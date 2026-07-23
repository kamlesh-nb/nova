# Foundation Gap Register (F1–F5 → 100%)

Living record for the autonomous foundation-hardening pass. Grading ruler: **can spec-legal code
crash / leak / UAF / silently produce a wrong value?** — verified with ASAN + `NOVA_SEMA_SHADOW` +
`NOVA_ARC_AUDIT`, not just FUNC gates. Every fix lands with a genuine test in that discipline, or is
reverted. No faked green.

Status legend: ☐ open · ◑ in progress · ☑ fixed+gated · ✗ attempted, reverted (why)

## Class A — erasure×ARC ownership (F4/F5) — the biggest biter
- ☑ `Map<K,Trait>.set` stored raw struct (no widening, V erased at call site) → UAF. Fixed 57fbc48; gate 70.
- ☑ **A1** `x ?? default` on owned struct/trait double-freed via the coalesce phi aliasing the owned
      operand. FIXED: per-edge ownership in the `??` operator (retain a borrowed operand, move a fresh
      one) is now the SINGLE mechanism, and the redundant `return x ?? default` retain-on-return was
      REMOVED (it doubled the retain → the +286 serde-binder leak via `json.get`'s `return r ?? ..`).
      Root cause was TWO colliding retain mechanisms. All repros ASAN-clean; 13_serde ARC clean; 49
      diverse gates ASAN-clean; FUNC 90/90 SHADOW 160/160 ARC 160/160. Gate 70 coalesce cases enabled.
- ☑ **A1 (dominance completion, 2026-07-21, commit cab09ca)** — the per-edge retain of a BORROWED-owner
      DEFAULT (`x ?? d`, d an ident/field/index) was emitted at the MERGE, where rhs_val (defined only in
      nc_rhs) does NOT dominate the left-survived edge → LLVM "instruction does not dominate all uses" (a
      COMPILE failure) AND a wrong retain of the default when the left survived. The corpus never hit it —
      every `??` default in it is a FRESH producer (`?? Item()` → consumed, no retain); a borrowed owned
      LOCAL default is what exposed it. FIX: emit the borrowed-right retain in nc_rhs (defined there, runs
      only when the default is selected — dominance- AND ownership-correct); the left retain stays at the
      merge (left_val dominates it; retain(0) is a no-op on the null edge). Net count unchanged → no serde
      regression. Gate 78: `?? d` present/absent, inline + via-local, and left-borrowed+fresh-default — all
      ASAN-clean. FUNC 100/100.
- ☑ **A1b** `?? StructDefault` (default selected, key absent) placed a raw struct in a trait slot → SEGV.
      Fixed 1d05837: widen the `??` default operand to the trait when the result type is a trait.
- ◑ **A2** ownership `isRefCountedType` string fallback — SAFETY CLOSED, elimination is tracked debt (not a
      biter). MEASURED 2026-07-21: `isRefCountedType` is called ~262k times/corpus, DOMINATED by primitives
      (i32 117k, void 34k, string 34k, bool 28k) — deterministic-correct classifications, NOT guesses. The
      dangerous UNKNOWN-name guess is already a TRIPWIRE ABORT (`isUntypeablePlaceholder`), and the F5-2
      shadow gate proved `store.isOwned == isRefCountedType(render)` DISAGREE=0 on every concrete decision.
      So A2 is memory-SAFE. FULL elimination requires threading a TypeId to ~40 decision sites AND retiring
      the string destructor BUILDERS — but those builders remain reachable for (a) any string-first symbol
      race and (b) the ERASED generic bodies (`__destruct_List_T`/`Storage_K` — type-erased instantiations
      whose element renders as a `.type_param`), which are inherent to type-erased generics and cannot be
      removed without COMPLETING full monomorphization. PROGRESS (F2-6 stage 5): the release SITES are now
      TypeId-keyed (Phase A/B/C1/D#6, coverage extension); flip=8106, no-id 66→23. But coverage extension
      did NOT dent the 262k — confirming it is builder-internal + erased-body decisions, not local drains.
      CONCLUSION: A2's remaining work is a large architectural migration (full mono + 40-site TypeId thread)
      with ZERO safety payoff (proven-equivalent, guess-tripwired) — tracked debt, NOT a fix to force. See
      `docs/design/F2-6-stage5-release-site-migration.md`.
- ◐ **A3** trait-object WIDENING audit (widen struct→trait object at EVERY position). ASAN audit:
      fn-arg, struct-field, container-set, `??`-default, return, nested containers, downcast, and
      annotated-let (`let g: G = A{}`) — all CLEAN. TWO POSITIONS STILL UNSAFE (found by audit, NOT
      safely fixed this round):
      (a) ☑ trait-var REASSIGNMENT `g: G = A{}; g = B{}` then use — FIXED. IR trace: a naive widening
          double-freed because the NEW fat-pointer box was left as a drainable temp (freed by the
          statement drain while the variable still pointed at it). Fix MIRRORS the let-widening
          (statements.zig): after constructTraitObject on the assign RHS, CONSUME the new fat pointer
          (the variable owns it, not the drain) + RELEASE the struct's orphaned construction ref (the
          trait object retained it). ASAN-clean incl. chained + loop reassignment; string reassign no
          regression; broad ASAN sweep 0 fails; FUNC 91/91 SHADOW 162/162 ARC 162/162. Gate 70.
      (b) ☑ trait in a TUPLE element in a context-typed position (`fn f(): (int,G) { return (1,A{}); }`
          and `let p: (int,G) = (1,A{})`) — FIXED. THREE bugs in one, each surfaced by ASAN/ARC:
          1. sema typed `(1,A{})` as `(int,A)` by its elements → raw struct in the trait slot → SEGV.
             FIX: type the tuple LITERAL by its EXPECTED type — `inferExprExpecting` per element on both
             the return path (already plumbed via `current_ret`) AND the annotated-`let` path (was
             plain `inferExpr`, now passes the declared type). A struct element at a `.trait_` slot is
             typed AS the trait on the tuple's TypeId.
          2. codegen put a raw struct in the slot even once typed → widen it (constructTraitObject) with
             the let-widening ARC discipline: CONSUME the struct's own construction temp (the miss that
             caused a UAF — the statement drain freed it a 2nd time inside the producer) AND the fat-
             pointer temp, then release the orphaned struct ref.
          3. the `(int,G)` tuple destructor released NOTHING (16-byte leak) because `isRefCountedType`
             read a single-letter trait name `G` as an unbound type PARAMETER (traits were absent from
             the struct/enum/union decl-table disambiguation) → non-owned. FIX: add traits to that check.
          ASAN + ARC clean: return position, annotated local, destructure-from-named-local, tuple of two
          traits, single- and multi-letter traits. Gate 72. FUNC/SHADOW/ARC 92/92.
      (c) ☑ struct LITERAL with a trait-typed field initialized directly by a struct (`Holder{ g: A{} }`,
          `g: G`) — FIXED. The A3 audit's "struct-field clean" only covered a field init from an
          ALREADY-trait value (`Holder{ g: x }`, x: G, needs no widening); a struct-literal field init
          was still raw → garbage vtable → SEGV. Found by the post-A3(b) adversarial ASAN sweep. FIX:
          codegen widens the field value in the struct_init arm (constructTraitObject + the consume-
          struct-temp discipline), and for a field whose type is a TUPLE containing a trait
          (`p: (int, G)`), sema infers the struct-init field value with its DECLARED type as the expected
          type so the tuple element lands as the trait (the tuple arm then widens it). Gate 73; ASAN+ARC
          clean incl. field-from-trait-value (no double-widen) and tuple-in-field. FUNC/SHADOW/ARC 94/94.
      (d) ☑ struct assigned to a trait-typed FIELD (`self.g = A{}` — constructor init() bodies +
          setters, the stdlib's actual pattern). The `.field_access` assignment arm now widens (r_val
          already consumed at the assign-block top → consume the fat pointer + release the orphan struct
          ref). Gate 74. FUNC/SHADOW/ARC 95/95.
      (e) ☑ if-EXPRESSION of struct branches in a trait position (`let o: G = if (c) A{} else B{}`,
          `return if (c) A{} else B{}`). Sema types the if-expr as the trait when expected is a trait
          and both branches are structs (branches keep their struct types for codegen); codegen widens
          each branch PER-EDGE (shared `widenBranchToTrait` helper) and the phi owns the selected fat
          pointer. Gate 75. FUNC/SHADOW/ARC 96/96. NOTE: the UNANNOTATED heterogeneous form
          (`let o = if (c) A{} else B{}; return o`) still needs least-upper-bound inference (o has no
          context at the let; two different structs) — a larger inference feature, NOT a widening bug;
          annotate `let o: G` or return the if-expr directly. Recorded as C2 below.
      A3 COMPLETE — every widening position (fn-arg/field/container/`??`/return/annotated-let/
      reassignment/tuple-element/struct-literal-field/tuple-in-field/field-assign/if-expr-branch) is
      ASAN+ARC clean. The systemic root (a literal typed by its elements, not by context) is addressed
      incrementally by plumbing the expected type at each construction site via `inferExprExpecting`
      (let, return, tuple-element, struct-init field, if-expr branches) + a shared `widenBranchToTrait`
      codegen helper; the full systemic fix is F2-6 contextual typing.

## Class B — numeric honesty (F3)
- ☑ **B1** — NON-GAP (spec-conformant, verified 2026-07-21). The authoritative spec
      (`docs/language-specification.md:63`) states `int` is 32-bit signed and **arithmetic WRAPS at 2³¹**
      (→ 19_int_overflow) — wrapping is the SPECIFIED behavior, NOT a trap. Verified: `int` is honest
      32-bit and wraps (`2147483647+1 == -2147483648`); gate 19_int_overflow 9/9. There is no overflow-trap
      requirement to implement; the older specs.md "i64 native" line is a stale status-table entry.
- ☑ **B2** — COMPLETE (verified 2026-07-21). `decimal` is IEEE-754 decimal128 (BID), `m`-suffixed literals
      (`10.5m`), toString/interpolation, arithmetic+compare, BSON codec — gates 50/51/52 all pass. No
      implicit int↔decimal / float↔decimal conversion is the HONEST design choice (explicit only), so a
      `let a: decimal = 3.14` (binary float) is correctly a type error. See [[nova-decimal128]].

## Class C — optionals / narrowing (F2, spec §3.4)
- ◑ **C1** the spec (§3.4) DESIGNS optional member access as GUARDED (safe), not statically-enforced —
      so "make it a compile error" would CONTRADICT the spec (re-graded 2026-07-21). The real gap was
      guard INCOMPLETENESS: struct `.field` was guarded, but two BUILTIN deref paths escaped it and
      crashed RAW on an absent optional — `.length` (read `str_ptr - 4` from 0) and index `s[i]` (read
      from address 0). ☑ FIXED: both now call `guardOptionalDeref` → located "narrow it first (§3.4)"
      trap. Gate 76 (happy path); manual trap verified. AUDIT COMPLETE (2026-07-21): the inline builtin
      deref paths are `.length`/`.len` (expressions.zig:2652), struct `.field` (2691), index `s[i]` (2800),
      plus the two llvm_codegen receivers (1382/1832); `.value` on a non-struct is a pass-through and on a
      struct routes through the guarded field path. Adversarially verified all three (repro/c1_deref_*) TRAP
      with the located "narrow it first (specs §3.4)" message on an absent map.get optional — none SEGV.
      String METHODS on an unnarrowed optional are a COMPILE error (safe). C1 is memory-safe and complete;
      static enforcement is explicitly NOT pursued (spec §3.4 chose the guarded model). FUNC/SHADOW/ARC 98/98.
- ☑ **C2** least-upper-bound inference for an unannotated heterogeneous if-expr — FIXED (2026-07-21,
      commit e9f8d13). `let o = if (c) A{} else B{}; return o` (A,B both `impl G`) left `o` unresolved (two
      different structs, no context), so a raw struct reached the trait return slot → SEGV on valid code.
      FIX: `lubTraitOfStructs(tt, et)` computes the two struct types' single common trait (via
      `StructDecl.impls`, equality by resolved trait TypeId); the if_expr arm types the expr as that trait
      when both branches are structs and no expected type resolved it, and the existing per-edge
      `widenBranchToTrait` (A3(e)) widens each branch. Returns null (stays unresolved → requires annotation)
      when the branches share NO trait or MORE THAN ONE — never guesses. Gate 79; FUNC/ASAN/ARC 101/101.
- ☑ **C3** struct-literal with MISSING required fields — FIXED. `Holder{}` where `Holder` has a
      non-defaulted field `g: G` left `g` null → SEGV on deref (found unvalidated during the A3
      adversarial sweep: compiled + crashed instead of a located error). Fields have NO defaults (the
      `ast.Field` has no default slot), so the rule is exact: a struct literal must initialize EVERY
      declared field. FIX: type_checker.zig `.struct_init` arm reports a located "missing field 'x'"
      error (suggesting the constructor `S(…)` form when S has an init()). Field-LESS literals (`A{}`)
      stay valid; enum-variant payloads and generic instantiations (name carries type args → null
      lookup) are skipped — no false positives. Gate: expect_fail/struct_literal_missing_field.
      FUNC/SHADOW/ARC 97/97; drivers + stdlib compile clean.

## Class D — generics completeness (F4)
- ☑ **D1** type args survive parse (StructInit.type_args) — VERIFIED WORKING (2026-07-21). A struct-init
      literal with explicit type args (`Box<int>{ v: 7 }`, `Box<string>{ v: "hi" }`) parses, type-checks,
      and runs ASAN-clean. Gate 80.
- ☑ **D2** value-witness (destroy slot) for irreducibly-erased trait objects — VERIFIED WORKING
      (2026-07-21). A trait object in a fully type-ERASED container (`List<Shape>` holding `Sq`/`Ci` that
      own strings) is destroyed via its vtable SLOT-0 destructor (`__destruct_trait` → the concrete
      struct's dtor) at container drop — no leak, no UAF under ASAN. This IS the value-witness the entry
      asked for. Gate 81. (Erased-body ELIMINATION — dropping dead monomorphized bodies — is a code-size
      optimization, not a correctness/safety gap.)

## Class E — name resolution robustness (F1)
- ☑ **E3** DUPLICATE struct-name across modules → wrong-struct resolution — RESOLVED for the stdlib
      (2026-07-21) by RENAMING the 7 dups + re-adding the now-safe collision diagnostic. The 7 (each →
      module-unique): driver internals `Dsn`/`Frame`/`PCursor`/`Reader` → `Pg*`/`My*`/`Bt*` (per driver;
      private, file-local); web `Mediator`→`AppMediator` + `Route`→`AppRoute` in app.nova (app is the
      self-contained flagship; keeps mediator.nova's `Mediator` and router.nova's `Route`); `Router`→
      `CtrlRouter` in the vestigial router.nova/controller.nova (keeps routing.nova's flagship `Router`).
      Stdlib is now duplicate-free: all 3 drivers + app + mediator + routing compile TOGETHER (was 7
      collisions → 11/11). The collision diagnostic (type_checker struct registration) is RE-ADDED —
      previously reverted for over-firing on the driver internals, now safe since the stdlib is clean, so
      it fires only on a genuine USER collision (located error instead of the span-less "no such method").
      KEYSTONE FULLY CLOSED (2026-07-21): true MODULE-SCOPED struct/type resolution IMPLEMENTED — two
      modules may define the same struct name and each resolves to its OWN; the uniqueness diagnostic is
      retired. Sema: `findTypeInModule` (bare name → local def first) threaded through the lowerer + infer
      + method `self_ty`. Symbol table: `colliding_types` + precomputed per-symbol `scoped_name`. Codegen:
      struct table keyed by scoped name, method mangling + construction sites route colliding structs
      through it (constructor names built via `methodSymbol`→`mangleTypeName`, the hyphen-escape gotcha).
      No-op when nothing collides (gated on `colliding_types`), so the suite stayed green throughout.
      Verified: gate 77 + all 3 SQL drivers + web.app + web.mediator + web.routing together + a user
      struct colliding with a stdlib name — all ASAN+ARC clean. FUNC/SHADOW/ARC 99/99. Plan+writeup in
      `docs/design/F1-module-scoped-types.md`. (The stdlib renames stay — clearer names, and now optional.)
      --- ORIGINAL FINDING (kept for context) ---
      DUPLICATE struct-name across modules → wrong-struct resolution (found 2026-07-21). The codegen
      struct table (and sema type lookup) is BARE-NAME keyed (last-wins), not module-scoped. `web/app.nova`
      and `web/mediator.nova` BOTH define `pub struct Mediator` (different shapes); importing both makes
      `self: Mediator` in mediator.nova's methods resolve to app's Mediator (no `behaviors` field) →
      `self.behaviors.push(...)` → objType null → "no such method or function" (span-less codegen fail).
      SEVEN stdlib names are duplicated across modules and latently collide: `Duration`, `Mediator`,
      `Process`, `Route`, `Router`, `StopWatch`, `Watcher`. Proper fix = MODULE-SCOPED struct/type
      resolution (key struct table by (module, name); type `self` from the method's OWN module) — a large
      F1 keystone (continuation of task F1-4), blast radius across every struct/method/`self` lookup, with
      a design choice (true scoping vs rename the stdlib dups). NOT memory-unsafe; needs its own scoped
      plan. Interim: don't import two modules that share a struct name (e.g. web.app already IS the
      mediator framework — don't also import web.mediator).
      DIAGNOSTIC BAND-AID TRIED + REVERTED (2026-07-21): a hard error on any cross-module same-name struct
      OVER-FIRES on legitimate code — the three SQL drivers each define internal `Reader`/`PCursor`/`Dsn`/
      `Frame`, and importing several drivers is legal (each uses only its OWN). So the fix MUST be real
      module scoping (each module's methods resolve to its own structs), not a collision error. Confirmed
      E3 is a genuine keystone, not band-aid-able. The drivers-imported-together case is also latently
      mis-resolved today (bare-name last-wins) — another reason scoping is the only correct fix.
- ☑ **E1** multi-segment-import **function** visibility hole — FIXED. ROOT CAUSE: the import spelling
      separates segments with `/` (`serde/json`, `lib/helper`) but module `path`s use `.`
      (`std.serde.json`), so `findModuleByImportName` NEVER matched a multi-segment import → the import
      EDGE was silently dropped → every multi-segment call fell back to the global `findFunctionBySegment`,
      which skipped the visibility check that types/consts already enforced. So a non-`pub` function was
      freely callable across modules. The import-edge machinery was effectively DEAD for every
      multi-segment import (stdlib included). FIX: (1) `findModuleByImportName`/segment extraction is now
      separator-AGNOSTIC (`sepAgnosticEql`/`lastSegment`), so edges are recorded for multi-segment
      imports — the primary visibility path now fires; (2) the segment-fallback path ALSO enforces
      visibility (`recordFnVisibility`, shared with the edge path) as defense-in-depth. This EXPOSED a
      latent bug the hole had hidden: `serde/bson` had ZERO `pub fn` (all 28 private) yet is used as a
      public API — marked its 25 public-API fns `pub` (kept 3 internal byte-plumbing helpers private),
      matching json's convention (21 pub / 2 private). Gate: expect_fail/private_fn_cross_module.nova
      (bson.getDocSize, a private helper, rejected cross-module). FUNC/SHADOW/ARC 93/93; DB drivers +
      multi-segment stdlib imports all still typecheck.
- ☑ **E2** — RESOLVED (verified 2026-07-21). Both facets now hold: (1) an unimported/unresolved call is a
      located hard error ("undefined identifier 'leaf' … (F2-5)"), not silent; (2) the redundant-import
      collision sub-item (`import web.app; import web.mediator` — app transitively uses mediator, and they
      share the `Mediator` name) now compiles+runs clean — the MODULE-SCOPING KEYSTONE (E3) fixed it (each
      module resolves its own `Mediator`; bare-name last-wins is gone). Repro: repro/e2_web_app_mediator
      (8 transitive tests pass), repro/e2_redundant_import, repro/e2_unimported_call (rejected).

## Class F — tuples (F2 type-checker)
- ☐ **F1t** type-checker blind to tuples: element types unchecked (`int + string` compiles), arity
      unchecked both directions.

## Class G — enums
- ☐ **G1** payload binding fails when switching on a LOCAL (`let e = E.A(7); switch(e)`), works on
      param/call-result. Local type inference for enum-constructor initializers.

## Verification results (empirical, 2026-07-21) — MANY suspected gaps were already fixed
Ruler: repro under FUNC/ASAN/SHADOW/ARC. Verifying BEFORE fixing prevented "fixing" non-gaps.

- ☑ **G1** (enum switch-on-local payload bind): ALREADY WORKS, incl. string payload, ARC-clean. Stale backlog.
- ☑ **C1 runtime safety**: unnarrowed access to an absent STRUCT optional does NOT SEGV — it TRAPS with a
      located "narrow it first (specs §3.4)" message. So no memory-unsafety. What remains is STATIC
      enforcement (compile error), a larger type-system feature — lower severity (fails safe at runtime).
- ☑ **B1 int width**: `int` IS honest 32-bit and WRAPS on overflow (2147483647+1 == -2147483648 verified).
      Not silently 64-bit. Remaining: overflow TRAP vs wrap is a spec choice, not a safety bug.
- ☑ **tuple-return-via-local**: fixed (was known-bad in the probe seed; F5 tuple work closed it).
- ✗ **A1** (`map.get(k) ?? default` double-free on owned struct/trait): CONFIRMED real (memory-unsafe).
      TWO fix attempts (retain borrowed `??` operand) BOTH regressed the serde binders +286 leak — the
      retain adds an unbalanced +1 to EVERY borrowed-owned `??` across the stdlib, not just the
      double-free case. The distinction lives in the drainTemporaries/consumeTemporary/phi-registration
      lifecycle I have NOT fully traced. DO NOT re-attempt blindly. Fix needs a full trace of the temp
      lifecycle for `??`-on-borrowed-owned vs the balanced general field-`??`. Routing is unaffected
      (mediator uses null-narrowing). REVERTED both attempts; 13_serde ARC clean.
- ☑ **F1t** REDIAGNOSED + FIXED: not "int+string should be rejected" — Nova `+` with a string operand
      IS concat (with coercion), and `"n="+5` → "n=5" works. The real bug: a DESTRUCTURED tuple
      element's TypeId is correct (`e.length` worked) but its RENDERED string was "i32" (tuple type
      doesn't round-trip), so `is_string_concat`/`is_string_comparison` (which read the STRING) missed
      it → `v + e` did a NUMERIC add on the string pointer → SILENT GARBAGE ON VALID CODE. Fixed by
      deciding string-concat/comparison from the TypeId (`isStringExpr`), not the name — the "stop
      deciding from strings" thesis applied. Gate 71; FUNC 91/91 SHADOW 162/162 ARC 162/162.

Honest recalibration: the foundation is stronger than the pessimistic re-grade implied. The ONE confirmed
valid-code memory-safety gap is A1; most others were already handled or are invalid-code diagnostics.

## Broad ASAN sweep result (2026-07-21) — the biting class is NARROW
Ran ~19 adversarial patterns; **direct** per-repro ASAN is the source of truth (the probe harness's
auto-classifier is UNRELIABLE — it reported `?? default` cases "clean" because a passing earlier @test
printed `Results:` before the crash; always confirm with a single-test ASAN run).

ASAN-CLEAN (verified, no UAF/leak): container narrow-read (Map/List of trait & struct), closure capture
of owned, closure-in-generic-method, generic-method reify, nested-generic Map value, string reassign-
alias, trait widening at fn-arg and struct-field, `Map<K,string>` coalesce. That is broad, real safety.

CONFIRMED memory-unsafe (direct ASAN):
- **A1** `x ?? default` where `x` is an OWNED struct/trait value (`let h = m.get(); h ?? d`, or inline
  `(m.get(k) ?? d)`, key present OR absent) → heap-use-after-free / double-free (nova_release
  alloc.cpp:369). `?? StructDefault` in a trait-typed coalesce (key absent) → SEGV (raw struct in a
  trait slot). Narrowing (`if (x==undefined)`) is SOUND and clean — this is ONLY the `??` unwrap.
  STATUS: 3 fix attempts reverted. Unresolved CONTRADICTION: the per-edge retain fires only on
  ident/field/index lefts, yet 13_serde (all `.get()`-call lefts) leaked +286 — impossible under my
  model → my model of drainTemporaries/consumeTemporary/phi-registration is WRONG somewhere.
  NEXT STEP (do this, not more guessing): apply the per-edge fix, dump 13_serde `__nova_test.ll`, grep
  the `nc_` blocks for the ADDED `nova_retain`, and find which `??` site it fired on — that reveals the
  wrong assumption. Only then design the fix. Routing is UNAFFECTED (mediator uses narrowing).

Not-memory-unsafe (lower priority): C1 (unnarrowed optional → safe located TRAP, not SEGV; static
enforcement is a larger type-system feature), F1t (tuple `int+string` unchecked — invalid code only;
touches the "load-bearing permissive arithmetic" path, blast-radius risk), B1 (int is honest 32-bit
wrap; trap-vs-wrap is a spec choice).

---
## MEMORY-SAFETY CLOSURE (2026-07-21) — every confirmed valid-code biter is fixed
The two last confirmed valid-code gaps that could crash/leak/UAF/silently-wrong were closed this pass:
**A1** (`x ?? ownedDefault` non-dominating retain → IR-invalid / UAF, commit cab09ca, gate 78) and **C2**
(unannotated heterogeneous if-expr → SEGV, commit e9f8d13, gate 79). Everything else on the register is now
either VERIFIED-WORKING (D1/D2 gates 80/81; E2 via module scoping; G1/F1t/tuple-local), SPEC-CONFORMANT
(B1 int-wraps per spec §; B2 decimal128 complete), or ARCHITECTURAL-COMPLETENESS that is NOT a memory-safety
biter (A2 string-fallback seam — the fallback is CORRECT where still used; its elimination is the F2-6
stage-5 migration, Phase A/B/C1 landed, D/E remain; F4 erased-body ELIMINATION is a code-size optimization;
F1-6 mangling cosmetics). By the register's ruler — "can spec-legal code crash/leak/UAF/silently produce a
wrong value?" — the answer across F1-F5 is now NO, ASAN-verified. Suite FUNC/SHADOW/ARC 103/103; full-corpus
ASAN 81/81 clean.

## Log (newest first)
- 2026-07-21: C1 re-graded via the SPEC (§3.4 designs optionals as guarded, not static-narrowed) — so
  the real gap was guard INCOMPLETENESS. Fixed two unguarded builtin derefs (`.length` read `0-4`; index
  `s[i]` read from 0) that crashed raw on an absent optional; both now trap with the located message.
  Also recorded E3 (duplicate struct-name across modules → wrong-struct resolution; 7 stdlib dup names;
  needs module-scoped resolution, an F1 keystone). Gate 76; 98/98.
- 2026-07-21: C3 struct-literal missing-field validation FIXED (was: compiled + SEGV on a null field;
  now a located typecheck error). Fields have no defaults → a literal must initialize all of them.
  Gate expect_fail/struct_literal_missing_field; 97/97. Noted an E2 sub-item: importing a module both
  directly and transitively (web.app + web.mediator) collides at codegen ("no such method or function").
- 2026-07-21: A3(d) field-assign + A3(e) if-expr-branch trait widening FIXED (adversarial sweep found
  both). Field-assignment (`self.g = A{}`) is the stdlib's init()-body pattern; if-expr needs per-branch
  widening via a shared `widenBranchToTrait` helper + sema typing the if-expr by context. Gates 74, 75;
  96/96. Recorded C2 (unannotated heterogeneous if-expr LUB inference) + C3 (missing-field validation)
  as the two NON-widening gaps the sweep surfaced.
- 2026-07-21: A3(c) struct-literal trait-field widening FIXED (found by post-A3b adversarial ASAN sweep;
  scalar-trait field + tuple-with-trait field). Codegen widens the struct_init field; sema types the
  field literal by its declared type. A3 now COMPLETE across all construction sites. Gate 73; 94/94.
- 2026-07-21: E1 multi-segment-import function-visibility hole FIXED. Root cause: '/' vs '.' separator
  mismatch made findModuleByImportName never match multi-segment imports → import edges silently dropped
  → calls fell to the segment fallback which skipped visibility enforcement. Fixed separator-agnostic
  matching + guarded the fallback. Exposed serde/bson's entirely-un-`pub`'d public API (marked 25 fns
  pub). Gate: expect_fail/private_fn_cross_module. FUNC/SHADOW/ARC 93/93.
- 2026-07-21: A3(b) trait-in-context-typed-tuple-element FIXED (3 bugs: contextual tuple typing in sema
  for return + annotated-let, codegen widening with the consume-struct-temp discipline, and a single-
  letter-trait leak in isRefCountedType). A3 (trait widening at every position) now COMPLETE. ASAN+ARC
  clean; gate 72; FUNC/SHADOW/ARC 92/92.
- 2026-07-21: broad ASAN sweep. Foundation memory-safety is BROADLY clean; the one biting gap is A1
  (`??` unwrap of an owned struct/trait). 3 blind fix attempts regressed serde binders; STOPPED per the
  "understand before fixing" rule and recorded the exact next diagnostic step. Suite 90/90 FUNC.
- 2026-07-21: verified G1/C1/B1/tuple-local already OK; A1 confirmed + attempts reverted; F1t confirmed.
