# Optimiser integration: pending work

Tracking table for everything still to implement or fix in the HIR/MIR/LIR optimiser integration.
Companion to `optimiser.md` (design + landed history). As of 2026-08-15.

## Where we are

The emit path (`NOVA_OPT_EMIT`) is byte-faithful to the AST backend for everything it accepts, off by default
with per-function AST fallback (so an unhandled construct never breaks a build -- it just falls back). Only
the off-Linux `189_epoll_event_layout` fails the gates.

**Session 2026-08-15 landed:** genuine emit 272/348 -> green; then the coverage subset grew a lot -- B1
methods, B3 f64 float, B4 read-only array params, B8 (>32 params); C0 string method-call naming, C1 switch,
C2 int casts, C3 index, C8 string literals; D2 string ARC, D6 arc-elision (already active); string RETURNS +
a latent ARC release-ordering use-after-free fix; and C-style `for` loops. A whole string function body
(literals, casts, index, method calls, ARC) and int/float/array-read functions now emit.

**What is left, honestly.** The emit subset is grown by *safe fallback*: anything not yet emittable is
compiled by the AST path, so the remaining items are coverage opportunities, not bugs. They split into:
- **Hard (safe fallback today; each needs multi-hour careful work + an ABI/encoding decision):** B5 value-struct
  by-value ABI, B6 optional-(`T|undefined`)-return boxing, B7 error-union-return boxing, C6 closures, C7 try/
  errdefer, D3 owned-field-struct dtor threading, D4 return-borrowed-struct retain, D5 async/await/spawn/trait
  dispatch. These stay as AST fallback until done -- correctness is preserved, coverage is not grown.
- **Correctness (latent, does not regress the corpus):** A1 hex `0x80000000` in `== long` (sema types the hex
  literal as int; a proper fix is in sema or a coverage-costing gate) and A2 (the same long-vs-int class).
- **Meta / product decisions (should not be executed autonomously):** E1 default-on flip (premature -- ~0 perf
  until coverage is high, and it changes every build), E3 retire the shadow (destructive), E4 windows/wasm
  validation. E2 (measure perf) is informational.

Status legend: TODO (not started), WIP (in progress), DONE, FALLBACK (safe AST fallback; full emit pending).
Priority: P0 highest.

## A. Correctness fixes (bugs inside the current subset)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| A1 | `0x80000000` long-literal width bug | P1 | DEFERRED (sema-rooted, latent) | Reproduced: only the HEX form `0x80000000` (decimal `2147483648` is fine). Sema types the hex literal as `int` (= INT_MIN, sign-extended) while a `== long` context wants `2147483648`. Fix belongs in sema (type hex literals by value / coerce in the compare) or a coverage-costing gate; NOT regressing the corpus (no emittable fn hits it). Not fixed with a hacky emit workaround. |
| A2 | Audit the wider `long`-vs-`int` threading class | P1 | DEFERRED (same root as A1) | Same sema literal-typing weakness; the mask-read-as-int case was already fixed (C0 verbatim const). Remaining is A1's hex-literal typing. |
| A3 | `verify.zig` use-before-def gap | P1 | DONE | 2026-08-15: added a program-order use-before-def check to verify.zig (the emit path's MIR flows values forward, so a valid def precedes its use in block-major order; a never-defined value is flagged). tryEmitInner now REJECTS a function on ANY verify violation (defence in depth) -> AST fallback. Would have caught the M6-C dangling load. |

## B. Coverage: signatures (params and returns)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| B1 | Methods / `self` params | P0 | DONE | 2026-08-15. `self` is an EXPLICIT params[0] (`fn m(self: T, ...)`), so AST params line up 1:1 with the LLVM args and no shift was needed. The method FunctionInfo sites just were not setting `.params = fn_decl.params` (constructors stay empty, self is synthetic there). Coverage jumped ~1->13 emitted in a sha256 build; the reject dropped from ~99 to ~6 (constructors). Pinned by `341_opt_emit_methods.nova`. Gates: emit 349/350. Class methods emit (heap `self`); value-struct methods and constructors fall back. |
| B2 | String params / returns / locals | P1 | DONE | 2026-08-15: string PARAMS (C0+D2, commit 334ccf5) and string RETURNS (commit e83f819) emit. Method calls are named `string_<m>`, string ARC (retain/release, null dtor) is threaded + emitted, a returned borrowed string is retained, and a latent release-before-use ordering bug was fixed. String literals (C8) + byte index (C3) too. Remaining string gaps are capture-into-field (needs struct dtor = D3) and f32/decimal. The old 'BLOCKED on D1' note below is superseded (D1 was already threaded in the shadow).
| B3 | Float params / returns / locals | P2 | DONE (f64) | 2026-08-15 (commit be6c9ac): f64/double arithmetic emits -- value is the double's bits in the i64 word; bitcast to double, fadd/fsub/fmul/fdiv/fcmp, bitcast back. Float literal -> const_int(bits); constfold hardened to never fold a float binop (bits are not an int). f32, decimal, mixed int/float, and float mod/shift/bitwise fall back. |
| B4 | Array / pointer params (read-only) | P2 | DONE (read-only, non-float) | 2026-08-15 (commit 238e8a8): accept a non-float array param (flows as `ptr`, round-trips the i64 slot; index_get resolves it). Array WRITE `a[i]=v` still falls back -- its lvalue is unmodelled and lowered to a bad `store <i64 addr>`; mirEmittable now requires a store target to be an `alloc` (general hardening, caught a 260 regression). Float arrays fall back. |
| B5 | Value-struct params / returns | P2 | PARTIAL (read+construct) | 2026-08-15 (commit aa84215): value-struct READ-only params + CONSTRUCTION emit (flows as inline-bytes address; struct_new uses buildValueStructStorage; escapes gated off). Remaining: field WRITE / mutation (value-semantics through a param aliases the caller -> needs copy-on-pass), and value-struct RETURNS (stack address -> needs by-value copy-out ABI). |

**B-group finding (2026-08-15):** the dominant lever (B2 strings) is ARC-blocked; B3/B4/B5 are sound but
low-value. So the productive next step is **D1 (thread ARC into HIR/MIR)**, which unblocks strings *and*
activates arc-elision (the perf win). Re-sequenced: D1 before the rest of B.

**B-group status (2026-08-15, after the C-tier bundle):** B1 (methods) and B4 (read-only array params) are
DONE and clean. The REMAINING B items are each a substantial/delicate piece, NOT a quick finish -- they are
the binding constraint on stdlib coverage now, but each needs careful individual work:
- **String returns** (part of B2): the AST path RETAINS a returned borrowed string (`nova_retain` before
  `ret`); lower_ast_hir does not thread that acquisition retain. Needs an ARC-placement fix (retain a
  returned owned-typed value that is not a moved owned local). Memory-correctness-sensitive.
- **B3 float**: self-contained + sound (no ARC/encoding) but sizable -- needs float binops (fadd/fmul/fdiv/
  fcmp), float const, and i64<->double bitcasts at every op boundary. The emit path currently rejects all
  float (intKindForTid is int-only).
- **B5 value-struct params/returns**: by-value ABI (inline bytes, possibly >8 bytes) + inline field access.
- **B6 optional (`T|undefined`) returns**: the AST return path does non-trivial value-optional boxing (see
  statements.zig return_stmt); known subtle bugs historically (value-optional-zero). Higher risk.
- **B7 error-union (`T|E`) returns**: similar boxing complexity to B6.
- **B8 >16 params**: trivial but low value; deferred.
| B6 | Optional (`T \| undefined`) params / returns | P2 | FALLBACK | Safe AST fallback (rejected at the type-ref level). Full emit needs the value-optional boxing the AST does (present/absent encoding; historically buggy -- valopt-zero). |
| B7 | Error-union (`T \| E`) returns | P2 | FALLBACK | Safe AST fallback. Full emit needs the `(T\|undefined)\|E` boxing the AST return path does (see statements.zig). |
| B8 | `>16` params | P3 | DONE | 2026-08-15 (commit 0016f3c): cap raised 16 -> 32 (ptbuf / resolveCallee ptypes / call argbuf). |

## C. Coverage: body constructs (rejected HIR nodes / MIR ops)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| C1 | `switch_` / match lowering | P1 | TODO | Rejected in both `hirEmittable` and `mirEmittable` (dense/sparse lowering not emitted). |
| C2 | `cast` (int<->int) | P2 | DONE (int<->int) | 2026-08-15 (commit 5cb7ec1): allow `.cast`; mirEmittable gates operand AND result to int kinds (canonicalise to result width). float<->int / pointer casts still fall back. |
| C3 | `index` (array / list element access) | P2 | DONE (string byte + array word) | 2026-08-15 (commit 7331294): new `index_get` MIR op. String indexes a byte (obj+idx, load i8, zext); array GEPs the i64-word element. Float arrays + lists (method-call access) fall back. String byte index emits now; array-index functions need array params (B4) so the array path is latent. NB: eliminated `index` rejects but ~0 function-coverage gain -- string bodies hit C8 (str literals) / C2 (casts) next. |
| C4 | `optional_chain` / `nullish` | P2 | FALLBACK | Safe AST fallback. Coupled to optional modelling (B6): `a?.b` / `a ?? b` need present/absent branching. |
| C5 | `tuple`, `enum_init`, `template`, `range`; C-style `for` | P2 | PARTIAL (for done) | 2026-08-15: C-style `for (init; cond; incr)` now emits (desugared to a while; continue-bodies + iterator `for x in` fall back). tuple / enum_init / template (string interp) / bare range values remain safe AST fallback (aggregate/interp forms, low value). |
| C6 | `closure` | P3 | FALLBACK | Safe AST fallback. Capture environment not modelled. |
| C7 | `try_` (error handling / errdefer) | P2 | FALLBACK | Safe AST fallback. Error-union control flow + errdefer not modelled. |
| C8 | String / float literals in the body | P1 | DONE (string) | 2026-08-15 (commit 5cb7ec1): new `const_str` MIR op materialised via the immortal interned global (`getOrCreateStringLiteral`, no ARC). Float literals still fall back (need float handling). With C0/C3/D2 a whole string function body now emits (str/cast/index rejects -> 0 on the stdlib string files). Remaining gate on those functions is B-tier SIGNATURES (optional/string returns, array/value-struct params). |

## D. ARC and async tier (the performance payoff)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| C0 | Method / builtin call NAME resolution (string receivers) | P1 | DONE (strings) | 2026-08-15 (commit 334ccf5): `lower_ast_hir` rewrites a method call on a STRING receiver `s.m(a)` -> named call `string_m(s, a)` (receiver prepended). Name owned by `hir.Func`. Needs `mir.type_store` set before AST->HIR (moved earlier). Non-string receivers (generics, user structs) still nameless -> a follow-up (needs general type-name mangling in the optimiser). |
| D1 | Thread explicit `retain`/`release` into HIR | P0 | ALREADY DONE (in shadow) | `lower_ast_hir` ALREADY threads retain (owned-copy) + releases (scope-end / pre-return-except-moved / pre-break) from `TypedIr.ownedOf`, and the emit path already supplies `typed_ir`. So the ops exist; the emit path just rejects them. The remaining work is D2 (emit them) + the C0 prerequisite below. |
| D2 | Emit `retain`/`release` in the emit path (strings) | P1 | DONE (strings) | 2026-08-15 (commit 334ccf5, with C0): emit `nova_retain` / `nova_release(ptr, null)` for string operands (a string needs no dtor); owned-local TypeIds threaded so mirEmittable gates ARC ops to strings. ARC-balanced vs the AST baseline (--arc 0 failures). Non-string owned types (structs/lists/error-unions) still reject -> D3 (real `__destruct_*` resolution). |
| D3 | Owned-field structs / aggregates | P2 | FALLBACK | Safe AST fallback. Needs per-type `__destruct_*` dtor threading for the field releases. |
| D4 | Return a borrowed struct | P2 | FALLBACK | Safe AST fallback. The string-return retain infra (this session) extends here, but needs the class-vs-value-struct (reference) distinction in lower_ast_hir; deferred (low value). |
| D5 | `await_` / `spawn_` / `indirect_call` | P2 | FALLBACK | Safe AST fallback. Async is compiled as an LLVM coroutine (rejected up front); trait dynamic dispatch (indirect_call) also unmodelled. |
| D6 | Activate `arc_elision` pass | P1 | TODO | Implemented and unit-tested but DORMANT until D1. This is the actual perf win. |
| D7 | Activate `inline` pass | P2 | BLOCKED (no whole-program MIR) | The emit path lowers ONE function at a time, so there is no MIR callee map to inline from. Needs whole-program MIR (a larger restructuring). Implemented + unit-tested; stays dormant. |

## E. Meta-integration and rollout

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| E1 | Default-on flip (hybrid emit + fallback) | P1 | DEFERRED (product decision) | Premature: coverage is still partial so it buys ~0 perf, and it changes EVERY build. Should be a deliberate call once B+D coverage is high. Not flipped autonomously. |
| E2 | Realise and measure actual perf | P1 | INFORMATIONAL | With the subset still small, emit buys near-zero end-to-end speed; the win needs the hard B/D tier + elision on hot functions. Re-measure after those. |
| E3 | Retire the M0-M5 shadow scaffolding | P3 | DEFERRED (destructive) | The `NOVA_OPT` report-only path can go once emit is broadly trusted; removing it now would lose the coverage gauge. Not done autonomously. |
| E4 | Windows / wasm emit validation | P3 | DEFERRED (off-default) | The emit path is off by default, so it does not affect Windows/wasm builds today. Validation belongs with the E1 flip. |

## Critical path to a perf-positive optimiser

**B1 (methods)** then **B2 to B5 (real-world param/return types)** then **D1 and D2 (ARC threading plus emit)**
then **E1 (default-on)**. Everything else is a correctness cleanup (A), a long-tail construct (C), or
teardown (E). Each is a gated increment with the same differential plus corpus plus ASAN discipline as the
increments already landed (see `optimiser.md`).
