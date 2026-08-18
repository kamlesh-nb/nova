
const std = @import("std");
const ast = @import("../../frontend/ast.zig");
const sema_mono = @import("../../frontend/sema/mono.zig");
const sema_reach = @import("../../frontend/sema/reach.zig");
const llvm = @import("llvm");

const types = llvm.types;
const core = llvm.core;
const target = llvm.target;
const debug = llvm.debug;
const target_machine = llvm.target_machine;
const analysis = llvm.analysis;
const coverage_mod = @import("coverage.zig");
pub const CoverageBlock = coverage_mod.CoverageBlock;
pub const CoverageRegistry = coverage_mod.CoverageRegistry;

const types_mod = @import("types.zig");
const sema_infer = @import("../../frontend/sema/infer.zig");
const sema_types = @import("../../frontend/types.zig");
const sema_shadow = @import("../../frontend/sema/shadow.zig");
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
    // The declared parameters (free functions only; left empty for methods, whose implicit `self` shifts the
    // argument indices). The optimiser emit path uses this to model params; empty => it treats the function
    // as unmodelled and compiles from the AST.
    params: []const ast.Param = &.{},

    is_async: bool = false,

    instantiation: ?[]const u8 = null,
    // String-engine-removal: the explicit TypeId instantiation key for this spec (free-fn or method),
    // used to set current_instantiation_id directly, bypassing the fragile name->live_inst_ids lookup.
    instantiation_id: ?sema_types.TypeId = null,

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

// FR-simd-L2: which family of hardware crypto intrinsics the compile target provides. Decided once from
// the target triple; the SIMD builtins pick the right LLVM intrinsic (or the software fallback) from it.
pub const SimdTarget = enum { none, aarch64, x86_64 };

// Identity key for interning substTypeParams results. Interned/AST strings have stable pointers for the
// duration of a compile, so (ptr,len) identifies the input and current instantiation uniquely.
pub const SubstKey = struct { in_ptr: usize, in_len: usize, inst_ptr: usize, inst_id: u32 };

pub const LlvmCompiler = struct {
    allocator: std.mem.Allocator,
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    target_machine: types.LLVMTargetMachineRef,
    // DWARF debug info (Gap 4). Only populated in debug (non-release) builds: locals are only
    // reliable at -O0, so debugging is a debug-build activity. `di_builder` null => emit nothing.
    // `di_scope` is the current function's DISubprogram, set per-function so statement debug
    // locations attach to the right scope.
    di_builder: types.LLVMDIBuilderRef = null,
    di_cu: types.LLVMMetadataRef = null,
    di_file: types.LLVMMetadataRef = null,
    // Absolute process cwd, resolved once, so relative source dirs become absolute DWARF paths a
    // debugger can match against an absolute-path breakpoint. Null => leave dirs relative (fallback).
    di_cwd: ?[]const u8 = null,
    di_scope: types.LLVMMetadataRef = null,
    di_scope_file: types.LLVMMetadataRef = null,
    debug_enabled: bool = false,
    di_finalized: bool = false,
    // DIFile per source path (Span.file), so per-function debug info attributes to the right file
    // in a merged multi-file program. Keyed by the source path string.
    di_files: std.StringHashMap(types.LLVMMetadataRef) = undefined,
    // Cached DIType per primitive type name (int/bool/f64/...), so N variables share one type node.
    di_types: std.StringHashMap(types.LLVMMetadataRef) = undefined,
    // Names already given a DILocalVariable in the current function, so the pre-alloc declare and the
    // per-let declare don't emit two for the same variable. Cleared per function.
    dbg_declared: std.StringHashMap(void) = undefined,
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
    // M-1: base names of structs that ESCAPE their constructing frame (used as a function/method
    // return type, a struct field type, or a container element / generic arg). Such a struct must
    // NOT be value-lowered while escape handling (sret/heap-promote) is unimplemented, else a stack
    // alloca outlives its frame -> UAF. Computed lazily on first isValueStructName. null = not yet.
    value_escape_set: ?std.StringHashMap(void) = null,
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

    // Set while compiling a call argument whose (substituted) parameter type is itself a value-optional.
    // The speculative ident-unbox in compileExpr (a valopt local used where the checker recorded a BARE
    // type) must NOT fire in that position: the box has to survive into a value-optional parameter (e.g.
    // `List<T|undefined>.push(value)` forwarding to `RawBuffer<T|undefined>.push`). Without this the box
    // is stripped to a raw value, stored, and a later read `?? d` unboxes the raw value as a pointer.
    suppress_valopt_unbox: bool = false,

    default_ctor_depth: u32 = 0,

    rendered_name_ids: ?std.StringHashMapUnmanaged(sema_types.TypeId) = null,
    current_module_prefix: ?[]const u8,
    current_function_name: ?[]const u8,

    current_loop_scope_depth: ?usize,
    current_collecting_function_name: ?[]const u8,

    current_collecting_instantiation: ?[]const u8,

    // SE-C: the TypeId inst_key of the function whose body is being scanned for closures. A lifted lambda
    // inherits it as its own instantiation_id so the overlay can reify the parent's type-params (e.g. a
    // lambda inside a generic method reifying its <T>) without the string method_subst.
    current_collecting_instantiation_id: ?sema_types.TypeId = null,

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
    // FR-simd-L2: which target crypto-intrinsic family is available, decided from the target triple.
    simd_target: SimdTarget = .none,
    coverage_enabled: bool,
    cov_registry: ?CoverageRegistry,
    current_string_builder: ?types.LLVMValueRef = null,
    // Compile-time accumulator for adjacent NSX static text (tag opens, attributes, closes, literal text).
    // jsxAppendLiteral appends bytes here instead of emitting a StringBuilder.append per chunk; the buffer
    // is flushed as ONE append right before any dynamic part ({expr}, a `{for}` block) and at element end.
    // Turns ~25 append calls per card into ~5, closing most of the gap to a hand-written builder.
    jsx_pending_literal: std.ArrayListUnmanaged(u8) = .empty,
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
    // Interns rendered type names by TypeId. resolveExpressionTypeName is called per-expression across the
    // whole program and used to allocate a fresh renderLegacy string every call that NO caller freed -- a
    // codegen-wide leak (tens of GB on a large app). Rendering is a pure function of the TypeId, so cache it:
    // one owned string per distinct TypeId, freed at deinit; callers borrow and never free.
    type_name_cache: std.AutoHashMapUnmanaged(sema_types.TypeId, []const u8) = .empty,
    // Interns substTypeParams results. Keyed by (input string identity, current instantiation string
    // identity, current instantiation id). substTypeParams allocates a fresh substituted name per call
    // that callers (symbolName/resolveExpressionTypeName) never freed -- a per-expression codegen leak.
    subst_cache: std.AutoHashMapUnmanaged(SubstKey, []const u8) = .empty,
    // Interns decimal literals (`0m`, `2m`, ...) to a lazily-initialised, immortal-pinned global so a literal
    // parses+allocates ONCE per program run instead of on every evaluation. Keyed by the literal's digits.
    decimal_globals: std.StringHashMap(types.LLVMValueRef),

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

        // DWARF debug info (Gap 4): only in debug builds (locals are unreliable at -O3). Create the
        // DIBuilder now; the compile unit + per-file DIFiles are built lazily on first function emit
        // (the source path lives on each node's Span, not available here). Module flags declare the
        // DWARF + debug-metadata versions so lldb reads the info.
        const dbg_on = !is_release and !is_wasm;
        var di_builder: types.LLVMDIBuilderRef = null;
        if (dbg_on) {
            di_builder = debug.LLVMCreateDIBuilder(module);
            const md_dwarf = core.LLVMValueAsMetadata(core.LLVMConstInt(core.LLVMInt32Type(), 4, 0));
            const md_debug = core.LLVMValueAsMetadata(core.LLVMConstInt(core.LLVMInt32Type(), 3, 0));
            core.LLVMAddModuleFlag(module, .LLVMModuleFlagBehaviorWarning, "Dwarf Version", "Dwarf Version".len, md_dwarf);
            core.LLVMAddModuleFlag(module, .LLVMModuleFlagBehaviorWarning, "Debug Info Version", "Debug Info Version".len, md_debug);
        }

        const compiler = LlvmCompiler{
            .di_builder = di_builder,
            .debug_enabled = dbg_on,
            .di_files = std.StringHashMap(types.LLVMMetadataRef).init(allocator),
            .di_types = std.StringHashMap(types.LLVMMetadataRef).init(allocator),
            .dbg_declared = std.StringHashMap(void).init(allocator),
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
            .decimal_globals = std.StringHashMap(types.LLVMValueRef).init(allocator),
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
            .simd_target = if (is_wasm) .none else if (std.mem.indexOf(u8, triple_z, "aarch64") != null or std.mem.indexOf(u8, triple_z, "arm64") != null) .aarch64 else if (std.mem.indexOf(u8, triple_z, "x86_64") != null) .x86_64 else .none,
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

    // --- DWARF debug info (Gap 4) -----------------------------------------------------------------
    // A DIFile for `path`, cached so a merged multi-file program reuses one file node per source.
    // LLVM copies the name/dir into its context, so the null-terminated dupes are freed after the call.
    fn diFileFor(self: *LlvmCompiler, path: []const u8) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_files.get(path)) |f| return f;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir_rel = if (slash) |s| path[0..s] else ".";
        const base_s = if (slash) |s| path[s + 1 ..] else path;
        // DWARF must carry ABSOLUTE directories so a debugger (lldb-dap / VS Code) can match a
        // breakpoint it sets by absolute file path. A relative dir binds only by basename, which
        // lldb CLI tolerates but lldb-dap does not — the breakpoint stays pending and never fires.
        // Prefix the process cwd for relative source dirs; leave already-absolute paths untouched.
        // EXCEPT synthetic generated "files" (<mediator-generated> etc.): never make those absolute, or
        // lldb/VS Code tries to open a nonexistent `<cwd>/./<...>` path.
        const synthetic = base_s.len > 0 and base_s[0] == '<';
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_s: []const u8 = blk: {
            if (synthetic) break :blk dir_rel;
            if (dir_rel.len > 0 and dir_rel[0] == '/') break :blk dir_rel;
            // The stdlib is compiled under the logical prefix `src/std/...` but its SOURCE actually lives
            // at ~/.nova/std/... . Prefixing the app cwd would point the debugger at <app>/src/std/... ,
            // which does not exist -> "the editor could not be opened, file not found" the moment you step
            // into List/string/etc. Map the stdlib prefix to the real install dir instead.
            if (std.mem.startsWith(u8, dir_rel, "src/std")) {
                if (std.c.getenv("HOME")) |home_c| {
                    const rest = dir_rel["src/std".len..]; // "" or "/collections" ...
                    const joined = std.fmt.bufPrint(&abs_buf, "{s}/.nova/std{s}", .{ std.mem.span(home_c), rest }) catch break :blk dir_rel;
                    break :blk joined;
                }
            }
            const cwd = self.di_cwd orelse break :blk dir_rel;
            const joined = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd, dir_rel }) catch break :blk dir_rel;
            break :blk joined;
        };
        // Catch-all: if the resolved source does not exist on disk (target-conditional stdlib logical names
        // like net/eventloop.nova -> net/ev/kqueue.nova, injected helpers.nova, cache/package paths, ...),
        // emit NO debug info for it. A DIFile pointing at a missing path makes VS Code pop "the editor
        // could not be opened, file not found" when you step into that frame. Better to step over silently.
        if (dir_s.len > 0 and dir_s[0] == '/') {
            var chk_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_z = std.fmt.bufPrintZ(&chk_buf, "{s}/{s}", .{ dir_s, base_s }) catch null;
            if (full_z == null or std.c.access(full_z.?.ptr, 0) != 0) {
                self.di_files.put(path, null) catch {};
                return null;
            }
        }
        const base_z = self.allocator.dupeZ(u8, base_s) catch return null;
        defer self.allocator.free(base_z);
        const dir_z = self.allocator.dupeZ(u8, dir_s) catch return null;
        defer self.allocator.free(dir_z);
        const f = debug.LLVMDIBuilderCreateFile(self.di_builder, base_z.ptr, base_s.len, dir_z.ptr, dir_s.len);
        self.di_files.put(path, f) catch {};
        return f;
    }

    // Lazily create the compile unit on the first function emitted, using its source file as primary.
    fn ensureDebugCU(self: *LlvmCompiler, path: []const u8) void {
        if (self.di_builder == null or self.di_cu != null) return;
        self.di_file = self.diFileFor(path);
        self.di_cu = debug.LLVMDIBuilderCreateCompileUnit(
            self.di_builder,
            .LLVMDWARFSourceLanguageC99,
            self.di_file,
            "nova",
            "nova".len,
            0,
            "",
            0,
            0,
            "",
            0,
            .LLVMDWARFEmissionFull,
            0,
            0,
            0,
            "",
            0,
            "",
            0,
        );
    }

    // Attach a DISubprogram to `fn_val` and set it as the active scope, so breakpoints / step / call
    // stack resolve to this function. Item-2 will flesh out the subroutine type with real DITypes;
    // for the line-table MVP a "void()" signature is enough for line/scope info.
    pub fn beginFunctionDebug(self: *LlvmCompiler, fn_val: types.LLVMValueRef, name: []const u8, file: []const u8, line: usize) void {
        self.di_scope = null; // reset first so a no-file function never inherits the prior scope
        self.di_scope_file = null;
        if (self.debug_enabled) self.dbg_declared.clearRetainingCapacity();
        // Clear the builder's current debug location too: instructions in a function WITHOUT a
        // DISubprogram must carry no !dbg (else the verifier rejects a location whose scope is another
        // function). This runs for every function, so cross-function contamination cannot happen.
        core.LLVMSetCurrentDebugLocation2(self.builder, null);
        // Synthetic compiler-generated "files" (<mediator-generated>, <serde-generated>, <rmediator-...>)
        // are not real source. Emitting a DISubprogram for them made lldb/VS Code try to OPEN (or create)
        // a path like `<cwd>/./<mediator-generated>` when stepping through the dispatch that every handler
        // goes through -- the crash/"tries to create a file" report. Skip debug info: generated code just
        // steps over with no source, which is correct.
        if (self.di_builder == null or file.len == 0 or file[0] == '<') return;
        self.ensureDebugCU(file);
        const dif = self.diFileFor(file) orelse return; // missing source on disk -> no debug info (steps over)
        self.di_scope_file = dif;
        var params0 = [_]types.LLVMMetadataRef{null}; // element 0 = return type (null => void)
        const subr = debug.LLVMDIBuilderCreateSubroutineType(self.di_builder, dif, &params0, 1, .LLVMDIFlagZero);
        const name_z = self.allocator.dupeZ(u8, name) catch return;
        defer self.allocator.free(name_z);
        const ln: c_uint = @intCast(if (line == 0) 1 else line);
        const sp = debug.LLVMDIBuilderCreateFunction(
            self.di_builder,
            dif,
            name_z.ptr,
            name.len,
            name_z.ptr,
            name.len,
            dif,
            ln,
            subr,
            0,
            1,
            ln,
            .LLVMDIFlagZero,
            0,
        );
        debug.LLVMSetSubprogram(fn_val, sp);
        self.di_scope = sp;
        // Initial location at the function line so prologue instructions (allocas, ARC retains)
        // carry a !dbg before the first statement updates it -- the verifier requires it on calls.
        self.setDebugLoc(line, 0);
    }

    // Set the IR builder's current debug location to (line, col) within the active function scope.
    // A no-op unless a DISubprogram scope is live. Instructions emitted after this carry the location.
    pub fn setDebugLoc(self: *LlvmCompiler, line: usize, col: usize) void {
        if (self.di_scope == null) return;
        const loc = debug.LLVMDIBuilderCreateDebugLocation(
            core.LLVMGetGlobalContext(),
            @intCast(if (line == 0) 1 else line),
            @intCast(col),
            self.di_scope,
            null,
        );
        core.LLVMSetCurrentDebugLocation2(self.builder, loc);
    }

    // Cached DIBasicType for a primitive. `encoding` is a raw DWARF DW_ATE_* value.
    fn diBasicType(self: *LlvmCompiler, name: []const u8, size_bits: u64, encoding: c_uint) types.LLVMMetadataRef {
        if (self.di_types.get(name)) |t| return t;
        const name_z = self.allocator.dupeZ(u8, name) catch return null;
        defer self.allocator.free(name_z);
        const t = debug.LLVMDIBuilderCreateBasicType(self.di_builder, name_z.ptr, name.len, size_bits, encoding, .LLVMDIFlagZero);
        self.di_types.put(name, t) catch {};
        return t;
    }

    // DIType for a local's declared type + its LLVM slot type. Item 2 slice A handles only the
    // primitives whose value is the slot itself: float (double slot) and int/bool (i64 slot). Pointer /
    // struct / string / any slots return null and stay undeclared until their DITypes + lldb formatters
    // land (items 2b/2c/3) -- better an omitted variable than one that shows a raw pointer as an int.
    // DWARF encodings: DW_ATE_boolean=2, DW_ATE_float=4, DW_ATE_signed=5.
    fn diTypeFor(self: *LlvmCompiler, type_name: ?[]const u8, slot_ty: types.LLVMTypeRef) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        const kind = core.LLVMGetTypeKind(slot_ty);
        // float / f32 / f64 all live in a DOUBLE slot -> size to the slot (64 bits), DW_ATE_float=4.
        if (kind == .LLVMDoubleTypeKind) return self.diBasicType("f64", 64, 4);
        if (kind == .LLVMIntegerTypeKind) {
            const tn = type_name orelse return null;
            if (std.mem.eql(u8, tn, "string")) return self.diStringType();
            if (types_mod.cgPrim(tn)) |p| {
                if (p.repr == .word) return null; // raw ptr -> not a displayable scalar here
                if (p.repr == .i1) return self.diBasicType("bool", 8, 2); // DW_ATE_boolean, reads low byte
                if (p.repr == .f32 or p.repr == .f64) return null; // a float never lands in an int slot
                // int-like: the value occupies the low bits of the i64 slot; DW_ATE_signed=5/unsigned=7.
                return self.diBasicType(tn, 64, if (p.signed) 5 else 7);
            }
            // A struct local: the i64 slot holds a POINTER to the heap struct. Give it a native
            // pointer-to-struct DIType so lldb / the VS Code Variables panel expand its fields with no
            // Python. Nested struct/container FIELDS still render as opaque addresses (see diFieldType);
            // the optional Python formatter enriches containers.
            const base = getStructBaseName(tn);
            // Containers (List/Map/Set) FIRST -- even though List is a struct, showing its raw data/len/cap
            // fields is useless; instead give it a NAMED pointer typedef whose name carries the element
            // type (e.g. "List<int>") so the Python synthetic-children provider can expand its elements.
            if (std.mem.eql(u8, base, "List") or std.mem.eql(u8, base, "Map") or std.mem.eql(u8, base, "Set"))
                return self.diContainerType(tn);
            // A borrowed `str.Str` local: the value struct { ptr, len } is stored INLINE in the slot, so
            // give it the inline struct type (not a pointer) -- nova_str_summary then shows its text.
            if (std.mem.eql(u8, base, "Str")) return self.diStrType();
            // A struct local: the i64 slot holds a POINTER to the heap struct. Native pointer-to-struct
            // DIType so lldb / the VS Code Variables panel expand its fields with no Python.
            if (self.structs.get(base) != null) return self.diStructType(base);
        }
        return null;
    }

    // A pointer typedef named after the container instantiation (e.g. "List<int>"), so an lldb type
    // synthetic/summary can match it by name and read elements. The pointee is opaque here.
    fn diContainerType(self: *LlvmCompiler, tn: []const u8) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get(tn)) |t| return t;
        const byte_t = self.diBasicType("u8", 8, 7);
        const ptr = debug.LLVMDIBuilderCreatePointerType(self.di_builder, byte_t, 64, 0, 0, "", 0);
        const tn_z = self.allocator.dupeZ(u8, tn) catch return null;
        defer self.allocator.free(tn_z);
        // A single-member STRUCT { ptr } named after the instantiation (e.g. "List<int>"), NOT a pointer
        // typedef. An aggregate has an empty SBValue::GetValue(), so lldb-dap shows only the summary/
        // synthetic (the element list) and drops the raw `0x…` address prefix -- same trick as `string`.
        // The Python provider reads the underlying pointer from the variable's storage (its load address).
        const member = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "ptr", "ptr".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, ptr);
        var members = [_]types.LLVMMetadataRef{member};
        const st = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, tn_z.ptr, tn.len, self.di_file, 0, 64, 0, .LLVMDIFlagZero, null, &members, 1, 0, null, "", 0);
        self.di_types.put(tn, st) catch {};
        return st;
    }

    // Nova `string` as a single-member STRUCT { data: u8* } named "string", NOT a bare pointer/typedef.
    // Why a struct and not a `char*` typedef: lldb-dap builds a variable's displayed value from
    // SBValue::GetValue(), which for ANY pointer type is the raw address -- so a pointer-typed string
    // always renders `0x… "nova"` in VS Code, address first, no matter what summary we register (this is
    // also why List/Map/Set carry an address prefix). For an AGGREGATE, GetValue() is empty, so lldb-dap
    // shows only the summary -> a clean `"nova"`, C#-style. The local's 8 bytes ARE the struct; member
    // `data` at offset 0 holds the char pointer, which the Python summary (nova_string_summary) reads via
    // child 0. Graceful degradation without the Python formatter: lldb shows `string @ <addr>` and the
    // `data` child still renders the text natively (unsigned char* -> "nova"), one expand away. Cached.
    fn diStringType(self: *LlvmCompiler) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get("string")) |t| return t;
        const byte_t = self.diBasicType("u8", 8, 7);
        const datap = debug.LLVMDIBuilderCreatePointerType(self.di_builder, byte_t, 64, 0, 0, "", 0);
        const member = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "data", "data".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, datap);
        var members = [_]types.LLVMMetadataRef{member};
        const strtd = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, "string", "string".len, self.di_file, 0, 64, 0, .LLVMDIFlagZero, null, &members, 1, 0, null, "", 0);
        self.di_types.put("string", strtd) catch {};
        return strtd;
    }

    // DIType for a struct FIELD, by type name. Primitives + string get real value types; nested structs
    // and everything else (decimal/containers/optionals) render as an opaque pointer (address only) --
    // keeps this non-recursive and cycle-safe for the first cut.
    // Create a DIBasicType WITHOUT the di_types name-cache. Needed for struct fields: the same display
    // name (e.g. "int") is a 64-bit local slot but a 32-bit field, and a name-keyed cache would hand one
    // the other's width. LLVM uniques DIBasicTypes by content, so skipping our cache costs nothing.
    fn diBasicTypeUncached(self: *LlvmCompiler, name: []const u8, size_bits: u64, encoding: c_uint) types.LLVMMetadataRef {
        const name_z = self.allocator.dupeZ(u8, name) catch return null;
        defer self.allocator.free(name_z);
        return debug.LLVMDIBuilderCreateBasicType(self.di_builder, name_z.ptr, name.len, size_bits, encoding, .LLVMDIFlagZero);
    }

    // DIType for a struct FIELD. Unlike a local (which sits in a 64-bit slot), a field is stored at its
    // REAL width inside the heap struct, so the basic type must be sized to getTypeSize(tn)*8 -- a
    // 32-bit `int` field declared as 64-bit makes lldb read 8 bytes and swallow the next field.
    // Nova `str.Str` is a BORROWED string view: a value struct { ptr: long @0, len: int @8 } pointing into
    // some backing buffer (e.g. a DB row), NOT NUL-terminated. Emit it as a real inline struct so its
    // fields read correctly; the Python formatter's nova_str_summary reads ptr+len and shows the text. This
    // is the pervasive text type in ORM-backed views (every borrowed column), so without this a struct's
    // text fields show a raw pointer number instead of their contents. Cached.
    fn diStrType(self: *LlvmCompiler) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get("Str")) |t| return t;
        const long_t = self.diBasicType("long", 64, 5); // DW_ATE_signed
        const int_t = self.diBasicType("int", 32, 5);
        const m_ptr = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "ptr", "ptr".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, long_t);
        const m_len = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "len", "len".len, self.di_file, 0, 32, 0, 64, .LLVMDIFlagZero, int_t);
        var body_members = [_]types.LLVMMetadataRef{ m_ptr, m_len };
        const body = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, "StrData", "StrData".len, self.di_file, 0, 128, 0, .LLVMDIFlagZero, null, &body_members, 2, 0, null, "", 0);
        // Str is NOT stored inline (fieldStoredInline("Str") == false -- the escape analysis keeps it on the
        // heap), so a Str field/local is an 8-byte POINTER to the { ptr, len } payload. Wrap that pointer in
        // a single-member STRUCT named "Str" (an aggregate, empty GetValue()) so lldb-dap shows only the
        // summary -- clean `"Alpha"`, no `0x…` prefix, consistent with string/List/Map/Set. nova_str_summary
        // reads the object pointer from the variable's storage, then ptr/len from the payload.
        const objp = debug.LLVMDIBuilderCreatePointerType(self.di_builder, body, 64, 0, 0, "", 0);
        const m_obj = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "obj", "obj".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, objp);
        var members = [_]types.LLVMMetadataRef{m_obj};
        const st = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, "Str", "Str".len, self.di_file, 0, 64, 0, .LLVMDIFlagZero, null, &members, 1, 0, null, "", 0);
        self.di_types.put("Str", st) catch {};
        return st;
    }

    fn diFieldType(self: *LlvmCompiler, tn: []const u8, f_size: u32) types.LLVMMetadataRef {
        if (std.mem.eql(u8, tn, "string")) return self.diStringType();
        if (std.mem.eql(u8, getStructBaseName(tn), "Str")) return self.diStrType();
        if (types_mod.cgPrim(tn)) |p| {
            const bits: u64 = if (f_size == 0) 64 else @as(u64, f_size) * 8;
            if (p.repr == .i1) return self.diBasicTypeUncached("bool", bits, 2);
            if (p.repr == .f32 or p.repr == .f64) return self.diBasicTypeUncached(tn, bits, 4);
            if (p.repr == .word) return self.diBasicTypeUncached("uptr", 64, 7);
            return self.diBasicTypeUncached(tn, bits, if (p.signed) 5 else 7);
        }
        return self.diBasicTypeUncached("uptr", 64, 7); // opaque: show the address
    }

    // A pointer-to-struct DIType with a member per field (name, DIType, byte offset), so lldb natively
    // shows `(T) x = { field = value, ... }`. Field offsets mirror getFieldOffset (aligned, getTypeSize).
    // Cached by base name; struct-typed fields are shown as opaque pointers (see diFieldType) so this is
    // non-recursive and cannot cycle.
    fn diStructType(self: *LlvmCompiler, base: []const u8) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get(base)) |t| return t;
        const s = self.structs.get(base) orelse return null;
        var members: std.ArrayListUnmanaged(types.LLVMMetadataRef) = .empty;
        defer members.deinit(self.allocator);
        var offset: u32 = 0;
        for (s.fields) |field| {
            const f_size = self.getTypeSize(field.type_name, true);
            const f_align = self.getTypeAlign(field.type_name);
            if (f_align != 0) offset = (offset + f_align - 1) / f_align * f_align;
            // Not freed: typeRefToString's ownership via substTypeParams is ambiguous, and diStructType is
            // cached (runs once per struct type), so the leak is a few bytes in a short-lived compiler.
            const fname = self.typeRefToString(field.type_name) catch "";
            // Pass the SAME f_size used for the member offset/size, so the field's basic-type width can't
            // diverge from its slot (getTypeSize("int") the string returns the 8-byte slot size, but the
            // packed field is f_size bytes -- a mismatch made lldb read 8 bytes and swallow the next field).
            const f_di = self.diFieldType(fname, f_size);
            const nm_z = self.allocator.dupeZ(u8, field.name) catch continue;
            defer self.allocator.free(nm_z);
            const m = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, nm_z.ptr, field.name.len, self.di_file, 0, @as(u64, f_size) * 8, 0, @as(u64, offset) * 8, .LLVMDIFlagZero, f_di);
            members.append(self.allocator, m) catch {};
            offset += f_size;
        }
        const base_z = self.allocator.dupeZ(u8, base) catch return null;
        defer self.allocator.free(base_z);
        const st = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, base_z.ptr, base.len, self.di_file, 0, @as(u64, offset) * 8, 0, .LLVMDIFlagZero, null, members.items.ptr, @intCast(members.items.len), 0, null, "", 0);
        // The local holds a POINTER to the heap struct; typedef the pointer to the struct name so lldb
        // reports `(T)` and expands the fields.
        const ptr = debug.LLVMDIBuilderCreatePointerType(self.di_builder, st, 64, 0, 0, "", 0);
        const td = debug.LLVMDIBuilderCreateTypedef(self.di_builder, ptr, base_z.ptr, base.len, self.di_file, 0, self.di_cu, 0);
        self.di_types.put(base, td) catch {};
        return td;
    }

    // Emit a DILocalVariable + llvm.dbg.declare so `frame variable` / hover shows this local's real
    // value. `storage` is the variable's alloca. No-op unless a debug scope is active and the declared
    // type is a supported primitive.
    pub fn declareLocalVar(self: *LlvmCompiler, storage: types.LLVMValueRef, name: []const u8, type_name: ?[]const u8, slot_ty: types.LLVMTypeRef) void {
        if (self.di_scope == null or self.di_builder == null) return;
        if (self.dbg_declared.contains(name)) return; // one DILocalVariable per name per function
        const dtype = self.diTypeFor(type_name, slot_ty) orelse return;
        self.dbg_declared.put(name, {}) catch {};
        const name_z = self.allocator.dupeZ(u8, name) catch return;
        defer self.allocator.free(name_z);
        const v = debug.LLVMDIBuilderCreateAutoVariable(self.di_builder, self.di_scope, name_z.ptr, name.len, self.di_scope_file, 0, dtype, 0, .LLVMDIFlagZero, 0);
        const expr = debug.LLVMDIBuilderCreateExpression(self.di_builder, null, 0);
        var loc = core.LLVMGetCurrentDebugLocation2(self.builder);
        if (loc == null) loc = debug.LLVMDIBuilderCreateDebugLocation(core.LLVMGetGlobalContext(), 1, 0, self.di_scope, null);
        const bb = core.LLVMGetInsertBlock(self.builder);
        _ = debug.LLVMDIBuilderInsertDeclareRecordAtEnd(self.di_builder, storage, v, expr, loc, bb);
    }

    // Sanitize + resolve debug metadata for `module` before it is verified/emitted. Runs per emitted
    // module, so it must operate on the passed module (which under T6 split is a per-file CLONE), not
    // self.module. A function DECLARATION (no basic blocks) must NOT carry a DISubprogram definition --
    // the verifier rejects it ("declaration may only have a unique !dbg attachment"). We attach the
    // subprogram when a body is emitted, but under T6 split a function defined in another file appears
    // here as an external declaration still carrying its subprogram; strip it. LLVMDIBuilderFinalize
    // resolves temporary MD in the original module and is a harmless no-op on the clones.
    pub fn finalizeDebug(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
        const dib = self.di_builder orelse return;
        var f = core.LLVMGetFirstFunction(module);
        while (f != null) : (f = core.LLVMGetNextFunction(f)) {
            if (core.LLVMCountBasicBlocks(f) == 0 and debug.LLVMGetSubprogram(f) != null) {
                debug.LLVMSetSubprogram(f, null);
            }
        }
        // Finalize EXACTLY ONCE. emitModule runs per emitted module (97x under T6 split), but
        // LLVMDIBuilderFinalize must be called once -- repeated calls double-free the DIBuilder's
        // temporary nodes (malloc "tiny_free_list_remove_ptr" heap corruption on multi-file builds).
        if (!self.di_finalized) {
            debug.LLVMDIBuilderFinalize(dib);
            self.di_finalized = true;
        }
    }

    pub fn deinit(self: *LlvmCompiler) void {
        if (self.debug_enabled) {
            self.di_files.deinit();
            self.di_types.deinit();
            self.dbg_declared.deinit();
        }
        core.LLVMDisposeBuilder(self.builder);
        core.LLVMDisposeModule(self.module);
        target_machine.LLVMDisposeTargetMachine(self.target_machine);
        // param_names is allocated ONCE per method and SHARED across all its instantiations' FunctionInfos,
        // so freeing per-FunctionInfo double-frees the same array. Dedup by pointer identity. (Under the old
        // arena, free() was a no-op so this was harmless; under a real allocator it is a double-free.)
        {
            var freed = std.AutoHashMap(usize, void).init(self.allocator);
            defer freed.deinit();
            for (self.functions.items) |func| {
                if (func.param_names.len == 0) continue;
                const key = @intFromPtr(func.param_names.ptr);
                if (freed.contains(key)) continue;
                freed.put(key, {}) catch {};
                self.allocator.free(func.param_names);
            }
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
        self.decimal_globals.deinit();
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
    pub const valueOptionalName = types_mod.valueOptionalName;

    pub fn closureKey(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8) ![]const u8 {
        return self.closureKeyM(span, inst, self.closureKeyActiveInstId());
    }

    // SE-C: the instantiation discriminator for closure keys is now the TypeId inst_key (which encodes BOTH
    // the receiver's struct-T and the method's <U>), not the string method_subst. Sourced consistently at
    // registration (current_collecting_instantiation_id) and lookup (current_instantiation_id), both from
    // the same FunctionInfo.instantiation_id, so the keys still match -- and it is a strictly stronger
    // discriminator than the old name=concrete signature.
    fn closureKeyActiveInstId(self: *LlvmCompiler) ?sema_types.TypeId {
        return self.current_collecting_instantiation_id orelse self.current_instantiation_id;
    }

    pub fn closureKeyM(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8, inst_id: ?sema_types.TypeId) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}|{s}|{d}", .{
            getClosureUniqueId(span),
            inst orelse "",
            if (inst_id) |id| @intFromEnum(id) else 0,
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

        // Reserve one extra byte for a NUL terminator (chars array is len+1) so the debugger's built-in
        // char* view + C-FFI read the string without Python formatters. The len field stays the logical
        // length; the trailing NUL is padding beyond it.
        var field_types = [_]types.LLVMTypeRef{ self.i32_type, self.i32_type, core.LLVMArrayType(self.i8_type, @intCast(unescaped.len + 1)) };
        const struct_type = core.LLVMStructType(&field_types, 3, 1);

        const global_var = core.LLVMAddGlobal(self.module, struct_type, "str_literal");
        core.LLVMSetGlobalConstant(global_var, 0);
        core.LLVMSetLinkage(global_var, types.LLVMLinkage.LLVMInternalLinkage);

        const str_z = try self.allocator.dupeZ(u8, unescaped);
        defer self.allocator.free(str_z);
        // Immortal constant: a NEGATIVE refcount makes nova_retain/nova_release full no-ops (both early-return
        // on `*rc < 0`). The old value was +100000000, which is NOT immortal -- it was decremented on every
        // use (a literal is stored without a matching retain but released on drop), so a string literal reused
        // >1e8 times drifted the count to zero, freed the shared global, and double-freed -> SIGABRT. A
        // negative sentinel never drifts and never frees, and it also skips the per-use ARC inc/dec entirely.
        const ref_const = core.LLVMConstInt(self.i32_type, @as(c_ulonglong, @bitCast(@as(i64, -1000000000))), 0);
        const len_const = core.LLVMConstInt(self.i32_type, @intCast(unescaped.len), 0);
        const chars_const = core.LLVMConstString(str_z.ptr, @intCast(unescaped.len), 0); // 0 => append a NUL (len+1 bytes)

        var field_values = [_]types.LLVMValueRef{ ref_const, len_const, chars_const };
        const init_const = core.LLVMConstStruct(&field_values, 3, 1);
        core.LLVMSetInitializer(global_var, init_const);

        const dup_str = try self.allocator.dupe(u8, str);
        try self.string_globals.put(dup_str, global_var);

        const chars_ptr = core.LLVMBuildStructGEP2(self.builder, struct_type, global_var, 2, "chars_ptr");
        return core.LLVMBuildPtrToInt(self.builder, chars_ptr, self.val_type, "str_ptr_int");
    }

    // A decimal literal (`0m`, `2m`, ...) used to lower to an unconditional nova_decimal_from_string call --
    // a heap alloc + ASCII parse on EVERY evaluation. In hot paths (e.g. every DbValue carries a `0m`
    // placeholder) that is thousands of throwaway allocations per request. This interns each distinct literal
    // to a lazily-initialised global: the parse+alloc runs once, and every later use is a load + a predicted
    // branch. The cached value is pinned immortal (negative refcount) so sharing it across owners is safe --
    // nova_retain/nova_release early-return on `*rc < 0`, so it never drifts or frees.
    pub fn getOrCreateDecimalLiteral(self: *LlvmCompiler, digits: []const u8) anyerror!types.LLVMValueRef {
        const cache_g = if (self.decimal_globals.get(digits)) |g| g else blk: {
            const g = core.LLVMAddGlobal(self.module, self.val_type, "dec_cache");
            core.LLVMSetLinkage(g, types.LLVMLinkage.LLVMInternalLinkage);
            core.LLVMSetInitializer(g, core.LLVMConstInt(self.val_type, 0, 0));
            const dup = try self.allocator.dupe(u8, digits);
            try self.decimal_globals.put(dup, g);
            break :blk g;
        };

        const from_fn = self.func_map.get("nova_decimal_from_string").?;
        const from_t = core.LLVMGlobalGetValueType(from_fn);

        const cur_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const entry_bb = core.LLVMGetInsertBlock(self.builder);
        const init_bb = core.LLVMAppendBasicBlock(cur_fn, "dec_init");
        const cont_bb = core.LLVMAppendBasicBlock(cur_fn, "dec_cont");

        const cached = core.LLVMBuildLoad2(self.builder, self.val_type, cache_g, "dec_cached");
        const is_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, cached, core.LLVMConstInt(self.val_type, 0, 0), "dec_uninit");
        _ = core.LLVMBuildCondBr(self.builder, is_zero, init_bb, cont_bb);

        // init_bb: parse once, pin immortal, cache.
        core.LLVMPositionBuilderAtEnd(self.builder, init_bb);
        const dz = try self.allocator.dupeZ(u8, digits);
        defer self.allocator.free(dz);
        const str_global = core.LLVMBuildGlobalString(self.builder, dz.ptr, "dec_lit");
        const str_ptr = core.LLVMBuildBitCast(self.builder, str_global, self.ptr_type, "dec_lit_ptr");
        var args = [_]types.LLVMValueRef{str_ptr};
        const parsed = core.LLVMBuildCall2(self.builder, from_t, from_fn, &args, 1, "dec_parse_once");
        // Pin: *(i32*)(parsed - 8) = -1000000000  => immortal to ARC (safe whether arena- or malloc-backed).
        const hdr_addr = core.LLVMBuildSub(self.builder, parsed, core.LLVMConstInt(self.val_type, 8, 0), "dec_hdr_addr");
        const hdr_ptr = core.LLVMBuildIntToPtr(self.builder, hdr_addr, self.ptr_type, "dec_hdr_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i32_type, @as(c_ulonglong, @bitCast(@as(i64, -1000000000))), 0), hdr_ptr);
        _ = core.LLVMBuildStore(self.builder, parsed, cache_g);
        _ = core.LLVMBuildBr(self.builder, cont_bb);
        const init_end_bb = core.LLVMGetInsertBlock(self.builder);

        // cont_bb: phi of the cached-or-just-parsed value.
        core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
        const phi = core.LLVMBuildPhi(self.builder, self.val_type, "dec_val");
        var inc_vals = [_]types.LLVMValueRef{ cached, parsed };
        var inc_bbs = [_]types.LLVMBasicBlockRef{ entry_bb, init_end_bb };
        core.LLVMAddIncoming(phi, &inc_vals, &inc_bbs, 2);
        return phi;
    }

    pub const compileRetain = arc_mod.compileRetain;
    pub const errUnionParts = arc_mod.errUnionParts;
    pub const buildErrUnion = arc_mod.buildErrUnion;
    pub const compileRelease = arc_mod.compileRelease;
    pub const elideBorrowedArc = arc_mod.elideBorrowedArc;
    pub const verifyArcBalance = arc_mod.verifyArcBalance;
    pub const arcCensusBefore = arc_mod.arcCensusBefore;
    pub const arcCensusAfter = arc_mod.arcCensusAfter;
    pub const getOrCreateDestructor = arc_mod.getOrCreateDestructor;
    pub const getOrCreateTraitDestructor = arc_mod.getOrCreateTraitDestructor;
    pub const getOrCreateDestructorByTypeId = arc_mod.getOrCreateDestructorByTypeId;
    pub const getOrCreateDestructorPreferId = arc_mod.getOrCreateDestructorPreferId;
    pub const releaseLocalVariables = arc_mod.releaseLocalVariables;
    pub const releaseLocalByName = arc_mod.releaseLocalByName;
    pub const dropValueStruct = arc_mod.dropValueStruct;
    pub const substituteFieldType = arc_mod.substituteFieldType;
    pub const substTypeParams = arc_mod.substTypeParams;
    pub const substMethodParams = types_mod.substMethodParams;
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
            // A NESTED value-optional (`(int | undefined) | undefined`, produced only through generics,
            // e.g. `Map<K, int | undefined>.get()`): the inner is itself a value-optional, so the whole
            // thing is a value-optional whose payload is the inner box. Recursing lets the box/unbox seam
            // add/remove exactly one level per site, so present-holding-undefined (inner 0) stays distinct
            // from absent (outer 0). See A-nested in final-beta-readiness.md.
            .optional => if (self.valueOptionalInner(info.optional) != null) info.optional else null,
            else => null,
        };
    }

    // How many value-optional levels wrap this type (0 = not a value-optional, 1 = `int | undefined`,
    // 2 = `(int | undefined) | undefined`). Each level is one heap box, so the depth is the number of
    // box/unbox peels between two value-optional representations.
    pub fn valoptDepth(self: *LlvmCompiler, tid: sema_types.TypeId) usize {
        var d: usize = 0;
        var cur = tid;
        while (self.valueOptionalInner(cur)) |inner| {
            d += 1;
            cur = inner;
        }
        return d;
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

    pub fn buildAnyBox(self: *LlvmCompiler, payload: types.LLVMValueRef, dtor: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const f = if (self.func_map.get("nova_any_box")) |g| g else blk: {
            var at = [_]types.LLVMTypeRef{ self.val_type, self.val_type };
            const ft = core.LLVMFunctionType(self.val_type, &at, 2, 0);
            const g = core.LLVMAddFunction(self.module, "nova_any_box", ft);
            try self.func_map.put("nova_any_box", g);
            break :blk g;
        };
        const ft = core.LLVMGlobalGetValueType(f);
        var args = [_]types.LLVMValueRef{ payload, dtor };
        return core.LLVMBuildCall2(self.builder, ft, f, &args, 2, "any_box");
    }

    pub fn buildAnyUnbox(self: *LlvmCompiler, box: types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const f = if (self.func_map.get("nova_any_unbox")) |g| g else blk: {
            var at = [_]types.LLVMTypeRef{self.val_type};
            const ft = core.LLVMFunctionType(self.val_type, &at, 1, 0);
            const g = core.LLVMAddFunction(self.module, "nova_any_unbox", ft);
            try self.func_map.put("nova_any_unbox", g);
            break :blk g;
        };
        const ft = core.LLVMGlobalGetValueType(f);
        var args = [_]types.LLVMValueRef{box};
        return core.LLVMBuildCall2(self.builder, ft, f, &args, 1, "any_unbox");
    }

    // Widen a value of `src_expr` into an owning `any` carrier. A heap payload is retained when the source
    // is a live borrow (an owned temp transfers its ref to the box); the box records the payload's
    // destructor so dropping the `any` releases the payload.
    pub fn coerceToAny(self: *LlvmCompiler, val: types.LLVMValueRef, src_expr: *const ast.Expression) anyerror!types.LLVMValueRef {
        const payload = self.coerceToSlotType(val, self.val_type);
        const src_name = (try self.resolveExpressionTypeName(src_expr)) orelse "";
        if (std.mem.eql(u8, src_name, "any")) return payload; // already a carrier
        var dtor = core.LLVMConstInt(self.val_type, 0, 0);
        const src_tid = self.typeOfExprConcrete(src_expr);
        // M-1: a VALUE struct has no heap identity -- `payload` is a STACK alloca address that the
        // any-box would outlive (case 123: use-after-return). Heap-promote it: copy the struct into a
        // fresh ARC-headed heap block and box THAT, with the struct's own destructor. Its owned fields
        // are now aliased by the original local and the heap copy, so retain them in the copy (the
        // local still drops its own copy at scope end; the box's nova_release drops the heap copy's).
        const is_vstruct = if (src_tid) |t| self.isValueStructTid(t) else self.isValueStructName(src_name);
        if (is_vstruct) {
            var vname = src_name;
            if (vname.len == 0) {
                if (src_tid) |t| vname = sema_shadow.renderLegacy(self.allocator, self.type_store.?, t) catch "";
            }
            const vsz = self.getTypeSize(ast.TypeRef{ .ident = types_mod.getStructBaseName(vname) }, false);
            const heap_ptr = try self.compileAlloc(core.LLVMConstInt(self.val_type, if (vsz == 0) 8 else vsz, 0));
            _ = try self.buildValueStructCopyInto(heap_ptr, payload, vsz);
            try self.retainValueStructOwnedFields(heap_ptr, vname);
            if (try self.getOrCreateDestructorPreferId(vname, src_tid)) |dfn| {
                dtor = core.LLVMBuildPtrToInt(self.builder, dfn, self.val_type, "any_dtor");
            }
            const box_vs = try self.buildAnyBox(heap_ptr, dtor);
            try self.registerTemporary(box_vs, "any");
            return box_vs;
        }
        const heap = if (src_tid) |t| self.type_store.?.isOwnedSafe(t) else self.ownedByName(src_name);
        if (heap) {
            if (try self.getOrCreateDestructorPreferId(src_name, src_tid)) |dfn| {
                dtor = core.LLVMBuildPtrToInt(self.builder, dfn, self.val_type, "any_dtor");
            }
            const is_borrow = src_expr.kind == .ident or src_expr.kind == .field_access or src_expr.kind == .index;
            if (is_borrow) {
                try self.compileRetain(payload);
            } else {
                self.consumeTemporary(payload);
            }
        }
        const box = try self.buildAnyBox(payload, dtor);
        // The box is a fresh owned temporary (rc=1). Register it so a call that stores it (and retains)
        // has its extra caller-side reference released at statement end; a let-init that takes ownership
        // consumes this registration instead (see the widen path in statements.zig).
        try self.registerTemporary(box, "any");
        return box;
    }

    pub fn valoptTypeRefIsValue(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        // B3 (string-engine-removal): resolve the inner through the CURRENT instantiation so a
        // `T | undefined` parameter decides value-vs-reference on its CONCRETE argument, not on the
        // unresolved type-parameter. concreteTidForTypeRef applies the instantiation overlay and
        // symbolName renders that concrete id (the sanctioned TypeId->name boundary); this drops the
        // former dependence on typeRefToString -> substMethodParams (the deletable string engine). The
        // declared-TypeRef string render survives ONLY as the fallback when no concrete id is recoverable
        // -- a genuinely erased body, where a bare type-param inner is not a value-prim and so is not
        // boxed either way, matching this path. Gating case: 119_generic_return (maybe<int> must box).
        const inner = blk: {
            if (self.concreteTidForTypeRef(tr.optional.*)) |itid| {
                break :blk self.symbolName(itid) catch (self.typeRefToString(tr.optional.*) catch return false);
            }
            break :blk self.typeRefToString(tr.optional.*) catch return false;
        };
        if (std.mem.eql(u8, inner, "ptr")) return false;
        if (types_mod.cgPrim(inner) != null) return true;
        // A NESTED value-optional return (`(int | undefined) | undefined`, produced only through generics,
        // e.g. `Map<K, int | undefined>.get()`): the inner is itself a value-optional name, so the outer
        // level is boxed like any value-optional. The outer box BORROWS the inner box (its dtor is the plain
        // value-optional NULL dtor, it does NOT free the inner) -- the container owns the inner box and frees
        // it on drop (see buildStorageDestructor / f6e7b86), and the consuming `??` peel retains a ref for the
        // bound local. So no owner double-frees. See A-nested in final-beta-readiness.md.
        if (valueOptionalName(inner)) return true;

        const base = getStructBaseName(inner);
        if (self.enums.contains(base) and !arc_mod.enumIsTaggedUnion(self, base)) return true;
        return false;
    }

    // Is this TypeRef a NESTED value-optional (`(int | undefined) | undefined`)? i.e. an optional whose
    // inner type is itself a value-optional. Used to force the outer box on return even when the returned
    // expression already yields the inner value-optional box (which normally suppresses re-boxing).
    pub fn valoptTypeRefIsNested(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        const inner = self.typeRefToString(tr.optional.*) catch return false;
        return valueOptionalName(inner);
    }

    // Does a generic method's parameter (declared as the receiver struct's type parameter, e.g.
    // `value: T` on `List<T>.push`) resolve, for THIS receiver instance, to a value-optional element
    // type (`int | undefined`)? Routes through the receiver's TypeId arguments (which preserve
    // optionality) rather than the substituted param string (typeRefToString drops `.optional`).
    // `param_idx` is the call-argument index (self excluded).
    // True when `arg` is a bare identifier whose local slot is a value-optional. Passing such an ident to
    // a method argument must keep the BOX intact (the speculative ident-unbox must not fire): a generic
    // container parameter's value-optional type arg is collapsed by monomorphisation, so the callee-param
    // signal is unreliable, but the arg's own slot type is authoritative. Narrowing a value-optional to a
    // bare parameter requires an explicit `?? d` at the call site, so the bare ident never legitimately
    // needs unboxing here.
    pub fn argIsValoptLocal(self: *LlvmCompiler, arg: *const ast.Expression) bool {
        if (arg.kind != .ident) return false;
        const ids = self.current_local_type_ids orelse return false;
        const slot_tid = ids.get(arg.kind.ident) orelse return false;
        return self.valueOptionalInner(slot_tid) != null;
    }

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
            // `await f()` where f returns a value-optional yields the boxed representation, exactly like
            // a plain call; without this a consuming `?? d` (or comparison) would treat the box pointer
            // as the raw value and return garbage (silent corruption on every async optional API).
            // `try`/`catch` over a `T | undefined | E` yield the value-optional ok arm (a box) too, so a
            // consuming `?? d` must unbox it rather than return the raw pointer (F1).
            .ident, .field_access, .call, .generic_call, .index, .optional_chaining, .await_expr, .catch_expr, .try_expr => true,
            // A NESTED value-optional peeled by `??` (`let inner = g ?? undefined` where
            // `g : (int | undefined) | undefined`) yields the INNER value-optional box, itself a
            // value-optional. Whitelisting it lets a further consumer unbox exactly one level rather than
            // double-boxing the already-boxed inner. Gated by the value-optional type check above, so a plain
            // `x ?? 0` yielding a raw `int` is unaffected.
            .nullish_coalesce => true,
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

    // A `struct` (value type) FIELD is stored INLINE by value (Swift's value-type model), so it takes its
    // full size; a `class` (reference) field is an 8-byte pointer. This is the single decision that makes
    // nested value structs deep-copy for free (a flat memcpy of the parent copies the inline bytes).
    pub fn fieldStoredInline(self: *LlvmCompiler, base: []const u8) bool {
        // A field is stored INLINE only if its type is a VALUE-LOWERED struct -- i.e. the ESCAPE-AWARE
        // predicate, not is_reference alone. A struct the escape analysis keeps on the heap (e.g. `Aes`,
        // returned as a bare local; or a `class`) is a POINTER field. Using is_reference here would inline a
        // heap-kept struct while the rest of codegen (isValueStructName) treats it as a pointer -> layout
        // mismatch and corruption (the aes.gcm null-skey crash). This keeps the inline decision consistent.
        return self.isValueStructName(base);
    }

    // Natural alignment of a type used as a field: a scalar aligns to its width; an inline value struct to
    // the max of its fields' alignments; a pointer (class/string/other) to 8. Kept separate from getTypeSize
    // because an inline struct's SIZE is the sum of its fields but its ALIGNMENT is only the widest field.
    pub fn getTypeAlign(self: *LlvmCompiler, type_ref: ast.TypeRef) u32 {
        switch (type_ref) {
            .ident => |name| {
                if (types_mod.cgPrim(name)) |p| return switch (p.repr) {
                    .i1, .i8 => 1,
                    .i16 => 2,
                    .i32, .f32 => 4,
                    .word, .i64, .f64 => 8,
                };
                const base = getStructBaseName(name);
                if (self.fieldStoredInline(base)) {
                    const s = self.structs.get(base).?;
                    var a: u32 = 1;
                    for (s.fields) |f| {
                        const fa = self.getTypeAlign(f.type_name);
                        if (fa > a) a = fa;
                    }
                    return a;
                }
                return 8;
            },
            else => return 8,
        }
    }

    pub fn getTypeSize(self: *LlvmCompiler, type_ref: ast.TypeRef, is_field: bool) u32 {
        switch (type_ref) {
            .generic => |g| {
                if (is_field) return 8;
                const base = getStructBaseName(g.name);
                if (self.structs.get(base)) |s| return self.structPayloadSize(s);
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
                    // As a FIELD: a value struct is stored inline (its full size); a class is a pointer (8).
                    if (is_field and !self.fieldStoredInline(base)) return 8;
                    return self.structPayloadSize(s);
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

    // Total inline payload size of a struct: each field placed at its natural alignment, size summed, then
    // the whole rounded up to the struct's own alignment (so an array/inline-nesting of the struct stays
    // aligned -- matches C/Swift struct layout).
    fn structPayloadSize(self: *LlvmCompiler, s: ast.StructDecl) u32 {
        var size: u32 = 0;
        var struct_align: u32 = 1;
        for (s.fields) |f| {
            const f_size = self.getTypeSize(f.type_name, true);
            const f_align = self.getTypeAlign(f.type_name);
            if (f_align > struct_align) struct_align = f_align;
            size = (size + f_align - 1) / f_align * f_align;
            size += f_size;
        }
        size = (size + struct_align - 1) / struct_align * struct_align;
        return size;
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
            const f_align = self.getTypeAlign(field.type_name);
            offset = (offset + f_align - 1) / f_align * f_align;
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
        // C7 fail-closed: a non-vararg function called with the wrong argument count used to build a
        // malformed LLVM call (extra args passed, or fewer than the signature) which either fails
        // verification or is silent UB. Sema must have caught a real arity error long before codegen, so
        // reaching here with a mismatch on a fixed-arity function is a COMPILER bug -- surface it loudly
        // instead of emitting a broken call.
        if (core.LLVMIsFunctionVarArg(fn_t) == 0 and args.len != param_count) {
            const name = std.mem.span(core.LLVMGetValueName(fn_val));
            std.debug.print(
                "\x1b[1m\x1b[31mcompiler error:\x1b[0m\x1b[1m call built with {d} argument(s) for a function taking {d}\x1b[0m\n" ++
                "  '{s}' has a fixed arity; codegen must not emit a call with a different count. This is a\n" ++
                "  COMPILER bug (sema should have rejected the arity), not user code. Please report.\n",
                .{ args.len, param_count, if (name.len == 0) "<anonymous>" else name },
            );
            std.debug.print("(compilation failed)\n", .{});
            std.process.exit(70);
        }
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
        // Return a BORROWED cache-owned pointer (the cache is freed at compiler deinit); callers never free it.
        // Returning a fresh per-call dup instead leaked one allocation on EVERY call -- and this is called
        // millions of times during codegen, so it accumulated to tens of GB on a large build.
        if (self.param_type_str_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached; // borrowed
        }
        const result = self.getFunctionParamTypeUncached(func_name, param_idx);
        // Cache OWNS an independent copy and we return THAT (borrowed). `result` may be owned (typeRefToString)
        // or borrowed (AST s.name) -- we can't tell, so we don't free it; it leaks at most once per distinct
        // (func,param) key (bounded to thousands), never per-call.
        const stored: ?[]const u8 = if (result) |r| (self.allocator.dupe(u8, r) catch null) else null;
        self.param_type_str_cache.put(key, stored) catch {
            if (stored) |s| self.allocator.free(s);
            self.allocator.free(key);
            return stored; // borrowed
        };
        return stored; // borrowed
    }

    fn getFunctionParamTypeUncached(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?[]const u8 {
        for (self.program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| {
                    var name = f.name;
                    var name_owned = false;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        defer self.allocator.free(mod_prefix); // getModulePrefix returns owned memory
                        if (!LlvmCompiler.isAlreadyNamespaced(f.name)) {
                            name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, f.name }) catch return null;
                            name_owned = true;
                        }
                    }
                    defer if (name_owned) self.allocator.free(name); // temp only used for the comparison
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
                    // instantiationsOf returns an OWNED slice (its ?[]const u8 elements are borrowed). It
                    // depends only on `s`, so compute it ONCE per struct, free it, and reuse across methods --
                    // computing+leaking it per method was O(structs*methods) leaked slices per call.
                    const insts = self.instantiationsOf(s) catch continue;
                    defer self.allocator.free(insts);
                    for (s.methods) |m| {
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            defer self.allocator.free(full_name); // methodSymbol returns owned memory
                            if (!std.mem.eql(u8, full_name, func_name)) continue;
                            if (param_idx == 0) return s.name;
                            const is_constructor = std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new");
                            const actual_idx = if (is_constructor) param_idx - 1 else param_idx;
                            if (actual_idx < m.decl.params.len) {
                                if (m.decl.params[actual_idx].type_name) |t| {
                                    // Render the param under the CALLEE's instantiation (`owner` is the angle-form
                                    // `Map<string, any>`), so a struct type-param like `V` resolves to its concrete
                                    // (`any`) even though this is reached from the caller's context. Without this the
                                    // param reads back as the bare type-param name.
                                    const saved = self.current_instantiation;
                                    self.current_instantiation = owner;
                                    defer self.current_instantiation = saved;
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
                    var name_owned = false;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        defer self.allocator.free(mod_prefix); // getModulePrefix returns owned memory
                        if (!LlvmCompiler.isAlreadyNamespaced(f.name)) {
                            name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, f.name }) catch return null;
                            name_owned = true;
                        }
                    }
                    defer if (name_owned) self.allocator.free(name);
                    if (std.mem.eql(u8, name, func_name)) {
                        if (param_idx < f.params.len) return f.params[param_idx].type_name;
                        return null;
                    }
                },
                .struct_decl => |s| {
                    const insts = self.instantiationsOf(s) catch continue; // owned slice; depends only on `s`
                    defer self.allocator.free(insts);
                    for (s.methods) |m| {
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            defer self.allocator.free(full_name); // methodSymbol returns owned memory
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

    pub fn coerceValoptArg(self: *LlvmCompiler, val: types.LLVMValueRef, arg: *const ast.Expression, param_tr_opt: ?ast.TypeRef, param_str_opt: ?[]const u8) anyerror!types.LLVMValueRef {
        // Widen an argument into an `any` parameter: box it into an owning carrier. The parameter type is
        // taken from the callee's INSTANTIATION-substituted string (`getFunctionParamType`), not the raw AST
        // ref -- so a generic `set(v: V)` on `Map<K, any>`, whose ref renders `V` but whose substituted type
        // is `any`, boxes too. The container then only ever stores real heap boxes, so its element
        // retain/release works unchanged.
        if (param_str_opt) |param_str| {
            if (std.mem.eql(u8, param_str, "any")) {
                if (!self.isAnyExpr(arg)) return try self.coerceToAny(val, arg);
                return val;
            }
        }
        const param_tr = param_tr_opt orelse return val;
        // A NESTED value-optional argument (`(int | undefined) | undefined`, e.g. from
        // `List<int | undefined>.get()`) passed to a flatter value-optional parameter: deliver a box at the
        // PARAMETER's declared depth, not the argument's. The value-optional param ABI is uniformly boxed at
        // the declared depth (the callee unboxes exactly that many levels on `??`/comparison -- see the C10
        // param-TypeId change in declarations.zig), so peel the surplus levels here. suppress_valopt_unbox
        // kept the full box through compileCallArgument (now uniform across ident/call after the save-restore
        // above), so the surplus is exactly arg_depth - param_depth. Gated on the parameter being
        // SYNTACTICALLY a value-optional, which excludes the generic-container element slot whose `T` param is
        // collapsed by monomorphisation and must keep the full box.
        if (self.valoptTypeRefIsValue(param_tr) and self.exprYieldsValoptBox(arg)) {
            if (self.typeOfExprConcrete(arg)) |arg_tid| {
                const arg_depth = self.valoptDepth(arg_tid);
                const param_depth: usize = if (self.valoptTypeRefIsNested(param_tr)) 2 else 1;
                if (arg_depth > param_depth) {
                    var out = val;
                    var n = arg_depth - param_depth;
                    while (n > 0) : (n -= 1) out = try self.buildValoptUnbox(out);
                    return out;
                }
            }
        }
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

    // True when EVERY method of `trait_name` has a concrete per-instantiation body emitted for `struct_name`
    // (e.g. `Cell_i32_render` for `Cell<i32>`). Used to decide whether constructTraitObject can build a
    // per-instantiation vtable (correct for a T-typed method) or must fall back to the erased shared vtable.
    // For a base/erased name the concrete name equals the erased name, so this returns true iff the shared
    // body exists -- i.e. the base path is unchanged.
    pub fn hasConcreteTraitMethods(self: *LlvmCompiler, struct_name: []const u8, trait_name: []const u8) !bool {
        const trait_decl = self.traits.get(getStructBaseName(trait_name)) orelse return false;
        for (trait_decl.methods) |tm| {
            const mn = try self.methodSymbol(struct_name, tm.name);
            defer self.allocator.free(mn);
            if (!self.func_map.contains(mn)) return false;
        }
        return true;
    }

    pub fn getGlobalVTable(self: *LlvmCompiler, struct_name: []const u8, trait_name: []const u8) !types.LLVMValueRef {
        // Mangle the (possibly instantiated) struct name so the vtable global has a valid symbol name and is
        // PER-INSTANTIATION: `Cell<i32>` -> `_vtable_Cell_i32_Render`, whose slots point at the concrete
        // `Cell_i32_render`. For a plain base name mangling is the identity, so base-name callers are
        // unchanged. This is what lets a generic struct with a T-typed method dispatch correctly through a
        // trait object (the erased shared body mishandled the concrete field, SEGV -- case 299).
        const mangled = try types_mod.mangleTypeName(self.allocator, struct_name);
        defer self.allocator.free(mangled);
        const base_name = try std.fmt.allocPrint(self.allocator, "_vtable_{s}_{s}", .{ mangled, trait_name });
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
            // methodSymbol mangles the (possibly instantiated) owner: `Cell<i32>` + `render` ->
            // `Cell_i32_render` (the per-instantiation body), and for a base name it equals the raw
            // `{owner}_{method}`, so base-name callers see no change.
            const method_name = try self.methodSymbol(struct_name, tm.name);
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

        // Prefer a PER-INSTANTIATION vtable when the concrete methods are emitted: `Cell<i32>` ->
        // `_vtable_Cell_i32_Render` whose slots are the concrete `Cell_i32_render`, so a T-typed method
        // dispatches correctly (case 299). Fall back to the base-erased vtable (`_vtable_Cell_Render` ->
        // `Cell_render`) only for a genuinely erased generic context where no concrete body exists.
        const vtable_global = if (try self.hasConcreteTraitMethods(struct_name, trait_name))
            try self.getGlobalVTable(struct_name, trait_name)
        else
            try self.getGlobalVTable(getStructBaseName(struct_name), trait_name);
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
                            if (self.structs.contains(getStructBaseName(struct_name))) {
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
            // Resolve a colliding enum (`Shape.Circle(x)` tagged construction) to the module-scoped enum
            // this reference's file declares, so the right variant set/tags/layout are used (S3). Used for
            // both the enum lookup and getEnumTagAndSize below.
            const obj_name = self.scopedTypeName(fa.object.kind.ident, fa.span.file);
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
                        sema_shadow.noteF45Erased(self.allocator, mono_name);
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
                                if (self.structs.contains(getStructBaseName(struct_name))) {
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
                                if (self.structs.contains(getStructBaseName(struct_name))) {
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
                    // A value-optional element parameter must receive the BOX, not a raw value. Suppress the
                    // speculative ident-unbox (which fires when the checker recorded a bare use-type for a
                    // value-optional local) so a `List<T|undefined>.push(value)` forwards the box intact.
                    const arg_param_valopt = self.methodParamIsValueOptional(fa.object, fa.field, idx) or self.argIsValoptLocal(arg);
                    self.suppress_valopt_unbox = arg_param_valopt;
                    var val = try self.compileCallArgument(arg.*);
                    self.suppress_valopt_unbox = false;
                    var widened_any = false;
                    var elem_type_name: ?[]const u8 = null;
                    if (self.getFunctionParamType(func_name, idx + 1)) |expected_type| {
                        elem_type_name = expected_type;
                        const widen_to = self.resolveParamTypeForWiden(obj_type, expected_type);
                        if (self.traits.contains(getStructBaseName(widen_to))) {
                            if (try self.resolveExpressionTypeName(arg)) |struct_name| {
                                if (self.structs.contains(getStructBaseName(struct_name))) {
                                    val = try self.constructTraitObject(val, struct_name, widen_to);
                                }
                            }
                        } else if (std.mem.eql(u8, widen_to, "any")) {
                            // Widen a value inserted into an owning `any` element slot (`Map<K, any>.set(k, v)`):
                            // box it into a `{payload, dtor}` carrier so the container stores a real heap box
                            // and its element retain/release stays uniform. The callee param resolves to `any`
                            // via the instantiation even though the generic ref is a bare type-param.
                            if (!self.isAnyExpr(arg)) {
                                val = try self.coerceToAny(val, arg);
                                widened_any = true;
                            }
                        }
                    }
                    // Box a plain value being inserted into a value-optional element slot (`List<int |
                    // undefined>.push(7)`), so the slot holds a box a later read can unbox rather than a
                    // raw value it would dereference as a pointer. `undefined` stays 0 (a box holding 0
                    // would read back as a present 0); an already-boxed value-optional is left as-is.
                    // The box is a fresh OWNED temporary: register it so its caller-side reference is
                    // released at statement end. `Storage.set` takes its OWN reference (retain-on-store) and
                    // the container frees it on drop (buildStorageDestructor), so create(+1) / set-retain(+1)
                    // balance drain(-1) / container-release(-1) -- else a `List<int|undefined>` leaks its
                    // present-value boxes.
                    if (!widened_any and !LlvmCompiler.isUndefinedLiteralExpr(arg) and !self.exprYieldsValoptBox(arg) and
                        self.methodParamIsValueOptional(fa.object, fa.field, idx))
                    {
                        val = try self.buildValoptBox(self.coerceToSlotType(val, self.val_type));
                        if (elem_type_name) |etn| try self.registerTemporary(val, try self.allocator.dupe(u8, etn));
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
                                if (self.structs.contains(getStructBaseName(struct_name))) {
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
                    .instantiation_id = self.current_collecting_instantiation_id,

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

                // A name that is a PARAMETER of the enclosing function is always a captured free variable,
                // never a global function reference. Detect it before the loose `_name` function-suffix
                // heuristic below, which otherwise matches an unrelated struct method (e.g. `RawBuffer_base`
                // for a local `base`) and wrongly drops the capture -- silently corrupting any closure over
                // a variable whose name collides with some method's suffix.
                var is_parent_param = false;
                for (self.functions.items) |pf| {
                    if (std.mem.eql(u8, pf.name, parent_name)) {
                        for (pf.param_names) |pn| {
                            if (std.mem.eql(u8, pn, name)) {
                                is_parent_param = true;
                                break;
                            }
                        }
                        break;
                    }
                }

                if (!is_parent_param) {
                    for (self.functions.items) |f| {
                        if (std.mem.eql(u8, f.name, name)) return;

                        const suffix = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});
                        defer self.allocator.free(suffix);
                        if (std.mem.endsWith(u8, f.name, suffix)) return;
                    }
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
                    // Gap 8 demand-mono gate: drop an uncalled non-constructor method of a GENERIC struct
                    // for all its instantiations (context-insensitive). No-op unless NOVA_REACH_ON.
                    if (s.type_params.len > 0 and !sema_reach.methodIsReachable(s.name, fn_decl.name)) continue;
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

                                var name_buf = std.ArrayListUnmanaged(u8).empty;
                                try name_buf.appendSlice(self.allocator, full_name);
                                for (mi.args) |an| {
                                    const ma = try types_mod.mangleTypeName(self.allocator, an);
                                    defer self.allocator.free(ma);
                                    try name_buf.appendSlice(self.allocator, "__");
                                    try name_buf.appendSlice(self.allocator, ma);
                                }
                                const spec_name = try name_buf.toOwnedSlice(self.allocator);

                                const prev_iid = self.current_instantiation_id;
                                self.current_instantiation_id = mi.inst_key;
                                const spec_ret = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void";
                                self.current_instantiation_id = prev_iid;

                                try self.functions.append(self.allocator, .{
                                    .name = spec_name,
                                    .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                                    .param_names = param_names,
                                    .return_type = spec_ret,

                                    .ret_type_ref = fn_decl.ret_type,
                                    .body = fn_decl.body,
                                    // A non-constructor method declares `self` explicitly as params[0], so the
                                    // AST params line up 1:1 with the LLVM arguments (self at index 0) and the
                                    // optimiser emit path can model them. A constructor's `self` is synthetic
                                    // (prepended above, not in fn_decl.params), so leave params empty -> the emit
                                    // path sees the count mismatch and falls back.
                                    .params = if (is_constructor) &.{} else fn_decl.params,
                                    .is_async = fn_decl.is_async,
                                    .instantiation = inst_opt,
                                    .instantiation_id = mi.inst_key,
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
                                // Non-constructor method: `self` is an explicit params[0], so params line up 1:1
                                // with the LLVM arguments and the emit path can model them. Constructor `self` is
                                // synthetic -> leave empty so the emit path falls back.
                                .params = if (is_constructor) &.{} else fn_decl.params,
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
                const e_owner = self.scopedStructName(e.name, e.span.file);
                try self.enums.put(e_owner, e);
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

                    const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ e_owner, fn_decl.name });
                    const info = FunctionInfo{
                        .name = full_name,
                        .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                        .param_names = param_names,
                        .return_type = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void",
                        .ret_type_ref = fn_decl.ret_type,
                        .body = fn_decl.body,
                        // Non-constructor method: explicit `self` params[0] lines up with the LLVM args (emit
                        // path can model it); constructor `self` is synthetic -> empty -> emit path falls back.
                        .params = if (is_constructor) &.{} else fn_decl.params,
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
                    .params = fn_decl.params, // free function: argument index i == declared param i (no self)
                    .is_async = fn_decl.is_async,
                    .source_file = fn_decl.span.file,
                };

                if (fn_decl.type_params.len == 0 or fn_decl.is_async) try self.functions.append(self.allocator, info);

                if (fn_decl.type_params.len > 0) {
                    for (sema_mono.free_fn_insts.items) |fi| {
                        if (!std.mem.eql(u8, fi.fn_name, fn_decl.name)) continue;
                        if (fi.params.len != fn_decl.type_params.len) continue;

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

                        const prev_iid2 = self.current_instantiation_id;
                        self.current_instantiation_id = fi.inst_key;
                        const spec_ret = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void";
                        self.current_instantiation_id = prev_iid2;

                        // String-engine-removal: bind this free-fn spec to its TypeId instantiation key so
                        // current_instantiation_id resolves inside its body. The sema free-fn overlay
                        // (inst_disp.runFreeFns/recordFreeFnInst) recorded tp_resolve/expr_types_inst under the
                        // SAME inst_key = .struct_{owner, args_tids}.
                        try self.functions.append(self.allocator, .{
                            .name = spec_name,
                            .param_count = fn_decl.params.len,
                            .param_names = spec_params,
                            .return_type = spec_ret,
                            .ret_type_ref = fn_decl.ret_type,
                            .body = fn_decl.body,
                            // Generic free-function spec: argument index i == declared param i (no self).
                            .params = fn_decl.params,
                            .is_async = fn_decl.is_async,
                            .instantiation_id = fi.inst_key,
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

                // B1: expose the TypeId instantiation of THIS instance so registerGenericFnInst can
                // resolve inner type-args to concrete TypeIds (not just strings) and make the transitive
                // callee TypeId-native too.
                const prev_iid = self.current_instantiation_id;
                self.current_instantiation_id = fi.inst_key;
                defer self.current_instantiation_id = prev_iid;

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

        // B1 TypeId-native path: resolve the type-args to CONCRETE TypeIds under the current instance and
        // register the callee as a TypeId-native instance (noteFreeFnInst), then record its overlay so the
        // fixpoint can resolve ITS type-params next round. Falls back to the string-only path when a TypeId
        // is not recoverable (e.g. the current instance itself has no inst_key yet).
        if (sema_shadow.live_sema) |sm| {
            if (sm.tab.findFunction(callee_fd.name)) |callee_fid| {
                var tids = try self.allocator.alloc(sema_types.TypeId, type_args.len);
                defer self.allocator.free(tids);
                var all_tid = true;
                for (type_args, 0..) |ta, idx| {
                    tids[idx] = self.concreteTidForTypeRef(ta) orelse {
                        all_tid = false;
                        break;
                    };
                }
                if (all_tid) {
                    const added = sema_mono.noteFreeFnInst(self.allocator, &sm.store, callee_fd.name, callee_fid, callee_fd.type_params, tids);
                    if (added) {
                        // The inst_key is a deterministic intern of .struct_{callee_fid, tids}, so it equals
                        // whatever noteFreeFnInst stored; record the overlay directly from what we computed.
                        const key = sm.store.intern(.{ .struct_ = .{ .decl = callee_fid, .args = tids } }) catch null;
                        @import("../../frontend/sema/inst_disp.zig").recordFreeFnInst(self.allocator, &sm.store, &sm.ir, self.program, callee_fd.name, callee_fid, tids, key);
                        return true;
                    }
                    return false;
                }
            }
        }

        return sema_mono.noteFreeFnInstStr(self.allocator, callee_fd.name, callee_fd.type_params, rendered);
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

    // If `lt` and `rt` name the SAME payload-carrying enum, return the number of 8-byte words in its box
    // (tag + max payload words) so a fixed-width structural `==` compare can be emitted; else null. Every
    // variant box for the enum is allocated at this same size and zero-padded (see getEnumTagAndSize),
    // which is what makes the fixed-width compare correct.
    pub fn payloadEnumBoxWords(self: *LlvmCompiler, lt: ?[]const u8, rt: ?[]const u8) ?u32 {
        const l = lt orelse return null;
        const r = rt orelse return null;
        if (!std.mem.eql(u8, l, r)) return null;
        const decl = self.enums.get(l) orelse return null;
        var has_payload = false;
        for (decl.variants) |v| {
            if (v.fields != null or v.type_name != null) {
                has_payload = true;
                break;
            }
        }
        if (!has_payload or decl.variants.len == 0) return null;
        var tag: u32 = 0;
        var size: u32 = 0;
        self.getEnumTagAndSize(l, decl.variants[0].name, &tag, &size) catch return null;
        return size / 8;
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
                                                } else if (v.fields) |payload_fields| {
                                                    // Tuple-form multi-payload pattern `Rect(w, h)`: bind each
                                                    // positional arg to the matching payload field.
                                                    for (call.args, 0..) |arg, i| {
                                                        if (i < payload_fields.len and arg.kind == .ident) {
                                                            try list.append(self.allocator, arg.kind.ident);
                                                        }
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
            // A `let` can live inside an NSX element's `{for}`/`{if}` block (e.g. a returned view). Descend
            // into the JSX so its locals get allocas -- without this, `{for x { let p = ..; <card/> }}`
            // fails with "variable not found" because the pre-pass never saw the `let`.
            .expr_stmt => |es| if (es.expr.kind == .jsx_element) try self.collectLocalVarNamesFromJsx(list, es.expr.kind.jsx_element),
            .return_stmt => |rs| if (rs.value) |v| if (v.kind == .jsx_element) try self.collectLocalVarNamesFromJsx(list, v.kind.jsx_element),
            else => {},
        }
    }

    fn collectLocalVarNamesFromJsx(self: *LlvmCompiler, list: *std.ArrayList([]const u8), jsx: ast.JsxElement) anyerror!void {
        for (jsx.children) |child| {
            switch (child) {
                .statement => |stmt| try self.collectLocalVarNamesFromStatement(list, stmt),
                .element => |sub| try self.collectLocalVarNamesFromJsx(list, sub),
                else => {},
            }
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
                                var stored = false;
                                if (self.typed_ir) |ir| {
                                    if (ir.typeOf(init)) |tid| {
                                        const store_tid = if (self.current_instantiation_id) |inst|
                                            (ir.typeOfInst(init.id, inst) orelse tid)
                                        else
                                            tid;
                                        // Only accept a CONCRETE id. `let s = xs.get(i)` from a desugared
                                        // `for (s in xs)` types its init as the container's type-param (`T`)
                                        // or unresolved, which is NOT a usable decision id.
                                        if (self.type_store) |st| {
                                            const k = st.get(store_tid);
                                            if (k != .unresolved and k != .type_param) {
                                                try ids.put(ls.name, store_tid);
                                                stored = true;
                                            }
                                        } else {
                                            try ids.put(ls.name, store_tid);
                                            stored = true;
                                        }
                                    }
                                }
                                // Phase 1 bridge (string->TypeId cutover): when the typed IR has no CONCRETE id
                                // for the initialiser (the generic-container element case above), round-trip
                                // the resolved NAME back to a TypeId via tidForName. This gives loop/element
                                // bindings a real TypeId so isStringExpr/isOwnedTypeId etc. work on them,
                                // instead of only the string engine being able to resolve them.
                                if (!stored) {
                                    if (self.tidForName(name)) |tid| try ids.put(ls.name, tid);
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
                                                } else if (v.fields) |payload_fields| {
                                                    // Tuple-form multi-payload pattern `Rect(w, h)`: type each
                                                    // positional binding from the matching payload field.
                                                    for (call.args, 0..) |arg, i| {
                                                        if (i < payload_fields.len and arg.kind == .ident) {
                                                            const p_type_str = try self.typeRefToString(payload_fields[i].type_name);
                                                            try map.put(arg.kind.ident, p_type_str);
                                                        }
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
            // Same as the name pass: pick up the TYPES of `let`s nested inside an NSX element's blocks.
            .expr_stmt => |es| if (es.expr.kind == .jsx_element) try self.collectLocalVarTypesFromJsx(map, es.expr.kind.jsx_element),
            .return_stmt => |rs| if (rs.value) |v| if (v.kind == .jsx_element) try self.collectLocalVarTypesFromJsx(map, v.kind.jsx_element),
            else => {},
        }
    }

    fn collectLocalVarTypesFromJsx(self: *LlvmCompiler, map: *std.StringHashMap([]const u8), jsx: ast.JsxElement) anyerror!void {
        for (jsx.children) |child| {
            switch (child) {
                .statement => |stmt| try self.collectLocalVarTypesFromStatement(map, &stmt),
                .element => |sub| try self.collectLocalVarTypesFromJsx(map, sub),
                else => {},
            }
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
    pub const cachedTypeName = types_mod.cachedTypeName;
    pub const scopedStructName = types_mod.scopedStructName;
    pub const scopedTypeName = types_mod.scopedTypeName;
    pub const isCollidingStruct = types_mod.isCollidingStruct;
    pub const isOptionalExpr = types_mod.isOptionalExpr;
    pub const typeOfExprConcrete = types_mod.typeOfExprConcrete;
    pub const isOwnedExpr = types_mod.isOwnedExpr;
    pub const isOwnedTypeId = types_mod.isOwnedTypeId;
    pub const isOwnedLocal = types_mod.isOwnedLocal;
    pub const isValueStructName = types_mod.isValueStructName;
    pub const isValueStructTid = types_mod.isValueStructTid;
    pub const valueStructHasOwnedFields = types_mod.valueStructHasOwnedFields;
    pub const returnIsBorrow = types_mod.returnIsBorrow;
    pub const isOwnedErrUnionOk = types_mod.isOwnedErrUnionOk;
    pub const isStringExpr = types_mod.isStringExpr;
    pub const isFloatExpr = types_mod.isFloatExpr;
    pub const isBoolExpr = types_mod.isBoolExpr;
    pub const isVoidExpr = types_mod.isVoidExpr;
    pub const isAnyExpr = types_mod.isAnyExpr;
    pub const isDecimalExpr = types_mod.isDecimalExpr;
    pub const symbolName = types_mod.symbolName;
    pub const tupleElemTraitName = types_mod.tupleElemTraitName;
    pub const isOwnedErrUnionErr = types_mod.isOwnedErrUnionErr;
    pub const isOwnedStorageElem = types_mod.isOwnedStorageElem;
    pub const isOwnedStorageElemByName = types_mod.isOwnedStorageElemByName;
    pub const typeIdForRenderedName = types_mod.typeIdForRenderedName;
    pub const isOwnedErrUnionPayloadByName = types_mod.isOwnedErrUnionPayloadByName;
    pub const isOwnedTupleElemByName = types_mod.isOwnedTupleElemByName;
    pub const isOwnedDeclaredType = types_mod.isOwnedDeclaredType;
    pub const tidForTypeRef = types_mod.tidForTypeRef;
    pub const concreteTidForTypeRef = types_mod.concreteTidForTypeRef;
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
    pub const compileIntSimd = expressions_mod.compileIntSimd;
    pub const compileClmul64 = expressions_mod.compileClmul64;
    pub const compileMemCall = expressions_mod.compileMemCall;
    pub const arrayElemFloatLLVM = expressions_mod.arrayElemFloatLLVM;
    pub const arrayBasePtr = expressions_mod.arrayBasePtr;
    pub const buildBareFnBox = expressions_mod.buildBareFnBox;
    pub const fnBoxReturn = expressions_mod.fnBoxReturn;
    pub const fnRefInt = expressions_mod.fnRefInt;
    pub const identNamesVariable = expressions_mod.identNamesVariable;
    pub const widenBranchToTrait = expressions_mod.widenBranchToTrait;
    pub const buildValueStructStorage = expressions_mod.buildValueStructStorage;
    pub const buildValueStructCopy = expressions_mod.buildValueStructCopy;
    pub const buildValueStructCopyInto = expressions_mod.buildValueStructCopyInto;
    pub const compileElemWitness = expressions_mod.compileElemWitness;
    pub const retainValueStructOwnedFields = expressions_mod.retainValueStructOwnedFields;
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
    pub const compileOptionalMethodCall = expressions_mod.compileOptionalMethodCall;
    pub const canonicalizeInt = expressions_mod.canonicalizeInt;
    pub const emitIntDivGuard = expressions_mod.emitIntDivGuard;
    pub const emitTrapIf = expressions_mod.emitTrapIf;
    pub const numToString = expressions_mod.numToString;
    pub const numToStringImpl = expressions_mod.numToStringImpl;
    pub const numToStringT = expressions_mod.numToStringT;
    pub const compileJsxElement = expressions_mod.compileJsxElement;
    pub const emitJsxInto = expressions_mod.emitJsxInto;
    pub const jsxAppendVal = expressions_mod.jsxAppendVal;
    pub const jsxAppendLiteral = expressions_mod.jsxAppendLiteral;
    pub const jsxFlushLiteral = expressions_mod.jsxFlushLiteral;
    pub const jsxAppendExpr = expressions_mod.jsxAppendExpr;
    pub const jsxSetLoc = expressions_mod.jsxSetLoc;
    pub const compileGenericParse = expressions_mod.compileGenericParse;
    pub const compileDecodeBinaryRow = expressions_mod.compileDecodeBinaryRow;
    pub const compileNovaQuery = expressions_mod.compileNovaQuery;
    pub const convertValueToType = expressions_mod.convertValueToType;
    pub const resolveReifyTypeName = expressions_mod.resolveReifyTypeName;
    pub const getFunc = expressions_mod.getFunc;
};

pub const compile = declarations_mod.compile;
pub const flags = declarations_mod.flags;
