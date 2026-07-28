
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");

pub const TypeId = types.TypeId;

pub const Stats = struct {
    lowered: usize = 0,
    unresolved: usize = 0,

    unresolved_names: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.unresolved_names.deinit(allocator);
    }
};

pub const ParamScope = struct {
    owner: types.SymbolId,
    names: []const []const u8,
};

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    store: *types.TypeStore,

    param_scopes: []const ParamScope = &.{},

    symtab: ?*const symbols.SymbolTable = null,

    current_module: ?symbols.ModuleId = null,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, store: *types.TypeStore) Lowerer {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn deinit(self: *Lowerer) void {
        self.stats.deinit(self.allocator);
    }

    fn unresolved(self: *Lowerer, name: []const u8) !TypeId {
        self.stats.unresolved += 1;
        try self.stats.unresolved_names.append(self.allocator, name);
        return self.store.unresolvedT();
    }

    fn prim(self: *Lowerer, name: []const u8) !?TypeId {
        const T = struct { n: []const u8, k: types.PrimKind, b: u16, s: bool };
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
                    return self.store.ptrT();
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

const testing = std.testing;

fn mk(store: *types.TypeStore) Lowerer {
    return Lowerer.init(testing.allocator, store);
}

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

test "T4: an unknown type lowers to unresolved — NOT to int" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    const unk = try l.lower(.{ .ident = "NoSuchType" });
    try testing.expect(store.get(unk) == .unresolved);
    try testing.expect(unk != try l.lower(.{ .ident = "int" }));
    try testing.expectEqual(@as(usize, 1), l.stats.unresolved);
}

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

test "lower: a function type is structural — arity and return matter" {
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

test "stats count what could NOT be typed — the honest F2 signal" {
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

test "join: F4's precondition holds on real decls — List<string> != List<int>" {
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

test "lower: with no scope, `T` is not a param at all — never symbol 0's" {

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
