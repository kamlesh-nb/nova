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
            // `|` appears in a value-optional element name (`int | undefined`): map it so the mangled
            // symbol stays linker-safe AND stays distinct from the bare inner type. Without a distinct
            // mangling, `List<int | undefined>` collides with `List<int>` at the monomorphised name.
            '|' => try buf.appendSlice(allocator, "_or"),
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

// True when `name` is a BOXED value-optional: `<value-type> | undefined` (e.g. `int | undefined`). A
// heap-optional (`string | undefined`) is a plain pointer optional (0 == none), NOT boxed, so it is excluded.
pub fn valueOptionalName(name: []const u8) bool {
    const bar = std.mem.indexOfScalar(u8, name, '|') orelse return false;
    const lhs = std.mem.trim(u8, name[0..bar], " ");
    const rhs = std.mem.trim(u8, name[bar + 1 ..], " ");
    if (std.mem.indexOfScalar(u8, rhs, '|') != null) return false; // more than two arms
    const value_arm = if (std.mem.eql(u8, rhs, "undefined")) lhs else if (std.mem.eql(u8, lhs, "undefined")) rhs else return false;
    return isPrimitiveTypeName(value_arm) and
        !std.mem.eql(u8, value_arm, "any") and
        !std.mem.eql(u8, value_arm, "void");
}

pub fn isPrimitiveTypeName(type_name: []const u8) bool {

    return cgPrim(type_name) != null or
        std.mem.eql(u8, type_name, "void") or
        std.mem.eql(u8, type_name, "f64x4") or   // SIMD vector: a value type, never ARC-owned
        simdVecName(type_name) != null or        // FR-simd-L1 integer vectors, also value types
        std.mem.eql(u8, type_name, "any");
}

// FR-simd-L1: the LLVM vector type for one of the integer-vector type names, or null. One place so the
// builtins, the slot picker, and the ownership check all agree.
pub fn simdVecName(type_name: []const u8) ?struct { elem: c_uint, lanes: c_uint } {
    if (std.mem.eql(u8, type_name, "u8x16")) return .{ .elem = 8, .lanes = 16 };
    if (std.mem.eql(u8, type_name, "u32x4")) return .{ .elem = 32, .lanes = 4 };
    if (std.mem.eql(u8, type_name, "u64x2")) return .{ .elem = 64, .lanes = 2 };
    return null;
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
        // Fixed arrays are `ptr` slots (not the i64 word) so pointer provenance survives -- lets LLVM
        // disambiguate arrays and vectorize/hoist array loops. Access GEPs the ptr directly.
        if (self.type_store) |st| {
            if (st.get(tid) == .array) return self.ptr_type;
        }
    }
    if (type_name) |tn| {
        if (std.mem.eql(u8, tn, "f64x4")) return core.LLVMVectorType(core.LLVMDoubleType(), 4);
        if (simdVecName(tn)) |v| return core.LLVMVectorType(core.LLVMIntType(v.elem), v.lanes);
        if (std.mem.indexOfScalar(u8, tn, '[') != null) return self.ptr_type; // T[N] array by name
        if (cgPrim(tn)) |p| {
            if (p.repr == .f64 or p.repr == .f32) return core.LLVMDoubleType();
        }
    }
    return self.val_type;
}

// The SIMD lane type: <4 x double>. One place so the builtins and the slot picker agree.
pub fn vecF64x4Type(self: *LlvmCompiler) types.LLVMTypeRef {
    _ = self;
    return core.LLVMVectorType(core.LLVMDoubleType(), 4);
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
    // ptr <-> i64 value-word: array slots are `ptr` (for provenance/vectorization); everything else
    // stays the i64 word, so the seams (array into a List/any/i64 param, or an i64 into a ptr slot)
    // convert here.
    if (sk == .LLVMPointerTypeKind and vk == .LLVMIntegerTypeKind) {
        return core.LLVMBuildIntToPtr(self.builder, val, slot_ty, "val_to_ptr");
    }
    if (sk == .LLVMIntegerTypeKind and vk == .LLVMPointerTypeKind) {
        return core.LLVMBuildPtrToInt(self.builder, val, slot_ty, "ptr_to_val");
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
        // A VALUE-optional (`int | undefined`) is a BOXED representation distinct from its inner value type;
        // rendering it as just the inner drops the optionality. That made an error-union ok arm
        // `int | undefined` collapse to `int` (`ErrUnion(int, E)`), so the producer stored a raw int while
        // the consumer (typed path) unboxed it -> SEGV (F1). Render value-optionals distinctly, matching
        // the typed path (`renderLegacy`); a heap-optional keeps the inner rendering (same pointer repr).
        .optional => |opt| {
            const inner = try self.typeRefToString(opt.*);
            if (opt.* == .ident and cgPrim(opt.*.ident) != null) {
                return try std.fmt.allocPrint(self.allocator, "{s} | undefined", .{inner});
            }
            return inner;
        },

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
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct0| {
            // A bare type-parameter carries no ownership of its own; resolve it through this
            // instantiation's substitution so ownership is decided by the CONCRETE type.
            const ct = if (st.get(ct0) == .type_param) (ir.tpResolve(ct0, inst) orelse ct0) else ct0;
            if (st.get(ct) != .unresolved and st.get(ct) != .type_param) return self.isOwnedTypeId(ct);
        }
    }
    var t_opt = ir.typeOf(expr_ptr);

    // If the static type is a type-parameter (e.g. returning a `U`-typed value from a generic fn), its
    // ownership must be that of the concrete type it was monomorphised with. Without this, a generic fn
    // returning an owned value emits no retain-on-return and the caller over-releases (a double-free).
    // This is Swift's rule: a function result is +1, so a returned borrowed/parameter value is copied.
    if (t_opt) |t| {
        if (st.get(t) == .type_param) {
            if (self.current_instantiation_id) |inst| {
                if (ir.tpResolve(t, inst)) |sub| t_opt = sub;
            }
        }
    }

    if (t_opt == null or st.get(t_opt.?) == .unresolved) {
        if (expr_ptr.kind == .ident) {
            if (self.current_local_types) |lt| {
                if (lt.get(expr_ptr.kind.ident)) |ts| return self.isOwnedLocal(expr_ptr.kind.ident, ts);
            }
        }
        return false;
    }
    // A FREE generic fn's spec binds its type parameters through `current_method_subst` (name -> concrete
    // strings), not `current_instantiation_id`, so the TypeId-based resolution above cannot resolve a bare
    // `T`. Fall back to the string substitution (`resolveExpressionTypeName` applies `method_subst`) and
    // decide ownership by the concrete name. Without this, `fn id<T>(v: T): T { return v; }` emits no
    // retain-on-return and the caller over-releases the returned arg -> double-free (B3-family).
    if (st.get(t_opt.?) == .type_param) {
        if (self.resolveExpressionTypeName(expr_ptr) catch null) |nm| {
            return self.ownedByName(getStructBaseName(nm));
        }
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

// M-1/M-10: a return expression is a CONFIRMED BORROW (its value lives outside this frame, so
// returning it is safe) iff it is a variable/field/index read, or a call whose callee is NOT a
// struct constructor (that callee returns its own safe value). Anything else -- a struct_init, a
// `Ctor(...)` call, a ternary, etc. -- may materialise a fresh stack alloca, so it is conservatively
// treated as a non-borrow (an escape). Failing safe here means an unclassified shape excludes.
// M-1 fail-safe: a field type that is a trivially-copyable scalar primitive (no heap, no ARC, no
// non-trivial copy). Only structs whose fields are ALL such scalars are value-lowered for now.
fn isScalarFieldTypeName(name: []const u8) bool {
    const scalars = [_][]const u8{ "int", "long", "short", "byte", "bool", "float", "double", "char", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "word", "usize", "isize" };
    for (scalars) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn calleeNamesStruct(self: *LlvmCompiler, callee: *const ast.Expression) bool {
    if (callee.kind == .ident) return self.structs.contains(getStructBaseName(callee.kind.ident));
    return false;
}
pub fn returnIsBorrow(self: *LlvmCompiler, expr: *const ast.Expression) bool {
    return switch (expr.kind) {
        // These never materialise a fresh value-struct stack alloca: reads, literals (incl.
        // `undefined`), arithmetic, casts, ranges, and calls to a non-constructor callee (that
        // callee returns its own safe value). A struct_init / `Ctor(...)` / selector (if_expr,
        // nullish, tuple, closure, ...) may, so it falls to the conservative `false` -> excluded.
        // A bare `.ident` is NOT safe: `return localStruct` returns a value struct held in THIS
        // frame's alloca by value, and we do not copy-return -> it dangles. Only reads that alias
        // longer-lived storage are true borrows: `self.field` (into the receiver), a container
        // `get`/index (into the container's heap buffer), literals, arithmetic, casts, ranges.
        .literal, .binary, .unary, .field_access, .index, .cast, .range => true,
        .call => |c| !calleeNamesStruct(self, c.callee),
        .generic_call => |gc| !calleeNamesStruct(self, gc.callee),
        else => false,
    };
}
fn stmtHasNonBorrowReturn(self: *LlvmCompiler, stmt: *const ast.Statement) bool {
    return switch (stmt.*) {
        .return_stmt => |rs| if (rs.value) |*v| !returnIsBorrow(self, v) else false,
        .block => |b| blockHasNonBorrowReturn(self, b.statements),
        .if_stmt => |i| stmtHasNonBorrowReturn(self, i.then_branch) or
            (if (i.else_branch) |e| stmtHasNonBorrowReturn(self, e) else false),
        .while_stmt => |w| stmtHasNonBorrowReturn(self, w.body),
        .for_stmt => |f| stmtHasNonBorrowReturn(self, f.body),
        .switch_stmt => |s| blk: {
            for (s.cases) |c| if (stmtHasNonBorrowReturn(self, c.body)) break :blk true;
            if (s.default_case) |d| break :blk stmtHasNonBorrowReturn(self, d);
            break :blk false;
        },
        else => false,
    };
}
fn blockHasNonBorrowReturn(self: *LlvmCompiler, stmts: []const ast.Statement) bool {
    for (stmts) |*st| if (stmtHasNonBorrowReturn(self, st)) return true;
    return false;
}

// M-1: the base name of the struct CONSTRUCTED by `expr` in a return position (a fresh alloca), or
// null if `expr` is not a struct construction. Recurses selector expressions (if/nullish) whose
// branches may each construct. `Ctor(...)` and `Struct{...}` construct; a bare read/call does not.
fn returnedConstructedStruct(self: *LlvmCompiler, expr: *const ast.Expression, set: *std.StringHashMap(void)) void {
    switch (expr.kind) {
        .struct_init => |si| excludeStructByName(self, set, si.type_name),
        .call => |c| if (c.callee.kind == .ident) excludeStructByName(self, set, c.callee.kind.ident),
        .generic_call => |gc| if (gc.callee.kind == .ident) excludeStructByName(self, set, gc.callee.kind.ident),
        .if_expr => |ie| {
            returnedConstructedStruct(self, ie.then_branch, set);
            returnedConstructedStruct(self, ie.else_branch, set);
        },
        else => {},
    }
}

fn excludeStructByName(self: *LlvmCompiler, set: *std.StringHashMap(void), name: []const u8) void {
    const base = getStructBaseName(name);
    if (base.len == 0 or !self.structs.contains(base) or set.contains(base)) return;
    const owned = self.allocator.dupe(u8, base) catch return;
    set.put(owned, {}) catch {};
}

// Walk a body; for every non-borrow return whose value CONSTRUCTS a value struct, exclude that
// struct. Mirrors stmtHasNonBorrowReturn's control-flow recursion (blocks, if/while/for/switch).
fn scanReturnConstructions(self: *LlvmCompiler, stmts: []const ast.Statement, set: *std.StringHashMap(void)) void {
    for (stmts) |*st| scanStmtReturnConstructions(self, st, set);
}
fn scanStmtReturnConstructions(self: *LlvmCompiler, stmt: *const ast.Statement, set: *std.StringHashMap(void)) void {
    switch (stmt.*) {
        .return_stmt => |rs| if (rs.value) |*v| {
            if (!returnIsBorrow(self, v)) returnedConstructedStruct(self, v, set);
        },
        .block => |b| scanReturnConstructions(self, b.statements, set),
        .if_stmt => |i| {
            scanStmtReturnConstructions(self, i.then_branch, set);
            if (i.else_branch) |e| scanStmtReturnConstructions(self, e, set);
        },
        .while_stmt => |w| scanStmtReturnConstructions(self, w.body, set),
        .for_stmt => |f| scanStmtReturnConstructions(self, f.body, set),
        .switch_stmt => |s| {
            for (s.cases) |c| scanStmtReturnConstructions(self, c.body, set);
            if (s.default_case) |d| scanStmtReturnConstructions(self, d, set);
        },
        else => {},
    }
}

// M-1: whole-program escape set. A value struct escapes (and must stay heap) when it is
// CONSTRUCTED-and-returned (a fresh stack alloca that outlives the frame), stored as a direct
// struct field, or used as a direct type-param field. A value struct returned only by borrow
// (a container get, a field/var read) does NOT escape and can be value-lowered inline. Computed
// once, lazily, only when the value-struct gate is on.
fn computeValueEscapeSet(self: *LlvmCompiler) void {
    var set = std.StringHashMap(void).init(self.allocator);
    const addName = struct {
        fn f(s: *LlvmCompiler, st: *std.StringHashMap(void), name: []const u8) void {
            const base = getStructBaseName(name);
            if (base.len == 0 or !s.structs.contains(base) or st.contains(base)) return;
            const owned = s.allocator.dupe(u8, base) catch return;
            st.put(owned, {}) catch {};
        }
    }.f;
    // 1. a value struct CONSTRUCTED in a return position escapes (a fresh stack alloca that outlives
    //    the frame); one returned only by borrow (e.g. List.at -> self.data.get(i)) does NOT. We scan
    //    the BODY and exclude the struct actually constructed in the return -- NOT the function's
    //    declared return type: a lifted CLOSURE carries a useless "i32" return_type (only trait
    //    returns are recorded), so keying on the declared type misses `() => Point(3,4)`. Every
    //    lifted closure is appended to self.functions, so this scan covers them.
    for (self.functions.items) |f| {
        // (a) exclude the struct CONSTRUCTED in a return -- covers lifted closures, whose declared
        //     return_type is a useless "i32".
        scanReturnConstructions(self, f.body.statements, &set);
        // (b) a non-borrow return of a bare local (`return r` where r: R) has no construction node
        //     to key on, so exclude the function's DECLARED return type. Skipped for classes.
        const rbase = getStructBaseName(f.return_type);
        if (self.structs.get(rbase)) |rsd| {
            if (!rsd.is_reference and blockHasNonBorrowReturn(self, f.body.statements))
                addName(self, &set, f.return_type);
        }
    }
    // 2. every struct field type (a value struct stored as a field escapes with its container);
    //    also: a struct that IMPLEMENTS A TRAIT can be widened to that trait's fat pointer, which
    //    stores a pointer to the struct -> it must live on the heap, so exclude it from value-lowering.
    var it = self.structs.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.impls.len > 0) addName(self, &set, e.key_ptr.*);
        // A @serializable struct is constructed and returned by a generated `<T>__bind` binder, and
        // through a type-parameter-erased generic (`serde.bind<T>` returning `T`) whose declared
        // return type is the bare param `T`, not the concrete struct -- so the return-construction
        // channel (1) cannot see it. Exclude it directly: serde-bound structs stay on the heap until
        // the binder/generic-return path is inline-aware.
        for (e.value_ptr.attributes) |a| if (a == .serializable) {
            addName(self, &set, e.key_ptr.*);
            break;
        };
        for (e.value_ptr.fields) |fld| {
            const fs = self.typeRefToString(fld.type_name) catch continue;
            addName(self, &set, fs);
            // A field must be a scalar primitive OR a `string` (an owned reference the copy/drop paths
            // now handle: retain-on-copy, release-on-drop). Any other field -- decimal, function,
            // nested struct, container/optional -- is not yet handled inline, so it forces the whole
            // struct to the heap. (Those are the next slices: nested-value-struct + container fields.)
            if (!isScalarFieldTypeName(fs) and !std.mem.eql(u8, fs, "string")) addName(self, &set, e.key_ptr.*);
        }
    }
    // 3. Generic struct args that land in a DIRECT type-param field escape (that field is a raw
    //    8-byte slot holding a pointer to a stack alloca -> dangling). But a type param used only
    //    inside a container (e.g. `data: Storage<T>`) is inline-safe (M-10), so it does NOT escape.
    //    Storage<X> elements themselves are inline (M-10) and are NOT excluded. renderLegacy returns
    //    a BORROWED string — do not free it.
    if (self.type_store) |store| {
        const n = store.count();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id: typesys.TypeId = @enumFromInt(i);
            switch (store.get(id)) {
                .struct_ => |s| {
                    if (s.args.len == 0) continue;
                    const inst = sema_shadow.renderLegacy(self.allocator, store, id) catch continue;
                    const decl = self.structs.get(getStructBaseName(inst)) orelse continue;
                    for (decl.fields) |fld| {
                        // A field typed DIRECTLY as a bare type param (`p: T`) makes that param escape.
                        const tp_name: ?[]const u8 = switch (fld.type_name) {
                            .ident => |nm| nm,
                            else => null,
                        };
                        if (tp_name) |tpn| {
                            for (decl.type_params, 0..) |p, pi| {
                                if (std.mem.eql(u8, p, tpn) and pi < s.args.len) {
                                    const an = sema_shadow.renderLegacy(self.allocator, store, s.args[pi]) catch continue;
                                    addName(self, &set, an);
                                }
                            }
                        }
                    }
                },
                // A value struct that lands in a tuple element, an error-union payload, or an
                // optional inner is stored as a raw 8-byte slot holding a pointer to a stack alloca
                // -> it would dangle. These aggregate/coercion slots are not yet inline-aware, so any
                // value struct reaching one is excluded (kept on the heap). Over-exclusion is safe;
                // under-exclusion is a UAF, so this scans the whole interned type store (complete).
                .tuple => |items| for (items) |elt| excludeIfStruct(self, store, &set, elt),
                .error_union => |eu| {
                    excludeIfStruct(self, store, &set, eu.ok);
                    excludeIfStruct(self, store, &set, eu.err);
                },
                .optional => |inner| excludeIfStruct(self, store, &set, inner),
                else => {},
            }
        }
    }
    self.value_escape_set = set;
}

// M-1: if `id` renders to a known struct base name, exclude it from value-lowering (keep it on the
// heap). Used for aggregate/coercion slots (tuple/error-union/optional) that hold a pointer, not an
// inline value. renderLegacy returns a BORROWED string — do not free it.
fn excludeIfStruct(self: *LlvmCompiler, store: *const typesys.TypeStore, set: *std.StringHashMap(void), id: typesys.TypeId) void {
    const rendered = sema_shadow.renderLegacy(self.allocator, store, id) catch return;
    const base = getStructBaseName(rendered);
    if (base.len == 0 or !self.structs.contains(base) or set.contains(base)) return;
    const owned = self.allocator.dupe(u8, base) catch return;
    set.put(owned, {}) catch {};
}

// M-1: a value-lowered struct by base name (rollout-gated). When disabled (default) this is
// always false, so codegen is unchanged. Escaping structs are excluded (safety, see above).
pub fn isValueStructName(self: *LlvmCompiler, name: []const u8) bool {
    if (!arc_mod.value_structs_enabled) return false;
    const base = getStructBaseName(name);
    const sd = self.structs.get(base) orelse return false;
    // A COLLIDING struct (same bare name in two modules) reaches here under a fully MANGLED scoped
    // key (`conformance_cases_scoped_rec_a_Rec`), which the escape channels -- keyed on the SOURCE
    // name `Rec` -- never match, so its returned-by-value alloca would dangle undetected (case 282).
    // The decl still carries the original bare name; use it. Colliding structs are rare; keep them
    // all on the heap rather than thread the scoped/mangled/base name duality through value lowering.
    if (self.isCollidingStruct(sd.name)) return false;
    if (sd.is_reference) return false; // `class` stays a reference type
    if (self.value_escape_set == null) computeValueEscapeSet(self);
    if (self.value_escape_set.?.contains(base)) return false; // escapes -> keep on heap
    if (arc_mod.value_structs_all) return true;
    if (arc_mod.value_type_set) |set| return set.contains(base);
    return false;
}

// M-1: does a value struct have any OWNED (reference) field that needs retain-on-copy /
// release-on-drop? A scalar-only value struct has none, so it needs no drop at all.
pub fn valueStructHasOwnedFields(self: *LlvmCompiler, name: []const u8) bool {
    const base = getStructBaseName(name);
    const sd = self.structs.get(base) orelse return false;
    for (sd.fields) |fld| {
        const fts = self.typeRefToString(fld.type_name) catch continue;
        if (self.isOwnedDeclaredType(fld.type_name, fts)) return true;
    }
    return false;
}

// M-1: same decision from a struct TypeId (for ownership). Only pays the name render when the
// rollout gate is on; off by default => zero overhead on the hot ownership path.
pub fn isValueStructTid(self: *LlvmCompiler, t: typesys.TypeId) bool {
    if (!arc_mod.value_structs_enabled) return false;
    const st = self.type_store orelse return false;
    if (st.get(t) != .struct_) return false;
    // renderLegacy may return a BORROWED (interned) or static string — never free it, matching
    // every other codegen caller. Freeing it corrupts sema's name cache (method resolution reads it).
    const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return false;
    return self.isValueStructName(nm);
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

        // M-1: a value-lowered struct is NOT owned — inline storage, no ARC (no retain/release/free).
        // Its owned FIELDS are still dropped by the struct's generated destructor when it is a
        // reference; a value struct with owned fields is out of scope for the initial rollout
        // (all-primitive value structs only), so this simple gate suffices for now.
        .struct_ => if (self.isValueStructTid(t)) false else st.isOwned(t),

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
    const st_opt = self.type_store;
    // A type_param or unresolved id is NOT a usable decision id: in an instantiated body the typed IR may
    // hand back the raw type-param `T` (the string engine substitutes it to the concrete arg via
    // substTypeParams; the TypeId path must reach the same concrete id). Reject those and fall through to
    // the local-slot fallback, which holds the concrete id (populated with the substituted type).
    const concrete = struct {
        fn ok(st: ?*const typesys.TypeStore, t: typesys.TypeId) bool {
            const s = st orelse return true;
            return switch (s.get(t)) {
                .unresolved, .type_param => false,
                else => true,
            };
        }
    }.ok;
    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct| {
            if (concrete(st_opt, ct)) return ct;
        }
    }
    if (ir.typeOf(expr_ptr)) |t| {
        if (concrete(st_opt, t)) return t;
    }
    // Phase 1 (string->TypeId cutover): fall back to the local TypeId slot for an ident, mirroring the
    // string engine's `resolveExpressionTypeName -> current_local_types.get(ident)` fallback but keeping a
    // real TypeId. current_local_type_ids is populated for params (C10) and for `let`/`const` locals
    // (collectLocalVarTypes), so an ident whose typed-IR node is missing/unresolved still resolves here.
    if (expr_ptr.kind == .ident) {
        if (self.current_local_type_ids) |ids| {
            if (ids.get(expr_ptr.kind.ident)) |tid| {
                if (self.type_store) |st| {
                    if (st.get(tid) != .unresolved) return tid;
                } else {
                    return tid;
                }
            }
        }
    }
    return null;
}

pub fn isStringExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .string;
        }
    }
    return false;
}

// TypeId-based expression-type predicates — the string->TypeId replacements for
// `resolveExpressionTypeName(e) == "float"/"bool"/"void"/"any"/"decimal"`. Each returns false when no
// concrete TypeId is available (matching the old `if (name) |n| ... else false` shape), so a caller that
// used the string compare as a redundant fallback behind one of these can drop the string compare.
pub fn isFloatExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .float;
        }
    }
    return false;
}

pub fn isBoolExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .bool;
        }
    }
    return false;
}

pub fn isVoidExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .void_;
        }
    }
    return false;
}

pub fn isAnyExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .any_;
        }
    }
    return false;
}

pub fn isDecimalExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .decimal;
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
    // `any` is an OWNED heap carrier (nova_any_box), but isPrimitiveTypeName lumps it with the value
    // primitives (convenient for the value-optional value-arm check). Decide it as owned BEFORE the
    // primitive short-circuit, otherwise this LIVE string fallback under-claims ownership on an `any` value
    // and leaks its box. Matches isOwnedTypeId (the TypeId engine) and the legacyStringOwnership baseline.
    if (std.mem.eql(u8, name, "any")) return true;
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

// The module-scoped name of a colliding struct/enum/trait bound to `bare`, resolved from the module in
// which `bare` appears (its file). Enum/trait references have no value-TypeId to read from, so scope by
// the source file of the reference. Returns null (use the bare name) when `bare` is not colliding.
pub fn scopedTypeName(self: *LlvmCompiler, bare: []const u8, file: []const u8) []const u8 {
    _ = self;
    if (sema_shadow.live_sema) |sm| {
        if (sm.tab.scopedNameFor(bare, file)) |scoped| return scoped;
    }
    return bare;
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

    if (sema_shadow.tid_census and typeOfExprConcrete(self, expr_ptr) == null) {
        sema_shadow.census_total += 1;
        switch (expr_ptr.kind) {
            .ident => sema_shadow.census_kind_ident += 1,
            .index => sema_shadow.census_kind_index += 1,
            .call => sema_shadow.census_kind_call += 1,
            .generic_call => sema_shadow.census_kind_method += 1,
            .field_access => sema_shadow.census_kind_field += 1,
            else => sema_shadow.census_kind_other += 1,
        }
    }

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
