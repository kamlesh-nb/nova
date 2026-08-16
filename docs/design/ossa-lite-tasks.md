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
- [~] **V4'** IN PROGRESS — slice 1 built. `arc.zig:verifyArcBalance` runs on the RAW codegen module
      (before LLVM -O), gated by NOVA_OWN_VERIFY (=hard fails). For each alloca slot it PROVES
      non-escaping + owned, it checks acquires==releases. Findings, verified empirically:
      - It FIRES (non-vacuous): the first cut reported 31/31 checkable slots imbalanced — the
        `acquires != releases` branch is reachable, unlike the dead move-check. That was a real
        false-positive (a retained value stored into a local slot ALSO escaped via `ret %sv`); fixed
        with `storedValueStaysLocal` (the stored value's only uses must be retain/store/compare).
      - After the fix: 0 false positives, 0 crashes on the corpus — BUT **checkable slots ≈ 0**. Slice 1
        only recognises an owned value that enters a slot via `nova_retain` AND stays purely local. That
        intersection is nearly empty in real code: a fresh `List.new()` local is born +1 by the ALLOCATOR,
        not via nova_retain, so it is not counted; borrowed/dup values that stay local are rare.
      - CONCLUSION (the real V3' prerequisite, now proven concrete): a balance verifier with useful
        coverage MUST recognise every OWNED-PRODUCTION site — allocator births, constructor returns,
        retained borrows — i.e. the ownership-production catalog. That catalog IS V3', and building it is
        the genuine multi-session core (matches the Swift-scale honesty). Slice 1 is committed as SOUND,
        ZERO-FALSE-POSITIVE, opt-in scaffolding whose coverage is ~0 until V3' lands. It never blocks a
        clean build (0 checkable -> 0 imbalance).
      - NEXT SLICE (V3'/V4' slice 2): recognise fresh owned allocations as +1 acquires (map the runtime
        allocator call shape to an owned birth), which is where real coverage starts.
- [ ] **V5'** expect_fail case = a program `arc.zig` would MIS-balance (e.g. a known string→TypeId shape),
      confirm the balance checker rejects it; clean corpus passes. THEN consider default-on.
- Note: keep `NOVA_OWN_VERIFY` infra (V1/V2) — the structured-diagnostic + reporter plumbing is reused by
  V4'. Only the PROPERTY being checked changes (from the dead move-walk to real ARC-balance).

## Track I — ownership IR (OSSA-lite). The SHARED substrate for BOTH gaps (verifier + ownership-forwarding).
- [x] **I1** DONE. Purpose-built minimal ownership IR at `src/frontend/sema/ossa/ir.zig` (NOT a salvage of
      the emit-optimiser's general mir.zig — that modelled arithmetic; this models ONLY ownership).
      Value/Block/Ownership{trivial,owned,borrowed}; ownership-event ops make_owned/make_trivial/copy/
      borrow/destroy/move_out/borrow_use/end_borrow; Terminator; Func builder. `consumesOperand()` is the
      single consumption classifier both later passes share. INVARIANT (for I3): every owned value is
      consumed exactly once per path. Wired into root.zig test aggregation; 3 unit tests PASS (verified by
      deliberate-break: pass 104->103). Compiler builds clean; corpus green. Not yet produced/checked.
- [ ] **I2** Minimal lowering (SILGen): produce the OSSA IR for ONE straight-line function from Nova source,
      seeding owned-births/copies/destroys from codegen's ARC decisions + borrows from escape.zig. Report-only.
      NOTE: this is where the V4' blocker is solved — codegen KNOWS ownership; lowering records it as IR
      events (make_owned/copy/destroy) instead of reverse-engineering from LLVM IR shapes.
- [ ] **I3** OSSA VERIFIER on the IR: every owned value consumed exactly once; no use-after-consume; no
      double-consume. IR-level restatement of Track V; this is the REAL, non-vacuous soundness verifier.
- [ ] **I4** Extend lowering coverage function-by-function until it matches AST codegen's ARC decisions
      (cross-check `NOVA_ARC_AUDIT`). Then ownership-forwarding (Track A) becomes possible ON this IR.

## Track A — ARC optimisation (perf). GATED on measured delta. LOWEST priority.
- [ ] **A1** borrow-skip / release-sink pass on the OSSA IR (the one non-redundant-with-LLVM opt).
- [ ] **A2** MEASURE perf delta vs AST+LLVM-O3 on a real bench. If it does not move, STOP — perf half unjustified.

## Where NOT to spend effort (from the Swift comparison)
- Generic specializer, devirt, exclusivity, ~90 other SIL passes — LLVM O3 + mono already cover these.
- Re-lowering for LLVM (the scrapped B6/B7/closure/async emit work) — WRONG layer, already scrapped.
