// cli.zig — Nova command-line dispatch.
//
// The thin routing layer between the process entry (main.zig) and the command implementations
// (commands.zig). `run` parses argv[1], prints version/usage, and delegates to the matching command.
// All the real work — the compile/link/test pipeline, scaffolding, formatting, package fetch — lives in
// commands.zig; this file stays a readable table of "which subcommand does what".

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const commands = @import("commands.zig");

pub fn run(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("Usage: nova <file> [--wasm|--native] [-o <output>]\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        // L5 stability: report the language/toolchain version, the runtime ABI contract version,
        // the pinned Zig, and the host target -- all from single sources of truth (build_options).
        std.debug.print(
            \\nova {s}
            \\  abi:    {d}    (extern-C runtime ABI contract; see docs/abi/runtime-abi.md)
            \\  zig:    {f}    (pinned; see .zig-version)
            \\  host:   {s}-{s}
            \\
        , .{
            build_options.nova_version,
            build_options.nova_abi_version,
            builtin.zig_version,
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
        });
        return;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        try commands.cmdInit(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "add")) {
        if (args.len >= 4 and std.mem.eql(u8, args[2], "feature")) {
            try commands.cmdAddFeature(allocator, init, args[3]);
            return;
        }
        std.debug.print("Usage: nova add feature <name>\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "test")) {
        try commands.cmdTest(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "fmt")) {
        try commands.cmdFmt(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "get")) {
        try commands.cmdGet(allocator, init, args);
        return;
    }

    // `nova build ...` and the bare `nova <file> ...` compile form.
    try commands.cmdBuild(allocator, init, args);
}
