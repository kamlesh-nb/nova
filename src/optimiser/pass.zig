// pass.zig — the optimiser pass interface and the fixpoint pipeline runner.
//
// A Pass is a small, single-responsibility rewrite over a mir.Func. Passes report whether they changed
// anything so the pipeline can iterate the fold -> dce -> simplify cycle to a bounded fixpoint. Each
// pass is verifiable in isolation on a small MIR fragment and, in debug builds, the verifier runs after
// every pass (driver.zig). See docs/design/optimiser.md. M0: interface + a no-op runner.

const std = @import("std");
const mir = @import("mir.zig");

pub const Pass = struct {
    name: []const u8,
    // Returns true if the function was modified. Purely local rewrites justified by SSA data-flow facts.
    run: *const fn (allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool,
};

// Run the pipeline to a bounded fixpoint: keep sweeping the passes until a full sweep makes no change,
// or max_iters is reached (a runaway backstop). Returns the number of sweeps performed.
pub fn runToFixpoint(allocator: std.mem.Allocator, func: *mir.Func, passes: []const Pass, max_iters: usize) !usize {
    var sweeps: usize = 0;
    while (sweeps < max_iters) : (sweeps += 1) {
        var changed = false;
        for (passes) |p| {
            if (try p.run(allocator, func)) changed = true;
        }
        if (!changed) break;
    }
    return sweeps;
}
