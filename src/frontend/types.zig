
const std = @import("std");
const symbols = @import("sema/symbols.zig");

pub const SymbolId = symbols.SymbolId;

pub const TypeId = enum(u32) { _ };

pub const PrimKind = enum { bool, int, float, void_ };

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

pub const TypeParam = struct {
    owner: SymbolId,
    index: u32,
};

pub const ErrorUnionType = struct { ok: TypeId, err: TypeId };

pub const Type = union(enum) {
    prim: PrimType,
    string,

    decimal,

    ptr,
    // `any` -- a type-erased OWNING carrier. Distinct from `ptr` (unowned/manual) so the ownership machinery
    // releases it. At runtime an `any` value is a refcounted `nova_any_box { payload, dtor }`.
    any_,
    struct_: StructType,
    enum_: SymbolId,
    trait_: SymbolId,
    func: FuncType,
    optional: TypeId,

    error_union: ErrorUnionType,
    tuple: []const TypeId,
    array: ArrayType,
    type_param: TypeParam,

    storage: TypeId,

    future: TypeId,

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
        .string, .decimal, .ptr, .any_, .unresolved => {},
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
        .string, .decimal, .ptr, .any_, .unresolved => true,
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

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayListUnmanaged(Type) = .empty,
    map: std.HashMapUnmanaged(Type, TypeId, TypeContext, std.hash_map.default_max_load_percentage) = .empty,
    owned_slices: std.ArrayListUnmanaged([]TypeId) = .empty,

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

    pub fn setEnumTagged(self: *TypeStore, sid: SymbolId, tagged: bool) !void {
        try self.enum_tagged.put(self.allocator, sid, tagged);
    }

    fn ownIds(self: *TypeStore, ids: []const TypeId) ![]const TypeId {
        if (ids.len == 0) return &.{};
        const copy = try self.allocator.dupe(TypeId, ids);
        try self.owned_slices.append(self.allocator, copy);
        return copy;
    }

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
    // f64x4 SIMD vector, encoded as a 256-bit float prim (renders to "f64x4"); slot type <4 x double>.
    pub fn vecF64x4T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 256 } });
    }
    // FR-simd-L1 integer vectors. All three are 128-bit and would collide on total bits, so they are
    // encoded with a bijective sentinel in the `bits` field: bits = elementBits*1000 + laneCount. This
    // never collides with a real integer type (max real width is 64) and is decoded back to a name
    // ("u8x16" etc.) in renderLegacy and to an LLVM vector type in the codegen slot picker.
    pub fn vecU8x16T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 8 * 1000 + 16, .signed = false } });
    }
    pub fn vecU32x4T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32 * 1000 + 4, .signed = false } });
    }
    pub fn vecU64x2T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 64 * 1000 + 2, .signed = false } });
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
    pub fn anyT(self: *TypeStore) !TypeId {
        return self.intern(.any_);
    }
    pub fn unresolvedT(self: *TypeStore) !TypeId {
        return self.intern(.unresolved);
    }

    pub fn isOwned(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .prim, .ptr => false,
            .any_ => true,
            .string, .decimal, .struct_, .array, .tuple => true,

            .error_union => true,
            .func => true,

            .trait_ => true,

            .enum_ => |sid| self.enum_tagged.get(sid) orelse false,

            .future => false,

            .storage => true,
            .optional => |inner| self.isOwned(inner),
            .type_param => unreachable,
            .unresolved => unreachable,
        };
    }

    pub fn isOwnedSafe(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .type_param, .unresolved => false,
            .optional => |inner| self.isOwnedSafe(inner),
            else => self.isOwned(id),
        };
    }
};

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
    try testing.expect(try s.intT() != try s.longT());
    try testing.expect(try s.intT() != try s.uintT());
    try testing.expect(try s.doubleT() != try s.floatT());
    try testing.expect(try s.stringT() != try s.ptrT());
}

test "signedness is carried, not spelled — u64 is NOT i64" {

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

    try testing.expectEqual(list_str, try s.intern(.{ .struct_ = .{ .decl = list_decl, .args = &.{str} } }));
}

test "a function is a TYPE, not a name containing an arrow" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    const int = try s.intT();
    const str = try s.stringT();
    const f1 = try s.intern(.{ .func = .{ .params = &.{int}, .ret = int } });
    const f2 = try s.intern(.{ .func = .{ .params = &.{int}, .ret = str } });
    const f3 = try s.intern(.{ .func = .{ .params = &.{ int, int }, .ret = int } });
    try testing.expect(f1 != f2);
    try testing.expect(f1 != f3);
    try testing.expectEqual(f1, try s.intern(.{ .func = .{ .params = &.{int}, .ret = int } }));

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

    try testing.expect(t0 != t1);
    try testing.expect(t0 != b_t0);
}

test "T4: unresolved is representable and is NOT int" {

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
    try testing.expect(s.isOwned(opt_str));
    const opt_int = try s.intern(.{ .optional = try s.intT() });
    try testing.expect(!s.isOwned(opt_int));
}

test "ownership is decided from the TYPE, never a spelling" {
    var s = TypeStore.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.isOwned(try s.intT()));
    try testing.expect(!s.isOwned(try s.ptrT()));
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
    scratch[0] = try s.stringT();
    try testing.expectEqual(int, s.get(t).tuple[0]);
}
