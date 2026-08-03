
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
    attributes: []Attribute,

    type_params: []const []const u8 = &.{},

    is_async: bool = false,

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
    attributes: []Attribute,

    impls: []TraitImpl,
    is_public: bool,

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
    value: ?i64,
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

    type_params: []const []const u8 = &.{},
    span: Span,
};

pub const TraitMethodDecl = struct {
    name: []const u8,
    params: []Param,
    ret_type: ?TypeRef,

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
    optional: *TypeRef,

    error_union: struct {
        ok: *TypeRef,
        err: *TypeRef,
    },
    fixed_array: struct {
        element: *TypeRef,
        length: usize,
    },
    generic: struct {
        name: []const u8,
        params: []TypeRef,
    },
    func: struct {
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
    names: ?[][]const u8,
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

pub const ForIterator = struct {
    binding: ForBinding,
    iterable: *Expression,
};

pub const ForBinding = union(enum) {
    item: []const u8,
    destructure: struct { key: []const u8, value: []const u8 },
};

pub const RangeExpr = struct {
    start: *Expression,
    end: *Expression,
    inclusive: bool,
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

pub const ExprId = enum(u32) { unassigned = 0, _ };

pub const Expression = struct {
    id: ExprId = .unassigned,
    kind: ExprKind,
    // Source location of this expression. Defaulted (line 0 = "unset") so the many synthesized/desugared
    // Expression literals across the compiler keep compiling; the parser sets it for user-written primary
    // expressions (e.g. identifiers) so diagnostics can point at file:line:col.
    span: Span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "" },
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

    range: RangeExpr,
    optional_chaining: OptionalChaining,
    nullish_coalesce: NullishCoalesce,
    jsx_element: JsxElement,
    closure: Closure,
    tuple: []Expression,
    if_expr: IfExpr,
    block_expr: Block,

    try_expr: *Expression,

    catch_expr: struct {
        expr: *Expression,
        err_name: ?[]const u8,
        handler: *Expression,
    },
    template_expr: TemplateExpr,

    await_expr: AwaitExpr,

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

    decimal: []const u8,
    string: []const u8,
    bool: bool,
    null,
    undefined,
    array: []Expression,
    array_repeat: ArrayRepeat,
    object: []ObjectFieldInit,
};

// `[value; count]` -- a fixed array of `count` elements all initialized to `value`. count is a
// compile-time constant (fixed length); value is evaluated once and filled by a codegen loop.
pub const ArrayRepeat = struct {
    value: *Expression,
    count: usize,
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

    bit_and, bit_or,

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
    // F4-1: explicit type args from `Foo<int>{ ... }`. Empty when the literal is unparameterised
    // (`Foo{ ... }`) and T is left to field inference. When present these are AUTHORITATIVE: sema
    // binds them positionally to the struct's type params and validates the fields against them.
    type_args: []TypeRef = &.{},
    span: Span,
};

pub const EnumInit = struct {
    enum_name: []const u8,
    variant: []const u8,
    fields: []ObjectFieldInit,
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

    param_types: []const ?TypeRef = &.{},
    body: ClosureBody,
    span: Span,
};

pub const ClosureBody = union(enum) {
    expr: *Expression,
    block: Block,
};
