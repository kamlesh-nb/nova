# Chained-map leak — corrected diagnosis & remaining findings (2026-07-19b)

**Supersedes the `F4-method-monomorphization.md` hypothesis.** The "chained-map leak"
(`xs.map(f).map(g)` leaks) was believed to be a generic-method-monomorphization / parametric-drop-glue
problem (arc.md §4: the erased `map` body's `mapped: U` never dropped). **That diagnosis was wrong.**

## What it actually was (FIXED — `63217a8`)
The dominant leak had nothing to do with generics or `map`. It reproduces with a plain, non-generic
function and no closure:

```nova
fn wrap(s: string): string { return `<${s}>`; }   // interpolates its PARAMETER
let arg = mk("x");
let r = wrap(arg);                                  // `arg` ("x!") leaked — 1 object
```

Root cause: `compileAppendToStringBuilder` retained a template interpolation part that is a bare
VARIABLE (`${s}` / `${obj.f}` / `${xs[i]}`) of owned type, with **no matching release**. But
`StringBuilder.append` COPIES the bytes and never stores the pointer, so the part is BORROWED — the
retain was a pure `+1` leak, once per interpolation. `xs.map(f).map(g)` hit it because map's closure
body interpolates its owned string argument (`(s) => `[${s}]``), leaking one element per call.

Fix: delete the retain (borrowed parts are not retained). Pinned by `conformance/cases/48`. Verified by
`--asan` that the retain was NOT masking a double-free. This closed the bulk of the "chained-map"
family: bound-intermediate map, direct-fn interpolation, closure-arg-in-loop, heap-string map — all
ARC-clean now.

## RESOLVED (2026-07-19c) — both remaining bugs fixed

Both bugs below were traced to CLOSURE TYPING, not the method-call machinery, and are now FIXED
(`06c6ee0` + `27e56e5`, pinned by `conformance/cases/49_closure_interpolation.nova`):

- **Chained intermediate box leak** — a closure with an un-pinnable param (`(x) => `v${x}``) was
  typed `.unresolved`, so the intermediate `List` box (and the closure box) were not owned locals and
  leaked. Fixed by typing a closure from its known RETURN even when a param is unresolved (`06c6ee0`).
- **Closure string-interpolation CRASH + leak** — a closure param's type comes from the CALL SITE; the
  resolver only handled `map(f)`, not `let g = <closure>; g(5)`, so `${x}` had no type and `append`
  derefed a scalar as a pointer (SIGSEGV). Fixed by resolving the param from the actual call-argument
  type + an interpolation type fallback (`27e56e5`). The 24-byte box + result leak went with it.

Residual (non-crash, rare): a string closure param whose call the resolver cannot find falls to the
machine-word default and mis-formats (prints the pointer) instead of crashing — memory-safe, and the
real fix is closure-param typing in sema (F2-6). The historical analysis below is kept for context.

## (historical) What remained before the closure-typing fix

### 1. Chained method-call intermediate box — `xs.map(f).map(g)` leaks 1 object / 24 bytes
`repro/chained_map_intermediate_box.nova`. After the template fix, the ONLY survivor is the 24-byte
intermediate `List` BOX from the first `map` (its elements ARE freed — only the outer struct leaks).
Narrowing:
- `xs.map(f).size()` and `xs.filter(f).size()` are CLEAN — a chained receiver whose second call
  returns a non-owned value IS drained correctly.
- `let a = xs.map(f); let ys = a.map(g)` (bind the intermediate) is CLEAN.
- Only `.map(g)`-as-the-second-call leaks the receiver box, and only when the outer result is itself
  owned-and-bound. So it is an interaction between the intermediate temp's statement-drain and the
  outer owned-call registration/spill — NOT a missing receiver registration (size() proves the
  registration works). Entry point: the method-call receiver compilation + the `pending_temps` drain
  ordering when an owned call's receiver is itself an owned call.

### 2. Closure returning a string, bound to a `let` — leak AND crash
`repro/closure_string_result_leak.nova`, `repro/closure_string_return_crash.nova`.
```nova
let f = (s) => `<${s}>`;  let arg = mk("x");  let r = f(arg);   // leaks the closure BOX (24B) + r
let g = (x) => `n${x}`;   let r2 = g(5);                        // CRASHES ("terminated abnormally")
```
- `let f = (x) => x + 1; let r = f(5)` (int result) is CLEAN — so the closure-box lifecycle works for
  non-string results.
- A string-RETURNING closure bound to a variable and then called leaks its box and result, and the
  crash variant (`g(5)` returning a template) aborts. This is a closure-ARC lifecycle bug specific to
  closures whose RETURN type is managed. PRE-EXISTING (independent of the template fix, whose retain
  was guarded by `isOwnedExpr(part)` and never fired for these int parts). Entry point:
  `buildClosureCall` (expressions.zig:131) + closure-box registration/drop + the closure body's
  string-return ABI.

## Status
The template-part leak (the primary mechanism) is FIXED and gated. The two remaining bugs are narrower,
localized, and have repros. The closure-string-return CRASH (#2) is the highest-severity open item in
this area — it is a correctness hole, not a leak.
