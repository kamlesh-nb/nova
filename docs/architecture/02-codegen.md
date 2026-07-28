# Code Generation

`src/codegen/` (about 11,500 lines) turns the typed IR into **LLVM IR**, and thereafter an object file. It
is the largest subsystem, and the one in which Nova's runtime representation is decided. The entry point
is `declarations.zig:compile(...)`, which constructs an `LlvmCompiler` (see `llvm_codegen.zig`) and runs
three phases: declare everything, then emit bodies, and finally verify, optimise, and emit the object.

| File | Role |
|------|------|
| `llvm_codegen.zig` (about 3050) | The `LlvmCompiler` struct: the LLVM context, module, and builder, the type table, and the emitted primitives (the allocator, `nova_retain` and `nova_release`, vtable construction, and trait dispatch). |
| `declarations.zig` (about 1710) | Phase 1 declares every function, global, vtable, and the WASM allocator; Phase 3 verifies, runs `CoroSplit` and `globalDCE`, and writes the `.o` (per file under T6). |
| `expressions.zig` (about 3970) | Lowers expression IR to LLVM values (calls, closures, trait dispatch, await, operators, literals). |
| `statements.zig` (about 720) | Lowers statements (let, assign, return, if, while, for) along with the ownership drops around them. |
| `arc.zig` (about 1250) | Emits retain and release, and the per-type destructors (`__destruct_*`) that `ownership.zig` planned. |
| `types.zig` (about 740) | Maps Nova `TypeId`s to LLVM types, and computes struct layouts. |

## The Value Model: `val_type` is i64

**Every Nova value is a 64 bit handle** (`val_type = LLVMInt64Type`), on both native and WASM. The reason
is uniformity: the same slot must be capable of holding an `int`, a `long`, a heap pointer, or an `f64`
(for which the float path bit casts `val_type` to and from `double`). The consequences are as follows.

- An `int` is semantically 32 bit, yet it travels in an i64 slot; the overflow and narrowing rules are
  enforced in the checker, and not by the slot width.
- A **heap pointer is 64 bit** on native. Address arithmetic (`buf + off`) must be performed at i64, since
  an `int` typed address truncates to 32 bits (a `trunc i64 to i32`), which yields a garbage pointer, and
  hence an address dependent SIGSEGV. This is the single most common class of bug; the checker's pointer
  truncation diagnostic, and the `long` typing of buffer addresses in the standard library, exist for the
  express purpose of preventing it.
- On **WASM32 a pointer is i32**, yet it still rides in the low 32 bits of the i64 handle. Inside the
  module, `inttoptr i64 to ptr` truncates to i32, so memory access is correct even if the high bits are
  dirty; at the host import boundary, however, the high bits must be masked (please see the WASM section).

## Heap Objects and ARC

Nova is reference counted, and not garbage collected. Every heap allocation carries an **8 byte header**.

```
  [ refcount : i32 @ ptr-8 ][ length : i32 @ ptr-4 ][ payload ... @ ptr ]
```

- `nova_bytes_alloc(size)` returns `payload` (the client pointer); the header sits just below it.
- **`nova_retain(ptr)`** bumps the refcount. **`nova_release(ptr, dtor)`** decrements it and, at zero,
  calls the type's destructor (which releases the owned fields) and frees the block.
- On **native** these are provided by the C++ runtime. On **WASM** the compiler *emits* a bump allocator
  in the module (please see below), and `nova_retain` and `nova_release` are at present no ops there (only
  explicit `bytes.free` is used); this is a deliberate best effort simplification for the secondary target.

The ownership pass (`sema/ownership.zig`) decides, per IR edge, who owns a value and where it is dropped;
`arc.zig` then emits the matching `retain` and `release`, and the per-type `__destruct_<T>` functions.
Kindly note that **balance is verified with AddressSanitizer**; the ARC audit by itself does miss use
after free cases.

## Traits: Fat Pointers and Vtables

A trait object is a **fat pointer**, `{ struct_ptr, vtable }` (two `val_type` slots, that is, 16 bytes).
The vtable is a per-(struct, trait) constant global, `_vtable_<Struct>_<Trait>`, laid out as follows.

```
  slot 0 : the struct's destructor          (so that __destruct_trait may release a value it knows only as a trait)
  slot 1 : trait method 0
  slot 2 : trait method 1   ...
```

Dynamic dispatch (`buildTraitVtableCall` in `llvm_codegen.zig`) loads `struct_ptr` from fat pointer offset
0, `vtable` from offset 8, and thereafter the method pointer from `vtable + (m_idx+1) * ptrElemSize()`.

> **A portability note (concerning a real bug that this fixed).** The vtable *elements* are `ptr_type`. On
> native `ptr_type` is 8 bytes; on WASM32 it is **4 bytes**. Indexing with a hardcoded `8` read the wrong
> slot on WASM, which yielded a garbage function index, and hence a `call_indirect` "null function". The
> stride is therefore `ptrElemSize()` (4 on WASM, 8 on native). The fat pointer slots remain `val_type`
> (always 8).

Generic trait objects (`Behavior<M>`) erase the type argument for dispatch and share a base name vtable.
An `async fn` trait method's vtable slot holds the coroutine ramp; the same dispatch lowering is shared by
the sync call site and the `await` path.

## Closures

A closure is a heap box, `{ fn_ptr, env, cleanup }`. The lambda body is emitted as a top level function
whose first parameter is the environment; the captured locals are copied into `env` **by value** at
creation (a mutating closure does not write back, which is a documented sharp edge for those coming from
JavaScript or Python). Calling a closure loads `fn_ptr` and `env` and issues an indirect call with the
arity appropriate function type.

## Async: LLVM Coroutines

An `async fn` compiles to an **LLVM coroutine** (`presplitcoroutine`, then the `CoroSplit` pass, yielding
`.resume` and `.destroy` functions). `spawn` and `go` fork a coroutine and return a `future<T>` handle;
`await` suspends the caller, registers it as the awaited child's waiter, and resumes upon completion.
`when_all` and `selectAny` combine futures. A **generic** async method is spawnable only from a *concrete*
instantiation, and not from an erased `M` context.

There is one seam worth an understanding. A **synchronous** caller (a sync `main` or `@test`, at top
level) may call an `async fn` directly; codegen block drives it to completion via `nova_run_root`. Doing
this from *inside* the event loop (that is, from a running coroutine) re-enters `io.run()` and deadlocks;
the runtime detects the nested drive and aborts loudly, and the checker's function colouring rules keep it
from arising in normal code. For further details, kindly see [03-runtime.md](03-runtime.md).

## The WASM Split

Codegen is parameterised by the target through `is_wasm`. The differences that matter are as follows.

- **Pointer width.** `ptr_type` is i32; the vtable and pointer array strides use `ptrElemSize()`; and the
  host imports mask pointers to 32 bits (via the harness helper `ptr32`).
- **The allocator is emitted in the module.** There is no C++ runtime on WASM, and hence
  `declarations.zig` emits `nova_bytes_alloc` (a bump allocator) and `nova_bytes_alloc_persistent` (also
  bump; the free list is disabled on WASM, because a hardcoded 32 MB heap and persistent boundary did not
  survive the `__heap_base` seeding, so pure bump trades reuse for correctness). The heap is seeded lazily
  from the linker symbol **`__heap_base`** upon the first allocation (a static `ptrtoint(&__heap_base)`
  initialiser is illegal on WASM, and the `@test` harness never calls `main`).
- **Native only features are rejected up front.** async, await, spawn, and the native runtime symbols
  (sockets, TLS, crypto, process, FFI) produce clean, located compile errors on WASM instead of crashing;
  please see the checker's `is_wasm` gate and the codegen "native only on wasm" messages.

The WASM execution harness (`conformance/wasm-run.mjs`) implements the small set of host imports (string
helpers, decimal128 as a BigInt port of `runtime/decimal.cpp`, and atomics) against the module's own
memory. Its `--guard` mode snapshots the read only static data `[0, __data_end)` after each `@test`, so as
to catch out of bounds writes; this is the WASM equivalent of ASAN.

## Emit, Verify, Optimise

After the bodies are emitted, `declarations.zig` runs `LLVMVerifyModule`, the coroutine split, and
`globalDCE` (which drops the erased fallback bodies and any unreferenced vtables), and thereafter emits the
object via the target machine. Under T6, the module is cloned and emitted **per source file** into
separate objects, each of them keyed by a content hash, so that a one file edit rebuilds one object.
