const std = @import("std");
const Io = std.Io;

pub const parser = @import("frontend/parser.zig");
pub const formatter = @import("frontend/formatter.zig");
pub const ast = @import("frontend/ast.zig");
pub const lexer = @import("frontend/lexer.zig");
pub const type_checker = @import("frontend/type_checker.zig");

pub const types = @import("frontend/types.zig");

pub const symbols = @import("frontend/sema/symbols.zig");
pub const lower = @import("frontend/sema/lower.zig");
pub const infer = @import("frontend/sema/infer.zig");
pub const builtins = @import("frontend/sema/builtins.zig");
pub const alpha = @import("frontend/sema/alpha.zig");
pub const ids = @import("frontend/sema/ids.zig");
pub const subst = @import("frontend/sema/subst.zig");
pub const sema = @import("frontend/sema/sema.zig");
pub const mono = @import("frontend/sema/mono.zig");
pub const shadow = @import("frontend/sema/shadow.zig");

test {
    std.testing.refAllDecls(@This());

    _ = @import("frontend/types.zig");

    _ = @import("backend/codegen/types.zig");
    _ = @import("backend/codegen/arc.zig");

    _ = @import("frontend/sema/symbols.zig");
    _ = @import("frontend/sema/lower.zig");
    _ = @import("frontend/sema/infer.zig");
    _ = @import("frontend/sema/builtins.zig");
    _ = @import("frontend/sema/alpha.zig");
    _ = @import("frontend/sema/ids.zig");
    _ = @import("frontend/sema/subst.zig");
    _ = @import("frontend/sema/sema.zig");
    _ = @import("frontend/sema/mono.zig");
    _ = @import("frontend/sema/shadow.zig");
    _ = @import("frontend/sema/ossa/ir.zig");

    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/ast.zig");
    _ = @import("frontend/formatter.zig");

    // (HIR/MIR/LIR LLVM-emit optimiser scrapped 2026-08-16; see docs/design/sil-arc-optimiser-direction.md.)
}
