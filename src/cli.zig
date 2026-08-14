// cli.zig — Nova command-line dispatch.
//
// The thin routing layer between the process entry (main.zig) and the command implementations. `run`
// parses argv[1], prints version/usage, and delegates to the matching command module. Each subcommand
// lives in its own file — scaffold (init/add), tester (test), format (fmt), packages (get), builder
// (build/bare-file) — all sitting on the shared pipeline.zig compile machinery.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const scaffold = @import("scaffold.zig");
const tester = @import("tester.zig");
const format = @import("format.zig");
const packages = @import("packages.zig");
const builder = @import("builder.zig");

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
        try scaffold.cmdInit(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "add")) {
        if (args.len >= 4 and std.mem.eql(u8, args[2], "feature")) {
            try scaffold.cmdAddFeature(allocator, init, args[3]);
            return;
        }
        std.debug.print("Usage: nova add feature <name>\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "test")) {
        try tester.cmdTest(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "fmt")) {
        try format.cmdFmt(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "get")) {
        try packages.cmdGet(allocator, init, args);
        return;
    }

    // `nova build ...` and the bare `nova <file> ...` compile form.
    try builder.cmdBuild(allocator, init, args);
}

// A user-facing compilation error (as opposed to a compiler bug) gets a clean one-line message and a
// non-zero exit instead of a Zig stack trace. Return null for errors that should surface as internal.
pub fn userErrorHint(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.TypeCheckError => "",
        error.ExpectedToken, error.UnexpectedToken => "",

        error.IdentifierNotFound => "undefined identifier",
        error.FunctionNotFound => "undefined function",
        error.VariableNotFound => "undefined variable",
        error.MethodOrFunctionNotFound => "no such method or function",
        error.AmbiguousName => "ambiguous name",
        error.StructTypeNotFound => "unknown struct type",
        error.FieldAccessObjectNotStruct => "field access on a non-struct value",
        else => null,
    };
}
