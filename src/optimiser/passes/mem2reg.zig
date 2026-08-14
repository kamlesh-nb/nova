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
    return changed;
}
