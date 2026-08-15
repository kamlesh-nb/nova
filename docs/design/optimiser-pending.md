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
| B3 | Float params / returns / locals | P2 | TODO | f32/f64 excluded from `intKindForTid`. SOUND (no ARC) but needs float arithmetic ops (fadd/fmul/fcmp + i64<->double bitcasts) in the emit path. Low value: negligible in the measured builds. |
| B4 | Array / pointer params | P2 | TODO | Arrays flow as `ptr` (not the i64 word), and array use needs C3 (index). Low value in the measured builds. |
| B5 | Value-struct params / returns | P2 | TODO | Only heap/`class` structs emit (M6-D). Plain (scalar-field) value structs are SOUND (no ARC) but need by-value ABI + inline field access. Low value in the measured builds. |

**B-group finding (2026-08-15):** the dominant lever (B2 strings) is ARC-blocked; B3/B4/B5 are sound but
low-value. So the productive next step is **D1 (thread ARC into HIR/MIR)**, which unblocks strings *and*
activates arc-elision (the perf win). Re-sequenced: D1 before the rest of B.
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
| C0 | **Method / builtin call NAME resolution** (prerequisite for strings) | P1 | TODO | 2026-08-15 finding: a method call (`s.length()`) lowers with a `.field` callee, so `lowerCall` sets `name = null` and `mirEmittable` rejects the nameless call; the resolved `callee: SymbolId` has no `SymbolId`->mangled-name bridge exposed to the emit path. So NO string op emits (all are calls). This gates all of B2 (strings) together with D2. Needs a `SymbolId`->LLVM-name resolution (or set `callee_name` at lower time from the resolved method). This is the real string unlock, paired with D2. |
| D1 | Thread explicit `retain`/`release` into HIR | P0 | ALREADY DONE (in shadow) | `lower_ast_hir` ALREADY threads retain (owned-copy) + releases (scope-end / pre-return-except-moved / pre-break) from `TypedIr.ownedOf`, and the emit path already supplies `typed_ir`. So the ops exist; the emit path just rejects them. The remaining work is D2 (emit them) + the C0 prerequisite below. |
| D2 | Emit `retain`/`release` in the emit path | P1 | PROTOTYPED, reverted; blocked on C0 | 2026-08-15: built + validated a strings-only ARC emit slice (retain=`nova_retain`, release=`nova_release(ptr,null)` -- a string needs no dtor; threaded owned-local TypeIds to gate ARC ops to strings). Emit/ASAN/ARC all green. BUT reverted: it emits ~0 useful functions, because every string operation is a CALL the emit path cannot name-resolve (see C0). ARC has nothing to apply to without C0. Strings need C0 + D2 TOGETHER. |
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
