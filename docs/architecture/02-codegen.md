# Code Generation

`src/codegen/` (~11,500 lines) turns the typed IR into **LLVM IR**, then an object file. It is the largest
subsystem and the one where Nova's runtime representation is decided. Entry point:
`declarations.zig:compile(...)`, which constructs an `LlvmCompiler` (`llvm_codegen.zig`) and runs three
phases: declare everything → emit bodies → verify + optimize + emit object.

| File | Role |
|------|------|
| `llvm_codegen.zig` (~3050) | The `LlvmCompiler` struct: LLVM context/module/builder, type table, and the emitted primitives (allocator, `nova_retain`/`nova_release`, vtable construction, trait dispatch). |
| `declarations.zig` (~1710) | Phase 1: declare every function/global/vtable + the WASM allocator; Phase 3: verify, `CoroSplit`, `globalDCE`, write `.o` (per-file under T6). |
| `expressions.zig` (~3970) | Lower expression IR → LLVM values (calls, closures, trait dispatch, await, operators, literals). |
| `statements.zig` (~720) | Lower statements (let/assign/return/if/while/for) + the ownership drops around them. |
| `arc.zig` (~1250) | Emit retain/release and per-type destructors (`__destruct_*`) that `ownership.zig` planned. |
| `types.zig` (~740) | Map Nova `TypeId`s to LLVM types; struct layouts. |

## The value model: `val_type` = i64

**Every Nova value is a 64-bit handle** (`val_type = LLVMInt64Type`), on *both* native and WASM. The
reason is uniformity: the same slot must be able to hold an `int`, a `long`, a heap pointer, or an `f64`
(the float path bit-casts `val_type ↔ double`). Consequences:

- An `int` is semantically 32-bit but travels in an i64 slot; overflow/narrowing rules are enforced in the
  checker, not by the slot width.
- A **heap pointer is 64-bit** on native. Address arithmetic (`buf + off`) must be done at i64 — an
  `int`-typed address truncates to 32 bits (`trunc i64→i32`) → garbage pointer → address-dependent
  SIGSEGV. This is the single most common class of bug; the checker's pointer-truncation diagnostic and
  the `long`-typing of buffer addresses in the stdlib exist to prevent it.
- On **WASM32 a pointer is i32** but still rides the low 32 bits of the i64 handle. Inside the module,
  `inttoptr i64→ptr` truncates to i32 so memory access is correct even if the high bits are dirty; at the
  host-import boundary the high bits must be masked (see WASM section).

## Heap objects & ARC

Nova is reference-counted, not garbage-collected. Every heap allocation carries an **8-byte header**:

```
  [ refcount : i32 @ ptr-8 ][ length : i32 @ ptr-4 ][ payload … @ ptr ]
```

- `nova_bytes_alloc(size)` returns `payload` (the client pointer); the header sits just below it.
- **`nova_retain(ptr)`** bumps the refcount; **`nova_release(ptr, dtor)`** decrements and, at zero, calls
  the type's destructor (which releases owned fields) and frees the block.
- On **native** these are provided by the C++ runtime. On **WASM** the compiler *emits* a bump allocator
  in-module (see below), and `nova_retain`/`nova_release` are currently no-ops there (explicit `bytes.free`
  only) — a deliberate best-effort simplification for the secondary target.

The ownership pass (`sema/ownership.zig`) decides, per IR edge, who owns a value and where it is dropped;
`arc.zig` emits the matching `retain`/`release` and the per-type `__destruct_<T>` functions. **Balance is
verified with AddressSanitizer** — the ARC audit alone misses use-after-frees.

## Traits: fat pointers + vtables

A trait object is a **fat pointer** `{ struct_ptr, vtable }` (two `val_type` slots, 16 bytes). The vtable
is a per-(struct, trait) constant global, `_vtable_<Struct>_<Trait>`, laid out as:

```
  slot 0 : the struct's destructor          ← so __destruct_trait can release a value it only knows as a trait
  slot 1 : trait method 0
  slot 2 : trait method 1   …
```

Dynamic dispatch (`buildTraitVtableCall` in `llvm_codegen.zig`) loads `struct_ptr` from fat-pointer
offset 0, `vtable` from offset 8, then the method pointer from `vtable + (m_idx+1) * ptrElemSize()`.

> **Portability note (a real bug this fixed):** vtable *elements* are `ptr_type`. On native `ptr_type` is
> 8 bytes; on WASM32 it is **4 bytes**. Indexing with a hardcoded `8` read the wrong slot on WASM → a
> garbage function index → `call_indirect` "null function". The stride is therefore `ptrElemSize()`
> (4 on WASM, 8 native). Fat-pointer slots stay `val_type` (always 8).

Generic trait objects (`Behavior<M>`) erase the type arg for dispatch and share a base-name vtable. An
`async fn` trait method's vtable slot holds the coroutine ramp; the same dispatch lowering is shared by
the sync-call site and the `await` path.

## Closures

A closure is a heap box `{ fn_ptr, env, cleanup }`. The lambda body is emitted as a top-level function
whose first parameter is the environment; captured locals are copied into `env` **by value** at creation
(a mutating closure does not write back — a documented sharp edge for JS/Python devs). Calling a closure
loads `fn_ptr` and `env` and issues an indirect call with the arity-appropriate function type.

## Async: LLVM coroutines

`async fn` compiles to an **LLVM coroutine** (`presplitcoroutine` → the `CoroSplit` pass → `.resume` /
`.destroy` functions). `spawn`/`go` forks a coroutine and returns a `future<T>` handle; `await` suspends
the caller, registers it as the awaited child's waiter, and resumes on completion. `when_all` /
`selectAny` combine futures. A **generic** async method is only spawnable from a *concrete* instantiation,
not an erased-`M` context.

The one seam worth knowing: a **synchronous** caller (a sync `main`/`@test`, top level) may call an
`async fn` directly — codegen block-drives it to completion via `nova_run_root`. Doing that from *inside*
the event loop (a running coroutine) re-enters `io.run()` and deadlocks; the runtime detects the nested
drive and aborts loudly, and the checker's function-coloring rules keep it from arising in normal code.
See [03-runtime.md](03-runtime.md).

## The WASM split

Codegen is target-parameterized by `is_wasm`. The differences that matter:

- **Pointer width** — `ptr_type` is i32; vtable/pointer-array strides use `ptrElemSize()`; host imports
  mask pointers to 32 bits (the harness `ptr32`).
- **Allocator is emitted in-module.** There is no C++ runtime on WASM, so `declarations.zig` emits
  `nova_bytes_alloc` (a bump allocator) and `nova_bytes_alloc_persistent` (bump; the free-list is disabled
  on WASM — a hardcoded 32 MB heap/persistent boundary didn't survive the `__heap_base` seeding, so pure
  bump trades reuse for correctness). The heap is seeded lazily from the linker symbol **`__heap_base`**
  on first allocation (a static `ptrtoint(&__heap_base)` initializer is illegal on WASM, and the `@test`
  harness never calls `main`).
- **Native-only features are rejected up front.** async/await/spawn and native runtime symbols
  (sockets/TLS/crypto/process/FFI) produce clean, located compile errors on WASM instead of crashing —
  see the checker's `is_wasm` gate and the codegen "native-only on wasm" messages.

The WASM execution harness (`conformance/wasm-run.mjs`) implements the small set of host imports (string
helpers, decimal128 as a BigInt port of `runtime/decimal.cpp`, atomics) against the module's own memory,
and its `--guard` mode snapshots read-only static data `[0, __data_end)` after each `@test` to catch
out-of-bounds writes — the WASM equivalent of ASAN.

## Emit, verify, optimize

After bodies are emitted, `declarations.zig` runs `LLVMVerifyModule`, the coroutine split, and
`globalDCE` (which drops erased fallback bodies and unreferenced vtables), then emits the object via the
target machine. Under T6 the module is cloned and emitted **per source file** into separate objects, each
keyed by a content hash so a one-file edit rebuilds one object.
