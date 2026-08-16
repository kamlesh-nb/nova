# The Nova optimiser: a HIR / MIR / LIR middle-end

Status: design, not yet implemented. Home for all code: `lang/src/optimiser/`.
Author's intent: give Nova a real optimising middle-end between the typed frontend and the LLVM
backend, with automatic reference counting (ARC) modelled as first-class IR operations so that
redundant retain/release pairs can be elided. ARC-elision is the headline payoff; a clean multi-tier
IR is the enabling structure.

## Why we are doing this

Today the pipeline is:

```
source -> lexer -> parser -> AST -> sema (typed IR) -> llvm_codegen (walks the AST) -> LLVM IR -> object
```

`backend/codegen/llvm_codegen.zig` walks the **AST** directly and, guided by the sema `TypedIr`
(`expr_types`, `expr_owned`, `tp_resolve`, `expr_types_inst`, keyed by `ExprId`/`InstKey`), emits LLVM IR
in one pass. ARC `retain`/`release` calls are inserted inline as the walker goes
(`backend/codegen/arc.zig`: `compileRetain`, `compileRelease`, `releaseLocalVariables`,
`dropValueStruct`). There is no mid-level intermediate representation.

This has served well, but it has three structural limits:

1. **ARC is emitted, never reasoned about.** Every owned value gets a retain on acquisition and a
   release at scope end. A great many of these pairs are provably redundant (a value created and
   consumed in the same block, a borrow that never escapes, a temporary passed straight into a callee
   that takes ownership). We cannot elide them because by the time they exist they are opaque LLVM
   calls, and LLVM does not know they are balanced. The per-request allocation-and-refcount count is
   the measured per-core gap against Rust (see `docs/design/perf-improvement.md` and the
   `nova-per-core-perf-vs-rust` note): ~3000 ARC objects per request against ~50 for hand-written
   code. Removing provably-redundant traffic is the single biggest perf lever left.

2. **Optimisation has nowhere to live.** Constant folding, dead-code elimination, copy propagation,
   inlining of tiny accessors, and branch simplification all have to be either done ad-hoc on the AST
   (fragile, and the AST is not in a normal form) or left entirely to LLVM (which cannot see Nova-level
   invariants like "this optional is statically present" or "this trait call has one concrete target").
   A normalised IR with a pass pipeline is where these belong.

3. **The backend is doing too much at once.** `llvm_codegen.zig` (~3900 lines) simultaneously lowers
   control flow, computes ownership, mangles names, and emits LLVM. Splitting lowering into staged IRs
   makes each stage small, testable, and independently verifiable, in the same spirit as the
   frontend/backend/lib reorg and the string-engine removal.

## The shape of the solution: three tiers

We introduce three intermediate representations, each a strict lowering of the one above it. Three
tiers, not one, because each tier answers a different question and a pass wants exactly one of them.

| Tier | Full name | Shape | What it is good for |
|---|---|---|---|
| **HIR** | High-level IR | Tree, typed, desugared | Nova semantics made explicit; source-level rewrites |
| **MIR** | Mid-level IR | SSA over a CFG of basic blocks | Data-flow analysis and the optimiser; ARC-elision lives here |
| **LIR** | Low-level IR | Linear, near-LLVM, no SSA phis needed | A thin, mechanical hand-off to LLVM |

```
AST + TypedIr -> HIR -> MIR (SSA/CFG) -> [optimiser passes] -> LIR -> LLVM IR -> object
                 ^lower  ^lower                                 ^lower  ^emit
```

The sema frontend is unchanged. The middle-end consumes the AST plus the `TypedIr` (types, ownership,
monomorphisation instances) that sema already produces, and hands the backend a lowered IR to emit.
Codegen stops walking the AST and starts walking LIR.

### HIR: high-level IR

HIR is a **typed, desugared tree**. It is the AST with all the Nova sugar removed and every node
carrying a concrete `TypeId` (post-monomorphisation, so `List<int>` not `List<T>`). Desugaring makes
implicit work explicit so later tiers have fewer cases:

- `for`, `while let`, optional chaining `?.`, the null-coalesce `??`, `if`/`switch` **expressions**,
  string interpolation, and the ternary all lower to explicit `if`/`loop` + `match` HIR nodes.
- `try`/`?` error propagation lowers to an explicit branch on the error union.
- `await`/`spawn` become explicit HIR nodes (they survive to LIR; the backend still lowers them to
  LLVM coroutines).
- **ARC becomes explicit here.** Every value acquisition that sema marked owned
  (`TypedIr.expr_owned` / `expr_owned_inst`) emits an explicit `hir.Retain`, and every scope exit that
  would drop an owned local emits an explicit `hir.Release`. This is the crucial move: retain/release
  stop being a backend side effect and become IR operations that later passes can see, count, and
  cancel. HIR ARC is the naive, always-correct placement (exactly what codegen emits today); the MIR
  optimiser is what makes it sparse.

HIR is still a tree because desugaring is a structural rewrite and reads most naturally as one. It is
not yet in SSA and has no explicit control-flow graph.

### MIR: mid-level IR, SSA over a CFG

MIR is where the optimiser works. It is **Static Single Assignment** form over a **control-flow graph**
of **basic blocks**. Each function becomes:

- a list of basic blocks, each a straight-line sequence of instructions ending in a terminator
  (`br`, `condbr`, `switch`, `ret`, `unreachable`);
- instructions that define at most one **virtual register** (an SSA value), so every value has exactly
  one definition and def-use chains are trivial to walk;
- block arguments (our spelling of phi nodes) to merge values at control-flow joins.

MIR instructions are typed (every SSA value has a `TypeId`) and include the Nova-specific operations
that must survive to the backend: `retain`, `release`, `alloc`, field load/store, `call`,
`indirect_call` (trait dispatch), `await`, `spawn`, and the arithmetic/comparison/cast set.

Why SSA: the ARC-elision pass, dead-code elimination, constant propagation, and copy propagation are
all data-flow problems, and SSA makes them near-trivial (one definition per value, explicit def-use).
This is the standard reason production compilers put their optimiser on an SSA IR.

### LIR: low-level IR

LIR is a **linear, register-allocated-in-spirit, near-LLVM** representation. It is MIR after the
optimiser, with SSA block arguments resolved into a form the LLVM builder consumes directly, and with
every operation reduced to something that maps one-to-one onto an LLVM builder call. LIR exists so the
backend is a dumb, mechanical translator with no decisions left to make: no ownership reasoning, no
name mangling logic, no type-decision work. It walks LIR and calls `LLVMBuild*`.

LIR keeps the async and ARC operations explicit (LLVM coroutine intrinsics and the
`nova_retain`/`nova_release` runtime calls are emitted here), but it makes no further choices about
them; the choices were made in MIR.

## The optimiser: passes over MIR

The pass pipeline runs on MIR. Passes are small, each with a single responsibility, each verifiable in
isolation. The initial set, in dependency order:

1. **Mem2reg / promotion.** Promote address-taken locals that never escape into SSA values. This is
   the enabler for everything else; without it most values are loads/stores and data flow is opaque.
2. **Constant folding and propagation.** Fold constant arithmetic, propagate known constants, and
   resolve statically-known optionals (`x ?? d` where `x` is provably present) and statically-known
   trait targets (a single concrete implementor) into direct calls.
3. **Copy propagation and redundant-load elimination.** Standard SSA clean-ups that expose more
   ARC-elision opportunities.
4. **Dead-code elimination.** Remove instructions whose results are unused and have no side effects.
   Crucially, a `retain` whose only use was elided becomes dead here.
5. **ARC-elision (the headline pass).** See below.
6. **Inlining (bounded).** Inline trivial accessors and single-call-site functions. Nova generates
   many tiny getters and generated binders (`__bind`, serde); inlining them removes call overhead and
   exposes cross-call ARC pairs to elision. Bounded by a size/blow-up budget.
7. **Simplify-CFG.** Merge straight-line blocks, remove unreachable blocks, fold trivial branches. Run
   last as a clean-up, and interleaved as other passes create dead edges.

Passes 2 to 7 iterate to a fixpoint (bounded), because each pass exposes opportunities for the others
(the classic fold -> DCE -> simplify cycle).

### ARC-elision, in detail

This is why the whole structure exists. Nova's ownership is decided in sema
(`TypedIr.expr_owned` / `expr_owned_inst`, the TypeId ownership predicates) and HIR turns each decision
into an explicit `retain`/`release`. On MIR we then apply the standard ARC optimisation moves, all of
which are sound because the IR is SSA and typed:

- **Redundant retain/release cancellation.** A `retain(v)` followed on all paths by a `release(v)`
  with no operation in between that could observe the refcount (no escape, no store into a
  heap-reachable location, no call that captures `v`) is a balanced pair and both are removed.
- **Retain/release motion and pairing across calls.** A value retained only to be passed to a callee
  that takes ownership (a `+1` parameter) does not need a separate retain then release; the caller's
  owned value is forwarded (move semantics). This is where "created and immediately consumed"
  temporaries stop churning the refcount.
- **Borrow detection.** A value that is only read through and never stored, returned, captured, or
  passed to a `+1` sink does not need to be retained at all for the duration of the borrow; its
  provider keeps it alive. This is the function-local case the escape-analysis gauge already measures
  (`sema/escape.zig`, `NOVA_ESCAPE_REPORT`); MIR is where we can finally act on it.
- **Release sinking.** Move a release to the earliest point where the value is provably last-used,
  shortening lifetimes and enabling earlier frees.

Every one of these is a local rewrite justified by an SSA data-flow fact, so each is unit-testable on a
small MIR fragment and the whole pass is verifiable against the "does the object count balance" ASAN
gate. The safety rule is conservative by construction: when in doubt, keep the retain/release. Removing
a needed retain is a use-after-free (ASAN catches it); keeping a redundant one is merely slow. We only
ever remove when the data flow proves the pair balanced with no interleaved observer.

Note the relationship to the request-arena work (`nova-p7-request-arena-infra`,
`docs/design/p7-sound-arena.md`): arena allocation removes the *free*; ARC-elision removes the
*retain/release traffic*. They are complementary. Escape analysis feeds both. The arena work found that
function-escape is the wrong granularity for allocation; ARC-elision works at exactly the right
granularity for refcount traffic, which is the function-local balanced pair.

## Data structures (grounded in what exists)

The middle-end reuses the frontend's type system verbatim. It does not invent a parallel one; that was
the whole lesson of the string-engine removal.

- **Types**: `frontend/types.zig` `TypeId` (`enum(u32)`) and the `TypeStore`. Every HIR/MIR/LIR value
  carries a `TypeId`. Ownership queries go through the existing TypeId predicates, never through type
  spellings.
- **Symbols**: `types.SymbolId` for function/struct/field identity, as sema already uses.
- **Monomorphisation**: the IR is built **after** `inst_disp` has run, so all generics are concrete.
  An `InstKey` selects the instance; HIR lowering resolves each `ExprId` through
  `TypedIr.expr_types_inst` / `expr_owned_inst` / `tp_resolve` under the active `InstKey`, exactly as
  codegen does today. There are no type parameters left in HIR.
- **Provenance**: every IR node keeps the originating `ast.Span` (and, where useful, the `ExprId`) for
  diagnostics and for the differential shadow (below).

Sketch of the core node shapes (illustrative, not final):

```
// hir.zig
const HirNode = union(enum) {
    // values
    literal, ident, field, index, call, indirect_call, struct_init, ...
    retain: HirId,               // explicit ARC
    release: HirId,
    // control (desugared)
    if_: struct { cond: HirId, then: HirBlock, else_: HirBlock },
    loop_: HirBlock,
    match_: struct { scrutinee: HirId, arms: []Arm },
    ret, brk, cont,
    await_: HirId, spawn_: HirId,
};

// mir.zig  (SSA over CFG)
const Value = enum(u32) { _ };      // virtual register / SSA value
const Block = enum(u32) { _ };
const Inst = union(enum) {
    binop: struct { op, lhs: Value, rhs: Value },
    load, store, alloc, gep,
    call: struct { callee: SymbolId, args: []Value, takes_ownership: []bool },
    indirect_call,               // trait dispatch through a vtable value
    retain: Value, release: Value,
    await_: Value, spawn_: Value,
};
const Terminator = union(enum) { br: Block, condbr, switch_, ret: ?Value, unreachable_ };
const BasicBlock = struct { params: []Value, insts: []Inst, term: Terminator };
const MirFunc = struct { blocks: []BasicBlock, value_types: []TypeId, ... };

// lir.zig  (linear, near-LLVM)
const LirOp = union(enum) { /* MIR after opt, phis resolved, 1:1 with LLVMBuild* */ };
```

## Folder structure: everything under `src/optimiser/`

```
src/optimiser/
  README.md            # points at this doc
  hir.zig              # HIR node definitions
  mir.zig              # MIR: Value/Block/Inst/Terminator/BasicBlock/MirFunc
  lir.zig              # LIR definitions
  lower_ast_hir.zig    # AST + TypedIr  ->  HIR   (desugar + explicit ARC)
  lower_hir_mir.zig    # HIR            ->  MIR   (build CFG, into SSA)
  lower_mir_lir.zig    # MIR (optimised)->  LIR   (resolve SSA, linearise)
  driver.zig           # runs lowering + the pass pipeline; the middle-end entry point
  pass.zig             # the Pass interface + the fixpoint pipeline runner
  passes/
    mem2reg.zig
    constfold.zig
    copyprop.zig
    dce.zig
    arc_elision.zig    # the headline pass
    inline.zig
    simplifycfg.zig
  verify.zig           # IR verifier (SSA well-formedness, type consistency, ARC balance check)
```

The backend (`backend/codegen`) eventually consumes LIR instead of the AST. During the rollout it keeps
its current AST path (see below), and a new thin `lir_to_llvm` emitter grows alongside.

## Integration and rollout: shadow first, switch last

We do **not** replace the working AST->LLVM path in one commit. That path passes 340/341 corpus + ASAN
and it is our correctness oracle. We follow the same shadow-then-cut methodology that de-risked SE-A/B/C:

- **Milestone M0 (scaffold).** Create `src/optimiser/` with the IR type definitions and a no-op
  `driver.run` that is not on the critical path. Reference the modules from `root.zig` so `zig build`
  type-checks them. No behaviour change. This is the code home the user asked for.
- **Milestone M1 (lower + round-trip, off).** Implement AST->HIR->MIR->LIR with **no** optimisation
  passes, plus a `lir_to_llvm` emitter. Gate it behind `NOVA_OPT=1` (off by default). When on, codegen
  emits from LIR instead of the AST. Success = the corpus + ASAN pass byte-for-byte equivalently
  (same behaviour) with `NOVA_OPT=1`. This proves the lowering is faithful before any pass touches it.
- **Milestone M2 (verifier + differential shadow).** Add `verify.zig` (SSA well-formedness, type
  consistency, and an ARC-balance check: every value's retains and releases net to its ownership
  contract). Add a differential mode that runs BOTH paths and asserts identical observable behaviour,
  exactly like `NOVA_SEMA_SHADOW` / the census did for the string engine.
- **Milestone M3 (safe passes).** Turn on the non-ARC passes (mem2reg, constfold, copyprop, dce,
  simplifycfg) one at a time, each gated by the full corpus + ASAN + the verifier. These change
  generated code but not behaviour.
- **Milestone M4 (ARC-elision).** The headline pass, landed last and most carefully, one elision move
  at a time (cancellation, then move/forward, then borrow, then sink), each proven by: full ASAN
  corpus (no new use-after-free), the ARC-balance verifier, and a measured drop in retain/release
  counts on the web/ORM benchmarks. Conservative by construction; when the data flow is not certain,
  the pair stays.
- **Milestone M5 (inlining).** Bounded inlining of accessors/binders, which multiplies M4's wins by
  exposing cross-call pairs.
- **Milestone M6 (cut over).** Once `NOVA_OPT=1` has been the measured-better, corpus-and-ASAN-clean
  path for long enough, make it the default and retire the AST->LLVM emitter. The backend becomes a
  LIR emitter only.

At every milestone the fallback is the current path, and the gate is unchanged: `conformance/run.sh -j`
(fast, catches miscompiles as loud failures) and `NOVA_ASAN=1 zig build && conformance/run.sh --asan`
(catches any ARC mistake as a use-after-free). Perf is measured on the web/ORM/YCSB benchmarks, since
ARC-elision is the reason we are here.

## Verification strategy (how we know it is right)

- **The verifier (`verify.zig`)** runs after every pass in debug builds: SSA has one def per value,
  block arguments match predecessor terminators, every value is dominated by its definition, types are
  consistent across an instruction's operands, and ARC is balanced against each value's ownership
  contract. A pass that breaks any invariant fails loudly at the pass boundary, not later as a
  mysterious miscompile.
- **The differential shadow** runs the AST path and the LIR path and compares observable behaviour
  during the rollout, so a divergence is caught the moment it appears and attributed to a specific
  pass. This is the same method that made the string-engine removal safe.
- **The gates are the existing ones**: the corpus (loud on miscompiles), `--asan` (loud on any ARC
  error), and the benchmarks (the reason the ARC pass exists). No new trust is required; we reuse the
  oracle we already trust.

## Risks and non-goals

- **Risk: ARC-elision removes a needed retain.** Mitigation: conservative-by-default (keep when
  unsure), the ARC-balance verifier, and the full ASAN corpus as a hard gate. A wrong elision is a
  use-after-free, which ASAN catches deterministically; it is never silent.
- **Risk: the lowering is not faithful and M1 diverges.** Mitigation: M1 lands with zero passes, so any
  divergence is a pure lowering bug, isolated from optimisation. The differential shadow attributes it.
- **Risk: scope creep into a general optimiser.** Non-goal for now: loop optimisations (LICM,
  unrolling), vectorisation (LLVM already does this well for our array/SIMD paths), and interprocedural
  analysis beyond bounded inlining. LLVM remains our backend optimiser for the classical scalar work;
  our passes exist for the Nova-specific wins LLVM cannot see, chiefly ARC.
- **Non-goal: replacing sema.** The frontend, the TypeId type system, and monomorphisation are
  unchanged. The middle-end consumes their output.

> Remaining work is tracked as a checklist in **`optimiser-pending.md`** (methods, ARC threading,
> default-on flip, and the rest of the coverage/activation backlog).

## ✅ Resolution (2026-08-15) — genuine emit is now 348/349 (was 272/348 when the gate went honest)

Once the gate was honest (below), the 75-case gap turned out to be three root causes, each fixed as a
clean, differentially-verified increment. Genuine `NOVA_OPT_EMIT=1 conformance/run.sh -j` is now **348/349**
(only `189_epoll_event_layout`, the expected off-Linux structural fail) — identical to the default build,
and clean under `--asan`. Default build (emit off) stays **348/349**, users unaffected.

1. **Unary operators were silently dropped (miscompile).** `lower_hir_mir` lowered every `.unop` as a no-op
   `cast` "cast-through", so `-x` became `x`, `~x` became `x`, `!b` became `b`. This is why the INT_MIN
   probe failed: `-2147483647 - 1` emitted as `2147483647 - 1`. Fix: lower each unop to its exact binop
   identity — `neg`→`0 - x` (sub, canonicalised to width), `bit_not`→`x ^ -1`, `not`→`x == 0`. constfold then
   folds the constant forms. +10 cases. (The "INT_MIN is zero-extended" hypothesis was wrong — the value was
   never negated at all.)
2. **Global-const references lowered to 0 (miscompile).** The `.ident` lowering mapped any name not in the
   local-slot map to `const_int 0` — a fine opaque placeholder for the report-only shadow, but a silent
   miscompile under emit: every `& MASK32` in the crypto/TLS stdlib became `& 0`. Fix (fail-closed): a new
   `mir.Func.emit_poison` flag is set when lowering hits this placeholder; `mirEmittable` rejects a poisoned
   function → AST fallback. The shadow still sees `const 0` (unchanged). Cleared the whole crypto/TLS/DB/
   mediator/web cluster, ~57 cases. (Resolving the const value to GROW the subset is a separate additive
   increment; today it just falls back.)
3. **`async fn` with a trivial body was emitted as a plain function (crash).** An `async fn` is compiled as
   an LLVM coroutine (`presplitcoroutine`, spawned/awaited by callers), but if its body had no await/spawn
   node (e.g. `async fn square(n){return n*n}`) the node gate accepted it, the emit path emitted a plain body
   and `continue`d before the coro prologue → malformed coroutine → CoroSplit crash. Fix (fail-closed):
   `tryEmitInner` rejects `func.is_async` up front. Cleared the 9-case async cluster.

Pinned by `conformance/cases/339_opt_emit_unop.nova` (neg/bit_not/not + INT_MIN boundary, AST vs emit).
The history below (the vacuous-gate correction) is kept for the record.

### Subset growth (2026-08-15) — module-level const references now emit

Fix #2 above made global-const references FALL BACK; they now EMIT. A new opaque MIR op `global_const`
carries the const NAME (opaque so the folding passes never treat it as a known value), and the emit path
resolves it at emit time via `compiler.constants` + `compileConstRef` — the SAME lazy-init per-module
`__const_<name>_val` load the AST path uses, so a literal const and a runtime-computed const both work and
match the AST byte-for-byte. `mirEmittable` accepts it only when the name is a real const whose value is a
scalar int/bool (arrays/structs/strings and bare function references fall back). The resolved word is used
verbatim (NOT re-canonicalised: a `long` mask whose threaded MIR type reads as `int` would otherwise be
width-32 sign-extended, turning `0xffffffff` into `-1` and unmasking `x & MASK32`). Gates: default / emit /
emit-`--asan` all 349/350 (only off-Linux `189_epoll`). Pinned by
`conformance/cases/340_opt_emit_global_const.nova` (mask/rotate idiom + scalar/bool/computed consts).

**Known orthogonal follow-up (pre-existing, exposed by more functions now emitting):** a hex literal with
bit 31 set (e.g. `0x80000000`) used in a `== long` comparison is emitted as a 32-bit int (INT_MIN,
sign-extended) rather than a `long`, so the compare fails. It does NOT regress the corpus (crypto masks the
value before comparing), but `fn f(x:long){return x<<31;} … r == 0x80000000` diverges. Root cause is the
literal's threaded width in the emit const path — the same `long`-vs-`int` threading weakness — not the
global-const work. Fix is a separate increment.

## ⚠️ Correction (2026-08-15) — the NOVA_OPT_EMIT corpus gate was VACUOUS; genuine emit is 272/348

Every prior claim below of "NOVA_OPT_EMIT=1 corpus 346/347" was measured through `nova test`, and
`nova test` (tester.zig) NEVER set `lir_emit.emit_enabled` — only the `nova build` path (builder.zig:192)
did. So `NOVA_OPT_EMIT=1 conformance/run.sh` ran the AST path the whole time: the emit gate proved nothing.
Per-increment BUILD-path differentials (M6-A..E) were real, but the corpus-wide emit gate was not.

Fixed 2026-08-15: tester.zig now sets `emit_enabled`/`emit_verbose`/`mir.type_store` from the same env the
build path reads, so `nova test` genuinely exercises emit. With the gate honest, the numbers are:
- **Default build (emit off): 347/348** (only 189_epoll, expected off-Linux) — unchanged, users unaffected.
- **NOVA_OPT_EMIT=1 (genuine): 272/348 — 75 real failures.** The emit path (M6-A..D) is NOT corpus-correct;
  it was hardened against a gate that didn't run it.

Two representative defects found immediately (there are ~75):
1. **Over-acceptance of non-plain types** (FIXED 2026-08-15). `mirEmittable`/`tryEmitInner` accepted functions
   with value-optional (`int | undefined`) params/returns because `concreteTidForTypeRef` strips the optional
   to its inner int, which then reads as a plain scalar. e.g. `checkedAddInt(): int | undefined` emitted and
   returned `undefined` for a valid value. Fix: reject `.optional` param/return type-refs before the strip,
   and gate the return type to void / scalar-int-bool / fresh-heap-struct only. Recovered ~5 cases.
2. **INT_MIN boundary miscompile** (OPEN — example of the remaining 75). `intMin(): int { return -2147483647
   - 1; }` — the value `-2147483648` (0x80000000) is ZERO-extended to the i64 word instead of sign-extended,
   so `intMin() < 0` reads false. Both the const-folded and the runtime (`x - 1`) forms hit it identically;
   ordinary negatives (-3, -4) are fine, so it is specific to the high-bit-set boundary. This is a miscompile
   of an IN-SUBSET construct (plain int arithmetic), so it must be fixed, not gated — it means other
   boundary-int functions may be subtly wrong.

**The genuine 75-case gap is now the real "M6 remaining" work, and it is measurable for the first time.**
Everything below predates this correction; read it with the vacuous-gate caveat in mind.

## Implementation status (2026-08-14) — honest milestone accounting

The optimiser MACHINERY is built, tested, and proven on real code via the `NOVA_OPT` shadow. The backend
EMIT cutover is deliberately NOT faked. Precisely:

- **M0 scaffold — DONE.** `src/optimiser/` with the IR types + pass registry, compiled by `zig build`.
- **M1 lowering — DONE.** AST→HIR (100% of node forms), HIR→MIR (CFG, locals as memory), MIR→LIR
  (linear near-LLVM). Exercised over the whole corpus: 0 crashes, every function lowers through all four
  tiers.
- **M1 emit half — WIRED, airtight, and EMITTING the optimised IR for a growing subset.** `src/backend/codegen/lir_emit.zig`
  emits an LLVM function body from the optimised MIR, hooked into `declarations.zig` and gated by a SEPARATE
  opt-in `NOVA_OPT_EMIT` (off by default, so default builds are byte-identical). It is a per-function
  FALLBACK: `tryEmit` returns false for anything outside a provable subset and codegen then emits that
  function from the AST unchanged. Every emit is validated by a dry pass (`mirEmittable`) BEFORE any IR is
  built, so a reject can never leave a half-filled block. The subset grew in gated increments (M6-A/B/C),
  each differentially verified (`conformance/emit-differential.sh`) + corpus + ASAN:
  - **base**: paramless straight-line signed-int/bool (arithmetic, 32-bit + chained overflow, comparisons, bitops).
  - **M6-A parameters**: int/bool params, modelled as `let name = param(i)` (LLVMGetParam; every non-array
    param flows as the i64 word). The param node is stamped with its resolved TypeId because mem2reg forwards
    the param store->load, making the param value itself an arithmetic operand. Free functions only.
  - **M6-B control flow**: multi-block CFG — `emitFunc` emits one LLVM block per MIR block with ret/br/condbr
    (branch on `cond != 0`) / unreachable terminators. if/else, nested if, while loops with mutated and
    body-local variables, nested loops.
  - **M6-C direct calls**: a call resolved by source name to an all-word LLVM function (`resolveCallee`:
    N word params, word/void return, else fall back), args passed straight through. Leaf, nested, and
    recursive (`fact`, `fib`).
  - **M6-D structs (heap/reference)**: three atomic MIR ops — `struct_new` / `field_get` / `field_set` —
    carrying the type/field names a backend needs to resolve layout, driving the SAME codegen helpers the AST
    path uses (`compileAlloc`, `getFieldOffset`, `toLLVMType`, `castFrom/ToValType`). Scoped to heap structs
    (`class`, or `struct` that escapes) with scalar fields and no ARC: the gate rejects owned-field structs,
    value structs, and any `retain`/`release`. Returning a heap struct is allowed only when it is a fresh
    `struct_new` (rc=1, moved out) — returning a BORROWED struct needs a retain the emit path does not do, so
    it falls back (an ASAN-caught double-free if it did not). Verified: construction, field read/write on a
    param, differential + ASAN.
  The optimiser pipeline (constfold/mem2reg/copyprop/dce/simplifycfg) runs before every emit. M6-C surfaced
  and fixed a real **mem2reg correctness bug**: full promotion removed a single-block slot's alloc+store even
  when an opaque call between store and load had blocked that load's forwarding, leaving a load of freed
  memory. `mem2reg.zig` now tracks slots with a surviving (`live_load`) load and never promotes them. (This
  is also a `verify.zig` gap — it did not flag the dangling load; hardening it is a follow-up.)

  Getting the base working first required fixing three defects the emit-first-slice surfaced:
  1. **TypeId-0 / unset collision (the reason the subset looked empty).** Store TypeIds are dense indices
     from 0, and `int` is interned first, so TypeId 0 is a REAL type — but the optimiser used `@intFromEnum(ty)==0`
     to mean "no type threaded". Every `int`-typed value therefore read as untyped, and the airtight gate
     rejected even `2 + 3*4`. Fixed with an out-of-range sentinel `unset_ty = 0xFFFF_FFFF` (`hir.zig`,
     `mir.zig`) used everywhere the optimiser meant "unset"; the shadow's type-threading coverage jumps
     accordingly and `int` values now resolve.
  2. **constfold was not width-honest.** It folded integer arithmetic at i64 (`+%`/`*%`), so a chained
     overflow like `(2e9 + 2e9) >> 20` diverged from the runtime's per-step 32-bit wrap. Fixed by giving the
     optimiser the sema `TypeStore` (`mir.type_store`, set by the driver + emit path) and wrapping every
     folded result to its MIR result-type width via `mir.wrapToWidth` — the i64-domain twin of codegen's
     `canonicalizeInt`. (The "synthesised const has an invalid TypeId" symptom was a misdiagnosis: constfold
     folds in place and keeps the binop's valid result type; the segfault was a `symbolName`-result
     double-free in the emit path, also fixed — that string is not caller-owned.)
  3. **Emit-time canonicalisation for narrowing/folded consts.** The emitter canonicalises each `const_int`
     and `cast` to its result-type width, so a folded constant that overflows `int` wraps exactly as the AST
     path would even when it reaches the emitter pre-wrapped.
  Coverage note: the subset now covers int/bool functions with parameters, control flow and direct calls,
  but is still bounded by construction — anything touching ARC, aggregates (structs/value-structs/enums),
  traits/vtables, closures, async, strings/floats, optionals or error unions correctly falls back to the
  AST. Extending to those is the remaining M6 work below, each increment gated the same way (dry-validate,
  differential, corpus + ASAN) before the AST emitter can be retired.
- **M2 verifier — DONE.** SSA/terminator/operand-range checks, corpus-clean (0 verify errors) including
  after block-renumbering passes. The ARC-balance check is present but dormant (no ARC ops yet). The
  differential AST-vs-LIR shadow is N/A until the emitter exists.
- **M3 safe passes — DONE and firing.** mem2reg (local load-forwarding), constfold, copyprop (algebraic
  identities), dce, simplifycfg (const/dup-target branch folding + dead-block elimination with renumber).
  Measured over the whole corpus: **~27% of all MIR instructions removed** (871k / 3.11M), 0 verify errors.
- **M4 arc_elision — FIRING on real code.** The ownership pass threads explicit ARC ops into HIR from
  `TypedIr.ownedOf` (owned `let` -> owned local; owned-local copy -> `retain`). Releases are placed by
  lexical SCOPE as HIR nodes: at the end of the declaring block, before a `return` (all enclosing owned
  locals except one moved out by `return x`), and before `break`/`continue` (the scopes the jump exits).
  mem2reg fully promotes non-escaping single-block slots (removing the dead stores that were falsely
  reading as escapes), and arc_elision cancels balanced pairs over straight-line block TRACES (a chain of
  blocks joined by unconditional `br` into single-predecessor successors), not just within one block.
  Over the full corpus: **24,498 ARC ops threaded, 1,651 pairs cancelled (6.7%)**, 0 verify errors, 0
  crashes. Remaining headroom: dominance-based cross-branch elision, and retain/release motion into +1
  call sinks.
- **M5 inline — algorithm DONE + unit-tested; DORMANT on real code.** Single-block callee splicing is
  implemented and unit-tested. **Activation prerequisite: a MIR call graph** (symbol resolution wiring
  each `call` to its callee `MirFunc`); the lowering currently leaves callees as placeholders.
- **M6 cut over — IN PROGRESS (subset emits; AST path still the fallback).** The LIR→LLVM emitter now
  reproduces the AST path for int/bool functions with parameters, control flow and direct calls (M6-A/B/C
  above), all gated. Retiring the AST emitter requires reproducing the REST of the backend — ARC
  (retain/release/destructors), aggregates (structs/value-structs/enums + pattern matching), traits/vtables,
  closures, async coroutines, strings/floats, optionals, error unions, generics — and certifying each on the
  `--asan` corpus. That is the genuinely multi-week remainder; it is being grown one differentially-verified
  increment at a time (never a half-cutover) with the trusted AST path covering everything not yet emitted.

**Bottom line:** the middle-end and its optimiser are real, correct (verifier + unit tests), and
measurably effective (27% MIR reduction) on the whole corpus, entirely behind `NOVA_OPT` with the trusted
AST path untouched. The backend EMIT path now exists and emits the OPTIMISED IR for a small, airtight,
differentially-verified subset behind `NOVA_OPT_EMIT` (default corpus + `NOVA_OPT_EMIT=1` corpus + ASAN all
346/347). Unblocking it fixed a real whole-optimiser bug (the TypeId-0/unset collision — type-threading
47%→84%) and made constfold width-honest. What remains is GROWING the emitted subset (params, control flow,
calls, ARC, traits) toward the full backend and the two threading prerequisites (ownership→ARC ops,
symbols→call graph) that switch M4/M5 from unit-tested to firing — the M6 cutover.

## One-paragraph summary

Insert a three-tier middle-end (`src/optimiser/`): HIR makes Nova semantics and ARC explicit, MIR puts
it in SSA so the optimiser can reason, LIR hands a decision-free stream to the LLVM backend. The passes
we care about are the ARC ones: turn the retain/release traffic that dominates our per-core gap from an
opaque backend side effect into IR operations we can prove balanced and cancel. Land it behind a flag,
shadow it against the path we already trust, gate every step on the corpus and ASAN, and cut over only
once it is measured-better and proven-safe.
