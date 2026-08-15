# Optimiser direction — SCRAP the LLVM-emit optimiser, go Swift-SIL (ARC-semantic) — DECISION 2026-08-16

## Decision

The HIR/MIR/LIR **LLVM-emit optimiser is SCRAPPED** and moved to `discards/optimiser-2026-08-16/`. The
codebase now compiles Nova the way it always actually did: **AST backend → LLVM (`default<O3>` in release)**.
Future optimisation work follows the **Swift-SIL model**, not the current one.

## Why (the evidence that forced this)

Measured + confirmed 2026-08-16 (see `lastlap/gap3-optimiser.md`, kept for the record):

1. The whole LLVM module gets `default<O3>` + vectorization in release (`declarations.zig:1337`), for BOTH
   the AST path and the (now-removed) emit path.
2. So the emit optimiser's generic passes — mem2reg / constfold / copyprop / dce / inline / simplifycfg —
   are **redundant with LLVM O3**. They changed nothing about the shipped binary.
3. The ONLY thing an in-house optimiser can do that LLVM cannot is **ARC-semantic optimisation** (LLVM sees
   `nova_retain`/`nova_release` as opaque calls it must not touch). The emit optimiser's one such pass,
   `arc_elision`, fired **0/44** — it only cancels *adjacent balanced* pairs, and the threading is already
   tight, so it will fire ~0 even at 100% coverage.
4. Net realised optimisation from the emit optimiser = **0**. Coverage work (B6/B7/closures/async) only
   widened a path that buys nothing.

## What Zig taught us (why this is the right call)

Zig's pipeline is `ZIR → Sema → AIR → Liveness → backend`. Zig **deliberately does NOT reimplement LLVM's
optimisations in AIR** — AIR is a lowering target; in release Zig hands it to LLVM and lets LLVM optimise.
Zig built its OWN backends (x86_64/aarch64/wasm) for **compile speed** (skip slow LLVM in debug), accepting
WORSE codegen — a different goal from runtime perf. Zig has no ARC, so it has no analog to Nova's real
perf lever. Conclusion: the two justifiable reasons to own an IR/backend are (a) **runtime perf via
semantic passes LLVM can't do** — for a refcounted language that is **Swift-SIL-style ARC optimisation** —
or (b) **compile speed via a self-hosted non-LLVM backend** (Zig's reason). The scrapped optimiser was
neither: it duplicated LLVM (no runtime win) and added compile time (no speed win).

## The Swift-SIL approach (the new plan)

Swift's SIL is a typed, ownership-aware IR sitting BEFORE LLVM, whose entire reason to exist is the
optimisation LLVM cannot do: **ARC optimisation** (retain/release elision, ownership forwarding). Nova's
version, minimal and perf-first:

1. **Borrow/escape analysis on a typed IR with explicit retain/release.** Seed exists: `src/frontend/sema/
   escape.zig` (currently report-only) + the ARC threading that lived in `lower_ast_hir.zig` (preserved in
   discards for reference). The analysis answers: for each owned value, does it ESCAPE (stored to a
   persistent sink / returned / captured) between its retain and its release, or is it only BORROWED
   (read, passed to a non-consuming callee)? A retain/release pair around a borrow-only region is removable.
2. **`arc_elision` becomes `borrow-skip`**: remove retain/release when the value provably does not escape
   between them. This is the ONE thing LLVM can't do and the ONLY source of a real perf delta.
3. **PROVE IT FIRST.** Run it on a MINIMAL set of ARC-heavy functions and **measure a perf delta (E2) on a
   real workload BEFORE any coverage work.** If the number does not move, the whole idea is unjustified and
   ARC optimisation should be scrapped too — not expanded. This is the standing go/scrap gate.
4. Only after a measured win: decide how much of the language the ARC pass must see (coverage), driven by
   where the ARC churn actually is (per-request allocations — see the perf notes), not by completeness.

**Standing decision rule for any future optimiser work:** NO coverage / breadth work until an ARC-semantic
pass shows a measured perf delta over AST+LLVM O3. Motion on coverage is not progress on perf.

## What was removed vs kept

- REMOVED → `discards/optimiser-2026-08-16/`: `src/optimiser/` (hir/mir/lir + lowering + passes + driver +
  verifier) and `src/backend/codegen/lir_emit.zig` (the emit path). Wiring removed from declarations.zig,
  builder.zig, tester.zig, cli.zig, root.zig. `NOVA_OPT` / `NOVA_OPT_EMIT` env vars are gone.
- KEPT: `src/frontend/sema/escape.zig` (the SIL borrow-analysis seed) and `src/frontend/sema/shadow.zig`
  (that is the string→TypeId SOUNDNESS gate + `renderLegacy`, NOT the optimiser — used across codegen).
- The compiler is unchanged in observable behaviour: it already compiled everything via the AST path; the
  emit path was off by default and a no-op on the binary.
