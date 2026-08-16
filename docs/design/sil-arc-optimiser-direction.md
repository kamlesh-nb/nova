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

## E2 gate MEASURED (2026-08-16) — peephole borrow-skip has ~0 headroom; the lever is ownership-forwarding

Per the standing rule (measure before building), an ARC-traffic census was added (`arc.zig`, opt-in via
`NOVA_ARC_CENSUS`; runs around the elision call in `declarations.zig`). It counts nova_retain/nova_release
sites before/after elision, plus borrow-skip CANDIDATE pairs by two definitions (analysis-only, nothing
removed). Measured across the full stdlib + test corpus (~1530 defined functions, ~1645 ARC calls):

- current M-5 `elideBorrowedArc` removes **0** on these programs (0% of raw traffic);
- borrow-skip candidates, **intra-block** (retain→borrow-only-uses→release in one block): **0**;
- borrow-skip candidates, **function-scope / inter-block** (a retained SSA value whose every use is a
  borrow — load / call-argument / compare — plus exactly one release): **0**;
- unchanged with `NOVA_ARC_ELIDE_OFF=1`, so M-5 is not hiding candidates.

**Reading:** Nova's ARC traffic is GENUINE OWNERSHIP, not redundant borrow pairs. A retain is a
dup/acquire whose value is then STORED into an owned slot/field and released at scope end, with the value
LIVE (owned, used via loads of the slot) in between — not a borrow-only region. So a cheap
peephole/direct-SSA borrow-skip pass (the E2 candidate) would remove ~0 and move perf ~0.

**Honest caveat:** the counters treat a store-into-local-slot as an escape, so they do NOT judge the
slot-stored ownership pattern; deciding whether THAT is borrow-only needs slot-level borrow analysis =
the OSSA borrow pass itself. So the precise verdict is: **the cheap peephole borrow-skip is ruled out
(0 headroom); the only remaining lever is OWNERSHIP-FORWARDING** (convert an owned binding into a borrow
where no callee consumes it), which requires the full typed-ownership IR + borrow analysis (Track I/V).

**Gate outcome:** the peephole perf half stays SCRAPPED (0 measured headroom). The real perf lever
converges with the SAME OSSA-lite ownership IR as the soundness verifier — i.e. Gap-3-perf and Gap-1-
soundness are one investment, exactly the reframing. Do NOT build a borrow-skip peephole; if perf is
pursued it must be ownership-forwarding on the OSSA IR, still gated on a measured runtime delta.

## Track A ownership-forwarding MEASURED on the OSSA IR (2026-08-16) — also ~0 headroom, PERF HALF CLOSED

After the OSSA-lite ownership IR + verifier landed (Track I, ~87% coverage), the perf half was re-measured
on the IR itself (`ossa/forward.zig`, reported via NOVA_OSSA). The clearest OSSA-level forwarding pattern
is a REDUNDANT COPY: an owned dup (`let y = x`, which retains) whose result is only borrowed and then
destroyed, never moved out or returned — its +1 is dead weight a forwarding pass could elide.

Measured across the corpus: **owned-dup copies emitted = 0**, hence forwardable candidates = 0. Real Nova
code essentially never creates a redundant owned ALIAS; owned bindings are fresh births (`let y = expr`),
stores into owned slots/fields, or genuine transfers — not `let y = x` dups that are merely borrowed. The
forward.zig detector is unit-tested to fire on constructed IR (a copy-only-destroyed IS flagged; a copy
returned or moved is NOT), so the 0 is a real measurement, not a dead check.

**Two independent measurements now agree there is no ARC-elision headroom:**
- E2 (LLVM level): 0 borrow-skip candidates — the retain/release traffic is retain-for-store into
  genuinely-owned slots/fields, which the callee needs.
- Track A (OSSA level): 0 redundant-copy candidates — no forwardable owned aliases.

**DECISION: the ARC-optimisation perf half is CLOSED (scrapped), not merely deferred.** Nova's ARC cost is
the fundamental per-object retain/release for values that are genuinely owned; forwarding cannot remove it.
The real per-core perf lever is REDUCING THE ALLOCATION COUNT (per the perf notes: ~3000 ARC objects per
request vs ~50 for Rust) — an ARCHITECTURAL lever (arena / value types / fewer per-request allocations,
partly explored in P7), NOT an ARC-semantic pass on any IR. The OSSA IR's justified, delivered value is the
SOUNDNESS verifier (Track V/I), not perf. This is the honest, final answer to "is there an in-house ARC
optimisation worth building": no.
