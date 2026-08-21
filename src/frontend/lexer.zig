
//! Hand-written lexer: the first stage of the Nova compiler front end.
//!
//! This module turns raw Nova source text (a borrowed `[]const u8`) into a
//! forward stream of [`Token`]s that the parser pulls one at a time via
//! [`Lexer.nextToken`]. There is no separate token buffer: the lexer is a
//! pull-based scanner holding a cursor into the source, so a whole file is
//! never tokenised up front and the parser drives the pace.
//!
//! Design decisions and invariants worth knowing:
//!
//!   * **Zero-copy lexemes.** Every [`Token.lexeme`] is a sub-slice of the
//!     original `source`, never a fresh allocation. The lexer therefore needs
//!     no allocator, but a `Token` is only valid for as long as the source
//!     buffer it was cut from stays alive. String/template/interpolated tokens
//!     deliberately carry the *inner* text (the surrounding quotes/backticks
//!     are consumed but excluded from the lexeme); escape sequences are NOT
//!     decoded here, that is left to a later stage.
//!
//!   * **Line/column tracking.** `line` and `column` are maintained as the
//!     cursor advances so each `Token` can report a 1-based source position for
//!     diagnostics. Because a token's fields are filled in AFTER the cursor has
//!     already moved past the lexeme, every producer computes the start column
//!     by subtracting the consumed width back off the current `column` (hence
//!     the `- lexeme.len` / `- 2` / `- 3` adjustments dotted throughout).
//!
//!   * **Keywords are not lexed specially.** An identifier run is scanned
//!     first, then [`tokenTypeFromKeyword`] reclassifies it: any word matching
//!     a reserved spelling becomes its keyword token, everything else stays
//!     `.identifier`. This keeps the character switch small and the keyword set
//!     in one table.
//!
//!   * **Comments and whitespace are skipped, not emitted.** `//` line comments
//!     are dropped both in [`Lexer.skipWhitespace`] (leading run) and inline in
//!     the `/` branch of [`Lexer.nextToken`] (a comment discovered where an
//!     operator was expected), after which the lexer tail-recurses to fetch the
//!     next real token.
//!
//!   * **Error handling is lenient.** An unrecognised byte is reported to
//!     stderr and skipped, then lexing continues by tail-calling
//!     [`Lexer.nextToken`] again; the lexer never returns an error. It emits a
//!     terminating `.eof` token once the cursor reaches the end of source.
//!
//! The interpolated-string form (`$"...{expr}..."`) is the one construct the
//! lexer scans with real structure: it balances braces and skips nested string
//! literals so an embedded `}` inside a quoted string does not prematurely close
//! the interpolation. It still returns a single token whose lexeme is the raw
//! body; splitting text from expressions happens downstream.

const std = @import("std");

/// The full set of lexical token kinds Nova recognises.
///
/// Members fall into four groups: `keyword_*` reserved words (produced only via
/// [`tokenTypeFromKeyword`]), literal kinds ([`TokenType.integer`] ..
/// [`TokenType.char_literal`]), operators and punctuation, and the structural
/// sentinels [`TokenType.identifier`] and [`TokenType.eof`]. The names are the
/// contract the parser matches against, so the spelling of each variant is
/// load-bearing.
pub const TokenType = enum {
    /// The `fn` keyword introducing a function declaration.
    keyword_fn,
    /// The `async` modifier marking a coroutine-returning function.
    keyword_async,
    /// The `await` operator that joins on a pending future.
    keyword_await,
    /// The `spawn` keyword that forks a concurrent task returning a future.
    keyword_spawn,
    /// The `extern` keyword declaring a foreign (FFI) symbol.
    keyword_extern,
    /// The `struct` keyword introducing a value-semantic aggregate type.
    keyword_struct,
    /// The `class` keyword introducing a reference-semantic aggregate type.
    keyword_class,
    /// The `import` keyword pulling in another module.
    keyword_import,
    /// The `trait` keyword declaring an interface for dynamic dispatch.
    keyword_trait,
    /// The `impl` keyword attaching methods or a trait to a type.
    keyword_impl,
    /// The `return` statement keyword.
    keyword_return,
    /// The `let` keyword binding an immutable local.
    keyword_let,
    /// The `defer` keyword scheduling cleanup at scope exit.
    keyword_defer,
    /// The `errdefer` keyword scheduling cleanup only on an error unwind.
    keyword_errdefer,
    /// The `break` loop-exit keyword.
    keyword_break,
    /// The `continue` loop-restart keyword.
    keyword_continue,
    /// The `if` conditional keyword.
    keyword_if,
    /// The `else` conditional-alternative keyword.
    keyword_else,
    /// The `while` loop keyword.
    keyword_while,
    /// The `for` loop keyword.
    keyword_for,
    /// The `switch` multi-way branch keyword.
    keyword_switch,
    /// The `case` keyword labelling a `switch`/`match` arm.
    keyword_case,
    /// The `default` keyword for the fallthrough arm of a `switch`.
    keyword_default,
    /// The `try` keyword propagating an error result.
    keyword_try,
    /// The `catch` keyword handling an error result.
    keyword_catch,
    /// The `throw` keyword raising an error.
    keyword_throw,
    /// The `match` keyword for pattern matching.
    keyword_match,
    /// The `const` keyword binding a compile-time/module-level constant.
    keyword_const,
    /// The `export` keyword marking a declaration for external visibility.
    keyword_export,
    /// The `enum` keyword introducing a tagged-union/enumeration type.
    keyword_enum,
    /// The `pub` visibility modifier.
    keyword_pub,
    /// The `var` keyword. Retained as a reserved word even though mutable
    /// `var` bindings were removed from the language.
    keyword_var,
    /// The `union` keyword introducing an untagged union type.
    keyword_union,
    /// A user identifier: the default classification for any word that is not a
    /// reserved keyword. See [`tokenTypeFromKeyword`].
    identifier,

    /// An integer literal (decimal, or `0x`/`0o`/`0b` prefixed); `_` digit
    /// separators are permitted inside the run.
    integer,
    /// A floating-point literal (has a fractional part and/or an exponent).
    float,
    /// A fixed-point `decimal` literal, distinguished from a float by a trailing
    /// `m`/`M` suffix at an identifier boundary.
    decimal,
    /// A double-quoted string literal; the lexeme is the inner text, quotes
    /// stripped and escapes left undecoded.
    string,
    /// A backtick-delimited template string; lexeme is the inner text.
    template_string,
    /// A `$"..."` interpolated string carrying embedded `{expr}` holes; lexeme
    /// is the raw body. See [`Lexer.readInterpolatedString`].
    interpolated_string,
    /// The boolean literal `true`.
    bool_true,
    /// The boolean literal `false`.
    bool_false,
    /// The `+` addition operator.
    plus,
    /// The `-` subtraction/negation operator.
    minus,
    /// The `*` multiplication operator.
    star,
    /// The `/` division operator.
    slash,
    /// The `=` assignment operator.
    equal,
    /// The `==` equality operator.
    equal_equal,
    /// The `!=` inequality operator.
    bang_equal,
    /// The `+=` compound-assignment operator.
    plus_equal,
    /// The `-=` compound-assignment operator.
    minus_equal,
    /// The `*=` compound-assignment operator.
    star_equal,
    /// The `/=` compound-assignment operator.
    slash_equal,
    /// The `%=` compound-assignment operator.
    percent_equal,
    /// The `&=` compound-assignment operator.
    amp_equal,
    /// The `|=` compound-assignment operator.
    pipe_equal,
    /// The `^=` compound-assignment operator.
    caret_equal,
    /// The `<<=` compound-assignment operator.
    shl_equal,
    /// The `>>=` compound-assignment operator.
    shr_equal,
    /// The `<` less-than operator.
    less,
    /// The `>` greater-than operator.
    greater,
    /// The `<<` left-shift operator.
    shl,
    /// The `>>` right-shift operator.
    shr,
    /// The `<=` less-than-or-equal operator.
    less_equal,
    /// The `>=` greater-than-or-equal operator.
    greater_equal,
    /// The `&&` logical-and operator (capitalised because `and` is a Zig
    /// keyword and cannot name a variant).
    And,
    /// The `||` logical-or operator (capitalised because `or` is a Zig keyword).
    Or,
    /// The `!` logical-not operator.
    not,
    /// The `:` colon (type annotations, labels).
    colon,
    /// The `;` statement terminator.
    semicolon,
    /// The `,` separator.
    comma,
    /// The `(` opening parenthesis.
    left_paren,
    /// The `)` closing parenthesis.
    right_paren,
    /// The `{` opening brace.
    left_brace,
    /// The `}` closing brace.
    right_brace,
    /// The `[` opening bracket.
    left_bracket,
    /// The `]` closing bracket.
    right_bracket,
    /// The `->` arrow (return-type / mapping).
    arrow,
    /// The `.` member-access / decimal-point operator.
    dot,
    /// The `..` exclusive range operator.
    dot_dot,
    /// The `..=` inclusive range operator.
    dot_dot_eq,
    /// The `|` bitwise-or / pattern-alternation operator.
    pipe,
    /// The `&` bitwise-and / address operator.
    ampersand,
    /// The `^` bitwise-xor operator.
    caret,
    /// The `~` bitwise-not operator.
    tilde,
    /// The `%` modulo operator.
    percent,
    /// The `</` JSX/NSX closing-tag opener.
    jsx_close,
    /// The `/>` JSX/NSX self-closing-tag terminator.
    jsx_self_close,
    /// End-of-source sentinel, emitted once the cursor passes the last byte.
    eof,
    /// The `?` optional / try-shorthand operator.
    question,
    /// The `@` attribute/builtin sigil.
    at,
    /// The `...` ellipsis (spread / variadic).
    ellipsis,
    /// The `=>` fat arrow (match/closure bodies).
    fat_arrow,
    /// A single-quoted character literal; the lexeme includes the surrounding
    /// quotes (unlike string literals, which strip them).
    char_literal,
};

/// A single lexed token: a classified slice of source plus its position.
///
/// The token owns nothing: [`Token.lexeme`] borrows from the source buffer, so
/// the token outlives nothing that buffer does not. Positions are 1-based and
/// point at the START of the lexeme, reconstructed by the producers in
/// [`Lexer`] after the cursor has already advanced.
pub const Token = struct {
    /// Which lexical category this token belongs to.
    type: TokenType,
    /// The exact source text of the token, as a borrowed sub-slice of the
    /// lexer's `source`. For quoted literals this is the INNER text (delimiters
    /// excluded); for `char_literal` the quotes are included.
    lexeme: []const u8,
    /// 1-based source line the lexeme starts on.
    line: usize,
    /// 1-based source column the lexeme starts on.
    column: usize,
};

/// The pull-based scanner: holds a cursor into the source and produces one
/// [`Token`] per call to [`Lexer.nextToken`].
///
/// Allocation-free by construction (every lexeme is a borrow). The lexer is a
/// mutable value threaded by pointer; the parser constructs one with
/// [`Lexer.init`] and calls [`Lexer.nextToken`] until it sees a `.eof` token.
pub const Lexer = struct {
    /// The full source buffer being scanned; every lexeme is a slice of this.
    source: []const u8,
    /// Byte offset of the cursor: the next unread position in `source`.
    pos: usize,
    /// Current 1-based line, incremented on each `\n` consumed.
    line: usize,
    /// Current 1-based column, reset to 1 after each newline and advanced per
    /// byte otherwise.
    column: usize,

    /// Byte offset where the token currently being scanned began, set at the
    /// top of [`Lexer.nextToken`] after whitespace is skipped. Recorded for
    /// callers that want the token's start; individual readers mostly track
    /// their own `start` local instead.
    tok_start: usize = 0,

    /// Creates a lexer positioned at the start of `source`.
    ///
    /// The returned lexer borrows `source`; it must outlive every [`Token`] the
    /// lexer emits. Line and column both start at 1.
    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    /// Scans and returns the next token, advancing the cursor past it.
    ///
    /// Leading whitespace and `//` line comments are skipped first via
    /// [`Lexer.skipWhitespace`]. If the cursor is at end of source, returns
    /// `.eof`. Otherwise it dispatches on the first byte: letters/`_` start an
    /// identifier or keyword ([`Lexer.readIdentifier`]), digits a number
    /// ([`Lexer.readNumber`]), `"`/`` ` ``/`$"` the string forms, and the rest
    /// is a punctuation/operator switch that greedily takes the longest match
    /// (e.g. `<<=` over `<<` over `<`).
    ///
    /// Two branches do NOT return a token directly but tail-recurse: a `//`
    /// comment discovered in the `/` branch, and any unrecognised byte (which
    /// is reported to stderr and skipped). The recursion means this function
    /// always yields a real token or `.eof`, never a comment or error.
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

    /// Advances the cursor past a run of insignificant characters.
    ///
    /// Consumes spaces, `\r`, `\t`, and newlines (updating `line`/`column`),
    /// and treats a `//` sequence as a comment: everything to the next newline
    /// is skipped. A lone `/` that is not followed by another `/` is an
    /// operator, so the function returns without consuming it, leaving
    /// [`Lexer.nextToken`] to lex the `/`. Stops at the first significant byte
    /// or end of source.
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

    /// Scans an identifier run and classifies it as a keyword or identifier.
    ///
    /// Consumes the maximal run of `[A-Za-z0-9_]` starting at the cursor (the
    /// caller has already checked the first byte is a letter or `_`, so a digit
    /// can never lead). The resulting word is passed through
    /// [`tokenTypeFromKeyword`], which returns the matching keyword token type
    /// or `.identifier`. The lexeme borrows the scanned slice; the start column
    /// is recovered as `column - lexeme.len`.
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

    /// Advances the cursor over a run of decimal digits with `_` separators.
    ///
    /// Consumes `0`-`9`, and a `_` only when it sits BETWEEN digits (the byte
    /// after it is also a digit), so a trailing or grouping-terminating `_` is
    /// left unconsumed rather than swallowed. Used by [`Lexer.readNumber`] for
    /// the integer part, the fractional part, and the exponent digits.
    fn scanDigitRun(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
                self.column += 1;
            } else if (c == '_' and self.pos + 1 < self.source.len and
                self.source[self.pos + 1] >= '0' and self.source[self.pos + 1] <= '9')
            {
                self.pos += 1;
                self.column += 1;
            } else break;
        }
    }

    /// Scans a numeric literal and decides whether it is integer, float, or
    /// decimal.
    ///
    /// First checks for a radix prefix (`0x`/`0X`, `0o`/`0O`, `0b`/`0B`): if
    /// present, the whole run is scanned with [`Lexer.isBaseDigit`] and returned
    /// as an `.integer` with no float/decimal interpretation. Otherwise it scans
    /// the decimal integer part, then optionally a `.` fractional part (only if
    /// a digit follows the dot, so `1.foo` keeps the `.` as a member access),
    /// then an optional `e`/`E` exponent (only if it is well-formed, so a stray
    /// `e` is left for the next token). Presence of either makes it a `.float`.
    ///
    /// Finally, a trailing `m`/`M` at an identifier boundary (nothing that could
    /// continue an identifier follows) promotes the token to `.decimal`. Note
    /// the returned lexeme runs to `num_end`, i.e. it EXCLUDES the `m`/`M`
    /// suffix even though the cursor has consumed it. The base-prefix path
    /// returns early and never reaches the float/decimal logic.
    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        if (self.source[self.pos] == '0' and self.pos + 1 < self.source.len) {
            const p = self.source[self.pos + 1];
            const base: u8 = switch (p) {
                'x', 'X' => 16,
                'b', 'B' => 2,
                'o', 'O' => 8,
                else => 0,
            };
            if (base != 0) {
                self.pos += 2;
                self.column += 2;
                while (self.pos < self.source.len and
                    (isBaseDigit(self.source[self.pos], base) or
                        (self.source[self.pos] == '_' and self.pos + 1 < self.source.len and isBaseDigit(self.source[self.pos + 1], base))))
                {
                    self.pos += 1;
                    self.column += 1;
                }
                const lexeme = self.source[start..self.pos];
                return Token{ .type = .integer, .lexeme = lexeme, .line = self.line, .column = self.column - (self.pos - start) };
            }
        }
        self.scanDigitRun();
        var is_float = false;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and self.source[self.pos + 1] >= '0' and self.source[self.pos + 1] <= '9') {
                self.pos += 1;
                self.column += 1;
                self.scanDigitRun();
                is_float = true;
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            var q = self.pos + 1;
            if (q < self.source.len and (self.source[q] == '+' or self.source[q] == '-')) q += 1;
            if (q < self.source.len and self.source[q] >= '0' and self.source[q] <= '9') {
                while (self.pos < q) : (self.pos += 1) self.column += 1;
                self.scanDigitRun();
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

    /// Reports whether `c` may appear inside an identifier (`[A-Za-z0-9_]`).
    ///
    /// Used by [`Lexer.readNumber`] to test the boundary after a `m`/`M`
    /// decimal suffix, so `1m` is a decimal but `1motorway` is not.
    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    /// Reports whether `c` is a valid digit in the given numeric `base`.
    ///
    /// Handles base 16 (`0-9a-fA-F`), 8 (`0-7`), and 2 (`0`/`1`); any other
    /// base falls back to decimal `0-9`. Drives the prefixed-integer scan in
    /// [`Lexer.readNumber`].
    fn isBaseDigit(c: u8, base: u8) bool {
        return switch (base) {
            16 => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
            8 => c >= '0' and c <= '7',
            2 => c == '0' or c == '1',
            else => c >= '0' and c <= '9',
        };
    }

    /// Scans a double-quoted string literal, returning its inner text.
    ///
    /// Assumes the cursor is on the opening `"`; consumes it, scans to the
    /// closing `"`, and consumes that too, but the returned lexeme spans ONLY
    /// the text between the quotes. A backslash escapes the next byte (both are
    /// skipped as a pair, so `\"` does not terminate the string), but escapes
    /// are NOT decoded here. The `- lexeme.len - 2` start-column adjustment
    /// accounts for the two consumed quote characters. An unterminated string
    /// runs to end of source without erroring.
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

    /// Scans a backtick-delimited template string, returning its inner text.
    ///
    /// Mirrors [`Lexer.readString`] but with `` ` `` as the delimiter: consumes
    /// the opening and closing backticks, returns the text between them, and
    /// treats `\` as escaping the following byte. Escapes are left undecoded.
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

    /// Scans a `$"..."` interpolated string into a single raw-body token.
    ///
    /// The caller ([`Lexer.nextToken`]) has already consumed the `$"` opener, so
    /// the cursor is on the first body byte. This scanner walks the body finding
    /// `{expr}` interpolation holes and returns one `.interpolated_string` token
    /// whose lexeme is the whole raw body (delimiters excluded); the parser
    /// later splits literal text from embedded expressions.
    ///
    /// The subtle part is not treating a `}` inside an embedded expression's own
    /// string as the end of the hole. Two pieces of state handle this:
    ///
    ///   * `in_expr` toggles on at `{` and back off when the matching `}` is
    ///     reached, so text outside a hole and text inside one are scanned by
    ///     different rules.
    ///   * `brace_level` counts nested `{`/`}` while inside an expression, so a
    ///     `}` only closes the hole when the level returns to zero.
    ///
    /// While inside an expression, a nested double-quoted string is scanned
    /// whole (respecting its own `\` escapes) so that a `}` inside it is ignored.
    /// Newlines update `line`/`column` in both modes. Outside an expression, `\`
    /// escapes the next byte and a bare `"` ends the whole literal. The
    /// `- lexeme.len - 3` start-column adjustment accounts for the three-byte
    /// `$"`...`"` framing.
    fn readInterpolatedString(self: *Lexer) Token {
        // Byte offset where the raw body begins (just past the `$"` opener).
        const start = self.pos;
        // Depth of nested `{`/`}` while scanning inside an interpolation hole;
        // the hole closes when a `}` brings this back to zero.
        var brace_level: usize = 0;
        // Whether the cursor is currently inside a `{...}` interpolation hole.
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

/// Maps an already-scanned identifier word to its keyword token type.
///
/// This is the single keyword table: [`Lexer.readIdentifier`] scans a maximal
/// identifier run and calls this to decide whether the word is reserved. Each
/// reserved spelling returns its `keyword_*` (or `bool_true`/`bool_false`)
/// token; anything unmatched falls through to `.identifier`. Comparisons are
/// exact via `std.mem.eql`, so the language is case-sensitive and, for example,
/// `Fn` is an identifier while `fn` is a keyword.
fn tokenTypeFromKeyword(lexeme: []const u8) TokenType {
    if (std.mem.eql(u8, lexeme, "fn")) return .keyword_fn;
    if (std.mem.eql(u8, lexeme, "async")) return .keyword_async;
    if (std.mem.eql(u8, lexeme, "await")) return .keyword_await;
    if (std.mem.eql(u8, lexeme, "spawn")) return .keyword_spawn;
    if (std.mem.eql(u8, lexeme, "extern")) return .keyword_extern;
    if (std.mem.eql(u8, lexeme, "struct")) return .keyword_struct;
    if (std.mem.eql(u8, lexeme, "class")) return .keyword_class;
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
