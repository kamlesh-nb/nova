//! Recursive-descent parser: Nova token stream -> abstract syntax tree.
//!
//! This is the second stage of the compiler frontend. It owns a fully
//! tokenised buffer (the [`Parser.init`] path runs the lexer eagerly to EOF)
//! and walks it with a hand-written recursive-descent grammar, producing the
//! [`ast`] node tree that the type checker and `sema/` passes then consume. It
//! does NO name resolution, NO type checking, and almost NO semantic
//! validation: its job is purely to turn a linear sequence of tokens into a
//! shaped tree, plus a small number of well-defined syntactic desugarings.
//!
//! Expression precedence is encoded as a classic climbing chain of one method
//! per level, each parsing the tighter level below it and folding left:
//! assignment -> logical (`&&`/`||`/`??`/ternary) -> bit-or -> bit-xor ->
//! bit-and -> equality -> comparison -> shift -> add/sub -> mul/div -> unary
//! -> postfix -> primary. Reading that chain top to bottom is the fastest way
//! to see how tightly each operator binds. See [`Parser.parseAssignment`]
//! through [`Parser.parsePrimary`].
//!
//! Design decisions worth knowing before editing:
//!
//!   - Desugaring happens here, not in a later pass. `for (x in coll)` is
//!     lowered to an index-counted C-style `for` over `coll.size()`/`coll.at(i)`
//!     ([`Parser.desugarCollectionForIn`]); `for ((k, v) in map)` lowers to a
//!     keys() walk plus a get() ([`Parser.desugarMapForIn`]); `while (let x = e)`
//!     lowers to an infinite loop with a break-on-`undefined` guard
//!     ([`Parser.parseWhileStmt`]); compound assignment `a += b` expands to
//!     `a = a + b`; and trait default method bodies are copied into every
//!     implementing struct ([`Parser.expandTraitDefaults`]). Consumers only
//!     ever see the desugared forms.
//!
//!   - Target gating is resolved at parse time. `@wasm { ... }` / `@native { ... }`
//!     blocks are kept or brace-skipped based on [`Parser.is_wasm`], so the AST
//!     handed downstream already contains only the declarations that belong to
//!     the current target.
//!
//!   - Exceptions are rejected with teaching errors, not merely a syntax error.
//!     `throw`/`catch`-block/`try { ... }` no longer exist in Nova, and
//!     [`Parser.rejectExceptions`] prints the migration guidance to the error
//!     model (`fn f(): T | E`, prefix `try`, and `catch` as an expression
//!     operator) rather than a bare "unexpected token".
//!
//!   - Spans point back into the original source text. [`Parser.span`] recovers
//!     a byte offset by pointer arithmetic against [`Parser.source`], relying on
//!     the fact that a token's `lexeme` is a slice of that same buffer; when the
//!     lexeme is a freshly allocated string (interpolation, synthesised tokens)
//!     it falls back to offset 0.
//!
//! Allocation model: nearly every AST node and slice is allocated from the
//! caller-supplied [`Parser.allocator`] and never individually freed here. The
//! tree is expected to live in an arena that the driver frees wholesale, which
//! is why the parser can hand out borrowed sub-slices of the token buffer and
//! source freely.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

/// Failure set for every parsing routine.
///
/// `UnexpectedToken` is the catch-all for a syntax error the recogniser cannot
/// continue past (a diagnostic is usually printed to stderr first);
/// `ExpectedToken` is raised specifically by [`Parser.expect`] when a required
/// token type is absent; `OutOfMemory` propagates allocator failure. There is
/// no recovery or resynchronisation: the first error aborts the whole parse.
const ParserError = error{
    UnexpectedToken,
    ExpectedToken,
    OutOfMemory,
};

/// Extracts a compile-time non-negative integer from a literal expression, or
/// null if `e` is not an integer literal (or is negative).
///
/// Used to validate the count in an array-repeat literal `[value; N]`, where
/// `N` must be a constant `usize`. Anything that is not a plain non-negative
/// integer literal (a variable, a negative number, an expression) yields null so
/// the caller can reject it. See [`Parser.parsePrimary`].
fn intLiteralOf(e: ast.Expression) ?usize {
    switch (e.kind) {
        .literal => |lit| switch (lit) {
            .integer => |v| return if (v >= 0) @intCast(v) else null,
            else => return null,
        },
        else => return null,
    }
}

/// The recursive-descent parser and its cursor over a tokenised source file.
///
/// One `Parser` is created per compilation unit (and, recursively, one per
/// string-interpolation fragment, see [`Parser.parseTemplateString`]). It holds
/// the whole token slice and a single mutable cursor [`Parser.pos`]; the parse
/// methods advance the cursor and never backtrack destructively, though they do
/// peek arbitrarily far ahead with raw index lookups (for example the generic
/// vs less-than disambiguation in [`Parser.parsePostfix`]).
pub const Parser = struct {
    /// Allocator backing every AST node, slice, and duped string this parser
    /// produces. Expected to be an arena owned by the driver; the parser never
    /// frees individual nodes.
    allocator: std.mem.Allocator,
    /// The complete token buffer, lexed to EOF in [`Parser.init`]. A few tokens
    /// are rewritten in place during parsing (for example [`Parser.expectGenericClose`]
    /// splits a `>>` token into a single `>`), which is why this is a mutable
    /// slice rather than `[]const`.
    tokens: []lexer.Token,
    /// Index of the current token in [`Parser.tokens`]. Advanced by
    /// [`Parser.advance`]; read via [`Parser.current`]/[`Parser.peek`].
    pos: usize,
    /// Owned copy of the source file path, duped in [`Parser.init`]. Embedded in
    /// every [`ast.Span`] for diagnostics.
    file_path: []const u8,
    /// Whether the current compilation target is WebAssembly. Selects which of
    /// `@wasm { ... }` / `@native { ... }` blocks are parsed into the AST and
    /// which are brace-skipped. See [`Parser.parseProgram`] and [`Parser.parseStatement`].
    is_wasm: bool,
    /// The original source text. Token lexemes are slices into this buffer, which
    /// [`Parser.span`] exploits to recover byte offsets by pointer arithmetic.
    source: []const u8,

    /// Monotonic counter used to mint unique synthetic variable names during
    /// `for-in` desugaring (`__for_idx_N`, `__for_coll_N`, `__for_keys_N`, ...),
    /// so nested loops never collide. Incremented by
    /// [`Parser.desugarCollectionForIn`] and [`Parser.desugarMapForIn`].
    for_counter: usize = 0,

    /// Lexes `source` to completion and returns a ready-to-run parser positioned
    /// at the first token.
    ///
    /// The lexer is driven eagerly to EOF up front (rather than pulled lazily),
    /// so `tokens` always includes a terminating `.eof` token and every lookahead
    /// is a bounds-checked array index. `file_path` is duped so the parser owns
    /// it. Errors only on allocator failure.
    pub fn init(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8, is_wasm: bool) !Parser {
        var lex = lexer.Lexer.init(source);
        var token_list = std.ArrayList(lexer.Token).empty;
        defer token_list.deinit(allocator);

        while (true) {
            const token = lex.nextToken();
            try token_list.append(allocator, token);
            if (token.type == .eof) break;
        }

        return Parser{
            .allocator = allocator,
            .tokens = try token_list.toOwnedSlice(allocator),
            .pos = 0,
            .file_path = try allocator.dupe(u8, file_path),
            .is_wasm = is_wasm,
            .source = source,
        };
    }

    /// Frees the token buffer. Does NOT free the AST or any duped strings, which
    /// outlive the parser and belong to the caller's arena.
    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
    }

    /// The token under the cursor. Safe because the buffer is always
    /// EOF-terminated, so [`Parser.pos`] can never run past a real token
    /// without landing on `.eof`.
    fn current(self: *Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    /// The token one position ahead, clamped to the final (EOF) token at the end
    /// of the buffer so lookahead near end-of-file is always in bounds.
    fn peek(self: *Parser) lexer.Token {
        if (self.pos + 1 < self.tokens.len) return self.tokens[self.pos + 1];
        return self.tokens[self.tokens.len - 1];
    }

    /// Moves the cursor forward one token. No bounds guard: correctness relies on
    /// the grammar stopping at `.eof`.
    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    /// Consumes the current token if it matches `expected` and reports whether it
    /// did.
    ///
    /// Special-cased for `.identifier`: the keyword `fn` is also accepted as an
    /// identifier (so `fn` can appear as a value name), whereas [`Parser.expect`]
    /// additionally tolerates `spawn`. Unlike [`Parser.expect`] this never errors,
    /// making it the tool for optional-token grammar branches.
    fn match(self: *Parser, expected: lexer.TokenType) bool {
        const current_type = self.current().type;
        if (expected == .identifier) {
            if (current_type == .identifier or current_type == .keyword_fn) {
                self.advance();
                return true;
            }
            return false;
        }
        if (current_type == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    /// Consumes the current token, requiring it to be `expected`, else prints a
    /// diagnostic and returns `error.ExpectedToken`.
    ///
    /// The `.identifier` case is deliberately lenient: `spawn` is silently
    /// accepted as an identifier (so a variable may be named `spawn`), and `fn`
    /// likewise counts as an identifier. Any other mismatch prints the expected
    /// vs actual token with line/column before erroring.
    fn expect(self: *Parser, expected: lexer.TokenType) ParserError!void {
        const current_type = self.current().type;
        if (expected == .identifier) {

            if (current_type == .keyword_spawn) {
                self.advance();
                return;
            }
            if (current_type != .identifier and current_type != .keyword_fn) {
                std.debug.print("Expect failed: expected=identifier, got={} ('{s}') at line {}, col {}\n", .{current_type, self.current().lexeme, self.current().line, self.current().column});
                return error.ExpectedToken;
            }
        } else {
            if (current_type != expected) {
                std.debug.print("Expect failed: expected={}, got={} ('{s}') at line {}, col {}\n", .{expected, current_type, self.current().lexeme, self.current().line, self.current().column});
                return error.ExpectedToken;
            }
        }
        self.advance();
    }

    /// Consumes the `>` that closes a generic argument list, splitting a `>>`
    /// token when necessary.
    ///
    /// The lexer greedily forms `>>` (right-shift) as one token, but in nested
    /// generics such as `List<Map<K, V>>` that same `>>` must close two argument
    /// lists. This rewrites the current token in place to a single `>` and leaves
    /// the cursor on it, so the next `expectGenericClose`/`expect(.greater)`
    /// consumes the second half. This is the reason [`Parser.tokens`] is mutable.
    fn expectGenericClose(self: *Parser) ParserError!void {
        if (self.current().type == .shr) {
            self.tokens[self.pos].type = .greater;
            self.tokens[self.pos].lexeme = ">";
            return;
        }
        return self.expect(.greater);
    }

    /// Builds an [`ast.Span`] for the current token, recovering its byte offset
    /// into the original source.
    ///
    /// The offset is derived by pointer arithmetic: a normal token's `lexeme` is
    /// a sub-slice of [`Parser.source`], so subtracting the base pointer gives the
    /// start index. When the lexeme pointer is NOT within the source buffer (a
    /// synthesised or interpolation-fragment token whose text was freshly
    /// allocated) the offset falls back to 0. Line and column always come
    /// straight from the token.
    fn span(self: *Parser) ast.Span {
        const tok = self.current();
        const tok_ptr = @intFromPtr(tok.lexeme.ptr);
        const src_ptr = @intFromPtr(self.source.ptr);
        const start = if (tok_ptr >= src_ptr and tok_ptr < src_ptr + self.source.len)
            tok_ptr - src_ptr
        else
            0;
        return ast.Span{
            .start = start,
            .end = start + tok.lexeme.len,
            .line = tok.line,
            .col = tok.column,
            .file = self.file_path,
        };
    }

    /// Heap-allocates a copy of `value` and returns a pointer to it, for AST
    /// nodes that must be referenced indirectly (branch bodies, boxed
    /// sub-statements). The allocation is arena-owned and never freed here.
    fn allocStatement(self: *Parser, value: ast.Statement) !*ast.Statement {
        const ptr = try self.allocator.create(ast.Statement);
        ptr.* = value;
        return ptr;
    }

    /// Heap-allocates a copy of `value` and returns a pointer to it. The
    /// expression tree is a graph of `*ast.Expression`, so almost every operand
    /// is boxed through here. Arena-owned; never freed here.
    fn allocExpression(self: *Parser, value: ast.Expression) !*ast.Expression {
        const ptr = try self.allocator.create(ast.Expression);
        ptr.* = value;
        return ptr;
    }

    /// Parses either a `{ ... }` block or a single statement, whichever follows.
    ///
    /// This is the body form for `if`/`else`/`while`/`for`, which in Nova may be
    /// braced or a single unbraced statement. A leading `{` is treated as a block
    /// rather than an object literal in statement position.
    fn parseStatementOrBlock(self: *Parser) ParserError!ast.Statement {
        if (self.current().type == .left_brace) {
            return ast.Statement{ .block = try self.parseBlock() };
        } else {
            return try self.parseStatement();
        }
    }

    /// Copies default trait-method bodies into every struct that implements the
    /// trait but does not override them.
    ///
    /// Run once at the end of [`Parser.parseProgram`], when all declarations are
    /// visible. For each `struct S impl T`, it finds trait `T`, and for every
    /// method of `T` that has a `default_body` and is not already defined on `S`,
    /// it synthesises a concrete [`ast.MethodDecl`] on `S` with that body. The
    /// first parameter, if named `self`, is retyped to a self-reference for `S`
    /// (generic-aware, via [`Parser.selfTypeRefFor`]) so the copied body type-checks
    /// against the concrete struct. This is why later passes never need to reason
    /// about trait defaults: they are already inlined as ordinary methods.
    fn expandTraitDefaults(self: *Parser, decls: []ast.Declaration) ParserError!void {
        for (decls) |*d| {
            if (d.* != .struct_decl) continue;
            const sd = &d.struct_decl;
            if (sd.impls.len == 0) continue;

            var methods = std.ArrayList(ast.MethodDecl).empty;
            defer methods.deinit(self.allocator);
            try methods.appendSlice(self.allocator, sd.methods);

            for (sd.impls) |impl| {
                const trait = findTraitDecl(decls, impl.name) orelse continue;
                for (trait.methods) |tm| {
                    const body = tm.default_body orelse continue;
                    if (structHasMethod(methods.items, tm.name)) continue;

                    const new_params = try self.allocator.alloc(ast.Param, tm.params.len);
                    for (tm.params, 0..) |p, i| {
                        if (i == 0 and std.mem.eql(u8, p.name, "self")) {
                            new_params[i] = .{ .name = p.name, .type_name = try self.selfTypeRefFor(sd.*), .span = p.span };
                        } else {
                            new_params[i] = p;
                        }
                    }

                    try methods.append(self.allocator, ast.MethodDecl{
                        .is_public = true,
                        .is_static = false,
                        .decl = ast.FunctionDecl{
                            .name = tm.name,
                            .params = new_params,
                            .ret_type = tm.ret_type,
                            .body = body,
                            .is_exported = false,
                            .attributes = &.{},
                            .type_params = sd.type_params,
                            .is_async = tm.is_async,
                            .span = tm.span,
                        },
                    });
                }
            }
            sd.methods = try methods.toOwnedSlice(self.allocator);
        }
    }

    /// Produces the [`ast.TypeRef`] that names `sd` as its own `self` type.
    ///
    /// For a non-generic struct this is just its name; for a generic struct it is
    /// the struct name applied to its own type parameters (`Foo<T, U>`), so a
    /// copied trait-default `self` parameter refers to the fully parameterised
    /// type. Helper for [`Parser.expandTraitDefaults`].
    fn selfTypeRefFor(self: *Parser, sd: ast.StructDecl) ParserError!ast.TypeRef {
        if (sd.type_params.len == 0) return ast.TypeRef{ .ident = sd.name };
        const params = try self.allocator.alloc(ast.TypeRef, sd.type_params.len);
        for (sd.type_params, 0..) |tp, i| params[i] = ast.TypeRef{ .ident = tp };
        return ast.TypeRef{ .generic = .{ .name = sd.name, .params = params } };
    }

    /// Linear-scans the program's declarations for a trait named `name`, or null
    /// if none. Used by [`Parser.expandTraitDefaults`] to resolve the trait a
    /// struct claims to implement.
    fn findTraitDecl(decls: []ast.Declaration, name: []const u8) ?ast.TraitDecl {
        for (decls) |d| {
            if (d == .trait_decl and std.mem.eql(u8, d.trait_decl.name, name)) return d.trait_decl;
        }
        return null;
    }

    /// Reports whether `methods` already contains a method named `name`.
    ///
    /// The override guard for [`Parser.expandTraitDefaults`]: a trait default is
    /// only injected when the struct has not defined a method of the same name.
    fn structHasMethod(methods: []const ast.MethodDecl, name: []const u8) bool {
        for (methods) |m| {
            if (std.mem.eql(u8, m.decl.name, name)) return true;
        }
        return false;
    }

    /// Parses a whole compilation unit into an [`ast.Program`]: the top-level
    /// entry point.
    ///
    /// Loops over top-level items until EOF, skipping stray semicolons. It
    /// resolves `@wasm`/`@native` target blocks inline (keeping the matching
    /// target's declarations, brace-skipping the other), tolerates a bare
    /// top-level call expression such as a macro-like invocation (parsed and
    /// discarded), and otherwise delegates to [`Parser.parseDeclaration`]. After
    /// collecting all declarations it runs [`Parser.expandTraitDefaults`] over the
    /// finished set, so trait defaults are inlined before anyone else sees the
    /// tree.
    pub fn parseProgram(self: *Parser) ParserError!ast.Program {
        var declarations = std.ArrayList(ast.Declaration).empty;
        defer declarations.deinit(self.allocator);

        while (self.current().type != .eof) {
            if (self.current().type == .semicolon) {
                self.advance();
                continue;
            }

            if (self.current().type == .at) {
                const next_t = self.peek();
                if (next_t.type == .identifier and (std.mem.eql(u8, next_t.lexeme, "wasm") or std.mem.eql(u8, next_t.lexeme, "native"))) {
                    const is_wasm_block = std.mem.eql(u8, next_t.lexeme, "wasm");
                    const matches_target = (is_wasm_block == self.is_wasm);

                    self.advance();
                    self.advance();
                    try self.expect(.left_brace);

                    if (matches_target) {
                        while (self.current().type != .right_brace and self.current().type != .eof) {
                            if (self.current().type == .semicolon) {
                                self.advance();
                                continue;
                            }
                            try declarations.append(self.allocator, try self.parseDeclaration());
                        }
                        try self.expect(.right_brace);
                    } else {
                        var brace_count: usize = 1;
                        while (brace_count > 0 and self.current().type != .eof) {
                            const t = self.current();
                            self.advance();
                            if (t.type == .left_brace) brace_count += 1;
                            if (t.type == .right_brace) brace_count -= 1;
                        }
                    }
                    continue;
                }
            }

            if (self.current().type == .identifier and self.peek().type == .left_paren) {
                _ = try self.parseExpression();
                if (self.current().type == .semicolon) self.advance();
                continue;
            }

            try declarations.append(self.allocator, try self.parseDeclaration());
        }

        const decls = try declarations.toOwnedSlice(self.allocator);
        try self.expandTraitDefaults(decls);
        return ast.Program{
            .declarations = decls,
            .span = self.span(),
        };
    }

    /// Parses a run of `@name(...)` attributes preceding a declaration or member.
    ///
    /// Recognises the fixed vocabulary Nova supports: `@serializable`, `@test`,
    /// `@deprecated("note")` (optional string note), `@route("METHOD", "path")`,
    /// and the shorthand HTTP verbs `@get/@post/@put/@delete("path")` which expand
    /// to a `route` attribute with the upper-cased verb as the method. String
    /// arguments are duped into the arena. Unknown attribute names are silently
    /// consumed (their argument list is not parsed), so an unrecognised bare
    /// `@name` is skipped rather than rejected.
    fn parseAttributes(self: *Parser) ParserError![]ast.Attribute {
        var attrs = std.ArrayList(ast.Attribute).empty;
        defer attrs.deinit(self.allocator);
        while (self.current().type == .at) {
            self.advance();
            const name = self.current().lexeme;
            try self.expect(.identifier);
            if (std.mem.eql(u8, name, "serializable")) {
                try attrs.append(self.allocator, .serializable);
            } else if (std.mem.eql(u8, name, "test")) {
                try attrs.append(self.allocator, .@"test");
            } else if (std.mem.eql(u8, name, "deprecated")) {
                var note: ?[]const u8 = null;
                if (self.match(.left_paren)) {
                    if (self.current().type == .string) {
                        note = try self.allocator.dupe(u8, self.current().lexeme);
                        self.advance();
                    }
                    try self.expect(.right_paren);
                }
                try attrs.append(self.allocator, .{ .deprecated = note });
            } else if (std.mem.eql(u8, name, "route")) {
                try self.expect(.left_paren);
                if (self.current().type != .string) return error.UnexpectedToken;
                const method = try self.allocator.dupe(u8, self.current().lexeme);
                self.advance();
                try self.expect(.comma);
                if (self.current().type != .string) return error.UnexpectedToken;
                const path = try self.allocator.dupe(u8, self.current().lexeme);
                self.advance();
                try self.expect(.right_paren);
                try attrs.append(self.allocator, .{ .route = .{ .method = method, .path = path } });
            } else if (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "post") or std.mem.eql(u8, name, "put") or std.mem.eql(u8, name, "delete")) {
                try self.expect(.left_paren);
                if (self.current().type != .string) return error.UnexpectedToken;
                const path = try self.allocator.dupe(u8, self.current().lexeme);
                self.advance();
                try self.expect(.right_paren);
                const method = try self.allocator.dupe(u8, name);
                for (method) |*c| {
                    c.* = std.ascii.toUpper(c.*);
                }
                try attrs.append(self.allocator, .{ .route = .{ .method = method, .path = path } });
            }
        }
        return try attrs.toOwnedSlice(self.allocator);
    }

    /// Parses one top-level declaration, dispatching on the leading keyword.
    ///
    /// Handles the optional attribute run and `pub`/`export` modifiers first,
    /// then branches: `fn`/`async fn` and `export fn` and `extern(...) fn` become
    /// function declarations; `struct`/`class` become a struct decl (a `class` is
    /// a struct with reference semantics); `union`, `enum`, and the `exception`
    /// keyword (a tagged enum used as an error type) each map to their decl; a
    /// bare `identifier` is an error unless it is `exception`; `trait`, `import`,
    /// and `const` round out the set. `export`-declared functions are marked
    /// exported regardless of `pub`. Any other leading token is
    /// `error.UnexpectedToken`.
    fn parseDeclaration(self: *Parser) ParserError!ast.Declaration {
        const attrs = try self.parseAttributes();
        var is_public = false;
        if (self.match(.keyword_pub)) {
            is_public = true;
        }

        switch (self.current().type) {
            .keyword_export => {
                self.advance();
                var fd = try self.parseFunctionDecl(true);
                fd.attributes = attrs;
                return ast.Declaration{ .fn_decl = fd };
            },
            .keyword_fn, .keyword_async => {

                var fd = try self.parseFunctionDecl(is_public);
                fd.attributes = attrs;
                return ast.Declaration{ .fn_decl = fd };
            },
            .keyword_extern => {

                var fd = try self.parseExternFnDecl(is_public);
                fd.attributes = attrs;
                return ast.Declaration{ .fn_decl = fd };
            },
            .keyword_struct, .keyword_class => {
                var sd = try self.parseStructDecl(is_public);
                sd.attributes = attrs;
                return ast.Declaration{ .struct_decl = sd };
            },
            .keyword_union => {
                const ud = try self.parseUnionDecl(is_public);
                return ast.Declaration{ .union_decl = ud };
            },
            .keyword_enum => {
                self.advance();
                var ed = try self.parseEnumDecl(false);
                ed.attributes = attrs;
                return ast.Declaration{ .enum_decl = ed };
            },
            .identifier => {
                if (std.mem.eql(u8, self.current().lexeme, "exception")) {
                    self.advance();
                    var ed = try self.parseEnumDecl(true);
                    ed.attributes = attrs;
                    return ast.Declaration{ .enum_decl = ed };
                }
                return error.UnexpectedToken;
            },
            .keyword_trait => {
                const td = try self.parseTraitDecl(is_public);
                return ast.Declaration{ .trait_decl = td };
            },
            .keyword_import => return ast.Declaration{ .import_decl = try self.import_decl_fallback() },
            .keyword_const => return ast.Declaration{ .const_decl = try self.parseConstDecl() },
            else => return error.UnexpectedToken,
        }
    }

    /// Thin indirection to [`Parser.parseImportDecl`], kept as a named seam in the
    /// [`Parser.parseDeclaration`] dispatch for the `import` case.
    fn import_decl_fallback(self: *Parser) ParserError!ast.ImportDecl {
        return try self.parseImportDecl();
    }

    /// Parses a top-level `const NAME [: Type] = expr;` declaration.
    ///
    /// The optional type annotation is parsed and discarded (const type is
    /// inferred from the value downstream). The span runs from the `const` keyword
    /// to the terminating token. `is_exported` is always false here; export of a
    /// const is not expressed through this path.
    fn parseConstDecl(self: *Parser) ParserError!ast.ConstDecl {
        const start_span = self.span();
        try self.expect(.keyword_const);
        const name = self.current().lexeme;
        try self.expect(.identifier);
        if (self.match(.colon)) {
            _ = try self.parseTypeRef();
        }
        try self.expect(.equal);
        const value = try self.parseExpression();
        try self.expect(.semicolon);
        const end_span = self.span();
        return ast.ConstDecl{
            .name = name,
            .value = value,
            .is_exported = false,
            .span = .{
                .start = start_span.start,
                .end = end_span.start,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Extracts the bare name of a trait reference in a bound, whether written as
    /// a plain identifier (`Display`) or a generic head (`Into<T>` -> `Into`).
    /// Anything else yields the empty string. Used by [`Parser.parseWhereClause`].
    fn traitRefName(t: ast.TypeRef) []const u8 {
        return switch (t) {
            .ident => |n| n,
            .generic => |g| g.name,
            else => "",
        };
    }

    /// Parses an optional `where T: Trait1 + Trait2, U: Trait3` clause into a list
    /// of [`ast.WhereBound`].
    ///
    /// Returns an empty slice when the next token is not the contextual keyword
    /// `where` (it is an identifier, not a reserved word). Each comma-separated
    /// bound names a type parameter and one or more `+`-joined traits; the trait
    /// names are reduced to bare identifiers via [`Parser.traitRefName`].
    fn parseWhereClause(self: *Parser) ParserError![]const ast.WhereBound {
        if (!(self.current().type == .identifier and std.mem.eql(u8, self.current().lexeme, "where"))) return &.{};
        self.advance();
        var bounds = std.ArrayList(ast.WhereBound).empty;
        while (true) {
            const tp_ref = try self.parseTypeRef();
            const tp_name: []const u8 = switch (tp_ref) {
                .ident => |n| n,
                .generic => |g| g.name,
                else => "",
            };
            try self.expect(.colon);
            var traits = std.ArrayList([]const u8).empty;
            const first = try self.parseTypeRef();
            try traits.append(self.allocator, traitRefName(first));
            while (self.match(.plus)) {
                const more = try self.parseTypeRef();
                try traits.append(self.allocator, traitRefName(more));
            }
            try bounds.append(self.allocator, ast.WhereBound{
                .type_param = tp_name,
                .traits = try traits.toOwnedSlice(self.allocator),
            });
            if (!self.match(.comma)) break;
        }
        return try bounds.toOwnedSlice(self.allocator);
    }

    /// Parses a full function declaration: `[async] fn name[<T,...>](params) [: Ret] [where ...] { body }`.
    ///
    /// `is_exported` seeds the exported flag from the caller's `pub`/`export`
    /// context; additionally an `async pub fn` form is accepted, where `pub`
    /// appears after `async`, and also marks the function exported. Type
    /// parameters, parameter type annotations, return type, and where-bounds are
    /// all optional. Parameters without an explicit type get a null `type_name`
    /// (inferred later). The span covers keyword through closing brace.
    fn parseFunctionDecl(self: *Parser, is_exported: bool) ParserError!ast.FunctionDecl {
        const start_span = self.span();
        const is_async = self.match(.keyword_async);
        var exported = is_exported;
        if (!exported and is_async and self.match(.keyword_pub)) exported = true;
        try self.expect(.keyword_fn);
        const name = self.current().lexeme;
        try self.expect(.identifier);
        var type_params = std.ArrayList([]const u8).empty;
        if (self.match(.less)) {
            while (true) {
                const tp = self.current().lexeme;
                try self.expect(.identifier);
                try type_params.append(self.allocator, tp);
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater);
        }
        try self.expect(.left_paren);

        var params = std.ArrayList(ast.Param).empty;
        defer params.deinit(self.allocator);

        if (self.current().type != .right_paren) {
            while (true) {
                const param_name = self.current().lexeme;
                try self.expect(.identifier);
                const param_type = if (self.match(.colon)) try self.parseTypeRef() else null;
                try params.append(self.allocator, ast.Param{
                    .name = param_name,
                    .type_name = param_type,
                    .span = self.span(),
                });
                if (!self.match(.comma)) break;
            }
        }

        try self.expect(.right_paren);
        const ret_type = if (self.match(.colon)) try self.parseTypeRef() else null;
        const where_bounds = try self.parseWhereClause();
        const body = try self.parseBlock();

        const end_span = self.span();
        return ast.FunctionDecl{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .ret_type = ret_type,
            .body = body,
            .is_exported = exported,
            .attributes = &.{},
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .where_bounds = where_bounds,
            .is_async = is_async,
            .span = ast.Span{
                .start = start_span.start,
                .end = end_span.end,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses an FFI declaration `extern("lib") fn name(params) [: Ret];`.
    ///
    /// The `"lib"` string names the native library to bind against and is stored
    /// in `extern_lib`. There is no body: the declaration ends at a required
    /// semicolon and the resulting [`ast.FunctionDecl`] carries an empty block.
    /// Parameter and return types parse as usual.
    fn parseExternFnDecl(self: *Parser, is_exported: bool) ParserError!ast.FunctionDecl {
        const start_span = self.span();
        try self.expect(.keyword_extern);
        try self.expect(.left_paren);
        if (self.current().type != .string) return error.UnexpectedToken;
        const lib_name = try self.allocator.dupe(u8, self.current().lexeme);
        self.advance();
        try self.expect(.right_paren);
        try self.expect(.keyword_fn);
        const name = self.current().lexeme;
        try self.expect(.identifier);
        try self.expect(.left_paren);

        var params = std.ArrayList(ast.Param).empty;
        defer params.deinit(self.allocator);
        if (self.current().type != .right_paren) {
            while (true) {
                const param_name = self.current().lexeme;
                try self.expect(.identifier);
                const param_type = if (self.match(.colon)) try self.parseTypeRef() else null;
                try params.append(self.allocator, ast.Param{
                    .name = param_name,
                    .type_name = param_type,
                    .span = self.span(),
                });
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.right_paren);
        const ret_type = if (self.match(.colon)) try self.parseTypeRef() else null;
        try self.expect(.semicolon);

        const end_span = self.span();
        return ast.FunctionDecl{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .ret_type = ret_type,
            .body = ast.Block{ .statements = &.{}, .span = start_span },
            .is_exported = is_exported,
            .attributes = &.{},
            .extern_lib = lib_name,
            .span = ast.Span{
                .start = start_span.start,
                .end = end_span.end,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses a struct constructor body `(params) { body }` into a method named
    /// `"init"`.
    ///
    /// Called after the `init` keyword has already been consumed by
    /// [`Parser.parseStructDecl`], which passes the `init` token's span so the
    /// method span starts there. The synthesised function has no return type and
    /// is not exported; the caller marks it public and instance (non-static).
    fn parseInitializerDecl(self: *Parser, start_span: ast.Span) ParserError!ast.FunctionDecl {
        try self.expect(.left_paren);

        var params = std.ArrayList(ast.Param).empty;
        defer params.deinit(self.allocator);

        if (self.current().type != .right_paren) {
            while (true) {
                const param_name = self.current().lexeme;
                try self.expect(.identifier);
                const param_type = if (self.match(.colon)) try self.parseTypeRef() else null;
                try params.append(self.allocator, ast.Param{
                    .name = param_name,
                    .type_name = param_type,
                    .span = self.span(),
                });
                if (!self.match(.comma)) break;
            }
        }

        try self.expect(.right_paren);
        const body = try self.parseBlock();

        const end_span = self.span();
        return ast.FunctionDecl{
            .name = "init",
            .params = try params.toOwnedSlice(self.allocator),
            .ret_type = null,
            .body = body,
            .is_exported = false,
            .attributes = &.{},
            .span = ast.Span{
                .start = start_span.start,
                .end = end_span.end,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses a `struct` or `class` declaration, including type parameters, trait
    /// impl list, fields, methods, and `init` constructors.
    ///
    /// `class` sets `is_reference` (reference semantics); `struct` is a value
    /// type. The optional `impl Trait<...>, Trait2` list after the name records
    /// which traits the type claims, later consumed by
    /// [`Parser.expandTraitDefaults`]. Inside the body, each member may carry
    /// attributes and `pub`; a member is a method if it starts with `fn`/`async`,
    /// a constructor if it starts with `init`, otherwise a `name: Type` field.
    /// A method whose first parameter is `self` is instance, else static.
    /// Attributes on a plain field are rejected. The struct span runs from the
    /// keyword to the closing brace.
    fn parseStructDecl(self: *Parser, is_public: bool) ParserError!ast.StructDecl {
        const start_span = self.span();
        const is_class = (self.current().type == .keyword_class);
        if (is_class) try self.expect(.keyword_class) else try self.expect(.keyword_struct);
        const name = self.current().lexeme;
        try self.expect(.identifier);
        var type_params = std.ArrayList([]const u8).empty;
        if (self.match(.less)) {
            while (true) {
                const tp = self.current().lexeme;
                try self.expect(.identifier);
                try type_params.append(self.allocator, tp);
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater);
        }

        var impls = std.ArrayList(ast.TraitImpl).empty;
        defer impls.deinit(self.allocator);
        if (self.match(.keyword_impl)) {
            while (true) {
                const trait_name = self.current().lexeme;
                try self.expect(.identifier);

                var timpl_args = std.ArrayList(ast.TypeRef).empty;
                defer timpl_args.deinit(self.allocator);
                if (self.match(.less)) {
                    while (true) {
                        try timpl_args.append(self.allocator, try self.parseTypeRef());
                        if (!self.match(.comma)) break;
                    }
                    try self.expectGenericClose();
                }
                try impls.append(self.allocator, .{
                    .name = trait_name,
                    .type_args = try timpl_args.toOwnedSlice(self.allocator),
                });
                if (!self.match(.comma)) break;
            }
        }

        try self.expect(.left_brace);

        var fields = std.ArrayList(ast.Field).empty;
        defer fields.deinit(self.allocator);
        var methods = std.ArrayList(ast.MethodDecl).empty;
        defer methods.deinit(self.allocator);

        while (self.current().type != .right_brace and self.current().type != .eof) {
            const attrs = try self.parseAttributes();
            var field_is_pub = false;

            while (true) {
                if (self.match(.keyword_pub)) {
                    field_is_pub = true;
                } else {
                    break;
                }
            }

            if (self.current().type == .keyword_fn or self.current().type == .keyword_async) {
                var fd = try self.parseFunctionDecl(false);
                fd.attributes = attrs;
                var is_static = true;
                if (fd.params.len > 0 and std.mem.eql(u8, fd.params[0].name, "self")) {
                    is_static = false;
                }
                try methods.append(self.allocator, ast.MethodDecl{
                    .is_public = field_is_pub or fd.is_exported,
                    .is_static = is_static,
                    .decl = fd,
                });
            } else if (self.current().type == .identifier and std.mem.eql(u8, self.current().lexeme, "init")) {
                const init_span = self.span();
                self.advance();
                var fd = try self.parseInitializerDecl(init_span);
                fd.attributes = attrs;
                try methods.append(self.allocator, ast.MethodDecl{
                    .is_public = true,
                    .is_static = false,
                    .decl = fd,
                });
            } else {
                if (attrs.len > 0) return error.UnexpectedToken;
                const field_span = self.span();
                const field_name = self.current().lexeme;
                try self.expect(.identifier);
                try self.expect(.colon);
                const field_type = try self.parseTypeRef();
                try fields.append(self.allocator, ast.Field{
                    .name = field_name,
                    .type_name = field_type,
                    .is_public = field_is_pub,
                    .span = field_span,
                });
                if (self.current().type == .comma) self.advance();
            }
        }

        try self.expect(.right_brace);
        const end_span = self.span();
        return ast.StructDecl{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .attributes = &.{},
            .impls = try impls.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .is_reference = is_class,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .span = .{
                .start = start_span.start,
                .end = end_span.start,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses a C-style `union Name { field: Type, ... }` declaration.
    ///
    /// A union is a flat list of typed, optionally `pub` fields with no methods,
    /// no type parameters, and no discriminant (unlike an `enum`, which carries a
    /// tag and per-variant payloads). Trailing commas are tolerated.
    fn parseUnionDecl(self: *Parser, is_public: bool) ParserError!ast.UnionDecl {
        try self.expect(.keyword_union);
        const name = self.current().lexeme;
        try self.expect(.identifier);
        try self.expect(.left_brace);

        var fields = std.ArrayList(ast.Field).empty;
        defer fields.deinit(self.allocator);

        while (self.current().type != .right_brace and self.current().type != .eof) {
            var field_is_pub = false;
            if (self.match(.keyword_pub)) {
                field_is_pub = true;
            }
            const field_name = self.current().lexeme;
            try self.expect(.identifier);
            try self.expect(.colon);
            const field_type = try self.parseTypeRef();
            try fields.append(self.allocator, ast.Field{
                .name = field_name,
                .type_name = field_type,
                .is_public = field_is_pub,
                .span = self.span(),
            });
            if (self.current().type == .comma) self.advance();
        }

        try self.expect(.right_brace);
        return ast.UnionDecl{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .span = self.span(),
        };
    }

    /// Parses an `enum`/`exception` body into variants and methods.
    ///
    /// Called with the `enum` (or `exception`) keyword already consumed, so the
    /// cursor is on the name. `is_exception` tags the enum as an error type.
    /// Each variant may take one of four shapes:
    ///   - bare (`Red`),
    ///   - explicit integer value (`Red = 1`),
    ///   - named-field payload (`Point { x: int, y: int }`),
    ///   - tuple payload (`Pair(int, string)`), stored as positional fields named
    ///     `_0`, `_1`, ...; a single-element parenthesised type is instead treated
    ///     as a newtype-style `type_name` rather than a one-field tuple.
    /// An enum may also declare methods (`fn`/`async fn`), classified static vs
    /// instance by whether the first parameter is `self`. Attributes on a plain
    /// variant are rejected.
    fn parseEnumDecl(self: *Parser, is_exception: bool) ParserError!ast.EnumDecl {
        const start_span = self.span();
        const name = self.current().lexeme;
        try self.expect(.identifier);
        try self.expect(.left_brace);

        var variants = std.ArrayList(ast.Variant).empty;
        defer variants.deinit(self.allocator);
        var methods = std.ArrayList(ast.MethodDecl).empty;
        defer methods.deinit(self.allocator);

        while (self.current().type != .right_brace and self.current().type != .eof) {
            const attrs = try self.parseAttributes();
            var is_pub = false;
            if (self.current().type == .keyword_pub) {
                _ = self.advance();
                is_pub = true;
            }

            if (self.current().type == .keyword_fn or self.current().type == .keyword_async) {
                var fd = try self.parseFunctionDecl(false);
                fd.attributes = attrs;
                var is_static = true;
                if (fd.params.len > 0 and std.mem.eql(u8, fd.params[0].name, "self")) {
                    is_static = false;
                }
                try methods.append(self.allocator, ast.MethodDecl{
                    .is_public = is_pub or fd.is_exported,
                    .is_static = is_static,
                    .decl = fd,
                });
            } else {
                if (attrs.len > 0) return error.UnexpectedToken;
                const var_span = self.span();
                const var_name = self.current().lexeme;
                try self.expect(.identifier);

                var value: ?i64 = null;
                var fields: ?[]ast.Field = null;
                var type_name: ?ast.TypeRef = null;

                if (self.match(.equal)) {
                    const val_token = self.current();
                    try self.expect(.integer);
                    value = try self.parseIntLexeme(val_token);
                } else if (self.match(.left_brace)) {
                    var payload_fields = std.ArrayList(ast.Field).empty;
                    defer payload_fields.deinit(self.allocator);
                    while (self.current().type != .right_brace and self.current().type != .eof) {
                        var field_is_pub = false;
                        if (self.match(.keyword_pub)) {
                            field_is_pub = true;
                        }
                        const f_name = self.current().lexeme;
                        try self.expect(.identifier);
                        try self.expect(.colon);
                        const f_type = try self.parseTypeRef();
                        try payload_fields.append(self.allocator, ast.Field{
                            .name = f_name,
                            .type_name = f_type,
                            .is_public = field_is_pub,
                            .span = self.span(),
                        });
                        if (self.current().type == .comma) self.advance();
                    }
                    try self.expect(.right_brace);
                    fields = try payload_fields.toOwnedSlice(self.allocator);
                } else if (self.match(.left_paren)) {
                    const first_type = try self.parseTypeRef();
                    if (self.current().type == .comma) {
                        var payload_fields = std.ArrayList(ast.Field).empty;
                        defer payload_fields.deinit(self.allocator);
                        try payload_fields.append(self.allocator, ast.Field{
                            .name = "_0",
                            .type_name = first_type,
                            .is_public = true,
                            .span = var_span,
                        });
                        var pidx: usize = 1;
                        while (self.match(.comma)) {
                            const ft = try self.parseTypeRef();
                            const nm = try std.fmt.allocPrint(self.allocator, "_{d}", .{pidx});
                            try payload_fields.append(self.allocator, ast.Field{
                                .name = nm,
                                .type_name = ft,
                                .is_public = true,
                                .span = var_span,
                            });
                            pidx += 1;
                        }
                        try self.expect(.right_paren);
                        fields = try payload_fields.toOwnedSlice(self.allocator);
                    } else {
                        try self.expect(.right_paren);
                        type_name = first_type;
                    }
                }

                try variants.append(self.allocator, ast.Variant{
                    .name = var_name,
                    .value = value,
                    .fields = fields,
                    .type_name = type_name,
                    .span = var_span,
                });
            }
            if (self.current().type == .comma) self.advance();
        }

        try self.expect(.right_brace);
        const end_span = self.span();
        return ast.EnumDecl{
            .name = name,
            .variants = try variants.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .attributes = &.{},
            .is_exception = is_exception,
            .span = .{
                .start = start_span.start,
                .end = end_span.start,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses a `trait Name[<T,...>] { ... }` declaration.
    ///
    /// Each member is a method signature: `[async] fn name(params) [: Ret]
    /// [where ...]` followed either by a `{ default body }` (recorded as
    /// `default_body`, later inlined by [`Parser.expandTraitDefaults`]) or a bare
    /// `;` for an abstract requirement. The receiver is written as a bare `self`
    /// parameter with no type annotation, which this recognises specially and
    /// records with a `self` type-ref. Per-method where-clauses are parsed but
    /// discarded here.
    fn parseTraitDecl(self: *Parser, is_public: bool) ParserError!ast.TraitDecl {
        try self.expect(.keyword_trait);
        const name = self.current().lexeme;
        try self.expect(.identifier);

        var type_params = std.ArrayList([]const u8).empty;
        if (self.match(.less)) {
            while (true) {
                const tp = self.current().lexeme;
                try self.expect(.identifier);
                try type_params.append(self.allocator, tp);
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }
        try self.expect(.left_brace);

        var methods = std.ArrayList(ast.TraitMethodDecl).empty;
        defer methods.deinit(self.allocator);

        while (self.current().type != .right_brace and self.current().type != .eof) {

            const m_is_async = self.match(.keyword_async);
            try self.expect(.keyword_fn);
            const fn_name = self.current().lexeme;
            try self.expect(.identifier);

            try self.expect(.left_paren);
            var params = std.ArrayList(ast.Param).empty;
            defer params.deinit(self.allocator);
            while (self.current().type != .right_paren and self.current().type != .eof) {
                const param_name = self.current().lexeme;
                try self.expect(.identifier);

                if (std.mem.eql(u8, param_name, "self") and self.current().type != .colon) {
                    try params.append(self.allocator, ast.Param{
                        .name = param_name,
                        .type_name = .{ .ident = "self" },
                        .span = self.span(),
                    });
                    if (self.current().type == .comma) self.advance();
                    continue;
                }
                try self.expect(.colon);
                const param_type = try self.parseTypeRef();
                try params.append(self.allocator, ast.Param{
                    .name = param_name,
                    .type_name = param_type,
                    .span = self.span(),
                });
                if (self.current().type == .comma) self.advance();
            }
            try self.expect(.right_paren);

            const ret_type = if (self.match(.colon)) try self.parseTypeRef() else null;
            _ = try self.parseWhereClause();
            var default_body: ?ast.Block = null;
            if (self.current().type == .left_brace) {
                default_body = try self.parseBlock();
            } else if (self.current().type == .semicolon) {
                self.advance();
            }

            try methods.append(self.allocator, ast.TraitMethodDecl{
                .name = fn_name,
                .params = try params.toOwnedSlice(self.allocator),
                .ret_type = ret_type,
                .is_async = m_is_async,
                .default_body = default_body,
                .span = self.span(),
            });
        }

        try self.expect(.right_brace);
        return ast.TraitDecl{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .span = self.span(),
        };
    }

    /// Parses `import a.b.c;` into an [`ast.ImportDecl`] whose `module` is the
    /// dotted path rewritten with `/` separators (`a/b/c`).
    ///
    /// Each path segment is normally an identifier, but a purely numeric segment
    /// is also accepted (some generated module paths contain numbers). The
    /// assembled slash-path is duped into the arena. The `items` list is always
    /// empty: selective `import { x } from ...` is not parsed here.
    fn parseImportDecl(self: *Parser) ParserError!ast.ImportDecl {
        try self.expect(.keyword_import);
        var path_buf = std.ArrayList(u8).empty;
        defer path_buf.deinit(self.allocator);

        const first = self.current().lexeme;
        try self.expect(.identifier);
        try path_buf.appendSlice(self.allocator, first);

        while (self.current().type == .dot) {
            self.advance();
            const part = self.current().lexeme;
            if (self.current().type == .integer) {
                self.advance();
            } else {
                try self.expect(.identifier);
            }
            try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, part);
        }

        try self.expect(.semicolon);
        const module = try self.allocator.dupe(u8, path_buf.items);
        return ast.ImportDecl{
            .module = module,
            .items = &.{},
            .span = self.span(),
        };
    }

    /// Parses one "atomic" type: the base before any postfix `?`, `|`, or `[N]`
    /// suffix that [`Parser.parseTypeRef`] layers on top.
    ///
    /// Handles: a leading `&`/`&mut` borrow marker (consumed and ignored, the
    /// borrowed type is returned as-is); a parenthesised form that is either a
    /// grouping, a tuple `(A, B)`, or a function type `(A, B) => R` / `(A) -> R`
    /// depending on whether a `=>`/`->` follows; the variadic `...` spelled as the
    /// `any` type; and a possibly dotted, possibly generic named type
    /// (`std.List<T>`), where a trailing `<...>` produces a `generic` type-ref.
    fn parseTypeRefAtom(self: *Parser) ParserError!ast.TypeRef {
        if (self.match(.ampersand)) {
            if (self.current().type == .identifier and std.mem.eql(u8, self.current().lexeme, "mut")) {
                self.advance();
            }
            return try self.parseTypeRefAtom();
        }
        return blk: {
            if (self.match(.left_paren)) {
                var items = std.ArrayList(ast.TypeRef).empty;
                defer items.deinit(self.allocator);
                if (self.current().type != .right_paren) {
                    while (true) {
                        try items.append(self.allocator, try self.parseTypeRef());
                        if (!self.match(.comma)) break;
                    }
                }
                try self.expect(.right_paren);
                if (self.match(.fat_arrow) or self.match(.arrow)) {
                    const ret = try self.parseTypeRef();
                    const ret_ptr = try self.allocator.create(ast.TypeRef);
                    ret_ptr.* = ret;
                    break :blk ast.TypeRef{ .func = .{ .params = try items.toOwnedSlice(self.allocator), .ret = ret_ptr } };
                } else if (items.items.len == 1) {
                    break :blk items.items[0];
                } else {
                    break :blk ast.TypeRef{ .tuple = try items.toOwnedSlice(self.allocator) };
                }
            }

            if (self.current().type == .ellipsis) {
                self.advance();
                break :blk ast.TypeRef{ .ident = "any" };
            }

            var name = self.current().lexeme;
            try self.expect(.identifier);
            while (self.match(.dot)) {
                name = self.current().lexeme;
                try self.expect(.identifier);
            }

            if (self.match(.less)) {
                var params = std.ArrayList(ast.TypeRef).empty;
                defer params.deinit(self.allocator);
                while (true) {
                    try params.append(self.allocator, try self.parseTypeRef());
                    if (!self.match(.comma)) break;
                }
                try self.expectGenericClose();
                break :blk ast.TypeRef{ .generic = .{ .name = name, .params = try params.toOwnedSlice(self.allocator) } };
            }

            break :blk ast.TypeRef{ .ident = name };
        };

    }

    /// Parses a full type reference: an atom ([`Parser.parseTypeRefAtom`]) plus any
    /// chain of postfix modifiers.
    ///
    /// The postfix loop applies, in any order:
    ///   - `| E` union tails, which encode the error/optional model. A `T | undefined`
    ///     wraps `T` as `optional`; a `T | E` wraps it as an `error_union` with ok
    ///     and err arms. Only ONE error type is permitted: a second named error
    ///     (`T | E1 | E2`) prints a spec-referenced diagnostic and errors, because
    ///     multiple error types must be modelled as one error enum.
    ///   - `?` optional suffix.
    ///   - `[N]` fixed-size array suffix (N is a required integer literal).
    /// Finally, a doubly-wrapped optional (`T??`) is flattened to a single
    /// optional. See the file header for how this fits the error model.
    fn parseTypeRef(self: *Parser) ParserError!ast.TypeRef {
        var base_type: ast.TypeRef = try self.parseTypeRefAtom();

        while (true) {
            if (self.match(.pipe)) {

                var saw_undefined = false;
                var err_type: ?ast.TypeRef = null;

                while (true) {
                    const m_tok = self.current();
                    if (m_tok.type == .identifier and std.mem.eql(u8, m_tok.lexeme, "undefined")) {
                        self.advance();
                        saw_undefined = true;
                    } else {
                        const member = try self.parseTypeRefAtom();
                        if (err_type != null) {

                            const sp = self.span();
                            std.debug.print(
                                "{s}:{d}:{d}: error: a signature may name only ONE error type.\n" ++
                                "  `T | E1 | E2` is not supported. Use one error enum with variants:\n" ++
                                "      enum DbError {{ Timeout(int), Conn(string) }}\n" ++
                                "      fn q(): Row | DbError\n" ++
                                "  See specs.md §3.4b.\n",
                                .{ sp.file, sp.line, sp.col },
                            );
                            return error.UnexpectedToken;
                        }
                        err_type = member;
                    }
                    if (!self.match(.pipe)) break;
                }
                if (saw_undefined and base_type != .optional) {
                    const opt_ptr = try self.allocator.create(ast.TypeRef);
                    opt_ptr.* = base_type;
                    base_type = ast.TypeRef{ .optional = opt_ptr };
                }
                if (err_type) |et| {
                    const ok_ptr = try self.allocator.create(ast.TypeRef);
                    ok_ptr.* = base_type;
                    const err_ptr = try self.allocator.create(ast.TypeRef);
                    err_ptr.* = et;
                    base_type = ast.TypeRef{ .error_union = .{ .ok = ok_ptr, .err = err_ptr } };
                }
            } else if (self.match(.question)) {
                if (base_type != .optional) {
                    const opt_ptr = try self.allocator.create(ast.TypeRef);
                    opt_ptr.* = base_type;
                    base_type = ast.TypeRef{ .optional = opt_ptr };
                }
            } else if (self.match(.left_bracket)) {
                const len_token = self.current();
                try self.expect(.integer);
                const len = std.fmt.parseInt(usize, len_token.lexeme, 10) catch return error.UnexpectedToken;
                try self.expect(.right_bracket);
                const arr_ptr = try self.allocator.create(ast.TypeRef);
                arr_ptr.* = base_type;
                base_type = ast.TypeRef{ .fixed_array = .{
                    .element = arr_ptr,
                    .length = len,
                } };
            } else {
                break;
            }
        }

        while (base_type == .optional and base_type.optional.* == .optional) {
            base_type = base_type.optional.*;
        }

        return base_type;
    }

    /// Parses a braced `{ ... }` block into an [`ast.Block`] of statements,
    /// skipping empty `;` statements. Stops at `}` (required) or EOF.
    fn parseBlock(self: *Parser) ParserError!ast.Block {
        try self.expect(.left_brace);
        var stmts = std.ArrayList(ast.Statement).empty;
        defer stmts.deinit(self.allocator);

        while (self.current().type != .right_brace and self.current().type != .eof) {
            if (self.current().type == .semicolon) {
                self.advance();
                continue;
            }
            try stmts.append(self.allocator, try self.parseStatement());
        }

        try self.expect(.right_brace);
        return ast.Block{
            .statements = try stmts.toOwnedSlice(self.allocator),
            .span = self.span(),
        };
    }

    /// Parses a single statement, dispatching on the leading keyword.
    ///
    /// Covers `let`/`const` bindings, `if`/`while`/`for`/`switch`/`return`,
    /// `defer`/`errdefer`, `break`/`continue`, bare blocks, and statement-position
    /// `@wasm`/`@native` target gating (matching-target statements are parsed into
    /// a block, non-matching ones are brace-skipped to an empty block). Several
    /// removed constructs are intercepted with teaching errors: `var` (use
    /// `let`/`const`), and the exception forms `throw`/`catch`/`try { ... }` via
    /// [`Parser.rejectExceptions`]. A prefix `try expr` in statement position (not
    /// `try {`) is an ordinary expression statement. Anything else falls through
    /// to an expression statement.
    fn parseStatement(self: *Parser) ParserError!ast.Statement {
        switch (self.current().type) {
            .keyword_let => return ast.Statement{ .let_stmt = try self.parseLetStmt(false) },
            .keyword_var => {

                const t = self.current();
                std.debug.print("Parser error: {s}:{}:{}: `var` is not a Nova keyword — use `let` for a mutable variable or `const` for a constant.\n", .{ self.file_path, t.line, t.column });
                return error.UnexpectedToken;
            },
            .keyword_const => return ast.Statement{ .let_stmt = try self.parseLetStmt(true) },
            .keyword_if => return ast.Statement{ .if_stmt = try self.parseIfStmt() },
            .keyword_while => return ast.Statement{ .while_stmt = try self.parseWhileStmt() },
            .keyword_for => return try self.parseForStmt(),
            .keyword_switch => return ast.Statement{ .switch_stmt = try self.parseSwitchStmt() },
            .keyword_return => return ast.Statement{ .return_stmt = try self.parseReturnStmt() },

            .keyword_throw, .keyword_catch => return self.rejectExceptions(),
            .keyword_try => {
                if (self.peekIsLeftBrace()) return self.rejectExceptions();
                return ast.Statement{ .expr_stmt = try self.parseExprStmt() };
            },
            .keyword_defer => return ast.Statement{ .defer_stmt = try self.parseDeferStmt(false) },
            .keyword_errdefer => return ast.Statement{ .defer_stmt = try self.parseDeferStmt(true) },
            .keyword_break => {
                self.advance();
                try self.expect(.semicolon);
                return ast.Statement{ .break_stmt = ast.BreakStmt{ .span = self.span() } };
            },
            .keyword_continue => {
                self.advance();
                try self.expect(.semicolon);
                return ast.Statement{ .continue_stmt = ast.ContinueStmt{ .span = self.span() } };
            },
            .left_brace => return ast.Statement{ .block = try self.parseBlock() },
            .at => {
                const next_t = self.peek();
                if (next_t.type == .identifier and (std.mem.eql(u8, next_t.lexeme, "wasm") or std.mem.eql(u8, next_t.lexeme, "native"))) {
                    const is_wasm_block = std.mem.eql(u8, next_t.lexeme, "wasm");
                    const matches_target = (is_wasm_block == self.is_wasm);

                    try self.expect(.at);
                    self.advance();
                    try self.expect(.left_brace);

                    if (matches_target) {
                        var statements = std.ArrayList(ast.Statement).empty;
                        defer statements.deinit(self.allocator);
                        while (self.current().type != .right_brace and self.current().type != .eof) {
                            try statements.append(self.allocator, try self.parseStatement());
                        }
                        try self.expect(.right_brace);
                        return ast.Statement{
                            .block = ast.Block{
                                .statements = try statements.toOwnedSlice(self.allocator),
                                .span = self.span(),
                            },
                        };
                    } else {
                        var brace_count: usize = 1;
                        while (brace_count > 0 and self.current().type != .eof) {
                            const t = self.current();
                            self.advance();
                            if (t.type == .left_brace) brace_count += 1;
                            if (t.type == .right_brace) brace_count -= 1;
                        }
                        return ast.Statement{
                            .block = ast.Block{
                                .statements = &.{},
                                .span = self.span(),
                            },
                        };
                    }
                } else {
                    return ast.Statement{ .expr_stmt = try self.parseExprStmt() };
                }
            },
            else => return ast.Statement{ .expr_stmt = try self.parseExprStmt() },
        }
    }

    /// Reports whether the token after the cursor is `{`.
    ///
    /// Used to distinguish the removed exception form `try { ... }` (rejected)
    /// from the prefix operator `try expr` in [`Parser.parseStatement`].
    fn peekIsLeftBrace(self: *Parser) bool {
        return self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].type == .left_brace;
    }

    /// Always errors, printing a migration diagnostic for a removed exception
    /// keyword.
    ///
    /// Nova has no exceptions: `throw`/`catch { }`/`try { }` were removed because
    /// a thrown value was truncated to i32, leaked unwound frames, and longjmp out
    /// of an async fn is undefined behaviour. Two messages are produced: one for
    /// `try { ... }` explaining that `try` is a prefix operator on an expression,
    /// and a general one for the other keywords pointing at the error-value model
    /// (`fn f(): T | E`). Returns `error.UnexpectedToken` in every case.
    fn rejectExceptions(self: *Parser) ParserError!ast.Statement {
        const tok = self.current();
        const sp = self.span();
        if (tok.type == .keyword_try) {

            std.debug.print(
                "{s}:{d}:{d}: error: `try {{ ... }}` (the exception form) does not exist in Nova.\n" ++
                "  `try` is a PREFIX operator on an expression, not a block:\n" ++
                "      let raw = try readConfig(path);   // error -> return it from this fn\n" ++
                "      let p   = loadPort() catch 8080;  // error -> use 8080\n" ++
                "      let p   = loadPort() catch (e) reason(e);\n" ++
                "  It branches on a returned VALUE — nothing unwinds. See specs.md §3.4b.\n",
                .{ sp.file, sp.line, sp.col },
            );
            return error.UnexpectedToken;
        }
        std.debug.print(
            "{s}:{d}:{d}: error: '{s}' was removed from Nova — exceptions do not exist.\n" ++
            "  The thrown value could not survive: it was truncated to an i32, so `throw \"msg\"`\n" ++
            "  was caught as an integer. It also leaked every frame it unwound, and longjmp out\n" ++
            "  of an async fn is undefined behaviour.\n" ++
            "  Return an error VALUE instead: `fn f(): T | E` — see specs.md §3.4b and §5.5.\n",
            .{ sp.file, sp.line, sp.col, tok.lexeme },
        );
        return error.UnexpectedToken;
    }

    /// Parses `defer expr;` or, when `is_err` is set, `errdefer expr;`.
    ///
    /// `defer` runs its expression on normal scope exit; `errdefer` only on an
    /// error-propagating exit. The distinction is carried in the `is_err` field of
    /// the resulting [`ast.DeferStmt`].
    fn parseDeferStmt(self: *Parser, is_err: bool) ParserError!ast.DeferStmt {
        try self.expect(if (is_err) .keyword_errdefer else .keyword_defer);
        const expr = try self.parseExpression();
        try self.expect(.semicolon);
        return ast.DeferStmt{
            .expr = expr,
            .is_err = is_err,
            .span = self.span(),
        };
    }

    /// Parses `let`/`const` binding: `let name [: Type] [= expr];` or a
    /// destructuring `let (a, b) = expr;`.
    ///
    /// `is_const` selects the keyword and is recorded on the binding. A
    /// parenthesised name list produces a tuple destructuring (`names` set, `name`
    /// empty); a single identifier sets `name` and leaves `names` null. Both the
    /// type annotation and the initialiser are optional at parse time. The span
    /// runs from the keyword to the terminating token.
    fn parseLetStmt(self: *Parser, is_const: bool) ParserError!ast.LetStmt {
        const start_span = self.span();
        if (is_const) {
            try self.expect(.keyword_const);
        } else {
            try self.expect(.keyword_let);
        }
        var names: ?[][]const u8 = null;
        var name: []const u8 = "";
        if (self.match(.left_paren)) {
            var name_list = std.ArrayList([]const u8).empty;
            defer name_list.deinit(self.allocator);
            while (true) {
                const n = self.current().lexeme;
                try self.expect(.identifier);
                try name_list.append(self.allocator, n);
                if (!self.match(.comma)) break;
            }
            try self.expect(.right_paren);
            names = try name_list.toOwnedSlice(self.allocator);
        } else {
            name = self.current().lexeme;
            try self.expect(.identifier);
        }
        const type_name = if (self.match(.colon)) try self.parseTypeRef() else null;
        const init_expr = if (self.match(.equal)) try self.parseExpression() else null;
        try self.expect(.semicolon);

        const end_span = self.span();
        return ast.LetStmt{
            .name = name,
            .names = names,
            .type_name = type_name,
            .init = init_expr,
            .is_const = is_const,
            .span = .{
                .start = start_span.start,
                .end = end_span.start,
                .line = start_span.line,
                .col = start_span.col,
                .file = start_span.file,
            },
        };
    }

    /// Parses `if (cond) then [else ...]`, recursing on `else if` to build a
    /// right-leaning chain.
    ///
    /// The condition is parenthesised. Each branch is a statement-or-block
    /// ([`Parser.parseStatementOrBlock`]). An `else if` is stored as a nested
    /// [`ast.IfStmt`] in the else branch; a plain `else` stores its body directly;
    /// absence of `else` leaves the branch null.
    fn parseIfStmt(self: *Parser) ParserError!ast.IfStmt {
        try self.expect(.keyword_if);
        try self.expect(.left_paren);
        const cond = try self.parseExpression();
        try self.expect(.right_paren);
        const then_branch = try self.allocStatement(try self.parseStatementOrBlock());

        const else_branch = if (self.match(.keyword_else)) blk: {
            if (self.current().type == .keyword_if) {
                const else_if = try self.parseIfStmt();
                break :blk try self.allocStatement(ast.Statement{ .if_stmt = else_if });
            } else {
                break :blk try self.allocStatement(try self.parseStatementOrBlock());
            }
        } else null;

        return ast.IfStmt{
            .condition = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .span = self.span(),
        };
    }

    /// Parses `while (cond) body`, including the `while (let x = e)` binding form.
    ///
    /// The plain form is a direct [`ast.WhileStmt`]. The `while (let x = e)` form
    /// is DESUGARED here into an infinite `while (true)` whose body first binds
    /// `let x = e`, then guards `if (x == undefined) break;`, then runs the user
    /// body. This lets a loop pull an optional each iteration and stop when it
    /// becomes empty, without a dedicated loop node downstream. The synthesised
    /// comparison uses the `undefined` literal as the empty sentinel.
    fn parseWhileStmt(self: *Parser) ParserError!ast.WhileStmt {
        try self.expect(.keyword_while);
        try self.expect(.left_paren);

        if (self.current().type == .keyword_let) {
            const sp = self.span();
            self.advance();
            const bind_name = self.current().lexeme;
            try self.expect(.identifier);
            try self.expect(.equal);
            const bound_expr = try self.parseExpression();
            try self.expect(.right_paren);
            const user_body = try self.parseStatementOrBlock();

            const let_stmt = ast.Statement{ .let_stmt = ast.LetStmt{
                .name = bind_name,
                .names = null,
                .type_name = null,
                .init = bound_expr,
                .is_const = false,
                .span = sp,
            } };
            const lhs = try self.allocExpression(ast.Expression{ .kind = .{ .ident = bind_name } });
            const rhs = try self.allocExpression(ast.Expression{ .kind = .{ .literal = .undefined } });
            const cmp = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{ .left = lhs, .op = .eq, .right = rhs, .span = sp } } };
            const break_block = try self.allocStatement(ast.Statement{ .block = ast.Block{
                .statements = try self.allocator.dupe(ast.Statement, &.{ast.Statement{ .break_stmt = ast.BreakStmt{ .span = sp } }}),
                .span = sp,
            } });
            const guard = ast.Statement{ .if_stmt = ast.IfStmt{
                .condition = cmp,
                .then_branch = break_block,
                .else_branch = null,
                .span = sp,
            } };

            var stmts = std.ArrayList(ast.Statement).empty;
            defer stmts.deinit(self.allocator);
            try stmts.append(self.allocator, let_stmt);
            try stmts.append(self.allocator, guard);
            try stmts.append(self.allocator, user_body);

            const loop_body = ast.Statement{ .block = ast.Block{
                .statements = try stmts.toOwnedSlice(self.allocator),
                .span = sp,
            } };
            return ast.WhileStmt{
                .condition = ast.Expression{ .kind = .{ .literal = .{ .bool = true } } },
                .body = try self.allocStatement(loop_body),
                .span = sp,
            };
        }

        const cond = try self.parseExpression();
        try self.expect(.right_paren);
        const body = try self.parseStatementOrBlock();
        return ast.WhileStmt{
            .condition = cond,
            .body = try self.allocStatement(body),
            .span = self.span(),
        };
    }

    /// Parses an expression that may be a range `a..b` / `a..=b`, or a plain
    /// expression if no range operator follows.
    ///
    /// Used for the iterable in `for (i in a..b)`. `..=` is inclusive of the end,
    /// `..` exclusive. When no `..`/`..=` follows, the leading expression is
    /// returned unchanged, so this is a superset of [`Parser.parseExpression`].
    fn parseRangeOrExpr(self: *Parser) ParserError!ast.Expression {
        const start = try self.parseExpression();
        if (self.current().type == .dot_dot or self.current().type == .dot_dot_eq) {
            const inclusive = self.current().type == .dot_dot_eq;
            self.advance();
            const end = try self.parseExpression();
            return ast.Expression{ .kind = .{ .range = .{
                .start = try self.allocExpression(start),
                .end = try self.allocExpression(end),
                .inclusive = inclusive,
                .span = self.span(),
            } } };
        }
        return start;
    }

    /// Builds a synthetic `recv.method(args)` call expression.
    ///
    /// A small AST-construction helper for the `for-in` desugarings, which emit
    /// calls like `coll.size()`, `coll.at(i)`, `map.keys()`, and `map.get(k)`.
    /// `recv` is an identifier name, not an arbitrary expression. See
    /// [`Parser.desugarCollectionForIn`] and [`Parser.desugarMapForIn`].
    fn mkMethodCall(self: *Parser, recv: []const u8, method: []const u8, args: []ast.Expression, sp: ast.Span) ParserError!ast.Expression {
        const obj = try self.allocExpression(.{ .kind = .{ .ident = recv } });
        const callee = try self.allocExpression(.{ .kind = .{ .field_access = .{ .object = obj, .field = method, .span = sp } } });
        return ast.Expression{ .kind = .{ .call = .{ .callee = callee, .args = args, .span = sp } } };
    }

    /// Lowers `for (name in iterable) body` over an indexable collection into an
    /// index-counted C-style loop.
    ///
    /// Emits (conceptually):
    /// ```
    /// let __for_coll_N = iterable;              // omitted when iterable is a bare ident
    /// let __for_idx_N: int = 0;
    /// for (; __for_idx_N < __for_coll_N.size(); __for_idx_N = __for_idx_N + 1) {
    ///     let name = __for_coll_N.at(__for_idx_N);
    ///     body
    /// }
    /// ```
    /// The unique suffix `N` comes from [`Parser.for_counter`] so nested loops do
    /// not collide. When `iterable` is already a simple identifier the extra
    /// collection binding is skipped and the identifier is used directly (avoiding
    /// an evaluation and a copy). Range-based `for` does NOT come here; it stays a
    /// native iterator node (see [`Parser.parseForStmt`]).
    fn desugarCollectionForIn(self: *Parser, name: []const u8, iterable: ast.Expression, body: ast.Statement, sp: ast.Span) ParserError!ast.Statement {
        const n = self.for_counter;
        self.for_counter += 1;
        const fi = try std.fmt.allocPrint(self.allocator, "__for_idx_{d}", .{n});

        const is_ident = iterable.kind == .ident;
        const fc = if (is_ident) iterable.kind.ident else try std.fmt.allocPrint(self.allocator, "__for_coll_{d}", .{n});
        const fc_let: ?ast.Statement = if (is_ident) null else ast.Statement{ .let_stmt = .{ .name = fc, .names = null, .type_name = null, .init = iterable, .is_const = false, .span = sp } };

        const fi_init = try self.allocStatement(ast.Statement{ .let_stmt = .{
            .name = fi,
            .names = null,
            .type_name = ast.TypeRef{ .ident = "int" },
            .init = ast.Expression{ .kind = .{ .literal = .{ .integer = 0 } } },
            .is_const = false,
            .span = sp,
        } });

        const size_call = try self.mkMethodCall(fc, "size", &.{}, sp);
        const cond = ast.Expression{ .kind = .{ .binary = .{
            .left = try self.allocExpression(.{ .kind = .{ .ident = fi } }),
            .op = .lt,
            .right = try self.allocExpression(size_call),
            .span = sp,
        } } };

        const add = try self.allocExpression(.{ .kind = .{ .binary = .{
            .left = try self.allocExpression(.{ .kind = .{ .ident = fi } }),
            .op = .add,
            .right = try self.allocExpression(.{ .kind = .{ .literal = .{ .integer = 1 } } }),
            .span = sp,
        } } });
        const incr = ast.Expression{ .kind = .{ .binary = .{
            .left = try self.allocExpression(.{ .kind = .{ .ident = fi } }),
            .op = .assign,
            .right = add,
            .span = sp,
        } } };

        const get_args = try self.allocator.alloc(ast.Expression, 1);
        get_args[0] = ast.Expression{ .kind = .{ .ident = fi } };
        const get_call = try self.mkMethodCall(fc, "at", get_args, sp);
        const x_let = ast.Statement{ .let_stmt = .{ .name = name, .names = null, .type_name = null, .init = get_call, .is_const = false, .span = sp } };

        const inner_stmts = try self.allocator.alloc(ast.Statement, 2);
        inner_stmts[0] = x_let;
        inner_stmts[1] = body;
        const inner_block = ast.Statement{ .block = .{ .statements = inner_stmts, .span = sp } };

        const for_stmt = ast.Statement{ .for_stmt = .{
            .initializer = fi_init,
            .condition = cond,
            .increment = incr,
            .iterator = null,
            .body = try self.allocStatement(inner_block),
            .span = sp,
        } };

        if (fc_let) |fcl| {
            const outer_stmts = try self.allocator.alloc(ast.Statement, 2);
            outer_stmts[0] = fcl;
            outer_stmts[1] = for_stmt;
            return ast.Statement{ .block = .{ .statements = outer_stmts, .span = sp } };
        }
        return for_stmt;
    }

    /// Lowers `for ((k, v) in map) body` into a keys-walk with a per-iteration
    /// value lookup.
    ///
    /// Emits (conceptually):
    /// ```
    /// let __for_map_N = map;                    // omitted when map is a bare ident
    /// let __for_keys_N = __for_map_N.keys();
    /// for (k in __for_keys_N) {                 // via desugarCollectionForIn
    ///     let v = __for_map_N.get(k);
    ///     body
    /// }
    /// ```
    /// The inner key loop is produced by [`Parser.desugarCollectionForIn`], so map
    /// iteration reduces to collection iteration plus a `get`. As there, a bare
    /// identifier map skips the intermediate binding.
    fn desugarMapForIn(self: *Parser, k_name: []const u8, v_name: []const u8, iterable: ast.Expression, body: ast.Statement, sp: ast.Span) ParserError!ast.Statement {
        const n = self.for_counter;
        self.for_counter += 1;
        const mk = try std.fmt.allocPrint(self.allocator, "__for_keys_{d}", .{n});

        const m_is_ident = iterable.kind == .ident;
        const m = if (m_is_ident) iterable.kind.ident else try std.fmt.allocPrint(self.allocator, "__for_map_{d}", .{n});
        const m_let: ?ast.Statement = if (m_is_ident) null else ast.Statement{ .let_stmt = .{ .name = m, .names = null, .type_name = null, .init = iterable, .is_const = false, .span = sp } };
        const keys_call = try self.mkMethodCall(m, "keys", &.{}, sp);
        const mk_let = ast.Statement{ .let_stmt = .{ .name = mk, .names = null, .type_name = null, .init = keys_call, .is_const = false, .span = sp } };

        const get_args = try self.allocator.alloc(ast.Expression, 1);
        get_args[0] = ast.Expression{ .kind = .{ .ident = k_name } };
        const get_call = try self.mkMethodCall(m, "get", get_args, sp);
        const v_let = ast.Statement{ .let_stmt = .{ .name = v_name, .names = null, .type_name = null, .init = get_call, .is_const = false, .span = sp } };
        const inner_stmts = try self.allocator.alloc(ast.Statement, 2);
        inner_stmts[0] = v_let;
        inner_stmts[1] = body;
        const inner_block = ast.Statement{ .block = .{ .statements = inner_stmts, .span = sp } };

        const loop = try self.desugarCollectionForIn(k_name, ast.Expression{ .kind = .{ .ident = mk } }, inner_block, sp);

        if (m_let) |ml| {
            const outer = try self.allocator.alloc(ast.Statement, 3);
            outer[0] = ml;
            outer[1] = mk_let;
            outer[2] = loop;
            return ast.Statement{ .block = .{ .statements = outer, .span = sp } };
        }
        const outer = try self.allocator.alloc(ast.Statement, 2);
        outer[0] = mk_let;
        outer[1] = loop;
        return ast.Statement{ .block = .{ .statements = outer, .span = sp } };
    }

    /// Parses every `for` form and routes each to its lowering.
    ///
    /// Disambiguates by lookahead inside the `for (...)` header:
    ///   - `((k, v) in map)` -> [`Parser.desugarMapForIn`];
    ///   - `(name in iterable)` -> a native range-iterator node when the iterable
    ///     is a range, otherwise [`Parser.desugarCollectionForIn`];
    ///   - the classic three-clause `(init; cond; incr)` -> a direct
    ///     [`ast.ForStmt`], where each clause is independently optional.
    /// The two `in` forms are detected purely by token pattern before committing,
    /// which is why the header peeks several tokens ahead.
    fn parseForStmt(self: *Parser) ParserError!ast.Statement {
        try self.expect(.keyword_for);
        try self.expect(.left_paren);

        if (self.current().type == .left_paren and self.pos + 5 < self.tokens.len and
            self.tokens[self.pos + 1].type == .identifier and
            self.tokens[self.pos + 2].type == .comma and
            self.tokens[self.pos + 3].type == .identifier and
            self.tokens[self.pos + 4].type == .right_paren and
            self.tokens[self.pos + 5].type == .identifier and
            std.mem.eql(u8, self.tokens[self.pos + 5].lexeme, "in"))
        {
            self.advance();
            const k_name = self.current().lexeme;
            self.advance();
            self.advance();
            const v_name = self.current().lexeme;
            self.advance();
            self.advance();
            self.advance();
            const iterable = try self.parseExpression();
            try self.expect(.right_paren);
            const body = try self.parseStatementOrBlock();
            return try self.desugarMapForIn(k_name, v_name, iterable, body, self.span());
        }

        if (self.current().type == .identifier and self.peek().type == .identifier and
            std.mem.eql(u8, self.peek().lexeme, "in"))
        {
            const name = self.current().lexeme;
            self.advance();
            self.advance();
            const iterable = try self.parseRangeOrExpr();
            try self.expect(.right_paren);
            const body = try self.parseStatementOrBlock();

            if (iterable.kind == .range) {
                return ast.Statement{ .for_stmt = .{
                    .initializer = null,
                    .condition = null,
                    .increment = null,
                    .iterator = ast.ForIterator{ .binding = .{ .item = name }, .iterable = try self.allocExpression(iterable) },
                    .body = try self.allocStatement(body),
                    .span = self.span(),
                } };
            }
            return try self.desugarCollectionForIn(name, iterable, body, self.span());
        }

        const _init = if (self.current().type == .keyword_let or self.current().type == .keyword_const) blk: {
            const is_const = self.current().type == .keyword_const;
            const stmt = try self.parseLetStmt(is_const);
            break :blk try self.allocStatement(ast.Statement{ .let_stmt = stmt });
        } else if (self.current().type != .semicolon) blk: {
            const expr = try self.parseExpression();
            try self.expect(.semicolon);
            break :blk try self.allocStatement(ast.Statement{ .expr_stmt = ast.ExprStmt{ .expr = expr, .span = self.span() } });
        } else blk: {
            try self.expect(.semicolon);
            break :blk null;
        };

        const cond = if (self.current().type != .semicolon) try self.parseExpression() else null;
        try self.expect(.semicolon);

        const incr = if (self.current().type != .right_paren) try self.parseExpression() else null;
        try self.expect(.right_paren);

        const body = try self.parseStatementOrBlock();
        return ast.Statement{ .for_stmt = .{
            .initializer = _init,
            .condition = cond,
            .increment = incr,
            .iterator = null,
            .body = try self.allocStatement(body),
            .span = self.span(),
        } };
    }

    /// Parses `switch (discr) { case v1, v2 [if guard]: { ... } default: { ... } }`.
    ///
    /// A `case` may list several comma-separated match values and carry an
    /// optional `if guard` predicate; its body is a braced block. A single
    /// `default:` block is captured separately and terminates the case loop (any
    /// cases written after it are not parsed). Each case body is boxed as a block
    /// statement.
    fn parseSwitchStmt(self: *Parser) ParserError!ast.SwitchStmt {
        try self.expect(.keyword_switch);
        try self.expect(.left_paren);
        const discr = try self.parseExpression();
        try self.expect(.right_paren);
        try self.expect(.left_brace);

        var cases = std.ArrayList(ast.SwitchCase).empty;
        defer cases.deinit(self.allocator);
        var default_case: ?*ast.Statement = null;

        while (self.current().type != .right_brace and self.current().type != .eof) {
            if (self.current().type == .keyword_default) {
                self.advance();
                try self.expect(.colon);
                const body = try self.parseBlock();
                default_case = try self.allocStatement(ast.Statement{ .block = body });
                break;
            }

            try self.expect(.keyword_case);
            var values = std.ArrayList(ast.Expression).empty;
            defer values.deinit(self.allocator);
            while (true) {
                try values.append(self.allocator, try self.parseExpression());
                if (!self.match(.comma)) break;
            }
            var guard: ?ast.Expression = null;
            if (self.current().type == .keyword_if) {
                self.advance();
                guard = try self.parseExpression();
            }
            try self.expect(.colon);
            const body = try self.parseBlock();
            try cases.append(self.allocator, ast.SwitchCase{
                .values = try values.toOwnedSlice(self.allocator),
                .guard = guard,
                .body = try self.allocStatement(ast.Statement{ .block = body }),
                .span = self.span(),
            });
        }

        try self.expect(.right_brace);
        return ast.SwitchStmt{
            .discriminant = discr,
            .cases = try cases.toOwnedSlice(self.allocator),
            .default_case = default_case,
            .span = self.span(),
        };
    }

    /// Parses `return [expr];`. A bare `return;` yields a null value; otherwise the
    /// expression before the required semicolon is the returned value.
    fn parseReturnStmt(self: *Parser) ParserError!ast.ReturnStmt {
        try self.expect(.keyword_return);
        const value = if (self.current().type != .semicolon) try self.parseExpression() else null;
        try self.expect(.semicolon);
        return ast.ReturnStmt{
            .value = value,
            .span = self.span(),
        };
    }

    /// Parses an expression used in statement position.
    ///
    /// A trailing semicolon is required for ordinary expressions but OPTIONAL when
    /// the expression is a JSX element, since `<div/>` at statement level reads
    /// cleanly without one. The span is taken at the start of the expression.
    fn parseExprStmt(self: *Parser) ParserError!ast.ExprStmt {
        const start = self.span();
        const expr = try self.parseExpression();
        if (expr.kind != .jsx_element) {
            try self.expect(.semicolon);
        } else {
            _ = self.match(.semicolon);
        }
        return ast.ExprStmt{
            .expr = expr,
            .span = start,
        };
    }

    /// The expression entry point. Starts the precedence chain at its loosest
    /// level, [`Parser.parseAssignment`].
    fn parseExpression(self: *Parser) ParserError!ast.Expression {
        return self.parseAssignment();
    }

    /// Parses assignment, the loosest expression level: plain `=`, compound
    /// `+= -= *= /= %= &= |= ^= <<= >>=`, and the postfix `catch` handler.
    ///
    /// Assignment is right-associative (recurses into itself on the right). A
    /// compound assignment `a op= b` is DESUGARED to `a = a op b`. The `catch`
    /// form `expr catch [(e)] handler` binds an error handler to the left
    /// expression, with an optional error binding name. This is where `catch`
    /// lives as an expression operator (contrast the removed `catch { }` statement
    /// rejected by [`Parser.rejectExceptions`]).
    fn parseAssignment(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseLogical();

        if (self.current().type == .keyword_catch) {
            self.advance();
            var err_name: ?[]const u8 = null;
            if (self.match(.left_paren)) {
                err_name = self.current().lexeme;
                try self.expect(.identifier);
                try self.expect(.right_paren);
            }
            const handler = try self.parseAssignment();
            left = ast.Expression{ .kind = .{ .catch_expr = .{
                .expr = try self.allocExpression(left),
                .err_name = err_name,
                .handler = try self.allocExpression(handler),
            } } };
        }

        if (self.match(.equal)) {
            const right = try self.parseAssignment();
            return ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                .left = try self.allocExpression(left),
                .op = .assign,
                .right = try self.allocExpression(right),
                .span = self.span(),
            } } };
        }

        const compound_op: ?ast.BinaryOp = switch (self.current().type) {
            .plus_equal => .add,
            .minus_equal => .sub,
            .star_equal => .mul,
            .slash_equal => .div,
            .percent_equal => .mod,
            .amp_equal => .bit_and,
            .pipe_equal => .bit_or,
            .caret_equal => .bit_xor,
            .shl_equal => .shl,
            .shr_equal => .shr,
            else => null,
        };

        if (compound_op) |op| {
            self.advance();
            const right = try self.parseAssignment();

            const add_expr = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                .left = try self.allocExpression(left),
                .op = op,
                .right = try self.allocExpression(right),
                .span = self.span(),
            } } };
            return ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                .left = try self.allocExpression(left),
                .op = .assign,
                .right = try self.allocExpression(add_expr),
                .span = self.span(),
            } } };
        }

        return left;
    }

    /// Parses logical operators and the ternary conditional, one level tighter
    /// than assignment.
    ///
    /// Left-folds `&&`, `||`, and the nullish-coalescing `??` (built from two
    /// adjacent `?` tokens, since the lexer does not produce a single `??`). After
    /// the logical chain, a trailing `? then : else` is parsed as a ternary
    /// [`ast.IfExpr`]. Operands come from [`Parser.parseBitwiseOr`].
    fn parseLogical(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseBitwiseOr();
        while (true) {
            if (self.current().type == .And) {
                self.advance();
                const right = try self.parseBitwiseOr();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .And,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else if (self.current().type == .Or) {
                self.advance();
                const right = try self.parseBitwiseOr();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .Or,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else if (self.current().type == .question and self.peek().type == .question) {
                self.advance();
                self.advance();
                const right = try self.parseBitwiseOr();
                left = ast.Expression{ .kind = .{ .nullish_coalesce = ast.NullishCoalesce{
                    .left = try self.allocExpression(left),
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }

        if (self.match(.question)) {
            const then_branch = try self.parseExpression();
            try self.expect(.colon);
            const else_branch = try self.parseExpression();
            left = ast.Expression{ .kind = .{ .if_expr = ast.IfExpr{
                .condition = try self.allocExpression(left),
                .then_branch = try self.allocExpression(then_branch),
                .else_branch = try self.allocExpression(else_branch),
                .span = self.span(),
            } } };
        }

        return left;
    }

    /// Parses bitwise-or `|`, left-folding over [`Parser.parseBitwiseXor`] operands.
    /// Note: in TYPE position `|` means a union/error tail (see [`Parser.parseTypeRef`]);
    /// here it is the value operator.
    fn parseBitwiseOr(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseBitwiseXor();
        while (true) {
            if (self.match(.pipe)) {
                const right = try self.parseBitwiseXor();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .bit_or,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses bitwise-xor `^`, left-folding over [`Parser.parseBitwiseAnd`] operands.
    fn parseBitwiseXor(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseBitwiseAnd();
        while (true) {
            if (self.match(.caret)) {
                const right = try self.parseBitwiseAnd();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .bit_xor,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses bitwise-and `&`, left-folding over [`Parser.parseEquality`] operands.
    /// A leading `&` is instead a borrow marker handled in [`Parser.parseUnary`];
    /// this level only sees `&` as an infix operator.
    fn parseBitwiseAnd(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseEquality();
        while (true) {
            if (self.match(.ampersand)) {
                const right = try self.parseEquality();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .bit_and,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses equality `==`/`!=`, left-folding over [`Parser.parseComparison`]
    /// operands.
    fn parseEquality(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseComparison();
        while (true) {
            if (self.current().type == .equal_equal) {
                self.advance();
                const right = try self.parseComparison();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .eq,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else if (self.current().type == .bang_equal) {
                self.advance();
                const right = try self.parseComparison();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = .ne,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses relational comparison `< > <= >=`, left-folding.
    ///
    /// Note the mild asymmetry: the left operand comes from [`Parser.parseShift`]
    /// but each right operand is parsed at [`Parser.parseAddSub`]. In practice this
    /// is fine because shift binds tighter than comparison and the loop re-reads
    /// the next operator, but it means a bare `a < b << c` associates the shift to
    /// the right operand as expected.
    fn parseComparison(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseShift();
        while (true) {
            const tok_type = self.current().type;
            const op: ?ast.BinaryOp = if (tok_type == .less) .lt else if (tok_type == .greater) .gt else if (tok_type == .less_equal) .le else if (tok_type == .greater_equal) .ge else null;
            if (op) |o| {
                self.advance();
                const right = try self.parseAddSub();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = o,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses bit-shift `<<`/`>>`, left-folding over [`Parser.parseAddSub`]
    /// operands. Sits between comparison and additive precedence.
    fn parseShift(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseAddSub();
        while (true) {
            const tok_type = self.current().type;
            const op: ?ast.BinaryOp = if (tok_type == .shl) .shl else if (tok_type == .shr) .shr else null;
            if (op) |o| {
                self.advance();
                const right = try self.parseAddSub();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = o,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses additive `+`/`-`, left-folding over [`Parser.parseMulDiv`] operands.
    fn parseAddSub(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseMulDiv();
        while (true) {
            const tok_type = self.current().type;
            const op: ?ast.BinaryOp = if (tok_type == .plus) .add else if (tok_type == .minus) .sub else null;
            if (op) |o| {
                self.advance();
                const right = try self.parseMulDiv();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = o,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses multiplicative `* / %`, the tightest binary level, left-folding over
    /// [`Parser.parseUnary`] operands.
    fn parseMulDiv(self: *Parser) ParserError!ast.Expression {
        var left = try self.parseUnary();
        while (true) {
            const tok_type = self.current().type;
            const op: ?ast.BinaryOp = if (tok_type == .star) .mul else if (tok_type == .slash) .div else if (tok_type == .percent) .mod else null;
            if (op) |o| {
                self.advance();
                const right = try self.parseUnary();
                left = ast.Expression{ .kind = .{ .binary = ast.BinaryExpr{
                    .left = try self.allocExpression(left),
                    .op = o,
                    .right = try self.allocExpression(right),
                    .span = self.span(),
                } } };
            } else {
                break;
            }
        }
        return left;
    }

    /// Parses prefix operators, right-recursive so they stack.
    ///
    /// Handles: `try expr` (an error-propagating unwrap) and its `try? expr`
    /// variant, which is desugared to `expr catch undefined` (swallow the error to
    /// an empty optional); `await expr`; `spawn expr` (fork, yielding a future);
    /// a prefix `&` borrow marker (consumed, operand returned as-is); numeric
    /// negation `-`, with a special case that folds `-` into a decimal literal so
    /// `-1.5` is one negative literal rather than a negate of a positive one;
    /// logical not `!`; and bitwise not `~`. With no prefix it falls through to
    /// [`Parser.parsePostfix`].
    fn parseUnary(self: *Parser) ParserError!ast.Expression {

        if (self.current().type == .keyword_try) {
            self.advance();
            if (self.match(.question)) {
                const operand = try self.parseUnary();
                const undef = try self.allocExpression(ast.Expression{ .kind = .{ .literal = .undefined } });
                return ast.Expression{ .kind = .{ .catch_expr = .{
                    .expr = try self.allocExpression(operand),
                    .err_name = null,
                    .handler = undef,
                } } };
            }
            const operand = try self.parseUnary();
            return ast.Expression{ .kind = .{ .try_expr = try self.allocExpression(operand) } };
        }

        if (self.current().type == .keyword_await) {
            const await_span = self.span();
            self.advance();
            const operand = try self.parseUnary();
            return ast.Expression{ .kind = .{ .await_expr = .{
                .operand = try self.allocExpression(operand),
                .span = await_span,
            } } };
        }
        if (self.current().type == .keyword_spawn) {
            const go_span = self.span();
            self.advance();
            const operand = try self.parseUnary();
            return ast.Expression{ .kind = .{ .go_expr = .{
                .operand = try self.allocExpression(operand),
                .span = go_span,
            } } };
        }
        if (self.current().type == .ampersand) {
            self.advance();
            return try self.parseUnary();
        }
        if (self.current().type == .minus) {
            self.advance();
            const operand = try self.parseUnary();

            if (operand.kind == .literal and operand.kind.literal == .decimal) {
                const neg = try std.fmt.allocPrint(self.allocator, "-{s}", .{operand.kind.literal.decimal});
                return ast.Expression{ .kind = .{ .literal = ast.Literal{ .decimal = neg } } };
            }
            return ast.Expression{ .kind = .{ .unary = ast.UnaryExpr{
                .op = .neg,
                .operand = try self.allocExpression(operand),
                .span = self.span(),
            } } };
        }
        if (self.current().type == .not) {
            self.advance();
            const operand = try self.parseUnary();
            return ast.Expression{ .kind = .{ .unary = ast.UnaryExpr{
                .op = .not,
                .operand = try self.allocExpression(operand),
                .span = self.span(),
            } } };
        }
        if (self.current().type == .tilde) {
            self.advance();
            const operand = try self.parseUnary();
            return ast.Expression{ .kind = .{ .unary = ast.UnaryExpr{
                .op = .bit_not,
                .operand = try self.allocExpression(operand),
                .span = self.span(),
            } } };
        }
        return self.parsePostfix();
    }

    /// Parses postfix operators that chain off a primary expression.
    ///
    /// Loops applying, in any order: call `(args)`; index `[expr]`; member access
    /// `.field`; tuple/positional access `.0`, lowered to an index expression;
    /// struct-literal `Name { field: v }` (or `expr.Field { ... }`);
    /// optional-chaining `?.field`; and the contextual cast `expr as Type`.
    ///
    /// The subtle case is a leading `<`: it may open a generic argument list
    /// (`Vec<int>(...)`, `Box<T> { ... }`, `obj.method<T>(...)`) OR be the
    /// less-than operator. It scans ahead balancing `<`/`>` (treating `>>` as
    /// closing two) and bailing at `;`/`{`/`}`, and only commits to a generic
    /// reading if the matching close is immediately followed by `.`, `{`, or `(`.
    /// Otherwise the `<` is left for [`Parser.parseComparison`]. Generic forms
    /// produce a `struct_init`, a `generic_call`, or a `generic_call` on a
    /// field-access callee depending on what follows the type arguments.
    fn parsePostfix(self: *Parser) ParserError!ast.Expression {
        var expr = try self.parsePrimary();

        while (true) {
            switch (self.current().type) {
                .less => {
                    var depth: usize = 1;
                    var look = self.pos + 1;
                    var is_generic = false;
                    while (look < self.tokens.len and depth > 0) {
                        const t = self.tokens[look];
                        if (t.type == .semicolon or t.type == .left_brace or t.type == .right_brace) {
                            break;
                        }
                        if (t.type == .less) depth += 1;
                        if (t.type == .greater) depth -= 1;
                        if (t.type == .shr) depth = if (depth >= 2) depth - 2 else 0;
                        look += 1;
                    }
                    if (depth == 0 and look < self.tokens.len and
                        (self.tokens[look].type == .dot or
                         self.tokens[look].type == .left_brace or
                         self.tokens[look].type == .left_paren)) {
                        is_generic = true;
                    }

                    if (is_generic) {
                        self.advance();
                        var type_args = std.ArrayList(ast.TypeRef).empty;
                        defer type_args.deinit(self.allocator);
                        while (true) {
                            try type_args.append(self.allocator, try self.parseTypeRef());
                            if (!self.match(.comma)) break;
                        }
                        try self.expectGenericClose();

                        if (self.current().type == .left_brace) {
                            self.advance();
                            var fields = std.ArrayList(ast.ObjectFieldInit).empty;
                            defer fields.deinit(self.allocator);
                            if (self.current().type != .right_brace) {
                                while (true) {
                                    const f_name = self.current().lexeme;
                                    try self.expect(.identifier);
                                    try self.expect(.colon);
                                    const val = try self.parseExpression();
                                    try fields.append(self.allocator, ast.ObjectFieldInit{
                                        .name = f_name,
                                        .value = val,
                                        .span = self.span(),
                                    });
                                    if (!self.match(.comma)) break;
                                    if (self.current().type == .right_brace) break;
                                }
                            }
                            try self.expect(.right_brace);

                            const type_name = switch (expr.kind) {
                                .ident => |id| id,
                                else => return error.UnexpectedToken,
                            };
                            expr = ast.Expression{ .kind = .{ .struct_init = ast.StructInit{
                                .type_name = type_name,
                                .fields = try fields.toOwnedSlice(self.allocator),
                                .type_args = try type_args.toOwnedSlice(self.allocator),
                                .span = self.span(),
                            } } };
                        } else if (self.current().type == .left_paren) {
                            self.advance();
                            var args = std.ArrayList(ast.Expression).empty;
                            defer args.deinit(self.allocator);
                            if (self.current().type != .right_paren) {
                                while (true) {
                                    try args.append(self.allocator, try self.parseExpression());
                                    if (!self.match(.comma)) break;
                                }
                            }
                            try self.expect(.right_paren);

                            expr = ast.Expression{ .kind = .{ .generic_call = ast.GenericCallExpr{
                                .callee = try self.allocExpression(expr),
                                .type_args = try type_args.toOwnedSlice(self.allocator),
                                .args = try args.toOwnedSlice(self.allocator),
                                .span = self.span(),
                            } } };
                        } else {
                            try self.expect(.dot);

                            const field = self.current().lexeme;
                            try self.expect(.identifier);

                            expr = ast.Expression{ .kind = .{ .field_access = ast.FieldAccess{
                                .object = try self.allocExpression(expr),
                                .field = field,
                                .span = self.span(),
                            } } };

                            try self.expect(.left_paren);
                            var args = std.ArrayList(ast.Expression).empty;
                            defer args.deinit(self.allocator);
                            if (self.current().type != .right_paren) {
                                while (true) {
                                    try args.append(self.allocator, try self.parseExpression());
                                    if (!self.match(.comma)) break;
                                }
                            }
                            try self.expect(.right_paren);

                            expr = ast.Expression{ .kind = .{ .generic_call = ast.GenericCallExpr{
                                .callee = try self.allocExpression(expr),
                                .type_args = try type_args.toOwnedSlice(self.allocator),
                                .args = try args.toOwnedSlice(self.allocator),
                                .span = self.span(),
                            } } };
                        }
                    } else {
                        break;
                    }
                },
                .left_paren => {
                    self.advance();
                    var args = std.ArrayList(ast.Expression).empty;
                    defer args.deinit(self.allocator);
                    if (self.current().type != .right_paren) {
                        while (true) {
                            try args.append(self.allocator, try self.parseExpression());
                            if (!self.match(.comma)) break;
                        }
                    }
                    try self.expect(.right_paren);
                    expr = ast.Expression{ .kind = .{ .call = ast.CallExpr{
                        .callee = try self.allocExpression(expr),
                        .args = try args.toOwnedSlice(self.allocator),
                        .span = self.span(),
                    } } };
                },
                .left_bracket => {
                    self.advance();
                    const index = try self.parseExpression();
                    try self.expect(.right_bracket);
                    expr = ast.Expression{ .kind = .{ .index = ast.IndexExpr{
                        .object = try self.allocExpression(expr),
                        .index = try self.allocExpression(index),
                        .span = self.span(),
                    } } };
                },
                .dot => {
                    self.advance();
                    if (self.current().type == .integer) {
                        const n = try self.parseIntLexeme(self.current());
                        const sp = self.span();
                        self.advance();
                        const idx_lit = ast.Expression{ .kind = .{ .literal = .{ .integer = n } }, .span = sp };
                        expr = ast.Expression{ .kind = .{ .index = ast.IndexExpr{
                            .object = try self.allocExpression(expr),
                            .index = try self.allocExpression(idx_lit),
                            .span = sp,
                        } } };
                    } else {
                        const field = self.current().lexeme;
                        try self.expect(.identifier);
                        expr = ast.Expression{ .kind = .{ .field_access = ast.FieldAccess{
                            .object = try self.allocExpression(expr),
                            .field = field,
                            .span = self.span(),
                        } } };
                    }
                },
                .left_brace => {
                    self.advance();
                    var fields = std.ArrayList(ast.ObjectFieldInit).empty;
                    defer fields.deinit(self.allocator);
                    if (self.current().type != .right_brace) {
                        while (true) {
                            const f_name = self.current().lexeme;
                            try self.expect(.identifier);
                            try self.expect(.colon);
                            const val = try self.parseExpression();
                            try fields.append(self.allocator, ast.ObjectFieldInit{
                                .name = f_name,
                                .value = val,
                                .span = self.span(),
                            });
                            if (!self.match(.comma)) break;
                            if (self.current().type == .right_brace) break;
                        }
                    }
                    try self.expect(.right_brace);

                    const type_name = switch (expr.kind) {
                        .ident => |id| id,
                        .field_access => |fa| fa.field,
                        else => return error.UnexpectedToken,
                    };

                    expr = ast.Expression{ .kind = .{ .struct_init = ast.StructInit{
                        .type_name = type_name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                        .span = self.span(),
                    } } };
                },
                .question => {
                    if (self.peek().type == .dot) {
                        self.advance();
                        self.advance();
                        const field = self.current().lexeme;
                        try self.expect(.identifier);
                        expr = ast.Expression{ .kind = .{ .optional_chaining = ast.OptionalChaining{
                            .object = try self.allocExpression(expr),
                            .field = field,
                            .span = self.span(),
                        } } };
                    } else {
                        break;
                    }
                },
                .identifier => {
                    if (std.mem.eql(u8, self.current().lexeme, "as")) {
                        self.advance();
                        const target_type = try self.parseTypeRef();
                        expr = ast.Expression{ .kind = .{ .cast = ast.CastExpr{
                            .expr = try self.allocExpression(expr),
                            .target_type = target_type,
                            .span = self.span(),
                        } } };
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }

        return expr;
    }

    /// Reads a JSX attribute name, splicing adjacent tokens that the lexer split
    /// but that form one hyphenated/namespaced attribute.
    ///
    /// JSX attribute names such as `data-on-click`, `xmlns:xlink`, or `@click`
    /// contain characters (`-`, `:`, `.`, `@`) the lexer tokenises separately. To
    /// rebuild the original spelling, this concatenates the lexemes of tokens that
    /// are physically ADJACENT (same line, and each starts exactly where the
    /// previous ended, checked via line/column arithmetic) and are valid
    /// name-continuation characters. Any gap or non-continuation token ends the
    /// name. Returns the assembled buffer (arena-backed).
    fn parseJsxAttrName(self: *Parser) ParserError![]const u8 {
        const first = self.current();
        const ok_start = first.type == .at or first.type == .colon or
            (first.lexeme.len > 0 and (std.ascii.isAlphabetic(first.lexeme[0]) or first.lexeme[0] == '_'));
        if (!ok_start) return error.UnexpectedToken;
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(self.allocator, first.lexeme);
        var last = first;
        self.advance();
        while (true) {
            const t = self.current();
            if (t.line != last.line) break;
            if (@as(usize, t.column) != @as(usize, last.column) + last.lexeme.len) break;
            const cont = t.type == .minus or t.type == .colon or t.type == .dot or t.type == .at or
                (t.lexeme.len > 0 and (std.ascii.isAlphanumeric(t.lexeme[0]) or t.lexeme[0] == '_'));
            if (!cont) break;
            try buf.appendSlice(self.allocator, t.lexeme);
            last = t;
            self.advance();
        }
        return buf.items;
    }

    /// Parses a JSX/NSX element `<tag attrs>children</tag>` (or self-closing
    /// `<tag/>`) into a [`ast.JsxElement`] expression.
    ///
    /// Attributes are parsed via [`Parser.parseJsxAttrName`] and take a string
    /// literal, a `{expr}` value, or nothing (boolean-style, stored as empty
    /// string). The self-closing form is recognised either as a single
    /// `jsx_self_close` token or as `/` followed by `>`. For a non-self-closing
    /// element, children are read until the matching close tag: nested `<...>`
    /// recurse; a `{ ... }` child is parsed as a statement when it begins with a
    /// statement keyword, else as an expression; and any run of adjacent text
    /// tokens is coalesced into a single text child, inserting a single space
    /// wherever the original tokens were not physically adjacent. A close tag whose
    /// name does not match the open tag errors, as does EOF before the close.
    fn parseJsxElement(self: *Parser) ParserError!ast.Expression {
        const start_span = self.span();
        try self.expect(.less);
        var tag: []const u8 = "";
        if (self.current().type == .identifier) {
            tag = self.current().lexeme;
            self.advance();
        }

        var attributes = std.ArrayList(ast.JsxAttribute).empty;
        defer attributes.deinit(self.allocator);

        while (self.current().type != .greater and self.current().type != .jsx_self_close and self.current().type != .eof) {
            if (self.current().type == .slash and self.peek().type == .greater) {
                break;
            }
            const attr_name = try self.parseJsxAttrName();
            var val: ast.JsxAttributeValue = undefined;
            if (self.current().type == .equal) {
                self.advance();
                if (self.current().type == .string) {
                    val = ast.JsxAttributeValue{ .string_literal = self.current().lexeme };
                    self.advance();
                } else if (self.match(.left_brace)) {
                    const expr = try self.parseExpression();
                    try self.expect(.right_brace);
                    val = ast.JsxAttributeValue{ .expression = expr };
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                val = ast.JsxAttributeValue{ .string_literal = "" };
            }
            try attributes.append(self.allocator, ast.JsxAttribute{
                .name = attr_name,
                .value = val,
                .span = self.span(),
            });
        }

        var is_self_closing = false;
        if (self.match(.jsx_self_close) or (self.match(.slash) and self.match(.greater))) {
            is_self_closing = true;
        } else {
            try self.expect(.greater);
        }

        var children = std.ArrayList(ast.JsxChild).empty;
        defer children.deinit(self.allocator);

        if (!is_self_closing) {
            while (true) {
                if (self.current().type == .jsx_close or (self.current().type == .less and self.peek().type == .slash)) {
                    if (self.current().type == .jsx_close) {
                        self.advance();
                    } else {
                        self.advance();
                        self.advance();
                    }
                    if (tag.len > 0) {
                        const end_tag = self.current().lexeme;
                        try self.expect(.identifier);
                        if (!std.mem.eql(u8, end_tag, tag)) {
                            return error.UnexpectedToken;
                        }
                    }
                    try self.expect(.greater);
                    break;
                }

                if (self.current().type == .eof) {
                    return error.UnexpectedToken;
                }

                if (self.current().type == .less) {
                    const child_el = try self.parseJsxElement();
                    try children.append(self.allocator, ast.JsxChild{ .element = child_el.kind.jsx_element });
                } else if (self.match(.left_brace)) {
                    const next_token = self.current();
                    var is_stmt = false;
                    switch (next_token.type) {
                        .keyword_let, .keyword_var, .keyword_const,
                        .keyword_if, .keyword_while, .keyword_for,
                        .keyword_switch, .keyword_return, .keyword_try,
                        .keyword_throw, .keyword_defer, .keyword_errdefer => {
                            is_stmt = true;
                        },
                        else => {},
                    }
                    if (is_stmt) {
                        const child_stmt = try self.parseStatement();
                        try self.expect(.right_brace);
                        try children.append(self.allocator, ast.JsxChild{ .statement = child_stmt });
                    } else {
                        const child_expr = try self.parseExpression();
                        try self.expect(.right_brace);
                        try children.append(self.allocator, ast.JsxChild{ .expression = child_expr });
                    }
                } else {
                    var buf = std.ArrayList(u8).empty;
                    var prev_end_line: usize = 0;
                    var prev_end_col: usize = 0;
                    var first = true;
                    while (true) {
                        const t = self.current();
                        if (t.type == .less or t.type == .jsx_close or t.type == .left_brace or
                            t.type == .greater or t.type == .eof) break;
                        if (!first and (@as(usize, t.line) != prev_end_line or @as(usize, t.column) != prev_end_col)) {
                            try buf.append(self.allocator, ' ');
                        }
                        try buf.appendSlice(self.allocator, t.lexeme);
                        prev_end_line = @as(usize, t.line);
                        prev_end_col = @as(usize, t.column) + t.lexeme.len;
                        first = false;
                        self.advance();
                    }
                    try children.append(self.allocator, ast.JsxChild{ .text = buf.items });
                }
            }
        }

        return ast.Expression{ .kind = .{ .jsx_element = ast.JsxElement{
            .tag = tag,
            .attributes = try attributes.toOwnedSlice(self.allocator),
            .children = try children.toOwnedSlice(self.allocator),
            .span = start_span,
        } } };
    }

    /// Parses a primary expression: the atoms at the bottom of the precedence
    /// chain.
    ///
    /// Dispatches on the leading token to produce: a JSX element (leading `<`);
    /// an `if cond [then] a else b` expression form; the `@Cast(Type, value)`
    /// built-in cast (leading `@`); literals (int/float/decimal/string/bool/char);
    /// template and interpolated strings; a parenthesised expression that may be a
    /// grouping, a tuple, or an arrow closure `(params) => body` (chosen by
    /// scanning for a `=>` after the balanced `)`); array and array-repeat
    /// literals `[a, b]` / `[v; N]`; object literals `{ k: v }`; the `undefined`
    /// and `null` sentinels; a struct-init `Name { ... }`; and bare identifiers.
    /// An unrecognised leading token prints a diagnostic and errors.
    fn parsePrimary(self: *Parser) ParserError!ast.Expression {
        if (self.current().type == .less) {
            return try self.parseJsxElement();
        }

        switch (self.current().type) {
            .keyword_if => {
                self.advance();
                var cond: ast.Expression = undefined;
                if (self.match(.left_paren)) {
                    cond = try self.parseExpression();
                    try self.expect(.right_paren);
                } else {
                    cond = try self.parseExpression();
                }
                if (self.current().type == .identifier and std.mem.eql(u8, self.current().lexeme, "then")) {
                    self.advance();
                }
                const then_branch = try self.parseExpression();
                try self.expect(.keyword_else);
                const else_branch = try self.parseExpression();
                return ast.Expression{ .kind = .{ .if_expr = ast.IfExpr{
                    .condition = try self.allocExpression(cond),
                    .then_branch = try self.allocExpression(then_branch),
                    .else_branch = try self.allocExpression(else_branch),
                    .span = self.span(),
                } } };
            },
            .at => {
                self.advance();
                try self.expect(.identifier);
                try self.expect(.left_paren);

                const target_type = try self.parseTypeRef();
                try self.expect(.comma);

                const val = try self.parseExpression();
                try self.expect(.right_paren);

                return ast.Expression{ .kind = .{ .cast = ast.CastExpr{
                    .expr = try self.allocExpression(val),
                    .target_type = target_type,
                    .span = self.span(),
                } } };
            },
            .integer, .float, .decimal, .string, .bool_true, .bool_false, .char_literal => {
                const lit = try self.parseLiteral();
                return ast.Expression{ .kind = .{ .literal = lit } };
            },
            .template_string => {
                const token = self.current();
                self.advance();
                return try self.parseTemplateString(token.lexeme);
            },
            .interpolated_string => {
                const token = self.current();
                self.advance();
                return try self.parseInterpolatedString(token.lexeme);
            },
            .left_paren => {
                var paren_depth: usize = 1;
                var look_pos = self.pos + 1;
                var is_arrow = false;
                while (look_pos < self.tokens.len and paren_depth > 0) {
                    const tok = self.tokens[look_pos];
                    if (tok.type == .left_paren) paren_depth += 1;
                    if (tok.type == .right_paren) paren_depth -= 1;
                    look_pos += 1;
                }
                if (look_pos < self.tokens.len and self.tokens[look_pos].type == .fat_arrow) {
                    is_arrow = true;
                }

                if (is_arrow) {
                    self.advance();
                    var params = std.ArrayList([]const u8).empty;
                    defer params.deinit(self.allocator);

                    var param_types = std.ArrayList(?ast.TypeRef).empty;
                    defer param_types.deinit(self.allocator);
                    if (self.current().type != .right_paren) {
                        while (true) {
                            const name = self.current().lexeme;
                            try self.expect(.identifier);
                            const ptype: ?ast.TypeRef = if (self.match(.colon)) try self.parseTypeRef() else null;
                            try params.append(self.allocator, name);
                            try param_types.append(self.allocator, ptype);
                            if (!self.match(.comma)) break;
                        }
                    }
                    try self.expect(.right_paren);
                    try self.expect(.fat_arrow);

                    if (self.current().type == .left_brace) {
                        const block = try self.parseBlock();
                        return ast.Expression{ .kind = .{ .closure = ast.Closure{
                            .params = try params.toOwnedSlice(self.allocator),
                            .param_types = try param_types.toOwnedSlice(self.allocator),
                            .body = .{ .block = block },
                            .span = self.span(),
                        }} };
                    } else {
                        const expr = try self.parseExpression();
                        const expr_ptr = try self.allocator.create(ast.Expression);
                        expr_ptr.* = expr;
                        return ast.Expression{ .kind = .{ .closure = ast.Closure{
                            .params = try params.toOwnedSlice(self.allocator),
                            .param_types = try param_types.toOwnedSlice(self.allocator),
                            .body = .{ .expr = expr_ptr },
                            .span = self.span(),
                        }} };
                    }
                } else {
                    self.advance();
                    var items = std.ArrayList(ast.Expression).empty;
                    defer items.deinit(self.allocator);
                    var has_comma = false;
                    if (self.current().type != .right_paren) {
                        while (true) {
                            try items.append(self.allocator, try self.parseExpression());
                            if (self.match(.comma)) {
                                has_comma = true;
                                if (self.current().type == .right_paren) break;
                            } else {
                                break;
                            }
                        }
                    }
                    try self.expect(.right_paren);
                    if (items.items.len == 1 and !has_comma) {
                        return items.items[0];
                    } else {
                        return ast.Expression{ .kind = .{ .tuple = try items.toOwnedSlice(self.allocator) } };
                    }
                }
            },
            .left_bracket => {
                self.advance();
                var elems = std.ArrayList(ast.Expression).empty;
                defer elems.deinit(self.allocator);
                if (self.current().type != .right_bracket) {
                    const first = try self.parseExpression();
                    if (self.current().type == .semicolon) {
                        self.advance();
                        const count_expr = try self.parseExpression();
                        try self.expect(.right_bracket);
                        const n = intLiteralOf(count_expr) orelse {
                            std.debug.print("Parser error: {s}:{}:{}: array repeat count must be a constant non-negative integer literal, e.g. [0.0; 256]\n", .{ self.file_path, self.current().line, self.current().column });
                            return error.UnexpectedToken;
                        };
                        const vptr = try self.allocExpression(first);
                        return ast.Expression{ .kind = .{ .literal = ast.Literal{ .array_repeat = .{ .value = vptr, .count = n } } } };
                    }
                    try elems.append(self.allocator, first);
                    while (self.match(.comma)) {
                        if (self.current().type == .right_bracket) break;
                        try elems.append(self.allocator, try self.parseExpression());
                    }
                }
                try self.expect(.right_bracket);
                return ast.Expression{ .kind = .{ .literal = ast.Literal{ .array = try elems.toOwnedSlice(self.allocator) } } };
            },
            .left_brace => {
                self.advance();
                var fields = std.ArrayList(ast.ObjectFieldInit).empty;
                defer fields.deinit(self.allocator);
                if (self.current().type != .right_brace) {
                    while (true) {
                        if (self.current().type == .right_brace) break;
                        const name = self.current().lexeme;
                        try self.expect(.identifier);
                        try self.expect(.colon);
                        const value = try self.parseExpression();
                        try fields.append(self.allocator, ast.ObjectFieldInit{
                            .name = name,
                            .value = value,
                            .span = self.span(),
                        });
                        if (self.current().type == .comma) {
                            self.advance();
                            if (self.current().type == .right_brace) break;
                        }
                    }
                }
                try self.expect(.right_brace);
                return ast.Expression{ .kind = .{ .literal = ast.Literal{ .object = try fields.toOwnedSlice(self.allocator) } } };
            },
            .identifier, .keyword_fn => {
                const name = self.current().lexeme;
                const ident_span = self.span();
                self.advance();

                if (std.mem.eql(u8, name, "undefined")) {
                    return ast.Expression{ .kind = .{ .literal = .undefined } };
                }
                if (std.mem.eql(u8, name, "null")) {
                    return ast.Expression{ .kind = .{ .literal = .null } };
                }

                if (self.current().type == .left_brace) {
                    self.advance();
                    var fields = std.ArrayList(ast.ObjectFieldInit).empty;
                    defer fields.deinit(self.allocator);
                    while (self.current().type != .right_brace) {
                        const fname = self.current().lexeme;
                        try self.expect(.identifier);
                        try self.expect(.colon);
                        const value = try self.parseExpression();
                        try fields.append(self.allocator, ast.ObjectFieldInit{
                            .name = fname,
                            .value = value,
                            .span = self.span(),
                        });
                        if (self.current().type == .comma) {
                            self.advance();
                            if (self.current().type == .right_brace) break;
                        }
                    }
                    try self.expect(.right_brace);
                    return ast.Expression{ .kind = .{ .struct_init = ast.StructInit{
                        .type_name = name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                        .span = self.span(),
                    } } };
                }

                return ast.Expression{ .kind = .{ .ident = name }, .span = ident_span };
            },
            else => {
                std.debug.print("Unexpected token: type={}, lexeme='{s}' at line {}, col {}\n", .{self.current().type, self.current().lexeme, self.current().line, self.current().column});
                return error.UnexpectedToken;
            },
        }
    }

    /// Parses an integer literal token into an `i64`, honouring base prefixes and
    /// full 64-bit range.
    ///
    /// Recognises `0x`/`0b`/`0o` prefixes (parsed as `u64` then bit-cast to `i64`,
    /// so `0xFFFFFFFFFFFFFFFF` is representable as `-1`); otherwise base-10. The
    /// exact value `9223372036854775808` (i64::MAX + 1) is special-cased so it can
    /// be the operand of a later unary minus to spell `i64::MIN`. Out-of-range or
    /// unparseable literals go through [`Parser.intOutOfRange`].
    fn parseIntLexeme(self: *Parser, token: lexer.Token) ParserError!i64 {
        const lexeme = token.lexeme;
        if (lexeme.len > 2 and lexeme[0] == '0') {
            const base: u8 = switch (lexeme[1]) {
                'x', 'X' => 16,
                'b', 'B' => 2,
                'o', 'O' => 8,
                else => 0,
            };
            if (base != 0) {
                const u = std.fmt.parseInt(u64, lexeme[2..], base) catch return self.intOutOfRange(token);
                return @bitCast(u);
            }
        }
        if (std.fmt.parseInt(i64, lexeme, 10)) |v| {
            return v;
        } else |_| {
            if (std.mem.eql(u8, lexeme, "9223372036854775808")) return @bitCast(@as(u64, 9223372036854775808));
            return self.intOutOfRange(token);
        }
    }

    /// Prints an out-of-range diagnostic for an integer literal and returns
    /// `error.UnexpectedToken`.
    ///
    /// The return type is the error itself (not an error union), so callers write
    /// `return self.intOutOfRange(token)` at a point where only failure is
    /// possible. Message states the valid i64 decimal range and the unsigned
    /// hex/bin/oct ceiling.
    fn intOutOfRange(self: *Parser, token: lexer.Token) ParserError {
        std.debug.print(
            "Parser error: {s}:{}:{}: integer literal '{s}' is out of range for a 64-bit integer (i64: -9223372036854775808..9223372036854775807; hex/bin/oct up to 0xFFFFFFFFFFFFFFFF).\n",
            .{ self.file_path, token.line, token.column, token.lexeme },
        );
        return error.UnexpectedToken;
    }

    /// Parses a scalar literal token into an [`ast.Literal`].
    ///
    /// Integers go through [`Parser.parseIntLexeme`]; floats parse to `f64`
    /// (falling back to `0.0` on a malformed lexeme rather than erroring);
    /// decimals keep their textual lexeme (exact decimal type); strings borrow the
    /// lexeme; booleans map directly. A char literal is decoded to its integer
    /// code point: surrounding quotes are stripped and a leading `\` escape
    /// (`\n \r \t \\ \' \" \0`) is resolved, otherwise the first byte is taken.
    /// Any other token type degrades to a `null` literal.
    fn parseLiteral(self: *Parser) ParserError!ast.Literal {
        const token = self.current();
        self.advance();
        return switch (token.type) {
            .integer => ast.Literal{ .integer = try self.parseIntLexeme(token) },
            .float => ast.Literal{ .float = std.fmt.parseFloat(f64, token.lexeme) catch 0.0 },
            .decimal => ast.Literal{ .decimal = token.lexeme },
            .string => ast.Literal{ .string = token.lexeme },
            .bool_true => ast.Literal{ .bool = true },
            .bool_false => ast.Literal{ .bool = false },
            .char_literal => {
                var lexeme = token.lexeme;
                if (lexeme.len >= 2 and lexeme[0] == '\'') {
                    lexeme = lexeme[1 .. lexeme.len - 1];
                }
                var val: i64 = 0;
                if (lexeme.len > 0) {
                    if (lexeme[0] == '\\' and lexeme.len > 1) {
                        val = switch (lexeme[1]) {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            '\\' => '\\',
                            '\'' => '\'',
                            '\"' => '\"',
                            '0' => 0,
                            else => lexeme[1],
                        };
                    } else {
                        val = lexeme[0];
                    }
                }
                return ast.Literal{ .integer = val };
            },
            else => ast.Literal{ .null = {} },
        };
    }

    /// Parses a backtick template string ``` `text ${expr} more` ``` into a
    /// [`ast.TemplateExpr`] of alternating literal and embedded-code parts.
    ///
    /// The raw inner text is scanned for `${ ... }` holes (brace-depth balanced so
    /// nested braces inside an interpolation are handled). Literal runs between
    /// holes become string-literal parts (duped into the arena). Each hole's source
    /// is re-parsed with a FRESH nested [`Parser`] over just that fragment: if the
    /// fragment looks like statements (starts with `for`/`while`/`switch`/`let` or
    /// contains a `;`) it is parsed as a statement sequence wrapped in a
    /// `block_expr`, otherwise as a single expression. An unterminated `${` is kept
    /// as literal text. Shares its structure with
    /// [`Parser.parseInterpolatedString`]; the only difference is the `${`
    /// vs `{` hole delimiter.
    fn parseTemplateString(self: *Parser, lexeme: []const u8) ParserError!ast.Expression {
        var parts = std.ArrayList(ast.Expression).empty;
        defer parts.deinit(self.allocator);

        var current_pos: usize = 0;
        while (current_pos < lexeme.len) {
            var found_start: ?usize = null;
            var i: usize = current_pos;
            while (i < lexeme.len - 1) {
                if (lexeme[i] == '$' and lexeme[i + 1] == '{') {
                    found_start = i;
                    break;
                }
                i += 1;
            }

            if (found_start) |start_idx| {
                if (start_idx > current_pos) {
                    const lit_text = lexeme[current_pos..start_idx];
                    const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                    parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                }

                var brace_depth: i32 = 1;
                var end_idx: ?usize = null;
                var j: usize = start_idx + 2;
                while (j < lexeme.len) {
                    if (lexeme[j] == '{') {
                        brace_depth += 1;
                    } else if (lexeme[j] == '}') {
                        brace_depth -= 1;
                        if (brace_depth == 0) {
                            end_idx = j;
                            break;
                        }
                    }
                    j += 1;
                }

                if (end_idx) |close_idx| {
                    const sub_source = lexeme[start_idx + 2 .. close_idx];
                    var sub_parser = Parser.init(self.allocator, sub_source, self.file_path, self.is_wasm) catch return error.OutOfMemory;

                    const trimmed = std.mem.trim(u8, sub_source, " \t\r\n");
                    const is_stmt = blk: {
                        if (std.mem.startsWith(u8, trimmed, "for") or
                            std.mem.startsWith(u8, trimmed, "while") or
                            std.mem.startsWith(u8, trimmed, "switch") or
                            std.mem.startsWith(u8, trimmed, "let") or
                            std.mem.indexOfScalar(u8, trimmed, ';') != null) {
                            break :blk true;
                        }
                        break :blk false;
                    };

                    const sub_expr = if (is_stmt) blk: {
                        var stmts = std.ArrayList(ast.Statement).empty;
                        defer stmts.deinit(self.allocator);
                        while (sub_parser.pos < sub_parser.tokens.len and sub_parser.current().type != .eof) {
                            const stmt = sub_parser.parseStatement() catch return error.UnexpectedToken;
                            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
                        }
                        break :blk ast.Expression{ .kind = .{ .block_expr = ast.Block{
                            .statements = stmts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                            .span = self.span(),
                        } } };
                    } else sub_parser.parseExpression() catch return error.UnexpectedToken;

                    parts.append(self.allocator, sub_expr) catch return error.OutOfMemory;
                    current_pos = close_idx + 1;
                } else {
                    const lit_text = lexeme[start_idx..];
                    const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                    parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                    current_pos = lexeme.len;
                }
            } else {
                const lit_text = lexeme[current_pos..];
                const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                current_pos = lexeme.len;
            }
        }

        return ast.Expression{ .kind = .{ .template_expr = ast.TemplateExpr{
            .parts = parts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .span = self.span(),
        } } };
    }

    /// Parses an interpolated string with bare `{ ... }` holes into a
    /// [`ast.TemplateExpr`].
    ///
    /// Identical in structure to [`Parser.parseTemplateString`] but the hole
    /// delimiter is a single `{` rather than `${`: literal runs, brace-balanced
    /// hole extraction, per-hole nested parsing (statement block vs expression by
    /// the same heuristic), and unterminated-hole-as-literal handling all match.
    fn parseInterpolatedString(self: *Parser, lexeme: []const u8) ParserError!ast.Expression {
        var parts = std.ArrayList(ast.Expression).empty;
        defer parts.deinit(self.allocator);

        var current_pos: usize = 0;
        while (current_pos < lexeme.len) {
            var found_start: ?usize = null;
            var i: usize = current_pos;
            while (i < lexeme.len) {
                if (lexeme[i] == '{') {
                    found_start = i;
                    break;
                }
                i += 1;
            }

            if (found_start) |start_idx| {
                if (start_idx > current_pos) {
                    const lit_text = lexeme[current_pos..start_idx];
                    const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                    parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                }

                var brace_depth: i32 = 1;
                var end_idx: ?usize = null;
                var j: usize = start_idx + 1;
                while (j < lexeme.len) {
                    if (lexeme[j] == '{') {
                        brace_depth += 1;
                    } else if (lexeme[j] == '}') {
                        brace_depth -= 1;
                        if (brace_depth == 0) {
                            end_idx = j;
                            break;
                        }
                    }
                    j += 1;
                }

                if (end_idx) |close_idx| {
                    const sub_source = lexeme[start_idx + 1 .. close_idx];
                    var sub_parser = Parser.init(self.allocator, sub_source, self.file_path, self.is_wasm) catch return error.OutOfMemory;

                    const trimmed = std.mem.trim(u8, sub_source, " \t\r\n");
                    const is_stmt = blk: {
                        if (std.mem.startsWith(u8, trimmed, "for") or
                            std.mem.startsWith(u8, trimmed, "while") or
                            std.mem.startsWith(u8, trimmed, "switch") or
                            std.mem.startsWith(u8, trimmed, "let") or
                            std.mem.indexOfScalar(u8, trimmed, ';') != null) {
                            break :blk true;
                        }
                        break :blk false;
                    };

                    const sub_expr = if (is_stmt) blk: {
                        var stmts = std.ArrayList(ast.Statement).empty;
                        defer stmts.deinit(self.allocator);
                        while (sub_parser.pos < sub_parser.tokens.len and sub_parser.current().type != .eof) {
                            const stmt = sub_parser.parseStatement() catch return error.UnexpectedToken;
                            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
                        }
                        break :blk ast.Expression{ .kind = .{ .block_expr = ast.Block{
                            .statements = stmts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                            .span = self.span(),
                        } } };
                    } else sub_parser.parseExpression() catch return error.UnexpectedToken;

                    parts.append(self.allocator, sub_expr) catch return error.OutOfMemory;
                    current_pos = close_idx + 1;
                } else {
                    const lit_text = lexeme[start_idx..];
                    const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                    parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                    current_pos = lexeme.len;
                }
            } else {
                const lit_text = lexeme[current_pos..];
                const lit_expr = ast.Expression{ .kind = .{ .literal = .{ .string = self.allocator.dupe(u8, lit_text) catch return error.OutOfMemory } } };
                parts.append(self.allocator, lit_expr) catch return error.OutOfMemory;
                current_pos = lexeme.len;
            }
        }

        return ast.Expression{ .kind = .{ .template_expr = ast.TemplateExpr{
            .parts = parts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .span = self.span(),
        } } };
    }
};
