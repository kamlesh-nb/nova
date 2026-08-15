// constfold.zig — constant folding and propagation.
//
// Fold a binop whose operands are both `const_int` into a single `const_int`, and record the mapping so
// downstream uses see the constant (copy propagation). Value ids are stable, so folding rewrites the
// instruction in place to `const_int` and lets dce remove any now-dead feeders. Real arithmetic only
// (add/sub/mul/div/mod, comparisons, bitops, shifts); division by zero is left unfolded (kept as-is so
// the runtime semantics are unchanged). See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("../mir.zig");
const Pass = @import("../pass.zig").Pass;

pub const pass = Pass{ .name = "constfold", .run = run };

fn run(allocator: std.mem.Allocator, func: *mir.Func) anyerror!bool {
    const nvalues = func.value_types.items.len;
    if (nvalues == 0) return false;

    // Value -> known constant (if any).
    const konst = try allocator.alloc(?i64, nvalues);
    defer allocator.free(konst);
    @memset(konst, null);

    var changed = false;
    // Single forward sweep: SSA + the lowering emits definitions before uses within a block, and const
    // feeders precede the binop, so one pass folds the common chains; the pipeline fixpoint catches the rest.
    for (func.blocks.items) |*b| {
        for (b.insts.items) |*inst| {
            switch (inst.op) {
                .const_int => |v| if (inst.result != .invalid) {
                    konst[@intFromEnum(inst.result)] = v;
                },
                .binop => |bin| {
                    const lk = konst[@intFromEnum(bin.lhs)];
                    const rk = konst[@intFromEnum(bin.rhs)];
                    // NEVER fold a float binop: a float const_int holds the double's BIT PATTERN, so the
                    // integer `fold` (l +% r) would add bit patterns -> garbage. Float const-folding would
                    // need real FP arithmetic; the emit path materialises the operands instead.
                    if (lk != null and rk != null and !mir.isFloatTy(inst.ty) and
                        !mir.isFloatTy(func.typeOf(bin.lhs)) and !mir.isFloatTy(func.typeOf(bin.rhs)))
                    {
                        if (fold(bin.op, lk.?, rk.?)) |raw| {
                            // Width-honesty: Nova's `int` is 32-bit, so a folded arithmetic result must wrap
                            // to the RESULT type's width exactly as the runtime does (codegen's
                            // canonicalizeInt). Folding purely at i64 would miscompile a chained overflow such
                            // as `(2e9 + 2e9) >> 20`. If the result type's width is unknown (no store / not an
                            // int prim, e.g. a bool compare result), leave the raw fold -- it is already 0/1.
                            const result = if (mir.intWidthOf(inst.ty)) |w| mir.wrapToWidth(raw, w.width, w.signed) else raw;
                            inst.op = .{ .const_int = result };
                            if (inst.result != .invalid) konst[@intFromEnum(inst.result)] = result;
                            changed = true;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return changed;
}

fn fold(op: mir.BinOp, l: i64, r: i64) ?i64 {
    return switch (op) {
        .add => l +% r,
        .sub => l -% r,
        .mul => l *% r,
        .div => if (r == 0) null else @divTrunc(l, r),
        .mod => if (r == 0) null else @rem(l, r),
        .eq => @intFromBool(l == r),
        .ne => @intFromBool(l != r),
        .lt => @intFromBool(l < r),
        .le => @intFromBool(l <= r),
        .gt => @intFromBool(l > r),
        .ge => @intFromBool(l >= r),
        .bit_and => l & r,
        .bit_or => l | r,
        .bit_xor => l ^ r,
        .shl => if (r < 0 or r >= 64) null else l << @intCast(r),
        .shr => if (r < 0 or r >= 64) null else l >> @intCast(r),
    };
}
