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
const sema_shadow = @import("../../frontend/sema/shadow.zig");
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
    if (func.params.len > 32) return reject("too many params (>32)");
    var ptbuf: [32]mir.TypeId = undefined;
    for (func.params, 0..) |p, i| {
        const tr = p.type_name orelse return reject("untyped param");
        // An OPTIONAL param (`T | undefined`) is boxed/encoded specially and concreteTidForTypeRef strips
        // it to the inner tid -- which would masquerade as a plain scalar. The emit path does not model
        // optionals, so reject at the type-ref level before the tid is stripped.
        if (tr == .optional and !isRefOptionalTypeRef(compiler, tr)) return reject("optional param");
        // B7: an error-union param (`T | E`) is a tagged HEAP box {tag@0, payload@8} (nova_bytes_alloc,
        // ARC-owned, __destruct_ErrUnion_* branches on the tag), and its ok arm is itself value-optional-
        // boxed `(T|undefined)`. concreteTidForTypeRef could resolve it to a box tid that emittableHeapStruct
        // Tid mistakes for a plain heap struct -> the body would read payload as raw struct fields. The emit
        // path models none of the box/tag/unbox/errdefer machinery, so reject at the type-ref shape.
        if (tr == .error_union) return reject("error-union param");
        // For a REFERENCE optional param (`string | undefined`, class `T | undefined`), thread the INNER
        // reference tid, not `concreteTidForTypeRef(tr)`: the latter strips the optional to a distinct
        // "string"/struct tid that lands in a different slot than the canonical reference tid (a tid-space
        // artefact), so `isStringTid`/`emittableHeapStructTid` reject it and the param falls back. A reference
        // optional IS a plain nullable pointer word (0 == absent), identical at the word level to its payload
        // reference, so threading the inner tid is exact (B6). A VALUE optional never reaches here (rejected
        // above), so the boxed encoding is untouched.
        const ptid = blk_ptid: {
            if (tr == .optional) {
                if (compiler.concreteTidForTypeRef(tr.optional.*)) |inner| break :blk_ptid inner;
            }
            break :blk_ptid compiler.concreteTidForTypeRef(tr) orelse return reject("unresolved param type");
        };
        const scalar_ok = if (intKindForTid(compiler, ptid)) |pk| (pk.signed or pk.is_bool) else false;
        // A string param flows as the i64 pointer word like a class param. It is BORROWED, so read-only use
        // (via string_* method calls, now named by C0) needs no ARC; an owned string LOCAL created in the body
        // gets its scope-end release from the threaded ARC ops (D2). Capturing a string into a struct field is
        // blocked by the field gates (string fields are non-scalar); returning a string is blocked below.
        // A TRAIT-typed param is a borrowed fat-pointer word: the body may dispatch sync trait methods on it
        // (D5). No ARC is threaded for it (a param is never an owned local), matching the AST borrow contract.
        // isFloatWordTid admits both f32 (promoted-to-double ABI) and f64.
        if (!scalar_ok and !emittableHeapStructTid(compiler, ptid) and !isStringTid(compiler, ptid) and !isArrayWordTid(compiler, ptid) and !isFloatWordTid(compiler, ptid) and !emittableValueStructParamTid(compiler, ptid) and !emittableRefOptionalTid(compiler, ptid) and !emittableTraitParamTid(compiler, ptid)) return reject("param not int/bool/heap-struct/string/array/f32/f64/value-struct/ref-optional/trait");
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
        if (rtr == .optional and !isRefOptionalTypeRef(compiler, rtr)) return reject("optional return");
        // B7 (FALLBACK, documented in docs/design/optimiser-pending.md): an error-union return `T | E` is a
        // tagged HEAP box built by arc.buildErrUnion -- 16 bytes = {i64 tag @0 (0=ok,1=err), i64 payload @8},
        // a nova_bytes_alloc ARC object whose per-union __destruct_ErrUnion_* releases the payload by tag. The
        // ok arm is NESTED value-optional-boxed: `T | E` reads as `(T|undefined) | E`, so `return 42` produces
        // TWO nested heap boxes (outer errunion box holding a pointer to an inner valopt box). The error path
        // also runs runErrdefers() before boxing, and an owned payload is retained INTO the box. None of this
        // (heap-box alloc + tag/payload stores, nested valopt boxing, errdefer side effects, retain-into-box,
        // and the try/catch/?? unbox control flow) has a MIR representation, so a raw-word emit would miscompile
        // (an ok value returned as a bare int is read back as a box pointer -> SEGV). Reject at the type-ref
        // shape -- do NOT rely on the tid failing emittableHeapStructTid below (the box IS a heap object).
        if (rtr == .error_union) return reject("error-union return");
        const is_void = (rtr == .ident and std.mem.eql(u8, rtr.ident, "void"));
        if (!is_void) {
            const rtid = compiler.concreteTidForTypeRef(rtr) orelse return reject("unresolved return type");
            const ret_scalar = if (intKindForTid(compiler, rtid)) |rk| (rk.signed or rk.is_bool) else false;
            // f64 returns flow as the double's bits in the i64 word (the signature returns the word), matching
            // how the emit path represents a float value -- so a float-returning function is emittable.
            // A string return is emittable: lower_ast_hir threads the return-acquisition retain (a borrowed
            // string returned is retained; a moved owned local / fresh temporary is not), so ownership out is
            // balanced -- validated by the --arc gate.
            // B5 value-struct RETURNS: there is NO separate by-value copy-out / sret ABI in this backend. The
            // whole-program escape analysis (computeValueEscapeSet, honoured by isValueStructName) HEAP-PROMOTES
            // any struct that is constructed-and-returned -- a returned struct is therefore a reference-counted
            // HEAP struct, not inline stack bytes, so `emittableHeapStructTid` accepts it here and it flows out
            // as the payload pointer word exactly like the AST (which uses the same nova_bytes_alloc + return-
            // pointer sequence -- differential byte-identical + ASAN-clean, incl. an intervening call between
            // the return and the field read). A struct that STAYS value-lowered never reaches a return position
            // (returning it would dangle, which escape analysis is precisely what prevents), so no dead-stack
            // return is reachable. The one shape still NOT emitted is a returned heap-struct BORROW (`return p`
            // / `return aLocal`), which the AST retains on the way out (nova_retain + the caller's __destruct_*
            // release): mirEmittable's `.ret` gate restricts heap-struct returns to a FRESH construction
            // (isStructNewResult), and the retain/release gates are string-only, so the borrow-return is left to
            // the AST until struct-destructor ARC threading lands. That is an ARC slice, not a value-struct ABI.
            if (!ret_scalar and !emittableHeapStructTid(compiler, rtid) and !isFloatWordTid(compiler, rtid) and !isStringTid(compiler, rtid) and !emittableRefOptionalTid(compiler, rtid)) return reject("return type not int/bool/heap-struct/f32/f64/string/ref-optional");
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
    // Set the sema store BEFORE lowering: AST->HIR needs it too now (lower_ast_hir's C0 method-call naming
    // resolves the receiver type via mir.type_store), not only constfold below.
    mir.type_store = compiler.type_store;
    var hfunc = try lower_ast_hir.lowerFuncTyped(compiler.allocator, fd, ir, param_types);
    defer hfunc.deinit(compiler.allocator);
    // C5: fold payloadless enum values (`Color.Red`) to their integer discriminant BEFORE the HIR gate, so a
    // function that reads/compares enum values emits instead of falling back on the `.field`->field_get shape.
    rewriteEnumValueNodes(compiler, &hfunc);
    if (!hirEmittable(&hfunc)) return reject("non-emittable HIR node");

    // HIR -> MIR, then run the optimiser pipeline. The only value-computing pass that can fire on this
    // subset is constfold, which is width-honest (wraps folded ints to the result type's width via the
    // store, matching codegen's canonicalizeInt) -- see passes/constfold.zig. mem2reg/copyprop/dce/
    // simplifycfg are structural and do not change computed values. The store must be set for constfold's
    // width lookup.
    mir.type_store = compiler.type_store;
    // Emit-path lowering: produce dedicated emit ops (e.g. `.template`) the shadow does not. Reset after so a
    // later shadow lowering is unaffected.
    mir.emit_mode = true;
    defer mir.emit_mode = false;
    var mfunc = try lower_hir_mir.lowerFunc(compiler.allocator, hfunc);
    defer mfunc.deinit(compiler.allocator);
    _ = opt_driver.optimise(compiler.allocator, &mfunc) catch return reject("optimise failed");

    // Structural verify (A3): reject the function if the MIR violates a basic invariant (use-before-def,
    // out-of-range operand/result, bad block target, unterminated block). Defence in depth -- a pass bug that
    // produced e.g. a dangling load must not reach LLVM. The AST fallback then emits the function unchanged.
    {
        const violations = @import("../../optimiser/verify.zig").verify(compiler.allocator, &mfunc) catch return reject("verify failed");
        defer compiler.allocator.free(violations);
        if (violations.len > 0) return reject("MIR verify violation");
    }

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
            // nullish `a ?? b` (C4): lowers to a present-check branch on the pointer word (`a != 0 ? a : b`).
            // Emittable ONLY for a REFERENCE optional -- the synthesized `a != null` compare is a reference-
            // WORD eq that mirEmittable's isRefWordEq gate admits solely for a reference word, so a boxed
            // value optional makes the compare non-emittable and the whole function falls back. See the
            // lower_hir_mir `.nullish` note for why treating value-optional `undefined` as 0 is unsafe.
            .nullish,
            // direct calls (M6-C): validated + emitted from the MIR call op (callee resolved by name)
            .call, .generic_call,
            // structs (M6-D): construction + field read/write, validated + emitted from struct_new/field_*
            .struct_init, .field,
            // tuples (C5): construction `(a, b)` -> tuple_new; element read `t.0` desugars to the index form
            // `t[0]` (a `.index` node, already allowed). mirEmittable gates both to all-scalar tuples.
            .tuple,
            // ARC (D2): retain/release threaded by lower_ast_hir; mirEmittable gates them to string operands.
            .retain, .release,
            // element read (C3): `object[idx]` -> index_get; mirEmittable gates it to string / non-float array.
            .index,
            // int<->int casts (C2): `x as long` / `x as int`; mirEmittable gates operand AND result to int.
            .cast,
            // string literals (C8): materialised as an immortal interned global (no ARC).
            .str,
            // string interpolation (C5): `` `${a}b` ``; mirEmittable gates it to all-string parts and
            // reproduces the AST StringBuilder lowering (alloc/init/append*/toString/delete/release).
            .template,
            // float literals (B3): f64 flows as the double's bit pattern in the word; mirEmittable gates ops.
            .float => {},
            // NB: `undefined` / `null` are deliberately NOT in this allowlist. They lower to `const_int 0`,
            // which is exact for a REFERENCE optional (0 == absent) but WRONG for a VALUE optional, where the
            // AST boxes them to a non-zero absent-sentinel. The HIR gate is whole-function and cannot tell the
            // two apart per node, and admitting `.undefined` was verified to MISCOMPILE `f(undefined)` for a
            // value-optional param (the arg is passed as 0, not the boxed sentinel). So a function containing
            // any `undefined`/`null` literal falls back to the AST. Reference-optional signatures that never
            // materialise `undefined` in the body (only read/compare a passed-in optional) still emit.
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

// The AST EnumDecl a TypeId names, but ONLY if the enum is PAYLOADLESS (no variant carries a `type_name`
// or `fields`). A payloadless enum value is a plain integer discriminant word (expressions.zig materialises
// `Color.Red` as `LLVMConstInt(val_type, discriminant)` and a `Color` param flows as that i64 word), so the
// emit path can treat it exactly like a signed 64-bit int. A TAGGED enum is a heap `{tag, payload...}` box
// with a different ABI -> null (fall back). Resolves the enum SymbolId via the live sema symbol table.
fn payloadlessEnumDeclForTid(compiler: *LlvmCompiler, tid: mir.TypeId) ?*const ast.EnumDecl {
    const st = compiler.type_store orelse return null;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return null;
    const sid = switch (st.get(tid)) {
        .enum_ => |s| s,
        else => return null,
    };
    const sm = sema_shadow.live_sema orelse return null;
    const ed = switch (sm.tab.symbolAt(sid).decl) {
        .enum_ => |e| e,
        else => return null,
    };
    for (ed.variants) |v| if (v.type_name != null or v.fields != null) return null;
    return ed;
}

// True if the HIR function binds a local (or parameter) called `name`. Parameters are lowered as
// `let name = param(i)`, so a `.let` scan covers both. Used to distinguish a genuine field read on a
// same-named variable from a payloadless enum-value access (`Color.Red`).
fn hirBindsLocal(hf: *const hir.Func, name: []const u8) bool {
    for (hf.nodes.items) |n| {
        if (n.kind == .let and std.mem.eql(u8, n.kind.let.name, name)) return true;
    }
    return false;
}

// Rewrite a payloadless enum VALUE (`Color.Red`) from a `.field` on a type-name ident into an `.int`
// discriminant constant, exactly what the AST backend materialises (expressions.zig: `LLVMConstInt(val_type,
// v.value orelse idx)`). Without this the `.field` lowers to a `field_get` on a base that is not a struct
// value, and the whole function falls back. The node KEEPS its sema TypeId (the enum type), so intKindForTid
// still classifies it as an enum-int word and `disc == Color.Red` compares as a plain i64 -- byte-identical
// to the AST. The now-orphaned type-name `.ident` node is unreferenced; lower_hir_mir only lowers nodes
// reachable from the block tree, so it is never emitted. Only PAYLOADLESS enums are rewritten (a tagged
// `E.Variant` builds a heap box with a different ABI and stays on the AST).
fn rewriteEnumValueNodes(compiler: *LlvmCompiler, hf: *hir.Func) void {
    const nodes = hf.nodes.items;
    for (nodes) |*node| {
        if (node.kind != .field) continue;
        const fld = node.kind.field;
        const obj = nodes[@intFromEnum(fld.object)];
        if (obj.kind != .ident) continue;
        const type_name = obj.kind.ident;
        if (hirBindsLocal(hf, type_name)) continue; // a same-named variable -> real field read
        const scoped = compiler.scopedTypeName(type_name, node.span.file);
        const ed = compiler.enums.get(scoped) orelse compiler.enums.get(type_name) orelse continue;
        var tagged = false;
        for (ed.variants) |v| {
            if (v.type_name != null or v.fields != null) {
                tagged = true;
                break;
            }
        }
        if (tagged) continue;
        for (ed.variants, 0..) |v, idx| {
            if (std.mem.eql(u8, v.name, fld.name)) {
                const disc: i64 = v.value orelse @intCast(idx);
                node.kind = .{ .int = disc }; // keep node.ty (the enum tid): the compare stays enum-typed
                break;
            }
        }
    }
}

fn intKindForTid(compiler: *LlvmCompiler, tid: mir.TypeId) ?IntKind {
    if (tid == mir.unset_ty) {
        if (emit_verbose) std.debug.print("[opt-emit]     tid=unset (placeholder)\n", .{});
        return null; // placeholder: unknown type -> cannot prove semantics
    }
    // A payloadless enum is a discriminant word: the AST represents both the value (`LLVMConstInt(val_type,
    // tag)`) and a `Color` param as the i64 word, and compares two of them with a plain signed `icmp` (see
    // expressions.zig: "non-tagged enums are plain integer tags and already compare correctly via the integer
    // path"). So it is a signed 64-bit int for every gate: param/return admit it as a scalar, and `==`/`!=`
    // (and any incidental ordering) emit the identical i64 compare. No narrowing ever applies (val_type width).
    if (payloadlessEnumDeclForTid(compiler, tid) != null) return .{ .width = 64, .signed = true, .is_bool = false };
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

// True if `tid` is a 64-bit float (`double`). A float value flows as the i64 word = the double's bit
// pattern; ops bitcast i64<->double transiently. Scoped to f64 (8 bytes, clean i64 bitcast); f32 and decimal
// (which pack differently in the word) fall back.
fn isF64Tid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return switch (st.get(tid)) {
        .prim => |p| p.kind == .float and p.bits == 64,
        else => false,
    };
}

// True if `tid` is a 32-bit float (`f32`/`float`). B3 f32 extension: in THIS backend an f32 is PROMOTED to
// double everywhere in scalar code -- its local/param slot is `double`, its i64 word carries the DOUBLE's
// 64-bit bit pattern (castToValType FPExts f32->double then bitcasts), and the AST binop path bitcasts the
// word straight to DoubleType and computes at double precision (never FPTrunc'ing between ops). A float
// literal is `LLVMConstReal(DoubleType, val)` for f32 too. So an f32 value is bit-for-bit a double in the
// word, and the emit path handles it with the SAME DoubleType bitcast as f64 -- using LLVMFloatType (the
// 32-bit width) would reinterpret garbage. Scalar f32 only: f32 struct FIELDS and f32 ARRAYS keep the real
// 32-bit storage and still fall back.
fn isF32Tid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return switch (st.get(tid)) {
        .prim => |p| p.kind == .float and p.bits == 32,
        else => false,
    };
}

// A scalar float that flows as the DOUBLE's bit pattern in the i64 word: f64, or f32 (promoted to double).
// Both take the identical DoubleType-bitcast emit path; the only difference is the source width, which is
// invisible here because f32 was already FPExt'd to double at the value-word boundary.
fn isFloatWordTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    return isF64Tid(compiler, tid) or isF32Tid(compiler, tid);
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
        var ptypes: [32]types.LLVMTypeRef = undefined;
        if (nargs > ptypes.len) return null;
        core.LLVMGetParamTypes(fn_type, &ptypes);
        for (ptypes[0..nargs]) |pt| if (pt != vt) return null;
    }
    const ret = core.LLVMGetReturnType(fn_type);
    if (ret != vt and ret != compiler.void_type) return null;
    return .{ .fn_val = fn_val, .fn_type = fn_type };
}

// True if `tid` is the `string` primitive. A string is an ARC-managed heap pointer that flows as the i64
// word like a class param, but its release needs no destructor (single allocation, no nested owned fields),
// so it is the one owned type the D1/D2 ARC slice can emit (retain/release with a null dtor).
fn isStringTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return st.get(tid) == .string;
}

// How to emit `object[idx]` for a given object TypeId. `string` indexes a byte; `array_word` GEPs the
// i64-word element base. Null (fall back) for anything else, incl. float-element arrays (they need a float
// load type + GEP the emit path does not yet do) and lists/maps (their element access is a method call).
// True if `tid` is a non-float array. Such a param flows as a clean `ptr` argument (the signature builder
// makes array params ptr_type); it round-trips through the i64 slot (both 8 bytes) and index_get's
// arrayBasePtr handles it. Only used read-only via index_get in this slice.
fn isArrayWordTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return switch (st.get(tid)) {
        .array => |ar| blk: {
            const et = st.get(ar.elem);
            break :blk !(et == .prim and et.prim.kind == .float);
        },
        else => false,
    };
}

// True if `tid` is a tuple whose EVERY element is a scalar int/bool. A tuple is a positional heap aggregate
// (N i64 words, element k at k*8). A scalar tuple has no owned elements, so its construction needs no element
// retain and its element reads load the i64 word directly -- exactly what the AST emits. A tuple with a
// string / float / nested-aggregate element needs element ARC (or a float/bit read) the AST threads but this
// slice does not, so it falls back. The tuple's OWN heap release (a no-op-body tuple destructor + free) is
// still emitted for the scalar case (see the .release gate/emit).
fn isScalarTupleTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return switch (st.get(tid)) {
        .tuple => |elems| blk: {
            if (elems.len == 0) break :blk false;
            for (elems) |et| if (intKindForTid(compiler, et) == null) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

const IndexKind = enum { string, array_word };
fn indexKind(compiler: *LlvmCompiler, otid: mir.TypeId) ?IndexKind {
    const st = compiler.type_store orelse return null;
    if (otid == mir.unset_ty or @intFromEnum(otid) >= st.count()) return null;
    return switch (st.get(otid)) {
        .string => .string,
        .array => |ar| blk: {
            const et = st.get(ar.elem);
            if (et == .prim and et.prim.kind == .float) break :blk null; // float arrays: deferred
            break :blk .array_word;
        },
        // A scalar tuple indexes exactly like an array of words: `t[k]` inttoptr's the base + GEPs the k-th
        // i64 word. (indexKind takes only the object type; gating to all-scalar tuples keeps every element a
        // word, byte-identical to the AST index path, which never takes the float branch for a tuple.)
        .tuple => if (isScalarTupleTid(compiler, otid)) .array_word else null,
        else => null,
    };
}

// True if `addr` is defined by an `alloc` (a real stack slot, i.e. a valid pointer to store into). Any other
// store target -- e.g. the index_get result an unmodelled `a[i] = v` lvalue lowers to -- is not a pointer.
fn storeAddrIsAlloc(mf: *const mir.Func, addr: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.result == addr) return inst.op == .alloc;
        }
    }
    return false;
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
// A value struct usable as a read-only i64-word param: a known value struct whose fields are all scalar. It
// flows as the address of its inline bytes; field reads are base+offset like a heap struct. Construction,
// mutation (field_set), copy-on-assign, and returns of a value struct need the by-value copy ABI and stay on
// the AST path (rejected by their gates), so a value-struct param that is only READ is what this admits.
fn emittableValueStructParamTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    const nm = compiler.symbolName(tid) catch return false;
    const base = types_mod.getStructBaseName(nm);
    const sd = compiler.structs.get(base) orelse return false;
    if (!compiler.isValueStructName(base)) return false;
    for (sd.fields) |f| if (!isScalarFieldTypeRef(f.type_name)) return false;
    return true;
}

fn emittableHeapStructTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    const nm = compiler.symbolName(tid) catch return false;
    const base = types_mod.getStructBaseName(nm);
    if (!compiler.structs.contains(base)) return false;
    return !compiler.isValueStructName(base);
}

// True if `tid` is a TRAIT type (a trait object). A trait object is a fat pointer -- a heap-allocated
// {struct_ptr, vtable} pair -- that flows as the i64 pointer word (declarations.zig types every non-array
// param as val_type). It is BORROWED when passed as a param: the callee dispatches through it read-only and
// does NOT retain/release it (the caller owns the object), so a trait param needs no ARC threading -- which
// matches lower_ast_hir, which threads releases only for owned LOCALS, never params. Only used to admit a
// trait-typed param whose body dispatches one or more sync trait methods on it (D5).
fn emittableTraitParamTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    const nm = compiler.symbolName(tid) catch return false;
    const base = types_mod.getStructBaseName(nm);
    return compiler.traits.contains(base);
}

// D5: resolve a MIR `indirect_call` to a concrete trait vtable slot, or null (-> fall back to the AST). The
// receiver's threaded TypeId must name a known TRAIT, and the method name must be one of that trait's
// methods; the returned index is the method's position in the trait declaration (the vtable stores the
// destructor at slot 0 and method k at slot k+1, so the emit adds 1). An ASYNC trait method is a coroutine
// (spawn/await + a driven handle) that this path does not model -- rejected here so async stays on the AST.
fn traitDispatchSlot(compiler: *LlvmCompiler, mf: *const mir.Func, x: anytype) ?u32 {
    const mname = x.name orelse return null;
    const rtid = mf.typeOf(x.receiver);
    if (rtid == mir.unset_ty) return null;
    const nm = compiler.symbolName(rtid) catch return null;
    const base = types_mod.getStructBaseName(nm);
    const trait = compiler.traits.get(base) orelse return null;
    for (trait.methods, 0..) |tm, idx| {
        if (std.mem.eql(u8, tm.name, mname)) {
            if (tm.is_async) return null; // async trait dispatch (coroutine) is not modelled here
            return @intCast(idx);
        }
    }
    return null;
}

// True if Value `v` is defined by a `.param` instruction -- i.e. it is a function argument, not a local.
fn valueIsParam(mf: *const mir.Func, v: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.result == v) return inst.op == .param;
        }
    }
    return false;
}

// True if a trait dispatch receiver `v` is a caller-built fat pointer: it is a function PARAM directly, OR
// a LOAD from a slot that is stored ONLY param values (a repeated `sh.method()` that mem2reg left as a load
// of the param slot rather than forwarding the `.param` value). This EXCLUDES a trait LOCAL that could hold
// a struct implicitly WIDENED to the trait (`let a: Shape = Sq{...}`) -- a conversion the emit path does not
// model: such a slot's stored value is a struct_new / widened value, not a param, so it is rejected here
// (and, being an owned trait local, it is also rejected by the string-only .release gate). A trait object
// passed in as a param is always well-formed (the caller ran constructTraitObject), so dispatching on it is
// safe. Anything else (a field/array/call-result trait value) falls back to the AST.
fn receiverIsParamBacked(mf: *const mir.Func, v: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.result != v) continue;
            switch (inst.op) {
                .param => return true,
                .load => |ld| {
                    // The slot must receive at least one store, and every store into it must be a param.
                    var any = false;
                    for (mf.blocks.items) |*b2| {
                        for (b2.insts.items) |s| {
                            if (s.op == .store and s.op.store.addr == ld.addr) {
                                any = true;
                                if (!valueIsParam(mf, s.op.store.val)) return false;
                            }
                        }
                    }
                    return any;
                },
                else => return false,
            }
        }
    }
    return false;
}

// True if the callee named `name` declares a TRAIT-typed parameter among its first `nargs` params. Passing
// an argument to a trait param may require implicit struct->trait WIDENING at the call site (the AST builds
// the fat pointer via constructTraitObject); the emit path passes args as raw words with NO coercion, so it
// cannot widen. Such a call is rejected -> the function falls back to the AST. This also closes a pre-existing
// emit-path miscompile: a function that constructs a trait object and passes it to a trait-param free
// function emitted the raw struct pointer (a non-fat pointer), crashing the callee's first vtable load.
fn calleeHasTraitParam(compiler: *LlvmCompiler, name: []const u8, nargs: usize) bool {
    var i: usize = 0;
    while (i < nargs) : (i += 1) {
        const ptn = compiler.getFunctionParamType(name, i) orelse continue;
        defer compiler.allocator.free(ptn);
        if (compiler.traits.contains(types_mod.getStructBaseName(ptn))) return true;
    }
    return false;
}

// True if `tr` is the bare `string` type-ref. `string` is the one OWNED (non-scalar) field the emit path
// can construct + release: a struct whose only owned fields are strings is released via its real
// `__destruct_<Struct>`, which releases each string field with a null dtor (a single heap allocation, no
// further owned fields). Any other owned field (class/list/nested struct/error-union/optional) is excluded.
fn isStringFieldTypeRef(tr: ast.TypeRef) bool {
    return tr == .ident and std.mem.eql(u8, tr.ident, "string");
}

// How a struct-with-string-fields local is dropped at scope end:
//   .heap  -- a reference/heap struct (class, or an escaping struct): `nova_release(ptr, __destruct_*)`
//             decrefs, runs the destructor (which releases the string fields), then frees the payload.
//   .value -- a value struct (inline stack bytes, no ARC header): `dropValueStruct` calls __destruct_*
//             DIRECTLY on the storage address to release the string fields, and does NOT free (it is stack).
const StructDropKind = enum { heap, value };

// D3: classify a struct whose owned fields are ALL bare strings (every field is scalar or `string`). Returns
// how to drop it, or null if `tid` is not such a struct. The `__destruct_<Struct>` the AST backend generates
// releases each string field (null dtor). Any field that is not scalar-or-string (class/list/nested struct/
// error-union/optional/type-param) yields null -> the whole function falls back to the AST.
fn stringFieldStructDropKind(compiler: *LlvmCompiler, tid: mir.TypeId) ?StructDropKind {
    if (tid == mir.unset_ty) return null;
    const nm = compiler.symbolName(tid) catch return null;
    const base = types_mod.getStructBaseName(nm);
    const sd = compiler.structs.get(base) orelse return null;
    for (sd.fields) |f| {
        if (isScalarFieldTypeRef(f.type_name)) continue;
        if (isStringFieldTypeRef(f.type_name)) continue;
        return null; // any other owned field kind -> fall back
    }
    return if (compiler.isValueStructName(base)) .value else .heap;
}

// True if Value `v` is defined by a `const_str` (an immortal interned string literal). A literal stored
// into a struct's string field is MOVED in with NO retain (immortal: retain/release are no-ops), so no ARC
// threading is needed at construction. A NON-literal string field arg (a named owner) would need a retain
// the emit path does not thread at struct_new, so only const_str string fields are admitted for construction.
fn isConstStrResult(mf: *const mir.Func, v: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.result == v) return inst.op == .const_str;
        }
    }
    return false;
}

// True if `tid` is a REFERENCE (pointer) word: a string, a reference optional, or a heap struct. These all
// flow as an i64 pointer word, so an `eq`/`ne` compare between two of them -- or between one and the null
// word (`undefined`/`null` == const_int 0) -- is a plain `icmp eq/ne i64`, exactly what the AST emits for a
// nullable-pointer comparison. Ordering (<,>) is meaningless on pointers, so only eq/ne uses this.
fn isRefWordTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (isStringTid(compiler, tid) or emittableRefOptionalTid(compiler, tid) or emittableHeapStructTid(compiler, tid)) return true;
    // `ptr` -- the raw unsigned pointer word a reference-optional param/local is often typed as inside the
    // body -- is a word-repr primitive. It is not a signed int, so the ordinary int eq/ne arm rejects it, but
    // `icmp eq/ne i64` on the pointer word is exactly right (and sign-agnostic), so treat it as a ref word.
    if (tid != mir.unset_ty) {
        if (compiler.symbolName(tid) catch null) |nm| {
            if (types_mod.cgPrim(nm)) |p| return p.repr == .word;
        }
    }
    return false;
}

// True if `tr` is an OPTIONAL type-ref whose present arm is a reference type (string or a heap/class struct).
// Such an optional is a plain nullable pointer word, so concreteTidForTypeRef can strip it to the inner
// reference tid and the string / heap-struct param/return gate accepts it. A VALUE optional (`int|undefined`,
// a value struct | undefined) is boxed and must stay on the AST path, so this returns false for it.
fn isRefOptionalTypeRef(compiler: *LlvmCompiler, tr: ast.TypeRef) bool {
    if (tr != .optional) return false;
    const itid = compiler.concreteTidForTypeRef(tr.optional.*) orelse return false;
    return isStringTid(compiler, itid) or emittableHeapStructTid(compiler, itid);
}

// True if the two operands of an `eq`/`ne` are a reference-word comparison the emit path handles as a bare
// `icmp` on the words: at least one side is a reference word, and the other is a reference word OR an integer
// (the null literal `undefined`/`null` lowers to `const_int 0`, an int-typed word). Pure int/bool eq/ne does
// NOT match here (neither side is a reference word) and stays on the existing signed-word compare arm.
fn isRefWordEq(compiler: *LlvmCompiler, mf: *const mir.Func, x: anytype) bool {
    const lt = mf.typeOf(x.lhs);
    const rt = mf.typeOf(x.rhs);
    const lref = isRefWordTid(compiler, lt);
    const rref = isRefWordTid(compiler, rt);
    if (!lref and !rref) return false; // pure int/bool: handled elsewhere
    const lok = lref or intKindForTid(compiler, lt) != null;
    const rok = rref or intKindForTid(compiler, rt) != null;
    return lok and rok;
}

// True if `tid` is a REFERENCE optional -- `<reference-type> | undefined` (e.g. `string | undefined`,
// `Foo | undefined`). A reference optional is a plain nullable pointer: `undefined` is the null word (0),
// present is the payload pointer, and the AST does NOT box it (types_mod.valueOptionalName is false). The
// emit path already lowers `.undefined` to `const_int 0` (lower_hir_mir) and flows the present value as its
// word, so a reference optional is byte-identical to the AST. A VALUE optional (`int | undefined`) IS boxed
// (nova_valopt_box, so a present 0 is distinguishable from absent) -- that encoding is not emitted here, so
// valueOptionalName-typed optionals are excluded and fall back.
// If `tid` is a store `.optional` whose inner is a REFERENCE type (string or a non-value struct/class),
// return that inner tid; else null. The type_store is authoritative and, crucially, sees the `.optional`
// even when its rendered NAME drops the `| undefined` (e.g. `string | undefined` renders as `string`, which
// the name-based path below cannot recognise -- that is why B6's string-optional params were not emitting).
// A VALUE optional (`.optional` inner prim/decimal/value-struct) returns null: its boxed encoding is NOT a
// nullable word and must fall back.
fn refOptionalInner(compiler: *LlvmCompiler, tid: mir.TypeId) ?mir.TypeId {
    const st = compiler.type_store orelse return null;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return null;
    const t = st.get(tid);
    if (t != .optional) return null;
    const inner = t.optional;
    if (isStringTid(compiler, inner)) return inner;
    if (emittableHeapStructTid(compiler, inner)) return inner;
    return null;
}

// True if `tid` is a BOXED VALUE optional: a store `.optional` whose inner is a VALUE type (int/bool/float/
// decimal/value-struct). The AST path boxes such a value (nova_valopt_box) so that a present 0 is
// distinguishable from absent, but the emit path has no boxing and would flow the raw word -- which
// miscompiles both a materialised `let z: int | undefined = 0` (stored as raw 0, then unboxed by a callee as
// a pointer) and `f(undefined)` (passed as 0, not the sentinel). The whole-function HIR `.undefined` guard
// only catches a MATERIALISED `undefined` literal, not a value-optional that arrives via a typed local or a
// call result, so gate on the TYPE here: any value-optional-typed MIR value forces the function to the AST.
fn isValueOptionalTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    const st = compiler.type_store orelse return false;
    if (tid == mir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    const t = st.get(tid);
    if (t != .optional) return false;
    return refOptionalInner(compiler, tid) == null; // an optional that is NOT a reference optional == value optional
}

fn emittableRefOptionalTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    // Store-authoritative first: a `.optional` type is decided purely by its inner's reference-ness (this
    // catches the `string | undefined` case whose rendered name is just `string`). A store `.optional` with a
    // VALUE inner is a boxed value optional -> reject here, do NOT fall through to the name heuristic.
    if (compiler.type_store) |st| {
        if (@intFromEnum(tid) < st.count() and st.get(tid) == .optional) {
            return refOptionalInner(compiler, tid) != null;
        }
    }
    const nm = compiler.symbolName(tid) catch return false;
    if (std.mem.indexOfScalar(u8, nm, '|') == null) return false; // not a union/optional
    if (types_mod.valueOptionalName(nm)) return false; // boxed value-optional: not emitted here
    // Must be exactly `<arm> | undefined` (two arms, one of them `undefined`), and the present arm a
    // reference type: a string or a known (non-value) struct/class. Anything else falls back.
    const bar = std.mem.indexOfScalar(u8, nm, '|').?;
    const lhs = std.mem.trim(u8, nm[0..bar], " ");
    const rhs = std.mem.trim(u8, nm[bar + 1 ..], " ");
    if (std.mem.indexOfScalar(u8, rhs, '|') != null) return false; // more than two arms
    const arm = if (std.mem.eql(u8, rhs, "undefined")) lhs else if (std.mem.eql(u8, lhs, "undefined")) rhs else return false;
    if (std.mem.eql(u8, arm, "string")) return true;
    const base = types_mod.getStructBaseName(arm);
    if (compiler.structs.contains(base) and !compiler.isValueStructName(base)) return true;
    return false;
}

// True if `tid` is `string | undefined` specifically: a reference optional whose present payload is a
// `string`. Its ARC contract is a plain string's -- single allocation, null destructor, and releasing the
// null word (absent) is a no-op -- so retain/release on it is emittable exactly like a bare string. A
// class-payload optional (`Foo | undefined`) needs the struct's `__destruct_*` and is excluded here.
fn isStringRefOptionalTid(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    // Store-authoritative: a `.optional` whose inner is a `string` (the rendered name would just be `string`).
    if (compiler.type_store) |st| {
        if (@intFromEnum(tid) < st.count() and st.get(tid) == .optional) {
            return isStringTid(compiler, st.get(tid).optional);
        }
    }
    const nm = compiler.symbolName(tid) catch return false;
    const bar = std.mem.indexOfScalar(u8, nm, '|') orelse return false;
    if (types_mod.valueOptionalName(nm)) return false;
    const lhs = std.mem.trim(u8, nm[0..bar], " ");
    const rhs = std.mem.trim(u8, nm[bar + 1 ..], " ");
    if (std.mem.indexOfScalar(u8, rhs, '|') != null) return false;
    const arm = if (std.mem.eql(u8, rhs, "undefined")) lhs else if (std.mem.eql(u8, lhs, "undefined")) rhs else return false;
    return std.mem.eql(u8, arm, "string");
}

// True if `tid` is a VALUE optional (`int | undefined`, `bool | undefined`, `f64 | undefined`, or a value
// struct | undefined): one the AST BOXES via nova_valopt_box, so a present 0 is a NON-NULL heap box and only
// absent is the null word. The emit path does NOT model that box/unbox (it would need node-by-node boxing on
// every store/return/arg into the optional and an unbox on every payload read, plus the box temporary's ARC
// release -- see optimiser-pending.md B6), so ANY value flowing as a value optional falls back to the AST.
// This is the guard that keeps the two engines byte-identical: without it a present 0 emits as the absent
// word (miscompile) and a payload read dereferences the raw scalar as a pointer (ASAN). A REFERENCE optional
// (`string | undefined`, class `T | undefined`) is NOT boxed (0 == absent, present is the payload pointer),
// so valueOptionalName is false for it and it stays emittable -- see isStringRefOptionalTid / case 351.
fn tidIsValueOptional(compiler: *LlvmCompiler, tid: mir.TypeId) bool {
    if (tid == mir.unset_ty) return false;
    const nm = compiler.symbolName(tid) catch return false;
    return types_mod.valueOptionalName(nm);
}

// True if a direct call to `name` with `nargs` arguments delivers ANY argument into a value-optional
// PARAMETER. The AST boxes such an argument at the call site (compileCallArgument -> buildValoptBox); the emit
// path passes the raw word, so the callee -- whether AST or emitted -- reads a present value as absent (a
// present 0 is the null word) or dereferences the raw scalar on unbox. resolveCallee accepts the callee
// because a boxed value optional IS an i64 word in the signature, which is exactly why the plain all-word
// check is not enough. We recover the callee's declared parameter TypeRefs by name and reject if any is a
// value optional. Checked under both the resolved (module-namespaced) and the raw source name.
fn callTargetsValueOptionalParam(compiler: *LlvmCompiler, name: []const u8, nargs: usize) bool {
    const resolved = compiler.resolveCalleeName(name) catch name;
    var i: usize = 0;
    while (i < nargs) : (i += 1) {
        const tr = compiler.getFunctionParamTypeRef(resolved, i) orelse
            compiler.getFunctionParamTypeRef(name, i) orelse continue;
        if (compiler.valoptTypeRefIsValue(tr)) return true;
    }
    return false;
}

// Dry validation: return false if any instruction OR terminator is outside the emittable subset, building
// NO IR. This MUST run before emitFunc touches the builder -- otherwise a mid-stream reject would leave a
// half-emitted block that the AST fallback then double-fills. Keep the per-op gates in sync with emitBinop /
// the cast arm, and the terminator gates in sync with emitFunc.
fn mirEmittable(compiler: *LlvmCompiler, mf: *const mir.Func) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            // A boxed value optional cannot be represented on the emit path (no boxing) -- reject the whole
            // function so it falls back to the AST, which boxes it. Every MIR Value is an inst result, so
            // gating each inst's type covers all value-optional-typed values (locals, call results, params).
            if (isValueOptionalTid(compiler, inst.ty)) return false;
            if (!mirInstEmittable(compiler, mf, inst)) return false;
        }
        switch (b.term) {
            .ret => |x| if (x) |rv| {
                // A heap-struct return must transfer a balanced +1 to the caller (which releases it as an
                // owned temporary). Two shapes qualify: (1) a FRESH construction (`struct_new`, rc=1, moved
                // out) -- also covers a returned owned LOCAL, whose slot forwards to its struct_new; and
                // (2) a BORROWED value (a param / field) that the return path RETAINED (D4). Anything else
                // (an un-retained borrow) would under-retain -> double-free, so reject it.
                if (emittableHeapStructTid(compiler, mf.typeOf(rv)) and !isStructNewResult(mf, rv) and !isRetainedResult(mf, rv)) return false;
            },
            .br, .condbr, .unreachable_ => {},
            .switch_ => return false,
        }
    }
    return true;
}

fn mirInstEmittable(compiler: *LlvmCompiler, mf: *const mir.Func, inst: mir.Inst) bool {
    {
        {
            // A value flowing AS a value optional is never emittable: whatever instruction produces it (a call
            // that RETURNS `int | undefined`, a `let` / temp typed as one) would have to box the payload, and
            // every downstream read would have to unbox -- neither modelled here (see tidIsValueOptional). The
            // whole-function param/return gate already rejects a value-optional signature; this catches a value
            // optional materialised or bound INSIDE an otherwise-scalar function (e.g. a local from a valopt
            // call). Reject the function so it falls back to the AST, which boxes/unboxes correctly.
            if (tidIsValueOptional(compiler, inst.ty)) return false;
            switch (inst.op) {
                .binop => |x| {
                    // FLOAT (f64/f32) binop (B3): both operands float; arithmetic (add/sub/mul/div) or a
                    // compare. No mod/shift/bitwise on float. The emit path bitcasts to double and back.
                    // f32 is promoted to double in this backend, so an f32 operand takes the identical path
                    // (double bits in the word); mixed f32/f64 is fine because both are double-repr.
                    if (isFloatWordTid(compiler, mf.typeOf(x.lhs))) {
                        if (!isFloatWordTid(compiler, mf.typeOf(x.rhs))) return false;
                        switch (x.op) {
                            .add, .sub, .mul, .div => if (!isFloatWordTid(compiler, inst.ty)) return false,
                            .eq, .ne, .lt, .le, .gt, .ge => {}, // result is bool (word 0/1)
                            else => return false,
                        }
                        return true;
                    }
                    // Reference-word eq/ne (string / ref-optional / heap pointer vs another such, or vs the
                    // null word): a bare `icmp eq/ne i64`, result bool. Ordering never applies to pointers.
                    if ((x.op == .eq or x.op == .ne) and isRefWordEq(compiler, mf, x)) return true;
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
                // Cast is int<->int only: both operand and result must be integer kinds. The emitter
                // canonicalises to the result width (trunc+sext/zext), which is exact for int<->int but wrong
                // for float<->int (that needs fptosi/sitofp) or pointer casts -- so gate the OPERAND too.
                .cast => |x| {
                    if (intKindForTid(compiler, mf.typeOf(x.val)) == null) return false;
                    if (intKindForTid(compiler, inst.ty) == null) return false;
                },
                // A direct call is emittable if its callee resolves to an all-word LLVM function (below).
                // The result type, if the value is used arithmetically, is gated by the consuming binop.
                .call => |x| {
                    const nm = x.name orelse return false;
                    if (resolveCallee(compiler, nm, x.args.len) == null) return false;
                    // A callee with a trait-typed param may need the arg WIDENED to a trait object (a
                    // fat pointer) at the call site; the emit path cannot widen, so fall back (D5).
                    if (calleeHasTraitParam(compiler, nm, x.args.len)) return false;
                    // An argument delivered into a value-optional PARAMETER must be boxed at the call site (the
                    // AST does this); the emit path passes the raw word, so it would pass a present 0 as the
                    // absent null word and a present value's raw scalar where the callee expects a box pointer
                    // to unbox. resolveCallee cannot see this (a boxed value optional is an i64 word), so gate
                    // on the callee's declared parameter types and fall back if any target is a value optional.
                    if (callTargetsValueOptionalParam(compiler, nm, x.args.len)) return false;
                },
                // Heap OR value struct, fully initialised (every declared field supplied so we never rely on
                // zero-init), whose fields are all scalar or bare-`string`-with-a-const_str-literal value (D3).
                .struct_new => |x| {
                    // Fully initialised (every declared field supplied so we never rely on zero-init). A value
                    // struct constructs into inline stack bytes (buildValueStructStorage) and must not escape;
                    // escape analysis HEAP-PROMOTES any struct that is constructed-and-returned (so a returned
                    // struct is `!isValueStructName` here and takes the heap alloc branch instead), and the
                    // field gates reject struct-in-struct -- so a value-lowered construction cannot outlive the fn.
                    const sd = compiler.structs.get(x.type_name) orelse return false;
                    if (sd.fields.len != x.args.len or sd.fields.len != x.field_names.len) return false;
                    // Scalar fields, OR a bare `string` field whose arg is a const_str literal -- an immortal
                    // literal moved in needs NO retain, so no ARC threading at construction. A non-literal
                    // string field (a named owner) would need a retain we do not thread here, so it falls back.
                    // Holds for BOTH a heap struct (released via nova_release + real __destruct_<Struct>) and a
                    // value struct (inline stack bytes, dropped via dropValueStruct -- direct destructor call,
                    // no free). The .release gate/emit picks the right drop by the value's type.
                    for (x.field_names, x.args) |fname, arg| {
                        const ftr = fieldTypeRef(compiler, x.type_name, fname) orelse return false;
                        if (isScalarFieldTypeRef(ftr)) continue;
                        if (isStringFieldTypeRef(ftr) and isConstStrResult(mf, arg)) continue;
                        return false;
                    }
                },
                // Tuple construction: emittable iff EVERY element is a scalar int/bool (no owned/float element
                // to retain or bit-read). The result TypeId must itself be a scalar tuple. This mirrors the
                // AST's nova_bytes_alloc + offset-store sequence with no element ARC.
                .tuple_new => |x| {
                    if (!isScalarTupleTid(compiler, inst.ty)) return false;
                    for (x.args) |arg| if (intKindForTid(compiler, mf.typeOf(arg)) == null) return false;
                },
                .field_get => |x| {
                    // Reads work for BOTH a heap struct (payload pointer) and a value struct (its inline byte
                    // address): field offsets are payload-relative in both, so `base + offset` + load is the
                    // same. Only scalar fields (owned/float/nested fields need ARC / the float path).
                    const sname = structBaseNameOf(compiler, mf, x.base) orelse return false;
                    const ftr = fieldTypeRef(compiler, sname, x.field) orelse return false;
                    if (!isScalarFieldTypeRef(ftr)) return false;
                },
                .field_set => |x| {
                    // Scalar-field write into a heap OR value struct: `base + offset` + store, identical to the
                    // AST for the same address, so it matches whatever the value-struct aliasing semantics are.
                    // Owned/float/nested fields (ARC / float path) stay on the AST.
                    const sname = structBaseNameOf(compiler, mf, x.base) orelse return false;
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
                // ARC gates, merged D3 + D4:
                // A RETAIN is a plain refcount bump (`nova_retain(ptr)`) that needs NO destructor, so it is
                // emittable on a string, a string-optional, OR a heap (class / reference) struct pointer word
                // (D4: the return-acquisition retain of a borrowed struct return -- the caller owns the
                // matching release).
                .retain => |x| if (!isStringTid(compiler, mf.typeOf(x.val)) and !isStringRefOptionalTid(compiler, mf.typeOf(x.val)) and !emittableHeapStructTid(compiler, mf.typeOf(x.val))) return false,
                // A RELEASE is emittable on a string / string-optional (null dtor), OR a struct whose owned
                // fields are all strings (D3) -- released via its real `__destruct_<Struct>` (heap) or a direct
                // destructor call on its inline storage (value struct). Other owned types (class-with-non-
                // string-fields / list / nested-struct / error-union) still need dtor resolution -> fall back.
                // ... OR a scalar tuple (D-tuple): its own heap allocation is freed via the tuple destructor
                // (a no-op body -- no owned elements -- so `nova_release(ptr, __destruct_<tuple>)` just decrefs
                // + frees the N words), byte-identical to the AST tuple release.
                .release => |x| if (!isStringTid(compiler, mf.typeOf(x.val)) and !isStringRefOptionalTid(compiler, mf.typeOf(x.val)) and stringFieldStructDropKind(compiler, mf.typeOf(x.val)) == null and !isScalarTupleTid(compiler, mf.typeOf(x.val))) return false,
                // element read (C3): only a string (byte index) or a non-float array (i64-word element).
                .index_get => |x| if (indexKind(compiler, mf.typeOf(x.object)) == null) return false,
                // String interpolation (C5): emittable only when EVERY part is a `string` (interpolated string
                // var or a const_str literal-text run) -- so each append is a plain borrow-copy with no per-part
                // toString/ARC, reproducing the AST StringBuilder path exactly. A non-string part (int/float/
                // optional/decimal) needs the AST's type-dispatched append (numToString + release), not modelled
                // here, so it falls back. Also require the StringBuilder helpers to be resolvable in func_map
                // (any template-using program imports them, but stay safe: fall back if absent).
                .template => |x| {
                    for (x.parts) |p| {
                        if (!isStringTid(compiler, mf.typeOf(p))) return false;
                    }
                    if (compiler.func_map.get("StringBuilder_init") == null) return false;
                    if (compiler.func_map.get("StringBuilder_append") == null) return false;
                    if (compiler.func_map.get("StringBuilder_toString") == null) return false;
                    if (compiler.func_map.get("StringBuilder_delete") == null) return false;
                },
                // A string literal materialises to an immortal interned global -> always emittable, no ARC.
                .const_str => {},
                // A store must target a real slot (an `alloc`). The lowering of an lvalue it does not model --
                // notably an array-element write `a[i] = v` -- falls back to `store <value-as-address>`, i.e.
                // the address is a computed i64 (an index_get result), not a pointer. Emitting that yields
                // `store i64 %v, i64 %addr` which fails LLVM verification. Restricting stores to alloc targets
                // rejects those functions (field writes use field_set, not store).
                .store => |x| if (!storeAddrIsAlloc(mf, x.addr)) return false,
                .const_int, .alloc, .load, .param => {},
                // Trait dynamic dispatch (D5): a method call through a trait fat pointer. Emittable only when
                // the receiver resolves to a known trait + the method resolves to a vtable slot (sync only).
                // Minimal slice: NO extra args (self only) and a SCALAR int/bool result -- so there is no
                // argument-ARC or non-word return to reproduce. A void / string / struct-returning method, or
                // one taking extra args, falls back to the AST until those ABIs are threaded.
                .indirect_call => |x| {
                    if (traitDispatchSlot(compiler, mf, x) == null) return false;
                    // Receiver must be a caller-built trait fat pointer (a param, or a param-backed slot
                    // load), never a local that could hold an un-widened struct. See receiverIsParamBacked.
                    if (!receiverIsParamBacked(mf, x.receiver)) return false;
                    if (x.args.len != 0) return false;
                    if (intKindForTid(compiler, inst.ty) == null) return false;
                },
                else => return false, // gep/await/spawn -> not yet
            }
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

// True if Value `v` is the operand of a `retain` in this function -- i.e. the return path bumped its
// refcount (D4's return-acquisition of a borrowed struct). Paired with the caller releasing the returned
// temporary, this balances ownership out. Used only to admit a borrowed heap-struct return.
fn isRetainedResult(mf: *const mir.Func, v: mir.Value) bool {
    for (mf.blocks.items) |*b| {
        for (b.insts.items) |inst| {
            if (inst.op == .retain and inst.op.retain.val == v) return true;
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
        // A string literal (C8): materialise it via the SAME interned immortal global the AST path uses, so a
        // literal shared with AST-compiled code is the same object. Immortal (negative refcount) -> retain/
        // release are no-ops, so no ARC is needed even though it is a string.
        .const_str => |s| try compiler.getOrCreateStringLiteral(s),
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
            // A value struct constructs into INLINE STACK bytes (no ARC header), same address representation as
            // a heap payload; a class/heap struct allocates the ref-counted payload. Field stores below are
            // identical for both (base + offset). A value struct that would ESCAPE (returned, or stored into a
            // heap field) is rejected by the return / field gates, so its stack storage cannot outlive the fn.
            const struct_ptr = if (compiler.isValueStructName(x.type_name))
                try compiler.buildValueStructStorage(total)
            else
                try compiler.compileAlloc(core.LLVMConstInt(vt, total, 0));
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
        // Tuple construction: allocate N i64 words (nova_bytes_alloc), store each element word at offset k*8 --
        // the exact nova_bytes_alloc + add/inttoptr/store sequence the AST tuple path emits (expressions.zig).
        // Every element is a scalar word (gated by mirEmittable), so no per-element cast or retain is needed.
        .tuple_new => |x| blk: {
            const total: u64 = @as(u64, x.args.len) * 8;
            const tuple_ptr = try compiler.compileAlloc(core.LLVMConstInt(vt, total, 0));
            for (x.args, 0..) |arg, idx| {
                const off = core.LLVMConstInt(vt, idx * 8, 0);
                const addr = core.LLVMBuildAdd(compiler.builder, tuple_ptr, off, "");
                const eptr = core.LLVMBuildIntToPtr(compiler.builder, addr, compiler.ptr_type, "");
                const av = vals[@intFromEnum(arg)] orelse return error.Unemittable;
                _ = core.LLVMBuildStore(compiler.builder, av, eptr);
            }
            break :blk tuple_ptr;
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
        // Element read `object[idx]` (C3). String: obj+idx is a byte address (load i8, zext to the word).
        // Array: GEP the i64-word element base (arrays store every element as the word; float arrays are
        // rejected by mirEmittable). Mirrors the AST index path (expressions.zig). No bounds check -- the AST
        // path emits none here either.
        .index_get => |x| blk: {
            const obj = vals[@intFromEnum(x.object)] orelse return error.Unemittable;
            const idx = vals[@intFromEnum(x.idx)] orelse return error.Unemittable;
            const kind = indexKind(compiler, mf.typeOf(x.object)) orelse return error.Unemittable;
            switch (kind) {
                .string => {
                    const addr = core.LLVMBuildAdd(compiler.builder, obj, idx, "");
                    const p = core.LLVMBuildIntToPtr(compiler.builder, addr, compiler.ptr_type, "");
                    const byte = core.LLVMBuildLoad2(compiler.builder, compiler.i8_type, p, "");
                    break :blk core.LLVMBuildZExt(compiler.builder, byte, vt, "");
                },
                .array_word => {
                    const base = compiler.arrayBasePtr(obj);
                    var idxs = [_]types.LLVMValueRef{idx};
                    const ep = core.LLVMBuildInBoundsGEP2(compiler.builder, vt, base, &idxs, 1, "");
                    break :blk core.LLVMBuildLoad2(compiler.builder, vt, ep, "");
                },
            }
        },
        // ARC (D2, strings only -- gated by mirEmittable to string operands). A string is a single heap
        // allocation with no nested owned fields, so its release needs NO destructor (nova_release(ptr, null)
        // just decrefs and frees). retain is nova_retain(ptr). These reproduce the AST path's ARC calls;
        // arc_elision may already have cancelled balanced pairs before we get here.
        .retain => |x| blk: {
            try compiler.compileRetain(vals[@intFromEnum(x.val)] orelse return error.Unemittable);
            break :blk null;
        },
        .release => |x| blk: {
            const v = vals[@intFromEnum(x.val)] orelse return error.Unemittable;
            const tid = mf.typeOf(x.val);
            // A string / string-optional releases with a NULL dtor (single allocation, no owned fields). A
            // string-owned-field heap struct (D3) releases via its REAL __destruct_<Struct>, resolved here
            // exactly as the AST path does (getOrCreateDestructorPreferId, keyed on the value's TypeId), so
            // its string fields are released and there is no duplicate destructor. The gate proved it is one
            // of these two shapes.
            if (isStringTid(compiler, tid) or isStringRefOptionalTid(compiler, tid)) {
                try compiler.compileRelease(v, null);
            } else if (isScalarTupleTid(compiler, tid)) {
                // A scalar tuple: free its N-word heap allocation via the tuple destructor resolved by TypeId
                // (getOrCreateDestructorByTypeId dispatches to the tuple dtor). Its body releases no elements
                // (all scalar), so this is decref -> dtor -> free, exactly as the AST tuple release does.
                const dtor = (compiler.getOrCreateDestructorByTypeId(tid) catch return error.Unemittable) orelse return error.Unemittable;
                try compiler.compileRelease(v, dtor);
            } else {
                const sname = structBaseNameOf(compiler, mf, x.val) orelse return error.Unemittable;
                switch (stringFieldStructDropKind(compiler, tid) orelse return error.Unemittable) {
                    // Heap/reference struct: nova_release with the real destructor (decref -> dtor -> free).
                    .heap => {
                        const dtor = (compiler.getOrCreateDestructorPreferId(sname, tid) catch return error.Unemittable) orelse return error.Unemittable;
                        try compiler.compileRelease(v, dtor);
                    },
                    // Value struct: `v` is the inline-storage address word. Drop its string fields via the
                    // destructor DIRECTLY (no nova_release/free -- it is stack storage), exactly as the AST
                    // path's releaseLocalByName does for a value-struct local.
                    .value => try compiler.dropValueStruct(v, sname, tid),
                }
            }
            break :blk null;
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
            var argbuf: [32]types.LLVMValueRef = undefined;
            if (x.args.len > argbuf.len) return error.Unemittable;
            for (x.args, 0..) |arg, i| argbuf[i] = vals[@intFromEnum(arg)] orelse return error.Unemittable;
            const call = core.LLVMBuildCall2(compiler.builder, c.fn_type, c.fn_val, &argbuf, @intCast(x.args.len), "");
            break :blk if (inst.result != .invalid) call else null;
        },
        // Trait dynamic dispatch (D5): reproduce the AST path's buildTraitVtableCall exactly. The receiver
        // is the trait-object word (a pointer to a {struct_ptr, vtable} pair). Load struct_ptr from offset 0,
        // the vtable from offset ptr_size, then the fn pointer from vtable slot (slot+1)*ptr_size (slot 0 is
        // the destructor), and do an indirect call passing struct_ptr as self. All params/return are the i64
        // word, the fixed trait-method ABI. Gated to sync + zero extra args + scalar result by mirEmittable.
        .indirect_call => |x| blk: {
            const slot = traitDispatchSlot(compiler, mf, x) orelse return error.Unemittable;
            const recv = vals[@intFromEnum(x.receiver)] orelse return error.Unemittable;
            const ptr_size = compiler.ptrElemSize();
            // struct_ptr = *(recv)
            const sp_ptr = core.LLVMBuildIntToPtr(compiler.builder, recv, core.LLVMPointerType(vt, 0), "");
            const struct_ptr = core.LLVMBuildLoad2(compiler.builder, vt, sp_ptr, "");
            // vtable = *(recv + ptr_size)
            const vt_addr = core.LLVMBuildAdd(compiler.builder, recv, core.LLVMConstInt(vt, ptr_size, 0), "");
            const vt_ptr = core.LLVMBuildIntToPtr(compiler.builder, vt_addr, core.LLVMPointerType(vt, 0), "");
            const vtable_int = core.LLVMBuildLoad2(compiler.builder, vt, vt_ptr, "");
            // fn_ptr = *(vtable + (slot+1)*ptr_size)
            const fn_offset = core.LLVMConstInt(vt, (@as(u64, slot) + 1) * ptr_size, 0);
            const fn_addr = core.LLVMBuildAdd(compiler.builder, vtable_int, fn_offset, "");
            const fn_ptr_ptr = core.LLVMBuildIntToPtr(compiler.builder, fn_addr, core.LLVMPointerType(compiler.ptr_type, 0), "");
            const fn_ptr = core.LLVMBuildLoad2(compiler.builder, compiler.ptr_type, fn_ptr_ptr, "");
            // indirect call fn_ptr(struct_ptr): 1 word param (self), word return.
            var params = [_]types.LLVMTypeRef{vt};
            const fn_t = core.LLVMFunctionType(vt, &params, 1, 0);
            var cargs = [_]types.LLVMValueRef{struct_ptr};
            break :blk core.LLVMBuildCall2(compiler.builder, fn_t, fn_ptr, &cargs, 1, "");
        },
        // String interpolation (C5), all-string parts (gated by mirEmittable). Reproduces the AST template
        // lowering (expressions.zig `.template_expr`) EXACTLY for the all-string case:
        //   sb = compileAlloc(sizeof StringBuilder); StringBuilder_init(sb)
        //   for each part v:  StringBuilder_append(sb, v)     // append COPIES + BORROWS -> no per-part ARC
        //   final = StringBuilder_toString(sb)                // the owned result string
        //   StringBuilder_delete(sb); nova_release(sb, null)  // free the StringBuilder itself (null dtor)
        // The part values are borrowed here; any owned string temporary among them gets its own scope-end
        // release from the D2 ARC threading (independent of this op), so ARC stays balanced.
        .template => |x| blk: {
            const sb_init = compiler.func_map.get("StringBuilder_init") orelse return error.Unemittable;
            const sb_append = compiler.func_map.get("StringBuilder_append") orelse return error.Unemittable;
            const sb_toString = compiler.func_map.get("StringBuilder_toString") orelse return error.Unemittable;
            const sb_delete = compiler.func_map.get("StringBuilder_delete") orelse return error.Unemittable;

            const sb_size = compiler.getTypeSize(ast.TypeRef{ .ident = "StringBuilder" }, false);
            const sb_val = try compiler.compileAlloc(core.LLVMConstInt(vt, sb_size, 0));

            const init_t = core.LLVMGlobalGetValueType(sb_init);
            var init_args = [_]types.LLVMValueRef{sb_val};
            _ = core.LLVMBuildCall2(compiler.builder, init_t, sb_init, &init_args, 1, "");

            const append_t = core.LLVMGlobalGetValueType(sb_append);
            for (x.parts) |p| {
                const pv = vals[@intFromEnum(p)] orelse return error.Unemittable;
                var append_args = [_]types.LLVMValueRef{ sb_val, pv };
                _ = core.LLVMBuildCall2(compiler.builder, append_t, sb_append, &append_args, 2, "");
            }

            const toString_t = core.LLVMGlobalGetValueType(sb_toString);
            var to_args = [_]types.LLVMValueRef{sb_val};
            const final_str = core.LLVMBuildCall2(compiler.builder, toString_t, sb_toString, &to_args, 1, "final_str");

            const delete_t = core.LLVMGlobalGetValueType(sb_delete);
            _ = core.LLVMBuildCall2(compiler.builder, delete_t, sb_delete, &to_args, 1, "");

            try compiler.compileRelease(sb_val, null);
            break :blk final_str;
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

    // FLOAT (f64/f32) path (B3): operands are the double's bit pattern in the i64 word. Bitcast to double, do
    // the FP op, then bitcast the arithmetic result back to the i64 word (compares zext an i1). Both operands
    // must be float; f32 is PROMOTED to double in this backend (its word already carries the double's 64-bit
    // pattern -- so DoubleType is the correct bitcast width for f32 too, NOT LLVMFloatType), so it takes the
    // identical path and mixed f32/f64 is byte-identical. Decimal and mixed int/float fall back. No
    // mod/shift/bitwise on float.
    if (isFloatWordTid(compiler, mf.typeOf(inst.op.binop.lhs))) {
        if (!isFloatWordTid(compiler, mf.typeOf(inst.op.binop.rhs))) return error.Unemittable;
        const dbl = core.LLVMDoubleType();
        const ld = core.LLVMBuildBitCast(bld, l, dbl, "");
        const rd = core.LLVMBuildBitCast(bld, r, dbl, "");
        switch (op) {
            .add => return core.LLVMBuildBitCast(bld, core.LLVMBuildFAdd(bld, ld, rd, ""), vt, ""),
            .sub => return core.LLVMBuildBitCast(bld, core.LLVMBuildFSub(bld, ld, rd, ""), vt, ""),
            .mul => return core.LLVMBuildBitCast(bld, core.LLVMBuildFMul(bld, ld, rd, ""), vt, ""),
            .div => return core.LLVMBuildBitCast(bld, core.LLVMBuildFDiv(bld, ld, rd, ""), vt, ""),
            .eq, .ne, .lt, .le, .gt, .ge => {
                const pred: types.LLVMRealPredicate = switch (op) {
                    .eq => .LLVMRealOEQ,
                    .ne => .LLVMRealONE,
                    .lt => .LLVMRealOLT,
                    .le => .LLVMRealOLE,
                    .gt => .LLVMRealOGT,
                    .ge => .LLVMRealOGE,
                    else => unreachable,
                };
                const cmp = core.LLVMBuildFCmp(bld, pred, ld, rd, "");
                return core.LLVMBuildZExt(bld, cmp, vt, "");
            },
            else => return error.Unemittable, // mod / shifts / bitwise are not valid on float
        }
    }

    // Reference-word eq/ne (string / ref-optional / heap pointer, incl. vs the null word): a bare word
    // compare. The operands are already the i64 pointer words; icmp eq/ne then zext to the bool word. This
    // mirrors how the AST compiles a nullable-pointer `== undefined` / `== null`.
    if ((op == .eq or op == .ne) and isRefWordEq(compiler, mf, inst.op.binop)) {
        const pred: types.LLVMIntPredicate = if (op == .eq) .LLVMIntEQ else .LLVMIntNE;
        const cmp = core.LLVMBuildICmp(bld, pred, l, r, "");
        return core.LLVMBuildZExt(bld, cmp, vt, "");
    }

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
