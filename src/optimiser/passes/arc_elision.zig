// arc_elision.zig — THE headline pass: cancel balanced retain/release pairs, forward owned temporaries into +1 sinks (move), skip retains on pure borrows, sink releases to last-use. Conservative by construction; keep when the data flow is not certain.
// See docs/design/optimiser.md. M0: registered no-op (returns false = no change) until M3/M4.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "arc_elision", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    _ = allocator;
    _ = func;
    return false;
}
