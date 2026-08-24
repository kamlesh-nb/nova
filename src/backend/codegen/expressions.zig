//! Expression lowering for the LLVM backend: the half of codegen that turns a
//! Nova `ast.Expression` into an `LLVMValueRef`.
//!
//! Every function here is a free function whose first parameter is
//! `self: *LlvmCompiler`; they are mixed into [`LlvmCompiler`] (defined in
//! `llvm_codegen.zig`) by `usingnamespace`, so `self.compileExpression(...)`
//! resolves to the code in this file. The split exists purely to keep the
//! backend readable: `statements.zig` lowers control flow, `declarations.zig`
//! lowers functions/structs, `arc.zig` owns retain/release, `types.zig` owns
//! the type/layout queries, and this file owns value-producing expressions.
//!
//! The single load-bearing entry point is [`compileExpression`], which wraps
//! the exhaustive dispatch [`compileExpressionInner`] (the ~2800-line
//! `switch (expr.kind)` that has one arm per AST node kind). The wrapper is
//! where ownership tracking lives: after computing a value it consults the
//! ownership pass and, for a value it now OWNS, spills the result to a stack
//! slot and records a [`LlvmCompiler.PendingTemp`] so [`drainTemporaries`] can
//! release it at the end of the enclosing statement. This is how ARC temporary
//! cleanup is threaded through expression evaluation without the caller having
//! to remember anything.
//!
//! Two representation decisions pervade this file and explain most of the
//! `IntToPtr`/`PtrToInt` churn:
//!
//!   - Every Nova value is carried in a single machine word, `self.val_type`
//!     (i64 native, i32 on wasm). Heap objects are addresses stored in that
//!     word; primitives are the value sign/zero-extended into it. Pointer
//!     arithmetic is therefore done on the integer and cast back to a pointer
//!     only at the load/store. Because the word is 64-bit but `int` is 32-bit,
//!     any address held in an `int` truncates: addresses must stay in the word.
//!
//!   - A `struct` is a VALUE type stored inline (raw bytes), whereas a `class`
//!     (and any escape-set struct) is a reference. The value-struct helpers at
//!     the top of the file ([`buildValueStructStorage`],
//!     [`buildValueStructCopy`], [`retainValueStructOwnedFields`],
//!     [`buildValueStructCopyInto`]) implement value semantics: a copy is a
//!     byte copy PLUS a deep retain of any owned/container fields the struct
//!     transitively holds, so ARC refcounts stay balanced across the copy.
//!     This mirrors the let-binding copy path and is the subtle correctness
//!     core of value structs.
//!
//! The file also carries several self-contained lowerings that could live
//! elsewhere but are expression-shaped: `async`/`await` (LLVM coroutine
//! suspend points, `spawn`, channel receive, `whenAny`), SIMD/crypto
//! intrinsics ([`compileSimdCall`], [`compileIntSimd`], [`compileClmul64`],
//! [`compileAesRound`]), unaligned/endian memory access ([`compileMemCall`]),
//! JSX/hypermedia string building ([`emitJsxInto`]), and the typed NovaDB
//! query row decoder ([`compileNovaQuery`], [`compileDecodeBinaryRow`]).
//!
//! When `NOVA_SEMA_SHADOW` reporting is on, the temporary-tracking helpers
//! ([`diffTempOp`], [`diffDtorName`]) additionally cross-check codegen's own
//! move/drop and destructor-name decisions against the typed IR's ownership
//! pass, accumulating agree/disagree counters in `sema_shadow`. That machinery
//! is diagnostic only and never changes emitted code.

/// The Zig standard library, used here for `std.mem` slice utilities,
/// formatting/allocation, and `ArrayListUnmanaged`.
const std = @import("std");
/// The Nova abstract syntax tree; every function here consumes
/// `ast.Expression`/`ast.TypeRef` and friends as its input.
const ast = @import("../../frontend/ast.zig");
/// The Zig binding to the LLVM-C API; `llvm.types` and `llvm.core` are the two
/// namespaces this file leans on for `LLVMValueRef`/`LLVMTypeRef` and the IR
/// builder functions respectively.
const llvm = @import("llvm");
/// LLVM opaque handle types (`LLVMValueRef`, `LLVMTypeRef`, `LLVMBasicBlockRef`,
/// the `LLVMIntPredicate` enum, ...).
const types = llvm.types;
/// The LLVM-C core builder API (`LLVMBuild*`, `LLVMConst*`, block/function
/// construction) used to emit every instruction in this file.
const core = llvm.core;

/// The backend compiler state these free functions extend; each function takes
/// `self: *LlvmCompiler`, and the type mixes this file's functions in via
/// `usingnamespace` so they appear as methods.
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
/// Shadow-verification globals and helpers. Provides `live_sema`,
/// `renderLegacy` (TypeId to legacy mangled name), and the agree/disagree
/// counters that [`diffTempOp`]/[`diffDtorName`] bump under `NOVA_SEMA_SHADOW`.
const sema_shadow = @import("../../frontend/sema/shadow.zig");
/// The ownership-inference pass; [`sema_infer.OwnOp`] is the move/drop decision
/// that codegen's temporary tracking is diffed against.
const sema_infer = @import("../../frontend/sema/infer.zig");
/// The typed-IR type system; [`sema_types.TypeId`] indexes into the type store
/// used throughout for concrete-type queries.
const sema_types = @import("../../frontend/types.zig");
/// Backend type/layout utilities: primitive classification (`cgPrim`),
/// mangling (`mangleTypeName`), value-optional detection (`valueOptionalName`),
/// and bit-width helpers.
const types_mod = @import("types.zig");
/// Strips generic arguments from a rendered type name (`List<int>` -> `List`),
/// used constantly to key into `self.structs`/`self.traits` by base name.
const getStructBaseName = @import("types.zig").getStructBaseName;
/// ARC helper predicate re-exported for local use: whether a name already
/// denotes an existing owner (so a fresh retain would be redundant).
const namesExistingOwner = @import("arc.zig").namesExistingOwner;
/// Re-export of the closure-id allocator on [`LlvmCompiler`], used when
/// synthesising unique names for lambda thunks and environments.
const getClosureUniqueId = LlvmCompiler.getClosureUniqueId;
/// Decodes source-level string escapes into their byte values for string
/// literals.
const unescapeString = @import("llvm_codegen.zig").unescapeString;
/// Metadata describing the function currently being compiled (name, params,
/// return type, body); a synthetic one is fabricated in [`emitJsxInto`] to
/// lower statements embedded inside JSX.
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
/// A lexical scope handle from the codegen driver (unused re-export kept for
/// symmetry with sibling codegen files).
const Scope = @import("llvm_codegen.zig").Scope;

/// Allocates a zero-initialised stack slot to hold a value struct's inline
/// bytes and returns its ADDRESS as an integer in `self.val_type`.
///
/// A value struct lives inline, so its storage is a byte array (`[size]i8`,
/// with a floor of 8 bytes for a zero-size struct so the address is always
/// distinct and non-null). The alloca is stored back as an integer address
/// because every Nova value travels in the machine word; callers do pointer
/// arithmetic on that integer. See [`buildValueStructCopy`] for the
/// storage-plus-copy variant.
pub fn buildValueStructStorage(self: *LlvmCompiler, size: u32) anyerror!types.LLVMValueRef {
    const n: c_uint = if (size == 0) 8 else @intCast(size);
    const arr_t = core.LLVMArrayType(self.i8_type, n);
    const a = core.LLVMBuildAlloca(self.builder, arr_t, "vstruct");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstNull(arr_t), a);
    return core.LLVMBuildPtrToInt(self.builder, a, self.val_type, "vstruct_addr");
}

/// Deep-retains every heap-owning field of a freshly byte-copied value struct
/// so ARC refcounts stay balanced across the copy.
///
/// After [`buildValueStructCopyInto`] duplicates the raw bytes, both the source
/// and destination point at the SAME owned/container payloads. This walks the
/// struct's fields and, for each container/owned/nested-value-struct field,
/// bumps the shared payload's refcount (or clones a container via its `copy`
/// method), so dropping either struct later is sound. This is the correctness
/// core of value-struct copies; forgetting it is a use-after-free. Entry point
/// that starts the recursion at depth 0; see
/// [`retainValueStructOwnedFieldsDepth`].
pub fn retainValueStructOwnedFields(self: *LlvmCompiler, structAddr: types.LLVMValueRef, struct_name: []const u8) anyerror!void {
    try retainValueStructOwnedFieldsDepth(self, structAddr, struct_name, 0);
}

/// Depth-bounded recursion behind [`retainValueStructOwnedFields`].
///
/// For each field at its computed offset: a `List`/`Map`/`Set` field is either
/// retained (when its element type mentions a type parameter, so the concrete
/// copy fn is unknown) or deep-cloned via its monomorphised `copy` function and
/// stored back; a declared owned field is retained; a nested VALUE struct is
/// recursed into in place. The `depth > 64` guard prevents runaway recursion on
/// pathological/self-referential type graphs. Fields that fail a lookup are
/// skipped rather than aborting the whole copy.
fn retainValueStructOwnedFieldsDepth(self: *LlvmCompiler, structAddr: types.LLVMValueRef, struct_name: []const u8, depth: u32) anyerror!void {
    if (depth > 64) return;
    const base = getStructBaseName(struct_name);
    const sd = self.structs.get(base) orelse return;
    for (sd.fields) |fld| {
        const fts = self.typeRefToString(fld.type_name) catch continue;
        const off = self.getFieldOffset(base, fld.name) catch continue;
        const addr = core.LLVMBuildAdd(self.builder, structAddr, core.LLVMConstInt(self.val_type, off, 0), "vs_ofld_addr");
        const fbase = getStructBaseName(fts);
        if (isContainerBaseName(fbase)) {
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "vs_cfld_ptr");
            const cur = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "vs_cfld");
            if (fieldTypeMentionsTypeParam(fts, sd.type_params)) {
                try self.compileRetain(cur);
            } else if (findContainerCopyFn(self, fts)) |copy_fn| {
                const ft = core.LLVMGlobalGetValueType(copy_fn);
                var args = [_]types.LLVMValueRef{cur};
                const fresh = core.LLVMBuildCall2(self.builder, ft, copy_fn, &args, 1, "vs_ccopy");
                _ = core.LLVMBuildStore(self.builder, fresh, ptr);
            } else {
                try self.compileRetain(cur);
            }
        } else if (self.isOwnedDeclaredType(fld.type_name, fts)) {
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "vs_ofld_ptr");
            const fv = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "vs_ofld");
            try self.compileRetain(fv);
        } else {
            if (fbase.len != 0 and self.isValueStructName(fbase)) {
                try retainValueStructOwnedFieldsDepth(self, addr, fts, depth + 1);
            }
        }
    }
}

/// Whether a struct base name is one of the built-in owning containers
/// (`List`/`Map`/`Set`), which need clone-on-copy rather than a plain retain.
fn isContainerBaseName(name: []const u8) bool {
    return std.mem.eql(u8, name, "List") or std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set");
}

/// Whether `c` can appear inside an identifier, used by
/// [`fieldTypeMentionsTypeParam`] to enforce whole-word matches.
fn vscIsIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Whether a rendered field-type string references any of the struct's type
/// parameters as a WHOLE identifier.
///
/// Used to decide whether a container field can be cloned via a known concrete
/// `copy` function or must fall back to a bare retain: if the element type is
/// still generic (mentions e.g. `T`), no monomorphised copy fn exists yet. The
/// whole-word check (via [`vscIsIdentChar`] on both sides of the match) avoids
/// matching `T` inside `Type`.
fn fieldTypeMentionsTypeParam(fts: []const u8, type_params: []const []const u8) bool {
    for (type_params) |tp| {
        if (tp.len == 0) continue;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, fts, i, tp)) |pos| {
            const before_ok = pos == 0 or !vscIsIdentChar(fts[pos - 1]);
            const after_idx = pos + tp.len;
            const after_ok = after_idx >= fts.len or !vscIsIdentChar(fts[after_idx]);
            if (before_ok and after_ok) return true;
            i = pos + 1;
        }
    }
    return false;
}

/// Looks up the monomorphised `copy` function for a concrete container field
/// type (e.g. `List<int>`), returning the LLVM function or null if absent.
///
/// Resolves the mangled `<Type>_copy` symbol via [`LlvmCompiler.methodSymbol`]
/// and asks the module for it by name. A null result means the concrete
/// instantiation was not emitted, in which case the caller retains instead of
/// cloning.
fn findContainerCopyFn(self: *LlvmCompiler, field_type: []const u8) ?types.LLVMValueRef {
    const sym = self.methodSymbol(field_type, "copy") catch return null;
    defer self.allocator.free(sym);
    const symz = self.allocator.dupeZ(u8, sym) catch return null;
    defer self.allocator.free(symz);
    return core.LLVMGetNamedFunction(self.module, symz);
}

/// Byte-copies `size` bytes of a value struct from `src` to a caller-provided
/// destination `dst` via the runtime `nova_bytes_copy`, returning `dst`.
///
/// This copies the raw inline bytes ONLY; it does not adjust refcounts, so
/// callers that want value semantics must follow it with
/// [`retainValueStructOwnedFields`]. A zero-size struct is treated as 8 bytes
/// to match [`buildValueStructStorage`]. The `nova_bytes_copy` declaration is
/// lazily created and cached in `func_map` on first use. Compare
/// [`buildValueStructCopy`], which also allocates the destination.
pub fn buildValueStructCopyInto(self: *LlvmCompiler, dst: types.LLVMValueRef, src: types.LLVMValueRef, size: u32) anyerror!types.LLVMValueRef {
    const copy_fn = if (self.func_map.get("nova_bytes_copy")) |f| f else blk: {
        var at = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type };
        const ft = core.LLVMFunctionType(core.LLVMVoidType(), &at, 3, 0);
        const f = core.LLVMAddFunction(self.module, "nova_bytes_copy", ft);
        try self.func_map.put("nova_bytes_copy", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(copy_fn);
    const n: u64 = if (size == 0) 8 else size;
    var args = [_]types.LLVMValueRef{ dst, src, core.LLVMConstInt(self.val_type, n, 0) };
    _ = core.LLVMBuildCall2(self.builder, fn_t, copy_fn, &args, 3, "");
    return dst;
}

/// If `tid` is `Optional<S>` where `S` is a value struct, returns `S`'s base
/// name; otherwise null.
///
/// Used to detect the case where an optional wraps an inline struct, which
/// needs the branchy deep copy of [`buildOptionalStructDeepCopy`] rather than a
/// plain word copy. A reference struct (`is_reference`) returns null because it
/// is copied by pointer.
pub fn optionalInnerValueStructName(self: *LlvmCompiler, tid: sema_types.TypeId) ?[]const u8 {
    const st = self.type_store orelse return null;
    if (st.get(tid) != .optional) return null;
    const inner = st.get(tid).optional;
    if (st.get(inner) != .struct_) return null;
    const nm = sema_shadow.renderLegacy(self.allocator, st, inner) catch return null;
    const base = getStructBaseName(nm);
    const sd = self.structs.get(base) orelse return null;
    if (sd.is_reference) return null;
    return base;
}

/// Deep-copies an optional-of-value-struct, guarding on presence, and returns
/// the copied handle (or the original null word when absent).
///
/// When an optional carries an inline struct, "present" is represented by a
/// heap pointer and "absent" by a null word. This emits a diamond: on the
/// present branch it allocates fresh storage, byte-copies the struct, and deep
/// retains owned fields (via [`buildHeapStructDeepCopy`]'s steps); on the absent
/// branch it passes the null through; a phi merges them. Needed so copying an
/// optional value struct does not alias the original's owned payloads.
pub fn buildOptionalStructDeepCopy(self: *LlvmCompiler, src: types.LLVMValueRef, base: []const u8) anyerror!types.LLVMValueRef {
    const size = self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(base) }, false);
    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const copy_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_dc_copy");
    const null_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_dc_null");
    const merge_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_dc_merge");
    const present = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, src, core.LLVMConstInt(self.val_type, 0, 0), "opt_dc_present");
    _ = core.LLVMBuildCondBr(self.builder, present, copy_bb, null_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, copy_bb);
    const new_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, if (size == 0) 8 else size, 0));
    _ = try self.buildValueStructCopyInto(new_ptr, src, size);
    try self.retainValueStructOwnedFields(new_ptr, base);
    const copy_end = core.LLVMGetInsertBlock(self.builder);
    _ = core.LLVMBuildBr(self.builder, merge_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, null_bb);
    _ = core.LLVMBuildBr(self.builder, merge_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
    const phi = core.LLVMBuildPhi(self.builder, self.val_type, "opt_dc");
    var vals = [_]types.LLVMValueRef{ new_ptr, src };
    var blocks = [_]types.LLVMBasicBlockRef{ copy_end, null_bb };
    core.LLVMAddIncoming(phi, &vals, &blocks, 2);
    return phi;
}

/// Allocates a fresh heap copy of a value struct and deep-retains its owned
/// fields, returning the new address.
///
/// The unconditional (non-optional) counterpart to
/// [`buildOptionalStructDeepCopy`]: `compileAlloc` + [`buildValueStructCopyInto`]
/// + [`retainValueStructOwnedFields`]. Used when a value struct needs an
/// independent heap-resident copy whose lifetime is managed by ARC.
pub fn buildHeapStructDeepCopy(self: *LlvmCompiler, src: types.LLVMValueRef, base: []const u8) anyerror!types.LLVMValueRef {
    const size = self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(base) }, false);
    const new_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, if (size == 0) 8 else size, 0));
    _ = try self.buildValueStructCopyInto(new_ptr, src, size);
    try self.retainValueStructOwnedFields(new_ptr, base);
    return new_ptr;
}

/// Copies a value struct into a NEW stack slot and returns its address.
///
/// Combines [`buildValueStructStorage`] with a `nova_bytes_copy`. Unlike
/// [`buildHeapStructDeepCopy`] this allocates on the stack and does NOT retain
/// owned fields, so it is for short-lived by-value struct values whose owned
/// payloads are handled by the caller's ownership bookkeeping.
pub fn buildValueStructCopy(self: *LlvmCompiler, src: types.LLVMValueRef, size: u32) anyerror!types.LLVMValueRef {
    const dst = try self.buildValueStructStorage(size);
    const copy_fn = if (self.func_map.get("nova_bytes_copy")) |f| f else blk: {
        var at = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type };
        const ft = core.LLVMFunctionType(core.LLVMVoidType(), &at, 3, 0);
        const f = core.LLVMAddFunction(self.module, "nova_bytes_copy", ft);
        try self.func_map.put("nova_bytes_copy", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(copy_fn);
    const n: u64 = if (size == 0) 8 else size;
    var args = [_]types.LLVMValueRef{ dst, src, core.LLVMConstInt(self.val_type, n, 0) };
    _ = core.LLVMBuildCall2(self.builder, fn_t, copy_fn, &args, 3, "");
    return dst;
}

/// Lowers a call to one of the compiler's element-"witness" intrinsics, the
/// low-level primitives the collection library uses to store/load/copy/drop an
/// element of an arbitrary `T` in a raw buffer.
///
/// `wn` is the witness name and `gc.type_args[0]` is the element type `T`. The
/// witness set (`sizeOf`, `copyElem`, `store`/`storeOver`, `load`/`moveOut`,
/// `moveElem`, `dropElem`) abstracts over the two element representations:
/// a VALUE struct occupies `sizeOf(T)` inline bytes and is copied with
/// [`buildValueStructCopyInto`] plus a field retain, while everything else
/// occupies one word and is loaded/stored directly with a retain when the
/// element type is owned. `storeOver`/`load` (vs `moveElem`/`moveOut`) is the
/// retain-adjusting vs move-without-retain distinction. Returns null (not
/// matched) if `wn` is unknown or the argument count is wrong; a matched
/// void-like witness returns the zero word.
pub fn compileElemWitness(self: *LlvmCompiler, wn: []const u8, gc: ast.GenericCallExpr) anyerror!?types.LLVMValueRef {
    const t = self.typeRefToString(gc.type_args[0]) catch return null;
    const is_vs = self.isValueStructName(t);
    const elem_owned = self.ownedByName(t);
    const width_u: u64 = if (is_vs) @max(self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(t) }, false), 1) else 8;
    const valptr_t = core.LLVMPointerType(self.val_type, 0);

    if (std.mem.eql(u8, wn, "sizeOf")) {
        if (gc.args.len != 0) return null;
        return core.LLVMConstInt(self.val_type, width_u, 0);
    }
    if (std.mem.eql(u8, wn, "copyElem")) {
        if (gc.args.len != 2) return null;
        const dst = try self.compileExpression(gc.args[0]);
        const src = try self.compileExpression(gc.args[1]);
        if (is_vs) {
            _ = try self.buildValueStructCopyInto(dst, src, @intCast(width_u));
            try self.retainValueStructOwnedFields(dst, t);
        } else {
            const sptr = core.LLVMBuildIntToPtr(self.builder, src, valptr_t, "we_sptr");
            const v = core.LLVMBuildLoad2(self.builder, self.val_type, sptr, "we_v");
            const dptr = core.LLVMBuildIntToPtr(self.builder, dst, valptr_t, "we_dptr");
            _ = core.LLVMBuildStore(self.builder, v, dptr);
            if (elem_owned) try self.compileRetain(v);
        }
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, wn, "dropElem")) {
        if (gc.args.len != 1) return null;
        const addr = try self.compileExpression(gc.args[0]);
        try dropElemAt(self, t, is_vs, addr);
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, wn, "store") or std.mem.eql(u8, wn, "storeOver")) {
        if (gc.args.len != 2) return null;
        const over = std.mem.eql(u8, wn, "storeOver");
        const slot = try self.compileExpression(gc.args[0]);
        const value = try self.compileExpression(gc.args[1]);
        if (is_vs) {
            if (over) try dropElemAt(self, t, true, slot);
            _ = try self.buildValueStructCopyInto(slot, value, @intCast(width_u));
            try self.retainValueStructOwnedFields(slot, t);
        } else {
            if (elem_owned) try self.compileRetain(value);
            if (over) try dropElemAt(self, t, false, slot);
            const p = core.LLVMBuildIntToPtr(self.builder, slot, valptr_t, "we_sp");
            _ = core.LLVMBuildStore(self.builder, value, p);
        }
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, wn, "load") or std.mem.eql(u8, wn, "moveOut")) {
        if (gc.args.len != 1) return null;
        const slot = try self.compileExpression(gc.args[0]);
        if (is_vs) return slot;
        const p = core.LLVMBuildIntToPtr(self.builder, slot, valptr_t, "we_lp");
        const v = core.LLVMBuildLoad2(self.builder, self.val_type, p, "we_lv");
        if (std.mem.eql(u8, wn, "load") and elem_owned) try self.compileRetain(v);
        return v;
    }
    if (std.mem.eql(u8, wn, "moveElem")) {
        if (gc.args.len != 2) return null;
        const dst = try self.compileExpression(gc.args[0]);
        const src = try self.compileExpression(gc.args[1]);
        if (is_vs) {
            _ = try self.buildValueStructCopyInto(dst, src, @intCast(width_u));
        } else {
            const sp = core.LLVMBuildIntToPtr(self.builder, src, valptr_t, "we_msp");
            const v = core.LLVMBuildLoad2(self.builder, self.val_type, sp, "we_mv");
            const dp = core.LLVMBuildIntToPtr(self.builder, dst, valptr_t, "we_mdp");
            _ = core.LLVMBuildStore(self.builder, v, dp);
        }
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    return null;
}

/// Destroys the element of type `t` living at `addr`, shared by the
/// `dropElem`/`storeOver` witnesses in [`compileElemWitness`].
///
/// For a value struct (`is_vs`) with owned fields it calls the struct's
/// in-place destructor over the inline bytes; for a plain-value struct with no
/// owned fields it does nothing. For a one-word owned/value-optional element it
/// loads the word and releases it. A non-owning scalar element is a no-op.
fn dropElemAt(self: *LlvmCompiler, t: []const u8, is_vs: bool, addr: types.LLVMValueRef) anyerror!void {
    const valptr_t = core.LLVMPointerType(self.val_type, 0);
    if (is_vs) {
        if (self.valueStructHasOwnedFields(t)) {
            if (try self.getOrCreateDestructor(t)) |d| {
                const dt = core.LLVMGlobalGetValueType(d);
                var args = [_]types.LLVMValueRef{addr};
                _ = core.LLVMBuildCall2(self.builder, dt, d, &args, 1, "");
            }
        }
    } else if (self.ownedByName(t) or types_mod.valueOptionalName(t)) {
        const p = core.LLVMBuildIntToPtr(self.builder, addr, valptr_t, "we_dp");
        const v = core.LLVMBuildLoad2(self.builder, self.val_type, p, "we_dv");
        const d = try self.getOrCreateDestructor(t);
        try self.compileRelease(v, d);
    }
}

/// Widens a concrete struct value to a trait fat pointer in place when a
/// branch's static type must unify to a trait type, returning whether it did.
///
/// Given a branch expression that produced a concrete struct `val` and the
/// trait the surrounding expression expects (`trait_name`), this constructs the
/// `{struct_ptr, vtable}` trait object, updates `val.*` to it, and releases the
/// original struct temporary (transferring ownership into the trait object).
/// Returns false (leaving `val` untouched) when there is no trait target or the
/// branch is not a known struct. Used to make the two arms of an `if`/`match`
/// expression agree on a trait result type.
pub fn widenBranchToTrait(self: *LlvmCompiler, branch: *const ast.Expression, val: *types.LLVMValueRef, trait_name: ?[]const u8) anyerror!bool {
    const tn = trait_name orelse return false;
    const st = (try self.resolveExpressionTypeName(branch)) orelse return false;
    if (!self.structs.contains(st)) return false;
    const orig = val.*;
    self.consumeTemporary(orig);
    val.* = try self.constructTraitObject(orig, st, tn);
    self.consumeTemporary(val.*);

    const tid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(branch) else null;
    const sdtor = try self.getOrCreateDestructorPreferId(st, tid);
    try self.compileRelease(orig, sdtor);
    return true;
}

/// Whether `name` refers to an in-scope runtime variable rather than a
/// function/type/global.
///
/// Checks, in order: captured closure-environment slots, locals, and captured
/// globals walking up the lambda-parent chain (so a name captured by an
/// enclosing lambda still counts). Used to disambiguate an identifier that
/// could otherwise be read as a bare function reference.
pub fn identNamesVariable(self: *LlvmCompiler, name: []const u8) bool {
    if (self.envCaptureIndex(name) != null) return true;
    if (self.locals.contains(name)) return true;

    var curr_fn = self.current_function_name;
    while (curr_fn) |fn_name| {
        const key = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name }) catch return false;
        defer self.allocator.free(key);
        if (self.captured_globals.contains(key)) return true;
        curr_fn = self.lambda_parents.get(fn_name);
    }
    return false;
}

/// Boxes a plain top-level function into a closure value so it can be passed
/// where a closure/`fn` value is expected, returning the boxed handle.
///
/// A closure is called through a uniform `(env, args...)` ABI, but a bare
/// function has no environment. This synthesises (once per function, cached in
/// `fn_box_globals`) an internal thunk that ignores the env slot and forwards
/// the remaining arguments to the real function, then emits a constant global
/// box `{header, thunk_ptr, empty_env}` and returns the payload address via
/// [`fnBoxReturn`]. The wasm and native layouts differ (wasm needs an explicit
/// ptr field); both encode the same shape. Idempotent: a second call returns
/// the cached box.
pub fn buildBareFnBox(self: *LlvmCompiler, fn_val: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const fn_name = std.mem.span(core.LLVMGetValueName(fn_val));
    if (self.fn_box_globals.get(fn_name)) |box_g| {

        return self.fnBoxReturn(box_g, fn_name);
    }

    const target_ft = core.LLVMGlobalGetValueType(fn_val);
    const arity = core.LLVMCountParamTypes(target_ft);

    const nparams: usize = @intCast(arity + 1);
    const params = try self.allocator.alloc(types.LLVMTypeRef, nparams);
    defer self.allocator.free(params);
    @memset(params, self.val_type);
    const thunk_ft = core.LLVMFunctionType(self.val_type, params.ptr, @intCast(nparams), 0);

    const thunk_name = try std.fmt.allocPrintSentinel(self.allocator, "__fnbox_thunk_{s}", .{fn_name}, 0);
    defer self.allocator.free(thunk_name);
    const thunk = core.LLVMAddFunction(self.module, thunk_name, thunk_ft);
    core.LLVMSetLinkage(thunk, .LLVMInternalLinkage);

    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    const entry_bb = core.LLVMAppendBasicBlock(thunk, "entry");
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const fwd = try self.allocator.alloc(types.LLVMValueRef, @intCast(arity));
    defer self.allocator.free(fwd);
    for (fwd, 0..) |*slot, i| {
        slot.* = core.LLVMGetParam(thunk, @intCast(i + 1));
    }

    const ret = try self.buildCallWithCasts(fn_val, fwd);
    _ = core.LLVMBuildRet(self.builder, ret);

    if (saved_ip) |sip| {
        core.LLVMPositionBuilderAtEnd(self.builder, sip);
    }

    const i32_t = self.i32_type;
    const box_name = try std.fmt.allocPrintSentinel(self.allocator, "__fnbox_{s}", .{fn_name}, 0);
    defer self.allocator.free(box_name);
    const box_g = blk: {
        if (self.is_wasm) {
            var box_fields = [_]types.LLVMTypeRef{ i32_t, i32_t, self.ptr_type, i32_t, self.val_type };
            const box_t = core.LLVMStructType(&box_fields, 5, 1);
            const g = core.LLVMAddGlobal(self.module, box_t, box_name);
            var box_init = [_]types.LLVMValueRef{
                core.LLVMConstInt(i32_t, 100000000, 0),
                core.LLVMConstInt(i32_t, 16, 0),
                thunk,
                core.LLVMConstInt(i32_t, 0, 0),
                core.LLVMConstInt(self.val_type, 0, 0),
            };
            core.LLVMSetInitializer(g, core.LLVMConstStruct(&box_init, 5, 1));
            break :blk g;
        }
        const payload_t = core.LLVMArrayType(self.val_type, 2);
        var box_fields = [_]types.LLVMTypeRef{ i32_t, i32_t, payload_t };
        const box_t = core.LLVMStructType(&box_fields, 3, 1);
        const g = core.LLVMAddGlobal(self.module, box_t, box_name);
        var slots = [_]types.LLVMValueRef{
            core.LLVMConstPtrToInt(thunk, self.val_type),
            core.LLVMConstInt(self.val_type, 0, 0),
        };
        var box_init = [_]types.LLVMValueRef{
            core.LLVMConstInt(i32_t, 100000000, 0),
            core.LLVMConstInt(i32_t, 16, 0),
            core.LLVMConstArray(self.val_type, &slots, 2),
        };
        core.LLVMSetInitializer(g, core.LLVMConstStruct(&box_init, 3, 1));
        break :blk g;
    };
    core.LLVMSetGlobalConstant(box_g, 0);
    core.LLVMSetLinkage(box_g, .LLVMInternalLinkage);

    try self.fn_box_globals.put(fn_name, box_g);
    return self.fnBoxReturn(box_g, fn_name);
}

/// Returns the closure-payload address of a function box: the box global's
/// address advanced past its 8-byte ARC header.
///
/// Callers treat the value like any other closure handle. `fn_name` is
/// currently unused (discarded) but kept in the signature for call-site
/// symmetry with [`buildBareFnBox`].
pub fn fnBoxReturn(self: *LlvmCompiler, box_g: types.LLVMValueRef, fn_name: []const u8) anyerror!types.LLVMValueRef {
    const base = core.LLVMBuildPtrToInt(self.builder, box_g, self.val_type, "fnbox_base");
    const ptr = core.LLVMBuildAdd(self.builder, base, core.LLVMConstInt(self.val_type, 8, 0), "fnbox_ptr");
    _ = fn_name;
    return ptr;
}

/// Materialises a function pointer as an integer word usable in a Nova value.
///
/// On native targets a function address fits directly, so this is a plain
/// `ptrtoint`. On wasm, function pointers are table indices that are not known
/// as integers at compile time, so it emits (once per function, cached as a
/// `__fnref_<name>` global) a relocatable `{fn_ptr, 0}` struct and loads the
/// first word at runtime. Used wherever a function must be stored in the
/// uniform value word (e.g. closure cleanup thunks).
pub fn fnRefInt(self: *LlvmCompiler, fn_val: types.LLVMValueRef, name: []const u8) anyerror!types.LLVMValueRef {
    if (!self.is_wasm) return core.LLVMBuildPtrToInt(self.builder, fn_val, self.val_type, "fn_ref_int");
    const gname = try std.fmt.allocPrintSentinel(self.allocator, "__fnref_{s}", .{name}, 0);
    defer self.allocator.free(gname);
    const g = core.LLVMGetNamedGlobal(self.module, gname.ptr) orelse blk: {
        var fields = [_]types.LLVMTypeRef{ self.ptr_type, self.i32_type };
        const gty = core.LLVMStructType(&fields, 2, 1);
        const ng = core.LLVMAddGlobal(self.module, gty, gname.ptr);
        var init = [_]types.LLVMValueRef{ fn_val, core.LLVMConstInt(self.i32_type, 0, 0) };
        core.LLVMSetInitializer(ng, core.LLVMConstStruct(&init, 2, 1));
        core.LLVMSetGlobalConstant(ng, 1);
        core.LLVMSetLinkage(ng, .LLVMInternalLinkage);
        break :blk ng;
    };
    return core.LLVMBuildLoad2(self.builder, self.val_type, g, "fnref_raw");
}

/// If `obj` is a float array, returns the LLVM element type (`double`/`float`);
/// otherwise null.
///
/// Consulted when indexing an array so a float element is loaded/stored with
/// the right type rather than through the generic word path (floats and ints
/// share the value word but need distinct load types).
pub fn arrayElemFloatLLVM(self: *LlvmCompiler, obj: *const ast.Expression) ?types.LLVMTypeRef {
    const ir = self.typed_ir orelse return null;
    const st = self.type_store orelse return null;
    const tid = ir.typeOf(obj) orelse return null;
    const t = st.get(tid);
    if (t != .array) return null;
    const et = st.get(t.array.elem);
    if (et == .prim and et.prim.kind == .float) {
        if (et.prim.bits == 64) return core.LLVMDoubleType();
        if (et.prim.bits == 32) return core.LLVMFloatType();
    }
    return null;
}

/// Normalises an array base value to a pointer: returns it unchanged if already
/// a pointer, otherwise casts the integer address to `ptr_type`.
///
/// Array bases can arrive either as a raw pointer or as the usual integer
/// address word; this lets indexing code build a GEP without caring which.
pub fn arrayBasePtr(self: *LlvmCompiler, base: types.LLVMValueRef) types.LLVMValueRef {
    if (core.LLVMGetTypeKind(core.LLVMTypeOf(base)) == .LLVMPointerTypeKind) return base;
    return core.LLVMBuildIntToPtr(self.builder, base, self.ptr_type, "arr_base");
}

/// Lowers a call to a `simd.*` intrinsic to native vector IR.
///
/// Dispatches by `field`: a `mulhi64` high-64-of-128 multiply; integer-lane
/// families (`*U8x16`/`*U32x4`/`*U64x2`) forwarded to [`compileIntSimd`]; and
/// the f64x4 family (`splat4`, `make4`, `load4`/`store4`, `sum4`, and the
/// arithmetic ops `add4`/`sub4`/`mul4`/`div4`/`fma4`) built directly on a
/// 4-wide double vector. Unaligned memory is handled where relevant. Returns
/// `error.UnknownSimdOp` for an unrecognised `field`. Element pointers are
/// computed with small inline helper structs so the vector load/store shares
/// one GEP shape.
pub fn compileSimdCall(self: *LlvmCompiler, field: []const u8, args: []const ast.Expression) anyerror!types.LLVMValueRef {
    if (std.mem.eql(u8, field, "mulhi64")) {
        const i128t = core.LLVMIntType(128);
        const a64 = core.LLVMBuildTrunc(self.builder, try self.compileExpression(args[0]), core.LLVMInt64Type(), "mh_a");
        const b64 = core.LLVMBuildTrunc(self.builder, try self.compileExpression(args[1]), core.LLVMInt64Type(), "mh_b");
        const az = core.LLVMBuildZExt(self.builder, a64, i128t, "mh_az");
        const bz = core.LLVMBuildZExt(self.builder, b64, i128t, "mh_bz");
        const prod = core.LLVMBuildMul(self.builder, az, bz, "mh_mul");
        const sh = core.LLVMBuildLShr(self.builder, prod, core.LLVMConstInt(i128t, 64, 0), "mh_hi");
        return core.LLVMBuildTrunc(self.builder, sh, self.val_type, "mh_hitr");
    }

    if (std.mem.endsWith(u8, field, "U8x16")) return try self.compileIntSimd(field, args, 8, 16);
    if (std.mem.endsWith(u8, field, "U32x4")) return try self.compileIntSimd(field, args, 32, 4);
    if (std.mem.endsWith(u8, field, "U64x2")) return try self.compileIntSimd(field, args, 64, 2);

    const vecTy = self.vecF64x4Type();
    const dbl = core.LLVMDoubleType();

    const elemPtr = struct {
        fn get(c: *LlvmCompiler, arr_word: types.LLVMValueRef, idx: types.LLVMValueRef) types.LLVMValueRef {
            const base = core.LLVMBuildIntToPtr(c.builder, arr_word, c.ptr_type, "simd_base");
            var ix = [_]types.LLVMValueRef{idx};
            return core.LLVMBuildInBoundsGEP2(c.builder, core.LLVMDoubleType(), base, &ix, 1, "simd_gep");
        }
    }.get;

    if (std.mem.eql(u8, field, "splat4")) {
        const x = try self.compileExpression(args[0]);
        var undef = core.LLVMGetUndef(vecTy);
        undef = core.LLVMBuildInsertElement(self.builder, undef, x, core.LLVMConstInt(self.i32_type, 0, 0), "splat0");
        var mask = [_]types.LLVMValueRef{ core.LLVMConstInt(self.i32_type, 0, 0), core.LLVMConstInt(self.i32_type, 0, 0), core.LLVMConstInt(self.i32_type, 0, 0), core.LLVMConstInt(self.i32_type, 0, 0) };
        const maskv = core.LLVMConstVector(&mask, 4);
        return core.LLVMBuildShuffleVector(self.builder, undef, core.LLVMGetUndef(vecTy), maskv, "splat4");
    }
    if (std.mem.eql(u8, field, "make4")) {
        var v = core.LLVMGetUndef(vecTy);
        var lane: c_uint = 0;
        while (lane < 4) : (lane += 1) {
            const e = try self.compileExpression(args[lane]);
            v = core.LLVMBuildInsertElement(self.builder, v, e, core.LLVMConstInt(self.i32_type, lane, 0), "make4");
        }
        return v;
    }
    if (std.mem.eql(u8, field, "load4")) {
        const arr = try self.compileExpression(args[0]);
        const idx = try self.compileExpression(args[1]);
        const p = elemPtr(self, arr, idx);
        return core.LLVMBuildLoad2(self.builder, vecTy, p, "load4");
    }
    if (std.mem.eql(u8, field, "store4")) {
        const arr = try self.compileExpression(args[0]);
        const idx = try self.compileExpression(args[1]);
        const v = try self.compileExpression(args[2]);
        const p = elemPtr(self, arr, idx);
        _ = core.LLVMBuildStore(self.builder, v, p);
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, field, "sum4")) {
        const v = try self.compileExpression(args[0]);
        var acc = core.LLVMBuildExtractElement(self.builder, v, core.LLVMConstInt(self.i32_type, 0, 0), "l0");
        var lane: c_uint = 1;
        while (lane < 4) : (lane += 1) {
            const e = core.LLVMBuildExtractElement(self.builder, v, core.LLVMConstInt(self.i32_type, lane, 0), "ln");
            acc = core.LLVMBuildFAdd(self.builder, acc, e, "sumacc");
        }
        return acc;
    }
    const a = try self.compileExpression(args[0]);
    const b = try self.compileExpression(args[1]);
    if (std.mem.eql(u8, field, "add4")) return core.LLVMBuildFAdd(self.builder, a, b, "add4");
    if (std.mem.eql(u8, field, "sub4")) return core.LLVMBuildFSub(self.builder, a, b, "sub4");
    if (std.mem.eql(u8, field, "mul4")) return core.LLVMBuildFMul(self.builder, a, b, "mul4");
    if (std.mem.eql(u8, field, "div4")) return core.LLVMBuildFDiv(self.builder, a, b, "div4");
    if (std.mem.eql(u8, field, "fma4")) {
        const c = try self.compileExpression(args[2]);
        const m = core.LLVMBuildFMul(self.builder, a, b, "fma_mul");
        return core.LLVMBuildFAdd(self.builder, m, c, "fma_add");
    }
    _ = dbl;
    std.debug.print("unknown simd op: {s}\n", .{field});
    return error.UnknownSimdOp;
}

/// Lowers an integer SIMD intrinsic for an `elem`-bit x `lanes`-wide vector.
///
/// The operation name is `field` with its width suffix (`U8x16`/`U32x4`/...)
/// stripped. Handles lane construction (`splat`), unaligned `load`/`store`,
/// `movemask` (pack sign bits), lane shifts (`shl`/`shr`), `cast`/`lane`
/// extract, carry-less multiply (`clmul` via [`compileClmul64`]), AES rounds
/// (`aesenc`/`aesenclast` via [`compileAesRound`]), and the elementwise
/// arithmetic/bitwise/compare ops. Returns `error.UnknownSimdOp` for an
/// unrecognised op. The inline `splat`/`vecPtr` helpers keep the broadcast and
/// address computation uniform across ops.
pub fn compileIntSimd(self: *LlvmCompiler, field: []const u8, args: []const ast.Expression, elem: c_uint, lanes: c_uint) anyerror!types.LLVMValueRef {
    const et = core.LLVMIntType(elem);
    const vt = core.LLVMVectorType(et, lanes);
    const suffix_len: usize = if (elem == 8) "U8x16".len else "U32x4".len;
    const op = field[0 .. field.len - suffix_len];

    const splat = struct {
        fn make(c: *LlvmCompiler, scalar: types.LLVMValueRef, e_ty: types.LLVMTypeRef, v_ty: types.LLVMTypeRef, n: c_uint) types.LLVMValueRef {
            const sc = core.LLVMBuildTrunc(c.builder, scalar, e_ty, "simd_splat_tr");
            var undef = core.LLVMGetUndef(v_ty);
            undef = core.LLVMBuildInsertElement(c.builder, undef, sc, core.LLVMConstInt(c.i32_type, 0, 0), "simd_splat0");
            var masks: [16]types.LLVMValueRef = undefined;
            var i: c_uint = 0;
            while (i < n) : (i += 1) masks[i] = core.LLVMConstInt(c.i32_type, 0, 0);
            const maskv = core.LLVMConstVector(&masks, n);
            return core.LLVMBuildShuffleVector(c.builder, undef, core.LLVMGetUndef(v_ty), maskv, "simd_splat");
        }
    }.make;

    const vecPtr = struct {
        fn get(c: *LlvmCompiler, buf: types.LLVMValueRef, off: types.LLVMValueRef, v_ty: types.LLVMTypeRef) types.LLVMValueRef {
            const addr = core.LLVMBuildAdd(c.builder, buf, off, "simd_vaddr");
            return core.LLVMBuildIntToPtr(c.builder, addr, core.LLVMPointerType(v_ty, 0), "simd_vptr");
        }
    }.get;

    if (std.mem.eql(u8, op, "splat")) {
        const s = try self.compileExpression(args[0]);
        return splat(self, s, et, vt, lanes);
    }
    if (std.mem.eql(u8, op, "load")) {
        const buf = try self.compileExpression(args[0]);
        const off = try self.compileExpression(args[1]);
        const p = vecPtr(self, buf, off, vt);
        const ld = core.LLVMBuildLoad2(self.builder, vt, p, "simd_load");
        core.LLVMSetAlignment(ld, 1);
        return ld;
    }
    if (std.mem.eql(u8, op, "store")) {
        const buf = try self.compileExpression(args[0]);
        const off = try self.compileExpression(args[1]);
        const v = try self.compileExpression(args[2]);
        const p = vecPtr(self, buf, off, vt);
        const st = core.LLVMBuildStore(self.builder, v, p);
        core.LLVMSetAlignment(st, 1);
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, op, "movemask")) {
        const v = try self.compileExpression(args[0]);
        const zero = core.LLVMConstNull(vt);
        const signs = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, v, zero, "simd_signs");
        const packed_ty = core.LLVMIntType(lanes);
        const bits = core.LLVMBuildBitCast(self.builder, signs, packed_ty, "simd_mask");
        return core.LLVMBuildZExt(self.builder, bits, self.val_type, "simd_mask_ext");
    }
    if (std.mem.eql(u8, op, "shl") or std.mem.eql(u8, op, "shr")) {
        const v = try self.compileExpression(args[0]);
        const n = try self.compileExpression(args[1]);
        const amt = splat(self, n, et, vt, lanes);
        if (std.mem.eql(u8, op, "shl")) return core.LLVMBuildShl(self.builder, v, amt, "simd_shl");
        return core.LLVMBuildLShr(self.builder, v, amt, "simd_shr");
    }
    if (std.mem.eql(u8, op, "cast")) {
        const v = try self.compileExpression(args[0]);
        return core.LLVMBuildBitCast(self.builder, v, vt, "simd_cast");
    }
    if (std.mem.eql(u8, op, "lane")) {
        const v = try self.compileExpression(args[0]);
        const idxv = try self.compileExpression(args[1]);
        const idx32 = core.LLVMBuildTrunc(self.builder, idxv, self.i32_type, "lane_idx");
        const el = core.LLVMBuildExtractElement(self.builder, v, idx32, "lane_ex");
        if (elem >= 64) return el;
        return core.LLVMBuildZExt(self.builder, el, self.val_type, "lane_ext");
    }
    if (std.mem.eql(u8, op, "clmul")) {
        const a64 = core.LLVMBuildTrunc(self.builder, try self.compileExpression(args[0]), core.LLVMInt64Type(), "clmul_a");
        const b64 = core.LLVMBuildTrunc(self.builder, try self.compileExpression(args[1]), core.LLVMInt64Type(), "clmul_b");
        return try self.compileClmul64(a64, b64, vt);
    }
    if (std.mem.eql(u8, op, "aesenc") or std.mem.eql(u8, op, "aesenclast")) {
        const state = try self.compileExpression(args[0]);
        const rk = try self.compileExpression(args[1]);
        return try self.compileAesRound(state, rk, vt, std.mem.eql(u8, op, "aesenclast"));
    }

    const a = try self.compileExpression(args[0]);
    const b = try self.compileExpression(args[1]);
    if (std.mem.eql(u8, op, "add")) return core.LLVMBuildAdd(self.builder, a, b, "simd_add");
    if (std.mem.eql(u8, op, "sub")) return core.LLVMBuildSub(self.builder, a, b, "simd_sub");
    if (std.mem.eql(u8, op, "and")) return core.LLVMBuildAnd(self.builder, a, b, "simd_and");
    if (std.mem.eql(u8, op, "or")) return core.LLVMBuildOr(self.builder, a, b, "simd_or");
    if (std.mem.eql(u8, op, "xor")) return core.LLVMBuildXor(self.builder, a, b, "simd_xor");
    if (std.mem.eql(u8, op, "eq")) {
        const c = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, a, b, "simd_eqcmp");
        return core.LLVMBuildSExt(self.builder, c, vt, "simd_eq");
    }
    std.debug.print("unknown int-simd op: {s}\n", .{op});
    return error.UnknownSimdOp;
}

/// Emits a 64x64 carry-less (GF(2)) multiply producing a 128-bit result bit-cast
/// to vector type `vt`.
///
/// Target-specialised on `self.simd_target`: AArch64 uses `pmull64`, x86-64
/// uses `pclmulqdq` (packing the operands into the low lane of a vector), and
/// the `.none` fallback expands the schoolbook shift-and-xor loop over 64 bits
/// with a branchless mask. This is the primitive behind GHASH/CRC-style code.
pub fn compileClmul64(self: *LlvmCompiler, a64: types.LLVMValueRef, b64: types.LLVMValueRef, vt: types.LLVMTypeRef) anyerror!types.LLVMValueRef {
    const ctx = core.LLVMGetModuleContext(self.module);
    switch (self.simd_target) {
        .aarch64 => {
            const name: [:0]const u8 = "llvm.aarch64.neon.pmull64";
            const id = core.LLVMLookupIntrinsicID(name.ptr, name.len);
            const fn_val = core.LLVMGetIntrinsicDeclaration(self.module, id, null, 0);
            const fn_ty = core.LLVMIntrinsicGetType(ctx, id, null, 0);
            var cargs = [_]types.LLVMValueRef{ a64, b64 };
            const res = core.LLVMBuildCall2(self.builder, fn_ty, fn_val, &cargs, 2, "clmul_pmull");
            return core.LLVMBuildBitCast(self.builder, res, vt, "clmul_v");
        },
        .x86_64 => {
            const name: [:0]const u8 = "llvm.x86.pclmulqdq";
            const id = core.LLVMLookupIntrinsicID(name.ptr, name.len);
            const fn_val = core.LLVMGetIntrinsicDeclaration(self.module, id, null, 0);
            const fn_ty = core.LLVMIntrinsicGetType(ctx, id, null, 0);
            const i64t = core.LLVMInt64Type();
            var av = core.LLVMGetUndef(vt);
            av = core.LLVMBuildInsertElement(self.builder, av, a64, core.LLVMConstInt(self.i32_type, 0, 0), "clmul_av0");
            av = core.LLVMBuildInsertElement(self.builder, av, core.LLVMConstInt(i64t, 0, 0), core.LLVMConstInt(self.i32_type, 1, 0), "clmul_av1");
            var bv = core.LLVMGetUndef(vt);
            bv = core.LLVMBuildInsertElement(self.builder, bv, b64, core.LLVMConstInt(self.i32_type, 0, 0), "clmul_bv0");
            bv = core.LLVMBuildInsertElement(self.builder, bv, core.LLVMConstInt(i64t, 0, 0), core.LLVMConstInt(self.i32_type, 1, 0), "clmul_bv1");
            var cargs = [_]types.LLVMValueRef{ av, bv, core.LLVMConstInt(self.i8_type, 0, 0) };
            return core.LLVMBuildCall2(self.builder, fn_ty, fn_val, &cargs, 3, "clmul_pclmul");
        },
        .none => {
            const i128t = core.LLVMIntType(128);
            const a128 = core.LLVMBuildZExt(self.builder, a64, i128t, "clmul_a128");
            var acc = core.LLVMConstInt(i128t, 0, 0);
            var i: c_uint = 0;
            while (i < 64) : (i += 1) {
                const bit = core.LLVMBuildAnd(self.builder, core.LLVMBuildLShr(self.builder, b64, core.LLVMConstInt(core.LLVMInt64Type(), i, 0), "clmul_sh"), core.LLVMConstInt(core.LLVMInt64Type(), 1, 0), "clmul_bit");
                const bit128 = core.LLVMBuildZExt(self.builder, bit, i128t, "clmul_bit128");
                const mask = core.LLVMBuildNeg(self.builder, bit128, "clmul_mask");
                const shifted = core.LLVMBuildShl(self.builder, a128, core.LLVMConstInt(i128t, i, 0), "clmul_shl");
                acc = core.LLVMBuildXor(self.builder, acc, core.LLVMBuildAnd(self.builder, shifted, mask, "clmul_and"), "clmul_acc");
            }
            return core.LLVMBuildBitCast(self.builder, acc, vt, "clmul_vsw");
        },
    }
}

/// Emits one AES encryption round on `state` with round key `rk`, `last`
/// selecting the final round (no MixColumns).
///
/// AArch64's `aese` combines SubBytes+ShiftRows+AddRoundKey but XORs the key
/// FIRST, so this passes a zero key and XORs `rk` afterwards, adding `aesmc`
/// (MixColumns) for non-final rounds. x86-64 maps directly onto
/// `aesenc`/`aesenclast`. The `.none` target has no software fallback and
/// returns `error.UnknownSimdOp`.
pub fn compileAesRound(self: *LlvmCompiler, state: types.LLVMValueRef, rk: types.LLVMValueRef, vt: types.LLVMTypeRef, last: bool) anyerror!types.LLVMValueRef {
    const ctx = core.LLVMGetModuleContext(self.module);
    switch (self.simd_target) {
        .aarch64 => {
            const zero = core.LLVMConstNull(vt);
            const aese_name: [:0]const u8 = "llvm.aarch64.crypto.aese";
            const aese_id = core.LLVMLookupIntrinsicID(aese_name.ptr, aese_name.len);
            const aese_fn = core.LLVMGetIntrinsicDeclaration(self.module, aese_id, null, 0);
            const aese_ty = core.LLVMIntrinsicGetType(ctx, aese_id, null, 0);
            var aese_args = [_]types.LLVMValueRef{ state, zero };
            var t = core.LLVMBuildCall2(self.builder, aese_ty, aese_fn, &aese_args, 2, "aese");
            if (!last) {
                const mc_name: [:0]const u8 = "llvm.aarch64.crypto.aesmc";
                const mc_id = core.LLVMLookupIntrinsicID(mc_name.ptr, mc_name.len);
                const mc_fn = core.LLVMGetIntrinsicDeclaration(self.module, mc_id, null, 0);
                const mc_ty = core.LLVMIntrinsicGetType(ctx, mc_id, null, 0);
                var mc_args = [_]types.LLVMValueRef{t};
                t = core.LLVMBuildCall2(self.builder, mc_ty, mc_fn, &mc_args, 1, "aesmc");
            }
            return core.LLVMBuildXor(self.builder, t, rk, "aes_ark");
        },
        .x86_64 => {
            const i64x2 = core.LLVMVectorType(core.LLVMInt64Type(), 2);
            const s2 = core.LLVMBuildBitCast(self.builder, state, i64x2, "aes_s2");
            const k2 = core.LLVMBuildBitCast(self.builder, rk, i64x2, "aes_k2");
            const name: [:0]const u8 = if (last) "llvm.x86.aesni.aesenclast" else "llvm.x86.aesni.aesenc";
            const id = core.LLVMLookupIntrinsicID(name.ptr, name.len);
            const fn_val = core.LLVMGetIntrinsicDeclaration(self.module, id, null, 0);
            const fn_ty = core.LLVMIntrinsicGetType(ctx, id, null, 0);
            var cargs = [_]types.LLVMValueRef{ s2, k2 };
            const r = core.LLVMBuildCall2(self.builder, fn_ty, fn_val, &cargs, 2, "aesni");
            return core.LLVMBuildBitCast(self.builder, r, vt, "aes_v");
        },
        .none => return error.UnknownSimdOp,
    }
}

/// Maps a Nova integer type name to its bit width and signedness for the raw
/// `mem.*` load/store intrinsics.
///
/// Covers the width/sign aliases (`byte`/`i8`, `int`/`i32`, `long`/`i64`,
/// `word`/`usize`, and their unsigned forms). An unrecognised name defaults to
/// signed 32-bit. Consumed by [`compileMemCall`].
fn memWidthSign(tname: []const u8) struct { w: c_uint, signed: bool } {
    const M = struct { n: []const u8, w: c_uint, s: bool };
    const tbl = [_]M{
        .{ .n = "byte", .w = 8, .s = true },    .{ .n = "ubyte", .w = 8, .s = false },
        .{ .n = "i8", .w = 8, .s = true },      .{ .n = "u8", .w = 8, .s = false },
        .{ .n = "short", .w = 16, .s = true },  .{ .n = "ushort", .w = 16, .s = false },
        .{ .n = "i16", .w = 16, .s = true },    .{ .n = "u16", .w = 16, .s = false },
        .{ .n = "int", .w = 32, .s = true },    .{ .n = "uint", .w = 32, .s = false },
        .{ .n = "i32", .w = 32, .s = true },    .{ .n = "u32", .w = 32, .s = false },
        .{ .n = "long", .w = 64, .s = true },   .{ .n = "ulong", .w = 64, .s = false },
        .{ .n = "i64", .w = 64, .s = true },    .{ .n = "u64", .w = 64, .s = false },
        .{ .n = "word", .w = 64, .s = false },  .{ .n = "usize", .w = 64, .s = false },
    };
    for (tbl) |m| if (std.mem.eql(u8, tname, m.n)) return .{ .w = m.w, .signed = m.s };
    return .{ .w = 32, .signed = true };
}

/// Byte-reverses an integer of width `w` (LLVM type `iw`) by shift/mask/or,
/// returning `v` unchanged for widths of one byte or less.
///
/// Used by [`compileMemCall`] to implement big-endian loads/stores and `bswap`.
/// It open-codes the swap rather than calling `llvm.bswap` so it works for any
/// byte count uniformly.
fn memByteReverse(self: *LlvmCompiler, v: types.LLVMValueRef, iw: types.LLVMTypeRef, w: c_uint) types.LLVMValueRef {
    const bytes = w / 8;
    if (bytes <= 1) return v;
    var acc = core.LLVMConstInt(iw, 0, 0);
    var i: c_uint = 0;
    while (i < bytes) : (i += 1) {
        const shifted = core.LLVMBuildLShr(self.builder, v, core.LLVMConstInt(iw, i * 8, 0), "br_sh");
        const masked = core.LLVMBuildAnd(self.builder, shifted, core.LLVMConstInt(iw, 0xff, 0), "br_mask");
        const placed = core.LLVMBuildShl(self.builder, masked, core.LLVMConstInt(iw, (bytes - 1 - i) * 8, 0), "br_place");
        acc = core.LLVMBuildOr(self.builder, acc, placed, "br_or");
    }
    return acc;
}

/// Lowers a `mem.*<T>` intrinsic: typed raw-memory access and bit ops on an
/// integer address.
///
/// `type_arg` is the element type `T` (giving width/signedness via
/// [`memWidthSign`]). Implements `load`/`store` at `ptr+off` with a runtime
/// endianness flag (byte-reversed on big-endian via [`memByteReverse`]),
/// `bswap`, `rotl`/`rotr` (via `llvm.fshl`/`fshr`), and `ctz`/`clz`. Results
/// are sign- or zero-extended back into the value word per `T`. Returns
/// `error.UnknownMemOp` for an unrecognised `field`. These are the primitives
/// the binary-protocol/codec std code builds on; note that offsets are added on
/// the 64-bit address word to avoid the 32-bit `int` truncation trap.
pub fn compileMemCall(self: *LlvmCompiler, field: []const u8, type_arg: ast.TypeRef, args: []const ast.Expression) anyerror!types.LLVMValueRef {
    const tname = try self.typeRefToString(type_arg);
    const ws = memWidthSign(tname);
    const iw = core.LLVMIntType(ws.w);
    const iwptr = core.LLVMPointerType(iw, 0);

    if (std.mem.eql(u8, field, "load")) {
        const p = try self.compileExpression(args[0]);
        const off = try self.compileExpression(args[1]);
        const endv = try self.compileExpression(args[2]);
        const addr = core.LLVMBuildAdd(self.builder, p, off, "mem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, iwptr, "mem_ptr");
        const loaded = core.LLVMBuildLoad2(self.builder, iw, ptr, "mem_load");
        var val = loaded;
        if (ws.w > 8) {
            const swapped = memByteReverse(self, loaded, iw, ws.w);
            const big = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, endv, core.LLVMConstInt(core.LLVMTypeOf(endv), 1, 0), "mem_big");
            val = core.LLVMBuildSelect(self.builder, big, swapped, loaded, "mem_endsel");
        }
        if (ws.signed) return core.LLVMBuildSExt(self.builder, val, self.val_type, "mem_sext");
        return core.LLVMBuildZExt(self.builder, val, self.val_type, "mem_zext");
    }
    if (std.mem.eql(u8, field, "store")) {
        const p = try self.compileExpression(args[0]);
        const off = try self.compileExpression(args[1]);
        const v = try self.compileExpression(args[2]);
        const endv = try self.compileExpression(args[3]);
        const truncated = core.LLVMBuildTrunc(self.builder, v, iw, "mem_trunc");
        var to_store = truncated;
        if (ws.w > 8) {
            const swapped = memByteReverse(self, truncated, iw, ws.w);
            const big = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, endv, core.LLVMConstInt(core.LLVMTypeOf(endv), 1, 0), "mem_big");
            to_store = core.LLVMBuildSelect(self.builder, big, swapped, truncated, "mem_endsel");
        }
        const addr = core.LLVMBuildAdd(self.builder, p, off, "mem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, iwptr, "mem_ptr");
        _ = core.LLVMBuildStore(self.builder, to_store, ptr);
        return core.LLVMConstInt(self.val_type, 0, 0);
    }
    if (std.mem.eql(u8, field, "bswap")) {
        const x = try self.compileExpression(args[0]);
        const xw = core.LLVMBuildTrunc(self.builder, x, iw, "bsw_tr");
        const rev = if (ws.w > 8) memByteReverse(self, xw, iw, ws.w) else xw;
        if (ws.signed) return core.LLVMBuildSExt(self.builder, rev, self.val_type, "bsw_sx");
        return core.LLVMBuildZExt(self.builder, rev, self.val_type, "bsw_zx");
    }
    if (std.mem.eql(u8, field, "rotl") or std.mem.eql(u8, field, "rotr")) {
        const x = try self.compileExpression(args[0]);
        const n = try self.compileExpression(args[1]);
        const xw = core.LLVMBuildTrunc(self.builder, x, iw, "rot_x");
        const nw = core.LLVMBuildTrunc(self.builder, n, iw, "rot_n");
        const iname: [:0]const u8 = if (std.mem.eql(u8, field, "rotl")) "llvm.fshl" else "llvm.fshr";
        const id = core.LLVMLookupIntrinsicID(iname.ptr, iname.len);
        var ptypes = [_]types.LLVMTypeRef{iw};
        const fn_val = core.LLVMGetIntrinsicDeclaration(self.module, id, &ptypes, 1);
        const fn_ty = core.LLVMIntrinsicGetType(core.LLVMGetModuleContext(self.module), id, &ptypes, 1);
        var cargs = [_]types.LLVMValueRef{ xw, xw, nw };
        const res = core.LLVMBuildCall2(self.builder, fn_ty, fn_val, &cargs, 3, "rot");
        if (ws.signed) return core.LLVMBuildSExt(self.builder, res, self.val_type, "rot_sx");
        return core.LLVMBuildZExt(self.builder, res, self.val_type, "rot_zx");
    }
    if (std.mem.eql(u8, field, "ctz") or std.mem.eql(u8, field, "clz")) {
        const x = try self.compileExpression(args[0]);
        const xw = core.LLVMBuildTrunc(self.builder, x, iw, "cnt_x");
        const iname: [:0]const u8 = if (std.mem.eql(u8, field, "ctz")) "llvm.cttz" else "llvm.ctlz";
        const id = core.LLVMLookupIntrinsicID(iname.ptr, iname.len);
        var ptypes = [_]types.LLVMTypeRef{iw};
        const fn_val = core.LLVMGetIntrinsicDeclaration(self.module, id, &ptypes, 1);
        const fn_ty = core.LLVMIntrinsicGetType(core.LLVMGetModuleContext(self.module), id, &ptypes, 1);
        var cargs = [_]types.LLVMValueRef{ xw, core.LLVMConstInt(self.i1_type, 0, 0) };
        const res = core.LLVMBuildCall2(self.builder, fn_ty, fn_val, &cargs, 2, "cnt");
        return core.LLVMBuildZExt(self.builder, res, self.val_type, "cnt_z");
    }
    std.debug.print("unknown mem op: {s}\n", .{field});
    return error.UnknownMemOp;
}

/// Calls a closure through its box: loads the code pointer, passes the env slot
/// as the hidden first argument, and forwards the compiled call arguments.
///
/// The box layout is `{fn_ptr_word, env_word, ...captures}`; the env address is
/// the box address plus one value slot, so a closure sees its captured
/// environment as `arg0`. All arguments are coerced to the value word. The
/// callee function type is reconstructed as `(env, args...) -> val` since the
/// pointer is opaque.
pub fn buildClosureCall(self: *LlvmCompiler, box_val: types.LLVMValueRef, call_args: []const ast.Expression) anyerror!types.LLVMValueRef {
    const es = self.valSlotSize();
    const box_ptr = core.LLVMBuildIntToPtr(self.builder, box_val, self.ptr_type, "clo_box");
    const fn_ptr_int = core.LLVMBuildLoad2(self.builder, self.val_type, box_ptr, "clo_fn");
    const env_off = core.LLVMConstInt(self.val_type, es, 0);
    const env_addr = core.LLVMBuildAdd(self.builder, box_val, env_off, "clo_env_addr");
    const env_ptr = core.LLVMBuildIntToPtr(self.builder, env_addr, self.ptr_type, "clo_env_ptr");
    const env_val = core.LLVMBuildLoad2(self.builder, self.val_type, env_ptr, "clo_env");
    const call_ptr = core.LLVMBuildIntToPtr(self.builder, fn_ptr_int, self.ptr_type, "clo_fn_ptr");

    const nparams = call_args.len + 1;
    const params = try self.allocator.alloc(types.LLVMTypeRef, nparams);
    defer self.allocator.free(params);
    @memset(params, self.val_type);
    const fn_t = core.LLVMFunctionType(self.val_type, params.ptr, @intCast(nparams), 0);

    const args = try self.allocator.alloc(types.LLVMValueRef, nparams);
    defer self.allocator.free(args);
    args[0] = env_val;
    for (call_args, 0..) |arg, idx| {
        args[idx + 1] = self.coerceToSlotType(try self.compileCallArgument(arg), self.val_type);
    }
    return core.LLVMBuildCall2(self.builder, fn_t, call_ptr, args.ptr, @intCast(nparams), "closure_call");
}

/// The LLVM struct type of an async coroutine's promise: two value words,
/// `{result, waiter}`.
///
/// The promise is embedded in the coroutine frame by the LLVM coroutine lowering
/// and reached through `llvm.coro.promise`. Slot 0 holds the awaited result and
/// slot 1 the handle of a coroutine waiting on this one. See
/// [`coroPromiseResultSlot`] and [`coroPromiseWaiterSlot`].
pub fn coroPromiseType(self: *LlvmCompiler) types.LLVMTypeRef {
    var fields = [_]types.LLVMTypeRef{ self.val_type, self.val_type };
    return core.LLVMStructType(&fields, 2, 0);
}

/// GEPs to field `idx` of the coroutine promise struct, naming the resulting
/// pointer `name`.
///
/// Low-level accessor shared by [`coroPromiseResultSlot`]/
/// [`coroPromiseWaiterSlot`].
pub fn coroPromiseSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef, idx: c_uint, name: [:0]const u8) types.LLVMValueRef {
    var indices = [_]types.LLVMValueRef{
        core.LLVMConstInt(self.i32_type, 0, 0),
        core.LLVMConstInt(self.i32_type, idx, 0),
    };
    return core.LLVMBuildInBoundsGEP2(self.builder, self.coroPromiseType(), promise_ptr, &indices, 2, name.ptr);
}

/// Pointer to the coroutine's result slot (promise field 0), where its return
/// value is written before completion and read by the awaiter.
pub fn coroPromiseResultSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef) types.LLVMValueRef {
    return self.coroPromiseSlot(promise_ptr, 0, "coro.result.slot");
}

/// Pointer to the coroutine's waiter slot (promise field 1), holding the handle
/// of the coroutine to resume when this one finishes.
pub fn coroPromiseWaiterSlot(self: *LlvmCompiler, promise_ptr: types.LLVMValueRef) types.LLVMValueRef {
    return self.coroPromiseSlot(promise_ptr, 1, "coro.waiter.slot");
}

/// Given a coroutine handle, calls `llvm.coro.promise` to get a pointer to its
/// embedded promise (aligned to 8).
///
/// The promise pointer is then narrowed to specific slots with
/// [`coroPromiseResultSlot`]/[`coroPromiseWaiterSlot`].
pub fn buildCoroPromisePtr(self: *LlvmCompiler, hdl: types.LLVMValueRef) types.LLVMValueRef {
    const promise_fn = self.func_map.get("llvm.coro.promise").?;
    const promise_t = core.LLVMGlobalGetValueType(promise_fn);
    var p_args = [_]types.LLVMValueRef{
        hdl,
        core.LLVMConstInt(self.i32_type, 8, 0),
        core.LLVMConstInt(self.i1_type, 0, 0),
    };
    return core.LLVMBuildCall2(self.builder, promise_t, promise_fn, &p_args, 3, "coro.promise");
}

/// Calls an async function and synchronously drives its coroutine to
/// completion, returning the result value.
///
/// Convenience wrapper: build the call (which returns a coroutine handle) then
/// [`buildDriveAsyncHandle`]. Used at the sync/async boundary, e.g. calling an
/// async function from `main`.
pub fn buildDriveAsyncCall(self: *LlvmCompiler, fn_val: types.LLVMValueRef, args: []const types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const hdl_i = try self.buildCallWithCasts(fn_val, args);
    return try self.buildDriveAsyncHandle(hdl_i);
}

/// Schedules a coroutine handle on the runtime, runs the reactor to
/// completion, reads its result, and releases the frame.
///
/// The full blocking drive: `nova_sched_schedule` then `nova_run_root` (which
/// returns only when the root coroutine finishes), then loads the promise
/// result slot and calls `nova_coro_release` to free the frame. This is how an
/// async call is turned into a plain synchronous value at the top level; do not
/// use it from inside another coroutine (use [`buildAwait`] instead).
pub fn buildDriveAsyncHandle(self: *LlvmCompiler, hdl_i: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const sched_fn = self.func_map.get("nova_sched_schedule").?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");

    const run_fn = self.func_map.get("nova_run_root").?;
    const run_t = core.LLVMGlobalGetValueType(run_fn);
    var run_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, run_t, run_fn, &run_args, 1, "");

    const hdl = core.LLVMBuildIntToPtr(self.builder, hdl_i, self.ptr_type, "async.root");
    const prom = self.buildCoroPromisePtr(hdl);
    const rslot = self.coroPromiseResultSlot(prom);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, rslot, "async.result");

    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{hdl_i};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");

    return result;
}

/// If `operand` is a direct call to a known async function/method, compiles the
/// call and returns the coroutine handle WITHOUT driving it; null otherwise.
///
/// This is the shared front half of `await expr` and `spawn expr`: it resolves
/// which async function the operand names (plain ident, module-qualified,
/// generic instantiation with mangled type args, trait method via vtable, or a
/// struct method with a receiver), compiles the receiver and arguments with the
/// right value-optional/trait coercions, and emits the call. Returning null (an
/// operand that is not a direct async call) tells [`buildAwait`] to fall back to
/// awaiting a future value instead. When `is_spawn`, arguments that get widened
/// to trait objects are retained and pinned to the child coroutine via
/// `nova_coro_hold_arg` so they outlive the spawning frame. The many
/// resolution branches exist because async fns are keyed by mangled symbol and
/// the callee syntax can under-specify which instantiation is meant.
pub fn awaitedCallHandle(self: *LlvmCompiler, operand: ast.Expression, is_spawn: bool) anyerror!?types.LLVMValueRef {

    var callee_ident: []const u8 = undefined;
    var call_args: []const ast.Expression = undefined;

    var obj_name: ?[]const u8 = null;

    var method_sym: ?[]const u8 = null;

    var recv_expr: ?*const ast.Expression = null;
    switch (operand.kind) {
        .call => |c| {
            switch (c.callee.kind) {
                .ident => |n| callee_ident = n,
                .field_access => |fa| {

                    callee_ident = fa.field;
                    if (try self.resolveExpressionTypeName(fa.object)) |obj_ty_raw| {

                        const obj_ty = getStructBaseName(obj_ty_raw);
                        if (self.traits.get(obj_ty)) |trait_decl| {
                            for (trait_decl.methods, 0..) |tm, idx| {
                                if (std.mem.eql(u8, tm.name, fa.field)) {
                                    if (!tm.is_async) return null;
                                    return try self.buildTraitVtableCall(fa, idx, c.args);
                                }
                            }
                            return null;
                        }

                        const mono_cand = blk: {
                            if (std.mem.indexOfScalar(u8, obj_ty_raw, '<') == null) break :blk null;
                            const mangled = types_mod.mangleTypeName(self.allocator, obj_ty_raw) catch break :blk null;
                            defer self.allocator.free(mangled);
                            const mc = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled, fa.field }) catch break :blk null;
                            if (self.async_fns.contains(mc)) break :blk mc;
                            self.allocator.free(mc);
                            break :blk null;
                        };
                        const base = getStructBaseName(obj_ty);
                        const cand = mono_cand orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base, fa.field });
                        if (self.async_fns.contains(cand)) {
                            method_sym = cand;
                            recv_expr = fa.object;
                        } else {
                            self.allocator.free(cand);
                        }
                    }
                    if (fa.object.kind == .ident) obj_name = fa.object.kind.ident;
                },
                else => return null,
            }
            call_args = c.args;
        },
        .generic_call => |gc| {
            switch (gc.callee.kind) {
                .ident => |n| callee_ident = n,
                .field_access => |fa| {
                    callee_ident = fa.field;
                    if (fa.object.kind == .ident) obj_name = fa.object.kind.ident;
                    // Resolve the callee shape for a generic `object.field<T...>()`:
                    //
                    //  - If `object` is an INSTANCE (resolves to a struct type), this
                    //    is a generic METHOD call: build the monomorphized async
                    //    symbol `Owner_method__T...`, set `method_sym`, and pass the
                    //    receiver as the implicit first argument.
                    //  - Otherwise `object` is a MODULE (e.g. `db.query<T>` /
                    //    `orm.queryAs<T>`): rewrite `callee_ident` to the module's
                    //    fully-qualified free-function name (e.g. `data_db_query`) so
                    //    the resolution below builds the EXACT `data_db_query__T`.
                    //    Without this the mangled candidate is the bare `query__T`,
                    //    which misses the exact match and falls into an ambiguous
                    //    suffix search that can pick a SAME-NAMED method
                    //    (`Dapper_query__T`) instead, self-recursing and crashing.
                    if (try self.resolveExpressionTypeName(fa.object)) |obj_ty_raw| {
                        const base_sym = try self.methodSymbol(obj_ty_raw, fa.field);
                        var nb = std.ArrayListUnmanaged(u8).empty;
                        errdefer nb.deinit(self.allocator);
                        try nb.appendSlice(self.allocator, base_sym);
                        self.allocator.free(base_sym);
                        for (gc.type_args) |ta| {
                            const rendered = try self.typeRefToString(ta);
                            const ma = try types_mod.mangleTypeName(self.allocator, rendered);
                            defer self.allocator.free(ma);
                            try nb.appendSlice(self.allocator, "__");
                            try nb.appendSlice(self.allocator, ma);
                        }
                        const cand = try nb.toOwnedSlice(self.allocator);
                        if (self.async_fns.contains(cand)) {
                            method_sym = cand;
                            recv_expr = fa.object;
                        } else {
                            self.allocator.free(cand);
                        }
                    } else if (fa.object.kind == .ident) {
                        if (sema_shadow.live_sema) |sm| {
                            if (sm.tab.findModuleByImportNameForImporter(fa.object.kind.ident, fa.span.file)) |mid| {
                                if (sm.tab.findFunctionIn(mid, fa.field)) |sid| {
                                    callee_ident = sm.tab.symbolAt(sid).legacy_mangled;
                                }
                            }
                        }
                    }
                },
                else => return null,
            }
            call_args = gc.args;
        },
        else => return null,
    }
    defer if (method_sym) |ms| self.allocator.free(ms);

    const resolved = resolve: {

        if (method_sym) |ms| break :resolve ms;
        if (operand.kind == .call) {
            if (self.typed_ir) |ir| {
                if (ir.symOf(&operand)) |sid| {
                    if (sema_shadow.live_sema) |sm| {
                        const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                        if (self.hasFunction(legacy)) break :resolve legacy;
                    }
                }
            }
        }
        const base = try self.resolveCalleeName(callee_ident);

        if (operand.kind == .generic_call) {
            const gc = operand.kind.generic_call;
            if (gc.type_args.len > 0) {
                var nb = std.ArrayListUnmanaged(u8).empty;
                errdefer nb.deinit(self.allocator);
                try nb.appendSlice(self.allocator, base);
                for (gc.type_args) |ta| {
                    const rendered = try self.typeRefToString(ta);
                    const ma = try types_mod.mangleTypeName(self.allocator, rendered);
                    defer self.allocator.free(ma);
                    try nb.appendSlice(self.allocator, "__");
                    try nb.appendSlice(self.allocator, ma);
                }
                const cand = try nb.toOwnedSlice(self.allocator);
                if (self.async_fns.contains(cand)) break :resolve cand;
                {
                    var it = self.async_fns.keyIterator();
                    while (it.next()) |k| {
                        const key = k.*;
                        if (key.len > cand.len + 1 and key[key.len - cand.len - 1] == '_' and
                            std.mem.endsWith(u8, key, cand))
                        {
                            self.allocator.free(cand);
                            break :resolve key;
                        }
                    }
                }
                self.allocator.free(cand);
            }
        }

        if (self.async_fns.contains(base)) break :resolve base;

        if (obj_name) |on| {
            const qual = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ on, callee_ident });
            defer self.allocator.free(qual);
            var it = self.async_fns.keyIterator();
            while (it.next()) |k| {
                const key = k.*;
                if (std.mem.eql(u8, key, qual)) break :resolve key;
                if (key.len > qual.len + 1 and key[key.len - qual.len - 1] == '_' and
                    std.mem.endsWith(u8, key, qual)) break :resolve key;
            }
        }
        break :resolve base;
    };
    if (!self.async_fns.contains(resolved)) return null;
    const fn_val = self.func_map.get(resolved) orelse return null;

    const recv_off: usize = if (recv_expr != null) 1 else 0;
    const args = try self.allocator.alloc(types.LLVMValueRef, call_args.len + recv_off);
    defer self.allocator.free(args);

    var spawn_held = std.ArrayListUnmanaged(types.LLVMValueRef).empty;
    defer spawn_held.deinit(self.allocator);
    if (recv_expr) |re| args[0] = try self.compileCallArgument(re.*);
    for (call_args, 0..) |*arg, idx| {
        const psup = self.getFunctionParamType(resolved, idx + recv_off);
        self.suppress_valopt_unbox = psup != null and types_mod.valueOptionalName(psup.?);
        var val = try self.compileCallArgument(arg.*);
        self.suppress_valopt_unbox = false;

        val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(resolved, idx + recv_off), psup);

        const pidx = idx + recv_off;
        if (self.getFunctionParamType(resolved, pidx)) |expected_type| {
            const exp_base = getStructBaseName(expected_type);
            if (self.traits.contains(exp_base)) {
                if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                    if (self.structs.contains(getStructBaseName(struct_name))) {
                        val = try self.constructTraitObject(val, struct_name, expected_type);
                        if (is_spawn) {
                            try self.compileRetain(val);
                            try spawn_held.append(self.allocator, val);
                        }
                    }
                }
            } else if (self.structs.contains(exp_base)) {
                if (try self.resolveExpressionTypeName(arg)) |arg_type| {
                    if (self.traits.contains(getStructBaseName(arg_type))) {
                        const sp_ptr = core.LLVMBuildIntToPtr(self.builder, val, core.LLVMPointerType(self.val_type, 0), "argdowncast_sp");
                        val = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "argdowncast_struct");
                    }
                }
            }
        }
        args[pidx] = val;
    }
    const handle = try self.buildCallWithCasts(fn_val, args);

    if (is_spawn and spawn_held.items.len > 0) {
        const hold_fn = self.func_map.get("nova_coro_hold_arg").?;
        const hold_t = core.LLVMGlobalGetValueType(hold_fn);
        const trait_dtor = try self.getOrCreateTraitDestructor();
        for (spawn_held.items) |held| {
            var h_args = [_]types.LLVMValueRef{ handle, held, trait_dtor };
            _ = core.LLVMBuildCall2(self.builder, hold_t, hold_fn, &h_args, 3, "");
        }
    }
    return handle;
}

/// Emits an `llvm.coro.suspend` point and the switch that routes resume/destroy,
/// leaving the builder positioned on the resume block.
///
/// The suspend's result switches to: the shared final-suspend block on the
/// default (never actually taken here since this is a mid-body suspend), the
/// freshly created resume block on 0, and the cleanup block on 1 (coroutine
/// destroyed while suspended). Every await/receive/timer path calls this so the
/// coroutine yields control back to the scheduler and resumes in place.
pub fn buildAwaitSuspend(self: *LlvmCompiler) anyerror!void {
    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "await.resume");
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "await.susp");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
}

/// Recognises `await sleep(ms)` and returns the `ms` argument expression, else
/// null.
///
/// A syntactic pattern match on the operand so [`buildAwait`] can lower a sleep
/// to a runtime timer rather than a coroutine call. `self` is unused; the
/// parameter is kept for method-call uniformity.
pub fn awaitSleepMillis(self: *LlvmCompiler, operand: ast.Expression) ?ast.Expression {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    if (call.args.len != 1) return null;
    const is_sleep = switch (call.callee.kind) {
        .ident => |n| std.mem.eql(u8, n, "sleep"),
        .field_access => |fa| std.mem.eql(u8, fa.field, "sleep"),
        else => false,
    };
    if (!is_sleep) return null;
    return call.args[0];
}

/// Recognises `await chanRecv(ch)` and returns the channel expression, else
/// null.
///
/// Lets [`buildAwait`] route to [`buildChanRecv`], which has its own
/// retry/suspend loop. `self` is unused (kept for uniformity).
pub fn awaitChanRecvArg(self: *LlvmCompiler, operand: ast.Expression) ?ast.Expression {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    if (call.args.len != 1) return null;
    const is_recv = switch (call.callee.kind) {
        .ident => |n| std.mem.eql(u8, n, "chanRecv"),
        .field_access => |fa| std.mem.eql(u8, fa.field, "chanRecv"),
        else => false,
    };
    if (!is_recv) return null;
    return call.args[0];
}

/// Recognises `await <async-io>(...)` for the known intrinsic I/O calls and
/// returns the call node, else null.
///
/// Matches the fixed set of runtime I/O primitives by name AND exact arity
/// (`socketRecvAsync`, `socketAcceptAsync`, `aaccept`, `aconnect`,
/// `async_read`, `async_read_deadline`, `async_write`) so [`buildAwait`] can
/// lower them to a submit-then-suspend via [`buildAsyncIo`] rather than treating
/// them as ordinary async fn calls. `self` is unused.
pub fn awaitAsyncIoCall(self: *LlvmCompiler, operand: ast.Expression) ?ast.CallExpr {
    _ = self;
    if (operand.kind != .call) return null;
    const call = operand.kind.call;
    const name = switch (call.callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => return null,
    };
    if ((std.mem.eql(u8, name, "socketRecvAsync") and call.args.len == 3) or
        (std.mem.eql(u8, name, "socketAcceptAsync") and call.args.len == 1) or
        (std.mem.eql(u8, name, "aaccept") and call.args.len == 1) or
        (std.mem.eql(u8, name, "aconnect") and call.args.len == 2) or
        (std.mem.eql(u8, name, "async_read") and call.args.len == 3) or
        (std.mem.eql(u8, name, "async_read_deadline") and call.args.len == 4) or
        (std.mem.eql(u8, name, "async_write") and call.args.len == 2))
    {
        return call;
    }
    return null;
}

/// Lowers an awaited async-I/O intrinsic: submit the operation tagged with this
/// coroutine's handle, suspend, then take the completed result.
///
/// Each recognised call (see [`awaitAsyncIoCall`]) maps to a runtime submit
/// function (`nova_arecv`/`nova_asend`/`nova_aaccept`/`nova_aconnect`/... and
/// their deadline variants) that registers the op against the current
/// coroutine handle (`current_async_hdl`). After the submit it suspends via
/// [`buildAwaitSuspend`]; when the reactor completes the op it resumes the
/// coroutine, and `nova_io_take_result` yields the byte count / new socket.
/// This is the proactor-style flow: the op is submitted, not polled.
pub fn buildAsyncIo(self: *LlvmCompiler, call: ast.CallExpr) anyerror!types.LLVMValueRef {
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self.current_async_hdl.?, self.val_type, "aio.selfh");
    const name = switch (call.callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => unreachable,
    };
    if (std.mem.eql(u8, name, "async_read_deadline")) {

        const a0 = try self.compileExpression(call.args[0]);
        const a1 = try self.compileExpression(call.args[1]);
        const a2 = try self.compileExpression(call.args[2]);
        const a3 = try self.compileExpression(call.args[3]);
        const f = self.func_map.get("nova_arecv_deadline").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ a0, a1, a2, a3, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 5, "");
    } else if (std.mem.eql(u8, name, "socketRecvAsync") or std.mem.eql(u8, name, "async_read")) {

        const a0 = try self.compileExpression(call.args[0]);
        const a1 = try self.compileExpression(call.args[1]);
        const a2 = try self.compileExpression(call.args[2]);
        const fname = if (std.mem.eql(u8, name, "async_read")) "nova_arecv" else "nova_io_recv_async";
        const f = self.func_map.get(fname).?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ a0, a1, a2, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 4, "");
    } else if (std.mem.eql(u8, name, "async_write")) {
        const sock = try self.compileExpression(call.args[0]);
        const data = try self.compileExpression(call.args[1]);
        const f = self.func_map.get("nova_asend").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ sock, data, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 3, "");
    } else if (std.mem.eql(u8, name, "aconnect")) {
        const host = try self.compileExpression(call.args[0]);
        const port = try self.compileExpression(call.args[1]);
        const f = self.func_map.get("nova_aconnect").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ host, port, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 3, "");
    } else {
        const s = try self.compileExpression(call.args[0]);
        const fname = if (std.mem.eql(u8, name, "aaccept")) "nova_aaccept" else "nova_io_accept_async";
        const f = self.func_map.get(fname).?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ s, self_hi };
        _ = core.LLVMBuildCall2(self.builder, t, f, &a, 2, "");
    }
    try self.buildAwaitSuspend();
    const take = self.func_map.get("nova_io_take_result").?;
    const take_t = core.LLVMGlobalGetValueType(take);
    var ta = [_]types.LLVMValueRef{self_hi};
    return core.LLVMBuildCall2(self.builder, take_t, take, &ta, 1, "aio.result");
}

/// Lowers `await chanRecv(ch)` as a retry loop that suspends while the channel
/// is empty and returns the received value.
///
/// Emits `loop -> nova_chan_recv(ch, self, out)`: a non-zero status means a
/// value landed in the `out` slot and control jumps to `done`; a zero status
/// means the receiver was parked, so the coroutine suspends and, on resume,
/// branches back to `loop` to retry. The loop is necessary because a wake does
/// not guarantee the value is still available (another receiver may race).
pub fn buildChanRecv(self: *LlvmCompiler, ch_expr: ast.Expression) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "chan.selfh");
    const ch = try self.compileExpression(ch_expr);
    const out = core.LLVMBuildAlloca(self.builder, self.val_type, "chan.out");

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const loop_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.loop");
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.susp");
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.resume");
    const done_bb = core.LLVMAppendBasicBlock(cur_fn, "chan.done");
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
    const recv_fn = self.func_map.get("nova_chan_recv").?;
    const recv_t = core.LLVMGlobalGetValueType(recv_fn);
    var r_args = [_]types.LLVMValueRef{ ch, self_hi, out };
    const status = core.LLVMBuildCall2(self.builder, recv_t, recv_fn, &r_args, 3, "chan.status");
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, status, core.LLVMConstInt(self.val_type, 0, 0), "chan.ready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, done_bb, susp_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "chan.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    return core.LLVMBuildLoad2(self.builder, self.val_type, out, "chan.val");
}

/// Lowers `await whenAny(buf, n)` / `whenAnyDeadline(buf, n, ms)` as a
/// suspend-retry loop returning the index of the first ready future (or the
/// timeout sentinel).
///
/// Calls `nova_when_any`(`_deadline`) over the `n`-element handle buffer tagged
/// with this coroutine; a result of `-1` means "none ready yet", so it suspends
/// and retries on resume, while any other index (including the deadline path's
/// timeout result) exits the loop. Mirrors [`buildChanRecv`]'s structure.
pub fn buildWhenAny(self: *LlvmCompiler, buf_expr: ast.Expression, n_expr: ast.Expression, ms_expr: ?ast.Expression) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "wany.selfh");
    const buf = try self.compileExpression(buf_expr);
    const n = try self.compileExpression(n_expr);

    const ms: ?types.LLVMValueRef = if (ms_expr) |m| try self.compileExpression(m) else null;

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const loop_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.loop");
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.susp");
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.resume");
    const done_bb = core.LLVMAppendBasicBlock(cur_fn, "wany.done");
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
    const idx = if (ms) |ms_val| blk: {
        const f = self.func_map.get("nova_when_any_deadline").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ buf, n, ms_val, self_hi };
        break :blk core.LLVMBuildCall2(self.builder, t, f, &a, 4, "wany.idx");
    } else blk: {
        const f = self.func_map.get("nova_when_any").?;
        const t = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{ buf, n, self_hi };
        break :blk core.LLVMBuildCall2(self.builder, t, f, &a, 3, "wany.idx");
    };

    const neg1 = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, -1)), 0);
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, idx, neg1, "wany.ready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, done_bb, susp_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "wany.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, loop_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    return idx;
}

/// Lowers `spawn expr` (or a detached spawn): starts the operand's async call
/// as an independent coroutine and returns its handle as a future.
///
/// Requires the operand be a direct async fn call, obtained via
/// [`awaitedCallHandle`] with `is_spawn=true` (so its arguments are pinned to
/// the child); a non-call operand is a hard error. Schedules the child with
/// `nova_sched_schedule` (or the `_detached` variant when `is_detached`, which
/// fire-and-forgets it) and returns the child handle so the caller can later
/// `await` it. The AST node is named `AwaitExpr` because `await`/`spawn` share
/// a shape.
pub fn buildGo(self: *LlvmCompiler, g: ast.AwaitExpr, is_detached: bool) anyerror!types.LLVMValueRef {

    const inner_hi = (try self.awaitedCallHandle(g.operand.*, true)) orelse {
        std.debug.print("'spawn' requires a direct async fn call (M3-D-4)\n", .{});
        return error.GoUnsupportedOperand;
    };
    const fname = if (is_detached) "nova_sched_schedule_detached" else "nova_sched_schedule";
    const sched_fn = self.func_map.get(fname).?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");
    return inner_hi;
}

/// Awaits an already-scheduled future handle (e.g. the result of `spawn`),
/// suspending only if it is not yet complete, and returns its result.
///
/// Calls `nova_await_future` to register this coroutine as the future's waiter;
/// if it reports ready, control skips straight to reading the result, otherwise
/// the coroutine suspends and resumes when the future completes. Then it reads
/// the child's promise result slot and releases the child frame. This is the
/// path taken by `await fut` where `fut` is a value, as opposed to
/// `await someAsyncFn(...)` which [`buildAwait`] handles inline.
pub fn buildAwaitFuture(self: *LlvmCompiler, fut_hi: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl.?;
    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "awaitf.selfh");
    const fut_h = core.LLVMBuildIntToPtr(self.builder, fut_hi, self.ptr_type, "awaitf.h");

    const fut_fn = self.func_map.get("nova_await_future").?;
    const fut_t = core.LLVMGlobalGetValueType(fut_fn);
    var f_args = [_]types.LLVMValueRef{ fut_hi, self_hi };
    const ready = core.LLVMBuildCall2(self.builder, fut_t, fut_fn, &f_args, 2, "awaitf.ready");

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const susp_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.susp");
    const read_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.read");
    const is_ready = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, ready, core.LLVMConstInt(self.val_type, 0, 0), "awaitf.isready");
    _ = core.LLVMBuildCondBr(self.builder, is_ready, read_bb, susp_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, susp_bb);
    const resume_bb = core.LLVMAppendBasicBlock(cur_fn, "awaitf.resume");
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = self.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(self.i1_type, 0, 0) };
    const s = core.LLVMBuildCall2(self.builder, suspend_t, suspend_fn, &s_args, 2, "awaitf.susp.tok");
    const sw = core.LLVMBuildSwitch(self.builder, s, self.current_async_suspend_bb.?, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 0, 0), resume_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(self.i8_type, 1, 0), self.current_async_cleanup_bb.?);
    core.LLVMPositionBuilderAtEnd(self.builder, resume_bb);
    _ = core.LLVMBuildBr(self.builder, read_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, read_bb);
    const prom = self.buildCoroPromisePtr(fut_h);
    const rslot = self.coroPromiseResultSlot(prom);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, rslot, "awaitf.result");

    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{fut_hi};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");
    return result;
}

/// Lowers an `await` expression, dispatching to the right suspend strategy for
/// what is being awaited.
///
/// Must run inside a coroutine (`current_async_hdl` set), else it is a compile
/// error. Order of recognition: `sleep(ms)` -> runtime timer + suspend;
/// `chanRecv` -> [`buildChanRecv`]; `whenAny`/`whenAnyDeadline` ->
/// [`buildWhenAny`]; a known async-I/O call -> [`buildAsyncIo`]; a direct async
/// fn call (via [`awaitedCallHandle`]) -> register-waiter + schedule + suspend +
/// read result + release; anything else is treated as an already-built future
/// and handed to [`buildAwaitFuture`]. The inline direct-call path registers
/// this coroutine as the child's waiter BEFORE scheduling it so the wake cannot
/// be missed.
pub fn buildAwait(self: *LlvmCompiler, aw: ast.AwaitExpr) anyerror!types.LLVMValueRef {
    const self_hdl = self.current_async_hdl orelse {

        std.debug.print("'await' used outside an async fn reached codegen\n", .{});
        return error.AwaitOutsideAsync;
    };

    if (self.awaitSleepMillis(aw.operand.*)) |ms_expr| {
        const ms_val = try self.compileExpression(ms_expr);
        const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "await.selfh");
        const timer_fn = self.func_map.get("nova_await_timer").?;
        const timer_t = core.LLVMGlobalGetValueType(timer_fn);
        var t_args = [_]types.LLVMValueRef{ self_hi, ms_val };
        _ = core.LLVMBuildCall2(self.builder, timer_t, timer_fn, &t_args, 2, "");
        try self.buildAwaitSuspend();
        return core.LLVMConstInt(self.val_type, 0, 0);
    }

    if (self.awaitChanRecvArg(aw.operand.*)) |ch_expr| {
        return try self.buildChanRecv(ch_expr);
    }

    if (aw.operand.kind == .call) {
        const c = aw.operand.kind.call;
        const nm: ?[]const u8 = switch (c.callee.kind) {
            .field_access => |fa| fa.field,
            .ident => |id| id,
            else => null,
        };
        if (nm) |name| {
            if (std.mem.eql(u8, name, "whenAny") and c.args.len == 2) {
                return try self.buildWhenAny(c.args[0], c.args[1], null);
            }
            if (std.mem.eql(u8, name, "whenAnyDeadline") and c.args.len == 3) {
                return try self.buildWhenAny(c.args[0], c.args[1], c.args[2]);
            }
        }
    }

    if (self.awaitAsyncIoCall(aw.operand.*)) |io_call| {
        return try self.buildAsyncIo(io_call);
    }
    const inner_hi = (try self.awaitedCallHandle(aw.operand.*, false)) orelse {
        const fut_hi = try self.compileExpression(aw.operand.*);
        return try self.buildAwaitFuture(fut_hi);
    };
    const inner_h = core.LLVMBuildIntToPtr(self.builder, inner_hi, self.ptr_type, "await.child");

    const self_hi = core.LLVMBuildPtrToInt(self.builder, self_hdl, self.val_type, "await.selfh");
    const reg_fn = self.func_map.get("nova_register_waiter").?;
    const reg_t = core.LLVMGlobalGetValueType(reg_fn);
    var reg_args = [_]types.LLVMValueRef{ inner_hi, self_hi };
    _ = core.LLVMBuildCall2(self.builder, reg_t, reg_fn, &reg_args, 2, "");

    const sched_fn = self.func_map.get("nova_sched_schedule").?;
    const sched_t = core.LLVMGlobalGetValueType(sched_fn);
    var sched_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, sched_t, sched_fn, &sched_args, 1, "");

    try self.buildAwaitSuspend();

    const child_prom2 = self.buildCoroPromisePtr(inner_h);
    const child_rslot = self.coroPromiseResultSlot(child_prom2);
    const result = core.LLVMBuildLoad2(self.builder, self.val_type, child_rslot, "await.result");

    const destroy_fn = self.func_map.get("nova_coro_release").?;
    const destroy_t = core.LLVMGlobalGetValueType(destroy_fn);
    var d_args = [_]types.LLVMValueRef{inner_hi};
    _ = core.LLVMBuildCall2(self.builder, destroy_t, destroy_fn, &d_args, 1, "");
    return result;
}

/// Emits (once, cached by name) a cleanup thunk that releases a lambda's owned
/// captures when its box is destroyed, returning the thunk address or the zero
/// word if there is nothing to release.
///
/// Walks the lambda's captures and, for each one whose local type is owned,
/// records its env slot index; if none are owned the box needs no destructor
/// and this returns 0. Otherwise it builds an internal `(env) -> void` function
/// that loads and releases each owned capture from the environment, so ARC over
/// closures is balanced. `span` is currently unused.
fn buildClosureCleanup(self: *LlvmCompiler, lambda_name: []const u8, span: ast.Span) anyerror!types.LLVMValueRef {
    const zero = core.LLVMConstInt(self.val_type, 0, 0);
    const caps = self.lambda_captures.get(lambda_name) orelse return zero;
    if (caps.items.len == 0) return zero;

    const name = try std.fmt.allocPrintSentinel(self.allocator, "__clocleanup_{s}", .{lambda_name}, 0);
    defer self.allocator.free(name);
    if (core.LLVMGetNamedFunction(self.module, name.ptr)) |existing| {
        return try self.fnRefInt(existing, name);
    }

    const es = self.valSlotSize();
    var slots = std.ArrayListUnmanaged(struct { i: usize, ty: []const u8 }).empty;
    defer slots.deinit(self.allocator);
    if (self.current_local_types) |lt| {
        for (caps.items, 0..) |cap, i| {
            if (lt.get(cap)) |ct| {
                if (self.isOwnedLocal(cap, ct)) try slots.append(self.allocator, .{ .i = i, .ty = ct });
            }
        }
    }
    if (slots.items.len == 0) return zero;
    _ = span;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const clean_fn = core.LLVMAddFunction(self.module, name.ptr, fn_type);
    core.LLVMSetLinkage(clean_fn, .LLVMInternalLinkage);
    const entry_bb = core.LLVMAppendBasicBlock(clean_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const env = core.LLVMGetParam(clean_fn, 0);
    for (slots.items) |s| {
        const off = core.LLVMConstInt(self.val_type, s.i * es, 0);
        const addr = core.LLVMBuildAdd(self.builder, env, off, "clo_cap_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "clo_cap_ptr");
        const val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "clo_cap");
        const dest = self.getOrCreateDestructor(s.ty) catch null;
        try self.compileRelease(val, dest);
    }
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);

    return try self.fnRefInt(clean_fn, name);
}

/// Substitutes type parameters for concrete type arguments across a list of
/// type refs, returning a freshly allocated slice.
///
/// Element-wise [`substOneTypeRef`]; used by [`initDefaultContainerFields`] to
/// specialise a generic field's declared type (e.g. `List<T>` -> `List<int>`)
/// before default-constructing it.
fn substFieldTypeArgs(self: *LlvmCompiler, params: []const ast.TypeRef, tparams: []const []const u8, targs: []const ast.TypeRef) anyerror![]ast.TypeRef {
    const out = try self.allocator.alloc(ast.TypeRef, params.len);
    for (params, 0..) |p, i| out[i] = try substOneTypeRef(self, p, tparams, targs);
    return out;
}
/// Substitutes type parameters in a single type ref, recursing into generic
/// arguments.
///
/// An `.ident` matching a type parameter name becomes the corresponding
/// argument; a `.generic` has its arguments substituted (via
/// [`substFieldTypeArgs`]) while keeping its name; anything else passes through.
fn substOneTypeRef(self: *LlvmCompiler, p: ast.TypeRef, tparams: []const []const u8, targs: []const ast.TypeRef) anyerror!ast.TypeRef {
    switch (p) {
        .ident => |nm| {
            for (tparams, 0..) |tp, i| {
                if (i < targs.len and std.mem.eql(u8, nm, tp)) return targs[i];
            }
            return p;
        },
        .generic => |g| {
            const np = try substFieldTypeArgs(self, g.params, tparams, targs);
            return ast.TypeRef{ .generic = .{ .name = g.name, .params = np } };
        },
        else => return p,
    }
}

/// Default-initialises a struct's fields that have an implied empty/zero value
/// so a struct built without an explicit constructor is not left with garbage
/// container fields.
///
/// For each field it synthesises and compiles a default expression: `List<...>`
/// -> `List<...>()` (type args substituted for the concrete instantiation),
/// `string` -> `""`, and a nested struct that has a no-arg constructor ->
/// `T()`. Other field types are left untouched (assumed set explicitly).
/// Inline value-struct fields are byte-copied into place; reference fields are
/// stored as a word. The `default_ctor_depth > 24` guard prevents unbounded
/// recursion through mutually default-constructing structs. Uses
/// [`structHasNoArgCtor`] to decide the nested-struct case.
pub fn initDefaultContainerFields(self: *LlvmCompiler, struct_name: []const u8, instance_ptr: types.LLVMValueRef, span: ast.Span, type_args: []const ast.TypeRef) anyerror!void {
    const sd = self.structs.get(struct_name) orelse return;
    if (self.default_ctor_depth > 24) return;
    self.default_ctor_depth += 1;
    defer self.default_ctor_depth -= 1;

    for (sd.fields) |f| {

        var callee_expr: ast.Expression = undefined;
        const zero_expr: ?ast.Expression = switch (f.type_name) {
            .generic => |g| blk: {
                if (!std.mem.eql(u8, g.name, "List")) break :blk null;
                const cparams = substFieldTypeArgs(self, g.params, sd.type_params, type_args) catch g.params;
                callee_expr = ast.Expression{ .kind = .{ .ident = "List" } };
                break :blk ast.Expression{ .kind = .{ .generic_call = .{
                    .callee = &callee_expr,
                    .type_args = cparams,
                    .args = &[_]ast.Expression{},
                    .span = span,
                } } };
            },
            .ident => |tn| blk: {
                if (std.mem.eql(u8, tn, "string")) {
                    break :blk ast.Expression{ .kind = .{ .literal = .{ .string = "" } } };
                }

                if (self.structs.contains(tn) and !self.traits.contains(tn) and structHasNoArgCtor(self, tn)) {
                    callee_expr = ast.Expression{ .kind = .{ .ident = tn } };
                    break :blk ast.Expression{ .kind = .{ .call = .{
                        .callee = &callee_expr,
                        .args = &[_]ast.Expression{},
                        .span = span,
                    } } };
                }
                break :blk null;
            },
            else => null,
        };
        const ze = zero_expr orelse continue;

        const fv = try self.compileExpression(ze);
        try self.takeOwnedElement(ze.kind, fv);
        const offset = try self.getFieldOffset(struct_name, f.name);
        const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
        const addr = core.LLVMBuildAdd(self.builder, instance_ptr, offset_val, "cf_addr");
        const f_tstr = self.typeRefToString(f.type_name) catch "";
        const ftbase = getStructBaseName(f_tstr);
        if (self.structs.contains(ftbase) and self.fieldStoredInline(ftbase)) {
            const fsz = self.getTypeSize(f.type_name, false);
            _ = try self.buildValueStructCopyInto(addr, fv, fsz);
        } else {
            const llvm_ft = self.toLLVMType(f.type_name);
            const fptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_ft, 0), "cf_ptr");
            _ = core.LLVMBuildStore(self.builder, self.castFromValType(fv, llvm_ft), fptr);
        }
    }
}

/// Whether a struct can be constructed with no user arguments.
///
/// True if it has an `init`/`new` method whose only parameter is `self`, or if
/// it has no `init`/`new` at all (implicit default construction). False if the
/// constructor requires arguments. Guards the nested-struct default case in
/// [`initDefaultContainerFields`].
fn structHasNoArgCtor(self: *LlvmCompiler, struct_name: []const u8) bool {
    const sd = self.structs.get(struct_name) orelse return false;
    for (sd.methods) |*m| {
        if (std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new")) {
            var user_params: usize = 0;
            for (m.decl.params) |p| {
                if (!std.mem.eql(u8, p.name, "self")) user_params += 1;
            }
            return user_params == 0;
        }
    }
    return true;
}

/// Whether a module-level const's initialiser is a plain literal, so it can be
/// emitted inline instead of behind a lazy-init guard.
fn isTrivialConstLiteral(expr: ast.Expression) bool {
    return expr.kind == .literal;
}

/// Lowers a reference to a module-level `const` with lazy, run-once
/// initialisation, returning the const's value word.
///
/// A trivial literal const is just recompiled inline. For a non-trivial
/// initialiser (which may allocate or call functions) it emits two internal
/// globals per const, a value slot and a `done` flag, and guards the
/// initialiser: on first reference it computes and stores the value and sets
/// the flag, on later references it loads the cached value. This gives
/// deterministic first-use initialisation without a static initialiser (which
/// Nova does not have) and memoises so the initialiser runs at most once.
pub fn compileConstRef(self: *LlvmCompiler, name: []const u8, val: ast.Expression) anyerror!types.LLVMValueRef {
    if (isTrivialConstLiteral(val)) return try self.compileExpression(val);

    const val_name = try std.fmt.allocPrint(self.allocator, "__const_{s}_val", .{name});
    defer self.allocator.free(val_name);
    const done_name = try std.fmt.allocPrint(self.allocator, "__const_{s}_done", .{name});
    defer self.allocator.free(done_name);
    const val_z = try self.allocator.dupeZ(u8, val_name);
    defer self.allocator.free(val_z);
    const done_z = try self.allocator.dupeZ(u8, done_name);
    defer self.allocator.free(done_z);

    var val_g = core.LLVMGetNamedGlobal(self.module, val_z.ptr);
    if (val_g == null) {
        val_g = core.LLVMAddGlobal(self.module, self.val_type, val_z.ptr);
        core.LLVMSetInitializer(val_g, core.LLVMConstInt(self.val_type, 0, 0));
        core.LLVMSetLinkage(val_g, .LLVMInternalLinkage);
        const done_new = core.LLVMAddGlobal(self.module, self.i1_type, done_z.ptr);
        core.LLVMSetInitializer(done_new, core.LLVMConstInt(self.i1_type, 0, 0));
        core.LLVMSetLinkage(done_new, .LLVMInternalLinkage);
    }
    const done_g = core.LLVMGetNamedGlobal(self.module, done_z.ptr);

    const cur_bb = core.LLVMGetInsertBlock(self.builder);
    const cur_fn = core.LLVMGetBasicBlockParent(cur_bb);
    const init_bb = core.LLVMAppendBasicBlock(cur_fn, "const_init");
    const cont_bb = core.LLVMAppendBasicBlock(cur_fn, "const_cont");

    const done_v = core.LLVMBuildLoad2(self.builder, self.i1_type, done_g, "const_done");
    const need = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, done_v, core.LLVMConstInt(self.i1_type, 0, 0), "const_need");
    _ = core.LLVMBuildCondBr(self.builder, need, init_bb, cont_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, init_bb);
    const computed = try compileExpressionInner(self, val);
    _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(computed, self.val_type), val_g);
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i1_type, 1, 0), done_g);
    _ = core.LLVMBuildBr(self.builder, cont_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
    return core.LLVMBuildLoad2(self.builder, self.val_type, val_g, "const_val");
}

/// THE expression entry point: lowers `expr` to a value and registers it as an
/// ARC temporary when this evaluation OWNS the result.
///
/// Delegates to [`compileExpressionInner`] for the actual lowering, then
/// consults the ownership disposition of the expression. If the value is merely
/// borrowed, it is returned as-is. If it is owned, the value is spilled to a
/// stack slot (via [`spillTemp`]) and pushed onto `pending_temps`, so
/// [`drainTemporaries`] releases it at the end of the statement, preventing
/// leaks of intermediate results. Value structs with no owned fields, or ones
/// returned as a borrow, are exempt from tracking. Every place that needs an
/// expression's value should call THIS, not `compileExpressionInner`, so the
/// cleanup is not skipped.
pub fn compileExpression(self: *LlvmCompiler, expr: ast.Expression) anyerror!types.LLVMValueRef {
    const val = try compileExpressionInner(self, expr);
    switch (self.acquisitionDisposition(&expr)) {
        .borrowed => return val,
        .owned => {},
    }
    const t = (try self.resolveExpressionTypeName(&expr)) orelse return val;
    if (self.isValueStructName(t) and (!self.valueStructHasOwnedFields(t) or self.returnIsBorrow(&expr))) return val;
    const slot = try spillTemp(self, val);
    try self.pending_temps.append(self.allocator, .{ .val = val, .slot = slot, .type_name = t, .expr_id = expr.id });
    return val;
}

/// Allocates an entry-block stack slot, zero-inits it there, stores `val` into
/// it at the current point, and returns the slot.
///
/// The alloca is placed at the top of the function's entry block (before the
/// first instruction) so it dominates all uses and is not re-run inside loops;
/// the zero-store also happens in the entry block so an unreleased-then-reloaded
/// slot reads null rather than garbage. Backs [`compileExpression`] and
/// [`registerTemporary`]; the slot is what [`drainTemporaries`] reloads and
/// releases.
fn spillTemp(self: *LlvmCompiler, val: types.LLVMValueRef) anyerror!types.LLVMValueRef {
    const cur_bb = core.LLVMGetInsertBlock(self.builder);
    const fn_val = core.LLVMGetBasicBlockParent(cur_bb);
    const entry_bb = core.LLVMGetEntryBasicBlock(fn_val);
    if (core.LLVMGetFirstInstruction(entry_bb)) |first| {
        core.LLVMPositionBuilderBefore(self.builder, first);
    } else {
        core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    }
    const slot = core.LLVMBuildAlloca(self.builder, self.val_type, "tmp_slot");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), slot);
    core.LLVMPositionBuilderAtEnd(self.builder, cur_bb);
    _ = core.LLVMBuildStore(self.builder, val, slot);
    return slot;
}

/// Resolves the storage width and LLVM integer type for an `Atomic<T>` cell,
/// or fails compilation with a diagnostic for an unsupported `T`.
///
/// Returns the bit width, an `is_i64` flag, byte size, and the LLVM type used
/// for atomic loads/stores/RMWs. `Atomic<T>` is only sound for integer and bool
/// types; a non-primitive or floating-point `T` prints a compiler error and
/// calls `process.exit(70)` (there is no valid atomic representation, so this
/// aborts rather than returning an error to unwind).
pub fn atomicCell(self: *LlvmCompiler, t_name: []const u8) struct { bits: u32, is_i64: bool, size: usize, ty: types.LLVMTypeRef } {
    const pr = types_mod.cgPrim(t_name) orelse {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m Atomic<{s}> is not supported\x1b[0m\n" ++
            "  Atomic<T> works only for integer and bool types (byte/short/int/long and their unsigned\n" ++
            "  forms, or bool). '{s}' is not one of these, so there is no sound atomic representation for\n" ++
            "  it. Use an integer/bool Atomic, or guard the value with an AsyncLock instead.\n",
            .{ t_name, t_name },
        );
        std.debug.print("(compilation failed)\n", .{});
        std.process.exit(70);
    };
    const bits: u32 = types_mod.reprBitWidth(pr.repr);
    if (pr.repr == .f32 or pr.repr == .f64) {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m Atomic<{s}> (floating point) is not supported\x1b[0m\n" ++
            "  Atomic<T> works only for integer and bool types. Store the bits in an Atomic<long> if you\n" ++
            "  need an atomic float, or guard the value with an AsyncLock.\n",
            .{t_name},
        );
        std.debug.print("(compilation failed)\n", .{});
        std.process.exit(70);
    }
    const is_i64 = bits == 64;
    const llvm_ty = if (is_i64) self.i64_type else if (bits == 1) self.i1_type else self.i32_type;
    return .{ .bits = bits, .is_i64 = is_i64, .size = @max(1, bits / 8), .ty = llvm_ty };
}

/// Emits a null-check that traps with a source location when a required
/// optional is dereferenced while absent.
///
/// A no-op unless `obj_expr` is statically optional. Otherwise it branches on
/// `handle == 0`: the fail branch calls `nova_optional_deref_fail` with a
/// `file:line` string and is `unreachable`; the ok branch continues. This is
/// the runtime backstop for non-null-asserted optional member access.
pub fn guardOptionalDeref(self: *LlvmCompiler, obj_expr: *const ast.Expression, handle: types.LLVMValueRef, span: ast.Span) anyerror!void {
    if (!self.isOptionalExpr(obj_expr)) return;
    const cur_bb = core.LLVMGetInsertBlock(self.builder);
    const cur_fn = core.LLVMGetBasicBlockParent(cur_bb);
    const is_null = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, handle, core.LLVMConstInt(self.val_type, 0, 0), "opt_is_null");
    const fail_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_deref_fail");
    const ok_bb = core.LLVMAppendBasicBlock(cur_fn, "opt_deref_ok");
    _ = core.LLVMBuildCondBr(self.builder, is_null, fail_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
    const loc_raw = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ span.file, span.line });
    defer self.allocator.free(loc_raw);
    const loc = try self.allocator.dupeZ(u8, loc_raw);
    defer self.allocator.free(loc);
    const loc_str = core.LLVMBuildGlobalString(self.builder, loc.ptr, "opt_loc");
    const loc_ptr = core.LLVMBuildBitCast(self.builder, loc_str, self.ptr_type, "opt_loc_ptr");
    const fail_fn = self.func_map.get("nova_optional_deref_fail").?;
    const fail_t = core.LLVMGlobalGetValueType(fail_fn);
    var args = [_]types.LLVMValueRef{loc_ptr};
    _ = core.LLVMBuildCall2(self.builder, fail_t, fail_fn, &args, 1, "");
    _ = core.LLVMBuildUnreachable(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
}

/// Shadow-verification only: compares codegen's move/drop decision for a
/// temporary against the typed IR ownership pass and bumps agree/disagree
/// counters.
///
/// `cg` is what codegen decided (`.move` when a temp was consumed, `.drop` when
/// it was released); `id` identifies the expression. Runs only under
/// `sema_shadow.report_enabled` and never affects emitted code; it exists to
/// catch divergence between the two ownership models while they are both live.
fn diffTempOp(self: *LlvmCompiler, id: ast.ExprId, cg: sema_infer.OwnOp) void {
    const ir = self.typed_ir orelse return;
    const pass_op = ir.opOf(id) orelse {
        sema_shadow.op_no_op += 1;
        return;
    };
    if (pass_op == cg) {
        sema_shadow.op_agree += 1;
    } else {
        sema_shadow.op_disagree += 1;
        switch (cg) {
            .drop => sema_shadow.op_disagree_cg_drop += 1,
            .move => sema_shadow.op_disagree_cg_move += 1,
        }

        if (self.typed_ir) |tir| {
            if (self.type_store) |s| {
                if (tir.typeOf2(id)) |tid| sema_shadow.op_last_disagree = @tagName(s.get(tid));
            }
        }
    }
}

/// Manually registers an already-computed value as an owned ARC temporary of
/// type `type_name`.
///
/// The imperative counterpart to the automatic tracking in
/// [`compileExpression`]: spills the value and appends a `pending_temps` entry
/// (with no expr id) so it will be released by [`drainTemporaries`]. Used by
/// call sites that synthesise an owned value outside the normal expression flow.
pub fn registerTemporary(self: *LlvmCompiler, val: types.LLVMValueRef, type_name: []const u8) anyerror!void {
    const slot = try spillTemp(self, val);
    try self.pending_temps.append(self.allocator, .{ .val = val, .slot = slot, .type_name = type_name });
}

/// Removes `val` from the pending-temporary list because ownership of it has
/// been transferred (moved) to somewhere that will release it.
///
/// Scans from the most recent entry and removes the first matching one, so a
/// temporary consumed by a store/return/argument is not double-released by
/// [`drainTemporaries`]. Under shadow reporting it records the decision as a
/// `.move` via [`diffTempOp`].
pub fn consumeTemporary(self: *LlvmCompiler, val: types.LLVMValueRef) void {
    var i = self.pending_temps.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pending_temps.items[i].val == val) {

            if (sema_shadow.report_enabled) diffTempOp(self, self.pending_temps.items[i].expr_id, .move);
            _ = self.pending_temps.orderedRemove(i);
            return;
        }
    }
}

/// Shadow-verification only: compares the string-derived destructor type name a
/// temporary carries against the name the typed IR would render, bumping
/// agree/disagree counters.
///
/// Codegen historically keyed destructors by a rendered type-name string;
/// this cross-checks that against the typed IR's `TypeId`-rendered name (both
/// the type-param-substituted form and the raw form) to detect the
/// "ownership-by-typename" corruption class. Diagnostic only; no effect on
/// emitted code. Runs under `sema_shadow.report_enabled`.
fn diffDtorName(self: *LlvmCompiler, t: @import("llvm_codegen.zig").PendingTemp) void {
    if (t.expr_id == .unassigned) {
        sema_shadow.dtor_name_no_id += 1;
        return;
    }
    const ir = self.typed_ir orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const st = self.type_store orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };

    var tid: ?sema_types.TypeId = null;
    if (self.current_instantiation_id) |inst| tid = ir.typeOfInst(t.expr_id, inst);
    if (tid == null) tid = ir.typeOf2(t.expr_id);
    const t_id = tid orelse {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const rendered = sema_shadow.renderLegacy(self.allocator, st, t_id) catch {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    const typed_name = self.substTypeParams(rendered) catch {
        sema_shadow.dtor_name_no_id += 1;
        return;
    };
    if (std.mem.eql(u8, typed_name, t.type_name)) {
        sema_shadow.dtor_name_agree += 1;
    } else {
        sema_shadow.dtor_name_disagree += 1;
        sema_shadow.dtor_name_last_disagree_string = t.type_name;
        sema_shadow.dtor_name_last_disagree_typed = typed_name;
    }

    if (std.mem.eql(u8, rendered, t.type_name)) {
        sema_shadow.dtor_name_raw_agree += 1;
    } else {
        sema_shadow.dtor_name_raw_disagree += 1;
        sema_shadow.dtor_name_raw_last = rendered;
    }
}

/// Resolves the destructor function to call when releasing a pending temporary,
/// preferring the typed-IR `TypeId` over the carried type-name string.
///
/// If the temp has an expr id and the typed IR knows its (possibly
/// instantiation-specific) type, it uses `getOrCreateDestructorByTypeId`;
/// otherwise it falls back to the string-keyed `getOrCreateDestructor`. The
/// TypeId path is preferred because it is not vulnerable to name-string
/// ambiguity. Called from [`drainTemporaries`].
fn drainDtor(self: *LlvmCompiler, t: @import("llvm_codegen.zig").PendingTemp) anyerror!?types.LLVMValueRef {
    if (t.expr_id != .unassigned) {
        if (self.typed_ir) |ir| {
            var tid: ?sema_types.TypeId = null;
            if (self.current_instantiation_id) |inst| tid = ir.typeOfInst(t.expr_id, inst);
            if (tid == null) tid = ir.typeOf2(t.expr_id);
            if (tid) |t_id| return self.getOrCreateDestructorByTypeId(t_id);
        }
    }
    return self.getOrCreateDestructor(t.type_name);
}

/// Releases and pops all pending ARC temporaries down to a saved `mark`,
/// emitting the destructor calls at the current point.
///
/// Callers snapshot `pending_temps.items.len` as `mark` before an expression
/// or statement and call this after to clean up everything registered since.
/// If the current block already has a terminator (e.g. an early return already
/// drained temps), it only truncates the list without emitting dead releases.
/// Otherwise it pops in LIFO order, reloading each spilled slot and releasing
/// it (value structs via `dropValueStruct`, others via the destructor from
/// [`drainDtor`]), then zeroes the slot so a later reload is null. Under shadow
/// reporting it also runs [`diffTempOp`]/[`diffDtorName`].
pub fn drainTemporaries(self: *LlvmCompiler, mark: usize) anyerror!void {
    if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {

        self.pending_temps.shrinkRetainingCapacity(@min(mark, self.pending_temps.items.len));
        return;
    }
    while (self.pending_temps.items.len > mark) {
        const t = self.pending_temps.pop().?;

        if (sema_shadow.report_enabled) diffTempOp(self, t.expr_id, .drop);

        if (sema_shadow.report_enabled) diffDtorName(self, t);

        const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, t.slot, "tmp_rel");
        if (self.isValueStructName(t.type_name)) {
            try self.dropValueStruct(loaded, t.type_name, null);
        } else {
            const dest = drainDtor(self, t) catch null;
            try self.compileRelease(loaded, dest);
        }

        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), t.slot);
    }
}

/// The exhaustive expression lowering: one `switch` arm per `ast.Expression`
/// kind, each emitting IR and returning the result value word.
///
/// This is the largest function in the backend and the heart of the file. It
/// does NOT do ownership/temporary tracking; that is added by its wrapper
/// [`compileExpression`], which is what almost everything should call. It is
/// invoked directly only where the wrapper's temp registration must be bypassed
/// (e.g. inside [`compileConstRef`]'s init guard).
///
/// The arms, in source order, cover: literals; identifiers (locals, captures,
/// globals, bare function references); binary and unary operators (with the
/// integer canonicalisation and div/overflow guards from [`intOpKind`],
/// [`canonicalizeInt`], [`emitIntDivGuard`]); `if` expressions; ordinary and
/// generic calls (the bulk: method resolution, trait dispatch, closures, the
/// SIMD/mem/element-witness intrinsics, builtin constructors); struct
/// initialisers; field access; closures/lambdas; indexing; tuples; `try`/`catch`
/// error handling; optional chaining and `??` nullish coalescing; JSX elements;
/// block and template (string-interpolation) expressions; `cast`; and
/// `await`/`spawn` (forwarding to [`buildAwait`]/[`buildGo`]). Value structs vs
/// reference types, and the single-word value representation, drive the many
/// `IntToPtr`/`PtrToInt`/coercion steps throughout.
fn compileExpressionInner(self: *LlvmCompiler, expr: ast.Expression) anyerror!types.LLVMValueRef {
    switch (expr.kind) {
        .literal => |lit| {
            switch (lit) {
                .integer => |val| {
                    return core.LLVMConstInt(self.val_type, @bitCast(val), 0);
                },
                .bool => |b| {
                    const val: u64 = if (b) 1 else 0;
                    return core.LLVMConstInt(self.val_type, val, 0);
                },
                .null, .undefined => {
                    return core.LLVMConstInt(self.val_type, 0, 0);
                },
                .string => |str| {
                    return try self.getOrCreateStringLiteral(str);
                },
                .array => |arr| {
                    const element_size: usize = 8;
                    const size_val = core.LLVMConstInt(self.val_type, arr.len * element_size, 0);

                    const base = try self.compileAllocArray(size_val);
                    for (arr, 0..) |elem, idx| {
                        const val = try self.compileExpression(elem);
                        var gi = [_]types.LLVMValueRef{core.LLVMConstInt(self.val_type, idx, 0)};
                        const ep = core.LLVMBuildInBoundsGEP2(self.builder, self.val_type, base, &gi, 1, "array_elem_ptr");
                        _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(val, self.val_type), ep);
                    }
                    return base;
                },
                .array_repeat => |ar| {
                    const element_size: usize = 8;
                    const size_val = core.LLVMConstInt(self.val_type, ar.count * element_size, 0);
                    const array_ptr_val = try self.compileAllocArray(size_val);
                    const fill_val = self.coerceToSlotType(try self.compileExpression(ar.value.*), self.val_type);

                    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
                    const head_bb = core.LLVMAppendBasicBlock(cur_fn, "arr_rep_head");
                    const body_bb = core.LLVMAppendBasicBlock(cur_fn, "arr_rep_body");
                    const done_bb = core.LLVMAppendBasicBlock(cur_fn, "arr_rep_done");
                    const entry_bb = core.LLVMGetInsertBlock(self.builder);
                    _ = core.LLVMBuildBr(self.builder, head_bb);

                    core.LLVMPositionBuilderAtEnd(self.builder, head_bb);
                    const iv = core.LLVMBuildPhi(self.builder, self.val_type, "arr_rep_i");
                    const count_val = core.LLVMConstInt(self.val_type, ar.count, 0);
                    const cond = core.LLVMBuildICmp(self.builder, .LLVMIntULT, iv, count_val, "arr_rep_cond");
                    _ = core.LLVMBuildCondBr(self.builder, cond, body_bb, done_bb);

                    core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
                    var gidx = [_]types.LLVMValueRef{iv};
                    const slot = core.LLVMBuildInBoundsGEP2(self.builder, self.val_type, array_ptr_val, &gidx, 1, "arr_rep_slot");
                    _ = core.LLVMBuildStore(self.builder, fill_val, slot);
                    const next = core.LLVMBuildAdd(self.builder, iv, core.LLVMConstInt(self.val_type, 1, 0), "arr_rep_next");
                    _ = core.LLVMBuildBr(self.builder, head_bb);

                    var inc_vals = [_]types.LLVMValueRef{ core.LLVMConstInt(self.val_type, 0, 0), next };
                    var inc_bbs = [_]types.LLVMBasicBlockRef{ entry_bb, body_bb };
                    core.LLVMAddIncoming(iv, &inc_vals, &inc_bbs, 2);

                    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
                    return array_ptr_val;
                },
                .float => |val| {

                    return core.LLVMConstReal(core.LLVMDoubleType(), val);
                },
                .decimal => |digits| {
                    return try self.getOrCreateDecimalLiteral(digits);
                },
                else => {
                    std.debug.print("Literal type not supported yet: {s}\n", .{@tagName(lit)});
                    return error.UnsupportedLiteral;
                },
            }
        },
        .ident => |name| {

            if (self.envCaptureIndex(name)) |idx| {
                const addr = try self.envSlotAddr(idx);
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_ptr_load");
                return core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "env_capture_load");
            }
            var curr_fn = self.current_function_name;
            while (curr_fn) |fn_name| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                defer self.allocator.free(key);
                if (self.captured_globals.get(key)) |global_var| {
                    return core.LLVMBuildLoad2(self.builder, self.val_type, global_var, "captured_load");
                }
                curr_fn = self.lambda_parents.get(fn_name);
            }
            if (self.locals.get(name)) |alloca_val| {

                const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                    core.LLVMGetAllocatedType(alloca_val)
                else
                    self.val_type;
                const loaded = core.LLVMBuildLoad2(self.builder, slot_ty, alloca_val, "");

                if (self.current_local_type_ids) |ids| {
                    if (ids.get(name)) |slot_tid| {
                        if (self.type_store) |st| {
                            if (self.valueOptionalInner(slot_tid) != null) {

                                const use_is_bare_value = if (self.typeOfExprConcrete(&expr)) |ut| blk: {
                                    const uk = st.get(ut);
                                    break :blk uk == .prim or (uk == .enum_ and !st.isOwned(ut));
                                } else false;
                                if (use_is_bare_value and !self.suppress_valopt_unbox) {
                                    return try self.buildValoptUnbox(self.coerceToSlotType(loaded, self.val_type));
                                }
                            }
                        }
                    }
                }
                return loaded;
            } else if (self.constants.get(name)) |val| {
                return try self.compileConstRef(name, val);
            } else {
                const resolved = try self.resolveCalleeName(name);
                if (self.func_map.get(resolved)) |func_val| {

                    return try self.buildBareFnBox(func_val);
                }
                std.debug.print("Identifier '{s}' not found\n", .{name});
                return error.IdentifierNotFound;
            }
        },
        .binary => |bin| {
            if (bin.op == .assign) {
                const r_val = try self.compileExpression(bin.right.*);

                self.consumeTemporary(r_val);
                switch (bin.left.kind) {
                    .ident => |name| {

                        _ = self.narrowed_present.remove(name);

                        if (self.envCaptureIndex(name)) |idx| {
                            const addr = try self.envSlotAddr(idx);
                            const eptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_ptr_store");
                            _ = core.LLVMBuildStore(self.builder, r_val, eptr);
                            return r_val;
                        }
                        var ptr: ?types.LLVMValueRef = null;
                        var curr_fn = self.current_function_name;
                        while (curr_fn) |fn_name| {
                            const fmt_key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                            defer self.allocator.free(fmt_key);
                            if (self.captured_globals.get(fmt_key)) |global_var| {
                                ptr = global_var;
                                break;
                            }
                            curr_fn = self.lambda_parents.get(fn_name);
                        }
                        if (ptr == null) {
                            ptr = self.locals.get(name);
                        }
                        const alloca_val = ptr orelse {
                            std.debug.print("Variable '{s}' not found on assignment left\n", .{name});
                            return error.VariableNotFound;
                        };

                        var target_type: ?[]const u8 = null;
                        if (self.current_local_types) |lt| {
                            target_type = lt.get(name);
                        }

                        if (target_type) |tt| {
                            if (self.isOwnedLocal(name, tt)) {
                                const is_r_var = (bin.right.kind == .ident or bin.right.kind == .field_access or bin.right.kind == .index);
                                if (is_r_var) {
                                    try self.compileRetain(r_val);
                                }
                                const old_val = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "old_val");

                                const old_tid: ?sema_types.TypeId = if (self.current_local_type_ids) |ids| ids.get(name) else null;
                                const dest = try self.getOrCreateDestructorPreferId(tt, old_tid);
                                try self.compileRelease(old_val, dest);
                            }
                        }

                        var stored_val = r_val;
                        if (target_type) |tt| {
                            if (self.traits.contains(tt)) {
                                if (try self.resolveExpressionTypeName(bin.right)) |rt| {
                                    if (self.structs.contains(rt)) {
                                        const orig_struct = r_val;
                                        stored_val = try self.constructTraitObject(orig_struct, rt, tt);
                                        self.consumeTemporary(stored_val);

                                        const rtid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(bin.right) else null;
                                        const sdtor = try self.getOrCreateDestructorPreferId(rt, rtid);
                                        try self.compileRelease(orig_struct, sdtor);
                                    }
                                }
                            }
                        }

                        const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                            core.LLVMGetAllocatedType(alloca_val)
                        else
                            self.val_type;
                        _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(stored_val, slot_ty), alloca_val);
                        return stored_val;
                    },
                    .field_access => |fa| {
                        const obj_ptr = try self.compileExpression(fa.object.*);
                        const obj_type = try self.resolveExpressionTypeName(fa.object);
                        if (obj_type) |struct_name| {
                            if (self.isStructType(struct_name)) {
                                const base_struct = getStructBaseName(struct_name);
                                var field_type_ref = ast.TypeRef{ .ident = "i32" };
                                if (self.structs.get(base_struct)) |s| {
                                    for (s.fields) |field| {
                                        if (std.mem.eql(u8, field.name, fa.field)) {
                                            field_type_ref = field.type_name;
                                            break;
                                        }
                                    }
                                } else if (self.unions.get(base_struct)) |u| {
                                    for (u.fields) |field| {
                                        if (std.mem.eql(u8, field.name, fa.field)) {
                                            field_type_ref = field.type_name;
                                            break;
                                        }
                                    }
                                }

                                const offset = try self.getFieldOffset(struct_name, fa.field);
                                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                                const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "field_addr");

                                const llvm_field_type = self.toLLVMType(field_type_ref);
                                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");

                                const f_type_str = try self.typeRefToString(field_type_ref);

                                {
                                    const fw_base = getStructBaseName(f_type_str);
                                    if (self.structs.contains(fw_base) and self.fieldStoredInline(fw_base)) {
                                        const fsz = self.getTypeSize(field_type_ref, false);
                                        _ = try self.buildValueStructCopyInto(addr, r_val, fsz);
                                        const is_r_borrow = (bin.right.kind == .ident or bin.right.kind == .field_access or bin.right.kind == .index);
                                        if (is_r_borrow) {
                                            try self.retainValueStructOwnedFields(addr, f_type_str);
                                        }
                                        return r_val;
                                    }
                                }

                                if (self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                                    const is_r_var = (bin.right.kind == .ident or bin.right.kind == .field_access or bin.right.kind == .index);
                                    if (is_r_var) {
                                        try self.compileRetain(r_val);
                                    }
                                    const old_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "old_field_val");
                                    const casted_old = self.castToValType(old_field_val, field_type_ref);

                                    const f_tid = self.tidForTypeRef(field_type_ref);
                                    const dest = try self.getOrCreateDestructorPreferId(f_type_str, f_tid);
                                    try self.compileRelease(casted_old, dest);
                                }

                                var stored_r = r_val;
                                if (field_type_ref == .ident and self.traits.contains(field_type_ref.ident)) {
                                    if (try self.resolveExpressionTypeName(bin.right)) |rt| {
                                        if (self.structs.contains(rt)) {
                                            const orig_struct = r_val;
                                            stored_r = try self.constructTraitObject(orig_struct, rt, field_type_ref.ident);
                                            self.consumeTemporary(stored_r);

                                            const rtid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(bin.right) else null;
                                            const sdtor = try self.getOrCreateDestructorPreferId(rt, rtid);
                                            try self.compileRelease(orig_struct, sdtor);
                                        }
                                    }
                                }

                                if (self.valoptTypeRefIsValue(field_type_ref) and
                                    !LlvmCompiler.isUndefinedLiteralExpr(bin.right) and
                                    !self.exprYieldsValoptBox(bin.right))
                                {
                                    stored_r = try self.buildValoptBox(self.coerceToSlotType(stored_r, self.val_type));
                                }

                                const casted_r_val = self.castFromValType(stored_r, llvm_field_type);
                                _ = core.LLVMBuildStore(self.builder, casted_r_val, ptr);
                                return stored_r;
                            }
                        }
                        return error.FieldAccessObjectNotStruct;
                    },
                    .index => |idx| {
                        const base = try self.compileExpression(idx.object.*);
                        try self.guardOptionalDeref(idx.object, base, idx.span);
                        const off = try self.compileExpression(idx.index.*);
                        const is_string = self.isStringExpr(idx.object);
                        if (is_string) {
                            const saddr = core.LLVMBuildAdd(self.builder, base, off, "idx_store_addr");
                            const sptr = core.LLVMBuildIntToPtr(self.builder, saddr, self.ptr_type, "idx_store_ptr");
                            const b = core.LLVMBuildTrunc(self.builder, self.coerceToSlotType(r_val, self.val_type), self.i8_type, "idx_byte");
                            _ = core.LLVMBuildStore(self.builder, b, sptr);
                            return r_val;
                        }
                        const base_ptr = self.arrayBasePtr(base);
                        var st_idxs = [_]types.LLVMValueRef{off};
                        if (self.arrayElemFloatLLVM(idx.object)) |ety| {
                            const ep = core.LLVMBuildInBoundsGEP2(self.builder, ety, base_ptr, &st_idxs, 1, "arr_store_gepf");
                            _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(r_val, ety), ep);
                            return r_val;
                        }
                        const elem_ptr = core.LLVMBuildInBoundsGEP2(self.builder, self.val_type, base_ptr, &st_idxs, 1, "arr_store_gep");
                        _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(r_val, self.val_type), elem_ptr);
                        return r_val;
                    },
                    else => {
                        std.debug.print("Unsupported assignment target: {s}\n", .{@tagName(bin.left.kind)});
                        return error.UnsupportedAssignmentTarget;
                    },
                }
            }

            const left_type = try self.resolveExpressionTypeName(bin.left);
            const right_type = try self.resolveExpressionTypeName(bin.right);

            const is_string_concat = self.isStringExpr(bin.left) or self.isStringExpr(bin.right);
            const is_string_comparison = blk: {
                if (bin.left.kind == .literal and (bin.left.kind.literal == .null or bin.left.kind.literal == .undefined)) break :blk false;
                if (bin.right.kind == .literal and (bin.right.kind.literal == .null or bin.right.kind.literal == .undefined)) break :blk false;
                break :blk self.isStringExpr(bin.left) or self.isStringExpr(bin.right);
            };
            const is_float_op = self.isFloatExpr(bin.left) or self.isFloatExpr(bin.right);

            var l_val = try self.compileExpression(bin.left.*);
            var r_val = try self.compileExpression(bin.right.*);

            {
                const l_is_undef = bin.left.kind == .literal and (bin.left.kind.literal == .undefined or bin.left.kind.literal == .null);
                const r_is_undef = bin.right.kind == .literal and (bin.right.kind.literal == .undefined or bin.right.kind.literal == .null);
                if (!r_is_undef and self.exprYieldsValoptBox(bin.left)) {
                    l_val = try self.buildValoptUnbox(self.coerceToSlotType(l_val, self.val_type));
                }
                if (!l_is_undef and self.exprYieldsValoptBox(bin.right)) {
                    r_val = try self.buildValoptUnbox(self.coerceToSlotType(r_val, self.val_type));
                }
            }

            {
                const l_is_dec = self.isDecimalExpr(bin.left);
                const r_is_dec = self.isDecimalExpr(bin.right);

                const other_is_null_lit =
                    (bin.left.kind == .literal and (bin.left.kind.literal == .null or bin.left.kind.literal == .undefined)) or
                    (bin.right.kind == .literal and (bin.right.kind.literal == .null or bin.right.kind.literal == .undefined));
                if ((l_is_dec or r_is_dec) and !other_is_null_lit) {
                    if (!(l_is_dec and r_is_dec)) {
                        std.debug.print("decimal arithmetic requires BOTH operands to be `decimal` (Stage 2 has no implicit conversion): use an `m` literal, e.g. `2m`\n", .{});
                        return error.UnsupportedBinaryOp;
                    }
                    const dec_fn_name: ?[]const u8 = switch (bin.op) {
                        .add => "nova_decimal_add",
                        .sub => "nova_decimal_sub",
                        .mul => "nova_decimal_mul",
                        .div => "nova_decimal_div",
                        .mod => "nova_decimal_mod",
                        .eq, .ne, .lt, .gt, .le, .ge => "nova_decimal_cmp",
                        else => null,
                    };
                    const fname = dec_fn_name orelse {
                        std.debug.print("Binary operator not supported for decimal: {s}\n", .{@tagName(bin.op)});
                        return error.UnsupportedBinaryOp;
                    };
                    const dec_fn = self.func_map.get(fname).?;
                    const fn_t = core.LLVMGlobalGetValueType(dec_fn);
                    var dargs = [_]types.LLVMValueRef{ l_val, r_val };
                    const call = core.LLVMBuildCall2(self.builder, fn_t, dec_fn, &dargs, 2, "dec_op");
                    switch (bin.op) {
                        .eq, .ne, .lt, .gt, .le, .ge => {

                            const zero = core.LLVMConstInt(self.val_type, 0, 0);
                            const pred = switch (bin.op) {
                                .eq => types.LLVMIntPredicate.LLVMIntEQ,
                                .ne => types.LLVMIntPredicate.LLVMIntNE,
                                .lt => types.LLVMIntPredicate.LLVMIntSLT,
                                .gt => types.LLVMIntPredicate.LLVMIntSGT,
                                .le => types.LLVMIntPredicate.LLVMIntSLE,
                                .ge => types.LLVMIntPredicate.LLVMIntSGE,
                                else => unreachable,
                            };
                            const cmp = core.LLVMBuildICmp(self.builder, pred, call, zero, "dec_cmp");
                            return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "dec_cmp_ext");
                        },
                        else => return call,
                    }
                }
            }

            if (is_float_op and !is_string_concat) {

                l_val = core.LLVMBuildBitCast(self.builder, l_val, core.LLVMDoubleType(), "l_double");
                r_val = core.LLVMBuildBitCast(self.builder, r_val, core.LLVMDoubleType(), "r_double");
                switch (bin.op) {
                    .add => return core.LLVMBuildFAdd(self.builder, l_val, r_val, "faddtmp"),
                    .sub => return core.LLVMBuildFSub(self.builder, l_val, r_val, "fsubtmp"),
                    .mul => return core.LLVMBuildFMul(self.builder, l_val, r_val, "fmultmp"),
                    .div => return core.LLVMBuildFDiv(self.builder, l_val, r_val, "fdivtmp"),
                    .mod => return core.LLVMBuildFRem(self.builder, l_val, r_val, "fremtmp"),
                    .eq, .ne, .lt, .gt, .le, .ge => {
                        const pred = switch (bin.op) {
                            .eq => types.LLVMRealPredicate.LLVMRealOEQ,
                            .ne => types.LLVMRealPredicate.LLVMRealUNE,
                            .lt => types.LLVMRealPredicate.LLVMRealOLT,
                            .gt => types.LLVMRealPredicate.LLVMRealOGT,
                            .le => types.LLVMRealPredicate.LLVMRealOLE,
                            .ge => types.LLVMRealPredicate.LLVMRealOGE,
                            else => unreachable,
                        };
                        const cmp = core.LLVMBuildFCmp(self.builder, pred, l_val, r_val, "fcmptmp");
                        return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                    },
                    else => {
                        std.debug.print("Binary operator not supported for floats: {s}\n", .{@tagName(bin.op)});
                        return error.UnsupportedFloatBinaryOp;
                    },
                }
            }

            const iop = intOpKind(left_type, right_type);

            switch (bin.op) {
                .add => {

                    var l_minted = false;
                    var r_minted = false;
                    if (is_string_concat) {

                        const left_is_str = if (left_type) |lt| std.mem.eql(u8, lt, "string") else false;
                        if (!left_is_str) {
                            l_val = try self.numToString(l_val, left_type);
                            l_minted = true;
                        }
                        const right_is_str = if (right_type) |rt| std.mem.eql(u8, rt, "string") else false;
                        if (!right_is_str) {
                            r_val = try self.numToString(r_val, right_type);
                            r_minted = true;
                        }
                    }
                    if (is_string_concat) {
                        var concat_fn = self.func_map.get("string_concat");
                        if (concat_fn == null) {
                            var iter = self.func_map.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (std.mem.endsWith(u8, key, "_string_concat") or std.mem.eql(u8, key, "string_concat")) {
                                    concat_fn = entry.value_ptr.*;
                                    break;
                                }
                            }
                        }
                        const final_concat_fn = concat_fn orelse {
                            std.debug.print("Error: string_concat function not found in func_map\n", .{});
                            return error.StringConcatFnNotFound;
                        };
                        var args = [_]types.LLVMValueRef{ l_val, r_val };
                        const fn_t = core.LLVMGlobalGetValueType(final_concat_fn);
                        const concat_res = core.LLVMBuildCall2(self.builder, fn_t, final_concat_fn, &args, 2, "concat_tmp");

                        if (l_minted) try self.compileRelease(l_val, null);
                        if (r_minted) try self.compileRelease(r_val, null);
                        return concat_res;
                    }

                    const res = core.LLVMBuildAdd(self.builder, l_val, r_val, "addtmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .sub => {
                    const res = core.LLVMBuildSub(self.builder, l_val, r_val, "subtmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .mul => {
                    const res = core.LLVMBuildMul(self.builder, l_val, r_val, "multmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .div => {

                    const unsigned = if (iop) |k| !k.signed else false;
                    const width: u32 = if (iop) |k| k.width else 64;
                    self.emitIntDivGuard(l_val, r_val, !unsigned, width, "integer division by zero", "integer division overflow (INT_MIN / -1)");
                    return if (unsigned)
                        core.LLVMBuildUDiv(self.builder, l_val, r_val, "udivtmp")
                    else
                        core.LLVMBuildSDiv(self.builder, l_val, r_val, "divtmp");
                },
                .mod => {
                    const unsigned = if (iop) |k| !k.signed else false;
                    const width: u32 = if (iop) |k| k.width else 64;
                    self.emitIntDivGuard(l_val, r_val, !unsigned, width, "integer modulo by zero", "integer modulo overflow (INT_MIN % -1)");
                    return if (unsigned)
                        core.LLVMBuildURem(self.builder, l_val, r_val, "uremtmp")
                    else
                        core.LLVMBuildSRem(self.builder, l_val, r_val, "modtmp");
                },
                .shl => {
                    const res = core.LLVMBuildShl(self.builder, l_val, r_val, "shltmp");
                    return if (iop) |k| self.canonicalizeInt(res, k.width, k.signed) else res;
                },
                .shr => {

                    const unsigned = if (iop) |k| !k.signed else false;
                    if (unsigned) {
                        if (iop) |k| {
                            const lc = self.canonicalizeInt(l_val, k.width, false);
                            return core.LLVMBuildLShr(self.builder, lc, r_val, "lshrtmp");
                        }
                        return core.LLVMBuildLShr(self.builder, l_val, r_val, "lshrtmp");
                    }
                    return core.LLVMBuildAShr(self.builder, l_val, r_val, "shrtmp");
                },
                .And, .bit_and => return core.LLVMBuildAnd(self.builder, l_val, r_val, "andtmp"),
                .Or, .bit_or => return core.LLVMBuildOr(self.builder, l_val, r_val, "ortmp"),
                .bit_xor => return core.LLVMBuildXor(self.builder, l_val, r_val, "xortmp"),
                .eq, .ne, .lt, .gt, .le, .ge => {
                    if (bin.op == .eq or bin.op == .ne) {
                        if (self.payloadEnumBoxWords(left_type, right_type)) |nwords| {
                            var acc = core.LLVMConstInt(self.i1_type, 1, 0);
                            var i: u32 = 0;
                            while (i < nwords) : (i += 1) {
                                const off = core.LLVMConstInt(self.val_type, @as(u64, i) * 8, 0);
                                const la = core.LLVMBuildAdd(self.builder, l_val, off, "eeq_la");
                                const ra = core.LLVMBuildAdd(self.builder, r_val, off, "eeq_ra");
                                const lp = core.LLVMBuildIntToPtr(self.builder, la, core.LLVMPointerType(self.val_type, 0), "eeq_lp");
                                const rp = core.LLVMBuildIntToPtr(self.builder, ra, core.LLVMPointerType(self.val_type, 0), "eeq_rp");
                                const lw = core.LLVMBuildLoad2(self.builder, self.val_type, lp, "eeq_lw");
                                const rw = core.LLVMBuildLoad2(self.builder, self.val_type, rp, "eeq_rw");
                                const weq = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, lw, rw, "eeq_w");
                                acc = core.LLVMBuildAnd(self.builder, acc, weq, "eeq_acc");
                            }
                            const same = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, l_val, r_val, "eeq_same");
                            var res = core.LLVMBuildOr(self.builder, acc, same, "eeq_eq");
                            if (bin.op == .ne) res = core.LLVMBuildXor(self.builder, res, core.LLVMConstInt(self.i1_type, 1, 0), "eeq_ne");
                            return core.LLVMBuildZExt(self.builder, res, self.val_type, "eeq_ext");
                        }
                    }
                    if (is_string_comparison and (bin.op == .eq or bin.op == .ne)) {
                        var eql_fn = self.func_map.get("string_eql");
                        if (eql_fn == null) {
                            var iter = self.func_map.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (std.mem.endsWith(u8, key, "_string_eql") or std.mem.eql(u8, key, "string_eql")) {
                                    eql_fn = entry.value_ptr.*;
                                    break;
                                }
                            }
                        }
                        const final_eql_fn = eql_fn orelse {
                            std.debug.print("Error: string_eql function not found in func_map\n", .{});
                            return error.StringEqlFnNotFound;
                        };
                        var args = [_]types.LLVMValueRef{ l_val, r_val };
                        const fn_t = core.LLVMGlobalGetValueType(final_eql_fn);
                        const eql_val = core.LLVMBuildCall2(self.builder, fn_t, final_eql_fn, &args, 2, "eql_tmp");
                        if (bin.op == .eq) {
                            return eql_val;
                        } else {
                            const zero = core.LLVMConstInt(self.val_type, 0, 0);
                            const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, eql_val, zero, "not_eql");
                            return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "not_eql_ext");
                        }
                    }

                    const unsigned = if (iop) |k| !k.signed else false;
                    const pred = switch (bin.op) {
                        .eq => types.LLVMIntPredicate.LLVMIntEQ,
                        .ne => types.LLVMIntPredicate.LLVMIntNE,
                        .lt => if (unsigned) types.LLVMIntPredicate.LLVMIntULT else types.LLVMIntPredicate.LLVMIntSLT,
                        .gt => if (unsigned) types.LLVMIntPredicate.LLVMIntUGT else types.LLVMIntPredicate.LLVMIntSGT,
                        .le => if (unsigned) types.LLVMIntPredicate.LLVMIntULE else types.LLVMIntPredicate.LLVMIntSLE,
                        .ge => if (unsigned) types.LLVMIntPredicate.LLVMIntUGE else types.LLVMIntPredicate.LLVMIntSGE,
                        else => unreachable,
                    };

                    if (unsigned) {
                        if (iop) |k| {
                            l_val = self.canonicalizeInt(l_val, k.width, false);
                            r_val = self.canonicalizeInt(r_val, k.width, false);
                        }
                    }
                    const l_t = core.LLVMTypeOf(l_val);
                    const r_t = core.LLVMTypeOf(r_val);
                    const l_kind = core.LLVMGetTypeKind(l_t);
                    const r_kind = core.LLVMGetTypeKind(r_t);
                    if (l_kind == types.LLVMTypeKind.LLVMIntegerTypeKind and r_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {
                        const l_width = core.LLVMGetIntTypeWidth(l_t);
                        const r_width = core.LLVMGetIntTypeWidth(r_t);
                        if (l_width < r_width) {
                            l_val = core.LLVMBuildSExt(self.builder, l_val, r_t, "l_ext");
                        } else if (r_width < l_width) {
                            r_val = core.LLVMBuildSExt(self.builder, r_val, l_t, "r_ext");
                        }
                    }
                    const cmp = core.LLVMBuildICmp(self.builder, pred, l_val, r_val, "cmptmp");
                    return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                },
                else => {
                    std.debug.print("Binary operator not supported: {s}\n", .{@tagName(bin.op)});
                    return error.UnsupportedBinaryOp;
                },
            }
        },
        .unary => |uni| {
            const operand_val = try self.compileExpression(uni.operand.*);
            const operand_type = try self.resolveExpressionTypeName(uni.operand);
            const is_float_op = blk: {
                if (operand_type) |ot| {
                    if (std.mem.eql(u8, ot, "f32") or std.mem.eql(u8, ot, "float") or
                        std.mem.eql(u8, ot, "f64") or std.mem.eql(u8, ot, "double")) break :blk true;
                }
                break :blk false;
            };

            switch (uni.op) {
                .neg => {
                    if (is_float_op) {

                        const operand_double = core.LLVMBuildBitCast(self.builder, operand_val, core.LLVMDoubleType(), "neg_double");
                        return core.LLVMBuildFNeg(self.builder, operand_double, "fnegtmp");
                    }
                    const zero = core.LLVMConstInt(self.val_type, 0, 0);
                    return core.LLVMBuildSub(self.builder, zero, operand_val, "negtmp");
                },
                .not => {
                    const zero = core.LLVMConstInt(self.val_type, 0, 0);
                    const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, operand_val, zero, "nottmp");
                    return core.LLVMBuildZExt(self.builder, cmp, self.val_type, "zexttmp");
                },
                .bit_not => {

                    return core.LLVMBuildNot(self.builder, operand_val, "bitnottmp");
                },
            }
        },
        .if_expr => |ie| {
            const cond_val = try self.compileExpression(ie.condition.*);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "ifcond");

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const then_bb = core.LLVMAppendBasicBlock(current_fn, "then");
            const else_bb = core.LLVMAppendBasicBlock(current_fn, "else");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "ifcont");

            _ = core.LLVMBuildCondBr(self.builder, cond_i1, then_bb, else_bb);

            const if_result_trait: ?[]const u8 = blk: {
                const rt = (self.resolveExpressionTypeName(&expr) catch null) orelse break :blk null;
                break :blk if (self.traits.contains(rt)) rt else null;
            };

            core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
            var then_raw = try self.compileExpression(ie.then_branch.*);
            const then_widened = try self.widenBranchToTrait(ie.then_branch, &then_raw, if_result_trait);
            if (!then_widened and self.isOwnedExpr(ie.then_branch)) try self.takeOwnedElement(ie.then_branch.kind, then_raw);
            const then_val = self.coerceToSlotType(then_raw, self.val_type);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const then_bb_end = core.LLVMGetInsertBlock(self.builder);

            core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
            var else_raw = try self.compileExpression(ie.else_branch.*);
            const else_widened = try self.widenBranchToTrait(ie.else_branch, &else_raw, if_result_trait);
            if (!else_widened and self.isOwnedExpr(ie.else_branch)) try self.takeOwnedElement(ie.else_branch.kind, else_raw);
            const else_val = self.coerceToSlotType(else_raw, self.val_type);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const else_bb_end = core.LLVMGetInsertBlock(self.builder);

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

            const phi = core.LLVMBuildPhi(self.builder, self.val_type, "ifphi");
            var incoming_vals = [_]types.LLVMValueRef{ then_val, else_val };
            var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_bb_end, else_bb_end };
            core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

            return phi;
        },
        .call => |call| {

            if (call.callee.kind == .optional_chaining) {
                if (try self.compileOptionalMethodCall(call, &expr)) |v| return v;
            }

            if (call.callee.kind == .field_access) {
                const fa = call.callee.kind.field_access;
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "simd")) {
                    return try self.compileSimdCall(fa.field, call.args);
                }
                if (fa.object.kind == .ident) {
                } else {
                }
                const is_console = fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "console");
                const is_log = std.mem.eql(u8, fa.field, "log");
                const is_info = std.mem.eql(u8, fa.field, "info");
                const is_debug = std.mem.eql(u8, fa.field, "debug");
                const is_err = std.mem.eql(u8, fa.field, "err");
                if (is_console and (is_log or is_info or is_debug or is_err)) {
                    if (call.args.len == 1) {

                        const arg = call.args[0];
                        const type_name = try self.resolveExpressionTypeName(&call.args[0]);
                        if (type_name) |t| {
                            if (std.mem.eql(u8, t, "string")) {
                                const str_ptr = try self.compileExpression(arg);
                                if (self.is_wasm) {

                                    const offset = core.LLVMConstInt(self.val_type, 4, 0);
                                    const addr_sub = core.LLVMBuildSub(self.builder, str_ptr, offset, "len_addr");
                                    const len_ptr = core.LLVMBuildIntToPtr(self.builder, addr_sub, self.ptr_type, "len_ptr");
                                    const len_val = core.LLVMBuildLoad2(self.builder, self.val_type, len_ptr, "len_val");

                                    var args = [_]types.LLVMValueRef{ str_ptr, len_val };
                                    const fn_t = core.LLVMGlobalGetValueType(self.log_fn.?);
                                    _ = core.LLVMBuildCall2(self.builder, fn_t, self.log_fn.?, &args, 2, "");
                                } else {
                                    const ptr = core.LLVMBuildIntToPtr(self.builder, str_ptr, self.ptr_type, "puts_ptr");
                                    var args = [_]types.LLVMValueRef{ptr};
                                    const log_fn_to_call = if (is_info)
                                        self.nova_log_info_fn.?
                                    else if (is_debug)
                                        self.nova_log_debug_fn.?
                                    else if (is_err)
                                        self.nova_log_err_fn.?
                                    else
                                        self.nova_log_string_fn.?;
                                    const fn_t = core.LLVMGlobalGetValueType(log_fn_to_call);
                                    _ = core.LLVMBuildCall2(self.builder, fn_t, log_fn_to_call, &args, 1, "");
                                }
                            } else if (std.mem.eql(u8, t, "bool")) {
                                const val = try self.compileExpression(arg);
                                const helper = self.func_map.get("__log_bool") orelse return error.HelperNotFound;
                                var args = [_]types.LLVMValueRef{val};
                                const fn_t = core.LLVMGlobalGetValueType(helper);
                                _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                            } else {
                                const val = try self.compileExpression(arg);
                                const helper = self.func_map.get("__log_i32") orelse return error.HelperNotFound;
                                var args = [_]types.LLVMValueRef{val};
                                const fn_t = core.LLVMGlobalGetValueType(helper);
                                _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                            }
                        } else {
                            const val = try self.compileExpression(arg);
                            const helper = self.func_map.get("__log_i32") orelse return error.HelperNotFound;
                            var args = [_]types.LLVMValueRef{val};
                            const fn_t = core.LLVMGlobalGetValueType(helper);
                            _ = core.LLVMBuildCall2(self.builder, fn_t, helper, &args, 1, "");
                        }
                    }
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }

                if (fa.object.kind == .ident and std.mem.endsWith(u8, fa.object.kind.ident, "protocol") and std.mem.eql(u8, fa.field, "callDecoder")) {
                    const decoder_ptr = try self.compileExpression(call.args[0]);
                    const fixed_data = try self.compileExpression(call.args[1]);
                    const heap_data = try self.compileExpression(call.args[2]);
                    const col_names = try self.compileExpression(call.args[3]);
                    const col_types = try self.compileExpression(call.args[4]);

                    var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
                    const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
                    const fn_ptr = core.LLVMBuildIntToPtr(self.builder, decoder_ptr, self.ptr_type, "fn_ptr");

                    var args = [_]types.LLVMValueRef{ fixed_data, heap_data, col_names, col_types };
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, 4, "call_decoder_res");
                }

                if (try self.resolveExpressionTypeName(fa.object)) |obj_t| {
                    if (std.mem.startsWith(u8, obj_t, "Storage<")) {
                        const elem = obj_t["Storage<".len .. obj_t.len - 1];
                        const base = try self.compileExpression(fa.object.*);
                        const inline_vs = self.isValueStructName(elem);
                        const slot_w: u64 = if (inline_vs) @max(self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(elem) }, false), 1) else 8;
                        const width = core.LLVMConstInt(self.val_type, slot_w, 0);

                        if (std.mem.eql(u8, fa.field, "get")) {
                            const idx = try self.compileExpression(call.args[0]);
                            const off = core.LLVMBuildMul(self.builder, idx, width, "stg_g_off");
                            const addr = core.LLVMBuildAdd(self.builder, base, off, "stg_g_addr");
                            if (inline_vs) return addr;
                            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "stg_g_ptr");
                            const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "stg_g");

                            if (self.isOwnedStorageElem(fa.object, elem)) {
                                try self.compileRetain(loaded);
                            }
                            return loaded;
                        }
                        if (std.mem.eql(u8, fa.field, "set")) {
                            const idx = try self.compileExpression(call.args[0]);
                            const val = try self.compileExpression(call.args[1]);
                            const off = core.LLVMBuildMul(self.builder, idx, width, "stg_s_off");
                            const addr = core.LLVMBuildAdd(self.builder, base, off, "stg_s_addr");
                            if (inline_vs) {
                                _ = try self.buildValueStructCopyInto(addr, val, @intCast(slot_w));
                                try self.retainValueStructOwnedFields(addr, elem);
                                return core.LLVMConstInt(self.val_type, 0, 0);
                            }
                            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "stg_s_ptr");

                            if (self.isOwnedStorageElem(fa.object, elem)) {
                                try self.compileRetain(val);
                                const old = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "stg_s_old");
                                const elem_dest = try self.getOrCreateDestructor(elem);
                                try self.compileRelease(old, elem_dest);
                            }
                            _ = core.LLVMBuildStore(self.builder, val, ptr);
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                    }
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "decimal")) {
                    if (std.mem.eql(u8, fa.field, "fromInt")) {
                        const n = try self.compileExpression(call.args[0]);
                        const fn_val = self.func_map.get("nova_decimal_from_int").?;
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);
                        var args = [_]types.LLVMValueRef{n};

                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, &args, 1, "dec_from_int");
                    }
                    if (std.mem.eql(u8, fa.field, "toInt")) {
                        const d = try self.compileExpression(call.args[0]);
                        const fn_val = self.func_map.get("nova_decimal_to_int").?;
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);
                        var args = [_]types.LLVMValueRef{d};
                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, &args, 1, "dec_to_int");
                    }

                    if (std.mem.eql(u8, fa.field, "fromString")) {
                        const s = try self.compileExpression(call.args[0]);

                        const four = core.LLVMConstInt(self.val_type, 4, 0);
                        const len_addr = core.LLVMBuildSub(self.builder, s, four, "dec_len_addr");
                        const i32ptr = core.LLVMPointerType(self.i32_type, 0);
                        const len_ptr = core.LLVMBuildIntToPtr(self.builder, len_addr, i32ptr, "dec_len_ptr");
                        const len_i32 = core.LLVMBuildLoad2(self.builder, self.i32_type, len_ptr, "dec_len_i32");
                        const len = core.LLVMBuildZExt(self.builder, len_i32, self.val_type, "dec_len");
                        const s_ptr = core.LLVMBuildIntToPtr(self.builder, s, self.ptr_type, "dec_fromstr_ptr");
                        const from_fn = self.func_map.get("nova_decimal_from_string_n").?;
                        const from_t = core.LLVMGlobalGetValueType(from_fn);
                        var args = [_]types.LLVMValueRef{ s_ptr, len };
                        return core.LLVMBuildCall2(self.builder, from_t, from_fn, &args, 2, "dec_from_string_n");
                    }
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "mem") and
                    std.mem.eql(u8, fa.field, "xorBytes"))
                {
                    const dst = try self.compileExpression(call.args[0]);
                    const a = try self.compileExpression(call.args[1]);
                    const b = try self.compileExpression(call.args[2]);
                    const len = try self.compileExpression(call.args[3]);
                    const xor_fn = if (self.func_map.get("nova_mem_xor")) |f| f else blk: {
                        var arg_types = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
                        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 4, 0);
                        const f = core.LLVMAddFunction(self.module, "nova_mem_xor", fn_type);
                        try self.func_map.put("nova_mem_xor", f);
                        break :blk f;
                    };
                    const fn_t = core.LLVMGlobalGetValueType(xor_fn);
                    var args = [_]types.LLVMValueRef{ dst, a, b, len };
                    _ = core.LLVMBuildCall2(self.builder, fn_t, xor_fn, &args, 4, "");
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes")) {
                    if (std.mem.eql(u8, fa.field, "alloc")) {
                        const size = try self.compileExpression(call.args[0]);
                        return try self.compileAlloc(size);
                    }
                    if (std.mem.eql(u8, fa.field, "alloc_persistent")) {
                        const size = try self.compileExpression(call.args[0]);
                        return try self.compileAllocPersistent(size);
                    }
                    if (std.mem.eql(u8, fa.field, "alloc_persistent_nz")) {
                        const size = try self.compileExpression(call.args[0]);
                        const nz_fn = if (self.func_map.get("nova_bytes_alloc_persistent_nz")) |f| f else blk: {
                            var arg_types = [_]types.LLVMTypeRef{self.val_type};
                            const fn_type = core.LLVMFunctionType(self.val_type, &arg_types, 1, 0);
                            const f = core.LLVMAddFunction(self.module, "nova_bytes_alloc_persistent_nz", fn_type);
                            try self.func_map.put("nova_bytes_alloc_persistent_nz", f);
                            break :blk f;
                        };
                        const fn_t = core.LLVMGlobalGetValueType(nz_fn);
                        var args = [_]types.LLVMValueRef{size};
                        return core.LLVMBuildCall2(self.builder, fn_t, nz_fn, &args, 1, "alloc_persistent_nz_tmp");
                    }
                    if (std.mem.eql(u8, fa.field, "free")) {
                        const ptr = try self.compileExpression(call.args[0]);
                        return try self.compileFree(ptr);
                    }
                    if (std.mem.eql(u8, fa.field, "arenaMark")) {
                        const f = if (self.func_map.get("nova_arena_mark")) |g| g else blk: {
                            const t = core.LLVMFunctionType(self.val_type, &[_]types.LLVMTypeRef{}, 0, 0);
                            const g = core.LLVMAddFunction(self.module, "nova_arena_mark", t);
                            try self.func_map.put("nova_arena_mark", g);
                            break :blk g;
                        };
                        const ft = core.LLVMGlobalGetValueType(f);
                        var noargs = [_]types.LLVMValueRef{};
                        return core.LLVMBuildCall2(self.builder, ft, f, &noargs, 0, "arena_mark");
                    }
                    if (std.mem.eql(u8, fa.field, "arenaReset")) {
                        const mark = try self.compileExpression(call.args[0]);
                        const f = if (self.func_map.get("nova_arena_reset")) |g| g else blk: {
                            var a = [_]types.LLVMTypeRef{self.val_type};
                            const t = core.LLVMFunctionType(self.void_type, &a, 1, 0);
                            const g = core.LLVMAddFunction(self.module, "nova_arena_reset", t);
                            try self.func_map.put("nova_arena_reset", g);
                            break :blk g;
                        };
                        const ft = core.LLVMGlobalGetValueType(f);
                        var args = [_]types.LLVMValueRef{mark};
                        _ = core.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "copy")) {
                        const dst = try self.compileExpression(call.args[0]);
                        const src = try self.compileExpression(call.args[1]);
                        const len = try self.compileExpression(call.args[2]);
                        const copy_fn = if (self.func_map.get("nova_bytes_copy")) |f| f else blk: {
                            var arg_types = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type };
                            const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 3, 0);
                            const f = core.LLVMAddFunction(self.module, "nova_bytes_copy", fn_type);
                            try self.func_map.put("nova_bytes_copy", f);
                            break :blk f;
                        };
                        const fn_t = core.LLVMGlobalGetValueType(copy_fn);
                        var args = [_]types.LLVMValueRef{ dst, src, len };
                        _ = core.LLVMBuildCall2(self.builder, fn_t, copy_fn, &args, 3, "");
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "write_byte")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const byte_val_raw = try self.compileExpression(call.args[2]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "write_ptr");
                        const byte_val = core.LLVMBuildTrunc(self.builder, byte_val_raw, self.i8_type, "byte_val");
                        _ = core.LLVMBuildStore(self.builder, byte_val, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "write_i32")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const i32_val_raw = try self.compileExpression(call.args[2]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "write_ptr");
                        const i32_val = core.LLVMBuildTrunc(self.builder, i32_val_raw, self.i32_type, "i32_val");
                        _ = core.LLVMBuildStore(self.builder, i32_val, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "write_u16")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const raw = try self.compileExpression(call.args[2]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const p16 = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(core.LLVMInt16Type(), 0), "write_ptr");
                        const v16 = core.LLVMBuildTrunc(self.builder, raw, core.LLVMInt16Type(), "u16_val");
                        _ = core.LLVMBuildStore(self.builder, v16, p16);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_u16")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const p16 = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(core.LLVMInt16Type(), 0), "read_ptr");
                        const v16 = core.LLVMBuildLoad2(self.builder, core.LLVMInt16Type(), p16, "u16_val");
                        return core.LLVMBuildZExt(self.builder, v16, self.val_type, "u16_ext");
                    }
                    if (std.mem.eql(u8, fa.field, "read_i16")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const p16 = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(core.LLVMInt16Type(), 0), "read_ptr");
                        const v16 = core.LLVMBuildLoad2(self.builder, core.LLVMInt16Type(), p16, "i16_val");
                        return core.LLVMBuildSExt(self.builder, v16, self.val_type, "i16_ext");
                    }
                    if (std.mem.eql(u8, fa.field, "ptr_size")) {
                        return core.LLVMConstInt(self.val_type, 8, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_ptr")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "read_ptr");
                        return core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "ptr_val");
                    }
                    if (std.mem.eql(u8, fa.field, "write_ptr")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);
                        const val_to_write = try self.compileExpression(call.args[2]);
                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "write_ptr");
                        _ = core.LLVMBuildStore(self.builder, val_to_write, ptr);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_byte")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "read_ptr");
                        const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
                        return core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "byte_val_ext");
                    }
                    if (std.mem.eql(u8, fa.field, "read_i32")) {
                        const ptr_val = try self.compileExpression(call.args[0]);
                        const offset_val = try self.compileExpression(call.args[1]);

                        const addr = core.LLVMBuildAdd(self.builder, ptr_val, offset_val, "addr");
                        const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "read_ptr");
                        const i32_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "i32_val");
                        return core.LLVMBuildZExt(self.builder, i32_val, self.val_type, "i32_val_ext");
                    }

                    if (std.mem.eql(u8, fa.field, "write_decimal")) {
                        const dst = try self.compileExpression(call.args[0]);
                        const offset = try self.compileExpression(call.args[1]);
                        const dec = try self.compileExpression(call.args[2]);
                        const i64ptr = core.LLVMPointerType(self.val_type, 0);
                        const eight = core.LLVMConstInt(self.val_type, 8, 0);
                        const dst_addr = core.LLVMBuildAdd(self.builder, dst, offset, "dec_dst_addr");
                        const s0 = core.LLVMBuildIntToPtr(self.builder, dec, i64ptr, "dec_s0");
                        const d0 = core.LLVMBuildIntToPtr(self.builder, dst_addr, i64ptr, "dec_d0");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s0, "dw0"), d0);
                        const s1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dec, eight, "s1a"), i64ptr, "dec_s1");
                        const d1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dst_addr, eight, "d1a"), i64ptr, "dec_d1");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s1, "dw1"), d1);
                        return core.LLVMConstInt(self.val_type, 0, 0);
                    }
                    if (std.mem.eql(u8, fa.field, "read_decimal")) {
                        const src = try self.compileExpression(call.args[0]);
                        const offset = try self.compileExpression(call.args[1]);
                        const dec = try self.compileAlloc(core.LLVMConstInt(self.val_type, 16, 0));
                        const i64ptr = core.LLVMPointerType(self.val_type, 0);
                        const eight = core.LLVMConstInt(self.val_type, 8, 0);
                        const src_addr = core.LLVMBuildAdd(self.builder, src, offset, "dec_src_addr");
                        const s0 = core.LLVMBuildIntToPtr(self.builder, src_addr, i64ptr, "dec_rs0");
                        const d0 = core.LLVMBuildIntToPtr(self.builder, dec, i64ptr, "dec_rd0");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s0, "rw0"), d0);
                        const s1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, src_addr, eight, "rs1a"), i64ptr, "dec_rs1");
                        const d1 = core.LLVMBuildIntToPtr(self.builder, core.LLVMBuildAdd(self.builder, dec, eight, "rd1a"), i64ptr, "dec_rd1");
                        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildLoad2(self.builder, self.val_type, s1, "rw1"), d1);
                        return dec;
                    }
                    if (std.mem.eql(u8, fa.field, "read_string")) {
                        const fn_val = self.func_map.get("__read_string") orelse {
                            std.debug.print("Helper function '__read_string' not found\n", .{});
                            return error.HelperNotFound;
                        };
                        const fn_t = core.LLVMGlobalGetValueType(fn_val);

                        const args = try self.allocator.alloc(types.LLVMValueRef, 2);
                        defer self.allocator.free(args);
                        args[0] = try self.compileExpression(call.args[0]);
                        args[1] = try self.compileExpression(call.args[1]);

                        return core.LLVMBuildCall2(self.builder, fn_t, fn_val, args.ptr, 2, "read_string_call");
                    }
                }
                return try self.compileMethodOrNamespacedCall(fa, call.args);
            }

            if (call.callee.kind == .ident) {
                const name = call.callee.kind.ident;

                if (std.mem.eql(u8, name, "currentCoro")) {
                    if (self.current_async_hdl) |h| {
                        return core.LLVMBuildPtrToInt(self.builder, h, self.val_type, "cur_coro");
                    }
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }
                if (std.mem.eql(u8, name, "coroSuspend")) {
                    try self.buildAwaitSuspend();
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }
                if (std.mem.eql(u8, name, "coroStart")) {
                    if (call.args.len == 1) {
                        if (try self.awaitedCallHandle(call.args[0], true)) |h| {
                            const detach_fn = self.func_map.get("nova_reactor_detach").?;
                            var da = [_]types.LLVMValueRef{h};
                            _ = try self.buildCallWithCasts(detach_fn, &da);
                            const resume_fn = self.func_map.get("nova_reactor_resume").?;
                            var ra = [_]types.LLVMValueRef{h};
                            _ = try self.buildCallWithCasts(resume_fn, &ra);
                            return h;
                        }
                    }
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }

                var resolved_struct_name = name;
                if (self.isCollidingStruct(name)) {
                    if (try self.resolveExpressionTypeName(&expr)) |rt| {
                        const rt_base = getStructBaseName(rt);
                        if (self.isStructType(rt_base)) resolved_struct_name = rt_base;
                    }
                    }
                if (self.isStructType(resolved_struct_name)) {
                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = resolved_struct_name }, false);
                    const instance_ptr = if (self.isValueStructName(resolved_struct_name))
                        try self.buildValueStructStorage(struct_size)
                    else
                        try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    const init_name = try self.methodSymbol(resolved_struct_name, "init");
                    defer self.allocator.free(init_name);
                    const new_name = try self.methodSymbol(resolved_struct_name, "new");
                    defer self.allocator.free(new_name);

                    var mono_init: ?[]const u8 = null;
                    if (try self.resolveExpressionTypeName(&expr)) |inst| {
                        if (!std.mem.eql(u8, getStructBaseName(inst), inst)) {
                            const mi = try self.methodSymbol(inst, "init");
                            if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                        }
                    }
                    defer if (mono_init) |mi| self.allocator.free(mi);

                    const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                        self.func_map.get(init_name) orelse self.func_map.get(new_name);

                    if (fn_val_opt) |fn_val| {
                        const total_args = call.args.len + 1;
                        const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                        defer self.allocator.free(args);

                        args[0] = instance_ptr;
                        const actual_fn_name = if (mono_init) |mi| mi else if (self.func_map.get(init_name) != null) init_name else new_name;
                        for (call.args, 0..) |*arg, idx| {
                            const psup = self.getFunctionParamType(actual_fn_name, idx + 1);
                            self.suppress_valopt_unbox = psup != null and types_mod.valueOptionalName(psup.?);
                            var val = try self.compileCallArgument(arg.*);
                            self.suppress_valopt_unbox = false;

                            val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(actual_fn_name, idx + 1), psup);
                            if (self.getFunctionParamType(actual_fn_name, idx + 1)) |expected_type| {
                                if (self.traits.contains(getStructBaseName(expected_type))) {
                                    if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                        if (self.structs.contains(getStructBaseName(struct_name))) {
                                            val = try self.constructTraitObject(val, struct_name, expected_type);
                                        }
                                    }
                                }
                            }
                            args[idx + 1] = val;
                        }

                        _ = try self.buildCallWithCasts(fn_val, args);
                    } else {
                        try self.initDefaultContainerFields(resolved_struct_name, instance_ptr, call.span, &[_]ast.TypeRef{});
                    }
                    return instance_ptr;
                }

                var is_captured = self.envCaptureIndex(name) != null;
                var curr_fn = self.current_function_name;
                while (curr_fn) |fn_name| {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fn_name, name });
                    defer self.allocator.free(key);
                    if (self.captured_globals.contains(key)) {
                        is_captured = true;
                        break;
                    }
                    curr_fn = self.lambda_parents.get(fn_name);
                }
                if (self.locals.contains(name) or is_captured) {

                    const box_val = try self.compileExpression(call.callee.*);
                    return try self.buildClosureCall(box_val, call.args);
                }

                const resolved_name = resolve: {
                    if (self.typed_ir) |ir| {
                        if (ir.symOf(&expr)) |sid| {
                            if (sema_shadow.live_sema) |sm| {
                                const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                                if (self.hasFunction(legacy)) {
                                    if (sema_shadow.report_enabled) sema_shadow.f1_3b_agree += 1;
                                    break :resolve legacy;
                                }
                            }
                        }
                    }
                    if (sema_shadow.report_enabled) {
                        sema_shadow.f1_3b_sym_absent += 1;
                        sema_shadow.noteF13bAbsent(self.allocator, name);
                    }
                    break :resolve try self.resolveCalleeName(name);
                };

                var mono_name: ?[]const u8 = null;
                defer if (mono_name) |m| self.allocator.free(m);
                if (!self.func_map.contains(resolved_name)) {
                    if (self.typed_ir) |ir| {
                        if (ir.methodArgsOf(&expr)) |targs| {
                            if (targs.len > 0) {
                                if (self.type_store) |st| {
                                    var nb = std.ArrayListUnmanaged(u8).empty;
                                    var ok = true;
                                    nb.appendSlice(self.allocator, resolved_name) catch {
                                        ok = false;
                                    };
                                    for (targs) |ta| {
                                        if (!ok) break;
                                        const rendered = sema_shadow.renderLegacy(self.allocator, st, ta) catch {
                                            ok = false;
                                            break;
                                        };
                                        const ma = types_mod.mangleTypeName(self.allocator, rendered) catch {
                                            ok = false;
                                            break;
                                        };
                                        defer self.allocator.free(ma);
                                        nb.appendSlice(self.allocator, "__") catch {
                                            ok = false;
                                        };
                                        nb.appendSlice(self.allocator, ma) catch {
                                            ok = false;
                                        };
                                    }
                                    if (ok) {
                                        const cand = nb.toOwnedSlice(self.allocator) catch null;
                                        if (cand) |c| {
                                            if (self.func_map.contains(c)) mono_name = c else self.allocator.free(c);
                                        }
                                    } else {
                                        nb.deinit(self.allocator);
                                    }
                                }
                            }
                        }
                    }
                }
                const lookup_name = mono_name orelse resolved_name;
                const fn_val = self.func_map.get(lookup_name) orelse {
                    if (self.is_wasm) {
                        std.debug.print("error: '{s}' is native-only and not available on the wasm target (it resolves to a native runtime symbol with no wasm host import). Guard native code with `@native {{ ... }}`, or provide a `@wasm {{ ... }}` alternative.\n", .{resolved_name});
                    } else {
                        std.debug.print("Function '{s}' not found\n", .{resolved_name});
                    }
                    return error.FunctionNotFound;
                };

                if (self.ffi_externs.get(resolved_name)) |ffd| {
                    const args = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                    defer self.allocator.free(args);

                    var to_free = std.ArrayListUnmanaged([2]types.LLVMValueRef).empty;
                    defer to_free.deinit(self.allocator);
                    for (call.args, 0..) |*arg, idx| {
                        const val = try self.compileCallArgument(arg.*);
                        const is_str_param = idx < ffd.params.len and if (ffd.params[idx].type_name) |t|
                            std.mem.eql(u8, self.typeRefToString(t) catch "", "string")
                        else
                            false;
                        if (is_str_param) {
                            const to_cstr = self.func_map.get("nova_ffi_to_cstr").?;
                            var one = [_]types.LLVMValueRef{val};
                            const cstr = try self.buildCallWithCasts(to_cstr, &one);
                            try to_free.append(self.allocator, .{ val, cstr });
                            args[idx] = cstr;
                        } else {
                            args[idx] = val;
                        }
                    }
                    var ret = try self.buildCallWithCasts(fn_val, args);
                    for (to_free.items) |pair| {
                        const free_fn = self.func_map.get("nova_ffi_free_cstr").?;
                        var fa = [_]types.LLVMValueRef{ pair[0], pair[1] };
                        _ = try self.buildCallWithCasts(free_fn, &fa);
                    }
                    const ret_is_str = if (ffd.ret_type) |t|
                        std.mem.eql(u8, self.typeRefToString(t) catch "", "string")
                    else
                        false;
                    if (ret_is_str) {
                        const from_cstr = self.func_map.get("nova_ffi_from_cstr").?;
                        var one = [_]types.LLVMValueRef{ret};
                        ret = try self.buildCallWithCasts(from_cstr, &one);
                    }
                    return ret;
                }

                const args = try self.allocator.alloc(types.LLVMValueRef, call.args.len);
                defer self.allocator.free(args);
                for (call.args, 0..) |*arg, idx| {
                    const psup = self.getFunctionParamType(resolved_name, idx);
                    self.suppress_valopt_unbox = psup != null and types_mod.valueOptionalName(psup.?);
                    var val = try self.compileCallArgument(arg.*);
                    self.suppress_valopt_unbox = false;

                    val = try self.coerceValoptArg(val, arg, self.getFunctionParamTypeRef(resolved_name, idx), psup);
                    if (self.getFunctionParamType(resolved_name, idx)) |expected_type| {
                        if (self.traits.contains(getStructBaseName(expected_type))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(getStructBaseName(struct_name))) {
                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                }
                            }
                        }
                    }
                    args[idx] = val;
                }

                if (self.async_fns.contains(resolved_name)) {
                    return try self.buildDriveAsyncCall(fn_val, args);
                }

                return try self.buildCallWithCasts(fn_val, args);
            }

            const box_val = try self.compileExpression(call.callee.*);
            return try self.buildClosureCall(box_val, call.args);
        },
        .generic_call => |gc| {
            if (gc.type_args.len == 1) {
                const wcallee: ?[]const u8 = switch (gc.callee.kind) {
                    .field_access => |fa| if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "witness")) fa.field else null,
                    else => null,
                };
                if (wcallee) |wn| {
                    if (std.mem.eql(u8, wn, "sizeOf") or std.mem.eql(u8, wn, "copyElem") or
                        std.mem.eql(u8, wn, "dropElem") or std.mem.eql(u8, wn, "store") or
                        std.mem.eql(u8, wn, "storeOver") or std.mem.eql(u8, wn, "load") or
                        std.mem.eql(u8, wn, "moveElem") or std.mem.eql(u8, wn, "moveOut"))
                    {
                        if (try self.compileElemWitness(wn, gc)) |v| return v;
                    }
                }
            }
            if (gc.callee.kind == .field_access) {
                const fa = gc.callee.kind.field_access;

                if (routeVerbMethod(fa.field)) |method_str| {
                    if (gc.type_args.len == 1 and gc.args.len == 1) {
                        if (try self.resolveExpressionTypeName(fa.object)) |obj_ty| {
                            if (self.structs.get(getStructBaseName(obj_ty))) |rsd| {
                                if (structHasMethod(rsd, "__addRoute")) {

                                    const q = try self.typeRefToString(gc.type_args[0]);
                                    var synth_args = [_]ast.Expression{
                                        .{ .kind = .{ .literal = .{ .string = method_str } } },
                                        gc.args[0],
                                        .{ .kind = .{ .literal = .{ .string = q } } },
                                    };
                                    const synth_fa = ast.FieldAccess{ .object = fa.object, .field = "__addRoute", .span = fa.span };
                                    return try self.compileMethodOrNamespacedCall(synth_fa, &synth_args);
                                }
                            }
                        }
                    }
                }
                if (std.mem.eql(u8, fa.field, "Atomic")) {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }
                if (fa.object.kind == .ident and
                    (std.mem.eql(u8, fa.object.kind.ident, "json") or std.mem.eql(u8, fa.object.kind.ident, "JsonValue") or
                        std.mem.eql(u8, fa.object.kind.ident, "yaml") or std.mem.eql(u8, fa.object.kind.ident, "YamlValue")) and
                    std.mem.eql(u8, fa.field, "parse"))
                {
                    const is_yaml = std.mem.eql(u8, fa.object.kind.ident, "yaml") or std.mem.eql(u8, fa.object.kind.ident, "YamlValue");
                    var target_type = gc.type_args[0];

                    if (target_type == .ident) {
                        if (self.concreteTidForTypeRef(target_type)) |ctid| {
                            target_type = ast.TypeRef{ .ident = try self.symbolName(ctid) };
                        }
                    }
                    const input_expr = gc.args[0];
                    return try self.compileGenericParse(is_yaml, target_type, input_expr);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "mem") and
                    gc.type_args.len == 1 and
                    (std.mem.eql(u8, fa.field, "load") or std.mem.eql(u8, fa.field, "store") or
                        std.mem.eql(u8, fa.field, "rotl") or std.mem.eql(u8, fa.field, "rotr") or
                        std.mem.eql(u8, fa.field, "ctz") or std.mem.eql(u8, fa.field, "clz") or
                        std.mem.eql(u8, fa.field, "bswap")))
                {
                    return try self.compileMemCall(fa.field, gc.type_args[0], gc.args);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "bind") and gc.type_args.len == 1)
                {

                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const binder_name = try std.fmt.allocPrint(self.allocator, "{s}__bind", .{rendered});
                    defer self.allocator.free(binder_name);
                    const resolved_binder = try self.resolveCalleeName(binder_name);
                    const fn_val = self.func_map.get(resolved_binder) orelse self.func_map.get(binder_name) orelse {
                        if (!self.structs.contains(getStructBaseName(rendered))) {
                            self.emitTrapIf(core.LLVMConstInt(core.LLVMInt1Type(), 1, 0), "unreachable: serde.bind on an unresolved type parameter (erased generic body)");
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                        std.debug.print("serde.bind: binder '{s}' not found\n", .{binder_name});
                        return error.FunctionNotFound;
                    };
                    var arg_val = try self.compileCallArgument(gc.args[0]);
                    if (try self.resolveExpressionTypeName(&gc.args[0])) |sname| {
                        if (self.structs.contains(sname)) {
                            arg_val = try self.constructTraitObject(arg_val, sname, "ValueSource");
                        }
                    }
                    var bargs = [_]types.LLVMValueRef{arg_val};
                    const bound = try self.buildCallWithCasts(fn_val, &bargs);

                    return bound;
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "dump") and gc.type_args.len == 1 and gc.args.len == 2)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const dumper_name = try std.fmt.allocPrint(self.allocator, "{s}__dump", .{rendered});
                    defer self.allocator.free(dumper_name);
                    const resolved_dumper = try self.resolveCalleeName(dumper_name);
                    const fn_val = self.func_map.get(resolved_dumper) orelse self.func_map.get(dumper_name) orelse {
                        std.debug.print("serde.dump: dumper '{s}' not found\n", .{dumper_name});
                        return error.FunctionNotFound;
                    };
                    const obj_val = try self.compileCallArgument(gc.args[0]);
                    var sink_val = try self.compileCallArgument(gc.args[1]);
                    if (try self.resolveExpressionTypeName(&gc.args[1])) |sname| {
                        if (self.structs.contains(sname)) {
                            sink_val = try self.constructTraitObject(sink_val, sname, "ValueSink");
                        }
                    }
                    var dargs = [_]types.LLVMValueRef{ obj_val, sink_val };
                    return try self.buildCallWithCasts(fn_val, &dargs);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "planFor") and gc.type_args.len == 1 and gc.args.len == 1)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const name = try std.fmt.allocPrint(self.allocator, "{s}__planFor", .{rendered});
                    defer self.allocator.free(name);
                    const resolved = try self.resolveCalleeName(name);
                    const fn_val = self.func_map.get(resolved) orelse self.func_map.get(name) orelse {
                        if (!self.structs.contains(getStructBaseName(rendered))) {
                            self.emitTrapIf(core.LLVMConstInt(core.LLVMInt1Type(), 1, 0), "unreachable: serde.planFor on an unresolved type parameter (erased generic body)");
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                        std.debug.print("serde.planFor: '{s}' not found\n", .{name});
                        return error.FunctionNotFound;
                    };
                    const cols_val = try self.compileCallArgument(gc.args[0]);
                    var pargs = [_]types.LLVMValueRef{cols_val};
                    return try self.buildCallWithCasts(fn_val, &pargs);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "bindRow") and gc.type_args.len == 1 and gc.args.len == 2)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const name = try std.fmt.allocPrint(self.allocator, "{s}__bindRow", .{rendered});
                    defer self.allocator.free(name);
                    const resolved = try self.resolveCalleeName(name);
                    const fn_val = self.func_map.get(resolved) orelse self.func_map.get(name) orelse {
                        if (!self.structs.contains(getStructBaseName(rendered))) {
                            self.emitTrapIf(core.LLVMConstInt(core.LLVMInt1Type(), 1, 0), "unreachable: serde.bindRow on an unresolved type parameter (erased generic body)");
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                        std.debug.print("serde.bindRow: '{s}' not found\n", .{name});
                        return error.FunctionNotFound;
                    };
                    const row_val = try self.compileCallArgument(gc.args[0]);
                    const plan_val = try self.compileCallArgument(gc.args[1]);
                    var bargs = [_]types.LLVMValueRef{ row_val, plan_val };
                    return try self.buildCallWithCasts(fn_val, &bargs);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "bindAll") and gc.type_args.len == 1 and gc.args.len == 1)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const name = try std.fmt.allocPrint(self.allocator, "{s}__bindAll", .{rendered});
                    defer self.allocator.free(name);
                    const resolved = try self.resolveCalleeName(name);
                    const fn_val = self.func_map.get(resolved) orelse self.func_map.get(name) orelse {
                        if (!self.structs.contains(getStructBaseName(rendered))) {
                            self.emitTrapIf(core.LLVMConstInt(core.LLVMInt1Type(), 1, 0), "unreachable: serde.bindAll on an unresolved type parameter (erased generic body)");
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                        std.debug.print("serde.bindAll: '{s}' not found\n", .{name});
                        return error.FunctionNotFound;
                    };
                    const rs_val = try self.compileCallArgument(gc.args[0]);
                    var bargs = [_]types.LLVMValueRef{rs_val};
                    return try self.buildCallWithCasts(fn_val, &bargs);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "bindWire") and gc.type_args.len == 1 and gc.args.len == 1)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    const name = try std.fmt.allocPrint(self.allocator, "{s}__bindWire", .{rendered});
                    defer self.allocator.free(name);
                    const resolved = try self.resolveCalleeName(name);
                    const fn_val = self.func_map.get(resolved) orelse self.func_map.get(name) orelse {
                        if (!self.structs.contains(getStructBaseName(rendered))) {
                            self.emitTrapIf(core.LLVMConstInt(core.LLVMInt1Type(), 1, 0), "unreachable: serde.bindWire on an unresolved type parameter (erased generic body)");
                            return core.LLVMConstInt(self.val_type, 0, 0);
                        }
                        std.debug.print("serde.bindWire: '{s}' not found\n", .{name});
                        return error.FunctionNotFound;
                    };
                    const w_val = try self.compileCallArgument(gc.args[0]);
                    var bargs = [_]types.LLVMValueRef{w_val};
                    return try self.buildCallWithCasts(fn_val, &bargs);
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "serde") and
                    std.mem.eql(u8, fa.field, "typeName") and gc.type_args.len == 1)
                {
                    const rendered = try self.resolveReifyTypeName(gc.type_args[0]);
                    return try self.getOrCreateStringLiteral(rendered);
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "protocol") and std.mem.eql(u8, fa.field, "callDecoder")) {
                    const decoder_ptr = try self.compileExpression(gc.args[0]);
                    const fixed_data = try self.compileExpression(gc.args[1]);
                    const heap_data = try self.compileExpression(gc.args[2]);
                    const col_names = try self.compileExpression(gc.args[3]);
                    const col_types = try self.compileExpression(gc.args[4]);

                    var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
                    const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
                    const fn_ptr = core.LLVMBuildIntToPtr(self.builder, decoder_ptr, self.ptr_type, "fn_ptr");

                    var args = [_]types.LLVMValueRef{ fixed_data, heap_data, col_names, col_types };
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, 4, "call_decoder_res");
                }
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                if (obj_type) |struct_name| {
                    const base_struct = getStructBaseName(struct_name);
                    if (std.mem.eql(u8, base_struct, "NovaConnection") and
                        (std.mem.eql(u8, fa.field, "query") or std.mem.eql(u8, fa.field, "queryStruct")))
                    {
                        const target_type = gc.type_args[0];
                        const sql_expr = gc.args[0];
                        const params_expr = gc.args[1];
                        return try self.compileNovaQuery(target_type, fa.object.*, sql_expr, params_expr);
                    }
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "Atomic") and std.mem.eql(u8, fa.field, "new"))
                {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }

                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes") and std.mem.eql(u8, fa.field, "new_persistent")) {
                    const target_type = gc.type_args[0];
                    var size: usize = 8;
                    switch (target_type) {
                        .ident => |name| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = name }, false);
                        },
                        .generic => |g| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = g.name }, false);
                        },
                        else => {},
                    }
                    const size_val = core.LLVMConstInt(self.val_type, size, 0);
                    return try self.compileAllocPersistent(size_val);
                }
                if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes") and std.mem.eql(u8, fa.field, "new_with_allocator")) {
                    if (self.locals.get("self")) |self_alloca| {
                        return core.LLVMBuildLoad2(self.builder, self.val_type, self_alloca, "self_val");
                    }
                    const target_type = gc.type_args[0];
                    var size: usize = 8;
                    switch (target_type) {
                        .ident => |name| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = name }, false);
                        },
                        .generic => |g| {
                            size = self.getTypeSize(ast.TypeRef{ .ident = g.name }, false);
                        },
                        else => {},
                    }
                    const size_val = core.LLVMConstInt(self.val_type, size, 0);
                    const alloc_val = try self.compileExpression(gc.args[0]);

                    const offset = try self.getFieldOffset("Allocator", "kind");
                    const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                    const addr = core.LLVMBuildAdd(self.builder, alloc_val, offset_val, "kind_addr");
                    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "kind_ptr");
                    const kind_val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "kind_val");

                    const is_c_alloc = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, kind_val, core.LLVMConstInt(self.val_type, 1, 0), "is_c_alloc");

                    const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
                    const then_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_c");
                    const else_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_arena");
                    const merge_bb = core.LLVMAppendBasicBlock(current_fn, "alloc_merge");

                    _ = core.LLVMBuildCondBr(self.builder, is_c_alloc, then_bb, else_bb);

                    core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
                    const p_val = try self.compileAllocPersistent(size_val);
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                    const then_end_bb = core.LLVMGetInsertBlock(self.builder);

                    core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
                    const a_val = try self.compileAlloc(size_val);
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                    const else_end_bb = core.LLVMGetInsertBlock(self.builder);

                    core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
                    const phi = core.LLVMBuildPhi(self.builder, self.val_type, "alloc_res");
                    var incoming_vals = [_]types.LLVMValueRef{ p_val, a_val };
                    var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                    core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                    return phi;
                }

                if (try self.compileExplicitGenericMethodCall(gc.callee.kind.field_access, gc.type_args, gc.args)) |v| {
                    return v;
                }

                {
                    const cfa = gc.callee.kind.field_access;
                    if (gc.type_args.len > 0 and cfa.object.kind == .ident and
                        self.isStructType(cfa.field) and
                        (try self.resolveExpressionTypeName(cfa.object)) == null)
                    {
                        const g_ref = ast.TypeRef{ .generic = .{ .name = cfa.field, .params = gc.type_args } };
                        const struct_size = self.getTypeSize(g_ref, false);
                        const instance_ptr = if (self.isValueStructName(cfa.field))
                            try self.buildValueStructStorage(struct_size)
                        else
                            try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));
                        var mono_init: ?[]const u8 = null;
                        if (try self.resolveExpressionTypeName(&expr)) |inst| {
                            if (!std.mem.eql(u8, getStructBaseName(inst), inst)) {
                                const mi = try self.methodSymbol(inst, "init");
                                if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                            }
                        }
                        defer if (mono_init) |mi| self.allocator.free(mi);
                        const base_init = try self.methodSymbol(cfa.field, "init");
                        defer self.allocator.free(base_init);
                        const base_new = try self.methodSymbol(cfa.field, "new");
                        defer self.allocator.free(base_new);
                        const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                            self.func_map.get(base_init) orelse self.func_map.get(base_new);
                        if (fn_val_opt) |fn_val| {
                            const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len + 1);
                            defer self.allocator.free(args);

                            const init_decl: ?*const ast.FunctionDecl = blk: {
                                const sd = self.structs.get(cfa.field) orelse break :blk null;
                                for (sd.methods) |*m| {
                                    if (std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new")) break :blk &m.decl;
                                }
                                break :blk null;
                            };
                            args[0] = instance_ptr;
                            for (gc.args, 0..) |arg, idx| {
                                var val = try self.compileCallArgument(arg);
                                if (init_decl) |idcl| {
                                    if (idx < idcl.params.len) {
                                        if (idcl.params[idx].type_name) |trt| {
                                            const expected_type = try self.typeRefToString(trt);
                                            if (self.traits.contains(getStructBaseName(expected_type))) {
                                                if (try self.resolveExpressionTypeName(&arg)) |struct_name| {
                                                    if (self.structs.contains(getStructBaseName(struct_name))) {
                                                        val = try self.constructTraitObject(val, struct_name, expected_type);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                args[idx + 1] = val;
                            }
                            _ = try self.buildCallWithCasts(fn_val, args);
                            return instance_ptr;
                        }
                    }
                }

                {
                    const cfa = gc.callee.kind.field_access;

                    var isAsyncField = false;
                    {
                        var it = self.async_fns.keyIterator();
                        while (it.next()) |k| {
                            const key = k.*;
                            if (std.mem.endsWith(u8, key, cfa.field) and
                                (key.len == cfa.field.len or key[key.len - cfa.field.len - 1] == '_'))
                            {
                                isAsyncField = true;
                                break;
                            }
                        }
                    }
                    if (!isAsyncField and gc.type_args.len > 0 and cfa.object.kind == .ident and
                        !self.isStructType(cfa.field) and
                        (try self.resolveExpressionTypeName(cfa.object)) == null)
                    {
                        if (try self.findNamespacedSpec(cfa.object.kind.ident, cfa.field, gc.type_args)) |fn_val| {
                            const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len);
                            defer self.allocator.free(args);
                            for (gc.args, 0..) |*arg, idx| {
                                var val = try self.compileCallArgument(arg.*);

                                if (self.getFunctionParamType(cfa.field, idx)) |expected_type| {
                                    if (self.traits.contains(getStructBaseName(expected_type))) {
                                        if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                            if (self.structs.contains(getStructBaseName(struct_name))) {
                                                val = try self.constructTraitObject(val, struct_name, expected_type);
                                            }
                                        }
                                    }
                                }
                                args[idx] = val;
                            }
                            return try self.buildCallWithCasts(fn_val, args);
                        }
                    }
                }
                return try self.compileMethodOrNamespacedCall(gc.callee.kind.field_access, gc.args);
            }
            if (gc.callee.kind == .ident) {
                const name = gc.callee.kind.ident;

                var resolved_struct_name = name;
                if (self.isCollidingStruct(name)) {
                    if (try self.resolveExpressionTypeName(&expr)) |rt| {
                        const rt_base = getStructBaseName(rt);
                        if (self.isStructType(rt_base)) resolved_struct_name = rt_base;
                    }
                    }
                if (std.mem.eql(u8, resolved_struct_name, "Atomic")) {
                    const target_type = gc.type_args[0];
                    const t_name = try self.typeRefToString(target_type);

                    const cell = self.atomicCell(t_name);
                    const size_val = core.LLVMConstInt(self.val_type, cell.size, 0);

                    const atomic_val_ptr = try self.compileAlloc(size_val);

                    const initial_val = try self.compileExpression(gc.args[0]);
                    const llvm_field_type = self.atomicCell(t_name).ty;
                    const casted_initial = self.castFromValType(initial_val, llvm_field_type);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, core.LLVMPointerType(llvm_field_type, 0), "init_ptr");
                    _ = core.LLVMBuildStore(self.builder, casted_initial, ptr);

                    const struct_size = self.getTypeSize(ast.TypeRef{ .ident = "Atomic" }, false);
                    const struct_ptr_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    const ptr_dest = core.LLVMBuildIntToPtr(self.builder, struct_ptr_val, core.LLVMPointerType(self.ptr_type, 0), "struct_ptr_dest");
                    _ = core.LLVMBuildStore(self.builder, core.LLVMBuildIntToPtr(self.builder, atomic_val_ptr, self.ptr_type, "cast_ptr"), ptr_dest);

                    return struct_ptr_val;
                }

                if (std.mem.eql(u8, resolved_struct_name, "Storage")) {
                    const n = try self.compileExpression(gc.args[0]);
                    var slot_w: u64 = 8;
                    if (gc.type_args.len > 0) {
                        const en = self.typeRefToString(gc.type_args[0]) catch "";
                        if (self.isValueStructName(en)) slot_w = @max(self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(en) }, false), 1);
                    }
                    const width = core.LLVMConstInt(self.val_type, slot_w, 0);
                    const bytes_needed = core.LLVMBuildMul(self.builder, n, width, "stg_bytes");
                    return try self.compileAllocPersistent(bytes_needed);
                }

                if (self.isStructType(resolved_struct_name)) {
                    const g_ref = ast.TypeRef{
                        .generic = .{
                            .name = resolved_struct_name,
                            .params = gc.type_args,
                        }
                    };
                    const struct_size = self.getTypeSize(g_ref, false);
                    const instance_ptr = if (self.isValueStructName(resolved_struct_name))
                        try self.buildValueStructStorage(struct_size)
                    else
                        try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                    var gen_name = try self.allocator.dupe(u8, resolved_struct_name);
                    for (gc.type_args) |t| {
                        const t_str = try self.typeRefToString(t);
                        const old_gen_name = gen_name;
                        gen_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ old_gen_name, t_str });
                        self.allocator.free(old_gen_name);
                    }

                    const init_name = try self.methodSymbol(gen_name, "init");
                    defer self.allocator.free(init_name);
                    const new_name = try self.methodSymbol(gen_name, "new");
                    defer self.allocator.free(new_name);
                    self.allocator.free(gen_name);

                    const base_init_name = try self.methodSymbol(resolved_struct_name, "init");
                    defer self.allocator.free(base_init_name);
                    const base_new_name = try self.methodSymbol(resolved_struct_name, "new");
                    defer self.allocator.free(base_new_name);

                    var mono_init: ?[]const u8 = null;
                    if (try self.resolveExpressionTypeName(&expr)) |inst| {
                        if (!std.mem.eql(u8, getStructBaseName(inst), inst)) {
                            const mi = try self.methodSymbol(inst, "init");
                            if (self.func_map.get(mi) != null) mono_init = mi else self.allocator.free(mi);
                        }
                    }
                    defer if (mono_init) |mi| self.allocator.free(mi);

                    const fn_val_opt = (if (mono_init) |mi| self.func_map.get(mi) else null) orelse
                                       self.func_map.get(init_name) orelse
                                       self.func_map.get(new_name) orelse
                                       self.func_map.get(base_init_name) orelse
                                       self.func_map.get(base_new_name);

                    if (fn_val_opt) |fn_val| {
                        const total_args = gc.args.len + 1;
                        const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                        defer self.allocator.free(args);

                        const init_decl: ?*const ast.FunctionDecl = blk: {
                            const sd = self.structs.get(resolved_struct_name) orelse break :blk null;
                            for (sd.methods) |*m| {
                                if (std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new")) break :blk &m.decl;
                            }
                            break :blk null;
                        };
                        args[0] = instance_ptr;
                        for (gc.args, 0..) |arg, idx| {
                            var val = try self.compileCallArgument(arg);

                            if (init_decl) |idcl| {
                                if (idx < idcl.params.len) {
                                    if (idcl.params[idx].type_name) |trt| {
                                        const expected_type = try self.typeRefToString(trt);
                                        if (self.traits.contains(getStructBaseName(expected_type))) {
                                            if (try self.resolveExpressionTypeName(&arg)) |struct_name| {
                                                if (self.structs.contains(getStructBaseName(struct_name))) {
                                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            args[idx + 1] = val;
                        }

                        _ = try self.buildCallWithCasts(fn_val, args);
                    } else {
                        try self.initDefaultContainerFields(resolved_struct_name, instance_ptr, gc.span, gc.type_args);
                    }
                    return instance_ptr;
                }

                if (self.locals.contains(name)) {

                    const box_val = try self.compileExpression(gc.callee.*);
                    return try self.buildClosureCall(box_val, gc.args);
                }

                const resolved_name = try self.resolveCalleeName(name);

                var callee_name = resolved_name;
                var spec_buf: ?[]const u8 = null;
                defer if (spec_buf) |s| self.allocator.free(s);
                if (gc.type_args.len > 0) {
                    var nb = std.ArrayListUnmanaged(u8).empty;
                    errdefer nb.deinit(self.allocator);
                    try nb.appendSlice(self.allocator, resolved_name);
                    for (gc.type_args) |ta| {
                        const rendered = try self.typeRefToString(ta);
                        const ma = try types_mod.mangleTypeName(self.allocator, rendered);
                        defer self.allocator.free(ma);
                        try nb.appendSlice(self.allocator, "__");
                        try nb.appendSlice(self.allocator, ma);
                    }
                    const cand = try nb.toOwnedSlice(self.allocator);
                    if (self.func_map.contains(cand)) {
                        spec_buf = cand;
                        callee_name = cand;
                    } else {
                        self.allocator.free(cand);
                    }
                }
                const fn_val = self.func_map.get(callee_name) orelse {
                    if (self.is_wasm) {
                        std.debug.print("error: '{s}' is native-only and not available on the wasm target (native runtime symbol / FFI extern with no wasm host import). Guard native code with `@native {{ ... }}`.\n", .{callee_name});
                    } else {
                        std.debug.print("Function '{s}' not found\n", .{callee_name});
                    }
                    return error.FunctionNotFound;
                };

                const args = try self.allocator.alloc(types.LLVMValueRef, gc.args.len);
                defer self.allocator.free(args);
                for (gc.args, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(name, idx)) |expected_type| {
                        if (self.traits.contains(getStructBaseName(expected_type))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(getStructBaseName(struct_name))) {
                                    val = try self.constructTraitObject(val, struct_name, expected_type);
                                }
                            }
                        }
                    }
                    args[idx] = val;
                }

                if (self.async_fns.contains(callee_name)) {
                    return try self.buildDriveAsyncCall(fn_val, args);
                }

                return try self.buildCallWithCasts(fn_val, args);
            }
            return error.UnsupportedCallTarget;
        },
        .struct_init => |si| {
            if (self.findEnumByVariant(si.type_name)) |enum_name| {
                var tag: u32 = 0;
                var total_size: u32 = 0;
                try self.getEnumTagAndSize(enum_name, si.type_name, &tag, &total_size);

                const union_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, total_size, 0));

                const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                const enum_decl = self.enums.get(enum_name).?;
                const ptr_size = @as(u32, 8);
                for (enum_decl.variants) |v| {
                    if (std.mem.eql(u8, v.name, si.type_name)) {
                        if (v.fields) |payload_fields| {
                            for (si.fields) |f_init| {
                                for (payload_fields, 0..) |pf, idx| {
                                    if (std.mem.eql(u8, f_init.name, pf.name)) {
                                        const f_val = try self.compileExpression(f_init.value);
                                        const pf_type_str = try self.typeRefToString(pf.type_name);

                                        if (self.isOwnedDeclaredType(pf.type_name, pf_type_str)) {
                                            try self.takeOwnedElement(f_init.value.kind, f_val);
                                        }
                                        const offset = core.LLVMConstInt(self.val_type, ptr_size + idx * ptr_size, 0);
                                        const addr = core.LLVMBuildAdd(self.builder, union_ptr, offset, "payload_addr");
                                        const dest_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                                        _ = core.LLVMBuildStore(self.builder, f_val, dest_ptr);
                                        break;
                                    }
                                }
                            }
                        }
                        break;
                    }
                }

                return union_ptr;
            }

            if (self.unions.get(si.type_name)) |u| {
                var max_size = self.getTypeSize(ast.TypeRef{ .ident = si.type_name }, false);
                if (max_size == 0) max_size = 8;
                const size_val = core.LLVMConstInt(self.val_type, max_size, 0);
                const union_ptr_val = try self.compileAlloc(size_val);
                for (si.fields) |f_init| {
                    var field_type_ref = ast.TypeRef{ .ident = "i32" };
                    for (u.fields) |f| {
                        if (std.mem.eql(u8, f.name, f_init.name)) {
                            field_type_ref = f.type_name;
                            break;
                        }
                    }
                    const field_val = try self.compileExpression(f_init.value);
                    const f_type_str = try self.typeRefToString(field_type_ref);

                    if (self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                        try self.takeOwnedElement(f_init.value.kind, field_val);
                    }
                    const llvm_field_type = self.toLLVMType(field_type_ref);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr_val, core.LLVMPointerType(llvm_field_type, 0), "union_field_ptr");
                    const casted_field_val = self.castFromValType(field_val, llvm_field_type);
                    _ = core.LLVMBuildStore(self.builder, casted_field_val, ptr);
                }
                return union_ptr_val;
            }

            // Substitute a type parameter (e.g. a generic mapper's `To`) to the
            // concrete struct at this monomorphisation; a no-op for a plain literal.
            const tn = try self.substTypeParams(si.type_name);
            const s = self.structs.get(tn) orelse {
                return error.StructNotFound;
            };
            const total_size = self.getTypeSize(ast.TypeRef{ .ident = tn }, false);
            const size_val = core.LLVMConstInt(self.val_type, total_size, 0);

            const struct_ptr_val = if (self.isValueStructName(tn))
                try self.buildValueStructStorage(total_size)
            else
                try self.compileAlloc(size_val);

            // Effective field list. With a `...from(expr)` spread, every target
            // field not named explicitly is synthesised as `expr.<srcField>`,
            // where srcField matches by convention (`_`/case-insensitive). The
            // type checker has already verified every field is covered, so any
            // still-unmatched field here is simply skipped.
            const conv = struct {
                fn eq(a: []const u8, b: []const u8) bool {
                    var i: usize = 0;
                    var j: usize = 0;
                    while (true) {
                        while (i < a.len and a[i] == '_') i += 1;
                        while (j < b.len and b[j] == '_') j += 1;
                        if (i >= a.len or j >= b.len) break;
                        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
                        i += 1;
                        j += 1;
                    }
                    while (i < a.len and a[i] == '_') i += 1;
                    while (j < b.len and b[j] == '_') j += 1;
                    return i >= a.len and j >= b.len;
                }
            }.eq;

            // Flatten name-matcher: target == prefix ++ leaf under normalisation
            // (so `customerName` == `customer` + `name`). Mirrors the type
            // checker's flattenNameMatch.
            const flat = struct {
                fn norm(buf: []u8, name: []const u8) []const u8 {
                    var n: usize = 0;
                    for (name) |c| {
                        if (c == '_') continue;
                        if (n >= buf.len) break;
                        buf[n] = std.ascii.toLower(c);
                        n += 1;
                    }
                    return buf[0..n];
                }
                fn eq(tgt: []const u8, prefix: []const u8, leaf: []const u8) bool {
                    var tb: [128]u8 = undefined;
                    var pb: [128]u8 = undefined;
                    var lb: [128]u8 = undefined;
                    const nt = norm(&tb, tgt);
                    const np = norm(&pb, prefix);
                    const nl = norm(&lb, leaf);
                    if (np.len == 0 or nl.len == 0 or nt.len != np.len + nl.len) return false;
                    return std.mem.startsWith(u8, nt, np) and std.mem.eql(u8, nt[np.len..], nl);
                }
            }.eq;

            var eff_fields: []const ast.ObjectFieldInit = si.fields;
            var synth = std.ArrayList(ast.ObjectFieldInit).empty;
            defer synth.deinit(self.allocator);
            if (si.spread) |sp| {
                for (si.fields) |f| try synth.append(self.allocator, f);
                var src_name_raw = (try self.resolveExpressionTypeName(sp)) orelse "";
                // When the source is a bare local/param whose type did not resolve
                // via the typed IR (e.g. a generic mapper's `src: From`), fall back
                // to its declared local type so a type parameter can be substituted.
                if (src_name_raw.len == 0 and sp.kind == .ident) {
                    if (self.current_local_types) |lt| {
                        if (lt.get(sp.kind.ident)) |ts| src_name_raw = ts;
                    }
                }
                // Substitute a type-parameter source (a generic mapper's `From`).
                const src_name = try self.substTypeParams(src_name_raw);
                if (self.structs.get(src_name)) |ss| {
                    for (s.fields) |df| {
                        var explicit = false;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, df.name)) {
                                explicit = true;
                                break;
                            }
                        }
                        if (explicit) continue;

                        // Field-level mapper attributes on the TARGET field win
                        // over convention: `@from("col")` reads a named source
                        // field; `@derive(fn)` computes `fn(src)` from the whole
                        // source. (df is the concrete target struct field.)
                        var attr_handled = false;
                        for (df.attributes) |at| {
                            switch (at) {
                                .from => |col| {
                                    const fa = ast.Expression{ .kind = .{ .field_access = .{
                                        .object = sp,
                                        .field = col,
                                        .span = si.span,
                                    } }, .span = si.span };
                                    try synth.append(self.allocator, ast.ObjectFieldInit{ .name = df.name, .value = fa, .span = si.span });
                                    attr_handled = true;
                                },
                                .derive => |fn_name| {
                                    const callee = try self.allocator.create(ast.Expression);
                                    callee.* = ast.Expression{ .kind = .{ .ident = fn_name }, .span = si.span };
                                    const args = try self.allocator.alloc(ast.Expression, 1);
                                    args[0] = sp.*;
                                    const call = ast.Expression{ .kind = .{ .call = .{ .callee = callee, .args = args, .span = si.span } }, .span = si.span };
                                    try synth.append(self.allocator, ast.ObjectFieldInit{ .name = df.name, .value = call, .span = si.span });
                                    attr_handled = true;
                                },
                                else => {},
                            }
                            if (attr_handled) break;
                        }
                        if (attr_handled) continue;

                        var matched = false;
                        for (ss.fields) |sf| {
                            if (!conv(df.name, sf.name)) continue;
                            const df_id = switch (df.type_name) {
                                .ident => |n| n,
                                else => "",
                            };
                            const sf_id = switch (sf.type_name) {
                                .ident => |n| n,
                                else => "",
                            };
                            // The source field access (allocated so a nested
                            // struct-init spread can point at it).
                            const src_fa = try self.allocator.create(ast.Expression);
                            src_fa.* = ast.Expression{ .kind = .{ .field_access = .{
                                .object = sp,
                                .field = sf.name,
                                .span = si.span,
                            } }, .span = si.span };

                            if (df_id.len > 0 and std.mem.eql(u8, df_id, sf_id)) {
                                // Direct copy: same type.
                                try synth.append(self.allocator, ast.ObjectFieldInit{
                                    .name = df.name,
                                    .value = src_fa.*,
                                    .span = si.span,
                                });
                                matched = true;
                                break;
                            }
                            if (df_id.len > 0 and self.structs.contains(df_id) and
                                sf_id.len > 0 and self.structs.contains(sf_id))
                            {
                                // Nested map: `TargetFieldType{ ...from(src.field) }`.
                                // The struct-init codegen recurses into this spread.
                                const nested = ast.Expression{ .kind = .{ .struct_init = ast.StructInit{
                                    .type_name = df_id,
                                    .fields = &.{},
                                    .spread = src_fa,
                                    .span = si.span,
                                } }, .span = si.span };
                                try synth.append(self.allocator, ast.ObjectFieldInit{
                                    .name = df.name,
                                    .value = nested,
                                    .span = si.span,
                                });
                                matched = true;
                                break;
                            }
                            // else: type mismatch with no nested map — the type
                            // checker has already required an explicit field.
                        }
                        // Flatten: `customerName` <- `customer.name`. Build the
                        // path `src.<prefixField>.<leafField>`.
                        if (!matched) {
                            flatten: for (ss.fields) |sf| {
                                const sf_id = switch (sf.type_name) {
                                    .ident => |n| n,
                                    else => "",
                                };
                                if (sf_id.len == 0) continue;
                                const ns = self.structs.get(sf_id) orelse continue;
                                for (ns.fields) |nf| {
                                    if (!flat(df.name, sf.name, nf.name)) continue;
                                    const prefix_fa = try self.allocator.create(ast.Expression);
                                    prefix_fa.* = ast.Expression{ .kind = .{ .field_access = .{
                                        .object = sp,
                                        .field = sf.name,
                                        .span = si.span,
                                    } }, .span = si.span };
                                    const leaf_fa = ast.Expression{ .kind = .{ .field_access = .{
                                        .object = prefix_fa,
                                        .field = nf.name,
                                        .span = si.span,
                                    } }, .span = si.span };
                                    try synth.append(self.allocator, ast.ObjectFieldInit{
                                        .name = df.name,
                                        .value = leaf_fa,
                                        .span = si.span,
                                    });
                                    break :flatten;
                                }
                            }
                        }
                    }
                }
                eff_fields = synth.items;

                // Exhaustiveness at the instantiation. For a non-generic literal the
                // type checker already proved every field is covered; but a spread
                // into a type parameter (a generic mapper's `To`) cannot be checked
                // there (To is abstract), so verify here that every target field was
                // filled, else it would be left as garbage. Erroring keeps the
                // generic `...from` sound.
                for (s.fields) |df| {
                    var covered = false;
                    for (eff_fields) |ef| {
                        if (std.mem.eql(u8, ef.name, df.name)) {
                            covered = true;
                            break;
                        }
                    }
                    if (!covered) {
                        std.debug.print("\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m spread '...from' into '{s}' leaves field '{s}' uncovered\x1b[0m (no convention/@from match, and not given explicitly)\n", .{ tn, df.name });
                        std.debug.print("(compilation failed)\n", .{});
                        std.process.exit(70);
                    }
                }
            }

            for (eff_fields) |f_init| {
                const offset = try self.getFieldOffset(tn, f_init.name);
                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                var field_val = try self.compileExpression(f_init.value);

                var field_type_ref = ast.TypeRef{ .ident = "i32" };
                for (s.fields) |f| {
                    if (std.mem.eql(u8, f.name, f_init.name)) {
                        field_type_ref = f.type_name;
                        break;
                    }
                }

                const f_type_str = try self.typeRefToString(field_type_ref);

                var widened_field = false;
                if (field_type_ref == .ident and self.traits.contains(field_type_ref.ident)) {
                    if (try self.resolveExpressionTypeName(&f_init.value)) |st_name| {
                        if (self.structs.contains(st_name)) {
                            const orig = field_val;
                            self.consumeTemporary(orig);
                            field_val = try self.constructTraitObject(orig, st_name, field_type_ref.ident);
                            self.consumeTemporary(field_val);

                            const stid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(&f_init.value) else null;
                            const sdtor = try self.getOrCreateDestructorPreferId(st_name, stid);
                            try self.compileRelease(orig, sdtor);
                            widened_field = true;
                        }
                    }
                }

                if (!widened_field and self.isOwnedDeclaredType(field_type_ref, f_type_str)) {
                    try self.takeOwnedElement(f_init.value.kind, field_val);
                }

                if (!widened_field and self.valoptTypeRefIsValue(field_type_ref) and
                    !LlvmCompiler.isUndefinedLiteralExpr(&f_init.value) and
                    !self.exprYieldsValoptBox(&f_init.value))
                {
                    field_val = try self.buildValoptBox(self.coerceToSlotType(field_val, self.val_type));
                }

                const addr = core.LLVMBuildAdd(self.builder, struct_ptr_val, offset_val, "field_addr");
                const fbase = getStructBaseName(f_type_str);
                if (!widened_field and self.structs.contains(fbase) and self.fieldStoredInline(fbase)) {
                    const fsz = self.getTypeSize(field_type_ref, false);
                    _ = try self.buildValueStructCopyInto(addr, field_val, fsz);
                } else {
                    const llvm_field_type = self.toLLVMType(field_type_ref);
                    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
                    const casted_field_val = self.castFromValType(field_val, llvm_field_type);
                    _ = core.LLVMBuildStore(self.builder, casted_field_val, ptr);
                }
            }

            return struct_ptr_val;
        },
        .field_access => |fa| {

            const enum_obj_name: ?[]const u8 = switch (fa.object.kind) {
                .ident => |n| n,
                .field_access => |inner| if (inner.object.kind == .ident and !self.identNamesVariable(inner.object.kind.ident)) inner.field else null,
                else => null,
            };
            if (enum_obj_name) |obj_name_bare| {
                const obj_name = self.scopedTypeName(obj_name_bare, fa.span.file);
                if (self.enums.get(obj_name)) |enum_decl| {
                    var is_tagged = false;
                    for (enum_decl.variants) |v| {
                        if (v.type_name != null or v.fields != null) {
                            is_tagged = true;
                            break;
                        }
                    }

                    if (is_tagged) {
                        var tag: u32 = 0;
                        var total_size: u32 = 0;
                        try self.getEnumTagAndSize(obj_name, fa.field, &tag, &total_size);

                        const union_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, total_size, 0));

                        const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                        const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                        _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                        return union_ptr;
                    } else {
                        for (enum_decl.variants, 0..) |v, idx| {
                            if (std.mem.eql(u8, v.name, fa.field)) {
                                const val = v.value orelse @as(i64, @intCast(idx));
                                return core.LLVMConstInt(self.val_type, @intCast(val), 0);
                            }
                        }
                    }
                }

                if (!self.identNamesVariable(obj_name)) {
                    if (self.constants.get(fa.field)) |val| {
                        return try self.compileConstRef(fa.field, val);
                    }
                }
            }

            const obj_is_variable = fa.object.kind == .ident and
                self.identNamesVariable(fa.object.kind.ident);
            if (fa.object.kind == .ident and !obj_is_variable) {
                const mod_name = fa.object.kind.ident;
                const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, fa.field });
                defer self.allocator.free(full_name);
                var fn_val_opt: ?types.LLVMValueRef = self.func_map.get(full_name) orelse self.func_map.get(fa.field);
                if (fn_val_opt == null) {
                    var best_len: usize = std.math.maxInt(usize);
                    var iter = self.func_map.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const suffix_len = full_name.len + 1;
                        if (key.len >= suffix_len) {
                            const suffix = key[key.len - suffix_len..];
                            if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], full_name) and key.len < best_len) {
                                best_len = key.len;
                                fn_val_opt = entry.value_ptr.*;
                            }
                        }
                    }
                }
                if (fn_val_opt) |fn_val| {

                    return try self.buildBareFnBox(fn_val);
                }
            }

            if (std.mem.eql(u8, fa.field, "length") or std.mem.eql(u8, fa.field, "len")) {
                if (self.typed_ir) |ir| {
                    if (self.type_store) |st| {
                        if (ir.typeOf(fa.object)) |tid| {
                            const ty = st.get(tid);
                            if (ty == .array) return core.LLVMConstInt(self.val_type, ty.array.len, 0);
                        }
                    }
                }
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {

                    const str_ptr = try self.compileExpression(fa.object.*);

                    try self.guardOptionalDeref(fa.object, str_ptr, fa.span);
                    const offset = core.LLVMConstInt(self.val_type, 4, 0);
                    const addr = core.LLVMBuildSub(self.builder, str_ptr, offset, "len_addr");
                    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "len_ptr");
                    const len_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "len_val");
                    return core.LLVMBuildZExt(self.builder, len_val, self.val_type, "len_val_ext");
                }
            }

            if (std.mem.eql(u8, fa.field, "ok")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return core.LLVMConstInt(self.val_type, 1, 0);
                }
            }
            if (std.mem.eql(u8, fa.field, "error")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return core.LLVMConstInt(self.val_type, 0, 0);
                }
            }
            if (std.mem.eql(u8, fa.field, "value")) {
                const obj_type = try self.resolveExpressionTypeName(fa.object);
                const is_struct = if (obj_type) |name| self.isStructType(name) else false;
                if (!is_struct) {
                    return try self.compileExpression(fa.object.*);
                }
            }

            const obj_ptr = try self.compileExpression(fa.object.*);

            try self.guardOptionalDeref(fa.object, obj_ptr, fa.span);
            const obj_type = try self.resolveExpressionTypeName(fa.object) orelse {
                return error.StructTypeNotFound;
            };

            const base_struct = getStructBaseName(obj_type);
            var field_type_ref = ast.TypeRef{ .ident = "i32" };
            if (self.structs.get(base_struct)) |s| {
                for (s.fields) |field| {
                    if (std.mem.eql(u8, field.name, fa.field)) {
                        field_type_ref = field.type_name;
                        break;
                    }
                }
            } else if (self.unions.get(base_struct)) |u| {
                for (u.fields) |field| {
                    if (std.mem.eql(u8, field.name, fa.field)) {
                        field_type_ref = field.type_name;
                        break;
                    }
                }
            }

            const offset = try self.getFieldOffset(obj_type, fa.field);
            const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
            const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "field_addr");
            const ftbase = getStructBaseName(try self.typeRefToString(field_type_ref));
            if (self.structs.contains(ftbase) and self.fieldStoredInline(ftbase)) {
                return addr;
            }
            const llvm_field_type = self.toLLVMType(field_type_ref);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
            const raw_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_val");
            return self.castToValType(raw_val, field_type_ref);
        },
        .closure => |cl| {

            const ckey = try self.closureKey(cl.span, self.current_instantiation);
            defer self.allocator.free(ckey);
            const lambda_name = self.closure_lambdas.get(ckey) orelse blk: {
                const base_key = try self.closureKeyM(cl.span, null, null);
                defer self.allocator.free(base_key);
                break :blk self.closure_lambdas.get(base_key) orelse return error.LambdaNotFound;
            };
            const fn_val = self.func_map.get(lambda_name) orelse return error.LambdaValueNotFound;
            const fn_ptr_int = try self.fnRefInt(fn_val, lambda_name);

            const es = self.valSlotSize();

            var env_int = core.LLVMConstInt(self.val_type, 0, 0);
            if (self.lambda_captures.get(lambda_name)) |caps| {
                if (caps.items.len > 0) {
                    const env_size = core.LLVMConstInt(self.val_type, caps.items.len * es, 0);
                    env_int = try self.compileAllocPersistent(env_size);
                    for (caps.items, 0..) |cap, i| {
                        const cap_val = try self.compileExpression(ast.Expression{ .kind = .{ .ident = cap } });

                        if (self.current_local_types) |lt| {
                            if (lt.get(cap)) |ct| {
                                if (self.isOwnedLocal(cap, ct)) try self.compileRetain(cap_val);
                            }
                        }
                        const off = core.LLVMConstInt(self.val_type, i * es, 0);
                        const addr = core.LLVMBuildAdd(self.builder, env_int, off, "env_init_addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "env_init_ptr");
                        _ = core.LLVMBuildStore(self.builder, cap_val, ptr);
                    }
                }
            }

            const cleanup_int = try buildClosureCleanup(self, lambda_name, cl.span);

            const box_size = core.LLVMConstInt(self.val_type, 3 * es, 0);
            const box_int = try self.compileAllocPersistent(box_size);
            const box_ptr0 = core.LLVMBuildIntToPtr(self.builder, box_int, self.ptr_type, "box_ptr0");
            _ = core.LLVMBuildStore(self.builder, fn_ptr_int, box_ptr0);
            const off1 = core.LLVMConstInt(self.val_type, es, 0);
            const addr1 = core.LLVMBuildAdd(self.builder, box_int, off1, "box_addr1");
            const box_ptr1 = core.LLVMBuildIntToPtr(self.builder, addr1, self.ptr_type, "box_ptr1");
            _ = core.LLVMBuildStore(self.builder, env_int, box_ptr1);
            const off2 = core.LLVMConstInt(self.val_type, 2 * es, 0);
            const addr2 = core.LLVMBuildAdd(self.builder, box_int, off2, "box_addr2");
            const box_ptr2 = core.LLVMBuildIntToPtr(self.builder, addr2, self.ptr_type, "box_ptr2");
            _ = core.LLVMBuildStore(self.builder, cleanup_int, box_ptr2);
            return box_int;
        },
        .index => |idx| {
            const obj_ptr = try self.compileExpression(idx.object.*);

            try self.guardOptionalDeref(idx.object, obj_ptr, idx.span);
            const offset_val = try self.compileExpression(idx.index.*);

            const is_string = self.isStringExpr(idx.object);

            if (is_string) {
                const addr = core.LLVMBuildAdd(self.builder, obj_ptr, offset_val, "index_addr");
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "index_ptr");
                const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
                return core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "byte_val_ext");
            } else {
                const base_ptr = self.arrayBasePtr(obj_ptr);
                var idxs = [_]types.LLVMValueRef{offset_val};
                if (self.arrayElemFloatLLVM(idx.object)) |ety| {
                    const ep = core.LLVMBuildInBoundsGEP2(self.builder, ety, base_ptr, &idxs, 1, "arr_gepf");
                    return core.LLVMBuildLoad2(self.builder, ety, ep, "index_fval");
                }
                const elem_ptr = core.LLVMBuildInBoundsGEP2(self.builder, self.val_type, base_ptr, &idxs, 1, "arr_gep");
                return core.LLVMBuildLoad2(self.builder, self.val_type, elem_ptr, "index_val");
            }
        },
        .tuple => |tuple_exprs| {
            const element_size: usize = 8;
            const size_val = core.LLVMConstInt(self.val_type, tuple_exprs.len * element_size, 0);

            const tuple_ptr_val = try self.compileAlloc(size_val);

            for (tuple_exprs, 0..) |te, idx| {
                const offset = core.LLVMConstInt(self.val_type, idx * element_size, 0);
                var val = try self.compileExpression(te);

                var widened = false;
                if (self.tupleElemTraitName(&expr, idx)) |trait_name| {
                    if (try self.resolveExpressionTypeName(&tuple_exprs[idx])) |st_name| {
                        if (self.structs.contains(st_name)) {
                            const orig = val;

                            self.consumeTemporary(orig);
                            val = try self.constructTraitObject(orig, st_name, trait_name);
                            self.consumeTemporary(val);

                            const stid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(&tuple_exprs[idx]) else null;
                            const sdtor = try self.getOrCreateDestructorPreferId(st_name, stid);
                            try self.compileRelease(orig, sdtor);
                            widened = true;
                        }
                    }
                }

                if (!widened and self.isOwnedExpr(&tuple_exprs[idx])) {
                    try self.takeOwnedElement(te.kind, val);
                }
                const addr = core.LLVMBuildAdd(self.builder, tuple_ptr_val, offset, "tuple_elem_addr");
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "tuple_elem_ptr");
                _ = core.LLVMBuildStore(self.builder, val, ptr);
            }

            return tuple_ptr_val;
        },

        .try_expr => |inner| {
            const box = try self.compileExpression(inner.*);
            const word: usize = 8;
            const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));

            const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "try_tag_ptr");
            const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "try_tag");
            const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "try_is_err");

            const prop_bb = core.LLVMAppendBasicBlock(cur_fn, "try_propagate");
            const cont_bb = core.LLVMAppendBasicBlock(cur_fn, "try_ok");
            _ = core.LLVMBuildCondBr(self.builder, is_err, prop_bb, cont_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, prop_bb);

            try self.runErrdefers();
            if (self.current_async_promise) |promise| {
                const rslot = self.coroPromiseResultSlot(promise);
                _ = core.LLVMBuildStore(self.builder, box, rslot);
                _ = core.LLVMBuildBr(self.builder, self.current_async_final_bb.?);
            } else {
                _ = core.LLVMBuildRet(self.builder, box);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
            const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "try_pay_addr");
            const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "try_pay_ptr");
            const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "try_pay");

            if (self.errUnionParts(try self.resolveExpressionTypeName(inner) orelse "")) |pp| {
                defer self.allocator.free(pp.ok);
                defer self.allocator.free(pp.err);
                if (self.isOwnedErrUnionOk(inner, pp.ok)) {
                    try self.compileRetain(payload);
                    try registerTemporary(self, payload, try self.allocator.dupe(u8, pp.ok));
                }
            }
            return payload;
        },

        .catch_expr => |ce| {
            const box = try self.compileExpression(ce.expr.*);
            const word: usize = 8;
            const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const slot = try spillTemp(self, core.LLVMConstInt(self.val_type, 0, 0));

            const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "c_tag_ptr");
            const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "c_tag");
            const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "c_is_err");
            const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "c_pay_addr");
            const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "c_pay_ptr");

            var parts_ok_refcounted = false;
            var parts_err_refcounted = false;
            var ok_is_valopt = false;
            if (self.errUnionParts(try self.resolveExpressionTypeName(ce.expr) orelse "")) |pp| {
                defer self.allocator.free(pp.ok);
                defer self.allocator.free(pp.err);
                parts_ok_refcounted = self.isOwnedErrUnionOk(ce.expr, pp.ok);
                parts_err_refcounted = self.isOwnedErrUnionErr(ce.expr, pp.err);
                ok_is_valopt = types_mod.valueOptionalName(pp.ok);
            }
            const err_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_err");
            const ok_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_ok");
            const done_bb = core.LLVMAppendBasicBlock(cur_fn, "catch_done");
            _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
            if (ce.err_name) |n| {
                var alloca_val = self.locals.get(n);
                if (alloca_val == null) {
                    const entry_bb = core.LLVMGetEntryBasicBlock(cur_fn);
                    const cur = core.LLVMGetInsertBlock(self.builder);
                    if (core.LLVMGetFirstInstruction(entry_bb)) |first| {
                        core.LLVMPositionBuilderBefore(self.builder, first);
                    } else core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
                    const nz = try self.allocator.dupeZ(u8, n);
                    defer self.allocator.free(nz);
                    const a = core.LLVMBuildAlloca(self.builder, self.val_type, nz.ptr);
                    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), a);
                    core.LLVMPositionBuilderAtEnd(self.builder, cur);
                    try self.locals.put(try self.allocator.dupe(u8, n), a);
                    alloca_val = a;
                    if (self.errUnionParts(try self.resolveExpressionTypeName(ce.expr) orelse "")) |pp| {
                        defer self.allocator.free(pp.ok);
                        defer self.allocator.free(pp.err);
                        if (self.current_local_types) |lt| {
                            try lt.put(try self.allocator.dupe(u8, n), try self.allocator.dupe(u8, pp.err));
                        }
                    }
                }
                const err_val = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "c_err");

                if (parts_err_refcounted) try self.compileRetain(err_val);
                _ = core.LLVMBuildStore(self.builder, err_val, alloca_val.?);
            }
            var hv = try self.compileExpression(ce.handler.*);
            if (ok_is_valopt and !LlvmCompiler.isUndefinedLiteralExpr(ce.handler) and !self.exprYieldsValoptBox(ce.handler)) {
                hv = try self.buildValoptBox(self.coerceToSlotType(hv, self.val_type));
            }
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(hv, self.val_type), slot);
                _ = core.LLVMBuildBr(self.builder, done_bb);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
            const okv = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "c_pay");

            if (parts_ok_refcounted) try self.compileRetain(okv);
            _ = core.LLVMBuildStore(self.builder, okv, slot);
            _ = core.LLVMBuildBr(self.builder, done_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
            const result = core.LLVMBuildLoad2(self.builder, self.val_type, slot, "catch_val");

            self.consumeTemporary(hv);
            return result;
        },
        .optional_chaining => |oc| {

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const obj_raw = self.coerceToSlotType(try self.compileExpression(oc.object.*), self.val_type);

            const obj_ptr = if (self.exprYieldsValoptBox(oc.object)) try self.buildValoptUnbox(obj_raw) else obj_raw;

            const field_bb = core.LLVMAppendBasicBlock(current_fn, "oc_field");
            const null_bb = core.LLVMAppendBasicBlock(current_fn, "oc_null");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "oc_merge");
            const present = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, obj_ptr, core.LLVMConstInt(self.val_type, 0, 0), "oc_present");
            _ = core.LLVMBuildCondBr(self.builder, present, field_bb, null_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, field_bb);
            const obj_type = (try self.resolveExpressionTypeName(oc.object)) orelse return error.StructTypeNotFound;
            const base_struct = getStructBaseName(obj_type);
            var field_type_ref = ast.TypeRef{ .ident = "i32" };
            if (self.structs.get(base_struct)) |s| {
                for (s.fields) |field| {
                    if (std.mem.eql(u8, field.name, oc.field)) {
                        field_type_ref = field.type_name;
                        break;
                    }
                }
            }
            const offset = try self.getFieldOffset(base_struct, oc.field);
            const addr = core.LLVMBuildAdd(self.builder, obj_ptr, core.LLVMConstInt(self.val_type, offset, 0), "oc_addr");
            const llvm_ft = self.toLLVMType(field_type_ref);
            const fptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_ft, 0), "oc_fptr");
            const raw = core.LLVMBuildLoad2(self.builder, llvm_ft, fptr, "oc_val");
            var field_val = self.coerceToSlotType(self.castToValType(raw, field_type_ref), self.val_type);

            const oc_tid = if (self.typed_ir) |ir| ir.typeOf(&expr) else null;
            if (oc_tid) |t| {
                if (self.valueOptionalInner(t) != null) field_val = try self.buildValoptBox(field_val);
            }
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const field_bb_end = core.LLVMGetInsertBlock(self.builder);

            core.LLVMPositionBuilderAtEnd(self.builder, null_bb);
            _ = core.LLVMBuildBr(self.builder, merge_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = core.LLVMBuildPhi(self.builder, self.val_type, "oc_phi");
            var iv = [_]types.LLVMValueRef{ field_val, core.LLVMConstInt(self.val_type, 0, 0) };
            var ib = [_]types.LLVMBasicBlockRef{ field_bb_end, null_bb };
            core.LLVMAddIncoming(phi, &iv, &ib, 2);
            return phi;
        },
        .nullish_coalesce => |nc| {
            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));

            const left_val = self.coerceToSlotType(try self.compileExpression(nc.left.*), self.val_type);

            const nc_is_valopt = self.exprYieldsValoptBox(nc.left);
            const left_present = if (nc_is_valopt) try self.buildValoptUnbox(left_val) else left_val;

            if (!nc_is_valopt and nc.left.kind == .ident and self.narrowed_present.contains(nc.left.kind.ident)) {
                if (self.type_store) |st| {
                    if (self.typeOfExprConcrete(nc.left)) |lt| {
                        const inner = self.valueOptionalInner(lt) orelse lt;
                        const iname = self.cachedTypeName(st, inner) catch "";
                        if (types_mod.isPrimitiveTypeName(iname)) {
                            return left_val;
                        }
                    }
                }
            }

            const left_bb_end = core.LLVMGetInsertBlock(self.builder);

            const nested_valopt_peel = nc_is_valopt and blk: {
                const lt = self.typeOfExprConcrete(nc.left) orelse break :blk false;
                const inner_tid = self.valueOptionalInner(lt) orelse break :blk false;
                break :blk self.valueOptionalInner(inner_tid) != null;
            };

            const rhs_bb = core.LLVMAppendBasicBlock(current_fn, "nc_rhs");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "nc_merge");
            const present_bb = if (nested_valopt_peel) core.LLVMAppendBasicBlock(current_fn, "nc_present") else null;

            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, left_val, core.LLVMConstInt(self.val_type, 0, 0), "is_not_null");
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, present_bb orelse merge_bb, rhs_bb);

            var left_incoming_bb = left_bb_end;
            if (present_bb) |pbb| {
                core.LLVMPositionBuilderAtEnd(self.builder, pbb);
                try self.compileRetain(left_present);
                _ = core.LLVMBuildBr(self.builder, merge_bb);
                left_incoming_bb = core.LLVMGetInsertBlock(self.builder);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, rhs_bb);
            var rhs_val = self.coerceToSlotType(try self.compileExpression(nc.right.*), self.val_type);

            if (try self.resolveExpressionTypeName(nc.left)) |lt| {
                if (self.traits.contains(lt)) {
                    if (try self.resolveExpressionTypeName(nc.right)) |rt| {
                        if (self.structs.contains(rt)) {
                            rhs_val = try self.constructTraitObject(rhs_val, rt, lt);
                        }
                    }
                }
            }

            if (nested_valopt_peel and
                !LlvmCompiler.isUndefinedLiteralExpr(nc.right) and
                !self.exprYieldsValoptBox(nc.right))
            {
                rhs_val = try self.buildValoptBox(self.coerceToSlotType(rhs_val, self.val_type));
            }

            if (!nc_is_valopt and namesExistingOwner(nc.right.kind) and self.isOwnedExpr(nc.right)) {
                try self.compileRetain(rhs_val);
            }
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            const rhs_bb_end = core.LLVMGetInsertBlock(self.builder);

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = core.LLVMBuildPhi(self.builder, self.val_type, "nc_phi");
            var incoming_vals = [_]types.LLVMValueRef{ left_present, rhs_val };
            var incoming_bbs = [_]types.LLVMBasicBlockRef{ left_incoming_bb, rhs_bb_end };
            core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

            if (!nc_is_valopt) {
                if (namesExistingOwner(nc.left.kind) and self.isOwnedExpr(nc.left)) {

                    try self.compileRetain(left_val);
                } else {
                    self.consumeTemporary(left_val);
                }

                if (!(namesExistingOwner(nc.right.kind) and self.isOwnedExpr(nc.right))) {
                    self.consumeTemporary(rhs_val);
                }
            }

            return phi;
        },
        .jsx_element => |jsx| {
            return try self.compileJsxElement(jsx);
        },
        .block_expr => |be| {
            const func = FunctionInfo{
                .name = self.current_function_name orelse "main",
                .param_count = 0,
                .param_names = &[_][]const u8{},
                .return_type = "void",
                .body = ast.Block{ .statements = &[_]ast.Statement{}, .span = be.span },
            };
            try self.scopes.append(self.allocator, Scope{ .deferred_statements = std.ArrayList(ast.Expression).empty });
            for (be.statements) |s| {
                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
                    break;
                }
                try self.compileStatement(s, func);
            }
            var scope = self.scopes.pop().?;
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                var idx = scope.deferred_statements.items.len;
                while (idx > 0) {
                    idx -= 1;
                    _ = try self.compileExpression(scope.deferred_statements.items[idx]);
                }
            }
            scope.deferred_statements.deinit(self.allocator);
            return core.LLVMConstInt(self.val_type, 0, 0);
        },
        .template_expr => |te| {
            if (te.parts.len == 1 and te.parts[0].kind != .block_expr) {
                if (self.typed_ir) |ir| {
                    if (self.type_store) |st| {
                        const part0 = te.parts[0];
                        if (ir.typeOf(&part0)) |tid| {
                            switch (st.get(tid)) {
                                .prim => {
                                    const v = try self.compileExpression(part0);
                                    if (try self.numToStringT(v, tid)) |s| return s;
                                },
                                .decimal => {
                                    const v = try self.compileExpression(part0);
                                    const to_fn = self.func_map.get("nova_decimal_to_string").?;
                                    const to_t = core.LLVMGlobalGetValueType(to_fn);
                                    var da = [_]types.LLVMValueRef{v};
                                    return core.LLVMBuildCall2(self.builder, to_t, to_fn, &da, 1, "dec_to_str");
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
            const sb_new = self.getFunc("StringBuilder_init") orelse {
                std.debug.print("Error: 'StringBuilder_init' not found. Make sure to import collections/string_builder.\n", .{});
                return error.StringBuilderNewNotFound;
            };
            const sb_toString = self.getFunc("StringBuilder_toString") orelse {
                std.debug.print("Error: 'StringBuilder_toString' not found.\n", .{});
                return error.StringBuilderToStringNotFound;
            };
            const sb_delete = self.getFunc("StringBuilder_delete") orelse {
                std.debug.print("Error: 'StringBuilder_delete' not found.\n", .{});
                return error.StringBuilderDeleteNotFound;
            };

            const sb_size = self.getTypeSize(ast.TypeRef{ .ident = "StringBuilder" }, false);
            const sb_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, sb_size, 0));
            const sb_new_t = core.LLVMGlobalGetValueType(sb_new);
            var sb_args = [_]types.LLVMValueRef{sb_val};
            _ = core.LLVMBuildCall2(self.builder, sb_new_t, sb_new, &sb_args, 1, "");

            const outer_sb = self.current_string_builder;
            self.current_string_builder = sb_val;
            defer self.current_string_builder = outer_sb;

            for (te.parts) |*part| {
                if (part.kind == .block_expr) {
                    _ = try self.compileExpression(part.*);
                } else {
                    const val = try self.compileExpression(part.*);
                    const expr_type = try self.resolveExpressionTypeName(part);
                    try self.compileAppendToStringBuilder(sb_val, val, expr_type, part.*);
                }
            }

            const sb_toString_t = core.LLVMGlobalGetValueType(sb_toString);
            var toString_args = [_]types.LLVMValueRef{sb_val};
            const final_str = core.LLVMBuildCall2(self.builder, sb_toString_t, sb_toString, &toString_args, 1, "final_str");

            const sb_delete_t = core.LLVMGlobalGetValueType(sb_delete);
            _ = core.LLVMBuildCall2(self.builder, sb_delete_t, sb_delete, &toString_args, 1, "");

            try self.compileRelease(sb_val, null);

            return final_str;
        },
        .cast => |c| {
            var val = try self.compileExpression(c.expr.*);
            const target = try self.typeRefToString(c.target_type);
            const src_opt = try self.resolveExpressionTypeName(c.expr);

            if (src_opt) |src| {
                if (std.mem.eql(u8, src, "any") and !std.mem.eql(u8, target, "any")) {
                    val = try self.buildAnyUnbox(self.coerceToSlotType(val, self.val_type));
                    if (self.ownedByName(target) or self.isStructType(target) or self.traits.contains(target)) {
                        try self.compileRetain(val);
                        try registerTemporary(self, val, try self.allocator.dupe(u8, target));
                    }
                    return val;
                }
            }

            if (src_opt) |src| {
                if (self.traits.contains(src) and self.isStructType(target)) {
                    const ptr_size = @as(u64, 8);
                    const vt_addr = core.LLVMBuildAdd(self.builder, val, core.LLVMConstInt(self.val_type, ptr_size, 0), "downcast_vt_addr");
                    const vt_ptr = core.LLVMBuildIntToPtr(self.builder, vt_addr, core.LLVMPointerType(self.val_type, 0), "downcast_vt_ptr");
                    const actual_vt = core.LLVMBuildLoad2(self.builder, self.val_type, vt_ptr, "downcast_actual_vt");
                    const expected_vt_global = try self.getGlobalVTable(getStructBaseName(target), getStructBaseName(src));
                    const expected_vt = core.LLVMBuildPtrToInt(self.builder, expected_vt_global, self.val_type, "downcast_expected_vt");
                    const mismatch = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, actual_vt, expected_vt, "downcast_bad");
                    self.emitTrapIf(mismatch, "invalid downcast: trait object is not the target concrete type");

                    const sp_ptr = core.LLVMBuildIntToPtr(self.builder, val, core.LLVMPointerType(self.val_type, 0), "downcast_sp_ptr");
                    const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "downcast_struct_ptr");

                    try self.compileRetain(struct_ptr);
                    try registerTemporary(self, struct_ptr, try self.allocator.dupe(u8, target));
                    return struct_ptr;
                }
            }

            var result = val;
            if (!self.is_wasm) {
                const isFloatName = struct {
                    fn f(n: []const u8) bool {
                        return std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "double") or
                            std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "float");
                    }
                }.f;
                const target_is_float = isFloatName(target);
                const src_is_float = if (src_opt) |s| isFloatName(s) else false;
                if (src_is_float and !target_is_float) {

                    const dbl = core.LLVMBuildBitCast(self.builder, val, core.LLVMDoubleType(), "cast_f2i_dbl");
                    result = core.LLVMBuildFPToSI(self.builder, dbl, self.val_type, "cast_f2i");
                } else if (!src_is_float and target_is_float) {

                    const dbl = core.LLVMBuildSIToFP(self.builder, val, core.LLVMDoubleType(), "cast_i2f");
                    return core.LLVMBuildBitCast(self.builder, dbl, self.val_type, "cast_i2f_val");
                }

                if (types_mod.cgPrim(target)) |p| {
                    const is_int_repr = p.repr == .i8 or p.repr == .i16 or p.repr == .i32 or
                        p.repr == .word or p.repr == .i64;
                    if (is_int_repr) {
                        const w = types_mod.reprBitWidth(p.repr);
                        if (w < 64) result = self.canonicalizeInt(result, w, p.signed);
                    }
                }
            }
            return result;
        },
        .await_expr => |aw| {
            return try self.buildAwait(aw);
        },
        .go_expr => |g| {
            return try self.buildGo(g, false);
        },
        else => {
            std.debug.print("Expression type not supported in LLVM yet: {s}\n", .{@tagName(expr.kind)});
            return error.UnsupportedExpression;
        },
    }
}

/// Whether a type name denotes a floating-point type (`f64`/`double`/`f32`/
/// `float`), used to pick float vs integer codegen paths.
fn isFloatTypeName(n: []const u8) bool {
    return std.mem.eql(u8, n, "f64") or std.mem.eql(u8, n, "double") or
        std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "float");
}

/// The result width and signedness chosen for a binary integer operation.
const IntOpKind = struct { width: u32, signed: bool };
/// Computes the width/signedness a binary integer op should be performed at from
/// its two operand type names, or null if neither side is a supported integer.
///
/// Only sized integer reprs (i8/i16/i32/word/i64) qualify; floats/decimals/etc
/// return null. When both sides qualify the wider one wins, and on a tie the
/// result is unsigned only if BOTH operands are unsigned. This drives
/// [`canonicalizeInt`] (truncation/extension back to the value word) and the
/// division guards so integer arithmetic wraps at the intended width. Note that
/// `int` is 32-bit here, per the language's integer model.
fn intOpKind(left_name: ?[]const u8, right_name: ?[]const u8) ?IntOpKind {
    const kindOf = struct {
        fn f(name: ?[]const u8) ?IntOpKind {
            const n = name orelse return null;
            const p = types_mod.cgPrim(n) orelse return null;

            if (!(p.repr == .i8 or p.repr == .i16 or p.repr == .i32 or p.repr == .word or p.repr == .i64)) return null;
            return .{ .width = types_mod.reprBitWidth(p.repr), .signed = p.signed };
        }
    }.f;
    const l = kindOf(left_name);
    const r = kindOf(right_name);
    if (l == null and r == null) return null;
    if (l == null) return r;
    if (r == null) return l;
    const lk = l.?;
    const rk = r.?;
    if (lk.width > rk.width) return lk;
    if (rk.width > lk.width) return rk;

    return .{ .width = lk.width, .signed = lk.signed and rk.signed };
}

/// Whether a type name is a 64-bit integer (`long`/`ulong`/`i64`/`u64`), i.e.
/// already the full value-word width so no truncation/extension is needed.
fn isWideIntTypeName(n: []const u8) bool {
    return std.mem.eql(u8, n, "long") or std.mem.eql(u8, n, "ulong") or
        std.mem.eql(u8, n, "i64") or std.mem.eql(u8, n, "u64");
}

/// Emits a conditional runtime trap: if `cond` is true, panic with `msg` and
/// become `unreachable`, otherwise continue.
///
/// Splits the current block into a panic block (calls `nova_panic_cstr` with the
/// message then `unreachable`) and a continue block, leaving the builder on the
/// continue block. The generic building block behind the division and overflow
/// guards ([`emitIntDivGuard`]).
pub fn emitTrapIf(self: *LlvmCompiler, cond: types.LLVMValueRef, msg: [:0]const u8) void {
    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
    const panic_bb = core.LLVMAppendBasicBlock(cur_fn, "trap_panic");
    const cont_bb = core.LLVMAppendBasicBlock(cur_fn, "trap_ok");
    _ = core.LLVMBuildCondBr(self.builder, cond, panic_bb, cont_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, panic_bb);
    const cstr = core.LLVMBuildGlobalString(self.builder, msg.ptr, "trap_msg");
    const cstr_ptr = core.LLVMBuildBitCast(self.builder, cstr, self.ptr_type, "trap_msg_ptr");
    if (self.func_map.get("nova_panic_cstr")) |pf| {
        const pt = core.LLVMGlobalGetValueType(pf);
        var args = [_]types.LLVMValueRef{cstr_ptr};
        _ = core.LLVMBuildCall2(self.builder, pt, pf, &args, 1, "");
    }
    _ = core.LLVMBuildUnreachable(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
}

/// Emits the pre-division safety checks: trap on divide-by-zero, and on the
/// `INT_MIN / -1` overflow for wide signed division.
///
/// Always guards `r_val == 0`. When `signed and width >= 64` it also guards the
/// single overflowing signed case (`INT64_MIN / -1`), which is UB in LLVM's
/// `sdiv`. Both use [`emitTrapIf`]. Narrower widths cannot hit the overflow case
/// once operands are canonicalised, so only the zero check applies there.
pub fn emitIntDivGuard(self: *LlvmCompiler, l_val: types.LLVMValueRef, r_val: types.LLVMValueRef, signed: bool, width: u32, zero_msg: [:0]const u8, ovf_msg: [:0]const u8) void {
    const zero = core.LLVMConstInt(self.val_type, 0, 0);
    const is_zero = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, r_val, zero, "div_zero");
    self.emitTrapIf(is_zero, zero_msg);

    if (signed and width >= 64) {
        const imin = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, std.math.minInt(i64))), 0);
        const neg1 = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, -1)), 0);
        const l_is_min = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, l_val, imin, "div_lmin");
        const r_is_neg1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, r_val, neg1, "div_rneg1");
        const ovf = core.LLVMBuildAnd(self.builder, l_is_min, r_is_neg1, "div_ovf");
        self.emitTrapIf(ovf, ovf_msg);
    }
}

/// Normalises an integer result back into the value word by truncating to
/// `width` and re-extending, giving correct wraparound and sign for narrow
/// types.
///
/// Nova arithmetic is done in the 64-bit word, but a narrower type must observe
/// its own overflow behaviour, so after an op the result is truncated to
/// `width` and then sign- or zero-extended per `signed`. Widths of 64 or more
/// are already full-width and returned unchanged. This is what makes `int`
/// (32-bit) arithmetic wrap at 32 bits despite the wider representation.
pub fn canonicalizeInt(self: *LlvmCompiler, val: types.LLVMValueRef, width: u32, signed: bool) types.LLVMValueRef {
    if (width >= 64) return val;
    const iw = core.LLVMIntType(width);
    const truncd = core.LLVMBuildTrunc(self.builder, val, iw, "int_trunc");
    return if (signed)
        core.LLVMBuildSExt(self.builder, truncd, self.val_type, "int_sext")
    else
        core.LLVMBuildZExt(self.builder, truncd, self.val_type, "int_zext");
}

/// Converts a numeric value word to a Nova string by calling the matching
/// runtime formatter.
///
/// Routes to `nova_f64_to_string` (bit-casting the word to a double first),
/// `nova_bool_to_string`, or `nova_i64_to_string` per the two flags. Returns
/// `error.HelperNotFound` if the runtime formatter is not linked. The
/// name-driven and TypeId-driven wrappers ([`numToString`], [`numToStringT`])
/// pick the flags.
pub fn numToStringImpl(self: *LlvmCompiler, val: types.LLVMValueRef, is_float: bool, is_bool: bool) !types.LLVMValueRef {
    if (is_float) {
        const f = self.func_map.get("nova_f64_to_string") orelse return error.HelperNotFound;
        const ft = core.LLVMGlobalGetValueType(f);
        const dbl = core.LLVMBuildBitCast(self.builder, val, core.LLVMDoubleType(), "concat_f2d");
        var a = [_]types.LLVMValueRef{dbl};
        return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "f64_str");
    }
    if (is_bool) {
        const f = self.func_map.get("nova_bool_to_string") orelse return error.HelperNotFound;
        const ft = core.LLVMGlobalGetValueType(f);
        var a = [_]types.LLVMValueRef{val};
        return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "bool_str");
    }
    const f = self.func_map.get("nova_i64_to_string") orelse return error.HelperNotFound;
    const ft = core.LLVMGlobalGetValueType(f);
    var a = [_]types.LLVMValueRef{val};
    return core.LLVMBuildCall2(self.builder, ft, f, &a, 1, "i64_str");
}

/// Stringifies a numeric value given its type NAME, deriving the float/bool
/// flags for [`numToStringImpl`].
///
/// A null or unrecognised `type_name` defaults to the signed-integer path.
pub fn numToString(self: *LlvmCompiler, val: types.LLVMValueRef, type_name: ?[]const u8) !types.LLVMValueRef {
    const is_float = if (type_name) |tn| isFloatTypeName(tn) else false;
    const is_bool = if (type_name) |tn| std.mem.eql(u8, tn, "bool") else false;
    return self.numToStringImpl(val, is_float, is_bool);
}

/// Stringifies a numeric value given its typed-IR `TypeId`, returning null when
/// the type is not a stringifiable primitive.
///
/// The TypeId-precise counterpart to [`numToString`]: dispatches on the
/// primitive kind (float/bool/int) and returns null for `void` or any
/// non-primitive, letting the caller fall back to another append path. Used in
/// string interpolation ([`compileAppendToStringBuilder`]).
pub fn numToStringT(self: *LlvmCompiler, val: types.LLVMValueRef, tid: sema_types.TypeId) !?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    switch (st.get(tid)) {
        .prim => |p| switch (p.kind) {
            .void_ => return null,
            .float => return try self.numToStringImpl(val, true, false),
            .bool => return try self.numToStringImpl(val, false, true),
            .int => return try self.numToStringImpl(val, false, false),
        },
        else => return null,
    }
}

/// Lowers an optional-chaining METHOD call `obj?.m(args)`: call the method only
/// when the receiver is present, else yield null.
///
/// Resolves the method on the optional's inner struct type (trying the exact
/// mangled name and a lowercased fallback), then emits a present/null diamond:
/// on present it calls the method with the unwrapped receiver and re-boxes a
/// value-optional result if needed; on null it produces the zero word; a phi
/// merges them. Returns null (not handled here) if the callee is not optional
/// chaining or the method cannot be resolved. Compare optional-chaining FIELD
/// access, which is handled inside [`compileExpressionInner`].
pub fn compileOptionalMethodCall(self: *LlvmCompiler, call: ast.CallExpr, expr_ptr: *const ast.Expression) anyerror!?types.LLVMValueRef {
    const oc = call.callee.kind.optional_chaining;
    const st = self.type_store orelse return null;

    const obj_tid = self.typeOfExprConcrete(oc.object) orelse return null;
    const obj_info = st.get(obj_tid);
    const inner_tid = if (obj_info == .optional) obj_info.optional else return null;
    const inner_name = sema_shadow.renderLegacy(self.allocator, st, inner_tid) catch return null;
    const base = getStructBaseName(inner_name);

    const method_fn = blk: {
        const exact = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base, oc.field }) catch return null;
        defer self.allocator.free(exact);
        if (self.func_map.get(exact)) |f| break :blk f;
        const lower = self.allocator.alloc(u8, base.len) catch return null;
        defer self.allocator.free(lower);
        _ = std.ascii.lowerString(lower, base);
        const lname = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ lower, oc.field }) catch return null;
        defer self.allocator.free(lname);
        if (self.func_map.get(lname)) |f| break :blk f;
        break :blk null;
    } orelse return null;

    const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));

    const obj_raw = self.coerceToSlotType(try self.compileExpression(oc.object.*), self.val_type);

    const present_bb = core.LLVMAppendBasicBlock(cur_fn, "ocm_present");
    const null_bb = core.LLVMAppendBasicBlock(cur_fn, "ocm_null");
    const merge_bb = core.LLVMAppendBasicBlock(cur_fn, "ocm_merge");
    const present = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, obj_raw, core.LLVMConstInt(self.val_type, 0, 0), "ocm_present_c");
    _ = core.LLVMBuildCondBr(self.builder, present, present_bb, null_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, present_bb);
    const nargs = call.args.len + 1;
    const args = try self.allocator.alloc(types.LLVMValueRef, nargs);
    defer self.allocator.free(args);
    args[0] = obj_raw;
    for (call.args, 0..) |*a, i| {
        args[i + 1] = self.coerceToSlotType(try self.compileCallArgument(a.*), self.val_type);
    }
    const fn_t = core.LLVMGlobalGetValueType(method_fn);
    var res = core.LLVMBuildCall2(self.builder, fn_t, method_fn, args.ptr, @intCast(nargs), "ocm_call");
    if (self.typeOfExprConcrete(expr_ptr)) |et| {
        if (self.valueOptionalInner(et) != null) res = try self.buildValoptBox(self.coerceToSlotType(res, self.val_type));
    }
    _ = core.LLVMBuildBr(self.builder, merge_bb);
    const present_end = core.LLVMGetInsertBlock(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, null_bb);
    _ = core.LLVMBuildBr(self.builder, merge_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
    const phi = core.LLVMBuildPhi(self.builder, self.val_type, "ocm_phi");
    var iv = [_]types.LLVMValueRef{ res, core.LLVMConstInt(self.val_type, 0, 0) };
    var ib = [_]types.LLVMBasicBlockRef{ present_end, null_bb };
    core.LLVMAddIncoming(phi, &iv, &ib, 2);
    return phi;
}

/// Appends one interpolation part `val` to a `StringBuilder`, formatting it
/// according to its type.
///
/// This is the per-part backend of template/`${}` string interpolation. When
/// the typed IR knows the part's type it formats precisely: a string is
/// appended directly; a primitive is stringified via [`numToStringT`] (and the
/// temporary string released); a decimal via `nova_decimal_to_string`; an
/// optional emits a present/absent diamond that appends the inner value or the
/// literal `undefined`. Falling back to the `expr_type_opt` name handles the
/// no-typed-IR case, and anything else is appended as a raw string value. Each
/// synthesised temporary string is released to keep ARC balanced.
pub fn compileAppendToStringBuilder(self: *LlvmCompiler, sb_val: types.LLVMValueRef, val: types.LLVMValueRef, expr_type_opt: ?[]const u8, opt_part: ?ast.Expression) !void {
    const sb_append = self.func_map.get("StringBuilder_append") orelse {
        std.debug.print("Error: 'StringBuilder_append' not found.\n", .{});
        return error.StringBuilderAppendNotFound;
    };
    const sb_append_t = core.LLVMGlobalGetValueType(sb_append);

    if (opt_part) |part| {
        if (self.typed_ir) |ir| {
            if (self.type_store) |st| {
                if (ir.typeOf(&part)) |tid| {
                    switch (st.get(tid)) {
                        .string => {
                            var args = [_]types.LLVMValueRef{ sb_val, val };
                            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                            return;
                        },

                        .prim => {
                            if (try self.numToStringT(val, tid)) |str_temp| {
                                var args = [_]types.LLVMValueRef{ sb_val, str_temp };
                                _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                                try self.compileRelease(str_temp, null);
                                return;
                            }
                        },

                        .decimal => {
                            const to_fn = self.func_map.get("nova_decimal_to_string").?;
                            const to_t = core.LLVMGlobalGetValueType(to_fn);
                            var da = [_]types.LLVMValueRef{val};
                            const str_temp = core.LLVMBuildCall2(self.builder, to_t, to_fn, &da, 1, "dec_to_str");
                            var args = [_]types.LLVMValueRef{ sb_val, str_temp };
                            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
                            try self.compileRelease(str_temp, null);
                            return;
                        },

                        .optional => {
                            const cur = core.LLVMGetInsertBlock(self.builder);
                            const func = core.LLVMGetBasicBlockParent(cur);
                            const present_bb = core.LLVMAppendBasicBlock(func, "interp_opt_present");
                            const absent_bb = core.LLVMAppendBasicBlock(func, "interp_opt_absent");
                            const merge_bb = core.LLVMAppendBasicBlock(func, "interp_opt_done");
                            const is_null = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, val, core.LLVMConstInt(self.val_type, 0, 0), "interp_opt_null");
                            _ = core.LLVMBuildCondBr(self.builder, is_null, absent_bb, present_bb);

                            core.LLVMPositionBuilderAtEnd(self.builder, present_bb);
                            if (self.valueOptionalInner(tid)) |inner_tid| {
                                const inner_val = try self.buildValoptUnbox(val);
                                if (try self.numToStringT(inner_val, inner_tid)) |str_temp| {
                                    var pa = [_]types.LLVMValueRef{ sb_val, str_temp };
                                    _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &pa, 2, "");
                                    try self.compileRelease(str_temp, null);
                                }
                            } else if (st.get(st.get(tid).optional) == .string) {
                                var pa = [_]types.LLVMValueRef{ sb_val, val };
                                _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &pa, 2, "");
                            }
                            _ = core.LLVMBuildBr(self.builder, merge_bb);

                            core.LLVMPositionBuilderAtEnd(self.builder, absent_bb);
                            const undef_str = try self.getOrCreateStringLiteral("undefined");
                            var aa = [_]types.LLVMValueRef{ sb_val, undef_str };
                            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &aa, 2, "");
                            _ = core.LLVMBuildBr(self.builder, merge_bb);

                            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
                            return;
                        },

                        else => {},
                    }
                }
            }
        }
    }

    if (expr_type_opt) |t| {
        if (std.mem.eql(u8, t, "string")) {
            var args = [_]types.LLVMValueRef{ sb_val, val };
            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
            return;
        } else if (types_mod.isPrimitiveTypeName(t) and !std.mem.eql(u8, t, "void") and !std.mem.eql(u8, t, "any")) {

            const str_temp = try self.numToString(val, t);
            var args = [_]types.LLVMValueRef{ sb_val, str_temp };
            _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
            try self.compileRelease(str_temp, null);
            return;
        }
    }

    var args = [_]types.LLVMValueRef{ sb_val, val };
    _ = core.LLVMBuildCall2(self.builder, sb_append_t, sb_append, &args, 2, "");
}

/// Sets the current debug source location from a JSX node's span (when it has a
/// real line), so emitted JSX maps back to source in a debugger.
pub fn jsxSetLoc(self: *LlvmCompiler, span: ast.Span) void {
    if (span.line > 0) self.setDebugLoc(span.line, span.col);
}

/// Appends a compiled string value to a JSX `StringBuilder` via
/// `StringBuilder_append`.
///
/// The lowest-level JSX emit step; higher-level helpers buffer literals and
/// escape dynamic values before calling this.
pub fn jsxAppendVal(self: *LlvmCompiler, sb: types.LLVMValueRef, val: types.LLVMValueRef) !void {
    const sb_append = self.getFunc("StringBuilder_append") orelse return error.StringBuilderAppendNotFound;
    const append_t = core.LLVMGlobalGetValueType(sb_append);
    var args = [_]types.LLVMValueRef{ sb, val };
    _ = core.LLVMBuildCall2(self.builder, append_t, sb_append, &args, 2, "");
}

/// Buffers static JSX text into `jsx_pending_literal` instead of emitting it
/// immediately.
///
/// Adjacent literal chunks (tags, attribute punctuation, plain text) accumulate
/// so they are emitted as ONE append by [`jsxFlushLiteral`], cutting the number
/// of runtime append calls. `sb` is unused (the buffer is compiler-side).
pub fn jsxAppendLiteral(self: *LlvmCompiler, sb: types.LLVMValueRef, text: []const u8) !void {
    _ = sb;
    try self.jsx_pending_literal.appendSlice(self.allocator, text);
}

/// Flushes the accumulated JSX literal buffer as a single string append, if
/// non-empty, and clears it.
///
/// Must be called before appending any dynamic value or closing a coalesced run
/// so literal and dynamic content stay in order. Compiles the buffered bytes as
/// a string literal and appends via [`jsxAppendVal`].
pub fn jsxFlushLiteral(self: *LlvmCompiler, sb: types.LLVMValueRef) !void {
    if (self.jsx_pending_literal.items.len == 0) return;
    const expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.jsx_pending_literal.items } } };
    const str_val = try self.compileExpression(expr);
    try self.jsxAppendVal(sb, str_val);
    self.jsx_pending_literal.clearRetainingCapacity();
}

/// Flushes buffered literals, then appends a dynamic JSX expression with the
/// correct HTML escaping for its type.
///
/// A `string` is HTML-escaped into the builder via `web_response_escapeHtmlInto`
/// (falling back to a raw append if that helper is absent); a `Str` view uses
/// the view variant; a primitive is stringified (and the temp released) and
/// appended without escaping. This escaping is the XSS boundary for interpolated
/// hypermedia content. Anything else is appended raw.
pub fn jsxAppendExpr(self: *LlvmCompiler, sb: types.LLVMValueRef, expr: *const ast.Expression) !void {
    try self.jsxFlushLiteral(sb);
    const val = try self.compileExpression(expr.*);
    const type_name = try self.resolveExpressionTypeName(expr);
    if (type_name) |t| {
        if (std.mem.eql(u8, t, "string")) {
            if (self.getFunc("web_response_escapeHtmlInto")) |escInto| {
                const escInto_t = core.LLVMGlobalGetValueType(escInto);
                var ea = [_]types.LLVMValueRef{ sb, self.coerceToSlotType(val, self.val_type) };
                _ = core.LLVMBuildCall2(self.builder, escInto_t, escInto, &ea, 2, "");
            } else {
                try self.jsxAppendVal(sb, val);
            }
            return;
        } else if (std.mem.eql(u8, t, "Str")) {
            if (self.getFunc("web_response_escapeHtmlIntoView")) |escView| {
                const escView_t = core.LLVMGlobalGetValueType(escView);
                var ea = [_]types.LLVMValueRef{ sb, val };
                _ = core.LLVMBuildCall2(self.builder, escView_t, escView, &ea, 2, "");
            } else {
                try self.jsxAppendVal(sb, val);
            }
            return;
        } else if (types_mod.isPrimitiveTypeName(t) and !std.mem.eql(u8, t, "void") and !std.mem.eql(u8, t, "any")) {
            const str_temp = try self.numToString(val, t);
            try self.jsxAppendVal(sb, str_temp);
            try self.compileRelease(str_temp, null);
            return;
        }
    }
    try self.jsxAppendVal(sb, val);
}

/// Recursively serialises a JSX element tree into a `StringBuilder`, emitting
/// tags, attributes, children, and embedded expressions/statements.
///
/// Sets `current_string_builder` to `sb_val` for the duration so nested lowering
/// knows where to append. Writes `<tag`, each attribute (`name="..."` with a
/// string literal or an escaped dynamic expression), then either self-closes
/// (`/>`) when there are no children or writes `>`, the children (text,
/// sub-elements recursed into, escaped expressions, or embedded statements
/// lowered against a synthetic [`FunctionInfo`]), and the closing tag. Literal
/// runs are buffered and flushed via [`jsxAppendLiteral`]/[`jsxFlushLiteral`];
/// debug builds flush at element boundaries so source locations stay precise.
pub fn emitJsxInto(self: *LlvmCompiler, sb_val: types.LLVMValueRef, jsx: ast.JsxElement) anyerror!void {
    const outer_sb = self.current_string_builder;
    self.current_string_builder = sb_val;
    defer self.current_string_builder = outer_sb;

    if (self.debug_enabled) try self.jsxFlushLiteral(sb_val);
    self.jsxSetLoc(jsx.span);

    const tag_open = try std.fmt.allocPrint(self.allocator, "<{s}", .{jsx.tag});
    defer self.allocator.free(tag_open);
    try self.jsxAppendLiteral(sb_val, tag_open);

    for (jsx.attributes) |attr| {
        const attr_prefix = try std.fmt.allocPrint(self.allocator, " {s}=\"", .{attr.name});
        defer self.allocator.free(attr_prefix);
        try self.jsxAppendLiteral(sb_val, attr_prefix);
        switch (attr.value) {
            .string_literal => |lit| try self.jsxAppendLiteral(sb_val, lit),
            .expression => |*expr| {
                self.jsxSetLoc(expr.span);
                try self.jsxAppendExpr(sb_val, expr);
                self.jsxSetLoc(jsx.span);
            },
        }
        try self.jsxAppendLiteral(sb_val, "\"");
    }

    if (jsx.children.len == 0) {
        try self.jsxAppendLiteral(sb_val, "/>");
        if (self.debug_enabled) try self.jsxFlushLiteral(sb_val);
        return;
    }
    try self.jsxAppendLiteral(sb_val, ">");
    if (self.debug_enabled) try self.jsxFlushLiteral(sb_val);
    for (jsx.children) |child| {
        switch (child) {
            .text => |txt| try self.jsxAppendLiteral(sb_val, txt),
            .element => |sub_el| try self.emitJsxInto(sb_val, sub_el),
            .expression => |*expr| {
                self.jsxSetLoc(expr.span);
                try self.jsxAppendExpr(sb_val, expr);
            },
            .statement => |stmt| {
                try self.jsxFlushLiteral(sb_val);
                const dummy_func = FunctionInfo{
                    .name = self.current_function_name orelse "main",
                    .param_count = 0,
                    .param_names = &[_][]const u8{},
                    .return_type = "void",
                    .body = ast.Block{ .statements = &[_]ast.Statement{}, .span = ast.Span{ .file = "", .line = 0, .col = 0, .start = 0, .end = 0 } },
                };
                try self.compileStatement(stmt, dummy_func);
            },
        }
    }
    self.jsxSetLoc(jsx.span);
    const tag_close = try std.fmt.allocPrint(self.allocator, "</{s}>", .{jsx.tag});
    defer self.allocator.free(tag_close);
    try self.jsxAppendLiteral(sb_val, tag_close);
}

/// Lowers a JSX element EXPRESSION to a freshly built HTML string value.
///
/// Allocates and initialises a `StringBuilder`, serialises the tree into it via
/// [`emitJsxInto`], flushes any trailing literal, calls `toString` to snapshot
/// the result, then deletes and releases the builder. The returned string is
/// the value of the JSX expression. Requires the collections/string_builder std
/// module to be imported (errors clearly otherwise).
pub fn compileJsxElement(self: *LlvmCompiler, jsx: ast.JsxElement) anyerror!types.LLVMValueRef {
    const sb_new = self.getFunc("StringBuilder_init") orelse {
        std.debug.print("Error: 'StringBuilder_init' not found. Make sure to import collections/string_builder.\n", .{});
        return error.StringBuilderNewNotFound;
    };
    const sb_toString = self.getFunc("StringBuilder_toString") orelse {
        std.debug.print("Error: 'StringBuilder_toString' not found.\n", .{});
        return error.StringBuilderToStringNotFound;
    };
    const sb_delete = self.getFunc("StringBuilder_delete") orelse {
        std.debug.print("Error: 'StringBuilder_delete' not found.\n", .{});
        return error.StringBuilderDeleteNotFound;
    };

    const sb_size = self.getTypeSize(ast.TypeRef{ .ident = "StringBuilder" }, false);
    const sb_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, sb_size, 0));
    const sb_new_t = core.LLVMGlobalGetValueType(sb_new);
    var sb_args = [_]types.LLVMValueRef{sb_val};
    _ = core.LLVMBuildCall2(self.builder, sb_new_t, sb_new, &sb_args, 1, "");

    try self.emitJsxInto(sb_val, jsx);
    try self.jsxFlushLiteral(sb_val);

    const sb_toString_t = core.LLVMGlobalGetValueType(sb_toString);
    var toString_args = [_]types.LLVMValueRef{sb_val};
    const final_str = core.LLVMBuildCall2(self.builder, sb_toString_t, sb_toString, &toString_args, 1, "final_str");

    const sb_delete_t = core.LLVMGlobalGetValueType(sb_delete);
    _ = core.LLVMBuildCall2(self.builder, sb_delete_t, sb_delete, &toString_args, 1, "");

    try self.compileRelease(sb_val, null);

    return final_str;
}

/// Lowers a typed NovaDB query `conn.query<T>(sql, params)` into a call that
/// decodes each result row into a `T`.
///
/// Synthesises (once per `T`, cached by name) a `decode_binary_row_<T>` function
/// whose body is [`compileDecodeBinaryRow`], then passes a pointer to it into
/// the runtime `NovaConnection_queryInternal` alongside the connection, SQL, and
/// params. The runtime drives the wire protocol and calls back into the
/// generated decoder per row, so row decoding is monomorphised to the target
/// struct at compile time rather than done reflectively at runtime.
pub fn compileNovaQuery(
    self: *LlvmCompiler,
    target_type: ast.TypeRef,
    conn_expr: ast.Expression,
    sql_expr: ast.Expression,
    params_expr: ast.Expression,
) anyerror!types.LLVMValueRef {
    const type_str = try self.typeRefToString(target_type);

    const tmp_fn_name = try std.fmt.allocPrint(self.allocator, "decode_binary_row_{s}", .{type_str});
    defer self.allocator.free(tmp_fn_name);
    const fn_name = try self.allocator.dupeZ(u8, tmp_fn_name);
    defer self.allocator.free(fn_name);

    var decoder_fn = self.func_map.get(fn_name);
    if (decoder_fn == null) {
        var params = [_]types.LLVMTypeRef{ self.val_type, self.val_type, self.val_type, self.val_type };
        const fn_type = core.LLVMFunctionType(self.val_type, &params, 4, 0);
        decoder_fn = core.LLVMAddFunction(self.module, fn_name.ptr, fn_type);
        try self.func_map.put(fn_name, decoder_fn.?);

        const current_bb = core.LLVMGetInsertBlock(self.builder);
        const entry_bb = core.LLVMAppendBasicBlock(decoder_fn.?, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

        const fixed_data = core.LLVMGetParam(decoder_fn.?, 0);
        const heap_data = core.LLVMGetParam(decoder_fn.?, 1);
        const col_names = core.LLVMGetParam(decoder_fn.?, 2);
        const col_types = core.LLVMGetParam(decoder_fn.?, 3);

        const decoded_struct = try self.compileDecodeBinaryRow(target_type, fixed_data, heap_data, col_names, col_types);
        _ = core.LLVMBuildRet(self.builder, decoded_struct);

        core.LLVMPositionBuilderAtEnd(self.builder, current_bb);
    }

    const query_internal_fn = self.func_map.get("NovaConnection_queryInternal") orelse return error.QueryInternalNotFound;
    const query_internal_fn_t = core.LLVMGlobalGetValueType(query_internal_fn);

    const self_val = try self.compileExpression(conn_expr);
    const sql_val = try self.compileExpression(sql_expr);
    const params_val = try self.compileExpression(params_expr);
    const decoder_ptr = core.LLVMBuildPtrToInt(self.builder, decoder_fn.?, self.val_type, "decoder_ptr");

    var query_args = [_]types.LLVMValueRef{ self_val, sql_val, params_val, decoder_ptr };
    return core.LLVMBuildCall2(self.builder, query_internal_fn_t, query_internal_fn, &query_args, 4, "query_res");
}

/// Emits the body of a per-type row decoder: reads each field of `target_type`
/// out of NovaDB's binary row layout and builds a heap struct.
///
/// For every struct field it looks up the column by name
/// (`findColumnIndex`); when found, it reads the value at the column offset from
/// the fixed-size area according to the field's type (bool as a byte, int as
/// zero/sign-extended i32/i64, strings via a `{offset -> len-prefixed bytes}`
/// indirection into the heap area using `__read_string`), and when the column is
/// absent it stores a zero default. A per-field present/absent phi feeds the
/// store into the allocated struct at the field's offset. This is the compiled,
/// allocation-light equivalent of a generic row-to-object mapper.
pub fn compileDecodeBinaryRow(
    self: *LlvmCompiler,
    target_type: ast.TypeRef,
    fixed_data_val: types.LLVMValueRef,
    heap_data_val: types.LLVMValueRef,
    col_names_val: types.LLVMValueRef,
    col_types_val: types.LLVMValueRef,
) anyerror!types.LLVMValueRef {

    const type_str = try self.typeRefToString(target_type);

    const find_fn = self.getFunc("findColumnIndex") orelse return error.HelperNotFound;
    const find_fn_t = core.LLVMGlobalGetValueType(find_fn);

    const offset_fn = self.getFunc("getColumnOffset") orelse return error.HelperNotFound;
    const offset_fn_t = core.LLVMGlobalGetValueType(offset_fn);

    const read_str_fn = self.getFunc("__read_string") orelse return error.HelperNotFound;
    const read_str_fn_t = core.LLVMGlobalGetValueType(read_str_fn);

    const s_decl = self.structs.get(type_str) orelse return error.StructDeclNotFound;
    const total_size = self.getTypeSize(target_type, false);
    const size_val = core.LLVMConstInt(self.val_type, total_size, 0);
    const struct_ptr = try self.compileAlloc(size_val);

    for (s_decl.fields) |field| {
        const field_name_str = try self.getOrCreateStringLiteral(field.name);

        var find_args = [_]types.LLVMValueRef{ col_names_val, field_name_str };
        const col_idx = core.LLVMBuildCall2(self.builder, find_fn_t, find_fn, &find_args, 2, "col_idx");

        const minus_one = core.LLVMConstInt(self.val_type, @bitCast(@as(i64, -1)), 0);
        const col_idx_found = core.LLVMBuildICmp(self.builder, .LLVMIntNE, col_idx, minus_one, "col_idx_found");

        const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const then_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_found");
        const else_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_not_found");
        const merge_bb = core.LLVMAppendBasicBlock(current_fn, "decode_field_merge");

        _ = core.LLVMBuildCondBr(self.builder, col_idx_found, then_bb, else_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, then_bb);

        var offset_args = [_]types.LLVMValueRef{ col_types_val, col_idx };
        const col_offset = core.LLVMBuildCall2(self.builder, offset_fn_t, offset_fn, &offset_args, 2, "col_offset");

        const f_type_str = try self.typeRefToString(field.type_name);
        const llvm_field_type = self.toLLVMType(field.type_name);

        var decoded_val: types.LLVMValueRef = undefined;
        if (std.mem.eql(u8, f_type_str, "bool")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "byte_ptr");
            const byte_val = core.LLVMBuildLoad2(self.builder, self.i8_type, ptr, "byte_val");
            decoded_val = core.LLVMBuildZExt(self.builder, byte_val, self.val_type, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "i32") or std.mem.eql(u8, f_type_str, "int")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const i32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i32_ptr_type, "i32_ptr");
            const i32_val = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "i32_val");
            decoded_val = core.LLVMBuildSExt(self.builder, i32_val, self.val_type, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "i64") or std.mem.eql(u8, f_type_str, "long") or std.mem.eql(u8, f_type_str, "double") or std.mem.eql(u8, f_type_str, "decimal")) {
            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const i64_ptr_type = core.LLVMPointerType(self.i64_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, i64_ptr_type, "i64_ptr");
            decoded_val = core.LLVMBuildLoad2(self.builder, self.i64_type, ptr, "decoded_val");
        } else if (std.mem.eql(u8, f_type_str, "string")) {

            const addr = core.LLVMBuildAdd(self.builder, fixed_data_val, col_offset, "addr");
            const u32_ptr_type = core.LLVMPointerType(self.i32_type, 0);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, u32_ptr_type, "u32_ptr");
            const heap_offset = core.LLVMBuildLoad2(self.builder, self.i32_type, ptr, "heap_offset");
            const heap_offset_ext = core.LLVMBuildZExt(self.builder, heap_offset, self.val_type, "heap_offset_ext");

            const str_addr = core.LLVMBuildAdd(self.builder, heap_data_val, heap_offset_ext, "str_addr");
            const str_len_ptr = core.LLVMBuildIntToPtr(self.builder, str_addr, u32_ptr_type, "str_len_ptr");
            const str_len = core.LLVMBuildLoad2(self.builder, self.i32_type, str_len_ptr, "str_len");
            const str_len_ext = core.LLVMBuildZExt(self.builder, str_len, self.val_type, "str_len_ext");

            const chars_addr = core.LLVMBuildAdd(self.builder, heap_data_val, heap_offset_ext, "chars_addr");
            const chars_ptr = core.LLVMBuildAdd(self.builder, chars_addr, core.LLVMConstInt(self.val_type, 4, 0), "chars_ptr");

            var read_args = [_]types.LLVMValueRef{ chars_ptr, str_len_ext };
            decoded_val = core.LLVMBuildCall2(self.builder, read_str_fn_t, read_str_fn, &read_args, 2, "read_str");
        } else {
            decoded_val = core.LLVMConstInt(self.val_type, 0, 0);
        }

        _ = core.LLVMBuildBr(self.builder, merge_bb);
        const then_end_bb = core.LLVMGetInsertBlock(self.builder);

        core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
        const default_val = core.LLVMConstInt(self.val_type, 0, 0);
        _ = core.LLVMBuildBr(self.builder, merge_bb);
        const else_end_bb = core.LLVMGetInsertBlock(self.builder);

        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi_val = core.LLVMBuildPhi(self.builder, self.val_type, "field_phi");
        var incoming_vals = [_]types.LLVMValueRef{ decoded_val, default_val };
        var incoming_bbs = [_]types.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
        core.LLVMAddIncoming(phi_val, &incoming_vals, &incoming_bbs, 2);

        const f_offset = try self.getFieldOffset(type_str, field.name);
        const f_offset_val = core.LLVMConstInt(self.val_type, f_offset, 0);
        const f_addr = core.LLVMBuildAdd(self.builder, struct_ptr, f_offset_val, "f_addr");
        const f_dest_ptr = core.LLVMBuildIntToPtr(self.builder, f_addr, core.LLVMPointerType(llvm_field_type, 0), "f_dest_ptr");
        const casted = self.castFromValType(phi_val, llvm_field_type);
        _ = core.LLVMBuildStore(self.builder, casted, f_dest_ptr);
    }

    return struct_ptr;
}

/// Lowers a typed `parse<T>(text)` for JSON or YAML: parse to a dynamic value,
/// then structurally convert it to `T`.
///
/// Finds the `serde_json_parse`/`serde_yaml_parse` runtime entry (tolerating a
/// module-qualified symbol), calls it, converts the resulting dynamic value into
/// the concrete `target_type` via [`convertValueToType`], and releases the
/// intermediate dynamic value. `is_yaml` selects the JSON vs YAML function
/// family throughout.
pub fn compileGenericParse(self: *LlvmCompiler, is_yaml: bool, target_type: ast.TypeRef, input_expr: ast.Expression) anyerror!types.LLVMValueRef {
    const input_val = try self.compileExpression(input_expr);

    const parse_fn_name = if (is_yaml) "serde_yaml_parse" else "serde_json_parse";
    var parse_fn = self.func_map.get(parse_fn_name);
    if (parse_fn == null) {
        var iter = self.func_map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.endsWith(u8, key, parse_fn_name)) {
                parse_fn = entry.value_ptr.*;
                break;
            }
        }
    }
    const final_parse_fn = parse_fn orelse {
        std.debug.print("Parse function '{s}' not found\n", .{parse_fn_name});
        return error.ParseFunctionNotFound;
    };
    const parsed_val = try self.buildCallWithCasts(final_parse_fn, &[_]types.LLVMValueRef{input_val});

    const result_val = try self.convertValueToType(is_yaml, parsed_val, target_type);

    const type_name = if (is_yaml) "YamlValue" else "JsonValue";
    if (try self.getOrCreateDestructor(type_name)) |dest_fn| {
        try self.compileRelease(parsed_val, dest_fn);
    } else {
        try self.compileRelease(parsed_val, null);
    }

    return result_val;
}

/// Looks up an emitted function by name, tolerating module-name prefixes on the
/// symbol.
///
/// First tries an exact `func_map` hit. Failing that it scans for a key ENDING
/// in `name`, preferring the shortest overall match and, among those, one where
/// `name` is preceded by an underscore (a proper `module_name` boundary) so a
/// suffix match cannot pick up an unrelated function whose name merely ends the
/// same way. This is how std helpers are found regardless of their mangled
/// module prefix. (Contains debug tracing for `List_init`/`List_new` lookups.)
pub fn getFunc(self: *LlvmCompiler, name: []const u8) ?types.LLVMValueRef {
    if (std.mem.eql(u8, name, "List_init") or std.mem.eql(u8, name, "List_new")) {
        var debug_iter = self.func_map.iterator();
        while (debug_iter.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, "List_") != null) {
                std.debug.print("  func_map key={s}\n", .{entry.key_ptr.*});
            }
        }
    }
    if (self.func_map.get(name)) |v| return v;
    var best: ?types.LLVMValueRef = null;
    var best_len: usize = std.math.maxInt(usize);
    var best_bounded: ?types.LLVMValueRef = null;
    var best_bounded_len: usize = std.math.maxInt(usize);
    var iter = self.func_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, key, name)) continue;
        if (key.len < best_len) {
            best_len = key.len;
            best = entry.value_ptr.*;
        }
        if (key.len > name.len and key[key.len - name.len - 1] == '_' and key.len < best_bounded_len) {
            best_bounded_len = key.len;
            best_bounded = entry.value_ptr.*;
        }
    }
    return best_bounded orelse best;
}

/// Resolves a type ref to the concrete, reified type name used to key generated
/// code.
///
/// For a bare identifier that has a known concrete `TypeId` in the current
/// context it returns the symbol name of that concrete type (so a type
/// parameter reifies to its instantiation); otherwise it falls back to the plain
/// rendered type string.
pub fn resolveReifyTypeName(self: *LlvmCompiler, type_ref: ast.TypeRef) anyerror![]const u8 {
    if (type_ref == .ident) {
        if (self.concreteTidForTypeRef(type_ref)) |ctid| return try self.symbolName(ctid);
    }
    return try self.typeRefToString(type_ref);
}

/// Recursively converts a dynamic JSON/YAML value into a concrete Nova value of
/// `type_ref`.
///
/// Numbers/bools/strings call the matching `serde_*_asNumber/asBool/asString`
/// accessor (retaining the source value across the borrow). A struct type
/// allocates the struct and recurses per field via `serde_*_get`. A `List<E>`
/// allocates a fresh list and loops over the dynamic array, converting each
/// element to `E` and pushing it. An unrecognised type yields the zero word.
/// Retains are inserted before each accessor call because the runtime accessors
/// borrow their argument, and the intermediate array is released after the loop.
/// This is the type-directed half of [`compileGenericParse`].
pub fn convertValueToType(self: *LlvmCompiler, is_yaml: bool, val: types.LLVMValueRef, type_ref: ast.TypeRef) anyerror!types.LLVMValueRef {
    const type_str = try self.typeRefToString(type_ref);

    const get_fn_name = if (is_yaml) "serde_yaml_get" else "serde_json_get";
    const get_fn = self.getFunc(get_fn_name) orelse return error.GetFunctionNotFound;

    if (std.mem.eql(u8, type_str, "i32") or std.mem.eql(u8, type_str, "i64") or std.mem.eql(u8, type_str, "int") or std.mem.eql(u8, type_str, "long") or std.mem.eql(u8, type_str, "double") or std.mem.eql(u8, type_str, "decimal") or std.mem.eql(u8, type_str, "float") or std.mem.eql(u8, type_str, "f32") or std.mem.eql(u8, type_str, "f64")) {
        const asNum_name = if (is_yaml) "serde_yaml_asNumber" else "serde_json_asNumber";
        const asNum_fn = self.getFunc(asNum_name) orelse return error.AsNumberFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asNum_fn, &[_]types.LLVMValueRef{val});
        const llvm_t = self.toLLVMType(type_ref);
        return self.castFromValType(res, llvm_t);
    }

    if (std.mem.eql(u8, type_str, "bool")) {
        const asBool_name = if (is_yaml) "serde_yaml_asBool" else "serde_json_asBool";
        const asBool_fn = self.getFunc(asBool_name) orelse return error.AsBoolFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asBool_fn, &[_]types.LLVMValueRef{val});
        const llvm_t = self.toLLVMType(type_ref);
        return self.castFromValType(res, llvm_t);
    }

    if (std.mem.eql(u8, type_str, "string")) {
        const asStr_name = if (is_yaml) "serde_yaml_asString" else "serde_json_asString";
        const asStr_fn = self.getFunc(asStr_name) orelse return error.AsStringFunctionNotFound;
        try self.compileRetain(val);
        const res = try self.buildCallWithCasts(asStr_fn, &[_]types.LLVMValueRef{val});
        try self.compileRetain(res);
        return res;
    }

    if (self.structs.get(type_str)) |s_decl| {
        const total_size = self.getTypeSize(type_ref, false);
        const size_val = core.LLVMConstInt(self.val_type, total_size, 0);
        const struct_ptr = try self.compileAlloc(size_val);

        for (s_decl.fields) |field| {
            const offset = try self.getFieldOffset(type_str, field.name);
            const offset_val = core.LLVMConstInt(self.val_type, offset, 0);

            const field_name_str = try self.getOrCreateStringLiteral(field.name);
            try self.compileRetain(val);
            const field_json_val = try self.buildCallWithCasts(get_fn, &[_]types.LLVMValueRef{ val, field_name_str });

            const converted_val = try self.convertValueToType(is_yaml, field_json_val, field.type_name);

            const addr = core.LLVMBuildAdd(self.builder, struct_ptr, offset_val, "field_addr");
            const llvm_field_type = self.toLLVMType(field.type_name);
            const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
            const casted = self.castFromValType(converted_val, llvm_field_type);
            _ = core.LLVMBuildStore(self.builder, casted, ptr);
        }

        return struct_ptr;
    }

    if (std.mem.startsWith(u8, type_str, "List<")) {
        const open_angle = std.mem.indexOfScalar(u8, type_str, '<') orelse return error.InvalidGenericType;
        const close_angle = std.mem.indexOfScalar(u8, type_str, '>') orelse return error.InvalidGenericType;
        const sub_item_type_str = type_str[open_angle + 1 .. close_angle];
        const sub_item_type = ast.TypeRef{ .ident = sub_item_type_str };

        const asArray_name = if (is_yaml) "serde_yaml_asArray" else "serde_json_asArray";
        const asArray_fn = self.getFunc(asArray_name) orelse return error.AsArrayFunctionNotFound;
        try self.compileRetain(val);
        const arr_val = try self.buildCallWithCasts(asArray_fn, &[_]types.LLVMValueRef{val});

        const list_new = self.getFunc("List_init") orelse return error.ListNewNotFound;
        const list_size = self.getFunc("List_size") orelse return error.ListSizeNotFound;
        const list_get = self.getFunc("List_get") orelse return error.ListGetNotFound;
        const list_push = self.getFunc("List_push") orelse return error.ListPushNotFound;

        const list_size_type = self.getTypeSize(ast.TypeRef{ .ident = "List" }, false);
        const new_list_val = try self.compileAlloc(core.LLVMConstInt(self.val_type, list_size_type, 0));
        const list_new_t = core.LLVMGlobalGetValueType(list_new);
        var list_args = [_]types.LLVMValueRef{new_list_val};
        _ = core.LLVMBuildCall2(self.builder, list_new_t, list_new, &list_args, 1, "");

        const size_t = core.LLVMGlobalGetValueType(list_size);
        var size_args = [_]types.LLVMValueRef{arr_val};
        try self.compileRetain(arr_val);
        const size_val = core.LLVMBuildCall2(self.builder, size_t, list_size, &size_args, 1, "arr_size");

        const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const loop_cond_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_cond");
        const loop_body_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_body");
        const loop_end_bb = core.LLVMAppendBasicBlock(current_fn, "list_loop_end");

        const idx_var = try self.compileAlloc(core.LLVMConstInt(self.val_type, 4, 0));
        const idx_ptr = core.LLVMBuildIntToPtr(self.builder, idx_var, core.LLVMPointerType(self.i32_type, 0), "idx_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i32_type, 0, 0), idx_ptr);

        _ = core.LLVMBuildBr(self.builder, loop_cond_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_cond_bb);
        const current_idx = core.LLVMBuildLoad2(self.builder, self.i32_type, idx_ptr, "current_idx");
        const casted_idx = self.castToValType(current_idx, ast.TypeRef{ .ident = "i32" });
        const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntSLT, casted_idx, size_val, "loop_cmp");
        _ = core.LLVMBuildCondBr(self.builder, cmp, loop_body_bb, loop_end_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_body_bb);
        const get_t = core.LLVMGlobalGetValueType(list_get);
        var get_args = [_]types.LLVMValueRef{ arr_val, casted_idx };
        try self.compileRetain(arr_val);
        const elem_val = core.LLVMBuildCall2(self.builder, get_t, list_get, &get_args, 2, "elem_val");

        const converted_elem = try self.convertValueToType(is_yaml, elem_val, sub_item_type);

        const push_t = core.LLVMGlobalGetValueType(list_push);
        var push_args = [_]types.LLVMValueRef{ new_list_val, converted_elem };
        try self.compileRetain(new_list_val);
        _ = core.LLVMBuildCall2(self.builder, push_t, list_push, &push_args, 2, "");

        const next_idx = core.LLVMBuildAdd(self.builder, current_idx, core.LLVMConstInt(self.i32_type, 1, 0), "next_idx");
        _ = core.LLVMBuildStore(self.builder, next_idx, idx_ptr);
        _ = core.LLVMBuildBr(self.builder, loop_cond_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_end_bb);
        if (try self.getOrCreateDestructor("List")) |dest_fn| {
            try self.compileRelease(arr_val, dest_fn);
        } else {
            try self.compileRelease(arr_val, null);
        }
        return new_list_val;
    }

    return core.LLVMConstInt(self.val_type, 0, 0);
}

/// Maps a lowercase HTTP-verb router method name (`get`, `post`, ...) to its
/// uppercase HTTP method (`GET`, `POST`, ...), or null if not a verb.
///
/// Used when lowering web-router builder calls like `router.get(path, handler)`
/// so the method string passed to the runtime is the canonical verb.
fn routeVerbMethod(field: []const u8) ?[]const u8 {
    const verbs = [_]struct { f: []const u8, m: []const u8 }{
        .{ .f = "get", .m = "GET" },       .{ .f = "post", .m = "POST" },
        .{ .f = "put", .m = "PUT" },       .{ .f = "delete", .m = "DELETE" },
        .{ .f = "patch", .m = "PATCH" },   .{ .f = "options", .m = "OPTIONS" },
        .{ .f = "head", .m = "HEAD" },
    };
    for (verbs) |v| if (std.mem.eql(u8, field, v.f)) return v.m;
    return null;
}

/// Whether struct declaration `sd` declares a method called `name`.
///
/// A small predicate used while lowering calls to decide between a user-defined
/// method and a builtin/fallback with the same name.
fn structHasMethod(sd: ast.StructDecl, name: []const u8) bool {
    for (sd.methods) |m| if (std.mem.eql(u8, m.decl.name, name)) return true;
    return false;
}
