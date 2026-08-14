// hir.zig — High-level IR: a typed, desugared tree.
//
// HIR is the AST with Nova sugar removed and every node carrying a concrete post-monomorphisation
// TypeId. Desugaring makes implicit work explicit (for/while-let/optional-chaining/coalesce/if-expr/
// interpolation/ternary -> if+loop+match; try/? -> explicit error-union branch) and, crucially, makes
// ARC explicit: each owned acquisition emits a Retain, each owned scope-exit a Release, so later tiers
// can see and cancel them. See docs/design/optimiser.md. M0: definitions only.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const types = @import("../frontend/types.zig");

pub const TypeId = types.TypeId;
pub const SymbolId = types.SymbolId;

pub const HirId = enum(u32) { none = 0, _ };

pub const BinOp = enum { add, sub, mul, div, mod, @"and", @"or", eq, ne, lt, le, gt, ge, bit_and, bit_or, shl, shr };
pub const UnOp = enum { neg, not };

pub const Arm = struct {
    // A match arm: a pattern discriminant (variant symbol or literal) and its body.
    tag: ?SymbolId,
    body: Block,
};

pub const Block = struct {
    nodes: []const HirId = &.{},
};

// A HIR node. Every node has a TypeId (void for statements) and a source span for diagnostics and the
// differential shadow. This is illustrative of the intended set; it grows as lowering is implemented.
pub const Node = struct {
    kind: Kind,
    ty: TypeId,
    span: ast.Span,

    pub const Kind = union(enum) {
        // values
        literal: void,
        ident: SymbolId,
        field: struct { object: HirId, field: SymbolId },
        index: struct { object: HirId, idx: HirId },
        binop: struct { op: BinOp, lhs: HirId, rhs: HirId },
        unop: struct { op: UnOp, operand: HirId },
        call: struct { callee: SymbolId, args: []const HirId, takes_ownership: []const bool },
        indirect_call: struct { receiver: HirId, slot: u32, args: []const HirId },
        struct_init: struct { ty: TypeId, fields: []const HirId },

        // ARC, made explicit here (the whole point of the tier)
        retain: HirId,
        release: HirId,

        // control flow, desugared
        if_: struct { cond: HirId, then: Block, else_: Block },
        loop_: Block,
        match_: struct { scrutinee: HirId, arms: []const Arm },
        ret: ?HirId,
        brk: void,
        cont: void,

        // async, survives to LIR
        await_: HirId,
        spawn_: HirId,
    };
};

// A lowered function: a flat node table addressed by HirId plus the entry block.
pub const Func = struct {
    sym: SymbolId,
    inst: ?TypeId = null, // monomorphisation instance key, null for a non-generic function
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    entry: Block = .{},

    pub fn deinit(self: *Func, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }
};
