const std = @import("std");
const Io = std.Io;

pub const parser = @import("parser.zig");
pub const formatter = @import("formatter.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");

// F2: the type system (Type / TypeId / TypeStore). Deliberately not imported by
// the compiler yet — it is wired into codegen in F2 stage 2 under a shadow diff.
pub const types = @import("types.zig");

// F1: name resolution / the symbol table, and the shadow diff against legacy
// resolution.
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

// `zig build test` runs the tests of every file reachable from here. Zig only
// analyses what is referenced, so a file that is merely `@import`ed elsewhere in
// the tree still needs to appear below or its tests silently never run — and a
// test nobody runs is a comment.
test {
    std.testing.refAllDecls(@This());

    _ = @import("types.zig");

    // F4 4b: `codegen/types.zig` holds `mangleTypeName`, the ONE speller shared by
    // G3's destructors and 4b's method symbols. Its tests were written before this
    // line existed and passed a deliberately wrong expectation — because nothing
    // reached them. The comment above is not decorative.
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
