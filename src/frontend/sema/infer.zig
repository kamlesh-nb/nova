//! Best-effort type inference over the parsed AST, producing the typed IR the
//! rest of the compiler consumes.
//!
//! This is the authoritative "what type is every expression" pass. It walks
//! each function body, threads an OPTIONAL expected type inwards (so a literal
//! or closure can be shaped by its context), and records the result of every
//! expression into a [`TypedIr`] keyed by the expression's stable
//! [`ast.ExprId`]. Codegen and the ownership/ARC passes then look up those
//! recorded types instead of re-deriving them.
//!
//! The guiding principle is HONESTY over guessing. When the inferer cannot
//! prove a type it returns the store's `unresolved` type rather than a
//! plausible-looking default. That is why comparisons are `bool` (not `i32`),
//! an integer literal is `int` (not the machine word), and `a + b` over two
//! unknown idents stays `unresolved`. An unresolved result is not a hard error
//! by itself: much of the pipeline can still proceed, and the [`Stats`]
//! counters plus [`TypedIr.unresolvedCount`] give an honest coverage figure.
//! A small set of genuinely fatal cases (an unresolvable bare identifier that
//! is not a known module/builtin, or a call into a known module that names no
//! such function) are counted separately on the [`Inferer`] so the driver can
//! reject the program.
//!
//! Beyond typing, the pass doubles as a lightweight semantic checker and
//! records a family of deferred diagnostics into per-kind error lists on the
//! [`Inferer`] (visibility violations, const reassignment, dereferencing an
//! optional/error-union without unwrapping, catch-arm and try error-type
//! mismatches, non-bool conditions, returning an optional where a plain type is
//! declared, and method arity). These are collected rather than thrown so the
//! driver can report them together after the walk.
//!
//! Two features make the walk subtle and are worth calling out. First,
//! FLOW-SENSITIVE NARROWING: `if (s != undefined)` rebinds `s` from
//! `optional<T>` to `T` inside the guarded branch (and an early-exit
//! `if (s == undefined) return;` narrows the rest of the statement sequence),
//! implemented via a scoped shadow binding, see [`Inferer.narrowedBranch`] and
//! [`earlyExitNarrowing`]. Second, GENERICS: monomorphisation is driven from
//! here. When a call's type arguments can be solved to fully concrete types the
//! pass substitutes them into the return type AND notifies [`mono`] to emit the
//! concrete instantiation, so the type engine and the code emitter agree on
//! exactly which specialisations exist.
//!
//! Recursion is bounded: [`Inferer.inferExprInner`] increments a depth counter
//! and bails with `error.TypeInferenceRecursionLimit` past 2000 frames, so a
//! pathological or cyclic AST cannot blow the native stack.

const std = @import("std");
/// AST node definitions (`Expression`, `Statement`, `FunctionDecl`, ...) that
/// this pass walks; the input to inference.
const ast = @import("../ast.zig");
/// Assigns stable [`ast.ExprId`]s to expressions; used only by the tests here
/// to stamp ids so recorded types can be read back by identity.
const ids = @import("ids.zig");
/// Type-parameter substitution over interned types: solve a type param from an
/// actual argument, then rewrite it out of a return type.
const subst = @import("subst.zig");
/// The interned type store and the `TypeId` handle vocabulary everything below
/// speaks in.
const types = @import("../types.zig");
/// The symbol table: functions, types, methods, constants, and modules keyed by
/// name and module.
const symbols = @import("symbols.zig");
/// Lowers a syntactic [`ast.TypeRef`] into an interned [`TypeId`], honouring the
/// active type-parameter scopes.
const lower = @import("lower.zig");
/// The compiler's intrinsic/receiver builtins table (`bytes`, `console`, ...);
/// consulted to type builtin receivers and extern calls.
const builtins = @import("builtins.zig");
/// The monomorphisation registry: the pass notes concrete generic
/// instantiations here so the code emitter specialises exactly those.
const mono = @import("mono.zig");

/// Re-export of the type store's opaque type handle, so callers of this module
/// spell it `infer.TypeId` without importing `types` directly.
pub const TypeId = types.TypeId;

/// Running counters that quantify how much of a program the inferer could type,
/// and where it fell short.
///
/// These are diagnostic, not load-bearing for correctness: they let the driver
/// print an honest coverage figure and let the tests assert that guessing did
/// not creep back in. Note that several call sites deliberately UNDO an earlier
/// `typed` bump (`stats.typed -|= 1`) when a sub-expression was only visited to
/// reach its parent, so `typed` counts distinct typed results, not visits.
pub const Stats = struct {
    /// Number of expressions the pass assigned a concrete (non-unresolved) type.
    typed: usize = 0,
    /// Number of times the pass gave up and returned the store's `unresolved`
    /// type. Broken down by syntactic cause in [`Stats.by_tag`].
    unresolved: usize = 0,

    /// Unresolved bare identifiers that are NOT treated as fatal, e.g. a `self`
    /// or a name that resolves to a known module segment. Kept apart from the
    /// fatal count on [`Inferer`] so tolerable misses do not sink the build.
    unresolved_ns_ident: usize = 0,
    /// Unresolved field accesses whose object is an unknown-but-non-fatal name
    /// (module-qualified access that could not be typed), counted separately for
    /// the same reason as [`Stats.unresolved_ns_ident`].
    unresolved_ns_field: usize = 0,

    /// Histogram of unresolved results keyed by a short cause tag (`"binary"`,
    /// `"call"`, `"closure"`, ...), populated by [`Inferer.unresolved`]. Keys
    /// are borrowed string literals, so no ownership is transferred.
    by_tag: std.StringHashMapUnmanaged(usize) = .empty,

    /// Histogram of the specific names that failed to resolve (idents/fields),
    /// populated by [`Inferer.note`]. Useful for spotting a single missing
    /// import that cascades into many misses.
    by_name: std.StringHashMapUnmanaged(usize) = .empty,

    /// Frees the two histogram maps. The counter fields are plain integers and
    /// need no cleanup; only the hash maps own heap.
    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.by_tag.deinit(allocator);
        self.by_name.deinit(allocator);
    }
};

/// One local variable in scope: its name, current type, and whether it was
/// introduced with `const` (so a reassignment can be flagged). The `ty` is
/// mutable in place, which is how narrowing and same-name reassignment update a
/// binding via [`Inferer.rebind`].
const Binding = struct { name: []const u8, ty: TypeId, is_const: bool = false };

/// How an owned value flows out of an expression: `move` transfers ownership,
/// `drop` means the temporary is consumed here. Recorded per expression so the
/// ARC pass knows whether to emit a retain/release.
pub const OwnOp = enum { move, drop };

/// Key for the per-instantiation IR maps: an expression together with the
/// concrete monomorphic type it is being specialised for. The same syntactic
/// expression can carry different types across different generic
/// instantiations, so a bare [`ast.ExprId`] is not enough.
pub const InstKey = struct { id: ast.ExprId, inst: TypeId };

/// Key for [`TypedIr.tp_resolve`]: a type parameter and the instantiation in
/// which we are resolving it, mapping to the concrete type it binds to there.
pub const TpKey = struct { tp: TypeId, inst: TypeId };

/// The typed IR: the durable output of this pass, mapping each stable
/// [`ast.ExprId`] to what inference learned about it.
///
/// Everything downstream (codegen, ownership/ARC) reads from here rather than
/// re-inferring. All maps are keyed by expression id, and the constructors
/// uniformly refuse `.unassigned` ids so that every un-walked expression does
/// NOT collide on id 0. The `*Inst` maps carry per-monomorphisation overrides
/// for the cases where one expression has different types in different generic
/// instantiations.
pub const TypedIr = struct {

    /// The core map: expression id to its inferred [`TypeId`]. See
    /// [`TypedIr.typeOf`] / [`TypedIr.record`].
    expr_types: std.AutoHashMapUnmanaged(ast.ExprId, TypeId) = .empty,

    /// Resolved symbol behind an expression (which concrete function/method a
    /// call actually binds to), when unambiguous. See [`TypedIr.symOf`].
    expr_syms: std.AutoHashMapUnmanaged(ast.ExprId, types.SymbolId) = .empty,

    /// For a generic call/method, the concrete type arguments solved for it.
    /// The slice is OWNED (duped) per entry; [`TypedIr.deinit`] frees each
    /// distinct pointer once (de-duplicated) to avoid a double free.
    expr_method_args: std.AutoHashMapUnmanaged(ast.ExprId, []const TypeId) = .empty,

    /// Whether the expression yields a fresh OWNED value (a heap temporary the
    /// caller must release) versus a borrow. Drives ARC. See
    /// [`Inferer.ownedDisposition`].
    expr_owned: std.AutoHashMapUnmanaged(ast.ExprId, bool) = .empty,

    /// The ownership operation ([`OwnOp`]) to apply at this expression, when one
    /// was decided.
    expr_op: std.AutoHashMapUnmanaged(ast.ExprId, OwnOp) = .empty,

    /// Per-instantiation override of [`TypedIr.expr_owned`], keyed by
    /// [`InstKey`], for expressions whose ownership differs across generic
    /// specialisations.
    expr_owned_inst: std.AutoHashMapUnmanaged(InstKey, bool) = .empty,

    /// Per-instantiation override of [`TypedIr.expr_types`], keyed by
    /// [`InstKey`].
    expr_types_inst: std.AutoHashMapUnmanaged(InstKey, TypeId) = .empty,

    /// Resolution of a type parameter within a given instantiation, keyed by
    /// [`TpKey`]; how a `T` becomes a concrete type inside one monomorphic body.
    tp_resolve: std.AutoHashMapUnmanaged(TpKey, TypeId) = .empty,

    /// Count of `record` calls dropped because the expression had an
    /// `.unassigned` id. A non-zero value in production would mean ids were not
    /// stamped before inference.
    unassigned_rejected: usize = 0,

    /// Frees every map. The subtle part is [`TypedIr.expr_method_args`]: its
    /// values are owned slices, but the same slice pointer can be stored under
    /// several ids, so this de-duplicates by pointer before freeing to avoid a
    /// double free.
    pub fn deinit(self: *TypedIr, allocator: std.mem.Allocator) void {
        self.expr_types.deinit(allocator);
        self.expr_syms.deinit(allocator);
        var freed = std.AutoHashMap(usize, void).init(allocator);
        var mit = self.expr_method_args.valueIterator();
        while (mit.next()) |v| {
            if (v.*.len == 0) continue;
            const gop = freed.getOrPut(@intFromPtr(v.*.ptr)) catch {
                allocator.free(v.*);
                continue;
            };
            if (!gop.found_existing) allocator.free(v.*);
        }
        freed.deinit();
        self.expr_method_args.deinit(allocator);
        self.expr_owned.deinit(allocator);
        self.expr_op.deinit(allocator);
        self.expr_owned_inst.deinit(allocator);
        self.expr_types_inst.deinit(allocator);
        self.tp_resolve.deinit(allocator);
    }

    /// Records the owned/borrow disposition for `id` under a specific
    /// instantiation `inst`. Silently ignores `.unassigned` ids (see the map
    /// docs on [`TypedIr`]).
    pub fn recordOwnedInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, owned: bool) !void {
        if (id == .unassigned) return;
        try self.expr_owned_inst.put(allocator, .{ .id = id, .inst = inst }, owned);
    }

    /// Reads back the per-instantiation ownership recorded by
    /// [`TypedIr.recordOwnedInst`], or null if none (or the id is unassigned).
    pub fn ownedOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?bool {
        if (id == .unassigned) return null;
        return self.expr_owned_inst.get(.{ .id = id, .inst = inst });
    }

    /// Records the type of `id` under a specific instantiation `inst`, for
    /// expressions whose type varies across monomorphic specialisations.
    pub fn recordTypeInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, t: TypeId) !void {
        if (id == .unassigned) return;
        try self.expr_types_inst.put(allocator, .{ .id = id, .inst = inst }, t);
    }

    /// Reads back the per-instantiation type recorded by
    /// [`TypedIr.recordTypeInst`], or null.
    pub fn typeOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types_inst.get(.{ .id = id, .inst = inst });
    }

    /// Records that type parameter `tp`, within instantiation `inst`, binds to
    /// the concrete type `concrete`. Unlike the id-keyed maps there is no
    /// `.unassigned` guard because the key is a type param, not an expression.
    pub fn recordTpResolve(self: *TypedIr, allocator: std.mem.Allocator, tp: TypeId, inst: TypeId, concrete: TypeId) !void {
        try self.tp_resolve.put(allocator, .{ .tp = tp, .inst = inst }, concrete);
    }

    /// Reads back the concrete binding of type parameter `tp` in instantiation
    /// `inst`, or null.
    pub fn tpResolve(self: *const TypedIr, tp: TypeId, inst: TypeId) ?TypeId {
        return self.tp_resolve.get(.{ .tp = tp, .inst = inst });
    }

    /// Records the ownership operation ([`OwnOp`]) chosen for expression `e`.
    pub fn recordOp(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, op: OwnOp) !void {
        if (e.id == .unassigned) return;
        try self.expr_op.put(allocator, e.id, op);
    }

    /// Reads back the [`OwnOp`] recorded for the expression id, or null.
    pub fn opOf(self: *const TypedIr, id: ast.ExprId) ?OwnOp {
        if (id == .unassigned) return null;
        return self.expr_op.get(id);
    }

    /// Looks up an expression's recorded type by RAW id (not by
    /// `*const Expression`). The `2` suffix distinguishes it from
    /// [`TypedIr.typeOf`], which takes the expression pointer.
    pub fn typeOf2(self: *const TypedIr, id: ast.ExprId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types.get(id);
    }

    /// Records whether expression `e` yields an owned value. Called for every
    /// expression from [`Inferer.inferExprExpecting`].
    pub fn recordOwned(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, owned: bool) !void {
        if (e.id == .unassigned) return;
        try self.expr_owned.put(allocator, e.id, owned);
    }

    /// Reads back the owned/borrow disposition recorded for `e`, or null.
    pub fn ownedOf(self: *const TypedIr, e: *const ast.Expression) ?bool {
        if (e.id == .unassigned) return null;
        return self.expr_owned.get(e.id);
    }

    /// Counts how many expressions were recorded as owned (`true`). A cheap
    /// health metric for the ARC pass.
    pub fn ownedTrueCount(self: *const TypedIr) usize {
        var n: usize = 0;
        var it = self.expr_owned.valueIterator();
        while (it.next()) |v| {
            if (v.*) n += 1;
        }
        return n;
    }

    /// Records the solved concrete type arguments of a generic call/method on
    /// `e`, taking a fresh OWNED copy of `args`. Any previously stored slice for
    /// this id is freed first, so re-recording is safe and does not leak.
    pub fn recordMethodArgs(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, args: []const TypeId) !void {
        if (e.id == .unassigned) return;
        if (self.expr_method_args.get(e.id)) |old| allocator.free(old);
        const dup = try allocator.dupe(TypeId, args);
        try self.expr_method_args.put(allocator, e.id, dup);
    }

    /// Reads back the solved type arguments recorded for `e`, or null. The
    /// slice is borrowed from the map; do not free it.
    pub fn methodArgsOf(self: *const TypedIr, e: *const ast.Expression) ?[]const TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_method_args.get(e.id);
    }

    /// Records which concrete symbol `e` resolved to (the callee of a call).
    /// Only recorded when the resolution is unambiguous, so codegen can bind
    /// directly instead of re-doing name lookup.
    pub fn recordSym(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, sid: types.SymbolId) !void {
        if (e.id == .unassigned) return;
        try self.expr_syms.put(allocator, e.id, sid);
    }

    /// Reads back the resolved symbol recorded for `e`, or null.
    pub fn symOf(self: *const TypedIr, e: *const ast.Expression) ?types.SymbolId {
        if (e.id == .unassigned) return null;
        return self.expr_syms.get(e.id);
    }

    /// Records the inferred type of `e`. An `.unassigned` id is rejected and
    /// bumps [`TypedIr.unassigned_rejected`] rather than being stored, so
    /// un-walked expressions never all collide on id 0.
    pub fn record(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, t: TypeId) !void {
        if (e.id == .unassigned) {
            self.unassigned_rejected += 1;
            return;
        }
        try self.expr_types.put(allocator, e.id, t);
    }

    /// Looks up the recorded type of `e` by its pointer's id, or null. The
    /// primary read path for downstream passes.
    pub fn typeOf(self: *const TypedIr, e: *const ast.Expression) ?TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_types.get(e.id);
    }

    /// Total number of expressions with a recorded type.
    pub fn count(self: *const TypedIr) usize {
        return self.expr_types.count();
    }

    /// How many recorded expressions still carry the `unresolved` type: the
    /// honest coverage gap. Requires the store to classify each recorded id.
    pub fn unresolvedCount(self: *const TypedIr, store: *const types.TypeStore) usize {
        var n: usize = 0;
        var it = self.expr_types.valueIterator();
        while (it.next()) |t| {
            if (store.get(t.*) == .unresolved) n += 1;
        }
        return n;
    }
};

/// The result of recognising an `x != undefined` / `x == undefined` guard: the
/// binding `name` to narrow, and in which branch (`when_true`) the narrowing
/// applies. Consumed by [`Inferer.narrowedBranch`] and
/// [`Inferer.inferStmtSeq`].
const Narrowing = struct {
    /// The identifier being compared against `undefined`.
    name: []const u8,

    /// True if narrowing applies when the condition is TRUE (the `!=` case:
    /// inside the then-branch the value is present); false for `==` (the value
    /// is present in the else-branch instead).
    when_true: bool,
};

/// Recognises a `binding != undefined` or `binding == undefined` comparison and
/// returns which binding it narrows and in which branch.
///
/// Returns null unless exactly ONE side is the `undefined` literal and the
/// OTHER side is a plain identifier (a field access does not narrow, see the
/// gating test). The operator must be `==` or `!=`.
fn narrowedBinding(cond: ast.BinaryExpr) ?Narrowing {
    const when_true = switch (cond.op) {
        .ne => true,
        .eq => false,
        else => return null,
    };
    const l_undef = cond.left.kind == .literal and cond.left.kind.literal == .undefined;
    const r_undef = cond.right.kind == .literal and cond.right.kind.literal == .undefined;

    if (l_undef == r_undef) return null;
    const other = if (l_undef) cond.right else cond.left;
    if (other.kind != .ident) return null;
    return .{ .name = other.kind.ident, .when_true = when_true };
}

/// Whether a statement definitely transfers control out of the enclosing block
/// (returns/breaks/continues), looking through a block to its last statement.
///
/// Used to prove that an `if (x == undefined) return;` guard leaves `x` present
/// for everything that follows, see [`earlyExitNarrowing`].
fn branchTerminates(s: *const ast.Statement) bool {
    return switch (s.*) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        .block => |b| b.statements.len > 0 and branchTerminates(&b.statements[b.statements.len - 1]),
        else => false,
    };
}

/// Recognises an early-exit narrowing statement: an `if` whose undefined-check
/// guard bails out, so the CHECKED binding is narrowed for the rest of the
/// statement sequence rather than just inside a branch.
///
/// Two shapes qualify. `if (x != undefined) { ... } else <terminates>`: the
/// else exits, so past the `if` the true (present) case holds. `if (x ==
/// undefined) <then terminates>` with NO else: the then exits, so past the `if`
/// the value is present. Returns null for any other shape (e.g. an `==` guard
/// that also has an else). The caller ([`Inferer.inferStmtSeq`]) then narrows
/// the remaining statements.
fn earlyExitNarrowing(s: *const ast.Statement) ?Narrowing {
    if (s.* != .if_stmt) return null;
    const i = s.if_stmt;
    if (i.condition.kind != .binary) return null;
    const n = narrowedBinding(i.condition.kind.binary) orelse return null;
    if (n.when_true) {

        const e = i.else_branch orelse return null;
        if (!branchTerminates(e)) return null;
    } else {

        if (i.else_branch != null) return null;
        if (!branchTerminates(i.then_branch)) return null;
    }
    return n;
}

/// Which category of declaration a visibility violation was against, so the
/// diagnostic can name it correctly (a private function vs type vs const).
pub const VisKind = enum { function, type_, const_ };

/// A deferred "accessed a non-public symbol from another module" diagnostic.
/// Collected during the walk and reported later by the driver.
pub const VisError = struct {
    /// Source location of the offending access.
    span: ast.Span,
    /// The receiver/module name through which the access was made (empty for a
    /// bare type or const reference).
    recv: []const u8,
    /// The name of the private member that was accessed.
    field: []const u8,

    /// Which kind of declaration was private, defaulting to a function.
    kind: VisKind = .function,
};

/// A deferred "assigned to a `const` binding" diagnostic.
pub const ConstReassignError = struct {
    /// Source location of the assignment.
    span: ast.Span,
    /// The const binding's name.
    name: []const u8,
};

/// Whether a see-through-without-unwrapping happened on an optional (`opt`) or
/// an error union (`err`), so the message can say `undefined`/`error`
/// appropriately.
pub const OptDerefKind = enum { opt, err };
/// A deferred "dereferenced an optional/error-union without unwrapping it"
/// diagnostic: accessing `.field` or calling `.method()` on a value that might
/// be absent or an error.
pub const OptDerefError = struct {
    /// Source location of the field access or method call.
    span: ast.Span,
    /// The field or method name that was reached through the wrapper.
    field: []const u8,
    /// True for a method call, false for a field access.
    is_method: bool,
    /// Whether the wrapper was an optional or an error union.
    kind: OptDerefKind = .opt,
};

/// A deferred "the catch handler's type does not match the try's ok type"
/// diagnostic, e.g. `x catch "s"` where `x`'s success value is not a string.
pub const CatchMismatchError = struct {
    /// Source location of the handler (or the guarded expression).
    span: ast.Span,
    /// The success-branch type of the `try`/error-union expression.
    ok: TypeId,
    /// The type produced by the catch handler.
    handler: TypeId,
};

/// A deferred "the callee's error type is incompatible with the enclosing
/// function's declared error type" diagnostic, raised at a `try` that would
/// propagate an error the function cannot return.
pub const TryErrorMismatch = struct {
    /// Source location of the `try`.
    span: ast.Span,
    /// The error type the called expression can produce.
    callee_err: TypeId,
    /// The error type the current function is declared to return.
    fn_err: TypeId,
};

/// A deferred "condition is not a boolean" diagnostic for an `if`/`while`/`for`
/// guard whose type is known and is not `bool`.
pub const CondTypeError = struct {
    /// Source location of the condition expression.
    span: ast.Span,
    /// The (non-bool, non-unresolved) type the condition actually had.
    got: TypeId,
    /// A short label for which construct's condition this was (`"if"`,
    /// `"while"`, `"for"`).
    ctx: []const u8,
};

/// A deferred "returning an optional where the function declares a plain type"
/// diagnostic, i.e. a value-optional leaking out of a function that promised a
/// non-optional result.
pub const RetOptionalError = struct {
    /// Source location of the returned expression.
    span: ast.Span,
    /// The function's declared (plain) return type.
    ret: TypeId,
    /// The optional type of the value being returned.
    val: TypeId,
};

/// A deferred "a value-optional was used where a plain type is required"
/// diagnostic at a non-return position (a let binding or an argument). Raised
/// by [`Inferer.checkPlainTarget`].
pub const ValoptPosError = struct {
    /// Source location of the offending expression.
    span: ast.Span,
    /// The plain type the position requires.
    want: TypeId,
    /// The optional type actually supplied.
    got: TypeId,
    /// A short label describing the position (e.g. "assigned to a variable of
    /// type", "passed as an argument ...").
    ctx: []const u8,
};

/// A deferred "method called with the wrong number of arguments" diagnostic.
/// `expected` already accounts for an implicit `self`, see
/// [`Inferer.checkMethodArity`].
pub const MethodArityError = struct {
    /// Source location of the call.
    span: ast.Span,
    /// The method name.
    name: []const u8,
    /// Number of arguments the method expects (excluding an implicit `self`
    /// when called on an instance).
    expected: usize,
    /// Number of arguments actually supplied.
    got: usize,
};

/// The inference engine itself: holds the scope stack, the deferred-diagnostic
/// lists, the fatal-miss counters, and the transient state threaded through the
/// recursive walk.
///
/// Construct with [`Inferer.init`], point `ir` at a [`TypedIr`] to capture
/// results, then drive it with [`Inferer.inferFunction`] /
/// [`Inferer.inferFunctionWithSelf`] per function. Call [`Inferer.deinit`] to
/// release the scope stack and the error lists. Many fields are context that is
/// saved and restored around a nested walk (module, expected return type,
/// callee flag), so the walk can be re-entrant without leaking state.
pub const Inferer = struct {
    /// Allocator for scopes, error lists, and the temporary slices the walk
    /// builds; also the allocator the [`TypedIr`] maps use.
    allocator: std.mem.Allocator,
    /// The interned type store: the source of canonical `TypeId`s and the
    /// classifier (`store.get(t)`) the whole pass branches on.
    store: *types.TypeStore,
    /// Read-only symbol table for resolving names to functions, types, methods,
    /// constants, and modules.
    symtab: *const symbols.SymbolTable,
    /// Lowers syntactic type refs to `TypeId`s. Its `param_scopes` and
    /// `current_module` are temporarily overridden while typing a generic body.
    lowerer: *lower.Lowerer,

    /// Stack of lexical scopes, each a list of [`Binding`]s. Pushed/popped by
    /// [`Inferer.push`]/[`Inferer.pop`]; lookups scan innermost-first.
    scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    /// Recursion guard for constant-value inference in [`Inferer.constType`],
    /// which can chain const-to-const; capped to break cycles.
    const_depth: usize = 0,
    /// Current expression-recursion depth, incremented per
    /// [`Inferer.inferExprInner`] frame.
    infer_depth: u32 = 0,
    /// Latched once `infer_depth` exceeds the 2000 limit; every subsequent
    /// expression fails fast with `error.TypeInferenceRecursionLimit` so a
    /// cyclic AST cannot overflow the stack.
    infer_overflow: bool = false,

    /// The declared return type of the function currently being walked, used to
    /// shape `return`/`try` expressions and to detect optional-in-plain-return.
    current_ret: ?TypeId = null,

    /// The module the current function belongs to, driving visibility checks and
    /// module-scoped name resolution.
    current_module: ?symbols.ModuleId = null,

    /// Collected cross-module visibility violations. See [`VisError`].
    visibility_errors: std.ArrayListUnmanaged(VisError) = .empty,

    /// Collected assignments to `const` bindings. See [`ConstReassignError`].
    const_reassign_errors: std.ArrayListUnmanaged(ConstReassignError) = .empty,

    /// Collected optional/error-union see-through diagnostics. See
    /// [`OptDerefError`].
    optional_deref_errors: std.ArrayListUnmanaged(OptDerefError) = .empty,

    /// Collected catch-arm type mismatches. See [`CatchMismatchError`].
    catch_mismatch_errors: std.ArrayListUnmanaged(CatchMismatchError) = .empty,

    /// Collected `try` error-type propagation mismatches. See
    /// [`TryErrorMismatch`].
    try_error_mismatch_errors: std.ArrayListUnmanaged(TryErrorMismatch) = .empty,

    /// Collected non-boolean condition diagnostics. See [`CondTypeError`].
    cond_type_errors: std.ArrayListUnmanaged(CondTypeError) = .empty,

    /// Collected optional-returned-from-plain-function diagnostics. See
    /// [`RetOptionalError`].
    ret_optional_errors: std.ArrayListUnmanaged(RetOptionalError) = .empty,
    /// Collected value-optional-in-plain-position diagnostics. See
    /// [`ValoptPosError`].
    valopt_pos_errors: std.ArrayListUnmanaged(ValoptPosError) = .empty,

    /// Collected method arity mismatches. See [`MethodArityError`].
    method_arity_errors: std.ArrayListUnmanaged(MethodArityError) = .empty,

    /// Count of bare identifiers that failed to resolve AND were judged fatal by
    /// [`Inferer.isFatalUnresolvedIdent`] (not a module/builtin/self). The
    /// driver treats a non-zero count as a compile failure.
    fatal_unresolved_idents: usize = 0,

    /// Name of the first fatal unresolved identifier, for the error message.
    first_fatal_ident: ?[]const u8 = null,
    /// Source span of the first fatal unresolved identifier (only set once a
    /// real, line > 0 span is available).
    first_fatal_span: ?ast.Span = null,
    /// Count of calls into a KNOWN module that named no such function, a
    /// separate fatal class from unresolved idents.
    fatal_unresolved_calls: usize = 0,
    /// Receiver (module) name of the first fatal unresolved call.
    first_fatal_call_recv: ?[]const u8 = null,
    /// Field (function) name of the first fatal unresolved call.
    first_fatal_call_field: ?[]const u8 = null,
    /// Source span of the first fatal unresolved call.
    first_fatal_call_span: ?ast.Span = null,

    /// The last concrete type produced by a `return` in the current body, used
    /// to infer a closure/function result when no return type was declared.
    captured_return: ?TypeId = null,

    /// True while typing the callee sub-expression of a call. Lets a
    /// field-access decide it is being CALLED (so an unresolved method should be
    /// treated more strictly) rather than read as a value.
    in_call_callee: bool = false,

    /// The statement slice currently being walked, so closure-argument inference
    /// can look ahead to a later call in the same sequence. See
    /// [`Inferer.closureCallExpectation`].
    current_stmt_seq: ?[]ast.Statement = null,

    /// Where to record results; null runs the walk purely for its side effects
    /// (used by [`Inferer.inferExprQuietly`] to probe a type without polluting
    /// the IR or the counters).
    ir: ?*TypedIr = null,
    /// The running coverage/diagnostic counters. See [`Stats`].
    stats: Stats = .{},

    /// Creates an inferer bound to the given store, symbol table, and lowerer.
    /// All the mutable walk state starts empty; point `ir` at a [`TypedIr`]
    /// afterwards to capture results.
    pub fn init(
        allocator: std.mem.Allocator,
        store: *types.TypeStore,
        symtab: *const symbols.SymbolTable,
        lowerer: *lower.Lowerer,
    ) Inferer {
        return .{ .allocator = allocator, .store = store, .symtab = symtab, .lowerer = lowerer };
    }

    /// Releases the scope stack, the stats histograms, and the deferred-error
    /// lists.
    ///
    /// Note it does NOT free `cond_type_errors`, `ret_optional_errors`,
    /// `valopt_pos_errors`, or `method_arity_errors`: those lists must be
    /// drained/owned by the driver before teardown, or their backing memory is
    /// reclaimed with the arena the inferer runs under.
    pub fn deinit(self: *Inferer) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.stats.deinit(self.allocator);
        self.visibility_errors.deinit(self.allocator);
        self.const_reassign_errors.deinit(self.allocator);
        self.optional_deref_errors.deinit(self.allocator);
        self.catch_mismatch_errors.deinit(self.allocator);
        self.try_error_mismatch_errors.deinit(self.allocator);
    }

    /// Pushes a fresh empty lexical scope onto the stack.
    fn push(self: *Inferer) !void {
        try self.scopes.append(self.allocator, .empty);
    }
    /// Pops and frees the innermost scope. Asserts a scope exists (`.?`), so it
    /// must be balanced with a prior [`Inferer.push`].
    fn pop(self: *Inferer) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }
    /// Binds `name` to `ty` in the innermost scope as a non-const (reassignable)
    /// variable. Thin wrapper over [`Inferer.bindC`].
    fn bind(self: *Inferer, name: []const u8, ty: TypeId) !void {
        try self.bindC(name, ty, false);
    }

    /// Binds `name` to `ty`, recording whether it is `const`. Creates an initial
    /// scope if the stack is empty, so binding before any explicit push is
    /// safe.
    fn bindC(self: *Inferer, name: []const u8, ty: TypeId, is_const: bool) !void {
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(self.allocator, .{ .name = name, .ty = ty, .is_const = is_const });
    }

    /// Whether the nearest binding of `name` was declared `const`, used to flag
    /// a reassignment. Returns false if the name is unbound.
    fn lookupIsConst(self: *Inferer, name: []const u8) bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b.is_const;
            }
        }
        return false;
    }

    /// Updates the type of the nearest existing binding of `name` in place.
    ///
    /// This is how a value is re-typed after a same-name reassignment where the
    /// RHS is an optional, and it underpins narrowing when done inside a scoped
    /// shadow. A no-op if the name is not bound.
    fn rebind(self: *Inferer, name: []const u8, ty: TypeId) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |*b| {
                if (std.mem.eql(u8, b.name, name)) {
                    b.ty = ty;
                    return;
                }
            }
        }
    }

    /// Resolves `name` to its type by scanning scopes innermost-first, or null
    /// if unbound. The primary local-variable lookup.
    fn lookup(self: *Inferer, name: []const u8) ?TypeId {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b.ty;
            }
        }
        return null;
    }

    /// Returns the store's `unresolved` type and records the miss under `tag`
    /// in [`Stats.by_tag`]. The single funnel for "I could not type this",
    /// which is what keeps the coverage stats honest.
    fn unresolved(self: *Inferer, tag: []const u8) !TypeId {
        self.stats.unresolved += 1;
        const gop = try self.stats.by_tag.getOrPut(self.allocator, tag);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        return self.store.unresolvedT();
    }

    /// Bumps the per-name miss histogram [`Stats.by_name`] for `name`, so a
    /// single unresolved symbol appearing in many places is visible as one hot
    /// name.
    fn note(self: *Inferer, name: []const u8) !void {
        const gop = try self.stats.by_name.getOrPut(self.allocator, name);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    /// Least-upper-bound of two struct types via a COMMON trait, or null if
    /// there is not exactly one.
    ///
    /// Used to type an `if`/ternary whose two branches are different structs:
    /// if both structs implement the same single trait, the expression's type
    /// is that trait object. If they share zero or more than one trait the
    /// result is ambiguous and this returns null (the caller then reports
    /// unresolved). Only structs are considered.
    fn lubTraitOfStructs(self: *Inferer, tt: TypeId, et: TypeId) !?TypeId {
        if (self.store.get(tt) != .struct_ or self.store.get(et) != .struct_) return null;
        const t_sym = self.symtab.symbolAt(self.store.get(tt).struct_.decl);
        const e_sym = self.symtab.symbolAt(self.store.get(et).struct_.decl);
        if (t_sym.decl != .struct_ or e_sym.decl != .struct_) return null;
        var found: ?TypeId = null;
        for (t_sym.decl.struct_.impls) |ti| {
            for (e_sym.decl.struct_.impls) |ei| {
                if (!std.mem.eql(u8, ti.name, ei.name)) continue;
                const sid = self.symtab.findTypeInModule(ti.name, self.current_module) orelse continue;
                if (self.symtab.symbolAt(sid).decl != .trait_) continue;
                const trait_tid = try self.store.intern(.{ .trait_ = sid });
                if (found) |f| {
                    if (f != trait_tid) return null;
                } else found = trait_tid;
            }
        }
        return found;
    }
    /// Records a successful typing (bumps [`Stats.typed`]) and returns the type
    /// unchanged. The complement of [`Inferer.unresolved`]; wrapping every
    /// concrete result in `ok(...)` is what makes the counter meaningful.
    fn ok(self: *Inferer, id: TypeId) TypeId {
        self.stats.typed += 1;
        return id;
    }

    /// Whether a `catch` handler's type is compatible with the guarded
    /// expression's success type.
    ///
    /// Deliberately lenient: identical types pass, and anything involving an
    /// `unresolved` type passes (we do not manufacture errors from ignorance).
    /// It only REJECTS a clear category mismatch, string-vs-non-string or
    /// decimal-vs-non-decimal, which are the cases that would silently corrupt
    /// codegen.
    fn catchArmsCompatible(self: *Inferer, ok_t: TypeId, handler_t: TypeId) bool {
        if (ok_t == handler_t) return true;
        const ko = self.store.get(ok_t);
        const kh = self.store.get(handler_t);
        if (ko == .unresolved or kh == .unresolved) return true;
        if ((ko == .string) != (kh == .string)) return false;
        if ((ko == .decimal) != (kh == .decimal)) return false;
        return true;
    }

    /// Whether two error types are compatible for `try` propagation.
    ///
    /// Like [`Inferer.catchArmsCompatible`], it is lenient around `unresolved`.
    /// Two enums match iff they are the same enum symbol; two structs iff they
    /// share a declaration; anything else is incompatible. Used to check that a
    /// `try` cannot propagate an error the enclosing function is not declared to
    /// return.
    fn errorTypesCompatible(self: *Inferer, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        const sa = self.store.get(a);
        const sb = self.store.get(b);
        if (sa == .unresolved or sb == .unresolved) return true;
        if (sa == .enum_ and sb == .enum_) return sa.enum_ == sb.enum_;
        if (sa == .struct_ and sb == .struct_) return sa.struct_.decl == sb.struct_.decl;
        return false;
    }

    /// Infers the type of `ep` with no expected-type context. The public entry
    /// point for a stand-alone expression.
    pub fn inferExpr(self: *Inferer, ep: *const ast.Expression) anyerror!TypeId {
        return self.inferExprExpecting(ep, null);
    }

    /// Infers `ep`'s type, threading an optional `expected` type inwards, and
    /// records both the type AND the owned/borrow disposition into the IR.
    ///
    /// The `expected` hint is what lets a literal, tuple, closure, or `if`
    /// expression be shaped by its context. This is the recording wrapper; the
    /// actual case analysis is in [`Inferer.inferExprInner`].
    pub fn inferExprExpecting(self: *Inferer, ep: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const t = try self.inferExprInner(ep.*, expected);
        if (self.ir) |ir| {
            try ir.record(self.allocator, ep, t);

            try ir.recordOwned(self.allocator, ep, self.ownedDisposition(ep.kind, t));
        }
        return t;
    }

    /// Decides whether an expression of syntactic `kind` and type `t` yields a
    /// fresh OWNED heap value (needing release) or a borrow.
    ///
    /// Certain kinds are borrows by construction regardless of type: reading an
    /// ident/field/index, an assignment, a non-decimal literal, and the
    /// unwrapping forms (`try`/cast/await/`go`/optional-chaining) all return
    /// false. For everything else, ownership is whatever
    /// `store.isOwnedSafe(t)` says. Feeds [`TypedIr.expr_owned`] and hence the
    /// ARC pass.
    fn ownedDisposition(self: *Inferer, kind: ast.ExprKind, t: TypeId) bool {
        switch (kind) {
            .ident, .field_access, .index => return false,
            .binary => |b| if (b.op == .assign) return false,

            .literal => |lit| if (lit != .decimal) return false,
            .try_expr, .cast, .await_expr, .go_expr, .optional_chaining => return false,
            else => {},
        }

        return self.store.isOwnedSafe(t);
    }

    /// The heart of the pass: a big switch over expression kind that computes a
    /// type (or `unresolved`) for `e`, threading `expected` where it helps.
    ///
    /// It is guarded by the recursion limit (2000 frames, latched into
    /// [`Inferer.infer_overflow`]) so a cyclic AST fails fast instead of blowing
    /// the stack. Each arm follows the honesty rule: prefer `unresolved` over a
    /// guess, and record the specific cause tag. Notable arms: `call` handles
    /// enum-variant construction, extern builtins, free functions (with generic
    /// return substitution), struct construction, module functions, and methods
    /// in that order; `struct_init`/`generic_call` solve and register concrete
    /// generic instantiations with [`mono`]; `closure` infers parameter types
    /// from the expected function type or, failing that, from how the param is
    /// used in the body. This routine does NOT record into the IR itself, its
    /// caller [`Inferer.inferExprExpecting`] does.
    fn inferExprInner(self: *Inferer, e: ast.Expression, expected: ?TypeId) anyerror!TypeId {
        if (self.infer_overflow) return error.TypeInferenceRecursionLimit;
        self.infer_depth += 1;
        defer self.infer_depth -= 1;
        if (self.infer_depth > 2000) {
            self.infer_overflow = true;
            return error.TypeInferenceRecursionLimit;
        }
        switch (e.kind) {

            .range => |r| {
                _ = try self.inferExpr(r.start);
                _ = try self.inferExpr(r.end);
                return self.ok(try self.store.intT());
            },
            .literal => |lit| return switch (lit) {

                .integer => {
                    if (expected) |exp| {
                        const et = self.store.get(exp);
                        if (et == .prim and et.prim.kind == .int and et.prim.bits >= 32) return self.ok(exp);
                    }
                    return self.ok(try self.store.intT());
                },
                .float => self.ok(try self.store.doubleT()),
                .string => self.ok(try self.store.stringT()),
                .bool => self.ok(try self.store.boolT()),

                .decimal => self.ok(try self.store.decimalT()),

                .array => |items| {
                    if (items.len == 0) return self.unresolved("literal");
                    const elem = try self.inferExpr(&items[0]);
                    for (items[1..]) |*it| _ = try self.inferExpr(it);
                    if (self.store.get(elem) == .unresolved) return self.unresolved("literal");
                    return self.ok(try self.store.intern(.{ .array = .{ .elem = elem, .len = items.len } }));
                },
                .array_repeat => |ar| {
                    const elem = try self.inferExpr(ar.value);
                    if (self.store.get(elem) == .unresolved) return self.unresolved("literal");
                    return self.ok(try self.store.intern(.{ .array = .{ .elem = elem, .len = ar.count } }));
                },
                else => self.unresolved("literal"),
            },
            .ident => |name| {
                if (self.lookup(name)) |t| return self.ok(t);

                if (try self.constType(name)) |t| return self.ok(t);

                if (self.symtab.findFunction(name)) |sid| {
                    if (self.symtab.symbolAt(sid).decl == .function) {
                        return self.ok(try self.fnType(self.symtab.symbolAt(sid).decl.function));
                    }
                }

                if (builtins.findExtern(name)) |b| {
                    return self.ok(try builtins.retType(self.store, b.ret));
                }
                if (self.symtab.findTypeInModule(name, self.current_module)) |sid| {
                    const tsym = self.symtab.symbolAt(sid);
                    switch (tsym.decl) {
                        .struct_ => return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } })),
                        .enum_ => return self.ok(try self.store.intern(.{ .enum_ = sid })),
                        else => {},
                    }
                }

                if (self.isFatalUnresolvedIdent(name)) {
                    self.fatal_unresolved_idents += 1;
                    if (self.first_fatal_ident == null) self.first_fatal_ident = name;
                    if (self.first_fatal_span == null and e.span.line > 0) {
                        self.first_fatal_span = e.span;
                        self.first_fatal_ident = name;
                    }
                } else {

                    self.stats.unresolved_ns_ident += 1;
                }
                try self.note(name);
                return self.unresolved("ident");
            },
            .binary => |b| {
                switch (b.op) {

                    .eq, .ne, .lt, .gt, .le, .ge, .And, .Or => {
                        _ = try self.inferExpr(b.left);
                        _ = try self.inferExpr(b.right);
                        return self.ok(try self.store.boolT());
                    },

                    .assign => {
                        const lt = try self.inferExpr(b.left);
                        if (b.left.kind == .ident and self.lookupIsConst(b.left.kind.ident)) {
                            self.const_reassign_errors.append(self.allocator, .{ .span = b.span, .name = b.left.kind.ident }) catch {};
                        }
                        const at = try self.inferExpr(b.right);
                        if (b.left.kind == .ident and self.store.get(at) == .optional and self.store.get(lt) != .optional) {
                            self.rebind(b.left.kind.ident, at);
                        }
                        if (self.store.get(lt) == .unresolved) {
                            return if (self.store.get(at) == .unresolved)
                                self.unresolved("assign")
                            else
                                self.ok(at);
                        }
                        return self.ok(lt);
                    },
                    else => {},
                }

                const int_expected: ?TypeId = blk: {
                    const exp = expected orelse break :blk null;
                    const et = self.store.get(exp);
                    break :blk if (et == .prim and et.prim.kind == .int) exp else null;
                };
                const is_shift = (b.op == .shl or b.op == .shr);
                const lt = try self.inferExprExpecting(b.left, int_expected);
                const rt = if (is_shift) try self.inferExpr(b.right) else try self.inferExprExpecting(b.right, int_expected);

                if (b.op == .add and (self.store.get(lt) == .string or self.store.get(rt) == .string)) {
                    return self.ok(try self.store.stringT());
                }
                if (self.store.get(lt) == .unresolved) {

                    return if (self.store.get(rt) == .unresolved) self.unresolved("binary") else self.ok(rt);
                }
                if (!is_shift) {
                    const lk = self.store.get(lt);
                    const rk = self.store.get(rt);
                    if (lk == .prim and lk.prim.kind == .int and rk == .prim and rk.prim.kind == .int and rk.prim.bits > lk.prim.bits) {
                        return self.ok(rt);
                    }
                }
                return self.ok(lt);
            },
            .unary => |u| {
                const t = try self.inferExpr(u.operand);
                return if (self.store.get(t) == .unresolved) self.unresolved("unary") else self.ok(t);
            },
            .cast => |c| {
                _ = try self.inferExpr(c.expr);
                const t = try self.lowerer.lower(c.target_type);
                return if (self.store.get(t) == .unresolved) self.unresolved("cast") else self.ok(t);
            },
            .call => |c| {

                self.in_call_callee = true;
                const callee_t = try self.inferExpr(c.callee);
                self.in_call_callee = false;
                self.stats.typed -|= 1;

                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;
                    if (fa.object.kind == .ident) {
                        if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                            const decl = self.symtab.symbolAt(sid).decl;

                            if (decl == .enum_) {
                                var is_variant = false;
                                for (decl.enum_.variants) |v| {
                                    if (std.mem.eql(u8, v.name, fa.field)) {
                                        is_variant = true;
                                        break;
                                    }
                                }
                                if (is_variant) {
                                    for (c.args) |*a| _ = try self.inferExpr(a);
                                    return self.ok(try self.store.intern(.{ .enum_ = sid }));
                                }
                            }
                        }
                    }
                }

                const want = try self.calleeParamTypes(c.callee);
                defer if (want) |w| self.allocator.free(w);

                var arg_types = std.ArrayListUnmanaged(TypeId).empty;
                defer arg_types.deinit(self.allocator);
                for (c.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (want) |w| (if (i < w.len) w[i] else null) else null;
                    const at = try self.inferExprExpecting(a, exp);
                    if (exp) |pe| self.checkPlainTarget(a.span, pe, at, "passed as an argument to a parameter of type");
                    try arg_types.append(self.allocator, at);
                }
                if (c.callee.kind == .ident) {

                    if (builtins.findExtern(c.callee.kind.ident)) |b| {
                        return self.ok(try builtins.retType(self.store, b.ret));
                    }

                    const bare_fn_sid: ?symbols.SymbolId = blk: {
                        if (self.current_module) |cm| {
                            if (self.symtab.findFunctionIn(cm, c.callee.kind.ident)) |s| break :blk s;
                        }
                        break :blk self.symtab.findFunction(c.callee.kind.ident);
                    };
                    if (bare_fn_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .function) {

                            if (!self.symtab.findFunctionAmbiguous(c.callee.kind.ident)) {
                                if (self.ir) |ir| try ir.recordSym(self.allocator, &e, sid);
                            }
                            const fd = sym.decl.function;
                            self.warnIfDeprecated(fd, c.span);
                            if (fd.ret_type) |r| {

                                if (fd.type_params.len > 0) {
                                    if (try self.freeFnReturn(sid, fd, r, arg_types.items, &e)) |t| {
                                        if (self.store.get(t) != .unresolved) return self.ok(t);
                                    }
                                }
                                const t = try self.lowerer.lower(r);
                                if (self.store.get(t) != .unresolved) return self.ok(t);
                            } else return self.ok(try self.store.voidT());
                        }
                    }

                    if (self.symtab.findTypeInModule(c.callee.kind.ident, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }
                }
                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;

                    if (try self.builtinCallReturn(fa)) |t| return self.ok(t);
                    var modsym: ?types.SymbolId = null;
                    if (try self.moduleCallReturn(fa, &modsym)) |t| {
                        if (modsym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(t);
                    }
                    var msym: ?types.SymbolId = null;
                    if (try self.methodReturn(fa, c.args, &msym, &e)) |t| {
                        if (msym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(t);
                    }

                    if (self.symtab.findTypeInModule(fa.field, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }

                    if (try self.staticMethodReturn(fa)) |t| return self.ok(t);
                    if (fa.object.kind == .ident) {
                        const recv = fa.object.kind.ident;
                        if (self.lookup(recv) == null and self.isKnownModule(recv) and
                            self.resolveModuleFn(recv, fa.field, fa.span) == null)
                        {
                            self.fatal_unresolved_calls += 1;
                            if (self.first_fatal_call_recv == null) {
                                self.first_fatal_call_recv = recv;
                                self.first_fatal_call_field = fa.field;
                                self.first_fatal_call_span = fa.span;
                            }
                        }
                    }
                    if (fa.object.kind == .ident) try self.note(fa.object.kind.ident);
                }

                if (self.store.get(callee_t) == .func) {
                    return self.ok(self.store.get(callee_t).func.ret);
                }
                if (c.callee.kind == .ident) try self.note(c.callee.kind.ident);
                return self.unresolved("call");
            },
            .field_access => |fa| {

                const is_callee = self.in_call_callee;
                self.in_call_callee = false;

                _ = try self.inferExpr(fa.object);
                self.stats.typed -|= 1;

                if (try self.moduleFnValue(fa)) |t| return self.ok(t);
                if (try self.fieldType(fa)) |t| return self.ok(t);

                if (try self.stringProperty(fa)) |t| return self.ok(t);

                if (fa.object.kind == .ident) {
                    if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                        if (self.symtab.symbolAt(sid).decl == .enum_) {
                            return self.ok(try self.store.intern(.{ .enum_ = sid }));
                        }
                    }
                }

                if (fa.object.kind == .field_access) {
                    const inner = fa.object.kind.field_access;
                    if (inner.object.kind == .ident and self.lookup(inner.object.kind.ident) == null) {
                        if (self.symtab.findTypeInModule(inner.field, self.current_module)) |sid| {
                            if (self.symtab.symbolAt(sid).decl == .enum_) {
                                return self.ok(try self.store.intern(.{ .enum_ = sid }));
                            }
                        }
                    }
                }

                if (fa.object.kind == .ident and self.lookup(fa.object.kind.ident) == null) {
                    if (try self.constType(fa.field)) |t| return self.ok(t);
                }

                if (fa.object.kind == .ident) {
                    const obj = fa.object.kind.ident;
                    if (self.lookup(obj) == null and !self.isFatalUnresolvedIdent(obj)) {
                        self.stats.unresolved_ns_field += 1;
                        return self.unresolved("field_access");
                    }
                }

                if (is_callee) {
                    self.stats.unresolved_ns_field += 1;
                    return self.unresolved("field_access");
                }

                try self.note(fa.field);
                return self.unresolved("field_access");
            },
            .optional_chaining => |o| {

                const obj_t = try self.inferExpr(o.object);
                self.stats.typed -|= 1;
                var struct_tid = obj_t;
                if (self.store.get(obj_t) == .optional) struct_tid = self.store.get(obj_t).optional;
                const st = self.store.get(struct_tid);
                if (st == .struct_) {
                    const sym = self.symtab.symbolAt(st.struct_.decl);
                    if (sym.decl == .struct_) {
                        for (sym.decl.struct_.fields) |f| {
                            if (std.mem.eql(u8, f.name, o.field)) {
                                const ft = try self.lowerInStructScope(st.struct_, f.type_name);

                                if (self.store.get(ft) == .optional) return self.ok(ft);
                                return self.ok(try self.store.intern(.{ .optional = ft }));
                            }
                        }
                    }
                }
                return self.unresolved("optional_chaining");
            },
            .nullish_coalesce => |n| {
                const lt = try self.inferExpr(n.left);
                const rt = try self.inferExpr(n.right);
                if (self.store.get(lt) == .unresolved)
                    return if (self.store.get(rt) == .unresolved) self.unresolved("nullish") else self.ok(rt);

                const l = self.store.get(lt);
                if (l == .optional) return self.ok(l.optional);
                return self.ok(lt);
            },

            .template_expr => |t| {
                for (t.parts) |*p| _ = try self.inferExpr(p);
                return self.ok(try self.store.stringT());
            },
            .if_expr => |ie| {
                _ = try self.inferExpr(ie.condition);
                const tt = try self.inferExprExpecting(ie.then_branch, expected);
                const et = try self.inferExprExpecting(ie.else_branch, expected);

                if (expected) |exp_t| {
                    if (self.store.get(exp_t) == .trait_ and
                        self.store.get(tt) == .struct_ and self.store.get(et) == .struct_)
                        return self.ok(exp_t);
                }
                if (tt == et) return self.ok(tt);

                if (try self.lubTraitOfStructs(tt, et)) |lub| return self.ok(lub);
                return self.unresolved("if_expr");
            },
            .struct_init => |si| {

                const decl_sid = self.symtab.findTypeInModule(si.type_name, self.current_module);

                var type_params: []const []const u8 = &.{};
                if (decl_sid) |sid| {
                    const sym = self.symtab.symbolAt(sid);
                    if (sym.decl == .struct_) type_params = sym.decl.struct_.type_params;
                }
                const solved = try self.allocator.alloc(?TypeId, type_params.len);
                defer self.allocator.free(solved);
                @memset(solved, null);

                for (si.fields) |*f| {
                    var expected_field: ?TypeId = null;
                    var declared_in_scope: ?TypeId = null;
                    if (decl_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .struct_) {
                            for (sym.decl.struct_.fields) |sf| {
                                if (std.mem.eql(u8, sf.name, f.name)) {
                                    expected_field = self.lowerer.lower(sf.type_name) catch null;
                                    if (type_params.len > 0) {
                                        const saved = self.lowerer.param_scopes;
                                        const scopes = [_]lower.ParamScope{.{ .owner = sid, .names = type_params }};
                                        self.lowerer.param_scopes = &scopes;
                                        declared_in_scope = self.lowerer.lower(sf.type_name) catch null;
                                        self.lowerer.param_scopes = saved;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    const actual = try self.inferExprExpecting(&f.value, expected_field);
                    if (declared_in_scope) |dts| {
                        if (decl_sid) |sid| subst.solveParams(self.store, dts, actual, sid, solved);
                    }
                }
                self.recordTypeVis(si.type_name, si.span);
                if (decl_sid) |sid| {
                    if (type_params.len > 0) {
                        const args = try self.allocator.alloc(TypeId, type_params.len);
                        defer self.allocator.free(args);
                        for (solved, 0..) |m, i| args[i] = m orelse try self.store.unresolvedT();
                        const inst_tid = try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } });
                        mono.noteForcedStructInst(self.allocator, inst_tid);
                        return self.ok(inst_tid);
                    }
                    return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                }
                return self.unresolved("struct_init");
            },
            .index => |ix| {
                const obj = try self.inferExpr(ix.object);
                _ = try self.inferExpr(ix.index);
                switch (self.store.get(obj)) {

                    .string => return self.ok(try self.store.intT()),
                    .array => |a| return self.ok(a.elem),
                    .tuple => |elems| {
                        if (ix.index.kind == .literal and ix.index.kind.literal == .integer) {
                            const n = ix.index.kind.literal.integer;
                            if (n >= 0 and @as(usize, @intCast(n)) < elems.len) {
                                const et = elems[@intCast(n)];
                                if (self.store.get(et) != .prim) return self.ok(et);
                            }
                        }
                        return self.unresolved("tuple-index");
                    },
                    else => return self.unresolved("index"),
                }
            },

            .go_expr => |g| {
                const inner = try self.inferExpr(g.operand);
                if (self.store.get(inner) == .unresolved) return self.unresolved("go");
                return self.ok(try self.store.intern(.{ .future = inner }));
            },
            .await_expr => |a| {
                const inner = try self.inferExpr(a.operand);

                return switch (self.store.get(inner)) {
                    .future => |t| self.ok(t),
                    .unresolved => try self.unresolved("await"),
                    else => self.ok(inner),
                };
            },
            .tuple => |items| {
                const elems = try self.allocator.alloc(TypeId, items.len);
                defer self.allocator.free(elems);

                const exp_elems: ?[]const TypeId = if (expected) |exp_t| blk: {
                    const ei = self.store.get(exp_t);
                    break :blk if (ei == .tuple and ei.tuple.len == items.len) ei.tuple else null;
                } else null;
                for (items, 0..) |*it, i| {
                    const exp_i: ?TypeId = if (exp_elems) |xe| xe[i] else null;
                    const actual = try self.inferExprExpecting(it, exp_i);
                    elems[i] = if (exp_i) |xi|
                        (if (self.store.get(xi) == .trait_ and self.store.get(actual) == .struct_) xi else actual)
                    else
                        actual;
                }
                return self.ok(try self.store.intern(.{ .tuple = elems }));
            },
            .closure => |cl| {

                if (expected == null) {
                    if (self.ir) |ir| {
                        if (ir.typeOf(&e)) |cached| {
                            if (self.store.get(cached) == .func) {
                                const cft = self.store.get(cached).func;
                                var all_resolved = self.store.get(cft.ret) != .unresolved and cft.params.len == cl.params.len;
                                for (cft.params) |pt| {
                                    if (self.store.get(pt) == .unresolved) all_resolved = false;
                                }
                                if (all_resolved) return self.ok(cached);
                            }
                        }
                    }
                }

                const want: ?types.FuncType = if (expected) |x| switch (self.store.get(x)) {
                    .func => |ft| ft,
                    else => null,
                } else null;

                try self.push();
                defer self.pop();
                for (cl.params, 0..) |p, i| {

                    const pt = if (want) |ft|
                        (if (i < ft.params.len and ft.params.len == cl.params.len)
                            ft.params[i]
                        else
                            try self.store.unresolvedT())
                    else
                        try self.store.unresolvedT();
                    try self.bind(p, pt);
                }

                for (cl.params) |p| {
                    if (self.lookup(p)) |cur| {
                        if (self.store.get(cur) != .unresolved) continue;
                        if (try self.paramFromUse(p, cl.body)) |t| self.rebind(p, t);
                    }
                }
                const body_t: TypeId = switch (cl.body) {
                    .expr => |ex| try self.inferExpr(ex),
                    .block => |*b| blk: {

                        const saved_cap = self.captured_return;
                        self.captured_return = null;
                        try self.inferBlock(b);
                        const rt = self.captured_return orelse try self.store.voidT();
                        self.captured_return = saved_cap;
                        break :blk rt;
                    },
                };

                if (want) |ft| {
                    if (ft.params.len == cl.params.len) {

                        const ret = if (self.store.get(ft.ret) == .trait_ and self.store.get(body_t) != .unresolved)
                            ft.ret
                        else if (self.store.get(body_t) != .unresolved)
                            body_t
                        else
                            ft.ret;
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ft.params, .ret = ret } }));
                    }
                }

                {
                    const ps = try self.allocator.alloc(TypeId, cl.params.len);
                    defer self.allocator.free(ps);
                    for (cl.params, 0..) |p, i| {
                        ps[i] = self.lookup(p) orelse try self.store.unresolvedT();
                    }

                    if (self.store.get(body_t) != .unresolved) {
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ps, .ret = body_t } }));
                    }
                }
                return self.unresolved("closure");
            },

            .try_expr => |inner| {
                const it = try self.inferExpr(inner);
                const ity = self.store.get(it);
                if (ity == .error_union) {
                    if (self.current_ret) |rt| {
                        const rty = self.store.get(rt);
                        if (rty == .error_union and !self.errorTypesCompatible(ity.error_union.err, rty.error_union.err)) {
                            const sp = if (e.span.line > 0) e.span else inner.span;
                            self.try_error_mismatch_errors.append(self.allocator, .{
                                .span = sp,
                                .callee_err = ity.error_union.err,
                                .fn_err = rty.error_union.err,
                            }) catch {};
                        }
                    }
                    return self.ok(ity.error_union.ok);
                }

                return self.ok(it);
            },

            .catch_expr => |*ce| {
                const it = try self.inferExpr(ce.expr);
                const ity = self.store.get(it);
                if (ity == .error_union) {
                    if (ce.err_name) |n| try self.bind(n, ity.error_union.err);
                    const ok_ty = ity.error_union.ok;
                    const ht = try self.inferExprExpecting(ce.handler, ok_ty);
                    if (!self.catchArmsCompatible(ok_ty, ht)) {
                        const sp = if (ce.handler.span.line > 0) ce.handler.span else ce.expr.span;
                        self.catch_mismatch_errors.append(self.allocator, .{ .span = sp, .ok = ok_ty, .handler = ht }) catch {};
                    }
                    return self.ok(ok_ty);
                }
                _ = try self.inferExpr(ce.handler);
                return self.ok(it);
            },
            .block_expr => |*b| {
                try self.inferBlock(b);
                return self.unresolved("block_expr");
            },
            .generic_call => |g| {

                if (g.callee.kind == .field_access) {
                    const sfa = g.callee.kind.field_access;
                    if (sfa.object.kind == .ident and std.mem.eql(u8, sfa.object.kind.ident, "serde") and g.type_args.len == 1) {
                        if (std.mem.eql(u8, sfa.field, "bind") or std.mem.eql(u8, sfa.field, "bindRow")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            return self.ok(try self.lowerer.lower(g.type_args[0]));
                        }
                        if (std.mem.eql(u8, sfa.field, "bindAll") or std.mem.eql(u8, sfa.field, "bindWire")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            var params = [_]ast.TypeRef{g.type_args[0]};
                            const list_ref = ast.TypeRef{ .generic = .{ .name = "List", .params = &params } };
                            return self.ok(try self.lowerer.lower(list_ref));
                        }
                        if (std.mem.eql(u8, sfa.field, "planFor")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            var params = [_]ast.TypeRef{ast.TypeRef{ .ident = "int" }};
                            const list_ref = ast.TypeRef{ .generic = .{ .name = "List", .params = &params } };
                            return self.ok(try self.lowerer.lower(list_ref));
                        }
                        if (std.mem.eql(u8, sfa.field, "typeName")) {
                            return self.ok(try self.store.stringT());
                        }
                        if (std.mem.eql(u8, sfa.field, "dump")) {

                            for (g.args) |*a| _ = try self.inferExpr(a);
                            return self.ok(try self.store.voidT());
                        }
                    }
                    if (sfa.object.kind == .ident and std.mem.eql(u8, sfa.object.kind.ident, "mem") and g.type_args.len == 1) {
                        for (g.args) |*a| _ = try self.inferExpr(a);
                        if (std.mem.eql(u8, sfa.field, "load") or std.mem.eql(u8, sfa.field, "rotl") or
                            std.mem.eql(u8, sfa.field, "rotr") or std.mem.eql(u8, sfa.field, "bswap"))
                        {
                            return self.ok(try self.lowerer.lower(g.type_args[0]));
                        }
                        if (std.mem.eql(u8, sfa.field, "ctz") or std.mem.eql(u8, sfa.field, "clz")) {
                            return self.ok(try self.store.intT());
                        }
                        if (std.mem.eql(u8, sfa.field, "store")) {
                            return self.ok(try self.store.voidT());
                        }
                    }
                }
                _ = try self.inferExpr(g.callee);
                self.stats.typed -|= 1;

                var gwant: ?[]TypeId = null;
                if (g.callee.kind == .field_access) gwant = self.calleeParamTypes(g.callee) catch null;
                defer if (gwant) |w| self.allocator.free(w);
                for (g.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (gwant) |w| (if (i < w.len) w[i] else null) else null;
                    _ = try self.inferExprExpecting(a, exp);
                }

                if (g.callee.kind == .field_access) {
                    const bfa = g.callee.kind.field_access;
                    if (bfa.object.kind == .ident and std.mem.eql(u8, bfa.object.kind.ident, "bytes") and
                        g.type_args.len == 1 and
                        (std.mem.eql(u8, bfa.field, "new") or
                            std.mem.eql(u8, bfa.field, "new_persistent") or
                            std.mem.eql(u8, bfa.field, "new_with_allocator")))
                    {
                        return self.ok(try self.lowerer.lower(g.type_args[0]));
                    }
                }

                if (g.callee.kind == .field_access) {
                    var vmsym: ?types.SymbolId = null;
                    if (try self.explicitMethodReturn(g.callee.kind.field_access, g.type_args, g.args, &vmsym)) |mt| {
                        if (vmsym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(mt);
                    }
                }

                const tname: ?[]const u8 = switch (g.callee.kind) {
                    .ident => |n| n,
                    .field_access => |fa| fa.field,
                    else => null,
                };
                if (tname) |n| {

                    const args = try self.allocator.alloc(TypeId, g.type_args.len);
                    defer self.allocator.free(args);
                    for (g.type_args, 0..) |ta, i| args[i] = try self.lowerer.lower(ta);

                    if (std.mem.eql(u8, n, "Storage") and args.len == 1) {
                        return self.ok(try self.store.intern(.{ .storage = args[0] }));
                    }
                    if (self.symtab.findTypeInModule(n, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }));
                    }

                    if (self.symtab.findFunction(n)) |fid| {
                        const sym = self.symtab.symbolAt(fid);
                        if (sym.decl == .function) {
                            const fd = sym.decl.function;
                            const ret = fd.ret_type orelse return self.ok(try self.store.voidT());
                            const saved = self.lowerer.param_scopes;
                            defer self.lowerer.param_scopes = saved;
                            const scope = [_]lower.ParamScope{.{ .owner = fid, .names = fd.type_params }};
                            self.lowerer.param_scopes = &scope;
                            const raw = try self.lowerer.lower(ret);
                            const sub = try subst.substitute(self.store, raw, fid, args);
                            if (self.store.get(sub) != .unresolved) {

                                var all_concrete = fd.type_params.len > 0 and args.len == fd.type_params.len;
                                for (args) |a| {
                                    switch (self.store.get(a)) {
                                        .type_param, .unresolved => all_concrete = false,
                                        else => {},
                                    }
                                }
                                if (all_concrete) {
                                    _ = mono.noteFreeFnInst(self.allocator, self.store, n, fid, fd.type_params, args);
                                }
                                return self.ok(sub);
                            }
                        }
                    }
                }

                return self.unresolved("generic_call");
            },
            .enum_init => |ei| {
                for (ei.fields) |*f| _ = try self.inferExpr(&f.value);
                if (self.symtab.findTypeInModule(ei.enum_name, self.current_module)) |sid| return self.ok(try self.store.intern(.{ .enum_ = sid }));
                return self.unresolved("enum_init");
            },
            .jsx_element => |jsx| {
                try self.inferJsxElement(&jsx);
                // An NSX `<...>` literal is trusted, pre-escaped markup: type it
                // `Html` (nominally distinct from `string`) so `{expr}` inserts it
                // raw while a plain `string` is HTML-escaped (the XSS boundary).
                return self.ok(try self.store.htmlT());
            },
        }
    }

    /// Walks a JSX element for its side effects only: types every attribute's
    /// expression value and recurses into child elements, expressions, and
    /// embedded statements.
    ///
    /// The element itself is typed as `string` by the caller (JSX lowers to
    /// string output), so this returns nothing; it exists to make the embedded
    /// expressions typed and recorded.
    fn inferJsxElement(self: *Inferer, jsx: *const ast.JsxElement) anyerror!void {
        for (jsx.attributes) |*attr| {
            switch (attr.value) {
                .expression => |*ex| _ = try self.inferExpr(ex),
                .string_literal => {},
            }
        }
        for (jsx.children) |*child| {
            switch (child.*) {
                .element => |*el| try self.inferJsxElement(el),
                .expression => |*ex| _ = try self.inferExpr(ex),
                .statement => |*st| try self.inferStmt(st),
                .text => {},
            }
        }
    }

    /// Builds the `func` type of a free function declaration by lowering its
    /// parameter and return type refs. An untyped parameter lowers to
    /// `unresolved`; a missing return type is `void`. Used when a function is
    /// referenced as a first-class value.
    fn fnType(self: *Inferer, f: *const ast.FunctionDecl) !TypeId {
        const params = try self.allocator.alloc(TypeId, f.params.len);
        defer self.allocator.free(params);
        for (f.params, 0..) |p, i| {
            params[i] = if (p.type_name) |t| try self.lowerer.lower(t) else try self.store.unresolvedT();
        }
        const ret = if (f.ret_type) |r| try self.lowerer.lower(r) else try self.store.voidT();
        return self.store.intern(.{ .func = .{ .params = params, .ret = ret } });
    }

    /// Lowers a type ref that appears inside a struct, resolving the struct's
    /// type parameters to the receiver's concrete arguments.
    ///
    /// Temporarily installs the struct's params as the lowerer's param scope
    /// (restored via `defer`), lowers `tr` to a possibly param-bearing type,
    /// then substitutes the receiver's `st.args` for those params. This is how
    /// `List<string>`'s field/return `T` becomes `string`.
    fn lowerInStructScope(self: *Inferer, st: types.StructType, tr: ast.TypeRef) !TypeId {
        const sym = self.symtab.symbolAt(st.decl);
        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scope = [_]lower.ParamScope{.{
            .owner = st.decl,
            .names = if (sym.decl == .struct_) sym.decl.struct_.type_params else &.{},
        }};
        self.lowerer.param_scopes = &scope;
        const raw = try self.lowerer.lower(tr);
        return try subst.substitute(self.store, raw, st.decl, st.args);
    }

    /// Lowers a type ref inside a METHOD, with BOTH the struct's type params and
    /// the method's own type params in scope.
    ///
    /// Installs a two-level param scope (struct first, then method) so a ref can
    /// mention either. After lowering it substitutes only the STRUCT's args; the
    /// method's own params are solved and substituted later by the caller (see
    /// [`Inferer.methodReturn`]). Like [`Inferer.lowerInStructScope`] but for
    /// generic methods on generic structs.
    fn lowerInMethodScope(
        self: *Inferer,
        st: types.StructType,
        mid: types.SymbolId,
        fd: *const ast.FunctionDecl,
        tr: ast.TypeRef,
    ) !TypeId {
        const owner = self.symtab.symbolAt(st.decl);
        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scopes = [_]lower.ParamScope{
            .{ .owner = st.decl, .names = if (owner.decl == .struct_) owner.decl.struct_.type_params else &.{} },
            .{ .owner = mid, .names = fd.type_params },
        };
        self.lowerer.param_scopes = &scopes;
        const raw = try self.lowerer.lower(tr);

        return try subst.substitute(self.store, raw, st.decl, st.args);
    }

    /// Computes the concrete return type of a generic FREE function call by
    /// solving its type params from the actual argument types.
    ///
    /// For each declared parameter it matches the declared (param-bearing) type
    /// against the actual argument type to solve params, then substitutes every
    /// solved param out of the return type. When every param solved to a fully
    /// concrete type (and enough args were supplied), it registers the concrete
    /// instantiation with [`mono.noteFreeFnInst`] and records the solved args
    /// into the IR for `call_expr`, so the emitter specialises exactly this
    /// call. Returns the (partly or fully) substituted return type; it may
    /// still be `unresolved` if inference under-determined the params.
    fn freeFnReturn(
        self: *Inferer,
        fid: types.SymbolId,
        fd: *const ast.FunctionDecl,
        ret_tr: ast.TypeRef,
        arg_types: []const TypeId,
        call_expr: *const ast.Expression,
    ) !?TypeId {

        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scopes = [_]lower.ParamScope{.{ .owner = fid, .names = fd.type_params }};
        self.lowerer.param_scopes = &scopes;

        const sub = try self.lowerer.lower(ret_tr);

        const solved = try self.allocator.alloc(?TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        @memset(solved, null);

        for (fd.params, 0..) |p, i| {
            if (i >= arg_types.len) break;
            const tr = p.type_name orelse continue;
            const dp = try self.lowerer.lower(tr);
            subst.solveParams(self.store, dp, arg_types[i], fid, solved);
        }

        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;
            out = try subst.substituteOne(self.store, out, fid, @intCast(i), bound);
        }

        if (fd.type_params.len > 0 and arg_types.len >= fd.params.len) {
            var all_concrete = true;
            const solved_args = self.allocator.alloc(TypeId, solved.len) catch return out;
            defer self.allocator.free(solved_args);
            for (solved, 0..) |maybe, i| {
                const bound = maybe orelse {
                    all_concrete = false;
                    break;
                };
                switch (self.store.get(bound)) {
                    .type_param, .unresolved => {
                        all_concrete = false;
                    },
                    else => {},
                }
                solved_args[i] = bound;
            }
            if (all_concrete) {
                _ = mono.noteFreeFnInst(self.allocator, self.store, fd.name, fid, fd.type_params, solved_args);
                if (self.ir) |ir| ir.recordMethodArgs(self.allocator, call_expr, solved_args) catch {};
            }
        }

        return out;
    }

    /// Records an [`OptDerefError`] for reaching through an optional/error-union
    /// without unwrapping. Honours the `NOVA_OPT_AUDIT` env var to also print
    /// the site to stderr for debugging where see-throughs occur.
    fn recordOptDeref(self: *Inferer, fa: ast.FieldAccess, is_method: bool, kind: OptDerefKind) void {
        if (std.c.getenv("NOVA_OPT_AUDIT") != null)
            std.debug.print("OPT-SEETHROUGH {s} {s}:{d}:{d} .{s}\n", .{ if (is_method) "method" else "field", fa.span.file, fa.span.line, fa.span.col, fa.field });
        self.optional_deref_errors.append(self.allocator, .{ .span = fa.span, .field = fa.field, .is_method = is_method, .kind = kind }) catch {};
    }

    /// Types a struct field access `obj.field`, or null if it is not a struct
    /// field.
    ///
    /// If the object is an optional or error union it records a see-through
    /// diagnostic ([`Inferer.recordOptDeref`]) and returns null rather than
    /// piercing the wrapper. On a struct it lowers the matching field's type in
    /// the receiver's scope so generic fields resolve. The `stats.typed -|= 1`
    /// undoes the object's own typing bump, since the object was only visited to
    /// reach the field.
    fn fieldType(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        const obj = try self.inferExpr(fa.object);

        self.stats.typed -|= 1;
        const t = self.store.get(obj);

        if (t == .optional) {
            self.recordOptDeref(fa, false, .opt);
            return null;
        }

        if (t == .error_union) {
            self.recordOptDeref(fa, false, .err);
            return null;
        }
        if (t != .struct_) return null;
        const sym = self.symtab.symbolAt(t.struct_.decl);
        if (sym.decl != .struct_) return null;
        for (sym.decl.struct_.fields) |f| {

            if (std.mem.eql(u8, f.name, fa.field)) {
                return try self.lowerInStructScope(t.struct_, f.type_name);
            }
        }
        return null;
    }

    /// If `fa`'s object is a bare identifier that names an imported or
    /// segment-addressable module (and is NOT a local binding), returns that
    /// module id; otherwise null. Distinguishes `mymod.foo` from `localVar.foo`.
    fn moduleOfObject(self: *Inferer, fa: ast.FieldAccess) ?symbols.ModuleId {
        if (fa.object.kind != .ident) return null;
        const name = fa.object.kind.ident;
        if (self.lookup(name) != null) return null;

        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name)) |mid| return mid;
        }
        return self.symtab.findModuleBySegment(name);
    }

    /// Resolves the type of a named module-level constant by inferring its
    /// initialiser expression, or null if there is no such const or it is
    /// unresolved.
    ///
    /// Guards against const-to-const cycles with a depth cap
    /// ([`Inferer.const_depth`], limit 8). It also records a visibility error if
    /// the const is private to another module, de-duplicating against the last
    /// recorded one. The typed-stat delta from inferring the initialiser is
    /// rolled back so counting a const's body does not inflate coverage.
    fn constType(self: *Inferer, name: []const u8) !?TypeId {
        if (self.const_depth > 8) return null;
        for (self.symtab.symbols.items) |sym| {
            if (sym.kind != .constant) continue;
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (sym.decl != .constant) return null;

            if (self.current_module) |cm| {
                if (sym.module != cm and sym.visibility != .public) {
                    const seen = self.visibility_errors.items.len > 0 and blk: {
                        const last = self.visibility_errors.items[self.visibility_errors.items.len - 1];
                        break :blk last.kind == .const_ and std.mem.eql(u8, last.field, name);
                    };
                    if (!seen) self.visibility_errors.append(self.allocator, .{ .span = sym.span, .recv = "", .field = name, .kind = .const_ }) catch {};
                }
            }
            self.const_depth += 1;
            defer self.const_depth -= 1;
            const before = self.stats.typed;
            const t = try self.inferExpr(&sym.decl.constant.value);

            self.stats.typed = before;
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return null;
    }

    /// Types the built-in `.length`/`.len` property on strings and arrays as
    /// `int`, or null for any other field or receiver. Lets `s.length` and
    /// `arr.len` work without a declared field.
    fn stringProperty(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (!std.mem.eql(u8, fa.field, "length") and !std.mem.eql(u8, fa.field, "len")) return null;
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        const k = self.store.get(obj);
        if (k != .string and k != .array) return null;
        return try self.store.intT();
    }

    /// Types a call on a builtin RECEIVER (e.g. `bytes.foo(...)`,
    /// `console.log(...)`) by looking the method up in the [`builtins`] table,
    /// or null if the receiver is a local binding or not a known builtin. Only
    /// applies when the receiver is a bare ident that is not shadowed locally.
    fn builtinCallReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;
        if (!builtins.isReceiver(recv)) return null;
        const b = builtins.find(recv, fa.field) orelse return null;
        return try builtins.retType(self.store, b.ret);
    }

    /// Records a [`VisError`] of kind `.type_` if `name` names a type private to
    /// another module used from the current one.
    ///
    /// Skips synthetic spans (file starting with `<`, e.g. generated code) and
    /// de-duplicates against the immediately preceding error at the same
    /// location. A public type, or one in the current module, is fine.
    fn recordTypeVis(self: *Inferer, name: []const u8, span: ast.Span) void {

        if (span.file.len > 0 and span.file[0] == '<') return;
        const cm = self.current_module orelse return;
        const sid = self.symtab.findTypeInModule(name, self.current_module) orelse return;
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;

        if (self.visibility_errors.items.len > 0) {
            const last = self.visibility_errors.items[self.visibility_errors.items.len - 1];
            if (last.span.line == span.line and last.span.col == span.col and std.mem.eql(u8, last.field, name)) return;
        }
        self.visibility_errors.append(self.allocator, .{ .span = span, .recv = "", .field = name, .kind = .type_ }) catch {};
    }

    /// Recursively checks a type reference (and every type it mentions, through
    /// optionals, error unions, arrays, generics, function types, and tuples)
    /// for cross-module visibility violations via [`Inferer.recordTypeVis`].
    /// Used on declared types at let bindings.
    fn checkTypeRefVis(self: *Inferer, tr: ast.TypeRef, span: ast.Span) void {
        switch (tr) {
            .ident => |name| self.recordTypeVis(name, span),
            .optional => |inner| self.checkTypeRefVis(inner.*, span),
            .error_union => |eu| {
                self.checkTypeRefVis(eu.ok.*, span);
                self.checkTypeRefVis(eu.err.*, span);
            },
            .fixed_array => |fa| self.checkTypeRefVis(fa.element.*, span),
            .generic => |g| {
                self.recordTypeVis(g.name, span);
                for (g.params) |p| self.checkTypeRefVis(p, span);
            },
            .func => |f| {
                for (f.params) |p| self.checkTypeRefVis(p, span);
                self.checkTypeRefVis(f.ret.*, span);
            },
            .tuple => |elems| for (elems) |e| self.checkTypeRefVis(e, span),
        }
    }

    /// Resolves `recv.field` to a function symbol, treating `recv` as a module
    /// name (imported alias first, then a bare segment), or null.
    ///
    /// On a hit it records a visibility diagnostic if the target function is
    /// private to another module (via [`Inferer.recordFnVisibility`]). This is
    /// the module-function counterpart to method resolution.
    fn resolveModuleFn(self: *Inferer, recv: []const u8, field: []const u8, span: ast.Span) ?types.SymbolId {
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, recv)) |mid| {
                if (self.symtab.findFunctionIn(mid, field)) |sid| {
                    self.recordFnVisibility(sid, cm, recv, field, span);
                    return sid;
                }
            }
        }

        if (self.symtab.findFunctionBySegment(recv, field)) |sid| {
            if (self.current_module) |cm| self.recordFnVisibility(sid, cm, recv, field, span);
            return sid;
        }
        return null;
    }

    /// Records a function-visibility [`VisError`] if `sid` is private to another
    /// module. De-duplicates against the previous error at the same span.
    /// Helper for [`Inferer.resolveModuleFn`].
    fn recordFnVisibility(self: *Inferer, sid: types.SymbolId, cm: symbols.ModuleId, recv: []const u8, field: []const u8, span: ast.Span) void {
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;

        const dup = self.visibility_errors.items.len > 0 and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.line == span.line and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.col == span.col;
        if (!dup) self.visibility_errors.append(self.allocator, .{ .span = span, .recv = recv, .field = field }) catch {};
    }

    /// Whether an unresolved identifier should be treated as a hard compile
    /// error rather than a tolerable miss.
    ///
    /// Returns false (non-fatal) for a curated set that legitimately fails local
    /// resolution: `self`, runtime intrinsics (`nova_*`), the magic receivers
    /// (`bytes`/`console`/`sync`/`atomic`), builtin receivers and types, and any
    /// name that resolves to a known module. Anything else is a genuine
    /// undefined name and returns true, feeding
    /// [`Inferer.fatal_unresolved_idents`].
    fn isFatalUnresolvedIdent(self: *Inferer, name: []const u8) bool {
        if (std.mem.eql(u8, name, "self")) return false;

        if (std.mem.startsWith(u8, name, "nova_")) return false;

        const magic = [_][]const u8{ "bytes", "console", "sync", "atomic" };
        for (magic) |m| if (std.mem.eql(u8, name, m)) return false;

        if (builtins.isReceiver(name)) return false;

        const builtin_types = [_][]const u8{ "Storage", "Atomic" };
        for (builtin_types) |t| if (std.mem.eql(u8, name, t)) return false;

        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name) != null) return false;
        }
        if (self.symtab.findModuleByImportName(name) != null) return false;
        if (self.symtab.findModuleBySegment(name) != null) return false;
        return true;
    }

    /// Whether `name` refers to any known module (imported alias, import name,
    /// or bare segment). Used to decide that `name.field()` is a module call so
    /// a missing function there is fatal.
    fn isKnownModule(self: *Inferer, name: []const u8) bool {
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name) != null) return true;
        }
        if (self.symtab.findModuleByImportName(name) != null) return true;
        if (self.symtab.findModuleBySegment(name) != null) return true;
        return false;
    }

    /// Types a module function call `mod.fn(...)`, writing the resolved symbol to
    /// `out_sym`, or null if the receiver is not a module or names no function.
    ///
    /// Lowers the function's return type in the TARGET module's scope (saving
    /// and restoring the lowerer's module), so types named relative to the
    /// callee's module resolve correctly. A void-returning function yields the
    /// void type; an unresolved return yields null.
    fn moduleCallReturn(self: *Inferer, fa: ast.FieldAccess, out_sym: *?types.SymbolId) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;

        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;

        out_sym.* = sid;
        if (sym.decl.function.ret_type) |r| {
            const saved_mod = self.lowerer.current_module;
            self.lowerer.current_module = sym.module;
            defer self.lowerer.current_module = saved_mod;
            const t = try self.lowerer.lower(r);
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return try self.store.voidT();
    }

    /// Types a module function referenced as a VALUE (`mod.fn` without calling
    /// it) as its `func` type, or null. The value-position counterpart to
    /// [`Inferer.moduleCallReturn`].
    fn moduleFnValue(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;
        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;
        return try self.fnType(sym.decl.function);
    }

    /// Types a static method call `Type.method(...)` (receiver is a type name,
    /// not an instance) as the method's lowered return type, or null.
    ///
    /// Resolves the method in the TYPE's own module so a static defined
    /// alongside the type is found regardless of the current module. A missing
    /// return type yields void; an unresolved one yields null.
    fn staticMethodReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {

        const type_name = switch (fa.object.kind) {
            .ident => |n| n,
            .field_access => |ofa| ofa.field,
            else => return null,
        };

        const tsid = self.symtab.findTypeInModule(type_name, self.current_module) orelse return null;
        const tmod = self.symtab.symbolAt(tsid).module;
        const mid = self.symtab.findMethodInModule(type_name, fa.field, tmod) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();
        const lowered = try self.lowerer.lower(ret);
        if (self.store.get(lowered) == .unresolved) return null;
        return lowered;
    }

    /// Types an INSTANCE method call `recv.method(args)`, writing the resolved
    /// symbol to `out_sym`, or null if the receiver is not a struct/enum/trait
    /// with such a method.
    ///
    /// The workhorse of method typing, handling several receiver shapes: an
    /// optional/error-union receiver records a see-through and returns null; a
    /// trait receiver dispatches to [`Inferer.traitMethodReturn`]; a `storage`
    /// receiver special-cases `get`/`set`; enum and struct receivers resolve the
    /// method in the owner's module, check arity, and lower the return in the
    /// method scope. For a GENERIC method it also solves the method's type
    /// params from the argument types, substitutes them out of the return type,
    /// and (when fully concrete) registers the instantiation with [`mono`] and
    /// records the solved args into the IR. Returns null on an unresolved
    /// result. `stats.typed -|= 1` undoes the receiver's typing bump.
    fn methodReturn(self: *Inferer, fa: ast.FieldAccess, args: []const ast.Expression, out_sym: *?types.SymbolId, call_ep: *const ast.Expression) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        const t = self.store.get(obj);

        if (t == .optional) {
            self.recordOptDeref(fa, true, .opt);
            return null;
        }
        if (t == .error_union) {
            self.recordOptDeref(fa, true, .err);
            return null;
        }

        if (t == .trait_) return try self.traitMethodReturn(t.trait_, fa.field);

        if (t == .storage) {
            if (std.mem.eql(u8, fa.field, "get")) return t.storage;
            if (std.mem.eql(u8, fa.field, "set")) return try self.store.voidT();
            return null;
        }

        if (t == .enum_) {
            const owner = self.symtab.symbolAt(t.enum_);
            const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
            out_sym.* = mid;
            const m = self.symtab.symbolAt(mid);
            if (m.decl != .function) return null;
            self.checkMethodArity(m.decl.function.params, args, fa, owner.name, fa.span);
            const ret = m.decl.function.ret_type orelse return try self.store.voidT();
            const lowered = try self.lowerer.lower(ret);
            if (self.store.get(lowered) == .unresolved) return null;
            return lowered;
        }
        if (t != .struct_) return null;
        const owner = self.symtab.symbolAt(t.struct_.decl);
        const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;

        out_sym.* = mid;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        self.checkMethodArity(m.decl.function.params, args, fa, owner.name, fa.span);
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();

        const fd0 = m.decl.function;
        const sub = try self.lowerInMethodScope(t.struct_, mid, fd0, ret);

        const fd = fd0;
        if (fd.type_params.len == 0) {
            if (self.store.get(sub) == .unresolved) return null;
            return sub;
        }
        const solved = try self.allocator.alloc(?TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        @memset(solved, null);

        var declared_l = std.ArrayListUnmanaged(TypeId).empty;
        defer declared_l.deinit(self.allocator);
        for (fd.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            const tr = p.type_name orelse {
                try declared_l.append(self.allocator, try self.store.unresolvedT());
                continue;
            };
            try declared_l.append(self.allocator, try self.lowerInMethodScope(t.struct_, mid, fd, tr));
        }
        const declared = declared_l.items;
        for (declared, 0..) |dp, i| {
            if (i >= args.len) break;

            const actual = try self.inferExprExpecting(&args[i], dp);
            subst.solveParams(self.store, dp, actual, mid, solved);
        }

        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;

            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }

        if (self.ir) |ir| {
            var all_concrete = true;
            for (solved) |ma| {
                const mt = ma orelse {
                    all_concrete = false;
                    break;
                };
                const k = self.store.get(mt);
                if (k == .type_param or k == .unresolved) {
                    all_concrete = false;
                    break;
                }
            }
            if (all_concrete) {
                const buf = try self.allocator.alloc(TypeId, solved.len);
                defer self.allocator.free(buf);
                for (solved, 0..) |ma, i| buf[i] = ma.?;
                try ir.recordMethodArgs(self.allocator, call_ep, buf);

                mono.noteMethodInst(self.allocator, self.store, obj, mid, fa.field, fd.type_params, buf);

                mono.noteBaseNeeded(self.allocator, self.store, obj, fa.field);
            }
        }
        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    /// Types a generic method call with EXPLICIT type arguments
    /// (`recv.method<T>(args)`) by substituting the given `type_args` into the
    /// return type, or null.
    ///
    /// Unlike [`Inferer.methodReturn`], the type params are supplied directly
    /// rather than solved from arguments, so it only applies when the count of
    /// type args matches the method's type-param count. It still types the
    /// arguments (with the declared param types as hints) and, when the args are
    /// fully concrete, registers the instantiation with [`mono`]. Peels one
    /// optional layer off the receiver before requiring a struct.
    fn explicitMethodReturn(
        self: *Inferer,
        fa: ast.FieldAccess,
        type_args: []ast.TypeRef,
        args: []const ast.Expression,
        out_sym: *?types.SymbolId,
    ) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        var t = self.store.get(obj);
        if (t == .optional) t = self.store.get(t.optional);
        if (t != .struct_) return null;
        const owner = self.symtab.symbolAt(t.struct_.decl);
        const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const fd = m.decl.function;

        if (fd.type_params.len == 0 or fd.type_params.len != type_args.len) return null;
        out_sym.* = mid;

        const pts = self.paramTypesOf(fd, t.struct_) catch null;
        defer if (pts) |p| self.allocator.free(p);
        for (args, 0..) |*a, i| {
            const exp: ?TypeId = if (pts) |p| (if (i < p.len) p[i] else null) else null;
            _ = try self.inferExprExpecting(a, exp);
        }

        const ret = fd.ret_type orelse return try self.store.voidT();
        const solved = try self.allocator.alloc(TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        for (type_args, 0..) |ta, i| solved[i] = try self.lowerer.lower(ta);

        var out = try self.lowerInMethodScope(t.struct_, mid, fd, ret);
        for (solved, 0..) |bound, i| {
            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }

        if (self.ir) |_| {
            var all_concrete = true;
            for (solved) |s| {
                const k = self.store.get(s);
                if (k == .type_param or k == .unresolved) {
                    all_concrete = false;
                    break;
                }
            }
            if (all_concrete) {
                mono.noteMethodInst(self.allocator, self.store, obj, mid, fa.field, fd.type_params, solved);
            }
        }

        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    /// Walks one branch of an `if`, applying optional narrowing inside it.
    ///
    /// If `narrow` applies to this branch (`when_true == is_then`) and the named
    /// binding is currently an optional, it pushes a scoped shadow binding of
    /// the UNWRAPPED type for the duration of the branch, so `s.field` typechecks
    /// where `s` is known present. Otherwise the branch is walked unchanged.
    fn narrowedBranch(self: *Inferer, narrow: ?Narrowing, is_then: bool, branch: *const ast.Statement) anyerror!void {
        const n = narrow orelse return self.inferStmt(branch);
        if (n.when_true != is_then) return self.inferStmt(branch);
        const cur = self.lookup(n.name) orelse return self.inferStmt(branch);
        const t = self.store.get(cur);
        if (t != .optional) return self.inferStmt(branch);
        try self.push();
        defer self.pop();
        try self.bind(n.name, t.optional);
        try self.inferStmt(branch);
    }

    /// Computes the declared parameter types of a call's callee (a free function
    /// or a method), so arguments can be typed WITH an expected type. Returns an
    /// owned slice (caller frees) or null when the callee cannot be resolved.
    ///
    /// For a method it types the receiver quietly (via
    /// [`Inferer.typeOfObjectQuietly`], no IR side effects) to find the owning
    /// struct and lowers the params in its scope.
    fn calleeParamTypes(self: *Inferer, callee: *const ast.Expression) !?[]TypeId {
        switch (callee.kind) {
            .ident => |n| {
                const sid = self.symtab.findFunction(n) orelse return null;
                const sym = self.symtab.symbolAt(sid);
                if (sym.decl != .function) return null;
                return try self.paramTypesOf(sym.decl.function, null);
            },
            .field_access => |fa| {

                const obj = self.typeOfObjectQuietly(fa.object) orelse return null;
                const t = self.store.get(obj);
                if (t != .struct_) return null;
                const owner = self.symtab.symbolAt(t.struct_.decl);
                const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
                const m = self.symtab.symbolAt(mid);
                if (m.decl != .function) return null;
                return try self.paramTypesOf(m.decl.function, t.struct_);
            },
            else => return null,
        }
    }

    /// Lowers a function's parameter types into an owned slice, skipping an
    /// implicit `self`, resolving generics in the receiver's scope when `recv`
    /// is given.
    ///
    /// An untyped parameter becomes `unresolved`. Caller owns and frees the
    /// returned slice. Shared by [`Inferer.calleeParamTypes`] and
    /// [`Inferer.explicitMethodReturn`].
    fn paramTypesOf(self: *Inferer, fd: *const ast.FunctionDecl, recv: ?types.StructType) !?[]TypeId {
        var out = std.ArrayListUnmanaged(TypeId).empty;
        errdefer out.deinit(self.allocator);
        for (fd.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            const tr = p.type_name orelse {
                try out.append(self.allocator, try self.store.unresolvedT());
                continue;
            };
            const t = if (recv) |r|
                try self.lowerInStructScope(r, tr)
            else
                try self.lowerer.lower(tr);
            try out.append(self.allocator, t);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    /// Resolves the type of a receiver expression WITHOUT running full inference
    /// or touching stats/IR: handles a plain binding and a chain of struct field
    /// accesses only.
    ///
    /// Used where knowing the receiver type must not have side effects (e.g.
    /// pre-computing param-type hints in [`Inferer.calleeParamTypes`]). Returns
    /// null for anything more complex than ident/field-chain.
    fn typeOfObjectQuietly(self: *Inferer, obj: *const ast.Expression) ?TypeId {
        switch (obj.kind) {
            .ident => |n| return self.lookup(n),
            .field_access => |fa| {
                const recv = self.typeOfObjectQuietly(fa.object) orelse return null;
                const t = self.store.get(recv);
                if (t != .struct_) return null;
                const sym = self.symtab.symbolAt(t.struct_.decl);
                if (sym.decl != .struct_) return null;
                for (sym.decl.struct_.fields) |f| {
                    if (std.mem.eql(u8, f.name, fa.field)) {
                        return self.lowerInStructScope(t.struct_, f.type_name) catch return null;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Types a method call on a TRAIT-object receiver as the declared return
    /// type of the matching trait method, or null if the trait has no such
    /// method. A method with no declared return is void. Feeds the trait arm of
    /// [`Inferer.methodReturn`].
    fn traitMethodReturn(self: *Inferer, tid: types.SymbolId, field: []const u8) !?TypeId {
        const sym = self.symtab.symbolAt(tid);
        if (sym.decl != .trait_) return null;
        for (sym.decl.trait_.methods) |m| {
            if (!std.mem.eql(u8, m.name, field)) continue;
            const ret = m.ret_type orelse return try self.store.voidT();
            const t = try self.lowerer.lower(ret);
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return null;
    }

    /// Attempts to infer a closure parameter's type from how it is USED in the
    /// closure body, when no expected type pinned it down.
    ///
    /// Only an expression-bodied closure is analysed; a block body returns null
    /// (too complex to walk usefully here). Delegates to
    /// [`Inferer.paramFromUseExpr`].
    fn paramFromUse(self: *Inferer, param: []const u8, body: ast.ClosureBody) anyerror!?TypeId {
        return switch (body) {
            .expr => |e| try self.paramFromUseExpr(param, e),

            .block => null,
        };
    }

    /// Recursively searches an expression for an arithmetic/bitwise operation
    /// with `param` on one side and a TYPEABLE other side, returning that other
    /// side's type as the param's inferred type.
    ///
    /// For example in `x + 1`, `x`'s type is inferred as `int` from the literal.
    /// Non-arithmetic binary ops just recurse into both sides. The other side is
    /// typed quietly (no IR/stats effect). Returns null if nothing constrains
    /// the param.
    fn paramFromUseExpr(self: *Inferer, param: []const u8, e: *const ast.Expression) anyerror!?TypeId {
        switch (e.kind) {
            .binary => |b| {
                switch (b.op) {
                    .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or => {},

                    else => return (try self.paramFromUseExpr(param, b.left)) orelse
                        try self.paramFromUseExpr(param, b.right),
                }
                const l_is = b.left.kind == .ident and std.mem.eql(u8, b.left.kind.ident, param);
                const r_is = b.right.kind == .ident and std.mem.eql(u8, b.right.kind.ident, param);
                if (l_is != r_is) {
                    const other = if (l_is) b.right else b.left;
                    const t = try self.inferExprQuietly(other, null);
                    if (self.store.get(t) != .unresolved) return t;

                }

                return (try self.paramFromUseExpr(param, b.left)) orelse
                    try self.paramFromUseExpr(param, b.right);
            },
            .unary => |u| return try self.paramFromUseExpr(param, u.operand),
            else => return null,
        }
    }

    /// Infers an expression's type as a pure PROBE, leaving no trace: it nulls
    /// the IR and saves/restores the stats and every fatal-miss counter around
    /// the walk.
    ///
    /// This lets speculative typing (param-from-use, look-ahead argument typing)
    /// discover a type without recording results or wrongly incrementing the
    /// fatal-error counters that would fail the build. The full set of saved
    /// fields is why it is a method and not a one-liner.
    fn inferExprQuietly(self: *Inferer, e: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const saved_ir = self.ir;
        const saved = self.stats.typed;
        const saved_fatal_idents = self.fatal_unresolved_idents;
        const saved_first_ident = self.first_fatal_ident;
        const saved_first_span = self.first_fatal_span;
        const saved_fatal_calls = self.fatal_unresolved_calls;
        const saved_first_call_recv = self.first_fatal_call_recv;
        const saved_first_call_field = self.first_fatal_call_field;
        const saved_first_call_span = self.first_fatal_call_span;
        self.ir = null;
        defer {
            self.ir = saved_ir;
            self.stats.typed = saved;
            self.fatal_unresolved_idents = saved_fatal_idents;
            self.first_fatal_ident = saved_first_ident;
            self.first_fatal_span = saved_first_span;
            self.fatal_unresolved_calls = saved_fatal_calls;
            self.first_fatal_call_recv = saved_first_call_recv;
            self.first_fatal_call_field = saved_first_call_field;
            self.first_fatal_call_span = saved_first_call_span;
        }
        return self.inferExprInner(e.*, expected);
    }

    /// Walks a block in its own lexical scope: pushes a scope, infers the
    /// statement sequence, then pops. The scoping entry point for `{ ... }`.
    pub fn inferBlock(self: *Inferer, b: *const ast.Block) anyerror!void {
        try self.push();
        defer self.pop();
        try self.inferStmtSeq(b.statements);
    }

    /// Walks a statement sequence, applying EARLY-EXIT narrowing to the tail.
    ///
    /// After each statement it checks [`earlyExitNarrowing`]: if an
    /// `if (x == undefined) return;`-style guard proves `x` present, it pushes a
    /// scoped shadow binding of the unwrapped type and recurses on the REMAINING
    /// statements, so the rest of the block sees the narrowed type. Tracks
    /// `current_stmt_seq` so closure look-ahead can find later calls in the same
    /// sequence.
    pub fn inferStmtSeq(self: *Inferer, statements: []ast.Statement) anyerror!void {
        const saved_seq = self.current_stmt_seq;
        self.current_stmt_seq = statements;
        defer self.current_stmt_seq = saved_seq;
        for (statements, 0..) |*s, idx| {
            try self.inferStmt(s);
            if (earlyExitNarrowing(s)) |n| {
                const cur = self.lookup(n.name) orelse continue;
                const t = self.store.get(cur);
                if (t == .optional) {

                    try self.push();
                    defer self.pop();
                    try self.bind(n.name, t.optional);
                    try self.inferStmtSeq(statements[idx + 1 ..]);
                    return;
                }
            }
        }
    }

    /// Walks a single statement, binding new names and typing sub-expressions.
    ///
    /// Handles let bindings (including declared-type checking, tuple
    /// destructuring, closure-expectation shaping, and same-name const-checks),
    /// `if`/`while`/`for` (with narrowing on the guard and loop-variable
    /// binding), `switch` (binding enum-payload names per case), and `return`
    /// (checking optional-in-plain-return and capturing the return type for
    /// later inference). Conditions are validated for bool-ness via
    /// [`Inferer.checkCond`].
    pub fn inferStmt(self: *Inferer, sp: *const ast.Statement) anyerror!void {
        switch (sp.*) {
            .block => |*b| try self.inferBlock(b),
            .let_stmt => |*ls| {
                var t: TypeId = undefined;
                if (ls.type_name) |declared| {
                    t = try self.lowerer.lower(declared);
                    self.checkTypeRefVis(declared, ls.span);

                    if (ls.init) |*i| {
                        const it = try self.inferExprExpecting(i, t);
                        self.checkPlainTarget(i.span, t, it, "assigned to a variable of type");
                    }
                } else if (ls.init) |*i| {
                    if (i.kind == .closure and i.kind.closure.params.len > 0 and ls.names == null) {
                        if (try self.closureCallExpectation(ls.name, i.kind.closure.params.len)) |exp| {
                            t = try self.inferExprExpecting(i, exp);
                        } else {
                            t = try self.inferExpr(i);
                        }
                    } else {
                        t = try self.inferExpr(i);
                    }
                } else {
                    t = try self.store.unresolvedT();
                }

                if (ls.names) |names| {
                    const ty = self.store.get(t);
                    if (ty == .tuple and ty.tuple.len == names.len) {
                        for (names, ty.tuple) |n, elem_t| try self.bindC(n, elem_t, ls.is_const);
                    } else {
                        for (names) |n| try self.bindC(n, try self.store.unresolvedT(), ls.is_const);
                    }
                } else {
                    try self.bindC(ls.name, t, ls.is_const);
                }
            },
            .expr_stmt => |*es| _ = try self.inferExpr(&es.expr),
            .if_stmt => |*i| {
                try self.checkCond(&i.condition, "if");

                const narrow: ?Narrowing = if (i.condition.kind == .binary)
                    narrowedBinding(i.condition.kind.binary)
                else
                    null;

                try self.narrowedBranch(narrow, true, i.then_branch);
                if (i.else_branch) |e| try self.narrowedBranch(narrow, false, e);
            },
            .while_stmt => |*w| {
                try self.checkCond(&w.condition, "while");
                try self.inferStmt(w.body);
            },
            .for_stmt => |*f| {
                try self.push();
                defer self.pop();

                if (f.initializer) |i| try self.inferStmt(i);
                if (f.condition) |*c| try self.checkCond(c, "for");
                if (f.increment) |*inc| _ = try self.inferExpr(inc);

                if (f.iterator) |*it| {
                    _ = try self.inferExpr(it.iterable);
                    switch (it.binding) {
                        .item => |n| {
                            const elem_t = if (it.iterable.kind == .range) try self.store.intT() else try self.store.unresolvedT();
                            try self.bindC(n, elem_t, false);
                        },
                        .destructure => |d| {
                            try self.bindC(d.key, try self.store.unresolvedT(), false);
                            try self.bindC(d.value, try self.store.unresolvedT(), false);
                        },
                    }
                }
                try self.inferStmt(f.body);
            },
            .switch_stmt => |*sw| {
                const disc_t = try self.inferExpr(&sw.discriminant);
                for (sw.cases) |*c| {

                    try self.bindSwitchPayloads(disc_t, c);
                    for (c.values) |*v| _ = try self.inferExpr(v);
                    if (c.guard) |*g| _ = try self.inferExpr(g);
                    try self.inferStmt(c.body);
                }
                if (sw.default_case) |d| try self.inferStmt(d);
            },
            .return_stmt => |*r| {

                if (r.value) |*v| {
                    const rt = try self.inferExprExpecting(v, self.current_ret);

                    if (self.current_ret) |crt| {
                        const rtk = self.store.get(rt);
                        const crtk = self.store.get(crt);
                        const declared_plain = crtk != .optional and crtk != .unresolved and
                            crtk != .any_ and crtk != .error_union;
                        if (rtk == .optional and declared_plain) {
                            self.ret_optional_errors.append(self.allocator, .{ .span = v.span, .ret = crt, .val = rt }) catch {};
                        }
                    }

                    if (self.store.get(rt) != .unresolved) self.captured_return = rt;
                }
            },
            .defer_stmt => |*d| _ = try self.inferExpr(&d.expr),
.break_stmt, .continue_stmt => {},
        }
    }

    /// Flags a [`ValoptPosError`] when a value-OPTIONAL is supplied to a
    /// position that requires a PLAIN type (a typed let binding or a typed
    /// parameter).
    ///
    /// "Plain" excludes optionals, unresolved, `any`, error unions, and type
    /// params, i.e. targets where an optional would be an outright type error.
    /// `ctx` describes the position for the message.
    fn checkPlainTarget(self: *Inferer, span: ast.Span, want: TypeId, got: TypeId, ctx: []const u8) void {
        const wk = self.store.get(want);
        const plain = wk != .optional and wk != .unresolved and wk != .any_ and wk != .error_union and wk != .type_param;
        if (plain and self.store.get(got) == .optional) {
            self.valopt_pos_errors.append(self.allocator, .{ .span = span, .want = want, .got = got, .ctx = ctx }) catch {};
        }
    }

    /// Types a condition expression and records a [`CondTypeError`] if it is a
    /// known non-bool type. An unresolved condition is left alone (honesty
    /// rule). `ctx` names the construct (`"if"`/`"while"`/`"for"`).
    fn checkCond(self: *Inferer, cond: *const ast.Expression, ctx: []const u8) !void {
        const t = try self.inferExpr(cond);
        const ty = self.store.get(t);
        const is_bool = ty == .prim and ty.prim.kind == .bool;
        if (!is_bool and ty != .unresolved) {
            self.cond_type_errors.append(self.allocator, .{ .span = cond.span, .got = t, .ctx = ctx }) catch {};
        }
    }

    /// Checks a method call's argument count against its declaration, recording
    /// a [`MethodArityError`] on mismatch.
    ///
    /// The subtlety is `self`: a method with a leading `self` param expects one
    /// FEWER argument when invoked on an instance (`obj.m(a)`), but the FULL
    /// count when invoked statically through the type name (`Type.m(obj, a)`).
    /// It detects the static form by the receiver being the type name itself.
    fn checkMethodArity(self: *Inferer, fnp: []const ast.Param, args: []const ast.Expression, fa: ast.FieldAccess, owner_name: []const u8, span: ast.Span) void {
        const has_self = fnp.len > 0 and std.mem.eql(u8, fnp[0].name, "self");
        const self_explicit = fa.object.kind == .ident and
            self.lookup(fa.object.kind.ident) == null and
            std.mem.eql(u8, fa.object.kind.ident, owner_name);
        var expected: usize = fnp.len;
        if (has_self and !self_explicit) expected -= 1;
        if (args.len != expected) {
            self.method_arity_errors.append(self.allocator, .{ .span = span, .name = fa.field, .expected = expected, .got = args.len }) catch {};
        }
    }

    /// Prints a yellow compiler warning to stderr if the called function
    /// carries a `@deprecated` attribute, including the optional message. Emits
    /// at most one warning per call. Does not use `self` (kept as a method for
    /// call-site symmetry).
    fn warnIfDeprecated(self: *Inferer, fd: *const ast.FunctionDecl, span: ast.Span) void {
        _ = self;
        for (fd.attributes) |attr| {
            switch (attr) {
                .deprecated => |dep_note| {
                    if (dep_note) |msg| {
                        std.debug.print("  \x1b[1m{s}:{d}:{d}: \x1b[33mwarning:\x1b[0m\x1b[1m '{s}' is deprecated: {s}\x1b[0m\n", .{ span.file, span.line, span.col, fd.name, msg });
                    } else {
                        std.debug.print("  \x1b[1m{s}:{d}:{d}: \x1b[33mwarning:\x1b[0m\x1b[1m '{s}' is deprecated\x1b[0m\n", .{ span.file, span.line, span.col, fd.name });
                    }
                    return;
                },
                else => {},
            }
        }
    }

    /// Binds the payload variables introduced by an enum-pattern switch case, so
    /// the case body can use them with their declared types.
    ///
    /// For a discriminant of enum type, each case value is matched against the
    /// enum's variants: a call-form pattern (`Variant(x)`) binds a
    /// single-payload or positional-field payload; a struct-init form
    /// (`Variant { a, b }`) binds named fields. Non-enum discriminants and
    /// non-pattern values are ignored.
    fn bindSwitchPayloads(self: *Inferer, disc_t: TypeId, c: *const ast.SwitchCase) anyerror!void {
        const dt = self.store.get(disc_t);
        if (dt != .enum_) return;
        const sym = self.symtab.symbolAt(dt.enum_);
        if (sym.decl != .enum_) return;
        const enum_decl = sym.decl.enum_;
        for (c.values) |v| {
            switch (v.kind) {

                .call => |call| {
                    if (call.callee.kind != .field_access) continue;
                    const variant_name = call.callee.kind.field_access.field;
                    for (enum_decl.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, variant_name)) continue;
                        if (variant.type_name) |payload_ref| {
                            if (call.args.len == 0) break;
                            if (call.args[0].kind != .ident) break;
                            try self.bind(call.args[0].kind.ident, try self.lowerer.lower(payload_ref));
                        } else if (variant.fields) |vfields| {
                            for (call.args, 0..) |arg, i| {
                                if (i < vfields.len and arg.kind == .ident) {
                                    try self.bind(arg.kind.ident, try self.lowerer.lower(vfields[i].type_name));
                                }
                            }
                        }
                        break;
                    }
                },

                .struct_init => |si| {
                    const tn = si.type_name;
                    const variant_name = if (std.mem.lastIndexOfScalar(u8, tn, '.')) |i| tn[i + 1 ..] else tn;
                    for (enum_decl.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, variant_name)) continue;
                        const vfields = variant.fields orelse break;
                        for (si.fields) |fi| {
                            if (fi.value.kind != .ident) continue;
                            for (vfields) |vf| {
                                if (!std.mem.eql(u8, vf.name, fi.name)) continue;
                                try self.bind(fi.value.kind.ident, try self.lowerer.lower(vf.type_name));
                                break;
                            }
                        }
                        break;
                    }
                },
                else => {},
            }
        }
    }

    /// Infers a free function's body (no `self`). The public per-function entry
    /// point; thin wrapper over [`Inferer.inferFunctionWithSelf`].
    pub fn inferFunction(self: *Inferer, f: *const ast.FunctionDecl) !void {
        return self.inferFunctionWithSelf(null, f);
    }

    /// Infers a function or method body, optionally binding `self` to `self_ty`.
    ///
    /// Sets up the per-function context: a fresh scope, the owning module (for
    /// visibility and name resolution, on both this pass and the lowerer), the
    /// declared return type (for return/try checks), and the parameter bindings.
    /// All of that context is saved and restored via `defer` so functions can be
    /// walked in any order. After the body it runs
    /// [`Inferer.closureSecondPass`] to re-type closures whose parameter types
    /// only became knowable from a later call.
    pub fn inferFunctionWithSelf(self: *Inferer, self_ty: ?TypeId, f: *const ast.FunctionDecl) !void {
        try self.push();
        defer self.pop();

        const saved_module = self.current_module;
        defer self.current_module = saved_module;
        self.current_module = self.symtab.findModuleByFile(f.span.file);
        const saved_lowerer_module = self.lowerer.current_module;
        defer self.lowerer.current_module = saved_lowerer_module;
        self.lowerer.current_module = self.current_module;

        const saved_ret = self.current_ret;
        defer self.current_ret = saved_ret;
        self.current_ret = if (f.ret_type) |r| try self.lowerer.lower(r) else null;
        if (self_ty) |t| try self.bind("self", t);
        for (f.params) |p| {
            const t = if (p.type_name) |tn| try self.lowerer.lower(tn) else try self.store.unresolvedT();
            try self.bind(p.name, t);
        }
        try self.inferStmtSeq(f.body.statements);

        _ = try self.closureSecondPass(&f.body);
    }

    /// Deeply searches an expression tree for a call to `name` with `arity`
    /// arguments and returns those arguments' quietly-inferred types, or null.
    ///
    /// This is the look-ahead that lets `let f = (x) => ...; use(f(someInt))`
    /// infer `x` from how `f` is later CALLED. It recurses through most
    /// expression shapes. See also [`Inferer.callArgTypesInExpr`], the
    /// shallower statement-level variant.
    fn callArgTypesDeep(self: *Inferer, e: *const ast.Expression, name: []const u8, arity: usize) anyerror!?[]TypeId {
        switch (e.kind) {
            .call => |call| {
                if (call.callee.kind == .ident and std.mem.eql(u8, call.callee.kind.ident, name) and call.args.len == arity) {
                    const out = try self.allocator.alloc(TypeId, arity);
                    for (call.args, 0..) |*a, i| out[i] = try self.inferExprQuietly(a, null);
                    return out;
                }
                if (try self.callArgTypesDeep(call.callee, name, arity)) |r| return r;
                for (call.args) |*a| if (try self.callArgTypesDeep(a, name, arity)) |r| return r;
            },
            .generic_call => |gc| {
                if (try self.callArgTypesDeep(gc.callee, name, arity)) |r| return r;
                for (gc.args) |*a| if (try self.callArgTypesDeep(a, name, arity)) |r| return r;
            },
            .template_expr => |te| for (te.parts) |*p| { if (try self.callArgTypesDeep(p, name, arity)) |r| return r; },
            .binary => |b| {
                if (try self.callArgTypesDeep(b.left, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(b.right, name, arity)) |r| return r;
            },
            .unary => |u| { if (try self.callArgTypesDeep(u.operand, name, arity)) |r| return r; },
            .cast => |c| { if (try self.callArgTypesDeep(c.expr, name, arity)) |r| return r; },
            .nullish_coalesce => |n| {
                if (try self.callArgTypesDeep(n.left, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(n.right, name, arity)) |r| return r;
            },
            .optional_chaining => |o| { if (try self.callArgTypesDeep(o.object, name, arity)) |r| return r; },
            .field_access => |fa| { if (try self.callArgTypesDeep(fa.object, name, arity)) |r| return r; },
            .index => |ix| {
                if (try self.callArgTypesDeep(ix.object, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ix.index, name, arity)) |r| return r;
            },
            .if_expr => |ie| {
                if (try self.callArgTypesDeep(ie.condition, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ie.then_branch, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ie.else_branch, name, arity)) |r| return r;
            },
            .try_expr => |tx| { if (try self.callArgTypesDeep(tx, name, arity)) |r| return r; },
            .await_expr => |ae| { if (try self.callArgTypesDeep(ae.operand, name, arity)) |r| return r; },
            .go_expr => |ae| { if (try self.callArgTypesDeep(ae.operand, name, arity)) |r| return r; },
            .tuple => |elems| for (elems) |*el| { if (try self.callArgTypesDeep(el, name, arity)) |r| return r; },
            else => {},
        }
        return null;
    }

    /// Builds an EXPECTED function type for a closure bound to `name`, by
    /// scanning the current statement sequence for a call to `name` and using
    /// that call's argument types as the closure's parameter types.
    ///
    /// Requires at least one argument type to be known (otherwise it keeps
    /// looking). The return type is left unresolved, to be filled from the
    /// closure body. This is what makes `let f = (x) => x + 1; g(f(3))` type
    /// `x` as int at the binding site.
    fn closureCallExpectation(self: *Inferer, name: []const u8, arity: usize) anyerror!?TypeId {
        const stmts = self.current_stmt_seq orelse return null;
        for (stmts) |*s| {
            const ep: ?*const ast.Expression = switch (s.*) {
                .expr_stmt => |*es| &es.expr,
                .let_stmt => |*ls| if (ls.init) |*i| i else null,
                .return_stmt => |*rs| if (rs.value) |*v| v else null,
                else => null,
            };
            if (ep) |e| {
                if (try self.callArgTypesDeep(e, name, arity)) |arg_types| {
                    defer self.allocator.free(arg_types);
                    var any_known = false;
                    for (arg_types) |at| if (self.store.get(at) != .unresolved) { any_known = true; };
                    if (!any_known) continue;
                    return try self.store.intern(.{ .func = .{ .params = arg_types, .ret = try self.store.unresolvedT() } });
                }
            }
        }
        return null;
    }

    /// Second pass over a function body that re-types closures bound by `let`
    /// whose parameter types could only be resolved AFTER seeing a later call.
    ///
    /// Runs after the forward walk. Returns whether any closure was
    /// successfully re-typed. Delegates the per-closure work to
    /// [`Inferer.retypeBoundClosure`].
    fn closureSecondPass(self: *Inferer, fn_body: *const ast.Block) anyerror!bool {
        var retyped_any = false;
        for (fn_body.statements) |*s| {
            if (s.* != .let_stmt) continue;
            const ls = &s.let_stmt;
            const cl_init = if (ls.init) |*i| i else continue;
            if (cl_init.kind != .closure) continue;
            if (try self.retypeBoundClosure(fn_body, ls.name, cl_init)) retyped_any = true;
        }
        return retyped_any;
    }

    /// Re-infers one `let`-bound closure using its parameter types discovered
    /// from a later call, and returns whether that produced a fully-resolved
    /// function type.
    ///
    /// Short-circuits (returns false) if the closure was already fully typed on
    /// the first pass, or if no call constrains its params, or if no argument
    /// type is known. Otherwise it re-runs inference with the discovered
    /// expected function type. Helper for [`Inferer.closureSecondPass`].
    fn retypeBoundClosure(self: *Inferer, fn_body: *const ast.Block, name: []const u8, cl_init: *const ast.Expression) anyerror!bool {
        const cl = cl_init.kind.closure;
        if (cl.params.len == 0) return false;

        if (self.ir) |ir| {
            if (ir.typeOf(cl_init)) |t| {
                if (self.store.get(t) == .func) {
                    const ft = self.store.get(t).func;
                    var any_unresolved = false;
                    for (ft.params) |pt| {
                        if (self.store.get(pt) == .unresolved) any_unresolved = true;
                    }
                    if (!any_unresolved) return false;
                }
            }
        }
        const arg_types = (try self.findCallArgTypes(fn_body, name, cl.params.len)) orelse return false;
        defer self.allocator.free(arg_types);

        var any_known = false;
        for (arg_types) |at| if (self.store.get(at) != .unresolved) { any_known = true; };
        if (!any_known) return false;

        const exp = try self.store.intern(.{ .func = .{ .params = arg_types, .ret = try self.store.unresolvedT() } });
        const ct = try self.inferExprExpecting(cl_init, exp);
        if (self.store.get(ct) == .func and self.store.get(self.store.get(ct).func.ret) != .unresolved) {
            return true;
        }
        return false;
    }

    /// Searches a whole block (recursing into nested blocks and the bodies of
    /// `if`/`while`/`for`) for a call to `name` with `arity` args, returning
    /// those args' quietly-inferred types.
    ///
    /// The block-structured counterpart used by the closure SECOND pass, versus
    /// [`Inferer.closureCallExpectation`]'s flat scan on the first pass.
    /// Delegates per-statement to [`Inferer.findCallArgTypesStmt`] and
    /// [`Inferer.callArgTypesInExpr`].
    fn findCallArgTypes(self: *Inferer, block: *const ast.Block, name: []const u8, arity: usize) anyerror!?[]TypeId {
        for (block.statements) |*s| {
            const e: ?*const ast.Expression = switch (s.*) {
                .expr_stmt => |*es| &es.expr,
                .let_stmt => |*ls| if (ls.init) |*i| i else null,
                .return_stmt => |*rs| if (rs.value) |*v| v else null,
                else => null,
            };
            if (e) |ep| {
                if (try self.callArgTypesInExpr(ep, name, arity)) |r| return r;
            }
            switch (s.*) {
                .block => |*b| { if (try self.findCallArgTypes(b, name, arity)) |r| return r; },
                .if_stmt => |*is| {
                    if (try self.findCallArgTypesStmt(is.then_branch, name, arity)) |r| return r;
                    if (is.else_branch) |eb| if (try self.findCallArgTypesStmt(eb, name, arity)) |r| return r;
                },
                .while_stmt => |*ws| { if (try self.findCallArgTypesStmt(ws.body, name, arity)) |r| return r; },
                .for_stmt => |*fs| { if (try self.findCallArgTypesStmt(fs.body, name, arity)) |r| return r; },
                else => {},
            }
        }
        return null;
    }

    /// Searches a single statement for a constraining call to `name`: a block
    /// recurses via [`Inferer.findCallArgTypes`], otherwise the statement's main
    /// expression is scanned. Recursion helper for the closure second pass.
    fn findCallArgTypesStmt(self: *Inferer, sp: *const ast.Statement, name: []const u8, arity: usize) anyerror!?[]TypeId {
        if (sp.* == .block) return self.findCallArgTypes(&sp.block, name, arity);
        const e: ?*const ast.Expression = switch (sp.*) {
            .expr_stmt => |*es| &es.expr,
            .let_stmt => |*ls| if (ls.init) |*i| i else null,
            .return_stmt => |*rs| if (rs.value) |*v| v else null,
            else => null,
        };
        if (e) |ep| return self.callArgTypesInExpr(ep, name, arity);
        return null;
    }

    /// Shallow search of an expression for a direct call to `name` (`arity`
    /// args), returning those args' quietly-inferred types, else null.
    ///
    /// Unlike [`Inferer.callArgTypesDeep`], it only descends into call
    /// arguments, not the full expression tree; used at statement level in the
    /// closure second pass.
    fn callArgTypesInExpr(self: *Inferer, ep: *const ast.Expression, name: []const u8, arity: usize) anyerror!?[]TypeId {
        switch (ep.kind) {
            .call => |call| {
                if (call.callee.kind == .ident and std.mem.eql(u8, call.callee.kind.ident, name) and call.args.len == arity) {
                    const out = try self.allocator.alloc(TypeId, arity);
                    for (call.args, 0..) |*a, i| out[i] = try self.inferExprQuietly(a, null);
                    return out;
                }
                for (call.args) |*a| {
                    if (try self.callArgTypesInExpr(a, name, arity)) |r| return r;
                }
            },
            else => {},
        }
        return null;
    }
};

/// Shorthand for Zig's test assertions used throughout the unit tests below.
const testing = std.testing;

/// Test harness bundling the three collaborators an [`Inferer`] needs: a type
/// store, a symbol table, and a lowerer.
///
/// The `low` field is left `undefined` by [`Fixture.init`] because the lowerer
/// borrows `&store`, whose address is only stable once the fixture is placed in
/// its final `var`; each test therefore assigns `f.low = lower.Lowerer.init(a,
/// &f.store)` after construction. [`Fixture.deinit`] tears the three down in
/// reverse dependency order.
const Fixture = struct {
    /// The interned type store under test.
    store: types.TypeStore,
    /// The symbol table the inferer resolves names against.
    tab: symbols.SymbolTable,
    /// The lowerer; initialised by the test AFTER the fixture's address is
    /// fixed, since it holds `&store`.
    low: lower.Lowerer,

    /// Builds a fixture with a fresh store and symbol table, leaving `low`
    /// undefined for the caller to initialise once `&store` is stable.
    fn init(a: std.mem.Allocator) Fixture {
        return .{
            .store = types.TypeStore.init(a),
            .tab = symbols.SymbolTable.init(a),
            .low = undefined,
        };
    }
    /// Tears down the lowerer, symbol table, and store, in reverse of their
    /// dependency order.
    fn deinit(self: *Fixture) void {
        self.low.deinit();
        self.tab.deinit();
        self.store.deinit();
    }
};

// Verifies each literal kind gets its exact type (int/string/bool/double), the
// honesty rule that a literal is not widened to the machine word.
test "infer: literals get honest types, an int literal is int, not the machine word" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var e_int = ast.Expression{ .kind = .{ .literal = .{ .integer = 42 } } };
    var e_str = ast.Expression{ .kind = .{ .literal = .{ .string = "x" } } };
    var e_bool = ast.Expression{ .kind = .{ .literal = .{ .bool = true } } };
    var e_flt = ast.Expression{ .kind = .{ .literal = .{ .float = 1.5 } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&e_int));
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&e_str));
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&e_bool));
    try testing.expectEqual(try f.store.doubleT(), try inf.inferExpr(&e_flt));
}

// A relational operator yields bool, not the i32 of its operands: guards
// against comparisons leaking an integer type into codegen.
test "infer: a comparison is BOOL, not i32" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var cmp_e = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .lt, .span = sp } } };
    const cmp = try inf.inferExpr(&cmp_e);
    try testing.expectEqual(try f.store.boolT(), cmp);
    try testing.expect(cmp != try f.store.intT());
}

// `a + b` over two unresolved idents stays unresolved rather than defaulting
// to int: the honesty rule applied to arithmetic.
test "T4: a binary over two unknowns is UNRESOLVED, not i32" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var l = ast.Expression{ .kind = .{ .ident = "nope" } };
    var r = ast.Expression{ .kind = .{ .ident = "alsonope" } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var add_e = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .add, .span = sp } } };
    const t = try inf.inferExpr(&add_e);
    try testing.expect(f.store.get(t) == .unresolved);
    try testing.expect(t != try f.store.intT());
}

// A bound name resolves to its binding's type, while an unbound name is
// unresolved: the core scope-lookup behaviour of [`Inferer.lookup`].
test "infer: a let binding's type flows to its uses" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    try inf.push();
    try inf.bind("s", try f.store.stringT());
    var e_s = ast.Expression{ .kind = .{ .ident = "s" } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&e_s));

    var e_ghost = ast.Expression{ .kind = .{ .ident = "ghost" } };
    const u = try inf.inferExpr(&e_ghost);
    try testing.expect(f.store.get(u) == .unresolved);
}

/// Test helper: stamps stable [`ast.ExprId`]s onto the given expressions (and
/// their sub-expressions) via an id assigner, so [`TypedIr`] can key results by
/// identity. Panics on assigner failure, which never happens in these tests.
fn stampIds(a: *ids.Assigner, exprs: []const *ast.Expression) void {
    for (exprs) |e| a.walkExpr(e) catch unreachable;
}

// The IR keys results by stamped expression id, so distinct exprs are recorded
// separately and an un-stamped expr reads back as absent.
test "TypedIr: records by expression identity and reads back" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var e1 = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var e2 = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{ &e1, &e2 });
    _ = try inf.inferExpr(&e1);
    _ = try inf.inferExpr(&e2);
    try testing.expectEqual(@as(usize, 2), ir.count());

    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e1).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e2).?);

    var never = ast.Expression{ .kind = .{ .literal = .{ .integer = 3 } } };
    stampIds(&idg, &.{&never});
    try testing.expect(ir.typeOf(&never) == null);
}

// Inference records every sub-expression it visits, not only the top node, so a
// binary's operands are individually typed in the IR.
test "TypedIr: sub-expressions are recorded too, not just the root" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var add = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .add, .span = sp } } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{&add});
    _ = try inf.inferExpr(&add);

    try testing.expectEqual(@as(usize, 3), ir.count());
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&l).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&add).?);
}

// [`TypedIr.unresolvedCount`] reports exactly how many recorded exprs remain
// unresolved: the coverage gap, distinct from the total count.
test "TypedIr: unresolvedCount is the honest coverage number" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var known = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var unknown = ast.Expression{ .kind = .{ .ident = "ghost" } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{ &known, &unknown });
    _ = try inf.inferExpr(&known);
    _ = try inf.inferExpr(&unknown);
    try testing.expectEqual(@as(usize, 2), ir.count());
    try testing.expectEqual(@as(usize, 1), ir.unresolvedCount(&f.store));
}

// [`TypedIr.record`] drops `.unassigned` ids (bumping `unassigned_rejected`)
// instead of letting every un-stamped expr collide on id 0.
test "TypedIr: refuses `.unassigned` rather than colliding every un-walked expr on id 0" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);

    var no_id = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var also_no_id = ast.Expression{ .kind = .{ .literal = .{ .string = "x" } } };
    try testing.expectEqual(ast.ExprId.unassigned, no_id.id);

    try ir.record(a, &no_id, try f.store.intT());
    try ir.record(a, &also_no_id, try f.store.stringT());

    try testing.expectEqual(@as(usize, 0), ir.count());
    try testing.expectEqual(@as(usize, 2), ir.unassigned_rejected);

    try testing.expect(ir.typeOf(&also_no_id) == null);
}

// Bitwise `&`/`|` produce the operand (int) type, while logical `&&`/`||`
// produce bool: the two families must not be conflated.
test "infer: bitwise `&`/`|` yield the OPERAND type, not bool" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 6 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 3 } } };

    var band = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .bit_and, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&band));

    var bor = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .bit_or, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&bor));

    var land = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .And, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&land));

    var lor = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .Or, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&lor));
}

// An assignment expression is typed as the assigned value's type (not void), so
// `x = 5` can be used in value position.
test "infer: assignment yields the assigned VALUE, not void" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };

    try inf.push();
    try inf.bind("x", try f.store.intT());
    var lhs = ast.Expression{ .kind = .{ .ident = "x" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .{ .integer = 5 } } };
    var asn = ast.Expression{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .assign, .span = sp } } };

    const t = try inf.inferExpr(&asn);
    try testing.expectEqual(try f.store.intT(), t);
    try testing.expect(t != try f.store.voidT());
}

/// Test helper: builds a one-declaration program containing a generic
/// `struct List<T>` with the given methods, used to exercise receiver-driven
/// type-parameter substitution in the F4 tests.
fn genericListProgram(sp: ast.Span, methods: []ast.MethodDecl) [1]ast.Declaration {
    return [_]ast.Declaration{.{ .struct_decl = .{
        .name = "List",
        .fields = &.{},
        .methods = methods,
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{"T"},
        .span = sp,
    } }};
}

// A generic method's return `T` is substituted from the RECEIVER's type args,
// so `List<string>.get()` is string and `List<int>.get()` is int.
test "F4: `List<string>.get()` is string, substitute T from the RECEIVER's args" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var methods = [_]ast.MethodDecl{.{
        .is_public = true,
        .is_static = false,
        .decl = .{
            .name = "get",
            .params = &.{},
            .ret_type = .{ .ident = "T" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .span = sp,
        },
    }};
    var decls = genericListProgram(sp, &methods);
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    const list_str = try f.low.lower(.{ .generic = .{ .name = "List", .params = &str_args } });
    var int_args = [_]ast.TypeRef{.{ .ident = "int" }};
    const list_int = try f.low.lower(.{ .generic = .{ .name = "List", .params = &int_args } });
    try testing.expect(list_str != list_int);

    try inf.push();
    try inf.bind("list", list_str);
    try inf.bind("nums", list_int);

    var obj_s = ast.Expression{ .kind = .{ .ident = "list" } };
    var fa_s = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_s, .field = "get", .span = sp } } };
    var call_s = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_s, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call_s));

    var obj_i = ast.Expression{ .kind = .{ .ident = "nums" } };
    var fa_i = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_i, .field = "get", .span = sp } } };
    var call_i = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_i, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call_i));
}

// A generic free-function call substitutes its EXPLICIT type args into the
// return type (`wrap<string>()` is string), even when the arg is unused.
test "F4: a generic FUNCTION call substitutes from its explicit type args" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var decls = [_]ast.Declaration{
        .{ .fn_decl = .{
            .name = "allocCopy",
            .params = &.{},
            .ret_type = .{ .ident = "int" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .type_params = &.{"T"},
            .span = sp,
        } },
        .{ .fn_decl = .{
            .name = "wrap",
            .params = &.{},
            .ret_type = .{ .ident = "T" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .type_params = &.{"T"},
            .span = sp,
        } },
    };
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    try inf.push();

    var ac_callee = ast.Expression{ .kind = .{ .ident = "allocCopy" } };
    var ac_targs = [_]ast.TypeRef{.{ .ident = "int" }};
    var ac = ast.Expression{ .kind = .{ .generic_call = .{
        .callee = &ac_callee,
        .type_args = &ac_targs,
        .args = &.{},
        .span = sp,
    } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&ac));

    var w_callee = ast.Expression{ .kind = .{ .ident = "wrap" } };
    var w_targs = [_]ast.TypeRef{.{ .ident = "string" }};
    var w = ast.Expression{ .kind = .{ .generic_call = .{
        .callee = &w_callee,
        .type_args = &w_targs,
        .args = &.{},
        .span = sp,
    } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&w));
}

// A generic struct's field type substitutes from the receiver's args too, so
// `Box<string>.v` reads as string.
test "F4: a generic struct's FIELD substitutes too, `Box<string>.v` is string" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var fields = [_]ast.Field{.{ .name = "v", .type_name = .{ .ident = "T" }, .is_public = true, .span = sp }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Box",
        .fields = &fields,
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{"T"},
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    const box_str = try f.low.lower(.{ .generic = .{ .name = "Box", .params = &str_args } });
    try inf.push();
    try inf.bind("b", box_str);

    var obj = ast.Expression{ .kind = .{ .ident = "b" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "v", .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&fa));
}

// A field whose type is a function can be CALLED: `(self.hashFn)(key)` types as
// the function's return, with the field's params substituted from the struct.
test "F4: calling a field that HOLDS a function, `(self.hashFn)(key)`" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    const k_ref = ast.TypeRef{ .ident = "K" };
    var int_ref = ast.TypeRef{ .ident = "int" };
    var k_params = [_]ast.TypeRef{k_ref};
    var fields = [_]ast.Field{.{
        .name = "hashFn",
        .type_name = .{ .func = .{ .params = &k_params, .ret = &int_ref } },
        .is_public = true,
        .span = sp,
    }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Map",
        .fields = &fields,
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{ "K", "V" },
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var args = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const map_si = try f.low.lower(.{ .generic = .{ .name = "Map", .params = &args } });
    try inf.push();
    try inf.bind("self", map_si);

    var obj = ast.Expression{ .kind = .{ .ident = "self" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "hashFn", .span = sp } } };
    const ft = try inf.inferExpr(&fa);
    try testing.expect(f.store.get(ft) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(ft).func.ret);
    try testing.expectEqual(try f.store.stringT(), f.store.get(ft).func.params[0]);

    const key = ast.Expression{ .kind = .{ .ident = "key" } };
    var call_args = [_]ast.Expression{key};
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &call_args, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call));
}

// `if (s != undefined)` narrows `s` from optional to present INSIDE the branch
// (so `s.length` types), and it reverts to optional afterwards.
test "F2: `if (s != undefined)` narrows s inside the branch (specs.md 3.4a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    const str = try f.store.stringT();
    const opt_str = try f.store.intern(.{ .optional = str });
    try inf.push();
    try inf.bind("s", opt_str);

    var lhs = ast.Expression{ .kind = .{ .ident = "s" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .undefined } };
    var o2 = ast.Expression{ .kind = .{ .ident = "s" } };
    const len_in = ast.Expression{ .kind = .{ .field_access = .{ .object = &o2, .field = "length", .span = sp } } };
    var then_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = len_in, .span = sp } }};
    var then_blk = ast.Statement{ .block = .{ .statements = &then_stmts, .span = sp } };
    var if_stmt = ast.Statement{ .if_stmt = .{
        .condition = .{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .ne, .span = sp } } },
        .then_branch = &then_blk,
        .else_branch = null,
        .span = sp,
    } };
    var idg = ids.Assigner.init();
    try idg.walkStmt(&if_stmt);
    try inf.inferStmt(&if_stmt);

    const inner = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    try testing.expectEqual(try f.store.intT(), ir.typeOf(inner).?);

    var o3 = ast.Expression{ .kind = .{ .ident = "s" } };
    var after = ast.Expression{ .kind = .{ .field_access = .{ .object = &o3, .field = "length", .span = sp } } };
    try idg.walkExpr(&after);
    try testing.expect(f.store.get(try inf.inferExpr(&after)) == .unresolved);
}

// The `==` form narrows the ELSE branch instead: the value is present where the
// equality check failed, mirroring [`Narrowing.when_true`].
test "F2: `if (s == undefined)` narrows the ELSE branch (specs.md 3.4a)" {
    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    const str = try f.store.stringT();
    try inf.push();
    try inf.bind("s", try f.store.intern(.{ .optional = str }));

    var lhs = ast.Expression{ .kind = .{ .ident = "s" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .undefined } };
    var o_then = ast.Expression{ .kind = .{ .ident = "s" } };
    const in_then = ast.Expression{ .kind = .{ .field_access = .{ .object = &o_then, .field = "length", .span = sp } } };
    var then_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = in_then, .span = sp } }};
    var then_blk = ast.Statement{ .block = .{ .statements = &then_stmts, .span = sp } };

    var o_else = ast.Expression{ .kind = .{ .ident = "s" } };
    const in_else = ast.Expression{ .kind = .{ .field_access = .{ .object = &o_else, .field = "length", .span = sp } } };
    var else_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = in_else, .span = sp } }};
    var else_blk = ast.Statement{ .block = .{ .statements = &else_stmts, .span = sp } };

    var if_stmt = ast.Statement{ .if_stmt = .{
        .condition = .{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .eq, .span = sp } } },
        .then_branch = &then_blk,
        .else_branch = &else_blk,
        .span = sp,
    } };
    var idg = ids.Assigner.init();
    try idg.walkStmt(&if_stmt);
    try inf.inferStmt(&if_stmt);

    const then_e = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    const else_e = &if_stmt.if_stmt.else_branch.?.block.statements[0].expr_stmt.expr;
    try testing.expect(f.store.get(ir.typeOf(then_e).?) == .unresolved);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(else_e).?);
}

// Only a plain identifier narrows; `obj.field != undefined` does not, since
// narrowing rebinds a name and a field has no binding to rewrite.
test "F2: only a plain BINDING narrows, a field does not (specs.md 3.4a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    try inf.push();
    try inf.bind("s", try f.store.intern(.{ .optional = try f.store.stringT() }));

    var obj = ast.Expression{ .kind = .{ .ident = "s" } };
    var fld = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "inner", .span = sp } } };
    var undef = ast.Expression{ .kind = .{ .literal = .undefined } };
    const cond = ast.BinaryExpr{ .left = &fld, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(cond) == null);

    var id = ast.Expression{ .kind = .{ .ident = "s" } };
    const ok_cond = ast.BinaryExpr{ .left = &id, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(ok_cond) != null);
    try testing.expectEqualStrings("s", narrowedBinding(ok_cond).?.name);
    try testing.expect(narrowedBinding(ok_cond).?.when_true);
}

// A closure passed to a method gets its param types from the EXPECTED function
// type, so `m.forEach((k, v) => k)` types `k` as the map's key type.
test "F2: a closure's params come from the EXPECTED type (specs.md 6.3a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    const k_ref = ast.TypeRef{ .ident = "K" };
    const v_ref = ast.TypeRef{ .ident = "V" };
    var void_ref = ast.TypeRef{ .ident = "void" };
    var kv = [_]ast.TypeRef{ k_ref, v_ref };
    var params = [_]ast.Param{.{
        .name = "fn",
        .type_name = .{ .func = .{ .params = &kv, .ret = &void_ref } },
        .span = sp,
    }};
    var methods = [_]ast.MethodDecl{.{
        .is_public = true,
        .is_static = false,
        .decl = .{
            .name = "forEach",
            .params = &params,
            .ret_type = .{ .ident = "void" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .span = sp,
        },
    }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Map",
        .fields = &.{},
        .methods = &methods,
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{ "K", "V" },
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var targs = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const map_si = try f.low.lower(.{ .generic = .{ .name = "Map", .params = &targs } });
    try inf.push();
    try inf.bind("m", map_si);

    var body_k = ast.Expression{ .kind = .{ .ident = "k" } };
    var clo_params = [_][]const u8{ "k", "v" };
    const closure = ast.Expression{ .kind = .{ .closure = .{
        .params = &clo_params,
        .body = .{ .expr = &body_k },
        .span = sp,
    } } };
    var recv = ast.Expression{ .kind = .{ .ident = "m" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "forEach", .span = sp } } };
    var args = [_]ast.Expression{closure};

    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &args, .span = sp } } };

    var idg = ids.Assigner.init();
    try idg.walkExpr(&call);
    _ = try inf.inferExpr(&call);

    const inner = args[0].kind.closure.body.expr;
    try testing.expectEqual(try f.store.stringT(), ir.typeOf(inner).?);
}

// A method call on a trait-object receiver resolves to the trait method's
// declared return type, and an unknown method stays unresolved.
test "F2: a method call on a TRAIT receiver resolves (`src.getString(k)`)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var tm = [_]ast.TraitMethodDecl{
        .{ .name = "getString", .params = &.{}, .ret_type = .{ .ident = "string" }, .span = sp },
        .{ .name = "arrayLen", .params = &.{}, .ret_type = .{ .ident = "int" }, .span = sp },
        .{ .name = "close", .params = &.{}, .ret_type = null, .span = sp },
    };
    var decls = [_]ast.Declaration{.{ .trait_decl = .{
        .name = "ValueSource",
        .methods = &tm,
        .is_public = true,
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    const vs = try f.low.lower(.{ .ident = "ValueSource" });
    try testing.expect(f.store.get(vs) == .trait_);
    try inf.push();
    try inf.bind("src", vs);

    var recv = ast.Expression{ .kind = .{ .ident = "src" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "getString", .span = sp } } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call));

    var fa2 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "arrayLen", .span = sp } } };
    var call2 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa2, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call2));

    var fa3 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "close", .span = sp } } };
    var call3 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa3, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.voidT(), try inf.inferExpr(&call3));

    var fa4 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "nosuch", .span = sp } } };
    var call4 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa4, .args = &.{}, .span = sp } } };
    try testing.expect(f.store.get(try inf.inferExpr(&call4)) == .unresolved);
}

// `go f()` yields `future<T>` and `await` unwraps it back to `T`; the two are
// distinct types so a future is never mistaken for its result.
test "F2: `go` yields future<T> and `await` unwraps it (specs.md 7.1)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var decls = [_]ast.Declaration{.{ .fn_decl = .{
        .name = "square",
        .params = &.{},
        .ret_type = .{ .ident = "int" },
        .body = .{ .statements = &.{}, .span = sp },
        .is_exported = false,
        .attributes = &.{},
        .is_async = true,
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    try inf.push();

    var callee = ast.Expression{ .kind = .{ .ident = "square" } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &callee, .args = &.{}, .span = sp } } };
    var aw_call = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &call, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_call));

    var go_e = ast.Expression{ .kind = .{ .go_expr = .{ .operand = &call, .span = sp } } };
    const h = try inf.inferExpr(&go_e);
    try testing.expect(f.store.get(h) == .future);
    try testing.expectEqual(try f.store.intT(), f.store.get(h).future);
    try testing.expect(h != try f.store.intT());

    try inf.bind("h", h);
    var h_id = ast.Expression{ .kind = .{ .ident = "h" } };
    var aw_h = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &h_id, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_h));

    const fut_str = try f.store.intern(.{ .future = try f.store.stringT() });
    try testing.expect(fut_str != h);
}

// With no expected type, a closure param is inferred from its USE in the body:
// `(x) => x + 1` types `x` as int via [`Inferer.paramFromUse`].
test "F2: a closure param is inferred from its USE in the body (specs.md 6.3a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;
    try inf.push();

    var xi = ast.Expression{ .kind = .{ .ident = "x" } };
    var one = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var body = ast.Expression{ .kind = .{ .binary = .{ .left = &xi, .right = &one, .op = .add, .span = sp } } };
    var params = [_][]const u8{"x"};
    var clo = ast.Expression{ .kind = .{ .closure = .{ .params = &params, .body = .{ .expr = &body }, .span = sp } } };
    var idg = ids.Assigner.init();
    try idg.walkExpr(&clo);
    const t = try inf.inferExpr(&clo);

    try testing.expectEqual(try f.store.intT(), ir.typeOf(&xi).?);

    try testing.expect(f.store.get(t) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.params[0]);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.ret);
}

// `(a, b) => a + b` with neither param constrained stays unresolved rather than
// guessing: documents the deliberate limit of use-based inference.
test "F2: `(a, b) => a + b` stays unresolved, the limit, not a guess" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;
    try inf.push();

    var ai = ast.Expression{ .kind = .{ .ident = "a" } };
    var bi = ast.Expression{ .kind = .{ .ident = "b" } };
    var body = ast.Expression{ .kind = .{ .binary = .{ .left = &ai, .right = &bi, .op = .add, .span = sp } } };
    var params = [_][]const u8{ "a", "b" };
    var clo = ast.Expression{ .kind = .{ .closure = .{ .params = &params, .body = .{ .expr = &body }, .span = sp } } };
    var idg = ids.Assigner.init();
    try idg.walkExpr(&clo);
    _ = try inf.inferExpr(&clo);
    try testing.expect(f.store.get(ir.typeOf(&ai).?) == .unresolved);
    try testing.expect(f.store.get(ir.typeOf(&bi).?) == .unresolved);
}
