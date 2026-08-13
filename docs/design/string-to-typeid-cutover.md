# String engine removal: the full TypeId cutover plan

## Goal

One uniform way to reason about types in codegen. Every type DECISION (is this owned, a string, a float, a
struct, a trait, ...) is made from a resolved `TypeId` through the `TypeStore`. The only place a `TypeId`
ever becomes a string is a single canonical `symbolName(tid)` mangler used for LLVM symbol names and map
keys. The parallel "string engine" (deciding types by comparing rendered type-name spellings) is deleted in
full, and a lint keeps it from coming back.

This is a maintainability project. The dual engine is the root of the whole C-series soundness-bug class:
two sources of truth that must agree, kept honest only by a shadow gate, where a drifted spelling silently
fails open into a miscompile (the `any`-box leak fixed on 2026-08-13 was exactly this).

## End state (what "uniform" means here)

- **Decisions**: `store.get(tid)` predicates only. Zero `std.mem.eql(u8, <name>, "<type>")` in `src/codegen/`.
- **Names**: exactly one function, `symbolName(self, tid) -> []const u8` (memoised), is the TypeId -> string
  boundary. `func_map`, `structs`, `enums`, `traits`, vtables and every LLVM symbol derive their key from it.
- **Deleted**: `legacyStringOwnership`, `isOwnedRenderedFallback`, `erasedOwnershipDefault`, the
  `tdShadowDiff` shadow-diff machinery and its counters, `resolveExpressionTypeName` (as a decision source),
  and the ad-hoc `renderLegacy`/`typeRefToString`/`getStructBaseName` calls scattered across codegen.
- **Enforced**: a CI lint fails the build if a string type-decision is reintroduced.

## The two root blockers (why the string engine cannot simply be deleted today)

### Blocker A: sema does not attach a concrete TypeId to every expression codegen decides on

`typeOfExprConcrete(expr)` returns null in a small but load-bearing set of positions, and the string path
(which resolves by NAME through a different route) is the fallback for exactly those:

- Collection-element access (`list[i]`, `map.get(k)`, `.at(i)`) where the element type is generic. The
  container's instantiation knows the element type (`List_string` knows it holds string), but that concrete
  id is not written onto the access expression's node. This is what made the `is_string` index conversion
  miscompile `test_collection_string` on 2026-08-13.
- Erased generic bodies. Before monomorphisation instantiates, an erased body carries type-param types
  (`T`), not concrete ids. These bodies are dead-stripped by globalDCE but must still emit verifiable IR, so
  codegen needs a decision for them.
- Assorted non-concrete / cross-module expression nodes.

KEY INSIGHT: the types ARE known. Monomorphisation resolves every instantiation to concrete types. The gap
is PROPAGATION COVERAGE, not missing information. Phase 1 is "attach the id that already exists to the
node", which is tractable, not "invent a type".

### Blocker B: the compiler's symbol and lookup maps are keyed by NAME strings

`func_map`, `structs`, `enums`, `traits`, the vtable globals and the mangled LLVM function names are all
string-keyed. `getStructBaseName("List<int>") -> "List"` exists because methods are looked up by base name.
LLVM symbol names are strings by necessity (the linker deals in strings), so SOME TypeId -> string boundary
is irreducible. The fix is not to delete the boundary but to make it SINGULAR and one-way: derive every name
from one `symbolName(tid)`, never re-render ad hoc.

## Plan (phased, each phase gated by corpus + `--asan` + the shadow/lint invariant)

### Phase 0 — Safety net and worklist (small, do first)

1. Wire the shadow gate into `gate.sh` as a standing check: fail if `ownership td_disagree != 0` or
   `keystone_disagree != 0`. This freezes the current 0-disagreement contract so nothing regresses during
   the migration.
2. Add a "non-concrete decision census": at every decision site, when `typeOfExprConcrete(expr)` is null,
   record the expression kind and source span under an opt-in env flag. Running it over the corpus produces
   the exact, counted worklist for Phase 1 (which syntactic positions lack a concrete id, and how many).

Deliverable: a green CI gate plus a ranked list of the non-concrete positions to fix.

### Phase 1 — Close Blocker A (the crux; the real compiler work)

Drive the non-concrete census to zero. Sub-steps, each landed and gated independently:

- 1a. **Collection-element typing.** When sema types an index/`.get`/`.at` access, propagate the concrete
  element `TypeId` from the receiver's instantiated container type onto the access expression's node
  (`typed_ir.typeOf` / `typeOfInst`). The mono pass already knows the element type; write it back per expr
  per instantiation.
- 1b. **Instantiation write-back coverage.** Ensure `typeOfInst(expr.id, inst)` is populated for EVERY
  expression in an instantiated body, not just some. The infrastructure (`typeOfInst`) exists; this closes
  the coverage holes the census surfaces.
- 1c. **Erased bodies.** Prefer: stop emitting erased generic bodies at all, emitting only monomorphised
  instantiations, so there is no erased-body decision to make and `erasedOwnershipDefault` deletes cleanly.
  Fallback if a link-time erased body is still required: decide it purely at the type-param level (a type
  param carries no owned reference), which is a TypeId-level rule, not a string one.

Exit criterion: the Phase 0 census reports 0 non-concrete decision sites across the corpus.

### Phase 2 — Migrate every decision site to TypeId

Now that a concrete id is guaranteed:

- Replace the ~55 `== "<primitive>"` comparisons with `store.get(...)` predicates (extend the
  `isStringExpr`/`isFloatExpr`/... family already introduced). Safe because Phase 1 removed the null case.
- Replace every `ownedByName(name)` decision with `isOwnedTypeId(tid)` at the call site (thread the id, not
  the name).
- Delete `erasedOwnershipDefault` (its only reachable path is gone after 1c).

### Phase 3 — Collapse the name layer to one function

- Introduce `symbolName(self, tid) -> []const u8` (memoised): the SINGLE TypeId -> string boundary, producing
  the mangled name used for map keys and LLVM symbols.
- Route map lookups through it. Pragmatic scope: keep the maps string-keyed but derive every key via
  `symbolName(tid)` (uniform derivation) rather than re-keying every map by TypeId (a larger, riskier change
  that can be a later step if desired). The uniformity win is the single derivation point.
- Retire ad-hoc `renderLegacy` / `typeRefToString` / `getStructBaseName` decision-and-name calls in favour of
  `symbolName`.

### Phase 4 — Delete the string engine and the scaffolding

- Remove `legacyStringOwnership`, `isOwnedRenderedFallback`, `tdShadowDiff`, and the
  `a2_irct`/`td_*`/`disp_*` counters. Their job (prove agreement before cutover) is complete; corpus +
  `--asan` + a lighter TypeId-only invariant remain the regression net.
- Remove `resolveExpressionTypeName` as a decision source; its name uses move to `symbolName(tid)`.
- Reduce `typeRefToString` / `getStructBaseName` to internal helpers of `symbolName`, or delete if unused.

### Phase 5 — Lock it in

- Add a CI lint: no `std.mem.eql(u8, <x>, "<type-spelling>")` in `src/codegen/`, and `symbolName(tid)` is the
  only sanctioned TypeId -> string call. Reintroducing a string type-decision fails the build.

## Effort and risk (honest)

- Phase 1 is the hard part: real type-inference and monomorphisation write-back work, the riskiest because
  it touches typing. It is the only phase that legitimately removes the fallback rather than relocating it.
  Budget multiple days and land 1a/1b/1c as separate gated changes.
- Phases 2 to 4 are large but mechanical once Phase 1 holds, each gated by corpus + `--asan`.
- Total: a multi-week, staged effort, not a single session. But it has a defined end state and a lint that
  makes the uniform design permanent.

## Why it is worth it

It closes the entire C-series soundness-bug class at the root (one source of truth), removes the dual-engine
cognitive and testing burden, deletes the shadow scaffolding, and drops the per-call string allocation on hot
codegen paths. The result is uniform: decisions on TypeId, names from one mangler, enforced by a lint.

## Status

- Prerequisite already done (2026-08-13): decisions run TypeId-first; shadow gate at 0 disagreements; C7/C8/
  C10 fail-closed; the `any` ownership under-claim fixed; codegen string-type comparisons reduced 73 -> 55
  with the non-convertible ones proven load-bearing (they are the Phase 1 worklist).
- Next actionable step: Phase 0.
