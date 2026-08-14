// lower_hir_mir.zig — HIR -> MIR (build the CFG, go into SSA).
//
// Flatten the desugared HIR tree into basic blocks, thread control flow into a CFG, and construct SSA
// (block arguments at joins). After this, retain/release are SSA instructions the optimiser can reason
// about. See docs/design/optimiser.md. M0: stub.

const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

pub fn lowerFunc(allocator: std.mem.Allocator, func: hir.Func) !mir.Func {
    _ = allocator;
    return mir.Func{ .sym = func.sym, .inst = func.inst };
}
