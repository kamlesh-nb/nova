# F4-5 completion: method-level monomorphization

**Status:** designed 2026-07-18 from this session's measurements. This is the last structural blocker
for removing the erased body → `.type_param`-fatal at codegen → F2-5 → F5-2. **The risky phases (2b, 3)
touch ARC ownership and need supervision** — a wrong retain passes gates but corrupts at runtime.

## The exact problem (measured, not assumed)

After the struct-level fix (`72b0f82`, `substTypeParams` on the method-call receiver), the erased body
is still reachable from EXACTLY one shape. Instrumented across the corpus (remove erased body → 40
failures, all identical shape):

```
NOTFOUND: obj='result' field='push' inst='List<i32>'   (×26)
NOTFOUND: obj='result' field='push' inst='List<string>' (×11)  ... List<Seg>, List<Item>, List<(i32)->i32>
```

`result: List<U>` where **U is a METHOD-level type parameter** (`List<T>.map<U>(f)`, `reduce<U>`, …).
The struct is monomorphized (`List<i32>`, so `current_instantiation` = `List<i32>`, T=i32), but the
method's own `U` is bound at the CALL SITE (from the closure's return type via `solveParams`), not by
the struct instantiation. So inside the single `List_i32_map` body, `U` is abstract → `result` is
`List<U>` → `result.push` resolves to the missing `List_U_push` → erased `List_push` (retain=0). That
erased `List_push` is the only thing still forcing the erased body alive, and it is ARC-unsound for a
refcounted U (works today only because the leak stays within the `--arc` floor).

## Why struct-level mono doesn't cover it

`mono.zig`'s worklist keys purely on **struct TypeIds with concrete args** (`compute()` walks
`ir.expr_types`, `note()` records `.struct_{decl,args}` when `isConcrete`). A method instantiation
`List<i32>.map<string>` is a `(struct-inst, method SymbolId, [method args])` tuple — NOT a struct
TypeId — so it is unrepresentable in the current `seen` set. This is the core gap.

## The build (phases; anchors verified this session)

**Phase 1 — record method type-args in the IR (sema; ADDITIVE, safe, gate-green trivially).**
`methodReturn` (`infer.zig:996`) already computes `solved: []?TypeId` (the resolved method params) at
`infer.zig:1076-1094` via `subst.solveParams`. Add `expr_method_args: AutoHashMap(ExprId, []TypeId)`
to `TypedIr` (`infer.zig:77`) and, when EVERY `solved[i]` is non-null AND concrete, record it keyed by
the CALL's ExprId. `methodReturn` has no `&e` — thread it in via an out-param (same pattern as the
`out_sym` added in `aed2c5d`) and record at the `.call` caller (`infer.zig:463`). Nothing reads it yet.

**Phase 2a — collect method instantiations (mono.zig; additive shadow).** New set
`method_seen: AutoHashMap(struct { inst: TypeId, mid: SymbolId, args: []TypeId })` (or a rendered-name
set for parity with codegen's string world, per the file header's TypeId-vs-pair note — prefer a
composite key rendered to `"List_i32_map_string"`). Walk `ir.expr_method_args`; for each, the receiver
struct-inst comes from `symOf`/`expr_types` of the call's receiver. Report the count (shadow).

**Phase 2b — EMIT per-method-instantiation bodies (codegen; RISKY — ARC).** In `collectFunctions`
(`llvm_codegen.zig:2271` struct-method loop), currently N copies per struct instantiation. Extend to
also copy per METHOD instantiation: `List_i32_map_string` with BOTH the struct scope (T=i32) AND the
method scope (U=string) installed so the body's `List<U>` renders `List<string>` and its `result.push`
binds `List_string_push` (which retains). This is where a wrong scope = wrong retain = latent UAF.
Mind the closure path too (`current_collecting_instantiation`, `llvm_codegen.zig:2231`).

**Phase 3 — resolve method calls to the instantiation (codegen; RISKY).** In
`compileMethodOrNamespacedCall` (`llvm_codegen.zig:1458`), when the method has type params, build the
mono name from `(qualifySelfType(subst_struct), method, method-args)` using the recorded args (via the
call's ExprId → `expr_method_args`), falling back to the current behavior. Byte-identical guard: the
fallback + `hasFunction` check (same fail-safe as the `72b0f82` and F1-3b flips).

**Phase 4 — remove the erased body + assert `.type_param` unreachable (F4-5 done-criterion).** Re-run
the removal experiment (patch in this session's history: `instantiationsOf`, drop `null` when ≥1
concrete inst). When it stays 58/58 + `--arc`/`--asan` green, drop the erased body for instantiated
generics and make `isOwned`/codegen assert on a `.type_param` that reaches it (F2 §5 / F4 §5 G5).

## Verification (each phase)
`zig build; echo EXIT=$?` (NEVER `| tail` — it masks the exit; caught this session, `db82cee`) ·
`KYTE=./zig-out/bin/kyte ./conformance/run.sh` (58) · `--arc` (98) · `KYTE_ASAN=1 zig build` then
`--asan` (98) · `zig build test`. Phase 4's gate IS the removal experiment going green.

## Measured refinements (2026-07-18, experiments — read before Phase 2)

Two experiments sharpened the plan materially:

1. **The erased reliance is EMITTED-but-UNCALLED abstract-U bodies, not called ones.** `List_i32_map`
   is emitted for EVERY `List<i32>` (all methods of an instantiation are), and its internal
   `result.push` on `List<U>` (U abstract) forces the erased `List_push` — even when `map` is never
   called. So Phase 2b must ALSO **stop emitting the abstract-U generic-method body** (skip a method
   with `type_params>0` at the struct-instantiation level in `collectFunctions` `llvm_codegen.zig:2258`),
   emitting ONLY the specialized `List_i32_map_string` bodies. Experiment: skipping generic-method
   bodies + removing the erased body → breakage **40 → 9** (the 18-from-`72b0f82` plus these).

2. **The 9 residual are cases that genuinely CALL a generic method** (`04_closures`, `07_generics`,
   `12`, `13`, `14`, `20`, `29`, `34`, `37`) — they need the specialized body emitted. So method-inst
   emission (Phase 2b) IS required, for those 9.

3. **⚠️ Phase 1 recording has GAPS.** `method_insts` counted **0** on `13_serde`, yet `13_serde` is in
   the failing 9 — so it calls a generic method that `methodReturn`'s `all_concrete` block did NOT
   record. Before Phase 2b, WIDEN the recording: find why the call is missed (different inference path?
   `solveParams` partial? receiver not `.struct_`?). The recording MUST capture every called generic
   method or Phase 2b emits an incomplete set and those calls stay broken. This is the first task.

Order corrected: **(0) fix + verify Phase 1 recording captures all 9 cases' generic calls → (2b) emit
specialized bodies + skip abstract-U bodies → (3) resolve calls → (4) remove erased body.** Phase 1's
`expr_method_args` (committed) is the substrate; the `mono.method_insts` global (reverted this session,
re-add) is the emission worklist.

## ⚠️⚠️ DEFINITIVE FINDING — the abstract-U/erased bodies are RUNTIME-referenced (2026-07-18)

Diagnosed `13_serde` to the bottom. It has **no** `GENMETHOD-CALL` — it never calls a method with
method type-params. Its erased reliance is `result.push` at `inst='List<Item>'`: the **emitted-but-
uncalled** `List_Item_map` body (map is emitted because `List<Item>` is instantiated → ALL its methods
are), whose internal `result: List<U>` push binds the erased `List_push`.

**The trap, measured:** skipping the generic-method body emission + removing the erased body makes
`13_serde` **COMPILE CLEAN but CRASH AT RUNTIME** ("Test process terminated abnormally" after several
passing tests). So the abstract-U/erased bodies are referenced at RUNTIME — via destructors
(`__destruct_List_Item` releasing through the erased path), closures, or function-pointer tables — NOT
only as compile-time link fallbacks. **A compile gate + `--arc`/`--asan` on the corpus does NOT catch
this** (it compiled and the crash was mid-suite). This is the precise gate-passing-but-wrong ARC hazard.

**Consequences for the build:**
- **Do NOT "skip" or "remove" bodies as a shortcut.** F4-5 MUST emit a CORRECT specialized body
  (`List_Item_map_<U>`) AND rewire every runtime reference (destructor, closure lambda, any table) to
  it before the erased body can go. The destructor path is the sharp edge.
- **Runtime testing is mandatory at every step**, not just gates — drive the actual programs.
- This validates doing the emission/resolution phases WITH supervision: the failure mode is a runtime
  crash a compile gate misses.
- Phase 1's recording gap is REAL but secondary: even for uncalled maps, `List_Item_map` is emitted and
  must be handled. The worklist must include method-instantiations reachable via EMITTED generic bodies,
  not only via call sites — i.e. when `List<Item>` is instantiated, its `map` needs a policy (emit
  specialized per used U, or a sound erased body), because the body exists whether or not it is called.

## Supervised-phase investigation (2026-07-18) — the erased reliance, fully decomposed

Ran targeted probes (BARE-RECV at method resolution, ERASED-USE at the erased fallback, per-test
crash isolation). The erased-`List_push` reliance decomposes into exactly these, and NO others:

1. **`self.`-calls inside mono bodies** — HANDLED. `qualifySelfType` rewrites bare `Map`→`Map<string,i32>`
   (via `current_instantiation`), so `self.resize()` in `Map_string_i32_set` binds mono. The BARE-RECV
   probe fires here but the call still resolves mono — a false lead.
2. **Mono closures** — HANDLED. A lambda lifted from a mono body inherits `.instantiation =
   current_collecting_instantiation` (llvm_codegen.zig:1922), so `Map_string_i32_keys`'s
   `result.push(k)` binds `List_string_push`. The `List<K> inst=<none>` erased-uses are the ERASED
   bodies' own closures (erased→erased, fine while the erased body exists).
3. **Abstract-METHOD-param bodies** — THE REAL RESIDUE. `List_Item_map` (map's own param `U` is abstract;
   `current_instantiation=List<Item>` binds only the struct param `T`, never `U`), so its internal
   `result: List<U>` push binds erased `List_push`. Both the erased AND the mono `List_Item_map` copies
   have this. `substTypeParams` cannot help — there is no `U` binding in a body that is not specialized
   by `U`. **These bodies are emitted for every `List<Item>` even when map is never called**, and they
   are **runtime-referenced** (skip+erased-removal → `13_serde` compiles but crashes at `test_map` — a
   mono/closure/erased interaction not yet isolated to a single site).

**So F4-5 reduces to source #3 ONLY**, and the fix is unavoidably: **specialize** the abstract-method-param
body per concrete `U` (`List_Item_map_string`, U bound via a NEW `current_method_subst` extending
`substTypeParams`), emitted from the Phase-1 `expr_method_args` worklist; and for an UNCALLED such method,
either don't emit it (requires finding + rewiring the runtime reference that makes skip crash) or emit a
sound-but-unspecialized variant. The runtime-reference crash is the sharp edge to isolate FIRST (get a
backtrace: `KYTE_KEEP_OBJ=1`, lldb the test binary) before touching emission.

## Session progress already banked
`72b0f82` (struct-level type-param receivers → 58→40 on removal). Everything else in
`FOUNDATION-STATUS.md`. This doc is the executable continuation of its "F4-5 residual" section.

## Build progress (2026-07-19) — Phases 1+2a landed; 2b/3 built but blocked on local-types subst

**LANDED (4bed9f3, green):**
- **current_method_subst mechanism** (llvm_codegen.zig `MethodParamBinding` + field; arc.zig
  `substMethodParams`). `substTypeParams` now runs struct-subst (T from `current_instantiation`) THEN
  method-subst (U from `current_method_subst`). Behavior-neutral until something sets it.
- **Phase 2a worklist** (mono.zig `method_insts` + `noteMethodInst`; infer.zig records at the
  all-concrete point). Validated via KYTE_SEMA_SHADOW: chained map → `List<i32>.map<string>` +
  `List<string>.map<string>`; single map over List<string> → `List<string>.map<i32>`.

**BUILT + FUNCTIONAL but REVERTED (net regression):**
- **2b emit** — a pass in `collectFunctions` emits one `FunctionInfo` per `method_insts` entry, name
  `List_i32_map_string` (= methodSymbol(inst,method) + "_"+mangled args), with `instantiation`=inst and
  a NEW `FunctionInfo.method_subst`; installed as `current_method_subst` at both declarations.zig
  compile sites (664, 887). Additive-safe on its own (uncalled bodies, gates green).
- **3 resolve** — `compileMethodOrNamespacedCall` gains a `call_ep: ?*const Expression` param (threaded
  `&expr` from both callers); when `methodArgsOf(call_ep)` has args, build `mono_name + "_"+mangled` and
  try it FIRST. Resolution FIRES correctly (both specialized bodies hit=true).

**THE BLOCKER (precise):** the specialized body reuses the erased body's AST **and sema typing**, so
its inferred local `mapped` (`let mapped = fn(self.get(i))`) is typed `U` — NON-OWNED — in
`current_local_types` (sema typed the body ONCE, erased). The concrete `result.push` (`List_string_push`)
RETAINS `mapped`, but nothing releases it at loop-scope (U non-owned in local_types) → **over-retain**
(elements at rc=2; `--arc +53` on 40_map_refcounted_closure; single map regresses too). `--arc` catches
it (it's a leak, not a UAF), so gate on `--arc` as well as `--asan`.

**FIX to land 3:** substitute the method-params (U→string) in the specialized body's INFERRED LOCAL
TYPES — the codegen local-types pass (declarations.zig ~664+) must apply `current_method_subst` to each
inferred local's recorded type (or re-infer the body with U bound). Then `mapped:string` is released at
loop-scope, balancing the retain. This is exactly the "local_types vs body disagree → leak, not
diagnostic" hazard noted at declarations.zig:883. After that: 2b/3 re-apply cleanly, then Phase 4
(erased-body removal, still runtime-referenced) stays deferred.

## Local-types subst SOLVED + corrected diagnosis (2026-07-19, second pass)

**The local-types over-retain IS solved.** Root: the specialized body reuses the erased body's sema
typing, so an inferred local `mapped` has the ERASED `.type_param` TypeId (U) in `current_local_type_ids`,
and `isOwnedLocal` PREFERS that TypeId over the (correctly substituted) string — reading `U` as
non-owned (erasure) so `mapped` is never released → the concrete `push`'s retain leaks (rc 2). FIX
(verified: over-retain 5→3, single map stays clean): in `collectLocalVarTypes` (llvm_codegen.zig ~2739),
inside a specialized body (`current_method_subst != null`), SKIP storing a `.type_param` TypeId — let
the correctly-substituted string decide. With that, Phases 2b+3 build GREEN corpus-wide (64/64,
--arc/--asan/--shadow 110/110, unit).

**BUT method-mono does NOT fix the chained-map leak** — the diagnosis in the sections above was WRONG
about the cause. Decisive probes:
- single `map` over `List<string>` with HEAP elements → CLEAN (probe 11)
- `let a = xs.map(f); a.map(g)` (a is a map RESULT) → LEAKS a's elements (probe 02b), erased OR specialized
So the leak is ELEMENT-PROVENANCE-dependent, not the erased `result.push`/`List_U_push`: mapping over a
directly-constructed `List<string>` is fine, but mapping over a `List<string>` that is ITSELF a map
result leaks its elements. Same body, same `self.get(i)` transfer — only the source differs. Specializing
the body (concrete `List_string_map_string`) does not change this (still leaks 3). So method-mono is
correct infrastructure that does not deliver THIS fix.

**Decision (measure-before-optimizing, mono.zig header):** 2b/3 + the local-types fix were built and
proven GREEN, but REVERTED — the corpus barely exercises the worklist (13_serde: 0 entries), and adding
specialized bodies that fix no MEASURED leak is exactly the size-for-no-benefit trade the discipline
forbids. Kept: the committed foundation (mechanism + worklist, 4bed9f3) and this corrected diagnosis.

**Real next step (redirected):** diagnose the ELEMENT-PROVENANCE leak — why a `List<string>` produced by
`map` leaks its elements when re-iterated by a second generic method, while a directly-pushed one does
not. It is an ARC-accounting difference in how map-produced elements are owned, independent of
specialization. Fix THAT (likely in the map body's `self.get(i)` temp release or push retain balance),
and it fixes chained pipelines with or without method-mono. THEN method-mono is a size/cleanliness
follow-up (and the Phase-4 erased-body removal enabler), not the leak fix.

## Element-provenance leak — narrowed to the first-map `mapped` release (2026-07-19, third pass)

Runtime rc-trace of `let a = xs.map(f); let b = a.map(g)` (both closures produce template strings):
the leaked element `"X1"` (a's element) ends at **rc 1** — `alloc(1) → retain[push] → retain[a.get in
2nd map] → release → release`. ONE release short. Key facts established:
- The leaked string is a `bytes.alloc_persistent` object from `StringBuilder.toString` (template
  interpolation) — malloc'd and HONESTLY refcounted (persistent ≠ exempt; the name misleads).
- `a` IS typed `List<string>` (concrete) and its `__destruct_List_string` DOES run at scope exit — so
  the erased-destructor hypothesis is WRONG.
- The missing release is in the FIRST map's body: `mapped` (typed `U`, non-owned in the erased body's
  local_types) is not released at loop-scope, so the `push`-retain is unbalanced. Method-mono's
  specialized body + the local-types fix DID remove the analogous over-retain, but the chained leak
  persisted — the second-map `a.get` retain / first-map `mapped` release interaction is not fully
  closed by specialization alone.

**Status:** NOT closed. This is a genuinely deep, multi-layer ARC interaction (erased generic body
element ARC × closure return × persistent-alloc strings × two-map refcount balance). Characterized
extensively across THREE passes (method-mono, provenance, rc-trace) but not solved. The leak is NARROW
(composed generic pipelines `map().map()` over heap-allocated owned elements), NON-CORRUPTING (a leak,
ASAN-clean), and AVOIDABLE (single maps clean; all corpus patterns clean; the whole corpus is arc 0).
It does not block stdlib work — it is a known, documented, bounded limitation to fix as dedicated work.
