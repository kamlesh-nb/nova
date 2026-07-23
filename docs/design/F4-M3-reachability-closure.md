# F4 M3 — Erased-Body Reachability Closure (scope)

**Problem (established empirically).** Codegen emits a type-erased body for every generic struct method
(`List_push`, `Map_get`, …) as a link-time fallback. Most are dead (`f45_erased_fallback == 0`: no
INSTANTIATED call reaches them), but a **blanket suppression regressed 8/103** because the erased bodies are
NOT all dead: a `base_needed` method body (`List_i32_map`, kept so an inferred-arg call `xs.map((x)=>..)` can
reach it) contains `result: List<U>` whose `result.push` can only resolve to the erased `List_push` — `U` is
a method-level param, unbound at that site, so no mono symbol exists (the **abstract residue**). So an erased
body may only be suppressed if **no retained body references it**. That decision is the reachability closure.

**What this build buys — and does NOT.** It removes the DEAD erased bodies (code size) and the
`__destruct_*_T/K/V` destructor family minted inside them. It does **not** by itself retire the string
parsers (`isRefCountedType`/`substituteFieldType`/`storageElem`/`getTupleElementType`): the surviving
abstract-residue bodies inherently make string/erasure-rule decisions on `T`/`U`, and the ~262k
`isRefCountedType` calls are dominated by PRIMITIVE decisions in ALL bodies (mono included), not just erased
ones. Full string-parser retirement additionally needs F2-6 stage-5 completion (all destructors via TypeId)
AND eliminating the abstract residue (a larger method-mono change). This build is a bounded, correct step and
the empirical validator of the abstract-residue boundary — not the A2 close on its own.

## Retained roots (never suppressed)
- Every non-generic function body.
- Every struct-instantiation mono body (`List_string_push`, `Map_string_i32_set`, …).
- Every `base_needed` method body (`sema_mono.baseIsNeeded`, `mono.zig:81-94`) and method-specialization
  (`App_get__GetUser`). These are the roots the abstract residue lives in.

The reachable-erased set = every erased symbol reachable (transitively) from a root. Suppress an erased body
iff its symbol is NOT in that set.

## Approach A — LLVM globalDCE — ✅ LANDED (R1, commit 88db887)
DONE. `FunctionInfo.erased_generic` (set when `inst_opt==null && struct is generic`) → internal linkage at
body-compile (declarations.zig ~968); a `__destruct_*` name sweep → internal (declarations.zig, pre-pass);
`globaldce` appended to the pass string (`default<O0|O3>,globaldce`) so it runs at O0. RESULT
(14_collections_map final binary): erased method bodies **22 → 5**, erased `_T/_K/_V` destructors **6 → 1**.
**The abstract-residue ORACLE (survivors): `List_grow`, `List_push`, `Map_delete`, `__destruct_Storage_T`** —
exactly the bodies a `base_needed` method body's `List<U>` residue calls. FUNC/ARC 103/103, ASAN 81/81. This
is R2's target set: the pre-pass must keep precisely these and drop the rest. Original design notes below.

## Approach A (original design notes)
LLVM already runs `LLVMRunPasses(module, "default<O0|O3>")` (declarations.zig:1306-1315) and the codebase
already sets `LLVMInternalLinkage` on helper globals. So:
1. Mark every ERASED struct-method body (`inst_opt == null`, generic struct — the `FunctionInfo` emitted at
   llvm_codegen.zig:2562-2573) and its on-demand erased destructors (`__destruct_List`/`_T`/`_K`, arc.zig)
   with `LLVMInternalLinkage` (external linkage tells DCE "assume used").
2. Ensure `globaldce` runs even at O0 — either append it to the pass string
   (`"globaldce"` / `"default<O0>,globaldce"`) or run it explicitly regardless of opt level.
3. LLVM computes the reachability closure precisely: dead erased internals are deleted; the abstract-residue
   ones (referenced by a `base_needed` root) survive.
- **Effort:** ~0.5–1d. **Gate:** module verify + link OK; full-corpus ASAN 0; measure the code-size / function-
  count drop; **INSPECT the surviving erased bodies — that set IS the abstract residue** (validates the
  theory and becomes the oracle for Approach B). Risk: LOW (LLVM owns the reachability; a mis-mark that keeps
  a needed body just misses an optimization, and internal+unused is exactly what DCE is for).
- **Limitation:** removes bodies AFTER codegen, so the string-parser CALLS during their emission already
  happened. This is the code-size win + the validator, not the string-parser lever.

## Approach B — ✅ LANDED (R2, commit 992a6bb) — but via REFERENCE-DRIVEN emission, not a symbolic pre-pass
DONE, and far simpler/safer than the symbolic-resolution design below. Instead of replicating codegen's
symbol resolution, let CODEGEN ITSELF compute reachability: stable-partition so erased generic bodies
compile LAST (after every retained body → their call-site uses are final), then SKIP emitting any erased
body with `LLVMGetFirstUse == null` (declarations.zig, before the body loop). Skipping the body also skips
its destructor generation — THAT is what stops the string-parser calls (R1's DCE runs post-codegen, too
late). SAFE by construction: skipping a still-referenced body is an undefined-symbol LINK error (compile-
time), never runtime corruption — it never fired corpus-wide. The surviving set MATCHES the R1 DCE oracle
exactly. Measured: emitted erased method bodies 22→3, erased `_T/_K/_V` destructors 6→1; **isRefCountedType
calls 262796 → 244029 (−7%, ~19k fewer)** — the first real shrink of the string-parser surface. FUNC/SHADOW/
ARC 103/103, ASAN 81/81. The symbolic-pre-pass design below was NOT needed.

## Approach B (original symbolic-pre-pass design — superseded by the reference-driven form above)
To stop the string-parser calls, the dead erased bodies must not be EMITTED. Compute the reachable-erased set
BEFORE emission, symbolically (name-only, no IR, so no string-parser calls):
1. Worklist seeded with the roots' AST bodies.
2. For each body, walk its call expressions; resolve each call's TARGET SYMBOL using codegen's exact
   resolution (methodSymbol + `qualifySelfType` + `substTypeParams` for the receiver — the same logic at
   llvm_codegen.zig:1636-1667, and the constructor paths). Collect targets that resolve to an ERASED symbol.
3. Add newly-reached erased bodies to the worklist; transitively close.
4. In `instantiationsOf` / the emission loop, suppress an erased method body iff its symbol ∉ reachable set.
- **The Approach-A DCE output is the ORACLE:** the pre-pass's reachable-erased set MUST equal the set LLVM
  globalDCE keeps. Assert equality corpus-wide before trusting the pre-pass — a divergence is a
  resolution-logic mismatch (would be a link error if the pre-pass under-keeps).
- **Effort:** ~2–3d (the risk is faithfully replicating codegen's symbol resolution). **Gate:** pre-pass set
  == DCE set (corpus-wide); LINK OK (no undefined symbol); `f45_erased_fallback == 0`; full-corpus ASAN 0;
  measure the `isRefCountedType`/parser-call drop attributable to the un-emitted erased bodies.

## Dependencies for the FULL string-parser retirement (beyond this build)
- **F2-6 stage-5 completion** — every DESTRUCTOR built via TypeId (the string struct/tuple/storage builders
  unreachable), so `substituteFieldType`/`storageElem`/`getTupleElementType` have no caller. See
  `F2-6-stage5-release-site-migration.md` (Phase E) and `nova-f2-6-stage4-parked`.
- **Abstract-residue elimination** — fully monomorphize `base_needed` method bodies so no `List<U>` residue
  remains → then EVERY erased body is deletable and the erasure-rule `isRefCountedType("U")` calls vanish.
  This changes the method-monomorphization model (base bodies are erased BY DESIGN for inferred-arg calls),
  so it is its own effort, larger than this closure.

## Recommended order
R1 (Approach A, globalDCE) → measure + inspect the surviving abstract-residue set → R2 (Approach B pre-pass,
gated by the R1 oracle) → then the stage-5 + abstract-residue efforts for the full parser retirement. R1
alone is a safe, shippable code-size win and de-risks everything after it. See
[[nova-mono-completion-progress]] and `F4-monomorphization-completion.md`.
