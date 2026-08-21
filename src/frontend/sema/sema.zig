//! Semantic-analysis facade: the object that owns the compiler's typed view of
//! a program and hands its sub-passes a single place to live.
//!
//! Nova's frontend runs several distinct passes over a program: symbol
//! resolution ([`symbols`]), lowering AST to a typed IR ([`lower`]), and type
//! inference ([`infer`]). Every one of them needs the same three long-lived
//! stores: an arena/allocator, the interned [`types.TypeStore`] that gives every
//! distinct type a stable [`TypeId`], and the [`symbols.SymbolTable`] mapping
//! names to declarations. Rather than thread those through every call site, this
//! module bundles them into one heap-allocated [`Sema`] context that the driver
//! creates once, passes to each pass, and destroys at the end. So this file is
//! deliberately thin: it is the aggregation root and lifetime owner, not where
//! the actual analysis logic lives (that is in the imported sub-modules).
//!
//! The one piece of behaviour it does own is the **type-name cache** ([`names`]):
//! a lazily populated, deduplicating map from [`TypeId`] to a printable type name
//! like `"List<int>"`. Codegen and diagnostics ask for a type's display name
//! repeatedly, and rendering it is not free (it recurses through generic args),
//! so the first caller to name a given id interns the string and every later
//! caller gets the SAME bytes back. Because [`Sema`] owns those duplicated
//! strings, [`Sema.destroy`] is responsible for freeing them. See the ordering
//! note there, which frees the cache before the stores it indexes.

/// The Zig standard library, used here for its allocator interface and the
/// unmanaged hash map backing the type-name cache.
const std = @import("std");
/// The parsed abstract syntax tree the sub-passes consume. Imported so this
/// aggregation root stays in the same module graph as the passes it hosts;
/// [`Sema`] itself does not reference AST nodes directly.
const ast = @import("../ast.zig");
/// The type system: provides [`types.TypeStore`] (the interning arena) and the
/// [`TypeId`] handle re-exported below.
const types = @import("../types.zig");
/// Symbol resolution pass; provides [`symbols.SymbolTable`], the name-to-decl
/// store owned by [`Sema.tab`].
const symbols = @import("symbols.zig");
/// AST-to-typed-IR lowering pass. Held in the module graph so a single [`Sema`]
/// can drive it; it reads and writes the shared stores.
const lower = @import("lower.zig");
/// Type-inference pass; provides [`infer.TypedIr`], the typed intermediate
/// representation owned by [`Sema.ir`].
const infer = @import("infer.zig");
/// Node/declaration id definitions shared across the frontend passes.
const ids = @import("ids.zig");

/// Re-export of the type-system's handle type so callers can spell
/// `sema.TypeId` without also importing `types`. A [`TypeId`] is a small stable
/// integer key into [`types.TypeStore`]; the same structural type always maps to
/// the same id, which is what makes it a valid cache key in [`Sema.names`].
pub const TypeId = types.TypeId;

/// The semantic-analysis context: the single owner of every long-lived store
/// the frontend passes share.
///
/// It is always heap-allocated (see [`Sema.create`]) and referred to by pointer,
/// because the passes hold `*Sema` and mutate its stores in place; copying the
/// value would fork the interning tables and break id stability. Ownership of
/// everything reachable from a [`Sema`] is exclusive, so [`Sema.destroy`] tears
/// it all down.
pub const Sema = struct {
    /// The allocator backing every store below and the [`Sema`] object itself.
    /// Retained so [`Sema.destroy`] can free with the same allocator that
    /// created each piece.
    allocator: std.mem.Allocator,
    /// The type interner: maps structural types to stable [`TypeId`]s and owns
    /// the memory for compound types (generic arg slices, etc.).
    store: types.TypeStore,
    /// The symbol table: resolves names to declarations for the passes.
    tab: symbols.SymbolTable,
    /// The typed intermediate representation produced by [`infer`]; the analysis
    /// output that codegen ultimately consumes.
    ir: infer.TypedIr,

    /// Lazily populated cache of printable type names, keyed by [`TypeId`].
    ///
    /// Unmanaged (the allocator is passed in per call) and starts empty. Values
    /// are heap-duplicated strings OWNED by this map: [`Sema.internName`] dupes
    /// on first insert and [`Sema.destroy`] frees each one. A miss is a valid
    /// state: [`Sema.cachedName`] returns null for an id nobody has named yet.
    names: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty,

    /// Allocates and initialises a [`Sema`] on the heap and returns a pointer to
    /// it.
    ///
    /// The stores are constructed against `allocator`, and the [`names`] cache
    /// starts empty via its default. Returns an error if any allocation fails.
    /// The caller owns the returned pointer and must release it with
    /// [`Sema.destroy`].
    pub fn create(allocator: std.mem.Allocator) !*Sema {
        const self = try allocator.create(Sema);
        self.* = .{
            .allocator = allocator,
            .store = types.TypeStore.init(allocator),
            .tab = symbols.SymbolTable.init(allocator),
            .ir = .{},
        };
        return self;
    }

    /// Tears down a [`Sema`] and frees everything it owns, including itself.
    ///
    /// Ordering is deliberate: the [`names`] cache is freed FIRST (each owned
    /// string, then the map's own buffer), because those strings are display
    /// names OF types in [`store`] and must be released before the store they
    /// describe. Then [`ir`], [`tab`], and [`store`] are deinitialised, and
    /// finally the [`Sema`] allocation itself is destroyed via a saved copy of
    /// the allocator (`self` is invalid after `a.destroy(self)`). After this
    /// call the pointer is dangling and must not be used.
    pub fn destroy(self: *Sema) void {
        var it = self.names.valueIterator();
        while (it.next()) |n| self.allocator.free(n.*);
        self.names.deinit(self.allocator);
        self.ir.deinit(self.allocator);
        self.tab.deinit();
        self.store.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    /// Interns a display name for a type, returning the cache-owned copy.
    ///
    /// If `id` is already cached its existing name is returned unchanged and the
    /// argument `name` is ignored (the caller keeps ownership of whatever it
    /// passed). Otherwise `name` is DUPLICATED into memory this map owns and that
    /// copy is stored and returned; the caller therefore still owns its own
    /// `name` buffer in every case. Returns the SAME bytes (same pointer) on
    /// repeated calls for the same `id`, which the tests rely on. Errors only if
    /// the get-or-put or the dupe allocation fails. See [`Sema.cachedName`] for a
    /// non-inserting lookup.
    pub fn internName(self: *Sema, id: TypeId, name: []const u8) ![]const u8 {
        const gop = try self.names.getOrPut(self.allocator, id);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = try self.allocator.dupe(u8, name);
        return gop.value_ptr.*;
    }

    /// Looks up an already-interned name for `id` without inserting anything.
    ///
    /// Returns null if no name has been interned for `id` yet, so a null result
    /// means "not named", not "unnamed type". Takes `*const Sema` because it does
    /// not mutate the cache, unlike [`Sema.internName`], which populates it.
    pub fn cachedName(self: *const Sema, id: TypeId) ?[]const u8 {
        return self.names.get(id);
    }
};

/// Alias for the standard testing namespace used by the unit tests below.
const testing = std.testing;

// Verifies the full [`Sema.create`]/[`Sema.destroy`] lifecycle frees everything
// (run under the testing allocator, which asserts on leaks) while still leaving
// the type store usable in between.
test "sema: create/destroy leaks nothing" {

    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    _ = try s.store.intT();
    try testing.expect(s.store.count() > 0);
}

// Pins the interning contract: naming the same [`TypeId`] twice returns the
// identical pointer (not merely an equal string), and only one entry ends up in
// the cache. This is the property codegen depends on when it compares interned
// names by pointer identity.
test "sema: an interned name is the SAME bytes, not an equal string" {
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const id = try s.store.intT();

    const first = try s.internName(id, try testing.allocator.dupe(u8, "List<int>"));

    const second = try s.internName(id, try testing.allocator.dupe(u8, "List<int>"));
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqualStrings("List<int>", second);
    try testing.expectEqual(@as(usize, 1), s.names.count());
}

// Checks that separate [`TypeId`]s keep separate cache entries, that
// [`Sema.cachedName`] reads each back, and that an id which was never interned
// (here `boolT`) returns null rather than aliasing another entry.
test "sema: distinct types get distinct names" {
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const a = try s.store.intT();
    const b = try s.store.stringT();
    _ = try s.internName(a, try testing.allocator.dupe(u8, "i32"));
    _ = try s.internName(b, try testing.allocator.dupe(u8, "string"));
    try testing.expectEqualStrings("i32", s.cachedName(a).?);
    try testing.expectEqualStrings("string", s.cachedName(b).?);
    try testing.expect(s.cachedName(try s.store.boolT()) == null);
}

// Guards the store side of the lifetime: interning a compound type
// (`List<int>`, built as a `struct_` with an int arg) twice yields the same
// [`TypeId`] and, run under the testing allocator, leaves no leak, confirming
// [`Sema.destroy`] frees the memory the [`types.TypeStore`] allocates for
// generic arg slices, not just the name cache.
test "sema: the store's own slices are freed too (no leak through interning)" {

    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const int = try s.store.intT();
    var args = [_]TypeId{int};
    const list_int = try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } });

    try testing.expectEqual(list_int, try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } }));
}
