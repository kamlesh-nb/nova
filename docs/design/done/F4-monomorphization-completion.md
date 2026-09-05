# F4 — Monomorphization Completion (erased-body elimination) — plan

**Goal.** Delete the type-erased generic bodies so that (1) the string ownership seam
(`isRefCountedType`/`substituteFieldType`/`storageElem`/`getTupleElementType`) can be retired — the A2 /
F2-6 stage-5 Phase E endgame — and (2) code size drops. **This is a purity/completeness effort, NOT a
safety fix:** the erased bodies are already SAFE (the erasure rule `.type_param → non-owned` is correct
because the concrete owner compensates; the unknown-name guess is a tripwire abort; `store.isOwned ==
isRefCountedType(render)` DISAGREE=0). The payoff is retiring the seam and the string parsers, not fixing a
bug.

## Ground truth (measured 2026-07-21)
- **Mono is TypeId-keyed and mandatory** (`mono.zig:167`, no off-switch). Two worklists: struct-level
  (`seen`/`live_instantiations`, `mono.zig:172/51`) and method-level (`method_insts`, `mono.zig:73`),
  both discovered by scanning the typed IR (`Worklist.compute`, `mono.zig:266`).
- **The erased body is ALWAYS emitted first.** `instantiationsOf` (`codegen/types.zig:101`) unconditionally
  prepends `null` (the erased body) then appends each concrete instantiation (`types.zig:104`); both become
  `FunctionInfo`s (`llvm_codegen.zig:2490-2573`). `func.instantiation == null` ⇒ erased (`T` unresolved).
- **The erased container bodies are already provably DEAD: `f45_erased_fallback == 0` corpus-wide** — no
  instantiated call site misses its mono symbol and falls to an erased one (`shadow.zig:799`, the evidence
  gate). Confirmed empirically: `List_filter`/`List_get` erased bodies have 0 call sites; concrete sites
  call `List_string_*`/`List_i32_*`.
- **Two things still keep erased bodies alive:**
  1. **`base_needed` method bodies** — an inferred-arg method call (`xs.map((x)=>..)`) routes to the
     method-erased BASE (`List_int_map`), tracked by `sema_mono.baseIsNeeded` (`mono.zig:81-94`). `skip_base`
     (`llvm_codegen.zig:2555-2562`) already suppresses the erased body for generic METHODS reached only by
     explicit-arg calls — this is the pattern to generalize.
  2. **`Map` is EXCLUDED from monomorphization by name** (`codegen/types.zig:119-139`) because `map.ky`
     stores keys/values through raw `bytes.write_ptr` (no ARC), not `Storage<K>`/`Storage<V>` — so a
     monomorphized `Map_string_i32_set` has `retain=0` and use-after-frees (`Expected 100, got 4367861072`
     on 12_traits_dispatch). Map therefore runs ENTIRELY on its erased body + the call-site
     `retainIfGenericStore` compensation. This is the load-bearing blocker.
- **The `keystoneSubst` side-channel** (`declarations.zig:772`, `types.zig:486-525`) lets an erased-context
  codegen re-derive concrete types; `inst_disp.zig` (records `tp_resolve`/`expr_owned_inst` per
  (ExprId, instantiation)) is meant to supplant it but is additive so far.
- **Why the erased `__destruct_*_T/K/V` exist:** they are minted from INSIDE erased bodies — with a bare
  owner (`"Map"`, no `<>`), `substituteFieldType` (`arc.zig:366`) is an identity map, so a `Storage<K>`
  field stays `Storage<K>` → `getOrCreateDestructor("Storage<K>")` mints `__destruct_Storage_K`. Kill the
  erased bodies and these vanish, taking the string-parser calls with them.

## Phases (each independently landable, ASAN-gated; a wrong dtor is a UAF)

### M1 — Migrate `Map` to `Storage<K>`/`Storage<V>` (the load-bearing blocker) — LARGE, highest risk
`map.ky` currently stores through `bytes.write_ptr` into `allocZero` memory that carries no ARC. Rewrite
its key/value storage to `Storage<K>`/`Storage<V>` (the same typed-slot model `List` uses), so a
monomorphized `Map_string_Box_set` RETAINS an owned key/value via the store-native path. Then:
- delete the `retainIfGenericStore` call-site compensation (a mono callee stands it down);
- delete the `Map`-by-name exclusion (`codegen/types.zig:137`).
- **Gate:** the two cases the exclusion was protecting (12_traits_dispatch, 13_serde) pass; full corpus
  FUNC/SHADOW/ARC green; **full-corpus ASAN 0** (this is where a botched retain re-introduces the UAF the
  exclusion documents — do NOT rush); `f45_erased_fallback` stays 0. This is the [[kyte-f4b-monomorphization]]
  "migrate Map to Storage<T>" task and the single riskiest step — treat it as its own focused sub-effort.

### M2 — Retire the `keystoneSubst` side-channel via `inst_disp` — MEDIUM
Complete `inst_disp.zig` so codegen reads concrete per-instantiation dispositions/type-params from the IR
(`tp_resolve`, `expr_owned_inst`) instead of `current_instantiation`/`keystoneSubst`. Prove the
`principledDisposition` fallback shadow-diff is DISAGREE=0, then delete `keystoneSubst` (`types.zig:486-525`).
De-risks M3: an erased body suppressed while a mono body still relied on the side-channel would mis-resolve.
- **Gate:** disposition shadow-diff DISAGREE=0; FUNC/SHADOW/ARC green; ASAN 0.

### M3 — Suppress the erased struct/method bodies — MEDIUM (the structural payoff)
Generalize `skip_base` (`llvm_codegen.zig:2555`) to also drop the struct-erased body (`inst_opt == null`)
of a generic struct. **EMPIRICALLY ATTEMPTED 2026-07-21 — blocked on call-site routing gaps, NOT ready.**
A blanket `skip_struct_erased = inst_opt == null and s.type_params.len > 0` regressed 23/103 cases.
KEY FINDING: **`f45_erased_fallback == 0` is necessary but NOT sufficient** — it only counts *method*-call
fallbacks; several call-site kinds route straight to the bare erased symbol and were never measured:
  1. **Constructors** — `Pair<int,string>(..)` called the erased `Pair_init`, not `Pair_i32_string_init`.
     Two causes: the plain ctor path never tried a mono symbol; the generic ctor path built the candidate
     from `typeRefToString` (`Pair_int_string`) while the mono body is defined from `renderLegacy`
     (`Pair_i32_string`) — the `int`/`i32` two-renderer split made it miss and fall to erased. **FIXED
     (commit b13c829): resolve the call's instantiation type and prefer that mono init.** This alone took
     the regression 23 → 12.
  2. **Destructors** — with erased bodies suppressed, the remaining 12 cases crash in TEARDOWN ("terminated
     abnormally" AFTER all tests pass) → the erased struct DESTRUCTOR path (`__destruct_List`/`_T`) still
     mis-resolves for some releases. NOT yet fixed.
  3. Other method-call sites likely remain (the 12 also include container-heavy cases).
So M3's real precondition is: **complete call-site → mono-symbol routing for constructors [done], methods,
and destructors** so NO live site targets a bare erased symbol; only THEN suppress.

  4. **Renderer unification — DONE (commit 706b014).** `mangleTypeName` now folds every primitive SOURCE
     alias to codegen's canonical spelling (`int`→`i32`, `long`→`i64`, `float`→`f32`, …), token-aware, so a
     symbol built from `typeRefToString` and one from `renderLegacy` CONVERGE. Verified no `_int`/`_long`/
     `_float` symbols remain in emitted IR. This closes the two-renderer split at its ROOT (the recurring
     cause of the routing misses). FUNC/ARC 103/103, ASAN 81/81. But it is NECESSARY, not sufficient for M3.
  5. **Constructor mono-routing — three paths, all FIXED (2026-07-21).** The crash was NOT intra-body
     self-calls (method calls already route to mono, f45==0). It was the CONSTRUCTOR leaving `hashFn`
     unset because it ran the ERASED init. Three constructor emission paths each bypassed mono and were
     fixed: bare `Pair<..>()` (b13c829), the generic path's `int`/`i32` name build (fixed by the renderer
     unification 706b014), and **module-qualified `map.Map<..>()`** (c095783 — it delegated to
     `compileMethodOrNamespacedCall`, DROPPING `gc.type_args`, and built the raw erased `Map_init`; now
     short-circuited to the mono init). Progress: suppression regression 23 → 12 → 8.
  6. **The FUNDAMENTAL blocker (pinpointed 2026-07-21) — abstract-residue reachability.** The remaining 8
     are NOT routing bugs: `[nomethod] field=push obj_type=List<U> inst=List<i32>`. A base_needed method
     body (e.g. `List_i32_map`, kept for inferred-arg calls) contains `result: List<U>` whose `result.push`
     can ONLY resolve to the erased `List_push` — U is a METHOD-level param, unbound at that site, so no
     mono symbol exists. **So the erased struct bodies are NOT all dead: they are the link-time fallback the
     abstract residue genuinely needs.** Blanket `skip_struct_erased` is therefore WRONG — it deletes an
     erased body a KEPT (base_needed) body still calls. Correct M3 = a REACHABILITY CLOSURE: suppress an
     erased struct body only if NO retained body (base_needed method bodies + their transitive erased calls)
     references it. That closure is the real M3 build; it is separate, non-trivial, and NOT band-aidable.
     ALTERNATIVELY, eliminate the abstract residue itself (fully monomorphize base_needed method bodies) —
     but they are erased BY DESIGN for inferred-arg calls (`xs.map((x)=>..)` routes to the method-base), so
     that is a larger change to the method-monomorphization model.

Reverted the suppression each time; kept the three constructor fixes AND the renderer unification (all
correct on their own — they close real routing gaps regardless of M3). The `int`/`i32` two-renderer split
(increment 6's finding) WAS a recurring root and is now fixed at the source. The residual is the
abstract-residue reachability closure above — the concrete next task, and the true depth of M3.
- **Gate:** with routing complete, FUNC 103/103 + `f45==0` + full-corpus ASAN 0 (teardown crashes are the
  tell) BEFORE dropping the erased body; then re-measure the `isRefCountedType`-call / code-size drop.

### M4 — Delete the now-dead string destructor parsers (F2-6 stage-5 Phase E) — SMALL
With no erased body emitted, `__destruct_*_T/K/V` are never minted, so the `.type_param` field-release path
in the string builders is dead. Delete `getTupleElementType`, `countTupleElements`, `errUnionParts`,
`storageElem`, and drop `substituteFieldType` from the destructor path (its non-destructor callers are a
separate stage-6 concern).
- **Gate:** build clean; FUNC/SHADOW/ARC green; ASAN 0; `a2_irct_calls` drops to primitives-only volume.

### M5 — Retire `isRefCountedType` as an ownership oracle (A2 close) — MEDIUM
The remaining `isRefCountedType` callers are the `isOwned*ByName` fallbacks (`types.zig`). With no erased
bodies and all release sites TypeId-keyed, thread a TypeId to each (or prove it unreachable and route to the
tripwire). Delete `isRefCountedType` when its call count reaches 0.
- **Gate:** `a2_irct_calls == 0` corpus-wide (or only the tripwire path remains); FUNC/SHADOW/ARC green;
  ASAN 0. This is the literal A2 closure.

## Abstract-residue elimination — PARTIAL (2026-07-21), 3 sources found, 2 fixed
Corpus-wide, after R1/R2, only 3 erased bodies survive (List_grow, List_init, List_push). Traced to THREE
distinct sources:
1. **Destructor delete-hook** (`Map_delete`) — the `<Struct>_delete` cleanup hook was built from the bare
   base name, pinning the erased base. **FIXED (88ca691):** prefer `methodSymbol(type_name,"delete")` →
   `Map_string_i32_delete`. ARC-clean.
2. **Erased-context closures** — a lambda collected from an erased body (`(k,v)=>result.push(k)` in the
   erased `Map_keys`) inherits instantiation=null → `result:List<K>` binds erased `List_push`, and being a
   separate FunctionInfo R2 kept it. **FIXED (3513ed5):** propagate the parent's `erased_generic` to the
   lambda so R2 skips it. ARC-clean.
3. **`map<U>` method-level residue** — the base `List_i32_map` (kept `base_needed`) has `result: List<U>` →
   erased `List_push`. **FIXED (5cc56fc + be51d50):** route the inferred-arg call to the single
   specialization + flag the method-base `erased_generic` so R2 drops it. The initial attempt LEAKED (ARC
   AUDIT, 40/49) — **RECONCILED:** the spec body's `let mapped = fn(val)` (type `U`) was left unreleased
   while `List_string_push` retained it, because `isOwnedLocal` preferred the erased method-param TypeId
   (`U` → non-owned) over the string `type_string` that `substMethodParams` had already resolved to
   `string`. Fix: `isOwnedLocal` treats a `.type_param` TypeId like `.unresolved` and defers to the string
   (safe for a struct-level `T` in an erased body — string is also `"T"`; correct for a method-param `U` in
   a specialized body — string is the concrete owned type). The `map<U>` base is now eliminated; `List_push`
   is no longer kept by `List_i32_map`.
4. **Closure-captured `List<K>` residue — FIXED (57d8fe0), and it was the LAST source.** The lambda's
   `result.push(k)` DID resolve correctly to `mono='List_Box_push'` — but `List_Box_push` wasn't in
   func_map, so it fell to the erased `List_push`. Root cause: `List<Box>` (the return of
   `Map<string,Box>.keys(): List<K>`) was NOT in the mono worklist — `keys()` may never be called, yet
   `Map_string_Box_keys` is emitted and its lambda pushes into that List. FIX: the worklist's `note()` now,
   after recursing into a struct's args, lowers each METHOD RETURN type in the struct's type-param scope +
   `subst.substitute`s the instantiation's args, and notes the concrete result (`List<Box>`) — so
   `List_Box_push` is emitted and the lambda routes to it. **RESULT: ZERO surviving erased generic bodies
   corpus-wide.** FUNC/ARC 103/103, ASAN 81/81.

## ✅ ABSTRACT RESIDUE FULLY ELIMINATED (2026-07-21) — F4 mono completion
All 5 sources closed (delete-hook, erased closures, spec routing + ARC reconciliation, method-base flag,
worklist method-return discovery). NO erased generic body is emitted anywhere in the corpus. This is the
F4 monomorphization-completion goal. REMAINING for F2-6 Phase E (delete the string parsers): the ~76
`Storage<<unresolved>>` release splits — a SEPARATE Storage-FIELD-element TypeId resolution gap in the
struct destructor (the `Storage<T>` field's element renders unresolved in some release contexts while the
string path has the concrete type). Not abstract residue; a TypeId-resolution completeness gap that keeps
the string destructor builders reachable. That is the next (and likely last) thing gating parser deletion.

## Critical path & risk
`M1 → (M2 ∥ M3-prep) → M3 → M4 → M5`. M1 is the prerequisite and the highest risk (it re-enters the exact
UAF the Map exclusion was added to prevent — the ASAN gate is non-negotiable). M2 de-risks M3. M3 is the
structural payoff (erased bodies gone). M4/M5 are the seam-retirement cleanup that motivated the whole
effort. Rough effort: M1 ≈ 3-5d (risky, its own sub-effort), M2 ≈ 2-3d, M3 ≈ 1-2d, M4 ≈ 0.5d, M5 ≈ 2-3d.
~2-3 weeks total, M1 dominating.

## Evidence gates (the instruments that make this provable, not hopeful)
- `f45_erased_fallback` (`shadow.zig:799`) — MUST stay 0 through M3; a nonzero value means a live call site
  now resolves to a deleted erased symbol.
- `a2_irct_calls` (added this session) — the `isRefCountedType` volume; the M4/M5 progress meter.
- Per-phase: full-corpus ASAN (a wrong destructor is a UAF, not a leak — ASAN is the authority), plus the
  existing `KYTE_SEMA_SHADOW` store-vs-string diffs (struct-field/tuple/erru/storage all DISAGREE=0) as
  regression guards.

See [[kyte-f4b-monomorphization]] [[kyte-f1-f5-memory-safety-closed]] [[kyte-f2-6-stage4-parked]] and
`docs/design/F2-6-stage5-release-site-migration.md` (Phase E is M4 here).
