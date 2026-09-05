const std = @import("std");
const builtin = @import("builtin");

const dynamic_llvm_prefix = "/opt/homebrew/opt/llvm";
const static_llvm_prefix = "/Users/kamlesh/LLVM-22.1.0-macOS-ARM64-native";

fn llvmPrefix(b: *std.Build, static: bool) []const u8 {
    return b.graph.environ_map.get("KYTE_LLVM_PREFIX") orelse
        (if (static) static_llvm_prefix else dynamic_llvm_prefix);
}

const llvm_libs_macos = @embedFile("deps/llvm-zig/llvm-libs.txt");
const llvm_libs_linux = @embedFile("deps/llvm-zig/llvm-libs-linux.txt");

fn configureLlvmLink(b: *std.Build, m: *std.Build.Module, static: bool, os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) void {
    const lib_dir = b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
    m.addLibraryPath(.{ .cwd_relative = lib_dir });

    if (!static) {
        if (os_tag == .windows) {
            m.linkSystemLibrary("LLVM-C", .{ .use_pkg_config = .no });
            return;
        }
        m.linkSystemLibrary("LLVM", .{ .use_pkg_config = .no });
        m.linkSystemLibrary("z", .{});
        return;
    }

    var count: usize = 0;
    if (b.graph.environ_map.get("KYTE_LLVM_PREFIX")) |prefix| {
        const io = b.graph.io;
        const lib_dir_path = b.pathJoin(&.{ prefix, "lib" });
        var dir = b.build_root.handle.openDir(io, lib_dir_path, .{ .iterate = true }) catch
            std.debug.panic("configureLlvmLink: cannot open KYTE_LLVM_PREFIX lib dir {s}", .{lib_dir_path});
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (os_tag == .windows) {
                // Windows/MSVC static components are `LLVMCore.lib`, not `libLLVMCore.a`. Skip the
                // dynamic C-API import lib if the prebuilt ships one -- linking `LLVM-C.lib` would pull
                // LLVM-C.dll back in and defeat the entire point of a static, DLL-free kyte.exe.
                if (!std.mem.startsWith(u8, entry.name, "LLVM")) continue;
                if (!std.mem.endsWith(u8, entry.name, ".lib")) continue;
                if (std.mem.eql(u8, entry.name, "LLVM-C.lib")) continue;
                const comp = entry.name[0 .. entry.name.len - ".lib".len];
                m.linkSystemLibrary(b.dupe(comp), .{ .preferred_link_mode = .static, .use_pkg_config = .no });
                count += 1;
            } else {
                if (!std.mem.startsWith(u8, entry.name, "libLLVM")) continue;
                if (!std.mem.endsWith(u8, entry.name, ".a")) continue;
                const comp = entry.name["lib".len .. entry.name.len - ".a".len];
                m.linkSystemLibrary(b.dupe(comp), .{ .preferred_link_mode = .static, .use_pkg_config = .no });
                count += 1;
            }
        }
    } else {
        const llvm_libs = if (os_tag == .linux) llvm_libs_linux else llvm_libs_macos;
        var lines = std.mem.tokenizeScalar(u8, llvm_libs, '\n');
        while (lines.next()) |raw| {
            const comp = std.mem.trim(u8, raw, " \r\t");
            if (comp.len == 0) continue;
            m.linkSystemLibrary(comp, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
            count += 1;
        }
    }
    if (count == 0) std.debug.panic("configureLlvmLink: empty llvm-libs list", .{});

    if (os_tag == .linux) {
        for (&[_][]const u8{ "z", "zstd", "xml2", "lzma" }) |lib|
            m.linkSystemLibrary(lib, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        const stdcxx_dir = b.graph.environ_map.get("KYTE_LLVM_STDCXX_DIR") orelse
            b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ stdcxx_dir, "libstdc++.so" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ stdcxx_dir, "libgcc_s.so" }) });
    } else if (os_tag == .windows) {
        // Static LLVM on Windows pulls the Win32 system import libs LLVM's own CMake links; they come
        // from the Windows SDK on the runner. The prebuilt static LLVM MUST be built with zlib / zstd /
        // libxml2 / terminfo DISABLED (see the "Releasing a static, DLL-free Windows kyte.exe" section
        // in CLAUDE.md) so there are no extra external deps to resolve here -- only these OS libs. The
        // MSVC C++ runtime is folded in by link.exe via the exe's own C++ objects, so no libc++ here.
        for (&[_][]const u8{ "ntdll", "ole32", "oleaut32", "uuid", "psapi", "shell32", "advapi32", "version" }) |lib|
            m.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    } else {
        if (arch == .aarch64) {
            m.addLibraryPath(b.path("deps/zstd"));
            m.linkSystemLibrary("zstd", .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        } else {
            if (b.graph.environ_map.get("KYTE_ZSTD_PREFIX")) |zp|
                m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ zp, "lib" }) });
            m.linkSystemLibrary("zstd", .{ .use_pkg_config = .no });
        }
        m.linkSystemLibrary("z", .{});
        m.linkSystemLibrary("xml2", .{});
        m.link_libcpp = true;
    }
}

const llvm_headers_prefix = "/Users/kamlesh/LLVM-22.1.0-macOS-ARM64";

fn addInprocessLld(b: *std.Build, m: *std.Build.Module) void {
    const headers = b.graph.environ_map.get("KYTE_LLVM_HEADERS") orelse llvm_headers_prefix;
    m.addCSourceFile(.{
        .file = b.path("src/backend/linker/lld_link.cpp"),
        .flags = &.{
            "-std=c++20", "-fno-rtti",
            b.fmt("-I{s}/include", .{headers}),
            "-D_FILE_OFFSET_BITS=64", "-D__STDC_CONSTANT_MACROS",
            "-D__STDC_FORMAT_MACROS", "-D__STDC_LIMIT_MACROS",
        },
    });
    m.link_libcpp = true;
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ llvmPrefix(b, true), "lib" }) });
    for ([_][]const u8{ "lldMachO", "lldWasm", "lldELF", "lldCommon" }) |l| {
        m.linkSystemLibrary(l, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
    }
}

const pinned_zig_version = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

const kyte_version = "0.1.0";
const kyte_abi_version: u32 = 1;

fn assertPinnedZig(b: *std.Build) void {
    if (b.option(bool, "allow-zig-drift", "Bypass the pinned-Zig-version check (toolchain bring-up only)") orelse false) return;
    const v = builtin.zig_version;
    if (v.order(pinned_zig_version) != .eq) {
        std.debug.print(
            \\
            \\error: Kyte is pinned to Zig {f} but you are building with Zig {f}.
            \\       The compiler tracks this exact toolchain (std.Io / std.Build surface);
            \\       a different version can miscompile or fail obscurely.
            \\       Install Zig {f} (scripts/bootstrap-zig.sh fetches + checksum-verifies it),
            \\       or pass -Dallow-zig-drift=true if you are intentionally moving the pin.
            \\
        , .{ pinned_zig_version, v, pinned_zig_version });
        std.process.exit(1);
    }
}

pub fn build(b: *std.Build) void {
    assertPinnedZig(b);
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("kyte", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
    });

    const llvm_dep = b.dependency("llvm", .{
        .target = target,
        .optimize = optimize,
    });
    const llvm_mod = llvm_dep.module("llvm");

    const static_llvm = b.option(bool, "static-llvm", "Static-link LLVM into kyte (self-contained delivery binary; default: dynamic)") orelse false;
    configureLlvmLink(b, llvm_mod, static_llvm, target.result.os.tag, target.result.cpu.arch);

    const is_cross_build = target.result.os.tag != builtin.target.os.tag or
        target.result.cpu.arch != builtin.target.cpu.arch;
    const inprocess_lld = b.option(bool, "inprocess-lld", "Link LLD into kyte for in-process linking (requires -Dstatic-llvm; defaults ON for a cross static build)") orelse (static_llvm and is_cross_build);
    if (inprocess_lld and !static_llvm) @panic("-Dinprocess-lld requires -Dstatic-llvm");
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "inprocess_lld", inprocess_lld);
    build_opts.addOption([]const u8, "kyte_version", kyte_version);
    build_opts.addOption(u32, "kyte_abi_version", kyte_abi_version);
    // Whether the install step assembled `kyte_crypto.o`. Windows links the runtime as a bare COFF
    // object rather than an archive (link.exe cannot read llvm-ar's GNU archive), so the crypto object
    // has to be named explicitly on the link line there — see pipeline.appendRuntimeLink. Passing this
    // as a build option rather than probing the filesystem keeps the two decisions provably identical.
    build_opts.addOption(bool, "has_asm_crypto_obj", asmCryptoFor(target) != null);
    const build_opts_mod = build_opts.createModule();

    mod.addImport("llvm", llvm_mod);
    mod.addImport("build_options", build_opts_mod);

    const exe = b.addExecutable(.{
        .name = "kyte",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kyte", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("llvm", llvm_mod);
    exe.root_module.addImport("build_options", build_opts_mod);
    if (inprocess_lld) addInprocessLld(b, exe.root_module);

    b.installArtifact(exe);



    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    checkTestDiscovery(b);

    addKyteInstall(b, exe, target);
    addKyteArchive(b, exe, target);
}

const TargetInfo = struct { triple: []const u8, os_name: []const u8, arch_name: []const u8, is_cross: bool };

/// The hand-written integrated-assembly crypto source for `target`, plus any define it needs, or null
/// when this target has none.
///
/// Two architectures have a kernel: `kyte_crypto_arm64.S` (AES/GHASH/SHA/ChaCha/Poly over the ARMv8
/// crypto extensions) and `kyte_crypto_amd64.S` (the AES-NI / PCLMULQDQ / SHA-NI / SSE equivalents).
/// `-DKYTE_ASM_CRYPTO_X86` is what switches crypto.cpp from portable C to the CPUID dispatchers, so it
/// must be set on exactly the builds that also assemble the x86 file — hence one helper answering both
/// questions, rather than two conditions that can drift apart.
///
/// Returns null for a CROSS build. The assembled object goes into the NATIVE `libkytecore.a`; a cross
/// build produces `kytecore_<triple>.o` on a different path that never sees this object, and emitting
/// the define there would leave crypto.cpp calling symbols nothing assembled. That was the trap worth
/// designing out: it would surface as a link error far from here.
fn asmCryptoFor(target: std.Build.ResolvedTarget) ?struct { src: []const u8, define: []const u8 } {
    if (target.result.os.tag != builtin.target.os.tag or
        target.result.cpu.arch != builtin.target.cpu.arch) return null;
    return switch (target.result.cpu.arch) {
        .aarch64 => .{ .src = "src/runtime/kyte_crypto_arm64.S", .define = "" },
        .x86_64 => .{ .src = "src/runtime/kyte_crypto_amd64.S", .define = "-DKYTE_ASM_CRYPTO_X86" },
        else => null,
    };
}

fn targetInfo(b: *std.Build, target: std.Build.ResolvedTarget) TargetInfo {
    const arch = @tagName(target.result.cpu.arch);
    const os_name = @tagName(target.result.os.tag);
    const os_triple = switch (target.result.os.tag) {
        .linux => "linux-gnu",
        else => os_name,
    };
    const is_cross = target.result.os.tag != builtin.target.os.tag or
        target.result.cpu.arch != builtin.target.cpu.arch;
    return .{
        .triple = b.fmt("{s}-{s}", .{ arch, os_triple }),
        .os_name = os_name,
        .arch_name = arch,
        .is_cross = is_cross,
    };
}

fn checkTestDiscovery(b: *std.Build) void {
    const io = b.graph.io;
    const root_src = b.build_root.handle.readFileAlloc(
        io,
        "src/root.zig",
        b.allocator,
        .limited(4 << 20),
    ) catch return;

    var src_dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch return;
    defer src_dir.close(io);

    var walker = src_dir.walk(b.allocator) catch return;
    defer walker.deinit();

    var missing: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "root.zig")) continue;

        const content = src_dir.readFileAlloc(io, entry.path, b.allocator, .limited(8 << 20)) catch continue;
        if (!fileHasTests(content)) continue;

        const owned = b.allocator.dupe(u8, entry.path) catch continue;
        std.mem.replaceScalar(u8, owned, '\\', '/');

        const needle = std.fmt.allocPrint(b.allocator, "@import(\"{s}\")", .{owned}) catch continue;
        if (std.mem.indexOf(u8, root_src, needle) != null) continue;

        missing.append(b.allocator, owned) catch continue;
    }

    if (missing.items.len == 0) return;

    std.debug.print(
        \\
        \\error: {d} file(s) under src/ have tests that NOTHING RUNS.
        \\
        \\Zig only runs a file's tests if something references it, so these
        \\contribute 0 tests while `zig build test` still reports success.
        \\
        \\Add to the test block in src/root.zig:
        \\
    , .{missing.items.len});
    for (missing.items) |p| {
        std.debug.print("    _ = @import(\"{s}\");\n", .{p});
    }
    std.debug.print("\n", .{});
    std.process.exit(1);
}

fn fileHasTests(src: []const u8) bool {
    if (std.mem.startsWith(u8, src, "test \"") or std.mem.startsWith(u8, src, "test {")) return true;
    return std.mem.indexOf(u8, src, "\ntest \"") != null or std.mem.indexOf(u8, src, "\ntest {") != null;
}

fn addKyteInstall(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse
        std.debug.panic("$HOME not set; cannot run install steps", .{});

    const ti = targetInfo(b, target);
    const cxx = if (ti.is_cross)
        b.fmt("zig c++ -target {s}", .{ti.triple})
    else
        "clang++";

    const bin_dest = b.fmt("{s}/.kyte/bin", .{home});
    const std_dest = b.fmt("{s}/.kyte/std", .{home});

    // Integrated-assembly crypto path (the Go/BoringSSL model): assemble this architecture's hand-written
    // crypto routines and bundle the object into libkytecore.a, so every Kyte binary links them and calls
    // them by symbol via extern("c") — a plain call, with no cgo/FFI marshalling. The three strings below
    // are spliced into both install scripts; `# no integrated assembly` is a comment in sh AND PowerShell,
    // so the no-kernel case needs no branching in either.
    const asm_crypto = asmCryptoFor(target);
    const asm_cmd = if (asm_crypto) |ac|
        b.fmt("{s} -O2 -c {s} -o \"{s}/.kyte/lib/kyte_crypto.o\"", .{ cxx, ac.src, home })
    else
        "# no integrated assembly crypto kernel for this target";
    const asm_obj = if (asm_crypto != null) b.fmt("\"{s}/.kyte/lib/kyte_crypto.o\"", .{home}) else "";
    const asm_def = if (asm_crypto) |ac| ac.define else "";

    if (builtin.os.tag == .windows) {
        const ps = b.fmt(
            \\$ErrorActionPreference = "Stop"
            \\New-Item -ItemType Directory -Force -Path "{[bin]s}","{[std]s}","{[home]s}/.kyte/src/runtime","{[home]s}/.kyte/deps","{[home]s}/.kyte/lib" | Out-Null
            \\Copy-Item -Force zig-out/bin/kyte.exe "{[bin]s}/kyte.exe"
            \\Copy-Item -Recurse -Force src/lib/std/* "{[std]s}/"
            \\Copy-Item -Recurse -Force src/runtime/* "{[home]s}/.kyte/src/runtime/"
            \\Copy-Item -Recurse -Force deps/* "{[home]s}/.kyte/deps/"
            \\Write-Host "Building kytecore.lib (Windows; reactor runtime + Win32 syscall shims) ..."
            \\{[asm_cmd]s}
            \\{[cxx]s} -std=c++20 -O2 -DKYTE_DROP_ARENA {[asm_def]s} -c src/runtime/runtime.cpp -o "{[home]s}/.kyte/lib/kytecore.o"
            \\# Archive as a COFF .lib via llvm-lib, NOT a GNU .a via llvm-ar: MSVC's link.exe (which the
            \\# shipped toolchain drives to link user programs) cannot read llvm-ar's GNU archive, but it
            \\# reads llvm-lib's COFF archive fine. So on Windows the runtime ships as kytecore.lib and
            \\# appendRuntimeLink links it directly (the crypto object rides inside the same .lib).
            \\llvm-lib "-out:{[home]s}/.kyte/lib/kytecore.lib" "{[home]s}/.kyte/lib/kytecore.o" {[asm_obj]s}
            \\# KYTE_ASAN=1: additionally build an AddressSanitizer runtime, so `conformance/run.sh --asan`
            \\# works here too. clang's ASAN is fully functional on Windows against the MSVC runtime; what
            \\# it needs is clang_rt.asan_dynamic-x86_64.dll on PATH at RUN time (it lives in
            \\# <llvm>/lib/clang/<ver>/lib/windows, NOT in bin), or the instrumented binary dies with
            \\# "error while loading shared libraries" before main. Same class of trap as LLVM-C.dll.
            \\if ($env:KYTE_ASAN -eq "1") {{
            \\  Write-Host "Building kytecore_asan.lib (AddressSanitizer) ..."
            \\  {[cxx]s} -std=c++20 -O1 -g -fsanitize=address -fno-omit-frame-pointer -DKYTE_DROP_ARENA {[asm_def]s} -c src/runtime/runtime.cpp -o "{[home]s}/.kyte/lib/kytecore_asan.o"
            \\  llvm-lib "-out:{[home]s}/.kyte/lib/kytecore_asan.lib" "{[home]s}/.kyte/lib/kytecore_asan.o" {[asm_obj]s}
            \\  Write-Host "ASAN runtime built. Use: KYTE_ASAN=1 kyte test <file>"
            \\}}
            \\Write-Host "Installed compiler to {[bin]s}/kyte.exe"
            \\Write-Host "Prebuilt kytecore.lib; synced std/runtime/deps to {[home]s}/.kyte/"
            \\
        , .{
            .bin = bin_dest,
            .std = std_dest,
            .home = home,
            .cxx = cxx,
            .asm_cmd = asm_cmd,
            .asm_obj = asm_obj,
            .asm_def = asm_def,
        });
        const install_cmd_ps = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps });
        const install_exe_ps = b.addInstallArtifact(exe, .{});
        install_cmd_ps.step.dependOn(&install_exe_ps.step);
        b.getInstallStep().dependOn(&install_cmd_ps.step);
        return;
    }

    const script = b.fmt(
        \\set -e
        \\mkdir -p "{[bin]s}"
        \\mkdir -p "{[std]s}"
        \\mkdir -p "{[home]s}/.kyte/src/runtime"
        \\mkdir -p "{[home]s}/.kyte/deps"
        \\mkdir -p "{[home]s}/.kyte/lib"
        \\cp zig-out/bin/kyte "{[bin]s}/kyte"
        \\rsync -a --exclude=".git" src/lib/std/ "{[std]s}/"
        \\rsync -a --exclude=".git" src/runtime/ "{[home]s}/.kyte/src/runtime/"
        \\# W1: build the vendored webview static lib once (FFI `extern("webview")`). macOS
        \\# Cocoa/WKWebView backend (Objective-C++). Built BEFORE the deps rsync so the fresh
        \\# .a is synced to ~/.kyte/deps this same run. Skipped if already built.
        \\WEBVIEW_LIB="deps/webview/build/libwebview.a"
        \\WV_NEED=0
        \\[ ! -f "$WEBVIEW_LIB" ] && WV_NEED=1
        \\[ deps/webview/webview_impl.cc -nt "$WEBVIEW_LIB" ] && WV_NEED=1
        \\[ deps/webview/webview_kyte.cc -nt "$WEBVIEW_LIB" ] && WV_NEED=1
        \\if [ "$WV_NEED" = "1" ] && [ -f deps/webview/webview_impl.cc ]; then
        \\  echo "webview: building static lib ..."
        \\  mkdir -p deps/webview/build
        \\  clang++ -std=c++17 -ObjC++ -O2 -c deps/webview/webview_impl.cc \
        \\      -o deps/webview/build/webview_impl.o 2>/dev/null && \
        \\  clang++ -std=c++17 -ObjC++ -O2 -c deps/webview/webview_kyte.cc \
        \\      -o deps/webview/build/webview_kyte.o 2>/dev/null && \
        \\  ar rcs "$WEBVIEW_LIB" deps/webview/build/webview_impl.o deps/webview/build/webview_kyte.o && \
        \\  echo "webview: built ($WEBVIEW_LIB)" || echo "webview: build failed (GUI FFI unavailable)"
        \\fi
        \\rsync -a --exclude=".git" deps/ "{[home]s}/.kyte/deps/"
        \\# Prebuild the C++ runtime ONCE into a static library. Boost.Asio has been retired (M4):
        \\# the async runtime is reactor-native (net/eventedio over os/sys, kqueue/epoll), so nothing
        \\# in src/runtime includes Boost and no Boost include path is needed.
        \\# TLS is pure Kyte (M9/M11/M13): crypto/tls + net/tlsmembio + net/tls12bio. wolfSSL is retired,
        \\# so there is no C TLS library to build or link, and no KYTE_HAVE_WOLFSSL define.
        \\echo "Building libkytecore.a (no Boost, no wolfSSL; reactor runtime) ..."
        \\# Integrated-assembly crypto path (Go/BoringSSL model): assemble this architecture's hand-written
        \\# crypto routines -- kyte_crypto_arm64.S on aarch64, kyte_crypto_amd64.S on x86_64 -- and bundle
        \\# the object into libkytecore.a, so every Kyte binary links them and calls them by symbol
        \\# (extern "c") with NO cgo/FFI marshalling. Chosen in build.zig from the RESOLVED TARGET rather
        \\# than `uname -m`, so a cross build never assembles the host's assembly by mistake. On an
        \\# architecture with no kernel the symbols come from the C fallbacks in crypto.cpp instead.
        \\# This runs BEFORE the runtime.cpp compile because the x86 path also contributes
        \\# -DKYTE_ASM_CRYPTO_X86, which is what switches crypto.cpp to the CPUID dispatchers.
        \\{[asm_cmd]s}
        \\# Workstream A: KYTE_DROP_ARENA makes every heap object honestly refcounted
        \\# (no load-bearing thread-local arena). Required for multi-core + clean ARC.
        \\{[cxx]s} -std=c++20 -O2 -pthread -DKYTE_DROP_ARENA {[asm_def]s} -c \
        \\    src/runtime/runtime.cpp -o "{[home]s}/.kyte/lib/kytecore.o"
        \\ar rcs "{[home]s}/.kyte/lib/libkytecore.a" "{[home]s}/.kyte/lib/kytecore.o" {[asm_obj]s}
        \\# T1: the cross-compilation cache (kytecore_<triple>.o, built lazily by `kyte build
        \\# --target ...`) is keyed only by triple, so it must be invalidated whenever the runtime
        \\# source changes. Clear it here, triples contain dashes, so this glob spares kytecore_asan.o.
        \\rm -f "{[home]s}/.kyte/lib/kytecore_"*-*.o 2>/dev/null || true
        \\# KYTE_ASAN=1: additionally build an AddressSanitizer runtime. Opt-in because it
        \\# roughly doubles this step; `kyte test` links it only when KYTE_ASAN=1 too.
        \\#
        \\# WHY: ARC decides ownership from a rendered type NAME, and when the name is
        \\# unknown it GUESSES, isRefCountedType's catch-all returns true, so "the compiler
        \\# is confused" means "free this memory". The result is a use-after-free whose crash
        \\# lands somewhere unrelated, at a location chosen by the allocator rather than by the
        \\# bug: `kyte_release` on a freed object reads the refcount at ptr-8 and looks harmless
        \\# until malloc REUSES the block, at which point it decrements a DIFFERENT object.
        \\# That is how "string heap corruption" stayed misfiled for months. ASAN turns exactly
        \\# that read into a located report AT the release, naming both the free and the use.
        \\# NOTE: the runtime is instrumented; codegen's LLVM IR is not, so a read of freed
        \\# memory from KYTE code is caught only when it flows through a runtime entry point
        \\# (which every retain/release/alloc does). LeakSanitizer is unsupported on Darwin,
        \\# use KYTE_ARC_AUDIT for leaks, which is semantic and better anyway.
        \\if [ "${{KYTE_ASAN:-0}}" = "1" ]; then
        \\  echo "Building libkytecore_asan.a (AddressSanitizer) ..."
        \\  clang++ -std=c++20 -O1 -g -fsanitize=address -fno-omit-frame-pointer \
        \\      -pthread -DKYTE_DROP_ARENA {[asm_def]s} -c \
        \\      src/runtime/runtime.cpp -o "{[home]s}/.kyte/lib/kytecore_asan.o"
        \\  ar rcs "{[home]s}/.kyte/lib/libkytecore_asan.a" "{[home]s}/.kyte/lib/kytecore_asan.o" {[asm_obj]s}
        \\  echo "ASAN runtime built. Use: KYTE_ASAN=1 kyte test <file>"
        \\fi
        \\# KYTE_TSAN=1: additionally build a ThreadSanitizer runtime. This is the gate for the
        \\# self-hosted runtime work (docs/design/self-hosted-runtime.md): the corpus and the ASAN
        \\# gate are effectively single-threaded and CANNOT catch a data race in the multi-reactor
        \\# runtime. TSan instruments the C++ runtime (the scheduler, the CoroState map, the
        \\# reactors) so that a race under KYTE_THREADS>1 becomes a located report naming both
        \\# accesses. Opt-in because it is slow; `kyte test` links it only when KYTE_TSAN=1 too.
        \\if [ "${{KYTE_TSAN:-0}}" = "1" ]; then
        \\  echo "Building libkytecore_tsan.a (ThreadSanitizer) ..."
        \\  clang++ -std=c++20 -O1 -g -fsanitize=thread -fno-omit-frame-pointer \
        \\      -pthread -DKYTE_DROP_ARENA -c \
        \\      src/runtime/runtime.cpp -o "{[home]s}/.kyte/lib/kytecore_tsan.o"
        \\  ar rcs "{[home]s}/.kyte/lib/libkytecore_tsan.a" "{[home]s}/.kyte/lib/kytecore_tsan.o"
        \\  echo "TSAN runtime built. Use: KYTE_TSAN=1 kyte test <file> (with KYTE_THREADS>1)"
        \\fi
        \\echo "Installed compiler to {[bin]s}/kyte"
        \\echo "Prebuilt libkytecore.a; synced std/runtime/deps to {[home]s}/.kyte/"
        \\
    , .{
        .bin = bin_dest,
        .std = std_dest,
        .home = home,
        .cxx = cxx,
        .asm_cmd = asm_cmd,
        .asm_obj = asm_obj,
        .asm_def = asm_def,
    });

    const install_cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    const install_exe = b.addInstallArtifact(exe, .{});
    install_cmd.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&install_cmd.step);
}

fn addKyteArchive(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const ti = targetInfo(b, target);
    const os_name = ti.os_name;
    const arch_name = ti.arch_name;
    const version = b.graph.environ_map.get("KYTE_VERSION") orelse "dev";
    const bundle = b.fmt("kyte-{s}-{s}-{s}", .{ version, os_name, arch_name });

    const archive_step = b.step("archive", "Package a self-installing, versioned, checksummed toolchain bundle (kyte + nls + stdlib) for this host");

    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse
        std.debug.panic("$HOME not set; cannot run archive step", .{});

    if (builtin.os.tag == .windows) {
        const ps = b.fmt(
            \\$ErrorActionPreference = "Stop"
            \\$stage = "zig-out/dist/{[bundle]s}"
            \\if (Test-Path $stage) {{ Remove-Item -Recurse -Force $stage }}
            \\New-Item -ItemType Directory -Force -Path "$stage/bin","$stage/lib" | Out-Null
            \\Copy-Item -Force "{[home]s}/.kyte/bin/kyte.exe" "$stage/bin/kyte.exe"
            \\# nls: PURE ZIG (no LLVM link), built from the sibling repo unless KYTE_ARCHIVE_SKIP_NLS=1,
            \\# matching the Unix path -- skip only when the nls repo is not checked out.
            \\if ($env:KYTE_ARCHIVE_SKIP_NLS -eq "1") {{ Write-Host "archive: KYTE_ARCHIVE_SKIP_NLS=1 -- bundling without nls" }}
            \\else {{ Push-Location ../nls; zig build "-Dkyte-src=../lang/src/root.zig"; Pop-Location; Copy-Item -Force "{[home]s}/.kyte/bin/nls.exe" "$stage/bin/nls.exe" }}
            \\# A -Dstatic-llvm build (the release path) links LLVM into kyte.exe and needs NO DLL -- the
            \\# static prefix has no bin/LLVM-C.dll, so the copy below simply no-ops. It stays only to keep
            \\# a legacy DYNAMIC build (`zig build archive` without -Dstatic-llvm) self-contained, where the
            \\# loader must find LLVM-C.dll in the exe's own directory.
            \\if ($env:KYTE_LLVM_PREFIX) {{ Copy-Item -Force "$env:KYTE_LLVM_PREFIX/bin/LLVM-C.dll" "$stage/bin/" -ErrorAction SilentlyContinue }}
            \\Copy-Item -Force "{[home]s}/.kyte/lib/kytecore.lib" "$stage/lib/"
            \\Copy-Item -Recurse -Force "{[home]s}/.kyte/std" "$stage/std"
            \\# NOTE: src/runtime + deps are NOT bundled -- the prebuilt kytecore.lib covers
            \\# host-target compilation. They are only needed to cross-compile the runtime to OTHER
            \\# targets (kyte build --target) or to build webview FFI apps; add them back if the
            \\# shipped toolchain must do that.
            \\Set-Content "$stage/VERSION" "{[version]s}"
            \\# self-installer: copy the tree into the user's ~/.kyte
            \\Set-Content "$stage/install.ps1" '$d="$env:USERPROFILE/.kyte"; New-Item -ItemType Directory -Force -Path "$d/bin","$d/lib" | Out-Null; Copy-Item -Recurse -Force ./* "$d/"; Write-Host "Installed Kyte to $d"'
            \\Compress-Archive -Force -Path "$stage/*" -DestinationPath "zig-out/{[bundle]s}.zip"
            \\# SHA256 via .NET types, NOT Get-FileHash: the powershell this build spawns does not
            \\# reliably autoload the Utility module (PSModulePath is not set), so Get-FileHash is
            \\# "not recognized". [System.Security.Cryptography] is always available.
            \\$bytes = [System.IO.File]::ReadAllBytes("zig-out/{[bundle]s}.zip")
            \\$sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
            \\$hex = ($sha | ForEach-Object {{ $_.ToString("x2") }}) -join ""
            \\Set-Content "zig-out/{[bundle]s}.zip.sha256" "$hex  {[bundle]s}.zip"
            \\Write-Host "archive:  zig-out/{[bundle]s}.zip"
            \\Write-Host "checksum: zig-out/{[bundle]s}.zip.sha256"
            \\
        , .{ .bundle = bundle, .home = home, .version = version });
        const cmd = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps });
        cmd.step.dependOn(b.getInstallStep());
        archive_step.dependOn(&cmd.step);
        return;
    }

    const script = b.fmt(
        \\set -e
        \\STAGE="zig-out/dist/{[bundle]s}"
        \\rm -rf "$STAGE"
        \\mkdir -p "$STAGE/bin" "$STAGE/lib"
        \\cp "{[home]s}/.kyte/bin/kyte" "$STAGE/bin/kyte"
        \\# nls: build fresh from the sibling compiler repo (installs to ~/.kyte/bin/nls). It is PURE ZIG
        \\# (no LLVM link -- the LSP only touches the frontend re-exports, not codegen), so it builds on
        \\# any runner with the bundled Zig toolchain alone; pinned to THIS lang checkout via -Dkyte-src.
        \\# Set KYTE_ARCHIVE_SKIP_NLS=1 only to intentionally ship a kyte+stdlib bundle without the LSP
        \\# (e.g. when the nls repo is not checked out).
        \\if [ "${{KYTE_ARCHIVE_SKIP_NLS:-0}}" = "1" ]; then
        \\  echo "archive: KYTE_ARCHIVE_SKIP_NLS=1 -- bundling without nls (language server)"
        \\else
        \\  ( cd ../nls && zig build -Dkyte-src=../lang/src/root.zig )
        \\  cp "{[home]s}/.kyte/bin/nls" "$STAGE/bin/nls"
        \\fi
        \\cp "{[home]s}/.kyte/lib/libkytecore.a" "$STAGE/lib/"
        \\rsync -a "{[home]s}/.kyte/std/" "$STAGE/std/"
        \\# NOTE: src/runtime + deps are NOT bundled -- the prebuilt libkytecore.a covers host-target
        \\# compilation. They are only needed to cross-compile the runtime to OTHER targets
        \\# (kyte build --target) or to build webview FFI apps; add them back if that is required.
        \\printf '%s\n' "{[version]s}" > "$STAGE/VERSION"
        \\# self-installer: copy the tree into the user's ~/.kyte
        \\cat > "$STAGE/install.sh" <<'INSTALL'
        \\#!/bin/sh
        \\set -e
        \\D="$HOME/.kyte"
        \\mkdir -p "$D/bin" "$D/lib"
        \\cp -R ./bin/* "$D/bin/"
        \\cp -R ./lib/* "$D/lib/"
        \\cp -R ./std "$D/"
        \\echo "Installed Kyte to $D (add $D/bin to PATH)"
        \\INSTALL
        \\chmod +x "$STAGE/install.sh"
        \\tar czf "zig-out/{[bundle]s}.tar.gz" -C zig-out/dist "{[bundle]s}"
        \\# SHA256 checksum next to the archive (sha256sum on Linux, shasum on macOS)
        \\( cd zig-out && {{ command -v sha256sum >/dev/null 2>&1 && sha256sum "{[bundle]s}.tar.gz" || shasum -a 256 "{[bundle]s}.tar.gz"; }} > "{[bundle]s}.tar.gz.sha256" )
        \\echo "archive:  zig-out/{[bundle]s}.tar.gz"
        \\echo "checksum: zig-out/{[bundle]s}.tar.gz.sha256"
        \\
    , .{ .bundle = bundle, .home = home, .version = version });

    const cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    cmd.step.dependOn(b.getInstallStep());
    _ = exe;
    archive_step.dependOn(&cmd.step);
}
