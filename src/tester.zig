//! The `nova test` runner.
//!
//! This drives the whole test pipeline: it loads the program the user asked to
//! test (a named file, or every `.nova` file under the project), collects the
//! `@test` functions THAT USER wrote, synthesises a `main()` harness that calls
//! each one and tallies pass/fail, then runs the normal compile + link pipeline
//! on the combined program and executes the resulting binary.
//!
//! Two deliberate behaviours are the source of subtle bugs if changed:
//!
//!   1. Only the USER's `@test`s run. The stdlib is merged into the program like
//!      any import and carries its own `@test`s, but re-running those on every
//!      `nova test` would be noise (they are already covered by the conformance
//!      corpus). [`collectTestFunctions`] filters by source file so stdlib and
//!      package tests are excluded.
//!   2. A file with no `@test` of its own is still COMPILED (it just reports
//!      "0 passed, 0 failed"), so a mistake in such a file is still caught. This
//!      is why the runner falls through to build a trivial harness rather than
//!      returning early when no tests are found.
//!
//! The harness also gates on the ARC leak audit: if `nova_arc_audit_report`
//! reports survivors the process exits non-zero, so a leak fails the test run.

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


/// Collects the names of `@test` functions declared in the USER's files.
///
/// Walks the merged declaration list and keeps a `fn` only when BOTH: its
/// `span.file` (stamped by the parser with the source path) matches one of
/// `user_files`, AND it carries the `@test` attribute. The `span.file` filter is
/// what excludes the stdlib's and imported packages' own tests, which are merged
/// into the program but are not what `nova test <file>` is asking to run. The
/// returned slice is owned by the caller.
fn collectTestFunctions(declarations: []const ast.Declaration, user_files: []const []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var test_fns = std.ArrayList([]const u8).empty;
    defer test_fns.deinit(allocator);
    for (declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                var from_user_file = false;
                for (user_files) |uf| {
                    if (std.mem.eql(u8, fd.span.file, uf)) {
                        from_user_file = true;
                        break;
                    }
                }
                if (!from_user_file) continue;
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

/// Generates the Nova source of the harness `main()` that drives the tests.
///
/// Emits a `main` that, for each test name, resets the per-test state
/// (`nova_test_reset`), marks the current test (`nova_test_begin`), calls the
/// test function, and prints `PASS`/`FAIL` based on `nova_test_did_fail`,
/// accumulating counts. After all tests it prints the `Results:` summary and
/// exits non-zero if the ARC audit reports survivors OR any test failed, so a
/// leak or a failure both fail the process. The result is Nova source text,
/// parsed and merged into the program alongside the user's code. `console.log`
/// string concatenation is used because the harness is plain Nova, not Zig.
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

/// Entry point for the `nova test` subcommand.
///
/// Runs the full test pipeline end to end:
///
///   1. Ensures dependencies are fetched, then parses the build-tuning flags
///      (`--split-objects`, `--prune`, `--emit-llvm`, `--mem-stats`, `--wasm`/
///      `--native`, `--asan`/`--tsan`) and the optional target file.
///   2. Determines the files to test: the given file, or every `.nova` file
///      under the current directory when none is named.
///   3. Loads and merges those files (plus `string_builder` and small runtime
///      helpers) into one declaration list, resolving imports transitively.
///   4. Collects the user's `@test`s ([`collectTestFunctions`]), generates the
///      harness ([`generateTestHarness`]), and appends it. `main` from the
///      user's files is dropped so only the harness `main` remains.
///   5. Runs the normal frontend (synthetic generators, alpha-rename, id
///      assignment, type check, TypeId sema, monomorphise, optional
///      reach/escape/ownership/OSSA passes) exactly as a real build does, so a
///      test build exercises the same pipeline as `nova build`.
///   6. Emits objects, links against the C++ runtime (`novacore`, or the
///      `_asan`/`_tsan` variant), and runs the produced `__nova_test` binary.
///
/// The whole `build/test` tree is cleaned up afterwards. The process exits
/// non-zero if the test binary reports failure (which itself covers both a
/// failed assertion and a leak, see [`generateTestHarness`]).
pub fn cmdTest(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    try packages.ensureDependencies(allocator, init);

    llvm_codegen.flags.split_per_file = pipeline.hasFlag(args, "--split-objects");
    llvm_codegen.flags.prune = pipeline.hasFlag(args, "--prune");
    llvm_codegen.flags.dump_ir = pipeline.hasFlag(args, "--emit-llvm");
    llvm_codegen.flags.mem_stats = pipeline.hasFlag(args, "--mem-stats");

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
        pipeline.findNovaFiles(allocator, init.io, .cwd(), ".", &file_paths) catch |err| {
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
    const tinfo = pipeline.deriveTargetInfo(target, null);

    pipeline.loadProgram(allocator, init, "src/std/collections/string_builder.nova", &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder in test harness: {any}\n", .{err});
    };

    for (file_paths.items) |path| {
        pipeline.loadProgram(allocator, init, path, &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
            std.debug.print("Failed to load program {s}: {any}\n", .{ path, err });

            return err;
        };
    }

    const test_fn_names = try collectTestFunctions(declarations.items, file_paths.items, allocator);
    if (test_fn_names.len == 0) {
        if (file_path.len == 0) {
            std.debug.print("No @test functions found in project directory; compiling only.\n", .{});
        } else {
            std.debug.print("No @test functions found in {s}; compiling only.\n", .{file_path});
        }
    } else {
        std.debug.print("Found {d} test function(s)\n", .{test_fn_names.len});
    }

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

    try pipeline.expandTraitDefaults(allocator, &filtered_decls);
    try pipeline.generateControllerRoutes(allocator, &filtered_decls);
    try pipeline.generateSerdeBinders(allocator, &filtered_decls, is_wasm);
    try pipeline.generateMediatorDispatch(allocator, &filtered_decls, is_wasm);
    try pipeline.generateRuntimeMediator(allocator, &filtered_decls, is_wasm);

    const program = ast.Program{
        .declarations = filtered_decls.items,
        .span = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = file_path },
    };

    try sema_alpha.run(allocator, program);

    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    tc.is_wasm = is_wasm;
    try tc.check(program);

    sema_shadow.report_enabled = init.environ_map.get("NOVA_SEMA_SHADOW") != null;
    sema_shadow.tid_census = init.environ_map.get("NOVA_TID_CENSUS") != null;
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

    {
        const reach = @import("frontend/sema/reach.zig");
        const shadow = init.environ_map.get("NOVA_REACH_SHADOW") != null;
        const gate = init.environ_map.get("NOVA_REACH_ON") != null;
        if (shadow or gate) {
            var rr = reach.compute(allocator, &owned_sema.tab, &owned_sema.ir, program, true) catch reach.Result{};
            defer rr.deinit(allocator);
            if (shadow) reach.report(&rr, &owned_sema.tab);
            if (gate) {
                reach.publish(allocator, &rr, &owned_sema.tab);
                reach.gate_on = true;
            }
        }
    }

    sema_escape.report_enabled = init.environ_map.get("NOVA_ESCAPE_REPORT") != null;
    if (sema_escape.report_enabled) _ = sema_escape.analyze(allocator, &owned_sema.store, &owned_sema.ir, &program);

    if (init.environ_map.get("NOVA_OWN_VERIFY")) |v| {
        const hard = std.mem.eql(u8, v, "hard");
        sema_ownership.runVerify(allocator, &owned_sema.store, &owned_sema.ir, &program, hard);
        codegen_arc.balance_verify = true;
        codegen_arc.balance_hard = false;
    }

    {
        const ossa = init.environ_map.get("NOVA_OSSA");
        const disabled = ossa != null and std.mem.eql(u8, ossa.?, "off");
        if (!disabled) {
            const report_only = ossa != null and std.mem.eql(u8, ossa.?, "1");
            const verbose = ossa != null;
            sema_ossa_lower.reportQuiet(allocator, &owned_sema.store, &owned_sema.ir, &program, !report_only, !verbose);
        }
    }


    const test_dir = "build/test";
    Io.Dir.createDirPath(.cwd(), init.io, test_dir) catch {};
    const output_path = "build/test/__nova_test";
    const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
    defer allocator.free(obj_path);
    const t6_split = llvm_codegen.flags.split_per_file;
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
    sema_shadow.tidCensusReport();
    sema_shadow.reportF45();
    sema_mono.dumpMethodInsts();

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const shared_nova = try std.fmt.allocPrint(allocator, "{s}/.nova", .{ home });
    const shared_nova_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{shared_nova});

    const asan = pipeline.hasFlag(args, "--asan");
    const tsan = pipeline.hasFlag(args, "--tsan");

    var test_clang_args = std.ArrayList([]const u8).empty;
    try test_clang_args.append(allocator, "clang++");
    try test_clang_args.append(allocator, "-std=c++20");
    try test_clang_args.append(allocator, "-g");
    try test_clang_args.append(allocator, "-O0");
    try test_clang_args.append(allocator, "-pthread");

    try test_clang_args.append(allocator, pipeline.dead_strip_flag);
    try test_clang_args.appendSlice(allocator, pipeline.pie_flags);
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

    try pipeline.appendRuntimeLink(&test_clang_args, allocator, shared_nova, if (asan)
        "novacore_asan"
    else if (tsan)
        "novacore_tsan"
    else
        "novacore");
    try pipeline.appendWolfsslLink(&test_clang_args, allocator, shared_nova, init.io);

    for (try pipeline.collectFfiLibs(allocator, program)) |lib| {
        try pipeline.appendFfiLib(&test_clang_args, allocator, shared_nova, init.io, lib);
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
        .argv = &[_][]const u8{"./build/test/__nova_test"},
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

    Io.Dir.deleteTree(.cwd(), init.io, test_dir) catch {};

    if (suite_failed) std.process.exit(1);
}
