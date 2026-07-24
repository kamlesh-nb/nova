// infer.zig — F2 stage 2c: give every EXPRESSION a type.
//
// This is the half of F2 that matters. Stage 2a/2b typed the DECLARED surface
// (563/563 on ycsb); this types the expressions, which is what `isRefCountedType`
// and every instruction-selection decision actually need.
//
// It is deliberately a SEPARATE engine from the two that exist, both of which are
// wrong in ways that matter:
//
//   type_checker.zig:498  resolveExprType         -> ?ast.TypeRef, then FREED at
//                         deinit. Structurally cannot annotate: check() takes
//                         ast.Program BY VALUE.
//   codegen/types.zig:176 resolveExpressionTypeName -> ?[]const u8, recomputed at
//                         every use site, and falls back to the STRING "i32".
//
// That last one is the disease. `i32` IS the universal machine word, so a failed
// inference is indistinguishable from a correct one:
//
//     types.zig:201  integer literal            -> "i32"
//     types.zig:457  binary, both sides unknown -> "i32"      <-- a WRONG answer
//     types.zig:477  .block_expr                -> "string"   <-- unconditionally
//     expressions.zig:1742 unresolved field     -> i32, then loads 8 bytes at a
//                                                  GUESSED offset
//
// Here, not knowing is `.unresolved` — a real, distinct type. That is why the
// numbers this file reports are meaningful at all: you cannot count what you
// cannot distinguish.
//
// STAGE 2c IS SHADOW MODE. Nothing consumes it. It reports how much of a real
// program's expression surface F2 can type today, which is the input that decides
// stage 4's cutover — the same way 2a's 85% and 2b's 100% decided 2b.
const std = @import("std");
const ast = @import("../ast.zig");
const ids = @import("ids.zig");
const subst = @import("subst.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const lower = @import("lower.zig");
const builtins = @import("builtins.zig");
const mono = @import("mono.zig");

pub const TypeId = types.TypeId;

pub const Stats = struct {
    typed: usize = 0,
    unresolved: usize = 0,
    /// F2-6 stage 0: of the `unresolved` count, how many are NOT-A-VALUE references — a bare module /
    /// magic-builtin / container-type / extern ident (`console`, `assert`, `Storage`), or a
    /// `field_access` ON such a receiver (`console.log`). These are CORRECTLY untyped-as-a-value; a
    /// complete typed IR marks them `namespace`, it does not "type" them. `genuine = unresolved -
    /// namespace` is the real coverage debt F2-6 stage 1 must close. Split by the two shapes that can
    /// be namespace (ident / field_access) so the report can subtract them from `by_tag` and show the
    /// GENUINE shapes only. Measurement only.
    unresolved_ns_ident: usize = 0,
    unresolved_ns_field: usize = 0,
    /// Which expression SHAPES could not be typed, by AST tag. This is the
    /// actionable output: it names the next increment instead of guessing at it.
    by_tag: std.StringHashMapUnmanaged(usize) = .empty,
    /// The actual NAMES behind the failures ("ident:foo", "call:math.fpowf").
    /// A tag says which shape; this says which symbol — the difference between
    /// "93 calls fail" and "these 4 receivers fail".
    by_name: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.by_tag.deinit(allocator);
        self.by_name.deinit(allocator);
    }
};

const Binding = struct { name: []const u8, ty: TypeId, is_const: bool = false };

/// F2 stage 2i: the typed IR. Every expression's type, recorded ONCE, for codegen
/// to READ instead of re-deriving at each use site.
///
/// Keyed by the expression's ADDRESS, not by an `ExprId` on the AST node. The
/// design (§6 Q1) recommended adding ExprId — touching ast.zig and the parser —
/// but that is unnecessary: expressions live in parser-allocated memory reached
/// through `*Expression` / `[]Expression` that is never copied (only top-level
/// Declaration structs are, and program.declarations is a finalized slice before
/// sema runs). So identity is already available for free.
///
/// The tradeoff, honestly: an ExprId survives an AST copy and prints in a debugger;
/// an address does neither. If the AST ever gets copied or re-allocated after sema,
/// this breaks SILENTLY — the lookup would just miss. Guarded by `assertStable`
/// below and revisited at the stage-4 cutover, where correctness stops being
/// optional.
/// The ownership operation the pass assigns to an owned temporary occurrence (arc.md §1.4).
pub const OwnOp = enum { move, drop };

/// F4: key for the per-instantiation disposition — an expression occurrence, seen inside one concrete
/// instantiation of its enclosing generic type.
pub const InstKey = struct { id: ast.ExprId, inst: TypeId };

/// F4: key for resolving a bare type-param against an instantiation.
pub const TpKey = struct { tp: TypeId, inst: TypeId };

pub const TypedIr = struct {
    /// Keyed on ExprId, NOT on the node's address (stage 4a).
    ///
    /// Codegen takes Expression BY VALUE, so it always holds a copy at a fresh
    /// address; an address key misses every time, which is exactly why stage 3's
    /// absences plateaued at 1113. An id travels with the copy.
    expr_types: std.AutoHashMapUnmanaged(ast.ExprId, TypeId) = .empty,

    /// F1 stage 3b groundwork: the resolved SYMBOL for a CALL expression — F1's answer,
    /// recorded, so codegen can resolve a call via `SymbolId` instead of the 227-line
    /// func_map SUFFIX SCAN (`resolveCalleeName`, codegen/types.zig). Keyed on the CALL's
    /// ExprId. Populated where sema resolves the callee unambiguously; a call sema cannot
    /// resolve simply has no entry (codegen keeps its scan meanwhile — additive cutover, the
    /// same discipline as F2's `expr_types`). Nothing reads this yet; the shadow reports the
    /// coverage so the number can be driven up before the scan is deleted.
    expr_syms: std.AutoHashMapUnmanaged(ast.ExprId, types.SymbolId) = .empty,

    /// F4-5 method-level monomorphization (Phase 1): the resolved METHOD type-arguments for a
    /// generic-method call — `xs.map<U>(f)` with U solved to `string` records `[string]`, keyed by
    /// the CALL's ExprId. Recorded ONLY when every method param solved to a CONCRETE type (an
    /// abstract residue means no instantiation to emit). This is what lets codegen emit
    /// `List_i32_map_string` (U=string) instead of the erased `List_map` whose `result.push` binds
    /// the unsound erased `List_push`. See docs/design/F4-method-monomorphization.md. Owned slices.
    expr_method_args: std.AutoHashMapUnmanaged(ast.ExprId, []const TypeId) = .empty,

    /// F2-6 stage 5 (balance-check step 1): the ownership DISPOSITION of each expression occurrence —
    /// true = `owned` (a fresh +1 the statement drain must consume), false = `borrowed` (names an
    /// existing owner, or trivial). The checker computes it here so it can eventually OWN the ownership
    /// decision (today codegen's `acquisitionDisposition` computes it); a `--shadow` diff proves the two
    /// agree before any cutover. It is the value-level input the dup/drop-insertion + linear balance
    /// check (arc.md §5/§6.1) will run on. Recorded, read only by the shadow diff for now.
    expr_owned: std.AutoHashMapUnmanaged(ast.ExprId, bool) = .empty,

    /// F2-6 stage 5 step 5 (codegen cutover, shadow half): the ownership OP the pass assigned to each
    /// owned TEMPORARY occurrence — `move` (its +1 transfers into a bind/return/aggregate) or `drop`
    /// (released at the enclosing statement's end). Keyed by ExprId so codegen can look it up at the
    /// EXACT site it acts (`drainTemporaries` = a drop, `consumeTemporary` = a move) and shadow-diff its
    /// own decision against the pass. Agreement at the drop site is what greenlights flipping codegen to
    /// obey this map (delete the `pending_temps` heuristic). Recorded by `ownership.zig`.
    expr_op: std.AutoHashMapUnmanaged(ast.ExprId, OwnOp) = .empty,

    /// F4 erased-body elimination: the ownership disposition of an expression occurrence AS SEEN IN A
    /// SPECIFIC INSTANTIATION of its enclosing generic type. Keyed by (ExprId, instantiation struct
    /// TypeId). This is what makes the checker instantiation-AWARE: `self.data.get(i)` in `List<T>.get`
    /// is `.type_param` (borrowed) in the erased body, but `string` (owned) in the `List<string>`
    /// instantiation — codegen compiles the latter and must read the CONCRETE disposition from here
    /// instead of re-deriving it with the `keystoneSubst` side-channel. Populated by a per-instantiation
    /// pass (inst_disp.zig) that substitutes the recorded erased type against each instantiation's args.
    expr_owned_inst: std.AutoHashMapUnmanaged(InstKey, bool) = .empty,

    /// F4: the CONCRETE type of an expression occurrence in a specific instantiation — the erased type
    /// with the generic's params substituted against the instantiation's args. Lets codegen read the
    /// concrete type from the IR in a monomorphized body instead of computing the substitution itself
    /// (`keystoneSubst`). Same key as `expr_owned_inst`, populated by the same pass (inst_disp.zig).
    expr_types_inst: std.AutoHashMapUnmanaged(InstKey, TypeId) = .empty,

    /// F4 keystoneSubst removal: resolve a bare `.type_param` against an instantiation, precomputed by
    /// sema so codegen READS it instead of substituting. `(type_param{owner,i}, List<string>) -> string`.
    /// This is the field-level counterpart of `expr_types_inst` — a struct field (e.g. the destructor's
    /// `Storage<T>` element) is not an expression, so it has no ExprId; it is resolved by (its
    /// type_param, the instantiation) directly. Populated by inst_disp.zig, read by `isOwnedTypeId`.
    tp_resolve: std.AutoHashMapUnmanaged(TpKey, TypeId) = .empty,

    /// Expressions offered to the IR with no id. MUST stay 0 — `.unassigned` is
    /// zero, so admitting them would collide every un-walked expression onto one
    /// bucket and hand them each other's types, silently. Refusing them instead
    /// turns a sema/ids.zig walk miss into a visible absence.
    unassigned_rejected: usize = 0,

    pub fn deinit(self: *TypedIr, allocator: std.mem.Allocator) void {
        self.expr_types.deinit(allocator);
        self.expr_syms.deinit(allocator);
        var mit = self.expr_method_args.valueIterator();
        while (mit.next()) |v| allocator.free(v.*);
        self.expr_method_args.deinit(allocator);
        self.expr_owned.deinit(allocator);
        self.expr_op.deinit(allocator);
        self.expr_owned_inst.deinit(allocator);
        self.expr_types_inst.deinit(allocator);
        self.tp_resolve.deinit(allocator);
    }

    /// F4: record the disposition of `id` as seen inside instantiation `inst`.
    pub fn recordOwnedInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, owned: bool) !void {
        if (id == .unassigned) return;
        try self.expr_owned_inst.put(allocator, .{ .id = id, .inst = inst }, owned);
    }

    /// F4: the disposition of `id` inside instantiation `inst`, or null if none recorded (not in a
    /// generic body, or the type did not substitute).
    pub fn ownedOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?bool {
        if (id == .unassigned) return null;
        return self.expr_owned_inst.get(.{ .id = id, .inst = inst });
    }

    /// F4: record the concrete type of `id` inside instantiation `inst`.
    pub fn recordTypeInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, t: TypeId) !void {
        if (id == .unassigned) return;
        try self.expr_types_inst.put(allocator, .{ .id = id, .inst = inst }, t);
    }

    /// F4: the concrete type of `id` inside instantiation `inst`, or null if none recorded.
    pub fn typeOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types_inst.get(.{ .id = id, .inst = inst });
    }

    /// F4: record `tp` resolves to `concrete` under instantiation `inst`.
    pub fn recordTpResolve(self: *TypedIr, allocator: std.mem.Allocator, tp: TypeId, inst: TypeId, concrete: TypeId) !void {
        try self.tp_resolve.put(allocator, .{ .tp = tp, .inst = inst }, concrete);
    }

    /// F4: what does bare type-param `tp` resolve to under instantiation `inst`? null when `tp` is not
    /// a parameter of `inst`'s type (e.g. a method-level param) — the same "does not resolve" the old
    /// keystoneSubst returned.
    pub fn tpResolve(self: *const TypedIr, tp: TypeId, inst: TypeId) ?TypeId {
        return self.tp_resolve.get(.{ .tp = tp, .inst = inst });
    }

    /// F2-6 stage 5 step 5: record the ownership op the pass assigned to an owned temp occurrence.
    pub fn recordOp(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, op: OwnOp) !void {
        if (e.id == .unassigned) return;
        try self.expr_op.put(allocator, e.id, op);
    }

    /// F2-6 stage 5 step 5: the pass's op for the temp born at `id`, or null if none was recorded
    /// (not an owned temp, or an unassigned/explicitly-registered temp the pass never saw).
    pub fn opOf(self: *const TypedIr, id: ast.ExprId) ?OwnOp {
        if (id == .unassigned) return null;
        return self.expr_op.get(id);
    }

    /// The recorded TypeId for the occurrence at `id` (ExprId-keyed), for diagnostics that hold an id
    /// rather than the node (e.g. codegen's temp-op diff).
    pub fn typeOf2(self: *const TypedIr, id: ast.ExprId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types.get(id);
    }

    /// F2-6 stage 5: record an expression's ownership disposition (true = owned producer).
    pub fn recordOwned(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, owned: bool) !void {
        if (e.id == .unassigned) return;
        try self.expr_owned.put(allocator, e.id, owned);
    }

    /// F2-6 stage 5: the recorded ownership disposition, or null (not recorded).
    pub fn ownedOf(self: *const TypedIr, e: *const ast.Expression) ?bool {
        if (e.id == .unassigned) return null;
        return self.expr_owned.get(e.id);
    }

    /// F2-6 stage 5 step 4: how many recorded occurrences are OWNED producer temps (disposition ==
    /// owned). The denominator for the ownership pass's temp-accounting completeness — it counts every
    /// owned occurrence the checker saw, closure interiors included, so the pass's shortfall against it
    /// is exactly the (known) not-yet-descended set.
    pub fn ownedTrueCount(self: *const TypedIr) usize {
        var n: usize = 0;
        var it = self.expr_owned.valueIterator();
        while (it.next()) |v| {
            if (v.*) n += 1;
        }
        return n;
    }

    /// F4-5: record a generic-method call's resolved concrete method type-args. Dupes the slice
    /// (the caller's `solved` buffer is transient); the IR owns the copy and frees it in deinit.
    pub fn recordMethodArgs(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, args: []const TypeId) !void {
        if (e.id == .unassigned) return;
        if (self.expr_method_args.get(e.id)) |old| allocator.free(old);
        const dup = try allocator.dupe(TypeId, args);
        try self.expr_method_args.put(allocator, e.id, dup);
    }

    /// F4-5: the resolved concrete method type-args for a call, or null (not a monomorphizable
    /// generic-method call).
    pub fn methodArgsOf(self: *const TypedIr, e: *const ast.Expression) ?[]const TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_method_args.get(e.id);
    }

    /// F1-3b: record the CALL expression `e`'s resolved callee SymbolId.
    pub fn recordSym(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, sid: types.SymbolId) !void {
        if (e.id == .unassigned) return;
        try self.expr_syms.put(allocator, e.id, sid);
    }

    /// F1-3b: the resolved callee SymbolId for a call, or null when sema could not resolve it
    /// (codegen falls back to its scan — behaviour-preserving until the cutover).
    pub fn symOf(self: *const TypedIr, e: *const ast.Expression) ?types.SymbolId {
        if (e.id == .unassigned) return null;
        return self.expr_syms.get(e.id);
    }

    pub fn record(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, t: TypeId) !void {
        if (e.id == .unassigned) {
            self.unassigned_rejected += 1;
            return;
        }
        try self.expr_types.put(allocator, e.id, t);
    }

    /// The whole point: codegen asks instead of inferring.
    pub fn typeOf(self: *const TypedIr, e: *const ast.Expression) ?TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_types.get(e.id);
    }

    pub fn count(self: *const TypedIr) usize {
        return self.expr_types.count();
    }

    /// How many recorded expressions are `.unresolved`. THIS is the honest
    /// coverage number: `stats.typed`/`unresolved` are event counters with manual
    /// adjustments (fieldType re-infers an object and decrements), so they
    /// over/under-count re-visits. The IR is a SET keyed by identity — each
    /// expression appears once, whatever the walk did.
    pub fn unresolvedCount(self: *const TypedIr, store: *const types.TypeStore) usize {
        var n: usize = 0;
        var it = self.expr_types.valueIterator();
        while (it.next()) |t| {
            if (store.get(t.*) == .unresolved) n += 1;
        }
        return n;
    }
};

/// A binding that a condition narrows, and in which branch (specs.md 3.4a).
const Narrowing = struct {
    name: []const u8,
    /// true  => `x != undefined`, narrowed when the condition HOLDS (then-branch)
    /// false => `x == undefined`, narrowed when it does NOT (else-branch)
    when_true: bool,
};

/// Does `cond` narrow a binding? `x != undefined` / `x == undefined`, either way
/// round (`undefined != x` reads badly but means the same).
///
/// Only a PLAIN BINDING narrows. `a.b != undefined` does not: nothing stops the
/// field changing between the test and the use, so a narrowed type would be a lie
/// the type system told itself. Same for a call — `get() != undefined` tests a
/// DIFFERENT value than the next `get()` returns.
fn narrowedBinding(cond: ast.BinaryExpr) ?Narrowing {
    const when_true = switch (cond.op) {
        .ne => true,
        .eq => false,
        else => return null,
    };
    const l_undef = cond.left.kind == .literal and cond.left.kind.literal == .undefined;
    const r_undef = cond.right.kind == .literal and cond.right.kind.literal == .undefined;
    // Exactly one side must be `undefined`; `undefined != undefined` narrows nothing.
    if (l_undef == r_undef) return null;
    const other = if (l_undef) cond.right else cond.left;
    if (other.kind != .ident) return null; // a field or call never narrows
    return .{ .name = other.kind.ident, .when_true = when_true };
}

/// Does control-flow definitely NOT fall out of the bottom of `s`? (a `return`/`break`/
/// `continue`, or a block whose last statement is one). Used for early-exit narrowing:
/// only when the non-narrowed branch is unreachable can the rest of the block assume the
/// narrowed type.
fn branchTerminates(s: *const ast.Statement) bool {
    return switch (s.*) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        .block => |b| b.statements.len > 0 and branchTerminates(&b.statements[b.statements.len - 1]),
        else => false,
    };
}

/// If `s` is a guard `if (x == undefined) { <terminating> }` (or the `!=` + terminating-else
/// mirror), return the binding narrowed FOR THE REST OF THE BLOCK — the branch that would
/// leave `x` still-optional cannot fall through, so afterwards `x` is `T`.
fn earlyExitNarrowing(s: *const ast.Statement) ?Narrowing {
    if (s.* != .if_stmt) return null;
    const i = s.if_stmt;
    if (i.condition.kind != .binary) return null;
    const n = narrowedBinding(i.condition.kind.binary) orelse return null;
    if (n.when_true) {
        // Narrowed when the cond HOLDS (`x != undefined`) — need the ELSE branch (x absent)
        // to terminate so the fall-through world has x present.
        const e = i.else_branch orelse return null;
        if (!branchTerminates(e)) return null;
    } else {
        // Narrowed when the cond FAILS (`x == undefined`) — the THEN branch (x absent) must
        // terminate. An else, if present, would also continue; require none for soundness.
        if (i.else_branch != null) return null;
        if (!branchTerminates(i.then_branch)) return null;
    }
    return n;
}

/// F1-4: one recorded cross-module access to a non-pub symbol (`mod.field` where `field` is private).
/// What kind of symbol a cross-module visibility violation names — drives the diagnostic wording.
pub const VisKind = enum { function, type_, const_ };

pub const VisError = struct {
    span: ast.Span,
    recv: []const u8,
    field: []const u8,
    /// F1-4 (types): a cross-module reference to a non-pub TYPE (`.type_`) vs the original non-pub
    /// FUNCTION call (`.function`). Defaults to `.function` so the existing recorder is unchanged.
    kind: VisKind = .function,
};

/// A reassignment of a `const` binding — `const x = 5; x = 6;`. Recorded with the assignment's
/// span so shadow.run raises a located diagnostic and rejects (like VisError). `const` is the
/// enforced-immutable half of the two-keyword model (`let` = mutable, `const` = constant).
pub const ConstReassignError = struct {
    span: ast.Span,
    name: []const u8,
};

/// H2: an unguarded member access on a value that may not be a plain `T` — either
/// `T | undefined` (optional, `.opt`) or `T | E` (error union, `.err`). Both are hard
/// errors (specs §3.4): the value must be made a `T` first (at/??/?./narrow, or try/catch).
pub const OptDerefKind = enum { opt, err };
pub const OptDerefError = struct {
    span: ast.Span,
    field: []const u8,
    is_method: bool,
    kind: OptDerefKind = .opt,
};

pub const Inferer = struct {
    allocator: std.mem.Allocator,
    store: *types.TypeStore,
    symtab: *const symbols.SymbolTable,
    lowerer: *lower.Lowerer,
    /// Lexical scope. F1's alpha-renaming pass has already made every binding name
    /// unique per function (§10 #23), so a flat list per function is sound here —
    /// but it is a STACK anyway, because relying on that invariant silently is how
    /// the last one got missed.
    scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    const_depth: usize = 0,
    /// The enclosing function's DECLARED return type, when it has one.
    ///
    /// `fn make_greeter(name: string): (int) => string { return (x) => ...; }`
    /// (06_closures_advanced:10) — `x` is never used in the body, so nothing pins
    /// it, and contextual typing only reached call ARGUMENTS. The expected type was
    /// right there in the signature the whole time.
    current_ret: ?TypeId = null,
    /// F1-4: the module whose function body is being inferred, so a bare `list.foo()` resolves `list`
    /// against what THIS module imported (resolveImportedModule) rather than a global segment scan.
    /// Saved/restored around each function walk, like current_ret.
    current_module: ?symbols.ModuleId = null,
    /// F1-4 visibility enforcement: a cross-module reference to a NON-pub symbol, recorded with the
    /// call's span so shadow.run can raise a located diagnostic and abort. Empty on a clean program
    /// (measured: 0 across the corpus once `pub fn` was honored).
    visibility_errors: std.ArrayListUnmanaged(VisError) = .empty,
    /// Reassignments of `const` bindings — a hard error at end of sema (the `const`-is-immutable
    /// half of the two-keyword model). Empty on a clean program.
    const_reassign_errors: std.ArrayListUnmanaged(ConstReassignError) = .empty,
    /// H2: unguarded `optional.field` / `optional.method()` accesses — a hard error at end of sema.
    /// Empty on a clean program (the stdlib + corpus were migrated to `at()`/`?.`/`??`/narrowing).
    optional_deref_errors: std.ArrayListUnmanaged(OptDerefError) = .empty,
    /// F2-5 fatal (shadow): count of GENUINELY undefined bare idents (not a value/type/extern/namespace).
    /// Must be 0 on a clean program; the end-of-sema fatal turns a non-zero into an error.
    fatal_unresolved_idents: usize = 0,
    /// F2-5: the first genuinely-undefined ident (for the end-of-sema diagnostic).
    first_fatal_ident: ?[]const u8 = null,
    /// The type of the most recent `return <value>` seen while walking a block, captured DURING
    /// the walk (so the returned expr's locals are still in scope). Read right after inferBlock to
    /// give a braced closure its real return type. See blockReturnType's removed re-inference.
    captured_return: ?TypeId = null,
    /// F2-6 stage 1: true only while inferring a call's DIRECT callee. A `field_access` callee
    /// (`xs.push`) is a METHOD REFERENCE — not a first-class value (Nova has no bound-method values;
    /// it is only ever called) — so an unresolved one is not-a-value, not a coverage gap. Cleared on
    /// entry to `field_access` so a nested RECEIVER (`a.b` in `a.b.c()`) is still judged as a value.
    in_call_callee: bool = false,
    /// When set, every expression's type is recorded. Stage 2i.
    ir: ?*TypedIr = null,
    stats: Stats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        store: *types.TypeStore,
        symtab: *const symbols.SymbolTable,
        lowerer: *lower.Lowerer,
    ) Inferer {
        return .{ .allocator = allocator, .store = store, .symtab = symtab, .lowerer = lowerer };
    }

    pub fn deinit(self: *Inferer) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.stats.deinit(self.allocator);
        self.visibility_errors.deinit(self.allocator);
        self.const_reassign_errors.deinit(self.allocator);
        self.optional_deref_errors.deinit(self.allocator);
    }

    fn push(self: *Inferer) !void {
        try self.scopes.append(self.allocator, .empty);
    }
    fn pop(self: *Inferer) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }
    fn bind(self: *Inferer, name: []const u8, ty: TypeId) !void {
        try self.bindC(name, ty, false);
    }
    /// Bind with an explicit mutability. `const` bindings (bindC(.., true)) reject reassignment;
    /// every other binder (params, `let`, closure params, switch payloads) is mutable.
    fn bindC(self: *Inferer, name: []const u8, ty: TypeId, is_const: bool) !void {
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(self.allocator, .{ .name = name, .ty = ty, .is_const = is_const });
    }
    /// Is `name` bound as a `const` in the nearest enclosing scope? (rebind preserves is_const,
    /// so a type refinement never silently makes a const mutable.)
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
    /// Replace an EXISTING binding's type in place.
    ///
    /// Not `bind`: that appends, and `lookup` returns the FIRST match in a scope, so
    /// an appended second binding for the same name is never seen. (That also means
    /// intra-scope shadowing quietly does not work — alpha-renaming makes names
    /// unique per function, which is the only reason it does not bite.)
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

    fn unresolved(self: *Inferer, tag: []const u8) !TypeId {
        self.stats.unresolved += 1;
        const gop = try self.stats.by_tag.getOrPut(self.allocator, tag);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        return self.store.unresolvedT();
    }

    fn note(self: *Inferer, name: []const u8) !void {
        const gop = try self.stats.by_name.getOrPut(self.allocator, name);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    /// C2: the least-upper-bound of two struct types — the SINGLE trait both implement. Used to type an
    /// unannotated heterogeneous if-expr (`let o = if (c) A{} else B{}`, A,B: G) as `G` so the struct
    /// branches widen instead of a raw struct reaching a trait slot (SEGV). Returns null when the two are
    /// not both structs, share NO trait, or share MORE THAN ONE (ambiguous — require an annotation; never
    /// guess). Trait EQUALITY is by resolved TypeId, so the same trait named twice is not "two".
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
                    if (f != trait_tid) return null; // >1 distinct common trait → ambiguous
                } else found = trait_tid;
            }
        }
        return found;
    }
    fn ok(self: *Inferer, id: TypeId) TypeId {
        self.stats.typed += 1;
        return id;
    }

    /// Records into the TypedIr when one is attached. The recursive calls below all
    /// go through here, so every sub-expression is recorded too.
    pub fn inferExpr(self: *Inferer, ep: *const ast.Expression) anyerror!TypeId {
        return self.inferExprExpecting(ep, null);
    }

    /// `expected` is the type this position REQUIRES, when the caller knows it.
    ///
    /// It exists for closures and only for closures: a closure parameter carries no
    /// annotation (spec 6.3), so the expected type is the only thing that can give
    /// `k` in `m.forEach((k, v) => ...)` a type. Everything else ignores it — this
    /// is contextual typing, not full bidirectional inference, and the difference
    /// is worth keeping: nothing here ever CHECKS an expression against `expected`.
    pub fn inferExprExpecting(self: *Inferer, ep: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const t = try self.inferExprInner(ep.*, expected);
        if (self.ir) |ir| {
            try ir.record(self.allocator, ep, t);
            // F2-6 stage 5: also record the ownership disposition, so the checker owns the decision a
            // `--shadow` diff proves it agrees with codegen's `acquisitionDisposition` on.
            try ir.recordOwned(self.allocator, ep, self.ownedDisposition(ep.kind, t));
        }
        return t;
    }

    /// F2-6 stage 5: the ownership disposition of an expression occurrence — true = OWNED (a fresh +1
    /// the statement drain consumes), false = BORROWED (names an existing owner) or trivial. Mirrors
    /// codegen's `principledDisposition` (arc.zig): borrow KINDS and non-producing forms are borrowed;
    /// everything else is owned iff its type is ARC-managed. The `--shadow` diff measures where this
    /// and codegen disagree (expected residue: payload-carrying enums, which `store.isOwned` reads
    /// coarsely — the same enum-awareness gap codegen routes through a fallback).
    fn ownedDisposition(self: *Inferer, kind: ast.ExprKind, t: TypeId) bool {
        switch (kind) {
            .ident, .field_access, .index => return false,
            .binary => |b| if (b.op == .assign) return false,
            // A decimal literal is NOT a compile-time constant: `9.99m` lowers to a runtime
            // nova_decimal_from_string call — a fresh 16-byte ARC heap +1 — so it is an owned
            // temporary, exactly like a template string. Every OTHER literal is borrowed: int/
            // bool/float are trivial and a string literal is a static, sentinel-refcounted global.
            .literal => |lit| if (lit != .decimal) return false,
            .try_expr, .cast, .await_expr, .go_expr, .optional_chaining => return false,
            else => {},
        }
        // `isOwnedSafe`, not `isOwned`: the checker runs on a still-generic body, so an unbound
        // `.type_param` (even nested in `?T`) or an `.unresolved` expr legitimately reaches here —
        // `isOwned`'s substitution-invariant `unreachable`s would crash. Both read as non-owned by
        // the erasure rule; the `--shadow` diff surfaces where that under-claims vs monomorphized
        // codegen (the `.type_param` residue) rather than letting it corrupt the disposition.
        return self.store.isOwnedSafe(t);
    }

    fn inferExprInner(self: *Inferer, e: ast.Expression, expected: ?TypeId) anyerror!TypeId {
        switch (e.kind) {
            // `a..b` — a numeric range. Its bounds are ints; the range's element type (what the loop
            // variable binds to) is `int`. Not a first-class value type yet — only a for-in iterable.
            .range => |r| {
                _ = try self.inferExpr(r.start);
                _ = try self.inferExpr(r.end);
                return self.ok(try self.store.intT());
            },
            .literal => |lit| return switch (lit) {
                // An integer literal is `int` (32-bit, F3's target) — not the
                // machine word. Range checking against the declared type is F3
                // stage 5; representing it honestly is the precondition.
                .integer => self.ok(try self.store.intT()),
                .float => self.ok(try self.store.doubleT()),
                .string => self.ok(try self.store.stringT()),
                .bool => self.ok(try self.store.boolT()),
                // A `m`-suffixed decimal literal (`9.99m`) is `decimal` — a 16-byte ARC heap object
                // (specs §3.1). Without this arm the literal fell to `unresolved`, so its ownership
                // was invisible: bound to an annotated local it still worked (the local carries the
                // type), but used as a bare temp (`take(9.99m)`) nothing owned or drained it → leak.
                .decimal => self.ok(try self.store.decimalT()),
                // `[1, 2, 3]` — element type from the first element, length from
                // the literal. An EMPTY array is honestly unresolved: types.zig:206
                // answers "i32" there, inventing an element type out of nothing.
                .array => |items| {
                    if (items.len == 0) return self.unresolved("literal");
                    const elem = try self.inferExpr(&items[0]);
                    for (items[1..]) |*it| _ = try self.inferExpr(it);
                    if (self.store.get(elem) == .unresolved) return self.unresolved("literal");
                    return self.ok(try self.store.intern(.{ .array = .{ .elem = elem, .len = items.len } }));
                },
                else => self.unresolved("literal"),
            },
            .ident => |name| {
                if (self.lookup(name)) |t| return self.ok(t);
                // A CONSTANT: `const SECONDS_PER_MINUTE = 60;` — its type is its
                // initialiser's. Const decls are in the symbol table but nothing
                // was looking them up.
                if (try self.constType(name)) |t| return self.ok(t);
                // A bare fn used as a VALUE has a function type (§10 #18's box).
                if (self.symtab.findFunction(name)) |sid| {
                    if (self.symtab.symbolAt(sid).decl == .function) {
                        return self.ok(try self.fnType(self.symtab.symbolAt(sid).decl.function));
                    }
                }
                // F2-5: a bare RUNTIME EXTERN callee (`nova_test_fail`, `nova_exit`, declared in no
                // .nova file). The call arm already resolves its return type via findExtern; the callee
                // ident was still counting as `.unresolved`. It is only ever CALLED, so its own type is
                // that return type — enough to stop it being untyped.
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
                // F2-5 fatal (shadow): a bare ident reaching here is a NAMESPACE ref (module / magic
                // builtin / self), a container TYPE name the symbol table does not hold (`Storage`), a
                // runtime EXTERN (`nova_*`), or a GENUINE undefined identifier — only the last is fatal.
                // Counted (not yet erroring): the corpus proves this is 0, so the end-of-sema fatal is
                // ready to enable once the exclusion set is validated against btree/app and the ident
                // carries a span for a located diagnostic. Undefined idents are already caught at
                // codegen (expressions.zig "Identifier not found"); this moves the check earlier.
                if (self.isFatalUnresolvedIdent(name)) {
                    self.fatal_unresolved_idents += 1;
                    if (self.first_fatal_ident == null) self.first_fatal_ident = name;
                } else {
                    // F2-6 stage 0: not fatal ⇒ a not-a-value ident (module / builtin / container
                    // type / extern). CORRECTLY untyped-as-a-value, not a coverage gap.
                    self.stats.unresolved_ns_ident += 1;
                }
                try self.note(name);
                return self.unresolved("ident");
            },
            .binary => |b| {
                const lt = try self.inferExpr(b.left);
                // Comparison and logical operators are BOOL. The resolver types
                // them as i32 today (roadmap A3), which is why the
                // condition-must-be-bool check would flag every `if`.
                switch (b.op) {
                    // Comparisons and the LOGICAL operators are bool.
                    //
                    // `.And`/`.Or` are `&&`/`||`. The bitwise `&`/`|` are
                    // `.bit_and`/`.bit_or` and must NOT be here — they yield the
                    // operand type, so they fall through to the arithmetic path
                    // below. They used to be named `@"and"`/`@"or"`, left over from
                    // the `and`/`or` keywords that `&&`/`||` replaced, which is
                    // exactly how all four ended up in this arm typing
                    // `hash & (cap - 1)` as bool. Renamed so it cannot recur.
                    .eq, .ne, .lt, .gt, .le, .ge, .And, .Or => {
                        _ = try self.inferExpr(b.right);
                        return self.ok(try self.store.boolT());
                    },
                    // Assignment is an expression yielding the assigned value
                    // (specs.md §5.6): `a = b = 5` is legal and tested. Its type is
                    // the LHS's — void would silently break the chain at cutover.
                    .assign => {
                        // `const` is enforced-immutable: reassigning a const binding is a hard error
                        // (recorded, rejected at end of sema). `let` stays mutable. Only a bare-ident
                        // LHS is a rebinding of the binding itself; `c.field = x` / `c[i] = x` mutate
                        // THROUGH a const reference, which is allowed (the reference is const, not the
                        // pointee) — matching `const xs = List(); xs.push(1)`.
                        if (b.left.kind == .ident and self.lookupIsConst(b.left.kind.ident)) {
                            self.const_reassign_errors.append(self.allocator, .{ .span = b.span, .name = b.left.kind.ident }) catch {};
                        }
                        const at = try self.inferExpr(b.right);
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
                const rt = try self.inferExpr(b.right);
                // String CONCAT: `+` with EITHER operand a string yields a string. Typing it as the
                // LEFT operand's type made `n + " items"` (int + string) type as `int`, so codegen
                // never registered the concat result as an owned temporary and it leaked (24_stringify
                // "42 items"). `string + int` was already correct (left IS the string).
                if (b.op == .add and (self.store.get(lt) == .string or self.store.get(rt) == .string)) {
                    return self.ok(try self.store.stringT());
                }
                if (self.store.get(lt) == .unresolved) {
                    // NOT `orelse "i32"`. If the left is unknown the result is
                    // unknown — types.zig:457 answers `i32` here, which is a wrong
                    // answer wearing a valid type.
                    return if (self.store.get(rt) == .unresolved) self.unresolved("binary") else self.ok(rt);
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
                // Infer the CALLEE as an expression, not just as a name to resolve.
                // The walk used to be need-driven — it visited what it needed to
                // compute a type — so a callee like `string.eql` was consulted but
                // never RECORDED, and codegen asking about it found nothing. Every
                // node must be visited, whether or not its type is needed here.
                self.in_call_callee = true;
                const callee_t = try self.inferExpr(c.callee);
                self.in_call_callee = false;
                self.stats.typed -|= 1;
                // `E.Variant(x)` — enum construction with a payload. It parses as a CALL with a
                // field-access callee (not `.enum_init`, which is the payload-less form), and
                // nothing here typed it, so `return E.NotFound(k)` had NO type at all.
                //
                // That is not cosmetic: specs §3.4b's return wrap asks "is this value the error
                // side?" by comparing the value's type to the declared error type. With no type
                // the answer defaulted to "no", so `return E.NotFound(k)` was boxed with the OK
                // tag — the error silently became a success. Typing it here is the root fix; the
                // alternative (matching the syntax at the return site) is exactly the syntactic
                // guard that made the tuple `return t` a use-after-free.
                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;
                    if (fa.object.kind == .ident) {
                        if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                            const decl = self.symtab.symbolAt(sid).decl;
                            // Enum construction is `E.Variant(payload)` — the FIELD must name a VARIANT.
                            // A STATIC METHOD call `E.method(args)` (e.g. `Status.reasonPhrase(s)`) also
                            // parses as a field-access-callee on an enum name, and typing it as `.enum_`
                            // here (the old, field-blind check) discarded the method's real return type —
                            // so `let r = Status.reasonPhrase(s)` was typed as the enum, and a `+` concat
                            // then numToString'd the string RESULT (garbage HTTP reason phrase/headers).
                            // Only short-circuit when the field is genuinely a variant; otherwise fall
                            // through to methodReturn/staticMethodReturn, which resolves the return type.
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
                // Resolve what the callee EXPECTS before inferring the arguments —
                // a closure argument has no other source for its parameter types
                // (spec 6.3a), and inferring it first would bind them unresolved
                // and record that. Order is the whole mechanism here.
                const want = try self.calleeParamTypes(c.callee);
                defer if (want) |w| self.allocator.free(w);
                // Capture the argument types — a generic FREE-function call solves its type params from
                // them (freeFnReturn), the same way methodReturn solves a method's own params.
                var arg_types = std.ArrayListUnmanaged(TypeId).empty;
                defer arg_types.deinit(self.allocator);
                for (c.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (want) |w| (if (i < w.len) w[i] else null) else null;
                    const at = try self.inferExprExpecting(a, exp);
                    try arg_types.append(self.allocator, at);
                }
                if (c.callee.kind == .ident) {
                    // A bare-name runtime extern: nova_test_fail(msg) etc. No .nova
                    // declaration exists — codegen declares them as C externs.
                    if (builtins.findExtern(c.callee.kind.ident)) |b| {
                        return self.ok(try builtins.retType(self.store, b.ret));
                    }
                    // Prefer the SAME-MODULE function: `str`/`number`/`object` are defined in BOTH
                    // serde.json and serde.yaml, and the global first-match `findFunction` would type a
                    // bare `str("x")` in yaml.nova as json's `str` (return JsonValue) — while codegen
                    // dispatches module-scoped to yaml's `str` (YamlValue). That divergence released a
                    // YamlValue temp through `__destruct_JsonValue` (a co-import crash). Resolving the
                    // return type module-scoped first makes sema agree with codegen's dispatch.
                    const bare_fn_sid: ?symbols.SymbolId = blk: {
                        if (self.current_module) |cm| {
                            if (self.symtab.findFunctionIn(cm, c.callee.kind.ident)) |s| break :blk s;
                        }
                        break :blk self.symtab.findFunction(c.callee.kind.ident);
                    };
                    if (bare_fn_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .function) {
                            // F1-3b: the callee is resolved to THIS symbol — record it (whether or
                            // not its return type is known), so codegen can later resolve the call
                            // by SymbolId instead of the func_map suffix scan. But ONLY when the
                            // bare name is UNAMBIGUOUS: if two decls share it, the codegen scan must
                            // still fire and reject it (N2, F1 §2.3) — recording an arbitrary pick
                            // would silently bypass that safety. Gated by `ambiguous_bare_call`.
                            if (!self.symtab.findFunctionAmbiguous(c.callee.kind.ident)) {
                                if (self.ir) |ir| try ir.recordSym(self.allocator, &e, sid);
                            }
                            const fd = sym.decl.function;
                            if (fd.ret_type) |r| {
                                // GENERIC free function (`fn id<T>(x: T): T`): the erased return is a
                                // `.type_param`, which reads non-owned and left `id(s)` mis-typed — the
                                // LAST keystone gap in the disposition oracle. Solve the type params from
                                // the argument types and substitute into the return, exactly as
                                // methodReturn does for a method's own params. A param that does not solve
                                // stays itself, so the result falls back to the erased type (no regression).
                                if (fd.type_params.len > 0) {
                                    if (try self.freeFnReturn(sid, fd, r, arg_types.items)) |t| {
                                        if (self.store.get(t) != .unresolved) return self.ok(t);
                                    }
                                }
                                const t = try self.lowerer.lower(r);
                                if (self.store.get(t) != .unresolved) return self.ok(t);
                            } else return self.ok(try self.store.voidT());
                        }
                    }
                    // A constructor call: `Foo(...)` yields Foo.
                    if (self.symtab.findTypeInModule(c.callee.kind.ident, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }
                }
                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;
                    // Module-qualified FIRST: `string.hash(x)`. The object is a
                    // MODULE, not a struct receiver — checked before inferring it,
                    // so a module name does not get counted as an unresolved ident.
                    //
                    // The guard is the same one F1 put into codegen this morning
                    // (llvm_codegen.zig `obj_is_variable`): only a module namespace
                    // can name a function in member position. A VARIABLE's member is
                    // never a module fn, however the names collide — that confusion
                    // is §10 #6, which cost months as "string heap corruption".
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
                    // MODULE-QUALIFIED CONSTRUCTOR: `protocol.ProtocolWriter()` — the
                    // FIELD names the type. Codegen builds the constructor, but without
                    // typing the result here `let w = protocol.ProtocolWriter()` is
                    // untyped and `w.method()` fails. (The bare `Foo()` case is typed by
                    // the `.ident` callee branch above; this is its module-qualified form.)
                    if (self.symtab.findTypeInModule(fa.field, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }
                    // STATIC/associated method: `Point.origin()` — the receiver is the
                    // struct NAME, not a value, so methodReturn (which infers the object
                    // as a value) missed it and the result was `unresolved`. That left
                    // `let q = Point.origin()` untyped, so `q.method()` could not resolve
                    // — the bug that made static factories like `File.open()` unusable.
                    if (try self.staticMethodReturn(fa)) |t| return self.ok(t);
                    if (fa.object.kind == .ident) try self.note(fa.object.kind.ident);
                }
                // The callee is a VALUE of function type — `(self.hashFn)(key)`
                // (map.nova:62), or `let f = ...; f(x)`. This is the general rule the
                // named paths above are special cases of, so it goes last: a field or
                // local holding a function is called by evaluating it, and its type
                // already says what it returns.
                //
                // It is deliberately NOT a field special-case. `hashFn` is only
                // interesting because it is a field whose TYPE is `.func`; the shape
                // of the callee expression is irrelevant.
                if (self.store.get(callee_t) == .func) {
                    return self.ok(self.store.get(callee_t).func.ret);
                }
                if (c.callee.kind == .ident) try self.note(c.callee.kind.ident);
                return self.unresolved("call");
            },
            .field_access => |fa| {
                // F2-6 stage 1: capture-and-clear so this field_access knows if IT is a call callee
                // (a method reference), while its RECEIVER (`fa.object`, inferred just below) is judged
                // as an ordinary value.
                const is_callee = self.in_call_callee;
                self.in_call_callee = false;
                // Always visit the object, even when the paths below do not need its
                // type (a module receiver, say). Exhaustive, not need-driven.
                _ = try self.inferExpr(fa.object);
                self.stats.typed -|= 1;
                // `string.hash` used as a VALUE is a function (§10 #18's box).
                if (try self.moduleFnValue(fa)) |t| return self.ok(t);
                if (try self.fieldType(fa)) |t| return self.ok(t);
                // `s.length` is a builtin PROPERTY on string, not a field — codegen
                // special-cases it (expressions.zig:1590, loading the i32 header at
                // [ptr-4]). Used 194x across the stdlib.
                if (try self.stringProperty(fa)) |t| return self.ok(t);
                // `E.A` — a PAYLOAD-LESS enum value: object names the enum, field is a variant.
                // Without this it typed as `.unresolved`, so `let s = E.A` gave `s` no type and
                // `s.code()` found no method. (The payload form `E.N(3)` is a CALL, typed
                // elsewhere.) Symmetric with the enum-construction typing on the call path.
                if (fa.object.kind == .ident) {
                    if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                        if (self.symtab.symbolAt(sid).decl == .enum_) {
                            return self.ok(try self.store.intern(.{ .enum_ = sid }));
                        }
                    }
                }
                // F2-6 stage 0: `console.log` / `assert.x` — an access ON a not-a-value receiver (a
                // module/builtin ident that is not a local). The access itself is namespace routing,
                // not a value whose type sema failed to find.
                if (fa.object.kind == .ident) {
                    const obj = fa.object.kind.ident;
                    if (self.lookup(obj) == null and !self.isFatalUnresolvedIdent(obj)) {
                        self.stats.unresolved_ns_field += 1; // `console.log` — access on a module
                        return self.unresolved("field_access");
                    }
                }
                // A method-call CALLEE (`xs.push`, `self.data.get`) is a method REFERENCE — not a
                // first-class value — so an unresolved one is not-a-value, not a coverage gap. The
                // CALL itself is typed by the .call arm.
                if (is_callee) {
                    self.stats.unresolved_ns_field += 1;
                    return self.unresolved("field_access");
                }
                // GENUINE field_access failure — a FIELD on a real value sema could not type.
                // Record the field name so the report names the actual coverage gap.
                try self.note(fa.field);
                return self.unresolved("field_access");
            },
            .optional_chaining => |o| {
                _ = try self.inferExpr(o.object);
                return self.unresolved("optional_chaining");
            },
            .nullish_coalesce => |n| {
                const lt = try self.inferExpr(n.left);
                const rt = try self.inferExpr(n.right);
                if (self.store.get(lt) == .unresolved)
                    return if (self.store.get(rt) == .unresolved) self.unresolved("nullish") else self.ok(rt);
                // `a ?? b`: if `a` is `T | undefined`, the result is `T` — `b` supplies the value
                // when `a` is absent. STRIP the leading optional so the coalesced value is
                // non-optional; this is THE guarded form (H2), so `xs.get(i) ?? d` must yield a
                // plain `T` that needs no further guarding. (Without this, `??` returned the
                // optional unchanged, so even guarded access still "saw through".)
                const l = self.store.get(lt);
                if (l == .optional) return self.ok(l.optional);
                return self.ok(lt);
            },
            // A template string IS a string — but so is `.block_expr` according to
            // types.zig:477, unconditionally, which is simply wrong.
            .template_expr => |t| {
                for (t.parts) |*p| _ = try self.inferExpr(p);
                return self.ok(try self.store.stringT());
            },
            .if_expr => |ie| {
                _ = try self.inferExpr(ie.condition);
                const tt = try self.inferExprExpecting(ie.then_branch, expected);
                const et = try self.inferExprExpecting(ie.else_branch, expected);
                // Contextual trait typing: `let o: G = if (c) A{} else B{}` — when the expected type is
                // a trait and both branches are structs, the if-expr IS the trait (each branch widens to
                // it in codegen). The branch EXPRESSIONS keep their struct types (recorded above), which
                // codegen needs to build each vtable. Without this the if-expr is `.unresolved` (tt != et
                // for two different structs) and a raw struct reaches the trait slot → SEGV.
                if (expected) |exp_t| {
                    if (self.store.get(exp_t) == .trait_ and
                        self.store.get(tt) == .struct_ and self.store.get(et) == .struct_)
                        return self.ok(exp_t);
                }
                if (tt == et) return self.ok(tt);
                // C2: unannotated heterogeneous branches — type the if-expr as the two structs' common
                // trait (LUB) so codegen widens each branch (A3(e)) instead of leaking a raw struct into a
                // trait slot. Branch expressions keep their struct types (inferred above) for the vtables.
                if (try self.lubTraitOfStructs(tt, et)) |lub| return self.ok(lub);
                return self.unresolved("if_expr");
            },
            .struct_init => |si| {
                // Infer each field value with its DECLARED type as the expected type, so a tuple/trait
                // literal in a field slot (`Pair2{ p: (4, A{}) }` where `p: (int, G)`) is typed by
                // context — the element lands as the trait on the field's TypeId and codegen widens it.
                // Without the expectation the literal is typed by its elements and a raw struct sits in
                // the trait slot → SEGV. Same seam as the let / return / tuple-element expected typing.
                const decl_sid = self.symtab.findTypeInModule(si.type_name, self.current_module);
                for (si.fields) |*f| {
                    var expected_field: ?TypeId = null;
                    if (decl_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .struct_) {
                            for (sym.decl.struct_.fields) |sf| {
                                if (std.mem.eql(u8, sf.name, f.name)) {
                                    expected_field = self.lowerer.lower(sf.type_name) catch null;
                                    break;
                                }
                            }
                        }
                    }
                    _ = try self.inferExprExpecting(&f.value, expected_field);
                }
                self.recordTypeVis(si.type_name, si.span); // F1-4: `mod.PrivateType{...}` cross-module construction
                if (decl_sid) |sid| {
                    return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                }
                return self.unresolved("struct_init");
            },
            .index => |ix| {
                const obj = try self.inferExpr(ix.object);
                _ = try self.inferExpr(ix.index);
                switch (self.store.get(obj)) {
                    // `s[i]` on a string yields a BYTE. It is `int` here rather
                    // than a `byte` because that is what the expression evaluates
                    // to today (codegen sign/zero-extends into the machine word);
                    // F3 stage 5 is where that becomes a real 8-bit value.
                    .string => return self.ok(try self.store.intT()),
                    .array => |a| return self.ok(a.elem),
                    else => return self.unresolved("index"),
                }
            },
            // specs.md 7.1. `go f()` yields future<T>; `await` unwraps it, and
            // `await <direct async call>` is simply the call's type.
            //
            // Both returned unresolved unconditionally, which is why `await` was one
            // of the last things blocking the legacy resolver's deletion — and why
            // `let x = await square(a)` poisoned x, y and the `x + y` after them.
            .go_expr => |g| {
                const inner = try self.inferExpr(g.operand);
                if (self.store.get(inner) == .unresolved) return self.unresolved("go");
                return self.ok(try self.store.intern(.{ .future = inner }));
            },
            .await_expr => |a| {
                const inner = try self.inferExpr(a.operand);
                // Unwrap a future; otherwise the operand IS the value (awaiting a
                // direct call). NOT `.unresolved` -> int: an unknown operand makes
                // an unknown result, or this becomes the i32-on-failure lie again.
                return switch (self.store.get(inner)) {
                    .future => |t| self.ok(t),
                    .unresolved => try self.unresolved("await"),
                    else => self.ok(inner),
                };
            },
            .tuple => |items| {
                const elems = try self.allocator.alloc(TypeId, items.len);
                defer self.allocator.free(elems);
                // Contextual widening: in a position with an expected tuple type (return/let/arg —
                // return passes `current_ret`), a STRUCT element sitting in a TRAIT slot types AS the
                // trait, so the tuple's TypeId carries the trait and codegen widens the struct to the
                // trait object. Without this, `(1, A{})` in a `(int, G)` position typed as `(int, A)`
                // and the raw struct stayed in the trait slot → garbage vtable → SEGV.
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
                // specs.md 6.3a: a closure's parameters come from the EXPECTED type.
                // They have no annotation and nowhere to put one, so with no
                // expectation there is genuinely nothing to conclude — they stay
                // unresolved, and that is honest rather than a failure.
                const want: ?types.FuncType = if (expected) |x| switch (self.store.get(x)) {
                    .func => |ft| ft,
                    else => null,
                } else null;

                try self.push();
                defer self.pop();
                for (cl.params, 0..) |p, i| {
                    // Arity must match, or the binding would silently pair `k` with
                    // the wrong parameter's type — resolved-looking and wrong.
                    const pt = if (want) |ft|
                        (if (i < ft.params.len and ft.params.len == cl.params.len)
                            ft.params[i]
                        else
                            try self.store.unresolvedT())
                    else
                        try self.store.unresolvedT();
                    try self.bind(p, pt);
                }
                // specs.md 6.3a: with no expected type, a parameter is inferred
                // from its USE — `(x) => x + 1` pins x to int. Done as a probe pass
                // BEFORE the real one, so the IR records the improved types rather
                // than the unresolved first guess: codegen reads the IR, and a
                // recorded `.unresolved` is what it would act on.
                // Runs whether or not there was an expectation: an expectation that
                // says `unresolved` for a parameter is NO expectation for it.
                //
                // `xs.reduce(0, (acc, x) => acc + x)` — reduce<U>(acc: U, fn: (U,T) => U).
                // U is solved from the FIRST argument (`0` -> int), but arguments are
                // inferred before that happens, so the closure's expected type still
                // has U unresolved and `acc` came out unresolved with it. `acc + x`
                // pins it from x, which is already known.
                for (cl.params) |p| {
                    if (self.lookup(p)) |cur| {
                        if (self.store.get(cur) != .unresolved) continue;
                        if (try self.paramFromUse(p, cl.body)) |t| self.rebind(p, t);
                    }
                }
                const body_t: TypeId = switch (cl.body) {
                    .expr => |ex| try self.inferExpr(ex),
                    .block => |*b| blk: {
                        // A braced closure's return type is what its `return`s yield, NOT void.
                        // Hardcoding void meant `let f = () => { return P(7); }; f().x` typed `f()`
                        // as void and `.x` failed with "unknown struct type='void'". Captured
                        // DURING the walk (below), because re-inferring the return afterwards runs
                        // with the block's locals already out of scope and mis-types
                        // `return r.field`. Save/restore so a NESTED closure does not clobber ours.
                        const saved_cap = self.captured_return;
                        self.captured_return = null;
                        try self.inferBlock(b);
                        const rt = self.captured_return orelse try self.store.voidT();
                        self.captured_return = saved_cap;
                        break :blk rt;
                    },
                };
                // The closure's own type. With a known expectation the params are
                // real, so this is a usable `.func` — which is what makes a call
                // through it typeable.
                if (want) |ft| {
                    if (ft.params.len == cl.params.len) {
                        // The params come from the expectation; the RETURN comes from
                        // the BODY. Returning `ft.ret` verbatim reports the closure's
                        // type as its expected type — so `(x) => x * 2` passed to
                        // `map<U>(fn: (T) => U)` claimed to be `(int) -> U`, and
                        // solving U against U learns nothing. The whole point of
                        // inferring U from the closure is that the body knows it.
                        // The params come from the expectation; the RETURN normally comes from the
                        // BODY (so a generic `U` in `map<U>(fn:(T)=>U)` is solved FROM the body, not
                        // reported back verbatim). EXCEPTION: when the expected return is a TRAIT and
                        // the body yields a concrete impl, the closure's return type is the TRAIT —
                        // exactly like a named `fn f(): Trait { return Impl(); }`. The body value then
                        // widens to the fat pointer at the return (statements.zig return-widening).
                        // Without this the closure recorded its body-concrete type, so codegen left the
                        // return UNWIDENED (a raw struct) and any downcast of the produced trait object
                        // crashed — the di-factory `(sp) => ServiceImpl()` case.
                        const ret = if (self.store.get(ft.ret) == .trait_ and self.store.get(body_t) != .unresolved)
                            ft.ret
                        else if (self.store.get(body_t) != .unresolved)
                            body_t
                        else
                            ft.ret;
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ft.params, .ret = ret } }));
                    }
                }
                // No expectation, but the params may have been pinned by their use
                // above — `(x) => x + 1` is `(int) -> int`. Building the type here is
                // what makes `let f = (x) => x + 1; f(5)` typeable: the general
                // "callee of .func type" rule then has something to read.
                {
                    const ps = try self.allocator.alloc(TypeId, cl.params.len);
                    defer self.allocator.free(ps);
                    for (cl.params, 0..) |p, i| {
                        ps[i] = self.lookup(p) orelse try self.store.unresolvedT();
                    }
                    // Type the closure as a `.func` whenever its RETURN is known — even if a
                    // PARAMETER is still unresolved. The return type is what a call through the
                    // closure yields and what the closure box's ownership hinges on; an unresolved
                    // param only loosens ARGUMENT checking (already loose for an un-inferrable
                    // param), it does not make the value any less a callable owned box. Requiring
                    // ALL params known left `let g = (x) => `n${x}`` typed `.unresolved` (x is
                    // un-pinnable — a template interpolation constrains nothing), so `g` was not an
                    // owned closure box (its 24-byte box leaked) and `g(5)` was untyped (its string
                    // result leaked). When `body_t` itself is unresolved (`(x) => x` identity with x
                    // unknown) this still yields `.unresolved` — the return genuinely is unknown.
                    if (self.store.get(body_t) != .unresolved) {
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ps, .ret = body_t } }));
                    }
                }
                return self.unresolved("closure");
            },
            // specs §3.4b. `try f()` yields f's OK type (the error path returns from the enclosing fn).
            .try_expr => |inner| {
                const it = try self.inferExpr(inner);
                const ity = self.store.get(it);
                if (ity == .error_union) return self.ok(ity.error_union.ok);
                // `try` on a non-error-union is a mistake, but diagnosing it is the checker's job;
                // pass the type through rather than inventing one.
                return self.ok(it);
            },
            // `f() catch h` also yields the OK type: the handler supplies a value on the error path
            // (or diverges). The handler is inferred with `e` bound to the unwrapped ERROR.
            .catch_expr => |*ce| {
                const it = try self.inferExpr(ce.expr);
                const ity = self.store.get(it);
                if (ity == .error_union) {
                    if (ce.err_name) |n| try self.bind(n, ity.error_union.err);
                    _ = try self.inferExpr(ce.handler);
                    return self.ok(ity.error_union.ok);
                }
                _ = try self.inferExpr(ce.handler);
                return self.ok(it);
            },
            .block_expr => |*b| {
                try self.inferBlock(b);
                return self.unresolved("block_expr");
            },
            .generic_call => |g| {
                // Compiler-intrinsic reifies keyed on the `serde` pseudo-module — handled BEFORE
                // callee inference, since `serde` is not a real imported module and would otherwise
                // trip the F2-5 unresolved-identifier check. `serde.bind<T>(src): T`,
                // `serde.typeName<T>(): string`.
                if (g.callee.kind == .field_access) {
                    const sfa = g.callee.kind.field_access;
                    if (sfa.object.kind == .ident and std.mem.eql(u8, sfa.object.kind.ident, "serde") and g.type_args.len == 1) {
                        if (std.mem.eql(u8, sfa.field, "bind")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            return self.ok(try self.lowerer.lower(g.type_args[0]));
                        }
                        if (std.mem.eql(u8, sfa.field, "typeName")) {
                            return self.ok(try self.store.stringT());
                        }
                    }
                }
                _ = try self.inferExpr(g.callee);
                self.stats.typed -|= 1;
                // Propagate DECLARED parameter types to the arguments for a METHOD call on a value
                // receiver, so a CLOSURE argument gets its parameter types from the method signature —
                // `app.handleFrom<T>((sp) => sp.require("Db"))` types `sp` as `ServiceProvider`. Without
                // this a closure arg to a GENERIC method was inferred with NO expected type, leaving its
                // params unresolved, and any method call through them ("no such method or function")
                // failed. This mirrors the `.call` arm's `calleeParamTypes` propagation; it is scoped to
                // field-access (method) callees so generic constructors/free-functions are unaffected.
                var gwant: ?[]TypeId = null;
                if (g.callee.kind == .field_access) gwant = self.calleeParamTypes(g.callee) catch null;
                defer if (gwant) |w| self.allocator.free(w);
                for (g.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (gwant) |w| (if (i < w.len) w[i] else null) else null;
                    _ = try self.inferExprExpecting(a, exp);
                }
                // `bytes.new<T>()` / `new_persistent<T>()` / `new_with_allocator<T>()`
                // allocate a `T` and return it — Nova structs are reference-semantic
                // (an i64 handle), so the EXPRESSION's type is `T`, not the builtin's
                // erased `.ptr`. Without this the result is `unresolved`, and codegen
                // rejects `f.field = ...` on it (FieldAccessObjectNotStruct) — the bug
                // that broke io/file, io/dir, and net/tcp/server.
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
                // Explicit-type-arg method call on a VALUE receiver — `app.get<GetUser>(path)` — is
                // tried BEFORE the free-function/constructor `tname` fallback below: otherwise
                // `a.get<T>(..)` collides with a global function named `get` (List/Map define one),
                // which hijacked the call and left it unrecorded (`post` had no such collision, so it
                // worked — the asymmetry that surfaced this). `explicitMethodReturn` returns null for
                // a module/namespace receiver, so `list.List<int>()` still falls through.
                if (g.callee.kind == .field_access) {
                    var vmsym: ?types.SymbolId = null;
                    if (try self.explicitMethodReturn(g.callee.kind.field_access, g.type_args, g.args, &vmsym)) |mt| {
                        if (vmsym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(mt);
                    }
                }
                // `list.List<int>()` / `List<string>()` — a generic constructor.
                // The type args are RIGHT THERE in the AST; codegen throws them
                // away for struct literals (parser.zig:1461, F4 §2.4) and erases
                // them at every lookup via getStructBaseName. Here they make the
                // instantiation: List<int> and List<string> are distinct TypeIds.
                const tname: ?[]const u8 = switch (g.callee.kind) {
                    .ident => |n| n,
                    .field_access => |fa| fa.field, // `list.List<int>()`
                    else => null,
                };
                if (tname) |n| {
                    // The call's type args are lowered in the CALLER's scope, and
                    // must be: `allocCopy<T>(value)` at list.nova:40 sits inside
                    // `List<T>.push`, so that `T` is LIST's T. Lowering it in the
                    // callee's scope would resolve it to allocCopy's own T and
                    // substitute a parameter with itself.
                    const args = try self.allocator.alloc(TypeId, g.type_args.len);
                    defer self.allocator.free(args);
                    for (g.type_args, 0..) |ta, i| args[i] = try self.lowerer.lower(ta);

                    // `Storage<T>(n)` — a PRIMITIVE, so there is no declaration to
                    // find (specs.md §3.8). Without this the local is unresolved and
                    // codegen cannot dispatch `.get`/`.set`, which are typed on the
                    // receiver.
                    if (std.mem.eql(u8, n, "Storage") and args.len == 1) {
                        return self.ok(try self.store.intern(.{ .storage = args[0] }));
                    }
                    if (self.symtab.findTypeInModule(n, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }));
                    }
                    // A generic FUNCTION — `allocCopy<T>(v)`. Only the constructor
                    // case existed, so every generic function call was unresolved.
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
                            if (self.store.get(sub) != .unresolved) return self.ok(sub);
                        }
                    }
                }
                // Explicit-type-arg method call on a VALUE receiver — `app.get<GetUser>(path)`.
                // (Constructors / free-fns / `bytes.new<T>` are handled above via `tname`.) This
                // is the method-monomorphization entry point (now handled above, before `tname`).
                return self.unresolved("generic_call");
            },
            .enum_init => |ei| {
                for (ei.fields) |*f| _ = try self.inferExpr(&f.value);
                if (self.symtab.findTypeInModule(ei.enum_name, self.current_module)) |sid| return self.ok(try self.store.intern(.{ .enum_ = sid }));
                return self.unresolved("enum_init");
            },
            .jsx_element => return self.unresolved("jsx"),
        }
    }

    fn fnType(self: *Inferer, f: *const ast.FunctionDecl) !TypeId {
        const params = try self.allocator.alloc(TypeId, f.params.len);
        defer self.allocator.free(params);
        for (f.params, 0..) |p, i| {
            params[i] = if (p.type_name) |t| try self.lowerer.lower(t) else try self.store.unresolvedT();
        }
        const ret = if (f.ret_type) |r| try self.lowerer.lower(r) else try self.store.voidT();
        return self.store.intern(.{ .func = .{ .params = params, .ret = ret } });
    }

    /// The type of `obj.field`. Needs the object's struct decl — which is why
    /// Symbol carries its decl (F1 §3.2).
    /// Lower a type written INSIDE `st`'s declaration, then substitute `st`'s own
    /// type arguments into it.
    ///
    /// Both halves matter and both were missing. A declared `T` only means anything
    /// in the scope of the declaration that binds it — lowering it under whatever
    /// scope the walk left behind resolves it against the wrong declaration, or not
    /// at all. And having lowered it to `.type_param{Box, 0}`, it is still a
    /// parameter until the receiver's `args` say what it stands for.
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

    /// Like `lowerInStructScope`, but with the METHOD's own type params in scope
    /// too — `pub fn map<U>(self: List<T>, ...)` has T from the struct and U from
    /// the method, in two different declarations (see lower.zig's ParamScope).
    ///
    /// Without the method scope, `U` is not a parameter at all: it lowers to
    /// `.unresolved`, and then there is nothing for solveParams to match against.
    /// The receiver's args are substituted (T := int); U is left as a parameter,
    /// which is exactly what the solver then binds.
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
        // Only the RECEIVER's args are substituted here; the method's own params
        // stay parameters until the arguments solve them.
        return try subst.substitute(self.store, raw, st.decl, st.args);
    }

    /// F4 (the last keystone gap): the return type of a GENERIC FREE-function call, with its type
    /// params solved from the argument types and substituted in. The free-function twin of
    /// `methodReturn`'s solve loop (no receiver, so params map positionally to args and there is no
    /// struct scope to substitute — only the function's own type params). Returns the substituted
    /// return; a param that did not solve stays a `.type_param`, so the caller falls back to the erased
    /// type and nothing regresses.
    fn freeFnReturn(
        self: *Inferer,
        fid: types.SymbolId,
        fd: *const ast.FunctionDecl,
        ret_tr: ast.TypeRef,
        arg_types: []const TypeId,
    ) !?TypeId {
        // Lower the return AND the params in the CALLEE's scope, so `T` is its parameter (not the
        // caller's, where it would fail to resolve).
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
            const dp = try self.lowerer.lower(tr); // declared param type, in the callee's scope
            subst.solveParams(self.store, dp, arg_types[i], fid, solved);
        }

        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;
            out = try subst.substituteOne(self.store, out, fid, @intCast(i), bound);
        }
        return out;
    }

    // H2: record an unguarded member access on a `T | undefined` receiver (bare `x.field` /
    // `x.m()`, NOT `?.`/`??`/narrowed). A hard error surfaced at end of sema. NOVA_OPT_AUDIT=1
    // additionally prints each site (the migration tool that drove the stdlib to `at()`/`?.`).
    fn recordOptDeref(self: *Inferer, fa: ast.FieldAccess, is_method: bool, kind: OptDerefKind) void {
        if (std.c.getenv("NOVA_OPT_AUDIT") != null)
            std.debug.print("OPT-SEETHROUGH {s} {s}:{d}:{d} .{s}\n", .{ if (is_method) "method" else "field", fa.span.file, fa.span.line, fa.span.col, fa.field });
        self.optional_deref_errors.append(self.allocator, .{ .span = fa.span, .field = fa.field, .is_method = is_method, .kind = kind }) catch {};
    }

    fn fieldType(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        // inferExpr already counted the object; this is a lookup, not a new expr.
        self.stats.typed -|= 1;
        const t = self.store.get(obj);
        // H2: a bare `x.field` where `x` is `T | undefined` is a HARD ERROR (specs §3.4) — no
        // silent see-through. Record it; leave `t` optional so the member does not resolve
        // (sema aborts with the located diagnostic before codegen). The value must be made
        // present first: `x.at(i)` / `x ?? d` / `x?.field` / `if (x != undefined) { x.field }`.
        if (t == .optional) {
            self.recordOptDeref(fa, false, .opt);
            return null;
        }
        // H2/E1: `x.field` where `x` is `T | E` (error union) — the value might BE the error.
        // Handle it first (`try x` / `x catch …`); no silent see-through to the ok side.
        if (t == .error_union) {
            self.recordOptDeref(fa, false, .err);
            return null;
        }
        if (t != .struct_) return null;
        const sym = self.symtab.symbolAt(t.struct_.decl);
        if (sym.decl != .struct_) return null;
        for (sym.decl.struct_.fields) |f| {
            // `Box<string>.v` is string, not `T`. Fields need the same scope-and-
            // substitute treatment as method returns; this lowered the declared type
            // under the ambient scope and never substituted, so every field of a
            // generic type was unresolved — `Map`'s `hashFn: (K) -> int` included.
            if (std.mem.eql(u8, f.name, fa.field)) {
                return try self.lowerInStructScope(t.struct_, f.type_name);
            }
        }
        return null;
    }

    /// Is `fa.object` a module rather than a variable? Only then may `fa.field`
    /// name a function.
    fn moduleOfObject(self: *Inferer, fa: ast.FieldAccess) ?symbols.ModuleId {
        if (fa.object.kind != .ident) return null;
        const name = fa.object.kind.ident;
        if (self.lookup(name) != null) return null; // it is a variable — F1's guard
        // F1-4: prefer the IMPORT-SCOPED resolution — which module did THIS module import under
        // `name`? — over the global segment reconstruction. The reconstruction stays as the fallback
        // for a body whose module has no recorded import of `name` (e.g. the root program, or a name
        // reached transitively), so this is additive: it only ever RESOLVES a name the scan left
        // ambiguous (the ycsb `client` case), never changes a name the scan already resolved uniquely.
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name)) |mid| return mid;
        }
        return self.symtab.findModuleBySegment(name);
    }

    /// `const X = <expr>` — the constant's type is its initialiser's type.
    /// Const decls were in the symbol table all along; nothing looked them up.
    ///
    /// Consts reference each other (`const SECONDS_PER_HOUR = SECONDS_PER_MINUTE *
    /// MINUTES_PER_HOUR;`), so this recurses — bounded by depth, because a cyclic
    /// `const A = B; const B = A;` would otherwise recurse forever. Bounded, not
    /// hoped-for.
    fn constType(self: *Inferer, name: []const u8) !?TypeId {
        if (self.const_depth > 8) return null;
        for (self.symtab.symbols.items) |sym| {
            if (sym.kind != .constant) continue;
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (sym.decl != .constant) return null;
            // F1-4 (consts): a cross-module reference to a non-pub const is a visibility violation.
            // Located at the const's declaration (expressions carry no span). Dedup by name.
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
            // The initialiser is not an expression of the PROGRAM at this site —
            // it is counted where it is declared. Undo the accounting.
            self.stats.typed = before;
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return null;
    }

    /// `s.length` / `s.len` on a string. A builtin property, not a struct field.
    fn stringProperty(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (!std.mem.eql(u8, fa.field, "length") and !std.mem.eql(u8, fa.field, "len")) return null;
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1; // the object is a sub-expression, already counted
        if (self.store.get(obj) != .string) return null;
        return try self.store.intT();
    }

    /// `bytes.alloc(n)` / `console.log(s)` — builtins have no .nova declaration
    /// (they are hardcoded in codegen), so they resolve against the signature table
    /// instead. Same "is the object a variable" guard as everywhere else.
    fn builtinCallReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null; // a variable shadows the builtin
        if (!builtins.isReceiver(recv)) return null;
        const b = builtins.find(recv, fa.field) orelse return null;
        return try builtins.retType(self.store, b.ret);
    }

    /// F1-4: resolve `recv.field` — a module function — IMPORT-SCOPED first. If this body's module
    /// imported a module under `recv`, look the function up in THAT module (findFunctionIn); only if
    /// no such import is recorded fall back to the global segment search (findFunctionBySegment, which
    /// goes null on a 2-module ambiguity). Additive: it resolves the ambiguous case the scan couldn't,
    /// and agrees with the scan when the name was unique.
    /// F1-4 (types): record a cross-module reference to a NON-pub type as a visibility violation.
    /// Robust — decided from the RESOLVED symbol's defining module vs the current module, so it needs
    /// no module qualifier (the parser discards it for types anyway). Same-module use (sym.module == cm)
    /// is always allowed; a name that resolves to no type, or to a public one, is fine. shadow.run
    /// reports + aborts, exactly like the function check.
    fn recordTypeVis(self: *Inferer, name: []const u8, span: ast.Span) void {
        // Compiler-generated code (serde `<S>__bind`/`__toJson`, mediator dispatch)
        // is emitted into synthetic `<…-generated>` files but is part of the same
        // compilation unit, so it may reference the user's non-pub types.
        if (span.file.len > 0 and span.file[0] == '<') return;
        const cm = self.current_module orelse return;
        const sid = self.symtab.findTypeInModule(name, self.current_module) orelse return;
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;
        // Dedup: the same annotation can be lowered more than once (value + type positions).
        if (self.visibility_errors.items.len > 0) {
            const last = self.visibility_errors.items[self.visibility_errors.items.len - 1];
            if (last.span.line == span.line and last.span.col == span.col and std.mem.eql(u8, last.field, name)) return;
        }
        self.visibility_errors.append(self.allocator, .{ .span = span, .recv = "", .field = name, .kind = .type_ }) catch {};
    }

    /// Walk a type annotation and check every NAMED type it mentions for cross-module visibility
    /// (recurses through optional / error-union / array / generic / func / tuple).
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

    fn resolveModuleFn(self: *Inferer, recv: []const u8, field: []const u8, span: ast.Span) ?types.SymbolId {
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, recv)) |mid| {
                if (self.symtab.findFunctionIn(mid, field)) |sid| {
                    self.recordFnVisibility(sid, cm, recv, field, span);
                    return sid;
                }
            }
        }
        // Fallback: the global segment search. This path was the multi-segment-import VISIBILITY HOLE —
        // it resolved a cross-module function WITHOUT the visibility check the import-edge path does, so a
        // non-`pub` function was callable from another module (types/consts were enforced; functions were
        // not). The separator-normalization fix to findModuleByImportName makes the edge path fire for
        // multi-segment imports too, but this fallback still runs for segment-only resolution, so it must
        // enforce visibility identically: resolve, then reject a cross-module non-pub target the same way.
        if (self.symtab.findFunctionBySegment(recv, field)) |sid| {
            if (self.current_module) |cm| self.recordFnVisibility(sid, cm, recv, field, span);
            return sid;
        }
        return null;
    }

    /// F1-4 visibility: record a cross-module call to a NON-pub function as a violation (shadow.run
    /// reports + aborts). Same-module access (sym.module == cm) is always allowed. Shared by the
    /// import-edge path and the segment fallback so BOTH enforce visibility uniformly.
    fn recordFnVisibility(self: *Inferer, sid: types.SymbolId, cm: symbols.ModuleId, recv: []const u8, field: []const u8, span: ast.Span) void {
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;
        // Dedup: the same call is probed as both a call (moduleCallReturn) and a value (moduleFnValue),
        // so record each violation site once.
        const dup = self.visibility_errors.items.len > 0 and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.line == span.line and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.col == span.col;
        if (!dup) self.visibility_errors.append(self.allocator, .{ .span = span, .recv = recv, .field = field }) catch {};
    }

    /// F2-5: is a bare `.unresolved` ident a GENUINE undefined identifier (fatal), or a legitimate
    /// non-value name (a namespace, a container type the symbol table doesn't hold, a runtime extern)?
    fn isFatalUnresolvedIdent(self: *Inferer, name: []const u8) bool {
        if (std.mem.eql(u8, name, "self")) return false;
        // Runtime externs declared in no .nova file (`nova_concurrency_sleep`, `nova_sha256`, ...).
        if (std.mem.startsWith(u8, name, "nova_")) return false;
        // Magic builtin namespaces (extern receivers: `bytes.alloc`, `console.log`). `fiber` is the
        // concurrency namespace — `fiber.sleep(ms)` / `fiber.spawn(f)` are codegen builtins (is_sleep,
        // spawn) with no .nova declaration, so the checker must not flag the receiver as undefined.
        const magic = [_][]const u8{ "bytes", "console", "sync", "atomic" };
        for (magic) |m| if (std.mem.eql(u8, name, m)) return false;
        // Any receiver declared in the builtin signature table is a valid namespace, not a value
        // (`decimal.fromInt`, etc.) — exempt it the same way, and stay in sync with the table.
        if (builtins.isReceiver(name)) return false;
        // Container/runtime TYPE names that are store types, not symbol-table structs.
        const builtin_types = [_][]const u8{ "Storage", "Atomic" };
        for (builtin_types) |t| if (std.mem.eql(u8, name, t)) return false;
        // A module used under this name (import-scoped first, then global).
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name) != null) return false;
        }
        if (self.symtab.findModuleByImportName(name) != null) return false;
        if (self.symtab.findModuleBySegment(name) != null) return false;
        return true;
    }

    /// `string.hash(x)` -> hash's return type.
    fn moduleCallReturn(self: *Inferer, fa: ast.FieldAccess, out_sym: *?types.SymbolId) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null; // a variable — F1's guard
        // Search EVERY module used under this segment: ycsb imports both
        // net.tcp.client and data.btree.client, so `client` is ambiguous and
        // first-match-wins picked the wrong one (31 expressions).
        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;
        // F1-3b: the module function is resolved to THIS symbol — surface it for the IR.
        out_sym.* = sid;
        if (sym.decl.function.ret_type) |r| {
            const t = try self.lowerer.lower(r);
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return try self.store.voidT();
    }

    /// `string.hash` as a value -> its function type.
    fn moduleFnValue(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;
        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;
        return try self.fnType(sym.decl.function);
    }

    /// The return type of `recv.method(...)`.
    ///
    /// For a generic receiver this is where F4's join happens: `get`'s declared
    /// return is `T`, and the receiver knows T := string. Both halves already
    /// existed — `List<string>` and `List<int>` are distinct TypeIds, and `T`
    /// lowers to `.type_param{List, 0}` — but nothing put them together, so every
    /// `list.get(i)` was `.unresolved` and everything downstream with it.
    /// `Point.origin()` — a STATIC/associated method call, where the receiver is a
    /// struct/enum TYPE NAME (not a value). Returns the method's declared return type.
    /// Distinct from methodReturn, which infers the receiver as a value and so only sees
    /// instance calls. Without this, static factory results are `unresolved`.
    fn staticMethodReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        // The receiver names a struct/enum TYPE, either bare (`Point.origin()`) or
        // module-qualified (`client.TcpClient.connect()` — object is `client.TcpClient`,
        // a field access whose FIELD is the struct name). Take the last component.
        const type_name = switch (fa.object.kind) {
            .ident => |n| n,
            .field_access => |ofa| ofa.field,
            else => return null,
        };
        // The object must name a declared TYPE (else it is a module/variable, handled
        // elsewhere). A variable that shadows a type name is inferred as a value by
        // methodReturn first, so reaching here means it is genuinely the type.
        _ = self.symtab.findTypeInModule(type_name, self.current_module) orelse return null;
        const mid = self.symtab.findMethod(type_name, fa.field) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();
        const lowered = try self.lowerer.lower(ret);
        if (self.store.get(lowered) == .unresolved) return null;
        return lowered;
    }

    fn methodReturn(self: *Inferer, fa: ast.FieldAccess, args: []const ast.Expression, out_sym: *?types.SymbolId, call_ep: *const ast.Expression) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        const t = self.store.get(obj);
        // A method call on an OPTIONAL receiver (`list.get(i).field`, `map.get(k).method()`)
        // sees through to the underlying type — `.get` returns `T | undefined`, and without
        // this every `let x = xs.get(i); x.m()` failed to resolve `x`'s type (only the
        // `?? default` form worked, which coalesces the optional away). The runtime handle is
        // H2: a bare `x.method()` where `x` is `T | undefined` is a HARD ERROR (specs §3.4).
        // Record it and stop resolving; make the value present first (`at`/`??`/`?.`/narrow).
        if (t == .optional) {
            self.recordOptDeref(fa, true, .opt);
            return null;
        }
        if (t == .error_union) {
            self.recordOptDeref(fa, true, .err);
            return null;
        }
        // A TRAIT receiver: `src.getString(key)` where `src: ValueSource`. The trait
        // IS the contract, so the method is looked up in the trait's own decl —
        // symbols.zig registers the trait but not its methods. Never fall through to
        // a struct that happens to have the same method name.
        if (t == .trait_) return try self.traitMethodReturn(t.trait_, fa.field);
        // `Storage<T>` is a PRIMITIVE (specs.md §3.8) — a `.storage`, not a `.struct_`
        // — so there is no declaration for the struct path below to find a method on,
        // and it answered `null` for every `s.get(i)` / `s.set(i, v)`. §3.8 has
        // specified both since it was written; sema typed only the CONSTRUCTOR (~line
        // 633) and stayed silent about the rest.
        //
        // That silence LEAKED. An untyped `let` is never recorded in `local_types`, so
        // it is never an OWNED local, so ARC never releases it: `let key =
        // oldKeys.get(i)` in `Map.resize` retains (+1 — `Storage.get` transfers) and
        // nothing gave it back. Proven by printing `local_types` for
        // `Map_string_i32_resize`: `key`/`val`/`cur` were ABSENT while `tomb`/`hash`/
        // `nt` at the same and deeper nesting were present — the missing ones were
        // exactly the `<storage>.get(..)` initialisers.
        //
        // ⚠️ This could not land until closures were monomorphized (§3.4d). The leak
        // was PAYING for a missing retain: the closure in `Map.keys()` was emitted
        // erased and called `List_push` (retain=0), so removing the leak alone turned
        // a balanced accident into a double free.
        if (t == .storage) {
            if (std.mem.eql(u8, fa.field, "get")) return t.storage; // the slot's T
            if (std.mem.eql(u8, fa.field, "set")) return try self.store.voidT();
            return null;
        }
        if (t != .struct_) return null;
        const owner = self.symtab.symbolAt(t.struct_.decl);
        const mid = self.symtab.findMethod(owner.name, fa.field) orelse return null;
        // F1-3b: the method is resolved to THIS symbol — surface it so the caller records it in the
        // IR (codegen can then resolve `recv.method(...)` by SymbolId, not the func_map scan).
        out_sym.* = mid;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();

        const fd0 = m.decl.function;
        const sub = try self.lowerInMethodScope(t.struct_, mid, fd0, ret);

        // F4 type-ARGUMENT inference. The receiver's args gave T; a method's OWN
        // params (`map<U>`) are still unbound, and they come from the ARGUMENTS:
        //
        //     List<int>.map<U>(fn: (T) => U)  called with  (x) => x * 2
        //     declared (int) => U   vs   actual (int) -> int   =>   U := int
        //
        // Without this, `xs.map(...)` is `List<unresolved>` — the last thing
        // standing between here and deleting the legacy resolver.
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
            // Pass `dp` as the EXPECTED type. A closure arg `(x) => ...` has no
            // annotation on `x`, so inferring it in a vacuum yields `.unresolved`
            // params and the solve learns nothing about U. Handing the declared
            // `(T) -> U` down pins the closure's params, so its body types and U
            // solves — the difference between `xs.map(f)` being `List<U>` (erased)
            // and `List<string>` (a real instantiation).
            //
            // F2-6: inferExprExpecting, not inferExprQuietly — a method call's args are inferred
            // ONLY here (the .call arm returns as soon as methodReturn yields a type; there is no
            // later "real walk" of them), so this IS their walk and its results MUST be recorded.
            // Recording pins the closure body's types in the IR — the interpolation part `${s}` in
            // `xs.map(f).map(g)`'s `g` now types `string` from the receiver's T, so codegen reads
            // typeOf() instead of the findLambdaCallSite scan. In the `typeOfObjectQuietly` probe
            // context `self.ir` is null, so this still records nothing there (record checks ir).
            const actual = try self.inferExprExpecting(&args[i], dp);
            subst.solveParams(self.store, dp, actual, mid, solved);
        }

        // Only substitute what was actually solved. An unsolved param stays itself,
        // so the result is `.unresolved` rather than a confident wrong answer.
        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;
            // Index i ONLY: `substitute` takes a positional slice, which cannot say
            // "solve U but not V" — a partially-solved signature would shift the
            // unsolved params into the wrong slots. Solving is incremental, so
            // substitution is too.
            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }
        // F4-5 Phase 1: record the method instantiation when EVERY method param solved to a
        // concrete type. An abstract residue (a method param solved to another param, e.g. calling
        // `map<U>` from inside another generic) is not a monomorphizable instantiation — skip it,
        // the erased body still serves it. See docs/design/F4-method-monomorphization.md.
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
                // F4-5 Phase 2a: also record the specialized (receiver-inst × method × args) into the
                // codegen worklist. `obj` is the receiver instantiation TypeId, `fa.field` the method,
                // `fd.type_params` its own params (["U"]), `buf` the solved concrete args. Rendered +
                // deduped in mono.noteMethodInst. Codegen emits one body per entry.
                mono.noteMethodInst(self.store, obj, fa.field, fd.type_params, buf);
                // This is the INFERRED-arg path (`xs.map(..)`), which routes to the method-erased
                // base body — so that base must be emitted. (Explicit-arg calls route to a
                // specialization instead; see explicitMethodReturn, which does NOT mark this.)
                mono.noteBaseNeeded(self.store, obj, fa.field);
            }
        }
        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    /// Explicit-type-arg method call: `recv.method<Concrete...>(args)`. The dual of
    /// `methodReturn`, which SOLVES a method's own params from the argument types — here the
    /// type args are given at the call site, so they populate `solved` directly. Records the
    /// (receiver-instantiation × method × concrete-args) tuple into the method-mono worklist so
    /// codegen emits ONE specialized body per instantiation, and returns the substituted return
    /// type. This is what makes `app.get<GetUser>(path)` a real generic method (method-level
    /// monomorphization) rather than a codegen call-site intercept.
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
        const mid = self.symtab.findMethod(owner.name, fa.field) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const fd = m.decl.function;
        // Arity must match — `get<GetUser>` on a `get<T>` (1 == 1). A mismatch is not this
        // construct; let the caller fall through to its unresolved path.
        if (fd.type_params.len == 0 or fd.type_params.len != type_args.len) return null;
        out_sym.* = mid;
        // Infer the value args too, so their subexpressions are recorded in the IR — WITH each arg's
        // declared parameter type as the expected type, so a CLOSURE argument gets its parameter types
        // from the method signature (`app.handleFrom<T>((sp) => sp.require(..))` types `sp` as
        // `ServiceProvider`). Plain `inferExpr(a)` here re-inferred with NO expectation and OVERWROTE
        // the generic_call arm's propagation, leaving the closure params unresolved and a method call
        // through them (`sp.require`) failing at codegen. Mirrors `calleeParamTypes` for non-generic
        // calls. (Params that reference the method's OWN type args are the uncommon case; here they
        // lower with those params unsubstituted, which is no worse than the prior no-expectation walk.)
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

        // Substitute the method's params positionally into the return type, in the method's
        // scope (which also binds the receiver's own T). Mirrors methodReturn's tail.
        var out = try self.lowerInMethodScope(t.struct_, mid, fd, ret);
        for (solved, 0..) |bound, i| {
            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }

        // Record the specialized body — ONLY when every type arg is concrete (an abstract
        // residue, e.g. `get<T>` called from inside another generic, is served by the erased
        // body). Same discipline as methodReturn's noteMethodInst gate.
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
                mono.noteMethodInst(self.store, obj, fa.field, fd.type_params, solved);
            }
        }

        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    /// Infer `branch` with `narrow` applied if this is the branch where the test
    /// holds. The narrowed binding is pushed in its own scope, so it cannot leak
    /// past the branch (specs.md 3.4a).
    fn narrowedBranch(self: *Inferer, narrow: ?Narrowing, is_then: bool, branch: *const ast.Statement) anyerror!void {
        const n = narrow orelse return self.inferStmt(branch);
        if (n.when_true != is_then) return self.inferStmt(branch); // wrong branch
        const cur = self.lookup(n.name) orelse return self.inferStmt(branch);
        const t = self.store.get(cur);
        if (t != .optional) return self.inferStmt(branch); // nothing to unwrap
        try self.push();
        defer self.pop();
        try self.bind(n.name, t.optional);
        try self.inferStmt(branch);
    }

    /// The DECLARED parameter types of whatever `callee` names, with the receiver's
    /// type arguments already substituted — `Map<string,int>.forEach` expects
    /// `(string, int) -> void`, not `(K, V) -> void`. Caller owns the slice.
    ///
    /// Returns null when the callee is not a known declaration; that is not a
    /// failure, just an absence of expectation.
    fn calleeParamTypes(self: *Inferer, callee: *const ast.Expression) !?[]TypeId {
        switch (callee.kind) {
            .ident => |n| {
                const sid = self.symtab.findFunction(n) orelse return null;
                const sym = self.symtab.symbolAt(sid);
                if (sym.decl != .function) return null;
                return try self.paramTypesOf(sym.decl.function, null);
            },
            .field_access => |fa| {
                // A METHOD on a struct receiver. Only then are the params worth
                // substituting; a module fn (`string.hash`) has no type args.
                const obj = self.typeOfObjectQuietly(fa.object) orelse return null;
                const t = self.store.get(obj);
                if (t != .struct_) return null;
                const owner = self.symtab.symbolAt(t.struct_.decl);
                const mid = self.symtab.findMethod(owner.name, fa.field) orelse return null;
                const m = self.symtab.symbolAt(mid);
                if (m.decl != .function) return null;
                return try self.paramTypesOf(m.decl.function, t.struct_);
            },
            else => return null,
        }
    }

    /// Lower a declaration's parameter types, substituting `recv`'s args if given.
    /// `self` params are skipped: `forEach(self, fn)` is called as `m.forEach(fn)`,
    /// so the declared list is one longer than the argument list.
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

    /// The object's type WITHOUT recording it — this runs before the argument walk
    /// and must not double-count or re-record what inferExpr already handled.
    ///
    /// Handles a plain variable (`m.forEach`) AND a field-access receiver
    /// (`self.headers.forEach`): without the field-access arm, calleeParamTypes returned
    /// null for a method called on a FIELD, so the closure passed to it (`(key, value) =>
    /// key + ": " + value`) got NO expected param types — its params inferred as unresolved
    /// (machine word), and codegen then numToString'd the string key/value (garbage HTTP
    /// header lines from web.response.serialize's `self.headers.forEach`). Resolving the
    /// field type here (quietly, via lowerInStructScope — no IR recording) types the params.
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

    /// The return type of a method declared by a trait. Traits are not generic
    /// today (ast.TraitDecl has no type_params), so there is nothing to substitute.
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

    /// The type a parameter is pinned to by its use in `body` — specs.md 6.3a.
    ///
    /// DELIBERATELY NARROW: a parameter used as one side of a binary whose OTHER
    /// side has a known type takes that type. `(x) => x + 1` gives int;
    /// `(a, b) => a + b` gives nothing, because "these are addable" needs type
    /// variables and a solver, not propagation. Returning null there is the honest
    /// answer — guessing int would be the machine-word lie in a new place.
    ///
    /// Comparisons are excluded: `(x) => x == 0` pins x to int, but `(x) => x == y`
    /// where y is a string would too, and the operator does not require the operands
    /// to be the same type as the RESULT. Only arithmetic is safe to read backwards.
    fn paramFromUse(self: *Inferer, param: []const u8, body: ast.ClosureBody) anyerror!?TypeId {
        return switch (body) {
            .expr => |e| try self.paramFromUseExpr(param, e),
            // A block body would need a statement walk; the shapes that matter are
            // expression bodies. Recorded rather than half-done.
            .block => null,
        };
    }

    fn paramFromUseExpr(self: *Inferer, param: []const u8, e: *const ast.Expression) anyerror!?TypeId {
        switch (e.kind) {
            .binary => |b| {
                switch (b.op) {
                    .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or => {},
                    // Not a pinning operator, but a param can still be pinned DEEPER
                    // in either side — `(x) => (a * x) == 0`.
                    else => return (try self.paramFromUseExpr(param, b.left)) orelse
                        try self.paramFromUseExpr(param, b.right),
                }
                const l_is = b.left.kind == .ident and std.mem.eql(u8, b.left.kind.ident, param);
                const r_is = b.right.kind == .ident and std.mem.eql(u8, b.right.kind.ident, param);
                if (l_is != r_is) {
                    const other = if (l_is) b.right else b.left;
                    const t = try self.inferExprQuietly(other, null);
                    if (self.store.get(t) != .unresolved) return t;
                    // fall through: the other side is unknown, but a nested use may pin it
                }
                // `a * x + b` — the top binary is `+` over `a*x` and `b`, so x is not
                // an operand HERE. Recurse, or every non-trivial body pins nothing.
                return (try self.paramFromUseExpr(param, b.left)) orelse
                    try self.paramFromUseExpr(param, b.right);
            },
            .unary => |u| return try self.paramFromUseExpr(param, u.operand),
            else => return null,
        }
    }

    /// Infer without recording or counting: this is a PROBE, run before the real
    /// walk. Recording here would put the pre-improvement type in the IR and then
    /// the walk would overwrite it — twice the work and one chance to leave the
    /// wrong one behind.
    fn inferExprQuietly(self: *Inferer, e: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const saved_ir = self.ir;
        const saved = self.stats.typed;
        self.ir = null;
        defer {
            self.ir = saved_ir;
            self.stats.typed = saved;
        }
        return self.inferExprInner(e.*, expected);
    }

    pub fn inferBlock(self: *Inferer, b: *const ast.Block) anyerror!void {
        try self.push();
        defer self.pop();
        try self.inferStmtSeq(b.statements);
    }

    /// Walk a statement sequence, applying EARLY-EXIT NARROWING between statements
    /// (specs.md §3.4a): after `if (x == undefined) { return; }` (a guard whose branch
    /// cannot fall through), `x` is `T` — not `T | undefined` — for the rest of the block.
    /// This is the idiom the H2 soundness rule pushes people toward, so it must typecheck:
    ///   `let h = m.get(k); if (h == undefined) { return notFound; } h.method();`  // h: T here
    pub fn inferStmtSeq(self: *Inferer, statements: []ast.Statement) anyerror!void {
        for (statements, 0..) |*s, idx| {
            try self.inferStmt(s);
            if (earlyExitNarrowing(s)) |n| {
                const cur = self.lookup(n.name) orelse continue;
                const t = self.store.get(cur);
                if (t == .optional) {
                    // Narrow for the REST of this block, in a FRESH shadowing scope so the
                    // narrowing (a) is found first by lookup and (b) is popped at block end —
                    // never leaking past a nested guard (`while (…) { if (x==undefined) break; }`).
                    try self.push();
                    defer self.pop();
                    try self.bind(n.name, t.optional);
                    try self.inferStmtSeq(statements[idx + 1 ..]);
                    return;
                }
            }
        }
    }

    /// Takes a POINTER, and that is not cosmetic. With `s: ast.Statement` the
    /// switch captures point into a stack COPY, so every address recorded into the
    /// TypedIr would be a dangling stack slot — `typeOf` would silently miss and
    /// the table would look empty-ish rather than wrong. Pointer-keyed identity
    /// forces the whole walk to be by-reference.
    pub fn inferStmt(self: *Inferer, sp: *const ast.Statement) anyerror!void {
        switch (sp.*) {
            .block => |*b| try self.inferBlock(b),
            .let_stmt => |*ls| {
                var t: TypeId = undefined;
                if (ls.type_name) |declared| {
                    t = try self.lowerer.lower(declared);
                    self.checkTypeRefVis(declared, ls.span); // F1-4: `let s: mod.PrivateType` cross-module
                    // Plumb the declared type as the EXPECTED type so a tuple literal element
                    // whose slot is a trait (`let p: (int, G) = (1, A{})`) is typed AS the trait
                    // on the tuple's TypeId — codegen then widens the struct to the trait object.
                    // Without this the literal is typed by its elements `(int, A)` and a raw struct
                    // lands in the trait slot → garbage vtable → SEGV. Same seam as the return path.
                    if (ls.init) |*i| _ = try self.inferExprExpecting(i, t);
                } else if (ls.init) |*i| {
                    t = try self.inferExpr(i);
                } else {
                    t = try self.store.unresolvedT();
                }
                // `let (a, b) = f()` — bind EACH name to its element type.
                //
                // This bound only `ls.name`, which for a destructuring `let` is the empty string
                // (parser.zig sets it and never overwrites it) — so every destructured binding was
                // `.unresolved` and nothing downstream could type it. The damage was not confined
                // to sema: rebuilding a tuple out of destructured locals (`let (a,b) = f(); let t =
                // (b,a);`) rendered `t` as `(unresolved,unresolved)`, so its generated destructor
                // released two elements that construction — resolving each to null — had never
                // retained. An over-release, i.e. a use-after-free, from a missing bind.
                //
                // Arity mismatch binds `.unresolved` rather than guessing: the checker cannot yet
                // report it (it never reads `ls.names` — expect_fail/PENDING.md), and silently
                // pairing off a 3-name pattern against a 2-tuple would type the third from thin air.
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
                _ = try self.inferExpr(&i.condition);
                // specs.md 3.4a: comparing a binding against `undefined` narrows it
                // in the branch where the test holds. Without this the idiom the
                // spec itself prescribes — `if (s != undefined) { use(s); }` — does
                // not typecheck, because a member of an optional is never
                // auto-unwrapped (and must not be: that is the null deref optionals
                // exist to prevent).
                const narrow: ?Narrowing = if (i.condition.kind == .binary)
                    narrowedBinding(i.condition.kind.binary)
                else
                    null;

                try self.narrowedBranch(narrow, true, i.then_branch);
                if (i.else_branch) |e| try self.narrowedBranch(narrow, false, e);
            },
            .while_stmt => |*w| {
                _ = try self.inferExpr(&w.condition);
                try self.inferStmt(w.body);
            },
            .for_stmt => |*f| {
                try self.push();
                defer self.pop();
                // C-style `for (init; cond; incr)` — the initialiser binds in this scope.
                if (f.initializer) |i| try self.inferStmt(i);
                if (f.condition) |*c| _ = try self.inferExpr(c);
                if (f.increment) |*inc| _ = try self.inferExpr(inc);
                // for-in `for (x in iterable)` — infer the iterable, then bind the loop variable so the
                // body can name it. A range binds `int`; a container's element type is a follow-up
                // (collection for-in is not codegen'd yet), so it binds `.unresolved` for now.
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
                    // Bind `case E.Variant(k):` payloads BEFORE inferring the case values: the value
                    // `E.Variant(k)` is a PATTERN, and `k` is a binding target, not a use. Inferring it
                    // first left `k` unbound -> `.unresolved` (harmless for the body, which rebinds, but
                    // it is a phantom untyped ident that would trip the F2-5 fatal check).
                    // `case E.Variant(k):` — BIND `k` to the variant's declared payload type.
                    //
                    // The payload binding is the ONLY place `k` is ever introduced — so without it `k`
                    // had no type and codegen fell back to int. The value was right (`return k;` gave
                    // "Logger") but `"not found: " + k` stringified the POINTER: `not found:
                    // 4299572560`. Exactly the destructuring-bind gap in another costume.
                    try self.bindSwitchPayloads(disc_t, c);
                    for (c.values) |*v| _ = try self.inferExpr(v);
                    try self.inferStmt(c.body);
                }
                if (sw.default_case) |d| try self.inferStmt(d);
            },
            .return_stmt => |*r| {
                // Return position is an expected type too — see `current_ret`.
                if (r.value) |*v| {
                    const rt = try self.inferExprExpecting(v, self.current_ret);
                    // Captured HERE, while the returned expr's locals are still bound. A braced
                    // closure reads this after inferBlock instead of re-inferring the return (which
                    // would run after the block's scope was popped and mis-type `return r.field`).
                    if (self.store.get(rt) != .unresolved) self.captured_return = rt;
                }
            },
            .defer_stmt => |*d| _ = try self.inferExpr(&d.expr),
.break_stmt, .continue_stmt => {},
        }
    }

    /// Bind each `case E.Variant(name):` payload name to the variant's declared payload type.
    ///
    /// Quiet no-op unless the discriminant is a known enum and the case value is a
    /// `E.Variant(ident)` call — anything else (an int case, a bare `E.Variant` with no payload,
    /// a non-ident argument) leaves bindings untouched rather than guessing.
    fn bindSwitchPayloads(self: *Inferer, disc_t: TypeId, c: *const ast.SwitchCase) anyerror!void {
        const dt = self.store.get(disc_t);
        if (dt != .enum_) return;
        const sym = self.symtab.symbolAt(dt.enum_);
        if (sym.decl != .enum_) return;
        const enum_decl = sym.decl.enum_;
        for (c.values) |v| {
            switch (v.kind) {
                // TUPLE payload: `case E.Variant(k):` -> bind `k` to the variant's single payload type.
                .call => |call| {
                    if (call.callee.kind != .field_access) continue;
                    const variant_name = call.callee.kind.field_access.field;
                    for (enum_decl.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, variant_name)) continue;
                        const payload_ref = variant.type_name orelse break;
                        if (call.args.len == 0) break;
                        if (call.args[0].kind != .ident) break;
                        try self.bind(call.args[0].kind.ident, try self.lowerer.lower(payload_ref));
                        break;
                    }
                },
                // STRUCT payload: `case E.Variant{ f: nm, g: cnt }:` -> bind each destructured field
                // name to the variant field's declared type. The value's `type_name` may be the bare
                // variant (`Pair`) or enum-qualified (`Boxed.Pair`); match on the last segment.
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

    pub fn inferFunction(self: *Inferer, f: *const ast.FunctionDecl) !void {
        return self.inferFunctionWithSelf(null, f);
    }

    /// `self_ty` is the owning struct's type, for methods and constructors.
    ///
    /// A method declares `self` explicitly (`pub fn push(self: List<T>, ...)`), so
    /// it binds like any param. A CONSTRUCTOR does not — `init(initialCap: int,
    /// hashFn: (K) -> int)` takes no `self`, yet its body is `self.cap = cap`
    /// (map.nova:38). `self` is implicit there, and the parser routes init through
    /// a separate branch (parser.zig:470) that never adds it. So every `self` in
    /// every constructor body was unbound — 43 expressions on ycsb, the single
    /// largest remaining name.
    pub fn inferFunctionWithSelf(self: *Inferer, self_ty: ?TypeId, f: *const ast.FunctionDecl) !void {
        try self.push();
        defer self.pop();
        // Saved/restored rather than just set: a closure body is inferred INSIDE the
        // enclosing function's walk, and leaving this pointing at the outer fn's
        // return type would hand the wrong expectation to any `return` inside it.
        // F1-4 / module-scoped types: set the owning module FIRST — the return type and param types
        // lowered below resolve bare type names in THIS module's scope (a colliding `Widget` → the local
        // one). The lowerer reads `current_module`, so mirror it there for the duration of this body.
        const saved_module = self.current_module;
        defer self.current_module = saved_module;
        self.current_module = self.symtab.findModuleByFile(f.span.file);
        const saved_lowerer_module = self.lowerer.current_module;
        defer self.lowerer.current_module = saved_lowerer_module;
        self.lowerer.current_module = self.current_module;
        // Saved/restored rather than just set: a closure body is inferred INSIDE the
        // enclosing function's walk, and leaving this pointing at the outer fn's
        // return type would hand the wrong expectation to any `return` inside it.
        const saved_ret = self.current_ret;
        defer self.current_ret = saved_ret;
        self.current_ret = if (f.ret_type) |r| try self.lowerer.lower(r) else null;
        if (self_ty) |t| try self.bind("self", t);
        for (f.params) |p| {
            const t = if (p.type_name) |tn| try self.lowerer.lower(tn) else try self.store.unresolvedT();
            try self.bind(p.name, t); // an explicit `self` param shadows the implicit one
        }
        try self.inferStmtSeq(f.body.statements);
        // PASS 2 (F2-6 stage 2): now that the whole body is typed, re-type any bound closure whose
        // parameter could not be inferred from its own body, using the types of the arguments at its
        // CALL SITE. A closure's param type comes from AFTER its definition (spec 6.3a) — single-pass
        // top-to-bottom inference cannot see it, which is why codegen kept a call-site SCAN. This is
        // that scan, in the checker: it makes typeOf() complete for `let g = (x) => …; g(5)` (x -> int),
        // so codegen reads the type instead of guessing, and the closure itself types as `.func`.
        try self.closureSecondPass(&f.body);
    }

    /// F2-6 stage 2 — re-type bound closures from their call sites. Top-level `let name = <closure>`
    /// in the function body; the call `name(args)` is searched function-wide.
    fn closureSecondPass(self: *Inferer, fn_body: *const ast.Block) anyerror!void {
        for (fn_body.statements) |*s| {
            if (s.* != .let_stmt) continue;
            const ls = &s.let_stmt;
            const cl_init = if (ls.init) |*i| i else continue;
            if (cl_init.kind != .closure) continue;
            try self.retypeBoundClosure(fn_body, ls.name, cl_init);
        }
    }

    fn retypeBoundClosure(self: *Inferer, fn_body: *const ast.Block, name: []const u8, cl_init: *const ast.Expression) anyerror!void {
        const cl = cl_init.kind.closure;
        if (cl.params.len == 0) return;
        // Only re-type when a parameter is still unresolved — otherwise there is nothing to gain and a
        // needless re-walk risks churn. A closure whose param the body already pinned (`(x) => x + 1`)
        // is fully `.func` and skipped.
        if (self.ir) |ir| {
            if (ir.typeOf(cl_init)) |t| {
                if (self.store.get(t) == .func) {
                    const ft = self.store.get(t).func;
                    var any_unresolved = false;
                    for (ft.params) |pt| {
                        if (self.store.get(pt) == .unresolved) any_unresolved = true;
                    }
                    if (!any_unresolved) return;
                }
            }
        }
        const arg_types = (try self.findCallArgTypes(fn_body, name, cl.params.len)) orelse return;
        defer self.allocator.free(arg_types);
        // A wholly-unresolved arg set tells us nothing — leave the closure as pass 1 had it.
        var any_known = false;
        for (arg_types) |at| if (self.store.get(at) != .unresolved) { any_known = true; };
        if (!any_known) return;
        // Re-infer the closure with the call-site params as its EXPECTED type. The `want` mechanism
        // binds each param to `expected.params[i]`; the body re-infers with them and re-records into
        // the IR (record = put, so the pass-1 unresolved entries are overwritten). The RETURN is left
        // unresolved — the body determines it, exactly as at definition.
        const exp = try self.store.intern(.{ .func = .{ .params = arg_types, .ret = try self.store.unresolvedT() } });
        _ = try self.inferExprExpecting(cl_init, exp);
    }

    /// Find a `name(args)` call anywhere in `block` (function-wide: recurses into nested control-flow),
    /// and return each argument's inferred type. Caller owns the returned slice. Null when no such call.
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

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

const Fixture = struct {
    store: types.TypeStore,
    tab: symbols.SymbolTable,
    low: lower.Lowerer,

    fn init(a: std.mem.Allocator) Fixture {
        return .{
            .store = types.TypeStore.init(a),
            .tab = symbols.SymbolTable.init(a),
            .low = undefined,
        };
    }
    fn deinit(self: *Fixture) void {
        self.low.deinit();
        self.tab.deinit();
        self.store.deinit();
    }
};

test "infer: literals get honest types — an int literal is int, not the machine word" {
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

test "infer: a comparison is BOOL, not i32" {
    // The resolver types comparisons as i32 (roadmap A3), which is why the
    // condition-must-be-bool check would have flagged every `if`.
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

test "T4: a binary over two unknowns is UNRESOLVED, not i32" {
    // types.zig:457 answers `i32` here — a wrong answer wearing a valid type.
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
    // an unbound name is unresolved, not int
    var e_ghost = ast.Expression{ .kind = .{ .ident = "ghost" } };
    const u = try inf.inferExpr(&e_ghost);
    try testing.expect(f.store.get(u) == .unresolved);
}

/// Stamps ids the way the real pipeline does (main.zig runs sema/ids.zig right
/// after alpha, before inference). TypedIr refuses `.unassigned`, so a test that
/// skips this measures nothing.
///
/// Takes the Assigner rather than making one, because ONE assigner per program is
/// the invariant that makes ids unique. A fresh assigner per call restarts at 1
/// and hands out ids that collide — the first cut of this helper did exactly that
/// and made an un-inferred expression read back as another expression's type. The
/// "never inferred is absent" test below is what caught it.
fn stampIds(a: *ids.Assigner, exprs: []const *ast.Expression) void {
    for (exprs) |e| a.walkExpr(e) catch unreachable;
}

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

    // Two DISTINCT expressions that happen to have the same type must be two
    // entries — identity, not value. Keying by value would collapse them.
    var e1 = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var e2 = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{ &e1, &e2 });
    _ = try inf.inferExpr(&e1);
    _ = try inf.inferExpr(&e2);
    try testing.expectEqual(@as(usize, 2), ir.count());

    // ...and codegen's whole job here is to ASK rather than re-derive.
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e1).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e2).?);

    // An expression that was never inferred is absent — not silently `int`.
    var never = ast.Expression{ .kind = .{ .literal = .{ .integer = 3 } } };
    stampIds(&idg, &.{&never}); // same assigner => a DISTINCT id, not a collision
    try testing.expect(ir.typeOf(&never) == null);
}

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
    stampIds(&idg, &.{&add}); // walks operands too
    _ = try inf.inferExpr(&add);

    // root + both operands
    try testing.expectEqual(@as(usize, 3), ir.count());
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&l).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&add).?);
}

test "TypedIr: unresolvedCount is the honest coverage number" {
    // stats.typed/unresolved are event counters with manual adjustments and
    // over-count re-visits; the IR is a set keyed by identity.
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

test "TypedIr: refuses `.unassigned` rather than colliding every un-walked expr on id 0" {
    // `.unassigned == 0`. If the IR admitted it, EVERY expression sema/ids.zig
    // failed to reach would share bucket 0 and hand unrelated expressions each
    // other's types — silently, and it would be blamed on inference. Refusing
    // makes a walk miss show up as an absence, which the stage-3 number counts.
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

    try testing.expectEqual(@as(usize, 0), ir.count()); // neither admitted
    try testing.expectEqual(@as(usize, 2), ir.unassigned_rejected);
    // The bug this prevents: reading back int for a string.
    try testing.expect(ir.typeOf(&also_no_id) == null);
}

test "infer: bitwise `&`/`|` yield the OPERAND type, not bool" {
    // `.bit_and`/`.bit_or` were named `@"and"`/`@"or"` — leftovers from the
    // `and`/`or` keywords that `&&`/`||` replaced. Reading as the logical pair,
    // they got lumped into the comparison arm, typing every `hash & (cap - 1)` as
    // bool: 78 divergences on one corpus case, e.g. std/collections/map.nova:63.
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

    // ...while the LOGICAL pair really is bool. Both must hold, or the fix is a swap.
    var land = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .And, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&land));

    var lor = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .Or, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&lor));
}

test "infer: assignment yields the assigned VALUE, not void" {
    // `a = b = 5` compiles and passes today (see the chained-assign conformance
    // case), so assignment is an expression that yields a value — typing it void
    // would break the chain at cutover. specs.md §5.6 records the semantics.
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

// ---------------------------------------------------------------------------
// F4 — generics. The gap that blocks F2's cutover.
// ---------------------------------------------------------------------------

/// `struct List<T> { pub fn get(self: List<T>): T; }` — the smallest generic that
/// exhibits the gap, and the shape `std/collections/list.nova` actually has.
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

test "F4: `List<string>.get()` is string — substitute T from the RECEIVER's args" {
    // The single biggest F2 gap, and the reason the cutover is blocked. lower.zig
    // ALREADY interns List<string> and List<int> as distinct TypeIds (G1 holds),
    // and `get`'s declared return is `T`. What is missing is the last step:
    // SUBSTITUTE T := string using the receiver's own type args.
    //
    // Without it `list.get(i)` is `.unresolved`, so `s` is unresolved, so `s.length`
    // is unresolved, so `len_s` is — one root cause, four clusters, 43 divergences.
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
            .ret_type = .{ .ident = "T" }, // <- the whole point
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

    // `list: List<string>` — a real instantiation, distinct from List<int>.
    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    const list_str = try f.low.lower(.{ .generic = .{ .name = "List", .params = &str_args } });
    var int_args = [_]ast.TypeRef{.{ .ident = "int" }};
    const list_int = try f.low.lower(.{ .generic = .{ .name = "List", .params = &int_args } });
    try testing.expect(list_str != list_int); // G1 — already true

    try inf.push();
    try inf.bind("list", list_str);
    try inf.bind("nums", list_int);

    var obj_s = ast.Expression{ .kind = .{ .ident = "list" } };
    var fa_s = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_s, .field = "get", .span = sp } } };
    var call_s = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_s, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call_s));

    // ...and the SAME method on List<int> is int. One body, two types — which is
    // the whole claim of G1 and the thing erasure destroys.
    var obj_i = ast.Expression{ .kind = .{ .ident = "nums" } };
    var fa_i = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_i, .field = "get", .span = sp } } };
    var call_i = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_i, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call_i));
}

test "F4: a generic FUNCTION call substitutes from its explicit type args" {
    // `allocCopy<T>(value: T): int` (list.nova:4) — generic_call only ever handled
    // the CONSTRUCTOR case (`findType`), so a generic function fell through to
    // unresolved: 9 divergences from one missing branch.
    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var decls = [_]ast.Declaration{
        .{ .fn_decl = .{
            .name = "allocCopy",
            .params = &.{},
            .ret_type = .{ .ident = "int" }, // returns int regardless of T
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .type_params = &.{"T"},
            .span = sp,
        } },
        .{ .fn_decl = .{
            .name = "wrap",
            .params = &.{},
            .ret_type = .{ .ident = "T" }, // returns T — substitution must bite
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

    // allocCopy<int>(...) : int
    var ac_callee = ast.Expression{ .kind = .{ .ident = "allocCopy" } };
    var ac_targs = [_]ast.TypeRef{.{ .ident = "int" }};
    var ac = ast.Expression{ .kind = .{ .generic_call = .{
        .callee = &ac_callee,
        .type_args = &ac_targs,
        .args = &.{},
        .span = sp,
    } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&ac));

    // wrap<string>(...) : string — T := string, by index
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

test "F4: a generic struct's FIELD substitutes too — `Box<string>.v` is string" {
    // methodReturn learned to lower in the struct's scope and substitute; fieldType
    // did neither. It lowered the declared type under whatever scope the walk had
    // left behind, so a field of type `T` never resolved. Every generic struct's
    // fields are affected, not only the closure case below.
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

test "F4: calling a field that HOLDS a function — `(self.hashFn)(key)`" {
    // map.nova:36 `pub hashFn: (K) -> int` called at :62 as `(self.hashFn)(key)`.
    // The callee is a field_access, so .call tried builtin -> module -> method and
    // missed all three: hashFn is a FIELD, not a method. 21 divergences — the call
    // (9) and the `hash` it feeds (12).
    //
    // The rule is general, not a field special-case: if the CALLEE's type is .func,
    // the call yields its return type. That covers `let f = ...; f(x)` too.
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

    // the field itself is `(string) -> int` after K := string
    var obj = ast.Expression{ .kind = .{ .ident = "self" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "hashFn", .span = sp } } };
    const ft = try inf.inferExpr(&fa);
    try testing.expect(f.store.get(ft) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(ft).func.ret);
    try testing.expectEqual(try f.store.stringT(), f.store.get(ft).func.params[0]);

    // ...and calling it yields int, which is what `let hash = (self.hashFn)(key)` needs.
    const key = ast.Expression{ .kind = .{ .ident = "key" } };
    var call_args = [_]ast.Expression{key};
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &call_args, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call));
}

test "F2: `if (s != undefined)` narrows s inside the branch (specs.md 3.4a)" {
    // `List.get(i)` returns `T | undefined` (spec 3.4), so `s.length` on the result
    // is a null deref the type system exists to prevent — and F2 correctly refused
    // it. But the check-then-use idiom the spec prescribes only works if the check
    // NARROWS, and nothing narrowed. 90 `.get()` bindings in the stdlib, 3 checked.
    //
    // The type inside the branch is read back out of the TypedIr rather than through
    // a probe added to the Inferer for the test's benefit. That works only because
    // an ExprId survives the copy into the statement (stage 4a) — the IR is the
    // observer it was built to be.
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

    // if (s != undefined) { s.length; }
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

    // INSIDE the branch, `s.length` is int — s narrowed to string.
    const inner = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    try testing.expectEqual(try f.store.intT(), ir.typeOf(inner).?);

    // OUTSIDE it, `s.length` stays refused. Narrowing must not leak past the branch,
    // and an optional's member is never auto-unwrapped (spec 3.4a).
    var o3 = ast.Expression{ .kind = .{ .ident = "s" } };
    var after = ast.Expression{ .kind = .{ .field_access = .{ .object = &o3, .field = "length", .span = sp } } };
    try idg.walkExpr(&after);
    try testing.expect(f.store.get(try inf.inferExpr(&after)) == .unresolved);
}

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

    // `==` narrows the ELSE, not the then. Both directions must hold or the sign is
    // simply flipped somewhere and half the idiom silently does nothing.
    const then_e = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    const else_e = &if_stmt.if_stmt.else_branch.?.block.statements[0].expr_stmt.expr;
    try testing.expect(f.store.get(ir.typeOf(then_e).?) == .unresolved); // still optional
    try testing.expectEqual(try f.store.intT(), ir.typeOf(else_e).?); // narrowed
}

test "F2: only a plain BINDING narrows — a field does not (specs.md 3.4a)" {
    // `a.b != undefined` must not narrow `a.b`: nothing stops the field changing
    // between the test and the use, so the narrowed type would be a lie the type
    // system told itself.
    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    try inf.push();
    try inf.bind("s", try f.store.intern(.{ .optional = try f.store.stringT() }));

    // The narrowing helper sees through neither a field nor a call.
    var obj = ast.Expression{ .kind = .{ .ident = "s" } };
    var fld = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "inner", .span = sp } } };
    var undef = ast.Expression{ .kind = .{ .literal = .undefined } };
    const cond = ast.BinaryExpr{ .left = &fld, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(cond) == null);

    // ...while a plain binding does.
    var id = ast.Expression{ .kind = .{ .ident = "s" } };
    const ok_cond = ast.BinaryExpr{ .left = &id, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(ok_cond) != null);
    try testing.expectEqualStrings("s", narrowedBinding(ok_cond).?.name);
    try testing.expect(narrowedBinding(ok_cond).?.when_true);
}

test "F2: a closure's params come from the EXPECTED type (specs.md 6.3a)" {
    // `map.nova:175  pub fn forEach(self: Map<K,V>, fn: (K, V) => void)`, called as
    // `m.forEach((k, v) => ...)`. A closure parameter carries NO annotation — the
    // parser has nowhere to put one (spec 6.3) — so the expected type is the ONLY
    // source of `k` and `v`. Everything bound `.unresolved`, which is why `k` and
    // `v` showed up as gaps.
    //
    // The expected type must be the DECLARED param type with the receiver's args
    // substituted: Map<string,int>.forEach expects `(string, int) -> void`, not
    // `(K, V) -> void`. Getting that wrong binds k to a type PARAMETER, which looks
    // resolved and is useless.
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

    // m.forEach((k, v) => k)  -- the body just names k, so its type IS k's type
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

    // `k` inside the closure body is string — substituted, not `K`.
    const inner = args[0].kind.closure.body.expr;
    try testing.expectEqual(try f.store.stringT(), ir.typeOf(inner).?);
}

test "F2: a method call on a TRAIT receiver resolves (`src.getString(k)`)" {
    // `trait ValueSource { fn getString(self, key): string; }` (serde/source.nova:11)
    // and the serde binders call `src.getString(key)` where `src: ValueSource`.
    // methodReturn required a `.struct_` receiver, so a trait receiver returned null
    // and every such call was unresolved — ~13 of the corpus gap, and nothing to do
    // with closures or generics despite sitting in the same bucket.
    //
    // Trait methods are not in the symbol table at all (symbols.zig adds the trait
    // but not its methods), so the lookup goes through the trait's own decl.
    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var tm = [_]ast.TraitMethodDecl{
        .{ .name = "getString", .params = &.{}, .ret_type = .{ .ident = "string" }, .span = sp },
        .{ .name = "arrayLen", .params = &.{}, .ret_type = .{ .ident = "int" }, .span = sp },
        .{ .name = "close", .params = &.{}, .ret_type = null, .span = sp }, // no return => void
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
    try testing.expect(f.store.get(vs) == .trait_); // the receiver really is a trait
    try inf.push();
    try inf.bind("src", vs);

    var recv = ast.Expression{ .kind = .{ .ident = "src" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "getString", .span = sp } } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call));

    var fa2 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "arrayLen", .span = sp } } };
    var call2 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa2, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call2));

    // No declared return means void, not unresolved.
    var fa3 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "close", .span = sp } } };
    var call3 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa3, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.voidT(), try inf.inferExpr(&call3));

    // A method the trait does not declare stays unresolved — the trait is the
    // contract, so this must not fall through to some struct that happens to have it.
    var fa4 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "nosuch", .span = sp } } };
    var call4 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa4, .args = &.{}, .span = sp } } };
    try testing.expect(f.store.get(try inf.inferExpr(&call4)) == .unresolved);
}

test "F2: `go` yields future<T> and `await` unwraps it (specs.md 7.1)" {
    // `let h1 = go square(3); … await h1` (10_async_go:17-20). `.await_expr` and
    // `.go_expr` both returned unresolved unconditionally, so `await` was one of
    // the last things blocking the legacy resolver's deletion.
    //
    // The alternative — typing a handle AS its eventual value, which is what legacy
    // does — would make `h + 1` correct rather than merely unchecked. That is the
    // machine-word lie F3 exists to kill, so `go` gets a real type instead.
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

    // await square(3) : int -- await on a CALL is the call's return type
    var callee = ast.Expression{ .kind = .{ .ident = "square" } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &callee, .args = &.{}, .span = sp } } };
    var aw_call = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &call, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_call));

    // go square(3) : future<int> -- NOT int. A handle is not the value.
    var go_e = ast.Expression{ .kind = .{ .go_expr = .{ .operand = &call, .span = sp } } };
    const h = try inf.inferExpr(&go_e);
    try testing.expect(f.store.get(h) == .future);
    try testing.expectEqual(try f.store.intT(), f.store.get(h).future);
    try testing.expect(h != try f.store.intT()); // the whole point

    // await h : int -- unwrapped
    try inf.bind("h", h);
    var h_id = ast.Expression{ .kind = .{ .ident = "h" } };
    var aw_h = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &h_id, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_h));

    // future<int> and future<string> are distinct — interning, not a tag
    const fut_str = try f.store.intern(.{ .future = try f.store.stringT() });
    try testing.expect(fut_str != h);
}

test "F2: a closure param is inferred from its USE in the body (specs.md 6.3a)" {
    // `let f = (x) => x + 1;` (05_closures_capture:7). No expected type, so
    // contextual typing has nothing to offer — but `x + 1` pins x to int, and the
    // legacy resolver knew that while F2 did not. 8 of the 11 resolutions blocking
    // the legacy resolver's deletion were this one shape.
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

    // (x) => x + 1
    var xi = ast.Expression{ .kind = .{ .ident = "x" } };
    var one = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var body = ast.Expression{ .kind = .{ .binary = .{ .left = &xi, .right = &one, .op = .add, .span = sp } } };
    var params = [_][]const u8{"x"};
    var clo = ast.Expression{ .kind = .{ .closure = .{ .params = &params, .body = .{ .expr = &body }, .span = sp } } };
    var idg = ids.Assigner.init();
    try idg.walkExpr(&clo);
    const t = try inf.inferExpr(&clo);

    // x is int, recorded in the IR — which is what codegen reads.
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&xi).?);
    // ...and the closure's own type is (int) -> int.
    try testing.expect(f.store.get(t) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.params[0]);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.ret);
}

test "F2: `(a, b) => a + b` stays unresolved — the limit, not a guess" {
    // Neither side is pinned. `a + b` says only "these are addable", which needs
    // type variables and a solver. Guessing int would be the machine-word lie in a
    // new place — the exact thing F2 exists to stop.
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
