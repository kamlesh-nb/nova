// sema.zig — F2 stage 4c: sema's artefacts, OWNED.
//
// Stage 2i heap-allocated the SymbolTable, TypeStore and TypedIr and leaked all
// three, deliberately: codegen reads them after sema returns, and a `defer
// deinit()` would have been a use-after-free that only appeared under
// NOVA_SEMA_SHADOW=1 — i.e. exactly where nobody looks. The comment there said
// "stage 4 gives sema a real ownership model rather than inheriting this one".
// This is that.
//
// It is what blocks the 4b cutover from being the default. The cutover reads
// `live_ir`, which only exists when the shadow runs; making it unconditional means
// leaking a TypeStore + SymbolTable + TypedIr on EVERY compile, which is fine for
// a report you opt into and not fine for the compiler's normal path.
//
// The shape is dull on purpose: ONE owner, created once, destroyed once, with
// borrowed views handed out. Sema is heap-allocated because `Lowerer` holds
// `*TypeStore` and `*SymbolTable` — a by-value Sema that moved would leave those
// pointing at the old address, which is the same class of bug as stage 2i's
// address-keyed IR and would be just as quiet.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const lower = @import("lower.zig");
const infer = @import("infer.zig");
const ids = @import("ids.zig");

pub const TypeId = types.TypeId;

pub const Sema = struct {
    allocator: std.mem.Allocator,
    store: types.TypeStore,
    tab: symbols.SymbolTable,
    ir: infer.TypedIr,

    /// Interned type NAMES, keyed by TypeId.
    ///
    /// Rendering a composite type (`List<int>`, `(int) -> int`) allocates, and the
    /// 4b cutover renders on EVERY resolution codegen makes — measured at 9,222
    /// renders / 296 allocations / 3,716 bytes on ONE corpus case, all leaked,
    /// because codegen never frees what `resolveExpressionTypeName` hands back.
    /// That scales with program size and would run on every compile once the
    /// cutover is the default.
    ///
    /// A TypeId is interned, so its name is a pure function of it: render once,
    /// keep it, hand out the same bytes forever. The map owns them; deinit frees
    /// them. Primitives return string literals and never land here.
    names: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty,

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

    /// Cache `name` for `id`, taking ownership. Returns the stored bytes — which
    /// may be a PREVIOUSLY stored copy, in which case `name` is freed: two renders
    /// of one TypeId must return the same bytes, not two equal strings.
    pub fn internName(self: *Sema, id: TypeId, name: []const u8) ![]const u8 {
        const gop = try self.names.getOrPut(self.allocator, id);
        if (gop.found_existing) {
            self.allocator.free(name);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = name;
        return name;
    }

    pub fn cachedName(self: *const Sema, id: TypeId) ?[]const u8 {
        return self.names.get(id);
    }
};

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

test "sema: create/destroy leaks nothing" {
    // testing.allocator FAILS the test on a leak, so this is the whole assertion:
    // the aggregate that used to be leaked on purpose is now owned.
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    _ = try s.store.intT();
    try testing.expect(s.store.count() > 0);
}

test "sema: an interned name is the SAME bytes, not an equal string" {
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const id = try s.store.intT();

    const first = try s.internName(id, try testing.allocator.dupe(u8, "List<int>"));
    // A second render of the same TypeId hands back the FIRST bytes and frees the
    // duplicate — otherwise the cache would grow one entry per render and leak all
    // but the last, which is the bug it exists to fix.
    const second = try s.internName(id, try testing.allocator.dupe(u8, "List<int>"));
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqualStrings("List<int>", second);
    try testing.expectEqual(@as(usize, 1), s.names.count());
}

test "sema: distinct types get distinct names" {
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const a = try s.store.intT();
    const b = try s.store.stringT();
    _ = try s.internName(a, try testing.allocator.dupe(u8, "i32"));
    _ = try s.internName(b, try testing.allocator.dupe(u8, "string"));
    try testing.expectEqualStrings("i32", s.cachedName(a).?);
    try testing.expectEqualStrings("string", s.cachedName(b).?);
    try testing.expect(s.cachedName(try s.store.boolT()) == null); // never rendered
}

test "sema: the store's own slices are freed too (no leak through interning)" {
    // TypeStore.own() dupes every slice a Type carries; subst.zig and infer.zig
    // free their temporaries immediately after interning on that basis. If deinit
    // ever stopped freeing owned_slices this test fails rather than the leak
    // reappearing silently under a different owner.
    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const int = try s.store.intT();
    var args = [_]TypeId{int};
    const list_int = try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } });
    // interning is by value: the same args yield the same id, and the store owns a copy
    try testing.expectEqual(list_int, try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } }));
}
