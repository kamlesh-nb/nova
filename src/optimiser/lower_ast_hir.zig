// lower_ast_hir.zig — AST -> HIR.
//
// Walks a function body and builds the flat HIR node table. Desugaring and TypeId attachment mature over
// M1; this checkpoint (M1a) covers the core expression and statement forms and lowers anything else to
// `.unsupported` (tagged with the AST kind) so lowering never crashes on real corpus code and coverage
// is measurable. Sugar that is already desugared here: if/while as explicit if_/loop_ nodes. See
// docs/design/optimiser.md.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const hir = @import("hir.zig");

const HirId = hir.HirId;

// Lower one function to HIR. `inst` selects a monomorphisation instance (null = non-generic); it is
// carried for the later TypeId-attachment pass and unused at M1a.
pub fn lowerFunc(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, inst: ?hir.TypeId) !hir.Func {
    var func = hir.Func{ .name = fn_decl.name, .inst = inst };
    errdefer func.deinit(allocator);
    func.entry = try lowerBlock(allocator, &func, fn_decl.body);
    return func;
}

fn lowerBlock(allocator: std.mem.Allocator, func: *hir.Func, block: ast.Block) !hir.Block {
    var ids = std.ArrayListUnmanaged(HirId).empty;
    defer ids.deinit(allocator);
    for (block.statements) |stmt| {
        try ids.append(allocator, try lowerStmt(allocator, func, stmt));
    }
    const owned = try allocator.dupe(HirId, ids.items);
    return hir.Block{ .nodes = owned };
}

fn lowerStmt(allocator: std.mem.Allocator, func: *hir.Func, stmt: ast.Statement) anyerror!HirId {
    return switch (stmt) {
        .block => |b| func.add(allocator, .{ .kind = .{ .block = try lowerBlock(allocator, func, b) }, .span = b.span }),
        .let_stmt => |ls| blk: {
            const value: ?HirId = if (ls.init) |e| try lowerExpr(allocator, func, e) else null;
            break :blk func.add(allocator, .{ .kind = .{ .let = .{ .name = ls.name, .value = value } }, .span = ls.span });
        },
        .expr_stmt => |es| lowerExpr(allocator, func, es.expr),
        .return_stmt => |rs| blk: {
            const value: ?HirId = if (rs.value) |e| try lowerExpr(allocator, func, e) else null;
            break :blk func.add(allocator, .{ .kind = .{ .ret = value }, .span = rs.span });
        },
        .if_stmt => |is| blk: {
            const cond = try lowerExpr(allocator, func, is.condition);
            const then_block = try lowerStmtAsBlock(allocator, func, is.then_branch.*);
            const else_block = if (is.else_branch) |e| try lowerStmtAsBlock(allocator, func, e.*) else hir.Block{};
            break :blk func.add(allocator, .{ .kind = .{ .if_ = .{ .cond = cond, .then = then_block, .else_ = else_block } }, .span = is.span });
        },
        .while_stmt => |ws| blk: {
            const cond = try lowerExpr(allocator, func, ws.condition);
            const body = try lowerStmtAsBlock(allocator, func, ws.body.*);
            break :blk func.add(allocator, .{ .kind = .{ .loop_ = .{ .cond = cond, .body = body } }, .span = ws.span });
        },
        .break_stmt => |bs| func.add(allocator, .{ .kind = .brk, .span = bs.span }),
        .continue_stmt => |cs| func.add(allocator, .{ .kind = .cont, .span = cs.span }),
        // for/switch/defer desugar in later checkpoints; mark for coverage until then.
        else => func.add(allocator, .{ .kind = .{ .unsupported = @tagName(stmt) }, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "" } }),
    };
}

// A statement used as a block body (the then/else/loop arm) may be a `.block` or a single statement.
fn lowerStmtAsBlock(allocator: std.mem.Allocator, func: *hir.Func, stmt: ast.Statement) anyerror!hir.Block {
    if (stmt == .block) return lowerBlock(allocator, func, stmt.block);
    const one = try allocator.alloc(HirId, 1);
    one[0] = try lowerStmt(allocator, func, stmt);
    return hir.Block{ .nodes = one };
}

fn lowerExpr(allocator: std.mem.Allocator, func: *hir.Func, expr: ast.Expression) anyerror!HirId {
    const span = expr.span;
    return switch (expr.kind) {
        .literal => |lit| switch (lit) {
            .integer => |v| func.add(allocator, .{ .kind = .{ .int = v }, .span = span }),
            .float => |v| func.add(allocator, .{ .kind = .{ .float = v }, .span = span }),
            .bool => |v| func.add(allocator, .{ .kind = .{ .bool = v }, .span = span }),
            .string => |v| func.add(allocator, .{ .kind = .{ .str = v }, .span = span }),
            .null => func.add(allocator, .{ .kind = .null, .span = span }),
            .undefined => func.add(allocator, .{ .kind = .undefined, .span = span }),
            else => func.add(allocator, .{ .kind = .{ .unsupported = "literal" }, .span = span }),
        },
        .ident => |name| func.add(allocator, .{ .kind = .{ .ident = name }, .span = span }),
        .binary => |b| blk: {
            if (b.op == .assign) {
                const target = try lowerExpr(allocator, func, b.left.*);
                const value = try lowerExpr(allocator, func, b.right.*);
                break :blk func.add(allocator, .{ .kind = .{ .assign = .{ .target = target, .value = value } }, .span = span });
            }
            const lhs = try lowerExpr(allocator, func, b.left.*);
            const rhs = try lowerExpr(allocator, func, b.right.*);
            break :blk func.add(allocator, .{ .kind = .{ .binop = .{ .op = mapBinOp(b.op), .lhs = lhs, .rhs = rhs } }, .span = span });
        },
        .unary => |u| blk: {
            const operand = try lowerExpr(allocator, func, u.operand.*);
            break :blk func.add(allocator, .{ .kind = .{ .unop = .{ .op = mapUnOp(u.op), .operand = operand } }, .span = span });
        },
        .call => |c| blk: {
            const callee = try lowerExpr(allocator, func, c.callee.*);
            var args = std.ArrayListUnmanaged(HirId).empty;
            defer args.deinit(allocator);
            for (c.args) |a| try args.append(allocator, try lowerExpr(allocator, func, a));
            const owned = try allocator.dupe(HirId, args.items);
            break :blk func.add(allocator, .{ .kind = .{ .call = .{ .callee = callee, .args = owned } }, .span = span });
        },
        .field_access => |fa| blk: {
            const object = try lowerExpr(allocator, func, fa.object.*);
            break :blk func.add(allocator, .{ .kind = .{ .field = .{ .object = object, .name = fa.field } }, .span = span });
        },
        .index => |ix| blk: {
            const object = try lowerExpr(allocator, func, ix.object.*);
            const idx = try lowerExpr(allocator, func, ix.index.*);
            break :blk func.add(allocator, .{ .kind = .{ .index = .{ .object = object, .idx = idx } }, .span = span });
        },
        .block_expr => |b| func.add(allocator, .{ .kind = .{ .block = try lowerBlock(allocator, func, b) }, .span = span }),
        .await_expr => |aw| blk: {
            const operand = try lowerExpr(allocator, func, aw.operand.*);
            break :blk func.add(allocator, .{ .kind = .{ .await_ = operand }, .span = span });
        },
        // struct_init, generic_call, if_expr, closure, template, try/catch, cast, optional-chaining,
        // nullish-coalesce, tuple, range, enum_init, jsx, go: later checkpoints. Mark for coverage.
        else => func.add(allocator, .{ .kind = .{ .unsupported = @tagName(expr.kind) }, .span = span }),
    };
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
