# Foundation (F1–F5) — Status Board

**This is the single source of truth for F1–F5.** Every row is code-audited, not doc-trusted.
Progress logs live in `beta-readiness-plan.md`; this file is the *board* you scan to see what's done.
Gates as of last edit (**2026-07-19d**): conformance **70/70** · `--arc` **120/120** · `--asan` **120/120** · `--shadow` **120/120** · `zig build test` ✅.

> ⚠️ **HONESTY CAVEAT (the throughline of the 2026-07-19 session).** A high % here means "no *known*
> bug on a corpus that has repeatedly hidden bugs" — NOT "provably correct." This session alone found,
> on a fully-green foundation: an orphaned-tuple leak, an owned-if-expr **use-after-free**, a
> template-part leak, a closure box/result leak, a closure-string **SIGSEGV**, and a closure-param
> mis-format — none tripped the gates until a case exercised the pattern. The only thing that upgrades
> "green" to "provable" is F2-6 stage 5's **static balance check** (arc.md §6.1), which is not built.
> Read the per-phase %s as "correct-for-covered-scope + how principled the layer is," with that asterisk.

## 📊 Scorecard

| Phase | Done | Partial | Open | ~% | One-line state |
|---|---|---|---|---|---|
| **F1** name resolution | 1, 2, 3a, 3b, 4, 5, 7 | 6 | - | **95%** | Scan DELETED, module scoping ENFORCED, undefined-ident = typecheck error. **2026-07-19: two-keyword model enforced — `let` (mutable) + `const` (enforced-immutable), `var` REMOVED (parser rejects it, 169 sites migrated).** Remaining: Itanium mangling (F1-6, cosmetic) |
| **F2** typed IR | 1-4d, 5, 6:0/1/2/3p | 6:rest | - | **97%** | undefined-ident hard sema error (F2-5). **F2-6 UNDERWAY 2026-07-19 (stages 0,1,2,3-partial): the IR is ~99.5% complete for VALUES (the "gap" was ~90% namespace/method-callee noise); closure params typed from call sites (second-pass, `bfa24aa`); interpolation type-decisions read the store.** Remaining: finish stage-3 cutover (codegen reads typeOf everywhere) → stage-4 TypeId-keyed destructors → stage-5 static balance check (the "provable" upgrade) → stage-6 delete the string engine |
| **F3** primitives | 1, 2, 3, 4, 4b, 5, 6 | - | 5a, 7 | **86%** | **F3-5 int-overflow CORRECTNESS verified DONE (18u): int arithmetic wraps at 32 bits via canonicalizeInt on every op (19_int_overflow passes); long doesn't.** i64 slot stores the canonical value (not a lie). Remaining: honest i32 SLOTS = memory-opt only (wide/risky, low value); overflow debug-trap = optional; ~27 `orelse "i32"` guesses (F3-7) |
| **F4** generics | 2, 3, 4, 4b, 5 | 6 | 1 | **88%** | `.type_param` corruption-class DONE; erasure rule principled. **2026-07-19: the "chained-generic-method leak" — F4's one hard SOUNDNESS blocker — is CLOSED. Root cause traced (NOT generics-mono as long assumed): a template-interpolation `${var}` retain-without-release (`63217a8`); `xs.map(f).map(g)` leaked because map's closure interpolates its owned element. Fixed + the closure typing that fed it (`bfa24aa`).** Remaining is CODE-SIZE cleanup, not soundness: method-level mono (List_U_push), type-param-receiver resolution, drop erased body; serde source-gen reparse-based |
| **F5** ARC ownership | 2a,3,5,O4,acquisition-rewrite,cases-41-49 | balance-check | - | **95%** | **The DANGER is dead: no ownership decision is made by an unprincipled string guess** — proven corpus-wide (NOVA_SEMA_SHADOW, disagree=0) and enforced by the `--shadow` gate. ARC 0 leaks. **Coverage-probe pass (cases 41–45) fixed 5 real defects the corpus was dodging: struct-literal owned-field UAF, single-letter struct misclassified, struct-literal-as-arg leak, trait-downcast UAF, and the `try`-returns-owned double-free (payload was registered twice; masked as a box leak by a return band-aid).** `--asan` is a REQUIRED gate (ARC-audit is blind to these UAFs). **2026-07-19 ACQUISITION-LAYER REWRITE (arc.md Option A): the RAII "constructor" (acquisition) half is now ONE principled TypeId decision (`acquisitionDisposition`/`takeOwnedElement`), matching the (already-correct) destruction half — no producer whitelist, no per-site string-kind re-derivation. Fixed 6 real bugs this session, each with a regression case (46-49): orphaned-tuple leak, owned-if-expr UAF (per-edge drops), template-part leak, chained-map leak, closure box/result leak, and a closure-string SIGSEGV.** Remaining to a PROVABLE 100%: promote the codegen-level rule to a sema pass with the **static balance check** (arc.md §6.1, = F2-6 stage 5) — until then "green," not "proven"; O4 formal audit subsumed by it |

Legend: ✅ done · 🟡 partial · ❌ open. Per-stage evidence tables below.

## 🛤️ What "Lane A" is (it maps onto F-stages — it is not a separate track)

"Lane A" = finishing the foundation *properly*: kill "codegen decides semantics by string-matching type
names" by migrating ownership/structural decisions from rendered strings to `TypeId`. It is not a new
phase — it **is** the completion of these exact stages, done behind a shadow-diff safety net:

- **Keystone** (per-instantiation typing in the store) → completes **F5-2** ownership decider. ✅ cut over 18d.
- **`.type_param` elimination** (drop the erased body) → **F4-5**. ❌ the big remaining build (Task #1).
- **`.unresolved` fatal** → **F2-5**. ❌ (Task #4).
- **Mechanical structural-predicate conversion** (getTypeSize/toLLVMType/isStructType TypeId versions) →
  the §4.4 tail of `string-to-typeid-migration.md`, folded into F5-2/F2-5 cleanup.

## ✅ Landed this session (2026-07-18, Lane A)

- **Shadow-diff harness** (18b): computes both engines' ownership answer at every `isOwnedTypeId` site;
  proved `DISAGREE=0` → migration is safe. `NOVA_SEMA_SHADOW=1` prints the live breakdown.
- **Keystone cutover** (18c/18d, first real string→TypeId cutover): struct-level `.type_param` ownership
  now resolved via `subst.substitute` in the store, byte-identical (`DISAGREE=0`, `keystone-DISAGREE=0`).
- **map<U> refcounted leak FIXED** (18e, `f35d8b4`): `xs.map((x) => \`val${x}\`)` was `List<U>` (erased,
  leaked 303/100 iters). Fixed at the **sema** layer (closure arg now gets the declared `(T)->U` as its
  expected type, so `U` solves to `string`). Result: 303→3 leaks (= floor, leak-free), values correct.
  New gate `40_map_refcounted_closure`. **Method-mono was NOT needed** and its earlier attempt produced
  garbage — deferred as pure-optimization (Task #1).
- **F4-5 principled erasure** (18f, `35a8883`): the last string-matched `.type_param` **ownership**
  decision removed — an unbound param is an opaque non-owned word by RULE (sound: erased body does no
  ARC on `T`; the concrete-typed caller compensates). Cleaner than "make `.type_param` fatal".
- **F5-2 all ownership decision sites → store-based** (18g/18h): the 10 `isRefCountedType` DECISION
  sites (return/append/Storage get-set + err-union/tuple/Storage destructor generators) now go through
  `isOwnedTypeId` via `isOwnedExpr`/`isOwnedStorageElem`/`isOwnedErrUnionPayloadByName`/
  `isOwnedTupleElemByName`/`isOwnedStorageElemByName` + a rendered-name→TypeId reverse index (verified
  it FIRES). **Measured: no `isRefCountedType` ownership decision remains outside `types.zig`.**
- **F2-5 decision-site tripwire** (18i): `isOwnedTypeId(.unresolved)` (reached zero times, measured) is
  now a loud located compiler error, not a silent guess.

**Net this session: the corruption-class of "codegen decides ownership by string-matching type names"
is closed** — every ownership decision is store/rule-based, `DISAGREE=0`, and the two remaining silent
guesses (`.type_param`, `.unresolved` at a decision) are now a principled rule and a tripwire. All gates
green throughout (corpus 59/59, `--arc` 100/100, `--asan` 100/100, unit).

## 🎯 Remaining work is tracked as UI tasks (this session)

Tasks #1–#12 cover every 🟡/❌ stage with dependency edges. The spine: **#1 F4-5 (drop erased body)** and
**#2→#3 F4-6→F1-3b** are the two unblockers; **#4 F2-5**, **#5 F5-2**, **#6 F3-7**, **#11 F5-cleanup**
depend on them. #7 (int slots), #8 (F4-1 parse), #9 (module scoping), #10 (mangling/N3), #12 (checker/decimal)
are independent and can land anytime.

---

## Detailed audit (measured 2026-07-18 by direct code audit — 5 parallel audits)

The per-F design docs' stage tables are correct but their *headers* lag; the tables below are ground truth.

## ⚠️ Cross-dependency found by experiment (2026-07-18) — NOT in any design doc

Typing a previously-`.unresolved` **receiver ident** (`bytes` in `bytes.alloc()`, `Status` in
`Status.Ok`) — whether as `.module`, `.struct_`, or `.enum_` — **breaks codegen**: module-qualified
calls turn into failed method dispatch and `Status.Ok` in a closure fails "Identifier not found".
Root cause: **codegen keys its value-vs-namespace routing on "does the receiver expression have a
sema type?"** A receiver with no type ⇒ name-based namespace resolution (`isNamespaceReceiver`); a
receiver with a type ⇒ value/method path. So giving these idents an honest type flips the routing.
(Measured: `13_serde` 615→539 unresolved, but corpus 58→49 — reverted.)

**Consequence:** the dominant F2 unresolved clusters (module/type receivers: `bytes`×138, `json`,
`JsonValue`, …) **cannot be typed until F1-3b** makes codegen's namespace detection authoritative
(routing by `SymbolId`, not by "has a type"). So **F2 stage 5 completion depends on F1-3b**, and the
receiver-ident reduction is NOT a standalone win. Do them together.

## The one dependency that gates the endgame

Three audits converge on the same spine. The full ARC correctness swap is **measured-blocked**:
**7,157 corpus expressions reach a codegen decision carrying `.type_param` (3,360) or `.unresolved`
(3,797)**, and `isOwned(TypeId)` marks both `unreachable`. So the order is forced:

> **F4-5 (monomorphize → eliminate `.type_param` at codegen) → F2-5 (`.unresolved` fatal at end of
> sema) → F5-2 (`isOwned(TypeId)` is the sole ownership decider).**

Everything else is either already landed, or an application that sits on top of this spine.

## Per-stage status

### F1 — name resolution  (Landed 1,2,3a,5 · Partial 6 · Open 3b,4,7)
| Stage | Status | Evidence |
|---|---|---|
| 1 symbol table (shadow) | ✅ | `sema/symbols.zig`, wired `main.zig:1137` |
| 2 divergence-fix | ✅ | `shadow.zig:71-186` |
| 3a N2 ambiguity = error | ✅ | `types.zig:709,733` `error.AmbiguousName`; `expect_fail/ambiguous_bare_call` |
| 3b **cut codegen to SymbolId** | ❌ OPEN | `grep SymbolId src/codegen` = 0; **227 func_map lines + 17 endsWith** still scan; suffix scans `types.zig:697,721` |
| 4 **real module scoping** | ❌ OPEN | loader discards imports `main.zig:474`; `is_public` unchecked cross-module; no ModuleId scopes |
| 5 lexical block scope | ✅ | `sema/alpha.zig`; `16_block_scope` |
| 6 length-prefixed mangling | 🟡 PARTIAL | `$HOME`-free (`getModulePrefix`), but not Itanium length-prefixed; 40-entry allowlist + `self`-spelling struct detection alive |
| 7 N3 failure = error | ❌ OPEN | silent `return callee_name` (`types.zig:747`); `i32` field defaults `expressions.zig:962,2036,2075,2227` |

### F2 — typed IR  (Landed 1–4d · Open 5 · Partial 6)
| Stage | Status | Evidence |
|---|---|---|
| 1–4d | ✅ | `types.zig` TypeStore; `sema/{lower,infer,ids,sema,shadow}.zig`; legacy resolver deleted; **`grep 'orelse "i32"'` = 0** in sema |
| 5 **`.unresolved` fatal** | ❌ OPEN | `infer.zig:240` only bumps a stat; no end-of-sema error, no codegen assert |
| 6 checker writes TypedIr | 🟡 PARTIAL | checks ON + enforcing in standalone `type_checker.zig` (arg-count :545, bool-cond :262, return :340, signedness/ptr :574) but takes `program` by value, runs separately, does not write TypedIr |

**Coverage today:** 13_serde 88% distinct typed (615 unresolved/5197); 14_map 86% (509/3727).
Top unresolved cluster = the `.ident` arm (`infer.zig:297-311`) has **no `findType`/module branch**,
so bare type/module names in member position (`bytes`×138, `json`×26, `JsonValue`×23, `string`×17)
fall to `.unresolved` — **inert** (enclosing call typed via `moduleCallReturn`) but counted. Genuinely
blocked: `closure`/`generic_call` (F4-5), `await` (needs `Handle<T>`), `optional_chaining`/`jsx` (unimpl).

### F3 — primitives  (Landed 1,2,3,4,4b,6 · Partial 5 · Open 5a,7)
| Stage | Status | Evidence |
|---|---|---|
| 1 PrimType table (int=32) | ✅ | `codegen/types.zig:189` cgPrim; `types.zig:299` intT bits=32 |
| 2 ptr type | ✅ | cgPrim ptr, non-refcounted |
| 3 `${f64}`/`${i64}` | ✅ | runtime converters wired |
| 4 alloca double / 4b ptr migration | ✅ | `slotTypeForLocal`; std 33 `:ptr`, 0 truncation |
| 5 honest i32 + narrowing/signedness | 🟡 PARTIAL | range/narrow/signed/ptr-trunc all enforced (4 negatives pass) BUT int **local slots still i64**, no overflow debug-trap |
| 5a decimal | ❌ OPEN | rejected `type_checker.zig:304` |
| 6 stdlib sweep | ✅ | std: 0 `:i32`, 299 `:int` |
| 7 unresolved≠i32 | ❌ OPEN | ~27 live `"i32"` guess-fallbacks in legacy codegen path |

### F4 — generics  (Landed 2,3,4,4b · Open 1,5,6)
| Stage | Status | Evidence |
|---|---|---|
| 1 type args survive parse | ❌ OPEN | `StructInit.type_name` still `[]const u8`; parser drops type_args |
| 2 `.type_param` subst by index | ✅ | `lower.zig`/`infer.zig` |
| 3 instantiation worklist | ✅ shadow | `sema/mono.zig` "SHADOW — emits nothing" |
| 4 per-instantiation destructors | ✅ | `arc.zig substituteFieldType`; `__destruct_List_string` |
| 4b **monomorphize method bodies** | ✅ mandatory | `llvm_codegen.zig:2271-2292`; real per-inst symbols + ARC; no flag |
| 5 **`.type_param` fatal at codegen** | ❌ OPEN | erased body still always emitted (`types.zig:102`); type_param resolved by string subst, not eliminated |
| 6 serde binders fold in | ❌ OPEN | still source-emit-and-reparse |

**Verdict: HYBRID.** Bodies genuinely monomorphized; erasure **not** removed — `.type_param` still
reaches codegen (resolved by render-boundary string substitution). This is the F5-2 blocker. ("Map
excluded from mono" is **stale** — `map.nova:37` holds `Storage<K>`/`Storage<V>`.)

### F5 — ARC ownership  (Landed 2a,3 · Partial 2,4,5 · Open 6)
| Stage | Status | Evidence |
|---|---|---|
| 2a static fn box writable+sentinel | ✅ | `buildBareFnBox expressions.zig:114-124` (rc 100000000, len 16, writable global) |
| 2 `isOwned(TypeId)` | 🟡 PARTIAL | vehicles `isOwnedExpr/TypeId/Local/DeclaredType` (`types.zig:481-604`); many sites migrated; full swap blocked (see spine) |
| 3 closure env ARC | ✅ | `__destruct_closure` + capture retain/release |
| 4 O4 enforced | 🟡 | rules coded at insertion points; no formal audit pass; ARC×`throw` undefined |
| 5 reified container destructors | 🟡 | `buildStorageDestructor`; `retainIfGenericStore` deleted; tuple leaks keep audit ≠ 0 |
| 6 remove interim | ❌ OPEN | — |

**Remaining `isRefCountedType` DECISION sites = 10** (audit corrected the doc's "9"): `statements.zig:475`,
`arc.zig:297/608/615/745/827`, `expressions.zig:1454/1468/2794/2439`. Plus 5 intended fallbacks in
`types.zig` (not decision sites). Catch-all `return true` (`arc.zig:72`) still stands for any
non-placeholder unknown string; only whole-string placeholders abort (`isUntypeablePlaceholder`).

## Definition-of-done metrics (beta-plan §8, target 0)
| grep (src/codegen/) | today | target |
|---|---|---|
| `isRefCountedType(` decision sites | 10 | 0 |
| `getStructBaseName` | 30 | 0 |
| bare `"i32"` | ~29 | 0 |
| `mem.eql … type_name` | 7 | 0 |
| `endsWith … _ … name` | 8 | 0 |

## F1-3b cutover progress (2026-07-18) — VALIDATED, ready to flip

Commits `aed2c5d` (record callee SymbolId per call: bare fns + methods + module calls; coverage 262
on 13_serde) and `31d7ab7` (shadow-diff). **Key enabler:** the sema `Symbol` already carries
`legacy_mangled` (the exact name codegen emits), so the reverse map is FREE — `symOf(call) →
symbolAt(sid).legacy_mangled` IS the emitted name, no reconstruction.

**Shadow-diff result (13_serde, main named-call path):** 149 calls, **AGREE 76, DISAGREE 0**, 73 no-
SymbolId. Zero disagreements = the SymbolId lookup can replace the scan for covered calls, byte-
identically. The 73 uncovered keep the scan.

**FLIPPED (commit `961e4e4`):** the main bare-name call path (expressions.zig:1613) now resolves via
`symOf → legacy_mangled` when it names a real emitted function, fallback to the scan otherwise.
Byte-identical (DISAGREE=0 + `hasFunction` fail-safe). N2 preserved via `findFunctionAmbiguous` (an
ambiguous bare name is NOT recorded, so the scan still errors naming both — `ambiguous_bare_call`).

**Measured scan-reach AFTER the flip (per-case, `run.sh` hides per-case stderr — run `nova test`
directly):** 13_serde still hits the suffix scan 18×. WHAT reaches it — the real blockers:
- **Compiler-GENERATED code sema never walked** (~7): serde binders/toJson (`Order__bind` →
  `<serde-generated>_Order__bind`), and the **test harness** (`test_map` → `collections_map_test_map`).
  `symOf` keys on sema-walked call exprs, so a generated call has no entry — CANNOT be covered by
  symOf. **Blocked on F4-6** (fold serde generation into sema) + harness call resolution.
- **Non-1613 call paths** (~6): generic mono'd internal calls (`nextPowerOfTwo`×3, `allocZero`×3)
  reach the scan through a DIFFERENT resolveCalleeName caller (generic_call 1936 / method-body path),
  not the flipped path — they were NOT in the flip's absent list, confirming a different arm.
- **Conclusion: full scan DELETION is blocked on generated-code resolution (F4-6 + harness), not just
  more flips.** Flipping the remaining user-code paths reduces reliance but cannot delete the scan
  while generated calls need it. So F1-3b "delete the 227 lines" is gated on F4-6.

**Remaining cutover steps (do NOT flip until all are green):**
1. Extend `symOf` recording to constructors (`Foo()`→init/new) and static methods → drive coverage.
2. Extend the shadow-diff to the method/module-call codegen arm (`compileMethodOrNamespacedCall`) —
   currently only the bare-ident path (expressions.zig:1612) is diffed.
3. When AGREE is high and DISAGREE stays 0 across ALL call paths AND the corpus, switch each call
   path to prefer `symOf` (fall back to scan when absent) — behavior-preserving.
4. When no call path reads the scan (coverage 100%), DELETE the 227 func_map scan lines + the
   endsWith sites + the isAlreadyNamespaced allowlist. That completes F1-3b.

## F4-5 feasibility — MEASURED 2026-07-18 (experiment, not doc-trust)

Ran the decisive test: stop emitting the erased body (`instantiationsOf`) when a generic has ≥1
concrete instantiation. **Result: 58/58 break** with "no such method or function" (codegen
resolution, even `00_smoke`). So the erased body is **heavily load-bearing** — 4b monomorphized the
bodies and fixed `self.method` self-calls (`qualifySelfType`), but **cross-instantiation and
generic-from-generic call sites still resolve to erased names** ("4b's second half", types.zig:91, was
never finished). **F4-5 = thread the instantiation context through EVERY generic call resolution so no
site resolves to an erased body, THEN drop it + assert `.type_param` unreachable.** A large, careful
multi-part build — the doc's claim HOLDS (unlike several stale ones). Reverted; corpus green.

**Net: both critical-path dominoes are now MEASURED load-bearing multi-part builds** — F1-3b deletion
(gated on F4-6 generated-code) and F4-5 (4b's second half). There is no quick knock-off; the plan's
10-12h estimate is real. The tractable parts (F5-2 err-arm, F1-3b main-path flip) are done + committed.

### F4-5 "4b's second half" — PARTIALLY DONE (commit `72b0f82`), residual pinpointed

The erased-body reachability was dissected by instrumenting the method-call resolver + re-running the
removal experiment. Two layers:
1. **STRUCT-level type-param receivers** (`List<T>` in a List body, `List<K>` in a Map body) resolved
   to the missing `List_T_push`/`List_K_push` → erased fallback. **FIXED** (`72b0f82`): apply
   `substTypeParams` (maps the nested param against `current_instantiation`) before `mono_name`.
   Measured: with the erased body removed, breakage dropped **58 → 40** (18 cases freed).
2. **METHOD-level type params** (`result: List<U>` from `map<U>`/`reduce<U>`) — the residual **40**. All
   remaining failures are `result.push` on a `List<U>` where U is a METHOD param, and
   `current_instantiation` is the STRUCT inst (`List<i32>`) which does not know U. **This needs
   method-level monomorphization** (emit `List_i32_map_string` per (struct-inst, method-args) — a cross
   product; the mono.zig worklist would need method-arg instantiations). That is the real remaining
   F4-5 build, and it is what still forces the erased body alive. LARGE.

So F4-5 = method-level monomorphization; F1-3b deletion = F4-6 (serde/harness into sema). Both remain.

## Session log — 2026-07-18 (later increments)

- **i32→int cleanup** (user directive: int is the canonical F3 primitive, i32 not used):
  type-annotation `i32`→`int` in all `.nova` source (5 expect_fail cases, the repro); `i32_hash`→
  `int_hash` (dead fn). Left: `bytes.write_i32`/`read_i32` (API names), `__i32_to_string`/`__destruct_*_i32`
  (symbols), truncation-history comments. The compiler's own `i32` render feeds MANGLING
  (`List_i32_push`), so migrating it is the F3-6 vocabulary stage, not a swap.
- **F1-3b**: flipped the **async-await call path** to SymbolId (`awaitedCallHandle`) — the last safely-
  flippable bare-name call path. Scan now serves only generated code (F4-6) + mono-refined paths.
- **F3-7**: `__env` closure-env param typed `ptr` (honest) instead of the bare `"i32"` machine-word
  guess — behavior-preserving (word-sized, unowned), one fewer codegen `"i32"`. The remaining bare
  `"i32"` are F2/F4-gated genuine guesses (lambda return needs sema; container elements need F4).

## Session log — 2026-07-18 (this audit + first increments)

- **Landed (commit `f35f0c2`):** F5-2 — catch err-arm ownership migrated to typed `isOwnedErrUnionErr`
  (the err-side twin of the ok-arm). `isRefCountedType` decision sites **10 → 9**. All 5 gates green.
  This was the LAST expression-backed clean site; the remaining 9 only have a rendered *name string*
  in scope (`buildErrUnion` parses `union_name`; the destructor generators memoize on the name), so
  they need TypeId-threading refactors, not 1:1 swaps.
- **Finding — F2 receiver-typing ⇄ F1-3b** (see the cross-dependency section above). Reverted; not a
  standalone win.
- **Finding — stale comment:** `codegen/types.zig:117-137` still documents a Map monomorphization
  *exclusion*, but the exclusion CODE is gone (lines 140-142 just base-match). Map IS monomorphized
  now ([[nova-storage-get-not-owned]]). Comment is orphaned — trim when touching that function.
- **F4-5 crux (measured):** the "erased body, always" (`types.zig:99-104`) is NOT dead code — it is a
  **live link fallback** for generic-from-generic calls (a generic body calling another generic has no
  concrete instantiation). F4-5 (drop it + make `.type_param` fatal) is blocked until every
  generic-from-generic call site resolves to a concrete instantiation — a real multi-part build.
- **F1-3b scope (measured):** the IR records only `expr_types` (ExprId→TypeId); there is **no
  `expr_syms`**. F1-3b needs: (1) sema records callee `SymbolId`, (2) codegen builds `SymbolId→mangled`
  map, (3) thread `ExprId` through call compilation, (4) delete the 227 func_map scan lines. Multi-part.

## Prioritized runway (the honest multi-session order)

1. **F1-3b** — record `SymbolId` in IR → `SymbolId→mangled` map → thread ExprId → delete scans.
   Unblocks F2 receiver-typing (the dominant unresolved clusters) and completes an F1 stage.
2. **F4-5** — cover generic-from-generic call sites with concrete instantiations → drop the erased
   body → make `.type_param` fatal at codegen. Unblocks F5-2 and F2-5 generic clusters.
3. **F2-5** — with (1)+(2) shrinking the unresolved/type_param sets, make `.unresolved` fatal at end
   of sema + assert in codegen; delete the ~27 `orelse "i32"` guesses (also F3-7).
4. **F5-2 remainder** — thread TypeIds into the destructor generators + `buildErrUnion`; migrate the
   9 remaining decision sites; delete the `isRefCountedType` catch-all.
5. **F1-4/6/7, F3-5/5a, F5-4/5/6** — module scoping, mangling, honest i32 local slots, decimal, O4 audit.

## Honest completion (by landed stages)
F1 ≈ 56% · F2 ≈ 80% (1–4d done, 5 open, 6 partial) · F3 ≈ 72% · F4 ≈ 57% (bodies mono, erasure not
removed) · F5 ≈ 45%. **The safety-critical halves are in** (ambiguity/block-scope errors, typed IR
substrate, honest widths, monomorphized bodies, writable fn boxes, enum ownership). **The cleanup +
enforcement halves are the remaining ~10-12h**, and they are gated on the spine above.
