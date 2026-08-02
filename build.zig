const std = @import("std");
const builtin = @import("builtin");

// LLVM install prefixes (override either with NOVA_LLVM_PREFIX). The two link
// modes need different trees:
//   dynamic (dev)  → Homebrew LLVM 21: has libLLVM.dylib.
//   static (deliv) → native LLVM 22: libLLVM*.a as *native* Mach-O (produced by
//                    converting the LLVM.org 22 drop's LTO bitcode with llc; the
//                    drop itself is unlinkable bitcode — see README-static-llvm.md).
// llvm-libs.txt is the native-22 component set (a superset of Homebrew 21).
const dynamic_llvm_prefix = "/opt/homebrew/opt/llvm";
const static_llvm_prefix = "/Users/kamlesh/LLVM-22.1.0-macOS-ARM64-native";

fn llvmPrefix(b: *std.Build, static: bool) []const u8 {
    return b.graph.environ_map.get("NOVA_LLVM_PREFIX") orelse
        (if (static) static_llvm_prefix else dynamic_llvm_prefix);
}

// The static LLVM component set differs per OS (the apt Linux drop is 226 native-ELF archives; the
// converted macOS-22 drop is 211). Committed lists let the static link pick the right names by target.
const llvm_libs_macos = @embedFile("deps/llvm-zig/llvm-libs.txt");
const llvm_libs_linux = @embedFile("deps/llvm-zig/llvm-libs-linux.txt");

// Wire LLVM into `m` (the `llvm` binding module). The vendored deps/llvm-zig
// build.zig deliberately does NO LLVM linking — it happens here so this repo
// owns the toolchain paths and the dynamic/static choice. Paths come from `llvmPrefix`
// (NOVA_LLVM_PREFIX, else the hardcoded dev prefix) -- there is no fetched mirror.
fn configureLlvmLink(b: *std.Build, m: *std.Build.Module, static: bool, os_tag: std.Target.Os.Tag) void {
    // The LLVM prefix: NOVA_LLVM_PREFIX (an installed apt/brew LLVM), else the hardcoded dev prefix.
    // There is no auto-fetched mirror -- static builds link a LOCAL LLVM (the CI release workflow
    // installs LLVM 21 and sets NOVA_LLVM_PREFIX; see release.yml).
    const lib_dir = b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
    m.addLibraryPath(.{ .cwd_relative = lib_dir });

    if (!static) {
        if (os_tag == .windows) {
            // Native Windows dev build: dynamic-link the LLVM C API from a local LLVM install.
            // Set NOVA_LLVM_PREFIX to the install root (e.g. C:/Program Files/LLVM) so the lib path
            // above resolves to <prefix>/lib, which holds LLVM-C.lib (the import lib for LLVM-C.dll).
            // No system zlib on Windows; the C-API surface does not require it.
            m.linkSystemLibrary("LLVM-C", .{ .use_pkg_config = .no });
            return;
        }
        // Default: dynamic link (fast dev builds), matching the original dep.
        m.linkSystemLibrary("LLVM", .{ .use_pkg_config = .no });
        m.linkSystemLibrary("z", .{});
        return;
    }

    // Static: link every libLLVM*.a component. The linker demand-loads only the
    // members that resolve undefined symbols, so listing the whole set matches an
    // `llvm-config --libs` curation, order-independent (macOS ld resolves archive
    // cycles).
    //
    // TWO sources for the component list:
    //   * BRING-YOUR-OWN LLVM (NOVA_LLVM_PREFIX set -- e.g. an apt/brew `llvm@21` install in CI):
    //     GLOB the prefix's lib dir for the libLLVM*.a it actually ships. A stock package-manager
    //     LLVM has a slightly different component set than the pinned mirror (it lacks a handful like
    //     LLVMCAS/LLVMDTLTO), so a hardcoded list would fail to link against it. Globbing the actual
    //     install is what lets "just apt/brew install llvm-21" work with no per-source list upkeep.
    //   * MIRROR (no prefix): the committed list (reproducible, no configure-time fs walk).
    //     Regenerate with: ls <prefix>/lib/libLLVM*.a | xargs -n1 basename | sed 's/^lib//;s/\.a$//' \
    //       | sort > deps/llvm-zig/llvm-libs.txt
    var count: usize = 0;
    if (b.graph.environ_map.get("NOVA_LLVM_PREFIX")) |prefix| {
        const io = b.graph.io;
        const lib_dir_path = b.pathJoin(&.{ prefix, "lib" });
        // build_root.handle.openDir with an ABSOLUTE path works on POSIX (the base fd is ignored).
        var dir = b.build_root.handle.openDir(io, lib_dir_path, .{ .iterate = true }) catch
            std.debug.panic("configureLlvmLink: cannot open NOVA_LLVM_PREFIX lib dir {s}", .{lib_dir_path});
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "libLLVM")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".a")) continue;
            const comp = entry.name["lib".len .. entry.name.len - ".a".len]; // libLLVMXxx.a -> LLVMXxx
            m.linkSystemLibrary(b.dupe(comp), .{ .preferred_link_mode = .static, .use_pkg_config = .no });
            count += 1;
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

    // Externals LLVM's static archives reference (zstd, zlib, libxml2). These live IN the LLVM
    // prefix's own lib dir for a self-contained mirror drop; on macOS z/xml2 fall back to SDK dylibs
    // and zstd is the vendored copy. Link them static so `nova` stays self-contained.
    if (os_tag == .linux) {
        // The Linux mirror artifact bundles LLVM's C-lib deps as static archives alongside libLLVM*.a
        // (apt's LLVM was built against them). xml2 in turn needs lzma. Resolve from the prefix lib dir.
        for (&[_][]const u8{ "z", "zstd", "xml2", "lzma" }) |lib|
            m.linkSystemLibrary(lib, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        // Prebuilt Linux LLVM is compiled against libstdc++ (the std::__cxx11 / GLIBCXX ABI), NOT
        // libc++. It must link libstdc++.so — but `linkSystemLibrary("stdc++")` gets ALIASED by zig
        // to its own `-lc++` (libc++, wrong ABI → every std:: sym undefined), and a static libstdc++.a
        // hits ld.lld's archive-cycle limit (macOS ld auto-resolves cycles; ld.lld needs --start-group,
        // which zig-build can't emit). So pass the SHARED libstdc++.so as an explicit positional input,
        // bypassing zig's -l normalization. libstdc++.so.6 + glibc are on every Linux, so the binary is
        // still "deploy only nova" in practice (the real win — no libLLVM.so dep — is preserved). Target
        // must be *-linux-gnu. NOTE: these .so live in the LLVM prefix's lib dir for a self-contained
        // LLVM tree; a stock apt LLVM does NOT bundle them (they are system libs), so a bring-your-own
        // apt LLVM in CI may need NOVA_LLVM_STDCXX_DIR or a symlink -- the Linux static path is not yet
        // CI-verified (see release.yml build-linux).
        const stdcxx_dir = b.graph.environ_map.get("NOVA_LLVM_STDCXX_DIR") orelse
            b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ stdcxx_dir, "libstdc++.so" }) });
        m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ stdcxx_dir, "libgcc_s.so" }) }); // libgcc_s unwinder
    } else {
        // zstd: llvm-config bakes in a Homebrew path; use the vendored static copy.
        m.addLibraryPath(b.path("deps/zstd"));
        m.linkSystemLibrary("zstd", .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        // z/xml2 resolve against the macOS SDK dylibs.
        m.linkSystemLibrary("z", .{});
        m.linkSystemLibrary("xml2", .{});
        // LLVM static archives are C++ objects → need the C++ runtime (LLVM's libc++ on macOS).
        m.link_libcpp = true;
    }
}

// LLVM/LLD C++ headers for compiling the in-process-LLD shim. The native tree
// (`…-native/`) has only lib/; headers come from the original drop's include/.
const llvm_headers_prefix = "/Users/kamlesh/LLVM-22.1.0-macOS-ARM64";

// Compile src/linker/lld_link.cpp into `m` and link the native liblld*.a so
// nova can call lld::{macho,wasm,elf}::link() in-process. Requires the static
// LLVM link (configureLlvmLink) to already be on the same module tree.
fn addInprocessLld(b: *std.Build, m: *std.Build.Module) void {
    const headers = b.graph.environ_map.get("NOVA_LLVM_HEADERS") orelse llvm_headers_prefix;
    m.addCSourceFile(.{
        .file = b.path("src/linker/lld_link.cpp"),
        .flags = &.{
            "-std=c++20", "-fno-rtti",
            b.fmt("-I{s}/include", .{headers}),
            "-D_FILE_OFFSET_BITS=64", "-D__STDC_CONSTANT_MACROS",
            "-D__STDC_FORMAT_MACROS", "-D__STDC_LIMIT_MACROS",
        },
    });
    m.link_libcpp = true;
    // The native liblld*.a live in the static prefix lib dir (already added to
    // the library path by configureLlvmLink); add it here too so this module
    // resolves them, then link the four drivers nova exposes.
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ llvmPrefix(b, true), "lib" }) });
    for ([_][]const u8{ "lldMachO", "lldWasm", "lldELF", "lldCommon" }) |l| {
        m.linkSystemLibrary(l, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
    }
}

// L4 toolchain pin: the compiler is developed and gated against EXACTLY this Zig. Nova rides Zig
// 0.16's std.Io/std.Build surface closely, so a drifted toolchain fails in obscure ways -- pin it
// here (single source of truth, mirrored by .zig-version and scripts/zig-checksums.txt) and fail
// LOUD at configure time on a mismatch. Override deliberately with -Dallow-zig-drift=true when
// bringing the toolchain forward (then update all three pin sites + re-run the gates).
const pinned_zig_version = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

// L5 stability: the language/toolchain version (semver) and the extern-C runtime ABI contract
// version. `nova_version` is mirrored in build.zig.zon `.version`; keep them in lockstep. `nova`
// is BETA -- a 0.x version deliberately signals "no cross-version stability guarantee yet" per
// docs/STABILITY.md. `nova_abi_version` matches src/runtime/nova_abi.h NOVA_ABI_VERSION.
const nova_version = "0.1.0";
const nova_abi_version: u32 = 1;

fn assertPinnedZig(b: *std.Build) void {
    if (b.option(bool, "allow-zig-drift", "Bypass the pinned-Zig-version check (toolchain bring-up only)") orelse false) return;
    const v = builtin.zig_version;
    if (v.order(pinned_zig_version) != .eq) {
        std.debug.print(
            \\
            \\error: Nova is pinned to Zig {f} but you are building with Zig {f}.
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

    const mod = b.addModule("nova", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
    });

    const llvm_dep = b.dependency("llvm", .{
        .target = target,
        .optimize = optimize,
    });
    const llvm_mod = llvm_dep.module("llvm");

    // P5 #20 (toolchain self-sufficiency). LLVM linking is applied to the `llvm`
    // module so it is transitive to every importer (exe + test module).
    //   default            → dynamic libLLVM.dylib (Homebrew): fast dev builds.
    //   -Dstatic-llvm=true → static-link the LLVM component archives so the
    //                        resulting `nova` carries LLVM and loads no
    //                        libLLVM.dylib (self-contained delivery binary).
    // NOTE: the static path needs *native* Mach-O archives. Homebrew's LLVM 21
    // archives are native; the LLVM.org 22 drop is LTO bitcode (not linkable by
    // Zig's linker) — see deps/llvm-zig/README-static-llvm.md.
    const static_llvm = b.option(bool, "static-llvm", "Static-link LLVM into nova (self-contained delivery binary; default: dynamic)") orelse false;
    // A STATIC build links a LOCAL LLVM: set NOVA_LLVM_PREFIX to an installed LLVM (apt/brew llvm-21 --
    // its libLLVM*.a are globbed in configureLlvmLink), else the hardcoded dev prefix is used. There is
    // no auto-fetched mirror (the CI release workflow installs LLVM 21 and sets the prefix).
    configureLlvmLink(b, llvm_mod, static_llvm, target.result.os.tag);

    // P5 #20: link LLD into nova so it links its output executables in-process
    // (no clang/ld shell-out). Requires -Dstatic-llvm (needs the native liblld*.a
    // + libLLVM from the same LLVM 22 tree). Exposed to the code via build_options.
    const inprocess_lld = b.option(bool, "inprocess-lld", "Link LLD into nova for in-process linking (requires -Dstatic-llvm)") orelse false;
    if (inprocess_lld and !static_llvm) @panic("-Dinprocess-lld requires -Dstatic-llvm");
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "inprocess_lld", inprocess_lld);
    // L5 stability: single source of truth for the version surfaced by `nova version`.
    //   nova_version   -- the language/toolchain semver (also mirrored in build.zig.zon).
    //   nova_abi_version -- the extern-C runtime ABI contract version (see src/runtime/nova_abi.h
    //                       NOVA_ABI_VERSION and docs/abi/runtime-abi.md). Bumped ONLY on a
    //                       breaking change to the stable seam (heap header layout / retain-release).
    build_opts.addOption([]const u8, "nova_version", nova_version);
    build_opts.addOption(u32, "nova_abi_version", nova_abi_version);
    const build_opts_mod = build_opts.createModule();

    // `mod` is the module `zig build test` compiles (`addTest{ .root_module = mod }`),
    // and it reaches `codegen/*`, which imports `llvm`. Without this the tests build
    // ONLY while no test touches an llvm-typed decl — Zig analyses top-level decls
    // lazily, so `const llvm = @import("llvm")` sits there unresolved and harmless
    // until something names it, and then:
    //
    //     error: no module named 'llvm' available within module 'root'
    //
    // The exe never noticed because `main.zig` imports by RELATIVE path
    // (`@import("sema/mono.zig")`), so it reaches src/ through `exe.root_module` —
    // which has llvm. Two module views of one tree; only one was wired.
    //
    // A test module must carry the same imports as the code it tests, or the tests
    // you can write are silently restricted to the ones that avoid the dependency.
    mod.addImport("llvm", llvm_mod);
    mod.addImport("build_options", build_opts_mod);

    const exe = b.addExecutable(.{
        .name = "nova",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nova", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("llvm", llvm_mod);
    exe.root_module.addImport("build_options", build_opts_mod);
    if (inprocess_lld) addInprocessLld(b, exe.root_module);

    b.installArtifact(exe);

    // Build for WASM
    // const wasm_target = b.resolveTargetQuery(.{
    //     .cpu_arch = .wasm32,
    //     .os_tag = .freestanding,
    // });

    // const wasm_exe = b.addExecutable(.{
    //     .name = "nova_wasm",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = wasm_target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "nova_lang", .module = mod },
    //         },
    //     }),
    // });
    // b.installArtifact(wasm_exe);

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

    addNovaInstall(b, exe);
    addNovaArchive(b, exe);
}

/// `src/root.zig`'s test block is a HAND-WRITTEN list, and Zig only runs the tests of
/// a file that something references. So a file with tests that is missing from that
/// list contributes ZERO tests — and the suite still reports success. Measured
/// 2026-07-16: `codegen/types.zig` was absent, `zig build test` said
/// **"101/101 tests passed"**, and the 5 tests it did not run included one asserting a
/// deliberately WRONG value. Adding the line took it to 106/106.
///
/// That is the same shape as the stale `~/.nova/bin/nova` reporting a green 28/28
/// while the real compiler crashed: a number that looks like proof precisely because
/// nothing says what it is made of. So it gets a guard rather than a comment
/// (README non-negotiable #2).
///
/// This VERIFIES rather than GENERATES, and the reason is Zig's, not a preference:
/// `@import` cannot escape its module path ("import of file outside module path"), so
/// a generated root in the cache cannot reach `src/`, and a test-artifact-per-file
/// dies the same way the moment `sema/infer.zig` imports `../ast.zig`. The
/// alternatives were writing into the source tree from `build.zig`, or copying `src/`
/// into the cache and having every test failure point at `.zig-cache/o/<hash>/...`
/// forever. A check costs one pasted line and keeps the diagnostics honest.
///
/// FAIL-SAFE: any I/O trouble skips the check. It must never break a build for a
/// reason of its own.
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
        // root.zig IS the list; it cannot be missing from itself.
        if (std.mem.eql(u8, entry.path, "root.zig")) continue;

        const content = src_dir.readFileAlloc(io, entry.path, b.allocator, .limited(8 << 20)) catch continue;
        if (!fileHasTests(content)) continue;

        // `entry.path` is reused by the walker on the next iteration, so this copy is needed
        // anyway; on Windows the walker yields `\` separators while `@import` paths are always
        // `/`, so normalize or every nested file reads as missing.
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

/// A `test "..."` or `test {` at the START of a line. Indented `test` blocks are not
/// a thing at file scope, and requiring column 0 is what keeps the word "test" inside
/// a comment or a string from counting.
fn fileHasTests(src: []const u8) bool {
    if (std.mem.startsWith(u8, src, "test \"") or std.mem.startsWith(u8, src, "test {")) return true;
    return std.mem.indexOf(u8, src, "\ntest \"") != null or std.mem.indexOf(u8, src, "\ntest {") != null;
}

/// Install the compiler and prebuild the C++ runtime into `$HOME/.nova`.
///
/// This runs as part of the DEFAULT `zig build`, and it must: `conformance/run.sh`
/// executes `$HOME/.nova/bin/nova`, not `zig-out/bin/nova`. Without it, run.sh
/// silently tests a stale binary — that reported a green 28/28 while the real
/// compiler crashed on every run.
fn addNovaInstall(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse
        std.debug.panic("$HOME not set; cannot run install steps", .{});

    const bin_dest = b.fmt("{s}/.nova/bin", .{home});
    const std_dest = b.fmt("{s}/.nova/std", .{home});

    // Native Windows host: the sh/rsync/clang++ script below is POSIX-only. Mirror it in PowerShell
    // (present on every Windows) with New-Item/Copy-Item and the LLVM install's clang++/llvm-ar. The
    // macOS-only webview build and the ASAN/TSAN runtimes are skipped here (follow-ons). This branch
    // only runs when `zig build` is invoked ON a Windows host; macOS/Linux take the unchanged path.
    if (builtin.os.tag == .windows) {
        const ps = b.fmt(
            \\$ErrorActionPreference = "Stop"
            \\New-Item -ItemType Directory -Force -Path "{[bin]s}","{[std]s}","{[home]s}/.nova/src/runtime","{[home]s}/.nova/deps","{[home]s}/.nova/lib" | Out-Null
            \\Copy-Item -Force zig-out/bin/nova.exe "{[bin]s}/nova.exe"
            \\Copy-Item -Recurse -Force src/std/* "{[std]s}/"
            \\Copy-Item -Recurse -Force src/runtime/* "{[home]s}/.nova/src/runtime/"
            \\Copy-Item -Recurse -Force deps/* "{[home]s}/.nova/deps/"
            \\Write-Host "Building libnova_runtime.a (Windows; reactor runtime + Win32 syscall shims) ..."
            \\clang++ -std=c++20 -O2 -DNOVA_DROP_ARENA -c src/runtime/runtime.cpp -o "{[home]s}/.nova/lib/nova_runtime.o"
            \\llvm-ar rcs "{[home]s}/.nova/lib/libnova_runtime.a" "{[home]s}/.nova/lib/nova_runtime.o"
            \\Write-Host "Installed compiler to {[bin]s}/nova.exe"
            \\Write-Host "Prebuilt libnova_runtime.a; synced std/runtime/deps to {[home]s}/.nova/"
            \\
        , .{ .bin = bin_dest, .std = std_dest, .home = home });
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
        \\mkdir -p "{[home]s}/.nova/src/runtime"
        \\mkdir -p "{[home]s}/.nova/deps"
        \\mkdir -p "{[home]s}/.nova/lib"
        \\cp zig-out/bin/nova "{[bin]s}/nova"
        \\rsync -a --exclude=".git" src/std/ "{[std]s}/"
        \\rsync -a --exclude=".git" src/runtime/ "{[home]s}/.nova/src/runtime/"
        \\# W1: build the vendored webview static lib once (FFI `extern("webview")`). macOS
        \\# Cocoa/WKWebView backend (Objective-C++). Built BEFORE the deps rsync so the fresh
        \\# .a is synced to ~/.nova/deps this same run. Skipped if already built.
        \\WEBVIEW_LIB="deps/webview/build/libwebview.a"
        \\WV_NEED=0
        \\[ ! -f "$WEBVIEW_LIB" ] && WV_NEED=1
        \\[ deps/webview/webview_impl.cc -nt "$WEBVIEW_LIB" ] && WV_NEED=1
        \\[ deps/webview/webview_nova.cc -nt "$WEBVIEW_LIB" ] && WV_NEED=1
        \\if [ "$WV_NEED" = "1" ] && [ -f deps/webview/webview_impl.cc ]; then
        \\  echo "webview: building static lib ..."
        \\  mkdir -p deps/webview/build
        \\  clang++ -std=c++17 -ObjC++ -O2 -c deps/webview/webview_impl.cc \
        \\      -o deps/webview/build/webview_impl.o 2>/dev/null && \
        \\  clang++ -std=c++17 -ObjC++ -O2 -c deps/webview/webview_nova.cc \
        \\      -o deps/webview/build/webview_nova.o 2>/dev/null && \
        \\  ar rcs "$WEBVIEW_LIB" deps/webview/build/webview_impl.o deps/webview/build/webview_nova.o && \
        \\  echo "webview: built ($WEBVIEW_LIB)" || echo "webview: build failed (GUI FFI unavailable)"
        \\fi
        \\rsync -a --exclude=".git" deps/ "{[home]s}/.nova/deps/"
        \\# Prebuild the C++ runtime ONCE into a static library. Boost.Asio has been retired (M4):
        \\# the async runtime is reactor-native (net/reactorio over os/sys, kqueue/epoll), so nothing
        \\# in src/runtime includes Boost and no Boost include path is needed.
        \\# TLS is pure Nova (M9/M11/M13): crypto/tls + net/tlsmembio + net/tls12bio. wolfSSL is retired,
        \\# so there is no C TLS library to build or link, and no NOVA_HAVE_WOLFSSL define.
        \\echo "Building libnova_runtime.a (no Boost, no wolfSSL; reactor runtime) ..."
        \\# Workstream A: NOVA_DROP_ARENA makes every heap object honestly refcounted
        \\# (no load-bearing thread-local arena). Required for multi-core + clean ARC.
        \\clang++ -std=c++20 -O2 -pthread -DNOVA_DROP_ARENA -c \
        \\    src/runtime/runtime.cpp -o "{[home]s}/.nova/lib/nova_runtime.o"
        \\ar rcs "{[home]s}/.nova/lib/libnova_runtime.a" "{[home]s}/.nova/lib/nova_runtime.o"
        \\# T1: the cross-compilation cache (nova_runtime_<triple>.o, built lazily by `nova build
        \\# --target ...`) is keyed only by triple, so it must be invalidated whenever the runtime
        \\# source changes. Clear it here — triples contain dashes, so this glob spares nova_runtime_asan.o.
        \\rm -f "{[home]s}/.nova/lib/nova_runtime_"*-*.o 2>/dev/null || true
        \\# NOVA_ASAN=1: additionally build an AddressSanitizer runtime. Opt-in because it
        \\# roughly doubles this step; `nova test` links it only when NOVA_ASAN=1 too.
        \\#
        \\# WHY: ARC decides ownership from a rendered type NAME, and when the name is
        \\# unknown it GUESSES — isRefCountedType's catch-all returns true, so "the compiler
        \\# is confused" means "free this memory". The result is a use-after-free whose crash
        \\# lands somewhere unrelated, at a location chosen by the allocator rather than by the
        \\# bug: `nova_release` on a freed object reads the refcount at ptr-8 and looks harmless
        \\# until malloc REUSES the block, at which point it decrements a DIFFERENT object.
        \\# That is how "string heap corruption" stayed misfiled for months. ASAN turns exactly
        \\# that read into a located report AT the release, naming both the free and the use.
        \\# NOTE: the runtime is instrumented; codegen's LLVM IR is not, so a read of freed
        \\# memory from NOVA code is caught only when it flows through a runtime entry point
        \\# (which every retain/release/alloc does). LeakSanitizer is unsupported on Darwin —
        \\# use NOVA_ARC_AUDIT for leaks, which is semantic and better anyway.
        \\if [ "${{NOVA_ASAN:-0}}" = "1" ]; then
        \\  echo "Building libnova_runtime_asan.a (AddressSanitizer) ..."
        \\  clang++ -std=c++20 -O1 -g -fsanitize=address -fno-omit-frame-pointer \
        \\      -pthread -DNOVA_DROP_ARENA -c \
        \\      src/runtime/runtime.cpp -o "{[home]s}/.nova/lib/nova_runtime_asan.o"
        \\  ar rcs "{[home]s}/.nova/lib/libnova_runtime_asan.a" "{[home]s}/.nova/lib/nova_runtime_asan.o"
        \\  echo "ASAN runtime built. Use: NOVA_ASAN=1 nova test <file>"
        \\fi
        \\# NOVA_TSAN=1: additionally build a ThreadSanitizer runtime. This is the gate for the
        \\# self-hosted runtime work (docs/design/self-hosted-runtime.md): the corpus and the ASAN
        \\# gate are effectively single-threaded and CANNOT catch a data race in the multi-reactor
        \\# runtime. TSan instruments the C++ runtime (the scheduler, the CoroState map, the
        \\# reactors) so that a race under NOVA_THREADS>1 becomes a located report naming both
        \\# accesses. Opt-in because it is slow; `nova test` links it only when NOVA_TSAN=1 too.
        \\if [ "${{NOVA_TSAN:-0}}" = "1" ]; then
        \\  echo "Building libnova_runtime_tsan.a (ThreadSanitizer) ..."
        \\  clang++ -std=c++20 -O1 -g -fsanitize=thread -fno-omit-frame-pointer \
        \\      -pthread -DNOVA_DROP_ARENA -c \
        \\      src/runtime/runtime.cpp -o "{[home]s}/.nova/lib/nova_runtime_tsan.o"
        \\  ar rcs "{[home]s}/.nova/lib/libnova_runtime_tsan.a" "{[home]s}/.nova/lib/nova_runtime_tsan.o"
        \\  echo "TSAN runtime built. Use: NOVA_TSAN=1 nova test <file> (with NOVA_THREADS>1)"
        \\fi
        \\echo "Installed compiler to {[bin]s}/nova"
        \\echo "Prebuilt libnova_runtime.a; synced std/runtime/deps to {[home]s}/.nova/"
        \\
    , .{ .bin = bin_dest, .std = std_dest, .home = home });

    const install_cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    // The script copies zig-out/bin/nova, so the artifact must be installed first.
    const install_exe = b.addInstallArtifact(exe, .{});
    install_cmd.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&install_cmd.step);
}

/// `zig build archive` — package one relocatable bundle of the whole toolchain for THIS host:
/// the compiler (`nova`), the language server (`nls`, built fresh from the sibling repo), the
/// stdlib, the prebuilt runtime static lib, and the runtime/deps sources `nova build --target`
/// needs. The install step already assembles all of these under ~/.nova, so the archive stages
/// FROM there into a clean tree (no ASAN/TSAN variants, no cross-compile cache) and tars it.
///
/// Host-only by design: the bundle is named for the build host's os/arch and contains that host's
/// binaries. It carries a tiny `install` script that copies the tree into the user's ~/.nova, so
/// the archive is self-installing, plus a VERSION file, and a SHA256 checksum is written alongside
/// the archive so a release can be verified. The version comes from the NOVA_VERSION env var
/// (set by the release workflow from the git tag); it defaults to "dev" for local builds.
/// Output: `zig-out/nova-<version>-<os>-<arch>.tar.gz` (+ `.sha256`; `.zip` on Windows).
fn addNovaArchive(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const os_name = @tagName(builtin.target.os.tag); // macos | linux | windows
    const arch_name = @tagName(builtin.target.cpu.arch); // aarch64 | x86_64 | ...
    const version = b.graph.environ_map.get("NOVA_VERSION") orelse "dev";
    const bundle = b.fmt("nova-{s}-{s}-{s}", .{ version, os_name, arch_name });

    const archive_step = b.step("archive", "Package a self-installing, versioned, checksummed toolchain bundle (nova + nls + stdlib) for this host");

    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse
        std.debug.panic("$HOME not set; cannot run archive step", .{});

    if (builtin.os.tag == .windows) {
        const ps = b.fmt(
            \\$ErrorActionPreference = "Stop"
            \\$stage = "zig-out/dist/{[bundle]s}"
            \\if (Test-Path $stage) {{ Remove-Item -Recurse -Force $stage }}
            \\New-Item -ItemType Directory -Force -Path "$stage/bin","$stage/lib" | Out-Null
            \\Copy-Item -Force "{[home]s}/.nova/bin/nova.exe" "$stage/bin/nova.exe"
            \\# nls: build from the sibling repo unless skipped (NOVA_ARCHIVE_SKIP_NLS=1), matching the
            \\# Unix path -- used where the private nls repo is not checked out (e.g. CI).
            \\if ($env:NOVA_ARCHIVE_SKIP_NLS -eq "1") {{ Write-Host "archive: NOVA_ARCHIVE_SKIP_NLS=1 -- bundling without nls" }}
            \\else {{ Push-Location ../nls; zig build -Dnova-src=../lang/src/root.zig; Pop-Location; Copy-Item -Force "{[home]s}/.nova/bin/nls.exe" "$stage/bin/nls.exe" }}
            \\# nova.exe dynamically links LLVM-C.dll on Windows; bundle it next to the exe so the
            \\# archive is self-contained (the loader finds a DLL in the exe's own directory).
            \\if ($env:NOVA_LLVM_PREFIX) {{ Copy-Item -Force "$env:NOVA_LLVM_PREFIX/bin/LLVM-C.dll" "$stage/bin/" -ErrorAction SilentlyContinue }}
            \\Copy-Item -Force "{[home]s}/.nova/lib/libnova_runtime.a" "$stage/lib/"
            \\Copy-Item -Recurse -Force "{[home]s}/.nova/std" "$stage/std"
            \\# NOTE: src/runtime + deps are NOT bundled -- the prebuilt libnova_runtime.a covers
            \\# host-target compilation. They are only needed to cross-compile the runtime to OTHER
            \\# targets (nova build --target) or to build webview FFI apps; add them back if the
            \\# shipped toolchain must do that.
            \\Set-Content "$stage/VERSION" "{[version]s}"
            \\# self-installer: copy the tree into the user's ~/.nova
            \\Set-Content "$stage/install.ps1" '$d="$env:USERPROFILE/.nova"; New-Item -ItemType Directory -Force -Path "$d/bin","$d/lib" | Out-Null; Copy-Item -Recurse -Force ./* "$d/"; Write-Host "Installed Nova to $d"'
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
        cmd.step.dependOn(b.getInstallStep()); // ~/.nova must be populated first
        archive_step.dependOn(&cmd.step);
        return;
    }

    const script = b.fmt(
        \\set -e
        \\STAGE="zig-out/dist/{[bundle]s}"
        \\rm -rf "$STAGE"
        \\mkdir -p "$STAGE/bin" "$STAGE/lib"
        \\cp "{[home]s}/.nova/bin/nova" "$STAGE/bin/nova"
        \\# nls: build fresh from the sibling compiler repo (installs to ~/.nova/bin/nls). It links
        \\# LLVM the same way the compiler does; where that toolchain is not set up (e.g. a Linux CI
        \\# runner without system LLVM), set NOVA_ARCHIVE_SKIP_NLS=1 to ship a nova+stdlib bundle
        \\# without the language server rather than fail the release.
        \\if [ "${{NOVA_ARCHIVE_SKIP_NLS:-0}}" = "1" ]; then
        \\  echo "archive: NOVA_ARCHIVE_SKIP_NLS=1 -- bundling without nls (language server)"
        \\else
        \\  ( cd ../nls && zig build -Dnova-src=../lang/src/root.zig )
        \\  cp "{[home]s}/.nova/bin/nls" "$STAGE/bin/nls"
        \\fi
        \\cp "{[home]s}/.nova/lib/libnova_runtime.a" "$STAGE/lib/"
        \\rsync -a "{[home]s}/.nova/std/" "$STAGE/std/"
        \\# NOTE: src/runtime + deps are NOT bundled -- the prebuilt libnova_runtime.a covers host-target
        \\# compilation. They are only needed to cross-compile the runtime to OTHER targets
        \\# (nova build --target) or to build webview FFI apps; add them back if that is required.
        \\printf '%s\n' "{[version]s}" > "$STAGE/VERSION"
        \\# self-installer: copy the tree into the user's ~/.nova
        \\cat > "$STAGE/install.sh" <<'INSTALL'
        \\#!/bin/sh
        \\set -e
        \\D="$HOME/.nova"
        \\mkdir -p "$D/bin" "$D/lib"
        \\cp -R ./bin/* "$D/bin/"
        \\cp -R ./lib/* "$D/lib/"
        \\cp -R ./std "$D/"
        \\echo "Installed Nova to $D (add $D/bin to PATH)"
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
    cmd.step.dependOn(b.getInstallStep()); // ~/.nova must be populated first
    _ = exe;
    archive_step.dependOn(&cmd.step);
}
