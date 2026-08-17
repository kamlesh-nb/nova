const std = @import("std");
const ast = @import("../../frontend/ast.zig");
const sema_shadow = @import("../../frontend/sema/shadow.zig");
const sema_mono = @import("../../frontend/sema/mono.zig");
const sema_types = @import("../../frontend/types.zig");
const getStructBaseName = @import("types.zig").getStructBaseName;
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;
const analysis = llvm.analysis;
const target_machine = llvm.target_machine;
const transform = llvm.transform;
const errors = llvm.errors;

const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const unescapeString = @import("llvm_codegen.zig").unescapeString;
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
const Scope = @import("llvm_codegen.zig").Scope;

// NOVA_MEM_STATS phase profiler: prints peak RSS (ru_maxrss, bytes on macOS) reached so far, so we can see
// which codegen phase pushes the high-water mark. Zero-cost unless the env var is set.
var mem_phase_on: ?bool = null;
fn memPhase(label: []const u8) void {
    if (mem_phase_on == null) mem_phase_on = (std.c.getenv("NOVA_MEM_STATS") != null);
    if (!(mem_phase_on.?)) return;
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const mb = @as(u64, @intCast(ru.maxrss)) / (1024 * 1024); // macOS: bytes
    std.debug.print("[MEM] {s:<28} peak={d} MB\n", .{ label, mb });
}

// Demand pruning: drop functions unreachable from the program entry so a source file the app never
// calls (crypto/tls/bson in a plain web app) produces NO object at all. On by default for builds;
// set NOVA_NO_PRUNE=1 to fall back to compiling every imported file's object.
var prune_on: ?bool = null;
fn pruneEnabled() bool {
    if (prune_on == null) prune_on = (std.c.getenv("NOVA_NO_PRUNE") == null);
    return prune_on.?;
}

fn ffiCType(compiler: *LlvmCompiler, type_name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, type_name, "int")) return compiler.i32_type;
    if (std.mem.eql(u8, type_name, "long")) return compiler.i64_type;
    if (std.mem.eql(u8, type_name, "bool")) return compiler.i8_type;
    if (std.mem.eql(u8, type_name, "void")) return compiler.void_type;

    return compiler.ptr_type;
}

// The source span of a statement, whichever variant it is (used for DWARF line attribution).
fn stmtSpan(stmt: ast.Statement) ast.Span {
    return switch (stmt) {
        .block => |s| s.span,
        .let_stmt => |s| s.span,
        .expr_stmt => |s| s.span,
        .if_stmt => |s| s.span,
        .while_stmt => |s| s.span,
        .for_stmt => |s| s.span,
        .switch_stmt => |s| s.span,
        .return_stmt => |s| s.span,
        .break_stmt => |s| s.span,
        .continue_stmt => |s| s.span,
        .defer_stmt => |s| s.span,
    };
}

pub fn compile(allocator: std.mem.Allocator, program: ast.Program, is_wasm: bool, is_release: bool, target_triple_opt: ?[]const u8, output_path: []const u8, coverage_enabled: bool, t6_split: bool, objs_out: ?*std.ArrayList([]const u8), cache_dir: ?[]const u8, io: std.Io) !void {
    var compiler = try LlvmCompiler.new(allocator, is_wasm, is_release, target_triple_opt, coverage_enabled);

    compiler.typed_ir = sema_shadow.live_ir;
    compiler.type_store = sema_shadow.live_store;

    compiler.f2_types = sema_shadow.f2_types_enabled;
    defer compiler.deinit();

    // Resolve the absolute cwd once so DWARF records absolute source dirs (lldb-dap matches
    // breakpoints by absolute path; a relative dir only binds by basename, which it won't do).
    {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.realPathFile(.cwd(), io, ".", &cwd_buf)) |n| {
            compiler.di_cwd = allocator.dupe(u8, cwd_buf[0..n]) catch null;
        } else |_| {}
    }
    defer if (compiler.di_cwd) |c| allocator.free(c);

    compiler.program = program;
    memPhase("compile start");

    for (program.declarations) |decl| {
        switch (decl) {
            .const_decl => |c| try compiler.constants.put(c.name, c.value),
            // Key colliding enums by their module-scoped name (like structs), so two same-named enums in
            // different modules don't overwrite each other (S3). Non-colliding keep the bare name. Traits
            // stay bare-keyed (their scoping is a separate follow-on; see renderLegacy).
            .enum_decl => |e| try compiler.enums.put(compiler.scopedStructName(e.name, e.span.file), e),
            .trait_decl => |t| try compiler.traits.put(t.name, t),
            else => {},
        }
    }

    try compiler.collectFunctions(program);
    memPhase("after collectFunctions");

    var i: usize = 0;
    while (i < compiler.functions.items.len) {
        compiler.current_collecting_function_name = compiler.functions.items[i].name;

        compiler.current_collecting_instantiation = compiler.functions.items[i].instantiation;
        // Derive the inst_key IDENTICALLY to the body-compile lookup (see line ~669) so a closure's
        // registration key and its lookup key agree: raw instantiation_id, else the name->live_inst_ids map.
        compiler.current_collecting_instantiation_id = compiler.functions.items[i].instantiation_id orelse
            (if (compiler.functions.items[i].instantiation) |inst| sema_mono.live_inst_ids.get(inst) else null);
        compiler.current_collecting_erased_generic = compiler.functions.items[i].erased_generic;
        try compiler.collectClosuresFromBlock(compiler.functions.items[i].body);
        i += 1;
    }
    compiler.current_collecting_function_name = null;
    compiler.current_collecting_instantiation = null;
    compiler.current_collecting_instantiation_id = null;

    if (t6_split) {
        var by_file = std.StringHashMap(usize).init(allocator);
        defer by_file.deinit();
        var uncategorized: usize = 0;
        for (compiler.functions.items) |func| {
            if (func.source_file.len == 0) {
                uncategorized += 1;
                continue;
            }
            const gop = try by_file.getOrPut(func.source_file);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        std.debug.print("[T6] function partition: {d} files, {d} functions ({d} uncategorized)\n", .{ by_file.count(), compiler.functions.items.len, uncategorized });
        var it = by_file.iterator();
        while (it.next()) |e| {
            std.debug.print("[T6]   {d:>4}  {s}\n", .{ e.value_ptr.*, std.fs.path.basename(e.key_ptr.*) });
        }
    }

    try compiler.collectStringLiterals(program);
    for (compiler.functions.items) |func| {
        try compiler.collectStringsFromBlock(func.body);
    }

    var total_data_size: u32 = 0;
    for (compiler.strings.items) |str| {
        const unescaped = try unescapeString(allocator, str);
        defer allocator.free(unescaped);
        total_data_size += 4 + @as(u32, @intCast(unescaped.len));
    }
    const heap_start = if (total_data_size < 1024) @as(u32, 1024) else (total_data_size + 15) & ~@as(u32, 15);

    const heap_ptr_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "heap_ptr");
    const persistent_ptr_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "persistent_ptr");
    if (is_wasm) {

        const heap_base = core.LLVMAddGlobal(compiler.module, compiler.i8_type, "__heap_base");
        core.LLVMSetLinkage(heap_base, .LLVMExternalLinkage);
        core.LLVMSetInitializer(heap_ptr_global, core.LLVMConstInt(compiler.val_type, 0, 0));
        core.LLVMSetInitializer(persistent_ptr_global, core.LLVMConstInt(compiler.val_type, 0, 0));
    } else {
        core.LLVMSetInitializer(heap_ptr_global, core.LLVMConstInt(compiler.val_type, @intCast(heap_start), 0));
        core.LLVMSetInitializer(persistent_ptr_global, core.LLVMConstInt(compiler.val_type, @intCast(heap_start + 32 * 1024 * 1024), 0));
    }
    compiler.heap_ptr = heap_ptr_global;

    const free_list_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "free_list");
    core.LLVMSetInitializer(free_list_global, core.LLVMConstInt(compiler.val_type, 0, 0));
    compiler.free_list = free_list_global;

    compiler.persistent_ptr = persistent_ptr_global;

    for (compiler.strings.items) |str| {
        const unescaped = try unescapeString(allocator, str);
        defer allocator.free(unescaped);

        var field_types = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.i32_type, core.LLVMArrayType(compiler.i8_type, @intCast(unescaped.len)) };
        const struct_type = core.LLVMStructType(&field_types, 3, 1);

        const global_var = core.LLVMAddGlobal(compiler.module, struct_type, "str_literal");
        core.LLVMSetGlobalConstant(global_var, 0);
        core.LLVMSetLinkage(global_var, types.LLVMLinkage.LLVMInternalLinkage);

        const str_z = try allocator.dupeZ(u8, unescaped);
        defer allocator.free(str_z);
        // Immortal constant: NEGATIVE refcount => nova_retain/nova_release are no-ops (both early-return on
        // `*rc < 0`). +100000000 was decremented per use (literal stored without a matching retain, released
        // on drop), so a literal reused >1e8 times drifted to zero, freed the shared global, and double-freed.
        // Must match getOrCreateStringLiteral in llvm_codegen.zig (the other string-literal emitter).
        const ref_const = core.LLVMConstInt(compiler.i32_type, @as(c_ulonglong, @bitCast(@as(i64, -1000000000))), 0);
        const len_const = core.LLVMConstInt(compiler.i32_type, @intCast(unescaped.len), 0);
        const chars_const = core.LLVMConstString(str_z.ptr, @intCast(unescaped.len), 1);

        var field_values = [_]types.LLVMValueRef{ ref_const, len_const, chars_const };
        const init_const = core.LLVMConstStruct(&field_values, 3, 1);
        core.LLVMSetInitializer(global_var, init_const);

        try compiler.string_globals.put(str, global_var);
    }

    {
        var i64_p = [_]types.LLVMTypeRef{compiler.val_type};
        const i64_t = core.LLVMFunctionType(compiler.val_type, &i64_p, 1, 0);
        try compiler.func_map.put("nova_i64_to_string", core.LLVMAddFunction(compiler.module, "nova_i64_to_string", i64_t));

        var f64_p = [_]types.LLVMTypeRef{core.LLVMDoubleType()};
        const f64_t = core.LLVMFunctionType(compiler.val_type, &f64_p, 1, 0);
        try compiler.func_map.put("nova_f64_to_string", core.LLVMAddFunction(compiler.module, "nova_f64_to_string", f64_t));

        var ieee_p = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        try compiler.func_map.put("nova_ieee_le_to_str", core.LLVMAddFunction(compiler.module, "nova_ieee_le_to_str", core.LLVMFunctionType(compiler.ptr_type, &ieee_p, 2, 0)));

        var f64bits_p = [_]types.LLVMTypeRef{core.LLVMDoubleType()};
        try compiler.func_map.put("nova_f64_bits", core.LLVMAddFunction(compiler.module, "nova_f64_bits", core.LLVMFunctionType(compiler.val_type, &f64bits_p, 1, 0)));

        // nova_pg_be_f64(ptr: long, len: int) -> double : big-endian IEEE float read for the pg BINARY decode.
        var pgbe_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.i32_type };
        try compiler.func_map.put("nova_pg_be_f64", core.LLVMAddFunction(compiler.module, "nova_pg_be_f64", core.LLVMFunctionType(core.LLVMDoubleType(), &pgbe_p, 2, 0)));
        // nova_pg_be_i64(ptr: long, len: int) -> long : big-endian signed int read for the pg BINARY decode.
        var pgbei_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.i32_type };
        try compiler.func_map.put("nova_pg_be_i64", core.LLVMAddFunction(compiler.module, "nova_pg_be_i64", core.LLVMFunctionType(compiler.val_type, &pgbei_p, 2, 0)));
        // nova_html_find_meta(base: long, start: int, len: int) -> int : SWAR scan for next HTML metachar.
        var hfm_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.i32_type, compiler.i32_type };
        try compiler.func_map.put("nova_html_find_meta", core.LLVMAddFunction(compiler.module, "nova_html_find_meta", core.LLVMFunctionType(compiler.i32_type, &hfm_p, 3, 0)));

        // nova_f64_sqrt IS the llvm.sqrt.f64 intrinsic (double -> double), lowered by LLVM to a hardware
        // fsqrt. Registering it under this name lets math.fsqrt call it like any extern; no runtime symbol.
        var sqrt_p = [_]types.LLVMTypeRef{core.LLVMDoubleType()};
        try compiler.func_map.put("nova_f64_sqrt", core.LLVMAddFunction(compiler.module, "llvm.sqrt.f64", core.LLVMFunctionType(core.LLVMDoubleType(), &sqrt_p, 1, 0)));

        var bool_p = [_]types.LLVMTypeRef{compiler.val_type};
        const bool_t = core.LLVMFunctionType(compiler.val_type, &bool_p, 1, 0);
        try compiler.func_map.put("nova_bool_to_string", core.LLVMAddFunction(compiler.module, "nova_bool_to_string", bool_t));

        var dec_from_p = [_]types.LLVMTypeRef{compiler.ptr_type};
        const dec_from_t = core.LLVMFunctionType(compiler.val_type, &dec_from_p, 1, 0);
        try compiler.func_map.put("nova_decimal_from_string", core.LLVMAddFunction(compiler.module, "nova_decimal_from_string", dec_from_t));

        var dec_to_p = [_]types.LLVMTypeRef{compiler.val_type};
        const dec_to_t = core.LLVMFunctionType(compiler.val_type, &dec_to_p, 1, 0);
        try compiler.func_map.put("nova_decimal_to_string", core.LLVMAddFunction(compiler.module, "nova_decimal_to_string", dec_to_t));

        var dec_bin_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const dec_bin_t = core.LLVMFunctionType(compiler.val_type, &dec_bin_p, 2, 0);
        for ([_][:0]const u8{ "nova_decimal_add", "nova_decimal_sub", "nova_decimal_mul", "nova_decimal_div", "nova_decimal_mod", "nova_decimal_cmp" }) |name| {
            try compiler.func_map.put(name, core.LLVMAddFunction(compiler.module, name, dec_bin_t));
        }

        var dec_fi_p = [_]types.LLVMTypeRef{compiler.val_type};
        const dec_fi_t = core.LLVMFunctionType(compiler.val_type, &dec_fi_p, 1, 0);
        try compiler.func_map.put("nova_decimal_from_int", core.LLVMAddFunction(compiler.module, "nova_decimal_from_int", dec_fi_t));
        try compiler.func_map.put("nova_decimal_to_int", core.LLVMAddFunction(compiler.module, "nova_decimal_to_int", dec_fi_t));

        var dec_fsn_p = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.val_type };
        const dec_fsn_t = core.LLVMFunctionType(compiler.val_type, &dec_fsn_p, 2, 0);
        try compiler.func_map.put("nova_decimal_from_string_n", core.LLVMAddFunction(compiler.module, "nova_decimal_from_string_n", dec_fsn_t));
    }

    if (!is_wasm) {
        var inv_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const inv_t = core.LLVMFunctionType(compiler.val_type, &inv_p, 2, 0);
        try compiler.func_map.put("nova_invoke_str_closure", core.LLVMAddFunction(compiler.module, "nova_invoke_str_closure", inv_t));
        var invv_p = [_]types.LLVMTypeRef{compiler.val_type};
        const invv_t = core.LLVMFunctionType(compiler.void_type, &invv_p, 1, 0);
        try compiler.func_map.put("nova_invoke_void_closure", core.LLVMAddFunction(compiler.module, "nova_invoke_void_closure", invv_t));
    }

    if (is_wasm) {

        var log_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const log_fn_type = core.LLVMFunctionType(compiler.void_type, &log_params, 2, 0);
        const log_fn = core.LLVMAddFunction(compiler.module, "log", log_fn_type);
        core.LLVMAddTargetDependentFunctionAttr(log_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(log_fn, "wasm-import-name", "log");
        compiler.log_fn = log_fn;

        try compiler.generateWasmMemoryFunctions();

        const now_fn_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_fn = core.LLVMAddFunction(compiler.module, "nova_time_now", now_fn_type);
        core.LLVMAddTargetDependentFunctionAttr(now_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(now_fn, "wasm-import-name", "now");
        try compiler.func_map.put("nova_time_now", now_fn);

        const get_st_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const get_st_fn = core.LLVMAddFunction(compiler.module, "nova_get_stacktrace", get_st_type);
        core.LLVMAddTargetDependentFunctionAttr(get_st_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(get_st_fn, "wasm-import-name", "get_stacktrace");
        try compiler.func_map.put("nova_get_stacktrace", get_st_fn);

        {
            var th_ptr = [_]types.LLVMTypeRef{compiler.ptr_type};
            const th_void_ptr = core.LLVMFunctionType(compiler.void_type, &th_ptr, 1, 0);
            const th_void = core.LLVMFunctionType(compiler.void_type, null, 0, 0);
            const th_i32 = core.LLVMFunctionType(compiler.i32_type, null, 0, 0);
            const th_ptr_ret = core.LLVMFunctionType(compiler.ptr_type, null, 0, 0);
            const Imp = struct { name: [:0]const u8, ty: types.LLVMTypeRef };
            const imps = [_]Imp{
                .{ .name = "nova_test_reset", .ty = th_void },
                .{ .name = "nova_test_begin", .ty = th_void_ptr },
                .{ .name = "nova_test_fail", .ty = th_void_ptr },
                .{ .name = "nova_test_did_fail", .ty = th_i32 },
                .{ .name = "nova_test_fail_message", .ty = th_ptr_ret },
                .{ .name = "nova_optional_deref_fail", .ty = th_void_ptr },
                .{ .name = "nova_panic", .ty = th_void_ptr },
            };
            for (imps) |imp| {
                const f = core.LLVMAddFunction(compiler.module, imp.name.ptr, imp.ty);
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-module", "env");
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-name", imp.name.ptr);
                try compiler.func_map.put(imp.name, f);
            }
        }

        {
            var one_ptr = [_]types.LLVMTypeRef{compiler.ptr_type};
            var one_val = [_]types.LLVMTypeRef{compiler.val_type};
            const val_0 = core.LLVMFunctionType(compiler.val_type, &one_ptr, 0, 0);
            const val_1val = core.LLVMFunctionType(compiler.val_type, &one_val, 1, 0);
            const Imp2 = struct { name: [:0]const u8, ty: types.LLVMTypeRef };
            const imps2 = [_]Imp2{
                .{ .name = "nova_arg_count", .ty = val_0 },
                .{ .name = "nova_arg_at", .ty = val_1val },
            };
            for (imps2) |imp| {
                const f = core.LLVMAddFunction(compiler.module, imp.name.ptr, imp.ty);
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-module", "env");
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-name", imp.name.ptr);
                try compiler.func_map.put(imp.name, f);
            }
        }
    } else {

        var printf_params = [_]types.LLVMTypeRef{compiler.ptr_type};
        const printf_type = core.LLVMFunctionType(compiler.i32_type, &printf_params, 1, 1);
        compiler.printf_fn = core.LLVMAddFunction(compiler.module, "printf", printf_type);

        var puts_params = [_]types.LLVMTypeRef{compiler.ptr_type};
        const puts_type = core.LLVMFunctionType(compiler.i32_type, &puts_params, 1, 0);
        compiler.puts_fn = core.LLVMAddFunction(compiler.module, "puts", puts_type);

        const log_str_type = core.LLVMFunctionType(compiler.void_type, &puts_params, 1, 0);
        compiler.nova_log_string_fn = core.LLVMAddFunction(compiler.module, "nova_log_string", log_str_type);
        compiler.nova_log_info_fn = core.LLVMAddFunction(compiler.module, "nova_log_info", log_str_type);
        compiler.nova_log_debug_fn = core.LLVMAddFunction(compiler.module, "nova_log_debug", log_str_type);
        compiler.nova_log_err_fn = core.LLVMAddFunction(compiler.module, "nova_log_err", log_str_type);

        var malloc_params = [_]types.LLVMTypeRef{compiler.val_type};
        const malloc_type = core.LLVMFunctionType(compiler.ptr_type, &malloc_params, 1, 0);
        const malloc_fn = core.LLVMAddFunction(compiler.module, "malloc", malloc_type);
        try compiler.func_map.put("malloc", malloc_fn);

        const now_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_fn = core.LLVMAddFunction(compiler.module, "nova_time_now", now_type);
        try compiler.func_map.put("nova_time_now", now_fn);

        const now_ns_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_ns_fn = core.LLVMAddFunction(compiler.module, "nova_time_now_ns", now_ns_type);
        try compiler.func_map.put("nova_time_now_ns", now_ns_fn);

        const get_st_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const get_st_fn = core.LLVMAddFunction(compiler.module, "nova_get_stacktrace", get_st_type);
        try compiler.func_map.put("nova_get_stacktrace", get_st_fn);

        try setupCoroutineSupport(&compiler);

        var one_param_i32 = [_]types.LLVMTypeRef{compiler.i32_type};
        var one_param_ptr = [_]types.LLVMTypeRef{compiler.ptr_type};

        const close_type = core.LLVMFunctionType(compiler.i32_type, &one_param_i32, 1, 0);
        const close_fn = core.LLVMAddFunction(compiler.module, "nova_close", close_type);
        try compiler.func_map.put("close", close_fn);
        try compiler.func_map.put("nova_close", close_fn);

        const test_reset_type = core.LLVMFunctionType(compiler.void_type, null, 0, 0);
        const test_reset_fn = core.LLVMAddFunction(compiler.module, "nova_test_reset", test_reset_type);
        try compiler.func_map.put("nova_test_reset", test_reset_fn);

        const opt_fail_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const opt_fail_fn = core.LLVMAddFunction(compiler.module, "nova_optional_deref_fail", opt_fail_type);
        try compiler.func_map.put("nova_optional_deref_fail", opt_fail_fn);

        const panic_fn = core.LLVMAddFunction(compiler.module, "nova_panic", core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_panic", panic_fn);

        // nova_panic_cstr takes a plain C string (not a Nova string with an ARC header). Used by
        // codegen to emit runtime traps such as integer division by zero.
        const panic_cstr_fn = core.LLVMAddFunction(compiler.module, "nova_panic_cstr", core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_panic_cstr", panic_cstr_fn);

        const test_begin_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const test_begin_fn = core.LLVMAddFunction(compiler.module, "nova_test_begin", test_begin_type);
        try compiler.func_map.put("nova_test_begin", test_begin_fn);

        const test_fail_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const test_fail_fn = core.LLVMAddFunction(compiler.module, "nova_test_fail", test_fail_type);
        try compiler.func_map.put("nova_test_fail", test_fail_fn);

        const test_did_fail_type = core.LLVMFunctionType(compiler.i32_type, null, 0, 0);
        const test_did_fail_fn = core.LLVMAddFunction(compiler.module, "nova_test_did_fail", test_did_fail_type);
        try compiler.func_map.put("nova_test_did_fail", test_did_fail_fn);

        const test_fail_msg_type = core.LLVMFunctionType(compiler.ptr_type, null, 0, 0);
        const test_fail_msg_fn = core.LLVMAddFunction(compiler.module, "nova_test_fail_message", test_fail_msg_type);
        try compiler.func_map.put("nova_test_fail_message", test_fail_msg_fn);

        // The wolfSSL socket-TLS (nova_tls_*), TDS-TLS (nova_tds_tls_*), and memory-BIO (nova_mtls_*)
        // externs were removed in M13: TLS is now pure Nova (crypto/tls, net/tlsmembio, net/tls12bio).

        // nova_getenv/nova_setenv were retired in M6: std/env.nova reads and writes the environment
        // through the getenv/setenv bindings in os/sys.

        const argc_type = core.LLVMFunctionType(compiler.val_type, &one_param_ptr, 0, 0);
        try compiler.func_map.put("nova_arg_count", core.LLVMAddFunction(compiler.module, "nova_arg_count", argc_type));
        var argat_params = [_]types.LLVMTypeRef{compiler.val_type};
        const argat_type = core.LLVMFunctionType(compiler.val_type, &argat_params, 1, 0);
        try compiler.func_map.put("nova_arg_at", core.LLVMAddFunction(compiler.module, "nova_arg_at", argat_type));

        // SHA/MD5/HMAC/PBKDF2/random are now pure Nova (M11 stage A); only the MySQL auth-scramble and
        // All crypto (SHA/HMAC/PBKDF2/random/MySQL-scramble/RSA-OAEP) is pure Nova as of M11 stage B;
        // no wolfCrypt shim is declared here anymore.
        var getrandom_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i64_type };
        const getrandom_fn = core.LLVMAddFunction(compiler.module, "nova_getrandom", core.LLVMFunctionType(compiler.void_type, &getrandom_params, 2, 0));
        try compiler.func_map.put("nova_getrandom", getrandom_fn);

        // nova_gzip_compress/decompress retired: gzip is pure Nova (compress/deflate.nova).

        var process_spawn_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const process_spawn_type = core.LLVMFunctionType(compiler.ptr_type, &process_spawn_params, 2, 0);
        const process_spawn_fn = core.LLVMAddFunction(compiler.module, "nova_process_spawn", process_spawn_type);
        try compiler.func_map.put("nova_process_spawn", process_spawn_fn);

        var process_iso_params = [_]types.LLVMTypeRef{
            compiler.ptr_type, compiler.ptr_type, compiler.i64_type, compiler.ptr_type,
            compiler.ptr_type, compiler.i32_type, compiler.i32_type, compiler.i32_type,
        };
        const process_iso_type = core.LLVMFunctionType(compiler.ptr_type, &process_iso_params, 8, 0);
        const process_iso_fn = core.LLVMAddFunction(compiler.module, "nova_process_spawn_isolated", process_iso_type);
        try compiler.func_map.put("nova_process_spawn_isolated", process_iso_fn);

        var process_write_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const process_write_type = core.LLVMFunctionType(compiler.i32_type, &process_write_params, 2, 0);
        const process_write_fn = core.LLVMAddFunction(compiler.module, "nova_process_write_stdin", process_write_type);
        try compiler.func_map.put("nova_process_write_stdin", process_write_fn);

        var process_read_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const process_read_type = core.LLVMFunctionType(compiler.i32_type, &process_read_params, 3, 0);
        const process_read_fn = core.LLVMAddFunction(compiler.module, "nova_process_read_stdout", process_read_type);
        try compiler.func_map.put("nova_process_read_stdout", process_read_fn);

        const process_wait_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const process_wait_fn = core.LLVMAddFunction(compiler.module, "nova_process_wait", process_wait_type);
        try compiler.func_map.put("nova_process_wait", process_wait_fn);

        const process_pid_type = core.LLVMFunctionType(compiler.i64_type, &one_param_ptr, 1, 0);
        const process_pid_fn = core.LLVMAddFunction(compiler.module, "nova_process_pid", process_pid_type);
        try compiler.func_map.put("nova_process_pid", process_pid_fn);

        const process_trywait_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const process_trywait_fn = core.LLVMAddFunction(compiler.module, "nova_process_try_wait", process_trywait_type);
        try compiler.func_map.put("nova_process_try_wait", process_trywait_fn);

        var process_kill_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        const process_kill_type = core.LLVMFunctionType(compiler.i32_type, &process_kill_params, 2, 0);
        const process_kill_fn = core.LLVMAddFunction(compiler.module, "nova_process_kill", process_kill_type);
        try compiler.func_map.put("nova_process_kill", process_kill_fn);

        const process_free_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const process_free_fn = core.LLVMAddFunction(compiler.module, "nova_process_free", process_free_type);
        try compiler.func_map.put("nova_process_free", process_free_fn);

        const watcher_create_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const watcher_create_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_create", watcher_create_type);
        try compiler.func_map.put("nova_fs_watcher_create", watcher_create_fn);

        const watcher_next_event_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const watcher_next_event_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_next_event", watcher_next_event_type);
        try compiler.func_map.put("nova_fs_watcher_next_event", watcher_next_event_fn);

        const watcher_free_event_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const watcher_free_event_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_free_event", watcher_free_event_type);
        try compiler.func_map.put("nova_fs_watcher_free_event", watcher_free_event_fn);

        const watcher_close_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const watcher_close_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_close", watcher_close_type);
        try compiler.func_map.put("nova_fs_watcher_close", watcher_close_fn);

        const exit_type = core.LLVMFunctionType(compiler.void_type, &one_param_i32, 1, 0);
        const exit_fn = core.LLVMAddFunction(compiler.module, "nova_exit", exit_type);
        try compiler.func_map.put("nova_exit", exit_fn);

        const audit_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const audit_fn = core.LLVMAddFunction(compiler.module, "nova_arc_audit_report", audit_type);
        try compiler.func_map.put("nova_arc_audit_report", audit_fn);

        // File and directory runtime functions retired in M5: file and directory I/O moved to
        // Nova over os/sys (see src/std/io/file.nova and src/std/io/dir.nova), so the codegen no
        // longer declares nova_file_*/nova_dir_*. The only shim left is nova_open (variadic open),
        // declared in Nova as an extern("c") in os/sys.nova.

        var bytes_free_params = [_]types.LLVMTypeRef{compiler.val_type};
        const bytes_free_type = core.LLVMFunctionType(compiler.void_type, &bytes_free_params, 1, 0);
        const bytes_free_fn = core.LLVMAddFunction(compiler.module, "nova_bytes_free", bytes_free_type);
        try compiler.func_map.put("nova_bytes_free", bytes_free_fn);

        var ch_create_params = [_]types.LLVMTypeRef{compiler.i32_type};
        const ch_create_type = core.LLVMFunctionType(compiler.val_type, &ch_create_params, 1, 0);
        const ch_create_fn = core.LLVMAddFunction(compiler.module, "nova_channel_create", ch_create_type);
        try compiler.func_map.put("nova_channel_create", ch_create_fn);

        var ch_send_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const ch_send_type = core.LLVMFunctionType(compiler.void_type, &ch_send_params, 2, 0);
        const ch_send_fn = core.LLVMAddFunction(compiler.module, "nova_channel_send", ch_send_type);
        try compiler.func_map.put("nova_channel_send", ch_send_fn);

        var ch_recv_params = [_]types.LLVMTypeRef{compiler.val_type};
        const ch_recv_type = core.LLVMFunctionType(compiler.val_type, &ch_recv_params, 1, 0);
        const ch_recv_fn = core.LLVMAddFunction(compiler.module, "nova_channel_recv", ch_recv_type);
        try compiler.func_map.put("nova_channel_recv", ch_recv_fn);

        const void_type = compiler.void_type;
        const val_type = compiler.val_type;

        const mutex_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const mutex_create_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_create", mutex_create_type);
        try compiler.func_map.put("nova_mutex_create", mutex_create_fn);

        try compiler.func_map.put("nova_thread_id", core.LLVMAddFunction(compiler.module, "nova_thread_id", mutex_create_type));
        try compiler.func_map.put("nova_worker_count", core.LLVMAddFunction(compiler.module, "nova_worker_count", mutex_create_type));

        const spin_create_fn = core.LLVMAddFunction(compiler.module, "nova_spin_create", mutex_create_type);
        try compiler.func_map.put("nova_spin_create", spin_create_fn);
        var spin_p = [_]types.LLVMTypeRef{val_type};
        const spin_lu_type = core.LLVMFunctionType(void_type, &spin_p, 1, 0);
        try compiler.func_map.put("nova_spin_lock", core.LLVMAddFunction(compiler.module, "nova_spin_lock", spin_lu_type));
        try compiler.func_map.put("nova_spin_unlock", core.LLVMAddFunction(compiler.module, "nova_spin_unlock", spin_lu_type));

        try compiler.func_map.put("nova_pin_next_coro", core.LLVMAddFunction(compiler.module, "nova_pin_next_coro", spin_lu_type));

        try compiler.func_map.put("nova_trace_msg", core.LLVMAddFunction(compiler.module, "nova_trace_msg", spin_lu_type));
        try compiler.func_map.put("nova_trace_enabled", core.LLVMAddFunction(compiler.module, "nova_trace_enabled", mutex_create_type));
        var trace_kv_p = [_]types.LLVMTypeRef{ val_type, val_type };
        const trace_kv_type = core.LLVMFunctionType(void_type, &trace_kv_p, 2, 0);
        try compiler.func_map.put("nova_trace_kv", core.LLVMAddFunction(compiler.module, "nova_trace_kv", trace_kv_type));

        var reactor_resume_p = [_]types.LLVMTypeRef{val_type};
        const reactor_resume_type = core.LLVMFunctionType(val_type, &reactor_resume_p, 1, 0);
        try compiler.func_map.put("nova_reactor_resume", core.LLVMAddFunction(compiler.module, "nova_reactor_resume", reactor_resume_type));
        // nova_set_reuseport retired in M6: sys.setReusePort is pure Nova over setsockopt.

        var run_reactors_p = [_]types.LLVMTypeRef{ val_type, val_type };
        const run_reactors_type = core.LLVMFunctionType(void_type, &run_reactors_p, 2, 0);
        try compiler.func_map.put("nova_run_reactors", core.LLVMAddFunction(compiler.module, "nova_run_reactors", run_reactors_type));

        var detach_p = [_]types.LLVMTypeRef{val_type};
        const detach_type = core.LLVMFunctionType(void_type, &detach_p, 1, 0);
        try compiler.func_map.put("nova_reactor_detach", core.LLVMAddFunction(compiler.module, "nova_reactor_detach", detach_type));

        var set_current_p = [_]types.LLVMTypeRef{val_type};
        const set_current_type = core.LLVMFunctionType(void_type, &set_current_p, 1, 0);
        try compiler.func_map.put("nova_reactor_set_current", core.LLVMAddFunction(compiler.module, "nova_reactor_set_current", set_current_type));

        const current_type = core.LLVMFunctionType(val_type, null, 0, 0);
        try compiler.func_map.put("nova_reactor_current", core.LLVMAddFunction(compiler.module, "nova_reactor_current", current_type));

        var set_timer_p = [_]types.LLVMTypeRef{ val_type, val_type };
        const set_timer_type = core.LLVMFunctionType(void_type, &set_timer_p, 2, 0);
        try compiler.func_map.put("nova_reactor_set_timer", core.LLVMAddFunction(compiler.module, "nova_reactor_set_timer", set_timer_type));

        var cancel_timer_p = [_]types.LLVMTypeRef{val_type};
        const cancel_timer_type = core.LLVMFunctionType(void_type, &cancel_timer_p, 1, 0);
        try compiler.func_map.put("nova_reactor_cancel_timer", core.LLVMAddFunction(compiler.module, "nova_reactor_cancel_timer", cancel_timer_type));

        const batch_begin_type = core.LLVMFunctionType(void_type, null, 0, 0);
        try compiler.func_map.put("nova_reactor_batch_begin", core.LLVMAddFunction(compiler.module, "nova_reactor_batch_begin", batch_begin_type));

        const mono_ms_type = core.LLVMFunctionType(val_type, null, 0, 0);
        try compiler.func_map.put("nova_mono_ms", core.LLVMAddFunction(compiler.module, "nova_mono_ms", mono_ms_type));

        var wake_reg_p = [_]types.LLVMTypeRef{ val_type, val_type };
        const wake_reg_type = core.LLVMFunctionType(void_type, &wake_reg_p, 2, 0);
        try compiler.func_map.put("nova_reactor_wake_register", core.LLVMAddFunction(compiler.module, "nova_reactor_wake_register", wake_reg_type));

        var post_p = [_]types.LLVMTypeRef{ val_type, val_type };
        const post_type = core.LLVMFunctionType(void_type, &post_p, 2, 0);
        try compiler.func_map.put("nova_reactor_post", core.LLVMAddFunction(compiler.module, "nova_reactor_post", post_type));

        var drain_p = [_]types.LLVMTypeRef{val_type};
        const drain_type = core.LLVMFunctionType(val_type, &drain_p, 1, 0);
        try compiler.func_map.put("nova_reactor_drain_one", core.LLVMAddFunction(compiler.module, "nova_reactor_drain_one", drain_type));

        const evfilt_user_type = core.LLVMFunctionType(val_type, null, 0, 0);
        try compiler.func_map.put("nova_evfilt_user", core.LLVMAddFunction(compiler.module, "nova_evfilt_user", evfilt_user_type));

        const void_noarg_type = core.LLVMFunctionType(void_type, null, 0, 0);
        try compiler.func_map.put("nova_hold_all_reactors", core.LLVMAddFunction(compiler.module, "nova_hold_all_reactors", void_noarg_type));

        var one_val_param = [_]types.LLVMTypeRef{val_type};
        const mutex_lock_type = core.LLVMFunctionType(void_type, &one_val_param, 1, 0);
        const mutex_lock_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_lock", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_lock", mutex_lock_fn);

        const mutex_unlock_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_unlock", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_unlock", mutex_unlock_fn);

        const cond_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const cond_create_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_create", cond_create_type);
        try compiler.func_map.put("nova_condvar_create", cond_create_fn);

        var two_val_params = [_]types.LLVMTypeRef{ val_type, val_type };
        const cond_wait_type = core.LLVMFunctionType(void_type, &two_val_params, 2, 0);
        const cond_wait_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_wait", cond_wait_type);
        try compiler.func_map.put("nova_condvar_wait", cond_wait_fn);

        const cond_signal_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_signal", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_signal", cond_signal_fn);

        const cond_broadcast_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_broadcast", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_broadcast", cond_broadcast_fn);

        const rw_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const rw_create_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_create", rw_create_type);
        try compiler.func_map.put("nova_rwlock_create", rw_create_fn);

        const rw_acq_r_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_acquire_read", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_acquire_read", rw_acq_r_fn);

        const rw_rel_r_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_release_read", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_release_read", rw_rel_r_fn);

        const rw_acq_w_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_acquire_write", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_acquire_write", rw_acq_w_fn);

        const rw_rel_w_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_release_write", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_release_write", rw_rel_w_fn);

        var bytes_alloc_p_params = [_]types.LLVMTypeRef{compiler.val_type};
        const bytes_alloc_p_type = core.LLVMFunctionType(compiler.val_type, &bytes_alloc_p_params, 1, 0);
        const bytes_alloc_p_fn = core.LLVMAddFunction(compiler.module, "nova_bytes_alloc_persistent", bytes_alloc_p_type);
        try compiler.func_map.put("nova_bytes_alloc_persistent", bytes_alloc_p_fn);

        const ch_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_channel_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_channel_destroy", ch_destroy_fn);

        const mutex_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_destroy", mutex_destroy_fn);

        const cond_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_destroy", cond_destroy_fn);

        const rw_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_destroy", rw_destroy_fn);

        var retain_params = [_]types.LLVMTypeRef{compiler.val_type};
        const retain_fn_type = core.LLVMFunctionType(compiler.void_type, &retain_params, 1, 0);
        const retain_fn = core.LLVMAddFunction(compiler.module, "nova_retain", retain_fn_type);
        try compiler.func_map.put("nova_retain", retain_fn);

        const ptr_type = core.LLVMPointerType(compiler.void_type, 0);
        var release_params = [_]types.LLVMTypeRef{compiler.val_type, ptr_type};
        const release_fn_type = core.LLVMFunctionType(compiler.void_type, &release_params, 2, 0);
        const release_fn = core.LLVMAddFunction(compiler.module, "nova_release", release_fn_type);
        try compiler.func_map.put("nova_release", release_fn);
    }

    if (!is_wasm) {

        {
            var to_p = [_]types.LLVMTypeRef{compiler.ptr_type};
            const to_t = core.LLVMFunctionType(compiler.ptr_type, &to_p, 1, 0);
            try compiler.func_map.put("nova_ffi_to_cstr", core.LLVMAddFunction(compiler.module, "nova_ffi_to_cstr", to_t));
            var from_p = [_]types.LLVMTypeRef{compiler.ptr_type};
            const from_t = core.LLVMFunctionType(compiler.ptr_type, &from_p, 1, 0);
            try compiler.func_map.put("nova_ffi_from_cstr", core.LLVMAddFunction(compiler.module, "nova_ffi_from_cstr", from_t));
            var free_p = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
            const free_t = core.LLVMFunctionType(compiler.void_type, &free_p, 2, 0);
            try compiler.func_map.put("nova_ffi_free_cstr", core.LLVMAddFunction(compiler.module, "nova_ffi_free_cstr", free_t));
        }
        for (program.declarations) |decl| {
            if (decl != .fn_decl) continue;
            const fd = decl.fn_decl;
            if (fd.extern_lib == null) continue;

            try compiler.ffi_externs.put(fd.name, fd);
            if (compiler.func_map.contains(fd.name)) continue;

            const param_ll = try allocator.alloc(types.LLVMTypeRef, fd.params.len);
            defer allocator.free(param_ll);
            for (fd.params, 0..) |p, idx| {
                param_ll[idx] = if (p.type_name) |t|
                    ffiCType(&compiler, try compiler.typeRefToString(t))
                else
                    compiler.i64_type;
            }
            const ret_ll = if (fd.ret_type) |t|
                ffiCType(&compiler, try compiler.typeRefToString(t))
            else
                compiler.void_type;

            const fn_ty = core.LLVMFunctionType(ret_ll, param_ll.ptr, @intCast(fd.params.len), 0);
            const name_z = try allocator.dupeZ(u8, fd.name);
            defer allocator.free(name_z);
            const f = core.LLVMAddFunction(compiler.module, name_z.ptr, fn_ty);
            try compiler.func_map.put(fd.name, f);
        }
    }

    for (compiler.functions.items) |func| {
        var local_types = std.StringHashMap([]const u8).init(allocator);
        var local_type_ids = std.StringHashMap(sema_types.TypeId).init(allocator);

        compiler.current_function_name = func.name;
        compiler.current_local_types = &local_types;
        compiler.current_local_type_ids = &local_type_ids;
        compiler.current_struct_name = null;
        compiler.current_module_prefix = null;

        compiler.current_instantiation = func.instantiation;
        compiler.current_instantiation_id = func.instantiation_id orelse (if (func.instantiation) |inst| sema_mono.live_inst_ids.get(inst) else null);

        if (func.instantiation) |inst| {

            compiler.current_struct_name = getStructBaseName(inst);
            try local_types.put("self", inst);
        } else {
            const underscore_pos = std.mem.indexOfScalar(u8, func.name, '_');
            if (underscore_pos) |pos| {
                const struct_name = func.name[0..pos];
                if (compiler.isStructType(struct_name)) {
                    compiler.current_struct_name = struct_name;
                    try local_types.put("self", struct_name);
                }
            }
        }

        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                var decl_name = decl.fn_decl.name;
                var decl_name_owned = false;
                if (compiler.getStructPrefix(decl.fn_decl)) |prefix| {
                    decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, decl.fn_decl.name });
                    decl_name_owned = true;
                } else if (compiler.getModulePrefix(decl.fn_decl.span)) |mod_prefix| {
                    defer allocator.free(mod_prefix);
                    if (LlvmCompiler.isAlreadyNamespaced(decl.fn_decl.name)) {
                        decl_name = decl.fn_decl.name;
                    } else {
                        decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ mod_prefix, decl.fn_decl.name });
                        decl_name_owned = true;
                    }
                }
                const dn_match = std.mem.eql(u8, decl_name, func.name);
                if (decl_name_owned) allocator.free(decl_name);
                if (dn_match) {
                    compiler.current_module_prefix = compiler.getModulePrefix(decl.fn_decl.span);
                    for (decl.fn_decl.params) |p| {
                        if (p.type_name) |t| {
                            const p_type = try compiler.typeRefToString(t);
                            try local_types.put(p.name, p_type);
                            // Also record the param's TypeId (optionality PRESERVED, unlike typeRefToString
                            // which drops `.optional`). This lets value-use codegen recognise a value-optional
                            // PARAMETER as a boxed slot and unbox it on `??`/comparison irrespective of flow
                            // narrowing -- the C10 fix (uniform boxed value-optional param ABI).
                            if (compiler.tidForTypeRef(t)) |tid| try local_type_ids.put(p.name, tid);
                        }
                    }
                    break;
                }
            } else if (decl == .struct_decl) {
                const s = decl.struct_decl;
                var matched = false;
                for (s.methods) |method| {
                    const fn_decl = method.decl;

                    const owner = func.instantiation orelse compiler.scopedStructName(s.name, s.span.file);
                    const decl_name = try compiler.methodSymbol(owner, fn_decl.name);
                    defer allocator.free(decl_name);

                    const is_spec = func.instantiation_id != null and
                        std.mem.startsWith(u8, func.name, decl_name) and
                        func.name.len > decl_name.len + 2 and
                        std.mem.eql(u8, func.name[decl_name.len .. decl_name.len + 2], "__");
                    if (std.mem.eql(u8, decl_name, func.name) or is_spec) {
                        compiler.current_module_prefix = compiler.getModulePrefix(s.span);
                        for (fn_decl.params) |p| {
                            if (p.type_name) |t| {

                                const p_type = try compiler.typeRefToString(t);
                                try local_types.put(p.name, p_type);
                                if (compiler.tidForTypeRef(t)) |tid| try local_type_ids.put(p.name, tid);
                            }
                        }
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            } else if (decl == .enum_decl) {
                const e = decl.enum_decl;
                var matched = false;
                for (e.methods) |method| {
                    const fn_decl = method.decl;
                    const decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ compiler.scopedStructName(e.name, e.span.file), fn_decl.name });
                    defer allocator.free(decl_name);

                    if (std.mem.eql(u8, decl_name, func.name)) {
                        compiler.current_module_prefix = compiler.getModulePrefix(e.span);
                        for (fn_decl.params) |p| {
                            if (p.type_name) |t| {
                                const p_type = try compiler.typeRefToString(t);
                                try local_types.put(p.name, p_type);
                                if (compiler.tidForTypeRef(t)) |tid| try local_type_ids.put(p.name, tid);
                            }
                        }
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            }
        }

        if (std.mem.startsWith(u8, func.name, "__lambda_")) {
            if (compiler.lambda_parents.get(func.name)) |parent| {
                const lambda_underscore_pos = std.mem.indexOfScalar(u8, parent, '_');
                if (lambda_underscore_pos) |pos| {
                    const prefix = parent[0..pos];
                    if (compiler.isStructType(prefix)) {
                        if (compiler.structs.get(prefix)) |s| {
                            compiler.current_module_prefix = compiler.getModulePrefix(s.span);
                        }
                    } else {
                        compiler.current_module_prefix = prefix;
                    }
                }
            }

            const decl_types = compiler.lambda_param_types.get(func.name);
            for (func.param_names, 0..) |param, pidx| {
                if (std.mem.eql(u8, param, "__env")) {
                    try local_types.put(param, "ptr");
                    continue;
                }

                var typ: []const u8 = "i32";
                if (decl_types) |dts| {
                    const user_idx = pidx - 1;
                    if (user_idx < dts.len) {
                        if (dts[user_idx]) |t| typ = t;
                    }
                }
                try local_types.put(param, typ);
            }
        }

        try compiler.collectLocalVarTypes(&local_types, func.body);
        try compiler.function_local_types.put(func.name, local_types);
        try compiler.function_local_type_ids.put(func.name, local_type_ids);
    }
    compiler.current_function_name = null;
    compiler.current_local_types = null;
    compiler.current_local_type_ids = null;
    compiler.current_struct_name = null;
    compiler.current_module_prefix = null;

    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var write_idx: usize = 0;
        for (compiler.functions.items) |func| {
            if (seen.contains(func.name)) continue;
            try seen.put(func.name, {});
            compiler.functions.items[write_idx] = func;
            write_idx += 1;
        }
        compiler.functions.shrinkRetainingCapacity(write_idx);
    }

    for (compiler.functions.items) |func| {
        const params = try allocator.alloc(types.LLVMTypeRef, func.param_count);
        defer allocator.free(params);
        @memset(params, compiler.val_type);
        // Array params flow as `ptr` (not the i64 word): the pointer arrives as a clean function
        // argument with provenance, so LLVM can disambiguate arrays and vectorize/hoist the loop. (No
        // `noalias` -- it would be unsound if the same array is passed to two params; LLVM still
        // vectorizes via a runtime overlap check.) The caller inttoptr's the i64 array value at the
        // call site (existing arg coercion). Return type stays the word for now.
        if (compiler.function_local_types.get(func.name)) |lt| {
            for (0..func.param_count) |pi| {
                if (lt.get(func.param_names[pi])) |tn| {
                    if (std.mem.indexOfScalar(u8, tn, '[') != null) params[pi] = compiler.ptr_type;
                }
            }
        }

        const is_void = std.mem.eql(u8, func.return_type, "void");
        const is_main = std.mem.eql(u8, func.name, "main");

        const is_async_native = func.is_async and !is_wasm;

        const ret_t = if (is_main) compiler.val_type else if (is_async_native) compiler.val_type else if (is_void) compiler.void_type else compiler.val_type;

        const fn_type = core.LLVMFunctionType(ret_t, params.ptr, @intCast(func.param_count), 0);
        const real_name = if (is_main) "__nova_main" else func.name;
        const fn_name_z = try allocator.dupeZ(u8, real_name);
        defer allocator.free(fn_name_z);
        const fn_val = core.LLVMAddFunction(compiler.module, fn_name_z.ptr, fn_type);
        try compiler.func_map.put(func.name, fn_val);

        if (is_async_native) {

            const kind = core.LLVMGetEnumAttributeKindForName("presplitcoroutine", "presplitcoroutine".len);
            const attr = core.LLVMCreateEnumAttribute(core.LLVMGetGlobalContext(), kind, 0);
            core.LLVMAddAttributeAtIndex(fn_val, std.math.maxInt(c_uint), attr);
            try compiler.async_fns.put(func.name, {});
        }
    }

    {
        var reordered = std.ArrayListUnmanaged(FunctionInfo).empty;
        defer reordered.deinit(allocator);
        for (compiler.functions.items) |f| if (!f.erased_generic) try reordered.append(allocator, f);
        for (compiler.functions.items) |f| if (f.erased_generic) try reordered.append(allocator, f);
        @memcpy(compiler.functions.items, reordered.items);
    }

    memPhase("before body emit");
    for (compiler.functions.items) |func| {
        const fn_val = compiler.func_map.get(func.name).?;

        // Skip a use-less erased fallback -- EXCEPT for RawBuffer, the universal container backing
        // (M-10). An erased container body (e.g. erased List_init) constructs an erased RawBuffer_init
        // whose use is only created once the container body is emitted; if RawBuffer was visited first
        // it would be skipped here and left undefined at link. RawBuffer's erased bodies codegen
        // cleanly, so emit them unconditionally (internal linkage); globalDCE drops them if the whole
        // erased chain is unreachable. Everything else keeps the no-use skip (some erased bodies -- a
        // closure in an erased generic method, etc. -- do not codegen when erased and must stay elided).
        const is_rawbuf_backing = std.mem.startsWith(u8, func.name, "RawBuffer_");
        if (func.erased_generic and !is_rawbuf_backing and core.LLVMGetFirstUse(fn_val) == null) continue;

        if (func.erased_generic and !t6_split) core.LLVMSetLinkage(fn_val, types.LLVMLinkage.LLVMInternalLinkage);

        compiler.current_function_name = func.name;
        compiler.current_local_types = compiler.function_local_types.getPtr(func.name).?;
        compiler.current_local_type_ids = compiler.function_local_type_ids.getPtr(func.name).?;
        compiler.current_param_names = func.param_names;

        compiler.current_struct_name = null;
        compiler.current_module_prefix = null;

        compiler.current_instantiation = func.instantiation;
        compiler.current_instantiation_id = func.instantiation_id orelse (if (func.instantiation) |inst| sema_mono.live_inst_ids.get(inst) else null);

        if (func.instantiation) |inst| {
            compiler.current_struct_name = getStructBaseName(inst);
        } else {
            const underscore_pos = std.mem.indexOfScalar(u8, func.name, '_');
            if (underscore_pos) |pos| {
                const struct_name = func.name[0..pos];
                if (compiler.isStructType(struct_name)) {
                    compiler.current_struct_name = struct_name;
                }
            }
        }

        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                var decl_name = decl.fn_decl.name;
                var decl_name_owned = false;
                if (compiler.getStructPrefix(decl.fn_decl)) |prefix| {
                    decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, decl.fn_decl.name });
                    decl_name_owned = true;
                } else if (compiler.getModulePrefix(decl.fn_decl.span)) |mod_prefix| {
                    defer allocator.free(mod_prefix); // getModulePrefix returns owned memory
                    if (LlvmCompiler.isAlreadyNamespaced(decl.fn_decl.name)) {
                        decl_name = decl.fn_decl.name;
                    } else {
                        decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ mod_prefix, decl.fn_decl.name });
                        decl_name_owned = true;
                    }
                }
                const dn_matches = std.mem.eql(u8, decl_name, func.name);
                if (decl_name_owned) allocator.free(decl_name);
                if (dn_matches) {
                    compiler.current_module_prefix = compiler.getModulePrefix(decl.fn_decl.span);
                    break;
                }
            } else if (decl == .struct_decl) {
                const s = decl.struct_decl;
                var matched = false;
                for (s.methods) |method| {
                    const fn_decl = method.decl;
                    const owner = func.instantiation orelse compiler.scopedStructName(s.name, s.span.file);
                    const decl_name = try compiler.methodSymbol(owner, fn_decl.name);
                    defer allocator.free(decl_name);

                    if (std.mem.eql(u8, decl_name, func.name)) {
                        compiler.current_module_prefix = compiler.getModulePrefix(s.span);
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            } else if (decl == .enum_decl) {
                const e = decl.enum_decl;
                var matched = false;
                for (e.methods) |method| {
                    const fn_decl = method.decl;
                    const decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ compiler.scopedStructName(e.name, e.span.file), fn_decl.name });
                    defer allocator.free(decl_name);

                    if (std.mem.eql(u8, decl_name, func.name)) {
                        compiler.current_module_prefix = compiler.getModulePrefix(e.span);
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            }
        }

        compiler.locals.clearRetainingCapacity();

        const entry_bb = core.LLVMAppendBasicBlock(fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(compiler.builder, entry_bb);

        // DWARF (Gap 4): attach this function's DISubprogram + set it as the active debug scope, so
        // statement debug locations (set during body emission) resolve to it. Self-guards on debug mode.
        // The function line comes from the first statement (reliably inside the body) rather than the
        // block span, which points past the closing brace for some declarations.
        const fn_dbg_line = if (func.body.statements.len > 0)
            stmtSpan(func.body.statements[0]).line
        else
            func.body.span.line;
        compiler.beginFunctionDebug(fn_val, func.name, func.source_file, fn_dbg_line);

        // (The HIR/MIR/LIR LLVM-emit optimiser was scrapped 2026-08-16 -- it delivered ~0 optimisation over
        // AST+LLVM O3; see docs/design/sil-arc-optimiser-direction.md. Every function is compiled from the
        // AST below, as it always effectively was.)

        {
            var iter = compiler.current_saved_captures.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            compiler.current_saved_captures.clearRetainingCapacity();
        }

        for (0..func.param_count) |idx| {
            const arg_name = func.param_names[idx];
            const arg_val = core.LLVMGetParam(fn_val, @intCast(idx));

            var alloca_val: types.LLVMValueRef = undefined;

            var slot_ty = compiler.slotTypeForLocalId(
                if (compiler.current_local_types) |lt| lt.get(arg_name) else null,
                if (compiler.current_local_type_ids) |ids| ids.get(arg_name) else null,
            );
            const key = try std.fmt.allocPrint(allocator, "{s}_{s}", .{func.name, arg_name});
            defer allocator.free(key);
            if (compiler.captured_globals.get(key)) |global_var| {
                slot_ty = compiler.val_type;
                alloca_val = global_var;
                const backup_slot = core.LLVMBuildAlloca(compiler.builder, compiler.val_type, "backup");
                const current_val = core.LLVMBuildLoad2(compiler.builder, compiler.val_type, global_var, "backup_load");
                _ = core.LLVMBuildStore(compiler.builder, current_val, backup_slot);
                const key_dup = try allocator.dupe(u8, key);
                try compiler.current_saved_captures.put(key_dup, backup_slot);
            } else {
                const arg_name_z = try allocator.dupeZ(u8, arg_name);
                defer allocator.free(arg_name_z);
                alloca_val = core.LLVMBuildAlloca(compiler.builder, slot_ty, arg_name_z.ptr);
            }
            _ = core.LLVMBuildStore(compiler.builder, compiler.coerceToSlotType(arg_val, slot_ty), alloca_val);
            try compiler.locals.put(arg_name, alloca_val);
            // DWARF (Gap 4, item 2): declare the parameter so the debugger shows its value.
            compiler.declareLocalVar(alloca_val, arg_name, if (compiler.current_local_types) |lt| lt.get(arg_name) else null, slot_ty);
        }

        var local_names = std.ArrayList([]const u8).empty;
        defer local_names.deinit(allocator);
        try compiler.collectLocalVarNames(&local_names, func.body);

        for (local_names.items) |name| {
            if (compiler.locals.contains(name)) continue;

            var alloca_val: types.LLVMValueRef = undefined;

            var slot_ty = compiler.slotTypeForLocalId(
                if (compiler.current_local_types) |lt| lt.get(name) else null,
                if (compiler.current_local_type_ids) |ids| ids.get(name) else null,
            );
            const key = try std.fmt.allocPrint(allocator, "{s}_{s}", .{func.name, name});
            defer allocator.free(key);
            if (compiler.captured_globals.get(key)) |global_var| {
                slot_ty = compiler.val_type;
                alloca_val = global_var;
                const backup_slot = core.LLVMBuildAlloca(compiler.builder, compiler.val_type, "backup");
                const current_val = core.LLVMBuildLoad2(compiler.builder, compiler.val_type, global_var, "backup_load");
                _ = core.LLVMBuildStore(compiler.builder, current_val, backup_slot);
                const key_dup = try allocator.dupe(u8, key);
                try compiler.current_saved_captures.put(key_dup, backup_slot);
            } else {
                const name_z = try allocator.dupeZ(u8, name);
                defer allocator.free(name_z);
                alloca_val = core.LLVMBuildAlloca(compiler.builder, slot_ty, name_z.ptr);
            }

            // Zero-init the slot with the right kind of null: 0.0 for double, 0 for ints, and a real
            // null/zeroinitializer for ptr (array) and vector slots -- ConstInt on a non-int type emits
            // an invalid `i0 0` that poisons the optimizer (blocks vectorization).
            const zk = core.LLVMGetTypeKind(slot_ty);
            const zero = if (zk == .LLVMDoubleTypeKind)
                core.LLVMConstReal(slot_ty, 0)
            else if (zk == .LLVMIntegerTypeKind)
                core.LLVMConstInt(slot_ty, 0, 0)
            else
                core.LLVMConstNull(slot_ty);
            _ = core.LLVMBuildStore(compiler.builder, zero, alloca_val);
            try compiler.locals.put(name, alloca_val);
            // DWARF (Gap 4, item 2): declare the local so the debugger shows its value.
            compiler.declareLocalVar(alloca_val, name, if (compiler.current_local_types) |lt| lt.get(name) else null, slot_ty);
        }

        const is_main = std.mem.eql(u8, func.name, "main");
        if (is_main and !is_wasm) {
            const malloc_val = compiler.func_map.get("malloc").?;
            const malloc_t = core.LLVMGlobalGetValueType(malloc_val);
            const heap_size = core.LLVMConstInt(compiler.val_type, 16 * 1024 * 1024, 0);
            var malloc_args = [_]types.LLVMValueRef{heap_size};
            const heap_alloc_ptr = core.LLVMBuildCall2(compiler.builder, malloc_t, malloc_val, &malloc_args, 1, "heap_alloc");
            const heap_alloc_int = core.LLVMBuildPtrToInt(compiler.builder, heap_alloc_ptr, compiler.val_type, "heap_alloc_int");
            _ = core.LLVMBuildStore(compiler.builder, heap_alloc_int, compiler.heap_ptr.?);
        }

        compiler.current_async_promise = null;
        compiler.current_async_final_bb = null;
        compiler.current_async_hdl = null;
        compiler.current_async_suspend_bb = null;
        compiler.current_async_cleanup_bb = null;
        var coro_ctx: ?CoroCtx = null;
        if (func.is_async and !is_wasm) {
            coro_ctx = try emitCoroPrologue(&compiler, fn_val);
            compiler.current_async_promise = coro_ctx.?.promise;
            compiler.current_async_final_bb = coro_ctx.?.final_bb;
            compiler.current_async_hdl = coro_ctx.?.hdl;
            compiler.current_async_suspend_bb = coro_ctx.?.suspend_bb;
            compiler.current_async_cleanup_bb = coro_ctx.?.cleanup_bb;
        }

        try compiler.scopes.append(allocator, Scope{ .deferred_statements = std.ArrayList(ast.Expression).empty });
        for (func.body.statements) |stmt| {
            try compiler.compileStatement(stmt, func);
        }

        if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(compiler.builder)) == null) {
            var scope = compiler.scopes.pop().?;
            var idx = scope.deferred_statements.items.len;
            while (idx > 0) {
                idx -= 1;
                _ = try compiler.compileExpression(scope.deferred_statements.items[idx]);
            }
            scope.deferred_statements.deinit(allocator);

            try compiler.releaseLocalVariables();

            if (coro_ctx) |cc| {

                _ = core.LLVMBuildBr(compiler.builder, cc.final_bb);
            } else if (is_main) {
                _ = core.LLVMBuildRet(compiler.builder, core.LLVMConstInt(compiler.val_type, 0, 0));
            } else {
                const is_constructor = std.mem.endsWith(u8, func.name, "_new") or std.mem.endsWith(u8, func.name, "_init");
                if (is_constructor) {
                    const is_void = std.mem.eql(u8, func.return_type, "void");
                    if (is_void) {
                        _ = core.LLVMBuildRetVoid(compiler.builder);
                    } else if (compiler.locals.get("self")) |self_alloca| {
                        const self_val = core.LLVMBuildLoad2(compiler.builder, compiler.val_type, self_alloca, "self_val");
                        _ = core.LLVMBuildRet(compiler.builder, self_val);
                    } else {
                        _ = core.LLVMBuildRetVoid(compiler.builder);
                    }
                } else {
                    const is_void = std.mem.eql(u8, func.return_type, "void");
                    if (is_void) {
                        _ = core.LLVMBuildRetVoid(compiler.builder);
                    } else {
                        _ = core.LLVMBuildRet(compiler.builder, core.LLVMConstInt(compiler.val_type, 0, 0));
                    }
                }
            }
        } else {
            if (compiler.scopes.items.len > 0) {
                var scope = compiler.scopes.pop().?;
                scope.deferred_statements.deinit(allocator);
            }
        }

        if (coro_ctx) |cc| {
            emitCoroEpilogue(&compiler, fn_val, cc);
            compiler.current_async_promise = null;
            compiler.current_async_final_bb = null;
            compiler.current_async_hdl = null;
            compiler.current_async_suspend_bb = null;
            compiler.current_async_cleanup_bb = null;
        }

        for (compiler.scopes.items) |*scope| {
            scope.deferred_statements.deinit(allocator);
        }
        compiler.scopes.clearRetainingCapacity();
        compiler.current_param_names = null;
        compiler.current_function_name = null;
    }

    if (compiler.coverage_enabled) {
        if (compiler.cov_registry) |*reg| {
            try reg.writeMetadataFile();
            const N = reg.blocks.items.len;
            if (N > 0) {
                const counters_glob = core.LLVMGetNamedGlobal(compiler.module, "__nova_cov_counters") orelse blk: {
                    const ptr_to_ptr = core.LLVMPointerType(compiler.i64_type, 0);
                    const glob = core.LLVMAddGlobal(compiler.module, ptr_to_ptr, "__nova_cov_counters");
                    core.LLVMSetLinkage(glob, types.LLVMLinkage.LLVMExternalLinkage);
                    break :blk glob;
                };
                _ = counters_glob;

                if (compiler.func_map.get("main")) |main_fn| {
                    const entry_bb = core.LLVMGetEntryBasicBlock(main_fn);
                    const cov_builder = core.LLVMCreateBuilder();
                    defer core.LLVMDisposeBuilder(cov_builder);

                    const first_inst = core.LLVMGetFirstInstruction(entry_bb);
                    if (first_inst) |inst| {
                        core.LLVMPositionBuilder(cov_builder, entry_bb, inst);
                    } else {
                        core.LLVMPositionBuilderAtEnd(cov_builder, entry_bb);
                    }

                    const init_fn = if (compiler.func_map.get("nova_coverage_init")) |f| f else blk: {
                        var arg_types = [_]types.LLVMTypeRef{compiler.i64_type};
                        const fn_type = core.LLVMFunctionType(compiler.void_type, &arg_types, 1, 0);
                        const f = core.LLVMAddFunction(compiler.module, "nova_coverage_init", fn_type);
                        try compiler.func_map.put("nova_coverage_init", f);
                        break :blk f;
                    };
                    const init_fn_t = core.LLVMGlobalGetValueType(init_fn);
                    var init_args = [_]types.LLVMValueRef{core.LLVMConstInt(compiler.i64_type, @intCast(N), 0)};
                    _ = core.LLVMBuildCall2(cov_builder, init_fn_t, init_fn, &init_args, 1, "");
                }
            }
        }
    }

    if (t6_split and !is_wasm) {
        if (objs_out) |objs| {
            try compileSplitEmit(&compiler, allocator, output_path, is_release, objs, cache_dir, io);
            return;
        }
    }

    try emitModule(&compiler, allocator, compiler.module, output_path, is_wasm, is_release, "__nova_test.ll");
}

fn compileSplitEmit(
    compiler: *LlvmCompiler,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    is_release: bool,
    objs: *std.ArrayList([]const u8),
    cache_dir: ?[]const u8,
    io: std.Io,
) !void {

    {
        var g = core.LLVMGetFirstGlobal(compiler.module);
        while (g != null) : (g = core.LLVMGetNextGlobal(g)) {
            const nm = std.mem.span(core.LLVMGetValueName(g));
            if (std.mem.eql(u8, nm, "heap_ptr") or std.mem.startsWith(u8, nm, "_vtable_")) {
                core.LLVMSetLinkage(g, types.LLVMLinkage.LLVMLinkOnceODRLinkage);
            }
        }
    }

    memPhase("after body emit + vtables");

    // Symbol-name -> owning source file, built BEFORE any pruning while every func_map value is still
    // live. Keys are duped because demand pruning below deletes the dead functions (and with them the
    // LLVM name strings we'd otherwise alias).
    var sym_to_file = std.StringHashMap([]const u8).init(allocator);
    defer {
        var kit = sym_to_file.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        sym_to_file.deinit();
    }
    for (compiler.functions.items) |func| {
        const v = compiler.func_map.get(func.name) orelse continue;
        const sym = std.mem.span(core.LLVMGetValueName(v));
        const file = if (func.source_file.len > 0) func.source_file else "<uncategorized>";
        if (sym_to_file.contains(sym)) continue;
        try sym_to_file.put(try allocator.dupe(u8, sym), file);
    }

    // Demand pruning (task #205): remove functions unreachable from __nova_main, so a wholly-unused
    // source file emits no object. T6 needs surviving functions to keep their ORIGINAL (external)
    // linkage for cross-object references, so this is two-phase: (1) compute the reachable set on a
    // throwaway clone by internalizing everything but the entry and running globaldce; (2) on the real
    // module, internalize only the DEAD functions and globaldce them away, leaving reachable functions'
    // linkage untouched. globaldce is address-aware, so pointer-referenced coroutine/callback bodies
    // reachable from main are retained. After this, func_map holds dangling refs to deleted functions
    // -- everything downstream reads the MODULE, not func_map.
    if (pruneEnabled()) {
        var reachable = std.StringHashMap(void).init(allocator);
        defer {
            var kit = reachable.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            reachable.deinit();
        }
        {
            const clone = core.LLVMCloneModule(compiler.module);
            defer core.LLVMDisposeModule(clone);
            var cf = core.LLVMGetFirstFunction(clone);
            while (cf != null) : (cf = core.LLVMGetNextFunction(cf)) {
                const nm = std.mem.span(core.LLVMGetValueName(cf));
                if (!std.mem.eql(u8, nm, "__nova_main")) core.LLVMSetLinkage(cf, .LLVMInternalLinkage);
            }
            const opts = transform.LLVMCreatePassBuilderOptions();
            defer transform.LLVMDisposePassBuilderOptions(opts);
            const perr = transform.LLVMRunPasses(clone, "globaldce", compiler.target_machine, opts);
            if (perr != null) errors.LLVMConsumeError(perr);
            var sf = core.LLVMGetFirstFunction(clone);
            while (sf != null) : (sf = core.LLVMGetNextFunction(sf)) {
                const nm = std.mem.span(core.LLVMGetValueName(sf));
                try reachable.put(try allocator.dupe(u8, nm), {});
            }
        }
        var rf = core.LLVMGetFirstFunction(compiler.module);
        while (rf != null) : (rf = core.LLVMGetNextFunction(rf)) {
            const nm = std.mem.span(core.LLVMGetValueName(rf));
            if (std.mem.eql(u8, nm, "__nova_main")) continue;
            if (!reachable.contains(nm)) core.LLVMSetLinkage(rf, .LLVMInternalLinkage);
        }
        const opts2 = transform.LLVMCreatePassBuilderOptions();
        defer transform.LLVMDisposePassBuilderOptions(opts2);
        const perr2 = transform.LLVMRunPasses(compiler.module, "globaldce", compiler.target_machine, opts2);
        if (perr2 != null) errors.LLVMConsumeError(perr2);
        memPhase("after demand prune");
    }

    // Group the SURVIVING owned function definitions by source file. Iterating the module (not
    // func_map) is required post-prune: deleted functions are simply absent. Declarations (no body)
    // are cross-object references or runtime symbols -- skipped, they have no owning file here.
    var all_syms = std.StringHashMap(void).init(allocator);
    defer all_syms.deinit();
    var file_syms = std.StringHashMap(std.StringHashMap(void)).init(allocator);
    defer {
        var it = file_syms.valueIterator();
        while (it.next()) |v| v.deinit();
        file_syms.deinit();
    }
    {
        var mf = core.LLVMGetFirstFunction(compiler.module);
        while (mf != null) : (mf = core.LLVMGetNextFunction(mf)) {
            if (core.LLVMGetFirstBasicBlock(mf) == null) continue; // declaration, not owned here
            const sym = std.mem.span(core.LLVMGetValueName(mf));
            const file = sym_to_file.get(sym) orelse continue;
            try all_syms.put(sym, {});
            const gop = try file_syms.getOrPut(file);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(allocator);
            try gop.value_ptr.put(sym, {});
        }
    }

    // Bump T6_CACHE_VERSION whenever codegen changes in a way that alters emitted objects, so every
    // cached object gets a new filename and the stale ones are ignored (mtime alone can't see a
    // compiler change -- source files did not move). Folded into the per-object name hash below.
    const T6_CACHE_VERSION: u64 = 2;

    var idx: usize = 0;
    var hits: usize = 0;
    var misses: usize = 0;
    var fit = file_syms.iterator();
    while (fit.next()) |entry| : (idx += 1) {
        const src_path = entry.key_ptr.*;

        // Readable, stable, unique object name derived from the SOURCE file: `<stem>_<pathhash>.o`
        // (e.g. json_1a2b3c.o). The stem is the source basename; the path hash disambiguates same-named
        // files in different dirs (e.g. two query.nova). Falls back to `<out>.<idx>.o` with no cache dir.
        var obj_path: []const u8 = undefined;
        if (cache_dir) |cdir| {
            const base = std.fs.path.basename(src_path);
            const stem = if (std.mem.endsWith(u8, base, ".nova")) base[0 .. base.len - 5] else base;
            // Path hash disambiguates same-named files in different dirs; version + release bit keep
            // release/debug and pre/post-codegen-change objects from aliasing.
            const ph: u32 = @truncate(std.hash.Wyhash.hash(T6_CACHE_VERSION ^ (if (is_release) @as(u64, 1) else 0), src_path));
            obj_path = try std.fmt.allocPrint(allocator, "{s}/{s}_{x}.o", .{ cdir, stem, ph });

            // Freshness: if the object exists (and, for app files, is newer than its source), skip this
            // file ENTIRELY -- no clone, no globaldce, no emit. This is what lets an incremental build
            // skip the whole (unchanged) stdlib instead of re-emitting it every time. Stdlib sources
            // (`src/std/...`) are installed and don't change during app dev, and a compiler change bumps
            // T6_CACHE_VERSION (new filename), so an existing stdlib object is always fresh. App sources
            // are cwd-relative and stat-able. (Cross-file signature changes aren't tracked; do a clean
            // rebuild -- `rm -rf build` -- after changing a shared signature.)
            fresh: {
                const om = (std.Io.Dir.statFile(.cwd(), io, obj_path, .{}) catch break :fresh).mtime.nanoseconds;
                if (!std.mem.startsWith(u8, src_path, "src/std/")) {
                    const sm = (std.Io.Dir.statFile(.cwd(), io, src_path, .{}) catch break :fresh).mtime.nanoseconds;
                    if (om < sm) break :fresh;
                }
                hits += 1;
                try objs.append(allocator, obj_path);
                continue; // fresh: reuse the object, do no per-file work
            }
        } else {
            obj_path = try std.fmt.allocPrint(allocator, "{s}.{d}.o", .{ output_path, idx });
        }

        // Stale (or no cache): build this file's object. Clone the module and strip every function that
        // this file does not OWN down to a bare declaration.
        const owner = entry.value_ptr;
        const clone = core.LLVMCloneModule(compiler.module);
        defer core.LLVMDisposeModule(clone);

        var f = core.LLVMGetFirstFunction(clone);
        while (f != null) : (f = core.LLVMGetNextFunction(f)) {
            const nm = std.mem.span(core.LLVMGetValueName(f));
            if (!all_syms.contains(nm)) continue;
            if (owner.contains(nm)) continue;

            var bb = core.LLVMGetFirstBasicBlock(f);
            while (bb != null) {
                const next = core.LLVMGetNextBasicBlock(bb);
                core.LLVMDeleteBasicBlock(bb);
                bb = next;
            }
        }

        if (cache_dir != null) {
            const opts = transform.LLVMCreatePassBuilderOptions();
            defer transform.LLVMDisposePassBuilderOptions(opts);
            const perr = transform.LLVMRunPasses(clone, "globaldce", compiler.target_machine, opts);
            if (perr != null) errors.LLVMConsumeError(perr);
        }

        misses += 1;
        try emitModule(compiler, allocator, clone, obj_path, false, is_release, null);
        try objs.append(allocator, obj_path);
    }
    if (cache_dir != null) {
        std.debug.print("[T6] per-file objects: {d} total, {d} reused (mtime), {d} rebuilt\n", .{ idx, hits, misses });
    }
}

fn emitModule(
    compiler: *LlvmCompiler,
    allocator: std.mem.Allocator,
    module: types.LLVMModuleRef,
    obj_path: []const u8,
    is_wasm: bool,
    is_release: bool,
    dump_ll_name: ?[]const u8,
) !void {
    // Gap3-A/E2 ARC-traffic census: raw retain/release traffic BEFORE elision.
    compiler.arcCensusBefore(module);

    // Prototype ARC elision (NOVA_ARC_ELIDE): remove provably-redundant borrowed
    // retain/release pairs before the IR is dumped / verified / emitted.
    compiler.elideBorrowedArc(module);

    // Gap3-A/E2 ARC-traffic census: surviving traffic AFTER elision (the borrow-skip target).
    compiler.arcCensusAfter(module);

    // OSSA-lite Track V (V4'): static ARC release-balance verifier on the raw module
    // (before LLVM -O strips ARC calls). Opt-in via NOVA_OWN_VERIFY. See docs/design/ossa-lite-tasks.md.
    compiler.verifyArcBalance(module);

    // DWARF (Gap 4): sanitize + resolve debug metadata for this exact module (a per-file clone under
    // T6 split) before it is dumped/verified/emitted.
    compiler.finalizeDebug(module);

    if (dump_ll_name) |nm| {
        const nm_z = try allocator.dupeZ(u8, nm);
        defer allocator.free(nm_z);
        _ = core.LLVMPrintModuleToFile(module, nm_z.ptr, null);
    }

    var errMsg: ?[*:0]u8 = null;
    const failed: types.LLVMBool = analysis.LLVMVerifyModule(
        module,
        types.LLVMVerifierFailureAction.LLVMReturnStatusAction,
        @ptrCast(&errMsg),
    );
    if (failed != 0 and errMsg != null) {
        const msg = std.mem.span(errMsg.?);
        std.debug.print("LLVM Module Verification Failed: {s}\n", .{msg});
        return error.LLVMVerificationError;
    }

    {
        var f = core.LLVMGetFirstFunction(module);
        while (f != null) : (f = core.LLVMGetNextFunction(f)) {
            const nm = std.mem.span(core.LLVMGetValueName(f));
            if (std.mem.startsWith(u8, nm, "__destruct_")) {
                core.LLVMSetLinkage(f, types.LLVMLinkage.LLVMInternalLinkage);
            }
        }
    }

    if (!is_wasm) {
        const opts = transform.LLVMCreatePassBuilderOptions();
        defer transform.LLVMDisposePassBuilderOptions(opts);
        // The C PassBuilder API defaults loop + SLP vectorization OFF, so `default<O3>` was running
        // without the vectorizer. Enable them (release only) -- now that array values carry pointer
        // provenance (perf-ceiling.md pt1+pt2), auto-vectorization of array loops can actually fire.
        if (is_release) {
            transform.LLVMPassBuilderOptionsSetLoopVectorization(opts, 1);
            transform.LLVMPassBuilderOptionsSetSLPVectorization(opts, 1);
            transform.LLVMPassBuilderOptionsSetLoopUnrolling(opts, 1);
        }
        memPhase("before LLVM opt passes");
        const passes: [*:0]const u8 = if (is_release) "default<O3>,globaldce" else "default<O0>,globaldce";
        const perr = transform.LLVMRunPasses(module, passes, compiler.target_machine, opts);
        if (perr != null) {
            errors.LLVMConsumeError(perr);
            std.debug.print("LLVM pass pipeline ('{s}') failed\n", .{passes});
            return error.LLVMPassError;
        }

        // NOVA_ASAN_CODEGEN: instrument Nova-generated code so a UAF in *our* code (not just the runtime)
        // is caught with provenance. LLVM's ASAN only touches functions carrying `sanitize_address`, so tag
        // every defined function, then run the `asan` module pass after the main pipeline (post coro-split).
        if (@import("arc.zig").asan_codegen_enabled) {
            const ctx = core.LLVMGetModuleContext(module);
            const kind = core.LLVMGetEnumAttributeKindForName("sanitize_address", "sanitize_address".len);
            const attr = core.LLVMCreateEnumAttribute(ctx, kind, 0);
            const fn_idx: types.LLVMAttributeIndex = @as(types.LLVMAttributeIndex, 0xFFFFFFFF); // LLVMAttributeFunctionIndex
            var fnv = core.LLVMGetFirstFunction(module);
            while (fnv != null) : (fnv = core.LLVMGetNextFunction(fnv)) {
                if (core.LLVMCountBasicBlocks(fnv) == 0) continue; // skip declarations (ASAN skips them anyway)
                core.LLVMAddAttributeAtIndex(fnv, fn_idx, attr);
            }
            const aerr = transform.LLVMRunPasses(module, "asan", compiler.target_machine, opts);
            if (aerr != null) {
                errors.LLVMConsumeError(aerr);
                std.debug.print("LLVM ASAN instrumentation pass failed\n", .{});
                return error.LLVMPassError;
            }
        }
    }

    memPhase("after LLVM opt passes");
    const file_type = types.LLVMCodeGenFileType.LLVMObjectFile;
    var err_msg: [*c]u8 = null;
    const obj_path_c = try allocator.dupeZ(u8, obj_path);
    defer allocator.free(obj_path_c);
    if (target_machine.LLVMTargetMachineEmitToFile(
        compiler.target_machine,
        module,
        obj_path_c.ptr,
        file_type,
        @ptrCast(&err_msg),
    ) != 0) {
        const span_msg = std.mem.span(err_msg);
        std.debug.print("Failed to emit object file: {s}\n", .{span_msg});
        return error.LLVMEmitFileError;
    }
    memPhase("after emit object");
}

fn declareCoroIntrinsic(compiler: *LlvmCompiler, name: [:0]const u8, overload: ?types.LLVMTypeRef) !void {
    const id = core.LLVMLookupIntrinsicID(name.ptr, name.len);
    const fn_val = if (overload) |ot| blk: {
        var ptypes = [_]types.LLVMTypeRef{ot};
        break :blk core.LLVMGetIntrinsicDeclaration(compiler.module, id, &ptypes, 1);
    } else core.LLVMGetIntrinsicDeclaration(compiler.module, id, null, 0);
    try compiler.func_map.put(name[0..name.len], fn_val);
}

const CoroCtx = struct {
    hdl: types.LLVMValueRef,
    id: types.LLVMValueRef,
    promise: types.LLVMValueRef,
    final_bb: types.LLVMBasicBlockRef,
    cleanup_bb: types.LLVMBasicBlockRef,
    suspend_bb: types.LLVMBasicBlockRef,
};

fn emitCoroPrologue(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef) !CoroCtx {
    const b = compiler.builder;
    const ptr_ty = compiler.ptr_type;

    const promise = core.LLVMBuildAlloca(b, compiler.coroPromiseType(), "coro.promise");

    const w0 = compiler.coroPromiseWaiterSlot(promise);
    _ = core.LLVMBuildStore(b, core.LLVMConstInt(compiler.val_type, 0, 0), w0);

    const id_fn = compiler.func_map.get("llvm.coro.id").?;
    const id_t = core.LLVMGlobalGetValueType(id_fn);
    var id_args = [_]types.LLVMValueRef{
        core.LLVMConstInt(compiler.i32_type, 0, 0),
        promise,
        core.LLVMConstNull(ptr_ty),
        core.LLVMConstNull(ptr_ty),
    };
    const id_tok = core.LLVMBuildCall2(b, id_t, id_fn, &id_args, 4, "coro.id");

    const size_fn = compiler.func_map.get("llvm.coro.size").?;
    const size_t = core.LLVMGlobalGetValueType(size_fn);
    const size_val = core.LLVMBuildCall2(b, size_t, size_fn, null, 0, "coro.size");

    const alloc_fn = compiler.func_map.get("nova_coro_alloc").?;
    const alloc_t = core.LLVMGlobalGetValueType(alloc_fn);
    var alloc_args = [_]types.LLVMValueRef{size_val};
    const frame_i = core.LLVMBuildCall2(b, alloc_t, alloc_fn, &alloc_args, 1, "coro.frame");
    const frame_p = core.LLVMBuildIntToPtr(b, frame_i, ptr_ty, "coro.framep");

    const begin_fn = compiler.func_map.get("llvm.coro.begin").?;
    const begin_t = core.LLVMGlobalGetValueType(begin_fn);
    var begin_args = [_]types.LLVMValueRef{ id_tok, frame_p };
    const hdl = core.LLVMBuildCall2(b, begin_t, begin_fn, &begin_args, 2, "coro.hdl");

    const body_bb = core.LLVMAppendBasicBlock(fn_val, "coro.body");
    const final_bb = core.LLVMAppendBasicBlock(fn_val, "coro.final");
    const cleanup_bb = core.LLVMAppendBasicBlock(fn_val, "coro.cleanup");
    const suspend_bb = core.LLVMAppendBasicBlock(fn_val, "coro.ret");

    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);
    const suspend_fn = compiler.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var s0_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(compiler.i1_type, 0, 0) };
    const s0 = core.LLVMBuildCall2(b, suspend_t, suspend_fn, &s0_args, 2, "coro.init.susp");
    const sw0 = core.LLVMBuildSwitch(b, s0, suspend_bb, 2);
    core.LLVMAddCase(sw0, core.LLVMConstInt(compiler.i8_type, 0, 0), body_bb);
    core.LLVMAddCase(sw0, core.LLVMConstInt(compiler.i8_type, 1, 0), cleanup_bb);

    core.LLVMPositionBuilderAtEnd(b, body_bb);
    return CoroCtx{
        .hdl = hdl,
        .id = id_tok,
        .promise = promise,
        .final_bb = final_bb,
        .cleanup_bb = cleanup_bb,
        .suspend_bb = suspend_bb,
    };
}

fn emitCoroEpilogue(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, ctx: CoroCtx) void {
    const b = compiler.builder;
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);

    core.LLVMPositionBuilderAtEnd(b, ctx.final_bb);
    const suspend_fn = compiler.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var sf_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(compiler.i1_type, 1, 0) };
    const sf = core.LLVMBuildCall2(b, suspend_t, suspend_fn, &sf_args, 2, "coro.final.susp");
    const trap_bb = core.LLVMAppendBasicBlock(fn_val, "coro.trap");
    const sw = core.LLVMBuildSwitch(b, sf, ctx.suspend_bb, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(compiler.i8_type, 0, 0), trap_bb);
    core.LLVMAddCase(sw, core.LLVMConstInt(compiler.i8_type, 1, 0), ctx.cleanup_bb);
    core.LLVMPositionBuilderAtEnd(b, trap_bb);
    _ = core.LLVMBuildUnreachable(b);

    core.LLVMPositionBuilderAtEnd(b, ctx.cleanup_bb);
    const free_fn = compiler.func_map.get("llvm.coro.free").?;
    const free_t = core.LLVMGlobalGetValueType(free_fn);
    var free_args = [_]types.LLVMValueRef{ ctx.id, ctx.hdl };
    const mem_p = core.LLVMBuildCall2(b, free_t, free_fn, &free_args, 2, "coro.free");
    const mem_i = core.LLVMBuildPtrToInt(b, mem_p, compiler.val_type, "coro.freei");
    const nfree_fn = compiler.func_map.get("nova_coro_free").?;
    const nfree_t = core.LLVMGlobalGetValueType(nfree_fn);
    var nfree_args = [_]types.LLVMValueRef{mem_i};
    _ = core.LLVMBuildCall2(b, nfree_t, nfree_fn, &nfree_args, 1, "");
    _ = core.LLVMBuildBr(b, ctx.suspend_bb);

    core.LLVMPositionBuilderAtEnd(b, ctx.suspend_bb);
    const end_fn = compiler.func_map.get("llvm.coro.end").?;
    const end_t = core.LLVMGlobalGetValueType(end_fn);
    var end_args = [_]types.LLVMValueRef{ ctx.hdl, core.LLVMConstInt(compiler.i1_type, 0, 0), none_tok };
    _ = core.LLVMBuildCall2(b, end_t, end_fn, &end_args, 3, "");
    const hdl_i = core.LLVMBuildPtrToInt(b, ctx.hdl, compiler.val_type, "coro.hdli");
    _ = core.LLVMBuildRet(b, hdl_i);
}

fn setupCoroutineSupport(compiler: *LlvmCompiler) !void {
    try declareCoroIntrinsic(compiler, "llvm.coro.id", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.size", compiler.i64_type);
    try declareCoroIntrinsic(compiler, "llvm.coro.begin", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.suspend", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.end", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.free", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.resume", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.destroy", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.done", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.promise", null);

    var one_val = [_]types.LLVMTypeRef{compiler.val_type};
    const alloc_type = core.LLVMFunctionType(compiler.val_type, &one_val, 1, 0);
    const alloc_fn = core.LLVMAddFunction(compiler.module, "nova_coro_alloc", alloc_type);
    try compiler.func_map.put("nova_coro_alloc", alloc_fn);
    const free_type = core.LLVMFunctionType(compiler.void_type, &one_val, 1, 0);
    const free_fn = core.LLVMAddFunction(compiler.module, "nova_coro_free", free_type);
    try compiler.func_map.put("nova_coro_free", free_fn);

    const sched_type = core.LLVMFunctionType(compiler.void_type, &one_val, 1, 0);
    const sched_fn = core.LLVMAddFunction(compiler.module, "nova_sched_schedule", sched_type);
    try compiler.func_map.put("nova_sched_schedule", sched_fn);
    const sched_det_fn = core.LLVMAddFunction(compiler.module, "nova_sched_schedule_detached", sched_type);
    try compiler.func_map.put("nova_sched_schedule_detached", sched_det_fn);
    const next_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
    const next_fn = core.LLVMAddFunction(compiler.module, "nova_sched_next", next_type);
    try compiler.func_map.put("nova_sched_next", next_fn);

    const run_type = core.LLVMFunctionType(compiler.void_type, null, 0, 0);
    const run_fn = core.LLVMAddFunction(compiler.module, "nova_run", run_type);
    try compiler.func_map.put("nova_run", run_fn);

    var release_params = [_]types.LLVMTypeRef{compiler.val_type};
    const release_type = core.LLVMFunctionType(compiler.void_type, &release_params, 1, 0);
    const release_fn = core.LLVMAddFunction(compiler.module, "nova_coro_release", release_type);
    try compiler.func_map.put("nova_coro_release", release_fn);

    var run_root_params = [_]types.LLVMTypeRef{compiler.val_type};
    const run_root_type = core.LLVMFunctionType(compiler.void_type, &run_root_params, 1, 0);
    const run_root_fn = core.LLVMAddFunction(compiler.module, "nova_run_root", run_root_type);
    try compiler.func_map.put("nova_run_root", run_root_fn);

    var timer_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const timer_type = core.LLVMFunctionType(compiler.void_type, &timer_params, 2, 0);
    const timer_fn = core.LLVMAddFunction(compiler.module, "nova_await_timer", timer_type);
    try compiler.func_map.put("nova_await_timer", timer_fn);

    var waiter_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const waiter_type = core.LLVMFunctionType(compiler.void_type, &waiter_params, 2, 0);
    const waiter_fn = core.LLVMAddFunction(compiler.module, "nova_register_waiter", waiter_type);
    try compiler.func_map.put("nova_register_waiter", waiter_fn);

    var fut_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const fut_type = core.LLVMFunctionType(compiler.val_type, &fut_params, 2, 0);
    const fut_fn = core.LLVMAddFunction(compiler.module, "nova_await_future", fut_type);
    try compiler.func_map.put("nova_await_future", fut_fn);

    var one_val_c = [_]types.LLVMTypeRef{compiler.val_type};
    const cnew_type = core.LLVMFunctionType(compiler.val_type, &one_val_c, 1, 0);
    const cnew_fn = core.LLVMAddFunction(compiler.module, "nova_chan_new", cnew_type);
    try compiler.func_map.put("nova_chan_new", cnew_fn);
    var csend_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const csend_type = core.LLVMFunctionType(compiler.void_type, &csend_params, 2, 0);
    const csend_fn = core.LLVMAddFunction(compiler.module, "nova_chan_send", csend_type);
    try compiler.func_map.put("nova_chan_send", csend_fn);
    var crecv_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.ptr_type };
    const crecv_type = core.LLVMFunctionType(compiler.val_type, &crecv_params, 3, 0);
    const crecv_fn = core.LLVMAddFunction(compiler.module, "nova_chan_recv", crecv_type);
    try compiler.func_map.put("nova_chan_recv", crecv_fn);
    const cfree_type = core.LLVMFunctionType(compiler.void_type, &one_val_c, 1, 0);
    const cfree_fn = core.LLVMAddFunction(compiler.module, "nova_chan_free", cfree_type);
    try compiler.func_map.put("nova_chan_free", cfree_fn);

    var recv_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type };
    const iorecv_type = core.LLVMFunctionType(compiler.void_type, &recv_params, 4, 0);
    const iorecv_fn = core.LLVMAddFunction(compiler.module, "nova_io_recv_async", iorecv_type);
    try compiler.func_map.put("nova_io_recv_async", iorecv_fn);
    var accept_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const ioaccept_type = core.LLVMFunctionType(compiler.void_type, &accept_params, 2, 0);
    const ioaccept_fn = core.LLVMAddFunction(compiler.module, "nova_io_accept_async", ioaccept_type);
    try compiler.func_map.put("nova_io_accept_async", ioaccept_fn);
    const iotake_type = core.LLVMFunctionType(compiler.val_type, &one_val_c, 1, 0);
    const iotake_fn = core.LLVMAddFunction(compiler.module, "nova_io_take_result", iotake_type);
    try compiler.func_map.put("nova_io_take_result", iotake_fn);

    const listen_type = core.LLVMFunctionType(compiler.val_type, &one_val_c, 1, 0);
    const listen_fn = core.LLVMAddFunction(compiler.module, "nova_aserver_listen", listen_type);
    try compiler.func_map.put("nova_aserver_listen", listen_fn);
    var two_val_c = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };

    const listen_addr_type = core.LLVMFunctionType(compiler.val_type, &two_val_c, 2, 0);
    const listen_addr_fn = core.LLVMAddFunction(compiler.module, "nova_aserver_listen_addr", listen_addr_type);
    try compiler.func_map.put("nova_aserver_listen_addr", listen_addr_fn);
    const aaccept_type = core.LLVMFunctionType(compiler.void_type, &two_val_c, 2, 0);
    const aaccept_fn = core.LLVMAddFunction(compiler.module, "nova_aaccept", aaccept_type);
    try compiler.func_map.put("nova_aaccept", aaccept_fn);
    var three_val_conn = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type };
    const aconn_type = core.LLVMFunctionType(compiler.void_type, &three_val_conn, 3, 0);
    const aconn_fn = core.LLVMAddFunction(compiler.module, "nova_aconnect", aconn_type);
    try compiler.func_map.put("nova_aconnect", aconn_fn);
    var four_val_c = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type };
    const arecv_type = core.LLVMFunctionType(compiler.void_type, &four_val_c, 4, 0);
    const arecv_fn = core.LLVMAddFunction(compiler.module, "nova_arecv", arecv_type);
    try compiler.func_map.put("nova_arecv", arecv_fn);
    var five_val_c = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type };
    const arecv_dl_type = core.LLVMFunctionType(compiler.void_type, &five_val_c, 5, 0);
    const arecv_dl_fn = core.LLVMAddFunction(compiler.module, "nova_arecv_deadline", arecv_dl_type);
    try compiler.func_map.put("nova_arecv_deadline", arecv_dl_fn);
    var three_val_c = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type };
    const asend_type = core.LLVMFunctionType(compiler.void_type, &three_val_c, 3, 0);
    const asend_fn = core.LLVMAddFunction(compiler.module, "nova_asend", asend_type);
    try compiler.func_map.put("nova_asend", asend_fn);
    const aclose_type = core.LLVMFunctionType(compiler.void_type, &one_val_c, 1, 0);
    const aclose_fn = core.LLVMAddFunction(compiler.module, "nova_aclose", aclose_type);
    try compiler.func_map.put("nova_aclose", aclose_fn);

    var holdarg_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.ptr_type };
    const holdarg_type = core.LLVMFunctionType(compiler.void_type, &holdarg_params, 3, 0);
    try compiler.func_map.put("nova_coro_hold_arg", core.LLVMAddFunction(compiler.module, "nova_coro_hold_arg", holdarg_type));

    var whenany_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type };
    const whenany_type = core.LLVMFunctionType(compiler.val_type, &whenany_params, 3, 0);
    try compiler.func_map.put("nova_when_any", core.LLVMAddFunction(compiler.module, "nova_when_any", whenany_type));
    var whenanydl_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type };
    const whenanydl_type = core.LLVMFunctionType(compiler.val_type, &whenanydl_params, 4, 0);
    try compiler.func_map.put("nova_when_any_deadline", core.LLVMAddFunction(compiler.module, "nova_when_any_deadline", whenanydl_type));
}
