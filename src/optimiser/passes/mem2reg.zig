// mem2reg.zig — promote memory slots to SSA values (local, load-forwarding form).
//
// The lowering emits `let` locals as memory (alloc + store/load) so this pass builds SSA. The full form
// inserts phis using dominance; this first, always-safe form does intra-block load-forwarding: within a
// single block a `load` from a slot is replaced by the value most recently `store`d to that slot, when no
// intervening store or opaque call could have changed it. The now-dead loads are removed by dce. Stores
// and allocs are left in place (a later cross-block promotion removes them); nothing is removed here that
// could change behaviour. A slot whose address escapes (used as anything other than a load/store addr) is
// never forwarded. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "mem2reg", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    const nvalues = func.value_types.items.len;
    if (nvalues == 0) return false;

    // A slot (alloc result) is forwardable only if its address is used solely as a load/store addr.
    const escaped = try allocator.alloc(bool, nvalues);
    defer allocator.free(escaped);
    @memset(escaped, false);
    const is_slot = try allocator.alloc(bool, nvalues);
    defer allocator.free(is_slot);
    @memset(is_slot, false);

    for (func.blocks.items) |b| {
        for (b.insts.items) |inst| {
            if (inst.op == .alloc and inst.result != .invalid) is_slot[@intFromEnum(inst.result)] = true;
            // Any operand that is a slot address, appearing anywhere other than load.addr / store.addr,
            // marks that slot as escaped.
            var buf: [8]mir.Value = undefined;
            const ops = mir.instOperands(inst.op, &buf);
            for (ops) |v| {
                const legal = switch (inst.op) {
                    .load => |x| x.addr == v,
                    .store => |x| x.addr == v, // note: the stored *val* being a slot addr escapes it
                    else => false,
                };
                if (!legal) escaped[@intFromEnum(v)] = true;
            }
        }
        var tbuf: [2]mir.Value = undefined;
        for (mir.termOperands(b.term, &tbuf)) |v| escaped[@intFromEnum(v)] = true;
    }

    // Which block each slot is used in (as load/store addr). block_of[slot] = the single block index, or
    // sentinel "many" if it appears in more than one block. Used to fully promote single-block slots.
    const many = std.math.maxInt(u32);
    const block_of = try allocator.alloc(u32, nvalues);
    defer allocator.free(block_of);
    @memset(block_of, many - 1); // "unset"
    for (func.blocks.items, 0..) |b, bi| {
        for (b.insts.items) |inst| {
            const addr: ?mir.Value = switch (inst.op) {
                .load => |x| x.addr,
                .store => |x| x.addr,
                .alloc => inst.result,
                else => null,
            };
            if (addr) |v| {
                if (@intFromEnum(v) < nvalues and is_slot[@intFromEnum(v)]) {
                    const cur = block_of[@intFromEnum(v)];
                    if (cur == many - 1) block_of[@intFromEnum(v)] = @intCast(bi) else if (cur != bi) block_of[@intFromEnum(v)] = many;
                }
            }
        }
    }

    // Intra-block load-forwarding.
    var changed = false;
    // last[slot] = most recent stored value within the current block, or .invalid if unknown.
    const last = try allocator.alloc(mir.Value, nvalues);
    defer allocator.free(last);

    for (func.blocks.items) |*b| {
        @memset(last, mir.Value.invalid);
        for (b.insts.items) |inst| {
            switch (inst.op) {
                .store => |s| {
                    if (@intFromEnum(s.addr) < nvalues and is_slot[@intFromEnum(s.addr)] and !escaped[@intFromEnum(s.addr)]) {
                        last[@intFromEnum(s.addr)] = s.val;
                    }
                },
                .load => |l| {
                    if (inst.result != .invalid and @intFromEnum(l.addr) < nvalues and is_slot[@intFromEnum(l.addr)] and !escaped[@intFromEnum(l.addr)]) {
                        const lv = last[@intFromEnum(l.addr)];
                        if (lv != .invalid) {
                            mir.replaceUses(func, inst.result, lv);
                            changed = true;
                        }
                    }
                },
                // an opaque call may write through an aliased pointer -> conservatively forget everything
                .call, .indirect_call => @memset(last, mir.Value.invalid),
                else => {},
            }
        }
    }

    // Full promotion: a non-escaping slot confined to ONE block has had every load forwarded, so its
    // stores are dead-writes and its alloc is dead memory. Remove them (the forwarded loads are unused and
    // fall to dce). This clears false "escapes into a slot" that would otherwise block arc_elision.
    for (func.blocks.items) |*b| {
        var w: usize = 0;
        for (b.insts.items) |inst| {
            const slot: ?mir.Value = switch (inst.op) {
                .store => |x| x.addr,
                .alloc => inst.result,
                else => null,
            };
            if (slot) |s| {
                const si = @intFromEnum(s);
                if (si < nvalues and is_slot[si] and !escaped[si] and block_of[si] != many) {
                    changed = true;
                    continue; // drop the dead store / alloc
                }
            }
            b.insts.items[w] = inst;
            w += 1;
        }
        b.insts.items.len = w;
    }
    return changed;
}
