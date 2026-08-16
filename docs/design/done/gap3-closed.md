# Gap 3 (optimiser / ARC-semantic perf) — CLOSED (2026-08-16)

Final decision of record. Gap 3 was "the optimiser": build an in-house IR + passes to make Nova faster than
what LLVM alone produces. It is **closed as resolved** — not deferred — on the strength of two independent
measurements. Do not reopen an in-house optimiser without a measured perf delta over AST+LLVM-O3.

## What Gap 3 was
The `last-lap-of-gaps` register (now archived) framed Gap 3 as the HIR/MIR/LIR LLVM-emit optimiser, whose
perf goal was "~0% realized". The reframing (`swift-arch-comparison.md`) then established that Gap 3 (perf)
and Gap 1 (soundness) were ONE gap — "no ownership IR". This doc closes the PERF half; the SOUNDNESS half
is closed separately by the shipped ownership verifier (`ossa-lite-tasks.md`, gated in CI).

## The decision + evidence
1. **The in-house LLVM-emit optimiser was SCRAPPED** (commit 57da4cf → `discards/optimiser-2026-08-16/`).
   Reason: the whole module already gets LLVM `default<O3>` + vectorization on both the AST and the emit
   path (`declarations.zig:1347` — `passes = is_release ? "default<O3>,globaldce" : "default<O0>,globaldce"`),
   so the optimiser's generic passes were redundant with LLVM and byte-identical on the shipped binary. Its
   one non-redundant pass (arc_elision) fired 0/44. Net realized optimisation = 0.
2. **The only thing LLVM cannot do is ARC-semantic optimisation** — eliding retain/release LLVM must treat
   as opaque. Two independent measurements both found ~0 headroom for it:
   - **E2 — LLVM level** (`arc.zig` census, `NOVA_ARC_CENSUS`): borrow-skip candidates = **0** intra-block
     AND **0** function-scope, across the whole stdlib. Nova's ARC traffic is genuine ownership
     (retain-as-dup → store into an owned slot → scope-end release, value live between), not redundant
     borrow pairs.
   - **Track A — OSSA level** (`ossa/forward.zig`, `NOVA_OSSA`): owned-dup redundant copies = **0**,
     forwardable = **0**, across the corpus. Real Nova code does not create redundant owned aliases.
   Re-verified fresh 2026-08-16 on `13_serde` (7929 ARC calls): current elision removes 0% of traffic;
   borrow-skip 0/0; forwarding 0/0.

## Why this is a real close, not a punt
Nova's ARC cost is the FUNDAMENTAL per-object retain/release of genuinely-owned values — the callee needs
its own +1 when it stores, the returned value carries its +1 to the caller. An ARC optimiser cannot remove
that; forwarding/borrow-skip only remove REDUNDANT refcount traffic, of which there is essentially none.
LLVM O3 already gives Nova competitive scalar/loop/vectorized codegen (it beats Rust axum and Go net/http
per-core on some benches — see CLAUDE.md throughput tables). So the optimiser was the wrong lever, and there
is no in-house ARC optimisation worth building.

## The remaining perf lever is a DIFFERENT gap (Gap 5), separate + optional
The honest per-core perf lever is **reducing the per-request ALLOCATION COUNT** (~3000 ARC objects/request
vs Rust's ~50), which is ARCHITECTURAL (arena / value types / fewer per-row containers), NOT an ARC-semantic
pass on any IR. That is Gap 5 in `remaining-gaps-design.md`, gated on a measured target (the P7 blanket arena
already regressed 28% and was rolled back). It is intentionally NOT part of Gap 3's closure.

## Verify (reproduce the close)
- `NOVA_ARC_CENSUS=1 nova test conformance/cases/13_serde.nova` → borrow-skip candidates 0/0.
- `NOVA_OSSA=1 nova test conformance/cases/13_serde.nova` → owned-dup copies 0, forwardable 0.
- `grep -n 'passes.*is_release' src/backend/codegen/declarations.zig` → `default<O3>,globaldce` in release.
- Scrapped optimiser preserved at `discards/optimiser-2026-08-16/`; rationale in
  `docs/design/sil-arc-optimiser-direction.md`.

## Standing rule (do not violate)
No in-house optimiser / ARC-semantic pass is to be built unless it first shows a MEASURED perf delta over
AST+LLVM-O3 on a real workload. Motion on coverage is not progress on perf.
