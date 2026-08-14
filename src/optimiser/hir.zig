// hir.zig — High-level IR: a typed, desugared tree over a flat node table.
//
// HIR is the AST with Nova sugar being removed and (as lowering matures) every node carrying a concrete
// post-monomorphisation TypeId. It is stored as a flat table addressed by HirId so later tiers walk it
// cheaply. ARC becomes explicit here: each owned acquisition emits a Retain, each owned scope-exit a
// Release (added once ownership threading lands). See docs/design/optimiser.md.
//
// M1a: the node set + a builder. AST->HIR lowering (lower_ast_hir.zig) targets the core forms; anything
// not yet handled lowers to `.unsupported` so the pass never crashes on real code and coverage is
// measurable. HIR->MIR->LIR are the next checkpoints.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../frontend/types.zig");

pub const TypeId = types.TypeId;
pub const SymbolId = types.SymbolId;

pub const HirId = enum(u32) { none = 0xFFFF_FFFF, _ };

pub const BinOp = enum { add, sub, mul, div, mod, @"and", @"or", eq, ne, lt, le, gt, ge, bit_and, bit_or, bit_xor, shl, shr, assign };
pub const UnOp = enum { neg, not, bit_not };

// A desugared block: an ordered list of statement/expression node ids.
pub const Block = struct {
    nodes: []const HirId = &.{},
};

pub const Arm = struct {
    tag: ?SymbolId,
    body: Block,
};

pub const Node = struct {
    kind: Kind,
    ty: TypeId = @enumFromInt(0), // filled by lowering once ExprId->TypeId threading lands (M1b)
    span: ast.Span,

    pub const Kind = union(enum) {
        // literals
        int: i64,
        float: f64,
        bool: bool,
        str: []const u8,
        null,
        undefined,
        // references
        ident: []const u8,
        field: struct { object: HirId, name: []const u8 },
        index: struct { object: HirId, idx: HirId },
        // operators
        binop: struct { op: BinOp, lhs: HirId, rhs: HirId },
        unop: struct { op: UnOp, operand: HirId },
        // calls
        call: struct { callee: HirId, args: []const HirId },
        generic_call: struct { callee: HirId, args: []const HirId }, // type_args resolved via TypeId later
        // aggregates
        struct_init: struct { type_name: []const u8, fields: []const HirId },
        enum_init: struct { name: []const u8, variant: []const u8, fields: []const HirId },
        tuple: []const HirId,
        // desugar targets that keep a value
        if_expr: struct { cond: HirId, then: HirId, else_: HirId },
        nullish: struct { lhs: HirId, rhs: HirId }, // a ?? b
        optional_chain: struct { object: HirId, name: []const u8 },
        template: []const HirId,
        range: struct { start: HirId, end: HirId, inclusive: bool },
        cast: HirId, // operand; target type carried in .ty once threaded
        closure: struct { body: HirId }, // lifted separately by the backend; opaque body ref for now
        try_: HirId,
        // ARC (made explicit as ownership threading lands)
        retain: HirId,
        release: HirId,
        // statements / control (desugared)
        let: struct { name: []const u8, value: ?HirId },
        assign: struct { target: HirId, value: HirId },
        ret: ?HirId,
        brk,
        cont,
        if_: struct { cond: HirId, then: Block, else_: Block },
        loop_: struct { cond: ?HirId, body: Block }, // cond == null => infinite loop
        block: Block,
        // async
        await_: HirId,
        spawn_: HirId,
        // a form not yet lowered; carries the AST tag name for coverage reporting
        unsupported: []const u8,
    };
};

// A lowered function: a flat node table plus the entry block.
pub const Func = struct {
    name: []const u8,
    sym: ?SymbolId = null,
    inst: ?TypeId = null,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    entry: Block = .{},

    pub fn deinit(self: *Func, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    // Append a node and return its id.
    pub fn add(self: *Func, allocator: std.mem.Allocator, node: Node) !HirId {
        const id: HirId = @enumFromInt(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return id;
    }

    pub fn get(self: *const Func, id: HirId) Node {
        return self.nodes.items[@intFromEnum(id)];
    }

    // Count nodes that are still `.unsupported` (a coverage metric for the shadow harness).
    pub fn unsupportedCount(self: *const Func) usize {
        var n: usize = 0;
        for (self.nodes.items) |node| {
            if (node.kind == .unsupported) n += 1;
        }
        return n;
    }
};
