
const std = @import("std");
const ast = @import("../ast.zig");
const sema_mono = @import("../sema/mono.zig");
const llvm = @import("llvm");

const types = llvm.types;
const core = llvm.core;
const target = llvm.target;
const target_machine = llvm.target_machine;
const analysis = llvm.analysis;
const coverage_mod = @import("coverage.zig");
pub const CoverageBlock = coverage_mod.CoverageBlock;
pub const CoverageRegistry = coverage_mod.CoverageRegistry;

const types_mod = @import("types.zig");
const sema_infer = @import("../sema/infer.zig");
const sema_types = @import("../types.zig");
const sema_shadow = @import("../sema/shadow.zig");
const getStructBaseName = types_mod.getStructBaseName;
const isPrimitiveTypeName = types_mod.isPrimitiveTypeName;
const arc_mod = @import("arc.zig");
const statements_mod = @import("statements.zig");
const declarations_mod = @import("declarations.zig");
const expressions_mod = @import("expressions.zig");

pub fn unescapeString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '\\' => try result.append(allocator, '\\'),
                '\"' => try result.append(allocator, '\"'),
                '\'' => try result.append(allocator, '\''),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub const FunctionInfo = struct {
    name: []const u8,
    param_count: usize,
    param_names: []const []const u8,
    return_type: []const u8,

    ret_type_ref: ?ast.TypeRef = null,
    body: ast.Block,

    is_async: bool = false,

    instantiation: ?[]const u8 = null,

    method_subst: ?[]const MethodParamBinding = null,

    erased_generic: bool = false,

    source_file: []const u8 = "",
};

pub const Scope = struct {
    deferred_statements: std.ArrayList(ast.Expression),

    errdeferred_statements: std.ArrayList(ast.Expression) = .empty,

    owned_locals: std.ArrayList(OwnedLocal) = .empty,
};

pub const OwnedLocal = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const PendingTemp = struct {

    val: types.LLVMValueRef,

    slot: types.LLVMValueRef,
    type_name: []const u8,

    expr_id: ast.ExprId = .unassigned,
};

pub const MethodParamBinding = struct {
    name: []const u8,
    concrete: []const u8,
};

pub const LlvmCompiler = struct {
    allocator: std.mem.Allocator,
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    target_machine: types.LLVMTargetMachineRef,
    functions: std.ArrayList(FunctionInfo),
    strings: std.ArrayList([]const u8),
    scopes: std.ArrayList(Scope),
    locals: std.StringHashMap(types.LLVMValueRef),
    func_map: std.StringHashMap(types.LLVMValueRef),
    // Memoises getFunctionParamTypeRef, whose body is an O(all-declarations x methods x
    // instantiations) linear scan with per-iteration allocation. It is called per-parameter
    // per-call-site over the whole merged program, so on stdlib-heavy files (15k merged lines)
    // the repeated scan dominated compile time. The result is a pure function of
    // (func_name, param_idx) for a fixed program, so caching it is safe. Key: "name\x00idx".
    param_type_cache: std.StringHashMap(?ast.TypeRef),
    // Same memoisation for getFunctionParamType (the string-returning sibling). Value is an
    // owned type-name string; callers own their result, so a hit returns a fresh dupe (cheap next
    // to the scan it avoids). Both keys and stored value strings are freed on deinit.
    param_type_str_cache: std.StringHashMap(?[]const u8),
    structs: std.StringHashMap(ast.StructDecl),
    unions: std.StringHashMap(ast.UnionDecl),
    enums: std.StringHashMap(ast.EnumDecl),
    traits: std.StringHashMap(ast.TraitDecl),

    ffi_externs: std.StringHashMap(ast.FunctionDecl),
    constants: std.StringHashMap(ast.Expression),
    current_local_types: ?*std.StringHashMap([]const u8),

    current_local_type_ids: ?*std.StringHashMap(sema_types.TypeId),

    pending_temps: std.ArrayList(PendingTemp) = .empty,
    current_struct_name: ?[]const u8,

    current_instantiation: ?[]const u8,

    current_instantiation_id: ?sema_types.TypeId = null,

    current_method_subst: ?[]const MethodParamBinding = null,

    default_ctor_depth: u32 = 0,

    rendered_name_ids: ?std.StringHashMapUnmanaged(sema_types.TypeId) = null,
    current_module_prefix: ?[]const u8,
    current_function_name: ?[]const u8,

    current_loop_scope_depth: ?usize,
    current_collecting_function_name: ?[]const u8,

    current_collecting_instantiation: ?[]const u8,

    current_collecting_method_subst: ?[]const MethodParamBinding = null,

    current_collecting_erased_generic: bool = false,
    lambda_parents: std.StringHashMap([]const u8),

    lambda_param_types: std.StringHashMap([]const ?[]const u8),
    function_local_types: std.StringHashMap(std.StringHashMap([]const u8)),

    function_local_type_ids: std.StringHashMap(std.StringHashMap(sema_types.TypeId)),
    captured_globals: std.StringHashMap(types.LLVMValueRef),

    lambda_captures: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    fn_box_globals: std.StringHashMap(types.LLVMValueRef),

    typed_ir: ?*const sema_infer.TypedIr = null,

    f2_types: bool = false,
    type_store: ?*const sema_types.TypeStore = null,
    current_scanning_lambda: ?[]const u8 = null,
    program: ast.Program,
    has_log: bool,
    next_lambda_id: u32,

    closure_lambdas: std.StringHashMapUnmanaged([]const u8),
    current_saved_captures: std.StringHashMap(types.LLVMValueRef),
    is_wasm: bool,
    coverage_enabled: bool,
    cov_registry: ?CoverageRegistry,
    current_string_builder: ?types.LLVMValueRef = null,
    current_param_names: ?[]const []const u8 = null,

    current_async_promise: ?types.LLVMValueRef = null,
    current_async_final_bb: ?types.LLVMBasicBlockRef = null,
    current_async_hdl: ?types.LLVMValueRef = null,
    current_async_suspend_bb: ?types.LLVMBasicBlockRef = null,
    current_async_cleanup_bb: ?types.LLVMBasicBlockRef = null,

    async_fns: std.StringHashMap(void) = undefined,

    i1_type: types.LLVMTypeRef,
    i8_type: types.LLVMTypeRef,
    i32_type: types.LLVMTypeRef,
    i64_type: types.LLVMTypeRef,
    void_type: types.LLVMTypeRef,
    ptr_type: types.LLVMTypeRef,
    val_type: types.LLVMTypeRef,

    string_globals: std.StringHashMap(types.LLVMValueRef),

    puts_fn: ?types.LLVMValueRef = null,
    printf_fn: ?types.LLVMValueRef = null,
    nova_log_string_fn: ?types.LLVMValueRef = null,
    nova_log_info_fn: ?types.LLVMValueRef = null,
    nova_log_debug_fn: ?types.LLVMValueRef = null,
    nova_log_err_fn: ?types.LLVMValueRef = null,
    log_fn: ?types.LLVMValueRef = null,
    heap_ptr: ?types.LLVMValueRef = null,
    free_list: ?types.LLVMValueRef = null,
    persistent_ptr: ?types.LLVMValueRef = null,
    current_break_bb: ?types.LLVMBasicBlockRef = null,
    current_continue_bb: ?types.LLVMBasicBlockRef = null,

    pub fn new(allocator: std.mem.Allocator, is_wasm: bool, is_release: bool, target_triple_opt: ?[]const u8, coverage_enabled: bool) !LlvmCompiler {

        target.LLVMInitializeAllTargetInfos();
        target.LLVMInitializeAllTargets();
        target.LLVMInitializeAllTargetMCs();
        target.LLVMInitializeAllAsmPrinters();
        target.LLVMInitializeAllAsmParsers();

        const triple_z = if (is_wasm)
            try allocator.dupeZ(u8, "wasm32-unknown-unknown")
        else if (target_triple_opt) |t|
            try allocator.dupeZ(u8, t)
        else
            try allocator.dupeZ(u8, std.mem.span(target_machine.LLVMGetDefaultTargetTriple()));
        defer allocator.free(triple_z);

        var target_ref: types.LLVMTargetRef = undefined;
        var err_msg: [*c]u8 = null;
        if (target_machine.LLVMGetTargetFromTriple(triple_z.ptr, &target_ref, @ptrCast(&err_msg)) != 0) {
            const span_msg = std.mem.span(err_msg);
            std.debug.print("Failed to get target from triple {s}: {s}\n", .{ triple_z, span_msg });
            return error.LLVMTargetError;
        }

        const opt_level = if (is_release)
            types.LLVMCodeGenOptLevel.LLVMCodeGenLevelAggressive
        else
            types.LLVMCodeGenOptLevel.LLVMCodeGenLevelNone;
        const reloc = types.LLVMRelocMode.LLVMRelocDefault;
        const code_model = types.LLVMCodeModel.LLVMCodeModelDefault;
        // For a native (non-wasm, non-cross) build, target the actual host CPU + features so the
        // vectorizer models the real vector units (NEON/AVX) and its cost model fires -- "generic" is
        // pessimistic and leaves array loops scalar. Cross/wasm builds stay generic for portability.
        const native = !is_wasm and target_triple_opt == null;
        const host_cpu = if (native) target_machine.LLVMGetHostCPUName() else null;
        const host_feat = if (native) target_machine.LLVMGetHostCPUFeatures() else null;
        defer if (host_cpu) |c| core.LLVMDisposeMessage(c);
        defer if (host_feat) |f| core.LLVMDisposeMessage(f);
        const cpu_z: [*:0]const u8 = if (host_cpu) |c| @ptrCast(c) else "generic";
        const feat_z: [*:0]const u8 = if (host_feat) |f| @ptrCast(f) else "";
        const tm = target_machine.LLVMCreateTargetMachine(
            target_ref,
            triple_z.ptr,
            cpu_z,
            feat_z,
            opt_level,
            reloc,
            code_model,
        ) orelse return error.LLVMTargetMachineCreationError;

        const module = core.LLVMModuleCreateWithName("nova_module");
        const builder = core.LLVMCreateBuilder();

        core.LLVMSetTarget(module, triple_z.ptr);
        const layout = target_machine.LLVMCreateTargetDataLayout(tm);
        target.LLVMSetModuleDataLayout(module, layout);

        const compiler = LlvmCompiler{
            .allocator = allocator,
            .module = module,
            .builder = builder,
            .target_machine = tm,
            .functions = std.ArrayList(FunctionInfo).empty,
            .strings = std.ArrayList([]const u8).empty,
            .scopes = std.ArrayList(Scope).empty,
            .heap_ptr = null,
            .free_list = null,
            .persistent_ptr = null,
            .locals = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .func_map = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .param_type_cache = std.StringHashMap(?ast.TypeRef).init(allocator),
            .param_type_str_cache = std.StringHashMap(?[]const u8).init(allocator),
            .async_fns = std.StringHashMap(void).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .unions = std.StringHashMap(ast.UnionDecl).init(allocator),
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .traits = std.StringHashMap(ast.TraitDecl).init(allocator),
            .ffi_externs = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .constants = std.StringHashMap(ast.Expression).init(allocator),
            .string_globals = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .current_local_types = null,
            .current_local_type_ids = null,
            .current_struct_name = null,
            .current_instantiation = null,
            .current_module_prefix = null,
            .current_function_name = null,
            .current_loop_scope_depth = null,
            .current_collecting_function_name = null,
            .current_collecting_instantiation = null,
            .lambda_parents = std.StringHashMap([]const u8).init(allocator),
            .lambda_param_types = std.StringHashMap([]const ?[]const u8).init(allocator),
            .function_local_types = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .function_local_type_ids = std.StringHashMap(std.StringHashMap(sema_types.TypeId)).init(allocator),
            .captured_globals = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .lambda_captures = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .fn_box_globals = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .typed_ir = null,
            .type_store = null,
            .current_scanning_lambda = null,
            .program = undefined,
            .has_log = false,
            .next_lambda_id = 0,
            .closure_lambdas = .{},
            .current_saved_captures = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .is_wasm = is_wasm,
            .coverage_enabled = coverage_enabled,
            .cov_registry = if (coverage_enabled) CoverageRegistry.init(allocator) else null,
            .current_string_builder = null,
            .current_param_names = null,

            .i1_type = core.LLVMInt1Type(),
            .i8_type = core.LLVMInt8Type(),
            .i32_type = core.LLVMInt32Type(),
            .i64_type = core.LLVMInt64Type(),
            .void_type = core.LLVMVoidType(),
            .ptr_type = core.LLVMPointerType(core.LLVMInt8Type(), 0),

            .val_type = core.LLVMInt64Type(),
        };
        return compiler;
    }

    pub fn deinit(self: *LlvmCompiler) void {
        core.LLVMDisposeBuilder(self.builder);
        core.LLVMDisposeModule(self.module);
        target_machine.LLVMDisposeTargetMachine(self.target_machine);
        for (self.functions.items) |func| {
            self.allocator.free(func.param_names);
        }
        self.functions.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        for (self.scopes.items) |*scope| {
            scope.deferred_statements.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.locals.deinit();
        self.func_map.deinit();
        {
            var it = self.param_type_cache.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.param_type_cache.deinit();
        }
        {
            var it = self.param_type_str_cache.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                if (e.value_ptr.*) |v| self.allocator.free(v);
            }
            self.param_type_str_cache.deinit();
        }
        self.async_fns.deinit();
        self.structs.deinit();
        self.unions.deinit();
        self.enums.deinit();
        self.traits.deinit();
        self.constants.deinit();
        self.string_globals.deinit();
        self.lambda_parents.deinit();
        var captured_global_iter = self.captured_globals.iterator();
        while (captured_global_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.captured_globals.deinit();
        var lc_iter = self.lambda_captures.iterator();
        while (lc_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.lambda_captures.deinit();
        self.fn_box_globals.deinit();
        var flt_iter = self.function_local_types.iterator();
        while (flt_iter.next()) |entry| {
            var inner = entry.value_ptr.*;
            inner.deinit();
        }
        self.function_local_types.deinit();
        self.closure_lambdas.deinit(self.allocator);
        self.current_saved_captures.deinit();
        if (self.cov_registry) |*reg| {
            var mutable_reg = reg.*;
            mutable_reg.deinit();
        }
    }

    pub const isStructType = types_mod.isStructType;

    pub fn closureKey(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8) ![]const u8 {
        return self.closureKeyM(span, inst, self.closureKeyActiveSubst());
    }

    fn closureKeyActiveSubst(self: *LlvmCompiler) ?[]const MethodParamBinding {
        return self.current_collecting_method_subst orelse self.current_method_subst;
    }

    pub fn closureKeyM(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8, msubst: ?[]const MethodParamBinding) ![]const u8 {
        var sig = std.ArrayListUnmanaged(u8).empty;
        defer sig.deinit(self.allocator);
        if (msubst) |bs| for (bs) |b| {
            try sig.appendSlice(self.allocator, b.name);
            try sig.append(self.allocator, '=');
            try sig.appendSlice(self.allocator, b.concrete);
            try sig.append(self.allocator, ';');
        };
        return std.fmt.allocPrint(self.allocator, "{d}|{s}|{s}", .{
            getClosureUniqueId(span),
            inst orelse "",
            sig.items,
        });
    }

    pub fn getClosureUniqueId(span: ast.Span) usize {
        var h = std.hash.Wyhash.init(0);
        h.update(span.file);
        h.update(std.mem.asBytes(&span.line));
        h.update(std.mem.asBytes(&span.col));
        return h.final();
    }

    pub fn getTupleElementType(allocator: std.mem.Allocator, tuple_type: []const u8, idx: usize) ![]const u8 {
        if (!std.mem.startsWith(u8, tuple_type, "(") or !std.mem.endsWith(u8, tuple_type, ")")) {
            return "i32";
        }
        const inner = tuple_type[1 .. tuple_type.len - 1];
        var depth: usize = 0;
        var curr: usize = 0;
        var start: usize = 0;
        for (inner, 0..) |c, i| {
            switch (c) {
                '<', '(' => depth += 1,
                '>', ')' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        if (curr == idx) {
                            return try allocator.dupe(u8, std.mem.trim(u8, inner[start..i], " \t\r\n"));
                        }
                        curr += 1;
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        if (curr == idx and start <= inner.len) {
            return try allocator.dupe(u8, std.mem.trim(u8, inner[start..], " \t\r\n"));
        }
        return "i32";
    }

    pub const legacyStringOwnership = arc_mod.legacyStringOwnership;
    pub const erasedOwnershipDefault = arc_mod.erasedOwnershipDefault;
    pub const compileCallArgument = arc_mod.compileCallArgument;
    pub const acquisitionDisposition = arc_mod.acquisitionDisposition;
    pub const takeOwnedElement = arc_mod.takeOwnedElement;

    pub fn getOrCreateStringLiteral(self: *LlvmCompiler, str: []const u8) anyerror!types.LLVMValueRef {
        if (self.string_globals.get(str)) |global_var| {
            const unescaped = try unescapeString(self.allocator, str);
            defer self.allocator.free(unescaped);
            var field_types = [_]types.LLVMTypeRef{ self.i32_type, self.i32_type, core.LLVMArrayType(self.i8_type, @intCast(unescaped.len)) };
            const struct_type = core.LLVMStructType(&field_types, 3, 1);
            const chars_ptr = core.LLVMBuildStructGEP2(self.builder, struct_type, global_var, 2, "chars_ptr");
            return core.LLVMBuildPtrToInt(self.builder, chars_ptr, self.val_type, "str_ptr_int");
        }

        const unescaped = try unescapeString(self.allocator, str);
        defer self.allocator.free(unescaped);

        var field_types = [_]types.LLVMTypeRef{ self.i32_type, self.i32_type, core.LLVMArrayType(self.i8_type, @intCast(unescaped.len)) };
        const struct_type = core.LLVMStructType(&field_types, 3, 1);

        const global_var = core.LLVMAddGlobal(self.module, struct_type, "str_literal");
        core.LLVMSetGlobalConstant(global_var, 0);
        core.LLVMSetLinkage(global_var, types.LLVMLinkage.LLVMInternalLinkage);

        const str_z = try self.allocator.dupeZ(u8, unescaped);
        defer self.allocator.free(str_z);
        const ref_const = core.LLVMConstInt(self.i32_type, 100000000, 0);
        const len_const = core.LLVMConstInt(self.i32_type, @intCast(unescaped.len), 0);
        const chars_const = core.LLVMConstString(str_z.ptr, @intCast(unescaped.len), 1);

        var field_values = [_]types.LLVMValueRef{ ref_const, len_const, chars_const };
        const init_const = core.LLVMConstStruct(&field_values, 3, 1);
        core.LLVMSetInitializer(global_var, init_const);

        const dup_str = try self.allocator.dupe(u8, str);
        try self.string_globals.put(dup_str, global_var);

        const chars_ptr = core.LLVMBuildStructGEP2(self.builder, struct_type, global_var, 2, "chars_ptr");
        return core.LLVMBuildPtrToInt(self.builder, chars_ptr, self.val_type, "str_ptr_int");
    }

    pub const compileRetain = arc_mod.compileRetain;
    pub const errUnionParts = arc_mod.errUnionParts;
    pub const buildErrUnion = arc_mod.buildErrUnion;
    pub const compileRelease = arc_mod.compileRelease;
    pub const elideBorrowedArc = arc_mod.elideBorrowedArc;
    pub const getOrCreateDestructor = arc_mod.getOrCreateDestructor;
    pub const getOrCreateTraitDestructor = arc_mod.getOrCreateTraitDestructor;
    pub const getOrCreateDestructorByTypeId = arc_mod.getOrCreateDestructorByTypeId;
    pub const getOrCreateDestructorPreferId = arc_mod.getOrCreateDestructorPreferId;
    pub const releaseLocalVariables = arc_mod.releaseLocalVariables;
    pub const releaseLocalByName = arc_mod.releaseLocalByName;
    pub const substituteFieldType = arc_mod.substituteFieldType;
    pub const substTypeParams = arc_mod.substTypeParams;
    pub const substMethodParams = arc_mod.substMethodParams;
    pub const methodSymbol = types_mod.methodSymbol;
    pub const instantiationsOf = types_mod.instantiationsOf;
    pub const qualifySelfType = types_mod.qualifySelfType;

    pub fn compileAlloc(self: *LlvmCompiler, size: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const alloc_fn = if (self.func_map.get("nova_bytes_alloc")) |f| f else blk: {
            var arg_types = [_]types.LLVMTypeRef{self.val_type};
            const fn_type = core.LLVMFunctionType(self.val_type, &arg_types, 1, 0);
            const f = core.LLVMAddFunction(self.module, "nova_bytes_alloc", fn_type);
            try self.func_map.put("nova_bytes_alloc", f);
            break :blk f;
        };
        const fn_t = core.LLVMGlobalGetValueType(alloc_fn);
        var args = [_]types.LLVMValueRef{size};
        return core.LLVMBuildCall2(self.builder, fn_t, alloc_fn, &args, 1, "alloc_tmp");
    }

    // Array allocation that returns a real `ptr` (nova_array_alloc), so fixed-array construction keeps
    // pointer provenance -- the array literal/repeat store through this ptr and return it into a ptr
    // slot with no inttoptr laundering, which lets LLVM vectorize/hoist the later access loops.
    pub fn compileAllocArray(self: *LlvmCompiler, size: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const alloc_fn = if (self.func_map.get("nova_array_alloc")) |f| f else blk: {
            var arg_types = [_]types.LLVMTypeRef{self.val_type};
            const fn_type = core.LLVMFunctionType(self.ptr_type, &arg_types, 1, 0);
            const f = core.LLVMAddFunction(self.module, "nova_array_alloc", fn_type);
            try self.func_map.put("nova_array_alloc", f);
            break :blk f;
        };
        const fn_t = core.LLVMGlobalGetValueType(alloc_fn);
        var args = [_]types.LLVMValueRef{size};
        return core.LLVMBuildCall2(self.builder, fn_t, alloc_fn, &args, 1, "arr_alloc");
    }

    pub fn compileAllocPersistent(self: *LlvmCompiler, size: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const alloc_fn = if (self.func_map.get("nova_bytes_alloc_persistent")) |f| f else blk: {
            var arg_types = [_]types.LLVMTypeRef{self.val_type};
            const fn_type = core.LLVMFunctionType(self.val_type, &arg_types, 1, 0);
            const f = core.LLVMAddFunction(self.module, "nova_bytes_alloc_persistent", fn_type);
            try self.func_map.put("nova_bytes_alloc_persistent", f);
            break :blk f;
        };
        const fn_t = core.LLVMGlobalGetValueType(alloc_fn);
        var args = [_]types.LLVMValueRef{size};
        return core.LLVMBuildCall2(self.builder, fn_t, alloc_fn, &args, 1, "alloc_persistent_tmp");
    }

    pub fn valueOptionalInner(self: *LlvmCompiler, tid: sema_types.TypeId) ?sema_types.TypeId {
        const st = self.type_store orelse return null;
        const info = st.get(tid);
        if (info != .optional) return null;
        return switch (st.get(info.optional)) {
            .prim => info.optional,

            .enum_ => if (st.isOwned(info.optional)) null else info.optional,
            else => null,
        };
    }

    pub fn buildValoptBox(self: *LlvmCompiler, value: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const f = if (self.func_map.get("nova_valopt_box")) |g| g else blk: {
            var at = [_]types.LLVMTypeRef{self.val_type};
            const ft = core.LLVMFunctionType(self.val_type, &at, 1, 0);
            const g = core.LLVMAddFunction(self.module, "nova_valopt_box", ft);
            try self.func_map.put("nova_valopt_box", g);
            break :blk g;
        };
        const ft = core.LLVMGlobalGetValueType(f);
        var args = [_]types.LLVMValueRef{value};
        return core.LLVMBuildCall2(self.builder, ft, f, &args, 1, "valopt_box");
    }

    pub fn buildValoptUnbox(self: *LlvmCompiler, box: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const f = if (self.func_map.get("nova_valopt_unbox")) |g| g else blk: {
            var at = [_]types.LLVMTypeRef{self.val_type};
            const ft = core.LLVMFunctionType(self.val_type, &at, 1, 0);
            const g = core.LLVMAddFunction(self.module, "nova_valopt_unbox", ft);
            try self.func_map.put("nova_valopt_unbox", g);
            break :blk g;
        };
        const ft = core.LLVMGlobalGetValueType(f);
        var args = [_]types.LLVMValueRef{box};
        return core.LLVMBuildCall2(self.builder, ft, f, &args, 1, "valopt_unbox");
    }

    pub fn valoptTypeRefIsValue(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        const inner = self.typeRefToString(tr.optional.*) catch return false;
        if (std.mem.eql(u8, inner, "ptr")) return false;
        if (types_mod.cgPrim(inner) != null) return true;

        const base = getStructBaseName(inner);
        if (self.enums.contains(base) and !arc_mod.enumIsTaggedUnion(self, base)) return true;
        return false;
    }

    // Does a generic method's parameter (declared as the receiver struct's type parameter, e.g.
    // `value: T` on `List<T>.push`) resolve, for THIS receiver instance, to a value-optional element
    // type (`int | undefined`)? Routes through the receiver's TypeId arguments (which preserve
    // optionality) rather than the substituted param string (typeRefToString drops `.optional`).
    // `param_idx` is the call-argument index (self excluded).
    pub fn methodParamIsValueOptional(self: *LlvmCompiler, recv_expr: *const ast.Expression, method_name: []const u8, param_idx: usize) bool {
        const st = self.type_store orelse return false;
        const recv_tid = self.typeOfExprConcrete(recv_expr) orelse return false;
        const info = st.get(recv_tid);
        if (info != .struct_) return false;
        if (info.struct_.args.len == 0) return false;
        const rendered = sema_shadow.renderLegacy(self.allocator, st, recv_tid) catch return false;
        const base = getStructBaseName(rendered);
        const sdecl = self.structs.get(base) orelse return false;
        for (sdecl.methods) |m| {
            if (!std.mem.eql(u8, m.decl.name, method_name)) continue;
            // The method decl lists `self` as its first parameter; call arguments exclude it.
            var off: usize = 0;
            if (m.decl.params.len > 0 and std.mem.eql(u8, m.decl.params[0].name, "self")) off = 1;
            const real_idx = off + param_idx;
            if (real_idx >= m.decl.params.len) return false;
            const ptr = m.decl.params[real_idx].type_name orelse return false;
            if (ptr != .ident) return false;
            for (sdecl.type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, ptr.ident) and i < info.struct_.args.len) {
                    return self.valueOptionalInner(info.struct_.args[i]) != null;
                }
            }
            return false;
        }
        return false;
    }

    pub fn exprYieldsValoptBox(self: *LlvmCompiler, e: *const ast.Expression) bool {
        const tid = self.typeOfExprConcrete(e) orelse return false;
        if (self.valueOptionalInner(tid) == null) return false;
        return switch (e.kind) {

            .ident, .field_access, .call, .generic_call, .index, .optional_chaining => true,
            else => false,
        };
    }

    pub fn isUndefinedLiteralExpr(e: *const ast.Expression) bool {
        return e.kind == .literal and (e.kind.literal == .undefined or e.kind.literal == .null);
    }

    pub fn ptrElemSize(self: *LlvmCompiler) u64 {
        return if (self.is_wasm) 4 else 8;
    }

    pub fn valSlotSize(self: *LlvmCompiler) usize {
        _ = self;

        return 8;
    }

    pub fn envCaptureIndex(self: *LlvmCompiler, name: []const u8) ?usize {
        const fn_name = self.current_function_name orelse return null;
        if (!std.mem.startsWith(u8, fn_name, "__lambda_")) return null;
        const caps = self.lambda_captures.get(fn_name) orelse return null;
        for (caps.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, name)) return i;
        }
        return null;
    }

    pub fn envSlotAddr(self: *LlvmCompiler, index: usize) anyerror!types.LLVMValueRef {
        const env_slot = self.locals.get("__env") orelse return error.EnvNotFound;
        const env_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, env_slot, "env_ptr");
        const off = core.LLVMConstInt(self.val_type, index * self.valSlotSize(), 0);
        return core.LLVMBuildAdd(self.builder, env_ptr, off, "env_slot_addr");
    }

    pub fn compileFree(self: *LlvmCompiler, ptr: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const free_fn = if (self.func_map.get("nova_bytes_free")) |f| f else blk: {
            var arg_types = [_]types.LLVMTypeRef{self.val_type};
            const fn_type = core.LLVMFunctionType(self.void_type, &arg_types, 1, 0);
            const f = core.LLVMAddFunction(self.module, "nova_bytes_free", fn_type);
            try self.func_map.put("nova_bytes_free", f);
            break :blk f;
        };
        const fn_t = core.LLVMGlobalGetValueType(free_fn);
        var args = [_]types.LLVMValueRef{ptr};
        _ = core.LLVMBuildCall2(self.builder, fn_t, free_fn, &args, 1, "");
        return core.LLVMConstInt(self.val_type, 0, 0);
    }

    pub fn generateWasmMemoryFunctions(self: *LlvmCompiler) !void {

        var free_params = [_]types.LLVMTypeRef{self.val_type};
        const free_type = core.LLVMFunctionType(self.void_type, &free_params, 1, 0);
        const free_fn = core.LLVMAddFunction(self.module, "nova_bytes_free", free_type);
        try self.func_map.put("nova_bytes_free", free_fn);

        const entry_bb = core.LLVMAppendBasicBlock(free_fn, "entry");
        const do_free_bb = core.LLVMAppendBasicBlock(free_fn, "do_free");
        const ret_bb = core.LLVMAppendBasicBlock(free_fn, "ret");

        const builder = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(builder);
        core.LLVMPositionBuilderAtEnd(builder, entry_bb);

        const ptr = core.LLVMGetParam(free_fn, 0);

        const is_zero = core.LLVMBuildICmp(builder, types.LLVMIntPredicate.LLVMIntEQ, ptr, core.LLVMConstInt(self.val_type, 0, 0), "is_zero");

        const boundary = core.LLVMConstInt(self.val_type, 32 * 1024 * 1024, 0);
        const is_arena = core.LLVMBuildICmp(builder, types.LLVMIntPredicate.LLVMIntULT, ptr, boundary, "is_arena");

        const cond = if (self.is_wasm)
            core.LLVMConstInt(self.i1_type, 1, 0)
        else
            core.LLVMBuildOr(builder, is_zero, is_arena, "cond");

        _ = core.LLVMBuildCondBr(builder, cond, ret_bb, do_free_bb);

        core.LLVMPositionBuilderAtEnd(builder, do_free_bb);
        const next = core.LLVMBuildLoad2(builder, self.val_type, self.free_list.?, "next");
        const ptr_ptr = core.LLVMBuildIntToPtr(builder, ptr, core.LLVMPointerType(self.val_type, 0), "ptr_ptr");
        _ = core.LLVMBuildStore(builder, next, ptr_ptr);
        _ = core.LLVMBuildStore(builder, ptr, self.free_list.?);
        _ = core.LLVMBuildBr(builder, ret_bb);

        core.LLVMPositionBuilderAtEnd(builder, ret_bb);
        _ = core.LLVMBuildRetVoid(builder);

        var alloc_params = [_]types.LLVMTypeRef{self.val_type};
        const alloc_type = core.LLVMFunctionType(self.val_type, &alloc_params, 1, 0);
        const alloc_fn = core.LLVMAddFunction(self.module, "nova_bytes_alloc", alloc_type);
        try self.func_map.put("nova_bytes_alloc", alloc_fn);

        const a_entry_bb = core.LLVMAppendBasicBlock(alloc_fn, "entry");
        const ab = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(ab);

        core.LLVMPositionBuilderAtEnd(ab, a_entry_bb);
        const a_size = core.LLVMGetParam(alloc_fn, 0);

        if (self.is_wasm) {
            if (core.LLVMGetNamedGlobal(self.module, "__heap_base")) |heap_base| {
                const seed_bb = core.LLVMAppendBasicBlock(alloc_fn, "seed_heap");
                const cont_bb = core.LLVMAppendBasicBlock(alloc_fn, "alloc_cont");
                const cur = core.LLVMBuildLoad2(ab, self.val_type, self.heap_ptr.?, "seed_cur");
                const is0 = core.LLVMBuildICmp(ab, .LLVMIntEQ, cur, core.LLVMConstInt(self.val_type, 0, 0), "heap_uninit");
                _ = core.LLVMBuildCondBr(ab, is0, seed_bb, cont_bb);
                core.LLVMPositionBuilderAtEnd(ab, seed_bb);
                const hb = core.LLVMBuildPtrToInt(ab, heap_base, self.val_type, "heap_base_int");
                _ = core.LLVMBuildStore(ab, hb, self.heap_ptr.?);
                if (self.persistent_ptr) |pp| {
                    const poff = core.LLVMConstInt(self.val_type, 32 * 1024 * 1024, 0);
                    _ = core.LLVMBuildStore(ab, core.LLVMBuildAdd(ab, hb, poff, "pbase"), pp);
                }
                _ = core.LLVMBuildBr(ab, cont_bb);
                core.LLVMPositionBuilderAtEnd(ab, cont_bb);
            }
        }

        const a_old_ptr = core.LLVMBuildLoad2(ab, self.val_type, self.heap_ptr.?, "old_heap");
        const a_size_i32 = core.LLVMBuildTrunc(ab, a_size, self.i32_type, "size_i32");
        const a_size_ptr2 = core.LLVMBuildIntToPtr(ab, a_old_ptr, core.LLVMPointerType(self.i32_type, 0), "size_ptr2");
        _ = core.LLVMBuildStore(ab, a_size_i32, a_size_ptr2);

        const a_client_ptr = core.LLVMBuildAdd(ab, a_old_ptr, core.LLVMConstInt(self.val_type, 4, 0), "client_ptr");

        const a_total_size = core.LLVMBuildAdd(ab, a_size, core.LLVMConstInt(self.val_type, 4, 0), "total_size");
        const a_seven = core.LLVMConstInt(self.val_type, 7, 0);
        const a_aligned = core.LLVMBuildAnd(ab, core.LLVMBuildAdd(ab, a_total_size, a_seven, "add_seven"), core.LLVMConstInt(self.val_type, ~@as(u64, 7), 0), "aligned");

        const a_new_ptr = core.LLVMBuildAdd(ab, a_old_ptr, a_aligned, "new_heap");
        _ = core.LLVMBuildStore(ab, a_new_ptr, self.heap_ptr.?);
        _ = core.LLVMBuildRet(ab, a_client_ptr);

        var p_alloc_params = [_]types.LLVMTypeRef{self.val_type};
        const p_alloc_type = core.LLVMFunctionType(self.val_type, &p_alloc_params, 1, 0);
        const p_alloc_fn = core.LLVMAddFunction(self.module, "nova_bytes_alloc_persistent", p_alloc_type);
        try self.func_map.put("nova_bytes_alloc_persistent", p_alloc_fn);

        const ap_entry_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "entry");
        const ap_cond_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_cond");
        const ap_body_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_body");
        const ap_next_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_next");
        const ap_found_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_found");
        const ap_prev_null_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "prev_null");
        const ap_prev_not_null_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "prev_not_null");
        const ap_bump_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_bump");
        const ap_end_bb = core.LLVMAppendBasicBlock(p_alloc_fn, "alloc_end");

        const apb = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(apb);

        core.LLVMPositionBuilderAtEnd(apb, ap_entry_bb);
        const ap_size = core.LLVMGetParam(p_alloc_fn, 0);

        const ap_prev_ptr = core.LLVMBuildAlloca(apb, self.val_type, "prev_ptr");
        const ap_curr_ptr = core.LLVMBuildAlloca(apb, self.val_type, "curr_ptr");
        _ = core.LLVMBuildStore(apb, core.LLVMConstInt(self.val_type, 0, 0), ap_prev_ptr);
        const ap_head = core.LLVMBuildLoad2(apb, self.val_type, self.free_list.?, "head");
        _ = core.LLVMBuildStore(apb, ap_head, ap_curr_ptr);
        _ = core.LLVMBuildBr(apb, ap_cond_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_cond_bb);
        const ap_curr = core.LLVMBuildLoad2(apb, self.val_type, ap_curr_ptr, "curr");
        const ap_is_null = core.LLVMBuildICmp(apb, types.LLVMIntPredicate.LLVMIntEQ, ap_curr, core.LLVMConstInt(self.val_type, 0, 0), "is_null");
        _ = core.LLVMBuildCondBr(apb, ap_is_null, ap_bump_bb, ap_body_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_body_bb);
        const ap_four = core.LLVMConstInt(self.val_type, 4, 0);
        const ap_size_addr = core.LLVMBuildSub(apb, ap_curr, ap_four, "size_addr");
        const ap_size_ptr = core.LLVMBuildIntToPtr(apb, ap_size_addr, core.LLVMPointerType(self.i32_type, 0), "size_ptr");
        const ap_block_size_i32 = core.LLVMBuildLoad2(apb, self.i32_type, ap_size_ptr, "block_size_i32");
        const ap_block_size = core.LLVMBuildZExt(apb, ap_block_size_i32, self.val_type, "block_size");
        const ap_is_ok = core.LLVMBuildICmp(apb, types.LLVMIntPredicate.LLVMIntUGE, ap_block_size, ap_size, "is_ok");
        _ = core.LLVMBuildCondBr(apb, ap_is_ok, ap_found_bb, ap_next_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_next_bb);
        _ = core.LLVMBuildStore(apb, ap_curr, ap_prev_ptr);
        const ap_next_node_ptr = core.LLVMBuildIntToPtr(apb, ap_curr, core.LLVMPointerType(self.val_type, 0), "next_node_ptr");
        const ap_next_node = core.LLVMBuildLoad2(apb, self.val_type, ap_next_node_ptr, "next_node");
        _ = core.LLVMBuildStore(apb, ap_next_node, ap_curr_ptr);
        _ = core.LLVMBuildBr(apb, ap_cond_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_found_bb);
        const ap_next_node_ptr2 = core.LLVMBuildIntToPtr(apb, ap_curr, core.LLVMPointerType(self.val_type, 0), "next_node_ptr2");
        const ap_next_node2 = core.LLVMBuildLoad2(apb, self.val_type, ap_next_node_ptr2, "next_node2");
        const ap_prev = core.LLVMBuildLoad2(apb, self.val_type, ap_prev_ptr, "prev");
        const ap_is_prev_null = core.LLVMBuildICmp(apb, types.LLVMIntPredicate.LLVMIntEQ, ap_prev, core.LLVMConstInt(self.val_type, 0, 0), "is_prev_null");
        _ = core.LLVMBuildCondBr(apb, ap_is_prev_null, ap_prev_null_bb, ap_prev_not_null_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_prev_null_bb);
        _ = core.LLVMBuildStore(apb, ap_next_node2, self.free_list.?);
        _ = core.LLVMBuildBr(apb, ap_end_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_prev_not_null_bb);
        const ap_prev_next_ptr = core.LLVMBuildIntToPtr(apb, ap_prev, core.LLVMPointerType(self.val_type, 0), "prev_next_ptr");
        _ = core.LLVMBuildStore(apb, ap_next_node2, ap_prev_next_ptr);
        _ = core.LLVMBuildBr(apb, ap_end_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_bump_bb);
        const ap_old_ptr = core.LLVMBuildLoad2(apb, self.val_type, self.persistent_ptr.?, "old_persistent");
        const ap_size_i32 = core.LLVMBuildTrunc(apb, ap_size, self.i32_type, "size_i32");
        const ap_size_ptr2 = core.LLVMBuildIntToPtr(apb, ap_old_ptr, core.LLVMPointerType(self.i32_type, 0), "size_ptr2");
        _ = core.LLVMBuildStore(apb, ap_size_i32, ap_size_ptr2);

        const ap_client_ptr = core.LLVMBuildAdd(apb, ap_old_ptr, core.LLVMConstInt(self.val_type, 4, 0), "client_ptr");

        const ap_total_size = core.LLVMBuildAdd(apb, ap_size, core.LLVMConstInt(self.val_type, 4, 0), "total_size");
        const ap_seven = core.LLVMConstInt(self.val_type, 7, 0);
        const ap_aligned = core.LLVMBuildAnd(apb, core.LLVMBuildAdd(apb, ap_total_size, ap_seven, "add_seven"), core.LLVMConstInt(self.val_type, ~@as(u64, 7), 0), "aligned");

        const ap_new_ptr = core.LLVMBuildAdd(apb, ap_old_ptr, ap_aligned, "new_persistent");
        _ = core.LLVMBuildStore(apb, ap_new_ptr, self.persistent_ptr.?);
        _ = core.LLVMBuildBr(apb, ap_end_bb);

        core.LLVMPositionBuilderAtEnd(apb, ap_end_bb);
        const ap_res = core.LLVMBuildPhi(apb, self.val_type, "alloc_res");
        var ap_phi_vals = [_]types.LLVMValueRef{ ap_curr, ap_curr, ap_client_ptr };
        var ap_phi_bbs = [_]types.LLVMBasicBlockRef{ ap_prev_null_bb, ap_prev_not_null_bb, ap_bump_bb };
        core.LLVMAddIncoming(ap_res, &ap_phi_vals, &ap_phi_bbs, 3);
        _ = core.LLVMBuildRet(apb, ap_res);

        var retain_params = [_]types.LLVMTypeRef{self.val_type};
        const retain_type = core.LLVMFunctionType(self.void_type, &retain_params, 1, 0);
        const retain_fn = core.LLVMAddFunction(self.module, "nova_retain", retain_type);
        try self.func_map.put("nova_retain", retain_fn);
        const r_entry = core.LLVMAppendBasicBlock(retain_fn, "entry");
        const rb = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(rb);
        core.LLVMPositionBuilderAtEnd(rb, r_entry);
        _ = core.LLVMBuildRetVoid(rb);

        const ptr_type = core.LLVMPointerType(self.void_type, 0);
        var release_params = [_]types.LLVMTypeRef{self.val_type, ptr_type};
        const release_type = core.LLVMFunctionType(self.void_type, &release_params, 2, 0);
        const release_fn = core.LLVMAddFunction(self.module, "nova_release", release_type);
        try self.func_map.put("nova_release", release_fn);
        const rel_entry = core.LLVMAppendBasicBlock(release_fn, "entry");
        const relb = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(relb);
        core.LLVMPositionBuilderAtEnd(relb, rel_entry);
        _ = core.LLVMBuildRetVoid(relb);
    }

    pub fn getStructPrefix(self: *LlvmCompiler, fn_decl: ast.FunctionDecl) ?[]const u8 {

        if (fn_decl.params.len > 0) {
            const first_param = fn_decl.params[0];
            if (std.mem.eql(u8, first_param.name, "self")) {
                if (first_param.type_name) |t| {
                    switch (t) {
                        .ident => |name| {
                            const scoped = self.scopedStructName(getStructBaseName(name), fn_decl.span.file);
                            if (self.isStructType(scoped)) return scoped;
                        },
                        .generic => |g| {
                            const scoped = self.scopedStructName(getStructBaseName(g.name), fn_decl.span.file);
                            if (self.isStructType(scoped)) return scoped;
                        },
                        else => {},
                    }
                }
            }
        }
        if (std.mem.eql(u8, fn_decl.name, "new")) {
            if (fn_decl.ret_type) |ret| {
                switch (ret) {
                    .ident => |name| {
                        const scoped = self.scopedStructName(getStructBaseName(name), fn_decl.span.file);
                        if (self.isStructType(scoped)) return scoped;
                    },
                    .generic => |g| {
                        const scoped = self.scopedStructName(getStructBaseName(g.name), fn_decl.span.file);
                        if (self.isStructType(scoped)) return scoped;
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    pub fn isAlreadyNamespaced(name: []const u8) bool {
        const prefixes = [_][]const u8{
            "string", "bson", "json", "datetime", "http", "i32", "double", "bool", "list", "map", "set", "concurrency", "channel", "sync", "allocator", "web",
            "net_tcp_socket", "net_tcp_server", "net_tcp_client",
            "net_http_request", "net_http_response", "net_http_mime", "net_http_status", "net_http_methods", "net_http_server", "net_http_client",
            "concurrency_fiber", "concurrency_channel",
            "collections_list", "collections_map", "collections_set",
            "io_file", "io_dir",
            "serde_json", "serde_bson", "serde_yaml",
            "mem_allocator", "mem_arena", "mem_c_allocator", "mem_memory"
        };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) {
                if (name.len > prefix.len and name[prefix.len] == '_') return true;
            }
        }
        return false;
    }

    pub fn getTypeSize(self: *LlvmCompiler, type_ref: ast.TypeRef, is_field: bool) u32 {
        switch (type_ref) {
            .generic => |g| {
                if (is_field) {
                    return 8;
                }
                const base = getStructBaseName(g.name);
                if (self.structs.get(base)) |s| {
                    var size: u32 = 0;
                    for (s.fields) |f| {
                        const f_size = self.getTypeSize(f.type_name, true);
                        size = (size + f_size - 1) / f_size * f_size;
                        size += f_size;
                    }
                    return size;
                }
                return 8;
            },
            .ident => |name| {

                if (types_mod.cgPrim(name)) |p| {
                    switch (p.repr) {
                        .i1 => {},
                        .i8 => return 1,
                        .i16 => return 2,

                        .i32 => return 4,
                        .word => return 8,
                        .i64 => return 8,
                        .f32 => return 4,
                        .f64 => return 8,
                    }
                }
                const base = getStructBaseName(name);
                if (self.structs.get(base)) |s| {
                    if (is_field) {
                        return 8;
                    }
                    var size: u32 = 0;
                    for (s.fields) |f| {
                        const f_size = self.getTypeSize(f.type_name, true);
                        size = (size + f_size - 1) / f_size * f_size;
                        size += f_size;
                    }
                    return size;
                }
                if (self.unions.get(base)) |u| {
                    if (is_field) {
                        return 8;
                    }
                    var max_size: u32 = 0;
                    for (u.fields) |f| {
                        const f_size = self.getTypeSize(f.type_name, true);
                        if (f_size > max_size) max_size = f_size;
                    }
                    return max_size;
                }
                return 8;
            },
            else => return 8,
        }
    }

    pub const toLLVMType = types_mod.toLLVMType;
    pub const llvmForRepr = types_mod.llvmForRepr;
    pub const vecF64x4Type = types_mod.vecF64x4Type;
    pub const castToValType = types_mod.castToValType;
    pub const castFromValType = types_mod.castFromValType;
    pub const slotTypeForLocal = types_mod.slotTypeForLocal;
    pub const slotTypeForLocalId = types_mod.slotTypeForLocalId;
    pub const coerceToSlotType = types_mod.coerceToSlotType;

    pub fn getFieldOffset(self: *LlvmCompiler, struct_name: []const u8, field_name: []const u8) anyerror!u32 {
        const base_struct = getStructBaseName(struct_name);
        if (self.unions.contains(base_struct)) {
            return 0;
        }
        const s = self.structs.get(base_struct) orelse {
            return error.StructTypeNotFound;
        };
        var offset: u32 = 0;
        for (s.fields) |field| {
            const f_size = self.getTypeSize(field.type_name, true);
            offset = (offset + f_size - 1) / f_size * f_size;
            if (std.mem.eql(u8, field.name, field_name)) {
                return offset;
            }
            offset += f_size;
        }
        return error.FieldNotFound;
    }

    pub fn buildCallWithCasts(self: *LlvmCompiler, fn_val: types.LLVMValueRef, args: []const types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const fn_t = core.LLVMGlobalGetValueType(fn_val);
        const param_count = core.LLVMCountParamTypes(fn_t);
        const param_types = try self.allocator.alloc(types.LLVMTypeRef, param_count);
        defer self.allocator.free(param_types);
        core.LLVMGetParamTypes(fn_t, param_types.ptr);

        const casted_args = try self.allocator.alloc(types.LLVMValueRef, args.len);
        defer self.allocator.free(casted_args);

        for (args, 0..) |arg, idx| {
            if (idx < param_count) {
                const expected_t = param_types[idx];
                const expected_kind = core.LLVMGetTypeKind(expected_t);
                const actual_t = core.LLVMTypeOf(arg);
                const actual_kind = core.LLVMGetTypeKind(actual_t);

                if (expected_kind == types.LLVMTypeKind.LLVMPointerTypeKind and actual_kind != types.LLVMTypeKind.LLVMPointerTypeKind) {
                    casted_args[idx] = core.LLVMBuildIntToPtr(self.builder, arg, expected_t, "arg_ptr_cast");
                } else if (expected_kind == types.LLVMTypeKind.LLVMIntegerTypeKind and actual_kind == types.LLVMTypeKind.LLVMDoubleTypeKind and core.LLVMGetIntTypeWidth(expected_t) == 64) {

                    casted_args[idx] = core.LLVMBuildBitCast(self.builder, arg, expected_t, "arg_double_to_val");
                } else if (expected_kind == types.LLVMTypeKind.LLVMDoubleTypeKind and actual_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {

                    casted_args[idx] = core.LLVMBuildBitCast(self.builder, arg, expected_t, "arg_val_to_double");
                } else if (expected_kind == types.LLVMTypeKind.LLVMIntegerTypeKind and actual_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {
                    const expected_width = core.LLVMGetIntTypeWidth(expected_t);
                    const actual_width = core.LLVMGetIntTypeWidth(actual_t);
                    if (expected_width < actual_width) {
                        casted_args[idx] = core.LLVMBuildTrunc(self.builder, arg, expected_t, "arg_trunc_cast");
                    } else if (expected_width > actual_width) {
                        casted_args[idx] = core.LLVMBuildZExt(self.builder, arg, expected_t, "arg_zext_cast");
                    } else {
                        casted_args[idx] = arg;
                    }
                } else {
                    casted_args[idx] = arg;
                }
            } else {
                casted_args[idx] = arg;
            }
        }

        const ret_t = core.LLVMGetReturnType(fn_t);
        const is_void = core.LLVMGetTypeKind(ret_t) == types.LLVMTypeKind.LLVMVoidTypeKind;
        const call_val = core.LLVMBuildCall2(self.builder, fn_t, fn_val, casted_args.ptr, @intCast(args.len), if (is_void) "" else "calltmp");

        if (is_void) {
            return core.LLVMConstInt(self.val_type, 0, 0);
        }

        const ret_kind = core.LLVMGetTypeKind(ret_t);
        if (ret_kind == types.LLVMTypeKind.LLVMPointerTypeKind) {
            return core.LLVMBuildPtrToInt(self.builder, call_val, self.val_type, "ret_ptr_int");
        } else if (ret_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {
            const ret_width = core.LLVMGetIntTypeWidth(ret_t);
            const val_width = core.LLVMGetIntTypeWidth(self.val_type);
            if (ret_width < val_width) {
                return core.LLVMBuildSExt(self.builder, call_val, self.val_type, "ret_sext");
            } else if (ret_width > val_width) {
                return core.LLVMBuildTrunc(self.builder, call_val, self.val_type, "ret_trunc");
            }
        }
        return call_val;
    }

    pub fn getFunctionParamType(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?[]const u8 {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ func_name, param_idx }) catch return self.getFunctionParamTypeUncached(func_name, param_idx);
        if (self.param_type_str_cache.get(key)) |cached| {
            self.allocator.free(key);
            return if (cached) |c| (self.allocator.dupe(u8, c) catch null) else null;
        }
        const result = self.getFunctionParamTypeUncached(func_name, param_idx);
        // Store an independent copy in the cache; the caller keeps `result`.
        const stored: ?[]const u8 = if (result) |r| (self.allocator.dupe(u8, r) catch null) else null;
        self.param_type_str_cache.put(key, stored) catch {
            if (stored) |s| self.allocator.free(s);
            self.allocator.free(key);
        };
        return result;
    }

    fn getFunctionParamTypeUncached(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?[]const u8 {
        for (self.program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| {
                    var name = f.name;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        if (!LlvmCompiler.isAlreadyNamespaced(f.name)) {
                            name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, f.name }) catch return null;
                        }
                    }

                    if (std.mem.eql(u8, name, func_name) or std.mem.eql(u8, f.name, func_name)) {
                        if (param_idx < f.params.len) {
                            if (f.params[param_idx].type_name) |t| {
                                return self.typeRefToString(t) catch null;
                            }
                        }
                        return null;
                    }
                },
                .struct_decl => |s| {
                    for (s.methods) |m| {

                        const insts = self.instantiationsOf(s) catch continue;
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            if (!std.mem.eql(u8, full_name, func_name)) continue;
                            if (param_idx == 0) return s.name;
                            const is_constructor = std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new");
                            const actual_idx = if (is_constructor) param_idx - 1 else param_idx;
                            if (actual_idx < m.decl.params.len) {
                                if (m.decl.params[actual_idx].type_name) |t| {
                                    return self.typeRefToString(t) catch null;
                                }
                            }
                            return null;
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    pub fn getFunctionParamTypeRef(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?ast.TypeRef {
        // Cache lookup: the scan below is O(all-declarations x methods x instantiations) and this
        // is called per-parameter per-call-site, so memoise on (func_name, param_idx). Pure for a
        // fixed program.
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ func_name, param_idx }) catch return self.getFunctionParamTypeRefUncached(func_name, param_idx);
        if (self.param_type_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        const result = self.getFunctionParamTypeRefUncached(func_name, param_idx);
        self.param_type_cache.put(key, result) catch self.allocator.free(key);
        return result;
    }

    fn getFunctionParamTypeRefUncached(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?ast.TypeRef {
        for (self.program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| {
                    var name = f.name;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        if (!LlvmCompiler.isAlreadyNamespaced(f.name)) {
                            name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, f.name }) catch return null;
                        }
                    }
                    if (std.mem.eql(u8, name, func_name)) {
                        if (param_idx < f.params.len) return f.params[param_idx].type_name;
                        return null;
                    }
                },
                .struct_decl => |s| {
                    for (s.methods) |m| {
                        const insts = self.instantiationsOf(s) catch continue;
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            if (!std.mem.eql(u8, full_name, func_name)) continue;
                            if (param_idx == 0) return null;
                            const is_constructor = std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new");
                            const actual_idx = if (is_constructor) param_idx - 1 else param_idx;
                            if (actual_idx < m.decl.params.len) return m.decl.params[actual_idx].type_name;
                            return null;
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    pub fn coerceValoptArg(self: *LlvmCompiler, val: types.LLVMValueRef, arg: *const ast.Expression, param_tr_opt: ?ast.TypeRef) anyerror!types.LLVMValueRef {
        const param_tr = param_tr_opt orelse return val;
        if (self.valoptTypeRefIsValue(param_tr) and
            !LlvmCompiler.isUndefinedLiteralExpr(arg) and
            !self.exprYieldsValoptBox(arg))
        {
            return try self.buildValoptBox(self.coerceToSlotType(val, self.val_type));
        }
        return val;
    }

    pub fn findNamespacedSpec(self: *LlvmCompiler, obj: []const u8, field: []const u8, type_args: []const ast.TypeRef) anyerror!?types.LLVMValueRef {
        var nb = std.ArrayListUnmanaged(u8).empty;
        defer nb.deinit(self.allocator);
        try nb.appendSlice(self.allocator, obj);
        try nb.append(self.allocator, '_');
        try nb.appendSlice(self.allocator, field);
        for (type_args) |ta| {
            const r = try self.typeRefToString(ta);
            const ma = try types_mod.mangleTypeName(self.allocator, r);
            defer self.allocator.free(ma);
            try nb.appendSlice(self.allocator, "__");
            try nb.appendSlice(self.allocator, ma);
        }
        const spec_target = nb.items;
        if (self.func_map.get(spec_target)) |v| return v;
        var it = self.func_map.keyIterator();
        while (it.next()) |k| {
            const key = k.*;
            if (key.len > spec_target.len + 1 and key[key.len - spec_target.len - 1] == '_' and std.mem.endsWith(u8, key, spec_target)) {
                return self.func_map.get(key);
            }
        }
        return null;
    }

    fn getGlobalVTable(self: *LlvmCompiler, struct_name: []const u8, trait_name: []const u8) !types.LLVMValueRef {
        const base_name = try std.fmt.allocPrint(self.allocator, "_vtable_{s}_{s}", .{ struct_name, trait_name });
        defer self.allocator.free(base_name);
        const vtable_name = try self.allocator.dupeZ(u8, base_name);
        defer self.allocator.free(vtable_name);

        if (core.LLVMGetNamedGlobal(self.module, vtable_name.ptr)) |existing| {
            return existing;
        }

        const trait_decl = self.traits.get(trait_name) orelse return error.TraitNotFound;

        const element_type = self.ptr_type;

        const n = trait_decl.methods.len + 1;
        const array_type = core.LLVMArrayType(element_type, @intCast(n));

        const global = core.LLVMAddGlobal(self.module, array_type, vtable_name.ptr);
        core.LLVMSetGlobalConstant(global, 1);

        const elements = try self.allocator.alloc(types.LLVMValueRef, n);
        defer self.allocator.free(elements);

        elements[0] = (try self.getOrCreateDestructor(struct_name)) orelse core.LLVMConstNull(element_type);

        for (trait_decl.methods, 0..) |tm, idx0| {
            const idx = idx0 + 1;
            var found_method: ?types.LLVMValueRef = null;
            const method_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name, tm.name });
            defer self.allocator.free(method_name);

            if (self.func_map.get(method_name)) |fn_val| {
                found_method = fn_val;
            } else {
                const struct_name_lower = try self.allocator.alloc(u8, struct_name.len);
                defer self.allocator.free(struct_name_lower);
                _ = std.ascii.lowerString(struct_name_lower, struct_name);
                const method_name_lower = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name_lower, tm.name });
                defer self.allocator.free(method_name_lower);
                if (self.func_map.get(method_name_lower)) |fn_val| {
                    found_method = fn_val;
                }
            }

            if (found_method) |fm| {
                elements[idx] = fm;
            } else {
                elements[idx] = core.LLVMConstNull(element_type);
            }
        }

        const const_array = core.LLVMConstArray(element_type, elements.ptr, @intCast(n));
        core.LLVMSetInitializer(global, const_array);

        return global;
    }

    pub fn constructTraitObject(self: *LlvmCompiler, struct_ptr: types.LLVMValueRef, struct_name: []const u8, trait_name_raw: []const u8) !types.LLVMValueRef {

        const trait_name = getStructBaseName(trait_name_raw);
        const ptr_size = @as(u32, 8);
        const size_val = core.LLVMConstInt(self.val_type, ptr_size * 2, 0);
        const trait_obj = try self.compileAlloc(size_val);

        try self.compileRetain(struct_ptr);

        const addr0 = trait_obj;
        const ptr0 = core.LLVMBuildIntToPtr(self.builder, addr0, core.LLVMPointerType(self.val_type, 0), "trait_struct_ptr");
        _ = core.LLVMBuildStore(self.builder, struct_ptr, ptr0);

        const addr1 = core.LLVMBuildAdd(self.builder, trait_obj, core.LLVMConstInt(self.val_type, ptr_size, 0), "vtable_addr");
        const ptr1 = core.LLVMBuildIntToPtr(self.builder, addr1, core.LLVMPointerType(self.val_type, 0), "trait_vtable_ptr");

        const vtable_global = try self.getGlobalVTable(struct_name, trait_name);
        const vtable_int = core.LLVMBuildPtrToInt(self.builder, vtable_global, self.val_type, "vtable_int");
        _ = core.LLVMBuildStore(self.builder, vtable_int, ptr1);

        try self.registerTemporary(trait_obj, trait_name);

        return trait_obj;
    }

    fn getOrCreateAtomicExternFn(self: *LlvmCompiler, fn_name: []const u8, t_name: []const u8, method_name: []const u8) !types.LLVMValueRef {
        if (self.func_map.get(fn_name)) |val| {
            return val;
        }

        const ret_llvm_type = if (std.mem.eql(u8, method_name, "compareAndSwap"))
            self.i32_type
        else if (std.mem.eql(u8, method_name, "store"))
            self.void_type
        else
            if (std.mem.eql(u8, t_name, "i64") or std.mem.eql(u8, t_name, "u64") or std.mem.eql(u8, t_name, "double")) self.i64_type else if (std.mem.eql(u8, t_name, "bool")) self.i1_type else self.i32_type;

        var param_types = std.ArrayList(types.LLVMTypeRef).empty;
        defer param_types.deinit(self.allocator);

        try param_types.append(self.allocator, self.ptr_type);

        if (std.mem.eql(u8, method_name, "add") or std.mem.eql(u8, method_name, "sub") or std.mem.eql(u8, method_name, "store")) {
            const t_llvm = if (std.mem.eql(u8, t_name, "i64") or std.mem.eql(u8, t_name, "u64") or std.mem.eql(u8, t_name, "double")) self.i64_type else if (std.mem.eql(u8, t_name, "bool")) self.i1_type else self.i32_type;
            try param_types.append(self.allocator, t_llvm);
        } else if (std.mem.eql(u8, method_name, "compareAndSwap")) {
            const t_llvm = if (std.mem.eql(u8, t_name, "i64") or std.mem.eql(u8, t_name, "u64") or std.mem.eql(u8, t_name, "double")) self.i64_type else if (std.mem.eql(u8, t_name, "bool")) self.i1_type else self.i32_type;
            try param_types.append(self.allocator, t_llvm);
            try param_types.append(self.allocator, t_llvm);
        }

        const fn_type = core.LLVMFunctionType(ret_llvm_type, param_types.items.ptr, @intCast(param_types.items.len), 0);

        const fn_name_c = try self.allocator.dupeZ(u8, fn_name);
        defer self.allocator.free(fn_name_c);
        const f = core.LLVMAddFunction(self.module, fn_name_c.ptr, fn_type);
        try self.func_map.put(try self.allocator.dupe(u8, fn_name), f);
        return f;
    }

    pub fn compileAtomicCall(self: *LlvmCompiler, obj_type: []const u8, method_name: []const u8, obj_expr: ast.Expression, args_exprs: []const ast.Expression) !types.LLVMValueRef {
        var t_name: []const u8 = "i32";
        if (std.mem.indexOfScalar(u8, obj_type, '<')) |start_idx| {
            if (std.mem.indexOfScalar(u8, obj_type, '>')) |end_idx| {
                t_name = obj_type[start_idx + 1 .. end_idx];
            }
        }
        t_name = std.mem.trim(u8, t_name, " ");

        const atomic_obj_ptr = try self.compileExpression(obj_expr);

        const ptr_val = core.LLVMBuildLoad2(self.builder, self.ptr_type, core.LLVMBuildIntToPtr(self.builder, atomic_obj_ptr, core.LLVMPointerType(self.ptr_type, 0), "atomic_ptr_ptr"), "atomic_ptr");

        var fn_name: []const u8 = "";

        const is_i64 = if (types_mod.cgPrim(t_name)) |pr| types_mod.reprBitWidth(pr.repr) == 64 else false;
        if (std.mem.eql(u8, method_name, "add")) {
            if (is_i64) {
                fn_name = "nova_atomic_add_i64";
            } else {
                fn_name = "nova_atomic_add_i32";
            }
        } else if (std.mem.eql(u8, method_name, "sub")) {
            if (is_i64) {
                fn_name = "nova_atomic_sub_i64";
            } else {
                fn_name = "nova_atomic_sub_i32";
            }
        } else if (std.mem.eql(u8, method_name, "load")) {
            if (is_i64) {
                fn_name = "nova_atomic_load_i64";
            } else if (std.mem.eql(u8, t_name, "bool")) {
                fn_name = "nova_atomic_load_bool";
            } else {
                fn_name = "nova_atomic_load_i32";
            }
        } else if (std.mem.eql(u8, method_name, "store")) {
            if (is_i64) {
                fn_name = "nova_atomic_store_i64";
            } else if (std.mem.eql(u8, t_name, "bool")) {
                fn_name = "nova_atomic_store_bool";
            } else {
                fn_name = "nova_atomic_store_i32";
            }
        } else if (std.mem.eql(u8, method_name, "compareAndSwap")) {
            if (is_i64) {
                fn_name = "nova_atomic_cas_i64";
            } else if (std.mem.eql(u8, t_name, "bool")) {
                fn_name = "nova_atomic_cas_bool";
            } else {
                fn_name = "nova_atomic_cas_i32";
            }
        } else {
            return error.UnknownAtomicMethod;
        }

        const atomic_fn = try self.getOrCreateAtomicExternFn(fn_name, t_name, method_name);

        var args = std.ArrayList(types.LLVMValueRef).empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, ptr_val);
        const t_llvm = if (is_i64) self.i64_type else if (std.mem.eql(u8, t_name, "bool")) self.i1_type else self.i32_type;
        for (args_exprs) |arg| {
            const arg_compiled = try self.compileExpression(arg);
            try args.append(self.allocator, self.castFromValType(arg_compiled, t_llvm));
        }

        const fn_t = core.LLVMGlobalGetValueType(atomic_fn);
        const is_void = std.mem.eql(u8, method_name, "store");
        const call_name = if (is_void) "" else "atomic_call_tmp";
        const ret_val = core.LLVMBuildCall2(self.builder, fn_t, atomic_fn, args.items.ptr, @intCast(args.items.len), call_name);

        if (std.mem.eql(u8, method_name, "compareAndSwap")) {
            return core.LLVMBuildTrunc(self.builder, ret_val, self.i1_type, "cas_bool");
        }

        return ret_val;
    }

    pub fn compileExplicitGenericMethodCall(
        self: *LlvmCompiler,
        fa: ast.FieldAccess,
        type_args: []const ast.TypeRef,
        args_exprs: []const ast.Expression,
    ) anyerror!?types.LLVMValueRef {
        const obj_type = (try self.resolveExpressionTypeName(fa.object)) orelse return null;
        const base = getStructBaseName(obj_type);
        const s = self.structs.get(base) orelse return null;

        var method_decl: ?ast.FunctionDecl = null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, fa.field)) {
                if (m.decl.type_params.len == type_args.len and type_args.len > 0) method_decl = m.decl;
                break;
            }
        }
        const mdecl = method_decl orelse return null;

        const base_sym = try self.methodSymbol(obj_type, fa.field);
        var name_buf = std.ArrayListUnmanaged(u8).empty;
        try name_buf.appendSlice(self.allocator, base_sym);
        for (type_args) |ta| {
            const rendered = try self.typeRefToString(ta);
            const ma = try types_mod.mangleTypeName(self.allocator, rendered);
            defer self.allocator.free(ma);
            try name_buf.appendSlice(self.allocator, "__");
            try name_buf.appendSlice(self.allocator, ma);
        }
        const spec_name = try name_buf.toOwnedSlice(self.allocator);

        const fn_val = self.func_map.get(spec_name) orelse return null;

        const args = try self.allocator.alloc(types.LLVMValueRef, args_exprs.len + 1);
        defer self.allocator.free(args);
        args[0] = try self.compileCallArgument(fa.object.*);
        try self.guardOptionalDeref(fa.object, args[0], fa.span);

        for (args_exprs, 0..) |*arg, idx| {
            var val = try self.compileCallArgument(arg.*);
            if (idx + 1 < mdecl.params.len) {
                if (mdecl.params[idx + 1].type_name) |tr| {
                    const expected_type = try self.typeRefToString(tr);
                    if (self.traits.contains(getStructBaseName(expected_type))) {
                        if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                            if (self.structs.contains(struct_name)) {
                                val = try self.constructTraitObject(val, struct_name, expected_type);
                            }
                        }
                    }
                }
            }
            args[idx + 1] = val;
        }
        return try self.buildCallWithCasts(fn_val, args);
    }

    fn resolveParamTypeForWiden(self: *LlvmCompiler, obj_type_opt: ?[]const u8, expected_type: []const u8) []const u8 {
        const ot = obj_type_opt orelse return expected_type;
        if (std.mem.indexOfScalar(u8, ot, '<') == null) return expected_type;
        return self.substituteFieldType(ot, expected_type) catch expected_type;
    }

    pub fn buildTraitVtableCall(self: *LlvmCompiler, fa: ast.FieldAccess, m_idx: usize, args_exprs: []const ast.Expression) anyerror!types.LLVMValueRef {
        const trait_obj_ptr = try self.compileExpression(fa.object.*);
        const ptr_size = @as(u32, 8);

        const struct_ptr_ptr = core.LLVMBuildIntToPtr(self.builder, trait_obj_ptr, core.LLVMPointerType(self.val_type, 0), "trait_struct_ptr_ptr");
        const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, struct_ptr_ptr, "trait_struct_ptr");

        const vtable_addr = core.LLVMBuildAdd(self.builder, trait_obj_ptr, core.LLVMConstInt(self.val_type, ptr_size, 0), "vtable_addr");
        const vtable_ptr_ptr = core.LLVMBuildIntToPtr(self.builder, vtable_addr, core.LLVMPointerType(self.val_type, 0), "trait_vtable_ptr_ptr");
        const vtable_ptr_int = core.LLVMBuildLoad2(self.builder, self.val_type, vtable_ptr_ptr, "trait_vtable_ptr_int");

        const fn_offset = core.LLVMConstInt(self.val_type, (m_idx + 1) * self.ptrElemSize(), 0);
        const fn_addr = core.LLVMBuildAdd(self.builder, vtable_ptr_int, fn_offset, "fn_addr");
        const fn_ptr_ptr = core.LLVMBuildIntToPtr(self.builder, fn_addr, core.LLVMPointerType(self.ptr_type, 0), "fn_ptr_ptr");
        const fn_ptr = core.LLVMBuildLoad2(self.builder, self.ptr_type, fn_ptr_ptr, "fn_ptr");

        const total_args = args_exprs.len + 1;
        const params = try self.allocator.alloc(types.LLVMTypeRef, total_args);
        defer self.allocator.free(params);
        @memset(params, self.val_type);

        const fn_t = core.LLVMFunctionType(self.val_type, params.ptr, @intCast(total_args), 0);

        const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
        defer self.allocator.free(args);

        args[0] = struct_ptr;
        for (args_exprs, 0..) |arg, idx| {
            args[idx + 1] = try self.compileCallArgument(arg);
        }

        return core.LLVMBuildCall2(self.builder, fn_t, fn_ptr, args.ptr, @intCast(total_args), "trait_call");
    }

    pub fn compileMethodOrNamespacedCall(self: *LlvmCompiler, callee_fa: ast.FieldAccess, args_exprs: []const ast.Expression) anyerror!types.LLVMValueRef {
        const fa = callee_fa;
        var obj_type = try self.resolveExpressionTypeName(fa.object);

        if (fa.object.kind == .ident and !self.identNamesVariable(fa.object.kind.ident) and
            (self.enums.contains(fa.object.kind.ident) or self.structs.contains(fa.object.kind.ident)))
        {
            obj_type = null;
        }

        if (obj_type == null and fa.object.kind == .field_access) {
            const inner = fa.object.kind.field_access;
            if (self.isStructType(inner.field)) {
                obj_type = inner.field;
            }

            else if (inner.object.kind == .ident and self.enums.contains(inner.object.kind.ident)) {
                obj_type = inner.object.kind.ident;
            }
        }

        if (obj_type) |struct_name| {
            const base_struct = getStructBaseName(struct_name);
            if (std.mem.eql(u8, base_struct, "Atomic") and !std.mem.eql(u8, fa.field, "delete")) {
                return try self.compileAtomicCall(struct_name, fa.field, fa.object.*, args_exprs);
            }

        }

        if (fa.object.kind == .ident) {
            const obj_name = fa.object.kind.ident;
            if (self.enums.get(obj_name)) |enum_decl| {
                var is_variant = false;
                var variant_idx: usize = 0;
                for (enum_decl.variants, 0..) |v, vi| {
                    if (std.mem.eql(u8, v.name, fa.field)) {
                        is_variant = true;
                        variant_idx = vi;
                        break;
                    }
                }
                if (is_variant) {
                    const vdecl = enum_decl.variants[variant_idx];
                    var tag: u32 = 0;
                    var total_size: u32 = 0;
                    try self.getEnumTagAndSize(obj_name, fa.field, &tag, &total_size);

                    const union_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, total_size, 0));

                    const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                    _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                    const ptr_size = @as(u32, 8);
                    for (args_exprs, 0..) |arg, idx| {
                        const arg_val = try self.compileCallArgument(arg);

                        const ptref: ?ast.TypeRef = if (vdecl.type_name) |t|
                            t
                        else if (vdecl.fields) |flds|
                            (if (idx < flds.len) flds[idx].type_name else null)
                        else
                            null;
                        if (ptref) |pt| {
                            const pstr = try self.typeRefToString(pt);
                            if (self.isOwnedDeclaredType(pt, pstr)) {
                                const is_r_var = (arg.kind == .ident or arg.kind == .field_access or arg.kind == .index);
                                if (is_r_var) {
                                    try self.compileRetain(arg_val);
                                } else {
                                    self.consumeTemporary(arg_val);
                                }
                            }
                        }
                        const offset = core.LLVMConstInt(self.val_type, ptr_size + idx * ptr_size, 0);
                        const addr = core.LLVMBuildAdd(self.builder, union_ptr, offset, "payload_addr");
                        const dest_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                        _ = core.LLVMBuildStore(self.builder, arg_val, dest_ptr);
                    }

                    return union_ptr;
                }
            }
        }

        if (obj_type) |t_name_raw| {

            const t_name = getStructBaseName(t_name_raw);
            if (self.traits.contains(t_name)) {
                const trait_decl = self.traits.get(t_name).?;
                var method_idx: ?usize = null;
                for (trait_decl.methods, 0..) |tm, idx| {
                    if (std.mem.eql(u8, tm.name, fa.field)) {
                        method_idx = idx;
                        break;
                    }
                }

                if (method_idx) |m_idx| {
                    const call_res = try self.buildTraitVtableCall(fa, m_idx, args_exprs);

                    if (trait_decl.methods[m_idx].is_async) {
                        return try self.buildDriveAsyncHandle(call_res);
                    }
                    return call_res;
                }
            }
        }

        var is_method = false;
        var fn_val_opt: ?types.LLVMValueRef = null;

        if (obj_type) |struct_name| {
            const base_struct = getStructBaseName(struct_name);
            const method_name = fa.field;
            var is_static = false;
            if (self.structs.get(base_struct)) |s| {
                for (s.methods) |m| {
                    if (std.mem.eql(u8, m.decl.name, method_name)) {
                        is_static = m.is_static;
                        break;
                    }
                }
            } else if (self.enums.get(base_struct)) |e| {
                for (e.methods) |m| {
                    if (std.mem.eql(u8, m.decl.name, method_name)) {
                        is_static = m.is_static;
                        break;
                    }
                }
            }

            const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base_struct, method_name });
            defer self.allocator.free(full_name);

            const struct_name_lower = try self.allocator.alloc(u8, base_struct.len);
            defer self.allocator.free(struct_name_lower);
            _ = std.ascii.lowerString(struct_name_lower, base_struct);
            const full_name_lower = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name_lower, method_name });
            defer self.allocator.free(full_name_lower);

            const subst_struct = self.substTypeParams(struct_name) catch struct_name;
            defer if (subst_struct.ptr != struct_name.ptr) self.allocator.free(subst_struct);
            const mono_name = try self.methodSymbol(self.qualifySelfType(subst_struct), method_name);
            defer self.allocator.free(mono_name);

            var spec_name: ?[]const u8 = null;
            {
                const owner2 = self.qualifySelfType(subst_struct);
                var found: ?*const sema_mono.MethodInst = null;
                var count: usize = 0;
                for (sema_mono.method_insts.items) |*mi| {
                    if (std.mem.eql(u8, mi.inst_name, owner2) and std.mem.eql(u8, mi.method, method_name)) {
                        count += 1;
                        found = mi;
                    }
                }
                if (count == 1) {
                    var nb = std.ArrayListUnmanaged(u8).empty;
                    errdefer nb.deinit(self.allocator);
                    try nb.appendSlice(self.allocator, mono_name);
                    for (found.?.args) |an| {
                        const ma = try types_mod.mangleTypeName(self.allocator, an);
                        defer self.allocator.free(ma);
                        try nb.appendSlice(self.allocator, "__");
                        try nb.appendSlice(self.allocator, ma);
                    }
                    spec_name = try nb.toOwnedSlice(self.allocator);
                }
            }
            defer if (spec_name) |s| self.allocator.free(s);

            if (spec_name != null and self.func_map.get(spec_name.?) != null) {
                fn_val_opt = self.func_map.get(spec_name.?);
                is_method = !is_static;
            } else if (self.func_map.get(mono_name)) |val| {
                fn_val_opt = val;
                is_method = !is_static;
                if (sema_shadow.report_enabled and !std.mem.eql(u8, mono_name, full_name)) sema_shadow.f45_mono_hit += 1;
            } else if (self.func_map.get(full_name)) |val| {
                fn_val_opt = val;
                is_method = !is_static;

                if (sema_shadow.report_enabled) {
                    if (!std.mem.eql(u8, mono_name, full_name)) {
                        sema_shadow.f45_erased_fallback += 1;
                        sema_shadow.noteF45Erased(mono_name);
                    } else sema_shadow.f45_erased_nongeneric += 1;
                }
            } else if (self.func_map.get(full_name_lower)) |val| {
                fn_val_opt = val;
                is_method = !is_static;
            }
        }

        const obj_is_variable = fa.object.kind == .ident and self.identNamesVariable(fa.object.kind.ident);
        if (!is_method and fa.object.kind == .ident and !obj_is_variable) {
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fa.object.kind.ident, fa.field });
            defer self.allocator.free(full_name);

            var capitalized = try self.allocator.alloc(u8, fa.object.kind.ident.len);
            defer self.allocator.free(capitalized);
            @memcpy(capitalized, fa.object.kind.ident);
            if (capitalized.len > 0) {
                capitalized[0] = std.ascii.toUpper(capitalized[0]);
            }
            const cap_full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ capitalized, fa.field });
            defer self.allocator.free(cap_full_name);

            var resolved_name: ?[]const u8 = null;

            // Importer-relative resolution FIRST: a qualified call `mod.fn()` must bind to the
            // `mod` that THIS file imported, not to any same-named module elsewhere. The suffix
            // scan below is module-blind and picks the shortest matching key, so two packages
            // that both export e.g. `codec.buildSSLRequest` would collide (the shorter package
            // path wins, silently calling the wrong one with mismatched arity). Ask the symbol
            // table which module `mod` resolves to for the importing file, then take that
            // function's exact mangled name.
            if (sema_shadow.live_sema) |sm| {
                if (sm.tab.findModuleByImportNameForImporter(fa.object.kind.ident, fa.span.file)) |mid| {
                    if (sm.tab.findFunctionIn(mid, fa.field)) |sid| {
                        const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                        if (self.func_map.contains(legacy)) resolved_name = legacy;
                    }
                }
            }

            if (resolved_name != null) {
                // already bound importer-relative
            } else if (self.func_map.get(full_name)) |_| {
                resolved_name = full_name;
            } else if (self.func_map.get(cap_full_name)) |_| {
                resolved_name = cap_full_name;
            } else {
                // `full_name` is the partly-qualified "<alias>_<field>" (e.g. "url_parse"); its fully
                // mangled key is "net_url_parse". Several functions can share that trailing segment --
                // "net_url_parse" and "net_url_test_url_parse" both end in "_url_parse" -- so taking the
                // FIRST hashmap key that ends in it is ambiguous AND order-dependent: adding modules
                // reorders the map and silently rebinds `url.parse` to `url.test_url_parse`. Pick the
                // SHORTEST matching key deterministically (the most-direct match, fewest extra prefix
                // segments). Try full_name first, then the capitalized variant.
                var best_len: usize = std.math.maxInt(usize);
                var iter = self.func_map.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const suffix_len = full_name.len + 1;
                    if (key.len >= suffix_len) {
                        const suffix = key[key.len - suffix_len..];
                        if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], full_name) and key.len < best_len) {
                            best_len = key.len;
                            resolved_name = key;
                        }
                    }
                }
                if (resolved_name == null) {
                    best_len = std.math.maxInt(usize);
                    iter = self.func_map.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const suffix_len = cap_full_name.len + 1;
                        if (key.len >= suffix_len) {
                            const suffix = key[key.len - suffix_len..];
                            if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], cap_full_name) and key.len < best_len) {
                                best_len = key.len;
                                resolved_name = key;
                            }
                        }
                    }
                }
            }

            if (resolved_name) |r_name| {
                fn_val_opt = self.func_map.get(r_name);
            } else if (self.func_map.get(fa.field)) |val| {
                fn_val_opt = val;
            }
        }

        var is_constructor_call = false;
        var base_struct_name: []const u8 = "";
        if (obj_type == null and fa.object.kind == .ident) {
            if (self.isStructType(fa.field)) {
                is_constructor_call = true;
                base_struct_name = fa.field;
                const init_name = try std.fmt.allocPrint(self.allocator, "{s}_init", .{fa.field});
                defer self.allocator.free(init_name);
                const new_name = try std.fmt.allocPrint(self.allocator, "{s}_new", .{fa.field});
                defer self.allocator.free(new_name);
                fn_val_opt = self.func_map.get(init_name) orelse self.func_map.get(new_name);
            }
        }

        if (is_constructor_call) {
            const struct_size = self.getTypeSize(ast.TypeRef{ .ident = base_struct_name }, false);
            const instance_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

            if (fn_val_opt) |fn_val| {
                const func_name = std.mem.span(core.LLVMGetValueName(fn_val));
                const total_args = args_exprs.len + 1;
                const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                defer self.allocator.free(args);

                args[0] = instance_ptr;
                for (args_exprs, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(func_name, idx + 1)) |expected_type| {
                        const widen_to = self.resolveParamTypeForWiden(obj_type, expected_type);
                        if (self.traits.contains(getStructBaseName(widen_to))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, widen_to);
                                }
                            }
                        }

                    }
                    args[idx + 1] = val;
                }

                _ = try self.buildCallWithCasts(fn_val, args);
            }
            return instance_ptr;
        }

        if (fn_val_opt) |fn_val| {
            const func_name = std.mem.span(core.LLVMGetValueName(fn_val));
            var base_struct = getStructBaseName(obj_type orelse "");
            if (base_struct.len == 0 and fa.object.kind == .ident) {
                if (self.isStructType(fa.object.kind.ident)) {
                    base_struct = fa.object.kind.ident;
                }
            }
            const is_new_call = (std.mem.endsWith(u8, func_name, "_new") or std.mem.endsWith(u8, func_name, "_init")) and self.isStructType(base_struct);

            if (is_new_call) {
                const struct_size = self.getTypeSize(ast.TypeRef{ .ident = base_struct }, false);
                const instance_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, struct_size, 0));

                const total_args = args_exprs.len + 1;
                const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
                defer self.allocator.free(args);

                args[0] = instance_ptr;
                for (args_exprs, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(func_name, idx + 1)) |expected_type| {
                        const widen_to = self.resolveParamTypeForWiden(obj_type, expected_type);
                        if (self.traits.contains(getStructBaseName(widen_to))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, widen_to);
                                }
                            }
                        }

                    }
                    args[idx + 1] = val;
                }

                _ = try self.buildCallWithCasts(fn_val, args);
                return instance_ptr;
            }

            const total_args = if (is_method) args_exprs.len + 1 else args_exprs.len;
            const args = try self.allocator.alloc(types.LLVMValueRef, total_args);
            defer self.allocator.free(args);

            if (is_method) {
                args[0] = try self.compileCallArgument(fa.object.*);

                try self.guardOptionalDeref(fa.object, args[0], fa.span);
                for (args_exprs, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(func_name, idx + 1)) |expected_type| {
                        const widen_to = self.resolveParamTypeForWiden(obj_type, expected_type);
                        if (self.traits.contains(getStructBaseName(widen_to))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, widen_to);
                                }
                            }
                        }
                    }
                    // Box a plain value being inserted into a value-optional element slot (`List<int |
                    // undefined>.push(7)`), so the slot holds a box a later read can unbox rather than a
                    // raw value it would dereference as a pointer. `undefined` stays 0 (a box holding 0
                    // would read back as a present 0); an already-boxed value-optional is left as-is.
                    if (!LlvmCompiler.isUndefinedLiteralExpr(arg) and !self.exprYieldsValoptBox(arg) and
                        self.methodParamIsValueOptional(fa.object, fa.field, idx))
                    {
                        val = try self.buildValoptBox(self.coerceToSlotType(val, self.val_type));
                    }
                    args[idx + 1] = val;
                }
            } else {
                for (args_exprs, 0..) |*arg, idx| {
                    var val = try self.compileCallArgument(arg.*);
                    if (self.getFunctionParamType(func_name, idx)) |expected_type| {
                        const widen_to = self.resolveParamTypeForWiden(obj_type, expected_type);
                        if (self.traits.contains(getStructBaseName(widen_to))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(struct_name)) {
                                    val = try self.constructTraitObject(val, struct_name, widen_to);
                                }
                            }
                        }

                    }
                    args[idx] = val;
                }
            }

            if (self.async_fns.contains(func_name)) {
                return try self.buildDriveAsyncCall(fn_val, args);
            }

            return try self.buildCallWithCasts(fn_val, args);
        }

        if (obj_type) |struct_name| {
            if (self.isStructType(struct_name)) {
                const base_struct = getStructBaseName(struct_name);
                var field_exists = false;
                if (self.structs.get(base_struct)) |s| {
                    for (s.fields) |field| {
                        if (std.mem.eql(u8, field.name, fa.field)) {
                            field_exists = true;
                            break;
                        }
                    }
                }
                if (field_exists) {

                    const field_val = try self.compileExpression(.{ .kind = .{ .field_access = fa } });
                    return try self.buildClosureCall(field_val, args_exprs);
                }
            }
        }

        const recv: []const u8 = switch (fa.object.kind) {
            .ident => |n| n,
            else => "value",
        };
        if (fa.span.line > 0) {
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m no method or function '{s}' on '{s}'\x1b[0m — check the name and that it is `pub`.\n",
                .{ fa.span.file, fa.span.line, fa.span.col, fa.field, recv },
            );
        }
        return error.MethodOrFunctionNotFound;
    }

    fn isVoidExpression(self: *LlvmCompiler, expr: ast.Expression) bool {
        var callee_expr: *ast.Expression = undefined;
        switch (expr.kind) {
            .call => |call| callee_expr = call.callee,
            .generic_call => |gc| callee_expr = gc.callee,
            else => return false,
        }

        if (callee_expr.kind == .field_access) {
            const fa = callee_expr.kind.field_access;
            if (std.mem.eql(u8, fa.field, "log") and fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "console")) return true;
            if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "router")) {
                if (std.mem.eql(u8, fa.field, "register")) return true;
            }
            if (fa.object.kind == .ident and std.mem.eql(u8, fa.object.kind.ident, "bytes")) {
                if (std.mem.startsWith(u8, fa.field, "write")) return true;
            }
            if (std.mem.eql(u8, fa.field, "push") or
                std.mem.eql(u8, fa.field, "set") or
                std.mem.eql(u8, fa.field, "forEach") or
                std.mem.eql(u8, fa.field, "add") or
                std.mem.eql(u8, fa.field, "insert")) return true;
            var full_name: ?[]const u8 = null;
            var full_name_lower: ?[]const u8 = null;
            if (self.resolveExpressionTypeName(fa.object) catch null) |struct_name| {
                full_name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name, fa.field }) catch null;
                const struct_name_lower = self.allocator.alloc(u8, struct_name.len) catch return false;
                _ = std.ascii.lowerString(struct_name_lower, struct_name);
                full_name_lower = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name_lower, fa.field }) catch null;
            } else if (fa.object.kind == .ident) {
                full_name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fa.object.kind.ident, fa.field }) catch null;
            }
            if (full_name) |name| {
                defer self.allocator.free(name);
                if (full_name_lower) |name_lower| {
                    defer self.allocator.free(name_lower);
                    for (self.functions.items) |f| {
                        if (std.mem.eql(u8, f.name, name) or std.mem.eql(u8, f.name, name_lower)) {
                            return std.mem.eql(u8, f.return_type, "void");
                        }
                    }
                } else {
                    for (self.functions.items) |f| {
                        if (std.mem.eql(u8, f.name, name)) {
                            return std.mem.eql(u8, f.return_type, "void");
                        }
                    }
                }
            }
        }
        if (callee_expr.kind == .ident) {
            const callee_name = callee_expr.kind.ident;
            const resolved_name = self.resolveCalleeName(callee_name) catch callee_name;
            for (self.functions.items) |f| {
                if (std.mem.eql(u8, f.name, resolved_name)) {
                    return std.mem.eql(u8, f.return_type, "void");
                }
            }
        }
        return false;
    }

    pub fn collectClosuresFromBlock(self: *LlvmCompiler, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectClosuresFromStatement(stmt);
        }
    }

    fn collectClosuresFromStatement(self: *LlvmCompiler, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .block => |b| try self.collectClosuresFromBlock(b),
            .let_stmt => |ls| if (ls.init) |init| try self.collectClosuresFromExpr(init),
            .expr_stmt => |es| try self.collectClosuresFromExpr(es.expr),
            .if_stmt => |is| {
                try self.collectClosuresFromExpr(is.condition);
                try self.collectClosuresFromStatement(is.then_branch.*);
                if (is.else_branch) |eb| try self.collectClosuresFromStatement(eb.*);
            },
            .while_stmt => |ws| {
                try self.collectClosuresFromExpr(ws.condition);
                try self.collectClosuresFromStatement(ws.body.*);
            },
            .for_stmt => |fs| {
                if (fs.initializer) |init| try self.collectClosuresFromStatement(init.*);
                if (fs.condition) |c| try self.collectClosuresFromExpr(c);
                if (fs.increment) |inc| try self.collectClosuresFromExpr(inc);
                try self.collectClosuresFromStatement(fs.body.*);
            },
            .return_stmt => |rs| if (rs.value) |val| try self.collectClosuresFromExpr(val),
            .defer_stmt => |ds| try self.collectClosuresFromExpr(ds.expr),
            .switch_stmt => |ss| {
                try self.collectClosuresFromExpr(ss.discriminant);
                for (ss.cases) |case| {
                    for (case.values) |val| {
                        try self.collectClosuresFromExpr(val);
                    }
                    try self.collectClosuresFromStatement(case.body.*);
                }
                if (ss.default_case) |dc| {
                    try self.collectClosuresFromStatement(dc.*);
                }
            },
            else => {},
        }
    }

        fn hasReturnStatement(stmt: ast.Statement) bool {
        switch (stmt) {
            .block => |b| {
                for (b.statements) |s| {
                    if (hasReturnStatement(s)) return true;
                }
                return false;
            },
            .return_stmt => return true,
            .if_stmt => |is| {
                if (hasReturnStatement(is.then_branch.*)) return true;
                if (is.else_branch) |eb| {
                    if (hasReturnStatement(eb.*)) return true;
                }
                return false;
            },
            .while_stmt => |ws| return hasReturnStatement(ws.body.*),
            .for_stmt => |fs| return hasReturnStatement(fs.body.*),
            .switch_stmt => |ss| {
                for (ss.cases) |c| {
                    if (hasReturnStatement(c.body.*)) return true;
                }
                if (ss.default_case) |dc| {
                    if (hasReturnStatement(dc.*)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn collectClosuresFromExpr(self: *LlvmCompiler, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .closure => |cl| {
                switch (cl.body) {
                    .block => |b| try self.collectClosuresFromBlock(b),
                    .expr => |e| try self.collectClosuresFromExpr(e.*),
                }

                var is_void_lambda = false;
                switch (cl.body) {
                    .expr => |e| {
                        if (self.isVoidExpression(e.*)) {
                            is_void_lambda = true;
                        }
                    },
                    .block => |b| {
                        var has_return = false;
                        for (b.statements) |s| {
                            if (hasReturnStatement(s)) {
                                has_return = true;
                                break;
                            }
                        }
                        if (!has_return) is_void_lambda = true;
                    },
                }

                const body_block = switch (cl.body) {
                    .block => |b| b,
                    .expr => |e| blk: {
                        if (is_void_lambda) {
                            const statements = try self.allocator.alloc(ast.Statement, 1);
                            statements[0] = ast.Statement{ .expr_stmt = ast.ExprStmt{
                                .expr = e.*,
                                .span = cl.span,
                            } };
                            break :blk ast.Block{
                                .statements = statements,
                                .span = cl.span,
                            };
                        } else {
                            const statements = try self.allocator.alloc(ast.Statement, 1);
                            statements[0] = ast.Statement{ .return_stmt = ast.ReturnStmt{
                                .value = e.*,
                                .span = cl.span,
                            } };
                            break :blk ast.Block{
                                .statements = statements,
                                .span = cl.span,
                            };
                        }
                    },
                };

                var lambda_return_type: []const u8 = if (is_void_lambda) (if (self.is_wasm) "i32" else "void") else "i32";

                if (!is_void_lambda) {
                    if (self.typed_ir) |ir| {
                        if (self.type_store) |st| {
                            if (ir.typeOf(&expr)) |tid| {
                                const info = st.get(tid);
                                if (info == .func and st.get(info.func.ret) == .trait_) {
                                    if (sema_shadow.renderLegacy(self.allocator, st, info.func.ret)) |tn| {
                                        lambda_return_type = tn;
                                    } else |_| {}
                                }
                            }
                        }
                    }
                }

                const lambda_name = try std.fmt.allocPrint(self.allocator, "__lambda_{d}", .{self.next_lambda_id});
                self.next_lambda_id += 1;

                const param_names = try self.allocator.alloc([]const u8, cl.params.len + 1);
                param_names[0] = "__env";
                for (cl.params, 0..) |p, i| {
                    param_names[i + 1] = p;
                }

                if (cl.param_types.len > 0) {
                    const decl_types = try self.allocator.alloc(?[]const u8, cl.params.len);
                    for (cl.params, 0..) |_, i| {
                        decl_types[i] = if (i < cl.param_types.len)
                            (if (cl.param_types[i]) |t| (self.typeRefToString(t) catch null) else null)
                        else
                            null;
                    }
                    try self.lambda_param_types.put(lambda_name, decl_types);
                }

                const info = FunctionInfo{
                    .name = lambda_name,
                    .param_count = cl.params.len + 1,
                    .param_names = param_names,
                    .return_type = lambda_return_type,
                    .body = body_block,

                    .instantiation = self.current_collecting_instantiation,

                    .method_subst = self.current_collecting_method_subst,

                    .erased_generic = self.current_collecting_erased_generic,
                    .source_file = cl.span.file,
                };                try self.functions.append(self.allocator, info);
                const ckey = try self.closureKey(cl.span, self.current_collecting_instantiation);
                try self.closure_lambdas.put(self.allocator, ckey, lambda_name);

                if (!self.lambda_captures.contains(lambda_name)) {
                    try self.lambda_captures.put(lambda_name, .empty);
                }
                if (self.current_collecting_function_name) |parent| {
                    try self.lambda_parents.put(lambda_name, parent);

                    var lambda_params = std.StringHashMap(void).init(self.allocator);
                    defer lambda_params.deinit();
                    for (cl.params) |p| {
                        try lambda_params.put(p, {});
                    }

                    var lambda_locals = std.StringHashMap(void).init(self.allocator);
                    defer lambda_locals.deinit();

                    const prev_scanning = self.current_scanning_lambda;
                    self.current_scanning_lambda = lambda_name;
                    defer self.current_scanning_lambda = prev_scanning;

                    switch (cl.body) {
                        .block => |b| try self.scanStatementCaptures(ast.Statement{ .block = b }, parent, lambda_params, &lambda_locals),
                        .expr => |e| try self.scanExprCaptures(e.*, parent, lambda_params, &lambda_locals),
                    }
                }
            },
            .call => |call| {
                try self.collectClosuresFromExpr(call.callee.*);
                for (call.args) |arg| try self.collectClosuresFromExpr(arg);
            },
            .generic_call => |gc| {
                try self.collectClosuresFromExpr(gc.callee.*);
                for (gc.args) |arg| try self.collectClosuresFromExpr(arg);
            },
            .binary => |bin| {
                try self.collectClosuresFromExpr(bin.left.*);
                try self.collectClosuresFromExpr(bin.right.*);
            },
            .unary => |uni| try self.collectClosuresFromExpr(uni.operand.*),
            .field_access => |fa| try self.collectClosuresFromExpr(fa.object.*),
            .index => |idx| {
                try self.collectClosuresFromExpr(idx.object.*);
                try self.collectClosuresFromExpr(idx.index.*);
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.collectClosuresFromExpr(field.value);
            },
            .tuple => |tuple_exprs| {
                for (tuple_exprs) |te| try self.collectClosuresFromExpr(te);
            },
            .if_expr => |ie| {
                try self.collectClosuresFromExpr(ie.condition.*);
                try self.collectClosuresFromExpr(ie.then_branch.*);
                try self.collectClosuresFromExpr(ie.else_branch.*);
            },
            .template_expr => |te| {
                for (te.parts) |p| try self.collectClosuresFromExpr(p);
            },
            .block_expr => |be| {
                try self.collectClosuresFromBlock(be);
            },

            .nullish_coalesce => |nc| {
                try self.collectClosuresFromExpr(nc.left.*);
                try self.collectClosuresFromExpr(nc.right.*);
            },

            .cast => |c| try self.collectClosuresFromExpr(c.expr.*),
            else => {},
        }
    }

    fn scanStatementCaptures(self: *LlvmCompiler, stmt: ast.Statement, parent_name: []const u8, lambda_params: std.StringHashMap(void), lambda_locals: *std.StringHashMap(void)) anyerror!void {
        switch (stmt) {
            .block => |b| {
                for (b.statements) |s| {
                    try self.scanStatementCaptures(s, parent_name, lambda_params, lambda_locals);
                }
            },
            .let_stmt => |ls| {
                try lambda_locals.put(ls.name, {});
                if (ls.init) |init| {
                    try self.scanExprCaptures(init, parent_name, lambda_params, lambda_locals);
                }
            },
            .expr_stmt => |es| try self.scanExprCaptures(es.expr, parent_name, lambda_params, lambda_locals),
            .if_stmt => |is| {
                try self.scanExprCaptures(is.condition, parent_name, lambda_params, lambda_locals);
                try self.scanStatementCaptures(is.then_branch.*, parent_name, lambda_params, lambda_locals);
                if (is.else_branch) |eb| {
                    try self.scanStatementCaptures(eb.*, parent_name, lambda_params, lambda_locals);
                }
            },
            .while_stmt => |ws| {
                try self.scanExprCaptures(ws.condition, parent_name, lambda_params, lambda_locals);
                try self.scanStatementCaptures(ws.body.*, parent_name, lambda_params, lambda_locals);
            },
            .for_stmt => |fs| {
                if (fs.initializer) |init| {
                    try self.scanStatementCaptures(init.*, parent_name, lambda_params, lambda_locals);
                }
                if (fs.condition) |c| {
                    try self.scanExprCaptures(c, parent_name, lambda_params, lambda_locals);
                }
                if (fs.increment) |inc| {
                    try self.scanExprCaptures(inc, parent_name, lambda_params, lambda_locals);
                }
                try self.scanStatementCaptures(fs.body.*, parent_name, lambda_params, lambda_locals);
            },
            .return_stmt => |rs| {
                if (rs.value) |val| {
                    try self.scanExprCaptures(val, parent_name, lambda_params, lambda_locals);
                }
            },
            .defer_stmt => |ds| {
                try self.scanExprCaptures(ds.expr, parent_name, lambda_params, lambda_locals);
            },
            .switch_stmt => |ss| {
                try self.scanExprCaptures(ss.discriminant, parent_name, lambda_params, lambda_locals);
                for (ss.cases) |c| {
                    for (c.values) |val| {
                        try self.scanExprCaptures(val, parent_name, lambda_params, lambda_locals);
                    }
                    try self.scanStatementCaptures(c.body.*, parent_name, lambda_params, lambda_locals);
                }
                if (ss.default_case) |dc| {
                    try self.scanStatementCaptures(dc.*, parent_name, lambda_params, lambda_locals);
                }
            },
            else => {},
        }
    }

    fn isNamespaceReceiver(self: *LlvmCompiler, obj_name: []const u8, member: []const u8) bool {

        if (self.structs.contains(member)) return true;
        if (self.enums.contains(member)) return true;

        if (std.mem.eql(u8, obj_name, "console") or std.mem.eql(u8, obj_name, "bytes")) return true;

        if (std.mem.eql(u8, obj_name, "serde")) return true;

        if (self.structs.contains(obj_name)) return true;
        if (self.enums.contains(obj_name)) return true;

        const flat = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj_name, member }) catch return false;
        defer self.allocator.free(flat);
        const suffix = std.fmt.allocPrint(self.allocator, "_{s}_{s}", .{ obj_name, member }) catch return false;
        defer self.allocator.free(suffix);
        for (self.functions.items) |f| {
            if (std.mem.eql(u8, f.name, flat)) return true;
            if (std.mem.endsWith(u8, f.name, suffix)) return true;
        }
        return false;
    }

    fn scanExprCaptures(self: *LlvmCompiler, expr: ast.Expression, parent_name: []const u8, lambda_params: std.StringHashMap(void), lambda_locals: *std.StringHashMap(void)) anyerror!void {
        switch (expr.kind) {
            .ident => |name| {
                if (std.mem.eql(u8, name, "self")) return;

                if (std.mem.eql(u8, name, "console") or std.mem.eql(u8, name, "bytes")) return;
                if (lambda_params.contains(name)) return;
                if (lambda_locals.contains(name)) return;
                if (self.constants.contains(name)) return;

                for (self.functions.items) |f| {
                    if (std.mem.eql(u8, f.name, name)) return;

                    const suffix = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});
                    defer self.allocator.free(suffix);
                    if (std.mem.endsWith(u8, f.name, suffix)) return;
                }

                if (self.structs.contains(name)) return;
                if (self.enums.contains(name)) return;

                if (self.current_scanning_lambda) |lam| {
                    if (self.lambda_captures.getPtr(lam)) |caps| {
                        var already = false;
                        for (caps.items) |c| {
                            if (std.mem.eql(u8, c, name)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) try caps.append(self.allocator, name);
                    }
                }
            },
            .call => |call| {
                try self.scanExprCaptures(call.callee.*, parent_name, lambda_params, lambda_locals);
                for (call.args) |arg| {
                    try self.scanExprCaptures(arg, parent_name, lambda_params, lambda_locals);
                }
            },
            .generic_call => |gc| {
                try self.scanExprCaptures(gc.callee.*, parent_name, lambda_params, lambda_locals);
                for (gc.args) |arg| {
                    try self.scanExprCaptures(arg, parent_name, lambda_params, lambda_locals);
                }
            },
            .binary => |bin| {
                try self.scanExprCaptures(bin.left.*, parent_name, lambda_params, lambda_locals);
                try self.scanExprCaptures(bin.right.*, parent_name, lambda_params, lambda_locals);
            },
            .unary => |uni| {
                try self.scanExprCaptures(uni.operand.*, parent_name, lambda_params, lambda_locals);
            },
            .field_access => |fa| {

                if (fa.object.kind == .ident and self.isNamespaceReceiver(fa.object.kind.ident, fa.field)) {
                    return;
                }
                try self.scanExprCaptures(fa.object.*, parent_name, lambda_params, lambda_locals);
            },
            .index => |idx| {
                try self.scanExprCaptures(idx.object.*, parent_name, lambda_params, lambda_locals);
                try self.scanExprCaptures(idx.index.*, parent_name, lambda_params, lambda_locals);
            },
            .struct_init => |si| {
                for (si.fields) |field| {
                    try self.scanExprCaptures(field.value, parent_name, lambda_params, lambda_locals);
                }
            },
            .tuple => |tuple_exprs| {
                for (tuple_exprs) |te| {
                    try self.scanExprCaptures(te, parent_name, lambda_params, lambda_locals);
                }
            },
            .nullish_coalesce => |nc| {
                try self.scanExprCaptures(nc.left.*, parent_name, lambda_params, lambda_locals);
                try self.scanExprCaptures(nc.right.*, parent_name, lambda_params, lambda_locals);
            },
            .template_expr => |te| {
                for (te.parts) |p| try self.scanExprCaptures(p, parent_name, lambda_params, lambda_locals);
            },
            .block_expr => |be| {
                try self.scanStatementCaptures(ast.Statement{ .block = be }, parent_name, lambda_params, lambda_locals);
            },
            else => {},
        }
    }

    pub fn getModulePrefix(self: *LlvmCompiler, span: ast.Span) ?[]const u8 {

        if (span.file.len == 0 or std.mem.eql(u8, span.file, self.program.span.file) or std.mem.eql(u8, span.file, "helpers.nova") or std.mem.eql(u8, span.file, "test_harness.nova") or std.mem.eql(u8, span.file, "<serde-generated>")) {
            return null;
        }

        var path = span.file;
        const std_roots = [_][]const u8{ "src/std/", "src/lib/", ".nova/std/", ".nova/lib/" };
        for (std_roots) |root| {
            if (std.mem.indexOf(u8, path, root)) |pos| {
                path = path[pos + root.len ..];
                break;
            }
        }
        const ext_pos = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
        const base_path = path[0..ext_pos];
        var prefix = self.allocator.alloc(u8, base_path.len) catch return null;
        @memcpy(prefix, base_path);
        for (prefix, 0..) |char, idx| {
            // Convert '.' as well as path separators so a package/relative path prefix
            // (e.g. "../packages/nova-mysql/src/codec") becomes a dot-free identifier. A
            // leftover '.' would (a) desync this emit name from the symbol table's
            // legacy_mangled (which converts dots), breaking importer-relative qualified
            // call resolution, and (b) make getStructBaseName truncate the name at that dot.
            if (char == '/' or char == '\\' or char == '.') {
                prefix[idx] = '_';
            }
        }
        return prefix;
    }

    pub fn hasFunction(self: *LlvmCompiler, name: []const u8) bool {
        if (self.func_map.contains(name)) return true;
        for (self.functions.items) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    pub const resolveCalleeName = types_mod.resolveCalleeName;

    pub const typeRefToString = types_mod.typeRefToString;

    pub fn collectFunctions(self: *LlvmCompiler, program: ast.Program) !void {

        for (program.declarations) |decl| {
            if (decl == .struct_decl) {
                const s = decl.struct_decl;

                try self.structs.put(self.scopedStructName(s.name, s.span.file), s);
                for (s.methods) |method| {
                    const fn_decl = method.decl;
                    const is_constructor = std.mem.eql(u8, fn_decl.name, "new") or std.mem.eql(u8, fn_decl.name, "init");
                    const param_names = try self.allocator.alloc([]const u8, if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len);
                    if (is_constructor) {
                        param_names[0] = "self";
                        for (fn_decl.params, 0..) |p, i| {
                            param_names[i + 1] = p.name;
                        }
                    } else {
                        for (fn_decl.params, 0..) |p, i| {
                            param_names[i] = p.name;
                        }
                    }

                    for (try self.instantiationsOf(s)) |inst_opt| {

                        const owner = inst_opt orelse self.scopedStructName(s.name, s.span.file);
                        const full_name = try self.methodSymbol(owner, fn_decl.name);

                        const prev_inst = self.current_instantiation;
                        self.current_instantiation = inst_opt;
                        defer self.current_instantiation = prev_inst;

                        if (fn_decl.type_params.len > 0) {
                            for (sema_mono.method_insts.items) |mi| {
                                if (!std.mem.eql(u8, mi.inst_name, owner)) continue;
                                if (!std.mem.eql(u8, mi.method, fn_decl.name)) continue;
                                if (mi.params.len != fn_decl.type_params.len) continue;

                                const subst = try self.allocator.alloc(MethodParamBinding, mi.params.len);
                                for (mi.params, mi.args, 0..) |pn, an, i| {
                                    subst[i] = .{ .name = pn, .concrete = an };
                                }

                                var name_buf = std.ArrayListUnmanaged(u8).empty;
                                try name_buf.appendSlice(self.allocator, full_name);
                                for (mi.args) |an| {
                                    const ma = try types_mod.mangleTypeName(self.allocator, an);
                                    defer self.allocator.free(ma);
                                    try name_buf.appendSlice(self.allocator, "__");
                                    try name_buf.appendSlice(self.allocator, ma);
                                }
                                const spec_name = try name_buf.toOwnedSlice(self.allocator);

                                const prev_ms = self.current_method_subst;
                                self.current_method_subst = subst;
                                const spec_ret = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void";
                                self.current_method_subst = prev_ms;

                                try self.functions.append(self.allocator, .{
                                    .name = spec_name,
                                    .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                                    .param_names = param_names,
                                    .return_type = spec_ret,

                                    .ret_type_ref = fn_decl.ret_type,
                                    .body = fn_decl.body,
                                    .is_async = fn_decl.is_async,
                                    .instantiation = inst_opt,
                                    .method_subst = subst,
                                    .source_file = fn_decl.span.file,
                                });
                            }
                        }

                        const skip_base = fn_decl.type_params.len > 0 and !sema_mono.baseIsNeeded(owner, fn_decl.name);
                        if (!skip_base) {
                            const info = FunctionInfo{
                                .name = full_name,
                                .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                                .param_names = param_names,
                                .return_type = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void",
                                .ret_type_ref = fn_decl.ret_type,
                                .body = fn_decl.body,
                                .is_async = fn_decl.is_async,
                                .instantiation = inst_opt,

                                .erased_generic = (inst_opt == null and s.type_params.len > 0) or fn_decl.type_params.len > 0,
                                .source_file = fn_decl.span.file,
                            };
                            try self.functions.append(self.allocator, info);
                        }
                    }
                }
            } else if (decl == .enum_decl) {
                const e = decl.enum_decl;
                try self.enums.put(e.name, e);
                for (e.methods) |method| {
                    const fn_decl = method.decl;
                    const is_constructor = std.mem.eql(u8, fn_decl.name, "new") or std.mem.eql(u8, fn_decl.name, "init");
                    const param_names = try self.allocator.alloc([]const u8, if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len);
                    if (is_constructor) {
                        param_names[0] = "self";
                        for (fn_decl.params, 0..) |p, i| {
                            param_names[i + 1] = p.name;
                        }
                    } else {
                        for (fn_decl.params, 0..) |p, i| {
                            param_names[i] = p.name;
                        }
                    }

                    const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ e.name, fn_decl.name });
                    const info = FunctionInfo{
                        .name = full_name,
                        .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                        .param_names = param_names,
                        .return_type = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void",
                        .ret_type_ref = fn_decl.ret_type,
                        .body = fn_decl.body,
                        .is_async = fn_decl.is_async,
                        .source_file = fn_decl.span.file,
                    };
                    try self.functions.append(self.allocator, info);
                }
            } else if (decl == .union_decl) {
                const u = decl.union_decl;
                try self.unions.put(u.name, u);
            }
        }

        // B2: transitively discover free-generic instances reached only through another generic. If
        // `outer<int>` is instantiated and its body calls `inner<T>(x)`, `inner<int>` must be emitted
        // too. sema registers the direct calls; this closes over the type-parameter-forwarding chain.
        // Purely additive (worst case: an instance is missed and the same loud compile error as before
        // results), so it cannot introduce a miscompile.
        try self.expandFreeFnInstsTransitively(program);

        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                const fn_decl = decl.fn_decl;

                if (fn_decl.extern_lib != null) continue;
                const param_names = try self.allocator.alloc([]const u8, fn_decl.params.len);
                for (fn_decl.params, 0..) |p, i| {
                    param_names[i] = p.name;
                }

                var name = fn_decl.name;
                if (self.getStructPrefix(fn_decl)) |prefix| {
                    name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, fn_decl.name });
                } else if (self.getModulePrefix(fn_decl.span)) |mod_prefix| {
                    if (LlvmCompiler.isAlreadyNamespaced(fn_decl.name)) {
                        name = fn_decl.name;
                    } else {
                        name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, fn_decl.name });
                    }
                }

                const info = FunctionInfo{
                    .name = name,
                    .param_count = fn_decl.params.len,
                    .param_names = param_names,
                    .return_type = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void",
                    .ret_type_ref = fn_decl.ret_type,
                    .body = fn_decl.body,
                    .is_async = fn_decl.is_async,
                    .source_file = fn_decl.span.file,
                };

                if (fn_decl.type_params.len == 0 or fn_decl.is_async) try self.functions.append(self.allocator, info);

                if (fn_decl.type_params.len > 0) {
                    for (sema_mono.free_fn_insts.items) |fi| {
                        if (!std.mem.eql(u8, fi.fn_name, fn_decl.name)) continue;
                        if (fi.params.len != fn_decl.type_params.len) continue;

                        const subst = try self.allocator.alloc(MethodParamBinding, fi.params.len);
                        for (fi.params, fi.args, 0..) |pn, an, i| {
                            subst[i] = .{ .name = pn, .concrete = an };
                        }

                        var nb = std.ArrayListUnmanaged(u8).empty;
                        try nb.appendSlice(self.allocator, name);
                        for (fi.args) |an| {
                            const ma = try types_mod.mangleTypeName(self.allocator, an);
                            defer self.allocator.free(ma);
                            try nb.appendSlice(self.allocator, "__");
                            try nb.appendSlice(self.allocator, ma);
                        }
                        const spec_name = try nb.toOwnedSlice(self.allocator);

                        const spec_params = try self.allocator.alloc([]const u8, fn_decl.params.len);
                        for (fn_decl.params, 0..) |p, i| spec_params[i] = p.name;

                        const prev_ms = self.current_method_subst;
                        self.current_method_subst = subst;
                        const spec_ret = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void";
                        self.current_method_subst = prev_ms;

                        try self.functions.append(self.allocator, .{
                            .name = spec_name,
                            .param_count = fn_decl.params.len,
                            .param_names = spec_params,
                            .return_type = spec_ret,
                            .ret_type_ref = fn_decl.ret_type,
                            .body = fn_decl.body,
                            .is_async = fn_decl.is_async,
                            .method_subst = subst,
                            .source_file = fn_decl.span.file,
                        });
                    }
                }
            }
        }
    }

    // Fixpoint over sema_mono.free_fn_insts: for each generic free-fn instance, walk its body under
    // that instance's type-parameter binding and register any generic free-fn it calls with concrete
    // (substituted) type arguments. Handles explicit `inner<T>(x)` where T is forwarded from the
    // enclosing generic. Additive only.
    pub fn expandFreeFnInstsTransitively(self: *LlvmCompiler, program: ast.Program) !void {
        var gmap = std.StringHashMap(ast.FunctionDecl).init(self.allocator);
        defer gmap.deinit();
        for (program.declarations) |decl| {
            if (decl == .fn_decl and decl.fn_decl.type_params.len > 0 and decl.fn_decl.extern_lib == null) {
                try gmap.put(decl.fn_decl.name, decl.fn_decl);
            }
        }
        if (gmap.count() == 0) return;

        var guard: usize = 0;
        var changed = true;
        while (changed and guard < 100000) : (guard += 1) {
            changed = false;
            const n = sema_mono.free_fn_insts.items.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const fi = sema_mono.free_fn_insts.items[i];
                const fd = gmap.get(fi.fn_name) orelse continue;
                if (fi.params.len != fd.type_params.len) continue;

                const subst = try self.allocator.alloc(MethodParamBinding, fi.params.len);
                defer self.allocator.free(subst);
                for (fi.params, fi.args, 0..) |pn, an, k| subst[k] = .{ .name = pn, .concrete = an };

                const prev = self.current_method_subst;
                self.current_method_subst = subst;
                defer self.current_method_subst = prev;

                if (try self.discoverGenericCallsInBlock(fd.body, &gmap)) changed = true;
            }
        }
    }

    fn discoverGenericCallsInBlock(self: *LlvmCompiler, block: ast.Block, gmap: *const std.StringHashMap(ast.FunctionDecl)) anyerror!bool {
        var any = false;
        for (block.statements) |stmt| {
            if (try self.discoverGenericCallsInStmt(stmt, gmap)) any = true;
        }
        return any;
    }

    fn discoverGenericCallsInStmt(self: *LlvmCompiler, stmt: ast.Statement, gmap: *const std.StringHashMap(ast.FunctionDecl)) anyerror!bool {
        var any = false;
        switch (stmt) {
            .expr_stmt => |es| any = try self.discoverGenericCallsInExpr(es.expr, gmap),
            .let_stmt => |ls| if (ls.init) |init| {
                any = try self.discoverGenericCallsInExpr(init, gmap);
            },
            .defer_stmt => |ds| any = try self.discoverGenericCallsInExpr(ds.expr, gmap),
            .block => |b| any = try self.discoverGenericCallsInBlock(b, gmap),
            .if_stmt => |is| {
                if (try self.discoverGenericCallsInExpr(is.condition, gmap)) any = true;
                if (try self.discoverGenericCallsInStmt(is.then_branch.*, gmap)) any = true;
                if (is.else_branch) |eb| {
                    if (try self.discoverGenericCallsInStmt(eb.*, gmap)) any = true;
                }
            },
            .while_stmt => |ws| {
                if (try self.discoverGenericCallsInExpr(ws.condition, gmap)) any = true;
                if (try self.discoverGenericCallsInStmt(ws.body.*, gmap)) any = true;
            },
            .for_stmt => |fs| {
                if (fs.initializer) |init| {
                    if (try self.discoverGenericCallsInStmt(init.*, gmap)) any = true;
                }
                if (fs.condition) |c| {
                    if (try self.discoverGenericCallsInExpr(c, gmap)) any = true;
                }
                if (fs.increment) |inc| {
                    if (try self.discoverGenericCallsInExpr(inc, gmap)) any = true;
                }
                if (try self.discoverGenericCallsInStmt(fs.body.*, gmap)) any = true;
            },
            .switch_stmt => |ss| {
                if (try self.discoverGenericCallsInExpr(ss.discriminant, gmap)) any = true;
                for (ss.cases) |c| {
                    if (try self.discoverGenericCallsInStmt(c.body.*, gmap)) any = true;
                }
                if (ss.default_case) |dc| {
                    if (try self.discoverGenericCallsInStmt(dc.*, gmap)) any = true;
                }
            },
            .return_stmt => |rs| if (rs.value) |v| {
                any = try self.discoverGenericCallsInExpr(v, gmap);
            },
            else => {},
        }
        return any;
    }

    fn discoverGenericCallsInExpr(self: *LlvmCompiler, expr: ast.Expression, gmap: *const std.StringHashMap(ast.FunctionDecl)) anyerror!bool {
        var any = false;
        switch (expr.kind) {
            .generic_call => |gc| {
                if (gc.callee.kind == .ident) {
                    if (gmap.get(gc.callee.kind.ident)) |callee_fd| {
                        if (gc.type_args.len == callee_fd.type_params.len and gc.type_args.len > 0) {
                            if (try self.registerGenericFnInst(callee_fd, gc.type_args)) any = true;
                        }
                    }
                }
                for (gc.args) |*a| {
                    if (try self.discoverGenericCallsInExpr(a.*, gmap)) any = true;
                }
            },
            .call => |c| {
                for (c.args) |*a| {
                    if (try self.discoverGenericCallsInExpr(a.*, gmap)) any = true;
                }
                if (try self.discoverGenericCallsInExpr(c.callee.*, gmap)) any = true;
            },
            .binary => |b| {
                if (try self.discoverGenericCallsInExpr(b.left.*, gmap)) any = true;
                if (try self.discoverGenericCallsInExpr(b.right.*, gmap)) any = true;
            },
            .unary => |u| any = try self.discoverGenericCallsInExpr(u.operand.*, gmap),
            .field_access => |fa| any = try self.discoverGenericCallsInExpr(fa.object.*, gmap),
            .index => |ix| {
                if (try self.discoverGenericCallsInExpr(ix.object.*, gmap)) any = true;
                if (try self.discoverGenericCallsInExpr(ix.index.*, gmap)) any = true;
            },
            .await_expr => |aw| any = try self.discoverGenericCallsInExpr(aw.operand.*, gmap),
            .go_expr => |g| any = try self.discoverGenericCallsInExpr(g.operand.*, gmap),
            .cast => |c| any = try self.discoverGenericCallsInExpr(c.expr.*, gmap),
            .try_expr => |t| any = try self.discoverGenericCallsInExpr(t.*, gmap),
            .nullish_coalesce => |nc| {
                if (try self.discoverGenericCallsInExpr(nc.left.*, gmap)) any = true;
                if (try self.discoverGenericCallsInExpr(nc.right.*, gmap)) any = true;
            },
            .if_expr => |ie| {
                if (try self.discoverGenericCallsInExpr(ie.condition.*, gmap)) any = true;
                if (try self.discoverGenericCallsInExpr(ie.then_branch.*, gmap)) any = true;
                if (try self.discoverGenericCallsInExpr(ie.else_branch.*, gmap)) any = true;
            },
            .block_expr => |b| any = try self.discoverGenericCallsInBlock(b, gmap),
            .tuple => |items| {
                for (items) |*it| {
                    if (try self.discoverGenericCallsInExpr(it.*, gmap)) any = true;
                }
            },
            else => {},
        }
        return any;
    }

    // Render gc's type args under the current instance's subst; if all concrete, register the callee
    // instance. Returns true if a NEW instance was added.
    fn registerGenericFnInst(self: *LlvmCompiler, callee_fd: ast.FunctionDecl, type_args: []const ast.TypeRef) anyerror!bool {
        const rendered = try self.allocator.alloc([]const u8, type_args.len);
        defer {
            for (rendered) |r| self.allocator.free(r);
            self.allocator.free(rendered);
        }
        var all_concrete = true;
        for (type_args, 0..) |ta, idx| {
            rendered[idx] = try self.typeRefToString(ta);
            // Still-abstract if the rendered arg is one of the callee's own type parameters (subst
            // failed to resolve it), i.e. it names an unbound type variable rather than a real type.
            for (callee_fd.type_params) |tp| {
                if (std.mem.eql(u8, rendered[idx], tp)) all_concrete = false;
            }
        }
        if (!all_concrete) return false;
        return sema_mono.noteFreeFnInstStr(callee_fd.name, callee_fd.type_params, rendered);
    }

    pub fn collectStringLiterals(self: *LlvmCompiler, program: ast.Program) anyerror!void {
        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                try self.collectStringsFromBlock(decl.fn_decl.body);
            } else if (decl == .struct_decl) {
                for (decl.struct_decl.methods) |method| {
                    try self.collectStringsFromBlock(method.decl.body);
                }
            } else if (decl == .enum_decl) {
                for (decl.enum_decl.methods) |method| {
                    try self.collectStringsFromBlock(method.decl.body);
                }
            }
        }
    }

    pub fn collectStringsFromBlock(self: *LlvmCompiler, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectStringsFromStatement(stmt);
        }
    }

    fn collectStringsFromStatement(self: *LlvmCompiler, stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .expr_stmt => |es| try self.collectStringsFromExpr(es.expr),
            .let_stmt => |ls| if (ls.init) |init| try self.collectStringsFromExpr(init),
            .block => |b| try self.collectStringsFromBlock(b),
            .if_stmt => |is| {
                try self.collectStringsFromExpr(is.condition);
                try self.collectStringsFromStatement(is.then_branch.*);
                if (is.else_branch) |eb| try self.collectStringsFromStatement(eb.*);
            },
            .while_stmt => |ws| {
                try self.collectStringsFromExpr(ws.condition);
                try self.collectStringsFromStatement(ws.body.*);
            },
            .for_stmt => |fs| {
                if (fs.initializer) |init| try self.collectStringsFromStatement(init.*);
                if (fs.condition) |c| try self.collectStringsFromExpr(c);
                if (fs.increment) |inc| try self.collectStringsFromExpr(inc);
                try self.collectStringsFromStatement(fs.body.*);
            },
            .switch_stmt => |ss| {
                try self.collectStringsFromExpr(ss.discriminant);
                for (ss.cases) |c| {
                    try self.collectStringsFromStatement(c.body.*);
                }
                if (ss.default_case) |dc| {
                    try self.collectStringsFromStatement(dc.*);
                }
            },
            .return_stmt => |rs| if (rs.value) |v| try self.collectStringsFromExpr(v),
            else => {},
        }
    }

    fn collectStringsFromExpr(self: *LlvmCompiler, expr: ast.Expression) anyerror!void {
        switch (expr.kind) {
            .literal => |lit| {
                if (lit == .string) {
                    const str = lit.string;
                    for (self.strings.items) |s| {
                        if (std.mem.eql(u8, s, str)) return;
                    }
                    try self.strings.append(self.allocator, str);
                } else if (lit == .array) {
                    for (lit.array) |expr_item| try self.collectStringsFromExpr(expr_item);
                } else if (lit == .object) {
                    for (lit.object) |field| try self.collectStringsFromExpr(field.value);
                }
            },
            .binary => |bin| {
                try self.collectStringsFromExpr(bin.left.*);
                try self.collectStringsFromExpr(bin.right.*);
            },
            .unary => |uni| try self.collectStringsFromExpr(uni.operand.*),
            .call => |call| {
                try self.collectStringsFromExpr(call.callee.*);
                for (call.args) |arg| try self.collectStringsFromExpr(arg);
            },
            .generic_call => |gc| {
                try self.collectStringsFromExpr(gc.callee.*);
                for (gc.args) |arg| try self.collectStringsFromExpr(arg);
            },
            .field_access => |fa| try self.collectStringsFromExpr(fa.object.*),
            .index => |idx| {
                try self.collectStringsFromExpr(idx.object.*);
                try self.collectStringsFromExpr(idx.index.*);
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.collectStringsFromExpr(field.value);
            },
            .enum_init => |ei| {
                for (ei.fields) |field| try self.collectStringsFromExpr(field.value);
            },
            .cast => |c| try self.collectStringsFromExpr(c.expr.*),
            .optional_chaining => |oc| try self.collectStringsFromExpr(oc.object.*),
            .nullish_coalesce => |nc| {
                try self.collectStringsFromExpr(nc.left.*);
                try self.collectStringsFromExpr(nc.right.*);
            },
            .tuple => |t| {
                for (t) |expr_item| try self.collectStringsFromExpr(expr_item);
            },
            .if_expr => |ife| {
                try self.collectStringsFromExpr(ife.condition.*);
                try self.collectStringsFromExpr(ife.then_branch.*);
                try self.collectStringsFromExpr(ife.else_branch.*);
            },
            .closure => |cl| {
                switch (cl.body) {
                    .expr => |e| try self.collectStringsFromExpr(e.*),
                    .block => |b| try self.collectStringsFromBlock(b),
                }
            },
            .template_expr => |te| {
                for (te.parts) |p| try self.collectStringsFromExpr(p);
            },
            .block_expr => |be| {
                try self.collectStringsFromBlock(be);
            },
            else => {},
        }
    }

    pub fn collectLocalVarNames(self: *LlvmCompiler, list: *std.ArrayList([]const u8), block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectLocalVarNamesFromStatement(list, stmt);
        }
    }

    pub fn findEnumByVariant(self: *LlvmCompiler, variant_name: []const u8) ?[]const u8 {
        var iter = self.enums.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.variants) |v| {
                if (std.mem.eql(u8, v.name, variant_name)) {
                    return entry.key_ptr.*;
                }
            }
        }
        return null;
    }

    pub fn getEnumTagAndSize(self: *LlvmCompiler, enum_name: []const u8, variant_name: []const u8, tag_out: *u32, max_size_out: *u32) !void {
        const enum_decl = self.enums.get(enum_name) orelse return error.EnumNotFound;
        const ptr_size = @as(u32, 8);

        var max_payload_size: u32 = 0;
        var found_tag: ?u32 = null;

        for (enum_decl.variants, 0..) |v, idx| {
            if (std.mem.eql(u8, v.name, variant_name)) {
                found_tag = @intCast(idx);
            }
            var payload_size: u32 = 0;
            if (v.fields) |fields| {
                payload_size = @intCast(fields.len * ptr_size);
            } else if (v.type_name) |_| {
                payload_size = ptr_size;
            }
            if (payload_size > max_payload_size) {
                max_payload_size = payload_size;
            }
        }

        if (found_tag) |t| {
            tag_out.* = t;
            max_size_out.* = ptr_size + max_payload_size;
        } else {
            return error.VariantNotFound;
        }
    }

    fn resolveDiscriminantEnumName(self: *LlvmCompiler, discr: *const ast.Expression) ?[]const u8 {
        const t = self.resolveExpressionTypeName(discr) catch return null;
        if (t) |name| {
            if (self.enums.contains(name)) return name;
        }
        return null;
    }

    fn collectLocalVarNamesFromStatement(self: *LlvmCompiler, list: *std.ArrayList([]const u8), stmt: ast.Statement) anyerror!void {
        switch (stmt) {
            .let_stmt => |ls| {
                if (ls.names) |names| {
                    for (names) |name| {
                        try list.append(self.allocator, name);
                    }
                } else {
                    try list.append(self.allocator, ls.name);
                }
            },
            .block => |b| try self.collectLocalVarNames(list, b),
            .if_stmt => |is| {
                try self.collectLocalVarNamesFromStatement(list, is.then_branch.*);
                if (is.else_branch) |eb| try self.collectLocalVarNamesFromStatement(list, eb.*);
            },
            .while_stmt => |ws| try self.collectLocalVarNamesFromStatement(list, ws.body.*),
            .for_stmt => |fs| {
                if (fs.initializer) |init| try self.collectLocalVarNamesFromStatement(list, init.*);
                try self.collectLocalVarNamesFromStatement(list, fs.body.*);
            },
            .switch_stmt => |*ss| {
                const enum_name_opt = self.resolveDiscriminantEnumName(&ss.discriminant);
                if (enum_name_opt) |enum_name| {
                    if (self.enums.get(enum_name)) |enum_decl| {
                        for (ss.cases) |c| {
                            for (c.values) |val| {
                                if (val.kind == .call) {
                                    const call = val.kind.call;
                                    if (call.callee.kind == .field_access) {
                                        const fa = call.callee.kind.field_access;
                                        for (enum_decl.variants) |v| {
                                            if (std.mem.eql(u8, v.name, fa.field)) {
                                                if (v.type_name) |_| {
                                                    if (call.args.len > 0 and call.args[0].kind == .ident) {
                                                        try list.append(self.allocator, call.args[0].kind.ident);
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    }
                                } else if (val.kind == .struct_init) {
                                    const si = val.kind.struct_init;
                                    for (enum_decl.variants) |v| {
                                        if (std.mem.eql(u8, v.name, si.type_name)) {
                                            if (v.fields) |payload_fields| {
                                                for (si.fields) |f_init| {
                                                    for (payload_fields) |pf| {
                                                        if (std.mem.eql(u8, f_init.name, pf.name)) {
                                                            if (f_init.value.kind == .ident) {
                                                                try list.append(self.allocator, f_init.value.kind.ident);
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                for (ss.cases) |c| try self.collectLocalVarNamesFromStatement(list, c.body.*);
                if (ss.default_case) |dc| try self.collectLocalVarNamesFromStatement(list, dc.*);
            },
            else => {},
        }
    }

    pub fn collectLocalVarTypes(self: *LlvmCompiler, map: *std.StringHashMap([]const u8), block: ast.Block) anyerror!void {
        for (block.statements) |*stmt| {
            try self.collectLocalVarTypesFromStatement(map, stmt);
        }
    }

    fn collectLocalVarTypesFromStatement(self: *LlvmCompiler, map: *std.StringHashMap([]const u8), stmt_ptr: *const ast.Statement) anyerror!void {
        const stmt = stmt_ptr.*;
        switch (stmt) {
            .let_stmt => |ls| {
                if (ls.names) |names| {
                    var tuple_type: ?[]const u8 = null;
                    if (ls.init) |*init| {
                        tuple_type = try self.resolveExpressionTypeName(init);
                    }
                    for (names, 0..) |name, idx| {
                        const t = if (tuple_type) |tt| try getTupleElementType(self.allocator, tt, idx) else "i32";
                        try map.put(name, t);

                        if (self.current_local_type_ids) |ids| {
                            if (self.typed_ir) |ir| {
                                if (ls.init) |*init| {
                                    if (ir.typeOf(init)) |tup_tid| {
                                        if (self.type_store) |st| {
                                            const info = st.get(tup_tid);
                                            if (info == .tuple and idx < info.tuple.len) {
                                                try ids.put(name, info.tuple[idx]);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    if (ls.type_name) |t| {
                        const t_str = try self.typeRefToString(t);
                        try map.put(ls.name, t_str);

                        if (self.current_local_type_ids) |ids| {
                            if (self.tidForTypeRef(t)) |tid| try ids.put(ls.name, tid);
                        }
                    } else if (ls.init) |*init| {
                        const resolved0 = try self.resolveExpressionTypeName(init);

                        const resolved = if (resolved0) |r| try self.substTypeParams(r) else null;
                        if (resolved) |name| {
                            try map.put(ls.name, name);

                            if (self.current_local_type_ids) |ids| {
                                if (self.typed_ir) |ir| {
                                    if (ir.typeOf(init)) |tid| {

                                        const store_tid = if (self.current_instantiation_id) |inst|
                                            (ir.typeOfInst(init.id, inst) orelse tid)
                                        else
                                            tid;
                                        try ids.put(ls.name, store_tid);
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .block => |b| try self.collectLocalVarTypes(map, b),
            .if_stmt => |is| {
                try self.collectLocalVarTypesFromStatement(map, is.then_branch);
                if (is.else_branch) |eb| try self.collectLocalVarTypesFromStatement(map, eb);
            },
            .while_stmt => |ws| try self.collectLocalVarTypesFromStatement(map, ws.body),
            .for_stmt => |fs| {
                if (fs.initializer) |init| try self.collectLocalVarTypesFromStatement(map, init);
                try self.collectLocalVarTypesFromStatement(map, fs.body);
            },
            .switch_stmt => |*ss| {
                const enum_name_opt = self.resolveDiscriminantEnumName(&ss.discriminant);
                if (enum_name_opt) |enum_name| {
                    if (self.enums.get(enum_name)) |enum_decl| {
                        for (ss.cases) |c| {
                            for (c.values) |val| {
                                if (val.kind == .call) {
                                    const call = val.kind.call;
                                    if (call.callee.kind == .field_access) {
                                        const fa = call.callee.kind.field_access;
                                        for (enum_decl.variants) |v| {
                                            if (std.mem.eql(u8, v.name, fa.field)) {
                                                if (v.type_name) |payload_type| {
                                                    if (call.args.len > 0 and call.args[0].kind == .ident) {
                                                        const p_type_str = try self.typeRefToString(payload_type);
                                                        try map.put(call.args[0].kind.ident, p_type_str);
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    }
                                } else if (val.kind == .struct_init) {
                                    const si = val.kind.struct_init;
                                    for (enum_decl.variants) |v| {
                                        if (std.mem.eql(u8, v.name, si.type_name)) {
                                            if (v.fields) |payload_fields| {
                                                for (si.fields) |f_init| {
                                                    for (payload_fields) |pf| {
                                                        if (std.mem.eql(u8, f_init.name, pf.name)) {
                                                            if (f_init.value.kind == .ident) {
                                                                const p_type_str = try self.typeRefToString(pf.type_name);
                                                                try map.put(f_init.value.kind.ident, p_type_str);
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                for (ss.cases) |c| try self.collectLocalVarTypesFromStatement(map, c.body);
                if (ss.default_case) |dc| try self.collectLocalVarTypesFromStatement(map, dc);
            },
            else => {},
        }
    }

    pub fn compileCoverageIncrement(self: *LlvmCompiler, block_id: usize) anyerror!void {
        const counters_glob = core.LLVMGetNamedGlobal(self.module, "__nova_cov_counters") orelse blk: {
            const ptr_to_ptr = core.LLVMPointerType(self.i64_type, 0);
            const glob = core.LLVMAddGlobal(self.module, ptr_to_ptr, "__nova_cov_counters");
            core.LLVMSetLinkage(glob, types.LLVMLinkage.LLVMExternalLinkage);
            break :blk glob;
        };

        const counters_ptr_val = core.LLVMBuildLoad2(self.builder, core.LLVMPointerType(self.i64_type, 0), counters_glob, "counters_ptr_val");
        var indices = [_]types.LLVMValueRef{
            core.LLVMConstInt(self.i32_type, @intCast(block_id), 0),
        };
        const elem_ptr = core.LLVMBuildInBoundsGEP2(self.builder, self.i64_type, counters_ptr_val, &indices, 1, "cov_ptr");
        const val = core.LLVMBuildLoad2(self.builder, self.i64_type, elem_ptr, "cov_val");
        const inc = core.LLVMBuildAdd(self.builder, val, core.LLVMConstInt(self.i64_type, 1, 0), "cov_inc");
        _ = core.LLVMBuildStore(self.builder, inc, elem_ptr);
    }

    pub const resolveExpressionTypeName = types_mod.resolveExpressionTypeName;
    pub const scopedStructName = types_mod.scopedStructName;
    pub const isCollidingStruct = types_mod.isCollidingStruct;
    pub const isOptionalExpr = types_mod.isOptionalExpr;
    pub const typeOfExprConcrete = types_mod.typeOfExprConcrete;
    pub const isOwnedExpr = types_mod.isOwnedExpr;
    pub const isOwnedTypeId = types_mod.isOwnedTypeId;
    pub const isOwnedLocal = types_mod.isOwnedLocal;
    pub const isOwnedErrUnionOk = types_mod.isOwnedErrUnionOk;
    pub const isStringExpr = types_mod.isStringExpr;
    pub const tupleElemTraitName = types_mod.tupleElemTraitName;
    pub const isOwnedErrUnionErr = types_mod.isOwnedErrUnionErr;
    pub const isOwnedStorageElem = types_mod.isOwnedStorageElem;
    pub const isOwnedStorageElemByName = types_mod.isOwnedStorageElemByName;
    pub const typeIdForRenderedName = types_mod.typeIdForRenderedName;
    pub const isOwnedErrUnionPayloadByName = types_mod.isOwnedErrUnionPayloadByName;
    pub const isOwnedTupleElemByName = types_mod.isOwnedTupleElemByName;
    pub const isOwnedDeclaredType = types_mod.isOwnedDeclaredType;
    pub const tidForTypeRef = types_mod.tidForTypeRef;
    pub const tidForName = types_mod.tidForName;
    pub const ownedByName = types_mod.ownedByName;

    pub const compileStatement = statements_mod.compileStatement;
    pub const runErrdefers = statements_mod.runErrdefers;

    pub const compileExpression = expressions_mod.compileExpression;
    pub const compileConstRef = expressions_mod.compileConstRef;
    pub const initDefaultContainerFields = expressions_mod.initDefaultContainerFields;
    pub const consumeTemporary = expressions_mod.consumeTemporary;
    pub const atomicCell = expressions_mod.atomicCell;
    pub const guardOptionalDeref = expressions_mod.guardOptionalDeref;
    pub const registerTemporary = expressions_mod.registerTemporary;
    pub const drainTemporaries = expressions_mod.drainTemporaries;
    pub const buildClosureCall = expressions_mod.buildClosureCall;
    pub const compileSimdCall = expressions_mod.compileSimdCall;
    pub const arrayElemFloatLLVM = expressions_mod.arrayElemFloatLLVM;
    pub const arrayBasePtr = expressions_mod.arrayBasePtr;
    pub const buildBareFnBox = expressions_mod.buildBareFnBox;
    pub const fnBoxReturn = expressions_mod.fnBoxReturn;
    pub const fnRefInt = expressions_mod.fnRefInt;
    pub const identNamesVariable = expressions_mod.identNamesVariable;
    pub const widenBranchToTrait = expressions_mod.widenBranchToTrait;
    pub const buildDriveAsyncCall = expressions_mod.buildDriveAsyncCall;
    pub const buildDriveAsyncHandle = expressions_mod.buildDriveAsyncHandle;
    pub const coroPromiseType = expressions_mod.coroPromiseType;
    pub const coroPromiseSlot = expressions_mod.coroPromiseSlot;
    pub const coroPromiseResultSlot = expressions_mod.coroPromiseResultSlot;
    pub const coroPromiseWaiterSlot = expressions_mod.coroPromiseWaiterSlot;
    pub const buildCoroPromisePtr = expressions_mod.buildCoroPromisePtr;
    pub const awaitedCallHandle = expressions_mod.awaitedCallHandle;
    pub const buildAwait = expressions_mod.buildAwait;
    pub const buildAwaitSuspend = expressions_mod.buildAwaitSuspend;
    pub const awaitSleepMillis = expressions_mod.awaitSleepMillis;
    pub const buildGo = expressions_mod.buildGo;
    pub const buildAwaitFuture = expressions_mod.buildAwaitFuture;
    pub const awaitChanRecvArg = expressions_mod.awaitChanRecvArg;
    pub const buildChanRecv = expressions_mod.buildChanRecv;
    pub const buildWhenAny = expressions_mod.buildWhenAny;
    pub const awaitAsyncIoCall = expressions_mod.awaitAsyncIoCall;
    pub const buildAsyncIo = expressions_mod.buildAsyncIo;
    pub const compileAppendToStringBuilder = expressions_mod.compileAppendToStringBuilder;
    pub const canonicalizeInt = expressions_mod.canonicalizeInt;
    pub const emitIntDivGuard = expressions_mod.emitIntDivGuard;
    pub const emitTrapIf = expressions_mod.emitTrapIf;
    pub const numToString = expressions_mod.numToString;
    pub const numToStringImpl = expressions_mod.numToStringImpl;
    pub const numToStringT = expressions_mod.numToStringT;
    pub const compileJsxElement = expressions_mod.compileJsxElement;
    pub const compileGenericParse = expressions_mod.compileGenericParse;
    pub const compileDecodeBinaryRow = expressions_mod.compileDecodeBinaryRow;
    pub const compileNovaQuery = expressions_mod.compileNovaQuery;
    pub const convertValueToType = expressions_mod.convertValueToType;
    pub const resolveReifyTypeName = expressions_mod.resolveReifyTypeName;
    pub const getFunc = expressions_mod.getFunc;
};

pub const compile = declarations_mod.compile;
