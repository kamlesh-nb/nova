//! Top-level command dispatcher for the `kyte` executable.
//!
//! This is the thin front door of the compiler CLI. It owns two things and
//! deliberately nothing else: the *allocator setup* every subcommand runs on,
//! and the *first-argument dispatch table* that routes `kyte <verb> ...` to the
//! module that actually implements the verb. All the real work lives elsewhere,
//! so this file stays a readable map of what the tool can do:
//!
//!   - `init` / `add feature` → [`scaffold`] (project + feature templates)
//!   - `test`                 → [`tester`]   (compile and run `@test` functions)
//!   - `fmt`                  → [`format`]   (the source formatter)
//!   - `get` / `restore` / `update` / `publish` → [`packages`] (the package manager)
//!   - anything else, including a bare `kyte <file.ky>` → [`builder`] (the build/link path)
//!
//! The build path is the fall-through case on purpose: the common invocation is
//! `kyte app.ky -o out`, where `args[1]` is a source file, not a verb. Rather
//! than special-casing "looks like a file", every unrecognised first argument is
//! handed to [`builder.cmdBuild`], which is where filename and flag parsing
//! properly lives.
//!
//! Allocator policy is decided here once and threaded into every subcommand: a
//! leak-checking [`std.heap.DebugAllocator`] in Debug builds (so `zig build`
//! test runs fail loudly on a leak via [`run`]'s `defer`), and the C allocator
//! in release builds for speed. An optional profiling wrapper
//! (`KYTE_ALLOC_PROFILE`) can sit on top of whichever base allocator is chosen.

const std = @import("std");
const builtin = @import("builtin");
/// Build-time constants injected by `build.zig` (the Kyte version string and
/// the runtime ABI version). Consumed only by the `version` subcommand in
/// [`run`]; kept out of the source tree so a release stamps its own numbers.
const build_options = @import("build_options");

/// Project and feature scaffolding: `kyte init ...` and `kyte add feature ...`.
const scaffold = @import("scaffold.zig");
/// The test runner: compiles the input and executes its `@test` functions.
const tester = @import("tester.zig");
/// The source formatter behind `kyte fmt`.
const format = @import("format.zig");
/// The package manager: `get`, `restore`, `update`, `publish`.
const packages = @import("packages.zig");
/// The compile-and-link path, and the catch-all for `kyte <file.ky>`.
const builder = @import("builder.zig");


/// Entry point for the `kyte` CLI: set up the allocator, then dispatch on the
/// first argument to the module that implements the requested verb.
///
/// The allocator chosen here is used by every subcommand. In Debug builds it is
/// a leak-detecting [`std.heap.DebugAllocator`] whose `defer` calls
/// `detectLeaks` and exits with status 1 if anything leaked, which is how the
/// build's own leak gate fails. Release builds use the faster C allocator with
/// no leak check. When `KYTE_ALLOC_PROFILE` is set in the environment an
/// [`allocprof.Profiler`] wraps that base allocator and dumps a profile on exit.
///
/// Dispatch is a linear string match on `args[1]`. Recognised verbs return
/// early; every other first argument (most importantly a source filename) falls
/// through to [`builder.cmdBuild`], so `kyte app.ky -o out` reaches the
/// builder without being treated as a subcommand. With fewer than two arguments
/// a usage line is printed and the process returns normally.
///
/// Propagates any error a subcommand returns; the caller maps it to an exit
/// status (see [`userErrorHint`] for the user-facing wording of known errors).
pub fn run(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const base_allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks() > 0) std.process.exit(1);
    };

    const allocprof = @import("allocprof.zig");
    const profile_alloc = std.c.getenv("KYTE_ALLOC_PROFILE") != null;
    var prof = allocprof.Profiler.init(base_allocator, std.heap.c_allocator);
    const allocator = if (profile_alloc) prof.allocator() else base_allocator;
    defer if (profile_alloc) prof.dump();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("Usage: kyte <file> [--wasm|--native] [-o <output>]\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        std.debug.print(
            \\kyte {s}
            \\  abi:    {d}    (extern-C runtime ABI contract; see docs/abi/runtime-abi.md)
            \\  zig:    {f}    (pinned; see .zig-version)
            \\  host:   {s}-{s}
            \\
        , .{
            build_options.kyte_version,
            build_options.kyte_abi_version,
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
        std.debug.print("Usage: kyte add feature <name>\n", .{});
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
    if (std.mem.eql(u8, args[1], "restore")) {
        try packages.cmdRestore(allocator, init);
        return;
    }
    if (std.mem.eql(u8, args[1], "update")) {
        try packages.cmdUpdate(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "publish")) {
        try packages.cmdPublish(allocator, init);
        return;
    }

    try builder.cmdBuild(allocator, init, args);
}

/// Maps a compiler error to a short human-readable hint, or `null` if the error
/// has no special user-facing wording.
///
/// This lets the top-level error reporter turn an internal Zig error tag into a
/// message that means something to a Kyte programmer. Two errors map to the
/// empty string rather than `null`: `error.TypeCheckError` and the parser's
/// `error.ExpectedToken` / `error.UnexpectedToken` already print their own
/// detailed diagnostics, so an empty hint suppresses a redundant generic line
/// while still marking them as "handled" (distinct from `null`, which means
/// "unknown error, fall back to the default reporting"). The remaining cases are
/// name-resolution and field-access failures given a plain-language gloss.
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
