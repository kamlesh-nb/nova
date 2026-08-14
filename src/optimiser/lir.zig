// lir.zig — Low-level IR: linear, near-LLVM.
//
// LIR is MIR after the optimiser, with SSA block arguments resolved and every operation reduced to
// something that maps one-to-one onto an LLVMBuild* call. LIR exists so the backend is a dumb,
// mechanical translator: no ownership reasoning, no name mangling, no type decisions are left. The ARC
// and async operations stay explicit (they lower to nova_retain/nova_release runtime calls and LLVM
// coroutine intrinsics) but no further choices are made about them. See docs/design/optimiser.md.
// M0: definitions only.

const std = @import("std");
const types = @import("../frontend/types.zig");

pub const TypeId = types.TypeId;
pub const SymbolId = types.SymbolId;

pub const Reg = enum(u32) { _ };
pub const Label = enum(u32) { _ };

pub const BinOp = enum { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge, bit_and, bit_or, bit_xor, shl, shr };

// A linear op. After SSA resolution these run top-to-bottom within a labelled region; control flow is
// explicit jumps. This is intentionally close to the LLVM builder surface so lir_to_llvm is trivial.
pub const Op = union(enum) {
    // arithmetic / memory
    binop: struct { result: Reg, op: BinOp, lhs: Reg, rhs: Reg },
    load: struct { result: Reg, addr: Reg },
    store: struct { addr: Reg, val: Reg },
    alloc: struct { result: Reg, ty: TypeId },
    gep: struct { result: Reg, base: Reg, offset: u32 },
    cast: struct { result: Reg, val: Reg, to: TypeId },
    const_int: struct { result: Reg, val: i64 },
    param: struct { result: Reg, index: u32 }, // Nth function argument
    // calls
    call: struct { result: ?Reg, callee: SymbolId, args: []const Reg },
    indirect_call: struct { result: ?Reg, receiver: Reg, slot: u32, args: []const Reg },
    // ARC runtime calls (nova_retain / nova_release), emitted, not decided
    retain: struct { val: Reg },
    release: struct { val: Reg, dtor: ?SymbolId },
    // async (LLVM coroutine intrinsics)
    await_: struct { result: ?Reg, fut: Reg },
    spawn_: struct { result: Reg, callee: SymbolId, args: []const Reg },
    // control
    label: Label,
    jmp: Label,
    condjmp: struct { cond: Reg, then: Label, else_: Label },
    ret: ?Reg,
};

pub const Func = struct {
    sym: SymbolId,
    inst: ?TypeId = null,
    ops: std.ArrayListUnmanaged(Op) = .empty,
    reg_types: std.ArrayListUnmanaged(TypeId) = .empty,

    pub fn deinit(self: *Func, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.reg_types.deinit(allocator);
    }
};
