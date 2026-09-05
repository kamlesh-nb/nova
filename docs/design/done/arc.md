# arc.md — Kyte ownership & reference-counting, as an explicit sema pass

**Status:** DESIGN (2026-07-19). Supersedes the string-heuristic ARC in codegen. This is the rewrite
that ends the fix-then-revert cycle (see `resume.md` "THE REAL PROBLEM") and takes the correctness
foundation (F4/F5) to a true 100%.

**One-line thesis:** stop deciding ownership in codegen from rendered type-name strings and local
temp-drain heuristics. Instead, a **sema pass computes ownership globally and inserts explicit
`dup`/`drop`/`move` operations into a typed IR**; codegen mechanically lowers them. Ownership becomes
*analyzable and provable*, not guessed. The model is **Perceus** (precise reference counting, from
Koka/Lean4) adapted to Kyte's existing `kyte_retain`/`kyte_release` runtime.

---

## PROGRESS — acquisition layer rewrite COMPLETE at the codegen level (2026-07-19b)

Chosen path: Option A (resume.md) — rewrote the acquisition ("constructor") DECISION in
`src/codegen/arc.zig` incrementally, per-construct, gated; NOT the full sema pass. The destruction
half is kept unchanged (§0b). All six steps LANDED, each green on build + FUNC + ARC + ASAN + SHADOW +
unit:

- **Step 1 (`03c516f`)** — homed the acquisition decision in `arc.acquisitionDisposition(expr) →
  {owned|borrowed}`. Was inferred inline in `compileExpression`; now one nameable function. Identical.
- **Step 2 (`0e94ede`)** — made it the PRINCIPLED model (`principledDisposition`): `.owned` is the
  DEFAULT for a managed producer; only borrows (ident/field/index), assignment, bare literals, and
  own-arm-acquired kinds (try/cast/await/go/optional-chaining) are excluded. Corpus-measured the
  whitelist-vs-principled divergence (report-only under `KYTE_SEMA_SHADOW=1` → `dumpAcqShadow`): only
  `.tuple` (cut over — fixed a real orphaned-tuple box leak, `conformance/cases/46`) and `.if_expr`.
  `would_drop=0` everywhere (principled ⊇ whitelist).
- **Step 3 (`769532c`)** — unified the store-into-aggregate move/dup rule (retain-borrowed /
  consume-fresh) from 4 open-coded sites (enum-payload / union / struct field / tuple element) into
  `arc.takeOwnedElement`, borrow test via the shared `namesExistingOwner`.
- **Step 4 (`27c3908`)** — cut `.if_expr` over via PER-EDGE DROPS (§9): the phi that selects a branch
  value takes ownership of it, so each branch applies `takeOwnedElement` to its own value IN its own
  block (retain a borrowed branch, move a fresh one) — runs only on the taken edge. FIXED A REAL UAF
  (`let x = if c mk("a") else mk("b")` returned freed garbage), not just a leak. `conformance/cases/47`.
- **Step 5 (`e89925a`)** — deleted the now-superseded scaffolding: the `producesOwnedTemporary`
  whitelist, `acqShadowDiff`/`dumpAcqShadow` + counters, the `main.zig` hooks, the `sema_shadow` import.
  `acquisitionDisposition` delegates straight to `principledDisposition`. Behavior-identical.

**RESULT:** ownership acquisition is ONE principled decision (`acquisitionDisposition` /
`principledDisposition` + the shared `takeOwnedElement`/`namesExistingOwner` primitives), decided from
the TypeId store, with no producer whitelist and no per-site string-kind re-derivation. The RAII
"constructor" half is done to match the (already-correct) destruction half.

**STILL OPEN (separate — NOT closed by this work):**
- **Chained-map leak (F4-5)** — closed by §4 parametric drop glue, a generic-body drop-insertion
  problem, orthogonal to the aggregate/expression acquisition rewritten here. The principled
  acquisition layer is a precondition for it, not the fix.
- Full sema-level Perceus pass (§5) — the codegen-level rewrite realizes the same rule table (§2) at
  codegen; promoting it to a sema IR pass with the static balance check (§6.1) remains future work.

---

## 0. Why the current approach cannot reach 100% (the root cause, precisely)

Today codegen answers "is this value owned? should I retain/release it here?" from:
- `isRefCountedType(rendered_type_string)` — a string classifier, and
- `pending_temps` drain heuristics — register a "+1" when an expression "looks like a producer",
  release it at statement end unless something "consumed" it.

Every site is locally plausible; there is **no global invariant**. So "struct literals are drainable
temporaries" balances the aggregate-field site and simultaneously unbalances the trait-downcast site,
and you only discover it at the next probe. The refcount of one value (`"X1"` in the chained-map leak)
threads through closure-return → StringBuilder alloc → first-map `push` → `mapped` scope-drop →
second-map `a.get` retain → get-temp drop → `a` destructor — six sites, three files, and **no single
place decides the whole story.** Hand-reasoning about that does not converge. That is a structural
defect, not a bug count.

**The fix is structural: make ownership a computed property with one owner of the decision.**

---

## 0b. What Kyte ALREADY has — the pass COMPLETES RAII, it does not add it

RAII has two halves. Kyte got the **destruction** half right and only the **ownership-assignment** half
wrong. Do not throw the working half away.

- ✅ **Destruction at scope exit — CORRECT and KEPT.** `releaseLocalVariables` (function exit),
  block-scoped `owned_locals` + `releaseLocalByName` (block exit), `releaseScopesForLoopExit`
  (break/continue), and real per-type `__destruct_*` destructors. This is RAII's "dtor runs
  deterministically at scope exit," and it is why the corpus is leak-free where it is covered.
- ❌ **Ownership assignment — GUESSED (the bug).** "Is this use a copy (dup) or a move? Is this arg
  borrowed or consumed?" is inferred by `isRefCountedType` + `pending_temps`. In C++ the TYPE SYSTEM
  answers this (overload picks copy-ctor / move-ctor / `T&`); Kyte has no enforcement, so it guesses,
  and guesses wrong at boundaries.

Proof it is the assignment half, not the destruction half: the chained-map leak's `a` scope-exit drop
DID run and DID release a's element — but the element was UNDER-retained on the way in (the first
map's `push` never `dup`'d it). **The drop was correct; the missing `dup` was the bug.**

**Consequence for scope:** the pass is *complete the RAII*, not *build RAII*. It REUSES the destructors,
the block-scope `owned_locals`, and the scope-exit release machinery; it only computes and inserts the
`dup`/`move`/`borrow` decisions (§2) that the heuristics were guessing, and adds the balance check (§6)
that proves the (kept) drops and the (new) dups cancel. Smaller and lower-risk than the §7 estimate
implies — the destruction infrastructure is already built and correct.

---

## 1. The ownership model

### 1.1 Value categories (from the TypeStore, never from a string)
- **Trivial** (`int`, `long`, `bool`, `ptr`, `float`, `double`, `future` handle): copyable, no ARC.
- **Managed** (`string`, `List/Map/Set/Storage`, `struct`, `trait object`, `closure`, `error_union`
  box, payload-carrying `enum`, `tuple`, `array`): heap, reference-counted.
`isManaged(TypeId)` is `TypeStore.isOwned` (already exists, already correct on concrete types — proven
by the `--shadow` gate, disagree=0). Enums route through variant info (payload ⇒ managed). No strings.

### 1.2 Ownership disposition of each expression occurrence
For every managed-typed expression node the pass assigns one of:
- **`owned`** — this occurrence PRODUCES or MOVES a +1 that must be consumed exactly once downstream
  (a constructor, a call returning owned, the last use of a variable, an aggregate literal).
- **`borrowed`** — a non-consuming read; the owner keeps its +1 (a method receiver, a read of a
  variable that is used again later, a field read for a call argument the callee only reads).

### 1.3 The single invariant the pass GUARANTEES
> Every `owned` value is consumed **exactly once** — by a bind, a store into an aggregate, a move into
> an owned parameter/return, or an inserted `drop`. Every `borrowed` value is consumed **zero** times
> by this scope.

This is a checkable, global property. The pass both *establishes* it (by inserting `dup`/`drop`) and
*asserts* it (Section 6). That assertion is what replaces "run a probe and hope."

### 1.4 The three IR operations the pass inserts
- **`dup(v)`** — `+1`. Lowers to `kyte_retain(v)`. Inserted when a value is used more than once: every
  non-last use gets a `dup` so each use owns its own reference.
- **`drop(v: T)`** — `-1` with the destructor for `T`. Lowers to `kyte_release(v, __drop_T)`. Inserted
  at the LAST live point of every `owned` value that nothing else consumed.
- **`move`** — no runtime op; a bookkeeping mark that ownership transferred (bind/store/return/owned-arg),
  so the pass does NOT also `drop` it. (Codegen emits nothing; it is purely the pass's accounting.)

Perceus precision: `dup` at every use except the last, `drop` at the last use — never a blanket
retain-everything. This is why it does not leak and does not over-retain.

---

## 2. The rules, per expression kind (the core — this is what "no heuristics" means)

The pass walks each function body with a **liveness / last-use** analysis (backward pass), then a
forward insertion pass. Rules:

| Construct | Ownership decision |
|---|---|
| **literal** (int/bool) | trivial — nothing |
| **string / template literal** | produces `owned` (heap) |
| **variable read** | `borrowed` if the variable is used again later in the scope; `owned` (a MOVE) if this is its LAST use |
| **`let x = e`** | `e` is consumed (`move` into x). x is a new owned local; `drop(x)` at x's last use / scope exit |
| **`x = e` (assign)** | `drop(old x)` first, then `move` e into x |
| **call `f(args)` returning managed** | the RESULT is `owned` (callee returns +1 — the uniform ABI, §3). Each ARG: `borrowed` (default C-style "callee borrows") unless the param is marked `consuming` |
| **method `recv.m(args)`** | `recv` is `borrowed` (a method borrows self unless it is a consuming method e.g. a `delete`); args as above; result `owned` if managed |
| **field read `x.f`** | reading a managed field for a BORROW use is `borrowed` (no dup); binding/moving it out is `dup` then `move` (the aggregate keeps its copy) |
| **aggregate literal** (`Foo{..}`, tuple, `List` push) | each managed element is `move`d in (the aggregate takes the +1); the aggregate is `owned` |
| **`return e`** | `e` is `move`d to the caller (transfer). No `drop` |
| **trait coercion `x as Trait`** | the fat pointer takes ownership of the struct: `move` the struct into the trait object (the box's drop releases it) |
| **downcast `x as Concrete`** | reads the struct pointer OUT of the fat pointer — a `borrow` of the box's contents; `dup` if the result outlives the box |
| **closure literal** | captures: each captured managed variable is `move`d (or `dup`+move) into the env; the closure box is `owned` |
| **`try e` / `catch`** | the error-union box is `owned` (a temp); on the ok path the payload is `dup`'d out and the box `drop`'d; on the err path the box is `move`d to the caller (return) |
| **generic-typed value** (`T`, `U`) | see §4 — parametric drop glue |

There is exactly ONE table. Codegen consults NONE of it — it lowers `dup`/`drop`/nothing. Every ARC
bug this session found is an entry in this table applied consistently instead of per-site.

---

## 3. The function ABI convention (fix the inconsistency that caused reverts)

Adopt ONE convention, enforced everywhere:
- **Returns are `owned`** — a function returning a managed value returns a +1 the caller consumes.
  (Already true for most of the codebase; make it universal.)
- **Parameters are `borrowed` by default** — the callee does not consume/free an argument; if it wants
  to keep it, it `dup`s. This is what `push`/`set` already do.
- **`consuming` parameters are opt-in** — a param the callee takes ownership of (frees or stores the
  actual +1) is marked `consuming` in the signature; the caller `move`s into it.
This kills the `push`-borrows-vs-`send`-consumes inconsistency (resume.md First Axis, task #13) by
making it declared, not guessed. `send(msg)` either borrows (default) or is `consuming` — the pass
reads the mark; codegen never wonders.

---

## 4. Generics — parametric drop glue (THE insight that closes the chained-map leak WITHOUT method-mono)

The chained-map leak is: inside the erased `List_map` body, `let mapped: U = f(...)` is never released
at loop scope because "U" reads as non-owned. Method-mono tried to fix this by specializing the whole
body (`List_string_map`) — big, and it did not fully close it.

**Better: keep the parametric body; make its `drop` calls parametric too.**
- The ownership pass inserts `drop(mapped: U)` at `mapped`'s last use — U is a type PARAMETER.
- `drop(v: U)` lowers to a call to **`__drop_U`**, a per-INSTANTIATION drop-glue function:
  `__drop_string(v) = kyte_release(v, __drop_string_impl)`, `__drop_int(v) = { }` (no-op).
- The erased `List_map` body is emitted ONCE; where U is bound (List<int>.map<string>), the call site
  passes the drop glue for U=string (via the instantiation's dictionary / a mangled call
  `__drop_string`), OR — simpler for Kyte's monomorphizing model — the body is emitted per
  instantiation but ONLY the `drop`/`dup` glue differs, not the logic.

This is exactly how Rust/Swift handle `T`'s drop: the LOGIC is parametric, the DROP GLUE is
per-type. It means:
- The erased body's `mapped` IS dropped (via `__drop_string`) → the first-map `mapped` release that
  was missing → **leak closed.**
- No need to specialize the entire method body for correctness. Method-mono becomes a pure SIZE/speed
  optimization (fewer indirections), not a correctness requirement — which is the right layering.

Concretely, Kyte already monomorphizes bodies; so the minimal form is: the ownership pass, run on the
already-monomorphized `List_int_map` etc., sees `mapped` typed by the instantiation and inserts the
concrete `drop`. Where a truly erased body must exist (an uninstantiated generic reached only via a
fn-pointer table), emit `__drop_T` glue and call it. Either way the DECISION is the pass's, uniform.

---

## 5. Where it lives, and the IR

- **New pass:** `src/sema/ownership.zig`, run AFTER type inference and (if kept) monomorphization,
  BEFORE codegen. Input: the typed AST + `TypeStore` + `TypedIr` (expr→TypeId). Output: an
  **ownership-annotated IR** — for Kyte's current shape, the cheapest form is to annotate `TypedIr`
  with, per expr node: its disposition (`owned`/`borrowed`) and a list of inserted `dup`/`drop` ops
  keyed to program points (before/after the node, at scope exit).
- **Codegen becomes a lowering:** delete `isRefCountedType`, the `isOwned*` fallback family, and the
  `pending_temps`/`drainTemporaries` heuristic machinery. Replace with: "emit `kyte_retain` for each
  `dup`, `kyte_release(_, __drop_T)` for each `drop`, nothing else." The destructor `__drop_T` comes
  from the TypeId (existing `getOrCreateDestructor`, but keyed on TypeId not a rendered string).
- `TypeStore.isOwned` + variant-aware enum ownership is the ONLY ownership oracle; it already exists
  and is `--shadow`-proven on concretes. Extend it with enum-variant awareness (the one documented gap)
  and it is total.

---

## 6. Verification — prove balance, don't probe for it

Three layers, all already partly built this session:
1. **Static balance check (new, cheap):** after insertion, assert per function that every `owned`
   value has exactly one consumer on every control-flow path (a linear-use check over the ops). A
   violation is a COMPILER error at build time, located — not a runtime leak found months later. This
   is the thing the string-heuristic model could never have.
2. **Runtime ARC audit (`--arc`, exists):** live-object count at exit must be 0 corpus-wide. Ratchets
   the static check.
3. **ASAN (`--asan`, exists, MANDATORY):** catches any residual use-after-free/double-free the static
   check's assumptions missed. The `--arc` audit is blind to UAFs; ASAN is the real net.
Plus the existing `--shadow` gate stays during migration to prove the new pass agrees with the old
engine on concretes until the old engine is deleted.

---

## 7. Migration plan — land it WITHOUT breaking the green tree (shadow-then-cutover)

This is the discipline that worked for the string→TypeId migration; reuse it exactly.
1. **Build the pass in SHADOW.** Run `ownership.zig`, compute dispositions + ops, but codegen keeps
   using the old heuristics. Add a diff: for each site, does the pass's decision match what the old
   heuristic did? Report `agree`/`disagree` per site (like `tdShadowDiff`). Drive `disagree` to a
   known, explained set (the sites the OLD engine got WRONG — the leaks/UAFs — should disagree; that
   is the pass being right).
2. **Cut over per construct, gated.** Flip codegen to obey the pass for ONE construct at a time (start
   with `let`/scope-drop, then aggregates, then calls, then generics), running the FULL gate suite
   (`--arc`/`--asan`/`--shadow`/unit + the runtime programs) after each. Revert-or-gate per step.
3. **Delete the heuristics.** Once every construct is cut over and green, delete `isRefCountedType`,
   `isOwned*` fallbacks, `pending_temps`. The static balance check (6.1) becomes the gate.
4. **Grow the corpus first.** Before cutting over a construct, add conformance cases for it under
   `--asan` (the coverage-gap lesson — every bug this session hid behind a green gate over a corpus
   that dodged the pattern). Cases 41–45 are the template.

Estimated ~1–2 focused weeks. Bounded because the rule table (§2) is finite and the migration is
mechanical per construct.

---

## 8. What this closes (the 100% claim, itemized)

- **Chained-generic-method leak (F4)** — closed by §4 (parametric drop of the first-map `mapped`).
- **F5 ARC ownership** — the entire phase becomes "the pass decides, codegen lowers, the static check
  proves." O4 audit is subsumed by 6.1. `isRefCountedType` deleted (its callers become `drop(v:T)`
  lowered from TypeId).
- **F2-6** — the ownership-annotated `TypedIr` IS "the checker writes the typed IR." Same artifact.
- **Method-mono (F4)** — demoted from correctness-blocker to optional optimization (§4). It can land
  later purely for `.o` size, or not at all.

**Does NOT close (separate, non-ARC, non-corrupting — a day or two total):**
- F1-6 Itanium length-prefixed mangling (name mangling; cosmetic).
- F3-5 honest i32 local slots (representation/perf; correctness already done).
- F3-5a decimal literals (a parser/lexer feature).
- F4-1 store carries struct type-args (generics representation; no consumer yet).

So: **the ARC pass takes the SAFETY/CORRECTNESS foundation — the dimension that makes it "fragile" — to
a true, provable 100%.** The residue is unrelated small cleanup that never caused a revert.

---

## 9. Risks & how the design pre-empts them
- **"A wrong `drop` passes gates but corrupts at runtime"** (the method-mono hazard) → the STATIC
  balance check (6.1) catches unbalanced ownership at BUILD time on ALL paths, before ASAN even runs.
  The heuristic model had no such check; this is the core upgrade.
- **Control-flow (branches, loops, early return, `try` propagation)** → last-use analysis is per-CFG;
  a value live on one branch and not another gets a `drop` on the branch that ends its life (Perceus
  handles this with per-edge drops; Kyte's `spillTemp`-to-slot trick already exists for exactly the
  "born in a branch the drain block doesn't dominate" case and can back the drop-on-edge).
- **The `StringBuilder.alloc_persistent` string** → under the pass it is a normal managed value with a
  known TypeId (`string`); its `drop` is inserted at its last use like any other. The "persistent"
  name is a red herring — it is honestly refcounted; the pass treats it uniformly.
- **FFI boundary** (resume.md Third Axis) → `owned`/`borrowed`/`consuming` dispositions are exactly the
  marks an `extern` signature needs; FFI marshalling reads them instead of inventing boundary rules.

---

## 10. First concrete step
Create `src/sema/ownership.zig` with the liveness/last-use analysis over one function body, producing
the disposition + op list, and wire the SHADOW diff (step 7.1) against the current heuristics on the
corpus. Do NOT touch codegen behavior yet. When the shadow's `disagree` set is exactly the known
leaks/UAFs (the pass being right where the heuristics were wrong), begin the per-construct cutover.

---

## 11. Reference implementations to follow (real, shipping — mapped to this design)

No single project is a drop-in template (each targets a different language), but each solves one piece
of §1–§7, and TWO are close enough to Kyte to follow closely. Ranked by relevance:

### A. Swift — SIL Ownership SSA (OSSA) + calling conventions. **Closest overall.**
Swift is an imperative language with `retain`/`release` ARC, generics, protocols (≈ traits) — Kyte's
shape. Learn:
- **OSSA (Ownership SSA):** Swift's SIL carries ownership on every value and a VERIFIER statically
  proves every owned value is consumed exactly once on all paths. This IS §6.1 (the static balance
  check) as a battle-tested implementation. → `swift/docs/SIL.rst`, `docs/OwnershipManifesto.md`,
  `lib/SIL/Verifier/`.
- **Calling conventions:** `@owned` / `@guaranteed` params = our `consuming` / `borrowed` (§3); the
  language surface `consuming`/`borrowing` keywords are exactly our marks. → the Ownership Manifesto.
- **ARC optimizer:** removes redundant retain/release pairs. → `lib/SILOptimizer/` (ARC passes).
Follow OSSA's *design* (ownership-annotated IR + verifier); the codebase is large, so read the docs,
not all the code.

### B. Nim — ARC/ORC with `=destroy`/`=sink`/`=copy` hooks. **Closest for the generics/drop-glue side.**
Nim is imperative with value semantics + generics + deterministic RC and destructors — and its
codebase is far smaller/more readable than Swift's. Learn:
- **Destructor/move hooks:** `=destroy`(drop glue), `=sink`(move), `=copy`(dup) are generated PER TYPE
  and dispatched for generic `T` — this IS §4 (parametric drop glue). Nim proves the approach works for
  an imperative language with generics. → Nim manual "Destructors and move semantics"; compiler
  `compiler/injectdestructors.nim` is the drop-insertion pass — **read this file; it is the single
  closest analogue to `ownership.zig`.**
- **`--mm:arc`** = deterministic RC (no cycle collector); `--mm:orc` adds cycle collection. Kyte can
  start at `arc` (no cycles) like Nim did.

### C. Koka — Perceus. **The reference for the dup/drop INSERTION algorithm.**
The precise last-use `dup`/`drop` placement in §1.4/§2 is Perceus. Learn the algorithm from:
- **Paper:** "Perceus: Garbage Free Reference Counting with Reuse", Reinking, Xie, de Moura, Leijen,
  PLDI 2021 — the canonical description of dup/drop insertion + drop-reuse.
- **Code:** `koka-lang/koka` (the `Backend`/`Core` reference-counting pass). Functional language, so
  its control flow is simpler than Kyte's — take the algorithm, not the language assumptions.

### D. Lean 4 — RC for a functional+systems language.
"Counting Immutable Beans: Reference Counting Optimized for Purely Functional Programming", Ullrich &
de Moura (IFL 2019) — the RC scheme behind Lean 4, same lineage as Perceus (Leijen). Good second
reading for the optimization (borrow inference, reuse) after the Perceus paper.

### E. Rust — MIR drop elaboration. **For the hard control-flow case only.**
Rust is not RC, but its **drop elaboration** solves exactly §9's hard problem: inserting drops at the
right point across branches, loops, early return, and partial moves, driven by a liveness/`drop-flag`
analysis. → `rustc_mir_transform` `elaborate_drops`; and "drop glue"/`drop_in_place` for the
per-monomorphization destructor (same idea as §4). Read this when implementing drop-on-CFG-edge.

### F. LLVM ObjC ARC optimizer — RC-pair elimination at the IR level.
`llvm/lib/Transforms/ObjCARC` — a real pass that removes redundant `retain`/`release`. Relevant LATER,
as an optimization once correctness lands (our `dup`/`drop` lower to `kyte_retain`/`kyte_release`, and
an ARC-opt pass can then elide pairs). Not needed for 100%-correct; needed for fast.

### G. C++ `std::shared_ptr` — the intuition pump and correctness baseline (you already know it)
`shared_ptr` IS reference counting, and Kyte's runtime already matches it: `kyte_retain`/`kyte_release`
= `shared_ptr` inc/dec; the 8-byte header at `ptr-8` = the control block (INLINE — better than
`shared_ptr`'s separate, atomically-counted block). So the RC MECHANISM is not the problem.

The lesson is WHY `shared_ptr` is correct and Kyte's codegen was not: **RAII.** `shared_ptr` never
guesses — a copy is a retain (copy-ctor), a scope exit is a release (dtor), `std::move` transfers; the
C++ compiler mechanically emits the dtor at every scope exit. That is the "one owner of the decision"
property (§0). **This whole document is "give Kyte RAII"**: the pass inserts `dup` (= copy), `drop`
(= dtor at last-use), `move` (= `std::move`) so ownership is mechanical, not heuristic. Sanity-check
every §2 rule with: "would this be right if every managed value were a `shared_ptr`?"

CAVEATS (why we follow Perceus/Nim/Swift, not `shared_ptr` literally): `shared_ptr` is the NAÏVE RC —
atomic counts, separate control block, no last-use elision, and it LEAKS CYCLES (needs `weak_ptr` by
hand; Kyte will need ORC-style cycle collection or weak refs eventually, same as Nim). And you CANNOT
shortcut by wrapping Kyte values in `shared_ptr` in the runtime: it changes the ABI, adds atomic cost,
and — the point — still does not tell the compiler WHERE to emit the copies/dtors. That placement IS
the pass. Kyte's inline-header RC + this pass = `shared_ptr` semantics with better layout and
compiler-optimized (non-atomic, elided, last-use) counts.

### Recommendation
**Follow Nim's `injectdestructors.nim` for the PASS structure** (closest language shape, readable),
**Swift OSSA for the VERIFIER + calling conventions** (the static-balance guarantee that ends the
revert cycle), and **the Perceus paper for the dup/drop ALGORITHM**. That triad covers §2 (rules),
§3 (ABI), §4 (parametric drop), §6 (verify). Rust's drop elaboration is the reference for §9 when the
control-flow drops get tricky.
