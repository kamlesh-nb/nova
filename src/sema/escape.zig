// P7 escape analysis (see docs/design/p7-sound-arena.md).
//
//   Stage 1 — classify each owned allocation bound to a local as LOCAL vs ESCAPES (report-only).
//   Stage 2 — interprocedural summaries: instead of "any allocation passed to any call escapes", a call
//             argument escapes only if the CALLEE's matching parameter escapes. Computed to a least
//             fixpoint over the call graph (start optimistic: nothing escapes, then propagate discovered
//             escapes monotonically -- sound because it is a may-escape analysis).
//
// Soundness: default = ESCAPES. A name is only LOCAL when no escape route touches it. Unresolved callees
// (trait dispatch, closures, extern, unknown names) stay conservative -> their args escape. Method
// receivers are conservatively treated as escaping. So a wrong LOCAL cannot arise from missing a route.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const infer = @import("infer.zig");

const TypeStore = types.TypeStore;
const TypedIr = infer.TypedIr;

pub var report_enabled: bool = false;

pub const Stats = struct {
    fns: usize = 0,
    alloc_sites: usize = 0,
    local: usize = 0,
    escapes: usize = 0,
    iterations: usize = 0,
};

const StrSet = std.StringHashMap(void);
const Edge = struct { lhs: []const u8, rhs: []const u8 };

// A function we can look up by name for its escape summary.
const FnEntry = struct {
    name: []const u8,
    params: []ast.Param,
    body: *const ast.Block,
};

// Module-scoped analysis state (rebuilt per analyze() call).
const Analysis = struct {
    alloc: std.mem.Allocator,
    ir: *const TypedIr,
    // name -> escapes[i]: does param i of (any function of this name) escape. OR-merged across same-named
    // functions; sized to the max arity seen. A call arg beyond the vector length is conservatively escaping.
    summaries: std.StringHashMap([]bool),

    fn summaryFor(self: *Analysis, name: []const u8) ?[]bool {
        return self.summaries.get(name);
    }
};

pub fn analyze(allocator: std.mem.Allocator, store: *const TypeStore, ir: *const TypedIr, program: *const ast.Program) Stats {
    _ = store;
    var st = Stats{};

    var an = Analysis{
        .alloc = allocator,
        .ir = ir,
        .summaries = std.StringHashMap([]bool).init(allocator),
    };
    defer {
        var vit = an.summaries.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        an.summaries.deinit();
    }

    // Collect every analysable function (free fns + struct/enum methods).
    var fns = std.ArrayList(FnEntry).empty;
    defer fns.deinit(allocator);
    for (program.declarations) |*decl| {
        switch (decl.*) {
            .fn_decl => |*f| fns.append(allocator, .{ .name = f.name, .params = f.params, .body = &f.body }) catch {},
            .struct_decl => |*sd| for (sd.methods) |*m| fns.append(allocator, .{ .name = m.decl.name, .params = m.decl.params, .body = &m.decl.body }) catch {},
            .enum_decl => |*ed| for (ed.methods) |*m| fns.append(allocator, .{ .name = m.decl.name, .params = m.decl.params, .body = &m.decl.body }) catch {},
            else => {},
        }
    }

    // Pre-populate an all-false (optimistic BOTTOM) summary for every KNOWN function name, sized to the max
    // arity across same-named functions. This is essential for a sound least-fixpoint: during iteration a
    // call to a known-but-not-yet-analysed function must assume its params do NOT escape (bottom) and only
    // gain escapes as they are justified. Only names ABSENT here (extern / trait-dispatch / indirect) stay
    // conservative (all args escape). Starting pessimistically would monotonically over-mark and never recover.
    for (fns.items) |fe| {
        const gop = an.summaries.getOrPut(fe.name) catch continue;
        if (!gop.found_existing) {
            const v = allocator.alloc(bool, fe.params.len) catch continue;
            for (v) |*b| b.* = false;
            gop.value_ptr.* = v;
        } else if (gop.value_ptr.*.len < fe.params.len) {
            const nv = allocator.alloc(bool, fe.params.len) catch continue;
            for (nv, 0..) |*b, i| b.* = if (i < gop.value_ptr.*.len) gop.value_ptr.*[i] else false;
            allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = nv;
        }
    }

    // Fixpoint: recompute each function's param-escape summary using the current summaries until stable.
    var round: usize = 0;
    while (round < 24) : (round += 1) {
        var changed = false;
        for (fns.items) |fe| {
            var escaping = StrSet.init(allocator);
            defer escaping.deinit();
            computeEscaping(&an, fe.params, fe.body, &escaping);
            if (mergeSummary(&an, fe, &escaping)) changed = true;
        }
        st.iterations += 1;
        if (!changed) break;
    }

    // Final classification pass with converged summaries.
    for (fns.items) |fe| {
        st.fns += 1;
        var escaping = StrSet.init(allocator);
        defer escaping.deinit();
        var allocs = StrSet.init(allocator);
        defer allocs.deinit();
        computeEscapingAndAllocs(&an, fe.params, fe.body, &escaping, &allocs);
        var it = allocs.keyIterator();
        while (it.next()) |k| {
            st.alloc_sites += 1;
            if (escaping.contains(k.*)) st.escapes += 1 else st.local += 1;
        }
    }

    if (report_enabled) {
        std.debug.print(
            "[escape] fns={d} alloc_sites={d} LOCAL={d} ESCAPES={d} (local {d}%, {d} iters)\n",
            .{ st.fns, st.alloc_sites, st.local, st.escapes, if (st.alloc_sites == 0) 0 else st.local * 100 / st.alloc_sites, st.iterations },
        );
    }
    return st;
}

// OR the freshly computed param-escape bits into the by-name summary. Returns whether any bit flipped on.
fn mergeSummary(an: *Analysis, fe: FnEntry, escaping: *StrSet) bool {
    const n = fe.params.len;
    const gop = an.summaries.getOrPut(fe.name) catch return false;
    if (!gop.found_existing) {
        const v = an.alloc.alloc(bool, n) catch return false;
        for (v, 0..) |*b, i| b.* = escaping.contains(fe.params[i].name);
        gop.value_ptr.* = v;
        // A fresh summary with any escaping param (or any at all) counts as a change so callers re-run.
        return true;
    }
    var vec = gop.value_ptr.*;
    var changed = false;
    // Grow if this same-named function has more params.
    if (vec.len < n) {
        const nv = an.alloc.alloc(bool, n) catch return false;
        for (nv, 0..) |*b, i| b.* = if (i < vec.len) vec[i] else false;
        an.alloc.free(vec);
        vec = nv;
        gop.value_ptr.* = nv;
        changed = true;
    }
    for (0..n) |i| {
        if (escaping.contains(fe.params[i].name) and !vec[i]) {
            vec[i] = true;
            changed = true;
        }
    }
    return changed;
}

const Ctx = struct {
    an: *Analysis,
    escaping: *StrSet,
    allocs: ?*StrSet, // non-null only on the final classification pass
    edges: std.ArrayList(Edge),

    fn markEscape(self: *Ctx, name: []const u8) void {
        self.escaping.put(name, {}) catch {};
    }
};

fn computeEscaping(an: *Analysis, params: []ast.Param, body: *const ast.Block, escaping: *StrSet) void {
    computeEscapingAndAllocs(an, params, body, escaping, null);
}

fn computeEscapingAndAllocs(an: *Analysis, params: []ast.Param, body: *const ast.Block, escaping: *StrSet, allocs: ?*StrSet) void {
    _ = params;
    var ctx = Ctx{ .an = an, .escaping = escaping, .allocs = allocs, .edges = std.ArrayList(Edge).empty };
    defer ctx.edges.deinit(an.alloc);
    for (body.statements) |*s| walkStmt(&ctx, s);
    // Alias fixpoint: if lhs escapes, rhs escapes.
    var changed = true;
    while (changed) {
        changed = false;
        for (ctx.edges.items) |e| {
            if (escaping.contains(e.lhs) and !escaping.contains(e.rhs)) {
                escaping.put(e.rhs, {}) catch {};
                changed = true;
            }
        }
    }
}

fn isOwned(ctx: *Ctx, e: *const ast.Expression) bool {
    return ctx.an.ir.ownedOf(e) orelse false;
}

fn collectIdents(e: *const ast.Expression, out: *std.ArrayList([]const u8), a: std.mem.Allocator) void {
    switch (e.kind) {
        .ident => |n| out.append(a, n) catch {},
        .binary => |b| {
            collectIdents(b.left, out, a);
            collectIdents(b.right, out, a);
        },
        .unary => |u| collectIdents(u.operand, out, a),
        .call => |c| {
            collectIdents(c.callee, out, a);
            for (c.args) |*arg| collectIdents(arg, out, a);
        },
        .generic_call => |c| {
            collectIdents(c.callee, out, a);
            for (c.args) |*arg| collectIdents(arg, out, a);
        },
        .field_access => |fa| collectIdents(fa.object, out, a),
        .index => |ix| {
            collectIdents(ix.object, out, a);
            collectIdents(ix.index, out, a);
        },
        .struct_init => |si| for (si.fields) |*fld| collectIdents(&fld.value, out, a),
        .enum_init => |ei| for (ei.fields) |*fld| collectIdents(&fld.value, out, a),
        .cast => |cx| collectIdents(cx.expr, out, a),
        .range => |r| {
            collectIdents(r.start, out, a);
            collectIdents(r.end, out, a);
        },
        .optional_chaining => |oc| collectIdents(oc.object, out, a),
        .nullish_coalesce => |nc| {
            collectIdents(nc.left, out, a);
            collectIdents(nc.right, out, a);
        },
        .tuple => |els| for (els) |*el| collectIdents(el, out, a),
        .if_expr => |ie| {
            collectIdents(ie.condition, out, a);
            collectIdents(ie.then_branch, out, a);
            collectIdents(ie.else_branch, out, a);
        },
        .template_expr => |te| for (te.parts) |*p| collectIdents(p, out, a),
        .try_expr => |tx| collectIdents(tx, out, a),
        .catch_expr => |cx| {
            collectIdents(cx.expr, out, a);
            collectIdents(cx.handler, out, a);
        },
        else => {},
    }
}

fn markIdentsEscape(ctx: *Ctx, e: *const ast.Expression) void {
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(ctx.an.alloc);
    collectIdents(e, &ids, ctx.an.alloc);
    for (ids.items) |n| ctx.markEscape(n);
}

// The callee's simple name (free-fn ident, or method name from `obj.method`), plus whether it is a method.
fn calleeName(callee: *const ast.Expression) ?struct { name: []const u8, method: bool } {
    return switch (callee.kind) {
        .ident => |n| .{ .name = n, .method = false },
        .field_access => |fa| .{ .name = fa.field, .method = true },
        else => null,
    };
}

// Apply a call's escapes using the callee summary. For a method `recv.m(a0,a1)` the receiver is param
// slot 0 (self) and arg i maps to param i+1; for a free call arg i maps to param i. A pointer escapes
// only if the matching parameter escapes in the callee summary. Unknown callee, or an out-of-range
// position (more actuals than the summary knows) => conservative escape. NOTE: the receiver is NOT
// blanket-escaped -- a local builder you only mutate (`sb.append(x)`, self does not escape) stays LOCAL.
fn applyCall(ctx: *Ctx, callee: *const ast.Expression, args: []const ast.Expression) void {
    const cn = calleeName(callee);
    if (cn == null) {
        // Indirect callee (closure var, computed): everything escapes.
        for (args) |*arg| markIdentsEscape(ctx, arg);
        return;
    }
    const summary = ctx.an.summaryFor(cn.?.name);
    const is_method = cn.?.method;
    const recv: ?*const ast.Expression = if (is_method) callee.kind.field_access.object else null;
    const base: usize = if (is_method) 1 else 0;
    if (summary) |esc| {
        if (recv) |r| {
            if (esc.len == 0 or esc[0]) markIdentsEscape(ctx, r); // self escapes (or summary too short)
        }
        for (args, 0..) |*arg, i| {
            const pi = base + i;
            if (pi >= esc.len or esc[pi]) markIdentsEscape(ctx, arg);
        }
    } else {
        if (recv) |r| markIdentsEscape(ctx, r);
        for (args) |*arg| markIdentsEscape(ctx, arg);
    }
}

fn walkExpr(ctx: *Ctx, e: *const ast.Expression) void {
    switch (e.kind) {
        .call => |c| {
            applyCall(ctx, c.callee, c.args);
            for (c.args) |*arg| walkExpr(ctx, arg);
        },
        .generic_call => |c| {
            applyCall(ctx, c.callee, c.args);
            for (c.args) |*arg| walkExpr(ctx, arg);
        },
        .closure => |cl| switch (cl.body) {
            .expr => |be| markIdentsEscape(ctx, be),
            .block => |blk| for (blk.statements) |*s| markStmtIdentsEscape(ctx, s),
        },
        .binary => |b| {
            walkExpr(ctx, b.left);
            walkExpr(ctx, b.right);
        },
        .unary => |u| walkExpr(ctx, u.operand),
        .field_access => |fa| walkExpr(ctx, fa.object),
        .index => |ix| {
            walkExpr(ctx, ix.object);
            walkExpr(ctx, ix.index);
        },
        .struct_init => |si| for (si.fields) |*fld| walkExpr(ctx, &fld.value),
        .cast => |cx| walkExpr(ctx, cx.expr),
        .nullish_coalesce => |nc| {
            walkExpr(ctx, nc.left);
            walkExpr(ctx, nc.right);
        },
        .optional_chaining => |oc| walkExpr(ctx, oc.object),
        .if_expr => |ie| {
            walkExpr(ctx, ie.condition);
            walkExpr(ctx, ie.then_branch);
            walkExpr(ctx, ie.else_branch);
        },
        .tuple => |els| for (els) |*el| walkExpr(ctx, el),
        .template_expr => |te| for (te.parts) |*p| walkExpr(ctx, p),
        .try_expr => |tx| walkExpr(ctx, tx),
        .catch_expr => |cx| {
            walkExpr(ctx, cx.expr);
            walkExpr(ctx, cx.handler);
        },
        else => {},
    }
}

fn markStmtIdentsEscape(ctx: *Ctx, s: *const ast.Statement) void {
    switch (s.*) {
        .expr_stmt => |es| markIdentsEscape(ctx, &es.expr),
        .let_stmt => |ls| if (ls.init) |init| markIdentsEscape(ctx, &init),
        .return_stmt => |r| if (r.value) |v| markIdentsEscape(ctx, &v),
        .block => |b| for (b.statements) |*x| markStmtIdentsEscape(ctx, x),
        .if_stmt => |iff| {
            markIdentsEscape(ctx, &iff.condition);
            markStmtIdentsEscape(ctx, iff.then_branch);
            if (iff.else_branch) |e| markStmtIdentsEscape(ctx, e);
        },
        .while_stmt => |w| {
            markIdentsEscape(ctx, &w.condition);
            markStmtIdentsEscape(ctx, w.body);
        },
        .for_stmt => |fo| markStmtIdentsEscape(ctx, fo.body),
        else => {},
    }
}

fn identName(e: *const ast.Expression) ?[]const u8 {
    return switch (e.kind) {
        .ident => |n| n,
        else => null,
    };
}

fn walkStmt(ctx: *Ctx, s: *const ast.Statement) void {
    switch (s.*) {
        .block => |b| for (b.statements) |*x| walkStmt(ctx, x),
        .let_stmt => |ls| {
            if (ls.init) |init| {
                if (ls.names == null and isOwned(ctx, &init)) {
                    if (ctx.allocs) |a| a.put(ls.name, {}) catch {};
                }
                if (ls.names == null) {
                    if (identName(&init)) |rhs| ctx.edges.append(ctx.an.alloc, .{ .lhs = ls.name, .rhs = rhs }) catch {};
                }
                walkExpr(ctx, &init);
            }
        },
        .expr_stmt => |es| {
            if (es.expr.kind == .binary and es.expr.kind.binary.op == .assign) {
                const b = es.expr.kind.binary;
                switch (b.left.kind) {
                    .field_access => markIdentsEscape(ctx, b.right),
                    .index => markIdentsEscape(ctx, b.right),
                    .ident => |lhs| {
                        if (identName(b.right)) |rhs| ctx.edges.append(ctx.an.alloc, .{ .lhs = lhs, .rhs = rhs }) catch {};
                        walkExpr(ctx, b.right);
                    },
                    else => walkExpr(ctx, b.right),
                }
            } else {
                walkExpr(ctx, &es.expr);
            }
        },
        .return_stmt => |r| if (r.value) |v| {
            markIdentsEscape(ctx, &v);
            walkExpr(ctx, &v);
        },
        .if_stmt => |iff| {
            walkExpr(ctx, &iff.condition);
            walkStmt(ctx, iff.then_branch);
            if (iff.else_branch) |e| walkStmt(ctx, e);
        },
        .while_stmt => |w| {
            walkExpr(ctx, &w.condition);
            walkStmt(ctx, w.body);
        },
        .for_stmt => |fo| {
            if (fo.initializer) |i| walkStmt(ctx, i);
            if (fo.condition) |*c| walkExpr(ctx, c);
            if (fo.increment) |*inc| walkExpr(ctx, inc);
            walkStmt(ctx, fo.body);
        },
        .switch_stmt => |sw| {
            walkExpr(ctx, &sw.discriminant);
            for (sw.cases) |*c| walkStmt(ctx, c.body);
            if (sw.default_case) |dc| walkStmt(ctx, dc);
        },
        .defer_stmt => |d| walkExpr(ctx, &d.expr),
        else => {},
    }
}
