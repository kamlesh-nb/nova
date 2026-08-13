const std = @import("std");
const Io = std.Io;

pub const parser = @import("parser.zig");
pub const formatter = @import("formatter.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const type_checker = @import("type_checker.zig");

pub const types = @import("types.zig");

pub const symbols = @import("sema/symbols.zig");
pub const lower = @import("sema/lower.zig");
pub const infer = @import("sema/infer.zig");
pub const builtins = @import("sema/builtins.zig");
pub const alpha = @import("sema/alpha.zig");
pub const ids = @import("sema/ids.zig");
pub const subst = @import("sema/subst.zig");
pub const sema = @import("sema/sema.zig");
pub const mono = @import("sema/mono.zig");
pub const shadow = @import("sema/shadow.zig");

test {
    std.testing.refAllDecls(@This());

    _ = @import("types.zig");

    _ = @import("codegen/types.zig");
    _ = @import("codegen/arc.zig");

    _ = @import("sema/symbols.zig");
    _ = @import("sema/lower.zig");
    _ = @import("sema/infer.zig");
    _ = @import("sema/builtins.zig");
    _ = @import("sema/alpha.zig");
    _ = @import("sema/ids.zig");
    _ = @import("sema/subst.zig");
    _ = @import("sema/sema.zig");
    _ = @import("sema/mono.zig");
    _ = @import("sema/shadow.zig");

    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("ast.zig");
    _ = @import("formatter.zig");
}
