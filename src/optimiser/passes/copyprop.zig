// copyprop.zig — copy propagation and algebraic identity simplification.
//
// Forwards a value through an operation that provably produces it unchanged, so downstream uses see the
// original value and the identity op becomes dead (dce removes it). With one operand a known constant
// (constfold runs first), the standard identities fire: x+0, x-0, x|0, x^0, x<<0, x>>0, x*1, x/1 -> x;
// and x*0 -> 0. Values are matched against `const_int` definitions collected in a forward sweep. Real
// arithmetic identities only; nothing that changes a result is rewritten. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "copyprop", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    const nvalues = func.value_types.items.len;
    if (nvalues == 0) return false;

    const konst = try allocator.alloc(?i64, nvalues);
    defer allocator.free(konst);
    @memset(konst, null);
    // The value that a const 0 is defined by (so x*0 -> 0 can forward to an existing zero).
    for (func.blocks.items) |b| {
        for (b.insts.items) |inst| {
            if (inst.op == .const_int and inst.result != .invalid) konst[@intFromEnum(inst.result)] = inst.op.const_int;
        }
    }

    var changed = false;
    for (func.blocks.items) |*b| {
        for (b.insts.items) |*inst| {
            if (inst.op != .binop or inst.result == .invalid) continue;
            const bin = inst.op.binop;
            const lk = konst[@intFromEnum(bin.lhs)];
            const rk = konst[@intFromEnum(bin.rhs)];

            // x <op> identity -> x
            if (rk) |rc| {
                if (isRightIdentity(bin.op, rc)) {
                    mir.replaceUses(func, inst.result, bin.lhs);
                    changed = true;
                    continue;
                }
                // x * 0 -> 0 : forward to the zero operand itself
                if (bin.op == .mul and rc == 0) {
                    mir.replaceUses(func, inst.result, bin.rhs);
                    changed = true;
                    continue;
                }
            }
            // identity <op> x -> x  (only for commutative ops)
            if (lk) |lc| {
                if (isCommutative(bin.op) and isRightIdentity(bin.op, lc)) {
                    mir.replaceUses(func, inst.result, bin.rhs);
                    changed = true;
                    continue;
                }
                if (bin.op == .mul and lc == 0) {
                    mir.replaceUses(func, inst.result, bin.lhs);
                    changed = true;
                }
            }
        }
    }
    return changed;
}

fn isRightIdentity(op: mir.BinOp, c: i64) bool {
    return switch (op) {
        .add, .sub, .bit_or, .bit_xor, .shl, .shr => c == 0,
        .mul, .div => c == 1,
        else => false,
    };
}

fn isCommutative(op: mir.BinOp) bool {
    return switch (op) {
        .add, .mul, .bit_or, .bit_xor, .bit_and, .eq, .ne => true,
        else => false,
    };
}
