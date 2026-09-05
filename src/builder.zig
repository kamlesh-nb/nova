//! The `kyte build` / `kyte <file>` command driver: turn Kyte source into a
//! linked native or WASM binary.
//!
//! This file is the top of the compile pipeline the CLI reaches when the user
//! asks to produce an executable (as opposed to `kyte test`, `kyte fmt`, etc.).
//! It does two jobs and nothing else: [`cmdBuild`] parses the command line and
//! computes every path/flag decision, and [`compileProgram`] runs the actual
//! front-to-back compile for one program. The heavy lifting all lives elsewhere,
//! this file is the conductor: it loads and merges the source graph, drives the
//! semantic passes in the one order they must run, hands the checked program to
//! the LLVM backend, and then spawns (or in-process invokes) the linker.
//!
//! Two shapes of invocation flow through here, and the difference is threaded
//! everywhere as `build_mode`:
//!
//!   * Single-file mode (`kyte app.ky ...`): compile one file to a binary,
//!     the object file is a throwaway next to the output.
//!   * Project mode (`kyte build ...`): read `project.json` for the name, emit
//!     into `build/<profile>/{obj,bin}`, keep the per-file `.o` split for
//!     incremental linking, and stamp a content hash so an unchanged tree is a
//!     no-op rebuild. This is the T6 per-file-split path.
//!
//! Key design points worth knowing before editing:
//!   * The three `want_*` file-level vars are process-global switches set once
//!     by [`cmdBuild`] from CLI flags and read deep inside [`compileProgram`];
//!     they are here rather than threaded as parameters because they are pure
//!     cross-cutting toggles. Codegen/sema toggles instead ride on environment
//!     variables read straight out of `init.environ_map` (NOT `getenv`, which
//!     does not work in this Zig), so an operator can flip a diagnostic without
//!     a rebuild.
//!   * The semantic passes in [`compileProgram`] have a MANDATORY order: alpha
//!     rename, id assignment, type check, the shadow/typed-IR sema, then
//!     monomorphization worklist, reachability, escape/ownership/OSSA verifiers,
//!     and only then codegen. Reordering them breaks correctness, not just
//!     diagnostics.
//!   * Linking has several fast paths (in-process LLD for macOS and WASM, cross
//!     link via bundled `zig cc`) that fall back to spawning `clang++`. The
//!     object file is deleted afterwards unless `--keep-obj` or project mode
//!     asks to retain it.

const std = @import("std");
/// Compile-time host info, used only to gate the macOS-only in-process Mach-O
/// linker fast path (`builtin.target.os.tag == .macos`).
const builtin = @import("builtin");
/// Shorthand for the `std.Io` namespace, this Zig's explicit-IO filesystem and
/// process API (`Io.Dir.readFileAlloc`, `Io.Dir.writeFile`, etc.).
const Io = std.Io;
/// Build-time options injected by `build.zig`; here it supplies `inprocess_lld`,
/// which selects the linked-in LLD path over spawning an external linker.
const build_options = @import("build_options");
/// AST types (`ast.Program`, `ast.Declaration`, `ast.Span`) used to assemble the
/// merged program before it is checked and lowered.
const ast = @import("frontend/ast.zig");
/// The lexer module. Imported for module-graph completeness, not called directly
/// from this file (parsing here goes through [`parser`] and [`pipeline`]).
const lexer = @import("frontend/lexer.zig");
/// The Kyte parser, used directly only to parse the injected WASM/native helper
/// snippet (`__log_i32` and friends) into extra declarations.
const parser = @import("frontend/parser.zig");
/// The source formatter. Imported for module-graph completeness; `kyte build`
/// does not format.
const formatter = @import("frontend/formatter.zig");
/// The classic type checker pass ([`type_checker.TypeChecker`]), run after alpha
/// and id assignment and before the shadow/typed-IR sema.
const type_checker = @import("frontend/type_checker.zig");
/// Project scaffolding templates. Imported for module-graph completeness; not
/// used on the build path.
const templates = @import("templates.zig");
/// The LLVM backend entry point ([`llvm_codegen.compile`]) plus its global
/// `flags` struct that the CLI toggles (`--emit-llvm`, `--mem-stats`, ...).
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
/// The ARC codegen module, reached here only to flip its global switches
/// (`asan_codegen_enabled`, `elide_enabled`, `balance_verify`, ...) from env.
const codegen_arc = @import("backend/codegen/arc.zig");
/// The shadow / typed-IR semantic pass and its many report toggles; `run` is the
/// authoritative sema, the rest are diagnostics gated by `KYTE_*` env vars.
const sema_shadow = @import("frontend/sema/shadow.zig");
/// Escape analysis (report-only), enabled by `KYTE_ESCAPE_REPORT`.
const sema_escape = @import("frontend/sema/escape.zig");
/// The ownership balance verifier, enabled by `KYTE_OWN_VERIFY` (soft or hard).
const sema_ownership = @import("frontend/sema/ownership.zig");
/// OSSA lowering plus its ARC-balance self-verifier, default-on and fail-closed
/// unless `KYTE_OSSA=off`.
const sema_ossa_lower = @import("frontend/sema/ossa/lower.zig");
/// The alpha-renaming pass, the FIRST sema step so later passes see unique names.
const sema_alpha = @import("frontend/sema/alpha.zig");
/// The node-id assigner ([`sema_ids.Assigner`]), run right after alpha to give
/// every AST node a stable id the later passes key on.
const sema_ids = @import("frontend/sema/ids.zig");
/// The owning sema container ([`sema_mod.Sema`]) that holds the type store, name
/// table, and typed IR the backend consumes.
const sema_mod = @import("frontend/sema/sema.zig");
/// Monomorphization: the [`sema_mono.Worklist`] that computes live generic
/// instantiations plus the census/report globals the backend and diagnostics use.
const sema_mono = @import("frontend/sema/mono.zig");
/// The shared compile pipeline helpers: source loading/merging, target-info
/// derivation, codegen transforms (trait defaults, serde binders, mediator), and
/// all the link-command construction. Most of this file's real work is delegated
/// here.
const pipeline = @import("pipeline.zig");
/// Package/dependency management, used to fetch declared dependencies before a
/// build starts ([`packages.ensureDependencies`]).
const packages = @import("packages.zig");

/// Process-global: emit an AddressSanitizer build (`-fsanitize=address`, links
/// the `_asan` runtime). Set once from the `--asan` flag; ignored for WASM.
var want_asan: bool = false;
/// Process-global: keep the intermediate `.o` file instead of deleting it after
/// a successful single-file link. Set from `--keep-obj`.
var want_keep_obj: bool = false;
/// Process-global: write the merged pre-compile source to `merged.ky` for
/// inspection. Set from `--dump-merged`.
var want_dump_merged: bool = false;


/// Compile one Kyte program end to end: load and merge its source graph, run the
/// full semantic pipeline, generate LLVM code, and link the object into a native
/// or WASM binary.
///
/// This is the core of a build. The steps, in the order they MUST happen:
///   1. Recursively load the entry file and its imports (plus the always-on
///      `string_builder` stdlib prelude) into one merged buffer and a flat
///      declaration list, via [`pipeline.loadProgram`].
///   2. In project mode, short-circuit if the content hash matches the previous
///      build and the output binary still exists ("up to date, nothing to
///      rebuild").
///   3. Inject the WASM/native `__log_*`/`__read_string` helper declarations.
///   4. Run the codegen-side AST transforms (trait defaults, controller routes,
///      serde binders, mediator dispatch).
///   5. Run the semantic passes in fixed order: alpha, id assignment, type
///      check, shadow sema, mono worklist + instantiation dispatch, reachability
///      gate, then the report-only escape/ownership/OSSA verifiers.
///   6. Codegen to an object file and link (WASM via `clang`/in-process LLD;
///      native via cross-link-through-zig, in-process Mach-O LLD, or `clang++`).
///
/// `visited` is the caller-owned set of already-loaded file paths; it is shared
/// so watch mode can learn which files to stat for changes. `build_mode`,
/// `build_obj_dir`, and `build_hash_path` are only meaningful in project mode
/// and drive the `build/<profile>` layout, the per-file object split, and the
/// content-hash up-to-date check. Errors propagate (`error.LinkFailed`,
/// `error.UnsupportedTarget`, allocation/IO failures); sema-pass failures are
/// caught and printed rather than aborting, since a diagnostic is more useful
/// than a stack trace. See [`cmdBuild`], which computes every argument here.
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

    const asan = !is_wasm and want_asan;
    codegen_arc.asan_codegen_enabled = asan and (init.environ_map.get("KYTE_ASAN_CODEGEN") != null);

    pipeline.loadProgram(allocator, init, "src/std/collections/string_builder.ky", visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder standard library: {any}\n", .{err});
    };

    try pipeline.loadProgram(allocator, init, file_path, visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo);

    if (want_dump_merged) {
        _ = Io.Dir.writeFile(.cwd(), init.io, .{ .data = merged.items, .sub_path = "merged.ky", .flags = .{} }) catch |err| {
            std.debug.print("Failed to write merged.ky: {s}\n", .{@errorName(err)});
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
                std.debug.print("{s} is up to date ({s}), nothing to rebuild.\n", .{ output_path, if (is_release) "release" else "debug" });
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
        var helpers_p = try parser.Parser.init(allocator, helpers, "helpers.ky", is_wasm);
        defer helpers_p.deinit();
        const helpers_prog = try helpers_p.parseProgram();
        try declarations.appendSlice(allocator, helpers_prog.declarations);
    }
    try pipeline.expandTraitDefaults(allocator, &declarations);
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

    try sema_alpha.run(allocator, program);

    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    tc.is_wasm = is_wasm;
    try tc.check(program);

    sema_shadow.report_enabled = init.environ_map.get("KYTE_SEMA_SHADOW") != null;
    sema_shadow.tid_census = init.environ_map.get("KYTE_TID_CENSUS") != null;
    codegen_arc.elide_enabled = init.environ_map.get("KYTE_ARC_ELIDE_OFF") == null;
    codegen_arc.arc_census = init.environ_map.get("KYTE_ARC_CENSUS") != null;
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

    {
        const reach = @import("frontend/sema/reach.zig");
        const shadow = init.environ_map.get("KYTE_REACH_SHADOW") != null;
        const gate = init.environ_map.get("KYTE_REACH_OFF") == null;
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

    sema_escape.report_enabled = init.environ_map.get("KYTE_ESCAPE_REPORT") != null;
    if (sema_escape.report_enabled) _ = sema_escape.analyze(allocator, &owned_sema.store, &owned_sema.ir, &program);

    if (init.environ_map.get("KYTE_OWN_VERIFY")) |v| {
        const hard = std.mem.eql(u8, v, "hard");
        sema_ownership.runVerify(allocator, &owned_sema.store, &owned_sema.ir, &program, hard);
        codegen_arc.balance_verify = true;
        codegen_arc.balance_hard = false;
    }

    {
        const ossa = init.environ_map.get("KYTE_OSSA");
        const disabled = ossa != null and std.mem.eql(u8, ossa.?, "off");
        if (!disabled) {
            const report_only = ossa != null and std.mem.eql(u8, ossa.?, "1");
            const verbose = ossa != null;
            sema_ossa_lower.reportQuiet(allocator, &owned_sema.store, &owned_sema.ir, &program, !report_only, !verbose);
        }
    }


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
        const shared_kyte = try std.fmt.allocPrint(allocator, "{s}/.kyte", .{ home });

        const ffi_libs = try pipeline.collectFfiLibs(allocator, program);

        if (target_triple_opt) |triple| {
            if (try pipeline.crossLinkViaZig(allocator, init.environ_map, init.io, triple, link_objs, output_path, shared_kyte, is_release)) {
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
            try pipeline.linkNativeInProcessMacho(allocator, init.environ_map, init.io, link_objs, output_path, shared_kyte, ffi_libs);

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

        const shared_kyte_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{shared_kyte});
        try clang_args.append(allocator, shared_kyte_arg);

        for (link_objs) |o| try clang_args.append(allocator, o);

        try pipeline.appendRuntimeLink(&clang_args, allocator, shared_kyte, if (asan) "kytecore_asan" else "kytecore");
        try pipeline.appendWolfsslLink(&clang_args, allocator, shared_kyte, init.io);
        for (ffi_libs) |lib| {
            try pipeline.appendFfiLib(&clang_args, allocator, shared_kyte, init.io, lib);
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

/// Parse the `kyte build` / `kyte <file>` command line and drive one (or many,
/// under `--watch`) compiles.
///
/// This is the CLI-facing half: it does argument parsing, path/flag resolution,
/// and directory setup, then hands off to [`compileProgram`] for the actual
/// work. It first ensures declared dependencies are present, then sets the three
/// process-global `want_*` toggles and the [`llvm_codegen.flags`] from the flag
/// list.
///
/// Argument parsing has TWO shapes keyed off `args[1]`:
///   * `args[1] == "build"` → project mode. Flags carry values (`--target X`,
///     `--file X`, `-o X`, `--release`/`-r`, `--debug`/`-d`, `--watch`/`-w`).
///     Defaults: entry `src/main.ky`, name from `project.json`, output under
///     `build/<profile>/bin`, objects under `build/<profile>/obj`, and a
///     `.build-hash` stamp for incremental rebuilds.
///   * otherwise → single-file mode with `args[1]` as the file and a looser flag
///     set (`--wasm`/`--native`, `--target`/`-t X`, `-o X`, release/debug/watch).
///
/// `--target` accepts `wasm`, `native`, or a cross switch (`linux-arm64`,
/// `linux-x86_64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64`,
/// `windows-arm64`) which is mapped to an LLVM triple; an unknown switch returns
/// `error.UnsupportedTarget`. When no `-o` is given the output name is derived
/// from the entry file's basename (`.wasm` suffix for WASM).
///
/// In `--watch` mode it loops forever: each pass compiles under a fresh arena,
/// records the mtimes of every visited file, then polls at 500 ms until one of
/// them changes and recompiles. A compile failure in watch mode is printed and
/// the loop continues rather than exiting. In non-watch mode it compiles exactly
/// once and returns.
pub fn cmdBuild(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    try packages.ensureDependencies(allocator, init);

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

        if (file_path.len == 0) file_path = "src/main.ky";

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

