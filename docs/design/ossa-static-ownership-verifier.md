# OSSA static ownership verifier — scope

Status: SCOPE (2026-08-20). Goal owner: language soundness. Grounds on existing code (`src/frontend/sema/
ownership.zig`, `src/frontend/sema/ossa/{ir,lower,verify,forward}.zig`) and the V1-V4 / Track-I work
(tasks #194-201). Related: [[nova-value-semantics-completion]] closed the value-semantics escape channels;
this is the next step on the same axis — converting leak/double-free freedom from TESTED to PROVEN.

## Goal

Turn the ownership / ARC-balance check from an **opt-in report** into a **default-on, fail-closed static
guarantee**: a Nova program that compiles is statically proven **leak-free and double-free-free for owned
values** — the property ASAN/ARC currently CATCH at runtime, PROVEN at compile time. This is the
"tested → proven" step vs Rust: instead of "we ran ASAN and it was clean," the compiler rejects any program
whose owned values are not consumed exactly once.

## Current state (measured 2026-08-20)

Three overlapping pieces, all opt-in via `NOVA_OWN_VERIFY` (=1 report, =hard fail on a proven imbalance),
NONE in the default pipeline:

- **`ownership.zig` (V1-V4):** per-path use-after-move + release-balance on owned LET-LOCALS. ~97-98%
  coverage of owned locals across the sampled corpus, 0 accusations. Mature; loops mostly handled.
- **V4' ARC release-balance verifier:** static acquire/release count compared against codegen's ACTUAL
  `arc.zig` emits, on "checkable" (non-escaping + owned-via-retain) slots. VERY LOW coverage (e.g. 1 slot in
  `33_error_union`) but HIGH precision — flags imbalances.
- **`ossa/verify.zig` (I1-I3):** the rigorous linear-ownership IR verifier (leak / double-consume /
  use-after-consume / path-imbalance), non-vacuous (unit-tested on broken IR). SILGen (`lower.zig`) DEFERS
  complex CFG / untyped inits; loops (back-edges) are DEFERRED (reported, never a false positive).

## CORRECTED FINDING (Slice 1 done, 2026-08-20) — the V4' accusations were ALL false positives

Initial hypothesis (that the V4' `hard`-mode accusations might be real leaks) was WRONG and is retracted.
Triage with ARC-audit as ground truth: `33_error_union` / `test_int_payload_round_trips`, `57_mediator_
discovery` / `ServiceProvider_require`, `37_serde_composite_source` / `serde_yaml_stringifyIndent` — all
ARC-audit CLEAN (every object released), ASAN clean. The V4' `verifyArcBalance` is NON-PATH-SENSITIVE: it
sums TOTAL acquires vs TOTAL releases, so a value stored in two exclusive branches and released once at the
merge shows a spurious imbalance. A partial corpus scan found 45+ accused cases dominated by two heavily-used
correct functions (`serde_yaml_stringifyIndent` ×24, `ServiceProvider_require` ×17). **V4' found ZERO real
leaks.** The path-sensitive OSSA verifier (`NOVA_OSSA`) passes all of them (census: 340 cases, **0
imbalanced**).

**Slice 1 fix (committed):** demoted the broken V4' balance verifier to a report (never fails the build) and
routed `NOVA_OWN_VERIFY=hard` to the SOUND path-sensitive OSSA verifier + the sound use-after-move check.
Gate: full corpus under `NOVA_OWN_VERIFY=hard` = 394/397 (only the 3 pre-existing crashes 118/189/42) -> **0
false accusations across all 394 correct cases**.

## Slice 3 done (2026-08-20) — reassign modelled, incl. outer-local-in-branch via owned-value phi

`reassign` (`x = rhs` on an owned local) was the SOLE remaining deferral bucket corpus-wide (break/continue,
switch-guard, nonblock-branch were already 0; loops are handled by the back-edge set-equality check, so the
old "loops deferred" note was stale). Closed in two layers:

- **SILGen (`lower.zig`):** a reassign now lowers to `destroy(old) ; rebind(new)` in ownership order (RHS is
  evaluated while old is still live, then old is dropped, then the slot is rebound to a `copy` of another
  owned local or a fresh `make_owned`). A trivial RHS (`x = null`) marks the slot not-live.
- **Owned-value phi (`ir.zig` `Phi` + `verify.zig` edge application):** when a branch reassigns an OUTER
  local, the two paths carry different owned values for the same variable into the join. `reconcileJoin`
  builds a phi at the join; the verifier MOVES each predecessor's input into the phi on that edge (a consume)
  and the phi result is the single live value at the join. This is the linear-ownership move-merge, and it is
  the same machinery loop-header merges will reuse. Mixed-liveness merges (live on one path, not another)
  still defer — soundly.
- **Still deferred (honest):** an outer-local reassign inside a LOOP body or SWITCH case (guarded by
  `clone_floor`). These need a phi at the loop header / switch join respectively; scoped, not done. Measured
  residue: `92_regex` reassign=1, `271_runtime_mediator` reassign=1 (was 4; the 3 if-branch ones are now
  covered, lowered 569 -> 572).

**Gate:** full corpus under `NOVA_OSSA=hard` = **397/397, 0 proven imbalances** (phi introduced no false
positives). Two `verify.zig` unit tests added (balanced phi-reassign clean; un-consumed phi result flagged as
a leak). Synthetic case: straight-line + branch-local + outer-in-branch reassign all lower, 100% coverage,
ASAN-clean.

## What this verifier IS (honest boundary, restated)

In Nova, ARC is AUTOMATIC — a user cannot create a leak/double-free through ownership mistakes (codegen
inserts retain/release). So this is NOT a Rust-style borrow checker over USER code; it is a **codegen
ARC-balance self-verifier**: it proves the COMPILER's own ARC insertion is balanced (no compiler-introduced
leaks/double-frees) for covered functions. Default-on, it would catch codegen regressions like the P1 UAF at
COMPILE time instead of via ASAN. Valuable, but a compiler-correctness guarantee, NOT Rust's user-code
guarantee. Do not conflate the two.

## Honest boundary (what this proves vs Rust's borrow checker)

Even complete, this proves the **linear-ownership / ARC-balance invariant** → no leak / double-free /
use-after-consume for OWNED values. It is NOT a full borrow checker:
- No **data-race freedom** (no `Send`/`Sync` analysis of the actor/channel/async concurrency).
- No **exclusive-mutable-borrow** checking (Rust's aliasing-xor-mutation).
- No **cross-function lifetime / dangling-borrow** analysis.
So it converts the leak/UAF-for-owned-values axis from tested→proven — a genuine step toward Rust — but the
borrow checker's other guarantees stay runtime/absent. State that plainly; do not oversell it as "Rust-safe".

## Slices (order)

1. **Full-corpus V4' triage + census.** Run `=hard` over the ENTIRE corpus + stdlib; aggregate coverage and
   list every imbalance. For each: is it a CODEGEN BUG (fix `arc.zig` — a real leak/double-free, immediate
   win) or a MODEL GAP (fix the verifier's acquire/release contract for that shape)? Drive proven-imbalances
   to 0 on all known-correct code. This is the fastest path to actionable results AND the prerequisite for
   enforcement. Start with error-union / mediator / serde.
2. **Broaden V4' coverage.** Only "non-escaping + owned-via-retain" slots are checkable today (1 in the
   error-union case). Extend the acquire/release contract to ALL owned slots — escaping via return / field /
   container, borrowed params, `any`, trait objects — so ~100% of owned slots are checked. A guarantee needs
   near-total coverage; an unchecked slot is an un-proven slot.
3. **Consolidate on the OSSA-IR verifier (`verify.zig`) as the successor.** It models the full linear-
   ownership property on a proper SSA IR and subsumes `ownership.zig` + V4'. Bring SILGen (`lower.zig`)
   coverage to 100%: close the deferred buckets (reassign, break/continue, switch-guard, nonblock-branch,
   shadow, untyped-init, general CFG). Each is a lowering extension.
4. **Loop soundness.** `verify.zig` defers back-edges. Implement a CFG dataflow FIXPOINT (the consumed/live
   bitset converges over the loop) so loops are CHECKED, not deferred. This is the algorithmically hard piece
   and the biggest theoretical gap.
5. **Consume-form completeness.** Model EVERY consume/borrow Nova has: move-into-call, `ret_owned`, container
   insert, closure/async capture, trait widening, optional/error-union wrap, the value-semantics deep-copies
   just added. A missed form = a FALSE NEGATIVE = a soundness hole. This is the deep completeness work that
   makes the guarantee real rather than partial.
6. **Flip default-on, fail-closed.** Once coverage ~100% and 0 false positives corpus-wide, run the verifier
   in the default `nova build` / `nova test` pipeline and REJECT proven violations, exactly like the type
   checker. Add `expect_fail` ownership cases (deliberately-broken: leak, double-consume, path-imbalance)
   that MUST be rejected. Keep ASAN/ARC as a backstop until the verifier provably subsumes them.

## Verification / gate (every slice)

Full corpus stays green — 0 false positives — at each step (a false positive on correct code makes the gate
unusable). The new `expect_fail` ownership cases must be rejected. ASAN + ARC gates remain until enforcement
is proven to subsume them. Measure coverage% and proven-imbalance count after each slice.

## Effort / recommended first step

Multi-session. **Slice 1 (triage the V4' imbalances) is the highest-value first step** — it yields either
real leak fixes or precise model gaps immediately, and it is the prerequisite for everything downstream. The
deep, session-heavy work is Slices 3/4/5 (full SILGen coverage, loop fixpoint, consume-form completeness).
The enforcement flip (Slice 6) is small once the coverage/false-positive gates are green.
