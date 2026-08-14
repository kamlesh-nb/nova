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
        arc_imbalance, // retains/releases do not net to the ownership contract (dormant until ARC threaded)
    };
};

pub fn verify(allocator: std.mem.Allocator, func: *const mir.Func) ![]Error {
    var errs = std.ArrayListUnmanaged(Error).empty;
    errdefer errs.deinit(allocator);

    const nvalues = func.value_types.items.len;
    const nblocks = func.blocks.items.len;

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
