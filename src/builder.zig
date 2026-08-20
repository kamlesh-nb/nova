// builder.zig — `nova build` / `nova <file>` — orchestrate the compile+link pipeline.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const ast = @import("frontend/ast.zig");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser.zig");
const formatter = @import("frontend/formatter.zig");
const type_checker = @import("frontend/type_checker.zig");
const templates = @import("templates.zig");
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
const codegen_arc = @import("backend/codegen/arc.zig");
const sema_shadow = @import("frontend/sema/shadow.zig");
const sema_escape = @import("frontend/sema/escape.zig");
const sema_ownership = @import("frontend/sema/ownership.zig");
const sema_ossa_lower = @import("frontend/sema/ossa/lower.zig");
const sema_alpha = @import("frontend/sema/alpha.zig");
const sema_ids = @import("frontend/sema/ids.zig");
const sema_mod = @import("frontend/sema/sema.zig");
const sema_mono = @import("frontend/sema/mono.zig");
const pipeline = @import("pipeline.zig");
const packages = @import("packages.zig");

// User-facing build options, set from CLI flags in cmdBuild (see pipeline.hasFlag). Builder-level knobs
// live here; the codegen-deep ones (--split-objects/--prune/--emit-llvm/--mem-stats) live on
// llvm_codegen.flags. Replaces the former NOVA_ASAN / NOVA_KEEP_OBJ / NOVA_DUMP_MERGED env vars.
var want_asan: bool = false;
var want_keep_obj: bool = false;
var want_dump_merged: bool = false;


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
    const tinfo = pipeline.deriveTargetInfo(target, target_triple_opt);

    // AddressSanitizer is OPT-IN via --asan (never for wasm). It is a memory-bug testing tool, not a
    // debug-build default: defaulting it on made debug builds depend on the linker's clang matching the
    // exact ASAN runtime version that built libnovacore_asan.a -- when they differ (e.g. a VS Code task
    // shell finds Apple clang 17 while the runtime was built with Homebrew clang 21) the link fails with
    // `__asan_version_mismatch_check_v*` undefined. Off by default means plain debug builds link with any
    // clang and run faster; the conformance --asan gate passes --asan explicitly.
    const asan = !is_wasm and want_asan;
    // Opt-in: also instrument NOVA-GENERATED code with ASAN (not only the runtime), for provenance on a
    // Nova-code UAF. Requires the runtime ASAN link (so it implies `asan`); niche dev knob, stays env.
    codegen_arc.asan_codegen_enabled = asan and (init.environ_map.get("NOVA_ASAN_CODEGEN") != null);

    pipeline.loadProgram(allocator, init, "src/std/collections/string_builder.nova", visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder standard library: {any}\n", .{err});
    };

    try pipeline.loadProgram(allocator, init, file_path, visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo);

    if (want_dump_merged) {
        _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = merged.items, .sub_path = "merged.nova", .flags = .{} }) catch |err| {
            std.debug.print("Failed to write merged.nova: {s}\n", .{@errorName(err)});
        };
    }

    var src_hash: u64 = 0;
    if (build_mode) {
        src_hash = pipeline.sourcesHash(&file_sources, is_release, asan, pipeline.linkLibsStamp(allocator, init));
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
    try pipeline.expandTraitDefaults(allocator, &declarations); // cross-module trait default methods
    try pipeline.generateControllerRoutes(allocator, &declarations);
    try pipeline.generateSerdeBinders(allocator, &declarations, is_wasm);
    try pipeline.generateMediatorDispatch(allocator, &declarations, is_wasm);
    try pipeline.generateRuntimeMediator(allocator, &declarations, is_wasm);
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
    sema_shadow.tid_census = init.environ_map.get("NOVA_TID_CENSUS") != null;
    // M-5 (memory-management-refinements.md): borrowed-field ARC elision is ON by default
    // (verified: corpus + ASAN clean, differential ARC audit identical off vs on). Set
    // NOVA_ARC_ELIDE_OFF to disable it for debugging a suspected elision regression.
    codegen_arc.elide_enabled = init.environ_map.get("NOVA_ARC_ELIDE_OFF") == null;
    codegen_arc.arc_census = init.environ_map.get("NOVA_ARC_CENSUS") != null;
    pipeline.configureValueStructs(allocator, init.environ_map);
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
            @import("frontend/sema/inst_disp.zig").run(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir, ids);
            @import("frontend/sema/inst_disp.zig").runFreeFns(allocator, &owned_sema.store, &owned_sema.ir, program);
            @import("frontend/sema/inst_disp.zig").runMethods(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir);
        }
    }

    // Gap 8: demand-driven monomorphization -- "compile only what the app uses". Computes the set of
    // function/method decls reachable from main() (call graph + vtable/serde/closure roots) and gates
    // codegen emission on it, so uncalled generic methods (List/RawBuffer's 93% dead surface) and unreached
    // subsystems (crypto in a plaintext app) are never emitted. Default ON for build (huge memory+speed win);
    // NOVA_REACH_OFF disables. See docs/design/demand-driven-mono.md.
    {
        const reach = @import("frontend/sema/reach.zig");
        const shadow = init.environ_map.get("NOVA_REACH_SHADOW") != null;
        const gate = init.environ_map.get("NOVA_REACH_OFF") == null;
        if (shadow or gate) {
            var rr = reach.compute(allocator, &owned_sema.tab, &owned_sema.ir, program, false) catch reach.Result{};
            defer rr.deinit(allocator);
            if (shadow) reach.report(&rr, &owned_sema.tab);
            if (gate) {
                reach.publish(allocator, &rr, &owned_sema.tab);
                reach.gate_on = true;
            }
        }
    }

    // P7 Stage 1: report-only escape gauge (no codegen effect). See docs/design/p7-sound-arena.md.
    sema_escape.report_enabled = init.environ_map.get("NOVA_ESCAPE_REPORT") != null;
    if (sema_escape.report_enabled) _ = sema_escape.analyze(allocator, &owned_sema.store, &owned_sema.ir, &program);

    // OSSA-lite Track V: opt-in ownership verifier. See docs/design/ossa-lite-tasks.md.
    //   NOVA_OWN_VERIFY=1        -> run, report (does not fail the build).
    //   NOVA_OWN_VERIFY=hard     -> also fail the build on an imbalance.
    // Drives BOTH the sema-level owned-local coverage report AND the real codegen-level
    // ARC release-balance verifier (V4', set below and run inside declarations.zig).
    if (init.environ_map.get("NOVA_OWN_VERIFY")) |v| {
        const hard = std.mem.eql(u8, v, "hard");
        // Sound use-after-move gate (owned let-locals).
        sema_ownership.runVerify(allocator, &owned_sema.store, &owned_sema.ir, &program, hard);
        // The V4' codegen balance verifier is NON-PATH-SENSITIVE (it counts total acquires vs total
        // releases, so a value stored in two exclusive branches and released once at the merge shows a
        // spurious imbalance). It is SUPERSEDED by the path-sensitive OSSA verifier below and kept only as
        // an informational report -- it NEVER fails the build (verified false-positive on serde/DI/error-
        // union across the corpus while ARC-audit is clean).
        codegen_arc.balance_verify = true;
        codegen_arc.balance_hard = false;
    }

    // Slice 6: DEFAULT-ON, fail-closed ownership enforcement. The sound, path-sensitive OSSA verifier runs
    // on EVERY build and REJECTS a proven ARC release imbalance (leak / double-free) in a covered function,
    // exactly like a type error. 0 false positives across the corpus (398/398); it DEFERS what it cannot
    // prove rather than accuse. Escape hatch + report:
    //   NOVA_OSSA=off  -> disable the check entirely.
    //   NOVA_OSSA=1    -> report-only (print the coverage census, never fail).
    //   NOVA_OSSA=hard -> verbose census AND fail.
    //   (unset)        -> enforce quietly (fail on a proven imbalance, no census noise).
    {
        const ossa = init.environ_map.get("NOVA_OSSA");
        const disabled = ossa != null and std.mem.eql(u8, ossa.?, "off");
        if (!disabled) {
            const report_only = ossa != null and std.mem.eql(u8, ossa.?, "1");
            const verbose = ossa != null; // any explicit NOVA_OSSA=... prints the census
            sema_ossa_lower.reportQuiet(allocator, &owned_sema.store, &owned_sema.ir, &program, !report_only, !verbose);
        }
    }

    // (HIR/MIR/LIR LLVM-emit optimiser scrapped 2026-08-16; see docs/design/sil-arc-optimiser-direction.md.)

    if (std.mem.eql(u8, target, "--wasm")) {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
        defer allocator.free(obj_path);
        try llvm_codegen.compile(allocator, program, true, is_release, target_triple_opt, obj_path, false, false, null, null, init.io);

        if (build_options.inprocess_lld) {
            try pipeline.linkWasmInProcess(allocator, obj_path, output_path);
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

        // A project build always produces linkable object(s) (the objs path); single-file compiles emit
        // one object directly. --split-objects (llvm_codegen.flags.split_per_file) then chooses per-file
        // vs one combined object INSIDE the objs path.
        const t6_split = build_mode;
        var split_objs = std.ArrayList([]const u8).empty;
        defer {
            for (split_objs.items) |o| {
                if (!want_keep_obj and !build_mode) Io.Dir.deleteFile(.cwd(), init.io, o) catch {};
                allocator.free(o);
            }
            split_objs.deinit(allocator);
        }
        try llvm_codegen.compile(allocator, program, false, is_release, target_triple_opt, obj_path, false, t6_split, if (t6_split) &split_objs else null, if (build_mode) build_obj_dir else null, init.io);
        const link_objs: []const []const u8 = if (split_objs.items.len > 0) split_objs.items else &[_][]const u8{obj_path};
        sema_shadow.reportResolution();
        sema_shadow.reportDiff();
    sema_shadow.reportTypeIdDiff();
    sema_shadow.tidCensusReport();
    sema_shadow.reportF45();
    sema_mono.dumpMethodInsts();

    if (llvm_codegen.flags.mem_stats) {
        const store_types: usize = if (sema_shadow.live_sema) |sm| sm.store.count() else 0;
        const interned_names: usize = if (sema_shadow.live_sema) |sm| sm.names.count() else 0;
        std.debug.print(
            \\=== mem-stats ===
            \\  program.declarations : {d}
            \\  method_insts         : {d}
            \\  free_fn_insts        : {d}
            \\  forced_struct_insts  : {d}
            \\  store types          : {d}
            \\  interned names       : {d}
            \\  renderLegacy calls   : {d}  (cache hits {d})
            \\  render allocs        : {d}  bytes {d}
            \\
        , .{
            program.declarations.len,
            sema_mono.method_insts.items.len,
            sema_mono.free_fn_insts.items.len,
            sema_mono.forced_struct_insts.items.len,
            store_types,
            interned_names,
            sema_shadow.render_calls,
            sema_shadow.render_cache_hits,
            sema_shadow.render_allocs,
            sema_shadow.render_bytes,
        });
    }

        var clang_args = std.ArrayList([]const u8).empty;
        defer clang_args.deinit(allocator);

        try clang_args.append(allocator, "clang++");
        try clang_args.append(allocator, "-std=c++20");

        try clang_args.append(allocator, pipeline.dead_strip_flag);
        try clang_args.appendSlice(allocator, pipeline.pie_flags);
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

        const ffi_libs = try pipeline.collectFfiLibs(allocator, program);

        if (target_triple_opt) |triple| {
            if (try pipeline.crossLinkViaZig(allocator, init.environ_map, init.io, triple, link_objs, output_path, shared_nova, is_release)) {
                if (!want_keep_obj and !build_mode)
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
            try pipeline.linkNativeInProcessMacho(allocator, init.environ_map, init.io, link_objs, output_path, shared_nova, ffi_libs);

            if (!want_keep_obj and !build_mode)
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

        try pipeline.appendRuntimeLink(&clang_args, allocator, shared_nova, if (asan) "novacore_asan" else "novacore");
        try pipeline.appendWolfsslLink(&clang_args, allocator, shared_nova, init.io);
        for (ffi_libs) |lib| {
            try pipeline.appendFfiLib(&clang_args, allocator, shared_nova, init.io, lib);
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

        if (!want_keep_obj and !build_mode) {
            Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};
        } else if (!build_mode) {
            std.debug.print("Kept object file {s} (--keep-obj)\n", .{obj_path});
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

// cmdBuild: the `nova build ...` and bare `nova <file> ...` path (arg parsing + watch + compile).
// Extracted verbatim from the tail of the former mainInner; cli.run dispatches here for both forms.
pub fn cmdBuild(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    // Auto-fetch: clone any project.json dependency missing from the package cache before compiling, so
    // a freshly cloned app builds without a manual `nova get`. Silent when there is no project.json.
    try packages.ensureDependencies(allocator, init);

    // User-facing build options as CLI flags (were NOVA_* env vars). Parsed once here; builder-level
    // knobs go to module globals, codegen-deep ones to llvm_codegen.flags, before any compile runs.
    want_asan = pipeline.hasFlag(args, "--asan");
    want_keep_obj = pipeline.hasFlag(args, "--keep-obj");
    want_dump_merged = pipeline.hasFlag(args, "--dump-merged");
    llvm_codegen.flags.split_per_file = pipeline.hasFlag(args, "--split-objects");
    llvm_codegen.flags.prune = pipeline.hasFlag(args, "--prune");
    llvm_codegen.flags.dump_ir = pipeline.hasFlag(args, "--emit-llvm");
    llvm_codegen.flags.mem_stats = pipeline.hasFlag(args, "--mem-stats");

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
            if (std.json.parseFromSlice(pipeline.ProjectJson, allocator, pj, .{ .ignore_unknown_fields = true })) |parsed| {
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
        } else if (std.mem.eql(u8, ct, "windows-arm64")) {
            target_triple_opt = "aarch64-pc-windows-gnu";
        } else {
            std.debug.print("Unsupported target switch: {s}\n", .{ct});
            return error.UnsupportedTarget;
        }
    }

    if (output_path.len == 0) {
        const base_name = try pipeline.basenameWithoutExtension(file_path, allocator);
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
            // Back the per-iteration arena with the command allocator, never page_allocator (which never
            // returns pages). The arena is deinit'd at the end of each watch iteration below.
            var pass_arena = std.heap.ArenaAllocator.init(allocator);
            const pass_allocator = pass_arena.allocator();

            var visited = std.StringHashMap(void).init(pass_allocator);

            compileProgram(pass_allocator, init, file_path, target, output_path, is_release, target_triple_opt, &visited, build_mode, build_obj_dir, build_hash_path) catch |err| {
                std.debug.print("Compilation failed: {any}\n", .{err});
            };

            var file_iter = visited.keyIterator();
            while (file_iter.next()) |file| {
                if (!mtimes.contains(file.*)) {
                    if (pipeline.getFileMtime(init.io, file.*)) |mt| {
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
                    if (pipeline.getFileMtime(init.io, file_path)) |mt| {
                        const dup_key = try allocator.dupe(u8, file_path);
                        try mtimes.put(dup_key, mt);
                    } else |_| {}
                }

                var iter = mtimes.iterator();
                while (iter.next()) |entry| {
                    const file = entry.key_ptr.*;
                    const old_mt = entry.value_ptr.*;
                    if (pipeline.getFileMtime(init.io, file)) |new_mt| {
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

