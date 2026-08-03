# Nova — Compute Benchmark Results

Cross-language comparison of **Nova** against **Rust**, **Go**, and **C#** on six algorithms from the
[Programming Language Benchmarks](https://programming-language-benchmarks.vercel.app/) suite.

Every implementation is a **scalar, single-threaded** port of the *same* algorithm. Every Nova program
prints the reference *golden* output byte-for-byte (or agrees with all three peers). Times are the
**best of 10 wall-clock runs** on an Apple M1, all release builds. Numbers are milliseconds.

---

## Results (absolute wall-clock, milliseconds — lower is better)

| Benchmark | Rust | Go | C# | **Nova** | Fastest peer | **Nova vs fastest** |
|---|---:|---:|---:|---:|---|---:|
| nbody (N=1M) | 28.9 | 75.1 | 81.8 | **29.1** | Rust 28.9 | **1.01× slower** |
| fannkuch-redux (n=11) | 2061.6 | 1938.1 | 1973.1 | **1916.1** | *Nova* | **fastest** |
| mandelbrot (1600²) | 267.9 | 233.9 | 305.0 | **269.1** | Go 233.9 | **1.15× slower** |
| nsieve (160k ×400) | 259.9 | 264.7 | 300.4 | **353.2** | Rust 259.9 | **1.36× slower** |
| spectral-norm (N=1000) | 38.2 | 39.9 | 68.3 | **55.0** | Rust 38.2 | **1.44× slower** |
| binary-trees (depth 16) | 276.0 | 270.4 | 193.7 | **429.4** | C# 193.7 | **2.22× slower** |

**Bottom line: Nova is competitive on 2 of the 6 (nbody, fannkuch) and slower on the other 4** — by
1.15× to 2.22× against the fastest peer for each benchmark. It is not, in general, as fast as Rust/Go/C#.

---

## Where Nova is, honestly

**Competitive (≈ within noise):**
- **nbody** — 29.1 ms vs Rust's 28.9 ms. Scalar floating-point loop; essentially tied once `fsqrt` was
  lowered to the hardware `llvm.sqrt.f64` intrinsic (it was ~20× slower before that fix).
- **fannkuch-redux** — 1916 ms, marginally the fastest of the four. Integer array permutation with no
  allocation; all four land within ~7% of each other.

**Slower (1.15×–1.44×):**
- **mandelbrot** (1.15× vs Go) — scalar-double escape math into a bit-packed buffer. Go edges ahead via
  FMA contraction; Nova and Rust are within noise of each other but both behind Go here.
- **nsieve** (1.36× vs Rust) — boolean sieve over a fixed array.
- **spectral-norm** (1.44× vs Rust) — dense float array with a division-heavy inner loop. The array-loop
  cost is the recurring theme: Nova round-trips values through heap array slots where Rust/Go keep them
  in registers.

**A lot slower:**
- **binary-trees** (2.22× vs C#) — allocation churn. Nova's ARC (reference counting) is correct and
  ASAN-clean, but per-node inc/dec/free is far more expensive than C#'s generational GC (the outright
  winner here) or even Rust `Box` / Go GC (both ~270 ms vs Nova's 429 ms). **Allocation-heavy code is
  Nova's clear weak spot.**

---

## SIMD (a separate, self-referential result)

Nova gained an explicit `f64x4` vector type (LLVM `<4 x double>`). On a dot-product kernel:

| | time | |
|---|---:|---|
| Nova — scalar loop | 384 ms | baseline |
| **Nova — f64x4 SIMD** | **98 ms** | **~4× faster than its own scalar** |

This is a **self-comparison** (Nova-SIMD vs Nova-scalar), *not* a win over the peers: a hand-vectorized
Rust/C# version would also be ~4×. The honest claim is only that Nova now *has* usable, deterministic
SIMD and it delivers the expected 4× lane parallelism.

---

## Why Nova trails (the specific costs)

1. **Array access goes through the heap.** Fixed arrays (`double[N]` etc.) store values inline with
   direct indexed load/store, but the hot value still round-trips to memory each iteration where a
   register-allocating backend keeps it in a register. This is the 1.15×–1.44× on the array benchmarks.
2. **ARC pays per object.** Every heap object carries a refcount touched on every retain/release, and
   freeing is per-node. For allocation-churn workloads (binary-trees) this is 2×+ a generational GC.
3. **No auto-vectorization.** Nova doesn't emit `noalias`, so LLVM won't auto-vectorize array loops;
   SIMD requires the explicit `f64x4` type.

None of these are wrong answers — Nova is *correct* everywhere (golden-output match, ASAN-clean) — but
it is genuinely slower than mature toolchains on most of this set today.

---

## Method & environment

| | |
|---|---|
| Machine | Apple M1 · 8 cores · macOS 15.6 (arm64) |
| Rust | rustc 1.93.1 · `rustc -O` |
| Go | go 1.26.0 · `go build` |
| C# | .NET 9.0.116 · Release (server GC for binary-trees) |
| Nova | 0.1.0 · `nova <file>.nova --release` |
| Timing | best of 10 wall-clock runs, milliseconds |

Each benchmark folder holds the four source files (`*.nova`, `*.rs`, `*.go`, `cs/`) and the reference
golden output. Ratios are Nova divided by the *fastest peer* for that row.

---

## What changed this pass

Nova began this effort unable to hold floats in its generic container. The work that moved it from
"float containers miscompile" to "competitive on 2 of 6, slower on the rest":

1. **`List<double>` fix** — a `double` closure argument miscompiled (LLVM verify failure).
2. **Hardware `fsqrt`** — `math.fsqrt` → `llvm.sqrt.f64` intrinsic (nbody: ~20× → ~1×).
3. **Fixed primitive arrays** — `T[N]` mutation, `.length`, `[value; count]` sizing, typed-GEP access
   (array benchmarks: ~19× on `List<double>` → ~1.4× on fixed arrays).
4. **`f64x4` SIMD** — explicit vector type (~4× over Nova's own scalar).

The remaining gaps — register allocation for array values, ARC cost under churn, auto-vectorization —
are the next targets if the goal is to close on Rust/Go/C#.
