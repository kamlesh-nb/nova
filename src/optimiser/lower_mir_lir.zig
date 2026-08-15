// lower_mir_lir.zig — MIR (optimised) -> LIR (resolve the CFG into a linear op stream).
//
// After the optimiser, lower each MIR basic block to a LIR label followed by its instructions as
// near-LLVM ops, and its terminator as an explicit jmp / condjmp / ret. MIR Values map 1:1 to LIR Regs
// (our memory-based lowering produces no block-argument phis, so there is nothing to resolve here beyond
// the block->label mapping). LIR is the decision-free stream the backend emitter consumes: every op maps
// onto one LLVMBuild* call. See docs/design/optimiser.md.

const std = @import("std");
const mir = @import("mir.zig");
const lir = @import("lir.zig");

fn reg(v: mir.Value) lir.Reg {
    return @enumFromInt(@intFromEnum(v));
}
fn label(b: mir.Block) lir.Label {
    return @enumFromInt(@intFromEnum(b));
}

pub fn lowerFunc(allocator: std.mem.Allocator, func: mir.Func) !lir.Func {
    var lf = lir.Func{ .sym = func.sym, .inst = func.inst };
    errdefer lf.deinit(allocator);

    // Reg types mirror MIR value types 1:1.
    try lf.reg_types.appendSlice(allocator, func.value_types.items);

    for (func.blocks.items, 0..) |b, bi| {
        try lf.ops.append(allocator, .{ .label = label(@enumFromInt(@as(u32, @intCast(bi)))) });
        for (b.insts.items) |inst| try lowerInst(allocator, &lf, inst);
        try lowerTerm(allocator, &lf, b.term);
    }
    return lf;
}

fn lowerInst(allocator: std.mem.Allocator, lf: *lir.Func, inst: mir.Inst) !void {
    const r: ?lir.Reg = if (inst.result != .invalid) reg(inst.result) else null;
    switch (inst.op) {
        .binop => |x| try lf.ops.append(allocator, .{ .binop = .{ .result = r.?, .op = mapBin(x.op), .lhs = reg(x.lhs), .rhs = reg(x.rhs) } }),
        .load => |x| try lf.ops.append(allocator, .{ .load = .{ .result = r.?, .addr = reg(x.addr) } }),
        .store => |x| try lf.ops.append(allocator, .{ .store = .{ .addr = reg(x.addr), .val = reg(x.val) } }),
        .alloc => |x| try lf.ops.append(allocator, .{ .alloc = .{ .result = r.?, .ty = x.ty } }),
        .gep => |x| try lf.ops.append(allocator, .{ .gep = .{ .result = r.?, .base = reg(x.base), .offset = x.offset } }),
        .cast => |x| try lf.ops.append(allocator, .{ .cast = .{ .result = r.?, .val = reg(x.val), .to = inst.ty } }),
        // valopt_box/unbox are driven from MIR by the emit path (runtime nova_valopt_box/unbox calls); the
        // shadow LIR only needs a structural stand-in for the op count that preserves the value dependency.
        .valopt_box => |x| try lf.ops.append(allocator, .{ .cast = .{ .result = r.?, .val = reg(x.val), .to = inst.ty } }),
        .valopt_unbox => |x| try lf.ops.append(allocator, .{ .cast = .{ .result = r.?, .val = reg(x.val), .to = inst.ty } }),
        .const_int => |v| try lf.ops.append(allocator, .{ .const_int = .{ .result = r.?, .val = v } }),
        // The shadow LIR only needs a structural stand-in for the op count -- the emit path resolves the real
        // const via compiler.constants. Represent it as an opaque const_int 0 (its value is unknown here).
        .global_const => try lf.ops.append(allocator, .{ .const_int = .{ .result = r.?, .val = 0 } }),
        .const_str => try lf.ops.append(allocator, .{ .const_int = .{ .result = r.?, .val = 0 } }),
        .param => |i| try lf.ops.append(allocator, .{ .param = .{ .result = r.?, .index = i } }),
        // aggregates: the emit path drives these from MIR, so LIR only needs a structural stand-in for the
        // shadow's op count (alloc for the new object, load/store for a field access).
        .struct_new => try lf.ops.append(allocator, .{ .alloc = .{ .result = r.?, .ty = inst.ty } }),
        // tuple_new is a positional heap aggregate; the emit path drives it from MIR, so the shadow LIR only
        // needs a structural stand-in for the op count (the alloc of the new object).
        .tuple_new => try lf.ops.append(allocator, .{ .alloc = .{ .result = r.?, .ty = inst.ty } }),
        // `.template` is produced ONLY on the emit path (emit_mode), which drives emission from MIR and never
        // lowers to LIR -- so this arm is unreachable at runtime; keep a structural alloc stand-in for the
        // exhaustive switch (matching the aggregate placeholder the shadow uses).
        .template => try lf.ops.append(allocator, .{ .alloc = .{ .result = r.?, .ty = inst.ty } }),
        .field_get => |x| try lf.ops.append(allocator, .{ .load = .{ .result = r.?, .addr = reg(x.base) } }),
        // The shadow LIR only needs a structural stand-in for the op count; the emit path resolves the real
        // element address from the object's TypeId. Represent it as a load off the object register.
        .index_get => |x| try lf.ops.append(allocator, .{ .load = .{ .result = r.?, .addr = reg(x.object) } }),
        .field_set => |x| try lf.ops.append(allocator, .{ .store = .{ .addr = reg(x.base), .val = reg(x.val) } }),
        .call => |x| try lf.ops.append(allocator, .{ .call = .{ .result = r, .callee = x.callee, .args = try regs(allocator, x.args) } }),
        .indirect_call => |x| try lf.ops.append(allocator, .{ .indirect_call = .{ .result = r, .receiver = reg(x.receiver), .slot = x.slot, .args = try regs(allocator, x.args) } }),
        .retain => |x| try lf.ops.append(allocator, .{ .retain = .{ .val = reg(x.val) } }),
        .release => |x| try lf.ops.append(allocator, .{ .release = .{ .val = reg(x.val), .dtor = null } }),
        .await_ => |x| try lf.ops.append(allocator, .{ .await_ = .{ .result = r, .fut = reg(x.fut) } }),
        .spawn_ => |x| try lf.ops.append(allocator, .{ .spawn_ = .{ .result = r.?, .callee = x.callee, .args = try regs(allocator, x.args) } }),
    }
}

fn lowerTerm(allocator: std.mem.Allocator, lf: *lir.Func, term: mir.Terminator) !void {
    switch (term) {
        .br => |x| try lf.ops.append(allocator, .{ .jmp = label(x.dest) }),
        .condbr => |x| try lf.ops.append(allocator, .{ .condjmp = .{ .cond = reg(x.cond), .then = label(x.then), .else_ = label(x.else_) } }),
        .ret => |x| try lf.ops.append(allocator, .{ .ret = if (x) |v| reg(v) else null }),
        // a switch lowers to a chain of condjmps in the emitter; represent structurally as a jmp to default.
        .switch_ => |x| try lf.ops.append(allocator, .{ .jmp = label(x.default) }),
        .unreachable_ => try lf.ops.append(allocator, .{ .ret = null }),
    }
}

fn regs(allocator: std.mem.Allocator, vals: []const mir.Value) ![]const lir.Reg {
    const out = try allocator.alloc(lir.Reg, vals.len);
    for (vals, 0..) |v, i| out[i] = reg(v);
    return out;
}

fn mapBin(op: mir.BinOp) lir.BinOp {
    return switch (op) {
        .add => .add, .sub => .sub, .mul => .mul, .div => .div, .mod => .mod,
        .eq => .eq, .ne => .ne, .lt => .lt, .le => .le, .gt => .gt, .ge => .ge,
        .bit_and => .bit_and, .bit_or => .bit_or, .bit_xor => .bit_xor, .shl => .shl, .shr => .shr,
    };
}
