const std = @import("std");
const ast = @import("../ast.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;

const sema_shadow = @import("../sema/shadow.zig");
const typesys = @import("../types.zig");
const lower = @import("../sema/lower.zig");
const subst = @import("../sema/subst.zig");
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const getStructBaseName = @import("types.zig").getStructBaseName;
const isPrimitiveTypeName = @import("types.zig").isPrimitiveTypeName;
const mangleTypeName = @import("types.zig").mangleTypeName;

pub fn enumIsTaggedUnion(self: *LlvmCompiler, enum_name: []const u8) bool {
    const enum_decl = self.enums.get(enum_name) orelse return false;
    for (enum_decl.variants) |v| {
        if (v.type_name != null or v.fields != null) return true;
    }
    return false;
}

// Ownership default for a value with NO recoverable concrete TypeId. Reached ONLY from
// types.ownedByName -- after the primitive short-circuit and after tidForName failed -- i.e. a bare
// type parameter or an instantiation-free generic/function type from an ERASED generic body, which
// monomorphization dead-strips (but whose IR must still verify, so a decision is unavoidable). This
// is a STRUCTURAL default over dead code, NOT ownership-by-user-type-name: every RESOLVABLE type is
// decided by the TypeId engine (isOwnedTypeId) before reaching here. A lone type-parameter slot
// carries no owned reference; every other shape (a function value, a List/Map container) is
// heap-owned. An untypeable placeholder means sema failed to type a LIVE value that reached ARC -- a
// compiler bug -- so keep the loud guard rather than silently guessing.
pub fn erasedOwnershipDefault(self: *LlvmCompiler, type_name: []const u8) bool {
    _ = self;
    if (isUntypeablePlaceholder(type_name)) {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ARC ownership asked of an un-typeable value '{s}'\x1b[0m\n" ++
            "  sema failed to type a value that reached a retain/release. This is a COMPILER bug\n" ++
            "  (not user code): freeing it would corrupt memory. Please report.\n",
            .{type_name});
        std.process.exit(70);
    }
    // A bare, undeclared single-letter name is a type parameter (a declared one-letter type would
    // have resolved via tidForName). Its slot holds no owned reference in an erased body.
    if (type_name.len == 1 and type_name[0] >= 'A' and type_name[0] <= 'Z') return false;
    return true;
}

// LEGACY string ownership classifier. As of the L1 string->TypeId migration this is NO LONGER a
// codegen ownership decider -- codegen uses the resolved-TypeId engine (isOwnedTypeId) for every
// real type, and erasedOwnershipDefault for dead erased bodies. This survives ONLY as the SHADOW
// gate's comparison baseline (types.tdShadowDiff / isOwnedRenderedFallback): it reproduces the
// historical name-matched rule so the shadow diff keeps proving the TypeId engine agrees with it
// (the F5-2 engine-agreement invariant). Do NOT call it from a codegen path.
pub fn legacyStringOwnership(self: *LlvmCompiler, type_name: []const u8) bool {
    if (sema_shadow.report_enabled) { sema_shadow.a2_irct_calls += 1; if (std.mem.indexOfAny(u8, type_name, "<(") != null) sema_shadow.a2_irct_composite += 1; }
    const base = getStructBaseName(type_name);
    if (type_name.len == 1 and type_name[0] >= 'A' and type_name[0] <= 'Z') {

        if (!self.structs.contains(type_name) and !self.enums.contains(type_name) and !self.unions.contains(type_name) and !self.traits.contains(type_name)) {
            return false;
        }
    }
    if (isPrimitiveTypeName(type_name)) {
        return false;
    }

    if (self.enums.contains(base)) {

        return enumIsTaggedUnion(self, base);
    }

    if (isUntypeablePlaceholder(type_name)) {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ARC ownership asked of an un-typeable value '{s}'\x1b[0m\n" ++
            "  sema failed to type a value that reached a retain/release. This is a COMPILER bug\n" ++
            "  (not user code): freeing it would corrupt memory. F5 stage 2 — please report.\n",
            .{type_name});
        std.process.exit(70);
    }

    return true;
}

pub fn isUntypeablePlaceholder(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "unresolved") or
        std.mem.eql(u8, name, "<unresolved>") or
        std.mem.eql(u8, name, "<tuple>") or
        std.mem.eql(u8, name, "<array>") or
        std.mem.eql(u8, name, "<fn>");
}

pub fn compileCallArgument(self: *LlvmCompiler, arg: ast.Expression) anyerror!types.LLVMValueRef {
    const val = try self.compileExpression(arg);

    if (self.exprYieldsValoptBox(&arg)) {
        return try self.buildValoptUnbox(self.coerceToSlotType(val, self.val_type));
    }
    return val;
}

pub const Disposition = enum { owned, borrowed };

fn dispResidueOf(store: *const typesys.TypeStore, tid: typesys.TypeId) sema_shadow.DispResidue {
    return switch (store.get(tid)) {
        .type_param => .type_param,
        .enum_ => .enum_,
        .optional => |inner| dispResidueOf(store, inner),
        // A disposition disagreement on a NON-OWNED type (a primitive like i32/bool/etc.) cannot corrupt
        // memory -- no retain/release happens regardless of which side wins -- so it is SAFE, not a real
        // ownership divergence. Only disagreements on OWNED types can be genuine bugs.
        else => if (!store.isOwned(tid)) .not_owned else .other,
    };
}

pub fn acquisitionDisposition(self: *LlvmCompiler, expr: *const ast.Expression) Disposition {
    const principled = principledDisposition(self, expr);

    const pass_says_owned = if (self.typed_ir) |ir| blk: {
        if (self.current_instantiation_id) |inst| {
            if (ir.ownedOfInst(expr.id, inst)) |o| break :blk o;
        }
        break :blk (ir.ownedOf(expr) orelse false);
    } else false;
    const d: Disposition = if (pass_says_owned) .owned else principled;

    if (sema_shadow.report_enabled) {
        if (self.typed_ir) |ir| {

            const sema_owned_opt: ?bool = if (self.current_instantiation_id) |inst|
                (ir.ownedOfInst(expr.id, inst) orelse ir.ownedOf(expr))
            else
                ir.ownedOf(expr);
            if (sema_owned_opt) |sema_owned| {
                if ((principled == .owned) == sema_owned) {
                    sema_shadow.disp_agree += 1;
                } else {
                    sema_shadow.disp_disagree += 1;
                    const sema_tag: sema_shadow.DispResidue = blk: {
                        const st = self.type_store orelse break :blk .other;
                        const tid = ir.typeOf(expr) orelse break :blk .other;
                        break :blk dispResidueOf(st, tid);
                    };
                    switch (sema_tag) {
                        .type_param => sema_shadow.disp_disagree_typeparam += 1,
                        .enum_ => sema_shadow.disp_disagree_enum += 1,
                        .not_owned => sema_shadow.disp_disagree_not_owned += 1,
                        .other => {
                            sema_shadow.disp_disagree_other += 1;
                            sema_shadow.disp_last_kind = @tagName(expr.kind);
                            sema_shadow.disp_last_type = (self.resolveExpressionTypeName(expr) catch null) orelse "";
                        },
                    }
                }
            }
        }
    }
    return d;
}

pub fn namesExistingOwner(kind: ast.ExprKind) bool {
    return switch (kind) {
        .ident, .field_access, .index => true,
        else => false,
    };
}

fn principledDisposition(self: *LlvmCompiler, expr: *const ast.Expression) Disposition {

    const is_enum_variant_ctor = expr.kind == .field_access and
        expr.kind.field_access.object.kind == .ident and
        self.enums.contains(expr.kind.field_access.object.kind.ident);

    if (!is_enum_variant_ctor and namesExistingOwner(expr.kind)) return .borrowed;
    switch (expr.kind) {

        .binary => |b| {
            if (b.op == .assign) return .borrowed;
        },

        .literal => |lit| if (lit != .decimal and lit != .array) return .borrowed,

        .try_expr, .cast, .await_expr, .go_expr => return .borrowed,

        .optional_chaining => return if (self.exprYieldsValoptBox(expr)) .owned else .borrowed,

        else => {},
    }
    if (!self.isOwnedExpr(expr)) return .borrowed;
    return .owned;
}

pub fn takeOwnedElement(self: *LlvmCompiler, elem_kind: ast.ExprKind, val: types.LLVMValueRef) anyerror!void {
    if (namesExistingOwner(elem_kind)) {
        try self.compileRetain(val);
    } else {
        self.consumeTemporary(val);
    }
}

pub fn compileRetain(self: *LlvmCompiler, ptr: types.LLVMValueRef) anyerror!void {
    const retain_fn = if (self.func_map.get("nova_retain")) |f| f else blk: {
        var arg_types = [_]types.LLVMTypeRef{self.val_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 1, 0);
        const f = core.LLVMAddFunction(self.module, "nova_retain", fn_type);
        try self.func_map.put("nova_retain", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(retain_fn);
    var args = [_]types.LLVMValueRef{ptr};
    _ = core.LLVMBuildCall2(self.builder, fn_t, retain_fn, &args, 1, "");
}

pub fn compileRelease(self: *LlvmCompiler, ptr: types.LLVMValueRef, destructor_fn_opt: ?types.LLVMValueRef) anyerror!void {
    const release_fn = if (self.func_map.get("nova_release")) |f| f else blk: {
        const ptr_type = core.LLVMPointerType(self.void_type, 0);
        var arg_types = [_]types.LLVMTypeRef{self.val_type, ptr_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 2, 0);
        const f = core.LLVMAddFunction(self.module, "nova_release", fn_type);
        try self.func_map.put("nova_release", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(release_fn);
    const dest_val = if (destructor_fn_opt) |d|
        core.LLVMBuildBitCast(self.builder, d, core.LLVMPointerType(self.void_type, 0), "dest_cast")
    else
        core.LLVMConstNull(core.LLVMPointerType(self.void_type, 0));
    var args = [_]types.LLVMValueRef{ptr, dest_val};
    _ = core.LLVMBuildCall2(self.builder, fn_t, release_fn, &args, 2, "");
}

fn destructorName(allocator: std.mem.Allocator, type_name: []const u8) ![]u8 {
    const mangled = try mangleTypeName(allocator, type_name);
    defer allocator.free(mangled);
    return std.fmt.allocPrint(allocator, "__destruct_{s}", .{mangled});
}

pub fn substituteFieldType(self: *LlvmCompiler, inst_name: []const u8, field_type: []const u8) anyerror![]const u8 {
    const lt = std.mem.indexOfScalar(u8, inst_name, '<') orelse return field_type;
    if (!std.mem.endsWith(u8, inst_name, ">")) return field_type;
    const base = inst_name[0..lt];
    const decl = self.structs.get(base) orelse return field_type;
    if (decl.type_params.len == 0) return field_type;

    var args = std.ArrayListUnmanaged([]const u8).empty;
    defer args.deinit(self.allocator);
    const inner = inst_name[lt + 1 .. inst_name.len - 1];
    var depth: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        switch (inner[i]) {
            '<' => depth += 1,

            '>' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                try args.append(self.allocator, std.mem.trim(u8, inner[seg_start..i], " "));
                seg_start = i + 1;
            },
            else => {},
        }
    }
    try args.append(self.allocator, std.mem.trim(u8, inner[seg_start..], " "));
    if (args.items.len != decl.type_params.len) return field_type;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(self.allocator);
    var j: usize = 0;
    outer: while (j < field_type.len) {
        const at_start = j == 0 or !isIdentCh(field_type[j - 1]);
        if (at_start) {
            for (decl.type_params, 0..) |tp, k| {
                if (std.mem.startsWith(u8, field_type[j..], tp)) {
                    const end = j + tp.len;
                    if (end == field_type.len or !isIdentCh(field_type[end])) {
                        try out.appendSlice(self.allocator, args.items[k]);
                        j = end;
                        continue :outer;
                    }
                }
            }
        }
        try out.append(self.allocator, field_type[j]);
        j += 1;
    }
    return try out.toOwnedSlice(self.allocator);
}

pub fn substTypeParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {

    const after_struct = if (self.current_instantiation) |inst|
        try self.substituteFieldType(inst, type_str)
    else
        type_str;
    return try self.substMethodParams(after_struct);
}

pub fn substMethodParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {
    const bindings = self.current_method_subst orelse return type_str;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(self.allocator);
    var replaced = false;
    var j: usize = 0;
    outer: while (j < type_str.len) {
        const at_start = j == 0 or !isIdentCh(type_str[j - 1]);
        if (at_start) {
            for (bindings) |b| {
                if (std.mem.startsWith(u8, type_str[j..], b.name)) {
                    const end = j + b.name.len;
                    if (end == type_str.len or !isIdentCh(type_str[end])) {
                        try out.appendSlice(self.allocator, b.concrete);
                        j = end;
                        replaced = true;
                        continue :outer;
                    }
                }
            }
        }
        try out.append(self.allocator, type_str[j]);
        j += 1;
    }
    if (!replaced) {
        out.deinit(self.allocator);
        return type_str;
    }
    return out.toOwnedSlice(self.allocator);
}

fn isIdentCh(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn isFunctionType(type_name: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < type_name.len) : (i += 1) {
        switch (type_name[i]) {
            '<' => depth += 1,
            '>' => {

                if (i > 0 and (type_name[i - 1] == '=' or type_name[i - 1] == '-')) {
                    if (depth == 0) return true;
                } else {
                    depth -= 1;
                }
            },
            else => {},
        }
    }
    return false;
}

fn storageElem(type_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, type_name, "Storage<")) return null;
    if (!std.mem.endsWith(u8, type_name, ">")) return null;
    return type_name["Storage<".len .. type_name.len - 1];
}

fn buildStorageDestructor(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem: []const u8) anyerror!void {
    const owned = self.isOwnedStorageElemByName(elem);
    const elem_dest = if (owned) try self.getOrCreateDestructor(elem) else null;
    try buildStorageDestructorLoop(self, dest_fn, owned, elem_dest);
}

fn buildStorageDestructorByTypeId(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem_tid: typesys.TypeId) anyerror!void {
    const owned = self.isOwnedTypeId(elem_tid);
    const elem_dest = if (owned) try self.getOrCreateDestructorByTypeId(elem_tid) else null;
    try buildStorageDestructorLoop(self, dest_fn, owned, elem_dest);
}

fn buildStorageDestructorLoop(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, owned: bool, elem_dest: ?types.LLVMValueRef) anyerror!void {

    if (!owned) return;

    const self_val = core.LLVMGetParam(dest_fn, 0);
    const fn_parent = dest_fn;

    const four = core.LLVMConstInt(self.val_type, 4, 0);
    const len_addr = core.LLVMBuildSub(self.builder, self_val, four, "stg_len_addr");
    const len_ptr = core.LLVMBuildIntToPtr(self.builder, len_addr, core.LLVMPointerType(self.i32_type, 0), "stg_len_ptr");
    const len_i32 = core.LLVMBuildLoad2(self.builder, self.i32_type, len_ptr, "stg_len");
    const len_val = core.LLVMBuildZExt(self.builder, len_i32, self.val_type, "stg_len_ext");
    const eight = core.LLVMConstInt(self.val_type, 8, 0);
    const n_slots = core.LLVMBuildUDiv(self.builder, len_val, eight, "stg_slots");

    const i_alloca = core.LLVMBuildAlloca(self.builder, self.val_type, "stg_i");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), i_alloca);

    const cond_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_cond");
    const body_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_body");
    const exit_bb = core.LLVMAppendBasicBlock(fn_parent, "stg_exit");

    _ = core.LLVMBuildBr(self.builder, cond_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
    const i_cur = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "stg_i_cur");
    const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntULT, i_cur, n_slots, "stg_cmp");
    _ = core.LLVMBuildCondBr(self.builder, cmp, body_bb, exit_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
    const i_b = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "stg_i_b");
    const off = core.LLVMBuildMul(self.builder, i_b, eight, "stg_off");
    const slot_addr = core.LLVMBuildAdd(self.builder, self_val, off, "stg_slot_addr");
    const slot_ptr = core.LLVMBuildIntToPtr(self.builder, slot_addr, core.LLVMPointerType(self.val_type, 0), "stg_slot_ptr");
    const elem_val = core.LLVMBuildLoad2(self.builder, self.val_type, slot_ptr, "stg_elem");

    try self.compileRelease(elem_val, elem_dest);
    const i_next = core.LLVMBuildAdd(self.builder, i_b, core.LLVMConstInt(self.val_type, 1, 0), "stg_i_next");
    _ = core.LLVMBuildStore(self.builder, i_next, i_alloca);
    _ = core.LLVMBuildBr(self.builder, cond_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
}

fn getOrCreateStorageDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (st.get(t) != .storage) return null;

    if (sema_shadow.report_enabled) diffStorageElem(self, t);
    const elem_tid = st.get(t).storage;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    try buildStorageDestructorByTypeId(self, dest_fn, elem_tid);

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

pub fn getOrCreateTraitDestructor(self: *LlvmCompiler) anyerror!types.LLVMValueRef {
    if (core.LLVMGetNamedFunction(self.module, "__destruct_trait")) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, "__destruct_trait", fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const fat = core.LLVMGetParam(dest_fn, 0);
    const ptr_size: u64 = 8;

    const sp_ptr = core.LLVMBuildIntToPtr(self.builder, fat, core.LLVMPointerType(self.val_type, 0), "td_sp_ptr");
    const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "td_struct_ptr");

    const vt_addr = core.LLVMBuildAdd(self.builder, fat, core.LLVMConstInt(self.val_type, ptr_size, 0), "td_vt_addr");
    const vt_ptr = core.LLVMBuildIntToPtr(self.builder, vt_addr, core.LLVMPointerType(self.val_type, 0), "td_vt_ptr");
    const vtable = core.LLVMBuildLoad2(self.builder, self.val_type, vt_ptr, "td_vtable");

    const sd_ptr = core.LLVMBuildIntToPtr(self.builder, vtable, core.LLVMPointerType(self.val_type, 0), "td_sd_ptr");
    const struct_dtor = core.LLVMBuildLoad2(self.builder, self.val_type, sd_ptr, "td_struct_dtor");

    const dtor_as_ptr = core.LLVMBuildIntToPtr(self.builder, struct_dtor, core.LLVMPointerType(self.void_type, 0), "td_dtor_cast");
    try self.compileRelease(struct_ptr, dtor_as_ptr);

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn getOrCreateClosureDestructor(self: *LlvmCompiler) anyerror!types.LLVMValueRef {
    if (core.LLVMGetNamedFunction(self.module, "__destruct_closure")) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, "__destruct_closure", fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

    const box = core.LLVMGetParam(dest_fn, 0);
    const ptr_size: u64 = 8;
    const env_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, ptr_size, 0), "clo_env_addr");
    const env_ptr = core.LLVMBuildIntToPtr(self.builder, env_addr, core.LLVMPointerType(self.val_type, 0), "clo_env_ptr");
    const env = core.LLVMBuildLoad2(self.builder, self.val_type, env_ptr, "clo_env");

    const clean_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, 2 * ptr_size, 0), "clo_cleanup_addr");
    const clean_ptr = core.LLVMBuildIntToPtr(self.builder, clean_addr, core.LLVMPointerType(self.val_type, 0), "clo_cleanup_ptr");
    const cleanup = core.LLVMBuildLoad2(self.builder, self.val_type, clean_ptr, "clo_cleanup");
    const has_cleanup = core.LLVMBuildICmp(self.builder, .LLVMIntNE, cleanup, core.LLVMConstInt(self.val_type, 0, 0), "clo_has_cleanup");
    const call_bb = core.LLVMAppendBasicBlock(dest_fn, "clo_cleanup_call");
    const after_bb = core.LLVMAppendBasicBlock(dest_fn, "clo_cleanup_done");
    _ = core.LLVMBuildCondBr(self.builder, has_cleanup, call_bb, after_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, call_bb);
    {
        var cp = [_]types.LLVMTypeRef{self.val_type};
        const cft = core.LLVMFunctionType(self.void_type, &cp, 1, 0);
        const cfp = core.LLVMBuildIntToPtr(self.builder, cleanup, core.LLVMPointerType(cft, 0), "clo_cleanup_fp");
        var cargs = [_]types.LLVMValueRef{env};
        _ = core.LLVMBuildCall2(self.builder, cft, cfp, &cargs, 1, "");
    }
    _ = core.LLVMBuildBr(self.builder, after_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, after_bb);

    const free_fn = if (self.func_map.get("nova_bytes_free")) |f| f else blk: {
        var at = [_]types.LLVMTypeRef{self.val_type};
        const ft = core.LLVMFunctionType(self.void_type, &at, 1, 0);
        const f = core.LLVMAddFunction(self.module, "nova_bytes_free", ft);
        try self.func_map.put("nova_bytes_free", f);
        break :blk f;
    };
    const free_t = core.LLVMGlobalGetValueType(free_fn);
    var free_args = [_]types.LLVMValueRef{env};
    _ = core.LLVMBuildCall2(self.builder, free_t, free_fn, &free_args, 1, "");

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

pub fn getOrCreateDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    switch (st.get(t)) {

        .trait_ => return try getOrCreateTraitDestructor(self),
        .func => return try getOrCreateClosureDestructor(self),

        .prim, .ptr, .unresolved => return null,

        .tuple => return try getOrCreateTupleDestructorByTypeId(self, t),
        .error_union => return try getOrCreateErrUnionDestructorByTypeId(self, t),
        .struct_ => return try getOrCreateStructDestructorByTypeId(self, t),
        .storage => return try getOrCreateStorageDestructorByTypeId(self, t),

        .optional => {
            if (self.valueOptionalInner(t) != null) return null;
            const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
            return try self.getOrCreateDestructor(name);
        },

        else => {
            const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
            return try self.getOrCreateDestructor(name);
        },
    }
}

pub fn getOrCreateDestructorPreferId(self: *LlvmCompiler, name_str: []const u8, tid: ?typesys.TypeId) anyerror!?types.LLVMValueRef {
    if (tid) |t| {
        if (self.type_store) |st| {
            if (st.get(t) != .unresolved) {

                const id_name = sema_shadow.renderLegacy(self.allocator, st, t) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                const id_sym = destructorName(self.allocator, id_name) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                defer self.allocator.free(id_sym);
                const str_sym = destructorName(self.allocator, name_str) catch {
                    return try self.getOrCreateDestructor(name_str);
                };
                defer self.allocator.free(str_sym);
                if (std.mem.eql(u8, id_sym, str_sym)) {
                    if (sema_shadow.report_enabled) sema_shadow.phaseA_flip += 1;
                    return try self.getOrCreateDestructorByTypeId(t);
                }
                if (sema_shadow.report_enabled) {
                    sema_shadow.phaseA_split += 1;
                    sema_shadow.phaseA_split_last = std.fmt.allocPrint(self.allocator, "id='{s}' str='{s}'", .{ id_name, name_str }) catch name_str;
                }
                return try self.getOrCreateDestructor(name_str);
            }
        }
    }
    if (sema_shadow.report_enabled) sema_shadow.phaseA_no_id += 1;
    return try self.getOrCreateDestructor(name_str);
}

pub fn getOrCreateDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {

    if (self.traits.contains(type_name)) return try getOrCreateTraitDestructor(self);

    if (isFunctionType(type_name)) {
        return try getOrCreateClosureDestructor(self);
    }

    if (isTupleType(type_name)) {
        return try getOrCreateTupleDestructor(self, type_name);
    }

    if (std.mem.startsWith(u8, type_name, "ErrUnion(")) {
        return try getOrCreateErrUnionDestructor(self, type_name);
    }
    const base_struct = getStructBaseName(type_name);

    if (self.enums.contains(base_struct)) {
        return try getOrCreateEnumDestructor(self, base_struct);
    }
    const is_storage = storageElem(type_name) != null;

    if (!is_storage and !self.structs.contains(base_struct)) {
        return null;
    }

    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);

    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| {
        return existing;
    }

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);

    const saved_instantiation = self.current_instantiation;
    const saved_method_subst = self.current_method_subst;
    self.current_instantiation = type_name;
    self.current_method_subst = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_method_subst = saved_method_subst;
    }

    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);

    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const self_val = core.LLVMGetParam(dest_fn, 0);

    const delete_method_name = try self.methodSymbol(type_name, "delete");
    defer self.allocator.free(delete_method_name);
    const delete_bare = try std.fmt.allocPrint(self.allocator, "{s}_delete", .{base_struct});
    defer self.allocator.free(delete_bare);
    const delete_method_name_z = try self.allocator.dupeZ(u8, delete_method_name);
    defer self.allocator.free(delete_method_name_z);
    const delete_bare_z = try self.allocator.dupeZ(u8, delete_bare);
    defer self.allocator.free(delete_bare_z);

    if (core.LLVMGetNamedFunction(self.module, delete_method_name_z) orelse core.LLVMGetNamedFunction(self.module, delete_bare_z)) |del_fn| {
        const del_t = core.LLVMGlobalGetValueType(del_fn);

        if (core.LLVMCountParamTypes(del_t) == 1) {
            var del_args = [_]types.LLVMValueRef{self_val};
            _ = core.LLVMBuildCall2(self.builder, del_t, del_fn, &del_args, 1, "");
        }
    }

    if (storageElem(type_name)) |elem| {
        try buildStorageDestructor(self, dest_fn, elem);
        _ = core.LLVMBuildRetVoid(self.builder);
        if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
        return dest_fn;
    }

    if (self.structs.get(base_struct)) |s| {
        for (s.fields) |field| {
            const field_type = try self.substituteFieldType(type_name, try self.typeRefToString(field.type_name));

            const is_ref = self.isOwnedDeclaredType(field.type_name, field_type);
            if (is_ref) {
                const offset = try self.getFieldOffset(base_struct, field.name);
                const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                const addr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "field_addr");

                const llvm_field_type = self.toLLVMType(field.type_name);
                const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
                const loaded_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_load");
                const casted_field_val = self.castToValType(loaded_field_val, field.type_name);

                const field_dest = try self.getOrCreateDestructor(field_type);
                try self.compileRelease(casted_field_val, field_dest);
            }
        }
    }

    _ = core.LLVMBuildRetVoid(self.builder);

    if (saved_ip) |sip| {
        core.LLVMPositionBuilderAtEnd(self.builder, sip);
    }

    return dest_fn;
}

fn getOrCreateStructDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (st.get(t) != .struct_) return null;
    const stype = st.get(t).struct_;
    const sm = sema_shadow.live_sema orelse {

        const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
        return try self.getOrCreateDestructor(nm);
    };
    const sym = sm.tab.symbolAt(stype.decl);
    if (sym.decl != .struct_) {
        const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
        return try self.getOrCreateDestructor(nm);
    }
    const decl = sym.decl.struct_;

    if (sema_shadow.report_enabled) diffStructFields(self, t);

    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const base_struct = getStructBaseName(type_name);

    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);

    const saved_instantiation = self.current_instantiation;
    const saved_method_subst = self.current_method_subst;
    self.current_instantiation = type_name;
    self.current_method_subst = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_method_subst = saved_method_subst;
    }

    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const self_val = core.LLVMGetParam(dest_fn, 0);

    const delete_method_name = try self.methodSymbol(type_name, "delete");
    defer self.allocator.free(delete_method_name);
    const delete_bare = try std.fmt.allocPrint(self.allocator, "{s}_delete", .{base_struct});
    defer self.allocator.free(delete_bare);
    const del_z = try self.allocator.dupeZ(u8, delete_method_name);
    defer self.allocator.free(del_z);
    const del_bare_z = try self.allocator.dupeZ(u8, delete_bare);
    defer self.allocator.free(del_bare_z);
    if (core.LLVMGetNamedFunction(self.module, del_z) orelse core.LLVMGetNamedFunction(self.module, del_bare_z)) |del_fn| {
        const del_t = core.LLVMGlobalGetValueType(del_fn);
        if (core.LLVMCountParamTypes(del_t) == 1) {
            var del_args = [_]types.LLVMValueRef{self_val};
            _ = core.LLVMBuildCall2(self.builder, del_t, del_fn, &del_args, 1, "");
        }
    }

    for (decl.fields) |field| {
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const scopes = [_]lower.ParamScope{.{ .owner = stype.decl, .names = decl.type_params }};
        l.param_scopes = &scopes;

        const concrete: ?typesys.TypeId = blk: {
            const raw = l.lower(field.type_name) catch break :blk null;
            break :blk subst.substitute(&sm.store, raw, stype.decl, stype.args) catch null;
        };
        const is_ref = if (concrete) |c|
            self.isOwnedTypeId(c)
        else str_blk: {
            const fs = self.typeRefToString(field.type_name) catch break :str_blk false;
            const ft = self.substituteFieldType(type_name, fs) catch break :str_blk false;
            break :str_blk self.isOwnedDeclaredType(field.type_name, ft);
        };
        if (!is_ref) continue;

        const offset = try self.getFieldOffset(base_struct, field.name);
        const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
        const addr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "field_addr");
        const llvm_field_type = self.toLLVMType(field.type_name);
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
        const loaded_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_load");
        const casted_field_val = self.castToValType(loaded_field_val, field.type_name);

        const field_dest = if (concrete) |c|
            try self.getOrCreateDestructorByTypeId(c)
        else str_blk: {
            const fs = self.typeRefToString(field.type_name) catch break :str_blk null;
            const ft = self.substituteFieldType(type_name, fs) catch break :str_blk null;
            break :str_blk try self.getOrCreateDestructor(ft);
        };
        try self.compileRelease(casted_field_val, field_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn getOrCreateErrUnionDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;
    if (sema_shadow.report_enabled) diffErrUnionArms(self, t);
    const eu = st.get(t).error_union;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "d_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "d_tag");
    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "d_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "d_pay_ptr");
    const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "d_pay");

    const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "d_is_err");
    const err_bb = core.LLVMAppendBasicBlock(dest_fn, "d_err");
    const ok_bb = core.LLVMAppendBasicBlock(dest_fn, "d_ok");
    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "d_done");
    _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
    if (self.isOwnedTypeId(eu.err)) {
        const d = try self.getOrCreateDestructorByTypeId(eu.err);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    if (self.isOwnedTypeId(eu.ok)) {
        const d = try self.getOrCreateDestructorByTypeId(eu.ok);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn getOrCreateErrUnionDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    const parts = self.errUnionParts(type_name) orelse return null;
    defer self.allocator.free(parts.ok);
    defer self.allocator.free(parts.err);

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "d_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "d_tag");
    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "d_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "d_pay_ptr");
    const payload = core.LLVMBuildLoad2(self.builder, self.val_type, pay_ptr, "d_pay");

    const is_err = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, 1, 0), "d_is_err");
    const err_bb = core.LLVMAppendBasicBlock(dest_fn, "d_err");
    const ok_bb = core.LLVMAppendBasicBlock(dest_fn, "d_ok");
    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "d_done");
    _ = core.LLVMBuildCondBr(self.builder, is_err, err_bb, ok_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
    if (self.isOwnedErrUnionPayloadByName(type_name, true, parts.err)) {
        const d = try self.getOrCreateDestructor(parts.err);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    if (self.isOwnedErrUnionPayloadByName(type_name, false, parts.ok)) {
        const d = try self.getOrCreateDestructor(parts.ok);
        try self.compileRelease(payload, d);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn getOrCreateEnumDestructor(self: *LlvmCompiler, enum_name: []const u8) anyerror!?types.LLVMValueRef {
    if (!enumIsTaggedUnion(self, enum_name)) return null;
    const enum_decl = self.enums.get(enum_name).?;

    const dest_name = try destructorName(self.allocator, enum_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: u32 = 8;
    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "en_tag_ptr");
    const tag = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "en_tag");

    const done_bb = core.LLVMAppendBasicBlock(dest_fn, "en_done");

    for (enum_decl.variants, 0..) |v, idx| {
        if (v.type_name == null and v.fields == null) continue;

        const rel_bb = core.LLVMAppendBasicBlock(dest_fn, "en_rel");
        const next_bb = core.LLVMAppendBasicBlock(dest_fn, "en_next");
        const is_v = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, tag, core.LLVMConstInt(self.val_type, @intCast(idx), 0), "en_is");
        _ = core.LLVMBuildCondBr(self.builder, is_v, rel_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, rel_bb);
        if (v.type_name) |ptref| {
            try releaseEnumPayloadSlot(self, box, word, ptref);
        }
        if (v.fields) |fields| {
            for (fields, 0..) |f, fidx| {
                try releaseEnumPayloadSlot(self, box, word + @as(u32, @intCast(fidx)) * word, f.type_name);
            }
        }
        _ = core.LLVMBuildBr(self.builder, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
    }
    _ = core.LLVMBuildBr(self.builder, done_bb);

    core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn releaseEnumPayloadSlot(self: *LlvmCompiler, box: types.LLVMValueRef, offset: u32, tref: ast.TypeRef) anyerror!void {
    const tstr = try self.typeRefToString(tref);
    if (!self.isOwnedDeclaredType(tref, tstr)) return;
    const addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, offset, 0), "en_pay_addr");
    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "en_pay_ptr");
    const val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "en_pay");
    const d = try self.getOrCreateDestructor(tstr);
    try self.compileRelease(val, d);
}

pub fn isTupleType(type_name: []const u8) bool {
    return type_name.len >= 2 and type_name[0] == '(' and type_name[type_name.len - 1] == ')' and
        std.mem.indexOf(u8, type_name, "=>") == null;
}

fn getOrCreateTupleDestructorByTypeId(self: *LlvmCompiler, t: typesys.TypeId) anyerror!?types.LLVMValueRef {
    const st = self.type_store orelse return null;

    if (sema_shadow.report_enabled) diffTupleElems(self, t);
    const elems = st.get(t).tuple;
    const type_name = sema_shadow.renderLegacy(self.allocator, st, t) catch return null;
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    for (elems, 0..) |elem_tid, idx| {
        if (!self.isOwnedTypeId(elem_tid)) continue;
        const offset = core.LLVMConstInt(self.val_type, @intCast(idx * word), 0);
        const addr = core.LLVMBuildAdd(self.builder, box, offset, "tup_elem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "tup_elem_ptr");
        const elem = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "tup_elem_load");
        const elem_dest = try self.getOrCreateDestructorByTypeId(elem_tid);
        try self.compileRelease(elem, elem_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

fn diffStructFields(self: *LlvmCompiler, t: typesys.TypeId) void {
    const sm = sema_shadow.live_sema orelse return;
    const st_store = self.type_store orelse return;
    if (st_store.get(t) != .struct_) return;
    const stype = st_store.get(t).struct_;
    const sym = sm.tab.symbolAt(stype.decl);
    if (sym.decl != .struct_) return;
    const decl = sym.decl.struct_;
    const type_name = sema_shadow.renderLegacy(self.allocator, st_store, t) catch return;
    for (decl.fields) |field| {

        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const scopes = [_]lower.ParamScope{.{ .owner = stype.decl, .names = decl.type_params }};
        l.param_scopes = &scopes;
        const raw = l.lower(field.type_name) catch continue;
        const concrete = subst.substitute(&sm.store, raw, stype.decl, stype.args) catch continue;
        const store_owned = self.isOwnedTypeId(concrete);
        const store_name = sema_shadow.renderLegacy(self.allocator, st_store, concrete) catch continue;

        const field_str = self.typeRefToString(field.type_name) catch continue;
        const field_type = self.substituteFieldType(type_name, field_str) catch continue;
        const str_owned = self.isOwnedDeclaredType(field.type_name, field_type);

        _ = store_name;
        if (store_owned == str_owned) {
            sema_shadow.struct_field_agree += 1;
        } else {
            sema_shadow.struct_field_disagree += 1;
            sema_shadow.struct_field_last = std.fmt.allocPrint(self.allocator, "{s}.{s}: store-owned={} vs parse-owned={} ('{s}')", .{ type_name, field.name, store_owned, str_owned, field_type }) catch type_name;
        }
    }
}

fn diffErrUnionArms(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .error_union) return;
    const eu = st.get(t).error_union;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    const parts = self.errUnionParts(name) orelse {
        sema_shadow.erru_elem_disagree += 1;
        sema_shadow.erru_elem_last = name;
        return;
    };
    defer self.allocator.free(parts.ok);
    defer self.allocator.free(parts.err);
    const ok_name = sema_shadow.renderLegacy(self.allocator, st, eu.ok) catch return;
    const err_name = sema_shadow.renderLegacy(self.allocator, st, eu.err) catch return;
    const ok_ok = self.isOwnedTypeId(eu.ok) == self.isOwnedErrUnionPayloadByName(name, false, parts.ok) and std.mem.eql(u8, ok_name, parts.ok);
    const err_ok = self.isOwnedTypeId(eu.err) == self.isOwnedErrUnionPayloadByName(name, true, parts.err) and std.mem.eql(u8, err_name, parts.err);
    if (ok_ok and err_ok) sema_shadow.erru_elem_agree += 1 else {
        sema_shadow.erru_elem_disagree += 1;
        sema_shadow.erru_elem_last = name;
    }
}

fn diffStorageElem(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .storage) return;
    const elem_tid = st.get(t).storage;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    const elem_str = storageElem(name) orelse {
        sema_shadow.storage_elem_disagree += 1;
        sema_shadow.storage_elem_last = name;
        return;
    };
    const store_name = sema_shadow.renderLegacy(self.allocator, st, elem_tid) catch return;
    if (self.isOwnedTypeId(elem_tid) == self.isOwnedStorageElemByName(elem_str) and std.mem.eql(u8, store_name, elem_str))
        sema_shadow.storage_elem_agree += 1
    else {
        sema_shadow.storage_elem_disagree += 1;
        sema_shadow.storage_elem_last = name;
    }
}

fn diffTupleElems(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store orelse return;
    if (st.get(t) != .tuple) return;
    const elems = st.get(t).tuple;
    const name = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
    if (elems.len != countTupleElements(name)) {
        sema_shadow.tuple_elem_disagree += 1;
        sema_shadow.tuple_elem_last = name;
        return;
    }
    for (elems, 0..) |elem, idx| {
        const store_owned = self.isOwnedTypeId(elem);
        const store_name = sema_shadow.renderLegacy(self.allocator, st, elem) catch continue;
        const str_elem = LlvmCompiler.getTupleElementType(self.allocator, name, idx) catch continue;
        defer self.allocator.free(str_elem);
        const str_owned = self.isOwnedTupleElemByName(name, idx, str_elem);
        if (store_owned == str_owned and std.mem.eql(u8, store_name, str_elem)) {
            sema_shadow.tuple_elem_agree += 1;
        } else {
            sema_shadow.tuple_elem_disagree += 1;
            sema_shadow.tuple_elem_last = name;
        }
    }
}

fn getOrCreateTupleDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {
    const dest_name = try destructorName(self.allocator, type_name);
    defer self.allocator.free(dest_name);
    const dest_name_z = try self.allocator.dupeZ(u8, dest_name);
    defer self.allocator.free(dest_name_z);
    if (core.LLVMGetNamedFunction(self.module, dest_name_z)) |existing| return existing;

    var params = [_]types.LLVMTypeRef{self.val_type};
    const fn_type = core.LLVMFunctionType(self.void_type, &params, 1, 0);
    const dest_fn = core.LLVMAddFunction(self.module, dest_name_z, fn_type);
    const entry_bb = core.LLVMAppendBasicBlock(dest_fn, "entry");
    const saved_ip = core.LLVMGetInsertBlock(self.builder);
    core.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
    const box = core.LLVMGetParam(dest_fn, 0);

    const word: usize = 8;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        const elem_ty = try LlvmCompiler.getTupleElementType(self.allocator, type_name, idx);

        if (idx >= countTupleElements(type_name)) break;
        defer self.allocator.free(elem_ty);
        if (!self.isOwnedTupleElemByName(type_name, idx, elem_ty)) continue;
        const offset = core.LLVMConstInt(self.val_type, @intCast(idx * word), 0);
        const addr = core.LLVMBuildAdd(self.builder, box, offset, "tup_elem_addr");
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "tup_elem_ptr");
        const elem = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "tup_elem_load");
        const elem_dest = try self.getOrCreateDestructor(elem_ty);
        try self.compileRelease(elem, elem_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

pub fn countTupleElements(type_name: []const u8) usize {
    if (!isTupleType(type_name)) return 0;
    const inner = type_name[1 .. type_name.len - 1];
    if (inner.len == 0) return 0;
    var depth: usize = 0;
    var n: usize = 1;
    for (inner) |c| {
        switch (c) {
            '<', '(' => depth += 1,
            '>', ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) n += 1;
            },
            else => {},
        }
    }
    return n;
}

pub fn errUnionParts(self: *LlvmCompiler, name: []const u8) ?struct { ok: []const u8, err: []const u8 } {
    const pre = "ErrUnion(";
    if (!std.mem.startsWith(u8, name, pre) or !std.mem.endsWith(u8, name, ")")) return null;
    const inner = name[pre.len .. name.len - 1];
    var depth: usize = 0;
    for (inner, 0..) |c, i| {
        switch (c) {
            '<', '(' => depth += 1,
            '>', ')' => { if (depth > 0) depth -= 1; },
            ',' => {
                if (depth == 0) {
                    const ok = self.allocator.dupe(u8, inner[0..i]) catch return null;
                    const err = self.allocator.dupe(u8, inner[i + 1 ..]) catch {
                        self.allocator.free(ok);
                        return null;
                    };
                    return .{ .ok = ok, .err = err };
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn buildErrUnion(self: *LlvmCompiler, val: types.LLVMValueRef, is_err: bool, union_name: []const u8) anyerror!types.LLVMValueRef {
    const word: usize = 8;
    const box = try self.compileAlloc(core.LLVMConstInt(self.val_type, @intCast(word * 2), 0));

    const parts = self.errUnionParts(union_name);
    if (parts) |pp| {
        defer self.allocator.free(pp.ok);
        defer self.allocator.free(pp.err);
        const payload_ty = if (is_err) pp.err else pp.ok;
        if (self.isOwnedErrUnionPayloadByName(union_name, is_err, payload_ty)) try self.compileRetain(val);
    }

    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, box, core.LLVMPointerType(self.val_type, 0), "eu_tag_ptr");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, if (is_err) 1 else 0, 0), tag_ptr);

    const pay_addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, @intCast(word), 0), "eu_pay_addr");
    const pay_ptr = core.LLVMBuildIntToPtr(self.builder, pay_addr, core.LLVMPointerType(self.val_type, 0), "eu_pay_ptr");
    _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(val, self.val_type), pay_ptr);
    return box;
}

pub fn releaseLocalByName(self: *LlvmCompiler, name: []const u8, type_name: []const u8) anyerror!void {
    const alloca_val = self.locals.get(name) orelse return;
    const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "blk_rel_load");

    const tid: ?typesys.TypeId = if (self.current_local_type_ids) |ids| ids.get(name) else null;
    const dest = try self.getOrCreateDestructorPreferId(type_name, tid);
    try self.compileRelease(loaded, dest);

    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), alloca_val);
}

pub fn releaseLocalVariables(self: *LlvmCompiler) anyerror!void {
    const local_types = self.current_local_types orelse return;
    var iter = local_types.iterator();
    while (iter.next()) |entry| {
        const var_name = entry.key_ptr.*;
        const var_type = entry.value_ptr.*;

        if (std.mem.eql(u8, var_name, "self")) {
            if (self.current_function_name) |func_name| {
                if (std.mem.endsWith(u8, func_name, "_delete") or
                    std.mem.endsWith(u8, func_name, "_init") or
                    std.mem.endsWith(u8, func_name, "_new")) {
                    continue;
                }
            }
        }

        if (self.isOwnedLocal(var_name, var_type)) {
            if (self.current_param_names) |params| {
                var is_param = false;
                for (params) |p| {
                    if (std.mem.eql(u8, p, var_name)) {
                        is_param = true;
                        break;
                    }
                }
                if (is_param) continue;
            }
            if (self.current_function_name) |func_name| {
                const key = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{func_name, var_name}) catch "";
                if (key.len > 0) {
                    defer self.allocator.free(key);
                    if (self.captured_globals.contains(key)) {
                        continue;
                    }
                }
            }
            if (self.locals.get(var_name)) |alloca_val| {
                const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "var_rel_load");

                const tid: ?typesys.TypeId = if (self.current_local_type_ids) |ids| ids.get(var_name) else null;
                const dest = try self.getOrCreateDestructorPreferId(var_type, tid);
                try self.compileRelease(loaded, dest);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Prototype: compile-time retain/release elision (borrowed-field pattern).
//
// Removes a defensive `nova_retain` + its paired `nova_release`(s) when a local
// slot only ever holds a value copied out of a BORROWED PARAMETER's field and
// never escapes (used only for null-checks, borrowed call-args, or its own
// release). The parameter is caller-owned and alive across the whole call, so
// its sub-object cannot be freed underneath us -> the retain/release is net-zero.
//
// Gated by NOVA_ARC_ELIDE (elide_enabled). Off = today's codegen, unchanged.
// This is a conservative peephole: any shape it can't prove safe is left alone.
pub var elide_enabled: bool = false;
pub var elide_count: usize = 0;

fn callTargetName(inst: types.LLVMValueRef) ?[]const u8 {
    if (core.LLVMGetInstructionOpcode(inst) != .LLVMCall) return null;
    const n = core.LLVMGetNumOperands(inst);
    if (n < 1) return null;
    const callee = core.LLVMGetOperand(inst, @intCast(n - 1)); // callee is the last operand
    var len: usize = 0;
    const name_c = core.LLVMGetValueName2(callee, &len);
    if (len == 0) return null;
    return name_c[0..len];
}

fn isNamedCall(inst: types.LLVMValueRef, want: []const u8) bool {
    const nm = callTargetName(inst) orelse return false;
    return std.mem.eql(u8, nm, want);
}

// sv must be: ptrtoint( load( inttoptr( add( load(param_slot), CONST ) ) ) )
fn tracesBorrowedParamField(sv: types.LLVMValueRef, param_slots: []const types.LLVMValueRef) bool {
    if (core.LLVMIsAInstruction(sv) == null) return false;
    if (core.LLVMGetInstructionOpcode(sv) != .LLVMPtrToInt) return false;
    const field_load = core.LLVMGetOperand(sv, 0);
    if (core.LLVMIsAInstruction(field_load) == null or core.LLVMGetInstructionOpcode(field_load) != .LLVMLoad) return false;
    const field_ptr = core.LLVMGetOperand(field_load, 0);
    if (core.LLVMIsAInstruction(field_ptr) == null or core.LLVMGetInstructionOpcode(field_ptr) != .LLVMIntToPtr) return false;
    const addr = core.LLVMGetOperand(field_ptr, 0);
    if (core.LLVMIsAInstruction(addr) == null or core.LLVMGetInstructionOpcode(addr) != .LLVMAdd) return false;
    const base_load = core.LLVMGetOperand(addr, 0);
    if (core.LLVMIsAInstruction(base_load) == null or core.LLVMGetInstructionOpcode(base_load) != .LLVMLoad) return false;
    const base_slot = core.LLVMGetOperand(base_load, 0);
    for (param_slots) |ps| if (ps == base_slot) return true;
    return false;
}

fn valueIsRetained(sv: types.LLVMValueRef) ?types.LLVMValueRef {
    var use = core.LLVMGetFirstUse(sv);
    while (use != null) : (use = core.LLVMGetNextUse(use)) {
        const user = core.LLVMGetUser(use);
        if (isNamedCall(user, "nova_retain")) return user;
    }
    return null;
}

pub fn elideBorrowedArc(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
    if (!elide_enabled) return;
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        elideBorrowedArcInFn(self, fnv);
    }
}

fn elideBorrowedArcInFn(self: *LlvmCompiler, fnv: types.LLVMValueRef) void {
    const a = self.allocator;

    // 1) param-holding alloca slots: `store %param, %alloca` in the function.
    var param_slots = std.ArrayList(types.LLVMValueRef).empty;
    defer param_slots.deinit(a);
    const nparams = core.LLVMCountParams(fnv);
    var bb = core.LLVMGetFirstBasicBlock(fnv);
    while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
        var inst = core.LLVMGetFirstInstruction(bb);
        while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
            if (core.LLVMGetInstructionOpcode(inst) != .LLVMStore) continue;
            const val = core.LLVMGetOperand(inst, 0);
            const ptr = core.LLVMGetOperand(inst, 1);
            if (core.LLVMIsAAllocaInst(ptr) == null) continue;
            var pi: c_uint = 0;
            while (pi < nparams) : (pi += 1) {
                if (core.LLVMGetParam(fnv, pi) == val) {
                    param_slots.append(a, ptr) catch {};
                    break;
                }
            }
        }
    }
    if (param_slots.items.len == 0) return;

    // 2) each alloca: is it a non-escaping borrow of a param field?
    var to_erase = std.ArrayList(types.LLVMValueRef).empty;
    defer to_erase.deinit(a);

    bb = core.LLVMGetFirstBasicBlock(fnv);
    while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
        var inst = core.LLVMGetFirstInstruction(bb);
        while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
            if (core.LLVMIsAAllocaInst(inst) == null) continue;
            const slot = inst;

            var owned_store: ?types.LLVMValueRef = null; // the ptrtoint stored value
            var retain_inst: ?types.LLVMValueRef = null;
            var releases = std.ArrayList(types.LLVMValueRef).empty;
            defer releases.deinit(a);
            var ok = true;
            var owned_store_count: usize = 0;

            var use = core.LLVMGetFirstUse(slot);
            scan: while (use != null) : (use = core.LLVMGetNextUse(use)) {
                const user = core.LLVMGetUser(use);
                const opc = core.LLVMGetInstructionOpcode(user);
                if (opc == .LLVMStore and core.LLVMGetOperand(user, 1) == slot) {
                    // a store INTO the slot
                    const sv = core.LLVMGetOperand(user, 0);
                    if (core.LLVMIsAConstantInt(sv) != null) continue :scan; // zero-init: ignore
                    if (tracesBorrowedParamField(sv, param_slots.items)) {
                        if (valueIsRetained(sv)) |r| {
                            owned_store = sv;
                            retain_inst = r;
                            owned_store_count += 1;
                            continue :scan;
                        }
                    }
                    ok = false; // unknown store into the slot
                    break :scan;
                } else if (opc == .LLVMStore and core.LLVMGetOperand(user, 0) == slot) {
                    ok = false; // slot's ADDRESS stored somewhere -> escapes
                    break :scan;
                } else if (opc == .LLVMLoad and core.LLVMGetOperand(user, 0) == slot) {
                    // every consumer of this load must be a borrow use
                    var luse = core.LLVMGetFirstUse(user);
                    while (luse != null) : (luse = core.LLVMGetNextUse(luse)) {
                        const luser = core.LLVMGetUser(luse);
                        const lopc = core.LLVMGetInstructionOpcode(luser);
                        if (lopc == .LLVMICmp) continue;
                        if (isNamedCall(luser, "nova_release")) {
                            releases.append(a, luser) catch {};
                            continue;
                        }
                        if (lopc == .LLVMCall) {
                            // borrowed call-arg: the load must be an ARGUMENT, not the callee
                            const n = core.LLVMGetNumOperands(luser);
                            if (n >= 1 and core.LLVMGetOperand(luser, @intCast(n - 1)) == user) {
                                ok = false; // used as the callee (function pointer) -> bail
                                break :scan;
                            }
                            continue;
                        }
                        ok = false; // Ret / Store-as-value / PtrToInt / GEP / ... -> escapes
                        break :scan;
                    }
                } else {
                    ok = false; // any other use of the slot pointer -> bail
                    break :scan;
                }
            }

            if (ok and owned_store_count == 1 and retain_inst != null) {
                to_erase.append(a, retain_inst.?) catch {};
                for (releases.items) |r| to_erase.append(a, r) catch {};
                elide_count += 1;
            }
        }
    }

    for (to_erase.items) |ins| core.LLVMInstructionEraseFromParent(ins);
}

test "isUntypeablePlaceholder: whole-string placeholders match, real types and fn-types do not" {
    const testing = std.testing;

    try testing.expect(isUntypeablePlaceholder(""));
    try testing.expect(isUntypeablePlaceholder("unresolved"));
    try testing.expect(isUntypeablePlaceholder("<unresolved>"));
    try testing.expect(isUntypeablePlaceholder("<tuple>"));
    try testing.expect(isUntypeablePlaceholder("<array>"));
    try testing.expect(isUntypeablePlaceholder("<fn>"));

    try testing.expect(!isUntypeablePlaceholder("string"));
    try testing.expect(!isUntypeablePlaceholder("List<string>"));
    try testing.expect(!isUntypeablePlaceholder("Storage<string>"));
    try testing.expect(!isUntypeablePlaceholder("(string,int)"));

    try testing.expect(!isUntypeablePlaceholder("(<unresolved>, i32) -> i32"));
    try testing.expect(!isUntypeablePlaceholder("(i32) -> void"));
}
