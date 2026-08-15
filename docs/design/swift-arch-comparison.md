# Nova vs Swift (swiftlang/swift) — architectural comparison + re-verified genuine gaps (2026-08-16)

Purpose: after scrapping the LLVM-emit optimiser, compare Nova's pipeline against Swift's proven design
and re-derive Nova's GENUINE gaps. Swift facts here are from architectural knowledge of the swiftlang/swift
compiler (SILGen / SIL / OSSA / the SIL optimizer), not a source read; the structural claims are stable.

## 1. The two pipelines side by side

**Swift:**
```
source → Parse → AST → Sema (type check, generics, protocols)
       → SILGen → SIL (raw)                         ← ownership-explicit, Swift-semantic IR
       → SIL mandatory passes (OSSA):  definite-init, ownership VERIFIER, diagnostics, exclusivity,
                                       mandatory (transparent) inlining
       → SIL optimizer (-O):  ARC optimisation (semantic-arc-opts, RR motion), generic specialization,
                              devirtualization, function-signature opts, closure specialization, inlining
       → IRGen → LLVM IR → LLVM -O → machine code
```

**Nova (current, post-scrap 2026-08-16):**
```
source → Parse → AST → Sema (infer/TypedIr, ownership.zig move-check, escape.zig escape analysis)
       → codegen (llvm_codegen: AST → LLVM IR directly; ARC retain/release decided INLINE from TypeIds)
       → LLVM -O3 → machine code
```

## 2. The single architectural difference that matters

**Swift has a dedicated ownership-aware IR (SIL, in OSSA form) between Sema and LLVM. Nova does not.**

Everything else is a consequence of that. In Swift, SIL is where every Swift-SPECIFIC thing happens that
LLVM cannot: ownership is explicit (`copy_value`/`destroy_value`/`begin_borrow`/`end_borrow`, values typed
owned/guaranteed/unowned), a VERIFIER enforces ownership invariants on every function, and the ARC optimizer
+ generic specializer run on it. LLVM then does only the generic low-level optimisation.

In Nova, there is NO such IR. Ownership is ANALYSED in sema (`ownership.zig` = a move/use-after-move balance
check on the AST/TypedIr; `escape.zig` = interprocedural may-escape analysis, report-only) but it is not
MATERIALISED into an IR with explicit ownership instructions, and it does not GATE compilation. ARC
retain/release is then decided ad hoc in codegen (from TypeIds, after the gap-1 cleanup) and handed to LLVM
as opaque `nova_retain`/`nova_release` calls LLVM must not touch.

## 3. What that costs Nova (both gaps share ONE root)

The missing ownership IR is simultaneously the root of what the register called two separate gaps:

- **Soundness (was "gap 1").** Swift's OSSA VERIFIER proves at compile time that there is no use-after-move,
  no leak, no double-consume — every SIL function must pass it or the compile fails. Nova has ownership
  ANALYSIS (ownership.zig) but not an ownership-SSA VERIFIER that gates the build; the actual safety net is
  the **ASAN corpus gate at RUNTIME**. So Nova's memory safety is EMPIRICALLY TESTED (ASAN-clean on the
  corpus), NOT PROVEN. The honest restatement of gap 1: "no live UAF/double-free found by ASAN + the string
  →TypeId shadow agrees" — which is real and valuable, but it is not Swift-grade "verified safe". A program
  outside the corpus with an ownership bug would not be caught at compile time.
- **Perf (was "gap 3").** Swift's ARC optimizer lives in SIL because that is the only place ownership is
  explicit enough to safely remove retain/release. Nova has nowhere to do it — which is exactly why the
  scrapped emit optimiser's arc_elision fired 0× and why LLVM (which can't see through nova_retain/release)
  leaves all the refcount traffic in.

**So gap 1 and gap 3 are not two gaps. They are one: Nova has no ownership IR.** Swift proves that a single
investment — an OSSA-style SIL — closes BOTH: the verifier gives compile-time soundness, and the ARC
optimizer on the same IR gives the perf.

## 4. Where Nova is genuinely OK vs Swift (don't over-scope)

- **Generics:** Nova MONOMORPHISES (specialises every instantiation). Swift can specialise in SIL OR keep
  unspecialised generics behind witness tables. Nova's mono is simpler and adequate — NOT a gap. (It does
  cost code size / compile time, but correctness + perf are fine.)
- **Value semantics:** Nova already lowers value structs inline (Swift-style), done earlier. Fine.
- **Exclusivity enforcement (Swift's `@inout` law-of-exclusivity):** Nova has no `inout`-style exclusivity
  model, so it does not need Swift's exclusivity passes. Not a gap for Nova's semantics.
- **The AST→LLVM backend itself:** solid. LLVM O3 gives Nova competitive scalar/loop codegen for free.

## 5. Re-verified GENUINE gaps (through the Swift lens)

1. **ROOT GAP — no ownership IR (SIL/OSSA analog).** Underlies both:
   1a. **Soundness is tested, not verified.** No compile-time ownership verifier; safety = ASAN corpus gate.
   1b. **No ARC optimisation.** No IR where retain/release can be safely elided ⇒ perf ~0 over AST+LLVM.
2. Everything previously itemised under "gap 3 coverage" (B6/B7/closures/async emit) was work on the WRONG
   layer (re-lowering for LLVM, which LLVM already optimises) and is now scrapped. It is NOT a genuine gap.

## 6. The honest scale + the pragmatic path

Swift's SIL is one of the largest subsystems in any production compiler: SILGen + OSSA + the verifier +
~100 optimisation passes, built by a large team over many years. A full Nova SIL is a multi-YEAR effort and
should NOT be undertaken on faith.

The pragmatic, gated path (matches sil-arc-optimiser-direction.md, now with the soundness payoff made
explicit):

1. **Promote the analysis Nova already has into a minimal ownership IR.** ownership.zig (move-check) +
   escape.zig (escape/borrow) are the seeds. Materialise explicit `retain`/`release`/`borrow` on a small
   typed IR (the scrapped mir.zig in discards is a reusable typed-SSA starting point).
2. **Add an ownership VERIFIER that GATES the build** (OSSA-lite). This alone upgrades gap-1 soundness from
   "ASAN-tested" to "compile-time verified" — the single highest-value slice, and it is a SOUNDNESS win
   independent of perf.
3. **Then the ARC borrow-skip pass on that IR, and MEASURE a perf delta** before any breadth. If the number
   does not move, stop — the perf half is unjustified, but the verifier (step 2) still stands on its own.

**Key reframing this comparison produces:** the SIL direction is not only about perf. Done as OSSA-lite, its
FIRST deliverable is a compile-time memory-safety verifier — which is the honest closure of gap 1 that
"deleting the string decision engine" did NOT provide. That verifier, not more ARC coverage, is the highest
genuine-value item on Nova's whole roadmap.
