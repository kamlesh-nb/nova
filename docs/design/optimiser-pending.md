# Optimiser integration: pending work

Tracking table for the HIR/MIR/LIR emit path (`NOVA_OPT_EMIT`). Companion to `optimiser.md` (design +
landed history). The emit path is byte-faithful to the AST backend for everything it accepts, off by default,
with per-function AST fallback (an unhandled construct never breaks a build -- it falls back). As of
2026-08-15. Detail for each row lives in **§ Item detail** below, keyed by ID -- the table stays one line.

## Scoreboard

| Bucket | Count | IDs |
|---|---|---|
| DONE | 12 | A3, B1, B2, B3(f64), B4(ro), B8, C0, C2, C3, C8, D1, D2 |
| PARTIAL | 3 | B5 (read/construct/mutate), B6 (reference optionals), C5 (C-style `for`) |
| FALLBACK (safe, not yet emitted) | 8 | B7, C4, C6, C7, D3, D4, D5, D7 |
| TODO | 2 | C1 switch, D6 arc-elision (dormant until threaded) |
| DEFERRED (correctness / product) | 5 | A1, A2, E1, E3, E4 |

Legend: **DONE** emitted + gated · **PARTIAL** a subset emits, rest falls back · **FALLBACK** always AST today ·
**TODO** not started · **DEFERRED** blocked on sema, a product call, or destructive teardown. Priority P0 highest.

## Status table

### A. Correctness fixes
| ID | Item | Pri | Status |
|----|------|-----|--------|
| A1 | `0x80000000` hex-literal width in `== long` | P1 | DEFERRED (sema-rooted, latent) |
| A2 | Wider `long`-vs-`int` threading audit | P1 | DEFERRED (same root as A1) |
| A3 | `verify.zig` use-before-def check | P1 | DONE |

### B. Signatures (params / returns)
| ID | Item | Pri | Status |
|----|------|-----|--------|
| B1 | Methods / `self` params | P0 | DONE |
| B2 | String params / returns / locals | P1 | DONE |
| B3 | Float params / returns / locals | P2 | DONE (f64; f32/decimal fall back) |
| B4 | Array / pointer params | P2 | DONE (read-only, non-float) |
| B5 | Value-struct params / returns | P2 | PARTIAL (read + construct + mutate; returns fall back) |
| B6 | Optional (`T \| undefined`) params / returns | P2 | PARTIAL (reference optionals; value optionals fall back) |
| B7 | Error-union (`T \| E`) returns | P2 | FALLBACK |
| B8 | `>16` params | P3 | DONE (cap 32) |

### C. Body constructs
| ID | Item | Pri | Status |
|----|------|-----|--------|
| C0 | Method/builtin call NAME resolution (string receivers) | P1 | DONE (strings) |
| C1 | `switch_` / match lowering | P1 | TODO |
| C2 | `cast` (int<->int) | P2 | DONE (int<->int) |
| C3 | `index` (element access) | P2 | DONE (string byte + array word) |
| C4 | `optional_chain` / `nullish` | P2 | FALLBACK |
| C5 | `tuple`/`enum_init`/`template`/`range`; C-style `for` | P2 | PARTIAL (`for` done) |
| C6 | `closure` | P3 | FALLBACK |
| C7 | `try_` / errdefer | P2 | FALLBACK |
| C8 | String / float literals in the body | P1 | DONE (string) |

### D. ARC and async tier
| ID | Item | Pri | Status |
|----|------|-----|--------|
| D1 | Thread `retain`/`release` into HIR | P0 | DONE (in shadow) |
| D2 | Emit `retain`/`release` (strings) | P1 | DONE (strings) |
| D3 | Owned-field structs / aggregates | P2 | FALLBACK |
| D4 | Return a borrowed struct | P2 | FALLBACK |
| D5 | `await_` / `spawn_` / `indirect_call` | P2 | FALLBACK |
| D6 | Activate `arc_elision` pass | P1 | TODO (dormant) |
| D7 | Activate `inline` pass | P2 | BLOCKED (no whole-program MIR) |

### E. Meta / rollout
| ID | Item | Pri | Status |
|----|------|-----|--------|
| E1 | Default-on flip | P1 | DEFERRED (product decision) |
| E2 | Measure actual perf | P1 | INFORMATIONAL |
| E3 | Retire M0-M5 shadow | P3 | DEFERRED (destructive) |
| E4 | Windows / wasm emit validation | P3 | DEFERRED (off-default) |

## Critical path to a perf-positive optimiser

B1 (methods) → B2-B5 (real param/return types) → D1/D2 (ARC threading + emit) → E1 (default-on). Everything
else is correctness cleanup (A), long-tail constructs (C), or teardown (E). Each is a gated increment under
the same differential + corpus + ASAN discipline as the landed ones.

## Item detail

Design notes and the *why* behind each status. New entries are appended; a status flip updates its entry here.

**A1** — Only the HEX form `0x80000000` mis-types (decimal `2147483648` is fine). Sema types the hex literal
as `int` (INT_MIN, sign-extended) while a `== long` context wants `2147483648`. The fix belongs in sema (type
hex literals by value, or coerce in the compare), not a hacky emit workaround. No emittable function hits it,
so it does not regress the corpus.
**A2** — Same sema literal-typing weakness as A1; the mask-read-as-int case was already fixed (C0 verbatim
const). What remains is A1's hex-literal typing.
**A3** — 2026-08-15: program-order use-before-def check (the emit path's MIR flows values forward, so a valid
def precedes its use in block-major order; a never-defined value is flagged). `tryEmitInner` now rejects a
function on ANY verify violation → AST fallback. Would have caught the M6-C dangling load.

**B1** — 2026-08-15. `self` is an EXPLICIT `params[0]`, so AST params line up 1:1 with the LLVM args. The
method FunctionInfo sites just were not setting `.params = fn_decl.params` (constructors stay empty). Coverage
~1→13 emitted in a sha256 build; rejects ~99→6 (constructors). Pinned by `341_opt_emit_methods.nova`. Class
methods emit (heap `self`); value-struct methods and constructors fall back.
**B2** — 2026-08-15: string PARAMS (C0+D2, 334ccf5) and string RETURNS (e83f819) emit. Method calls named
`string_<m>`; string ARC (retain/release, null dtor) threaded + emitted; a returned borrowed string is
retained; a latent release-before-use ordering bug was fixed. String literals (C8) + byte index (C3) too.
Remaining string gaps: capture-into-field (needs D3) and f32/decimal.
**B3** — 2026-08-15 (be6c9ac): f64/double arithmetic emits (value is the double's bits in the i64 word;
bitcast to double, fadd/fsub/fmul/fdiv/fcmp, bitcast back). Float literal → const_int(bits); constfold
hardened never to fold a float binop. f32, decimal, mixed int/float, and float mod/shift/bitwise fall back.
**B4** — 2026-08-15 (238e8a8): a non-float array param flows as `ptr`, round-trips the i64 slot, index_get
resolves it. Array WRITE `a[i]=v` falls back (unmodelled lvalue → bad `store <i64 addr>`; mirEmittable now
requires a store target to be an `alloc`, which also caught a 260 regression). Float arrays fall back.
**B5** — read-only params + construction landed 2026-08-15 (aa84215). This session: field MUTATION emits too
— `s.f = v` on a value struct is `base + offset` + store, the identical address the AST writes, so it matches
whatever the aliasing semantics are (verified AST==EMIT, ASAN-clean; pinned by `350` `mutate()`). RETURNS
stay fallback: a value struct is its inline STACK bytes, so returning it returns a dead stack address
(use-after-return). Verified a naive allow "passes" only because the stack is not clobbered between return
and use (UB); needs a real by-value copy-out / sret ABI first.
**B6** — this session: REFERENCE optionals (`string|undefined`, class `T|undefined`) emit for read/compare.
They are a plain nullable pointer word (0 == absent), the AST does NOT box them, so the signature threads as
the payload pointer, `== undefined` is a bare `icmp eq/ne i64` (new `isRefWordEq` path, incl. the `ptr`-repr
word a passed-in optional is typed as), and a `string`-payload optional's ARC is a plain string's (null dtor).
Pinned by `351_opt_emit_ref_optional.nova`. A function that MATERIALISES `undefined`/`null` in its body still
falls back: `.undefined` lowers to `const_int 0`, exact for a reference optional but WRONG for a VALUE
optional, which boxes to a non-zero absent-sentinel. **Verified this session that admitting `.undefined`
MISCOMPILES `f(undefined)` for a value-optional param (AST=10 vs EMIT=134 + ASAN errors): the arg is passed
as 0, not the boxed sentinel.** So value optionals stay fallback. Full value-optional emit needs the AST's
present/absent boxing modelled node-by-node (the HIR gate is whole-function and cannot tell ref from value
per node) — higher risk (valopt-zero history).
**B7** — full emit needs the `(T|undefined)|E` boxing the AST return path does (statements.zig). Similar
complexity to value optionals.
**B8** — 2026-08-15 (0016f3c): cap raised 16→32 (ptbuf / resolveCallee ptypes / call argbuf).

**C0** — 2026-08-15 (334ccf5): `lower_ast_hir` rewrites a method call on a STRING receiver `s.m(a)` → named
call `string_m(s, a)`. Name owned by `hir.Func`. Needs `mir.type_store` set before AST→HIR. Non-string
receivers (generics, user structs) still nameless → a follow-up (general type-name mangling in the optimiser).
**C1** — rejected in both `hirEmittable` and `mirEmittable` (dense/sparse switch lowering not emitted).
**C2** — 2026-08-15 (5cb7ec1): allow `.cast`; mirEmittable gates operand AND result to int kinds (canonicalise
to result width). float<->int / pointer casts fall back.
**C3** — 2026-08-15 (7331294): new `index_get` MIR op. String indexes a byte (obj+idx, load i8, zext); array
GEPs the i64-word element. Float arrays + lists (method-call access) fall back. ~0 function-coverage gain on
its own (string bodies hit C8/C2 next).
**C4** — coupled to optional modelling (B6): `a?.b` / `a ?? b` need present/absent branching.
**C5** — 2026-08-15: C-style `for (init; cond; incr)` emits (desugared to a while; continue-bodies + iterator
`for x in` fall back). tuple / enum_init / template / bare range values remain fallback (aggregate/interp,
low value).
**C6** — capture environment not modelled.
**C7** — error-union control flow + errdefer not modelled.
**C8** — 2026-08-15 (5cb7ec1): new `const_str` MIR op via the immortal interned global (no ARC). With
C0/C3/D2 a whole string function BODY emits; the remaining gate on those functions is B-tier SIGNATURES. Float
literals fall back.

**D1** — `lower_ast_hir` ALREADY threads retain (owned-copy) + releases (scope-end / pre-return-except-moved /
pre-break) from `TypedIr.ownedOf`; the emit path supplies `typed_ir`. The ops exist; the emit path just gates
them. Remaining work is D2 (emit) + C0.
**D2** — 2026-08-15 (334ccf5): emit `nova_retain` / `nova_release(ptr, null)` for string operands (no dtor);
owned-local TypeIds threaded so mirEmittable gates ARC ops to strings. ARC-balanced vs the AST baseline (--arc
0 failures). Non-string owned types reject → D3.
**D3** — needs per-type `__destruct_*` dtor threading for the field releases.
**D4** — the string-return retain infra extends here, but needs the class-vs-value-struct distinction in
lower_ast_hir; deferred (low value).
**D5** — async is compiled as an LLVM coroutine (rejected up front); trait dynamic dispatch (indirect_call)
also unmodelled.
**D6** — `arc_elision` is implemented + unit-tested but dormant; this is the actual perf win, activate once
ARC threading is broadly trusted.
**D7** — the emit path lowers ONE function at a time, so there is no MIR callee map to inline from. Needs
whole-program MIR (a larger restructuring). Implemented + unit-tested; stays dormant.

**E1** — premature: coverage is still partial so it buys ~0 perf, and it changes EVERY build. A deliberate
call once B+D coverage is high. Not flipped autonomously.
**E2** — with the subset still small, emit buys near-zero end-to-end speed; the win needs the hard B/D tier +
elision on hot functions. Re-measure after those.
**E3** — the `NOVA_OPT` report-only path can go once emit is broadly trusted; removing it now loses the
coverage gauge. Not done autonomously.
**E4** — the emit path is off by default, so it does not affect Windows/wasm builds today. Validation belongs
with the E1 flip.
