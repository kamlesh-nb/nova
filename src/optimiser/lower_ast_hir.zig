// lower_ast_hir.zig — AST -> HIR, with ARC ops threaded in (scope-accurate placement).
//
// Walks a function body and builds the flat HIR node table, and -- when a sema TypedIr is supplied --
// makes ARC explicit. A `let` whose initialiser sema marks OWNED (TypedIr.ownedOf) declares an owned
// local in the current lexical scope; binding an owned local FROM another owned local (a copy) emits a
// `retain` for the new owner. Releases are placed by scope, as HIR nodes:
//   - at the end of the block that declared the local,
//   - before a `return` (all enclosing owned locals, EXCEPT one being moved out by `return x`),
//   - before a `break`/`continue` (the owned locals of the scopes the jump exits).
// Placing releases as HIR nodes BEFORE the exit node is what makes HIR->MIR lower them (a release after a
// return would be dropped when the block terminates). This gives arc_elision (M4) balanced pairs to
// cancel. Runs only in the NOVA_OPT shadow today, so an imperfect placement cannot affect the produced
// program. See docs/design/optimiser.md.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const hir = @import("hir.zig");
const mir = @import("mir.zig");
const infer = @import("../frontend/sema/infer.zig");

const HirId = hir.HirId;

// If `fa` is a method access on a STRING receiver (`s.method`), return the mangled callee name
// `string_<method>` (owned by `func`), else null. This lets the emit path resolve what is otherwise a
// nameless field-access callee. Scoped to string receivers, whose mangled type name is just `string`; other
// receivers (generics, user structs) need the general type-name mangling and stay nameless for now.
// True if `stmt` contains a `continue` that belongs to the ENCLOSING loop (i.e. not inside a nested loop of
// its own). A nested for/while owns its continues, so we stop the walk there; a switch does NOT (a continue
// in a case targets the enclosing loop), so we walk its cases.
fn hasEnclosingContinue(stmt: ast.Statement) bool {
    return switch (stmt) {
        .continue_stmt => true,
        .block => |b| blk: {
            for (b.statements) |s| if (hasEnclosingContinue(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |is| hasEnclosingContinue(is.then_branch.*) or (if (is.else_branch) |e| hasEnclosingContinue(e.*) else false),
        .switch_stmt => |ss| blk: {
            for (ss.cases) |c| if (hasEnclosingContinue(c.body.*)) break :blk true;
            if (ss.default_case) |d| if (hasEnclosingContinue(d.*)) break :blk true;
            break :blk false;
        },
        .for_stmt, .while_stmt => false, // a nested loop owns its own continues
        else => false,
    };
}

// Desugar a C-style `for (init; cond; incr) body` to `{ init; while (cond) { body; incr } }`. A `continue`
// in the body must still run the increment; a naive while would skip it, so a for whose body has an
// enclosing continue (or an iterator form `for x in ...`) lowers to `.unsupported` (AST fallback).
fn lowerFor(ctx: *Ctx, ids: *std.ArrayListUnmanaged(HirId), fs: ast.ForStmt) anyerror!void {
    const a = ctx.allocator;
    const func = ctx.func;
    if (fs.iterator != null or hasEnclosingContinue(fs.body.*)) {
        try ids.append(a, try func.add(a, .{ .kind = .{ .unsupported = "for" }, .span = fs.span }));
        return;
    }
    if (fs.initializer) |init| try lowerStmt(ctx, ids, init.*);
    const cond: HirId = if (fs.condition) |c| try lowerExpr(ctx, c) else try func.add(a, .{ .kind = .{ .bool = true }, .span = fs.span });
    try ctx.loop_depths.append(a, ctx.scopes.items.len);
    // Loop body = the user body, then the increment expression (runs at the end of each iteration).
    var body_ids = std.ArrayListUnmanaged(HirId).empty;
    defer body_ids.deinit(a);
    try ctx.pushScope();
    try lowerStmt(ctx, &body_ids, fs.body.*);
    if (fs.increment) |inc| try body_ids.append(a, try lowerExpr(ctx, inc));
    try ctx.popScopeReleases(&body_ids);
    _ = ctx.loop_depths.pop();
    const body = hir.Block{ .nodes = try a.dupe(HirId, body_ids.items) };
    try ids.append(a, try func.add(a, .{ .kind = .{ .loop_ = .{ .cond = cond, .body = body } }, .span = fs.span }));
}

fn isStringTid(tid: hir.TypeId) bool {
    const st = mir.type_store orelse return false;
    if (tid == hir.unset_ty or @intFromEnum(tid) >= st.count()) return false;
    return st.get(tid) == .string;
}

fn stringMethodName(ctx: *Ctx, fa: ast.FieldAccess) ?[]const u8 {
    const ir = ctx.ir orelse return null;
    const st = mir.type_store orelse return null; // set by the emit path / driver; null in bare shadow
    const rtid = ir.typeOf(fa.object) orelse return null;
    if (@intFromEnum(rtid) >= st.count()) return null;
    if (st.get(rtid) != .string) return null;
    const nm = std.fmt.allocPrint(ctx.allocator, "string_{s}", .{fa.field}) catch return null;
    return ctx.func.internName(ctx.allocator, nm) catch {
        ctx.allocator.free(nm);
        return null;
    };
}

const Scope = std.ArrayListUnmanaged([]const u8);

const Ctx = struct {
    allocator: std.mem.Allocator,
    func: *hir.Func,
    ir: ?*const infer.TypedIr,
    scopes: std.ArrayListUnmanaged(Scope) = .empty, // lexical scope stack; each holds owned local names
    owned: std.StringHashMapUnmanaged(hir.TypeId) = .empty, // in-scope owned local name -> TypeId (lets the emit path gate ARC ops by type; unset_ty when sema could not type it)
    loop_depths: std.ArrayListUnmanaged(usize) = .empty, // scope-stack depth at each enclosing loop
    tmp_ctr: usize = 0, // fresh-name counter for synthesised locals (e.g. a switch discriminant temp)

    fn deinit(self: *Ctx) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.owned.deinit(self.allocator);
        self.loop_depths.deinit(self.allocator);
    }

    fn ownedExpr(self: *Ctx, e: *const ast.Expression) bool {
        const ir = self.ir orelse return false;
        return ir.ownedOf(e) orelse false;
    }

    fn pushScope(self: *Ctx) !void {
        try self.scopes.append(self.allocator, .empty);
    }

    fn declareOwned(self: *Ctx, name: []const u8, ty: hir.TypeId) !void {
        try self.scopes.items[self.scopes.items.len - 1].append(self.allocator, name);
        try self.owned.put(self.allocator, name, ty);
    }

    // Emit `release` nodes for the owned locals of the top scope into `ids`, then pop it.
    fn popScopeReleases(self: *Ctx, ids: *std.ArrayListUnmanaged(HirId)) !void {
        var scope = self.scopes.pop().?;
        defer scope.deinit(self.allocator);
        for (scope.items) |name| {
            try self.appendRelease(ids, name);
            _ = self.owned.remove(name);
        }
    }

    // Emit releases for scopes [from_depth .. top], skipping `skip` (a moved-out local). Does not pop.
    fn releaseScopesDownTo(self: *Ctx, ids: *std.ArrayListUnmanaged(HirId), from_depth: usize, skip: ?[]const u8) !void {
        var d = self.scopes.items.len;
        while (d > from_depth) {
            d -= 1;
            for (self.scopes.items[d].items) |name| {
                if (skip) |s| if (std.mem.eql(u8, s, name)) continue;
                try self.appendRelease(ids, name);
            }
        }
    }

    fn appendRelease(self: *Ctx, ids: *std.ArrayListUnmanaged(HirId), name: []const u8) !void {
        // Stamp the released value with the owned local's TypeId so HIR->MIR carries it and the emit path can
        // gate the release by type (only strings, whose dtor is null, are emittable ARC today).
        const ty = self.owned.get(name) orelse hir.unset_ty;
        const load = try self.func.add(self.allocator, .{ .kind = .{ .ident = name }, .ty = ty, .span = zeroSpan() });
        const rel = try self.func.add(self.allocator, .{ .kind = .{ .release = load }, .span = zeroSpan() });
        try ids.append(self.allocator, rel);
    }
};

pub fn lowerFunc(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, ir: ?*const infer.TypedIr) !hir.Func {
    return lowerFuncTyped(allocator, fn_decl, ir, null);
}

// As lowerFunc, but with resolved parameter TypeIds (emit path). Stamping the param nodes matters because
// mem2reg forwards a param store->load, so the param VALUE itself becomes an arithmetic operand -- if it
// were left unset, the emit gate could not prove its width. Pass null (shadow) to leave params unset.
pub fn lowerFuncTyped(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, ir: ?*const infer.TypedIr, param_types: ?[]const hir.TypeId) !hir.Func {
    var func = hir.Func{ .name = fn_decl.name };
    errdefer func.deinit(allocator);
    var ctx = Ctx{ .allocator = allocator, .func = &func, .ir = ir };
    defer ctx.deinit();

    // Parameters: bind each to its name with a synthesized `let name = param(i)` at function entry, so body
    // idents resolve to the argument (HIR->MIR turns the let into a slot; the emit path maps param(i) to the
    // LLVM function argument). Params flow as the i64 word (see declarations.zig: the signature uses val_type
    // for every non-array param), so no coercion is modelled here.
    var pre = std.ArrayListUnmanaged(HirId).empty;
    defer pre.deinit(allocator);
    for (fn_decl.params, 0..) |p, i| {
        const pty: hir.TypeId = if (param_types) |pts| (if (i < pts.len) pts[i] else hir.unset_ty) else hir.unset_ty;
        const pnode = try func.add(allocator, .{ .kind = .{ .param = @intCast(i) }, .ty = pty, .span = fn_decl.body.span });
        const binding = try func.add(allocator, .{ .kind = .{ .let = .{ .name = p.name, .value = pnode } }, .span = fn_decl.body.span });
        try pre.append(allocator, binding);
    }

    const body = try lowerBlock(&ctx, fn_decl.body);
    if (pre.items.len == 0) {
        func.entry = body;
    } else {
        var all = std.ArrayListUnmanaged(HirId).empty;
        errdefer all.deinit(allocator);
        try all.appendSlice(allocator, pre.items);
        try all.appendSlice(allocator, body.nodes);
        allocator.free(@constCast(body.nodes));
        func.entry = hir.Block{ .nodes = try all.toOwnedSlice(allocator) };
    }
    return func;
}

fn lowerBlock(ctx: *Ctx, block: ast.Block) !hir.Block {
    var ids = std.ArrayListUnmanaged(HirId).empty;
    defer ids.deinit(ctx.allocator);
    try ctx.pushScope();
    var terminated = false;
    for (block.statements) |stmt| {
        try lowerStmt(ctx, &ids, stmt);
        // If this statement is a control exit, later statements are dead and the scope releases were
        // already emitted before the exit node; do not emit block-end releases on top.
        if (isExitStmt(stmt)) {
            terminated = true;
            break;
        }
    }
    if (terminated) {
        // Pop the scope WITHOUT block-end releases (the exit path emitted its own).
        var scope = ctx.scopes.pop().?;
        for (scope.items) |name| _ = ctx.owned.remove(name);
        scope.deinit(ctx.allocator);
    } else {
        try ctx.popScopeReleases(&ids);
    }
    return hir.Block{ .nodes = try ctx.allocator.dupe(HirId, ids.items) };
}

fn isExitStmt(stmt: ast.Statement) bool {
    return stmt == .return_stmt or stmt == .break_stmt or stmt == .continue_stmt;
}

fn lowerStmt(ctx: *Ctx, ids: *std.ArrayListUnmanaged(HirId), stmt: ast.Statement) anyerror!void {
    const a = ctx.allocator;
    const func = ctx.func;
    switch (stmt) {
        .block => |b| try ids.append(a, try func.add(a, .{ .kind = .{ .block = try lowerBlock(ctx, b) }, .span = b.span })),
        .let_stmt => |ls| {
            var value: ?HirId = null;
            if (ls.init) |e| {
                var v = try lowerExpr(ctx, e);
                const is_copy = e.kind == .ident and ctx.owned.contains(e.kind.ident);
                // Owned local's TypeId: a copy inherits the copied-from local's type; otherwise the
                // initialiser's sema type. Threaded so the emit path can gate ARC ops (retain/release) by type.
                const oty: hir.TypeId = if (is_copy)
                    (ctx.owned.get(e.kind.ident) orelse hir.unset_ty)
                else if (ctx.ir) |ir| (ir.typeOf(&e) orelse hir.unset_ty) else hir.unset_ty;
                if (is_copy) {
                    func.nodes.items[@intFromEnum(v)].ty = oty; // stamp the retained (copied-from) value too
                    v = try func.add(a, .{ .kind = .{ .retain = v }, .span = ls.span });
                }
                value = v;
                if (ctx.ownedExpr(&e) or is_copy) try ctx.declareOwned(ls.name, oty);
            }
            try ids.append(a, try func.add(a, .{ .kind = .{ .let = .{ .name = ls.name, .value = value } }, .span = ls.span }));
        },
        .expr_stmt => |es| try ids.append(a, try lowerExpr(ctx, es.expr)),
        .return_stmt => |rs| {
            if (rs.value) |*e| {
                const raw = try lowerExpr(ctx, e.*);
                // Move-out: a `return x` that returns an owned local must not release it.
                const moved: ?[]const u8 = if (e.kind == .ident and ctx.owned.contains(e.kind.ident)) e.kind.ident else null;
                // Bind the return value to a temp FIRST so its expression (which may READ a local the scope
                // releases below would free) is evaluated BEFORE those releases -- otherwise a release is
                // lowered ahead of the use (a use-after-free: `return s.len()` released `s` before the call).
                // A raw let (constructed here, not via let_stmt) never triggers the copy-retain, so a moved
                // owned local is aliased, not retained.
                const rname = try std.fmt.allocPrint(a, "__ret{d}", .{ctx.tmp_ctr});
                ctx.tmp_ctr += 1;
                const rn = try func.internName(a, rname);
                try ids.append(a, try func.add(a, .{ .kind = .{ .let = .{ .name = rn, .value = raw } }, .span = rs.span }));

                try ctx.releaseScopesDownTo(ids, 0, moved);

                // Return-acquisition (string returns): the AST RETAINS a returned BORROWED owned value (the
                // caller gets a new owner). A moved owned local (`moved != null`) or a fresh owned temporary
                // (`ownedExpr`) already transfers ownership and must NOT be retained. Only `string` is an
                // emittable owned return today.
                const rref = try func.add(a, .{ .kind = .{ .ident = rn }, .span = rs.span });
                if (moved == null and !ctx.ownedExpr(e)) {
                    if (ctx.ir) |ir| if (ir.typeOf(e)) |tid| if (isStringTid(tid)) {
                        func.nodes.items[@intFromEnum(rref)].ty = tid;
                        try ids.append(a, try func.add(a, .{ .kind = .{ .retain = rref }, .span = rs.span }));
                    };
                }
                try ids.append(a, try func.add(a, .{ .kind = .{ .ret = rref }, .span = rs.span }));
            } else {
                try ctx.releaseScopesDownTo(ids, 0, null);
                try ids.append(a, try func.add(a, .{ .kind = .{ .ret = null }, .span = rs.span }));
            }
        },
        .if_stmt => |is| {
            const cond = try lowerExpr(ctx, is.condition);
            const then_block = try lowerStmtAsBlock(ctx, is.then_branch.*);
            const else_block = if (is.else_branch) |e| try lowerStmtAsBlock(ctx, e.*) else hir.Block{};
            try ids.append(a, try func.add(a, .{ .kind = .{ .if_ = .{ .cond = cond, .then = then_block, .else_ = else_block } }, .span = is.span }));
        },
        .while_stmt => |ws| {
            const cond = try lowerExpr(ctx, ws.condition);
            try ctx.loop_depths.append(a, ctx.scopes.items.len);
            const body = try lowerStmtAsBlock(ctx, ws.body.*);
            _ = ctx.loop_depths.pop();
            try ids.append(a, try func.add(a, .{ .kind = .{ .loop_ = .{ .cond = cond, .body = body } }, .span = ws.span }));
        },
        .break_stmt => |bs| {
            const loop_depth = if (ctx.loop_depths.items.len > 0) ctx.loop_depths.items[ctx.loop_depths.items.len - 1] else ctx.scopes.items.len;
            try ctx.releaseScopesDownTo(ids, loop_depth, null);
            try ids.append(a, try func.add(a, .{ .kind = .brk, .span = bs.span }));
        },
        .continue_stmt => |cs| {
            const loop_depth = if (ctx.loop_depths.items.len > 0) ctx.loop_depths.items[ctx.loop_depths.items.len - 1] else ctx.scopes.items.len;
            try ctx.releaseScopesDownTo(ids, loop_depth, null);
            try ids.append(a, try func.add(a, .{ .kind = .cont, .span = cs.span }));
        },
        .switch_stmt => |ss| try lowerSwitch(ctx, ids, ss),
        .for_stmt => |fs| try lowerFor(ctx, ids, fs),
        else => try ids.append(a, try func.add(a, .{ .kind = .{ .unsupported = @tagName(stmt) }, .span = zeroSpan() })),
    }
}

fn lowerStmtAsBlock(ctx: *Ctx, stmt: ast.Statement) anyerror!hir.Block {
    if (stmt == .block) return lowerBlock(ctx, stmt.block);
    // Wrap a single statement in its own scope so its releases are placed correctly.
    var ids = std.ArrayListUnmanaged(HirId).empty;
    defer ids.deinit(ctx.allocator);
    try ctx.pushScope();
    try lowerStmt(ctx, &ids, stmt);
    if (isExitStmt(stmt)) {
        var scope = ctx.scopes.pop().?;
        for (scope.items) |name| _ = ctx.owned.remove(name);
        scope.deinit(ctx.allocator);
    } else {
        try ctx.popScopeReleases(&ids);
    }
    return hir.Block{ .nodes = try ctx.allocator.dupe(HirId, ids.items) };
}

// Desugar a `switch` to an if-chain: bind the discriminant once (it may have side effects), then for each
// case test `disc == v0 | disc == v1 | ...` (a side-effect-free OR of eq compares, so bit_or of the bool
// words is exact and needs no short-circuit) and run its body, falling through to the default otherwise.
// A GUARDED case (`case v if cond`) has fall-to-default-on-guard-false semantics that this desugaring does
// not model, so a switch with any guard lowers to `.unsupported` (the emit path falls back to the AST).
fn lowerSwitch(ctx: *Ctx, ids: *std.ArrayListUnmanaged(HirId), ss: ast.SwitchStmt) anyerror!void {
    const a = ctx.allocator;
    const func = ctx.func;
    for (ss.cases) |c| if (c.guard != null) {
        try ids.append(a, try func.add(a, .{ .kind = .{ .unsupported = "switch_guard" }, .span = ss.span }));
        return;
    };

    // Bind the discriminant once. Thread its TypeId onto the references below so the `disc == v` compares can
    // prove an integer kind (an untyped ident load would make the emit path reject the whole function).
    const dty: hir.TypeId = if (ctx.ir) |ir| (ir.typeOf(&ss.discriminant) orelse hir.unset_ty) else hir.unset_ty;
    const disc_v = try lowerExpr(ctx, ss.discriminant);
    const nm = try std.fmt.allocPrint(a, "__sw{d}", .{ctx.tmp_ctr});
    ctx.tmp_ctr += 1;
    const dname = try func.internName(a, nm);
    try ids.append(a, try func.add(a, .{ .kind = .{ .let = .{ .name = dname, .value = disc_v } }, .span = ss.span }));

    // else-of-the-chain starts as the default body (or empty).
    var else_block: hir.Block = if (ss.default_case) |d| try lowerStmtAsBlock(ctx, d.*) else hir.Block{};

    // Build the chain from the LAST case to the FIRST, nesting each into the running else block.
    var i: usize = ss.cases.len;
    while (i > 0) {
        i -= 1;
        const c = ss.cases[i];
        // cond = OR over the case values of `disc == value`.
        var cond: ?HirId = null;
        for (c.values) |cv| {
            const disc_ref = try func.add(a, .{ .kind = .{ .ident = dname }, .ty = dty, .span = ss.span });
            const val_id = try lowerExpr(ctx, cv);
            // Stamp the eq/bit_or results with the discriminant type: their VALUE is 0/1, and typing them as
            // the (int/bool) discriminant type lets the emit path's bit_or/branch gates accept them (an untyped
            // result would be rejected). The OR of eq compares is exact + side-effect-free, so no short-circuit.
            const eq = try func.add(a, .{ .kind = .{ .binop = .{ .op = .eq, .lhs = disc_ref, .rhs = val_id } }, .ty = dty, .span = ss.span });
            cond = if (cond) |prev|
                try func.add(a, .{ .kind = .{ .binop = .{ .op = .bit_or, .lhs = prev, .rhs = eq } }, .ty = dty, .span = ss.span })
            else
                eq;
        }
        const then_block = try lowerStmtAsBlock(ctx, c.body.*);
        const if_id = try func.add(a, .{ .kind = .{ .if_ = .{ .cond = cond orelse unreachable, .then = then_block, .else_ = else_block } }, .span = ss.span });
        else_block = hir.Block{ .nodes = try a.dupe(HirId, &.{if_id}) };
    }

    // Emit the head of the chain (each case's if node lives inside `else_block`). The block slice itself is
    // not freed here -- like the other `lowerStmtAsBlock` blocks stored in if_ nodes, it lives with the func.
    for (else_block.nodes) |n| try ids.append(a, n);
}

fn lowerExpr(ctx: *Ctx, expr: ast.Expression) anyerror!HirId {
    const a = ctx.allocator;
    const func = ctx.func;
    const span = expr.span;
    const eid = expr.id;
    const id = switch (expr.kind) {
        .literal => |lit| switch (lit) {
            .integer => |v| try func.add(a, .{ .kind = .{ .int = v }, .span = span }),
            .float => |v| try func.add(a, .{ .kind = .{ .float = v }, .span = span }),
            .bool => |v| try func.add(a, .{ .kind = .{ .bool = v }, .span = span }),
            .string => |v| try func.add(a, .{ .kind = .{ .str = v }, .span = span }),
            .null => try func.add(a, .{ .kind = .null, .span = span }),
            .undefined => try func.add(a, .{ .kind = .undefined, .span = span }),
            else => try func.add(a, .{ .kind = .{ .unsupported = "literal" }, .span = span }),
        },
        .ident => |name| try func.add(a, .{ .kind = .{ .ident = name }, .span = span }),
        .binary => |b| blk: {
            if (b.op == .assign) {
                const target = try lowerExpr(ctx, b.left.*);
                const value = try lowerExpr(ctx, b.right.*);
                break :blk try func.add(a, .{ .kind = .{ .assign = .{ .target = target, .value = value } }, .span = span });
            }
            const lhs = try lowerExpr(ctx, b.left.*);
            const rhs = try lowerExpr(ctx, b.right.*);
            break :blk try func.add(a, .{ .kind = .{ .binop = .{ .op = mapBinOp(b.op), .lhs = lhs, .rhs = rhs } }, .span = span });
        },
        .unary => |u| blk: {
            const operand = try lowerExpr(ctx, u.operand.*);
            break :blk try func.add(a, .{ .kind = .{ .unop = .{ .op = mapUnOp(u.op), .operand = operand } }, .span = span });
        },
        .call => |c| blk: {
            const sym = if (ctx.ir) |ir| ir.symOf(&expr) else null; // resolved callee (emit-path call graph)
            // Method-call fast path: `recv.method(args)` on a string receiver lowers to a NAMED call
            // `string_<method>(recv, args...)` -- the receiver becomes the first argument (self), matching the
            // AST calling convention. A bare field-access callee is nameless and the emit path would reject
            // it; naming it here is what makes string methods emittable (C0).
            if (c.callee.kind == .field_access) {
                if (stringMethodName(ctx, c.callee.kind.field_access)) |mname| {
                    const recv = try lowerExpr(ctx, c.callee.kind.field_access.object.*);
                    var args = std.ArrayListUnmanaged(HirId).empty;
                    defer args.deinit(a);
                    try args.append(a, recv);
                    for (c.args) |arg| try args.append(a, try lowerExpr(ctx, arg));
                    const owned_m = try a.dupe(HirId, args.items);
                    const callee_ident = try func.add(a, .{ .kind = .{ .ident = mname }, .span = span });
                    break :blk try func.add(a, .{ .kind = .{ .call = .{ .callee = callee_ident, .args = owned_m, .sym = sym } }, .span = span });
                }
            }
            const callee = try lowerExpr(ctx, c.callee.*);
            const owned = try lowerExprSlice(ctx, c.args);
            break :blk try func.add(a, .{ .kind = .{ .call = .{ .callee = callee, .args = owned, .sym = sym } }, .span = span });
        },
        .field_access => |fa| blk: {
            const object = try lowerExpr(ctx, fa.object.*);
            break :blk try func.add(a, .{ .kind = .{ .field = .{ .object = object, .name = fa.field } }, .span = span });
        },
        .index => |ix| blk: {
            const object = try lowerExpr(ctx, ix.object.*);
            const idx = try lowerExpr(ctx, ix.index.*);
            break :blk try func.add(a, .{ .kind = .{ .index = .{ .object = object, .idx = idx } }, .span = span });
        },
        .block_expr => |b| try func.add(a, .{ .kind = .{ .block = try lowerBlock(ctx, b) }, .span = span }),
        .await_expr => |aw| blk: {
            const operand = try lowerExpr(ctx, aw.operand.*);
            break :blk try func.add(a, .{ .kind = .{ .await_ = operand }, .span = span });
        },
        .go_expr => |aw| blk: {
            const operand = try lowerExpr(ctx, aw.operand.*);
            break :blk try func.add(a, .{ .kind = .{ .spawn_ = operand }, .span = span });
        },
        .cast => |c| blk: {
            const operand = try lowerExpr(ctx, c.expr.*);
            break :blk try func.add(a, .{ .kind = .{ .cast = operand }, .span = span });
        },
        .if_expr => |ie| blk: {
            const cond = try lowerExpr(ctx, ie.condition.*);
            const then_v = try lowerExpr(ctx, ie.then_branch.*);
            const else_v = try lowerExpr(ctx, ie.else_branch.*);
            break :blk try func.add(a, .{ .kind = .{ .if_expr = .{ .cond = cond, .then = then_v, .else_ = else_v } }, .span = span });
        },
        .nullish_coalesce => |nc| blk: {
            const lhs = try lowerExpr(ctx, nc.left.*);
            const rhs = try lowerExpr(ctx, nc.right.*);
            break :blk try func.add(a, .{ .kind = .{ .nullish = .{ .lhs = lhs, .rhs = rhs } }, .span = span });
        },
        .optional_chaining => |oc| blk: {
            const object = try lowerExpr(ctx, oc.object.*);
            break :blk try func.add(a, .{ .kind = .{ .optional_chain = .{ .object = object, .name = oc.field } }, .span = span });
        },
        .generic_call => |gc| blk: {
            const callee = try lowerExpr(ctx, gc.callee.*);
            const owned = try lowerExprSlice(ctx, gc.args);
            const sym = if (ctx.ir) |ir| ir.symOf(&expr) else null;
            break :blk try func.add(a, .{ .kind = .{ .generic_call = .{ .callee = callee, .args = owned, .sym = sym } }, .span = span });
        },
        .struct_init => |si| blk: {
            const owned = try lowerFieldSlice(ctx, si.fields);
            const names = try a.alloc([]const u8, si.fields.len);
            for (si.fields, 0..) |f, i| names[i] = f.name;
            break :blk try func.add(a, .{ .kind = .{ .struct_init = .{ .type_name = si.type_name, .fields = owned, .field_names = names } }, .span = span });
        },
        .enum_init => |ei| blk: {
            const owned = try lowerFieldSlice(ctx, ei.fields);
            break :blk try func.add(a, .{ .kind = .{ .enum_init = .{ .name = ei.enum_name, .variant = ei.variant, .fields = owned } }, .span = span });
        },
        .tuple => |elems| blk: {
            const owned = try lowerExprSlice(ctx, elems);
            break :blk try func.add(a, .{ .kind = .{ .tuple = owned }, .span = span });
        },
        .template_expr => |te| blk: {
            const owned = try lowerExprSlice(ctx, te.parts);
            break :blk try func.add(a, .{ .kind = .{ .template = owned }, .span = span });
        },
        .range => |r| blk: {
            const start = try lowerExpr(ctx, r.start.*);
            const end = try lowerExpr(ctx, r.end.*);
            break :blk try func.add(a, .{ .kind = .{ .range = .{ .start = start, .end = end, .inclusive = r.inclusive } }, .span = span });
        },
        .try_expr => |inner| blk: {
            const operand = try lowerExpr(ctx, inner.*);
            break :blk try func.add(a, .{ .kind = .{ .try_ = operand }, .span = span });
        },
        .closure => try func.add(a, .{ .kind = .{ .closure = .{ .body = HirId.none } }, .span = span }),
        else => try func.add(a, .{ .kind = .{ .unsupported = @tagName(expr.kind) }, .span = span }),
    };
    ctx.func.nodes.items[@intFromEnum(id)].expr_id = eid;
    // Thread the concrete post-inference TypeId from the sema TypedIr (emit-path prerequisite: MIR/LIR
    // values must carry real types, not the placeholder). Leaves the placeholder where sema could not type
    // the expr (erased/generic positions) -- measured as coverage in the shadow.
    if (ctx.ir) |ir| {
        if (ir.typeOf2(eid)) |t| ctx.func.nodes.items[@intFromEnum(id)].ty = t;
    }
    return id;
}

fn lowerExprSlice(ctx: *Ctx, exprs: []const ast.Expression) ![]const HirId {
    var out = std.ArrayListUnmanaged(HirId).empty;
    defer out.deinit(ctx.allocator);
    for (exprs) |e| try out.append(ctx.allocator, try lowerExpr(ctx, e));
    return ctx.allocator.dupe(HirId, out.items);
}

fn lowerFieldSlice(ctx: *Ctx, fields: []const ast.ObjectFieldInit) ![]const HirId {
    var out = std.ArrayListUnmanaged(HirId).empty;
    defer out.deinit(ctx.allocator);
    for (fields) |f| try out.append(ctx.allocator, try lowerExpr(ctx, f.value));
    return ctx.allocator.dupe(HirId, out.items);
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "" };
}

fn mapBinOp(op: ast.BinaryOp) hir.BinOp {
    return switch (op) {
        .add => .add, .sub => .sub, .mul => .mul, .div => .div, .mod => .mod,
        .eq => .eq, .ne => .ne, .lt => .lt, .gt => .gt, .le => .le, .ge => .ge,
        .bit_and => .bit_and, .bit_or => .bit_or, .bit_xor => .bit_xor,
        .And => .@"and", .Or => .@"or", .shl => .shl, .shr => .shr,
        .assign => .assign,
    };
}

fn mapUnOp(op: ast.UnaryOp) hir.UnOp {
    return switch (op) {
        .neg => .neg, .not => .not, .bit_not => .bit_not,
    };
}
