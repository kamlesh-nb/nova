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

## Status (2026-07-24)

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
real unit is **produce + ALL consume + ARC, corpus-green in one coherent change.** **Approach = default-OFF flag**
(like T6-split): thread a `compiler.valopt_box: bool` from `NOVA_VALOPT_BOX` (computed in `main.zig` from
`environ_map`, passed through `compile()` like `t6_split`); gate EVERY produce/consume behind it. Corpus runs with it
OFF → green (zero regression); develop + gate the boxing path with it ON (`NOVA_VALOPT_BOX=1 nova test <case>` +
`value_optional_zero`); flip the default ON only when the flag-ON corpus + ASAN are green. Then delete the flag.

**Exact plumbing identified:**
- `FunctionInfo.ret_type_ref: ?ast.TypeRef = null` (defaulted) — `typeRefToString` ERASES the optional (`int? →
  "int"`, `types.zig:392`), so `func.return_type` can't detect it. Populate `.ret_type_ref = fn_decl.ret_type` at the
  3 real-function construction sites (`llvm_codegen.zig` ~2741 / ~2780 / ~2821); lambdas/specializations leave null.
- Consume-`??` detection is RELIABLE via `typeOf(nc.left)` at the caller (the checker types `m.get(k)` as
  `.optional(int)`), so no plumbing needed there — use `valueOptionalInner(typeOf(nc.left))`.

### WIRING PROGRESS (2026-07-24 — flag `NOVA_VALOPT_BOX`, default OFF, corpus 152/152 green with it OFF)

✅ **Flag infrastructure** — `llvm_codegen.valopt_box_enabled` (module var) → `compiler.valopt_box` (field, set in
`new()`); set from `NOVA_VALOPT_BOX` in `main.zig` (both codegen entry paths). Default OFF.
✅ **`FunctionInfo.ret_type_ref`** — added + populated at ALL real-function construction sites (llvm_codegen.zig
~2760/~2799/~2841 + the specialization ~2742). Needed because `typeRefToString` erases the optional.
✅ **Produce-box at `return`** (`statements.zig` return_stmt) — a value-type-prim optional return (`.optional` with
`isPrimitiveTypeName` inner, type-params substituted) boxes the value; `undefined` stays 0. VERIFIED firing (debug
showed `inner=i32 isprim=true` → box for `fn f(): int | undefined`).
✅ **Consume-unbox at `??`** (`expressions.zig` nullish_coalesce) — value-optional left (via `typeOf(nc.left)` +
`valueOptionalInner`) unboxes on the present edge; `!= undefined` unchanged (box non-null).

⚠️ **EMPIRICALLY CONFIRMED: the wiring is ALL-OR-NOTHING and flag-ON is NOT testable until EVERY consume site is
wired.** With the flag ON, an IMPORTED `list` test failed (`list[0] != 10`) — produce-boxed value-optionals reach a
consume site (here a binary comparison / index on a value-optional) that isn't unboxing yet, so it reads the box
pointer as garbage. Because imported stdlib uses value-optionals via index/comparison/narrowing, NO flag-ON case runs
until those are wired. This is the confirmed reason it can't be gated incrementally.

**REMAINING consume sites to wire (the bulk — each unboxes a value-optional used AS its inner value):**
- **binary ops** (comparison `x != 10`, arithmetic `x + 1`) — unbox a value-optional operand. [first, per the failure]
- **index** `list[i]` used as a value; **arg-passing** `f(x)` where param is the value type; **assign/let** `let y:
  int = x`; **narrowed use** `if (x != undefined) { … x … }`.
- **`at()`** — returns V directly (traps on absent); no unbox needed there.
Then **ARC-own the box** (`isOwned(.optional .prim)` → true, free-only dtor) so boxes don't leak (`--arc`/ASAN), and
**extend + verify all widths**, then **flip the default + delete the flag**.

Suggested increments (all behind the flag, landed together for corpus-green):
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
