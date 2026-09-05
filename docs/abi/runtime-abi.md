# Kyte Runtime ABI (extern-C seam)

**ABI version: 1** (`KYTE_ABI_VERSION` in `src/runtime/kyte_abi.h`; reported by `kyte version`).

This is the frozen contract between compiler-emitted native code and the C++ runtime library. A
compiler build and a runtime library are link-compatible iff their ABI versions are equal. The
version bumps ONLY on a breaking change to the STABLE core below, independently of the language
version (see `docs/STABILITY.md`).

## Stable core (what the version pins)

### Heap object layout

Every heap-allocated Kyte object is a pointer `ptr` to its payload, preceded by an 8-byte header:

```
  [ptr-8]  u32  refcount     (little-endian; the live reference count)
  [ptr-4]  u32  byte length  (payload length in bytes)
  [ptr+0]  ...  payload      (the object's data; ptr is what Kyte code holds)
```

`KYTE_OBJ_HEADER_SIZE` is `8`. The compiler emits address arithmetic against exactly this layout
(see `src/codegen/arc.zig`); the runtime allocator writes it (see `src/runtime/alloc.cpp`). Heap
addresses are 64-bit: pointer math must be done at 64-bit width (`int` is 32-bit in Kyte and
truncates -- see the language spec's integer note).

### Reference counting

```c
void kyte_retain(long long ptr);                                   // refcount += 1
void kyte_release(long long ptr, void (*destructor)(long long));   // refcount -= 1; if 0, run dtor then free
```

ARC is deterministic: the compiler inserts `kyte_retain`/`kyte_release` pairs so each owning
reference is released exactly once. `destructor` is the type's generated field-releasing dtor (or
null for a payload with no owned fields). This is the seam the whole memory model rests on; the
`--asan` and `--shadow` gates exist to prove the compiler balances it.

### Allocation

```c
long long kyte_bytes_alloc(long long size);              // header + size bytes, refcount = 1
long long kyte_bytes_alloc_persistent(long long size);   // same, but never arena-reclaimed
void      kyte_bytes_free(long long ptr);                // free without running a dtor
```

`kyte_bytes_alloc` returns `ptr` (payload start), with the header initialised and refcount 1.

## Internal symbols (NOT covered by the ABI version)

The rest of `kyte_abi.h` -- the async scheduler and reactor (`kyte_sched_*`, `kyte_run_root`,
`kyte_reactor_*`, `kyte_a*` socket ops), channels (`kyte_chan_*`), synchronisation primitives
(`kyte_mutex_*`, `kyte_atomic_*`), decimal, logging, process/fs, and the test/coverage hooks -- is
the compiler talking to ITS OWN runtime. It is an implementation detail, not a third-party
contract. It changes freely as the self-hosted runtime evolves and does NOT bump the ABI version.
Do not build against these from outside the toolchain.

## Compatibility rule

- Same ABI version -> a `kyte`-compiled object links against that runtime library.
- Different ABI version -> refuse to link; rebuild the object with a matching toolchain.

The layout above has been stable across the C++-runtime-retirement work (the header and ref-count
core predate and survived it); it is expected to be long-lived. When it must break, bump
`KYTE_ABI_VERSION` (header) and `kyte_abi_version` (`build.zig`) together and record the change here.
