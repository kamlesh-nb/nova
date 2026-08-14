// driver.zig — the middle-end entry point.
//
// Orchestrates AST+TypedIr -> HIR -> MIR -> [optimiser passes] -> LIR, running the MIR verifier after
// every pass in debug builds. This is what builder.zig will call between sema and codegen once the
// backend consumes LIR (gated by NOVA_OPT during the rollout; see docs/design/optimiser.md).
//
// Milestone M0: `run` is a no-op that is NOT on the compile critical path. Codegen still lowers from the
// AST. This file exists so the pipeline shape and the pass registry are real, compiled code, and so the
// modules type-check as part of `zig build`.

const std = @import("std");
const builtin = @import("builtin");

const hir = @import("hir.zig");
const mir = @import("mir.zig");
const lir = @import("lir.zig");
const pass = @import("pass.zig");
const verify = @import("verify.zig");

const lower_ast_hir = @import("lower_ast_hir.zig");
const lower_hir_mir = @import("lower_hir_mir.zig");
const lower_mir_lir = @import("lower_mir_lir.zig");

// The pass pipeline, in dependency order (see the doc). All no-ops at M0.
pub const pipeline = [_]pass.Pass{
    @import("passes/mem2reg.zig").pass,
    @import("passes/constfold.zig").pass,
    @import("passes/copyprop.zig").pass,
    @import("passes/dce.zig").pass,
    @import("passes/arc_elision.zig").pass,
    @import("passes/inline.zig").pass,
    @import("passes/simplifycfg.zig").pass,
};

// Optimise one MIR function: run the pipeline to a bounded fixpoint, verifying after each sweep in
// debug builds. Returns the number of sweeps performed.
pub fn optimise(allocator: std.mem.Allocator, func: *mir.Func) !usize {
    const sweeps = try pass.runToFixpoint(allocator, func, &pipeline, 16);
    if (builtin.mode == .Debug) {
        const violations = try verify.verify(allocator, func);
        defer allocator.free(violations);
        std.debug.assert(violations.len == 0);
    }
    return sweeps;
}

// M0 no-op entry: enabled is false, so the middle-end never runs and codegen keeps its AST path. When
// the rollout begins (M1) this reads NOVA_OPT and, when set, drives the lowering + optimise + hand-off.
pub const enabled: bool = false;

pub fn run() void {
    // Intentionally empty at M0. Referenced so the module and its dependencies are compiled and checked.
    _ = &lower_ast_hir.lowerFunc;
    _ = &lower_hir_mir.lowerFunc;
    _ = &lower_mir_lir.lowerFunc;
    _ = hir.HirId.none;
    _ = mir.Value.invalid;
    _ = lir.Reg;
}
