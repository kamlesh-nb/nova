//! Alpha-renaming (alpha-conversion) pass over the parsed AST.
//!
//! Kyte lets an inner `let` shadow an outer name that is still in scope
//! (`let x = 1; { let x = x + 1; ... }`). The source reads correctly under
//! lexical scoping, but the codegen backend lowers every local in a function
//! into ONE flat namespace keyed by identifier text. Two distinct variables
//! that happen to share a name would then collapse onto the same slot, so the
//! inner binding would clobber the outer one and any later reference to the
//! outer `x` would silently read the inner value. This pass removes that hazard
//! by giving each shadowing binding a fresh, globally-unique name before codegen
//! ever sees it.
//!
//! The transform is a classic alpha-conversion: walk the tree, and the SECOND
//! (and later) time a name is bound anywhere in a function, rewrite that binding
//! to `name$N` and rewrite every identifier reference that resolves to it. The
//! FIRST use of a name is left untouched, so unshadowed code is byte-identical
//! and only genuine collisions pay the rename. Uniqueness is tracked per
//! function in [`Renamer.seen`]: it is a set of every name ever emitted (source
//! and freshened), so a fresh name can never itself collide with a later
//! binding.
//!
//! Two binding disciplines coexist, and the distinction is the crux of the pass:
//!
//!   * [`Renamer.bind`] is used for `let` statements, which are the constructs
//!     that actually shadow within a shared flat namespace, so they are the ones
//!     that get freshened on collision.
//!   * [`Renamer.bindPlain`] is used for function parameters, closure
//!     parameters, `catch` error bindings, and `for`-loop bindings. These are
//!     introduced inside a scope this pass pushes explicitly, so they are
//!     recorded as identity mappings (no rename) but still marked as `seen` so a
//!     later `let` of the same name is freshened away from them.
//!
//! Scoping is a stack of scopes ([`Renamer.scopes`]); [`Renamer.lookup`] scans
//! it innermost-first so a reference binds to the nearest enclosing definition,
//! which is what decides whether an `.ident` is rewritten. The pass runs
//! per-function ([`run`] constructs a fresh [`Renamer`] for each top-level
//! function and each struct/enum method), because the flat-namespace collision
//! it guards against is confined to a single function body.

const std = @import("std");
const ast = @import("../ast.zig");

/// Process-wide count of bindings that were freshened to `name$N` because they
/// shadowed an already-seen name. Accumulates across every [`Renamer`] run in
/// the process; used as an observability/telemetry counter for how much
/// shadowing the compiled program actually contains.
pub var renames: usize = 0;
/// Process-wide counter reserved for shadowed-name accounting. Declared as a
/// public hook alongside [`renames`]; it is not mutated by this pass.
pub var shadowed_names: usize = 0;

/// One entry in a scope: a source name and the name it resolves to after
/// renaming.
///
/// For a plain (unshadowed) binding `renamed == src`. For a freshened binding
/// `renamed` is the allocated `name$N` string owned by [`Renamer.owned`].
/// [`Renamer.lookup`] matches on [`Binding.src`] and returns
/// [`Binding.renamed`].
const Binding = struct {
    /// The identifier exactly as it appeared in the source.
    src: []const u8,
    /// The name to emit for this binding: identical to [`Binding.src`] when no
    /// collision occurred, otherwise the freshened `name$N`.
    renamed: []const u8,
};

/// The per-function alpha-renaming state and the tree walker that applies it.
///
/// A `Renamer` is scoped to a single function body: [`run`] creates one, walks
/// the body, and discards it. All of its state (the scope stack, the seen-set,
/// the freshened-name arena, the counter) is therefore function-local, which is
/// exactly the granularity at which the flat-namespace collision this pass fixes
/// can occur. Freshened names are allocated into [`Renamer.owned`] and freed en
/// masse by [`Renamer.deinit`].
pub const Renamer = struct {
    /// Allocator backing every dynamic structure below and the freshened name
    /// strings in [`Renamer.owned`].
    allocator: std.mem.Allocator,
    /// The lexical scope stack: one inner list of [`Binding`]s per open block.
    /// [`Renamer.push`]/[`Renamer.pop`] bracket a scope; [`Renamer.lookup`]
    /// walks it innermost-to-outermost so the nearest binding wins.
    scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    /// Backing store for the freshened `name$N` strings. Held here (not in the
    /// scopes, which only borrow slices) so they outlive individual scope pops
    /// and are all freed together in [`Renamer.deinit`].
    owned: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Every name ever emitted in this function, both original and freshened.
    /// A name already present here means the next binding of it collides and
    /// must be freshened; inserting freshened names too guarantees a generated
    /// `name$N` can never itself collide with a later binding.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Monotonic suffix source for freshened names. Incremented per rename so
    /// each `name$N` within a function is distinct.
    counter: usize = 0,

    /// Creates an empty renamer bound to `allocator`. All collection fields
    /// start empty; the first binding lazily opens a scope.
    pub fn init(allocator: std.mem.Allocator) Renamer {
        return .{ .allocator = allocator };
    }

    /// Releases every structure the renamer owns: each remaining scope, the
    /// scope stack, the seen-set, and the freshened-name arena. Idempotent with
    /// respect to already-popped scopes since [`Renamer.pop`] frees as it goes.
    pub fn deinit(self: *Renamer) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.seen.deinit(self.allocator);

        self.owned.deinit(self.allocator);
    }

    /// Opens a new innermost lexical scope onto [`Renamer.scopes`]. Paired with
    /// [`Renamer.pop`]; the walkers call it on entering a block, closure, `for`,
    /// or `catch` body.
    fn push(self: *Renamer) !void {
        try self.scopes.append(self.allocator, .empty);
    }

    /// Closes the innermost scope and frees its binding list. Asserts a scope is
    /// open (the walkers always `push` before `pop`, typically via `defer`).
    fn pop(self: *Renamer) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }

    /// Resolves `name` to its current binding by scanning scopes
    /// innermost-first, returning the [`Binding.renamed`] target, or `null` if
    /// the name is not bound (a free/global identifier this pass leaves alone).
    ///
    /// Within a single scope the search also runs last-to-first so that if a
    /// name were bound twice in the same block the most recent binding wins,
    /// matching sequential `let` semantics.
    fn lookup(self: *Renamer, name: []const u8) ?[]const u8 {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;

            const items = self.scopes.items[i].items;
            var j = items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, items[j].src, name)) return items[j].renamed;
            }
        }
        return null;
    }

    /// Binds a `let` name in the current scope, freshening it to `name$N` if it
    /// has been seen before, and returns the name to actually emit.
    ///
    /// This is the shadowing-sensitive path. On a collision it allocates a fresh
    /// `name$<counter>` (tracked in [`Renamer.owned`] for later freeing), bumps
    /// the global [`renames`] counter, and records BOTH the original and the
    /// fresh name in [`Renamer.seen`] so neither can be re-issued. It always
    /// records a [`Binding`] `{ src = name, renamed = out }` in the current
    /// scope so subsequent references via [`Renamer.lookup`] rewrite to `out`.
    /// Opens a scope first if none is open. The caller ([`Renamer.walkStmt`] on
    /// `let`) is responsible for writing the returned name back into the AST.
    fn bind(self: *Renamer, name: []const u8) ![]const u8 {

        const collides = self.seen.contains(name);
        var out = name;
        if (collides) {
            self.counter += 1;
            const fresh = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, self.counter });
            try self.owned.append(self.allocator, fresh);
            out = fresh;
            renames += 1;
        }
        try self.seen.put(self.allocator, name, {});
        if (out.ptr != name.ptr) try self.seen.put(self.allocator, out, {});
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(
            self.allocator,
            .{ .src = name, .renamed = out },
        );
        return out;
    }

    /// Binds `name` as an identity mapping (no rename) in the current scope and
    /// marks it seen.
    ///
    /// Used for bindings that live in a scope this pass pushes explicitly, so
    /// they cannot participate in the flat-namespace collision that
    /// [`Renamer.bind`] guards against: function/closure parameters, `for`-loop
    /// item/destructure names, and `catch` error names. Recording them in
    /// [`Renamer.seen`] still matters, because a later `let` of the same name
    /// must be freshened away from the parameter or loop variable.
    fn bindPlain(self: *Renamer, name: []const u8) !void {
        try self.seen.put(self.allocator, name, {});
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(
            self.allocator,
            .{ .src = name, .renamed = name },
        );
    }

    /// Recursively rewrites identifier references inside an expression.
    ///
    /// The only node that mutates is `.ident`: if [`Renamer.lookup`] maps it to
    /// a different name, the ident's payload is replaced with the renamed
    /// target. Every other arm just recurses into children. The scope-opening
    /// arms are the subtle ones: `.catch_expr` pushes a scope and binds the
    /// error name so it is visible only in the handler, and `.closure` pushes a
    /// scope and [`Renamer.bindPlain`]s its parameters before walking the body
    /// (the body may be an expression or a block). `.jsx_element` and `.literal`
    /// have no identifier subtree to rewrite.
    pub fn walkExpr(self: *Renamer, e: *ast.Expression) anyerror!void {
        switch (e.kind) {
            .range => |r| {
                try self.walkExpr(r.start);
                try self.walkExpr(r.end);
            },
            .ident => |name| {
                if (self.lookup(name)) |r| {
                    if (!std.mem.eql(u8, r, name)) e.kind = .{ .ident = r };
                }
            },
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
                try self.push();
                defer self.pop();
                if (ce.err_name) |n| try self.bindPlain(n);
                try self.walkExpr(ce.handler);
            },
            .block_expr => |*b| try self.walkBlock(b),
            .template_expr => |*t| {
                for (t.parts) |*p| try self.walkExpr(p);
            },
            .await_expr, .go_expr => |*a| try self.walkExpr(a.operand),
            .closure => |*cl| {

                try self.push();
                defer self.pop();
                for (cl.params) |p| try self.bindPlain(p);
                switch (cl.body) {
                    .expr => |ex| try self.walkExpr(ex),
                    .block => |*b| try self.walkBlock(@constCast(b)),
                }
            },
            .jsx_element, .literal => {},
        }
    }

    /// Walks a block in its own lexical scope: pushes a scope, walks each
    /// statement so any `let` binds into that scope, and pops on exit. The
    /// push/pop bracket is what makes a `let` in the block invisible once the
    /// block ends.
    pub fn walkBlock(self: *Renamer, b: *ast.Block) anyerror!void {
        try self.push();
        defer self.pop();
        for (b.statements) |*s| try self.walkStmt(s);
    }

    /// Recursively rewrites a statement, introducing bindings for its declared
    /// names.
    ///
    /// The load-bearing arm is `.let_stmt`: it walks the initialiser FIRST (so
    /// `let x = x` reads the OUTER `x` before the new one is bound), then binds
    /// each declared name via [`Renamer.bind`] and, on a rename, writes the
    /// fresh name back into the AST (`names[idx]` for a destructuring `let`, or
    /// `ls.name` for a single one). `.for_stmt` opens its own scope so the loop
    /// variable and initializer are local to the loop. Control-flow arms recurse
    /// into their sub-statements and conditions; `.break_stmt`/`.continue_stmt`
    /// bind nothing.
    pub fn walkStmt(self: *Renamer, s: *ast.Statement) anyerror!void {
        switch (s.*) {
            .block => |*b| try self.walkBlock(b),
            .let_stmt => |*ls| {

                if (ls.init) |*i| try self.walkExpr(i);
                if (ls.names) |names| {

                    for (names, 0..) |n, idx| {
                        const r = try self.bind(n);
                        if (!std.mem.eql(u8, r, n)) names[idx] = r;
                    }
                } else {
                    ls.name = try self.bind(ls.name);
                }
            },
            .expr_stmt => |*es| try self.walkExpr(&es.expr),
            .if_stmt => |*i| {
                try self.walkExpr(&i.condition);
                try self.walkStmt(i.then_branch);
                if (i.else_branch) |e| try self.walkStmt(e);
            },
            .while_stmt => |*w| {
                try self.walkExpr(&w.condition);
                try self.walkStmt(w.body);
            },
            .for_stmt => |*f| {

                try self.push();
                defer self.pop();
                if (f.initializer) |i| try self.walkStmt(i);
                if (f.iterator) |*it| {

                    try self.walkExpr(it.iterable);
                    switch (it.binding) {
                        .item => |n| try self.bindPlain(n),
                        .destructure => |d| {
                            try self.bindPlain(d.key);
                            try self.bindPlain(d.value);
                        },
                    }
                }
                if (f.condition) |*c| try self.walkExpr(c);
                if (f.increment) |*inc| try self.walkExpr(inc);
                try self.walkStmt(f.body);
            },
            .switch_stmt => |*sw| {
                try self.walkExpr(&sw.discriminant);
                for (sw.cases) |*c| {
                    for (c.values) |*v| try self.walkExpr(v);
                    if (c.guard) |*g| try self.walkExpr(g);
                    try self.walkStmt(c.body);
                }
                if (sw.default_case) |d| try self.walkStmt(d);
            },
            .return_stmt => |*r| {
                if (r.value) |*v| try self.walkExpr(v);
            },
            .defer_stmt => |*d| try self.walkExpr(&d.expr),
            .break_stmt, .continue_stmt => {},
        }
    }

    /// Entry point for one function body: opens the outermost scope, binds the
    /// parameters as identity mappings via [`Renamer.bindPlain`], then walks the
    /// body statements. Note it iterates `f.body.statements` directly rather
    /// than calling [`Renamer.walkBlock`], so parameters and top-level locals
    /// share this single function scope (a top-level `let` therefore collides
    /// with a same-named parameter, which is the intended behaviour).
    pub fn walkFunction(self: *Renamer, f: *ast.FunctionDecl) !void {
        try self.push();
        defer self.pop();
        for (f.params) |p| try self.bindPlain(p.name);
        for (f.body.statements) |*s| try self.walkStmt(s);
    }
};

/// Runs alpha-renaming over an entire program, mutating the AST in place.
///
/// Iterates every top-level declaration and applies a FRESH [`Renamer`] to each
/// function body and to each struct/enum method body. Using a separate renamer
/// per function is deliberate: the flat-namespace collision this pass fixes is
/// confined to one function, so per-function state keeps the seen-set and
/// counter from leaking across unrelated bodies. Non-callable declarations are
/// ignored.
pub fn run(allocator: std.mem.Allocator, program: ast.Program) !void {
    for (program.declarations) |*decl| {
        switch (decl.*) {
            .fn_decl => |*f| {
                var r = Renamer.init(allocator);
                defer r.deinit();
                try r.walkFunction(f);
            },
            .struct_decl => |*s| {
                for (s.methods) |*m| {
                    var r = Renamer.init(allocator);
                    defer r.deinit();
                    try r.walkFunction(&m.decl);
                }
            },
            .enum_decl => |*e| {
                for (e.methods) |*m| {
                    var r = Renamer.init(allocator);
                    defer r.deinit();
                    try r.walkFunction(&m.decl);
                }
            },
            else => {},
        }
    }
}
