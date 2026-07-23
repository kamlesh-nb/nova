# Nova Language Specification vs. Implementation: Identified Gaps

This document identifies the discrepancies, stubs, and correctness gaps between [language-specification.md](file:///Users/kamlesh/nova-lang/lang/docs/language-specification.md) and the actual compiler/runtime implementation in [lang/src](file:///Users/kamlesh/nova-lang/lang/src).

---

## 1. Memory Management & ARC Gaps

### 1.1 Memory Leak in JSX Element Interpolation
* **Specification Section:** §7 Expressions & §3.3 string (StringBuilder-based assembly)
* **Code Reference:** [`lang/src/codegen/expressions.zig#L3248-L3253`](file:///Users/kamlesh/nova-lang/lang/src/codegen/expressions.zig#L3248-L3253)
* **Gap/Bug:** When compiling JSX elements (`compileJsxElement`), the compiler uses an internal `StringBuilder` to compile expressions and append results. If an interpolated expression is a variable (`is_var` check for `.ident`, `.field_access`, or `.index`), the compiler explicitly emits a `compileRetain` call. However, `StringBuilder_append` utilizes a uniform borrow-ABI—it only borrows the string and copies its byte contents, without retaining it. Since the caller increments the refcount via `compileRetain`, and no balancing release is ever emitted, **interpolating any variable inside a JSX element causes a permanent memory leak** of that variable.
* **Additional Leak:** The 24-byte `StringBuilder` header box allocated on the heap at [`lang/src/codegen/expressions.zig#L3207`](file:///Users/kamlesh/nova-lang/lang/src/codegen/expressions.zig#L3207) is never released via `nova_release`, leaking the header on every JSX element evaluation.

### 1.2 Skipped Defer Execution on Loop Jumps (`break` / `continue`)
* **Specification Section:** §6.4 return, break, continue, defer
* **Code Reference:** [`lang/src/codegen/statements.zig#L26-L41`](file:///Users/kamlesh/nova-lang/lang/src/codegen/statements.zig#L26-L41)
* **Gap/Bug:** When loop control flow jumps using `break` or `continue`, the compiler calls the `releaseScopesForLoopExit` helper to release `owned_locals` for the scopes being exited. However, this helper **does not** execute any `deferred_statements` in those scopes. Consequently, any `defer` statements defined inside the body of a loop are completely skipped if the loop is exited early or continued, leading to potential resource leaks or skipped cleanup actions.

### 1.3 Missing ARC Destructors for Unions (`union_decl`)
* **Specification Section:** §3.8 Structs, enums, traits & §15 Known gaps
* **Code Reference:** [`lang/src/codegen/arc.zig#L725-L727`](file:///Users/kamlesh/nova-lang/lang/src/codegen/arc.zig#L725-L727)
* **Gap/Bug:** The compiler parses unions (`ast.UnionDecl`), but does not perform type checking on them (they are ignored in `TypeChecker.check`'s declaration walk). Additionally, in `getOrCreateDestructor` in `codegen/arc.zig`, the compiler returns `null` for unions since they are not standard structs or `Storage<T>`. Because unions are untagged, the runtime does not know which field is active and cannot clean up reference-counted elements (such as `string` or `struct` fields). Consequently, any reference-counted fields stored in a union will leak when the union goes out of scope. There is currently no type-checking rule preventing reference-counted types inside unions.

### 1.4 Missing ARC Destructors for Fixed-Size Arrays `T[N]`
* **Specification Section:** §2 Lexical structure & §4 Ownership & memory model
* **Code Reference:** [`lang/src/codegen/arc.zig#L725-L727`](file:///Users/kamlesh/nova-lang/lang/src/codegen/arc.zig#L725-L727)
* **Gap/Bug:** Fixed-size arrays (like `string[3]`) are allocated on the heap via `compileAlloc`. However, `getOrCreateDestructor` in `codegen/arc.zig` returns `null` for `.fixed_array` types since they are not declared structs. Thus, fixed-size arrays containing reference-counted elements (such as strings or structs) do not have destructors generated, causing **all elements inside the array to leak** when the array goes out of scope.

---

## 2. Type System & Type Checker Gaps

### 2.1 Lack of Type Checker validation for `Atomic<T>`
* **Specification Section:** §3.7 Containers & generics & §9 Concurrency
* **Code Reference:** [`lang/src/codegen/llvm_codegen.zig#L1266-L1305`](file:///Users/kamlesh/nova-lang/lang/src/codegen/llvm_codegen.zig#L1266-L1305) & [`lang/src/type_checker.zig`](file:///Users/kamlesh/nova-lang/lang/src/type_checker.zig)
* **Gap/Bug:** The primary type checker (`type_checker.zig`) completely ignores `Atomic<T>` and does not restrict the generic parameter `T` to supported primitives (`int`/`long`/`bool`). If a user instantiates `Atomic<string>` or `Atomic<MyStruct>` (refcounted types), the compiler allows it. At the codegen level, `compileAtomicCall` falls back to emitting 32-bit atomic operations (`nova_atomic_*_i32`) for unrecognized types. This leads to:
  1. **Silent pointer truncation** and memory corruption at runtime (since pointers are 64-bit).
  2. **ARC bypass**, resulting in memory leaks or use-after-free bugs because the stored objects are never retained or released.

### 2.2 Missing Type-Checking on Index (`[]`) Expressions
* **Specification Section:** §2 Lexical structure & §3.7 Containers & generics
* **Code Reference:** [`lang/src/type_checker.zig#L615-L618`](file:///Users/kamlesh/nova-lang/lang/src/type_checker.zig#L615-L618)
* **Gap/Bug:** The `TypeChecker`'s `checkExpr` function only recursively checks the sub-expressions of an index expression `.index`. It does not perform any semantic validation (e.g., verifying that the base object is indexable like a string or array, or checking that the index evaluates to an integer). Consequently, it allows indexing arbitrary types (such as `int`, `float`, or arbitrary structs). Codegen compiled this via raw pointer arithmetic (`obj_ptr + offset * 8`), which leads to compilation success but results in segmentation faults or arbitrary memory reads/corruption at runtime.

### 2.3 The `any` Type ARC & Type Safety Bypass
* **Specification Section:** §3.1 Primitive & scalar types & §15 Known gaps
* **Code Reference:** [`lang/src/type_checker.zig#L1120-L1123`](file:///Users/kamlesh/nova-lang/lang/src/type_checker.zig#L1120-L1123) & [`lang/src/codegen/types.zig#L228`](file:///Users/kamlesh/nova-lang/lang/src/codegen/types.zig#L228)
* **Gap/Bug:** The `any` type is parsed and accepted by the type checker, which treats it as mutually compatible with all types. However, `any` is classified as a primitive type under `isPrimitiveTypeName`, meaning the compiler does not generate any ARC instructions (retains/releases) or destructor calls for it. If a reference-counted object (like `string` or `List`) is assigned to `any`, the compiler copies the raw pointer address without managing the reference count. When the `any` variable goes out of scope, it is ignored by ARC, leading to memory leaks. Assigning back from `any` also lacks ownership tracking, leading to double-free or use-after-free corruptions.

### 2.4 Lack of Tuple Indexing Support in Semantic Analysis
* **Specification Section:** §3.7 Containers & generics & §15 Known gaps
* **Code Reference:** [`lang/src/sema/infer.zig#L931-L939`](file:///Users/kamlesh/nova-lang/lang/src/sema/infer.zig#L931-L939) & [`lang/src/codegen/expressions.zig#L2586-L2594`](file:///Users/kamlesh/nova-lang/lang/src/codegen/expressions.zig#L2586-L2594)
* **Gap/Bug:** While the language supports tuple construction and destructuring assignment (`let (a, b) = pair`), it does not support tuple index access (like `pair.0` or `pair.1` since field access only parses identifiers, or `pair[0]`). In `sema/infer.zig`, index access on a type other than `string` or `array` returns `unresolved("index")`, which poisons downstream type inference. In codegen, index access falls back to raw pointer loading (`obj_ptr + offset * 8`), bypassing bounds checks and semantic type validation.

---

## 3. Scoping & Visibility Gaps

### 3.1 Function Cross-Module Visibility Hole on Multi-Segment Imports
* **Specification Section:** §8 Modules & visibility & §15 Known gaps
* **Code Reference:** [`lang/src/sema/infer.zig#L1477`](file:///Users/kamlesh/nova-lang/lang/src/sema/infer.zig#L1477) & [`lang/src/sema/symbols.zig#L362-L374`](file:///Users/kamlesh/nova-lang/lang/src/sema/symbols.zig#L362-L374)
* **Gap/Bug:** Cross-module visibility checks for functions are performed inside the `resolveImportedModule` block of `resolveModuleFn` in `infer.zig`. However, when this direct module lookup fails (which is the case for multi-segment imports like `import collections.map`), the compiler falls back to `findFunctionBySegment`. Since `findFunctionBySegment` does not perform any visibility checks, non-public (`pub`) functions from external modules can be successfully resolved and called without compilation errors.

---

## 4. Platform & Build Gaps

### 4.1 Unverified WebAssembly (WASM) Target
* **Specification Section:** §1 Overview & toolchain, §15 Known gaps
* **Code Reference:** [`lang/build.zig#L162-L179`](file:///Users/kamlesh/nova-lang/build.zig#L162-L179) & [`lang/docs/language-specification.md#L352-L354`](file:///Users/kamlesh/nova-lang/lang/docs/language-specification.md#L352-L354)
* **Gap/Bug:** The strategic target for WebAssembly compiles and generates LLD link instructions in codegen, but the Zig build system configuration for building WASM is commented out in `build.zig`. There is currently no active CI test running with the `--wasm` target in default conformance checks, and the runtime library lacks complete integration and verification.
