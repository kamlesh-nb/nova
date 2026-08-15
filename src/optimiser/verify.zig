// verify.zig — the MIR verifier (M2).
//
// Runs after lowering and after every pass (driver). Checks the invariants that keep the optimiser
// honest: every block is terminated; terminator targets are valid blocks; every operand Value is defined
// (in range); results are in range. The ARC-balance check (retains and releases net to a value's
// ownership contract) activates once explicit ARC ops are threaded in; until then there are none to
// check. A violation is reported, not silently tolerated. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("mir.zig");

pub const Error = struct {
    kind: Kind,
    block: u32,
    detail: []const u8,

    pub const Kind = enum {
        not_terminated, // a block whose terminator was never set
        bad_block_target, // a terminator jumps to a non-existent block
        use_out_of_range, // an operand Value id is >= the number of defined values
        result_out_of_range, // an instruction result id is out of range
        use_before_def, // an operand is used before (or without) its defining instruction in program order
        arc_imbalance, // retains/releases do not net to the ownership contract (dormant until ARC threaded)
    };
};

pub fn verify(allocator: std.mem.Allocator, func: *const mir.Func) ![]Error {
    var errs = std.ArrayListUnmanaged(Error).empty;
    errdefer errs.deinit(allocator);

    const nvalues = func.value_types.items.len;
    const nblocks = func.blocks.items.len;

    // Program-order definition position of each value (block-major, then instruction index), for the
    // use-before-def check below. The emit path's MIR flows values forward only (cross-block values live in
    // memory via alloc/load/store, no back-edge SSA), so a valid def always precedes its use in this order.
    // A value never defined stays at `undefined_pos` and any use of it is flagged. This is what would have
    // caught the M6-C dangling load (a load promoted away while a use survived).
    const undefined_pos: u64 = std.math.maxInt(u64);
    const def_pos = allocator.alloc(u64, nvalues) catch return errs.toOwnedSlice(allocator);
    defer allocator.free(def_pos);
    @memset(def_pos, undefined_pos);
    for (func.blocks.items, 0..) |b, bi| {
        for (b.insts.items, 0..) |inst, ii| {
            if (inst.result != .invalid and @intFromEnum(inst.result) < nvalues) {
                def_pos[@intFromEnum(inst.result)] = (@as(u64, @intCast(bi)) << 32) | @as(u64, @intCast(ii));
            }
        }
    }

    for (func.blocks.items, 0..) |b, bi| {
        for (b.insts.items, 0..) |inst, ii| {
            const use_pos = (@as(u64, @intCast(bi)) << 32) | @as(u64, @intCast(ii));
            var ubuf: [8]mir.Value = undefined;
            for (mir.instOperands(inst.op, &ubuf)) |v| {
                if (@intFromEnum(v) >= nvalues) continue; // already flagged out-of-range below
                if (def_pos[@intFromEnum(v)] >= use_pos) {
                    try errs.append(allocator, .{ .kind = .use_before_def, .block = @intCast(bi), .detail = "operand used before its definition" });
                }
            }
        }
    }

    for (func.blocks.items, 0..) |b, bi| {
        // 1. every instruction's operands and result are in range
        for (b.insts.items) |inst| {
            var buf: [8]mir.Value = undefined;
            for (mir.instOperands(inst.op, &buf)) |v| {
                if (@intFromEnum(v) >= nvalues) try errs.append(allocator, .{ .kind = .use_out_of_range, .block = @intCast(bi), .detail = "operand value out of range" });
            }
            if (inst.result != .invalid and @intFromEnum(inst.result) >= nvalues) {
                try errs.append(allocator, .{ .kind = .result_out_of_range, .block = @intCast(bi), .detail = "result value out of range" });
            }
        }

        // 2. the block is terminated, and its terminator's operands + targets are valid
        switch (b.term) {
            .unreachable_ => try errs.append(allocator, .{ .kind = .not_terminated, .block = @intCast(bi), .detail = "block has no terminator" }),
            .br => |x| if (@intFromEnum(x.dest) >= nblocks) try errs.append(allocator, .{ .kind = .bad_block_target, .block = @intCast(bi), .detail = "br to invalid block" }),
            .condbr => |x| {
                if (@intFromEnum(x.then) >= nblocks or @intFromEnum(x.else_) >= nblocks)
                    try errs.append(allocator, .{ .kind = .bad_block_target, .block = @intCast(bi), .detail = "condbr to invalid block" });
            },
            .switch_ => |x| {
                if (@intFromEnum(x.default) >= nblocks) try errs.append(allocator, .{ .kind = .bad_block_target, .block = @intCast(bi), .detail = "switch default invalid" });
                for (x.cases) |c| if (@intFromEnum(c.dest) >= nblocks) try errs.append(allocator, .{ .kind = .bad_block_target, .block = @intCast(bi), .detail = "switch case invalid" });
            },
            .ret => {},
        }
        var tbuf: [2]mir.Value = undefined;
        for (mir.termOperands(b.term, &tbuf)) |v| {
            if (@intFromEnum(v) >= nvalues) try errs.append(allocator, .{ .kind = .use_out_of_range, .block = @intCast(bi), .detail = "terminator operand out of range" });
        }
    }

    return errs.toOwnedSlice(allocator);
}
