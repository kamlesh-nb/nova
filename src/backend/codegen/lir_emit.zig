// lir_emit.zig — the LIR->LLVM emitter (emit-path step 3, first slice).
//
// The optimiser produces a typed MIR/LIR for each function; this backend module emits LLVM directly from
// it, so the ARC-elision / inlining / const-folding the optimiser did actually reach the binary. It is
// gated behind NOVA_OPT_EMIT (a separate opt-in from the NOVA_OPT shadow) and, crucially, is a per-function
// FALLBACK: `tryEmit` returns false for any function outside the emittable subset, and codegen then emits
// that function from the AST exactly as before. So nothing regresses -- only functions the emitter can
// prove it handles correctly take the new path.
//
// First slice (deliberately tiny + provably correct): a PARAMLESS, straight-line (no control flow)
// function over integer/bool values only -- literals, locals, arithmetic/comparison/bitops, and a return.
// Everything is a `val_type` (i64) word, matching how codegen represents integers, so no type precision is
// needed. Strings/floats/structs/calls/ARC/control-flow are all rejected by the HIR-level filter (MIR
// placeholders a string literal to `const_int 0`, so the filter must run on HIR, which keeps the node kind).
// Params, control flow, and calls are the next slices.

const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;

const ast = @import("../../frontend/ast.zig");
const hir = @import("../../optimiser/hir.zig");
const mir = @import("../../optimiser/mir.zig");
const lower_ast_hir = @import("../../optimiser/lower_ast_hir.zig");
const lower_hir_mir = @import("../../optimiser/lower_hir_mir.zig");
const opt_driver = @import("../../optimiser/driver.zig");
const llvm_codegen = @import("llvm_codegen.zig");
const types_mod = @import("types.zig");
const expressions_mod = @import("expressions.zig");
const LlvmCompiler = llvm_codegen.LlvmCompiler;

// Opt-in: set from NOVA_OPT_EMIT in builder.zig. Off by default, so default builds are byte-identical.
pub var emit_enabled: bool = false;
// Set from NOVA_OPT_EMIT_VERBOSE: log each function taken by the LIR emit path (proof-of-fire).
pub var emit_verbose: bool = false;

// Try to emit `func`'s body from the optimiser IR into `fn_val` (builder already positioned at its entry
// block). Returns true on success (codegen should then skip the AST body); false to fall back to the AST.
pub fn tryEmit(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, func: anytype) bool {
    return tryEmitInner(compiler, fn_val, func) catch false;
}

fn reject(comptime why: []const u8) bool {
    if (emit_verbose) std.debug.print("[opt-emit]   reject: {s}\n", .{why});
    return false;
}

fn tryEmitInner(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, func: anytype) !bool {
    const ir = compiler.typed_ir; // may be null; lowering still works, just fewer types

    // Parameters. `func.params` is populated only for FREE functions (methods leave it empty because their
    // implicit `self` shifts the LLVM argument indices), so `params.len != param_count` means a method or an
    // otherwise-unmodelled signature -> fall back. Every param must be a signed int / bool primitive: those
    // flow as the i64 word (declarations.zig gives every non-array param val_type), which is exactly what
    // LLVMGetParam yields and what the emitter treats values as. Anything else (arrays -> ptr, structs,
    // strings, floats, unsigned) is rejected.
    if (func.params.len != func.param_count) return reject("param count mismatch (method/self?)");
    if (func.params.len > 16) return reject("too many params");
    var ptbuf: [16]mir.TypeId = undefined;
    for (func.params, 0..) |p, i| {
        const tr = p.type_name orelse return reject("untyped param");
        const ptid = compiler.concreteTidForTypeRef(tr) orelse return reject("unresolved param type");
        const pk = intKindForTid(compiler, ptid) orelse return reject("non-int/bool param");
        if (!pk.signed and !pk.is_bool) return reject("unsigned param");
        ptbuf[i] = ptid;
    }
    const param_types = ptbuf[0..func.params.len];

    // AST -> HIR for this function body (params modelled as `let name = param(i)`).
    const fd = ast.FunctionDecl{
        .name = func.name,
        .params = @constCast(func.params), // lowerFunc only reads params; FunctionDecl declares them mutable
        .ret_type = func.ret_type_ref,
        .body = func.body,
        .is_exported = false,
        .attributes = &.{},
        .span = func.body.span,
    };
    var hfunc = try lower_ast_hir.lowerFuncTyped(compiler.allocator, fd, ir, param_types);
    defer hfunc.deinit(compiler.allocator);
    if (!hirEmittable(&hfunc)) return reject("non-emittable HIR node");

    // HIR -> MIR, then run the optimiser pipeline. The only value-computing pass that can fire on this
    // subset is constfold, which is width-honest (wraps folded ints to the result type's width via the
    // store, matching codegen's canonicalizeInt) -- see passes/constfold.zig. mem2reg/copyprop/dce/
    // simplifycfg are structural and do not change computed values. The store must be set for constfold's
    // width lookup.
    mir.type_store = compiler.type_store;
    var mfunc = try lower_hir_mir.lowerFunc(compiler.allocator, hfunc);
    defer mfunc.deinit(compiler.allocator);
    _ = opt_driver.optimise(compiler.allocator, &mfunc) catch return reject("optimise failed");

    // Validate the whole function BEFORE emitting any IR (a mid-stream reject would corrupt a block).
    if (!mirEmittable(compiler, &mfunc)) return reject("MIR outside emittable subset");

    const entry_bb = core.LLVMGetInsertBlock(compiler.builder);
    try emitFunc(compiler, fn_val, &mfunc, entry_bb);
    if (emit_verbose) std.debug.print("[opt-emit] emitted fn `{s}` via LIR path\n", .{func.name});
    return true;
}

// The HIR contains only integer/bool straight-line forms (no control flow, no non-integer values, no
// calls/ARC). This is the correctness gate: it runs on HIR because MIR collapses str/float/null to
// const_int 0.
fn hirEmittable(hf: *const hir.Func) bool {
    for (hf.nodes.items) |node| {
        switch (node.kind) {
            .int, .bool, .param, .ident, .binop, .unop, .let, .assign, .ret, .block,
            // control flow (M6-B): the MIR CFG + emitFunc handle these; if_expr lowers through a result slot
            .if_, .loop_, .if_expr, .brk, .cont => {},
            else => {
                if (emit_verbose) std.debug.print("[opt-emit]   non-emittable node: {s}\n", .{@tagName(node.kind)});
                return false; // str/float/null/call/struct_init/cast/... -> fall back
            },
        }
    }
    return true;
}

// An integer primitive's machine kind, resolved from a TypeId. `null` means "not a signed integer or
// bool primitive" -- the airtight gate below rejects the whole function on any such operand/result, so
// the emit path only handles values whose semantics it can reproduce EXACTLY (matching the AST path's
// canonicalizeInt / signed compares). Unsigned integers are deliberately excluded (they need unsigned
// canonicalisation + predicates the AST path applies conditionally); float/string/struct too.
const IntKind = struct { width: u32, signed: bool, is_bool: bool };

fn intKindForTid(compiler: *LlvmCompiler, tid: mir.TypeId) ?IntKind {
    if (tid == mir.unset_ty) {
        if (emit_verbose) std.debug.print("[opt-emit]     tid=unset (placeholder)\n", .{});
        return null; // placeholder: unknown type -> cannot prove semantics
    }
    // symbolName's result is a transient compile-time string not owned by the caller (every other caller
    // treats it the same way and never frees it), so we do not free it here.
    const name = compiler.symbolName(tid) catch return null;
    const p = types_mod.cgPrim(name) orelse {
        if (emit_verbose) std.debug.print("[opt-emit]     tid={d} name=`{s}` not a cgPrim\n", .{ @intFromEnum(tid), name });
        return null;
    };
    return switch (p.repr) {
        .i1 => .{ .width = 1, .signed = false, .is_bool = true },
        .i8, .i16, .i32, .i64, .word => .{ .width = types_mod.reprBitWidth(p.repr), .signed = p.signed, .is_bool = false },
        else => null, // f32/f64
    };
}

// Dry validation: return false if any instruction OR terminator is outside the emittable subset, building
// NO IR. This MUST run before emitFunc touches the builder -- otherwise a mid-stream reject would leave a
// half-emitted block that the AST fallback then double-fills. Keep the per-op gates in sync with emitBinop /
// the cast arm, and the terminator gates in sync with emitFunc.
fn mirEmittable(compiler: *LlvmCompiler, mf: *const mir.Func) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            switch (inst.op) {
                .binop => |x| {
                    const lk = intKindForTid(compiler, mf.typeOf(x.lhs)) orelse return false;
                    const rk = intKindForTid(compiler, mf.typeOf(x.rhs)) orelse return false;
                    switch (x.op) {
                        .div, .mod, .shr => return false,
                        .add, .sub, .mul, .shl => {
                            if (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool) return false;
                            const rez = intKindForTid(compiler, inst.ty) orelse return false;
                            if (rez.is_bool) return false;
                        },
                        .bit_and, .bit_or, .bit_xor => {
                            if ((!lk.signed and !lk.is_bool) or (!rk.signed and !rk.is_bool)) return false;
                        },
                        .eq, .ne, .lt, .le, .gt, .ge => {
                            const ordering = (x.op == .lt or x.op == .le or x.op == .gt or x.op == .ge);
                            if (ordering and (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool)) return false;
                            if (!ordering and ((!lk.signed and !lk.is_bool) or (!rk.signed and !rk.is_bool))) return false;
                        },
                    }
                },
                .cast => if (intKindForTid(compiler, inst.ty) == null) return false,
                .const_int, .alloc, .load, .store, .param => {},
                else => return false, // call/gep/retain/release/await/spawn/indirect_call -> not yet
            }
        }
        switch (b.term) {
            .ret, .br, .condbr, .unreachable_ => {},
            .switch_ => return false, // dense/sparse switch lowering not emitted yet
        }
    }
    return true;
}

// Emit one MIR instruction into the builder's current block; returns its LLVM value (null for value-less
// ops). `vals` maps MIR Value -> LLVM value across the whole function (SSA is globally numbered).
fn emitInst(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, inst: mir.Inst, mf: *const mir.Func, vals: []?types.LLVMValueRef) !?types.LLVMValueRef {
    const vt = compiler.val_type;
    return switch (inst.op) {
        // A const may be a constfold result computed at i64 precision; canonicalise it to the slot's
        // declared int width so a folded value that overflows `int` wraps exactly as the AST path would.
        .const_int => |v| blk: {
            const c = core.LLVMConstInt(vt, @bitCast(v), 1);
            const rk = intKindForTid(compiler, inst.ty) orelse break :blk c;
            break :blk if (rk.is_bool) c else compiler.canonicalizeInt(c, rk.width, rk.signed);
        },
        // A parameter's value is the Nth LLVM function argument. Every non-array param flows as the i64
        // word (declarations.zig builds the signature with val_type), matching how we treat all values.
        .param => |i| core.LLVMGetParam(fn_val, i),
        .binop => |x| try emitBinop(compiler, inst, x.op, mf, vals[@intFromEnum(x.lhs)].?, vals[@intFromEnum(x.rhs)].?),
        .alloc => core.LLVMBuildAlloca(compiler.builder, vt, ""),
        .load => |x| core.LLVMBuildLoad2(compiler.builder, vt, vals[@intFromEnum(x.addr)].?, ""),
        .store => |x| blk: {
            _ = core.LLVMBuildStore(compiler.builder, vals[@intFromEnum(x.val)].?, vals[@intFromEnum(x.addr)].?);
            break :blk null;
        },
        // A cast between int types must narrow/widen to the TARGET width (an int<-long cast truncates);
        // a raw passthrough would silently keep the wrong width. Canonicalise to the result TypeId's kind.
        .cast => |x| blk: {
            const src = vals[@intFromEnum(x.val)] orelse return error.Unemittable;
            const rk = intKindForTid(compiler, inst.ty) orelse return error.Unemittable;
            break :blk if (rk.is_bool) src else compiler.canonicalizeInt(src, rk.width, rk.signed);
        },
        else => return error.Unemittable, // filtered by mirEmittable, but stay safe
    };
}

// Emit `mf` into `fn_val`. `entry_bb` is the already-created + positioned entry block (MIR block 0). Every
// other MIR block gets a fresh LLVM block; instructions are emitted in block-index order, which satisfies
// SSA define-before-use for the structured CFGs this lowering produces (locals are memory, so the only
// cross-block values are entry-dominating allocas; loop back-edges carry control only, no phis).
fn emitFunc(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, mf: *const mir.Func, entry_bb: types.LLVMBasicBlockRef) !void {
    const vt = compiler.val_type;
    const nblocks = mf.blocks.items.len;

    const llb = try compiler.allocator.alloc(types.LLVMBasicBlockRef, nblocks);
    defer compiler.allocator.free(llb);
    llb[0] = entry_bb;
    for (1..nblocks) |i| llb[i] = core.LLVMAppendBasicBlock(fn_val, "");

    const vals = try compiler.allocator.alloc(?types.LLVMValueRef, mf.value_types.items.len);
    defer compiler.allocator.free(vals);
    @memset(vals, null);

    for (mf.blocks.items, 0..) |*b, bi| {
        core.LLVMPositionBuilderAtEnd(compiler.builder, llb[bi]);
        for (b.insts.items) |inst| {
            const r = try emitInst(compiler, fn_val, inst, mf, vals);
            if (inst.result != .invalid) vals[@intFromEnum(inst.result)] = r;
        }
        switch (b.term) {
            .ret => |x| {
                if (x) |v| {
                    _ = core.LLVMBuildRet(compiler.builder, vals[@intFromEnum(v)] orelse core.LLVMConstInt(vt, 0, 0));
                } else {
                    _ = core.LLVMBuildRetVoid(compiler.builder);
                }
            },
            .br => |x| _ = core.LLVMBuildBr(compiler.builder, llb[@intFromEnum(x.dest)]),
            .condbr => |x| {
                // The condition is a bool word (0/1); branch on nonzero, exactly as the AST path does.
                const c = vals[@intFromEnum(x.cond)] orelse return error.Unemittable;
                const i1v = core.LLVMBuildICmp(compiler.builder, .LLVMIntNE, c, core.LLVMConstInt(vt, 0, 0), "");
                _ = core.LLVMBuildCondBr(compiler.builder, i1v, llb[@intFromEnum(x.then)], llb[@intFromEnum(x.else_)]);
            },
            .unreachable_ => _ = core.LLVMBuildUnreachable(compiler.builder),
            else => return error.Unemittable, // switch_ -> rejected by mirEmittable
        }
    }
}

// Airtight binop emit: reproduces the AST path's integer semantics EXACTLY for the subset it accepts, and
// returns error.Unemittable (fall back to AST) for anything it cannot prove. Accepts SIGNED int / bool
// operands only. div/mod/shr are rejected (they need the AST path's div-by-zero guard / signed-shift and
// unsigned-canonicalisation, which introduce branches or sign logic outside this straight-line slice).
fn emitBinop(compiler: *LlvmCompiler, inst: mir.Inst, op: mir.BinOp, mf: *const mir.Func, l: types.LLVMValueRef, r: types.LLVMValueRef) !types.LLVMValueRef {
    const bld = compiler.builder;
    const vt = compiler.val_type;
    const lk = intKindForTid(compiler, mf.typeOf(inst.op.binop.lhs)) orelse return error.Unemittable;
    const rk = intKindForTid(compiler, mf.typeOf(inst.op.binop.rhs)) orelse return error.Unemittable;
    switch (op) {
        // Arithmetic + left shift: emit at the i64 word, then canonicalise to the RESULT type's width/sign
        // (this is the 32-bit-honest wrap the AST path applies via canonicalizeInt). Signed operands only.
        .add, .sub, .mul, .shl => {
            if (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool) return error.Unemittable;
            const rez = intKindForTid(compiler, inst.ty) orelse return error.Unemittable;
            if (rez.is_bool) return error.Unemittable;
            const res = switch (op) {
                .add => core.LLVMBuildAdd(bld, l, r, ""),
                .sub => core.LLVMBuildSub(bld, l, r, ""),
                .mul => core.LLVMBuildMul(bld, l, r, ""),
                .shl => core.LLVMBuildShl(bld, l, r, ""),
                else => unreachable,
            };
            return compiler.canonicalizeInt(res, rez.width, rez.signed);
        },
        // Bitwise: representation-preserving at the word for signed/bool operands; no canonicalise (matches AST).
        .bit_and, .bit_or, .bit_xor => {
            if ((!lk.signed and !lk.is_bool) or (!rk.signed and !rk.is_bool)) return error.Unemittable;
            return switch (op) {
                .bit_and => core.LLVMBuildAnd(bld, l, r, ""),
                .bit_or => core.LLVMBuildOr(bld, l, r, ""),
                .bit_xor => core.LLVMBuildXor(bld, l, r, ""),
                else => unreachable,
            };
        },
        // Comparisons: operands arrive as sign-extended i64 words, so a signed word compare is exact for
        // signed ints. eq/ne are sign-agnostic and allowed on bool too. Ordering needs signed operands.
        .eq, .ne, .lt, .le, .gt, .ge => {
            const ordering = (op == .lt or op == .le or op == .gt or op == .ge);
            if (ordering and (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool)) return error.Unemittable;
            if (!ordering and ((!lk.signed and !lk.is_bool) or (!rk.signed and !rk.is_bool))) return error.Unemittable;
            const pred: types.LLVMIntPredicate = switch (op) {
                .eq => .LLVMIntEQ,
                .ne => .LLVMIntNE,
                .lt => .LLVMIntSLT,
                .le => .LLVMIntSLE,
                .gt => .LLVMIntSGT,
                .ge => .LLVMIntSGE,
                else => unreachable,
            };
            const cmp = core.LLVMBuildICmp(bld, pred, l, r, "");
            return core.LLVMBuildZExt(bld, cmp, vt, "");
        },
        // div / mod / shr: need the AST path's guard / sign handling -> fall back.
        .div, .mod, .shr => return error.Unemittable,
    }
}
