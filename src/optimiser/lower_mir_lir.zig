// lower_mir_lir.zig — MIR (optimised) -> LIR (resolve SSA, linearise).
//
// Resolve SSA block arguments into a linear op stream and reduce every MIR instruction to a near-LLVM
// LIR op, so the backend emitter is a mechanical 1:1 translation. See docs/design/optimiser.md. M0: stub.

const std = @import("std");
const mir = @import("mir.zig");
const lir = @import("lir.zig");

pub fn lowerFunc(allocator: std.mem.Allocator, func: mir.Func) !lir.Func {
    _ = allocator;
    return lir.Func{ .sym = func.sym, .inst = func.inst };
}
