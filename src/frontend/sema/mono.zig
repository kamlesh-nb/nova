//! Monomorphisation worklist: which concrete generic instantiations exist.
//!
//! Nova monomorphises generics rather than erasing them: `List<int>` and
//! `List<string>` become two distinct emitted bodies (`List_int_*`,
//! `List_string_*`), not one type-erased body that boxes its element. Before
//! codegen can emit those bodies it must know the exact SET of concrete
//! instantiations the program actually uses. Computing that set is what this
//! file does. [`Worklist`] walks every type the type checker inferred, keeps
//! only the concrete generic structs (a struct with type arguments, all of
//! which are themselves concrete), transitively pulls in the instantiations
//! reachable through their fields and method return types, and de-duplicates
//! the whole thing through a `seen` memo keyed by interned [`TypeId`].
//!
//! Two design decisions shape the code:
//!
//!   1. **This is a SHADOW pass that emits nothing.** Historically the module
//!      was the F4 stage-3 experiment that measured how much code true
//!      monomorphisation would generate versus the old type-erased scheme (see
//!      [`Worklist.report`], which prints "SHADOW — emits nothing" and a growth
//!      ratio). It graduated into the authoritative source of the instantiation
//!      list: [`Worklist.names`] and [`Worklist.instIds`] hand the collected set
//!      to the real emitter, and [`live_instantiations`] / [`live_inst_ids`]
//!      publish it as process-global state for later passes to consult.
//!
//!   2. **Concreteness and a depth bound are load-bearing invariants.** A body
//!      is only emitted for a FULLY concrete type: [`Worklist.isConcrete`]
//!      rejects anything still carrying a `type_param` or `unresolved` slot, so
//!      the compiler never emits a guess. Speculative instantiations reached
//!      through method return types are additionally capped at [`max_depth`] by
//!      [`Worklist.depthOf`], so an unbounded generic recurrence (a method that
//!      returns `List<List<...>>` of ever-growing nesting) is REFUSED rather
//!      than expanded forever, which is the classic monomorphisation
//!      non-termination trap.
//!
//! Alongside the struct worklist the file keeps three flat side-tables that the
//! rest of sema/codegen append to as they discover generic uses that the type
//! map alone does not surface: [`method_insts`] (generic method calls),
//! [`free_fn_insts`] (generic free functions), and [`base_needed`] (which
//! erased base method bodies must survive as fallbacks). These are plain
//! append-and-dedupe registries; they leak their small string/slice
//! allocations by design because they live for the whole compile and are freed
//! when the compiler process exits.
//!
//! Type rendering to a stable string name goes through `shadow.renderLegacy`;
//! lowering an AST type annotation to a [`TypeId`] and substituting a struct's
//! type parameters for its concrete arguments go through `lower.Lowerer` and
//! `subst.substitute` respectively.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const sema_mod = @import("sema.zig");
const render = @import("shadow.zig");
const lower = @import("lower.zig");
const subst = @import("subst.zig");

/// Re-export of the interned type identifier used throughout the compiler.
///
/// A [`TypeId`] is an index into the `TypeStore`; two structurally identical
/// types share one id after interning, which is exactly why it can serve as the
/// key of the `seen` memo and of [`live_inst_ids`].
pub const TypeId = types.TypeId;

/// Maximum generic nesting depth a SPECULATIVE instantiation may reach before
/// it is refused.
///
/// Speculative instantiations come from a generic method's return type (e.g. a
/// method on `List<T>` that returns `List<List<T>>`), which can drive an
/// unbounded recurrence. Capping the nesting at 2 makes the worklist terminate:
/// anything deeper is counted in [`Stats.too_deep`] and dropped. Note the bound
/// applies ONLY to speculative notes; a type the program actually mentions is
/// always accepted regardless of depth. See [`Worklist.depthOf`] and
/// [`Worklist.noteImpl`].
pub const max_depth: u32 = 2;

/// Counters describing the size of the instantiation set, for the shadow report.
///
/// Populated by [`Worklist.compute`] / [`Worklist.noteImpl`] and printed by
/// [`Worklist.report`]. The interesting figure is the ratio of
/// [`Stats.projected_bodies`] to [`Stats.todays_bodies`], which estimates the
/// code-size growth that real monomorphisation costs over type erasure.
pub const Stats = struct {

    /// Count of distinct concrete generic instantiations added to `seen`.
    instantiations: usize = 0,

    /// Number of method bodies emitted under the OLD type-erased scheme, one per
    /// method of each generic struct declaration in the program (each generic
    /// struct compiles to a single erased body today).
    todays_bodies: usize = 0,

    /// Number of method bodies that FULL monomorphisation would emit: the
    /// per-declaration method count summed over every distinct instantiation in
    /// `seen`. The projected-versus-today ratio is the growth estimate.
    projected_bodies: usize = 0,

    /// Number of speculative instantiations refused for exceeding [`max_depth`].
    too_deep: usize = 0,
};

/// Process-global list of instantiation names, published for later passes.
///
/// Set once the worklist has been computed (from [`Worklist.names`]); `null`
/// until then. Global because codegen consults it well after the [`Worklist`]
/// value itself has gone out of scope.
pub var live_instantiations: ?[]const []const u8 = null;

/// Process-global map from instantiation name to its interned [`TypeId`].
///
/// The inverse lookup of [`live_instantiations`]: given a rendered name such as
/// `List_int`, recover the type id so codegen can re-derive the concrete
/// arguments. Populated as a side effect of [`Worklist.names`].
pub var live_inst_ids: std.StringHashMapUnmanaged(TypeId) = .empty;

/// One recorded call to a generic METHOD that must be monomorphised.
///
/// The struct type map alone does not reveal which method instantiations are
/// needed (a call may instantiate a method's own type parameters independently
/// of the receiver), so callers register them here via [`noteMethodInst`]. The
/// string fields (`inst_name`, `args`) are the rendered forms used for
/// de-duplication; the `?TypeId` / `?SymbolId` fields carry the resolved
/// identities codegen needs and may be absent on a purely string-sourced entry.
pub const MethodInst = struct {
    /// Rendered name of the receiver instantiation, e.g. `List_int`.
    inst_name: []const u8,
    /// The method's source name.
    method: []const u8,
    /// Rendered names of the method's own type parameters.
    params: []const []const u8,
    /// Rendered names of the concrete arguments bound to those parameters; the
    /// dedup key together with `inst_name` and `method`.
    args: []const []const u8,
    /// Interned type id of the receiver, when known.
    recv: ?TypeId = null,
    /// Symbol of the struct that declares the method, when known.
    method_owner: ?types.SymbolId = null,
    /// Interned type ids of the method arguments, parallel to `args`.
    args_tids: ?[]const TypeId = null,
    /// Synthetic interned key `struct_{decl=owner, args=[recv, args...]}` used to
    /// give the specific (receiver, args) method instance a single stable id.
    inst_key: ?TypeId = null,
};
/// Global append-only worklist of generic method instantiations.
///
/// Deduplicated on insert by [`noteMethodInst`]; consumed by codegen.
pub var method_insts: std.ArrayListUnmanaged(MethodInst) = .empty;

/// Instantiations forced into the worklist irrespective of the inferred type map.
///
/// Seeded by [`noteForcedStructInst`] and drained by [`Worklist.compute`]. Used
/// when a struct instantiation is required (say, because a driver or the runtime
/// references it) yet never appears as an expression type.
pub var forced_struct_insts: std.ArrayListUnmanaged(TypeId) = .empty;
/// Records a struct instantiation that must be emitted even if unseen.
///
/// Allocation failure is swallowed (`catch {}`): a dropped force-note only means
/// a later pass may re-request the body, never miscompilation.
pub fn noteForcedStructInst(a: std.mem.Allocator, tid: TypeId) void {
    forced_struct_insts.append(a, tid) catch {};
}

/// Set of `"owner|method"` keys whose ERASED base method body must be kept.
///
/// When a generic method is called through a receiver whose base body is still
/// needed as a link-time fallback, the pair is recorded here so globalDCE does
/// not drop it. See [`noteBaseNeeded`] and [`baseIsNeeded`].
pub var base_needed: std.StringHashMapUnmanaged(void) = .empty;

/// Marks the erased base body of `recv_tid`'s `method` as needed.
///
/// Renders the receiver to its legacy name, joins it with the method under a `|`
/// separator, and interns the key. If the key already existed the freshly built
/// string is freed; all allocation failures are swallowed since a missing note
/// is not fatal. Queried by [`baseIsNeeded`].
pub fn noteBaseNeeded(a: std.mem.Allocator, store: *types.TypeStore, recv_tid: TypeId, method: []const u8) void {
    const rn = render.renderLegacy(a, store, recv_tid) catch return;
    const key = std.fmt.allocPrint(a, "{s}|{s}", .{ rn, method }) catch return;
    const gop = base_needed.getOrPut(a, key) catch {
        a.free(key);
        return;
    };
    if (gop.found_existing) a.free(key);
}

/// Reports whether `owner`'s `method` base body was flagged as needed.
///
/// Builds the same `"owner|method"` key into a fixed stack buffer to avoid
/// allocating on this hot query. If the key does not fit the 512-byte buffer the
/// function returns `true` (conservatively keep the body) rather than risk
/// dropping a body that is actually referenced. Complement of [`noteBaseNeeded`].
pub fn baseIsNeeded(owner: []const u8, method: []const u8) bool {
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ owner, method }) catch return true;
    return base_needed.contains(key);
}

/// Debug dump of [`method_insts`], gated behind `NOVA_SEMA_SHADOW`.
///
/// Prints each recorded generic method call as `Recv.method<args...>`. A no-op
/// unless the environment variable is set, so it is safe to leave on any path.
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

/// Records a generic method call so its monomorphised body gets emitted.
///
/// Renders the receiver and each argument type to their legacy names, then scans
/// [`method_insts`] for an existing entry with the same `inst_name`, `method`
/// and argument-name tuple; if found the freshly rendered strings are freed and
/// the call returns without appending (idempotent dedupe). Otherwise it also
/// interns `inst_key` as `struct_{decl=method_owner, args=[recv, args...]}` and
/// appends a fully-populated [`MethodInst`].
///
/// Every allocation failure is handled by freeing what was allocated so far and
/// returning early: a lost note degrades to a missing body a later pass can
/// re-request, never a leak of the partial buffers.
pub fn noteMethodInst(
    a: std.mem.Allocator,
    store: *types.TypeStore,
    recv_tid: TypeId,
    method_owner: types.SymbolId,
    method: []const u8,
    params: []const []const u8,
    args: []const TypeId,
) void {
    const rn0 = render.renderLegacy(a, store, recv_tid) catch return;
    const inst_name = a.dupe(u8, rn0) catch return;
    const abuf = a.alloc([]const u8, args.len) catch {
        a.free(inst_name);
        return;
    };
    for (args, 0..) |at, i| {
        const ar = render.renderLegacy(a, store, at) catch {
            for (abuf[0..i]) |s| a.free(s);
            a.free(abuf);
            a.free(inst_name);
            return;
        };
        abuf[i] = a.dupe(u8, ar) catch {
            for (abuf[0..i]) |s| a.free(s);
            a.free(abuf);
            a.free(inst_name);
            return;
        };
    }

    for (method_insts.items) |mi| {
        if (!std.mem.eql(u8, mi.inst_name, inst_name)) continue;
        if (!std.mem.eql(u8, mi.method, method)) continue;
        if (mi.args.len != abuf.len) continue;
        var same = true;
        for (mi.args, abuf) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (same) {
            for (abuf) |s| a.free(s);
            a.free(abuf);
            a.free(inst_name);
            return;
        }
    }
    const pbuf = a.alloc([]const u8, params.len) catch return;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return;
    const tbuf = a.alloc(TypeId, args.len) catch return;
    for (args, 0..) |at, i| tbuf[i] = at;
    const kbuf = a.alloc(TypeId, args.len + 1) catch return;
    kbuf[0] = recv_tid;
    for (args, 0..) |at, i| kbuf[i + 1] = at;
    const key = store.intern(.{ .struct_ = .{ .decl = method_owner, .args = kbuf } }) catch null;
    method_insts.append(a, .{
        .inst_name = inst_name,
        .method = a.dupe(u8, method) catch return,
        .params = pbuf,
        .args = abuf,
        .recv = recv_tid,
        .method_owner = method_owner,
        .args_tids = tbuf,
        .inst_key = key,
    }) catch {};
}

/// One recorded instantiation of a generic FREE function (not a method).
///
/// The free-function analogue of [`MethodInst`]: same dedupe-by-rendered-args
/// idea, but there is no receiver, so `inst_key` is interned over the argument
/// types alone. Registered by [`noteFreeFnInst`] / [`noteFreeFnInstStr`].
pub const FreeFnInst = struct {
    /// The function's source name.
    fn_name: []const u8,
    /// Rendered names of the function's type parameters.
    params: []const []const u8,
    /// Rendered names of the concrete arguments; the dedup key with `fn_name`.
    args: []const []const u8,
    /// Symbol of the function declaration, when known.
    owner: ?types.SymbolId = null,
    /// Interned type ids of the arguments, parallel to `args`.
    args_tids: ?[]const TypeId = null,
    /// Synthetic interned key `struct_{decl=owner, args=[args...]}` giving this
    /// specific argument tuple a single stable id for codegen.
    inst_key: ?TypeId = null,
};
/// Global append-only worklist of generic free-function instantiations.
pub var free_fn_insts: std.ArrayListUnmanaged(FreeFnInst) = .empty;

/// Records a generic free-function instantiation from resolved type ids.
///
/// Renders the argument types, then either dedupes against an existing entry or
/// appends a new [`FreeFnInst`]. There is one subtlety in the dedupe branch: if a
/// matching entry exists but was created WITHOUT resolved identities (its
/// `inst_key` is `null`, typically because it came from [`noteFreeFnInstStr`])
/// and this call CAN supply them, the existing entry is UPGRADED in place with
/// `owner` / `args_tids` / `inst_key` and the call returns `true`. Otherwise the
/// duplicate is dropped and it returns `false`.
///
/// Returns `true` when the worklist changed (a new entry was appended or an
/// existing one upgraded), `false` when nothing changed or an allocation failed.
pub fn noteFreeFnInst(
    a: std.mem.Allocator,
    store: *types.TypeStore,
    fn_name: []const u8,
    owner: types.SymbolId,
    params: []const []const u8,
    args: []const TypeId,
) bool {
    const abuf = a.alloc([]const u8, args.len) catch return false;
    for (args, 0..) |at, i| {
        const ar = render.renderLegacy(a, store, at) catch {
            for (abuf[0..i]) |s| a.free(s);
            a.free(abuf);
            return false;
        };
        abuf[i] = a.dupe(u8, ar) catch {
            for (abuf[0..i]) |s| a.free(s);
            a.free(abuf);
            return false;
        };
    }
    const tbuf = a.alloc(TypeId, args.len) catch {
        for (abuf) |s| a.free(s);
        a.free(abuf);
        return false;
    };
    for (args, 0..) |at, i| tbuf[i] = at;
    const key = store.intern(.{ .struct_ = .{ .decl = owner, .args = tbuf } }) catch null;
    for (free_fn_insts.items) |*fi| {
        if (!std.mem.eql(u8, fi.fn_name, fn_name)) continue;
        if (fi.args.len != abuf.len) continue;
        var same = true;
        for (fi.args, abuf) |old, new| {
            if (!std.mem.eql(u8, old, new)) same = false;
        }
        if (!same) continue;
        for (abuf) |s| a.free(s);
        a.free(abuf);
        if (fi.inst_key == null and key != null) {
            fi.owner = owner;
            fi.args_tids = tbuf;
            fi.inst_key = key;
            return true;
        }
        a.free(tbuf);
        return false;
    }
    const pbuf = a.alloc([]const u8, params.len) catch return false;
    for (params, 0..) |p, i| pbuf[i] = a.dupe(u8, p) catch return false;
    free_fn_insts.append(a, .{
        .fn_name = a.dupe(u8, fn_name) catch return false,
        .params = pbuf,
        .args = abuf,
        .owner = owner,
        .args_tids = tbuf,
        .inst_key = key,
    }) catch return false;
    return true;
}

/// Records a generic free-function instantiation from ALREADY-rendered strings.
///
/// The string-only path used when the caller has the rendered parameter and
/// argument names but not their resolved [`TypeId`]s. Dedupes against
/// [`free_fn_insts`] and appends a [`FreeFnInst`] with `owner` / `args_tids` /
/// `inst_key` left `null`; a later [`noteFreeFnInst`] call may upgrade it. Returns
/// `true` if a new entry was appended, `false` if it was a duplicate or an
/// allocation failed.
pub fn noteFreeFnInstStr(a: std.mem.Allocator, fn_name: []const u8, params: []const []const u8, args: []const []const u8) bool {
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

/// Compile-time flag: monomorphisation is mandatory and always on.
///
/// Kept as a named constant so the (now historical) erased-only path can still
/// be referenced in prose; the value is never `false` in shipping builds.
pub const mono_enabled: bool = true;

/// The instantiation collector for one program.
///
/// Owns the `seen` memo and [`Stats`]; borrows the driving [`Sema`] (its type
/// store and symbol table) for the lifetime of the collection. Typical use:
/// [`Worklist.init`], then [`Worklist.compute`] over the program, then
/// [`Worklist.names`] / [`Worklist.instIds`] to hand the set to codegen, then
/// [`Worklist.deinit`].
pub const Worklist = struct {
    /// Allocator backing `seen` and every slice this worklist returns.
    allocator: std.mem.Allocator,
    /// The semantic-analysis context supplying the type store and symbol table.
    sema: *sema_mod.Sema,
    /// The memo of instantiations already collected; also THE dedupe set, since
    /// interning guarantees one [`TypeId`] per distinct instantiation.
    seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    /// Running counters for the shadow report; see [`Stats`].
    stats: Stats = .{},

    /// Creates an empty worklist bound to `allocator` and `sema`.
    pub fn init(allocator: std.mem.Allocator, sema: *sema_mod.Sema) Worklist {
        return .{ .allocator = allocator, .sema = sema };
    }

    /// Releases the `seen` memo. Does not touch the borrowed [`Sema`].
    pub fn deinit(self: *Worklist) void {
        self.seen.deinit(self.allocator);
    }

    /// Computes the generic nesting depth of type `t`, bounded by `fuel`.
    ///
    /// Depth is the height of the type tree over the container constructors that
    /// can drive recursion: a generic struct counts as one plus the max depth of
    /// its arguments; optionals, futures and arrays add nothing themselves but
    /// recurse into their element (called with `fuel - 1`); anything else is a
    /// leaf at depth 0. `fuel` is a hard recursion cap: when it hits 0 the
    /// function returns `max_depth + 1`, i.e. "too deep", so a pathological or
    /// cyclic type is reported as over-bound rather than overflowing the stack.
    /// Used by [`Worklist.noteImpl`] to enforce [`max_depth`] on speculative notes.
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

    /// Reports whether `t` is fully concrete, i.e. contains no unbound type.
    ///
    /// Returns `false` the moment any `type_param` or `unresolved` slot is
    /// reached anywhere in the type tree, recursing through struct arguments,
    /// optional/future/array elements, function parameters and return, and tuple
    /// members. This is the guard that stops the compiler emitting a body for a
    /// type it has only partially inferred: [`Worklist.noteImpl`] discards any
    /// non-concrete candidate. All other type shapes are treated as concrete
    /// leaves.
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

    /// Adds `t` and its reachable instantiations to the worklist.
    ///
    /// The public, NON-speculative entry point: types passed here are ones the
    /// program actually uses, so they are accepted at any depth (the
    /// [`max_depth`] cap only applies to speculative notes). Delegates to
    /// [`Worklist.noteImpl`].
    pub fn note(self: *Worklist, t: TypeId) !void {
        return self.noteImpl(t, false);
    }

    /// Core worklist insertion, shared by real and speculative notes.
    ///
    /// Ignores anything that is not a generic struct (a non-struct, or a struct
    /// with zero type arguments), anything not fully concrete
    /// ([`Worklist.isConcrete`]), and anything already in `seen`. When
    /// `speculative` is set it additionally refuses types deeper than
    /// [`max_depth`] (counting them in [`Stats.too_deep`]), which is what keeps a
    /// self-referential generic method from expanding without bound.
    ///
    /// On acceptance it records `t`, bumps [`Stats.instantiations`], and
    /// recurses in two directions. First into the struct's own type arguments
    /// (so `List<Map<K,V>>` also pulls in `Map<K,V>`), carrying the same
    /// `speculative` flag. Then, for a struct declaration, into the concrete
    /// forms of its members: each method RETURN type is lowered, substituted with
    /// this instantiation's arguments, and noted SPECULATIVELY (return types can
    /// diverge, hence the depth bound); each FIELD type is lowered, substituted,
    /// and noted with the CALLER's `speculative` flag (fields are real storage,
    /// not a divergence risk). Lowering or substitution failures are skipped with
    /// `continue` rather than aborting the whole worklist.
    fn noteImpl(self: *Worklist, t: TypeId, speculative: bool) !void {
        const ty = self.sema.store.get(t);
        if (ty != .struct_) return;
        if (ty.struct_.args.len == 0) return;
        if (!self.isConcrete(t)) return;
        if (self.seen.contains(t)) return;

        if (speculative and self.depthOf(t, max_depth + 2) > max_depth) {
            self.stats.too_deep += 1;
            return;
        }
        try self.seen.put(self.allocator, t, {});
        self.stats.instantiations += 1;
        for (ty.struct_.args) |a| try self.noteImpl(a, speculative);

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
                try self.noteImpl(concrete, true);
            }
            for (decl.fields) |f| {
                var l = lower.Lowerer.init(self.allocator, &self.sema.store);
                defer l.deinit();
                l.symtab = &self.sema.tab;
                const scopes = [_]lower.ParamScope{.{ .owner = ty.struct_.decl, .names = decl.type_params }};
                l.param_scopes = &scopes;
                const raw = l.lower(f.type_name) catch continue;
                const concrete = subst.substitute(&self.sema.store, raw, ty.struct_.decl, ty.struct_.args) catch continue;
                try self.noteImpl(concrete, speculative);
            }
        }
    }

    /// Builds the full instantiation set for `program` and fills [`Stats`].
    ///
    /// Seeds the worklist from every expression type the type checker inferred
    /// (`ir.expr_types`) plus the [`forced_struct_insts`] side-table, letting
    /// [`Worklist.noteImpl`] transitively close it. Then computes the two body
    /// counts for the growth report: [`Stats.todays_bodies`] by summing method
    /// counts over the program's generic struct DECLARATIONS (one erased body
    /// each today), and [`Stats.projected_bodies`] by summing method counts over
    /// every distinct INSTANTIATION in `seen` (what real monomorphisation emits).
    pub fn compute(self: *Worklist, program: ast.Program) !void {
        var it = self.sema.ir.expr_types.valueIterator();
        while (it.next()) |t| try self.note(t.*);
        for (forced_struct_insts.items) |t| try self.note(t);

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

    /// Renders every collected instantiation to a stable name slice.
    ///
    /// Allocates and returns the list of legacy names for the members of `seen`
    /// (owned by the caller). As a side effect it also populates the global
    /// [`live_inst_ids`] map from each name back to its [`TypeId`], so the name
    /// and the id it denotes are published together. The complementary raw-id
    /// list is [`Worklist.instIds`].
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

    /// Returns the collected instantiations as their raw [`TypeId`]s.
    ///
    /// The id-only counterpart of [`Worklist.names`]; the returned slice is owned
    /// by the caller. Order follows hash-map iteration and is not significant.
    pub fn instIds(self: *Worklist, allocator: std.mem.Allocator) ![]TypeId {
        var out = std.ArrayListUnmanaged(TypeId).empty;
        errdefer out.deinit(allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |t| try out.append(allocator, t.*);
        return out.toOwnedSlice(allocator);
    }

    /// Prints the shadow-pass summary to stderr.
    ///
    /// Diagnostic only: this pass "emits nothing", and the header says so. Shows
    /// the distinct-instantiation count, today's erased body count, the projected
    /// monomorphised body count and their growth ratio, the too-deep refusal
    /// count if any, and up to the first 12 instantiations with their argument
    /// lists and per-declaration method counts. Reads all figures from
    /// [`Stats`] and re-renders each instantiation's arguments via the type store.
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

/// Alias for the standard testing namespace used by the tests below.
const testing = std.testing;

/// Test helper: interns a `List<arg>` struct type over synthetic decl id 1.
///
/// The decl symbol is a fixed `@enumFromInt(1)` placeholder, so all `mkList`
/// results share one "List" declaration and differ only in their element
/// argument, which is exactly the shape the worklist keys on.
fn mkList(s: *sema_mod.Sema, arg: TypeId) !TypeId {
    return s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(1), .args = &.{arg} } });
}

// Distinct element types produce distinct instantiations (the core promise).
test "mono: List<int> and List<string> are TWO instantiations" {

    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();

    try w.note(try mkList(s, try s.store.intT()));
    try w.note(try mkList(s, try s.store.stringT()));
    try testing.expectEqual(@as(usize, 2), w.stats.instantiations);
}

// Re-noting an identical instantiation is idempotent via the `seen` memo.
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

// A struct with zero type arguments is never an instantiation.
test "mono: a NON-generic struct is not an instantiation" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    try w.note(try s.store.intern(.{ .struct_ = .{ .decl = @enumFromInt(2), .args = &.{} } }));
    try w.note(try s.store.intT());
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}

// A nested generic argument is itself counted, so the outer and inner both add.
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

// A nest past [`max_depth`] is refused (counted in `too_deep`), not expanded.
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

// A nest within the bound is accepted and every level counts.
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

// An uninstantiated type parameter is not concrete, so it is skipped.
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

// [`Worklist.isConcrete`] recurses, so a type param buried deep still disqualifies.
test "mono: a param nested DEEP still disqualifies — List<List<T>>" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    const t_param = try s.store.intern(.{ .type_param = .{ .owner = @enumFromInt(1), .index = 0 } });
    try w.note(try mkList(s, try mkList(s, t_param)));
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}

// An `unresolved` slot is also non-concrete, so no body is emitted for a guess.
test "mono: unresolved is not concrete either — never emit a body for a guess" {
    const s = try sema_mod.Sema.create(testing.allocator);
    defer s.destroy();
    var w = Worklist.init(testing.allocator, s);
    defer w.deinit();
    try w.note(try mkList(s, try s.store.unresolvedT()));
    try testing.expectEqual(@as(usize, 0), w.stats.instantiations);
}
