# Codegen core: `LlvmCompiler` and the LLVM-C emission scaffolding

This is the heart of Kyte's code generator. `src/backend/codegen/llvm_codegen.zig` defines the `LlvmCompiler` struct, the single mutable object that every other codegen file threads `self` through. It owns the LLVM module, builder and target machine, the symbol tables (`func_map`, `structs`, `enums`, `traits`, `constants`), the string and decimal literal interning caches, the closure and lambda bookkeeping, and the "everything is an i64 `val_type` word" value ABI on which declarations, expressions, statements and ARC all agree. Almost all of the low-level helpers that the other files call live here: `compileAlloc`, the ARC seam re-exports, `getFieldOffset`, `toLLVMType`, `castTo/FromValType`, `symbolName`, `concreteTidForTypeRef`, `buildValoptBox`/`buildValoptUnbox`, `buildAnyBox`/`coerceToAny`, `getOrCreateStringLiteral`, `getOrCreateDecimalLiteral`, `constructTraitObject`, the method/namespaced call dispatcher, and the pre-passes that populate the function and string tables before any body is compiled.

## `src/backend/codegen/llvm_codegen.zig` (3936 lines)

**Role in the pipeline:**

The compiler pipeline hands `LlvmCompiler` a merged `ast.Program` (all imported modules concatenated) plus the sema outputs: the typed IR (`typed_ir`), the `TypeStore` (`type_store`), and the live sema handle reachable through `sema_shadow.live_sema`. Codegen runs in two broad phases. First a set of pre-passes walk the whole program and fill the tables: `collectFunctions` registers every free function, method (per monomorphised instantiation) and lambda into `functions` and later `func_map`; `collectStringLiterals` interns string literals; `collectLocalVarNames`/`collectLocalVarTypes` build the per-function local name and type maps. Then the actual emission, driven from `declarations_mod.compile` (re-exported as the module-level `compile` at the very bottom), walks each declaration and lowers bodies statement by statement, expression by expression.

The value-representation ABI is the spine of the whole backend: **every Kyte value is materialised as a single 64-bit integer, `self.val_type` (an `LLVMInt64Type`)**. An `int` is that word sign-narrowed to 32 bits on demand, a `bool` is the low bit, a `double` is the 64 bits reinterpreted (`bitcast`, not convert), and every heap object (string, list, struct instance, enum box, trait object, `any` box, value-optional box, closure environment) is its address stored in that same word. Heap objects carry an 8-byte header: a 32-bit refcount at offset -8 and a 32-bit length at offset -4. This uniform word is what lets generic containers, `any`, trait fat pointers and the ARC calls all speak one representation. The recurring footgun is that addresses are 64-bit but `int` is 32-bit: any arithmetic that accidentally narrows a pointer to `i32` produces a garbage address, so the coercion helpers (`castToValType`/`castFromValType`, `coerceToSlotType`) and the call-argument casting in `buildCallWithCasts` are where correctness is won or lost.

`LlvmCompiler` owns these LLVM handles directly: `module` (the whole compilation unit), `builder` (the single instruction builder, repositioned as needed), `target_machine` (drives layout and the final object emission), and cached type handles `i1_type`, `i8_type`, `i32_type`, `i64_type`, `void_type`, `ptr_type` and `val_type`. The other codegen files (`declarations.zig`, `expressions.zig`, `statements.zig`, `arc.zig`, `types.zig`) do NOT use Zig's `usingnamespace`. Instead, `LlvmCompiler` re-exports their functions as public declarations, for example `pub const compileExpression = expressions_mod.compileExpression;`. Because Zig resolves `self.compileExpression(...)` method-call syntax against `pub const` function declarations on the type, these aliases make functions physically defined in the sibling files behave exactly like methods on `LlvmCompiler`. So the real code is split across files but every function takes `*LlvmCompiler` as its first parameter and shares one namespace. The blocks of `pub const X = mod.X;` at lines 494-499, 595-612, 1296-1303, 2915-2917 and 3834-3933 are the wiring that binds the pieces into one object.

**Key types & data structures:**

**`FunctionInfo`** (line 55, pub) is the codegen-side record of a compilable function (free function, method instantiation, or lifted lambda). Fields:
- `name: []const u8` -- the mangled emit name (allocator-owned in most construction paths; freed in `deinit` only via `param_names`, see the gotcha below).
- `param_count: usize`, `param_names: []const []const u8` -- arity and parameter names. `param_names` is allocator-owned and is the one allocation `deinit` frees per function.
- `return_type: []const u8` -- rendered return type string ("void" when none).
- `ret_type_ref: ?ast.TypeRef` -- the raw declared return type ref, kept for value-optional/return-boxing decisions.
- `body: ast.Block` -- the AST body to lower.
- `params: []const ast.Param` (default `&.{}`) -- the DECLARED params, populated ONLY for free functions and non-constructor methods (where `self` is explicit at index 0 so AST params line up 1:1 with LLVM args). Left empty for constructors (synthetic `self`) so the optimiser emit path (`lir_emit.zig`) sees the count mismatch and falls back.
- `is_async: bool` -- drives coroutine lowering and `async_fns` membership.
- `instantiation: ?[]const u8` -- the string instantiation key (angle-form owner like `Map<string, any>`).
- `instantiation_id: ?sema_types.TypeId` -- the explicit TypeId instantiation key, set directly to bypass the fragile name->live_inst_ids lookup (string-engine-removal work).
- `erased_generic: bool` -- true for the link-time fallback body with internal linkage that globalDCE drops.
- `source_file: []const u8` -- the source file, used for module-prefix resolution.

**`Scope`** (line 80, pub) is one lexical scope frame pushed onto `scopes`:
- `deferred_statements: std.ArrayList(ast.Expression)` -- `defer` bodies to run at scope exit.
- `errdeferred_statements` -- `errdefer` bodies to run on error unwind.
- `owned_locals: std.ArrayList(OwnedLocal)` -- locals whose ARC references must be released at scope end.

**`OwnedLocal`** (line 88, pub) -- `{ name, type_name }`, a heap-owning local tracked for release.

**`PendingTemp`** (line 93, pub) -- a temporary value awaiting drain: `{ val, slot, type_name, expr_id }`. Used by the temporary-registration machinery (`registerTemporary`/`drainTemporaries` in expressions.zig) so freshly created owned temporaries have their caller-side reference released at statement end.

**`SimdTarget`** (line 105, pub enum: `none`, `aarch64`, `x86_64`) -- which hardware crypto/SIMD intrinsic family the target triple provides, decided once in `new`.

Re-exported types: `CoverageBlock` and `CoverageRegistry` (lines 13-14, from `coverage.zig`).

**`LlvmCompiler`** (line 107, pub) -- the central object. Fields in declaration order:

- `allocator: std.mem.Allocator` -- the arena/allocator for all codegen allocations.
- `module: types.LLVMModuleRef` -- the LLVM module (owned; disposed in `deinit`).
- `builder: types.LLVMBuilderRef` -- the shared instruction builder (owned; disposed in `deinit`).
- `target_machine: types.LLVMTargetMachineRef` -- target machine for layout + object emission (owned; disposed).
- `functions: std.ArrayList(FunctionInfo)` -- every compilable function record (owned; `param_names` freed per entry in `deinit`).
- `strings: std.ArrayList([]const u8)` -- collected string literals (slices borrowed from the AST).
- `scopes: std.ArrayList(Scope)` -- the live lexical scope stack (deferred lists freed in `deinit`).
- `locals: std.StringHashMap(types.LLVMValueRef)` -- current function's local-name -> alloca slot.
- `func_map: std.StringHashMap(types.LLVMValueRef)` -- mangled name -> LLVM function value. The authoritative call-resolution table.
- `param_type_cache: std.StringHashMap(?ast.TypeRef)` -- memoises `getFunctionParamTypeRef`; key `"name\x00idx"` (keys owned, freed in `deinit`).
- `param_type_str_cache: std.StringHashMap(?[]const u8)` -- memoises `getFunctionParamType`; stored value strings owned (keys and values freed in `deinit`).
- `value_escape_set: ?std.StringHashMap(void)` (default null) -- lazily computed base names of structs that ESCAPE their frame and so must NOT be value-lowered (M-1 escape analysis). null = not yet computed.
- `structs: std.StringHashMap(ast.StructDecl)` -- scoped struct name -> decl.
- `unions: std.StringHashMap(ast.UnionDecl)` -- union name -> decl.
- `enums: std.StringHashMap(ast.EnumDecl)` -- scoped enum name -> decl.
- `traits: std.StringHashMap(ast.TraitDecl)` -- trait name -> decl (drives vtable layout).
- `ffi_externs: std.StringHashMap(ast.FunctionDecl)` -- FFI extern declarations.
- `constants: std.StringHashMap(ast.Expression)` -- top-level const name -> initialiser expression.
- `current_local_types: ?*std.StringHashMap([]const u8)` -- pointer to the current function's local-name -> type-string map.
- `current_local_type_ids: ?*std.StringHashMap(sema_types.TypeId)` -- pointer to the current function's local-name -> TypeId map (the authoritative typed view for value-optional/ownership decisions).
- `pending_temps: std.ArrayList(PendingTemp)` (default `.empty`) -- owned temporaries awaiting drain.
- `current_struct_name: ?[]const u8` -- the struct whose method body is being compiled (for `self` typing).
- `current_instantiation: ?[]const u8` -- the active string instantiation (angle-form owner) for type-param substitution.
- `current_instantiation_id: ?sema_types.TypeId` (default null) -- the active TypeId instantiation key; the TypeId-native equivalent of the above.
- `suppress_valopt_unbox: bool` (default false) -- set while compiling a call argument whose substituted param type is a value-optional, so the speculative ident-unbox in `compileExpr` does not strip a box that must survive into a value-optional parameter.
- `default_ctor_depth: u32` (default 0) -- recursion guard for default constructor synthesis.
- `rendered_name_ids: ?std.StringHashMapUnmanaged(sema_types.TypeId)` (default null) -- cache of rendered-name -> TypeId.
- `current_module_prefix: ?[]const u8` -- module prefix for the file being compiled.
- `current_function_name: ?[]const u8` -- the emit name of the function currently being lowered (used by `envCaptureIndex`).
- `current_loop_scope_depth: ?usize` -- the scope depth at loop entry, for break/continue cleanup.
- `current_collecting_function_name: ?[]const u8` -- during closure collection, the enclosing function (parent of any lambda).
- `current_collecting_instantiation: ?[]const u8` -- the string instantiation active during closure collection.
- `current_collecting_instantiation_id: ?sema_types.TypeId` (default null) -- SE-C: the TypeId inst_key active during closure scanning; a lifted lambda inherits it as its own `instantiation_id`.
- `current_collecting_erased_generic: bool` (default false) -- whether the scanning context is an erased generic body.
- `lambda_parents: std.StringHashMap([]const u8)` -- lambda name -> enclosing function name.
- `lambda_param_types: std.StringHashMap([]const ?[]const u8)` -- lambda name -> declared param type strings.
- `function_local_types: std.StringHashMap(std.StringHashMap([]const u8))` -- per-function local type maps (inner maps freed in `deinit`).
- `function_local_type_ids: std.StringHashMap(std.StringHashMap(sema_types.TypeId))` -- per-function local TypeId maps.
- `captured_globals: std.StringHashMap(types.LLVMValueRef)` -- captured global-var slots for closures (keys owned, freed in `deinit`).
- `lambda_captures: std.StringHashMap(std.ArrayListUnmanaged([]const u8))` -- lambda name -> captured free-variable names (inner lists freed in `deinit`).
- `fn_box_globals: std.StringHashMap(types.LLVMValueRef)` -- interned function-box globals (bare `fn` values).
- `typed_ir: ?*const sema_infer.TypedIr` (default null) -- the sema typed IR, queried for expression TypeIds.
- `f2_types: bool` (default false) -- F2 typed-IR gate flag.
- `type_store: ?*const sema_types.TypeStore` (default null) -- the sema type store, the authority on ownership/optionality.
- `current_scanning_lambda: ?[]const u8` (default null) -- the lambda currently being scanned for captures.
- `program: ast.Program` -- the merged program (set after `new`, initially undefined).
- `has_log: bool` -- whether the program uses logging (drives runtime-fn declaration).
- `next_lambda_id: u32` -- monotonically increasing lambda id counter.
- `closure_lambdas: std.StringHashMapUnmanaged([]const u8)` -- closure key (span+inst) -> lambda name; the map from a closure literal's site to its lifted function.
- `current_saved_captures: std.StringHashMap(types.LLVMValueRef)` -- saved capture slot values across a call boundary.
- `is_wasm: bool` -- WASM target flag (changes pointer size, memory functions).
- `simd_target: SimdTarget` (default `.none`) -- the crypto-intrinsic family (see enum above).
- `coverage_enabled: bool` and `cov_registry: ?CoverageRegistry` -- coverage instrumentation state (registry deinit'd in `deinit`).
- `current_string_builder: ?types.LLVMValueRef` (default null) -- the active StringBuilder for template/NSX emission.
- `jsx_pending_literal: std.ArrayListUnmanaged(u8)` (default `.empty`) -- compile-time accumulator that coalesces adjacent NSX static text into one `append` (flushed before any dynamic part).
- `current_param_names: ?[]const []const u8` (default null) -- the current function's param names.
- `current_async_promise`, `current_async_final_bb`, `current_async_hdl`, `current_async_suspend_bb`, `current_async_cleanup_bb` -- the coroutine-lowering context for the async function being compiled (promise value, final block, coroutine handle, suspend and cleanup blocks).
- `async_fns: std.StringHashMap(void)` (default undefined, init'd in `new`) -- set of async function emit names; membership routes a call through `buildDriveAsyncCall`.
- `i1_type`, `i8_type`, `i32_type`, `i64_type`, `void_type`, `ptr_type`, `val_type` -- the cached LLVM type handles. `ptr_type` is `i8*`; `val_type` is `i64` (the universal value word).
- `string_globals: std.StringHashMap(types.LLVMValueRef)` -- interned string literals -> their global (keys owned).
- `decimal_globals: std.StringHashMap(types.LLVMValueRef)` -- interned decimal literal digits -> lazy-init global (keys owned).
- `puts_fn`, `printf_fn`, `kyte_log_string_fn`, `kyte_log_info_fn`, `kyte_log_debug_fn`, `kyte_log_err_fn`, `log_fn` -- cached runtime/libc function values (declared lazily).
- `heap_ptr`, `free_list`, `persistent_ptr` -- the WASM bump-allocator globals (heap pointer, free list head, persistent-region pointer).
- `current_break_bb`, `current_continue_bb` -- the target blocks for `break`/`continue` in the current loop.

**Module-level state / constants:**

There is no mutable module-level state; all state lives on `LlvmCompiler`. The module-level declarations are: the import aliases (`std`, `ast`, `sema_mono`, `llvm` and its sub-namespaces `types`/`core`/`target`/`target_machine`/`analysis`, `types_mod`, `sema_infer`, `sema_types`, `sema_shadow`, `arc_mod`, `statements_mod`, `declarations_mod`, `expressions_mod`, `coverage_mod`); the two re-exported coverage types; the helper functions `getStructBaseName` and `isPrimitiveTypeName` pulled from `types_mod`; the free function `unescapeString`; and the module-level `pub const compile = declarations_mod.compile;` at line 3936 that is the codegen entry point.

**Functions** (source order; every function defined in this file, plus the re-export aliases grouped at the end):

- **`fn unescapeString(allocator, input: []const u8) ![]const u8`** (module-level, pub). Decodes backslash escapes (`\n \r \t \\ \" \'`; unknown escapes pass through with the backslash kept). Returns a fresh owned slice the CALLER frees. Uses a local `ArrayList(u8)` that is deinit'd, so only the `toOwnedSlice` result survives.

- **`fn new(allocator, is_wasm, is_release, target_triple_opt, coverage_enabled) !LlvmCompiler`** (pub). Constructs the compiler. Initialises all LLVM targets/asm printers, resolves the triple (forces `wasm32-unknown-unknown` for wasm, else the passed triple, else the host default), creates the target machine (aggressive opt in release, none otherwise; for a native non-cross build it queries `LLVMGetHostCPUName`/`Features` so the vectorizer sees real vector units), creates the module `kyte_module` and the builder, sets the data layout, and returns a fully zeroed `LlvmCompiler` with every hashmap `init`'d and the cached type handles built (`val_type = LLVMInt64Type`, `ptr_type = i8*`). Decides `simd_target` from the triple. Side effects: allocates and owns `module`, `builder`, `target_machine`; `program` is left `undefined` (the caller sets it). Errors: `error.LLVMTargetError`, `error.LLVMTargetMachineCreationError`.

- **`fn deinit(self) void`** (pub). Disposes the builder, module and target machine; frees each `FunctionInfo.param_names`; deinits every hashmap and array; frees the owned keys of `param_type_cache`/`param_type_str_cache`/`captured_globals` and the owned value strings of `param_type_str_cache`; deinits the inner maps of `function_local_types` and the inner lists of `lambda_captures`; deinits the coverage registry. Note it does NOT free `FunctionInfo.name` (a leak class accepted because codegen runs once per process).

- **`pub const isStructType`, `pub const valueOptionalName`** (line 430-431) -- re-exports from `types_mod`.

- **`fn closureKey(self, span, inst: ?[]const u8) ![]const u8`** (pub). Builds a closure identity key from span + string instantiation + the active TypeId inst (via `closureKeyActiveInstId`). Owned result.

- **`fn closureKeyActiveInstId(self) ?sema_types.TypeId`** (private). Returns `current_collecting_instantiation_id orelse current_instantiation_id` -- the TypeId discriminator that keeps registration-time and lookup-time keys matching (SE-C).

- **`fn closureKeyM(self, span, inst, inst_id) ![]const u8`** (pub). The explicit form: formats `"{span-hash}|{inst}|{inst_id}"`. Owned result the caller frees (or hands to `closure_lambdas`).

- **`fn getClosureUniqueId(span) usize`** (pub, static). Wyhash of the span's file+line+col -- a stable per-site id.

- **`fn getTupleElementType(allocator, tuple_type, idx) ![]const u8`** (pub, static). Parses a `(A, B, C)` tuple type string and returns element `idx` (depth-aware comma splitting so nested `<>`/`()` do not confuse it). Falls back to `"i32"` for a non-tuple or out-of-range index. Owned result.

- **`fn getOrCreateStringLiteral(self, str) !LLVMValueRef`** (pub). Interns a string literal to an internal-linkage global laid out as `{ i32 refcount, i32 len, [N x i8] chars }`, then returns a `ptrtoint` of the chars field into `val_type` (so a Kyte string is the address of the char data, with the header 8 bytes before it). The refcount initialiser is **-1000000000** (a NEGATIVE sentinel), which makes `kyte_retain`/`kyte_release` full no-ops (they early-return on `*rc < 0`) so the shared global is immortal and never drifts to a double-free. On a cache hit it still rebuilds the GEP+ptrtoint in the current block. Allocates a duped key stored in `string_globals` (owned by the map).

- **`fn getOrCreateDecimalLiteral(self, digits) !LLVMValueRef`** (pub). Interns a decimal literal (`0m`, `2m`, ...) to a lazily-initialised `val_type` global. Emits a runtime check `if (cache == 0) { parse once via kyte_decimal_from_string; pin its header refcount to -1000000000; store into cache }` then a phi of cached-or-parsed. Turns a per-evaluation heap-alloc+parse into a load plus a predicted branch. The pinned negative refcount makes sharing it across owners safe. Builds three basic blocks (`dec_init`, `dec_cont`) and a phi.

- **`pub const compileRetain, errUnionParts, buildErrUnion, compileRelease, elideBorrowedArc, getOrCreateDestructor, getOrCreateTraitDestructor, getOrCreateDestructorByTypeId, getOrCreateDestructorPreferId, releaseLocalVariables, releaseLocalByName, dropValueStruct, substituteFieldType, substTypeParams`** (lines 595-608) -- ARC and substitution re-exports from `arc_mod`. Plus `substMethodParams, methodSymbol, instantiationsOf, qualifySelfType` from `types_mod` (609-612).

- **`fn compileAlloc(self, size) !LLVMValueRef`** (pub). Lazily declares and calls `kyte_bytes_alloc(val_type) -> val_type` (the ARC-headed heap allocator). Returns the client pointer as a `val_type` word. The workhorse allocator for strings, structs, enum boxes, trait objects.

- **`fn compileAllocArray(self, size) !LLVMValueRef`** (pub). Same but calls `kyte_array_alloc(val_type) -> ptr` returning a real `ptr` (not an int), so fixed-array construction keeps pointer provenance and LLVM can vectorize/hoist the access loops.

- **`fn compileAllocPersistent(self, size) !LLVMValueRef`** (pub). Calls `kyte_bytes_alloc_persistent` for allocations that outlive a request arena.

- **`fn valueOptionalInner(self, tid) ?sema_types.TypeId`** (pub). Given a TypeId, if it is a value-optional (`prim | undefined`, a non-owned `enum | undefined`, or a NESTED value-optional whose inner is itself a value-optional) returns the inner TypeId, else null. This is the single decision that classifies a type as value-lowered-optional (boxed inline) vs reference-optional (nullable pointer). Recurses one level for nesting so `(int|undefined)|undefined` stays distinct from `absent`.

- **`fn valoptDepth(self, tid) usize`** (pub). Counts how many value-optional levels wrap a type (0/1/2...), each level being one heap box. Drives how many box/unbox peels a coercion needs.

- **`fn buildValoptBox(self, value) !LLVMValueRef`** (pub). Lazily declares and calls `kyte_valopt_box(val_type) -> val_type` -- heap-boxes a raw value so a value-optional slot can distinguish present-holding-0 from absent (0).

- **`fn buildValoptUnbox(self, box) !LLVMValueRef`** (pub). The inverse: `kyte_valopt_unbox`. Peels one box level, yielding the raw payload word.

- **`fn buildAnyBox(self, payload, dtor) !LLVMValueRef`** (pub). Calls `kyte_any_box(payload, dtor) -> val_type`, building a `{payload, dtor}` owning carrier so an `any` slot records how to release its payload.

- **`fn buildAnyUnbox(self, box) !LLVMValueRef`** (pub). Calls `kyte_any_unbox` to recover the payload word.

- **`fn coerceToAny(self, val, src_expr) !LLVMValueRef`** (pub). Widens a value into an owning `any` carrier. If the source is already `any`, returns it. For a VALUE struct (no heap identity, `payload` is a stack alloca that would outlive the box) it heap-promotes: allocates a fresh ARC-headed block, `buildValueStructCopyInto`s the struct, retains its owned fields (`retainValueStructOwnedFields`), records the struct's destructor, boxes that, and registers the box as a temporary. For a heap (owned) source it records the destructor and either retains (when the source is a live borrow: ident/field/index) or consumes the temporary (transferring the ref), then boxes. Registers the resulting box as an owned temporary of type `"any"`. Side effects: emits allocs/copies/retains, mutates `pending_temps`.

- **`fn valoptTypeRefIsValue(self, tr) bool`** (pub). Decides whether an `ast.TypeRef` optional is a VALUE optional (boxed) vs a reference optional. Resolves the inner type through the current instantiation (via `concreteTidForTypeRef` + `symbolName`, the sanctioned TypeId->name boundary) so a `T | undefined` parameter decides on its CONCRETE argument, falling back to the declared-ref string render only for a genuinely erased body. Value when the inner is a codegen primitive, a nested value-optional name, or a non-tagged-union enum; not-value when the inner is `ptr`.

- **`fn valoptTypeRefIsNested(self, tr) bool`** (pub). True when `tr` is a NESTED value-optional (an optional whose inner renders as a value-optional name). Used to force the outer box on return even when the returned expression already yields the inner box.

- **`fn argIsValoptLocal(self, arg) bool`** (pub). True when `arg` is a bare identifier whose local SLOT TypeId is a value-optional. The slot type is authoritative where a generic container param's element type has been collapsed by monomorphisation, so this keeps the box intact when forwarding.

- **`fn methodParamIsValueOptional(self, recv_expr, method_name, param_idx) bool`** (pub). Does a generic method's `value: T` parameter resolve, for THIS receiver instance, to a value-optional element type? Routes through the receiver's struct TypeId args (which preserve optionality) rather than the substituted param string. `param_idx` excludes `self`.

- **`fn exprYieldsValoptBox(self, e) bool`** (pub). True when an expression of value-optional type already yields the BOXED representation (so a consumer must unbox rather than treat the box pointer as a raw value). Covers ident/field/call/generic_call/index/optional_chaining/await/catch/try and a `??` peel of a nested value-optional.

- **`fn isUndefinedLiteralExpr(e) bool`** (pub, static). True for an `undefined`/`null` literal.

- **`fn ptrElemSize(self) u64`** (pub). 4 on wasm, 8 native -- the pointer/element size for GEP-by-word arithmetic (e.g. vtable slot stride).

- **`fn valSlotSize(self) usize`** (pub). Always 8 -- the size of one value word in a closure environment.

- **`fn envCaptureIndex(self, name) ?usize`** (pub). For a `__lambda_*` function, the index of `name` in its capture list, else null. Used to rewrite a captured free variable to an env-slot load.

- **`fn envSlotAddr(self, index) !LLVMValueRef`** (pub). Computes the address of capture slot `index`: loads the `__env` local, adds `index * valSlotSize()`. Errors `error.EnvNotFound` if no `__env` local.

- **`fn compileFree(self, ptr) !LLVMValueRef`** (pub). Lazily declares and calls `kyte_bytes_free(val_type) -> void`; returns a constant 0 word.

- **`fn generateWasmMemoryFunctions(self) !void`** (pub). Emits the whole WASM bump-allocator by hand: `kyte_bytes_free` (frees only arena-region or zero pointers, else pushes onto the free list), `kyte_bytes_alloc` (seeds the heap from `__heap_base` on wasm, writes a 4-byte size header, bumps `heap_ptr` with 8-byte alignment), `kyte_bytes_alloc_persistent` (a free-list first-fit walk with bump fallback into the persistent region), and stub `kyte_retain`/`kyte_release` (no-op ret void, since wasm uses the arena model). Builds many basic blocks with its own temporary builders. Registers all into `func_map`.

- **`fn getStructPrefix(self, fn_decl) ?[]const u8`** (pub). Returns the scoped struct name a function belongs to, by inspecting a `self` first parameter's type or (for `new`) the return type. Used to mangle methods as `Struct_method`.

- **`fn isAlreadyNamespaced(name) bool`** (pub, static). True when `name` already starts with a known stdlib module prefix followed by `_` (e.g. `string_`, `net_http_server_`), so the module-prefix pass does not double-prefix it.

- **`fn fieldStoredInline(self, base) bool`** (pub). Whether a struct field of type `base` is stored INLINE by value (its full size) vs as an 8-byte pointer. Delegates to `isValueStructName` (the escape-aware predicate), NOT `is_reference` alone, so a heap-kept struct stays a pointer field and layout matches the rest of codegen.

- **`fn getTypeAlign(self, type_ref) u32`** (pub). Natural field alignment: a scalar to its width, an inline value struct to the max of its fields' alignments, else 8.

- **`fn getTypeSize(self, type_ref, is_field) u32`** (pub). Byte size of a type. Primitives by repr; a generic as 8 when a field else its struct payload size; a struct inline (full payload) when a value field else 8 as a pointer field; a union as its widest field's size (8 as a field). The `is_field` flag is what distinguishes an inline value-struct field from a pointer field.

- **`fn structPayloadSize(self, s) u32`** (private). Sums each field placed at its natural alignment, rounds the total up to the struct's own alignment -- matches C/Swift struct layout so inline nesting stays aligned.

- **`fn getFieldOffset(self, struct_name, field_name) !u32`** (pub). Byte offset of a field within a struct (0 for a union). Walks fields accumulating aligned offsets. Errors `StructTypeNotFound`/`FieldNotFound`. The single source of truth for field GEP arithmetic.

- **`fn buildCallWithCasts(self, fn_val, args) !LLVMValueRef`** (pub). The universal call emitter. FAIL-CLOSED: if the function is non-vararg and the arg count mismatches the signature it prints a loud "compiler error" and `std.process.exit(70)` (a mismatch here is a codegen bug, since sema catches user arity errors). Otherwise it casts each argument to its expected param type (int<->ptr via inttoptr, int<->double via bitcast for 64-bit, integer width trunc/zext), builds the call, and coerces the return back into the `val_type` word (ptr->ptrtoint, integer sext/trunc to 64-bit, void->constant 0). This is where the i64-word ABI meets real LLVM function signatures.

- **`fn getFunctionParamType(self, func_name, param_idx) ?[]const u8`** (pub). Memoised (via `param_type_str_cache`) string form of a function's parameter type. On a hit returns a FRESH dupe (the caller owns its result). Delegates to the uncached scan on cache-key allocation failure.

- **`fn getFunctionParamTypeUncached(self, func_name, param_idx) ?[]const u8`** (private). The O(all-declarations x methods x instantiations) linear scan: matches a free function by mangled or raw name and renders its param type; matches a method across its instantiations (param 0 is the struct; constructors shift the index by 1) rendering under the CALLEE's instantiation so a struct type-param resolves to its concrete arg. Returns an owned string.

- **`fn getFunctionParamTypeRef(self, func_name, param_idx) ?ast.TypeRef`** (pub). Memoised (`param_type_cache`) TypeRef sibling of the above.

- **`fn getFunctionParamTypeRefUncached(self, func_name, param_idx) ?ast.TypeRef`** (private). The same scan returning the raw `ast.TypeRef` rather than a rendered string.

- **`fn coerceValoptArg(self, val, arg, param_tr_opt, param_str_opt) !LLVMValueRef`** (pub). Coerces a call argument to its parameter's value-optional/any ABI. If the substituted param string is `any`, widens via `coerceToAny` (unless already any). For a value-optional param that receives a deeper (nested) value-optional argument, peels the surplus box levels (arg_depth - param_depth) so the box is delivered at the parameter's declared depth. For a value-optional param receiving a plain value (not undefined, not already boxed), boxes it. Gated so a generic-container element slot keeps the full box.

- **`fn findNamespacedSpec(self, obj, field, type_args) !?LLVMValueRef`** (pub). Resolves a namespaced generic specialisation `obj_field__mangled(type_args)` in `func_map`, falling back to a suffix match on the map keys. Owned scratch buffers freed internally.

- **`fn getGlobalVTable(self, struct_name, trait_name) !LLVMValueRef`** (pub). Builds (or returns the existing) constant vtable global `_vtable_{struct}_{trait}`: an array of `ptr` with SLOT 0 = the struct's destructor and slots 1..N = the trait methods resolved as `{struct}_{method}` (with a lowercase-struct fallback), null-filled when unresolved. Errors `TraitNotFound`.

- **`fn constructTraitObject(self, struct_ptr, struct_name, trait_name_raw) !LLVMValueRef`** (pub). Builds a trait fat pointer: allocates 16 bytes, RETAINS the struct pointer, stores `{struct_ptr, vtable_int}` (the vtable found by BASE struct name, since generic trait objects erase the type arg and share one vtable), registers the object as a temporary, returns its address word.

- **`fn getOrCreateAtomicExternFn(self, fn_name, t_name, method_name) !LLVMValueRef`** (private). Lazily declares an atomic runtime extern with the right signature by method (`compareAndSwap`->i32, `store`->void, else the width of `t_name`) and the right param list (ptr, plus operand(s) for add/sub/store/cas). Caches an owned-key copy in `func_map`.

- **`fn compileAtomicCall(self, obj_type, method_name, obj_expr, args_exprs) !LLVMValueRef`** (pub). Lowers an `Atomic<T>` method call: extracts `T` from the angle brackets, loads the atomic's inner pointer, picks the right `kyte_atomic_*_{i32,i64,bool}` extern, compiles and casts the operands, builds the call, and truncates a CAS result to `i1`. Errors `UnknownAtomicMethod`.

- **`fn compileExplicitGenericMethodCall(self, fa, type_args, args_exprs) !?LLVMValueRef`** (pub). Handles an explicitly-parameterised generic method `recv.method<T>(...)`. Finds the method decl, builds the mangled spec name (`Struct_method__T`), looks it up in `func_map` (returns null if absent), compiles `self` + args (widening struct args to trait objects where the param is a trait), and emits the call.

- **`fn resolveParamTypeForWiden(self, obj_type_opt, expected_type) []const u8`** (private). If the receiver type is generic, substitutes the field/param type through it (`substituteFieldType`), else returns `expected_type` unchanged. Used to decide trait/any widening for a call argument.

- **`fn buildTraitVtableCall(self, fa, m_idx, args_exprs) !LLVMValueRef`** (pub). Emits a dynamic dispatch through a trait object: loads `{struct_ptr, vtable}`, loads the function pointer at vtable slot `m_idx + 1` (slot 0 is the destructor), builds an all-`val_type` function type, and calls it with `struct_ptr` prepended to the args.

- **`fn compileMethodOrNamespacedCall(self, callee_fa, args_exprs) !LLVMValueRef`** (pub). The big method/namespaced/constructor call dispatcher (the file's largest function). It: resolves the receiver's type name; special-cases `Atomic` -> `compileAtomicCall`; handles enum tagged-variant construction `Enum.Variant(payload)` (allocates the box, stores tag + payload words with ownership retain/consume); dispatches a trait-typed receiver through `buildTraitVtableCall` (driving the async handle if the method is async); resolves a struct/enum method to its monomorphised or erased-fallback `func_map` entry (with sema_shadow instrumentation of mono-hit vs erased-fallback); resolves a namespaced free call `mod.fn()` importer-relative first (via the symbol table) then by shortest-suffix match to avoid order-dependent collisions; handles a struct constructor call (`Struct.new/init`, allocating the instance and threading it as `self`); performs trait/any argument widening and value-optional boxing; routes async functions through `buildDriveAsyncCall`; and finally falls back to a closure-valued field call or a loud "no method or function" error (`error.MethodOrFunctionNotFound`).

- **`fn isVoidExpression(self, expr) bool`** (private). Heuristic: does a call expression return void (so its result must not be stored)? Recognises `console.log`, `router.register`, `bytes.write*`, container mutators (`push/set/forEach/add/insert`), else looks the function up in `functions` and checks its `return_type`.

- **`fn collectClosuresFromBlock(self, block) !void`** (pub) and **`collectClosuresFromStatement`** (private). Recursively walk statements to find closure literals.

- **`fn hasReturnStatement(stmt) bool`** (private, static). Whether a statement subtree contains a `return` (used to decide if an expression-bodied lambda is void).

- **`fn collectClosuresFromExpr(self, expr) !void`** (private). The core closure-lifting pass. For each `.closure`, decides void-ness, synthesises a body block (wrapping an expression body in a return or expr-stmt), computes the lambda return type (querying the typed IR for a trait return), allocates a `__lambda_N` name and an `__env`-prefixed param list, records declared param types, appends a `FunctionInfo` (inheriting the collecting instantiation and its TypeId inst_key), registers the closure key -> lambda name in `closure_lambdas`, and scans the body for captured free variables (`scanStatementCaptures`/`scanExprCaptures`) recording them in `lambda_captures`. Recurses into all sub-expressions.

- **`fn scanStatementCaptures(self, stmt, parent_name, lambda_params, lambda_locals) !void`** (private). Walks a lambda body's statements tracking its own locals and recursing into expressions to find captures.

- **`fn isNamespaceReceiver(self, obj_name, member) bool`** (private). Whether `obj.member` is a namespace/static reference (struct/enum name, `console`/`bytes`/`serde`, or a known `obj_member` function) rather than a captured variable access.

- **`fn scanExprCaptures(self, expr, parent_name, lambda_params, lambda_locals) !void`** (private). The capture detector. An identifier that is not `self`, not a param/local/constant/struct/enum/function, and (crucially, checked FIRST) is a parameter of the enclosing function, is recorded as a capture in the current lambda's `lambda_captures` list. The parent-param check precedes the loose `_name` function-suffix heuristic so a capture whose name collides with a method suffix is not silently dropped.

- **`fn getModulePrefix(self, span) ?[]const u8`** (pub). Derives a dot-free module-prefix identifier from a source file path (strips `src/std/` etc. roots and the extension, converts `/`, `\` and `.` to `_`). Returns null for the main file and a few synthetic files. Owned result. Keeping `.` converted keeps this name in sync with the symbol table's `legacy_mangled` and prevents `getStructBaseName` truncation.

- **`fn hasFunction(self, name) bool`** (pub). Whether `name` is in `func_map` or `functions`.

- **`pub const resolveCalleeName, typeRefToString`** (2915-2917) -- re-exports from `types_mod`.

- **`fn collectFunctions(self, program) !void`** (pub). The central pre-pass that populates `structs`/`enums`/`unions` and appends a `FunctionInfo` for EVERY compilable function: for each struct method, one spec per monomorphised instantiation (`instantiationsOf`), plus a per-`method_inst` generic-method spec (mangled `__arg` suffixes, `instantiation_id` = the mono inst_key) and the base/erased entry unless it can be skipped; likewise for enum methods; and for free functions, the base (unless a generic with no async) plus one spec per `sema_mono.free_fn_insts` entry. It threads `current_instantiation`/`current_instantiation_id` while rendering each spec's return type so type-params resolve correctly. It also calls `expandFreeFnInstsTransitively`. This is what makes monomorphisation concrete before any body is emitted.

- **`fn expandFreeFnInstsTransitively(self, program) !void`** (pub). Fixpoint over `sema_mono.free_fn_insts`: for each generic free-fn instance, walk its body under that instance's type-param binding and register any generic free-fn it calls with concrete args (so `outer<int>` calling `inner<T>(x)` emits `inner<int>`). Additive only; a miss just reproduces the old loud compile error, never a miscompile.

- **`fn discoverGenericCallsInBlock/Stmt/Expr(self, ..., gmap) !bool`** (private). The AST walkers for the fixpoint above; return whether a NEW instance was added.

- **`fn registerGenericFnInst(self, callee_fd, type_args) !bool`** (private). Renders the type args under the current instance's subst; if all concrete, registers the callee instance. Prefers the TypeId-native path (resolve args to concrete TypeIds via `concreteTidForTypeRef`, `sema_mono.noteFreeFnInst`, then record the overlay via `inst_disp.recordFreeFnInst`), falling back to the string-only `noteFreeFnInstStr`. Returns true when a new instance was added.

- **`fn collectStringLiterals(self, program) !void`**, **`collectStringsFromBlock`** (pub) and **`collectStringsFromStatement`/`collectStringsFromExpr`** (private). Walk every function/method/enum-method body collecting distinct string literals into `strings` (deduped by content; slices borrowed from the AST, not owned).

- **`fn collectLocalVarNames(self, list, block) !void`** (pub) with **`collectLocalVarNamesFromStatement`/`FromJsx`** (private). Walk a body collecting every `let` name (including tuple-destructure names and switch-case payload bindings and NSX `{for}`/`{if}` locals) so each gets an alloca in the function prologue. Appends borrowed name slices to `list`.

- **`fn findEnumByVariant(self, variant_name) ?[]const u8`** (pub). Finds the enum that declares a given variant name (first match).

- **`fn payloadEnumBoxWords(self, lt, rt) ?u32`** (pub). If `lt` and `rt` name the SAME payload-carrying enum, returns the number of 8-byte words in its box (tag + max payload) so a fixed-width structural `==` can be emitted; else null. Correct because every variant box is allocated at this uniform size and zero-padded.

- **`fn getEnumTagAndSize(self, enum_name, variant_name, tag_out, max_size_out) !void`** (pub). Computes a variant's tag (its declaration index) and the box's total size (8-byte tag + the widest variant's payload). Errors `EnumNotFound`/`VariantNotFound`. This is what makes every box of one enum the same size (needed by the structural compare above).

- **`fn resolveDiscriminantEnumName(self, discr) ?[]const u8`** (private). The enum name of a switch discriminant, if it is an enum.

- **`fn collectLocalVarTypes(self, map, block) !void`** (pub) with **`collectLocalVarTypesFromStatement`/`FromJsx`** (private). Builds the per-function local-name -> type-string map AND (when `current_local_type_ids` is set) the local-name -> TypeId map. For each `let` it resolves the declared type or the initialiser's type, storing a CONCRETE TypeId (rejecting `unresolved`/`type_param`), and where the typed IR has no concrete id it round-trips the resolved name back to a TypeId via `tidForName` (the string->TypeId bridge). Also types switch-case payload bindings and tuple-destructure elements. This is the authoritative local typing that ownership/value-optional decisions read.

- **`fn compileCoverageIncrement(self, block_id) !void`** (pub). Emits `__kyte_cov_counters[block_id] += 1` against the external coverage-counter global for coverage-instrumented builds.

- **`pub const` re-export block (lines 3834-3933)** -- binds the remaining methods onto `LlvmCompiler` from the sibling files:
  - From `types_mod`: `resolveExpressionTypeName, scopedStructName, scopedTypeName, isCollidingStruct, isOptionalExpr, typeOfExprConcrete, isOwnedExpr, isOwnedTypeId, isOwnedLocal, isValueStructName, isValueStructTid, valueStructHasOwnedFields, returnIsBorrow, isOwnedErrUnionOk, isStringExpr, isFloatExpr, isBoolExpr, isVoidExpr, isAnyExpr, isDecimalExpr, symbolName, tupleElemTraitName, isOwnedErrUnionErr, isOwnedStorageElem, isOwnedStorageElemByName, typeIdForRenderedName, isOwnedErrUnionPayloadByName, isOwnedTupleElemByName, isOwnedDeclaredType, tidForTypeRef, concreteTidForTypeRef, tidForName, ownedByName` -- plus `toLLVMType, llvmForRepr, vecF64x4Type, castToValType, castFromValType, slotTypeForLocal, slotTypeForLocalId, coerceToSlotType` (from the earlier block at 1296-1303).
  - From `statements_mod`: `compileStatement, runErrdefers`.
  - From `expressions_mod`: `compileExpression, compileConstRef, initDefaultContainerFields, consumeTemporary, atomicCell, guardOptionalDeref, registerTemporary, drainTemporaries, buildClosureCall, compileSimdCall, compileIntSimd, compileClmul64, compileMemCall, arrayElemFloatLLVM, arrayBasePtr, buildBareFnBox, fnBoxReturn, fnRefInt, identNamesVariable, widenBranchToTrait, buildValueStructStorage, buildValueStructCopy, buildValueStructCopyInto, compileElemWitness, retainValueStructOwnedFields, buildDriveAsyncCall, buildDriveAsyncHandle, coroPromiseType, coroPromiseSlot, coroPromiseResultSlot, coroPromiseWaiterSlot, buildCoroPromisePtr, awaitedCallHandle, buildAwait, buildAwaitSuspend, awaitSleepMillis, buildGo, buildAwaitFuture, awaitChanRecvArg, buildChanRecv, buildWhenAny, awaitAsyncIoCall, buildAsyncIo, compileAppendToStringBuilder, compileOptionalMethodCall, canonicalizeInt, emitIntDivGuard, emitTrapIf, numToString, numToStringImpl, numToStringT, compileJsxElement, emitJsxInto, jsxAppendVal, jsxAppendLiteral, jsxFlushLiteral, jsxAppendExpr, compileGenericParse, compileDecodeBinaryRow, compileKyteQuery, convertValueToType, resolveReifyTypeName, getFunc`.

- **`pub const compile = declarations_mod.compile;`** (line 3936, module level) -- the codegen entry point the pipeline calls.

**Gotchas / invariants / footguns:**

- **The i64 word truncates addresses if you narrow it.** Every value is `val_type` (i64). Coercing an address to `i32` (e.g. by treating it as `int`) yields a garbage pointer. `buildCallWithCasts` sext/trunc/inttoptr logic and `coerceToSlotType` are the guardrails; do not hand-roll a narrower cast on something that might be a pointer.
- **String and decimal literals carry a NEGATIVE (-1000000000) refcount sentinel** so `kyte_retain`/`kyte_release` are no-ops on them (they early-return on `*rc < 0`). This replaced a `+1e8` count that drifted to a double-free after ~1e8 reuses. Never re-introduce a positive "large" count for immortal shared objects.
- **`getFunctionParamType` returns an OWNED string; `getFunctionParamTypeUncached`, `getModulePrefix`, `closureKey*`, `getTupleElementType`, `unescapeString`, `symbolName` (re-exported) all return owned slices the CALLER must free.** The str cache stores an independent copy and returns fresh dupes on hits.
- **`buildCallWithCasts` fail-closes with `std.process.exit(70)` on an arity mismatch for a fixed-arity function.** This is deliberate: reaching codegen with a bad arg count is a compiler bug, not user error. Do not "fix" a mismatch by silently padding args.
- **`FunctionInfo.params` is empty for constructors on purpose** (synthetic `self`) so the optimiser emit path falls back rather than mis-modelling the argument indices.
- **Value-vs-reference struct lowering is escape-aware.** `fieldStoredInline` delegates to `isValueStructName` (which consults `value_escape_set`), NOT `is_reference` alone. Using `is_reference` would inline a heap-kept struct and corrupt layout (the recorded aes.gcm null-skey crash). Keep the inline decision and `getTypeSize(..., is_field=true)` consistent.
- **Value-optional depth must be peeled exactly.** `valueOptionalInner`/`valoptDepth`/`coerceValoptArg` add or remove exactly one box level per site; a present-holding-0 must stay distinct from absent (0). The `suppress_valopt_unbox` flag exists solely to stop the speculative ident-unbox from stripping a box that must survive into a value-optional parameter.
- **`getModulePrefix` converts `.` to `_`** so the emit name stays in sync with the symbol table's `legacy_mangled` (importer-relative qualified call resolution depends on this) and `getStructBaseName` does not truncate at a stray dot.
- **Namespaced free-call resolution is order-sensitive if done naively.** `compileMethodOrNamespacedCall` resolves importer-relative FIRST (via the symbol table), then by SHORTEST-suffix match, precisely to avoid two packages exporting the same trailing segment silently rebinding to whichever hashmap key iterates first.
- **`deinit` frees `FunctionInfo.param_names` but not `FunctionInfo.name`.** Names are treated as leaked (single-shot process). Do not assume names are freed.

**Cross-references:**

- `declarations.zig` -- owns `compile` (the entry point) and per-declaration lowering; consumes the tables `collectFunctions` builds.
- `expressions.zig` -- the bulk of expression lowering, closures, async/coroutine emission, JSX/NSX, value-struct copies, temporaries; ~60 methods re-exported onto `LlvmCompiler` here.
- `statements.zig` -- `compileStatement`, `runErrdefers`.
- `arc.zig` -- ARC retain/release, destructor synthesis (`getOrCreateDestructor*`), err-union boxing, value-struct drop, type-param substitution; re-exported at lines 494-499 and 595-608.
- `types.zig` (`types_mod`) -- the type-classification and ABI-coercion layer: `toLLVMType`, `castTo/FromValType`, `coerceToSlotType`, `symbolName`, `resolveExpressionTypeName`, `concreteTidForTypeRef`, `isValueStructName`, `tidForName`, `mangleTypeName`, and the large ownership-predicate family. Most decisions in this file bottom out in `types_mod`.
- `lir_emit.zig` -- the optimiser emit path that reads `FunctionInfo.params` (empty => fall back to AST) and `instantiation_id`.
- `coverage.zig` -- `CoverageBlock`/`CoverageRegistry`, driven by `compileCoverageIncrement`.
- sema (`sema_infer.TypedIr`, `sema_types.TypeStore`, `sema_mono`, `sema_shadow`, `inst_disp`) -- the typed-IR and monomorphisation inputs: expression TypeIds, the type store authority on ownership/optionality, the mono instance registries, the live-sema symbol table for importer-relative resolution, and the free-fn overlay recorder.
