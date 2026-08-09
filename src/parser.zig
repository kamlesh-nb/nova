
const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const ParserError = error{
    UnexpectedToken,
    ExpectedToken,
    OutOfMemory,
};

// A compile-time non-negative integer literal, for the `[value; count]` array-repeat count.
fn intLiteralOf(e: ast.Expression) ?usize {
    switch (e.kind) {
        .literal => |lit| switch (lit) {
            .integer => |v| return if (v >= 0) @intCast(v) else null,
            else => return null,
        },
        else => return null,
    }
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []lexer.Token,
    pos: usize,
    file_path: []const u8,
    is_wasm: bool,
    source: []const u8,

    for_counter: usize = 0,

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

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
    }

    fn current(self: *Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    fn peek(self: *Parser) lexer.Token {
        if (self.pos + 1 < self.tokens.len) return self.tokens[self.pos + 1];
        return self.tokens[self.tokens.len - 1];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

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

    fn expectGenericClose(self: *Parser) ParserError!void {
        if (self.current().type == .shr) {
            self.tokens[self.pos].type = .greater;
            self.tokens[self.pos].lexeme = ">";
            return;
        }
        return self.expect(.greater);
    }

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

    fn allocStatement(self: *Parser, value: ast.Statement) !*ast.Statement {
        const ptr = try self.allocator.create(ast.Statement);
        ptr.* = value;
        return ptr;
    }

    fn allocExpression(self: *Parser, value: ast.Expression) !*ast.Expression {
        const ptr = try self.allocator.create(ast.Expression);
        ptr.* = value;
        return ptr;
    }

    fn parseStatementOrBlock(self: *Parser) ParserError!ast.Statement {
        if (self.current().type == .left_brace) {
            return ast.Statement{ .block = try self.parseBlock() };
        } else {
            return try self.parseStatement();
        }
    }

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

        return ast.Program{
            .declarations = try declarations.toOwnedSlice(self.allocator),
            .span = self.span(),
        };
    }

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
            .keyword_struct => {
                var sd = try self.parseStructDecl(is_public);
                sd.attributes = attrs;
                return ast.Declaration{ .struct_decl = sd };
            },
            .keyword_union => {
                const ud = try self.parseUnionDecl(is_public);
                return ast.Declaration{ .union_decl = ud };
            },
            .keyword_enum => {
                self.advance(); // consume 'enum'
                var ed = try self.parseEnumDecl(false);
                ed.attributes = attrs;
                return ast.Declaration{ .enum_decl = ed };
            },
            // `exception` is a contextual keyword: at declaration position `exception Name { ... }`
            // parses like an enum but is marked as an exception (sema then requires describe()).
            // Everywhere else `exception` is an ordinary identifier (e.g. the `exception` module),
            // so `import exception;` and variables named `exception` are unaffected.
            .identifier => {
                if (std.mem.eql(u8, self.current().lexeme, "exception")) {
                    self.advance(); // consume contextual 'exception'
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

    fn import_decl_fallback(self: *Parser) ParserError!ast.ImportDecl {
        return try self.parseImportDecl();
    }

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

    fn parseFunctionDecl(self: *Parser, is_exported: bool) ParserError!ast.FunctionDecl {
        const start_span = self.span();
        const is_async = self.match(.keyword_async);
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
        const body = try self.parseBlock();

        const end_span = self.span();
        return ast.FunctionDecl{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .ret_type = ret_type,
            .body = body,
            .is_exported = is_exported,
            .attributes = &.{},
            .type_params = try type_params.toOwnedSlice(self.allocator),
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

    fn parseStructDecl(self: *Parser, is_public: bool) ParserError!ast.StructDecl {
        const start_span = self.span();
        try self.expect(.keyword_struct);
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
                    .is_public = field_is_pub,
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

    // The leading keyword (`enum`) or the contextual `exception` identifier has already been consumed
    // by the caller. `is_exception` marks the result as an exception (an enum the compiler requires to
    // have a `describe(self): string` method).
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
                    .is_public = is_pub,
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
                        // Tuple-form variant with MULTIPLE payloads (`Rect(int, int)`): desugar to positional
                        // struct fields `_0`, `_1`, ... so it reuses the (working) multi-field payload
                        // construction and pattern paths. Single-payload `Circle(int)` keeps `type_name`.
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
            if (self.current().type == .semicolon) self.advance();

            try methods.append(self.allocator, ast.TraitMethodDecl{
                .name = fn_name,
                .params = try params.toOwnedSlice(self.allocator),
                .ret_type = ret_type,
                .is_async = m_is_async,
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
            // A path segment is normally an identifier, but a version directory may be a bare
            // integer (e.g. `import crypto.tls.13.tls;` -> crypto/tls/13/tls.nova).
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
                if (saw_undefined) {
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

        return base_type;
    }

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

    fn peekIsLeftBrace(self: *Parser) bool {
        return self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].type == .left_brace;
    }

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

    fn parseWhileStmt(self: *Parser) ParserError!ast.WhileStmt {
        try self.expect(.keyword_while);
        try self.expect(.left_paren);
        const cond = try self.parseExpression();
        try self.expect(.right_paren);
        const body = try self.parseStatementOrBlock();
        return ast.WhileStmt{
            .condition = cond,
            .body = try self.allocStatement(body),
            .span = self.span(),
        };
    }

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

    fn mkMethodCall(self: *Parser, recv: []const u8, method: []const u8, args: []ast.Expression, sp: ast.Span) ParserError!ast.Expression {
        const obj = try self.allocExpression(.{ .kind = .{ .ident = recv } });
        const callee = try self.allocExpression(.{ .kind = .{ .field_access = .{ .object = obj, .field = method, .span = sp } } });
        return ast.Expression{ .kind = .{ .call = .{ .callee = callee, .args = args, .span = sp } } };
    }

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
        const get_call = try self.mkMethodCall(fc, "get", get_args, sp);
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
            try self.expect(.colon);
            const body = try self.parseBlock();
            try cases.append(self.allocator, ast.SwitchCase{
                .values = try values.toOwnedSlice(self.allocator),
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

    fn parseReturnStmt(self: *Parser) ParserError!ast.ReturnStmt {
        try self.expect(.keyword_return);
        const value = if (self.current().type != .semicolon) try self.parseExpression() else null;
        try self.expect(.semicolon);
        return ast.ReturnStmt{
            .value = value,
            .span = self.span(),
        };
    }

    fn parseExprStmt(self: *Parser) ParserError!ast.ExprStmt {
        const expr = try self.parseExpression();
        if (expr.kind != .jsx_element) {
            try self.expect(.semicolon);
        } else {
            _ = self.match(.semicolon);
        }
        return ast.ExprStmt{
            .expr = expr,
            .span = self.span(),
        };
    }

    fn parseExpression(self: *Parser) ParserError!ast.Expression {
        return self.parseAssignment();
    }

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

    fn parseUnary(self: *Parser) ParserError!ast.Expression {

        if (self.current().type == .keyword_try) {
            self.advance();
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
                        // A type-argument list cannot contain a statement terminator or a block brace.
                        // If one appears before the matching `>`, this `<` is a comparison, not a
                        // generic, and we must stop here rather than run on to a later `>>` (which the
                        // depth logic below would treat as a close). Without this, `while (i < len) {`
                        // followed later by an expression like `x >> (…)` was misparsed as a generic
                        // call. Parentheses are NOT bailed on, because a type argument may be a function
                        // type such as `Map<string, (int) -> any>`.
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
                                // F4-1: keep the explicit `<...>` args (was dropped here) so sema can
                                // bind + validate them. toOwnedSlice empties the list, so the defer
                                // deinit above is a no-op (same handoff the generic_call branch uses).
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
                    const field = self.current().lexeme;
                    try self.expect(.identifier);
                    expr = ast.Expression{ .kind = .{ .field_access = ast.FieldAccess{
                        .object = try self.allocExpression(expr),
                        .field = field,
                        .span = self.span(),
                    } } };
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

    // Parse an NSX attribute NAME, which may contain characters no single Nova token covers: hyphens
    // (`data-on-click`, `hx-get`), colons (`:class`), dots and double-underscores (Datastar modifiers like
    // `data-on-interval__duration.2s`), and a leading `@` (`@click`). The lexer splits these into several
    // tokens, so we reconstruct the name by taking the exact source span of the run of ADJACENT tokens
    // (no whitespace between them) that make up the name. Returns a slice into the original source.
    fn parseJsxAttrName(self: *Parser) ParserError![]const u8 {
        const first = self.current();
        const ok_start = first.type == .at or first.type == .colon or
            (first.lexeme.len > 0 and (std.ascii.isAlphabetic(first.lexeme[0]) or first.lexeme[0] == '_'));
        if (!ok_start) return error.UnexpectedToken;
        // Concatenate the lexemes of the adjacent run into a fresh buffer. We cannot take a source-span
        // slice here: punctuation tokens (`-`, `:`, `.`, `@`) carry STATIC string lexemes, not slices into
        // the source, so their addresses are unrelated to the surrounding identifier tokens.
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(self.allocator, first.lexeme);
        var last = first;
        self.advance();
        while (true) {
            const t = self.current();
            if (t.line != last.line) break;
            // adjacency: the next token must start exactly where the previous one ended (no space).
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

    fn parseJsxElement(self: *Parser) ParserError!ast.Expression {
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
                // Valueless boolean attribute (readonly, selected, checked, disabled, open, required...).
                // Emitted as name="" which HTML treats as present, so it round-trips correctly.
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
                    // Accumulate a RUN of text tokens into a single text child, preserving the spacing
                    // between words. The lexer drops whitespace and emits separate tokens ("Node",
                    // "information"), so joining lexemes directly would give "Nodeinformation". We insert a
                    // single space wherever the source had a gap between tokens (detected by column), which
                    // is exactly HTML's own whitespace-collapsing rule. Lexemes are used by value, since
                    // punctuation tokens carry static lexemes rather than source slices.
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
            .span = self.span(),
        } } };
    }

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
                    // `[value; count]` repeat-init: count must be a compile-time integer literal.
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

    // Parse an integer-literal lexeme, honoring a 0x/0b/0o radix prefix (decimal otherwise). The
    // radix forms are read as u64 and bit-cast to i64 so the whole 64-bit range is expressible (for
    // example 0xffffffffffffffff is -1), while a plain decimal keeps its signed base-10 value.
    // Parse an integer literal token to its 64-bit value. An out-of-range literal is a HARD ERROR, not a
    // silent 0 (the previous `catch 0` turned `9999999999999999999` into 0 -- silent data loss). Hex / binary
    // / octal literals keep their bit pattern up to u64 (so masks like `0xFFFFFFFFFFFFFFFF` work); a decimal
    // literal must fit signed i64, with the single exception of 2^63 (`9223372036854775808`), the magnitude
    // of i64 MIN, stored as its bit pattern so `-9223372036854775808` yields i64 MIN.
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

    fn intOutOfRange(self: *Parser, token: lexer.Token) ParserError {
        std.debug.print(
            "Parser error: {s}:{}:{}: integer literal '{s}' is out of range for a 64-bit integer (i64: -9223372036854775808..9223372036854775807; hex/bin/oct up to 0xFFFFFFFFFFFFFFFF).\n",
            .{ self.file_path, token.line, token.column, token.lexeme },
        );
        return error.UnexpectedToken;
    }

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
                        // A bare `${if (c) a else b}` is an if-EXPRESSION (it yields the interpolated value),
                        // so `if` is NOT treated as a statement here -- `parseExpression` handles it. A
                        // multi-statement body still routes to the block path via its `;`.
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
                        // A bare `${if (c) a else b}` is an if-EXPRESSION (it yields the interpolated value),
                        // so `if` is NOT treated as a statement here -- `parseExpression` handles it. A
                        // multi-statement body still routes to the block path via its `;`.
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
