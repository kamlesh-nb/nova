// alpha.zig — F1: lexical block scope, by alpha-renaming.
//
// Fixes specs §10 #23 (repro/block_scope_aliasing.nova):
//
//     let x = 1; if (true) { let x = 2; } return x;   // returned 2, must be 1
//
//     if (true)  { let v = 42; out = out + `${v}`; }  // v is an int here
//     if (false) { let v = "never-runs"; }            // NEVER RUNS -> types v as string
//     -> the live `${v}` reads a string header at [42-4] -> SIGSEGV
//
// WHY THIS SHAPE. Codegen keeps ONE flat `locals` map per function
// (declarations.zig:851) and `collectLocalVarNames` hoists every `let` in the whole
// body — nested blocks included — into entry-block allocas, skipping any name
// already present (:896). `collectLocalVarTypes` (llvm_codegen.zig:2241-2272) does
// put(name, type) per `let`, last-writer-wins. Both are correct *if every binding
// has a unique name*. So rather than teach three codegen sites about scopes, this
// pass makes the premise true: it walks the AST with a real scope stack and renames
// any `let` that shadows a visible binding to a fresh name (`x$1`), rewriting its
// uses. The flat map then cannot alias, and last-writer-wins becomes harmless
// because each name has exactly one binding.
//
// This is classic alpha-renaming, and it is deliberately the SMALLEST change that
// makes the existing machinery correct: codegen is untouched.
//
// MINIMAL BY CONSTRUCTION: a binding is renamed ONLY when it actually shadows.
// Code that does not shadow is byte-identical, which is what makes this safe to
// land under the corpus.
//
// SCOPE (what this does NOT do): it does not give codegen a scope tree, so
// `locals` is still flat and still function-lifetime — a `let` in a block is still
// allocated for the whole function. That is a lifetime/ARC question (F5), not a
// correctness one. F1 §3.2's real `Scope{names, parent}` remains the end state;
// this removes the miscompilation now.
const std = @import("std");
const ast = @import("../ast.zig");

pub var renames: usize = 0;
pub var shadowed_names: usize = 0;

const Binding = struct {
    src: []const u8,
    renamed: []const u8,
};

pub const Renamer = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Every name bound ANYWHERE in this function so far. The scope stack governs
    /// which binding an identifier *refers to*; this governs whether a new binding
    /// needs a fresh name. They are different questions, and conflating them was
    /// the first cut's bug: two `let v` in DISJOINT blocks shadow nothing (the
    /// first is popped before the second binds), yet they are distinct bindings
    /// that codegen's flat, function-lifetime map would still collapse into one
    /// slot with one last-writer-wins type. `seen` is what makes them distinct.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    counter: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Renamer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renamer) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.seen.deinit(self.allocator);
        // `owned` strings are referenced by the AST for the rest of compilation
        // and are intentionally not freed here.
        self.owned.deinit(self.allocator);
    }

    fn push(self: *Renamer) !void {
        try self.scopes.append(self.allocator, .empty);
    }

    fn pop(self: *Renamer) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }

    /// Innermost-first lookup. This is the whole point: today there is no chain,
    /// so an inner `let x` simply collides with the outer one in a flat map.
    fn lookup(self: *Renamer, name: []const u8) ?[]const u8 {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |b| {
                if (std.mem.eql(u8, b.src, name)) return b.renamed;
            }
        }
        return null;
    }

    /// Bind `name` in the current scope. If it is already visible, this is a
    /// SHADOW: give it a fresh name so the flat map in codegen cannot alias it.
    fn bind(self: *Renamer, name: []const u8) ![]const u8 {
        // Rename if this name has been bound anywhere in the function already —
        // NOT merely if it is currently visible. Disjoint blocks do not shadow but
        // do collide in codegen's flat map (specs §10 #23's `disjoint()` case).
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

    /// Bind without renaming (params, catch vars, for-iterators at their own level).
    fn bindPlain(self: *Renamer, name: []const u8) !void {
        try self.seen.put(self.allocator, name, {});
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(
            self.allocator,
            .{ .src = name, .renamed = name },
        );
    }

    // ---- expressions ----------------------------------------------------
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
                // A closure body sees the enclosing scope (captures) with its own
                // params bound on top. Renaming stays consistent through capture
                // analysis because every use is rewritten the same way.
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

    // ---- statements -----------------------------------------------------
    pub fn walkBlock(self: *Renamer, b: *ast.Block) anyerror!void {
        try self.push();
        defer self.pop();
        for (b.statements) |*s| try self.walkStmt(s);
    }

    pub fn walkStmt(self: *Renamer, s: *ast.Statement) anyerror!void {
        switch (s.*) {
            .block => |*b| try self.walkBlock(b),
            .let_stmt => |*ls| {
                // Walk the initialiser FIRST: in `let x = x + 1` the right-hand `x`
                // is the OUTER binding. Binding before walking would capture itself.
                if (ls.init) |*i| try self.walkExpr(i);
                if (ls.names) |names| {
                    // destructuring: each name is its own binding
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
                // The initialiser / iterator bind in the for's OWN scope.
                try self.push();
                defer self.pop();
                if (f.initializer) |i| try self.walkStmt(i);
                if (f.iterator) |*it| {
                    // The iterable is evaluated in the outer scope; the binding is then introduced for the body.
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

    pub fn walkFunction(self: *Renamer, f: *ast.FunctionDecl) !void {
        try self.push();
        defer self.pop();
        for (f.params) |p| try self.bindPlain(p.name);
        for (f.body.statements) |*s| try self.walkStmt(s);
    }
};

/// Rename every shadowing binding in the program so that each `let` is a distinct
/// name. Idempotent in effect: non-shadowing code is left byte-identical.
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
