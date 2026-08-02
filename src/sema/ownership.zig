
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const infer = @import("infer.zig");

const TypeStore = types.TypeStore;
const TypedIr = infer.TypedIr;

pub const Stats = struct {
    fns_walked: usize = 0,
    owned_locals: usize = 0,
    analyzed: usize = 0,
    deferred_cfg: usize = 0,
    deferred_untyped: usize = 0,
    drop_ops: usize = 0,
    move_outs: usize = 0,
    dup_ops: usize = 0,
    balance_violations: usize = 0,
    first_violation: []const u8 = "",

    temp_moves: usize = 0,
    temp_drops: usize = 0,
};

pub fn analyze(allocator: std.mem.Allocator, store: *const TypeStore, ir: *TypedIr, program: *const ast.Program) Stats {
    var st = Stats{};
    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |f| analyzeFn(allocator, &f, store, ir, &st),
            .struct_decl => |sd| for (sd.methods) |m| analyzeFn(allocator, &m.decl, store, ir, &st),
            .enum_decl => |ed| for (ed.methods) |m| analyzeFn(allocator, &m.decl, store, ir, &st),
            else => {},
        }
    }
    return st;
}

fn analyzeFn(allocator: std.mem.Allocator, f: *const ast.FunctionDecl, store: *const TypeStore, ir: *TypedIr, st: *Stats) void {
    st.fns_walked += 1;
    analyzeStmts(f.body.statements, store, ir, st);
    for (f.body.statements) |*s| tempStmt(allocator, ir, s, st);
}

fn tempStmt(alloc: std.mem.Allocator, ir: *TypedIr, s: *const ast.Statement, st: *Stats) void {
    switch (s.*) {
        .block => |b| for (b.statements) |*x| tempStmt(alloc, ir, x, st),

        .let_stmt => |ls| if (ls.init) |init| tempExpr(alloc, ir, &init, ls.names == null, st),
        .return_stmt => |r| if (r.value) |v| tempExpr(alloc, ir, &v, true, st),
        .expr_stmt => |es| tempExpr(alloc, ir, &es.expr, false, st),
        .if_stmt => |iff| {
            tempExpr(alloc, ir, &iff.condition, false, st);
            tempStmt(alloc, ir, iff.then_branch, st);
            if (iff.else_branch) |e| tempStmt(alloc, ir, e, st);
        },
        .while_stmt => |w| {
            tempExpr(alloc, ir, &w.condition, false, st);
            tempStmt(alloc, ir, w.body, st);
        },
        .for_stmt => |fo| {
            if (fo.condition) |c| tempExpr(alloc, ir, &c, false, st);
            if (fo.increment) |c| tempExpr(alloc, ir, &c, false, st);
            if (fo.iterator) |it| tempExpr(alloc, ir, it.iterable, false, st);
            tempStmt(alloc, ir, fo.body, st);
        },
        .switch_stmt => |sw| {
            tempExpr(alloc, ir, &sw.discriminant, false, st);
            for (sw.cases) |c| {
                for (c.values) |*v| tempExpr(alloc, ir, v, false, st);
                tempStmt(alloc, ir, c.body, st);
            }
            if (sw.default_case) |d| tempStmt(alloc, ir, d, st);
        },
        .defer_stmt => |d| tempExpr(alloc, ir, &d.expr, false, st),
        else => {},
    }
}

fn tempExpr(alloc: std.mem.Allocator, ir: *TypedIr, e: *const ast.Expression, moved: bool, st: *Stats) void {

    if (ir.ownedOf(e)) |owned| {
        if (owned) {
            if (moved) st.temp_moves += 1 else st.temp_drops += 1;
            ir.recordOp(alloc, e, if (moved) .move else .drop) catch {};
        }
    }

    switch (e.kind) {
        .call => |c| {
            tempExpr(alloc, ir, c.callee, false, st);
            for (c.args) |*a| tempExpr(alloc, ir, a, false, st);
        },
        .generic_call => |c| {
            tempExpr(alloc, ir, c.callee, false, st);
            for (c.args) |*a| tempExpr(alloc, ir, a, false, st);
        },
        .binary => |b| {

            tempExpr(alloc, ir, b.left, false, st);
            tempExpr(alloc, ir, b.right, b.op == .assign, st);
        },
        .unary => |u| tempExpr(alloc, ir, u.operand, false, st),
        .field_access => |fa| tempExpr(alloc, ir, fa.object, false, st),
        .index => |ix| {
            tempExpr(alloc, ir, ix.object, false, st);
            tempExpr(alloc, ir, ix.index, false, st);
        },
        .cast => |c| tempExpr(alloc, ir, c.expr, moved, st),
        .optional_chaining => |oc| tempExpr(alloc, ir, oc.object, false, st),
        .nullish_coalesce => |nc| {

            tempExpr(alloc, ir, nc.left, true, st);
            tempExpr(alloc, ir, nc.right, moved, st);
        },
        .template_expr => |t| for (t.parts) |*p| tempExpr(alloc, ir, p, false, st),
        .tuple => |elems| for (elems) |*x| tempExpr(alloc, ir, x, true, st),
        .struct_init => |si| for (si.fields) |*fld| tempExpr(alloc, ir, &fld.value, true, st),
        .enum_init => |ei| for (ei.fields) |*fld| tempExpr(alloc, ir, &fld.value, true, st),
        .if_expr => |ie| {

            tempExpr(alloc, ir, ie.condition, false, st);
            tempExpr(alloc, ir, ie.then_branch, true, st);
            tempExpr(alloc, ir, ie.else_branch, true, st);
        },
        .block_expr => |b| for (b.statements) |*s| tempStmt(alloc, ir, s, st),

        .try_expr => |t| tempExpr(alloc, ir, t, false, st),
        .catch_expr => |c| {
            tempExpr(alloc, ir, c.expr, false, st);
            tempExpr(alloc, ir, c.handler, moved, st);
        },
        .await_expr, .go_expr => |a| tempExpr(alloc, ir, a.operand, false, st),

        .closure => |cl| switch (cl.body) {
            .expr => |ce| tempExpr(alloc, ir, ce, true, st),
            .block => |b| for (b.statements) |*s| tempStmt(alloc, ir, s, st),
        },
        else => {},
    }
}

fn analyzeStmts(stmts: []const ast.Statement, store: *const TypeStore, ir: *const TypedIr, st: *Stats) void {
    for (stmts, 0..) |*s, i| {

        recurseIntoNested(s, store, ir, st);

        if (s.* != .let_stmt) continue;
        const ls = s.let_stmt;

        if (ls.names != null) continue;
        const init = ls.init orelse continue;

        const tid = ir.typeOf(&init) orelse {

            if (initCouldBeOwned(&init)) {
                st.owned_locals += 1;
                st.deferred_untyped += 1;
            }
            continue;
        };
        if (!store.isOwnedSafe(tid)) continue;

        st.owned_locals += 1;
        analyzeOwnedLocal(ls.name, stmts[i + 1 ..], st);
    }
}

fn recurseIntoNested(s: *const ast.Statement, store: *const TypeStore, ir: *const TypedIr, st: *Stats) void {
    switch (s.*) {
        .block => |b| analyzeStmts(b.statements, store, ir, st),
        .if_stmt => |iff| {
            recurseIntoNested(iff.then_branch, store, ir, st);
            if (iff.else_branch) |e| recurseIntoNested(e, store, ir, st);
        },
        .while_stmt => |w| recurseIntoNested(w.body, store, ir, st),
        .for_stmt => |fo| recurseIntoNested(fo.body, store, ir, st),
        .switch_stmt => |sw| {
            for (sw.cases) |c| recurseIntoNested(c.body, store, ir, st);
            if (sw.default_case) |d| recurseIntoNested(d, store, ir, st);
        },
        else => {},
    }
}

const St = enum { live, moved };

const Flow = union(enum) {

    fallthrough: St,

    returned,

    deferred,

    violation,
};

fn analyzeOwnedLocal(name: []const u8, rest: []const ast.Statement, st: *Stats) void {
    switch (walkSeq(name, rest, .live, st)) {
        .fallthrough => |s| {

            if (s == .live) st.drop_ops += 1 else st.move_outs += 1;
            st.analyzed += 1;
        },

        .returned => st.analyzed += 1,
        .deferred => st.deferred_cfg += 1,
        .violation => {
            st.balance_violations += 1;
            if (st.first_violation.len == 0) st.first_violation = name;
        },
    }
}

fn walkSeq(name: []const u8, stmts: []const ast.Statement, entry: St, st: *Stats) Flow {
    var state = entry;
    for (stmts) |*s| {
        switch (walkStmt(name, s, state, st)) {
            .fallthrough => |ns| state = ns,
            .returned => return .returned,
            .deferred => return .deferred,
            .violation => return .violation,
        }
    }
    return .{ .fallthrough = state };
}

fn walkStmt(name: []const u8, s: *const ast.Statement, state: St, st: *Stats) Flow {
    switch (s.*) {
        .block => |b| return walkSeq(name, b.statements, state, st),

        .let_stmt => |ls| {
            if (std.mem.eql(u8, ls.name, name)) return .deferred;
            if (ls.init) |init| {
                if (mentionsComplex(&init, name)) return .deferred;
                if (isIdent(&init, name)) {
                    // `let y = x` binds a SECOND owned reference to x. Under ARC this is a
                    // retaining DUP whenever x is used afterward -- codegen inserts nova_retain
                    // at the bind, so x and y are each dropped exactly once and the refcount
                    // stays balanced (last-use with no later mention degenerates to a move, which
                    // is likewise balanced). Modeling it as a LINEAR move made the check report a
                    // false "use-after-move" on the legitimate later use of x -- the only two such
                    // sites in the corpus, `frame` (web.client: `let body = dechunked; ...;
                    // body = gzip.decompress(dechunked)`) and `close_notify_detected`
                    // (tlsmembio: `let cw = cb; ...; cb.closeNotify()`), are both ASAN-clean.
                    // Nova is reference-counted, not affine: there is no source-level double-free
                    // via rebinding for codegen's retain to miss, so a dup leaves x live.
                    st.dup_ops += 1;
                    return .{ .fallthrough = state };
                }
                if (mentions(&init, name)) {
                    if (state == .moved) return .violation;
                    return .{ .fallthrough = state };
                }
            }
            return .{ .fallthrough = state };
        },

        .expr_stmt => |es| {

            if (es.expr.kind == .binary) {
                const b = es.expr.kind.binary;
                if (b.op == .assign and isIdent(b.left, name)) return .deferred;
            }
            if (mentionsComplex(&es.expr, name)) return .deferred;
            if (mentions(&es.expr, name)) {
                if (state == .moved) return .violation;
            }
            return .{ .fallthrough = state };
        },

        .return_stmt => |r| {
            if (r.value) |val| {
                if (mentionsComplex(&val, name)) return .deferred;
                if (isIdent(&val, name)) {
                    if (state == .moved) return .violation;
                    st.move_outs += 1;
                    return .returned;
                }
                if (mentions(&val, name)) {
                    if (state == .moved) return .violation;
                }
            }

            if (state == .live) st.drop_ops += 1;
            return .returned;
        },

        .if_stmt => |iff| {
            if (mentionsComplex(&iff.condition, name)) return .deferred;
            if (mentions(&iff.condition, name) and state == .moved) return .violation;
            const ft = walkStmt(name, iff.then_branch, state, st);
            const fe = if (iff.else_branch) |e| walkStmt(name, e, state, st) else Flow{ .fallthrough = state };
            return mergeIf(ft, fe, st);
        },

        .while_stmt => |w| return walkLoop(name, &w.condition, w.body, state, st),
        .for_stmt => |fo| {
            if (fo.iterator) |it| if (mentions(it.iterable, name) and state == .moved) return .violation;
            const cond: ?*const ast.Expression = if (fo.condition) |*c| c else null;
            return walkLoop(name, cond, fo.body, state, st);
        },

        .switch_stmt, .break_stmt, .continue_stmt, .defer_stmt => {
            if (stmtMentions(s, name)) return .deferred;
            return .{ .fallthrough = state };
        },
    }
}

fn mergeIf(ft: Flow, fe: Flow, st: *Stats) Flow {
    if (ft == .deferred or fe == .deferred) return .deferred;
    if (ft == .violation or fe == .violation) return .violation;
    const st_then: ?St = switch (ft) {
        .fallthrough => |x| x,
        .returned => null,
        else => unreachable,
    };
    const st_else: ?St = switch (fe) {
        .fallthrough => |x| x,
        .returned => null,
        else => unreachable,
    };
    if (st_then == null and st_else == null) return .returned;
    if (st_then == null) return .{ .fallthrough = st_else.? };
    if (st_else == null) return .{ .fallthrough = st_then.? };
    if (st_then.? == st_else.?) return .{ .fallthrough = st_then.? };

    st.drop_ops += 1;
    return .{ .fallthrough = .moved };
}

fn walkLoop(name: []const u8, cond: ?*const ast.Expression, body: *const ast.Statement, state: St, st: *Stats) Flow {
    if (cond) |c| {
        if (mentionsComplex(c, name)) return .deferred;
        if (mentions(c, name) and state == .moved) return .violation;
    }
    if (seqMovesLocal(name, body)) return .deferred;
    if (stmtComplexMentions(name, body)) return .deferred;
    if (state == .moved and stmtMentions(body, name)) return .violation;
    _ = st;
    return .{ .fallthrough = state };
}

fn seqMovesLocal(name: []const u8, s: *const ast.Statement) bool {
    switch (s.*) {
        .block => |b| {
            for (b.statements) |*x| if (seqMovesLocal(name, x)) return true;
            return false;
        },
        .return_stmt => |r| return if (r.value) |v| isIdent(&v, name) else false,
        .let_stmt => |ls| return if (ls.init) |v| isIdent(&v, name) else false,
        .if_stmt => |iff| {
            if (seqMovesLocal(name, iff.then_branch)) return true;
            if (iff.else_branch) |e| return seqMovesLocal(name, e);
            return false;
        },
        .while_stmt => |w| return seqMovesLocal(name, w.body),
        .for_stmt => |fo| return seqMovesLocal(name, fo.body),
        .switch_stmt => |sw| {
            for (sw.cases) |c| if (seqMovesLocal(name, c.body)) return true;
            if (sw.default_case) |d| return seqMovesLocal(name, d);
            return false;
        },
        else => return false,
    }
}

fn stmtComplexMentions(name: []const u8, s: *const ast.Statement) bool {
    switch (s.*) {
        .block => |b| {
            for (b.statements) |*x| if (stmtComplexMentions(name, x)) return true;
            return false;
        },
        .let_stmt => |ls| return if (ls.init) |v| mentionsComplex(&v, name) else false,
        .expr_stmt => |es| return mentionsComplex(&es.expr, name),
        .return_stmt => |r| return if (r.value) |v| mentionsComplex(&v, name) else false,
        .if_stmt => |iff| {
            if (mentionsComplex(&iff.condition, name)) return true;
            if (stmtComplexMentions(name, iff.then_branch)) return true;
            if (iff.else_branch) |e| return stmtComplexMentions(name, e);
            return false;
        },
        .while_stmt => |w| return mentionsComplex(&w.condition, name) or stmtComplexMentions(name, w.body),
        .for_stmt => |fo| {
            if (fo.condition) |c| if (mentionsComplex(&c, name)) return true;
            if (fo.increment) |c| if (mentionsComplex(&c, name)) return true;
            if (fo.iterator) |it| if (mentionsComplex(it.iterable, name)) return true;
            return stmtComplexMentions(name, fo.body);
        },
        .switch_stmt => |sw| {
            if (mentionsComplex(&sw.discriminant, name)) return true;
            for (sw.cases) |c| if (stmtComplexMentions(name, c.body)) return true;
            if (sw.default_case) |d| return stmtComplexMentions(name, d);
            return false;
        },
        .defer_stmt => |d| return mentionsComplex(&d.expr, name),
        else => return false,
    }
}

fn isIdent(e: *const ast.Expression, name: []const u8) bool {
    return e.kind == .ident and std.mem.eql(u8, e.kind.ident, name);
}

fn stmtMentions(s: *const ast.Statement, name: []const u8) bool {
    switch (s.*) {
        .block => |b| {
            for (b.statements) |*x| if (stmtMentions(x, name)) return true;
            return false;
        },
        .let_stmt => |ls| return if (ls.init) |v| mentions(&v, name) else false,
        .expr_stmt => |es| return mentions(&es.expr, name),
        .return_stmt => |r| return if (r.value) |v| mentions(&v, name) else false,
        .if_stmt => |iff| {
            if (mentions(&iff.condition, name)) return true;
            if (stmtMentions(iff.then_branch, name)) return true;
            if (iff.else_branch) |e| return stmtMentions(e, name);
            return false;
        },
        .while_stmt => |w| return mentions(&w.condition, name) or stmtMentions(w.body, name),
        .for_stmt => |fo| {
            if (fo.condition) |c| if (mentions(&c, name)) return true;
            if (fo.increment) |c| if (mentions(&c, name)) return true;
            if (fo.iterator) |it| if (mentions(it.iterable, name)) return true;
            return stmtMentions(fo.body, name);
        },
        .switch_stmt => |sw| {
            if (mentions(&sw.discriminant, name)) return true;
            for (sw.cases) |c| if (stmtMentions(c.body, name)) return true;
            if (sw.default_case) |d| return stmtMentions(d, name);
            return false;
        },
        .defer_stmt => |d| return mentions(&d.expr, name),
        else => return false,
    }
}

fn mentionsComplex(e: *const ast.Expression, name: []const u8) bool {
    switch (e.kind) {
        .closure, .if_expr, .block_expr, .catch_expr => return mentions(e, name),
        .binary => |b| return mentionsComplex(b.left, name) or mentionsComplex(b.right, name),
        .unary => |u| return mentionsComplex(u.operand, name),
        .call => |c| {
            if (mentionsComplex(c.callee, name)) return true;
            for (c.args) |*a| if (mentionsComplex(a, name)) return true;
            return false;
        },
        .field_access => |fa| return mentionsComplex(fa.object, name),
        .index => |ix| return mentionsComplex(ix.object, name) or mentionsComplex(ix.index, name),
        .template_expr => |t| {
            for (t.parts) |*p| if (mentionsComplex(p, name)) return true;
            return false;
        },
        .tuple => |elems| {
            for (elems) |*x| if (mentionsComplex(x, name)) return true;
            return false;
        },
        .cast => |c| return mentionsComplex(c.expr, name),
        else => return false,
    }
}

fn mentions(e: *const ast.Expression, name: []const u8) bool {
    switch (e.kind) {
        .ident => |n| return std.mem.eql(u8, n, name),
        .binary => |b| return mentions(b.left, name) or mentions(b.right, name),
        .unary => |u| return mentions(u.operand, name),
        .call => |c| {
            if (mentions(c.callee, name)) return true;
            for (c.args) |*a| if (mentions(a, name)) return true;
            return false;
        },
        .generic_call => |c| {
            if (mentions(c.callee, name)) return true;
            for (c.args) |*a| if (mentions(a, name)) return true;
            return false;
        },
        .field_access => |fa| return mentions(fa.object, name),
        .index => |ix| return mentions(ix.object, name) or mentions(ix.index, name),
        .cast => |c| return mentions(c.expr, name),
        .optional_chaining => |oc| return mentions(oc.object, name),
        .nullish_coalesce => |nc| return mentions(nc.left, name) or mentions(nc.right, name),
        .template_expr => |t| {
            for (t.parts) |*p| if (mentions(p, name)) return true;
            return false;
        },
        .tuple => |elems| {
            for (elems) |*x| if (mentions(x, name)) return true;
            return false;
        },
        .struct_init => |si| {
            for (si.fields) |*fld| if (mentions(&fld.value, name)) return true;
            return false;
        },
        .enum_init => |ei| {
            for (ei.fields) |*fld| if (mentions(&fld.value, name)) return true;
            return false;
        },
        .if_expr => |ie| {
            if (mentions(ie.condition, name)) return true;
            if (mentions(ie.then_branch, name)) return true;
            return mentions(ie.else_branch, name);
        },
        .block_expr => |b| {
            for (b.statements) |*s| if (stmtMentions(s, name)) return true;
            return false;
        },
        .try_expr => |t| return mentions(t, name),
        .catch_expr => |c| return mentions(c.expr, name) or mentions(c.handler, name),
        .await_expr, .go_expr => |a| return mentions(a.operand, name),
        .closure => |cl| return switch (cl.body) {
            .expr => |ce| mentions(ce, name),
            .block => |b| blk: {
                for (b.statements) |*s| if (stmtMentions(s, name)) break :blk true;
                break :blk false;
            },
        },
        else => return false,
    }
}

fn initCouldBeOwned(e: *const ast.Expression) bool {
    return switch (e.kind) {
        .literal => |lit| switch (lit) {
            .integer, .float, .bool, .null, .undefined => false,
            else => true,
        },
        else => true,
    };
}
