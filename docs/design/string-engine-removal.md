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
  null -> not boxed. Gating case: `119_generic_return.nova` (`maybe<int>(0,true)` must box or present-0 collapses).

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

`NOVA_ASAN=1 zig build && conformance/run.sh --asan`. ASAN is REQUIRED, not optional: the failure class is
UAF/double-free that a plain `nova test` masks. Green ASAN corpus is the only go signal. Guard cases the
adversaries named: 119, 279, 310, 40_map_refcounted_closure, 123, 02_generics_destructor, 39_declared_type_ownership.

## Honest effort and risk

Multi-day, memory-safety-critical. The novel pieces are the shared `inst_key` helper (both sides must agree)
and moving the transitive fixpoint into sema as TypeId-native (thin corpus coverage there). Every mistake in
this territory is a double-free, so land it as one coherent change verified under ASAN, not incrementally with
string fallbacks half-removed.
