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
- [~] **I2** SLICE 1 DONE — end-to-end lowering + verify on REAL code. `ossa/lower.zig` lowers
      straight-line functions (owned let-locals modelled: make_owned births, copy dups, destroy/ret_owned
      consumes; uses skipped as balance-irrelevant), defers anything with control flow / a local flowing
      into a call/store/return-expr (sound-by-deferral, no wrong lowering). Report via NOVA_OSSA runs
      lower->verify per fn. MEASURED (nova test on a case, ~121 fns): **37 lowered = 30% coverage, all 37
      verified BALANCED, 0 imbalanced**. This is the FIRST run of the real (non-vacuous) verifier on
      actual functions. lower.zig unit test passes; corpus green; no regressions. This solved the V4'
      blocker: ownership comes from sema's TypedIr (ownedOf/isOwnedSafe = codegen's ARC info), recorded as
      IR events, NOT reverse-engineered from LLVM shapes.
      SLICE 2 DONE — if/else control flow. Rewrote the lowering into a recursive CFG builder (Ctx +
      Flow{terminated,fallthrough}, per-path live set cloned into each branch, `Defer` error bubbles up on
      anything unmodelled). Join block allocated LAST so every edge is index-increasing (keeps the
      verifier's topological order valid, no false loop-detection). Branch-declared owned locals + bare
      (non-block) branches + while/for/switch still defer. MEASURED: coverage **30% -> 43%** (37->53 fns),
      still ALL BALANCED, 0 imbalanced; scanned 12 varied cases (struct/enum/closure/trait/option/generic/…)
      = 0 false positives. Unit tests pass.
      SLICE 3 DONE — calls/borrows. KEY: the E2 census showed caller-side call args carry NO retain/release,
      i.e. in Nova's ARC model passing an owned value to a call is a BORROW from the caller (the callee
      retains its own copies; the caller keeps its +1 and drops at scope end). So owned-local-into-call
      needs NO escape.zig consume/borrow distinction — it is always a borrow. The ONLY move is a bare
      `return x`. Lifted the defers: let-init mentioning a local (borrow -> makeOwned/copy), return-expr
      mentioning locals (drop all, ret_void), call expr-stmts (borrow, skip). Still defer only bare-local
      REASSIGNMENT (`x = ...`, drops old value — unmodelled). MEASURED: coverage 43% -> 47%, still 0
      imbalanced; ~18 varied cases scanned (incl closure/serde/json/error/trait) = 0 false positives —
      end-to-end confirmation the E2-derived borrow model is correct. The +4% is modest because most
      remaining defers are LOOPS.
      SLICE 4 DONE — while loops. Two coordinated changes: (1) VERIFIER lifted its loop-deferral — the
      back-edge to an already-processed header must carry a live set EQUAL to the header entry set (a
      forward edge sets/merges; a back edge, i.e. successor already fixed, compares). An inner value left
      live on the back-edge, or an outer value consumed, is a path_imbalance. Two new verifier unit tests
      (balanced loop clean; per-iteration inner leak flagged) prove it non-vacuous. (2) LOWERING builds the
      while CFG (entry->header; header-cond->body/exit; body->header back-edge; exit allocated LAST so only
      the back-edge decreases in index). Body may only BORROW outer locals; a body that declares its own
      owned local defers (needs per-iteration scoping). MEASURED: coverage **47% -> 75%** (58 -> 91 fns),
      still 0 imbalanced; scans over string/list/map/loop/while/serde/closure/trait = 0 false positives.
      SLICE 5 DONE — lexical scoping + for-loops (47%... 75% -> 86%). Replaced the append-only names/vals
      with a proper `Local` list + `lowerBlockScope`: each block (function body, if-branch, loop body) is a
      lexical scope that drops the locals IT declared at fall-through and truncates them. So branch AND
      loop bodies may now declare their own owned locals (dropped at scope end / each iteration) — this
      removed the growth-check defers and made inner-local loops verify (body-exit live == header entry).
      Added C-style for-loops (init var scoped to the loop, dropped after; increment = trivial borrow;
      for-in iterator form still defers). MEASURED: coverage 75% -> **86%** (91 -> 105 fns), still 0
      imbalanced; 10 varied cases (for/while/loop/string/list/map/struct/enum) = 0 false positives. Unit
      test now `resolveLocal` (innermost-shadow). Remaining ~14% defers = switch, destructuring lets,
      for-in iterators, bare-local reassignment, defer-stmt, nested bare blocks.
      NEXT slice-6: switch statements + for-in iterators (element ownership) + destructuring; then I4 is
      effectively met and ownership-forwarding (Track A perf) can be built ON this IR.
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
