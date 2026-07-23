// ownership.zig — the ownership pass (arc.md §5), increment 1: owned-local dup/drop ops + the
// §6.1 STATIC BALANCE CHECK, run in SHADOW.
//
// WHERE THIS SITS. F2-6 stage 5 step 1 (`a653a17`) proved the CHECKER can decide the ownership
// DISPOSITION of each expression (owned/borrowed) and that it agrees with codegen everywhere but two
// documented keystone gaps. Step 2 (this file) is the next piece arc.md §1.4/§5/§6.1 calls for: turn
// that disposition into the actual `dup`/`drop`/`move` OPERATIONS and PROVE they balance — every owned
// value consumed exactly once. This is the "provable" upgrade: a leak or double-free becomes a located
// BUILD error, not a runtime surprise months later.
//
// WHY LOCALS FIRST (the tractability finding from step 1). A temporary's retain (on the value) and its
// release (on a spill SLOT) are DIFFERENT LLVM SSA refs, so a codegen-side ledger over temporaries is
// intractable. A NAMED local has a stable slot and a stable name — its lifetime is analyzable from the
// AST alone. So increment 1 targets owned `let`-locals, where the analysis is sound and self-contained.
//
// WHAT IT PROVES, HONESTLY. Per function it walks the body and, for each owned let-local, inserts the
// §2 ops (a scope-exit `drop`, a `move` when the value is returned/rebound, a PER-EDGE `drop` on the
// branch of an `if` that does not consume it) and asserts the §1.3 invariant: exactly one terminal
// consumer on every path, and NO use after a move. Nova's control flow is STRUCTURED (if/while/for —
// no gotos), so backward last-use is expressible as a forward walk with a per-path ownership state and
// a branch-MERGE (increment 3). Still DEFERRED (no balance claim): a loop body that MOVES the local
// (re-move per iteration), a reassignment, a shadow re-bind, a `switch`/`break`/`continue` touching it,
// a use inside a closure/if_expr/block_expr/catch, or an init with no TypeId in the IR. Those and
// TEMPORARIES are later increments. Report-only under NOVA_SEMA_SHADOW — codegen behaviour is untouched.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const infer = @import("infer.zig");

const TypeStore = types.TypeStore;
const TypedIr = infer.TypedIr;

pub const Stats = struct {
    fns_walked: usize = 0,
    owned_locals: usize = 0, // owned `let`-locals discovered
    analyzed: usize = 0, // fully analyzed — a balance claim WAS made and held
    deferred_cfg: usize = 0, // lifetime crosses nested control flow / reassigned / shadowed
    deferred_untyped: usize = 0, // init had no concrete TypeId in the IR (a coverage gap, not a claim)
    drop_ops: usize = 0, // scope-exit `drop`s inserted (owned local not moved out)
    move_outs: usize = 0, // owned locals moved out (return / rebind) — no drop
    dup_ops: usize = 0, // `dup`s inserted for a local moved out more than once
    balance_violations: usize = 0, // §1.3 invariant broken — MUST be 0
    first_violation: []const u8 = "",

    // ── owned TEMPORARIES (the class intractable to self-check at codegen) ──────────────────────
    // An owned temporary is an expression occurrence that PRODUCES a +1 not bound to a name (a call
    // returning managed, a constructor, a string/template, an aggregate literal). The disposition
    // oracle (step 1) already marks these `ir.ownedOf == true`; here we give each its consumer:
    // MOVED (into a bind/return/aggregate element) or DROPPED at the enclosing statement's end. This
    // is the pass-side model of codegen's `registerTemporary`/`consumeTemporary`/`drainTemporaries` —
    // and because step 1 proved `ownedOf` agrees with codegen's `acquisitionDisposition` (the very
    // gate that registers a temp), these counts are directly comparable to codegen's (shadow.zig
    // prints the pass↔codegen diff). Closures interiors are NOT descended (a known undercount, same
    // gap as the locals walk) — the honest boundary of this increment.
    temp_moves: usize = 0, // owned temps moved into a bind/return/aggregate element
    temp_drops: usize = 0, // owned temps dropped at the enclosing statement's end
};

/// Analyze the whole program. Reads the TypedIr for types/dispositions; RECORDS the per-temp ownership
/// op back into it (`expr_op`) so codegen can shadow-diff at the drop site (stage 5 step 5). The balance
/// check over locals never mutates the IR.
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

// ── owned-temporary accounting ─────────────────────────────────────────────────────────────────
// Walk every expression, giving each owned-producer occurrence (`ir.ownedOf == true`) its consumer:
// MOVED when it sits in a move POSITION (a bind/return value, or an element of an aggregate literal),
// otherwise DROPPED at the enclosing statement's end. The `moved` flag is the position context, threaded
// down: aggregate elements set it true; a call's args/callee/receiver, binary operands, template parts,
// and the top of an expr-statement set it false; a branch construct (if-expr/??/catch) INHERITS its
// parent's position, since it forwards the selected value.

fn tempStmt(alloc: std.mem.Allocator, ir: *TypedIr, s: *const ast.Statement, st: *Stats) void {
    switch (s.*) {
        .block => |b| for (b.statements) |*x| tempStmt(alloc, ir, x, st),
        // A single bind CONSUMES the init temp (move). A DESTRUCTURING bind (`let (a,b) = e`) extracts the
        // elements out and DROPS the aggregate box — so its init is a drop, not a move (matches codegen).
        .let_stmt => |ls| if (ls.init) |init| tempExpr(alloc, ir, &init, ls.names == null, st),
        .return_stmt => |r| if (r.value) |v| tempExpr(alloc, ir, &v, true, st), // moved to caller
        .expr_stmt => |es| tempExpr(alloc, ir, &es.expr, false, st), // top temp dropped at stmt end
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
    // Account THIS occurrence if it is an owned producer temp — and RECORD its op into the IR so codegen
    // can shadow-diff at the exact site it acts (a move → `consumeTemporary`, a drop → `drainTemporaries`).
    if (ir.ownedOf(e)) |owned| {
        if (owned) {
            if (moved) st.temp_moves += 1 else st.temp_drops += 1;
            ir.recordOp(alloc, e, if (moved) .move else .drop) catch {};
        }
    }
    // Recurse, setting each child's position.
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
            // `x = e` MOVES `e` into the target (codegen `consumeTemporary`s it), so the RHS is a move
            // position — not a stmt-end drop. Every other binary borrows both operands (produces a new
            // value, e.g. `a + b`), so they are drops.
            tempExpr(alloc, ir, b.left, false, st);
            tempExpr(alloc, ir, b.right, b.op == .assign, st);
        },
        .unary => |u| tempExpr(alloc, ir, u.operand, false, st),
        .field_access => |fa| tempExpr(alloc, ir, fa.object, false, st),
        .index => |ix| {
            tempExpr(alloc, ir, ix.object, false, st);
            tempExpr(alloc, ir, ix.index, false, st);
        },
        .cast => |c| tempExpr(alloc, ir, c.expr, moved, st), // the cast forwards its operand's value
        .optional_chaining => |oc| tempExpr(alloc, ir, oc.object, false, st),
        .nullish_coalesce => |nc| {
            // `a ?? b`: `a` (the optional) is CONSUMED by the `??` (unwrapped or discarded) regardless of
            // where the whole expression sits — so it is always a move. `b` becomes the result value and
            // inherits the parent position.
            tempExpr(alloc, ir, nc.left, true, st);
            tempExpr(alloc, ir, nc.right, moved, st);
        },
        .template_expr => |t| for (t.parts) |*p| tempExpr(alloc, ir, p, false, st),
        .tuple => |elems| for (elems) |*x| tempExpr(alloc, ir, x, true, st), // aggregate element → moved in
        .struct_init => |si| for (si.fields) |*fld| tempExpr(alloc, ir, &fld.value, true, st),
        .enum_init => |ei| for (ei.fields) |*fld| tempExpr(alloc, ir, &fld.value, true, st),
        .if_expr => |ie| {
            // The PHI consumes the selected branch's value (codegen `takeOwnedElement`s each branch in
            // its own block), so a fresh branch temp is always MOVED — regardless of where the if-expr
            // sits. It is the if-expr RESULT (the phi, this node, accounted above) that inherits the
            // parent position, not the branches.
            tempExpr(alloc, ir, ie.condition, false, st);
            tempExpr(alloc, ir, ie.then_branch, true, st);
            tempExpr(alloc, ir, ie.else_branch, true, st);
        },
        .block_expr => |b| for (b.statements) |*s| tempStmt(alloc, ir, s, st),
        // `try e` / `e catch h`: the error-union BOX (the operand) is consumed by the construct — on the
        // ok path codegen extracts the payload and DROPS the box; the unwrapped payload (this node) is
        // what flows onward and inherits the parent position. So the operand is a drop, not a move.
        .try_expr => |t| tempExpr(alloc, ir, t, false, st),
        .catch_expr => |c| {
            tempExpr(alloc, ir, c.expr, false, st);
            tempExpr(alloc, ir, c.handler, moved, st); // the handler value becomes the result
        },
        .await_expr, .go_expr => |a| tempExpr(alloc, ir, a.operand, false, st),
        // A closure body is its OWN function scope. Descend it so its owned temps are accounted too —
        // the expr-body form returns its value (moved out of the closure); the block-body form is a
        // statement sequence whose top-level temps drop at their own statement ends.
        .closure => |cl| switch (cl.body) {
            .expr => |ce| tempExpr(alloc, ir, ce, true, st),
            .block => |b| for (b.statements) |*s| tempStmt(alloc, ir, s, st),
        },
        else => {},
    }
}

/// Walk a statement list. Owned `let`-locals declared here are analyzed against the REMAINDER of this
/// same list (their in-scope lifetime); nested blocks are recursed into so locals declared inside them
/// are analyzed within their own scope. A top-level local used inside one of those nested blocks is
/// DEFERRED by `analyzeOwnedLocal` (it sees the nested statement mention the name).
fn analyzeStmts(stmts: []const ast.Statement, store: *const TypeStore, ir: *const TypedIr, st: *Stats) void {
    for (stmts, 0..) |*s, i| {
        // Recurse into nested scopes so their own locals are analyzed.
        recurseIntoNested(s, store, ir, st);

        if (s.* != .let_stmt) continue;
        const ls = s.let_stmt;
        // Destructuring binds (`let (a, b) = …`) are not single-owner locals — defer.
        if (ls.names != null) continue;
        const init = ls.init orelse continue;

        // OWNERSHIP ORACLE — the SAME TypeId decision the disposition oracle uses (never a string).
        const tid = ir.typeOf(&init) orelse {
            // No concrete type recorded → cannot confirm managed. Might be an owned local we simply
            // can't see yet (an untyped generic-return init). Count it honestly as a coverage gap;
            // do NOT silently treat it as trivial (that is exactly the string-guess bug class).
            if (initCouldBeOwned(&init)) {
                st.owned_locals += 1;
                st.deferred_untyped += 1;
            }
            continue;
        };
        if (!store.isOwnedSafe(tid)) continue; // trivial (int/bool/ptr/…): no ARC, nothing to do.

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

/// The state of an owned local ON A PATH: `live` (still holds its +1) or `moved` (its +1 was
/// transferred to a bind/return, so reading it now is a use-after-move).
const St = enum { live, moved };

/// The result of walking a statement/sequence for one local, from a given entry state.
const Flow = union(enum) {
    /// Control fell through to the next statement with the local in this state.
    fallthrough: St,
    /// This path left the function (a `return`); no fall-through. The local was already consumed
    /// (moved by `return v`, or dropped before a `return other`).
    returned,
    /// An unhandled construct (loop that MOVES the local, reassignment, shadow, switch/break/continue,
    /// or a complex-expr use) — abandon this local's analysis, make no balance claim.
    deferred,
    /// The §1.3 invariant is broken on some path (a use-after-move).
    violation,
};

/// §6.1 for one owned local `name`, over the statements that follow its binding. Nova's control flow is
/// STRUCTURED (if/while/for/switch — no arbitrary gotos), so backward last-use is expressible as this
/// forward walk with a per-path ownership state and a branch-MERGE: where one `if` branch moves the
/// local and the other does not, a PER-EDGE `drop` is inserted on the non-moving branch so every path
/// consumes it exactly once (the Perceus rule, arc.md §6.1 / risk §9). Folds its result into `st`.
fn analyzeOwnedLocal(name: []const u8, rest: []const ast.Statement, st: *Stats) void {
    switch (walkSeq(name, rest, .live, st)) {
        .fallthrough => |s| {
            // The local is still around at scope exit: `drop` if never moved, else it left by a move.
            if (s == .live) st.drop_ops += 1 else st.move_outs += 1;
            st.analyzed += 1;
        },
        // Every path returned; its consumers (move-outs / pre-return drops) were counted inside.
        .returned => st.analyzed += 1,
        .deferred => st.deferred_cfg += 1,
        .violation => {
            st.balance_violations += 1;
            if (st.first_violation.len == 0) st.first_violation = name;
        },
    }
}

/// Walk a statement SEQUENCE, threading the local's state. A `returned`/`deferred`/`violation` from any
/// statement short-circuits the rest of the sequence (unreachable / abandoned).
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

/// Walk one statement. A bare `return name` / `let y = name` MOVES the local (ownership transfers, no
/// dup — codegen moves a bare ident); anything else that merely mentions it is a BORROW (even
/// `Foo{ f: name }`, since the aggregate store DUPs a borrowed element — arc.md §2 / `takeOwnedElement`).
/// A borrow while `moved` is a use-after-move. Constructs the increment does not model soundly `defer`.
fn walkStmt(name: []const u8, s: *const ast.Statement, state: St, st: *Stats) Flow {
    switch (s.*) {
        .block => |b| return walkSeq(name, b.statements, state, st),

        .let_stmt => |ls| {
            if (std.mem.eql(u8, ls.name, name)) return .deferred; // re-bind / shadow
            if (ls.init) |init| {
                if (mentionsComplex(&init, name)) return .deferred;
                if (isIdent(&init, name)) { // MOVE-out
                    if (state == .moved) return .violation; // moved twice with no intervening re-bind
                    return .{ .fallthrough = .moved };
                }
                if (mentions(&init, name)) { // borrow into the init
                    if (state == .moved) return .violation;
                    return .{ .fallthrough = state };
                }
            }
            return .{ .fallthrough = state };
        },

        .expr_stmt => |es| {
            // Reassignment to the local (`name = e`) needs the §2 drop-old rule — a later increment.
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
                if (isIdent(&val, name)) { // `return name` — MOVE to caller
                    if (state == .moved) return .violation;
                    st.move_outs += 1;
                    return .returned;
                }
                if (mentions(&val, name)) { // borrow of the local inside the returned value
                    if (state == .moved) return .violation;
                }
            }
            // The function returns while the local is still live → it dies here: a pre-return `drop`.
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

        // switch / break / continue / defer: not modeled yet. Safe only if they never touch the local.
        .switch_stmt, .break_stmt, .continue_stmt, .defer_stmt => {
            if (stmtMentions(s, name)) return .deferred;
            return .{ .fallthrough = state };
        },
    }
}

/// Merge the two arms of an `if`. Both return → the whole `if` returns. One returns, the other falls
/// through → continue with the survivor's state. Both fall through with DIFFERENT states (one moved the
/// local, one did not) → insert a PER-EDGE `drop` on the branch that left it live, unifying to `moved`
/// so every path has consumed it exactly once (arc.md §6.1).
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
    if (st_then == null and st_else == null) return .returned; // both branches returned
    if (st_then == null) return .{ .fallthrough = st_else.? };
    if (st_else == null) return .{ .fallthrough = st_then.? };
    if (st_then.? == st_else.?) return .{ .fallthrough = st_then.? };
    // One branch moved the local, the other left it live → per-edge drop on the live branch.
    st.drop_ops += 1;
    return .{ .fallthrough = .moved };
}

/// A loop borrows the local across iterations. Modeled soundly ONLY when the body does not MOVE it (a
/// move inside a loop would re-move a consumed value each iteration — deferred) and does not touch it
/// through a complex expression. A borrow-only loop leaves the local `live` for the drop at scope exit.
fn walkLoop(name: []const u8, cond: ?*const ast.Expression, body: *const ast.Statement, state: St, st: *Stats) Flow {
    if (cond) |c| {
        if (mentionsComplex(c, name)) return .deferred;
        if (mentions(c, name) and state == .moved) return .violation;
    }
    if (seqMovesLocal(name, body)) return .deferred; // move-in-loop — a later increment
    if (stmtComplexMentions(name, body)) return .deferred;
    if (state == .moved and stmtMentions(body, name)) return .violation; // borrow after move
    _ = st;
    return .{ .fallthrough = state };
}

/// Does statement `s` MOVE `name` (a bare `return name` / `let y = name`) anywhere within it? Used to
/// defer loops whose body moves the local.
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

/// Does `s` mention `name` inside a COMPLEX expression (closure/if_expr/block_expr/catch) — control
/// flow the walk does not descend into? Such a use is deferred.
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

// ── expression predicates ─────────────────────────────────────────────────────────────────────

fn isIdent(e: *const ast.Expression, name: []const u8) bool {
    return e.kind == .ident and std.mem.eql(u8, e.kind.ident, name);
}

/// Does `s` mention `name` anywhere (used only for the nested-CF defer test)?
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

/// Does `name` appear inside a COMPLEX sub-expression (closure/if_expr/block_expr/catch) of `e`? Such a
/// use has its own control flow the straight-line model does not track → defer.
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

/// Does `e` read the identifier `name` anywhere? Conservative: unknown kinds return false (they are
/// handled by the defer path, which errs toward deferring, so a missed mention cannot cause a false
/// balance CLAIM — at worst it defers).
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

/// Could this `let` init produce an OWNED value? Used only to count an untyped init honestly as a
/// coverage gap rather than silently assuming trivial. A pure numeric/bool literal cannot be owned;
/// anything else (a call, a constructor, a string/array/object literal, an ident) might be.
fn initCouldBeOwned(e: *const ast.Expression) bool {
    return switch (e.kind) {
        .literal => |lit| switch (lit) {
            .integer, .float, .bool, .null, .undefined => false,
            else => true,
        },
        else => true,
    };
}
