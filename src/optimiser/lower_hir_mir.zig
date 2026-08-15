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
const types = @import("../frontend/types.zig");

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
    // B6: the function returns a scalar value-optional; a scalar `.ret` operand is boxed (valopt_box).
    ret_valopt: bool = false,

    fn deinit(self: *Ctx) void {
        self.slots.deinit(self.allocator);
    }
};

pub fn lowerFunc(allocator: std.mem.Allocator, func: hir.Func) !mir.Func {
    var mf = mir.Func{ .sym = func.sym orelse @enumFromInt(0), .inst = func.inst };
    errdefer mf.deinit(allocator);
    const entry = try mf.newBlock(allocator);
    mf.entry = entry;

    var ctx = Ctx{ .allocator = allocator, .hf = &func, .mf = &mf, .cur = entry, .ret_valopt = func.ret_valopt };
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
        .param => |i| mf.emit(a, ctx.cur, nty, .{ .param = i }),
        // structural placeholders for non-integer literals (real materialisation is an emit-time concern)
        .str => |s| mf.emit(a, ctx.cur, nty, .{ .const_str = s }),
        // A float literal flows as the double's bit pattern in the i64 word (the emit path bitcasts to double
        // for ops). Carry the bits in const_int; its FLOAT type keeps constfold from folding it as an integer.
        .float => |fv| mf.emit(a, ctx.cur, nty, .{ .const_int = @as(i64, @bitCast(fv)) }),
        .null, .undefined => mf.emit(a, ctx.cur, nty, .{ .const_int = 0 }),

        .ident => |name| blk: {
            if (ctx.slots.get(name)) |addr| {
                break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = addr } });
            }
            // Not a local slot: a module-level const, a bare function reference, or a capture. Carry the
            // NAME as an OPAQUE global_const so (a) the emit path can resolve a scalar const via
            // compiler.constants (mirEmittable rejects a non-const / non-scalar name -> AST fallback), and
            // (b) the folding passes never treat it as a known value. Lowering it to `const_int 0` instead
            // miscompiled every `& MASK32` in the crypto stdlib (constfold folded `x & 0` -> 0).
            break :blk try mf.emit(a, ctx.cur, nty, .{ .global_const = name });
        },

        .binop => |b| blk: {
            const lhs = try lowerNode(ctx, b.lhs);
            const rhs = try lowerNode(ctx, b.rhs);
            // Result-type recovery: an arithmetic/bitwise/shift binop's result has the SAME type as its
            // operands. Sema leaves the result UNRESOLVED whenever a sub-expression was unresolved -- notably
            // `t.k` tuple-element access, whose type sema does not thread (see the .index case). When that
            // happens, take the (now-resolved) lhs operand type so the emit path's result-width gate sees a
            // concrete int. Only fires for a genuinely unresolved result on a same-type op -- resolved nodes
            // and comparisons (whose result is bool, not the operand type) are untouched, so no behaviour
            // changes for anything sema already typed.
            const rty = inferSameTypeResult(ctx, b.op, nty, lhs);
            break :blk try mf.emit(a, ctx.cur, rty, .{ .binop = .{ .op = mapBin(b.op), .lhs = lhs, .rhs = rhs } });
        },
        .unop => |u| blk: {
            const operand = try lowerNode(ctx, u.operand);
            const oty = mf.typeOf(operand);
            // A unary op is NOT a cast-through -- lowering it that way silently DROPS the operator (e.g.
            // `-x` became `x`, miscompiling every negative literal). Model each as its exact binop identity
            // so the emit path reproduces the AST semantics (and constfold folds the constant forms):
            //   neg     -> 0 - x        (sub, canonicalised to the result width by emitBinop)
            //   bit_not -> x ^ -1       (bitwise, representation-preserving)
            //   not     -> x == 0       (logical, on a bool operand)
            break :blk switch (u.op) {
                .neg => neg: {
                    const zero = try mf.emit(a, ctx.cur, oty, .{ .const_int = 0 });
                    break :neg try mf.emit(a, ctx.cur, nty, .{ .binop = .{ .op = .sub, .lhs = zero, .rhs = operand } });
                },
                .bit_not => bn: {
                    const allones = try mf.emit(a, ctx.cur, oty, .{ .const_int = -1 });
                    break :bn try mf.emit(a, ctx.cur, nty, .{ .binop = .{ .op = .bit_xor, .lhs = operand, .rhs = allones } });
                },
                .not => ln: {
                    const zero = try mf.emit(a, ctx.cur, oty, .{ .const_int = 0 });
                    break :ln try mf.emit(a, ctx.cur, nty, .{ .binop = .{ .op = .eq, .lhs = operand, .rhs = zero } });
                },
            };
        },
        .cast => |operand_id| blk: {
            const operand = try lowerNode(ctx, operand_id);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .cast = .{ .val = operand } });
        },

        .call => |c| try lowerCall(ctx, c.callee, c.args, c.sym, nty),
        .generic_call => |c| try lowerCall(ctx, c.callee, c.args, c.sym, nty),

        .field => |f| blk: {
            const object = try lowerNode(ctx, f.object);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .field_get = .{ .base = object, .field = f.name } });
        },
        .optional_chain => |oc| blk: {
            // `a?.b` == `a == null ? null : a.b`. For a REFERENCE optional `a` (nullable pointer word), branch
            // on `a != 0`: present -> read the field; absent -> null (0). The result defaults to 0 on the
            // absent path, which is correct ONLY when the whole `a?.b` is itself a REFERENCE optional (0 ==
            // absent). When `a.b` is a value-type field, `a?.b` is a boxed VALUE optional (`int | undefined`),
            // whose absent sentinel is NOT 0 -- so this lowering would miscompile it; the emit path's value-
            // optional gate rejects any value-optional-typed result and the whole function falls back to the
            // AST (which boxes). The field_get gate additionally rejects non-scalar (reference) fields, so a
            // reference-field chain (whose result WOULD be a ref optional) also currently falls back. This
            // lowering is therefore correct for any case the gates admit, and safe (fallback) for the rest.
            const object = try lowerNode(ctx, oc.object);
            const obj_ty = mf.typeOf(object);
            const slot = try mf.emit(a, ctx.cur, nty, .{ .alloc = .{ .ty = nty } });
            const zero_res = try mf.emit(a, ctx.cur, nty, .{ .const_int = 0 });
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = zero_res } }); // absent default = null
            const zero = try mf.emit(a, ctx.cur, obj_ty, .{ .const_int = 0 });
            const present = try mf.emit(a, ctx.cur, obj_ty, .{ .binop = .{ .op = .ne, .lhs = object, .rhs = zero } });
            const then_blk = try mf.newBlock(a);
            const merge = try mf.newBlock(a);
            mf.setTerm(ctx.cur, .{ .condbr = .{ .cond = present, .then = then_blk, .else_ = merge } });
            ctx.cur = then_blk;
            const field = try mf.emit(a, ctx.cur, nty, .{ .field_get = .{ .base = object, .field = oc.name } });
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = field } });
            if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });
            ctx.cur = merge;
            break :blk try mf.emit(a, ctx.cur, nty, .{ .load = .{ .addr = slot } });
        },
        .index => |ix| blk: {
            const object = try lowerNode(ctx, ix.object);
            const idx = try lowerNode(ctx, ix.idx);
            // Tuple positional access `t.k` desugars (in the parser) to `t[k]`, so it arrives here as an index
            // whose result type sema leaves UNRESOLVED (tuple-element types are not threaded through the index
            // expression). Recover the real element TypeId from the tuple's own type + the CONSTANT index, so
            // the emit path's operand gates (e.g. a following int binop) see a concrete int/bool. Arrays keep
            // `nty` (sema resolves their element type); only tuples fall through unresolved.
            var rty = nty;
            if (mir.type_store) |st| {
                const otid = mf.typeOf(object);
                if (otid != placeholder_ty and @intFromEnum(otid) < st.count() and st.get(otid) == .tuple) {
                    const idx_node = ctx.hf.get(ix.idx);
                    if (idx_node.kind == .int) {
                        const k: i64 = idx_node.kind.int;
                        const elems = st.get(otid).tuple;
                        if (k >= 0 and @as(usize, @intCast(k)) < elems.len) {
                            // Type the element read as the raw 64-bit WORD, not its declared 32-bit `int`. The
                            // AST loads a tuple element as an i64 word and does 64-bit arithmetic on it with NO
                            // width canonicalisation (a tuple element carries no int-width in the AST). Typing
                            // it `int` here would make the emit path's binop wrap at 32 bits and DIVERGE from
                            // the AST on overflow. The stored value already occupies the full word, so reading
                            // it as `long` is byte-identical for every use (read / arithmetic / compare).
                            rty = wordTid(st) orelse elems[@intCast(k)];
                        }
                    }
                }
            }
            break :blk try mf.emit(a, ctx.cur, rty, .{ .index_get = .{ .object = object, .idx = idx } });
        },

        .struct_init => |si| blk: {
            var args = std.ArrayListUnmanaged(Value).empty;
            defer args.deinit(a);
            for (si.fields) |fid| try args.append(a, try lowerNode(ctx, fid));
            const owned = try a.dupe(Value, args.items);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .struct_new = .{ .type_name = si.type_name, .field_names = si.field_names, .args = owned } });
        },
        .enum_init => |ei| try lowerAggregate(ctx, ei.fields),
        .tuple => |elems| blk: {
            // A tuple is a positional heap aggregate. Carry the element Values in a dedicated tuple_new op so
            // the emit path can reproduce the AST's nova_bytes_alloc + offset-store sequence exactly; the
            // shadow/structural path treats it as an alloc. (lowerAggregate would drop the elements.)
            var args = std.ArrayListUnmanaged(Value).empty;
            defer args.deinit(a);
            for (elems) |eid| try args.append(a, try lowerNode(ctx, eid));
            const owned = try a.dupe(Value, args.items);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .tuple_new = .{ .args = owned } });
        },
        // A template lowers to a dedicated `.template` op ONLY on the emit path (mir.emit_mode); the shadow
        // keeps the structural placeholder so its op counts are unchanged. `nty` is the node's sema type
        // (`string`); mirEmittable only admits it when every part is a string, else the function falls back.
        .template => |parts| if (mir.emit_mode) blk: {
            var pv = std.ArrayListUnmanaged(Value).empty;
            defer pv.deinit(a);
            for (parts) |p| try pv.append(a, try lowerNode(ctx, p));
            const owned = try a.dupe(Value, pv.items);
            break :blk try mf.emit(a, ctx.cur, nty, .{ .template = .{ .parts = owned } });
        } else try lowerAggregate(ctx, parts),
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
            // `obj.field = v` is an lvalue field write, NOT a load: emit field_set (a field_get here would
            // read the field instead of taking its address).
            if (target_node.kind == .field) {
                const base = try lowerNode(ctx, target_node.kind.field.object);
                try mf.emitVoid(a, ctx.cur, .{ .field_set = .{ .base = base, .field = target_node.kind.field.name, .val = v } });
                break :blk Value.invalid;
            }
            const addr = try lowerNode(ctx, asg.target);
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = addr, .val = v } });
            break :blk Value.invalid;
        },
        .ret => |vid| blk: {
            var rv: ?Value = if (vid) |x| try lowerNode(ctx, x) else null;
            // B6: box a scalar returned into a value-optional slot (valopt_box). Skip `undefined`/`null`
            // (already the null word = absent; boxing it would read back as a PRESENT 0 -- the C10 bug), and
            // skip an operand whose type is ALREADY optional (a pass-through) to avoid a double box.
            if (ctx.ret_valopt) {
                if (vid) |x| {
                    const opnode = ctx.hf.get(x);
                    const is_null = opnode.kind == .undefined or opnode.kind == .null;
                    const already_opt = blkopt: {
                        const st = mir.type_store orelse break :blkopt false;
                        if (opnode.ty == hir.unset_ty or @intFromEnum(opnode.ty) >= st.count()) break :blkopt false;
                        break :blkopt st.get(opnode.ty) == .optional;
                    };
                    if (!is_null and !already_opt) {
                        rv = try mf.emit(a, ctx.cur, placeholder_ty, .{ .valopt_box = .{ .val = rv.? } });
                    }
                }
            }
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
            // `a ?? b` == `a != null ? a : b`. For a REFERENCE optional `a` (a nullable pointer word, 0 ==
            // absent), this is a present-check branch on the word: evaluate `a` once, test `a != 0`, take
            // `a` when present else evaluate + take `b`. A value-optional `a` is BOXED (absent is a non-zero
            // sentinel, NOT 0), so treating `undefined` as 0 would miscompile -- but the present-check compare
            // below is a reference-WORD eq (const 0 typed as `a`'s type), which the emit path's `isRefWordEq`
            // gate admits ONLY for a reference word; a boxed value-optional's non-word type makes the compare
            // non-emittable and the whole function falls back to the AST. So this stays airtight for value
            // optionals without a separate check here.
            const slot = try mf.emit(a, ctx.cur, nty, .{ .alloc = .{ .ty = nty } });
            const lhs = try lowerNode(ctx, nc.lhs);
            const lhs_ty = mf.typeOf(lhs);
            const zero = try mf.emit(a, ctx.cur, lhs_ty, .{ .const_int = 0 });
            const present = try mf.emit(a, ctx.cur, lhs_ty, .{ .binop = .{ .op = .ne, .lhs = lhs, .rhs = zero } });
            const then_blk = try mf.newBlock(a);
            const else_blk = try mf.newBlock(a);
            const merge = try mf.newBlock(a);
            mf.setTerm(ctx.cur, .{ .condbr = .{ .cond = present, .then = then_blk, .else_ = else_blk } });
            // present: yield `a`.
            ctx.cur = then_blk;
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = lhs } });
            if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });
            // absent: evaluate + yield `b` (evaluated only on this path, matching the AST's short-circuit).
            ctx.cur = else_blk;
            const rhs = try lowerNode(ctx, nc.rhs);
            try mf.emitVoid(a, ctx.cur, .{ .store = .{ .addr = slot, .val = rhs } });
            if (!mirTerminated(ctx)) mf.setTerm(ctx.cur, .{ .br = .{ .dest = merge, .args = &.{} } });
            ctx.cur = merge;
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

fn lowerCall(ctx: *Ctx, callee: HirId, call_args: []const HirId, sym: ?hir.SymbolId, result_ty: mir.TypeId) !Value {
    const mf = ctx.mf;
    const a = ctx.allocator;
    const callee_kind = ctx.hf.get(callee).kind;
    // A method call `recv.method(args)` has a FIELD-ACCESS callee (the string-method fast path in
    // lower_ast_hir already rewrote its calls to a NAMED ident callee, so a field callee here is a
    // non-string method). Lower it to an `indirect_call` carrying the receiver + method name: the backend
    // resolves the vtable slot from the receiver's TypeId when (and only when) it is a genuine trait object
    // (D5). For a non-trait receiver (a static struct method) the backend gate rejects it and the function
    // falls back to the AST -- exactly as a nameless `.call` did before, so no emittable case regresses.
    if (callee_kind == .field) {
        const recv = try lowerNode(ctx, callee_kind.field.object);
        var margs = std.ArrayListUnmanaged(Value).empty;
        defer margs.deinit(a);
        for (call_args) |arg| try margs.append(a, try lowerNode(ctx, arg));
        const mowned = try a.dupe(Value, margs.items);
        return mf.emit(a, ctx.cur, result_ty, .{ .indirect_call = .{ .receiver = recv, .slot = 0, .args = mowned, .name = callee_kind.field.name } });
    }
    // A direct call to a named function keeps that source name, so a backend can resolve it (emit path)
    // without a symbol table. Only a bare identifier callee is a candidate; anything else stays nameless.
    const callee_name: ?[]const u8 = switch (callee_kind) {
        .ident => |n| n,
        else => null,
    };
    var args = std.ArrayListUnmanaged(Value).empty;
    defer args.deinit(a);
    for (call_args) |arg| try args.append(a, try lowerNode(ctx, arg));
    const owned = try a.dupe(Value, args.items);
    const owns = try a.alloc(bool, owned.len);
    @memset(owns, false);
    const target: mir.SymbolId = if (sym) |s| s else unresolved_callee;
    return mf.emit(a, ctx.cur, result_ty, .{ .call = .{ .callee = target, .args = owned, .takes_ownership = owns, .name = callee_name } });
}

// The interned 64-bit signed int ("long") TypeId, i.e. the raw machine word. Found by scan because the MIR
// type_store is const here (cannot intern). `long`/`int` are interned early, so a real program always has it.
fn wordTid(st: *const types.TypeStore) ?mir.TypeId {
    var i: usize = 0;
    while (i < st.count()) : (i += 1) {
        const t = st.get(@enumFromInt(@as(u32, @intCast(i))));
        if (t == .prim and t.prim.kind == .int and t.prim.bits == 64 and t.prim.signed) return @enumFromInt(@as(u32, @intCast(i)));
    }
    return null;
}

// True if `tid` is not usable as a concrete type: out of range, the unset sentinel, or a store `.unresolved`.
fn tyUnresolved(st: anytype, tid: mir.TypeId) bool {
    if (tid == placeholder_ty or @intFromEnum(tid) >= st.count()) return true;
    return st.get(tid) == .unresolved;
}

// For a binop whose RESULT has the same type as its operands (arithmetic / bitwise / shift), recover an
// unresolved result type from the lhs operand's (resolved) type. Comparisons are excluded -- their result is
// bool, not the operand type. Returns `nty` unchanged when it is already resolved or cannot be recovered, so
// nothing sema already typed is disturbed.
fn inferSameTypeResult(ctx: *Ctx, op: hir.BinOp, nty: mir.TypeId, lhs: Value) mir.TypeId {
    const st = mir.type_store orelse return nty;
    if (!tyUnresolved(st, nty)) return nty;
    switch (op) {
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .shl, .shr => {
            const lt = ctx.mf.typeOf(lhs);
            return if (tyUnresolved(st, lt)) nty else lt;
        },
        else => return nty,
    }
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
