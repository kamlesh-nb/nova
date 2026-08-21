//! Type-reference lowering: syntactic `TypeRef` -> interned semantic `TypeId`.
//!
//! This is the pass that turns a piece of type SYNTAX as the parser saw it (an
//! [`ast.TypeRef`], e.g. the tokens `List<string>` or `int?`) into a canonical,
//! deduplicated identity in the [`types.TypeStore`] (a [`TypeId`]). Everything
//! downstream in `sema/` (inference, monomorphization, ownership) and in codegen
//! reasons about `TypeId`s, never about `TypeRef`s, so this is the single
//! narrow door through which surface type notation enters the typed IR.
//!
//! The work is deliberately shallow. [`Lowerer.lower`] is a structural walk that
//! recurses into the shape of the `TypeRef` and interns the corresponding
//! semantic node; it does NOT type-check, does NOT resolve method bodies, and
//! does NOT report diagnostics. Its three resolution jobs are, in priority
//! order: recognise the built-in primitives and special names (`int`, `string`,
//! `ptr`, the SIMD vectors, `any`, `Storage<T>`, `future<T>`); resolve a bare
//! identifier against the in-scope generic type parameters ([`typeParamRef`]);
//! and, failing those, look the name up as a user-declared type in the
//! [`symbols.SymbolTable`].
//!
//! The most important design decision is the treatment of a name that resolves
//! to NOTHING. It does not error and it does not silently fall back to a default
//! like `int`; it interns a distinct `unresolved` type via [`Lowerer.unresolved`]
//! and records the offending name in [`Stats`]. That keeps lowering total (it
//! always produces a `TypeId`) while making the failure observable and countable
//! rather than papered over. A non-zero `stats.unresolved` is the honest signal
//! that the type engine could not name something the source referred to.
//!
//! Generic type parameters are resolved by POSITION, never by spelling. A bare
//! `T` is a type parameter only if some enclosing [`ParamScope`] in
//! [`Lowerer.param_scopes`] lists a parameter with that name; the resulting
//! [`types.TypeParam`] carries the owning symbol plus the parameter's index, so
//! `List<T>`'s `T` and `Map<T, U>`'s `T` are DIFFERENT types even though they
//! share a letter. Scopes are searched innermost-first, so a method's own type
//! parameter correctly shadows an identically named one on its enclosing struct.
//! With no scope active, `T` is just an unknown identifier, not "the first type
//! parameter of symbol 0".
//!
//! Interning is what makes structural equality cheap: two `TypeRef`s that denote
//! the same type lower to the SAME `TypeId` (`int` == `i32`, and any two
//! `List<string>`s coincide), while structurally different types (`List<string>`
//! vs `List<int>`, a 1-tuple vs a 2-tuple, a `[4]int` vs a `[8]int`) get distinct
//! ids. Ownership/ARC-ness is a property of the interned type, carried through
//! wrappers: `string?` is owned because `string` is, `int?` is not.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");

/// Re-export of the semantic type identity used throughout `sema` and codegen.
///
/// A `TypeId` is an opaque handle into a [`types.TypeStore`]; this alias exists
/// so callers of the lowerer can name the return type of [`Lowerer.lower`]
/// without also importing `types`.
pub const TypeId = types.TypeId;

/// Running tally of what lowering could and could not name.
///
/// This is the pass's honesty ledger, accumulated across every [`Lowerer.lower`]
/// call on a given [`Lowerer`]. A high `lowered`-to-`unresolved` ratio means the
/// type engine understood the source; a non-zero `unresolved` is the surfaced,
/// countable signal that some type name went unrecognised rather than being
/// quietly defaulted.
pub const Stats = struct {
    /// Count of `TypeRef`s that resolved to a concrete semantic type.
    ///
    /// Incremented on every successful arm of [`Lowerer.lower`], including
    /// primitives, wrappers, and user types. Note a wrapper such as `string?`
    /// bumps this once for the wrapper AND once for its inner type, since the
    /// inner is lowered by a nested `lower` call.
    lowered: usize = 0,
    /// Count of names that could not be resolved to any type.
    ///
    /// Bumped only by [`Lowerer.unresolved`]. Each increment corresponds to one
    /// appended entry in [`unresolved_names`].
    unresolved: usize = 0,

    /// The exact names that failed to resolve, in the order they were seen.
    ///
    /// Borrowed slices of the original `TypeRef` text (not copied), so they are
    /// only valid while that source text lives. Owned by this `Stats` and freed
    /// in [`deinit`].
    unresolved_names: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Frees the backing storage of [`unresolved_names`].
    ///
    /// Must be called with the same allocator that [`Lowerer.unresolved`] used
    /// to append. Invoked for you by [`Lowerer.deinit`].
    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.unresolved_names.deinit(allocator);
    }
};

/// One frame of the generic-type-parameter environment.
///
/// Represents the type parameters introduced by a single generic declaration
/// (a struct, enum, or method): `owner` is that declaration's symbol and `names`
/// are its parameter names in declaration order. A bare identifier lowers to a
/// [`types.TypeParam`] `{ owner, index }` where `index` is the position of the
/// matching name in `names`. Resolution by position (not by the identifier
/// text) is what lets `Map<K, V>`'s `K` and `List<T>`'s `T` be distinct types,
/// and lets a method's parameters coexist with its struct's. See
/// [`Lowerer.param_scopes`] for how frames stack, and [`Lowerer.typeParamRef`]
/// for the lookup.
pub const ParamScope = struct {
    /// Symbol of the generic declaration these parameters belong to.
    ///
    /// Becomes the `owner` of the resulting [`types.TypeParam`], so parameters
    /// of two different declarations never compare equal even at the same index.
    owner: types.SymbolId,
    /// Parameter names in declaration order; array index is the parameter index.
    names: []const []const u8,
};

/// Stateful driver for lowering `TypeRef`s into a [`types.TypeStore`].
///
/// Holds the interning store plus the ambient context lowering needs: the
/// active generic-parameter scopes, the symbol table for user-type lookup, the
/// current module for module-scoped resolution, and the [`Stats`] tally. A
/// single `Lowerer` is reused across many [`lower`] calls (its `stats`
/// accumulate); callers mutate [`param_scopes`] / [`current_module`] to set the
/// context before lowering a given declaration's types.
pub const Lowerer = struct {
    /// Allocator for scratch during lowering and for [`Stats.unresolved_names`].
    ///
    /// Note that recursive arms (`func`, `tuple`, `generic`) allocate temporary
    /// child-`TypeId` arrays from this and free them immediately after interning;
    /// the store owns the canonical copy.
    allocator: std.mem.Allocator,
    /// The interning table that owns every produced type and dedupes identities.
    store: *types.TypeStore,

    /// Innermost-last stack of generic-parameter scopes currently in effect.
    ///
    /// Searched from the end (innermost first) by [`typeParamRef`], so a nested
    /// scope shadows an outer one of the same name. Empty means no bare
    /// identifier can resolve as a type parameter. Callers set this per
    /// declaration; the default is no scopes.
    param_scopes: []const ParamScope = &.{},

    /// Optional symbol table used to resolve identifiers to user-declared types.
    ///
    /// When `null`, only built-ins and in-scope type parameters can resolve and
    /// every other name lowers to `unresolved`. When set, a bare identifier is
    /// looked up module-scoped via [`current_module`] and a generic head via a
    /// global lookup.
    symtab: ?*const symbols.SymbolTable = null,

    /// Module whose scope a bare identifier is resolved in, for `symtab` lookups.
    ///
    /// Passed to `findTypeInModule` so a name binds to the type visible from the
    /// module being lowered. `null` widens the search to whatever that call
    /// treats as no-module context.
    current_module: ?symbols.ModuleId = null,
    /// The accumulating resolve/unresolve tally for this lowerer. See [`Stats`].
    stats: Stats = .{},

    /// Constructs a lowerer bound to `store`, with empty context and stats.
    pub fn init(allocator: std.mem.Allocator, store: *types.TypeStore) Lowerer {
        return .{ .allocator = allocator, .store = store };
    }

    /// Releases resources owned by the lowerer (its [`Stats`] name list).
    ///
    /// Does NOT own `store`, `symtab`, or the `param_scopes` backing memory; the
    /// caller retains those.
    pub fn deinit(self: *Lowerer) void {
        self.stats.deinit(self.allocator);
    }

    /// Records `name` as unresolvable and returns the canonical `unresolved` type.
    ///
    /// The deliberate non-error fallback for a name lowering could not resolve:
    /// it keeps lowering total while making the miss observable. Bumps
    /// [`Stats.unresolved`] and appends `name` (borrowed, not copied) to
    /// [`Stats.unresolved_names`]. `name` must outlive this `Lowerer`.
    fn unresolved(self: *Lowerer, name: []const u8) !TypeId {
        self.stats.unresolved += 1;
        try self.stats.unresolved_names.append(self.allocator, name);
        return self.store.unresolvedT();
    }

    /// Interns a built-in primitive type by name, or `null` if `name` is not one.
    ///
    /// Maps Nova's primitive spellings, including the C#/TS-style aliases
    /// (`byte`/`u8`, `int`/`i32`, `long`/`i64`, `float`/`f32`, `double`/`f64`,
    /// and so on), to a `prim` type carrying the TARGET bit width and signedness.
    /// Note the width encoded is the language's fixed width, not the host's: `int`
    /// is 32-bit and `long` is 64-bit regardless of platform. Returns `null`
    /// (not an error) for any non-primitive name so [`lower`] can fall through to
    /// the other resolution strategies.
    fn prim(self: *Lowerer, name: []const u8) !?TypeId {
        // Row shape for the primitive table: name, kind, bit width, signedness.
        const T = struct { n: []const u8, k: types.PrimKind, b: u16, s: bool };
        // Every recognised primitive spelling and its interned attributes. Aliases
        // (e.g. `int`/`i32`, `byte`/`u8`) intentionally map to identical rows so
        // they intern to the same TypeId.
        const table = [_]T{
            .{ .n = "bool", .k = .bool, .b = 1, .s = false },
            .{ .n = "byte", .k = .int, .b = 8, .s = false },
            .{ .n = "ubyte", .k = .int, .b = 8, .s = false },
            .{ .n = "u8", .k = .int, .b = 8, .s = false },
            .{ .n = "sbyte", .k = .int, .b = 8, .s = true },
            .{ .n = "i8", .k = .int, .b = 8, .s = true },
            .{ .n = "short", .k = .int, .b = 16, .s = true },
            .{ .n = "i16", .k = .int, .b = 16, .s = true },
            .{ .n = "ushort", .k = .int, .b = 16, .s = false },
            .{ .n = "u16", .k = .int, .b = 16, .s = false },
            .{ .n = "int", .k = .int, .b = 32, .s = true },
            .{ .n = "i32", .k = .int, .b = 32, .s = true },
            .{ .n = "uint", .k = .int, .b = 32, .s = false },
            .{ .n = "u32", .k = .int, .b = 32, .s = false },
            .{ .n = "long", .k = .int, .b = 64, .s = true },
            .{ .n = "i64", .k = .int, .b = 64, .s = true },
            .{ .n = "ulong", .k = .int, .b = 64, .s = false },
            .{ .n = "u64", .k = .int, .b = 64, .s = false },
            .{ .n = "float", .k = .float, .b = 32, .s = true },
            .{ .n = "f32", .k = .float, .b = 32, .s = true },
            .{ .n = "double", .k = .float, .b = 64, .s = true },
            .{ .n = "f64", .k = .float, .b = 64, .s = true },
            .{ .n = "void", .k = .void_, .b = 0, .s = false },
        };
        for (table) |e| {
            if (std.mem.eql(u8, name, e.n)) {
                return try self.store.intern(.{ .prim = .{ .kind = e.k, .bits = e.b, .signed = e.s } });
            }
        }
        return null;
    }

    /// Resolves a bare identifier against the active generic parameter scopes.
    ///
    /// Walks [`param_scopes`] from the innermost frame outward and returns the
    /// first `{ owner, index }` whose name matches, so an inner scope shadows an
    /// outer one of the same name (a method's `T` wins over its struct's `T`).
    /// Returns `null` when `name` is not a parameter of any active scope, in
    /// which case [`lower`] continues to symbol-table resolution. The index is
    /// the parameter's declaration position, which is why two declarations'
    /// same-named parameters lower to distinct types.
    fn typeParamRef(self: *Lowerer, name: []const u8) ?types.TypeParam {
        var i = self.param_scopes.len;
        while (i > 0) {
            i -= 1;
            const sc = self.param_scopes[i];
            for (sc.names, 0..) |p, idx| {
                if (std.mem.eql(u8, p, name)) {
                    return .{ .owner = sc.owner, .index = @intCast(idx) };
                }
            }
        }
        return null;
    }

    /// Lowers one syntactic [`ast.TypeRef`] to an interned semantic [`TypeId`].
    ///
    /// The pass's entry point and its only recursive worker: it dispatches on the
    /// shape of `tr`, lowering any child type refs first and then interning the
    /// composite. Total by construction, it always yields a `TypeId`; a name it
    /// cannot resolve becomes the `unresolved` type via [`unresolved`] rather
    /// than an error. Every successful arm bumps [`Stats.lowered`].
    ///
    /// Identifier resolution order for the `.ident` arm is significant: the
    /// primitives ([`prim`]) and the special built-in names (`string`, `decimal`,
    /// `ptr`, the SIMD vectors) are checked first, then in-scope type parameters
    /// ([`typeParamRef`]), then user types in [`symtab`], and finally `any`
    /// before giving up. The `.generic` arm additionally special-cases the
    /// built-in higher-kinded heads `Storage<T>` and `future<T>` ahead of the
    /// symbol-table lookup.
    ///
    /// The error set is `anyerror` because it recurses and can fail only through
    /// allocation / interning; it does NOT signal "unresolved" via an error.
    pub fn lower(self: *Lowerer, tr: ast.TypeRef) anyerror!TypeId {
        switch (tr) {

            .error_union => |eu| {
                const ok = try self.lower(eu.ok.*);
                const err = try self.lower(eu.err.*);
                self.stats.lowered += 1;
                return try self.store.intern(.{ .error_union = .{ .ok = ok, .err = err } });
            },
            .ident => |name| {
                if (try self.prim(name)) |p| {
                    self.stats.lowered += 1;
                    return p;
                }
                if (std.mem.eql(u8, name, "string")) {
                    self.stats.lowered += 1;
                    return self.store.stringT();
                }
                if (std.mem.eql(u8, name, "decimal")) {
                    self.stats.lowered += 1;
                    return self.store.decimalT();
                }
                if (std.mem.eql(u8, name, "ptr")) {
                    self.stats.lowered += 1;
                    return self.store.ptrT();
                }
                // FR-simd-L1: the SIMD vector types are spellable as ordinary type names, so a value can be a
                // named local, a function parameter/return, or a struct field (not just an inline simd.* call
                // result). Their TypeIds are the same sentinel-encoded prims the codegen slot picker already
                // maps to <N x iM>, so no further codegen wiring is needed for params/returns/fields.
                if (std.mem.eql(u8, name, "u8x16")) {
                    self.stats.lowered += 1;
                    return self.store.vecU8x16T();
                }
                if (std.mem.eql(u8, name, "u32x4")) {
                    self.stats.lowered += 1;
                    return self.store.vecU32x4T();
                }
                if (std.mem.eql(u8, name, "u64x2")) {
                    self.stats.lowered += 1;
                    return self.store.vecU64x2T();
                }
                if (std.mem.eql(u8, name, "f64x4")) {
                    self.stats.lowered += 1;
                    return self.store.vecF64x4T();
                }

                if (self.typeParamRef(name)) |tp| {
                    self.stats.lowered += 1;
                    return self.store.intern(.{ .type_param = tp });
                }

                if (self.symtab) |st| {
                    if (st.findTypeInModule(name, self.current_module)) |sid| {
                        self.stats.lowered += 1;
                        return switch (st.symbolAt(sid).kind) {
                            .enum_ => try self.store.intern(.{ .enum_ = sid }),
                            .trait_ => try self.store.intern(.{ .trait_ = sid }),
                            else => try self.store.intern(.{ .struct_ = .{ .decl = sid } }),
                        };
                    }
                }

                if (std.mem.eql(u8, name, "any")) {
                    self.stats.lowered += 1;
                    return self.store.anyT();
                }
                return self.unresolved(name);
            },
            .optional => |inner| {
                const id = try self.lower(inner.*);
                self.stats.lowered += 1;
                return self.store.intern(.{ .optional = id });
            },
            .func => |f| {
                const params = try self.allocator.alloc(TypeId, f.params.len);
                defer self.allocator.free(params);
                for (f.params, 0..) |p, i| params[i] = try self.lower(p);
                const ret = try self.lower(f.ret.*);
                self.stats.lowered += 1;

                return self.store.intern(.{ .func = .{ .params = params, .ret = ret } });
            },
            .tuple => |items| {
                const elems = try self.allocator.alloc(TypeId, items.len);
                defer self.allocator.free(elems);
                for (items, 0..) |it, i| elems[i] = try self.lower(it);
                self.stats.lowered += 1;
                return self.store.intern(.{ .tuple = elems });
            },
            .fixed_array => |fa| {
                const elem = try self.lower(fa.element.*);
                self.stats.lowered += 1;
                return self.store.intern(.{ .array = .{ .elem = elem, .len = fa.length } });
            },
            .generic => |g| {
                const args = try self.allocator.alloc(TypeId, g.params.len);
                defer self.allocator.free(args);
                for (g.params, 0..) |p, i| args[i] = try self.lower(p);

                if (std.mem.eql(u8, g.name, "Storage") and args.len == 1) {
                    self.stats.lowered += 1;
                    return try self.store.intern(.{ .storage = args[0] });
                }

                if (std.mem.eql(u8, g.name, "future") and args.len == 1) {
                    self.stats.lowered += 1;
                    return try self.store.intern(.{ .future = args[0] });
                }

                if (self.symtab) |st| {
                    if (st.findType(g.name)) |sid| {
                        self.stats.lowered += 1;

                        return switch (st.symbolAt(sid).kind) {
                            .trait_ => try self.store.intern(.{ .trait_ = sid }),
                            .enum_ => try self.store.intern(.{ .enum_ = sid }),
                            else => try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }),
                        };
                    }
                }
                return self.unresolved(g.name);
            },
        }
    }
};

/// Alias for the standard testing namespace used by the tests below.
const testing = std.testing;

/// Builds a fresh [`Lowerer`] over `store` using the test allocator.
///
/// A convenience for the tests that need no symbol table or scopes; the caller
/// still owns `store` and must `deinit` the returned lowerer.
fn mk(store: *types.TypeStore) Lowerer {
    return Lowerer.init(testing.allocator, store);
}

// Primitive aliases intern to identical ids (int==i32, double==f64) while
// distinct widths/signedness stay distinct (int!=long, uint!=int, u64!=i64).
test "lower: primitives carry their TARGET width and signedness" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    try testing.expect(try l.lower(.{ .ident = "int" }) != try l.lower(.{ .ident = "long" }));

    try testing.expectEqual(try l.lower(.{ .ident = "int" }), try l.lower(.{ .ident = "i32" }));

    try testing.expect(try l.lower(.{ .ident = "uint" }) != try l.lower(.{ .ident = "int" }));
    try testing.expect(try l.lower(.{ .ident = "u64" }) != try l.lower(.{ .ident = "i64" }));

    try testing.expect(try l.lower(.{ .ident = "float" }) != try l.lower(.{ .ident = "double" }));
    try testing.expectEqual(try l.lower(.{ .ident = "double" }), try l.lower(.{ .ident = "f64" }));
}

// `string`, `ptr`, and `int` are three separate types; `string` is owned
// (ARC-tracked), `ptr` is not.
test "lower: string and ptr are distinct, and neither is an int" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    const str = try l.lower(.{ .ident = "string" });
    const p = try l.lower(.{ .ident = "ptr" });
    const int = try l.lower(.{ .ident = "int" });
    try testing.expect(str != p);
    try testing.expect(p != int);
    try testing.expect(store.isOwned(str));
    try testing.expect(!store.isOwned(p));
}

// The core honesty guarantee: an unknown name lowers to `unresolved` (not a
// silent `int` default) and bumps the unresolved tally.
test "T4: an unknown type lowers to unresolved, NOT to int" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    const unk = try l.lower(.{ .ident = "NoSuchType" });
    try testing.expect(store.get(unk) == .unresolved);
    try testing.expect(unk != try l.lower(.{ .ident = "int" }));
    try testing.expectEqual(@as(usize, 1), l.stats.unresolved);
}

// Type params resolve by their position in the scope's name list, not by being
// a lone capital: `A`/`B` map to indices 0/1, while an unlisted `T` is unresolved.
test "lower: a type param resolves by POSITION, not by being one uppercase letter" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const foo = [_]ParamScope{.{ .owner = @enumFromInt(1), .names = &.{ "A", "B" } }};
    l.param_scopes = &foo;
    const a = try l.lower(.{ .ident = "A" });
    const b = try l.lower(.{ .ident = "B" });
    try testing.expect(a != b);
    try testing.expect(store.get(a).type_param.index == 0);
    try testing.expect(store.get(b).type_param.index == 1);

    const t = try l.lower(.{ .ident = "T" });
    try testing.expect(store.get(t) == .unresolved);
}

// Function types are structural: same params but different return types give
// different ids, and a function type is owned.
test "lower: a function type is structural, arity and return matter" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var int_ref = ast.TypeRef{ .ident = "int" };
    var str_ref = ast.TypeRef{ .ident = "string" };
    var one_param = [_]ast.TypeRef{.{ .ident = "int" }};
    const f1 = try l.lower(.{ .func = .{ .params = &one_param, .ret = &int_ref } });
    const f2 = try l.lower(.{ .func = .{ .params = &one_param, .ret = &str_ref } });
    try testing.expect(f1 != f2);

    try testing.expect(store.isOwned(f1));
}

// An optional wraps its inner type (distinct per inner) and inherits ownership
// from it: `string?` is owned, `int?` is not.
test "lower: optionals wrap, and ownership follows the inner type" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var str_ref = ast.TypeRef{ .ident = "string" };
    var int_ref = ast.TypeRef{ .ident = "int" };
    const opt_str = try l.lower(.{ .optional = &str_ref });
    const opt_int = try l.lower(.{ .optional = &int_ref });
    try testing.expect(opt_str != opt_int);
    try testing.expect(store.isOwned(opt_str));
    try testing.expect(!store.isOwned(opt_int));
}

// Tuple element ORDER and fixed-array LENGTH are part of the identity:
// (int,string)!=(string,int) and [4]int!=[8]int.
test "lower: tuples and arrays are structural" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var ab_items = [_]ast.TypeRef{ .{ .ident = "int" }, .{ .ident = "string" } };
    var ba_items = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const ab = try l.lower(.{ .tuple = &ab_items });
    const ba = try l.lower(.{ .tuple = &ba_items });
    try testing.expect(ab != ba);

    var elem = ast.TypeRef{ .ident = "int" };
    const a4 = try l.lower(.{ .fixed_array = .{ .element = &elem, .length = 4 } });
    const a8 = try l.lower(.{ .fixed_array = .{ .element = &elem, .length = 8 } });
    try testing.expect(a4 != a8);
}

// Stats accounting: two known names bump `lowered`, one unknown bumps
// `unresolved` and is recorded verbatim in `unresolved_names`.
test "stats count what could NOT be typed, the honest F2 signal" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    _ = try l.lower(.{ .ident = "int" });
    _ = try l.lower(.{ .ident = "string" });
    _ = try l.lower(.{ .ident = "Mystery" });
    try testing.expectEqual(@as(usize, 2), l.stats.lowered);
    try testing.expectEqual(@as(usize, 1), l.stats.unresolved);
    try testing.expectEqualStrings("Mystery", l.stats.unresolved_names.items[0]);
}

// With a symbol table set, a declared name resolves to its struct decl (owned,
// not unresolved), while an undeclared name still lowers to unresolved.
test "join: a named type resolves to a struct decl, not unresolved" {
    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var tab = symbols.SymbolTable.init(a);
    defer tab.deinit();

    var decls = [_]ast.Declaration{
        .{ .struct_decl = .{
            .name = "Stats",
            .fields = &.{},
            .methods = &.{},
            .attributes = &.{},
            .impls = &.{},
            .is_public = true,
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "m.nova" },
        } },
        .{ .struct_decl = .{
            .name = "List",
            .fields = &.{},
            .methods = &.{},
            .attributes = &.{},
            .impls = &.{},
            .is_public = true,
            .span = .{ .start = 0, .end = 0, .line = 2, .col = 1, .file = "m.nova" },
        } },
    };
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "root.nova" } });

    var l = Lowerer.init(a, &store);
    defer l.deinit();
    l.symtab = &tab;

    const stats = try l.lower(.{ .ident = "Stats" });
    try testing.expect(store.get(stats) == .struct_);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);

    try testing.expect(store.isOwned(stats));

    const nope = try l.lower(.{ .ident = "NoSuchStruct" });
    try testing.expect(store.get(nope) == .unresolved);
}

// A generic head resolved through the symbol table keeps its lowered args, so
// distinct instantiations of the same struct (List<string> vs List<int>) differ.
test "join: F4's precondition holds on real decls, List<string> != List<int>" {
    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var tab = symbols.SymbolTable.init(a);
    defer tab.deinit();
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "List",
        .fields = &.{},
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "m.nova" },
    } }};
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "root.nova" } });

    var l = Lowerer.init(a, &store);
    defer l.deinit();
    l.symtab = &tab;

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    var int_args = [_]ast.TypeRef{.{ .ident = "int" }};
    const list_str = try l.lower(.{ .generic = .{ .name = "List", .params = &str_args } });
    const list_int = try l.lower(.{ .generic = .{ .name = "List", .params = &int_args } });

    try testing.expect(list_str != list_int);
    try testing.expect(store.get(list_str).struct_.args.len == 1);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);
}

// A single scope listing both a struct's and a method's params exposes both:
// `T`/`U` resolve to indices 0/1 with none unresolved.
test "join: a method sees the struct's type params AND its own" {

    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var l = Lowerer.init(a, &store);
    defer l.deinit();

    const su = [_]ParamScope{.{ .owner = @enumFromInt(1), .names = &.{ "T", "U" } }};
    l.param_scopes = &su;
    const t = try l.lower(.{ .ident = "T" });
    const u = try l.lower(.{ .ident = "U" });
    try testing.expect(t != u);
    try testing.expect(store.get(t).type_param.index == 0);
    try testing.expect(store.get(u).type_param.index == 1);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);
}

// Same index under different owners gives different types (Map's `K` != List's
// `T`), and re-selecting a scope reproduces the same id (interning is stable).
test "lower: two different generics' params are DIFFERENT types" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const map_sym: types.SymbolId = @enumFromInt(1);
    const list_sym: types.SymbolId = @enumFromInt(2);

    const map_sc = [_]ParamScope{.{ .owner = map_sym, .names = &.{ "K", "V" } }};
    l.param_scopes = &map_sc;
    const k = try l.lower(.{ .ident = "K" });

    const list_sc = [_]ParamScope{.{ .owner = list_sym, .names = &.{"T"} }};
    l.param_scopes = &list_sc;
    const t = try l.lower(.{ .ident = "T" });

    try testing.expect(store.get(k).type_param.index == 0);
    try testing.expect(store.get(t).type_param.index == 0);

    try testing.expect(k != t);

    l.param_scopes = &map_sc;
    try testing.expectEqual(k, try l.lower(.{ .ident = "K" }));
}

// Absent any scope, `T` is a plain unknown identifier (unresolved), NOT
// implicitly the first param of symbol 0; adding a scope makes it a type param.
test "lower: with no scope, `T` is not a param at all, never symbol 0's" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const t = try l.lower(.{ .ident = "T" });
    try testing.expect(store.get(t) == .unresolved);
    try testing.expect(store.get(t) != .type_param);

    const sc = [_]ParamScope{.{ .owner = @enumFromInt(3), .names = &.{"T"} }};
    l.param_scopes = &sc;
    try testing.expect(store.get(try l.lower(.{ .ident = "T" })) == .type_param);
}

// Stacked scopes keep ownership straight: `T` carries the struct's owner and
// `U` the method's, each at index 0, so the two are different types.
test "lower: a method's own `U` belongs to the METHOD, not to the struct" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const list_sym: types.SymbolId = @enumFromInt(1);
    const map_sym: types.SymbolId = @enumFromInt(2);

    l.param_scopes = &.{
        .{ .owner = list_sym, .names = &.{"T"} },
        .{ .owner = map_sym, .names = &.{"U"} },
    };

    const t = try l.lower(.{ .ident = "T" });
    const u = try l.lower(.{ .ident = "U" });

    try testing.expect(store.get(t) == .type_param);
    try testing.expect(store.get(u) == .type_param);

    try testing.expectEqual(list_sym, store.get(t).type_param.owner);
    try testing.expectEqual(@as(u32, 0), store.get(t).type_param.index);
    try testing.expectEqual(map_sym, store.get(u).type_param.owner);
    try testing.expectEqual(@as(u32, 0), store.get(u).type_param.index);
    try testing.expect(t != u);
}

// Innermost-first search means a nested scope's `T` shadows an outer scope's
// `T`: the resolved owner is the inner (rewrap), not the outer (box).
test "lower: an inner scope SHADOWS an outer one of the same name" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const box: types.SymbolId = @enumFromInt(1);
    const rewrap: types.SymbolId = @enumFromInt(2);
    l.param_scopes = &.{
        .{ .owner = box, .names = &.{"T"} },
        .{ .owner = rewrap, .names = &.{"T"} },
    };
    const t = try l.lower(.{ .ident = "T" });
    try testing.expectEqual(rewrap, store.get(t).type_param.owner);
}
