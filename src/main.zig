
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");

extern fn nova_lld_link_macho(argv: [*]const [*:0]const u8, argc: c_int) c_int;
extern fn nova_lld_link_wasm(argv: [*]const [*:0]const u8, argc: c_int) c_int;

// Codegen builds its target machine with LLVMRelocDefault, which on ELF is Reloc::Static — the
// object therefore carries absolute R_X86_64_32S relocations. Ubuntu's clang links -pie by default,
// and a PIE image cannot hold those ("relocation R_X86_64_32S against `.text` can not be used when
// making a PIE object"), so the link fails for any program whose layout produces one. Tell the
// driver what codegen actually emitted. The alternative is a PIC target machine, which is a codegen
// change affecting every target; this is the narrow, matching fix.
const pie_flags: []const []const u8 = if (builtin.target.os.tag == .linux) &.{"-no-pie"} else &.{};

const dead_strip_flag: []const u8 = switch (builtin.target.os.tag) {
    .macos => "-Wl,-dead_strip",
    // clang++ on Windows drives MSVC's link.exe, which does not understand --gc-sections
    // (it arrives as `/-gc-sections` → LNK4044 and no stripping). /OPT:REF is its equivalent.
    .windows => "-Wl,/OPT:REF",
    else => "-Wl,--gc-sections",
};

fn macSdkPath(environ: anytype, io: std.Io) []const u8 {
    if (environ.get("SDKROOT")) |s| return s;
    const clt = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
    Io.Dir.access(.cwd(), io, clt, .{}) catch {
        return "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    };
    return clt;
}

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
    // POSIX library names that MSVC folds into its CRT — there is no c.lib/m.lib/pthread.lib to
    // open, so passing them through is a hard LNK1181, not a harmless no-op. `extern("c")` decls
    // in std are the common source. The symbols themselves come from the UCRT, already linked.
    if (builtin.target.os.tag == .windows) {
        for (&[_][]const u8{ "c", "m", "pthread", "dl", "rt" }) |implicit| {
            if (std.mem.eql(u8, lib, implicit)) return;
        }
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

        "-dead_strip",
    });
    for (objs) |o| try args.append(allocator, o);
    const nova_lib = try std.fmt.allocPrint(allocator, "-L{s}/lib", .{shared_nova});
    try args.appendSlice(allocator, &.{ nova_lib, "-lnovacore", "-L/opt/homebrew/lib" });
    try appendWolfsslLink(&args, allocator, shared_nova, io);
    for (ffi_libs) |lib| {
        try appendFfiLib(&args, allocator, shared_nova, io, lib);
    }
    try args.appendSlice(allocator, &.{ "-o", output_path });

    var cargv = std.ArrayList([*:0]const u8).empty;
    defer cargv.deinit(allocator);
    for (args.items) |a| try cargv.append(allocator, try allocator.dupeZ(u8, a));

    const rc = nova_lld_link_macho(cargv.items.ptr, @intCast(cargv.items.len));
    if (rc != 0) {
        std.debug.print("in-process LLD (macho) failed with code {d}\n", .{rc});
        return error.LinkFailed;
    }
}

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
    _ = environ; // Boost include (formerly from BOOST_PREFIX) retired in M4; no env lookup needed.
    const target = mapCrossTarget(llvm_triple) orelse return false;

    const rt_obj = try std.fmt.allocPrint(allocator, "{s}/lib/novacore_{s}.o", .{ shared_nova, target.zig });
    if (Io.Dir.access(.cwd(), io, rt_obj, .{})) |_| {} else |_| {

        const rt_src = try std.fmt.allocPrint(allocator, "{s}/src/runtime/runtime.cpp", .{shared_nova});

        std.debug.print("[T1] cross-compiling the C++ runtime for {s} (one-time; caches to ~/.nova/lib) ...\n", .{target.zig});
        // Boost.Asio retired (M4): the runtime is reactor-native, no Boost include needed.
        // zlib retired: compression is pure Nova (compress/deflate.nova), no zlib include/link.
        const rc_args = [_][]const u8{ "zig", "c++", "-target", target.zig, "-std=c++20", "-O2", "-DNOVA_DROP_ARENA", "-c", rt_src, "-o", rt_obj };
        var rc_child = try std.process.spawn(io, .{ .argv = &rc_args });
        switch (try rc_child.wait(io)) {
            .exited => |code| if (code != 0) {
                std.debug.print("[T1] runtime cross-compile failed for {s} (code {d})\n", .{ target.zig, code });
                return error.LinkFailed;
            },
            else => return error.LinkFailed,
        }
    }

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "zig", "c++", "-target", target.zig });
    if (target.static) try args.append(allocator, "-static");
    if (is_release) try args.append(allocator, "-O3");
    for (objs) |o| try args.append(allocator, o);
    try args.append(allocator, rt_obj);

    // zlib retired: compression is pure Nova (compress/deflate.nova), so the vendored zlib .c files
    // are no longer compiled into cross targets.
    if (std.mem.indexOf(u8, target.zig, "windows") != null)
        try args.appendSlice(allocator, &.{ "-lws2_32", "-lmswsock", "-lbcrypt" });
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

fn linkWasmInProcess(allocator: std.mem.Allocator, obj_path: []const u8, output_path: []const u8) !void {
    const argv = [_][]const u8{
        "wasm-ld", "--no-entry", "--export-all", "--export-memory", "--allow-undefined",

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

/// Append the Nova C++ runtime to a clang++ link line.
///
/// On Windows clang++ targets MSVC, whose link.exe resolves `-lnovacore` to `novacore.lib`
/// and cannot read the GNU-format `libnovacore.a` that llvm-ar writes (LNK1104). The runtime is
/// a unity build — one `runtime.cpp` → one object — so the COFF object is linked directly there:
/// identical to demand-loading the archive's single member, minus the archive-format question.
fn appendRuntimeLink(
    args: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    shared_nova: []const u8,
    lib_name: []const u8,
) !void {
    if (builtin.target.os.tag == .windows) {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lib/{s}.o", .{ shared_nova, lib_name }));
        // compiler-rt's builtins carry the 128-bit helpers (__udivti3/__umodti3, used by
        // decimal.cpp's __int128 math); MSVC's CRT has no equivalent. clang++ only finds the
        // builtins archive under the windows/ layout when -rtlib=compiler-rt is explicit —
        // without it the link dies on unresolved __udivti3.
        try args.append(allocator, "-rtlib=compiler-rt");
        // Same system libs the cross-link (crossLinkViaZig) already passes for windows targets:
        // sockets (reactor/os.socket), AcceptEx/ConnectEx, and BCryptGenRandom for nova_getrandom.
        try args.appendSlice(allocator, &.{ "-lws2_32", "-lmswsock", "-lbcrypt" });
        return;
    }
    try args.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}/lib", .{shared_nova}));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib_name}));
    try args.append(allocator, "-L/opt/homebrew/lib");
}

fn appendWolfsslLink(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, shared_nova: []const u8, io: std.Io) !void {
    // wolfSSL was retired in M13 (TLS is pure Nova). Nothing to link; kept as a no-op so the three
    // link sites need no change. getentropy() (crypto.cpp) is in libSystem/glibc, no framework needed.
    _ = args;
    _ = allocator;
    _ = shared_nova;
    _ = io;
}

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const llvm_codegen = @import("codegen/llvm_codegen.zig");
const codegen_arc = @import("codegen/arc.zig");
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

// Compile-target facts, derived once per compilation from `--target`/triple (or the host for --native)
// and exposed to Nova source as the synthesized `builtin` module + used to pick target-conditional files.
const TargetInfo = struct {
    os: []const u8, // "darwin" | "linux" | "windows" | "wasm"
    arch: []const u8, // "aarch64" | "x86_64" | "wasm32"
    ptr_size: u8,
    is_posix: bool,
};

fn hostOs() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => "darwin",
    };
}
fn hostArch() []const u8 {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "x86_64",
    };
}

fn deriveTargetInfo(target: []const u8, triple: ?[]const u8) TargetInfo {
    if (std.mem.eql(u8, target, "--wasm")) {
        return .{ .os = "wasm", .arch = "wasm32", .ptr_size = 4, .is_posix = false };
    }
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    var os: []const u8 = hostOs();
    var arch: []const u8 = hostArch();
    if (triple) |t| {
        if (has(t, "linux")) {
            os = "linux";
        } else if (has(t, "windows") or has(t, "mingw") or has(t, "w64")) {
            os = "windows";
        } else if (has(t, "darwin") or has(t, "apple") or has(t, "macos")) {
            os = "darwin";
        }
        if (has(t, "aarch64") or has(t, "arm64")) {
            arch = "aarch64";
        } else if (has(t, "x86_64") or has(t, "x86-64") or has(t, "amd64")) {
            arch = "x86_64";
        }
    }
    return .{ .os = os, .arch = arch, .ptr_size = 8, .is_posix = std.mem.eql(u8, os, "darwin") or std.mem.eql(u8, os, "linux") };
}

// Source of the compiler-synthesized `platform` module (never a file on disk).
fn genPlatformSource(allocator: std.mem.Allocator, t: TargetInfo) ![]const u8 {
    const b = struct {
        fn s(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.s;
    return try std.fmt.allocPrint(allocator,
        \\pub const os: string = "{s}";
        \\pub const arch: string = "{s}";
        \\pub const pointerSize: int = {d};
        \\pub const isDarwin: bool = {s};
        \\pub const isLinux: bool = {s};
        \\pub const isWindows: bool = {s};
        \\pub const isWasm: bool = {s};
        \\pub const isPosix: bool = {s};
        \\
    , .{
        t.os,                                    t.arch, t.ptr_size,
        b(std.mem.eql(u8, t.os, "darwin")),      b(std.mem.eql(u8, t.os, "linux")),
        b(std.mem.eql(u8, t.os, "windows")),     b(std.mem.eql(u8, t.os, "wasm")),
        b(t.is_posix),
    });
}

// True if `cand` (a `.nova` path) exists, in cwd or the installed ~/.nova/std fallback.
fn suffixedFileExists(cand: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) bool {
    if (Io.Dir.access(.cwd(), io, cand, .{})) |_| {
        return true;
    } else |_| {}
    if (std.mem.startsWith(u8, cand, "src/std/")) {
        const sub = cand[8..];
        const h = home orelse "/";
        const abs = std.fmt.allocPrint(allocator, "{s}/.nova/std/{s}", .{ h, sub }) catch return false;
        defer allocator.free(abs);
        if (Io.Dir.access(.cwd(), io, abs, .{})) |_| {
            return true;
        } else |_| {}
    }
    return false;
}

// Platform-axis variant selection (restructure R1): given a resolved `dir/name.nova`, pick the
// most-specific existing target variant, keyed off the SAME os/arch the synthesized `platform` module
// exposes. Search order (first existing wins):
//   1. dir/<os>/<arch>/name.nova     2. dir/<os>/name.nova
//   3. dir/posix/<arch>/name.nova    4. dir/posix/name.nova        (3,4 only when is_posix)
//   5. dir/name_<os>.nova            (LEGACY suffix -- kept so un-migrated modules still resolve)
// Returns null when none exists (the caller then reads the flat base path). Module identity stays the
// BASE path so `import foo` links regardless of which file's bytes were read.
fn targetVariantPath(path: []const u8, os_tag: []const u8, arch: []const u8, is_posix: bool, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, ".nova")) return null;
    const stem = path[0 .. path.len - 5];
    const slash = std.mem.lastIndexOfScalar(u8, stem, '/') orelse stem.len;
    const dir = if (slash == stem.len) "" else stem[0..slash];
    const name = if (slash == stem.len) stem else stem[slash + 1 ..];

    const tryCand = struct {
        fn go(cand: []const u8, a: std.mem.Allocator, zio: std.Io, h: ?[]const u8) ?[]const u8 {
            if (suffixedFileExists(cand, a, zio, h)) return cand;
            a.free(cand);
            return null;
        }
    }.go;

    // Mechanism-named backends: the net/eventloop module is selected by MECHANISM (kqueue/epoll/iocp),
    // not by an os/ folder, so it maps to net/ev/<mechanism>.nova per target. The module identity stays
    // `net/eventloop` (the caller's base path), so importers' `eventloop.X` still resolves. io_uring is
    // runtime-dispatched inside the linux (epoll) unit, so linux -> net/ev/epoll.nova.
    if (std.mem.eql(u8, dir, "src/std/net") and std.mem.eql(u8, name, "eventloop")) {
        const mech: []const u8 = if (std.mem.eql(u8, os_tag, "darwin")) "kqueue" else if (std.mem.eql(u8, os_tag, "windows")) "iocp" else "epoll";
        if (std.fmt.allocPrint(allocator, "src/std/net/ev/{s}.nova", .{mech}) catch null) |c| {
            if (tryCand(c, allocator, io, home)) |hit| return hit;
        }
    }

    // 1. dir/<os>/<arch>/name.nova
    if (std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}.nova", .{ dir, os_tag, arch, name }) catch null) |c| {
        if (tryCand(c, allocator, io, home)) |hit| return hit;
    }
    // 2. dir/<os>/name.nova
    if (std.fmt.allocPrint(allocator, "{s}/{s}/{s}.nova", .{ dir, os_tag, name }) catch null) |c| {
        if (tryCand(c, allocator, io, home)) |hit| return hit;
    }
    if (is_posix) {
        // 3. dir/posix/<arch>/name.nova
        if (std.fmt.allocPrint(allocator, "{s}/posix/{s}/{s}.nova", .{ dir, arch, name }) catch null) |c| {
            if (tryCand(c, allocator, io, home)) |hit| return hit;
        }
        // 4. dir/posix/name.nova
        if (std.fmt.allocPrint(allocator, "{s}/posix/{s}.nova", .{ dir, name }) catch null) |c| {
            if (tryCand(c, allocator, io, home)) |hit| return hit;
        }
    }
    // 5. legacy dir/name_<os>.nova
    if (std.fmt.allocPrint(allocator, "{s}_{s}.nova", .{ stem, os_tag }) catch null) |c| {
        if (tryCand(c, allocator, io, home)) |hit| return hit;
    }
    return null;
}

// A resolved import may be either `<path>.nova` or its `<path>.nsx` sibling. `.nsx` is the SAME Nova
// language, filed under a distinct extension so view / JSX (NSX) code is kept apart from plain logic.
// Given a freshly-allocated `.nova` candidate, return whichever of the two exists as an owned path;
// otherwise free the candidate and return null. The `.nova` form is tried first so it wins on a tie.
fn existingSource(nova_candidate: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    if (Io.Dir.access(.cwd(), io, nova_candidate, .{})) |_| {
        return nova_candidate;
    } else |_| {}
    if (std.mem.endsWith(u8, nova_candidate, ".nova")) {
        if (std.fmt.allocPrint(allocator, "{s}.nsx", .{nova_candidate[0 .. nova_candidate.len - 5]}) catch null) |nsx| {
            if (Io.Dir.access(.cwd(), io, nsx, .{})) |_| {
                allocator.free(nova_candidate);
                return nsx;
            } else |_| {
                allocator.free(nsx);
            }
        }
    }
    allocator.free(nova_candidate);
    return null;
}

fn resolveImportPath(base_path: []const u8, module_name: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, module_name, "platform")) {
        // Synthetic module — parsed from generated source (see loadProgram), but given a src/std path so
        // canonicalModulePrefix maps its declarations to module "platform" (the import's qualifier).
        return try allocator.dupe(u8, "src/std/platform.nova");
    }
    if (std.mem.startsWith(u8, module_name, "std/")) {
        const sub = module_name[4..];
        return try std.fmt.allocPrint(allocator, "src/std/{s}.nova", .{sub});
    }
    const std_modules = [_][]const u8{ "net/tcp/stream", "net/tcp/server", "net/tcp/client", "net/url", "net/dns", "net/dial", "net/aio", "net/asynctls", "web/request", "web/response", "web/mime", "web/status", "web/methods", "web/client", "web/mediator", "web/routing", "web/middleware", "web/url", "web/cookie", "web/cors", "web/request_id", "web/redact", "web/secure_headers", "web/body_limit", "web/recovery", "web/rate_limit", "web/multipart", "web/session", "web/csrf", "web/di", "web/controller", "web/app", "web/logger", "web/httpparser", "concurrency/fiber", "concurrency/channel", "concurrency/asyncchan", "concurrency/atomic", "concurrency/async_util", "concurrency/actor", "io/file", "io/dir", "collections/list", "collections/map", "collections/set", "collections/string_builder", "collections/deque", "collections/heap", "collections/ordered_map", "serde/json", "serde/source", "serde/bson", "serde/yaml", "mem/allocator", "mem/memory", "string", "datetime", "math", "assert", "traits", "env", "log", "config", "metrics", "crypto/hash/sha", "crypto/hash/md5", "crypto/base64", "crypto/random", "crypto/scram", "crypto/hash/sha256", "crypto/hash/sha512", "crypto/hash/sha1", "crypto/mac/hmac", "crypto/kdf/hkdf", "crypto/kdf/pbkdf2", "crypto/cipher/chacha20", "crypto/mac/poly1305", "crypto/aead/chachapoly", "crypto/cipher/aes", "crypto/mac/ghash", "crypto/aead/aesgcm", "crypto/cipher/aesctr", "crypto/ecc/x25519", "crypto/ecc/p256", "crypto/ecc/p384", "crypto/rsa", "crypto/x509", "crypto/ocsp", "crypto/crl", "crypto/tls/13/tls", "crypto/tls/13/handshake", "crypto/tls/13/tlsClient", "crypto/tls/13/tlsServer", "crypto/tls/12/prf", "crypto/tls/truststore", "crypto/tls/revocation", "crypto/tls/12/client12", "process", "fs", "exception", "data/db", "data/sql/pool", "text/utf8", "text/regex", "webview", "web/static_content", "web/circuit_breaker", "resilience/breaker", "compress/gzip", "compress/deflate", "compress/lz4", "data/orm", "os/sys", "os/backend", "os/socket", "os/darwin/kqueue", "os/linux/epoll", "os/windows/win32", "os/windows/fs", "os/windows/proc", "os/windows/winsock", "io/slab", "io/arena", "net/poller", "net/eventedio", "net/tls13async", "net/tlsmembio", "net/tls12bio", "net/httpsclient", "net/eventloop" };
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
    if (std.mem.eql(u8, module_name, "deque")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/deque.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "heap")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/heap.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "ordered_map")) {
        return try std.fmt.allocPrint(allocator, "src/std/collections/ordered_map.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "db")) {
        return try std.fmt.allocPrint(allocator, "src/std/data/db.nova", .{});
    }
    if (std.mem.eql(u8, module_name, "pool")) {
        return try std.fmt.allocPrint(allocator, "src/std/data/sql/pool.nova", .{});
    }

    const dir_end = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
    const dir = if (dir_end == 0) "" else base_path[0..dir_end];

    // Importer-relative resolution WINS over any global package match. A driver package's own
    // `src/codec.nova` must resolve for `import codec` whether the importer is `src/postgres.nova`
    // (same dir) or `tests/66_x.nova` (reaches it via ../src), even though several driver packages
    // define a same-named `codec.nova`. Walking the importer's own tree first is what lets the
    // internal modules drop their per-driver prefixes (pg_/my_/ms_/bt_/mongo_): without it the
    // global scan below (resolveFromLocalPackages / resolveFromPackageCache) returns whichever
    // package iterates first, so bare names could only stay unique via those prefixes.
    var current_len = dir.len;
    while (current_len > 0) {
        const current_dir = dir[0..current_len];

        const src_candidate = try std.fmt.allocPrint(allocator, "{s}/src/{s}.nova", .{ current_dir, module_name });
        if (existingSource(src_candidate, allocator, io)) |hit| return hit;

        const dir_candidate = try std.fmt.allocPrint(allocator, "{s}/{s}.nova", .{ current_dir, module_name });
        if (existingSource(dir_candidate, allocator, io)) |hit| return hit;

        const last_slash = std.mem.lastIndexOfScalar(u8, current_dir, '/') orelse break;
        current_len = last_slash;
    }

    if (resolveFromLocalPackages(module_name, dir, allocator, io)) |local_hit| {
        return local_hit;
    }

    {
        const root_src = try std.fmt.allocPrint(allocator, "src/{s}.nova", .{module_name});
        if (existingSource(root_src, allocator, io)) |hit| return hit;
    }

    if (resolveFromPackageCache(module_name, allocator, io, home)) |cache_hit| {
        return cache_hit;
    }

    if (dir.len == 0) {
        return try std.fmt.allocPrint(allocator, "{s}.nova", .{module_name});
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}.nova", .{ dir, module_name });
}

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
            if (existingSource(candidate, allocator, io)) |hit| return hit;
        }
    }
    return null;
}

// Scan a single `packages/` root for a module: first `<root>/nova-<module>/src/<module>.nova` (the
// package's own top module), then `<root>/<any-pkg>/src/<module>.nova` (a flat module inside any
// package, e.g. nova-datastar's `datastar`/`ds_sink`). Returns an owned path or null.
fn scanPackageRoot(root: []const u8, module_name: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const direct = std.fmt.allocPrint(allocator, "{s}/nova-{s}/src/{s}.nova", .{ root, module_name, module_name }) catch return null;
    if (existingSource(direct, allocator, io)) |hit| return hit;
    const dir = Io.Dir.openDir(.cwd(), io, root, .{ .iterate = true }) catch return null;
    defer Io.Dir.close(dir, io);
    var it = Io.Dir.iterate(dir);
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = std.fmt.allocPrint(allocator, "{s}/{s}/src/{s}.nova", .{ root, entry.name, module_name }) catch continue;
        if (existingSource(candidate, allocator, io)) |hit| return hit;
    }
    return null;
}

// Resolve `module_name` from a sibling `packages/` directory. Searches the CWD-relative roots
// (`packages`, `../packages`) AND a `packages/` dir at every ANCESTOR of the importing file, so a
// cross-package import (e.g. an app under packages/nova-orchestrator/examples importing nova-datastar's
// `datastar`) resolves no matter what the process CWD is — `nova build --file <deep/path>` included.
fn resolveFromLocalPackages(module_name: []const u8, importer_dir: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    // CWD-relative `packages/` at several parent depths. `nova build --file <deep/path>` and `nova test`
    // run from different CWDs (the project dir, the lang dir, the file's dir), so probe a few `../` levels
    // rather than assume one. First existing package with the module wins.
    const cwd_roots = [_][]const u8{
        "packages", "../packages", "../../packages", "../../../packages",
        "../../../../packages", "../../../../../packages",
    };
    for (cwd_roots) |root| {
        if (scanPackageRoot(root, module_name, allocator, io)) |hit| return hit;
    }

    var current_len = importer_dir.len;
    while (current_len > 0) {
        const anc = importer_dir[0..current_len];
        const root = std.fmt.allocPrint(allocator, "{s}/packages", .{anc}) catch return null;
        if (scanPackageRoot(root, module_name, allocator, io)) |hit| {
            allocator.free(root);
            return hit;
        }
        allocator.free(root);
        const last_slash = std.mem.lastIndexOfScalar(u8, anc, '/') orelse break;
        current_len = last_slash;
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

            for (s.methods) |method| {
                for (method.decl.attributes) |attr| {
                    if (attr == .route) {
                        const route = attr.route;

                        const callee = try allocator.create(ast.Expression);
                        callee.* = ast.Expression{ .kind = .{ .field_access = .{
                                .object = try allocator.create(ast.Expression),
                                .field = "add",
                                .span = s.span,
                            } } };
                        callee.kind.field_access.object.* = ast.Expression{ .kind = .{ .ident = "router" } };

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

fn serdeIsInt(n: []const u8) bool {
    const ints = [_][]const u8{ "i8", "u8", "byte", "i16", "u16", "short", "ushort", "i32", "u32", "int", "uint", "i64", "u64", "long", "ulong" };
    for (ints) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}
fn serdeIsFloat(n: []const u8) bool {

    const fs = [_][]const u8{ "f32", "f64", "float", "double" };
    for (fs) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

fn serdeEnumPayloadless(e: ast.EnumDecl) bool {
    for (e.variants) |v| {
        if (v.type_name != null or v.fields != null) return false;
    }
    return true;
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

    var enums = std.StringHashMap(ast.EnumDecl).init(allocator);
    defer enums.deinit();
    for (declarations.items) |decl| {
        if (decl == .enum_decl and serdeEnumPayloadless(decl.enum_decl)) {
            try enums.put(decl.enum_decl.name, decl.enum_decl);
        }
    }

    var src = std.ArrayList(u8).empty;

    var needed_enums = std.StringHashMap(void).init(allocator);
    defer needed_enums.deinit();
    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        if (!serializable.contains(decl.struct_decl.name)) continue;
        for (decl.struct_decl.fields) |f| {
            const en: ?[]const u8 = switch (f.type_name) {
                .ident => |tn| tn,
                .optional => |inner| if (inner.* == .ident) inner.ident else null,
                else => null,
            };
            if (en) |name| if (enums.contains(name)) try needed_enums.put(name, {});
        }
    }
    {
        var it = needed_enums.keyIterator();
        while (it.next()) |k| {
            const en = enums.get(k.*).?;

            try serdeAppendf(&src, allocator, "fn {s}__name(e: {s}): string {{\n    switch (e) {{\n", .{ en.name, en.name });
            for (en.variants) |v| {
                try serdeAppendf(&src, allocator, "        case {s}.{s}: {{ return \"{s}\"; }}\n", .{ en.name, v.name, v.name });
            }
            try serdeAppendf(&src, allocator, "    }}\n    return \"\";\n}}\n", .{});
            try serdeAppendf(&src, allocator, "fn {s}__fromName(s: string): {s} {{\n", .{ en.name, en.name });
            for (en.variants) |v| {
                try serdeAppendf(&src, allocator, "    if (string.eql(s, \"{s}\")) {{ return {s}.{s}; }}\n", .{ v.name, en.name, v.name });
            }
            try serdeAppendf(&src, allocator, "    return {s}.{s};\n}}\n", .{ en.name, en.variants[0].name });
        }
    }

    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        const s = decl.struct_decl;
        if (!serializable.contains(s.name)) continue;

        try serdeAppendf(&src, allocator, "fn {s}__bind(src: ValueSource): {s} {{\n    let obj = {s}();\n", .{ s.name, s.name, s.name });
        for (s.fields) |f| {
            const fname = f.name;
            switch (f.type_name) {
                .ident => |tn| {
                    // has-guard every field so an ABSENT key keeps the value init() set (the documented
                    // "__bind overwrites the fields it finds" contract). Without the guard an omitted key
                    // zero-filled the field, so a partial JSON/YAML document silently wiped the defaults.
                    if (std.mem.eql(u8, tn, "string")) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getString(\"{s}\"); }}\n", .{ fname, fname, fname });
                    } else if (serdeIsInt(tn)) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getInt(\"{s}\"); }}\n", .{ fname, fname, fname });
                    } else if (std.mem.eql(u8, tn, "bool")) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getBool(\"{s}\"); }}\n", .{ fname, fname, fname });
                    } else if (std.mem.eql(u8, tn, "decimal")) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getDecimal(\"{s}\"); }}\n", .{ fname, fname, fname });
                    } else if (serdeIsFloat(tn)) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getFloat(\"{s}\"); }}\n", .{ fname, fname, fname });
                    } else if (serializable.contains(tn)) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = {s}__bind(src.getChild(\"{s}\")); }}\n", .{ fname, fname, tn, fname });
                    } else if (enums.contains(tn)) {
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = {s}__fromName(src.getString(\"{s}\")); }}\n", .{ fname, fname, tn, fname });
                    }
                },
                .optional => |inner| {

                    if (inner.* == .ident) {
                        const itn = inner.ident;
                        if (std.mem.eql(u8, itn, "string")) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getString(\"{s}\"); }}\n", .{ fname, fname, fname });
                        } else if (serdeIsInt(itn)) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getInt(\"{s}\"); }}\n", .{ fname, fname, fname });
                        } else if (std.mem.eql(u8, itn, "bool")) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getBool(\"{s}\"); }}\n", .{ fname, fname, fname });
                        } else if (std.mem.eql(u8, itn, "decimal")) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getDecimal(\"{s}\"); }}\n", .{ fname, fname, fname });
                        } else if (serdeIsFloat(itn)) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getFloat(\"{s}\"); }}\n", .{ fname, fname, fname });
                        } else if (serializable.contains(itn)) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = {s}__bind(src.getChild(\"{s}\")); }}\n", .{ fname, fname, itn, fname });
                        } else if (enums.contains(itn)) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = {s}__fromName(src.getString(\"{s}\")); }}\n", .{ fname, fname, itn, fname });
                        }
                    }
                },
                .generic => |g| {
                    if (std.mem.eql(u8, g.name, "List") and g.params.len == 1) {
                        // has-guard the whole list too: an absent key keeps the init() default list
                        // rather than resetting it to empty (matches the scalar/nested guard above).
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{\n", .{fname});
                        switch (g.params[0]) {
                            .ident => |en| try serdeAppendf(&src, allocator, "    obj.{s} = List<{s}>();\n", .{ fname, en }),
                            else => {},
                        }
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
                        try serdeAppendf(&src, allocator, "    }}\n", .{});   // close if (src.has(...))
                    }
                },
                else => {},
            }
        }
        try src.appendSlice(allocator, "    return obj;\n}\n\n");

        try serdeAppendf(&src, allocator, "fn {s}__toJson(obj: {s}): string {{\n    let out = \"{{\";\n    let __sep = \"\";\n", .{ s.name, s.name });
        for (s.fields) |f| {
            const fname = f.name;
            switch (f.type_name) {
                .ident => |tn| {
                    if (std.mem.eql(u8, tn, "string")) {
                        try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":\" + json.quote(obj.{s}); __sep = \",\";\n", .{ fname, fname });
                    } else if (serdeIsInt(tn) or std.mem.eql(u8, tn, "bool")) {
                        try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":\" + obj.{s}; __sep = \",\";\n", .{ fname, fname });
                    } else if (std.mem.eql(u8, tn, "decimal")) {

                        try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":\" + `${{obj.{s}}}`; __sep = \",\";\n", .{ fname, fname });
                    } else if (serializable.contains(tn)) {
                        try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":\" + {s}__toJson(obj.{s}); __sep = \",\";\n", .{ fname, tn, fname });
                    } else if (enums.contains(tn)) {

                        try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":\" + json.quote({s}__name(obj.{s})); __sep = \",\";\n", .{ fname, tn, fname });
                    }

                },
                .optional => |inner| {

                    if (inner.* == .ident) {
                        const itn = inner.ident;
                        var vexpr: ?[]const u8 = null;
                        if (std.mem.eql(u8, itn, "string")) {
                            vexpr = "json.quote(__v)";
                        } else if (serdeIsInt(itn) or std.mem.eql(u8, itn, "bool")) {
                            vexpr = "__v";
                        } else if (std.mem.eql(u8, itn, "decimal")) {
                            vexpr = "`${__v}`";
                        } else if (serializable.contains(itn)) {
                            vexpr = try std.fmt.allocPrint(allocator, "{s}__toJson(__v)", .{itn});
                        } else if (enums.contains(itn)) {
                            vexpr = try std.fmt.allocPrint(allocator, "json.quote({s}__name(__v))", .{itn});
                        }
                        if (vexpr) |ve| {
                            try serdeAppendf(&src, allocator, "    {{ let __v = obj.{s}; if (__v != undefined) {{ out = out + __sep + \"\\\"{s}\\\":\" + {s}; __sep = \",\"; }} }}\n", .{ fname, fname, ve });
                        }
                    }
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
                            try serdeAppendf(&src, allocator, "    out = out + __sep + \"\\\"{s}\\\":[\"; __sep = \",\";\n", .{fname});
                            try serdeAppendf(&src, allocator, "    {{ let __i = 0; while (__i < obj.{s}.size()) {{ if (__i > 0) {{ out = out + \",\"; }} out = out + {s}; __i = __i + 1; }} }}\n", .{ fname, itemexpr });
                            try src.appendSlice(allocator, "    out = out + \"]\";\n");
                        }
                    }
                },
                else => {},
            }
        }
        try src.appendSlice(allocator, "    out = out + \"}\";\n    return out;\n}\n\n");

        try serdeAppendf(&src, allocator, "fn {s}__dump(obj: {s}, sink: ValueSink): void {{\n", .{ s.name, s.name });
        for (s.fields) |f| {
            const fname = f.name;
            switch (f.type_name) {
                .ident => |tn| {
                    if (std.mem.eql(u8, tn, "string")) {
                        try serdeAppendf(&src, allocator, "    sink.putString(\"{s}\", obj.{s});\n", .{ fname, fname });
                    } else if (std.mem.eql(u8, tn, "bool")) {
                        try serdeAppendf(&src, allocator, "    sink.putBool(\"{s}\", obj.{s});\n", .{ fname, fname });
                    } else if (serdeIsInt(tn)) {
                        try serdeAppendf(&src, allocator, "    sink.putInt(\"{s}\", obj.{s});\n", .{ fname, fname });
                    } else if (std.mem.eql(u8, tn, "decimal")) {
                        try serdeAppendf(&src, allocator, "    sink.putDecimal(\"{s}\", obj.{s});\n", .{ fname, fname });
                    } else if (serdeIsFloat(tn)) {
                        try serdeAppendf(&src, allocator, "    sink.putFloat(\"{s}\", obj.{s});\n", .{ fname, fname });
                    } else if (enums.contains(tn)) {

                        try serdeAppendf(&src, allocator, "    sink.putString(\"{s}\", {s}__name(obj.{s}));\n", .{ fname, tn, fname });
                    }

                },
                .optional => |inner| {

                    if (inner.* == .ident) {
                        const itn = inner.ident;
                        var sink_fn: ?[]const u8 = null;
                        if (std.mem.eql(u8, itn, "string")) {
                            sink_fn = "putString";
                        } else if (std.mem.eql(u8, itn, "bool")) {
                            sink_fn = "putBool";
                        } else if (serdeIsInt(itn)) {
                            sink_fn = "putInt";
                        } else if (std.mem.eql(u8, itn, "decimal")) {
                            sink_fn = "putDecimal";
                        } else if (serdeIsFloat(itn)) {
                            sink_fn = "putFloat";
                        }
                        if (sink_fn) |sf| {
                            try serdeAppendf(&src, allocator, "    {{ let __v = obj.{s}; if (__v != undefined) {{ sink.{s}(\"{s}\", __v); }} }}\n", .{ fname, sf, fname });
                        } else if (enums.contains(itn)) {
                            try serdeAppendf(&src, allocator, "    {{ let __v = obj.{s}; if (__v != undefined) {{ sink.putString(\"{s}\", {s}__name(__v)); }} }}\n", .{ fname, fname, itn });
                        }
                    }
                },
                else => {},
            }
        }
        try src.appendSlice(allocator, "}\n\n");
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

fn generateMediatorDispatch(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
    var src = std.ArrayList(u8).empty;
    var by_name = std.ArrayList(u8).empty;
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
            // The response type arg is either a plain DTO `R` (always serialised as 200 JSON) or an
            // error union `R | E` (200 JSON on the ok side; on the error side the framework calls
            // `e.toResponse()`, so a handler can return any status). `HttpError` (web.response) is the
            // standard error type, but any type with a `toResponse(): Response` method works.
            var r_ok: []const u8 = "";
            var r_err: ?[]const u8 = null;
            switch (impl.type_args[1]) {
                .ident => |n| r_ok = n,
                .error_union => |eu| {
                    r_ok = switch (eu.ok.*) {
                        .ident => |n| n,
                        else => continue,
                    };
                    r_err = switch (eu.err.*) {
                        .ident => |n| n,
                        else => continue,
                    };
                },
                else => continue,
            }
            if (seen_q.contains(q)) continue;
            try seen_q.put(q, {});
            try qs.append(allocator, q);

            // Construct the handler, resolving each `init` parameter from the DI provider (ASP.NET-style
            // constructor injection). A handler with no constructor is just `H{}`; a handler that takes
            // dependencies becomes `H(__provider.require("Dep") as Dep, ...)`.
            var init_params: []const ast.Param = &.{};
            var handle_is_async = false;
            for (s.methods) |m| {
                if (std.mem.eql(u8, m.decl.name, "init")) {
                    init_params = m.decl.params;
                } else if (std.mem.eql(u8, m.decl.name, "handle")) {
                    handle_is_async = m.decl.is_async;
                }
            }
            // The generated dispatch is always `async` (so `by_name` is uniform and the App can await
            // it), but we only `await` the handler when its own `handle` is async — a sync handler is
            // called directly. This lets an async handler `await` a database driver, while a plain
            // handler pays no coroutine cost at its own call site.
            const await_kw: []const u8 = if (handle_is_async) "await " else "";
            var ctor_buf = std.ArrayList(u8).empty;
            defer ctor_buf.deinit(allocator);
            var di_ok = init_params.len > 0;
            if (di_ok) {
                try serdeAppendf(&ctor_buf, allocator, "{s}(", .{s.name});
                for (init_params, 0..) |p, pi| {
                    const dep: []const u8 = if (p.type_name) |tr| switch (tr) {
                        .ident => |n| n,
                        else => "",
                    } else "";
                    if (dep.len == 0) {
                        di_ok = false;
                        break;
                    }
                    if (pi > 0) try ctor_buf.appendSlice(allocator, ", ");
                    try serdeAppendf(&ctor_buf, allocator, "__provider.require(\"{s}\") as {s}", .{ dep, dep });
                }
                try ctor_buf.appendSlice(allocator, ")");
            }
            if (!di_ok) {
                ctor_buf.clearRetainingCapacity();
                try serdeAppendf(&ctor_buf, allocator, "{s}{{}}", .{s.name});
            }
            const handler_ctor = ctor_buf.items;

            // Raw-response escape hatch: a handler whose success type IS `Response` returns it verbatim
            // (its own status + Content-Type, e.g. text/html or text/event-stream from mediator.html/sse),
            // instead of the framework JSON-serialising a DTO. Detected by the response type name.
            const raw_ok = std.mem.eql(u8, r_ok, "Response") or std.mem.eql(u8, r_ok, "response.Response");
            if (r_err != null) {
                // ok helper returns `Response | E`, so `try` short-circuits the error out of it; the
                // dispatch then maps that error to a Response via its `toResponse()`.
                if (raw_ok) {
                    try serdeAppendf(&src, allocator,
                        "async fn __mediator_ok_{s}(src: ValueSource, __provider: ServiceProvider): Response | {s} {{\n" ++
                            "    let __h = {s};\n" ++
                            "    let __req = {s}__bind(src);\n" ++
                            "    return try {s}__h.handle(__req);\n" ++
                            "}}\n" ++
                            "async fn __mediator_dispatch_{s}(src: ValueSource, __provider: ServiceProvider): Response {{\n" ++
                            "    return await __mediator_ok_{s}(src, __provider) catch (__e) __e.toResponse();\n" ++
                            "}}\n\n", .{ q, r_err.?, handler_ctor, q, await_kw, q, q });
                } else {
                    try serdeAppendf(&src, allocator,
                        "async fn __mediator_ok_{s}(src: ValueSource, __provider: ServiceProvider): Response | {s} {{\n" ++
                            "    let __h = {s};\n" ++
                            "    let __req = {s}__bind(src);\n" ++
                            "    let __r = try {s}__h.handle(__req);\n" ++
                            "    let __resp = Response(Status.Ok, {s}__toJson(__r));\n" ++
                            "    __resp.setHeader(\"Content-Type\", \"application/json\");\n" ++
                            "    return __resp;\n" ++
                            "}}\n" ++
                            "async fn __mediator_dispatch_{s}(src: ValueSource, __provider: ServiceProvider): Response {{\n" ++
                            "    return await __mediator_ok_{s}(src, __provider) catch (__e) __e.toResponse();\n" ++
                            "}}\n\n", .{ q, r_err.?, handler_ctor, q, await_kw, r_ok, q, q });
                }
            } else {
                if (raw_ok) {
                    try serdeAppendf(&src, allocator,
                        "async fn __mediator_dispatch_{s}(src: ValueSource, __provider: ServiceProvider): Response {{\n" ++
                            "    let __h = {s};\n" ++
                            "    let __req = {s}__bind(src);\n" ++
                            "    return {s}__h.handle(__req);\n" ++
                            "}}\n\n", .{ q, handler_ctor, q, await_kw });
                } else {
                    try serdeAppendf(&src, allocator,
                        "async fn __mediator_dispatch_{s}(src: ValueSource, __provider: ServiceProvider): Response {{\n" ++
                            "    let __h = {s};\n" ++
                            "    let __req = {s}__bind(src);\n" ++
                            "    let __resp = Response(Status.Ok, {s}__toJson({s}__h.handle(__req)));\n" ++
                            "    __resp.setHeader(\"Content-Type\", \"application/json\");\n" ++
                            "    return __resp;\n" ++
                            "}}\n\n", .{ q, handler_ctor, q, r_ok, await_kw });
                }
            }
        }
    }

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

    try serdeAppendf(&src, allocator, "async fn __mediator_dispatch_by_name(__name: string, src: ValueSource, __provider: ServiceProvider): Response {{\n", .{});
    for (qs.items) |q| {
        try serdeAppendf(&by_name, allocator, "    if (string.eql(__name, \"{s}\")) {{ return await __mediator_dispatch_{s}(src, __provider); }}\n", .{ q, q });
    }
    try src.appendSlice(allocator, by_name.items);
    try src.appendSlice(allocator, "    return Response(Status.NotFound, \"\");\n}\n\n");

    var p = try parser.Parser.init(allocator, src.items, "<mediator-generated>", is_wasm);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("mediator dispatch generation failed to parse:\n{s}\n", .{src.items});
        return err;
    };
    for (prog.declarations) |d| {
        try declarations.append(allocator, d);
    }
}

// The RUNTIME mediator glue (web/rmediator.nova). For each `impl RequestHandler<Q,R>` this emits the
// tiny type-directed Nova the runtime cannot write itself: a widen `Q__asMessage`, an adapter
// `Q__Adapter` (downcast the erased request, build the handler with DI from the request scope, run it,
// serialise R), and it accumulates a `__registerHandlers(m)` that registers every adapter. The
// framework (dispatch, pipeline, DI, scopes, validation) lives in stdlib; this pass only writes the
// per-type glue. Emitted ALONGSIDE the legacy baked dispatch during the transition.
fn generateRuntimeMediator(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
    var src = std.ArrayList(u8).empty;
    var reg = std.ArrayList(u8).empty;
    defer reg.deinit(allocator);
    var disp = std.ArrayList(u8).empty;
    defer disp.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var found = false;

    // Only requests that opt into the runtime mediator (by implementing `Message`) get the runtime
    // glue. This lets the runtime path coexist with the legacy baked dispatch during the migration: a
    // handler whose request does not implement `Message` keeps using the old path untouched.
    var message_structs = std.StringHashMap(void).init(allocator);
    defer message_structs.deinit();
    // Per request type, its impl list (so we can record marker traits: any impl that is not a framework
    // trait becomes a marker the runtime can test with `ctx.requestIs("...")`).
    var req_impls = std.StringHashMap([]const ast.TraitImpl).init(allocator);
    defer req_impls.deinit();
    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        for (decl.struct_decl.impls) |impl| {
            if (std.mem.eql(u8, impl.name, "Message")) {
                try message_structs.put(decl.struct_decl.name, {});
                try req_impls.put(decl.struct_decl.name, decl.struct_decl.impls);
            }
        }
    }

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
            if (!message_structs.contains(q)) continue;
            var r_ok: []const u8 = "";
            var r_err: ?[]const u8 = null;
            switch (impl.type_args[1]) {
                .ident => |n| r_ok = n,
                .error_union => |eu| {
                    r_ok = switch (eu.ok.*) {
                        .ident => |n| n,
                        else => continue,
                    };
                    r_err = switch (eu.err.*) {
                        .ident => |n| n,
                        else => continue,
                    };
                },
                else => continue,
            }
            if (seen.contains(q)) continue;
            try seen.put(q, {});

            // handler construction via DI resolved from the per-request SCOPE (ctx.scope).
            var init_params: []const ast.Param = &.{};
            var handle_is_async = false;
            for (s.methods) |m| {
                if (std.mem.eql(u8, m.decl.name, "init")) {
                    init_params = m.decl.params;
                } else if (std.mem.eql(u8, m.decl.name, "handle")) {
                    handle_is_async = m.decl.is_async;
                }
            }
            const await_kw: []const u8 = if (handle_is_async) "await " else "";
            var ctor_buf = std.ArrayList(u8).empty;
            defer ctor_buf.deinit(allocator);
            var di_ok = init_params.len > 0;
            if (di_ok) {
                try serdeAppendf(&ctor_buf, allocator, "{s}(", .{s.name});
                for (init_params, 0..) |p, pi| {
                    const dep: []const u8 = if (p.type_name) |tr| switch (tr) {
                        .ident => |n| n,
                        else => "",
                    } else "";
                    if (dep.len == 0) {
                        di_ok = false;
                        break;
                    }
                    if (pi > 0) try ctor_buf.appendSlice(allocator, ", ");
                    try serdeAppendf(&ctor_buf, allocator, "ctx.scope.require(\"{s}\") as {s}", .{ dep, dep });
                }
                try ctor_buf.appendSlice(allocator, ")");
            }
            if (!di_ok) {
                ctor_buf.clearRetainingCapacity();
                try serdeAppendf(&ctor_buf, allocator, "{s}{{}}", .{s.name});
            }
            const handler_ctor = ctor_buf.items;

            found = true;
            // widen at a return boundary (Nova cannot widen a generic to a trait inline).
            try serdeAppendf(&src, allocator, "fn {s}__asMessage(q: {s}): Message {{ return q; }}\n", .{ q, q });

            // Raw-response escape hatch (see the runtime-dispatch site above): a `Response`-typed handler
            // result is emitted verbatim so a handler can return HTML / SSE / any content-type.
            const raw_ok = std.mem.eql(u8, r_ok, "Response") or std.mem.eql(u8, r_ok, "response.Response");
            if (r_err != null) {
                if (raw_ok) {
                    try serdeAppendf(&src, allocator,
                        "async fn {s}__rok(ctx: RequestContext): Response | {s} {{\n" ++
                            "    let __q = ctx.request as {s};\n" ++
                            "    let __h = {s};\n" ++
                            "    return try {s}__h.handle(__q);\n" ++
                            "}}\n" ++
                            "struct {s}__Adapter impl HandlerAdapter {{\n" ++
                            "    async fn execute(self: {s}__Adapter, ctx: RequestContext): Response {{\n" ++
                            "        return await {s}__rok(ctx) catch (__e) __e.toResponse();\n" ++
                            "    }}\n" ++
                            "}}\n\n", .{ q, r_err.?, q, handler_ctor, await_kw, q, q, q });
                } else {
                    try serdeAppendf(&src, allocator,
                        "async fn {s}__rok(ctx: RequestContext): Response | {s} {{\n" ++
                            "    let __q = ctx.request as {s};\n" ++
                            "    let __h = {s};\n" ++
                            "    let __r = try {s}__h.handle(__q);\n" ++
                            "    let __resp = Response(Status.Ok, {s}__toJson(__r));\n" ++
                            "    __resp.setHeader(\"Content-Type\", \"application/json\");\n" ++
                            "    return __resp;\n" ++
                            "}}\n" ++
                            "struct {s}__Adapter impl HandlerAdapter {{\n" ++
                            "    async fn execute(self: {s}__Adapter, ctx: RequestContext): Response {{\n" ++
                            "        return await {s}__rok(ctx) catch (__e) __e.toResponse();\n" ++
                            "    }}\n" ++
                            "}}\n\n", .{ q, r_err.?, q, handler_ctor, await_kw, r_ok, q, q, q });
                }
            } else {
                if (raw_ok) {
                    try serdeAppendf(&src, allocator,
                        "struct {s}__Adapter impl HandlerAdapter {{\n" ++
                            "    async fn execute(self: {s}__Adapter, ctx: RequestContext): Response {{\n" ++
                            "        let __q = ctx.request as {s};\n" ++
                            "        let __h = {s};\n" ++
                            "        return {s}__h.handle(__q);\n" ++
                            "    }}\n" ++
                            "}}\n\n", .{ q, q, q, handler_ctor, await_kw });
                } else {
                    try serdeAppendf(&src, allocator,
                        "struct {s}__Adapter impl HandlerAdapter {{\n" ++
                            "    async fn execute(self: {s}__Adapter, ctx: RequestContext): Response {{\n" ++
                            "        let __q = ctx.request as {s};\n" ++
                            "        let __h = {s};\n" ++
                            // Hoist the handler result into a `let` (as the error-union case does) so the
                            // ownership pass tracks and drops the response DTO after it is serialised.
                            // Inlining `__toJson(await __h.handle(__q))` left that owned DTO temp unreleased
                            // -- a per-request leak on every matched route.
                            "        let __r = {s}__h.handle(__q);\n" ++
                            "        let __resp = Response(Status.Ok, {s}__toJson(__r));\n" ++
                            "        __resp.setHeader(\"Content-Type\", \"application/json\");\n" ++
                            "        return __resp;\n" ++
                            "    }}\n" ++
                            "}}\n\n", .{ q, q, q, handler_ctor, await_kw, r_ok });
                }
            }

            // Record the request type's marker traits (impls that are not framework traits). A behaviour
            // opts in per request via a marker instead of per-type registration.
            try serdeAppendf(&reg, allocator, "    let __mk_{s} = List<string>();\n", .{q});
            if (req_impls.get(q)) |impls| {
                for (impls) |mi| {
                    if (std.mem.eql(u8, mi.name, "Message")) continue;
                    if (std.mem.eql(u8, mi.name, "RequestHandler")) continue;
                    if (std.mem.eql(u8, mi.name, "Request")) continue;
                    try serdeAppendf(&reg, allocator, "    __mk_{s}.push(\"{s}\");\n", .{ q, mi.name });
                }
            }
            try serdeAppendf(&reg, allocator, "    m.register(\"{s}\", {s}__Adapter{{}}, __mk_{s});\n", .{ q, q, q });

            // The HTTP endpoint side: bind the typed request from the source, widen it, and send it
            // through the runtime mediator. Keyed by the same type name the route is registered under.
            try serdeAppendf(&disp, allocator, "    if (string.eql(__key, \"{s}\")) {{ let __q = {s}__bind(src); return await m.send({s}__asMessage(__q), \"{s}\"); }}\n", .{ q, q, q, q });
        }
    }

    // Auto-register per-type validators: for each `impl Validator<Q>` generate an erased adapter that
    // downcasts the Message and calls the typed validator, then register it by request-type name.
    for (declarations.items) |decl| {
        if (decl != .struct_decl) continue;
        const vs = decl.struct_decl;
        for (vs.impls) |impl| {
            if (!std.mem.eql(u8, impl.name, "Validator")) continue;
            if (impl.type_args.len != 1) continue;
            const vq = switch (impl.type_args[0]) {
                .ident => |n| n,
                else => continue,
            };
            found = true;
            try serdeAppendf(&src, allocator,
                "struct {s}__ValAdapter impl ValidatorAdapter {{\n" ++
                    "    fn validate(self: {s}__ValAdapter, req: Message): List<string> {{\n" ++
                    "        let __q = req as {s};\n" ++
                    "        return {s}{{}}.validate(__q);\n" ++
                    "    }}\n" ++
                    "}}\n\n", .{ vs.name, vs.name, vq, vs.name });
            try serdeAppendf(&reg, allocator, "    m.registerValidator(\"{s}\", {s}__ValAdapter{{}});\n", .{ vq, vs.name });
        }
    }

    // Emit the two entry points whenever there is an App/router (even with no Message handlers) so
    // `App.init` (which calls `__registerHandlers`) and `App.dispatch` (which calls
    // `__mediator_dispatch_runtime`) always resolve. The runtime `Mediator` type they reference lives in
    // `web.mediator`, which a web app loads via `web.app`.
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
    if (!found and !has_router) return;

    try serdeAppendf(&src, allocator, "fn __registerHandlers(m: Mediator): void {{\n", .{});
    try src.appendSlice(allocator, reg.items);
    try src.appendSlice(allocator, "}\n\n");

    try serdeAppendf(&src, allocator, "async fn __mediator_dispatch_runtime(__key: string, src: ValueSource, m: Mediator): Response {{\n", .{});
    try src.appendSlice(allocator, disp.items);
    try src.appendSlice(allocator, "    return Response(Status.NotFound, \"Not Found\");\n}\n\n");

    var p = try parser.Parser.init(allocator, src.items, "<rmediator-generated>", is_wasm);
    const prog = p.parseProgram() catch |err| {
        std.debug.print("runtime mediator generation failed to parse:\n{s}\n", .{src.items});
        return err;
    };
    for (prog.declarations) |d| {
        try declarations.append(allocator, d);
    }
}

fn loadProgram(allocator: std.mem.Allocator, init: std.process.Init, file_path: []const u8, visited: *std.StringHashMap(void), visiting: *std.StringHashMap(void), merged: *std.ArrayList(u8), declarations: *std.ArrayList(ast.Declaration), is_wasm: bool, file_sources: *std.StringHashMap([]const u8), tinfo: TargetInfo) anyerror!void {
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

    const resolved_file_path = file_path;

    // Read from the target-conditional variant (foo_<os>.nova) if present; module identity stays file_path.
    const suffix_home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE");
    const read_path_opt = if (std.mem.eql(u8, file_path, "src/std/platform.nova")) null else targetVariantPath(file_path, tinfo.os, tinfo.arch, tinfo.is_posix, allocator, init.io, suffix_home);
    defer if (read_path_opt) |rp| allocator.free(rp);
    const read_path = read_path_opt orelse file_path;

    if (std.mem.eql(u8, file_path, "src/std/platform.nova")) {
        source = try genPlatformSource(allocator, tinfo);
    } else if (std.mem.startsWith(u8, read_path, "src/std/")) {
        source = Io.Dir.readFileAlloc(.cwd(), init.io, read_path, allocator, .unlimited) catch |err| blk: {
            if (err == error.FileNotFound) {

                const sub = read_path[8..];
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
        source = Io.Dir.readFileAlloc(.cwd(), init.io, read_path, allocator, .unlimited) catch |err| {
            std.debug.print("Failed to read file '{s}': {any}\n", .{ read_path, err });
            return err;
        };
    }

    if (visited.contains(resolved_file_path)) {
        const already_kv = visiting.fetchRemove(visiting_key);
        if (already_kv) |k| allocator.free(k.key);
        allocator.free(source);
        return;
    }

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
            const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE");
            const imported_path = try resolveImportPath(resolved_file_path, decl.import_decl.module, allocator, init.io, home);
            defer allocator.free(imported_path);
            try loadProgram(allocator, init, imported_path, visited, visiting, merged, declarations, is_wasm, file_sources, tinfo);
        }
    }

    const kv = visiting.fetchRemove(visiting_key).?;
    allocator.free(kv.key);

    const visited_key = try allocator.dupe(u8, resolved_file_path);
    try visited.put(visited_key, {});

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

fn scaffoldWeb(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    const f = struct { rel: []const u8, content: []const u8 };
    const files = [_]f{
        .{ .rel = "src/main.nova", .content = templates.web_main_sample },

        .{ .rel = "src/Features/Products/CreateProduct/command.nova", .content = templates.web_create_command_sample },
        .{ .rel = "src/Features/Products/CreateProduct/response.nova", .content = templates.web_create_response_sample },
        .{ .rel = "src/Features/Products/CreateProduct/validator.nova", .content = templates.web_create_validator_sample },
        .{ .rel = "src/Features/Products/CreateProduct/handler.nova", .content = templates.web_create_handler_sample },

        .{ .rel = "src/Features/Products/GetProductById/query.nova", .content = templates.web_get_query_sample },
        .{ .rel = "src/Features/Products/GetProductById/response.nova", .content = templates.web_get_response_sample },
        .{ .rel = "src/Features/Products/GetProductById/handler.nova", .content = templates.web_get_handler_sample },

        .{ .rel = "src/Features/Products/Shared/repository.nova", .content = templates.web_repository_sample },

        // View code lives in a `.nsx` file (same language as `.nova`; the extension keeps markup apart).
        .{ .rel = "src/Features/Products/views/product_card.nsx", .content = templates.web_view_sample },

        .{ .rel = "src/Domain/entities/product.nova", .content = templates.web_domain_entity_sample },
        .{ .rel = "wwwroot/index.html", .content = templates.web_index_html_sample },
        .{ .rel = "tests/features/products_test.nova", .content = templates.web_test_sample },

        // Tailwind CLI styling pipeline: `npm install` then `npm run css:watch`. tailwind.config.js lists
        // the content globs (including the `.nsx` views) so class changes hot-rebuild wwwroot/app.css.
        .{ .rel = "package.json", .content = templates.web_package_json_sample },
        .{ .rel = "tailwind.config.js", .content = templates.web_tailwind_config_sample },
        .{ .rel = "styles/app.css", .content = templates.web_tailwind_css_sample },
        .{ .rel = ".gitignore", .content = templates.web_gitignore_sample },
    };
    for (files) |file| try scaffoldFile(allocator, io, project, file.rel, file.content);
}

fn scaffoldDesktop(allocator: std.mem.Allocator, io: std.Io, project: []const u8) !void {
    try scaffoldFile(allocator, io, project, "src/main.nova", templates.desktop_main_sample);
}

fn cmdInit(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: nova init <console|web|desktop> --name <project_name>\n", .{});
        return;
    }
    var template_type = args[2];

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
            if ((std.mem.endsWith(u8, entry.name, ".nova") or std.mem.endsWith(u8, entry.name, ".nsx")) and !std.mem.eql(u8, entry.name, "merged.nova")) {
                try list.append(allocator, entry_path);
            } else {
                allocator.free(entry_path);
            }
        } else {
            allocator.free(entry_path);
        }
    }
}

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
    offset: usize,
    text: []const u8,
    order: usize,
};

fn reinjectComments(allocator: std.mem.Allocator, source: []const u8, formatted: []const u8) ![]u8 {
    const s_spans = try codeTokenSpans(allocator, source);
    defer allocator.free(s_spans);
    const f_spans = try codeTokenSpans(allocator, formatted);
    defer allocator.free(f_spans);

    const n = s_spans.len;

    if (n != f_spans.len) return allocator.dupe(u8, formatted);

    var inserts = std.ArrayList(CommentIns).empty;
    defer inserts.deinit(allocator);
    var order: usize = 0;

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

                break;
            }
        }
    }

    if (inserts.items.len == 0) return allocator.dupe(u8, formatted);

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

        const base = f_spans[i - 1].start;
        const line_end = std.mem.indexOfScalarPos(u8, formatted, base, '\n') orelse formatted.len;
        const rendered = try std.fmt.allocPrint(allocator, " {s}", .{text});
        try inserts.append(allocator, .{ .offset = line_end, .text = rendered, .order = order.* });
    } else if (i < n) {

        const base = f_spans[i].start;
        const line_start = if (std.mem.lastIndexOfScalar(u8, formatted[0..base], '\n')) |nl| nl + 1 else 0;
        var ind_end = line_start;
        while (ind_end < base and (formatted[ind_end] == ' ' or formatted[ind_end] == '\t')) ind_end += 1;
        const indent = formatted[line_start..ind_end];
        const rendered = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ indent, text });
        try inserts.append(allocator, .{ .offset = line_start, .text = rendered, .order = order.* });
    } else {

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

fn cloneIntoCache(allocator: std.mem.Allocator, init: std.process.Init, git_url: []const u8) !bool {
    const repo_name = repoNameFromUrl(git_url) orelse {
        std.debug.print("Invalid git URL format: {s}\n", .{git_url});
        return error.InvalidGitUrl;
    };
    const home_path = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const target_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_path, ".nova", "cache", repo_name });
    defer allocator.free(target_dir);

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

    var file_path: []const u8 = "";
    var target: []const u8 = "--native";

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
    const tinfo = deriveTargetInfo(target, null);

    loadProgram(allocator, init, "src/std/collections/string_builder.nova", &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder in test harness: {any}\n", .{err});
    };

    for (file_paths.items) |path| {
        loadProgram(allocator, init, path, &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
            std.debug.print("Failed to load program {s}: {any}\n", .{ path, err });

            return err;
        };
    }

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

    const harness_src = try generateTestHarness(test_fn_names, allocator);

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

    var harness_parser = try parser.Parser.init(allocator, harness_src, "test_harness.nova", is_wasm);
    defer harness_parser.deinit();
    const harness_prog = try harness_parser.parseProgram();
    try filtered_decls.appendSlice(allocator, harness_prog.declarations);

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
    try generateRuntimeMediator(allocator, &filtered_decls, is_wasm);

    const program = ast.Program{
        .declarations = filtered_decls.items,
        .span = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = file_path },
    };
    std.debug.print("Parsed {d} top-level declaration(s).\n", .{program.declarations.len});

    try sema_alpha.run(allocator, program);

    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    tc.is_wasm = is_wasm;
    try tc.check(program);

    sema_shadow.report_enabled = init.environ_map.get("NOVA_SEMA_SHADOW") != null;
    codegen_arc.elide_enabled = init.environ_map.get("NOVA_ARC_ELIDE") != null;
    sema_shadow.trace_resolution = sema_shadow.report_enabled;
    sema_shadow.f2_types_enabled = true;

    const owned_sema = try sema_mod.Sema.create(allocator);
    defer owned_sema.destroy();
    sema_shadow.run(allocator, program, owned_sema) catch |e| {
        std.debug.print("sema failed: {any}\n", .{e});
    };

    {
        var wl = sema_mono.Worklist.init(allocator, owned_sema);
        defer wl.deinit();
        wl.compute(program) catch |e| std.debug.print("F4 worklist failed: {any}\n", .{e});
        sema_mono.live_instantiations = wl.names(allocator) catch null;
        if (sema_shadow.report_enabled) wl.report();

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

    const asan = if (init.environ_map.get("NOVA_ASAN")) |v| !std.mem.eql(u8, v, "0") else false;
    const tsan = if (init.environ_map.get("NOVA_TSAN")) |v| !std.mem.eql(u8, v, "0") else false;

    var test_clang_args = std.ArrayList([]const u8).empty;
    try test_clang_args.append(allocator, "clang++");
    try test_clang_args.append(allocator, "-std=c++20");
    try test_clang_args.append(allocator, "-g");
    try test_clang_args.append(allocator, "-O0");
    try test_clang_args.append(allocator, "-pthread");

    try test_clang_args.append(allocator, dead_strip_flag);
    try test_clang_args.appendSlice(allocator, pie_flags);
    try test_clang_args.append(allocator, "-I.");
    try test_clang_args.append(allocator, shared_nova_arg);
    if (asan) {
        try test_clang_args.append(allocator, "-fsanitize=address");
        try test_clang_args.append(allocator, "-fno-omit-frame-pointer");
    } else if (tsan) {
        try test_clang_args.append(allocator, "-fsanitize=thread");
        try test_clang_args.append(allocator, "-fno-omit-frame-pointer");
    }

    for (link_objs) |o| try test_clang_args.append(allocator, o);

    try appendRuntimeLink(&test_clang_args, allocator, shared_nova, if (asan)
        "novacore_asan"
    else if (tsan)
        "novacore_tsan"
    else
        "novacore");
    try appendWolfsslLink(&test_clang_args, allocator, shared_nova, init.io);

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

    std.debug.print("\n", .{});
    var test_child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{"./__nova_test"},
    });
    const test_term = try test_child.wait(init.io);

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

    if (suite_failed) std.process.exit(1);
}

fn getFileMtime(io: Io, path: []const u8) !i96 {
    const stat = try Io.Dir.statFile(.cwd(), io, path, .{});
    return stat.mtime.nanoseconds;
}

fn linkLibsStamp(allocator: std.mem.Allocator, init: std.process.Init) u64 {
    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const libs = [_][]const u8{
        "/.nova/lib/libnovacore.a",
    };
    var acc: u64 = 0;
    for (libs) |suffix| {
        const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix }) catch continue;
        defer allocator.free(path);
        const mt = getFileMtime(init.io, path) catch continue;
        acc ^= @as(u64, @bitCast(@as(i64, @truncate(mt))));
    }
    return acc;
}

const CACHE_VERSION: u64 = 1;
fn sourcesHash(file_sources: *std.StringHashMap([]const u8), is_release: bool, asan: bool, link_stamp: u64) u64 {
    var acc: u64 = CACHE_VERSION ^ link_stamp ^ (if (is_release) @as(u64, 0x9e3779b97f4a7c15) else 0) ^ (if (asan) @as(u64, 0xa5a5_5a5a_c3c3_3c3c) else 0);
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
    const tinfo = deriveTargetInfo(target, target_triple_opt);

    // AddressSanitizer for native builds: default ON for debug, OFF for --release (and never for wasm).
    // NOVA_ASAN=0 forces it off (e.g. a debug build you want to benchmark), NOVA_ASAN=1 forces it on even
    // for --release. ASAN requires the clang link path (it pulls in the asan runtime + links the sanitized
    // novacore_asan), so it also disables the in-process-LLD fast path below.
    const asan = !is_wasm and (if (init.environ_map.get("NOVA_ASAN")) |v| !std.mem.eql(u8, v, "0") else !is_release);

    loadProgram(allocator, init, "src/std/collections/string_builder.nova", visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder standard library: {any}\n", .{err});
    };

    try loadProgram(allocator, init, file_path, visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo);

    if (init.environ_map.get("NOVA_DUMP_MERGED") != null) {
        _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = merged.items, .sub_path = "merged.nova", .flags = .{} }) catch |err| {
            std.debug.print("Failed to write merged.nova: {s}\n", .{@errorName(err)});
        };
    }

    var src_hash: u64 = 0;
    if (build_mode) {
        src_hash = sourcesHash(&file_sources, is_release, asan, linkLibsStamp(allocator, init));
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
    try generateRuntimeMediator(allocator, &declarations, is_wasm);
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

    try sema_alpha.run(allocator, program);

    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    tc.is_wasm = is_wasm;
    try tc.check(program);

    sema_shadow.report_enabled = init.environ_map.get("NOVA_SEMA_SHADOW") != null;
    codegen_arc.elide_enabled = init.environ_map.get("NOVA_ARC_ELIDE") != null;
    sema_shadow.trace_resolution = sema_shadow.report_enabled;
    sema_shadow.f2_types_enabled = true;

    const owned_sema = try sema_mod.Sema.create(allocator);
    defer owned_sema.destroy();
    sema_shadow.run(allocator, program, owned_sema) catch |e| {
        std.debug.print("sema failed: {any}\n", .{e});
    };

    {
        var wl = sema_mono.Worklist.init(allocator, owned_sema);
        defer wl.deinit();
        wl.compute(program) catch |e| std.debug.print("F4 worklist failed: {any}\n", .{e});
        sema_mono.live_instantiations = wl.names(allocator) catch null;
        if (sema_shadow.report_enabled) wl.report();

        if (wl.instIds(allocator) catch null) |ids| {
            defer allocator.free(ids);
            @import("sema/inst_disp.zig").run(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir, ids);
        }
    }

    if (std.mem.eql(u8, target, "--wasm")) {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
        defer allocator.free(obj_path);
        try llvm_codegen.compile(allocator, program, true, is_release, target_triple_opt, obj_path, false, init.environ_map.get("NOVA_T6_SPLIT") != null, null, null, init.io);

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

        const obj_path = if (build_mode)
            try std.fmt.allocPrint(allocator, "{s}/{s}.o", .{ build_obj_dir, std.fs.path.basename(output_path) })
        else
            try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
        defer allocator.free(obj_path);

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

        try clang_args.append(allocator, dead_strip_flag);
        try clang_args.appendSlice(allocator, pie_flags);
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
        if (asan) try clang_args.append(allocator, "-fsanitize=address");
        try clang_args.append(allocator, "-pthread");
        try clang_args.append(allocator, "-I.");

        const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
        const shared_nova = try std.fmt.allocPrint(allocator, "{s}/.nova", .{ home });

        const ffi_libs = try collectFfiLibs(allocator, program);

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

        if (build_options.inprocess_lld and builtin.target.os.tag == .macos and target_triple_opt == null and !asan) {
            try linkNativeInProcessMacho(allocator, init.environ_map, init.io, link_objs, output_path, shared_nova, ffi_libs);

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

        for (link_objs) |o| try clang_args.append(allocator, o);

        try appendRuntimeLink(&clang_args, allocator, shared_nova, if (asan) "novacore_asan" else "novacore");
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

        if (init.environ_map.get("NOVA_KEEP_OBJ") == null and !build_mode) {
            Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
        } else if (!build_mode) {
            std.debug.print("Kept object file {s} (NOVA_KEEP_OBJ)\n", .{obj_path});
        }
        if (build_mode) {
            const cur = std.fmt.allocPrint(allocator, "{x}", .{src_hash}) catch "";
            defer if (cur.len > 0) allocator.free(cur);
            _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = cur, .sub_path = build_hash_path, .flags = .{} }) catch {};
            std.debug.print("Built {s} ({s}{s}).\n", .{ output_path, if (is_release) "release" else "debug", if (asan) ", ASAN" else "" });
        } else {
            std.debug.print("Native output written to {s}{s}\n", .{ output_path, if (asan) " (ASAN)" else "" });
        }
    } else {
        std.debug.print("Unsupported target: {s}\n", .{target});
        return error.UnsupportedTarget;
    }
}

fn userErrorHint(e: anyerror) ?[]const u8 {
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

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch |e| {
        if (userErrorHint(e)) |hint| {

            if (hint.len > 0) {
                std.debug.print("\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m {s}\x1b[0m (compilation failed)\n", .{hint});
            }
            std.process.exit(1);
        }
        return e;
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

    var target: []const u8 = "--native";
    var output_path: []const u8 = "";
    var is_release = false;
    var cross_target: ?[]const u8 = null;
    var watch_mode = false;

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

    const profile: []const u8 = if (is_release) "release" else "debug";
    var build_obj_dir: []const u8 = "";
    var build_hash_path: []const u8 = "";
    if (build_mode) {

        if (file_path.len == 0) file_path = "src/main.nova";

        var proj_name: []const u8 = std.fs.path.stem(file_path);
        if (Io.Dir.readFileAlloc(.cwd(), init.io, "project.json", allocator, .unlimited)) |pj| {
            defer allocator.free(pj);
            if (std.json.parseFromSlice(ProjectJson, allocator, pj, .{ .ignore_unknown_fields = true })) |parsed| {
                proj_name = allocator.dupe(u8, parsed.value.name) catch proj_name;
                parsed.deinit();
            } else |_| {}
        } else |_| {}

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

            target_triple_opt = "x86_64-pc-windows-gnu";
        } else {
            std.debug.print("Unsupported target switch: {s}\n", .{ct});
            return error.UnsupportedTarget;
        }
    }

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
