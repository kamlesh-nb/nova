// lower_ast_hir.zig — AST -> HIR, with ARC ops threaded in.
//
// Walks a function body and builds the flat HIR node table, and -- when a sema TypedIr is supplied --
// makes ARC explicit: a `let` whose initialiser sema marks OWNED (TypedIr.ownedOf) makes an owned local,
// which gets a `release` at the end of the function body; binding an owned local FROM another owned local
// (a copy) emits a `retain` for the new owner. This is the first ownership model (straight-line, function
// -scope releases); precise per-scope / per-exit placement is a refinement. It is what gives arc_elision
// (M4) balanced retain/release pairs to cancel. Correctness note: this runs only in the NOVA_OPT shadow
// today (nothing is emitted from HIR yet), so an imperfect placement cannot affect the produced program;
// it only affects how many pairs the elision pass can prove balanced. See docs/design/optimiser.md.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const hir = @import("hir.zig");
const infer = @import("../frontend/sema/infer.zig");

const HirId = hir.HirId;

const Ctx = struct {
    allocator: std.mem.Allocator,
    func: *hir.Func,
    ir: ?*const infer.TypedIr,
    owned_locals: std.StringHashMapUnmanaged(void) = .empty, // names of owned locals (function-scoped, v1)

    fn deinit(self: *Ctx) void {
        self.owned_locals.deinit(self.allocator);
    }

    fn ownedExpr(self: *Ctx, e: *const ast.Expression) bool {
        const ir = self.ir orelse return false;
        return ir.ownedOf(e) orelse false;
    }

    pub var arc_retains: usize = 0; // process-wide counters for the shadow report
    pub var arc_releases: usize = 0;
};

pub fn lowerFunc(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, ir: ?*const infer.TypedIr) !hir.Func {
    var func = hir.Func{ .name = fn_decl.name };
    errdefer func.deinit(allocator);
    var ctx = Ctx{ .allocator = allocator, .func = &func, .ir = ir };
    defer ctx.deinit();

    var ids = std.ArrayListUnmanaged(HirId).empty;
    defer ids.deinit(allocator);
    for (fn_decl.body.statements) |stmt| {
        try ids.append(allocator, try lowerStmt(&ctx, stmt));
    }
    func.entry = hir.Block{ .nodes = try allocator.dupe(HirId, ids.items) };

    // Publish the owned locals; HIR->MIR emits a `release` of each at every function exit (before ret),
    // which is where they belong (a release after a return would be dropped when the block terminates).
    var names = std.ArrayListUnmanaged([]const u8).empty;
    defer names.deinit(allocator);
    var it = ctx.owned_locals.keyIterator();
    while (it.next()) |name| try names.append(allocator, name.*);
    func.owned_locals = try allocator.dupe([]const u8, names.items);
    return func;
}

fn lowerBlock(ctx: *Ctx, block: ast.Block) !hir.Block {
    var ids = std.ArrayListUnmanaged(HirId).empty;
    defer ids.deinit(ctx.allocator);
    for (block.statements) |stmt| {
        try ids.append(ctx.allocator, try lowerStmt(ctx, stmt));
    }
    return hir.Block{ .nodes = try ctx.allocator.dupe(HirId, ids.items) };
}

fn lowerStmt(ctx: *Ctx, stmt: ast.Statement) anyerror!HirId {
    const a = ctx.allocator;
    const func = ctx.func;
    return switch (stmt) {
        .block => |b| func.add(a, .{ .kind = .{ .block = try lowerBlock(ctx, b) }, .span = b.span }),
        .let_stmt => |ls| blk: {
            var value: ?HirId = null;
            if (ls.init) |e| {
                var v = try lowerExpr(ctx, e);
                // Copying an owned local into a new binding takes a new reference -> retain.
                if (e.kind == .ident and ctx.owned_locals.contains(e.kind.ident)) {
                    v = try func.add(a, .{ .kind = .{ .retain = v }, .span = ls.span });
                    Ctx.arc_retains += 1;
                }
                value = v;
                // Track ownership of the new local.
                if (ctx.ownedExpr(&e) or (e.kind == .ident and ctx.owned_locals.contains(e.kind.ident))) {
                    try ctx.owned_locals.put(a, ls.name, {});
                }
            }
            break :blk func.add(a, .{ .kind = .{ .let = .{ .name = ls.name, .value = value } }, .span = ls.span });
        },
        .expr_stmt => |es| lowerExpr(ctx, es.expr),
        .return_stmt => |rs| blk: {
            const value: ?HirId = if (rs.value) |e| try lowerExpr(ctx, e) else null;
            break :blk func.add(a, .{ .kind = .{ .ret = value }, .span = rs.span });
        },
        .if_stmt => |is| blk: {
            const cond = try lowerExpr(ctx, is.condition);
            const then_block = try lowerStmtAsBlock(ctx, is.then_branch.*);
            const else_block = if (is.else_branch) |e| try lowerStmtAsBlock(ctx, e.*) else hir.Block{};
            break :blk func.add(a, .{ .kind = .{ .if_ = .{ .cond = cond, .then = then_block, .else_ = else_block } }, .span = is.span });
        },
        .while_stmt => |ws| blk: {
            const cond = try lowerExpr(ctx, ws.condition);
            const body = try lowerStmtAsBlock(ctx, ws.body.*);
            break :blk func.add(a, .{ .kind = .{ .loop_ = .{ .cond = cond, .body = body } }, .span = ws.span });
        },
        .break_stmt => |bs| func.add(a, .{ .kind = .brk, .span = bs.span }),
        .continue_stmt => |cs| func.add(a, .{ .kind = .cont, .span = cs.span }),
        else => func.add(a, .{ .kind = .{ .unsupported = @tagName(stmt) }, .span = zeroSpan() }),
    };
}

fn lowerStmtAsBlock(ctx: *Ctx, stmt: ast.Statement) anyerror!hir.Block {
    if (stmt == .block) return lowerBlock(ctx, stmt.block);
    const one = try ctx.allocator.alloc(HirId, 1);
    one[0] = try lowerStmt(ctx, stmt);
    return hir.Block{ .nodes = one };
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
    // Stamp source provenance for ownership + diagnostics.
    ctx.func.nodes.items[@intFromEnum(id)].expr_id = eid;
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
