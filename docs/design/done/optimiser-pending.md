# Optimiser integration: pending work

Tracking table for the HIR/MIR/LIR emit path (`KYTE_OPT_EMIT`). Companion to `optimiser.md` (design +
landed history). The emit path is byte-faithful to the AST backend for everything it accepts, off by default,
with per-function AST fallback (an unhandled construct never breaks a build -- it falls back). As of
2026-08-15. Detail for each row lives in **§ Item detail** below, keyed by ID -- the table stays one line.

## Scoreboard

| Bucket | Count | IDs |
|---|---|---|
| DONE | 19 | A3, B1, B2, B3, B4(ro), B8, C0, C1, C2, C3, C5(enum/tuple/template), C8, D1, D2, D3(string-field), D4, D5(sync trait) |
| PARTIAL | 3 | B5 (read/construct/mutate/return; string-field), B6 (reference optionals + nullish; value optionals gated-fallback), C4 (nullish done; optional-chain falls back) |
| FALLBACK (safe, documented ABI) | 4 | B7 (error-union box), C6 (closures), C7 (try/errdefer), D7 (inline) |
| WIRED | 1 | D6 arc-elision (in pipeline, proven no-op on current subset) |
| DEFERRED (deep / product) | 6 | A1/A2 (emit-path literal only, not shipping), D5-async, E1, E3, E4 |

Two parallel-agent sessions (2026-08-15, ~10 isolated worktrees, each gated to prove byte-identical +
ASAN-clean or fall back). Wave 1: C1 switch (already emitting int/long; doc was stale), D3 string-owned-field
struct destructors, D4 return-borrowed heap struct, B5 value-struct returns (no sret needed — escape analysis
heap-promotes). Wave 2: **C5** payloadless enums (+ enum switch for free) + scalar tuples + all-string
templates, **C4** `a ?? b` nullish for reference optionals, **D5** SYNCHRONOUS trait dynamic dispatch
(fat-pointer + vtable), **B3** f32 (promoted-to-double ABI). FALLBACK-with-documented-ABI: B7 error-union
box, C6 closures, C7 try/errdefer. **Three latent miscompiles in `791c696` were found and closed by the
reverse-engineering:** B6 value-optional caller (a scalar-signature caller passed the raw word to a
value-optional param — present-0 read as absent), D5 trait construct-and-pass (raw struct pointer instead of
a fat pointer → BUS), and B7's fragile heap-struct-tid gate (now rejects at the `error_union` type-ref shape).
New MIR ops: `tuple_new`, `indirect_call`, `template`. Cases 354-362 pin the new coverage.

Legend: **DONE** emitted + gated · **PARTIAL** a subset emits, rest falls back · **FALLBACK** always AST today ·
**TODO** not started · **DEFERRED** blocked on sema, a product call, or destructive teardown. Priority P0 highest.

## Status table

### A. Correctness fixes
| ID | Item | Pri | Status |
|----|------|-----|--------|
| A1 | `0x80000000` hex-literal width in `== long` | P1 | NOT-A-BUG on shipping backend (emit-path literal only) |
| A2 | Wider `long`-vs-`int` threading audit | P1 | N/A on shipping backend (see A1) |
| A3 | `verify.zig` use-before-def check | P1 | DONE |

### B. Signatures (params / returns)
| ID | Item | Pri | Status |
|----|------|-----|--------|
| B1 | Methods / `self` params | P0 | DONE |
| B2 | String params / returns / locals | P1 | DONE |
| B3 | Float params / returns / locals | P2 | DONE (f32 + f64; decimal falls back) |
| B4 | Array / pointer params | P2 | DONE (read-only, non-float) |
| B5 | Value-struct params / returns | P2 | PARTIAL (read + construct + mutate + return; string-field via D3) |
| B6 | Optional (`T \| undefined`) params / returns | P2 | PARTIAL (reference optionals + nullish; value optionals gated-fallback) |
| B7 | Error-union (`T \| E`) returns | P2 | FALLBACK (box ABI documented + gate hardened) |
| B8 | `>16` params | P3 | DONE (cap 32) |

### C. Body constructs
| ID | Item | Pri | Status |
|----|------|-----|--------|
| C0 | Method/builtin call NAME resolution (string receivers) | P1 | DONE (strings) |
| C1 | `switch_` / match lowering | P1 | DONE (int/long) |
| C2 | `cast` (int<->int) | P2 | DONE (int<->int) |
| C3 | `index` (element access) | P2 | DONE (string byte + array word) |
| C4 | `optional_chain` / `nullish` | P2 | PARTIAL (nullish for ref optionals; optional-chain falls back) |
| C5 | `tuple`/`enum_init`/`template`/`range`; C-style `for` | P2 | PARTIAL (`for`, payloadless enum, scalar tuple, all-string template) |
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
| D5 | `await_` / `spawn_` / `indirect_call` | P2 | PARTIAL (sync trait dispatch DONE; async deferred) |
| D6 | Activate `arc_elision` pass | P1 | WIRED (in pipeline, no-op on current subset) |
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

**A1** — CORRECTED (this session): NOT a bug on the shipping (AST) backend. The parser reads a radix literal
as `u64`→`i64` (full value `2147483648`) and codegen materializes every integer literal at full i64 width, so
`0x80000000 == long` succeeds; verified across `0xFFFFFFFF`, `0x100000000`, 40-bit forms. Regression-guard
case `357_hex_literal_long`. The earlier "sema-rooted / typed as int" note was WRONG. The only place a hex
literal could still mistype is the emit path's SEPARATE literal-typing (via the threaded TypeId) — latent, no
emittable corpus function hits it.
**A2** — N/A on the shipping backend (see A1). The mask-read-as-int case was already fixed (C0 verbatim const).
**A3** — 2026-08-15: program-order use-before-def check (the emit path's MIR flows values forward, so a valid
def precedes its use in block-major order; a never-defined value is flagged). `tryEmitInner` now rejects a
function on ANY verify violation → AST fallback. Would have caught the M6-C dangling load.

**B1** — 2026-08-15. `self` is an EXPLICIT `params[0]`, so AST params line up 1:1 with the LLVM args. The
method FunctionInfo sites just were not setting `.params = fn_decl.params` (constructors stay empty). Coverage
~1→13 emitted in a sha256 build; rejects ~99→6 (constructors). Pinned by `341_opt_emit_methods.ky`. Class
methods emit (heap `self`); value-struct methods and constructors fall back.
**B2** — 2026-08-15: string PARAMS (C0+D2, 334ccf5) and string RETURNS (e83f819) emit. Method calls named
`string_<m>`; string ARC (retain/release, null dtor) threaded + emitted; a returned borrowed string is
retained; a latent release-before-use ordering bug was fixed. String literals (C8) + byte index (C3) too.
Remaining string gaps: capture-into-field (needs D3) and f32/decimal.
**B3** — 2026-08-15 (be6c9ac): f64/double arithmetic emits (value is the double's bits in the i64 word;
bitcast to double, fadd/fsub/fmul/fdiv/fcmp, bitcast back). Float literal → const_int(bits); constfold
hardened never to fold a float binop. **f32 too (this session, 7d42c29):** reverse-engineering found this
backend PROMOTES f32 to double everywhere in scalar code (an f32 local gets a Double slot, values are FPExt'd,
the word carries the double's 64-bit pattern) — so f32 uses the IDENTICAL double bitcast as f64 (using a
32-bit LLVMFloatType bitcast would reinterpret garbage). Added `isFloatWordTid` (f32||f64) across the param/
return/binop gates. Decimal, f32 struct fields / arrays, and float mod/shift/bitwise still fall back.
**B4** — 2026-08-15 (238e8a8): a non-float array param flows as `ptr`, round-trips the i64 slot, index_get
resolves it. Array WRITE `a[i]=v` falls back (unmodelled lvalue → bad `store <i64 addr>`; mirEmittable now
requires a store target to be an `alloc`, which also caught a 260 regression). Float arrays fall back.
**B5** — read-only params + construction landed 2026-08-15 (aa84215). Field MUTATION emits too — `s.f = v`
on a value struct is `base + offset` + store, the identical address the AST writes (verified AST==EMIT,
ASAN-clean; pinned by `350` `mutate()`). RETURNS also emit, and need NO sret ABI: this backend has no
by-value copy-out — whole-program escape analysis (`computeValueEscapeSet`, honoured by `isValueStructName`)
HEAP-PROMOTES any struct that is constructed-and-returned, so a returned struct is a reference-counted heap
struct (`kyte_bytes_alloc` + return the payload pointer), NOT a dead stack address. The existing fresh-
construction heap-return path already emits it, byte-identical to the AST and ASAN-clean even with an
intervening call between the return and the field read (`KYTE_ASAN_CODEGEN` verified). Pinned by `350`
`mkVec`/`mkVec3`. (My earlier "value-struct return = use-after-return, needs sret" note was WRONG for this
codebase: escape analysis prevents the stack case entirely. This is the exact kind of ABI fact that belongs
in a written representation spec, per the design-debt note.) The one shape still on the AST: a returned heap-
struct BORROW (`return p`) — that is D4, now DONE.
**B6** — this session: REFERENCE optionals (`string|undefined`, class `T|undefined`) emit for read/compare.
They are a plain nullable pointer word (0 == absent), the AST does NOT box them, so the signature threads as
the payload pointer, `== undefined` is a bare `icmp eq/ne i64` (new `isRefWordEq` path, incl. the `ptr`-repr
word a passed-in optional is typed as), and a `string`-payload optional's ARC is a plain string's (null dtor).
Pinned by `351_opt_emit_ref_optional.ky`. A function that MATERIALISES `undefined`/`null` in its body still
falls back: `.undefined` lowers to `const_int 0`, exact for a reference optional but WRONG for a VALUE
optional, which boxes to a non-zero absent-sentinel. **Verified this session that admitting `.undefined`
MISCOMPILES `f(undefined)` for a value-optional param (AST=10 vs EMIT=134 + ASAN errors): the arg is passed
as 0, not the boxed sentinel.** So value optionals stay fallback. **VALUE-OPTIONAL BOX ABI (reverse-engineered
this session):** a value optional is a nullable pointer to an 8-byte ARC box — `kyte_valopt_box(word)` =
`kyte_bytes_alloc(8)` storing the raw i64 word; unbox = `box==0 ? 0 : *box`; absent = the NULL word `0`;
a present value (even `0`) is a NON-null box (that is why boxing exists). The AST boxes on every store into a
value-optional slot (arg into a valopt param, let/assign, valopt return) and unboxes on every payload read.
**A second latent miscompile was found + closed (591153e):** the whole-function gate rejected a value-optional
SIGNATURE, but an emittable scalar-signature CALLER could still call a value-optional-param function and pass
the raw word — proven live: `f(0)` gave AST=222 vs EMIT=111 (present-0 read as absent), `f(5)` gave AST=6 vs
EMIT=134 + ASAN. Fixed with two `mirInstEmittable` guards: reject any instruction producing a value optional,
and reject any call whose callee declares a value-optional param. Case `359`. Faithful *emit* (node-by-node
box/unbox) remains the deferred slice.
**B7** — FALLBACK, gate hardened (7417725). **ERROR-UNION BOX ABI (reverse-engineered):** `T | E` is a tagged
16-byte ARC heap box — `tag@0` (0=ok, 1=err), `payload@8` (the ok or err value in the i64 slot), owned payload
retained into the box, released by tag in `__destruct_ErrUnion_*`. The ok arm is itself value-optional-boxed
(`(T|undefined)|E`), so a plain `return 42` is TWO nested heap boxes. The error path runs `runErrdefers()`
before the box is built. Emit needs a heap-box-alloc-with-tag op + nested valopt boxing + errdefer + the
try/catch unbox control-flow (C7) — none in MIR yet. The gate now rejects at the `error_union` type-ref shape
(the box IS a heap object, so relying on `emittableHeapStructTid` failing was fragile). Case `356`.
**B8** — 2026-08-15 (0016f3c): cap raised 16→32 (ptbuf / resolveCallee ptypes / call argbuf).

**C0** — 2026-08-15 (334ccf5): `lower_ast_hir` rewrites a method call on a STRING receiver `s.m(a)` → named
call `string_m(s, a)`. Name owned by `hir.Func`. Needs `mir.type_store` set before AST→HIR. Non-string
receivers (generics, user structs) still nameless → a follow-up (general type-name mangling in the optimiser).
**C1** — DONE for int/long discriminants (verified 2026-08-15, not assumed). `lower_ast_hir.lowerSwitch`
desugars a switch to an if-chain BEFORE MIR: it binds the discriminant once to a typed temp, and each case
becomes an OR of side-effect-free `disc == vK` eq compares (stamped with the discriminant TypeId), so the
`.switch_` MIR terminator is never produced and the reject for it is a dormant safety net. `KYTE_OPT_EMIT_
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
**C4** — PARTIAL (8bb73be). `a ?? b` NULLISH now emits for a REFERENCE optional `a`: lowered to a present-check
branch on the pointer word (`a != 0 ? a : b`), a `condbr` on `icmp ne i64 a, 0`. Value-optional nullish falls
back (the synthesized `a != null` isn't a reference-word compare → non-emittable → whole function reverts).
`a?.b` optional-chain stays fallback: a scalar field ⇒ value-optional result (absent≠0), a reference field ⇒
field_get ARC not modelled. Case `355`. Also landed 3 fixes: ref-optional PARAM inner-tid threading (case 351's
`tag`/`firstNonEmpty` were falling back), store-authoritative ref-optional detection, and a value-optional
safety gate.
**C5** — 2026-08-15: C-style `for` emits (desugar to while; continue-bodies + iterator `for x in` fall back).
**Payloadless ENUMS emit (4130c17):** a HIR post-pass folds `EnumName.Variant` → an int discriminant node,
and `intKindForTid` classifies a payloadless-enum TypeId as a signed 64-bit int — so enum values, `==`/`!=`,
params, returns, locals, AND `switch`-on-enum (C1's if-chain, for free) emit. Case `354`. **Scalar TUPLES emit
(1d222dc):** new `tuple_new` op; a tuple is a positional heap aggregate (`kyte_bytes_alloc(N*8)`, element k at
`k*8`), `t.N` is desugared by the parser to `t[N]` → `index_get`. Landmine fixed: a tuple element is a raw
64-bit word with NO 32-bit wrap (unlike an `int` local), so it must be word-typed. Case `358`. **All-string
TEMPLATES emit (a4dc6f8):** new `template` op; reverse-engineering found this backend lowers `` `${…}` `` to a
StringBuilder (`init`/`append` [copies+borrows, no per-part ARC]/`toString`/`delete`+`release`), NOT a concat
chain. Non-string parts (need `numToString` + temp release) fall back. Case `362`. Tagged enums, owned-element
tuples, tuple returns, and `range`-as-value still fall back.
**C6** — FALLBACK, ABI documented. **CLOSURE ABI (reverse-engineered):** the value is a pointer to a 3-slot ARC
heap box `{fn_ptr@0, env_ptr@8, __clocleanup@16}`; the env is a separate block of by-value capture words (one
i64 per captured var, owned captures retained in); call = load box[0]/box[1], indirect-call passing env as
arg0. Emit is INFEASIBLE without whole-program MIR: the HIR closure node is OPAQUE (`body = HirId.none`), all
capture/env/lambda state is AST-span-keyed, and the lambda is a separate function the (one-function-at-a-time)
emit path never sees. Same structural blocker as D7.
**C7** — FALLBACK, ABI documented. `try expr`: load `tag=box[0]`, `is_err=(tag==1)`, cond-branch; on error run
`runErrdefers()` (innermost→outermost, reverse within a scope, error-path only) then early-return the box; on
ok load `payload=box[8]` + retain if owned. Three independent blockers: the B7 signature gate (a `try` is only
legal in an error-union-returning fn, rejected at its signature), `try_` is a no-op in HIR→MIR (would drop
propagation), and `errdefer`/`defer_stmt` has no HIR lowering. Emit is a slice on top of B7's box modelling.
**C8** — 2026-08-15 (5cb7ec1): new `const_str` MIR op via the immortal interned global (no ARC). With
C0/C3/D2 a whole string function BODY emits; the remaining gate on those functions is B-tier SIGNATURES. Float
literals fall back.

**D1** — `lower_ast_hir` ALREADY threads retain (owned-copy) + releases (scope-end / pre-return-except-moved /
pre-break) from `TypedIr.ownedOf`; the emit path supplies `typed_ir`. The ops exist; the emit path just gates
them. Remaining work is D2 (emit) + C0.
**D2** — 2026-08-15 (334ccf5): emit `kyte_retain` / `kyte_release(ptr, null)` for string operands (no dtor);
owned-local TypeIds threaded so mirEmittable gates ARC ops to strings. ARC-balanced vs the AST baseline (--arc
0 failures). Non-string owned types reject → D3.
**D3** — DONE for STRING-owned-field structs (2026-08-15). A `struct` with only bare-`string` owned fields,
constructed from `const_str` literal values, now emits: construction moves the immortal literal in (no retain
needed), and the release resolves the struct's REAL destructor — heap/class via `compileRelease(v, getOr
CreateDestructorPreferId(name, tid))` (real `__destruct_<Struct>`), value struct via `dropValueStruct(v,
name, tid)` (direct destructor call on the inline-storage address, no free), selected at `.release` by the
value's type. Key finding: plain `struct` is a VALUE struct in this build, so a string-field struct is
usually dropped via `dropValueStruct`, not `kyte_release`. Verified byte-identical + ASAN-clean incl. a 1000-
iteration construct/drop loop (case 352). Non-literal string args, returned string fields, and any non-string
owned field (class/list/nested-struct/error-union) still fall back.
**D4** — DONE for heap/class structs (2026-08-15). A returned BORROWED heap struct (a param, not a fresh
`struct_new` and not a moved owned local) now emits: `lower_ast_hir` threads a return-acquisition `kyte_retain`
(the caller owns the matching release), the `.retain` gate admits a heap-struct pointer word (a refcount bump
needs no dtor), and the `.ret` gate admits a retained result (`isRetainedResult`) alongside the fresh
`struct_new` case. Verified byte-identical + ASAN-clean + ARC-audit-clean incl. a 1000-iteration loop (case
353). The `.release` gate stays string/string-field-struct-only, so a function with a releasable heap-struct
LOCAL still falls back (that needs general class-dtor threading, out of D4 scope).
**D5** — PARTIAL: SYNCHRONOUS trait dynamic dispatch (`indirect_call`) now emits (0e7f0e6). **TRAIT ABI
(reverse-engineered):** a trait object is a 16-byte ARC fat pointer `{struct_ptr@0, vtable@8}`; the vtable is
a global `_vtable_<Struct>_<Trait>` where slot 0 = the destructor and method k = slot k+1; dispatch loads
`struct_ptr`, `vtable`, `fn_ptr = *(vtable + (k+1)*8)`, then an indirect call passing `struct_ptr` as self; a
trait PARAM is borrowed (no ARC). New `indirect_call` MIR op carrying the method name (the optimiser has no
trait table; the backend resolves the slot from the receiver TypeId). Gated to sync + zero extra args + scalar
result + a caller-built fat-pointer receiver. Case `360`. **A latent miscompile was closed:** the baseline
emitted functions that CONSTRUCT a trait object and pass it to a trait-param callee, sending the raw struct
pointer (not a fat pointer) → BUS; the new `.call` gate makes those fall back. Async (`await`/`spawn`,
`func.is_async`), trait construction/widening, dispatch-with-args, and non-scalar returns stay deferred.
**D6** — WIRED (98db0f9). `arc_elision` is ALREADY in `driver.pipeline` and runs on the emit path (no gate)
now that D1-D4 thread ARC. Instrumented: it fires 0 times on the current subset (a retained string is always
subsequently used → `observesRef` blocks the cancel; a D4 return-retain's matching release is in the CALLER).
So it is active + provably byte-identical, but the perf win awaits the subset growing to produce a genuinely
redundant retain/release pair.
**D7** — the emit path lowers ONE function at a time, so there is no MIR callee map to inline from. Needs
whole-program MIR (a larger restructuring). Implemented + unit-tested; stays dormant.

**E1** — premature: coverage is still partial so it buys ~0 perf, and it changes EVERY build. A deliberate
call once B+D coverage is high. Not flipped autonomously.
**E2** — with the subset still small, emit buys near-zero end-to-end speed; the win needs the hard B/D tier +
elision on hot functions. Re-measure after those.
**E3** — the `KYTE_OPT` report-only path can go once emit is broadly trusted; removing it now loses the
coverage gauge. Not done autonomously.
**E4** — the emit path is off by default, so it does not affect Windows/wasm builds today. Validation belongs
with the E1 flip.
