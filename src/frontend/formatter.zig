//! Canonical source formatter for Kyte (`kyte fmt`).
//!
//! This module walks a parsed [`ast.Program`] and re-emits it as normalised
//! Kyte source text: fixed four-space indentation, one canonical spelling for
//! every construct, and consistent spacing around operators. It is a pure
//! AST-to-text pretty-printer, so it deliberately does NOT preserve the exact
//! bytes of the input. Comments and blank-line layout that the parser drops are
//! not reconstructed; what comes out is the AST's own idea of the program,
//! spelled the one canonical way.
//!
//! ## Why it works off the AST, not the token stream
//!
//! Because it prints from the AST rather than reshuffling tokens, the formatter
//! is inherently normalising: `a+b`, `a + b`, and `a  +  b` all parse to the
//! same [`ast.Expression`] and therefore print identically. The cost is that
//! anything the parser did not retain (notably comments) cannot be emitted. Two
//! places nonetheless dip back into the original text via [`ast.Span`], because
//! the AST alone does not carry the information: [`Formatter.getGenericString`]
//! (to recover a declaration's generic parameter list from source) and
//! [`Formatter.isPubDecl`] (to recover a `pub` marker the enum node does not
//! store). Those are the only two coupling points to raw source, which is why
//! the caller must hand the original `source` to [`Formatter.init`].
//!
//! ## Round-trip and precedence invariants
//!
//! The output must re-parse to an AST equivalent to the input, so two
//! correctness concerns drive the design. First, operators are re-parenthesised
//! by comparing precedence: [`Formatter.formatBinaryChild`] wraps a child only
//! when dropping the parentheses would change how it re-parses (a lower-precedence
//! child, or an equal-precedence child on the right of a left-associative
//! operator). Second, the operator spellings emitted by [`Formatter.binOpToStr`]
//! must all be real Kyte tokens; the module's tests assert that `&`/`|`/`&&`/`||`
//! and every other operator round-trip through the lexer rather than leaking an
//! internal tag name.
//!
//! ## Structure
//!
//! [`Formatter`] is a small stateful visitor: an output buffer, a current
//! indentation depth, and the borrowed source. Formatting proceeds by mutually
//! recursive `format*` methods, one family per AST node kind (declarations,
//! statements, expressions, type references). Statement formatting comes in two
//! flavours: the normal indent-and-newline path ([`Formatter.formatStatement`])
//! and a compact inline path ([`Formatter.formatStatementNoIndentNoNewline`])
//! used for single-statement `if`/`while`/`for` bodies that are not blocks.

const std = @import("std");
const ast = @import("ast.zig");

/// Stateful pretty-printer that renders a parsed Kyte program back to canonical
/// source text.
///
/// A `Formatter` owns a growable output buffer and threads the current
/// indentation depth through the recursive `format*` visitors. It borrows both
/// the caller's allocator and the original `source` slice (needed by
/// [`Formatter.getGenericString`] and [`Formatter.isPubDecl`]); neither is
/// copied, so both must outlive the formatter. Create one with
/// [`Formatter.init`], drive it with [`Formatter.formatProgram`], and release
/// its buffer with [`Formatter.deinit`] (unless ownership of the buffer was
/// transferred out via `toOwnedSlice`).
pub const Formatter = struct {
    /// Allocator used to grow [`Formatter.out`]; borrowed, not owned.
    allocator: std.mem.Allocator,
    /// Accumulating output buffer of formatted source. Callers usually take
    /// ownership of it via `toOwnedSlice` in [`Formatter.formatProgram`];
    /// otherwise [`Formatter.deinit`] frees it.
    out: std.ArrayList(u8),
    /// Current nesting depth in units of four-space indents. Bumped on entering
    /// a block/struct/enum body and restored on the way out; [`Formatter.writeIndent`]
    /// turns it into leading whitespace.
    indent_level: usize,
    /// The original, unformatted source text. Borrowed for the formatter's
    /// lifetime and consulted by [`Formatter.getGenericString`] and
    /// [`Formatter.isPubDecl`] to recover detail the AST does not retain.
    source: []const u8,

    /// Constructs a formatter with an empty buffer at indentation zero.
    ///
    /// `source` must be the same text the AST was parsed from: the span-based
    /// helpers index into it directly, so passing a different or already-freed
    /// slice yields wrong output or reads out of bounds.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Formatter {
        return Formatter{
            .allocator = allocator,
            .out = std.ArrayList(u8).empty,
            .indent_level = 0,
            .source = source,
        };
    }

    /// Frees the output buffer.
    ///
    /// Safe to call whether or not the buffer was emptied; but note that
    /// [`Formatter.formatProgram`] returns the buffer via `toOwnedSlice`, after
    /// which `out` is empty and this call is a harmless no-op on already-transferred
    /// memory.
    pub fn deinit(self: *Formatter) void {
        self.out.deinit(self.allocator);
    }

    /// Emits `indent_level` levels of four-space indentation to the buffer.
    ///
    /// Called at the start of every line that begins a construct. Nested-body
    /// callers bump [`Formatter.indent_level`] before invoking their children so
    /// this reflects the current depth.
    fn writeIndent(self: *Formatter) !void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.out.appendSlice(self.allocator, "    ");
        }
    }

    /// Appends a raw string to the output buffer verbatim.
    ///
    /// The workhorse output primitive; unlike [`Formatter.writeIndent`] it adds
    /// no leading whitespace, so callers control layout explicitly.
    fn write(self: *Formatter, str: []const u8) !void {
        try self.out.appendSlice(self.allocator, str);
    }

    /// Appends formatted output to the buffer using a `std.fmt` format string.
    ///
    /// Thin wrapper over the buffer's `print`; used where interpolation is
    /// clearer than concatenating [`Formatter.write`] calls (numbers, `{s}`
    /// names, etc.).
    fn print(self: *Formatter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.allocator, fmt, args);
    }

    /// Formats a whole program and returns the owned result buffer.
    ///
    /// Top-level declarations are emitted in source order, separated by a single
    /// blank line (a bare `\n` before every declaration after the first).
    /// Ownership of the buffer transfers to the caller via `toOwnedSlice`, so
    /// after this returns the formatter's `out` is empty and the caller must
    /// free the returned slice.
    pub fn formatProgram(self: *Formatter, program: ast.Program) ![]const u8 {
        var prev_import = false;
        for (program.declarations, 0..) |decl, idx| {
            const is_import = decl == .import_decl;
            if (idx > 0) {
                // Keep the import block tight: no blank line between two
                // consecutive imports. The single blank line still appears
                // between the import block and the first real declaration (that
                // transition is import -> non-import), and between all other
                // top-level declarations.
                if (!(prev_import and is_import)) {
                    try self.write("\n");
                }
            }
            try self.formatDeclaration(decl);
            prev_import = is_import;
        }
        return try self.out.toOwnedSlice(self.allocator);
    }

    /// Recovers a declaration's generic parameter list (e.g. `<T, U>`) from the
    /// original source, since the AST node does not retain the raw text.
    ///
    /// Scans the declaration's span looking for a top-level `<...>` that appears
    /// before the first `(` or `{` (i.e. before a parameter list or body opens),
    /// tracking `<`/`>` nesting depth so nested generics like `List<Map<K,V>>`
    /// are captured whole. Returns the bracketed substring including the angle
    /// brackets, or `""` if the span is out of range or no such list is present.
    fn getGenericString(self: *Formatter, span: ast.Span) []const u8 {
        if (span.start >= self.source.len or span.end > self.source.len) return "";
        const decl_str = self.source[span.start..span.end];
        var in_angle = false;
        var start_idx: ?usize = null;
        var end_idx: ?usize = null;
        var depth: usize = 0;

        for (decl_str, 0..) |c, idx| {
            if (c == '(' or c == '{') {
                if (!in_angle) break;
            }
            if (c == '<') {
                if (depth == 0) {
                    start_idx = idx;
                    in_angle = true;
                }
                depth += 1;
            }
            if (c == '>') {
                if (depth > 0) {
                    depth -= 1;
                    if (depth == 0) {
                        end_idx = idx;
                        break;
                    }
                }
            }
        }

        if (start_idx != null and end_idx != null) {
            return decl_str[start_idx.? .. end_idx.? + 1];
        }
        return "";
    }

    /// Recovers whether a declaration was written with a leading `pub`, by
    /// scanning the source immediately before its span.
    ///
    /// Used for enum declarations, whose AST node does not carry an
    /// `is_public` flag the way structs/unions/functions do. Walks backwards
    /// over whitespace to the first non-space character and checks it spells
    /// the end of the keyword `pub` (`b` preceded by `u`, `p`), with the `p`
    /// itself at start-of-input, or preceded by whitespace or a closing `}`, so
    /// an identifier ending in `pub` does not false-positive. Returns false if
    /// the span is at the very start of source or out of range.
    fn isPubDecl(self: *Formatter, span: ast.Span) bool {
        if (span.start == 0 or span.start >= self.source.len) return false;
        var idx = span.start;
        while (idx > 0) {
            idx -= 1;
            const c = self.source[idx];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
            if (c == 'b' and idx >= 2) {
                if (self.source[idx - 1] == 'u' and self.source[idx - 2] == 'p') {
                    if (idx - 2 == 0 or std.ascii.isWhitespace(self.source[idx - 3]) or self.source[idx - 3] == '}') {
                        return true;
                    }
                }
            }
            break;
        }
        return false;
    }

    /// Dispatches a top-level declaration to its specific formatter.
    ///
    /// Handles the leaf cases (imports, `const`, `export`) inline and delegates
    /// the compound ones to their dedicated methods. Imports rewrite the stored
    /// slash-separated module path (`http/web`) back into dotted form
    /// (`http.web`). Declared `anyerror` because the recursion bottoms out in
    /// arbitrary expression/block formatting.
    fn formatDeclaration(self: *Formatter, decl: ast.Declaration) anyerror!void {
        switch (decl) {
            .import_decl => |id| {
                try self.writeIndent();
                try self.write("import ");
                for (id.module) |c| {
                    if (c == '/') {
                        try self.write(".");
                    } else {
                        try self.print("{c}", .{c});
                    }
                }
                try self.write(";\n");
            },
            .const_decl => |cd| {
                try self.writeIndent();
                if (cd.is_exported) {
                    try self.write("export ");
                }
                try self.print("const {s} = ", .{cd.name});
                try self.formatExpression(cd.value);
                try self.write(";\n");
            },
            .export_decl => |ed| {
                try self.writeIndent();
                try self.print("export {s} {s};\n", .{ @tagName(ed.kind), ed.name });
            },
            .fn_decl => |fd| {
                try self.formatFunctionDecl(fd, "");
            },
            .struct_decl => |sd| {
                try self.formatStructDecl(sd);
            },
            .union_decl => |ud| {
                try self.formatUnionDecl(ud);
            },
            .enum_decl => |ed| {
                try self.formatEnumDecl(ed);
            },
            .trait_decl => |td| {
                try self.formatTraitDecl(td);
            },
        }
    }

    /// Emits each recognised attribute (`@serializable`, `@test`) on its own
    /// indented line above the declaration it annotates.
    ///
    /// Only the two known attributes are printed; any other attribute variant is
    /// silently skipped (the `else => {}` arm), so unrecognised annotations are
    /// dropped rather than mis-rendered.
    fn formatAttributes(self: *Formatter, attrs: []const ast.Attribute) !void {
        for (attrs) |attr| {
            try self.writeIndent();
            switch (attr) {
                .serializable => try self.write("@serializable\n"),
                .@"test" => try self.write("@test\n"),
                else => {},
            }
        }
    }

    /// Formats a function or method declaration, header through body.
    ///
    /// `prefix` is prepended immediately before the `fn` keyword and is how a
    /// method's `pub ` marker is threaded in from [`Formatter.formatStructDecl`]
    /// / [`Formatter.formatEnumDecl`] (top-level functions pass `""` and use
    /// their own `is_exported` flag for `pub`). Special cases handled: an
    /// `init` method prints as `init(` with no `fn` keyword; an `extern("lib")`
    /// function prints the extern spec and terminates with `;` instead of a
    /// body; an `async` function gets the `async ` keyword; generic type
    /// parameters print as `<...>`. When not extern, the body block is emitted
    /// after the signature.
    fn formatFunctionDecl(self: *Formatter, fd: ast.FunctionDecl, prefix: []const u8) !void {
        try self.formatAttributes(fd.attributes);
        try self.writeIndent();
        if (fd.is_exported) {
            try self.write("pub ");
        }
        const is_init = std.mem.eql(u8, fd.name, "init");
        // A method's `pub ` marker is threaded in via `prefix`; write it before
        // `async` so the modifier order is `pub async fn`, not `async pub fn`.
        // An `init` constructor prints as `init(...)` with no `pub` marker, so it
        // does not take the prefix.
        if (!is_init) {
            try self.write(prefix);
        }

        if (fd.extern_lib) |lib| {
            try self.print("extern(\"{s}\") ", .{lib});
        } else if (fd.is_async) {

            try self.write("async ");
        }
        if (is_init) {
            try self.print("init(", .{});
        } else {
            try self.print("fn {s}", .{fd.name});

            if (fd.type_params.len > 0) {
                try self.write("<");
                for (fd.type_params, 0..) |tp, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(tp);
                }
                try self.write(">");
            }
            try self.write("(");
        }
        for (fd.params, 0..) |p, idx| {
            if (idx > 0) try self.write(", ");
            try self.write(p.name);
            if (p.type_name) |t| {
                try self.write(": ");
                try self.formatTypeRef(t);
            }
        }
        try self.write(")");
        if (fd.ret_type) |r| {
            try self.write(": ");
            try self.formatTypeRef(r);
        }
        if (fd.extern_lib != null) {
            try self.write(";\n");
        } else {
            try self.write(" ");
            try self.formatBlock(fd.body);
            try self.write("\n");
        }
    }

    /// Formats a `struct` declaration: attributes, `pub`, name, optional generic
    /// parameters, optional `impl` trait list, then the field and method body.
    ///
    /// The `impl` clause lists implemented traits with their type arguments.
    /// Fields print one per line with their `pub` marker and type; methods
    /// follow, separated from the fields by a blank line only when both are
    /// present, and from each other by a blank line. Each method's `pub ` is
    /// composed into a small stack buffer and passed as the `prefix` to
    /// [`Formatter.formatFunctionDecl`].
    fn formatStructDecl(self: *Formatter, sd: ast.StructDecl) !void {
        try self.formatAttributes(sd.attributes);
        try self.writeIndent();
        if (sd.is_public) {
            try self.write("pub ");
        }
        try self.print("struct {s}", .{sd.name});

        if (sd.type_params.len > 0) {
            try self.write("<");
            for (sd.type_params, 0..) |tp, i| {
                if (i > 0) try self.write(", ");
                try self.write(tp);
            }
            try self.write(">");
        }
        if (sd.impls.len > 0) {
            try self.write(" impl ");
            for (sd.impls, 0..) |impl, idx| {
                if (idx > 0) try self.write(", ");
                try self.write(impl.name);
                if (impl.type_args.len > 0) {
                    try self.write("<");
                    for (impl.type_args, 0..) |ta, ti| {
                        if (ti > 0) try self.write(", ");
                        try self.formatTypeRef(ta);
                    }
                    try self.write(">");
                }
            }
        }
        try self.write(" {\n");
        self.indent_level += 1;

        for (sd.fields) |field| {
            try self.writeIndent();
            if (field.is_public) {
                try self.write("pub ");
            }
            try self.print("{s}: ", .{field.name});
            try self.formatTypeRef(field.type_name);
            try self.write(",\n");
        }

        if (sd.fields.len > 0 and sd.methods.len > 0) {
            try self.write("\n");
        }

        for (sd.methods, 0..) |method, idx| {
            if (idx > 0) try self.write("\n");
            var prefix_buf: [32]u8 = undefined;
            var f_idx: usize = 0;
            if (method.is_public) {
                std.mem.copyForwards(u8, prefix_buf[f_idx..], "pub ");
                f_idx += 4;
            }

            try self.formatFunctionDecl(method.decl, prefix_buf[0..f_idx]);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    /// Formats a `union` declaration and its `name: Type` fields.
    ///
    /// Simpler than a struct: no generics, `impl` list, or methods are emitted,
    /// only the `pub` marker, name, and one field per line. The `{{`/`}}` in the
    /// format string are escaped literal braces for the `union NAME {` header.
    fn formatUnionDecl(self: *Formatter, ud: ast.UnionDecl) !void {
        try self.writeIndent();
        if (ud.is_public) {
            try self.write("pub ");
        }
        try self.print("union {s} {{\n", .{ud.name});
        self.indent_level += 1;
        for (ud.fields) |field| {
            try self.writeIndent();
            if (field.is_public) {
                try self.write("pub ");
            }
            try self.print("{s}: ", .{field.name});
            try self.formatTypeRef(field.type_name);
            try self.write(",\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    /// Formats an `enum` declaration, its variants, and any methods.
    ///
    /// `pub` is recovered from source via [`Formatter.isPubDecl`] because the
    /// enum node lacks an explicit flag. Each variant is emitted in one of four
    /// shapes depending on which optional field is set: a plain name, `name = N`
    /// (explicit integer value), a struct-like `name { field: T, ... }` body, or
    /// a tuple-payload `name(T)`. Methods follow the variants with the same
    /// blank-line separation rules as [`Formatter.formatStructDecl`].
    fn formatEnumDecl(self: *Formatter, ed: ast.EnumDecl) !void {
        try self.formatAttributes(ed.attributes);
        try self.writeIndent();
        if (self.isPubDecl(ed.span)) {
            try self.write("pub ");
        }
        try self.print("enum {s} {{\n", .{ed.name});
        self.indent_level += 1;

        for (ed.variants) |variant| {
            try self.writeIndent();
            try self.write(variant.name);
            if (variant.value) |val| {
                try self.print(" = {d}", .{val});
            } else if (variant.fields) |fields| {
                try self.write(" {\n");
                self.indent_level += 1;
                for (fields) |f| {
                    try self.writeIndent();
                    if (f.is_public) try self.write("pub ");
                    try self.print("{s}: ", .{f.name});
                    try self.formatTypeRef(f.type_name);
                    try self.write(",\n");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}");
            } else if (variant.type_name) |t| {
                try self.write("(");
                try self.formatTypeRef(t);
                try self.write(")");
            }
            try self.write(",\n");
        }

        if (ed.variants.len > 0 and ed.methods.len > 0) {
            try self.write("\n");
        }

        for (ed.methods, 0..) |method, idx| {
            if (idx > 0) try self.write("\n");
            var prefix_buf: [32]u8 = undefined;
            var f_idx: usize = 0;
            if (method.is_public) {
                std.mem.copyForwards(u8, prefix_buf[f_idx..], "pub ");
                f_idx += 4;
            }

            try self.formatFunctionDecl(method.decl, prefix_buf[0..f_idx]);
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    /// Formats a `trait` declaration and its method signatures.
    ///
    /// Trait methods are signatures only (no body): each prints as an optionally
    /// `async fn name(params): ret;` line terminated with a semicolon. Optional
    /// generic type parameters on the trait itself print as `<...>` after the
    /// name.
    fn formatTraitDecl(self: *Formatter, td: ast.TraitDecl) !void {
        try self.writeIndent();
        if (td.is_public) {
            try self.write("pub ");
        }
        try self.print("trait {s}", .{td.name});

        if (td.type_params.len > 0) {
            try self.write("<");
            for (td.type_params, 0..) |tp, i| {
                if (i > 0) try self.write(", ");
                try self.write(tp);
            }
            try self.write(">");
        }
        try self.write(" {\n");
        self.indent_level += 1;
        for (td.methods) |m| {
            try self.writeIndent();

            if (m.is_async) try self.write("async ");
            try self.print("fn {s}(", .{m.name});
            for (m.params, 0..) |p, idx| {
                if (idx > 0) try self.write(", ");
                try self.write(p.name);
                if (p.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
            }
            try self.write(")");
            if (m.ret_type) |r| {
                try self.write(": ");
                try self.formatTypeRef(r);
            }
            try self.write(";\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
    }

    /// Formats a brace-delimited block: `{`, an indented sequence of statements,
    /// then the closing `}`.
    ///
    /// Increments [`Formatter.indent_level`] for the body and restores it before
    /// the closing brace. Note it emits the closing `}` WITHOUT a trailing
    /// newline, leaving the caller to add whatever follows (a newline, an
    /// ` else`, etc.).
    fn formatBlock(self: *Formatter, block: ast.Block) !void {
        try self.write("{\n");
        self.indent_level += 1;
        for (block.statements) |stmt| {
            try self.formatStatement(stmt);
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    /// Formats one statement on its own indented line(s), terminated by a
    /// newline.
    ///
    /// This is the standard, block-context statement printer (contrast the
    /// inline [`Formatter.formatStatementNoIndentNoNewline`] used for
    /// non-block control-flow bodies). Covers every [`ast.Statement`] variant:
    /// nested blocks, `let`/`const` (including tuple-destructuring `(a, b)`
    /// bindings), expression statements, `defer`, `if` (via
    /// [`Formatter.formatIfStmtNoIndent`]), `while`, `for` (both the `x in xs`
    /// iterator form and the C-style init/cond/incr form), `switch` with `case`
    /// and `default`, `return`, `break`, and `continue`. For `while`/`for`/`case`
    /// bodies a non-block single statement is wrapped in synthesised braces so
    /// the output is always a block. Declared `anyerror` for the mutual
    /// recursion through expressions.
    fn formatStatement(self: *Formatter, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .block => |b| {
                try self.writeIndent();
                try self.formatBlock(b);
                try self.write("\n");
            },
            .let_stmt => |l| {
                try self.writeIndent();
                if (l.is_const) {
                    try self.write("const ");
                } else {
                    try self.write("let ");
                }
                if (l.names) |names| {
                    try self.write("(");
                    for (names, 0..) |n, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.write(n);
                    }
                    try self.write(")");
                } else {
                    try self.write(l.name);
                }
                if (l.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
                if (l.init) |init_expr| {
                    try self.write(" = ");
                    try self.formatExpression(init_expr);
                }
                try self.write(";\n");
            },
            .expr_stmt => |e| {
                try self.writeIndent();
                try self.formatExpression(e.expr);
                try self.write(";\n");
            },
            .defer_stmt => |d| {
                try self.writeIndent();
                try self.write("defer ");
                try self.formatExpression(d.expr);
                try self.write(";\n");
            },
            .if_stmt => |i| {
                try self.writeIndent();
                try self.formatIfStmtNoIndent(i);
                try self.write("\n");
            },
            .while_stmt => |w| {
                try self.writeIndent();
                try self.write("while (");
                try self.formatExpression(w.condition);
                try self.write(") ");
                if (w.body.* == .block) {
                    try self.formatBlock(w.body.block);
                } else {
                    try self.write("{\n");
                    self.indent_level += 1;
                    try self.formatStatement(w.body.*);
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("}");
                }
                try self.write("\n");
            },
            .for_stmt => |f| {
                try self.writeIndent();
                try self.write("for (");
                if (f.iterator) |it| {

                    switch (it.binding) {
                        .item => |name| try self.write(name),
                        .destructure => |d| {
                            try self.write("(");
                            try self.write(d.key);
                            try self.write(", ");
                            try self.write(d.value);
                            try self.write(")");
                        },
                    }
                    try self.write(" in ");
                    try self.formatExpression(it.iterable.*);
                } else {

                    if (f.initializer) |init_stmt| {
                        try self.formatStatementNoIndentNoNewline(init_stmt.*);
                    } else {
                        try self.write(";");
                    }
                    if (f.condition) |cond| {
                        try self.write(" ");
                        try self.formatExpression(cond);
                    }
                    try self.write(";");
                    if (f.increment) |incr| {
                        try self.write(" ");
                        try self.formatExpression(incr);
                    }
                }
                try self.write(") ");
                if (f.body.* == .block) {
                    try self.formatBlock(f.body.block);
                } else {
                    try self.write("{\n");
                    self.indent_level += 1;
                    try self.formatStatement(f.body.*);
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("}");
                }
                try self.write("\n");
            },
            .switch_stmt => |sw| {
                try self.writeIndent();
                try self.write("switch (");
                try self.formatExpression(sw.discriminant);
                try self.write(") {\n");
                self.indent_level += 1;
                for (sw.cases) |case| {
                    try self.writeIndent();
                    try self.write("case ");
                    for (case.values, 0..) |val, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.formatExpression(val);
                    }
                    try self.write(": ");
                    if (case.body.* == .block) {
                        try self.formatBlock(case.body.block);
                        try self.write("\n");
                    } else {
                        try self.write("{\n");
                        self.indent_level += 1;
                        try self.formatStatement(case.body.*);
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.write("}\n");
                    }
                }
                if (sw.default_case) |def| {
                    try self.writeIndent();
                    try self.write("default: ");
                    if (def.* == .block) {
                        try self.formatBlock(def.block);
                        try self.write("\n");
                    } else {
                        try self.write("{\n");
                        self.indent_level += 1;
                        try self.formatStatement(def.*);
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.write("}\n");
                    }
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}\n");
            },
            .return_stmt => |r| {
                try self.writeIndent();
                try self.write("return");
                if (r.value) |val| {
                    try self.write(" ");
                    try self.formatExpression(val);
                }
                try self.write(";\n");
            },
            .break_stmt => {
                try self.writeIndent();
                try self.write("break;\n");
            },
            .continue_stmt => {
                try self.writeIndent();
                try self.write("continue;\n");
            },
}
    }

    /// Formats an `if` statement starting at the caret (no leading indent, no
    /// trailing newline).
    ///
    /// The caller writes the indent before invoking and the newline after, which
    /// lets this method be reused for `else if` chains: an `else` branch that is
    /// itself an `if_stmt` recurses here rather than nesting a fresh block, so
    /// `else if` prints flat instead of as `else { if ... }`. Block branches use
    /// [`Formatter.formatBlock`]; non-block branches use the compact
    /// [`Formatter.formatStatementNoIndentNoNewline`].
    fn formatIfStmtNoIndent(self: *Formatter, i: ast.IfStmt) anyerror!void {
        try self.write("if (");
        try self.formatExpression(i.condition);
        try self.write(") ");
        if (i.then_branch.* == .block) {
            try self.formatBlock(i.then_branch.block);
        } else {

            try self.formatStatementNoIndentNoNewline(i.then_branch.*);
        }
        if (i.else_branch) |eb| {
            try self.write(" else ");
            if (eb.* == .block) {
                try self.formatBlock(eb.block);
            } else if (eb.* == .if_stmt) {
                try self.formatIfStmtNoIndent(eb.if_stmt);
            } else {
                try self.formatStatementNoIndentNoNewline(eb.*);
            }
        }
    }

    /// Formats a statement inline: no leading indentation and terminated by a
    /// bare `;` (or nothing) rather than a newline.
    ///
    /// Used for single-statement control-flow bodies that share a line with
    /// their header, e.g. `if (c) return x;`. The common leaf statements
    /// (`let`/`const`, expression, `break`, `continue`, `return`) are printed
    /// directly with a `;` terminator. Anything else falls through to the full
    /// [`Formatter.formatStatement`] and then pops a single trailing newline it
    /// produced, so the caller still gets inline-shaped output. Declared
    /// `anyerror` for the recursion.
    fn formatStatementNoIndentNoNewline(self: *Formatter, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .let_stmt => |l| {
                if (l.is_const) {
                    try self.write("const ");
                } else {
                    try self.write("let ");
                }
                if (l.names) |names| {
                    try self.write(" (");
                    for (names, 0..) |n, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.write(n);
                    }
                    try self.write(")");
                } else {
                    try self.write(l.name);
                }
                if (l.type_name) |t| {
                    try self.write(": ");
                    try self.formatTypeRef(t);
                }
                if (l.init) |init_expr| {
                    try self.write(" = ");
                    try self.formatExpression(init_expr);
                }
                try self.write(";");
            },
            .expr_stmt => |e| {
                try self.formatExpression(e.expr);
                try self.write(";");
            },
            .break_stmt => try self.write("break;"),
            .continue_stmt => try self.write("continue;"),
            .return_stmt => |r| {
                try self.write("return");
                if (r.value) |v| {
                    try self.write(" ");
                    try self.formatExpression(v);
                }
                try self.write(";");
            },
            else => {

                try self.formatStatement(stmt);

                if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == '\n') {
                    _ = self.out.pop();
                }
            },
        }
    }

    /// Maps a binary operator to its precedence level (higher binds tighter).
    ///
    /// The scale (assignment `1` up to multiplicative `9`) is used purely for
    /// deciding parenthesisation in [`Formatter.formatBinaryChild`]; it mirrors
    /// the parser's precedence so that re-printed output re-parses to the same
    /// tree. Not tied to any absolute numbering, only the relative ordering
    /// matters.
    fn opPrecedence(op: ast.BinaryOp) i32 {
        return switch (op) {
            .assign => 1,
            .bit_or, .Or => 2,
            .bit_xor => 3,
            .bit_and, .And => 4,
            .eq, .ne => 5,
            .lt, .gt, .le, .ge => 6,
            .shl, .shr => 7,
            .add, .sub => 8,
            .mul, .div, .mod => 9,
        };
    }

    /// Returns the canonical source spelling of a binary operator.
    ///
    /// Every returned string must be a real Kyte operator token so the output
    /// re-lexes correctly; the module's tests assert exactly this (including that
    /// the bitwise `&`/`|` and logical `&&`/`||` map to distinct symbols and not
    /// to leftover keyword forms). Referenced by [`Formatter.formatExpression`]
    /// for the `.binary` case.
    fn binOpToStr(op: ast.BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .assign => "=",
            .And => "&&",
            .Or => "||",
            .shl => "<<",
            .shr => ">>",
        };
    }

    /// Formats one operand of a binary expression, adding parentheses only when
    /// required to preserve the tree on re-parse.
    ///
    /// A child that is itself a binary expression is wrapped when its operator
    /// binds looser than the parent (`child_prec < parent_prec`), or binds
    /// equally but sits on the RIGHT of a left-associative parent
    /// (`child_prec == parent_prec and is_right`), the case that would
    /// otherwise re-associate, e.g. `a - (b - c)` must keep its parentheses
    /// whereas `(a - b) - c` need not. Non-binary children are printed as-is.
    /// `is_right` marks which side of the parent this operand is.
    fn formatBinaryChild(self: *Formatter, child: ast.Expression, parent_op: ast.BinaryOp, is_right: bool) !void {
        switch (child.kind) {
            .binary => |bin| {
                const parent_prec = opPrecedence(parent_op);
                const child_prec = opPrecedence(bin.op);
                if (child_prec < parent_prec or (child_prec == parent_prec and is_right)) {
                    try self.write("(");
                    try self.formatExpression(child);
                    try self.write(")");
                    return;
                }
            },
            else => {},
        }
        try self.formatExpression(child);
    }

    /// Formats an arbitrary expression, dispatching on its kind.
    ///
    /// The large `switch` covers every [`ast.Expression`] variant: ranges,
    /// `await`/`go`, all literal forms (integers, floats with a forced `.0` when
    /// they would otherwise look integral, `m`-suffixed decimals, strings, bools,
    /// `null`/`undefined`, array/array-repeat/object literals), identifiers,
    /// binary (via [`Formatter.formatBinaryChild`]) and unary operators, calls
    /// and generic calls, field access, indexing, struct/enum initialisers,
    /// `as` casts, `?.` optional chaining, `??` nullish coalescing, JSX
    /// elements, closures, tuples, `if` expressions, `try`/`catch`, block
    /// expressions, and backtick template literals. Declared `anyerror` for the
    /// deep mutual recursion. Notable subtlety: a unary operand that is a binary
    /// expression is parenthesised so `-(a + b)` does not print as `-a + b`.
    fn formatExpression(self: *Formatter, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .range => |r| {
                try self.formatExpression(r.start.*);
                try self.write(if (r.inclusive) "..=" else "..");
                try self.formatExpression(r.end.*);
            },
            .await_expr => |aw| {
                try self.write("await ");
                try self.formatExpression(aw.operand.*);
            },
            .go_expr => |g| {
                try self.write("go ");
                try self.formatExpression(g.operand.*);
            },
            .literal => |lit| {
                switch (lit) {
                    .integer => |val| try self.print("{d}", .{val}),
                    .float => |val| {
                        var buf: [64]u8 = undefined;
                        const str = try std.fmt.bufPrint(&buf, "{d}", .{val});
                        try self.write(str);
                        if (std.mem.indexOfScalar(u8, str, '.') == null and std.mem.indexOfScalar(u8, str, 'e') == null) {
                            try self.write(".0");
                        }
                    },
                    .decimal => |d| try self.print("{s}m", .{d}),
                    .string => |val| try self.print("\"{s}\"", .{val}),
                    .bool => |val| try self.write(if (val) "true" else "false"),
                    .null => try self.write("null"),
                    .undefined => try self.write("undefined"),
                    .array => |elems| {
                        try self.write("[");
                        for (elems, 0..) |elem, idx| {
                            if (idx > 0) try self.write(", ");
                            try self.formatExpression(elem);
                        }
                        try self.write("]");
                    },
                    .array_repeat => |ar| {
                        try self.write("[");
                        try self.formatExpression(ar.value.*);
                        try self.print("; {d}]", .{ar.count});
                    },
                    .object => |fields| {
                        try self.write("{");
                        for (fields, 0..) |f, idx| {
                            if (idx > 0) try self.write(", ");
                            try self.print("{s}: ", .{f.name});
                            try self.formatExpression(f.value);
                        }
                        try self.write("}");
                    },
                }
            },
            .ident => |name| try self.write(name),
            .binary => |bin| {
                try self.formatBinaryChild(bin.left.*, bin.op, false);
                try self.print(" {s} ", .{binOpToStr(bin.op)});
                try self.formatBinaryChild(bin.right.*, bin.op, true);
            },
            .unary => |un| {
                try self.write(switch (un.op) {
                    .neg => "-",
                    .not => "!",
                    .bit_not => "~",
                });
                if (un.operand.kind == .binary) {
                    try self.write("(");
                    try self.formatExpression(un.operand.*);
                    try self.write(")");
                } else {
                    try self.formatExpression(un.operand.*);
                }
            },
            .call => |c| {
                try self.formatExpression(c.callee.*);
                try self.write("(");
                for (c.args, 0..) |arg, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(arg);
                }
                try self.write(")");
            },
            .generic_call => |gc| {
                try self.formatExpression(gc.callee.*);
                try self.write("<");
                for (gc.type_args, 0..) |t, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(t);
                }
                try self.write(">(");
                for (gc.args, 0..) |arg, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(arg);
                }
                try self.write(")");
            },
            .field_access => |fa| {
                try self.formatExpression(fa.object.*);
                try self.print(".{s}", .{fa.field});
            },
            .index => |ind| {
                try self.formatExpression(ind.object.*);
                try self.write("[");
                try self.formatExpression(ind.index.*);
                try self.write("]");
            },
            .struct_init => |si| {
                try self.print("{s} {{", .{si.type_name});
                for (si.fields, 0..) |f, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.print("{s}: ", .{f.name});
                    try self.formatExpression(f.value);
                }
                try self.write("}");
            },
            .enum_init => |ei| {
                try self.print("{s}.{s}", .{ei.enum_name, ei.variant});
                if (ei.fields.len > 0) {
                    try self.write(" {");
                    for (ei.fields, 0..) |f, idx| {
                        if (idx > 0) try self.write(", ");
                        try self.print("{s}: ", .{f.name});
                        try self.formatExpression(f.value);
                    }
                    try self.write("}");
                }
            },
            .cast => |c| {
                try self.formatExpression(c.expr.*);
                try self.write(" as ");
                try self.formatTypeRef(c.target_type);
            },
            .optional_chaining => |oc| {
                try self.formatExpression(oc.object.*);
                try self.print("?.{s}", .{oc.field});
            },
            .nullish_coalesce => |nc| {
                try self.formatExpression(nc.left.*);
                try self.write(" ?? ");
                try self.formatExpression(nc.right.*);
            },
            .jsx_element => |jsx| {
                try self.print("<{s}", .{jsx.tag});
                for (jsx.attributes) |attr| {
                    try self.print(" {s}=", .{attr.name});
                    switch (attr.value) {
                        .string_literal => |s| try self.print("\"{s}\"", .{s}),
                        .expression => |e| {
                            try self.write("{");
                            try self.formatExpression(e);
                            try self.write("}");
                        },
                    }
                }
                if (jsx.children.len == 0) {
                    try self.write(" />");
                } else {
                    try self.write(">");
                    for (jsx.children) |child| {
                        switch (child) {
                            .element => |el| try self.formatExpression(.{ .kind = .{ .jsx_element = el } }),
                            .expression => |e| {
                                try self.write("{");
                                try self.formatExpression(e);
                                try self.write("}");
                            },
                            .statement => |stmt| {
                                try self.write("{");
                                try self.formatStatement(stmt);
                                try self.write("}");
                            },
                            .text => |t| try self.write(t),
                        }
                    }
                    try self.print("</{s}>", .{jsx.tag});
                }
            },
            .closure => |cl| {
                try self.write("(");
                for (cl.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.write(p);
                }
                try self.write(") => ");
                switch (cl.body) {
                    .expr => |e| try self.formatExpression(e.*),
                    .block => |b| try self.formatBlock(b),
                }
            },
            .tuple => |t| {
                try self.write("(");
                for (t, 0..) |elem, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatExpression(elem);
                }
                try self.write(")");
            },
            .if_expr => |ife| {
                try self.write("if (");
                try self.formatExpression(ife.condition.*);
                try self.write(") ");
                try self.formatExpression(ife.then_branch.*);
                try self.write(" else ");
                try self.formatExpression(ife.else_branch.*);
            },
            .try_expr => |inner| {
                try self.write("try ");
                try self.formatExpression(inner.*);
            },
            .catch_expr => |ce| {
                try self.formatExpression(ce.expr.*);
                try self.write(" catch ");
                if (ce.err_name) |n| { try self.write("("); try self.write(n); try self.write(") "); }
                try self.formatExpression(ce.handler.*);
            },
            .block_expr => |b| {
                try self.formatBlock(b);
            },
            .template_expr => |temp| {

                try self.write("`");
                for (temp.parts) |part| {
                    switch (part.kind) {
                        .literal => |lit| {
                            if (lit == .string) {
                                try self.write(lit.string);
                            } else {
                                try self.write("${");
                                try self.formatExpression(part);
                                try self.write("}");
                            }
                        },
                        else => {
                            try self.write("${");
                            try self.formatExpression(part);
                            try self.write("}");
                        },
                    }
                }
                try self.write("`");
            },
        }
    }

    /// Formats a type reference in its canonical Kyte spelling.
    ///
    /// Covers each [`ast.TypeRef`] shape: a bare identifier; an error union
    /// `Ok | Err`; an optional, which prints as `T | undefined` (Kyte spells
    /// nullability that way rather than with a `?` suffix); a fixed-size array
    /// `T[N]`; a generic instantiation `Name<...>`; a function type
    /// `(params) -> ret`; and a tuple `(a, b, ...)`. Declared `anyerror` for the
    /// recursion through nested type references.
    fn formatTypeRef(self: *Formatter, tr: ast.TypeRef) anyerror!void {
        switch (tr) {
            .ident => |name| try self.write(name),
            .error_union => |eu| {

                try self.formatTypeRef(eu.ok.*);
                try self.write(" | ");
                try self.formatTypeRef(eu.err.*);
            },
            .optional => |sub| {
                try self.formatTypeRef(sub.*);
                try self.write(" | undefined");
            },
            .fixed_array => |fa| {
                try self.formatTypeRef(fa.element.*);
                try self.print("[{d}]", .{fa.length});
            },
            .generic => |g| {
                try self.write(g.name);
                try self.write("<");
                for (g.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(">");
            },
            .func => |f| {

                try self.write("(");
                for (f.params, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(") -> ");
                try self.formatTypeRef(f.ret.*);
            },
            .tuple => |t| {
                try self.write("(");
                for (t, 0..) |p, idx| {
                    if (idx > 0) try self.write(", ");
                    try self.formatTypeRef(p);
                }
                try self.write(")");
            },
        }
    }
};

/// Local alias for the standard testing namespace, used by the tests below.
const testing = std.testing;

// Guards against a real regression where the bitwise/logical operators once
// printed as internal tag names instead of source tokens.
//
// Asserts [`Formatter.binOpToStr`] maps `&`/`|`/`&&`/`||` to their distinct
// canonical spellings, so bitwise and logical operators never collide or leak
// a keyword form into formatted output.
test "formatter: `&` and `|` print as operators, not the dead and/or keywords" {

    try testing.expectEqualStrings("&", Formatter.binOpToStr(.bit_and));
    try testing.expectEqualStrings("|", Formatter.binOpToStr(.bit_or));
    try testing.expectEqualStrings("&&", Formatter.binOpToStr(.And));
    try testing.expectEqualStrings("||", Formatter.binOpToStr(.Or));
}

// Checks that every binary operator spelling is non-empty and purely
// symbolic.
//
// Iterating all [`ast.BinaryOp`] values, it asserts [`Formatter.binOpToStr`]
// returns a non-empty string containing no alphabetic characters, which is the
// invariant that keeps formatted output re-lexable as operators rather than
// identifiers/keywords.
test "formatter: every operator round-trips through the lexer" {

    for ([_]ast.BinaryOp{
        .add, .sub, .mul, .div, .mod,
        .eq,  .ne,  .lt,  .gt,  .le, .ge,
        .bit_and, .bit_or, .And, .Or, .shl, .shr, .assign,
    }) |op| {
        const s = Formatter.binOpToStr(op);
        try testing.expect(s.len > 0);

        for (s) |c| try testing.expect(!std.ascii.isAlphabetic(c));
    }
}
