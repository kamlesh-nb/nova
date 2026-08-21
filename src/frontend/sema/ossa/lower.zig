//! OSSA-lite lowering: turn a function's AST into an ownership-explicit,
//! basic-block IR so the release-balance verifier can PROVE that every owned
//! value is destroyed exactly once (no leak, no double-free).
//!
//! This is the front half of the `NOVA_OSSA` self-check. Codegen's real ARC is
//! decided elsewhere (`codegen/arc.zig`); this pass is a SEPARATE, conservative
//! model whose only job is to catch ownership imbalances at compile time. It
//! walks the typed AST, tracks the set of live owned locals in scope, and emits
//! an [`ir.Func`] made of blocks whose terminators encode control flow and
//! whose instructions are the ownership events that matter: `makeOwned` (a new
//! heap value is born), `copy` (an owned duplicate — an ARC retain of a fresh
//! reference), `borrowUse` (an owned value is read without transferring it),
//! and `destroy` (the ARC release). [`verify.verify`] then checks that along
//! every path each owned value reaches exactly one release. [`forward.count`]
//! separately tallies how many of the emitted copies are only ever
//! borrowed-then-destroyed (never moved or returned), which is headroom for a
//! later copy-elision optimisation.
//!
//! Key design decision: this is "OSSA-LITE" and it DEFERS rather than guesses.
//! Any construct whose ownership flow the model cannot represent soundly makes
//! the whole function bail out with [`Outcome.deferred`] and a [`DeferReason`],
//! instead of emitting an IR that might verify wrongly. A deferred function is
//! simply not checked; it is never reported as imbalanced. That is why the
//! coverage number (`lowered / total`) is a real metric — it is the slice of
//! the corpus the verifier actually vouches for. Deferral reasons include
//! `break`/`continue` outside a loop the model set up, a reassignment of a
//! local that pre-dates the current SSA "clone floor", `switch` cases with
//! guards, and non-block (single-statement) branch bodies.
//!
//! Ownership modelling, concretely. A scope is a stack of [`Local`]s (name +
//! [`ir.Value`] + a `live` flag). Only OWNED initialisers create a local
//! ([`isOwnedInit`] gates this); a plain-value `let x = 1` produces nothing to
//! track. Leaving a scope drops its locals in REVERSE declaration order
//! ([`dropScope`]), mirroring how ARC destructors run. `return x` moves `x` out
//! (`ret_owned`) and destroys every OTHER live local ([`dropAll`]).
//!
//! Control flow is where the SSA machinery earns its keep. Branches lower each
//! arm against a CLONE of the local stack ([`cloneLocals`]), then
//! [`reconcileJoin`] merges the arms at the join block: a local that kept the
//! same value in every arm passes through unchanged, one that diverged gets a
//! phi node, one that died in every arm becomes dead, and one that died in SOME
//! but not all arms is unrepresentable and DEFERS. Loops ([`lowerLoop`])
//! pre-scan the body for reassigned outer locals ([`collectReassignedOuter`]),
//! seed a header phi for each, and patch the phi inputs afterwards from the
//! back-edge and every recorded `continue`/`break` edge. When the loop body
//! reassigns NOTHING, no header phis are needed and a `clone_floor` is set
//! instead so that any attempt to reassign an outer local still defers rather
//! than silently corrupting the value model.
//!
//! Entry points: [`lowerFunction`] lowers one function; [`report`] /
//! [`reportQuiet`] lower every function in a program, run the verifier and
//! forwarding census, and (in `hard` mode) FAIL THE BUILD with a non-zero exit
//! if any lowered function is imbalanced. This is what the `NOVA_OSSA` gate
//! calls.

const std = @import("std");
/// Nova AST node definitions: the `Statement`/`Expression` shapes this pass walks.
const ast = @import("../../ast.zig");
/// The type engine. Used only for [`TypeStore.isOwnedSafe`], the fallback that
/// decides whether an initialiser produces an ARC-owned value.
const types = @import("../../types.zig");
/// The inference pass output ([`TypedIr`]): per-expression type and ownership
/// answers this pass consults but never mutates.
const infer = @import("../infer.zig");
/// The ownership-explicit IR built here: [`ir.Func`], [`ir.Block`],
/// [`ir.Value`], phi nodes, and the ownership instructions (copy/borrow/destroy).
const ir = @import("ir.zig");
/// The release-balance checker run over each lowered [`ir.Func`]; a function is
/// "balanced" iff every owned value is released exactly once on every path.
const verify = @import("verify.zig");
/// The copy-forwarding census: counts owned copies that are only borrowed and
/// destroyed, i.e. candidates a future copy-elision pass could remove.
const forward = @import("forward.zig");

/// Local alias for the immutable type table consulted during lowering.
const TypeStore = types.TypeStore;
/// Local alias for the inference result carrying per-expression type/ownership.
const TypedIr = infer.TypedIr;

/// Result of trying to lower one function: either the model built an IR we can
/// verify, or it gave up because some construct is outside the lite model.
pub const Outcome = enum { lowered, deferred };

/// Outcome of [`lowerFunction`] with its payload.
///
/// On `.lowered`, `func` holds an [`ir.Func`] the caller now OWNS and must
/// `deinit`. On `.deferred`, `func` is null and `reason` says why the model
/// bailed out (used for the census breakdown, never surfaced as an error).
pub const LowerResult = struct {
    /// Whether an IR was produced (`.lowered`) or the function was skipped.
    outcome: Outcome,
    /// The built IR on success; null when deferred. Caller-owned when present.
    func: ?ir.Func = null,
    /// Why lowering deferred; only meaningful when `outcome == .deferred`.
    reason: DeferReason = .other,
};

/// Internal error set for the lowering walk.
///
/// `error.Defer` is a control-flow signal, not a real failure: it unwinds the
/// recursive lowering back to [`lowerFunction`], which converts it to
/// [`Outcome.deferred`] using the reason stashed in [`Ctx.defer_reason`].
/// `error.OutOfMemory` propagates as a genuine allocation failure.
const LowerError = error{ Defer, OutOfMemory };

/// How a lowered statement sequence left the current block.
///
/// `terminated` means the block already has a terminator (a `return`, `break`,
/// `continue`, or a nested construct that itself terminated) so nothing more
/// may be appended. `fallthrough` carries the block execution continues into,
/// which the caller keeps threading subsequent statements onto.
const Flow = union(enum) {
    /// The block ended with a terminator; no successor to append to.
    terminated,
    /// Execution continues in this block.
    fallthrough: ir.Block,
};

/// One tracked owned local: its source name, its current SSA [`ir.Value`], and
/// whether it is still live (a moved-out or dropped local becomes `live=false`).
const Local = struct { name: []const u8, value: ir.Value, live: bool };
/// A scope stack of [`Local`]s. Innermost declarations sit at the end, so
/// [`resolveLocal`] scans from the back to honour shadowing.
const Locals = std.ArrayListUnmanaged(Local);

/// Why the lite model refused to lower a function, for the census breakdown.
///
/// Each variant marks a construct whose ownership flow the model cannot
/// represent soundly: `reassign` (a local reassigned below the SSA clone floor),
/// `break_continue` (a jump with no enclosing loop context set up),
/// `switch_guard` (a guarded `case` the model does not evaluate),
/// `nonblock_branch` (a single-statement branch body it declines to wrap), and
/// `other` (everything else, e.g. an exotic `for` initialiser).
pub const DeferReason = enum { reassign, break_continue, switch_guard, nonblock_branch, other };

/// A recorded phi contribution from one predecessor edge: the source block and
/// the value of each phi-tracked local at that edge, indexed parallel to
/// [`LoopCtx.phi_locals`]. Used to patch loop header/exit phis after the body
/// is lowered. The `values` slice is heap-owned and freed by [`lowerLoop`].
const PhiEdge = struct { block: ir.Block, values: []ir.Value };

/// The active loop's lowering context, threaded via [`Ctx.loop`] so that
/// `break`/`continue` inside the body know where to jump, which locals need
/// phis, and where to record their edge values.
const LoopCtx = struct {
    /// Block a `continue` branches to (the loop condition header).
    header: ir.Block,
    /// Block a `break` branches to (the loop exit).
    exit: ir.Block,
    /// Scope depth at loop entry; `break`/`continue` drop locals down to here
    /// before jumping, matching the scopes they exit.
    body_mark: usize,
    /// Indices (into the outer local stack) of locals that get a header phi
    /// because the loop body reassigns them; empty when no phi is needed.
    phi_locals: []const usize = &.{},
    /// Accumulates one [`PhiEdge`] per `continue`, feeding the header phis.
    continue_edges: ?*std.ArrayListUnmanaged(PhiEdge) = null,
    /// Accumulates one [`PhiEdge`] per `break`, feeding the exit phis.
    break_edges: ?*std.ArrayListUnmanaged(PhiEdge) = null,
};

/// Mutable lowering state threaded through the whole recursive walk of one
/// function. Holds the allocator, the read-only type/inference inputs, the IR
/// being built, and the transient bits (`defer_reason`, `loop`, `clone_floor`)
/// that record why we might defer and how loops constrain reassignment.
const Ctx = struct {
    /// Allocator for all IR and scratch structures for this function.
    gpa: std.mem.Allocator,
    /// Immutable type table, for the owned-value fallback in [`isOwnedInit`].
    store: *const TypeStore,
    /// Immutable inference result: per-expression types and ownership answers.
    tir: *const TypedIr,
    /// The function IR being constructed.
    f: *ir.Func,
    /// Reason stashed by [`deferBecause`] just before `error.Defer` unwinds, so
    /// [`lowerFunction`] can report it.
    defer_reason: DeferReason = .other,
    /// The enclosing loop's context, or null outside any loop.
    loop: ?LoopCtx = null,
    /// SSA barrier: locals whose index is below this may not be reassigned in
    /// the current region (set for phi-free loop bodies). A reassignment below
    /// it defers with [`DeferReason.reassign`] rather than corrupt the model.
    clone_floor: usize = 0,
};

/// Records `reason` on `ctx` and returns `error.Defer` to unwind lowering.
///
/// Centralises the "give up on this function" path so the reason is always set
/// atomically with the signal; callers write `return deferBecause(ctx, .x)`.
fn deferBecause(ctx: *Ctx, reason: DeferReason) LowerError {
    ctx.defer_reason = reason;
    return error.Defer;
}

/// Lower a single function to ownership-explicit IR, or defer it.
///
/// Builds an [`ir.Func`] with an entry block, lowers the body, and if the body
/// falls through without an explicit return terminates it with `ret_void`. If
/// the walk hits an unmodelable construct it catches `error.Defer`, tears down
/// the partially built IR, and returns [`Outcome.deferred`] with the stashed
/// reason. On success the returned `func` is caller-owned (`deinit` it).
///
/// Non-`Defer` errors (only `OutOfMemory`) propagate to the caller.
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

/// Lower a nested lexical scope: run its statements, then drop the locals it
/// introduced (in reverse order) on the fallthrough path before returning.
///
/// The reverse drop at `mark` mirrors ARC destructor order. When the scope
/// terminated (returned/broke), the drops were already handled by that
/// terminator's own path, so nothing is dropped here. See [`dropScope`].
fn lowerBlockScope(ctx: *Ctx, block: ir.Block, stmts: []const ast.Statement, locals: *Locals) LowerError!Flow {
    const mark = locals.items.len;
    switch (try lowerSeq(ctx, block, stmts, locals)) {
        .terminated => return .terminated,
        .fallthrough => |b| {
            try dropScope(ctx, b, locals, mark);
            return .{ .fallthrough = b };
        },
    }
}

/// Lower a flat statement list, threading the "current block" forward.
///
/// This is the core dispatcher. Each statement kind updates `cur` (the block
/// subsequent statements attach to) or returns `.terminated` when it ends the
/// flow. Notable cases: `return` moves an identifier operand out via `ret_owned`
/// and drops all other live locals ([`dropAll`]); an assignment statement is
/// detected as a local reassignment ([`isLocalReassign`]) and handled by
/// [`lowerReassign`], otherwise its owned sub-reads are emitted with
/// [`emitOwnedUses`]; `break`/`continue` consult [`Ctx.loop`] (deferring if
/// absent), record their phi edge, drop the scope back to the loop body mark,
/// and terminate. A `defer` statement is modelled only for its reassignment
/// side effect (its scheduling is not part of the lite model).
fn lowerSeq(ctx: *Ctx, block: ir.Block, stmts: []const ast.Statement, locals: *Locals) LowerError!Flow {
    var cur = block;
    for (stmts) |*s| {
        switch (s.*) {
            .let_stmt => |ls| try lowerLet(ctx, cur, &ls, locals),
            .return_stmt => |r| {
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
                if (isLocalReassign(&es.expr, locals.items)) {
                    try emitOwnedUses(ctx, cur, es.expr.kind.binary.right, locals);
                    try lowerReassign(ctx, cur, &es.expr, locals);
                } else {
                    try emitOwnedUses(ctx, cur, &es.expr, locals);
                }
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
                if (isLocalReassign(&s.defer_stmt.expr, locals.items)) try lowerReassign(ctx, cur, &s.defer_stmt.expr, locals);
            },
            .break_stmt => {
                const lp = ctx.loop orelse return deferBecause(ctx, .break_continue);
                if (lp.break_edges) |edges| try recordPhiEdge(ctx, edges, cur, lp.phi_locals, locals);
                try dropScope(ctx, cur, locals, lp.body_mark);
                ctx.f.setTerm(cur, .{ .br = lp.exit });
                return .terminated;
            },
            .continue_stmt => {
                const lp = ctx.loop orelse return deferBecause(ctx, .break_continue);
                if (lp.continue_edges) |edges| try recordPhiEdge(ctx, edges, cur, lp.phi_locals, locals);
                try dropScope(ctx, cur, locals, lp.body_mark);
                ctx.f.setTerm(cur, .{ .br = lp.header });
                return .terminated;
            },
        }
    }
    return .{ .fallthrough = cur };
}

/// Lower a `let` binding, tracking a new owned local when the initialiser owns.
///
/// Destructuring binds (`ls.names != null`) and bindings without an initialiser
/// are ignored. A non-owned initialiser tracks nothing but still emits its owned
/// sub-reads (a temporary borrowed inside it must be accounted for). An
/// initialiser that is itself a live local is an owned COPY (ARC retain of a
/// fresh reference, borrowing the source first); any other owned initialiser
/// mints a fresh `makeOwned` value. The new [`Local`] is pushed live.
fn lowerLet(ctx: *Ctx, block: ir.Block, ls: *const ast.LetStmt, locals: *Locals) LowerError!void {
    if (ls.names != null) return;
    const init = ls.init orelse return;
    if (!isOwnedInit(ctx.store, ctx.tir, &init)) {
        try emitOwnedUses(ctx, block, &init, locals);
        return;
    }
    const v = if (init.kind == .ident and resolveLocal(locals.items, init.kind.ident) != null) blk: {
        const src = locals.items[resolveLocal(locals.items, init.kind.ident).?].value;
        if (ctx.f.ownershipOf(src) == .owned) try ctx.f.borrowUse(ctx.gpa, block, src);
        break :blk try ctx.f.copy(ctx.gpa, block, src);
    } else blk: {
        try emitOwnedUses(ctx, block, &init, locals);
        break :blk try ctx.f.makeOwned(ctx.gpa, block, ctx.tir.typeOf(&init));
    };
    try locals.append(ctx.gpa, .{ .name = ls.name, .value = v, .live = true });
}

/// Lower an `if`/`else` into a diamond and reconcile the arms at a join block.
///
/// Both branch bodies must be block statements (a non-block branch defers). Each
/// arm is lowered against its OWN clone of the local stack ([`cloneLocals`]) so
/// their divergent value/liveness views do not interfere. The entry block ends
/// in a `cond_br`; every arm that falls through branches to a fresh join block
/// and contributes a [`JoinPred`]. With no `else`, the entry block itself is the
/// fall-through predecessor. [`reconcileJoin`] then installs phis / propagates
/// liveness across the outer locals. If no arm falls through, the whole `if`
/// terminates.
fn lowerIf(ctx: *Ctx, entry_block: ir.Block, iff: *const ast.IfStmt, locals: *Locals) LowerError!Flow {
    const then_stmts = branchStmts(iff.then_branch) orelse return deferBecause(ctx, .nonblock_branch);
    const else_stmts: ?[]const ast.Statement = if (iff.else_branch) |e| (branchStmts(e) orelse return deferBecause(ctx, .nonblock_branch)) else null;

    const n_outer = locals.items.len;
    const cond = try ctx.f.makeTrivial(ctx.gpa, entry_block, null);
    const then_block = try ctx.f.newBlock(ctx.gpa);
    const else_block: ?ir.Block = if (else_stmts != null) try ctx.f.newBlock(ctx.gpa) else null;

    var then_locals = try cloneLocals(ctx.gpa, locals);
    defer then_locals.deinit(ctx.gpa);
    const then_flow = try lowerBlockScope(ctx, then_block, then_stmts, &then_locals);

    var else_locals: ?Locals = if (else_stmts != null) try cloneLocals(ctx.gpa, locals) else null;
    defer if (else_locals) |*el| el.deinit(ctx.gpa);
    var else_flow: ?Flow = null;
    if (else_stmts) |es| else_flow = try lowerBlockScope(ctx, else_block.?, es, &else_locals.?);

    const join_block = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(entry_block, .{ .cond_br = .{ .cond = cond, .then_blk = then_block, .else_blk = else_block orelse join_block } });

    var preds: [2]JoinPred = undefined;
    var npreds: usize = 0;
    switch (then_flow) {
        .fallthrough => |b| {
            ctx.f.setTerm(b, .{ .br = join_block });
            preds[npreds] = .{ .block = b, .vals = then_locals.items };
            npreds += 1;
        },
        .terminated => {},
    }
    if (else_flow) |ef| {
        switch (ef) {
            .fallthrough => |b| {
                ctx.f.setTerm(b, .{ .br = join_block });
                preds[npreds] = .{ .block = b, .vals = else_locals.?.items };
                npreds += 1;
            },
            .terminated => {},
        }
    } else {
        preds[npreds] = .{ .block = entry_block, .vals = locals.items };
        npreds += 1;
    }

    if (npreds == 0) return .terminated;

    try reconcileJoin(ctx, join_block, locals, n_outer, preds[0..npreds]);
    return .{ .fallthrough = join_block };
}

/// One predecessor arriving at a join block: the block it arrives from and that
/// arm's snapshot of the local stack, read index-parallel by [`reconcileJoin`].
const JoinPred = struct { block: ir.Block, vals: []const Local };

/// Merge branch/switch arms at `join_block`, updating the outer local stack.
///
/// For each of the first `n_outer` locals (the ones that existed before the
/// branch), it inspects that local across every predecessor:
///   - dead in all arms  -> mark dead, no phi;
///   - dead in some arms  -> unrepresentable, DEFER with [`DeferReason.reassign`];
///   - live and identical value in all arms -> pass the value through;
///   - live but divergent  -> add a phi over the predecessors and adopt it.
/// The "dead in some" case defers because a value released on one path but not
/// another cannot be modelled as a single owned local without risking a
/// double-free or leak the verifier would then miscount.
fn reconcileJoin(ctx: *Ctx, join_block: ir.Block, locals: *Locals, n_outer: usize, preds: []const JoinPred) LowerError!void {
    var i: usize = 0;
    while (i < n_outer) : (i += 1) {
        var all_same_value = true;
        var any_live = false;
        var all_live = true;
        for (preds) |p| {
            const l = p.vals[i];
            if (l.value != preds[0].vals[i].value) all_same_value = false;
            if (l.live) any_live = true else all_live = false;
        }
        if (!any_live) {
            locals.items[i].live = false;
            continue;
        }
        if (!all_live) return deferBecause(ctx, .reassign);
        if (all_same_value) {
            locals.items[i].value = preds[0].vals[i].value;
            locals.items[i].live = true;
            continue;
        }
        const inputs = try ctx.gpa.alloc(ir.PhiInput, preds.len);
        defer ctx.gpa.free(inputs);
        for (preds, 0..) |p, k| inputs[k] = .{ .pred = p.block, .value = p.vals[i].value };
        const result = try ctx.f.addPhi(ctx.gpa, join_block, inputs, null);
        locals.items[i].value = result;
        locals.items[i].live = true;
    }
}

/// Snapshot the phi-tracked locals at a `break`/`continue` edge for later patch.
///
/// Allocates a values array parallel to `phi_locals` (freed when [`lowerLoop`]
/// tears down its edge lists) and appends a [`PhiEdge`]. A no-op when the loop
/// tracks no phi locals.
fn recordPhiEdge(ctx: *Ctx, edges: *std.ArrayListUnmanaged(PhiEdge), block: ir.Block, phi_locals: []const usize, locals: *Locals) !void {
    if (phi_locals.len == 0) return;
    const values = try ctx.gpa.alloc(ir.Value, phi_locals.len);
    errdefer ctx.gpa.free(values);
    for (phi_locals, 0..) |li, k| values[k] = locals.items[li].value;
    try edges.append(ctx.gpa, .{ .block = block, .values = values });
}

/// Append `v` to `out` only if not already present (a set-insert over a list).
///
/// Keeps the reassigned-locals list free of duplicates so each such local gets
/// exactly one header phi.
fn addUnique(out: *std.ArrayListUnmanaged(usize), v: usize, gpa: std.mem.Allocator) !void {
    for (out.items) |e| if (e == v) return;
    try out.append(gpa, v);
}

/// If `e` reassigns an OUTER local (index `< n_outer`), return that index.
///
/// Returns null when `e` is not a local reassignment, or when it reassigns a
/// local introduced inside the loop body (index `>= n_outer`), since only outer
/// locals need a header phi. See [`isLocalReassign`] and [`collectReassignedOuter`].
fn reassignTargetIdx(e: *const ast.Expression, locals: []const Local, n_outer: usize) ?usize {
    if (!isLocalReassign(e, locals)) return null;
    const idx = resolveLocal(locals, e.kind.binary.left.kind.ident).?;
    return if (idx < n_outer) idx else null;
}

/// Recursively collect the outer locals a loop body reassigns anywhere within.
///
/// Walks the body (descending into nested `if`/`block`/`while`/`for`/`switch`
/// bodies) and records the index of every outer local that is the target of an
/// assignment, via [`addUnique`]. Run BEFORE lowering the loop so the header can
/// pre-create a phi for each such local ([`lowerLoop`]); an outer local that the
/// body never reassigns keeps its entry value and needs no phi.
fn collectReassignedOuter(gpa: std.mem.Allocator, stmts: []const ast.Statement, locals: []const Local, n_outer: usize, out: *std.ArrayListUnmanaged(usize)) !void {
    for (stmts) |*s| switch (s.*) {
        .expr_stmt => |es| if (reassignTargetIdx(&es.expr, locals, n_outer)) |i| try addUnique(out, i, gpa),
        .defer_stmt => |d| if (reassignTargetIdx(&d.expr, locals, n_outer)) |i| try addUnique(out, i, gpa),
        .if_stmt => |iff| {
            if (branchStmts(iff.then_branch)) |ts| try collectReassignedOuter(gpa, ts, locals, n_outer, out);
            if (iff.else_branch) |e| if (branchStmts(e)) |els| try collectReassignedOuter(gpa, els, locals, n_outer, out);
        },
        .block => |b| try collectReassignedOuter(gpa, b.statements, locals, n_outer, out),
        .while_stmt => |w| if (branchStmts(w.body)) |bs| try collectReassignedOuter(gpa, bs, locals, n_outer, out),
        .for_stmt => |fr| if (branchStmts(fr.body)) |bs| try collectReassignedOuter(gpa, bs, locals, n_outer, out),
        .switch_stmt => |sw| {
            for (sw.cases) |c| if (branchStmts(c.body)) |cs| try collectReassignedOuter(gpa, cs, locals, n_outer, out);
            if (sw.default_case) |d| if (branchStmts(d)) |ds| try collectReassignedOuter(gpa, ds, locals, n_outer, out);
        },
        else => {},
    };
}

/// Lower a loop (the shared engine behind `while` and `for`) to header/body/exit
/// blocks with SSA phis, returning the exit block.
///
/// Structure: entry branches to a `header` whose `cond_br` goes to `body` or
/// `exit`. Before lowering the body it scans for reassigned outer locals
/// ([`collectReassignedOuter`]); each gets a header phi seeded with a
/// placeholder (entry value only) so the body sees a proper loop-variant value.
/// The body is lowered against a clone of the locals under a [`LoopCtx`] that
/// captures `break`/`continue` edges. Afterwards the header phis are finalised
/// from the entry value, the normal back-edge (if the body fell through), and
/// each recorded `continue` edge; if there were `break`s, an exit phi merges the
/// header value with every break edge so the outer locals are correct after the
/// loop.
///
/// When the body reassigns NOTHING, no phis are made; instead `clone_floor` is
/// raised to `n_outer` so a reassignment of any outer local inside the body will
/// [`deferBecause`] [`DeferReason.reassign`] rather than mutate a value the model
/// assumed loop-invariant.
fn lowerLoop(ctx: *Ctx, entry_block: ir.Block, body_stmts: []const ast.Statement, locals: *Locals) LowerError!ir.Block {
    const header = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(entry_block, .{ .br = header });
    const cond = try ctx.f.makeTrivial(ctx.gpa, header, null);
    const body_block = try ctx.f.newBlock(ctx.gpa);
    const exit_block = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(header, .{ .cond_br = .{ .cond = cond, .then_blk = body_block, .else_blk = exit_block } });

    const n_outer = locals.items.len;
    var reassigned = std.ArrayListUnmanaged(usize).empty;
    defer reassigned.deinit(ctx.gpa);
    try collectReassignedOuter(ctx.gpa, body_stmts, locals.items, n_outer, &reassigned);
    const use_phi = reassigned.items.len > 0;

    var continue_edges = std.ArrayListUnmanaged(PhiEdge).empty;
    var break_edges = std.ArrayListUnmanaged(PhiEdge).empty;
    defer {
        for (continue_edges.items) |e| ctx.gpa.free(e.values);
        for (break_edges.items) |e| ctx.gpa.free(e.values);
        continue_edges.deinit(ctx.gpa);
        break_edges.deinit(ctx.gpa);
    }

    const x0s = try ctx.gpa.alloc(ir.Value, reassigned.items.len);
    defer ctx.gpa.free(x0s);
    if (use_phi) {
        for (reassigned.items, 0..) |i, k| {
            x0s[k] = locals.items[i].value;
            const placeholder = [_]ir.PhiInput{.{ .pred = entry_block, .value = x0s[k] }};
            const r = try ctx.f.addPhi(ctx.gpa, header, &placeholder, null);
            locals.items[i].value = r;
            locals.items[i].live = true;
        }
    }

    const saved = ctx.loop;
    ctx.loop = .{
        .header = header,
        .exit = exit_block,
        .body_mark = n_outer,
        .phi_locals = reassigned.items,
        .continue_edges = &continue_edges,
        .break_edges = &break_edges,
    };
    const saved_floor = ctx.clone_floor;
    if (!use_phi) ctx.clone_floor = n_outer;

    var body_locals = try cloneLocals(ctx.gpa, locals);
    defer body_locals.deinit(ctx.gpa);
    const body_flow = try lowerBlockScope(ctx, body_block, body_stmts, &body_locals);
    ctx.clone_floor = saved_floor;
    ctx.loop = saved;

    const normal_back: ?ir.Block = switch (body_flow) {
        .fallthrough => |b| blk: {
            ctx.f.setTerm(b, .{ .br = header });
            break :blk b;
        },
        .terminated => null,
    };

    if (use_phi) {
        var hinputs = std.ArrayListUnmanaged(ir.PhiInput).empty;
        defer hinputs.deinit(ctx.gpa);
        for (reassigned.items, 0..) |i, k| {
            hinputs.clearRetainingCapacity();
            try hinputs.append(ctx.gpa, .{ .pred = entry_block, .value = x0s[k] });
            if (normal_back) |b| try hinputs.append(ctx.gpa, .{ .pred = b, .value = body_locals.items[i].value });
            for (continue_edges.items) |e| try hinputs.append(ctx.gpa, .{ .pred = e.block, .value = e.values[k] });
            try ctx.f.setPhiInputs(ctx.gpa, header, k, hinputs.items);
        }
        if (break_edges.items.len > 0) {
            var einputs = std.ArrayListUnmanaged(ir.PhiInput).empty;
            defer einputs.deinit(ctx.gpa);
            for (reassigned.items, 0..) |i, k| {
                einputs.clearRetainingCapacity();
                try einputs.append(ctx.gpa, .{ .pred = header, .value = locals.items[i].value });
                for (break_edges.items) |e| try einputs.append(ctx.gpa, .{ .pred = e.block, .value = e.values[k] });
                const r = try ctx.f.addPhi(ctx.gpa, exit_block, einputs.items, null);
                locals.items[i].value = r;
                locals.items[i].live = true;
            }
        }
    }
    return exit_block;
}

/// Lower a `while` by delegating to [`lowerLoop`] with its body statements.
///
/// Defers if the body is not a block ([`DeferReason.nonblock_branch`]).
fn lowerWhile(ctx: *Ctx, entry_block: ir.Block, w: *const ast.WhileStmt, locals: *Locals) LowerError!ir.Block {
    const body_stmts = branchStmts(w.body) orelse return deferBecause(ctx, .nonblock_branch);
    return lowerLoop(ctx, entry_block, body_stmts, locals);
}

/// Lower a `for` loop, handling both iterator-style and C-style forms.
///
/// An iterator `for` (`fr.iterator != null`) is just a loop over the body. A
/// C-style `for` first lowers its initialiser (a `let` introduces a scoped
/// local, or an assignment reassigns one; any other init form defers), runs the
/// loop, then drops the initialiser's local scope on exit ([`dropScope`]). The
/// loop condition/step themselves are not modelled beyond the body; this pass
/// only cares about ownership events.
fn lowerFor(ctx: *Ctx, entry_block: ir.Block, fr: *const ast.ForStmt, locals: *Locals) LowerError!Flow {
    const body_stmts = branchStmts(fr.body) orelse return deferBecause(ctx, .nonblock_branch);

    if (fr.iterator != null) {
        return .{ .fallthrough = try lowerLoop(ctx, entry_block, body_stmts, locals) };
    }

    const for_mark = locals.items.len;
    if (fr.initializer) |istmt| switch (istmt.*) {
        .let_stmt => |ls| try lowerLet(ctx, entry_block, &ls, locals),
        .expr_stmt => |es| if (isLocalReassign(&es.expr, locals.items)) try lowerReassign(ctx, entry_block, &es.expr, locals),
        else => return deferBecause(ctx, .other),
    };
    const exit_block = try lowerLoop(ctx, entry_block, body_stmts, locals);
    try dropScope(ctx, exit_block, locals, for_mark);
    return .{ .fallthrough = exit_block };
}

/// Lower a `switch` into a `switch_br` fanning out to per-case blocks, then
/// reconcile every fall-through case at a shared join.
///
/// Guarded cases defer up front ([`DeferReason.switch_guard`]) because the model
/// does not evaluate guards. Each case (and the optional default) is lowered
/// against its own clone of the locals; cases that fall through contribute a
/// [`JoinPred`]. With no default, the entry block is added as a pass-through
/// predecessor (the "no case matched" path). [`reconcileJoin`] merges them. If
/// no case and no default falls through, the switch terminates.
fn lowerSwitch(ctx: *Ctx, entry_block: ir.Block, sw: *const ast.SwitchStmt, locals: *Locals) LowerError!Flow {
    for (sw.cases) |c| if (c.guard != null) return deferBecause(ctx, .switch_guard);

    const n_outer = locals.items.len;
    const case_blocks = try ctx.gpa.alloc(ir.Block, sw.cases.len);
    errdefer ctx.gpa.free(case_blocks);
    const case_flows = try ctx.gpa.alloc(Flow, sw.cases.len);
    defer ctx.gpa.free(case_flows);

    const case_locals_arr = try ctx.gpa.alloc(Locals, sw.cases.len);
    for (case_locals_arr) |*cl| cl.* = .empty;
    defer {
        for (case_locals_arr) |*cl| cl.deinit(ctx.gpa);
        ctx.gpa.free(case_locals_arr);
    }

    for (sw.cases, 0..) |c, i| {
        const body_stmts = branchStmts(c.body) orelse return deferBecause(ctx, .nonblock_branch);
        case_blocks[i] = try ctx.f.newBlock(ctx.gpa);
        case_locals_arr[i] = try cloneLocals(ctx.gpa, locals);
        case_flows[i] = try lowerBlockScope(ctx, case_blocks[i], body_stmts, &case_locals_arr[i]);
    }

    var default_block: ?ir.Block = null;
    var default_flow: Flow = .{ .fallthrough = undefined };
    var default_locals: ?Locals = null;
    defer if (default_locals) |*dl| dl.deinit(ctx.gpa);
    if (sw.default_case) |dstmt| {
        const dstmts = branchStmts(dstmt) orelse return deferBecause(ctx, .nonblock_branch);
        default_block = try ctx.f.newBlock(ctx.gpa);
        default_locals = try cloneLocals(ctx.gpa, locals);
        default_flow = try lowerBlockScope(ctx, default_block.?, dstmts, &default_locals.?);
    }

    const join_block = try ctx.f.newBlock(ctx.gpa);
    ctx.f.setTerm(entry_block, .{ .switch_br = .{ .cases = case_blocks, .default_blk = default_block orelse join_block } });

    var preds = std.ArrayListUnmanaged(JoinPred).empty;
    defer preds.deinit(ctx.gpa);
    for (case_flows, 0..) |cf, i| switch (cf) {
        .fallthrough => |b| {
            ctx.f.setTerm(b, .{ .br = join_block });
            try preds.append(ctx.gpa, .{ .block = b, .vals = case_locals_arr[i].items });
        },
        .terminated => {},
    };
    if (default_block) |_| {
        switch (default_flow) {
            .fallthrough => |b| {
                ctx.f.setTerm(b, .{ .br = join_block });
                try preds.append(ctx.gpa, .{ .block = b, .vals = default_locals.?.items });
            },
            .terminated => {},
        }
    } else {
        try preds.append(ctx.gpa, .{ .block = entry_block, .vals = locals.items });
    }

    if (preds.items.len == 0) return .terminated;
    try reconcileJoin(ctx, join_block, locals, n_outer, preds.items);
    return .{ .fallthrough = join_block };
}

/// Destroy and pop every live local above `mark`, in reverse declaration order.
///
/// Emits a `destroy` (ARC release) for each still-live local introduced since
/// `mark`, newest first, then shrinks the stack back to `mark`. This is the ARC
/// end-of-scope drop; dead locals (moved out or already dropped) are skipped.
fn dropScope(ctx: *Ctx, block: ir.Block, locals: *Locals, mark: usize) !void {
    var i: usize = locals.items.len;
    while (i > mark) {
        i -= 1;
        if (locals.items[i].live) try ctx.f.destroy(ctx.gpa, block, locals.items[i].value);
    }
    locals.shrinkRetainingCapacity(mark);
}

/// Destroy every live local except an optional `keep`, marking them all dead.
///
/// Used at `return`: all locals go out of scope, but the returned value (if it
/// is a local, identified by `keep`) is MOVED out rather than destroyed, so it
/// is skipped and then marked dead so no later drop touches it. Unlike
/// [`dropScope`] this does not pop the stack, only flips liveness, because the
/// enclosing scopes are being unwound by the terminating return.
fn dropAll(ctx: *Ctx, block: ir.Block, locals: *Locals, keep: ?usize) !void {
    var i: usize = locals.items.len;
    while (i > 0) {
        i -= 1;
        if (!locals.items[i].live) continue;
        if (keep != null and i == keep.?) continue;
        try ctx.f.destroy(ctx.gpa, block, locals.items[i].value);
        locals.items[i].live = false;
    }
    if (keep) |k| locals.items[k].live = false;
}

/// Return a fresh, independent copy of the local stack.
///
/// Each branch/case/loop-body is lowered against its own clone so the value and
/// liveness edits it makes stay local until [`reconcileJoin`] (or the loop phi
/// patching) deliberately merges them back into the outer stack.
fn cloneLocals(gpa: std.mem.Allocator, locals: *const Locals) !Locals {
    var out: Locals = .empty;
    try out.appendSlice(gpa, locals.items);
    return out;
}

/// View a branch/loop/case body as a statement slice.
///
/// If the body is a `{ ... }` block, returns its statements. Otherwise the body
/// is a single statement and this returns a one-element slice aliasing it via a
/// pointer cast, so single-statement and block bodies are handled uniformly.
/// Never returns null in practice; the optional return keeps the `orelse
/// deferBecause(.nonblock_branch)` call sites uniform.
fn branchStmts(s: *const ast.Statement) ?[]const ast.Statement {
    return switch (s.*) {
        .block => |b| b.statements,
        else => @as([*]const ast.Statement, @ptrCast(s))[0..1],
    };
}

/// Decide whether an initialiser produces an ARC-OWNED value worth tracking.
///
/// Prefers the inference pass's per-expression answer ([`TypedIr.ownedOf`]);
/// when inference has no opinion it falls back to the value's type via
/// [`TypeStore.isOwnedSafe`]. A non-owned initialiser (a plain int, a borrow)
/// creates no tracked local. An unknown type is treated as not owned.
fn isOwnedInit(store: *const TypeStore, tir: *const TypedIr, e: *const ast.Expression) bool {
    if (tir.ownedOf(e)) |o| return o;
    const tid = tir.typeOf(e) orelse return false;
    return store.isOwnedSafe(tid);
}

/// Find the index of the innermost live-or-dead local named `want`.
///
/// Scans from the END of the stack so an inner shadow wins over an outer local
/// of the same name (see the `resolveLocal` unit test at the bottom of the
/// file). Returns null if no local by that name is in scope.
fn resolveLocal(locals: []const Local, want: []const u8) ?usize {
    var i: usize = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, want)) return i;
    }
    return null;
}

/// Is `e` an assignment whose left side is a tracked local (`x = ...`)?
///
/// True only for a binary `assign` whose left operand is an identifier that
/// resolves to a local in scope. Used to route assignment statements to
/// [`lowerReassign`] (which models the ARC release of the old value and the
/// acquire of the new) versus a plain expression.
fn isLocalReassign(e: *const ast.Expression, locals: []const Local) bool {
    if (e.kind != .binary) return false;
    const b = e.kind.binary;
    if (b.op != .assign) return false;
    return b.left.kind == .ident and resolveLocal(locals, b.left.kind.ident) != null;
}

/// Model `x = rhs` on a tracked local: acquire the new value, release the old.
///
/// Reassigning a local whose index is below [`Ctx.clone_floor`] defers with
/// [`DeferReason.reassign`] (the phi-free loop guard). Otherwise the new value
/// is either an owned COPY of another live local (RHS is an identifier) or a
/// fresh `makeOwned`; then the previous value of `x`, if live, is destroyed and
/// `x` rebound to the new value. This ordering (build new, then release old) is
/// what keeps the release count balanced across the reassignment.
fn lowerReassign(ctx: *Ctx, block: ir.Block, e: *const ast.Expression, locals: *Locals) LowerError!void {
    const b = e.kind.binary;
    const idx = resolveLocal(locals.items, b.left.kind.ident).?;
    if (idx < ctx.clone_floor) return deferBecause(ctx, .reassign);
    const rhs = b.right;
    var new_val: ?ir.Value = null;
    if (rhs.kind == .ident) {
        if (resolveLocal(locals.items, rhs.kind.ident)) |j| {
            if (locals.items[j].live) new_val = try ctx.f.copy(ctx.gpa, block, locals.items[j].value);
        }
    }
    if (new_val == null)
        new_val = try ctx.f.makeOwned(ctx.gpa, block, ctx.tir.typeOf(rhs));
    if (locals.items[idx].live) try ctx.f.destroy(ctx.gpa, block, locals.items[idx].value);
    locals.items[idx].value = new_val.?;
    locals.items[idx].live = true;
}

/// Walk an expression and emit a `borrowUse` for every read of a live owned local.
///
/// Every place a subexpression reads an owned local WITHOUT taking ownership
/// (passing it to a call, indexing it, a field access, a template
/// interpolation) is a borrow that ARC must account for, so the verifier needs
/// to see it. This recurses structurally through the common expression shapes.
/// For an assignment it descends only into the RHS (the LHS is the store
/// target, handled by [`lowerReassign`]), which avoids counting the assignee as
/// a borrow. Unhandled expression kinds contribute nothing.
fn emitOwnedUses(ctx: *Ctx, block: ir.Block, e: *const ast.Expression, locals: *Locals) LowerError!void {
    switch (e.kind) {
        .ident => |n| {
            if (resolveLocal(locals.items, n)) |i| {
                if (locals.items[i].live and ctx.f.ownershipOf(locals.items[i].value) == .owned)
                    try ctx.f.borrowUse(ctx.gpa, block, locals.items[i].value);
            }
        },
        .binary => |b| {
            if (b.op == .assign and b.left.kind == .ident) {
                try emitOwnedUses(ctx, block, b.right, locals);
            } else {
                try emitOwnedUses(ctx, block, b.left, locals);
                try emitOwnedUses(ctx, block, b.right, locals);
            }
        },
        .unary => |u| try emitOwnedUses(ctx, block, u.operand, locals),
        .call => |c| {
            try emitOwnedUses(ctx, block, c.callee, locals);
            for (c.args) |*a| try emitOwnedUses(ctx, block, a, locals);
        },
        .field_access => |fa| try emitOwnedUses(ctx, block, fa.object, locals),
        .index => |ix| {
            try emitOwnedUses(ctx, block, ix.object, locals);
            try emitOwnedUses(ctx, block, ix.index, locals);
        },
        .cast => |c| try emitOwnedUses(ctx, block, c.expr, locals),
        .template_expr => |t| for (t.parts) |*p| try emitOwnedUses(ctx, block, p, locals),
        else => {},
    }
}

/// Does the expression tree `e` reference an identifier named `name` anywhere?
///
/// A structural name-occurrence search mirroring [`emitOwnedUses`]'s recursion.
/// (Currently a self-contained utility, not on the main lowering path.)
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

/// The whole-program census accumulated by [`reportQuiet`] over every function.
///
/// Feeds both the human-readable table ([`printCensus`]) and the `hard`-mode
/// gate decision. `defer_reasons` is indexed by `@intFromEnum` of a
/// [`DeferReason`], so its length must match that enum's variant count.
const Counts = struct {
    /// Functions considered (top-level + struct/enum methods).
    total: usize = 0,
    /// Functions the model successfully lowered to verifiable IR.
    lowered: usize = 0,
    /// Functions skipped because a construct was outside the lite model.
    deferred: usize = 0,
    /// Lowered functions the verifier proved release-balanced.
    balanced: usize = 0,
    /// Lowered functions with a proven ARC imbalance (leak or double-free).
    imbalanced: usize = 0,
    /// Name of the first imbalanced function seen, for the gate message.
    first_imbalance_fn: []const u8 = "",
    /// Total owned `copy` instructions emitted across all lowered functions.
    fwd_copies: usize = 0,
    /// Of those copies, how many are borrow-then-destroy only (elision headroom).
    fwd_candidates: usize = 0,
    /// Per-reason deferral tally, indexed by `@intFromEnum(DeferReason)`.
    defer_reasons: [5]usize = .{0} ** 5,
};

/// Whole-program entry point: lower, verify, and print the census (non-quiet).
///
/// Thin wrapper over [`reportQuiet`] with `quiet = false`. In `hard` mode it
/// will exit the process non-zero if any function is imbalanced (the gate).
pub fn report(gpa: std.mem.Allocator, store: *const TypeStore, tir: *const TypedIr, program: *const ast.Program, hard: bool) void {
    reportQuiet(gpa, store, tir, program, hard, false);
}

/// Lower and verify every function in a program, optionally printing the census.
///
/// Iterates top-level functions and the methods of every struct/enum, running
/// [`lowerAndCheck`] for each into a [`Counts`]. When not `quiet`, prints the
/// coverage table. When `hard` and any lowered function was imbalanced, prints
/// the OSSA gate failure (naming the first offender) and calls
/// `std.process.exit(1)` to FAIL THE BUILD; this is the `NOVA_OSSA` gate's teeth.
pub fn reportQuiet(gpa: std.mem.Allocator, store: *const TypeStore, tir: *const TypedIr, program: *const ast.Program, hard: bool, quiet: bool) void {
    var c = Counts{};
    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |*f| lowerAndCheck(gpa, store, tir, f, &c),
            .struct_decl => |*sd| for (sd.methods) |*m| lowerAndCheck(gpa, store, tir, &m.decl, &c),
            .enum_decl => |*ed| for (ed.methods) |*m| lowerAndCheck(gpa, store, tir, &m.decl, &c),
            else => {},
        }
    }
    if (!quiet) printCensus(&c);

    if (hard and c.imbalanced > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mOSSA OWNERSHIP GATE FAILED:\x1b[0m {d} function(s) have an ARC release imbalance " ++
            "(a leak or double-free the release-balance verifier proved). First: '{s}'.\n" ++
            "(Set NOVA_OSSA=off to disable this check, or NOVA_OSSA=1 for the full coverage report.)\n",
            .{ c.imbalanced, c.first_imbalance_fn },
        );
        std.process.exit(1);
    }
}

/// Print the human-readable OSSA-lite census to stderr.
///
/// Reports totals, coverage percentage (`lowered / total`), balanced vs
/// imbalanced counts, the per-reason deferral breakdown, and the
/// ownership-forwarding headroom (copies emitted vs forwardable). Purely
/// diagnostic; the gate decision lives in [`reportQuiet`].
fn printCensus(c: *const Counts) void {
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

/// Lower one function, verify it if lowered, and fold the outcome into `c`.
///
/// A lowering that errors (only `OutOfMemory` reaches here) is counted as
/// deferred rather than crashing the census. A deferred function bumps its
/// reason bucket. A lowered function is verified ([`verify.verify`]) and tallied
/// balanced/imbalanced (recording the first imbalanced name), and its copies are
/// run through [`forward.count`] for the forwarding headroom stats. The built
/// IR and verifier result are freed before returning.
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


// Verifies [`resolveLocal`]'s back-to-front scan: with two locals named `b`,
// the later (innermost) one at index 2 must win; an outer `a` resolves to its
// index; an unknown name resolves to null.
test "resolveLocal returns the innermost (last-declared) shadow" {
    const locals = [_]Local{
        .{ .name = "a", .value = @enumFromInt(0), .live = true },
        .{ .name = "b", .value = @enumFromInt(1), .live = true },
        .{ .name = "b", .value = @enumFromInt(2), .live = true },
    };
    try std.testing.expectEqual(@as(?usize, 2), resolveLocal(&locals, "b"));
    try std.testing.expectEqual(@as(?usize, 0), resolveLocal(&locals, "a"));
    try std.testing.expectEqual(@as(?usize, null), resolveLocal(&locals, "z"));
}
