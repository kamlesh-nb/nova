# Removing the codegen string type-engine — validated architecture

This supersedes the earlier `string-to-typeid-cutover.md` as the authoritative plan. It is the product of two
adversarial deep-analysis rounds (all claims cite `file:line`; the adversaries broke every shortcut before any
code was written). Read this before touching the type engines.

## The one-sentence root

Codegen decides type properties (owned / value-optional / prim-kind / dtor / layout) from TypeIds for most
code, but for **type-parameters inside free generic functions and method-level `<U>`** it falls back to a
STRING engine (`resolveExpressionTypeName` -> `renderLegacy` + `substTypeParams`/`substMethodParams`, then
`std.mem.eql` against a spelling). The string engine is load-bearing there because only STRUCT type-args get a
TypeId substitution overlay (`inst_disp.run` -> `tp_resolve`); free-fn and method type-params get a STRING
overlay (`current_method_subst` / `MethodParamBinding`) and no TypeId one. The `isOwnedTypeId(.type_param)` arm
returns false without a `tp_resolve` hit, so removing the string fallback early is a **use-after-free /
double-free**, not a soft mistype.

## Why the two typed-IR maps are NOT the bug

`expr_types` (`typeOf`) holds the generic base (param-ful); `expr_types_inst` (`typeOfInst`) is a faithful
per-instantiation substitution of it (`inst_disp.zig:52,55`). They do not hold contradictory values. The
observed `i32` vs `i32 | undefined` symptom is the STRING engine reading the generic base and `renderLegacy`
dropping the `| undefined` when the optional's inner is a `.type_param` (`shadow.zig:938-946`). So the fix is
NOT to reconcile two maps and NOT to patch `renderLegacy`; it is to make type-parameter substitution
TypeId-native for every route so codegen never renders a param-ful type for a decision.

## The complete blocker set (audited complete, no hidden 4th)

- **B1 free-fn transitive discovery is string-native.** `expandFreeFnInstsTransitively`
  (`llvm_codegen.zig:3088-3119`) reconstructs inner instances (`mid<string>` from `top<string>`) from already
  rendered arg STRINGS; the originating TypeIds are gone (`noteFreeFnInst` receives `args: []const TypeId` at
  `mono.zig:111` but renders+discards them at `:116`).
- **B2 method-level `<U>` has no `tp_resolve`.** `recordTpResolve`'s only caller is `inst_disp.zig:29`
  (struct args). `noteMethodInst` (`mono.zig:68`) has the concrete TypeIds (`infer.zig:1744/1801`) but stores
  strings only.
- **B3 value-optional-of-type-param is decided on the TypeRef, not the expr.** `valoptTypeRefIsValue`
  (`llvm_codegen.zig:792`), `slotTypeForLocal`, `argIsValoptLocal` read the declared TypeRef; `tidForTypeRef`
  (`types.zig:1107-1112`) lowers with NO instantiation context -> `.optional{.type_param}` -> `valueOptionalInner`
  null -> not boxed. Gating case: `119_generic_return.ky` (`maybe<int>(0,true)` must box or present-0 collapses).

Ruled out as separate roots (confirmed): generic enums (no type_params), lambdas (inherit parent instantiation),
struct field dtor/owned (already TypeId-native via `subst.substitute`, `arc.zig:856-862`), `getTypeSize`
(TypeRef-syntactic, never calls the subst engine).

## Adversarial results on the "easy" partial steps (do NOT be tempted)

- **Step-0** (migrate `== "type"` decision sites onto `isXxxExpr`): 2 sites are a UAF if migrated
  (`llvm_codegen.zig:1482`, `:2231` — the `param_str`/`widen_to == "any"` param-gates for `Map<string,any>.set`,
  case 123); the other 10 are cosmetic no-ops that delete nothing load-bearing and narrow future generic
  headroom. Verdict: near-zero value as deletion.
- **Step-1** (flip `resolveExpressionTypeName` to the TypeId path): double-free on free-generic owned-string
  forwarding (`279_free_generic_composition`) because it neuters the `isOwnedExpr` type_param fallback
  (`types.zig:458-462`) for non-ident type_param exprs where `current_instantiation_id` is null.

Conclusion: **there is no meaningful partial removal.** The engine comes out only after B1+B2+B3.

## The build (the ONLY path to true zero)

One TypeId-native monomorphic-instantiation table, keyed by a shared `inst_key`, populated for every route,
feeding both `typeOfExprConcrete` (exprs) and an instantiation-aware `tidForTypeRef` (declared TypeRefs).

1. **Give free-fn and method instances real TypeIds + a shared `inst_key`.** `FreeFnInst` (`mono.zig:100`)
   and the method-inst record keep `args: []const TypeId` (stop discarding at `mono.zig:116`) and an interned
   `inst_key: TypeId` computed by ONE shared helper called by both the sema recorder and codegen setup (they
   MUST agree or lookups miss and fall to the deleted string path).
2. **Free-fn / method analog of `inst_disp.run`.** For each free-fn and each method instance, record
   `tp_resolve[{tp = fn/method type-param, inst_key}] = arg` and walk the body recording
   `expr_types_inst[{expr_id, inst_key}] = subst.substitute(store, typeOf(e), fn_or_method_sym, args)`. Reuses
   the proven `subst.substitute` (free-fn/method params already have real SymbolIds, `lower.zig`).
3. **Move transitive free-fn discovery (B1) to be TypeId-native**, carrying TypeIds end-to-end through the
   fixpoint (`subst.substitute` forwards them) instead of reconstructing from strings — run in sema before
   rendering, or duplicate there.
4. **Make `tidForTypeRef` instantiation-aware** (accept the `inst_key` binding) so B3's TypeRef-driven
   decisions resolve type-params — the TypeRef analog of what `typeOfExprConcrete` does for exprs.
5. **Set `current_instantiation_id = inst_key` for free-fn and method specs** (`declarations.zig:667` parallel).
6. **Route every remaining decision through TypeId** (`isXxxExpr` / `isOwnedTypeId` / `valoptTypeRefIsValue`
   now total), then **delete** `resolveExpressionTypeName`, `substTypeParams`, `substMethodParams`,
   `MethodParamBinding`, `current_method_subst`, `ownedByName`-as-decider, and the `renderLegacy`-for-decisions
   path. `renderLegacy` demotes to a concrete-id-only mangler behind `symbolName(tid)` (`types.zig:1221`), the
   sole TypeId->string boundary; assert concreteness at `typeIdForRenderedName`/`tupleElemTraitName` (they feed
   `renderLegacy` non-concrete ids today).

## The gate (once, at the end)

`KYTE_ASAN=1 zig build && conformance/run.sh --asan`. ASAN is REQUIRED, not optional: the failure class is
UAF/double-free that a plain `kyte test` masks. Green ASAN corpus is the only go signal. Guard cases the
adversaries named: 119, 279, 310, 40_map_refcounted_closure, 123, 02_generics_destructor, 39_declared_type_ownership.

## Honest effort and risk

Multi-day, memory-safety-critical. The novel pieces are the shared `inst_key` helper (both sides must agree)
and moving the transitive fixpoint into sema as TypeId-native (thin corpus coverage there). Every mistake in
this territory is a double-free, so land it as one coherent change verified under ASAN, not incrementally with
string fallbacks half-removed.

## Execution progress (2026-08-14)

The build (steps 1-5) is DONE and the overlay is proven total for decisions. What survives is NAME
substitution for dispatch/mangling, not any decision.

**Landed + committed (each ASAN-verified on guard cases):**
- **SE-A overlay total.** `inst_disp.run` (structs) + `runFreeFns` (direct + transitive free-fns, B1) +
  `runMethods` (generic methods, B2), all keyed by the shared `inst_key`. `current_instantiation_id` is
  set for free-fn/method specs.
- **SE-B: the ownership DECISION string fallback is deleted** (commit "SE-B delete the ownership string
  fallback"). Proof it was redundant, not a guess: instrumented the `isOwnedExpr` `.type_param` fallback
  to print its answer and swept the whole corpus -- **327 hits, every one `owned=false`**, identical to
  `isOwnedTypeId(.type_param)` when no instantiation resolves it. Every hit is a genuinely erased body
  (RawBuffer_at/pop, the async-util fns, ORM helpers, one lambda). So the fallback fell through to
  `isOwnedTypeId`.
- **B3: `valoptTypeRefIsValue` is TypeId-native** (commit "SE-B/B3 ..."). It resolves the value-optional
  inner via `concreteTidForTypeRef` + `symbolName` instead of `typeRefToString` -> `substMethodParams`,
  so no boxing decision is backed by the string engine any more. Gating case 119 + the value-optional
  set pass under `--asan`.
- **`resolveExpressionTypeName` is TypeId-first.** Where the overlay resolves the expr it returns
  `renderLegacy(concreteTid)` (type-params reified through TypeIds, value-optional wrapper rendered
  faithfully -- the string engine dropped `| undefined` on a type-param inner); the string-substituted
  base render survives only as the null-branch fallback. Full plain corpus 340/341 (only
  `189_epoll_event_layout`, off-platform). [ASAN gate result pending in this same run.]

**The precise residual (what still calls the string substitution, and why):** measured with
`KYTE_TID_CENSUS=1` across the whole corpus.
- Null-branch of `resolveExpressionTypeName`: **exactly ONE** expr in the entire corpus differs if
  `substMethodParams` is dropped -- a lambda reifying its parent generic method's `<T>`
  (`68_generic_method_mono`, `(s) => serde.bind<T>(s)...`). The lifted `__lambda_*` is compiled with a
  null `instantiation_id`, so `typeOfExprConcrete` cannot reach the overlay entry the method recorded.
  Closing it = give a lifted lambda its parent spec's `inst_key` (intricate lambda-monomorphization
  plumbing, one case).
- `substMethodParams` remains **load-bearing for monomorphized-spec NAME MANGLING** -- turning a generic
  body's `T` into the concrete spec name (`typeRefToString`'s `.ident` arm, the spec loop's
  `current_method_subst`, ~25 sites). This is name generation fundamental to how mono names functions,
  NOT a type decision. Excising it is task #172 "collapse name layer to `symbolName(tid)`": derive the
  concrete spec name from the `inst_key` TypeId args instead of string bindings.

**Remaining deletion map (the coherent, ASAN-gated finale):** close the one lambda case; convert the 8
`substTypeParams` callers (`llvm_codegen.zig:1998,3659`; `types.zig:337,1162,1266`; `expressions.zig:1693`;
plus the census/shadow baselines) to derive names from concrete TypeIds; remove the spec-loop
`current_method_subst` assignments; then delete `substTypeParams`, `substMethodParams`,
`current_method_subst`, `MethodParamBinding`, and demote `renderLegacy` behind `symbolName(tid)`. The
dev-only shadow scaffolding (`tid_census`, `legacyStringOwnership` baseline, `tdShadowDiff`) comes out
last. **No decision is left on the string engine; the maintainer hazard (ownership/boxing by spelling)
is gone.** What remains is bounded, mapped, and non-corrupting (a wrong dispatch name is a loud link
error, not a UAF).

### Update: the resolver foundation is TypeId-native (2026-08-14)

`concreteTidForTypeRef` (the TypeRef analog of `typeOfExprConcrete`) no longer reads
`current_method_subst`. Its fast path recovers a bare type-param's LEAF from the owner declaration's
`type_param` names -- the free-fn/method owner (`inst_key.decl`) and, for a method inst, the receiver
struct (`inst_key.args[0]`) -- and resolves it through the overlay's `tp_resolve`; its general path
substitutes every leaf via a new `substViaOverlay` walk (both owners, both recorded under the shared
`inst_key`). This also fixed a latent off-by-one: a method `inst_key` is
`.struct_{method_owner, [recv] ++ U-args}`, so the old raw-index lookup pointed at the recv for `U0`;
`tp_resolve` is keyed on the leaf so there is no offset. Behaviour-preserving (full plain + `--asan`
340/341). This is the resolver the whole finale sits on -- it is now TypeId-native.

**`current_method_subst` now has exactly three readers left:** `substMethodParams` (the token
substituter) and the two serde-reify sites (`expressions.zig` json/yaml-parse type-arg, and
`resolveReifyTypeName`). The next coherent batch (deletes the field): reimplement `substMethodParams`
to resolve each type-param token via `paramLeafByName` + `tp_resolve` + `symbolName` (so the concrete
comes from the overlay, not the string bindings) with `current_instantiation_id = inst_key` set in the
three spec loops (`llvm_codegen.zig:2936,3079,3135`) so it is live when spec return-types render;
convert the two reify sites to `concreteTidForTypeRef` + `symbolName`; then delete
`current_method_subst` / `MethodParamBinding` / the `method_subst` FunctionInfo field / the spec-loop
assignments. This batch is high-risk (it touches spec return-type mangling, a core mono path that
breaks corpus-wide if wrong, and interacts with the struct-T substitution `substituteFieldType` via
`current_instantiation`), so it must land as one change under the full `--asan` gate.

### DONE: the method-U string engine is deleted (2026-08-14)

`substMethodParams` is now TypeId-native (overlay only): each type-parameter token is resolved via
`paramLeafByName` + `tp_resolve` + `renderLegacy`. Enablers, each proven before deletion:
`current_instantiation_id` is set in the method + free-fn spec loops (so the overlay is live when spec
return-types render); a lifted lambda inherits its parent's `inst_key`
(`current_collecting_instantiation_id`), closing the one erased-lambda case (`68_generic_method_mono`)
the overlay previously could not reach; closure keys discriminate by `inst_key` (which encodes both the
receiver struct-T and the method `<U>`) instead of the `method_subst` signature, with registration and
lookup deriving the id identically; the two serde-reify sites use `concreteTidForTypeRef` + `symbolName`.

**Proof, not a guess:** a full-corpus `KYTE_TID_CENSUS` sweep showed the legacy string bindings were
never the sole resolver and never diverged from the overlay (`legacy_only=0`, `diverge=0`) on every
case, including `68`. Then **deleted**: `current_method_subst`, `MethodParamBinding`, the `method_subst`
FunctionInfo field, `current_collecting_method_subst`, all spec-loop `subst` allocations, and the
`arc.zig` save/restore bookkeeping. Gate: full plain corpus 340/341 AND `--asan` 340/341 (only
off-platform `189`), zero ASAN errors.

**What remains (NOT a decision, so not the hazard):** the struct-T path, `substTypeParams` ->
`substituteFieldType` (string) -> `substMethodParams` (now TypeId-native). It is used ONLY for NAME
rendering, the dev-only `KYTE_SEMA_SHADOW` report (`tdShadowDiff`/`isOwnedRenderedFallback`/
`legacyStringOwnership`), and a `live_sema`-null fallback destructor -- no live type DECISION rides on
it. A measured attempt to fold `substituteFieldType` into the overlay diverged on 292/341 cases: the
overlay cannot resolve struct-T wherever `current_instantiation` (string) is set but
`current_instantiation_id` (TypeId) is not (the string destructor path, various name-render contexts).
So the struct-T name path stays until `current_instantiation_id` is threaded everywhere
`current_instantiation` is -- a broader migration (P2/task #171), loud-failure (a wrong name is a link
error), not a corruption risk. **The string engine is decision-free; the maintainer hazard
(ownership/boxing by spelling) is gone.**
