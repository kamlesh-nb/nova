# Nova — Closing the Performance Gap to Rust

**Goal.** Match Rust (and beat Go/C#) on CPU-bound compute. Today Nova is competitive on scalar loops
but 1.15×-2.22× slower on array and allocation workloads. This document diagnoses *why*, to the exact
codegen site, and lays out the ordered engineering to close it. Nothing here is research; every step is
precedented compiler work.

**Status legend / tracking convention:** as in `execution-plan.md` (⬜ TODO · ✍️ DESIGNED · 🔨 WIP ·
✅ DONE, each with a Definition of Done and a Tracking line).

---

## 1. Current standing (Apple M1, best of 10, absolute ms)

| Benchmark | Rust | Go | C# | Nova | Nova vs fastest |
|---|---:|---:|---:|---:|---|
| nbody (N=1M) | 28.9 | 75.1 | 81.8 | 29.1 | 1.01× — competitive |
| fannkuch-redux (n=11) | 2061 | 1938 | 1973 | 1916 | fastest |
| mandelbrot (1600²) | 267.9 | 233.9 | 305.0 | 269.1 | 1.15× slower (vs Go) |
| nsieve (160k ×400) | 259.9 | 264.7 | 300.4 | 353.2 | 1.36× slower (vs Rust) |
| spectral-norm (N=1000) | 38.2 | 39.9 | 68.3 | 55.0 | 1.44× slower (vs Rust) |
| binary-trees (depth 16) | 276.0 | 270.4 | 193.7 | 429.4 | 2.22× slower (vs C#) |

Correctness: every Nova program matches the reference golden output; binary-trees is ASAN-clean.
Nova is *slower, not wrong*. Full report + sources: `lang/bench/`.

**Precedent that the ceiling is high.** Two gaps this size were already closed by single changes:
`math.fsqrt` (a 30-iteration Newton loop → the `llvm.sqrt.f64` intrinsic) took nbody from ~20× to 1×,
and the `List<double>` closure-ABI fix unblocked float containers entirely. When Nova hands LLVM clean
IR, LLVM makes it competitive. The remaining gaps are where Nova hands LLVM *dirty* IR.

---

## 2. Root-cause diagnosis

### 2.1 The array gap (mandelbrot / nsieve / spectral) — value representation

**Root cause: the uniform i64 value-word defeats LLVM alias analysis.**

Nova represents *every* value — pointers included — as an `i64` word (`slotTypeForLocalId`,
`src/codegen/types.zig`, returns `val_type` for any type that isn't a scalar prim or `f64x4`). An array
parameter is therefore an `i64`; every element access recovers a pointer with **`inttoptr`**
(`src/codegen/expressions.zig`, sites `arr_base` / `arr_store_base` / `simd_base`) and then `GEP`s.

LLVM's alias analysis is **blind through `inttoptr`**: a pointer with no provenance is assumed to alias
all memory. Consequences, all measured:
- The loop vectorizer will not run — it cannot prove `a[]` and `b[]` are distinct, so `c[i]=a[i]*b[i]`
  stays scalar. A textbook saxpy/dot in Nova compiles to scalar code identical in speed to *scalar*
  Rust; both are ~4× off a vectorized version.
- LICM/GVN cannot hoist or coalesce array loads as aggressively.
- `noalias` is **inapplicable**: the parameters are `i64`, not `ptr`, and LLVM ignores `noalias` on
  non-pointer params.

**Verified null result:** switching array loads to the real element type (`double` instead of the i64
word + bitcast) produced *zero* speedup, confirming the bitcast was never the bottleneck. (That change
was reverted; it is only useful once §3.1 lands.)

**Measured Phase-1 proof (at the LLVM-IR / C level, `opt`/`clang` 21, M1).** Before committing the
multi-day codegen change, the ceiling and the mechanism were verified directly:

- **The `inttoptr` barrier is real but conditional.** A 3-pointer saxpy (`c[i]=a[i]*s+b[i]`) does **not**
  vectorize when the arrays are integers cast to pointers (0 vector ops), but **does** with real
  `double* restrict` params (full NEON). LLVM refuses to insert its runtime alias check on
  provenance-less (`inttoptr`) pointers. Simpler 1-2 pointer loops sometimes vectorize despite
  `inttoptr` — so the block is *not* universal; it bites the multi-array kernels that matter
  (matrix/vector math, stencils, blends).
- **The compute headroom is ~1.9×.** A compute-bound, L1-resident, elementwise kernel (8th-degree Horner
  poly) times **353.7 ms vectorized vs 687.0 ms scalar** — i.e. vectorization ≈ 2× (the double-2-wide
  limit on M1 NEON), which is the ceiling Phase 1 unlocks for compute-bound array loops.
- **Caveat on magnitude:** memory-bound loops (working set > L2, e.g. saxpy at N=4096) are bandwidth-
  limited and see *little* from vectorization regardless. The win is on compute-bound, cache-resident
  array math. So §3.1's payoff is real but workload-dependent — biggest where the array loop is
  arithmetic-heavy and fits in cache.

Conclusion: §3.1 is worth doing (it reliably unlocks the ~2× on the kernels where it matters), and the
`inttoptr` diagnosis is confirmed as the mechanism — but the honest expected gain on the *benchmark set*
is spectral/mandelbrot moving toward parity, not a blanket 2× everywhere.

The i64-word model was a deliberate simplification that made a one-person compiler tractable. Its cost
is that alias-sensitive optimization is off the table until pointer-typed values flow as LLVM `ptr`.

### 2.2 The allocation gap (binary-trees) — ARC per-object cost

**Root cause: naive, unoptimized reference counting.**

Every heap object carries a refcount touched on every `nova_retain` / `nova_release`
(`src/codegen/arc.zig`), and reclamation is per-object. binary-trees allocates ~millions of short-lived
nodes; Nova pays a refcount round-trip and a free per node, where a generational GC (C#, the winner at
0.70×) bump-allocates and sweeps a young generation. Nova emits **no ARC optimization at all** today:
no redundant retain/release elimination, no escape analysis, no stack promotion of non-escaping
allocations. This is the entire 2.22×.

ARC is a legitimate design choice (predictable latency, no GC pauses, clean C/C++ interop — Swift ships
production software on it). It will never beat a tracing GC on an allocation-*pathological*
microbenchmark, but optimized ARC reaches Swift-level: competitive for real workloads and within a
small factor even here.

### 2.3 Non-issues (already at parity)

Scalar arithmetic (nbody, fannkuch) is already competitive — no work needed. `fsqrt` is done.

---

## 3. The plan (ordered by leverage)

### 3.1 ⬜ Pointer representation — flow arrays/pointers as `ptr`, not `i64`+`inttoptr`

**The single highest-leverage change.** Unblocks alias analysis → auto-vectorization + hoisting →
mandelbrot / nsieve / spectral toward parity, and makes `noalias` meaningful.

**Scope it narrowly first — arrays only, not the whole value model.** A full i64→typed conversion of
every value is a large refactor; the perf win is concentrated in array-typed values. Minimal viable cut:

1. `slotTypeForLocalId` returns `ptr` (not `val_type`) for **array-typed** locals/params (name matches
   `T[N]` / the sema `.array` type). Array locals become `ptr` allocas; params become `ptr`.
2. Array element access GEPs the **base `ptr` directly** — delete the `inttoptr` at `arr_base` /
   `arr_store_base`. The base is already a `ptr`; `GEP <elemty>, %base, %i` keeps provenance.
3. Array construction (`[...]`, `[v;n]`) returns the `ptr` from `compileAlloc` without the
   ptr→i64 round-trip; consumers that stored it as i64 now store it as `ptr`.
4. Element loads/stores use the **real element type** (the reverted typed-load change — re-land it here).
5. **`noalias` on distinct array parameters** — mark `ptr` params whose sema type is an array with the
   LLVM `noalias` attribute (safe: a fresh `[v;n]` allocation is unique; two array params are distinct
   objects by Nova's value semantics). This is what lets the vectorizer fire on `c[i]=a[i]*b[i]`.

**Watch:** the seam where an array value crosses into a context that still expects the i64 word (e.g.
stored in a `List`, an `any`, or passed where an i64 is expected). Insert an explicit `ptrtoint` at
exactly those boundaries — do not let the i64 leak back into the hot path.

**Definition of Done:**
- [x] Array slots (locals + params) are `ptr`, not the i64 word (`slotTypeForLocalId`); `coerceToSlotType`
      handles the ptr↔i64 seams. **Part 1 — landed, corpus 254/254 + ASAN green.**
- [x] Array element access GEPs the `ptr` base directly (no `inttoptr`), typed float loads. **Part 1.**
- [x] Array params flow as `ptr` in the signature (caller inttoptr's at the call via existing arg
      coercion). **Part 1.** (No `noalias`: unsound if the same array is passed to two params.)
- [ ] **Part 2 (the payoff, remaining): array construction must return a real `ptr`.**
      `nova_bytes_alloc` is declared to return the i64 word, so `[v;n]` / `[...]` produce a laundered
      pointer (`inttoptr(ptrtoint(malloc))`), which LLVM treats as provenance-less — so even with `ptr`
      slots the loop does **not** vectorize (verified: a Nova saxpy stays scalar). Fix: declare the
      array allocation path to return `ptr` (or add an array-specific `ptr`-returning alloc), and update
      the array-literal/repeat codegen to GEP element stores from that `ptr` instead of `inttoptr`+add.
      This ripples to every `compileAlloc` caller (tuples, boxes, structs) via `coerceToSlotType`, so it
      is the large, careful part — do it as its own gated change.
- [ ] `double[]` loops (saxpy) then auto-vectorize (`otool -tv` shows `.2d` in the loop body).
- [ ] spectral-norm, nsieve, mandelbrot re-measured (note: spectral's division-heavy inner loop and
      mandelbrot's byte buffer won't vectorize regardless; the clean win is on elementwise float kernels).
- [ ] Corpus green, ASAN-clean, ARC gate unchanged.

- [x] **Part 2 landed** — array construction returns a real `ptr` (`nova_array_alloc`), element stores
      GEP from it. Provenance is now pure ptr from alloc → slot → access.
- [x] **Auto-vectorization enabled** — the release pass pipeline set neither loop nor SLP vectorization
      (C PassBuilder API defaults them OFF), and the TargetMachine used CPU `"generic"` (pessimistic
      cost model). Now: `SetLoopVectorization`/`SetSLPVectorization(1)` + host CPU/features on native.
- [x] **i0 zero-init bug fixed** — local slot zero-init did `LLVMConstInt(ptr_ty, 0)` → invalid `i0 0`
      (exposed by the new ptr slots), which poisoned the optimizer. Now `ConstNull` for ptr/vector slots.
- [x] `double[]` loops **auto-vectorize** — a Nova poly/saxpy kernel emits `.2d` NEON vector ops; a
      compute-bound poly kernel is **~7× faster** (51 ms vs 357 ms scalar). Corpus 254/254, ASAN-clean.
      Case `262_array_vectorization`.

**Tracking:** ✅ Part 1 + Part 2 + auto-vectorization landed. Array float loops with **i64 counters**
vectorize and run ~7× the scalar version. Corpus 254/254 + ASAN clean.

**One follow-on remains for the benchmark set:** an **i32 loop counter** (`let i = 0`, Nova's default
`int`) updates via a `sext i32→i64` in the induction variable, which defeats LLVM's scalar-evolution so
the loop won't vectorize. `let i: long = 0` sidesteps it and vectorizes today. The general fix is F3-5
(honest i64 loop counters / eliminate the IV sext) — that would make `int`-counter array loops vectorize
without the annotation, which is what most of the benchmark kernels (spectral, nsieve) use.

**Root-cause note discovered while implementing:** the provenance chain must be *pure `ptr`* from the
allocation through the slot to the GEP — any `ptrtoint`/`inttoptr` round-trip in between launders the
pointer and LLVM's alias analysis gives up. Part 1 made the slot/param/access ptr-clean; the allocator
return type is the last laundering site.

**Part 2 precise shape (verified against the runtime).** `nova_bytes_alloc` returns `long long` (i64),
not a pointer (`src/runtime/alloc.cpp`, `nova_abi.h`) — the address is an integer at the C boundary. Two
ways to get a provenance-carrying `ptr` for array construction:
  1. **Scoped (recommended):** add `void* nova_array_alloc(long long)` to the runtime (`return (void*)nova_bytes_alloc(n)`),
     declare it `ptr @nova_array_alloc(i64)` in codegen, and route ONLY the array-literal / `[v;n]`
     codegen through it (GEP the element stores from the returned `ptr`, return the `ptr`). Non-array
     `compileAlloc` callers (tuples, boxes, structs) are untouched. Smallest blast radius.
  2. **ABI-compat hack:** redeclare `nova_bytes_alloc` itself as `ptr`-returning — works on arm64/x86-64
     (pointer and `long long` share the return register) but ripples to every `compileAlloc` caller and
     is not portable. Avoid.
Either way this is a focused, gated change (runtime rebuild + array-literal codegen + full corpus/ASAN),
not a one-liner — do it deliberately, not at the tail of an unrelated session.

### 3.2 ⬜ ARC optimizer — redundant retain/release elimination + escape analysis

Closes the binary-trees / allocation gap. Precedent: Swift's ARC optimizer removes the large majority
of naive refcount traffic. Ordered sub-steps, cheapest first:

1. **Redundant retain/release elimination** — a `retain` immediately followed by a `release` on the same
   SSA value within a block (and the CFG-extended version) cancels. Nova's ownership pass
   (`src/sema/` ownership + `src/codegen/arc.zig`) already tracks per-edge drops; add a local peephole
   that cancels balanced pairs before emission.
2. **Non-escaping stack promotion** — an object whose reference provably never escapes its creating
   frame (not returned, not stored to the heap, not captured) can be stack-allocated and skip ARC
   entirely. binary-trees' transient trees are the model case. Needs a conservative escape analysis
   over the typed IR.
3. **(Optional) young-object arena** — bump-allocate short-lived objects from a per-frame arena reset on
   return, sidestepping per-node `free`. Bounded to a scope where escape analysis proves safety.

**Definition of Done:**
- [ ] binary-trees re-measured; target ≤ 1.5× the fastest peer (from 2.22×).
- [ ] ARC gate + ASAN green (no new leaks/UAF — this is the load-bearing invariant).
- [ ] `NOVA_ARC_AUDIT` shows reduced retain/release counts on an allocation microbench.

**Tracking:** _pending_

### 3.3 ⬜ (Follow-on) register allocation for array-resident scalars

After §3.1, confirm the loop accumulator and loop-invariant array bases are register-promoted (mem2reg
+ LICM). If a residual gap remains on the division-heavy spectral inner loop, investigate hoisting the
`evala` integer computation and the int→double conversion. Likely small; measure before investing.

**Tracking:** _pending_

---

## 4. Non-goals / honest scope

- **Not converting the entire i64 value model.** §3.1 is scoped to array-typed values, where the perf
  lives. A global typed-value-model rewrite is out of scope unless a later benchmark demands it.
- **Not beating a tracing GC on allocation-pathological microbenchmarks.** Optimized ARC targets
  Swift-level (competitive for real workloads), not GC-parity on binary-trees-style churn.
- **Perspective:** Nova's target is I/O-bound server services (the reactor sustains ~75k req/s); these
  compute microbenchmarks measure *codegen maturity*, not the shipping workload. This plan exists
  because raw-compute parity was made an explicit goal, not because the current numbers block Nova's
  purpose.

---

## 5. Verification protocol (every phase)

1. Re-run `lang/bench/` (all six benchmarks + the SIMD kernel), best of 10, absolute ms; update
   `lang/bench/benchmark.md`.
2. Full corpus green: `conformance/run.sh -j`.
3. ASAN-clean: `NOVA_ASAN=1 zig build` then the targeted `--asan` cases (mandatory — the array/ARC
   changes touch memory).
4. ARC gate unchanged or improved.
5. Record the before/after ms in the phase's Tracking line, with the commit SHA.
