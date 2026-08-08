
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const sema_mod = @import("sema.zig");
const render = @import("shadow.zig");
const lower = @import("lower.zig");
const subst = @import("subst.zig");

pub const TypeId = types.TypeId;

pub const max_depth: u32 = 16;

pub const Stats = struct {

    instantiations: usize = 0,

    todays_bodies: usize = 0,

    projected_bodies: usize = 0,

    too_deep: usize = 0,
};

pub var live_instantiations: ?[]const []const u8 = null;

pub var live_inst_ids: std.StringHashMapUnmanaged(TypeId) = .empty;

pub const MethodInst = struct {
    inst_name: []const u8,
    method: []const u8,
    params: []const []const u8,
    args: []const []const u8,
};
pub var method_insts: std.ArrayListUnmanaged(MethodInst) = .empty;

pub var base_needed: std.StringHashMapUnmanaged(void) = .empty;

pub fn noteBaseNeeded(store: *types.TypeStore, recv_tid: TypeId, method: []const u8) void {
    const a = std.heap.page_allocator;
    const rn = render.renderLegacy(a, store, recv_tid) catch return;
    const key = std.fmt.allocPrint(a, "{s}|{s}", .{ rn, method }) catch return;
    base_needed.put(a, key, {}) catch {};
}

pub fn baseIsNeeded(owner: []const u8, method: []const u8) bool {
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ owner, method }) catch return true;
    return base_needed.contains(key);
}

pub fn dumpMethodInsts() void {
    if (std.c.getenv("NOVA_SEMA_SHADOW") == null) return;
    const out = std.debug.print;
    out("\n=== F4-5 method-instantiation worklist ({d}) ===\n", .{method_insts.items.len});
    for (method_insts.items) |mi| {
        out("  {s}.{s}<", .{ mi.inst_name, mi.method });
        for (mi.args, 0..) |an, i| {
            if (i > 0) out(", ", .{});
            out("{s}", .{an});
        }
        out(">\n", .{});
    }
    out("=== end method-inst worklist ===\n", .{});
}

pub fn noteMethodInst(
    store: *types.TypeStore,
    recv_tid: TypeId,
    method: []const u8,
    params: []const []const u8,
    args: []const TypeId,
) void {
    const a = std.heap.page_allocator;

    const rn0 = render.renderLegacy(a, store, recv_tid) catch return;
    const inst_name = a.dupe(u8, rn0) catch return;
    const abuf = a.alloc([]const u8, args.len) catch return;
    for (args, 0..) |at, i| {
        const ar = render.renderLegacy(a, store, at) catch return;
        abuf[i] = a.dupe(u8, ar) catch return;
    }

    for (method_insts.items) |mi| {
        if (!std.mem.eql(u8, mi.inst_name, inst_name)) continue;
        if (!std.mem.eql(u8, mi.method, method)) continue;
        if (mi.args.len != abuf.len) continue;
        var same = true;
        for (mi.args, abuf) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (same) return;
    }
    const pbuf = a.alloc([]const u8, params.len) catch return;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return;
    method_insts.append(a, .{ .inst_name = inst_name, .method = a.dupe(u8, method) catch return, .params = pbuf, .args = abuf }) catch {};
}

pub const FreeFnInst = struct {
    fn_name: []const u8,
    params: []const []const u8,
    args: []const []const u8,
};
pub var free_fn_insts: std.ArrayListUnmanaged(FreeFnInst) = .empty;

pub fn noteFreeFnInst(
    store: *types.TypeStore,
    fn_name: []const u8,
    params: []const []const u8,
    args: []const TypeId,
) void {
    const a = std.heap.page_allocator;
    const abuf = a.alloc([]const u8, args.len) catch return;
    for (args, 0..) |at, i| {
        const ar = render.renderLegacy(a, store, at) catch return;
        abuf[i] = a.dupe(u8, ar) catch return;
    }
    for (free_fn_insts.items) |fi| {
        if (!std.mem.eql(u8, fi.fn_name, fn_name)) continue;
        if (fi.args.len != abuf.len) continue;
        var same = true;
        for (fi.args, abuf) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (same) return;
    }
    const pbuf = a.alloc([]const u8, params.len) catch return;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return;
    free_fn_insts.append(a, .{ .fn_name = a.dupe(u8, fn_name) catch return, .params = pbuf, .args = abuf }) catch {};
}

// Register a free-generic function instantiation from already-rendered type-argument STRINGS
// (codegen's transitive-closure pass produces these when a generic function forwards an enclosing
// type parameter to another generic, e.g. `inner<T>` inside `outer<T>`). Dedups on (name, args) and
// returns true if a NEW instance was added, so the caller can run a fixpoint. Strings are duped into
// the page allocator to match noteFreeFnInst's storage.
pub fn noteFreeFnInstStr(fn_name: []const u8, params: []const []const u8, args: []const []const u8) bool {
    const a = std.heap.page_allocator;
    for (free_fn_insts.items) |fi| {
        if (!std.mem.eql(u8, fi.fn_name, fn_name)) continue;
        if (fi.args.len != args.len) continue;
        var same = true;
        for (fi.args, args) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (same) return false;
    }
    const abuf = a.alloc([]const u8, args.len) catch return false;
    for (args, 0..) |an, i| abuf[i] = a.dupe(u8, an) catch return false;
    const pbuf = a.alloc([]const u8, params.len) catch return false;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return false;
    free_fn_insts.append(a, .{ .fn_name = a.dupe(u8, fn_name) catch return false, .params = pbuf, .args = abuf }) catch return false;
    return true;
}

pub const mono_enabled: bool = true;

pub const Worklist = struct {
    allocator: std.mem.Allocator,
    sema: *sema_mod.Sema,
    seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, sema: *sema_mod.Sema) Worklist {
        return .{ .allocator = allocator, .sema = sema };
    }

    pub fn deinit(self: *Worklist) void {
        self.seen.deinit(self.allocator);
    }

    fn depthOf(self: *Worklist, t: TypeId, fuel: u32) u32 {
        if (fuel == 0) return max_depth + 1;
        return switch (self.sema.store.get(t)) {
            .struct_ => |st| blk: {
                var d: u32 = 0;
                for (st.args) |a| {
                    const ad = self.depthOf(a, fuel - 1);
                    if (ad > d) d = ad;
                }
                break :blk d + 1;
            },
            .optional => |i| self.depthOf(i, fuel - 1),
            .future => |i| self.depthOf(i, fuel - 1),
            .array => |a| self.depthOf(a.elem, fuel - 1),
            else => 0,
        };
    }

    fn isConcrete(self: *Worklist, t: TypeId) bool {
        return switch (self.sema.store.get(t)) {
            .type_param, .unresolved => false,
            .struct_ => |st| blk: {
                for (st.args) |a| {
                    if (!self.isConcrete(a)) break :blk false;
                }
                break :blk true;
            },
            .optional => |i| self.isConcrete(i),
            .future => |i| self.isConcrete(i),
            .array => |a| self.isConcrete(a.elem),
            .func => |ft| blk: {
                for (ft.params) |p| {
                    if (!self.isConcrete(p)) break :blk false;
                }
                break :blk self.isConcrete(ft.ret);
            },
            .tuple => |items| blk: {
                for (items) |i| {
                    if (!self.isConcrete(i)) break :blk false;
                }
                break :blk true;
            },
            else => true,
        };
    }

    pub fn note(self: *Worklist, t: TypeId) !void {
        const ty = self.sema.store.get(t);
        if (ty != .struct_) return;
        if (ty.struct_.args.len == 0) return;
        if (!self.isConcrete(t)) return;
        if (self.seen.contains(t)) return;

        if (self.depthOf(t, max_depth + 2) > max_depth) {
            self.stats.too_deep += 1;
            return;
        }
        try self.seen.put(self.allocator, t, {});
        self.stats.instantiations += 1;
        for (ty.struct_.args) |a| try self.note(a);

        const sym = self.sema.tab.symbolAt(ty.struct_.decl);
        if (sym.decl == .struct_) {
            const decl = sym.decl.struct_;
            for (decl.methods) |m| {
                const rt = m.decl.ret_type orelse continue;
                var l = lower.Lowerer.init(self.allocator, &self.sema.store);
                defer l.deinit();
                l.symtab = &self.sema.tab;
                const scopes = [_]lower.ParamScope{.{ .owner = ty.struct_.decl, .names = decl.type_params }};
                l.param_scopes = &scopes;
                const raw = l.lower(rt) catch continue;
                const concrete = subst.substitute(&self.sema.store, raw, ty.struct_.decl, ty.struct_.args) catch continue;
                try self.note(concrete);
            }
        }
    }

    pub fn compute(self: *Worklist, program: ast.Program) !void {
        var it = self.sema.ir.expr_types.valueIterator();
        while (it.next()) |t| try self.note(t.*);

        for (program.declarations) |d| {
            switch (d) {
                .struct_decl => |sd| {
                    self.stats.todays_bodies += sd.methods.len;
                },
                else => {},
            }
        }

        var sit = self.seen.keyIterator();
        while (sit.next()) |t| {
            const st = self.sema.store.get(t.*).struct_;
            const sym = self.sema.tab.symbolAt(st.decl);
            if (sym.decl == .struct_) {
                self.stats.projected_bodies += sym.decl.struct_.methods.len;
            }
        }
    }

    pub fn names(self: *Worklist, allocator: std.mem.Allocator) ![]const []const u8 {
        var out = std.ArrayListUnmanaged([]const u8).empty;
        errdefer out.deinit(allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |t| {
            const n = try render.renderLegacy(allocator, &self.sema.store, t.*);
            try out.append(allocator, n);

            try live_inst_ids.put(allocator, n, t.*);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn instIds(self: *Worklist, allocator: std.mem.Allocator) ![]TypeId {
        var out = std.ArrayListUnmanaged(TypeId).empty;
        errdefer out.deinit(allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |t| try out.append(allocator, t.*);
        return out.toOwnedSlice(allocator);
    }

    pub fn report(self: *const Worklist) void {
        const out = std.debug.print;
        out("\n=== F4 stage 3: instantiation worklist (SHADOW — emits nothing) ===\n", .{});
        out("  distinct instantiations : {d}\n", .{self.stats.instantiations});
        out("  bodies today (erased)   : {d}\n", .{self.stats.todays_bodies});
        out("  bodies if monomorphized : {d}\n", .{self.stats.projected_bodies});
        if (self.stats.todays_bodies > 0) {
            const ratio = @as(f64, @floatFromInt(self.stats.projected_bodies)) /
                @as(f64, @floatFromInt(self.stats.todays_bodies));
            out("  growth                  : {d:.2}x\n", .{ratio});
        }
        if (self.stats.too_deep > 0) {
            out("  REFUSED (depth > {d})    : {d}\n", .{ max_depth, self.stats.too_deep });
        }

        var it = self.seen.keyIterator();
        var n: usize = 0;
        while (it.next()) |t| {
            if (n >= 12) break;
            const st = self.sema.store.get(t.*).struct_;
            out("    - {s}<", .{self.sema.tab.symbolAt(st.decl).name});
            for (st.args, 0..) |a, i| {
                if (i > 0) out(", ", .{});
                out("{s}", .{render.renderLegacy(self.allocator, &self.sema.store, a) catch "?"});
            }
            out(">  x{d} methods\n", .{if (self.sema.tab.symbolAt(st.decl).decl == .struct_)
                self.sema.tab.symbolAt(st.decl).decl.struct_.methods.len
            else
                0});
            n += 1;
        }
        out("=== end ===\n\n", .{});
    }
};

const testing = std.testing;

fn mkList(s: *sema_mod.Sema, arg: TypeId) !TypeId {
    return s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &.{arg} } });
}

test "mono: List<int> and List<string> are TWO instantiations" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    try w.note(try mkList(s, try s.store.intT()));
    try w.note(try mkList(s, try s.store.stringT()));
    try testing.expectEqual(@as(usize, 2), w.stats.instantiations);
}

test "mono: the same instantiation twice is ONE — the seen set is the memo" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    const li = try mkList(s, try s.store.intT());
    try w.note(li);
    try w.note(li);
    try w.note(try mkList(s, try s.store.intT()));
    try testing.expectEqual(@as(usize, 1), w.stats.instantiations);
}

test "mono: a NON-generic struct is not an instantiation" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    try w.note(try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(2), .args = &.{} } }));
    try w.note(try s.store.intT());
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}

test "mono: nested args are instantiations too — List<Map<string,int>>" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    const map_si = try s.store.intern(.{ .struct_ = .{
        .decl = @enumFromInt(2),
        .args = &.{ try s.store.stringT(), try s.store.intT() },
    } });
    try w.note(try mkList(s, map_si));
    try testing.expectEqual(@as(usize, 2), w.stats.instantiations);
}

test "mono: RECURSION GUARD — an unbounded nest is refused, not hung (F4 3.6)" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    var t = try s.store.intT();
    var i: u32 = 0;
    while (i < max_depth + 3) : (i += 1) t = try mkList(s, t);
    try w.note(t);

    try testing.expectEqual(@as(usize, 1), w.stats.too_deep);
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}

test "mono: a legal nest just under the bound is ACCEPTED" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    var t = try s.store.intT();
    var i: u32 = 0;
    while (i < 3) : (i += 1) t = try mkList(s, t);
    try w.note(t);
    try testing.expectEqual(@as(usize, 0), w.stats.too_deep);
    try testing.expectEqual(@as(usize, 3), w.stats.instantiations);
}

test "mono: `List<T>` is NOT an instantiation — only concrete args count" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    const t_param = try s.store.intern(.{ .type_param = .{ .owner = @enumFromInt(1), .index = 0 } });
    try w.note(try mkList(s, t_param));
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);

    try w.note(try mkList(s, try s.store.intT()));
    try testing.expectEqual(@as(usize, 1), w.stats.instantiations);
}

test "mono: a param nested DEEP still disqualifies — List<List<T>>" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    const t_param = try s.store.intern(.{ .type_param = .{ .owner = @enumFromInt(1), .index = 0 } });
    try w.note(try mkList(s, try mkList(s, t_param)));
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}

test "mono: unresolved is not concrete either — never emit a body for a guess" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    try w.note(try mkList(s, try s.store.unresolvedT()));
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}
