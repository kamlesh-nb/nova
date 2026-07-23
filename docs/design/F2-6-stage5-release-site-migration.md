# F2-6 Stage 5 — Release-Site TypeId Migration (scope)

> **STAGE 5 COMPLETION ASSESSMENT (2026-07-21) — migration is at its PRODUCTIVE CEILING.** Measured after
> the release-site flips + renderer unification + R1/R2 erased-body reachability:
> - **Release-site flips: flip=8082, split=686, no-id=24. ALL 686 splits are the ERASURE FLOOR** (the
>   TypeId's element is `.unresolved`/a type-param `<U>/<T>/<K>/<V>` — from erased generic bodies — so the
>   string path is genuinely MORE informed; 0 are flippable). The migration cannot flip more without
>   eliminating the abstract residue.
> - **`isRefCountedType` = 244,029 calls, of which 224,231 (92%) are PRIMITIVES** (i32/void/bool/string —
>   trivially non-owned, string and TypeId paths AGREE, ZERO safety risk) and only **19,798 (8%) are the
>   composite/parser-relevant path** (List<>/Map<>/Storage<>), itself dominated by the erasure floor.
>
> **⇒ Phase E (delete the string parsers) and full `isRefCountedType` retirement are BLOCKED/low-ROI:**
> deleting the parsers needs the string destructor builders unreachable, which the 686 erasure-floor splits
> + the 3 surviving abstract-residue erased bodies keep reachable — blocked on **abstract-residue
> elimination** (routing inferred-arg method calls like `xs.map((x)=>..)` to a SPECIALIZATION instead of the
> erased base body, so no `List<U>` residue; a method-monomorphization-model feature, not a bounded fix).
> The 92% primitive fraction is the F5-2 "40 ownership-decision-site" migration — LARGE and ZERO safety
> benefit (primitives agree). Stage 5's SAFETY goal is fully met; the remaining purity work is
> large + low-value, gated on abstract-residue elimination. See `F4-monomorphization-completion.md`.


> **STATUS: Phase A LANDED (commit 3feecb1).** `getOrCreateDestructorPreferId` + the same-symbol gate
> wired into the three name-keyed sites. Corpus-wide: **flip=7744** store-native selections, split=4 (the
> erased `List<U>` vs concrete `List<string>` class, correctly kept on strings), no-id=66. Downstream:
> storage-elem diff coverage 0 → **agree=1108 DISAGREE=0** (C1 precondition now MET); struct-field agree
> 1944 → 8599, DISAGREE=0. Gates: FUNC 99/99, full-corpus ASAN 0, ARC audit clean. Bug fixed mid-flight:
> freeing `renderLegacy`'s (Sema-interned/static) result corrupted the heap → FUNC 22/99; the free was
> removed.
>
> **STATUS: Phase C1 LANDED (commit cd259f3).** `getOrCreateStorageDestructorByTypeId` +
> `buildStorageDestructorLoop` (shared element-agnostic loop) + `buildStorageDestructorByTypeId`; `.storage`
> routed to the twin in the dispatch. Verified: storage-elem agree=1108 DISAGREE=0 (guard now inside the
> twin), FUNC 99/99, ASAN 0, ARC clean, no duplicate `__destruct_Storage_*` symbols. `storageElem` NOT yet
> deleted — arc.zig:854/923 still serve the string struct builder (string-first races), :1409 is the diff
> guard; it retires in Phase E.
>
> **STATUS: Coverage extension + Phase D#6 LANDED (commits 3d8ecff, 6b3bb64).** `tidForTypeRef` keys
> annotated lets by TypeId (no-id 66→23, flip 7778→8106); field-reassign old-value release flipped.
> **Phase E is BLOCKED and reframed as tracked debt, not a fix.** Measured: `isRefCountedType` is called
> ~262k×/corpus, unchanged by coverage extension — it is dominated by string destructor-BUILDER internal
> field decisions AND the ERASED generic bodies (`__destruct_List_T`/`Storage_K`, type-param elements),
> which are inherent to type-erased generics and cannot be removed without COMPLETING full monomorphization.
> The string builders stay reachable, so the string PARSERS (`storageElem`/`substituteFieldType`/
> `getTupleElementType`) cannot be deleted. Crucially, A2 is memory-SAFE regardless: the unknown-name guess
> is a tripwire abort and the F5-2 gate proved `store.isOwned == isRefCountedType(render)` DISAGREE=0. So
> Phase E = a large architectural migration (full mono + ~40-site TypeId thread) with ZERO safety payoff.
> Per the project's "don't ship rushed corruption" discipline, it stays tracked, not forced.
>
> **STATUS: Phase B LANDED (commit fce9765).** The 7 expr-in-hand sites (widenBranchToTrait, reassign
> .ident/.field_access widen, struct-init field widen, tuple-element widen, let-widen, expr-stmt temp drain)
> now route through `getOrCreateDestructorPreferId(str, ir.typeOf(expr))`. flip 7744 → 7778 (+34), split=4,
> no-id=66 unchanged; FUNC 99/99, ASAN 0, ARC clean. NEXT: Phase D (threading/hardcoded sites #6/#8/#15) —
> mostly optional — then Phase E (delete the string parsers once the string struct builder is retired).


**Goal.** Make the store-native destructor builders (increment 7's struct builder + the tuple/err-union
twins) the path that *actually runs*, by migrating the destructor-SELECTION at release sites from the
string key (`getOrCreateDestructor(string)`) to the TypeId key (`getOrCreateDestructorByTypeId(tid)`).
This is the lever that turns the increment-7 struct builder from "correct where it happens to run" into
"the only builder," and is the precondition for retiring the string parsers
(`getTupleElementType`/`countTupleElements`/`errUnionParts`/`storageElem`, and `substituteFieldType` from
the destructor path).

Why it is NOT more builder work: the builders already exist and are proven (DISAGREE=0 + ASAN). The reason
they don't run is that a struct destructor is a memoized SYMBOL, and the string-carrying release sites
create that symbol first. Migrate the sites and the store-native builder wins the symbol.

## Load-bearing measurement (already taken)
At the function-exit drain (`releaseLocalVariables`, the highest-volume site), owned locals already carry a
usable TypeId in `current_local_type_ids` for **4881 of 4942 = 98.8%** corpus-wide. The 61 stragglers are:
function PARAMS (`k`, `p`, `nm` — populated as strings, never interned), a few annotated / null-`typeOf`
lets (`dummy:TcpStream`, `xs:List<int>`, `s:Speaker`, trait locals `g:Greeter`/`hb:G`), and `decimal`
locals. So the coverage-extension work is small and bounded; the map is essentially ready.

## The one real RISK to gate on (two-renderer symbol split)
The string path names the destructor from `current_local_types`' string (ultimately `typeRefToString` →
`int`/`List<int>`). The TypeId path names it from `renderLegacy(tid)` (→ `i32`/`List<i32>`). Where these
spellings differ (the known benign `i32`/`int` class, increment 6), flipping the SELECTION would emit a
SECOND symbol (`__destruct_List_i32` alongside `__destruct_List_int`) — both correct, but duplicated and no
longer "the same memoized function." **Every phase's gate must therefore include a same-SYMBOL check**: for
each flipped release, assert `renderLegacy(tid)`-derived `destructorName` equals the string path's
`destructorName`. Where it matches (the vast majority), flip. Where it diverges (the `i32`/`int` List
spelling), either reconcile the renderer first (this is the stage-6 `renderLegacy`/`typeRefToString`
unification) or keep that specific local on the string path until stage 6. Do NOT ship duplicate symbols
silently. A wrong dtor is a UAF; a duplicate dtor is a smell that hides the next wrong one.

## Site inventory (from the codegen sweep)
Top-level release sites of `getOrCreateDestructor(string)` whose result feeds `compileRelease`:

| # | site | scenario | keyability |
|---|------|----------|-----------|
| 2 | arc.zig:~1528 `releaseLocalVariables` | function-exit drain | **easy** — TypeId already loaded at this line for the shadow report; key by `current_local_type_ids.get(var_name)` |
| 1 | arc.zig:1485 `releaseLocalByName` | block-scope (O4) local release | **easy** — has `name`; consult `current_local_type_ids.get(name)` (no signature change needed) |
| 4 | expressions.zig:1097 | reassign `.ident`: release OLD value | **easy** — has `name` → `current_local_type_ids.get(name)` |
| 3,5,7,9,10,13,14 | expressions.zig:39/1117/1190/2515/2847, statements.zig:185/251 | trait-widen orphan-struct release + expr-stmt temp drain | **easy** — each has the `ast.Expression*` → `ir.typeOf(expr)` (mirror the `drainDtor` template at expressions.zig:917) |
| 6 | expressions.zig:1171 | reassign `.field_access`: release OLD field | **medium** — has declared `field_type_ref`; lower+`subst.substitute` like the struct builder does |
| 8 | expressions.zig:1746 | storage `.set(i,x)`: release OLD element | **medium** — reach `.storage.elem` from `fa.object`'s store type; depends on C1 |
| 11,12 | expressions.zig:3797/3958 | generic-parse/convert temp drain | **hard** — hardcoded `"JsonValue"`/`"YamlValue"`/`"List"`; need those names resolved to TypeIds. Low frequency; keep string fallback |
| 15 | llvm_codegen.zig:1143 `getGlobalVTable` | vtable slot-0 dtor pointer | **medium** — threads `struct_name` string; intern its TypeId (via `lower`) or thread a TypeId param |

Builder-internal element releases still on strings (retire alongside their twin): `.storage`
(arc.zig:583 `buildStorageDestructor`), enum payload (arc.zig:1176), closure-cleanup capture slot
(expressions.zig:674, also a known capture-leak gap). Struct/tuple/err-union already recurse via the TypeId
twin.

## Phasing (each phase independently shippable, gated identically)
**Gate for every phase:** (1) same-SYMBOL check per flipped release (above); (2) full-corpus ASAN 0
failures; (3) ARC audit clean; (4) FUNC 99/99. Flip is byte-identical where both resolve → the ASAN gate is
authority.

- **Phase A — the drain site (#2, + #1, #4; the 98.8%-ready lever).** Flip the three name-keyed sites to
  prefer `getOrCreateDestructorByTypeId(current_local_type_ids.get(name))`, string fallback otherwise. This
  is where the increment-7 struct builder finally runs for real (≈4900 locals) AND where `List`/`Map`
  locals first push their `Storage<T>` field through the TypeId dispatch — giving `.storage` its first real
  diff coverage (still delegates to the string storage builder, so SAFE without the storage twin).
  Highest value, lowest code churn, heaviest verification.

- **Phase B — the expr-in-hand sites (#3,#5,#7,#9,#10,#13,#14).** One mechanical pattern (the `drainDtor`
  template): add `ir.typeOf(expr)` beside the existing `resolveExpressionTypeName(expr)` and prefer the
  TypeId. Eight sites, all trait-widen orphan releases + temp drains.

- **Phase C — builder TypeId twins that unblock parser retirement.**
  - **C1 `.storage` twin** (`getOrCreateStorageDestructorByTypeId`, route `.storage` in the dispatch).
    Precondition now MET once Phase A runs (`diffStorageElem` gets coverage from struct-field storage
    dispatch); prove DISAGREE=0, then cut over. **Retires `storageElem`.**
  - **C2 enum twin** — LOW priority: enums aren't parameterized, the builder reads the AST decl, so there
    is no string PARSER to eliminate (per the parked note). Do only for #1176 consistency if convenient.

- **Phase D — threading / hardcoded sites (#6, #8, #15; #11/#12 optional).** Signature/threading changes:
  #6 lowers the declared field TypeRef; #8 reads `.storage.elem` (after C1); #15 interns the struct name.
  #11/#12 (hardcoded `JsonValue`/`YamlValue`/`List`) can stay on the string fallback indefinitely — bounded,
  rare, and correct.

- **Phase E — retire the string parsers.** Once every release site + builder-internal element release is
  TypeId-keyed: delete `getTupleElementType`, `countTupleElements`, `errUnionParts`, `storageElem`, and
  drop `substituteFieldType` from the destructor path. `substituteFieldType`'s NON-destructor callers
  (llvm_codegen.zig:1417, arc.zig:446) and the `renderLegacy`/`substTypeParams` decision paths
  (resolveExpressionTypeName etc.) are a SEPARATE stage-6 sweep, not part of this migration.

## Coverage-extension (parallel, unblocks a 100% Phase A)
To move the last 61 stragglers off the string fallback: intern TypeIds for (a) function PARAMS at the
`declarations.zig` pre-pass (the param TypeRef is in hand), (b) annotated / null-`typeOf` lets (lower the
annotation), (c) `self` (its instantiation string is known — lower it). Not blocking (the string fallback
is correct); it is what lets Phase E delete the parsers with zero remaining string-keyed owned releases.

## Effort
Phase A ≈ 0.5d (tiny edit, heavy verification — it is the big exerciser). Phase B ≈ 0.5d. Phase C1 ≈ 0.5d.
Phase D ≈ 1d. Phase E ≈ 0.5d. Coverage-extension ≈ 0.5d. ~3–3.5d total; **Phase A alone** delivers the
headline win (store-native struct builder actually runs for all locals) and is shippable on its own.

See [[nova-f2-6-stage4-parked]] and docs/design/done/F2-6-typed-ir.md (increment 7, honest-scope note).
