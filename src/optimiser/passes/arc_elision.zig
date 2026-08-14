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
    return cancelOverTraces(allocator, func);
}

// A position in the function: (block index, instruction index within that block).
const Pos = struct { b: usize, i: usize };

// Cross-block cancellation over straight-line TRACES. A trace is a maximal chain b0 -> b1 -> ... where
// each block ends in an unconditional `br` to the next and the next block has exactly one predecessor
// (so there is no branching or merge between them). Concatenating a trace's instructions and applying the
// within-block matching is sound: with no branch on the path, a retain(v) followed by a release(v) with
// no interleaved observer is balanced exactly as within a single block. This catches the common case of a
// retain in one block and the scope-end release in a straight-line successor. Branching regions still fall
// back to per-block cancellation (each block is its own length-1 trace).
fn cancelOverTraces(allocator: std.mem.Allocator, func: *mir.Func) !bool {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return false;

    const preds = try predCounts(allocator, func);
    defer allocator.free(preds);

    const in_trace = try allocator.alloc(bool, nblocks);
    defer allocator.free(in_trace);
    @memset(in_trace, false);

    var trace = std.ArrayListUnmanaged(usize).empty;
    defer trace.deinit(allocator);

    var changed = false;
    for (0..nblocks) |start| {
        if (in_trace[start]) continue;
        trace.clearRetainingCapacity();
        var cur = start;
        while (!in_trace[cur]) {
            in_trace[cur] = true;
            try trace.append(allocator, cur);
            switch (func.blocks.items[cur].term) {
                .br => |x| {
                    const dest = @intFromEnum(x.dest);
                    if (dest < nblocks and preds[dest] == 1 and !in_trace[dest]) {
                        cur = dest;
                        continue;
                    }
                },
                else => {},
            }
            break;
        }
        if (try cancelInTrace(allocator, func, trace.items)) changed = true;
    }
    return changed;
}

fn predCounts(allocator: std.mem.Allocator, func: *mir.Func) ![]u32 {
    const n = func.blocks.items.len;
    const preds = try allocator.alloc(u32, n);
    @memset(preds, 0);
    for (func.blocks.items) |b| {
        switch (b.term) {
            .br => |x| bump(preds, x.dest),
            .condbr => |x| {
                bump(preds, x.then);
                bump(preds, x.else_);
            },
            .switch_ => |x| {
                bump(preds, x.default);
                for (x.cases) |c| bump(preds, c.dest);
            },
            else => {},
        }
    }
    return preds;
}

fn bump(preds: []u32, b: mir.Block) void {
    const i = @intFromEnum(b);
    if (i < preds.len) preds[i] += 1;
}

// Match retains to releases over the flat instruction stream of a trace (blocks concatenated in order),
// then remove the cancelled pairs from their blocks.
fn cancelInTrace(allocator: std.mem.Allocator, func: *mir.Func, blocks: []const usize) !bool {
    // Flat list of positions across the trace.
    var flat = std.ArrayListUnmanaged(Pos).empty;
    defer flat.deinit(allocator);
    for (blocks) |bi| {
        for (0..func.blocks.items[bi].insts.items.len) |ii| try flat.append(allocator, .{ .b = bi, .i = ii });
    }
    const n = flat.items.len;
    if (n == 0) return false;

    const dead = try allocator.alloc(bool, n);
    defer allocator.free(dead);
    @memset(dead, false);

    var any = false;
    for (flat.items, 0..) |p, k| {
        if (dead[k]) continue;
        const inst = func.blocks.items[p.b].insts.items[p.i];
        if (inst.op != .retain) continue;
        const v = inst.op.retain.val;
        var m = k + 1;
        while (m < n) : (m += 1) {
            if (dead[m]) continue;
            const q = flat.items[m];
            const other = func.blocks.items[q.b].insts.items[q.i].op;
            if (other == .release and other.release.val == v) {
                dead[k] = true;
                dead[m] = true;
                any = true;
                break;
            }
            if (observesRef(other, v)) break;
        }
    }
    if (!any) return false;

    // Mark per-block which instruction indices are dead, then compact each block.
    for (blocks) |bi| {
        var w: usize = 0;
        for (func.blocks.items[bi].insts.items, 0..) |inst, ii| {
            var is_dead = false;
            for (flat.items, 0..) |p, k| {
                if (p.b == bi and p.i == ii and dead[k]) {
                    is_dead = true;
                    break;
                }
            }
            if (is_dead) continue;
            func.blocks.items[bi].insts.items[w] = inst;
            w += 1;
        }
        func.blocks.items[bi].insts.items.len = w;
    }
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
