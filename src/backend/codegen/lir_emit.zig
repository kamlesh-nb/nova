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
    // An `async fn` is compiled as an LLVM coroutine: `fn_val` already carries the `presplitcoroutine`
    // attribute and its callers `spawn`/`await` it expecting a coroutine frame. Emitting a plain body here
    // (and skipping the coro prologue) produces a malformed coroutine that CoroSplit turns into a crash --
    // even when the body itself is trivial int arithmetic (e.g. `async fn square(n){return n*n}`, which the
    // node gate otherwise accepts). Coroutine lowering is not in the emit subset, so reject async up front.
    if (func.is_async) return reject("async fn (coroutine)");

    const ir = compiler.typed_ir; // may be null; lowering still works, just fewer types

    // Parameters. `func.params` is populated only for FREE functions (methods leave it empty because their
    // implicit `self` shifts the LLVM argument indices), so `params.len != param_count` means a method or an
    // otherwise-unmodelled signature -> fall back. A param must flow as the i64 word (which is what
    // LLVMGetParam yields and what the emitter treats values as): that means a signed int / bool primitive,
    // or a heap struct/class (its address). Arrays (-> ptr), floats, strings, unsigned, value structs are
    // rejected.
    if (func.params.len != func.param_count) return reject("param count mismatch (method/self?)");
    if (func.params.len > 16) return reject("too many params");
    var ptbuf: [16]mir.TypeId = undefined;
    for (func.params, 0..) |p, i| {
        const tr = p.type_name orelse return reject("untyped param");
        // An OPTIONAL param (`T | undefined`) is boxed/encoded specially and concreteTidForTypeRef strips
        // it to the inner tid -- which would masquerade as a plain scalar. The emit path does not model
        // optionals, so reject at the type-ref level before the tid is stripped.
        if (tr == .optional) return reject("optional param");
        const ptid = compiler.concreteTidForTypeRef(tr) orelse return reject("unresolved param type");
        const scalar_ok = if (intKindForTid(compiler, ptid)) |pk| (pk.signed or pk.is_bool) else false;
        if (!scalar_ok and !emittableHeapStructTid(compiler, ptid)) return reject("param not int/bool/heap-struct");
        ptbuf[i] = ptid;
    }
    const param_types = ptbuf[0..func.params.len];

    // Return type must be plainly emittable: void (no ret_type_ref), a signed int/bool scalar, or an
    // emittable heap struct (the fresh-construction case, further restricted in mirEmittable's `.ret`).
    // A value-optional (`int | undefined`), float, string, union or error-union return is NOT correctly
    // encoded yet and must fall back to AST. Without this, e.g. `checkedAddInt(): int | undefined` emitted
    // and returned `undefined` for a perfectly valid value -- concreteTidForTypeRef strips the optional to
    // the inner int, so the scalar check alone lets it through; gate on the type-ref shape too.
    if (func.ret_type_ref) |rtr| {
        if (rtr == .optional) return reject("optional return");
        const is_void = (rtr == .ident and std.mem.eql(u8, rtr.ident, "void"));
        if (!is_void) {
            const rtid = compiler.concreteTidForTypeRef(rtr) orelse return reject("unresolved return type");
            const ret_scalar = if (intKindForTid(compiler, rtid)) |rk| (rk.signed or rk.is_bool) else false;
            if (!ret_scalar and !emittableHeapStructTid(compiler, rtid)) return reject("return type not int/bool/heap-struct");
        }
    }

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
            .if_, .loop_, .if_expr, .brk, .cont,
            // direct calls (M6-C): validated + emitted from the MIR call op (callee resolved by name)
            .call, .generic_call,
            // structs (M6-D): construction + field read/write, validated + emitted from struct_new/field_*
            .struct_init, .field => {},
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

const Callee = struct { fn_val: types.LLVMValueRef, fn_type: types.LLVMTypeRef };

// Resolve a direct call by source name to an LLVM function the emitter can call, but ONLY if its signature
// is all-word: `nargs` word (i64) parameters and a word or void return. Nova passes every non-array param as
// the i64 word, so such a call needs no argument/return coercion -- the MIR arg values are already words.
// Anything else (array=ptr params, wider/narrower ABI) returns null so the call falls back to the AST path.
fn resolveCallee(compiler: *LlvmCompiler, name: []const u8, nargs: usize) ?Callee {
    const resolved = compiler.resolveCalleeName(name) catch return null;
    const fn_val = compiler.func_map.get(resolved) orelse return null;
    const fn_type = core.LLVMGlobalGetValueType(fn_val);
    if (core.LLVMGetTypeKind(fn_type) != .LLVMFunctionTypeKind) return null;
    if (core.LLVMIsFunctionVarArg(fn_type) != 0) return null;
    if (core.LLVMCountParamTypes(fn_type) != @as(c_uint, @intCast(nargs))) return null;
    const vt = compiler.val_type;
    if (nargs > 0) {
        var ptypes: [16]types.LLVMTypeRef = undefined;
        if (nargs > ptypes.len) return null;
        core.LLVMGetParamTypes(fn_type, &ptypes);
        for (ptypes[0..nargs]) |pt| if (pt != vt) return null;
    }
    const ret = core.LLVMGetReturnType(fn_type);
    if (ret != vt and ret != compiler.void_type) return null;
    return .{ .fn_val = fn_val, .fn_type = fn_type };
}

// The declared base name of the struct/class a value holds (via its threaded TypeId), or null if the value
// is not a known struct type. Used to resolve field layout from the base of a field_get/field_set.
fn structBaseNameOf(compiler: *LlvmCompiler, mf: *const mir.Func, v: mir.Value) ?[]const u8 {
    const tid = mf.typeOf(v);
    if (tid == mir.unset_ty) return null;
    const nm = compiler.symbolName(tid) catch return null;
    const base = types_mod.getStructBaseName(nm);
    if (!compiler.structs.contains(base)) return null;
    return base;
}

fn fieldTypeRef(compiler: *LlvmCompiler, struct_name: []const u8, field_name: []const u8) ?ast.TypeRef {
    const sd = compiler.structs.get(struct_name) orelse return null;
    for (sd.fields) |f| if (std.mem.eql(u8, f.name, field_name)) return f.type_name;
    return null;
}

// A field this slice can store at its real width: a bare int/bool primitive. Floats, strings, nested
// structs, optionals, arrays etc. need the float-store path or ARC (owned fields) and are left to the AST.
fn isScalarFieldTypeRef(tr: ast.TypeRef) bool {
    return switch (tr) {
        .ident => |n| if (types_mod.cgPrim(n)) |p| (p.repr != .f32 and p.repr != .f64) else false,
        else => false,
    };
}

// A heap struct/class usable as an i64-word param/value in the emit subset: a known struct that is NOT a
// value struct (value structs use a stack alloca, a separate ABI not handled yet). Fields are validated at
// each field access, not here.
fn emittableHeapStructTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    const nm = compiler.symbolName(tid) catch return false;
    const base = types_mod.getStructBaseName(nm);
    if (!compiler.structs.contains(base)) return false;
    return !compiler.isValueStructName(base);
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
                        // Arithmetic + shifts (incl. div/mod/shr): signed non-bool operands, non-bool int
                        // result. div/mod carry the AST path's div-by-zero (+ i64 MIN/-1) guard; shr is an
                        // arithmetic shift of the sign-extended word. Same operand gate as the others.
                        .add, .sub, .mul, .shl, .div, .mod, .shr => {
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
                // A direct call is emittable if its callee resolves to an all-word LLVM function (below).
                // The result type, if the value is used arithmetically, is gated by the consuming binop.
                .call => |x| {
                    const nm = x.name orelse return false;
                    if (resolveCallee(compiler, nm, x.args.len) == null) return false;
                },
                // Heap struct with all-scalar fields, fully initialised (every declared field supplied so we
                // never rely on zero-init of an omitted field). Value structs + owned-field structs fall back.
                .struct_new => |x| {
                    if (compiler.isValueStructName(x.type_name)) return false;
                    const sd = compiler.structs.get(x.type_name) orelse return false;
                    if (sd.fields.len != x.args.len or sd.fields.len != x.field_names.len) return false;
                    for (sd.fields) |f| if (!isScalarFieldTypeRef(f.type_name)) return false;
                },
                .field_get => |x| {
                    const sname = structBaseNameOf(compiler, mf, x.base) orelse return false;
                    if (compiler.isValueStructName(sname)) return false;
                    const ftr = fieldTypeRef(compiler, sname, x.field) orelse return false;
                    if (!isScalarFieldTypeRef(ftr)) return false;
                },
                .field_set => |x| {
                    const sname = structBaseNameOf(compiler, mf, x.base) orelse return false;
                    if (compiler.isValueStructName(sname)) return false;
                    const ftr = fieldTypeRef(compiler, sname, x.field) orelse return false;
                    if (!isScalarFieldTypeRef(ftr)) return false;
                },
                // A module-level const reference is emittable iff the name IS a const (not a bare function
                // reference or a capture) AND its value is a scalar int/bool (arrays/structs/strings fall
                // back). The result type carries the const's declared type.
                .global_const => |name| {
                    if (!compiler.constants.contains(name)) return false;
                    if (intKindForTid(compiler, inst.ty) == null) return false;
                },
                .const_int, .alloc, .load, .store, .param => {},
                else => return false, // gep/retain/release/await/spawn/indirect_call -> not yet
            }
        }
        switch (b.term) {
            // Returning a heap struct is only safe when it is a FRESH construction (rc=1, moved to the
            // caller). Returning a BORROWED struct (a param, a field, an owned local not moved out) requires a
            // retain the emit path does not yet emit -- the AST caller would treat the result as an owned
            // temporary and release it, double-freeing. So restrict to struct_new results (mem2reg forwards a
            // `let t = Type{...}; return t` to the struct_new too). This is the ARC boundary for M6-D.
            .ret => |x| if (x) |rv| {
                if (emittableHeapStructTid(compiler, mf.typeOf(rv)) and !isStructNewResult(mf, rv)) return false;
            },
            .br, .condbr, .unreachable_ => {},
            .switch_ => return false, // dense/sparse switch lowering not emitted yet
        }
    }
    return true;
}

// True if Value `v` is defined by a struct_new instruction (a freshly-constructed, rc=1 heap object).
fn isStructNewResult(mf: *const mir.Func, v: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.result == v) return inst.op == .struct_new;
        }
    }
    return false;
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
        // A module-level const reference: resolve it via the SAME lazy-init per-module global-load the AST
        // path uses (compileConstRef compiles the initializer once, caches it in `__const_<name>_val`), so a
        // literal const and a runtime-computed const both work and match the AST byte-for-byte. Return the
        // loaded word directly -- compileConstRef already produced it canonical for the const's DECLARED type
        // (the AST ident path uses it verbatim too). Do NOT re-canonicalise here: the value's threaded MIR
        // type can be narrower than the const's real type (e.g. a `long` mask read as `int`), and a width-32
        // sign-extend would turn 0xffffffff into -1, unmasking `x & MASK32`.
        .global_const => |name| blk: {
            const init_expr = compiler.constants.get(name) orelse return error.Unemittable;
            break :blk try compiler.compileConstRef(name, init_expr);
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
        // Heap struct construction: allocate the payload, then store each field at its real offset/width --
        // the same nova_bytes_alloc + add/inttoptr/store sequence the AST path emits (expressions.zig), reusing
        // the same layout + cast helpers. Owned-field structs are rejected by mirEmittable (they need a retain).
        .struct_new => |x| blk: {
            const total = compiler.getTypeSize(ast.TypeRef{ .ident = x.type_name }, false);
            const struct_ptr = try compiler.compileAlloc(core.LLVMConstInt(vt, total, 0));
            for (x.field_names, x.args) |fname, arg| {
                const off = compiler.getFieldOffset(x.type_name, fname) catch return error.Unemittable;
                const ftr = fieldTypeRef(compiler, x.type_name, fname) orelse return error.Unemittable;
                const flt = compiler.toLLVMType(ftr);
                const addr = core.LLVMBuildAdd(compiler.builder, struct_ptr, core.LLVMConstInt(vt, off, 0), "");
                const fptr = core.LLVMBuildIntToPtr(compiler.builder, addr, core.LLVMPointerType(flt, 0), "");
                const av = vals[@intFromEnum(arg)] orelse return error.Unemittable;
                _ = core.LLVMBuildStore(compiler.builder, compiler.castFromValType(av, flt), fptr);
            }
            break :blk struct_ptr;
        },
        // Field read: base + offset, inttoptr to the field's real type, load, widen back to the i64 word.
        .field_get => |x| blk: {
            const sname = structBaseNameOf(compiler, mf, x.base) orelse return error.Unemittable;
            const off = compiler.getFieldOffset(sname, x.field) catch return error.Unemittable;
            const ftr = fieldTypeRef(compiler, sname, x.field) orelse return error.Unemittable;
            const flt = compiler.toLLVMType(ftr);
            const base_v = vals[@intFromEnum(x.base)] orelse return error.Unemittable;
            const addr = core.LLVMBuildAdd(compiler.builder, base_v, core.LLVMConstInt(vt, off, 0), "");
            const fptr = core.LLVMBuildIntToPtr(compiler.builder, addr, core.LLVMPointerType(flt, 0), "");
            const raw = core.LLVMBuildLoad2(compiler.builder, flt, fptr, "");
            break :blk compiler.castToValType(raw, ftr);
        },
        // Field write (scalar only in this slice, so no retain-old/release semantics): base + offset, narrow
        // the word to the field type, store.
        .field_set => |x| blk: {
            const sname = structBaseNameOf(compiler, mf, x.base) orelse return error.Unemittable;
            const off = compiler.getFieldOffset(sname, x.field) catch return error.Unemittable;
            const ftr = fieldTypeRef(compiler, sname, x.field) orelse return error.Unemittable;
            const flt = compiler.toLLVMType(ftr);
            const base_v = vals[@intFromEnum(x.base)] orelse return error.Unemittable;
            const av = vals[@intFromEnum(x.val)] orelse return error.Unemittable;
            const addr = core.LLVMBuildAdd(compiler.builder, base_v, core.LLVMConstInt(vt, off, 0), "");
            const fptr = core.LLVMBuildIntToPtr(compiler.builder, addr, core.LLVMPointerType(flt, 0), "");
            _ = core.LLVMBuildStore(compiler.builder, compiler.castFromValType(av, flt), fptr);
            break :blk null;
        },
        // Direct call: resolve the callee (all-word signature, verified by mirEmittable), pass the arg words
        // straight through (no coercion), return the result word. The callee returns an already-canonical
        // value for its declared width, so nothing more is needed here.
        .call => |x| blk: {
            const nm = x.name orelse return error.Unemittable;
            const c = resolveCallee(compiler, nm, x.args.len) orelse return error.Unemittable;
            var argbuf: [16]types.LLVMValueRef = undefined;
            if (x.args.len > argbuf.len) return error.Unemittable;
            for (x.args, 0..) |arg, i| argbuf[i] = vals[@intFromEnum(arg)] orelse return error.Unemittable;
            const call = core.LLVMBuildCall2(compiler.builder, c.fn_type, c.fn_val, &argbuf, @intCast(x.args.len), "");
            break :blk if (inst.result != .invalid) call else null;
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
// operands only. div/mod reuse the AST path's exact div-by-zero (+ i64 MIN/-1) guard (which splits the
// block, leaving the builder at the continuation), and shr is an arithmetic shift of the sign-extended
// word. Unsigned div/mod/shr (which need unsigned-canonicalisation) still fall back to the AST path.
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
        // div / mod: same div-by-zero (+ i64 MIN/-1 at width 64) guard the AST path emits, then a signed
        // divide/remainder. NOT canonicalised: for width<64 the sign-extended i64 operands cannot overflow
        // sdiv/srem and the result already fits; width==64 is caught by the guard. Matches the AST path.
        .div, .mod => {
            if (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool) return error.Unemittable;
            const rez = intKindForTid(compiler, inst.ty) orelse return error.Unemittable;
            if (rez.is_bool) return error.Unemittable;
            if (op == .div) {
                compiler.emitIntDivGuard(l, r, true, lk.width, "integer division by zero", "integer division overflow (INT_MIN / -1)");
                return core.LLVMBuildSDiv(bld, l, r, "");
            }
            compiler.emitIntDivGuard(l, r, true, lk.width, "integer modulo by zero", "integer modulo overflow (INT_MIN % -1)");
            return core.LLVMBuildSRem(bld, l, r, "");
        },
        // shr: signed operands arrive as sign-extended i64 words, so an arithmetic shift right is exact
        // (matches the AST path's signed branch). No canonicalise.
        .shr => {
            if (!lk.signed or !rk.signed or lk.is_bool or rk.is_bool) return error.Unemittable;
            return core.LLVMBuildAShr(bld, l, r, "");
        },
    }
}
