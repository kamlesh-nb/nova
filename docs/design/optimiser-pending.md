# Optimiser integration: pending work

Tracking table for everything still to implement or fix in the HIR/MIR/LIR optimiser integration.
Companion to `optimiser.md` (design + landed history). As of 2026-08-15.

## Where we are

The emit path (`NOVA_OPT_EMIT`) is byte-faithful to the AST backend for everything it accepts. All three
gates sit at **349/350** (default, emit, emit `--asan`), the only failure being the off-Linux
`189_epoll_event_layout`. It is off by default with per-function AST fallback, so it cannot harm a real
build. What remains is almost entirely coverage and activation, not fixing broken output: in a real sha256
build only about **1 of 146 functions** emits, the rest fall back.

Status legend: TODO (not started), WIP (in progress), DONE. Priority: P0 highest.

## A. Correctness fixes (bugs inside the current subset)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| A1 | `0x80000000` long-literal width bug | P1 | TODO | A hex literal with bit 31 set, used in `== long`, emits as a 32-bit int (INT_MIN, sign-extended) so the compare fails. Root: literal's threaded width in the emit const path. Does not regress the corpus (masks hide it). Repro: `fn f(x:long){return x<<31;} … r == 0x80000000`. |
| A2 | Audit the wider `long`-vs-`int` threading class | P1 | TODO | Same weakness as A1 and the mask-read-as-int case (`and i64 %0,-1`). Other `long` boundary cases may lurk; sweep the const/cast/compare threading. |
| A3 | `verify.zig` use-before-def gap | P1 | TODO | The verifier did not catch the dangling load the M6-C mem2reg bug produced. Harden it to reject use-before-def before emit trusts the MIR. |

## B. Coverage: signatures (params and returns)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| B1 | Methods / `self` params | P0 | DONE | 2026-08-15. `self` is an EXPLICIT params[0] (`fn m(self: T, ...)`), so AST params line up 1:1 with the LLVM args and no shift was needed. The method FunctionInfo sites just were not setting `.params = fn_decl.params` (constructors stay empty, self is synthetic there). Coverage jumped ~1->13 emitted in a sha256 build; the reject dropped from ~99 to ~6 (constructors). Pinned by `341_opt_emit_methods.nova`. Gates: emit 349/350. Class methods emit (heap `self`); value-struct methods and constructors fall back. |
| B2 | String params / returns / locals | P1 | BLOCKED on D1 | 2026-08-15 investigation: strings are ~152 of the param rejects (by far the biggest), BUT a `string` is an ARC-managed heap pointer and retain/release are not threaded into MIR yet (D1). A borrowed string is only sound while it never transfers ownership (no call, struct_new, or field_set) -- and EVERY useful string op (`.length()`, `==`, concat) is a call, so a sound pre-D1 gate emits +1 function (measured on a sha256 build). Not worth a gate that will be reworked at D1. Do D1 first, then strings gate on real retain/release ops. |
| B3 | Float params / returns / locals | P2 | DONE (f64) | 2026-08-15 (commit be6c9ac): f64/double arithmetic emits -- value is the double's bits in the i64 word; bitcast to double, fadd/fsub/fmul/fdiv/fcmp, bitcast back. Float literal -> const_int(bits); constfold hardened to never fold a float binop (bits are not an int). f32, decimal, mixed int/float, and float mod/shift/bitwise fall back. |
| B4 | Array / pointer params (read-only) | P2 | DONE (read-only, non-float) | 2026-08-15 (commit 238e8a8): accept a non-float array param (flows as `ptr`, round-trips the i64 slot; index_get resolves it). Array WRITE `a[i]=v` still falls back -- its lvalue is unmodelled and lowered to a bad `store <i64 addr>`; mirEmittable now requires a store target to be an `alloc` (general hardening, caught a 260 regression). Float arrays fall back. |
| B5 | Value-struct params / returns | P2 | TODO | Only heap/`class` structs emit (M6-D). Plain (scalar-field) value structs are SOUND (no ARC) but need by-value ABI + inline field access. Low value in the measured builds. |

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
| B6 | Optional (`T \| undefined`) params / returns | P2 | TODO | Deliberately rejected at the type-ref level (concreteTidForTypeRef strips the optional). |
| B7 | Error-union (`T \| E`) returns | P2 | TODO | Not encoded yet. |
| B8 | `>16` params | P3 | TODO | Minor fixed-buffer cap in `tryEmitInner`. |

## C. Coverage: body constructs (rejected HIR nodes / MIR ops)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| C1 | `switch_` / match lowering | P1 | TODO | Rejected in both `hirEmittable` and `mirEmittable` (dense/sparse lowering not emitted). |
| C2 | `cast` (int<->int) | P2 | DONE (int<->int) | 2026-08-15 (commit 5cb7ec1): allow `.cast`; mirEmittable gates operand AND result to int kinds (canonicalise to result width). float<->int / pointer casts still fall back. |
| C3 | `index` (array / list element access) | P2 | DONE (string byte + array word) | 2026-08-15 (commit 7331294): new `index_get` MIR op. String indexes a byte (obj+idx, load i8, zext); array GEPs the i64-word element. Float arrays + lists (method-call access) fall back. String byte index emits now; array-index functions need array params (B4) so the array path is latent. NB: eliminated `index` rejects but ~0 function-coverage gain -- string bodies hit C8 (str literals) / C2 (casts) next. |
| C4 | `optional_chain` / `nullish` | P2 | TODO | Not in the allowlist. |
| C5 | `tuple`, `enum_init`, `template`, `range` | P2 | TODO | Aggregate and interpolation forms. |
| C6 | `closure` | P3 | TODO | Capture handling not modelled. |
| C7 | `try_` (error handling / errdefer) | P2 | TODO | Not modelled. |
| C8 | String / float literals in the body | P1 | DONE (string) | 2026-08-15 (commit 5cb7ec1): new `const_str` MIR op materialised via the immortal interned global (`getOrCreateStringLiteral`, no ARC). Float literals still fall back (need float handling). With C0/C3/D2 a whole string function body now emits (str/cast/index rejects -> 0 on the stdlib string files). Remaining gate on those functions is B-tier SIGNATURES (optional/string returns, array/value-struct params). |

## D. ARC and async tier (the performance payoff)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| C0 | Method / builtin call NAME resolution (string receivers) | P1 | DONE (strings) | 2026-08-15 (commit 334ccf5): `lower_ast_hir` rewrites a method call on a STRING receiver `s.m(a)` -> named call `string_m(s, a)` (receiver prepended). Name owned by `hir.Func`. Needs `mir.type_store` set before AST->HIR (moved earlier). Non-string receivers (generics, user structs) still nameless -> a follow-up (needs general type-name mangling in the optimiser). |
| D1 | Thread explicit `retain`/`release` into HIR | P0 | ALREADY DONE (in shadow) | `lower_ast_hir` ALREADY threads retain (owned-copy) + releases (scope-end / pre-return-except-moved / pre-break) from `TypedIr.ownedOf`, and the emit path already supplies `typed_ir`. So the ops exist; the emit path just rejects them. The remaining work is D2 (emit them) + the C0 prerequisite below. |
| D2 | Emit `retain`/`release` in the emit path (strings) | P1 | DONE (strings) | 2026-08-15 (commit 334ccf5, with C0): emit `nova_retain` / `nova_release(ptr, null)` for string operands (a string needs no dtor); owned-local TypeIds threaded so mirEmittable gates ARC ops to strings. ARC-balanced vs the AST baseline (--arc 0 failures). Non-string owned types (structs/lists/error-unions) still reject -> D3 (real `__destruct_*` resolution). |
| D3 | Owned-field structs / aggregates | P2 | TODO | Beyond the scalar-field case; need retains. |
| D4 | Return a borrowed struct | P2 | TODO | Today only fresh `struct_new` results may be returned (a borrowed struct needs a retain). |
| D5 | `await_` / `spawn_` / `indirect_call` | P2 | TODO | Async plus trait dynamic dispatch. |
| D6 | Activate `arc_elision` pass | P1 | TODO | Implemented and unit-tested but DORMANT until D1. This is the actual perf win. |
| D7 | Activate `inline` pass | P2 | TODO | Implemented and unit-tested but dormant; needs call-graph threading. |

## E. Meta-integration and rollout

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| E1 | Default-on flip (hybrid emit + fallback) | P1 | TODO | The middle-end does NOT emit by default; codegen still lowers from the AST. Flip once coverage is high enough to matter. |
| E2 | Realise and measure actual perf | P1 | TODO | About 1/146 functions emit today, so integration buys near-zero speed. The win appears only once B plus D land and elision fires on hot functions. |
| E3 | Retire the M0-M5 shadow scaffolding | P3 | TODO | The `NOVA_OPT` report-only path can go once emit is broadly trusted. |
| E4 | Windows / wasm emit validation | P3 | TODO | The emit path is native-focused (the coroutine gate is `!is_wasm`). |

## Critical path to a perf-positive optimiser

**B1 (methods)** then **B2 to B5 (real-world param/return types)** then **D1 and D2 (ARC threading plus emit)**
then **E1 (default-on)**. Everything else is a correctness cleanup (A), a long-tail construct (C), or
teardown (E). Each is a gated increment with the same differential plus corpus plus ASAN discipline as the
increments already landed (see `optimiser.md`).
