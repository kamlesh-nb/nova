
const std = @import("std");
const types = @import("../types.zig");

pub const TypeId = types.TypeId;

pub fn substitute(
    store: *types.TypeStore,
    t: TypeId,
    owner: types.SymbolId,
    args: []const TypeId,
) anyerror!TypeId {
    if (args.len == 0) return t;
    return switch (store.get(t)) {
        .error_union => |eu| blk: {
            const ok2 = try substitute(store, eu.ok, owner, args);
            const err2 = try substitute(store, eu.err, owner, args);
            if (ok2 == eu.ok and err2 == eu.err) break :blk t;
            break :blk try store.intern(.{ .error_union = .{ .ok = ok2, .err = err2 } });
        },
        .type_param => |tp| blk: {
            if (tp.owner != owner) break :blk t;
            if (tp.index >= args.len) break :blk t;
            break :blk args[tp.index];
        },
        .struct_ => |st| blk: {
            if (st.args.len == 0) break :blk t;
            const sub = try store.allocator.alloc(TypeId, st.args.len);
            defer store.allocator.free(sub);
            var changed = false;
            for (st.args, 0..) |a, i| {
                sub[i] = try substitute(store, a, owner, args);
                if (sub[i] != a) changed = true;
            }
            if (!changed) break :blk t;
            break :blk try store.intern(.{ .struct_ = .{ .decl = st.decl, .args = sub } });
        },
        .optional => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .optional = s });
        },

        .future => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .future = s });
        },

        .storage => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .storage = s });
        },
        .array => |arr| blk: {
            const s = try substitute(store, arr.elem, owner, args);
            if (s == arr.elem) break :blk t;
            break :blk try store.intern(.{ .array = .{ .elem = s, .len = arr.len } });
        },
        .func => |ft| blk: {
            const ps = try store.allocator.alloc(TypeId, ft.params.len);
            defer store.allocator.free(ps);
            var changed = false;
            for (ft.params, 0..) |p, i| {
                ps[i] = try substitute(store, p, owner, args);
                if (ps[i] != p) changed = true;
            }
            const ret = try substitute(store, ft.ret, owner, args);
            if (!changed and ret == ft.ret) break :blk t;
            break :blk try store.intern(.{ .func = .{ .params = ps, .ret = ret } });
        },
        .tuple => |elems| blk: {
            const es = try store.allocator.alloc(TypeId, elems.len);
            defer store.allocator.free(es);
            var changed = false;
            for (elems, 0..) |e, i| {
                es[i] = try substitute(store, e, owner, args);
                if (es[i] != e) changed = true;
            }
            if (!changed) break :blk t;
            break :blk try store.intern(.{ .tuple = es });
        },

        .prim, .string, .decimal, .ptr, .enum_, .trait_, .unresolved => t,
    };
}

const testing = std.testing;

const List: types.SymbolId = @enumFromInt(1);
const Map: types.SymbolId = @enumFromInt(2);

fn param(store: *types.TypeStore, owner: types.SymbolId, index: u32) !TypeId {
    return store.intern(.{ .type_param = .{ .owner = owner, .index = index } });
}

test "subst: T becomes the argument" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const t = try param(&store, List, 0);
    try testing.expectEqual(str, try substitute(&store, t, List, &.{str}));
}

test "subst: ANOTHER declaration's param is left alone — no silent capture" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const map_k = try param(&store, Map, 0);
    try testing.expectEqual(map_k, try substitute(&store, map_k, List, &.{str}));
}

test "subst: by INDEX, not by name — param 1 takes arg 1" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const int = try store.intT();
    const k = try param(&store, Map, 0);
    const v = try param(&store, Map, 1);
    try testing.expectEqual(str, try substitute(&store, k, Map, &.{ str, int }));
    try testing.expectEqual(int, try substitute(&store, v, Map, &.{ str, int }));
}

test "subst: recurses into a nested instantiation" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const t = try param(&store, List, 0);

    const list_of_t = try store.intern(.{ .struct_ = .{ .decl = List, .args = &.{t} } });
    const got = try substitute(&store, list_of_t, List, &.{str});
    const list_of_str = try store.intern(.{ .struct_ = .{ .decl = List, .args = &.{str} } });
    try testing.expectEqual(list_of_str, got);
    try testing.expect(got != list_of_t);
}

test "subst: a type with nothing to substitute is returned UNCHANGED" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const int = try store.intT();
    try testing.expectEqual(int, try substitute(&store, int, List, &.{str}));
    try testing.expectEqual(str, try substitute(&store, str, List, &.{str}));

    const list_int = try store.intern(.{ .struct_ = .{ .decl = List, .args = &.{int} } });
    try testing.expectEqual(list_int, try substitute(&store, list_int, List, &.{str}));
}

test "subst: no args substitutes nothing — a non-generic receiver is untouched" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const t = try param(&store, List, 0);
    try testing.expectEqual(t, try substitute(&store, t, List, &.{}));
}

test "subst: an out-of-range index is left for the type checker, not panicked on" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const second = try param(&store, List, 1);
    try testing.expectEqual(second, try substitute(&store, second, List, &.{str}));
}

test "subst: through a function type — params and return both" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const t = try param(&store, List, 0);
    const fn_t = try store.intern(.{ .func = .{ .params = &.{t}, .ret = t } });
    const got = try substitute(&store, fn_t, List, &.{str});
    const want = try store.intern(.{ .func = .{ .params = &.{str}, .ret = str } });
    try testing.expectEqual(want, got);
}

pub fn solveParams(
    store: *types.TypeStore,
    declared: TypeId,
    actual: TypeId,
    owner: types.SymbolId,
    solved: []?TypeId,
) void {
    const d = store.get(declared);

    if (d == .type_param) {
        const tp = d.type_param;
        if (tp.owner == owner and tp.index < solved.len and solved[tp.index] == null) {
            if (store.get(actual) != .unresolved) solved[tp.index] = actual;
        }
        return;
    }
    const a = store.get(actual);
    if (@intFromEnum(std.meta.activeTag(d)) != @intFromEnum(std.meta.activeTag(a))) return;
    switch (d) {
        .func => |df| {
            const af = a.func;
            if (df.params.len != af.params.len) return;
            for (df.params, af.params) |dp, ap| solveParams(store, dp, ap, owner, solved);
            solveParams(store, df.ret, af.ret, owner, solved);
        },
        .struct_ => |ds| {
            const as_ = a.struct_;
            if (ds.decl != as_.decl or ds.args.len != as_.args.len) return;
            for (ds.args, as_.args) |da, aa| solveParams(store, da, aa, owner, solved);
        },
        .optional => |di| solveParams(store, di, a.optional, owner, solved),
        .future => |di| solveParams(store, di, a.future, owner, solved),
        .storage => |di| solveParams(store, di, a.storage, owner, solved),
        .array => |da| solveParams(store, da.elem, a.array.elem, owner, solved),
        .tuple => |dt| {
            if (dt.len != a.tuple.len) return;
            for (dt, a.tuple) |de, ae| solveParams(store, de, ae, owner, solved);
        },
        else => {},
    }
}

test "solve: U comes from the closure's RETURN — `map((x) => x * 2)`" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const int = try store.intT();
    const Map_: types.SymbolId = @enumFromInt(9);
    const u = try param(&store, Map_, 0);

    const declared = try store.intern(.{ .func = .{ .params = &.{int}, .ret = u } });
    const actual = try store.intern(.{ .func = .{ .params = &.{int}, .ret = int } });
    var solved = [_]?TypeId{null};
    solveParams(&store, declared, actual, Map_, &solved);
    try testing.expectEqual(int, solved[0].?);
}

test "solve: only OUR params are solved — a foreign one is left alone" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const int = try store.intT();
    const mine: types.SymbolId = @enumFromInt(1);
    const theirs: types.SymbolId = @enumFromInt(2);
    const t_theirs = try param(&store, theirs, 0);
    var solved = [_]?TypeId{null};
    solveParams(&store, t_theirs, int, mine, &solved);
    try testing.expect(solved[0] == null);
}

test "solve: nothing is invented from an unresolved actual" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const mine: types.SymbolId = @enumFromInt(1);
    const u = try param(&store, mine, 0);
    var solved = [_]?TypeId{null};
    solveParams(&store, u, try store.unresolvedT(), mine, &solved);
    try testing.expect(solved[0] == null);
}

test "solve: through a nested instantiation — `List<U>` against `List<string>`" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const mine: types.SymbolId = @enumFromInt(1);
    const u = try param(&store, mine, 0);
    const decl_l = try store.intern(.{ .struct_ = .{ .decl = List, .args = &.{u} } });
    const act_l = try store.intern(.{ .struct_ = .{ .decl = List, .args = &.{str} } });
    var solved = [_]?TypeId{null};
    solveParams(&store, decl_l, act_l, mine, &solved);
    try testing.expectEqual(str, solved[0].?);
}

test "solve: a shape mismatch solves nothing rather than guessing" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const int = try store.intT();
    const mine: types.SymbolId = @enumFromInt(1);
    const u = try param(&store, mine, 0);
    const declared = try store.intern(.{ .func = .{ .params = &.{int}, .ret = u } });
    var solved = [_]?TypeId{null};
    solveParams(&store, declared, int, mine, &solved);
    try testing.expect(solved[0] == null);
}

pub fn substituteOne(
    store: *types.TypeStore,
    t: TypeId,
    owner: types.SymbolId,
    index: u32,
    with: TypeId,
) anyerror!TypeId {
    return switch (store.get(t)) {
        .type_param => |tp| if (tp.owner == owner and tp.index == index) with else t,
        .struct_ => |st| blk: {
            if (st.args.len == 0) break :blk t;
            const sub = try store.allocator.alloc(TypeId, st.args.len);
            defer store.allocator.free(sub);
            var changed = false;
            for (st.args, 0..) |a, i| {
                sub[i] = try substituteOne(store, a, owner, index, with);
                if (sub[i] != a) changed = true;
            }
            if (!changed) break :blk t;
            break :blk try store.intern(.{ .struct_ = .{ .decl = st.decl, .args = sub } });
        },
        .optional => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .optional = s2 });
        },
        .future => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .future = s2 });
        },
        .storage => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .storage = s2 });
        },
        .func => |ft| blk: {
            const ps = try store.allocator.alloc(TypeId, ft.params.len);
            defer store.allocator.free(ps);
            var changed = false;
            for (ft.params, 0..) |p, i| {
                ps[i] = try substituteOne(store, p, owner, index, with);
                if (ps[i] != p) changed = true;
            }
            const ret = try substituteOne(store, ft.ret, owner, index, with);
            if (!changed and ret == ft.ret) break :blk t;
            break :blk try store.intern(.{ .func = .{ .params = ps, .ret = ret } });
        },
        else => t,
    };
}

test "substituteOne: solves U without disturbing V" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const owner: types.SymbolId = @enumFromInt(5);
    const u = try param(&store, owner, 0);
    const v = try param(&store, owner, 1);
    const pair = try store.intern(.{ .func = .{ .params = &.{u}, .ret = v } });

    const got = try substituteOne(&store, pair, owner, 0, str);
    const ft = store.get(got).func;
    try testing.expectEqual(str, ft.params[0]);
    try testing.expectEqual(v, ft.ret);
}
