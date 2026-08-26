//! Type-name plumbing and ownership decisions for the LLVM backend.
//!
//! This is the codegen layer's "what IS this type" oracle. Every other codegen
//! file (`expressions.zig`, `statements.zig`, `arc.zig`, `declarations.zig`)
//! reaches into here whenever it needs to translate a Nova type into an LLVM
//! representation, mangle a name into a valid symbol, or answer the single
//! most consequential question the backend asks: "does this value OWN a heap
//! allocation, so that a copy must retain it and its last use must release it?"
//! Getting that ownership answer wrong is not a soft failure: an over-release
//! is a use-after-free and an under-release is a leak, so the functions here
//! are written to fail LOUDLY (abort the compile) rather than guess when sema
//! never actually typed the value.
//!
//! The file has four intertwined jobs:
//!
//!   1. Name canonicalisation and mangling ([`getStructBaseName`],
//!      [`mangleTypeName`], [`methodSymbol`], [`qualifySelfType`]). Nova's
//!      human-readable type spellings (`List<Map<string, int>>`, `Foo.Bar`,
//!      `int`) become stable, collision-free LLVM symbol names. The primitive
//!      aliases are canonicalised first (`int`→`i32`, `long`→`i64`, ...) so that
//!      two spellings of the same type never mangle to two different symbols.
//!
//!   2. The codegen representation of primitives ([`CgRepr`], [`CgPrim`],
//!      [`cgPrim`], [`reprBitWidth`]) and the mapping from a Nova type to a
//!      concrete `LLVMTypeRef` ([`toLLVMType`], [`llvmForRepr`],
//!      [`slotTypeForLocal`], the SIMD-vector helpers). Most Nova values live
//!      in a uniform 64-bit "val" slot; the exceptions handled here are
//!      floats/doubles (kept in their FP register), SIMD vectors, and value
//!      optionals.
//!
//!   3. The bitcast bridges between that uniform val slot and a specific LLVM
//!      type ([`coerceToSlotType`], [`castToValType`], [`castFromValType`]).
//!      These respect signedness (sext vs zext) and the float/double widening
//!      that the val slot forces, because a wrong choice silently corrupts a
//!      numeric value.
//!
//!   4. Ownership analysis, the heart of the file. There are two engines that
//!      must agree: the authoritative TYPED path over `TypeStore`/`TypeId`
//!      ([`isOwnedTypeId`] and its many typed entry points), and a legacy
//!      STRING-name path ([`ownedByName`]) kept as a fallback for the cases the
//!      typed IR cannot resolve (erased type params without an instantiation,
//!      un-lowered names). [`tdShadowDiff`] cross-checks the two whenever
//!      `NOVA_SEMA_SHADOW` reporting is on, and the whole file is part of the
//!      long migration off string-based ownership (`irct_*` counters). Sitting
//!      alongside is the VALUE-STRUCT classifier ([`isValueStructName`],
//!      [`computeValueEscapeSet`]): a plain `struct` is value-semantic (copied,
//!      not refcounted) UNLESS it escapes by return, trait impl, `@serializable`,
//!      a reference-typed field, or a generic argument, in which case it falls
//!      back to reference semantics. That escape set is computed once and cached
//!      on the compiler.
//!
//! Nearly every `pub fn` takes `self: *LlvmCompiler`: this module is
//! effectively a mixin of free functions over the compiler's state (its
//! `type_store`, `typed_ir`, `current_instantiation_id`, struct/enum/trait
//! tables) rather than an independent abstraction. The functions are grouped
//! here purely because they are all "about types".

const std = @import("std");
const ast = @import("../../frontend/ast.zig");
/// Type-engine SHADOW/diagnostics module. Owns the legacy string renderer
/// ([`sema_shadow.renderLegacy`]) that turns a `TypeId` back into its
/// human-readable name, the live singletons (`live_store`, `live_sema`) codegen
/// borrows to lower a bare name, and the `td_*`/`irct_*`/`census_*` counters
/// that record where the typed and string ownership engines agree or disagree.
const sema_shadow = @import("../../frontend/sema/shadow.zig");
/// Monomorphisation results. [`instantiationsOf`] reads `live_instantiations`
/// (the concrete generic instantiations sema discovered) to emit one copy of a
/// generic struct's methods per instantiation.
const sema_mono = @import("../../frontend/sema/mono.zig");
/// Type-parameter substitution helpers (imported for module wiring; the
/// overlay substitution used here is [`substViaOverlay`], defined locally).
const subst_mod = @import("../../frontend/sema/subst.zig");
/// The inference pass's typed IR type ([`sema_infer.TypedIr`]), needed to spell
/// the parameter of [`substViaOverlay`] which walks a type resolving type
/// params through an instantiation overlay.
const sema_infer = @import("../../frontend/sema/infer.zig");
/// The name→`TypeId` lowerer. Codegen uses [`lower.Lowerer`] on the live sema
/// symbol table to resolve a bare type name or an `ast.TypeRef` into a store id
/// when the typed IR did not already carry one.
const lower = @import("../../frontend/sema/lower.zig");
/// The ARC codegen module. Its global flags gate value-struct behaviour
/// (`value_structs_enabled`, `value_structs_all`, `value_type_set`) and its
/// [`arc_mod.isUntypeablePlaceholder`] identifies names that must never reach
/// an ownership decision.
const arc_mod = @import("arc.zig");
/// The type system core: `TypeId`, `TypeStore`, `SymbolId`, and the `.isOwned`
/// predicate that the typed ownership path defers to.
const typesys = @import("../../frontend/types.zig");
/// The LLVM C-API bindings root.
const llvm = @import("llvm");
/// LLVM type/value handle aliases (`LLVMTypeRef`, `LLVMValueRef`, the type
/// kinds).
const types = llvm.types;
/// LLVM core builder functions (`LLVMBuild*`, `LLVMGetTypeKind`, the primitive
/// type constructors).
const core = llvm.core;

/// The backend compiler state every `pub fn` here operates on: the type store,
/// typed IR, current instantiation, and the struct/enum/union/trait tables.
/// These functions are logically methods of it, split out by topic.
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;

/// Strips a Nova type name down to its bare struct/enum identifier.
///
/// Drops any module qualifier before the last `.` (`foo.Bar` → `Bar`) and any
/// generic argument list starting at `<` (`List<int>` → `List`). The result is
/// the key used to look a declaration up in the compiler's `structs`/`enums`/
/// `unions` tables, which are all indexed by bare name. Returns a borrowed
/// sub-slice of the input; it allocates nothing.
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

/// Maps a Nova primitive alias to its canonical LLVM-integer spelling, or null
/// for anything that is not one of the ten aliases.
///
/// This is what makes mangling collision-free across spellings: `int` and `i32`
/// are the same type, so both must mangle to `i32`. Called per identifier token
/// by [`mangleTypeName`]; a non-primitive token passes through unchanged.
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

/// True for the characters that make up an identifier token (`[A-Za-z0-9_]`).
///
/// Used by [`mangleTypeName`] to segment a type spelling into identifier runs
/// (which get alias-canonicalised) versus punctuation (`<`, `>`, `,`, brackets)
/// that gets encoded.
fn isTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Turns a Nova type spelling into a valid, collision-free LLVM symbol name.
///
/// Identifier runs are copied through [`canonicalPrimAlias`] so alias spellings
/// unify, and the type-syntax punctuation is encoded so distinct types never
/// collapse to the same symbol: `<`, `>`, `,` and spaces each become a single
/// `_` separator (runs of them coalesce, so `Map<string, int>` →
/// `Map_string_int`, not `Map_string__int`), while `(` `)` `-` `=` `|` map to
/// `_lp`/`_rp`/`_da`/`_eq`/`_or`. A trailing `_` is trimmed. Caller owns the
/// returned buffer. See [`methodSymbol`], which appends the method name onto
/// this to form a mangled method symbol.
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
            '|' => try buf.appendSlice(allocator, "_or"),
            else => try buf.append(allocator, c),
        }
        i += 1;
    }

    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') _ = buf.pop();
    return buf.toOwnedSlice(allocator);
}

/// Rewrites the bare name of the type currently being compiled into its fully
/// instantiated spelling, so `Self`-typed things pick up the concrete generic
/// args.
///
/// While emitting a method of, say, `Box<int>` the compiler's
/// `current_instantiation` is `"Box<int>"`. A field or local typed with the
/// bare `"Box"` should compile as `"Box<int>"` in that context. Returns the
/// input unchanged when there is no active instantiation, when the name is
/// already generic (contains `<`), or when its base name is not the struct
/// being instantiated. Borrows; allocates nothing.
pub fn qualifySelfType(self: *LlvmCompiler, type_name: []const u8) []const u8 {
    const inst = self.current_instantiation orelse return type_name;
    if (std.mem.indexOfScalar(u8, type_name, '<') != null) return type_name;
    if (!std.mem.eql(u8, type_name, getStructBaseName(inst))) return type_name;
    return inst;
}

/// Builds the mangled LLVM symbol for a method: `mangle(owner) ++ "_" ++ method`.
///
/// This is the canonical name codegen emits and calls for `owner.method(...)`.
/// The owner is mangled via [`mangleTypeName`] (so `List<int>.push` becomes
/// `List_int_push`); `method` is appended verbatim. Caller owns the result.
pub fn methodSymbol(self: *LlvmCompiler, owner: []const u8, method: []const u8) ![]const u8 {
    const mangled = try mangleTypeName(self.allocator, owner);
    defer self.allocator.free(mangled);
    return std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mangled, method });
}

/// Lists the concrete instantiations of a struct declaration that codegen must
/// emit, as instantiation-name strings (`null` meaning "the erased/base body").
///
/// The first element is always `null`: even a generic struct emits an erased
/// base body (link-time fallback with internal linkage that globalDCE later
/// drops). A non-generic struct returns just `[null]`. For a generic struct it
/// then appends every entry of `sema_mono.live_instantiations` whose base name
/// matches `s.name`, i.e. every `List<int>`, `List<string>`, ... sema actually
/// discovered. Caller owns the returned slice. Drives per-instantiation method
/// emission alongside [`methodSymbol`].
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

/// True if the name refers to a user-declared aggregate: a struct, union, or
/// enum.
///
/// Reduces to the base name first via [`getStructBaseName`], so a generic
/// spelling or module-qualified name still matches. Distinguishes "has an
/// aggregate layout in one of the tables" from a primitive or a builtin.
pub fn isStructType(self: *LlvmCompiler, type_name: []const u8) bool {
    const base = getStructBaseName(type_name);
    return self.structs.contains(base) or self.unions.contains(base) or self.enums.contains(base);
}

/// The distinct machine representations codegen lowers a primitive to.
///
/// `i1`/`i8`/`i16`/`i32`/`i64` are the integer widths; `f32`/`f64` the floats;
/// `word` is the pointer-width machine word (`ptr`), 64-bit here but kept
/// separate from `i64` so pointer-ish values are recognisable. See [`cgPrim`]
/// which classifies a name into one of these plus a sign, and [`llvmForRepr`]
/// which materialises the LLVM type.
pub const CgRepr = enum { i1, i8, i16, i32, word, i64, f32, f64 };

/// The bit width of a [`CgRepr`]. `word` is 64 on this target, same as `i64`.
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

/// A classified primitive: its machine representation plus its signedness.
///
/// Signedness is separate from [`CgRepr`] because `u32` and `i32` share the
/// `i32` representation but differ on whether a widening cast should zext or
/// sext (see [`castToValType`]).
pub const CgPrim = struct { repr: CgRepr, signed: bool };

/// Classifies a type name as a primitive, or null if it is not one.
///
/// Recognises both the Nova alias spellings (`int`, `long`, `byte`, `float`, ...)
/// and the explicit-width spellings (`i32`, `u64`, `f64`, ...), plus `bool` (as
/// `i1`) and `ptr` (as an unsigned `word`). Note the deliberate collapse:
/// `byte`/`ubyte`/`u8` are all unsigned `i8` while `sbyte`/`i8` are signed
/// `i8`. This is the single source of truth for "is this a primitive and how is
/// it represented"; [`isPrimitiveTypeName`], [`toLLVMType`], and the cast
/// bridges all consult it.
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

/// True if the name spells a VALUE optional: a primitive OR-ed with `undefined`
/// (`int | undefined`, `undefined | float`).
///
/// A value optional is one whose non-null arm is a primitive, so it can be
/// represented inline in the 64-bit val slot with a sentinel rather than boxed
/// on the heap (see [`slotTypeForLocalId`]). The check is strict: exactly one
/// `|`, exactly one arm equal to `undefined`, the other a primitive that is
/// neither `any` nor `void`. Anything with a second `|`, or a non-primitive
/// arm, is not a value optional.
pub fn valueOptionalName(name: []const u8) bool {
    const bar = std.mem.indexOfScalar(u8, name, '|') orelse return false;
    const lhs = std.mem.trim(u8, name[0..bar], " ");
    const rhs = std.mem.trim(u8, name[bar + 1 ..], " ");
    if (std.mem.indexOfScalar(u8, rhs, '|') != null) return false;
    const value_arm = if (std.mem.eql(u8, rhs, "undefined")) lhs else if (std.mem.eql(u8, lhs, "undefined")) rhs else return false;
    return isPrimitiveTypeName(value_arm) and
        !std.mem.eql(u8, value_arm, "any") and
        !std.mem.eql(u8, value_arm, "void");
}

/// True if the name is a codegen primitive in the broad sense: a [`cgPrim`]
/// scalar, `void`, `any`, or a SIMD vector (`f64x4` and the [`simdVecName`]
/// set).
///
/// "Primitive" here means "not an owned heap value": [`ownedByName`] uses this
/// as the fast, allocation-free short-circuit that classifies such a name as
/// non-owning without touching the type store.
pub fn isPrimitiveTypeName(type_name: []const u8) bool {

    return cgPrim(type_name) != null or
        std.mem.eql(u8, type_name, "void") or
        std.mem.eql(u8, type_name, "f64x4") or
        simdVecName(type_name) != null or
        std.mem.eql(u8, type_name, "any");
}

/// Recognises the fixed-width SIMD vector type names, returning the element bit
/// width and lane count, or null.
///
/// Covers `u8x16` (16 lanes of 8 bits), `u32x4`, and `u64x2`. Consumed by
/// [`slotTypeForLocalId`] to build the corresponding `LLVMVectorType`. Note
/// `f64x4` is handled separately (as a double vector) and is not in this table.
pub fn simdVecName(type_name: []const u8) ?struct { elem: c_uint, lanes: c_uint } {
    if (std.mem.eql(u8, type_name, "u8x16")) return .{ .elem = 8, .lanes = 16 };
    if (std.mem.eql(u8, type_name, "u32x4")) return .{ .elem = 32, .lanes = 4 };
    if (std.mem.eql(u8, type_name, "u64x2")) return .{ .elem = 64, .lanes = 2 };
    return null;
}

/// Materialises the `LLVMTypeRef` for a [`CgRepr`].
///
/// Prefers the compiler's cached context types (`i1_type`, `i8_type`,
/// `i32_type`, `i64_type`, `val_type` for `word`) where they exist, falling
/// back to freshly constructed global types for `i16`/`f32`/`f64`. `word` maps
/// to `val_type`, the uniform 64-bit slot the runtime passes values in.
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

/// Lowers an `ast.TypeRef` to an LLVM type, coarsely.
///
/// A bare-identifier primitive lowers to its [`llvmForRepr`] type; EVERYTHING
/// else (non-primitive identifiers, optionals, tuples, arrays, generics, ...)
/// lowers to the opaque `ptr_type`. This is the coarse "is it a scalar or a
/// pointer" lowering used where an exact aggregate layout is not needed; the
/// finer slot decisions live in [`slotTypeForLocalId`].
pub fn toLLVMType(self: *LlvmCompiler, type_ref: ast.TypeRef) types.LLVMTypeRef {
    switch (type_ref) {
        .ident => |name| {
            if (cgPrim(name)) |p| return self.llvmForRepr(p.repr);
            return self.ptr_type;
        },
        else => return self.ptr_type,
    }
}

/// Chooses the LLVM type of a local variable's stack slot from its name alone.
///
/// Thin wrapper over [`slotTypeForLocalId`] with no `TypeId`; use the id-taking
/// form when a resolved type is available, since it can additionally recognise
/// value optionals and arrays.
pub fn slotTypeForLocal(self: *LlvmCompiler, type_name: ?[]const u8) types.LLVMTypeRef {
    return self.slotTypeForLocalId(type_name, null);
}

/// Chooses the LLVM type of a local variable's `alloca` slot.
///
/// Most locals live in the uniform 64-bit `val_type` slot, which is the default
/// return. The exceptions, in priority order: a value optional (by `TypeId`) or
/// an array stays a `val`/`ptr` respectively; a `f64x4` or [`simdVecName`]
/// vector gets a real LLVM vector type; a `[`-bearing (array) name is a `ptr`;
/// and a float/double primitive is stored as a `double` slot (floats are
/// widened, matching [`castToValType`]). Passing the `TypeId` lets it catch the
/// value-optional and array cases that the name alone cannot.
pub fn slotTypeForLocalId(self: *LlvmCompiler, type_name: ?[]const u8, type_id: ?typesys.TypeId) types.LLVMTypeRef {
    if (type_id) |tid| {
        if (self.valueOptionalInner(tid) != null) return self.val_type;
        if (self.type_store) |st| {
            if (st.get(tid) == .array) return self.ptr_type;
        }
    }
    if (type_name) |tn| {
        if (std.mem.eql(u8, tn, "f64x4")) return core.LLVMVectorType(core.LLVMDoubleType(), 4);
        if (simdVecName(tn)) |v| return core.LLVMVectorType(core.LLVMIntType(v.elem), v.lanes);
        if (std.mem.indexOfScalar(u8, tn, '[') != null) return self.ptr_type;
        if (cgPrim(tn)) |p| {
            if (p.repr == .f64 or p.repr == .f32) return core.LLVMDoubleType();
        }
    }
    return self.val_type;
}

/// The LLVM type for `f64x4`: a 4-lane vector of doubles. Takes `self` only for
/// call-site uniformity; it uses none of it.
pub fn vecF64x4Type(self: *LlvmCompiler) types.LLVMTypeRef {
    _ = self;
    return core.LLVMVectorType(core.LLVMDoubleType(), 4);
}

/// Bitcasts a value so it can be stored into a slot of a given LLVM type.
///
/// A no-op when the value already has `slot_ty`. Otherwise it bridges the four
/// mismatches that occur when a uniform-slot value meets a typed slot (or vice
/// versa): int↔double via bitcast, and int↔pointer via int-to-ptr / ptr-to-int.
/// These are REPRESENTATION casts (same bits, reinterpreted), not numeric
/// conversions; see [`castToValType`]/[`castFromValType`] for the width- and
/// sign-aware numeric conversions. Any unhandled combination returns `val`
/// unchanged.
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
    if (sk == .LLVMPointerTypeKind and vk == .LLVMIntegerTypeKind) {
        return core.LLVMBuildIntToPtr(self.builder, val, slot_ty, "val_to_ptr");
    }
    if (sk == .LLVMIntegerTypeKind and vk == .LLVMPointerTypeKind) {
        return core.LLVMBuildPtrToInt(self.builder, val, slot_ty, "ptr_to_val");
    }
    return val;
}

/// Converts a typed value INTO the uniform 64-bit `val_type` slot.
///
/// This is how a concrete-typed SSA value becomes a generic `val` the runtime
/// and containers can hold. Pointers are ptr-to-int'd; doubles are bitcast;
/// floats are FP-extended to double first then bitcast (so a 32-bit float
/// round-trips through 64 bits); integers narrower than the val width are
/// extended, and the sign of that extension is read from `type_ref` via
/// [`cgPrim`] (unsigned → zext, signed → sext) so the numeric value is
/// preserved, while wider integers are truncated. This is the inverse of
/// [`castFromValType`]. The `type_ref` matters ONLY for choosing zext vs sext;
/// getting it wrong sign-corrupts an unsigned value.
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

/// Converts a uniform `val_type` value back OUT to a concrete LLVM type.
///
/// The inverse of [`castToValType`], driven by the target's LLVM type KIND
/// rather than a Nova `TypeRef`: to a pointer → int-to-ptr; to a double →
/// bitcast; to a float → bitcast-to-double then FP-truncate; to an integer →
/// truncate or sign-extend to width, or, for a full 64-bit integer target that
/// actually holds float/double bits, bitcast (with a float first FP-extended to
/// double). Sign-extension here is unconditional because the target width, not
/// the source signedness, is what is known at this seam. Unhandled shapes
/// return `val` unchanged.
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

/// Renders an `ast.TypeRef` back to its canonical Nova type-name string.
///
/// This is the codegen spelling of a type as it will key mangling, ownership,
/// and the struct tables. It runs type-param substitution on bare identifiers
/// (via `substTypeParams`) and encodes the compound forms deliberately:
///   * a value-optional primitive keeps its `T | undefined` spelling, but a
///     non-primitive optional renders as just its inner type (optionals of
///     heap types are represented by the pointer, not a distinct name);
///   * error unions render as `ErrUnion(ok,err)`, tuples as `(a,b,...)`,
///     fixed arrays as `elem[N]`, function types as `(params) -> ret`, and
///     generics as `Name<a, b>` (bare `Name` when there are no params).
/// Recursive; several arms allocate a working buffer and return an owned slice,
/// so the caller owns the result. Used pervasively as the string bridge into
/// [`mangleTypeName`] and [`ownedByName`].
pub fn typeRefToString(self: *LlvmCompiler, type_ref: ast.TypeRef) anyerror![]const u8 {
    switch (type_ref) {

        .ident => |name| return try self.substTypeParams(name),
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

/// True if an expression's resolved type is an optional.
///
/// Consults the typed IR ([`typed_ir`].typeOf) and the type store; false when
/// either is absent or the expression was never typed. Distinct from
/// [`valueOptionalName`], which is a purely syntactic classifier: this asks the
/// type engine.
pub fn isOptionalExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;
    const t = ir.typeOf(expr_ptr) orelse return false;
    return st.get(t) == .optional;
}

/// The expression-level ownership oracle: does the value this expression yields
/// own a heap allocation that codegen must retain on copy and release at last
/// use?
///
/// This is the most-used ownership entry point and it layers several fallbacks,
/// most-precise first, because an expression can be typed to varying degrees of
/// concreteness:
///   1. If a concrete `TypeId` is available AND it is a value optional, the
///      answer is whether the expression actually produces a boxed valopt
///      ([`exprYieldsValoptBox`]) rather than an inline one.
///   2. Under an active instantiation, resolve the expression's per-inst type
///      through the overlay and, if it is neither unresolved nor a bare type
///      param, defer to [`isOwnedTypeId`].
///   3. Otherwise take the plain `typeOf`, resolving a lone type param through
///      the current instantiation.
///   4. If still untyped/unresolved and the expression is an identifier, fall
///      back to the local variable's declared type string
///      ([`isOwnedLocal`]); failing everything, answer NOT owned (false), the
///      safe-against-double-free default.
/// Delegates the actual decision to [`isOwnedTypeId`] once a usable id is in
/// hand.
pub fn isOwnedExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    const ir = self.typed_ir orelse return false;
    const st = self.type_store orelse return false;

    if (self.typeOfExprConcrete(expr_ptr)) |ct| {
        if (self.valueOptionalInner(ct) != null) return self.exprYieldsValoptBox(expr_ptr);
    }

    if (self.current_instantiation_id) |inst| {
        if (ir.typeOfInst(expr_ptr.id, inst)) |ct0| {
            const ct = if (st.get(ct0) == .type_param) (ir.tpResolve(ct0, inst) orelse ct0) else ct0;
            if (st.get(ct) != .unresolved and st.get(ct) != .type_param) return self.isOwnedTypeId(ct);
        }
    }
    var t_opt = ir.typeOf(expr_ptr);

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
    return self.isOwnedTypeId(t_opt.?);
}

/// Records whether the TYPED and legacy-STRING ownership engines agree for a
/// type, feeding the `sema_shadow.td_*` counters. Diagnostics only; it changes
/// no compilation result.
///
/// This is the instrumentation behind the migration off string ownership. For a
/// type param it resolves the concrete substitution and compares the typed
/// `isOwned` against the string fallback ([`isOwnedRenderedFallback`]), counting
/// `td_keystone_resolves`/`td_keystone_disagree` and stashing the last
/// disagreement; when there is no instantiation or the param stays a param it
/// buckets into `td_blocked_*`. For a concrete type it compares
/// `store.isOwned` against [`legacyStringOwnership`] of the rendered name,
/// counting `td_agree`/`td_disagree`. Optionals recurse on the inner; enums and
/// unresolved types are counted as blocked. Called from [`isOwnedTypeId`] only
/// when `sema_shadow.report_enabled`.
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

/// True if a field's type name is a scalar that never owns heap memory.
///
/// Broader than [`cgPrim`]: it also whitelists `char`, `usize`, `isize`, and
/// `word` by name. Used by the value-struct escape analysis
/// ([`computeValueEscapeSet`], [`isPureValueStructRec`]) to decide that a field
/// contributes no owned storage, so a struct made only of scalars (and strings)
/// can stay value-semantic.
fn isScalarFieldTypeName(name: []const u8) bool {
    const scalars = [_][]const u8{ "int", "long", "short", "byte", "bool", "float", "double", "char", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "word", "usize", "isize" };
    for (scalars) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True if a call's callee is an identifier that names a known struct, i.e. the
/// call is really a struct construction `Foo(...)` producing a fresh owned
/// value.
///
/// Used by [`returnIsBorrow`] to tell "returning a constructed struct" (owned,
/// escapes) from "returning a function's result" (treated as a borrow).
fn calleeNamesStruct(self: *LlvmCompiler, callee: *const ast.Expression) bool {
    if (callee.kind == .ident) return self.structs.contains(getStructBaseName(callee.kind.ident));
    return false;
}
/// True if a returned expression yields only a BORROW, not a freshly owned
/// value that escapes the function.
///
/// Literals, binary/unary ops, field accesses, indexing, casts, and ranges are
/// borrows. A call or generic-call is a borrow UNLESS its callee names a struct
/// (a constructor, which mints an owned value: see [`calleeNamesStruct`]).
/// Everything else is conservatively not a borrow. This drives the value-struct
/// escape analysis: a struct returned via a non-borrow path escapes and must
/// fall back to reference semantics (see [`computeValueEscapeSet`],
/// [`blockHasNonBorrowReturn`]).
pub fn returnIsBorrow(self: *LlvmCompiler, expr: *const ast.Expression) bool {
    return switch (expr.kind) {
        .literal, .binary, .unary, .field_access, .index, .cast, .range => true,
        .call => |c| !calleeNamesStruct(self, c.callee),
        .generic_call => |gc| !calleeNamesStruct(self, gc.callee),
        else => false,
    };
}
/// True if a statement subtree contains any `return` whose value is NOT a
/// borrow (see [`returnIsBorrow`]).
///
/// Walks into blocks, both arms of `if`, loop bodies, and every switch case /
/// default. A bare `return;` (no value) does not count. This is the "does this
/// function ever hand back a freshly owned value" test used by
/// [`computeValueEscapeSet`]. Mutually recursive with [`blockHasNonBorrowReturn`].
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
/// True if any statement in a block has a non-borrow return. The list-level
/// half of [`stmtHasNonBorrowReturn`].
fn blockHasNonBorrowReturn(self: *LlvmCompiler, stmts: []const ast.Statement) bool {
    for (stmts) |*st| if (stmtHasNonBorrowReturn(self, st)) return true;
    return false;
}

/// Adds to `set` every struct that is CONSTRUCTED inline in a returned
/// expression, so those structs are marked as escaping.
///
/// A `struct_init`, or a call/generic-call whose callee names a struct, records
/// that struct name (via [`excludeStructByName`]); an `if_expr` recurses into
/// both branches. Part of building the value-escape set in
/// [`scanReturnConstructions`]: a struct value that is built and then returned
/// escapes and cannot stay value-semantic.
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

/// Inserts a struct's base name into the escape `set`, owning a duplicate of
/// the key.
///
/// No-op for a name that is empty, is not a known struct, or is already
/// present. "Exclude" is from the value-struct point of view: being in this set
/// EXCLUDES the struct from value semantics. Allocation failure is swallowed
/// (best-effort; a missed entry only means a struct stays value-semantic).
fn excludeStructByName(self: *LlvmCompiler, set: *std.StringHashMap(void), name: []const u8) void {
    const base = getStructBaseName(name);
    if (base.len == 0 or !self.structs.contains(base) or set.contains(base)) return;
    const owned = self.allocator.dupe(u8, base) catch return;
    set.put(owned, {}) catch {};
}

/// Scans a statement list for returned inline struct constructions, adding each
/// to the escape `set`. The list-level driver over
/// [`scanStmtReturnConstructions`].
fn scanReturnConstructions(self: *LlvmCompiler, stmts: []const ast.Statement, set: *std.StringHashMap(void)) void {
    for (stmts) |*st| scanStmtReturnConstructions(self, st, set);
}
/// Walks one statement, recording structs constructed-and-returned into `set`.
///
/// For a `return` it only inspects the value when it is NOT a borrow (a
/// borrow-returned struct does not escape), then calls
/// [`returnedConstructedStruct`]. Recurses through blocks, `if` branches, loop
/// bodies, and switch cases. Mutually recursive with [`scanReturnConstructions`].
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

/// Computes, once, the set of struct names that must fall back to REFERENCE
/// semantics because they escape, and caches it on `self.value_escape_set`.
///
/// A plain `struct` is value-semantic (copied, destructed by value) by default;
/// this analysis finds the ones for which that is unsafe or wrong and excludes
/// them. A struct is excluded if any of the following hold:
///   * it is CONSTRUCTED and RETURNED anywhere ([`scanReturnConstructions`]),
///     or it is the declared return type of a function that has a non-borrow
///     return and is not itself marked a reference;
///   * it has trait `impls` (trait objects need a stable address), or carries
///     the `@serializable` attribute;
///   * it has a field whose type is a non-scalar, non-`string`, non-reference
///     type (an owning field forces reference semantics);
///   * it is used as a generic ARGUMENT substituted into another struct's
///     field, or appears inside a tuple / error-union / optional in the type
///     store ([`excludeIfStruct`]).
/// The `addName` local closure is the in-function equivalent of
/// [`excludeStructByName`]. The result is consulted by [`isValueStructName`];
/// computing it lazily there is why this returns void and stores into `self`.
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
    for (self.functions.items) |f| {
        scanReturnConstructions(self, f.body.statements, &set);
        const rbase = getStructBaseName(f.return_type);
        if (self.structs.get(rbase)) |rsd| {
            if (!rsd.is_reference and blockHasNonBorrowReturn(self, f.body.statements))
                addName(self, &set, f.return_type);
        }
    }
    var it = self.structs.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.impls.len > 0) addName(self, &set, e.key_ptr.*);
        for (e.value_ptr.attributes) |a| if (a == .serializable) {
            addName(self, &set, e.key_ptr.*);
            break;
        };
        for (e.value_ptr.fields) |fld| {
            const fs = self.typeRefToString(fld.type_name) catch continue;
            const fbase = getStructBaseName(fs);
            if (self.structs.get(fbase)) |fsd| {
                if (!fsd.is_reference) continue;
            }
            if (!isScalarFieldTypeName(fs) and !std.mem.eql(u8, fs, "string")) addName(self, &set, e.key_ptr.*);
        }
    }
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

/// Renders a `TypeId` to its name and, if it names a known struct, excludes it
/// from value semantics by inserting it into `set`.
///
/// The type-store-side counterpart of [`excludeStructByName`], used by
/// [`computeValueEscapeSet`] when walking tuple / error-union / optional
/// members. No-op for non-struct, empty, or already-present names; owns the
/// duplicated key and swallows allocation failure.
fn excludeIfStruct(self: *LlvmCompiler, store: *const typesys.TypeStore, set: *std.StringHashMap(void), id: typesys.TypeId) void {
    const rendered = sema_shadow.renderLegacy(self.allocator, store, id) catch return;
    const base = getStructBaseName(rendered);
    if (base.len == 0 or !self.structs.contains(base) or set.contains(base)) return;
    const owned = self.allocator.dupe(u8, base) catch return;
    set.put(owned, {}) catch {};
}

/// The definitive test: is this struct compiled with VALUE semantics (copied
/// and destructed by value, not reference-counted)?
///
/// Returns false unless value structs are enabled at all
/// (`arc_mod.value_structs_enabled`). Then it excludes, in order: a struct
/// whose name collides across modules ([`isCollidingStruct`], which needs a
/// stable identity), one explicitly declared a reference (`is_reference`), and
/// any struct in the lazily-computed escape set ([`computeValueEscapeSet`],
/// triggered here on first use). If it survives all that, it is a value struct
/// when `value_structs_all` is set, or when it is listed in the opt-in
/// `value_type_set`; otherwise false. This is the gate every copy/destruct site
/// in codegen consults to decide value vs reference handling.
pub fn isValueStructName(self: *LlvmCompiler, name: []const u8) bool {
    if (!arc_mod.value_structs_enabled) return false;
    const base = getStructBaseName(name);
    const sd = self.structs.get(base) orelse return false;
    if (self.isCollidingStruct(sd.name)) return false;
    if (sd.is_reference) return false;
    if (self.value_escape_set == null) computeValueEscapeSet(self);
    if (self.value_escape_set.?.contains(base)) return false;
    if (arc_mod.value_structs_all) return true;
    if (arc_mod.value_type_set) |set| return set.contains(base);
    return false;
}

/// True if a struct is a PURE value struct: value-semantic AND transitively made
/// only of scalars, strings, and other pure value structs, with no owned
/// container/heap field anywhere.
///
/// "Pure" is stronger than [`isValueStructName`]: a pure value struct has no
/// field that needs a destructor, so it can be copied with a plain bit-copy and
/// dropped with no cleanup. Seeds a `visited` set and defers to
/// [`isPureValueStructRec`]; contrast [`valueStructHasOwnedFields`], which is
/// the negation-flavoured "does it have any owned field".
pub fn isPureValueStructName(self: *LlvmCompiler, name: []const u8) bool {
    if (!arc_mod.value_structs_enabled) return false;
    var visited = std.StringHashMap(void).init(self.allocator);
    defer visited.deinit();
    return isPureValueStructRec(self, name, &visited);
}
/// Recursive core of [`isPureValueStructName`], with a `visited` set guarding
/// against cyclic struct references.
///
/// Returns false on an empty name, a re-visited name (a cycle means it is not a
/// trivially-copyable leaf), a missing declaration, a reference struct, or a
/// name-colliding struct. Each field must be `string`, a scalar
/// ([`isScalarFieldTypeName`]), or a non-reference struct that is itself pure by
/// recursion; any other field type makes the struct impure.
fn isPureValueStructRec(self: *LlvmCompiler, name: []const u8, visited: *std.StringHashMap(void)) bool {
    const base = getStructBaseName(name);
    if (base.len == 0 or visited.contains(base)) return false;
    visited.put(base, {}) catch return false;
    const sd = self.structs.get(base) orelse return false;
    if (sd.is_reference) return false;
    if (self.isCollidingStruct(sd.name)) return false;
    for (sd.fields) |fld| {
        const fts = self.typeRefToString(fld.type_name) catch return false;
        if (std.mem.eql(u8, fts, "string")) continue;
        if (isScalarFieldTypeName(fts)) continue;
        const fbase = getStructBaseName(fts);
        if (self.structs.get(fbase)) |fsd| {
            if (!fsd.is_reference and isPureValueStructRec(self, fbase, visited)) continue;
        }
        return false;
    }
    return true;
}

/// True if a value struct has at least one field that owns heap memory
/// (directly or through a nested value struct), so its copy/destruct must run
/// ARC on that field.
///
/// This is what tells codegen whether a value struct needs a real destructor
/// and deep-retain-on-copy versus a bit-copy. Seeds `visited` and defers to
/// [`valueStructHasOwnedFieldsRec`]. Roughly the complement of
/// [`isPureValueStructName`], but phrased over the ownership predicate rather
/// than the scalar/string whitelist.
pub fn valueStructHasOwnedFields(self: *LlvmCompiler, name: []const u8) bool {
    var visited = std.StringHashMap(void).init(self.allocator);
    defer visited.deinit();
    return valueStructHasOwnedFieldsRec(self, name, &visited);
}
/// Recursive core of [`valueStructHasOwnedFields`], cycle-guarded by `visited`.
///
/// Returns true as soon as any field is an owned declared type
/// ([`isOwnedDeclaredType`]), or is a nested value struct that itself has owned
/// fields. Fields whose type string fails to render are skipped
/// conservatively. Empty/re-visited/undeclared names return false.
fn valueStructHasOwnedFieldsRec(self: *LlvmCompiler, name: []const u8, visited: *std.StringHashMap(void)) bool {
    const base = getStructBaseName(name);
    if (base.len == 0 or visited.contains(base)) return false;
    visited.put(base, {}) catch {};
    const sd = self.structs.get(base) orelse return false;
    for (sd.fields) |fld| {
        const fts = self.typeRefToString(fld.type_name) catch continue;
        if (self.isOwnedDeclaredType(fld.type_name, fts)) return true;
        const fbase = getStructBaseName(fts);
        if (fbase.len != 0 and self.isValueStructName(fbase)) {
            if (valueStructHasOwnedFieldsRec(self, fbase, visited)) return true;
        }
    }
    return false;
}

/// [`isValueStructName`] keyed by a `TypeId` instead of a string.
///
/// False unless value structs are enabled and the id actually resolves to a
/// `.struct_` in the store; then it renders the id to its name and asks
/// [`isValueStructName`]. This is the form [`isOwnedTypeId`] calls to decide
/// that a value struct is NOT owned.
pub fn isValueStructTid(self: *LlvmCompiler, t: typesys.TypeId) bool {
    if (!arc_mod.value_structs_enabled) return false;
    const st = self.type_store orelse return false;
    if (st.get(t) != .struct_) return false;
    const nm = sema_shadow.renderLegacy(self.allocator, st, t) catch return false;
    return self.isValueStructName(nm);
}

/// The AUTHORITATIVE, typed ownership decision for a `TypeId`: does a value of
/// this type own a heap allocation?
///
/// This is the keystone the whole ARC apparatus rests on, so it is deliberately
/// strict. An `.unresolved` id is a COMPILER BUG (an ownership action was taken
/// on a value sema never typed): it prints a diagnostic and `exit(70)` rather
/// than guess, because either answer risks memory corruption. A `.type_param`
/// is resolved through the current instantiation's overlay if possible, else
/// treated as not owned. A value optional is owned (`true`) since it may box; a
/// value struct is explicitly NOT owned ([`isValueStructTid`]); everything else
/// defers to `store.isOwned`. When shadow reporting is on it first records a
/// typed-vs-string diff via [`tdShadowDiff`]. Contrast [`ownedByName`], the
/// string fallback used only when no id is available.
pub fn isOwnedTypeId(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    if (sema_shadow.report_enabled) tdShadowDiff(self, t);
    return switch (st.get(t)) {

        .unresolved => {
            std.debug.print(
                "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ownership decision asked of an UNTYPED value\x1b[0m\n" ++
                "  isOwnedTypeId reached an `.unresolved` TypeId. A caller took an ownership action on a\n" ++
                "  value sema never typed, a COMPILER bug (F2-5), not user code. Every ownership vehicle\n" ++
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

        .struct_ => if (self.isValueStructTid(t)) false else st.isOwned(t),

        else => st.isOwned(t),
    };
}

/// Ownership of a named LOCAL variable, preferring its resolved `TypeId` and
/// falling back to its declared type string.
///
/// If the local has a concrete type id in `current_local_type_ids` (neither
/// unresolved nor a bare type param), defers to [`isOwnedTypeId`]; when there is
/// no type store it trusts the id directly. Otherwise falls back to
/// [`ownedByName`] on the declared `type_string`. This is the identifier-case
/// fallback used from [`isOwnedExpr`].
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

/// Returns a CONCRETE `TypeId` for an expression, or null if only an
/// unresolved/type-param type is available.
///
/// "Concrete" excludes `.unresolved` and `.type_param` via the local `concrete`
/// predicate. It tries, in order: the per-instantiation type
/// (`typeOfInst` under the current instantiation), then the plain `typeOf`, then
/// for an identifier its declared local type id. This is the workhorse behind
/// all the `isXExpr` type predicates below and [`resolveExpressionTypeName`];
/// they need a concrete id so a generic body does not report an erased param.
pub fn typeOfExprConcrete(self: *LlvmCompiler, expr_ptr: *const ast.Expression) ?typesys.TypeId {
    const ir = self.typed_ir orelse return null;
    const st_opt = self.type_store;
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

/// True if an expression's concrete type is `string`. Uses
/// [`typeOfExprConcrete`]; false when unresolved or when there is no type store.
pub fn isStringExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .string;
        }
    }
    return false;
}

/// True if an expression's concrete type is a floating-point primitive (`.prim`
/// with `.float` kind). Used to pick FP paths in codegen. See
/// [`typeOfExprConcrete`].
pub fn isFloatExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .float;
        }
    }
    return false;
}

/// True if an expression's concrete type is `bool` (`.prim` with `.bool` kind).
/// See [`typeOfExprConcrete`].
pub fn isBoolExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .bool;
        }
    }
    return false;
}

/// True if an expression's concrete type is `void` (`.prim` with `.void_`
/// kind). See [`typeOfExprConcrete`].
pub fn isVoidExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            const info = st.get(tid);
            return info == .prim and info.prim.kind == .void_;
        }
    }
    return false;
}

/// True if an expression's concrete type is the dynamic `any` type (`.any_`).
/// See [`typeOfExprConcrete`].
pub fn isAnyExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .any_;
        }
    }
    return false;
}

/// True if an expression's concrete type is `decimal` (decimal128). See
/// [`typeOfExprConcrete`].
pub fn isDecimalExpr(self: *LlvmCompiler, expr_ptr: *const ast.Expression) bool {
    if (self.type_store) |st| {
        if (typeOfExprConcrete(self, expr_ptr)) |tid| {
            return st.get(tid) == .decimal;
        }
    }
    return false;
}

/// If an expression is a tuple whose element `idx` is a TRAIT type, returns that
/// trait's name; otherwise null.
///
/// Used where codegen must know a tuple element is a trait object (fat pointer)
/// to handle it correctly. Requires the element type to be `.trait_` in the
/// store AND for the rendered name to be a known trait; returns null on any miss
/// (no store, unresolved, out-of-range index, non-trait element). Caller owns
/// the rendered name string.
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

/// Ownership of the OK arm of an error-union expression, by type id, with a
/// string fallback.
///
/// When the expression resolves to a concrete `.error_union` type, defers to
/// [`isOwnedTypeId`] on its `ok` arm; otherwise falls back to [`ownedByName`] on
/// the caller-supplied `ok_string` (the codegen spelling of the ok type). This
/// lets ARC on a `try`/`catch` destructure release the ok payload correctly.
/// Mirrors [`isOwnedErrUnionErr`].
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

/// Ownership of the ERR arm of an error-union expression, by type id, with a
/// string fallback on `err_string`. The err-arm mirror of [`isOwnedErrUnionOk`].
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

/// Ownership of the element type of a `Storage<T>` expression, by type id, with
/// a string fallback.
///
/// When `obj_ptr` resolves to a concrete `.storage` type, defers to
/// [`isOwnedTypeId`] on its element; otherwise falls back to [`ownedByName`] on
/// `elem_string`. Storage is Nova's backing container primitive; this decides
/// whether removing/overwriting an element must release it. See
/// [`isOwnedStorageElemByName`] for the name-only variant.
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

/// Reverse lookup: finds the `TypeId` whose rendered name equals `name`, for
/// compound types (error unions, tuples, storages, structs).
///
/// Builds a name→id index lazily on first call by scanning the whole live store
/// and rendering every compound type once, caching it on
/// `self.rendered_name_ids`. This exists so codegen can go from a codegen
/// name-string (which it often has when the typed IR did not carry an id) back
/// to a store id to make a precise ownership decision. Only the four compound
/// kinds are indexed; primitives and simple names are handled by [`tidForName`].
/// Returns null if no compound type renders to that exact name.
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

/// Ownership of a storage element when only the element's NAME is known (no
/// expression to type).
///
/// Synthesises the container name `Storage<elem>`, looks it up via
/// [`typeIdForRenderedName`], and if it resolves to a `.storage` type asks
/// [`isOwnedTypeId`] on its element; otherwise falls back to [`ownedByName`] on
/// `elem_string`. The name-only counterpart of [`isOwnedStorageElem`].
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

/// Ownership of one arm of an error union identified by the union's NAME.
///
/// Looks `union_name` up via [`typeIdForRenderedName`]; if it is an
/// `.error_union`, asks [`isOwnedTypeId`] on the `err` arm when `is_err` else
/// the `ok` arm. Falls back to [`ownedByName`] on `payload_string`. The
/// name-keyed counterpart of [`isOwnedErrUnionOk`]/[`isOwnedErrUnionErr`].
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

/// Ownership of tuple element `idx` identified by the tuple's NAME.
///
/// Looks `tuple_name` up via [`typeIdForRenderedName`]; if it is a `.tuple` and
/// `idx` is in range, asks [`isOwnedTypeId`] on that element. Falls back to
/// [`ownedByName`] on `elem_string`. Used when destructuring a tuple by its
/// codegen name.
pub fn isOwnedTupleElemByName(self: *LlvmCompiler, tuple_name: []const u8, idx: usize, elem_string: []const u8) bool {
    if (self.typeIdForRenderedName(tuple_name)) |tid| {
        if (self.type_store) |st| {
            const info = st.get(tid);
            if (info == .tuple and idx < info.tuple.len) return self.isOwnedTypeId(info.tuple[idx]);
        }
    }
    return self.ownedByName(elem_string);
}

/// Resolves a bare type NAME to a concrete `TypeId`, or null if it stays
/// unresolved/param.
///
/// Two strategies: first the rendered-name index ([`typeIdForRenderedName`]) if
/// that hit resolves ([`nameResolvable`]); otherwise it actually LOWERS the name
/// through a fresh [`lower.Lowerer`] over the live sema symbol table, accepting
/// the result only if resolvable. This is the string→id bridge [`ownedByName`]
/// uses to promote a name to the typed path before deciding ownership.
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

/// True if a `TypeId` is concretely resolvable for ownership purposes: not a
/// type param, not unresolved (recursing through optionals). Gate used by
/// [`tidForName`].
fn nameResolvable(store: *const typesys.TypeStore, t: typesys.TypeId) bool {
    return switch (store.get(t)) {
        .type_param, .unresolved => false,
        .optional => |inner| nameResolvable(store, inner),
        else => true,
    };
}

/// The LEGACY string-name ownership decision, used only when no `TypeId` is
/// available.
///
/// It tries hard to reach the typed path first: `any` is owned; a primitive
/// ([`isPrimitiveTypeName`]) is not owned (fast path, counted `irct_primitive`);
/// a name that [`tidForName`] can resolve defers to [`isOwnedTypeId`]
/// (`irct_resolved`). Only if all that fails does it decide from the string
/// itself (`irct_string_decided`): an UN-TYPEABLE placeholder
/// ([`arc_mod.isUntypeablePlaceholder`]) is a compiler bug and aborts with
/// `exit(70)` (freeing it would corrupt memory); a lone uppercase letter (an
/// erased type param like `T`) is treated as not owned; anything else defaults
/// to OWNED. That default-owned is the conservative choice for an unknown
/// user type: over-retaining leaks, whereas the opposite would double-free.
/// Increments the `irct_*` migration counters throughout. Prefer
/// [`isOwnedTypeId`] whenever an id is in hand.
pub fn ownedByName(self: *LlvmCompiler, name: []const u8) bool {
    sema_shadow.irct_live_calls += 1;
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
    if (arc_mod.isUntypeablePlaceholder(name)) {
        std.debug.print(
            "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m ARC ownership asked of an un-typeable value '{s}'\x1b[0m\n" ++
            "  sema failed to type a value that reached a retain/release. This is a COMPILER bug\n" ++
            "  (not user code): freeing it would corrupt memory. Please report.\n",
            .{name});
        std.process.exit(70);
    }
    if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return false;
    return true;
}

/// Ownership of a DECLARED type (an `ast.TypeRef` from a field/param/return
/// annotation), preferring to lower it to a typed decision.
///
/// Lowers `tr` through a fresh [`lower.Lowerer`] over the live sema table; if
/// the result is decided directly ([`decidedDirectly`], i.e. not an
/// enum/param/unresolved that needs more context), defers to [`isOwnedTypeId`].
/// Otherwise falls back to [`ownedByName`] on `string_fallback`. This is the
/// entry point [`valueStructHasOwnedFieldsRec`] uses per field.
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

/// Lowers an `ast.TypeRef` to a `TypeId`, returning null if it lowers to
/// `.unresolved`.
///
/// A thin wrapper over [`lower.Lowerer`] on the live sema store. Unlike
/// [`concreteTidForTypeRef`] it does NOT apply the instantiation overlay, so a
/// type param may come back as `.type_param`; it only filters out fully
/// unresolved results.
pub fn tidForTypeRef(self: *LlvmCompiler, tr: ast.TypeRef) ?typesys.TypeId {
    const sm = sema_shadow.live_sema orelse return null;
    var l = lower.Lowerer.init(self.allocator, &sm.store);
    defer l.deinit();
    l.symtab = &sm.tab;
    const t = l.lower(tr) catch return null;
    if (sm.store.get(t) == .unresolved) return null;
    return t;
}

/// Lowers an `ast.TypeRef` to a fully CONCRETE `TypeId`, resolving type params
/// through the current instantiation; null if it cannot be made concrete.
///
/// For a bare identifier that names a type parameter it takes a fast path:
/// [`paramLeafByName`] finds the param leaf and `tpResolve` substitutes it. For
/// everything else it lowers via [`tidForTypeRef`] and then rewrites the whole
/// type through [`substViaOverlay`] under the current instantiation. Either way
/// it rejects a result that is still `.unresolved` or `.type_param`. This is the
/// form used where codegen genuinely needs the concrete instantiated type, e.g.
/// to name a monomorphised method.
pub fn concreteTidForTypeRef(self: *LlvmCompiler, tr: ast.TypeRef) ?typesys.TypeId {
    const st = sema_shadow.live_store orelse return null;
    const ir = self.typed_ir orelse return null;
    const inst_opt = self.current_instantiation_id;

    if (tr == .ident) {
        if (inst_opt) |inst| {
            if (paramLeafByName(tr.ident, inst)) |leaf| {
                if (ir.tpResolve(leaf, inst)) |c| {
                    return switch (st.get(c)) {
                        .unresolved, .type_param => null,
                        else => c,
                    };
                }
            }
        }
    }
    var t = self.tidForTypeRef(tr) orelse return null;
    if (inst_opt) |inst| t = substViaOverlay(st, ir, t, inst);
    return switch (st.get(t)) {
        .unresolved, .type_param => null,
        else => t,
    };
}

/// Given a type-parameter NAME and an instantiation, returns the `.type_param`
/// leaf id (owner symbol + index) so the caller can resolve it through the
/// overlay.
///
/// The instantiation must be a `.struct_`. It first checks the instantiation's
/// own declaration for a param named `name` ([`paramIndexIn`]); failing that, if
/// the first struct arg is itself a struct it checks THAT struct's params (this
/// handles a param inherited from a wrapping generic). Interns and returns the
/// `type_param` id, or null if the name is not a parameter here. Consumed by
/// [`concreteTidForTypeRef`] and [`substMethodParams`].
fn paramLeafByName(name: []const u8, inst: typesys.TypeId) ?typesys.TypeId {
    const st = sema_shadow.live_store orelse return null;
    const sm = sema_shadow.live_sema orelse return null;
    if (st.get(inst) != .struct_) return null;
    const si = st.get(inst).struct_;
    if (paramIndexIn(sm, si.decl, name)) |idx| {
        return st.intern(.{ .type_param = .{ .owner = si.decl, .index = idx } }) catch null;
    }
    if (si.args.len > 0 and st.get(si.args[0]) == .struct_) {
        const rs = st.get(si.args[0]).struct_;
        if (paramIndexIn(sm, rs.decl, name)) |idx| {
            return st.intern(.{ .type_param = .{ .owner = rs.decl, .index = idx } }) catch null;
        }
    }
    return null;
}

/// Returns the index of a type parameter `name` in a declaration's
/// `type_params`, or null.
///
/// Works for both function and struct declarations (other symbol kinds have no
/// type params and return null). `sm` is the sema instance (taken `anytype` to
/// avoid the import cycle). The index is the position used to select the
/// matching argument from an instantiation's `args`. Helper for
/// [`paramLeafByName`].
fn paramIndexIn(sm: anytype, decl: typesys.SymbolId, name: []const u8) ?u32 {
    const sym = sm.tab.symbolAt(decl);
    const tps: []const []const u8 = switch (sym.decl) {
        .function => |f| f.type_params,
        .struct_ => |s| s.type_params,
        else => return null,
    };
    for (tps, 0..) |tp, i| if (std.mem.eql(u8, tp, name)) return @intCast(i);
    return null;
}

/// Rewrites a type, replacing every type parameter with its concrete
/// substitution from an instantiation overlay, and re-interning the result.
///
/// Recurses structurally through every compound kind (struct args, optional,
/// future, storage, array, error union, tuple, function params/ret), rebuilding
/// only the branches that actually changed (an unchanged subtree returns the
/// original id, avoiding needless interning). A `.type_param` resolves via
/// `ir.tpResolve(t, inst)`, falling back to itself if the overlay has no entry.
/// Fixed 16-wide scratch buffers cap arity; anything wider is left unchanged.
/// Interning failures degrade to the original id. This is the general
/// substitution engine behind [`concreteTidForTypeRef`].
fn substViaOverlay(st: *typesys.TypeStore, ir: *const sema_infer.TypedIr, t: typesys.TypeId, inst: typesys.TypeId) typesys.TypeId {
    return switch (st.get(t)) {
        .type_param => ir.tpResolve(t, inst) orelse t,
        .struct_ => |s| blk: {
            if (s.args.len == 0 or s.args.len > 16) break :blk t;
            var buf: [16]typesys.TypeId = undefined;
            var changed = false;
            for (s.args, 0..) |a, i| {
                buf[i] = substViaOverlay(st, ir, a, inst);
                if (buf[i] != a) changed = true;
            }
            if (!changed) break :blk t;
            break :blk st.intern(.{ .struct_ = .{ .decl = s.decl, .args = buf[0..s.args.len] } }) catch t;
        },
        .optional => |inner| blk: {
            const s2 = substViaOverlay(st, ir, inner, inst);
            break :blk if (s2 == inner) t else (st.intern(.{ .optional = s2 }) catch t);
        },
        .future => |inner| blk: {
            const s2 = substViaOverlay(st, ir, inner, inst);
            break :blk if (s2 == inner) t else (st.intern(.{ .future = s2 }) catch t);
        },
        .storage => |inner| blk: {
            const s2 = substViaOverlay(st, ir, inner, inst);
            break :blk if (s2 == inner) t else (st.intern(.{ .storage = s2 }) catch t);
        },
        .array => |arr| blk: {
            const s2 = substViaOverlay(st, ir, arr.elem, inst);
            break :blk if (s2 == arr.elem) t else (st.intern(.{ .array = .{ .elem = s2, .len = arr.len } }) catch t);
        },
        .error_union => |eu| blk: {
            const ok2 = substViaOverlay(st, ir, eu.ok, inst);
            const err2 = substViaOverlay(st, ir, eu.err, inst);
            break :blk if (ok2 == eu.ok and err2 == eu.err) t else (st.intern(.{ .error_union = .{ .ok = ok2, .err = err2 } }) catch t);
        },
        .tuple => |elems| blk: {
            if (elems.len == 0 or elems.len > 16) break :blk t;
            var buf: [16]typesys.TypeId = undefined;
            var changed = false;
            for (elems, 0..) |e, i| {
                buf[i] = substViaOverlay(st, ir, e, inst);
                if (buf[i] != e) changed = true;
            }
            if (!changed) break :blk t;
            break :blk st.intern(.{ .tuple = buf[0..elems.len] }) catch t;
        },
        .func => |ft| blk: {
            if (ft.params.len > 16) break :blk t;
            var buf: [16]typesys.TypeId = undefined;
            var changed = false;
            for (ft.params, 0..) |p, i| {
                buf[i] = substViaOverlay(st, ir, p, inst);
                if (buf[i] != p) changed = true;
            }
            const ret2 = substViaOverlay(st, ir, ft.ret, inst);
            if (!changed and ret2 == ft.ret) break :blk t;
            break :blk st.intern(.{ .func = .{ .params = buf[0..ft.params.len], .ret = ret2 } }) catch t;
        },
        else => t,
    };
}

/// True for an identifier byte (`[A-Za-z0-9_]`). Used by [`substMethodParams`]
/// to find identifier-token boundaries within a type string.
fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Substitutes type parameters INSIDE a type STRING, token by token, using the
/// current instantiation.
///
/// This is the string-level analogue of [`substViaOverlay`]: it scans
/// `type_str` for identifier tokens (respecting boundaries via [`isIdentByte`]),
/// and for each token that names a resolvable type parameter
/// ([`paramLeafByName`] + `tpResolve`) splices in the rendered concrete type.
/// Non-parameter tokens and punctuation pass through verbatim. If nothing was
/// replaced it returns the ORIGINAL `type_str` (no allocation); otherwise the
/// caller owns the rebuilt string. Used where codegen only has a type spelling,
/// not an id, but still needs the instantiated form.
pub fn substMethodParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {
    const inst = self.current_instantiation_id orelse return type_str;
    const ir = self.typed_ir orelse return type_str;
    const ls = sema_shadow.live_store orelse return type_str;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(self.allocator);
    var replaced = false;
    var j: usize = 0;
    while (j < type_str.len) {
        const at_start = j == 0 or !isIdentByte(type_str[j - 1]);
        if (at_start and (std.ascii.isAlphabetic(type_str[j]) or type_str[j] == '_')) {
            var e = j;
            while (e < type_str.len and isIdentByte(type_str[e])) e += 1;
            const tok = type_str[j..e];

            var sub: ?[]const u8 = null;
            if (paramLeafByName(tok, inst)) |leaf| {
                if (ir.tpResolve(leaf, inst)) |c| switch (ls.get(c)) {
                    .unresolved, .type_param => {},
                    else => sub = sema_shadow.renderLegacy(self.allocator, ls, c) catch null,
                };
            }

            if (sub) |s| {
                try out.appendSlice(self.allocator, s);
                replaced = true;
            } else {
                try out.appendSlice(self.allocator, tok);
            }
            j = e;
            continue;
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

/// True if a type's ownership can be decided WITHOUT more context: not an enum,
/// type param, or unresolved (recursing through optionals).
///
/// Enums are excluded because their ownership needs the rendered-fallback path
/// ([`isOwnedRenderedFallback`]); params/unresolved need an instantiation. Gate
/// used by [`isOwnedDeclaredType`] before it trusts the typed decision.
fn decidedDirectly(store: *const typesys.TypeStore, t: typesys.TypeId) bool {
    return switch (store.get(t)) {
        .enum_, .type_param, .unresolved => false,
        .optional => |inner| decidedDirectly(store, inner),
        else => true,
    };
}

/// Ownership of a type decided the LEGACY way: render it to a name, substitute
/// type params in the string, and ask the string ownership rule.
///
/// Renders `t` ([`sema_shadow.renderLegacy`]), runs `substTypeParams`, then
/// [`legacyStringOwnership`]. This is the "keystone" fallback [`tdShadowDiff`]
/// compares the typed answer against, and the path enums take (which
/// [`decidedDirectly`] deliberately routes here). Returns false if rendering or
/// substitution fails.
fn isOwnedRenderedFallback(self: *LlvmCompiler, t: typesys.TypeId) bool {
    const st = self.type_store.?;
    const rendered = sema_shadow.renderLegacy(self.allocator, st, t) catch return false;
    const subst = self.substTypeParams(rendered) catch return false;
    return self.legacyStringOwnership(subst);
}

/// Maps a bare struct name to its module-unique SCOPED name for a given source
/// file.
///
/// Nova lets same-named structs coexist across modules by giving each a
/// module-unique name; this resolves the visible `name` in `file` to that
/// unique spelling via the sema symbol table (`scopedNameFor`). Returns `name`
/// unchanged if there is no live sema or no scoped mapping. Takes `self` only
/// for call-site uniformity. Compare [`scopedTypeName`], the identical operation
/// used for non-struct type names.
pub fn scopedStructName(self: *LlvmCompiler, name: []const u8, file: []const u8) []const u8 {
    _ = self;
    if (sema_shadow.live_sema) |sm| {
        if (sm.tab.scopedNameFor(name, file)) |scoped| return scoped;
    }
    return name;
}

/// True if a struct name is shared by more than one module (a "colliding"
/// type).
///
/// Such a struct cannot be treated as value-semantic (its identity is not
/// stable across modules), which is why [`isValueStructName`] and
/// [`isPureValueStructRec`] exclude it. Reads `colliding_types` from the live
/// sema symbol table; false without live sema. Takes `self` only for call-site
/// uniformity.
pub fn isCollidingStruct(self: *LlvmCompiler, name: []const u8) bool {
    _ = self;
    if (sema_shadow.live_sema) |sm| return sm.tab.colliding_types.contains(name);
    return false;
}

/// Maps a bare TYPE name to its module-unique scoped name for a source file.
///
/// The type-name counterpart of [`scopedStructName`] (same `scopedNameFor`
/// lookup, same pass-through behaviour), used for non-struct type spellings.
pub fn scopedTypeName(self: *LlvmCompiler, bare: []const u8, file: []const u8) []const u8 {
    _ = self;
    if (sema_shadow.live_sema) |sm| {
        if (sm.tab.scopedNameFor(bare, file)) |scoped| return scoped;
    }
    return bare;
}

/// Renders a `TypeId` to its name, MEMOISED per id in `self.type_name_cache`.
///
/// [`sema_shadow.renderLegacy`] allocates a fresh string each call, and codegen
/// renders the same ids repeatedly, so this caches the result. The returned
/// slice is owned by the cache, NOT the caller: do not free it. Use this rather
/// than calling `renderLegacy` directly on any hot path.
pub fn cachedTypeName(self: *LlvmCompiler, st: *const typesys.TypeStore, tid: typesys.TypeId) anyerror![]const u8 {
    if (self.type_name_cache.get(tid)) |cached| return cached;
    const rendered = try sema_shadow.renderLegacy(self.allocator, st, tid);
    try self.type_name_cache.put(self.allocator, tid, rendered);
    return rendered;
}

/// Resolves the codegen NAME of an expression's type, preferring the most
/// concrete spelling available.
///
/// When the typed IR has no usable type it recovers what it can from the AST: a
/// `struct_init` naming an enum variant yields the enum name
/// ([`findEnumByVariant`]); a bare identifier yields its declared local type
/// string; else null. When a type IS available it prefers the CONCRETE
/// per-instantiation id ([`typeOfExprConcrete`]) over the plain one, so a
/// generic body reports the instantiated name. The large middle block runs only
/// under `sema_shadow.tid_census`: it is pure instrumentation comparing the
/// string-rendered name against the concrete-id name and tallying disagreements
/// by expression kind (`census_*` counters); it does not affect the returned
/// value. Caller owns the returned string.
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

        // Synthesised expressions (e.g. a `...from` mapper spread's generated
        // nested field accesses) are not in the typed IR, which is keyed by
        // pointer. Resolve such a field access structurally: the object's struct
        // type, then the named field's declared type. Deliberately narrow: only
        // when the field's own type is another known struct (the nesting/
        // flattening intermediates the spread needs). For any/generic/primitive
        // fields this returns null exactly as before, so no other codegen path
        // changes behaviour.
        if (expr_ptr.kind == .field_access) {
            const fa = expr_ptr.kind.field_access;
            if (try self.resolveExpressionTypeName(fa.object)) |obj_ty| {
                if (self.structs.get(obj_ty)) |os| {
                    for (os.fields) |f| {
                        if (std.mem.eql(u8, f.name, fa.field)) {
                            const ft = switch (f.type_name) {
                                .ident => |n| n,
                                else => return null,
                            };
                            if (self.structs.contains(ft)) return ft;
                            return null;
                        }
                    }
                }
            }
        }

        // Synthesised constructor / method calls (e.g. the `querySql` tagged-template
        // desugar's `db.Params().a(...)` chain) are not in the typed IR either.
        // Resolve structurally, narrowly: a call whose callee names a struct is a
        // constructor (-> that struct); a `recv.method(...)` whose receiver resolves
        // to a struct takes the method's declared return type, but only when that
        // return type is itself a known struct (mirrors the field_access rule above).
        if (expr_ptr.kind == .call) {
            const c = expr_ptr.kind.call;
            switch (c.callee.kind) {
                .ident => |n| if (self.structs.contains(n)) return n,
                .field_access => |cfa| {
                    if (self.structs.contains(cfa.field)) return cfa.field;
                    if (try self.resolveExpressionTypeName(cfa.object)) |recv_ty| {
                        const mangled = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ recv_ty, cfa.field });
                        defer self.allocator.free(mangled);
                        for (self.functions.items) |f| {
                            if (std.mem.eql(u8, f.name, mangled)) {
                                if (self.structs.contains(f.return_type)) return f.return_type;
                                return null;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }
    const t = t_opt.?;

    if (sema_shadow.tid_census) {
        const s_name = try self.substTypeParams(try sema_shadow.renderLegacy(self.allocator, st, t));
        if (typeOfExprConcrete(self, expr_ptr)) |ctid| {
            const t_name = self.substTypeParams(sema_shadow.renderLegacy(self.allocator, st, ctid) catch "") catch "";
            if (!std.mem.eql(u8, s_name, t_name)) {
                sema_shadow.census_disagree += 1;
                switch (expr_ptr.kind) {
                    .ident => sema_shadow.census_dis_ident += 1,
                    .index => sema_shadow.census_dis_index += 1,
                    .call => sema_shadow.census_dis_call += 1,
                    .generic_call => sema_shadow.census_dis_gcall += 1,
                    .field_access => sema_shadow.census_dis_field += 1,
                    .binary => sema_shadow.census_dis_binary += 1,
                    else => sema_shadow.census_dis_other += 1,
                }
                const sl = @min(s_name.len, sema_shadow.census_dis_last_str.len);
                @memcpy(sema_shadow.census_dis_last_str[0..sl], s_name[0..sl]);
                sema_shadow.census_dis_last_str_len = sl;
                const tl = @min(t_name.len, sema_shadow.census_dis_last_tid.len);
                @memcpy(sema_shadow.census_dis_last_tid[0..tl], t_name[0..tl]);
                sema_shadow.census_dis_last_tid_len = tl;
            }
        } else {
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
    }

    if (typeOfExprConcrete(self, expr_ptr)) |ctid| {
        return try sema_shadow.renderLegacy(self.allocator, st, ctid);
    }
    return try sema_shadow.renderLegacy(self.allocator, st, t);
}

/// Renders a `TypeId` to its name and substitutes type params through the
/// current instantiation, giving the fully instantiated symbol spelling. Caller
/// owns the result.
pub fn symbolName(self: *LlvmCompiler, tid: typesys.TypeId) anyerror![]const u8 {
    const st = self.type_store.?;
    return try self.substTypeParams(try sema_shadow.renderLegacy(self.allocator, st, tid));
}

/// Resolves an unqualified callee name to the actual emitted FUNCTION symbol,
/// trying each naming scope in priority order.
///
/// Nova method/free-function calls are written unqualified but the emitted
/// symbol may be mangled or prefixed. This tries, and returns the first that
/// [`hasFunction`] confirms exists: (1) the bare name as-is; (2) the
/// monomorphised method symbol under the current instantiation
/// ([`methodSymbol`], its scratch buffer freed on miss); (3)
/// `current_struct_name ++ "_" ++ callee`; (4) `current_module_prefix ++ "_" ++
/// callee`. If none match it returns the original name unchanged (and, under
/// `trace_resolution`, bumps `scan_unresolved`). The order matters: a local/free
/// function shadows a method, which shadows a module-level function.
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

/// Alias for the std testing namespace used by the unit tests below.
const testing = std.testing;

// A plain, non-generic name has no punctuation to encode, so it round-trips
// through [`mangleTypeName`] byte-for-byte.
test "mangleTypeName: a non-generic name is unchanged" {
    const got = try mangleTypeName(testing.allocator, "Foo");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Foo", got);
}

// A single generic argument: the `<`/`>` become one `_` separator each,
// yielding `List_string`.
test "mangleTypeName: List<string> -> List_string (the G3 spelling 4b inherits)" {
    const got = try mangleTypeName(testing.allocator, "List<string>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("List_string", got);
}

// The comma AND the space after it are both separator characters, but adjacent
// separators coalesce, so `Map<string, int>` mangles to `Map_string_int` and
// not `Map_string__int`.
test "mangleTypeName: two args, and the space after the comma does not double up" {

    const got = try mangleTypeName(testing.allocator, "Map<string, int>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Map_string_int", got);
}

// Nested generics stack closing brackets (`>>`), but a run of separators still
// coalesces to one `_`, so `List<List<int>>` becomes `List_List_int`.
test "mangleTypeName: a nested arg keeps ONE separator per bracket run" {
    const got = try mangleTypeName(testing.allocator, "List<List<int>>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("List_List_int", got);
}

// The collision-freedom guarantee: two different instantiations of the same
// generic must mangle to different symbols, or their emitted functions would
// clash at link time.
test "mangleTypeName: List<int> and List<string> DO NOT collide" {

    const a = try mangleTypeName(testing.allocator, "List<int>");
    defer testing.allocator.free(a);
    const b = try mangleTypeName(testing.allocator, "List<string>");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

// Wiring guard: forces a reference to the `core` and `types` LLVM aliases so
// the test build genuinely links the LLVM bindings. It asserts nothing about
// behaviour; its value is failing to COMPILE if the LLVM import is not
// reachable from the test module.
test "the test module can SEE llvm, the wiring, not a lucky absence" {

    _ = core;
    _ = types;
    try testing.expect(true);
}
