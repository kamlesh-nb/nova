// tester.zig — `nova test` — collect @test fns, generate a harness, compile and run.

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
const sema_alpha = @import("frontend/sema/alpha.zig");
const sema_ids = @import("frontend/sema/ids.zig");
const sema_mod = @import("frontend/sema/sema.zig");
const sema_mono = @import("frontend/sema/mono.zig");
const pipeline = @import("pipeline.zig");
const packages = @import("packages.zig");


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

pub fn cmdTest(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    // Auto-fetch: clone any project.json dependency missing from the package cache before compiling.
    // Silent when there is no project.json (a bare `nova test <file>`).
    try packages.ensureDependencies(allocator, init);

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

    try pipeline.generateControllerRoutes(allocator, &filtered_decls);
    try pipeline.generateSerdeBinders(allocator, &filtered_decls, is_wasm);
    try pipeline.generateMediatorDispatch(allocator, &filtered_decls, is_wasm);
    try pipeline.generateRuntimeMediator(allocator, &filtered_decls, is_wasm);

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
    sema_shadow.tid_census = init.environ_map.get("NOVA_TID_CENSUS") != null;
    // M-5 (memory-management-refinements.md): borrowed-field ARC elision is ON by default
    // (verified: corpus + ASAN clean, differential ARC audit identical off vs on). Set
    // NOVA_ARC_ELIDE_OFF to disable it for debugging a suspected elision regression.
    codegen_arc.elide_enabled = init.environ_map.get("NOVA_ARC_ELIDE_OFF") == null;
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

    // P7 Stage 1: report-only escape gauge (no codegen effect). See docs/design/p7-sound-arena.md.
    sema_escape.report_enabled = init.environ_map.get("NOVA_ESCAPE_REPORT") != null;
    if (sema_escape.report_enabled) _ = sema_escape.analyze(allocator, &owned_sema.store, &owned_sema.ir, &program);

    // OSSA-lite Track V: opt-in ownership verifier. See docs/design/ossa-lite-tasks.md.
    // Drives both the sema-level coverage report and the codegen ARC release-balance verifier (V4').
    if (init.environ_map.get("NOVA_OWN_VERIFY")) |v| {
        sema_ownership.runVerify(allocator, &owned_sema.store, &owned_sema.ir, &program, std.mem.eql(u8, v, "hard"));
        codegen_arc.balance_verify = true;
        codegen_arc.balance_hard = std.mem.eql(u8, v, "hard");
    }

    // (HIR/MIR/LIR LLVM-emit optimiser scrapped 2026-08-16; see docs/design/sil-arc-optimiser-direction.md.)

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
    sema_shadow.tidCensusReport();
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
