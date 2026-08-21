//! Report-only escape analysis over the typed IR.
//!
//! This pass answers one question for every heap-owning local in a program:
//! does the object it holds STAY within the function that created it, or does a
//! reference to it flow out (returned, stored into a field or container element,
//! captured by a closure, or handed to a callee that keeps it)? A local whose
//! object never leaves is a candidate for cheaper allocation strategies (stack
//! or per-request arena) instead of a full ARC-counted heap box.
//!
//! It is deliberately REPORT-ONLY. As of this writing nothing in codegen acts
//! on the result: [`analyze`] returns aggregate [`Stats`] and, when
//! [`report_enabled`] is set, prints a one-line summary. The per-request arena
//! experiment that motivated it was rolled back (ARC follows pointers across an
//! arena region, so freeing the region under a still-counted object is unsound),
//! and this file survives as the sound, non-committing substrate a future escape
//! -driven optimisation would build on. See the perf notes in the design docs.
//!
//! ## How it decides
//!
//! The analysis is a two-layer fixpoint.
//!
//!   * OUTER (interprocedural): [`analyze`] iterates over every function up to
//!     24 rounds, recomputing each function's "which parameters escape" summary
//!     ([`mergeSummary`]) until no summary changes. Summaries only ever GAIN
//!     escaping parameters (monotone), so the fixpoint is guaranteed to settle;
//!     the 24-round cap is a belt-and-braces bound, not the expected exit. A
//!     call to a not-yet-summarised or unknown callee is treated pessimistically
//!     (every argument escapes), which keeps the result a sound over-approximation
//!     regardless of visitation order.
//!
//!   * INNER (intraprocedural): [`computeEscapingAndAllocs`] seeds a per-function
//!     escaping set from the direct escape sinks (returns, field/index stores,
//!     closure captures, escaping call arguments) and then closes it over
//!     assignment EDGES (`lhs = rhs` between plain identifiers) so that if `lhs`
//!     escapes then `rhs` does too. This flow closure is itself a small fixpoint.
//!
//! Everything works on borrowed slices from the AST and the typed IR; the only
//! owned state is the summary vectors and transient sets, all freed before
//! [`analyze`] returns. Allocation failures are swallowed (`catch {}` / `catch
//! continue`): a dropped edge or summary can only make the result MORE
//! conservative (more things marked escaping), never unsound, so the pass never
//! fails the build.
//!
//! ## Soundness direction
//!
//! Every approximation here errs towards "escapes". Missing an escape would be a
//! correctness bug (an object freed while still reachable); spuriously marking
//! something as escaping only forfeits an optimisation. That asymmetry is why the
//! unknown-callee, allocation-failure, and non-identifier-LHS cases all default
//! to marking escape.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
/// The inference/typed-IR pass. Supplies [`TypedIr.ownedOf`], which tells this
/// analysis whether an expression produces a heap-owning value (an allocation
/// site) as opposed to a borrow or a scalar.
const infer = @import("infer.zig");

/// The type table produced by inference. Accepted by [`analyze`] for interface
/// symmetry with the other sema passes but currently unused here (the analysis
/// works purely off ownership facts and AST shape).
const TypeStore = types.TypeStore;
/// The typed intermediate representation. Its [`TypedIr.ownedOf`] classifies
/// each expression as heap-owning or not, which is how [`isOwned`] finds the
/// allocation sites this pass reasons about.
const TypedIr = infer.TypedIr;

/// Global switch that turns the one-line `[escape] ...` summary print on.
///
/// Off by default so the pass is silent in normal builds. A driver flips this
/// (for example a `NOVA_ESCAPE_REPORT`-style opt-in) when it wants the aggregate
/// numbers from [`analyze`] echoed to stderr.
pub var report_enabled: bool = false;

/// Aggregate counts returned by [`analyze`], one snapshot for the whole program.
///
/// These are diagnostic only. `local + escapes == alloc_sites` after a run: every
/// allocation site is classified exactly once as staying local or escaping.
pub const Stats = struct {
    /// Number of functions (free functions plus struct/enum methods) analysed.
    fns: usize = 0,
    /// Number of heap-owning `let` bindings seen, i.e. candidate allocation sites.
    alloc_sites: usize = 0,
    /// Allocation sites whose object never leaves its function (optimisable).
    local: usize = 0,
    /// Allocation sites whose object escapes and must stay a full ARC heap box.
    escapes: usize = 0,
    /// Outer-fixpoint rounds [`analyze`] actually ran before summaries settled.
    iterations: usize = 0,
};

/// A set of identifier names, used both for the per-function escaping set and for
/// the set of allocation-site local names. Value type is `void` (membership only).
const StrSet = std.StringHashMap(void);
/// A directed assignment relation `lhs = rhs` between two plain identifiers.
///
/// Recorded by [`walkStmt`] for `let x = y` and `x = y`. During flow closure
/// (see [`computeEscapingAndAllocs`]) an edge propagates escape BACKWARDS: if the
/// destination `lhs` escapes then the source `rhs` must too, because whatever
/// object flowed left is still reachable through the right-hand name.
const Edge = struct { lhs: []const u8, rhs: []const u8 };

/// One analysable function: its name, parameter list, and body block.
///
/// Flattened out of the declaration tree by [`analyze`] so free functions and
/// methods can be iterated uniformly. `params`/`body` borrow the AST; `name` is
/// the key used to look up and store the function's escape summary.
const FnEntry = struct {
    /// Function or method name; the summary-map key. Note that same-named methods
    /// on different types collide here (see the length-reconciliation in
    /// [`analyze`] and [`mergeSummary`]).
    name: []const u8,
    /// Declared parameters, borrowed from the AST. `params.len` is the arity the
    /// summary vector is sized to.
    params: []ast.Param,
    /// The function body to walk. Borrowed pointer into the AST.
    body: *const ast.Block,
};

/// Shared state threaded through the whole run: the allocator, the typed IR, and
/// the interprocedural summary map.
const Analysis = struct {
    /// Allocator for summary vectors and transient sets. Everything it hands out
    /// is freed before [`analyze`] returns.
    alloc: std.mem.Allocator,
    /// The typed IR, consulted via [`isOwned`] to find allocation sites.
    ir: *const TypedIr,
    /// Per-function escape summaries keyed by name: `summaries[fn][i]` is true
    /// once parameter `i` of `fn` is known to escape. Grows monotonically across
    /// outer rounds; each value slice is owned and freed in [`analyze`]'s defer.
    summaries: std.StringHashMap([]bool),

    /// Look up the escape summary for a callee by name, or null if it is unknown
    /// (not defined in this program, or not yet computed this round).
    ///
    /// A null result makes [`applyCall`] treat every argument as escaping, which
    /// is the sound default for an opaque callee.
    fn summaryFor(self: *Analysis, name: []const u8) ?[]bool {
        return self.summaries.get(name);
    }
};

/// Run the whole-program escape analysis and return aggregate [`Stats`].
///
/// Phases, in order:
///
///   1. Flatten every free function and every struct/enum method into a
///      [`FnEntry`] list.
///   2. Seed a zero (nothing-escapes) summary vector for each function, and
///      reconcile arity when two same-named functions disagree on parameter
///      count (grow to the larger, preserving known-escaping flags).
///   3. Iterate the OUTER fixpoint (up to 24 rounds): recompute each function's
///      escaping set and [`mergeSummary`] it into the map; stop early the first
///      round nothing changes. Because summaries only gain flags this always
///      converges; the cap is a safety bound.
///   4. With summaries stable, walk each function once more via
///      [`computeEscapingAndAllocs`] to enumerate allocation sites and tally each
///      as local or escaping.
///
/// `store` is currently unused (discarded); it is accepted to match the sema
/// pass signature. All owned state is freed before returning, so calling this is
/// side-effect-free apart from the optional [`report_enabled`] print.
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

/// Fold a freshly computed escaping set into `fe`'s stored summary; return
/// whether the summary changed.
///
/// A parameter's summary bit is set when its NAME appears in `escaping`. The
/// merge is monotone: bits only ever go false→true, which is what makes the
/// outer fixpoint in [`analyze`] terminate. Returning true signals that another
/// outer round is needed because a caller of `fe` may now propagate the new
/// escape.
///
/// The `vec.len < n` branch handles arity reconciliation for same-named
/// functions: it grows the vector to the current arity, copying the old flags
/// and defaulting the new tail to false. `catch return false` on allocation
/// failure reports "no change" so the fixpoint can still make progress (at worst
/// this function's escapes are learned later or not at all, which stays sound).
fn mergeSummary(an: *Analysis, fe: FnEntry, escaping: *StrSet) bool {
    const n = fe.params.len;
    const gop = an.summaries.getOrPut(fe.name) catch return false;
    if (!gop.found_existing) {
        const v = an.alloc.alloc(bool, n) catch return false;
        for (v, 0..) |*b, i| b.* = escaping.contains(fe.params[i].name);
        gop.value_ptr.* = v;
        return true;
    }
    var vec = gop.value_ptr.*;
    var changed = false;
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

/// Per-function walk state passed down the statement/expression recursion.
///
/// Bundles the escaping set being built, the optional allocation-site set, and
/// the assignment edges collected for the flow-closure step. Kept as one struct
/// so the many walk helpers take a single `*Ctx` rather than four parameters.
const Ctx = struct {
    /// Backreference to the shared analysis (allocator, IR, summaries).
    an: *Analysis,
    /// The set of names known to escape in the current function. Grown in place.
    escaping: *StrSet,
    /// Optional set of local names that are allocation sites. Non-null only on
    /// the final counting walk; the fixpoint rounds pass null (they only need
    /// escape facts, not the allocation tally).
    allocs: ?*StrSet,
    /// Assignment edges `lhs = rhs` gathered during the walk, replayed to a
    /// fixpoint by [`computeEscapingAndAllocs`] to propagate escape backwards.
    edges: std.ArrayList(Edge),

    /// Record that `name` escapes.
    ///
    /// A `put` failure is swallowed because a missed escape mark can only make
    /// the analysis miss an optimisation later, and the pass must never fail the
    /// build.
    fn markEscape(self: *Ctx, name: []const u8) void {
        self.escaping.put(name, {}) catch {};
    }
};

/// Fixpoint-round convenience: compute only the escaping set, discarding the
/// allocation-site tally. Thin wrapper over [`computeEscapingAndAllocs`] with a
/// null `allocs`.
fn computeEscaping(an: *Analysis, params: []ast.Param, body: *const ast.Block, escaping: *StrSet) void {
    computeEscapingAndAllocs(an, params, body, escaping, null);
}

/// Intraprocedural core: populate `escaping` (and, if given, `allocs`) for one
/// function body.
///
/// Two steps. First [`walkStmt`] over every statement seeds the direct escape
/// sinks, records allocation sites into `allocs`, and collects assignment edges.
/// Then the trailing `while (changed)` loop closes `escaping` over those edges:
/// for each `lhs = rhs`, if `lhs` escapes so does `rhs`. Iterating to a fixpoint
/// handles chains like `a = b; c = a` where escape must flow through several
/// hops. `params` is unused (the walk keys purely on names).
fn computeEscapingAndAllocs(an: *Analysis, params: []ast.Param, body: *const ast.Block, escaping: *StrSet, allocs: ?*StrSet) void {
    _ = params;
    var ctx = Ctx{ .an = an, .escaping = escaping, .allocs = allocs, .edges = std.ArrayList(Edge).empty };
    defer ctx.edges.deinit(an.alloc);
    for (body.statements) |*s| walkStmt(&ctx, s);
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

/// Whether expression `e` produces a heap-owning value per the typed IR.
///
/// Consulted by [`walkStmt`] on the RHS of a `let` to decide if the binding is
/// an allocation site. Absent ownership info (`ownedOf` returns null) is treated
/// as not-owned, so an unclassified expression is simply not counted as an
/// allocation rather than mis-counted.
fn isOwned(ctx: *Ctx, e: *const ast.Expression) bool {
    return ctx.an.ir.ownedOf(e) orelse false;
}

/// Collect every identifier NAME reachable inside expression `e` into `out`.
///
/// Used to find which locals a value flows from when that value reaches an escape
/// sink. The switch recurses through every expression form that can carry a
/// subexpression (binary, call, field access, struct/enum init, tuple, template,
/// try/catch, and so on); leaves that cannot reference a local (literals) fall to
/// the `else`. Duplicates are allowed, since the caller only feeds them into a
/// set. Append failures are swallowed for the same soundness reason as elsewhere.
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

/// Mark every identifier appearing in `e` as escaping.
///
/// The blanket "any name mentioned in an escaping expression escapes" is a
/// conservative over-approximation: passing `f(x)` to a return, say, marks both
/// `f` and `x`. That over-marks harmlessly (forfeits optimisations, never
/// unsound), which is the intended bias. Built on [`collectIdents`].
fn markIdentsEscape(ctx: *Ctx, e: *const ast.Expression) void {
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(ctx.an.alloc);
    collectIdents(e, &ids, ctx.an.alloc);
    for (ids.items) |n| ctx.markEscape(n);
}

/// Extract the callee's name and whether the call is a method call.
///
/// Returns `{ name, method = false }` for a bare `foo(...)`, `{ field, method =
/// true }` for `obj.bar(...)`, and null for any other callee shape (an indirect
/// or computed callee we cannot name). The `method` flag tells [`applyCall`] to
/// treat the receiver as an implicit first parameter when indexing the summary.
fn calleeName(callee: *const ast.Expression) ?struct { name: []const u8, method: bool } {
    return switch (callee.kind) {
        .ident => |n| .{ .name = n, .method = false },
        .field_access => |fa| .{ .name = fa.field, .method = true },
        else => null,
    };
}

/// Propagate escape through a call, using the callee's summary when known.
///
/// For a named callee with a summary, an argument's identifiers are marked
/// escaping only if the corresponding parameter bit is set (or the position is
/// beyond the summary length, treated as escaping). For a method call the
/// receiver is parameter 0 and the explicit args shift by `base = 1`.
///
/// When the callee is unnameable ([`calleeName`] returns null) or has no summary
/// yet, EVERY argument (and the receiver) is marked escaping. That pessimism is
/// deliberate: an opaque or not-yet-analysed callee might retain anything handed
/// to it, and over-marking is the safe direction. During the outer fixpoint a
/// callee's summary sharpens over rounds, so genuinely-local arguments stop being
/// marked once its summary is known.
fn applyCall(ctx: *Ctx, callee: *const ast.Expression, args: []const ast.Expression) void {
    const cn = calleeName(callee);
    if (cn == null) {
        for (args) |*arg| markIdentsEscape(ctx, arg);
        return;
    }
    const summary = ctx.an.summaryFor(cn.?.name);
    const is_method = cn.?.method;
    const recv: ?*const ast.Expression = if (is_method) callee.kind.field_access.object else null;
    const base: usize = if (is_method) 1 else 0;
    if (summary) |esc| {
        if (recv) |r| {
            if (esc.len == 0 or esc[0]) markIdentsEscape(ctx, r);
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

/// Recurse into `e` to find and process nested calls and closures.
///
/// This walk does NOT itself mark escapes for ordinary subexpressions; its job is
/// to reach every call (so [`applyCall`] runs on it) and every closure (whose
/// captured identifiers escape, since the closure may outlive the frame). Escape
/// marking for direct sinks is driven by [`walkStmt`]. A closure body is handled
/// by marking all identifiers in its expression or statements as escaping via
/// [`markIdentsEscape`]/[`markStmtIdentsEscape`], the conservative "anything a
/// closure touches, it captures" rule.
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

/// Mark every identifier in statement `s` (and its nested statements) as
/// escaping.
///
/// Used for closure bodies of the block form: a closure can outlive the enclosing
/// frame, so anything its body names is conservatively treated as captured and
/// therefore escaping. Recurses through control-flow statements; expression and
/// let/return statements funnel their expressions to [`markIdentsEscape`].
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

/// The name of `e` if it is a bare identifier, else null.
///
/// Distinguishes the simple `x = y` / `let x = y` case (where an assignment
/// [`Edge`] can be recorded) from a right-hand side that is any richer
/// expression (handled by marking identifiers escaping instead).
fn identName(e: *const ast.Expression) ?[]const u8 {
    return switch (e.kind) {
        .ident => |n| n,
        else => null,
    };
}

/// Walk one statement, driving the three data collections of the analysis.
///
/// Per statement kind:
///
///   * `let x = init` — if `init` is heap-owning ([`isOwned`]) and this is a
///     single-name binding, record `x` as an allocation site. If `init` is a bare
///     identifier, record an `x = init` [`Edge`] so escape can flow. Then recurse
///     into `init` for nested calls. (Destructuring `let`s, where `names != null`,
///     are skipped for both.)
///   * assignment `lhs = rhs` — a field or index LHS means the object is stored
///     into aliasable memory, so `rhs`'s identifiers escape immediately. An
///     identifier LHS records an edge instead. Any other LHS just walks `rhs`.
///   * `return v` — `v`'s identifiers escape (they leave the function).
///   * control flow (`if`/`while`/`for`/`switch`/`defer`/`block`) — recurse into
///     conditions, sub-statements, and loop clauses to reach nested calls,
///     assignments, and returns.
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
