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
const LowerError = error{ Defer, OutOfMemory };

// A control-flow outcome for a lowered statement sequence.
const Flow = union(enum) {
    /// the block ended in a terminator (return); nothing follows on this path.
    terminated,
    /// execution falls out of the sequence in this block, with these owned locals still live.
    fallthrough: ir.Block,
};

// Threaded lowering state. `names`/`vals` are function-scoped and append-only (owned locals in
// declaration order); `live` is per-PATH (a branch works on a clone) — a bool per local index.
const Ctx = struct {
    gpa: std.mem.Allocator,
    store: *const TypeStore,
    tir: *const TypedIr,
    f: *ir.Func,
    names: *std.ArrayListUnmanaged([]const u8),
    vals: *std.ArrayListUnmanaged(ir.Value),
};

pub fn lowerFunction(
    gpa: std.mem.Allocator,
    store: *const TypeStore,
    tir: *const TypedIr,
    fn_decl: *const ast.FunctionDecl,
) !LowerResult {
    var f = ir.Func{ .name = fn_decl.name };
    errdefer f.deinit(gpa);
    const entry = try f.newBlock(gpa);

    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(gpa);
    var vals = std.ArrayListUnmanaged(ir.Value).empty;
    defer vals.deinit(gpa);
    var live = std.ArrayListUnmanaged(bool).empty;
    defer live.deinit(gpa);

    var ctx = Ctx{ .gpa = gpa, .store = store, .tir = tir, .f = &f, .names = &names, .vals = &vals };

    const flow = lowerSeq(&ctx, entry, fn_decl.body.statements, &live) catch |e| switch (e) {
        error.Defer => {
            f.deinit(gpa);
            return .{ .outcome = .deferred };
        },
        else => return e,
    };
    switch (flow) {
        .terminated => {},
        .fallthrough => |b| {
            // Fell out of the body: destroy every still-live owned local, then return void.
            try dropLive(&ctx, b, &live, null);
            f.setTerm(b, .ret_void);
        },
    }
    return .{ .outcome = .lowered, .func = f };
}

/// Lower a statement sequence into `block`, threading the per-path `live` set. Returns whether it
/// terminated (a return) or fell through (with the block execution continues in).
fn lowerSeq(ctx: *Ctx, block: ir.Block, stmts: []const ast.Statement, live: *std.ArrayListUnmanaged(bool)) LowerError!Flow {
    var cur = block;
    for (stmts) |*s| {
        switch (s.*) {
            .let_stmt => |ls| {
                if (ls.names != null) return error.Defer; // destructuring
                const init = ls.init orelse continue;
                if (!isOwnedInit(ctx.store, ctx.tir, &init)) continue; // trivial local: ignore

                var v: ir.Value = undefined;
                if (init.kind == .ident and findLocalIdx(ctx.names.items, init.kind.ident) != null) {
                    v = try ctx.f.copy(ctx.gpa, cur, ctx.vals.items[findLocalIdx(ctx.names.items, init.kind.ident).?]);
                } else if (mentionsAnyLocal(&init, ctx.names.items)) {
                    return error.Defer; // owned init derived from a local in a way we can't model
                } else {
                    v = try ctx.f.makeOwned(ctx.gpa, cur, ctx.tir.typeOf(&init));
                }
                try ctx.names.append(ctx.gpa, ls.name);
                try ctx.vals.append(ctx.gpa, v);
                try live.append(ctx.gpa, true);
            },
            .return_stmt => |r| {
                var returned_idx: ?usize = null;
                if (r.value) |val| {
                    if (val.kind == .ident) {
                        returned_idx = findLocalIdx(ctx.names.items, val.kind.ident);
                    } else if (mentionsAnyLocal(&val, ctx.names.items)) {
                        return error.Defer; // owned local flows into a return expression
                    }
                }
                try dropLive(ctx, cur, live, returned_idx);
                if (returned_idx) |ri| {
                    ctx.f.setTerm(cur, .{ .ret_owned = ctx.vals.items[ri] });
                } else {
                    ctx.f.setTerm(cur, .ret_void);
                }
                return .terminated;
            },
            .expr_stmt => |es| {
                if (mentionsAnyLocal(&es.expr, ctx.names.items)) return error.Defer; // maybe-consuming use
            },
            .if_stmt => |iff| {
                switch (try lowerIf(ctx, cur, &iff, live)) {
                    .terminated => return .terminated, // both branches diverged: rest is unreachable
                    .fallthrough => |join| cur = join,
                }
            },
            .defer_stmt => return error.Defer,
            else => return error.Defer, // while/for/switch/nested-block: not modelled yet
        }
    }
    return .{ .fallthrough = cur };
}

/// Lower an if/else. `entry_block` is where the branch is taken from. Returns the join block to
/// continue in, or `.terminated` when BOTH paths diverge (join unreachable). The join block is
/// allocated LAST so every edge is index-increasing (keeps the verifier's topological order valid).
fn lowerIf(ctx: *Ctx, entry_block: ir.Block, iff: *const ast.IfStmt, live: *std.ArrayListUnmanaged(bool)) LowerError!Flow {
    const then_stmts = branchStmts(iff.then_branch) orelse return error.Defer;
    const else_stmts: ?[]const ast.Statement = if (iff.else_branch) |e| (branchStmts(e) orelse return error.Defer) else null;

    const cond = try ctx.f.makeTrivial(ctx.gpa, entry_block, null);
    const then_block = try ctx.f.newBlock(ctx.gpa);
    const else_block: ?ir.Block = if (else_stmts != null) try ctx.f.newBlock(ctx.gpa) else null;

    // A branch must NOT declare a new owned local (that would make the live-set sizes differ across
    // paths). Detect by a growth check and defer.
    const nlocals_before = ctx.names.items.len;

    var then_live = try cloneLive(ctx.gpa, live);
    defer then_live.deinit(ctx.gpa);
    const then_flow = try lowerSeq(ctx, then_block, then_stmts, &then_live);
    if (ctx.names.items.len != nlocals_before) return error.Defer;

    var else_flow: ?Flow = null;
    if (else_stmts) |es| {
        var else_live = try cloneLive(ctx.gpa, live);
        defer else_live.deinit(ctx.gpa);
        else_flow = try lowerSeq(ctx, else_block.?, es, &else_live);
        if (ctx.names.items.len != nlocals_before) return error.Defer;
    }

    const join_block = try ctx.f.newBlock(ctx.gpa); // highest index
    ctx.f.setTerm(entry_block, .{ .cond_br = .{ .cond = cond, .then_blk = then_block, .else_blk = else_block orelse join_block } });

    var any_fallthrough = false;
    switch (then_flow) {
        .fallthrough => |b| {
            ctx.f.setTerm(b, .{ .br = join_block });
            any_fallthrough = true;
        },
        .terminated => {},
    }
    if (else_flow) |ef| {
        switch (ef) {
            .fallthrough => |b| {
                ctx.f.setTerm(b, .{ .br = join_block });
                any_fallthrough = true;
            },
            .terminated => {},
        }
    } else {
        // no else: the entry's else edge goes straight to join, carrying `live` unchanged.
        any_fallthrough = true;
    }

    return if (any_fallthrough) .{ .fallthrough = join_block } else .terminated;
}

/// Destroy every still-live owned local in `block`, except `keep` (the returned one). Marks them dead
/// in `live`. Iterates in reverse declaration order (scope-end drop order).
fn dropLive(ctx: *Ctx, block: ir.Block, live: *std.ArrayListUnmanaged(bool), keep: ?usize) !void {
    var i: usize = live.items.len;
    while (i > 0) {
        i -= 1;
        if (!live.items[i]) continue;
        if (keep != null and i == keep.?) continue;
        try ctx.f.destroy(ctx.gpa, block, ctx.vals.items[i]);
        live.items[i] = false;
    }
    if (keep) |k| live.items[k] = false; // returned value is consumed by the terminator
}

fn cloneLive(gpa: std.mem.Allocator, live: *const std.ArrayListUnmanaged(bool)) !std.ArrayListUnmanaged(bool) {
    var out = std.ArrayListUnmanaged(bool).empty;
    try out.appendSlice(gpa, live.items);
    return out;
}

/// The statement list of a branch (must be a block for slice 2; a bare single statement defers).
fn branchStmts(s: *const ast.Statement) ?[]const ast.Statement {
    return switch (s.*) {
        .block => |b| b.statements,
        else => null,
    };
}

fn isOwnedInit(store: *const TypeStore, tir: *const TypedIr, e: *const ast.Expression) bool {
    if (tir.ownedOf(e)) |o| return o;
    const tid = tir.typeOf(e) orelse return false;
    return store.isOwnedSafe(tid);
}

fn findLocalIdx(names: []const []const u8, want: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, want)) return i;
    return null;
}

fn mentionsAnyLocal(e: *const ast.Expression, names: []const []const u8) bool {
    for (names) |n| if (exprMentions(e, n)) return true;
    return false;
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

test "findLocalIdx locates a name by declaration order" {
    const names = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectEqual(@as(?usize, 1), findLocalIdx(&names, "b"));
    try std.testing.expectEqual(@as(?usize, null), findLocalIdx(&names, "z"));
}
