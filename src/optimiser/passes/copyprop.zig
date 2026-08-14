// copyprop.zig — Copy propagation and redundant-load elimination; exposes more ARC-elision opportunities.
// See docs/design/optimiser.md. M0: registered no-op (returns false = no change) until M3/M4.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "copyprop", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    _ = allocator;
    _ = func;
    return false;
}
