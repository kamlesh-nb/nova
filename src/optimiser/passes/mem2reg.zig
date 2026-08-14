// mem2reg.zig — Promote non-escaping address-taken locals into SSA values. The enabler for all data-flow passes.
// See docs/design/optimiser.md. M0: registered no-op (returns false = no change) until M3/M4.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "mem2reg", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    _ = allocator;
    _ = func;
    return false;
}
