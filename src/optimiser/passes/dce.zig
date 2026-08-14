// dce.zig — dead-code elimination.
//
// Remove instructions whose result Value is never used as an operand anywhere and which have no
// observable side effect (a store/call/retain/release/await/spawn always stays). Iterating the pipeline
// exposes more: a retain whose only use was elided by ARC-elision becomes dead here. Value ids are never
// renumbered, so a removed instruction simply leaves its result unused; no fix-up is needed.
// See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "dce", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    const nvalues = func.value_types.items.len;
    if (nvalues == 0) return false;

    // Count uses of every Value across all instruction operands and terminators.
    const used = try allocator.alloc(bool, nvalues);
    defer allocator.free(used);
    @memset(used, false);

    for (func.blocks.items) |b| {
        for (b.insts.items) |inst| {
            var buf: [8]mir.Value = undefined;
            for (mir.instOperands(inst.op, &buf)) |v| used[@intFromEnum(v)] = true;
        }
        var tbuf: [2]mir.Value = undefined;
        for (mir.termOperands(b.term, &tbuf)) |v| used[@intFromEnum(v)] = true;
    }

    var changed = false;
    for (func.blocks.items) |*b| {
        var w: usize = 0; // write cursor for the compacted inst list
        for (b.insts.items) |inst| {
            const dead = inst.result != .invalid and
                !used[@intFromEnum(inst.result)] and
                !mir.hasSideEffects(inst.op);
            if (dead) {
                changed = true;
                continue; // drop it
            }
            b.insts.items[w] = inst;
            w += 1;
        }
        b.insts.items.len = w;
    }
    return changed;
}
