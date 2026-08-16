# Gap 1 -- SOUNDNESS ROOT CAUSE: codegen deciding type/ownership from rendered type NAMES

Scope: does codegen still make an ownership / boxing / dtor / layout **decision** by rendering a type to
a name string and matching that string, rather than from the TypeId? That is the "string engine" that
Nova's memory records as the root of its soundness debt. Verdict up front, then the evidence.

**Verdict: the corruption-class gap is NOT currently live.** Empirically, every live ownership decision
that has a resolvable TypeId agrees with the string baseline (shadow gate `td_disagree = 0`), and the
one remaining string-only *decision* function is confined to erased generic bodies that global-DCE drops.
What genuinely remains is a large volume of name-based **dispatch / layout-lookup / mangling** (74
`resolveExpressionTypeName` sites, 76 `typeRefToString` sites) whose failure mode is a **loud link error**,
not a silent UAF. So this is a *residual-cleanup and hazard-surface* gap, not an open soundness hole.
I am confident on "no live corruption decision" (measured); I am less confident that the cleanup is as
bounded as the design doc claims (see unknowns).

---

## 1. Gap (proven)

### 1a. The string engine is NOT gone; the vestigial calls remain (grep counts, `lang/src`)

| Symbol | Live count | What it is now |
|---|---:|---|
| `resolveExpressionTypeName` | 74 refs | TypeId-**first** (see 1c); consumers use the name for dispatch/layout lookup |
| `typeRefToString` | 76 refs | TypeRef → spelling, feeds name mangling + the `substituteFieldType` fallbacks |
| `substTypeParams` | 14 | struct-T name mangling + shadow baselines (`types.zig:338,1328,1376`; `arc.zig:326`; `llvm_codegen.zig:2034,3690`; `expressions.zig:1703`) |
| `substituteFieldType` | 9 | struct-field dtor **name** + the *fallback* ownership decision (`arc.zig:273,334,741,846,863,1104`) |
| `substMethodParams` | ~4 live | now overlay-primary / TypeId-native (`types.zig:1273`) |
| `current_method_subst` | **0 live** | all 6 hits are past-tense comments (`arc.zig:701,803`, `types.zig:1137,1269`, `expressions.zig:3242,5433`) |
| `MethodParamBinding` | **0** | deleted |

So the method-`<U>` string engine (`current_method_subst` / `MethodParamBinding`) really is deleted, as
`docs/design/string-engine-removal.md` (lines 169-185) claims. The **struct-T** string path
(`substTypeParams` → `substituteFieldType`) and the residual `resolveExpressionTypeName` /
`typeRefToString` name usage survive.

### 1b. The ONLY remaining live string-**decision** function, and it is one caller

`erasedOwnershipDefault` (`src/backend/codegen/arc.zig:34-48`) is the last function that returns an
ownership boolean purely from a name string. Its single live caller is `ownedByName`
(`src/backend/codegen/types.zig:1100`) -- and `ownedByName` only reaches it *after* trying the TypeId
engine first:

```zig
// types.zig:1084-1101  ownedByName
if (std.mem.eql(u8, name, "any")) return true;
if (isPrimitiveTypeName(name)) { ... return false; }
if (self.tidForName(name)) |tid| { return self.isOwnedTypeId(tid); }   // TypeId path (primary)
return self.erasedOwnershipDefault(name);                             // string DECISION (fallback only)
```

`erasedOwnershipDefault` fails **closed** on an untypeable placeholder (`isUntypeablePlaceholder` →
`std.process.exit(70)` with a "compiler bug" message, arc.zig:36-43), returns `false` for a bare
single-letter type-param, and `true` otherwise. It is reached only when the name resolves to **no TypeId**
at all -- i.e. inside erased generic bodies.

The struct-field ownership decision has the same shape: `isOwnedDeclaredType`
(`types.zig:1103-1112`) lowers the field TypeRef and returns `isOwnedTypeId(t)` whenever the lowered type
is decidable; only if `live_sema` is absent or the lowered type is undecidable does it fall to
`ownedByName(string_fallback)`. And the struct destructor generator itself is TypeId-native: in
`getOrCreateStructDestructorByTypeId` (`arc.zig:838-848`) the `is_ref` decision uses
`subst.substitute(...)` + `self.isOwnedTypeId(c)`, with the `substituteFieldType`(string) +
`isOwnedDeclaredType` path taken only when `concrete == null` (the `else str_blk:` arm).

### 1c. `resolveExpressionTypeName` is TypeId-first (so the 74 sites are not name-primary)

`resolveExpressionTypeName` (`types.zig:1357-1423`) returns `renderLegacy(concreteTid)` whenever the
instantiation overlay resolves the expression (`if (typeOfExprConcrete(self, expr_ptr)) |ctid| return
renderLegacy(st, ctid);`, lines 1419-1421). The `substTypeParams`-based `s_name` (line 1376) is returned
only on the null branch -- per the doc's `NOVA_TID_CENSUS` sweep that is exactly **one** expr in the whole
corpus (`68_generic_method_mono`, a lambda reifying its parent method's `<T>`, doc lines 123-128). So the
name these 74 sites consume is TypeId-derived in the normal path; it is then used to *look up* a struct
layout (`self.structs.get(name)`) or *mangle* a call target -- a wrong answer there is a missing-symbol
**link error**, not memory corruption.

### 1d. Empirical proof there is no live disagreement (shadow gate, run 2026-08-15)

Built `zig build` clean, then ran `NOVA_SEMA_SHADOW=1 nova test <case>` on the guard cases the design doc
names (119, 279, 123, 68, 310, 40, plus 02/42/309/307). The gate prints the ownership-decision diff
between `isOwnedTypeId` (TypeId engine) and `legacyStringOwnership` (the historical name rule):

```
case                         td_disagree  keystone_disagree  erased-residual (irct_string_decided)
02_generics_destructor            0              0               22
119_generic_return                0              0               22
279_free_generic_composition      0              0               22
123_any_container                 0              0              105
68_generic_method_mono            0              0               42
310_generic_return_type_param     0              0               23
40_map_refcounted_closure         0              0               22
42_nested_owned_aggregates        0              0               22
309_generic_async_serde_bind      0              0               42
307_generic_struct_impl_trait     0              0               23
```

`td_disagree = 0` and `keystone_disagree = 0` everywhere (the report labels both "MUST be 0"). The
`erased-residual` count (22-105) is nonzero, so the string path *is* still executed, but the diff proves
the TypeId engine and the name rule return the **same** ownership answer wherever a TypeId exists.

**Honest caveat on this measurement:** `td_disagree` can only compare the two engines where a TypeId
exists. The `erased-residual` hits are precisely the cases where `tidForName` returned null, so there is
**no TypeId to compare against** -- the shadow gate does not (cannot) cover them. Their safety rests on a
separate argument: (i) they are erased generic bodies, which the compiler emits with `internal` linkage
as a link-time fallback that global-DCE drops (per `lang/CLAUDE.md`, "Monomorphization" note), so their
codegen is dead; and (ii) the design doc's SE-B sweep instrumented that fallback across the whole corpus
and found **327 hits, every one `owned=false`**, identical to `isOwnedTypeId(.type_param)`
(`string-engine-removal.md:106-110`). I did not independently re-run that 327-hit sweep; I verified the
call graph that makes it plausible (1b) and the `td_disagree=0` result (above).

---

## 2. Root cause (from the code)

The one-sentence root, still accurate to the code: codegen historically decided type properties (owned /
value-optional / dtor / layout) by rendering a type to a **name** and `std.mem.eql`-matching it, and that
name engine is load-bearing precisely where TypeId substitution was incomplete -- inside **generic
bodies**, where a bare type-parameter has no concrete TypeId unless an instantiation overlay resolves it.
`string-engine-removal.md:8-16` states it and the code confirms it: `isOwnedExpr` (`types.zig:463`) ends
in `return self.isOwnedTypeId(t_opt.?)`, but only after `tpResolve(t, inst)` (types.zig:440-442) has had a
chance to turn a `.type_param` into a concrete id via the overlay; when `current_instantiation_id == null`
(a genuinely erased body) the type stays a `.type_param`, `isOwnedTypeId` returns `false`, and the former
string fallback was there to "decide" it (types.zig:454-463 comment).

The fix already applied (steps 1-5 of the doc, "SE-A overlay total"): a TypeId-native monomorphic
instantiation table keyed by a shared `inst_key`, populated for struct / free-fn / method instances
(`inst_disp.run` / `runFreeFns` / `runMethods`), feeding both `typeOfExprConcrete` (exprs) and
`concreteTidForTypeRef` (declared TypeRefs, `types.zig:1128-1158`). With the overlay total for
*decisions*, the string fallback became redundant for every concrete instance and was deleted at the
ownership site (SE-B). What was **not** finished is demoting the string engine from **name generation**:
struct-T spec names, `renderLegacy`, and the `typeRefToString`/`substituteFieldType` name path still exist
because `current_instantiation_id` (the TypeId context) is not threaded everywhere
`current_instantiation` (the string context) is (`string-engine-removal.md:187-197`).

So: the *decision* root cause is closed; the *name* root cause (the maintainer hazard that a future
decision could be re-attached to a spelling) is still open because the string machinery is still present
and still called.

---

## 3. Design to close it -- PLAN (confidence: MEDIUM; this is not a proof)

The goal is not "fix a bug" (no live corruption bug is proven) but **remove the hazard surface**: delete
the string engine entirely so no future edit can accidentally decide ownership/layout by spelling. The
doc's step 6 + "Remaining deletion map" is the plan; my read of the code says it is directionally right.

Order (each item is name-generation, loud-fail, so landable behind the ASAN gate):

1. **Close the one erased-lambda case** (`68_generic_method_mono`): give a lifted lambda its parent spec's
   `inst_key` so `typeOfExprConcrete` reaches the overlay for it, eliminating the sole null-branch of
   `resolveExpressionTypeName` (`types.zig:1419-1422`). The doc (line 174-178) claims this is already
   done via `current_collecting_instantiation_id`; verify it still holds, then the null branch can be an
   assert.
2. **Thread `current_instantiation_id` everywhere `current_instantiation` (string) is set.** This is the
   genuinely hard part and the doc flags it (`:193-195`): a measured attempt to fold `substituteFieldType`
   into the overlay **diverged on 292/341 cases** because the string destructor path and various
   name-render contexts set the string instance but not the TypeId one. Until this is done, the struct-T
   name path cannot be removed. The spec loops to fix: `llvm_codegen.zig:2936,3079,3135`; the dtor
   isolation sites `arc.zig:701-706,803-808`.
3. **Derive spec / struct names from `inst_key` TypeId args** instead of `substTypeParams` string
   bindings, at the 8 `substTypeParams` name-render callers (doc `:136-139`).
4. **Delete** `substTypeParams`, `substituteFieldType`(as decider), `erasedOwnershipDefault`(as decider),
   demote `renderLegacy` to a concrete-id-only mangler behind `symbolName(tid)` (the single sanctioned
   TypeId→string boundary, `types.zig:1425`), and assert concreteness at
   `typeIdForRenderedName`/`tupleElemTraitName`.
5. **Remove the dev-only shadow scaffolding last** (`tdShadowDiff`, `legacyStringOwnership`,
   `tid_census`), once there is no second engine to diff against.

**The genuinely hard part** is step 2 (thread the TypeId instantiation context through every
name-rendering context, especially the string destructor path where 292/341 cases currently diverge).
Everything downstream is mechanical once that holds.

**Unknowns (stated, not hidden):**
- Whether step 2 is truly bounded or fans out into the whole codegen name layer (the 292/341 divergence
  says it is broad).
- Whether the erased-body fallback deletion is safe once `internal`-linkage bodies are the only callers  -- 
  i.e. is the DCE guarantee actually airtight for *every* erased body, or are there paths where an erased
  body is NOT DCE'd (async-util fns, RawBuffer intrinsics)? The 327-hit sweep says all were `owned=false`,
  but that is a corpus observation, not a proof over all programs.
- `typeRefToString` has 76 callers; I did not audit all of them for a hidden ownership decision. My 1b
  finding is that the *known* decision sites route through TypeId, but 76 is a lot of surface.

---

## 4. Risk + effort (GUESS -- labelled)

- **Effort: multi-day to ~1-2 weeks**, dominated by step 2 (the 292/341-divergence context threading).
  Steps 1, 3, 4, 5 are each a day or less once step 2 holds. This is a guess.
- **Highest-risk step: step 2** (threading `current_instantiation_id`), because it touches spec
  return-type mangling and the struct-field destructor path -- a core mono path that, if a name comes out
  wrong, breaks corpus-wide. The saving grace, and why the risk is *link-error* not *corruption*: a wrong
  mangled name is a missing symbol at link time, loud and immediate, not a silent UAF. The doc makes this
  point (`:196-197`) and the code supports it (the decisions already ride TypeIds; only names ride strings).
- **What could break:** any generic spec whose name is currently derived from the string bindings and
  whose TypeId `inst_key` disagrees -- those would fail to link. Guard cases the doc names: 119, 279, 310,
  40_map_refcounted_closure, 123, 02_generics_destructor, 39_declared_type_ownership, plus 68.
- **Because it is name-generation, this is NOT the corruption class** -- so the *risk of shipping it wrong*
  is a broken build, caught by the corpus, not a latent memory bug.

---

## 5. Verify (the exact command that proves it done)

Two gates, both required:

```bash
cd lang
# (a) no live disagreement between the TypeId engine and the string baseline, corpus-wide:
NOVA_SEMA_SHADOW=1 conformance/run.sh            # every case must print td_disagree=0, keystone-DISAGREE=0,
                                                 # and (once the engine is deleted) erased-residual=0
# (b) memory-safety gate -- the failure class is UAF/double-free that plain `nova test` masks:
NOVA_ASAN=1 zig build && conformance/run.sh --asan   # green ASAN corpus is the ONLY go signal
```

## MILESTONE 2026-08-16: the soundness-hazardous string engine is DELETED

`erasedOwnershipDefault` — the last function that returned an ownership boolean from a rendered type NAME —
is deleted (d1b8b60), folded into `ownedByName` as an inline erased-body structural default. After it:

- Shadow gate: `td_disagree=0`, `keystone-DISAGREE=0` (no live ownership disagreement between engines).
- Audited every remaining `std.mem.eql`/`startsWith` string comparison in `src/backend/codegen`: there are
  **ZERO that decide a generic/user type's ownership or layout** (the soundness hazard). The 51 the lint
  counts are all CANONICAL-identity checks — `bool`(12), `any`(12), `string`(11), `void`(3), primitives —
  whose name IS their identity (no type-params, no instantiation), plus a few BUILTIN special-cases
  (`Atomic` intrinsic ops, `Str` zero-copy, `List<` element parsing, `NovaConnection`) that key on a fixed
  builtin name, not a rendered generic instantiation. None is the "decide a generic type from its spelling"
  bug class.

So the string engine **as a miscompile risk is gone.** What remains under the name "string engine" is NOT
a soundness hazard:
- `renderLegacy` / `typeRefToString` (~130 refs): the necessary TypeId→symbol-name renderer (the sanctioned
  boundary via `symbolName`). These must exist — you cannot emit LLVM without turning a type into a name.
- `ownedByName` / `isOwnedDeclaredType`: name→TypeId bridges, already TypeId-FIRST; the string tail is the
  shadow-proven-safe erased-body structural default.
- `legacyStringOwnership` / `tdShadowDiff`: the dev-only proof harness (runs only under NOVA_SEMA_SHADOW).
- `substituteFieldType` / `substTypeParams` + the parallel string struct destructor: DUPLICATE machinery —
  a real code-cleanup opportunity, but NOT a soundness issue (the TypeId destructor path is primary).

Fully deleting (c)+(d) is the remaining literal cleanup (multi-hour, ~30 coupled callers); it removes
duplicate code, not a defect. The soundness bar for gap 1 is met and proven.

## PROGRESS 2026-08-15 (this session)

- **Slice A (05dae86):** restored the blind `string-typedecision-lint` (was grepping the pre-reorg path,
  false green; true count 51, re-baselined). See below.
- **Slice B (5d3341b):** `resolveExpressionTypeName`'s PRODUCTION path is now TypeId-only. The erased-body
  fallback returned `substTypeParams(renderLegacy(t))`; a corpus sweep (`NOVA_RESOLVE_FALLBACK`, 230
  samples, 0 DIFF) proved it is always a bare type-param there and `substTypeParams` is an identity, so it
  now renders the TypeId directly. `substTypeParams` survives only under the census baseline. Verified:
  14/14 generic/dtor/stdlib guard cases, shadow MUST-be-0 invariants all 0, 10/10 ASAN-clean.
- **Slices C/D BLOCKER pinned in code (declarations.zig:884):** the compiler already SKIPS unused erased
  generic bodies — `if (func.erased_generic and !is_rawbuf_backing and LLVMGetFirstUse(fn_val) == null)
  continue;`. It still emits (a) `is_rawbuf_backing` RawBuffer intrinsics and (b) erased bodies that HAVE
  uses. Those two are load-bearing and are exactly what the string fallback (`erasedOwnershipDefault`,
  the struct-T `substituteFieldType` dtor path) serves. So "delete the string engine" is NOT mechanical:
  it requires proving every used-erased body + RawBuffer intrinsic is safe to resolve via TypeId or drop,
  a multi-day change with soundness risk, gated behind full corpus+ASAN. This is the genuine design fork,
  now grounded in the code rather than a doc guess. **erasedOwnershipDefault is irreducible by a TypeId
  engine by construction** (it fires only when a name has NO TypeId — a bare type-param in an erased body).

### Safe-reductions track EXHAUSTED (2026-08-15) — the residual is ALL the erased-body core

Three safe reductions landed and verified: slice A (05dae86), slice B (5d3341b), dtor str_blk (68e1dee).
Then I measured the destructor bridge's `phaseA_split` (the count of release sites where the TypeId path
is NOT taken because its rendered name differs from the string name) corpus-wide:

```
366_map_ops:            flip=1060  split=75  no-id=0
365_list_combinators:   flip=541   split=33  no-id=0
02_generics_destructor: flip=532   split=33  no-id=0
   last split: id='RawBuffer<<unresolved>>'  str='RawBuffer<T>'
```

The code comment labels split "(i32/int, kept string)" but that is STALE. The actual split cause is an
UNRESOLVED TYPE-PARAM: in an erased/generic destructor context the TypeId path renders `RawBuffer<<unresolved>>`
(T has no concrete id) while the string engine keeps `RawBuffer<T>`. Forcing the TypeId path there would
emit a WRONG destructor symbol. So every remaining split is the SAME irreducible root as `erasedOwnershipDefault`
and the `resolveExpressionTypeName` fallback: **type-params with no concrete TypeId in erased bodies.** There
is no i32/int spelling slice to do; normalizing renderLegacy would not move `split`.

CONCLUSION: the string→TypeId gap-1 cleanup has no remaining CLEAN (behaviour-preserving, corpus-proven)
reduction. What is left is the design change deferred by the user (task #191): make the TypeId path resolve
type-params inside used-erased/RawBuffer bodies, or stop emitting those bodies. Until then the string engine
survives as the correct name source for exactly those contexts, and the shadow gate proves it makes NO live
ownership disagreement (td_disagree=0) — i.e. no live corruption, only residual name-generation surface.

There is a THIRD, cheaper ratchet gate that runs in `gate.sh`:

```bash
bash conformance/string-typedecision-lint.sh    # raw count of std.mem.eql string type-name decisions
```

**2026-08-15 finding (05dae86):** this lint had been BLIND since the compiler reorg -- it grepped the
pre-reorg `src/codegen/*.zig`, matched an empty glob, and reported a false `0 (baseline 49)` for weeks.
The true count against `src/backend/codegen/*.zig` is **51** (it had crept +2 unguarded). The lint is now
fixed and re-baselined to 51. Caveat kept in the script: the raw 51 also counts sanctioned canonical-name
checks (`any`/`void`/`string`/primitives, which have fixed identity and are not the generic-type hazard),
so the genuine hazard is a subset; gate (a)'s `td_disagree=0` remains the soundness proof, and this raw
count is the hazard-surface ratchet the gap-1 deletions drive toward 0.

"Done" = the string engine is deleted (grep for `substTypeParams`, `substituteFieldType`,
`erasedOwnershipDefault`, `legacyStringOwnership` returns **0 live callers**, only `symbolName(tid)`
remains as the TypeId→string boundary), AND both gates green. Today, gate (a) already reports
`td_disagree=0` on the guard cases (section 1d), and the corpus is ~340/341 plain + `--asan` (only the
off-platform `189_epoll_event_layout`), so the *soundness* bar is met; what the deletion adds is
`erased-residual=0` and the removal of the second engine, i.e. it closes the *hazard*, not a live defect.
