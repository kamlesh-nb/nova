//! Type-parameter substitution over interned types: the substrate the
//! monomorphizer stands on.
//!
//! Kyte generics are NOT type-erased. `List<int>` is a genuinely distinct type
//! from `List<string>`, instantiated by textually replacing each type parameter
//! with a concrete argument. That replacement is what this file does, operating
//! on [`TypeId`]s in a [`types.TypeStore`] rather than on syntax: every type is
//! interned (deduplicated) in the store, so a "type" is a small integer handle
//! and structural equality is pointer/id equality. Substitution therefore walks
//! the interned tree, rebuilds only the branches that actually change, and
//! re-interns the result so identical instantiations collapse to the same id.
//!
//! There are two directions here, and they are inverses of each other:
//!
//!   * [`substitute`] / [`substituteOne`] go FORWARD: given a generic type and
//!     the argument list (or a single argument), produce the concrete type.
//!     This is what monomorphization calls once the arguments are known, e.g.
//!     lowering the declared body of `List<T>` at `List<string>`.
//!
//!   * [`solveParams`] goes BACKWARD: given a DECLARED type that still mentions
//!     type parameters and the ACTUAL concrete type inferred at a call site, it
//!     deduces what each parameter must be. This is call-site inference, e.g.
//!     recovering `U = int` from `map((x) => x * 2)` where the closure's return
//!     type pins `U`.
//!
//! Three invariants run through all of it, and the tests below exist to nail
//! each one down:
//!
//!   1. **Ownership by (owner, index), never by name.** A [`type_param`] carries
//!      the [`types.SymbolId`] of the declaration that introduced it and its
//!      positional index. Substitution only touches parameters whose `owner`
//!      matches the one passed in, so a `T` belonging to `Map` is left untouched
//!      while substituting `List`'s parameters, even though both spell "the
//!      first type parameter". Arguments are matched by INDEX, not by any name.
//!
//!   2. **Structural sharing / no needless re-interning.** Every recursive case
//!      tracks whether a child actually changed and returns the ORIGINAL
//!      [`TypeId`] untouched when nothing did. This keeps ids stable (important
//!      because downstream code compares types by id) and avoids churning the
//!      intern table for no-op substitutions.
//!
//!   3. **Graceful under-determination, never panic on bad shapes.** An
//!      out-of-range parameter index, a foreign owner, or a shape mismatch
//!      between declared and actual is resolved to "do nothing" (leave the type
//!      as-is / leave the slot unsolved), NOT an assertion. Those situations are
//!      real type errors, but this file is not the place they are reported; the
//!      type checker diagnoses them afterwards. Substituting nothing keeps this
//!      layer total.

const std = @import("std");
const types = @import("../types.zig");

/// Re-export of [`types.TypeId`], the interned-type handle everything here
/// operates on. Aliased locally so the substitution API reads without the
/// `types.` qualifier on its most-used name.
pub const TypeId = types.TypeId;

/// Substitute a whole argument list into a type, producing its concrete form.
///
/// Recursively walks the interned tree of `t`, replacing every [`type_param`]
/// that belongs to `owner` with `args[param.index]`, and rebuilding each
/// composite type (`struct_`, `func`, `tuple`, `optional`, and so on) around the
/// substituted children. This is the forward direction used by
/// monomorphization: `t` is a declaration's type expressed in terms of its own
/// parameters, `owner` is that declaration's [`types.SymbolId`], and `args` are
/// the concrete type arguments in positional order.
///
/// Returns `t` UNCHANGED (same id, no allocation, no re-intern) when nothing in
/// the subtree actually changes, which is how structural sharing is preserved.
/// A fast path returns immediately when `args` is empty, so a non-generic
/// receiver costs nothing.
///
/// Parameters whose `owner` differs, or whose `index` is out of range for
/// `args`, are left in place rather than treated as errors (invariant 3): the
/// out-of-range case is a genuine arity mismatch left for the type checker. Leaf
/// types (`prim`, `string`, `decimal`, `ptr`, `any_`, `enum_`, `trait_`,
/// `unresolved`) contain no parameters and are returned as-is.
///
/// May allocate (and always frees) a temporary child buffer for the composite
/// cases via `store.allocator`; propagates allocator/intern errors as
/// `anyerror`. To replace a single parameter rather than a full list, see
/// [`substituteOne`]; for the inverse (deducing arguments), see [`solveParams`].
pub fn substitute(
    store: *types.TypeStore,
    t: TypeId,
    owner: types.SymbolId,
    args: []const TypeId,
) anyerror!TypeId {
    if (args.len == 0) return t;
    return switch (store.get(t)) {
        // An `ok!err` error union: substitute both halves, re-intern only if
        // either changed, else keep the original id (invariant 2).
        .error_union => |eu| blk: {
            const ok2 = try substitute(store, eu.ok, owner, args);
            const err2 = try substitute(store, eu.err, owner, args);
            if (ok2 == eu.ok and err2 == eu.err) break :blk t;
            break :blk try store.intern(.{ .error_union = .{ .ok = ok2, .err = err2 } });
        },
        // The base case that actually replaces something. Only OUR parameters
        // (matching `owner`) are eligible, and only within range: a foreign
        // owner or an out-of-range index is left as-is for the type checker to
        // flag, never panicked on (invariants 1 and 3).
        .type_param => |tp| blk: {
            if (tp.owner != owner) break :blk t;
            if (tp.index >= args.len) break :blk t;
            break :blk args[tp.index];
        },
        // A struct instantiation such as `List<T>`: substitute each type
        // argument. `st.args.len == 0` means a non-generic struct with nothing
        // to descend into. Rebuilds under the SAME `decl` with substituted args.
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
        // `T?`: substitute the wrapped type, re-wrapping only if it changed.
        .optional => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .optional = s });
        },

        // `future<T>` (the result of `spawn`): substitute the awaited type.
        .future => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .future = s });
        },

        // A storage wrapper (the ARC-storage view of a type): substitute the
        // element and re-wrap only if it changed.
        .storage => |inner| blk: {
            const s = try substitute(store, inner, owner, args);
            if (s == inner) break :blk t;
            break :blk try store.intern(.{ .storage = s });
        },
        // A fixed-length array `[N]T`: substitute the element type; `len` is a
        // value, not a type, so it carries through untouched.
        .array => |arr| blk: {
            const s = try substitute(store, arr.elem, owner, args);
            if (s == arr.elem) break :blk t;
            break :blk try store.intern(.{ .array = .{ .elem = s, .len = arr.len } });
        },
        // A function type: substitute every parameter type AND the return type,
        // re-interning only when at least one of them changed.
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
        // A tuple `(A, B, ...)`: substitute each element in place.
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

        // Leaf types with no substitutable inner structure. Primitives, strings,
        // decimals, raw pointers, `any`, enums, trait objects, and the
        // unresolved placeholder all pass through by identity.
        .prim, .string, .html, .decimal, .ptr, .any_, .enum_, .trait_, .unresolved => t,
    };
}

/// Local alias for `std.testing`, used by the unit tests in this file.
const testing = std.testing;

/// Stand-in owner id for a fictional `List` declaration, used only by the tests
/// to construct `List`'s type parameters without depending on real symbol
/// resolution.
const List: types.SymbolId = @enumFromInt(1);
/// Stand-in owner id for a fictional `Map` declaration, paired with [`List`] so
/// the tests can prove that substitution never crosses between owners.
const Map: types.SymbolId = @enumFromInt(2);

/// Test helper: intern and return the `index`-th type parameter belonging to
/// `owner`. Wraps the [`type_param`] construction the tests would otherwise
/// repeat verbatim.
fn param(store: *types.TypeStore, owner: types.SymbolId, index: u32) !TypeId {
    return store.intern(.{ .type_param = .{ .owner = owner, .index = index } });
}

// A bare parameter is replaced by its positional argument: the base case of
// [`substitute`].
test "subst: T becomes the argument" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const t = try param(&store, List, 0);
    try testing.expectEqual(str, try substitute(&store, t, List, &.{str}));
}

// Invariant 1: a parameter owned by a DIFFERENT declaration is not captured,
// even though it shares the same index as the one being substituted.
test "subst: ANOTHER declaration's param is left alone, no silent capture" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const map_k = try param(&store, Map, 0);
    try testing.expectEqual(map_k, try substitute(&store, map_k, List, &.{str}));
}

// Arguments bind by position: parameter 0 takes argument 0 and parameter 1
// takes argument 1, with no reliance on any parameter name.
test "subst: by INDEX, not by name, param 1 takes arg 1" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const int = try store.intT();
    const k = try param(&store, Map, 0);
    const v = try param(&store, Map, 1);
    try testing.expectEqual(str, try substitute(&store, k, Map, &.{ str, int }));
    try testing.expectEqual(int, try substitute(&store, v, Map, &.{ str, int }));
}

// Substitution reaches into nested instantiations: `List<T>` becomes
// `List<string>`, and the result is a genuinely different interned id.
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

// Invariant 2: a type containing none of `owner`'s parameters comes back with
// its original id, so no needless re-interning occurs.
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

// The empty-`args` fast path: with no arguments there is nothing to replace, so
// even a parameter is returned as-is.
test "subst: no args substitutes nothing, a non-generic receiver is untouched" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const t = try param(&store, List, 0);
    try testing.expectEqual(t, try substitute(&store, t, List, &.{}));
}

// Invariant 3: a parameter index beyond the argument list is a real arity
// error, but substitution leaves it in place rather than panicking.
test "subst: an out-of-range index is left for the type checker, not panicked on" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const second = try param(&store, List, 1);
    try testing.expectEqual(second, try substitute(&store, second, List, &.{str}));
}

// Function types substitute in both directions: a parameter appearing in the
// arguments AND the return type is replaced in each position.
test "subst: through a function type, params and return both" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const str = try store.stringT();
    const t = try param(&store, List, 0);
    const fn_t = try store.intern(.{ .func = .{ .params = &.{t}, .ret = t } });
    const got = try substitute(&store, fn_t, List, &.{str});
    const want = try store.intern(.{ .func = .{ .params = &.{str}, .ret = str } });
    try testing.expectEqual(want, got);
}

/// Infer type arguments by unifying a declared type against a concrete one.
///
/// The inverse of [`substitute`]: given `declared` (a type still written in
/// terms of `owner`'s parameters) and `actual` (the concrete type seen at a call
/// site), walk the two in lockstep and, wherever `declared` is one of `owner`'s
/// [`type_param`]s, record the corresponding piece of `actual` into `solved`.
/// `solved` is indexed by parameter position; a `null` slot means "not yet
/// known". This is how a call like `map((x) => x * 2)` recovers `U = int` from
/// the closure's return type without the caller writing the arguments out.
///
/// Deliberately conservative, so it never invents a binding it cannot justify:
///
///   * Only `owner`'s parameters are solved; a parameter belonging to another
///     declaration is skipped (invariant 1).
///   * The FIRST binding wins: a slot already set is left alone, so an earlier,
///     more specific occurrence is not overwritten by a later one.
///   * An `unresolved` actual contributes nothing, so an unknown at the call
///     site does not pin a parameter to the placeholder type.
///   * If the top-level tags differ, or a composite's shape does not line up
///     (arity, struct `decl`, tuple/array length), the branch solves NOTHING
///     rather than guessing (invariant 3). A genuine mismatch is reported later
///     by the type checker.
///
/// Purely additive on `solved` and returns no error: unsolvable inputs simply
/// leave slots `null`. Composite cases recurse structurally through `func`,
/// `struct_`, `optional`, `future`, `storage`, `array`, and `tuple`; all other
/// shapes bottom out with nothing to solve.
pub fn solveParams(
    store: *types.TypeStore,
    declared: TypeId,
    actual: TypeId,
    owner: types.SymbolId,
    solved: []?TypeId,
) void {
    const d = store.get(declared);

    // Base case: `declared` IS one of our parameters. Bind its slot to `actual`,
    // but only when in range, still unsolved (first-binding-wins), and `actual`
    // is something real (not the `unresolved` placeholder).
    if (d == .type_param) {
        const tp = d.type_param;
        if (tp.owner == owner and tp.index < solved.len and solved[tp.index] == null) {
            if (store.get(actual) != .unresolved) solved[tp.index] = actual;
        }
        return;
    }
    const a = store.get(actual);
    // Shapes must match to descend: differing top-level tags cannot unify, so
    // solve nothing rather than pairing unrelated children.
    if (@intFromEnum(std.meta.activeTag(d)) != @intFromEnum(std.meta.activeTag(a))) return;
    switch (d) {
        // Functions unify parameter-by-parameter plus the return type, but only
        // when the arities agree.
        .func => |df| {
            const af = a.func;
            if (df.params.len != af.params.len) return;
            for (df.params, af.params) |dp, ap| solveParams(store, dp, ap, owner, solved);
            solveParams(store, df.ret, af.ret, owner, solved);
        },
        // Struct instantiations unify argument-by-argument, but only when they
        // name the SAME declaration and carry the same number of arguments (so
        // `List<U>` unifies with `List<string>`, not with `Box<string>`).
        .struct_ => |ds| {
            const as_ = a.struct_;
            if (ds.decl != as_.decl or ds.args.len != as_.args.len) return;
            for (ds.args, as_.args) |da, aa| solveParams(store, da, aa, owner, solved);
        },
        // Single-child wrappers: descend into the one inner type. The tag-match
        // check above guarantees `a` has the same wrapper, so `a.optional` etc.
        // are safe to read.
        .optional => |di| solveParams(store, di, a.optional, owner, solved),
        .future => |di| solveParams(store, di, a.future, owner, solved),
        .storage => |di| solveParams(store, di, a.storage, owner, solved),
        .array => |da| solveParams(store, da.elem, a.array.elem, owner, solved),
        // Tuples unify element-by-element once the lengths match.
        .tuple => |dt| {
            if (dt.len != a.tuple.len) return;
            for (dt, a.tuple) |de, ae| solveParams(store, de, ae, owner, solved);
        },
        // Leaf and non-parameterised shapes: nothing to infer.
        else => {},
    }
}

// [`solveParams`] recovers a parameter from a nested position: `U` is deduced
// from a function's RETURN type when only that position mentions it.
test "solve: U comes from the closure's RETURN, `map((x) => x * 2)`" {
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

// Invariant 1 for inference: a parameter owned by another declaration is never
// bound, so its slot stays `null`.
test "solve: only OUR params are solved, a foreign one is left alone" {
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

// An `unresolved` actual pins nothing: [`solveParams`] refuses to bind a
// parameter to the placeholder type, leaving the slot open for later.
test "solve: nothing is invented from an unresolved actual" {

    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    const mine: types.SymbolId = @enumFromInt(1);
    const u = try param(&store, mine, 0);
    var solved = [_]?TypeId{null};
    solveParams(&store, u, try store.unresolvedT(), mine, &solved);
    try testing.expect(solved[0] == null);
}

// Inference descends into matching struct instantiations: unifying `List<U>`
// with `List<string>` yields `U = string`.
test "solve: through a nested instantiation, `List<U>` against `List<string>`" {
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

// Invariant 3 for inference: when declared and actual shapes disagree (here a
// function against a plain `int`), no slot is bound rather than a guess made.
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

/// Substitute a SINGLE type parameter, leaving all others intact.
///
/// Like [`substitute`], but replaces only the one parameter identified by
/// `(owner, index)` with `with`, so sibling parameters survive untouched. This
/// is the tool for solving parameters one at a time, for instance binding `U` in
/// a `(U, V)`-shaped type while `V` stays a parameter to be solved separately.
///
/// Shares [`substitute`]'s structural-sharing discipline: each composite case
/// rebuilds only when a child changed, otherwise the original `t` is returned by
/// identity. May allocate and free temporary child buffers via `store.allocator`
/// and propagates errors as `anyerror`. Note the coverage is intentionally
/// narrower than [`substitute`]: only the shapes that can carry a parameter and
/// arise here (`struct_`, `optional`, `future`, `storage`, `func`) are
/// descended into; everything else, including `array`, `tuple`, and
/// `error_union`, falls through the `else` and is returned as-is.
pub fn substituteOne(
    store: *types.TypeStore,
    t: TypeId,
    owner: types.SymbolId,
    index: u32,
    with: TypeId,
) anyerror!TypeId {
    return switch (store.get(t)) {
        // Base case: replace this parameter iff BOTH its owner and index match
        // the single target; any other parameter passes through unchanged.
        .type_param => |tp| if (tp.owner == owner and tp.index == index) with else t,
        // Struct instantiation: substitute the one target within each argument.
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
        // `T?`: descend into the wrapped type.
        .optional => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .optional = s2 });
        },
        // `future<T>`: descend into the awaited type.
        .future => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .future = s2 });
        },
        // Storage wrapper: descend into the element type.
        .storage => |inner| blk: {
            const s2 = try substituteOne(store, inner, owner, index, with);
            if (s2 == inner) break :blk t;
            break :blk try store.intern(.{ .storage = s2 });
        },
        // Function type: substitute the target across every parameter and the
        // return type, re-interning only if one of them changed.
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
        // Everything else (leaves plus the shapes not handled above) is returned
        // untouched.
        else => t,
    };
}

// [`substituteOne`] replaces exactly one parameter: binding `U` in a `(U) -> V`
// function leaves `V` still a parameter, ready to be solved on its own.
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
