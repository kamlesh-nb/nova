// src/ast.zig
const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
    line: usize,
    col: usize,
    file: []const u8,
};

pub const Program = struct {
    declarations: []Declaration,
    span: Span,
};

pub const Declaration = union(enum) {
    fn_decl: FunctionDecl,
    struct_decl: StructDecl,
    union_decl: UnionDecl,
    enum_decl: EnumDecl,
    const_decl: ConstDecl,
    import_decl: ImportDecl,
    export_decl: ExportDecl,
    trait_decl: TraitDecl,
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: []Param,
    ret_type: ?TypeRef,
    body: Block,
    is_exported: bool,
    attributes: []Attribute, // @route, @summary, etc.
    // A2: generic type parameter names, e.g. ["T", "U"] for fn f<T, U>(...).
    // Empty for non-generic functions. Previously these were parsed and discarded.
    type_params: []const []const u8 = &.{},
    // M3-B: `async fn`. Async functions are compiled as LLVM coroutines (M3-C).
    is_async: bool = false,
    // T3 FFI: `extern("lib") fn name(...): ret;` — a foreign C-ABI function with no
    // Nova body. When set, `body` is empty; codegen emits an LLVM *external* declaration
    // (C-mapped signature, symbol == `name`, no mangling) and the linker adds `-l<lib>`.
    extern_lib: ?[]const u8 = null,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    type_name: ?TypeRef,
    span: Span,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []Field,
    methods: []MethodDecl,
    attributes: []Attribute, // @serializable
    // Traits this struct implements. `type_args` carries the trait's type
    // arguments for a generic trait, e.g. `impl Handler<GetUser, UserDto>` →
    // { name: "Handler", type_args: [GetUser, UserDto] }. Empty for a plain
    // `impl Foo`. (Flagship: generic traits.)
    impls: []TraitImpl,
    is_public: bool,
    // A2: generic type parameter names, e.g. ["K", "V"] for struct Map<K, V>.
    // Empty for non-generic structs. Previously these were parsed and discarded.
    type_params: []const []const u8 = &.{},
    span: Span,
};

pub const UnionDecl = struct {
    name: []const u8,
    fields: []Field,
    is_public: bool,
    span: Span,
};

pub const Field = struct {
    name: []const u8,
    type_name: TypeRef,
    is_public: bool,
    span: Span,
};

pub const MethodDecl = struct {
    is_public: bool,
    is_static: bool,
    decl: FunctionDecl,
};

pub const EnumDecl = struct {
    name: []const u8,
    variants: []Variant,
    methods: []MethodDecl,
    attributes: []Attribute,
    span: Span,
};

pub const Variant = struct {
    name: []const u8,
    value: ?i64, // optional explicit integer value
    fields: ?[]Field,
    type_name: ?TypeRef,
    span: Span,
};

pub const TraitImpl = struct {
    name: []const u8,
    type_args: []TypeRef = &.{},
};

pub const TraitDecl = struct {
    name: []const u8,
    methods: []TraitMethodDecl,
    is_public: bool,
    // Generic type parameter names, e.g. ["Q", "R"] for `trait Handler<Q, R>`.
    // Empty for a non-generic trait. (Flagship: generic traits.)
    type_params: []const []const u8 = &.{},
    span: Span,
};

pub const TraitMethodDecl = struct {
    name: []const u8,
    params: []Param,
    ret_type: ?TypeRef,
    // A1 async-first seam: `async fn query(...)` in a trait declares the method's dynamic
    // dispatch as a coroutine — the vtable slot holds its ramp, and a call site drives it to
    // completion (sync ctx) or awaits it (async ctx). Impls must match this async-ness.
    is_async: bool = false,
    span: Span,
};

pub const ConstDecl = struct {
    name: []const u8,
    value: Expression,
    is_exported: bool,
    span: Span,
};

pub const ImportDecl = struct {
    module: []const u8,
    items: []ImportItem,
    span: Span,
};

pub const ImportItem = struct {
    name: []const u8,
    alias: ?[]const u8,
    span: Span,
};

pub const ExportDecl = struct {
    name: []const u8,
    kind: ExportKind,
    span: Span,
};

pub const ExportKind = enum {
    @"fn",
    @"struct",
    @"const",
};

pub const Attribute = union(enum) {
    route: RouteAttr,
    serializable,
    @"test",
    summary: []const u8,
    description: []const u8,
    tags: [][]const u8,
    request_body: TypeRef,
    response: ResponseAttr,
};

pub const RouteAttr = struct {
    method: []const u8,
    path: []const u8,
};

pub const ResponseAttr = struct {
    status: i32,
    type_ref: TypeRef,
    description: ?[]const u8,
};

pub const TypeRef = union(enum) {
    ident: []const u8,
    optional: *TypeRef,             // T | undefined
    /// `T | E` — an ERROR UNION (specs §3.4b). Exactly one of the two, never both:
    /// unlike Go's `(T, error)` there is no nil-error slot to forget to check.
    ///
    /// `ok` may itself be `.optional`, which is how `T | E | undefined` is represented —
    /// read as `(T | undefined) | E`. That is the 404-vs-500 shape: `undefined` means
    /// absence (not an error), `E` means failure (log it). Member order is irrelevant;
    /// the parser classifies rather than folding left-to-right.
    error_union: struct {
        ok: *TypeRef,
        err: *TypeRef,
    },
    fixed_array: struct {          // T[N]
        element: *TypeRef,
        length: usize,
    },
    generic: struct {              // List<T>, Dict<K, V>, etc.
        name: []const u8,
        params: []TypeRef,
    },
    func: struct {                 // (T, U) -> V
        params: []TypeRef,
        ret: *TypeRef,
    },
    tuple: []TypeRef,
};

pub const Statement = union(enum) {
    block: Block,
    let_stmt: LetStmt,
    expr_stmt: ExprStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    switch_stmt: SwitchStmt,
    return_stmt: ReturnStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    defer_stmt: DeferStmt,
};

pub const Block = struct {
    statements: []Statement,
    span: Span,
};

pub const LetStmt = struct {
    name: []const u8,
    names: ?[][]const u8, // For destructuring e.g. let (x, y) = ...
    type_name: ?TypeRef,
    init: ?Expression,
    is_const: bool,
    span: Span,
};

pub const ExprStmt = struct {
    expr: Expression,
    span: Span,
};

pub const DeferStmt = struct {
    expr: Expression,
    // E1: `errdefer e` runs `e` ONLY when the enclosing fn returns on the ERROR path of an
    // error union (an explicit error return, or a `try` that propagates). Plain `defer` runs
    // at every scope exit. Same AST node, discriminated here.
    is_err: bool = false,
    span: Span,
};

pub const IfStmt = struct {
    condition: Expression,
    then_branch: *Statement,
    else_branch: ?*Statement,
    span: Span,
};

pub const WhileStmt = struct {
    condition: Expression,
    body: *Statement,
    span: Span,
};

pub const ForStmt = struct {
    initializer: ?*Statement,
    condition: ?Expression,
    increment: ?Expression,
    iterator: ?ForIterator,
    body: *Statement,
    span: Span,
};

/// A `for … in` loop's binding and iterable. When `ForStmt.iterator` is non-null the loop is a for-in
/// (init/condition/increment are unused); when null it is the C-style `for (init; cond; incr)`.
pub const ForIterator = struct {
    binding: ForBinding,
    iterable: *Expression, // a range (`a..b`) or a collection
};

pub const ForBinding = union(enum) {
    item: []const u8, // `for (x in xs)`
    destructure: struct { key: []const u8, value: []const u8 }, // `for ((k, v) in map)`
};

pub const RangeExpr = struct {
    start: *Expression,
    end: *Expression,
    inclusive: bool, // `..=` true, `..` false
    span: Span,
};

pub const SwitchStmt = struct {
    discriminant: Expression,
    cases: []SwitchCase,
    default_case: ?*Statement,
    span: Span,
};

pub const SwitchCase = struct {
    values: []Expression,
    body: *Statement,
    span: Span,
};

pub const ReturnStmt = struct {
    value: ?Expression,
    span: Span,
};

pub const BreakStmt = struct {
    span: Span,
};

pub const ContinueStmt = struct {
    span: Span,
};

/// F2 stage 4a: a stable per-expression identity that SURVIVES COPYING.
///
/// Stage 2i keyed the TypedIr on the expression's address and stage 3 measured the
/// consequence: codegen takes AST nodes BY VALUE (compileStatement/compileExpression),
/// so a pointer taken inside is a stack address and the lookup misses — 1113 of 6596
/// resolutions, and no amount of site-fixing moved it, because it is structural.
/// An id lives IN the node, so a copy carries it.
pub const ExprId = enum(u32) { unassigned = 0, _ };

/// The expression itself. `kind` is what the union used to be; `id` is assigned by
/// a post-parse pass (sema/ids.zig), so construction sites do not have to supply one.
pub const Expression = struct {
    id: ExprId = .unassigned,
    kind: ExprKind,
};

pub const ExprKind = union(enum) {
    literal: Literal,
    ident: []const u8,
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    generic_call: GenericCallExpr,
    field_access: FieldAccess,
    index: IndexExpr,
    struct_init: StructInit,
    enum_init: EnumInit,
    cast: CastExpr,
    /// `a..b` (exclusive) / `a..=b` (inclusive) — a numeric range. Today it exists only to drive a
    /// `for i in a..b` loop (codegen desugars it to a counting `while`); it is not yet a first-class
    /// value type.
    range: RangeExpr,
    optional_chaining: OptionalChaining,
    nullish_coalesce: NullishCoalesce,
    jsx_element: JsxElement,
    closure: Closure,
    tuple: []Expression,
    if_expr: IfExpr,
    block_expr: Block,
    /// `try f()` — specs §3.4b. NOT an exception `try`: if `f()` returned the error side,
    /// return that error from the ENCLOSING function; otherwise yield the unwrapped ok value.
    /// A branch on a value. No unwinding, nothing for ARC to miss, no UB under coroutines.
    try_expr: *Expression,
    /// `f() catch 8080` or `f() catch (e) { … }` — specs §3.4b. The failure-side twin of `??`.
    /// `handler` yields the value on the error path; when `err_name` is set it is bound to the
    /// unwrapped ERROR (a plain enum), so `switch (e)` works on it.
    catch_expr: struct {
        expr: *Expression,
        err_name: ?[]const u8,
        handler: *Expression,
    },
    template_expr: TemplateExpr,
    // M3-B: `await <expr>` — suspends the enclosing async fn until the awaited
    // Future/task completes, yielding its value. Lowered to llvm.coro.suspend (M3-C).
    await_expr: AwaitExpr,
    // M3-D-4: `go <async-call>` launches the call as a concurrent task and yields a
    // Future handle; `await <future>` later retrieves its result. Lowered to a ramp
    // call + nova_sched_schedule (no suspend).
    go_expr: AwaitExpr,
};

pub const AwaitExpr = struct {
    operand: *Expression,
    span: Span,
};

pub const TemplateExpr = struct {
    parts: []Expression,
    span: Span,
};

pub const IfExpr = struct {
    condition: *Expression,
    then_branch: *Expression,
    else_branch: *Expression,
    span: Span,
};

pub const Literal = union(enum) {
    integer: i64,
    float: f64,
    /// specs §3.1: a `decimal` literal (`10.5m`) — the digit string, kept verbatim so codegen hands the
    /// EXACT text to the runtime's decimal128 parser (no lossy f64 round-trip).
    decimal: []const u8,
    string: []const u8,
    bool: bool,
    null,
    undefined,
    array: []Expression,
    object: []ObjectFieldInit,
};

pub const ObjectFieldInit = struct {
    name: []const u8,
    value: Expression,
    span: Span,
};

pub const BinaryExpr = struct {
    left: *Expression,
    op: BinaryOp,
    right: *Expression,
    span: Span,
};

pub const BinaryOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, gt, le, ge,
    // BITWISE `&` / `|` (parseBitwiseAnd/Or). Named `@"and"`/`@"or"` until the
    // `and`/`or` keywords were replaced by `&&`/`||`; the names outlived the
    // keywords and read as the LOGICAL pair, which is `.And`/`.Or` below.
    bit_and, bit_or,
    // BITWISE XOR `^` (parseBitwiseXor). C-family precedence: `&` > `^` > `|`.
    bit_xor,
    assign,
    And,
    Or,
    shl,
    shr,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expression,
    span: Span,
};

pub const UnaryOp = enum {
    neg,
    not,
    // BITWISE NOT `~` — one's complement of an integer (lowers to `xor x, -1`).
    bit_not,
};

pub const CallExpr = struct {
    callee: *Expression,
    args: []Expression,
    span: Span,
};

pub const GenericCallExpr = struct {
    callee: *Expression,
    type_args: []TypeRef,
    args: []Expression,
    span: Span,
};

pub const FieldAccess = struct {
    object: *Expression,
    field: []const u8,
    span: Span,
};

pub const IndexExpr = struct {
    object: *Expression,
    index: *Expression,
    span: Span,
};

pub const StructInit = struct {
    type_name: []const u8,
    fields: []ObjectFieldInit,
    span: Span,
};

pub const EnumInit = struct {
    enum_name: []const u8,
    variant: []const u8,
    fields: []ObjectFieldInit, // for payload
    span: Span,
};

pub const CastExpr = struct {
    expr: *Expression,
    target_type: TypeRef,
    span: Span,
};

pub const OptionalChaining = struct {
    object: *Expression,
    field: []const u8,
    span: Span,
};

pub const NullishCoalesce = struct {
    left: *Expression,
    right: *Expression,
    span: Span,
};

pub const JsxElement = struct {
    tag: []const u8,
    attributes: []JsxAttribute,
    children: []JsxChild,
    span: Span,
};

pub const JsxAttribute = struct {
    name: []const u8,
    value: JsxAttributeValue,
    span: Span,
};

pub const JsxAttributeValue = union(enum) {
    string_literal: []const u8,
    expression: Expression,
};

pub const JsxChild = union(enum) {
    element: JsxElement,
    expression: Expression,
    text: []const u8,
    statement: Statement,
};

pub const Closure = struct {
    params: [][]const u8,
    // Optional per-param type annotations, parallel to `params` (`(s: string) => ...`).
    // Empty when no param was annotated; an entry is null for an unannotated param in an
    // otherwise-annotated list. When present, codegen types the param directly from this
    // (authoritative over the call-site inference in the typed IR).
    param_types: []const ?TypeRef = &.{},
    body: ClosureBody,
    span: Span,
};

pub const ClosureBody = union(enum) {
    expr: *Expression,
    block: Block,
};