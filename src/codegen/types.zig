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

/// An instantiation's name, spelled as a SYMBOL: `List<string>` -> `List_string`;
/// `Map<string, int>` -> `Map_string_int`. A symbol cannot contain `<`, `>`, `,`
/// or a space.
///
/// F4 G3 wrote this inline inside `destructorName` (arc.zig); 4b needs the same
/// spelling for METHOD symbols (`List_string_push`), and two manglers would
/// eventually disagree about one type — a link error at best, and at worst a call
/// into the wrong instantiation's body. So there is one, and both callers use it.
/// Renderer unification: fold a primitive's SOURCE-spelling alias to codegen's canonical spelling (the
/// one `renderLegacy` uses — `int`→`i32`, `long`→`i64`, `float`→`f32`, `double`→`f64`, and the unsigned +
/// sub-word aliases). This is THE fix for the two-renderer split: a symbol built from `typeRefToString`
/// (`List<int>`) and one built from `renderLegacy` (`List<i32>`) now mangle to the SAME `List_i32` — so a
/// call site's symbol matches the mono body's definition symbol (they were silently missing and falling to
/// the erased body). The canonical (`i32`/`u32`/…) forms map to themselves; a non-primitive token
/// (`Map`, `string`, a user struct) is returned null → unchanged. Applied per TOKEN, never per substring,
/// so `MyInt` / `Point` are untouched.
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
            // Collect a maximal identifier TOKEN and canonicalize a primitive alias (int→i32, …) so
            // both renderers produce the same symbol. Non-alias tokens append unchanged.
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
            // §3.4j: FUNCTION-typed args (`List<(int) => int>`) must mangle INJECTIVELY,
            // or `List<(int) -> int>`, `List<(int) => int>` and `List<int, int>` collide
            // onto one symbol — a call into the wrong body. Distinct tokens, never folded
            // to `_`. These do not touch `<>,space`, so `List<string>` -> `List_string`
            // is unchanged and every hand-built `List_<method>` name still matches.
            '(' => try buf.appendSlice(allocator, "_lp"),
            ')' => try buf.appendSlice(allocator, "_rp"),
            '-' => try buf.appendSlice(allocator, "_da"),
            '=' => try buf.appendSlice(allocator, "_eq"),
            else => try buf.append(allocator, c),
        }
        i += 1;
    }
    // A trailing `_` from the closing `>`.
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

/// Inside `List_string_push`, sema types `self` as a BARE `List` — the struct with
/// no args at all, not `List<T>`. Measured directly: `in=List<string>` while
/// `obj_type=List`. So there is no `T` token for `substTypeParams` to replace, and
/// `self.grow()` resolved to the erased `List_grow` while `List_string_grow` sat
/// emitted and uncalled — every monomorphized body silently re-entering the erasure
/// one call deep.
///
/// A bare `List` inside an instantiation of `List` can only BE that instantiation:
/// that is what "this body belongs to exactly one instantiation" means. A type that
/// already carries args (`List<i32>` referenced from inside `List<string>`) is
/// returned untouched — it names a different instantiation and is already exact.
pub fn qualifySelfType(self: *LlvmCompiler, type_name: []const u8) []const u8 {
    const inst = self.current_instantiation orelse return type_name;
    if (std.mem.indexOfScalar(u8, type_name, '<') != null) return type_name;
    if (!std.mem.eql(u8, type_name, getStructBaseName(inst))) return type_name;
    return inst;
}

/// The symbol for a method, on either a plain struct or an instantiation:
/// `("List", "push")` -> `List_push`; `("List<string>", "push")` -> `List_string_push`.
///
/// One speller for the 36 sites that built `<Struct>_<method>` by hand (F4 §5, 4b).
pub fn methodSymbol(self: *LlvmCompiler, owner: []const u8, method: []const u8) ![]const u8 {
    const mangled = try mangleTypeName(self.allocator, owner);
    defer self.allocator.free(mangled);
    return std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled, method });
}

/// Which bodies to emit for `s`'s methods — F4 4b's N-copy expansion.
///
/// `null` means the ERASED body (`List_push`), which is what exists today. It is
/// always FIRST and always present, deliberately: until every call site is moved to
/// the monomorphized symbols (stage 4b's second half), an unflipped call — or a
/// generic body calling another generic — must still find a body to link against.
/// Emitting only the instantiations would turn any site this misses into a LINK
/// ERROR; keeping the erased body makes the same miss merely a missed optimisation,
/// and the corpus stays green while the call sites move over one at a time.
///
/// A non-generic struct, or mono switched off, yields exactly `{null}` — today's
/// behaviour, byte for byte.
pub fn instantiationsOf(self: *LlvmCompiler, s: ast.StructDecl) ![]const ?[]const u8 {
    var out = std.ArrayListUnmanaged(?[]const u8).empty;
    errdefer out.deinit(self.allocator);
    try out.append(self.allocator, null); // the erased body, always

    if (s.type_params.len == 0) return out.toOwnedSlice(self.allocator);
    // No `mono_enabled` check: monomorphization is not optional (sema/mono.zig).
    // `live_instantiations` is null only when sema did not run at all.
    const insts = sema_mono.live_instantiations orelse return out.toOwnedSlice(self.allocator);

    for (insts) |inst| {
        // §3.4j: FUNCTION-typed instantiations ARE monomorphized now. `mangleTypeName`
        // is injective for `(`/`)`/`->`/`=>`, so `List<(int) => int>` gets its own body
        // — and it MUST, because a closure element is refcounted, so an ERASED container
        // whose destructor releases (generated on demand) but whose `push` never
        // retained double-frees the closures (measured on test_loop_capture_independent).
        // Keeping it erased is not an option: the destructor/push mismatch is a crash,
        // not a leak.
        // HISTORICAL (M1 DONE): `Map` USED to be excluded here because it stored keys
        // through raw `bytes.write_ptr` (no ARC) → a monomorphized `Map_*_set` UAF'd.
        // `map.nova` is now on `Storage<K>`/`Storage<V>` (typed slots, ARC-managed) and
        // `retainIfGenericStore` is retired, so Map monomorphizes like List — no
        // exclusion. 12_traits_dispatch + 13_serde (the two the exclusion protected) are
        // ASAN-clean with Map mono. See docs/design/F4-monomorphization-completion.md.
        // `List<string>` belongs to `List`. Compare the BASE, not a prefix: a prefix
        // test would match `ListNode<int>` to `List`.
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

/// A7 / F3 §5 stage 1: the CODEGEN primitive table — the single source of truth for
/// how a primitive NAME maps to an LLVM representation, size, and signedness.
///
/// It reproduces TODAY's codegen mapping exactly (F3 stage 1 is behaviour-preserving),
/// including the lie that `int`/`i32` are word-sized (`.word` = `val_type` = i64 native
/// / i32 wasm). That lie is F3 stage 5's to remove; sema already carries the honest
/// widths (`sema/lower.zig` — `int` = 32), and this codegen table catches up at stage 5.
///
/// Two things ARE removed here (F3 §3.2a): `i128`/`u128` (zero uses, no consumer) — they
/// fall out of the table and become non-primitive — and `decimal`, which is a hard
/// compile error (raised in the type checker), never a silent `i128`.
// A7 / F3 §5 stage 5: `.i32` is `int`/`uint`'s HONEST 32-bit representation, split off
// from `.word` (which now belongs to `ptr` alone — the 64-bit machine word). For now
// `.i32` still LOWERS to `val_type` (llvmForRepr) so the i64 pipeline and struct layout
// are unchanged — the split's first use is knowing an `int`'s honest WIDTH (32) is
// distinct from a `ptr`'s (64), which is what lets integer arithmetic wrap at 32 bits.
// A later increment repoints `.i32` at a real `i32` slot (honest slots, §7).
pub const CgRepr = enum { i1, i8, i16, i32, word, i64, f32, f64 };

/// The honest bit-width of a `CgRepr` — what the value MEANS, independent of the slot
/// it currently lives in. `.word` is the 64-bit machine word (`ptr`). This is the width
/// integer arithmetic canonicalises (wraps) to.
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
        // A7 / F3 §5 stage 2: `ptr` is an OPAQUE machine-word value (F3 §3.2) — an
        // address from `bytes`/FFI, never dereferenced by Nova. Word-sized (`.word`,
        // like `int` today) and UNSIGNED. Making it a recognised primitive is the safety
        // move: without it `isRefCountedType("ptr")` is TRUE, so a `ptr` local would be
        // retained/released as a heap object and `nova_release` would decrement
        // `[addr-8]` of a raw pointer — heap corruption. Being primitive makes it a value
        // type. This lands BEFORE stage 5 (int→32) precisely so the stdlib's address
        // fields have a 64-bit-safe home before `int` can no longer hold one (F3 §5).
        .{ .n = "ptr", .r = .word, .s = false },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e.n)) return .{ .repr = e.r, .signed = e.s };
    }
    return null;
}

pub fn isPrimitiveTypeName(type_name: []const u8) bool {
    // `void`/`any` are recognised primitive NAMES but carry no CgRepr (they are not
    // value-representable), so the table above omits them — kept here to preserve
    // today's `isPrimitiveTypeName` set exactly.
    return cgPrim(type_name) != null or
        std.mem.eql(u8, type_name, "void") or
        std.mem.eql(u8, type_name, "any");
}

/// The LLVM type for a `CgRepr`. `.word` = the machine word (`val_type` = i64 native /
/// i32 wasm) — today's representation for `int`/`i32` (F3 stage 1 preserves it).
pub fn llvmForRepr(self: *LlvmCompiler, repr: CgRepr) types.LLVMTypeRef {
    return switch (repr) {
        .i1 => self.i1_type,
        .i8 => self.i8_type,
        .i16 => core.LLVMInt16Type(),
        // A7 / F3 §5 stage 5 (honest slots): `int` is a REAL `i32` — 32-bit on every
        // target (was `val_type` = i64 native / i32 wasm, the divergence §7 removes).
        // Struct/element machinery reads/writes it at this width and sext/truncs at the
        // i64 value boundary via castToValType/castFromValType, exactly like byte/short.
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

/// A7 / F3 §5 stage 4: the honest LLVM stack-slot type for a local of Nova type
/// `type_name`. Floats get a real `double` slot, so a float local's arithmetic loads
/// and stores stay in float storage — deleting the load/bitcast/op/bitcast/store
/// "sandwich". Everything else stays `val_type` (i64) until stage 5 narrows integers;
/// refcounted/struct/unknown are word-sized handles and stay `val_type` too.
pub fn slotTypeForLocal(self: *LlvmCompiler, type_name: ?[]const u8) types.LLVMTypeRef {
    if (type_name) |tn| {
        if (cgPrim(tn)) |p| {
            if (p.repr == .f64 or p.repr == .f32) return core.LLVMDoubleType();
        }
    }
    return self.val_type;
}

/// Coerce `val` so it can be stored into (or was just loaded from) a slot of
/// `slot_ty`. Idempotent: a value already of `slot_ty` passes through untouched.
/// Bridges the i64 ABI and real `double` float storage at the slot boundary.
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
                // A7 / F3 §5 stage 1: signedness from the canonical `cgPrim` table.
                // (This also gives `byte` its honest UNSIGNED widening — the old list
                // omitted it, so a negative-looking `byte` sext'd; corpus-invisible.)
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
            // A7 / F3 §5 stage 4: a real `double` value crossing back to the i64 ABI
            // edge (a call argument, a collection/struct slot, a return). Reinterpret
            // the bits — the value IS a 64-bit double, the slot is a 64-bit word.
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
        // F4 4b render boundary #1: DECLARED types. `value: T` in `List<T>.push`
        // arrives here as `.ident{"T"}` and left as `"T"`, which is what put `"T"`
        // into `local_types` and made `isRefCountedType` false inside the body.
        // A no-op outside a monomorphized body.
        .ident => |name| return try self.substTypeParams(name),
        .optional => |opt| return try self.typeRefToString(opt.*),
        // specs §3.4b. Rendered DISTINCTLY (`ErrUnion(ok,err)`), never as the ok type: the
        // representation is a tagged box, so rendering it as `T` would tell ARC it owns a `T`
        // when it owns a box — the exact "decide semantics from a spelling, guess when unsure"
        // failure that causes this codebase's corruptions. `isRefCountedType` sees an unknown
        // name and returns true, which is correct here: it IS a heap box.
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

/// F2 stage 3: takes a POINTER so the expression's identity is available — that is
/// what lets the TypedIr be consulted here (and, at stage 4, replace this
/// function entirely). A by-value parameter would make `&expr` a stack address,
/// which is silently useless as a key.
/// The type of an expression, ASKED of sema rather than re-derived here.
///
/// F2 stage 4d: the legacy resolver is gone. It was 315 lines that recomputed a
/// type at every use site and answered the STRING "i32" on failure — and because
/// i32 is the universal machine word, a wrong answer was indistinguishable from a
/// right one. That is the disease F2 was built to cure; this is the cure landing.
///
/// Deleting it was not a judgement call. Measured on the whole corpus: every
/// resolution legacy answered, sema answers (0 lossy fallbacks of 53,507), and
/// with legacy disabled entirely the emitted IR is BYTE-IDENTICAL on all 17 cases.
///
/// `null` means "no type", not "int". `.unresolved` is likewise never returned as a
/// name — it is sema saying it does not know, and forwarding it would be the same
/// lie in new clothes.
/// True when this expression's type is `T | undefined` (an optional).
///
/// Asked of the TYPE STORE, not the rendered name — the renderers see THROUGH an optional
/// (`typeRefToString`/`renderLegacy` both return the inner `T`), which is what makes
/// `xs.get(i).field` resolve the member type at all (specs §3.4b's see-through, commit 950495c).
/// That same see-through is why a member access on an ABSENT optional is a null deref rather than
/// a type error: the handle for `undefined` is 0 (specs §3.2), so `.field` reads through address 0
/// and SEGVs. Codegen uses this to insert a runtime guard that traps with a location instead
/// (specs §3.4, P2-14 decision: checked at runtime today). One TypeId lookup, no string compare.
pub fn isOptionalExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;
    const t = ir.typeOf(expr_ptr) orelse return false;
    return st.get(t) == .optional;
}

/// Does this expression's VALUE have an owned (ref-counted) type? (F5 stage 2, incremental.)
///
/// The typed answer, asked of the store directly for CONCRETE types — bypassing the renderer, so
/// a rendering bug can no longer change a concrete ARC decision. That class (a tuple rendered
/// `(unresolved,unresolved)`, an untyped `E.A`) caused this session's corruptions; a concrete-type
/// retain/release no longer depends on `renderLegacy` being right.
///
/// Falls back to the string path (`renderLegacy` + `substTypeParams` + `isRefCountedType`) ONLY for
/// a generic-body `.type_param` or an `.unresolved` — the two the renderer SUBSTITUTES and
/// `isOwned` marks `unreachable` (it cannot decide an unsubstituted generic; that needs F4-5).
/// Behavior-preserving: measured that `isOwned` and `isRefCountedType(render)` agree on every
/// concrete type in the corpus. As F4-5/F2-5 land, the fallback's reach shrinks to zero.
///
/// Returns false when the expression has no recorded type — matching the old
/// `resolveExpressionTypeName(...) orelse <skip>`: no type means no ownership action.
pub fn isOwnedExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;
    // F4 keystoneSubst removal: inside a MONOMORPHIZED body, read the checker's per-instantiation
    // CONCRETE type (inst_disp.zig) and decide from it directly — no substitution in codegen. This is
    // byte-identical to `isOwnedTypeId(type_param)`→keystoneSubst (both resolve to the same concrete
    // TypeId then ask `isOwned`), but the resolution now lives in the IR, not codegen.
    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct| {
            if (st.get(ct) != .unresolved and st.get(ct) != .type_param) return self.isOwnedTypeId(ct);
        }
    }
    const t_opt = ir.typeOf(expr_ptr);
    // No type, or an `.unresolved` one, means the store cannot decide — but a bare IDENT may still be
    // a known local (e.g. a switch-bound payload var `case E.Pair{ name: nm }`, which sema types
    // `.unresolved` but `current_local_types` recorded as `string`). Fall back to the name so a
    // `return nm` retains it, balancing the box destructor's release. Matches the old skip otherwise.
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

/// string→TypeId shadow-diff (report-only). Classifies this ownership decision: BLOCKED (the TypeId
/// engine cannot decide — `.type_param`/`.unresolved`/`.enum_`) or CONCRETE, and for concrete types
/// compares `store.isOwned(t)` against the legacy `isRefCountedType(renderLegacy(t))`. A concrete
/// DISAGREE is a real bug; the blocked counts are exactly what the keystone/F2-5/enum-awareness clear.
fn tdShadowDiff(self: *LlvmCompiler, t: typesys.TypeId) void {
    const st = self.type_store.?;
    switch (st.get(t)) {
        .type_param => {
            // KEYSTONE SHADOW: would substituting this `.type_param` against the current instantiation
            // (in the STORE, via subst.substitute) resolve it to a concrete type — and does that
            // concrete type's ownership AGREE with today's string answer (isOwnedRenderedFallback,
            // which substTypeParams on the rendered name)? If yes, the keystone converts this site
            // correctly; if it substitutes concrete but disagrees, that's a keystone bug.
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
            const str = self.isRefCountedType(rendered);
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

/// Total `isOwned`: concrete via the store's `isOwned`, generic/unresolved via the string path.
/// Intercepts `.optional` so `isOwned`'s own recursion cannot hit a `.type_param` inner and panic.
pub fn isOwnedTypeId(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    if (sema_shadow.report_enabled) tdShadowDiff(self, t);
    return switch (st.get(t)) {
        // `.unresolved` reaching an ownership DECISION is a compiler bug, not user code: every caller
        // that can see an untyped value (isOwnedExpr, isOwnedLocal, the vehicles) checks for
        // `.unresolved` FIRST and falls back, so this branch is UNREACHABLE in practice — measured
        // zero hits across the whole corpus. Making it a loud, located tripwire (rather than a silent
        // `false`) is the F2-5 enforcement half codegen CAN do now: it converts a future
        // "typed a decision off an untyped value" from a silent guess into a located compiler failure,
        // the same silent->visible transformation applied to isUntypeablePlaceholder and the
        // optional-deref guard. The end-of-sema `.unresolved`-fatal (the inert receiver-ident clusters)
        // stays gated on F1-3b; this is the decision-site tripwire, and it is behavior-preserving today.
        .unresolved => {
            std.debug.print(
                "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ownership decision asked of an UNTYPED value\x1b[0m\n" ++
                "  isOwnedTypeId reached an `.unresolved` TypeId. A caller took an ownership action on a\n" ++
                "  value sema never typed — a COMPILER bug (F2-5), not user code. Every ownership vehicle\n" ++
                "  must check `.unresolved` and fall back before deciding. Please report.\n",
                .{},
            );
            std.process.exit(70); // EX_SOFTWARE — an internal fault, same as isRefCountedType's placeholder abort
        },
        // KEYSTONE CUTOVER: substitute the `.type_param` against the current instantiation IN THE
        // STORE and decide from `store.isOwned` — no string rendering. Proven byte-identical to the
        // old `substTypeParams` path (shadow-diff disagree=0).
        //
        // F4-5 PRINCIPLED ERASURE RULE: when the keystone cannot resolve the `.type_param` — no
        // instantiation context (a bare erased body) or a METHOD-level param (`U` in `map<U>`, absent
        // from the struct instantiation) — it is UNBOUND in this body, and an unbound type parameter
        // has one honest meaning: an opaque, non-owned machine word. The erased/partial body is
        // type-agnostic by construction, so it must perform NO ARC on a `T`-typed value; whoever holds
        // the CONCRETE type (the monomorphized instantiation, or the caller — e.g. `xs.map(f)` typed
        // `List<string>` at the call site) owns and frees it. This is the exact "caller compensates"
        // contract the sema map<U> fix relies on (f35d8b4). This REPLACES the old string fallback
        // (`isOwnedRenderedFallback` → renderLegacy → substTypeParams → isRefCountedType): that path
        // ALSO returned false here, because an unbound param renders to a single-uppercase name
        // (`"U"`) which `isRefCountedType` (arc.zig:25) already reads as non-owned — so this is
        // behavior-preserving AND removes the last string-matched `.type_param` ownership decision.
        // A `List<U>` (the CONTAINER) is `.struct_`, not a bare `.type_param`, so it never reaches
        // here — it is owned via `store.isOwned` in the `else` arm, correctly.
        // F4: a bare `.type_param` is resolved by READING the checker's precomputed per-instantiation
        // resolution (`tp_resolve`) — codegen no longer substitutes. null (no instantiation context, or a
        // method-level param not resolved by this struct instantiation) is the erasure rule -> non-owned,
        // exactly what keystoneSubst's null-return gave.
        .type_param => blk: {
            if (self.current_instantiation_id) |inst| {
                if (self.typed_ir) |ir| {
                    if (ir.tpResolve(t, inst)) |concrete| break :blk st.isOwned(concrete);
                }
            }
            break :blk false;
        },
        // `.enum_` is now decided by `store.isOwned` — variant-aware via the `enum_tagged` table (a
        // payload-carrying enum is an owned heap box; a payload-less one is an immediate tag). This
        // REPLACES the `enumIsOwnedBySymbol orelse isOwnedRenderedFallback` route (symbol-table lookup
        // then the string engine): proven byte-identical on every enum ownership decision in the corpus
        // (the `[enum-mismatch]` shadow probe reported 0), the same license the keystone cutover used.
        // `.trait_` similarly moved to `else` once `isOwned(.trait_)` became correct (§3.4f).
        .enum_ => st.isOwned(t),
        .optional => |inner| self.isOwnedTypeId(inner),
        // Everything else agrees with the string path (measured): string / struct / array / tuple /
        // storage / error_union / func -> owned; prim / ptr / future -> not.
        else => st.isOwned(t),
    };
}

/// F5-2 name→TypeId migration: the ownership decision for a NAMED local.
///
/// The ownership read sites (statements.zig let-registration, arc.zig function-exit drain, the
/// closure-cleanup sites) know only the variable NAME and its string type from `current_local_types`.
/// This prefers the parallel `current_local_type_ids` map — a typed `isOwned`, asked of the store —
/// when the name is in it (populated where an initializer expression is in hand, so `typeOf` yields
/// the TypeId directly), and falls back to the string `isRefCountedType` otherwise (params, annotated
/// lets, and the populate sites not yet migrated). The map is PARTIAL and ADDITIVE: a name absent
/// from it decides exactly as before, so this is behavior-preserving while moving the expr-based
/// locals — the tuple/enum cases that corrupted this session — off the rendered name and onto the store.
pub fn isOwnedLocal(self: *LlvmCompiler, name: []const u8, type_string: []const u8) bool {
    if (self.current_local_type_ids) |ids| {
        if (ids.get(name)) |tid| {
            // Prefer the string ONLY when the stored TypeId carries no ownership info (`.unresolved`) —
            // sema sometimes types a value (non-null TypeId) yet leaves it `.unresolved`, while the
            // string path resolved a real name (e.g. an enum-variant struct-init `E.Pair{...}` that
            // `resolveExpressionTypeName` recovers as `E`). An unresolved TypeId would wrongly answer
            // "not owned" and leak the box; the resolved string is the better source here.
            if (self.type_store) |ts| {
                // Prefer the string ALSO for a `.type_param` TypeId: a method-level param (`U` in
                // `map<U>`) is not resolvable by `isOwnedTypeId` (it isn't in the struct instantiation →
                // erasure rule → non-owned), but in a SPECIALIZED body the string `type_string` was already
                // run through `substMethodParams` (U→string), so it carries the concrete owned type. Using
                // the TypeId here left `mapped = fn(val)` (type U→string) unreleased while `List_string_push`
                // retained it — a per-element leak once inferred-arg calls route to the specialization.
                // Safe for a STRUCT-level `T` in an erased body: the string is also `"T"` → same answer.
                const k = ts.get(tid);
                if (k != .unresolved and k != .type_param) return self.isOwnedTypeId(tid);
            } else {
                return self.isOwnedTypeId(tid);
            }
        }
    }
    return self.isRefCountedType(type_string);
}

/// F4 keystoneSubst removal: the CONCRETE type of `expr` — the per-instantiation type from the IR when
/// compiling a monomorphized body, else the recorded (possibly erased) type. Projections (err-union arm,
/// storage element, tuple element) start from this so they project a CONCRETE inner type and never reach
/// `isOwnedTypeId(.type_param)` -> keystoneSubst.
fn typeOfExprConcrete(self: *LlvmCompiler, expr_ptr: *const ast.Expression) ?typesys.TypeId {
    const ir = self.typed_ir orelse return null;
    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct| return ct;
    }
    return ir.typeOf(expr_ptr);
}

/// F2-6: is `expr`'s TYPE (from the typed IR) `string`? The rendered-type STRING can misname a value
/// — a destructured tuple element renders as `"i32"` when its tuple type does not round-trip through
/// `resolveExpressionTypeName` — so `+` string-concat and `==` string-comparison detection must ask
/// the TypeId, not the name. Without this, `let (v, e) = f(); v + e` (e a string) did a NUMERIC add
/// on the string pointer → garbage, while `e.length` (TypeId path) worked. Falls back to false when
/// the expr has no recorded type (the rendered-string check still runs alongside).
pub fn isStringExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .string;
        }
    }
    return false;
}

/// If `expr` is a TUPLE whose element `idx` has a TRAIT type (sema now types a struct element in a
/// trait slot AS the trait via contextual typing), return that trait's rendered name; else null.
/// Used to widen a struct element to the trait object at tuple construction — the one position the
/// widening had missed. `(1, A{}): (int, G)` otherwise stores a raw struct in the trait slot.
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

/// F5-2: is the OK arm of `expr`'s error-union type owned? Projects the ok TypeId straight out of
/// the `.error_union` in the store (`st.get(typeOf(expr)).error_union.ok`) and asks `isOwned` — the
/// same store-projection the tuple case uses. Falls back to the string `isRefCountedType(ok_string)`
/// when `expr` has no recorded error-union type (e.g. sema already unwrapped it), so it is
/// behavior-preserving. `ok_string` is still needed by the caller as the destructor's `.type_name`.
pub fn isOwnedErrUnionOk(self: *LlvmCompiler, expr_ptr: *const ast.Expression, ok_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            {
                const info = st.get(tid);
                if (info == .error_union) return self.isOwnedTypeId(info.error_union.ok);
            }
        }
    }
    return self.isRefCountedType(ok_string);
}

/// F5-2: is the ERR arm of `expr`'s error-union type owned? The symmetric twin of
/// `isOwnedErrUnionOk` — projects `.error_union.err` from the store and asks `isOwnedTypeId`.
/// Behavior-preserving: the err side is normally a payload enum, and `isOwnedTypeId(.enum_)`
/// routes through the rendered fallback that keys off `self.enums` (`enumIsTaggedUnion`) — the
/// exact answer `isRefCountedType(err_string)` gave. Falls back to the string when `expr` carries
/// no recorded error-union type. `err_string` is still the destructor's `.type_name` for the caller.
pub fn isOwnedErrUnionErr(self: *LlvmCompiler, expr_ptr: *const ast.Expression, err_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            {
                const info = st.get(tid);
                if (info == .error_union) return self.isOwnedTypeId(info.error_union.err);
            }
        }
    }
    return self.isRefCountedType(err_string);
}

/// F5-2: is the ELEMENT of `obj`'s `Storage<T>` owned? Projects the element TypeId straight out of
/// the `.storage` in the store (`st.get(typeOf(obj)).storage`) and asks `isOwnedTypeId` — the same
/// store-projection the tuple/error-union cases use. Falls back to `isRefCountedType(elem_string)`
/// when `obj` has no recorded `.storage` type, so it is behavior-preserving. A `Storage<T>` in an
/// erased body projects a `.type_param` element, which the principled erasure rule reads as
/// non-owned — matching `isRefCountedType("T")`.
pub fn isOwnedStorageElem(self: *LlvmCompiler, obj_ptr: *const ast.Expression, elem_string: []const u8) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, obj_ptr)) |tid| {
            {
                if (st.get(tid) == .storage) return self.isOwnedTypeId(st.get(tid).storage);
            }
        }
    }
    return self.isRefCountedType(elem_string);
}

/// F5-2: the TypeId whose rendered name is `name`, or null. Lazily builds a rendered-name -> TypeId
/// index from the store on first call (the store is index-based, so this is a straight scan). Used by
/// the name-only DECISION sites (destructor/box generators) to recover a TypeId from the type-NAME
/// string they are handed. A name absent from the index (a render-spelling mismatch, or a type interned
/// after the index was built) returns null and the caller keeps its string answer — behavior-preserving.
pub fn typeIdForRenderedName(self: *LlvmCompiler, name: []const u8) ?typesys.TypeId {
    const store = sema_shadow.live_store orelse return null;
    if (self.rendered_name_ids == null) {
        var map: std.StringHashMapUnmanaged(typesys.TypeId) = .empty;
        const n = store.count();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id: typesys.TypeId = @enumFromInt(i);
            // Only the aggregate kinds these sites ask about need indexing; skip the rest to keep the
            // map small and the spelling unambiguous. Last-wins on a collision is fine: two TypeIds
            // that render identically have identical ownership, which is all this index decides.
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

/// F5-2: is the element of a `Storage<elem_string>` owned, given only the ELEMENT name (the
/// storage destructor generator receives `elem`, not the container)? Reconstructs the container
/// name `Storage<elem>`, recovers its TypeId via the reverse index, and projects `.storage`.
/// Falls back to `isRefCountedType(elem_string)` — behavior-preserving. A `Storage<T>` projects a
/// `.type_param` element -> principled erasure rule -> non-owned, matching `isRefCountedType("T")`.
pub fn isOwnedStorageElemByName(self: *LlvmCompiler, elem_string: []const u8) bool {
    const container = std.fmt.allocPrint(self.allocator, "Storage<{s}>", .{elem_string}) catch return self.isRefCountedType(elem_string);
    defer self.allocator.free(container);
    if (self.typeIdForRenderedName(container)) |tid| {
        if (self.type_store) |st| {
            if (st.get(tid) == .storage) return self.isOwnedTypeId(st.get(tid).storage);
        }
    }
    return self.isRefCountedType(elem_string);
}

/// F5-2: is the payload arm (`is_err` ? err : ok) of the error-union NAMED `union_name` owned?
/// Recovers the `.error_union` TypeId from `union_name` via the reverse index and projects the arm,
/// asking `isOwnedTypeId`. Falls back to `isRefCountedType(payload_string)` — behavior-preserving.
/// For the name-only destructor/box generators (`buildErrUnion`, the err-union destructor body).
pub fn isOwnedErrUnionPayloadByName(self: *LlvmCompiler, union_name: []const u8, is_err: bool, payload_string: []const u8) bool {
    if (self.typeIdForRenderedName(union_name)) |tid| {
        if (self.type_store) |st| {
            const info = st.get(tid);
            if (info == .error_union) {
                return self.isOwnedTypeId(if (is_err) info.error_union.err else info.error_union.ok);
            }
        }
    }
    return self.isRefCountedType(payload_string);
}

/// F5-2: is element `idx` of the tuple NAMED `tuple_name` owned? Recovers the `.tuple` TypeId from
/// the reverse index and projects element `idx`, asking `isOwnedTypeId`. Falls back to
/// `isRefCountedType(elem_string)` — behavior-preserving. For the name-only tuple destructor body.
pub fn isOwnedTupleElemByName(self: *LlvmCompiler, tuple_name: []const u8, idx: usize, elem_string: []const u8) bool {
    if (self.typeIdForRenderedName(tuple_name)) |tid| {
        if (self.type_store) |st| {
            const info = st.get(tid);
            if (info == .tuple and idx < info.tuple.len) return self.isOwnedTypeId(info.tuple[idx]);
        }
    }
    return self.isRefCountedType(elem_string);
}

/// F5-2: is a DECLARED type (a `TypeRef` from a param / struct field / return / enum payload) owned?
///
/// The declared-type analogue of `isOwnedExpr` — there is no expression to `typeOf`, so it LOWERS the
/// `TypeRef` to a TypeId against the sema symbol table (reachable with no new plumbing via
/// `sema_shadow.live_sema`, the same store codegen already reads) and asks `isOwnedTypeId`.
///
/// It trusts that typed answer ONLY for a type the store decides DIRECTLY (`decidedDirectly`) —
/// concrete string / struct / array / tuple / storage / error_union / func / trait / prim / ptr /
/// future, where `st.isOwned` is measured to agree with the string path. A generic `T`, a payload
/// `.enum_`, or an `.unresolved` is declined and falls back to the caller's already-computed string.
/// Because a `.type_param`/`.unresolved` is NEVER trusted, `param_scopes` correctness cannot change
/// the answer (a mis-scoped generic simply lowers to `.unresolved` → the string path), so no scope
/// plumbing is needed. Behavior-preserving; removes the render round-trip for CONCRETE declared types.
pub fn isOwnedDeclaredType(self: *LlvmCompiler, tr: ast.TypeRef, string_fallback: []const u8) bool {
    if (sema_shadow.live_sema) |sm| {
        var l = lower.Lowerer.init(self.allocator, &sm.store);
        defer l.deinit();
        l.symtab = &sm.tab;
        const t = l.lower(tr) catch return self.isRefCountedType(string_fallback);
        if (decidedDirectly(&sm.store, t)) return self.isOwnedTypeId(t);
    }
    return self.isRefCountedType(string_fallback);
}

/// A2 stage-5 coverage extension: the TypeId of a DECLARED TypeRef (a param type, an annotated-let type),
/// lowered in the sema store, so a local whose initializer sema did not `typeOf` (annotated lets, params,
/// self) can still be keyed by TypeId in `current_local_type_ids` — flipping its scope-exit release to the
/// store-native destructor instead of the `isRefCountedType(string)` fallback. Returns null when no live
/// sema, the lower fails, or the result is `.unresolved` (a residual generic — the string fallback, which
/// isOwnedLocal already prefers for `.unresolved`, stays correct). A `.type_param` IS returned: the drain's
/// `isOwnedTypeId` resolves it via the instantiation context / erasure rule exactly as the string did.
pub fn tidForTypeRef(self: *LlvmCompiler, tr: ast.TypeRef) ?typesys.TypeId {
    const sm = sema_shadow.live_sema orelse return null;
    var l = lower.Lowerer.init(self.allocator, &sm.store);
    defer l.deinit();
    l.symtab = &sm.tab;
    const t = l.lower(tr) catch return null;
    if (sm.store.get(t) == .unresolved) return null;
    return t;
}

/// True when `isOwnedTypeId` decides `t` via `st.isOwned` DIRECTLY (not through the rendered-string
/// fallback). The three kinds it routes to that fallback — `.enum_`, `.type_param`, `.unresolved` —
/// are exactly where the typed answer could diverge from the caller's string, so those are declined.
fn decidedDirectly(store: *const typesys.TypeStore, t: typesys.TypeId) bool {
    return switch (store.get(t)) {
        .enum_, .type_param, .unresolved => false,
        .optional => |inner| decidedDirectly(store, inner),
        else => true,
    };
}

/// The pre-F4-5 fallback: render the (generic) type, substitute the instantiation's concrete
/// args, and ask the string function — exactly what `resolveExpressionTypeName` did. This is the
/// code the migration DELETES once `.type_param` no longer reaches codegen.
/// F5-2 enum-variant awareness: is the enum named by the store's `.enum_` SymbolId a HEAP BOX (a
/// tagged union with ≥1 payload variant), hence owned? Resolves the SymbolId to the enum's NAME
/// through the sema symbol table (a reliable SymbolId→name resolution, NOT a string match) and asks
/// `enumIsTaggedUnion`. Returns null when the SymbolId cannot be resolved to a known enum, so the
/// caller keeps the render-path answer — behavior-preserving. This takes `.enum_` off the
/// `isOwnedRenderedFallback` (render → substTypeParams → isRefCountedType) round-trip: the store's
/// own SymbolId, not a rendered string, now drives the enum ownership decision.
fn isOwnedRenderedFallback(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    const rendered = sema_shadow.renderLegacy(self.allocator, st, t) catch return false;
    const subst = self.substTypeParams(rendered) catch return false;
    return self.isRefCountedType(subst);
}

/// F1 module-scoped types: the module-unique codegen spelling for a struct declared in `file`, or the
/// bare `name` when it doesn't collide (the no-op case). Reads the symbol table's precomputed
/// `scoped_name`, so it is byte-identical to what `renderLegacy` (hence `resolveExpressionTypeName`)
/// produces for a reference — that agreement is what makes definition and reference resolve to the same
/// struct/method/vtable symbol.
pub fn scopedStructName(self: *LlvmCompiler, name: []const u8, file: []const u8) []const u8 {
    _ = self;
    if (sema_shadow.live_sema) |sm| {
        if (sm.tab.scopedNameFor(name, file)) |scoped| return scoped;
    }
    return name;
}

/// F1 module-scoped types: is `name` a BARE struct name that collides across modules? Only for such a
/// name does a construction site need to recover the module-unique spelling from the typed result — for
/// every other call (including a plain fn returning a struct) the bare name is already correct, so
/// gating on this keeps the scoping override from hijacking non-colliding calls.
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
        // Fill a sema typing gap: an enum-variant STRUCT-payload construction `E.Variant{ f: v }` is
        // of type E, but sema leaves the struct-init form untyped (the CALL form `E.Variant(v)` is
        // typed and never reaches here). Codegen knows E from the variant name. Resolving to E is what
        // registers the `let` box as an owned local, so it — and its payload — get released by
        // __destruct_<Enum> instead of leaking. Without this, `let p = E.Pair{...}` leaked its box.
        if (expr_ptr.kind == .struct_init) {
            if (self.findEnumByVariant(expr_ptr.kind.struct_init.type_name)) |enum_name| return enum_name;
        }
        // A bare IDENT sema did not type (a CLOSURE PARAMETER — its type comes from the call site,
        // not the body) falls back to `current_local_types`, which the closure-param resolver
        // populates from the ACTUAL call ARGUMENT types (findLambdaCallSiteInBlock, incl. the
        // bound-then-called `let g = <closure>; g(5)` shape). Mirror of isOwnedExpr's ident fallback.
        // Without this, `${x}` for a scalar closure param resolved to NO type and
        // compileAppendToStringBuilder derefed the raw scalar as a string pointer — a SIGSEGV. When
        // the resolver could not find the call it leaves the honest machine-word default, so a param
        // it could not type takes the numToString path (correct for a scalar, a harmless mis-format
        // for a string) rather than crashing — no interpolation is ever memory-unsafe again.
        if (expr_ptr.kind == .ident) {
            if (self.current_local_types) |lt| {
                if (lt.get(expr_ptr.kind.ident)) |ts| return ts;
            }
        }
        return null;
    }
    const t = t_opt.?;
    // F4 4b render boundary #2: INFERRED types. Sema typed each generic body ONCE,
    // erased, so `self.data.get(i)` in `List<T>` renders `.type_param` as `"T"`
    // (shadow.zig:595). Cloning the AST cannot fix this — `expr_types` is keyed by
    // `ExprId`, so a clone either inherits this same erased type or has none at all
    // (F4 §5, 4b correction). Substituting the rendered name is what does.
    // A no-op outside a monomorphized body.
    return try self.substTypeParams(try sema_shadow.renderLegacy(self.allocator, st, t));
}


pub fn resolveCalleeName(self: *LlvmCompiler, callee_name: []const u8) ![]const u8 {
    if (self.hasFunction(callee_name)) {
        return callee_name;
    }
    // F4 4b: inside `List_string_push`, `self.grow()` must reach `List_string_grow`,
    // not the erased `List_grow`. `current_struct_name` is the BASE (`List`) — it has
    // to be, because that is where the declarations live — so the struct-name path
    // below would bind a monomorphized body's internal calls straight back into the
    // erased ones, and every instantiation would share `grow`'s undecidable ARC again.
    // Measured: `List_string_push` called `@List_grow` while `@List_string_grow` sat
    // emitted and uncalled.
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

    // ---- F1-3b: THE FUNC_MAP SUFFIX SCAN IS DELETED ----------------------
    // What used to live here (~70 lines): two passes scanning `functions` and `func_map` for a key
    // ending in `_<callee_name>`, GUESSING resolution by suffix and erroring on a 2+-way tie (N2). It
    // was fragile — a bare `contains` picked `string_contains` or `assert_contains` by table order —
    // and it is now DEAD:
    //   • Resolution: measured 0 scan reaches across the whole corpus (137→0). Every call resolves
    //     through the exact paths above — SymbolId (symOf→legacy_mangled), the struct/constructor
    //     table, current_instantiation mono, and current_module_prefix. The constructor paths and the
    //     serde-binder globalization (F4-6) closed the last reaches.
    //   • N2 ambiguity: MOVED to the type_checker (a bare call to a name two modules share is a
    //     TYPECHECK error with a source span, gated by the file-locality rule — `ambiguous_bare_call`).
    //     Compilation now stops at typecheck before an ambiguous call ever reaches codegen.
    //
    // So an unresolved name here is a genuine miss: return it unchanged and the caller raises a loud
    // `FunctionNotFound` (the same behavior the old "nothing matched" tail had) — never a suffix guess.
    if (sema_shadow.trace_resolution) sema_shadow.scan_unresolved += 1;
    return callee_name;
}

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b). `mangleTypeName` is a pure function over a
// string, so it is testable without an LlvmCompiler — and it is the one thing 4b
// and G3 SHARE. If these two ever spell `List<string>` differently, a call lands in
// the wrong instantiation's body, which is a memory bug wearing a link error's
// clothes.
// ---------------------------------------------------------------------------
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
    // renderLegacy emits `", "` between args (shadow.zig), so BOTH the comma and the
    // space would each append a `_` without the run-collapsing guard.
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
    // The whole claim of monomorphization. If these collapsed to one symbol we would
    // be back to erasure, with a link that silently picks a winner.
    const a = try mangleTypeName(testing.allocator, "List<int>");
    defer testing.allocator.free(a);
    const b = try mangleTypeName(testing.allocator, "List<string>");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "the test module can SEE llvm — the wiring, not a lucky absence" {
    // Not a test of `llvm`; a test of `build.zig`. `mod` (what `zig build test`
    // compiles) reaches this file, which imports `llvm` — but `llvm` was attached
    // only to the EXE's module, so the tests here built ONLY while none of them
    // named an llvm-typed decl. Zig analyses top-level decls lazily, so
    // `const llvm = @import("llvm")` sat unresolved and harmless until something
    // touched it, and then: "no module named 'llvm' available within module 'root'".
    //
    // Naming `core`/`types` forces that import to resolve, so if `mod.addImport(
    // "llvm", ..)` is ever dropped this fails to BUILD instead of quietly shrinking
    // the set of tests anyone is able to write for codegen.
    _ = core;
    _ = types;
    try testing.expect(true);
}
