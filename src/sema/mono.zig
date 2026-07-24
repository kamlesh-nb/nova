// mono.zig — F4 stage 3: the instantiation worklist, in SHADOW MODE.
//
// Computes which generic instantiations a program actually needs, and reports the
// projected code growth. EMITS NOTHING. That ordering is the design's (F4 §5
// stage 3), and §3.5 item 3 says why: "Measure before optimising. Record the
// corpus's symbol count and .o size BEFORE stage 3."
//
// Monomorphization trades SIZE for correctness, and the trade is only worth making
// if the size is known. `List` has ~15 methods; instantiated at 8 types that is
// ~120 functions where 15 exist today. Emitting first and measuring after is how
// you find out the compiler got 8x bigger from a commit that said "correctness".
//
// THE KEY IS A TypeId, NOT (SymbolId, []TypeId).
// The design proposed keying `seen` on the pair. It does not need to: `List<int>`
// is ALREADY an interned TypeId (`.struct_{decl=List, args=[int]}`), and interning
// means TypeId equality IS type equality — so the set of instantiations is just the
// set of reachable struct TypeIds with non-empty args. The pair would be a second
// identity for a thing that already has one, and two identities for one concept is
// how the address-vs-ExprId bug happened.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const sema_mod = @import("sema.zig");
const render = @import("shadow.zig");
const lower = @import("lower.zig");
const subst = @import("subst.zig");

pub const TypeId = types.TypeId;

/// F4 §3.6. `struct Node<T> { next: Node<Node<T>> }` instantiates forever, and an
/// unbounded worklist is a compiler HANG — the design says "cannot ship without it".
/// The guard lives here, in the shadow stage, so it is proven before anything is
/// emitted rather than after a hang in someone's build.
pub const max_depth: u32 = 16;

pub const Stats = struct {
    /// Distinct instantiations reachable in this program.
    instantiations: usize = 0,
    /// Functions that exist TODAY: one body per generic declaration (the erasure).
    todays_bodies: usize = 0,
    /// Functions monomorphization would emit: one per (instantiation, method).
    projected_bodies: usize = 0,
    /// Instantiations refused for exceeding max_depth.
    too_deep: usize = 0,
};

/// F4 4b: the instantiation set, handed to codegen the same way sema hands over
/// `live_ir`/`live_store` (shadow.zig:68) — rendered into the legacy type STRINGS
/// codegen speaks (`"List<string>"`), because codegen's whole type world is strings.
///
/// Stage 3 computed this set and threw it away. 4b is what finally reads it.
pub var live_instantiations: ?[]const []const u8 = null;

/// Keystone: the instantiation NAME -> its concrete struct TypeId (`"List<string>"` ->
/// `.struct_{List,[string]}`). Lets codegen turn `current_instantiation` (a string) back into a
/// TypeId, so a `.type_param` in a monomorphized body can be SUBSTITUTED in the STORE
/// (`subst.substitute`) instead of on the rendered string (`substTypeParams`). Populated by `names()`.
pub var live_inst_ids: std.StringHashMapUnmanaged(TypeId) = .empty;

/// F4-5 method-level monomorphization worklist. A generic METHOD (`List<T>.map<U>`) needs one
/// specialized body per (receiver-instantiation × concrete method-args) — `List<i32>.map<string>`
/// -> `List_i32_map_string` — because the method's own param `U` is solved at the CALL SITE, not by
/// the receiver instantiation, so struct-level mono cannot cover it (its `result: List<U>` binds the
/// erased `List_U_push`, which does not retain — the chained-map leak). Populated during inference
/// (`noteMethodInst`) where the receiver TypeId, method, param names and solved args are all in hand,
/// rendered to the strings codegen speaks. Codegen emits one body per entry with `current_instantiation`
/// = inst_name AND `current_method_subst` = {param->arg}, and resolves generic-method calls to it.
pub const MethodInst = struct {
    inst_name: []const u8, // "List<i32>"  (the receiver instantiation)
    method: []const u8, // "map"
    params: []const []const u8, // ["U"]  (the method's own type-params)
    args: []const []const u8, // ["string"]  (solved concrete, positional with params)
};
pub var method_insts: std.ArrayListUnmanaged(MethodInst) = .empty;

/// F4-5: (receiver-inst | method) keys whose method-ERASED base body is REACHABLE and so must be
/// emitted — namely generic methods called with INFERRED type args (`xs.map((x)=>..)`), which route
/// to the base name `List_int_map`, not to a specialization. Methods called ONLY with EXPLICIT type
/// args (`app.get<GetUser>`, `serde.bind<T>` reifies inside) route to specializations, so their base
/// is dead AND may not even compile (a `<T>__bind` with no concrete T) — those are skipped. Populated
/// by `noteBaseNeeded` from the inferred-arg method-resolution path only.
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

/// F4-5 Phase 2a shadow: dump the method-instantiation worklist (the specialized bodies codegen will
/// emit). Under NOVA_SEMA_SHADOW, so coverage can be validated before emission is wired.
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

/// Record one method-instantiation, rendered from the store, deduped. Called from the inferer at the
/// point it has already proven every method arg concrete. Owns copies of every string (page allocator,
/// like the other mono globals) so it survives past the inferer's arena.
pub fn noteMethodInst(
    store: *types.TypeStore,
    recv_tid: TypeId,
    method: []const u8,
    params: []const []const u8,
    args: []const TypeId,
) void {
    const a = std.heap.page_allocator;
    // Render into a page-allocator-owned COPY (renderLegacy's own buffer allocator is not necessarily
    // page-allocator, so never `free` its result directly — dupe and own). Small, worklist-lifetime.
    const rn0 = render.renderLegacy(a, store, recv_tid) catch return;
    const inst_name = a.dupe(u8, rn0) catch return;
    const abuf = a.alloc([]const u8, args.len) catch return;
    for (args, 0..) |at, i| {
        const ar = render.renderLegacy(a, store, at) catch return;
        abuf[i] = a.dupe(u8, ar) catch return;
    }
    // Dedup on (inst_name, method, args) — the same call shape recurs across the corpus.
    for (method_insts.items) |mi| {
        if (!std.mem.eql(u8, mi.inst_name, inst_name)) continue;
        if (!std.mem.eql(u8, mi.method, method)) continue;
        if (mi.args.len != abuf.len) continue;
        var same = true;
        for (mi.args, abuf) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (same) return; // already recorded (leak the small dupes — worklist lifetime)
    }
    const pbuf = a.alloc([]const u8, params.len) catch return;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return;
    method_insts.append(a, .{ .inst_name = inst_name, .method = a.dupe(u8, method) catch return, .params = pbuf, .args = abuf }) catch {};
}

/// A FREE generic function called with concrete type-args — `maybe<int>(..)`. The direct analogue of
/// `MethodInst` but with NO receiver: keyed on `(fn_name, args)`. Codegen emits one specialized body
/// per entry (`maybe__int`) with `current_method_subst = {param->arg}`, so a value-representation-
/// dependent return (`T | undefined` where T is a value type → BOXED, V1) is compiled correctly — the
/// erased single body cannot, because it doesn't know whether T is a value or a pointer.
pub const FreeFnInst = struct {
    fn_name: []const u8, // "maybe"  (the free fn's source name, as codegen matches fn_decl.name)
    params: []const []const u8, // ["T"]      (the fn's own type-params)
    args: []const []const u8, // ["int"]    (solved concrete, positional with params)
};
pub var free_fn_insts: std.ArrayListUnmanaged(FreeFnInst) = .empty;

/// Record a free generic fn instantiation from the checker's `.generic_call` arm (infer.zig), where
/// the fn name, its type-params, and the solved concrete args are all in hand. Mirrors `noteMethodInst`
/// (dedup on (fn_name, args); page-allocator, worklist-lifetime dupes).
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
        if (same) return; // already recorded
    }
    const pbuf = a.alloc([]const u8, params.len) catch return;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return;
    free_fn_insts.append(a, .{ .fn_name = a.dupe(u8, fn_name) catch return, .params = pbuf, .args = abuf }) catch {};
}

/// Monomorphization is NOT OPTIONAL, and there is deliberately no way to switch it off.
///
/// It shipped behind `NOVA_F4_MONO=1` while it was only an optimisation of ARC's
/// precision. It stopped being optional the moment `Map` moved onto `Storage<K>`
/// (F5 §3.4b): an ERASED `Storage<K>` has inert ARC — `isRefCountedType("K")` is
/// false — so nothing retains the key, while the call-site retain still fires. The two
/// do not compose, and the result is not a leak but an intermittent use-after-free:
/// **4 of 6 corpus runs failed on 12_traits_dispatch**, which is exactly why the first
/// attempt at this migration (5c6c0cc) was reverted four minutes after it landed.
///
/// So the flag is gone rather than defaulted-on. An "off" switch that selects
/// intermittent memory corruption is not a fallback, it is a trap — and the one thing
/// worse than no escape hatch is one that hands someone a use-after-free looking like
/// their own bug.
///
/// The erased body is still EMITTED (`instantiationsOf` always yields `null` first) as
/// a link-time fallback for any call site that resolves to it; it is simply never the
/// selected target for a container. Deleting it is separate work.
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

    /// How deeply nested a type's arguments are. `List<int>` is 1;
    /// `List<List<int>>` is 2. This is what `Node<Node<T>>` grows without bound.
    fn depthOf(self: *Worklist, t: TypeId, fuel: u32) u32 {
        if (fuel == 0) return max_depth + 1; // already past the limit; stop looking
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

    /// Is `t` fully CONCRETE — no type parameter anywhere inside it?
    ///
    /// `List<T>` is not an instantiation. It is the generic's own use of its own
    /// parameter — `List<T>` appears in every one of List's method signatures, and
    /// `List<U>` in map's return. Emitting a body for `List<T>` is meaningless:
    /// there is no T to emit it AT. Only `List<int>` names real code.
    ///
    /// Counting them inflated the projected growth (4 instantiations where 2 exist)
    /// and would have had G3 emitting bodies for types that do not exist. The report
    /// naming them — `List<T>` next to `List<int>` — is what exposed it; the count
    /// alone looked plausible.
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

    /// Record `t` if it is an instantiation, and recurse into its arguments —
    /// `List<Map<string,int>>` needs Map<string,int> emitted too.
    pub fn note(self: *Worklist, t: TypeId) !void {
        const ty = self.sema.store.get(t);
        if (ty != .struct_) return;
        if (ty.struct_.args.len == 0) return; // not generic; nothing to instantiate
        if (!self.isConcrete(t)) return; // `List<T>` is the generic, not an instance
        if (self.seen.contains(t)) return;

        if (self.depthOf(t, max_depth + 2) > max_depth) {
            self.stats.too_deep += 1;
            return; // F4 §3.6 — refuse rather than hang
        }
        try self.seen.put(self.allocator, t, {});
        self.stats.instantiations += 1;
        for (ty.struct_.args) |a| try self.note(a);

        // Transitive: instantiations PRODUCED by this struct's methods. A method return `List<K>` on
        // `Map<string,Box>` is `List<Box>` — which no top-level expression need mention (keys() may never
        // be called), yet `Map_string_Box_keys` IS emitted and its lambda pushes into that List. Without
        // `List<Box>` in the worklist `List_Box_push` is absent and the lambda binds the erased `List_push`
        // (the last abstract residue). Lower each method return in the struct's type-param scope, substitute
        // the instantiation's args, and note the concrete result. Bounded by `seen` + the depth guard.
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

    /// Every instantiation the program's typed expressions mention.
    ///
    /// Reads the TypedIr rather than re-walking the AST: sema already visited every
    /// expression and recorded its type, and the design's "for each call site,
    /// key := (callee, concrete args) FROM THE TypedIr — no strings" is exactly
    /// this. An instantiation is reachable iff some expression has that type.
    pub fn compute(self: *Worklist, program: ast.Program) !void {
        var it = self.sema.ir.expr_types.valueIterator();
        while (it.next()) |t| try self.note(t.*);

        // Declared types too: a field `data: List<int>` is an instantiation even if
        // no expression in this program ever has that type.
        for (program.declarations) |d| {
            switch (d) {
                .struct_decl => |sd| {
                    self.stats.todays_bodies += sd.methods.len;
                },
                else => {},
            }
        }

        // Projected: one body per (instantiation, method of its decl).
        var sit = self.seen.keyIterator();
        while (sit.next()) |t| {
            const st = self.sema.store.get(t.*).struct_;
            const sym = self.sema.tab.symbolAt(st.decl);
            if (sym.decl == .struct_) {
                self.stats.projected_bodies += sym.decl.struct_.methods.len;
            }
        }
    }

    /// The instantiations, as the strings codegen matches on — `"List<string>"`.
    ///
    /// `renderLegacy` is the SAME renderer `resolveExpressionTypeName` feeds codegen
    /// from, which is what makes these names comparable to the ones codegen already
    /// holds; a second spelling of `List<string>` would be a second identity for a
    /// thing that has one, and this file's header says where that leads.
    pub fn names(self: *Worklist, allocator: std.mem.Allocator) ![]const []const u8 {
        var out = std.ArrayListUnmanaged([]const u8).empty;
        errdefer out.deinit(allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |t| {
            const n = try render.renderLegacy(allocator, &self.sema.store, t.*);
            try out.append(allocator, n);
            // Keystone: name -> TypeId, so codegen can substitute in the store.
            try live_inst_ids.put(allocator, n, t.*);
        }
        return out.toOwnedSlice(allocator);
    }

    /// F4 erased-body elimination: the instantiation struct TypeIds (`.struct_{List,[string]}`), for
    /// the per-instantiation disposition pass (inst_disp.zig). Caller owns the slice.
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
        // Name the instantiations. "List<1 arg(s)>" four times says a generic is
        // used; `List<int>` / `List<string>` says WHICH, and the difference is
        // whether the number is a finding or a fact.
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

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

fn mkList(s: *sema_mod.Sema, arg: TypeId) !TypeId {
    return s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &.{arg} } });
}

test "mono: List<int> and List<string> are TWO instantiations" {
    // The whole claim of G1. If these collapsed to one, monomorphization would emit
    // one body and we would be back to erasure with extra steps.
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
    try w.note(try mkList(s, try s.store.intT())); // re-interned: same TypeId
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
    // Emitting List<Map<..>> without Map<..> would link against a body that was
    // never emitted.
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    const map_si = try s.store.intern(.{ .struct_ = .{
        .decl = @enumFromInt(2),
        .args = &.{ try s.store.stringT(), try s.store.intT() },
    } });
    try w.note(try mkList(s, map_si));
    try testing.expectEqual(@as(usize, 2), w.stats.instantiations); // the List AND the Map
}

test "mono: RECURSION GUARD — an unbounded nest is refused, not hung (F4 3.6)" {
    // `struct Node<T> { next: Node<Node<T>> }` instantiates forever. The design says
    // this cannot ship without a bound, because an unbounded worklist is a compiler
    // HANG — the worst failure a compiler has, since there is nothing to read.
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    var t = try s.store.intT();
    var i: u32 = 0;
    while (i < max_depth + 3) : (i += 1) t = try mkList(s, t); // List<List<...<int>>>
    try w.note(t);

    try testing.expectEqual(@as(usize, 1), w.stats.too_deep);
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations); // refused, not queued
}

test "mono: a legal nest just under the bound is ACCEPTED" {
    // The guard must refuse runaways without refusing real code.
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    var t = try s.store.intT();
    var i: u32 = 0;
    while (i < 3) : (i += 1) t = try mkList(s, t); // List<List<List<int>>>
    try w.note(t);
    try testing.expectEqual(@as(usize, 0), w.stats.too_deep);
    try testing.expectEqual(@as(usize, 3), w.stats.instantiations); // and its nested ones
}

test "mono: `List<T>` is NOT an instantiation — only concrete args count" {
    // List<T> appears in every one of List's own method signatures, and List<U> in
    // map's return. They are the GENERIC, not instances of it: there is no T to emit
    // a body at. Counting them inflated growth and would have had G3 emitting bodies
    // for types that do not exist.
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    const t_param = try s.store.intern(.{ .type_param = .{ .owner = @enumFromInt(1), .index = 0 } });
    try w.note(try mkList(s, t_param)); // List<T>
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);

    try w.note(try mkList(s, try s.store.intT())); // List<int> — real
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
