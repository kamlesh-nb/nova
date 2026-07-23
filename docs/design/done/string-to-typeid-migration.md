# String-type → TypeId migration — scope, impact, automation, order

**Purpose:** the full scope of the string→TypeId conversion the foundation needs, so it can be done as
one planned migration instead of piecemeal ARC band-aids. Measured 2026-07-18 (4 parallel code
inventories). **Lane A** (finish the foundation properly).

## 0. The one fact that reframes everything

**Monomorphization substitutes at RENDER TIME on strings, not in the store.** Sema types each generic
body ONCE, erased: an expression inside `List<T>`'s body carries a `.type_param{List,0}` TypeId in the
`ExprId`-keyed `TypedIr`. When `List_string_push` compiles, codegen *renders* that `.type_param` to
`"T"` (`renderLegacy`) then *string-substitutes* `"T"→"string"` (`substTypeParams`). **The store never
holds a concrete `.struct_{List,[string]}` for that expression.** `mono.zig` is SHADOW ("emits
nothing") — it computes the instantiation TypeId set but only renders it to strings.

⟹ The migration is NOT blocked by the ~450 call sites. It is blocked by ONE architectural gap:
codegen cannot obtain a concrete `TypeId` for an expression inside a monomorphized body, so it MUST
fall back to the render-time string path. **Fix that (the keystone, §4.1) and everything unblocks.**

## 1. The measured surface

| Category | Count | Notes |
|---|---|---|
| String **manufacturers** | 2 | `resolveExpressionTypeName` (38 real calls, types.zig:634), `typeRefToString` (42) — produce the strings everyone consumes |
| The **TypeId→string bridge** | 12 | `renderLegacy`/`renderUncached` (shadow.zig:509) — the flattener |
| **Decision functions** (string→semantics) | ~35 | ~450 total call sites across arc/types/llvm/expressions/declarations/statements |
| **String-surgery** sites | ~35 | **nearly all round-trips**: structured `Type` → renderLegacy → re-parsed |
| `[]const u8` type **state** | 5 fields | `current_local_types`/`function_local_types`/`FunctionInfo.return_type` + 2 partial TypeId parallels |

Deepest by call count: `typeRefToString` 42 · `resolveExpressionTypeName` 38 · `getStructBaseName` 24 ·
`getTypeSize` 23 · `isRefCountedType` 22 · `isStructType` 21 · `isUntypeablePlaceholder` 14.

## 2. The blocker (confirmed, file:line)

`TypeStore.isOwned` (src/types.zig:333) has two panic arms — `.type_param => unreachable` (:364),
`.unresolved => unreachable` (:365). **~7,157 expressions reach codegen carrying one of these**
(3,360 type_param + 3,797 unresolved). `isOwnedTypeId` (codegen/types.zig:502) routes all three
undecidable kinds (`.type_param`, `.unresolved`, `.enum_`) back to the STRING path
(`isOwnedRenderedFallback` → renderLegacy → substTypeParams → isRefCountedType). **So the string path
is mandatory until type_param and unresolved are eliminated at codegen.**

## 3. Scaffolding that already exists (the migration is not from scratch)

- **`subst.substitute(store, t, owner, args)`** (subst.zig:40) — does the real index-based
  `.type_param`→concrete-arg TypeId rewrite, interning into the store. Currently invoked only to type
  call *expressions*, never to rewrite whole bodies. **This is the keystone's engine.**
- **`mono.Worklist.seen`** — the exact set of concrete instantiation TypeIds (shadow).
- **`isOwnedTypeId` / `TypeStore.isOwned`** — the TypeId sibling of `isRefCountedType` (clean deletion
  target once the blocker clears).
- **`current_local_type_ids` / `function_local_type_ids`** — the TypeId parallels of the string state
  maps (partially populated: tuple + let-with-init only; params/self/annotated-lets still string).
- **`Type` variants** `.struct_{decl,args}`, `.tuple`, `.func`, `.error_union`, `.storage`, `.enum_` —
  every structural predicate is a thin `store.get(id)` kind-match away.

## 4. The order (Lane A) — each step removes string sites monotonically

### 4.1 KEYSTONE — per-instantiation typing in the store  ⟵ the unlock, hardest piece
A new pass (in sema, beside `mono.zig`): for each instantiation in `Worklist.seen`, walk the generic
body's `expr_types` and rewrite each expr's TypeId through `subst.substitute(store, t, decl, args)` →
a concrete interned TypeId; store it in a `(ExprId, instantiation) → TypeId` side table. Codegen (which
already knows `current_instantiation`) reads the concrete id directly — **no renderLegacy, no
substTypeParams**. **Verify** with a shadow-diff: the concrete id's rendered name must equal today's
`substTypeParams` output at every site (the F2-stage-3 discipline). Method-level type params (`U` in
`map<U>`) need the method-instantiation context too — same mechanism, keyed `(ExprId, inst, method-args)`.
*Impact:* eliminates `.type_param` reaching codegen. *Risk:* a missed substitution leaves `.type_param`
→ still panics; the shadow-diff catches divergence before cutover. *Not scriptable — architectural.*

### 4.2 F2-5 — `.unresolved` fatal
Drive the 3,797 unresolved down (fix genuine sema gaps; the module/type-receiver-ident cluster needs
F1-3b codegen routing, partly done this session), then make `.unresolved` an error at end of sema.
*Impact:* eliminates the second panic arm's input. *Not scriptable — sema work.*

### 4.3 Flip `isOwned`'s arms + delete `isRefCountedType`
With type_param/unresolved gone, `st.isOwned` is total. Make `isOwned(.enum_)` variant-aware (it's
currently `false`, wrong for payload enums — needs enum-variant info; precompute per-enum or thread the
symbol table). Then delete `isRefCountedType` (22 sites) and route ownership through `isOwnedTypeId`.
*Risk:* enum ownership is the one non-mechanical sub-piece.

### 4.4 Mechanical conversion (semi-scriptable + shadow-diff)  — the ~450 sites
Write the TypeStore/codegen structural predicates as thin `store.get(id)` wrappers
(`isStructType`, `isTupleType`, `errUnionParts`, tuple/storage element extraction, `getTypeSize`,
`toLLVMType` TypeId versions). Convert call sites from `resolveExpressionTypeName(&e)` →
`typeOf(&e)`. **Delete** the round-trip string-surgery (`substTypeParams`, `substituteFieldType`,
`getTupleElementType`, `countTupleElements`, `errUnionParts`-by-string, storage/atomic/generic-arg
splits) — replaced by direct field reads. The consumers split into 8 groups (G1–G8): ~16 are uniform
(pure struct-ness gates, primitive dispatch, structural extraction) and semi-scriptable; ~22 are
name-for-symbol (`constructTraitObject`, `<struct>_<field>`) needing manual handling.

### 4.5 Complete the state parallels, delete the string maps
Fully populate `current_local_type_ids`/`function_local_type_ids` (params/self/annotated-lets), then
delete `current_local_types`/`function_local_types`/`FunctionInfo.return_type`-as-string.

## 5. Automation verdict (the piecemeal-vs-script question)

**A python/AST script is a HELPER for §4.4 and the verification, NOT the primary vehicle.** ~70% of
the real work (§4.1 keystone, §4.2 F2-5, §4.3 enum awareness, §4.4's TypeId sizing/LLVM functions) is
**architectural and not scriptable**. What IS worth scripting:
- **A shadow-diff harness** (like F2 stage 3): at every decision site, compute BOTH the TypeId answer
  and the string answer, count agreement, dump divergences. This is the safety net that makes the
  whole migration non-fragile — it converts "did I break something the corpus doesn't exercise?" (the
  bug class that's been biting us) into a measured number *before* cutover.
- **Call-site enumeration + the uniform G3/G4/G6 conversions** (~16 sites) — a mechanical find/rewrite,
  reviewed.
The ~22 name-for-symbol sites and all of §4.1–4.3 are manual, careful, gated.

## 6. Definition of done (grep → 0, per beta-plan §8)
`isRefCountedType(` · `getStructBaseName` (as a lookup key) · bare `"i32"` · `mem.eql`-on-type-name ·
`func_map` suffix scans · `substTypeParams`/`substituteFieldType` · `resolveExpressionTypeName` — all
deleted. When these read zero, codegen cannot decide semantics from a string, by construction.

## 7. Why this converges (answering "can we finish?")
Every step above **removes** string sites and never adds them (unlike the substTypeParams/method-
specialization band-aids, which ADD string machinery). The keystone unblocks; §4.3–4.5 are then
downhill and shadow-diff-verified. It is finite and monotone. The band-aid approach was
non-convergent *because it was the wrong layer* — patching the string system instead of removing it.
