// arc_elision.zig — the headline pass: cancel balanced retain/release pairs.
//
// When a `retain v` is followed, within the same block, by a `release v` with no intervening operation
// that relies on the extra reference -- no store of v, no call/spawn/return that could capture or consume
// v, no other retain/release of v -- the pair is balanced and both are removed. Conservative by
// construction: any uncertainty keeps the pair (a wrongly-removed retain is a use-after-free that ASAN
// catches; a kept redundant one is merely slow). This is the local cancellation move; motion into +1
// sinks, borrow-skip and release-sink build on the same analysis.
//
// DORMANT on real code today: HIR does not yet thread explicit retain/release (that needs the ownership
// pass reading TypedIr.expr_owned). The algorithm is implemented and unit-tested here so it is correct
// and ready the moment ARC ops are threaded. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "arc_elision", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    var changed = false;
    for (func.blocks.items) |*b| {
        if (try cancelInBlock(allocator, b)) changed = true;
    }
    return changed;
}

// Returns true if any pair was cancelled in this block. Marks the paired retain and release for removal
// and compacts the instruction list.
fn cancelInBlock(allocator: std.mem.Allocator, b: *mir.BasicBlock) !bool {
    const n = b.insts.items.len;
    if (n == 0) return false;
    const dead = try allocator.alloc(bool, n);
    defer allocator.free(dead);
    @memset(dead, false);

    var any = false;
    // For each retain, scan forward for a cancelling release of the same value.
    for (b.insts.items, 0..) |inst, i| {
        if (dead[i] or inst.op != .retain) continue;
        const v = inst.op.retain.val;
        var j = i + 1;
        while (j < n) : (j += 1) {
            if (dead[j]) continue;
            const other = b.insts.items[j].op;
            if (other == .release and other.release.val == v) {
                dead[i] = true;
                dead[j] = true;
                any = true;
                break;
            }
            if (observesRef(other, v)) break; // something relies on the +1; keep the pair
        }
    }
    if (!any) return false;

    var w: usize = 0;
    for (b.insts.items, 0..) |inst, i| {
        if (dead[i]) continue;
        b.insts.items[w] = inst;
        w += 1;
    }
    b.insts.items.len = w;
    return true;
}

// True if `op` could rely on the extra reference to `v` (so a retain before it must not be cancelled):
// a store of v, a call/spawn passing v, an indirect_call receiver/arg of v, or another retain/release of v.
fn observesRef(op: mir.Inst.Op, v: mir.Value) bool {
    return switch (op) {
        .store => |x| x.val == v,
        .retain => |x| x.val == v,
        .release => |x| x.val == v,
        .call => |x| containsV(x.args, v),
        .spawn_ => |x| containsV(x.args, v),
        .indirect_call => |x| x.receiver == v or containsV(x.args, v),
        else => false,
    };
}

fn containsV(args: []const mir.Value, v: mir.Value) bool {
    for (args) |a| if (a == v) return true;
    return false;
}

// --- unit tests: the algorithm is correct even though it is dormant on today's real code ---

test "cancels an adjacent retain/release of the same value" {
    const a = std.testing.allocator;
    var f = mir.Func{ .sym = @enumFromInt(0) };
    defer f.deinit(a);
    const b = try f.newBlock(a);
    const v = try f.newValue(a, @enumFromInt(0));
    try f.emitVoid(a, b, .{ .retain = .{ .val = v } });
    try f.emitVoid(a, b, .{ .release = .{ .val = v } });
    f.setTerm(b, .{ .ret = null });

    const ch = try run(a, &f);
    try std.testing.expect(ch);
    try std.testing.expectEqual(@as(usize, 0), f.block(b).insts.items.len);
}

test "keeps a retain/release straddling a store of the value" {
    const a = std.testing.allocator;
    var f = mir.Func{ .sym = @enumFromInt(0) };
    defer f.deinit(a);
    const b = try f.newBlock(a);
    const v = try f.newValue(a, @enumFromInt(0));
    const slot = try f.newValue(a, @enumFromInt(0));
    try f.emitVoid(a, b, .{ .retain = .{ .val = v } });
    try f.emitVoid(a, b, .{ .store = .{ .addr = slot, .val = v } }); // v escapes into memory
    try f.emitVoid(a, b, .{ .release = .{ .val = v } });
    f.setTerm(b, .{ .ret = null });

    const ch = try run(a, &f);
    try std.testing.expect(!ch);
    try std.testing.expectEqual(@as(usize, 3), f.block(b).insts.items.len);
}
