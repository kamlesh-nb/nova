# src/optimiser — the Nova middle-end

This folder is the home for Nova's optimising middle-end: the HIR / MIR / LIR lowering tiers and the
optimiser pass pipeline that sits between the typed frontend (`src/frontend/sema`) and the LLVM backend
(`src/backend/codegen`).

Read the design first: **`docs/design/optimiser.md`**. It explains why three tiers, what each is for,
how ARC becomes explicit so redundant retain/release pairs can be elided (the headline payoff), and the
shadow-then-cut rollout that keeps the trusted AST->LLVM path as the correctness oracle throughout.

Status: **Milestone M0 (scaffold)**. The IR type definitions and a no-op driver exist and type-check as
part of `zig build` (referenced from `src/root.zig`), but nothing here is on the compile critical path
yet. `driver.run` is a no-op; codegen still lowers from the AST. Filling in the lowering and passes is
M1 onward, each gated on the corpus + `--asan` exactly like the string-engine removal was.

Layout (see the doc for the full plan):

```
hir.zig            HIR node definitions (typed, desugared tree; ARC explicit)
mir.zig            MIR: SSA over a CFG (the optimiser works here)
lir.zig            LIR: linear, near-LLVM (a decision-free hand-off to the backend)
lower_ast_hir.zig  AST + TypedIr -> HIR
lower_hir_mir.zig  HIR -> MIR (build CFG, into SSA)
lower_mir_lir.zig  MIR (optimised) -> LIR
pass.zig           the Pass interface + the fixpoint pipeline runner
driver.zig         the middle-end entry point (M0: no-op)
verify.zig         IR verifier (SSA well-formedness, type consistency, ARC balance)
passes/            mem2reg, constfold, copyprop, dce, arc_elision, inline, simplifycfg
```
