// ids.zig — F2 stage 4a: give every Expression a copy-surviving identity.
//
// WHY THIS EXISTS
// ---------------
// Stage 2i keyed TypedIr on the AST node's ADDRESS. Codegen takes Expression BY
// VALUE (`compileExpression(expr: ast.Expression)`), so by the time codegen asks
// "what type is this?", it holds a COPY at a different address and the lookup
// misses. That is why stage 3's absences plateaued at 1113 instead of ~0: the IR
// was not wrong, it was unreachable.
//
// I had written that exact counter-argument in the stage 2i commit and shipped
// the address anyway because it was cheaper. This pass is the correction.
//
// An id assigned before codegen runs travels with every copy. Addresses cannot.
//
// THE COLLISION HAZARD
// --------------------
// `ExprId.unassigned == 0`. If this walk misses a variant, those expressions all
// keep id 0 — and a map keyed on ExprId would happily map ALL of them to a single
// bucket, silently giving unrelated expressions each other's types. That failure
// is invisible and would be blamed on inference for weeks.
//
// So the invariant is enforced on BOTH sides:
//   - here: the walk is exhaustive (no `else =>`; adding an ExprKind variant is a
//     COMPILE error, not a silent miss);
//   - in TypedIr: `.unassigned` is refused outright, so any miss becomes a
//     visible absence in the stage-3 coverage number rather than a wrong type.
//
// Note the walk covers two places alpha.zig deliberately skips — `literal.array`
// / `literal.object` and JSX children — because alpha only cares about idents,
// whereas an id must reach EVERY expression or the guarantee is not a guarantee.
const std = @import("std");
const ast = @import("../ast.zig");

pub const Assigner = struct {
    next: u32 = 1, // 0 is `.unassigned` and must never be handed out.
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

    // ---- program ---------------------------------------------------------
    /// Takes Program by value to match sema/alpha.zig — `declarations` is a
    /// slice, so writes through it land in the real AST.
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
            // Unlike alpha.zig (which stops at the three above, since only those
            // hold renameable idents), an id must reach EVERY expression — a
            // const initialiser included.
            .const_decl => |*cd| try self.walkExpr(&cd.value),
            .union_decl, .import_decl, .export_decl, .trait_decl => {},
        }
    }

    fn walkFn(self: *Assigner, f: *ast.FunctionDecl) anyerror!void {
        try self.walkBlock(&f.body);
    }

    // ---- statements ------------------------------------------------------
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
            // ForStmt carries BOTH the C-style triple and the optional iterator
            // form; a `for (x of xs)` uses `iterator`, a `for (i=0;;)` uses
            // initializer/condition/increment. Walk all of them — whichever the
            // parser left null simply is not there.
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

    // ---- expressions -----------------------------------------------------
    /// Assigns `e` an id, then recurses. Exhaustive by construction: no `else`
    /// branch, so a new ExprKind variant fails to compile here rather than
    /// silently inheriting id 0.
    pub fn walkExpr(self: *Assigner, e: *ast.Expression) anyerror!void {
        e.id = self.fresh();
        switch (e.kind) {
            .range => |*r| {
                try self.walkExpr(r.start);
                try self.walkExpr(r.end);
            },
            .literal => |*lit| switch (lit.*) {
                // alpha.zig skips these — it only rewrites idents. An id must
                // reach every expression, so they are walked here.
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

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

fn mkLit(n: i64) ast.Expression {
    return .{ .kind = .{ .literal = .{ .integer = n } } };
}

test "ids: never hands out 0, because 0 means unassigned" {
    // If this ever fails, every expression sharing id 0 would collide onto one
    // TypedIr bucket and silently take each other's types.
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
    // This is the entire reason stage 4a exists. codegen takes Expression by
    // value; the copy is what codegen actually asks about.
    var a = Assigner.init();
    var e = mkLit(7);
    try a.walkExpr(&e);

    const copy = e; // exactly what `compileExpression(expr: ast.Expression)` gets
    try testing.expectEqual(e.id, copy.id); // identity survives
    try testing.expect(&e != &copy); // address does not
}

test "ids: reaches array literal elements (alpha.zig skips these)" {
    var a = Assigner.init();
    var items = [_]ast.Expression{ mkLit(1), mkLit(2) };
    var e = ast.Expression{ .kind = .{ .literal = .{ .array = &items } } };
    try a.walkExpr(&e);

    try testing.expect(items[0].id != .unassigned);
    try testing.expect(items[1].id != .unassigned);
    try testing.expect(items[0].id != items[1].id);
    try testing.expectEqual(@as(usize, 3), a.assigned); // the array + 2 elements
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
        try testing.expect(!seen.contains(x.id)); // no duplicates
        try seen.put(x.id, {});
    }
    try testing.expectEqual(@as(usize, 5), a.assigned);
}
