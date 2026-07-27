const std = @import("std");
const ast = @import("../ast.zig");
const sema_shadow = @import("../sema/shadow.zig");
const sema_mono = @import("../sema/mono.zig");
const sema_types = @import("../types.zig");
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

// T3 FFI: map a Nova type name to its C-ABI LLVM type for a foreign function signature.
// Stage 1 supports the cleanly-marshalled integer/pointer set; `string`/struct pass as an
// opaque pointer (value marshalling of Nova string ↔ char* is Stage 2). `float`/`double`
// are Stage 2 as well — until then they map to i64 and should not be used across FFI.
fn ffiCType(compiler: *LlvmCompiler, type_name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, type_name, "int")) return compiler.i32_type; // C int
    if (std.mem.eql(u8, type_name, "long")) return compiler.i64_type; // C long / int64_t
    if (std.mem.eql(u8, type_name, "bool")) return compiler.i8_type; // C _Bool (1 byte)
    if (std.mem.eql(u8, type_name, "void")) return compiler.void_type;
    // ptr, string (char*), and struct-by-pointer all cross as an opaque C pointer.
    return compiler.ptr_type;
}

pub fn compile(allocator: std.mem.Allocator, program: ast.Program, is_wasm: bool, is_release: bool, target_triple_opt: ?[]const u8, output_path: []const u8, coverage_enabled: bool, t6_split: bool, objs_out: ?*std.ArrayList([]const u8), cache_dir: ?[]const u8, io: std.Io) !void {
    var compiler = try LlvmCompiler.new(allocator, is_wasm, is_release, target_triple_opt, coverage_enabled);

    // F2 stage 3: hand sema's TypedIr to codegen for the SHADOW DIFF. Codegen still
    // resolves types the old way (resolveExpressionTypeName); this only lets the two
    // answers be compared on every real expression it asks about, before stage 4
    // makes the IR authoritative. Both null unless NOVA_SEMA_SHADOW=1.
    compiler.typed_ir = sema_shadow.live_ir;
    compiler.type_store = sema_shadow.live_store;
    // F2 stage 4b: and with NOVA_F2_TYPES=1, codegen READS it instead of
    // re-deriving. Set from main.zig alongside the shadow, since the IR only
    // exists when sema ran.
    compiler.f2_types = sema_shadow.f2_types_enabled;
    defer compiler.deinit();

    compiler.program = program;

    // Scan program constants, enums, and traits (Pass 0)
    for (program.declarations) |decl| {
        switch (decl) {
            .const_decl => |c| try compiler.constants.put(c.name, c.value),
            .enum_decl => |e| try compiler.enums.put(e.name, e),
            .trait_decl => |t| try compiler.traits.put(t.name, t),
            else => {},
        }
    }

    // Collect functions and structures (Pass 1 & 2)
    try compiler.collectFunctions(program);
    // Collect closures (Pass 1.5)
    var i: usize = 0;
    while (i < compiler.functions.items.len) {
        compiler.current_collecting_function_name = compiler.functions.items[i].name;
        // F4 4b: `functions` already holds the N monomorphized copies of each generic
        // method, so this loop ALREADY visits `Map_keys` and `Map_string_i32_keys`
        // separately — one lambda per instantiation was being created and then thrown
        // away, because `closure_lambdas` was keyed by span alone and simply
        // overwrote. Telling the lambda WHICH instantiation it belongs to is the whole
        // change; the N copies were already here.
        compiler.current_collecting_instantiation = compiler.functions.items[i].instantiation;
        compiler.current_collecting_method_subst = compiler.functions.items[i].method_subst;
        compiler.current_collecting_erased_generic = compiler.functions.items[i].erased_generic;
        try compiler.collectClosuresFromBlock(compiler.functions.items[i].body);
        i += 1;
    }
    compiler.current_collecting_function_name = null;
    compiler.current_collecting_instantiation = null;
    compiler.current_collecting_method_subst = null;

    // T6 Phase 1b — increment 1: partition the collected functions (incl. monomorphized instances +
    // closures) by SOURCE FILE. Under NOVA_T6_SPLIT this reports the partition — the data model the
    // per-file object split (increment 2: one LLVM module → one `.o` per file) will emit from. No
    // codegen change yet; this proves every function is attributed to a file before we split emission.
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

    // Collect string literals (Pass 3)
    try compiler.collectStringLiterals(program);
    for (compiler.functions.items) |func| {
        try compiler.collectStringsFromBlock(func.body);
    }

    // Declare global heap pointer
    var total_data_size: u32 = 0;
    for (compiler.strings.items) |str| {
        const unescaped = try unescapeString(allocator, str);
        defer allocator.free(unescaped);
        total_data_size += 4 + @as(u32, @intCast(unescaped.len));
    }
    const heap_start = if (total_data_size < 1024) @as(u32, 1024) else (total_data_size + 15) & ~@as(u32, 15);

    const heap_ptr_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "heap_ptr");
    core.LLVMSetInitializer(heap_ptr_global, core.LLVMConstInt(compiler.val_type, @intCast(heap_start), 0));
    compiler.heap_ptr = heap_ptr_global;

    const free_list_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "free_list");
    core.LLVMSetInitializer(free_list_global, core.LLVMConstInt(compiler.val_type, 0, 0));
    compiler.free_list = free_list_global;

    const persistent_ptr_global = core.LLVMAddGlobal(compiler.module, compiler.val_type, "persistent_ptr");
    core.LLVMSetInitializer(persistent_ptr_global, core.LLVMConstInt(compiler.val_type, @intCast(heap_start + 32 * 1024 * 1024), 0));
    compiler.persistent_ptr = persistent_ptr_global;

    // Declare global string literals in LLVM
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
        const ref_const = core.LLVMConstInt(compiler.i32_type, 100000000, 0);
        const len_const = core.LLVMConstInt(compiler.i32_type, @intCast(unescaped.len), 0);
        const chars_const = core.LLVMConstString(str_z.ptr, @intCast(unescaped.len), 1); // 1 -> DontNullTerminate = true

        var field_values = [_]types.LLVMValueRef{ ref_const, len_const, chars_const };
        const init_const = core.LLVMConstStruct(&field_values, 3, 1);
        core.LLVMSetInitializer(global_var, init_const);

        try compiler.string_globals.put(str, global_var);
    }

    // A8: number/bool → Nova string, for concat and `${}` interpolation. Declared for
    // BOTH targets (on wasm they resolve as host imports) so the injected
    // `__i32_to_string`/`__bool_to_string` prelude can be deleted. Return val_type (i64):
    // Nova strings are pointers-as-i64 across the ABI. The f64 one takes a real `double`.
    {
        var i64_p = [_]types.LLVMTypeRef{compiler.val_type};
        const i64_t = core.LLVMFunctionType(compiler.val_type, &i64_p, 1, 0);
        try compiler.func_map.put("nova_i64_to_string", core.LLVMAddFunction(compiler.module, "nova_i64_to_string", i64_t));

        var f64_p = [_]types.LLVMTypeRef{core.LLVMDoubleType()};
        const f64_t = core.LLVMFunctionType(compiler.val_type, &f64_p, 1, 0);
        try compiler.func_map.put("nova_f64_to_string", core.LLVMAddFunction(compiler.module, "nova_f64_to_string", f64_t));

        // D6: IEEE-LE bytes -> shortest-decimal string, for the MySQL binary protocol FLOAT/DOUBLE.
        var ieee_p = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        try compiler.func_map.put("nova_ieee_le_to_str", core.LLVMAddFunction(compiler.module, "nova_ieee_le_to_str", core.LLVMFunctionType(compiler.ptr_type, &ieee_p, 2, 0)));

        // double's raw IEEE-754 bits -> long (bit_cast, not a value convert), for binary wire formats
        // (BSON type-0x01 double). See nova_f64_bits.
        var f64bits_p = [_]types.LLVMTypeRef{core.LLVMDoubleType()};
        try compiler.func_map.put("nova_f64_bits", core.LLVMAddFunction(compiler.module, "nova_f64_bits", core.LLVMFunctionType(compiler.val_type, &f64bits_p, 1, 0)));

        var bool_p = [_]types.LLVMTypeRef{compiler.val_type};
        const bool_t = core.LLVMFunctionType(compiler.val_type, &bool_p, 1, 0);
        try compiler.func_map.put("nova_bool_to_string", core.LLVMAddFunction(compiler.module, "nova_bool_to_string", bool_t));

        // specs §3.1: decimal128 (BID). from_string(cstr) -> heap decimal (val_type); to_string(dec) -> Nova string.
        var dec_from_p = [_]types.LLVMTypeRef{compiler.ptr_type};
        const dec_from_t = core.LLVMFunctionType(compiler.val_type, &dec_from_p, 1, 0);
        try compiler.func_map.put("nova_decimal_from_string", core.LLVMAddFunction(compiler.module, "nova_decimal_from_string", dec_from_t));

        var dec_to_p = [_]types.LLVMTypeRef{compiler.val_type};
        const dec_to_t = core.LLVMFunctionType(compiler.val_type, &dec_to_p, 1, 0);
        try compiler.func_map.put("nova_decimal_to_string", core.LLVMAddFunction(compiler.module, "nova_decimal_to_string", dec_to_t));

        // specs §3.1 Stage 2: decimal128 arithmetic + compare (BID base-10). Each `(dec, dec) -> dec`
        // op allocates a FRESH result decimal (an owned temp); `cmp` returns {-1,0,1} as an int.
        var dec_bin_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const dec_bin_t = core.LLVMFunctionType(compiler.val_type, &dec_bin_p, 2, 0);
        for ([_][:0]const u8{ "nova_decimal_add", "nova_decimal_sub", "nova_decimal_mul", "nova_decimal_div", "nova_decimal_mod", "nova_decimal_cmp" }) |name| {
            try compiler.func_map.put(name, core.LLVMAddFunction(compiler.module, name, dec_bin_t));
        }

        // S3: explicit int <-> decimal conversions. from_int(i64) -> heap decimal; to_int(dec) -> i64.
        var dec_fi_p = [_]types.LLVMTypeRef{compiler.val_type};
        const dec_fi_t = core.LLVMFunctionType(compiler.val_type, &dec_fi_p, 1, 0);
        try compiler.func_map.put("nova_decimal_from_int", core.LLVMAddFunction(compiler.module, "nova_decimal_from_int", dec_fi_t));
        try compiler.func_map.put("nova_decimal_to_int", core.LLVMAddFunction(compiler.module, "nova_decimal_to_int", dec_fi_t));

        // S4/S1: length-aware string->decimal for RUNTIME (possibly non-NUL-terminated) Nova strings.
        var dec_fsn_p = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.val_type };
        const dec_fsn_t = core.LLVMFunctionType(compiler.val_type, &dec_fsn_p, 2, 0);
        try compiler.func_map.put("nova_decimal_from_string_n", core.LLVMAddFunction(compiler.module, "nova_decimal_from_string_n", dec_fsn_t));
    }

    // FFI callback primitives: invoke a Nova closure from C (used by callback trampolines
    // like webview_bind). `(string)->string` and `()->void` shapes. Native only.
    if (!is_wasm) {
        var inv_p = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const inv_t = core.LLVMFunctionType(compiler.val_type, &inv_p, 2, 0);
        try compiler.func_map.put("nova_invoke_str_closure", core.LLVMAddFunction(compiler.module, "nova_invoke_str_closure", inv_t));
        var invv_p = [_]types.LLVMTypeRef{compiler.val_type};
        const invv_t = core.LLVMFunctionType(compiler.void_type, &invv_p, 1, 0);
        try compiler.func_map.put("nova_invoke_void_closure", core.LLVMAddFunction(compiler.module, "nova_invoke_void_closure", invv_t));
    }

    // Declare standard output functions/imports
    if (is_wasm) {
        // env.log import — params are val_type (i64): nova values (incl. the string
        // pointer handle) are i64 on both targets. The host reads the low 32 bits
        // for the wasm32 address.
        var log_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const log_fn_type = core.LLVMFunctionType(compiler.void_type, &log_params, 2, 0);
        const log_fn = core.LLVMAddFunction(compiler.module, "log", log_fn_type);
        core.LLVMAddTargetDependentFunctionAttr(log_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(log_fn, "wasm-import-name", "log");
        compiler.log_fn = log_fn;

        try compiler.generateWasmMemoryFunctions();

        // env.now import
        const now_fn_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_fn = core.LLVMAddFunction(compiler.module, "nova_time_now", now_fn_type);
        core.LLVMAddTargetDependentFunctionAttr(now_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(now_fn, "wasm-import-name", "now");
        try compiler.func_map.put("nova_time_now", now_fn);

        // env.get_stacktrace import
        const get_st_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const get_st_fn = core.LLVMAddFunction(compiler.module, "nova_get_stacktrace", get_st_type);
        core.LLVMAddTargetDependentFunctionAttr(get_st_fn, "wasm-import-module", "env");
        core.LLVMAddTargetDependentFunctionAttr(get_st_fn, "wasm-import-name", "get_stacktrace");
        try compiler.func_map.put("nova_get_stacktrace", get_st_fn);

        // Test-harness + abort functions referenced by stdlib assert helpers and
        // @test functions (both are compiled even in a plain build). The native
        // else-branch declares these against the runtime; the wasm branch used to
        // omit them, so ANY program failed codegen on `nova_test_fail` (#23).
        // Declare them as host imports so references resolve and the module links;
        // a real wasm build never calls them.
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

        // Runtime functions the stdlib references that the native else-branch
        // declares against libnova_runtime — crypto (crypto.nova), env/args
        // (env.nova). Declared as host imports so those modules compile to wasm
        // and link (--allow-undefined). The host provides them. Signatures mirror
        // the native declarations.
        {
            var one_ptr = [_]types.LLVMTypeRef{compiler.ptr_type};
            var two_ptr = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
            var one_val = [_]types.LLVMTypeRef{compiler.val_type};
            const ptr_1ptr = core.LLVMFunctionType(compiler.ptr_type, &one_ptr, 1, 0); // (ptr)->ptr
            const void_2ptr = core.LLVMFunctionType(compiler.void_type, &two_ptr, 2, 0); // (ptr,ptr)->void
            const ptr_2ptr = core.LLVMFunctionType(compiler.ptr_type, &two_ptr, 2, 0); // (ptr,ptr)->ptr
            const val_0 = core.LLVMFunctionType(compiler.val_type, &one_ptr, 0, 0); // ()->val
            const val_1val = core.LLVMFunctionType(compiler.val_type, &one_val, 1, 0); // (val)->val
            const ptr_1val = core.LLVMFunctionType(compiler.ptr_type, &one_val, 1, 0); // (val)->ptr
            const Imp2 = struct { name: [:0]const u8, ty: types.LLVMTypeRef };
            const imps2 = [_]Imp2{
                .{ .name = "nova_getenv", .ty = ptr_1ptr },
                .{ .name = "nova_setenv", .ty = void_2ptr },
                .{ .name = "nova_arg_count", .ty = val_0 },
                .{ .name = "nova_arg_at", .ty = val_1val },
                .{ .name = "nova_sha256", .ty = ptr_1ptr },
                .{ .name = "nova_sha512", .ty = ptr_1ptr },
                .{ .name = "nova_sha1", .ty = ptr_1ptr },
                .{ .name = "nova_md5", .ty = ptr_1ptr },
                .{ .name = "nova_hmac_sha256", .ty = ptr_2ptr },
                .{ .name = "nova_random_hex", .ty = ptr_1val },
            };
            for (imps2) |imp| {
                const f = core.LLVMAddFunction(compiler.module, imp.name.ptr, imp.ty);
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-module", "env");
                core.LLVMAddTargetDependentFunctionAttr(f, "wasm-import-name", imp.name.ptr);
                try compiler.func_map.put(imp.name, f);
            }
        }
    } else {
        // printf
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

        // malloc
        var malloc_params = [_]types.LLVMTypeRef{compiler.val_type};
        const malloc_type = core.LLVMFunctionType(compiler.ptr_type, &malloc_params, 1, 0);
        const malloc_fn = core.LLVMAddFunction(compiler.module, "malloc", malloc_type);
        try compiler.func_map.put("malloc", malloc_fn);

        // nova_time_now
        const now_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_fn = core.LLVMAddFunction(compiler.module, "nova_time_now", now_type);
        try compiler.func_map.put("nova_time_now", now_fn);

        // nova_time_now_ns — monotonic-ish nanosecond clock. nova_time_now only has 1-second
        // resolution, which cannot express a latency or a sub-second rate.
        const now_ns_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const now_ns_fn = core.LLVMAddFunction(compiler.module, "nova_time_now_ns", now_ns_type);
        try compiler.func_map.put("nova_time_now_ns", now_ns_fn);

        // nova_get_stacktrace
        const get_st_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const get_st_fn = core.LLVMAddFunction(compiler.module, "nova_get_stacktrace", get_st_type);
        try compiler.func_map.put("nova_get_stacktrace", get_st_fn);

        // M3-C: LLVM coroutine intrinsics + frame allocator (native only; async is
        // forbidden under wasm). Declares llvm.coro.* into func_map so async-fn
        // codegen can call them; the LLVMRunPasses(default<O…>) pipeline lowers them.
        try setupCoroutineSupport(&compiler);

        // Declare helper functions in func_map so that Nova code can call them
        var one_param_i32 = [_]types.LLVMTypeRef{compiler.i32_type};
        var one_param_ptr = [_]types.LLVMTypeRef{compiler.ptr_type};
        
        // close
        const close_type = core.LLVMFunctionType(compiler.i32_type, &one_param_i32, 1, 0);
        const close_fn = core.LLVMAddFunction(compiler.module, "nova_close", close_type);
        try compiler.func_map.put("close", close_fn);
        try compiler.func_map.put("nova_close", close_fn);

        // nova_socket_listen
        const listen_type = core.LLVMFunctionType(compiler.i32_type, &one_param_i32, 1, 0);
        const listen_fn = core.LLVMAddFunction(compiler.module, "nova_socket_listen", listen_type);
        try compiler.func_map.put("nova_socket_listen", listen_fn);

        // nova_socket_accept
        const accept_type = core.LLVMFunctionType(compiler.i32_type, &one_param_i32, 1, 0);
        const accept_fn = core.LLVMAddFunction(compiler.module, "nova_socket_accept", accept_type);
        try compiler.func_map.put("nova_socket_accept", accept_fn);

        // nova_socket_send
        var send_params = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.ptr_type };
        const send_type = core.LLVMFunctionType(compiler.i32_type, &send_params, 2, 0);
        const send_fn = core.LLVMAddFunction(compiler.module, "nova_socket_send", send_type);
        try compiler.func_map.put("nova_socket_send", send_fn);

        // nova_socket_send_n (fd, ptr, len) — length-aware binary send
        var send_n_params = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.ptr_type, compiler.i32_type };
        const send_n_type = core.LLVMFunctionType(compiler.i32_type, &send_n_params, 3, 0);
        const send_n_fn = core.LLVMAddFunction(compiler.module, "nova_socket_send_n", send_n_type);
        try compiler.func_map.put("nova_socket_send_n", send_n_fn);

        // nova_socket_recv
        var recv_params = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.ptr_type, compiler.i32_type };
        const recv_type = core.LLVMFunctionType(compiler.i32_type, &recv_params, 3, 0);
        const recv_fn = core.LLVMAddFunction(compiler.module, "nova_socket_recv", recv_type);
        try compiler.func_map.put("nova_socket_recv", recv_fn);

        // nova_socket_connect
        var connect_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        const connect_type = core.LLVMFunctionType(compiler.i32_type, &connect_params, 2, 0);
        const connect_fn = core.LLVMAddFunction(compiler.module, "nova_socket_connect", connect_type);
        try compiler.func_map.put("nova_socket_connect", connect_fn);

        // nova_socket_connect_timeout (host ptr, port, ms) -> fd (D6)
        var connect_to_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type, compiler.i32_type };
        const connect_to_type = core.LLVMFunctionType(compiler.i32_type, &connect_to_params, 3, 0);
        const connect_to_fn = core.LLVMAddFunction(compiler.module, "nova_socket_connect_timeout", connect_to_type);
        try compiler.func_map.put("nova_socket_connect_timeout", connect_to_fn);

        // nova_socket_set_timeout (fd, ms) -> 0/-1 (D6)
        var set_to_params = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.i32_type };
        const set_to_type = core.LLVMFunctionType(compiler.i32_type, &set_to_params, 2, 0);
        const set_to_fn = core.LLVMAddFunction(compiler.module, "nova_socket_set_timeout", set_to_type);
        try compiler.func_map.put("nova_socket_set_timeout", set_to_fn);

        // nova_test_reset: void -> void
        const test_reset_type = core.LLVMFunctionType(compiler.void_type, null, 0, 0);
        const test_reset_fn = core.LLVMAddFunction(compiler.module, "nova_test_reset", test_reset_type);
        try compiler.func_map.put("nova_test_reset", test_reset_fn);

        // nova_optional_deref_fail: (ptr) -> void — §3.4/P2-14 absent-optional deref abort.
        const opt_fail_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const opt_fail_fn = core.LLVMAddFunction(compiler.module, "nova_optional_deref_fail", opt_fail_type);
        try compiler.func_map.put("nova_optional_deref_fail", opt_fail_fn);

        // nova_panic: (ptr msg) -> void — unrecoverable error (bounds, broken invariant). Loud abort.
        const panic_fn = core.LLVMAddFunction(compiler.module, "nova_panic", core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_panic", panic_fn);

        // nova_test_begin: (ptr) -> void — records the running @test's name so nova_test_fail
        // can report WHICH test failed (the harness's own FAIL branch is unreachable past _Exit).
        const test_begin_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const test_begin_fn = core.LLVMAddFunction(compiler.module, "nova_test_begin", test_begin_type);
        try compiler.func_map.put("nova_test_begin", test_begin_fn);

        // nova_test_fail: (ptr) -> void
        const test_fail_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const test_fail_fn = core.LLVMAddFunction(compiler.module, "nova_test_fail", test_fail_type);
        try compiler.func_map.put("nova_test_fail", test_fail_fn);

        // nova_test_did_fail: void -> i32
        const test_did_fail_type = core.LLVMFunctionType(compiler.i32_type, null, 0, 0);
        const test_did_fail_fn = core.LLVMAddFunction(compiler.module, "nova_test_did_fail", test_did_fail_type);
        try compiler.func_map.put("nova_test_did_fail", test_did_fail_fn);

        // nova_test_fail_message: void -> ptr
        const test_fail_msg_type = core.LLVMFunctionType(compiler.ptr_type, null, 0, 0);
        const test_fail_msg_fn = core.LLVMAddFunction(compiler.module, "nova_test_fail_message", test_fail_msg_type);
        try compiler.func_map.put("nova_test_fail_message", test_fail_msg_fn);

        // nova_tls_new: (i32, ptr) -> ptr
        var tls_new_params = [_]types.LLVMTypeRef{ compiler.i32_type, compiler.ptr_type };
        const tls_new_type = core.LLVMFunctionType(compiler.ptr_type, &tls_new_params, 2, 0);
        const tls_new_fn = core.LLVMAddFunction(compiler.module, "nova_tls_new", tls_new_type);
        try compiler.func_map.put("nova_tls_new", tls_new_fn);

        // nova_tls_handshake: (ptr) -> i32
        const tls_handshake_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const tls_handshake_fn = core.LLVMAddFunction(compiler.module, "nova_tls_handshake", tls_handshake_type);
        try compiler.func_map.put("nova_tls_handshake", tls_handshake_fn);

        // nova_tls_write: (ptr, ptr) -> i32
        var tls_write_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const tls_write_type = core.LLVMFunctionType(compiler.i32_type, &tls_write_params, 2, 0);
        const tls_write_fn = core.LLVMAddFunction(compiler.module, "nova_tls_write", tls_write_type);
        try compiler.func_map.put("nova_tls_write", tls_write_fn);

        // nova_tls_read: (ptr, ptr, i32) -> i32
        var tls_read_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const tls_read_type = core.LLVMFunctionType(compiler.i32_type, &tls_read_params, 3, 0);
        const tls_read_fn = core.LLVMAddFunction(compiler.module, "nova_tls_read", tls_read_type);
        try compiler.func_map.put("nova_tls_read", tls_read_fn);

        // nova_tls_free: (ptr) -> void
        const tls_free_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const tls_free_fn = core.LLVMAddFunction(compiler.module, "nova_tls_free", tls_free_type);
        try compiler.func_map.put("nova_tls_free", tls_free_fn);

        // TDS-tunneled TLS (MSSQL): nova_tds_tls_new (i32 fd)->ptr, handshake (ptr)->i32,
        // write (ptr,ptr,i32)->i32, read (ptr,ptr,i32)->i32, free (ptr)->void.
        var tds_new_params = [_]types.LLVMTypeRef{compiler.i32_type};
        const tds_new_type = core.LLVMFunctionType(compiler.ptr_type, &tds_new_params, 1, 0);
        try compiler.func_map.put("nova_tds_tls_new", core.LLVMAddFunction(compiler.module, "nova_tds_tls_new", tds_new_type));
        const tds_hs_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_tds_tls_handshake", core.LLVMAddFunction(compiler.module, "nova_tds_tls_handshake", tds_hs_type));
        var tds_wr_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const tds_wr_type = core.LLVMFunctionType(compiler.i32_type, &tds_wr_params, 3, 0);
        try compiler.func_map.put("nova_tds_tls_write", core.LLVMAddFunction(compiler.module, "nova_tds_tls_write", tds_wr_type));
        try compiler.func_map.put("nova_tds_tls_read", core.LLVMAddFunction(compiler.module, "nova_tds_tls_read", tds_wr_type));
        const tds_free_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_tds_tls_free", core.LLVMAddFunction(compiler.module, "nova_tds_tls_free", tds_free_type));

        // Async memory-BIO TLS (driver-agnostic, non-blocking; net/asynctls.nova pumps it):
        //   nova_mtls_new(ptr hostname, i32 verify)->ptr, handshake(ptr)->i32,
        //   feed(ptr,ptr,i32)->void, mark_closed(ptr)->void, pull(ptr,ptr,i32)->i32,
        //   pending_out(ptr)->i32, write(ptr,ptr,i32)->i32, read(ptr,ptr,i32)->i32, free(ptr)->void.
        var mtls_new_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        const mtls_new_type = core.LLVMFunctionType(compiler.ptr_type, &mtls_new_params, 2, 0);
        try compiler.func_map.put("nova_mtls_new", core.LLVMAddFunction(compiler.module, "nova_mtls_new", mtls_new_type));
        var mtls_srv_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type, compiler.ptr_type, compiler.i32_type };
        const mtls_srv_type = core.LLVMFunctionType(compiler.ptr_type, &mtls_srv_params, 4, 0);
        try compiler.func_map.put("nova_mtls_new_server", core.LLVMAddFunction(compiler.module, "nova_mtls_new_server", mtls_srv_type));
        const mtls_hs_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_mtls_handshake", core.LLVMAddFunction(compiler.module, "nova_mtls_handshake", mtls_hs_type));
        var mtls_pp_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const mtls_feed_type = core.LLVMFunctionType(compiler.void_type, &mtls_pp_params, 3, 0);
        try compiler.func_map.put("nova_mtls_feed", core.LLVMAddFunction(compiler.module, "nova_mtls_feed", mtls_feed_type));
        const mtls_closed_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_mtls_mark_closed", core.LLVMAddFunction(compiler.module, "nova_mtls_mark_closed", mtls_closed_type));
        const mtls_pp_i32_type = core.LLVMFunctionType(compiler.i32_type, &mtls_pp_params, 3, 0);
        try compiler.func_map.put("nova_mtls_pull", core.LLVMAddFunction(compiler.module, "nova_mtls_pull", mtls_pp_i32_type));
        try compiler.func_map.put("nova_mtls_write", core.LLVMAddFunction(compiler.module, "nova_mtls_write", mtls_pp_i32_type));
        try compiler.func_map.put("nova_mtls_read", core.LLVMAddFunction(compiler.module, "nova_mtls_read", mtls_pp_i32_type));
        const mtls_pend_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_mtls_pending_out", core.LLVMAddFunction(compiler.module, "nova_mtls_pending_out", mtls_pend_type));
        const mtls_free_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        try compiler.func_map.put("nova_mtls_free", core.LLVMAddFunction(compiler.module, "nova_mtls_free", mtls_free_type));

        // nova_getenv: (ptr) -> ptr
        const getenv_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const getenv_fn = core.LLVMAddFunction(compiler.module, "nova_getenv", getenv_type);
        try compiler.func_map.put("nova_getenv", getenv_fn);

        // nova_setenv: (ptr, ptr) -> void
        var setenv_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const setenv_type = core.LLVMFunctionType(compiler.void_type, &setenv_params, 2, 0);
        const setenv_fn = core.LLVMAddFunction(compiler.module, "nova_setenv", setenv_type);
        try compiler.func_map.put("nova_setenv", setenv_fn);

        // nova_arg_count: () -> i64 ; nova_arg_at: (i64) -> ptr(string) — command-line args (env.args()).
        const argc_type = core.LLVMFunctionType(compiler.val_type, &one_param_ptr, 0, 0);
        try compiler.func_map.put("nova_arg_count", core.LLVMAddFunction(compiler.module, "nova_arg_count", argc_type));
        var argat_params = [_]types.LLVMTypeRef{compiler.val_type};
        const argat_type = core.LLVMFunctionType(compiler.val_type, &argat_params, 1, 0);
        try compiler.func_map.put("nova_arg_at", core.LLVMAddFunction(compiler.module, "nova_arg_at", argat_type));

        // nova_sha256: (ptr) -> ptr
        const sha256_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const sha256_fn = core.LLVMAddFunction(compiler.module, "nova_sha256", sha256_type);
        try compiler.func_map.put("nova_sha256", sha256_fn);

        // nova_md5: (ptr) -> ptr
        const md5_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const md5_fn = core.LLVMAddFunction(compiler.module, "nova_md5", md5_type);
        try compiler.func_map.put("nova_md5", md5_fn);

        // C6 crypto: nova_sha512 (ptr)->ptr, nova_hmac_sha256 (ptr,ptr)->ptr,
        // nova_random_hex (i64)->ptr — all return a hex Nova string.
        const sha512_fn = core.LLVMAddFunction(compiler.module, "nova_sha512", core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_sha512", sha512_fn);

        // nova_sha1: (ptr) -> ptr (hex)
        const sha1_fn = core.LLVMAddFunction(compiler.module, "nova_sha1", core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_sha1", sha1_fn);

        // nova_mysql_scramble / nova_mysql_sha2_scramble: (ptr password, ptr salt, i32 salt_len) -> ptr (raw bytes)
        var scramble_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const scramble_fn = core.LLVMAddFunction(compiler.module, "nova_mysql_scramble", core.LLVMFunctionType(compiler.ptr_type, &scramble_params, 3, 0));
        try compiler.func_map.put("nova_mysql_scramble", scramble_fn);
        const scramble2_fn = core.LLVMAddFunction(compiler.module, "nova_mysql_sha2_scramble", core.LLVMFunctionType(compiler.ptr_type, &scramble_params, 3, 0));
        try compiler.func_map.put("nova_mysql_sha2_scramble", scramble2_fn);

        var two_ptr = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const hmac_fn = core.LLVMAddFunction(compiler.module, "nova_hmac_sha256", core.LLVMFunctionType(compiler.ptr_type, &two_ptr, 2, 0));
        try compiler.func_map.put("nova_hmac_sha256", hmac_fn);

        // C1 (SCRAM): raw-byte crypto primitives.
        // nova_hmac_sha256_raw (ptr,ptr)->ptr (32 raw bytes); nova_sha256_raw (ptr)->ptr (32 raw bytes).
        const hmac_raw_fn = core.LLVMAddFunction(compiler.module, "nova_hmac_sha256_raw", core.LLVMFunctionType(compiler.ptr_type, &two_ptr, 2, 0));
        try compiler.func_map.put("nova_hmac_sha256_raw", hmac_raw_fn);
        const sha256_raw_fn = core.LLVMAddFunction(compiler.module, "nova_sha256_raw", core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_sha256_raw", sha256_raw_fn);
        // W7 gzip (over the already-linked zlib): (ptr in) -> ptr (length-prefixed binary buffer).
        const gzc_fn = core.LLVMAddFunction(compiler.module, "nova_gzip_compress", core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_gzip_compress", gzc_fn);
        const gzd_fn = core.LLVMAddFunction(compiler.module, "nova_gzip_decompress", core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0));
        try compiler.func_map.put("nova_gzip_decompress", gzd_fn);
        // nova_pbkdf2_hmac_sha256 (ptr password, ptr salt, i64 iters, i64 dklen) -> ptr (raw bytes)
        var pbkdf2_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.val_type, compiler.val_type };
        const pbkdf2_fn = core.LLVMAddFunction(compiler.module, "nova_pbkdf2_hmac_sha256", core.LLVMFunctionType(compiler.ptr_type, &pbkdf2_params, 4, 0));
        try compiler.func_map.put("nova_pbkdf2_hmac_sha256", pbkdf2_fn);

        var one_i64 = [_]types.LLVMTypeRef{compiler.val_type};
        const rand_fn = core.LLVMAddFunction(compiler.module, "nova_random_hex", core.LLVMFunctionType(compiler.ptr_type, &one_i64, 1, 0));
        try compiler.func_map.put("nova_random_hex", rand_fn);

        // D6: nova_rsa_oaep_encrypt (ptr pem, ptr data, i32 data_len) -> ptr (RSA ciphertext, raw bytes)
        var rsa_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const rsa_fn = core.LLVMAddFunction(compiler.module, "nova_rsa_oaep_encrypt", core.LLVMFunctionType(compiler.ptr_type, &rsa_params, 3, 0));
        try compiler.func_map.put("nova_rsa_oaep_encrypt", rsa_fn);

        // nova_process_spawn: (ptr, ptr) -> ptr
        var process_spawn_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const process_spawn_type = core.LLVMFunctionType(compiler.ptr_type, &process_spawn_params, 2, 0);
        const process_spawn_fn = core.LLVMAddFunction(compiler.module, "nova_process_spawn", process_spawn_type);
        try compiler.func_map.put("nova_process_spawn", process_spawn_fn);

        // I4: nova_process_spawn_isolated: (cmd_ptr, args_ptr, ns_flags:i64, rootfs_ptr, host_ptr,
        //     drop_caps:i32, no_new_privs:i32, seccomp:i32) -> ptr
        var process_iso_params = [_]types.LLVMTypeRef{
            compiler.ptr_type, compiler.ptr_type, compiler.i64_type, compiler.ptr_type,
            compiler.ptr_type, compiler.i32_type, compiler.i32_type, compiler.i32_type,
        };
        const process_iso_type = core.LLVMFunctionType(compiler.ptr_type, &process_iso_params, 8, 0);
        const process_iso_fn = core.LLVMAddFunction(compiler.module, "nova_process_spawn_isolated", process_iso_type);
        try compiler.func_map.put("nova_process_spawn_isolated", process_iso_fn);

        // nova_process_write_stdin: (ptr, ptr) -> i32
        var process_write_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const process_write_type = core.LLVMFunctionType(compiler.i32_type, &process_write_params, 2, 0);
        const process_write_fn = core.LLVMAddFunction(compiler.module, "nova_process_write_stdin", process_write_type);
        try compiler.func_map.put("nova_process_write_stdin", process_write_fn);

        // nova_process_read_stdout: (ptr, ptr, i32) -> i32
        var process_read_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const process_read_type = core.LLVMFunctionType(compiler.i32_type, &process_read_params, 3, 0);
        const process_read_fn = core.LLVMAddFunction(compiler.module, "nova_process_read_stdout", process_read_type);
        try compiler.func_map.put("nova_process_read_stdout", process_read_fn);

        // nova_process_wait: (ptr) -> i32
        const process_wait_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const process_wait_fn = core.LLVMAddFunction(compiler.module, "nova_process_wait", process_wait_type);
        try compiler.func_map.put("nova_process_wait", process_wait_fn);

        // nova_process_pid: (ptr) -> i64
        const process_pid_type = core.LLVMFunctionType(compiler.i64_type, &one_param_ptr, 1, 0);
        const process_pid_fn = core.LLVMAddFunction(compiler.module, "nova_process_pid", process_pid_type);
        try compiler.func_map.put("nova_process_pid", process_pid_fn);

        // nova_process_try_wait: (ptr) -> i32   (non-blocking exit poll; -2 running, -1 error, else code)
        const process_trywait_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const process_trywait_fn = core.LLVMAddFunction(compiler.module, "nova_process_try_wait", process_trywait_type);
        try compiler.func_map.put("nova_process_try_wait", process_trywait_fn);

        // nova_process_kill: (ptr, i32) -> i32
        var process_kill_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        const process_kill_type = core.LLVMFunctionType(compiler.i32_type, &process_kill_params, 2, 0);
        const process_kill_fn = core.LLVMAddFunction(compiler.module, "nova_process_kill", process_kill_type);
        try compiler.func_map.put("nova_process_kill", process_kill_fn);

        // nova_process_free: (ptr) -> void
        const process_free_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const process_free_fn = core.LLVMAddFunction(compiler.module, "nova_process_free", process_free_type);
        try compiler.func_map.put("nova_process_free", process_free_fn);

        // nova_fs_watcher_create: (ptr) -> ptr
        const watcher_create_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const watcher_create_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_create", watcher_create_type);
        try compiler.func_map.put("nova_fs_watcher_create", watcher_create_fn);

        // nova_fs_watcher_next_event: (ptr) -> ptr
        const watcher_next_event_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const watcher_next_event_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_next_event", watcher_next_event_type);
        try compiler.func_map.put("nova_fs_watcher_next_event", watcher_next_event_fn);

        // nova_fs_watcher_free_event: (ptr) -> void
        const watcher_free_event_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const watcher_free_event_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_free_event", watcher_free_event_type);
        try compiler.func_map.put("nova_fs_watcher_free_event", watcher_free_event_fn);

        // nova_fs_watcher_close: (ptr) -> void
        const watcher_close_type = core.LLVMFunctionType(compiler.void_type, &one_param_ptr, 1, 0);
        const watcher_close_fn = core.LLVMAddFunction(compiler.module, "nova_fs_watcher_close", watcher_close_type);
        try compiler.func_map.put("nova_fs_watcher_close", watcher_close_fn);

        // nova_exit: (i32) -> void
        const exit_type = core.LLVMFunctionType(compiler.void_type, &one_param_i32, 1, 0);
        const exit_fn = core.LLVMAddFunction(compiler.module, "nova_exit", exit_type);
        try compiler.func_map.put("nova_exit", exit_fn);

        // nova_arc_audit_report: void -> i64 (count of objects still live at exit).
        // F5 §3.5.1 — the generated test main calls this unconditionally; the
        // runtime returns 0 when NOVA_ARC_AUDIT is unset.
        const audit_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
        const audit_fn = core.LLVMAddFunction(compiler.module, "nova_arc_audit_report", audit_type);
        try compiler.func_map.put("nova_arc_audit_report", audit_fn);

        // nova_file_open
        var open_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const open_type = core.LLVMFunctionType(compiler.ptr_type, &open_params, 2, 0);
        const open_fn = core.LLVMAddFunction(compiler.module, "nova_file_open", open_type);
        try compiler.func_map.put("nova_file_open", open_fn);

        // nova_file_close
        const fclose_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const fclose_fn = core.LLVMAddFunction(compiler.module, "nova_file_close", fclose_type);
        try compiler.func_map.put("nova_file_close", fclose_fn);

        // nova_file_read
        var fread_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const fread_type = core.LLVMFunctionType(compiler.i32_type, &fread_params, 3, 0);
        const fread_fn = core.LLVMAddFunction(compiler.module, "nova_file_read", fread_type);
        try compiler.func_map.put("nova_file_read", fread_fn);

        // nova_file_write
        var fwrite_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const fwrite_type = core.LLVMFunctionType(compiler.i32_type, &fwrite_params, 3, 0);
        const fwrite_fn = core.LLVMAddFunction(compiler.module, "nova_file_write", fwrite_type);
        try compiler.func_map.put("nova_file_write", fwrite_fn);

        // nova_file_read_all: (ptr, ptr, i32) -> i32
        var fread_all_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const fread_all_type = core.LLVMFunctionType(compiler.i32_type, &fread_all_params, 3, 0);
        const fread_all_fn = core.LLVMAddFunction(compiler.module, "nova_file_read_all", fread_all_type);
        try compiler.func_map.put("nova_file_read_all", fread_all_fn);

        // nova_file_write_all: (ptr, ptr, i32) -> i32
        var fwrite_all_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type, compiler.i32_type };
        const fwrite_all_type = core.LLVMFunctionType(compiler.i32_type, &fwrite_all_params, 3, 0);
        const fwrite_all_fn = core.LLVMAddFunction(compiler.module, "nova_file_write_all", fwrite_all_type);
        try compiler.func_map.put("nova_file_write_all", fwrite_all_fn);

        // nova_file_seek: (void*, long offset, int whence) -> int. A7/F3 §6: the C
        // offset is `long` — a >2GB seek needs a 64-bit offset (was i32, truncating).
        var fseek_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i64_type, compiler.i32_type };
        const fseek_type = core.LLVMFunctionType(compiler.i32_type, &fseek_params, 3, 0);
        const fseek_fn = core.LLVMAddFunction(compiler.module, "nova_file_seek", fseek_type);
        try compiler.func_map.put("nova_file_seek", fseek_fn);

        // nova_file_tell: (void*) -> long. A7/F3 §6: C returns `long` — a >2GB position
        // needs 64 bits (was i32, truncating the high word).
        const ftell_type = core.LLVMFunctionType(compiler.i64_type, &one_param_ptr, 1, 0);
        const ftell_fn = core.LLVMAddFunction(compiler.module, "nova_file_tell", ftell_type);
        try compiler.func_map.put("nova_file_tell", ftell_fn);

        // nova_file_eof: (ptr) -> i32
        const feof_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const feof_fn = core.LLVMAddFunction(compiler.module, "nova_file_eof", feof_type);
        try compiler.func_map.put("nova_file_eof", feof_fn);

        // nova_file_flush: (ptr) -> i32
        const fflush_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const fflush_fn = core.LLVMAddFunction(compiler.module, "nova_file_flush", fflush_type);
        try compiler.func_map.put("nova_file_flush", fflush_fn);

        // nova_file_exists: (ptr) -> i32
        const fexists_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const fexists_fn = core.LLVMAddFunction(compiler.module, "nova_file_exists", fexists_type);
        try compiler.func_map.put("nova_file_exists", fexists_fn);

        // nova_dir_open: (ptr) -> ptr
        const dir_open_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const dir_open_fn = core.LLVMAddFunction(compiler.module, "nova_dir_open", dir_open_type);
        try compiler.func_map.put("nova_dir_open", dir_open_fn);

        // nova_dir_read: (ptr) -> ptr
        const dir_read_type = core.LLVMFunctionType(compiler.ptr_type, &one_param_ptr, 1, 0);
        const dir_read_fn = core.LLVMAddFunction(compiler.module, "nova_dir_read", dir_read_type);
        try compiler.func_map.put("nova_dir_read", dir_read_fn);

        // nova_dir_close: (ptr) -> i32
        const dir_close_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const dir_close_fn = core.LLVMAddFunction(compiler.module, "nova_dir_close", dir_close_type);
        try compiler.func_map.put("nova_dir_close", dir_close_fn);

        // nova_dir_create: (ptr, i32) -> i32
        var dir_create_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.i32_type };
        const dir_create_type = core.LLVMFunctionType(compiler.i32_type, &dir_create_params, 2, 0);
        const dir_create_fn = core.LLVMAddFunction(compiler.module, "nova_dir_create", dir_create_type);
        try compiler.func_map.put("nova_dir_create", dir_create_fn);

        // nova_dir_remove: (ptr) -> i32
        const dir_remove_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const dir_remove_fn = core.LLVMAddFunction(compiler.module, "nova_dir_remove", dir_remove_type);
        try compiler.func_map.put("nova_dir_remove", dir_remove_fn);

        // nova_dir_rename: (ptr, ptr) -> i32
        var dir_rename_params = [_]types.LLVMTypeRef{ compiler.ptr_type, compiler.ptr_type };
        const dir_rename_type = core.LLVMFunctionType(compiler.i32_type, &dir_rename_params, 2, 0);
        const dir_rename_fn = core.LLVMAddFunction(compiler.module, "nova_dir_rename", dir_rename_type);
        try compiler.func_map.put("nova_dir_rename", dir_rename_fn);

        // nova_dir_exists: (ptr) -> i32
        const dir_exists_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const dir_exists_fn = core.LLVMAddFunction(compiler.module, "nova_dir_exists", dir_exists_type);
        try compiler.func_map.put("nova_dir_exists", dir_exists_fn);

        // nova_dir_is_dir: (ptr) -> i32
        const dir_is_dir_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const dir_is_dir_fn = core.LLVMAddFunction(compiler.module, "nova_dir_is_dir", dir_is_dir_type);
        try compiler.func_map.put("nova_dir_is_dir", dir_is_dir_fn);

        // nova_dir_getcwd: () -> ptr
        const dir_getcwd_type = core.LLVMFunctionType(compiler.ptr_type, &[_]types.LLVMTypeRef{}, 0, 0);
        const dir_getcwd_fn = core.LLVMAddFunction(compiler.module, "nova_dir_getcwd", dir_getcwd_type);
        try compiler.func_map.put("nova_dir_getcwd", dir_getcwd_fn);

        // nova_dir_chdir: (ptr) -> i32
        const dir_chdir_type = core.LLVMFunctionType(compiler.i32_type, &one_param_ptr, 1, 0);
        const dir_chdir_fn = core.LLVMAddFunction(compiler.module, "nova_dir_chdir", dir_chdir_type);
        try compiler.func_map.put("nova_dir_chdir", dir_chdir_fn);


        // (nova_concurrency_spawn / nova_concurrency_sleep declarations REMOVED with `fiber` — the C-runtime
        // fiber shim. fiber.spawn ran the closure inline (no concurrency) and fiber.sleep blocked the thread;
        // both are superseded by async/await + `spawn` (asio coroutines) and `await sleep` (nova_await_timer).)

        // (Exception runtime declarations REMOVED with `throw` — specs §5.5, plan P2-12.)
        //
        // `nova_push_exception_frame` / `nova_pop_exception_frame` / `nova_throw`, and the
        // `_setjmp` declaration that existed ONLY to serve them (with its `returns_twice`
        // attribute), are gone. The model was setjmp/longjmp: no unwinding, so ARC released
        // only the catching frame's try-block locals and every frame in between leaked; the
        // thrown value was truncated to an i32, so `throw "msg"` was caught as a number; and
        // longjmp out of a C++20 coroutine — which is what every `async fn` compiles to — is
        // undefined behaviour. Errors are VALUES now (`T | Error`, plan P2-13).

        // nova_bytes_free
        var bytes_free_params = [_]types.LLVMTypeRef{compiler.val_type};
        const bytes_free_type = core.LLVMFunctionType(compiler.void_type, &bytes_free_params, 1, 0);
        const bytes_free_fn = core.LLVMAddFunction(compiler.module, "nova_bytes_free", bytes_free_type);
        try compiler.func_map.put("nova_bytes_free", bytes_free_fn);

        // nova_channel_create
        var ch_create_params = [_]types.LLVMTypeRef{compiler.i32_type};
        const ch_create_type = core.LLVMFunctionType(compiler.val_type, &ch_create_params, 1, 0);
        const ch_create_fn = core.LLVMAddFunction(compiler.module, "nova_channel_create", ch_create_type);
        try compiler.func_map.put("nova_channel_create", ch_create_fn);

        // nova_channel_send
        var ch_send_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
        const ch_send_type = core.LLVMFunctionType(compiler.void_type, &ch_send_params, 2, 0);
        const ch_send_fn = core.LLVMAddFunction(compiler.module, "nova_channel_send", ch_send_type);
        try compiler.func_map.put("nova_channel_send", ch_send_fn);

        // nova_channel_recv
        var ch_recv_params = [_]types.LLVMTypeRef{compiler.val_type};
        const ch_recv_type = core.LLVMFunctionType(compiler.val_type, &ch_recv_params, 1, 0);
        const ch_recv_fn = core.LLVMAddFunction(compiler.module, "nova_channel_recv", ch_recv_type);
        try compiler.func_map.put("nova_channel_recv", ch_recv_fn);

        // Mutex, CondVar, RwLock helpers:
        const void_type = compiler.void_type;
        const val_type = compiler.val_type;

        // nova_mutex_create
        const mutex_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const mutex_create_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_create", mutex_create_type);
        try compiler.func_map.put("nova_mutex_create", mutex_create_fn);

        // nova_thread_id / nova_worker_count — current io_context worker index + count, for per-thread
        // lock-free structures (the HAProxy-style reverse-proxy connection pool).
        try compiler.func_map.put("nova_thread_id", core.LLVMAddFunction(compiler.module, "nova_thread_id", mutex_create_type));
        try compiler.func_map.put("nova_worker_count", core.LLVMAddFunction(compiler.module, "nova_worker_count", mutex_create_type));

        // nova_spin_create/lock/unlock — spinlock for async-hot-path critical sections (proxy pool)
        const spin_create_fn = core.LLVMAddFunction(compiler.module, "nova_spin_create", mutex_create_type);
        try compiler.func_map.put("nova_spin_create", spin_create_fn);
        var spin_p = [_]types.LLVMTypeRef{val_type};
        const spin_lu_type = core.LLVMFunctionType(void_type, &spin_p, 1, 0);
        try compiler.func_map.put("nova_spin_lock", core.LLVMAddFunction(compiler.module, "nova_spin_lock", spin_lu_type));
        try compiler.func_map.put("nova_spin_unlock", core.LLVMAddFunction(compiler.module, "nova_spin_unlock", spin_lu_type));
        // P4c: nova_pin_next_coro(rid) — pin the next spawned coroutine to reactor rid (share-nothing accept fan-out)
        try compiler.func_map.put("nova_pin_next_coro", core.LLVMAddFunction(compiler.module, "nova_pin_next_coro", spin_lu_type));
        // P4c: nova_serve_forever() — persistent share-nothing server drive (separate from nova_run)
        const void_noarg_type = core.LLVMFunctionType(void_type, null, 0, 0);
        try compiler.func_map.put("nova_hold_all_reactors", core.LLVMAddFunction(compiler.module, "nova_hold_all_reactors", void_noarg_type));

        // nova_mutex_lock
        var one_val_param = [_]types.LLVMTypeRef{val_type};
        const mutex_lock_type = core.LLVMFunctionType(void_type, &one_val_param, 1, 0);
        const mutex_lock_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_lock", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_lock", mutex_lock_fn);

        // nova_mutex_unlock
        const mutex_unlock_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_unlock", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_unlock", mutex_unlock_fn);

        // nova_condvar_create
        const cond_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const cond_create_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_create", cond_create_type);
        try compiler.func_map.put("nova_condvar_create", cond_create_fn);

        // nova_condvar_wait
        var two_val_params = [_]types.LLVMTypeRef{ val_type, val_type };
        const cond_wait_type = core.LLVMFunctionType(void_type, &two_val_params, 2, 0);
        const cond_wait_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_wait", cond_wait_type);
        try compiler.func_map.put("nova_condvar_wait", cond_wait_fn);

        // nova_condvar_signal
        const cond_signal_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_signal", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_signal", cond_signal_fn);

        // nova_condvar_broadcast
        const cond_broadcast_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_broadcast", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_broadcast", cond_broadcast_fn);

        // nova_rwlock_create
        const rw_create_type = core.LLVMFunctionType(val_type, null, 0, 0);
        const rw_create_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_create", rw_create_type);
        try compiler.func_map.put("nova_rwlock_create", rw_create_fn);

        // nova_rwlock_acquire_read
        const rw_acq_r_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_acquire_read", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_acquire_read", rw_acq_r_fn);

        // nova_rwlock_release_read
        const rw_rel_r_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_release_read", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_release_read", rw_rel_r_fn);

        // nova_rwlock_acquire_write
        const rw_acq_w_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_acquire_write", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_acquire_write", rw_acq_w_fn);

        // nova_rwlock_release_write
        const rw_rel_w_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_release_write", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_release_write", rw_rel_w_fn);

        // nova_bytes_alloc_persistent
        var bytes_alloc_p_params = [_]types.LLVMTypeRef{compiler.val_type};
        const bytes_alloc_p_type = core.LLVMFunctionType(compiler.val_type, &bytes_alloc_p_params, 1, 0);
        const bytes_alloc_p_fn = core.LLVMAddFunction(compiler.module, "nova_bytes_alloc_persistent", bytes_alloc_p_type);
        try compiler.func_map.put("nova_bytes_alloc_persistent", bytes_alloc_p_fn);

        // nova_channel_destroy
        const ch_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_channel_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_channel_destroy", ch_destroy_fn);

        // nova_mutex_destroy
        const mutex_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_mutex_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_mutex_destroy", mutex_destroy_fn);

        // nova_condvar_destroy
        const cond_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_condvar_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_condvar_destroy", cond_destroy_fn);

        // nova_rwlock_destroy
        const rw_destroy_fn = core.LLVMAddFunction(compiler.module, "nova_rwlock_destroy", mutex_lock_type);
        try compiler.func_map.put("nova_rwlock_destroy", rw_destroy_fn);

        // nova_retain
        var retain_params = [_]types.LLVMTypeRef{compiler.val_type};
        const retain_fn_type = core.LLVMFunctionType(compiler.void_type, &retain_params, 1, 0);
        const retain_fn = core.LLVMAddFunction(compiler.module, "nova_retain", retain_fn_type);
        try compiler.func_map.put("nova_retain", retain_fn);

        // nova_release
        const ptr_type = core.LLVMPointerType(compiler.void_type, 0);
        var release_params = [_]types.LLVMTypeRef{compiler.val_type, ptr_type};
        const release_fn_type = core.LLVMFunctionType(compiler.void_type, &release_params, 2, 0);
        const release_fn = core.LLVMAddFunction(compiler.module, "nova_release", release_fn_type);
        try compiler.func_map.put("nova_release", release_fn);
    }

    // T3 FFI: declare each `extern("lib") fn` as an LLVM external with a C-ABI signature.
    // Runs AFTER the runtime prelude so a symbol the runtime already declared (malloc/free/
    // memset/close/…) is found by the guard and reused — re-adding it would make LLVM rename
    // ours (`malloc.57`) into an undefined symbol. The symbol is the bare Nova name (no
    // mangling — must match the C symbol). Native only (the wasm target cannot link a native
    // library). `buildCallWithCasts` handles the boundary width/ptr casts.
    if (!is_wasm) {
        // Exported wrappers for Nova-string <-> C-`char*` marshalling (the header helpers
        // are static inline and unlinkable). Declared once; used by the FFI call path.
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
            // Record the signature for call-site string marshalling regardless of whether the
            // symbol is (re)declared below — a runtime-shared name still needs its arg/return
            // conversions applied when the user calls it via FFI.
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

    // Populate function_local_types for all functions
    for (compiler.functions.items) |func| {
        var local_types = std.StringHashMap([]const u8).init(allocator);
        var local_type_ids = std.StringHashMap(sema_types.TypeId).init(allocator);

        compiler.current_function_name = func.name;
        compiler.current_local_types = &local_types;
        compiler.current_local_type_ids = &local_type_ids;
        compiler.current_struct_name = null;
        compiler.current_module_prefix = null;
        // F4 4b: the context that makes `T` mean `string` for the rest of this body.
        compiler.current_instantiation = func.instantiation;
        compiler.current_instantiation_id = if (func.instantiation) |inst| sema_mono.live_inst_ids.get(inst) else null;
        // F4-5: the method's OWN type-params for a specialized method body (`T` -> `GetUser`).
        compiler.current_method_subst = func.method_subst;

        if (func.instantiation) |inst| {
            // `self` inside `List_string_push` is a `List<string>`, not a `List`.
            // The name-split below cannot learn that — `List_string_push` splits at
            // the first `_` to "List" — but the FunctionInfo already knows, and
            // typing `self` as the instantiation is what lets ARC reach
            // `__destruct_List_string` (G3) instead of the erased destructor.
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

        // Get parameter types & module prefix
        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                var decl_name = decl.fn_decl.name;
                if (compiler.getStructPrefix(decl.fn_decl)) |prefix| {
                    decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, decl.fn_decl.name });
                } else if (compiler.getModulePrefix(decl.fn_decl.span)) |mod_prefix| {
                    if (LlvmCompiler.isAlreadyNamespaced(decl.fn_decl.name)) {
                        decl_name = decl.fn_decl.name;
                    } else {
                        decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ mod_prefix, decl.fn_decl.name });
                    }
                }
                if (std.mem.eql(u8, decl_name, func.name)) {
                    compiler.current_module_prefix = compiler.getModulePrefix(decl.fn_decl.span);
                    for (decl.fn_decl.params) |p| {
                        if (p.type_name) |t| {
                            const p_type = try compiler.typeRefToString(t);
                            try local_types.put(p.name, p_type);
                        }
                    }
                    break;
                }
            } else if (decl == .struct_decl) {
                const s = decl.struct_decl;
                var matched = false;
                for (s.methods) |method| {
                    const fn_decl = method.decl;
                    // F4 4b: `List_string_push` must match back to `List.push`'s
                    // decl. The owner is the INSTANTIATION when there is one, so the
                    // symbol built here is the same one the collection site built.
                    const owner = func.instantiation orelse compiler.scopedStructName(s.name, s.span.file);
                    const decl_name = try compiler.methodSymbol(owner, fn_decl.name);
                    defer allocator.free(decl_name);

                    // F4-5: a specialized generic-method body is named `<decl_name>__<args>`
                    // (`Reg_decode__GetUser`). Match it back to the SAME decl so its params get
                    // typed — with `current_method_subst` already installed above, a `T`-typed
                    // param renders concrete. Without this the params were left untyped and a
                    // trait param (`src: ValueSource`) mis-dispatched at runtime.
                    const is_spec = func.method_subst != null and
                        std.mem.startsWith(u8, func.name, decl_name) and
                        func.name.len > decl_name.len + 2 and
                        std.mem.eql(u8, func.name[decl_name.len .. decl_name.len + 2], "__");
                    if (std.mem.eql(u8, decl_name, func.name) or is_spec) {
                        compiler.current_module_prefix = compiler.getModulePrefix(s.span);
                        for (fn_decl.params) |p| {
                            if (p.type_name) |t| {
                                // Substituted: `value: T` becomes `string`, which is
                                // what makes `isRefCountedType` true in this body.
                                const p_type = try compiler.typeRefToString(t);
                                try local_types.put(p.name, p_type);
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
                    const decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ e.name, fn_decl.name });
                    defer allocator.free(decl_name);

                    if (std.mem.eql(u8, decl_name, func.name)) {
                        compiler.current_module_prefix = compiler.getModulePrefix(e.span);
                        for (fn_decl.params) |p| {
                            if (p.type_name) |t| {
                                const p_type = try compiler.typeRefToString(t);
                                try local_types.put(p.name, p_type);
                            }
                        }
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            }
        }

        // If it's a lambda, resolve and add its parameter types
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

            // F2-6: closure parameter types now live in the TYPED IR — the checker types them from
            // their call sites (map/filter via `want`, `xs.map(f).map(g)` via the recorded method-arg
            // inference in methodReturn, `let g=..; g(x)` via the closure second-pass). Codegen reads
            // `typeOf(param_ident)` at every decision site, so the old `findLambdaCallSite` program-SCAN
            // that reverse-engineered these from the source is DELETED. `current_local_types` keeps only
            // a machine-word default here (`__env` is a `ptr`; other params an unread `i32` legacy slot).
            const decl_types = compiler.lambda_param_types.get(func.name);
            for (func.param_names, 0..) |param, pidx| {
                if (std.mem.eql(u8, param, "__env")) {
                    try local_types.put(param, "ptr");
                    continue;
                }
                // An explicit `(s: string)` annotation is authoritative; else keep the legacy
                // default (the typed IR still refines untyped params from their call sites).
                var typ: []const u8 = "i32";
                if (decl_types) |dts| {
                    const user_idx = pidx - 1; // params after __env
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

    // Deduplicate collected functions by name. A module imported via multiple
    // paths can be collected more than once; without this, LLVMAddFunction
    // would create a second function with the same name and LLVM would rename
    // it (e.g. List_delete -> List_delete.64), leaving the original prototype
    // bodiless and breaking linking of ARC destructors that call it by name.
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

    // Declare function prototypes in LLVM
    for (compiler.functions.items) |func| {
        const params = try allocator.alloc(types.LLVMTypeRef, func.param_count);
        defer allocator.free(params);
        @memset(params, compiler.val_type);

        const is_void = std.mem.eql(u8, func.return_type, "void");
        const is_main = std.mem.eql(u8, func.name, "main");
        // M3-C: an async fn's ramp returns the coroutine handle (i64), regardless of
        // its declared Nova return type (which is carried in the coroutine promise).
        const is_async_native = func.is_async and !is_wasm;
        // Program entry `main` is emitted as `i64 __nova_main()` so it can propagate an
        // exit code to the runtime (0 when main is void / returns nothing).
        const ret_t = if (is_main) compiler.val_type else if (is_async_native) compiler.val_type else if (is_void) compiler.void_type else compiler.val_type;

        const fn_type = core.LLVMFunctionType(ret_t, params.ptr, @intCast(func.param_count), 0);
        const real_name = if (is_main) "__nova_main" else func.name;
        const fn_name_z = try allocator.dupeZ(u8, real_name);
        defer allocator.free(fn_name_z);
        const fn_val = core.LLVMAddFunction(compiler.module, fn_name_z.ptr, fn_type);
        try compiler.func_map.put(func.name, fn_val);

        if (is_async_native) {
            // Mark the ramp as a pre-split coroutine so LLVMRunPasses' CoroSplit
            // lowers the llvm.coro.* intrinsics we emit into resume/destroy funcs.
            const kind = core.LLVMGetEnumAttributeKindForName("presplitcoroutine", "presplitcoroutine".len);
            const attr = core.LLVMCreateEnumAttribute(core.LLVMGetGlobalContext(), kind, 0);
            core.LLVMAddAttributeAtIndex(fn_val, std.math.maxInt(c_uint), attr); // function attribute index
            try compiler.async_fns.put(func.name, {});
        }
    }

    // M3-R2: reorder so ERASED generic bodies compile LAST — after every retained (non-erased) body, so an
    // erased prototype's call-site uses are complete when we reach it. Then a dead erased body (0 uses) is
    // SKIPPED (not emitted), which is what stops its destructor-generation string-parser calls. Stable
    // partition preserves relative order within each group (so an erased body that calls an earlier erased
    // body still sees that use). SAFE by construction: skipping a still-referenced body is an undefined-
    // symbol LINK error (compile-time), never runtime corruption — and globalDCE (R1) removes the skipped
    // prototypes' now-unused declarations.
    {
        var reordered = std.ArrayListUnmanaged(FunctionInfo).empty;
        defer reordered.deinit(allocator);
        for (compiler.functions.items) |f| if (!f.erased_generic) try reordered.append(allocator, f);
        for (compiler.functions.items) |f| if (f.erased_generic) try reordered.append(allocator, f);
        @memcpy(compiler.functions.items, reordered.items);
    }

    // Compile function bodies
    for (compiler.functions.items) |func| {
        const fn_val = compiler.func_map.get(func.name).?;
        // M3-R2: an erased generic body with NO call-site uses is dead — skip emitting it (and its
        // destructor generation). Erased bodies are ordered last, so uses from retained callers are final.
        if (func.erased_generic and core.LLVMGetFirstUse(fn_val) == null) continue;

        // M3-R1: the erased body of a generic struct is a link-time fallback — give it internal linkage so
        // globalDCE can delete it when no retained body references it (external linkage would pin it).
        // T6 split: an erased body may be REFERENCED from another file's object, so it cannot be internal
        // (internal symbols are object-local) — leave it external; the per-clone globalDCE + the link-time
        // dead-strip drop the dead ones instead.
        if (func.erased_generic and !t6_split) core.LLVMSetLinkage(fn_val, types.LLVMLinkage.LLVMInternalLinkage);

        compiler.current_function_name = func.name;
        compiler.current_local_types = compiler.function_local_types.getPtr(func.name).?;
        compiler.current_local_type_ids = compiler.function_local_type_ids.getPtr(func.name).?;
        compiler.current_param_names = func.param_names;

        compiler.current_struct_name = null;
        compiler.current_module_prefix = null;
        // F4 4b: the SAME context as the local_types pass above. If these two
        // disagree, the body is typed against one substitution and emitted against
        // another — the kind of split that shows up as a leak, not a diagnostic.
        compiler.current_instantiation = func.instantiation;
        compiler.current_instantiation_id = if (func.instantiation) |inst| sema_mono.live_inst_ids.get(inst) else null;
        compiler.current_method_subst = func.method_subst;

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

        // Get module prefix
        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                var decl_name = decl.fn_decl.name;
                if (compiler.getStructPrefix(decl.fn_decl)) |prefix| {
                    decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, decl.fn_decl.name });
                } else if (compiler.getModulePrefix(decl.fn_decl.span)) |mod_prefix| {
                    if (LlvmCompiler.isAlreadyNamespaced(decl.fn_decl.name)) {
                        decl_name = decl.fn_decl.name;
                    } else {
                        decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ mod_prefix, decl.fn_decl.name });
                    }
                }
                if (std.mem.eql(u8, decl_name, func.name)) {
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
                    const decl_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ e.name, fn_decl.name });
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

        // Append entry block
        const entry_bb = core.LLVMAppendBasicBlock(fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(compiler.builder, entry_bb);

        // Clear previous saved captures
        {
            var iter = compiler.current_saved_captures.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            compiler.current_saved_captures.clearRetainingCapacity();
        }

        // Set up function arguments in locals alloca slots
        for (0..func.param_count) |idx| {
            const arg_name = func.param_names[idx];
            const arg_val = core.LLVMGetParam(fn_val, @intCast(idx));

            var alloca_val: types.LLVMValueRef = undefined;
            // A7 / F3 §5 stage 4: a float-typed param gets a real `double` slot. The
            // incoming param is i64 (the uniform ABI edge); coerce it once here, then
            // every load inside the body is honest `double`. Captured/global-backed
            // params stay val_type (a global is always i64).
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
        }

        // Set up all other local variables in locals alloca slots
        var local_names = std.ArrayList([]const u8).empty;
        defer local_names.deinit(allocator);
        try compiler.collectLocalVarNames(&local_names, func.body);

        for (local_names.items) |name| {
            if (compiler.locals.contains(name)) continue;

            var alloca_val: types.LLVMValueRef = undefined;
            // A7 / F3 §5 stage 4: honest slot type — a float local becomes `alloca
            // double`. Captured/global-backed locals stay val_type (i64).
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
            // Default initialize stack local/global to the slot's zero.
            const zero = if (core.LLVMGetTypeKind(slot_ty) == .LLVMDoubleTypeKind)
                core.LLVMConstReal(slot_ty, 0)
            else
                core.LLVMConstInt(slot_ty, 0, 0);
            _ = core.LLVMBuildStore(compiler.builder, zero, alloca_val);
            try compiler.locals.put(name, alloca_val);
        }

        // Initialize dynamic heap if main function in native target
        const is_main = std.mem.eql(u8, func.name, "main");
        if (is_main and !is_wasm) {
            const malloc_val = compiler.func_map.get("malloc").?;
            const malloc_t = core.LLVMGlobalGetValueType(malloc_val);
            const heap_size = core.LLVMConstInt(compiler.val_type, 16 * 1024 * 1024, 0); // 16MB
            var malloc_args = [_]types.LLVMValueRef{heap_size};
            const heap_alloc_ptr = core.LLVMBuildCall2(compiler.builder, malloc_t, malloc_val, &malloc_args, 1, "heap_alloc");
            const heap_alloc_int = core.LLVMBuildPtrToInt(compiler.builder, heap_alloc_ptr, compiler.val_type, "heap_alloc_int");
            _ = core.LLVMBuildStore(compiler.builder, heap_alloc_int, compiler.heap_ptr.?);
        }

        // M3-C: async fns become LLVM coroutines. Emit the coroutine prologue
        // (promise + coro.id/begin + initial suspend) now — after the arg/local
        // allocas (which CoroSplit hoists into the frame) — and compile the body
        // into the post-suspend block. `return` routes to the promise + final
        // suspend via current_async_* (see statements.zig).
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

        // Compile block statements
        try compiler.scopes.append(allocator, Scope{ .deferred_statements = std.ArrayList(ast.Expression).empty });
        for (func.body.statements) |stmt| {
            try compiler.compileStatement(stmt, func);
        }

        // Add terminator if not terminated
        if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(compiler.builder)) == null) {
            var scope = compiler.scopes.pop().?;
            var idx = scope.deferred_statements.items.len;
            while (idx > 0) {
                idx -= 1;
                _ = try compiler.compileExpression(scope.deferred_statements.items[idx]);
            }
            scope.deferred_statements.deinit(allocator);

            // Disable restoring captured globals to allow async/concurrent closures to access variables
            // after the enclosing function scope has exited.
            // var iter = compiler.current_saved_captures.iterator();
            // while (iter.next()) |entry| {
            //     const global_key = entry.key_ptr.*;
            //     const backup_slot = entry.value_ptr.*;
            //     const global_var = compiler.captured_globals.get(global_key).?;
            //     const saved_val = core.LLVMBuildLoad2(compiler.builder, compiler.val_type, backup_slot, "backup_restore_load");
            //     _ = core.LLVMBuildStore(compiler.builder, saved_val, global_var);
            // }

            // Release local variables
            try compiler.releaseLocalVariables();

            if (coro_ctx) |cc| {
                // async fn fell through without an explicit return → void result;
                // jump to the final suspend (promise left unset).
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

        // M3-C: emit the coroutine epilogue (final suspend + cleanup/free + coro.end
        // + return handle) for async fns.
        if (coro_ctx) |cc| {
            emitCoroEpilogue(&compiler, fn_val, cc);
            compiler.current_async_promise = null;
            compiler.current_async_final_bb = null;
            compiler.current_async_hdl = null;
            compiler.current_async_suspend_bb = null;
            compiler.current_async_cleanup_bb = null;
        }

        // Deinit leftover scopes (e.g. if we had early returns)
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

    // T6 Phase 1b (increment 2): per-file object split. The whole program is already codegen'd into
    // one module above; now emit ONE object PER SOURCE FILE by cloning that module and stripping the
    // bodies that belong to other files (turning them into extern declarations). Shared globals are
    // linkonce_odr so the linker dedups them. This reuses ALL the existing codegen — the split is a
    // pure post-process. Falls back to the single object when off / not requested.
    if (t6_split and !is_wasm) {
        if (objs_out) |objs| {
            try compileSplitEmit(&compiler, allocator, output_path, is_release, objs, cache_dir, io);
            return;
        }
    }

    try emitModule(&compiler, allocator, compiler.module, output_path, is_wasm, is_release, "__nova_test.ll");
}

// T6 Phase 1b — clone-and-strip per-file emission. For each source file, clone the whole-program
// module and delete the bodies of functions that belong to OTHER files (leaving them as extern
// declarations resolved at link from the file that owns them). Each clone is finalized through the
// same `emitModule` path (verify + CoroSplit + globalDCE + emit). Object paths are appended to `objs`.
fn compileSplitEmit(
    compiler: *LlvmCompiler,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    is_release: bool,
    objs: *std.ArrayList([]const u8),
    cache_dir: ?[]const u8,
    io: std.Io,
) !void {
    // (1) Make cross-object-shared globals linkonce_odr so every clone may define them and the linker
    // dedups. `_vtable_*` (trait vtables) and `heap_ptr` are externally referenced; string literals and
    // `__destruct_*` are already internal (object-local — each clone keeps its own copies, no clash).
    {
        var g = core.LLVMGetFirstGlobal(compiler.module);
        while (g != null) : (g = core.LLVMGetNextGlobal(g)) {
            const nm = std.mem.span(core.LLVMGetValueName(g));
            if (std.mem.eql(u8, nm, "heap_ptr") or std.mem.startsWith(u8, nm, "_vtable_")) {
                core.LLVMSetLinkage(g, types.LLVMLinkage.LLVMLinkOnceODRLinkage);
            }
        }
    }

    // (2) Group Nova-function symbol names by source file, and collect the set of ALL Nova-function
    // symbols (so the strip touches only OUR functions — never runtime externs, intrinsics, or
    // __destruct_*). `func_map[func.name]` carries the real emitted symbol name.
    var all_syms = std.StringHashMap(void).init(allocator);
    defer all_syms.deinit();
    var file_syms = std.StringHashMap(std.StringHashMap(void)).init(allocator);
    defer {
        var it = file_syms.valueIterator();
        while (it.next()) |v| v.deinit();
        file_syms.deinit();
    }
    for (compiler.functions.items) |func| {
        const v = compiler.func_map.get(func.name) orelse continue;
        const sym = std.mem.span(core.LLVMGetValueName(v));
        try all_syms.put(sym, {});
        const file = if (func.source_file.len > 0) func.source_file else "<uncategorized>";
        const gop = try file_syms.getOrPut(file);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(allocator);
        try gop.value_ptr.put(sym, {});
    }

    // (3) One object per file: clone → strip non-owner Nova-function bodies → finalize.
    // T6 Stage B — per-file object CACHE (build_mode only, `cache_dir` set): a clone's IR is a pure
    // function of the source, and emitModule is deterministic, so identical clone IR ⟹ identical
    // object. Hash the stripped clone's IR; if `<cache_dir>/nova_split_<hash>.o` already exists, REUSE
    // it and skip the expensive emit (LLVM passes + object codegen). A body edit strips other files'
    // functions to signature-only declarations, so their clone IR — and their object — is unchanged;
    // only the edited file (and anything whose IR actually changed) re-emits. Never stale: a hit means
    // byte-identical IR.
    var idx: usize = 0;
    var hits: usize = 0;
    var misses: usize = 0;
    var fit = file_syms.iterator();
    while (fit.next()) |entry| : (idx += 1) {
        const owner = entry.value_ptr;
        const clone = core.LLVMCloneModule(compiler.module);
        defer core.LLVMDisposeModule(clone);

        // Strip the body of every Nova function this file does NOT own → an extern declaration.
        var f = core.LLVMGetFirstFunction(clone);
        while (f != null) : (f = core.LLVMGetNextFunction(f)) {
            const nm = std.mem.span(core.LLVMGetValueName(f));
            if (!all_syms.contains(nm)) continue; // runtime extern / intrinsic / __destruct_ — leave it
            if (owner.contains(nm)) continue; // this file owns it — keep the body
            // Delete every basic block → the function becomes a declaration.
            var bb = core.LLVMGetFirstBasicBlock(f);
            while (bb != null) {
                const next = core.LLVMGetNextBasicBlock(bb);
                core.LLVMDeleteBasicBlock(bb);
                bb = next;
            }
        }

        if (cache_dir) |cdir| {
            // Minimize the clone before hashing: globaldce drops the internal globals (string literals,
            // etc.) this file does NOT reference, so a string/body edit in ANOTHER file no longer
            // changes THIS file's clone IR — the difference between "1 object rebuilt" and "all 26". The
            // pass is deterministic and idempotent (emitModule re-runs it), so the object is unchanged.
            {
                const opts = transform.LLVMCreatePassBuilderOptions();
                defer transform.LLVMDisposePassBuilderOptions(opts);
                const perr = transform.LLVMRunPasses(clone, "globaldce", compiler.target_machine, opts);
                if (perr != null) errors.LLVMConsumeError(perr);
            }
            // Content-hash the minimized clone IR → cache key.
            const ir_c = core.LLVMPrintModuleToString(clone);
            const ir = std.mem.span(ir_c);
            const key = std.hash.Wyhash.hash(if (is_release) 1 else 0, ir);
            core.LLVMDisposeMessage(ir_c);
            const obj_path = try std.fmt.allocPrint(allocator, "{s}/nova_split_{x}.o", .{ cdir, key });
            if (std.Io.Dir.access(.cwd(), io, obj_path, .{})) |_| {
                hits += 1; // cache hit — reuse the existing object, skip emit
            } else |_| {
                misses += 1;
                try emitModule(compiler, allocator, clone, obj_path, false, is_release, null);
            }
            try objs.append(allocator, obj_path);
        } else {
            // No cache (e.g. `nova test`): throwaway object next to the output.
            const obj_path = try std.fmt.allocPrint(allocator, "{s}.{d}.o", .{ output_path, idx });
            try emitModule(compiler, allocator, clone, obj_path, false, is_release, null);
            try objs.append(allocator, obj_path);
        }
    }
    if (cache_dir != null) {
        std.debug.print("[T6] per-file objects: {d} total, {d} cached (reused), {d} rebuilt\n", .{ idx, hits, misses });
    }
}

// Finalize ONE LLVM module → one object file: dump IR (debug), verify, strip `__destruct_*` to
// internal linkage (globalDCE reclaims dead ones), run the middle-end pipeline (CoroSplit etc.), and
// emit the object. Extracted so the per-file split (T6 Phase 1b) can finalize each file's module the
// SAME way the single whole-program module is finalized — one code path, no divergence.
fn emitModule(
    compiler: *LlvmCompiler,
    allocator: std.mem.Allocator,
    module: types.LLVMModuleRef,
    obj_path: []const u8,
    is_wasm: bool,
    is_release: bool,
    dump_ll_name: ?[]const u8,
) !void {
    if (dump_ll_name) |nm| {
        const nm_z = try allocator.dupeZ(u8, nm);
        defer allocator.free(nm_z);
        _ = core.LLVMPrintModuleToFile(module, nm_z.ptr, null);
    }

    // Verify the module
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

    // M3-R1: on-demand DESTRUCTORS (`__destruct_*`) are module-internal — only ever referenced by a
    // `nova_release` function-pointer arg inside this module, never exported. Give them internal linkage so
    // globalDCE reclaims the erased ones once their only callers (the dead erased bodies) are gone.
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
        const passes: [*:0]const u8 = if (is_release) "default<O3>,globaldce" else "default<O0>,globaldce";
        const perr = transform.LLVMRunPasses(module, passes, compiler.target_machine, opts);
        if (perr != null) {
            errors.LLVMConsumeError(perr);
            std.debug.print("LLVM pass pipeline ('{s}') failed\n", .{passes});
            return error.LLVMPassError;
        }
    }

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
}

// M3-C: declare the LLVM coroutine intrinsics and the frame allocator so async-fn
// codegen can emit calls to them. Intrinsics are declared via the intrinsic-ID
// path so LLVM builds their exact (token-typed) signatures for us; overloaded
// `llvm.coro.size` takes its result type (i64) as the overload parameter.
fn declareCoroIntrinsic(compiler: *LlvmCompiler, name: [:0]const u8, overload: ?types.LLVMTypeRef) !void {
    const id = core.LLVMLookupIntrinsicID(name.ptr, name.len);
    const fn_val = if (overload) |ot| blk: {
        var ptypes = [_]types.LLVMTypeRef{ot};
        break :blk core.LLVMGetIntrinsicDeclaration(compiler.module, id, &ptypes, 1);
    } else core.LLVMGetIntrinsicDeclaration(compiler.module, id, null, 0);
    try compiler.func_map.put(name[0..name.len], fn_val);
}

// M3-C: state produced by the coroutine prologue, consumed by the epilogue and
// (via compiler.current_async_*) by `return` lowering.
const CoroCtx = struct {
    hdl: types.LLVMValueRef,
    id: types.LLVMValueRef,
    promise: types.LLVMValueRef,
    final_bb: types.LLVMBasicBlockRef,
    cleanup_bb: types.LLVMBasicBlockRef,
    suspend_bb: types.LLVMBasicBlockRef,
};

// Emit the coroutine prologue into the current (entry) block and leave the builder
// positioned at the post-initial-suspend body block. Mirrors the validated spike IR.
fn emitCoroPrologue(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef) !CoroCtx {
    const b = compiler.builder;
    const ptr_ty = compiler.ptr_type;

    // Promise = { i64 result, i64 waiter }. `result` carries the async fn's Nova
    // return value across suspends; `waiter` holds the handle of a coroutine
    // awaiting this one (0 = none), scheduled when this coroutine completes.
    const promise = core.LLVMBuildAlloca(b, compiler.coroPromiseType(), "coro.promise");
    // waiter defaults to 0 (no awaiter); set by `await` on the child's promise.
    const w0 = compiler.coroPromiseWaiterSlot(promise);
    _ = core.LLVMBuildStore(b, core.LLVMConstInt(compiler.val_type, 0, 0), w0);

    const id_fn = compiler.func_map.get("llvm.coro.id").?;
    const id_t = core.LLVMGlobalGetValueType(id_fn);
    var id_args = [_]types.LLVMValueRef{
        core.LLVMConstInt(compiler.i32_type, 0, 0), // align
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

    // Initial suspend hands the coroutine handle back to the caller/resumer.
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

// Emit final suspend, cleanup (coro.free → nova_coro_free), and coro.end + return
// of the handle. Called after the body has branched to final_bb.
fn emitCoroEpilogue(compiler: *LlvmCompiler, fn_val: types.LLVMValueRef, ctx: CoroCtx) void {
    const b = compiler.builder;
    const tok_ty = core.LLVMTokenTypeInContext(core.LLVMGetGlobalContext());
    const none_tok = core.LLVMConstNull(tok_ty);

    // final_bb: this coroutine has produced its result (in the promise); take the
    // final suspend, which marks it done. M3-D-3: it does NOT schedule its own waiter
    // — the runtime does that AFTER this coroutine's resume returns (race-free under
    // multi-threading; see nova_sched_schedule / nova_register_waiter).
    core.LLVMPositionBuilderAtEnd(b, ctx.final_bb);
    const suspend_fn = compiler.func_map.get("llvm.coro.suspend").?;
    const suspend_t = core.LLVMGlobalGetValueType(suspend_fn);
    var sf_args = [_]types.LLVMValueRef{ none_tok, core.LLVMConstInt(compiler.i1_type, 1, 0) };
    const sf = core.LLVMBuildCall2(b, suspend_t, suspend_fn, &sf_args, 2, "coro.final.susp");
    const trap_bb = core.LLVMAppendBasicBlock(fn_val, "coro.trap");
    const sw = core.LLVMBuildSwitch(b, sf, ctx.suspend_bb, 2);
    core.LLVMAddCase(sw, core.LLVMConstInt(compiler.i8_type, 0, 0), trap_bb); // resume after final = UB
    core.LLVMAddCase(sw, core.LLVMConstInt(compiler.i8_type, 1, 0), ctx.cleanup_bb);
    core.LLVMPositionBuilderAtEnd(b, trap_bb);
    _ = core.LLVMBuildUnreachable(b);

    // cleanup_bb: return frame memory to nova_coro_free.
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

    // suspend_bb: coro.end, then return the handle (i64) to the caller/resumer.
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
    try declareCoroIntrinsic(compiler, "llvm.coro.size", compiler.i64_type); // -> llvm.coro.size.i64
    try declareCoroIntrinsic(compiler, "llvm.coro.begin", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.suspend", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.end", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.free", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.resume", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.destroy", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.done", null);
    try declareCoroIntrinsic(compiler, "llvm.coro.promise", null);

    // nova_coro_alloc(i64)->i64, nova_coro_free(i64)->void (frame backing store).
    var one_val = [_]types.LLVMTypeRef{compiler.val_type};
    const alloc_type = core.LLVMFunctionType(compiler.val_type, &one_val, 1, 0);
    const alloc_fn = core.LLVMAddFunction(compiler.module, "nova_coro_alloc", alloc_type);
    try compiler.func_map.put("nova_coro_alloc", alloc_fn);
    const free_type = core.LLVMFunctionType(compiler.void_type, &one_val, 1, 0);
    const free_fn = core.LLVMAddFunction(compiler.module, "nova_coro_free", free_type);
    try compiler.func_map.put("nova_coro_free", free_fn);

    // Minimal single-threaded ready-queue scheduler (M3-C): nova_sched_schedule(i64)
    // pushes a coroutine handle; nova_sched_next()->i64 pops one (0 when empty).
    // Replaced by the Asio io_context in workstream D.
    const sched_type = core.LLVMFunctionType(compiler.void_type, &one_val, 1, 0);
    const sched_fn = core.LLVMAddFunction(compiler.module, "nova_sched_schedule", sched_type);
    try compiler.func_map.put("nova_sched_schedule", sched_fn);
    const sched_det_fn = core.LLVMAddFunction(compiler.module, "nova_sched_schedule_detached", sched_type);
    try compiler.func_map.put("nova_sched_schedule_detached", sched_det_fn);
    const next_type = core.LLVMFunctionType(compiler.val_type, null, 0, 0);
    const next_fn = core.LLVMAddFunction(compiler.module, "nova_sched_next", next_type);
    try compiler.func_map.put("nova_sched_next", next_fn);

    // M3-D: nova_run() drives the Asio io_context until all scheduled coroutines
    // (and pending timers/sockets) complete.
    const run_type = core.LLVMFunctionType(compiler.void_type, null, 0, 0);
    const run_fn = core.LLVMAddFunction(compiler.module, "nova_run", run_type);
    try compiler.func_map.put("nova_run", run_fn);

    // nova_run_root(root) — drive until `root` has actually completed, not merely
    // until the io_context went idle. buildDriveAsyncCall reads root's promise
    // straight after, so "idle" is not a safe proxy for "done": an idle context
    // with a pending root means a wakeup is in flight, and reading then yields an
    // unwritten slot (the `10_async_go` flake).
    var release_params = [_]types.LLVMTypeRef{compiler.val_type};
    const release_type = core.LLVMFunctionType(compiler.void_type, &release_params, 1, 0);
    const release_fn = core.LLVMAddFunction(compiler.module, "nova_coro_release", release_type);
    try compiler.func_map.put("nova_coro_release", release_fn);

    var run_root_params = [_]types.LLVMTypeRef{compiler.val_type};
    const run_root_type = core.LLVMFunctionType(compiler.void_type, &run_root_params, 1, 0);
    const run_root_fn = core.LLVMAddFunction(compiler.module, "nova_run_root", run_root_type);
    try compiler.func_map.put("nova_run_root", run_root_fn);

    // M3-D: nova_await_timer(handle, ms) — non-blocking timer await primitive.
    var timer_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const timer_type = core.LLVMFunctionType(compiler.void_type, &timer_params, 2, 0);
    const timer_fn = core.LLVMAddFunction(compiler.module, "nova_await_timer", timer_type);
    try compiler.func_map.put("nova_await_timer", timer_fn);

    // M3-D-3: nova_register_waiter(child, parent) — race-free waiter registration
    // for multi-threaded execution (runtime wakes the waiter post-resume).
    var waiter_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const waiter_type = core.LLVMFunctionType(compiler.void_type, &waiter_params, 2, 0);
    const waiter_fn = core.LLVMAddFunction(compiler.module, "nova_register_waiter", waiter_type);
    try compiler.func_map.put("nova_register_waiter", waiter_fn);

    // M3-D-4: nova_await_future(future, waiter) -> i64 (1=ready, 0=suspended).
    var fut_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    const fut_type = core.LLVMFunctionType(compiler.val_type, &fut_params, 2, 0);
    const fut_fn = core.LLVMAddFunction(compiler.module, "nova_await_future", fut_type);
    try compiler.func_map.put("nova_await_future", fut_fn);

    // M3-D-6: async channels. new(cap)->i64, send(ch,val), recv(ch,self,out*)->i64, free(ch).
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

    // M3-D-6: async socket I/O offload.
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

    // M3-D-7: scalable async server sockets (true non-blocking asio).
    const listen_type = core.LLVMFunctionType(compiler.val_type, &one_val_c, 1, 0);
    const listen_fn = core.LLVMAddFunction(compiler.module, "nova_aserver_listen", listen_type);
    try compiler.func_map.put("nova_aserver_listen", listen_fn);
    var two_val_c = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type };
    // I3: bind+listen on a specific address (Service VIP): (host_ptr, port) -> handle
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
    // spawn-arg hold: (coro, ptr, dtor_fn) -> void. Releases `ptr` (via its dtor) when `coro` completes.
    var holdarg_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.ptr_type };
    const holdarg_type = core.LLVMFunctionType(compiler.void_type, &holdarg_params, 3, 0);
    try compiler.func_map.put("nova_coro_hold_arg", core.LLVMAddFunction(compiler.module, "nova_coro_hold_arg", holdarg_type));
    // select/when_any: (handles_buf, n, self) -> ready index or -1.
    var whenany_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type };
    const whenany_type = core.LLVMFunctionType(compiler.val_type, &whenany_params, 3, 0);
    try compiler.func_map.put("nova_when_any", core.LLVMAddFunction(compiler.module, "nova_when_any", whenany_type));
    var whenanydl_params = [_]types.LLVMTypeRef{ compiler.val_type, compiler.val_type, compiler.val_type, compiler.val_type };
    const whenanydl_type = core.LLVMFunctionType(compiler.val_type, &whenanydl_params, 4, 0);
    try compiler.func_map.put("nova_when_any_deadline", core.LLVMAddFunction(compiler.module, "nova_when_any_deadline", whenanydl_type));
}
