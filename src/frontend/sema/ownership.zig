//! Ownership analysis and use-after-move verifier for the typed IR.
//!
//! Kyte is an ARC language: every heap value carries a refcount and is dropped
//! (released) exactly once when its owner goes out of scope. This pass runs over
//! the already-typed IR ([`TypedIr`], produced by `infer.zig`) and has two jobs
//! that share the same tree walk:
//!
//!   1. **Temporary op annotation** ([`tempStmt`]/[`tempExpr`]). For every owned
//!      sub-expression the codegen needs to know whether the value is CONSUMED
//!      by its enclosing context (a "move", the receiver takes ownership, no
//!      drop is emitted) or merely produced and discarded (a "drop", ARC must
//!      release it). This half calls [`TypedIr.recordOp`] so `arc.zig` in the
//!      backend can emit the right retain/release. It is the authoritative
//!      source of move-vs-drop decisions for temporaries.
//!
//!   2. **Balance verification** ([`analyzeOwnedLocal`] and the `walk*` family).
//!      For every owned `let` local it performs a small flow-sensitive analysis:
//!      track whether the value is still `live` or has been `moved` out, and flag
//!      a **use-after-move** if a moved local is read again. This is a checker,
//!      not a rewriter: it only counts and diagnoses, never mutates the IR.
//!
//! ## Design stance: sound by deferral, not by completeness
//!
//! The verifier is deliberately conservative. It only reasons precisely about
//! the shapes it fully understands (straight-line moves, `return x`, plain
//! `if`/`else` merges). Anything it cannot prove, reassignment to the tracked
//! name, shadowing, a mention buried inside a closure/`if`-expression/`catch`,
//! loops that move a value, or an initialiser with no inferred type, is
//! classified `deferred` rather than analysed. A deferred local counts toward
//! coverage-as-unchecked but NEVER produces a false-positive violation. The
//! guiding rule is: report a use-after-move only when it is genuinely one; when
//! in doubt, defer. This is why [`Stats`] tracks `analyzed` (proved balanced)
//! separately from `deferred_cfg`/`deferred_untyped`.
//!
//! ## Entry points
//!
//! [`analyze`] returns just the [`Stats`] (fire-and-forget accounting used by the
//! normal compile). [`verify`] additionally collects a [`Diagnostic`] per
//! violation. [`runVerify`] is the `KYTE_OWN_VERIFY` developer gate: it prints a
//! coverage report and, when `hard_fail` is set, exits the process non-zero on
//! any violation so CI can gate on it. See `arc.zig` (the OSSA ARC-balance
//! self-verifier) for the complementary codegen-side check.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const infer = @import("infer.zig");

/// The type table produced by the type checker; consulted here only to ask
/// whether an inferred type is an owned (heap/ARC) type via `isOwnedSafe`.
const TypeStore = types.TypeStore;
/// The typed intermediate representation this pass walks. Its [`TypedIr.ownedOf`]
/// and [`TypedIr.typeOf`] answer per-expression ownership queries, and
/// [`TypedIr.recordOp`] receives the move/drop annotations this pass computes.
const TypedIr = infer.TypedIr;

/// Running accounting for one full analysis pass, and the mutable scratch state
/// threaded through the recursive walkers.
///
/// It doubles as both the RESULT (coverage counters, violation count) and the
/// live CONTEXT (`diags`, `diag_alloc`, `cur_fn`) that the `walk*`/`temp*`
/// functions mutate as they descend. `owned_locals = analyzed + deferred_cfg +
/// deferred_untyped` is the coverage identity [`runVerify`] prints.
pub const Stats = struct {
    /// Number of function bodies visited (top-level fns plus struct/enum methods).
    fns_walked: usize = 0,
    /// Owned `let` locals discovered, the denominator for coverage. Every such
    /// local is then either `analyzed` or deferred.
    owned_locals: usize = 0,
    /// Owned locals whose move/drop balance was fully proved by the flow walk.
    analyzed: usize = 0,
    /// Owned locals deferred because their control flow was too complex to prove
    /// soundly (reassignment, shadowing, closure/if-expr mentions, loop moves).
    /// Counted as unchecked, never as a violation.
    deferred_cfg: usize = 0,
    /// Owned locals deferred because the initialiser had no inferred type yet, so
    /// ownership could not be decided; gated behind [`initCouldBeOwned`].
    deferred_untyped: usize = 0,
    /// Count of scope-exit drops the walk decided must be emitted (value still
    /// live at fallthrough / on a control-flow merge).
    drop_ops: usize = 0,
    /// Count of moves OUT of a local (returned or moved on a merge branch), the
    /// value's ownership left the scope, so no drop is owed here.
    move_outs: usize = 0,
    /// Count of `let y = x;` duplications of the tracked owned name (an aliasing
    /// copy the codegen must retain).
    dup_ops: usize = 0,
    /// Number of use-after-move violations detected across the whole program.
    balance_violations: usize = 0,
    /// Name of the FIRST offending local, kept for a terse one-line summary even
    /// when full [`Diagnostic`] collection is off.
    first_violation: []const u8 = "",

    /// Temporaries (non-`let` owned sub-expressions) annotated as consumed/moved.
    temp_moves: usize = 0,
    /// Temporaries annotated as produced-and-dropped (ARC must release them).
    temp_drops: usize = 0,

    /// Optional sink for per-violation [`Diagnostic`]s. `null` in the
    /// count-only [`analyze`] path; set by [`verify`] so callers can report each
    /// offending local.
    diags: ?*std.ArrayListUnmanaged(Diagnostic) = null,
    /// Allocator used to grow `diags`; `undefined` until [`run`] installs it.
    diag_alloc: std.mem.Allocator = undefined,
    /// Name of the function currently being walked, stamped into each
    /// [`Diagnostic`] so a violation is attributable without a second pass.
    cur_fn: []const u8 = "",
};

/// One recorded use-after-move: the local `local` in function `fn_name` was read
/// after its owning value had been moved out. Both fields borrow names from the
/// AST, so a `Diagnostic` is only valid while the program tree is alive.
pub const Diagnostic = struct {
    /// Enclosing function's name (from [`Stats.cur_fn`] at detection time).
    fn_name: []const u8,
    /// The offending owned local's name.
    local: []const u8,
};

/// The full result of [`verify`]: the coverage [`Stats`] plus an owned slice of
/// every [`Diagnostic`]. The slice is heap-allocated by the caller's allocator
/// and becomes the caller's to free.
pub const VerifyResult = struct {
    /// Coverage and op accounting for the pass.
    stats: Stats,
    /// One entry per detected use-after-move, in discovery order.
    diagnostics: []Diagnostic,
};

/// Run the pass for its side effects and accounting only, discarding diagnostics.
///
/// This is the normal-compile entry point: it still annotates temporaries into
/// `ir` via [`recordOp`] (which the backend depends on) but does not collect a
/// [`Diagnostic`] list. Equivalent to [`run`] with a `null` diagnostics sink.
pub fn analyze(allocator: std.mem.Allocator, store: *const TypeStore, ir: *TypedIr, program: *const ast.Program) Stats {
    return run(allocator, store, ir, program, null);
}

/// Run the pass AND collect a [`Diagnostic`] for every use-after-move.
///
/// Returns a [`VerifyResult`] owning the diagnostics slice. Errors only if the
/// final `toOwnedSlice` allocation fails; per-append allocation failures inside
/// the walk are swallowed (best-effort diagnostics, never fatal).
pub fn verify(allocator: std.mem.Allocator, store: *const TypeStore, ir: *TypedIr, program: *const ast.Program) !VerifyResult {
    var list: std.ArrayListUnmanaged(Diagnostic) = .empty;
    const st = run(allocator, store, ir, program, &list);
    return .{ .stats = st, .diagnostics = try list.toOwnedSlice(allocator) };
}

/// The `KYTE_OWN_VERIFY` developer gate: run [`verify`], print a coverage report
/// to stderr, and optionally fail the build.
///
/// Prints functions walked, owned locals, the proved/deferred split, coverage
/// percentage, and each violation. When `hard_fail` is true and any violation
/// was found, it prints a bold red banner and calls `std.process.exit(1)` so CI
/// can gate on a clean report. A failure inside [`verify`] itself is silently
/// ignored (early `return`), this is a diagnostic gate, not part of codegen.
pub fn runVerify(allocator: std.mem.Allocator, store: *const TypeStore, ir: *TypedIr, program: *const ast.Program, hard_fail: bool) void {
    const res = verify(allocator, store, ir, program) catch return;
    const s = res.stats;
    const total = s.owned_locals;
    const proved = s.analyzed;
    const deferred = s.deferred_cfg + s.deferred_untyped;
    const cov: usize = if (total == 0) 100 else (proved * 100) / total;
    std.debug.print(
        "=== ownership verifier (KYTE_OWN_VERIFY) ===\n" ++
        "  functions walked        : {d}\n" ++
        "  owned let-locals        : {d}\n" ++
        "    proved (balance held) : {d}\n" ++
        "    deferred (unchecked)  : {d}   (CFG/reassign/shadow {d} + untyped-init {d})\n" ++
        "    coverage              : {d}% proved of owned locals\n" ++
        "  USE-AFTER-MOVE VIOLATIONS: {d}\n",
        .{ s.fns_walked, total, proved, deferred, s.deferred_cfg, s.deferred_untyped, cov, res.diagnostics.len },
    );
    for (res.diagnostics) |d| {
        std.debug.print("    violation: fn '{s}', owned local '{s}' used after move\n", .{ d.fn_name, d.local });
    }
    std.debug.print("=== end ownership verifier ===\n", .{});
    if (hard_fail and res.diagnostics.len > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mOWNERSHIP VERIFIER FAILED:\x1b[0m {d} use-after-move violation(s); an owned value is used after it was moved.\n",
            .{res.diagnostics.len},
        );
        std.process.exit(1);
    }
}

/// Core driver shared by [`analyze`] and [`verify`]: walk every top-level fn and
/// every struct/enum METHOD body, accumulating into a fresh [`Stats`].
///
/// `diags` is the optional violation sink threaded into the `Stats`; passing
/// `null` yields count-only behaviour. Only functions and type methods are
/// visited, other declaration kinds carry no analysable bodies.
fn run(allocator: std.mem.Allocator, store: *const TypeStore, ir: *TypedIr, program: *const ast.Program, diags: ?*std.ArrayListUnmanaged(Diagnostic)) Stats {
    var st = Stats{ .diags = diags, .diag_alloc = allocator };
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

/// Analyse a single function body: run the owned-local balance walk
/// ([`analyzeStmts`]) and then the temporary-op annotation walk ([`tempStmt`]).
///
/// The two passes are separate because they answer different questions, the
/// first proves per-local move balance for the verifier, the second annotates
/// every owned temporary for the backend, and neither depends on the other's
/// result. `cur_fn` is stamped here so any diagnostics raised deeper carry the
/// enclosing function's name.
fn analyzeFn(allocator: std.mem.Allocator, f: *const ast.FunctionDecl, store: *const TypeStore, ir: *TypedIr, st: *Stats) void {
    st.fns_walked += 1;
    st.cur_fn = f.name;
    analyzeStmts(f.body.statements, store, ir, st);
    for (f.body.statements) |*s| tempStmt(allocator, ir, s, st);
}

/// Recursively walk a statement, forwarding each contained expression to
/// [`tempExpr`] with the correct "is this position a move?" flag.
///
/// The `moved` argument encodes each context's ownership contract, and this is
/// where those contracts are decided per statement kind:
///   - a `let`'s initialiser is a move ONLY for a single-name binding (`ls.names
///     == null`); a destructuring `let` is treated as non-move here;
///   - a `return`'s value is a move (ownership leaves the function);
///   - an expression statement's value is dropped, not moved (`false`);
///   - conditions/iterables are read positions, not moves.
/// It descends into every nested block so temporaries in inner scopes are also
/// annotated.
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

/// Annotate one expression (and its children) with move/drop ops for the backend.
///
/// If [`TypedIr.ownedOf`] reports this expression produces an owned value, record
/// a `.move` when `moved` is set (the enclosing context consumes it) or a `.drop`
/// otherwise (ARC must release it), via [`TypedIr.recordOp`]; recording failures
/// are ignored. It then recurses into children, propagating `moved` position by
/// position. The subtle cases, mirroring the language's value semantics:
///   - `x = rhs` (binary `.assign`): the RHS is a move into the target;
///   - `a ?? b` nullish-coalesce: the left is always moved (it is consumed by the
///     coalesce), the right inherits the OUTER `moved` (it becomes the result);
///   - `cast`, `if_expr` branches, `catch` handler: pass `moved` through, since
///     the cast/branch value IS the surrounding value;
///   - tuple/struct/enum initialiser fields and closure/if-expr result positions
///     are moves (the aggregate takes ownership of each);
///   - callee, arguments, indices, conditions, field objects are read positions
///     (`false`).
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

/// Walk a statement sequence, finding owned `let` locals and kicking off the
/// balance analysis for each.
///
/// For every statement it first recurses into nested blocks via
/// [`recurseIntoNested`] (so locals declared inside `if`/loop/`switch` bodies are
/// also found). A `let` qualifies as a trackable owned local only when it is a
/// SINGLE-name binding (`ls.names == null`) with an initialiser. If the
/// initialiser has an inferred owned type ([`TypeStore.isOwnedSafe`]) the local
/// is handed to [`analyzeOwnedLocal`] over the REMAINING statements in this
/// sequence (`stmts[i+1..]`), which is its live scope. If the initialiser has no
/// inferred type yet, [`initCouldBeOwned`] decides whether to count it as a
/// deferred-untyped owned local instead.
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

/// Descend into the bodies of compound statements so their owned locals are
/// discovered by [`analyzeStmts`].
///
/// Only structural recursion: it opens blocks, both `if` branches, loop bodies,
/// and every `switch` case/default, calling `analyzeStmts` on true blocks and
/// recursing otherwise. It does NOT itself analyse locals; it just ensures no
/// nested scope is skipped by the top-level sequence walk.
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

/// The dataflow state of a tracked owned local at a program point: either still
/// `live` (owns its value, a drop is owed at scope exit) or `moved` (its value
/// was moved out, reading it again is a use-after-move).
const St = enum { live, moved };

/// The result of walking a statement (or a sequence) for one tracked local: how
/// control leaves that construct, which determines how enclosing walks combine
/// branches.
const Flow = union(enum) {

    /// Control fell through to the next statement with the local in this state.
    fallthrough: St,

    /// A `return` was hit, control leaves the function; the local's remaining
    /// scope on this path is over.
    returned,

    /// The construct contained a shape too complex to reason about soundly
    /// (reassignment, shadow, closure/if-expr mention, loop move); the whole
    /// local is abandoned as `deferred_cfg` rather than risk a false positive.
    deferred,

    /// A use-after-move was proved on this path.
    violation,
};

/// Drive the flow walk for one owned local over its live scope and fold the
/// resulting [`Flow`] into [`Stats`].
///
/// Interprets the terminal `Flow`:
///   - `fallthrough(.live)` → the value survives to scope end, so a drop is owed
///     (`drop_ops`); `fallthrough(.moved)` → it left the scope (`move_outs`);
///     either way the local is `analyzed` (proved balanced);
///   - `returned` → also proved (`analyzed`);
///   - `deferred` → counted as `deferred_cfg`, unchecked;
///   - `violation` → a use-after-move: bump the count, remember the first name,
///     and, if a sink is present, append a [`Diagnostic`].
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
            if (st.diags) |d| d.append(st.diag_alloc, .{ .fn_name = st.cur_fn, .local = name }) catch {};
        },
    }
}

/// Walk a statement sequence for one local, threading the [`St`] state forward.
///
/// Starts from `entry` and applies [`walkStmt`] to each statement in order,
/// carrying the updated state on `fallthrough`. Any non-fallthrough outcome
/// (`returned`/`deferred`/`violation`) short-circuits and is returned as the
/// sequence's result. If every statement falls through, returns
/// `fallthrough(state)` with the final state.
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

/// Transfer function for one statement: given the tracked local's state on
/// entry, return the [`Flow`] describing how it exits.
///
/// This is the heart of the balance analysis, and every arm encodes a soundness
/// choice about when to prove versus defer:
///   - `block` → recurse via [`walkSeq`].
///   - `let` → if it REDECLARES `name` (shadowing) or the initialiser mentions it
///     inside a complex construct, defer; if the initialiser is exactly `name`
///     (`let y = x;`) it is a duplicating copy (`dup_ops`), state unchanged; a
///     plain mention while `moved` is a violation.
///   - `expr_stmt` → an assignment `name = ...` re-initialises the local, which
///     this walk cannot model, so defer; a complex mention defers; a plain
///     mention while `moved` is a violation.
///   - `return` → `return name;` moves the value out (`move_outs`) and returns
///     `returned`; any other mention while `moved` is a violation; on a live
///     fall-off a drop is owed (`drop_ops`).
///   - `if` → walk both branches from the same entry state and combine with
///     [`mergeIf`]; a moved-state mention in the condition is an immediate
///     violation.
///   - `while`/`for` → delegate to [`walkLoop`], which is deliberately
///     conservative because a loop body can move a value on a later iteration.
///   - `switch`/`break`/`continue`/`defer` → if they mention the local at all,
///     defer (these are not flow-modelled here); otherwise fall through.
fn walkStmt(name: []const u8, s: *const ast.Statement, state: St, st: *Stats) Flow {
    switch (s.*) {
        .block => |b| return walkSeq(name, b.statements, state, st),

        .let_stmt => |ls| {
            if (std.mem.eql(u8, ls.name, name)) return .deferred;
            if (ls.init) |init| {
                if (mentionsComplex(&init, name)) return .deferred;
                if (isIdent(&init, name)) {
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

/// Combine the [`Flow`] of an `if`'s then-branch (`ft`) and else-branch (`fe`)
/// into a single outcome for the whole `if`.
///
/// Precedence and merge rules:
///   - if EITHER branch deferred, the result defers (soundness first);
///   - else if either has a violation, the result is a violation;
///   - a `returned` branch contributes no state to the merge (control left), so
///     if both returned the `if` is `returned`, and if one returned the other's
///     state carries;
///   - if both fall through to the SAME state, that state carries unchanged;
///   - if they fall through to DIFFERENT states (one `live`, one `moved`), the
///     value is conservatively treated as `moved` after the `if` and a drop is
///     charged (`drop_ops`) for the branch that still held it.
/// The `else => unreachable` arms are safe because deferred/violation were
/// already handled above, leaving only `fallthrough`/`returned`.
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

/// Conservatively handle a `while`/`for` for one local.
///
/// A loop is hard to prove precisely because a move in the body would strike on
/// the SECOND iteration, so this defers rather than track iteration state:
///   - a complex mention in the condition, or a moved-state mention there,
///     violates / defers as usual;
///   - if the body MOVES the local ([`seqMovesLocal`]) or mentions it inside a
///     complex construct ([`stmtComplexMentions`]), defer;
///   - if the local is already `moved` on entry and the body mentions it at all,
///     that is a use-after-move (`violation`);
///   - otherwise the local is untouched by the loop and control falls through in
///     the same state. (`st` is unused here, no ops are charged for a loop that
///     neither moves nor drops the local.)
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

/// Report whether statement `s` (recursively) MOVES the local out via a bare
/// `return name;` or `let y = name;` where the initialiser is exactly the ident.
///
/// Used by [`walkLoop`] to decide that a loop body which moves the value is
/// unanalysable and must be deferred. It looks only for the two move-shaped
/// positions (return value and let-initialiser being the plain identifier), not
/// arbitrary mentions.
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

/// Report whether statement `s` (recursively) mentions `name` inside a construct
/// the walk classifies as "complex" (see [`mentionsComplex`]), a closure,
/// `if`/`block` expression, or `catch`.
///
/// Such a mention means the local's use is control-flow-entangled beyond what
/// this analysis models, so callers ([`walkLoop`]) treat it as a reason to defer.
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

/// Report whether `e` is EXACTLY the bare identifier `name` (not merely a
/// sub-expression that mentions it).
///
/// This is the move test: `return x;`, `let y = x;`, `x = ...` all pivot on the
/// operand being the plain ident, which is what makes them a whole-value move or
/// a self-reassignment rather than a read.
fn isIdent(e: *const ast.Expression, name: []const u8) bool {
    return e.kind == .ident and std.mem.eql(u8, e.kind.ident, name);
}

/// Report whether statement `s` mentions `name` ANYWHERE in any of its
/// expressions, recursing through nested statements.
///
/// The statement-level counterpart to [`mentions`]. Used to decide that an
/// unmodelled statement kind (`switch`/`break`/`continue`/`defer`, or a loop body
/// under an already-moved local) touches the local at all, which forces a defer
/// or flags a violation.
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

/// Report whether `e` mentions `name` inside a control-flow-carrying
/// sub-expression: a closure, `if`-expression, block-expression, or `catch`.
///
/// When such a construct is present anywhere on the path to a mention, the walk
/// cannot pin down WHEN the use happens relative to a move, so any mention under
/// one is a reason to DEFER the whole local. The four "complex" kinds delegate
/// straight to [`mentions`] (their mere presence-with-a-mention is enough);
/// ordinary operator/call/index/field nodes recurse structurally; leaves and
/// unhandled kinds answer `false`. Note this walks a slightly NARROWER set of
/// expression kinds than [`mentions`] (e.g. it does not descend `try`/`await`),
/// which is acceptable because a false negative here only widens what gets
/// analysed, and [`mentions`] still guards the actual move check.
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

/// Report whether expression `e` reads the identifier `name` anywhere within it.
///
/// The exhaustive structural mention test underpinning every "is the local used
/// here?" question. Unlike [`mentionsComplex`] it descends the FULL expression
/// grammar (calls, generic calls, tuples, struct/enum initialisers, `if`/block
/// expressions, `try`/`catch`, `await`/`go`, closures) and bottoms out at an
/// `ident` comparison. A `true` result while the local is `moved` is what makes a
/// use-after-move.
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

/// Heuristic for an initialiser with NO inferred type: could this expression
/// plausibly produce an owned (heap) value?
///
/// Used by [`analyzeStmts`] to decide whether an un-typed `let` initialiser
/// should be counted as a `deferred_untyped` owned local (unchecked coverage) or
/// ignored entirely. Scalar literals (`integer`/`float`/`bool`/`null`/`undefined`)
/// are never owned and answer `false`; every other shape (string literals,
/// calls, constructors, ...) is conservatively assumed it MIGHT own, so it is
/// tracked as unchecked rather than silently dropped from the coverage count.
fn initCouldBeOwned(e: *const ast.Expression) bool {
    return switch (e.kind) {
        .literal => |lit| switch (lit) {
            .integer, .float, .bool, .null, .undefined => false,
            else => true,
        },
        else => true,
    };
}
