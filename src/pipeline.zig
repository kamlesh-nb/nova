// pipeline.zig — shared compile/link/load machinery for the CLI commands.
// The frontend->backend driver core: import resolution, source loading, the codegen prelude
// (route/serde/mediator generation), target derivation, native/wasm/cross linking, and build
// bookkeeping. builder/tester/format/packages call into this; nothing here calls them.

// Extracted from main.zig (SE-refactor 2026-08-14): main.zig is now a thin entry, cli.zig the
// dispatch, and this module holds every command (init/add/test/fmt/get/build) and the shared
// compile pipeline (loadProgram, import resolution, codegen prelude, linking, compileProgram).


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
pub const pie_flags: []const []const u8 = if (builtin.target.os.tag == .linux) &.{"-no-pie"} else &.{};

pub const dead_strip_flag: []const u8 = switch (builtin.target.os.tag) {
    .macos => "-Wl,-dead_strip",
    // clang++ on Windows drives MSVC's link.exe, which does not understand --gc-sections
    // (it arrives as `/-gc-sections` → LNK4044 and no stripping). /OPT:REF is its equivalent.
    .windows => "-Wl,/OPT:REF",
    else => "-Wl,--gc-sections",
};


pub fn macSdkPath(environ: anytype, io: std.Io) []const u8 {
    if (environ.get("SDKROOT")) |s| return s;
    const clt = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
    Io.Dir.access(.cwd(), io, clt, .{}) catch {
        return "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    };
    return clt;
}


pub fn collectFfiLibs(allocator: std.mem.Allocator, program: ast.Program) ![]const []const u8 {
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


pub fn appendFfiLib(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, shared_nova: []const u8, io: std.Io, lib: []const u8) !void {
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


pub fn linkNativeInProcessMacho(
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


pub const CrossTarget = struct { zig: []const u8, static: bool };

pub fn mapCrossTarget(llvm_triple: []const u8) ?CrossTarget {
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


pub fn crossLinkViaZig(
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


pub fn linkWasmInProcess(allocator: std.mem.Allocator, obj_path: []const u8, output_path: []const u8) !void {
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
pub fn appendRuntimeLink(
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


pub fn appendWolfsslLink(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, shared_nova: []const u8, io: std.Io) !void {
    // wolfSSL was retired in M13 (TLS is pure Nova). Nothing to link; kept as a no-op so the three
    // link sites need no change. getentropy() (crypto.cpp) is in libSystem/glibc, no framework needed.
    _ = args;
    _ = allocator;
    _ = shared_nova;
    _ = io;
}

const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser.zig");
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
const codegen_arc = @import("backend/codegen/arc.zig");


// M-1 value-type structs: configure the per-type rollout gate from the environment.
//   NOVA_VALUE_STRUCTS_ALL -> every is_reference==false struct is value-lowered.
//   NOVA_VALUE_TYPES=A,B,C -> only the named base types. Default: neither, so gate stays off.
pub fn configureValueStructs(allocator: std.mem.Allocator, environ: anytype) void {
    // M-1 value structs -- DEFAULT ON. Every non-`class` struct is value-lowered (stack alloca, no
    // ARC, copy-on-assign) unless it escapes. The escape channels (return-construction incl. lifted
    // closures, struct/type-param field, tuple/error-union/optional slot, @serializable binder,
    // trait impl, colliding module-scoped name, non-scalar/non-string field) keep every unsafe shape
    // on the heap; corpus + ASAN are green under the flip. NOVA_VALUE_STRUCTS_OFF is the escape hatch
    // (reverts to the all-reference model); NOVA_VALUE_TYPES=A,B narrows to named types for A/B tests.
    if (environ.get("NOVA_VALUE_STRUCTS_OFF") != null) return; // escape hatch: all-reference model
    if (environ.get("NOVA_VALUE_TYPES")) |list| {
        // A/B narrowing: value-lower only the named types (leave the rest reference).
        var set = std.StringHashMap(void).init(allocator);
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " \t");
            if (trimmed.len == 0) continue;
            const owned = allocator.dupe(u8, trimmed) catch continue;
            set.put(owned, {}) catch {};
        }
        codegen_arc.value_type_set = set;
        codegen_arc.value_structs_enabled = true;
        return;
    }
    // DEFAULT: `struct` is a value type, `class` is reference. Every non-`class` struct is value-lowered
    // (stack alloca, no ARC, copy-on-assign) unless the escape analysis (isValueStructName +
    // computeValueEscapeSet) keeps it on the heap for safety. This makes the language's stated semantics
    // (struct = value, class = reference) the actual default; NOVA_VALUE_STRUCTS_OFF reverts to all-reference.
    codegen_arc.value_structs_enabled = true;
    codegen_arc.value_structs_all = true;
}

const type_checker = @import("frontend/type_checker.zig");
const sema_shadow = @import("frontend/sema/shadow.zig");
const sema_escape = @import("frontend/sema/escape.zig");
const sema_alpha = @import("frontend/sema/alpha.zig");
const sema_ids = @import("frontend/sema/ids.zig");
const sema_mod = @import("frontend/sema/sema.zig");
const sema_mono = @import("frontend/sema/mono.zig");
const ast = @import("frontend/ast.zig");
const formatter = @import("frontend/formatter.zig");

const templates = @import("templates.zig");


pub fn getSharedAssetPath(allocator: std.mem.Allocator, init: std.process.Init, relative_path: []const u8) ![]const u8 {
    if (Io.Dir.access(.cwd(), init.io, relative_path, .{})) |_| {
        return try allocator.dupe(u8, relative_path);
    } else |_| {}

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    return try std.fmt.allocPrint(allocator, "{s}/.nova/{s}", .{ home, relative_path });
}


// Compile-target facts, derived once per compilation from `--target`/triple (or the host for --native)
// and exposed to Nova source as the synthesized `builtin` module + used to pick target-conditional files.
pub const TargetInfo = struct {
    os: []const u8, // "darwin" | "linux" | "windows" | "wasm"
    arch: []const u8, // "aarch64" | "x86_64" | "wasm32"
    ptr_size: u8,
    is_posix: bool,
};


pub fn hostOs() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => "darwin",
    };
}

pub fn hostArch() []const u8 {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "x86_64",
    };
}


pub fn deriveTargetInfo(target: []const u8, triple: ?[]const u8) TargetInfo {
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
pub fn genPlatformSource(allocator: std.mem.Allocator, t: TargetInfo) ![]const u8 {
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
pub fn suffixedFileExists(cand: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) bool {
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
pub fn targetVariantPath(path: []const u8, os_tag: []const u8, arch: []const u8, is_posix: bool, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ?[]const u8 {
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
pub fn existingSource(nova_candidate: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
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


pub fn resolveImportPath(base_path: []const u8, module_name: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, module_name, "platform")) {
        // Synthetic module — parsed from generated source (see loadProgram), but given a src/std path so
        // canonicalModulePrefix maps its declarations to module "platform" (the import's qualifier).
        return try allocator.dupe(u8, "src/std/platform.nova");
    }
    if (std.mem.startsWith(u8, module_name, "std/")) {
        const sub = module_name[4..];
        return try std.fmt.allocPrint(allocator, "src/std/{s}.nova", .{sub});
    }
    const std_modules = [_][]const u8{ "net/tcp/stream", "net/tcp/server", "net/tcp/client", "net/url", "net/dns", "net/dial", "net/aio", "net/asynctls", "web/request", "web/response", "web/mime", "web/status", "web/methods", "web/client", "web/mediator", "web/routing", "web/middleware", "web/url", "web/cookie", "web/cors", "web/request_id", "web/redact", "web/secure_headers", "web/body_limit", "web/recovery", "web/rate_limit", "web/multipart", "web/session", "web/csrf", "web/di", "web/controller", "web/app", "web/logger", "web/httpparser", "concurrency/fiber", "concurrency/channel", "concurrency/asyncchan", "concurrency/atomic", "concurrency/async_util", "concurrency/actor", "concurrency/asynclock", "io/file", "io/dir", "collections/list", "collections/map", "collections/set", "collections/string_builder", "collections/deque", "collections/heap", "collections/ordered_map", "serde/json", "serde/source", "serde/bson", "serde/yaml", "mem/allocator", "mem/memory", "mem/witness", "mem/rawbuffer", "mem/endian", "result", "string", "str", "datetime", "stopwatch", "math", "assert", "traits", "env", "log", "config", "metrics", "crypto/hash/sha", "crypto/hash/md5", "crypto/base64", "crypto/random", "crypto/scram", "crypto/hash/sha256", "crypto/hash/sha512", "crypto/hash/sha1", "crypto/mac/hmac", "crypto/kdf/hkdf", "crypto/kdf/pbkdf2", "crypto/cipher/chacha20", "crypto/mac/poly1305", "crypto/aead/chachapoly", "crypto/cipher/aes", "crypto/mac/ghash", "crypto/aead/aesgcm", "crypto/aead/aesgcmhw", "crypto/cipher/aesctr", "crypto/ecc/x25519", "crypto/ecc/p256", "crypto/ecc/p384", "crypto/rsa", "crypto/x509", "crypto/ocsp", "crypto/crl", "crypto/tls/13/tls", "crypto/tls/13/handshake", "crypto/tls/13/tlsClient", "crypto/tls/13/tlsServer", "crypto/tls/12/prf", "crypto/tls/truststore", "crypto/tls/revocation", "crypto/tls/12/client12", "process", "fs", "exception", "data/db", "data/sql/pool", "text/utf8", "text/regex", "webview", "web/static_content", "web/circuit_breaker", "resilience/breaker", "compress/gzip", "compress/deflate", "compress/lz4", "data/orm", "os/sys", "os/backend", "os/socket", "os/handle", "os/darwin/kqueue", "os/linux/epoll", "os/windows/win32", "os/windows/fs", "os/windows/proc", "os/windows/winsock", "io/slab", "io/arena", "net/poller", "net/eventedio", "net/tls13async", "net/tlsmembio", "net/tls12bio", "net/httpsclient", "net/eventloop" };
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

    // Final importer-relative step: the CWD (the project/package root being built). The walk above stops
    // at the importer's own directory chain, which for a relative importer like `tests/foo.nova` breaks at
    // `tests/` (no parent slash) and never reaches the package root's `src/`, and for a bare importer like
    // `foo.nova` never runs at all (empty dir). In both cases the importer's OWN package root is the CWD, so
    // check `./<mod>.nova` and `./src/<mod>.nova` here -- BEFORE the global scans below. This makes a
    // package's own module win over a same-named module in a SIBLING package or a stale ~/.nova/cache entry
    // (observed: mssql's `import connection` binding to nova-postgres's connection.nova, whose
    // ConnectionOptions lacks `encrypt`/`trustCert` -> FieldNotFound). These candidates only WIN when the
    // local file actually exists, so a package-managed app with no local file falls through to the version
    // resolution and package scans exactly as before.
    {
        const cwd_candidate = try std.fmt.allocPrint(allocator, "{s}.nova", .{module_name});
        if (existingSource(cwd_candidate, allocator, io)) |hit| return hit;
        const cwd_src = try std.fmt.allocPrint(allocator, "src/{s}.nova", .{module_name});
        if (existingSource(cwd_src, allocator, io)) |hit| return hit;
    }

    // Version-aware resolution (pkg-manager.md §6): when a lockfile exists, `import X` binds through the
    // owning package's manifest + the flat lock to a version-keyed cache dir. Wins over the legacy scans
    // so a package-managed app gets the EXACT pinned version (and multi-version coexistence). Inert (null)
    // when there is no lock, so the packages/-based dev setup and the corpus are unchanged.
    if (try resolveVersioned(module_name, base_path, allocator, io, home)) |ver_hit| {
        return ver_hit;
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


// -------------------------------------------------------------------------------------------------
// Version-aware import resolution (pkg-manager.md §6). When a project.lock.json exists, an `import X`
// binds PER OWNING PACKAGE: find the file's owning manifest (nearest project.json up its tree), look up
// X among that manifest's dependencies via the flat lock (url[#ref] -> declared name + resolved SHA),
// and resolve to the version-keyed cache dir `~/.nova/cache/<name>-<sha8>`. Because two versions live at
// different paths and mangling is path-derived, they coexist. Returns null (fall through to the legacy
// scan) when there is no lock — so the corpus and packages/-based dev setup are unaffected.
const PkgLockEntry = struct { url: []const u8, ref: ?[]const u8 = null, resolved: ?[]const u8 = null, name: []const u8 };
const PkgLockFile = struct { lockfileVersion: u32 = 1, dependencies: []PkgLockEntry = &[_]PkgLockEntry{} };

fn pkgParseDep(dep: []const u8) struct { url: []const u8, ref: ?[]const u8 } {
    if (std.mem.lastIndexOfScalar(u8, dep, '#')) |h|
        return .{ .url = dep[0..h], .ref = if (h + 1 < dep.len) dep[h + 1 ..] else null };
    return .{ .url = dep, .ref = null };
}

fn pkgCacheDirName(allocator: std.mem.Allocator, name: []const u8, sha: ?[]const u8) ?[]const u8 {
    if (sha) |s| return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, s[0..@min(s.len, 8)] }) catch null;
    return std.fmt.allocPrint(allocator, "{s}-branch", .{name}) catch null;
}

fn refEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// The nearest ancestor directory of `importer_file` that contains a project.json (its owning package).
// A top-level app file (e.g. "src/main.nova") is owned by the CWD project — so once the walk exhausts the
// path's own directories, fall back to the CWD's project.json (returned as ".").
fn findOwningManifestDir(allocator: std.mem.Allocator, io: std.Io, importer_file: []const u8) ?[]const u8 {
    var end = std.mem.lastIndexOfScalar(u8, importer_file, '/') orelse 0;
    while (end > 0) {
        const dir = importer_file[0..end];
        const mpath = std.fmt.allocPrint(allocator, "{s}/project.json", .{dir}) catch return null;
        if (Io.Dir.access(.cwd(), io, mpath, .{})) |_| return allocator.dupe(u8, dir) catch null else |_| {}
        end = std.mem.lastIndexOfScalar(u8, dir, '/') orelse break;
    }
    // CWD project (the app being built) owns any file not under a nested package dir.
    if (Io.Dir.access(.cwd(), io, "project.json", .{})) |_| return allocator.dupe(u8, ".") catch null else |_| {}
    return null;
}

fn findModuleInPackageDir(allocator: std.mem.Allocator, io: std.Io, pkg_dir: []const u8, module_name: []const u8) ?[]const u8 {
    const src = std.fmt.allocPrint(allocator, "{s}/src/{s}.nova", .{ pkg_dir, module_name }) catch return null;
    if (existingSource(src, allocator, io)) |hit| return hit;
    const flat = std.fmt.allocPrint(allocator, "{s}/{s}.nova", .{ pkg_dir, module_name }) catch return null;
    if (existingSource(flat, allocator, io)) |hit| return hit;
    return null;
}

pub const PkgResolveError = error{PackageNameCollision};

pub fn resolveVersioned(module_name: []const u8, importer_file: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) PkgResolveError!?[]const u8 {
    const home_dir = home orelse return null;
    // The flat lock is the ROOT project's (cwd) — it holds the whole tree, keyed by url (+ref).
    const lock_data = Io.Dir.readFileAlloc(.cwd(), io, "project.lock.json", allocator, .unlimited) catch return null;
    const lock = std.json.parseFromSlice(PkgLockFile, allocator, lock_data, .{ .ignore_unknown_fields = true }) catch return null;

    const owner_dir = findOwningManifestDir(allocator, io, importer_file) orelse return null;
    const owner_manifest = std.fmt.allocPrint(allocator, "{s}/project.json", .{owner_dir}) catch return null;
    const mdata = Io.Dir.readFileAlloc(.cwd(), io, owner_manifest, allocator, .unlimited) catch return null;
    const manifest = std.json.parseFromSlice(ProjectJson, allocator, mdata, .{ .ignore_unknown_fields = true }) catch return null;

    // Among THIS owning package's deps, find the one whose declared name (from the lock) == module_name.
    // Two different urls in the SAME scope declaring the same name is an identity clash (§6 name-collision).
    var match_url: ?[]const u8 = null;
    var match_entry: ?PkgLockEntry = null;
    for (manifest.value.dependencies) |dep| {
        const spec = pkgParseDep(dep);
        for (lock.value.dependencies) |e| {
            if (!std.mem.eql(u8, e.url, spec.url)) continue;
            if (!refEql(e.ref, spec.ref)) continue;
            if (!std.mem.eql(u8, e.name, module_name)) continue;
            if (match_url) |mu| {
                if (!std.mem.eql(u8, mu, e.url)) {
                    std.debug.print("package name collision: import \"{s}\" is declared by TWO urls in {s}:\n  {s}\n  {s}\n", .{ module_name, owner_dir, mu, e.url });
                    return PkgResolveError.PackageNameCollision;
                }
            } else {
                match_url = e.url;
                match_entry = e;
            }
        }
    }
    const entry = match_entry orelse return null;
    const dirname = pkgCacheDirName(allocator, entry.name, entry.resolved) orelse return null;
    const pkg_dir = std.fmt.allocPrint(allocator, "{s}/.nova/cache/{s}", .{ home_dir, dirname }) catch return null;
    return findModuleInPackageDir(allocator, io, pkg_dir, module_name);
}

pub fn resolveFromPackageCache(module_name: []const u8, allocator: std.mem.Allocator, io: std.Io, home: ?[]const u8) ?[]const u8 {
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
pub fn scanPackageRoot(root: []const u8, module_name: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
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
pub fn resolveFromLocalPackages(module_name: []const u8, importer_dir: []const u8, allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
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


// Copy a trait's DEFAULT method bodies onto every struct that impls the trait but does not override the
// method. The parser does this per file, so a struct only inherited defaults from traits declared in the SAME
// file; a trait in another module was invisible and the completeness check then reported the method missing.
// Running it again here on the FULLY-MERGED declaration list closes that cross-module gap. Idempotent: a
// method already present (same-file expansion, or a real override) is skipped, so re-running copies only the
// cross-module defaults.
fn tdStructHasMethod(methods: []const ast.MethodDecl, name: []const u8) bool {
    for (methods) |m| if (std.mem.eql(u8, m.decl.name, name)) return true;
    return false;
}
fn tdFindTrait(decls: []const ast.Declaration, name: []const u8) ?ast.TraitDecl {
    for (decls) |d| if (d == .trait_decl and std.mem.eql(u8, d.trait_decl.name, name)) return d.trait_decl;
    return null;
}
fn tdSelfTypeRef(allocator: std.mem.Allocator, sd: ast.StructDecl) !ast.TypeRef {
    if (sd.type_params.len == 0) return ast.TypeRef{ .ident = sd.name };
    const params = try allocator.alloc(ast.TypeRef, sd.type_params.len);
    for (sd.type_params, 0..) |tp, i| params[i] = ast.TypeRef{ .ident = tp };
    return ast.TypeRef{ .generic = .{ .name = sd.name, .params = params } };
}
pub fn expandTraitDefaults(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration)) !void {
    const decls = declarations.items;
    for (decls) |*d| {
        if (d.* != .struct_decl) continue;
        const sd = &d.struct_decl;
        if (sd.impls.len == 0) continue;
        var methods = std.ArrayList(ast.MethodDecl).empty;
        defer methods.deinit(allocator);
        try methods.appendSlice(allocator, sd.methods);
        var added = false;
        for (sd.impls) |impl| {
            const trait = tdFindTrait(decls, impl.name) orelse continue;
            for (trait.methods) |tm| {
                const body = tm.default_body orelse continue;
                if (tdStructHasMethod(methods.items, tm.name)) continue;
                const new_params = try allocator.alloc(ast.Param, tm.params.len);
                for (tm.params, 0..) |p, i| {
                    if (i == 0 and std.mem.eql(u8, p.name, "self")) {
                        new_params[i] = .{ .name = p.name, .type_name = try tdSelfTypeRef(allocator, sd.*), .span = p.span };
                    } else new_params[i] = p;
                }
                try methods.append(allocator, ast.MethodDecl{
                    .is_public = true,
                    .is_static = false,
                    .decl = ast.FunctionDecl{
                        .name = tm.name,
                        .params = new_params,
                        .ret_type = tm.ret_type,
                        .body = body,
                        .is_exported = false,
                        .attributes = &.{},
                        .type_params = sd.type_params,
                        .is_async = tm.is_async,
                        .span = tm.span,
                    },
                });
                added = true;
            }
        }
        if (added) sd.methods = try methods.toOwnedSlice(allocator);
    }
}

pub fn generateControllerRoutes(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration)) !void {
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


pub fn serdeIsInt(n: []const u8) bool {
    const ints = [_][]const u8{ "i8", "u8", "byte", "i16", "u16", "short", "ushort", "i32", "u32", "int", "uint", "i64", "u64", "long", "ulong" };
    for (ints) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

pub fn serdeIsFloat(n: []const u8) bool {

    const fs = [_][]const u8{ "f32", "f64", "float", "double" };
    for (fs) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}


pub fn serdeEnumPayloadless(e: ast.EnumDecl) bool {
    for (e.variants) |v| {
        if (v.type_name != null or v.fields != null) return false;
    }
    return true;
}

pub fn serdeAppendf(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    try list.appendSlice(allocator, s);
}


pub fn generateSerdeBinders(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
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

    // The positional binder (T__planFor/T__bindRow) references the DB seam (Row, Column, colIndexOf). Only
    // emit it when that seam is actually in the program (i.e. data.db was imported); a hermetic program with
    // @serializable structs but no DB import must not gain undefined references.
    var has_db = false;
    {
        var have_row = false;
        var have_colidx = false;
        for (declarations.items) |decl| {
            switch (decl) {
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, "Row")) have_row = true;
                },
                .fn_decl => |fd| {
                    if (std.mem.eql(u8, fd.name, "colIndexOf")) have_colidx = true;
                },
                else => {},
            }
        }
        has_db = have_row and have_colidx;
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
                    } else if (std.mem.eql(u8, tn, "Str")) {
                        // A borrowed-string field (P10 Str): bind a zero-copy VIEW instead of an owned
                        // string. From a DB RowSource this borrows Row.raw (owned by the ResultSet, which
                        // outlives the bind); from JSON/YAML it borrows the source node's bytes. The
                        // caller carries the same manual-lifetime contract as Str everywhere.
                        try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getStr(\"{s}\"); }}\n", .{ fname, fname, fname });
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
                        } else if (std.mem.eql(u8, itn, "Str")) {
                            try serdeAppendf(&src, allocator, "    if (src.has(\"{s}\")) {{ obj.{s} = src.getStr(\"{s}\"); }}\n", .{ fname, fname, fname });
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

        // Level A positional binder (DB ORM path). `{s}__planFor` resolves each field to its column index
        // ONCE per result set (by name, case-insensitive); `{s}__bindRow` then reads `row.cells[pos]` by
        // index -- no per-field name Map, no ValueSource trait dispatch. Additive: the name-based `{s}__bind`
        // above is untouched, so JSON/YAML/web binding is unaffected. Only scalar column types are bound
        // positionally; a field with no matching column keeps its init default (plan entry -1). Emitted only
        // when the DB seam (Row/Column/colIndexOf) is in the program, so hermetic non-DB programs are safe.
        if (has_db) {
        try serdeAppendf(&src, allocator, "fn {s}__planFor(cols: List<Column>): List<int> {{\n    let plan = List<int>();\n", .{s.name});
        for (s.fields) |f| {
            try serdeAppendf(&src, allocator, "    plan.push(colIndexOf(cols, \"{s}\"));\n", .{f.name});
        }
        try src.appendSlice(allocator, "    return plan;\n}\n\n");

        try serdeAppendf(&src, allocator, "fn {s}__bindRow(row: Row, plan: List<int>): {s} {{\n    let obj = {s}();\n", .{ s.name, s.name, s.name });
        var __k: usize = 0;
        for (s.fields) |f| {
            const fname = f.name;
            var acc: ?[]const u8 = null;
            var enumName: ?[]const u8 = null;
            const tnOpt: ?[]const u8 = switch (f.type_name) {
                .ident => |tn| tn,
                .optional => |inner| if (inner.* == .ident) inner.ident else null,
                else => null,
            };
            if (tnOpt) |tn| {
                if (std.mem.eql(u8, tn, "string")) {
                    acc = "asText";
                } else if (std.mem.eql(u8, tn, "Str")) {
                    acc = "asView";
                } else if (serdeIsInt(tn)) {
                    // Match the field width so there is no narrowing: `int` -> asInt(), `long` -> asLong().
                    acc = if (std.mem.eql(u8, tn, "int") or std.mem.eql(u8, tn, "i32")) "asInt" else "asLong";
                } else if (std.mem.eql(u8, tn, "bool")) {
                    acc = "asBool";
                } else if (std.mem.eql(u8, tn, "decimal")) {
                    acc = "asDecimal";
                } else if (serdeIsFloat(tn)) {
                    acc = "asDouble";
                } else if (enums.contains(tn)) {
                    acc = "asText";
                    enumName = tn;
                }
            }
            if (acc) |a| {
                if (enumName) |en| {
                    try serdeAppendf(&src, allocator, "    {{ let __p = plan.get({d}) ?? -1; if (__p >= 0) {{ obj.{s} = {s}__fromName(row.get(__p).{s}()); }} }}\n", .{ __k, fname, en, a });
                } else {
                    try serdeAppendf(&src, allocator, "    {{ let __p = plan.get({d}) ?? -1; if (__p >= 0) {{ obj.{s} = row.get(__p).{s}(); }} }}\n", .{ __k, fname, a });
                }
            }
            __k += 1;
        }
        try src.appendSlice(allocator, "    return obj;\n}\n\n");

        // Level B fused binder: `{s}__bindAll` decodes a WHOLE result set in one function -- the column
        // indices are resolved ONCE into LOCALS (not a per-row `plan` List) and each row is bound in a
        // tight inline loop with the direct accessor, exactly like a hand-rolled positional decode
        // (`obj.f = row.get(idx).asX()`). This removes the `planFor` List allocation and the per-row
        // `bindRow` call + `plan.get(k)` indirection that separated the generic binder from hand-decode.
        // Driver-agnostic: any @serializable T bound via orm.bindAll<T> over any driver's ResultSet.
        try serdeAppendf(&src, allocator, "fn {s}__bindAll(rs: ResultSet): List<{s}> {{\n    let out = List<{s}>();\n    let __n = rs.rows.size();\n    if (__n == 0) {{ return out; }}\n", .{ s.name, s.name, s.name });
        for (s.fields, 0..) |f, fi| {
            try serdeAppendf(&src, allocator, "    let __i{d} = colIndexOf(rs.columns, \"{s}\");\n", .{ fi, f.name });
        }
        try src.appendSlice(allocator, "    let __r = 0;\n    while (__r < __n) {\n        let __row = rs.rows.get(__r) ?? Row();\n");
        try serdeAppendf(&src, allocator, "        let obj = {s}();\n", .{s.name});
        for (s.fields, 0..) |f, fi| {
            const fname = f.name;
            var acc: ?[]const u8 = null;
            var enumName: ?[]const u8 = null;
            const tnOpt: ?[]const u8 = switch (f.type_name) {
                .ident => |tn| tn,
                .optional => |inner| if (inner.* == .ident) inner.ident else null,
                else => null,
            };
            if (tnOpt) |tn| {
                if (std.mem.eql(u8, tn, "string")) {
                    acc = "asText";
                } else if (std.mem.eql(u8, tn, "Str")) {
                    acc = "asView";
                } else if (serdeIsInt(tn)) {
                    acc = if (std.mem.eql(u8, tn, "int") or std.mem.eql(u8, tn, "i32")) "asInt" else "asLong";
                } else if (std.mem.eql(u8, tn, "bool")) {
                    acc = "asBool";
                } else if (std.mem.eql(u8, tn, "decimal")) {
                    acc = "asDecimal";
                } else if (serdeIsFloat(tn)) {
                    acc = "asDouble";
                } else if (enums.contains(tn)) {
                    acc = "asText";
                    enumName = tn;
                }
            }
            if (acc) |a| {
                if (enumName) |en| {
                    try serdeAppendf(&src, allocator, "        if (__i{d} >= 0) {{ obj.{s} = {s}__fromName(__row.get(__i{d}).{s}()); }}\n", .{ fi, fname, en, fi, a });
                } else {
                    try serdeAppendf(&src, allocator, "        if (__i{d} >= 0) {{ obj.{s} = __row.get(__i{d}).{s}(); }}\n", .{ fi, fname, fi, a });
                }
            }
        }
        try src.appendSlice(allocator, "        out.push(obj);\n        __r = __r + 1;\n    }\n    return out;\n}\n\n");

        // Buffer->struct binder: `{s}__bindWire` decodes a WHOLE response held as WireRows (one owned
        // buffer + per-row offsets) STRAIGHT into structs -- NO per-row Row/RawBuffer/DbValue materialised.
        // Each field reads its column's bytes directly from the shared buffer (Str fields borrow it). This
        // is the buffer->struct path that eliminates the ~400 refcounted per-row objects a ResultSet builds.
        // Covers string/Str/int/long/float; bool/decimal/enum are skipped (keep their init default).
        try serdeAppendf(&src, allocator, "fn {s}__bindWire(w: WireRows): List<{s}> {{\n    let out = List<{s}>();\n    let __n = w.count();\n    if (__n == 0) {{ return out; }}\n", .{ s.name, s.name, s.name });
        for (s.fields, 0..) |f, fi| {
            try serdeAppendf(&src, allocator, "    let __i{d} = colIndexOf(w.cols, \"{s}\");\n", .{ fi, f.name });
        }
        try src.appendSlice(allocator, "    let __b = w.base;\n    let __r = 0;\n    while (__r < __n) {\n        let __off = w.offs.at(__r);\n");
        try serdeAppendf(&src, allocator, "        let obj = {s}();\n", .{s.name});
        for (s.fields, 0..) |f, fi| {
            const fname = f.name;
            const tnOpt: ?[]const u8 = switch (f.type_name) {
                .ident => |tn| tn,
                .optional => |inner| if (inner.* == .ident) inner.ident else null,
                else => null,
            };
            var call: ?[]const u8 = null; // the wire accessor expression (with a trailing cast if needed)
            if (tnOpt) |tn| {
                if (std.mem.eql(u8, tn, "string")) {
                    call = "wireTextAt(__b, __off, IDX)";
                } else if (std.mem.eql(u8, tn, "Str")) {
                    call = "wireViewAt(__b, __off, IDX)";
                } else if (std.mem.eql(u8, tn, "int") or std.mem.eql(u8, tn, "i32")) {
                    call = "wireIntAt(__b, __off, IDX) as int";
                } else if (serdeIsInt(tn)) {
                    call = "wireIntAt(__b, __off, IDX)";
                } else if (serdeIsFloat(tn)) {
                    call = "wireDoubleAt(__b, __off, IDX)";
                }
            }
            if (call) |c| {
                // Substitute IDX -> __i{fi}.
                var it = std.mem.splitSequence(u8, c, "IDX");
                const first = it.next().?;
                const rest = it.next() orelse "";
                try serdeAppendf(&src, allocator, "        if (__i{d} >= 0) {{ obj.{s} = {s}__i{d}{s}; }}\n", .{ fi, fname, first, fi, rest });
            }
        }
        try src.appendSlice(allocator, "        out.push(obj);\n        __r = __r + 1;\n    }\n    return out;\n}\n\n");
        }   // if (has_db)

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


pub fn generateMediatorDispatch(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
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
pub fn generateRuntimeMediator(allocator: std.mem.Allocator, declarations: *std.ArrayList(ast.Declaration), is_wasm: bool) !void {
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


pub fn loadProgram(allocator: std.mem.Allocator, init: std.process.Init, file_path: []const u8, visited: *std.StringHashMap(void), visiting: *std.StringHashMap(void), merged: *std.ArrayList(u8), declarations: *std.ArrayList(ast.Declaration), is_wasm: bool, file_sources: *std.StringHashMap([]const u8), tinfo: TargetInfo) anyerror!void {
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


pub fn basenameWithoutExtension(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const base = std.fs.path.basename(path);
    const ext_pos = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const name = try allocator.dupe(u8, base[0..ext_pos]);
    return name;
}


pub fn findNovaFiles(allocator: std.mem.Allocator, io: Io, root_dir: Io.Dir, sub_path: []const u8, list: *std.ArrayList([]const u8)) !void {
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


pub const ProjectJson = struct {
    name: []const u8,
    version: []const u8,
    type: ?[]const u8 = null,
    repository: ?[]const u8 = null, // canonical git URL; required by `nova publish` (pkg-manager.md §1)
    dependencies: [][]const u8,
};


pub fn getFileMtime(io: Io, path: []const u8) !i96 {
    const stat = try Io.Dir.statFile(.cwd(), io, path, .{});
    return stat.mtime.nanoseconds;
}


pub fn linkLibsStamp(allocator: std.mem.Allocator, init: std.process.Init) u64 {
    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const libs = [_][]const u8{
        "/.nova/lib/libnovacore.a",
        // The compiler binary itself: a `zig build` reinstalls it and bumps its mtime, so folding it in
        // means a toolchain change (new codegen, new DWARF, new ABI) invalidates every project's build
        // cache and forces a rebuild. Without this, `nova build` reports "up to date" after a compiler
        // upgrade and silently reruns a stale binary -- e.g. an old debug binary keeps showing the old
        // string DWARF, so a debugger fix looks like it did not land.
        "/.nova/bin/nova",
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

pub fn sourcesHash(file_sources: *std.StringHashMap([]const u8), is_release: bool, asan: bool, link_stamp: u64) u64 {
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

/// True if `name` (a `--flag`) appears anywhere in argv. Used to route user-facing build options
/// (--asan, --prune, --split-objects, --keep-obj, --emit-llvm, --dump-merged, --mem-stats, --tsan)
/// as real CLI switches instead of NOVA_* env vars.
pub fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}
