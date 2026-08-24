//! The Nova abstract syntax tree: the parser's output and the shape every later
//! compiler pass reads.
//!
//! This file is nothing but data definitions. It declares the whole tree of
//! nodes the parser builds from a source file, from the top-level [`Program`]
//! down to individual [`Expression`] leaves. There is no behaviour here on
//! purpose: the AST is a plain, pass-agnostic description of "what the
//! programmer wrote", and the phases that give it meaning (the type checker,
//! the `sema/` typed-IR passes, and codegen) live elsewhere and only consume
//! these structs. Keeping the tree behaviour-free is what lets several passes
//! share one representation without coupling.
//!
//! A few conventions run through the whole file and are worth stating once:
//!
//!   * **Spans travel with every node.** Almost every struct carries a [`Span`]
//!     so that a diagnostic raised in a late pass can still point back at the
//!     exact source text. The parser fills these in; nothing downstream should
//!     need to reconstruct a location.
//!
//!   * **Slices are borrowed, ownership lives in the arena.** Every `[]const u8`
//!     name and every `[]T` child list is a slice into memory the parser's
//!     arena allocator owns. AST nodes never free anything; the arena is
//!     released wholesale once compilation of a unit is done. This is why it is
//!     safe to alias, copy, and point into these structs freely.
//!
//!   * **Recursion goes through single-pointer indirection.** Where a node
//!     contains a child of its own kind (an [`IfStmt`] branch that is itself a
//!     [`Statement`], a [`BinaryExpr`] operand that is itself an
//!     [`Expression`]), the child is stored behind a `*` because Zig cannot size
//!     a directly self-embedding struct. Lists of children, by contrast, are
//!     ordinary slices.
//!
//!   * **Tagged unions model "one of N node shapes".** [`Declaration`],
//!     [`Statement`], [`ExprKind`], [`TypeRef`], [`Literal`], and [`Attribute`]
//!     are `union(enum)`s: the tag says which grammar production matched and the
//!     payload carries its fields. Downstream passes switch on the tag.
//!
//! The statement/expression split mirrors the language: Nova is expression-
//! oriented in places (see [`IfExpr`] and `block_expr`), so a handful of
//! constructs appear both as a [`Statement`] variant and an [`ExprKind`]
//! variant with slightly different shapes.

const std = @import("std");

/// A half-open source range plus a human-readable location, attached to nearly
/// every AST node.
///
/// `start`/`end` are byte offsets into the source; `line`/`col` are the
/// 1-based position of `start` for messages; `file` is the borrowed path the
/// range belongs to. The redundancy (offsets AND line/col) is deliberate: byte
/// offsets are cheap to compute during lexing and exact for slicing, while
/// line/col is what a user-facing diagnostic prints.
pub const Span = struct {
    /// Byte offset of the first character of the span.
    start: usize,
    /// Byte offset one past the last character (half-open).
    end: usize,
    /// 1-based line number of `start`, for diagnostics.
    line: usize,
    /// 1-based column of `start`, for diagnostics.
    col: usize,
    /// Borrowed path of the source file this span refers to.
    file: []const u8,
};

/// The root of a parsed compilation unit: the ordered list of top-level
/// declarations in one source file.
pub const Program = struct {
    /// Top-level declarations in source order.
    declarations: []Declaration,
    /// Span covering the whole file.
    span: Span,
};

/// One top-level declaration, tagged by which kind of definition it is.
///
/// These are the only things allowed at file scope. Statements and expressions
/// never appear here; executable code lives inside a [`FunctionDecl`] body.
pub const Declaration = union(enum) {
    /// A free function definition.
    fn_decl: FunctionDecl,
    /// A `struct` type definition (value or reference; see [`StructDecl`]).
    struct_decl: StructDecl,
    /// A C-style tagged/untagged `union` type definition.
    union_decl: UnionDecl,
    /// An `enum` definition, possibly with payload variants.
    enum_decl: EnumDecl,
    /// A named compile-time/module-level constant.
    const_decl: ConstDecl,
    /// An `import` bringing names from another module into scope.
    import_decl: ImportDecl,
    /// An explicit `export` of a previously declared name.
    export_decl: ExportDecl,
    /// A `trait` interface definition.
    trait_decl: TraitDecl,
};

/// A single generic bound of the form `T: TraitA + TraitB`, as written in a
/// `where` clause.
///
/// Collected per type parameter; the semantics pass uses these to check that a
/// concrete type argument implements every listed trait before monomorphising.
pub const WhereBound = struct {
    /// The type parameter this clause constrains (e.g. `T`).
    type_param: []const u8,
    /// Names of the traits the parameter must satisfy.
    traits: []const []const u8,
};

/// A function definition: its signature, body, and the extras Nova functions
/// can carry (generics, async, attributes, extern linkage).
///
/// Used both for free functions ([`Declaration.fn_decl`]) and, wrapped by
/// [`MethodDecl`], for methods. When `extern_lib` is set the function has no
/// Nova body and binds to a symbol in that library instead; `body` is then an
/// empty [`Block`].
pub const FunctionDecl = struct {
    /// The function's name.
    name: []const u8,
    /// Formal parameters in declaration order.
    params: []Param,
    /// Declared return type, or `null` when the return type is inferred/void.
    ret_type: ?TypeRef,
    /// The function body. Empty for an `extern` function.
    body: Block,
    /// Whether the function is part of the module's public surface via `export`.
    is_exported: bool,
    /// Attributes (`@route`, `@test`, `@summary`, ...) attached to the function.
    attributes: []Attribute,

    /// Names of generic type parameters (`<T, U>`); empty for a non-generic fn.
    type_params: []const []const u8 = &.{},
    /// `where` clause bounds constraining `type_params`; empty when none.
    where_bounds: []const WhereBound = &.{},

    /// Whether the function is declared `async` (lowered to an LLVM coroutine).
    is_async: bool = false,

    /// The library name for an `extern` function, or `null` for a normal one.
    extern_lib: ?[]const u8 = null,
    /// Span of the whole function declaration.
    span: Span,
};

/// One formal parameter of a function.
///
/// `type_name` may be `null` for parameters whose type the checker infers
/// (for example closure parameters written without an annotation).
pub const Param = struct {
    /// Parameter name.
    name: []const u8,
    /// Declared parameter type, or `null` when it is to be inferred.
    type_name: ?TypeRef,
    /// Span of the parameter.
    span: Span,
};

/// A `struct` type definition: its fields, methods, trait implementations, and
/// value-vs-reference discipline.
///
/// The `is_reference` flag records the class/value distinction that governs
/// ARC and copy semantics (see the value-semantics notes in the project
/// memory). It defaults to `true` here; the parser and semantics pass decide
/// the final value-vs-reference classification.
pub const StructDecl = struct {
    /// The struct's name.
    name: []const u8,
    /// Declared fields in source order.
    fields: []Field,
    /// Methods defined on the struct.
    methods: []MethodDecl,
    /// Attributes attached to the struct (e.g. `@serializable`).
    attributes: []Attribute,

    /// Traits this struct declares it implements, with any type arguments.
    impls: []TraitImpl,
    /// Whether the struct is part of the module's public surface.
    is_public: bool,

    /// Whether the struct has reference (class) rather than value semantics.
    /// Defaults to `true`; used by codegen to pick copy/ARC behaviour.
    is_reference: bool = true,

    /// Generic type parameters of the struct; empty when non-generic.
    type_params: []const []const u8 = &.{},
    /// Span of the whole struct declaration.
    span: Span,
};

/// A `union` type definition (a set of alternative field layouts under one
/// name).
///
/// Simpler than [`StructDecl`]: unions carry no methods or attributes at the
/// AST level, only their member fields.
pub const UnionDecl = struct {
    /// The union's name.
    name: []const u8,
    /// The union's member fields (the alternative layouts).
    fields: []Field,
    /// Whether the union is public.
    is_public: bool,
    /// Span of the declaration.
    span: Span,
};

/// A single named, typed field of a struct or union.
///
/// Unlike a [`Param`], a field's type is always present: the grammar requires
/// an annotation on every field.
pub const Field = struct {
    /// Field name.
    name: []const u8,
    /// Field type (always annotated).
    type_name: TypeRef,
    /// Whether the field is publicly accessible.
    is_public: bool,
    /// Field-level attributes (`@from`, `@derive`); empty for a plain field.
    attributes: []Attribute = &.{},
    /// Span of the field.
    span: Span,
};

/// A method on a struct or enum: a [`FunctionDecl`] plus the modifiers that
/// only make sense in a method position.
///
/// `is_static` distinguishes an associated function (no receiver) from an
/// instance method; visibility is tracked here rather than on the inner
/// `decl` so that method privacy is independent of the function's own
/// `is_exported`.
pub const MethodDecl = struct {
    /// Whether the method is callable from outside the type.
    is_public: bool,
    /// Whether the method is static (associated function, no `self` receiver).
    is_static: bool,
    /// The underlying function definition (signature + body).
    decl: FunctionDecl,
};

/// An `enum` definition: its variants, any methods, and whether it is an
/// exception type.
///
/// Nova enums may carry payloads (see [`Variant`]), so this covers both plain
/// C-style enums and sum types. `is_exception` marks enums that participate in
/// the `try`/`catch` error model as thrown error values.
pub const EnumDecl = struct {
    /// The enum's name.
    name: []const u8,
    /// The enum's variants in declaration order.
    variants: []Variant,
    /// Methods defined on the enum.
    methods: []MethodDecl,
    /// Attributes attached to the enum.
    attributes: []Attribute,
    /// Span of the declaration.
    span: Span,
    /// Whether this enum is an error type usable with `try`/`catch`.
    is_exception: bool = false,
};

/// One variant of an [`EnumDecl`].
///
/// A variant may be plain, have an explicit integer discriminant (`value`),
/// carry named payload fields (`fields`), or carry a single positional payload
/// type (`type_name`). These optional shapes are mutually exclusive in
/// practice; which are set reflects how the variant was written.
pub const Variant = struct {
    /// The variant's name.
    name: []const u8,
    /// An explicit integer discriminant, or `null` to auto-number.
    value: ?i64,
    /// Named payload fields for a struct-like variant, or `null`.
    fields: ?[]Field,
    /// A single positional payload type, or `null`.
    type_name: ?TypeRef,
    /// Span of the variant.
    span: Span,
};

/// A trait a struct claims to implement, with the type arguments supplied for
/// a generic trait.
///
/// Appears in [`StructDecl.impls`]. `type_args` is empty for a non-generic
/// trait such as `Display`, and populated for one like `Into<T>`.
pub const TraitImpl = struct {
    /// Name of the implemented trait.
    name: []const u8,
    /// Type arguments applied to a generic trait; empty otherwise.
    type_args: []TypeRef = &.{},
};

/// A `trait` interface definition: the set of methods a conforming type must
/// provide.
///
/// Traits may be generic (`type_params`) and their methods may supply a
/// `default_body` (see [`TraitMethodDecl`]), in which case an implementer can
/// omit that method.
pub const TraitDecl = struct {
    /// The trait's name.
    name: []const u8,
    /// The methods the trait requires or provides defaults for.
    methods: []TraitMethodDecl,
    /// Whether the trait is public.
    is_public: bool,

    /// Generic type parameters of the trait; empty when non-generic.
    type_params: []const []const u8 = &.{},
    /// Span of the declaration.
    span: Span,
};

/// One method signature inside a [`TraitDecl`].
///
/// This is a signature, not a full [`FunctionDecl`], because a trait method is
/// usually just a contract. When `default_body` is present the trait supplies a
/// default implementation and conforming types may leave it out.
pub const TraitMethodDecl = struct {
    /// The method's name.
    name: []const u8,
    /// The method's parameters.
    params: []Param,
    /// Declared return type, or `null` for void/inferred.
    ret_type: ?TypeRef,

    /// Whether the trait method is `async`.
    is_async: bool = false,
    /// A default body making the method optional to implement, or `null`.
    default_body: ?Block = null,
    /// Span of the method signature.
    span: Span,
};

/// A named constant declared at module scope.
///
/// The initialiser is an arbitrary [`Expression`]; whether it must be
/// compile-time evaluable is enforced later, not encoded in the AST.
pub const ConstDecl = struct {
    /// The constant's name.
    name: []const u8,
    /// The initialising expression.
    value: Expression,
    /// Whether the constant is exported from the module.
    is_exported: bool,
    /// Span of the declaration.
    span: Span,
};

/// An `import` statement bringing selected names from another module into
/// scope.
///
/// `module` is the module path; the specific names (and optional aliases)
/// pulled in are listed in `items`.
pub const ImportDecl = struct {
    /// The module path being imported from.
    module: []const u8,
    /// The individual names imported, each possibly aliased.
    items: []ImportItem,
    /// Span of the import.
    span: Span,
};

/// One imported name, optionally renamed with `as`.
pub const ImportItem = struct {
    /// The original name in the source module.
    name: []const u8,
    /// The local alias (`import { x as y }`), or `null` to keep `name`.
    alias: ?[]const u8,
    /// Span of the item.
    span: Span,
};

/// An explicit `export` of an already-declared name, tagged by what kind of
/// entity it refers to.
///
/// This is the standalone `export foo` form; note that declarations can also
/// carry their own `is_exported`/`is_public` flag directly.
pub const ExportDecl = struct {
    /// The name being exported.
    name: []const u8,
    /// Which kind of declaration the name refers to.
    kind: ExportKind,
    /// Span of the export.
    span: Span,
};

/// The category of thing an [`ExportDecl`] names.
///
/// The identifiers are quoted because they are Zig keywords used here as enum
/// tag names.
pub const ExportKind = enum {
    /// The exported name is a function.
    @"fn",
    /// The exported name is a struct.
    @"struct",
    /// The exported name is a constant.
    @"const",
};

/// A declaration attribute (`@...`), tagged by which attribute it is.
///
/// These drive framework and tooling behaviour rather than the language core:
/// `route`/`request_body`/`response` power the web/HTTP layer, `serializable`
/// drives serde codegen, `test` marks a test function, and
/// `summary`/`description`/`tags`/`deprecated` feed API documentation.
pub const Attribute = union(enum) {
    /// `@route(METHOD, PATH)` binding a handler to an HTTP route.
    route: RouteAttr,
    /// `@serializable` requesting serde code generation.
    serializable,
    /// `@test` marking a function as a test case.
    @"test",
    /// `@summary "..."` one-line API summary text.
    summary: []const u8,
    /// `@description "..."` longer API description text.
    description: []const u8,
    /// `@tags [...]` grouping tags for API documentation.
    tags: [][]const u8,
    /// `@request_body T` declaring the expected request body type.
    request_body: TypeRef,
    /// `@response(...)` declaring a documented response.
    response: ResponseAttr,
    /// `@deprecated` with an optional explanatory message.
    deprecated: ?[]const u8,
    /// `@from("source_col")` on a DTO field: the `...from` mapper spread fills
    /// this field from the named source field instead of by name convention.
    from: []const u8,
    /// `@derive(fnName)` on a DTO field: the `...from` mapper spread fills this
    /// field with `fnName(src)` (the whole source), for a computed value.
    derive: []const u8,
};

/// The payload of a `@route` attribute: HTTP method and path template.
pub const RouteAttr = struct {
    /// The HTTP method (e.g. `GET`, `POST`).
    method: []const u8,
    /// The route path template (e.g. `/users/{id}`).
    path: []const u8,
};

/// The payload of a `@response` attribute: one documented HTTP response.
pub const ResponseAttr = struct {
    /// The HTTP status code this response documents.
    status: i32,
    /// The body type returned for this status.
    type_ref: TypeRef,
    /// An optional human-readable description of the response.
    description: ?[]const u8,
};

/// A type reference as written in source, tagged by its type syntax.
///
/// This is a syntactic type, not a resolved one: `ident` is just a name the
/// checker later resolves. Compound forms nest via `*TypeRef` because a type
/// can contain itself (an optional of a generic of a func, and so on). Later
/// passes turn these into the compiler's real type representation.
pub const TypeRef = union(enum) {
    /// A bare named type, e.g. `int` or `User`.
    ident: []const u8,
    /// An optional `T?`, pointing at the wrapped element type.
    optional: *TypeRef,

    /// An error-union type pairing an `ok` payload with an `err` payload.
    error_union: struct {
        /// The success/value type.
        ok: *TypeRef,
        /// The error type.
        err: *TypeRef,
    },
    /// A fixed-length array `[N]T`.
    fixed_array: struct {
        /// The element type.
        element: *TypeRef,
        /// The compile-time element count.
        length: usize,
    },
    /// A generic application `Name<params...>`, e.g. `List<int>`.
    generic: struct {
        /// The generic type's name.
        name: []const u8,
        /// The type arguments applied to it.
        params: []TypeRef,
    },
    /// A function type `(params...) -> ret`.
    func: struct {
        /// Parameter types.
        params: []TypeRef,
        /// Return type.
        ret: *TypeRef,
    },
    /// A tuple type `(A, B, ...)` as an ordered list of element types.
    tuple: []TypeRef,
};

/// One statement inside a [`Block`], tagged by statement kind.
///
/// This is the imperative half of the tree. Control-flow statements
/// (`if`/`while`/`for`/`switch`) hold their nested bodies behind `*Statement`;
/// see [`IfStmt`], [`WhileStmt`], [`ForStmt`], and [`SwitchStmt`].
pub const Statement = union(enum) {
    /// A nested `{ ... }` block introducing its own scope.
    block: Block,
    /// A `let`/`const` binding.
    let_stmt: LetStmt,
    /// An expression evaluated for its effect.
    expr_stmt: ExprStmt,
    /// An `if`/`else` statement.
    if_stmt: IfStmt,
    /// A `while` loop.
    while_stmt: WhileStmt,
    /// A `for` loop (C-style or iterator form).
    for_stmt: ForStmt,
    /// A `switch` statement.
    switch_stmt: SwitchStmt,
    /// A `return` statement.
    return_stmt: ReturnStmt,
    /// A `break` statement.
    break_stmt: BreakStmt,
    /// A `continue` statement.
    continue_stmt: ContinueStmt,
    /// A `defer`/`errdefer` statement.
    defer_stmt: DeferStmt,
};

/// A brace-delimited sequence of statements forming one lexical scope.
///
/// Reused as a function body, a loop/branch body, and a `block_expr`.
pub const Block = struct {
    /// The statements in order.
    statements: []Statement,
    /// Span of the block.
    span: Span,
};

/// A `let` or `const` binding, including the destructuring form.
///
/// For a single binding `name` holds the identifier and `names` is `null`. For
/// a destructuring binding (`let [a, b] = ...`) `names` holds every bound name
/// and `name` is unused. `type_name` and `init` are each optional so that
/// annotation-only and initialiser-only declarations both parse.
pub const LetStmt = struct {
    /// The single bound name (or unused when destructuring).
    name: []const u8,
    /// The list of names for a destructuring binding, or `null`.
    names: ?[][]const u8,
    /// An explicit type annotation, or `null` to infer.
    type_name: ?TypeRef,
    /// The initialising expression, or `null` for a declaration without one.
    init: ?Expression,
    /// Whether this is a `const` (immutable) binding rather than `let`.
    is_const: bool,
    /// Span of the statement.
    span: Span,
};

/// A statement that just evaluates an expression (e.g. a call for its side
/// effect).
pub const ExprStmt = struct {
    /// The evaluated expression.
    expr: Expression,
    /// Span of the statement.
    span: Span,
};

/// A `defer` or `errdefer` statement scheduling an expression to run on scope
/// exit.
///
/// `is_err` distinguishes `errdefer` (runs only on the error path) from plain
/// `defer` (always runs).
pub const DeferStmt = struct {
    /// The expression to run at scope exit.
    expr: Expression,

    /// Whether this is `errdefer` (error-path only) rather than `defer`.
    is_err: bool = false,
    /// Span of the statement.
    span: Span,
};

/// An `if`/`else` statement.
///
/// Branches are `*Statement` so an arm may be a single statement or a nested
/// block; `else_branch` is `null` when there is no `else` (and can itself point
/// at another `if_stmt` for `else if` chains).
pub const IfStmt = struct {
    /// The condition expression.
    condition: Expression,
    /// The statement run when the condition is true.
    then_branch: *Statement,
    /// The statement run otherwise, or `null` for no `else`.
    else_branch: ?*Statement,
    /// Span of the statement.
    span: Span,
};

/// A `while` loop.
pub const WhileStmt = struct {
    /// The loop condition, tested before each iteration.
    condition: Expression,
    /// The loop body.
    body: *Statement,
    /// Span of the statement.
    span: Span,
};

/// A `for` loop, covering both the C-style and the iterator form.
///
/// The two forms are disjoint in practice. The C-style form uses
/// `initializer`/`condition`/`increment` and leaves `iterator` `null`; the
/// iterator form (`for x in xs`) sets `iterator` and leaves the three C-style
/// slots `null`. See [`ForIterator`].
pub const ForStmt = struct {
    /// C-style init statement, or `null` in the iterator form.
    initializer: ?*Statement,
    /// C-style loop condition, or `null` in the iterator form.
    condition: ?Expression,
    /// C-style per-iteration increment, or `null` in the iterator form.
    increment: ?Expression,
    /// Iterator-form binding and iterable, or `null` in the C-style form.
    iterator: ?ForIterator,
    /// The loop body.
    body: *Statement,
    /// Span of the statement.
    span: Span,
};

/// The `x in xs` part of an iterator-form [`ForStmt`].
pub const ForIterator = struct {
    /// What each element is bound to (single name or key/value destructure).
    binding: ForBinding,
    /// The expression being iterated over.
    iterable: *Expression,
};

/// How an iterator `for` loop binds each element.
///
/// Either a single item name, or a `key, value` destructure used when
/// iterating a map-like collection.
pub const ForBinding = union(enum) {
    /// Bind each element to one name.
    item: []const u8,
    /// Bind each entry's key and value to two names.
    destructure: struct { key: []const u8, value: []const u8 },
};

/// A range expression `start..end` / `start..=end`.
///
/// `inclusive` selects `..=` (include `end`) versus `..` (exclude it). Also
/// reachable as the [`ExprKind.range`] expression variant.
pub const RangeExpr = struct {
    /// The range's lower bound.
    start: *Expression,
    /// The range's upper bound.
    end: *Expression,
    /// Whether `end` is included (`..=`) or excluded (`..`).
    inclusive: bool,
    /// Span of the expression.
    span: Span,
};

/// A `switch` statement over a discriminant value.
///
/// Cases are matched in order; `default_case` is the fall-through arm and is
/// `null` when the switch has none. See [`SwitchCase`].
pub const SwitchStmt = struct {
    /// The value being matched.
    discriminant: Expression,
    /// The ordered case arms.
    cases: []SwitchCase,
    /// The `default` arm, or `null` if absent.
    default_case: ?*Statement,
    /// Span of the statement.
    span: Span,
};

/// One arm of a [`SwitchStmt`].
///
/// `values` lets a single arm match several patterns; `guard` is an optional
/// `if` condition that must also hold for the arm to fire.
pub const SwitchCase = struct {
    /// The pattern value(s) this arm matches.
    values: []Expression,
    /// An optional guard condition, or `null`.
    guard: ?Expression = null,
    /// The arm's body.
    body: *Statement,
    /// Span of the case.
    span: Span,
};

/// A `return` statement, with an optional returned value.
pub const ReturnStmt = struct {
    /// The returned expression, or `null` for a bare `return`.
    value: ?Expression,
    /// Span of the statement.
    span: Span,
};

/// A `break` statement (span only; Nova `break` carries no label or value).
pub const BreakStmt = struct {
    /// Span of the statement.
    span: Span,
};

/// A `continue` statement (span only).
pub const ContinueStmt = struct {
    /// Span of the statement.
    span: Span,
};

/// A stable per-expression identifier assigned after parsing.
///
/// Backed by a `u32` with `unassigned = 0` as the sentinel the parser leaves in
/// place; a later pass numbers every [`Expression`] so downstream analyses can
/// key side-tables (types, ownership facts) by id rather than by pointer. The
/// open `_` tag makes it a non-exhaustive enum, i.e. any `u32` value is legal.
pub const ExprId = enum(u32) { unassigned = 0, _ };

/// An expression node: its kind plus an identity and location.
///
/// Wrapping [`ExprKind`] in a struct lets every expression carry an [`ExprId`]
/// and a [`Span`] uniformly. `id` starts `unassigned` and is filled in later;
/// `span` defaults to a zeroed span so synthetic expressions built by the
/// compiler are valid without a real source location.
pub const Expression = struct {
    /// This expression's stable id, or `.unassigned` until numbered.
    id: ExprId = .unassigned,
    /// The expression's shape and payload.
    kind: ExprKind,
    /// Source location; a zeroed default suits compiler-synthesised nodes.
    span: Span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "" },
};

/// The shape of an [`Expression`], tagged by expression kind.
///
/// This is the largest union in the file and the core of the expression
/// grammar. Note the expression-oriented members (`if_expr`, `block_expr`) that
/// mirror statement forms, and the error/async members (`try_expr`,
/// `catch_expr`, `await_expr`, `go_expr`) that make error handling and
/// concurrency first-class expressions. Nested operands are held behind `*` for
/// the usual sizing reason.
pub const ExprKind = union(enum) {
    /// A literal value (see [`Literal`]).
    literal: Literal,
    /// A bare identifier reference.
    ident: []const u8,
    /// A binary operation (see [`BinaryExpr`]).
    binary: BinaryExpr,
    /// A unary operation (see [`UnaryExpr`]).
    unary: UnaryExpr,
    /// A function/method call.
    call: CallExpr,
    /// A call with explicit type arguments, e.g. `f<int>(...)`.
    generic_call: GenericCallExpr,
    /// A field access `obj.field`.
    field_access: FieldAccess,
    /// An index expression `obj[i]`.
    index: IndexExpr,
    /// A struct literal `Name { field: ... }`.
    struct_init: StructInit,
    /// An enum construction `Enum.Variant { ... }`.
    enum_init: EnumInit,
    /// A type cast `expr as T`.
    cast: CastExpr,

    /// A range expression (see [`RangeExpr`]).
    range: RangeExpr,
    /// Optional chaining `obj?.field`.
    optional_chaining: OptionalChaining,
    /// Nullish coalescing `a ?? b`.
    nullish_coalesce: NullishCoalesce,
    /// A JSX/NSX element literal (hypermedia templating).
    jsx_element: JsxElement,
    /// A closure/lambda.
    closure: Closure,
    /// A tuple literal as an ordered list of element expressions.
    tuple: []Expression,
    /// An `if` used as an expression yielding a value.
    if_expr: IfExpr,
    /// A block used as an expression, yielding its last value.
    block_expr: Block,

    /// A `try expr`: unwrap an error union or propagate its error.
    try_expr: *Expression,

    /// A `catch`: evaluate `expr`, and on error run `handler` with the error
    /// optionally bound to `err_name`.
    catch_expr: struct {
        /// The expression whose error is being caught.
        expr: *Expression,
        /// The name the caught error is bound to, or `null`.
        err_name: ?[]const u8,
        /// The handler expression producing the fallback value.
        handler: *Expression,
    },
    /// A template/interpolated-string expression (see [`TemplateExpr`]).
    template_expr: TemplateExpr,

    /// An `await expr` joining an async result (see [`AwaitExpr`]).
    await_expr: AwaitExpr,

    /// A `go`/`spawn expr` starting concurrent work; shares [`AwaitExpr`]'s
    /// single-operand shape.
    go_expr: AwaitExpr,
};

/// The operand of an `await` or `go`/`spawn` expression.
///
/// A one-field wrapper (operand + span) shared by both [`ExprKind.await_expr`]
/// and [`ExprKind.go_expr`], since both take exactly one expression.
pub const AwaitExpr = struct {
    /// The awaited/spawned expression.
    operand: *Expression,
    /// Span of the expression.
    span: Span,
};

/// A template string / interpolation expression.
///
/// `parts` is the ordered concatenation of literal chunks and interpolated
/// sub-expressions that together form the string.
pub const TemplateExpr = struct {
    /// The alternating literal and interpolated parts, in order.
    parts: []Expression,
    /// Span of the expression.
    span: Span,
};

/// An `if` used in expression position, yielding a value from one branch.
///
/// Unlike [`IfStmt`], both branches are mandatory (an expression must always
/// produce a value) and both are `*Expression` rather than statements.
pub const IfExpr = struct {
    /// The condition.
    condition: *Expression,
    /// The value when the condition is true.
    then_branch: *Expression,
    /// The value when the condition is false.
    else_branch: *Expression,
    /// Span of the expression.
    span: Span,
};

/// A literal value, tagged by literal kind.
///
/// `decimal` is kept as its original text (not parsed to a float) so the exact
/// decimal value survives to codegen, which matters for the `decimal128` type.
/// `null`/`undefined` are payload-free tags; the array/object forms hold nested
/// expressions.
pub const Literal = union(enum) {
    /// An integer literal.
    integer: i64,
    /// A binary floating-point literal.
    float: f64,

    /// A decimal literal preserved as source text for exact `decimal128` codegen.
    decimal: []const u8,
    /// A string literal (already unescaped).
    string: []const u8,
    /// A boolean literal.
    bool: bool,
    /// The `null` literal.
    null,
    /// The `undefined` literal.
    undefined,
    /// An array literal `[a, b, ...]`.
    array: []Expression,
    /// A repeated-element array literal `[value; count]` (see [`ArrayRepeat`]).
    array_repeat: ArrayRepeat,
    /// An object literal `{ field: value, ... }`.
    object: []ObjectFieldInit,
};

/// The payload of an `[value; count]` array-repeat literal.
pub const ArrayRepeat = struct {
    /// The element expression repeated `count` times.
    value: *Expression,
    /// The number of repetitions.
    count: usize,
};

/// One `name: value` field in an object literal, struct init, or enum init.
///
/// Shared across [`Literal.object`], [`StructInit.fields`], and
/// [`EnumInit.fields`].
pub const ObjectFieldInit = struct {
    /// The field's name.
    name: []const u8,
    /// The field's value expression.
    value: Expression,
    /// Span of the field initialiser.
    span: Span,
};

/// A binary operation `left op right`.
pub const BinaryExpr = struct {
    /// The left-hand operand.
    left: *Expression,
    /// The operator.
    op: BinaryOp,
    /// The right-hand operand.
    right: *Expression,
    /// Span of the expression.
    span: Span,
};

/// The set of binary operators.
///
/// `assign` is included here so assignment is parsed as a binary expression.
/// `And`/`Or` are capitalised because `and`/`or` are Zig keywords; they are the
/// short-circuiting logical operators, distinct from the bitwise `bit_and`/
/// `bit_or`.
pub const BinaryOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, gt, le, ge,

    bit_and, bit_or,

    bit_xor,
    assign,
    And,
    Or,
    shl,
    shr,
};

/// A unary operation `op operand`.
pub const UnaryExpr = struct {
    /// The operator.
    op: UnaryOp,
    /// The operand.
    operand: *Expression,
    /// Span of the expression.
    span: Span,
};

/// The set of unary operators: arithmetic negation, logical not, and bitwise
/// complement.
pub const UnaryOp = enum {
    /// Arithmetic negation `-x`.
    neg,
    /// Logical negation `!x`.
    not,

    /// Bitwise complement `~x`.
    bit_not,
};

/// A function or method call `callee(args...)`.
pub const CallExpr = struct {
    /// The expression being called.
    callee: *Expression,
    /// The argument expressions in order.
    args: []Expression,
    /// Span of the call.
    span: Span,
};

/// A call with explicit type arguments, `callee<type_args>(args...)`.
///
/// Distinct from [`CallExpr`] because the turbofish-style type arguments must
/// be carried to monomorphisation.
pub const GenericCallExpr = struct {
    /// The expression being called.
    callee: *Expression,
    /// The explicit type arguments.
    type_args: []TypeRef,
    /// The value arguments in order.
    args: []Expression,
    /// Span of the call.
    span: Span,
};

/// A field access `object.field`.
pub const FieldAccess = struct {
    /// The receiver expression.
    object: *Expression,
    /// The accessed field name.
    field: []const u8,
    /// Span of the access.
    span: Span,
};

/// An index expression `object[index]`.
pub const IndexExpr = struct {
    /// The indexed expression.
    object: *Expression,
    /// The index expression.
    index: *Expression,
    /// Span of the expression.
    span: Span,
};

/// A struct literal `Name { field: value, ... }`.
///
/// `type_args` carries any explicit type arguments for constructing a generic
/// struct (e.g. `Box<int> { ... }`) and is empty otherwise.
pub const StructInit = struct {
    /// The struct type's name.
    type_name: []const u8,
    /// The field initialisers.
    fields: []ObjectFieldInit,
    /// Explicit type arguments for a generic struct; empty otherwise.
    type_args: []TypeRef = &.{},
    /// The source expression of a `...from(expr)` spread, or `null` if the literal
    /// has no spread. When present, every target field not named explicitly in
    /// `fields` is filled by convention from a same-named (`_`/case-insensitive)
    /// field of this source struct; explicit fields win. See the mapper-spread
    /// section in `docs/specs.md`.
    spread: ?*Expression = null,
    /// Span of the literal.
    span: Span,
};

/// An enum construction `Enum.Variant { field: value, ... }`.
pub const EnumInit = struct {
    /// The enum type's name.
    enum_name: []const u8,
    /// The variant being constructed.
    variant: []const u8,
    /// The payload field initialisers.
    fields: []ObjectFieldInit,
    /// Span of the construction.
    span: Span,
};

/// A cast expression `expr as target_type`.
pub const CastExpr = struct {
    /// The value being cast.
    expr: *Expression,
    /// The type it is cast to.
    target_type: TypeRef,
    /// Span of the cast.
    span: Span,
};

/// An optional-chaining access `object?.field`.
///
/// Distinct from [`FieldAccess`] because it short-circuits to null when
/// `object` is null instead of accessing the field.
pub const OptionalChaining = struct {
    /// The (possibly null) receiver.
    object: *Expression,
    /// The field accessed when the receiver is present.
    field: []const u8,
    /// Span of the access.
    span: Span,
};

/// A nullish-coalescing expression `left ?? right`.
///
/// Yields `left` when it is present, otherwise evaluates `right`. See the
/// project memory for the value-optional `??` codegen subtleties this feeds.
pub const NullishCoalesce = struct {
    /// The primary expression, used when present.
    left: *Expression,
    /// The fallback expression, used when `left` is null.
    right: *Expression,
    /// Span of the expression.
    span: Span,
};

/// A JSX/NSX element `<tag attr=...>children</tag>` used for hypermedia
/// templating.
pub const JsxElement = struct {
    /// The element's tag name.
    tag: []const u8,
    /// The element's attributes.
    attributes: []JsxAttribute,
    /// The element's children (elements, expressions, text, or statements).
    children: []JsxChild,
    /// Span of the element.
    span: Span,
};

/// One attribute on a [`JsxElement`], `name=value`.
pub const JsxAttribute = struct {
    /// The attribute name.
    name: []const u8,
    /// The attribute value (literal string or embedded expression).
    value: JsxAttributeValue,
    /// Span of the attribute.
    span: Span,
};

/// The value of a [`JsxAttribute`]: either a literal string or an embedded
/// `{expression}`.
pub const JsxAttributeValue = union(enum) {
    /// A plain string attribute value.
    string_literal: []const u8,
    /// An embedded expression attribute value.
    expression: Expression,
};

/// One child of a [`JsxElement`], tagged by child kind.
///
/// Children may be nested elements, embedded expressions, literal text, or, for
/// control-flow inside markup, embedded statements.
pub const JsxChild = union(enum) {
    /// A nested JSX element.
    element: JsxElement,
    /// An embedded `{expression}` child.
    expression: Expression,
    /// Literal text content.
    text: []const u8,
    /// An embedded statement (e.g. a loop generating children).
    statement: Statement,
};

/// A closure/lambda literal.
///
/// `params` are the parameter names; `param_types` is a parallel array of
/// optional annotations (empty when none were written), so unannotated closure
/// parameters get their types from inference. The body is either a single
/// expression or a block (see [`ClosureBody`]).
pub const Closure = struct {
    /// The closure's parameter names.
    params: [][]const u8,

    /// Optional per-parameter type annotations, parallel to `params`; empty
    /// when the closure is written without annotations.
    param_types: []const ?TypeRef = &.{},
    /// The closure body.
    body: ClosureBody,
    /// Span of the closure.
    span: Span,
};

/// The body of a [`Closure`]: an expression-bodied `=> expr` form or a
/// brace-delimited block.
pub const ClosureBody = union(enum) {
    /// A single-expression body.
    expr: *Expression,
    /// A statement-block body.
    block: Block,
};
