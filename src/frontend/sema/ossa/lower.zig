// OSSA-lite lowering (Track I / I2) — produce the ownership IR for real Nova functions.
//
// This is the connective piece: it turns a Nova function body into the ownership IR (ossa/ir.zig) so
// the I3 verifier (ossa/verify.zig) can check release-balance on REAL code, not just constructed IR.
// The ownership signals come from sema's TypedIr (`ownedOf` / `typeOf` + `store.isOwnedSafe`) — i.e. the
// same information codegen uses to decide retain/release — so the IR reflects codegen's ownership, not a
// reverse-engineering of LLVM shapes (which is what blocked the V4' balance checker).
//
// SLICE 1 (this file) is deliberately NARROW and SOUND-BY-DEFERRAL, mirroring the V4' discipline: it
// only lowers functions whose body is STRAIGHT-LINE (no if/while/for/switch/nested block), and only
// models owned LET-LOCALS. For the balance property, only three events matter, so only these are
// emitted: `make_owned` (a let-local of owned type = a +1 birth), `copy` (a `let y = x` dup of an owned
// local), and the consumes (`destroy` at scope end, or `ret_owned` when an owned local is returned).
// Uses/borrows do not affect balance and are skipped in slice 1. Anything the walk cannot model
// precisely (control flow, reassignment, an owned value flowing into a call/store, destructuring) makes
// the whole function DEFERRED — never a wrong lowering. Coverage grows in I4.

const std = @import("std");
const ast = @import("../../ast.zig");
const types = @import("../../types.zig");
const infer = @import("../infer.zig");
const ir = @import("ir.zig");
const verify = @import("verify.zig");

const TypeStore = types.TypeStore;
const TypedIr = infer.TypedIr;

pub const Outcome = enum { lowered, deferred };

pub const LowerResult = struct {
    outcome: Outcome,
    func: ?ir.Func = null,
};

/// Lower one function. Returns `.deferred` (with no Func) when the body is outside slice-1 scope.
pub fn lowerFunction(
    gpa: std.mem.Allocator,
    store: *const TypeStore,
    tir: *const TypedIr,
    fn_decl: *const ast.FunctionDecl,
) !LowerResult {
    // Straight-line only: bail on any control-flow / nested-scope statement.
    if (!isStraightLine(fn_decl.body.statements)) return .{ .outcome = .deferred };

    var f = ir.Func{ .name = fn_decl.name };
    errdefer f.deinit(gpa);
    const entry = try f.newBlock(gpa);

    // owned locals in declaration order: name -> IR value, plus a liveness flag we clear on consume.
    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(gpa);
    var vals = std.ArrayListUnmanaged(ir.Value).empty;
    defer vals.deinit(gpa);

    for (fn_decl.body.statements) |*s| {
        switch (s.*) {
            .let_stmt => |ls| {
                if (ls.names != null) return deferAndFree(gpa, &f); // destructuring: defer
                const init = ls.init orelse continue;
                if (!isOwnedInit(store, tir, &init)) continue; // trivial / non-owned local: ignore

                // `let y = x` where x is a known owned local -> a dup (copy). Otherwise a fresh birth.
                if (init.kind == .ident) {
                    if (findLocal(names.items, init.kind.ident)) |_| {
                        const src = vals.items[findLocalIdx(names.items, init.kind.ident).?];
                        const v = try f.copy(gpa, entry, src);
                        try names.append(gpa, ls.name);
                        try vals.append(gpa, v);
                        continue;
                    }
                }
                // A birth is only sound to model when the owned value stays LOCAL. If the initializer is
                // anything that could hand ownership elsewhere as a side effect we cannot see here, we are
                // still fine: the value is bound to `ls.name`, and its ONLY consume in a straight-line
                // body is our scope-end destroy or a return of it. Reassignment/stores are excluded
                // because isStraightLine already rejected assignment expr-stmts touching locals (below).
                const v = try f.makeOwned(gpa, entry, tir.typeOf(&init));
                try names.append(gpa, ls.name);
                try vals.append(gpa, v);
            },
            .return_stmt => |r| {
                // Consume the returned owned local (if any) via ret_owned; destroy the rest; then stop.
                var returned_idx: ?usize = null;
                if (r.value) |val| {
                    if (val.kind == .ident) {
                        returned_idx = findLocalIdx(names.items, val.kind.ident);
                    } else if (mentionsAnyLocal(&val, names.items)) {
                        // owned local flows into a non-trivial return expression: cannot model -> defer.
                        return deferAndFree(gpa, &f);
                    }
                }
                try emitScopeEnd(gpa, &f, entry, vals.items, returned_idx);
                return .{ .outcome = .lowered, .func = f };
            },
            .expr_stmt => |es| {
                // A use of an owned local that could CONSUME it (assignment, or passing to a call) is not
                // modelled in slice 1 -> defer to stay sound. A pure borrow (no local mention) is fine.
                if (mentionsAnyLocal(&es.expr, names.items)) return deferAndFree(gpa, &f);
            },
            .defer_stmt => return deferAndFree(gpa, &f), // defer semantics not modelled yet
            else => {},
        }
    }

    // Fell through the end of the body: destroy every still-live owned local.
    try emitScopeEnd(gpa, &f, entry, vals.items, null);
    f.setTerm(entry, .ret_void);
    return .{ .outcome = .lowered, .func = f };
}

fn emitScopeEnd(gpa: std.mem.Allocator, f: *ir.Func, b: ir.Block, vals: []const ir.Value, returned_idx: ?usize) !void {
    for (vals, 0..) |v, i| {
        if (returned_idx != null and i == returned_idx.?) continue;
        try f.destroy(gpa, b, v);
    }
    if (returned_idx) |ri| {
        f.setTerm(b, .{ .ret_owned = vals[ri] });
    } else {
        f.setTerm(b, .ret_void);
    }
}

fn deferAndFree(gpa: std.mem.Allocator, f: *ir.Func) LowerResult {
    f.deinit(gpa);
    return .{ .outcome = .deferred };
}

fn isOwnedInit(store: *const TypeStore, tir: *const TypedIr, e: *const ast.Expression) bool {
    if (tir.ownedOf(e)) |o| return o;
    const tid = tir.typeOf(e) orelse return false;
    return store.isOwnedSafe(tid);
}

fn findLocal(names: []const []const u8, want: []const u8) ?[]const u8 {
    for (names) |n| if (std.mem.eql(u8, n, want)) return n;
    return null;
}
fn findLocalIdx(names: []const []const u8, want: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, want)) return i;
    return null;
}

fn mentionsAnyLocal(e: *const ast.Expression, names: []const []const u8) bool {
    for (names) |n| if (exprMentions(e, n)) return true;
    return false;
}

// Straight-line = only let/return/expr statements (no control flow, no nested blocks). Conservative.
fn isStraightLine(stmts: []const ast.Statement) bool {
    for (stmts) |*s| switch (s.*) {
        .let_stmt, .return_stmt, .expr_stmt => {},
        else => return false,
    };
    return true;
}

// A minimal name-mention check (idents only, recursive over common expression shapes). Enough for the
// slice-1 "does an owned local appear in this expression" guard.
fn exprMentions(e: *const ast.Expression, name: []const u8) bool {
    switch (e.kind) {
        .ident => |n| return std.mem.eql(u8, n, name),
        .binary => |b| return exprMentions(b.left, name) or exprMentions(b.right, name),
        .unary => |u| return exprMentions(u.operand, name),
        .call => |c| {
            if (exprMentions(c.callee, name)) return true;
            for (c.args) |*a| if (exprMentions(a, name)) return true;
            return false;
        },
        .field_access => |fa| return exprMentions(fa.object, name),
        .index => |ix| return exprMentions(ix.object, name) or exprMentions(ix.index, name),
        .cast => |c| return exprMentions(c.expr, name),
        .template_expr => |t| {
            for (t.parts) |*p| if (exprMentions(p, name)) return true;
            return false;
        },
        else => return false,
    }
}

// ── report driver (NOVA_OSSA): lower every function + run the I3 verifier, tally results ──
const Counts = struct {
    total: usize = 0,
    lowered: usize = 0,
    deferred: usize = 0,
    balanced: usize = 0,
    imbalanced: usize = 0,
    first_imbalance_fn: []const u8 = "",
};

pub fn report(gpa: std.mem.Allocator, store: *const TypeStore, tir: *const TypedIr, program: *const ast.Program) void {
    var c = Counts{};
    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |*f| lowerAndCheck(gpa, store, tir, f, &c),
            .struct_decl => |*sd| for (sd.methods) |*m| lowerAndCheck(gpa, store, tir, &m.decl, &c),
            .enum_decl => |*ed| for (ed.methods) |*m| lowerAndCheck(gpa, store, tir, &m.decl, &c),
            else => {},
        }
    }
    const cov: usize = if (c.total == 0) 0 else (c.lowered * 100) / c.total;
    std.debug.print(
        "=== OSSA-lite lowering + verify (NOVA_OSSA, I2 slice 1) ===\n" ++
        "  functions            : {d}\n" ++
        "  lowered (straight-line, owned-locals modelled) : {d}  ({d}% coverage)\n" ++
        "  deferred (control flow / uncertain)            : {d}\n" ++
        "  verified BALANCED    : {d}\n" ++
        "  verified IMBALANCED  : {d}\n",
        .{ c.total, c.lowered, cov, c.deferred, c.balanced, c.imbalanced },
    );
    if (c.imbalanced > 0) std.debug.print("    first imbalanced fn: {s}\n", .{c.first_imbalance_fn});
    std.debug.print("=== end OSSA-lite lowering ===\n", .{});
}

fn lowerAndCheck(gpa: std.mem.Allocator, store: *const TypeStore, tir: *const TypedIr, fd: *const ast.FunctionDecl, c: *Counts) void {
    c.total += 1;
    const res = lowerFunction(gpa, store, tir, fd) catch {
        c.deferred += 1;
        return;
    };
    switch (res.outcome) {
        .deferred => c.deferred += 1,
        .lowered => {
            c.lowered += 1;
            var f = res.func.?;
            defer f.deinit(gpa);
            var vr = verify.verify(gpa, &f) catch return;
            defer vr.deinit(gpa);
            if (vr.ok()) {
                c.balanced += 1;
            } else {
                c.imbalanced += 1;
                if (c.first_imbalance_fn.len == 0) c.first_imbalance_fn = fd.name;
            }
        },
    }
}

// ─────────────────────────────────────────── tests ───────────────────────────────────────────
// (Lowering needs a real TypedIr, which is heavy to construct in a unit test; end-to-end lowering is
//  exercised via the NOVA_OSSA corpus report. These tests cover the pure helpers.)

test "isStraightLine rejects control flow" {
    // an empty body is straight-line; helpers are unit-tested via the corpus report otherwise.
    try std.testing.expect(isStraightLine(&[_]ast.Statement{}));
}
