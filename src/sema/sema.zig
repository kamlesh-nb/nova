
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

const testing = std.testing;

test "sema: create/destroy leaks nothing" {

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
    try testing.expect(s.cachedName(try s.store.boolT()) == null);
}

test "sema: the store's own slices are freed too (no leak through interning)" {

    const s = try Sema.create(testing.allocator);
    defer s.destroy();
    const int = try s.store.intT();
    var args = [_]TypeId{int};
    const list_int = try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } });

    try testing.expectEqual(list_int, try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &args } }));
}
