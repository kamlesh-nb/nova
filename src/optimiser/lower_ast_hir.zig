// lower_ast_hir.zig — AST + TypedIr -> HIR.
//
// Desugar the AST (for/while-let/optional-chaining/coalesce/if-expr/interpolation/ternary -> if+loop+
// match; try/? -> explicit error-union branch) and attach the concrete post-monomorphisation TypeId to
// every node by resolving each ExprId through the sema TypedIr (expr_types_inst / expr_owned_inst /
// tp_resolve) under the active InstKey, exactly as codegen does today. Emit explicit hir.Retain on each
// owned acquisition and hir.Release on each owned scope-exit. See docs/design/optimiser.md. M0: stub.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const hir = @import("hir.zig");

// Lower one monomorphised function body to HIR. inst selects the instance (null = non-generic).
pub fn lowerFunc(allocator: std.mem.Allocator, fn_decl: ast.FunctionDecl, inst: ?hir.TypeId) !hir.Func {
    _ = allocator; // unused until the lowering is implemented (M1)
    _ = fn_decl;
    return hir.Func{ .sym = undefined, .inst = inst, .nodes = .empty, .entry = .{} };
}
