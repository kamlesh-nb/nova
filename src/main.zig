// src/main.zig
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");

// In-process LLD (P5 #20): when nova was built with -Dinprocess-lld, these are
// provided by src/linker/lld_link.cpp (linked against native liblld*.a) and nova
// links its output executables itself, with no clang/ld shell-out. argv[0] is the
// linker name; args are exactly what ld64.lld / wasm-ld would receive.
extern fn nova_lld_link_macho(argv: [*]const [*:0]const u8, argc: c_int) c_int;
extern fn nova_lld_link_wasm(argv: [*]const [*:0]const u8, argc: c_int) c_int;

// T6/Phase-2 link-time dead-code elimination flag for the `clang++` link paths. Mach-O atomises so
// -dead_strip drops unreferenced symbols with no -ffunction-sections; ELF needs --gc-sections (and,
// for full effect, function-sections on the object — a later refinement). Passed via -Wl, to clang.
const dead_strip_flag: []const u8 = if (builtin.target.os.tag == .macos) "-Wl,-dead_strip" else "-Wl,--gc-sections";

// Resolve the macOS SDK path for -syslibroot: SDKROOT, else the Command Line
// Tools SDK, else the Xcode SDK. (The -platform_version SDK/min are fixed at
// 11.0 — ld64.lld only needs a plausible value; broad-compat deployment target.)
fn macSdkPath(environ: anytype, io: std.Io) []const u8 {
    if (environ.get("SDKROOT")) |s| return s;
    const clt = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
    Io.Dir.access(.cwd(), io, clt, .{}) catch {
        return "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    };
    return clt;
}

// Link `obj_path` (+ nova runtime + wolfSSL) into `output_path` with in-process
// ld64.lld, reconstructing the args the clang driver would hand the linker.
// T3 FFI: collect the distinct library names from every `extern("lib") fn` in the program.
// Order-preserving dedup so `-l` flags are stable and each lib appears once.
fn collectFfiLibs(allocator: std.mem.Allocator, program: ast.Program) ![]const []const u8 {
    var libs = std.ArrayList([]const u8).empty;
    for (program.declarations) |decl| {
        if (decl != .fn_decl) continue;
        const lib = decl.fn_decl.extern_lib orelse continue;
        var seen = false;
        for (libs.items) |existing| {
            if (std.mem.eql(u8, existing, lib)) {
                seen = true;
                break;
            }
        }
        if (!seen) try libs.append(allocator, lib);
    }
    return libs.toOwnedSlice(allocator);
}

// T3 FFI / W1: emit the link flags for one `extern("lib")` library. Most libs become a
// plain `-l<lib>` (resolved from system + `-L` search paths). `webview` is a VENDORED dep:
// link its static lib by path and pull in the macOS WebKit/Cocoa frameworks its WKWebView
// backend needs (there is no `-lwebview` on the search path, and frameworks are not `-l`).
fn appendFfiLib(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, shared_nova: []const u8, io: std.Io, lib: []const u8) !void {
    if (std.mem.eql(u8, lib, "webview")) {
        const lib_path = try std.fmt.allocPrint(allocator, "{s}/deps/webview/build/libwebview.a", .{shared_nova});
        Io.Dir.access(.cwd(), io, lib_path, .{}) catch {
            std.debug.print("webview requested but {s} is not built\n", .{lib_path});
            return error.LinkFailed;
        };
        try args.append(allocator, lib_path);
        if (builtin.target.os.tag == .macos) {
            try args.appendSlice(allocator, &.{ "-framework", "WebKit", "-framework", "Cocoa" });
        }
        return;
    }
    try args.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
}

fn linkNativeInProcessMacho(
    allocator: std.mem.Allocator,
    environ: anytype,
    io: std.Io,
    objs: []const []const u8,
    output_path: []const u8,
    shared_nova: []const u8,
    ffi_libs: []const []const u8,
) !void {
    const sdk_path = macSdkPath(environ, io);
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{
        "ld64.lld",             "-arch", "arm64",
        "-platform_version",    "macos", "11.0", "11.0",
        "-syslibroot",          sdk_path,
        "-lSystem",             "-lc++",
        // T6/Phase-2 dead-code strip: Mach-O atomises symbols, so ld64's -dead_strip drops every
        // function/global unreferenced from the entry point — a real app links only what it USES out of
        // the stdlib. Measured 1.33MB → 390KB on the sample web app (~71%), runs identically.
        "-dead_strip",
    });
    for (objs) |o| try args.append(allocator, o); // T6 split: one or many object files
    const nova_lib = try std.fmt.allocPrint(allocator, "-L{s}/lib", .{shared_nova});
    try args.appendSlice(allocator, &.{ nova_lib, "-lnova_runtime", "-L/opt/homebrew/lib" });
    try appendWolfsslLink(&args, allocator, shared_nova, io);
    for (ffi_libs) |lib| {
        try appendFfiLib(&args, allocator, shared_nova, io, lib);
    }
    try args.appendSlice(allocator, &.{ "-o", output_path });

    // Build the null-terminated C argv the shim expects.
    var cargv = std.ArrayList([*:0]const u8).empty;
    defer cargv.deinit(allocator);
    for (args.items) |a| try cargv.append(allocator, try allocator.dupeZ(u8, a));

    const rc = nova_lld_link_macho(cargv.items.ptr, @intCast(cargv.items.len));
    if (rc != 0) {
        std.debug.print("in-process LLD (macho) failed with code {d}\n", .{rc});
        return error.LinkFailed;
    }
}

// T1 — cross-compilation via the bundled Zig toolchain. `zig c++` ships libc (musl/glibc) + CRT and
// cross-links ELF/COFF, so a macOS host can PRODUCE (and, given musl `-static`, run anywhere) a
// Linux/Windows binary. Given the LLVM target triple, map it to a Zig target, cross-build the C++
// runtime for that target ONCE (cached at `~/.nova/lib/nova_runtime_<zigtriple>.o`), and link the
// Nova objects against it with `zig c++`. Returns true when it handled the link (a non-host target);
// false to fall through to the host in-process-LLD / clang++ path. TLS is stubbed on cross targets
// for now (the runtime is built without -DNOVA_HAVE_WOLFSSL — wolfSSL cross-build is a follow-on).
const CrossTarget = struct { zig: []const u8, static: bool };
fn mapCrossTarget(llvm_triple: []const u8) ?CrossTarget {
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    const arm = has(llvm_triple, "aarch64") or has(llvm_triple, "arm64");
    if (has(llvm_triple, "linux"))
        return .{ .zig = if (arm) "aarch64-linux-musl" else "x86_64-linux-musl", .static = true };
    if (has(llvm_triple, "windows") or has(llvm_triple, "mingw") or has(llvm_triple, "w64"))
        return .{ .zig = if (arm) "aarch64-windows-gnu" else "x86_64-windows-gnu", .static = false };
    if (has(llvm_triple, "darwin") or has(llvm_triple, "apple")) {
        // Native mac is handled by the host path; only take over when the arch differs from the host.
        const host_arm = builtin.target.cpu.arch == .aarch64;
        if (arm == host_arm) return null;
        return .{ .zig = if (arm) "aarch64-macos" else "x86_64-macos", .static = false };
    }
    return null;
}

fn crossLinkViaZig(
    allocator: std.mem.Allocator,
    environ: anytype,
    io: std.Io,
    llvm_triple: []const u8,
    objs: []const []const u8,
    output_path: []const u8,
    shared_nova: []const u8,
    is_release: bool,
) !bool {
    const target = mapCrossTarget(llvm_triple) orelse return false;

    // Cross-build the runtime for this target once, then cache it.
    const rt_obj = try std.fmt.allocPrint(allocator, "{s}/lib/nova_runtime_{s}.o", .{ shared_nova, target.zig });
    if (Io.Dir.access(.cwd(), io, rt_obj, .{})) |_| {} else |_| {
        // Boost = the vendored Asio-only header subset synced to ~/.nova/deps/boost (no Homebrew).
        const boost_inc = if (environ.get("BOOST_PREFIX")) |bp|
            try std.fmt.allocPrint(allocator, "-I{s}/include", .{bp})
        else
            try std.fmt.allocPrint(allocator, "-I{s}/deps/boost/include", .{shared_nova});
        const rt_src = try std.fmt.allocPrint(allocator, "{s}/src/runtime/runtime.cpp", .{shared_nova});
        std.debug.print("[T1] cross-compiling the C++ runtime for {s} (one-time; caches to ~/.nova/lib) ...\n", .{target.zig});
        const rc_args = [_][]const u8{ "zig", "c++", "-target", target.zig, "-std=c++20", "-O2", "-DNOVA_DROP_ARENA", boost_inc, "-c", rt_src, "-o", rt_obj };
        var rc_child = try std.process.spawn(io, .{ .argv = &rc_args });
        switch (try rc_child.wait(io)) {
            .exited => |code| if (code != 0) {
                std.debug.print("[T1] runtime cross-compile failed for {s} (code {d})\n", .{ target.zig, code });
                return error.LinkFailed;
            },
            else => return error.LinkFailed,
        }
    }

    // Link the Nova objects + cross runtime via `zig c++`.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "zig", "c++", "-target", target.zig });
    if (target.static) try args.append(allocator, "-static");
    if (is_release) try args.append(allocator, "-O3");
    for (objs) |o| try args.append(allocator, o); // T6 split: one or many object files
    try args.append(allocator, rt_obj);
    // Windows: the runtime + Boost.Asio use winsock2 (WSAStartup/socket/select via ws2_32) and Asio's
    // IOCP backend needs mswsock. The `#pragma comment(lib, ...)` in io.cpp isn't honored by lld-link
    // here, so link the system import libs explicitly.
    if (std.mem.indexOf(u8, target.zig, "windows") != null)
        try args.appendSlice(allocator, &.{ "-lws2_32", "-lmswsock" });
    try args.appendSlice(allocator, &.{ "-o", output_path });
    var child = try std.process.spawn(io, .{ .argv = args.items });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            std.debug.print("[T1] cross-link failed for {s} (code {d})\n", .{ target.zig, code });
            return error.LinkFailed;
        },
        else => return error.LinkFailed,
    }
    return true;
}

// Link `obj_path` into `output_path` (.wasm) with in-process wasm-ld. The wasm
// target is freestanding (-nostdlib + host imports) so there is nothing to link
// but the one object — the same args clang forwarded via -Wl,.
fn linkWasmInProcess(allocator: std.mem.Allocator, obj_path: []const u8, output_path: []const u8) !void {
    const argv = [_][]const u8{
        "wasm-ld", "--no-entry", "--export-all", "--export-memory", "--allow-undefined",
        // The bump allocator places its arena at heap_start and the persistent
        // arena at heap_start+32MB, and never grows memory — so the module must
        // ship enough initial memory to cover both (128MB). (Growing the heap on
        // demand is the proper long-term fix.)
        "--initial-memory=134217728",
        obj_path, "-o", output_path,
    };
    var cargv = std.ArrayList([*:0]const u8).empty;
    defer cargv.deinit(allocator);
    for (argv) |a| try cargv.append(allocator, try allocator.dupeZ(u8, a));

    const rc = nova_lld_link_wasm(cargv.items.ptr, @intCast(cargv.items.len));
    if (rc != 0) {
        std.debug.print("in-process LLD (wasm) failed with code {d}\n", .{rc});
        return error.LinkFailed;
    }
}

// M3-D-5: link the vendored wolfSSL static lib when it was built (TLS enabled). Kept
// in sync with build.zig's NOVA_HAVE_WOLFSSL guard: both key off the .a existing.
// macOS needs the Security/CoreFoundation frameworks (Apple native cert validation).
fn appendWolfsslLink(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, shared_nova: []const u8, io: std.Io) !void {
    const lib_path = std.fmt.allocPrint(allocator, "{s}/deps/wolfssl/build/libwolfssl.a", .{shared_nova}) catch return;
    Io.Dir.access(.cwd(), io, lib_path, .{}) catch return; // not built → TLS stubbed, skip
    try args.append(allocator, lib_path);
    if (builtin.target.os.tag == .macos) {
        try args.append(allocator, "-framework");
        try args.append(allocator, "Security");
        try args.append(allocator, "-framework");
        try args.append(allocator, "CoreFoundation");
    }
}

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const llvm_codegen = @import("codegen/llvm_codegen.zig");
const type_checker = @import("type_checker.zig");
const sema_shadow = @import("sema/shadow.zig");
const sema_alpha = @import("sema/alpha.zig");
const sema_ids = @import("sema/ids.zig");
const sema_mod = @import("sema/sema.zig");
const sema_mono = @import("sema/mono.zig");
const ast = @import("ast.zig");
const formatter = @import("formatter.zig");

const templates = @import("templates.zig");

fn getSharedAssetPath(allocator: std.mem.Allocator, init: std.process.Init, relative_path: []const u8) ![]const u8 {
    if (Io.Dir.access(.cwd(), init.io, relative_path, .{})) |_| {
        return try allocator.dupe(u8, relative_path);
    } else |_| {}

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    return try std.fmt.allocPrint(allocator, "{s}/.nova/{s}", .{ home, relative_path });
}

fn resolveImportPath(base_path: []const u8, module_name: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ![]const u8 {
    if (std.mem.startsWith(u8, module_name, "std/")) {
        const sub = module_name[4..];
        return try std.fmt.allocPrint(allocator, "src/std/{s}.nova", .{sub});
    }
    const std_modules = [_][]const u8{ "net/tcp/socket", "net/tcp/server", "net/tcp/client", "net/tls", "net/asyncio", "net/asynctls", "web/request", "web/response", "web/mime", "web/status", "web/methods", "web/server", "web/client", "web/mediator", "web/routing", "web/middleware", "web/url", "web/cookie", "web/cors", "web/request_id", "web/redact", "web/secure_headers", "web/body_limit", "web/recovery", "web/rate_limit", "web/multipart", "web/session", "web/csrf", "web/di", "web/controller", "web/router", "web/app", "web/logger", "concurrency/fiber", "concurrency/channel", "concurrency/asyncchan", "concurrency/atomic", "concurrency/async_util", "concurrency/actor", "io/file", "io/dir", "collections/list", "collections/map", "collections/set", "collections/string_builder", "serde/json", "serde/source", "serde/bson", "serde/yaml", "mem/allocator", "mem/arena_allocator", "mem/memory", "string", "datetime", "math", "assert", "traits", "env", "crypto/sha", "crypto/md5", "crypto/base64", "crypto/random", "crypto/scram", "process", "fs", "exception", "data/db", "data/sql/pool", "text/utf8", "text/regex", "webview", "web/static_content", "web/circuit_breaker", "resilience/breaker" };
    for (std_modules) |m| {
        if (std.mem.eql(u8, module_name, m)) {
            return try std.fmt.allocPrint(allocator, "src/std/{s}.nova", .{module_name});
        }
    }
    if (std.mem.eql(u8, module_name, "list")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/list.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "map")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/map.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "set")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/set.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "string_builder")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/string_builder.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "db")) {
        return try std.fmt.allocPrint(allocator, "src/std/data/db.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "pool")) {
        return try std.fmt.allocPrint(allocator, "src/std/data/sql/pool.nova", .{});
    }
    // The concrete DB drivers (postgres/mysql/mssql/btreedb) live in `packages/` — resolved
    // below via resolveFromLocalPackages (dev checkout) or the package cache (installed), like
    // any other package. The `db` seam + generic `pool` stay in std (the shared vocabulary).
    if (resolveFromLocalPackages(module_name, allocator, io)) |local_hit| {
        return local_hit;
    }
    const dir_end = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
    const dir = if (dir_end == 0) "" else base_path[0..dir_end];
    if (dir.len == 0) {
        return try std.fmt.allocPrint(allocator, "{s}.nova", .{module_name});
    }

    var current_len = dir.len;
    while (current_len > 0) {
        const current_dir = dir[0..current_len];
        // 1. Check parent_dir/src/module_name.nova
        const src_candidate = try std.fmt.allocPrint(allocator, "{s}/src/{s}.nova", .{ current_dir, module_name });
        if (Io.Dir.access(.cwd(), io, src_candidate, .{})) |_| {
            return src_candidate;
        } else |_| {
            allocator.free(src_candidate);
        }

        // 2. Check parent_dir/module_name.nova
        const dir_candidate = try std.fmt.allocPrint(allocator, "{s}/{s}.nova", .{ current_dir, module_name });
        if (Io.Dir.access(.cwd(), io, dir_candidate, .{})) |_| {
            return dir_candidate;
        } else |_| {
            allocator.free(dir_candidate);
        }

        // Walk up to parent directory
        const last_slash = std.mem.lastIndexOfScalar(u8, current_dir, '/') orelse break;
        current_len = last_slash;
    }

    // Project-root fallback: `src/<module>.nova` relative to the CWD. Lets files OUTSIDE src/
    // (e.g. a `tests/` tree) import project modules by their dotted path — the walk-up above
    // starts at the importing file's dir and never reaches the sibling `src/`.
    {
        const root_src = try std.fmt.allocPrint(allocator, "src/{s}.nova", .{module_name});
        if (Io.Dir.access(.cwd(), io, root_src, .{})) |_| {
            return root_src;
        } else |_| {
            allocator.free(root_src);
        }
    }

    // Package-manager resolution: a module provided by a FETCHED dependency lives under
    // `~/.nova/cache/<repo>/`. `nova get` populates that tree from `project.json`; here we let
    // an `import <module>` bind to it. Search each cached package's `src/<module>.nova` (the
    // conventional layout) then its `<module>.nova` root. Manifest drives fetching; the cache
    // drives resolution — so the resolver needs no manifest parse of its own.
    if (resolveFromPackageCache(module_name, allocator, io, home)) |cache_hit| {
        return cache_hit;
    }

    // Default fallback: direct join relative to base_path's dir
    return try std.fmt.allocPrint(allocator, "{s}/{s}.nova", .{ dir, module_name });
}

/// Search `~/.nova/cache/*/` for a module provided by a fetched dependency.
/// Returns an owned absolute path (caller frees) on the first hit, else null.
fn resolveFromPackageCache(module_name: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ?[]const u8 {
    const home_dir = home orelse return null;

    const cache_root = std.fmt.allocPrint(allocator, "{s}/.nova/cache", .{home_dir}) catch return null;
    defer allocator.free(cache_root);

    const dir = Io.Dir.openDir(.cwd(), io, cache_root, .{ .iterate = true }) catch return null;
    defer Io.Dir.close(dir, io);

    var it = Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const suffixes = [_][]const u8{ "src", "" };
        for (suffixes) |suffix| {
            const candidate = if (suffix.len == 0)
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}.nova", .{ cache_root, entry.name, module_name }) catch continue
            else
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}.nova", .{ cache_root, entry.name, suffix, module_name }) catch continue;
            if (Io.Dir.access(.cwd(), io, candidate, .{})) |_| {
                return candidate;
            } else |_| {
                allocator.free(candidate);
            }
        }
    }
    return null;
}

/// Search the repo's local `packages/nova-<module>/src/<module>.nova` (a dev checkout) for a
/// package-provided module — how the DB drivers, moved OUT of std into `packages/`, resolve in
/// tree without a `nova get` into the cache. Tries `packages/` (CWD = the driver's own project
/// root) and `../packages/` (CWD = the `lang/` compiler project, where the corpus + build run).
/// Returns an owned path on the first hit, else null; the installed path stays the package cache.
fn resolveFromLocalPackages(module_name: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const roots = [_][]const u8{ "packages", "../packages" };
    for (roots) |root| {
        const candidate = std.fmt.allocPrint(allocator, "{s}/nova-{s}/src/{s}.nova", .{ root, module_name, module_name }) catch continue;
        if (Io.Dir.access(.cwd(), io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

fn generateControllerRoutes(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration)) !void {
    for (declarations.items) |*decl| {
        if (decl.* == .struct_decl) {
            var s = &decl.struct_decl;
            var implements_controller = false;
            for (s.impls) |impl| {
                if (std.mem.eql(u8, impl.name, "Controller")) {
                    implements_controller = true;
                    break;
                }
            }
            if (!implements_controller) continue;

            var has_register_routes = false;
            for (s.methods) |method| {
                if (std.mem.eql(u8, method.decl.name, "registerRoutes")) {
                    has_register_routes = true;
                    break;
                }
            }
            if (has_register_routes) continue;

            var statements = std.ArrayList(ast.Statement).empty;
            defer statements.deinit(allocator);

            // 1. let ctrl = self;
            const let_ctrl = ast.Statement{
                .let_stmt = .{
                    .name = "ctrl",
                    .names = null,
                    .type_name = null,
                    .init = ast.Expression{ .kind = .{ .ident = "self" } },
                    .is_const = false,
                    .span = s.span,
                }
            };
            try statements.append(allocator, let_ctrl);

            // 2. Add router.add call for each method with route attributes
            for (s.methods) |method| {
                for (method.decl.attributes) |attr| {
                    if (attr == .route) {
                        const route = attr.route;

                        // Callee: router.add
                        const callee = try allocator.create(ast.Expression);
                        callee.* = ast.Expression{ .kind = .{ .field_access = .{
                                .object = try allocator.create(ast.Expression),
                                .field = "add",
                                .span = s.span,
                            } } };
                        callee.kind.field_access.object.* = ast.Expression{ .kind = .{ .ident = "router" } };

                        // Closure: (req) => ctrl.method_name(req)
                        const closure_param_names = try allocator.alloc([]const u8, 1);
                        closure_param_names[0] = "req";

                        const call_expr_callee = try allocator.create(ast.Expression);
                        call_expr_callee.* = ast.Expression{ .kind = .{ .field_access = .{
                                .object = try allocator.create(ast.Expression),
                                .field = method.decl.name,
                                .span = s.span,
                            } } };
                        call_expr_callee.kind.field_access.object.* = ast.Expression{ .kind = .{ .ident = "ctrl" } };

                        const call_expr_args = try allocator.alloc(ast.Expression, 1);
                        call_expr_args[0] = ast.Expression{ .kind = .{ .ident = "req" } };

                        const closure_body_expr = try allocator.create(ast.Expression);
                        closure_body_expr.* = ast.Expression{ .kind = .{ .call = .{
                                .callee = call_expr_callee,
                                .args = call_expr_args,
                                .span = s.span,
                            } } };

                        const closure_expr = ast.Expression{ .kind = .{
                            .closure = .{
                                .params = closure_param_names,
                                .body = .{ .expr = closure_body_expr },
                                .span = s.span,
                            },
                        } };

                        // router.add arguments
                        const add_args = try allocator.alloc(ast.Expression, 3);
                        add_args[0] = ast.Expression{ .kind = .{ .literal = .{ .string = route.method } } };
                        add_args[1] = ast.Expression{ .kind = .{ .literal = .{ .string = route.path } } };
                        add_args[2] = closure_expr;

                        const add_call = ast.Expression{ .kind = .{ .call = .{
                                .callee = callee,
                                .args = add_args,
                                .span = s.span,
                            } } };

                        const route_stmt = ast.Statement{
                            .expr_stmt = .{
                                .expr = add_call,
                                .span = s.span,
                            }
                        };
                        try statements.append(allocator, route_stmt);
                    }
                }
            }

            const method_body = ast.Block{
                .statements = try statements.toOwnedSlice(allocator),
                .span = s.span,
            };

            const register_routes_fn = ast.FunctionDecl{
                .name = "registerRoutes",
                .params = try allocator.alloc(ast.Param, 2),
                .ret_type = ast.TypeRef{ .ident = "void" },
                .body = method_body,
                .is_exported = false,
                .attributes = &.{},
                .span = s.span,
            };
            register_routes_fn.params[0] = .{
                .name = "self",
                .type_name = ast.TypeRef{ .ident = s.name },
                .span = s.span,
            };
            register_routes_fn.params[1] = .{
                .name = "router",
                .type_name = ast.TypeRef{ .ident = "Router" },
                .span = s.span,
            };

            const method_decl = ast.MethodDecl{
                .is_public = true,
                .is_static = false,
                .decl = register_routes_fn,
            };

            var new_methods = try allocator.alloc(ast.MethodDecl, s.methods.len + 1);
            @memcpy(new_methods[0..s.methods.len], s.methods);
            new_methods[s.methods.len] = method_decl;
            s.methods = new_methods;
        }
    }
}

// --- serde: generate a `<Struct>__bind(src: ValueSource): <Struct>` deserializer for
// every @serializable struct (recursive over nested @serializable structs and lists).
// Generated as source text and reparsed — far simpler than hand-building AST, and the
// binder resolves against the merged program (requires `import serde.source`). ---

fn serdeIsInt(n: []const u8) bool {
    const ints = [_][]const u8{ "i8", "u8", "byte", "i16", "u16", "short", "ushort", "i32", "u32", "int", "uint", "i64", "u64", "long", "ulong" };
    for (ints) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}
fn serdeIsFloat(n: []const u8) bool {
    // `decimal` is DELIBERATELY not here — it is exact (128-bit BID) and routes to getDecimal /
    // itemDecimal, not the lossy f64 getFloat. See the decimal branches in generateSerdeBinders.
    const fs = [_][]const u8{ "f32", "f64", "float", "double" };
    for (fs) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

fn serdeAppendf(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    try list.appendSlice(allocator, s);
}

fn generateSerdeBinders(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
    var serializable = std.StringHashMap(void).init(allocator);
    defer serializable.deinit();
    for (declarations.items) |decl| {
        if (decl == .struct_decl) {
            for (decl.struct_decl.attributes) |a| {
                if (a == .serializable) {
                    try serializable.put(decl.struct_decl.name, {});
                    break;
                }
            }
        }
    }
    if (serializable.count() == 0) return;

    var src = std.ArrayList(u8).empty; // leaked on purpose — the reparsed AST references it

    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        const s = decl.struct_decl;
        if (!serializable.contains(s.name)) continue;

        try serdeAppendf(&src, allocator, "fn {s}__bind(src: ValueSource): {s} {{\n    let obj = {s}();\n", .{ s.name, s.name, s.name });
        for (s.fields) |f| {
            const fname = f.name;
            switch (f.type_name) {
                .ident => |tn| {
                    if (std.mem.eql(u8, tn, "string")) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = src.getString(\"{s}\");\n", .{ fname, fname });
                    } else if (serdeIsInt(tn)) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = src.getInt(\"{s}\");\n", .{ fname, fname });
                    } else if (std.mem.eql(u8, tn, "bool")) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = src.getBool(\"{s}\");\n", .{ fname, fname });
                    } else if (std.mem.eql(u8, tn, "decimal")) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = src.getDecimal(\"{s}\");\n", .{ fname, fname });
                    } else if (serdeIsFloat(tn)) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = src.getFloat(\"{s}\");\n", .{ fname, fname });
                    } else if (serializable.contains(tn)) {
                        try serdeAppendf(&src, allocator, "    obj.{s} = {s}__bind(src.getChild(\"{s}\"));\n", .{ fname, tn, fname });
                    }
                },
                .generic => |g| {
                    if (std.mem.eql(u8, g.name, "List") and g.params.len == 1) {
                        try serdeAppendf(&src, allocator, "    {{ let __n = src.arrayLen(\"{s}\"); let __i = 0; while (__i < __n) {{ ", .{fname});
                        switch (g.params[0]) {
                            .ident => |en| {
                                if (std.mem.eql(u8, en, "string")) {
                                    try serdeAppendf(&src, allocator, "obj.{s}.push(src.itemString(\"{s}\", __i));", .{ fname, fname });
                                } else if (std.mem.eql(u8, en, "decimal")) {
                                    try serdeAppendf(&src, allocator, "obj.{s}.push(src.itemDecimal(\"{s}\", __i));", .{ fname, fname });
                                } else if (serdeIsInt(en)) {
                                    try serdeAppendf(&src, allocator, "obj.{s}.push(src.itemInt(\"{s}\", __i));", .{ fname, fname });
                                } else if (serializable.contains(en)) {
                                    try serdeAppendf(&src, allocator, "obj.{s}.push({s}__bind(src.itemChild(\"{s}\", __i)));", .{ fname, en, fname });
                                }
                            },
                            else => {},
                        }
                        try serdeAppendf(&src, allocator, " __i = __i + 1; }} }}\n", .{});
                    }
                },
                else => {},
            }
        }
        try src.appendSlice(allocator, "    return obj;\n}\n\n");

        // --- <S>__toJson(obj): string  (symmetric serializer; string-concat based) ---
        try serdeAppendf(&src, allocator, "fn {s}__toJson(obj: {s}): string {{\n    let out = \"{{\";\n", .{ s.name, s.name });
        var first = true;
        for (s.fields) |f| {
            const fname = f.name;
            const comma = if (first) "" else ",";
            switch (f.type_name) {
                .ident => |tn| {
                    if (std.mem.eql(u8, tn, "string")) {
                        try serdeAppendf(&src, allocator, "    out = out + \"{s}\\\"{s}\\\":\" + json.quote(obj.{s});\n", .{ comma, fname, fname });
                        first = false;
                    } else if (serdeIsInt(tn) or std.mem.eql(u8, tn, "bool")) {
                        try serdeAppendf(&src, allocator, "    out = out + \"{s}\\\"{s}\\\":\" + obj.{s};\n", .{ comma, fname, fname });
                        first = false;
                    } else if (std.mem.eql(u8, tn, "decimal")) {
                        // Exact decimal as an UNQUOTED JSON number (`${}` gives its BID text, no f64 hop).
                        try serdeAppendf(&src, allocator, "    out = out + \"{s}\\\"{s}\\\":\" + `${{obj.{s}}}`;\n", .{ comma, fname, fname });
                        first = false;
                    } else if (serializable.contains(tn)) {
                        try serdeAppendf(&src, allocator, "    out = out + \"{s}\\\"{s}\\\":\" + {s}__toJson(obj.{s});\n", .{ comma, fname, tn, fname });
                        first = false;
                    }
                    // f32/f64 float fields skipped (f64 stringify gap); decimal handled above
                },
                .generic => |g| {
                    if (std.mem.eql(u8, g.name, "List") and g.params.len == 1) {
                        var item: ?[]const u8 = null;
                        switch (g.params[0]) {
                            .ident => |en| {
                                if (std.mem.eql(u8, en, "string")) {
                                    item = try std.fmt.allocPrint(allocator, "json.quote(obj.{s}.get(__i) ?? \"\")", .{fname});
                                } else if (std.mem.eql(u8, en, "decimal")) {
                                    item = try std.fmt.allocPrint(allocator, "`${{obj.{s}.get(__i) ?? 0m}}`", .{fname});
                                } else if (serdeIsInt(en)) {
                                    item = try std.fmt.allocPrint(allocator, "(obj.{s}.get(__i) ?? 0)", .{fname});
                                } else if (serializable.contains(en)) {
                                    item = try std.fmt.allocPrint(allocator, "{s}__toJson(obj.{s}.get(__i) ?? {s}())", .{ en, fname, en });
                                }
                            },
                            else => {},
                        }
                        if (item) |itemexpr| {
                            try serdeAppendf(&src, allocator, "    out = out + \"{s}\\\"{s}\\\":[\";\n", .{ comma, fname });
                            try serdeAppendf(&src, allocator, "    {{ let __i = 0; while (__i < obj.{s}.size()) {{ if (__i > 0) {{ out = out + \",\"; }} out = out + {s}; __i = __i + 1; }} }}\n", .{ fname, itemexpr });
                            try src.appendSlice(allocator, "    out = out + \"]\";\n");
                            first = false;
                        }
                    }
                },
                else => {},
            }
        }
        try src.appendSlice(allocator, "    out = out + \"}\";\n    return out;\n}\n\n");
    }

    if (src.items.len == 0) return;

    var p = try parser.Parser.init(allocator, src.items, "<serde-generated>", is_wasm);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("serde binder generation failed to parse:\n{s}\n", .{src.items});
        return err;
    };
    for (prog.declarations) |d| {
        try declarations.append(allocator, d);
    }
}

// --- mediator (flagship): for every `struct H impl RequestHandler<Q, R>`, generate
// a typed route dispatch `__mediator_dispatch_<Q>(src: ValueSource): string` that
// binds the request (Q__bind), instantiates + runs the handler, and serializes the
// response (R__toJson). This IS the compile-time handler discovery — the dispatch
// embeds the handler, so `app.get<Q>(path)` needs no handler argument. Generated as
// source and reparsed, like the serde binders; must run AFTER them (uses Q__bind /
// R__toJson) and requires Q, R to be @serializable. ---
fn generateMediatorDispatch(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
    var src = std.ArrayList(u8).empty; // leaked on purpose — the reparsed AST references it
    var by_name = std.ArrayList(u8).empty; // body of __mediator_dispatch_by_name
    var seen_q = std.StringHashMap(void).init(allocator);
    defer seen_q.deinit();
    var qs = std.ArrayList([]const u8).empty;
    defer qs.deinit(allocator);
    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        const s = decl.struct_decl;
        for (s.impls) |impl| {
            if (!std.mem.eql(u8, impl.name, "RequestHandler")) continue;
            if (impl.type_args.len != 2) continue;
            const q = switch (impl.type_args[0]) {
                .ident => |n| n,
                else => continue,
            };
            const r = switch (impl.type_args[1]) {
                .ident => |n| n,
                else => continue,
            };
            if (seen_q.contains(q)) continue; // one handler per request type
            try seen_q.put(q, {});
            try qs.append(allocator, q);
            try serdeAppendf(&src, allocator,
                "fn __mediator_dispatch_{s}(src: ValueSource): string {{\n" ++
                    "    let __h = {s}{{}};\n" ++
                    "    let __req = {s}__bind(src);\n" ++
                    "    let __resp = __h.handle(__req);\n" ++
                    "    return {s}__toJson(__resp);\n" ++
                    "}}\n\n", .{ q, s.name, q, r });
        }
    }
    // A Router (a struct with an `__addRoute` method — e.g. web/routing.nova)
    // references __mediator_dispatch_by_name, so that must exist even when the
    // program declares no handlers yet (an empty router still compiles + 404s).
    var has_router = false;
    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        for (decl.struct_decl.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, "__addRoute")) {
                has_router = true;
                break;
            }
        }
        if (has_router) break;
    }
    if (src.items.len == 0 and !has_router) return;

    // A single by-name dispatcher so a Router can register a route by request-type
    // NAME (a string) and dispatch through this — no first-class fn-values needed
    // (a function value of a struct-typed binder mis-marshals; a plain call does not).
    try serdeAppendf(&src, allocator, "fn __mediator_dispatch_by_name(__name: string, src: ValueSource): string {{\n", .{});
    for (qs.items) |q| {
        try serdeAppendf(&by_name, allocator, "    if (string.eql(__name, \"{s}\")) {{ return __mediator_dispatch_{s}(src); }}\n", .{ q, q });
    }
    try src.appendSlice(allocator, by_name.items);
    try src.appendSlice(allocator, "    return \"\";\n}\n\n");

    var p = try parser.Parser.init(allocator, src.items, "<mediator-generated>", is_wasm);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("mediator dispatch generation failed to parse:\n{s}\n", .{src.items});
        return err;
    };
    for (prog.declarations) |d| {
        try declarations.append(allocator, d);
    }
}

fn loadProgram(allocator: std.mem.Allocator, init: std.process.Init, file_path: []const u8, visited: *std.StringHashMap(void), visiting: *std.StringHashMap(void), merged: *std.ArrayList(u8), declarations: *std.ArrayList(ast.Declaration), is_wasm: bool, file_sources: *std.StringHashMap([]const u8)) anyerror!void {
    if (visiting.contains(file_path)) return error.CyclicImport;
    if (visited.contains(file_path)) return;

    const visiting_key = try allocator.dupe(u8, file_path);
    errdefer allocator.free(visiting_key);
    try visiting.put(visiting_key, {});
    errdefer {
        const kv = visiting.fetchRemove(visiting_key);
        if (kv) |k| {
            allocator.free(k.key);
        }
    }

    var source: []const u8 = undefined;
    // Always the canonical spelling (e.g. "src/std/…" even when the bytes come from
    // ~/.nova/std) so a module's identity — its span.file, prefix, and dedup key — does not
    // depend on where it was read from.
    const resolved_file_path = file_path;

    if (std.mem.startsWith(u8, file_path, "src/std/")) {
        source = Io.Dir.readFileAlloc(.cwd(), init.io, file_path, allocator, .unlimited) catch |err| blk: {
            if (err == error.FileNotFound) {
                // A std module not present under a local `src/std/` (i.e. building a user
                // project outside the compiler checkout): read it from the installed
                // `~/.nova/std/`, but KEEP `resolved_file_path` as the canonical "src/std/…"
                // spelling. That spelling is what becomes each decl's span.file — and thus
                // its module prefix and the import-dedup key. Using the absolute HOME path
                // here instead made a std file's identity depend on WHERE it was read from,
                // so under `nova test` (whose harness/helpers merge shifts emission order) a
                // stdlib free function like `map.nextPowerOfTwo` got collected under one
                // spelling and CALLED under another → "Function 'nextPowerOfTwo' not found".
                // Keeping the canonical spelling makes user-project builds/tests behave
                // exactly like in-checkout ones.
                const sub = file_path[8..];
                const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
                const abs = try std.fmt.allocPrint(allocator, "{s}/.nova/std/{s}", .{ home, sub });
                defer allocator.free(abs);
                break :blk Io.Dir.readFileAlloc(.cwd(), init.io, abs, allocator, .unlimited) catch |r_err| {
                    std.debug.print("Failed to read fallback std file '{s}': {any}\n", .{ abs, r_err });
                    return r_err;
                };
            } else {
                return err;
            }
        };
    } else {
        source = Io.Dir.readFileAlloc(.cwd(), init.io, file_path, allocator, .unlimited) catch |err| {
            std.debug.print("Failed to read file '{s}': {any}\n", .{ file_path, err });
            return err;
        };
    }
    // If this file was already collected under its canonical resolved path
    // (reached earlier via a different spelling — relative "src/std/..." vs
    // absolute "~/.nova/std/..."), skip it. The checks at the top of this
    // function only see the raw file_path, so without this a module imported
    // via two paths gets its declarations collected twice (duplicate functions,
    // double-run tests, wasted compilation).
    if (visited.contains(resolved_file_path)) {
        const already_kv = visiting.fetchRemove(visiting_key);
        if (already_kv) |k| allocator.free(k.key);
        allocator.free(source);
        return;
    }

    // Keep source alive for AST node references.
    try file_sources.put(try allocator.dupe(u8, resolved_file_path), source);

    var p = try parser.Parser.init(allocator, source, resolved_file_path, is_wasm);
    defer p.deinit();
    const program = p.parseProgram() catch |err| {
        std.debug.print("Parser error in file: {s}\n", .{file_path});
        return err;
    };

    for (program.declarations) |decl| {
        if (decl == .import_decl) {
            if (std.mem.eql(u8, decl.import_decl.module, "bytes")) continue;
            const imported_path = try resolveImportPath(resolved_file_path, decl.import_decl.module, allocator, init.io, init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE"));
            defer allocator.free(imported_path);
            try loadProgram(allocator, init, imported_path, visited, visiting, merged, declarations, is_wasm, file_sources);
        }
    }

    const kv = visiting.fetchRemove(visiting_key).?;
    allocator.free(kv.key);

    const visited_key = try allocator.dupe(u8, resolved_file_path);
    try visited.put(visited_key, {});

    // F1-4: KEEP import_decl in the merged declarations (it was stripped here). Each carries the
    // importing file (span.file) and the imported module name, which is the import GRAPH the symbol
    // table needs to make module resolution a lookup instead of a file-path reconstruction (see
    // symbols.zig findModuleBySegment/findFunctionBySegment). Downstream passes skip import_decl via
    // their `else` arms; sema/symbols.build records the edges.
    for (program.declarations) |decl| {
        try declarations.append(allocator, decl);
    }

    try merged.appendSlice(allocator, source);
    try merged.append(allocator, '\n');
}

fn basenameWithoutExtension(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const base = std.fs.path.basename(path);
    const ext_pos = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const name = try allocator.dupe(u8, base[0..ext_pos]);
    return name;
}

// T5: write `content` to `<project>/<rel>`, creating parent directories as needed.
fn scaffoldFile(allocator: std.mem.Allocator, io: std.Io, project: []const u8, rel: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project, rel });
    defer allocator.free(full);
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {
        const dir = full[0..slash];
        Io.Dir.createDirPath(.cwd(), io, dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    try Io.Dir.writeFile(.cwd(), io, .{ .data = content, .sub_path = full, .flags = .{} });
}

// T5: `nova init web` — a vertical-slice (VSA) web app. One folder per slice under
// Features/, a per-feature views/ dir, Domain/ entities, wwwroot/ static assets, tests.
fn scaffoldWeb(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    const f = struct { rel: []const u8, content: []const u8 };
    const files = [_]f{
        .{ .rel = "src/main.nova", .content = templates.web_main_sample },
        // Products / CreateProduct slice
        .{ .rel = "src/Features/Products/CreateProduct/command.nova", .content = templates.web_create_command_sample },
        .{ .rel = "src/Features/Products/CreateProduct/response.nova", .content = templates.web_create_response_sample },
        .{ .rel = "src/Features/Products/CreateProduct/validator.nova", .content = templates.web_create_validator_sample },
        .{ .rel = "src/Features/Products/CreateProduct/handler.nova", .content = templates.web_create_handler_sample },
        // Products / GetProductById slice
        .{ .rel = "src/Features/Products/GetProductById/query.nova", .content = templates.web_get_query_sample },
        .{ .rel = "src/Features/Products/GetProductById/response.nova", .content = templates.web_get_response_sample },
        .{ .rel = "src/Features/Products/GetProductById/handler.nova", .content = templates.web_get_handler_sample },
        // Per-feature view
        .{ .rel = "src/Features/Products/views/product_card.nova", .content = templates.web_view_sample },
        // Domain + static + tests
        .{ .rel = "src/Domain/entities/product.nova", .content = templates.web_domain_entity_sample },
        .{ .rel = "wwwroot/index.html", .content = templates.web_index_html_sample },
        .{ .rel = "tests/features/products_test.nova", .content = templates.web_test_sample },
    };
    for (files) |file| try scaffoldFile(allocator, io, project, file.rel, file.content);
}

// T5: `nova init desktop` — a native webview desktop app (W1).
fn scaffoldDesktop(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    try scaffoldFile(allocator, io, project, "src/main.nova", templates.desktop_main_sample);
}

fn cmdInit(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name>\n", .{});
        return;
    }
    var template_type = args[2];
    // `app` is a deprecated alias for `web` (vertical-slice web app).
    if (std.mem.eql(u8, template_type, "app")) {
        std.debug.print("note: `nova init app` is deprecated — use `nova init web` (or `desktop`). Scaffolding a web app.\n", .{});
        template_type = "web";
    }
    if (!std.mem.eql(u8, template_type, "console") and
        !std.mem.eql(u8, template_type, "web") and
        !std.mem.eql(u8, template_type, "desktop"))
    {
        std.debug.print("Invalid template type '{s}'. Expected 'console', 'web', or 'desktop'.\n", .{template_type});
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name>\n", .{});
        return;
    }

    var project_name: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--name") or std.mem.eql(u8, args[i], "-n")) {
            if (i + 1 < args.len) {
                i += 1;
                project_name = args[i];
            } else {
                std.debug.print("Missing argument for name flag.\n", .{});
                return error.MissingNameArgument;
            }
        }
    }

    if (project_name == null) {
        std.debug.print("Error: Project name must be specified with --name <name> or -n <name>.\n", .{});
        std.debug.print("Usage: nova init <console|app> --name <project_name>\n", .{});
        return;
    }

    Io.Dir.createDirPath(.cwd(), init.io, project_name.?) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating directory '{s}': {any}\n", .{ project_name.?, err });
            return err;
        }
    };

    if (std.mem.eql(u8, template_type, "console")) {
        const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name.?});
        defer allocator.free(src_dir);
        Io.Dir.createDirPath(.cwd(), init.io, src_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const tests_dir = try std.fmt.allocPrint(allocator, "{s}/tests", .{project_name.?});
        defer allocator.free(tests_dir);
        Io.Dir.createDirPath(.cwd(), init.io, tests_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.nova", .{project_name.?});
        defer allocator.free(main_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.console_main_sample, .sub_path = main_path, .flags = .{} });

        const test_path = try std.fmt.allocPrint(allocator, "{s}/tests/main_test.nova", .{project_name.?});
        defer allocator.free(test_path);
        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = templates.console_test_sample, .sub_path = test_path, .flags = .{} });
    } else if (std.mem.eql(u8, template_type, "web")) {
        try scaffoldWeb(allocator, init.io, project_name.?);
    } else {
        try scaffoldDesktop(allocator, init.io, project_name.?);
    }

    const project_json_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "type": "{s}",
        \\  "dependencies": []
        \\}}
        , .{ project_name.?, template_type });
    defer allocator.free(project_json_content);

    const project_json_path = try std.fmt.allocPrint(allocator, "{s}/project.json", .{project_name.?});
    defer allocator.free(project_json_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = project_json_content, .sub_path = project_json_path, .flags = .{} });

    // A .gitignore so `nova build` artifacts + fetched deps aren't committed (T6).
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{project_name.?});
    defer allocator.free(gitignore_path);
    Io.Dir.writeFile(.cwd(), init.io, .{ .data = "build/\n*.o\n", .sub_path = gitignore_path, .flags = .{} }) catch {};

    std.debug.print("Project '{s}' initialized successfully.\n", .{project_name.?});
}

fn cmdAddFeature(allocator: std.mem.Allocator, init: std.process.Init, name: []const u8) !void {
    const feature_dir_path = try std.fmt.allocPrint(allocator, "features/{s}", .{name});
    defer allocator.free(feature_dir_path);
    Io.Dir.createDirPath(.cwd(), init.io, feature_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const model_path = try std.fmt.allocPrint(allocator, "features/{s}/model.nova", .{name});
    defer allocator.free(model_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// Model layer\n", .sub_path = model_path, .flags = .{} });
    const service_path = try std.fmt.allocPrint(allocator, "features/{s}/service.nova", .{name});
    defer allocator.free(service_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// Service layer\n", .sub_path = service_path, .flags = .{} });
    const view_path = try std.fmt.allocPrint(allocator, "features/{s}/view.nova", .{name});
    defer allocator.free(view_path);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = "// View layer\n", .sub_path = view_path, .flags = .{} });
    const handler_path = try std.fmt.allocPrint(allocator, "features/{s}/{s}.nova", .{ name, name });
    defer allocator.free(handler_path);
    const handler_content = try std.fmt.allocPrint(allocator, "// Handler layer for {s}\n", .{name});
    defer allocator.free(handler_content);
    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = handler_content, .sub_path = handler_path, .flags = .{} });

    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("No project.json found, skipping registration.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var new_json = std.ArrayList(u8).empty;
    defer new_json.deinit(allocator);

    const match_str = "\"features\": [";
    if (std.mem.indexOf(u8, json_data, match_str)) |pos| {
        try new_json.appendSlice(allocator, json_data[0 .. pos + match_str.len]);
        const is_empty = std.mem.indexOf(u8, json_data[pos + match_str.len ..], "\"") == null or
            (std.mem.indexOf(u8, json_data[pos + match_str.len ..], "]") orelse 0) < (std.mem.indexOf(u8, json_data[pos + match_str.len ..], "\"") orelse 0);

        const feature_item = if (is_empty)
            try std.fmt.allocPrint(allocator, "\n    \"{s}\"", .{name})
        else
            try std.fmt.allocPrint(allocator, "\n    \"{s}\",", .{name});
        defer allocator.free(feature_item);
        try new_json.appendSlice(allocator, feature_item);
        try new_json.appendSlice(allocator, json_data[pos + match_str.len ..]);

        try Io.Dir.writeFile(.cwd(), init.io, .{ .data = new_json.items, .sub_path = "project.json", .flags = .{} });
    }
    std.debug.print("Feature '{s}' scaffolded and registered successfully.\n", .{name});
}

/// Collect @test function names from declarations
fn collectTestFunctions(declarations: []const ast.Declaration, allocator: std.mem.Allocator) ![][]const u8 {
    var test_fns = std.ArrayList([]const u8).empty;
    defer test_fns.deinit(allocator);
    for (declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                for (fd.attributes) |attr| {
                    switch (attr) {
                        .@"test" => {
                            try test_fns.append(allocator, fd.name);
                            break;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return try test_fns.toOwnedSlice(allocator);
}

/// Generate a synthetic test harness main() that calls all @test functions
fn generateTestHarness(test_fn_names: []const []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);

    try src.appendSlice(allocator, "fn main(): void {\n");
    try src.print(allocator, "    let __test_total = {d};\n", .{test_fn_names.len});
    try src.appendSlice(allocator, "    let __test_passed = 0;\n");
    try src.appendSlice(allocator, "    let __test_failed = 0;\n");
    try src.print(allocator, "    console.log(\"Running {d} test(s)...\");\n", .{test_fn_names.len});
    try src.appendSlice(allocator, "    console.log(\"\");\n");

    for (test_fn_names) |name| {
        try src.appendSlice(allocator, "    nova_test_reset();\n");
        try src.print(allocator, "    nova_test_begin(\"{s}\");\n", .{name});
        try src.print(allocator, "    {s}();\n", .{name});
        try src.appendSlice(allocator, "    if (nova_test_did_fail() == 0) {\n");
        try src.print(allocator, "        console.log(\"  PASS  {s}\");\n", .{name});
        try src.appendSlice(allocator, "        __test_passed = __test_passed + 1;\n");
        try src.appendSlice(allocator, "    } else {\n");
        try src.print(allocator, "        console.log(\"  FAIL  {s}\");\n", .{name});
        try src.appendSlice(allocator, "        let msg = nova_test_fail_message();\n");
        try src.appendSlice(allocator, "        console.log(\"        \" + msg);\n");
        try src.appendSlice(allocator, "        __test_failed = __test_failed + 1;\n");
        try src.appendSlice(allocator, "    }\n");
    }

    try src.appendSlice(allocator, "    console.log(\"\");\n");
    try src.appendSlice(allocator, "    console.log(\"Results: \" + __test_passed + \" passed, \" + __test_failed + \" failed, \" + __test_total + \" total\");\n");
    // F5 §3.5.1: under NOVA_ARC_AUDIT a LEAK IS A TEST FAILURE. Returns 0 when the
    // audit is off, so this is unconditional — an opt-in check that only runs under
    // a flag someone remembers to set is a check that does not run.
    try src.appendSlice(allocator, "    if (nova_arc_audit_report() > 0) {\n");
    try src.appendSlice(allocator, "        nova_exit(1);\n");
    try src.appendSlice(allocator, "    }\n");
    try src.appendSlice(allocator, "    if (__test_failed > 0) {\n");
    try src.appendSlice(allocator, "        nova_exit(1);\n");
    try src.appendSlice(allocator, "    }\n");
    try src.appendSlice(allocator, "}\n");

    return try src.toOwnedSlice(allocator);
}

fn findNovaFiles(allocator: std.mem.Allocator, io: Io, root_dir: Io.Dir, sub_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    const dir = try Io.Dir.openDir(root_dir, io, sub_path, .{ .iterate = true });
    defer Io.Dir.close(dir, io);
    var it = Io.Dir.iterate(dir);
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "zig-cache") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "lang")) continue;

        const entry_path = if (sub_path.len == 0 or std.mem.eql(u8, sub_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &[_][]const u8{ sub_path, entry.name });
        errdefer allocator.free(entry_path);

        if (entry.kind == .directory) {
            try findNovaFiles(allocator, io, root_dir, entry_path, list);
            allocator.free(entry_path);
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".nova") and !std.mem.eql(u8, entry.name, "merged.nova")) {
                try list.append(allocator, entry_path);
            } else {
                allocator.free(entry_path);
            }
        } else {
            allocator.free(entry_path);
        }
    }
}

// T4: `nova fmt` is a from-AST re-serializer and is not yet complete for every construct
// (comments are dropped; a few features don't round-trip). To make it NON-DESTRUCTIVE, the
// formatted output's meaningful-token stream is compared to the original's; if they differ,
// the format is REJECTED and the file left untouched. So `nova fmt` can never corrupt code —
// at worst it leaves a file unchanged (reported), never silently rewrites it wrong.
fn sameTokenStream(a: []const u8, b: []const u8) bool {
    var la = lexer.Lexer.init(a);
    var lb = lexer.Lexer.init(b);
    while (true) {
        const ta = la.nextToken();
        const tb = lb.nextToken();
        if (ta.type != tb.type) return false;
        if (!std.mem.eql(u8, ta.lexeme, tb.lexeme)) return false;
        if (ta.type == .eof) return true;
    }
}

/// The (start, end) byte span of every non-EOF code token in `text`, using the lexer's
/// `tok_start`/`pos`. Robust for punctuation (whose lexemes are static literals) and for
/// strings (whose lexemes may be escape-processed) — both would defeat pointer arithmetic.
const TokenSpan = struct { start: usize, end: usize };

fn codeTokenSpans(allocator: std.mem.Allocator, text: []const u8) ![]TokenSpan {
    var spans = std.ArrayList(TokenSpan).empty;
    errdefer spans.deinit(allocator);
    var lx = lexer.Lexer.init(text);
    while (true) {
        const t = lx.nextToken();
        if (t.type == .eof) break;
        try spans.append(allocator, .{ .start = lx.tok_start, .end = lx.pos });
    }
    return spans.toOwnedSlice(allocator);
}

const CommentIns = struct {
    offset: usize, // where to splice into the FORMATTED text
    text: []const u8, // the rendered insertion (owned)
    order: usize, // stable tiebreaker for equal offsets
};

/// Re-inject the source's comments into `formatted`. The AST formatter drops comments
/// but preserves the exact CODE-token sequence (the caller has already asserted token
/// equivalence), so both texts share one token stream. Each source comment lives in a
/// whitespace gap between two code tokens; we find the same gap in `formatted` and splice
/// the comment in — as a trailing `// …` on the previous token's line, or on its own line
/// (at the next token's indentation) if it stood alone. Never alters a code token, so the
/// result stays token-equivalent.
fn reinjectComments(allocator: std.mem.Allocator, source: []const u8, formatted: []const u8) ![]u8 {
    const s_spans = try codeTokenSpans(allocator, source);
    defer allocator.free(s_spans);
    const f_spans = try codeTokenSpans(allocator, formatted);
    defer allocator.free(f_spans);

    const n = s_spans.len;
    // Defensive: if the token counts disagree (shouldn't, given the guard) don't risk a
    // misplaced comment — return the formatted text unchanged.
    if (n != f_spans.len) return allocator.dupe(u8, formatted);

    var inserts = std.ArrayList(CommentIns).empty;
    defer inserts.deinit(allocator);
    var order: usize = 0;

    // Walk every gap [prev-token-end, next-token-start], i in 0..=n (i==n = tail region).
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const gap_start = if (i == 0) 0 else s_spans[i - 1].end;
        const gap_end = if (i < n) s_spans[i].start else source.len;
        const has_prev = i > 0;
        var seen_nl = false;
        var j = gap_start;
        while (j < gap_end) {
            const c = source[j];
            if (c == '\n') {
                seen_nl = true;
                j += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r') {
                j += 1;
                continue;
            }
            if (c == '/' and j + 1 < gap_end and source[j + 1] == '/') {
                var k = j;
                while (k < gap_end and source[k] != '\n') k += 1;
                var te = k;
                while (te > j and (source[te - 1] == ' ' or source[te - 1] == '\t' or source[te - 1] == '\r')) te -= 1;
                const text = source[j..te];
                const trailing = has_prev and !seen_nl;
                try appendCommentInsert(allocator, &inserts, &order, formatted, f_spans, i, n, text, trailing);
                j = k;
                seen_nl = false;
            } else if (c == '/' and j + 1 < gap_end and source[j + 1] == '*') {
                var k = j + 2;
                while (k + 1 < gap_end and !(source[k] == '*' and source[k + 1] == '/')) k += 1;
                k = if (k + 1 < gap_end) k + 2 else gap_end;
                const text = source[j..k];
                const trailing = has_prev and !seen_nl;
                try appendCommentInsert(allocator, &inserts, &order, formatted, f_spans, i, n, text, trailing);
                j = k;
                seen_nl = false;
            } else {
                // A non-ws, non-comment byte inside a token gap shouldn't happen; bail out
                // of this gap rather than risk a misread.
                break;
            }
        }
    }

    if (inserts.items.len == 0) return allocator.dupe(u8, formatted);

    // Stable-sort insertions by splice offset (insertion order breaks ties).
    std.mem.sort(CommentIns, inserts.items, {}, struct {
        fn lt(_: void, a: CommentIns, b: CommentIns) bool {
            if (a.offset != b.offset) return a.offset < b.offset;
            return a.order < b.order;
        }
    }.lt);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (inserts.items) |ins| {
        const off = @min(ins.offset, formatted.len);
        if (off > cursor) try out.appendSlice(allocator, formatted[cursor..off]);
        try out.appendSlice(allocator, ins.text);
        cursor = off;
    }
    if (cursor < formatted.len) try out.appendSlice(allocator, formatted[cursor..]);
    // Free the per-insertion rendered strings.
    for (inserts.items) |ins| allocator.free(ins.text);
    return out.toOwnedSlice(allocator);
}

fn appendCommentInsert(
    allocator: std.mem.Allocator,
    inserts: *std.ArrayList(CommentIns),
    order: *usize,
    formatted: []const u8,
    f_spans: []const TokenSpan,
    i: usize,
    n: usize,
    text: []const u8,
    trailing: bool,
) !void {
    if (trailing and i >= 1) {
        // End of the line holding the previous token in the formatted output.
        const base = f_spans[i - 1].start;
        const line_end = std.mem.indexOfScalarPos(u8, formatted, base, '\n') orelse formatted.len;
        const rendered = try std.fmt.allocPrint(allocator, " {s}", .{text});
        try inserts.append(allocator, .{ .offset = line_end, .text = rendered, .order = order.* });
    } else if (i < n) {
        // Its own line, before the next token, at that line's indentation.
        const base = f_spans[i].start;
        const line_start = if (std.mem.lastIndexOfScalar(u8, formatted[0..base], '\n')) |nl| nl + 1 else 0;
        var ind_end = line_start;
        while (ind_end < base and (formatted[ind_end] == ' ' or formatted[ind_end] == '\t')) ind_end += 1;
        const indent = formatted[line_start..ind_end];
        const rendered = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ indent, text });
        try inserts.append(allocator, .{ .offset = line_start, .text = rendered, .order = order.* });
    } else {
        // After the last token (tail of file).
        const rendered = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
        try inserts.append(allocator, .{ .offset = formatted.len, .text = rendered, .order = order.* });
    }
    order.* += 1;
}

fn formatFile(allocator: std.mem.Allocator, init: std.process.Init, file_path: []const u8) !void {
    const source = try Io.Dir.readFileAlloc(.cwd(), init.io, file_path, allocator, .unlimited);
    defer allocator.free(source);

    var p = try parser.Parser.init(allocator, source, file_path, false);
    defer p.deinit();
    const program = p.parseProgram() catch |err| {
        std.debug.print("Parser error in file: {s}\n", .{file_path});
        return err;
    };

    var f = formatter.Formatter.init(allocator, source);
    defer f.deinit();

    const formatted = try f.formatProgram(program);
    defer allocator.free(formatted);

    // Non-destructive guard: only write if the meaningful tokens are unchanged.
    if (!sameTokenStream(source, formatted)) {
        if (init.environ_map.get("NOVA_FMT_DEBUG") != null) {
            var la = lexer.Lexer.init(source);
            var lb = lexer.Lexer.init(formatted);
            while (true) {
                const ta = la.nextToken();
                const tb = lb.nextToken();
                if (ta.type != tb.type or !std.mem.eql(u8, ta.lexeme, tb.lexeme)) {
                    std.debug.print("  [fmt-diff] src={s}'{s}' (L{d}) vs fmt={s}'{s}' (L{d})\n", .{ @tagName(ta.type), ta.lexeme, ta.line, @tagName(tb.type), tb.lexeme, tb.line });
                    break;
                }
                if (ta.type == .eof) break;
            }
        }
        std.debug.print("skipped '{s}': formatter would alter code (unsupported construct) — file left unchanged\n", .{file_path});
        return;
    }

    // Re-inject comments the AST formatter dropped, then re-check the guard defensively
    // (comment splicing only touches whitespace gaps, so it must stay token-equivalent).
    const with_comments = try reinjectComments(allocator, source, formatted);
    defer allocator.free(with_comments);
    if (!sameTokenStream(source, with_comments)) {
        std.debug.print("skipped '{s}': comment reinjection would alter code — file left unchanged\n", .{file_path});
        return;
    }

    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = with_comments, .sub_path = file_path, .flags = .{} });
}

fn cmdFmt(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len >= 3) {
        const file_path = args[2];
        formatFile(allocator, init, file_path) catch |err| {
            std.debug.print("Error formatting file '{s}': {any}\n", .{ file_path, err });
        };
    } else {
        var list = std.ArrayList([]const u8).empty;
        defer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        try findNovaFiles(allocator, init.io, .cwd(), ".", &list);
        if (list.items.len == 0) {
            std.debug.print("No .nova files found to format.\n", .{});
            return;
        }
        var formatted_count: usize = 0;
        for (list.items) |file_path| {
            formatFile(allocator, init, file_path) catch |err| {
                std.debug.print("Error formatting file '{s}': {any}\n", .{ file_path, err });
                continue;
            };
            formatted_count += 1;
        }
        std.debug.print("Formatted {d} files.\n", .{formatted_count});
    }
}

const ProjectJson = struct {
    name: []const u8,
    version: []const u8,
    type: ?[]const u8 = null,
    dependencies: [][]const u8,
};

/// The repository (directory) name a git URL clones into: last path segment, `.git` stripped.
fn repoNameFromUrl(git_url: []const u8) ?[]const u8 {
    var len = git_url.len;
    while (len > 0 and git_url[len - 1] == '/') len -= 1;
    const trimmed = git_url[0..len];
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    var repo = trimmed[last_slash + 1 ..];
    if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
    if (repo.len == 0) return null;
    return repo;
}

/// Clone `git_url` into `~/.nova/cache/<repo>` unless it is already present. Returns true if a
/// clone actually happened (false = cache hit, nothing fetched).
fn cloneIntoCache(allocator: std.mem.Allocator, init: std.process.Init, git_url: []const u8) !bool {
    const repo_name = repoNameFromUrl(git_url) orelse {
        std.debug.print("Invalid git URL format: {s}\n", .{git_url});
        return error.InvalidGitUrl;
    };
    const home_path = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const target_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_path, ".nova", "cache", repo_name });
    defer allocator.free(target_dir);

    // Idempotent: a present cache dir is a hit — don't re-clone (and don't clobber).
    if (Io.Dir.access(.cwd(), init.io, target_dir, .{})) |_| {
        std.debug.print("  {s} already cached ({s})\n", .{ repo_name, target_dir });
        return false;
    } else |_| {}

    std.debug.print("Cloning {s} into {s}...\n", .{ git_url, target_dir });
    var git_child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{ "git", "clone", "--depth", "1", git_url, target_dir },
    });
    const git_term = try git_child.wait(init.io);
    switch (git_term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git clone failed with exit code {d}\n", .{code});
            return error.GitCloneFailed;
        },
        else => {
            std.debug.print("git clone failed abnormally\n", .{});
            return error.GitCloneFailed;
        },
    }
    return true;
}

/// `nova get` with no URL: restore every dependency listed in `project.json` into the cache.
fn cmdRestore(allocator: std.mem.Allocator, init: std.process.Init) !void {
    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found. Run 'nova init' first.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var parsed = std.json.parseFromSlice(ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    if (parsed.value.dependencies.len == 0) {
        std.debug.print("No dependencies to restore.\n", .{});
        return;
    }
    std.debug.print("Restoring {d} dependenc{s} from project.json...\n", .{
        parsed.value.dependencies.len,
        if (parsed.value.dependencies.len == 1) "y" else "ies",
    });
    var fetched: usize = 0;
    for (parsed.value.dependencies) |dep| {
        if (try cloneIntoCache(allocator, init, dep)) fetched += 1;
    }
    std.debug.print("Restore complete: {d} fetched, {d} already cached.\n", .{ fetched, parsed.value.dependencies.len - fetched });
}

fn cmdGet(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        // No URL → restore all manifest dependencies.
        return cmdRestore(allocator, init);
    }
    const git_url = args[2];
    _ = cloneIntoCache(allocator, init, git_url) catch |err| return err;

    const json_data = Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited) catch {
        std.debug.print("Error: project.json not found in current directory. Run 'nova init' first.\n", .{});
        return;
    };
    defer allocator.free(json_data);

    var parsed = std.json.parseFromSlice(ProjectJson, allocator, json_data, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("Failed to parse project.json: {any}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    var deps_list = std.ArrayList([]const u8).empty;
    defer deps_list.deinit(allocator);
    for (parsed.value.dependencies) |dep| {
        try deps_list.append(allocator, dep);
    }

    var already_exists = false;
    for (deps_list.items) |dep| {
        if (std.mem.eql(u8, dep, git_url)) {
            already_exists = true;
            break;
        }
    }

    if (!already_exists) {
        try deps_list.append(allocator, git_url);
    }

    const updated_project = ProjectJson{
        .name = parsed.value.name,
        .version = parsed.value.version,
        .type = parsed.value.type,
        .dependencies = deps_list.items,
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(updated_project, .{}, &out.writer);

    try Io.Dir.writeFile(.cwd(), init.io, .{ .data = out.written(), .sub_path = "project.json", .flags = .{} });
    std.debug.print("Dependency locked in project.json successfully.\n", .{});
}

fn cmdTest(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    // Parse args: nova test [file.nova] [--native|--wasm]
    var file_path: []const u8 = "";
    var target: []const u8 = "--native"; // default to native for tests

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--wasm") or std.mem.eql(u8, arg, "--native")) {
            target = arg;
        } else {
            file_path = arg;
        }
    }

    var file_paths = std.ArrayList([]const u8).empty;
    defer {
        for (file_paths.items) |p| {
            allocator.free(p);
        }
        file_paths.deinit(allocator);
    }

    if (file_path.len == 0) {
        findNovaFiles(allocator, init.io, .cwd(), ".", &file_paths) catch |err| {
            std.debug.print("Failed to scan project directory: {any}\n", .{err});
            return;
        };
        if (file_paths.items.len == 0) {
            std.debug.print("No .nova files found in the current directory.\n", .{});
            return;
        }
    } else {
        const dup = try allocator.dupe(u8, file_path);
        try file_paths.append(allocator, dup);
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.keyIterator();
        while (iter.next()) |k| {
            allocator.free(k.*);
        }
        visited.deinit();
    }
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    var merged = std.ArrayList(u8).empty;
    defer merged.deinit(allocator);

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = file_sources.keyIterator();
        while (iter.next()) |k| {
            allocator.free(k.*);
        }
        file_sources.deinit();
    }

    var declarations = std.ArrayList(ast.Declaration).empty;
    defer declarations.deinit(allocator);

    const is_wasm = std.mem.eql(u8, target, "--wasm");

    // Preload string_builder standard library
    loadProgram(allocator, init, "src/std/collections/string_builder.nova", &visited, &visiting, &merged, &declarations, is_wasm, &file_sources) catch |err| {
        std.debug.print("Warning: Failed to load string_builder in test harness: {any}\n", .{err});
    };

    for (file_paths.items) |path| {
        loadProgram(allocator, init, path, &visited, &visiting, &merged, &declarations, is_wasm, &file_sources) catch |err| {
            std.debug.print("Failed to load program {s}: {any}\n", .{ path, err });
            // ⚠️ `return err`, not `return`. This swallowed the error and returned NORMALLY, so
            // **every parse error in `nova test` exited 0** — a file that fails to parse reported
            // SUCCESS, and CI would go green on a syntax error. The positive-case path in
            // conformance/run.sh happened to survive it (a parse failure prints no `Results:`
            // line, and that check requires one), so this only ever bit the negative cases —
            // which, until 2026-07-17, judged on exit code alone and so could not see it either.
            // Found the moment `throw_removed.nova` became the corpus's first `EXPECT-FAIL: parse`
            // case and the reason-classifier reported "COMPILED-AND-RAN" for an obvious parser
            // error. main's `userErrorHint` maps ExpectedToken/UnexpectedToken to a clean exit 1.
            return err;
        };
    }

    // Discover @test functions
    const test_fn_names = try collectTestFunctions(declarations.items, allocator);
    if (test_fn_names.len == 0) {
        if (file_path.len == 0) {
            std.debug.print("No @test functions found in project directory\n", .{});
        } else {
            std.debug.print("No @test functions found in {s}\n", .{file_path});
        }
        return;
    }
    std.debug.print("Found {d} test function(s)\n", .{test_fn_names.len});

    // Generate test harness main()
    const harness_src = try generateTestHarness(test_fn_names, allocator);

    // Remove any existing main() from declarations
    var filtered_decls = std.ArrayList(ast.Declaration).empty;
    defer filtered_decls.deinit(allocator);
    for (declarations.items) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "main")) continue;
                try filtered_decls.append(allocator, decl);
            },
            else => try filtered_decls.append(allocator, decl),
        }
    }

    // Parse the harness source and add to declarations
    var harness_parser = try parser.Parser.init(allocator, harness_src, "test_harness.nova", is_wasm);
    defer harness_parser.deinit();
    const harness_prog = try harness_parser.parseProgram();
    try filtered_decls.appendSlice(allocator, harness_prog.declarations);

    // Add compiler helpers (same as regular compilation)
    const helpers =
        \\fn __log_i32(val: i32): void {
        \\    console.log(`${val}`);
        \\}
        \\fn __log_bool(val: bool): void {
        \\    if (val) {
        \\        console.log("true");
        \\    } else {
        \\        console.log("false");
        \\    }
        \\}
        \\fn __read_string(ptr: i32, len: i32): string {
        \\    let new_ptr = bytes.alloc(len);
        \\    let i = 0;
        \\    while (i < len) {
        \\        bytes.write_byte(new_ptr, i, bytes.read_byte(ptr, i));
        \\        i = i + 1;
        \\    }
        \\    return new_ptr as string;
        \\}
        \\
    ;
    var helpers_p = try parser.Parser.init(allocator, helpers, "helpers.nova", is_wasm);
    defer helpers_p.deinit();
    const helpers_prog = try helpers_p.parseProgram();
    try filtered_decls.appendSlice(allocator, helpers_prog.declarations);

    try generateControllerRoutes(allocator, &filtered_decls);
    try generateSerdeBinders(allocator, &filtered_decls, is_wasm);
    try generateMediatorDispatch(allocator, &filtered_decls, is_wasm);

    const program = ast.Program{
        .declarations = filtered_decls.items,
        .span = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = file_path },
    };
    std.debug.print("Parsed {d} top-level declaration(s).\n", .{program.declarations.len});

    // F1: lexical block scope by alpha-renaming (specs §10 #23). Must run before
    // the checker and codegen, both of which assume one flat namespace per
    // function — an assumption this pass makes TRUE by giving every shadowing
    // binding a distinct name. Non-shadowing code is left byte-identical.
    try sema_alpha.run(allocator, program);

    // F2 stage 4a: stamp every Expression with a copy-surviving id. Must run
    // before BOTH sema and codegen: codegen takes Expression by value, so the IR
    // can only be keyed on something that survives the copy (sema/ids.zig).
    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    try tc.check(program);

    // F1/F2 shadow, mirroring the `nova <file>` path at ~:1330. It lives in BOTH
    // because this is the pipeline that actually compiles the conformance corpus:
    // `nova <file>` currently dies in codegen on nova_test_fail for any program,
    // so the other copy's report can never fire, and a measurement you cannot run
    // is not a measurement. Report-only and env-gated.
    // F2 stage 4c: main OWNS sema's artefacts.
    //
    // The owner is declared HERE, at function scope, not inside the `if` below —
    // codegen runs after that block and reads the IR through `live_ir`, so a
    // block-scoped `defer sm.destroy()` frees it out from under codegen. That is a
    // use-after-free, and freed memory usually still reads fine, so the corpus
    // would stay green and hide it. It is precisely the bug stage 2i documented
    // when it chose to leak instead — the fix is an owner with the RIGHT lifetime,
    // not a longer one.
    // F2 stage 4c: SEMA RUNS ON EVERY COMPILE, and codegen reads its types.
    //
    // No longer gated. The evidence, on the whole corpus: emitted IR BYTE-IDENTICAL
    // with the cutover on, 28/28, 97.3% of resolutions answered from the IR, and —
    // once type names were interned — no measurable time cost (+0.2 MB RSS). What
    // used to make this a decision was sema leaking its artefacts; it now owns them
    // (sema/sema.zig), so there is nothing left to weigh.
    //
    // The REPORTS stay opt-in (NOVA_SEMA_SHADOW=1): a compiler that narrates its
    // own type inference on every build is unusable. Building and reporting are
    // different decisions — conflating them is what kept sema off by default.
    sema_shadow.report_enabled = init.environ_map.get("NOVA_SEMA_SHADOW") != null;
    sema_shadow.trace_resolution = sema_shadow.report_enabled; // the DIFF costs; opt-in
    sema_shadow.f2_types_enabled = true; // no legacy to fall back to (4d)

    const owned_sema = try sema_mod.Sema.create(allocator);
    defer owned_sema.destroy(); // function scope: codegen reads it after this block
    sema_shadow.run(allocator, program, owned_sema) catch |e| {
        std.debug.print("sema failed: {any}\n", .{e});
    };

    // F4 stage 3: compute the instantiation set and REPORT it. Emits nothing —
    // §3.5 item 3 wants the growth measured before monomorphization is written, not
    // after a commit that says "correctness" makes the compiler 8x bigger.
    //
    // F4 4b: and now something reads it. The worklist must therefore run when EMISSION
    // wants it, not only when the report does — `report_enabled` was the condition for
    // printing, and reusing it as the condition for compiling would make the emitted
    // program depend on whether a debug env var was set.
    // F4 4b: the worklist ALWAYS runs — monomorphization is not optional (see
    // sema/mono.zig). `report_enabled` gates only the printing.
    {
        var wl = sema_mono.Worklist.init(allocator, owned_sema);
        defer wl.deinit();
        wl.compute(program) catch |e| std.debug.print("F4 worklist failed: {any}\n", .{e});
        sema_mono.live_instantiations = wl.names(allocator) catch null;
        if (sema_shadow.report_enabled) wl.report();
        // F4 erased-body elimination: record each expr's CONCRETE disposition per instantiation, so
        // codegen reads it in a monomorphized body instead of re-deriving via the keystoneSubst side-channel.
        if (wl.instIds(allocator) catch null) |ids| {
            defer allocator.free(ids);
            @import("sema/inst_disp.zig").run(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir, ids);
        }
    }

    const output_path = "__nova_test";
    const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
    defer allocator.free(obj_path);
    const t6_split = init.environ_map.get("NOVA_T6_SPLIT") != null;
    var split_objs = std.ArrayList([]const u8).empty;
    defer {
        for (split_objs.items) |o| {
            Io.Dir.deleteFile(.cwd(), init.io, o) catch {};
            allocator.free(o);
        }
        split_objs.deinit(allocator);
    }
    try llvm_codegen.compile(allocator, program, is_wasm, false, null, obj_path, false, t6_split, if (t6_split) &split_objs else null, null, init.io);
    const link_objs: []const []const u8 = if (split_objs.items.len > 0) split_objs.items else &[_][]const u8{obj_path};
    sema_shadow.reportDiff();
    sema_shadow.reportTypeIdDiff();
    sema_shadow.reportF45();
    sema_mono.dumpMethodInsts();

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const shared_nova = try std.fmt.allocPrint(allocator, "{s}/.nova", .{ home });
    const shared_nova_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{shared_nova});

    // NOVA_ASAN=1 links the AddressSanitizer runtime (built by `NOVA_ASAN=1 zig build`).
    //
    // The class of bug this exists for: ARC decides ownership by string-matching a rendered
    // type name, and guesses when the name is unknown — so a confused compiler emits a release
    // of live memory or a use of freed memory. `nova_release` on a freed object reads the
    // refcount at ptr-8 and returns quietly on the sentinel; the damage only surfaces once
    // malloc reuses the block and it decrements a DIFFERENT object's count, crashing somewhere
    // unrelated. ASAN reports that read AT the release, naming the free site too.
    const asan = if (init.environ_map.get("NOVA_ASAN")) |v| !std.mem.eql(u8, v, "0") else false;

    var test_clang_args = std.ArrayList([]const u8).empty;
    try test_clang_args.append(allocator, "clang++");
    try test_clang_args.append(allocator, "-std=c++20");
    try test_clang_args.append(allocator, "-g");
    try test_clang_args.append(allocator, "-O0");
    try test_clang_args.append(allocator, "-pthread");
    // T6/Phase-2 dead-code strip (see linkNativeInProcessMacho): drop functions/globals unreferenced
    // from the entry point. Mach-O: -dead_strip (atomised, no -ffunction-sections needed). ELF: --gc-sections.
    try test_clang_args.append(allocator, dead_strip_flag);
    try test_clang_args.append(allocator, "-I.");
    try test_clang_args.append(allocator, shared_nova_arg);
    if (asan) {
        try test_clang_args.append(allocator, "-fsanitize=address");
        try test_clang_args.append(allocator, "-fno-omit-frame-pointer");
    }

    for (link_objs) |o| try test_clang_args.append(allocator, o); // T6 split: one or many object files

    // Link the prebuilt C++ runtime static lib + Boost (fiber concurrency).
    // BOOST_PREFIX/lib is the Homebrew macOS default; configurable per platform.
    const test_nova_lib = try std.fmt.allocPrint(allocator, "-L{s}/lib", .{shared_nova});
    try test_clang_args.append(allocator, test_nova_lib);
    // The ASAN runtime is a SEPARATE archive: mixing an instrumented object with a plain
    // libnova_runtime.a would leave the allocator uninstrumented, which is the half that
    // matters here (nova_release reads the header of a freed block).
    try test_clang_args.append(allocator, if (asan) "-lnova_runtime_asan" else "-lnova_runtime");
    // M3-D: Boost.Asio is header-only; the abandoned Boost.Fiber attempt is not
    // compiled, so no -lboost_* is needed. Keep -L for any transitive boost_system.
    try test_clang_args.append(allocator, "-L/opt/homebrew/lib");
    try appendWolfsslLink(&test_clang_args, allocator, shared_nova, init.io);
    // T3 FFI: link flags for every library named by an `extern("lib") fn` in the test program.
    for (try collectFfiLibs(allocator, program)) |lib| {
        try appendFfiLib(&test_clang_args, allocator, shared_nova, init.io, lib);
    }
    try test_clang_args.append(allocator, "-o");
    try test_clang_args.append(allocator, output_path);

    var child = try std.process.spawn(init.io, .{
        .argv = test_clang_args.items,
    });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("Linking test binary failed with code {d}\n", .{code});
                return error.LinkerFailed;
            }
        },
        else => {
            std.debug.print("Linking test binary failed abnormally\n", .{});
            return error.LinkerFailed;
        },
    }
    Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};

    // Run the test binary
    std.debug.print("\n", .{});
    var test_child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{"./__nova_test"},
    });
    const test_term = try test_child.wait(init.io);
    // Remember rather than exit here: the test binary still has to be cleaned up
    // below. `nova test` printed "Test suite FAILED" and then returned 0 anyway, so
    // a failing suite looked green to anything judging by exit code — which is what
    // CI does, and what conformance/run.sh's own comment says it does. run.sh only
    // survived because it ALSO greps the "Results: ... 0 failed" line.
    var suite_failed = false;
    switch (test_term) {
        .exited => |code| {
            if (code != 0) {
                suite_failed = true;
                std.debug.print("\nTest suite FAILED (exit code {d})\n", .{code});
            }
        },
        else => {
            suite_failed = true;
            std.debug.print("\nTest process terminated abnormally\n", .{});
        },
    }

    // Clean up test binary
    // Io.Dir.deleteFile(.cwd(), init.io, "__nova_test") catch {};

    // Propagate the failure, AFTER cleanup. A test runner that reports success
    // when tests failed is worse than no test runner: everything downstream of it
    // is measuring nothing.
    if (suite_failed) std.process.exit(1);
}

fn getFileMtime(io: Io, path: []const u8) !i96 {
    const stat = try Io.Dir.statFile(.cwd(), io, path, .{});
    return stat.mtime.nanoseconds;
}

// T6 cache key: an order-independent digest of every input file's (path + content), folded with
// the profile and a CACHE_VERSION. XOR of per-file hashes is order-independent (the file set is a
// hashmap). Bump CACHE_VERSION when codegen changes in a way an unchanged source must rebuild for.
const CACHE_VERSION: u64 = 1;
fn sourcesHash(file_sources: *std.StringHashMap([]const u8), is_release: bool) u64 {
    var acc: u64 = CACHE_VERSION ^ (if (is_release) @as(u64, 0x9e3779b97f4a7c15) else 0);
    var it = file_sources.iterator();
    while (it.next()) |e| {
        var h = std.hash.Wyhash.init(0);
        h.update(e.key_ptr.*);
        h.update("\x00");
        h.update(e.value_ptr.*);
        acc ^= h.final();
    }
    return acc;
}

fn compileProgram(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    file_path: []const u8,
    target: []const u8,
    output_path: []const u8,
    is_release: bool,
    target_triple_opt: ?[]const u8,
    visited: *std.StringHashMap(void),
    // T6: when build_mode, the object goes to build_obj_dir and a content-hash of the input
    // files is cached in build_hash_path — an unchanged build is skipped. All empty/false for the
    // direct `nova <file> -o` path, which behaves exactly as before.
    build_mode: bool,
    build_obj_dir: []const u8,
    build_hash_path: []const u8,
) !void {
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    var merged = std.ArrayList(u8).empty;
    defer merged.deinit(allocator);

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = file_sources.keyIterator();
        while (iter.next()) |k| {
            allocator.free(k.*);
        }
        file_sources.deinit();
    }

    var declarations = std.ArrayList(ast.Declaration).empty;
    defer declarations.deinit(allocator);

    const is_wasm = std.mem.eql(u8, target, "--wasm");

    // Preload string_builder standard library
    loadProgram(allocator, init, "src/std/collections/string_builder.nova", visited, &visiting, &merged, &declarations, is_wasm, &file_sources) catch |err| {
        std.debug.print("Warning: Failed to load string_builder standard library: {any}\n", .{err});
    };

    try loadProgram(allocator, init, file_path, visited, &visiting, &merged, &declarations, is_wasm, &file_sources);
    // `merged.nova` is a DEBUG DUMP, not a compile input (codegen runs off `declarations`). It used to
    // be written on every compile, cluttering the CWD; now opt-in via NOVA_DUMP_MERGED=1. (T6.)
    if (init.environ_map.get("NOVA_DUMP_MERGED") != null) {
        _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = merged.items, .sub_path = "merged.nova", .flags = .{} }) catch |err| {
            std.debug.print("Failed to write merged.nova: {s}\n", .{@errorName(err)});
        };
    }

    // T6: content-hash cache — an unchanged build is skipped. The parse above is cheap; codegen +
    // link is the expensive part this guards. Cache HIT requires both a matching hash AND an existing
    // output binary (so a deleted binary rebuilds).
    var src_hash: u64 = 0;
    if (build_mode) {
        src_hash = sourcesHash(&file_sources, is_release);
        const cur = std.fmt.allocPrint(allocator, "{x}", .{src_hash}) catch "";
        defer if (cur.len > 0) allocator.free(cur);
        if (Io.Dir.readFileAlloc(.cwd(), init.io, build_hash_path, allocator, .unlimited)) |prev| {
            defer allocator.free(prev);
            const binary_exists = if (Io.Dir.access(.cwd(), init.io, output_path, .{})) |_| true else |_| false;
            if (binary_exists and std.mem.eql(u8, std.mem.trim(u8, prev, " \n"), cur)) {
                std.debug.print("{s} is up to date ({s}) — nothing to rebuild.\n", .{ output_path, if (is_release) "release" else "debug" });
                return;
            }
        } else |_| {}
    }
    if (std.mem.eql(u8, target, "--wasm") or std.mem.eql(u8, target, "--native")) {
        const helpers =
            \\fn __log_i32(val: i32): void {
            \\    console.log(`${val}`);
            \\}
            \\fn __log_bool(val: bool): void {
            \\    if (val) {
            \\        console.log("true");
            \\    } else {
            \\        console.log("false");
            \\    }
            \\}
            \\fn __read_string(ptr: i32, len: i32): string {
            \\    let new_ptr = bytes.alloc(len);
            \\    let i = 0;
            \\    while (i < len) {
            \\        bytes.write_byte(new_ptr, i, bytes.read_byte(ptr, i));
            \\        i = i + 1;
            \\    }
            \\    return new_ptr as string;
            \\}
            \\
        ;
        var helpers_p = try parser.Parser.init(allocator, helpers, "helpers.nova", is_wasm);
        defer helpers_p.deinit();
        const helpers_prog = try helpers_p.parseProgram();
        try declarations.appendSlice(allocator, helpers_prog.declarations);
    }
    try generateControllerRoutes(allocator, &declarations);
    try generateSerdeBinders(allocator, &declarations, is_wasm);
    try generateMediatorDispatch(allocator, &declarations, is_wasm);
    const source = try merged.toOwnedSlice(allocator);
    defer allocator.free(source);

    const program = ast.Program{
        .declarations = declarations.items,
        .span = ast.Span{
            .start = 0,
            .end = 0,
            .line = 1,
            .col = 1,
            .file = file_path,
        },
    };
    std.debug.print("Parsed {d} top-level declaration(s).\n", .{program.declarations.len});

    // F1: lexical block scope by alpha-renaming (specs §10 #23). NOTE: this
    // pipeline is DUPLICATED (the `nova test` path does the same at ~:1117), so a
    // pass added to only one silently does not run in the other. That is how the
    // first cut of this change appeared to do nothing.
    try sema_alpha.run(allocator, program);

    // F2 stage 4a: stamp every Expression with a copy-surviving id (see the note
    // above — this is deliberately in BOTH pipelines).
    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    try tc.check(program);

    // F1 stage 1: build the symbol table alongside legacy resolution and diff them.
    // Report-only and env-gated — changes nothing (docs/design/F1 §5 stage 1).
    // F2 stage 4c: main OWNS sema's artefacts.
    //
    // The owner is declared HERE, at function scope, not inside the `if` below —
    // codegen runs after that block and reads the IR through `live_ir`, so a
    // block-scoped `defer sm.destroy()` frees it out from under codegen. That is a
    // use-after-free, and freed memory usually still reads fine, so the corpus
    // would stay green and hide it. It is precisely the bug stage 2i documented
    // when it chose to leak instead — the fix is an owner with the RIGHT lifetime,
    // not a longer one.
    // F2 stage 4c: SEMA RUNS ON EVERY COMPILE, and codegen reads its types.
    //
    // No longer gated. The evidence, on the whole corpus: emitted IR BYTE-IDENTICAL
    // with the cutover on, 28/28, 97.3% of resolutions answered from the IR, and —
    // once type names were interned — no measurable time cost (+0.2 MB RSS). What
    // used to make this a decision was sema leaking its artefacts; it now owns them
    // (sema/sema.zig), so there is nothing left to weigh.
    //
    // The REPORTS stay opt-in (NOVA_SEMA_SHADOW=1): a compiler that narrates its
    // own type inference on every build is unusable. Building and reporting are
    // different decisions — conflating them is what kept sema off by default.
    sema_shadow.report_enabled = init.environ_map.get("NOVA_SEMA_SHADOW") != null;
    sema_shadow.trace_resolution = sema_shadow.report_enabled; // the DIFF costs; opt-in
    sema_shadow.f2_types_enabled = true; // no legacy to fall back to (4d)

    const owned_sema = try sema_mod.Sema.create(allocator);
    defer owned_sema.destroy(); // function scope: codegen reads it after this block
    sema_shadow.run(allocator, program, owned_sema) catch |e| {
        std.debug.print("sema failed: {any}\n", .{e});
    };

    // F4 stage 3: compute the instantiation set and REPORT it. Emits nothing —
    // §3.5 item 3 wants the growth measured before monomorphization is written, not
    // after a commit that says "correctness" makes the compiler 8x bigger.
    // F4 4b: `build` monomorphizes on the same terms as `test`. A flag that changed
    // what `nova test` emits but not `nova build` would make the corpus prove a
    // program that never ships — the same shape of gap as the stale installed binary
    // that reported 28/28 while the real compiler crashed.
    // F4 4b: the worklist ALWAYS runs — monomorphization is not optional (see
    // sema/mono.zig). `report_enabled` gates only the printing.
    {
        var wl = sema_mono.Worklist.init(allocator, owned_sema);
        defer wl.deinit();
        wl.compute(program) catch |e| std.debug.print("F4 worklist failed: {any}\n", .{e});
        sema_mono.live_instantiations = wl.names(allocator) catch null;
        if (sema_shadow.report_enabled) wl.report();
        // F4 erased-body elimination: per-instantiation concrete dispositions (see the test-path twin).
        if (wl.instIds(allocator) catch null) |ids| {
            defer allocator.free(ids);
            @import("sema/inst_disp.zig").run(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir, ids);
        }
    }

    if (std.mem.eql(u8, target, "--wasm")) {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
        defer allocator.free(obj_path);
        try llvm_codegen.compile(allocator, program, true, is_release, target_triple_opt, obj_path, false, init.environ_map.get("NOVA_T6_SPLIT") != null, null, null, init.io);

        // In-process LLD: link the wasm module ourselves via wasm-ld, no clang shell-out.
        if (build_options.inprocess_lld) {
            try linkWasmInProcess(allocator, obj_path, output_path);
            Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
            std.debug.print("WASM output written to {s}\n", .{output_path});
            return;
        }

        var child = try std.process.spawn(init.io, .{
            .argv = &[_][]const u8{ "clang", "-target", "wasm32", "-nostdlib", "-Wl,--no-entry", "-Wl,--export-all", "-Wl,--export-memory", "-Wl,--allow-undefined", "-Wl,--initial-memory=134217728", obj_path, "-o", output_path },
        });
        const term = try child.wait(init.io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print("Linking WASM binary failed with code {d}\n", .{code});
                    return error.LinkFailed;
                }
            },
            else => {
                std.debug.print("Linking WASM binary failed abnormally\n", .{});
                return error.LinkFailed;
            },
        }
        Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
        std.debug.print("WASM output written to {s}\n", .{output_path});
    } else if (std.mem.eql(u8, target, "--native")) {
        // T6: in build_mode the object lives in build/<profile>/obj/<name>.o (persistent, in the
        // build tree); otherwise it's a throwaway `<output>.o` next to the binary (deleted after link).
        const obj_path = if (build_mode)
            try std.fmt.allocPrint(allocator, "{s}/{s}.o", .{ build_obj_dir, std.fs.path.basename(output_path) })
        else
            try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
        defer allocator.free(obj_path);
        // T6 Phase 1b/Stage C: per-file object split emits one object PER SOURCE FILE (into
        // `split_objs`), linked together, so a one-file edit rebuilds one object (the rest come from
        // the content-hash cache in build/<profile>/obj). It is now the DEFAULT for `nova build`
        // (build_mode) — that's where the persistent cache lives and dev iteration benefits.
        // `NOVA_T6_NOSPLIT=1` forces the single-module path (useful for a one-shot cold/CI build,
        // ~18% faster cold since it skips per-file clone+emit+link). For throwaway `--native`
        // single-file compiles (no cache dir) the split has no upside, so it stays opt-in there.
        const t6_split = if (build_mode)
            init.environ_map.get("NOVA_T6_NOSPLIT") == null
        else
            init.environ_map.get("NOVA_T6_SPLIT") != null;
        var split_objs = std.ArrayList([]const u8).empty;
        defer {
            for (split_objs.items) |o| {
                if (init.environ_map.get("NOVA_KEEP_OBJ") == null and !build_mode) Io.Dir.deleteFile(.cwd(), init.io, o) catch {};
                allocator.free(o);
            }
            split_objs.deinit(allocator);
        }
        try llvm_codegen.compile(allocator, program, false, is_release, target_triple_opt, obj_path, false, t6_split, if (t6_split) &split_objs else null, if (build_mode) build_obj_dir else null, init.io);
        const link_objs: []const []const u8 = if (split_objs.items.len > 0) split_objs.items else &[_][]const u8{obj_path};
        sema_shadow.reportResolution();
        sema_shadow.reportDiff();
    sema_shadow.reportTypeIdDiff();
    sema_shadow.reportF45();
    sema_mono.dumpMethodInsts();

        var clang_args = std.ArrayList([]const u8).empty;
        defer clang_args.deinit(allocator);

        try clang_args.append(allocator, "clang++");
        try clang_args.append(allocator, "-std=c++20");
        // T6/Phase-2 dead-code strip: drop unreferenced functions/globals from the linked binary.
        try clang_args.append(allocator, dead_strip_flag);
        if (target_triple_opt) |triple| {
            try clang_args.append(allocator, "-target");
            try clang_args.append(allocator, triple);
        }
        if (is_release) {
            try clang_args.append(allocator, "-O3");
            try clang_args.append(allocator, "-DNDEBUG");
        } else {
            try clang_args.append(allocator, "-g");
            try clang_args.append(allocator, "-O0");
        }
        try clang_args.append(allocator, "-pthread");
        try clang_args.append(allocator, "-I.");

        const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
        const shared_nova = try std.fmt.allocPrint(allocator, "{s}/.nova", .{ home });

        // T3 FFI: gather the distinct libraries named by `extern("lib") fn` decls; each
        // becomes a `-l<lib>` on the link line so the foreign symbols resolve.
        const ffi_libs = try collectFfiLibs(allocator, program);

        // T1: an explicit NON-host target routes through the bundled Zig toolchain (cross ELF/COFF,
        // bundled libc). Returns false for the native-host target, falling through to the paths below.
        if (target_triple_opt) |triple| {
            if (try crossLinkViaZig(allocator, init.environ_map, init.io, triple, link_objs, output_path, shared_nova, is_release)) {
                if (init.environ_map.get("NOVA_KEEP_OBJ") == null and !build_mode)
                    Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
                if (build_mode) {
                    const cur = std.fmt.allocPrint(allocator, "{x}", .{src_hash}) catch "";
                    defer if (cur.len > 0) allocator.free(cur);
                    _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = cur, .sub_path = build_hash_path, .flags = .{} }) catch {};
                    std.debug.print("Built {s} ({s}, cross {s}).\n", .{ output_path, if (is_release) "release" else "debug", triple });
                } else {
                    std.debug.print("Native output written to {s} (cross {s})\n", .{ output_path, triple });
                }
                return;
            }
        }

        // In-process LLD: link the executable ourselves, no clang/ld shell-out.
        if (build_options.inprocess_lld and builtin.target.os.tag == .macos and target_triple_opt == null) {
            try linkNativeInProcessMacho(allocator, init.environ_map, init.io, link_objs, output_path, shared_nova, ffi_libs);
            // build_mode keeps the object in build/<profile>/obj/ (persistent); else delete it.
            if (init.environ_map.get("NOVA_KEEP_OBJ") == null and !build_mode)
                Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
            if (build_mode) {
                const cur = std.fmt.allocPrint(allocator, "{x}", .{src_hash}) catch "";
                defer if (cur.len > 0) allocator.free(cur);
                _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = cur, .sub_path = build_hash_path, .flags = .{} }) catch {};
                std.debug.print("Built {s} ({s}).\n", .{ output_path, if (is_release) "release" else "debug" });
            }
            return;
        }

        const shared_nova_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{shared_nova});
        try clang_args.append(allocator, shared_nova_arg);

        for (link_objs) |o| try clang_args.append(allocator, o); // T6 split: one or many object files

        // Link the prebuilt C++ runtime static lib + Boost (fiber concurrency).
        const nova_lib = try std.fmt.allocPrint(allocator, "-L{s}/lib", .{shared_nova});
        try clang_args.append(allocator, nova_lib);
        try clang_args.append(allocator, "-lnova_runtime");
        try clang_args.append(allocator, "-L/opt/homebrew/lib");
        try appendWolfsslLink(&clang_args, allocator, shared_nova, init.io);
        for (ffi_libs) |lib| {
            try appendFfiLib(&clang_args, allocator, shared_nova, init.io, lib);
        }
        try clang_args.append(allocator, "-o");
        try clang_args.append(allocator, output_path);

        var child = try std.process.spawn(init.io, .{
            .argv = clang_args.items,
        });
        const term = try child.wait(init.io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print("Linking native binary failed with code {d}\n", .{code});
                    return error.LinkFailed;
                }
            },
            else => {
                std.debug.print("Linking native binary failed abnormally\n", .{});
                return error.LinkFailed;
            },
        }
        // NOVA_KEEP_OBJ=1 keeps the intermediate object so it can be re-linked by hand — e.g.
        // against a sanitizer build of the runtime when chasing a memory bug. build_mode also keeps
        // it (in build/<profile>/obj/).
        if (init.environ_map.get("NOVA_KEEP_OBJ") == null and !build_mode) {
            Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
        } else if (!build_mode) {
            std.debug.print("Kept object file {s} (NOVA_KEEP_OBJ)\n", .{obj_path});
        }
        if (build_mode) {
            const cur = std.fmt.allocPrint(allocator, "{x}", .{src_hash}) catch "";
            defer if (cur.len > 0) allocator.free(cur);
            _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = cur, .sub_path = build_hash_path, .flags = .{} }) catch {};
            std.debug.print("Built {s} ({s}).\n", .{ output_path, if (is_release) "release" else "debug" });
        } else {
            std.debug.print("Native output written to {s}\n", .{output_path});
        }
    } else {
        std.debug.print("Unsupported target: {s}\n", .{target});
        return error.UnsupportedTarget;
    }
}

/// A compile error the USER caused, as opposed to a bug in the compiler.
///
/// Both used to look identical from outside: an unhandled Zig error propagating out of `main`,
/// so the Zig runtime printed a compiler stack trace. That meant even a perfectly good diagnostic
/// ("Type checking failed with 1 error(s): …") was followed by ~20 lines of `llvm_codegen.zig:868`
/// backtrace, which reads as "the compiler crashed" to anyone who did not write the compiler.
///
/// The diagnostic text itself is printed at the point of detection (the checker, the resolver, the
/// codegen site). This function only decides "is this the user's fault?" — if so `main` exits 1
/// quietly, and the message already on screen is the whole output. A genuine internal error still
/// propagates and still gets its stack trace, which is exactly when one is wanted.
///
/// ⚠️ The `codegen`-detected members are DEBT, not the destination: they fire late and carry no
/// source span, so the user gets a name but no `file:line`. The real fix is F1 stage 7 ("N3: failure
/// is an error") and F2 stage 5 ("`.unresolved` is fatal"), which move them into sema where spans
/// exist. Recorded in beta-readiness-plan.md P0-5. (2026-07-17)
fn userErrorHint(e: anyerror) ?[]const u8 {
    return switch (e) {
        // Detected in sema/the checker — a real diagnostic with file:line:col was already printed.
        error.TypeCheckError => "",
        error.ExpectedToken, error.UnexpectedToken => "",
        // Detected in codegen — a message was printed, but without a source span.
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

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch |e| {
        if (userErrorHint(e)) |hint| {
            // The detailed message is already on screen; add a terse trailer only when we have
            // something to add, then exit WITHOUT a compiler stack trace.
            if (hint.len > 0) {
                std.debug.print("\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m {s}\x1b[0m (compilation failed)\n", .{hint});
            }
            std.process.exit(1);
        }
        return e; // a genuine compiler bug — let it crash loudly, with its trace
    };
}

fn mainInner(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("Usage: nova <file> [--wasm|--native] [-o <output>]\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        try cmdInit(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "add")) {
        if (args.len >= 4 and std.mem.eql(u8, args[2], "feature")) {
            try cmdAddFeature(allocator, init, args[3]);
            return;
        }
        std.debug.print("Usage: nova add feature <name>\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "test")) {
        try cmdTest(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "fmt")) {
        try cmdFmt(allocator, init, args);
        return;
    }
    if (std.mem.eql(u8, args[1], "get")) {
        try cmdGet(allocator, init, args);
        return;
    }

    var file_path: []const u8 = "";
    // `nova build` defaults to a NATIVE executable (like `cargo build` / `go build`) — what a user
    // running `nova build` expects and what actually runs standalone. WASM is opt-in via
    // `--target wasm`. (The old default was `--wasm`, which produced a module that could not even
    // build a stdlib-importing program: the WASM codegen branch does not declare the test-harness
    // externs `assert` references. That WASM gap is tracked separately.)
    var target: []const u8 = "--native";
    var output_path: []const u8 = "";
    var is_release = false;
    var cross_target: ?[]const u8 = null;
    var watch_mode = false;
    // T6: `nova build` uses the persistent `build/<profile>/{obj,bin}` layout + a content-hash
    // cache (instant no-change rebuilds). The direct `nova <file> -o out` path is UNTOUCHED by this,
    // so the test harness and scripts keep their simple behaviour.
    const build_mode = std.mem.eql(u8, args[1], "build");

    if (std.mem.eql(u8, args[1], "build")) {
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--target")) {
                if (i + 1 < args.len) {
                    i += 1;
                    const val = args[i];
                    if (std.mem.eql(u8, val, "wasm")) {
                        target = "--wasm";
                    } else if (std.mem.eql(u8, val, "native")) {
                        target = "--native";
                    } else {
                        cross_target = val;
                        target = "--native";
                    }
                } else {
                    std.debug.print("Missing argument for --target\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "--file")) {
                if (i + 1 < args.len) {
                    i += 1;
                    file_path = args[i];
                } else {
                    std.debug.print("Missing argument for --file\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "-o")) {
                if (i + 1 < args.len) {
                    i += 1;
                    output_path = args[i];
                } else {
                    std.debug.print("Missing argument for -o\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
                is_release = true;
            } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
                is_release = false;
            } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
                watch_mode = true;
            }
        }
    } else {
        file_path = args[1];
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--wasm") or std.mem.eql(u8, arg, "--native")) {
                target = arg;
            } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
                is_release = true;
            } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
                is_release = false;
            } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
                watch_mode = true;
            } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "-t")) {
                if (i + 1 < args.len) {
                    i += 1;
                    cross_target = args[i];
                } else {
                    std.debug.print("Missing argument for --target\n", .{});
                    return;
                }
            } else if (std.mem.eql(u8, arg, "-o")) {
                if (i + 1 < args.len) {
                    i += 1;
                    output_path = args[i];
                } else {
                    std.debug.print("Missing argument for -o\n", .{});
                    return;
                }
            }
        }
    }

    // T6: `nova build` project setup — entry + name from project.json, and the build/<profile> layout.
    const profile: []const u8 = if (is_release) "release" else "debug";
    var build_obj_dir: []const u8 = "";
    var build_hash_path: []const u8 = "";
    if (build_mode) {
        // Default the entry to src/main.nova (the `nova init` layout) when no --file was given.
        if (file_path.len == 0) file_path = "src/main.nova";
        // Project name from project.json (falls back to the entry-file stem).
        var proj_name: []const u8 = std.fs.path.stem(file_path);
        if (Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited)) |pj| {
            defer allocator.free(pj);
            if (std.json.parseFromSlice(ProjectJson, allocator, pj, .{ .ignore_unknown_fields = true })) |parsed| {
                proj_name = allocator.dupe(u8, parsed.value.name) catch proj_name;
                parsed.deinit();
            } else |_| {}
        } else |_| {}
        // build/<profile>/{obj,bin}
        const bin_dir = try std.fmt.allocPrint(allocator, "build/{s}/bin", .{profile});
        build_obj_dir = try std.fmt.allocPrint(allocator, "build/{s}/obj", .{profile});
        Io.Dir.createDirPath(.cwd(), init.io, bin_dir) catch {};
        Io.Dir.createDirPath(.cwd(), init.io, build_obj_dir) catch {};
        if (output_path.len == 0)
            output_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, proj_name });
        build_hash_path = try std.fmt.allocPrint(allocator, "build/{s}/.build-hash", .{profile});
    }

    if (file_path.len == 0) {
        std.debug.print("Error: No input file specified.\n", .{});
        return;
    }

    var target_triple_opt: ?[]const u8 = null;
    if (cross_target) |ct| {
        if (std.mem.eql(u8, ct, "linux-arm64")) {
            target_triple_opt = "aarch64-unknown-linux-gnu";
        } else if (std.mem.eql(u8, ct, "linux-x86_64")) {
            target_triple_opt = "x86_64-unknown-linux-gnu";
        } else if (std.mem.eql(u8, ct, "macos-arm64")) {
            target_triple_opt = "aarch64-apple-darwin";
        } else if (std.mem.eql(u8, ct, "macos-x86_64")) {
            target_triple_opt = "x86_64-apple-darwin";
        } else if (std.mem.eql(u8, ct, "windows-x86_64")) {
            // Use the windows-gnu OS triple, NOT *-w64-mingw32: modern LLVM treats "mingw32" as an
            // unknown OS and defaults the object format to ELF, which lld-link then rejects. The
            // pc-windows-gnu triple selects COFF (what the mingw/lld-link toolchain expects).
            target_triple_opt = "x86_64-pc-windows-gnu";
        } else {
            std.debug.print("Unsupported target switch: {s}\n", .{ct});
            return error.UnsupportedTarget;
        }
    }

    // Derive output path if not provided.
    if (output_path.len == 0) {
        const base_name = try basenameWithoutExtension(file_path, allocator);
        defer allocator.free(base_name);
        if (std.mem.eql(u8, target, "--wasm")) {
            output_path = try std.fmt.allocPrint(allocator, "{s}.wasm", .{base_name});
        } else {
            output_path = try allocator.dupe(u8, base_name);
        }
    }


    if (watch_mode) {
        std.debug.print("[watch] Watching for changes...\n", .{});
        var mtimes = std.StringHashMap(i96).init(allocator);
        defer {
            var iter = mtimes.keyIterator();
            while (iter.next()) |k| allocator.free(k.*);
            mtimes.deinit();
        }

        while (true) {
            var pass_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const pass_allocator = pass_arena.allocator();
            
            var visited = std.StringHashMap(void).init(pass_allocator);
            
            compileProgram(pass_allocator, init, file_path, target, output_path, is_release, target_triple_opt, &visited, build_mode, build_obj_dir, build_hash_path) catch |err| {
                std.debug.print("Compilation failed: {any}\n", .{err});
            };

            // Update mtimes for newly visited files
            var file_iter = visited.keyIterator();
            while (file_iter.next()) |file| {
                if (!mtimes.contains(file.*)) {
                    if (getFileMtime(init.io, file.*)) |mt| {
                        const dup_key = try allocator.dupe(u8, file.*);
                        try mtimes.put(dup_key, mt);
                    } else |_| {}
                }
            }

            pass_arena.deinit();

            var changed = false;
            while (!changed) {
                init.io.sleep(std.Io.Duration.fromMilliseconds(500), .boot) catch {};
                
                if (mtimes.count() == 0) {
                    if (getFileMtime(init.io, file_path)) |mt| {
                        const dup_key = try allocator.dupe(u8, file_path);
                        try mtimes.put(dup_key, mt);
                    } else |_| {}
                }

                var iter = mtimes.iterator();
                while (iter.next()) |entry| {
                    const file = entry.key_ptr.*;
                    const old_mt = entry.value_ptr.*;
                    if (getFileMtime(init.io, file)) |new_mt| {
                        if (new_mt > old_mt) {
                            std.debug.print("\n[watch] File changed: {s}. Recompiling...\n", .{file});
                            entry.value_ptr.* = new_mt;
                            changed = true;
                            break;
                        }
                    } else |_| {}
                }
            }
        }
    } else {
        var visited = std.StringHashMap(void).init(allocator);
        defer {
            var iter = visited.keyIterator();
            while (iter.next()) |k| allocator.free(k.*);
            visited.deinit();
        }
        try compileProgram(allocator, init, file_path, target, output_path, is_release, target_triple_opt, &visited, build_mode, build_obj_dir, build_hash_path);
    }
}
