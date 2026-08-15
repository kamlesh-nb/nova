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
| B1 | Methods / `self` params | P0 | TODO | The single biggest blocker: about 99 of ~146 rejects. `func.params` is empty for methods because `self` shifts LLVM argument indices. Populate params and handle the shift in `tryEmitInner` and `resolveCallee`. |
| B2 | String params / returns / locals | P1 | TODO | Rejected today (not int/bool/heap-struct). |
| B3 | Float params / returns / locals | P1 | TODO | f32/f64 are excluded from `intKindForTid`. |
| B4 | Array / pointer params | P2 | TODO | Arrays flow as `ptr`; rejected. |
| B5 | Value-struct params / returns | P2 | TODO | Today only heap/`class` structs emit (M6-D). Value structs reject. |
| B6 | Optional (`T \| undefined`) params / returns | P2 | TODO | Deliberately rejected at the type-ref level (concreteTidForTypeRef strips the optional). |
| B7 | Error-union (`T \| E`) returns | P2 | TODO | Not encoded yet. |
| B8 | `>16` params | P3 | TODO | Minor fixed-buffer cap in `tryEmitInner`. |

## C. Coverage: body constructs (rejected HIR nodes / MIR ops)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| C1 | `switch_` / match lowering | P1 | TODO | Rejected in both `hirEmittable` and `mirEmittable` (dense/sparse lowering not emitted). |
| C2 | `cast` to non-int (float / ptr) | P2 | TODO | Only int-to-int casts handled. |
| C3 | `index` (array / list element access) | P2 | TODO | Node kind not in the allowlist. |
| C4 | `optional_chain` / `nullish` | P2 | TODO | Not in the allowlist. |
| C5 | `tuple`, `enum_init`, `template`, `range` | P2 | TODO | Aggregate and interpolation forms. |
| C6 | `closure` | P3 | TODO | Capture handling not modelled. |
| C7 | `try_` (error handling / errdefer) | P2 | TODO | Not modelled. |
| C8 | String / float literals in the body | P1 | TODO | MIR collapses str/float to `const_int 0`, so `hirEmittable` rejects them; needs real materialisation. |

## D. ARC and async tier (the performance payoff)

| ID | Item | Priority | Status | Notes |
|----|------|----------|--------|-------|
| D1 | Thread explicit `retain`/`release` into HIR | P0 | TODO | Keystone. Ownership pass reads `TypedIr.expr_owned`. Activates D2 and the dormant `arc_elision`. |
| D2 | Emit `retain`/`release` in the emit path | P1 | TODO | Currently `else => return false` in `mirEmittable`. |
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
