# Value-type optionals — boxing (Nova's `Nullable<T>`), the fix for V1

**The bug (V1, `nova-value-optional-zero-bug`):** a value-type optional (`int | undefined`, `long?`, `float?`,
`bool?`, `double?`) has NO distinct runtime representation for `undefined` — `codegen/types.zig:392` shows an
optional's machine type IS its inner type, and `undefined` is the literal `0` (`expressions.zig:1214`). For pointer
types (string/struct/trait/`Service`/`decimal` — all heap objects) `0` = null is correct. For value types the value
`0`/`0.0`/`false` collides with absent: `Map<string,int>.get(k)` storing `0` reads back as `undefined`. Silent
corruption.

## Why NOT a sentinel (rejected)

An out-of-range sentinel (`undefined` = `1<<width`) works for **sub-64-bit integers** (int/bool/byte/short) but is
piecemeal and cannot be uniform:
- `long`/`ulong` are **full 64-bit** — every bit pattern is a valid value, so NO sentinel exists.
- `float`/`double` would need a reserved NaN encoding (fragile, eats a NaN).
It would leave "optionals of some value types work, of others silently corrupt" — worse than a uniform rule.

## The design — borrow C#'s two-tier model

C# splits nullability and Nova already gets tier 1 right:
- **Reference types** — `null` is a null *reference* (`0`); zero runtime cost. **Nova already does this** for
  string/struct/trait/`Service`/`decimal`. UNCHANGED.
- **Value types** — `int?` is `Nullable<T> = { bool HasValue; T Value; }` — an EXPLICIT presence indicator, never a
  magic value. This is the tier Nova lacks.

C# carries presence in **two fields** (no alloc, but a value-optional is two words). Nova's Storage/Map/List assume a
uniform **one-word (8-byte) slot**, so two-word value-optionals would ripple through every container. The one-word,
container-compatible expression of "explicit presence" is **boxing**: a value-type optional is a **pointer to a
heap-boxed value, or null for `undefined`** — exactly what C# does when it boxes a `Nullable<T>` to `object`.

**Representation:** for a value type `T`, `T | undefined` becomes a machine word that is either
- `0` (null) → `undefined`, or
- a non-null pointer to a heap cell holding the `T` value (even `0`/`0.0`/`false`).

Then, uniformly for ALL value types:
- `x != undefined` / `x == undefined` → `x != 0` / `x == 0` (present is always non-null). **Works unchanged.**
- `x ?? d` → `x == 0 ? d : *x` (deref the box).
- `if (x != undefined) { … x … }` narrowing → deref on use.
- `at()` / trapping access → deref (trap if null).
- `decimal`/reference optionals: already pointers → **no change**.

**Reuse:** the `nova_any_box` runtime primitives (`src/runtime/alloc.cpp`, built for the deferred boxed-`any`, see
`docs/design/boxed-any.md`) are the boxing foundation — a value-optional box is simpler (no dtor: value types aren't
ARC-owned; the box is just a value cell freed with its owner). **One boxing foundation serves BOTH value-optionals
and dynamic `any`.**

## Status (2026-07-24) — ✅ COMPLETE (landed as one atomic pass)

**V1 IS DONE.** Value-type optionals are boxed end-to-end; a stored/present `0`/`0.0`/`false` is a
non-null pointer, distinct from `undefined` (null). **Corpus 153/153, ASAN 280/280, no ARC-leak
regression** (the value-optional gate `127_value_optional_zero` audits clean; the pre-existing
`nova_random_hex`/async-runtime baseline drift is unrelated, proven by a revert-and-re-audit). No flag.

**The invariant that makes it consistent:** since `val_type` is i64 everywhere, a boxed `int?` and a
raw `int` are the SAME machine type — so V1 is a *semantic* invariant, not an LLVM-type change: a value
of type `.optional(.prim)` is a "pointer-or-null", a bare prim is a raw word. Two predicates key every
decision on the expression FORM (not the checker's propagated type, which flows optionality through
arithmetic — `int? % int = int?` — even though the VALUE is already raw):
- **`valoptTypeRefIsValue(tr)`** — a declared type is a value-optional (`.optional` of a `cgPrim`, not
  `ptr`); drives PRODUCE. Uses the TypeRef because `typeRefToString` erases the optional.
- **`exprYieldsValoptBox(e)`** — compiling `e` MATERIALIZES a box: a value-optional-typed LEAF
  (`m.get(k)` call, an `int?` ident/field/index). A COMPOUND (`x % 2`, `a ?? b`, cast) or a
  `.generic_call` (erased free fns don't box) yields a RAW value → NOT a box. Drives CONSUME, the
  "already-a-box?" PRODUCE guard, AND `isOwnedExpr` (a value-optional is an owned heap box only if it
  yields one — else `nova_release` would free a raw int as a pointer).

**Where it landed (all in one change):**
- Foundation: runtime `nova_valopt_box`/`nova_valopt_unbox` (`alloc.cpp`, 8-byte ARC cell) + codegen
  `buildValoptBox`/`buildValoptUnbox`/`valueOptionalInner`.
- PRODUCE (box a bare value into a value-optional slot): `return` (via `FunctionInfo.ret_type_ref`, the
  un-erased TypeRef) · `let x: int? = …` · call-argument to a value-optional param (`coerceValoptArg`).
- CONSUME (unbox a box into its value): `??` present edge · binary operands (`x != 10`, `x % 2`) ·
  narrowed ident load (slot `int?` + use typed bare prim = the H2-narrowed `if (x != undefined){…x…}`) ·
  **every call argument** uniformly in `compileCallArgument` (`equalInt(m.get(k), 10)` — the universal,
  param-independent consume site).
- SLOT sizing: a value-optional local is an i64 alloca even for `float?`/`double?` (`slotTypeForLocalId`)
  — the slot holds a pointer, not the FP value.
- ARC: `isOwnedTypeId(.optional value)` = owned; a free-only destructor (`nova_release(box, null)`);
  boxes are retained/released by the existing machinery, freed once — no leak (audited).
- NULL-CHECK (`!= undefined`/`== undefined`) is unchanged: present box is non-null, absent is 0.

**Erasure gap — CLOSED (2026-07-24, follow-up).** A FREE generic fn returning `T | undefined`
(`maybe<T>`) was type-erased — one body for all `T`, so it couldn't box a value-typed return and
collapsed present-`0` with `undefined`. **Fixed by free-fn monomorphization** (mirrors struct-method
mono): a new `sema_mono.free_fn_insts` worklist (recorded at the checker's free-fn `.generic_call` arm,
`infer.zig`), a Pass-2 emission loop that emits `maybe__int` per instantiation with `method_subst`
{T→concrete} + `ret_type_ref`, and a call-site resolver in the `.generic_call` arm that prefers the
spec. Now the spec body boxes (`T | undefined` renders `int | undefined` under the subst → value-optional
→ box), and `exprYieldsValoptBox` treats a `.generic_call` as box-yielding again. Gate:
`119_generic_return::test_generic_optional_value_zero` (present-0 survives). Corpus 153/153, ASAN 280/280.

---

### Historical foundation note (superseded by the Status above)

✅ **FOUNDATION BUILT + verified compiling** (corpus 152/152, unused until wired):
- Runtime: `nova_valopt_box(value)` / `nova_valopt_unbox(box)` in `src/runtime/alloc.cpp` (+ `nova_abi.h`) — an
  8-byte ARC cell; present = non-null box, `undefined` = null.
- Codegen: `buildValoptBox` / `buildValoptUnbox` emit helpers + **`valueOptionalInner(tid)`** — the typed-IR detector
  that returns the inner TypeId iff `tid` is `.optional(.prim)` (int/long/float/double/bool), else null (pointer/
  decimal optionals unchanged). All in `src/codegen/llvm_codegen.zig`.

⏳ **REMAINING = the coercion-site WIRING** (the epic; do as gated increments, corpus + a new `value_optional_zero`
gate + ASAN at each step). KEY constraint: the optional erases to its inner STRING (`types.zig:392`), so every
decision below MUST be driven by the **typed IR** (`typeOf(expr)` → `valueOptionalInner`), NOT the type-name string.

**⚠️ KEY CONSTRAINT (found while wiring, 2026-07-24): the wiring is ALL-OR-NOTHING per type — NOT partially
landable.** The moment produce boxes an `int?`, EVERY consume site that isn't wired (narrowing, `at`, `as`,
arithmetic, arg-passing) reads the box pointer as garbage → corpus reds. So "produce + `??`" alone is unsafe; the
real unit is **produce + ALL consume + ARC, corpus-green in ONE coherent atomic change.**

**Approach = one ATOMIC change on a branch (NO dev flag).** A trial env flag (`NOVA_VALOPT_BOX`) was wired then
REMOVED — no shipped language exposes such a switch, and gating a representation change incrementally is exactly what
the all-or-nothing constraint forbids. The conventional path: do the whole wiring on a branch; the corpus is RED
mid-way (a half-changed representation is invalid), GREEN when complete; then merge. Present values are untouched, so
the diff is confined to the produce/consume BOUNDARY sites below.

**Exact plumbing identified (RE-ADD when doing the atomic pass — it was reverted with the flag):**
- `FunctionInfo.ret_type_ref: ?ast.TypeRef` — `typeRefToString` ERASES the optional (`int? → "int"`, `types.zig:392`),
  so `func.return_type` can't detect it. Populate `.ret_type_ref = fn_decl.ret_type` at ALL real-function
  construction sites (`llvm_codegen.zig` — 3 fn sites + the specialization site).
- Consume detection is RELIABLE via `typeOf(expr)` at the site (the checker types `m.get(k)` as `.optional(int)`) —
  use `valueOptionalInner(typeOf(expr))`.

### WIRING STATUS (2026-07-24 — flag + partial wiring REVERTED; foundation KEPT, flag-free)

Corpus 152/152, ASAN 276/276 — clean with NO flag. What survives in-tree is the **foundation only**:
✅ Runtime `nova_valopt_box`/`nova_valopt_unbox` (`alloc.cpp` + `nova_abi.h`).
✅ Codegen `buildValoptBox`/`buildValoptUnbox`/`valueOptionalInner` (`llvm_codegen.zig`) — unused until the pass.

REVERTED (were incomplete; unconditional they red the corpus, and a flag is not the right vehicle):
- The `NOVA_VALOPT_BOX` flag (module var + `compiler` field + `main.zig` wiring).
- `FunctionInfo.ret_type_ref` + its population sites.
- Produce-box at `return` (`statements.zig`) and consume-unbox at `??` (`expressions.zig`).

**EMPIRICALLY CONFIRMED all-or-nothing:** with produce boxing an `int?`, an IMPORTED `list` test failed
(`list[0] != 10`) — a value-optional reached a consume site (comparison/index) not yet unboxing, reading the box
pointer as garbage. Imported stdlib uses value-optionals via index/comparison/narrowing, so NO case runs until EVERY
consume site is wired. Hence: one atomic pass, not increments.

**The atomic pass wires (all together, corpus red→green):**
- **Produce** at `return` / `let`/assign / arg-passing when the target type is a value-optional and the RHS is the
  inner value (`undefined` literal stays 0 = null box).
- **Consume-unbox** at `??` (present edge), **binary ops** (`x != 10`, `x + 1`), **index used as value**,
  **narrowed use** (`if (x != undefined) { … x … }`), **assign/arg** where the target is the inner value type.
  `at()` returns V directly (traps on absent) — no unbox.
- **ARC-own the box** (`isOwned(.optional .prim)` → true, free-only dtor) so boxes don't leak (`--arc`/ASAN).
- **All widths** — int/long/uint/ulong/short/byte/bool/float/double, one uniform rule.

Reference increment order (do them in ONE change, not separate commits):
1. **Consume `??`** (`expressions.zig:3521`): if `valueOptionalInner(typeOf(nc.left))` — on the present edge
   (`left != 0`) feed the phi `buildValoptUnbox(left)` instead of the raw box; the RHS default is already unboxed.
2. **Produce at `let`/assign**: when the declared/target type is a value-optional and the RHS is the inner value (not
   `undefined`, not already an optional) → `buildValoptBox(rhs)`. (`undefined` literal stays 0.)
3. **Produce at `return`**: same, when the function return type is a value-optional (drives `Map`/`List.get`'s
   `return value`). Needs the typed return type (AST return TypeRef lowered), since the string erases the optional.
4. **Consume narrowing/`at`/`as`/arithmetic**: when a value-optional local is used as its inner value type → unbox.
   This is the widest-reaching increment (every read of a narrowed value-optional).
5. **ARC ownership**: a value-optional box is a heap cell — decide owned (retain/release the box; `isOwned(.optional
   .prim)` → true, dtor = free-only) so boxes don't leak. Verify with `--arc` + ASAN.
6. **Extend + verify** across all value widths (int/long/uint/ulong/short/byte/bool/float/double) — one uniform rule.

Gate target: `value_optional_zero` — `Map<string,int>` / `long?` / `float?` / `double?` / `bool?` storing `0`/`0.0`/
`false`, then `!= undefined` (true), `?? d` (yields the stored value), narrowed use (yields the stored value).

## Implementation plan (incremental, gated — same discipline as boxed-`any`)

1. **Runtime:** a value-cell box (or reuse `nova_any_box` with a 0 dtor). `nova_valopt_box(value)` → ptr;
   `nova_valopt_unbox(ptr)` → value; box freed by its owner (no ARC).
2. **Type system:** mark `.optional(valuetype)` as a distinct codegen representation (a pointer). `.optional(ptr
   type)` stays as-is (already a pointer).
3. **Box on PRODUCE** (T → value-optional): the coercion sites — a `return v` where the return type is a
   value-optional, `let x: int? = v`, assigning/storing `v` into a value-optional slot (incl. Map/List element
   stores), `?.` producing a value-optional. Box `v`.
4. **`undefined` on produce:** in a value-optional context → `0` (null). (Already `0`; correct once present is a
   non-null box.)
5. **Unbox on CONSUME** (value-optional → T): `??` result, narrowed use, `at()`, `as`. Deref.
6. **Null-check:** `!= undefined` stays `!= 0` (present = non-null box). No change needed.
7. **Ownership:** a value-optional box is NOT ARC-owned (value types); its slot is freed with the container. Ensure
   ARC treats `.optional(valuetype)` correctly (the box is a plain heap cell, freed once).

**Scope/risk:** pervasive (Map/List/`??`/narrowing/returns), the boxed-`any` class — **implement incrementally with
the corpus (151/151) + a new `value_optional_zero` gate + ASAN as the gate at every step; revert per-increment if it
destabilizes.** `long`/`double`/`float` and `int` all fixed by one uniform rule.

## Also worth borrowing from C# (separate, small)

- `?:` ternary — **DONE** (already parsed → `if`-expression; gate `126_ternary`).
- `??=` null-coalescing assignment — a small parser desugar (`x = x ?? d`).
- `if (x is T v)` pattern narrowing — Nova has H2 narrowing + `??`/`?.`; `is`-pattern is a future ergonomic.
