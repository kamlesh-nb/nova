
const std = @import("std");

pub const TokenType = enum {
    keyword_fn,
    keyword_async,
    keyword_await,
    keyword_spawn,
    keyword_extern,
    keyword_struct,
    keyword_import,
    keyword_trait,
    keyword_impl,
    keyword_return,
    keyword_let,
    keyword_defer,
    keyword_errdefer,
    keyword_break,
    keyword_continue,
    keyword_if,
    keyword_else,
    keyword_while,
    keyword_for,
    keyword_switch,
    keyword_case,
    keyword_default,
    keyword_try,
    keyword_catch,
    keyword_throw,
    keyword_match,
    keyword_const,
    keyword_export,
    keyword_enum,
    keyword_pub,
    keyword_var,
    keyword_union,
    identifier,

    integer,
    float,
    decimal,
    string,
    template_string,
    interpolated_string,
    bool_true,
    bool_false,
    plus,
    minus,
    star,
    slash,
    equal,
    equal_equal,
    bang_equal,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    percent_equal,
    amp_equal,
    pipe_equal,
    caret_equal,
    shl_equal,
    shr_equal,
    less,
    greater,
    shl,
    shr,
    less_equal,
    greater_equal,
    And,
    Or,
    not,
    colon,
    semicolon,
    comma,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    arrow,
    dot,
    dot_dot,
    dot_dot_eq,
    pipe,
    ampersand,
    caret,
    tilde,
    percent,
    jsx_close,
    jsx_self_close,
    eof,
    question,
    at,
    ellipsis,
    fat_arrow,
    char_literal,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    column: usize,

    tok_start: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();
        self.tok_start = self.pos;
        if (self.pos >= self.source.len) {
            return Token{ .type = .eof, .lexeme = "", .line = self.line, .column = self.column };
        }

        const char = self.source[self.pos];
        switch (char) {
            'a'...'z', 'A'...'Z', '_' => return self.readIdentifier(),
            '0'...'9' => return self.readNumber(),
            '"' => return self.readString(),
            '`' => return self.readTemplateString(),
            '$' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '"') {
                    self.pos += 2;
                    self.column += 2;
                    return self.readInterpolatedString();
                }
                std.debug.print("Unexpected character: {c}\n", .{char});
                self.pos += 1;
                self.column += 1;
                return self.nextToken();
            },
            '+' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .plus_equal, .lexeme = "+=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .plus, .lexeme = "+", .line = self.line, .column = self.column - 1 };
            },
            '-' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .arrow, .lexeme = "->", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .minus_equal, .lexeme = "-=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .minus, .lexeme = "-", .line = self.line, .column = self.column - 1 };
            },
            '*' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .star_equal, .lexeme = "*=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .star, .lexeme = "*", .line = self.line, .column = self.column - 1 };
            },
            '/' => {
                self.pos += 1;
                self.column += 1;

                if (self.pos < self.source.len and self.source[self.pos] == '/') {

                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.pos += 1;
                        self.column += 1;
                    }
                    return self.nextToken();
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .slash_equal, .lexeme = "/=", .line = self.line, .column = self.column - 2 };
                }

                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .jsx_self_close, .lexeme = "/>", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .slash, .lexeme = "/", .line = self.line, .column = self.column - 1 };
            },
            '=' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .equal_equal, .lexeme = "==", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .fat_arrow, .lexeme = "=>", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .equal, .lexeme = "=", .line = self.line, .column = self.column - 1 };
            },
            '!' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .bang_equal, .lexeme = "!=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .not, .lexeme = "!", .line = self.line, .column = self.column - 1 };
            },
            '<' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '/') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .jsx_close, .lexeme = "</", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .less_equal, .lexeme = "<=", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '<') {
                    self.pos += 1;
                    self.column += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        return Token{ .type = .shl_equal, .lexeme = "<<=", .line = self.line, .column = self.column - 3 };
                    }
                    return Token{ .type = .shl, .lexeme = "<<", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .less, .lexeme = "<", .line = self.line, .column = self.column - 1 };
            },
            '>' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .greater_equal, .lexeme = ">=", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    self.column += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        return Token{ .type = .shr_equal, .lexeme = ">>=", .line = self.line, .column = self.column - 3 };
                    }
                    return Token{ .type = .shr, .lexeme = ">>", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .greater, .lexeme = ">", .line = self.line, .column = self.column - 1 };
            },
            ':' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .colon, .lexeme = ":", .line = self.line, .column = self.column - 1 };
            },
            ';' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .semicolon, .lexeme = ";", .line = self.line, .column = self.column - 1 };
            },
            ',' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .comma, .lexeme = ",", .line = self.line, .column = self.column - 1 };
            },
            '(' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .left_paren, .lexeme = "(", .line = self.line, .column = self.column - 1 };
            },
            ')' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .right_paren, .lexeme = ")", .line = self.line, .column = self.column - 1 };
            },
            '{' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .left_brace, .lexeme = "{", .line = self.line, .column = self.column - 1 };
            },
            '}' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .right_brace, .lexeme = "}", .line = self.line, .column = self.column - 1 };
            },
            '[' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .left_bracket, .lexeme = "[", .line = self.line, .column = self.column - 1 };
            },
            ']' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .right_bracket, .lexeme = "]", .line = self.line, .column = self.column - 1 };
            },
            '.' => {
                self.pos += 1;
                self.column += 1;

                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
                    self.pos += 2;
                    self.column += 2;
                    return Token{ .type = .ellipsis, .lexeme = "...", .line = self.line, .column = self.column - 3 };
                }

                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    self.column += 2;
                    return Token{ .type = .dot_dot_eq, .lexeme = "..=", .line = self.line, .column = self.column - 3 };
                }

                if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .dot_dot, .lexeme = "..", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .dot, .lexeme = ".", .line = self.line, .column = self.column - 1 };
            },
            '|' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '|') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .Or, .lexeme = "||", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .pipe_equal, .lexeme = "|=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .pipe, .lexeme = "|", .line = self.line, .column = self.column - 1 };
            },
            '&' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '&') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .And, .lexeme = "&&", .line = self.line, .column = self.column - 2 };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .amp_equal, .lexeme = "&=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .ampersand, .lexeme = "&", .line = self.line, .column = self.column - 1 };
            },
            '^' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .caret_equal, .lexeme = "^=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .caret, .lexeme = "^", .line = self.line, .column = self.column - 1 };
            },
            '~' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .tilde, .lexeme = "~", .line = self.line, .column = self.column - 1 };
            },
            '%' => {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    return Token{ .type = .percent_equal, .lexeme = "%=", .line = self.line, .column = self.column - 2 };
                }
                return Token{ .type = .percent, .lexeme = "%", .line = self.line, .column = self.column - 1 };
            },
            '?' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .question, .lexeme = "?", .line = self.line, .column = self.column - 1 };
            },
            '@' => {
                self.pos += 1;
                self.column += 1;
                return Token{ .type = .at, .lexeme = "@", .line = self.line, .column = self.column - 1 };
            },
            '\'' => {
                const start = self.pos;
                self.pos += 1;
                self.column += 1;
                while (self.pos < self.source.len and self.source[self.pos] != '\'') {
                    if (self.source[self.pos] == '\\') {
                        self.pos += 2;
                        self.column += 2;
                    } else {
                        self.pos += 1;
                        self.column += 1;
                    }
                }
                if (self.pos < self.source.len) {
                    self.pos += 1;
                    self.column += 1;
                }
                return Token{ .type = .char_literal, .lexeme = self.source[start..self.pos], .line = self.line, .column = self.column - (self.pos - start) };
            },
            else => {
                std.debug.print("Unexpected character: {c}\n", .{char});
                self.pos += 1;
                self.column += 1;
                return self.nextToken();
            },
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\r', '\t' => {
                    self.pos += 1;
                    self.column += 1;
                },
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.column = 1;
                },
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {

                        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                            self.pos += 1;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.source.len and
            (self.source[self.pos] >= 'a' and self.source[self.pos] <= 'z' or
                self.source[self.pos] >= 'A' and self.source[self.pos] <= 'Z' or
                self.source[self.pos] >= '0' and self.source[self.pos] <= '9' or
                self.source[self.pos] == '_'))
        {
            self.pos += 1;
            self.column += 1;
        }
        const lexeme = self.source[start..self.pos];
        const types = tokenTypeFromKeyword(lexeme);
        return Token{ .type = types, .lexeme = lexeme, .line = self.line, .column = self.column - lexeme.len };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.source.len and
            self.source[self.pos] >= '0' and self.source[self.pos] <= '9')
        {
            self.pos += 1;
            self.column += 1;
        }
        var is_float = false;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and self.source[self.pos + 1] >= '0' and self.source[self.pos + 1] <= '9') {
                self.pos += 1;
                self.column += 1;
                while (self.pos < self.source.len and
                    self.source[self.pos] >= '0' and self.source[self.pos] <= '9')
                {
                    self.pos += 1;
                    self.column += 1;
                }
                is_float = true;
            }
        }
        const num_end = self.pos;

        var is_decimal = false;
        if (self.pos < self.source.len and (self.source[self.pos] == 'm' or self.source[self.pos] == 'M')) {
            const after = self.pos + 1;
            const boundary = after >= self.source.len or !isIdentChar(self.source[after]);
            if (boundary) {
                self.pos += 1;
                self.column += 1;
                is_decimal = true;
            }
        }
        const lexeme = self.source[start..num_end];
        const tt: TokenType = if (is_decimal) .decimal else if (is_float) .float else .integer;
        return Token{ .type = tt, .lexeme = lexeme, .line = self.line, .column = self.column - (self.pos - start) };
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    fn readString(self: *Lexer) Token {
        self.pos += 1;
        self.column += 1;
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.pos += 2;
                self.column += 2;
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        const lexeme = self.source[start..self.pos];
        self.pos += 1;
        self.column += 1;
        return Token{ .type = .string, .lexeme = lexeme, .line = self.line, .column = self.column - lexeme.len - 2 };
    }

    fn readTemplateString(self: *Lexer) Token {
        self.pos += 1;
        self.column += 1;
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '`') {
            if (self.source[self.pos] == '\\') {
                self.pos += 2;
                self.column += 2;
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        const lexeme = self.source[start..self.pos];
        self.pos += 1;
        self.column += 1;
        return Token{ .type = .template_string, .lexeme = lexeme, .line = self.line, .column = self.column - lexeme.len - 2 };
    }

    fn readInterpolatedString(self: *Lexer) Token {
        const start = self.pos;
        var brace_level: usize = 0;
        var in_expr = false;

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (in_expr) {
                if (c == '{') {
                    brace_level += 1;
                    self.pos += 1;
                    self.column += 1;
                } else if (c == '}') {
                    brace_level -= 1;
                    self.pos += 1;
                    self.column += 1;
                    if (brace_level == 0) {
                        in_expr = false;
                    }
                } else if (c == '"') {
                    self.pos += 1;
                    self.column += 1;
                    while (self.pos < self.source.len and self.source[self.pos] != '"') {
                        if (self.source[self.pos] == '\\') {
                            self.pos += 2;
                            self.column += 2;
                        } else {
                            self.pos += 1;
                            self.column += 1;
                        }
                    }
                    if (self.pos < self.source.len) {
                        self.pos += 1;
                        self.column += 1;
                    }
                } else if (c == '\n') {
                    self.pos += 1;
                    self.line += 1;
                    self.column = 1;
                } else {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                if (c == '"') {
                    break;
                } else if (c == '{') {
                    in_expr = true;
                    brace_level = 1;
                    self.pos += 1;
                    self.column += 1;
                } else if (c == '\\') {
                    self.pos += 2;
                    self.column += 2;
                } else if (c == '\n') {
                    self.pos += 1;
                    self.line += 1;
                    self.column = 1;
                } else {
                    self.pos += 1;
                    self.column += 1;
                }
            }
        }

        const lexeme = self.source[start..self.pos];
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.column += 1;
        }
        return Token{ .type = .interpolated_string, .lexeme = lexeme, .line = self.line, .column = self.column - lexeme.len - 3 };
    }
};

fn tokenTypeFromKeyword(lexeme: []const u8) TokenType {
    if (std.mem.eql(u8, lexeme, "fn")) return .keyword_fn;
    if (std.mem.eql(u8, lexeme, "async")) return .keyword_async;
    if (std.mem.eql(u8, lexeme, "await")) return .keyword_await;
    if (std.mem.eql(u8, lexeme, "spawn")) return .keyword_spawn;
    if (std.mem.eql(u8, lexeme, "extern")) return .keyword_extern;
    if (std.mem.eql(u8, lexeme, "struct")) return .keyword_struct;
    if (std.mem.eql(u8, lexeme, "import")) return .keyword_import;
    if (std.mem.eql(u8, lexeme, "trait")) return .keyword_trait;
    if (std.mem.eql(u8, lexeme, "impl")) return .keyword_impl;
    if (std.mem.eql(u8, lexeme, "return")) return .keyword_return;
    if (std.mem.eql(u8, lexeme, "let")) return .keyword_let;
    if (std.mem.eql(u8, lexeme, "defer")) return .keyword_defer;
    if (std.mem.eql(u8, lexeme, "errdefer")) return .keyword_errdefer;
    if (std.mem.eql(u8, lexeme, "break")) return .keyword_break;
    if (std.mem.eql(u8, lexeme, "continue")) return .keyword_continue;
    if (std.mem.eql(u8, lexeme, "if")) return .keyword_if;
    if (std.mem.eql(u8, lexeme, "else")) return .keyword_else;
    if (std.mem.eql(u8, lexeme, "while")) return .keyword_while;
    if (std.mem.eql(u8, lexeme, "for")) return .keyword_for;
    if (std.mem.eql(u8, lexeme, "switch")) return .keyword_switch;
    if (std.mem.eql(u8, lexeme, "case")) return .keyword_case;
    if (std.mem.eql(u8, lexeme, "default")) return .keyword_default;
    if (std.mem.eql(u8, lexeme, "try")) return .keyword_try;
    if (std.mem.eql(u8, lexeme, "catch")) return .keyword_catch;
    if (std.mem.eql(u8, lexeme, "throw")) return .keyword_throw;

    if (std.mem.eql(u8, lexeme, "match")) return .keyword_match;
    if (std.mem.eql(u8, lexeme, "true")) return .bool_true;
    if (std.mem.eql(u8, lexeme, "false")) return .bool_false;
    if (std.mem.eql(u8, lexeme, "export")) return .keyword_export;
    if (std.mem.eql(u8, lexeme, "const")) return .keyword_const;
    if (std.mem.eql(u8, lexeme, "enum")) return .keyword_enum;
    if (std.mem.eql(u8, lexeme, "pub")) return .keyword_pub;
    if (std.mem.eql(u8, lexeme, "var")) return .keyword_var;
    if (std.mem.eql(u8, lexeme, "union")) return .keyword_union;

    return .identifier;
}
