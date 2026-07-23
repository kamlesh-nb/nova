const std = @import("std");

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

// Wire LLVM into `m` (the `llvm` binding module). The vendored deps/llvm-zig
// build.zig deliberately does NO LLVM linking — it happens here so this repo
// owns the toolchain paths and the dynamic/static choice.
fn configureLlvmLink(b: *std.Build, m: *std.Build.Module, static: bool) void {
    const lib_dir = b.pathJoin(&.{ llvmPrefix(b, static), "lib" });
    m.addLibraryPath(.{ .cwd_relative = lib_dir });

    if (!static) {
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
    const llvm_libs = @embedFile("deps/llvm-zig/llvm-libs.txt");
    var lines = std.mem.tokenizeScalar(u8, llvm_libs, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const comp = std.mem.trim(u8, raw, " \r\t");
        if (comp.len == 0) continue;
        m.linkSystemLibrary(comp, .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        count += 1;
    }
    if (count == 0) std.debug.panic("configureLlvmLink: empty llvm-libs.txt", .{});

    // zstd: llvm-config bakes in a Homebrew path; use the vendored static copy.
    m.addLibraryPath(b.path("deps/zstd"));
    m.linkSystemLibrary("zstd", .{ .preferred_link_mode = .static, .use_pkg_config = .no });

    // Other externals LLVM references — the macOS SDK provides these dynamically.
    m.linkSystemLibrary("z", .{});
    m.linkSystemLibrary("xml2", .{});

    // LLVM static archives are C++ objects → need the C++ runtime.
    m.link_libcpp = true;
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
    configureLlvmLink(b, llvm_mod, static_llvm);

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
        \\# Prebuild the C++ runtime ONCE into a static library (compile the heavy
        \\# Boost.Fiber headers once here; `nova build` then just links this .a).
        \\# BOOST_PREFIX is configurable per platform (macOS Homebrew default).
        \\BOOST_PREFIX="${{BOOST_PREFIX:-/opt/homebrew}}"
        \\# M3-D-5: build the vendored wolfSSL static lib once (TLS via wolfSSL). If
        \\# libwolfssl.a is already built, skip. Enables real TLS with verify_peer.
        \\WOLF_LIB="deps/wolfssl/build/libwolfssl.a"
        \\WOLF_FLAGS=""
        \\if [ -f "$WOLF_LIB" ]; then
        \\  WOLF_FLAGS="-DNOVA_HAVE_WOLFSSL -Ideps/wolfssl -Ideps/wolfssl/build"
        \\  echo "wolfSSL: using $WOLF_LIB (TLS enabled)"
        \\elif command -v cmake >/dev/null 2>&1; then
        \\  echo "wolfSSL: building static lib via cmake ..."
        \\  cmake -S deps/wolfssl -B deps/wolfssl/build -DCMAKE_BUILD_TYPE=Release \
        \\    -DBUILD_SHARED_LIBS=OFF -DWOLFSSL_TLS13=yes -DWOLFSSL_EXAMPLES=no \
        \\    -DWOLFSSL_CRYPT_TESTS=no -DWOLFSSL_OPENSSLEXTRA=no \
        \\    -DWOLFSSL_SECURE_RENEGOTIATION=yes >/dev/null 2>&1 && \
        \\  cmake --build deps/wolfssl/build --parallel 8 >/dev/null 2>&1 && \
        \\  WOLF_FLAGS="-DNOVA_HAVE_WOLFSSL -Ideps/wolfssl -Ideps/wolfssl/build" && \
        \\  echo "wolfSSL: built (TLS enabled)" || echo "wolfSSL: build failed (TLS stubbed)"
        \\else
        \\  echo "wolfSSL: no prebuilt lib and no cmake (TLS stubbed)"
        \\fi
        \\echo "Building libnova_runtime.a (Boost prefix: $BOOST_PREFIX) ..."
        \\# Workstream A: NOVA_DROP_ARENA makes every heap object honestly refcounted
        \\# (no load-bearing thread-local arena). Required for multi-core + clean ARC.
        \\clang++ -std=c++20 -O2 -pthread -DNOVA_DROP_ARENA $WOLF_FLAGS -c -I"$BOOST_PREFIX/include" \
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
        \\      -pthread -DNOVA_DROP_ARENA $WOLF_FLAGS -c -I"$BOOST_PREFIX/include" \
        \\      src/runtime/runtime.cpp -o "{[home]s}/.nova/lib/nova_runtime_asan.o"
        \\  ar rcs "{[home]s}/.nova/lib/libnova_runtime_asan.a" "{[home]s}/.nova/lib/nova_runtime_asan.o"
        \\  echo "ASAN runtime built. Use: NOVA_ASAN=1 nova test <file>"
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
