//! Expression-id assignment: give every AST expression a stable, copy-safe
//! identity.
//!
//! Later semantic passes (type inference, monomorphisation, ownership/ARC,
//! lowering) need to attach information to individual expressions and look it up
//! again from a different place in the pipeline. The obvious key, the
//! expression's address, is unusable here: Nova's AST nodes are plain value
//! structs that get copied by value all over the compiler (stored into unions,
//! passed to helpers, returned), and a copy has a brand-new address while being
//! semantically the same node. Keying a side table on `&expr` would silently
//! break the moment a node is copied.
//!
//! This pass solves that once, up front, by walking the whole program in a
//! fixed order and stamping each [`ast.Expression`] with a small integer
//! [`ast.ExprId`] via [`Assigner.fresh`]. Because the id lives IN the node, it
//! travels with every copy, so two copies of the same expression compare equal
//! and any later pass can use the id as a dense, stable side-table key. The
//! accompanying tests spell this contract out: an id survives a struct copy, an
//! address does not.
//!
//! Two invariants make the ids usable as keys:
//!   1. Ids are handed out from `1` upward and `0` is never assigned, so the
//!      sentinel `.unassigned` (enum value 0) is unambiguous, a node that this
//!      pass never reached still reads as unassigned rather than colliding with
//!      a real id.
//!   2. The walk visits every expression reachable from a declaration exactly
//!      once, so ids are unique within a program. The traversal mirrors the AST
//!      shape node-for-node; if a new expression kind or a new expression-typed
//!      field is added to the AST, the matching arm here must be extended or
//!      those nodes will keep `.unassigned` and break whatever pass keys on them
//!      (the array-literal test guards one such gap that an earlier pass missed).
//!
//! The pass is allocation-free and infallible in practice, it only mutates the
//! `id` field of nodes the caller already owns; the `anyerror!void` signatures
//! exist so the recursive walkers compose uniformly, not because a step here can
//! fail.

const std = @import("std");
const ast = @import("../ast.zig");

/// Stateful walker that assigns a unique [`ast.ExprId`] to every expression it
/// reaches, in a single top-down pass over an [`ast.Program`].
///
/// It carries only a counter and a tally; it does not allocate and does not own
/// the AST, it mutates the `id` field of nodes borrowed through the `program`
/// passed to [`Assigner.run`]. Create one with [`Assigner.init`], call `run`,
/// then read [`Assigner.assigned`] if you want the count of nodes stamped.
pub const Assigner = struct {
    /// The next id to hand out. Starts at `1`, never `0`, so that id `0`
    /// (`ExprId.unassigned`) always means "this pass never visited the node".
    /// Incremented by [`Assigner.fresh`] on every stamp.
    next: u32 = 1,
    /// Running count of ids assigned so far. Purely diagnostic, the tests assert
    /// it to prove the walk reached exactly the expected number of nodes (that
    /// the traversal covered a nested/array structure with no gaps or repeats).
    assigned: usize = 0,

    /// Constructs a fresh [`Assigner`] with the counter primed at `1`.
    pub fn init() Assigner {
        return .{};
    }

    /// Allocates the next unused id and advances the counter and tally.
    ///
    /// Private because ids must only be minted while walking, one per node, so
    /// that uniqueness and the "never `0`" invariant hold. Every `walkExpr`
    /// entry calls this exactly once for the node it is visiting.
    fn fresh(self: *Assigner) ast.ExprId {
        const id: ast.ExprId = @enumFromInt(self.next);
        self.next += 1;
        self.assigned += 1;
        return id;
    }

    /// Entry point: stamp every expression in `program`.
    ///
    /// Iterates the top-level declarations by pointer (so the mutations land in
    /// the caller's AST, not a copy) and recurses through each. Idempotent only
    /// in the sense of "harmless to define"; running it twice on the same tree
    /// would re-stamp with a fresh set of ids, so call it exactly once per
    /// program before any pass that keys on the ids.
    pub fn run(self: *Assigner, program: ast.Program) anyerror!void {
        for (program.declarations) |*d| try self.walkDecl(d);
    }

    /// Descends into a single top-level declaration, visiting the expressions it
    /// contains.
    ///
    /// Only declaration kinds that actually hold expressions are recursed:
    /// functions and the methods hanging off struct/enum declarations reach
    /// their bodies, and a `const` reaches its initialiser. `union`, `import`,
    /// `export` and `trait` declarations carry no expressions to number, so they
    /// are deliberately no-ops rather than an oversight.
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

    /// Walks a function declaration by numbering the expressions in its body.
    ///
    /// The signature (parameter defaults, return type) is not an expression
    /// surface this pass touches; all numbering happens inside the block.
    fn walkFn(self: *Assigner, f: *ast.FunctionDecl) anyerror!void {
        try self.walkBlock(&f.body);
    }

    /// Walks every statement in a block, in source order.
    ///
    /// Order matters only in that it makes the id sequence deterministic;
    /// correctness just needs each statement reached once.
    pub fn walkBlock(self: *Assigner, b: *ast.Block) anyerror!void {
        for (b.statements) |*s| try self.walkStmt(s);
    }

    /// Recurses into a statement, numbering every expression it holds and
    /// descending into any nested statements or blocks.
    ///
    /// This mirrors the [`ast.Statement`] union arm-for-arm. Note the asymmetry
    /// in how children are reached: sub-expressions are addressed by pointer
    /// (`&is.condition`) so the stamp lands in place, while nested STATEMENTS
    /// that the AST already stores behind a pointer (`is.then_branch`,
    /// `ws.body`) are passed through as-is. `break` and `continue` carry no
    /// expression and are no-ops.
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
                    if (c.guard) |*g| try self.walkExpr(g);
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

    /// Stamp this expression, then recurse into its sub-expressions.
    ///
    /// This is the heart of the pass and the one place ids are assigned: the
    /// node gets its id via [`Assigner.fresh`] BEFORE its children, so a parent
    /// always has a lower id than its descendants (a stable, if incidental,
    /// property). The switch enumerates every [`ast.Expression`] kind and
    /// recurses into each expression-typed child; leaf kinds (`ident`, the
    /// scalar literals) recurse into nothing.
    ///
    /// Keeping this exhaustive is the pass's core obligation: a missed child, or
    /// a new expression kind added to the AST without a matching arm, leaves
    /// those nodes at `.unassigned` and silently breaks any later pass that keys
    /// on their id. The `array`/`array_repeat`/`object` literal arms exist
    /// precisely because a sibling pass (`alpha.zig`) once skipped them, see the
    /// "reaches array literal elements" test.
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
                .array_repeat => |*ar| try self.walkExpr(ar.value),
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

    /// Recurses through a JSX/NSX element tree, numbering the expressions
    /// embedded in it.
    ///
    /// Two expression surfaces exist in JSX and both are covered: attribute
    /// values that are `{expression}` (string-literal attributes carry no
    /// expression), and children, which may themselves be nested elements
    /// (recursed via `walkJsx`), `{expression}` interpolations, embedded
    /// statements, or plain text (no expression). Separate from [`walkExpr`]
    /// only because the JSX node types are not part of the `Expression` union.
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

/// Local alias for the standard test harness, used by the tests below.
const testing = std.testing;

/// Builds a minimal integer-literal [`ast.Expression`] for tests.
///
/// The `id` field defaults to `.unassigned`, so a freshly-built node is a clean
/// subject for asserting that a walk actually stamps it.
fn mkLit(n: i64) ast.Expression {
    return .{ .kind = .{ .literal = .{ .integer = n } } };
}

// Guards invariant 1: id `0` is never handed out, so `.unassigned` stays an
// unambiguous "not visited" sentinel after a real walk.
test "ids: never hands out 0, because 0 means unassigned" {

    var a = Assigner.init();
    var e = mkLit(1);
    try a.walkExpr(&e);
    try testing.expect(e.id != .unassigned);
    try testing.expect(@intFromEnum(e.id) != 0);
}

// Guards uniqueness on a small tree: a binary node and its two operands must
// all be assigned and all differ, and the tally must read exactly `3`.
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

// The reason this pass exists: after stamping, a by-value copy of an
// expression carries the SAME id (the id travels in the struct) while its
// address differs, so the id is a valid cross-copy key and `&expr` is not.
test "ids: THE POINT — an id survives a copy, an address does not" {

    var a = Assigner.init();
    var e = mkLit(7);
    try a.walkExpr(&e);

    const copy = e;
    try testing.expectEqual(e.id, copy.id);
    try testing.expect(&e != &copy);
}

// Regression guard for a real coverage gap: array-literal elements must be
// numbered here even though a sibling pass (`alpha.zig`) skips them, so the
// `array` arm in [`walkExpr`] is exercised end to end.
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

// End-to-end coverage check: builds a two-level binary tree and asserts every
// one of its five nodes is assigned, all ids are distinct (verified via a hash
// set), and the tally is exactly `5`, i.e. the recursion reaches deep nesting
// with no gaps or repeats.
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
