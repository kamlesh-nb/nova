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
const infer = @import("../frontend/sema/infer.zig");

const HirId = hir.HirId;

const Scope = std.ArrayListUnmanaged([]const u8);

const Ctx = struct {
    allocator: std.mem.Allocator,
    func: *hir.Func,
    ir: ?*const infer.TypedIr,
    scopes: std.ArrayListUnmanaged(Scope) = .empty, // lexical scope stack; each holds owned local names
    owned: std.StringHashMapUnmanaged(void) = .empty, // all currently in-scope owned local names
    loop_depths: std.ArrayListUnmanaged(usize) = .empty, // scope-stack depth at each enclosing loop

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

    fn declareOwned(self: *Ctx, name: []const u8) !void {
        try self.scopes.items[self.scopes.items.len - 1].append(self.allocator, name);
        try self.owned.put(self.allocator, name, {});
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
        const load = try self.func.add(self.allocator, .{ .kind = .{ .ident = name }, .span = zeroSpan() });
        const rel = try self.func.add(self.allocator, .{ .kind = .{ .release = load }, .span = zeroSpan() });
        try ids.append(self.allocator, rel);
    }
};

pub fn lowerFunc(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, ir: ?*const infer.TypedIr) !hir.Func {
    var func = hir.Func{ .name = fn_decl.name };
    errdefer func.deinit(allocator);
    var ctx = Ctx{ .allocator = allocator, .func = &func, .ir = ir };
    defer ctx.deinit();

    func.entry = try lowerBlock(&ctx, fn_decl.body);
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
                if (is_copy) {
                    v = try func.add(a, .{ .kind = .{ .retain = v }, .span = ls.span });
                }
                value = v;
                if (ctx.ownedExpr(&e) or is_copy) try ctx.declareOwned(ls.name);
            }
            try ids.append(a, try func.add(a, .{ .kind = .{ .let = .{ .name = ls.name, .value = value } }, .span = ls.span }));
        },
        .expr_stmt => |es| try ids.append(a, try lowerExpr(ctx, es.expr)),
        .return_stmt => |rs| {
            const value: ?HirId = if (rs.value) |e| try lowerExpr(ctx, e) else null;
            // Move-out: a `return x` that returns an owned local must not release it.
            const moved: ?[]const u8 = if (rs.value) |e| (if (e.kind == .ident and ctx.owned.contains(e.kind.ident)) e.kind.ident else null) else null;
            try ctx.releaseScopesDownTo(ids, 0, moved);
            try ids.append(a, try func.add(a, .{ .kind = .{ .ret = value }, .span = rs.span }));
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
            const callee = try lowerExpr(ctx, c.callee.*);
            const owned = try lowerExprSlice(ctx, c.args);
            break :blk try func.add(a, .{ .kind = .{ .call = .{ .callee = callee, .args = owned } }, .span = span });
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
            break :blk try func.add(a, .{ .kind = .{ .generic_call = .{ .callee = callee, .args = owned } }, .span = span });
        },
        .struct_init => |si| blk: {
            const owned = try lowerFieldSlice(ctx, si.fields);
            break :blk try func.add(a, .{ .kind = .{ .struct_init = .{ .type_name = si.type_name, .fields = owned } }, .span = span });
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
