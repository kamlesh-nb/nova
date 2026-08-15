# Gap analysis: completing the Nova optimiser EMIT PATH

Scope: the `NOVA_OPT_EMIT` LIR to LLVM emit path (`src/optimiser/*`, `src/optimiser/passes/*`,
`src/backend/codegen/lir_emit.zig`). Verified against code and live repros on 2026-08-15, working dir
`/Users/kamlesh/nova-lang/lang`. The status table read is `docs/design/optimiser-pending.md`; the design
narrative is `docs/design/lld/40-optimiser.md`. Where this file disagrees with the table, the code and the
repros below win.

This is a HONEST analysis, not a proof. Section 3 is a PLAN with per-item confidence and unknowns. Two of the
sub-items (whole-program MIR, async coroutines) are genuine multi-week rearchitectures and are labelled so.

---

## 1. Gap (verified)

### What the emit path IS

`lir_emit.tryEmit` is called per-function from `declarations.zig:970`
(`if (lir_emit.emit_enabled and lir_emit.tryEmit(&compiler, fn_val, func)) continue;`). It is a strict
**per-function fallback**: any function outside the emittable subset returns `false` and codegen emits that
function from the AST exactly as before. It is **off by default** (`emit_enabled` set from `NOVA_OPT_EMIT` in
`builder.zig:192` and `tester.zig:284`; `opt_driver.enabled = false` in `driver.zig:235`).

The emittable subset today (each an explicit allowlist entry in `hirEmittable` at `lir_emit.zig:207-253` plus
the per-op gate `mirInstEmittable` at `lir_emit.zig:873`): signed int/bool arithmetic, comparisons, bitops,
casts (int<->int only), string literals + string method calls + string ARC, f32/f64 (double-bit-pattern ABI),
control flow (if/loop/if_expr/break/continue), C-style `for`, direct calls, sync trait dynamic dispatch
(`indirect_call`), value + heap structs (construct/read/mutate/return-fresh), payloadless enums, scalar
tuples, all-string templates, reference optionals (read/compare + nullish `??`), array read (`index_get`).

### What FALLS BACK (each confirmed with a verbose repro or a cited gate)

Repros run with `NOVA_OPT_EMIT=1 NOVA_OPT_EMIT_VERBOSE=1 nova test <case>` over real corpus cases. The
`reject:` line is printed by `lir_emit.reject()` (`lir_emit.zig:45-48`). Counts below aggregate the whole
compile (stdlib + case), so they prove the reject FIRES, not a per-function tally.

| Item | Falls back? | Evidence | Gate in code |
|---|---|---|---|
| **B6 value-optional** param/return/body | YES | `127_value_optional_zero.nova`: `reject: optional return` x10, `reject: non-emittable HIR node` x10 (the `undefined` literal). Emitted 18 / rejected 150. | `lir_emit.zig:114` (`optional return`), `:74` (`optional param`), `:239-249` (`.undefined`/`.null` deliberately NOT in the HIR allowlist) |
| **B7 error-union** `T\|E` return | YES | `266_exception.nova`: `reject: error-union return` x2. `101_errdefer.nova`: x3. | `lir_emit.zig:125` (`error-union return`), `:80` (`error-union param`) |
| **C6 closures** | YES | `04_closures.nova` rejects wholesale (90x `MIR outside emittable subset` + `non-emittable HIR node`). | HIR: `.closure` never in allowlist (`lir_emit.zig:246 else => false`). Lowering is OPAQUE: `lower_ast_hir.zig:520` emits `.closure = { .body = HirId.none }`; `lower_hir_mir.zig:239` lowers it to `const_int 0`. |
| **C7 try/errdefer** | YES | `101_errdefer.nova` + `266_exception.nova` reject. | `try_` is a NO-OP passthrough: `lower_hir_mir.zig:249` `.try_ => lowerNode(operand)` (drops propagation). `errdefer`/`defer_stmt` has no HIR lowering (`lower_ast_hir.zig:323 else => unsupported`). Guarded also by the B7 signature reject. |
| **D5-async** `await`/`spawn` | YES | Any `async fn` rejected up front. | `lir_emit.zig:56` `if (func.is_async) return reject("async fn (coroutine)")`. Even the `await_`/`spawn_` MIR ops (`mir.zig:95-96`) have NO arm in the emit switch, and `spawn_` lowering is a stub (`lower_hir_mir.zig:245-247` builds `.spawn_{callee=0, args=&.{}}`). |
| **D7 inline** | DORMANT (no-op) | Pipeline pass is a no-op. | `passes/inline.zig:22-25` `run` is `_ = allocator; _ = func;` -- "DORMANT on real code... no MIR call graph yet". Activation path `inlineSmallCallees` only runs in the SHADOW (`driver.zig:122`), never on the emit path. |
| **D6 arc_elision** | WIRED, fires 0x | In pipeline (`driver.zig:39`) but proven no-op on the current subset (comment `driver.zig:9-12`). |
| **C4 optional-chain** `a?.b` | YES (nullish `??` emits for ref-optional only) | `166_optional_chaining.nova` rejects. | `lower_hir_mir.zig:152` note: a value-field `a?.b` is a boxed value optional (not modelled). |
| **B3 decimal**, float arrays/fields, float mod/shift/bitwise | YES | -- | documented in `optimiser-pending.md` B3; scalar-only gates |
| **E1 default-on flip** | NOT DONE | `opt_driver.enabled = false`; env-gated only. | `driver.zig:235` |

### The honest % complete

The emit path meets ONE of its two goals (correctness-preserving partial coverage) and NEITHER of the others
(broad coverage, realised perf win). Deriving a number three ways:

- **By scoreboard weight** (`optimiser-pending.md`): DONE 19, PARTIAL 3, FALLBACK 4, WIRED 1, DEFERRED 6 = 33
  rows. Counting PARTIAL as 0.5 and WIRED as 0.25: (19 + 1.5 + 0.25) / 33 ~= **63% of the tracked checklist**.
  But this over-counts: the checklist is dominated by easy scalar-signature rows and under-weights the four
  structural blockers that gate the entire value/error/async/closure half of the language.
- **By function coverage on real code**: on `127_value_optional_zero` the emit path took 18 functions and
  rejected 150 (~11%); on `266_exception`, 15 emitted / 138 rejected (~10%). So on ordinary Nova ~**10-12%**
  of functions currently emit; the rest fall back to the AST.
- **By GOAL** (the stated aim: "the designed perf win"): the win is `arc_elision` + inlining removing
  redundant retain/release on hot functions. `arc_elision` fires **0 times** on the current subset and
  `inline` is a no-op on real code, so the perf payoff is **~0% realised**, and the path is off by default so
  even the correctness work reaches no shipping build.

**Honest headline: call it ~40% of goal.** The scalar/string/struct plumbing is real and airtight, but the
constructs that make Nova *Nova* (value optionals, error unions, closures, async) are all fallback, the two
perf passes are inert, and it ships to nobody. The "63% of checklist" number is real but measures the wrong
thing; ~40% is the honest weight once you account for the blocked half and the unrealised perf goal.

---

## 2. Root cause / blockers (proven from code)

Two structural facts about the emit-path IR explain every fallback in section 1.

### Blocker A -- WHOLE-PROGRAM MIR is absent (the emit path lowers ONE function at a time)

The emit entry point is per-function: `declarations.zig:970` calls `tryEmit` inside the per-declaration
codegen loop, handed a single `func`. `lir_emit.tryEmitInner` lowers exactly that one function's body
(`lower_ast_hir.lowerFuncTyped(... fd ...)` at `:165`). There is no cross-function MIR available at emit time.

Consequences, each cited:
- **Closures (C6) are un-emittable.** The closure's lambda is a *separate function* the per-function path
  never sees, and the HIR node is deliberately opaque: `lower_ast_hir.zig:520` records `.closure = { .body =
  HirId.none }`. All capture/env state is AST-span-keyed elsewhere in codegen. You cannot emit a closure box
  `{fn_ptr, env_ptr, cleanup}` without seeing the lambda body and the capture set together.
- **Inlining (D7) is inert.** `inline.zig:22` is a no-op because "there is no MIR call graph yet". The working
  transform (`inlineSmallCallees`) only runs in `lowerProgramShadow` (`driver.zig:106-124`), which builds a
  callee list from ALL functions first -- precisely the whole-program view the emit path lacks.
- Because D7 never fires, `arc_elision` (D6) sees no cross-call redundant ARC pairs to cancel, so the perf
  goal stays at 0 (`driver.zig:9-12`).

### Blocker B -- the MIR op set has NO box-shaped ops (value-optional box, error-union tagged box, try/errdefer control flow)

The complete MIR `Op` union is `mir.zig:77-136`. It has scalar/memory/call/struct/tuple/string ops and the ARC
ops, plus `await_`/`spawn_` stubs. It has **no** op for: boxing/unboxing a value optional, allocating a tagged
error-union box, or the try/errdefer control-flow. So the lowering collapses those constructs to placeholders:
- **Value optional (B6).** The AST boxes a value optional to a nullable pointer to an 8-byte ARC box (present
  0 is a NON-null box; absent is the null word). The emit path has no box op, so `lower_hir_mir.zig:85`
  lowers `.null`/`.undefined` to `const_int 0` -- exact for a *reference* optional, WRONG for a *value* optional
  (a present 0 would read as absent). Hence the HIR gate refuses any function that materialises `undefined`
  (`lir_emit.zig:239-249`) and the signature gate refuses value-optional params/returns (`:74`, `:114`).
- **Error union (B7).** `T|E` is a tagged 16-byte ARC heap box `{tag@0, payload@8}` with a NESTED
  value-optional ok arm -- so `return 42` is two nested heap boxes. No `alloc-tagged-box` op exists, so the gate
  rejects at the type-ref shape (`lir_emit.zig:80`, `:125`).
- **try/errdefer (C7).** `try_` is a no-op passthrough (`lower_hir_mir.zig:249`) and `errdefer` has no HIR
  lowering at all (`lower_ast_hir.zig:323`). Emitting `try` needs the B7 box (load tag, branch, run errdefers,
  early-return the box) -- control flow that has no MIR representation.
- **async (D5-async).** `await_`/`spawn_` ops exist in the union (`mir.zig:95-96`) but have no emit-switch arm
  and `spawn_` lowering is a stub. More fundamentally, an `async fn` is an LLVM coroutine (presplitcoroutine ->
  CoroSplit); emitting a plain body without the coro prologue makes a malformed coroutine that CRASHES, so
  `lir_emit.zig:56` rejects async up front. Async needs coroutine-frame lowering, which is box-shaped state
  machinery layered on top of the same missing-op problem.

**Blocker-to-item map:** Blocker A gates C6 (closures), D7 (inline), and -- through D7 -- the D6 perf win.
Blocker B gates B6 (value optional), B7 (error union), C7 (try/errdefer), C4 (value-optional chain), and is a
prerequisite for D5-async (which additionally needs coroutine lowering).

---

## 3. Design to complete (PLAN -- per sub-item, confidence + unknowns)

Ordered as requested: whole-program MIR first (unblocks closures + inline), then box-op MIR (value optional,
error union, try/errdefer), then async coroutines, then the default-on flip. Each is a PLAN, not a proof.

### 3.1 Whole-program MIR (unblocks C6 closures + D7 inline)  -- REARCHITECTURE

**Mechanism.** Replace the per-function emit entry with a two-phase build: lower ALL functions (free fns +
methods + lambdas) to MIR up front into a keyed table (`SymbolId -> mir.Func`), exactly as
`lowerProgramShadow` already does (`driver.zig:83-117` builds `funcs` + `own_syms` + a `callees` list). Then
codegen consults that table instead of calling `tryEmit` per function. Inlining (`inlineSmallCallees`, already
written + unit-tested) then has its callee map and fires on real code.

**Files.** `src/backend/codegen/declarations.zig` (move the emit decision out of the per-decl loop to a
pre-pass), `src/optimiser/driver.zig` (promote the shadow's two-phase build into a real emit build that KEEPS
the MIR + the LLVM value handles), `src/optimiser/passes/inline.zig` (already ready; just needs the map).

**The hard part.** The current emit path leans on codegen's per-function context (`compiler.typed_ir`,
`compiler.type_store`, `compiler.constants`, `sema_shadow.live_sema`, the LLVM builder positioned at the entry
block). A whole-program pre-pass must either preserve or re-establish each function's context when it finally
emits -- the emit is NOT context-free today. And lambdas are not in `program.declarations` as first-class fns;
they are synthesised during codegen, so the pre-pass must discover and lower them too (closures need the
lambda body + capture set materialised into MIR -- a `closure_new {fn_sym, captures[]}` op plus a real lambda
MIR func). That closure-lowering is itself a meaningful sub-project on top of the table.

**Confidence: LOW-MEDIUM** for inline-enablement (the transform exists + is tested; the blocker is purely
plumbing the map, so this slice is the most tractable). **LOW** for closures (needs the new op AND lambda
discovery AND capture materialisation). **Unknowns:** how much of the codegen per-function context can be
snapshotted vs must be recomputed; whether method/generic monomorphised instances key cleanly into a
`SymbolId` table; whether emitting out of declaration order breaks any forward-reference assumption in codegen.

### 3.2 Box-op MIR: value optional (B6)  -- WEEKS

**Mechanism.** Add MIR ops `valopt_box {word} -> ptr` and `valopt_unbox {box} -> word` mirroring the AST
helpers (`nova_valopt_box` = `nova_bytes_alloc(8)` storing the raw word; unbox = `box==0 ? 0 : *box`; absent =
null word). The AST boxes on every store into a value-optional slot and unboxes on every payload read -- the
lowering must insert box/unbox at exactly those points, driven by the threaded TypeId telling value-optional
from reference-optional. Then admit `.undefined`/`.null` in the HIR gate ONLY when the target is a value
optional (box to null) vs reference optional (const_int 0), remove the signature rejects at `lir_emit.zig:74`
and `:114`, and remove the two `mirInstEmittable` guards that reject value-optional-producing insts and
value-optional-param callers.

**Files.** `src/optimiser/mir.zig` (two ops + effect/operand tables), `src/optimiser/lower_hir_mir.zig`
(box/unbox insertion at stores/reads/args/returns), `src/backend/codegen/lir_emit.zig` (emit arms + gate
loosening), the ARC threading in `lower_ast_hir.zig` (a value-optional box is an ARC heap object).

**The hard part.** The box is an ARC object, so the retain/release threading must be exactly right or ASAN
lights up (the doc records prior latent miscompiles here -- `optimiser-pending.md` B6: `f(0)` gave AST=222 vs
EMIT=111 with present-0-read-as-absent). Boxing must happen at EVERY store site including call arguments passed
into value-optional params (the call-site box that `buildValoptBox` does today), and unbox at every payload
read + narrowing site. Getting the insertion complete without a whole-function type-flow analysis is the risk.

**Confidence: MEDIUM.** The ABI is fully reverse-engineered and documented; this is "known target, careful
threading". **Unknowns:** narrowing (`if (x != undefined) { ... x ... }`) needs the unbox to be flow-sensitive;
nested value optionals (the error-union ok arm) compound the boxing.

### 3.3 Box-op MIR: error union (B7) + try/errdefer (C7)  -- WEEKS (C7 depends on B7)

**Mechanism.** Add `errunion_box {tag, payload} -> ptr` (16-byte tagged ARC box; ok arm is itself
value-optional-boxed, so it composes on 3.2) and the try control-flow lowering: load `tag=box[0]`, branch on
`tag==1`, on error run errdefers (innermost-first, error-path-only) then early-return the box, on ok unbox
`payload=box[8]` (+ retain if owned). `errdefer` needs a real HIR lowering (a scope-keyed deferred-node list,
error-path-only) -- today it is `unsupported` (`lower_ast_hir.zig:323`). Then drop the type-ref rejects at
`lir_emit.zig:80`/`:125` and make `try_` a real propagating lowering instead of the passthrough at
`lower_hir_mir.zig:249`.

**Files.** `mir.zig` (errunion op + a try/errdefer CFG shape), `lower_ast_hir.zig` (errdefer scope stack +
`try_` propagation), `lower_hir_mir.zig` (`try_` -> tag-branch + errdefer emission), `lir_emit.zig` (emit +
gate).

**The hard part.** errdefer ordering (LIFO across the active scope stack, error-path only, before locals
drain) is subtle control flow that must match the AST's `runErrdefers()` exactly, and the ok arm's nested
value-optional box means B7 is strictly built ON TOP of 3.2. The retain-into-box + release-by-tag destructor
(`__destruct_ErrUnion_*`) must be threaded.

**Confidence: MEDIUM-LOW.** Depends on 3.2 landing first and on getting errdefer semantics byte-identical.
**Unknowns:** interaction of `try` inside loops/nested scopes; the `catch`/`??`-on-error unbox paths that share
the box; whether errdefer's scope model can be expressed without a full defer-lowering rework.

### 3.4 async coroutines (D5-async)  -- MULTI-WEEK REARCHITECTURE, highest risk

**Mechanism.** Teach the emit path to build an LLVM coroutine: emit the `llvm.coro.id`/`begin`/`suspend`/`end`
intrinsic scaffold, model `await` as a suspend point + resume, `spawn` as fork-returns-future, and let
CoroSplit split the frame. The `await_`/`spawn_` MIR ops exist but carry no frame/suspend modelling and have no
emit arm; `spawn_` lowering is a stub.

**The hard part.** This is not "add an op" -- it is reproducing the entire coroutine-frame lowering that the AST
backend does, including the presplitcoroutine attribute contract, suspend-point state, and the future ABI. The
generic-async-method restriction ("spawnable only from a CONCRETE instantiation") applies. A malformed
coroutine does not fall back gracefully -- it CRASHES in CoroSplit (`lir_emit.zig:52-56`), so the gate has to
stay airtight until the whole thing works.

**Confidence: LOW.** This is genuinely multi-week and is the single least-tractable item. Do NOT minimise it  -- 
it is a second full lowering path, and it also sits on top of B7 (an `async fn` returns `T|E`). Realistically
this is the LAST thing to attempt and only after 3.1-3.3 are solid.

### 3.5 default-on flip (E1)  -- DAYS, but gated on coverage

**Mechanism.** Set the emit path on by default (`driver.zig:235` / the builder+tester env reads) once coverage
is high enough to buy perf and the differential + ASAN + corpus gates are green with it on. Add the Windows/
wasm emit validation (E4) at the same time (currently untested because off-default).

**The hard part.** Purely a product/coverage call -- premature today because coverage is ~10-12% so it buys ~0
perf while changing every build (`optimiser-pending.md` E1). The technical work is trivial; the bar is that
3.1-3.3 have landed AND `arc_elision`/inline actually fire on hot functions (measure E2 first).

**Confidence: HIGH** (mechanically) once the coverage precondition is met.

---

## 4. Risk + effort (honest guess)

| Sub-item | Size | Risk | Note |
|---|---|---|---|
| 3.1a Enable inline (map plumbing) | **days** | medium | transform exists + unit-tested; plumb the callee map from the shadow's two-phase build |
| 3.1b Whole-program MIR + closures | **weeks -> rearchitecture** | HIGH | needs a per-function context that survives a whole-program pre-pass + lambda discovery + a `closure_new` op + capture materialisation |
| 3.2 Value optional box | **weeks** | medium-high | ABI known; risk is complete + correct box/unbox insertion (ASAN is the judge) |
| 3.3 Error union + try/errdefer | **weeks** | medium-high | builds on 3.2; errdefer ordering must be byte-identical |
| 3.4 Async coroutines | **multi-week rearchitecture** | VERY HIGH | a second full lowering path; malformed coro = crash, not fallback; sits on B7 |
| 3.5 Default-on flip + Win/wasm validate | **days** | low | gated on coverage + green differential/ASAN with it on |

**Rearchitecture-honest callouts:** 3.1b (whole-program MIR + closures) and 3.4 (async coroutines) are NOT
incremental -- they are new lowering infrastructure and are genuinely multi-week each. 3.2 and 3.3 are "weeks"
of careful box-ABI threading with ASAN as the oracle, and 3.3 strictly depends on 3.2. Only 3.1a (inline
enablement) and 3.5 (the flip) are days-scale. Anyone promising the emit path "finished" in a sprint is
mis-sizing 3.1b and 3.4.

---

## 5. Verify (the gate that proves each done, and the end-state bar)

**Per-item done gate.** Every emit-path increment lands under the SAME discipline the existing 25 opt-emit
cases (`conformance/cases/338`-`362`) landed under:
1. **Differential byte-identical:** `conformance/emit-differential.sh` compiles a program BOTH ways (trusted
   AST vs `NOVA_OPT_EMIT=1`) and asserts identical output -- the oracle the path was built against
   (`emit-differential.sh:2-9`). A new construct adds a differential case here.
2. **ASAN-clean:** `NOVA_ASAN=1 zig build` then `conformance/run.sh --asan` -- the authority for the box work
   (value-optional/error-union boxes are ARC heap objects; ASAN catches the UAF/double-free that `--arc`
   misses). Prior latent emit miscompiles in this area were caught exactly here.
3. **`--arc` balanced:** `conformance/run.sh --arc` (baseline-gated) for ARC-neutral box/retain/release.
4. **A pinning corpus case** (like 354-362) proving the new coverage emits (via `NOVA_OPT_EMIT_VERBOSE`
   showing `emitted fn ... via LIR path`, not a `reject:`).
5. **Default corpus stays green:** `conformance/run.sh -j` (321 cases) unchanged with the path OFF -- proves no
   regression to the shipping backend.

**End-state bar (the emit path "complete").** The emit path is **on by default** (`NOVA_OPT_EMIT` retired /
`driver.zig` `enabled = true`), and with it on: the full default corpus is green (`run.sh -j`), `--asan` is
green, `--arc` is baseline-clean, the emit-differential gate is byte-identical across the whole set, AND
`arc_elision` + inline demonstrably fire on hot functions with a measured throughput win (E2) -- because the
whole point was the perf goal, and until a redundant retain/release pair is actually cancelled on a hot path,
the emit path is correct-but-pointless. Windows/wasm emit validation (E4) rides the same flip.
