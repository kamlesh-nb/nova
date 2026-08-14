// main.zig — process entry point for the `nova` executable.
//
// Kept deliberately thin (SE-refactor 2026-08-14): the entry wrapper lives here because Zig looks for
// `pub fn main` in the exe's root source file (see build.zig). Argument dispatch is in cli.zig; the
// command implementations and the compile/link pipeline are in commands.zig.

const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    cli.run(init) catch |e| {
        if (cli.userErrorHint(e)) |hint| {
            if (hint.len > 0) {
                std.debug.print("\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m {s}\x1b[0m (compilation failed)\n", .{hint});
            }
            std.process.exit(1);
        }
        return e;
    };
}
