# OSSA-lite — small-task breakdown (2026-08-16)

Derived from the Swift-SIL comparison (`swift-arch-comparison.md`) and the table the user pasted.
The table's rows map to three tracks. Ordered by VALUE and by what is buildable NOW.

Standing rule (from `sil-arc-optimiser-direction.md`): the perf half (Track A) may not add breadth
until an ARC-semantic pass shows a MEASURED perf delta. The soundness half (Track V) stands on its own
and is the highest-value item — it converts "ASAN-tested safe" into "compile-time verified safe".

## Grounding facts (verified 2026-08-16, not assumed)
- `src/frontend/sema/ownership.zig` (532 LOC) — a move/use-after-move BALANCE check over AST+TypedIr.
  Computes `balance_violations`, `deferred_cfg`, `deferred_untyped`, drop/move/dup ops. REPORT-ONLY today.
- It is ALREADY wired to a build gate — `shadow.zig:560` exits(1) on `balance_violations>0` OR unaccounted
  temporaries — but ONLY when the `NOVA_SEMA_SHADOW` report path runs. Not a standalone verifier.
- `src/frontend/sema/escape.zig` (431 LOC) — interprocedural may-escape analysis, report-only. = borrow seed.
- `discards/optimiser-2026-08-16/src/optimiser/{mir.zig(358),verify.zig(97),arc_elision.zig(208)}` — a
  reusable typed-SSA + a verifier skeleton + the (0/44-firing) ARC pass. Salvage, don't resurrect wholesale.

## Track V — ownership VERIFIER (soundness). Buildable now. HIGHEST VALUE.
- [x] **V1** DONE. Extracted the move-check into a standalone `verify()` (structured diagnostics) +
      `runVerify()` reporter in `ownership.zig`, wired opt-in via `NOVA_OWN_VERIFY` in builder.zig+tester.zig.
      Pure refactor; `analyze()` behaviour identical; build clean; shadow gate still runs; sample case green.
- [x] **V2** DONE (report wired + measured). `NOVA_OWN_VERIFY=1` runs report-only; `=hard` fails the build.
      Corpus sweep: 0 violations everywhere. BUT — see the load-bearing finding below — that 0 is VACUOUS.

### ⛔ LOAD-BEARING HONEST FINDING (2026-08-16) — the move-check is vacuous, and it is the WRONG property
Proven at the code level, not assumed:
1. **The move-checker structurally cannot report a use-after-move.** `St.moved` is produced as a
   fallthrough state ONLY at `ownership.zig:399` inside `mergeIf`, which requires an already-`.moved`
   input branch. The walk always ENTERS at `.live` and NO base transition sets `.moved`, so by induction
   `.moved` is never produced and every `state == .moved` violation check is dead code. "0 violations" =
   "the check never fires", NOT "proven safe". Reporting it as a soundness result would be an overclaim.
2. **A move / use-after-move verifier is the WRONG property for an ARC language.** Nova is
   reference-counted, not affine, and has NO move-only / noncopyable types. `let y = x` retains; a later
   use of `x` is safe by construction (the dup comment at `ownership.zig:242` says exactly this). Swift's
   OSSA move-verifier matters because Swift has `owned`/consuming/noncopyable values where use-after-consume
   IS a bug. Nova has none, so there is nothing for a move verifier to prove. This is not a bug to fix in
   the walk; it is the wrong verifier.
3. **The temp-accounting half is a pass-COVERAGE self-check, not a balance proof.** `accounted==total`
   means the walk VISITED every owned temporary; the move/drop labels are assigned by syntactic position
   and never checked for exactly-once release. It proves nothing about leaks or double-frees.

### Corrected Track V — the property that IS meaningful for Nova = ARC RELEASE-BALANCE
The Nova memory hazards are leak / double-free / UAF from UNBALANCED codegen retain/release (the
string→TypeId class), NOT source-level use-after-move. So the meaningful OSSA-lite verifier proves:
**every owned value (local + temporary) is released exactly once on every control-flow path** — matching
the retain/release codegen (`arc.zig`) actually inserts. That is a real, non-vacuous, ARC-appropriate
soundness property, and NEITHER existing analysis proves it.
- [ ] **V3'** Define the ARC-balance property precisely against what `arc.zig` emits (retain on
      acquire/dup, release on scope-end/consume). Enumerate the acquire/consume sites per owned value.
- [ ] **V4'** Build a per-path balance checker on the typed IR (not the syntactic move-walk): for each
      owned SSA value, prove acquires == releases on every path; flag any imbalance (leak or double-release).
      This is the OSSA-lite verifier and converges with Track I's I3.
- [ ] **V5'** expect_fail case = a program `arc.zig` would MIS-balance (e.g. a known string→TypeId shape),
      confirm the balance checker rejects it; clean corpus passes. THEN consider default-on.
- Note: keep `NOVA_OWN_VERIFY` infra (V1/V2) — the structured-diagnostic + reporter plumbing is reused by
  V4'. Only the PROPERTY being checked changes (from the dead move-walk to real ARC-balance).

## Track I — ownership IR (OSSA-lite). Needed for Track A, NOT for Track V.
- [ ] **I1** Salvage `mir.zig` as `src/frontend/sema/ossa/ir.zig` — typed-SSA value/op types ONLY, compile-gated,
      unused. Verify: builds.
- [ ] **I2** Minimal SILGen: lower ONE straight-line function body into the OSSA IR with explicit
      retain/release/borrow ops, seeded from ownership.zig (moves/drops) + escape.zig (borrows). Report-only.
- [ ] **I3** OSSA VERIFIER on the IR (salvage `verify.zig`): every value consumed exactly once; no
      use-after-consume. This is the IR-level restatement of Track V; converges with V4.
- [ ] **I4** Extend SILGen coverage function-by-function until it matches the AST codegen's ARC decisions
      (cross-check against `NOVA_ARC_AUDIT`). Each function = one verified slice.

## Track A — ARC optimisation (perf). GATED on measured delta. LOWEST priority.
- [ ] **A1** borrow-skip / release-sink pass on the OSSA IR (the one non-redundant-with-LLVM opt).
- [ ] **A2** MEASURE perf delta vs AST+LLVM-O3 on a real bench. If it does not move, STOP — perf half unjustified.

## Where NOT to spend effort (from the Swift comparison)
- Generic specializer, devirt, exclusivity, ~90 other SIL passes — LLVM O3 + mono already cover these.
- Re-lowering for LLVM (the scrapped B6/B7/closure/async emit work) — WRONG layer, already scrapped.
