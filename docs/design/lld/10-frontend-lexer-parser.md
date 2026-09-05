# Low-Level Design: Frontend Lexer and Parser

This document is a function-by-function reference for the two files that turn Kyte source text into an
abstract syntax tree (AST): `src/frontend/lexer.zig` and `src/frontend/parser.zig`. It is written for a
new maintainer who needs to be productive quickly, so it names every real function (public and private),
every type, and every piece of module-level state.

## Where these files sit in the pipeline

The compiler front end runs source text through two stages. The lexer scans raw bytes and produces a flat
stream of `Token` values, each carrying a kind, a lexeme slice, and a line/column position. The parser
consumes that stream (materialised as a slice up front) and produces an `ast.Program`, a tree of typed
declarations, statements, and expressions. Nothing here does type checking, name resolution, or ownership
analysis: that is the job of `type_checker.zig` and the `sema/` passes downstream. The parser does,
however, do a fair amount of desugaring (for-in loops, `while (let ...)`, tuple variants, `T?` sugar,
`try?`, compound assignment, trait default-method expansion), so the AST it hands over is already lowered
in several places. The flow is: source bytes to `Lexer.nextToken()` (tokens) to `Parser.parseProgram()`
(AST) to the rest of the compiler.

A useful mental model of the parser: it is a hand-written recursive-descent parser with a classic
precedence-climbing chain for binary operators (`parseAssignment` at the top, down through logical,
bitwise, equality, comparison, shift, additive, multiplicative, unary, postfix, primary). It does no
backtracking in the general case, but it uses bounded token lookahead in a few spots to disambiguate
`<` (generic argument list versus less-than) and `(` (arrow-function parameter list versus parenthesised
expression or tuple). Error reporting is print-to-stderr plus a small error set; there is no error
recovery, so the first hard error aborts the parse.

---

## `src/frontend/lexer.zig` (735 lines)

**Role in the pipeline:** The lexer is the byte-level scanner. `Lexer.init` wraps a source slice, and
each `nextToken()` call skips whitespace and comments, then classifies the next run of bytes into exactly
one `Token`. It is a pull lexer, not a push one: the parser drives it by calling `nextToken()` in a loop
until it sees `.eof`. The lexer holds no allocator and allocates nothing. Every `Token.lexeme` is either a
slice into the original source (identifiers, numbers, strings, the interior of template and interpolated
strings) or a static string constant baked into the code (punctuation and operators). This slice-versus-
static distinction matters greatly downstream: the parser relies on source-slice lexemes to compute spans
and to reconstruct multi-token NSX attribute names by adjacency, and it explicitly cannot do that for
punctuation tokens whose lexemes are static.

The big ideas to keep in mind: string, template, and interpolated-string bodies are lexed as a single
token each (the parser re-lexes the interior later); the lexer only tracks brace nesting inside `$"..."`
interpolation so it knows where the literal ends; numbers understand `_` digit separators, radix prefixes
(`0x`/`0b`/`0o`), floats, scientific notation, and a trailing `m`/`M` decimal suffix; and `<<`/`>>`
(`shl`/`shr`) are lexed as single tokens, which the parser later has to split back apart when they appear
as generic-close `>` characters.

**Key types and data structures:**

- **`pub const TokenType = enum { ... }`** -- the closed set of token kinds. Groups worth knowing:
  - Keywords: `keyword_fn`, `keyword_async`, `keyword_await`, `keyword_spawn`, `keyword_extern`,
    `keyword_struct`, `keyword_class`, `keyword_import`, `keyword_trait`, `keyword_impl`, `keyword_return`,
    `keyword_let`, `keyword_defer`, `keyword_errdefer`, `keyword_break`, `keyword_continue`, `keyword_if`,
    `keyword_else`, `keyword_while`, `keyword_for`, `keyword_switch`, `keyword_case`, `keyword_default`,
    `keyword_try`, `keyword_catch`, `keyword_throw`, `keyword_match`, `keyword_const`, `keyword_export`,
    `keyword_enum`, `keyword_pub`, `keyword_var`, `keyword_union`. Note `exception` and `where` are NOT in
    this set: they are contextual identifiers handled in the parser, and `match`/`throw`/`var` exist as
    tokens even though the parser rejects some of them.
  - Literals and identifiers: `identifier`, `integer`, `float`, `decimal`, `string`, `template_string`,
    `interpolated_string`, `bool_true`, `bool_false`, `char_literal`.
  - Operators and punctuation: `plus`, `minus`, `star`, `slash`, `equal`, `equal_equal`, `bang_equal`, the
    compound-assign family (`plus_equal`, `minus_equal`, `star_equal`, `slash_equal`, `percent_equal`,
    `amp_equal`, `pipe_equal`, `caret_equal`, `shl_equal`, `shr_equal`), `less`, `greater`, `shl`, `shr`,
    `less_equal`, `greater_equal`, `And` (`&&`), `Or` (`||`), `not` (`!`), `colon`, `semicolon`, `comma`,
    the bracket pairs, `arrow` (`->`), `dot`, `dot_dot` (`..`), `dot_dot_eq` (`..=`), `pipe`, `ampersand`,
    `caret`, `tilde`, `percent`, `jsx_close` (`</`), `jsx_self_close` (`/>`), `question`, `at` (`@`),
    `ellipsis` (`...`), `fat_arrow` (`=>`), and `eof`.
- **`pub const Token = struct`** -- one lexed token.
  - `type: TokenType` -- the classification.
  - `lexeme: []const u8` -- the text. Source slice for value-bearing tokens, static constant for operators.
    Ownership: never owned by the token; it borrows the source or points at a string literal.
  - `line: usize` -- 1-based line of the token (see the column caveat below).
  - `column: usize` -- 1-based column. Invariant to watch: for most tokens `column` is back-computed as the
    column AFTER consuming the token minus its length, so it points at the token start; but see the string
    readers where the arithmetic subtracts extra for the quote characters.
- **`pub const Lexer = struct`** -- the scanner state.
  - `source: []const u8` -- the full input, borrowed.
  - `pos: usize` -- current byte offset into `source`.
  - `line: usize` -- current 1-based line, bumped on `\n`.
  - `column: usize` -- current 1-based column, reset to 1 on `\n`.
  - `tok_start: usize = 0` -- byte offset where the current token began, set at the top of `nextToken`.
    It is bookkeeping only and is not currently read elsewhere in this file.

**Module-level state / constants:** none. The only file-scope function is `tokenTypeFromKeyword` (below).
There are no `pub var`/`pub const` globals.

**Functions (source order):**

- **`pub fn init(source: []const u8) Lexer`** (pub) -- constructs a lexer positioned at the start
  (`pos = 0`, `line = 1`, `column = 1`). Allocates nothing; borrows `source`.

- **`pub fn nextToken(self: *Lexer) Token`** (pub, method) -- the single entry point. Skips whitespace and
  line comments via `skipWhitespace`, records `tok_start`, and returns `.eof` at end of input. Otherwise
  it switches on the first byte: letters/underscore go to `readIdentifier`, digits to `readNumber`, `"` to
  `readString`, `` ` `` to `readTemplateString`, `$"` to `readInterpolatedString`, `'` inlines a
  char-literal scan, and every operator/punctuation byte is handled inline with maximal-munch lookahead
  (for example `<` can become `less`, `jsx_close`, `less_equal`, `shl`, or `shl_equal`). Side effects:
  advances `pos`/`column`/`line`. Gotchas: an unexpected byte (including a lone `$` not followed by `"`)
  prints `Unexpected character` to stderr, skips one byte, and recurses, so bad input is silently dropped
  rather than erroring. The `//` case here also skips a line comment and recurses (belt and braces with
  `skipWhitespace`). The char-literal branch consumes through the closing `'`, honouring `\` escapes, and
  keeps the quotes in the lexeme (the parser strips them in `parseLiteral`).

- **`fn skipWhitespace(self: *Lexer) void`** (private, method) -- advances over spaces, `\r`, `\t`, and
  `\n` (bumping `line`), and over `//` line comments (scanning to end of line). Returns as soon as it hits
  a `/` that is not the start of a comment, or any non-whitespace byte. Note it does NOT bump `column`
  while skipping a line comment body, only `pos`; this is a minor column-accuracy quirk.

- **`fn readIdentifier(self: *Lexer) Token`** (private, method) -- consumes a run of `[A-Za-z0-9_]`, then
  classifies the lexeme through `tokenTypeFromKeyword`. Returns either a keyword token or `.identifier`.
  The lexeme is a source slice. First character being a letter/underscore is guaranteed by the caller.

- **`fn scanDigitRun(self: *Lexer) void`** (private, method) -- consumes base-10 digits, allowing a single
  `_` between digits as a separator. A `_` is consumed only when the next byte is also a digit, so a
  trailing or doubled `_` ends the run. Used by `readNumber` for the integer part, fractional part, and
  exponent.

- **`fn readNumber(self: *Lexer) Token`** (private, method) -- the numeric-literal scanner, and the most
  involved lexer routine. Order of work: (1) if the input begins `0x`/`0X`, `0b`/`0B`, or `0o`/`0O`, scan
  base digits (with `_` separators via `isBaseDigit`) and return an `.integer` whose lexeme keeps the
  prefix; radix literals are always integers. (2) Otherwise scan an integer digit run. (3) If a `.` is
  followed by a digit, consume the fractional part and mark it a float (a `.` not followed by a digit is
  left alone, so `1.method()` and range `1..2` are not eaten). (4) Handle a scientific exponent `e`/`E`
  with optional sign, consumed only when a digit actually follows, marking the result a float. (5) After
  the numeric span ends (`num_end`), a trailing `m`/`M` at an identifier boundary marks the token
  `.decimal` (the `m` is consumed but is NOT included in the lexeme, which stops at `num_end`). Returns
  `.decimal`, `.float`, or `.integer` accordingly. Gotcha: the decimal suffix must be at an identifier
  boundary, so `1m` is decimal but `1module` is the integer `1` followed by the identifier `module`.

- **`fn isIdentChar(c: u8) bool`** (private) -- true for `[A-Za-z0-9_]`. Used by `readNumber` to test the
  decimal-suffix boundary.

- **`fn isBaseDigit(c: u8, base: u8) bool`** (private) -- true when `c` is a valid digit in the given radix
  (16, 8, 2, else base-10). Used for radix-prefixed integer scanning.

- **`fn readString(self: *Lexer) Token`** (private, method) -- reads a `"..."` string. Consumes the opening
  quote, scans to the closing quote honouring `\` escapes (skipping two bytes on a backslash), then
  consumes the closing quote. The lexeme is the interior only (quotes excluded), a source slice. The
  column arithmetic subtracts `lexeme.len + 2` to account for both quotes. No escape decoding happens
  here: escapes are resolved later.

- **`fn readTemplateString(self: *Lexer) Token`** (private, method) -- identical structure to `readString`
  but delimited by backticks, producing `.template_string`. The interior (including any `${...}`
  interpolation markers) is returned verbatim as one lexeme; the parser re-scans it in
  `parseTemplateString`.

- **`fn readInterpolatedString(self: *Lexer) Token`** (private, method) -- reads a `$"..."` string
  (the `$"` prefix has already been consumed by `nextToken`). It walks the body tracking whether it is
  inside a `{...}` interpolation expression (`in_expr`) and the brace nesting depth (`brace_level`), so it
  can find the true closing `"`. Inside an expression it also skips nested string literals and their
  escapes so a `"` inside `{...}` does not end the outer string, and it bumps `line` on newlines. Returns
  `.interpolated_string` with the interior as the lexeme (source slice); the parser re-lexes it in
  `parseInterpolatedString`. Gotcha: the column arithmetic subtracts `lexeme.len + 3` for the `$"` prefix
  and closing quote.

- **`fn tokenTypeFromKeyword(lexeme: []const u8) TokenType`** (file-scope, private) -- maps a scanned
  identifier lexeme to its keyword `TokenType`, or `.identifier` if it is not a keyword. Implemented as a
  linear chain of `std.mem.eql` comparisons. It also classifies `true`/`false` as `bool_true`/`bool_false`.
  Anything not listed (including `exception`, `where`, `mut`, `undefined`, `null`, `as`, `in`, `then`)
  returns `.identifier`; those are all contextual keywords resolved in the parser by lexeme comparison.

**Cross-references:** `Parser.init` (in `parser.zig`) is the only caller: it drives `nextToken()` to
build the token slice. The `Token`/`TokenType` types are re-exported through `lexer.zig` and referenced
across the parser as `lexer.Token`/`lexer.TokenType`. No file in this pair imports `ast.zig` from the
lexer; the lexer is AST-agnostic.

---

## `src/frontend/parser.zig` (2963 lines)

**Role in the pipeline:** The parser converts the token stream into an `ast.Program`. `Parser.init` runs
the lexer to completion, stores the tokens in an owned slice, and then the recursive-descent routines
walk that slice. Declarations are parsed by `parseProgram` to `parseDeclaration`; statements by
`parseStatement` and friends; expressions by the precedence chain rooted at `parseExpression`. The parser
owns an allocator and builds the AST with it, so every node it returns is allocator-owned; the caller
(usually the compile driver in `main.zig`/`pipeline.zig`) owns the resulting `Program` and its arena.

Big ideas to hold in mind. Precedence: binary operators use precedence climbing, one function per level,
each looping to build left-associative chains. Lookahead: `<` disambiguation in `parsePostfix` scans
ahead counting `<`/`>`/`>>` depth and bailing on `;`/`{`/`}`, and arrow-function detection in
`parsePrimary` scans to the matching `)` and checks for `=>`. Generic close: because the lexer emits `>>`
as a single `shr` token, `expectGenericClose` rewrites a `shr` in place into a `greater` so a nested
generic like `List<List<int>>` closes correctly. Desugaring: for-in over collections and maps,
`while (let ...)`, tuple-form enum variants, `T?`, `try?`, and compound assignment all expand to simpler
AST here. Target gating: `@wasm { ... }` and `@native { ... }` blocks are kept or skipped based on
`is_wasm`. Error handling: everything returns `ParserError`, errors print a diagnostic to stderr and
unwind; there is no recovery.

**Key types and data structures:**

- **`const ParserError = error{ UnexpectedToken, ExpectedToken, OutOfMemory }`** (file-scope) -- the parser
  error set. `UnexpectedToken` is the general "this token cannot appear here" or a semantic rejection
  (removed `throw`/`catch`, multiple error types in a union, out-of-range integer literal).
  `ExpectedToken` comes specifically from `expect` when the current token is not the demanded kind.
  `OutOfMemory` is propagated from allocation.
- **`pub const Parser = struct`** -- the parser state.
  - `allocator: std.mem.Allocator` -- used for the token slice, `file_path` dup, and every AST node.
  - `tokens: []lexer.Token` -- the owned token slice (freed in `deinit`). Mutable: `expectGenericClose`
    rewrites a `shr` token in place.
  - `pos: usize` -- index of the current token.
  - `file_path: []const u8` -- owned duplicate of the source path, stamped into every `Span`.
  - `is_wasm: bool` -- target flag driving `@wasm`/`@native` block selection.
  - `source: []const u8` -- the original source, borrowed, used by `span()` to compute byte offsets by
    pointer arithmetic against a lexeme slice.
  - `for_counter: usize = 0` -- monotonically increasing counter used to generate unique synthetic names
    (`__for_idx_N`, `__for_coll_N`, `__for_keys_N`, `__for_map_N`) during for-in desugaring, so nested
    loops do not collide.

**Module-level state / constants:** the only file-scope declarations are `ParserError` (above) and the
helper `intLiteralOf` (below). No `pub var`/`pub const` globals; all state lives in a `Parser` instance.

**Functions (source order):**

- **`fn intLiteralOf(e: ast.Expression) ?usize`** (file-scope, private) -- returns the value of a
  non-negative integer literal expression, else null. Used to validate the `count` in the `[value; count]`
  array-repeat form. Rejects negatives and non-literals.

- **`pub fn init(allocator, source, file_path, is_wasm) !Parser`** (pub) -- builds a `Lexer`, pumps
  `nextToken()` into a growing list until `.eof`, converts to an owned slice, dupes `file_path`, and
  returns the `Parser`. Side effects/ownership: allocates the token slice and the file-path copy (freed by
  `deinit` and, for the path, not freed at all currently). Errors: `OutOfMemory`.

- **`pub fn deinit(self: *Parser) void`** (pub) -- frees the token slice. Note it does NOT free
  `file_path`; the file path dup lives for the process (or is arena-collected upstream).

- **`fn current(self: *Parser) lexer.Token`** (private, method) -- the token at `pos`. Unchecked index;
  correctness relies on the stream always ending in `.eof` so `pos` never runs past the array while the
  loops test for `.eof`.

- **`fn peek(self: *Parser) lexer.Token`** (private, method) -- the token at `pos + 1`, clamped to the last
  token (the `.eof`) at end of stream.

- **`fn advance(self: *Parser) void`** (private, method) -- increments `pos`. No bounds check; see `current`.

- **`fn match(self: *Parser, expected) bool`** (private, method) -- if the current token matches `expected`,
  consume it and return true, else return false without consuming. Special case: when `expected` is
  `.identifier`, a `keyword_fn` token also matches (so `fn` can be used as an identifier, e.g. a method
  named `fn`); it does NOT special-case `keyword_spawn` here (that is only in `expect`).

- **`fn expect(self: *Parser, expected) ParserError!void`** (private, method) -- like `match` but errors
  when the token does not match, printing `Expect failed: ...` with position. Identifier special cases:
  `keyword_spawn` is accepted where an identifier is expected (so `spawn` can name things), and
  `keyword_fn` is accepted too. Returns `error.ExpectedToken` on mismatch.

- **`fn expectGenericClose(self: *Parser) ParserError!void`** (private, method) -- closes a generic
  argument list. If the current token is `shr` (`>>`), it rewrites that token IN PLACE to a single
  `greater` (`>`) and returns without advancing, so the outer generic consumes the remaining `>` on its
  next close. Otherwise it demands a plain `greater`. This is the mechanism that lets `Map<K, List<V>>`
  parse despite the lexer merging `>>`. Footgun: it mutates `self.tokens`, so re-parsing the same token
  slice is not idempotent.

- **`fn span(self: *Parser) ast.Span`** (private, method) -- builds a `Span` for the current token. It
  computes the byte `start` by subtracting the source base pointer from the lexeme pointer, but only when
  the lexeme pointer lies inside `source` (true for source-slice lexemes, false for static operator
  lexemes, in which case `start` is 0). Fills `end`, `line`, `col`, and `file`. Gotcha: spans built at a
  static-lexeme token, or after a desugar that fabricated tokens, can carry `start = 0`; positions in
  diagnostics come mostly from the tokens themselves, not from `span`.

- **`fn allocStatement(self, value) !*ast.Statement`** (private, method) -- heap-copies a `Statement` and
  returns the pointer. Allocator-owned.

- **`fn allocExpression(self, value) !*ast.Expression`** (private, method) -- heap-copies an `Expression`.
  Allocator-owned. These two are used everywhere the AST needs owning pointers to children.

- **`fn parseStatementOrBlock(self) ParserError!ast.Statement`** (private, method) -- if the next token is
  `{`, parse a block; otherwise parse a single statement. Used for if/while/for bodies so both `{ ... }`
  and single-statement bodies work.

- **`fn expandTraitDefaults(self, decls) ParserError!void`** (private, method) -- post-processing pass run
  once by `parseProgram` after all declarations are parsed. For every struct declaration with trait impls,
  it copies each impl'd trait's default-bodied methods onto the struct unless the struct already defines a
  method of that name, retyping the leading `self` parameter to the impl'ing struct (generic form via
  `selfTypeRefFor` when the struct has type params). This makes default methods flow through the normal
  method machinery. Side effects: mutates `sd.methods` (reallocates the method slice). Limitation stated
  in code: same-file only, the trait and struct must be in one module.

- **`fn selfTypeRefFor(self, sd) ParserError!ast.TypeRef`** (private, method) -- returns the `TypeRef` for a
  struct's own type: a plain `.ident` when non-generic, or a `.generic` with the struct's type params as
  arguments when generic. Used by `expandTraitDefaults` to retype `self`.

- **`fn findTraitDecl(decls, name) ?ast.TraitDecl`** (file-scope-style private, takes decls not self)  -- 
  linear search for a `trait_decl` by name in a declaration slice. Returns null if absent.

- **`fn structHasMethod(methods, name) bool`** (private) -- true if any method in the slice has the given
  name. Used to avoid overriding a struct's own method with a trait default.

- **`pub fn parseProgram(self) ParserError!ast.Program`** (pub) -- the top-level driver. Loops until
  `.eof`: skips stray `;`; handles `@wasm`/`@native` target blocks (parsing the inner declarations when
  the target matches `is_wasm`, else brace-counting past them without parsing); treats a top-level
  `identifier (` as an expression statement to run (parsed and discarded, for top-level calls); and
  otherwise calls `parseDeclaration`. After collecting all declarations it runs `expandTraitDefaults` and
  returns the `Program`. Ownership: returns an allocator-owned declaration slice.

- **`fn parseAttributes(self) ParserError![]ast.Attribute`** (private, method) -- parses a run of `@name`
  attributes. Recognises `@serializable`, `@test`, `@deprecated` (optionally `@deprecated("note")`),
  `@route("METHOD", "path")`, and the shorthand `@get/@post/@put/@delete("path")` which desugar to a
  `.route` attribute with the uppercased method. Side effects: dupes attribute string arguments.
  Unrecognised `@name` attributes are consumed and dropped (the name is still `expect`ed as an
  identifier). Returns an owned slice.

- **`fn parseDeclaration(self) ParserError!ast.Declaration`** (private, method) -- parses one top-level
  declaration. First reads attributes and an optional `pub`. Then dispatches on the current token:
  `export` (exported fn), `fn`/`async` (function), `extern` (FFI fn), `struct`/`class` (struct decl),
  `union`, `enum`, the contextual `exception` identifier (an enum flagged `is_exception`), `trait`,
  `import`, `const`. Anything else is `error.UnexpectedToken`. Attaches the parsed attributes to the
  produced declaration.

- **`fn import_decl_fallback(self) ParserError!ast.ImportDecl`** (private, method) -- thin wrapper that just
  calls `parseImportDecl`. A historical seam.

- **`fn parseConstDecl(self) ParserError!ast.ConstDecl`** (private, method) -- parses `const NAME [: Type]
  = expr;`. The type annotation is parsed and DISCARDED (const type is inferred). Returns a `ConstDecl`
  with `is_exported = false` and a span spanning the declaration.

- **`fn skipWhereClause(self) ParserError!void`** (private, method) -- parses and discards an optional
  `where T: Bound + Bound2, U: ...` clause. Generic dispatch in Kyte is structural, so the bounds are
  advisory and thrown away here; the function only exists so the grammar accepts them.

- **`fn parseFunctionDecl(self, is_exported) ParserError!ast.FunctionDecl`** (private, method) -- parses a
  full function: optional `async`, `fn`, name, optional `<T, U>` type params, `(params)` (each `name` with
  optional `: Type`), optional `: RetType`, optional `where` clause, then the block body. Returns a
  `FunctionDecl` with `attributes` empty (the caller fills them). Ownership: params and type-params slices
  are allocator-owned. Used for free functions, methods, and enum/trait methods.

- **`fn parseExternFnDecl(self, is_exported) ParserError!ast.FunctionDecl`** (private, method) -- parses
  `extern("lib") fn name(params) [: Ret];`. Same parameter grammar as `parseFunctionDecl` but the body is
  empty and `extern_lib` is set to the duped library name. Terminated by `;`, not a block.

- **`fn parseInitializerDecl(self, start_span) ParserError!ast.FunctionDecl`** (private, method) -- parses a
  struct `init(params) { ... }` constructor. The leading `init` identifier has already been consumed by
  the caller (`parseStructDecl`); `start_span` is passed in so the span covers the whole thing. Produces a
  `FunctionDecl` named `"init"` with no return type.

- **`fn parseStructDecl(self, is_public) ParserError!ast.StructDecl`** (private, method) -- parses
  `struct`/`class Name<TypeParams> [impl Trait<...>, Trait2] { fields, methods, init }`. Records
  `is_reference = is_class` (class is a reference type, struct a value type; the bit is stored and used
  downstream in codegen). Inside the body it loops: reads attributes and `pub`; a `fn`/`async` becomes a
  method (marked static unless the first parameter is `self`); an `init` identifier becomes an initializer
  method (always public, non-static); anything else is a `name: Type` field (attributes on a field are an
  error). Trailing commas between fields are consumed. Returns the assembled `StructDecl`; the caller sets
  `attributes`.

- **`fn parseUnionDecl(self, is_public) ParserError!ast.UnionDecl`** (private, method) -- parses
  `union Name { field: Type, ... }`. Only fields (each optionally `pub`), no methods. Trailing commas
  consumed.

- **`fn parseEnumDecl(self, is_exception) ParserError!ast.EnumDecl`** (private, method) -- parses an enum
  body; the leading `enum` keyword or contextual `exception` identifier has already been consumed by the
  caller. `is_exception` flags the enum as an exception (sema will require a `describe(self): string`
  method). Each member is either a method (`fn`/`async`) or a variant. Variant forms: bare `Name`;
  `Name = <int>` (explicit discriminant, value parsed via `parseIntLexeme`); `Name { field: Type, ... }`
  (named-payload struct variant); `Name(Type)` (single-payload, stored in `type_name`); and
  `Name(Type, Type, ...)` (multi-payload tuple form, DESUGARED to positional fields `_0`, `_1`, ... so it
  reuses the struct-payload machinery). Trailing commas between variants consumed. Ownership: variant
  field slices and the `_N` names are allocator-owned.

- **`fn parseTraitDecl(self, is_public) ParserError!ast.TraitDecl`** (private, method) -- parses
  `trait Name<TypeParams> { method signatures or defaults }`. Each method: optional `async`, `fn`, name,
  `(params)` where a bare `self` (no `: Type`) is given the type `.ident = "self"`, optional `: Ret`,
  optional `where`, then either a `;` (signature only) or a `{ ... }` default body. Produces
  `TraitMethodDecl` entries; default bodies feed `expandTraitDefaults`.

- **`fn parseImportDecl(self) ParserError!ast.ImportDecl`** (private, method) -- parses
  `import a.b.c;` into a module path where dots become `/` (so `crypto.tls.tls` becomes `crypto/tls/tls`).
  A path segment is normally an identifier, but a bare integer segment is allowed for version directories
  (`import crypto.tls.13.tls;`). The joined path is duped into `module`; `items` is empty. Ownership: the
  module string is allocator-owned.

- **`fn parseTypeRefAtom(self) ParserError!ast.TypeRef`** (private, method) -- parses one type atom, the
  base for `parseTypeRef`'s postfix loop. Handles: a leading `&`/`&mut` borrow marker (parsed and
  transparently dropped, recursing into the inner type); a parenthesised list that becomes either a
  function type `(Params) => Ret`/`(Params) -> Ret` or a `.tuple` type; `...` as sugar for `any`; a
  dotted qualified name (`mod.Type`, keeping only the last segment as `name`); and a `Name<...>` generic
  application. Returns `.ident`, `.tuple`, `.func`, or `.generic`. Footgun: the qualified-name handling
  keeps only the final segment, so module qualification of a type is flattened here.

- **`fn parseTypeRef(self) ParserError!ast.TypeRef`** (private, method) -- parses a full type reference: an
  atom followed by a postfix loop handling `|` unions, `?` optionals, and `[N]` fixed arrays. The union
  path is where the error-union and optional grammar lives: `T | undefined` wraps `T` in `.optional`;
  `T | E` becomes an `.error_union { ok, err }`; and it HARD-ERRORS if two distinct error types appear
  (`T | E1 | E2`), directing the user to a single error enum. `T?` is pure sugar for `T | undefined`
  (same `.optional` node). `T[N]` parses an integer length into a `.fixed_array`. The loop stacks these,
  so `T?[4]` and similar compose. Returns the built-up `TypeRef`.

- **`fn parseBlock(self) ParserError!ast.Block`** (private, method) -- parses `{ statements }`, skipping
  stray `;`. Returns an owned statement slice wrapped in a `Block`.

- **`fn parseStatement(self) ParserError!ast.Statement`** (private, method) -- the statement dispatcher.
  `let` and `const` go to `parseLetStmt`; `var` is a hard error with a helpful message (Kyte has no `var`);
  `if`/`while`/`for`/`switch`/`return` to their parsers; `throw`/`catch` are rejected via
  `rejectExceptions`; `try` is rejected only when it is followed by `{` (the exception-block form), else it
  is an expression statement (prefix `try`); `defer`/`errdefer` to `parseDeferStmt`; `break`/`continue`
  are parsed inline (each expects a trailing `;`); a `{` starts a block; `@wasm`/`@native` statement-level
  target blocks are handled here too (parsed or brace-skipped by target), and any other `@` is an
  expression statement (an attribute-style expression); everything else is an expression statement.

- **`fn peekIsLeftBrace(self) bool`** (private, method) -- true if the token after the current one is `{`.
  Used to distinguish `try { ... }` (rejected) from `try expr`.

- **`fn rejectExceptions(self) ParserError!ast.Statement`** (private, method) -- always returns
  `error.UnexpectedToken`, printing a detailed message. It has a special message for `try { ... }`
  explaining `try` is a prefix operator, and a general message for `throw`/`catch` explaining exceptions
  were removed in favour of error values. This is a deliberate teaching error, not a parse failure of
  malformed input.

- **`fn parseDeferStmt(self, is_err) ParserError!ast.DeferStmt`** (private, method) -- parses
  `defer expr;` or `errdefer expr;` (chosen by `is_err`). Returns a `DeferStmt` carrying the expression
  and the `is_err` flag.

- **`fn parseLetStmt(self, is_const) ParserError!ast.LetStmt`** (private, method) -- parses `let`/`const`
  bindings. Supports a single name, or a tuple-destructure `let (a, b, c) = ...` (stored in `names`),
  optional `: Type`, optional `= init`, terminated by `;`. `is_const` records const-ness. Returns a
  `LetStmt`; for the tuple form `name` is empty and `names` is the owned name slice.

- **`fn parseIfStmt(self) ParserError!ast.IfStmt`** (private, method) -- parses `if (cond) then [else ...]`.
  The `else` branch may be another `if` (recursing, for else-if chains) or a statement/block. Branches are
  heap-allocated statements.

- **`fn parseWhileStmt(self) ParserError!ast.WhileStmt`** (private, method) -- parses `while (cond) body`,
  with a special `while (let x = expr)` optional-binding form. The binding form is DESUGARED to
  `while (true) { let x = expr; if (x == undefined) { break; } body }`, reusing the guard-break narrowing
  the checker already understands. Everything (the let, the `x == undefined` guard, the break block) is
  built as fresh AST here using `allocExpression`/`allocStatement`.

- **`fn parseRangeOrExpr(self) ParserError!ast.Expression`** (private, method) -- parses an expression, and
  if it is followed by `..` or `..=`, wraps start and end in a `.range` (inclusive for `..=`). Used by the
  for-in path so `for (i in 0..n)` produces a range iterator.

- **`fn mkMethodCall(self, recv, method, args, sp) ParserError!ast.Expression`** (private, method)  -- 
  helper that builds `recv.method(args)` as AST: an `.ident` receiver, a `.field_access` callee, and a
  `.call`. Used by the for-in desugarers to synthesise `.size()`, `.at(i)`, `.keys()`, `.get(k)` calls.

- **`fn desugarCollectionForIn(self, name, iterable, body, sp) ParserError!ast.Statement`** (private,
  method) -- desugars `for (x in collection)` over an indexable collection into a classic index loop:
  `let __for_idx_N: int = 0; for (; __for_idx_N < coll.size(); __for_idx_N = __for_idx_N + 1) { let x =
  coll.at(__for_idx_N); body }`. When the iterable is not a bare identifier it first binds it to a
  `__for_coll_N` temp (so it is evaluated once) and wraps the loop in an outer block. Uses `for_counter`
  for unique names. Everything is synthesised AST.

- **`fn desugarMapForIn(self, k_name, v_name, iterable, body, sp) ParserError!ast.Statement`** (private,
  method) -- desugars `for ((k, v) in map)` into: bind the map to a temp if needed, `let __for_keys_N =
  map.keys();`, then a collection for-in over the keys where each iteration adds `let v = map.get(k);`
  before the body. Delegates the key iteration to `desugarCollectionForIn`. Uses `for_counter`.

- **`fn parseForStmt(self) ParserError!ast.Statement`** (private, method) -- parses all three for-loop
  shapes after `for (`. First, by fixed token lookahead it recognises `for ((k, v) in ...)` (map form,
  routes to `desugarMapForIn`). Next it recognises `for (x in ...)`: if the iterable is a `.range` it
  emits a native `.for_stmt` with a `ForIterator`, otherwise it desugars a collection loop via
  `desugarCollectionForIn`. Otherwise it parses a C-style `for (init; cond; incr)` where init may be a
  `let`/`const`, an expression, or empty, and cond/incr are optional. Returns a `.for_stmt` or a desugared
  block.

- **`fn parseSwitchStmt(self) ParserError!ast.SwitchStmt`** (private, method) -- parses
  `switch (discr) { case v[, v2] [if guard]: { ... } ... default: { ... } }`. Each case can list multiple
  comma-separated match values and an optional `if guard`. The `default` case ends the loop (it breaks
  after parsing). Case and default bodies are blocks wrapped as statements. Returns the `SwitchStmt` with
  its case slice and optional default.

- **`fn parseReturnStmt(self) ParserError!ast.ReturnStmt`** (private, method) -- parses `return [expr];`.
  A bare `return;` yields a null value.

- **`fn parseExprStmt(self) ParserError!ast.ExprStmt`** (private, method) -- parses an expression as a
  statement. Requires a trailing `;` EXCEPT when the expression is a `.jsx_element`, where the `;` is
  optional (NSX elements are statement-like). Returns an `ExprStmt`.

- **`fn parseExpression(self) ParserError!ast.Expression`** (private, method) -- the expression entry point;
  just calls `parseAssignment`. This is the top of the precedence chain.

- **`fn parseAssignment(self) ParserError!ast.Expression`** (private, method) -- lowest-precedence level.
  Parses a logical expression, then: handles a trailing `catch [(e)] handler` (building a `.catch_expr`,
  right-associative via recursion); a plain `=` assignment (building a `.binary` with op `.assign`,
  right-associative); and the compound-assignment family (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`,
  `<<=`, `>>=`), each desugared to `left = left <op> right`. Note the compound form allocates `left`
  twice (once as the assign target, once inside the binary op), so the LHS expression AST is duplicated.

- **`fn parseLogical(self) ParserError!ast.Expression`** (private, method) -- handles `&&`, `||`, and the
  `??` nullish-coalesce operator in one left-associative loop (a `.binary` for `&&`/`||`, a
  `.nullish_coalesce` for `??`). After the loop it also handles the ternary `cond ? then : else` (a single
  `?`, building an `.if_expr`). Precedence subtlety: `??` sits at the same level as `&&`/`||` here, and the
  ternary is layered on top of the whole logical chain.

- **`fn parseBitwiseOr(self) ParserError!ast.Expression`** (private, method) -- left-associative `|`
  (bit-or) chain. Sits below logical and above bitwise-xor.

- **`fn parseBitwiseXor(self) ParserError!ast.Expression`** (private, method) -- left-associative `^`
  (bit-xor) chain.

- **`fn parseBitwiseAnd(self) ParserError!ast.Expression`** (private, method) -- left-associative `&`
  (bit-and) chain.

- **`fn parseEquality(self) ParserError!ast.Expression`** (private, method) -- left-associative `==`/`!=`
  chain (`.eq`/`.ne`).

- **`fn parseComparison(self) ParserError!ast.Expression`** (private, method) -- left-associative
  `<`/`>`/`<=`/`>=` chain (`.lt`/`.gt`/`.le`/`.ge`). Subtle: the loop reads the operator, then parses the
  right operand with `parseAddSub` (not `parseShift`), so shift binds tighter than comparison in practice
  even though `parseShift` is the level above; this is a minor asymmetry to be aware of.

- **`fn parseShift(self) ParserError!ast.Expression`** (private, method) -- left-associative `<<`/`>>`
  chain (`.shl`/`.shr`). Operands parsed with `parseAddSub`.

- **`fn parseAddSub(self) ParserError!ast.Expression`** (private, method) -- left-associative `+`/`-`
  (`.add`/`.sub`), operands from `parseMulDiv`.

- **`fn parseMulDiv(self) ParserError!ast.Expression`** (private, method) -- left-associative
  `*`/`/`/`%` (`.mul`/`.div`/`.mod`), operands from `parseUnary`.

- **`fn parseUnary(self) ParserError!ast.Expression`** (private, method) -- prefix operators. Handles
  `try` (propagating `.try_expr`) and its `try?` variant (desugared to `expr catch undefined`, a
  `.catch_expr` with an undefined handler); `await` (`.await_expr`); `spawn` (`.go_expr`); a leading `&`
  (borrow marker, transparently dropped, recursing); `-` (negation, with a special case folding a negated
  decimal literal into a `-`-prefixed decimal string rather than a `.unary` node); `!` (`.not`); and `~`
  (`.bit_not`). Falls through to `parsePostfix`. Footgun: `&` as a prefix is silently dropped, so
  address-of syntax parses but produces the inner expression unchanged.

- **`fn parsePostfix(self) ParserError!ast.Expression`** (private, method) -- the postfix/trailer loop and
  the most intricate expression routine. Starting from a primary, it repeatedly applies:
  - `<` -- the generic-argument disambiguator. It scans ahead counting `<`/`>` depth (treating `>>` as
    minus two), bailing on `;`/`{`/`}` (which mean this `<` is a comparison, not a generic). It commits to
    a generic only if the matching close is followed by `.`, `{`, or `(`. On commit it parses the type
    args and then either a `Name<...>{ fields }` struct init, a `callee<...>(args)` generic call, or a
    `expr<...>.method(args)` generic method call.
  - `(` -- a call: `.call` with parsed argument list.
  - `[` -- an index: `.index`.
  - `.` -- either `tuple.N` positional access (desugared to `tuple[N]`, an `.index` on an integer literal)
    or a `.field_access` by name.
  - `{` -- a braced struct-init trailer, where the type name comes from a preceding `.ident` or the field
    name of a `.field_access`.
  - `?` -- only when followed by `.`, an optional-chaining `obj?.field` (`.optional_chaining`); a lone `?`
    is left for higher levels.
  - `identifier` -- only when it is the contextual `as`, a cast `expr as Type` (`.cast`).
  - anything else breaks the loop.
  This ordering is what makes chained trailers like `a.b(c)[d].e<T>(f)` parse.

- **`fn parseJsxAttrName(self) ParserError![]const u8`** (private, method) -- reconstructs an NSX/JSX
  attribute name that spans several lexer tokens. Kyte's lexer splits `data-on-click`, `:class`, `@click`,
  and Datastar modifiers like `data-on-interval__duration.2s` into separate tokens, so this walks the run
  of ADJACENT tokens (same line, each starting exactly where the previous ended, of the allowed kinds:
  identifier, `-`, `:`, `.`, `@`, `_`) and concatenates their lexemes into a fresh allocator buffer. It
  cannot take a source-span slice because punctuation tokens carry static lexemes, not source slices.
  Ownership: returns the buffer's items (allocator-owned).

- **`fn parseJsxElement(self) ParserError!ast.Expression`** (private, method) -- parses an NSX element
  `<tag attrs>children</tag>` or `<tag attrs />`. Attributes are name plus optional value, where the value
  is a string literal, a `{ expr }` embedded expression, or absent (a valueless boolean attribute stored
  as `name=""`). Children are parsed until the close tag: nested `<...>` elements, `{ ... }` embedded
  expressions or statements (statement when the braced content starts with a statement keyword), and runs
  of text tokens joined into a single text child with single spaces inserted wherever the source had a gap
  (detected by line/column adjacency, matching HTML whitespace collapsing). Verifies the closing tag name
  matches the opening tag. Returns a `.jsx_element`.

- **`fn parsePrimary(self) ParserError!ast.Expression`** (private, method) -- the leaf/atom parser. Cases:
  a leading `<` is an NSX element (delegates to `parseJsxElement`); `if cond [then] X else Y` is an
  if-EXPRESSION (`.if_expr`, with the optional contextual `then` keyword); `@name(Type, value)` is a
  built-in cast form (`.cast`); literals (`integer`/`float`/`decimal`/`string`/`bool`/`char`) via
  `parseLiteral`; template and interpolated strings re-parsed via `parseTemplateString` /
  `parseInterpolatedString`; a `(` that begins either an arrow-function closure (detected by scanning to
  the matching `)` and checking for `=>`) or a parenthesised expression / tuple (single item without a
  trailing comma collapses to the item, otherwise a `.tuple`); `[` array or `[value; count]` repeat
  literal (count validated by `intLiteralOf`); `{` object literal; and an `identifier`/`fn` which is
  `undefined`/`null` literals by name, a `Name { fields }` struct init, or a bare `.ident`. Anything else
  prints `Unexpected token` and errors.

- **`fn parseIntLexeme(self, token) ParserError!i64`** (private, method) -- converts an integer-literal
  lexeme to an `i64`. Radix forms (`0x`/`0b`/`0o`) are parsed as `u64` and bit-cast to `i64`, so the full
  64-bit pattern is expressible (`0xFFFFFFFFFFFFFFFF` is `-1`). A plain decimal must fit signed `i64`,
  with the single exception of `9223372036854775808` (magnitude of i64 MIN), stored as its bit pattern so
  `-9223372036854775808` yields i64 MIN. An out-of-range literal is a HARD ERROR via `intOutOfRange`, not
  a silent 0.

- **`fn intOutOfRange(self, token) ParserError`** (private, method) -- prints the out-of-range integer
  diagnostic and returns `error.UnexpectedToken`. Note the return type is `ParserError` (the error value
  itself), so callers use it as `return self.intOutOfRange(token)`.

- **`fn parseLiteral(self) ParserError!ast.Literal`** (private, method) -- converts the current literal
  token to an `ast.Literal`, advancing past it. Integers via `parseIntLexeme`; floats via `parseFloat`
  (falling back to 0.0 on parse failure); decimals keep the lexeme string; strings keep the lexeme; bools
  map to true/false; char literals strip the surrounding quotes and decode a single escape (`\n`, `\r`,
  `\t`, `\\`, `\'`, `\"`, `\0`, else the literal char) to its integer code point, producing an integer
  literal. Anything else becomes a null literal.

- **`fn parseTemplateString(self, lexeme) ParserError!ast.Expression`** (private, method) -- parses a
  backtick template body into a `.template_expr` with alternating literal-text and embedded-expression
  parts. It scans for `${` markers, emits the preceding text as a duped string literal, then finds the
  matching `}` by brace-depth counting and re-parses the interior with a FRESH sub-`Parser` (same
  allocator, file, target). The interior is parsed as a block expression when it looks statement-like
  (starts with `for`/`while`/`switch`/`let` or contains a `;`), else as a single expression; a bare
  `${if ...}` is treated as an if-expression, not a statement. Unterminated `${` is emitted as literal
  text. Ownership: text parts are duped; the sub-parser's tokens are its own.

- **`fn parseInterpolatedString(self, lexeme) ParserError!ast.Expression`** (private, method) -- the same
  algorithm as `parseTemplateString` but for `$"..."` strings where the interpolation marker is a bare
  `{` (not `${`). Produces a `.template_expr` the same way, with the same statement-versus-expression
  heuristic and the same fresh sub-parser per embedded fragment.

**Cross-references:** The parser imports `lexer.zig` (for `Token`/`TokenType` and to run the lexer in
`init`) and `ast.zig` (for every node type it constructs). Its public surface is `Parser.init`,
`Parser.deinit`, and `parseProgram`, called by the compile driver in `main.zig`/`pipeline.zig` (and by
the LSP/formatter paths). The AST it produces is consumed downstream by `type_checker.zig` and the
`sema/` passes, then `codegen/`. The template and interpolated-string parsers recursively construct
independent `Parser` instances, so those are the only place the parser calls back into its own `init`.
