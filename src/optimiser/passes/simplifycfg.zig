// simplifycfg.zig — control-flow graph simplification.
//
// Three real, safe transforms:
//  1. condbr with a constant condition -> br to the taken side (constfold makes conditions constant).
//  2. condbr whose two targets are the same block -> br.
//  3. dead-block elimination: drop blocks unreachable from entry, renumbering the remaining blocks and
//     rewriting every terminator's block references through an old->new map.
// Terminators reference blocks by index, so (3) does a proper renumber. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "simplifycfg", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return false;
    var changed = false;

    // Collect const_int values (to spot constant conditions).
    const nvalues = func.value_types.items.len;
    const konst = try allocator.alloc(?i64, nvalues);
    defer allocator.free(konst);
    @memset(konst, null);
    for (func.blocks.items) |b| {
        for (b.insts.items) |inst| {
            if (inst.op == .const_int and inst.result != .invalid) konst[@intFromEnum(inst.result)] = inst.op.const_int;
        }
    }

    // 1 + 2: simplify condbr terminators.
    for (func.blocks.items) |*b| {
        switch (b.term) {
            .condbr => |x| {
                if (x.then == x.else_) {
                    b.term = .{ .br = .{ .dest = x.then, .args = &.{} } };
                    changed = true;
                } else if (@intFromEnum(x.cond) < nvalues) {
                    if (konst[@intFromEnum(x.cond)]) |c| {
                        b.term = .{ .br = .{ .dest = if (c != 0) x.then else x.else_, .args = &.{} } };
                        changed = true;
                    }
                }
            },
            else => {},
        }
    }

    // 3: dead-block elimination. Skip if any switch_ is present -- its cases are an immutable slice we
    // cannot remap in place, and the lowering never emits switch_ today, so this stays sound.
    for (func.blocks.items) |b| {
        if (b.term == .switch_) return changed;
    }

    // Mark reachable from entry.
    const reachable = try allocator.alloc(bool, nblocks);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var stack = std.ArrayListUnmanaged(usize).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, @intFromEnum(func.entry));
    reachable[@intFromEnum(func.entry)] = true;
    while (stack.pop()) |bi| {
        for (successors(func.blocks.items[bi].term)) |succ| {
            const si = @intFromEnum(succ);
            if (si < nblocks and !reachable[si]) {
                reachable[si] = true;
                try stack.append(allocator, si);
            }
        }
    }

    var all_reachable = true;
    for (reachable) |r| {
        if (!r) {
            all_reachable = false;
            break;
        }
    }
    if (all_reachable) return changed;

    // Build old->new index map for the surviving blocks.
    const remap = try allocator.alloc(u32, nblocks);
    defer allocator.free(remap);
    var new_n: u32 = 0;
    for (0..nblocks) |i| {
        if (reachable[i]) {
            remap[i] = new_n;
            new_n += 1;
        } else {
            remap[i] = 0;
        }
    }

    // Compact the block list in place, freeing the dropped blocks' inst storage.
    var w: usize = 0;
    for (0..nblocks) |i| {
        if (reachable[i]) {
            func.blocks.items[w] = func.blocks.items[i];
            w += 1;
        } else {
            func.blocks.items[i].insts.deinit(allocator);
        }
    }
    func.blocks.items.len = w;
    func.entry = @enumFromInt(remap[@intFromEnum(func.entry)]);

    // Rewrite every terminator's block references through the remap.
    for (func.blocks.items) |*b| remapTerm(&b.term, remap);
    return true;
}

fn successors(term: mir.Terminator) [3]mir.Block {
    return switch (term) {
        .br => |x| .{ x.dest, x.dest, x.dest },
        .condbr => |x| .{ x.then, x.else_, x.else_ },
        .switch_ => |x| .{ x.default, x.default, x.default }, // cases handled below via remap; conservative reach
        else => .{ @enumFromInt(std.math.maxInt(u32)), @enumFromInt(std.math.maxInt(u32)), @enumFromInt(std.math.maxInt(u32)) },
    };
}

fn remapTerm(term: *mir.Terminator, remap: []const u32) void {
    switch (term.*) {
        .br => |*x| x.dest = @enumFromInt(remap[@intFromEnum(x.dest)]),
        .condbr => |*x| {
            x.then = @enumFromInt(remap[@intFromEnum(x.then)]);
            x.else_ = @enumFromInt(remap[@intFromEnum(x.else_)]);
        },
        .switch_ => |*x| x.default = @enumFromInt(remap[@intFromEnum(x.default)]),
        else => {},
    }
}
