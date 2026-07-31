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
// owns the toolchain paths and the dynamic/static choice.
// `llvm_dep`, when non-null, is the fetched per-platform LLVM mirror package (build.zig.zon
// `llvm_{linux_aarch64,linux_x86_64,macos_arm64}`); its `lib/` supplies the archives (+ on Linux the
// libstdc++.so/libgcc_s.so). When null (NOVA_LLVM_PREFIX override, or a non-static build) the paths
// come from `llvmPrefix`.
fn configureLlvmLink(b: *std.Build, m: *std.Build.Module, static: bool, os_tag: std.Target.Os.Tag, llvm_dep: ?*std.Build.Dependency) void {
    if (llvm_dep) |dep| {
        m.addLibraryPath(dep.path("lib"));
    } else {
        const lib_dir = b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
        m.addLibraryPath(.{ .cwd_relative = lib_dir });
    }

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
    // cycles). The list is committed (reproducible, no configure-time fs walk).
    // Regenerate for a different prefix with:
    //   ls <prefix>/lib/libLLVM*.a | xargs -n1 basename | sed 's/^lib//;s/\.a$//' \
    //     | sort > deps/llvm-zig/llvm-libs.txt
    const llvm_libs = if (os_tag == .linux) llvm_libs_linux else llvm_libs_macos;
    var lines = std.mem.tokenizeScalar(u8, llvm_libs, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const comp = std.mem.trim(u8, raw, " \r\t");
        if (comp.len == 0) continue;
        m.linkSystemLibrary(comp, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        count += 1;
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
        // must be *-linux-gnu. The .so lives in the mirror prefix lib dir alongside libLLVM*.a.
        if (llvm_dep) |dep| {
            m.addObjectFile(dep.path("lib/libstdc++.so"));
            m.addObjectFile(dep.path("lib/libgcc_s.so")); // libgcc_s unwinder (_Unwind_*)
        } else {
            m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ llvmPrefix(b, static), "lib", "libstdc++.so" }) });
            m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ llvmPrefix(b, static), "lib", "libgcc_s.so" }) });
        }
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

pub fn build(b: *std.Build) void {
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
    // For a STATIC build, fetch the LLVM libraries from the self-hosted mirror (lazy — only when this
    // branch runs, only the target's tree). NOVA_LLVM_PREFIX overrides with a local tree (skips the
    // fetch). `lazyDependency` returns null on the first pass while it downloads, then zig re-runs
    // build() with it available.
    var static_llvm_dep: ?*std.Build.Dependency = null;
    if (static_llvm and b.graph.environ_map.get("NOVA_LLVM_PREFIX") == null) {
        const os_tag = target.result.os.tag;
        const arch = target.result.cpu.arch;
        if (os_tag == .linux and arch == .aarch64) {
            static_llvm_dep = b.lazyDependency("llvm_linux_aarch64", .{});
        } else if (os_tag == .linux and arch == .x86_64) {
            static_llvm_dep = b.lazyDependency("llvm_linux_x86_64", .{});
        } else if (os_tag == .macos and arch == .aarch64) {
            static_llvm_dep = b.lazyDependency("llvm_macos_arm64", .{});
        }
    }
    configureLlvmLink(b, llvm_mod, static_llvm, target.result.os.tag, static_llvm_dep);

    // P5 #20: link LLD into nova so it links its output executables in-process
    // (no clang/ld shell-out). Requires -Dstatic-llvm (needs the native liblld*.a
    // + libLLVM from the same LLVM 22 tree). Exposed to the code via build_options.
    const inprocess_lld = b.option(bool, "inprocess-lld", "Link LLD into nova for in-process linking (requires -Dstatic-llvm)") orelse false;
    if (inprocess_lld and !static_llvm) @panic("-Dinprocess-lld requires -Dstatic-llvm");
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "inprocess_lld", inprocess_lld);
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

        const needle = std.fmt.allocPrint(b.allocator, "@import(\"{s}\")", .{entry.path}) catch continue;
        if (std.mem.indexOf(u8, root_src, needle) != null) continue;

        // `entry.path` is reused by the walker on the next iteration.
        const owned = b.allocator.dupe(u8, entry.path) catch continue;
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
