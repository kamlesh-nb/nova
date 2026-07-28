
const std = @import("std");
const ast = @import("../ast.zig");

pub const Assigner = struct {
    next: u32 = 1,
    assigned: usize = 0,

    pub fn init() Assigner {
        return .{};
    }

    fn fresh(self: *Assigner) ast.ExprId {
        const id: ast.ExprId = @enumFromInt(self.next);
        self.next += 1;
        self.assigned += 1;
        return id;
    }

    pub fn run(self: *Assigner, program: ast.Program) anyerror!void {
        for (program.declarations) |*d| try self.walkDecl(d);
    }

    pub fn walkDecl(self: *Assigner, d: *ast.Declaration) anyerror!void {
        switch (d.*) {
            .fn_decl => |*f| try self.walkFn(f),
            .struct_decl => |*sd| {
                for (sd.methods) |*m| try self.walkFn(&m.decl);
            },
            .enum_decl => |*ed| {
                for (ed.methods) |*m| try self.walkFn(&m.decl);
            },

            .const_decl => |*cd| try self.walkExpr(&cd.value),
            .union_decl, .import_decl, .export_decl, .trait_decl => {},
        }
    }

    fn walkFn(self: *Assigner, f: *ast.FunctionDecl) anyerror!void {
        try self.walkBlock(&f.body);
    }

    pub fn walkBlock(self: *Assigner, b: *ast.Block) anyerror!void {
        for (b.statements) |*s| try self.walkStmt(s);
    }

    pub fn walkStmt(self: *Assigner, s: *ast.Statement) anyerror!void {
        switch (s.*) {
            .block => |*b| try self.walkBlock(b),
            .let_stmt => |*ls| {
                if (ls.init) |*i| try self.walkExpr(i);
            },
            .expr_stmt => |*es| try self.walkExpr(&es.expr),
            .if_stmt => |*is| {
                try self.walkExpr(&is.condition);
                try self.walkStmt(is.then_branch);
                if (is.else_branch) |eb| try self.walkStmt(eb);
            },
            .while_stmt => |*ws| {
                try self.walkExpr(&ws.condition);
                try self.walkStmt(ws.body);
            },

            .for_stmt => |*fs| {
                if (fs.initializer) |i| try self.walkStmt(i);
                if (fs.condition) |*c| try self.walkExpr(c);
                if (fs.increment) |*i| try self.walkExpr(i);
                if (fs.iterator) |*it| try self.walkExpr(it.iterable);
                try self.walkStmt(fs.body);
            },
            .switch_stmt => |*ss| {
                try self.walkExpr(&ss.discriminant);
                for (ss.cases) |*c| {
                    for (c.values) |*v| try self.walkExpr(v);
                    try self.walkStmt(c.body);
                }
                if (ss.default_case) |dc| try self.walkStmt(dc);
            },
            .return_stmt => |*rs| {
                if (rs.value) |*v| try self.walkExpr(v);
            },
            .defer_stmt => |*ds| try self.walkExpr(&ds.expr),
            .break_stmt, .continue_stmt => {},
        }
    }

    pub fn walkExpr(self: *Assigner, e: *ast.Expression) anyerror!void {
        e.id = self.fresh();
        switch (e.kind) {
            .range => |*r| {
                try self.walkExpr(r.start);
                try self.walkExpr(r.end);
            },
            .literal => |*lit| switch (lit.*) {

                .array => |items| {
                    for (items) |*i| try self.walkExpr(i);
                },
                .object => |fields| {
                    for (fields) |*f| try self.walkExpr(&f.value);
                },
                .integer, .float, .decimal, .string, .bool, .null, .undefined => {},
            },
            .ident => {},
            .binary => |*b| {
                try self.walkExpr(b.left);
                try self.walkExpr(b.right);
            },
            .unary => |*u| try self.walkExpr(u.operand),
            .call => |*c| {
                try self.walkExpr(c.callee);
                for (c.args) |*a| try self.walkExpr(a);
            },
            .generic_call => |*g| {
                try self.walkExpr(g.callee);
                for (g.args) |*a| try self.walkExpr(a);
            },
            .field_access => |*f| try self.walkExpr(f.object),
            .index => |*i| {
                try self.walkExpr(i.object);
                try self.walkExpr(i.index);
            },
            .struct_init => |*si| {
                for (si.fields) |*f| try self.walkExpr(&f.value);
            },
            .enum_init => |*ei| {
                for (ei.fields) |*f| try self.walkExpr(&f.value);
            },
            .cast => |*c| try self.walkExpr(c.expr),
            .optional_chaining => |*o| try self.walkExpr(o.object),
            .nullish_coalesce => |*n| {
                try self.walkExpr(n.left);
                try self.walkExpr(n.right);
            },
            .tuple => |items| {
                for (items) |*i| try self.walkExpr(i);
            },
            .if_expr => |*ie| {
                try self.walkExpr(ie.condition);
                try self.walkExpr(ie.then_branch);
                try self.walkExpr(ie.else_branch);
            },
            .try_expr => |inner| try self.walkExpr(inner),
            .catch_expr => |*ce| {
                try self.walkExpr(ce.expr);
                try self.walkExpr(ce.handler);
            },
            .block_expr => |*b| try self.walkBlock(b),
            .template_expr => |*t| {
                for (t.parts) |*p| try self.walkExpr(p);
            },
            .await_expr, .go_expr => |*a| try self.walkExpr(a.operand),
            .closure => |*cl| {
                switch (cl.body) {
                    .expr => |ex| try self.walkExpr(ex),
                    .block => |*b| try self.walkBlock(@constCast(b)),
                }
            },
            .jsx_element => |*j| try self.walkJsx(j),
        }
    }

    fn walkJsx(self: *Assigner, j: *ast.JsxElement) anyerror!void {
        for (j.attributes) |*a| {
            switch (a.value) {
                .expression => |*e| try self.walkExpr(e),
                .string_literal => {},
            }
        }
        for (j.children) |*c| {
            switch (c.*) {
                .element => |*el| try self.walkJsx(el),
                .expression => |*e| try self.walkExpr(e),
                .statement => |*s| try self.walkStmt(s),
                .text => {},
            }
        }
    }
};

const testing = std.testing;

fn mkLit(n: i64) ast.Expression {
    return .{ .kind = .{ .literal = .{ .integer = n } } };
}

test "ids: never hands out 0, because 0 means unassigned" {

    var a = Assigner.init();
    var e = mkLit(1);
    try a.walkExpr(&e);
    try testing.expect(e.id != .unassigned);
    try testing.expect(@intFromEnum(e.id) != 0);
}

test "ids: distinct expressions get distinct ids" {
    var a = Assigner.init();
    var l = mkLit(1);
    var r = mkLit(2);
    var e = ast.Expression{ .kind = .{ .binary = .{
        .left = &l,
        .right = &r,
        .op = .add,
        .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t" },
    } } };
    try a.walkExpr(&e);

    try testing.expect(e.id != .unassigned);
    try testing.expect(l.id != .unassigned);
    try testing.expect(r.id != .unassigned);
    try testing.expect(e.id != l.id);
    try testing.expect(l.id != r.id);
    try testing.expectEqual(@as(usize, 3), a.assigned);
}

test "ids: THE POINT — an id survives a copy, an address does not" {

    var a = Assigner.init();
    var e = mkLit(7);
    try a.walkExpr(&e);

    const copy = e;
    try testing.expectEqual(e.id, copy.id);
    try testing.expect(&e != &copy);
}

test "ids: reaches array literal elements (alpha.zig skips these)" {
    var a = Assigner.init();
    var items = [_]ast.Expression{ mkLit(1), mkLit(2) };
    var e = ast.Expression{ .kind = .{ .literal = .{ .array = &items } } };
    try a.walkExpr(&e);

    try testing.expect(items[0].id != .unassigned);
    try testing.expect(items[1].id != .unassigned);
    try testing.expect(items[0].id != items[1].id);
    try testing.expectEqual(@as(usize, 3), a.assigned);
}

test "ids: nested structure is fully covered" {
    var a = Assigner.init();
    var inner_l = mkLit(1);
    var inner_r = mkLit(2);
    var inner = ast.Expression{ .kind = .{ .binary = .{
        .left = &inner_l,
        .right = &inner_r,
        .op = .add,
        .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t" },
    } } };
    var outer_r = mkLit(3);
    var outer = ast.Expression{ .kind = .{ .binary = .{
        .left = &inner,
        .right = &outer_r,
        .op = .mul,
        .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t" },
    } } };
    try a.walkExpr(&outer);

    var seen = std.AutoHashMap(ast.ExprId, void).init(testing.allocator);
    defer seen.deinit();
    for ([_]ast.Expression{ outer, inner, inner_l, inner_r, outer_r }) |x| {
        try testing.expect(x.id != .unassigned);
        try testing.expect(!seen.contains(x.id));
        try seen.put(x.id, {});
    }
    try testing.expectEqual(@as(usize, 5), a.assigned);
}
