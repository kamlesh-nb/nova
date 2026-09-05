# LLD 33: Codegen ARC and Type Layer (`arc.zig` + `types.zig`)

These two files are the memory model and the type-representation truth that the whole LLVM backend rests on. `arc.zig` owns the ARC (automatic reference counting) contract: every heap object carries an 8-byte header at `ptr - 8` (refcount at offset -8, a 32-bit length at offset -4), retain and release go through `kyte_retain(ptr)` and `kyte_release(ptr, dtor)`, and each Kyte type that owns references gets a synthesised, cached destructor (`__destruct_<mangled>`, plus the fixed `__destruct_trait` / `__destruct_closure` and the runtime `kyte_any_box_dtor`). It also builds the boxes for the compound representations: the error-union box `{tag@0, payload@8}`, the value-optional box, the `any` box, and the closure 3-slot box, and it holds the whole-program disposition (owned versus borrowed) decision and the optional ARC-elision peephole. `types.zig` is the layer underneath: it maps every Kyte type name to an LLVM type and to the i64 value-word, decides which structs may be value-lowered (`isValueStructName` and the whole-program `computeValueEscapeSet`), computes field layout and sizes indirectly through the codegen helpers, renders TypeRefs and TypeIds to canonical strings, mangles names, and is the single place the ownership engine (`isOwnedTypeId`) and its many name-keyed shims live.

A note on organisation: nearly every function here is declared as a free function taking `self: *LlvmCompiler` as its first parameter, and is then re-exported as a method on `LlvmCompiler` through `usingnamespace`-style aliasing in `llvm_codegen.zig`. So `self.compileRetain(...)` in other codegen files and `compileRetain(self, ...)` here are the same function. Where a function is described as "method on LlvmCompiler" below, that is the calling convention; the definition lives in one of these two files as a free function.

---

## `src/backend/codegen/arc.zig` (1626 lines)

**Role in the pipeline:** This is where ownership becomes machine code. Once sema has typed every expression and monomorphisation has produced concrete instantiations, codegen walks each function and, at every point a value is bound, stored, returned, or dropped, calls into this file to decide whether a retain or release is needed and to emit it. The destructor synthesis here is lazy and cached by symbol name: the first time a type needs dropping, its `__destruct_*` function is built (recursively building destructors for its owned fields/elements), added to the module, and thereafter found by name. The box constructors (`buildErrUnion`) and the box destructors define the binary ABI of Kyte's compound values, so the exact offsets here are load-bearing.

**Role, second half:** The file also carries the ownership-classification helpers that predate the TypeId engine (`legacyStringOwnership`, `erasedOwnershipDefault`), kept now only as the shadow-gate baseline and the erased-body fallback, plus the disposition decision (`acquisitionDisposition` / `principledDisposition`) that tells a call/bind site whether an argument is a fresh owned temporary or a borrow of existing storage. At the end sit the M-1 value-struct drop helpers and the two opt-in ARC-elision peepholes.

**Key types & data structures:**
- **`pub const Disposition = enum { owned, borrowed }`** -- the two ways a value can arrive at a consuming site. `owned` means it is a fresh +1 the consumer must take responsibility for (release at statement end unless moved); `borrowed` means it aliases storage that outlives the site, so it must NOT be released (and is retained if it is being stored into longer-lived storage).
- There are no other pub structs/enums in this file. `sema_shadow.DispResidue` (used by `dispResidueOf`) is defined in `sema/shadow.zig`, not here.

**Module-level state / constants:**
- **`pub var elide_enabled: bool = false`** -- gate for the borrowed-ARC elision peephole (env `KYTE_ARC_ELIDE`). Off leaves codegen unchanged.
- **`pub var elide_count: usize = 0`** -- running count of elided retain/release pairs, for reporting.
- **`pub var value_structs_enabled: bool = false`** -- master gate for M-1 value-lowered structs. Default false in a bare codegen call; `configureValueStructs` flips it on before real codegen (env `KYTE_VALUE_STRUCTS_OFF` reverts). When false, every struct stays a reference type and this whole subsystem is inert.
- **`pub var value_structs_all: bool = false`** -- env `KYTE_VALUE_STRUCTS_ALL`: value-lower EVERY non-reference struct.
- **`pub var value_type_set: ?std.StringHashMap(void) = null`** -- env `KYTE_VALUE_TYPES=A,B,C`: value-lower only the named base types.
- **`pub var asan_codegen_enabled: bool = false`** -- env `KYTE_ASAN_CODEGEN`: tag emitted functions `sanitize_address` and run LLVM's asan pass so UAF/OOB in Kyte-generated code is caught. Requires an ASAN build so `__asan_*` resolve. Read by `emitModule` in `llvm_codegen.zig`, not used within this file.

**The 8-byte header model (the ABI ground truth):** Every heap object Kyte allocates has an 8-byte header immediately BEFORE the pointer that is passed around. From the object pointer `p`:
- `p - 8` is the refcount (read/written by the runtime's `kyte_retain`/`kyte_release`).
- `p - 4` is a 32-bit length (`i32`), used by the storage destructors below to find the element count: `len_addr = self - 4`, loaded as `i32`, zero-extended to the word.
Storage buffers are laid out as 8-byte element slots (`n_slots = len / 8`); the inline value-struct variant divides `len` by the element's byte width instead.

**Functions (source order):**

- **`pub fn enumIsTaggedUnion(self, enum_name: []const u8) -> bool`** -- true if any variant of the named enum carries a payload (`type_name != null or fields != null`). A plain C-style enum is not a tagged union and needs no destructor. Returns false if the enum is unknown. No IR, no allocation.

- **`pub fn erasedOwnershipDefault(self, type_name: []const u8) -> bool`** -- the structural default for a value with no recoverable concrete TypeId, reached only from `types.ownedByName` after the primitive short-circuit and after `tidForName` failed, i.e. a bare type parameter or an instantiation-free generic in an ERASED body that mono dead-strips. If the name is an untypeable placeholder it prints a loud compiler-error banner and `std.process.exit(70)` (a live value reaching ARC untyped is a compiler bug). A bare single uppercase letter is treated as a type parameter (holds no owned reference) and returns false; everything else returns true (owned). `self` is unused.

- **`pub fn legacyStringOwnership(self, type_name: []const u8) -> bool`** -- the LEGACY name-matched ownership classifier. As of the L1 string->TypeId migration it is NO LONGER a codegen decider; it survives only as the shadow gate's comparison baseline (`tdShadowDiff` / `isOwnedRenderedFallback`) so the shadow diff keeps proving the TypeId engine agrees with the historical rule. Do not call from a codegen path. Logic: bumps shadow counters if reporting; a bare single-uppercase name that is not a known struct/enum/union/trait is a type parameter (not owned); `any` is decided owned BEFORE the primitive check (it is a heap `kyte_any_box`, which `isPrimitiveTypeName` misleadingly lumps with value primitives); a primitive is not owned; a known enum defers to `enumIsTaggedUnion`; an untypeable placeholder exits 70; otherwise owned.

- **`pub fn isUntypeablePlaceholder(name: []const u8) -> bool`** -- true for the whole-string sentinels sema emits when it could not type something: empty, `unresolved`, `<unresolved>`, `<tuple>`, `<array>`, `<fn>`. Note it matches the WHOLE string, so `List<string>` and a real function type do not match (covered by the module test at the bottom).

- **`pub fn compileCallArgument(self, arg: ast.Expression) -> !LLVMValueRef`** -- compiles one call argument and, if the argument yields a value-optional box and the call site did not suppress it, unboxes it to its raw value for the call ABI. Saves and restores `self.suppress_valopt_unbox` around the sub-evaluation because `compileExpression` clobbers that flag when the argument itself contains a nested call (the C10 nested-valopt-arg bug: a `.call` argument must see the suppress value the caller set for THIS argument, not one a sub-call left behind). Unboxing goes through `buildValoptUnbox(coerceToSlotType(val, val_type))`. IR: an unbox load when it fires. No heap allocation owned here.

- **`fn dispResidueOf(store, tid) -> sema_shadow.DispResidue`** (private) -- classifies a disposition disagreement for the shadow report: `.type_param`, `.enum_`, unwraps `.optional` recursively, and for anything else returns `.not_owned` when the type is not owned (a disagreement there is memory-safe, no retain/release happens either way) or `.other` when it is owned (a genuine potential bug).

- **`pub fn acquisitionDisposition(self, expr) -> Disposition`** -- THE disposition decision for a value being acquired. Computes `principledDisposition` (the structural rule), then overrides to `.owned` if the sema pass says the expr is owned (`ir.ownedOfInst(id, inst)` under the current instantiation, else `ir.ownedOf(expr)`). So sema can promote a borrow to owned but the principled rule stands otherwise. When `sema_shadow.report_enabled`, records agree/disagree counters bucketed by `dispResidueOf`. Returns the final disposition. No IR.

- **`pub fn namesExistingOwner(kind: ast.ExprKind) -> bool`** -- true for `.ident`, `.field_access`, `.index`: expression kinds that NAME storage that already has an owner (so reading them is a borrow, not a fresh value).

- **`fn principledDisposition(self, expr) -> Disposition`** (private) -- the structural owned/borrowed rule. An enum-variant constructor (`Enum.Variant`) is NOT treated as naming an existing owner even though it is a `.field_access`. Otherwise anything that `namesExistingOwner` returns borrowed. Then per kind: `binary` with `.assign` op is borrowed; a `literal` that is not `decimal`/`array` is borrowed (those two allocate); `try_expr`/`cast`/`go_expr` are borrowed; `await_expr` falls through to the owned-type check (an awaited result is a FRESH owned value exactly like a call, classifying it borrowed once leaked an inline `f(await g())`); `optional_chaining` is owned iff it yields a valopt box, else borrowed; `cast` stays deliberately borrowed (ptr-as-string ownership is genuinely ambiguous, so the contract is: bind to transfer ownership, inline stays a borrow for manual-memory interop). Finally, if the expr is not owned by type it is borrowed, else owned.

- **`pub fn takeOwnedElement(self, elem_kind, val) -> !void`** -- when moving a value into a container that takes ownership: if the source names an existing owner, emit a `compileRetain` (copy); otherwise it is already a fresh temporary, so `consumeTemporary` (hand ownership over without an extra retain).

- **`pub fn compileRetain(self, ptr) -> !void`** -- emits a call to `kyte_retain(ptr)`. Lazily declares the runtime function `void kyte_retain(word)` and caches it in `func_map`. No destructor argument; retain never needs one.

- **`pub fn compileRelease(self, ptr, destructor_fn_opt: ?LLVMValueRef) -> !void`** -- emits `kyte_release(ptr, dtor)`. Lazily declares `void kyte_release(word, void*)`. The destructor, if present, is bitcast to `void*`; if absent a null `void*` is passed (the runtime then just frees the box after decrementing to zero). This is the universal drop primitive: the runtime decrements the header refcount, and on reaching zero calls `dtor(ptr)` (to release owned fields) then frees `ptr - 8`.

- **`fn destructorName(allocator, type_name) -> ![]u8`** (private) -- builds the symbol `__destruct_<mangled>` where `<mangled>` comes from `mangleTypeName`. Caller owns and frees the returned slice.

- **`pub fn substituteFieldType(self, inst_name, field_type) -> ![]const u8`** -- string-level generic substitution: given an instantiation name like `Box<int>` and a field type spelling that mentions the struct's type parameters, replaces each type-param token with the concrete argument. Parses the `<...>` argument list of `inst_name` respecting nesting depth and commas, matches it against the struct decl's `type_params`, then token-substitutes in `field_type` (only at identifier boundaries via `isIdentCh`). Returns `field_type` unchanged (borrowed) when there is no `<>`, the base is unknown, the struct is non-generic, or the arg count mismatches; otherwise returns a freshly allocated string the caller owns.

- **`pub fn substTypeParams(self, type_str) -> ![]const u8`** -- the struct-T + method-U name resolver. First applies `substituteFieldType` using `current_instantiation` (string path, still load-bearing for name rendering where `current_instantiation` is set but `current_instantiation_id` is not), then applies `substMethodParams` (now TypeId-native, in `types.zig`). No type DECISION rides on this; it is for NAME rendering. Returns an owned string.

- **`fn isIdentCh(c: u8) -> bool`** (private) -- alphanumeric or `_`. The identifier-token boundary test for `substituteFieldType`.

- **`pub fn isFunctionType(type_name: []const u8) -> bool`** -- true if the type spelling contains a top-level `->` or `=>` arrow (a `>` preceded by `=` or `-` at bracket depth 0). Distinguishes a closure/function type from a generic `<...>`. Used to route to the closure destructor.

- **`fn storageElem(type_name) -> ?[]const u8`** (private) -- if the name is `Storage<X>`, returns the inner `X` (a borrow into the input); else null.

- **`fn buildInlineValueStructStorageLoop(self, dest_fn, elem) -> !void`** (private) -- M-1: destructor loop for a `Storage` whose element is an INLINE value-struct. Each element lives in the buffer at `elem_width` bytes (from `getTypeSize`, floored at 1). Loads the buffer length from `self - 4` (i32, zero-extended), computes `n_slots = len / width`, then loops calling the element's destructor DIRECTLY on the slot ADDRESS (`self + i*width`) to drop that element's owned fields. Never `kyte_release` on a slot: the slot is inline bytes, not a heap pointer. Emits the standard cond/body/exit basic-block loop.

- **`fn buildStorageDestructor(self, dest_fn, elem) -> !void`** (private) -- the name-keyed storage destructor dispatcher. If the element is a value-struct: build the inline loop only when it has owned fields, else nothing (scalar-only inline element needs no drop). Otherwise the element is a heap pointer: it should be freed if it is an owned storage element OR a value-optional (a valopt element is a heap box the container owns and must free on drop, even though its payload is a value). Delegates to `buildStorageDestructorLoop`.

- **`fn buildStorageDestructorByTypeId(self, dest_fn, elem_tid) -> !void`** (private) -- the TypeId equivalent. `should_free` is `isOwnedTypeId(elem)` OR the element is a value-optional (`valueOptionalInner != null`). A `List<int | undefined>` / `Map<K, int|undefined>` would leak its present-value boxes without this. `kyte_release` with the element's destructor (null for a plain valopt) frees the box; an `undefined` element is 0 and released as a no-op.

- **`fn buildStorageDestructorLoop(self, dest_fn, owned, elem_dest) -> !void`** (private) -- the shared 8-byte-slot release loop. If not owned, returns immediately (no drop). Otherwise: load `len` from `self - 4` (i32 zero-extended), `n_slots = len / 8`, then for each slot load the word at `self + i*8`, cast to a pointer-sized value, and `compileRelease(elem_val, elem_dest)`. Standard cond/body/exit blocks.

- **`fn getOrCreateStorageDestructorByTypeId(self, t) -> !?LLVMValueRef`** (private) -- synthesise-or-find a `__destruct_<Storage...>` from a storage TypeId. Renders the legacy name for the symbol, checks the module for an existing function, else creates `void __destruct(word)`, positions the builder at a fresh entry block (saving/restoring the current insert point), builds the by-TypeId storage loop, and returns void. Emits a shadow diff if reporting. Returns null if there is no type store or `t` is not a storage type.

- **`pub fn getOrCreateTraitDestructor(self) -> !LLVMValueRef`** -- synthesise-or-find the single `__destruct_trait`. A trait object is a FAT POINTER; this destructor takes the fat pointer address and, from it: loads the struct pointer at `[fat + 0]`, loads the vtable pointer at `[fat + 8]`, loads the struct's own destructor from vtable slot 0 (`[vtable + 0]`), and calls `kyte_release(struct_ptr, struct_dtor)`. So dropping a trait object drops the underlying concrete struct via its vtable-recorded destructor. Layout: fat pointer = `{struct_ptr@0, vtable@8}`, vtable slot 0 = destructor.

- **`fn getOrCreateClosureDestructor(self) -> !LLVMValueRef`** (private) -- synthesise-or-find the single `__destruct_closure`. A closure is a 3-SLOT box: `{fn_ptr@0, env@8, cleanup@16}`. The destructor loads `env` at `[box+8]` and `cleanup` at `[box+16]`; if `cleanup != 0` it calls `cleanup(env)` (a generated per-closure environment cleanup, `__clocleanup_*`, that releases captured owned values), then unconditionally `kyte_bytes_free(env)` to free the captured-environment buffer. Note it frees the ENV, not the box itself (the box pointer is what `kyte_release` will free after this destructor returns). Lazily declares `kyte_bytes_free`.

- **`pub fn getOrCreateDestructorByTypeId(self, t) -> !?LLVMValueRef`** -- the TypeId-first destructor dispatcher. Switches on the type-store kind: `.trait_` -> trait destructor; `.func` -> closure destructor; `.prim`/`.ptr`/`.unresolved` -> null (nothing to drop); `.tuple`/`.error_union`/`.struct_`/`.storage` -> the respective by-TypeId synthesiser; `.optional` -> null if it is a value-optional (the box is freed with a null dtor), else render the name and defer to `getOrCreateDestructor`; anything else -> render the name and defer to the string synthesiser. Returns null when there is no type store.

- **`pub fn getOrCreateDestructorPreferId(self, name_str, tid: ?TypeId) -> !?LLVMValueRef`** -- prefers the TypeId path but guards against a name/id mismatch. If a resolved `tid` is given, renders its name, mangles both the id-name and the passed `name_str`, and if the two mangled destructor symbols MATCH uses the by-TypeId synthesiser (recording a `phaseA_flip`); if they diverge it trusts the string name (`phaseA_split`) to avoid emitting a destructor for the wrong type. Falls back to the string synthesiser when there is no usable id (`phaseA_no_id`). This is the safe bridge used by the local-drop paths.

- **`pub fn getOrCreateDestructor(self, type_name: []const u8) -> !?LLVMValueRef`** -- the string-keyed destructor synthesiser, and the recursive workhorse. Order of routing: `any` -> the runtime `kyte_any_box_dtor` (declared+cached; the runtime releases the payload via the stored dtor before freeing the box); a trait name -> trait destructor; a function type -> closure destructor; a tuple type -> tuple destructor; `ErrUnion(...)` -> error-union destructor; a known enum base -> enum destructor. If it is neither a `Storage<>` nor a known struct, returns null (nothing to drop). Otherwise: build `__destruct_<mangled>` (or return the cached one), then, with `current_instantiation` set to `type_name` and `current_instantiation_id` nulled (isolating name-mangling from any enclosing generic instance), position at a fresh entry. First, if a `delete`/`_delete` method exists with arity 1, call it on the value (user finaliser). Then either build the storage destructor (and return), or, for a struct, iterate its fields: for each field whose (substituted) type is owned, compute the field offset, load the field, cast to the value word, recursively get the field's destructor, and `compileRelease`. Return void. Recursion is bounded by the module-name cache (a type's destructor is created once).

- **`fn getOrCreateStructDestructorByTypeId(self, t) -> !?LLVMValueRef`** (private) -- the by-TypeId struct destructor. Recovers the struct decl from the live sema symbol table (falling back to the string synthesiser if sema is absent or the symbol is not a struct). Emits a shadow field-diff if reporting. Builds/finds `__destruct_<name>`, isolates instantiation as above, calls any `delete`/`_delete` method, then for each declared field lowers the field type to a CONCRETE TypeId via a fresh `lower.Lowerer` with the struct's type-param scope plus `subst.substitute` under the instance args. Ownership is decided by `isOwnedTypeId(concrete)` when it resolves, else by the string path. For each owned field it loads at the field offset, casts, gets the field destructor by-id (or by-string), and releases. This is the accurate path; the string synthesiser is the fallback.

- **`fn getOrCreateErrUnionDestructorByTypeId(self, t) -> !?LLVMValueRef`** (private) -- the by-TypeId error-union destructor. THE ERROR-UNION BOX LAYOUT: `{tag@0, payload@8}`, both word-sized, tag 0 = ok, tag 1 = err. Loads tag and payload, branches on `tag == 1` into an err block and an ok block: in each, if that arm's type is owned (`isOwnedTypeId(eu.err|eu.ok)`), get its destructor and `compileRelease(payload, d)`; both fall through to a done block, then return void. Emits a shadow arm-diff if reporting.

- **`fn getOrCreateErrUnionDestructor(self, type_name) -> !?LLVMValueRef`** (private) -- the string-keyed error-union destructor, identical box layout `{tag@0, payload@8}`. Parses `type_name` into ok/err parts via `errUnionParts` (owns and frees both), and decides each arm's ownership via `isOwnedErrUnionPayloadByName`. Same tag-branch shape as the by-id version.

- **`fn getOrCreateEnumDestructor(self, enum_name) -> !?LLVMValueRef`** (private) -- the tagged-union (enum) destructor. Returns null if the enum is not a tagged union. THE ENUM BOX LAYOUT: `{tag@0, payload slots from offset 8, each 8 bytes}`. Loads the tag, then for each payload-carrying variant builds an `if tag == idx` chain: for a single-typed variant releases the one payload slot at offset 8; for a struct-form variant releases each field slot at `8 + fidx*8`. Uses `releaseEnumPayloadSlot`. All arms branch to a shared done block.

- **`fn releaseEnumPayloadSlot(self, box, offset, tref) -> !void`** (private) -- release one enum payload slot: if the slot's type is not owned, nothing; else load the word at `box + offset`, get its destructor, and `compileRelease`.

- **`pub fn isTupleType(type_name: []const u8) -> bool`** -- true if the spelling is parenthesised (`(...)`) and contains no `=>` (which would make it a function type). The syntactic tuple test.

- **`fn getOrCreateTupleDestructorByTypeId(self, t) -> !?LLVMValueRef`** (private) -- by-TypeId tuple destructor. THE TUPLE LAYOUT: elements packed at 8-byte offsets, element `i` at `box + i*8`. For each owned element (`isOwnedTypeId`), load the word, get its destructor by id, and release. Emits a shadow elem-diff if reporting.

- **`fn diffStructFields(self, t) -> void`** (private) -- shadow-gate cross-check: for each field of a struct TypeId, compares the by-TypeId ownership answer against the string-path answer and bumps `struct_field_agree`/`struct_field_disagree`, recording the last disagreement. Report-only; no IR.

- **`fn diffErrUnionArms(self, t) -> void`** (private) -- shadow cross-check for the two error-union arms (ownership answer AND rendered name must match). Bumps `erru_elem_agree`/`erru_elem_disagree`.

- **`fn diffStorageElem(self, t) -> void`** (private) -- shadow cross-check for a storage element (ownership + rendered name). Bumps `storage_elem_agree`/`storage_elem_disagree`.

- **`fn diffTupleElems(self, t) -> void`** (private) -- shadow cross-check for tuple elements (count, then per-element ownership + name). Bumps `tuple_elem_agree`/`tuple_elem_disagree`.

- **`fn getOrCreateTupleDestructor(self, type_name) -> !?LLVMValueRef`** (private) -- the string-keyed tuple destructor. Iterates elements via `getTupleElementType` (owned+freed per element) up to `countTupleElements`; for each owned element (`isOwnedTupleElemByName`) load at `i*8`, get its destructor, release.

- **`pub fn countTupleElements(type_name: []const u8) -> usize`** -- count top-level comma-separated elements inside the outer parens, respecting `<`/`(` nesting depth. Empty `()` -> 0.

- **`pub fn errUnionParts(self, name) -> ?struct { ok, err }`** -- split `ErrUnion(OK, ERR)` at the top-level comma (depth-aware). Both returned slices are freshly allocated and OWNED BY THE CALLER (every caller `defer`s two frees). Returns null if the name is not an error-union or has no top-level comma.

- **`pub fn buildErrUnion(self, val, is_err: bool, union_name) -> !LLVMValueRef`** -- CONSTRUCT an error-union box. Allocates `2*8` bytes via `compileAlloc` (a header'd heap object). If the chosen payload arm is owned, retains `val` first (the box takes a +1). Stores the tag (`1` for err, `0` for ok) at offset 0, and the slot-coerced payload at offset 8. Returns the box pointer. This defines the producer side of the `{tag@0, payload@8}` ABI that the error-union destructors above consume.

- **`pub fn dropValueStruct(self, struct_addr, type_name, tid: ?TypeId) -> !void`** -- M-1: drop a VALUE struct in place. Gets its destructor via `getOrCreateDestructorPreferId` and calls it DIRECTLY on `struct_addr` to release owned fields, but never `kyte_release`/free (inline stack storage has no header). No destructor -> nothing to do.

- **`pub fn releaseLocalByName(self, name, type_name) -> !void`** -- release one named local. Loads the local's alloca. If it is a value-struct, `dropValueStruct` on the loaded value; otherwise `getOrCreateDestructorPreferId` + `compileRelease`. Either way stores 0 back into the alloca (so a later drop is a no-op). The tid is recovered from `current_local_type_ids` for the prefer-id path.

- **`pub fn releaseLocalVariables(self) -> !void`** -- the function-exit sweep: iterate `current_local_types` and release every owned local. Skips `self` inside `_delete`/`_init`/`_new` methods (the receiver is not owned there), skips parameters (caller-owned), and skips captured globals (`captured_globals` keyed `func_var`). For each remaining owned local, load its alloca and `compileRelease` with the prefer-id destructor. This is where most drops are emitted at scope end.

- **`fn callTargetName(inst) -> ?[]const u8`** (private) -- for a call instruction, return the callee's symbol name (the callee is the LAST operand). Null if not a call or unnamed.

- **`fn isNamedCall(inst, want) -> bool`** (private) -- true if `inst` is a call to a function named `want`.

- **`fn tracesBorrowedParamField(sv, param_slots) -> bool`** (private) -- pattern-matches the exact IR shape `ptrtoint(load(inttoptr(add(load(param_slot), CONST))))`: a value read out of a borrowed parameter's field. Walks the operand chain opcode by opcode and checks the base slot is one of the known param slots.

- **`fn valueIsRetained(sv) -> ?LLVMValueRef`** (private) -- scan the uses of `sv` for a `kyte_retain(sv)` call; return that call or null.

- **`pub fn elideBorrowedArc(self, module) -> void`** -- the elision entry point (no-op unless `elide_enabled`). For every function in the module runs both peepholes: `elideBorrowedArcInFn` then `elideRedundantPairsInFn`.

- **`fn instUsesValue(inst, v) -> bool`** (private) -- true if any operand of `inst` is `v`.

- **`fn elideRedundantPairsInFn(self, fnv) -> void`** (private) -- M-5 peephole: within a single basic block, if `kyte_retain(v)` is followed (with NO intervening instruction that references `v`) by `kyte_release(v, ...)`, both are net-zero and are erased. Conservative: the FIRST use of `v` after the retain must be the matching release; any other use stops it. Collects the block's instructions, scans forward, records pairs, then erases them all at the end (and bumps `elide_count`).

- **`fn elideBorrowedArcInFn(self, fnv) -> void`** (private) -- the borrowed-field elision. Step 1: find alloca slots that hold a parameter (`store %param, %alloca`). Step 2: for each other alloca, prove it only ever holds a value traced from a borrowed param field (`tracesBorrowedParamField` + `valueIsRetained`), and that every load of it feeds only borrow uses (icmp, `kyte_release`, or a call ARGUMENT position, never the callee, never a return/store-as-value/ptrtoint/GEP). If the slot has exactly one owned store, a retain, and only such uses, the retain and its paired releases are erased (the param is caller-owned and alive across the whole call, so the defensive retain/release is net-zero). Any shape it cannot prove safe is left untouched.

- **`test "isUntypeablePlaceholder: ..."`** -- unit test asserting the whole-string placeholders match and real/function types do not.

**Gotchas / invariants (arc.zig):**
- Box offsets are the ABI. Error-union = `{tag@0, payload@8}`, tag 1 = err. Enum tagged-union = `{tag@0, payload slots at 8, 16, ... each 8 bytes}`. Closure = `{fn_ptr@0, env@8, cleanup@16}` (the destructor frees ENV, not the box). Trait fat pointer = `{struct_ptr@0, vtable@8}`, vtable slot 0 = destructor. Header = refcount@-8, len(i32)@-4.
- Destructors are cached by symbol name in the LLVM module; `getOrCreateDestructor*` returns the existing function on a second call, which is what bounds the recursion through owned fields.
- Value-struct slots hold INLINE bytes with no header. Never `kyte_release` on them; call the destructor directly (`dropValueStruct` / the inline storage loop). Releasing one would read a refcount off the stack and free a stack address.
- `errUnionParts` returns owned slices; forgetting the two frees leaks. `substituteFieldType` returns the input borrowed when it cannot substitute, but an owned slice when it does, so callers must treat the result as owned uniformly (they do).
- `legacyStringOwnership` and `erasedOwnershipDefault` are NOT codegen deciders any more (shadow baseline + erased fallback only). Real ownership is `isOwnedTypeId` in `types.zig`.
- The disposition of `await` and `cast` is subtle and deliberately asymmetric (await = owned/fresh, cast = borrowed for manual-memory interop); do not "simplify" them.

---

## `src/backend/codegen/types.zig` (1507 lines)

**Role in the pipeline:** This is the type-representation truth. Codegen never invents an LLVM type or a value-word encoding on its own; it asks here. The file answers three families of question: (1) what LLVM type does this Kyte type have, and how does it round-trip through the i64 value-word (`cgPrim`, `CgRepr`, `llvmForRepr`, `toLLVMType`, `slotTypeForLocal*`, `coerceToSlotType`, `castToValType`, `castFromValType`); (2) is this value OWNED (needs ARC), routed through the single engine `isOwnedTypeId` and its many name-keyed and expr-keyed shims; (3) may this struct be VALUE-lowered, computed once by the whole-program escape analysis `computeValueEscapeSet` and consulted by `isValueStructName`. It also owns name mangling, TypeRef/TypeId rendering, and the callee-name resolver.

**Role, second half:** The ownership shims exist because the codebase migrated from a string-keyed ownership engine to a TypeId one (the L1 / SE-C migration). Most `isOwned*ByName` functions first try to recover a real TypeId (via the rendered-name index `typeIdForRenderedName` or the sema lowerer) and defer to `isOwnedTypeId`, falling back to `ownedByName` (which itself tries `tidForName` then the erased default) only for names with no concrete type. The `substMethodParams` / `concreteTidForTypeRef` / `substViaOverlay` cluster is the TypeId-native replacement for the old `current_method_subst` string bindings, resolving generic type parameters through the sema overlay's `tpResolve`.

**Key types & data structures:**
- **`pub const CgRepr = enum { i1, i8, i16, i32, word, i64, f32, f64 }`** -- the codegen representation of a primitive. `i1` = bool, `i8`/`i16`/`i32`/`i64` are the sized integers, `word` is the 64-bit machine word used for `ptr` (kept distinct from `i64` so a pointer slot can stay `ptr`-typed for provenance), `f32`/`f64` are the floats. `reprBitWidth` maps these to 1/8/16/32/64/64/32/64.
- **`pub const CgPrim = struct { repr: CgRepr, signed: bool }`** -- a primitive's repr plus signedness (drives sext vs zext when widening into the value-word).
- **The `cgPrim` table (exact):** `bool`->(i1, unsigned); `byte`/`ubyte`/`u8`->(i8, unsigned); `sbyte`/`i8`->(i8, signed); `short`/`i16`->(i16, signed); `ushort`/`u16`->(i16, unsigned); `int`/`i32`->(i32, signed); `uint`/`u32`->(i32, unsigned); `long`/`i64`->(i64, signed); `ulong`/`u64`->(i64, unsigned); `float`/`f32`->(f32, signed); `double`/`f64`->(f64, signed); `ptr`->(word, unsigned). Note `int` is i32 (32-bit) and `long` is i64 (64-bit), the repeatedly-bitten gotcha: heap addresses must be `long`/`ptr`, never `int`.
- **The `canonicalPrimAlias` table** (used by mangling): `int`->`i32`, `uint`->`u32`, `long`->`i64`, `ulong`->`u64`, `short`->`i16`, `ushort`->`u16`, `byte`->`i8`, `ubyte`->`u8`, `float`->`f32`, `double`->`f64`. So a mangled symbol always uses the canonical spelling and `List<int>` and `List<i32>` cannot produce two different symbols.
- **`value_escape_set: ?std.StringHashMap(void)`** (a field ON `LlvmCompiler`, populated here) -- the set of struct base names that MUST stay on the heap (escape), computed by `computeValueEscapeSet`. Keys are owned dupes of base names.

**Module-level state / constants:** none of its own; it reaches into `arc_mod.value_structs_enabled` / `value_structs_all` / `value_type_set` for the value-struct gate, and into `sema_shadow` globals for the shadow report. `CgRepr`/`CgPrim` and the tables above are the only type declarations.

**Functions (source order):**

- **`pub fn getStructBaseName(name: []const u8) -> []const u8`** -- strip any module qualifier (last `.`) and any generic args (first `<`), returning the bare struct base name. A borrow into the input.

- **`fn canonicalPrimAlias(tok) -> ?[]const u8`** (private) -- the alias table above; null for a non-alias token.

- **`fn isTokenChar(c) -> bool`** (private) -- `[A-Za-z0-9_]`. The token boundary for mangling.

- **`pub fn mangleTypeName(allocator, type_name) -> ![]u8`** -- turn a type spelling into a linker-safe symbol. Identifier tokens are canonicalised (via `canonicalPrimAlias`) and copied; `<`/`>`/`,`/space collapse to a single `_` separator (no doubling); `(`->`_lp`, `)`->`_rp`, `-`->`_da`, `=`->`_eq`, `|`->`_or` (so `int | undefined` mangles distinctly from `int`, preventing `List<int|undefined>` colliding with `List<int>`); any trailing `_` is popped. Returns an owned slice. Covered by the module tests (`List<string>`->`List_string`, `Map<string, int>`->`Map_string_int`, `List<List<int>>`->`List_List_int`, and the non-collision assertions).

- **`pub fn qualifySelfType(self, type_name) -> []const u8`** -- inside a generic instantiation, replace a bare `Self`-style base name with the full instantiation name (`current_instantiation`) so a method body referring to its own struct gets the concrete args. Returns the input unchanged when there is no active instantiation, the name already has `<>`, or it is not the instantiation's base.

- **`pub fn methodSymbol(self, owner, method) -> ![]const u8`** -- build `<mangled-owner>_<method>`. Owned slice.

- **`pub fn instantiationsOf(self, s: ast.StructDecl) -> ![]const ?[]const u8`** -- list the monomorphised instantiations of a struct: always `[null]` (the base/erased form) plus, for a generic struct, every live instantiation whose base name matches (from `sema_mono.live_instantiations`). Owned slice.

- **`pub fn isStructType(self, type_name) -> bool`** -- true if the base name is a known struct, union, or enum.

- **`pub fn reprBitWidth(repr: CgRepr) -> u32`** -- the bit width table above.

- **`pub fn cgPrim(name) -> ?CgPrim`** -- look up a primitive name in the table; null if not a primitive. THE canonical primitive classifier.

- **`pub fn valueOptionalName(name) -> bool`** -- true if the spelling is a BOXED value-optional: exactly two arms, one `undefined` and the other a value primitive (excluding `any` and `void`). `string | undefined` is a plain pointer-optional (0 = none), NOT boxed, so it is excluded. This is the syntactic side of the valopt-box decision.

- **`pub fn isPrimitiveTypeName(type_name) -> bool`** -- a primitive (via `cgPrim`), or `void`, or `f64x4`, or an integer SIMD vector (`simdVecName`), or `any`. Note `any` is included here for the valopt value-arm check even though `any` is heap-owned; the ownership deciders special-case `any` to owned BEFORE this test.

- **`pub fn simdVecName(type_name) -> ?struct { elem, lanes }`** -- the LLVM vector shape for `u8x16`->(8,16), `u32x4`->(32,4), `u64x2`->(64,2); null otherwise. One place so builtins, slot picker, and ownership agree.

- **`pub fn llvmForRepr(self, repr) -> LLVMTypeRef`** -- map a `CgRepr` to the concrete LLVM type: i1/i8/i16 (i16 via `LLVMInt16Type`), i32, `word`->`val_type` (the i64 value-word), i64, f32 (`LLVMFloatType`), f64 (`LLVMDoubleType`).

- **`pub fn toLLVMType(self, type_ref: ast.TypeRef) -> LLVMTypeRef`** -- for an `.ident` that is a primitive, its repr's LLVM type; for any other ident or any non-ident TypeRef, `ptr_type`. So every non-primitive is a pointer at the LLVM level.

- **`pub fn slotTypeForLocal(self, type_name) -> LLVMTypeRef`** -- thin wrapper for `slotTypeForLocalId(type_name, null)`.

- **`pub fn slotTypeForLocalId(self, type_name, type_id) -> LLVMTypeRef`** -- pick the alloca slot type for a local. A value-optional TypeId -> the i64 word (the box pointer lives in a word). A fixed-array TypeId -> `ptr_type` (arrays stay pointers so LLVM keeps provenance and can vectorise/hoist). By name: `f64x4` -> `<4 x double>`; an integer SIMD name -> its vector; a `T[N]` array name -> `ptr_type`; a float/double primitive name -> `LLVMDoubleType` (floats are stored widened to double in the slot). Everything else -> the i64 word. This is where the "everything is an i64 word except arrays, SIMD, and floats" storage convention is decided.

- **`pub fn vecF64x4Type(self) -> LLVMTypeRef`** -- `<4 x double>`. One place so builtins and the slot picker agree. `self` unused.

- **`pub fn coerceToSlotType(self, val, slot_ty) -> LLVMValueRef`** -- bit/representation-convert `val` to the slot type at a store. Handles the four seams: int<->double (bitcast, for float slots), ptr<->i64 word (inttoptr / ptrtoint, for array slots versus the word). Returns `val` unchanged if already the slot type or if no rule matches.

- **`pub fn castToValType(self, val, type_ref) -> LLVMValueRef`** -- convert an arbitrary LLVM value INTO the i64 value-word. A pointer -> ptrtoint; a double -> bitcast; a float -> fpext to double then bitcast; a narrower integer -> zext or sext (signedness from `cgPrim(type_ref.ident)`, defaulting to signed); a wider integer -> trunc. This is the universal "put it in the word" coercion used when storing into 8-byte slots and boxes.

- **`pub fn castFromValType(self, val, target_type) -> LLVMValueRef`** -- the inverse: convert a value (usually the i64 word) to `target_type`. Pointer target -> inttoptr; double target -> bitcast; float target -> bitcast-to-double then fptrunc; integer target -> trunc/sext by width, or, for a 64-bit int target from a double/float, bitcast (float bits) to recover the word.

- **`pub fn typeRefToString(self, type_ref) -> ![]const u8`** -- render a TypeRef to the canonical codegen spelling. An `.ident` goes through `substTypeParams` (resolving type params). A VALUE-optional (`.optional` whose inner is a primitive) renders as `"<inner> | undefined"` distinctly (rendering it as just the inner once collapsed an error-union ok arm and caused a SEGV, the F1 bug); a heap-optional renders as its inner. `.error_union` -> `ErrUnion(ok,err)`; `.tuple` -> `(a,b,...)`; `.generic` -> `Name<p, ...>` (or bare name if no params); `.fixed_array` -> `elem[N]`; `.func` -> `(p, ...) -> ret`. Composite results are owned slices; the `.ident`/simple cases may be owned via `substTypeParams`.

- **`pub fn isOptionalExpr(self, expr_ptr) -> bool`** -- true if the expr's TypeId is `.optional`. Needs typed IR and a type store.

- **`pub fn isOwnedExpr(self, expr_ptr) -> bool`** -- the expression-level ownership decision. A value-optional expr is owned iff it actually yields a box (`exprYieldsValoptBox`). Otherwise resolves the expr's TypeId, RESOLVING a bare type-parameter through the current instantiation (`tpResolve`) so ownership is that of the concrete type (Swift's +1 result rule: a returned type-param value must be retained-on-return or the caller over-releases). If the type is still a bare type-param in an ERASED body (`current_instantiation_id == null`), it carries no static ownership -> not owned (the concrete instantiations decide at their own sites). Falls back to `isOwnedLocal` for an ident with a known local type when the TypeId is missing/unresolved.

- **`fn tdShadowDiff(self, t) -> void`** (private) -- shadow-gate cross-check of the TypeId ownership engine against the legacy string engine. For a `.type_param`, resolves through the instantiation and compares the keystone answer to the string fallback (`td_keystone_resolves`/`disagree`, or `td_blocked_*` when it cannot resolve). For a concrete type, compares `st.isOwned(t)` to `legacyStringOwnership(renderLegacy(t))` (`td_agree`/`td_disagree`). Report-only.

- **`fn isScalarFieldTypeName(name) -> bool`** (private) -- true for the trivially-copyable scalar primitive names (int/long/short/byte/bool/float/double/char and the sized/word/usize/isize spellings). A struct whose fields are ALL such scalars (or `string`) is value-lowerable; anything else forces the heap. Note: the comment block above it about "confirmed borrow" is misplaced (it describes `returnIsBorrow`), but this function is purely the scalar-name test.

- **`fn calleeNamesStruct(self, callee) -> bool`** (private) -- true if the callee is an ident naming a known struct (a constructor call). Used to tell a constructor (materialises a fresh value) from a plain call (returns its own safe value).

- **`pub fn returnIsBorrow(self, expr) -> bool`** -- is a returned expression a CONFIRMED BORROW (its value outlives this frame, safe to return without copying)? True for reads/literals/arithmetic/casts/ranges (`.literal`, `.binary`, `.unary`, `.field_access`, `.index`, `.cast`, `.range`) and for a `.call`/`.generic_call` whose callee is NOT a struct constructor. Everything else (struct_init, constructor call, if/nullish/tuple/closure selectors, and crucially a bare `.ident`) is a non-borrow -> excluded (a bare local value-struct returned by value would dangle since Kyte does not copy-return). This is the M-1 escape rule for return positions.

- **`fn stmtHasNonBorrowReturn(self, stmt) -> bool`** (private) -- does a statement (recursing blocks/if/while/for/switch) contain a return whose value is not a borrow? Drives value-struct escape channel (1b).

- **`fn blockHasNonBorrowReturn(self, stmts) -> bool`** (private) -- the `stmtHasNonBorrowReturn` fold over a statement list.

- **`fn returnedConstructedStruct(self, expr, set) -> void`** (private) -- record the struct base name CONSTRUCTED by a return expression (struct_init, constructor call, or the branches of an if-expr) into the escape `set`. A bare read/call constructs nothing.

- **`fn excludeStructByName(self, set, name) -> void`** (private) -- add a struct base name to a `StringHashMap(void)` escape set (dupes the key, owns it), guarding against unknown bases and duplicates.

- **`fn scanReturnConstructions(self, stmts, set) -> void`** (private) -- walk a body and, for every non-borrow return, exclude the struct it constructs. Mirrors the control-flow recursion of `stmtHasNonBorrowReturn`.

- **`fn scanStmtReturnConstructions(self, stmt, set) -> void`** (private) -- the per-statement half of the above.

- **`fn computeValueEscapeSet(self) -> void`** (private) -- THE whole-program value-struct escape analysis, run once lazily when the value-struct gate is on. A value struct must stay on the heap when: (1a) it is CONSTRUCTED-and-returned (a fresh alloca outliving the frame) anywhere, including lifted closures whose declared return type is a useless `i32`; (1b) a non-borrow return of a bare local of a declared non-reference return type; (2) it is stored as a direct struct field (unless the field is itself an inline value struct, which is deep-copied by memcpy and is safe; a `class` field forces the heap because it is a shared-mutable reference), OR it implements a trait (can be widened to a fat pointer holding a pointer to it), OR it is `@serializable` (constructed by a generated binder through an erased generic the return channel cannot see); (3) a generic struct arg that lands in a DIRECT type-param field (a raw 8-byte slot holding a pointer to a stack alloca), or in a tuple element / error-union payload / optional inner (aggregate slots not yet inline-aware). Over-exclusion is safe (heap); under-exclusion is a UAF, so it scans the whole interned type store for completeness. Stores the result in `self.value_escape_set`.

- **`fn excludeIfStruct(self, store, set, id) -> void`** (private) -- if a TypeId renders to a known struct base, exclude it. Used for the aggregate/coercion slots in channel (3). `renderLegacy` returns a BORROWED string, never freed.

- **`pub fn isValueStructName(self, name) -> bool`** -- may this struct be value-lowered? False unless `value_structs_enabled`. False for an unknown base, a colliding struct (same bare name in two modules, whose escape channels never match its scoped key, so keep it on the heap, case 282), a `class` (`is_reference`), or a struct in the escape set. Then true if `value_structs_all`, or if the named base is in `value_type_set`; else false. Lazily builds `value_escape_set`.

- **`pub fn valueStructHasOwnedFields(self, name) -> bool`** -- does the value struct have any owned (reference) field needing retain-on-copy / release-on-drop? A scalar-only value struct has none and needs no drop at all.

- **`pub fn isValueStructTid(self, t) -> bool`** -- the same decision from a struct TypeId. Only renders the name (paying the cost) when the gate is on; off by default so the hot ownership path has zero overhead. `renderLegacy` result is borrowed, never freed (freeing it would corrupt sema's name cache).

- **`pub fn isOwnedTypeId(self, t) -> bool`** -- THE ownership engine, the single decider for every real type. Emits `tdShadowDiff` if reporting. Switches: `.unresolved` -> prints a compiler-error banner and `exit(70)` (an ownership action on an untyped value is a compiler bug); `.type_param` -> resolve through the current instantiation's `tpResolve` and defer to `st.isOwned(concrete)`, else false (an erased type-param carries no ownership); `.enum_` -> `st.isOwned` (reads the tagged flag); `.optional` -> true if it is a value-optional (the box is owned), else the inner's ownership; `.struct_` -> false if value-lowered (`isValueStructTid`), else `st.isOwned`; everything else -> `st.isOwned`.

- **`pub fn isOwnedLocal(self, name, type_string) -> bool`** -- ownership of a named local: prefer its recorded TypeId (`current_local_type_ids`) when it is neither unresolved nor a type-param, else fall back to `ownedByName(type_string)`.

- **`pub fn typeOfExprConcrete(self, expr_ptr) -> ?typesys.TypeId`** -- recover a CONCRETE, usable TypeId for an expression. Rejects `.unresolved`/`.type_param` ids (in an instantiated body the typed IR may hand back the raw `T`; those are not decision ids). Tries the instantiation overlay (`typeOfInst`) first, then the plain `typeOf`, then, for an ident, the local TypeId slot (`current_local_type_ids`, populated for params and let/const locals). Null if nothing concrete resolves.

- **`pub fn isStringExpr(self, expr_ptr) -> bool`** -- the expr's concrete TypeId is `.string`.

- **`pub fn isFloatExpr(self, expr_ptr) -> bool`** -- concrete TypeId is a `.prim` of kind `.float`. (These `is*Expr` predicates are the TypeId replacements for the old `resolveExpressionTypeName(e) == "float"` string compares; each returns false when no concrete id is available.)

- **`pub fn isBoolExpr(self, expr_ptr) -> bool`** -- `.prim` of kind `.bool`.

- **`pub fn isVoidExpr(self, expr_ptr) -> bool`** -- `.prim` of kind `.void_`.

- **`pub fn isAnyExpr(self, expr_ptr) -> bool`** -- TypeId is `.any_`.

- **`pub fn isDecimalExpr(self, expr_ptr) -> bool`** -- TypeId is `.decimal`.

- **`pub fn tupleElemTraitName(self, expr_ptr, idx) -> ?[]const u8`** -- if the expr is a tuple and element `idx` is a trait, return that trait name (when it is a known trait); else null. Used to widen a tuple element to a trait object.

- **`pub fn isOwnedErrUnionOk(self, expr_ptr, ok_string) -> bool`** -- ownership of an error-union's ok arm: if the expr's TypeId is an error-union, `isOwnedTypeId(ok)`; else `ownedByName(ok_string)`.

- **`pub fn isOwnedErrUnionErr(self, expr_ptr, err_string) -> bool`** -- the err-arm equivalent.

- **`pub fn isOwnedStorageElem(self, obj_ptr, elem_string) -> bool`** -- ownership of a storage element from the container expr's TypeId; else `ownedByName(elem_string)`.

- **`pub fn typeIdForRenderedName(self, name) -> ?typesys.TypeId`** -- reverse-lookup a TypeId from a rendered composite name. Lazily builds `self.rendered_name_ids`, a map from `renderLegacy` name to id, over every interned `.error_union`/`.tuple`/`.storage`/`.struct_` type. Returns the id for `name` or null.

- **`pub fn isOwnedStorageElemByName(self, elem_string) -> bool`** -- build `Storage<elem>`, look up its TypeId, and if it is a storage type return `isOwnedTypeId(element)`; else `ownedByName(elem_string)`.

- **`pub fn isOwnedErrUnionPayloadByName(self, union_name, is_err, payload_string) -> bool`** -- look up the error-union TypeId by name and return the chosen arm's ownership; else `ownedByName(payload_string)`.

- **`pub fn isOwnedTupleElemByName(self, tuple_name, idx, elem_string) -> bool`** -- look up the tuple TypeId by name and return element `idx`'s ownership; else `ownedByName(elem_string)`.

- **`pub fn tidForName(self, name) -> ?typesys.TypeId`** -- recover a RESOLVED TypeId from a rendered name so a name-only site can defer to `isOwnedTypeId`. Tries the rendered-name index (composites + struct-with-args), then the sema lowerer (`lower.Lowerer` on `.ident`) for plain named types. Returns null only for names with no concrete type (bare type params, instantiation-free generics), which are reachable only from erased bodies mono dead-strips.

- **`fn nameResolvable(store, t) -> bool`** (private) -- a name resolves to a usable ownership answer for anything concrete INCLUDING enums (the "any variant has a payload" rule); only a bare type-param or unresolved has no answer. Unwraps optionals.

- **`pub fn ownedByName(self, name) -> bool`** -- the principled name-keyed ownership fallback. `any` is owned (decided before the primitive check, since `isPrimitiveTypeName` lumps `any` with value primitives); a primitive is not owned; anything with a recoverable TypeId (`tidForName`) defers to the one engine; else the erased-body default (`erasedOwnershipDefault`). Bumps `irct_*` shadow counters.

- **`pub fn isOwnedDeclaredType(self, tr: ast.TypeRef, string_fallback) -> bool`** -- ownership from a declared TypeRef: lower it via the sema lowerer, and if it resolves DIRECTLY (not enum/type_param/unresolved) defer to `isOwnedTypeId`; else `ownedByName(string_fallback)`. The preferred path for struct fields and enum payloads (used by the destructor synthesisers).

- **`pub fn tidForTypeRef(self, tr) -> ?typesys.TypeId`** -- lower a TypeRef to a TypeId via the sema lowerer; null if unresolved.

- **`pub fn concreteTidForTypeRef(self, tr) -> ?typesys.TypeId`** -- the CONCRETE TypeId a TypeRef lowers to UNDER the current instantiation. Fast path: a bare type-param name (`T`/`U`) recovers its interned leaf via `paramLeafByName` and resolves through `tpResolve`. Otherwise lower then `substViaOverlay`. Null if it still contains a type-param/unresolved. Used by transitive free-fn discovery to compute concrete TypeId args instead of strings.

- **`fn paramLeafByName(name, inst) -> ?typesys.TypeId`** (private) -- resolve a bare type-param name to its interned type-param LEAF under the current instantiation, using the owner decl's type_param names. Checks the inst key's owner (a free-fn or a method's `<U>`) first, then, for a method inst (`.struct_{method_owner, [recv] ++ args}`), the receiver struct's own type-params (its `T`). Interning is deterministic so the leaf matches the one the sema overlay recorded `tpResolve` for.

- **`fn paramIndexIn(sm, decl, name) -> ?u32`** (private) -- the index of a type-param `name` in a declaration's type_params (function or struct); null otherwise.

- **`fn substViaOverlay(st, ir, t, inst) -> typesys.TypeId`** (private) -- substitute every type-param LEAF in `t` with its concrete TypeId from the overlay's `tpResolve` under `inst`, re-interning composites (struct/optional/future/storage/array/error_union/tuple/func) as needed. The TypeId-native replacement for the string engine's `substTypeParams`; resolves both struct-T and method-U with no receiver off-by-one. Leaves it cannot resolve are returned unchanged. Guards arg counts at 16 (a fixed buffer).

- **`fn isIdentByte(c) -> bool`** (private) -- `[A-Za-z0-9_]`; the token boundary for `substMethodParams`.

- **`pub fn substMethodParams(self, type_str) -> ![]const u8`** -- SE-C monomorphised name mangling, TypeId-native. For each identifier token in a rendered type spelling, if it is a type-param of the active instance (`paramLeafByName` + `tpResolve` resolves to a concrete), replace it with that concrete's `renderLegacy` name. Returns `type_str` unchanged (borrowed) when nothing was replaced, else an owned string. This replaced the old `current_method_subst` string bindings (proven dead by a full-corpus census). A wrong name here is a loud LINK error, never a UAF.

- **`fn decidedDirectly(store, t) -> bool`** (private) -- true for anything except enum/type_param/unresolved (unwrapping optionals). Gates `isOwnedDeclaredType` onto the TypeId path only when the answer is direct.

- **`fn isOwnedRenderedFallback(self, t) -> bool`** (private) -- render the TypeId, substitute type params, and run `legacyStringOwnership`. The string-engine baseline used by `tdShadowDiff` for the shadow comparison.

- **`pub fn scopedStructName(self, name, file) -> []const u8`** -- the module-scoped name of a colliding struct bound to `name` in `file`, from the sema symbol table; else `name`. `self` unused.

- **`pub fn isCollidingStruct(self, name) -> bool`** -- true if `name` is in sema's `colliding_types` (a bare name defined in two modules). `self` unused.

- **`pub fn scopedTypeName(self, bare, file) -> []const u8`** -- like `scopedStructName` but for a type reference (enum/trait have no value TypeId, so scope by the reference's source file); returns `bare` when not colliding. `self` unused.

- **`pub fn resolveExpressionTypeName(self, expr_ptr) -> !?[]const u8`** -- render an expression's type NAME. When the typed IR has no concrete type: for a `struct_init` that is an enum variant, the enum name; for an ident, the recorded local type string; else null. Otherwise renders `renderLegacy` then `substTypeParams` for the base answer, runs the `tid_census` agreement check if enabled, and, where the instantiation overlay resolves a concrete TypeId, returns that id's render (type-params reified through TypeIds, value-optional wrapper rendered faithfully); only the residual erased cases fall back to the string-substituted render. This is the remaining legitimate name-from-expression path.

- **`pub fn symbolName(self, tid) -> ![]const u8`** -- THE single sanctioned TypeId->string boundary: `renderLegacy` then `substTypeParams` to resolve lingering type-params. All places needing a NAME from a TypeId should route here so the one type->string conversion is auditable. Owned slice.

- **`pub fn resolveCalleeName(self, callee_name) -> ![]const u8`** -- resolve a call target to its emitted symbol. If the bare name is a known function, use it. Else try, in order: the current instantiation's method symbol (`methodSymbol(inst, callee)`), `current_struct_name`-prefixed, and `current_module_prefix`-prefixed. Returns the bare name if none resolve (bumping `scan_unresolved` when tracing). Note: the intermediate `mono_name` is freed on miss, but the struct/module-prefixed hits return owned slices the caller manages.

- **Module tests** -- `mangleTypeName` spellings and non-collision, plus a wiring test that the test module can see the `llvm` import.

**Gotchas / invariants (types.zig):**
- The value-word convention: nearly everything is stored as the i64 `val_type` word. The exceptions are arrays (`ptr_type`, for provenance/vectorisation), SIMD vectors (their vector type), and floats/doubles (stored widened to `double`). `slotTypeForLocalId` is the authority; `coerceToSlotType`/`castToValType`/`castFromValType` are the seams that convert at every store/load boundary. Getting the seam wrong silently corrupts a value (e.g. treating a float's bits as an int).
- `int` is i32, `long` is i64. A heap address computed as `int + offset` truncates to 32 bits (LLVM `trunc i64->i32`) and SIGSEGVs address-dependently. `cgPrim` is where this is fixed in stone; do not change `int` to i64.
- `valueOptionalName` (value-optional) versus a heap-optional: only a value-primitive-plus-`undefined` pair is a boxed value-optional. `string | undefined` is a plain 0-is-none pointer optional. Rendering a value-optional as its bare inner (dropping `| undefined`) reintroduces the F1 SEGV; `typeRefToString` and `renderLegacy` both keep the wrapper.
- Ownership has ONE engine, `isOwnedTypeId`. Every `isOwned*ByName` shim exists only to recover a TypeId and defer to it, or to fall back to `ownedByName` (which itself tries `tidForName` then the erased default) for names with no concrete type. An `.unresolved` reaching `isOwnedTypeId` is a hard `exit(70)`.
- `renderLegacy` results are BORROWED (interned/static). Codegen never frees them; freeing corrupts sema's name cache that method resolution reads. `symbolName`/`substMethodParams`/`typeRefToString` results, by contrast, are owned when substitution happened.
- `computeValueEscapeSet` fails SAFE: over-exclusion just keeps a struct on the heap, under-exclusion is a UAF, so it scans the whole type store. A colliding struct is always kept on the heap (its escape channels are keyed on the source name, not its scoped key).

---

## Cross-references

- **`llvm_codegen.zig`** -- defines `LlvmCompiler` (its fields: `builder`, `module`, `val_type`/`i1_type`/`i8_type`/`i16`/`i32_type`/`i64_type`/`void_type`/`ptr_type`, `structs`/`enums`/`unions`/`traits`, `functions`, `func_map`, `locals`, `current_instantiation`/`current_instantiation_id`, `current_local_types`/`current_local_type_ids`, `type_store`, `typed_ir`, `value_escape_set`, `rendered_name_ids`, `suppress_valopt_unbox`, etc.) and re-exports every free function here as a method via the aliasing block. `configureValueStructs` (there) flips the `arc_mod` gates; `emitModule` reads `asan_codegen_enabled` and calls `elideBorrowedArc`.
- **`expressions.zig`** -- the primary caller of `compileCallArgument`, `acquisitionDisposition`, `takeOwnedElement`, `buildErrUnion`, the `is*Expr` predicates, and `castToValType`/`castFromValType`/`coerceToSlotType` at every value store/load.
- **`statements.zig`** -- calls `releaseLocalVariables` / `releaseLocalByName` / `dropValueStruct` at scope exit, and consults `returnIsBorrow` at return positions.
- **`sema/ownership.zig`** -- produces the `ownedOf` / `ownedOfInst` annotations that `acquisitionDisposition` and `isOwnedExpr` read; this file's `isOwnedTypeId` is the codegen mirror of that pass's decision, kept honest by the `KYTE_SEMA_SHADOW` diff.
- **`sema/escape.zig`** -- the sema-side escape gauge (function-local, report-only per the memory notes); `computeValueEscapeSet` here is the codegen-side, request-independent value-struct escape decision that actually gates value-lowering.
- **`sema/lower.zig` + `sema/subst.zig` + `sema/infer.zig` + `sema/shadow.zig`** -- `Lowerer` (TypeRef->TypeId), `subst.substitute` / `substViaOverlay` (type-param substitution), `TypedIr.tpResolve`/`typeOf*`, and `renderLegacy` (the TypeId->string renderer and the shadow counters) that this file leans on throughout.
- **`frontend/types.zig` (`typesys`)** -- the `TypeStore`, `TypeId`, and the type-kind union (`.prim`/`.struct_`/`.enum_`/`.optional`/`.tuple`/`.error_union`/`.storage`/`.array`/`.func`/`.trait_`/`.type_param`/`.unresolved`/`.string`/`.any_`/`.decimal`/`.future`) that every switch here dispatches on.
