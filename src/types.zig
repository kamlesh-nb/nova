// types.zig — F2 stage 1: a type is a VALUE, not a spelling.
//
// This file was 0 bytes. That emptiness was the architecture problem: Nova had no
// representation between the AST and LLVM, so every semantic question — is this
// refcounted? is this a function? how wide is it? — was answered by
// pattern-matching on the SPELLING of a type name at codegen time, with a
// hardcoded escape hatch wherever the string didn't carry enough information:
//
//     arc.zig:11   isRefCountedType(self, type_name: []const u8) bool
//                    "T"            -> hardcoded false   (a generic param)
//                    contains "=>"  -> hardcoded false   (a function)
//
// Those hardcodes are not oversights. They are the only possible answers when the
// type is not known. The function cannot be fixed; its SIGNATURE is the defect.
// See docs/design/F2-typed-ir.md.
//
// STAGE 1 IS PURE ADDITION. Nothing imports this yet (the `types.zig` imports
// elsewhere all resolve to src/codegen/types.zig, a module of string functions).
// It is built and unit-tested on its own, then wired in stage 2 under a shadow
// diff — the same discipline that made F1's three cutovers uneventful.
//
// The invariants this file makes STRUCTURAL rather than hoped-for:
//
//   T1  A type is a value. TypeId equality IS type equality (interning), so
//       `mem.eql` on a type name never decides semantics again.
//   T4  Unknown is REPRESENTABLE and distinct. `.unresolved` is a type you can
//       hold and test. Today `resolveExpressionTypeName` returns "i32" on failure
//       and `i32` IS the universal machine word — so "unknown" and "int" are
//       literally the same value, and every inference failure silently becomes a
//       valid-looking one. That is why Nova's defects are quiet.
//
// And two things that simply become UNREPRESENTABLE:
//   * `.func` is a real type -> `indexOf(name, "=>")` cannot be written.
//   * `.type_param{owner,index}` is a real type -> `name.len == 1 and 'A'..'Z'`
//     cannot be written, and F4 substitutes by INDEX rather than by the hardcoded
//     letters T/K/V/U (llvm_codegen.zig:2345-2355).
const std = @import("std");
const symbols = @import("sema/symbols.zig");

pub const SymbolId = symbols.SymbolId;

/// An interned type. Equality of TypeId IS equality of type — that is the whole
/// point (T1). Never compare types any other way.
pub const TypeId = enum(u32) { _ };

pub const PrimKind = enum { bool, int, float, void_ };

/// F3 owns the target table; F2 owns the representation. `bits` and `signed` are
/// carried, never spelled — which is what makes `castFromValType`'s always-sext
/// (codegen/types.zig:118) unrepresentable rather than a bug.
pub const PrimType = struct {
    kind: PrimKind,
    bits: u16,
    signed: bool = true,

    pub fn eql(a: PrimType, b: PrimType) bool {
        return a.kind == b.kind and a.bits == b.bits and a.signed == b.signed;
    }
};

pub const StructType = struct {
    decl: SymbolId,
    /// Non-empty = an INSTANTIATION. `List<string>` and `List<int>` are therefore
    /// distinct TypeIds — the precondition F4 needs, and that `getStructBaseName`
    /// (codegen/types.zig:9) currently destroys by stripping `<...>` at every
    /// lookup.
    args: []const TypeId = &.{},
};

pub const FuncType = struct {
    params: []const TypeId,
    ret: TypeId,
};

pub const ArrayType = struct {
    elem: TypeId,
    len: usize,
};

/// A generic parameter is a TYPE with an owner and an index — not the letter "T".
pub const TypeParam = struct {
    owner: SymbolId,
    index: u32,
};

pub const ErrorUnionType = struct { ok: TypeId, err: TypeId };

pub const Type = union(enum) {
    prim: PrimType,
    string,
    /// specs §3.1: IEEE 754-2008 decimal128 (BID). A 16-byte ARC-managed HEAP object — the slot holds a
    /// pointer, exactly like `string` — so it is owned, nullary, and equal-by-tag. Distinct from `string`
    /// so `decimal`'s literals/`toString`/arithmetic route to the decimal128 runtime, not the string path.
    decimal,
    /// Opaque, word-sized, explicitly UNOWNED (F3 §3.2 / F5 O2). Not an integer:
    /// this is the honest replacement for `data: i32`.
    ptr,
    struct_: StructType,
    enum_: SymbolId,
    trait_: SymbolId,
    func: FuncType,
    optional: TypeId,
    /// `T | E` — an ERROR UNION (specs §3.4b). Exactly one of the two, never both: unlike Go's
    /// `(T, error)` there is no nil-error slot to forget to check, and unlike `optional` (which
    /// is a 0 SENTINEL) the error side is a real value, so this needs a real discriminant.
    ///
    /// `ok` may itself be `.optional` — that is `T | E | undefined`, the 404-vs-500 shape where
    /// absence and failure are different outcomes.
    error_union: ErrorUnionType,
    tuple: []const TypeId,
    array: ArrayType,
    type_param: TypeParam,
    /// `Storage<T>` — N contiguous slots of T (specs.md §3.8). THE container
    /// primitive: it exists so ARC can see through a collection to its elements.
    ///
    /// A real type rather than a struct in the symbol table, because it has no
    /// declaration to point at — it IS the buffer, with §3.2's header. The slot
    /// count lives in that header ([ptr-4] / 8), not in a field.
    storage: TypeId,
    /// `go f()` yields `future<T>` (specs.md 7.1). It exists so `await` has
    /// something to unwrap — without it a handle carries no link to the async fn's
    /// return type and `await h` is untypeable BY CONSTRUCTION.
    ///
    /// Represented as a bare i64 at runtime, and the spec stores handles in
    /// `List<i64>`, so this is a type-level fact only. The alternative — typing a
    /// handle AS its eventual value, which the legacy resolver does — makes `h + 1`
    /// CORRECT rather than merely unchecked, and that is the machine-word lie F3
    /// exists to kill.
    future: TypeId,
    /// T4. An explicit "I do not know" that is NOT silently a valid type. An error
    /// at the end of sema; an assert if it ever reaches codegen.
    unresolved,
};

fn hashType(t: Type) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{@intFromEnum(std.meta.activeTag(t))});
    switch (t) {
        .prim => |p| {
            h.update(&[_]u8{@intFromEnum(p.kind)});
            h.update(std.mem.asBytes(&p.bits));
            h.update(&[_]u8{@intFromBool(p.signed)});
        },
        .string, .decimal, .ptr, .unresolved => {},
        .error_union => |eu| {
            h.update(std.mem.asBytes(&eu.ok));
            h.update(std.mem.asBytes(&eu.err));
        },
        .struct_ => |s| {
            var d = @intFromEnum(s.decl);
            h.update(std.mem.asBytes(&d));
            for (s.args) |a| {
                var v = @intFromEnum(a);
                h.update(std.mem.asBytes(&v));
            }
        },
        .enum_ => |sid| {
            var v = @intFromEnum(sid);
            h.update(std.mem.asBytes(&v));
        },
        .trait_ => |sid| {
            var v = @intFromEnum(sid);
            h.update(std.mem.asBytes(&v));
        },
        .func => |f| {
            for (f.params) |p| {
                var v = @intFromEnum(p);
                h.update(std.mem.asBytes(&v));
            }
            var r = @intFromEnum(f.ret);
            h.update(std.mem.asBytes(&r));
        },
        .optional => |inner| {
            var v = @intFromEnum(inner);
            h.update(std.mem.asBytes(&v));
        },
        // future<T> hashes on T, and the tag byte above keeps it distinct from
        // optional<T> — otherwise `future<int>` and `int | undefined` would collide.
        .future => |inner| {
            var v = @intFromEnum(inner);
            h.update(std.mem.asBytes(&v));
        },
        .storage => |inner| {
            var v = @intFromEnum(inner);
            h.update(std.mem.asBytes(&v));
        },
        .tuple => |items| for (items) |i| {
            var v = @intFromEnum(i);
            h.update(std.mem.asBytes(&v));
        },
        .array => |a| {
            var e = @intFromEnum(a.elem);
            h.update(std.mem.asBytes(&e));
            var l = a.len;
            h.update(std.mem.asBytes(&l));
        },
        .type_param => |tp| {
            var o = @intFromEnum(tp.owner);
            h.update(std.mem.asBytes(&o));
            var i = tp.index;
            h.update(std.mem.asBytes(&i));
        },
    }
    return h.final();
}

fn eqlIds(a: []const TypeId, b: []const TypeId) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn eqlType(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .prim => |p| p.eql(b.prim),
        .string, .decimal, .ptr, .unresolved => true,
        .struct_ => |s| s.decl == b.struct_.decl and eqlIds(s.args, b.struct_.args),
        .enum_ => |x| x == b.enum_,
        .error_union => |eu| eu.ok == b.error_union.ok and eu.err == b.error_union.err,
        .trait_ => |x| x == b.trait_,
        .func => |f| f.ret == b.func.ret and eqlIds(f.params, b.func.params),
        .optional => |x| x == b.optional,
        .future => |x| x == b.future,
        .storage => |x| x == b.storage,
        .tuple => |items| eqlIds(items, b.tuple),
        .array => |ar| ar.elem == b.array.elem and ar.len == b.array.len,
        .type_param => |tp| tp.owner == b.type_param.owner and tp.index == b.type_param.index,
    };
}

const TypeContext = struct {
    pub fn hash(_: TypeContext, t: Type) u64 {
        return hashType(t);
    }
    pub fn eql(_: TypeContext, a: Type, b: Type) bool {
        return eqlType(a, b);
    }
};

/// Interning table. `intern` is the ONLY way to make a TypeId, which is what
/// guarantees T1: two structurally equal types always get the same id, so `a == b`
/// on TypeIds is exact type equality with no traversal.
pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayListUnmanaged(Type) = .empty,
    map: std.HashMapUnmanaged(Type, TypeId, TypeContext, std.hash_map.default_max_load_percentage) = .empty,
    owned_slices: std.ArrayListUnmanaged([]TypeId) = .empty,
    /// F2-6 enum-variant awareness: is the enum identified by this SymbolId a TAGGED UNION (>=1
    /// payload-carrying variant, so its values are heap boxes and OWNED) vs a payload-less enum (an
    /// immediate integer tag, NOT owned)? Populated once by sema from the enum declarations, so
    /// `isOwned(.enum_)` can decide correctly instead of the coarse `false`. An enum absent from the
    /// table reads as non-owned (conservative — the same answer the old blanket `false` gave).
    enum_tagged: std.AutoHashMapUnmanaged(SymbolId, bool) = .empty,

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TypeStore) void {
        for (self.owned_slices.items) |s| self.allocator.free(s);
        self.owned_slices.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.enum_tagged.deinit(self.allocator);
    }

    /// F2-6: record whether an enum (by SymbolId) is a tagged union (a payload-carrying variant exists).
    /// Called by sema once the enum declarations are known, before any `isOwned(.enum_)` decision.
    pub fn setEnumTagged(self: *TypeStore, sid: SymbolId, tagged: bool) !void {
        try self.enum_tagged.put(self.allocator, sid, tagged);
    }

    fn ownIds(self: *TypeStore, ids: []const TypeId) ![]const TypeId {
        if (ids.len == 0) return &.{};
        const copy = try self.allocator.dupe(TypeId, ids);
        try self.owned_slices.append(self.allocator, copy);
        return copy;
    }

    /// Take ownership of any slices the type carries, so an interned Type never
    /// points at caller memory.
    fn own(self: *TypeStore, t: Type) !Type {
        return switch (t) {
            .struct_ => |s| Type{ .struct_ = .{ .decl = s.decl, .args = try self.ownIds(s.args) } },
            .func => |f| Type{ .func = .{ .params = try self.ownIds(f.params), .ret = f.ret } },
            .tuple => |items| Type{ .tuple = try self.ownIds(items) },
            else => t,
        };
    }

    pub fn intern(self: *TypeStore, t: Type) !TypeId {
        if (self.map.getContext(t, TypeContext{})) |existing| return existing;
        const owned = try self.own(t);
        const id: TypeId = @enumFromInt(@as(u32, @intCast(self.types.items.len)));
        try self.types.append(self.allocator, owned);
        try self.map.putContext(self.allocator, owned, id, TypeContext{});
        return id;
    }

    pub fn get(self: *const TypeStore, id: TypeId) Type {
        return self.types.items[@intFromEnum(id)];
    }

    pub fn count(self: *const TypeStore) usize {
        return self.types.items.len;
    }

    // ---- convenience: F3's target table, honest by construction -------------
    pub fn boolT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .bool, .bits = 1, .signed = false } });
    }
    pub fn intT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32, .signed = true } });
    }
    pub fn uintT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32, .signed = false } });
    }
    pub fn longT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 64, .signed = true } });
    }
    pub fn byteT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 8, .signed = false } });
    }
    pub fn doubleT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 64 } });
    }
    pub fn floatT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 32 } });
    }
    pub fn voidT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .void_, .bits = 0 } });
    }
    pub fn stringT(self: *TypeStore) !TypeId {
        return self.intern(.string);
    }
    pub fn decimalT(self: *TypeStore) !TypeId {
        return self.intern(.decimal);
    }
    pub fn ptrT(self: *TypeStore) !TypeId {
        return self.intern(.ptr);
    }
    pub fn unresolvedT(self: *TypeStore) !TypeId {
        return self.intern(.unresolved);
    }

    /// F5 §3.2, the corrected `isRefCountedType`. Ownership is a property of a
    /// TYPE, not of a spelling. The two `unreachable`s are the whole point: they
    /// are the hardcodes at arc.zig:13-15 and :19-20, made unrepresentable rather
    /// than answered wrongly.
    pub fn isOwned(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .prim, .ptr => false,
            .string, .decimal, .struct_, .array, .tuple => true,
            // specs §3.4b: a `T | E` is a heap box that OWNS its payload (built by
            // `buildErrUnion`, released by `__destruct_ErrUnion_*` branching on the tag).
            // Owned regardless of what the two sides are: the BOX is the allocation.
            .error_union => true,
            .func => true, // a closure box IS owned — fixes §10 #15
            // A trait object is an owned heap fat pointer `{struct_ptr, vtable}` that CO-OWNS its
            // struct (§3.4f). Retaining/releasing it is correct — the trait destructor releases the
            // wrapped struct. `.trait_ => false` was WRONG (measured: it diverged from
            // `isRefCountedType`, whose catch-all rightly says a trait is owned).
            .trait_ => true,
            // F2-6 enum-variant awareness (the follow-up the old `=> false` deferred): a PAYLOAD-carrying
            // enum (`JsonValue`, error-side enums) is a heap box owning its payload and IS owned; a
            // payload-less enum (`Color.Red`) is an immediate tag and is not. The `enum_tagged` side
            // table — populated by sema from the enum declarations — answers this without the store
            // needing the whole symbol table. An enum absent from the table (never declared to sema)
            // reads non-owned, exactly the answer the old blanket `false` gave, so this only ever makes
            // a KNOWN payload enum owned — closing the keystone gap the disposition oracle tracked.
            .enum_ => |sid| self.enum_tagged.get(sid) orelse false,
            // A `go` handle is a bare i64 (specs 7.1) — NOT a heap value. Retaining
            // it would call ARC on an integer; releasing it would decrement whatever
            // that integer happens to address.
            .future => false,
            // A Storage IS a heap object and IS owned — that is the whole point:
            // `data: Storage<T>` is a typed field, so ARC releases it by the
            // mechanism that already works, and its destructor releases the slots.
            .storage => true,
            .optional => |inner| self.isOwned(inner),
            .type_param => unreachable, // F4 substituted it (G5)
            .unresolved => unreachable, // F2 T4: never reaches codegen
        };
    }

    /// Sema-time variant of `isOwned` that tolerates an un-substituted type. While a generic body
    /// is still generic, the CHECKER legitimately holds `.type_param` (unbound) and `.unresolved`
    /// types that `isOwned`'s substitution-invariant `unreachable`s forbid. Here they read as
    /// NON-owned — the principled erasure rule (an unbound param is a machine word until
    /// monomorphized) — recursing through `.optional` so a nested `?T` is handled too. Used by the
    /// F2-6 disposition oracle (`ownedDisposition`), which runs on the still-generic checker IR.
    pub fn isOwnedSafe(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .type_param, .unresolved => false,
            .optional => |inner| self.isOwnedSafe(inner),
            else => self.isOwned(id),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests — these encode F2's invariants, so a violation is a failing test rather
// than a comment.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "T1: interning is idempotent — same type, same id" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const a = try s.intT();
    const b = try s.intT();
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "T1: TypeId equality IS type equality" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    try testing.expect(try s.intT() != try s.longT()); // 32 vs 64 bits
    try testing.expect(try s.intT() != try s.uintT()); // signed vs unsigned
    try testing.expect(try s.doubleT() != try s.floatT());
    try testing.expect(try s.stringT() != try s.ptrT());
}

test "signedness is carried, not spelled — u64 is NOT i64" {
    // type_checker.zig:790's canonicalizeTypeName maps u32->i32, so the checker
    // literally cannot tell them apart. Here it is structural.
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const i64_t = try s.intern(.{ .prim = .{ .kind = .int, .bits = 64, .signed = true } });
    const u64_t = try s.intern(.{ .prim = .{ .kind = .int, .bits = 64, .signed = false } });
    try testing.expect(i64_t != u64_t);
}

test "F4 precondition: List<string> and List<int> are DISTINCT types" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const list_decl: SymbolId = @enumFromInt(7);
    const str = try s.stringT();
    const int = try s.intT();
    const list_str = try s.intern(.{ .struct_ = .{ .decl = list_decl, .args = &.{str} } });
    const list_int = try s.intern(.{ .struct_ = .{ .decl = list_decl, .args = &.{int} } });
    try testing.expect(list_str != list_int);
    // ...and interning again yields the same id (slices compared by value)
    try testing.expectEqual(list_str, try s.intern(.{ .struct_ = .{ .decl = list_decl, .args = &.{str} } }));
}

test "a function is a TYPE, not a name containing an arrow" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const int = try s.intT();
    const str = try s.stringT();
    const f1 = try s.intern(.{ .func = .{ .params = &.{int}, .ret = int } });
    const f2 = try s.intern(.{ .func = .{ .params = &.{int}, .ret = str } }); // different ret
    const f3 = try s.intern(.{ .func = .{ .params = &.{ int, int }, .ret = int } }); // different arity
    try testing.expect(f1 != f2);
    try testing.expect(f1 != f3);
    try testing.expectEqual(f1, try s.intern(.{ .func = .{ .params = &.{int}, .ret = int } }));
    // and it is OWNED — arc.zig:19-20 hardcodes false for these, which is §10 #15
    try testing.expect(s.isOwned(f1));
}

test "a generic param is a TYPE, not a one-letter string" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const owner_a: SymbolId = @enumFromInt(1);
    const owner_b: SymbolId = @enumFromInt(2);
    const t0 = try s.intern(.{ .type_param = .{ .owner = owner_a, .index = 0 } });
    const t1 = try s.intern(.{ .type_param = .{ .owner = owner_a, .index = 1 } });
    const b_t0 = try s.intern(.{ .type_param = .{ .owner = owner_b, .index = 0 } });
    // `T` and `U` of the SAME decl differ; `T` of two different decls differ.
    // substitutePlaceholders (llvm_codegen.zig:2345) hardcodes T/K/V/U and can
    // express neither — struct Foo<A,B> gets no substitution at all.
    try testing.expect(t0 != t1);
    try testing.expect(t0 != b_t0);
}

test "T4: unresolved is representable and is NOT int" {
    // The bug this prevents: resolveExpressionTypeName returns "i32" on failure,
    // and i32 IS the universal machine word — so "unknown" and "int" are the same
    // value and every inference failure silently looks correct.
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const unk = try s.unresolvedT();
    try testing.expect(unk != try s.intT());
    try testing.expect(unk != try s.ptrT());
    try testing.expectEqual(unk, try s.unresolvedT());
    try testing.expect(s.get(unk) == .unresolved);
}

test "optionals nest and compare structurally" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const str = try s.stringT();
    const opt_str = try s.intern(.{ .optional = str });
    try testing.expect(opt_str != str);
    try testing.expectEqual(opt_str, try s.intern(.{ .optional = str }));
    try testing.expect(s.isOwned(opt_str)); // an optional string is owned
    const opt_int = try s.intern(.{ .optional = try s.intT() });
    try testing.expect(!s.isOwned(opt_int)); // an optional int is not
}

test "ownership is decided from the TYPE, never a spelling" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.isOwned(try s.intT()));
    try testing.expect(!s.isOwned(try s.ptrT())); // ptr is explicitly unowned (F5 O2)
    try testing.expect(s.isOwned(try s.stringT()));
    const arr = try s.intern(.{ .array = .{ .elem = try s.intT(), .len = 4 } });
    try testing.expect(s.isOwned(arr));
}

test "arrays differ by element AND length" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const int = try s.intT();
    const a4 = try s.intern(.{ .array = .{ .elem = int, .len = 4 } });
    const a8 = try s.intern(.{ .array = .{ .elem = int, .len = 8 } });
    const s4 = try s.intern(.{ .array = .{ .elem = try s.stringT(), .len = 4 } });
    try testing.expect(a4 != a8);
    try testing.expect(a4 != s4);
}

test "tuples compare element-wise, and (a,b) != (b,a)" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const int = try s.intT();
    const str = try s.stringT();
    const ab = try s.intern(.{ .tuple = &.{ int, str } });
    const ba = try s.intern(.{ .tuple = &.{ str, int } });
    try testing.expect(ab != ba);
    try testing.expectEqual(ab, try s.intern(.{ .tuple = &.{ int, str } }));
}

test "interned types never alias caller memory" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const int = try s.intT();
    var scratch = [_]TypeId{int};
    const t = try s.intern(.{ .tuple = &scratch });
    scratch[0] = try s.stringT(); // mutate the caller's buffer after interning
    try testing.expectEqual(int, s.get(t).tuple[0]);
}
