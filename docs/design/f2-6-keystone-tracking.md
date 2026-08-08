# F2-6 Keystone: master tracking table

Living document. The F2-6 keystone is: **codegen consumes the sema typed IR (TypeIds) everywhere, the
string-rendering type path is deleted, and a real codegen soundness fuzzer guards it.** This file tracks
how much is actually finished, with the objective progress gauge being the shadow-mode agreement counters,
not a guess.

Last updated: 2026-08-08.

## 0. The one-paragraph honest state

The hard infrastructure is **built and validated**, which is the opposite of "unstarted". The checker/sema
already emit a `TypeId` per expression; a shadow harness (`NOVA_SEMA_SHADOW=1`) runs the typed-IR path and
the legacy string path side by side on every compile and counts where they agree or disagree. On a
representative program the typed path agrees with the string path on **6723 type resolutions with 0
disagreements**, ownership drop/move on **172 agree / 4 disagree**, disposition on **6957 agree / 8
disagree (all in the safe direction)**, and destructor/field/tuple/storage derivations at **0 disagree**.
So the remaining work is not "invent the typed IR" — it is (a) drive the last-mile disagreements and the 36
not-concrete cases to zero, (b) cut each codegen site over from the string helper to the TypeId, (c) delete
the string path, and (d) build the gen→compile→ASAN→oracle fuzzer that `fuzz.sh` is not yet.

## 1. How to read the progress gauge (re-run this to update the table)

```
NOVA_SEMA_SHADOW=1 nova test conformance/cases/123_any_container.nova 2>&1 \
  | grep -iE "agree|disagree|served|fellback|NOT-CONCRETE|dtor_name|tuple_elem|no-id|flip"
```

The invariant for cutover: a workstream can flip from string to TypeId only once its `DISAGREE` counter is
**0** (or a known, proven-safe set). Every disagreement is either a real bug to fix or a benign case to
reclassify. "% done" for the cutover is literally `flipped_sites / total_sites` with `DISAGREE == 0` as the
gate.

## 2. Master table

Status legend: ✅ done · 🟢 built+validated (shadow agrees, not yet cut over / string not yet deleted) ·
🟡 partial · 🔴 not started · ⚪ n/a.

| # | Workstream | Status | Evidence / measure | Remaining |
|---|---|---|---|---|
| W1 | Sema emits a `TypeId` per expression (TypedIr) | ✅ | TypedIr SymbolId resolve **62 agree / 0 disagree**; `typeOf`/`typeOfInst`/`symOf`/`methodArgsOf`/`opOf` all live | — |
| W2 | Shadow validation harness (typed vs string, per compile) | ✅ | `NOVA_SEMA_SHADOW=1` report with agree/disagree counters across ~10 dimensions | keep green as sites flip |
| W3 | F2 type engine serves resolved types | 🟢 | **6723 agree / 0 disagree**; 36 NOT-CONCRETE (keystone cannot substitute; all `struct_`) | the 36 not-concrete (see W7) |
| W4 | Ownership pass: dup/drop ops + balance (tasks F2-6 s5 s2/s3) | ✅ | op drop/move **172 agree / 4 disagree (struct_)**; release-site flip **255 store-native** | reconcile the 4 struct_ op-disagreements |
| W5 | Disposition (owned/borrowed) from store | 🟢 | **6957 agree / 8 disagree, ALL safe-direction** (7 `.not_owned`, checker under-claims, never over-claims; ASAN-clean) | reclassify the 8 as known-safe, then flip |
| W6 | Destructor identity from store (dtor-name/tuple/erru/storage/struct-fields) | 🟢 | dtor-name **87 agree / 0 disagree** (no-id 2); tuple/erru/storage/struct-field store-vs-parse **0 disagree** | key dtor emission on TypeId; kill 2 no-id |
| W7 | Free-generic `type_param` substitution in store (the 36 not-concrete) | 🟡 | keystone resolves 0 / disagree 0 today; 36 stay not-concrete | thread free-generic instantiation type-subst so `type_param`→concrete in the store (adjacent to B1/B2 already landed) |
| W8 | Cut `resolveExpressionTypeName` sites over to `typeOfExprConcrete`+scoped render | 🟡 | 66 call sites (expr 49 / llvm 12 / stmt 5 / arc 1 / types 1). Converted so far: struct field-offset (S2), enum construction+switch (S3), value-optional container | remaining ~60 sites, flip as W3/W5/W6 hit 0 |
| W9 | Cut `typeRefToString` sites (drops `.optional` and scope) | 🟡 | 60 call sites. Known lossy: drops value-optional (fixed one path via TypeId in `List<int\|undefined>`), drops module scope (enums/structs now via `scopedTypeName`/`renderLegacy`) | audit each of 60; route through TypeId where identity matters |
| W10 | Delete the string type path (`resolveExpressionTypeName`, lossy `typeRefToString`, `renderLegacy` as primary) | 🔴 | blocked on W7/W8/W9 reaching 0 | the deletion PR, once every consumer reads TypeId |
| W11 | Codegen soundness fuzzer (gen well-typed → compile → ASAN → oracle) | 🔴 | `conformance/fuzz.sh` exists but is a **front-end crash fuzzer** (mutate → don't crash the compiler); it cannot catch a miscompile | build the typed generator + differential/oracle checker + wire into CI at ~1M programs |

## 3. What "finished" means, per milestone

- **M-infra (W1-W6)**: typed IR built, validated, ownership + destructor identity derivable from the store
  with zero unsafe disagreement. **Reached** (W3/W5/W6 are 🟢 = validated, pending only the mechanical flip;
  W1/W2/W4 ✅).
- **M-cutover (W7-W9)**: every codegen consumer reads the TypeId; the string helpers are unused. **~partial**
  — the soundness-critical sites hit this session (field offset, enum, value-optional container) are done;
  the long tail of ~60+60 sites is mechanical but not yet swept.
- **M-delete (W10)**: the string path is removed and cannot silently miscompile again. **Not started**
  (correctly gated behind M-cutover).
- **M-fuzzer (W11)**: a generator proves the above holds over ~1M programs in CI. **Not started.**

## 4. Ordered remaining work (the actual to-do)

1. **W5 reclassify** the 8 safe-direction disposition disagreements as a named allow-list, so the counter
   reads 0-real. (Small.)
2. **W4 reconcile** the 4 `struct_` op drop/move disagreements — each is a construct to flip or a bug.
   (Small, already the shape of task s5-step6.)
3. **W6 flip** destructor emission to key on the TypeId (0 disagree already); delete the parse-side dtor
   name derivation. (Medium.)
4. **W7** give free generics real store-level `type_param` substitution so the 36 not-concrete resolve.
   (Medium; shares a root with the B1/B2 free-generic work already landed.)
5. **W8/W9 sweep** the ~126 string call sites, flipping each to the TypeId once its dimension is 0-disagree,
   guarded by the shadow harness staying green. (Large but mechanical.)
6. **W10** delete `resolveExpressionTypeName` and the lossy `typeRefToString` uses. (The payoff PR.)
7. **W11** build the codegen soundness fuzzer. (Large, independent, can proceed in parallel.)

## 5. Why this is the right sequence

Every soundness bug fixed this session (value-optionals through strings, colliding structs, colliding
enums) was a *symptom* of W8/W9 — codegen re-deriving a type from a string that had already lost module,
generic, or optional identity. Fixing them one-by-one via TypeId (as done for S2/S3 and the value-optional
container) is exactly the cutover, done reactively. W10 makes the class impossible; W11 proves it. Doing
W11 before W10 would just document the holes; doing W10 before W7-W9 would break compiles. The order above
is the only one where each step keeps the corpus + ASAN green.
