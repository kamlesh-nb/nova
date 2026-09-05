# F2-6 — the checker writes a complete typed IR (the keystone)

**Status:** PLAN (2026-07-19d). The last structural piece between "no *known* bugs" and "*provably*
no bugs." Subsumes: closure-param sema typing, method monomorphization, and the arc.md ownership
pass's static balance check. Retires the codegen string-guessing surface (~147 sites).

**One-line thesis:** today the checker types ~90% of expressions into `TypedIr`, and codegen
re-derives the rest — and *all* destructor/mangling decisions — by **rendering `TypeId`→string and
pattern-matching**, or by **scanning the AST** (`findLambdaCallSite`, `resolveCalleeName`). F2-6 makes
the checker emit a **complete** IR — every expression's `TypeId`, resolved callee `SymbolId`, and
ownership **disposition** — so codegen only *lowers* it. Ownership becomes analyzable and *provable*,
and the string engine (`renderLegacy`/`substTypeParams`/`isRefCountedType`) and the scans are deleted.

---

## 0. Why this is the keystone (what it unblocks, grounded)

Every hard problem this session bottomed out here:
- **Closure-param mis-format** (the residual): codegen scans the AST for a bound closure's call site
  because sema never typed the param. The scan is block/function-local and can't do the untyped
  higher-order case — because typing a closure param needs info from *after* its definition (a
  **second pass**), which only a checker-side IR can carry. → §4.
- **ARC ownership** (the whole acquisition rewrite): codegen decides owned/borrowed via
  `acquisitionDisposition` reading `isOwnedExpr(TypeId)` **plus** a rendered-string fallback for the
  ~10% the IR doesn't cover. The fallback is where the corpus-dodged bugs lived. → §5.
- **Generics** (F4): `expr_method_args` exists but codegen still renders `.type_param` to `"T"` and
  `substTypeParams`-es it back. → §3.
- **Calls** (F1): `expr_syms` is recorded but *unread* — codegen still runs `resolveCalleeName`. → §3.

Closing F2-6 turns all of these from "guess, then hope the corpus caught it" into "the checker
decided; codegen lowered; a static check proved it balanced."

---

## 1. Current state (measured 2026-07-19d — the honest baseline)

`TypedIr` (`src/sema/infer.zig`, ExprId-keyed so it survives codegen's by-value AST copies):
- `expr_types: ExprId → TypeId` — **~84% (serde) to ~93% (typical)** of expressions.
- `expr_syms: ExprId → SymbolId` — resolved callee. **Recorded, NOT yet read by codegen.**
- `expr_method_args: ExprId → []TypeId` — generic method type-args. Recorded; partially read (F4-5).
- `unassigned_rejected` must stay 0 (an un-id'd expr would collide onto bucket 0).

The **untyped residue** (594/3861 on serde) is two very different things:
1. **Not-a-value idents** — `console`, `assert`, `string`, `list` (288 idents), module-qualified
   `field_access` (286): these are MODULES/NAMESPACES, not values. They are *correctly* untyped —
   but they read as "UNRESOLVED", indistinguishable from a genuine gap. **F2-6 needs a `namespace`
   disposition** so "not a value" ≠ "sema failed."
2. **Genuine gaps** — closure params (the ordering problem), a few `field_access`, `literal` edge
   cases. This is the ~real coverage debt to close.

Codegen's **string-guessing surface** (~147 sites): `resolveExpressionTypeName` (51 callers) renders
`typeOf` via `renderLegacy` → `substTypeParams`; `isRefCountedType` (the ownership fallback);
`findLambdaCallSite*` (closure params); `resolveCalleeName` (the call scan); and every
`getOrCreateDestructor(type_name: []const u8)` / mangling site keyed on a rendered STRING.

---

## 2. The target IR (what "complete" means)

Extend `TypedIr` so that for **every** expression node the checker records:
- **`type: TypeId`** — already there; drive coverage to 100% of *value* expressions (§7 stage 1).
- **`disposition: {owned, borrowed, namespace, trivial}`** — the ownership decision, computed by the
  checker from the TypeId + last-use (this is arc.md §1.2 moved into sema). `namespace` marks the
  not-a-value idents (§1.1); `trivial` marks non-managed values. Replaces codegen's
  `acquisitionDisposition` + the `isRefCountedType` fallback.
- **`callee: SymbolId`** (calls only) — already recorded as `expr_syms`; make codegen *read* it.
- **`method_args: []TypeId`** (generic method calls) — already `expr_method_args`.

Codegen then has exactly ONE question per expr, all answered by a lookup: *what is its TypeId, is it
owned, what does it call.* No rendering, no scanning, no `isRefCountedType`.

---

## 3. The string boundary — the subtle half codegen keeps needing

Even with 100% `typeOf` coverage, codegen currently needs a **string** for two things:
1. **Destructor symbol names** — `getOrCreateDestructor("List_string")` builds `__destruct_List_string`.
2. **Mangling** — function/instantiation names.

F2-6 must give these a **TypeId-keyed** path: `getOrCreateDestructor(t: TypeId)` and
`mangle(t: TypeId)`, deriving the symbol from the store, not a rendered name. This is what finally lets
`renderLegacy`/`substTypeParams` be **deleted** rather than merely bypassed. Until then the string
path survives as a name-generator only (no *decisions*), which is already the F5 posture
(`[[kyte-f5-typeid-migration]]`: 9.7k name-only sites deferred as "rider on F2-6").

---

## 4. Closure params — the second pass (why sema, not codegen)

The residual mis-format proved the ordering problem: a closure param's type comes from its **call
site**, which is *after* the definition and may reference not-yet-bound locals. Single-pass,
top-to-bottom inference cannot see it; codegen's scan works only because it runs post-typing.

F2-6 resolves it with a **bounded second pass over each function body**:
1. Pass 1 (exists): infer top-to-bottom; a closure with an un-inferrable param is typed
   `(unresolved…) → ret` and recorded.
2. Pass 2 (new): for each such closure, having now typed the whole body, find its uses — a bound
   variable's `name(args)` calls, or a call passing it to a typed parameter — and unify the param
   types. Re-record the closure body's affected expressions (the interpolation parts) with the
   resolved param types.
This is the checker-side replacement for `findLambdaCallSite*` (delete it, §7 stage 5). The
still-open **untyped higher-order param** (`fn apply(f, s){ f(s) }`) is closed here too: pass 2 types
`f` from its use `f(s)`, which is exactly "infer a param from use" generalized to function params.

---

## 5. Ownership in the IR + the static balance check (the "provable" payoff)

This is where F2-6 **merges with the arc.md ownership pass**. Once the checker emits `disposition`
per expr (§2), the acquisition layer (`arc.acquisitionDisposition`) stops *computing* and starts
*reading* — and codegen's `isRefCountedType` fallback is deleted (no expr is ever untyped at an
ownership decision). Then add the **static balance check** (arc.md §6.1, Swift OSSA-style): assert per
function that every `owned` value is consumed exactly once on every control-flow path. A violation is a
**compile error, located**, not a runtime leak found by a probe months later. THIS is what upgrades
"green on the corpus" to "provably balanced." The `--shadow` gate proves the IR agrees with the legacy
string engine during migration; the balance check proves the IR is *internally consistent* after.

---

## 6. Verification (each stage gated by the existing net + one new gate)

- **`--shadow`** (exists, ENFORCED): every concrete decision, TypeId engine == string engine. During
  cutover this proves the IR is a faithful replacement before the string path is deleted.
- **`--arc` / `--asan`** (exist, MANDATORY): 0 leaks / 0 UAF corpus-wide. ASAN catches what `--arc`'s
  freed-sentinel hides.
- **Static balance check** (NEW, §5): the build-time proof. Ratchets the runtime gates.
- **Coverage counter** (exists in the F2 shadow report): drive genuine-unresolved (excluding
  `namespace`) to 0 before deleting a fallback. Same "grow the corpus first" discipline that caught
  every bug this session.

---

## 7. Staged, gated rollout (shadow-then-cutover — the discipline that has worked all session)

Each stage lands green on the full suite; nothing is deleted until its replacement is proven.

- **Stage 0 — Instrument & classify (small). ✅ DONE 2026-07-19d.** Split the F2 "UNRESOLVED" counter
  into `namespace` (not-a-value: modules/builtins/container-types + accesses on them) vs `genuine`
  (the real coverage debt). Measured: ~65–80% of UNRESOLVED is `namespace`; the real `genuine` debt is
  only ~5–8% of expressions (serde 201, map 125, http 137, closures 61), not the scary ~16% raw. This
  is the honest denominator stage 1 drives to 0. Measurement-only, fully green. Next refinement (if
  wanted): a `genuine`-only `by_tag` to name the shapes (e.g. serde's 20 unresolved literals).
- **Stage 1 — Close coverage (medium). ✅ LARGELY DONE 2026-07-19d — and the finding rewrote the
  problem.** Named the genuine shapes, then discovered the "gap" was ~90% MEASUREMENT NOISE: on top of
  `namespace` idents, the dominant "genuine field_access" was **method-call callees** (`xs.push`,
  `self.data.get`) — a method REFERENCE is not-a-value (Kyte has no bound-method values; it is only
  called), so an unresolved one is not a coverage gap. Classifying those (an `in_call_callee` flag)
  collapsed the genuine debt: serde 201→20, map 125→11, http 137→12, closures 61→7. **The typed IR is
  already ~complete for VALUES (~99.5%+).** The true remainder is: (a) honest LITERALS — empty
  collections `[]`/`{}` whose element type is genuinely context-dependent (the bulk); (b) a narrow CASCADE
  from `Array<int>()` construction (Array was a generic type using free-fn UFCS methods sema does not
  type) — CLOSED 2026-07-19d by DROPPING Array (redundant with List; convention: generic types use
  struct-body methods). Corpus max genuine debt 42→20, now uniformly honest literals. So the
  coverage PRECONDITION for the cutover (stages 3-6) is essentially MET. Remaining stage-1 work is
  small and bounded: type container-construction (kills the cascade) + decide the honest-literal
  policy (they stay `unresolved`, codegen already handles them). Gate: `--shadow` coverage counter.
- **Stage 2 — Second pass for closures (medium, contained). ✅ DONE 2026-07-19d (`bfa24aa`).** §4.
  After pass 1, re-type each top-level `let name = <closure>` whose param is unresolved, using an
  EXPECTED func type built from its call-site arg types (`name(args)` searched function-wide). Reuses
  the `want` mechanism; re-records the body into the IR. Proven live (`g(5)`→int, `f(a)`→string), so
  `typeOf()` is now complete for bound closures and each types as `.func`. Ownership-flip risk
  (string param → `.owned`) checked clean (params are borrowed, never released). This is the
  precondition for retiring `findLambdaCallSite` (stage 3/6) AND unblocks the func/trait destructor
  cutover (stage 4, whose safe slice was dead precisely because closures typed `.unresolved`). Gates:
  FUNC 70/70, ARC/ASAN/SHADOW 120/120. STILL OPEN: a closure passed to a fully UNTYPED higher-order
  param (`fn apply(f,s){ f(s) }`) needs inter-procedural inference (type `f` from its use) — separate.
- **Stage 3 — Codegen reads the IR for TYPES (medium). 🟡 STARTED 2026-07-19d.** Cut
  `resolveExpressionTypeName`'s consumers over to `typeOf()` per construct, behind `--shadow`, so
  codegen stops rendering for *decisions*. **Increment 1 DONE (`9eceb7b`):** interpolation's `.string`
  decision now reads `typeOf(part) == .string` on the store, not `== "string"` on a rendered name —
  proven live (the TypeId path fires, not dead code). Pattern established: TypeId-first, string path as
  the unresolved fallback (closure params). **Increment 2 DONE (`da1d82f`):** the interpolation
  PRIMITIVE decision reads the store too — a TypeId-based `numToStringT` dispatches on `PrimKind`
  (float/bool/int), no rendered name (proven live on `${i}`/`${f}`). The ENTIRE interpolation
  type-KIND decision is now off the string engine for typed values (only unresolved/owned-else use the
  name path). This is also the stage-4 SEED: a TypeId-keyed op replacing a name-keyed one. REMAINING
  stage-3 increments: aggregates, then calls. Each behind `--shadow`.
- **Stage 4 — TypeId-keyed destructors & mangling (medium → LARGE; two blockers found 2026-07-19d).**
  §3. `getOrCreateDestructor(TypeId)` / `mangle(TypeId)`. INVESTIGATED and pulled back — there is NO
  safe *quick* increment here (unlike `numToStringT`), for two empirically-confirmed reasons:
  1. **The name-dependent aggregate builders** (tuple/enum/error_union/storage/struct) key their
     ELEMENT types and mangled SYMBOL on the rendered name — and in a generic body that name is
     `substTypeParams`-substituted (`T`→`string`). Re-deriving it from the TypeId risks the mangled
     destructor NAME diverging from the caller's → a WRONG destructor → CORRUPTION (not a leak). So the
     aggregate cutover requires the BUILDERS to become TypeId-keyed first (get element TypeIds from the
     store, mangle from the TypeId) — that is the actual (large) work; a shim that re-renders the name
     is the hazard, not the fix.
  2. **The name-INDEPENDENT cases are dead in the hot path.** A store-dispatch handling only
     `.trait_`/`.func` (safe — those builders take no name) + `.prim`/`.ptr`→null was built, threaded a
     TypeId into `PendingTemp`, and wired into the drain — then measured: `.func`/`.trait_` fire ZERO
     times (closure/trait temps are typed `.unresolved` at drain, not `.func`/`.trait_` — the
     closure-typing gap, stage 2), and `.prim`/`.ptr` never reach the drain as owned temps. So the safe
     slice is a NO-OP; reverted rather than commit dead scaffolding on load-bearing ARC code.
  **Consequences for the plan:** (a) stage 4 destructors DEPEND ON stage 2 (closure typing) for the
  func/trait cases to be non-dead; (b) the aggregate cutover is TypeId-keying the BUILDERS, a real
  chunk, not a shim — do it as focused work, gate on `--arc`/`--asan` (which verify destructor
  correctness, so a store-vs-string divergence is caught). `mangle(TypeId)` is the enabling primitive.
  `numToStringT` (`da1d82f`) remains the clean stage-4 seed for the NAME-INDEPENDENT ops.
  **INCREMENT 1 — the destructor-name foundation, PROVEN (2026-07-21).** Before any cutover of the
  corruption-prone destructor path, PROVED the precondition in shadow: at every temp DROP (`drainTemporaries`),
  the temp's TypeId (recovered via its `expr_id`) renders — through the EXISTING proven
  `renderLegacy`+`substTypeParams` (no reimplementation → no divergence risk) — to the SAME destructor name
  the drain currently keys on (`t.type_name`, captured at registration). Result CORPUS-WIDE:
  **agree=4302, DISAGREE=0**, no-id=45 (temps registered outside `compileExpression`'s choke point, so no
  `expr_id`). DISAGREE=0 is the gate the doc demands: it proves the destructor name is faithfully
  recoverable from the TypeId, so keying the destructor on the TypeId cannot diverge from the caller.
  Report-only (`diffDtorName`, under `report_enabled`); FUNC/SHADOW/ARC 99/99, ASAN clean. NEXT increments
  (each gated on this proof + `--arc`/`--asan`): (a) close the 45 no-id by threading `expr_id` to the
  out-of-choke-point temp registrations → then `t.type_name` is DELETABLE (derive at the drain from the
  TypeId); (b) build the store-native `mangleTypeId` (renderLegacy-free) and shadow-diff IT == the
  renderLegacy path (the reimplementation the aggregate cutover needs); (c) TypeId-key the aggregate
  BUILDERS (element TypeIds from the store). Only after (b) is DISAGREE=0 can `renderLegacy` be deleted.
  **INCREMENT 2 — the drain keys on the concrete TypeId, substTypeParams-free (2026-07-21).** Two
  findings, both proven DISAGREE=0 corpus-wide (agree=4302): (1) the destructor name is recoverable from
  the temp's TypeId (increment 1); (2) the RAW render of the CONCRETE TypeId (from `typeOfInst`, the
  instantiation resolving any `T`) — WITHOUT `substTypeParams` — already equals the stored string. So
  `substTypeParams` is REDUNDANT at the drain: the concrete TypeId already carries the resolved type.
  CUTOVER: `drainTemporaries` now derives its destructor from the concrete TypeId (`drainDtorName`,
  raw `renderLegacy`, no `substTypeParams`), falling back to the stored string only for the ~45
  SYNTHESIZED temps (trait objects / err-union payloads / downcast structs — values with no source
  expression, so no `expr_id`; their type is known by name at registration). Behavior-preserving by the
  proof; verified: FUNC/SHADOW/ARC 99/99 AND an ASAN sweep of every ARC-heavy case (serde/tuple/map/enum/
  generic/trait/owned/nested/mediator/db/codec/error/closure/storage) = 0 failures — the corruption gate
  the drop path demands. The `no-id` gap is NOT closeable by threading source exprs (synthesized temps),
  so the stored `type_name` stays for those; the drain path is otherwise off the registration string and
  off `substTypeParams`. NEXT: the store-native `mangleTypeId` (renderLegacy-free) + the aggregate
  BUILDER cutover, then deleting `substTypeParams`/`renderLegacy` (stage 6, gated on ALL their callers).
  **INCREMENT 3 — `getOrCreateDestructorByTypeId`: store-kind DISPATCH, no string-prefix matching
  (2026-07-21).** Built the TypeId-keyed destructor entry that `switch`es on `store.get(t)` instead of the
  string-prefix chain (`traits.contains` / `isFunctionType` / `isTupleType` / `startsWith("ErrUnion(")` /
  `enums.contains` / storage). The name-INDEPENDENT kinds are handled NATIVELY (`.trait_`→trait dtor,
  `.func`→closure dtor, `.prim`/`.ptr`/`.unresolved`→null); every other kind DELEGATES to the string path
  (byte-identical by construction) until its builder is TypeId-keyed. Shadow-diffed it resolves to the
  SAME LLVM function as the string path: **agree=4302, DISAGREE=0** corpus-wide. CUTOVER: `drainTemporaries`
  now dispatches its destructor on the concrete TypeId (`drainDtor` → `getOrCreateDestructorByTypeId`),
  string only for synthesized no-id temps. Verified: FUNC/SHADOW/ARC 99/99 + an ASAN sweep of every
  ARC-heavy case = 0 failures. The drain's destructor dispatch is now off string-prefix matching entirely.
  NEXT: TypeId-key the aggregate BUILDERS (tuple `.tuple`→element TypeIds instead of `getTupleElementType`
  parsing; err-union `.error_union.ok/.err`; storage `.storage`; enum by `SymbolId`) — each removes a
  string-PARSER (the fragile element-recovery the doc flags as the corruption source), each ASAN-gated.
  **INCREMENT 4 — the TUPLE builder reads elements from the store (2026-07-21).** First aggregate builder
  cut over. `getOrCreateTupleDestructorByTypeId` builds the tuple destructor straight from
  `st.get(t).tuple` (the element TypeIds) — no `getTupleElementType` depth-aware string PARSE, no
  `countTupleElements`; per-element ownership is the typed `isOwnedTypeId`; the symbol name still comes
  from the name-generator (`renderLegacy`, unchanged) so it is the same memoized function. Gate proven
  FIRST: `diffTupleElems` compared the STORE elements to the string parse (arity + per-element ownership +
  rendered name) — **agree=52, DISAGREE=0** corpus-wide, kept live as a regression guard. `.tuple` in
  `getOrCreateDestructorByTypeId` now routes to it. Verified: FUNC/SHADOW/ARC 99/99 + an ASAN sweep of
  every tuple/aggregate-heavy case = 0 failures + ARC audits clean on 42/46/71/72/73/77 — the corruption
  gate, since a wrong tuple ELEMENT destructor is a UAF. The tuple destructor path is off string-parsing.
  NEXT: the same for `.error_union` (`errUnionParts`), `.storage` (`storageElem`), and `.enum_`/`.struct_`.
  **INCREMENT 5 — the ERR-UNION builder reads arms from the store (2026-07-21).**
  `getOrCreateErrUnionDestructorByTypeId` builds the tag-branch destructor from `.error_union.ok/.err`
  (the store arm TypeIds) — no `errUnionParts` string parse; per-arm ownership is `isOwnedTypeId`; releases
  via the TypeId dispatch. Gate proven first: `diffErrUnionArms` (store arms vs `errUnionParts`, ownership
  + rendered name) — **agree=12, DISAGREE=0**, kept live. `.error_union` now routes to it. Verified:
  FUNC/SHADOW/ARC 99/99 + ASAN sweep of every error/try-catch/db/serde case = 0 failures. STORAGE was
  batched in but MEASURED (via `diffStorageElem`) to have **0 coverage on this path** — a `Storage<T>` is
  never a drain temp; its destructor is built inside the STRUCT field loop (string-based), so cutting over
  `getOrCreateDestructorByTypeId(.storage)` would be untested dead code. Honestly DEFERRED: storage rides
  the struct-builder increment where it is actually exercised (the `diffStorageElem` marker stays to
  measure it there). NEXT: the `.enum_` and `.struct_` builders (fields/variants by `SymbolId`) — the last
  two string-parsers (`storageElem` inside the struct loop; enum/struct field-type strings).
  **INCREMENT 6 — STRUCT-field resolution PROVEN (the cutover's precondition), 2026-07-21.** The struct
  builder is the riskiest: generic fields substitute `T`->concrete via `substituteFieldType` (a string
  parse+substitute). First verified the store identity the resolution needs (`live_store = &sm.store`,
  shadow.zig:210 — same store), then built `diffStructFields`: per field it resolves the CONCRETE TypeId
  the sema way (lower in the struct's type-param scope + `subst.substitute(decl,args)`) and compares to
  `substituteFieldType`. Result: the corruption-relevant OWNERSHIP verdict matches everywhere —
  **agree=1932, DISAGREE=0** corpus-wide. FINDING: the RENDERED name differs in a benign class
  (`renderLegacy`->`i32`/`List<i32>` vs `typeRefToString`->`int`/`List<int>`) — a pre-existing two-renderer
  spelling discrepancy, NOT corruption: the destructors are functionally equivalent (primitive->null; the
  List bodies release equivalent both-non-owned elements), so the gate is ownership + ASAN, not name
  equality. This proves the field-TypeId resolution faithful (the cutover precondition) and stays live as
  a guard. The CUTOVER (replicating the full struct destructor: the `delete(self)` hook, the instantiation
  context, the field loop releasing each field via `getOrCreateDestructorByTypeId`) is a substantial build
  DEFERRED to its own focused pass — not rushed on the most corruption-prone code — now de-risked by this
  proof. It is where `substituteFieldType` + `storageElem` (via `Storage<T>` fields) finally retire.

  **INCREMENT 7 — the STRUCT-builder CUTOVER (2026-07-21).** `getOrCreateStructDestructorByTypeId(t)`
  built and `.struct_` routed to it in `getOrCreateDestructorByTypeId`. It reads the store's
  `StructType{decl, args}`, and for each field resolves the CONCRETE TypeId the proven-faithful way
  (lower the declared field TypeRef in `[ParamScope{owner=decl, names=type_params}]` + `subst.substitute(
  decl, args)`), decides ownership via the typed `isOwnedTypeId`, and dispatches the field destructor by
  TypeId (`getOrCreateDestructorByTypeId`) — so a nested-struct / tuple / `Storage<T>` field routes through
  the store, never a re-parse of its rendered name. Everything else is byte-identical to the string
  builder and preserved: the symbol name (`renderLegacy`→`destructorName`, same memoized function), the
  `<Struct>_delete` cleanup hook, the `current_instantiation` pin (a storage field still resolves its
  element via the string fallback, which is context-driven), and the LLVM field LAYOUT (offset/load/cast
  driven by the DECLARED `field.type_name`). A field whose TypeRef fails to lower/substitute (a residual
  generic) falls back — for THAT field only — to `substituteFieldType`, so it is never silently skipped.
  `diffStructFields` stays live inside the builder as a regression guard. GATES: FUNC 99/99; struct-field
  ownership **agree=1944 DISAGREE=0** corpus-wide; **full-corpus ASAN 77/77 clean** (the authority — a
  wrong field dtor is a UAF); ARC audit clean.

  **HONEST SCOPE — this is a PARTIAL cutover (verified, not overstated).** A struct destructor is a
  memoized SYMBOL (`__destruct_<Struct>`); whichever release site requests it FIRST builds the body. Only
  ONE release site currently carries a TypeId — the drain-temp path (expressions.zig:917, increment 3);
  the many local-variable / field / return release sites still carry STRINGS and call `getOrCreateDestructor`
  directly. So when a struct is drained as a TypeId temp first, MY builder wins and the whole subtree is
  store-native (proven live: 18 field-loop entries across 7 cases — `Allocator.{allocFn:func,ctx:ptr,...}`,
  `Response.{body:string,cookies:struct_,headers:struct_,status:enum_}` — every ownership verdict correct,
  nested `struct_` fields recursing back into this builder). When a string site wins the race, it builds the
  SAME symbol and my `.struct_` dispatch returns the existing function — identical result (ASAN-proven),
  but my field loop is skipped (only `diffStructFields`, which precedes the memo check, runs as the guard).
  CONSEQUENCE: `substituteFieldType` is retired only for the TypeId-entered cases, NOT globally — its
  string callers (the local-drain sites, llvm_codegen.zig:1417, arc.zig:446) keep it live. Likewise
  `storageElem` does NOT retire: no `List`/`Map` is drained as a TypeId temp in the corpus, so a
  `Storage<T>` field never routes through this builder (storage-elem diff stays 0-coverage). A TRUE global
  cutover is gated on migrating the release SITES to carry TypeIds — that is stage 5's ownership-IR work,
  not a destructor-builder increment. This increment is the store-native struct BUILDER, correct and safe
  wherever it is the one that runs; the site migration is what makes it the ONLY one that runs.
- **Stage 5 — Ownership disposition drives ARC + static balance check (LARGE, the payoff — scoped
  2026-07-19d).** §5. `acquisitionDisposition` reads the IR's `disposition`; delete `isRefCountedType`;
  add the balance check as a build gate. **Architectural finding (why it needs the OWNERSHIP IR, not a
  shortcut):** the check must prove every owned value's retains and releases balance. On the current
  codegen model that is INTRACTABLE — a temp's retain (`compileRetain` on the value) and its release
  (`drainTemporaries` loads a spill SLOT and releases *that*) are DIFFERENT LLVM SSA refs, and the bug
  class this session actually hit (stray `compileRetain`/`compileRelease` with no counterpart —
  template-part, if-expr) is at the raw-op level where value identity flows through slots/phis
  unpredictably. So a codegen-level ledger keyed on SSA refs cannot track balance. The check requires
  the checker to first emit **dup/drop/move ops into the IR** (arc.md §1.4/§5, at the value level,
  before LLVM slots exist), THEN a linear-use pass asserts each owned value is consumed exactly once on
  every CFG path (arc.md §6.1, Swift-OSSA-style). That IR-emission is the large build; the linear check
  on top is small. This is the one remaining piece that turns "green" into "provable" — a dedicated
  focused effort, not an increment. FIRST sub-step: the checker computes+records a per-expr disposition
  (owned/borrowed/trivial/namespace) and a `--shadow` diff proves it agrees with codegen's
  `acquisitionDisposition` (disagree=0), exactly the shadow-then-cutover discipline that has worked all
  session; then the dup/drop ops; then the linear check.
  **FIRST sub-step LANDED (2026-07-19d):** the checker computes the disposition in `inferExprExpecting`
  (`ownedDisposition`, mirroring codegen's `principledDisposition`: borrow kinds + `isOwnedSafe` on the
  type) and records it into `TypedIr.expr_owned`; codegen's `acquisitionDisposition` shadow-diffs it
  under `--shadow`. Result across the corpus: **~2450/2462 agree**, and every disagreement is in the
  SAFE direction (checker under-claims owned, never over-claims). The residue is EXACTLY two documented
  keystone gaps, `OTHER=0` corpus-wide: (1) `.type_param` — a generic ERASED return the checker sees as
  the abstract `T` while codegen monomorphizes to an owned concrete type (closes with F4 per-call-site
  return recording); (2) `.enum_` — a payload-carrying enum `isOwned` reads coarsely (closes with the
  F5 `.enum_` variant-awareness follow-up). So the checker provably CAN own the disposition everywhere
  except those two tracked gaps — the precondition for the dup/drop ops is met. Gates: FUNC 70/70, ARC
  119/119, SHADOW 119/119, ASAN 119/119, unit.
  **SECOND sub-step (dup/drop ops + balance check) LANDED (2026-07-19d):** new pass `src/sema/ownership.zig`
  (arc.md §5), run in shadow. Increment 1 targets owned `let`-LOCALS — the tractability insight from
  step 1: a temporary's retain-on-value vs release-on-slot are different SSA refs (intractable), but a
  named local has a stable slot/name and is analyzable from the AST alone. Per function it walks the
  straight-line body, decides each owned local via `store.isOwnedSafe` (NO strings), inserts the §2 ops
  (scope-exit `drop`; `move` when returned/rebound; `dup` on a second move-out), and runs the §6.1
  STATIC BALANCE CHECK: exactly one terminal consumer, no use-after-move. A local whose lifetime crosses
  nested control flow / is reassigned / is shadowed / has an untyped init is DEFERRED (no claim) — the
  honest boundary; the CFG last-use (Perceus per-edge drops) and temporaries are later increments.
  Corpus result: 0 balance violations everywhere (consistent with the green `--arc`/`--asan`), ~60% of
  owned locals analyzed straight-line, ~40% deferred to the CFG increment. The check has TEETH: a
  synthetic `let b = a; use(a)` is flagged as use-after-move on `a`, so 0-on-corpus is soundness, not
  vacuity. Report-only; codegen untouched. Gates: FUNC 70/70, ARC 119/119, SHADOW 119/119, ASAN 119/119,
  unit.
  **THIRD sub-step (CFG last-use / per-edge drops) LANDED (2026-07-19d):** extended `ownership.zig` from
  straight-line to full structured control flow. Kyte has no gotos, so backward last-use is a forward walk
  with a per-path ownership state (`live`/`moved`) and a branch-MERGE: where one `if` arm moves the local
  and the other does not, a PER-EDGE `drop` is inserted on the non-moving arm so every path consumes it
  exactly once (the Perceus rule). Loops are modeled as borrow-across-iterations (a move-in-loop still
  defers). Result: coverage of owned locals jumped from ~60% to **98.7% corpus-wide (2176/2204 analyzed,
  28 deferred), 0 balance violations**. The check keeps its TEETH on the new paths too: a
  `let a=mk(); if c {let b=a;} else {sink(a);} sink(a);` is flagged use-after-branch-move, while the
  balanced `if c {sink(a);} else {let b=a;}` inserts a per-edge drop and passes. Remaining 1.3% deferred:
  move-in-loop, reassignment, shadow, switch/break/continue, closure-captured locals. Report-only.
  Gates: FUNC 70/70, ARC 119/119, SHADOW 119/119, ASAN 119/119, unit.
  **FOURTH sub-step (TEMPORARIES) LANDED (2026-07-19d):** the pass now accounts for owned TEMPORARIES too
  — an owned producer occurrence not bound to a name (a call returning managed, a constructor, a
  string/template, an aggregate literal). It walks every expression with a position context and gives
  each `ir.ownedOf==true` occurrence its consumer: MOVED (into a bind/return/aggregate element) or DROPPED
  at the enclosing statement's end — the pass-side model of codegen's
  `registerTemporary`/`consumeTemporary`/`drainTemporaries`. Completeness is measured against the
  disposition oracle (`ownedTrueCount` = every owned occurrence the checker recorded, closure interiors
  included): **non-closure code is 100% accounted corpus-wide**; the only shortfall is closure interiors
  (the walk does not descend closure bodies — quantified, e.g. 34_module_type_in_closure=12, 49=8, and a
  synthetic closure-body temp = exactly 1). FINDING: temp balance is satisfiable BY CONSTRUCTION (every
  visited owned temp gets a move or a stmt-end drop), so its teeth are COVERAGE (unaccounted → the
  closure set), not internal balance; the adversarial per-temp teeth is a per-ExprId diff against codegen,
  which is the CUTOVER's job (a raw pass-vs-codegen TOTAL diff was tried and DROPPED — the two models
  count different populations, so a Δ reads as disagreement when it is just different denominators). The
  ownership IR is now complete for locals (balance-checked, 98.7%) + temporaries (accounted, 100% non-
  closure). Report-only. Gates: FUNC 70/70, ARC 119/119, SHADOW 119/119, ASAN 119/119, unit.
  **FIFTH sub-step (CODEGEN CUTOVER — shadow half) LANDED (2026-07-19d):** the pass now RECORDS its per-temp
  op into the IR (`expr_op: ExprId -> move|drop`), and codegen shadow-diffs its OWN action at the EXACT
  site — a `drop` in `drainTemporaries`, a `move` in `consumeTemporary` — against the pass's op, keyed by
  the `ExprId` threaded into `PendingTemp` (set at `compileExpression`'s choke point). This is the clean
  PER-EXPRID diff the temporaries step said was needed. Result: after closing an assignment-RHS gap in the
  pass (`x = e` MOVES `e` — codegen consumes it), agreement is **4977 agree / 70 disagree corpus-wide
  (98.6%)**. The 70 residue is fully characterized by direction AND type — a small EXPLAINED set, not
  random: (a) codegen=move/pass=drop on `optional` (31) — optional consumption + the consuming-arg ABI
  (push/set store the arg; arc.md §3 wants a `consuming` mark the pass lacks); (b) codegen=drop/pass=move
  on `tuple`(11)/`struct_`(11)/`error_union`(8) — return/aggregate positions where codegen copies-then-
  drops rather than moves. Behaviour UNCHANGED: all diff code is under `report_enabled`; `expr_op`/`expr_id`
  are unread in a normal build. The FLIP (codegen obeys `expr_op`, delete the `pending_temps` heuristic) is
  correctly BLOCKED until the 70 reconcile — flipping now would regress on them.
  **SIXTH sub-step (RECONCILE the 70) LANDED (2026-07-19d):** five clean POSITION-MODEL corrections in the
  pass, each matching codegen's gate-verified behavior, took disagree **70 -> 18 (98.6% -> 99.6%)**: (1)
  `x = e` MOVES `e` (assignment-RHS was walked as a drop) — the big one, -262; (2) `a ?? b` — the optional
  `a` is always CONSUMED by the `??` (was inheriting the parent position) — -31 optional; (3) `let (a,b) =
  e` destructuring DROPS the aggregate box after extracting elements (was a move) — -11 tuple; (4) an
  if-expr's BRANCHES are consumed by the phi regardless of where the if-expr sits (only the RESULT inherits
  the parent) — -2; (5) `try e` / `e catch h` — the error-union BOX is dropped after the payload is
  extracted (the operand was inheriting the parent) — -8 error_union. The remaining **18 are TWO PRINCIPLED
  classes, not position bugs**: (a) cg=drop/pass=move (12) — returned producer temps (codegen does
  retain-on-return + drain-drop) and struct->trait coercion (codegen copies into the trait + drops the raw
  struct); here the PASS IS RIGHT (a clean move) and the FLIP removes codegen's redundant work; (b)
  cg=move/pass=drop (6) — constructor/consuming args (`Msg.Text(concat)`, container inserts) that codegen
  consumes but the pass treats as borrow, needing the arc.md §3 `consuming` mark the pass does not have.
  So the position model is now COMPLETE; the residue is exactly the flip-cleanup + the §3 ABI feature — both
  known larger workitems, neither a pass bug.
  **SEVENTH sub-step — THE FLIP (acquisition authority) LANDED (2026-07-19d):** codegen's
  `acquisitionDisposition` — the decision that REGISTERS a temporary — now OBEYS the checker's recorded
  `ownedOf` verdict FIRST, falling back to its own `principledDisposition` only where the pass did not
  record owned. This is sound because the disposition oracle proved the pass NEVER over-claims: every
  recorded disagreement was `pass=borrowed / codegen=owned`, only on the two keystone gaps — so
  `ownedOf==true` can only agree with what codegen would own, and the fallback still correctly owns the
  keystone under-claims (`.type_param` erased returns, payload `.enum_`) until F4 / enum-awareness close
  them. This is the FIRST place codegen reads the checker's ownership verdict to drive a real decision —
  the authority is now pass-first, codegen-fallback (the inversion §5 calls for). Behaviour-preserving on
  the whole corpus (there is provably no `pass=owned / codegen=borrowed` case); the `--shadow` diff still
  compares PRINCIPLED vs pass so it keeps proving agreement (OTHER=0). Note: this flips the ACQUISITION
  side (register-or-not); a drain-side flip is NOT yet possible — codegen already consumes returned temps
  (`consumeTemporary(rv)` before drain) and moves via `consumeTemporary`, so the 18 residue are genuine
  mechanism cases (coercion SSA-mismatch, consuming-ABI), not redundant work a drain flip would remove.
  NEXT: close the keystone gaps (enum-variant awareness in `isOwned`; F4 for `.type_param`) to DELETE the
  `principledDisposition` fallback; §3 `consuming` marks to clear the 6 consuming-arg temp disagreements;
  then the string engine. Gates: FUNC 70/70, ARC 119/119, SHADOW 119/119, ASAN 119/119, unit.
- **Stage 6 — Delete the dead machinery (small, satisfying).** `isRefCountedType`, `substTypeParams`,
  `findLambdaCallSite*`, `resolveCalleeName`'s scan (read `expr_syms` instead), the string
  `renderLegacy` decision paths. The static balance check is now the gate.

Estimate: Stages 0–2 ~1 wk (coverage + closures); 3–4 ~1 wk (cutover + TypeId names); 5 ~1 wk
(ownership + balance check); 6 ~2 days. **~3–4 focused weeks**, bounded, each stage independently green.

---

## 8. What F2-6 closes, itemized

- **Closure-param typing** (incl. untyped higher-order) — §4, stage 2. Retires `findLambdaCallSite`.
- **ARC ownership provably correct** — §5, stage 5. Deletes `isRefCountedType`; adds the balance check.
- **F1 call resolution** — codegen reads `expr_syms`; retires `resolveCalleeName`'s scan (stage 6).
- **F4 generics** — `expr_method_args` + TypeId-keyed mangling; retires `substTypeParams` (stages 4/6).
- **The ~147 string-guessing sites** — reduced to lowering of a complete IR.

**Does NOT close (separate, unrelated):** F3-5a decimal literals (a lexer feature), F1-6 Itanium
mangling cosmetics, F3-5 honest i32 slots (perf). None are correctness.

**Result:** the foundation reaches a *defensible, provable* 100% on the correctness axis — the checker
decides, codegen lowers, and a build-time check proves ownership balance on all paths. That is the
difference between "we haven't found a bug" and "a bug of this class cannot compile."

---

## 9. Risks & mitigations
- **ExprId stability across AST clones** (the serde reparse, the test harness synth) — an id must
  travel with every copy. Already handled for `expr_types` (stage 4a); stage 1 must verify the
  currently-untyped clones aren't clone-id misses. Mitigation: `unassigned_rejected` must stay 0, and
  the coverage counter is per-construct.
- **Second-pass cost/termination** (§4) — bound: one extra walk per function with an un-inferrable
  closure param; no fixpoint loop (a single use-directed refinement). Mitigation: cap at one pass;
  a param still unresolved after it stays `unresolved` (honest, non-crashing).
- **`namespace` disposition leaking into a value position** — a module ident used as a value is a
  real error (F2-5 territory). Mitigation: the balance check + the existing F2-5 fatal.
- **The balance check rejecting valid programs** (false positives) — the Swift-OSSA risk. Mitigation:
  land it in SHADOW first (report violations, don't reject) until the corpus is clean, then enforce —
  exactly how `--shadow` and the visibility/const gates were introduced.

---

## 10. First concrete step
Stage 0: in `src/sema/shadow.zig`'s F2 EXPRESSION report, split `UNRESOLVED` into `namespace` vs
`genuine` (a predicate on whether the ident/field resolves to a module/namespace symbol). This turns
"~594 unresolved, scary" into "~N genuine gaps, here they are" — the honest denominator that tells us
how far stage 1 actually is. Do NOT change any behavior. When `genuine` is a small, named set, begin
stage 1.

---

## 11. Relationship to the other docs
- **arc.md** — the ownership model & rule table; F2-6 stage 5 is where arc.md's `disposition` + balance
  check land *in sema* (arc.md built the codegen-level version; F2-6 promotes it). [[kyte-arc-acquisition-rewrite]]
- **chained-map-leak-findings.md** — the closure-param residual F2-6 stage 2 closes.
- **FOUNDATION-STATUS.md** — F2-6 is the one open item on F2 (96%) and the enabler for F4-5/F5 O4.
- Spec-first: no new syntax, so no `specs.md` change — F2-6 is internal correctness. [[kyte-spec-first-workflow]]
