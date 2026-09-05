# Kyte Compiler LLD: the type-inference / typed-IR pass

Inference is the pass that turns a parsed, symbol-resolved AST into a **typed IR**: a set of
side tables that map every expression node (by its stable `ast.ExprId`) to a `TypeId`, plus the
ownership disposition (owned versus borrowed), the resolved `SymbolId` of a called function or
method, and, for generic call sites, the concrete type arguments that codegen needs to rebuild
the monomorphised name. The pass does not rewrite the tree in place, it threads facts out through
a `TypedIr` record. Everything downstream (the LLVM codegen and the HIR/MIR/LIR optimiser) reads
those tables rather than re-deriving types. Inference sits after parsing and after the symbol
table is built (so it can resolve idents, modules, types, methods, constants), and it runs
alongside the legacy `type_checker.zig`. It is described in the memory notes and CLAUDE.md as the
**authoritative sema engine**: the `sema/` directory (infer/mono/ownership/lower/symbols) is the
typed-IR pass of record, and its type facts drive codegen ARC decisions, generic instantiation,
and a family of fail-closed soundness diagnostics.

## `src/frontend/sema/infer.zig` (3234 lines)

**Role in the pipeline:** the file defines one central engine, `Inferer`, and the typed-IR
container `TypedIr` it populates. The strategy is a straightforward recursive AST walk. The entry
points `inferFunction` / `inferFunctionWithSelf` set up a per-function scope (parameters,
`self`, the declared return type, the current module), then walk the body statement by statement
via `inferStmtSeq` / `inferStmt`, and each statement drives expression inference through
`inferExpr` / `inferExprExpecting` / `inferExprInner`. Types are represented as interned
`TypeId`s held in a shared `types.TypeStore`: inference **mints** primitive/aggregate types by
calling the store's constructors (`intT`, `stringT`, `boolT`, `voidT`, `decimalT`, `doubleT`)
and interns compound shapes (`.array`, `.tuple`, `.func`, `.future`, `.optional`, `.struct_`,
`.enum_`, `.storage`) with `store.intern`. There is no Hindley-Milner style constraint solver.
Inference is bidirectional in a light way: an `expected: ?TypeId` flows down so that, for example,
an untyped integer literal can adopt a `long` context, or a closure can take its parameter types
from the function-typed slot it is being passed into. Where a type genuinely cannot be pinned, the
engine returns the store's `unresolved` sentinel and records a stat, rather than guessing (guessing
is the historical soundness bug this pass exists to stop).

Generics are handled by **substitution plus monomorphisation notes**, not type erasure. When a
generic struct, method, or free function is used with concrete arguments, inference lowers the
declared type in the owner's parameter scope (via the `lower.Lowerer` with a pushed `ParamScope`),
solves the type parameters against the actual argument types (`subst.solveParams`), substitutes the
solved bindings back into the return type (`subst.substituteOne` / `subst.substitute`), and, when
every parameter solved to something concrete, calls into `mono.zig` (`noteFreeFnInst`,
`noteMethodInst`, `noteBaseNeeded`) so codegen knows to emit the specialised body (`fn__T`,
`List_int_*`). The concrete arg vector is also stashed on the call expression via
`ir.recordMethodArgs`, because a bare `fn(x)` call has no explicit `<T>` for codegen to mangle from.

The key data threaded out: `expr_types` (the type of every expression), `expr_owned` (does the
expression produce a freshly owned heap value that ARC must release), `expr_op` (a move/drop
`OwnOp` hint), `expr_syms` (the resolved callee `SymbolId`), `expr_method_args` (solved concrete
type args per call), plus the instantiation-keyed variants (`expr_owned_inst`, `expr_types_inst`,
`tp_resolve`) that let the same expression node carry different facts under different
monomorphisations. Inference also **interacts with ownership** by computing an owned/borrowed
disposition per node (`ownedDisposition`, backed by `store.isOwnedSafe`), which `ownership.zig`
and codegen's `arc.zig` consume; it interacts with `shadow.zig` through the shared `TypeStore`
that `KYTE_SEMA_SHADOW` diffs against the legacy engine.

Besides typing, the pass carries a set of **fail-closed soundness checks** (labelled A1 / L2 / G5
and the `gaps.md` C-chk-* ids) that collect located diagnostics into per-category error lists on
the `Inferer`: non-bool conditions, optional-where-plain returns and arguments, method-call arity,
const reassignment, cross-module visibility, optional/error-union see-through field/method access,
catch-arm mismatch, and `try` error-type mismatch. These lists are drained by the caller after the
walk.

### Key types & data structures

- **`pub const TypeId = types.TypeId`**: re-export so callers can spell `infer.TypeId`.

- **`pub const Stats = struct`**: inference coverage counters, owned by the `Inferer`.
  - `typed: usize`: count of expressions that resolved to a concrete type (bumped by `ok`).
  - `unresolved: usize`: count of expressions that fell back to the unresolved sentinel.
  - `unresolved_ns_ident`, `unresolved_ns_field`: sub-counts for "not-a-symbol" idents and
    field accesses that are expected to be resolved later (module namespaces, codegen-only paths),
    kept separate from genuine failures so they do not inflate the fatal count.
  - `by_tag: StringHashMapUnmanaged(usize)`: histogram of unresolved reasons keyed by the tag
    string passed to `unresolved` (e.g. "binary", "call", "closure").
  - `by_name: StringHashMapUnmanaged(usize)`: histogram of unresolved identifier/field names.
  - `deinit(self, allocator)`: frees the two maps. Keys are borrowed string slices (AST/tag
    literals), so only the map storage is freed.

- **`const Binding = struct`** (private): one lexical binding in a scope: `name`, `ty`,
  `is_const`. Held by value in the scope stack.

- **`pub const OwnOp = enum { move, drop }`**: the ownership operation hint recorded per
  expression for ARC lowering.

- **`pub const InstKey = struct { id: ast.ExprId, inst: TypeId }`**: key for per-instantiation
  side tables: the same expression node under a specific monomorphisation instance.

- **`pub const TpKey = struct { tp: TypeId, inst: TypeId }`**: key mapping a type-parameter type
  plus an instantiation context to the concrete type it resolves to.

- **`pub const TypedIr = struct`**: the output container. All maps are `AutoHashMapUnmanaged`
  keyed by `ast.ExprId` (or the composite keys above), allocator passed in per call.
  - `expr_types: {ExprId -> TypeId}`: the primary result: type of each expression.
  - `expr_syms: {ExprId -> SymbolId}`: the resolved function/method symbol at a call.
  - `expr_method_args: {ExprId -> []const TypeId}`: solved concrete type args at a generic call;
    the slices are **owned** (duped on insert, freed in `deinit`).
  - `expr_owned: {ExprId -> bool}`: whether the expression yields a fresh owned heap value.
  - `expr_op: {ExprId -> OwnOp}`: move/drop hint.
  - `expr_owned_inst`, `expr_types_inst`: the `InstKey`-keyed variants of owned/type, so a node
    can carry different facts per monomorphisation.
  - `tp_resolve: {TpKey -> TypeId}`: type-parameter resolution table.
  - `unassigned_rejected: usize`: count of `record` calls dropped because the expression had no
    stamped `ExprId` (guards against every un-walked node colliding on id 0).
  - `deinit(self, allocator)`: frees every map, first freeing the owned `expr_method_args` slices.
  - `recordOwnedInst / ownedOfInst`, `recordTypeInst / typeOfInst`, `recordTpResolve / tpResolve`:
    put/get pairs for the instantiation-keyed tables. The record side no-ops on
    `.unassigned` ids (except `tp_resolve`, which is not expression-keyed).
  - `recordOp / opOf`: put/get for the move/drop hint (skips `.unassigned`).
  - `typeOf2(id)`: type lookup by raw `ExprId` (skips `.unassigned`).
  - `recordOwned / ownedOf`: put/get owned flag keyed off an `*Expression` (uses `e.id`).
  - `ownedTrueCount`: counts how many recorded owned flags are true (a coverage gauge).
  - `recordMethodArgs / methodArgsOf`: put/get for the solved type-arg slice; put **frees the
    previous slice** for that id before duping the new one (idempotent re-inference).
  - `recordSym / symOf`: put/get resolved symbol.
  - `record / typeOf`: the primary put/get; `record` increments `unassigned_rejected` and drops
    the write when `e.id == .unassigned`.
  - `count()`: number of typed expressions.
  - `unresolvedCount(store)`: how many recorded types are still `.unresolved` per the store; the
    honest coverage number.

- **`const Narrowing = struct { name, when_true }`** (private): the result of recognising an
  `x != undefined` / `x == undefined` guard: which binding narrows and in which branch.

- **`pub const VisKind = enum { function, type_, const_ }`** and **`pub const VisError`**: a
  cross-module visibility violation (accessing a non-`pub` function/type/const from another
  module). Fields: `span`, `recv` (receiver/module text), `field` (name), `kind`.

- **`pub const ConstReassignError { span, name }`**: assignment to a `const` binding.

- **`pub const OptDerefKind = enum { opt, err }`** and **`pub const OptDerefError`**: a field or
  method accessed directly on an unnarrowed `T | undefined` (opt) or error union (err). Fields:
  `span`, `field`, `is_method`, `kind`.

- **`pub const CatchMismatchError { span, ok, handler }`**: a `catch` whose handler value type
  does not unify with the ok side of the error union.

- **`pub const TryErrorMismatch { span, callee_err, fn_err }`**: a `try g()` whose propagated
  error type differs from the enclosing function's declared error type (soundness hole G5: the
  contract says `E1` but an `E2` escapes).

- **`pub const CondTypeError { span, got, ctx }`**: a non-bool `if`/`while`/`for` condition
  (A1, C-chk-4). `ctx` names the construct.

- **`pub const RetOptionalError { span, ret, val }`**: returning a `T | undefined` where a plain
  `T` is declared (A1, C-chk-3).

- **`pub const ValoptPosError { span, want, got, ctx }`**: a possibly-`undefined` value used
  where a plain type is required at a let-binding or call-argument position (L2, C-chk-6). `ctx`
  names the position.

- **`pub const MethodArityError { span, name, expected, got }`**: a method call whose argument
  count does not match the declared parameters (A1, C-chk-1). Kyte has no defaults/variadics, so
  arity is exact.

- **`pub const Inferer = struct`**: the engine and all its mutable state (see below).

#### `Inferer` state fields

- `allocator`, `store: *TypeStore`, `symtab: *const SymbolTable`, `lowerer: *Lowerer`: the
  injected collaborators (the store is mutated by interning; the symbol table is read-only; the
  lowerer's `param_scopes` and `current_module` are saved/restored around scoped lowering).
- `scopes: ArrayList(ArrayList(Binding))`: the lexical scope stack (owned; freed in `deinit`).
- `const_depth: usize`: recursion guard for constant-value inference (`constType`, capped at 8).
- `infer_depth: u32`, `infer_overflow: bool`: cyclic-type recursion guard (capped at 2000; the
  overflow latch is sticky so a swallowed error cannot restart the loop).
- `current_ret: ?TypeId`: the enclosing function's declared return type, used by return-position
  checks and to give a return value its expected type.
- `current_module: ?ModuleId`: the module being inferred, for symbol/visibility resolution.
- the error lists: `visibility_errors`, `const_reassign_errors`, `optional_deref_errors`,
  `catch_mismatch_errors`, `try_error_mismatch_errors`, `cond_type_errors`, `ret_optional_errors`,
  `valopt_pos_errors`, `method_arity_errors`: all `ArrayListUnmanaged`, appended during the walk,
  drained by the caller. Note `deinit` only frees the first five (see the gotcha below).
- `fatal_unresolved_idents: usize`, `first_fatal_ident`, `first_fatal_span`: the confident subset
  of "unknown identifier" that should reject before codegen, plus the first located occurrence.
- `fatal_unresolved_calls: usize`, `first_fatal_call_recv/field/span`: the confident subset of
  "known module has no such function" (F1-7), rejected here rather than at codegen.
- `captured_return: ?TypeId`: the inferred return type seen inside a block/closure body (used to
  give a block-bodied closure its result type).
- `in_call_callee: bool`: set while inferring the callee sub-expression of a call, so a
  field-access that is a call target treats an otherwise-unresolved namespace access as expected
  rather than a failure.
- `current_stmt_seq: ?[]ast.Statement`: the statement list currently being walked, so a
  `let f = closure` can look ahead to a `f(args)` call site in the same block and pin the closure's
  param types on the first pass.
- `ir: ?*TypedIr`: the output sink; when null (quiet inference) nothing is recorded.
- `stats: Stats`: coverage counters.

### Module-level state / constants

There is no mutable module-level state. Module-level items are the imports (`std`, `ast`, `ids`,
`subst`, `types`, `symbols`, `lower`, `builtins`, `mono`), the `pub const TypeId` re-export, the
type declarations above, and, at the bottom, `const testing = std.testing` plus the in-file unit
tests. Notable magic constants live inside functions: the recursion caps `2000` (`inferExprInner`)
and `8` (`constType`), and the hard-coded builtin receiver/namespace names in `isFatalUnresolvedIdent`
(`"self"`, the `kyte_` prefix, `{ "bytes", "console", "sync", "atomic" }`, `{ "Storage", "Atomic" }`)
and the special-cased generic namespaces `"serde"`, `"mem"`, `"bytes"`, `"Storage"` in
`inferExprInner`'s `.generic_call` arm.

### Functions (source order)

Free functions (module scope):

- **`fn narrowedBinding(cond: ast.BinaryExpr) ?Narrowing`** (private): recognises an
  `ident != undefined` / `ident == undefined` comparison and returns which binding narrows and in
  which branch (`when_true` = true for `!=`, false for `==`). Requires exactly one side to be the
  `undefined` literal and the other to be a plain `.ident` (a field does not narrow). Pure.

- **`fn branchTerminates(s: *const ast.Statement) bool`** (private): does this statement
  unconditionally leave the enclosing flow: `return`/`break`/`continue`, or a block whose last
  statement terminates (recursive). Used for early-exit narrowing.

- **`fn earlyExitNarrowing(s: *const ast.Statement) ?Narrowing`** (private): recognises the
  guard-clause pattern `if (x == undefined) { return }` (or `if (x != undefined) {...} else
  { return }`) so the code after the `if` can treat `x` as narrowed. Returns the narrowing only
  when the non-taken branch terminates.

`Inferer` methods:

- **`pub fn init(allocator, store, symtab, lowerer) Inferer`**: constructs an `Inferer` with the
  collaborators; all state defaults empty.

- **`pub fn deinit(self)`**: frees the scope stack, stats, and the first five error lists
  (`visibility_errors`, `const_reassign_errors`, `optional_deref_errors`, `catch_mismatch_errors`,
  `try_error_mismatch_errors`). Gotcha: `cond_type_errors`, `ret_optional_errors`,
  `valopt_pos_errors`, `method_arity_errors`, `try_error_mismatch` is freed but the later four are
  **not** freed here, so their backing storage relies on an arena or the caller draining and never
  growing them. Treat the newer error lists as arena-lifetime.

- **`fn push(self) !void`** / **`fn pop(self) void`** (private): push an empty scope / pop and
  free the top scope. `pop` asserts a scope exists (`.pop().?`).

- **`fn bind(self, name, ty) !void`** / **`fn bindC(self, name, ty, is_const) !void`** (private) , 
  add a binding to the current scope; `bind` is the non-const shorthand. `bindC` lazily pushes a
  scope if the stack is empty. Note: shadowing is legal, a new `Binding` is appended, later lookups
  find the most recent (see the shadowing memory note).

- **`fn lookupIsConst(self, name) bool`** (private): walk scopes newest-first, return whether the
  nearest binding of `name` is const. Used by the assignment const-reassign check.

- **`fn rebind(self, name, ty) void`** (private): find the nearest binding of `name` and mutate
  its type in place (used for narrowing and for invalidating a narrowing on reassignment). Silent
  no-op if not found.

- **`fn lookup(self, name) ?TypeId`** (private): nearest-binding type lookup, newest scope first.

- **`fn unresolved(self, tag) !TypeId`** (private): bump `stats.unresolved`, increment the
  `by_tag` histogram for `tag`, and return `store.unresolvedT()`. The uniform "could not type it"
  exit; `tag` is a borrowed literal used as the reason label.

- **`fn note(self, name) !void`** (private): increment the `by_name` histogram for an unresolved
  identifier/field name (diagnostic breadcrumb).

- **`fn lubTraitOfStructs(self, tt, et) !?TypeId`** (private): least-upper-bound helper for
  `if`-expression branches whose arms are two different structs: if both structs implement exactly
  one common trait (by matching impl names resolved to a `.trait_` symbol in the current module),
  return that trait's `TypeId`; ambiguity (more than one common trait) or no common trait returns
  null. Interns a `.trait_` type.

- **`fn ok(self, id) TypeId`** (private): bump `stats.typed` and return `id`; the "successfully
  typed" exit that pairs with `unresolved`.

- **`fn catchArmsCompatible(self, ok_t, handler_t) bool`** (private): conservative unification
  for the two arms of a `catch`: equal types pass, an unresolved side passes, and the only rejected
  shape is a heap `string`/`decimal` on one arm and a non-string/non-decimal on the other (exactly
  what codegen would mis-stringify or mis-free). Numeric/struct/trait/enum variety is allowed.

- **`fn errorTypesCompatible(self, a, b) bool`** (private): do two error types match: identical
  `TypeId`, same enum symbol, or same struct decl; an unresolved side never flags. Kyte has no
  error subtyping, so anything else is a G5 mismatch.

- **`pub fn inferExpr(self, ep) !TypeId`**: the public expression entry; delegates to
  `inferExprExpecting(ep, null)`.

- **`pub fn inferExprExpecting(self, ep, expected) !TypeId`**: the recording wrapper: calls
  `inferExprInner`, then, if an `ir` sink is set, records the type (`ir.record`) and the owned
  disposition (`ir.recordOwned` from `ownedDisposition`). This is where every visited node gets its
  fact written. Returns the type.

- **`fn ownedDisposition(self, kind, t) bool`** (private): decide whether an expression yields a
  freshly owned heap value ARC must release. Borrowed by construction: `.ident`, `.field_access`,
  `.index`, an assignment `binary`, a non-decimal `.literal`, and `.try_expr`/`.cast`/`.await_expr`/
  `.go_expr`/`.optional_chaining`. Everything else falls through to `store.isOwnedSafe(t)`. This is
  the seam the ARC pass reads to decide retains/releases.

- **`fn inferExprInner(self, e, expected) !TypeId`** (private): **the core dispatcher**, a switch
  over `ast.ExprKind`. Guarded by the recursion cap (returns `error.TypeInferenceRecursionLimit`
  past depth 2000, sets the sticky `infer_overflow` latch). Per-construct handling:
  - `.range`: infer both ends, result is `int`.
  - `.literal`: `integer` adopts an integer `expected` type but only when it is at least 32-bit
    (int/uint/long/ulong); a narrower expected (short/byte) is ignored so a bare literal keeps
    defaulting to `int` per the explicit-narrowing rule. `float`→double, `string`→string,
    `bool`→bool, `decimal`→decimal. `array` infers the first element, walks the rest, and interns
    `.array{elem,len}` (empty array or unresolved element → unresolved). `array_repeat` interns
    `.array{elem,count}`. Anything else → unresolved.
  - `.ident`: resolution order: local binding, then `constType`, then a top-level function
    (returns its `.func` type), then a builtin extern, then a type-in-module (struct → `.struct_`,
    enum → `.enum_`). Failing all that, if `isFatalUnresolvedIdent` says it is a genuine unknown it
    bumps the fatal counters and captures the first located span, otherwise it counts a namespace
    miss. Always `note`s and returns unresolved.
  - `.binary`: comparison/logical ops (`eq/ne/lt/gt/le/ge/And/Or`) infer both sides and return
    `bool`. `assign` types the lhs, records a const-reassign error if the target is a const
    binding, types the rhs, and if the rhs is optional while the binding is not it **rebinds** the
    target to the optional type (invalidating a stale narrowing); result is the lhs type (or rhs if
    lhs is unresolved). Otherwise it is arithmetic/bitwise/shift: an integer `expected` propagates
    into the operands (so an all-literal `1 << 40` computes at the target width), the shift amount
    is left un-widened, string operands to `+` give string concatenation, and the result takes the
    **wider** of the two integer operand types (a single widened literal lifts the whole
    expression). Unresolved lhs falls back to rhs.
  - `.unary`: result is the operand type (propagates unresolved).
  - `.cast`: infers the source, lowers the target type, returns it (unresolved if the target is).
  - `.call`: the largest arm. Infers the callee (with `in_call_callee` set), then, if the callee
    is `Enum.Variant`, treats it as an enum construction. Computes expected parameter types
    (`calleeParamTypes`) to give arguments their expected types (and runs the C-chk-6 plain-target
    check per argument). For an ident callee: builtin extern, then a bare function (module-scoped
    first, recording the symbol when unambiguous, warning if deprecated, and for generic functions
    solving the return via `freeFnReturn`), then a struct constructor. For a field-access callee:
    builtin-call return, module-call return (recording the callee symbol), method return, static
    method return, and the F1-7 fatal-unresolved-call detection when the receiver is a known module
    with no such function. Falls back to a `.func` callee's declared return, else unresolved.
  - `.field_access`: infers the object, then tries in order: a module function value, a struct
    field type (`fieldType`), a string/array `.length`/`.len` property, an enum reference (bare
    `Enum` or nested `mod.Enum`), a module-qualified constant, and finally the namespace/unresolved
    fallbacks (respecting `in_call_callee` so a call target's unresolved namespace access is not a
    hard failure).
  - `.optional_chaining`: `obj?.field`: unwraps an optional object to its struct, finds the field
    in the struct's param scope, and returns it as an optional (not double-wrapping an
    already-optional field).
  - `.nullish_coalesce`: `a ?? b`: if `a` is optional, result is its inner type, else `a`'s type
    (or `b` when `a` is unresolved).
  - `.template_expr`: infer each interpolated part, result is `string`.
  - `.if_expr`: infers condition and both arms with `expected` propagated; if the expected type is
    a trait and both arms are structs, yields the trait; equal arms yield that type; otherwise tries
    `lubTraitOfStructs`; else unresolved.
  - `.struct_init`: resolves the struct decl, recovers its type params, lowers each declared field
    type both plainly and in the struct's param scope, infers each field value with the plain
    declared type expected, and **solves** the type params against the actual field values
    (`subst.solveParams`). Records visibility, then interns `.struct_{decl, args}` with the solved
    args (unresolved args fill unsolved slots). This is the fix for erased-`T` field SEGVs (B5).
  - `.index`: string index → int, array index → element type, else unresolved.
  - `.go_expr`: interns `.future{inner}` (unresolved inner → unresolved).
  - `.await_expr`: unwraps `.future`, passes through a non-future value, unresolved → unresolved.
  - `.tuple`: infers each element (propagating the matching expected tuple element), promoting a
    struct element to an expected trait slot; interns `.tuple{elems}`.
  - `.closure`: see the closure discussion below. Pins params from an expected `.func` type or
    from body use, infers the body (expr or block), and interns a `.func` type; reuses a cached
    resolved `.func` on a no-expectation re-inference.
  - `.try_expr`: unwraps an `.error_union` to its ok side, and (against `current_ret`) flags a G5
    `TryErrorMismatch` when the callee's error type differs from the function's declared error.
  - `.catch_expr`: binds the error name to the error type, infers the handler with the ok type
    expected, checks arm compatibility (`catchArmsCompatible`, else records a mismatch), yields the
    ok type; a non-error-union expression just infers the handler and passes through.
  - `.block_expr`: infers the block, returns unresolved (a block has no value here).
  - `.generic_call`: special-cases the `serde.*<T>` builtins (`bind`/`bindRow`→T,
    `bindAll`/`bindWire`→`List<T>`, `planFor`→`List<int>`, `typeName`→string, `dump`→void), the
    `mem.*<T>` byte/bit builtins (`load`/`rotl`/`rotr`/`bswap`→T, `ctz`/`clz`→int, `store`→void),
    the `bytes.new*<T>`→T constructors, and `Storage<T>`. Otherwise it lowers the explicit type
    args, resolves a generic struct (interning `.struct_{decl,args}`) or a generic free function
    (lowering + substituting the return in the function's param scope, and noting the mono
    instantiation when all args are concrete). Explicit method calls go through
    `explicitMethodReturn`. Else unresolved.
  - `.enum_init`: infer field values, resolve the enum type, intern `.enum_`.
  - `.jsx_element`: walks the element (`inferJsxElement`) so embedded `{expr}` are typed, result
    is `string` (NSX lowers to a built string).

- **`fn inferJsxElement(self, jsx) !void`** (private): recurse into an NSX element's attribute
  expressions and children (nested elements, `{expr}` children, embedded statements) so each is
  inferred. The element's own type is fixed as `string` by the caller.

- **`fn fnType(self, f) !TypeId`** (private): build a `.func` type from a `FunctionDecl`: lower
  each param type (unresolved where untyped), lower the return (void when absent), intern.

- **`fn lowerInStructScope(self, st, tr) !TypeId`** (private): lower a type ref `tr` in the
  struct's type-parameter scope (temporarily setting `lowerer.param_scopes` for the struct's decl
  and names), then `subst.substitute` the struct's concrete `args` into the result. This is how a
  field/method declared as `T` becomes the receiver's concrete type. Restores `param_scopes`.

- **`fn lowerInMethodScope(self, st, mid, fd, tr) !TypeId`** (private): like the above but pushes
  two param scopes: the owner struct's params and the method's own type params, then substitutes
  the struct's args. Used for method return/parameter lowering on generic methods.

- **`fn freeFnReturn(self, fid, fd, ret_tr, arg_types, call_expr) !?TypeId`** (private): infer the
  return type of a generic **free** function call from its argument types. Lowers the return in the
  function's param scope, solves each type param against the corresponding argument
  (`subst.solveParams`), substitutes the solved bindings into the return
  (`subst.substituteOne` per param). When every param solved concretely, registers the
  monomorphised instantiation (`mono.noteFreeFnInst`) and records the solved args on the call
  expression (`ir.recordMethodArgs`) so codegen can rebuild `fn__T` for a bare `fn(x)`. Allocates
  temporary `solved`/`solved_args` buffers (freed via defer). Returns null on failure paths.

- **`fn recordOptDeref(self, fa, is_method, kind) void`** (private): record an
  optional/error-union see-through field or method access, with an optional `KYTE_OPT_AUDIT`
  stderr trace. Appends to `optional_deref_errors`.

- **`fn fieldType(self, fa) !?TypeId`** (private): resolve `obj.field`: infer the object; if it is
  optional or an error union, record a see-through deref and return null; otherwise, for a struct,
  find the field and lower its type in the struct's scope. Null when not a struct field.

- **`fn moduleOfObject(self, fa) ?ModuleId`** (private): resolve the module a `mod.x` object refers
  to: only when the object is an unbound ident that names an imported module or a module segment.
  (Helper; note it is defined but the call arm mostly resolves modules inline.)

- **`fn constType(self, name) !?TypeId`** (private): resolve a named constant's type by scanning
  the symbol table for a `constant` symbol, checking cross-module visibility (recording a
  `const_` `VisError` once per name), then inferring the constant's initializer value with a
  `const_depth` guard (capped at 8, restoring `stats.typed` so const inference does not inflate
  coverage). Returns null on unresolved value or missing/private const.

- **`fn stringProperty(self, fa) !?TypeId`** (private): the `.length`/`.len` property on a
  `string` or `array` object, typed as `int`. Null otherwise.

- **`fn builtinCallReturn(self, fa) !?TypeId`** (private): return type of a builtin receiver call
  `recv.field(...)` (e.g. `console.log`), gated on the receiver being an unbound ident that
  `builtins.isReceiver` recognises.

- **`fn recordTypeVis(self, name, span) void`** (private): record a cross-module type visibility
  violation for `name` at `span` (skips synthesized `<...>` spans and public/same-module types,
  dedupes against the last error).

- **`fn checkTypeRefVis(self, tr, span) void`** (private): recursively check a type reference
  (including optional/error-union/array/generic/func/tuple shapes) for private-type usage via
  `recordTypeVis`.

- **`fn resolveModuleFn(self, recv, field, span) ?SymbolId`** (private): resolve `mod.fn`: an
  imported module's function, else a function found by module segment. Records function visibility.

- **`fn recordFnVisibility(self, sid, cm, recv, field, span) void`** (private): record a
  non-`pub` cross-module function access as a `VisError` (dedupes on span).

- **`fn isFatalUnresolvedIdent(self, name) bool`** (private): is an unresolved ident a genuine
  unknown that should reject the compile, versus a name that later passes resolve (`self`, the
  `kyte_` runtime prefix, the magic receivers `bytes`/`console`/`sync`/`atomic`, builtin receivers,
  the builtin types `Storage`/`Atomic`, or any known imported/segment module name).

- **`fn isKnownModule(self, name) bool`** (private): does `name` resolve to an imported module,
  an import name, or a module segment. Used by the F1-7 fatal-call detection.

- **`fn moduleCallReturn(self, fa, out_sym) !?TypeId`** (private): return type of a `mod.fn(...)`
  call: resolves the module function, writes its symbol to `out_sym`, and lowers the return type
  **in the callee's module scope** (saving/restoring `lowerer.current_module`) so a bare type name
  binds to the declaring module, not the caller's same-named type (the S2 mistype fix). Void when
  the callee has no declared return.

- **`fn moduleFnValue(self, fa) !?TypeId`** (private): the `.func` type of `mod.fn` referenced as
  a value (not called). Resolves the module function and builds its function type.

- **`fn staticMethodReturn(self, fa) !?TypeId`** (private): return type of a static/UFCS method
  `Type.method(...)`: resolves the type-in-module, finds the method in the type's module, lowers the
  declared return. Void when absent, null when unresolved.

- **`fn methodReturn(self, fa, args, out_sym, call_ep) !?TypeId`** (private): the instance-method
  workhorse. Infers the receiver; optional/error-union receivers record a see-through deref and
  return null; a trait receiver dispatches to `traitMethodReturn`; a `.storage` receiver handles
  `get`/`set`; an enum receiver finds the method in the enum's module (with an arity check) and
  lowers the return. For a struct receiver: finds the method, writes `out_sym`, runs the arity
  check, and lowers the return in the method scope. For a non-generic method that is the answer.
  For a generic method it lowers the declared parameter types in the method scope, infers each
  argument with its declared type expected, **solves** the method's type params against the
  actual arguments, substitutes the solved bindings into the return, and, when all solved
  concretely, records the solved args on the call (`ir.recordMethodArgs`) and notes the
  monomorphised method instantiation (`mono.noteMethodInst`) plus the base-vtable need
  (`mono.noteBaseNeeded`). Returns null on unresolved.

- **`fn explicitMethodReturn(self, fa, type_args, args, out_sym) !?TypeId`** (private): the
  generic-method path for an explicit `obj.method<T>(...)` call. Requires the method to be generic
  with a matching type-arg count. Types the arguments (with declared param types expected via
  `paramTypesOf`), lowers the explicit type args, substitutes them into the return in the method
  scope, and notes the mono instantiation when all args are concrete. Also transparently unwraps an
  optional receiver.

- **`fn narrowedBranch(self, narrow, is_then, branch) !void`** (private): infer an `if` branch
  under narrowing: if the narrowing applies to this branch and the bound name is currently optional,
  push a scope binding the name to its unwrapped inner type, then infer the branch; otherwise infer
  the branch plainly.

- **`fn calleeParamTypes(self, callee) !?[]TypeId`** (private): the declared parameter types of a
  call's callee (for giving arguments expected types). Handles an ident callee (a top-level
  function) and a field-access callee (a method resolved off the object's quietly-inferred type).
  Returns an **owned** slice the caller frees. Null when it cannot resolve.

- **`fn paramTypesOf(self, fd, recv) !?[]TypeId`** (private): lower a function's parameter types
  (skipping `self`), in the receiver struct's scope when `recv` is given, else plainly. Returns an
  owned slice (unresolved for untyped params).

- **`fn typeOfObjectQuietly(self, obj) ?TypeId`** (private): a non-recording, non-erroring type
  probe for an object expression: a bound ident's type, or a chain of struct field accesses. Used
  by `calleeParamTypes` so probing a method receiver does not emit diagnostics or record facts.

- **`fn traitMethodReturn(self, tid, field) !?TypeId`** (private): the declared return type of a
  trait method by name (void when the method has no return, null when unresolved or not found).

- **`fn paramFromUse(self, param, body) !?TypeId`** (private): infer a closure parameter's type
  from its use in an expression body (block bodies return null). Delegates to `paramFromUseExpr`.

- **`fn paramFromUseExpr(self, param, e) !?TypeId`** (private): walk an expression looking for an
  arithmetic/bitwise/shift binary where `param` is used against a **typed** other operand; that
  other operand's type is the parameter's inferred type. Recurses into both sides and unary
  operands. This is how `(x) => x + 1` pins `x` as int.

- **`fn inferExprQuietly(self, e, expected) !TypeId`** (private): infer without recording or
  leaking diagnostics: it snapshots `ir` (nulled), `stats.typed`, and all the fatal-diagnostic
  counters, restores them via defer, and calls `inferExprInner`. Used for look-ahead (typing a
  call's arguments before locals are bound). Footgun avoided: an "undefined identifier" hit during
  look-ahead must not become a real error, hence the counter snapshot.

- **`pub fn inferBlock(self, b) !void`**: push a scope, infer the statement sequence, pop.

- **`pub fn inferStmtSeq(self, statements) !void`**: set `current_stmt_seq` (for closure
  look-ahead), infer each statement, and after each apply `earlyExitNarrowing`: on a guard-clause
  early exit, push a scope with the narrowed binding and infer the remaining statements under it,
  then return. Restores `current_stmt_seq`.

- **`pub fn inferStmt(self, sp) !void`**: statement dispatcher:
  - `.block`: `inferBlock`.
  - `.let_stmt`: with a declared type, lower it, check its visibility, infer the initializer with
    it expected and run the C-chk-6 plain-target check; without a declared type, either look ahead
    to pin a closure's params (`closureCallExpectation`) or infer the initializer plainly; with no
    initializer, unresolved. Then bind: a tuple destructure binds each name to the matching tuple
    element (or unresolved on shape mismatch), otherwise bind the single name (respecting
    `is_const`).
  - `.expr_stmt`: infer the expression.
  - `.if_stmt`: check the condition is bool (`checkCond`), compute the narrowing, infer both
    branches under `narrowedBranch`.
  - `.while_stmt`: check the condition, infer the body.
  - `.for_stmt`: push a scope; infer C-style init/condition (bool-checked)/increment, or the
    iterator form (range item → int, other iterables → unresolved, destructure → two unresolved
    bindings); infer the body.
  - `.switch_stmt`: infer the discriminant, and per case bind enum payloads
    (`bindSwitchPayloads`), infer case values/guard/body; infer the default.
  - `.return_stmt`: infer the value with `current_ret` expected; flag a C-chk-3 `RetOptionalError`
    when the value is optional but the declared return is a plain type; set `captured_return` when
    resolved.
  - `.defer_stmt`: infer the deferred expression.
  - `.break_stmt`/`.continue_stmt`: nothing.

- **`fn checkPlainTarget(self, span, want, got, ctx) void`** (private): the L2/C-chk-6 check:
  record a `ValoptPosError` when `want` is a resolved plain (non-optional/unresolved/any/error-
  union/type-param) type and `got` is a resolved optional. Fail-closed only on both sides resolved.

- **`fn checkCond(self, cond, ctx) !void`** (private): the A1/C-chk-4 check: infer the condition
  (so its subexpressions are typed and narrowings computed), then record a `CondTypeError` if the
  resolved type is not bool. Unresolved is exempt to avoid false positives.

- **`fn checkMethodArity(self, fnp, args, fa, owner_name, span) void`** (private): the A1/C-chk-1
  exact-arity check. `fnp` includes the leading `self`. Distinguishes an instance call (self
  implicit, receiver is a bound local or non-owner-name) from a static/UFCS call (self explicit,
  receiver is the bare owner type name), adjusting the expected count accordingly. Records a
  `MethodArityError` on mismatch.

- **`fn warnIfDeprecated(self, fd, span) void`** (private): FR-safety-6: print a yellow
  compile-time **warning** (never an error) to stderr at a call site whose callee carries a
  `@deprecated` attribute, including the optional migration note. `self` is unused.

- **`fn bindSwitchPayloads(self, disc_t, c) !void`** (private): bind the payload bindings of an
  enum switch case. For a call-form pattern `Variant(x)` it binds `x` to the single payload type,
  or, for a tuple-form multi-payload `Rect(w, h)`, binds each positional to the matching field type.
  For a struct-init form `Variant { a, b }` it binds each named field's ident to its declared field
  type. Only fires when the discriminant is an enum.

- **`pub fn inferFunction(self, f) !void`**: infer a top-level function; delegates to
  `inferFunctionWithSelf(null, f)`.

- **`pub fn inferFunctionWithSelf(self, self_ty, f) !void`**: the per-function driver. Pushes a
  scope; sets `current_module` (from the function's file) and mirrors it onto the lowerer; sets
  `current_ret` (lowered declared return); binds `self` when `self_ty` is given; binds each
  parameter (lowered, unresolved when untyped); infers the body statement sequence; then runs
  `closureSecondPass` to retype any closures that could not be pinned on the first pass. Restores
  module/ret/lowerer-module and pops the scope via defers.

- **`fn callArgTypesDeep(self, e, name, arity) !?[]TypeId`** (private): recursively search an
  expression tree for a call `name(args)` of the given arity and return the quietly-inferred
  argument types. Descends into every sub-expression kind (calls, generic calls, templates, binary,
  unary, cast, nullish, optional-chaining, field-access, index, if-expr, try/await/go, tuple), so it
  finds a call nested inside `${name(a,b)}`. Returns an owned slice.

- **`fn closureCallExpectation(self, name, arity) !?TypeId`** (private): look ahead in
  `current_stmt_seq` for a call to the just-bound closure name and, if found with at least one
  known argument type, build the expected `.func` type (params = argument types, ret = unresolved)
  used to pin the closure's params on the first pass. Frees the intermediate arg slice.

- **`fn closureSecondPass(self, fn_body) !bool`** (private): after the body is walked once, for
  each `let name = closure` in the top-level body, try to retype it from a later call site
  (`retypeBoundClosure`). Returns whether anything was retyped.

- **`fn retypeBoundClosure(self, fn_body, name, cl_init) !bool`** (private): if a bound closure's
  recorded type still has unresolved params, search the body for a call `name(args)`
  (`findCallArgTypes`), build the expected `.func` type from the known argument types, and re-infer
  the closure with it expected. Returns true when the re-inference produced a fully resolved
  `.func` (worth re-walking the enclosing body).

- **`fn findCallArgTypes(self, block, name, arity) !?[]TypeId`** (private): search a block (and
  the bodies of nested if/while/for and sub-blocks) for a call `name(args)` matching arity, via
  `callArgTypesInExpr`. Returns an owned arg-type slice.

- **`fn findCallArgTypesStmt(self, sp, name, arity) !?[]TypeId`** (private): the single-statement
  variant of the above (recursing into a block statement).

- **`fn callArgTypesInExpr(self, ep, name, arity) !?[]TypeId`** (private): the shallow search: a
  direct call `name(args)` of the given arity (or one nested in another call's arguments) yields
  the quietly-inferred argument types. Unlike `callArgTypesDeep` it only descends through call
  arguments, not every expression kind.

### The closure story (why there are two passes)

A closure like `(a, b) => a + b` cannot be typed from its body alone, both params are only used
against each other. The engine handles this in three cooperating places: (1) `inferExprInner`'s
`.closure` arm pins params from an expected `.func` type or from `paramFromUse`, caches a resolved
`.func` in the IR, and reuses that cache on a no-expectation re-inference; (2) at a `let f = closure`
site, `inferStmt` calls `closureCallExpectation` to look ahead to a `f(args)` call in the same block
and pin params from the argument types on the first pass; (3) `closureSecondPass` /
`retypeBoundClosure` run after the whole body is walked to retype any still-unresolved closures from
their call sites. The in-file tests `F2: a closure's params come from the EXPECTED type`, `... from
its USE in the body`, and `(a, b) => a + b stays unresolved` pin these behaviours, including the
deliberate limit that a mutually-dependent closure with no call site stays unresolved rather than
guessed.

### In-file tests

The bottom third of the file is a `std.testing` suite exercising the engine through a `Fixture`
(a `TypeStore` + `SymbolTable` + `Lowerer`). Notable cases: literals get honest types (an int
literal is `int`, not the machine word); a comparison is `bool` not `i32`; a binary over two
unknowns stays unresolved; a let binding's type flows to its uses; `TypedIr` records by expression
identity, records sub-expressions, refuses `.unassigned` ids, and reports an honest
`unresolvedCount`; bitwise `&`/`|` yield the operand type while `&&`/`||` yield bool; assignment
yields the assigned value not void; the F4 generic substitution cases (`List<string>.get()`,
generic function calls, a generic struct field, a function-typed field call); the F2 narrowing
cases (`if (s != undefined)` narrows the then-branch, `== undefined` narrows the else-branch, only a
plain binding narrows); the closure cases above; and `go`/`await` future wrapping/unwrapping. The
helper `stampIds` walks expressions with an `ids.Assigner` so the `TypedIr` keys are populated, and
`genericListProgram` builds a minimal generic `List` decl. These tests double as the executable spec
for the trickier inference rules.

### Cross-references

- **`symbols.zig`**: the read-only `SymbolTable` (`self.symtab`). Inference calls it constantly:
  `findFunction`, `findFunctionIn`, `findFunctionAmbiguous`, `findFunctionBySegment`,
  `findTypeInModule`, `findMethodInModule`, `findModuleByImportName`, `findModuleBySegment`,
  `resolveImportedModule`, `findModuleByFile`, `symbolAt`, and the `symbols.items` scan in
  `constType`. `ModuleId` and `Symbol.decl` shapes (function/struct/enum/trait/constant) drive
  every resolution branch.
- **`subst.zig`**: parameter solving and substitution: `solveParams` (solve type params against
  actual types), `substitute`/`substituteOne` (substitute solved bindings into a lowered type). The
  backbone of generic return-type inference in `freeFnReturn`, `methodReturn`,
  `explicitMethodReturn`, `lowerInStructScope`, `lowerInMethodScope`, and `.struct_init`.
- **`mono.zig`**: monomorphisation notes: `noteFreeFnInst`, `noteMethodInst`, `noteBaseNeeded`.
  Inference tells `mono` which concrete instantiations codegen must emit, only when all type args
  solved concretely.
- **`ownership.zig`**: consumes `ownedDisposition`/`expr_owned`/`expr_op` (and `store.isOwnedSafe`)
  to place ARC retains/releases; inference produces the owned/move/drop facts it reads.
- **`shadow.zig`**: the `KYTE_SEMA_SHADOW` diff harness that compares the two type engines over
  the shared `TypeStore`; the `Stats` coverage numbers here are how that comparison is gauged.
- **`types.zig`**: the `TypeStore` and `TypeId`: minting (`intT`, `stringT`, `boolT`, `voidT`,
  `doubleT`, `decimalT`, `unresolvedT`), interning (`.array`, `.tuple`, `.func`, `.future`,
  `.optional`, `.struct_`, `.enum_`, `.storage`, `.trait_`), and reading (`store.get`,
  `store.isOwnedSafe`). Also `lower.zig` (the `Lowerer` and `ParamScope` used for scoped lowering),
  `ast.zig` (the node shapes walked), `ids.zig` (the `ExprId` assigner keying the IR), and
  `builtins.zig` (`findExtern`, `find`, `isReceiver`, `retType` for builtin functions/receivers).
