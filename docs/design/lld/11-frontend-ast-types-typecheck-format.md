# Frontend LLD: AST, types, type checker, and formatter

This part of the reference covers the four frontend files that sit between the parser and the authoritative sema pass. `src/frontend/ast.zig` defines the whole abstract syntax tree, the node types the parser builds and everything downstream consumes. `src/frontend/types.zig` defines `TypeRef`'s successor, the interned `Type` plus the `TypeStore` (the hash-consed type table that gives every distinct type a stable `TypeId`, so type equality becomes id equality). `src/frontend/type_checker.zig` is the legacy checking pass: a name-and-`TypeRef` based walk that catches soundness defects (trait to concrete narrowing, narrowing integer conversions, missing struct fields, non-exhaustive switches, and so on) and emits pretty diagnostics before the heavier sema pass runs. `src/frontend/formatter.zig` is `nova fmt`: it walks the same AST and re-emits canonical Nova source. Keep in mind that the type checker deliberately defers many hard cases (colliding module names, generics) to the authoritative sema pass under `src/sema/`; its job here is fast, high-value rejection with good error text, not full inference.

---

## `src/frontend/ast.zig` (544 lines)

**Role in the pipeline:** This is the shared vocabulary of the whole compiler. The parser produces a `Program` of these nodes; the type checker, formatter, sema pass, and codegen all read them. There is no behaviour here, only data definitions (plus a couple of `enum`s that carry an ordinal). Because so many nodes are synthesised or desugared elsewhere in the compiler (tuples, closures, serde helpers), several fields carry defaults so that a hand-built node still compiles.

**Key types and data structures.** Everything is `pub`. Working top to bottom:

- **`Span`** -- source location: `start`, `end` (byte offsets), `line`, `col`, and `file` (the source path). A line of 0 conventionally means "unset".
- **`Program`** -- the whole compilation unit: a slice of `Declaration` plus a `Span`.
- **`Declaration`** -- tagged union of the top-level forms: `fn_decl`, `struct_decl`, `union_decl`, `enum_decl`, `const_decl`, `import_decl`, `export_decl`, `trait_decl`.
- **`FunctionDecl`** -- `name`, `params` (`[]Param`), `ret_type` (optional `TypeRef`), `body` (`Block`), `is_exported`, `attributes`. Also `type_params` (generic parameter names, default empty), `is_async` (default false), `extern_lib` (optional library name for an `extern("lib")` FFI function), and `span`.
- **`Param`** -- `name`, optional `type_name` (`TypeRef`), `span`.
- **`StructDecl`** -- `name`, `fields`, `methods`, `attributes`, `impls` (`[]TraitImpl`), `is_public`. `is_reference` (default true) encodes value versus reference semantics: `class` declarations are reference types (heap plus ARC plus identity), `struct` declarations are value types. The default is true so any synthetically built struct keeps today's reference behaviour, and codegen ignores the bit until value-type lowering is wired. `type_params` (default empty) and `span`.
- **`UnionDecl`** -- `name`, `fields`, `is_public`, `span`. A C-style union (untagged), distinct from an enum.
- **`Field`** -- `name`, `type_name` (`TypeRef`, required here unlike `Param`), `is_public`, `span`.
- **`MethodDecl`** -- `is_public`, `is_static`, and the underlying `decl` (`FunctionDecl`). This is the wrapper that carries method visibility and static-ness around a normal function declaration.
- **`EnumDecl`** -- `name`, `variants`, `methods`, `attributes`, `span`, and `is_exception` (default false). An `exception` is an enum the compiler requires to provide a `message(self): string` method; it is used as the error side of a `T | E` union, and the parser sets `is_exception` for the `exception` keyword.
- **`Variant`** -- one enum variant: `name`, optional `value` (`i64`, for `= N` discriminant values), optional `fields` (struct-form payload), optional `type_name` (single-type tuple-form payload), `span`.
- **`TraitImpl`** -- a trait an `impl` block claims: `name` plus `type_args` (default empty), e.g. `impl Comparable<int>`.
- **`TraitDecl`** -- `name`, `methods` (`[]TraitMethodDecl`), `is_public`, `type_params` (default empty), `span`.
- **`TraitMethodDecl`** -- `name`, `params`, optional `ret_type`, `is_async` (default false), and `default_body` (optional `Block`): a default method body copied onto an implementing struct that does not override it (see `expandTraitDefaults` elsewhere). `span`.
- **`ConstDecl`** -- `name`, `value` (`Expression`), `is_exported`, `span`.
- **`ImportDecl`** -- `module` (path string) plus `items` (`[]ImportItem`), `span`.
- **`ImportItem`** -- imported `name`, optional `alias`, `span`.
- **`ExportDecl`** -- `name`, `kind` (`ExportKind`), `span`.
- **`ExportKind`** -- enum: `@"fn"`, `@"struct"`, `@"const"`.
- **`Attribute`** -- tagged union of decoration attributes: `route` (`RouteAttr`), `serializable`, `@"test"`, `summary` (string), `description` (string), `tags` (`[][]const u8`), `request_body` (`TypeRef`), `response` (`ResponseAttr`), and `deprecated` (optional replacement note string; a call to a deprecated function emits a warning, not an error).
- **`RouteAttr`** -- HTTP `method` plus `path`.
- **`ResponseAttr`** -- `status` (`i32`), `type_ref` (`TypeRef`), optional `description`.
- **`TypeRef`** -- the syntactic type as written in source (distinct from the semantic `Type` in `types.zig`). Tagged union:
  - `ident` -- a bare name (`int`, `string`, `Foo`).
  - `optional` -- `*TypeRef`, the `T | undefined` form.
  - `error_union` -- a struct `{ ok: *TypeRef, err: *TypeRef }`, the `T | E` form.
  - `fixed_array` -- `{ element: *TypeRef, length: usize }`, a compile-time sized array.
  - `generic` -- `{ name: []const u8, params: []TypeRef }`, e.g. `List<int>`.
  - `func` -- `{ params: []TypeRef, ret: *TypeRef }`, a function type.
  - `tuple` -- `[]TypeRef`, an anonymous tuple type.
- **`Statement`** -- tagged union of statement forms: `block`, `let_stmt`, `expr_stmt`, `if_stmt`, `while_stmt`, `for_stmt`, `switch_stmt`, `return_stmt`, `break_stmt`, `continue_stmt`, `defer_stmt`.
- **`Block`** -- `statements` slice plus `span`.
- **`LetStmt`** -- `name` (single binding), `names` (optional `[][]const u8`, present only for tuple destructuring `let (a, b) = e`), optional `type_name`, optional `init` expression, `is_const`, `span`.
- **`ExprStmt`** -- `expr` plus `span`.
- **`DeferStmt`** -- `expr`, `is_err` (default false; true for `errdefer`, which only runs on the error path), `span`.
- **`IfStmt`** -- `condition`, `then_branch` (`*Statement`), optional `else_branch` (`?*Statement`), `span`.
- **`WhileStmt`** -- `condition`, `body` (`*Statement`), `span`.
- **`ForStmt`** -- the union of C-style and for-in loops: optional `initializer` (`?*Statement`), optional `condition`, optional `increment`, optional `iterator` (`?ForIterator`, the for-in form), `body` (`*Statement`), `span`. A C-style loop leaves `iterator` null; a for-in loop leaves the three C-style fields null.
- **`ForIterator`** -- `binding` (`ForBinding`) plus `iterable` (`*Expression`).
- **`ForBinding`** -- tagged union: `item` (a single loop variable name) or `destructure` (`{ key, value }`, for iterating key/value pairs).
- **`RangeExpr`** -- `start` and `end` (`*Expression`), `inclusive` (`..=` vs `..`), `span`. Used both as an expression kind and standalone.
- **`SwitchStmt`** -- `discriminant`, `cases` (`[]SwitchCase`), optional `default_case` (`?*Statement`), `span`.
- **`SwitchCase`** -- `values` (one or more matched expressions), optional `guard` (a `case v if cond:` guard; a matched-but-guard-false case falls through to `default`), `body` (`*Statement`), `span`.
- **`ReturnStmt`** -- optional `value`, `span`.
- **`BreakStmt`** / **`ContinueStmt`** -- just a `span` each.
- **`ExprId`** -- `enum(u32)` with `unassigned = 0` and an open tag; a stable per-expression identifier assigned downstream.
- **`Expression`** -- wrapper carrying `id` (`ExprId`, default `.unassigned`), `kind` (`ExprKind`), and `span` (defaulted to an unset span so synthesised expressions compile; the parser fills it for user-written primaries so diagnostics can point at file:line:col).
- **`ExprKind`** -- the big expression tagged union:
  - `literal` (`Literal`), `ident` (name), `binary` (`BinaryExpr`), `unary` (`UnaryExpr`), `call` (`CallExpr`), `generic_call` (`GenericCallExpr`), `field_access` (`FieldAccess`), `index` (`IndexExpr`), `struct_init` (`StructInit`), `enum_init` (`EnumInit`), `cast` (`CastExpr`).
  - `range` (`RangeExpr`), `optional_chaining` (`OptionalChaining`), `nullish_coalesce` (`NullishCoalesce`), `jsx_element` (`JsxElement`), `closure` (`Closure`), `tuple` (`[]Expression`), `if_expr` (`IfExpr`), `block_expr` (`Block`).
  - `try_expr` (`*Expression`).
  - `catch_expr` -- anonymous struct `{ expr: *Expression, err_name: ?[]const u8, handler: *Expression }`.
  - `template_expr` (`TemplateExpr`), `await_expr` (`AwaitExpr`), `go_expr` (`AwaitExpr`; the `spawn`/`go` form, reusing `AwaitExpr`'s single-operand shape).
- **`AwaitExpr`** -- `operand` (`*Expression`), `span`. Shared by `await_expr` and `go_expr`.
- **`TemplateExpr`** -- `parts` (`[]Expression`, alternating string-literal and interpolated pieces), `span`.
- **`IfExpr`** -- `condition`, `then_branch`, `else_branch` (all `*Expression`), `span`. The expression form of `if`.
- **`Literal`** -- tagged union: `integer` (`i64`), `float` (`f64`), `decimal` (string, the raw digits of a `decimal` literal), `string`, `bool`, `null`, `undefined`, `array` (`[]Expression`), `array_repeat` (`ArrayRepeat`), `object` (`[]ObjectFieldInit`).
- **`ArrayRepeat`** -- `[value; count]`: `value` (`*Expression`, evaluated once) and `count` (`usize`, a compile-time constant length).
- **`ObjectFieldInit`** -- `name`, `value` (`Expression`), `span`. A single field in an object/struct literal.
- **`BinaryExpr`** -- `left`, `op` (`BinaryOp`), `right`, `span`.
- **`BinaryOp`** -- enum: `add, sub, mul, div, mod, eq, ne, lt, gt, le, ge, bit_and, bit_or, bit_xor, assign, And, Or, shl, shr`. Note `And`/`Or` are the short-circuit logical operators (capitalised to avoid the Zig keywords), distinct from the bitwise `bit_and`/`bit_or`.
- **`UnaryExpr`** -- `op` (`UnaryOp`), `operand`, `span`.
- **`UnaryOp`** -- enum: `neg`, `not`, `bit_not`.
- **`CallExpr`** -- `callee` (`*Expression`), `args` (`[]Expression`), `span`.
- **`GenericCallExpr`** -- like `CallExpr` plus `type_args` (`[]TypeRef`), the explicit `<T>` at a call or constructor.
- **`FieldAccess`** -- `object` (`*Expression`), `field` (name), `span`.
- **`IndexExpr`** -- `object`, `index` (both `*Expression`), `span`.
- **`StructInit`** -- `type_name`, `fields` (`[]ObjectFieldInit`), `type_args` (default empty; explicit `Foo<int>{ ... }` args, which are authoritative when present and bound positionally to the struct's type params), `span`.
- **`EnumInit`** -- `enum_name`, `variant`, `fields` (`[]ObjectFieldInit`, the struct-form payload), `span`.
- **`CastExpr`** -- `expr` (`*Expression`), `target_type` (`TypeRef`), `span`. The `as` cast.
- **`OptionalChaining`** -- `object`, `field`, `span`. The `?.field` form.
- **`NullishCoalesce`** -- `left`, `right` (both `*Expression`), `span`. The `??` form.
- **`JsxElement`** -- `tag`, `attributes` (`[]JsxAttribute`), `children` (`[]JsxChild`), `span`. The NSX/JSX hypermedia literal.
- **`JsxAttribute`** -- `name`, `value` (`JsxAttributeValue`), `span`.
- **`JsxAttributeValue`** -- tagged union: `string_literal` or `expression`.
- **`JsxChild`** -- tagged union: `element` (nested `JsxElement`), `expression`, `text` (raw string), `statement`.
- **`Closure`** -- `params` (`[][]const u8`, bare names), `param_types` (default empty; optional per-parameter types), `body` (`ClosureBody`), `span`.
- **`ClosureBody`** -- tagged union: `expr` (`*Expression`, expression body) or `block` (`Block`).

**Module-level state and constants.** None. This file is pure type definitions plus one `const std` import.

**Functions.** None. `ast.zig` declares no functions at all.

**Gotchas and invariants.**
- `Expression.span` and `Expression.id` are defaulted precisely so the many synthesised expressions across the compiler keep compiling; do not assume a span's `line` is meaningful without checking for 0.
- `optional` and `error_union` in `TypeRef` are separate variants even though both spell with `|` in source (`T | undefined` versus `T | E`). The formatter re-emits `optional` as `... | undefined`.
- `go_expr` deliberately reuses `AwaitExpr` for its payload shape; do not read `is_async`-style flags off it.
- `is_reference` on `StructDecl` is presently inert in codegen; treat it as metadata until value-type lowering lands.

**Cross-references.** Consumed by `type_checker.zig` and `formatter.zig` (both in this document), by the parser that builds it, by `src/sema/*`, and by `src/codegen/*`. The semantic counterpart to `TypeRef` is `Type` in `types.zig` below.

---

## `src/frontend/types.zig` (457 lines)

**Role in the pipeline:** This is the semantic type layer, the successor to the syntactic `TypeRef`. Where `TypeRef` is "what the programmer wrote", `Type` is "what the type actually is", and `TypeStore` interns (hash-conses) every distinct `Type` so that two structurally equal types share one `TypeId`. That is the whole point: after interning, type equality is a `u32` comparison, and monomorphization can key on ids. The file also owns the ownership decision (`isOwned`), which drives ARC in codegen: ownership is derived from the type, never from a spelling.

The bulk of the file below the store is a test suite that pins the invariants (interning is idempotent, `u64` is not `i64`, `List<string>` and `List<int>` are distinct, a function is a type not a name with an arrow, and interned types never alias caller memory).

**Key types and data structures.** All `pub` unless noted:

- **`SymbolId`** -- re-exported from `sema/symbols.zig`. A declaration's stable identifier.
- **`TypeId`** -- `enum(u32)` with an open tag. The interned handle for a `Type`. Equality of `TypeId` is equality of type.
- **`PrimKind`** -- enum: `bool`, `int`, `float`, `void_`.
- **`PrimType`** -- a primitive: `kind` (`PrimKind`), `bits` (`u16`), `signed` (default true). Has one method, `eql` (below). Signedness is carried, not spelled, so `u64` and `i64` are distinct types.
- **`StructType`** -- `decl` (`SymbolId`) plus `args` (`[]const TypeId`, the generic instantiation args, default empty). `List<int>` and `List<string>` share a `decl` but differ in `args`.
- **`FuncType`** -- `params` (`[]const TypeId`) plus `ret` (`TypeId`).
- **`ArrayType`** -- `elem` (`TypeId`) plus `len` (`usize`). Arrays differ by both element and length.
- **`TypeParam`** -- `owner` (`SymbolId`, the declaration that introduces the parameter) plus `index` (`u32`). A generic parameter is a type, keyed by owner and position, not a one-letter string.
- **`ErrorUnionType`** -- `{ ok: TypeId, err: TypeId }`.
- **`Type`** -- the interned type tagged union: `prim` (`PrimType`), `string`, `decimal`, `ptr` (unowned/manual pointer), `any_` (a type-erased owning carrier, a refcounted `nova_any_box { payload, dtor }` at runtime, distinct from `ptr` so the ownership machinery releases it), `struct_` (`StructType`), `enum_` (`SymbolId`), `trait_` (`SymbolId`), `func` (`FuncType`), `optional` (`TypeId`), `error_union` (`ErrorUnionType`), `tuple` (`[]const TypeId`), `array` (`ArrayType`), `type_param` (`TypeParam`), `storage` (`TypeId`), `future` (`TypeId`), `unresolved` (the honest "not yet known", distinct from any real type).

**Module-level state and constants.** `const std`, `const symbols`. `const testing = std.testing` (test-only). No mutable module state; all state lives in a `TypeStore` instance.

**Functions.** In source order:

- **`fn hashType(t: Type) u64`** (private). Wyhash over the type. Starts with the active tag byte, then hashes each variant's payload field by field: prim hashes kind/bits/signed; the payloadless variants (`string`, `decimal`, `ptr`, `any_`, `unresolved`) add nothing beyond the tag; struct hashes `decl` and every arg id; func hashes each param id and the ret; and so on for optional/future/storage/tuple/array/type_param. Pure, no allocation. It is the hash half of the intern map's context.

- **`fn eqlIds(a: []const TypeId, b: []const TypeId) bool`** (private). Length-then-element-wise id comparison of two id slices. Pure.

- **`fn eqlType(a: Type, b: Type) bool`** (private). Structural equality of two `Type`s. First compares active tags, then compares payloads per variant (prim via `PrimType.eql`, struct via `decl` plus `eqlIds(args)`, func via `ret` plus `eqlIds(params)`, tuple via `eqlIds`, array via elem and len, type_param via owner and index, and so on). Pure. It is the equality half of the intern map's context.

- **`PrimType.eql(a: PrimType, b: PrimType) bool`** (pub, method). True when kind, bits, and signed all match. This is what makes signedness and width load-bearing.

- **`const TypeContext`** (private struct) with methods **`hash`** and **`eql`** -- the `std.HashMap` context wrapping `hashType`/`eqlType`.

- **`TypeStore`** (pub struct) -- the interning table. Fields: `allocator`; `types` (an `ArrayListUnmanaged(Type)`, indexed by `TypeId`); `map` (a `HashMapUnmanaged(Type, TypeId, TypeContext, ...)`, the reverse lookup for hash-consing); `owned_slices` (an `ArrayListUnmanaged([]TypeId)` tracking every id slice the store duplicated, so `deinit` can free them); and `enum_tagged` (an `AutoHashMapUnmanaged(SymbolId, bool)` recording which enums are tagged unions, which decides their ownership). Its methods:
  - **`init(allocator) TypeStore`** (pub) -- returns a store with just the allocator set, everything else empty.
  - **`deinit(self) void`** (pub) -- frees every owned id slice, then the three collections and the tagged-enum map. The `Type` values themselves are not separately freed (only the id slices they point at are store-owned).
  - **`setEnumTagged(self, sid, tagged) !void`** (pub) -- records whether an enum symbol is a tagged union. Allocates a map entry. Feeds `isOwned`.
  - **`ownIds(self, ids) ![]const TypeId`** (private) -- duplicates a caller id slice into store-owned memory and records it in `owned_slices` so interned types never alias caller memory (a pinned invariant, see the last test). Returns the empty slice unchanged for length 0.
  - **`own(self, t) !Type`** (private) -- deep-copies the only variants that hold id slices (`struct_.args`, `func.params`, `tuple`) via `ownIds`, and returns every other variant unchanged. Called before a `Type` is stored so the stored copy owns its slices.
  - **`intern(self, t) !TypeId`** (pub) -- the core operation. If the type is already in `map`, returns the existing id (idempotent). Otherwise `own`s it, assigns the next id (`types.items.len`), appends to `types`, records it in `map`, and returns the new id. Allocates via the owning path. This is what makes id equality mean type equality.
  - **`get(self, id) Type`** (pub, const) -- returns the `Type` at that id (a direct index into `types`). No bounds check beyond Zig's slice indexing.
  - **`count(self) usize`** (pub, const) -- number of distinct interned types.
  - The primitive constructors, each `pub` and each just `intern`ing a fixed `Type`: **`boolT`** (bool, 1-bit, unsigned), **`intT`** (int, 32-bit signed), **`uintT`** (int, 32-bit unsigned), **`longT`** (int, 64-bit signed), **`byteT`** (int, 8-bit unsigned), **`doubleT`** (float, 64-bit), **`vecF64x4T`** (a 256-bit float prim, the f64x4 SIMD vector, rendered as `f64x4`), **`vecU8x16T`** / **`vecU32x4T`** / **`vecU64x2T`** (128-bit integer SIMD vectors encoded with a bijective sentinel `bits = elementBits*1000 + laneCount` to avoid colliding on total bits, decoded back to a name in `renderLegacy` and to an LLVM vector type in the codegen slot picker), **`floatT`** (float, 32-bit), **`voidT`** (void, 0 bits), **`stringT`**, **`decimalT`**, **`ptrT`**, **`anyT`**, **`unresolvedT`**. All allocate through `intern` and are idempotent.
  - **`isOwned(self, id) bool`** (pub, const) -- the ownership decision that drives ARC. `prim` and `ptr` are not owned; `any_`, `string`, `decimal`, `struct_`, `array`, `tuple`, `error_union`, `func`, `trait_`, and `storage` are owned; `future` is not owned; an `enum_` is owned only if it is tagged (looked up in `enum_tagged`, defaulting false); an `optional` inherits the ownership of its inner type. `type_param` and `unresolved` are `unreachable` (asking is a bug: ownership of an unresolved or still-generic type is not yet decided).
  - **`isOwnedSafe(self, id) bool`** (pub, const) -- the same question but total: `type_param` and `unresolved` answer false instead of panicking, `optional` recurses, everything else defers to `isOwned`. Use this at call sites that can legitimately see an unresolved type.

- The remaining declarations are `test` blocks (`T1` idempotency, `TypeId` equality is type equality, signedness carried, `List<string>` vs `List<int>` distinct, functions are types, generic params are types, `unresolved` is representable and not int, optionals nest and compare structurally, ownership from type not spelling, arrays differ by element and length, tuples compare element-wise and are ordered, and interned types never alias caller memory). They document and pin every invariant above.

**Gotchas and invariants.**
- `isOwned` panics (`unreachable`) on `type_param` and `unresolved`. If you might hold either, call `isOwnedSafe`.
- SIMD vector types are smuggled through `PrimType.bits`: 256 means f64x4, and any `int` prim with `bits > 64` is the `elementBits*1000 + laneCount` encoding. Do not treat `bits` as a literal width for those.
- Interning duplicates id slices into store memory (`ownIds`); a caller may freely mutate or free its own scratch slice afterwards (the last test pins this).
- `intern` is the only correct way to create a `TypeId`; do not `@enumFromInt` a raw value.

**Cross-references.** `SymbolId` comes from `sema/symbols.zig`. `TypeStore` is the backbone the sema pass (`src/sema/`) builds on, and `isOwned` is consulted by `src/codegen/arc.zig`. The syntactic counterpart, `TypeRef`, lives in `ast.zig` above; the type checker in this document still works in `TypeRef`, not `Type`.

---

## `src/frontend/type_checker.zig` (1995 lines)

**Role in the pipeline:** This is the legacy, `TypeRef`-based checking pass. It runs before the authoritative sema pass and its job is to catch a specific, high-value set of errors with good diagnostics: duplicate declarations, arity mismatches, missing struct fields, non-exhaustive switches, narrowing and signedness integer conversions, pointer truncation, unsound trait-to-concrete narrowing (the use-after-free class), invalid index targets, private member access, wasm-unavailable async, and a handful more. It is deliberately conservative: whenever a name is ambiguous across modules (colliding structs/enums, ambiguous free functions) it defers to the sema pass rather than validate against the wrong declaration, and it fails open on unknowns so valid generic code is never rejected.

The checker holds flat name to declaration maps (last writer wins), a per-function variable environment it clears between functions, and small pieces of context (current return type, current struct, whether inside an async function, whether inside an await). Type resolution is best-effort: `resolveExprType` returns an optional `TypeRef`, and most checks bail out (fail open) when it returns null.

**Key types and data structures.**

- **`Diagnostic`** (pub struct) -- a structured, span-carrying diagnostic kept alongside the pretty-printed `errors` strings so tooling (the language server) can map each error back to a source range instead of scraping ANSI text. Fields: `file`, `start` (byte offset of the reported node's start, reliable unlike `span.end`), `line`, `col`, `message` (plain text, no colour codes).
- **`IntRange`** (private struct) -- `{ min: i128, max: i128 }`, used by the literal range check.
- **`TypeChecker`** (pub struct) -- the pass itself. Fields:
  - `allocator`.
  - `errors` (`ArrayList([]const u8)`) -- the pretty, ANSI-formatted error strings.
  - `structured` (`ArrayList(Diagnostic)`) -- the span-carrying view of the same errors.
  - `silent` (default false) -- when true, `check` does not print the failure summary to stderr; the language server sets this.
  - `file_sources` (`*StringHashMap([]const u8)`) -- file path to source text, for rendering the offending line under an error.
  - `enums`, `variables`, `structs`, `unions`, `traits`, `functions` -- flat name to declaration maps. `variables` maps a name to its `TypeRef` and is the per-scope environment.
  - `colliding_structs`, `colliding_enums` (`StringHashMap(void)`) -- names defined in more than one module. The flat maps are last-writer-wins, so these record which names the legacy arity/narrowing/exhaustiveness checks must skip and defer to sema.
  - `ambiguous_fns` (`StringHashMap(void)`) -- function names defined more than once across imported modules; a bare call to one is ambiguous.
  - `fn_def_sites` (`StringHashMap(void)`) -- keyed by `file\x00name`, tracks where a function is defined (for duplicate detection and `fileDefinesFn`).
  - `fn_first_line` (`StringHashMap(usize)`) -- first-seen line per `file\x00name`, for the duplicate-function diagnostic.
  - `current_struct` (optional name) -- the struct/enum whose methods are being checked, for the own-methods case of visibility.
  - `current_ret_type` (default null) -- the return type of the function currently being checked.
  - `in_async` (default false), `in_awaited` (default false) -- context flags for the async-call rule.
  - `is_wasm` (default false) -- target flag; async/await/spawn are rejected on wasm.

**Module-level state and constants.** No mutable globals. `const std`, `const ast`, `const builtins` (`sema/builtins.zig`). The free functions below the struct (canonicalisation, compatibility, AST-walk helpers) are stateless.

**Functions.** In source order. The free helper functions at the top come first, then the `TypeChecker` methods, then the free functions after the struct.

Top-of-file free helpers:

- **`fn builtinRetType(r: builtins.Ret) ?ast.TypeRef`** (private) -- maps a builtin method's return-kind enum to a `TypeRef` (`void_` to `void`, `int` to `i32`, `long` to `i64`, `ptr`, `string`, `bool_` to `bool`, `decimal`, `double` to `f64`, and the four SIMD vector kinds to their names). Pure.
- **`fn isPtrTruncation(from, to) bool`** (private) -- true when `from` is `ptr` and `to` is a narrower integer (`i8`/`i16`/`i32`), the memory-unsafe case where an address is stored into something too small to hold it. Uses `canonicalizeTypeName`. Pure.
- **`fn intTypeRange(name) ?IntRange`** (private) -- the representable `[min, max]` for `i8`/`i16`/`i32` (and their unsigned spellings), else null. Signedness inferred from the name prefix. Pure.
- **`fn intWidthOf(name) ?u32`** (private) -- the bit width for `i8`/`i16`/`i32`/`i64`, else null. Pure.
- **`fn isNarrowingInt(from, to) bool`** (private) -- true when both are integer idents and `from` is wider than `to`. Pure.
- **`fn intNameSigned(name) bool`** (private) -- true unless the name starts with `u` or is `byte`. Pure.
- **`fn isSignednessMismatch(from, to) bool`** (private) -- true when two same-width integer idents differ in signedness. Pure.
- **`fn intLiteralValue(expr) ?i128`** (private) -- extracts the constant value of an integer literal, recursing through a unary `neg` to handle negative literals. Returns null for anything else. Pure. This is what lets the checker treat literals leniently (a literal in range for the declared type is accepted even if its default `i32` type would not be assignable).
- **`fn identOf(tr) ?[]const u8`** (private) -- the name of an `ident` type ref, else null. Pure.
- **`fn isScalarPrim(name) bool`** (private) -- membership test against the scalar primitive names (int/long/byte/bool/float/double/char and the sized spellings). Pure. Used by the fixed-array element check and the string/scalar clash check.
- **`fn stringScalarClash(a, b) bool`** (private) -- true only for the memory-unsafe clash where one side is `string` (a heap pointer) and the other is a scalar primitive. Kept deliberately narrow so tightening never false-positives on int/long widening, optionals, `any`, or trait widening. Pure.

`TypeChecker` methods:

- **`init(allocator, file_sources) TypeChecker`** (pub) -- constructs the checker with all maps initialised and `current_struct` null.
- **`fileDefinesFn(self, file, name) bool`** (private) -- whether a function of that name is defined in that file, via a `file\x00name` key lookup in `fn_def_sites`. Allocates and frees a temporary key; returns false on allocation failure.
- **`deinit(self) void`** (pub) -- frees every error string, every structured message, all maps, and the heap-allocated `fn_def_sites` keys.
- **`addError(self, span, fmt, args) void`** (private) -- the diagnostic emitter. Formats the user message once; appends a plain copy to `structured` (best-effort, a failed dupe just skips it); then builds the pretty ANSI form (bold `file:line:col: error:` header, the offending source line pulled from `file_sources`, and a green caret under the column) and appends it to `errors`. Allocates; the `errors`/`structured` entries are owned by the checker and freed in `deinit`. Never returns an error (allocation failures are swallowed so checking continues).
- **`check(self, program) !void`** (pub) -- the entry point, two passes. First pass registers every declaration into the flat maps and detects collisions: an enum or struct whose name already exists in a different file is recorded in `colliding_enums`/`colliding_structs`; a repeated function name goes into `ambiguous_fns`; a function redefined at a different line in the same non-generated module raises a duplicate-function error. Second pass dispatches each declaration to `checkFunction`/`checkStruct`/`checkEnum`/`checkConst`/`checkTrait`. Finally, if any errors accumulated, prints the summary (unless `silent`) and returns `error.TypeCheckError`. Mutates all the maps.
- **`checkDuplicateTypeParams(self, decl_name, type_params, span) void`** (private) -- O(n^2) scan reporting any repeated generic parameter name.
- **`checkBoolCondition(self, cond, span) void`** (private) -- resolves the condition's type and errors if it is definitely a non-bool ident (`string`, `i32`, `f64`, `i64`). Fails open on anything it cannot resolve.
- **`checkFunction(self, func) anyerror!void`** (private) -- checks one function. Validates duplicate type params, clears the variable environment, binds each typed parameter into `variables` (rejecting unimplemented types first), rejects async on wasm, then saves/sets `current_ret_type` and `in_async` (restored via `defer`) and checks the body block.
- **`typeRefName(t) []const u8`** (private) -- the name of an ident type ref, or the placeholder `"<type>"` for compound types. Pure. Used only for diagnostics.
- **`rejectUnimplementedType(self, t, span) void`** (private) -- recursively walks a type ref and errors on `i128`/`u128` (removed in F3 3.1; use `long`/`i64`). Recurses through optional, error_union, fixed_array, generic, func, and tuple.
- **`checkReturnType(self, value, span) void`** (private) -- checks a returned expression against `current_ret_type`. Returns early for `void`/`any` returns and single-letter (generic) return types. An integer literal is accepted against any numeric return type. Otherwise resolves the value's type and, if it is an ident and not `assignable` to the declared return, errors. Deliberately lenient: only ident value types are checked.
- **`structImplementsTrait(self, struct_name, trait_name) bool`** (private) -- whether the named struct's `impls` list mentions the trait. Canonicalises the struct name first.
- **`rejectNarrowingArgs(self, args, params) void`** (private) -- the soundness check for trait-to-concrete narrowing. For each aligned (arg, param) pair where the parameter is a concrete struct (not a trait), if the argument resolves to a trait type of a different name, errors: a trait value is a fat pointer that may hold any implementation, so narrowing it needs an explicit `as` downcast. Shared by free-function, method, and constructor calls. Concrete-to-trait widening stays allowed.
- **`rejectNarrowingArgsSubst(self, args, params, tparams, targs) void`** (private) -- the same check for a generic method call (e.g. `List<Dog>.push(traitVal)`): a parameter typed as a type-parameter name is first substituted with the receiver's instantiation arg before the trait-narrowing test, so pushing a trait into a `List<Concrete>` is caught.
- **`assignable(self, from, to) bool`** (private) -- the assignment-compatibility predicate used across the checker. Rejects narrowing-int and signedness mismatches outright; accepts anything `isTypeCompatible`; accepts a struct-to-trait widening (ident or generic trait target when the struct implements it); and accepts the two pointer/int bridges (`ptr` from a numeric, and `ptr` to `i64`). Everything else is not assignable.
- **`checkBlock(self, block) anyerror!void`** (private) -- checks each statement in order.
- **`checkStatement(self, stmt) anyerror!void`** (private) -- the statement dispatcher. Notable cases:
  - `let_stmt`: checks the initialiser; for tuple destructuring (`ls.names`), if the init resolves to a tuple it verifies the name count equals the tuple arity (else errors) and binds each name to its element type. For a typed let it rejects unimplemented types, binds the name, and runs three checks against the initialiser: an out-of-range integer literal for a sized target; and (for a non-literal init that resolves to an ident and is not `assignable`) a narrowing, signedness, or generic type-mismatch error. For an untyped let it binds the name to the inferred init type.
  - `if_stmt`/`while_stmt`: check the condition, run `checkBoolCondition`, recurse into the branch(es)/body.
  - `expr_stmt`, `return_stmt` (which also runs `checkReturnType`), `for_stmt` (checks only the body), `switch_stmt` (delegates to `checkSwitch`), `defer_stmt`.
- **`structInitParamCount(self, struct_name) ?usize`** (private) -- the parameter count of the struct's `init` method, or null if it has none. Used for constructor arity checks.
- **`structInitParams(self, struct_name) ?[]ast.Param`** (private) -- the `init` method's parameter slice, or null. Used to reject trait-to-concrete narrowing on a constructor argument.
- **`checkExpr(self, expr) anyerror!void`** (private) -- the expression checker, the largest method. Highlights per kind:
  - `generic_call`: the async-call rule (a call that targets an async function inside an async fn must be awaited or spawned); generic arity check against the struct's or function's type-param count; constructor arity check (skipping colliding structs); then recurses into callee and args.
  - `call`: the async-call rule; for an ident callee that is a constructor, arity plus constructor-arg narrowing rejection; for an ident callee that is a function, arity plus argument narrowing rejection; the ambiguity error for a name defined in more than one imported module; for a field-access callee (a method call), it resolves the receiver's struct (or generic instantiation) and rejects trait-to-concrete narrowing on the method args (skipping the implicit `self`). It special-cases `coroStart(<async call>)` as a spawn point so a bare async call passed to it is allowed.
  - `binary`: for an assignment whose right side is not a plain integer literal, it checks pointer truncation, narrowing, signedness, and trait-to-concrete narrowing (the L1 assignment case) between the resolved right and left types.
  - `literal`: enforces that fixed-array elements are primitives only (int/long/double/float/bool/byte), rejecting a struct/tuple/nested-array element both by resolved type and by syntactic form, pointing at `List<T>` for reference elements. Same for `array_repeat`.
  - `unary`, `field_access`, `index` (which also runs the fail-closed index check via `indexableTypeStatus`), `struct_init` (missing-field check plus F4-1 explicit type-arg validation: arity against the struct's type params, then a narrow string/scalar clash per field), `tuple`, `if_expr`, `template_expr`, `block_expr`, `await_expr` (rejected on wasm, must be inside an async fn, sets `in_awaited`), `go_expr` (same, for `spawn`).
- **`isSwitchableIntType(name) bool`** (private) -- membership test for the integer and integer-like names a switch can lower over (including `bool` and `char`). Pure.
- **`checkSwitch(self, ss) anyerror!void`** (private) -- exhaustiveness and validity for switch. Resolves the discriminant type; for an enum discriminant (skipping colliding enums) it builds a covered-set of variant names, walks each case marking covered variants (an *unguarded* case covers; a guarded case does not, since it may not match), binds payload variables from field-access, call, and struct-init patterns (single-payload and tuple-form multi-payload), checks each case guard after its bindings are in scope, and finally errors for every uncovered variant when there is no `default`. For a non-enum ident that is not a switchable integer type, it errors that the discriminant must be an enum or integer (strings and other types used to miscompile to garbage).
- **`substReturnType(self, tr, tparams, targs) ast.TypeRef`** (private) -- substitutes generic parameter names with concrete type args throughout a return type, recursing through optional, error_union, generic, tuple, fixed_array, and func. Allocates new `TypeRef` nodes for the compound cases (owned by the checker's allocator). Used to resolve a generic call's concrete return type.
- **`methodIsTraitContract(self, s, method_name) bool`** (private) -- whether a method name is part of any trait the struct implements. Used to exempt trait-contract methods from the private-method access error (a trait method is effectively public through the trait).
- **`callTargetsAsync(self, callee) bool`** (private) -- whether a call's callee resolves to an async function or method. Handles an ident callee (a local variable is not a function; else look up the function's `is_async`) and a field-access callee (a builtin is not async; else resolve the receiver's struct/trait/enum and read the method's `is_async`). Drives the async-call rule.
- **`unifyTypeParam(self, decl, actual, tparams, binds) void`** (private) -- one-directional unification binding type parameters from an argument type. `v: T` against `Dog` binds `T = Dog`; `xs: List<T>` against `List<Dog>` binds `T = Dog`; recurses through optional and matching-arity generics. Writes into `binds` (parallel to `tparams`), first binding wins.
- **`inferGenericTypeArgs(self, f, args) ?[]ast.TypeRef`** (private) -- infers a generic function's type args from its argument types (no explicit `<T>`), by unifying each declared param against each actual arg. Returns a slice parallel to `f.type_params`, or null if any parameter is unbound (leave the return unresolved rather than guess). Allocates the binds and output slices. Enables `let x: int = id(42)` type-checking against `int` instead of the raw `T`.
- **`indexableTypeStatus(self, tr) ?bool`** (private) -- the fail-closed index check. Returns true for `fixed_array`/`tuple`; for an ident, true for string/ptr/bytes/RawBuffer, false for a scalar primitive or a known struct/enum, and null (allow, stay fail-open) for an unknown or type-parameter name; null for generic (List/Map use `.get`), optional, error_union, and func. A false result means `[]` is rejected on that type.
- **`memberAccessible(self, decl_file, access_file, type_name) bool`** (private) -- module-private visibility (section 8): a non-`pub` member is accessible anywhere in the same module (same source file) as its declaration, or from within the declaring type's own methods (`current_struct` matches). Cross-module still needs `pub`.
- **`resolveExprType(self, expr) ?ast.TypeRef`** (private) -- best-effort type inference returning an optional `TypeRef`. Highlights:
  - `ident` reads the variable environment; `struct_init`/`enum_init` return the named type; `cast` returns its target; `await_expr`/`go_expr` unwrap the operand.
  - `binary`: assignment resolves to the left type; `+` with a string operand is string; `+`/`-`/`*`/`/`/`%` with a decimal operand is decimal; `+`/`-` with a ptr operand is ptr; other arithmetic defaults to `i32`; comparisons and logical ops are `bool`.
  - `literal`: integer to `i32`, float to `f64`, decimal, bool, string; null/undefined/array/object resolve to null (unknown).
  - `field_access`: resolves the object, then the field's declared type from a struct or union, emitting the private-field access error where applicable.
  - `call`: for a builtin method, the builtin return type; for a module-qualified constructor (`module.StructName(...)`) the struct name; for a struct/enum method, its declared return (emitting the private-method error unless it is a trait contract), defaulting to `void`; for a free function, its return type, running `inferGenericTypeArgs` plus `substReturnType` for a generic function so a typed context sees the concrete type; a bare struct name resolves to that struct type.
  - `generic_call`: a struct constructor carries the explicit type args on a `.generic` type (so downstream narrowing sees `Box<Dog>`), else `.ident`; a function applies `substReturnType`; a module-qualified generic constructor is handled too.
  - `if_expr` resolves to its then-branch type; `jsx_element`, `block_expr`, and `template_expr` all resolve to `string`.
- **`checkStruct(self, s) !void`** (private) -- checks a struct. Sets `current_struct`; checks duplicate type params; reports duplicate method names; rejects unimplemented field types; then for each method clears the environment, binds `self` and the parameters, sets return/async context, and checks the body. Finally validates each trait `impl`: the trait must exist, and for each trait method the struct must provide a matching method (async-ness, parameter count, per-parameter types after substituting the trait's type params with the impl's type args, and return type must all match), else a precise mismatch error.
- **`checkTrait(self, t) !void`** (private) -- reports duplicate method names within a trait.
- **`checkEnum(self, e) !void`** (private) -- checks an enum. Sets `current_struct`; reports duplicate variant names; for an `exception` enforces that a `message(self): string` instance method exists; then checks each method body (binding `self` and params, setting return/async context) exactly as `checkStruct` does.
- **`checkConst(self, c) !void`** (private) -- currently a no-op (`_ = self; _ = c;`). Constants are validated elsewhere.

Free functions after the struct:

- **`fn isScalarPrimitiveName(n) bool`** (private) -- a wider scalar-name membership test (includes `usize`, `void`, `decimal`) used by `indexableTypeStatus`. Pure.
- **`fn canonicalizeTypeName(name) []const u8`** (private) -- folds spelling aliases to a canonical name: `byte`/`ubyte` to `i8`, `short`/`ushort` to `i16`, `int`/`uint` to `i32`, `long`/`ulong` to `i64`, `double` to `f64`, `float` to `f32`, and the unsigned `u8`..`u64` to their signed-width counterparts (`u128` to `i128`). Note this canonicalisation drops signedness (`uint` and `int` both become `i32`), which is why `isSignednessMismatch` checks the raw names, not the canonical ones. Pure.
- **`fn typesAreEqual(a, b) bool`** (private) -- structural equality of two type refs, comparing idents by canonical name and recursing through the compound variants. Pure. Used for trait-conformance parameter/return checks.
- **`fn isNumericTypeName(name) bool`** (private) -- true for the canonical integer and float names (`i8`..`i128`, `f32`, `f64`). Pure.
- **`fn isTypeCompatible(from, to) bool`** (private) -- the looser compatibility predicate. `any` on either side is compatible with anything; ident-versus-generic compares canonical names; a non-optional is compatible with an optional of a compatible inner type; a non-error-union is compatible with an error union if it matches either arm; then, for equal tags, idents match by canonical name or if both are numeric, and the compound variants recurse. Pure. This is the widening-permissive core `assignable` builds on.
- **`fn optTypesAreEqual(a_opt, b_opt) bool`** (private) -- nullable wrapper over `typesAreEqual` (both null is equal, one null is not). Pure.
- **`fn substTraitType(tr, tparams, targs) ast.TypeRef`** (private) -- substitutes a single ident type parameter with its bound arg; leaves everything else unchanged (shallow, unlike `substReturnType`). Pure.
- **`fn substOptTraitType(tr, tparams, targs) ?ast.TypeRef`** (private) -- nullable wrapper over `substTraitType`. Pure. Used in the trait-conformance checks.
- **`fn isConstructorCall(expr) bool`** (private) -- whether an expression is a call whose callee looks like a constructor. Pure.
- **`fn isCalleeConstructor(callee) bool`** (private) -- heuristic: an ident starting with an uppercase letter, or named/suffixed/prefixed with `new`/`init` (plus a few explicit `new_*` primitives); or a field access with the same shape. Pure. (These two are helpers not currently wired into the main check paths but kept for constructor detection.)
- **`fn isVariableDeferred(stmt, var_name) bool`** (private) -- recursively scans a statement tree for a `defer` that deletes the named variable (a `x.delete*()` method call or a free `delete*(x)` call). Pure AST walk.
- **`fn isVariableReturned(stmt, var_name) bool`** (private) -- recursively scans for a `return` (through blocks, ifs, whiles, fors, switch cases and default) whose value references the named variable. Pure AST walk.
- **`fn exprReferencesVariable(expr, var_name) bool`** (private) -- whether an expression tree mentions the named identifier, recursing through calls, generic calls, tuples, field access, binary/unary, index, struct/enum init, cast, optional chaining, nullish coalesce, if-expr, closure (a block body defers to `isVariableReturned`), and template parts. Pure AST walk. These last three are ownership-analysis helpers (deferred delete versus returned value) available to callers.

**Algorithm and design notes.**
- Two-pass over declarations: register-then-check, so forward references resolve.
- The variable environment (`variables`) is cleared at the start of every function/method body, so it is a flat single-scope map, not a scope stack. Payload bindings from switch patterns and typed lets are put straight into it.
- Fail-open is the rule for anything unresolved; the checker only errs when it is confident. Colliding names and ambiguous functions are explicitly deferred to sema.
- Literals are treated leniently (an in-range integer literal is accepted against a narrower or numeric target) because a bare integer literal defaults to `i32` and would otherwise trip narrowing checks.

**Gotchas and footguns.**
- `canonicalizeTypeName` erases signedness; signedness checks must use the raw name. This is a real trap when adding new integer checks.
- Every error path in `addError` swallows allocation failure; the checker will not crash on OOM but may silently drop a diagnostic.
- The soundness checks (trait-to-concrete narrowing across call/method/constructor/assignment, fixed-array primitive elements, index validity, pointer truncation, narrowing/signedness) are the load-bearing correctness parts. They are narrow on purpose; widening any of them risks false positives on generics.
- `checkConst` is intentionally empty; do not expect const validation here.

**Cross-references.** Reads `ast.zig` throughout and `sema/builtins.zig` for builtin signatures. `Diagnostic` is consumed by the language server (`nls`). The authoritative typed pass this defers to lives in `src/sema/` (infer/mono/ownership/lower/symbols). The semantic `Type`/`TypeStore` in `types.zig` above is *not* used here; this pass works in syntactic `TypeRef`.

---

## `src/frontend/formatter.zig` (1031 lines)

**Role in the pipeline:** This is `nova fmt`. It takes a parsed `Program` (and the original source text, for a couple of things the AST does not carry) and re-emits canonical, indented Nova source. It is a straightforward recursive walk: one `format*` method per node kind, four-space indentation tracked by a counter, output accumulated into a growable buffer. There is no reflow or comment preservation; it renders the AST as-is in canonical form.

Two things are read from the raw source rather than the AST, because the AST does not preserve them faithfully: generic parameter strings on some declarations, and the `pub` marker on enums (via `getGenericString` and `isPubDecl`).

**Key types and data structures.**

- **`Formatter`** (pub struct) -- fields: `allocator`; `out` (an `ArrayList(u8)`, the output buffer); `indent_level` (current depth, four spaces each); `source` (the original text, for the two source-scraping helpers).

**Module-level state and constants.** `const std`, `const ast`. `const testing = std.testing` (test-only). No mutable globals.

**Functions.** In source order:

- **`init(allocator, source) Formatter`** (pub) -- constructs a formatter with an empty buffer at indent 0.
- **`deinit(self) void`** (pub) -- frees the output buffer. Note the buffer is transferred out by `formatProgram` via `toOwnedSlice`, so after a successful format the caller owns the string and `deinit` frees only whatever remains.
- **`writeIndent(self) !void`** (private) -- writes `indent_level` copies of four spaces.
- **`write(self, str) !void`** (private) -- appends a raw string to the buffer.
- **`print(self, fmt, args) !void`** (private) -- formatted append to the buffer.
- **`formatProgram(self, program) ![]const u8`** (pub) -- the entry point. Formats each declaration, inserting a blank line between declarations, and returns the buffer as an owned slice (`toOwnedSlice`, so the caller owns it thereafter).
- **`getGenericString(self, span) []const u8`** (private) -- scrapes the `<...>` generic-parameter substring out of the original source for a declaration's span, balancing angle brackets and stopping at the first `(` or `{`. Returns a slice into `source` (not owned) or empty. Used where the AST does not carry the exact generic spelling. Pure read of `source`.
- **`isPubDecl(self, span) bool`** (private) -- scans backwards from a declaration's start in the source for a preceding `pub` keyword (bounded by whitespace or `}`). Used for enums, whose AST node lacks an `is_public` field. Pure read of `source`.
- **`formatDeclaration(self, decl) anyerror!void`** (private) -- dispatches by declaration kind:
  - `import_decl`: `import a.b.c;`, translating the stored `/`-separated module path back to dotted form.
  - `const_decl`: optional `export `, then `const NAME = <value>;`.
  - `export_decl`: `export <kind> <name>;`.
  - `fn_decl`, `struct_decl`, `union_decl`, `enum_decl`, `trait_decl`: delegate to the matching `format*Decl`.
- **`formatAttributes(self, attrs) !void`** (private) -- emits `@serializable` and `@test` on their own indented lines; other attribute kinds are silently skipped (not round-tripped).
- **`formatFunctionDecl(self, fd, prefix) !void`** (private) -- formats a function or method. Emits attributes; optional `pub `; then `extern("lib") ` or `async `; then either `init(` for a constructor or `<prefix>fn NAME<T, ...>(` for a normal function (the `prefix` carries a method's `pub ` when called from a struct/enum). Renders parameters (`name: type`), the return type after `): `, and finally either `;` (extern, no body) or a space, the block, and a newline.
- **`formatStructDecl(self, sd) !void`** (private) -- attributes; optional `pub `; `struct NAME`; the `<...>` type params; an `impl A, B<...>` clause if any; then `{`, an indented block of fields (`pub? name: type,`), a blank line if both fields and methods exist, then each method (via `formatFunctionDecl` with a `pub ` prefix built into a small stack buffer), and the closing `}`.
- **`formatUnionDecl(self, ud) !void`** (private) -- optional `pub `; `union NAME {`; indented `pub? name: type,` fields; closing `}`.
- **`formatEnumDecl(self, ed) !void`** (private) -- attributes; `pub ` via `isPubDecl` (scraped from source, since `EnumDecl` has no `is_public`); `enum NAME {`; each variant rendered as one of: `NAME = value`, a struct-form payload block (`NAME { field: type, ... }`), or a tuple-form `NAME(type)`; a blank line before methods; then the methods; closing `}`.
- **`formatTraitDecl(self, td) !void`** (private) -- optional `pub `; `trait NAME<...>`; then each method signature (`async? fn name(params): ret;`) with no body; closing `}`.
- **`formatBlock(self, block) !void`** (private) -- `{`, newline, indented statements, dedent, indent, `}` (no trailing newline; callers add one where needed).
- **`formatStatement(self, stmt) anyerror!void`** (private) -- the statement renderer, each written with indentation and a trailing newline:
  - `block`: indented nested block.
  - `let_stmt`: `const `/`let `, then either a single name or a `(a, b)` destructure list, an optional `: type`, an optional ` = init`, and `;`.
  - `expr_stmt`: the expression then `;`.
  - `defer_stmt`: `defer <expr>;`.
  - `if_stmt`: delegates to `formatIfStmtNoIndent` (after writing the leading indent).
  - `while_stmt`: `while (cond) ` then the body (a block directly, or a single statement wrapped in a synthesised `{ ... }`).
  - `for_stmt`: `for (` then either the for-in form (`item in iterable` or `(key, value) in iterable`) or the C-style `init; cond; incr` form (each part optional), `) `, then the body (block or wrapped).
  - `switch_stmt`: `switch (disc) {`, each `case v, ...: <body>` and an optional `default: <body>` (bodies are blocks or wrapped), closing `}`.
  - `return_stmt`: `return` with an optional value, `;`.
  - `break_stmt`/`continue_stmt`: `break;`/`continue;`.
- **`formatIfStmtNoIndent(self, i) anyerror!void`** (private) -- renders `if (cond) <then>` where the then-branch is a block or an inline single statement, and chains `else`/`else if` (an else-if recurses into this same method so the chain stays flat). No leading indent (the caller writes it), so it can be reused for else-if.
- **`formatStatementNoIndentNoNewline(self, stmt) anyerror!void`** (private) -- renders a statement inline (no leading indent, no trailing newline) for use inside `if`/for bodies. Handles let/expr/break/continue/return directly; for any other kind it falls back to `formatStatement` and then pops a trailing newline if one was written. (Note the destructure branch here writes a stray space before `(`, a minor cosmetic quirk.)
- **`opPrecedence(op) i32`** (private, static) -- the binary-operator precedence table (assign lowest at 1, up to mul/div/mod at 9). Drives parenthesisation.
- **`binOpToStr(op) []const u8`** (private, static) -- the source spelling of each `BinaryOp` (`add` to `+`, `And` to `&&`, `bit_and` to `&`, `shl` to `<<`, and so on). Pure. Pinned by the two tests at the end (that `&`/`|` print as operators not the dead and/or keywords, and that every operator spelling is non-alphabetic so it round-trips through the lexer).
- **`formatBinaryChild(self, child, parent_op, is_right) !void`** (private) -- renders a binary operand, wrapping it in parentheses when precedence requires: a child binary of strictly lower precedence, or of equal precedence on the right side (to preserve left-associativity). Otherwise renders it bare.
- **`formatExpression(self, expr) anyerror!void`** (private) -- the expression renderer, one arm per `ExprKind`:
  - `range`: `start..end` or `start..=end`.
  - `await_expr`/`go_expr`: `await ` / `go ` then the operand.
  - `literal`: integers as digits; floats via `bufPrint` with a forced `.0` when there is no `.` or `e`; decimals with a trailing `m`; strings quoted; `true`/`false`; `null`; `undefined`; arrays `[a, b]`; array-repeat `[value; count]`; object literals `{name: value, ...}`.
  - `ident`: the name.
  - `binary`: left child, ` op `, right child (both through `formatBinaryChild` for parenthesisation).
  - `unary`: the operator symbol (`-`/`!`/`~`), then the operand, parenthesising a binary operand.
  - `call`: `callee(args)`.
  - `generic_call`: `callee<type_args>(args)`.
  - `field_access`: `object.field`.
  - `index`: `object[index]`.
  - `struct_init`: `Name {field: value, ...}`.
  - `enum_init`: `Enum.Variant` plus an optional `{field: value, ...}` payload.
  - `cast`: `expr as type`.
  - `optional_chaining`: `object?.field`.
  - `nullish_coalesce`: `left ?? right`.
  - `jsx_element`: `<tag attr="..." attr={expr}>` with children (nested elements recurse, expressions and statements wrap in `{}`, text is raw) and a self-closing `/>` when there are no children.
  - `closure`: `(params) => ` then an expression body or a block.
  - `tuple`: `(a, b, ...)`.
  - `if_expr`: `if (cond) then else else`.
  - `try_expr`: `try <expr>`.
  - `catch_expr`: `<expr> catch (name)? <handler>`.
  - `block_expr`: a block.
  - `template_expr`: a backtick template, emitting string parts raw and every other part as `${...}` interpolation.
- **`formatTypeRef(self, tr) anyerror!void`** (private) -- the type renderer: `ident` as its name; `error_union` as `ok | err`; `optional` as `sub | undefined`; `fixed_array` as `element[length]`; `generic` as `name<params>`; `func` as `(params) -> ret`; `tuple` as `(a, b, ...)`.
- Two `test` blocks at the end pin `binOpToStr` (operators print as symbols, and every operator spelling is non-alphabetic so it lexes back as an operator).

**Algorithm and design notes.**
- Output is a single growing buffer; `formatProgram` hands ownership to the caller via `toOwnedSlice`. Everything else appends.
- Precedence-aware parenthesisation is the only non-trivial logic: `formatBinaryChild` plus `opPrecedence` reconstruct the minimum parentheses that preserve the parse.
- Single-statement `if`/`while`/`for`/`case` bodies are always promoted to braced blocks in the output, so the formatter canonicalises brace style.
- `formatFunctionDecl` special-cases `init` (renders it as `init(...)` rather than `fn init`) and threads a method's `pub ` through the `prefix` parameter.

**Gotchas and footguns.**
- Comments are not preserved; the formatter renders the AST, which does not carry them.
- `formatAttributes` only round-trips `@serializable` and `@test`; other attributes (route, summary, response, deprecated, and the rest) are dropped on format.
- Enum `pub` is scraped from the source via `isPubDecl` because `EnumDecl` has no `is_public` field; if the span or source is off, the marker can be lost. Similarly `getGenericString` reads generics from source.
- `formatStatementNoIndentNoNewline` writes a stray leading space before a destructure `(` in the inline path, a cosmetic inconsistency with the main `formatStatement` path.
- The `struct`/`enum` method-prefix uses a fixed 32-byte stack buffer for the `pub ` prefix; it only ever writes four bytes, so this is safe, but it is a fixed buffer to be aware of.

**Cross-references.** Reads `ast.zig` exclusively. Invoked by the `nova fmt` CLI path (`src/frontend/*` is driven from the pipeline/format entry in the CLI split). It does not use `types.zig` or the type checker; formatting runs on the parsed AST alone.
