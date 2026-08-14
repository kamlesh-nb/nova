// lower_hir_mir.zig — HIR -> MIR (build the CFG; locals as memory).
//
// Structured lowering: walk the desugared HIR tree and emit a control-flow graph of basic blocks. Local
// variables (`let`) become memory slots (alloc + load/store), NOT SSA values directly -- the standard
// frontend approach that lets a later mem2reg pass build SSA and avoids phi construction here. Value-
// producing conditionals (if_expr, nullish) lower through a result slot. Terminators wire the blocks.
//
// This is STRUCTURAL MIR for the optimiser and its verifier: types are the placeholder id until the
// TypeId-threading checkpoint, and unresolved references (globals, params, functions) become opaque
// values. It is robust by construction (handles every HIR kind, never crashes) so it runs over the whole
// corpus via the shadow. See docs/design/optimiser.md.

const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

const HirId = hir.HirId;
const Value = mir.Value;
const Block = mir.Block;
const placeholder_ty: mir.TypeId = mir.unset_ty;

const Ctx = struct {
    allocator: std.mem.Allocator,
    hf: *const hir.Func,
    mf: *mir.Func,
    cur: Block,
    slots: std.StringHashMapUnmanaged(Value) = .empty, // local name -> alloc address value
    // innermost loop targets for break/continue; null outside a loop
    loop_header: ?Block = null,
    loop_exit: ?Block = null,

    fn deinit(self: *Ctx) void {
        self.slots.deinit(self.allocator);
    }
};

pub fn lowerFunc(allocator: std.mem.Allocator, func: hir.Func) !mir.Func {
    var mf = mir.Func{ .sym = func.sym orelse @enumFromInt(0), .inst = func.inst };
    errdefer mf.deinit(allocator);
    const entry = try mf.newBlock(allocator);
    mf.entry = entry;

    var ctx = Ctx{ .allocator = allocator, .hf = &func, .mf = &mf, .cur = entry };
    defer ctx.deinit();

    try lowerBlock(&ctx, func.entry);

    // Implicit `ret void` at the end of a void function. (Scope-end releases are already HIR `release`
    // nodes emitted by lower_ast_hir, so there is nothing to add here.)
    if (mf.block(ctx.cur).term == .unreachable_) mf.setTerm(ctx.cur, .{ .ret = null });
    return mf;
}

fn lowerBlock(ctx: *Ctx, block: hir.Block) !void {
    for (block.nodes) |id| {
        _ = try lowerNode(ctx, id);
        // A terminator (ret/break/continue) ends the block; anything after is dead in this structured form.
        if (mirTerminated(ctx)) break;
    }
}

fn mirTerminated(ctx: *Ctx) bool {
    return ctx.mf.block(ctx.cur).term != .unreachable_;
}

// Lower one HIR node. Returns a Value for value-producing nodes; for statements returns an invalid value.
fn lowerNode(ctx: *Ctx, id: HirId) anyerror!Value {
    if (id == HirId.none) return Value.invalid;
    const node = ctx.hf.get(id);
    const mf = ctx.mf;
    const a = ctx.allocator;
    // Use the node's real (sema-threaded) TypeId for the values it produces; fall back to the placeholder
    // only where sema could not type it. This carries real types into MIR (and thence LIR) for the emit path.
    const nty: mir.TypeId = if (node.ty == hir.unset_ty) placeholder_ty else node.ty;
    return switch (node.kind) {
        .int => |v| mf.emit(a, ctx.cur, nty, .{ .const_int = v }),
        .bool => |v| mf.emit(a, ctx.cur, nty, .{ .const_int = if (v) 1 else 0 }),
        // structural placeholders for non-integer literals (real materialisation is an emit-time concern)
        .float, .str, .null, .undefined => mf.emit(a, ctx.cur, nty, .{ .const_int = 0 }),

        .ident => |name| blk: {
            if (ctx.slots.get(name)) |addr| {
                break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = addr } });
            }
            // param / global / function reference: opaque value for the structural IR.
            break :blk try mf.emit(a, ctx.cur, nty, .{ .const_int = 0 });
        },

        .binop => |b| blk: {
            const lhs = try lowerNode(ctx, b.lhs);
            const rhs = try lowerNode(ctx, b.rhs);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .binop = .{ .op = mapBin(b.op), .lhs = lhs, .rhs = rhs } });
        },
        .unop => |u| blk: {
            const operand = try lowerNode(ctx, u.operand);
            // model unary as binop against a constant where convenient; structurally a cast-through.
            break :blk try mf.emit(a, ctx.cur, nty, .{ .cast = .{ .val = operand } });
        },
        .cast => |operand_id| blk: {
            const operand = try lowerNode(ctx, operand_id);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .cast = .{ .val = operand } });
        },

        .call => |c| try lowerCall(ctx, c.callee, c.args, c.sym),
        .generic_call => |c| try lowerCall(ctx, c.callee, c.args, c.sym),

        .field => |f| blk: {
            const object = try lowerNode(ctx, f.object);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .gep = .{ .base = object, .offset = 0 } });
        },
        .optional_chain => |oc| blk: {
            const object = try lowerNode(ctx, oc.object);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .gep = .{ .base = object, .offset = 0 } });
        },
        .index => |ix| blk: {
            const object = try lowerNode(ctx, ix.object);
            _ = try lowerNode(ctx, ix.idx);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = object } });
        },

        .struct_init => |si| try lowerAggregate(ctx, si.fields),
        .enum_init => |ei| try lowerAggregate(ctx, ei.fields),
        .tuple => |elems| try lowerAggregate(ctx, elems),
        .template => |parts| try lowerAggregate(ctx, parts),
        .range => |r| blk: {
            _ = try lowerNode(ctx, r.start);
            _ = try lowerNode(ctx, r.end);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .const_int = 0 });
        },
        .closure => mf.emit(a, ctx.cur, nty, .{ .const_int = 0 }),

        .await_ => |operand_id| blk: {
            const fut = try lowerNode(ctx, operand_id);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .await_ = .{ .fut = fut } });
        },
        .spawn_ => |operand_id| blk: {
            _ = try lowerNode(ctx, operand_id);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .spawn_ = .{ .callee = @enumFromInt(0), .args = &.{} } });
        },
        .try_ => |operand_id| lowerNode(ctx, operand_id),
        .retain => |operand_id| blk: {
            const v = try lowerNode(ctx, operand_id);
            try mf.emitVoid(a, ctx.cur, .{ .retain = .{ .val = v } });
            break :blk v;
        },
        .release => |operand_id| blk: {
            const v = try lowerNode(ctx, operand_id);
            try mf.emitVoid(a, ctx.cur, .{ .release = .{ .val = v } });
            break :blk Value.invalid;
        },

        // statements
        .let => |l| blk: {
            const addr = try mf.emit(a, ctx.cur, nty, .{ .alloc = .{ .ty = nty } });
            try ctx.slots.put(a, l.name, addr);
            if (l.value) |vid| {
                const v = try lowerNode(ctx, vid);
                try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = addr, .val = v } });
            }
            break :blk Value.invalid;
        },
        .assign => |asg| blk: {
            const v = try lowerNode(ctx, asg.value);
            // target is typically an ident (its slot) or a field address.
            const target_node = ctx.hf.get(asg.target);
            if (target_node.kind == .ident) {
                if (ctx.slots.get(target_node.kind.ident)) |addr| {
                    try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = addr, .val = v } });
                    break :blk Value.invalid;
                }
            }
            const addr = try lowerNode(ctx, asg.target);
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = addr, .val = v } });
            break :blk Value.invalid;
        },
        .ret => |vid| blk: {
            const rv: ?Value = if (vid) |x| try lowerNode(ctx, x) else null;
            mf.setTerm(ctx.cur, .{ .ret = rv });
            break :blk Value.invalid;
        },
        .brk => blk: {
            if (ctx.loop_exit) |ex| mf.setTerm(ctx.cur, .{ .br = .{ .dest = ex, .args = &.{} } });
            break :blk Value.invalid;
        },
        .cont => blk: {
            if (ctx.loop_header) |h| mf.setTerm(ctx.cur, .{ .br = .{ .dest = h, .args = &.{} } });
            break :blk Value.invalid;
        },
        .block => |b| blk: {
            try lowerBlock(ctx, b);
            break :blk Value.invalid;
        },
        .if_ => |iff| blk: {
            try lowerIf(ctx, iff.cond, iff.then, iff.else_, null);
            break :blk Value.invalid;
        },
        .if_expr => |ie| blk: {
            // value-producing: a result slot the arms store into, loaded at the merge.
            const slot = try mf.emit(a, ctx.cur, nty, .{ .alloc = .{ .ty = nty } });
            try lowerIfExpr(ctx, ie.cond, ie.then, ie.else_, slot);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = slot } });
        },
        .nullish => |nc| blk: {
            const slot = try mf.emit(a, ctx.cur, nty, .{ .alloc = .{ .ty = nty } });
            // a ?? b : evaluate a, store; a present-check would branch to b. Structural: store a then b path.
            const lhs = try lowerNode(ctx, nc.lhs);
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = lhs } });
            const rhs = try lowerNode(ctx, nc.rhs);
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = rhs } });
            break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = slot } });
        },
        .loop_ => |lp| blk: {
            try lowerLoop(ctx, lp.cond, lp.body);
            break :blk Value.invalid;
        },
        .unsupported => mf.emit(a, ctx.cur, nty, .{ .const_int = 0 }),
    };
}

// SymbolId 0xFFFF_FFFF marks an unresolved callee (the sema could not name the target).
pub const unresolved_callee: mir.SymbolId = @enumFromInt(0xFFFF_FFFF);

fn lowerCall(ctx: *Ctx, callee: HirId, call_args: []const HirId, sym: ?hir.SymbolId) !Value {
    const mf = ctx.mf;
    const a = ctx.allocator;
    var args = std.ArrayListUnmanaged(Value).empty;
    defer args.deinit(a);
    _ = try lowerNode(ctx, callee); // evaluate callee for effect/opaqueness
    for (call_args) |arg| try args.append(a, try lowerNode(ctx, arg));
    const owned = try a.dupe(Value, args.items);
    const owns = try a.alloc(bool, owned.len);
    @memset(owns, false);
    const target: mir.SymbolId = if (sym) |s| s else unresolved_callee;
    return mf.emit(a, ctx.cur, placeholder_ty, .{ .call = .{ .callee = target, .args = owned, .takes_ownership = owns } });
}

fn lowerAggregate(ctx: *Ctx, fields: []const HirId) !Value {
    for (fields) |f| _ = try lowerNode(ctx, f);
    return ctx.mf.emit(ctx.allocator, ctx.cur, placeholder_ty, .{ .alloc = .{ .ty = placeholder_ty } });
}

fn lowerIf(ctx: *Ctx, cond_id: HirId, then_b: hir.Block, else_b: hir.Block, merge_opt: ?Block) !void {
    const mf = ctx.mf;
    const a = ctx.allocator;
    const cond = try lowerNode(ctx, cond_id);
    const then_blk = try mf.newBlock(a);
    const has_else = else_b.nodes.len > 0;
    const else_blk = if (has_else) try mf.newBlock(a) else undefined;
    const merge = merge_opt orelse try mf.newBlock(a);

    mf.setTerm(ctx.cur, .{ .condbr = .{ .cond = cond, .then = then_blk, .else_ = if (has_else) else_blk else merge } });

    ctx.cur = then_blk;
    try lowerBlock(ctx, then_b);
    if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });

    if (has_else) {
        ctx.cur = else_blk;
        try lowerBlock(ctx, else_b);
        if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });
    }
    ctx.cur = merge;
}

// if_expr arms are single value nodes (not blocks); each stores its value into `slot`.
fn lowerIfExpr(ctx: *Ctx, cond_id: HirId, then_v: HirId, else_v: HirId, slot: Value) !void {
    const mf = ctx.mf;
    const a = ctx.allocator;
    const cond = try lowerNode(ctx, cond_id);
    const then_blk = try mf.newBlock(a);
    const else_blk = try mf.newBlock(a);
    const merge = try mf.newBlock(a);
    mf.setTerm(ctx.cur, .{ .condbr = .{ .cond = cond, .then = then_blk, .else_ = else_blk } });

    ctx.cur = then_blk;
    const tv = try lowerNode(ctx, then_v);
    try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = tv } });
    if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });

    ctx.cur = else_blk;
    const ev = try lowerNode(ctx, else_v);
    try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = ev } });
    if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });

    ctx.cur = merge;
}

fn lowerLoop(ctx: *Ctx, cond_id: ?HirId, body: hir.Block) !void {
    const mf = ctx.mf;
    const a = ctx.allocator;
    const header = try mf.newBlock(a);
    const body_blk = try mf.newBlock(a);
    const exit = try mf.newBlock(a);
    mf.setTerm(ctx.cur, .{ .br = .{ .dest = header, .args = &.{} } });

    ctx.cur = header;
    if (cond_id) |cid| {
        const cond = try lowerNode(ctx, cid);
        mf.setTerm(ctx.cur, .{ .condbr = .{ .cond = cond, .then = body_blk, .else_ = exit } });
    } else {
        mf.setTerm(ctx.cur, .{ .br = .{ .dest = body_blk, .args = &.{} } });
    }

    const saved_h = ctx.loop_header;
    const saved_e = ctx.loop_exit;
    ctx.loop_header = header;
    ctx.loop_exit = exit;
    ctx.cur = body_blk;
    try lowerBlock(ctx, body);
    if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = header, .args = &.{} } });
    ctx.loop_header = saved_h;
    ctx.loop_exit = saved_e;

    ctx.cur = exit;
}

fn mapBin(op: hir.BinOp) mir.BinOp {
    return switch (op) {
        .add => .add, .sub => .sub, .mul => .mul, .div => .div, .mod => .mod,
        .eq => .eq, .ne => .ne, .lt => .lt, .le => .le, .gt => .gt, .ge => .ge,
        .bit_and => .bit_and, .bit_or => .bit_or, .bit_xor => .bit_xor, .shl => .shl, .shr => .shr,
        .@"and" => .bit_and, .@"or" => .bit_or, .assign => .add, // assign handled before mapBin
    };
}
