//! ARC (automatic reference counting) code generation.
//!
//! Kyte has no garbage collector. Every heap object carries an 8-byte header
//! (refcount at offset -8, byte length at offset -4), and the compiler emits
//! `kyte_retain`/`kyte_release` calls so that objects are freed exactly when
//! their last reference goes away. This file is the part of codegen that
//! decides WHERE those calls go and, crucially, MANUFACTURES the destructor
//! functions that `kyte_release` invokes once a refcount hits zero. It is a
//! companion to `expressions.zig`/`statements.zig` (which call in here at
//! binding, return, and scope-exit points) and sits directly on top of the
//! LLVM C API via [`core`].
//!
//! ## The two questions this file answers
//!
//! 1. **Disposition** ([`acquisitionDisposition`], [`Disposition`]): when an
//!    expression's value flows into a new home (a `let`, a container slot, a
//!    struct field), does the destination TAKE ownership of an existing object
//!    (so we must `kyte_retain` it, because the source still names it too) or
//!    CONSUME a fresh temporary (so we just move it, no retain)? Naming an
//!    existing owner (`x`, `obj.field`, `arr[i]`) borrows; a constructor call
//!    or literal produces a fresh owned value. The authoritative answer comes
//!    from the typed-IR ownership pass; the `principled*` helpers here are the
//!    fallback and the shadow-diff cross-check.
//!
//! 2. **Destruction** (the `getOrCreate*Destructor*` family): given a type,
//!    synthesise (once, memoised by mangled symbol name) an LLVM function
//!    `__destruct_<mangled>` that releases everything the object transitively
//!    owns. Each type SHAPE gets its own layout-aware walker: plain structs
//!    release owned fields at their byte offsets and recurse into inline
//!    value-struct fields; tagged enums branch on the tag word and release the
//!    active variant's payload slots; tuples and error-unions release owned
//!    elements/arms; `Storage<T>` loops over its element slots; trait objects
//!    dispatch through the vtable (slot 0 is the concrete destructor); closures
//!    call the captured environment's cleanup then free the box.
//!
//! ## Two parallel destructor engines, kept in agreement
//!
//! Destructors can be built from a TypeId (`*ByTypeId`, driven by the typed-IR
//! [`typesys.TypeStore`]) or from a legacy type-NAME string (the plain
//! `getOrCreate*Destructor` variants). The string path is the historical one;
//! the TypeId path is the accurate one. [`getOrCreateDestructorPreferId`] uses
//! the TypeId whenever its mangled symbol matches the string's, and the
//! `diff*` helpers, active only under `sema_shadow.report_enabled`, count how
//! often the two engines agree so the string path can eventually be retired.
//!
//! ## Value structs vs reference types
//!
//! A `struct` is value-semantic: its bytes live inline in its owner, so it is
//! never refcounted itself, but a copy must deep-retain any owned FIELDS it
//! holds and a drop must release them. That is why copies (see
//! [`buildTupleDeepCopy`]) call `retainValueStructOwnedFields` and drops (see
//! [`dropValueStruct`], [`releaseLocalByName`]) call the value-struct
//! destructor directly rather than `kyte_release`.
//!
//! ## Optimisation and self-verification passes (module-level, opt-in globals)
//!
//! After the module is built, three whole-module passes run over raw LLVM IR:
//! [`elideBorrowedArc`] removes retain/release pairs on values that never
//! escape (redundant and borrow-only), [`arcCensusBefore`]/[`arcCensusAfter`]
//! measure how much ARC traffic exists and how much MORE could be elided, and
//! [`verifyArcBalance`] is a fail-closed self-check that every provably
//! non-escaping owned slot has acquires == releases (an imbalance is a leak or
//! double-free the compiler itself introduced). Each is gated by a global flag
//! wired to an env var, so they cost nothing unless asked for.
//!
//! ## Fail-closed on un-typeable values
//!
//! If a value reaches retain/release with no concrete type ([`unresolvedDtorField`],
//! the placeholder branch of [`legacyStringOwnership`]), this file aborts the
//! compile with a "please report" message rather than emitting a free of an
//! object whose layout is unknown: guessing would corrupt memory, so a compiler
//! bug is surfaced loudly instead of silently miscompiled.

/// The Zig standard library, used here for slices, formatting, hash maps, and
/// `std.process.exit` on the fail-closed compiler-bug paths.
const std = @import("std");
/// Kyte's AST. Disposition analysis reads [`ast.Expression`]/[`ast.ExprKind`]
/// and the destructor builders read struct/enum declarations and [`ast.TypeRef`].
const ast = @import("../../frontend/ast.zig");
/// The LLVM Zig bindings namespace; [`types`] and [`core`] are pulled out of it.
const llvm = @import("llvm");
/// LLVM opaque handle types (`LLVMValueRef`, `LLVMTypeRef`, predicates, ...).
const types = llvm.types;
/// The LLVM C API (`LLVMBuild*`, `LLVMAddFunction`, use/def iteration). Every
/// destructor body and elision pass is written against these calls.
const core = llvm.core;

/// Shadow-diff instrumentation: counters and the legacy type-name renderer
/// (`renderLegacy`). Under `report_enabled` the `diff*` helpers here tally
/// where the TypeId and string ownership engines agree or diverge.
const sema_shadow = @import("../../frontend/sema/shadow.zig");
/// The typed-IR type system: [`typesys.TypeId`] handles and the
/// [`typesys.TypeStore`] that the accurate `*ByTypeId` destructor path reads.
const typesys = @import("../../frontend/types.zig");
/// Lowers an [`ast.TypeRef`] to a [`typesys.TypeId`] under a type-parameter
/// scope; used to resolve a struct field's concrete type inside a generic
/// instantiation's destructor.
const lower = @import("../../frontend/sema/lower.zig");
/// Substitutes a generic struct's type arguments into a lowered field TypeId,
/// turning `T` into the concrete argument for this instantiation.
const subst = @import("../../frontend/sema/subst.zig");
/// The codegen context (`self`): the LLVM module/builder, symbol tables
/// (`structs`/`enums`/`unions`/`traits`), the type store, per-function ARC
/// state, and the many helper methods these free functions call as `self.*`.
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
/// Strips generic arguments from a type name (`List<int>` -> `List`), giving
/// the base name used to look a declaration up in `self.structs`/`self.enums`.
const getStructBaseName = @import("types.zig").getStructBaseName;
/// True for built-in scalar types (`int`, `bool`, `float`, ...) which are never
/// heap-allocated and therefore never owned.
const isPrimitiveTypeName = @import("types.zig").isPrimitiveTypeName;
/// Turns a type name into a symbol-safe mangled form so a destructor gets one
/// stable, collision-free `__destruct_<mangled>` name.
const mangleTypeName = @import("types.zig").mangleTypeName;
/// True if the name is a boxed value-optional (`T?` stored as a heap box); such
/// a box owns its payload and needs releasing even though `T` may be a value.
const valueOptionalName = @import("types.zig").valueOptionalName;

/// True if the named enum carries payloads (a variant has a `type_name` or
/// `fields`), i.e. it is a tagged union rather than a plain C-style enum.
///
/// Only tagged unions need a destructor: a plain enum is just an integer tag
/// with nothing to release. Used as the gate in [`getOrCreateEnumDestructor`]
/// and by [`legacyStringOwnership`] to decide whether an enum value is owned.
pub fn enumIsTaggedUnion(self: *LlvmCompiler, enum_name: []const u8) bool {
    const enum_decl = self.enums.get(enum_name) orelse return false;
    for (enum_decl.variants) |v| {
        if (v.type_name != null or v.fields != null) return true;
    }
    return false;
}


/// Aborts the compile because a struct field never lowered to a concrete
/// TypeId while building that struct's destructor.
///
/// This is fail-closed by design: a field with no known type has no known
/// layout, so we cannot safely decide whether or how to free it. Emitting a
/// destructor anyway could corrupt memory, so we exit with code 70 and a
/// "please report" message instead. Reached only from
/// [`getOrCreateStructDestructorByTypeId`] when `lower`/`subst` fail on a field
/// that should have resolved under the struct's own type arguments; it signals
/// a compiler (typed-IR) bug, not user error.
fn unresolvedDtorField(struct_name: []const u8, field_name: []const u8) noreturn {
    std.debug.print(
        "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m struct '{s}' field '{s}' has no concrete TypeId in destructor codegen\x1b[0m\n" ++
        "  the field did not lower under the struct's own type arguments. This is a COMPILER bug\n" ++
        "  (typed-IR accuracy), not user code. Please report.\n",
        .{ struct_name, field_name });
    std.process.exit(70);
}

/// Decides, from a type NAME alone, whether a value of that type is a
/// heap-allocated reference the ARC machinery owns (true) or a plain
/// non-refcounted value (false).
///
/// This is the legacy, string-based ownership oracle (the TypeId engine is the
/// accurate one). The rules, in order: a single uppercase letter that names no
/// known declaration is a generic type PARAMETER and treated as not-owned;
/// `any` is always owned (a boxed dynamic value); primitives are never owned;
/// an enum is owned only if it is a tagged union (see [`enumIsTaggedUnion`]);
/// anything left over is assumed owned. If the name is an un-typeable
/// placeholder (see [`isUntypeablePlaceholder`]) it aborts the compile with
/// code 70, for the same fail-closed reason as [`unresolvedDtorField`]. The
/// leading `sema_shadow` bump records how often this string path is exercised.
pub fn legacyStringOwnership(self: *LlvmCompiler, type_name: []const u8) bool {
    if (sema_shadow.report_enabled) { sema_shadow.a2_irct_calls += 1; if (std.mem.indexOfAny(u8, type_name, "<(") != null) sema_shadow.a2_irct_composite += 1; }
    const base = getStructBaseName(type_name);
    if (type_name.len == 1 and type_name[0] >= 'A' and type_name[0] <= 'Z') {

        if (!self.structs.contains(type_name) and !self.enums.contains(type_name) and !self.unions.contains(type_name) and !self.traits.contains(type_name)) {
            return false;
        }
    }
    if (std.mem.eql(u8, type_name, "any")) return true;
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
            "  (not user code): freeing it would corrupt memory. F5 stage 2, please report.\n",
            .{type_name});
        std.process.exit(70);
    }

    return true;
}

/// True if the name is one of the sentinel strings that mean "sema could not
/// give this value a real type" (empty, `unresolved`, `<unresolved>`,
/// `<tuple>`, `<array>`, `<fn>`).
///
/// Matches the WHOLE string only, so a real composite type that merely
/// CONTAINS one of these (for example a function type printed as
/// `(<unresolved>, i32) -> i32`) is not misclassified as un-typeable. Used by
/// [`legacyStringOwnership`] to trip the fail-closed abort. See the test at the
/// bottom of this file for the exact accept/reject set.
pub fn isUntypeablePlaceholder(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "unresolved") or
        std.mem.eql(u8, name, "<unresolved>") or
        std.mem.eql(u8, name, "<tuple>") or
        std.mem.eql(u8, name, "<array>") or
        std.mem.eql(u8, name, "<fn>");
}

/// Compiles a call argument expression, unboxing a value-optional result when
/// the callee expects the raw payload rather than the box.
///
/// `suppress_valopt_unbox` is a context flag some callers set to keep the box
/// intact; it is saved around [`compileExpression`] and restored, because
/// compiling the argument may itself toggle it. If the expression yields a
/// value-optional box and unboxing is not suppressed, the box is coerced to the
/// value slot type and unboxed via `buildValoptUnbox`; otherwise the value
/// passes through unchanged.
pub fn compileCallArgument(self: *LlvmCompiler, arg: ast.Expression) anyerror!types.LLVMValueRef {
    const saved_suppress = self.suppress_valopt_unbox;
    const val = try self.compileExpression(arg);
    self.suppress_valopt_unbox = saved_suppress;

    if (self.exprYieldsValoptBox(&arg) and !self.suppress_valopt_unbox) {
        return try self.buildValoptUnbox(self.coerceToSlotType(val, self.val_type));
    }
    return val;
}

/// How a value reaches a new home: `.owned` means it is a fresh reference the
/// destination must take (no retain, it is already +1) or a named owner it must
/// retain; `.borrowed` means the source keeps ownership. See
/// [`acquisitionDisposition`] for how this is computed and consumed.
pub const Disposition = enum { owned, borrowed };

/// Classifies WHY the TypeId engine considers a type not-owned, for shadow-diff
/// bucketing when it disagrees with the string engine.
///
/// Recurses through `optional` to its inner type so a `T?` is bucketed by `T`.
/// The result (`type_param`, `enum_`, `not_owned`, `other`) is only used to
/// attribute [`acquisitionDisposition`] disagreements to a cause in the
/// `sema_shadow` counters; it has no effect on emitted code.
fn dispResidueOf(store: *const typesys.TypeStore, tid: typesys.TypeId) sema_shadow.DispResidue {
    return switch (store.get(tid)) {
        .type_param => .type_param,
        .enum_ => .enum_,
        .optional => |inner| dispResidueOf(store, inner),
        else => if (!store.isOwned(tid)) .not_owned else .other,
    };
}

/// The authoritative disposition for an expression whose value is being
/// acquired into a new owner.
///
/// The typed-IR ownership pass is trusted first: if it says the expression is
/// owned (looked up per-instantiation when a generic instantiation is active,
/// else globally), the result is `.owned`. Otherwise it falls back to
/// [`principledDisposition`], the structural heuristic. When
/// `sema_shadow.report_enabled`, it additionally compares the heuristic against
/// the pass and records agree/disagree counts (bucketed by [`dispResidueOf`]),
/// which is how the heuristic path is validated before removal. See
/// [`Disposition`] and [`takeOwnedElement`].
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

/// True if the expression kind NAMES a place that already owns its value: a
/// variable (`ident`), a field (`field_access`), or an element (`index`).
///
/// Such an expression borrows: reading it does not transfer ownership, so a
/// destination that keeps the value must retain it. Everything else (calls,
/// literals, constructors) produces a fresh value. Consumed by
/// [`principledDisposition`] and [`takeOwnedElement`].
pub fn namesExistingOwner(kind: ast.ExprKind) bool {
    return switch (kind) {
        .ident, .field_access, .index => true,
        else => false,
    };
}

/// The structural fallback for [`acquisitionDisposition`], used when the typed
/// IR does not mark the expression owned.
///
/// An enum-variant constructor written as `EnumName.Variant` looks like a
/// field access but MINTS a value, so it is excluded from the
/// [`namesExistingOwner`] borrow rule. Assignments, most literals (except
/// heap-backed `decimal`/`array`), `try`/`cast`/`go`, and a non-boxing
/// optional-chain all borrow. Anything left is `.owned` only if
/// [`isOwnedExpr`] agrees the result type is a reference.
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

        .try_expr, .cast, .go_expr => return .borrowed,

        .await_expr => {},

        .optional_chaining => return if (self.exprYieldsValoptBox(expr)) .owned else .borrowed,

        else => {},
    }
    if (!self.isOwnedExpr(expr)) return .borrowed;
    return .owned;
}

/// Takes ownership of a value being stored into an owning slot (a container
/// element, for instance): retain it if it names an existing owner, otherwise
/// consume the temporary as-is.
///
/// This is the write-side counterpart of the disposition rules: a borrowed
/// source ([`namesExistingOwner`]) is aliased into the slot, so its refcount
/// must go +1; a fresh temporary is already +1 and is just moved in via
/// `consumeTemporary` (no extra retain, no leak).
pub fn takeOwnedElement(self: *LlvmCompiler, elem_kind: ast.ExprKind, val: types.LLVMValueRef) anyerror!void {
    if (namesExistingOwner(elem_kind)) {
        try self.compileRetain(val);
    } else {
        self.consumeTemporary(val);
    }
}

/// Emits a call to the runtime `kyte_retain(ptr)`, incrementing an object's
/// refcount.
///
/// The `kyte_retain` declaration is created lazily on first use and cached in
/// `self.func_map` so the whole module shares one declaration. `ptr` is passed
/// as the integer `val_type` (Kyte models heap pointers as integers).
pub fn compileRetain(self: *LlvmCompiler, ptr: types.LLVMValueRef) anyerror!void {
    const retain_fn = if (self.func_map.get("kyte_retain")) |f| f else blk: {
        var arg_types = [_]types.LLVMTypeRef{self.val_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 1, 0);
        const f = core.LLVMAddFunction(self.module, "kyte_retain", fn_type);
        try self.func_map.put("kyte_retain", f);
        break :blk f;
    };
    const fn_t = core.LLVMGlobalGetValueType(retain_fn);
    var args = [_]types.LLVMValueRef{ptr};
    _ = core.LLVMBuildCall2(self.builder, fn_t, retain_fn, &args, 1, "");
}

/// Emits a call to the runtime `kyte_release(ptr, dtor)`, decrementing an
/// object's refcount and running its destructor when it reaches zero.
///
/// The second argument is the destructor to invoke on the final release. When
/// `destructor_fn_opt` is null (the type owns nothing transitively, or is a
/// leaf), a null pointer is passed and the runtime just frees the box; when
/// present it is bitcast to an opaque `void*` function pointer. Like
/// [`compileRetain`], the `kyte_release` declaration is created once and cached
/// in `self.func_map`.
pub fn compileRelease(self: *LlvmCompiler, ptr: types.LLVMValueRef, destructor_fn_opt: ?types.LLVMValueRef) anyerror!void {
    const release_fn = if (self.func_map.get("kyte_release")) |f| f else blk: {
        const ptr_type = core.LLVMPointerType(self.void_type, 0);
        var arg_types = [_]types.LLVMTypeRef{self.val_type, ptr_type};
        const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 2, 0);
        const f = core.LLVMAddFunction(self.module, "kyte_release", fn_type);
        try self.func_map.put("kyte_release", f);
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

/// Builds the destructor symbol name for a type: `__destruct_<mangled>`.
///
/// The name is mangled (see [`mangleTypeName`]) so generic and composite type
/// names become symbol-safe and collision-free, giving each type exactly one
/// destructor function to memoise on. Caller owns the returned slice.
fn destructorName(allocator: std.mem.Allocator, type_name: []const u8) ![]u8 {
    const mangled = try mangleTypeName(allocator, type_name);
    defer allocator.free(mangled);
    return std.fmt.allocPrint(allocator, "__destruct_{s}", .{mangled});
}

/// Substitutes a generic struct instantiation's type arguments into a field's
/// declared type string.
///
/// Given `inst_name` like `Pair<int, string>` and a field type `T` (or a type
/// mentioning `T`), it maps each of the struct's declared type parameters to
/// the corresponding argument parsed out of the angle brackets, then rewrites
/// the field type accordingly (e.g. `List<K>` -> `List<int>`). Depth tracking
/// splits the top-level argument list correctly through nested `<...>`.
/// Substitution is whole-identifier only (bounded by [`isIdentCh`]) so a type
/// parameter `T` does not match inside `Tree`. Returns `field_type` unchanged
/// (same pointer) when `inst_name` is not a matching generic instantiation, so
/// callers must compare `.ptr` before freeing; otherwise the result is a fresh
/// owned slice.
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

/// Fully resolves a type string against the currently-active generic context:
/// the enclosing struct instantiation and then the current method's type
/// parameters.
///
/// Chains [`substituteFieldType`] (struct-level args from
/// `self.current_instantiation`) into `substMethodParams` (method-level args),
/// freeing the intermediate slice only when it is a distinct allocation from
/// both input and output. When no struct instantiation is active it applies
/// method substitution alone.
pub fn substTypeParams(self: *LlvmCompiler, type_str: []const u8) anyerror![]const u8 {
    if (self.current_instantiation) |inst| {
        const after_struct = try self.substituteFieldType(inst, type_str);
        const result = try self.substMethodParams(after_struct);
        if (after_struct.ptr != type_str.ptr and after_struct.ptr != result.ptr) {
            self.allocator.free(after_struct);
        }
        return result;
    }
    return try self.substMethodParams(type_str);
}


/// True if `c` can appear inside an identifier (alphanumeric or `_`).
///
/// Used by [`substituteFieldType`] to enforce whole-identifier matching when
/// replacing type parameters, so partial-name collisions are avoided.
fn isIdentCh(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True if the type name denotes a function/closure type, detected by an arrow
/// `=>` or `->` at bracket depth zero.
///
/// Function values are heap closures with a uniform layout, so
/// [`getOrCreateDestructor`] routes any function type to the single shared
/// closure destructor. The scan tracks `<...>` nesting so an arrow inside a
/// nested generic argument does not trigger a false positive; a `>` preceded by
/// `=` or `-` is read as an arrow rather than a bracket close.
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

/// Returns the element type of a `Storage<T>` name (the `T` slice), or null if
/// the name is not a `Storage<...>`.
///
/// `Storage<T>` is Kyte's raw contiguous backing buffer (the primitive under
/// `List`/`RawBuffer`); knowing its element type lets the storage destructor
/// loop release each owned slot. See [`buildStorageDestructor`].
fn storageElem(type_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, type_name, "Storage<")) return null;
    if (!std.mem.endsWith(u8, type_name, ">")) return null;
    return type_name["Storage<".len .. type_name.len - 1];
}

/// Emits a loop that destructs each INLINE value-struct element of a
/// `Storage<T>` where `T` is a value struct with owned fields.
///
/// Value-struct elements are stored by value (their bytes packed into the
/// buffer at `elementSize` stride), not as pointers, so they cannot be released
/// with `kyte_release`; instead each slot's ADDRESS is passed straight to the
/// element's own destructor. The element count is derived from the buffer's
/// byte length (loaded from the header at `self - 4`) divided by the element
/// width (min 1 to avoid division by zero). Builds the standard
/// cond/body/exit basic-block loop calling the element destructor per slot.
/// Contrast [`buildStorageDestructorLoop`], which handles pointer elements.
fn buildInlineValueStructStorageLoop(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem: []const u8) anyerror!void {
    const elem_dest = (try self.getOrCreateDestructor(elem)) orelse return;
    const dest_ft = core.LLVMGlobalGetValueType(elem_dest);
    const width_u = @max(self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(elem) }, false), 1);
    const width = core.LLVMConstInt(self.val_type, width_u, 0);
    const self_val = core.LLVMGetParam(dest_fn, 0);

    const four = core.LLVMConstInt(self.val_type, 4, 0);
    const len_addr = core.LLVMBuildSub(self.builder, self_val, four, "istg_len_addr");
    const len_ptr = core.LLVMBuildIntToPtr(self.builder, len_addr, core.LLVMPointerType(self.i32_type, 0), "istg_len_ptr");
    const len_i32 = core.LLVMBuildLoad2(self.builder, self.i32_type, len_ptr, "istg_len");
    const len_val = core.LLVMBuildZExt(self.builder, len_i32, self.val_type, "istg_len_ext");
    const n_slots = core.LLVMBuildUDiv(self.builder, len_val, width, "istg_slots");

    const i_alloca = core.LLVMBuildAlloca(self.builder, self.val_type, "istg_i");
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), i_alloca);
    const cond_bb = core.LLVMAppendBasicBlock(dest_fn, "istg_cond");
    const body_bb = core.LLVMAppendBasicBlock(dest_fn, "istg_body");
    const exit_bb = core.LLVMAppendBasicBlock(dest_fn, "istg_exit");
    _ = core.LLVMBuildBr(self.builder, cond_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
    const i_cur = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "istg_i_cur");
    const cmp = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntULT, i_cur, n_slots, "istg_cmp");
    _ = core.LLVMBuildCondBr(self.builder, cmp, body_bb, exit_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
    const i_b = core.LLVMBuildLoad2(self.builder, self.val_type, i_alloca, "istg_i_b");
    const off = core.LLVMBuildMul(self.builder, i_b, width, "istg_off");
    const slot_addr = core.LLVMBuildAdd(self.builder, self_val, off, "istg_slot_addr");
    var args = [_]types.LLVMValueRef{slot_addr};
    _ = core.LLVMBuildCall2(self.builder, dest_ft, elem_dest, &args, 1, "");
    const i_next = core.LLVMBuildAdd(self.builder, i_b, core.LLVMConstInt(self.val_type, 1, 0), "istg_i_next");
    _ = core.LLVMBuildStore(self.builder, i_next, i_alloca);
    _ = core.LLVMBuildBr(self.builder, cond_bb);
    core.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
}

/// Builds the body of a `Storage<T>` destructor, dispatching on how `T` is
/// stored (name-based path).
///
/// If `T` is a value struct, only structs that have owned fields need any work
/// and get the inline loop ([`buildInlineValueStructStorageLoop`]); a
/// field-less value struct is a no-op. Otherwise elements are 8-byte pointer
/// slots and are released only when the element is itself owned (an owned
/// storage element or a value-optional box), via
/// [`buildStorageDestructorLoop`]. Compare [`buildStorageDestructorByTypeId`],
/// the TypeId-driven equivalent.
fn buildStorageDestructor(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem: []const u8) anyerror!void {
    if (self.isValueStructName(elem)) {
        if (self.valueStructHasOwnedFields(elem)) try buildInlineValueStructStorageLoop(self, dest_fn, elem);
        return;
    }
    const should_free = self.isOwnedStorageElemByName(elem) or valueOptionalName(elem);
    const elem_dest = if (should_free) try self.getOrCreateDestructor(elem) else null;
    try buildStorageDestructorLoop(self, dest_fn, should_free, elem_dest);
}

/// TypeId-driven variant of [`buildStorageDestructor`]: builds the release loop
/// for a `Storage<T>` from the element's TypeId.
///
/// An element needs releasing if it is owned or a value-optional box (its inner
/// resolved via `valueOptionalInner`); the per-slot destructor is fetched by
/// TypeId. Delegates the actual loop emission to [`buildStorageDestructorLoop`].
fn buildStorageDestructorByTypeId(self: *LlvmCompiler, dest_fn: types.LLVMValueRef, elem_tid: typesys.TypeId) anyerror!void {
    const is_valopt = self.valueOptionalInner(elem_tid) != null;
    const should_free = self.isOwnedTypeId(elem_tid) or is_valopt;
    const elem_dest = if (should_free) try self.getOrCreateDestructorByTypeId(elem_tid) else null;
    try buildStorageDestructorLoop(self, dest_fn, should_free, elem_dest);
}

/// Emits the pointer-element release loop shared by both `Storage<T>`
/// destructor paths.
///
/// Returns immediately when `owned` is false (nothing to release, leaving the
/// caller to just `ret void`). Otherwise it reads the buffer byte-length from
/// the header word at `self - 4`, divides by 8 (pointer stride) to get the slot
/// count, then loops loading each pointer slot and calling [`compileRelease`]
/// with the per-element destructor `elem_dest`. Emits its own
/// cond/body/exit basic blocks appended to `dest_fn`.
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

/// Gets or creates the destructor function for a `Storage<T>` TypeId,
/// memoised by its mangled symbol name.
///
/// Returns null if there is no type store or the type is not a storage. Renders
/// the legacy name for the symbol, returns any pre-existing function of that
/// name, otherwise declares `__destruct_<mangled>`, positions the builder in a
/// fresh entry block (saving and restoring the previous insertion point), emits
/// the element loop via [`buildStorageDestructorByTypeId`], and closes with
/// `ret void`. Under shadow reporting it also runs [`diffStorageElem`].
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

/// Gets or creates the single shared destructor for trait objects
/// (`__destruct_trait`), memoised across the module.
///
/// A trait object is a fat pointer `{struct_ptr, vtable}`. This destructor
/// reads the struct pointer and the vtable out of the fat pointer, loads the
/// concrete destructor from vtable slot 0 (the convention: slot 0 is always the
/// struct's destructor), and calls [`compileRelease`] on the struct pointer
/// with that concrete destructor. One function serves every trait type because
/// the layout is uniform and the actual type is discovered at runtime through
/// the vtable.
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

/// Gets or creates the single shared closure destructor
/// (`__destruct_closure`), memoised across the module.
///
/// A closure box is laid out `{fn_ptr, env, cleanup}` at 8-byte strides. This
/// destructor loads the captured environment pointer and the optional cleanup
/// function pointer; if a cleanup is present (non-null), it is called with the
/// environment (this is where captured owned variables get released), then the
/// environment box is freed with `kyte_bytes_free`. The has-cleanup branch is
/// conditional so closures that captured nothing owned skip the call. Every
/// closure type shares this because the box layout is uniform.
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

    const free_fn = if (self.func_map.get("kyte_bytes_free")) |f| f else blk: {
        var at = [_]types.LLVMTypeRef{self.val_type};
        const ft = core.LLVMFunctionType(self.void_type, &at, 1, 0);
        const f = core.LLVMAddFunction(self.module, "kyte_bytes_free", ft);
        try self.func_map.put("kyte_bytes_free", f);
        break :blk f;
    };
    const free_t = core.LLVMGlobalGetValueType(free_fn);
    var free_args = [_]types.LLVMValueRef{env};
    _ = core.LLVMBuildCall2(self.builder, free_t, free_fn, &free_args, 1, "");

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// The TypeId-driven destructor dispatcher: returns the destructor function for
/// a type, or null if the type owns nothing and needs none.
///
/// This is the accurate counterpart to [`getOrCreateDestructor`]. It switches
/// on the type kind and routes to the shape-specific builder: traits and funcs
/// to the shared destructors, tuples/error-unions/structs/storage to their
/// `*ByTypeId` builders. Primitives, pointers, and unresolved types return
/// null (nothing to free). A boxed value-optional (`valueOptionalInner != null`)
/// also returns null here, because its box is released through the field
/// machinery, not a standalone destructor. `optional` (non-value) and any other
/// kind fall back to the name-based [`getOrCreateDestructor`] via the legacy
/// renderer.
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

/// Prefers the accurate TypeId destructor over the string one, but only when
/// the two engines produce the SAME mangled symbol.
///
/// This is the bridge that lets the codebase migrate off the string path
/// safely: given both a type NAME and an optional TypeId, it renders each to a
/// destructor symbol and, if they match, builds via
/// [`getOrCreateDestructorByTypeId`] (recording a `phaseA_flip`). If they
/// diverge, it keeps the legacy [`getOrCreateDestructor`] to avoid changing
/// behaviour, recording a `phaseA_split` with both names for later analysis.
/// With no usable TypeId it records `phaseA_no_id` and uses the string path.
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

/// The name-based destructor dispatcher: returns (creating and memoising on
/// first use) the destructor for a type NAME, or null if the type owns nothing.
///
/// This is the legacy string engine, still the fallback for
/// [`getOrCreateDestructorByTypeId`] on the shapes it does not handle directly.
/// It routes by name: `any` to a runtime box dtor; traits to the shared trait
/// dtor; function/tuple/`ErrUnion(...)` names to their builders; tagged enums to
/// [`getOrCreateEnumDestructor`]. For a `Storage<...>` or a known struct it
/// declares `__destruct_<mangled>`, sets `current_instantiation` so field types
/// substitute correctly, calls the user-declared `delete` method if one exists
/// (single-arg form only), then either loops over storage elements or walks the
/// struct's fields. A field that [`isOwnedDeclaredType`] considers a reference
/// is loaded and released; a field that is an inline value struct has its own
/// destructor called on the field ADDRESS. Types with no declaration return
/// null.
pub fn getOrCreateDestructor(self: *LlvmCompiler, type_name: []const u8) anyerror!?types.LLVMValueRef {

    if (std.mem.eql(u8, type_name, "any")) {
        if (self.func_map.get("kyte_any_box_dtor")) |f| return f;
        var one = [_]types.LLVMTypeRef{self.val_type};
        const ft = core.LLVMFunctionType(self.void_type, &one, 1, 0);
        const f = core.LLVMAddFunction(self.module, "kyte_any_box_dtor", ft);
        try self.func_map.put("kyte_any_box_dtor", f);
        return f;
    }

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
    const saved_inst_id = self.current_instantiation_id;
    self.current_instantiation = type_name;
    self.current_instantiation_id = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_instantiation_id = saved_inst_id;
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
            } else if (self.structs.contains(getStructBaseName(field_type))) {
                if (try self.getOrCreateDestructor(field_type)) |field_dest| {
                    const offset = try self.getFieldOffset(base_struct, field.name);
                    const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                    const faddr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "vfield_addr");
                    const fdt = core.LLVMGlobalGetValueType(field_dest);
                    var da = [_]types.LLVMValueRef{faddr};
                    _ = core.LLVMBuildCall2(self.builder, fdt, field_dest, &da, 1, "");
                }
            }
        }
    }

    _ = core.LLVMBuildRetVoid(self.builder);

    if (saved_ip) |sip| {
        core.LLVMPositionBuilderAtEnd(self.builder, sip);
    }

    return dest_fn;
}

/// TypeId-driven struct destructor: releases every owned field of a struct at
/// its byte offset, resolving field types through the typed IR.
///
/// The accurate counterpart to the struct branch of [`getOrCreateDestructor`].
/// Falls back to the name path when the live sema symbol table is unavailable or
/// the symbol is not a struct. After memoisation and the optional `delete`-method
/// call, it lowers each declared field type through [`lower.Lowerer`] under a
/// param scope built from the struct declaration, substitutes the
/// instantiation's type arguments ([`subst.substitute`]), and: releases owned
/// fields via [`compileRelease`]; recurses into inline (non-owned) struct fields
/// by calling their destructor on the field address. A field that fails to lower
/// or substitute aborts through [`unresolvedDtorField`] (fail-closed).
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
    const saved_inst_id = self.current_instantiation_id;
    self.current_instantiation = type_name;
    self.current_instantiation_id = null;
    defer {
        self.current_instantiation = saved_instantiation;
        self.current_instantiation_id = saved_inst_id;
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

        const c: typesys.TypeId = blk: {
            const raw = l.lower(field.type_name) catch break :blk unresolvedDtorField(type_name, field.name);
            break :blk subst.substitute(&sm.store, raw, stype.decl, stype.args) catch unresolvedDtorField(type_name, field.name);
        };

        if (!self.isOwnedTypeId(c)) {
            if (st.get(c) == .struct_) {
                if (try self.getOrCreateDestructorByTypeId(c)) |field_dest| {
                    const offset = try self.getFieldOffset(base_struct, field.name);
                    const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
                    const faddr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "vfield_addr");
                    const fdt = core.LLVMGlobalGetValueType(field_dest);
                    var da = [_]types.LLVMValueRef{faddr};
                    _ = core.LLVMBuildCall2(self.builder, fdt, field_dest, &da, 1, "");
                }
            }
            continue;
        }

        const offset = try self.getFieldOffset(base_struct, field.name);
        const offset_val = core.LLVMConstInt(self.val_type, offset, 0);
        const addr = core.LLVMBuildAdd(self.builder, self_val, offset_val, "field_addr");
        const llvm_field_type = self.toLLVMType(field.type_name);
        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(llvm_field_type, 0), "field_ptr");
        const loaded_field_val = core.LLVMBuildLoad2(self.builder, llvm_field_type, ptr, "field_load");
        const casted_field_val = self.castToValType(loaded_field_val, field.type_name);

        const field_dest = try self.getOrCreateDestructorByTypeId(c);
        try self.compileRelease(casted_field_val, field_dest);
    }

    _ = core.LLVMBuildRetVoid(self.builder);
    if (saved_ip) |sip| core.LLVMPositionBuilderAtEnd(self.builder, sip);
    return dest_fn;
}

/// TypeId-driven error-union destructor: branches on the tag word and releases
/// the active arm's payload if that arm is owned.
///
/// An error-union box is `{tag, payload}` at 8-byte offsets, tag 1 = error arm,
/// tag 0 = ok arm. This emits a conditional: in the error block it releases the
/// payload with the `err` type's destructor if [`isOwnedTypeId`] says the err
/// type is owned; in the ok block, likewise for the `ok` type; both fall through
/// to a common done block. Compare [`getOrCreateErrUnionDestructor`], the
/// name-based twin. Under shadow reporting it runs [`diffErrUnionArms`].
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

/// Name-based error-union destructor: the string-engine twin of
/// [`getOrCreateErrUnionDestructorByTypeId`].
///
/// Parses the ok/err arm names from the `ErrUnion(ok, err)` string via
/// [`errUnionParts`] (returns null if the name is malformed), then emits the
/// same tag-branch layout, releasing an arm's payload only when
/// [`isOwnedErrUnionPayloadByName`] reports it owned.
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

/// Builds the destructor for a tagged-union enum: switches on the tag word and
/// releases the payload slots of the active variant.
///
/// Returns null for plain enums (see [`enumIsTaggedUnion`]) which own nothing.
/// The box is `{tag, payload...}` at 8-byte strides. For each payload-carrying
/// variant it emits a tag comparison; on match it releases the variant's single
/// payload (`type_name`) or each of its named `fields` at successive 8-byte
/// slots (via [`releaseEnumPayloadSlot`]) then jumps to done; non-matching
/// variants fall through to the next test. Variants with no payload are skipped.
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

/// Releases one enum payload slot at `offset` within the box, if the payload
/// type is an owned reference.
///
/// Returns without emitting anything when [`isOwnedDeclaredType`] says the slot
/// holds a non-owned value. Otherwise loads the pointer from `box + offset` and
/// calls [`compileRelease`] with the payload type's destructor. Helper for
/// [`getOrCreateEnumDestructor`].
fn releaseEnumPayloadSlot(self: *LlvmCompiler, box: types.LLVMValueRef, offset: u32, tref: ast.TypeRef) anyerror!void {
    const tstr = try self.typeRefToString(tref);
    if (!self.isOwnedDeclaredType(tref, tstr)) return;
    const addr = core.LLVMBuildAdd(self.builder, box, core.LLVMConstInt(self.val_type, offset, 0), "en_pay_addr");
    const ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "en_pay_ptr");
    const val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "en_pay");
    const d = try self.getOrCreateDestructor(tstr);
    try self.compileRelease(val, d);
}

/// True if the type name is a tuple: parenthesised and NOT a function type.
///
/// The `=>` exclusion distinguishes a tuple `(int, string)` from a function
/// type `(int) => string`, which is also parenthesised. Used to route names to
/// the tuple destructor/copy paths ([`getOrCreateTupleDestructor`],
/// [`countTupleElements`]).
pub fn isTupleType(type_name: []const u8) bool {
    return type_name.len >= 2 and type_name[0] == '(' and type_name[type_name.len - 1] == ')' and
        std.mem.indexOf(u8, type_name, "=>") == null;
}

/// TypeId-driven tuple destructor: releases each owned element at its 8-byte
/// slot offset.
///
/// A tuple box packs its elements at 8-byte strides. This iterates the element
/// TypeIds, skips non-owned elements ([`isOwnedTypeId`]), and for owned ones
/// loads the pointer at `box + idx*8` and releases it with the element's
/// destructor. The name-based twin is [`getOrCreateTupleDestructor`]; shadow
/// reporting runs [`diffTupleElems`].
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

/// Shadow-diff: compares the TypeId and string engines' ownership verdicts for
/// each field of a struct, tallying agree/disagree counts.
///
/// Instrumentation only (active under `sema_shadow.report_enabled`), it emits
/// no code. For each field it lowers+substitutes the type to get the store-side
/// ownership and separately runs the string-side [`isOwnedDeclaredType`], then
/// bumps `struct_field_agree`/`struct_field_disagree` and records the last
/// disagreement for reporting. This is how confidence is built that the string
/// path can be retired.
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

/// Shadow-diff: compares the two engines' ownership and rendered names for an
/// error-union's ok and err arms.
///
/// Instrumentation only. Both arms must agree on ownership AND on rendered arm
/// name for `erru_elem_agree` to bump; any mismatch (or a name that fails to
/// parse into parts) bumps `erru_elem_disagree` and records the name. See
/// [`diffStructFields`] for the pattern.
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

/// Shadow-diff: compares the two engines' ownership and rendered name for a
/// `Storage<T>` element type.
///
/// Instrumentation only. Bumps `storage_elem_agree` when the TypeId-side
/// ownership and rendered name both match the string-side
/// [`isOwnedStorageElemByName`] and `storageElem` parse; otherwise
/// `storage_elem_disagree`.
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

/// Shadow-diff: compares the two engines element-by-element for a tuple type.
///
/// Instrumentation only. First checks the element COUNTS match
/// ([`countTupleElements`] vs the store's element list); then, per element,
/// compares ownership and rendered name against the string-side
/// `getTupleElementType`/[`isOwnedTupleElemByName`], bumping
/// `tuple_elem_agree`/`tuple_elem_disagree`.
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

/// Name-based tuple destructor: the string-engine twin of
/// [`getOrCreateTupleDestructorByTypeId`].
///
/// Iterates element index 0 upward, obtaining each element type name via
/// `getTupleElementType` and stopping once the index reaches
/// [`countTupleElements`]. Note the element type is fetched BEFORE the bound
/// check, so the loop must break on the count and its `defer` free covers only
/// the in-range allocations. Owned elements ([`isOwnedTupleElemByName`]) are
/// loaded from their 8-byte slot and released.
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

/// Deep-copies a tuple box so the copy independently owns its contents.
///
/// Allocates a fresh box of `n*8` bytes and copies each element with the right
/// ownership discipline: a value-struct element is byte-copied into a NEW heap
/// allocation and its owned fields retained (`retainValueStructOwnedFields`),
/// because value structs are copied by value not by pointer; an owned
/// pointer element is retained (+1); a plain scalar is copied as-is. Returns
/// `src` unchanged for the empty tuple. This is what makes assigning or passing
/// a tuple value-semantic rather than aliasing. Mirrors the field-copy logic in
/// `expressions.zig`.
pub fn buildTupleDeepCopy(self: *LlvmCompiler, src: types.LLVMValueRef, tuple_name: []const u8) anyerror!types.LLVMValueRef {
    const word: u64 = 8;
    const n = countTupleElements(tuple_name);
    if (n == 0) return src;
    const newbox = try self.compileAlloc(core.LLVMConstInt(self.val_type, @intCast(n * word), 0));
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const elem_ty = LlvmCompiler.getTupleElementType(self.allocator, tuple_name, idx) catch continue;
        defer self.allocator.free(elem_ty);
        const off = core.LLVMConstInt(self.val_type, @intCast(idx * word), 0);
        const src_addr = core.LLVMBuildAdd(self.builder, src, off, "tdc_saddr");
        const src_ptr = core.LLVMBuildIntToPtr(self.builder, src_addr, core.LLVMPointerType(self.val_type, 0), "tdc_sptr");
        const src_val = core.LLVMBuildLoad2(self.builder, self.val_type, src_ptr, "tdc_sval");

        var new_val = src_val;
        const base = getStructBaseName(elem_ty);
        const is_value_struct = if (self.structs.get(base)) |sd| !sd.is_reference else false;
        if (is_value_struct) {
            const size = self.getTypeSize(ast.TypeRef{ .ident = base }, false);
            const ns = try self.compileAlloc(core.LLVMConstInt(self.val_type, @intCast(if (size == 0) 8 else size), 0));
            _ = try self.buildValueStructCopyInto(ns, src_val, size);
            try self.retainValueStructOwnedFields(ns, base);
            new_val = ns;
        } else if (self.isOwnedTupleElemByName(tuple_name, idx, elem_ty)) {
            try self.compileRetain(src_val);
        }

        const dst_addr = core.LLVMBuildAdd(self.builder, newbox, off, "tdc_daddr");
        const dst_ptr = core.LLVMBuildIntToPtr(self.builder, dst_addr, core.LLVMPointerType(self.val_type, 0), "tdc_dptr");
        _ = core.LLVMBuildStore(self.builder, new_val, dst_ptr);
    }
    return newbox;
}

/// Counts the top-level elements of a tuple type name.
///
/// Returns 0 for a non-tuple or the empty tuple `()`. Commas are counted only
/// at bracket depth zero, so nested generics/tuples like `(List<A, B>, int)`
/// count as two elements, not three. Used everywhere the tuple destructor and
/// deep-copy need the element arity.
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

/// Splits an `ErrUnion(ok, err)` name into its two arm names, at the top-level
/// comma.
///
/// Returns null if the name is not a well-formed `ErrUnion(...)`. Depth-aware so
/// a comma inside a nested `<...>`/`(...)` in the ok arm does not split early.
/// Both returned slices are freshly allocated and OWNED by the caller (freed
/// together; on the second allocation failing, the first is freed before
/// returning null). Used by the name-based error-union destructor and
/// [`buildErrUnion`].
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

/// Constructs an error-union box `{tag, payload}` wrapping `val` in either the
/// ok or err arm.
///
/// Allocates a 2-word box, retains the payload first if that arm's type is owned
/// (so the box holds its own +1 reference), writes the tag (1 for err, 0 for
/// ok) and the payload coerced to the value slot type. The retain here is
/// balanced by the release the error-union destructor emits (see
/// [`getOrCreateErrUnionDestructor`]).
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

/// Runs a value struct's destructor directly on its in-place address, without
/// going through refcounting.
///
/// A value struct lives inline in its owner, so it is not a refcounted box:
/// there is nothing to `kyte_release`, but its owned FIELDS still need freeing.
/// This fetches the struct's destructor (preferring the TypeId,
/// [`getOrCreateDestructorPreferId`]) and calls it with the struct's address. A
/// no-op if the type owns nothing (destructor is null). Used by
/// [`releaseLocalByName`] and [`releaseLocalVariables`].
pub fn dropValueStruct(self: *LlvmCompiler, struct_addr: types.LLVMValueRef, type_name: []const u8, tid: ?typesys.TypeId) anyerror!void {
    const dest = (try self.getOrCreateDestructorPreferId(type_name, tid)) orelse return;
    var args = [_]types.LLVMValueRef{struct_addr};
    const fn_t = core.LLVMGlobalGetValueType(dest);
    _ = core.LLVMBuildCall2(self.builder, fn_t, dest, &args, 1, "");
}

/// Releases a single named local at end of its lifetime, then null out its slot
/// so it cannot be released twice.
///
/// Looks up the local's alloca, loads the value, and either drops it in place
/// as a value struct ([`dropValueStruct`]) or releases it as a reference. In
/// both cases the alloca is overwritten with 0 afterwards, so a later
/// scope-exit or return path that also visits this slot sees a null pointer and
/// skips it (double-free guard). Silently returns if the name is not a known
/// local. Used for block-scoped bindings.
pub fn releaseLocalByName(self: *LlvmCompiler, name: []const u8, type_name: []const u8) anyerror!void {
    const alloca_val = self.locals.get(name) orelse return;
    const loaded = core.LLVMBuildLoad2(self.builder, self.val_type, alloca_val, "blk_rel_load");

    const tid: ?typesys.TypeId = if (self.current_local_type_ids) |ids| ids.get(name) else null;
    if (self.isValueStructName(type_name)) {
        try self.dropValueStruct(loaded, type_name, tid);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), alloca_val);
        return;
    }
    const dest = try self.getOrCreateDestructorPreferId(type_name, tid);
    try self.compileRelease(loaded, dest);

    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), alloca_val);
}

/// Releases every owned local (and drops value structs with owned fields) at
/// function exit.
///
/// Iterates the function's local type map and, for each owned variable (or a
/// value struct with owned fields that must be dropped in place), emits the
/// release. Several locals are deliberately EXCLUDED to avoid unbalanced frees:
/// `self` inside `_delete`/`_init`/`_new` methods (its lifetime is the caller's
/// or the ctor's responsibility); parameters (released at the call site, not
/// here); and locals promoted to captured globals (`captured_globals`, kept
/// alive by the capture). Owned refs are released; value-struct drops go through
/// [`dropValueStruct`]; each released slot is nulled to prevent a second
/// release. This is the primary scope-exit ARC emitter.
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

        const owned = self.isOwnedLocal(var_name, var_type);
        const value_drop = !owned and self.isValueStructName(var_type) and self.valueStructHasOwnedFields(var_type);
        if (owned or value_drop) {
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
                if (value_drop) {
                    try self.dropValueStruct(loaded, var_type, tid);
                    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.val_type, 0, 0), alloca_val);
                } else {
                    const dest = try self.getOrCreateDestructorPreferId(var_type, tid);
                    try self.compileRelease(loaded, dest);
                }
            }
        }
    }
}

/// Master switch for the ARC-elision passes ([`elideBorrowedArc`]); off unless
/// enabled by the driver. Kept as a module-global because the passes run over
/// the finished module, outside any `self` context.
pub var elide_enabled: bool = false;
/// Running count of retain/release PAIRS the elision passes removed, reported by
/// the census ([`arcCensusAfter`]).
pub var elide_count: usize = 0;

/// Enables the ARC-traffic census (`KYTE_ARC_CENSUS`): counts total retain/release
/// calls before and after elision and estimates further headroom.
pub var arc_census: bool = false;
/// `kyte_retain` call count captured before elision, by [`arcCensusBefore`].
pub var census_retain_before: usize = 0;
/// `kyte_release` call count captured before elision, by [`arcCensusBefore`].
pub var census_release_before: usize = 0;

/// Counts `kyte_retain` and `kyte_release` calls across all DEFINED functions in
/// a module (declarations are skipped).
///
/// The primitive both census snapshots use; writes totals through the `retains`
/// and `releases` out-parameters. See [`arcCensusBefore`]/[`arcCensusAfter`].
fn countArcCalls(module: types.LLVMModuleRef, retains: *usize, releases: *usize) void {
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        if (core.LLVMIsDeclaration(fnv) != 0) continue;
        var bb = core.LLVMGetFirstBasicBlock(fnv);
        while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
            var inst = core.LLVMGetFirstInstruction(bb);
            while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
                if (isNamedCall(inst, "kyte_retain")) retains.* += 1;
                if (isNamedCall(inst, "kyte_release")) releases.* += 1;
            }
        }
    }
}

/// Snapshots ARC-call totals BEFORE the elision passes run.
///
/// A no-op unless [`arc_census`] is set. Resets and fills
/// [`census_retain_before`]/[`census_release_before`] so [`arcCensusAfter`] can
/// report how many calls elision removed. The `self` parameter is unused.
pub fn arcCensusBefore(_: *LlvmCompiler, module: types.LLVMModuleRef) void {
    if (!arc_census) return;
    census_retain_before = 0;
    census_release_before = 0;
    countArcCalls(module, &census_retain_before, &census_release_before);
}

/// Estimates how many retain/release pairs a future INTRA-BLOCK borrow-skip
/// optimisation could remove (a static lower bound for the census).
///
/// Within each basic block it materialises the instruction list, then for every
/// `kyte_retain` walks forward to the matching `kyte_release` of the same value.
/// If in between the value only appears in loads/compares and never "escapes"
/// (is not itself retained again, nor passed as the LAST argument of a call,
/// the destructor-argument position), the retained value stays borrow-only in
/// that window and the pair is counted as elidable. This does NOT modify the IR;
/// it only measures headroom that [`elideBorrowedArc`] does not yet capture. See
/// also [`countBorrowSkipFnScope`] for the whole-function version.
fn countBorrowSkipCandidates(a: std.mem.Allocator, module: types.LLVMModuleRef) usize {
    var candidates: usize = 0;
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        if (core.LLVMIsDeclaration(fnv) != 0) continue;
        var bb = core.LLVMGetFirstBasicBlock(fnv);
        while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
            var insts = std.ArrayList(types.LLVMValueRef).empty;
            defer insts.deinit(a);
            var inst = core.LLVMGetFirstInstruction(bb);
            while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) insts.append(a, inst) catch {};

            for (insts.items, 0..) |ri, i| {
                if (!isNamedCall(ri, "kyte_retain")) continue;
                const v = core.LLVMGetOperand(ri, 0);
                var j = i + 1;
                var escaped = false;
                while (j < insts.items.len) : (j += 1) {
                    const uj = insts.items[j];
                    if (isNamedCall(uj, "kyte_release") and core.LLVMGetOperand(uj, 0) == v) {
                        if (!escaped) candidates += 1;
                        break;
                    }
                    if (!instUsesValue(uj, v)) continue;
                    const opc = core.LLVMGetInstructionOpcode(uj);
                    if (opc == .LLVMLoad or opc == .LLVMICmp) continue;
                    if (opc == .LLVMCall) {
                        if (isNamedCall(uj, "kyte_retain")) { escaped = true; break; }
                        const n = core.LLVMGetNumOperands(uj);
                        if (n >= 1 and core.LLVMGetOperand(uj, @intCast(n - 1)) == v) { escaped = true; break; }
                        continue;
                    }
                    escaped = true;
                    break;
                }
            }
        }
    }
    return candidates;
}

/// Whole-function counterpart of [`countBorrowSkipCandidates`]: counts retains
/// whose value is borrow-only across the ENTIRE function.
///
/// Instead of scanning forward within a block, it walks all USES of the retained
/// value directly (use/def graph, so it spans basic blocks). A candidate is a
/// retain whose value has exactly one `kyte_release`, is never retained again,
/// and never escapes through a call's destructor-argument slot; loads and
/// compares are ignored. Reports a broader (inter-block) headroom figure for the
/// census; does not alter IR.
fn countBorrowSkipFnScope(module: types.LLVMModuleRef) usize {
    var candidates: usize = 0;
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        if (core.LLVMIsDeclaration(fnv) != 0) continue;
        var bb = core.LLVMGetFirstBasicBlock(fnv);
        while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
            var inst = core.LLVMGetFirstInstruction(bb);
            while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
                if (!isNamedCall(inst, "kyte_retain")) continue;
                const v = core.LLVMGetOperand(inst, 0);
                var releases: usize = 0;
                var escapes = false;
                var use = core.LLVMGetFirstUse(v);
                while (use != null) : (use = core.LLVMGetNextUse(use)) {
                    const user = core.LLVMGetUser(use);
                    if (user == inst) continue;
                    if (isNamedCall(user, "kyte_release")) { releases += 1; continue; }
                    if (isNamedCall(user, "kyte_retain")) { escapes = true; break; }
                    const opc = core.LLVMGetInstructionOpcode(user);
                    if (opc == .LLVMLoad or opc == .LLVMICmp) continue;
                    if (opc == .LLVMCall) {
                        const n = core.LLVMGetNumOperands(user);
                        if (n >= 1 and core.LLVMGetOperand(user, @intCast(n - 1)) == v) { escapes = true; break; }
                        continue;
                    }
                    escapes = true;
                    break;
                }
                if (!escapes and releases == 1) candidates += 1;
            }
        }
    }
    return candidates;
}

/// Prints the ARC-traffic census AFTER elision: before/after call counts, what
/// current elision removed, and estimated remaining borrow-skip headroom.
///
/// A no-op unless [`arc_census`] is set. Re-counts surviving retain/release
/// calls, runs both borrow-skip estimators
/// ([`countBorrowSkipCandidates`]/[`countBorrowSkipFnScope`]), computes the
/// percentage removed and the percentage still elidable, and dumps a
/// human-readable report to stderr. Purely diagnostic (the `Gap3` headroom
/// analysis); it does not change codegen.
pub fn arcCensusAfter(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
    if (!arc_census) return;
    var r_after: usize = 0;
    var rel_after: usize = 0;
    countArcCalls(module, &r_after, &rel_after);
    const borrow_skip = countBorrowSkipCandidates(self.allocator, module);
    const borrow_skip_fn = countBorrowSkipFnScope(module);
    const before = census_retain_before + census_release_before;
    const after = r_after + rel_after;
    const removed = before -| after;
    const pct: usize = if (before == 0) 0 else (removed * 100) / before;
    const bs_pct: usize = if (after == 0) 0 else (borrow_skip * 2 * 100) / after;
    std.debug.print(
        "=== ARC-traffic census (KYTE_ARC_CENSUS, Gap3-A/E2 headroom) ===\n" ++
        "  kyte_retain  : before={d}  after={d}\n" ++
        "  kyte_release : before={d}  after={d}\n" ++
        "  total ARC calls : before={d}  after(surviving)={d}\n" ++
        "  removed by current elision : {d} ({d}% of raw traffic)\n" ++
        "  elide_count (pairs the pass reported removing) : {d}\n" ++
        "  BORROW-SKIP CANDIDATE PAIRS (intra-block, borrow-only region) : {d}\n" ++
        "    -> would remove ~{d} ARC calls = {d}% of surviving traffic (static, intra-block LOWER bound)\n" ++
        "  BORROW-SKIP CANDIDATE PAIRS (function-scope, inter-block) : {d}\n" ++
        "    -> would remove ~{d} ARC calls (retain whose value is borrow-only across the whole fn)\n" ++
        "=== end ARC-traffic census ===\n",
        .{ census_retain_before, r_after, census_release_before, rel_after, before, after, removed, pct, elide_count, borrow_skip, borrow_skip * 2, bs_pct, borrow_skip_fn, borrow_skip_fn * 2 },
    );
}

/// Global toggle: whether value-struct semantics (inline storage + deep copy)
/// are active in codegen. Read by the value-struct paths across codegen.
pub var value_structs_enabled: bool = false;
/// When set, ALL structs are treated as value structs, ignoring
/// [`value_type_set`]; the opt-in "everything is a value" mode.
pub var value_structs_all: bool = false;
/// The explicit set of type names to treat as value structs when
/// [`value_structs_all`] is false; null means "none selected". Owned elsewhere.
pub var value_type_set: ?std.StringHashMap(void) = null;

/// Global flag: emit AddressSanitizer-friendly codegen (the `--asan` gate).
/// Consulted by memory-emitting paths to add ASAN instrumentation hooks.
pub var asan_codegen_enabled: bool = false;

/// Returns the callee symbol name of a call instruction, or null if `inst` is
/// not a call or the callee is anonymous.
///
/// The callee is the LAST operand of an LLVM call. Underpins [`isNamedCall`],
/// which every elision/verifier pass uses to recognise `kyte_retain`/`kyte_release`.
fn callTargetName(inst: types.LLVMValueRef) ?[]const u8 {
    if (core.LLVMGetInstructionOpcode(inst) != .LLVMCall) return null;
    const n = core.LLVMGetNumOperands(inst);
    if (n < 1) return null;
    const callee = core.LLVMGetOperand(inst, @intCast(n - 1));
    var len: usize = 0;
    const name_c = core.LLVMGetValueName2(callee, &len);
    if (len == 0) return null;
    return name_c[0..len];
}

/// True if `inst` is a direct call to the function named `want`.
///
/// The recogniser for `kyte_retain`/`kyte_release` (and `kyte_bytes_free`)
/// throughout the passes; built on [`callTargetName`].
fn isNamedCall(inst: types.LLVMValueRef, want: []const u8) bool {
    const nm = callTargetName(inst) orelse return false;
    return std.mem.eql(u8, nm, want);
}

/// Recognises the exact IR shape of "a field loaded out of a borrowed
/// parameter": `ptrtoint(load(inttoptr(add(load(param_slot), offset))))`.
///
/// [`elideBorrowedArcInFn`] uses this to prove a value came from reading a field
/// of a by-reference parameter (which the caller still owns), so a local
/// retain/release around it is redundant and safe to drop. It walks the exact
/// instruction chain and, at the base, checks the loaded pointer originates from
/// one of the function's known parameter slots (`param_slots`); any deviation
/// returns false (conservative).
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

/// Returns the `kyte_retain` instruction that retains `sv`, if any, else null.
///
/// Scans the uses of `sv` for a retain call. Used by the balance verifier and
/// the borrow-elider to pair a stored value with the retain that acquired it.
fn valueIsRetained(sv: types.LLVMValueRef) ?types.LLVMValueRef {
    var use = core.LLVMGetFirstUse(sv);
    while (use != null) : (use = core.LLVMGetNextUse(use)) {
        const user = core.LLVMGetUser(use);
        if (isNamedCall(user, "kyte_retain")) return user;
    }
    return null;
}

/// Runs the two ARC-elision passes over every function in the module.
///
/// A no-op unless [`elide_enabled`]. Per function it runs
/// [`elideBorrowedArcInFn`] (drop retain/release around a borrowed-parameter
/// field) then [`elideRedundantPairsInFn`] (drop an adjacent retain/release of
/// the same value). Both only remove provably-safe pairs, keeping ARC balance
/// intact while cutting traffic.
pub fn elideBorrowedArc(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
    if (!elide_enabled) return;
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        elideBorrowedArcInFn(self, fnv);
        elideRedundantPairsInFn(self, fnv);
    }
}

/// Enables the ARC release-balance self-verifier (`KYTE_OWN_VERIFY`); off by
/// default. See [`verifyArcBalance`].
pub var balance_verify: bool = false;
/// When set, a detected imbalance is FATAL (`std.process.exit(1)`) rather than
/// just reported: the fail-closed gate mode used in CI.
pub var balance_hard: bool = false;

/// Tally accumulated by the ARC balance verifier across a module.
const BalanceReport = struct {
    /// Number of defined functions examined.
    fns: usize = 0,
    /// Owned local slots the verifier could reason about (proved non-escaping and
    /// acquired via a retain).
    checkable_slots: usize = 0,
    /// Checkable slots whose acquire count did not equal its release count: each
    /// is a codegen leak or double-free.
    imbalanced: usize = 0,
    /// Slots skipped conservatively because their use pattern was too complex to
    /// prove balanced.
    skipped: usize = 0,
    /// Name of the first imbalanced function, for the report line.
    first: []const u8 = "",
};

/// Verifies that every provably non-escaping owned slot is ARC-balanced, and
/// prints a report; optionally aborts the compile on any imbalance.
///
/// A no-op unless [`balance_verify`]. This is a self-check on the compiler's OWN
/// output: for each function it runs [`verifyArcBalanceInFn`], accumulating a
/// [`BalanceReport`], and prints the totals. An imbalance means acquires !=
/// releases on a slot that cannot escape, i.e. a leak or double-free THIS
/// codegen emitted. When [`balance_hard`] is set, a non-zero imbalance count
/// exits the process with status 1 (the fail-closed gate).
pub fn verifyArcBalance(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
    if (!balance_verify) return;
    var rep = BalanceReport{};
    var fnv = core.LLVMGetFirstFunction(module);
    while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
        if (core.LLVMIsDeclaration(fnv) != 0) continue;
        rep.fns += 1;
        verifyArcBalanceInFn(self, fnv, &rep);
    }
    std.debug.print(
        "=== ARC release-balance verifier (KYTE_OWN_VERIFY, V4' slice 1) ===\n" ++
        "  functions (defined)     : {d}\n" ++
        "  checkable owned slots   : {d}   (proved non-escaping + owned-via-retain)\n" ++
        "  skipped (conservative)  : {d}\n" ++
        "  BALANCE IMBALANCES      : {d}\n",
        .{ rep.fns, rep.checkable_slots, rep.skipped, rep.imbalanced },
    );
    if (rep.imbalanced > 0) std.debug.print("    first imbalanced fn: {s}\n", .{rep.first});
    std.debug.print("=== end ARC release-balance verifier ===\n", .{});
    if (balance_hard and rep.imbalanced > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mARC BALANCE VERIFIER FAILED:\x1b[0m {d} non-escaping owned slot(s) with acquires != releases (leak or double-free in codegen).\n",
            .{rep.imbalanced},
        );
        std.process.exit(1);
    }
}

/// True if a stored value is used only in ways that keep it LOCAL to its slot:
/// retained, compared, or re-stored into the same slot.
///
/// Guards the balance verifier from counting an acquire on a value that also
/// leaks out through some other use: any use other than a retain, an `icmp`, or
/// the store back into `slot` disqualifies it (returns false), so the slot is
/// treated as escaping and left unchecked.
fn storedValueStaysLocal(sv: types.LLVMValueRef, slot: types.LLVMValueRef) bool {
    var use = core.LLVMGetFirstUse(sv);
    while (use != null) : (use = core.LLVMGetNextUse(use)) {
        const user = core.LLVMGetUser(use);
        if (isNamedCall(user, "kyte_retain")) continue;
        if (core.LLVMGetInstructionOpcode(user) == .LLVMICmp) continue;
        if (core.LLVMGetInstructionOpcode(user) == .LLVMStore and core.LLVMGetOperand(user, 0) == sv and core.LLVMGetOperand(user, 1) == slot) continue;
        return false;
    }
    return true;
}

/// Verifies ARC balance for the alloca slots of a single function, updating
/// `rep`.
///
/// For each alloca it counts acquires and releases by walking the slot's uses:
/// a store of a retained value that stays local ([`storedValueStaysLocal`])
/// counts an acquire; a load whose users are only release/retain/compare counts
/// releases and acquires accordingly. Any pattern it cannot fully account for
/// (a store OF the slot address, a call consuming the value, an unexpected use)
/// marks the slot non-checkable and it is skipped. A checkable slot with at
/// least one acquire but acquires != releases is recorded as an imbalance (leak
/// if acquires > releases, double-free if fewer). Conservative by design: it
/// only flags what it can prove, so it never false-positives on a slot it does
/// not fully understand. `self` is unused.
fn verifyArcBalanceInFn(self: *LlvmCompiler, fnv: types.LLVMValueRef, rep: *BalanceReport) void {
    _ = self;
    var bb = core.LLVMGetFirstBasicBlock(fnv);
    while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
        var inst = core.LLVMGetFirstInstruction(bb);
        while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
            if (core.LLVMIsAAllocaInst(inst) == null) continue;
            const slot = inst;
            var acquires: usize = 0;
            var releases: usize = 0;
            var checkable = true;

            var use = core.LLVMGetFirstUse(slot);
            scan: while (use != null) : (use = core.LLVMGetNextUse(use)) {
                const user = core.LLVMGetUser(use);
                const opc = core.LLVMGetInstructionOpcode(user);
                if (opc == .LLVMStore and core.LLVMGetOperand(user, 1) == slot) {
                    const sv = core.LLVMGetOperand(user, 0);
                    if (core.LLVMIsAConstantInt(sv) != null) continue :scan;
                    if (valueIsRetained(sv) != null and storedValueStaysLocal(sv, slot)) {
                        acquires += 1;
                        continue :scan;
                    }
                    checkable = false;
                    break :scan;
                } else if (opc == .LLVMStore and core.LLVMGetOperand(user, 0) == slot) {
                    checkable = false;
                    break :scan;
                } else if (opc == .LLVMLoad and core.LLVMGetOperand(user, 0) == slot) {
                    var luse = core.LLVMGetFirstUse(user);
                    while (luse != null) : (luse = core.LLVMGetNextUse(luse)) {
                        const luser = core.LLVMGetUser(luse);
                        if (isNamedCall(luser, "kyte_release")) {
                            releases += 1;
                        } else if (isNamedCall(luser, "kyte_retain")) {
                            acquires += 1;
                        } else if (core.LLVMGetInstructionOpcode(luser) == .LLVMICmp) {
                        } else {
                            checkable = false;
                            break;
                        }
                    }
                    if (!checkable) break :scan;
                } else {
                    checkable = false;
                    break :scan;
                }
            }

            if (!checkable or acquires == 0) {
                if (acquires > 0 or !checkable) rep.skipped += 1;
                continue;
            }
            rep.checkable_slots += 1;
            if (acquires != releases) {
                rep.imbalanced += 1;
                if (rep.first.len == 0) rep.first = std.mem.span(core.LLVMGetValueName(fnv));
            }
        }
    }
}

/// True if any operand of `inst` is `v`.
///
/// A small operand scan used by the elision passes to decide whether an
/// instruction touches a tracked value before the matching release is reached.
fn instUsesValue(inst: types.LLVMValueRef, v: types.LLVMValueRef) bool {
    const n = core.LLVMGetNumOperands(inst);
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        if (core.LLVMGetOperand(inst, i) == v) return true;
    }
    return false;
}

/// Removes redundant intra-block retain/release pairs on the same value.
///
/// Within each basic block: for a `kyte_retain` of value `v`, it scans forward
/// to the first instruction that USES `v`; if that instruction is a
/// `kyte_release` of `v`, both the retain and the release are marked for
/// erasure (the +1/-1 cancel and nothing in between depended on the extra
/// count). An `erased` set stops a call being paired twice. Erasures are
/// deferred to a batch at the end so iteration is not disturbed. Increments
/// [`elide_count`] per pair removed.
fn elideRedundantPairsInFn(self: *LlvmCompiler, fnv: types.LLVMValueRef) void {
    const a = self.allocator;
    var to_erase = std.ArrayList(types.LLVMValueRef).empty;
    defer to_erase.deinit(a);
    var erased = std.AutoHashMap(types.LLVMValueRef, void).init(a);
    defer erased.deinit();

    var bb = core.LLVMGetFirstBasicBlock(fnv);
    while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
        var insts = std.ArrayList(types.LLVMValueRef).empty;
        defer insts.deinit(a);
        var inst = core.LLVMGetFirstInstruction(bb);
        while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) insts.append(a, inst) catch {};

        for (insts.items, 0..) |ri, i| {
            if (erased.contains(ri)) continue;
            if (!isNamedCall(ri, "kyte_retain")) continue;
            const v = core.LLVMGetOperand(ri, 0);
            var j = i + 1;
            while (j < insts.items.len) : (j += 1) {
                const uj = insts.items[j];
                if (erased.contains(uj)) continue;
                if (!instUsesValue(uj, v)) continue;
                if (isNamedCall(uj, "kyte_release") and core.LLVMGetOperand(uj, 0) == v) {
                    to_erase.append(a, ri) catch {};
                    to_erase.append(a, uj) catch {};
                    erased.put(ri, {}) catch {};
                    erased.put(uj, {}) catch {};
                    elide_count += 1;
                }
                break;
            }
        }
    }
    for (to_erase.items) |ins| core.LLVMInstructionEraseFromParent(ins);
}

/// Removes the retain/release around a local that merely holds a field read out
/// of a borrowed (by-reference) parameter.
///
/// The caller still owns that parameter for the whole call, so a field it
/// exposes does not need a local +1/-1. The pass first collects the allocas that
/// a parameter value is stored into (`param_slots`). Then, for each local
/// alloca, it verifies the ONLY owned store into it is a value that
/// [`tracesBorrowedParamField`] proves came from such a parameter field and was
/// retained ([`valueIsRetained`]), and that every load of the local flows only
/// into releases or non-consuming uses (a call taking it as the destructor-arg
/// position disqualifies). If exactly one such owned store is found and nothing
/// escapes, the retain and all the matching releases are erased. Conservative:
/// any unexpected use aborts that slot with the pair left intact.
fn elideBorrowedArcInFn(self: *LlvmCompiler, fnv: types.LLVMValueRef) void {
    const a = self.allocator;

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

    var to_erase = std.ArrayList(types.LLVMValueRef).empty;
    defer to_erase.deinit(a);

    bb = core.LLVMGetFirstBasicBlock(fnv);
    while (bb != null) : (bb = core.LLVMGetNextBasicBlock(bb)) {
        var inst = core.LLVMGetFirstInstruction(bb);
        while (inst != null) : (inst = core.LLVMGetNextInstruction(inst)) {
            if (core.LLVMIsAAllocaInst(inst) == null) continue;
            const slot = inst;

            var owned_store: ?types.LLVMValueRef = null;
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
                    const sv = core.LLVMGetOperand(user, 0);
                    if (core.LLVMIsAConstantInt(sv) != null) continue :scan;
                    if (tracesBorrowedParamField(sv, param_slots.items)) {
                        if (valueIsRetained(sv)) |r| {
                            owned_store = sv;
                            retain_inst = r;
                            owned_store_count += 1;
                            continue :scan;
                        }
                    }
                    ok = false;
                    break :scan;
                } else if (opc == .LLVMStore and core.LLVMGetOperand(user, 0) == slot) {
                    ok = false;
                    break :scan;
                } else if (opc == .LLVMLoad and core.LLVMGetOperand(user, 0) == slot) {
                    var luse = core.LLVMGetFirstUse(user);
                    while (luse != null) : (luse = core.LLVMGetNextUse(luse)) {
                        const luser = core.LLVMGetUser(luse);
                        const lopc = core.LLVMGetInstructionOpcode(luser);
                        if (lopc == .LLVMICmp) continue;
                        if (isNamedCall(luser, "kyte_release")) {
                            releases.append(a, luser) catch {};
                            continue;
                        }
                        if (lopc == .LLVMCall) {
                            const n = core.LLVMGetNumOperands(luser);
                            if (n >= 1 and core.LLVMGetOperand(luser, @intCast(n - 1)) == user) {
                                ok = false;
                                break :scan;
                            }
                            continue;
                        }
                        ok = false;
                        break :scan;
                    }
                } else {
                    ok = false;
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

// Unit test pinning [`isUntypeablePlaceholder`]'s whole-string-only rule: the
// sentinel placeholders match, but real type names and composite types that
// merely CONTAIN a placeholder substring (function types, generics, tuples) do
// not. Guards against a regression where the fail-closed abort would fire on a
// legitimately typed value.
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
