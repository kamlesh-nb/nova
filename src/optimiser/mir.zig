// mir.zig — Mid-level IR: SSA over a control-flow graph.
//
// MIR is where the optimiser works. Each function is a CFG of basic blocks; each instruction defines at
// most one Value (SSA virtual register); block arguments merge values at joins (our phi spelling).
// Instructions are typed and include the Nova operations that must survive to the backend: retain,
// release, alloc, load/store, call, indirect_call (trait dispatch), await, spawn. SSA is what makes
// ARC-elision, DCE, const-prop and copy-prop near-trivial. See docs/design/optimiser.md. M0: defs only.

const std = @import("std");
const types = @import("../frontend/types.zig");

pub const TypeId = types.TypeId;
pub const SymbolId = types.SymbolId;

pub const Value = enum(u32) { invalid = 0xFFFF_FFFF, _ };
pub const Block = enum(u32) { _ };

pub const BinOp = enum { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge, bit_and, bit_or, bit_xor, shl, shr };

pub const Inst = struct {
    result: Value, // .invalid for a value-less instruction (e.g. store, release)
    ty: TypeId,
    op: Op,

    pub const Op = union(enum) {
        binop: struct { op: BinOp, lhs: Value, rhs: Value },
        load: struct { addr: Value },
        store: struct { addr: Value, val: Value },
        alloc: struct { ty: TypeId },
        gep: struct { base: Value, offset: u32 }, // field / element address
        call: struct { callee: SymbolId, args: []const Value, takes_ownership: []const bool },
        indirect_call: struct { receiver: Value, slot: u32, args: []const Value },
        cast: struct { val: Value },
        // ARC — first-class so the elision pass can see and cancel balanced pairs
        retain: struct { val: Value },
        release: struct { val: Value },
        // async
        await_: struct { fut: Value },
        spawn_: struct { callee: SymbolId, args: []const Value },
        // constants materialised by const-folding
        const_int: i64,
    };
};

pub const Terminator = union(enum) {
    br: struct { dest: Block, args: []const Value },
    condbr: struct { cond: Value, then: Block, else_: Block },
    switch_: struct { scrutinee: Value, cases: []const Case, default: Block },
    ret: ?Value,
    unreachable_: void,

    pub const Case = struct { val: i64, dest: Block };
};

pub const BasicBlock = struct {
    params: []const Value = &.{}, // block arguments (phis)
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    term: Terminator = .unreachable_,
};

pub const Func = struct {
    sym: SymbolId,
    inst: ?TypeId = null,
    blocks: std.ArrayListUnmanaged(BasicBlock) = .empty,
    value_types: std.ArrayListUnmanaged(TypeId) = .empty, // Value -> TypeId, indexed by @intFromEnum
    entry: Block = @enumFromInt(0),

    pub fn deinit(self: *Func, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*b| b.insts.deinit(allocator);
        self.blocks.deinit(allocator);
        self.value_types.deinit(allocator);
    }

    pub fn typeOf(self: *const Func, v: Value) TypeId {
        return self.value_types.items[@intFromEnum(v)];
    }
};
