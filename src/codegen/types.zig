const std = @import("std");
const ast = @import("../ast.zig");
const sema_shadow = @import("../sema/shadow.zig");
const sema_mono = @import("../sema/mono.zig");
const subst_mod = @import("../sema/subst.zig");
const lower = @import("../sema/lower.zig");
const arc_mod = @import("arc.zig");
const typesys = @import("../types.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;

const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;

pub fn getStructBaseName(name: []const u8) []const u8 {
    var base = name;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot_pos| {
        base = base[dot_pos + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, base, '<')) |pos| {
        return base[0..pos];
    }
    return base;
}

fn canonicalPrimAlias(tok: []const u8) ?[]const u8 {
    const pairs = [_]struct { a: []const u8, c: []const u8 }{
        .{ .a = "int", .c = "i32" },   .{ .a = "uint", .c = "u32" },
        .{ .a = "long", .c = "i64" },  .{ .a = "ulong", .c = "u64" },
        .{ .a = "short", .c = "i16" }, .{ .a = "ushort", .c = "u16" },
        .{ .a = "byte", .c = "i8" },   .{ .a = "ubyte", .c = "u8" },
        .{ .a = "float", .c = "f32" }, .{ .a = "double", .c = "f64" },
    };
    for (pairs) |p| if (std.mem.eql(u8, tok, p.a)) return p.c;
    return null;
}

fn isTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

pub fn mangleTypeName(allocator: std.mem.Allocator, type_name: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < type_name.len) {
        const c = type_name[i];
        if (isTokenChar(c)) {

            const start = i;
            while (i < type_name.len and isTokenChar(type_name[i])) : (i += 1) {}
            const tok = type_name[start..i];
            try buf.appendSlice(allocator, canonicalPrimAlias(tok) orelse tok);
            continue;
        }
        switch (c) {
            '<', '>', ',', ' ' => {
                if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '_') {
                    try buf.append(allocator, '_');
                }
            },

            '(' => try buf.appendSlice(allocator, "_lp"),
            ')' => try buf.appendSlice(allocator, "_rp"),
            '-' => try buf.appendSlice(allocator, "_da"),
            '=' => try buf.appendSlice(allocator, "_eq"),
            else => try buf.append(allocator, c),
        }
        i += 1;
    }

    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

pub fn qualifySelfType(self: *LlvmCompiler, type_name: []const u8) []const u8 {
    const inst = self.current_instantiation orelse return type_name;
    if (std.mem.indexOfScalar(u8, type_name, '<') != null) return type_name;
    if (!std.mem.eql(u8, type_name, getStructBaseName(inst))) return type_name;
    return inst;
}

pub fn methodSymbol(self: *LlvmCompiler, owner: []const u8, method: []const u8) ![]const u8 {
    const mangled = try mangleTypeName(self.allocator, owner);
    defer self.allocator.free(mangled);
    return std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled, method });
}

pub fn instantiationsOf(self: *LlvmCompiler, s: ast.StructDecl) ![]const ?[]const u8 {
    var out = std.ArrayListUnmanaged(?[]const u8).empty;
    errdefer out.deinit(self.allocator);
    try out.append(self.allocator, null);

    if (s.type_params.len == 0) return out.toOwnedSlice(self.allocator);

    const insts = sema_mono.live_instantiations orelse return out.toOwnedSlice(self.allocator);

    for (insts) |inst| {

        if (std.mem.eql(u8, getStructBaseName(inst), s.name)) {
            try out.append(self.allocator, inst);
        }
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn isStructType(self: *LlvmCompiler, type_name: []const u8) bool {
    const base = getStructBaseName(type_name);
    return self.structs.contains(base) or self.unions.contains(base) or self.enums.contains(base);
}

pub const CgRepr = enum { i1, i8, i16, i32, word, i64, f32, f64 };

pub fn reprBitWidth(repr: CgRepr) u32 {
    return switch (repr) {
        .i1 => 1,
        .i8 => 8,
        .i16 => 16,
        .i32 => 32,
        .word => 64,
        .i64 => 64,
        .f32 => 32,
        .f64 => 64,
    };
}

pub const CgPrim = struct { repr: CgRepr, signed: bool };

pub fn cgPrim(name: []const u8) ?CgPrim {
    const T = struct { n: []const u8, r: CgRepr, s: bool };
    const table = [_]T{
        .{ .n = "bool", .r = .i1, .s = false },
        .{ .n = "byte", .r = .i8, .s = false },   .{ .n = "ubyte", .r = .i8, .s = false },
        .{ .n = "u8", .r = .i8, .s = false },      .{ .n = "sbyte", .r = .i8, .s = true },
        .{ .n = "i8", .r = .i8, .s = true },
        .{ .n = "short", .r = .i16, .s = true },   .{ .n = "i16", .r = .i16, .s = true },
        .{ .n = "ushort", .r = .i16, .s = false }, .{ .n = "u16", .r = .i16, .s = false },
        .{ .n = "int", .r = .i32, .s = true },     .{ .n = "i32", .r = .i32, .s = true },
        .{ .n = "uint", .r = .i32, .s = false },   .{ .n = "u32", .r = .i32, .s = false },
        .{ .n = "long", .r = .i64, .s = true },    .{ .n = "i64", .r = .i64, .s = true },
        .{ .n = "ulong", .r = .i64, .s = false },  .{ .n = "u64", .r = .i64, .s = false },
        .{ .n = "float", .r = .f32, .s = true },   .{ .n = "f32", .r = .f32, .s = true },
        .{ .n = "double", .r = .f64, .s = true },  .{ .n = "f64", .r = .f64, .s = true },

        .{ .n = "ptr", .r = .word, .s = false },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e.n)) return .{ .repr = e.r, .signed = e.s };
    }
    return null;
}

pub fn isPrimitiveTypeName(type_name: []const u8) bool {

    return cgPrim(type_name) != null or
        std.mem.eql(u8, type_name, "void") or
        std.mem.eql(u8, type_name, "any");
}

pub fn llvmForRepr(self: *LlvmCompiler, repr: CgRepr) types.LLVMTypeRef {
    return switch (repr) {
        .i1 => self.i1_type,
        .i8 => self.i8_type,
        .i16 => core.LLVMInt16Type(),

        .i32 => self.i32_type,
        .word => self.val_type,
        .i64 => self.i64_type,
        .f32 => core.LLVMFloatType(),
        .f64 => core.LLVMDoubleType(),
    };
}

pub fn toLLVMType(self: *LlvmCompiler, type_ref: ast.TypeRef) types.LLVMTypeRef {
    switch (type_ref) {
        .ident => |name| {
            if (cgPrim(name)) |p| return self.llvmForRepr(p.repr);
            return self.ptr_type;
        },
        else => return self.ptr_type,
    }
}

pub fn slotTypeForLocal(self: *LlvmCompiler, type_name: ?[]const u8) types.LLVMTypeRef {
    return self.slotTypeForLocalId(type_name, null);
}

pub fn slotTypeForLocalId(self: *LlvmCompiler, type_name: ?[]const u8, type_id: ?typesys.TypeId) types.LLVMTypeRef {
    if (type_id) |tid| {
        if (self.valueOptionalInner(tid) != null) return self.val_type;
    }
    if (type_name) |tn| {
        if (cgPrim(tn)) |p| {
            if (p.repr == .f64 or p.repr == .f32) return core.LLVMDoubleType();
        }
    }
    return self.val_type;
}

pub fn coerceToSlotType(self: *LlvmCompiler, val: types.LLVMValueRef, slot_ty: types.LLVMTypeRef) types.LLVMValueRef {
    const vt = core.LLVMTypeOf(val);
    if (vt == slot_ty) return val;
    const vk = core.LLVMGetTypeKind(vt);
    const sk = core.LLVMGetTypeKind(slot_ty);
    if (sk == .LLVMDoubleTypeKind and vk == .LLVMIntegerTypeKind) {
        return core.LLVMBuildBitCast(self.builder, val, slot_ty, "val_to_double");
    }
    if (sk == .LLVMIntegerTypeKind and vk == .LLVMDoubleTypeKind) {
        return core.LLVMBuildBitCast(self.builder, val, slot_ty, "double_to_val");
    }
    return val;
}

pub fn castToValType(self: *LlvmCompiler, val: types.LLVMValueRef, type_ref: ast.TypeRef) types.LLVMValueRef {
    const val_t = core.LLVMTypeOf(val);
    const val_kind = core.LLVMGetTypeKind(val_t);
    if (val_kind == .LLVMPointerTypeKind) {
        return core.LLVMBuildPtrToInt(self.builder, val, self.val_type, "ptr_to_int");
    }
    if (val_kind == .LLVMDoubleTypeKind) {
        return core.LLVMBuildBitCast(self.builder, val, self.val_type, "double_to_val");
    }
    if (val_kind == .LLVMFloatTypeKind) {
        const extended = core.LLVMBuildFPExt(self.builder, val, core.LLVMDoubleType(), "float_to_double");
        return core.LLVMBuildBitCast(self.builder, extended, self.val_type, "double_to_val");
    }
    if (val_kind == .LLVMIntegerTypeKind) {
        const val_width = core.LLVMGetIntTypeWidth(val_t);
        const target_width = core.LLVMGetIntTypeWidth(self.val_type);
        if (val_width < target_width) {
            const is_unsigned = blk: {

                if (type_ref == .ident) {
                    if (cgPrim(type_ref.ident)) |p| break :blk !p.signed;
                }
                break :blk false;
            };
            if (is_unsigned) {
                return core.LLVMBuildZExt(self.builder, val, self.val_type, "zext");
            } else {
                return core.LLVMBuildSExt(self.builder, val, self.val_type, "sext");
            }
        } else if (val_width > target_width) {
            return core.LLVMBuildTrunc(self.builder, val, self.val_type, "trunc");
        }
    }
    return val;
}

pub fn castFromValType(self: *LlvmCompiler, val: types.LLVMValueRef, target_type: types.LLVMTypeRef) types.LLVMValueRef {
    const val_t = core.LLVMTypeOf(val);
    const val_kind = core.LLVMGetTypeKind(val_t);
    const target_kind = core.LLVMGetTypeKind(target_type);
    if (target_kind == .LLVMPointerTypeKind) {
        if (val_kind == .LLVMIntegerTypeKind) {
            return core.LLVMBuildIntToPtr(self.builder, val, target_type, "int_to_ptr");
        }
    } else if (target_kind == .LLVMDoubleTypeKind) {
        return core.LLVMBuildBitCast(self.builder, val, target_type, "val_to_double");
    } else if (target_kind == .LLVMFloatTypeKind) {
        const double_val = core.LLVMBuildBitCast(self.builder, val, core.LLVMDoubleType(), "val_to_double");
        return core.LLVMBuildFPTrunc(self.builder, double_val, target_type, "double_to_float");
    } else if (target_kind == .LLVMIntegerTypeKind) {
        if (val_kind == .LLVMIntegerTypeKind) {
            const val_width = core.LLVMGetIntTypeWidth(val_t);
            const target_width = core.LLVMGetIntTypeWidth(target_type);
            if (val_width > target_width) {
                return core.LLVMBuildTrunc(self.builder, val, target_type, "trunc");
            } else if (val_width < target_width) {
                return core.LLVMBuildSExt(self.builder, val, target_type, "sext");
            }
        } else if (val_kind == .LLVMDoubleTypeKind and core.LLVMGetIntTypeWidth(target_type) == 64) {

            return core.LLVMBuildBitCast(self.builder, val, target_type, "double_to_val");
        } else if (val_kind == .LLVMFloatTypeKind and core.LLVMGetIntTypeWidth(target_type) == 64) {
            const extended = core.LLVMBuildFPExt(self.builder, val, core.LLVMDoubleType(), "float_to_double");
            return core.LLVMBuildBitCast(self.builder, extended, target_type, "double_to_val");
        }
    }
    return val;
}

pub fn typeRefToString(self: *LlvmCompiler, type_ref: ast.TypeRef) anyerror![]const u8 {
    switch (type_ref) {

        .ident => |name| return try self.substTypeParams(name),
        .optional => |opt| return try self.typeRefToString(opt.*),

        .error_union => |eu| {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, "ErrUnion(");
            try list.appendSlice(self.allocator, try self.typeRefToString(eu.ok.*));
            try list.appendSlice(self.allocator, ",");
            try list.appendSlice(self.allocator, try self.typeRefToString(eu.err.*));
            try list.appendSlice(self.allocator, ")");
            return try list.toOwnedSlice(self.allocator);
        },
        .tuple => |items| {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, "(");
            for (items, 0..) |item, idx| {
                if (idx > 0) try list.appendSlice(self.allocator, ",");
                const item_str = try self.typeRefToString(item);
                try list.appendSlice(self.allocator, item_str);
            }
            try list.appendSlice(self.allocator, ")");
            return try list.toOwnedSlice(self.allocator);
        },
        .generic => |g| {
            if (g.params.len == 0) return g.name;
            var list = std.ArrayList(u8).empty;
            defer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, g.name);
            try list.appendSlice(self.allocator, "<");
            for (g.params, 0..) |p, idx| {
                if (idx > 0) try list.appendSlice(self.allocator, ", ");
                const p_str = try self.typeRefToString(p);
                try list.appendSlice(self.allocator, p_str);
            }
            try list.appendSlice(self.allocator, ">");
            return try list.toOwnedSlice(self.allocator);
        },
        .fixed_array => |fa| {
            const elem_str = try self.typeRefToString(fa.element.*);
            return try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ elem_str, fa.length });
        },
        .func => |f| {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, "(");
            for (f.params, 0..) |p, idx| {
                if (idx > 0) try list.appendSlice(self.allocator, ", ");
                const p_str = try self.typeRefToString(p);
                try list.appendSlice(self.allocator, p_str);
            }
            try list.appendSlice(self.allocator, ") -> ");
            const ret_str = try self.typeRefToString(f.ret.*);
            try list.appendSlice(self.allocator, ret_str);
            return try list.toOwnedSlice(self.allocator);
        },
    }
}

pub fn isOptionalExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;
    const t = ir.typeOf(expr_ptr) orelse return false;
    return st.get(t) == .optional;
}

pub fn isOwnedExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;

    if (self.typeOfExprConcrete(expr_ptr)) |ct| {
        if (self.valueOptionalInner(ct) != null) return self.exprYieldsValoptBox(expr_ptr);
    }

    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct| {
            if (st.get(ct) != .unresolved and st.get(ct) != .type_param) return self.isOwnedTypeId(ct);
        }
    }
    const t_opt = ir.typeOf(expr_ptr);

    if (t_opt == null or st.get(t_opt.?) == .unresolved) {
        if (expr_ptr.kind == .ident) {
            if (self.current_local_types) |lt| {
                if (lt.get(expr_ptr.kind.ident)) |ts| return self.isOwnedLocal(expr_ptr.kind.ident, ts);
            }
        }
        return false;
    }
    return self.isOwnedTypeId(t_opt.?);
}

fn tdShadowDiff(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store.?;
    switch (st.get(t)) {
        .type_param => {

            const subd_opt: ?typesys.TypeId = if (self.current_instantiation_id) |inst_id|
                (if (self.typed_ir) |ir| ir.tpResolve(t, inst_id) else null)
            else
                null;
            if (subd_opt) |subd| {
                const keystone_ans = if (st.get(subd) == .enum_) isOwnedRenderedFallback(self, subd) else st.isOwned(subd);
                const string_ans = isOwnedRenderedFallback(self, t);
                if (keystone_ans == string_ans) sema_shadow.td_keystone_resolves += 1 else {
                    sema_shadow.td_keystone_disagree += 1;
                    sema_shadow.td_last_disagree = sema_shadow.renderLegacy(self.allocator, st, subd) catch "";
                    sema_shadow.td_last_disagree_typed = keystone_ans;
                    sema_shadow.td_last_disagree_string = string_ans;
                }
            } else if (self.current_instantiation_id == null) {
                sema_shadow.td_blocked_noctx += 1;
            } else sema_shadow.td_blocked_typeparam += 1;
        },
        .unresolved => sema_shadow.td_blocked_unresolved += 1,
        .enum_ => sema_shadow.td_blocked_enum += 1,
        .optional => |inner| tdShadowDiff(self, inner),
        else => {
            const typed = st.isOwned(t);
            const rendered = sema_shadow.renderLegacy(self.allocator, st, t) catch return;
            const str = self.legacyStringOwnership(rendered);
            if (typed == str) {
                sema_shadow.td_agree += 1;
            } else {
                sema_shadow.td_disagree += 1;
                sema_shadow.td_last_disagree = rendered;
                sema_shadow.td_last_disagree_typed = typed;
                sema_shadow.td_last_disagree_string = str;
            }
        },
    }
}

pub fn isOwnedTypeId(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    if (sema_shadow.report_enabled) tdShadowDiff(self, t);
    return switch (st.get(t)) {

        .unresolved => {
            std.debug.print(
                "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ownership decision asked of an UNTYPED value\x1b[0m\n" ++
                "  isOwnedTypeId reached an `.unresolved` TypeId. A caller took an ownership action on a\n" ++
                "  value sema never typed — a COMPILER bug (F2-5), not user code. Every ownership vehicle\n" ++
                "  must check `.unresolved` and fall back before deciding. Please report.\n",
                .{},
            );
            std.process.exit(70);
        },

        .type_param => blk: {
            if (self.current_instantiation_id) |inst| {
                if (self.typed_ir) |ir| {
                    if (ir.tpResolve(t, inst)) |concrete| break :blk st.isOwned(concrete);
                }
            }
            break :blk false;
        },

        .enum_ => st.isOwned(t),

        .optional => |inner| if (self.valueOptionalInner(t) != null) true else self.isOwnedTypeId(inner),

        else => st.isOwned(t),
    };
}

pub fn isOwnedLocal(self: *LlvmCompiler, name: []const u8, type_string: []const u8) bool {
    if (self.current_local_type_ids) |ids| {
        if (ids.get(name)) |tid| {

            if (self.type_store) |ts| {

                const k = ts.get(tid);
                if (k != .unresolved and k != .type_param) return self.isOwnedTypeId(tid);
            } else {
                return self.isOwnedTypeId(tid);
            }
        }
    }
    return self.ownedByName(type_string);
}

pub fn typeOfExprConcrete(self: *LlvmCompiler, expr_ptr: *const ast.Expression) ?typesys.TypeId {
    const ir = self.typed_ir orelse return null;
    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct| return ct;
    }
    return ir.typeOf(expr_ptr);
}

pub fn isStringExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .string;
        }
    }
    return false;
}

pub fn tupleElemTraitName(self: *LlvmCompiler, expr_ptr: *const ast.Expression, idx: usize) ?[]const u8 {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            if (info == .tuple and idx < info.tuple.len) {
                if (st.get(info.tuple[idx]) == .trait_) {
                    const name = sema_shadow.renderLegacy(self.allocator, st, info.tuple[idx]) catch return null;
                    if (self.traits.contains(name)) return name;
                }
            }
        }
    }
    return null;
}

pub fn isOwnedErrUnionOk(self: *LlvmCompiler, expr_ptr: *const ast.Expression, ok_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            {
                const info = st.get(tid);
                if (info == .error_union) return self.isOwnedTypeId(info.error_union.ok);
            }
        }
    }
    return self.ownedByName(ok_string);
}

pub fn isOwnedErrUnionErr(self: *LlvmCompiler, expr_ptr: *const ast.Expression, err_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            {
                const info = st.get(tid);
                if (info == .error_union) return self.isOwnedTypeId(info.error_union.err);
            }
        }
    }
    return self.ownedByName(err_string);
}

pub fn isOwnedStorageElem(self: *LlvmCompiler, obj_ptr: *const ast.Expression, elem_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, obj_ptr)) |tid| {
            {
                if (st.get(tid) == .storage) return self.isOwnedTypeId(st.get(tid).storage);
            }
        }
    }
    return self.ownedByName(elem_string);
}

pub fn typeIdForRenderedName(self: *LlvmCompiler, name: []const u8) ?typesys.TypeId {
    const store = sema_shadow.live_store orelse return null;
    if (self.rendered_name_ids == null) {
        var map: std.StringHashMapUnmanaged(typesys.TypeId) = .empty;
        const n = store.count();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id: typesys.TypeId = @enumFromInt(i);

            switch (store.get(id)) {
                .error_union, .tuple, .storage, .struct_ => {
                    const rn = sema_shadow.renderLegacy(self.allocator, store, id) catch continue;
                    map.put(self.allocator, rn, id) catch {
                        self.allocator.free(rn);
                        continue;
                    };
                },
                else => {},
            }
        }
        self.rendered_name_ids = map;
    }
    return self.rendered_name_ids.?.get(name);
}

pub fn isOwnedStorageElemByName(self: *LlvmCompiler, elem_string: []const u8) bool {
    const container = std.fmt.allocPrint(self.allocator, "Storage<{s}>", .{elem_string}) catch return self.ownedByName(elem_string);
    defer self.allocator.free(container);
    if (self.typeIdForRenderedName(container)) |tid| {
        if (self.type_store) |st| {
            if (st.get(tid) == .storage) return self.isOwnedTypeId(st.get(tid).storage);
        }
    }
    return self.ownedByName(elem_string);
}

pub fn isOwnedErrUnionPayloadByName(self: *LlvmCompiler, union_name: []const u8, is_err: bool, payload_string: []const u8) bool {
    if (self.typeIdForRenderedName(union_name)) |tid| {
        if (self.type_store) |st| {
            const info = st.get(tid);
            if (info == .error_union) {
                return self.isOwnedTypeId(if (is_err) info.error_union.err else info.error_union.ok);
            }
        }
    }
    return self.ownedByName(payload_string);
}

pub fn isOwnedTupleElemByName(self: *LlvmCompiler, tuple_name: []const u8, idx: usize, elem_string: []const u8) bool {
    if (self.typeIdForRenderedName(tuple_name)) |tid| {
        if (self.type_store) |st| {
            const info = st.get(tid);
            if (info == .tuple and idx < info.tuple.len) return self.isOwnedTypeId(info.tuple[idx]);
        }
    }
    return self.ownedByName(elem_string);
}

// L1 string->TypeId migration: recover a RESOLVED TypeId from a rendered type name, so an ownership
// decision made from a name-only site can defer to the single TypeId engine (isOwnedTypeId) instead
// of string-matching. Covers composites + struct-with-args via the rendered-name index, and plain
// named types (struct / enum / trait / primitive) via the sema lowerer -- the same lower path
// isOwnedDeclaredType uses. Returns null only for names with no concrete type: bare type parameters
// and instantiation-free generics (e.g. "T", "List<T>"), which are reachable only from erased
// generic bodies that monomorphization dead-strips.
pub fn tidForName(self: *LlvmCompiler, name: []const u8) ?typesys.TypeId {
    if (self.type_store) |st| {
        if (self.typeIdForRenderedName(name)) |tid| {
            if (nameResolvable(st, tid)) return tid;
        }
    }
    if (sema_shadow.live_sema) |sm| {
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const t = l.lower(.{ .ident = name }) catch return null;
        if (nameResolvable(&sm.store, t)) return t;
    }
    return null;
}

// A name resolves to a usable ownership answer for anything with a concrete type -- INCLUDING enums
// (isOwnedTypeId reads enum_tagged, the SAME "any variant has a payload" rule the string engine's
// enumIsTaggedUnion applied). Only a bare type parameter or an unresolved name has no answer from a
// name alone (no instantiation context), so those are rejected and handled by the erased default.
fn nameResolvable(store: *const typesys.TypeStore, t: typesys.TypeId) bool {
    return switch (store.get(t)) {
        .type_param, .unresolved => false,
        .optional => |inner| nameResolvable(store, inner),
        else => true,
    };
}

// The principled replacement for the legacy string-ownership fallback. A primitive is not owned (a
// language fact); anything with a recoverable TypeId defers to the ONE ownership engine; only a bare
// type parameter in an erased (dead-stripped) body has no concrete type to ask, and there the
// conservative owned=true default -- NOT a decision by user-type NAME -- is emitted into code mono
// discards. This is what lets the string ownership engine be retired for all real types.
pub fn ownedByName(self: *LlvmCompiler, name: []const u8) bool {
    sema_shadow.irct_live_calls += 1;
    if (isPrimitiveTypeName(name)) {
        sema_shadow.irct_primitive += 1;
        return false;
    }
    if (self.tidForName(name)) |tid| {
        sema_shadow.irct_resolved += 1;
        return self.isOwnedTypeId(tid);
    }
    sema_shadow.irct_string_decided += 1;
    return self.erasedOwnershipDefault(name);
}

pub fn isOwnedDeclaredType(self: *LlvmCompiler, tr: ast.TypeRef, string_fallback: []const u8) bool {
    if (sema_shadow.live_sema) |sm| {
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const t = l.lower(tr) catch return self.ownedByName(string_fallback);
        if (decidedDirectly(&sm.store, t)) return self.isOwnedTypeId(t);
    }
    return self.ownedByName(string_fallback);
}

pub fn tidForTypeRef(self: *LlvmCompiler, tr: ast.TypeRef) ?typesys.TypeId {
    const sm = sema_shadow.live_sema orelse return null;
    var l = lower.Lowerer.init(self.allocator, &sm.store);
    defer l.deinit();
    l.symtab = &sm.tab;
    const t = l.lower(tr) catch return null;
    if (sm.store.get(t) == .unresolved) return null;
    return t;
}

fn decidedDirectly(store: *const typesys.TypeStore, t: typesys.TypeId) bool {
    return switch (store.get(t)) {
        .enum_, .type_param, .unresolved => false,
        .optional => |inner| decidedDirectly(store, inner),
        else => true,
    };
}

fn isOwnedRenderedFallback(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    const rendered = sema_shadow.renderLegacy(self.allocator, st, t) catch return false;
    const subst = self.substTypeParams(rendered) catch return false;
    return self.legacyStringOwnership(subst);
}

pub fn scopedStructName(self: *LlvmCompiler, name: []const u8, file: []const u8) []const u8 {
    _ = self;
    if (sema_shadow.live_sema) |sm| {
        if (sm.tab.scopedNameFor(name, file)) |scoped| return scoped;
    }
    return name;
}

pub fn isCollidingStruct(self: *LlvmCompiler, name: []const u8) bool {
    _ = self;
    if (sema_shadow.live_sema) |sm| return sm.tab.colliding_types.contains(name);
    return false;
}

pub fn resolveExpressionTypeName(self: *LlvmCompiler, expr_ptr: *const ast.Expression) anyerror!?[]const u8 {
    const ir = self.typed_ir orelse return null;
    const st = self.type_store orelse return null;
    const t_opt = ir.typeOf(expr_ptr);
    if (t_opt == null or st.get(t_opt.?) == .unresolved) {

        if (expr_ptr.kind == .struct_init) {
            if (self.findEnumByVariant(expr_ptr.kind.struct_init.type_name)) |enum_name| return enum_name;
        }

        if (expr_ptr.kind == .ident) {
            if (self.current_local_types) |lt| {
                if (lt.get(expr_ptr.kind.ident)) |ts| return ts;
            }
        }
        return null;
    }
    const t = t_opt.?;

    return try self.substTypeParams(try sema_shadow.renderLegacy(self.allocator, st, t));
}

pub fn resolveCalleeName(self: *LlvmCompiler, callee_name: []const u8) ![]const u8 {
    if (self.hasFunction(callee_name)) {
        return callee_name;
    }

    if (self.current_instantiation) |inst| {
        const mono_name = try self.methodSymbol(inst, callee_name);
        if (self.hasFunction(mono_name)) {
            return mono_name;
        }
        self.allocator.free(mono_name);
    }
    if (self.current_struct_name) |struct_name| {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name, callee_name });
        if (self.hasFunction(full_name)) {
            return full_name;
        }
    }

    if (self.current_module_prefix) |mod_prefix| {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, callee_name });
        if (self.hasFunction(full_name)) {
            return full_name;
        }
    }

    if (sema_shadow.trace_resolution) sema_shadow.scan_unresolved += 1;
    return callee_name;
}

const testing = std.testing;

test "mangleTypeName: a non-generic name is unchanged" {
    const got = try mangleTypeName(testing.allocator, "Foo");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Foo", got);
}

test "mangleTypeName: List<string> -> List_string (the G3 spelling 4b inherits)" {
    const got = try mangleTypeName(testing.allocator, "List<string>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("List_string", got);
}

test "mangleTypeName: two args, and the space after the comma does not double up" {

    const got = try mangleTypeName(testing.allocator, "Map<string, int>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Map_string_int", got);
}

test "mangleTypeName: a nested arg keeps ONE separator per bracket run" {
    const got = try mangleTypeName(testing.allocator, "List<List<int>>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("List_List_int", got);
}

test "mangleTypeName: List<int> and List<string> DO NOT collide" {

    const a = try mangleTypeName(testing.allocator, "List<int>");
    defer testing.allocator.free(a);
    const b = try mangleTypeName(testing.allocator, "List<string>");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "the test module can SEE llvm — the wiring, not a lucky absence" {

    _ = core;
    _ = types;
    try testing.expect(true);
}
