//! Interned, structural type universe for the Kyte compiler front-end.
//!
//! Every type the compiler reasons about is represented here NOT as a string
//! ("List<int>", "string?", "i64") but as a value in the [`Type`] union that is
//! then *interned* into a [`TypeStore`] and referred to everywhere else by a
//! compact [`TypeId`]. The single most important invariant this file exists to
//! guarantee is: **two [`TypeId`]s are equal if and only if the two types are
//! structurally equal.** That collapses the whole "is this the same type?"
//! question, which recurs on every assignment, argument bind, generic
//! instantiation, and ARC decision, into an integer comparison.
//!
//! Why interning and not just carrying [`Type`] values around? Two reasons.
//! First, `List<int>` and `List<string>` MUST be distinct types (monomorphs are
//! not type-erased, see the compiler's mono pass), yet the same spelling might
//! be produced by many independent code paths; interning gives them one shared
//! identity so downstream passes compare ids, not deep trees. Second, ownership
//! for ARC is decided *from the type*, never from how it was spelled (see
//! [`TypeStore.isOwned`]), a policy the codebase is emphatic about because
//! deciding ownership from a type NAME is a known source of memory corruption.
//! An interned id is the stable handle that policy hangs off.
//!
//! Structural equality is realised by a custom hash-map context ([`TypeContext`]
//! over [`hashType`]/[`eqlType`]): the store keys a `Type -> TypeId` map on the
//! type's *shape*, so re-interning an equal shape returns the existing id
//! instead of allocating a new one. Composite types (struct args, function
//! params, tuples) carry slices; the store copies those slices into its own
//! arena on first intern ([`TypeStore.own`]) so an interned type can never alias
//! caller memory that later mutates or is freed.
//!
//! A few encodings here are deliberately compact and worth flagging: SIMD vector
//! primitives are smuggled through [`PrimType.bits`] with a `lanes*1000 + count`
//! scheme (see [`TypeStore.vecU8x16T`]) rather than adding a variant, and enum
//! ownership is not intrinsic to the [`Type`], it depends on whether the enum
//! carries a payload, which is recorded out-of-band in
//! [`TypeStore.enum_tagged`] and consulted by [`TypeStore.isOwned`].

const std = @import("std");
const symbols = @import("sema/symbols.zig");

/// Re-export of the symbol-table id type so callers depend on this module for
/// both type ids and the declaration ids that types reference (a `struct_`,
/// `enum_`, `trait_`, or `type_param` owner all name a symbol).
pub const SymbolId = symbols.SymbolId;

/// Opaque handle to an interned [`Type`], the compiler's universal "what type is
/// this?" token.
///
/// Backed by a `u32` index into [`TypeStore.types`], but declared as a
/// non-exhaustive enum so callers cannot fabricate one arithmetically or confuse
/// it with any other `u32`. Because the store interns structurally, equality of
/// two `TypeId`s is equality of the underlying types (see the module header).
pub const TypeId = enum(u32) { _ };

/// The four scalar families a [`PrimType`] can belong to.
///
/// `void_` is spelled with a trailing underscore because `void` is a Zig
/// keyword. There is no dedicated SIMD family: vector primitives reuse `int` and
/// `float` with an encoded lane count in [`PrimType.bits`].
pub const PrimKind = enum { bool, int, float, void_ };

/// A primitive scalar (or, via the bit-width encoding, a SIMD vector) type.
///
/// The triple `(kind, bits, signed)` is the complete identity, and it is carried
/// structurally rather than by name: `i64` and `u64` share `kind`/`bits` and
/// differ ONLY in `signed`, so signedness must be compared, never inferred from
/// how the type was written (see the "u64 is NOT i64" test). Ordinary widths use
/// `bits` literally (1 for bool, 8/32/64 for ints, 32/64 for floats); SIMD
/// vectors overload `bits` as `lanes*1000 + count`, see [`TypeStore.vecU8x16T`]
/// and its siblings.
pub const PrimType = struct {
    /// Which scalar family this is: [`PrimKind.bool`], `int`, `float`, or `void_`.
    kind: PrimKind,
    /// Bit width for scalars; for SIMD vectors, the overloaded `lanes*1000 +
    /// count` encoding produced by the `vec*T` helpers on [`TypeStore`].
    bits: u16,
    /// Signedness, meaningful only for [`PrimKind.int`]. Two int types that
    /// agree on `kind` and `bits` are still DISTINCT if this differs, which is
    /// what keeps `u64` and `i64` from interning to the same id.
    signed: bool = true,

    /// Structural equality of two primitives: identical family, width, and
    /// signedness. Used by [`eqlType`] for the `.prim` case.
    pub fn eql(a: PrimType, b: PrimType) bool {
        return a.kind == b.kind and a.bits == b.bits and a.signed == b.signed;
    }
};

/// A (possibly generic) named struct type: the declaration plus its type
/// arguments.
///
/// Because Kyte monomorphises rather than erasing, the `args` are part of the
/// identity: `List<int>` and `List<string>` share `decl` but differ in `args`
/// and therefore intern to different ids. A non-generic struct has empty `args`.
pub const StructType = struct {
    /// The struct declaration this type instantiates (a symbol-table id).
    decl: SymbolId,

    /// The type arguments applied to [`StructType.decl`], in declaration order;
    /// empty for a non-generic struct. Interned by value, the store copies this
    /// slice into its own storage so it never aliases caller memory.
    args: []const TypeId = &.{},
};

/// A function type: an ordered parameter list and a return type.
///
/// This is a structural type, not a name: two functions are the same type iff
/// their param sequences and return types match, so `(int)->int` differs from
/// both `(int)->string` and `(int,int)->int` (see the "a function is a TYPE"
/// test).
pub const FuncType = struct {
    /// The parameter types in order. Interned by value (copied into the store).
    params: []const TypeId,
    /// The return type.
    ret: TypeId,
};

/// A fixed-length array type, distinct per element type AND length.
///
/// `[int; 4]` and `[int; 8]` are different types, as are `[int; 4]` and
/// `[string; 4]`; both components participate in equality and hashing.
pub const ArrayType = struct {
    /// The element type.
    elem: TypeId,
    /// The compile-time-fixed element count.
    len: usize,
};

/// A reference to a generic type parameter, e.g. the `T` inside `List<T>`.
///
/// A type parameter is a first-class type, not a one-letter string: it is
/// identified by the declaration that introduced it (`owner`) plus its position
/// (`index`), so the `T` of one generic is never confused with the `T` of
/// another (see the "a generic param is a TYPE" test). It resolves to a concrete
/// type only through monomorphisation; until then [`TypeStore.isOwned`] treats
/// it as `unreachable`, since ownership cannot be decided for an unbound param.
pub const TypeParam = struct {
    /// The generic declaration that declares this parameter.
    owner: SymbolId,
    /// Zero-based position of this parameter in `owner`'s parameter list.
    index: u32,
};

/// The `T!E` result type: a success payload `ok` or an error payload `err`.
pub const ErrorUnionType = struct { ok: TypeId, err: TypeId };

/// The tagged union of every kind of type Kyte can represent.
///
/// Each variant is either payload-free (a singleton shape like `string` or
/// `unresolved` that interns to exactly one id) or carries the data that makes
/// instances distinct. This is the value hashed and compared by [`hashType`] and
/// [`eqlType`] to give types their structural identity; every reachable variant
/// must be handled in both, in [`TypeStore.own`] (for the ones carrying slices),
/// and in [`TypeStore.isOwned`] (for the ARC decision).
pub const Type = union(enum) {
    /// A primitive scalar or SIMD vector; see [`PrimType`].
    prim: PrimType,
    /// The built-in owned string type. Payload-free singleton; owned for ARC.
    string,

    /// Trusted, pre-escaped HTML markup. Payload-free singleton, represented at
    /// runtime EXACTLY as `string` (owned for ARC), but NOMINALLY distinct so the
    /// NSX interpolation `{expr}` can insert it raw while a plain `string` is
    /// HTML-escaped (the XSS boundary). Produced by NSX `<...>` literals and by
    /// `raw(s)`; coerces to `string` (see the front-end checker's `assignable`).
    html,

    /// The exact-precision `decimal` type. Payload-free singleton; owned for ARC.
    decimal,

    /// An opaque, non-owned raw pointer (`ptr`). Interior is not ARC-managed.
    ptr,
    /// The dynamic `any` type. Payload-free singleton; owned for ARC because it
    /// may box a heap value whose lifetime it manages.
    any_,
    /// A named, possibly-generic struct; see [`StructType`].
    struct_: StructType,
    /// A named enum, identified by its declaration. Ownership is NOT decided from
    /// this alone, it depends on whether the enum is payload-carrying, recorded
    /// in [`TypeStore.enum_tagged`].
    enum_: SymbolId,
    /// A trait (interface) type, identified by its declaration. Represented at
    /// runtime as a fat pointer, hence owned for ARC.
    trait_: SymbolId,
    /// A function type; see [`FuncType`].
    func: FuncType,
    /// An optional `T?`. Payload is the inner type; ownership is inherited from
    /// the inner type (see [`TypeStore.isOwned`]).
    optional: TypeId,

    /// The `T!E` error-union result type; see [`ErrorUnionType`].
    error_union: ErrorUnionType,
    /// A tuple, identified by its ordered element types. `(a,b)` differs from
    /// `(b,a)`. Interned by value (the slice is copied into the store).
    tuple: []const TypeId,
    /// A fixed-length array; see [`ArrayType`].
    array: ArrayType,
    /// An unbound generic parameter; see [`TypeParam`].
    type_param: TypeParam,

    /// A storage-engine-backed handle over an inner type. Owned for ARC.
    storage: TypeId,

    /// A `future<T>` produced by `spawn`. Payload is the awaited type; treated as
    /// NOT owned for ARC (the frame/join, not the payload, is what is managed).
    future: TypeId,

    /// The sentinel for a type not yet inferred. Distinct from every real type
    /// (notably NOT `int`), payload-free singleton; ownership queries on it are
    /// `unreachable` in [`TypeStore.isOwned`].
    unresolved,
};

/// Computes a structural hash of a [`Type`], the hash half of [`TypeContext`].
///
/// The active tag is mixed in first, then only the payload bytes that
/// participate in identity, so two structurally-equal types always hash the
/// same. It MUST stay in agreement with [`eqlType`]: any field the equality
/// function compares has to be fed here, or the interning map will place equal
/// types in different buckets and hand out duplicate ids. Payload-free variants
/// (`string`, `decimal`, `ptr`, `any_`, `unresolved`) contribute nothing beyond
/// the tag. Composite variants fold each referenced `TypeId`/`SymbolId` in by
/// its integer value.
fn hashType(t: Type) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{@intFromEnum(std.meta.activeTag(t))});
    switch (t) {
        .prim => |p| {
            h.update(&[_]u8{@intFromEnum(p.kind)});
            h.update(std.mem.asBytes(&p.bits));
            h.update(&[_]u8{@intFromBool(p.signed)});
        },
        .string, .html, .decimal, .ptr, .any_, .unresolved => {},
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

/// Element-wise equality of two `TypeId` slices (same length, same ids in the
/// same order), used to compare struct args, function params, and tuples.
fn eqlIds(a: []const TypeId, b: []const TypeId) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Structural equality of two [`Type`]s, the equality half of [`TypeContext`].
///
/// Differing active tags are unequal immediately; otherwise each variant's
/// identity-bearing payload is compared (primitives via [`PrimType.eql`],
/// slice-carrying variants via [`eqlIds`], the rest by direct id/field
/// comparison). Because interning guarantees a given shape has one id,
/// comparing the referenced ids by value is sufficient, there is no need to
/// recurse into the pointed-at types. Must stay in lockstep with [`hashType`].
fn eqlType(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .prim => |p| p.eql(b.prim),
        .string, .html, .decimal, .ptr, .any_, .unresolved => true,
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

/// Zero-size hash-map context that makes a `std.HashMapUnmanaged` key [`Type`]
/// values by structure rather than by bytes.
///
/// It simply forwards to [`hashType`]/[`eqlType`]; it exists because
/// `std.HashMapUnmanaged` requires a context type providing `hash`/`eql`, and a
/// `Type` cannot be auto-hashed (it contains slices, whose pointer identity must
/// NOT participate, only their contents). This is what turns the store's
/// `Type -> TypeId` map into the interning table.
const TypeContext = struct {
    /// Structural hash of a key; delegates to [`hashType`].
    pub fn hash(_: TypeContext, t: Type) u64 {
        return hashType(t);
    }
    /// Structural equality of two keys; delegates to [`eqlType`].
    pub fn eql(_: TypeContext, a: Type, b: Type) bool {
        return eqlType(a, b);
    }
};

/// The interning arena: the authoritative universe of types for one compilation.
///
/// It owns three things kept in sync: `types` maps a [`TypeId`] (its index) back
/// to the [`Type`]; `map` is the reverse [`Type`] -> [`TypeId`] lookup keyed
/// structurally by [`TypeContext`], which is what makes re-interning an equal
/// shape return the existing id; and `owned_slices` retains the copies of every
/// slice payload so interned composite types never dangle. Ids are dense and
/// stable for the store's lifetime, so callers may cache them freely. Not
/// thread-safe: intern from a single thread (the front-end is single-threaded
/// per compilation).
pub const TypeStore = struct {
    /// Allocator backing every internal collection and every owned slice copy.
    allocator: std.mem.Allocator,
    /// Id-indexed table of interned types; `types.items[@intFromEnum(id)]` is the
    /// [`Type`] for `id`, which is exactly what [`TypeStore.get`] returns.
    types: std.ArrayListUnmanaged(Type) = .empty,
    /// Structural reverse index `Type -> TypeId` that gives interning its
    /// idempotence; keyed by [`TypeContext`] so equal shapes collide.
    map: std.HashMapUnmanaged(Type, TypeId, TypeContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Retains store-owned copies of every slice payload (struct args, func
    /// params, tuple elements) so they can be freed in [`TypeStore.deinit`] and
    /// never alias transient caller memory; populated by [`TypeStore.ownIds`].
    owned_slices: std.ArrayListUnmanaged([]TypeId) = .empty,

    /// Out-of-band record of which enum declarations carry a payload, i.e. are
    /// "tagged". Ownership of an `enum_` type depends on this (a payload-carrying
    /// enum is owned), so [`TypeStore.isOwned`] consults it; absence means
    /// "not tagged" hence not owned. Populated via [`TypeStore.setEnumTagged`].
    enum_tagged: std.AutoHashMapUnmanaged(SymbolId, bool) = .empty,

    /// Creates an empty store bound to `allocator`. Pair every `init` with a
    /// [`TypeStore.deinit`].
    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return .{ .allocator = allocator };
    }

    /// Frees all internal storage: the owned slice copies first, then the three
    /// collections. Invalidates every [`TypeId`] previously handed out.
    pub fn deinit(self: *TypeStore) void {
        for (self.owned_slices.items) |s| self.allocator.free(s);
        self.owned_slices.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.enum_tagged.deinit(self.allocator);
    }

    /// Records whether the enum declaration `sid` carries a payload, which is
    /// what determines ownership of its `enum_` type in [`TypeStore.isOwned`].
    /// Call this as enum declarations are resolved; unrecorded enums default to
    /// "not tagged".
    pub fn setEnumTagged(self: *TypeStore, sid: SymbolId, tagged: bool) !void {
        try self.enum_tagged.put(self.allocator, sid, tagged);
    }

    /// Duplicates a `TypeId` slice into store-owned memory and registers it for
    /// cleanup, so an interned composite type never aliases the caller's
    /// (possibly stack or soon-freed) buffer.
    ///
    /// The empty slice is returned as a shared static `&.{}` without allocating.
    /// See the "interned types never alias caller memory" test.
    fn ownIds(self: *TypeStore, ids: []const TypeId) ![]const TypeId {
        if (ids.len == 0) return &.{};
        const copy = try self.allocator.dupe(TypeId, ids);
        try self.owned_slices.append(self.allocator, copy);
        return copy;
    }

    /// Returns a copy of `t` whose slice payloads point into store-owned memory.
    ///
    /// Only the three slice-carrying variants (`struct_`, `func`, `tuple`) are
    /// rewritten via [`TypeStore.ownIds`]; everything else is returned unchanged
    /// because it is `TypeId`/scalar data with no external backing. Called by
    /// [`TypeStore.intern`] before the type is stored so the retained copy is
    /// self-owned.
    fn own(self: *TypeStore, t: Type) !Type {
        return switch (t) {
            .struct_ => |s| Type{ .struct_ = .{ .decl = s.decl, .args = try self.ownIds(s.args) } },
            .func => |f| Type{ .func = .{ .params = try self.ownIds(f.params), .ret = f.ret } },
            .tuple => |items| Type{ .tuple = try self.ownIds(items) },
            else => t,
        };
    }

    /// Interns `t` and returns its [`TypeId`], the primary entry point.
    ///
    /// If a structurally-equal type was interned before, its existing id is
    /// returned and nothing is allocated (idempotence, see the "interning is
    /// idempotent" test). Otherwise the type's slices are copied into the store
    /// via [`TypeStore.own`], it is appended to `types` under the next dense id,
    /// and registered in `map` so future equal shapes deduplicate to it. Note
    /// the map is keyed on the OWNED copy so the lookup slice and stored slice
    /// share identity semantics under [`TypeContext`].
    pub fn intern(self: *TypeStore, t: Type) !TypeId {
        if (self.map.getContext(t, TypeContext{})) |existing| return existing;
        const owned = try self.own(t);
        const id: TypeId = @enumFromInt(@as(u32, @intCast(self.types.items.len)));
        try self.types.append(self.allocator, owned);
        try self.map.putContext(self.allocator, owned, id, TypeContext{});
        return id;
    }

    /// Resolves an id back to its [`Type`]. The id must have come from THIS store
    /// (it indexes `types` directly, so a foreign or stale id is out of bounds).
    pub fn get(self: *const TypeStore, id: TypeId) Type {
        return self.types.items[@intFromEnum(id)];
    }

    /// Number of distinct types interned so far, i.e. the next id to be assigned.
    /// Used by tests to assert deduplication actually happened.
    pub fn count(self: *const TypeStore) usize {
        return self.types.items.len;
    }

    /// Interns and returns the `bool` type (`kind=.bool`, 1 bit, unsigned).
    pub fn boolT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .bool, .bits = 1, .signed = false } });
    }
    /// Interns and returns Kyte's default `int`: a SIGNED 32-bit integer.
    /// (Kyte's `int` is 32-bit; 64-bit is `long` via [`TypeStore.longT`].)
    pub fn intT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32, .signed = true } });
    }
    /// Interns and returns the unsigned 32-bit integer type, distinct from
    /// [`TypeStore.intT`] purely by signedness.
    pub fn uintT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32, .signed = false } });
    }
    /// Interns and returns Kyte's `long`: a signed 64-bit integer. Heap addresses
    /// must use this width, not `int`, to avoid 32-bit truncation.
    pub fn longT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 64, .signed = true } });
    }
    /// Interns and returns the `byte` type: an unsigned 8-bit integer.
    pub fn byteT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 8, .signed = false } });
    }
    /// Interns and returns the 64-bit float (`double`).
    pub fn doubleT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 64 } });
    }
    /// Interns and returns the 4-lane f64 SIMD vector. Encoded as a `float`
    /// primitive with `bits=256` (the plain total width, which is unambiguous for
    /// this one vector shape).
    pub fn vecF64x4T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 256 } });
    }
    /// Interns and returns the 16-lane u8 SIMD vector, encoded via the
    /// `lanes*1000 + count` bit-width scheme (`8*1000 + 16`) that lets integer
    /// vectors share the `int` variant without colliding with scalar widths.
    pub fn vecU8x16T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 8 * 1000 + 16, .signed = false } });
    }
    /// Interns and returns the 4-lane u32 SIMD vector (`32*1000 + 4` encoding).
    pub fn vecU32x4T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 32 * 1000 + 4, .signed = false } });
    }
    /// Interns and returns the 2-lane u64 SIMD vector (`64*1000 + 2` encoding).
    pub fn vecU64x2T(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .int, .bits = 64 * 1000 + 2, .signed = false } });
    }
    /// Interns and returns the 32-bit float (`float`), distinct from the 64-bit
    /// [`TypeStore.doubleT`].
    pub fn floatT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .float, .bits = 32 } });
    }
    /// Interns and returns `void` (`kind=.void_`, 0 bits).
    pub fn voidT(self: *TypeStore) !TypeId {
        return self.intern(.{ .prim = .{ .kind = .void_, .bits = 0 } });
    }
    /// Interns and returns the built-in `string` type.
    pub fn stringT(self: *TypeStore) !TypeId {
        return self.intern(.string);
    }
    /// Interns and returns the built-in `Html` type (trusted pre-escaped markup).
    pub fn htmlT(self: *TypeStore) !TypeId {
        return self.intern(.html);
    }
    /// Interns and returns the exact-precision `decimal` type.
    pub fn decimalT(self: *TypeStore) !TypeId {
        return self.intern(.decimal);
    }
    /// Interns and returns the opaque `ptr` type.
    pub fn ptrT(self: *TypeStore) !TypeId {
        return self.intern(.ptr);
    }
    /// Interns and returns the dynamic `any` type.
    pub fn anyT(self: *TypeStore) !TypeId {
        return self.intern(.any_);
    }
    /// Interns and returns the `unresolved` sentinel used before inference has
    /// settled a type. Distinct from every concrete type, especially `int`.
    pub fn unresolvedT(self: *TypeStore) !TypeId {
        return self.intern(.unresolved);
    }

    /// Decides whether values of type `id` are ARC-managed (owned), from the TYPE
    /// alone, never from a spelling.
    ///
    /// This is the authoritative ownership oracle the codegen/sema passes rely on
    /// to insert retains/releases. The rules: primitives and raw `ptr` are not
    /// owned; `string`/`decimal`/`struct_`/`array`/`tuple`/`error_union`/`func`/
    /// `trait_`/`storage`/`any_` are owned (they front heap data or fat
    /// pointers); a `future` is NOT owned (its join, not payload, is managed); an
    /// `optional` inherits ownership from its inner type; and an `enum_` is owned
    /// only if it is payload-carrying per [`TypeStore.enum_tagged`]. `type_param`
    /// and `unresolved` are `unreachable` because ownership of an unbound or
    /// un-inferred type is not answerable, resolve/monomorphise first, or use
    /// [`TypeStore.isOwnedSafe`] if reaching them is possible.
    pub fn isOwned(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .prim, .ptr => false,
            .any_ => true,
            .string, .html, .decimal, .struct_, .array, .tuple => true,

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

    /// Total, panic-free variant of [`TypeStore.isOwned`] for contexts that may
    /// legitimately hold an unresolved or unbound type.
    ///
    /// Instead of hitting `unreachable`, it treats `type_param` and `unresolved`
    /// as NOT owned (a conservative "no ARC action" answer), recurses through
    /// `optional` so a `T?` around such a type is handled too, and defers to
    /// [`TypeStore.isOwned`] for every fully-resolved type. Use this where the
    /// caller cannot guarantee inference has completed.
    pub fn isOwnedSafe(self: *const TypeStore, id: TypeId) bool {
        return switch (self.get(id)) {
            .type_param, .unresolved => false,
            .optional => |inner| self.isOwnedSafe(inner),
            else => self.isOwned(id),
        };
    }
};

/// Alias for `std.testing`, used by the interning/equality tests below that
/// pin the module's core invariants (structural identity, ownership-from-type,
/// no aliasing of caller memory).
const testing = std.testing;

test "T1: interning is idempotent, same type, same id" {
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

test "signedness is carried, not spelled, u64 is NOT i64" {

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
