# Optimiser integration: pending work

Tracking table for the HIR/MIR/LIR emit path (`NOVA_OPT_EMIT`). Companion to `optimiser.md` (design +
landed history). The emit path is byte-faithful to the AST backend for everything it accepts, off by default,
with per-function AST fallback (an unhandled construct never breaks a build -- it falls back). As of
2026-08-15. Detail for each row lives in **§ Item detail** below, keyed by ID -- the table stays one line.

## Scoreboard

| Bucket | Count | IDs |
|---|---|---|
| DONE | 16 | A3, B1, B2, B3(f64), B4(ro), B8, C0, C1, C2, C3, C8, D1, D2, D3(string-field), D4 |
| PARTIAL | 3 | B5 (read/construct/mutate/return), B6 (reference optionals), C5 (C-style `for`) |
| FALLBACK (safe, not yet emitted) | 5 | B7, C4, C6, C7, D7 |
| TODO | 1 | D6 arc-elision (dormant until threaded) |
| DEFERRED (correctness / product / async) | 6 | A1, A2, D5, E1, E3, E4 |

Parallel-agent session (2026-08-15, four isolated worktrees, each gated to prove byte-identical + ASAN-clean
or fall back): **C1** switch was already emitting for int/long (doc was stale) → DONE + case 347 enriched.
**D3** string-owned-field struct destructors now emit (real `__destruct_*` for heap / `dropValueStruct` for
value structs) → DONE, case 352. **D4** return-of-a-borrowed heap struct now emits with the return-retain
threaded, ARC-balanced → DONE, case 353. **B5** returns need NO sret ABI — escape analysis heap-promotes any
construct-and-returned struct, so the existing fresh-construction heap-return path already emits it (verified
ASAN-clean incl. an intervening-call test) → B5 now read/construct/mutate/**return**, case 350 extended.

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
| B5 | Value-struct params / returns | P2 | PARTIAL (read + construct + mutate + return; string-field via D3) |
| B6 | Optional (`T \| undefined`) params / returns | P2 | PARTIAL (reference optionals; value optionals fall back) |
| B7 | Error-union (`T \| E`) returns | P2 | FALLBACK |
| B8 | `>16` params | P3 | DONE (cap 32) |

### C. Body constructs
| ID | Item | Pri | Status |
|----|------|-----|--------|
| C0 | Method/builtin call NAME resolution (string receivers) | P1 | DONE (strings) |
| C1 | `switch_` / match lowering | P1 | DONE (int/long) |
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
| D3 | Owned-field structs / aggregates | P2 | DONE (string fields) |
| D4 | Return a borrowed struct | P2 | DONE (heap/class) |
| D5 | `await_` / `spawn_` / `indirect_call` | P2 | DEFERRED (async coroutine + trait dispatch) |
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
**B5** — read-only params + construction landed 2026-08-15 (aa84215). Field MUTATION emits too — `s.f = v`
on a value struct is `base + offset` + store, the identical address the AST writes (verified AST==EMIT,
ASAN-clean; pinned by `350` `mutate()`). RETURNS also emit, and need NO sret ABI: this backend has no
by-value copy-out — whole-program escape analysis (`computeValueEscapeSet`, honoured by `isValueStructName`)
HEAP-PROMOTES any struct that is constructed-and-returned, so a returned struct is a reference-counted heap
struct (`nova_bytes_alloc` + return the payload pointer), NOT a dead stack address. The existing fresh-
construction heap-return path already emits it, byte-identical to the AST and ASAN-clean even with an
intervening call between the return and the field read (`NOVA_ASAN_CODEGEN` verified). Pinned by `350`
`mkVec`/`mkVec3`. (My earlier "value-struct return = use-after-return, needs sret" note was WRONG for this
codebase: escape analysis prevents the stack case entirely. This is the exact kind of ABI fact that belongs
in a written representation spec, per the design-debt note.) The one shape still on the AST: a returned heap-
struct BORROW (`return p`) — that is D4, now DONE.
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
**C1** — DONE for int/long discriminants (verified 2026-08-15, not assumed). `lower_ast_hir.lowerSwitch`
desugars a switch to an if-chain BEFORE MIR: it binds the discriminant once to a typed temp, and each case
becomes an OR of side-effect-free `disc == vK` eq compares (stamped with the discriminant TypeId), so the
`.switch_` MIR terminator is never produced and the reject for it is a dormant safety net. `NOVA_OPT_EMIT_
VERBOSE` confirms switch functions land in "emitted fn", not "reject"; exit + checksum identical to the AST,
ASAN-clean, across multi-value cases, default, no-default fall-through, negative long labels, expression
discriminant, and nested switch (case 347). Enum switch falls back only because enums aren't in the emit
subset yet (the enum if-chain also falls back); string switch is rejected language-wide by the type checker;
a guarded case (`case v if cond`) intentionally falls back.
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
**D3** — DONE for STRING-owned-field structs (2026-08-15). A `struct` with only bare-`string` owned fields,
constructed from `const_str` literal values, now emits: construction moves the immortal literal in (no retain
needed), and the release resolves the struct's REAL destructor — heap/class via `compileRelease(v, getOr
CreateDestructorPreferId(name, tid))` (real `__destruct_<Struct>`), value struct via `dropValueStruct(v,
name, tid)` (direct destructor call on the inline-storage address, no free), selected at `.release` by the
value's type. Key finding: plain `struct` is a VALUE struct in this build, so a string-field struct is
usually dropped via `dropValueStruct`, not `nova_release`. Verified byte-identical + ASAN-clean incl. a 1000-
iteration construct/drop loop (case 352). Non-literal string args, returned string fields, and any non-string
owned field (class/list/nested-struct/error-union) still fall back.
**D4** — DONE for heap/class structs (2026-08-15). A returned BORROWED heap struct (a param, not a fresh
`struct_new` and not a moved owned local) now emits: `lower_ast_hir` threads a return-acquisition `nova_retain`
(the caller owns the matching release), the `.retain` gate admits a heap-struct pointer word (a refcount bump
needs no dtor), and the `.ret` gate admits a retained result (`isRetainedResult`) alongside the fresh
`struct_new` case. Verified byte-identical + ASAN-clean + ARC-audit-clean incl. a 1000-iteration loop (case
353). The `.release` gate stays string/string-field-struct-only, so a function with a releasable heap-struct
LOCAL still falls back (that needs general class-dtor threading, out of D4 scope).
**D5** — DEFERRED. Async is compiled as an LLVM coroutine (presplitcoroutine → CoroSplit), rejected up front
(`func.is_async`); `spawn`/`await`/`indirect_call` (trait dynamic dispatch) are unmodelled. These are the
deepest remaining subsystems — each is a multi-day slice with real miscompile risk, so they stay on the AST
until designed properly.
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
