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

// "No type threaded here yet." TypeId 0 is a REAL type (`int`), so 0 cannot mean unset; this out-of-range
// value never collides with a real store index. Mirrors hir.unset_ty.
pub const unset_ty: TypeId = @enumFromInt(0xFFFF_FFFF);

// The sema TypeStore, set by the driver / emit path so passes (constfold) can resolve a TypeId's integer
// width and stay width-honest (Nova's `int` is 32-bit; folding at i64 would miscompile a chained overflow).
// Null when unset -> width-dependent folding is skipped (conservative, never wrong).
pub var type_store: ?*const types.TypeStore = null;

// Set true by the LIR emit path (lir_emit.zig) around its own HIR->MIR lowering, false for the NOVA_OPT
// shadow. It gates lowerings that produce a DEDICATED emit-path op (currently `.template`): the shadow keeps
// its structural placeholder so its op counts stay byte-identical, while the emit path gets a real op it can
// reproduce. Always reset (defer) by the setter so it never leaks into a subsequent shadow lowering.
pub var emit_mode: bool = false;

pub const IntWidth = struct { width: u16, signed: bool };

// Resolve `tid` to its integer machine width/signedness via the store, or null if not an int prim / no store.
pub fn intWidthOf(tid: TypeId) ?IntWidth {
    const st = type_store orelse return null;
    if (tid == unset_ty or @intFromEnum(tid) >= st.count()) return null;
    return switch (st.get(tid)) {
        .prim => |p| if (p.kind == .int) IntWidth{ .width = p.bits, .signed = p.signed } else null,
        else => null,
    };
}

// True if `tid` is a float primitive. Used to keep constfold from folding a float binop as an integer op
// (a float value flows as the i64 bit pattern of the double, so `l +% r` on two float const_ints would add
// the bit patterns -- garbage).
pub fn isFloatTy(tid: TypeId) bool {
    const st = type_store orelse return false;
    if (tid == unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return switch (st.get(tid)) {
        .prim => |p| p.kind == .float,
        else => false,
    };
}

// Wrap `v` into `width` bits (Nova's honest-int semantics): truncate, then sign- or zero-extend back to i64.
// This is the i64-domain twin of codegen's canonicalizeInt, so a folded constant equals the runtime result.
pub fn wrapToWidth(v: i64, width: u16, signed: bool) i64 {
    if (width == 0 or width >= 64) return v;
    if (signed) {
        const shift: u6 = @intCast(64 - width);
        const u = @as(u64, @bitCast(v)) << shift; // logical shift in the u64 domain (well-defined wrap)
        return @as(i64, @bitCast(u)) >> shift; // arithmetic shift sign-extends from bit (width-1)
    }
    const mask: u64 = (@as(u64, 1) << @intCast(width)) - 1;
    return @bitCast(@as(u64, @bitCast(v)) & mask);
}

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
        call: struct { callee: SymbolId, args: []Value, takes_ownership: []const bool, name: ?[]const u8 = null },
        // Dynamic dispatch through a trait fat pointer (D5). `receiver` is the trait-object word (a pointer
        // to a {struct_ptr, vtable} pair); `name` is the trait method's source name. The vtable slot is NOT
        // resolvable here (the optimiser has no trait table) -- `slot` stays a placeholder and the backend
        // resolves the real slot from the receiver's TypeId + trait declaration at emit time. `args` excludes
        // the receiver (the backend prepends struct_ptr as self, matching the AST calling convention).
        indirect_call: struct { receiver: Value, slot: u32, args: []Value, name: ?[]const u8 = null },
        cast: struct { val: Value },
        // ARC — first-class so the elision pass can see and cancel balanced pairs
        retain: struct { val: Value },
        release: struct { val: Value },
        // async
        await_: struct { fut: Value },
        spawn_: struct { callee: SymbolId, args: []Value },
        // constants materialised by const-folding
        const_int: i64,
        // A string literal (the raw source bytes). The emit path materialises it via
        // getOrCreateStringLiteral -> an IMMORTAL interned global (retain/release are no-ops on it), so it
        // needs no ARC. The shadow lowers it to a structural const_int 0 for op counts.
        const_str: []const u8,
        // A reference to a module-level `const` by name. Its VALUE is unknown to the optimiser (a const can
        // be a runtime-computed expression), so it is deliberately OPAQUE: the folding passes must not treat
        // it as any particular constant (that is the whole point -- lowering a global const to `const_int 0`
        // let constfold turn `x & MASK32` into 0). The emit path resolves it at emit time via
        // compiler.constants + compileConstRef (the same lazy-init global-load the AST path uses); mirEmittable
        // only accepts it when the named const is a scalar int/bool. The shadow lowers it to a structural
        // const_int 0 purely for op counts.
        global_const: []const u8,
        // function parameter N (its value is the Nth LLVM function argument)
        param: u32,
        // aggregates (emit path M6-D): atomic struct ops carrying the names a backend needs to resolve
        // layout (field offsets/widths) via the type store. struct_new allocates + initialises; field_get/
        // field_set read/write one field at its real width.
        struct_new: struct { type_name: []const u8, field_names: []const []const u8, args: []Value },
        field_get: struct { base: Value, field: []const u8 },
        field_set: struct { base: Value, field: []const u8, val: Value },
        // Element read `object[idx]`. The backend resolves the layout from the object's threaded TypeId: a
        // string indexes a byte (obj+idx, load i8, zext); an array GEPs the i64-word element base. Carries no
        // element type -- the emit path reads it from the TypeId (rejecting float-element arrays for now).
        index_get: struct { object: Value, idx: Value },
        // Tuple construction `(a, b, ...)`. A positional heap aggregate: N i64 words (nova_bytes_alloc),
        // element k at offset k*8, each arg stored as the raw i64 word (no per-field type). Distinct from
        // struct_new because a tuple has no named struct / field names -- the layout is purely positional.
        // The emit path gates it to all-scalar (int/bool) element tuples; owned-element tuples need element
        // ARC + a tuple destructor and stay on the AST.
        tuple_new: struct { args: []Value },
        // String interpolation `` `${a} text ${b}` `` (C5). Carries the ORDERED part values; every part is a
        // `string` (an interpolated string var OR a literal-text run materialised as a const_str). The emit
        // path reproduces the AST's StringBuilder lowering: alloc + StringBuilder_init, one StringBuilder_
        // append per part (append COPIES + BORROWS, so no per-part ARC), StringBuilder_toString (the owned
        // result), StringBuilder_delete, then nova_release(sb, null). Produced ONLY under `emit_mode` (the
        // shadow keeps the aggregate placeholder); mirEmittable admits it only when every part is a string.
        template: struct { parts: []Value },
    };
};

// Collect the Value operands an instruction reads into `buf`, returning the used slice. Callals/args are
// bounded in practice; long arg lists are truncated for the fixed buffer (analysis stays conservative).
pub fn instOperands(op: Inst.Op, buf: *[8]Value) []Value {
    var n: usize = 0;
    const push = struct {
        fn f(b: *[8]Value, i: *usize, v: Value) void {
            if (i.* < b.len and v != .invalid) {
                b[i.*] = v;
                i.* += 1;
            }
        }
    }.f;
    switch (op) {
        .binop => |x| {
            push(buf, &n, x.lhs);
            push(buf, &n, x.rhs);
        },
        .load => |x| push(buf, &n, x.addr),
        .store => |x| {
            push(buf, &n, x.addr);
            push(buf, &n, x.val);
        },
        .gep => |x| push(buf, &n, x.base),
        .cast => |x| push(buf, &n, x.val),
        .retain => |x| push(buf, &n, x.val),
        .release => |x| push(buf, &n, x.val),
        .await_ => |x| push(buf, &n, x.fut),
        .indirect_call => |x| {
            push(buf, &n, x.receiver);
            for (x.args) |arg| push(buf, &n, arg);
        },
        .call => |x| for (x.args) |arg| push(buf, &n, arg),
        .spawn_ => |x| for (x.args) |arg| push(buf, &n, arg),
        .struct_new => |x| for (x.args) |arg| push(buf, &n, arg),
        .field_get => |x| push(buf, &n, x.base),
        .field_set => |x| {
            push(buf, &n, x.base);
            push(buf, &n, x.val);
        },
        .index_get => |x| {
            push(buf, &n, x.object);
            push(buf, &n, x.idx);
        },
        .tuple_new => |x| for (x.args) |arg| push(buf, &n, arg),
        .template => |x| for (x.parts) |p| push(buf, &n, p),
        .alloc, .const_int, .const_str, .global_const, .param => {},
    }
    return buf[0..n];
}

pub fn termOperands(term: Terminator, buf: *[2]Value) []Value {
    switch (term) {
        .condbr => |x| {
            buf[0] = x.cond;
            return buf[0..1];
        },
        .switch_ => |x| {
            buf[0] = x.scrutinee;
            return buf[0..1];
        },
        .ret => |x| if (x) |v| {
            buf[0] = v;
            return buf[0..1];
        },
        else => {},
    }
    return buf[0..0];
}

// Rewrite every operand equal to `from` to `to`, across every instruction and terminator in the function.
// Used by copy propagation and load-forwarding. Definitions (results) are not touched.
pub fn replaceUses(func: *Func, from: Value, to: Value) void {
    for (func.blocks.items) |*b| {
        for (b.insts.items) |*inst| rewriteInst(&inst.op, from, to);
        rewriteTerm(&b.term, from, to);
    }
}

fn sw(v: *Value, from: Value, to: Value) void {
    if (v.* == from) v.* = to;
}

fn rewriteInst(op: *Inst.Op, from: Value, to: Value) void {
    switch (op.*) {
        .binop => |*x| {
            sw(&x.lhs, from, to);
            sw(&x.rhs, from, to);
        },
        .load => |*x| sw(&x.addr, from, to),
        .store => |*x| {
            sw(&x.addr, from, to);
            sw(&x.val, from, to);
        },
        .gep => |*x| sw(&x.base, from, to),
        .cast => |*x| sw(&x.val, from, to),
        .retain => |*x| sw(&x.val, from, to),
        .release => |*x| sw(&x.val, from, to),
        .await_ => |*x| sw(&x.fut, from, to),
        .indirect_call => |*x| {
            sw(&x.receiver, from, to);
            for (x.args) |*arg| sw(arg, from, to);
        },
        .call => |*x| for (x.args) |*arg| sw(arg, from, to),
        .spawn_ => |*x| for (x.args) |*arg| sw(arg, from, to),
        .struct_new => |*x| for (x.args) |*arg| sw(arg, from, to),
        .field_get => |*x| sw(&x.base, from, to),
        .field_set => |*x| {
            sw(&x.base, from, to);
            sw(&x.val, from, to);
        },
        .index_get => |*x| {
            sw(&x.object, from, to);
            sw(&x.idx, from, to);
        },
        .tuple_new => |*x| for (x.args) |*arg| sw(arg, from, to),
        .template => |*x| for (x.parts) |*p| sw(p, from, to),
        .alloc, .const_int, .const_str, .global_const, .param => {},
    }
}

fn rewriteTerm(term: *Terminator, from: Value, to: Value) void {
    switch (term.*) {
        .condbr => |*x| sw(&x.cond, from, to),
        .switch_ => |*x| sw(&x.scrutinee, from, to),
        .ret => |*x| if (x.*) |*v| sw(v, from, to),
        else => {},
    }
}

// True if the instruction has an observable effect and must not be removed even if its result is unused.
pub fn hasSideEffects(op: Inst.Op) bool {
    return switch (op) {
        .store, .call, .indirect_call, .retain, .release, .await_, .spawn_ => true,
        // struct_new / tuple_new allocate + write memory; field_set writes memory -> keep them.
        .struct_new, .tuple_new, .field_set => true,
        // template allocates a StringBuilder + calls into it -> observable, keep it even if the result is dead.
        .template => true,
        .binop, .load, .alloc, .gep, .cast, .const_int, .const_str, .global_const, .param, .field_get, .index_get => false,
    };
}

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

    // --- builder helpers ---

    pub fn newValue(self: *Func, allocator: std.mem.Allocator, ty: TypeId) !Value {
        const v: Value = @enumFromInt(self.value_types.items.len);
        try self.value_types.append(allocator, ty);
        return v;
    }

    pub fn newBlock(self: *Func, allocator: std.mem.Allocator) !Block {
        const b: Block = @enumFromInt(self.blocks.items.len);
        try self.blocks.append(allocator, .{});
        return b;
    }

    pub fn block(self: *Func, b: Block) *BasicBlock {
        return &self.blocks.items[@intFromEnum(b)];
    }

    // Append a value-producing instruction to block `b`; returns its result Value.
    pub fn emit(self: *Func, allocator: std.mem.Allocator, b: Block, ty: TypeId, op: Inst.Op) !Value {
        const v = try self.newValue(allocator, ty);
        try self.blocks.items[@intFromEnum(b)].insts.append(allocator, .{ .result = v, .ty = ty, .op = op });
        return v;
    }

    // Append a value-less instruction (store, release, ...) to block `b`.
    pub fn emitVoid(self: *Func, allocator: std.mem.Allocator, b: Block, op: Inst.Op) !void {
        try self.blocks.items[@intFromEnum(b)].insts.append(allocator, .{ .result = .invalid, .ty = unset_ty, .op = op });
    }

    pub fn setTerm(self: *Func, b: Block, term: Terminator) void {
        self.blocks.items[@intFromEnum(b)].term = term;
    }
};
