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
const forward = @import("forward.zig");

const TypeStore = types.TypeStore;
const TypedIr = infer.TypedIr;

pub const Outcome = enum { lowered, deferred };

pub const LowerResult = struct {
    outcome: Outcome,
    func: ?ir.Func = null,
    reason: DeferReason = .other,
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

// One owned local in the current PATH: its name, its IR value, and whether it is still live. The list
// grows as blocks nest (a lexical scope = the tail beyond a saved `mark`) and shrinks at scope end
// (dropScope drops the tail's still-live locals and truncates). Branches/loop bodies work on a CLONE so
// their declarations and consumes do not leak into sibling paths.
const Local = struct { name: []const u8, value: ir.Value, live: bool };
const Locals = std.ArrayListUnmanaged(Local);

/// Why a function was deferred (for the NOVA_OSSA report's coverage-gap breakdown).
pub const DeferReason = enum { reassign, break_continue, switch_guard, nonblock_branch, other };

/// The innermost enclosing loop, for lowering `break`/`continue`. `body_mark` is the locals count at the
/// loop body's entry, so break/continue know which locals to drop (everything declared in the body).
const LoopCtx = struct { header: ir.Block, exit: ir.Block, body_mark: usize };

const Ctx = struct {
    gpa: std.mem.Allocator,
    store: *const TypeStore,
    tir: *const TypedIr,
    f: *ir.Func,
    defer_reason: DeferReason = .other,
    loop: ?LoopCtx = null,
};

/// Record why we are about to defer, then return the Defer error.
fn deferBecause(ctx: *Ctx, reason: DeferReason) LowerError {
    ctx.defer_reason = reason;
    return error.Defer;
}

pub fn lowerFunction(
    gpa: std.mem.Allocator,
    store: *const TypeStore,
    tir: *const TypedIr,
    fn_decl: *const ast.FunctionDecl,
) !LowerResult {
    var f = ir.Func{ .name = fn_decl.name };
    errdefer f.deinit(gpa);
    const entry = try f.newBlock(gpa);

    var locals: Locals = .empty;
    defer locals.deinit(gpa);
    var ctx = Ctx{ .gpa = gpa, .store = store, .tir = tir, .f = &f };

    // The function body is the outermost lexical scope (mark 0 = drop everything at the end).
    const flow = lowerBlockScope(&ctx, entry, fn_decl.body.statements, &locals) catch |e| switch (e) {
        error.Defer => {
            f.deinit(gpa);
            return .{ .outcome = .deferred, .reason = ctx.defer_reason };
        },
        else => return e,
    };
    switch (flow) {
        .terminated => {},
        .fallthrough => |b| f.setTerm(b, .ret_void),
    }
    return .{ .outcome = .lowered, .func = f };
}

/// Lower a lexical scope: run `stmts`, and on fall-through destroy the locals THIS scope declared
/// (those appended at index >= the entry mark), truncating them back out of scope.
fn lowerBlockScope(ctx: *Ctx, block: ir.Block, stmts: []const ast.Statement, locals: *Locals) LowerError!Flow {
    const mark = locals.items.len;
    switch (try lowerSeq(ctx, block, stmts, locals)) {
        .terminated => return .terminated, // a return already dropped every enclosing scope
        .fallthrough => |b| {
            try dropScope(ctx, b, locals, mark);
            return .{ .fallthrough = b };
        },
    }
}

/// Lower a statement sequence into `block` (no scope handling of its own — the caller wraps it in a
/// lowerBlockScope). Mutates `locals` (the current path). Returns terminated (a return) or fallthrough.
fn lowerSeq(ctx: *Ctx, block: ir.Block, stmts: []const ast.Statement, locals: *Locals) LowerError!Flow {
    var cur = block;
    for (stmts) |*s| {
        switch (s.*) {
            .let_stmt => |ls| try lowerLet(ctx, cur, &ls, locals),
            .return_stmt => |r| {
                // A bare `return x` where x is an owned local MOVES x out (ret_owned). Any other return
                // expression BORROWS the locals it mentions -> drop all live locals, ret_void.
                var returned_idx: ?usize = null;
                if (r.value) |val| {
                    if (val.kind == .ident) returned_idx = resolveLocal(locals.items, val.kind.ident);
                }
                try dropAll(ctx, cur, locals, returned_idx);
                if (returned_idx) |ri| {
                    ctx.f.setTerm(cur, .{ .ret_owned = locals.items[ri].value });
                } else {
                    ctx.f.setTerm(cur, .ret_void);
                }
                return .terminated;
            },
            .expr_stmt => |es| {
                // A bare-local REASSIGNMENT (`x = ...`) drops the old value and rebinds — not modelled
                // yet, so defer. Any other expression statement borrows the locals it touches: no effect.
                if (isLocalReassign(&es.expr, locals.items)) return deferBecause(ctx, .reassign);
            },
            .if_stmt => |iff| {
                switch (try lowerIf(ctx, cur, &iff, locals)) {
                    .terminated => return .terminated,
                    .fallthrough => |join| cur = join,
                }
            },
            .while_stmt => |w| cur = try lowerWhile(ctx, cur, &w, locals),
            .for_stmt => |fr| {
                switch (try lowerFor(ctx, cur, &fr, locals)) {
                    .terminated => return .terminated,
                    .fallthrough => |exit| cur = exit,
                }
            },
            .switch_stmt => |sw| {
                switch (try lowerSwitch(ctx, cur, &sw, locals)) {
                    .terminated => return .terminated,
                    .fallthrough => |join| cur = join,
                }
            },
            .block => |b| {
                // A nested bare block is a lexical scope in the SAME control-flow path: its locals are
                // dropped at its end. (Also how the for-in desugaring nests the user's original body.)
                const mark = locals.items.len;
                switch (try lowerSeq(ctx, cur, b.statements, locals)) {
                    .terminated => return .terminated,
                    .fallthrough => |nb| {
                        cur = nb;
                        try dropScope(ctx, cur, locals, mark);
                    },
                }
            },
            .defer_stmt => {
                // `defer expr` / `errdefer expr` runs a cleanup at scope exit. In Nova that expression is
                // a BORROW (a method call like `x.close()`; there is no manual drop), so it has no
                // ownership effect on the locals we track — skip it. A bare-local reassignment inside a
                // defer would be the only concern, and that is as unmodelled as elsewhere -> defer then.
                if (isLocalReassign(&s.defer_stmt.expr, locals.items)) return deferBecause(ctx, .reassign);
            },
            .break_stmt => {
                const lp = ctx.loop orelse return deferBecause(ctx, .break_continue);
                try dropScope(ctx, cur, locals, lp.body_mark); // exit the loop scope
                ctx.f.setTerm(cur, .{ .br = lp.exit });
                return .terminated;
            },
            .continue_stmt => {
                const lp = ctx.loop orelse return deferBecause(ctx, .break_continue);
                try dropScope(ctx, cur, locals, lp.body_mark); // end this iteration's scope
                ctx.f.setTerm(cur, .{ .br = lp.header }); // back-edge
                return .terminated;
            },
        }
    }
    return .{ .fallthrough = cur };
}

/// `let name = init;` — record an owned binding. `let y = x` (x an owned local) is a dup (copy);
/// any other owned initializer is a fresh birth (locals it mentions are borrowed, so no consume here).
/// A trivial (non-owned) local is ignored.
fn lowerLet(ctx: *Ctx, block: ir.Block, ls: *const ast.LetStmt, locals: *Locals) LowerError!void {
    // Destructuring (`let {a, b} = …` / `let [a, b] = …`): we have no per-binding type here, so we do NOT
    // track the destructured names. That is SOUND — an untracked owned binding carries no balance
    // obligation, so the worst case is missing a leak (a false negative), never a false imbalance.
    if (ls.names != null) return;
    const init = ls.init orelse return;
    if (!isOwnedInit(ctx.store, ctx.tir, &init)) return; // trivial local: ignore
    const v = if (init.kind == .ident and resolveLocal(locals.items, init.kind.ident) != null)
        try ctx.f.copy(ctx.gpa, block, locals.items[resolveLocal(locals.items, init.kind.ident).?].value)
    else
        try ctx.f.makeOwned(ctx.gpa, block, ctx.tir.typeOf(&init));
    try locals.append(ctx.gpa, .{ .name = ls.name, .value = v, .live = true });
}

/// Lower an if/else. Branches get a CLONE of `locals` and are each their own lexical scope, so a
/// branch may now declare its own owned locals (dropped at the branch end). The join block is allocated
/// LAST so every edge is index-increasing. The caller's `locals` is unchanged (a fall-through branch
/// consumes no outer local — only a `return` does, and that terminates the branch).
fn lowerIf(ctx: *Ctx, entry_block: ir.Block, iff: *const ast.IfStmt, locals: *Locals) LowerError!Flow {
    const then_stmts = branchStmts(iff.then_branch) orelse return deferBecause(ctx, .nonblock_branch);
    const else_stmts: ?[]const ast.Statement = if (iff.else_branch) |e| (branchStmts(e) orelse return deferBecause(ctx, .nonblock_branch)) else null;

    const cond = try ctx.f.makeTrivial(ctx.gpa, entry_block, null);
    const then_block = try ctx.f.newBlock(ctx.gpa);
    const else_block: ?ir.Block = if (else_stmts != null) try ctx.f.newBlock(ctx.gpa) else null;

    var then_locals = try cloneLocals(ctx.gpa, locals);
    defer then_locals.deinit(ctx.gpa);
    const then_flow = try lowerBlockScope(ctx, then_block, then_stmts, &then_locals);

    var else_flow: ?Flow = null;
    if (else_stmts) |es| {
        var else_locals = try cloneLocals(ctx.gpa, locals);
        defer else_locals.deinit(ctx.gpa);
        else_flow = try lowerBlockScope(ctx, else_block.?, es, &else_locals);
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
        any_fallthrough = true; // no else: the else edge goes straight to join, carrying `locals`
    }

    return if (any_fallthrough) .{ .fallthrough = join_block } else .terminated;
}

/// The shared loop shape: entry -> header; header -cond-> body/exit; body -> header (back-edge). The
/// body is its own lexical scope on a CLONE of `locals`, so it may declare its own owned locals (dropped
/// at the end of each iteration) — which keeps the body-exit live set equal to the header entry set, the
/// verifier's back-edge requirement. The exit block is allocated LAST so only the back-edge decreases in
/// index. Returns the exit block.
fn lowerLoop(ctx: *Ctx, entry_block: ir.Block, body_stmts: []const ast.Statement, locals: *Locals) LowerError!ir.Block {
    const header = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(entry_block, .{ .br = header });
    const cond = try ctx.f.makeTrivial(ctx.gpa, header, null);
    const body_block = try ctx.f.newBlock(ctx.gpa);
    // The exit block is allocated NOW (before the body) so `break` can target it. Its index sits between
    // the body block and any nested blocks the body allocates; the verifier's edge logic (set on first
    // arrival via the header's cond-false edge, compare thereafter) handles both the forward break edge
    // and back edges uniformly, so the ordering is sound.
    const exit_block = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(header, .{ .cond_br = .{ .cond = cond, .then_blk = body_block, .else_blk = exit_block } });

    const saved = ctx.loop;
    ctx.loop = .{ .header = header, .exit = exit_block, .body_mark = locals.items.len };
    var body_locals = try cloneLocals(ctx.gpa, locals);
    defer body_locals.deinit(ctx.gpa);
    const body_flow = try lowerBlockScope(ctx, body_block, body_stmts, &body_locals);
    ctx.loop = saved;

    switch (body_flow) {
        .fallthrough => |b| ctx.f.setTerm(b, .{ .br = header }), // back-edge (normal iteration)
        .terminated => {},
    }
    return exit_block;
}

fn lowerWhile(ctx: *Ctx, entry_block: ir.Block, w: *const ast.WhileStmt, locals: *Locals) LowerError!ir.Block {
    const body_stmts = branchStmts(w.body) orelse return deferBecause(ctx, .nonblock_branch);
    return lowerLoop(ctx, entry_block, body_stmts, locals);
}

/// Lower a `for` loop, both the C-style `for (init; cond; incr)` and the `for (item in iterable)` form.
/// C-style: the init binding is scoped to the loop (dropped after); the increment is a trivial-counter
/// borrow (not modelled). For-in: the loop variable is a BORROW of an element (the iterable retains its
/// own storage), so it is not tracked — modelling it as a borrow is sound (it can only miss an owned
/// element leak, never invent a false imbalance). Either way the body is its own scope on a clone.
fn lowerFor(ctx: *Ctx, entry_block: ir.Block, fr: *const ast.ForStmt, locals: *Locals) LowerError!Flow {
    const body_stmts = branchStmts(fr.body) orelse return deferBecause(ctx, .nonblock_branch);

    if (fr.iterator != null) {
        // for-in: loop variable borrowed, no init/increment scope to drop.
        return .{ .fallthrough = try lowerLoop(ctx, entry_block, body_stmts, locals) };
    }

    const for_mark = locals.items.len;
    if (fr.initializer) |istmt| switch (istmt.*) {
        .let_stmt => |ls| try lowerLet(ctx, entry_block, &ls, locals),
        .expr_stmt => |es| if (isLocalReassign(&es.expr, locals.items)) return deferBecause(ctx, .reassign),
        else => return deferBecause(ctx, .other),
    };
    const exit_block = try lowerLoop(ctx, entry_block, body_stmts, locals);
    try dropScope(ctx, exit_block, locals, for_mark); // drop the loop variable if it was owned
    return .{ .fallthrough = exit_block };
}

/// Lower a `switch`. The discriminant is a borrow. Each case body and the default are their own lexical
/// scopes (on clones) that join afterwards; the verifier requires every joining predecessor's exit live
/// set to match. Cases with a guard (`case v if cond:`) fall through to default on guard-false, which is
/// a control-flow shape this slice does not model, so a guarded switch defers.
fn lowerSwitch(ctx: *Ctx, entry_block: ir.Block, sw: *const ast.SwitchStmt, locals: *Locals) LowerError!Flow {
    for (sw.cases) |c| if (c.guard != null) return deferBecause(ctx, .switch_guard);

    const case_blocks = try ctx.gpa.alloc(ir.Block, sw.cases.len);
    errdefer ctx.gpa.free(case_blocks);
    const case_flows = try ctx.gpa.alloc(Flow, sw.cases.len);
    defer ctx.gpa.free(case_flows);

    // Lower each case body into its own block+scope. Blocks are allocated before the join (below).
    for (sw.cases, 0..) |c, i| {
        const body_stmts = branchStmts(c.body) orelse return deferBecause(ctx, .nonblock_branch); // errdefer frees case_blocks
        case_blocks[i] = try ctx.f.newBlock(ctx.gpa);
        var case_locals = try cloneLocals(ctx.gpa, locals);
        defer case_locals.deinit(ctx.gpa);
        case_flows[i] = try lowerBlockScope(ctx, case_blocks[i], body_stmts, &case_locals);
    }

    // default (if present): its own block+scope.
    var default_block: ?ir.Block = null;
    var default_flow: Flow = .{ .fallthrough = undefined };
    var has_default_fallthrough = true; // no default => the no-match path falls straight to join
    if (sw.default_case) |dstmt| {
        const dstmts = branchStmts(dstmt) orelse return deferBecause(ctx, .nonblock_branch); // errdefer frees case_blocks
        default_block = try ctx.f.newBlock(ctx.gpa);
        var default_locals = try cloneLocals(ctx.gpa, locals);
        defer default_locals.deinit(ctx.gpa);
        default_flow = try lowerBlockScope(ctx, default_block.?, dstmts, &default_locals);
        has_default_fallthrough = (default_flow == .fallthrough);
    }

    const join_block = try ctx.f.newBlock(ctx.gpa); // highest index
    ctx.f.setTerm(entry_block, .{ .switch_br = .{ .cases = case_blocks, .default_blk = default_block orelse join_block } });

    var any_fallthrough = has_default_fallthrough;
    for (case_flows) |cf| switch (cf) {
        .fallthrough => |b| {
            ctx.f.setTerm(b, .{ .br = join_block });
            any_fallthrough = true;
        },
        .terminated => {},
    };
    if (default_block) |_| switch (default_flow) {
        .fallthrough => |b| ctx.f.setTerm(b, .{ .br = join_block }),
        .terminated => {},
    };

    return if (any_fallthrough) .{ .fallthrough = join_block } else .terminated;
}

/// Destroy the still-live locals THIS scope declared (index >= mark) in `block`, in reverse order, then
/// truncate them out of scope.
fn dropScope(ctx: *Ctx, block: ir.Block, locals: *Locals, mark: usize) !void {
    var i: usize = locals.items.len;
    while (i > mark) {
        i -= 1;
        if (locals.items[i].live) try ctx.f.destroy(ctx.gpa, block, locals.items[i].value);
    }
    locals.shrinkRetainingCapacity(mark);
}

/// Destroy every still-live local (all enclosing scopes) in `block`, except `keep` (returned). Used at
/// a `return`, which exits all scopes at once. Marks consumed locals dead.
fn dropAll(ctx: *Ctx, block: ir.Block, locals: *Locals, keep: ?usize) !void {
    var i: usize = locals.items.len;
    while (i > 0) {
        i -= 1;
        if (!locals.items[i].live) continue;
        if (keep != null and i == keep.?) continue;
        try ctx.f.destroy(ctx.gpa, block, locals.items[i].value);
        locals.items[i].live = false;
    }
    if (keep) |k| locals.items[k].live = false; // returned value consumed by the terminator
}

fn cloneLocals(gpa: std.mem.Allocator, locals: *const Locals) !Locals {
    var out: Locals = .empty;
    try out.appendSlice(gpa, locals.items);
    return out;
}

/// The statement list of a branch/body. A `{ … }` block yields its statements; a braceless single
/// statement (`if (c) return x;`) yields a one-element view of that statement (safe: it outlives lowering).
fn branchStmts(s: *const ast.Statement) ?[]const ast.Statement {
    return switch (s.*) {
        .block => |b| b.statements,
        else => @as([*]const ast.Statement, @ptrCast(s))[0..1],
    };
}

fn isOwnedInit(store: *const TypeStore, tir: *const TypedIr, e: *const ast.Expression) bool {
    if (tir.ownedOf(e)) |o| return o;
    const tid = tir.typeOf(e) orelse return false;
    return store.isOwnedSafe(tid);
}

/// Resolve a name to its local index, innermost (last-declared) shadow winning.
fn resolveLocal(locals: []const Local, want: []const u8) ?usize {
    var i: usize = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, want)) return i;
    }
    return null;
}

/// True if `e` is a bare assignment `local = ...` to a tracked owned local (which drops the old value —
/// a rebinding this slice does not yet model, so the caller defers it).
fn isLocalReassign(e: *const ast.Expression, locals: []const Local) bool {
    if (e.kind != .binary) return false;
    const b = e.kind.binary;
    if (b.op != .assign) return false;
    return b.left.kind == .ident and resolveLocal(locals, b.left.kind.ident) != null;
}

// A minimal name-mention check (idents only, recursive over common expression shapes), kept for the
// exprMentions helper used by tests.
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
    fwd_copies: usize = 0,
    fwd_candidates: usize = 0,
    defer_reasons: [5]usize = .{0} ** 5,
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
    std.debug.print(
        "  deferred breakdown: reassign={d} break/continue={d} switch-guard={d} nonblock-branch={d} other={d}\n",
        .{
            c.defer_reasons[@intFromEnum(DeferReason.reassign)],
            c.defer_reasons[@intFromEnum(DeferReason.break_continue)],
            c.defer_reasons[@intFromEnum(DeferReason.switch_guard)],
            c.defer_reasons[@intFromEnum(DeferReason.nonblock_branch)],
            c.defer_reasons[@intFromEnum(DeferReason.other)],
        },
    );
    std.debug.print(
        "  ownership-forwarding (Track A, E2-gated headroom):\n" ++
        "    owned-dup copies emitted : {d}\n" ++
        "    of those, forwardable    : {d}   (only borrowed+destroyed, never moved/returned)\n",
        .{ c.fwd_copies, c.fwd_candidates },
    );
    std.debug.print("=== end OSSA-lite lowering ===\n", .{});
}

fn lowerAndCheck(gpa: std.mem.Allocator, store: *const TypeStore, tir: *const TypedIr, fd: *const ast.FunctionDecl, c: *Counts) void {
    c.total += 1;
    const res = lowerFunction(gpa, store, tir, fd) catch {
        c.deferred += 1;
        return;
    };
    switch (res.outcome) {
        .deferred => {
            c.deferred += 1;
            c.defer_reasons[@intFromEnum(res.reason)] += 1;
        },
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
            const fc = forward.count(&f);
            c.fwd_copies += fc.copies;
            c.fwd_candidates += fc.candidates;
        },
    }
}

// ─────────────────────────────────────────── tests ───────────────────────────────────────────
// (Lowering needs a real TypedIr, which is heavy to construct in a unit test; end-to-end lowering is
//  exercised via the NOVA_OSSA corpus report. These tests cover the pure helpers.)

test "resolveLocal returns the innermost (last-declared) shadow" {
    const locals = [_]Local{
        .{ .name = "a", .value = @enumFromInt(0), .live = true },
        .{ .name = "b", .value = @enumFromInt(1), .live = true },
        .{ .name = "b", .value = @enumFromInt(2), .live = true }, // shadows the earlier b
    };
    try std.testing.expectEqual(@as(?usize, 2), resolveLocal(&locals, "b"));
    try std.testing.expectEqual(@as(?usize, 0), resolveLocal(&locals, "a"));
    try std.testing.expectEqual(@as(?usize, null), resolveLocal(&locals, "z"));
}
