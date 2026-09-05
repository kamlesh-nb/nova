# Sema internals: shadow, symbols, ownership, mono, lower, subst

This reference documents six files under `src/frontend/sema/` that together form the spine of Kyte's typed-IR pass. A new maintainer should read this before touching the type engine, monomorphisation, or the ARC ownership analysis.

The pieces fit together like this. `symbols.zig` builds the symbol table: one flat list of `Symbol` records (functions, methods, structs, enums, traits, constants) keyed by a `SymbolId`, plus a list of `Module` records keyed by a `ModuleId`, plus the import edges. `lower.zig` takes a syntactic `ast.TypeRef` and lowers it to an interned `TypeId` in the type store, resolving named types through the symbol table and generic type-parameters through a stack of `ParamScope`s. `subst.zig` replaces type-parameters inside a `TypeId` with concrete arguments (this is how `List<T>.get() -> T` becomes `List<int>.get() -> int`), and also solves for unknown parameters by unifying a declared shape against an actual one. `mono.zig` walks every typed expression and collects the distinct concrete generic instantiations (`List<int>`, `Map<string, int>`, and so on) that codegen must emit a monomorphised body for, deduping through a `seen` set and guarding against unbounded nesting. `ownership.zig` is the ARC balance check: it decides which owned local values and owned temporaries exist, and records the `move` or `drop` op that keeps each one consumed exactly once, feeding retain/release insertion in codegen. `shadow.zig` is the umbrella diff harness gated by `KYTE_SEMA_SHADOW`: it drives the whole typed pipeline in parallel with the legacy string-based engine, reports every divergence, and, importantly, raises the real user-facing type-checking errors (visibility, const reassignment, optional deref, and the ownership balance gate) by calling `std.process.exit(1)`.

A note on the "shadow" name: much of this subsystem was built as a shadow of an older string-name-based type engine, so that the two could be run side by side and compared before the string engine was retired. Many of the counters and reports in `shadow.zig` exist only to prove the typed engine agrees with the legacy one. The typed path is now authoritative, but the shadow scaffolding remains and still gates the build (an unexplained ownership divergence, or a balance violation, fails the build).

---

## `src/frontend/sema/symbols.zig` (772 lines)

**Role in the pipeline:** This is the first thing `shadow.run` builds. It flattens an `ast.Program` into a global symbol table: every top-level declaration and every method becomes a `Symbol`, every source file becomes a `Module`, and every `import` becomes an `Import` edge. Everything downstream (lowering named types, resolving calls, module-scoping colliding types, mangling names for codegen) queries this table by `SymbolId` or `ModuleId`.

The table also owns the name-mangling logic. It keeps three names per function: the bare `name`, the `legacy_mangled` name (which reproduces the old, path-dependent `$HOME` mangling bug on purpose, so the shadow can prove a fix is safe), and the `canonical_mangled` name (the path-independent fix). Same-named structs and enums across modules get a `scoped_name` so codegen can keep them distinct.

**Key types and data structures:**

- **`SymbolId = enum(u32) { _ }`** and **`ModuleId = enum(u32) { _ }`**: opaque indices. A `SymbolId` is literally the position of a `Symbol` in `SymbolTable.symbols`; a `ModuleId` is the position in `SymbolTable.modules`. Conversion is via `@intFromEnum` / `@enumFromInt` throughout.
- **`SymbolKind = enum { function, method, struct_, enum_, union_, trait_, constant }`**: what a symbol is. Note `union_` is declared but `build` never produces one (there is no `.union_decl` arm); it exists for the `isTypeSym` predicate and future use.
- **`Visibility = enum { public, private }`**: derived from `is_exported` (functions) or `is_public` (structs). Methods, enums, traits, constants are all recorded `public`.
- **`Symbol = struct`**: the record. Fields: `name` (bare), `module` (its `ModuleId`), `kind`, `visibility`, `owner` (the owning type name for a method, else null), `span`, `legacy_mangled`, `canonical_mangled`, `decl` (a `Decl` pointer back into the AST, default `.none`), and `scoped_name` (default null, set only for colliding structs/enums). Invariant: `legacy_mangled`, `canonical_mangled`, and `scoped_name` are either borrowed slices from the AST (bare names) or owned by the table's `owned` list.
- **`Decl = union(enum)`**: a back-pointer into the AST: `none`, `function: *const ast.FunctionDecl`, `struct_: *const ast.StructDecl`, `enum_: *const ast.EnumDecl`, `trait_: *const ast.TraitDecl`, `constant: *const ast.ConstDecl`. Invariant (proven by the last unit test): these point INTO the program's AST, not at dead stack copies, so codegen can follow them. `build` takes `&decl_ptr.fn_decl` from a `for (…) |*decl_ptr|` loop precisely so the pointer is stable.
- **`Module = struct { id: ModuleId, path: []const u8, file: []const u8 }`**: `path` is the canonical dotted module path (e.g. `std.collections.list`), or the literal `"<root>"` for the root program file. `file` is the raw source path.
- **`Import = struct { importer: ModuleId, imported: ModuleId, segment: []const u8 }`**: one import edge. `segment` is the last path segment the module is used under (e.g. `list` from `std.collections.list`).
- **`SymbolTable = struct`**: the container. Fields: `allocator`, `symbols` (the flat list), `modules`, `imports`, `owned` (every heap string the table allocated, freed on `deinit`), `root_file` (set at the start of `build`), and `colliding_types` (a set of type names that are declared in more than one module and therefore need scoping).

**Module-level state / constants:** none beyond the types. `isAlreadyNamespaced` reads a hard-coded allowlist of stdlib prefixes.

**Free functions (before the struct):**

- **`canonicalModulePath(allocator, file, root_file) -> !?[]const u8`** (pub): computes the dotted module path for a file. Returns null for the root file, `helpers.ky`, `test_harness.ky`, and empty. Strips a `src/std/` or `src/lib/` prefix (or a `.kyte/std/` prefix for installed stdlib), drops the extension, prefixes `std.` when a std/lib root was stripped, and turns `/` and `\` into `.`. Allocates the result (owned by caller). This is the path-independent scheme: an absolute checkout path and a `src/std/` path yield the same result.
- **`canonicalModulePrefix(allocator, file, root_file) -> !?[]const u8`** (pub): like the above but for mangling prefixes: strips `src/std/`, `src/lib/`, `.kyte/std/`, `.kyte/lib/`, drops the extension, and replaces separators with `_` (no `std.` prefix). Allocates. Used to build `canonical_mangled` function names. Unit-tested to be `$HOME`-independent.
- **`legacyModulePrefix(allocator, file, root_file) -> !?[]const u8`** (pub): reproduces the OLD prefix behaviour on purpose, including the `$HOME` bug. It only strips a literal leading `src/std/` or `src/lib/`, so an installed path under `/Users/...//.kyte/std/` keeps the absolute path in the prefix. Used to build `legacy_mangled`. The divergence between this and `canonicalModulePrefix` is exactly what the shadow's `[PATH-DEP]` and `[NEW-COLLISION]` reports measure.

**`SymbolTable` methods (source order):**

- **`init(allocator) -> SymbolTable`** (pub): trivial, sets the allocator.
- **`deinit(self)`** (pub): frees every string in `owned`, then deinits all four lists and the `colliding_types` set.
- **`scopedNameFor(self, name, file) -> ?[]const u8`** (pub): for a colliding type name, returns the `scoped_name` of the declaration in `file`. Returns null if the name does not collide. Codegen uses this to pick the module-scoped identity.
- **`computeScopedName(self, name, file) -> !?[]const u8`** (private): builds `"<legacyprefix>_<name>"`, or `"root_<name>"` when the file has no prefix. Allocates via `own` (table-owned).
- **`computeCollidingTypes(self) -> !void`** (private): the second pass of `build`. Detects same-name, same-kind (`struct_` or `enum_` only) declarations in different modules, marks them in `colliding_types`, then fills in each colliding symbol's `scoped_name`. Traits and unions are deliberately not scoped yet (a documented follow-on: scoping traits broke the struct-to-trait return-widening check).
- **`sepAgnosticEql(a, b) -> bool`** (private): compares two paths treating `/` and `.` as equal. Used in import-name matching.
- **`lastSegment(name) -> []const u8`** (private): the substring after the last `.` or `/`.
- **`dirOf(path) -> []const u8`** (private): the directory portion (before the last `/` or `\`), or empty.
- **`fileBaseNoExt(path) -> []const u8`** (private): the file basename with directory and extension stripped.
- **`findModuleByImportNameForImporter(self, import_name, importer_file) -> ?ModuleId`** (pub): importer-relative module resolution. If the importing file has a sibling module (same directory) whose basename matches the import's last segment, prefer it. This is what lets two packages each with an internal `connection.ky` resolve to their own module instead of both binding to whichever `connection` was registered first. Falls back to `findModuleByImportName`.
- **`findModuleByImportName(self, import_name) -> ?ModuleId`** (pub): global name-based module lookup. First tries a full path match (separator-agnostic, with the `std.` prefix optionally stripped), then falls back to a last-segment match. Skips the `<root>` module.
- **`findModuleByFile(self, file) -> ?ModuleId`** (pub): exact file-path match.
- **`resolveImportedModule(self, importer, segment) -> ?ModuleId`** (pub): looks up the import edge `(importer, segment)` and returns the imported module.
- **`own(self, s) -> ![]const u8`** (private): appends a heap string to `owned` and returns it. This is the table's ownership sink; everything it allocates must go through here so `deinit` frees it.
- **`internModule(self, file) -> !ModuleId`** (private): finds or creates the module for a file. On creation it computes the canonical path (or `"<root>"`) and appends a `Module`.
- **`moduleOf(self, id) -> Module`** (pub): index into `modules`.
- **`findType(self, name) -> ?SymbolId`** (pub): first struct/enum/trait/union with a matching name, module-blind. First match wins.
- **`isTypeSym(k) -> bool`** (private): true for `struct_`, `enum_`, `trait_`, `union_`.
- **`findTypeInModule(self, name, ctx) -> ?SymbolId`** (pub): scoped type resolution, three tiers: (1) a type declared in `ctx` itself shadows any import; (2) a type in a module `ctx` directly imports; (3) module-blind `findType` as a last resort. For a unique name every tier returns the same symbol; the tiers only matter for cross-module collisions. This is the resolver `lower.zig` uses.
- **`findTypeViaImports(self, name, cm) -> ?SymbolId`** (private): among the modules `cm` imports, find the one declaring `name`. Returns null if two DISTINCT imported modules declare it (ambiguous, so it falls through to the module-blind resort rather than guessing).
- **`findTypeAmbiguous(self, name) -> bool`** (pub): true if more than one type symbol shares the name.
- **`findFunction(self, name) -> ?SymbolId`** (pub): first function symbol with a matching bare name.
- **`findFunctionAmbiguous(self, name) -> bool`** (pub): true if more than one function shares the name.
- **`findMethod(self, type_name, method) -> ?SymbolId`** (pub): first method whose `owner` equals `type_name` and whose `name` equals `method`, module-blind.
- **`findMethodInModule(self, type_name, method, owner_module) -> ?SymbolId`** (pub): like `findMethod` but prefers the method declared in `owner_module` (the receiver struct's module) when the owner type name collides. Falls back to `findMethod` so trait defaults and non-colliding owners are unchanged.
- **`findModuleBySegment(self, name) -> ?ModuleId`** (pub): the module whose path's last segment equals `name` (the name a module is used under, e.g. `string`). Skips `<root>`.
- **`findFunctionBySegment(self, segment, name) -> ?SymbolId`** (pub): find function `name` in the (unique) module used under `segment`. Returns null if two modules share the segment and both have the function (ambiguous).
- **`segmentIsAmbiguous(self, segment) -> bool`** (pub): true if more than one module is used under `segment`.
- **`findFunctionIn(self, mod, name) -> ?SymbolId`** (pub): function `name` restricted to module `mod`.
- **`symbolAt(self, id) -> Symbol`** (pub): index into `symbols`. Returns a copy of the record.
- **`addSymbol(self, sym) -> !void`** (private): append.
- **`build(self, program) -> !void`** (pub): the main entry. Sets `root_file`. First pass walks declarations: for `fn_decl` it interns the module, computes `legacy_mangled` and `canonical_mangled`, and adds a `function` symbol with a stable `Decl` pointer; for `struct_decl` it adds the struct then a `method` symbol per method (method `legacy_mangled` is `"<Struct>_<method>"`, canonical is the same); `enum_decl` mirrors structs; `trait_decl` and `const_decl` add single symbols. Second pass walks `import_decl`s (skipping `bytes`), resolves the imported module importer-relative, and records an `Import` edge with the last segment. Finally calls `computeCollidingTypes`. Footgun: it iterates `|*decl_ptr|` and stores `&decl_ptr.fn_decl` etc., so the AST must outlive the table.
- **`canonicalNameForFn(self, f) -> ![]const u8`** (private): `"<canonicalprefix>_<name>"`, unless the name is already namespaced (`isAlreadyNamespaced`) or the file has no prefix (returns the bare name).
- **`legacyNameForFn(self, f) -> ![]const u8`** (private): same but using `legacyModulePrefix` (reproduces the old mangling).

**Free function after the struct:**

- **`isAlreadyNamespaced(name) -> bool`** (pub): true if the name starts with one of a hard-coded list of stdlib module prefixes (`string`, `json`, `http`, `list`, `map`, `set`, `net_tcp`, and so on) FOLLOWED by `_`. Guards against double-prefixing already-mangled stdlib names. Unit-tested that `string_concat` matches but `stringify` and `string` do not.

**Tests:** eight `test` blocks covering prefix canonicalisation and the deliberate legacy bug, `isAlreadyNamespaced`, `findModuleBySegment` / `findFunctionIn`, and the "method decl points into the AST" invariant.

**Cross-references:** `../ast.zig` (all the decl and `Span` types), `types.zig` (this file does not import it but its `SymbolId` is the same `enum(u32)` re-exported as `types.SymbolId`), `lower.zig` (consumer of `findTypeInModule`), `shadow.zig` (calls `build` and reads every field for its reports), codegen (consumes `legacy_mangled` / `canonical_mangled` / `scoped_name`).

---

## `src/frontend/sema/lower.zig` (510 lines)

**Role in the pipeline:** Lowering turns a syntactic type annotation (`ast.TypeRef`, what the parser produced) into a semantic `TypeId` interned in the `TypeStore`. It is the join point between the symbol table and the type store: a named type (`Stats`, `List`) is resolved through the symbol table to a `SymbolId` and then interned as a `.struct_` / `.enum_` / `.trait_`; a generic type-parameter (`T`, `K`) is resolved by POSITION through the `param_scopes` stack; primitives, optionals, functions, tuples, fixed arrays, `Storage<...>`, `future<...>`, and error-unions are lowered structurally.

An unknown name lowers to `.unresolved` (never silently to `int`), and every unresolved name is counted and remembered in `Stats` so the shadow can report the coverage debt honestly.

**Key types and data structures:**

- **`TypeId = types.TypeId`** (pub re-export).
- **`Stats = struct { lowered, unresolved: usize, unresolved_names: ArrayListUnmanaged([]const u8) }`**: the honest F2 signal. `lowered` counts every `TypeRef` that produced a real type; `unresolved` counts the failures; `unresolved_names` keeps the names behind them. Has its own `deinit(allocator)`.
- **`ParamScope = struct { owner: SymbolId, names: []const []const u8 }`**: one lexical scope of generic parameters. `owner` is the declaring symbol (the struct or the function/method), `names` are the parameter names in declaration order. A method sees a STACK of two scopes: the struct's params then its own.
- **`Lowerer = struct`**: the lowering context. Fields: `allocator`, `store` (the type store), `param_scopes` (the scope stack, default empty), `symtab` (optional symbol table; without it named types cannot resolve), `current_module` (optional `ModuleId`, threaded into `findTypeInModule` so a local type shadows an import), and `stats`.

**Module-level state / constants:** none.

**`Lowerer` methods (source order):**

- **`init(allocator, store) -> Lowerer`** (pub): trivial.
- **`deinit(self)`** (pub): deinits `stats`.
- **`unresolved(self, name) -> !TypeId`** (private): bumps `stats.unresolved`, records the name, and returns `store.unresolvedT()`. The single sink for lowering failures.
- **`prim(self, name) -> !?TypeId`** (private): matches `name` against a hard-coded table of primitive spellings and interns the matching `.prim` with the correct width and signedness. This table is where Kyte's aliases live: `int`/`i32` are both 32-bit signed, `long`/`i64` 64-bit signed, `byte`/`ubyte`/`u8` 8-bit unsigned, `float`/`f32`, `double`/`f64`, `void`, and so on. Returns null (not unresolved) for a non-primitive name so callers can keep trying.
- **`typeParamRef(self, name) -> ?types.TypeParam`** (private): searches `param_scopes` from the TOP DOWN (innermost first), so an inner scope shadows an outer scope of the same name. Returns `{ owner, index }` for the first match. This is the core of "type params resolve by position, not by being an uppercase letter".
- **`lower(self, tr) -> anyerror!TypeId`** (pub): the recursive workhorse, one arm per `TypeRef` kind:
  - `.error_union` -> lower both sides, intern `.error_union`.
  - `.ident` -> try `prim`; then the built-ins `string`, `decimal`, `ptr`; then `typeParamRef` (a param wins over a same-named type); then `symtab.findTypeInModule` (interning `.enum_`, `.trait_`, or `.struct_` with no args by kind); then the `any` built-in; else `unresolved`.
  - `.optional` -> lower inner, intern `.optional`.
  - `.func` -> lower each param and the return, intern `.func`. Allocates a temporary param slice (freed via `defer`).
  - `.tuple` -> lower each element, intern `.tuple`.
  - `.fixed_array` -> lower element, intern `.array` with the length.
  - `.generic` -> lower each arg; special-case `Storage<T>` and `future<T>` (arity 1) to their dedicated store kinds; else resolve the base name via `findType` and intern `.struct_` WITH args (or `.trait_` / `.enum_` by kind); else `unresolved`. Note this uses `findType` (module-blind), not `findTypeInModule`, so a generic base name is resolved without module context.

Every successful arm bumps `stats.lowered`.

**Gotchas / invariants:**
- Order in the `.ident` arm matters: a type-parameter shadows a same-named declared type, which is why `typeParamRef` is checked before `findTypeInModule`.
- Without `symtab` set, no named type resolves (only primitives and built-ins). `shadow.zig` and `mono.zig` always set `l.symtab` before lowering.
- `.generic` uses `findType`, not the module-scoped resolver, an asymmetry with the `.ident` arm worth remembering.
- The param and element slices passed to `store.intern` are freed after interning (the store copies what it keeps).

**Tests:** fifteen `test` blocks: primitive widths/aliases, string-vs-ptr distinctness and ownership, unknown-to-unresolved (never int), positional type-params, structural function/optional/tuple/array types, the honest stats signal, named-type resolution through a real symbol table, `List<string> != List<int>`, method-sees-both-scopes, two-generics-different-params, no-scope-T-is-not-a-param, method-U-belongs-to-method, and inner-scope-shadows-outer.

**Cross-references:** `../types.zig` (`TypeStore`, `TypeId`, `TypeParam`, `PrimKind`, all the `intern` shapes), `symbols.zig` (`SymbolTable.findTypeInModule` / `findType`, `SymbolId`, `ModuleId`), `mono.zig` and `shadow.zig` (drive the lowerer), `subst.zig` (substitutes into the `TypeId`s this produces).

---

## `src/frontend/sema/subst.zig` (348 lines)

**Role in the pipeline:** Type-parameter substitution. Given a `TypeId` that mentions a declaration's type-parameters (e.g. the lowered return type `T` of `List<T>.get`, or `Map<T, bool>` as a field type), and a list of concrete arguments, produce the `TypeId` with those parameters replaced. This is how a generic method signature becomes concrete for a specific instantiation, and it is what `mono.zig` calls to follow generic field and return types into further instantiations.

The file also carries the inverse direction: `solveParams` unifies a declared shape against an actual one to infer unknown parameters (used to solve a closure's return type in `map((x) => x * 2)`), and `substituteOne` replaces a single parameter by owner-plus-index.

**Key types and data structures:**

- **`TypeId = types.TypeId`** (pub re-export). No structs of its own; it is a set of pure functions over the store.

**Module-level state / constants:** none (the `List` / `Map` consts near the bottom are test fixtures only).

**Functions (source order):**

- **`substitute(store, t, owner, args) -> anyerror!TypeId`** (pub): recursively rewrite `t`, replacing any `.type_param` whose `owner` matches and whose `index` is in range with `args[index]`. Fast path: if `args.len == 0`, return `t` unchanged. Structural cases (`.error_union`, `.struct_`, `.optional`, `.future`, `.storage`, `.array`, `.func`, `.tuple`) recurse into children and only re-intern when something CHANGED (the `changed` flag / pointer-equality check), so an unaffected type keeps its identity and no needless interning happens. Leaf and non-parametric cases (`.prim`, `.string`, `.decimal`, `.ptr`, `.any_`, `.enum_`, `.trait_`, `.unresolved`) return `t`. Allocates temporary child slices for struct/func/tuple (freed via `defer`); the store owns anything it interns. Footgun handled deliberately: a `.type_param` whose owner does not match, or whose index is out of range, is LEFT ALONE rather than panicking (an out-of-range index is left for the type checker to diagnose).
- **`solveParams(store, declared, actual, owner, solved) -> void`** (pub): unification for inference. If `declared` is a `.type_param` we own and `solved[index]` is still null, bind it to `actual` (but only if `actual` is not `.unresolved`, so nothing is invented from a guess). Otherwise, if the two top-level tags differ, solve nothing (a shape mismatch is not forced). Matching shapes recurse element-wise: `.func` (params and return, arity-checked), `.struct_` (same decl and arg count), `.optional` / `.future` / `.storage` (inner), `.array` (elem), `.tuple` (arity-checked). `solved` is a caller-provided `[]?TypeId` slice, one slot per parameter index, mutated in place. Only OUR `owner`'s params are ever written; a foreign param is left null.
- **`substituteOne(store, t, owner, index, with) -> anyerror!TypeId`** (pub): like `substitute` but replaces exactly ONE parameter (matched by `owner` AND `index`) with `with`. Same change-tracking discipline. Covers `.type_param`, `.struct_`, `.optional`, `.future`, `.storage`, `.func`; everything else returns `t`. Used to solve one method type-parameter (`U`) without disturbing the others (`V`).

**Gotchas / invariants:**
- Substitution is by `(owner, index)`, never by name, which is why another declaration's parameter is never captured (there is a test named exactly that).
- Re-interning only on change is not just an optimisation: it preserves `TypeId` identity so downstream pointer-equality comparisons (the mono `seen` set, dedup keys) stay correct.
- `substitute` handles the full type grammar including `.error_union` and `.tuple`; `substituteOne` deliberately handles a smaller set (no `error_union`, `array`, or `tuple`), sufficient for its single-param method-solve use.

**Tests:** thirteen `test` blocks across the three functions: basic replacement, no-capture, by-index, nested instantiation, unchanged-return, empty-args, out-of-range, function types (substitute); return-inference, own-params-only, no-invention-from-unresolved, nested unify, shape-mismatch (solveParams); and one-param-without-disturbing-the-other (substituteOne).

**Cross-references:** `../types.zig` (`TypeStore`, `TypeId`, `SymbolId`, `TypeParam`, the intern shapes), `mono.zig` (calls `substitute` on generic field and return types), `infer.zig` (calls `solveParams` / `substituteOne` during method-type inference), `lower.zig` (produces the parametric `TypeId`s that get substituted).

---

## `src/frontend/sema/mono.zig` (513 lines)

**Role in the pipeline:** Monomorphisation planning. Kyte instantiates generics rather than erasing them (`List<int>` becomes a distinct `List_int_*` body), and mono is mandatory. This file walks every typed expression's `TypeId` and collects the distinct CONCRETE generic instantiations that need a monomorphised body, following the graph transitively: a noted instantiation pulls in its own generic argument types, its methods' concrete return types, and its generic field types. The result is a `seen` set of `TypeId`s and a list of rendered names that codegen turns into bodies.

Alongside the struct-instantiation worklist, the file keeps three module-level worklists for method-level and free-function generics discovered during inference and codegen's transitive closure: `method_insts`, `free_fn_insts`, and `base_needed`.

**Key types and data structures:**

- **`TypeId = types.TypeId`** (pub) and **`max_depth: u32 = 16`** (pub): the recursion bound for nested instantiations.
- **`Stats = struct { instantiations, todays_bodies, projected_bodies, too_deep: usize }`**: shadow accounting: distinct instantiations found, erased bodies today, bodies if monomorphised, and instantiations refused for exceeding `max_depth`.
- **`MethodInst = struct`**: a method-level generic instantiation (e.g. `List<i32>.map<string>`). Fields: `inst_name` (rendered receiver, e.g. `List<i32>`), `method`, `params` (the method's type-param names), `args` (rendered concrete args), and the TypeId overlay added for string-engine removal: `recv` (receiver `TypeId`), `method_owner` (the method's `SymbolId`, owner of `<U>`), `args_tids` (concrete arg `TypeId`s), and `inst_key` (a COMBINED interned key `.struct_{method_owner, [recv] ++ args}` that distinguishes `List<i32>.map<string>` from `List<i32>.map<int>`).
- **`FreeFnInst = struct`**: a free generic function instantiation. Fields: `fn_name`, `params`, `args` (rendered), plus the overlay `owner` (the fn's `SymbolId`), `args_tids`, and `inst_key` = `.struct_{decl=owner, args=args_tids}`. The overlay fields are null for instances discovered by the legacy string-only transitive path until it is upgraded.
- **`Worklist = struct`**: the struct-instantiation collector. Fields: `allocator`, `sema` (the `Sema`, giving `store` + `tab` + `ir`), `seen` (an `AutoHashMapUnmanaged(TypeId, void)` that is both the dedup memo and the result set), and `stats`.

**Module-level state / constants:**

- **`live_instantiations: ?[]const []const u8`** (pub): the rendered instantiation names, published for other passes.
- **`live_inst_ids: StringHashMapUnmanaged(TypeId)`** (pub): rendered-name to `TypeId`, filled by `names`.
- **`method_insts: ArrayListUnmanaged(MethodInst)`** (pub): the method-instantiation worklist.
- **`base_needed: StringHashMapUnmanaged(void)`** (pub): keys `"<owner>|<method>"` marking that an erased base body is still needed.
- **`free_fn_insts: ArrayListUnmanaged(FreeFnInst)`** (pub): the free-function worklist.
- **`mono_enabled: bool = true`** (pub): a constant flag; mono is always on.

All of these live in the page allocator and persist for the process; they are appended to across passes and never freed (compiler-lifetime state).

**Free functions (source order):**

- **`noteBaseNeeded(store, recv_tid, method) -> void`** (pub): renders the receiver, builds `"<rendered>|<method>"`, and marks it in `base_needed`. Page-allocated.
- **`baseIsNeeded(owner, method) -> bool`** (pub): checks the `base_needed` set with a stack buffer key. Returns true on formatting failure (fail-safe: keep the base).
- **`dumpMethodInsts() -> void`** (pub): if `KYTE_SEMA_SHADOW` is set, prints the method-inst worklist.
- **`noteMethodInst(store, recv_tid, method_owner, method, params, args) -> bool-less void`** (pub): records a method instantiation. Renders the receiver and each arg, DEDUPS on `(inst_name, method, rendered args)`, and on a new entry dupes the param names, keeps the arg `TypeId`s, and interns the combined `inst_key = .struct_{method_owner, [recv] ++ args}`. All strings/slices page-allocated.
- **`noteFreeFnInst(store, fn_name, owner, params, args) -> bool`** (pub): records a free-fn instantiation from concrete `TypeId` args. Dedups on `(fn_name, rendered args)`. Key subtlety: if a string-only entry already exists (from the transitive path), it UPGRADES it in place with the `owner` / `args_tids` / `inst_key` and returns true; a fully-duplicate returns false; a fresh entry returns true. The bool lets a caller run a fixpoint until nothing new appears.
- **`noteFreeFnInstStr(fn_name, params, args) -> bool`** (pub): records a free-fn instantiation from already-rendered STRINGS (codegen's transitive closure produces these when a generic forwards an enclosing type-param to another generic). Dedups on `(name, args)`, returns true if newly added. No `TypeId` overlay (the string-only path).

**`Worklist` methods:**

- **`init(allocator, sema) -> Worklist`** and **`deinit(self)`** (pub): trivial; `deinit` frees `seen`.
- **`depthOf(self, t, fuel) -> u32`** (private): the nesting depth of a type, with a `fuel` guard so a cyclic store cannot hang it (fuel exhaustion returns `max_depth + 1`, i.e. "too deep"). Recurses through `.struct_` args (max child depth + 1), `.optional`, `.future`, `.array`; everything else is depth 0.
- **`isConcrete(self, t) -> bool`** (private): true if `t` has no `.type_param` or `.unresolved` anywhere. Recurses through struct args, optional/future/array inner, function params+return, and tuple elements. This is the gate: only fully-concrete types are real instantiations.
- **`note(self, t) -> !void`** (pub): the core. Ignores non-structs and zero-arg structs. Ignores non-concrete types (so `List<T>` is never an instantiation, only `List<int>`). Ignores already-seen types (the memo). Refuses (and counts `too_deep`) types deeper than `max_depth`. Otherwise records `t` in `seen`, bumps `instantiations`, and recurses: first into each generic ARG, then, if the decl is a struct, into each METHOD's substituted concrete return type and each FIELD's substituted concrete type. The method/field recursion is why `Set<T> { map: Map<T, bool> }` correctly monomorphises `Map<int, bool>` for `Set<int>` (a documented crash if missed: the erased container has the wrong value-optional representation). Each recursion lowers the raw AST type through a fresh `Lowerer` (scoped to the decl's params) and then `subst.substitute`s the instantiation's args in.
- **`compute(self, program) -> !void`** (pub): seeds the worklist from every `TypeId` in `sema.ir.expr_types`, then accounts `todays_bodies` (sum of struct method counts across all declarations) and `projected_bodies` (sum of method counts across the `seen` instantiations) for the growth report.
- **`names(self, allocator) -> ![]const []const u8`** (pub): renders each `seen` `TypeId` to its legacy name, also populating `live_inst_ids`. Caller owns the returned slice.
- **`instIds(self, allocator) -> ![]TypeId`** (pub): the `seen` set as a flat `TypeId` slice. Caller owns it.
- **`report(self) -> void`** (pub): the F4 shadow report: distinct instantiations, erased vs monomorphised body counts, growth ratio, refused count, and a sample of up to 12 instantiations with their args and method counts.

**Algorithm notes on instantiation keys and dedup:**
- The struct worklist dedups by `TypeId` identity (the `seen` `AutoHashMap`), which is sound because the store interns structurally: `List<int>` is always the same `TypeId`.
- The method and free-fn worklists dedup by rendered-name tuples (`inst_name`/`fn_name` plus rendered args), because they are collected incrementally from string-producing paths as well as TypeId paths; the interned `inst_key` is the bridge that lets the overlay be recorded once a TypeId-native discovery arrives.
- `noteFreeFnInst`'s in-place upgrade is the mechanism that unifies the two discovery routes (string transitive closure vs typed inference) without producing duplicate bodies.

**Gotchas / invariants:**
- `note` is a no-op for anything that is not a concrete, non-trivially-generic struct, so callers can spray every expression type at it safely.
- The depth guard is doubled up: `isConcrete` has no guard (relies on the store being acyclic for concrete types), but `note` calls `depthOf(t, max_depth + 2)` and `depthOf` itself carries fuel, so a pathological store cannot hang.
- The module-level worklists are never cleared; they accumulate for the whole compile.

**Tests:** nine `test` blocks: two-instantiations, dedup memo, non-generic-is-not-an-instantiation, nested args, the recursion guard (refused, not hung), a legal deep nest, `List<T>` is not concrete, a param nested deep still disqualifies, and unresolved is not concrete.

**Cross-references:** `../types.zig` (`TypeStore`, `TypeId`, `SymbolId`), `symbols.zig` (`SymbolTable.symbolAt` for the decl), `sema.zig` (the `Sema` container), `lower.zig` (`Lowerer` for method/field types), `subst.zig` (`substitute` to concretise them), `shadow.zig` (`renderLegacy` for names, and where `report` is printed), codegen (consumes `live_instantiations` / `live_inst_ids` / the worklists to emit bodies).

---

## `src/frontend/sema/ownership.zig` (532 lines)

**Role in the pipeline:** The ARC balance check. This pass proves that every OWNED value (a heap-allocated, reference-counted value: strings, structs with owned fields, containers, and so on) is consumed exactly once, and records the `move` or `drop` op that codegen threads retain/release around. It works on two populations: owned LET-LOCALS (a `let x = <owned>` binding, analysed with a small control-flow walk) and owned TEMPORARIES (an owned intermediate value with no name, e.g. the result of a call used as an argument). A use-after-move on a local is a `violation`; an owned temporary with no recorded move or drop is an unaccounted hole. Both are gated in `shadow.zig`: a non-zero count fails the build with the FOUNDATION GATE message.

The analysis is intentionally conservative: anything it cannot prove linearly (a nested reassignment, a shadow, a loop that moves the local, an untyped init) is `deferred` and left to codegen's existing scope-based dropping rather than asserted about. Only what it can prove is claimed.

**Key types and data structures:**

- **`TypeStore = types.TypeStore`**, **`TypedIr = infer.TypedIr`** (local aliases).
- **`Stats = struct`**: the accounting the shadow report prints. Fields: `fns_walked`, `owned_locals`, `analyzed` (balance claim made and held), `deferred_cfg` (nested CFG / reassign / shadow), `deferred_untyped` (init not typed in the IR), `drop_ops`, `move_outs`, `dup_ops`, `balance_violations`, `first_violation` (the name of the first offending local), and the temporary tallies `temp_moves`, `temp_drops`.
- **`St = enum { live, moved }`** (private): the abstract state of a tracked local: still owned, or already moved out.
- **`Flow = union(enum) { fallthrough: St, returned, deferred, violation }`** (private): the result of walking a statement or a sequence: continue with a state, the path returned, give up (defer to codegen), or a proven use-after-move.

**Module-level state / constants:** none. All state is threaded through `*Stats`.

**Functions (source order):**

- **`analyze(allocator, store, ir, program) -> Stats`** (pub): the entry. Walks every function, struct method, and enum method through `analyzeFn`, returning the accumulated `Stats`. NOTE: it takes `ir: *TypedIr` mutable because the temporary pass RECORDS ops into the IR.
- **`analyzeFn(allocator, f, store, ir, st) -> void`** (private): bumps `fns_walked`, runs the LOCALS analysis (`analyzeStmts`) over the body, then runs the TEMPORARIES analysis (`tempStmt`) over each top-level statement. Two separate passes over the same body.
- **`tempStmt(alloc, ir, s, st) -> void`** (private): the temporaries walk over statements. Descends into blocks, let inits (passing `moved = ls.names == null`, i.e. a scalar bind consumes its init, a destructuring bind does not), return values (moved), expression statements (not moved), and the sub-statements of if/while/for/switch/defer. The `moved` bool it threads to `tempExpr` says whether the value in tail position is consumed by a move or must be dropped.
- **`tempExpr(alloc, ir, e, moved, st) -> void`** (private): the heart of the temporaries pass. If the IR marks this expression OWNED (`ir.ownedOf`), it counts a `temp_move` or `temp_drop` and calls `ir.recordOp` to record `.move` or `.drop` on the expression for codegen. Then it recurses into sub-expressions, propagating `moved` correctly per construct: call/generic_call callee and args are not moved; a binary's right side is moved only for `.assign`; a tuple/struct_init/enum_init field, an if_expr branch, a closure expr body, and a nullish-coalesce's branches are moved; `cast` passes `moved` through; and so on. This is where the drop/move op for every owned temporary is decided.
- **`analyzeStmts(stmts, store, ir, st) -> void`** (private): the LOCALS driver. For each statement it recurses into nested blocks (`recurseIntoNested`) so locals in inner scopes are analysed too, then, for a scalar `let` (`names == null`) with an init: if the init's `TypeId` is missing it counts `deferred_untyped` when the init could plausibly be owned (`initCouldBeOwned`) and moves on; if the type is not owned it skips; otherwise it counts an `owned_local` and runs `analyzeOwnedLocal` over the REST of the statement sequence.
- **`recurseIntoNested(s, store, ir, st) -> void`** (private): descends `analyzeStmts` into block / if branches / while / for / switch bodies, so nested owned locals are discovered.
- **`analyzeOwnedLocal(name, rest, st) -> void`** (private): runs the flow walk (`walkSeq` from `.live`) over the statements after the binding and interprets the result: a `fallthrough` that is still `live` needs a `drop` (+1 `drop_ops`), a `fallthrough` that is `moved` is a `move_out`; `returned` is analysed and balanced; `deferred` bumps `deferred_cfg`; `violation` bumps `balance_violations` and records `first_violation`.
- **`walkSeq(name, stmts, entry, st) -> Flow`** (private): folds `walkStmt` across a statement sequence, threading the `St` state and short-circuiting on `returned` / `deferred` / `violation`.
- **`walkStmt(name, s, state, st) -> Flow`** (private): the per-statement transfer function for the tracked local `name`:
  - `block` -> recurse `walkSeq`.
  - `let_stmt` -> a rebind of `name` itself is `deferred`; a complex mention (see `mentionsComplex`) is `deferred`; `let y = x` (a plain ident init) is a retaining DUP (+1 `dup_ops`), modelled as leaving `x` live (Kyte is reference-counted, not affine, so a dup does not move); a plain mention while `moved` is a `violation`.
  - `expr_stmt` -> `x = ...` (assign to the tracked ident) is `deferred`; complex mention is `deferred`; a mention while `moved` is a `violation`.
  - `return_stmt` -> a complex mention is `deferred`; `return x` is a `move_out` and `returned` (a violation if already moved); any other mention while moved is a violation; a plain `return` while `live` inserts a `drop`.
  - `if_stmt` -> walk both branches from the same entry state and `mergeIf` them.
  - `while_stmt` / `for_stmt` -> `walkLoop`.
  - `switch` / `break` / `continue` / `defer` -> `deferred` if they mention the local, else fall through (conservative: control flow through these is not modelled).
- **`mergeIf(ft, fe, st) -> Flow`** (private): joins the two branch flows. Any `deferred` wins; any `violation` wins; if both branches returned, `returned`; if one returned, take the other's state; if both fall through to the same state, that state; if they DISAGREE (one moved, one live), insert a `drop` and continue as `moved` (the conservative merge: normalise to moved so a later use is caught).
- **`walkLoop(name, cond, body, state, st) -> Flow`** (private): loops are handled conservatively. A complex mention in the condition, or a body that MOVES the local (`seqMovesLocal` -- a move inside a loop could run more than once), or a complex mention in the body, is `deferred`; a plain mention while already moved is a `violation`; otherwise fall through unchanged. (The `st` param is unused here, hence the `_ = st`.)
- **`seqMovesLocal(name, s) -> bool`** (private): does this statement (recursively) MOVE the local by binding or returning it as a bare ident (`let y = x` / `return x`)? Used to reject loops that move.
- **`stmtComplexMentions(name, s) -> bool`** (private): does this statement (recursively) mention the local inside a "complex" expression (closure / if-expr / block-expr / catch-expr, or nested inside binary/call/etc)? Feeds the loop-defer decision.
- **`isIdent(e, name) -> bool`** (private): is `e` exactly the identifier `name`?
- **`stmtMentions(s, name) -> bool`** (private): does the statement mention the local at all (recursive)?
- **`mentionsComplex(e, name) -> bool`** (private): does the expression mention the local inside a control-flow-carrying or nested position? A closure / if_expr / block_expr / catch_expr that mentions it counts (via `mentions`); binary/unary/call/field/index/template/tuple/cast recurse into their children. This is the "I cannot reason about this linearly" detector that triggers deferral.
- **`mentions(e, name) -> bool`** (private): the full recursive "does this expression reference the local anywhere" check, over every expression kind.
- **`initCouldBeOwned(e) -> bool`** (private): a heuristic for the untyped-init case: an integer/float/bool/null/undefined literal is definitely not owned; anything else could be. Used so `deferred_untyped` counts only inits that might have been owned.

**Algorithm summary (owned-ness and where retain/release get threaded):**
- Owned-ness is NOT decided here; it comes from the type store (`store.isOwnedSafe(tid)` for locals) and the typed IR (`ir.ownedOf(e)` for temporaries). This pass decides CONSUMPTION: for each owned value, is it moved out (returned, passed as a consuming arg, stored) or does it need a drop at end of scope?
- The ops it records (`ir.recordOp(e, .move | .drop)` in the temporaries pass) are exactly what codegen reads to place `kyte_retain` / `kyte_release`. The locals pass does not record ops on the IR; it produces the balance verdict and the `drop_ops` / `move_outs` tallies that the shadow gate checks.
- The whole thing is fail-conservative: unprovable cases defer to codegen's pre-existing scope dropping, so the pass can only ADD confidence, never remove a needed release.

**Gotchas / invariants:**
- `analyze` mutates the IR (records ops), despite reading like an analysis. The `ir` param is `*TypedIr`.
- The dup rule (`let y = x` leaves `x` live) is load-bearing and documented inline: modelling it as a linear move produced a false use-after-move on the two real corpus sites, both ASAN-clean.
- Loops defer on any move because the loop body may execute more than once; this is why a moving loop is never asserted balanced here.
- A `switch` is always deferred if it mentions the local (switch arms are not flow-modelled), so switch-heavy owned-local code leans on codegen.

**Cross-references:** `../ast.zig` (every statement and expression kind walked), `../types.zig` (`TypeStore.isOwnedSafe`), `infer.zig` (`TypedIr.typeOf` / `ownedOf` / `recordOp` / `ownedTrueCount`), `shadow.zig` (calls `analyze` and prints/gates the result), codegen/arc.zig (consumes the recorded `.move` / `.drop` ops to emit retain/release, and is the fallback for every deferred case).

---

## `src/frontend/sema/shadow.zig` (1217 lines)

**Role in the pipeline:** The umbrella diff-and-gate harness, gated by `KYTE_SEMA_SHADOW` (via `report_enabled` / `trace_resolution`). `run` is the single entry called by the sema driver. It builds the symbol table, prints the F1 report (symbol-table vs legacy resolution: collisions, ambiguity, shadowing, path-dependence), then drives the full typed pipeline in `runTypeLowering`: lower every declared type (F2 declared-type surface), infer every function body (F2 expression surface), and run the ownership pass (F2-6). Crucially, this is also where the real, user-facing TYPE ERRORS are printed and the compile is aborted: visibility, const reassignment, optional deref, catch/try mismatch, condition type, return-optional, value-optional position, method arity, generic-method-outside-type, undefined identifier, no-such-function, and the two ownership FOUNDATION GATES. So although the file calls itself "report only", it is a hard gate on the build.

Beyond `run`, the file is a large collection of module-level counters and `report*` functions that compare the typed engine against the legacy string engine at many decision points (type identity, ownership decisions, temp-op decisions, dtor-name derivation, dispatch, method mono resolution), plus `renderLegacy`, the canonical `TypeId`-to-string renderer that the rest of sema uses for names and diagnostics.

**Key types and data structures:**

- **`Divergence = struct { kind: enum { legacy_collision, ambiguous_suffix, bare_shadows_qualified, path_dependent_symbol }, detail: []const u8 }`** (pub): a categorised divergence record (declared; used by the F1 reporting).
- **`DispResidue = enum { type_param, enum_, not_owned, other }`** (pub): the categories of an allowed checker-vs-codegen disposition disagreement. `other` is the one that fails the gate.

**Module-level state (there is a great deal; grouped by purpose):**

- Toggles: `trace_resolution`, `report_enabled` (the master gate), `tid_census`, `f2_types_enabled`.
- TID census counters (string resolves but TypeId is null, or they disagree): `census_total`, `census_kind_*`, `census_disagree`, `census_dis_*`, and the `census_dis_last_*` example buffers.
- Render accounting: `render_calls`, `render_allocs`, `render_bytes`, `render_cache_hits`, and the F2 fallback counters `f2_served` / `f2_fellback` / `f2_fellback_lossy`.
- L1 ownership-by-name split: `irct_live_calls`, `irct_primitive`, `irct_resolved`, `irct_string_decided`.
- Live singletons (set during `run` so the free helper functions can reach them): `live_sema`, `live_store`, `live_ir`, plus the private `diff_tab`.
- Scan accounting: `scan_hits`, `scan_ambiguous`, `scan_unresolved`.
- TypeId ownership-diff counters (`td_*`), disposition-diff counters (`disp_*`), temp-op-diff counters (`op_*`), dtor-name counters (`dtor_name_*`, `dtor_name_raw_*`), the store-vs-parse element counters (`tuple_elem_*`, `erru_elem_*`, `storage_elem_*`, `struct_field_*`), the PhaseA release-flip counters (`phaseA_*`), and the F1-3b call-symbol counters (`f1_3b_*` plus `f1_3b_absent_names`).
- F4-5 erased-vs-mono counters: `f45_mono_hit`, `f45_erased_fallback`, `f45_erased_nongeneric`, `f45_erased_by_name`.
- F2-stage-3 diff state: `diff_agree`, `diff_legacy_invented`, `diff_f2_better`, `diff_disagree`, `diff_absent`, the `diff_absent_tags` / `diff_absent_fns` maps, `walk_errors`, `walked_fns`, the `absent_spans` buffer, `diff_clusters` / `diff_cluster_where`, `diff_examples`, and `diff_absent_alloc`.

Most counters live for the process and are printed by the matching `report*` function; several string-keyed maps use `std.heap.page_allocator` directly so they survive across passes.

**Functions (source order):**

- **`tidCensusReport() -> void`** (pub): if `tid_census`, prints the Phase-1 (string resolves, TypeId null) and Phase-1a (both resolve, disagree) census tables plus an example.
- **`out(comptime fmt, args) -> void`** (private): `std.debug.print` gated on `report_enabled`. The report-only print used everywhere below.
- **`run(allocator, program, sm) -> !void`** (pub): THE entry. Sets `live_sema`, builds `sm.tab` from the program, then prints the F1 shadow: module/symbol counts, `[COLLISION]` (two symbols share a `legacy_mangled` name, excluding same-owner methods), `[AMBIGUOUS]` (a bare function name suffix-matches more than one legacy-mangled symbol, i.e. resolved by hash order), `[SHADOW]` (a root function shares a bare name with a module function), `[NEW-COLLISION]` (fixing the prefix would collapse two canonical names), and `[PATH-DEP]` (a legacy symbol embeds an absolute path). Then `setDiffTable(tab)` and calls `runTypeLowering` (errors there are printed but not fatal at this call site, since `runTypeLowering` exits directly on real errors).
- **`runTypeLowering(allocator, program, tab, sm) -> !void`** (private): the big driver. Sets `live_store`. Marks enums tagged/untagged in the store. Builds a `Lowerer`, lowers every function param/return and every struct field/method signature (setting `param_scopes` per declaration so type-params resolve), and prints the F2 declared-type surface (lowered vs unresolved, distinct interned, distinct unresolved names). Builds an `Inferer`, infers every function body and every struct/enum method body (with the receiver `self` type), and then -- this is the gate -- for each category of collected error (`visibility_errors`, `const_reassign_errors`, `optional_deref_errors`, `catch_mismatch_errors`, `try_error_mismatch_errors`, `cond_type_errors`, `ret_optional_errors`, `valopt_pos_errors`, `method_arity_errors`, the inline generic-method-outside-type scan, `fatal_unresolved_idents`, `fatal_unresolved_calls`) prints a formatted diagnostic and calls `std.process.exit(1)`. If no errors, prints the F2 expression surface and the TypedIr stats, then (when `report_enabled`) runs `ownership.analyze` and prints the ownership report; if there are balance violations or unaccounted temporaries it prints the FOUNDATION GATE FAILED message and exits 1.
- **`reportResolution() -> void`** (pub): if `trace_resolution`, prints the suffix-scan usage stats.
- **`reportTypeIdDiff() -> void`** (pub): if `report_enabled`, prints the string-to-TypeId ownership-decision diff, the temp-op diff, the dtor-name / store-vs-parse element diffs, the PhaseA flip stats, and the disposition diff, then GATES: an `other` disposition disagreement fails the F2-6 gate (exit 1), and any concrete or keystone ownership disagreement fails the F5-2 gate (exit 1). These gates are the machinery that proved the string engine could be retired.
- **`noteF13bAbsent(name) -> void`** (pub): records a call name for which no `SymbolId` was found (page-allocated map).
- **`noteF45Erased(missing_mono) -> void`** (pub): records a method that fell back to an erased body under an instantiated name (page-allocated, deduped).
- **`reportF45() -> void`** (pub): prints the F4-5 erased-vs-monomorphised report.
- **`spanOf(e) -> ?ast.Span`** (private): the span of an expression by kind (binary/call/unary/index/generic_call/field_access/cast/struct_init), else null.
- **`canonicalTypeStr(allocator, s) -> []const u8`** (private): rewrites primitive-alias TOKENS in a rendered type string to one canonical spelling (`i32`->`int`, `u8`->`byte`, `f64`->`double`, and so on) so the two engines' names can be compared token-for-token. Only whole identifier tokens are rewritten (a rewriter that invented agreement would be worse than none); returns the input unchanged on allocation failure.
- **`isIdentChar(c) -> bool`** (private): alphanumeric or `_`.
- **`renderLegacy(allocator, store, id) -> anyerror![]const u8`** (pub): the canonical `TypeId`-to-string renderer, and a genuinely load-bearing function (mono, method-inst notes, and diagnostics all call it). It first checks `live_sema.cachedName` (a per-`Sema` name cache) and returns the cached name; otherwise `renderUncached`, and if the type is one whose rendering allocates (`allocatesFor`) it interns the name into the `Sema` cache. Counts `render_calls` / `render_cache_hits`.
- **`allocatesFor(t) -> bool`** (private): true for a generic struct (args > 0), storage, or func: the shapes whose rendering allocates and are therefore worth caching.
- **`renderUncached(allocator, store, id) -> anyerror![]const u8`** (private): the actual renderer, one arm per store `Type`. Primitives render to Kyte's spellings (with the SIMD lane sentinels `u8x16` / `u32x4` / `u64x2` and `f64x4`). A `.struct_` renders `base<arg, ...>` using the symbol's `scoped_name` (falling back to `name`) so colliding types render distinctly; `.enum_` likewise prefers `scoped_name` (documented S3 fix so a same-named enum across modules keeps its identity); `.trait_` keeps the bare name for now. A VALUE-optional (`int | undefined`) renders DISTINCTLY from its inner (documented: otherwise `List<int | undefined>` collapses onto `List<int>` and mixes boxed and raw layouts, a catastrophic UAF), while a heap-optional keeps the inner rendering. `.future` renders as `i64`, `.storage` as `Storage<...>`, tuples and error-unions structurally.
- **`typeParamName(tp) -> ?[]const u8`** (private): the source name of a type-parameter, looked up through `diff_tab` and the owner's declared param names; null if out of range.
- **`nameHint(e) -> ?[]const u8`** (private): a human-readable name for an expression (ident, field, or callee name) for clustering divergences.
- **`noteCluster(allocator, e, legacy, f2, in_fn) -> void`** (private): buckets a legacy-vs-F2 divergence by a formatted key into `diff_clusters` (with a `diff_cluster_where` source location), so the report can show the biggest divergence clusters first.
- **`setDiffTable(t) -> void`** (pub): stashes the symbol table in `diff_tab` so `renderUncached` / `typeParamName` can reach it.
- **`recordDiff(allocator, store, ir, e, legacy, in_fn) -> void`** (pub): the per-expression comparator codegen calls. Looks up the IR's type for `e`; if absent, counts `diff_absent` (and records the span/tag/fn). Otherwise renders it, canonicalises both names, and buckets the result: legacy invented a type the IR calls unresolved (`diff_legacy_invented`), the two agree (`diff_agree`), or they disagree (`diff_disagree`, clustered and exampled). When there is no legacy name, an unresolved IR is agreement and a typed IR is `diff_f2_better`.
- **`reportDiff() -> void`** (pub): if `trace_resolution`, prints the F1 stage-3b call-symbol diff and the F2 stage-3 TypedIr-vs-legacy diff, including the absent breakdown (with a `sema-walked` flag per function) and the clustered divergences.

**Gotchas / invariants:**
- `report_enabled` is the master switch. With it off, the diff counters are still bumped by callers but nothing prints AND the ownership gate does not run -- the type-error gates in `runTypeLowering`, however, still fire because they use `std.debug.print` + `exit` directly, not `out`. Read: turning the shadow off does not turn off type checking.
- `renderLegacy` caches through `live_sema`, so it must not be called before `run` sets `live_sema`, and the cached names live as long as the `Sema`.
- The value-optional distinct rendering in `renderUncached` is a correctness rule, not cosmetic: changing it reintroduces a boxed/raw layout collision.
- Many maps here use the page allocator on purpose so they persist across passes; they are never freed (compiler-lifetime).

**Tests:** two `test` blocks for `canonicalTypeStr` (aliases collapse to one word; only whole tokens are rewritten).

**Cross-references:** `../ast.zig`, `../types.zig` (`TypeStore`, `TypeId`, `Type`, `TypeParam`), `symbols.zig` (builds and reads the table), `lower.zig` (`Lowerer` / `ParamScope`), `infer.zig` (`Inferer`, `TypedIr`, and every error-collection list), `ownership.zig` (`analyze` and the gate), `sema.zig` (the `Sema` container, `cachedName` / `internName`), `mono.zig` and codegen (consumers of `renderLegacy`), codegen/arc.zig (the disposition and temp-op diffs compare against arc's decisions).

---

## How the pieces call each other (quick map)

- `shadow.run` -> `symbols.SymbolTable.build` -> `shadow.runTypeLowering`.
- `runTypeLowering` -> `lower.Lowerer.lower` (declared types) -> `infer.Inferer.inferFunction*` (bodies) -> the error gates -> `ownership.analyze`.
- `mono.Worklist.note` -> `lower.Lowerer.lower` + `subst.substitute` to follow generic field/return types; `mono.noteMethodInst` / `noteFreeFnInst` -> `shadow.renderLegacy` + `store.intern` for keys.
- `infer.zig` -> `subst.solveParams` / `substituteOne` for method-type inference (and `subst.substitute` for concretising).
- `ownership.zig` reads `infer.TypedIr` (`ownedOf` / `typeOf`) and `types.TypeStore` (`isOwnedSafe`), writes `.move` / `.drop` ops back into the IR for codegen/arc.zig.
- `shadow.renderLegacy` is the shared `TypeId`-to-name renderer used by mono and diagnostics, and its output feeds the string-keyed dedup in the mono worklists.
