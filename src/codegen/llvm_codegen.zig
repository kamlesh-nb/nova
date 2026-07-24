// src/codegen/llvm_codegen.zig
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
    /// V1 value-optional boxing: the DECLARED return TypeRef, kept alongside the rendered
    /// `return_type` string because `typeRefToString` ERASES the optional (`int | undefined`
    /// → `"int"`, types.zig:392). The return statement needs the un-erased TypeRef to decide
    /// whether to BOX a value-type-optional return (`Map<K,int>.get`'s `return value`). Null
    /// for lambdas/synthetic bodies (their returns are never value-optionals in practice).
    ret_type_ref: ?ast.TypeRef = null,
    body: ast.Block,
    // M3-C: async fns are lowered to LLVM coroutines. Defaults false so closure/
    // block synthetic FunctionInfos (which are never async) need no change.
    is_async: bool = false,
    /// F4 4b: which INSTANTIATION this body is, if it is one — `"List<string>"` for
    /// `List_string_push`. Null for every non-generic function, which is why this
    /// defaults and the other collection sites need no change.
    ///
    /// `compiler.functions` is already the list every phase walks (local_types,
    /// prototypes, bodies), so monomorphization is expressed as: put N entries here
    /// where there was 1, and let the phases that already exist do their jobs. The
    /// alternative — a parallel list of "mono functions" — would need every phase
    /// taught about it, and the phase that got forgotten would be a silent erasure.
    instantiation: ?[]const u8 = null,
    /// F4-5 method-level monomorphization: the method's OWN type-params bound to concrete types for
    /// THIS specialized body — `[{T, GetUser}]` for `App_get__GetUser`. Null for every non-generic
    /// method and the erased fallback body. Installed as `current_method_subst` while the body
    /// compiles, so `json.parse<T>` / `T`-typed reifies inside resolve `T` -> `GetUser`.
    method_subst: ?[]const MethodParamBinding = null,
    /// F4 M3-R1: this is the type-ERASED body of a GENERIC struct (`List_push`, `inst_opt == null` and
    /// the struct has type params). It is a link-time fallback: every instantiated call resolves to a mono
    /// body, and only the ABSTRACT RESIDUE (a `base_needed` method body holding a `List<U>`) still calls
    /// it. Marking these `internal` lets LLVM globalDCE delete the dead ones and keep exactly the residue.
    /// Default false: a non-generic function / mono body / specialization stays external.
    erased_generic: bool = false,
    /// T6 Phase 1b (per-file object split): the SOURCE FILE this function's declaration came from
    /// (`fn_decl.span.file`), so codegen can partition functions into one LLVM module → one `.o` per
    /// file. A monomorphized instance is attributed to the file of its generic declaration; a closure
    /// to the file of its enclosing function. Default "" for synthetic/uncattributed bodies (they land
    /// in a catch-all bucket). Only consulted under NOVA_T6_SPLIT; the single-module path ignores it.
    source_file: []const u8 = "",
};

pub const Scope = struct {
    deferred_statements: std.ArrayList(ast.Expression),
    /// E1 `errdefer`: run ONLY on an error-path return (see runErrdefers). Discarded on normal
    /// scope exit. Defaulted so existing `Scope{…}` literals need not name it.
    errdeferred_statements: std.ArrayList(ast.Expression) = .empty,
    /// Owned locals declared directly in THIS block, released at its exit — F5 O4
    /// ("scope exit | release every owned local"). SCOPE, not function.
    ///
    /// Releases used to fire only at function exit, from one name-keyed map built
    /// over the whole body. A `let` inside a loop appears there ONCE, so exactly one
    /// release was emitted — for whatever the alloca held last. Every earlier
    /// iteration's value was orphaned: N iterations leaked N-1 objects, measured
    /// 10->9, 100->99, 1000->999.
    owned_locals: std.ArrayList(OwnedLocal) = .empty,
};

pub const OwnedLocal = struct {
    name: []const u8,
    type_name: []const u8,
};

/// F5 O4/§3.4b: an owned TEMPORARY — a `+1` produced by an expression that nothing
/// named, and which therefore has no owner to release it.
///
/// `ignore(string.concat("a","b"))` leaks EXACTLY ONE object per call: `concat`
/// returns +1, `ignore` borrows it, and the value is never bound to anything whose
/// scope exit would release it. Measured 108 live at N=100 and 408 at N=400 against
/// a floor of 8 — linear, and the single biggest leak in the corpus (1898 objects on
/// 14_collections_map, where `m.set(`k${i}`, i)` sheds ~3 of these per iteration:
/// the template's string and its interpolation intermediates).
pub const PendingTemp = struct {
    /// The SSA value, used only to match a `let`/assign that CONSUMES this temporary.
    val: types.LLVMValueRef,
    /// The stack slot it was spilled to — what the drain actually loads and releases,
    /// because the producer may live in a branch the drain's block does not dominate.
    slot: types.LLVMValueRef,
    type_name: []const u8,
    /// F2-6 stage 5 step 5: the ExprId of the producing expression, so `drainTemporaries` /
    /// `consumeTemporary` can shadow-diff codegen's action against the ownership pass's recorded op.
    /// `.unassigned` for temps registered outside `compileExpression`'s choke point (the pass never
    /// saw them) — those are skipped in the diff, not counted as a disagreement.
    expr_id: ast.ExprId = .unassigned,
};

/// F4-5 method-level monomorphization: one method type-param bound to a concrete type inside a
/// specialized method body (`U` -> `string` inside `List_i32_map_string`).
pub const MethodParamBinding = struct {
    name: []const u8, // the method type-param, e.g. "U"
    concrete: []const u8, // the concrete type it was solved to, e.g. "string"
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
    structs: std.StringHashMap(ast.StructDecl),
    unions: std.StringHashMap(ast.UnionDecl),
    enums: std.StringHashMap(ast.EnumDecl),
    traits: std.StringHashMap(ast.TraitDecl),
    // T3 FFI: bare name -> the `extern("lib") fn` decl, so the call site knows which args
    // are strings (Nova string -> C char* + free) and whether the return is a string.
    ffi_externs: std.StringHashMap(ast.FunctionDecl),
    constants: std.StringHashMap(ast.Expression),
    current_local_types: ?*std.StringHashMap([]const u8),
    /// F5-2: parallel to `current_local_types`, keyed identically by NAME but valued with the
    /// TypeId, so the ARC ownership decision (`isOwnedLocal`) can ask the store instead of the
    /// rendered name. PARTIAL (populated only where an initializer expression is in hand) and
    /// ADDITIVE — a name absent here falls back to the string path, so it is behavior-preserving.
    current_local_type_ids: ?*std.StringHashMap(sema_types.TypeId),
    /// F5 §3.4b: owned temporaries produced by the statement being compiled, drained
    /// at its end (the C++ rule). Drained at STATEMENT boundaries, not per call:
    /// `f(g(), h())` must keep g's result alive until f has run.
    pending_temps: std.ArrayList(PendingTemp) = .empty,
    current_struct_name: ?[]const u8,
    /// F4 4b: the INSTANTIATION whose body is being emitted — `"List<string>"`.
    ///
    /// Null everywhere except inside a monomorphized method body, where it is what
    /// makes `T` mean `string`. Read at the only two places a type parameter becomes
    /// a string (`typeRefToString`'s `.ident`, `resolveExpressionTypeName`'s render);
    /// see F4 §5's 4b correction for why substituting there — rather than cloning the
    /// AST — is what actually removes the erasure. Save/restore around each body, the
    /// same way `current_struct_name` is handled.
    current_instantiation: ?[]const u8,
    /// Keystone: the TypeId of `current_instantiation` (`.struct_{List,[string]}` for `"List<string>"`),
    /// so a `.type_param` in this monomorphized body can be substituted IN THE STORE via
    /// `subst.substitute` rather than on the rendered string. Set beside `current_instantiation`.
    current_instantiation_id: ?sema_types.TypeId = null,
    /// F4-5 method-level monomorphization: the METHOD's own type-params bound to concrete types for the
    /// body currently being emitted. `current_instantiation` binds the STRUCT params (`T` from
    /// `List<string>`); this binds the METHOD params (`U` from `List<string>.map<int>`), which the
    /// struct instantiation cannot — `map<U>`'s `U` is solved at the CALL SITE, not by the receiver.
    /// Installed only inside a specialized body (`List_string_map_int`) so its `result: List<U>` renders
    /// `List<int>` and `result.push` binds the concrete `List_int_push` (which retains) instead of the
    /// erased `List_U_push` (which does not — the chained-map leak). A list of {param-name, concrete}
    /// pairs, applied AFTER the struct subst in `substTypeParams`. Null everywhere else.
    current_method_subst: ?[]const MethodParamBinding = null,
    /// F5-2: a rendered-name → TypeId reverse index, lazily built once from the store. Lets the
    /// name-only DECISION sites (destructor/box generators that receive `"ErrUnion(...)"` /
    /// `"(string,int)"` type-NAME strings, never an expr) recover the TypeId and ask `isOwnedTypeId`
    /// instead of `isRefCountedType(name)`. A render-mismatch (name not in the index) falls back to
    /// the string, so it is behavior-preserving. Keys are owned by `self.allocator`.
    rendered_name_ids: ?std.StringHashMapUnmanaged(sema_types.TypeId) = null,
    current_module_prefix: ?[]const u8,
    current_function_name: ?[]const u8,
    /// F5 O4: the scope depth at the top of the innermost loop's BODY, so a `break` or
    /// `continue` knows how many scopes it is jumping out of — and therefore whose
    /// owned locals it must release on the way.
    ///
    /// `return` already does this (`.return_stmt` → `releaseLocalVariables`); `break`
    /// and `continue` did not, and a block that ends in a terminator SKIPS its
    /// scope-exit releases. So the last iteration of every `while (true) { ... break; }`
    /// leaked its locals — which is most of the JSON parser (§3.4e).
    current_loop_scope_depth: ?usize,
    current_collecting_function_name: ?[]const u8,
    /// F4 4b: the instantiation of the body whose closures are being collected.
    ///
    /// A closure inside `Map<K,V>.keys()` belongs to `Map<string,i32>` just as much as
    /// the method does — `result.push(k)` can only pick `List_string_push` if the
    /// lambda knows what K is. Without this the lambda is emitted erased and calls
    /// `List_push`, which does not retain; see §3.4d.
    current_collecting_instantiation: ?[]const u8,
    /// F4-5: the method-level subst of the body whose closures are being collected — the analogue of
    /// `current_collecting_instantiation` for a generic METHOD's own type-params. A closure inside
    /// `App.get<GetUser>` belongs to that specialization; without this its `serde.bind<T>` is emitted
    /// erased (T unresolved). Feeds the closure key so one lambda is emitted per method-subst.
    current_collecting_method_subst: ?[]const MethodParamBinding = null,
    /// M3: a closure collected from an ERASED generic body is itself erased (its `List<K>` binds the erased
    /// `List_push`). Propagate the parent's erased-ness so R2 can skip the dead erased lambda too —
    /// otherwise the erased lambda pins the erased `List_push`/`List_grow` alive (the last abstract residue).
    current_collecting_erased_generic: bool = false,
    lambda_parents: std.StringHashMap([]const u8),
    // Explicit lambda param type strings (parallel to the lambda's USER params, i.e. after
    // the hidden __env), keyed by lambda name. Set when a param was annotated `(s: string)`;
    // declarations.zig types the body param from this instead of the "i32" legacy default.
    lambda_param_types: std.StringHashMap([]const ?[]const u8),
    function_local_types: std.StringHashMap(std.StringHashMap([]const u8)),
    /// F5-2: the persistent parallel to `function_local_types` — per-function name→TypeId maps,
    /// built in the same primary pass and re-pointed by `current_local_type_ids` at body-compile time.
    function_local_type_ids: std.StringHashMap(std.StringHashMap(sema_types.TypeId)),
    captured_globals: std.StringHashMap(types.LLVMValueRef),
    // A1 heap-environment closures: per-lambda ordered list of captured variable
    // names. Each closure value is a heap box {fn_ptr, env}; `env` is a heap
    // struct whose slot i holds the snapshotted value of lambda_captures[i].
    lambda_captures: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    // #18: one module-level {thunk_ptr, 0} box per bare fn used as a value,
    // keyed by the target's mangled name. Cached so that the same fn always
    // yields the same box address — `self.hashFn == string.hash` compares boxes.
    fn_box_globals: std.StringHashMap(types.LLVMValueRef),
    /// F2 stage 3: sema's TypedIr, for the SHADOW DIFF only. Codegen still uses
    /// resolveExpressionTypeName; this exists so the two answers can be compared
    /// on every real expression before stage 4 makes the IR authoritative.
    /// Null unless NOVA_SEMA_SHADOW=1.
    typed_ir: ?*const sema_infer.TypedIr = null,
    /// F2 stage 4b: read types from sema instead of re-deriving (NOVA_F2_TYPES=1).
    f2_types: bool = false,
    type_store: ?*const sema_types.TypeStore = null,
    current_scanning_lambda: ?[]const u8 = null,
    program: ast.Program,
    has_log: bool,
    next_lambda_id: u32,
    /// F4 4b: keyed by (closure SPAN, INSTANTIATION), not span alone.
    ///
    /// One source closure needs one lambda PER instantiation — `Map<string,i32>.keys()`
    /// and `Map<int,int>.keys()` share a span but must not share a body. Keyed by span
    /// only, `put` simply OVERWROTE: N lambdas were emitted and every instantiation
    /// resolved to whichever was collected last (§3.4d).
    closure_lambdas: std.StringHashMapUnmanaged([]const u8),
    current_saved_captures: std.StringHashMap(types.LLVMValueRef),
    is_wasm: bool,
    coverage_enabled: bool,
    cov_registry: ?CoverageRegistry,
    current_string_builder: ?types.LLVMValueRef = null,
    current_param_names: ?[]const []const u8 = null,
    // M3-C: set while compiling an `async fn` body. `return` stores its value into
    // current_async_promise (field 0 of the {result, waiter} promise) and branches
    // to current_async_final_bb (the final coro.suspend). The handle / suspend /
    // cleanup blocks are needed by `await` to emit a mid-body suspend. All null in
    // normal (sync) fns.
    current_async_promise: ?types.LLVMValueRef = null, // ptr to {result,waiter}
    current_async_final_bb: ?types.LLVMBasicBlockRef = null,
    current_async_hdl: ?types.LLVMValueRef = null, // this coroutine's own handle (ptr)
    current_async_suspend_bb: ?types.LLVMBasicBlockRef = null, // coro.ret (suspend default)
    current_async_cleanup_bb: ?types.LLVMBasicBlockRef = null,
    // Names of all async fns, for the sync-context call site (drive-to-completion).
    async_fns: std.StringHashMap(void) = undefined,

    // LLVM Types
    i1_type: types.LLVMTypeRef,
    i8_type: types.LLVMTypeRef,
    i32_type: types.LLVMTypeRef,
    i64_type: types.LLVMTypeRef,
    void_type: types.LLVMTypeRef,
    ptr_type: types.LLVMTypeRef,
    val_type: types.LLVMTypeRef,

    // String literals cache
    string_globals: std.StringHashMap(types.LLVMValueRef),

    // Libc/Host imports cache
    puts_fn: ?types.LLVMValueRef = null,
    printf_fn: ?types.LLVMValueRef = null,
    nova_log_string_fn: ?types.LLVMValueRef = null,
    nova_log_info_fn: ?types.LLVMValueRef = null,
    nova_log_debug_fn: ?types.LLVMValueRef = null,
    nova_log_err_fn: ?types.LLVMValueRef = null,
    log_fn: ?types.LLVMValueRef = null, // WASM environment log import
    heap_ptr: ?types.LLVMValueRef = null,
    free_list: ?types.LLVMValueRef = null,
    persistent_ptr: ?types.LLVMValueRef = null,
    current_break_bb: ?types.LLVMBasicBlockRef = null,
    current_continue_bb: ?types.LLVMBasicBlockRef = null,

    pub fn new(allocator: std.mem.Allocator, is_wasm: bool, is_release: bool, target_triple_opt: ?[]const u8, coverage_enabled: bool) !LlvmCompiler {
        // Initialize target architectures
        target.LLVMInitializeAllTargetInfos();
        target.LLVMInitializeAllTargets();
        target.LLVMInitializeAllTargetMCs();
        target.LLVMInitializeAllAsmPrinters();
        target.LLVMInitializeAllAsmParsers();

        // Get triple
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
        const tm = target_machine.LLVMCreateTargetMachine(
            target_ref,
            triple_z.ptr,
            "generic",
            "",
            opt_level,
            reloc,
            code_model,
        ) orelse return error.LLVMTargetMachineCreationError;

        const module = core.LLVMModuleCreateWithName("nova_module");
        const builder = core.LLVMCreateBuilder();

        // Set target triple and layout
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
            // The universal value handle must be 64-bit on BOTH targets: it has to
            // hold an f64 (the float path bitcasts val_type <-> double). wasm32
            // pointers are i32, but ptrtoint/inttoptr zext/trunc handle the width
            // gap; an i32 val_type made every float bitcast invalid (#23).
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

    /// The key a closure resolves by: its SPAN plus the INSTANTIATION it was compiled
    /// for. `"1234|"` for an ordinary (or erased) body, `"1234|Map<string, i32>"` for a
    /// monomorphized one — so one source closure yields one lambda per instantiation
    /// and each resolves to its own.
    pub fn closureKey(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8) ![]const u8 {
        return self.closureKeyM(span, inst, self.closureKeyActiveSubst());
    }

    /// The method-subst active for closure keying — the collecting one during collection, the current
    /// one during emission/resolution. Both are set only inside a specialized generic-method body.
    fn closureKeyActiveSubst(self: *LlvmCompiler) ?[]const MethodParamBinding {
        return self.current_collecting_method_subst orelse self.current_method_subst;
    }

    /// F4-5: closure key extended with the method-subst signature, so one source closure yields one
    /// lambda per (instantiation × method-subst) — `App.get<GetUser>` and `App.get<AddReq>` get
    /// distinct lambdas even though the span and struct-instantiation are identical.
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

    /// The idx-th element type of a rendered tuple spelling, e.g. `(string,int)` -> "string".
    ///
    /// Splits at DEPTH 0 only. A naive `splitSequence(inner, ",")` cut
    /// `(Map<string,int>, int)` into "Map<string" / "int>" / "int" — the exact round-trip
    /// fragility lower.zig:8 calls out (generics render with ", ", tuples with ","). Nested
    /// tuples `((int,int),string)` have the same problem, hence `(`/`)` counts too.
    ///
    /// Returns "i32" when the spelling is not a tuple — callers treat that as "not refcounted",
    /// so a wrong answer here silently disables ARC for the element rather than failing. That is
    /// how `"<tuple>"` (which never starts with `(`) turned every element into a leak.
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

    pub const isRefCountedType = arc_mod.isRefCountedType;
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

    // ===== V1: value-type optional boxing =====================================================
    // A value-type optional (`.optional(.prim)` — int/long/float/double/bool) is represented as a
    // BOXED pointer (or null = `undefined`), so a present `0`/`0.0`/`false` is a non-null box and thus
    // distinguishable from absent. `!= undefined` stays a `!= 0` null-check (present is non-null);
    // producers box the value, consumers (`??`/narrowing/`at`) unbox it. Pointer/decimal optionals are
    // already heap-null-representable and are NOT boxed. See docs/design/value-optional-boxing.md.

    /// If `tid` is a VALUE-TYPE optional (`.optional` whose inner is a `.prim`), return the inner
    /// TypeId (the type to box/unbox); else null (pointer/decimal/struct optionals are unchanged).
    pub fn valueOptionalInner(self: *LlvmCompiler, tid: sema_types.TypeId) ?sema_types.TypeId {
        const st = self.type_store orelse return null;
        const info = st.get(tid);
        if (info != .optional) return null;
        return switch (st.get(info.optional)) {
            .prim => info.optional, // int/long/float/double/bool — a value type: box it
            else => null, // string/decimal/struct/trait/ptr/enum: already pointer/null-representable
        };
    }

    /// Box a value into a value-optional (present). `nova_valopt_box(value)` → non-null pointer.
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

    /// Unbox a value-optional (assumes non-null; callers null-check first). `nova_valopt_unbox`.
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

    /// V1 PRODUCE predicate: is `tr` a value-type optional (`int | undefined`, boxable)? The
    /// TypeRef is used because `typeRefToString` ERASES the optional; the inner name is rendered
    /// WITH the active mono/method subst installed, so `V | undefined` in `Map<_,int>.get` renders
    /// `"int"`. Kept in exact agreement with `valueOptionalInner` (store `.prim`): `ptr` lowers to
    /// `.ptr` (NOT `.prim`) so it is excluded here too — a `ptr?` is a null-representable address.
    pub fn valoptTypeRefIsValue(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        const inner = self.typeRefToString(tr.optional.*) catch return false;
        if (std.mem.eql(u8, inner, "ptr")) return false;
        return types_mod.cgPrim(inner) != null;
    }

    /// V1 CONSUME predicate: does compiling `e` YIELD A BOX at runtime (so a consumer must unbox)?
    /// A value-optional box is materialized only by a value-optional-typed LEAF — an ident whose slot
    /// holds a box (a non-narrowed value-optional local; a narrowed one loads UNBOXED, so its use type
    /// is the bare prim and this is false), a value-optional FIELD, or a call/index/`?.` that returns a
    /// value-optional (its producer boxed the return). COMPOUND expressions (`x % 2`, `x + 1`, `-x`,
    /// `a ?? b`, a cast) already unbox their own leaves and yield a RAW value — even though the checker
    /// propagates the optional type through arithmetic (`int? % int = int?`). Unboxing THOSE a second
    /// time dereferences a raw integer as a pointer (the `for (x in xs) { x % 2 }` SEGV). So the box
    /// property is keyed on the expression FORM, not on the (propagated) type alone.
    pub fn exprYieldsValoptBox(self: *LlvmCompiler, e: *const ast.Expression) bool {
        const tid = self.typeOfExprConcrete(e) orelse return false;
        if (self.valueOptionalInner(tid) == null) return false;
        return switch (e.kind) {
            // A value-optional-typed LEAF materializes a BOX: a `.call`/`.generic_call` boxed its return
            // (container methods `Map`/`List.get` are `.call`; a monomorphized generic free fn `maybe<int>`
            // is `.generic_call` and now ALSO boxes — free-fn mono), or an ident/field/index slot holds one.
            // A COMPOUND expression (`x % 2`, `a ?? b`, cast) yields a RAW value even when the checker types
            // it `int?` (optionality propagates through arithmetic) — unboxing it would deref a raw int.
            .ident, .field_access, .call, .generic_call, .index, .optional_chaining => true,
            else => false, // binary / unary / cast / ?? / if-expr / literal: already raw
        };
    }

    /// V1: the `undefined`/`null` literal in a value-optional context stays `0` (null box) — never boxed.
    pub fn isUndefinedLiteralExpr(e: *const ast.Expression) bool {
        return e.kind == .literal and (e.kind.literal == .undefined or e.kind.literal == .null);
    }

    // A1 heap-environment closures ------------------------------------------
    pub fn valSlotSize(self: *LlvmCompiler) usize {
        _ = self;
        // A value slot is one val_type (i64 = 8 bytes) on BOTH targets. wasm used
        // to say 4 (i32 val_type) — but val_type is now i64 everywhere (needed for
        // f64), so every field/array/box stride is 8. A 4-byte stride here was the
        // wasm pointer-corruption bug (#23): reference fields overlapped by half.
        return 8;
    }

    // If the current function is a lambda that captures `name`, return the index
    // of that capture in the lambda's env; otherwise null.
    pub fn envCaptureIndex(self: *LlvmCompiler, name: []const u8) ?usize {
        const fn_name = self.current_function_name orelse return null;
        if (!std.mem.startsWith(u8, fn_name, "__lambda_")) return null;
        const caps = self.lambda_captures.get(fn_name) orelse return null;
        for (caps.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, name)) return i;
        }
        return null;
    }

    // Address (as val_type int) of env slot `index` for the current lambda.
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
        // void nova_bytes_free(i64 ptr)
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
        
        // If ptr == 0: return
        const is_zero = core.LLVMBuildICmp(builder, types.LLVMIntPredicate.LLVMIntEQ, ptr, core.LLVMConstInt(self.val_type, 0, 0), "is_zero");
        
        // Arena pointers are < 32MB boundary (33554432)
        const boundary = core.LLVMConstInt(self.val_type, 32 * 1024 * 1024, 0);
        const is_arena = core.LLVMBuildICmp(builder, types.LLVMIntPredicate.LLVMIntULT, ptr, boundary, "is_arena");
        const cond = core.LLVMBuildOr(builder, is_zero, is_arena, "cond");
        
        _ = core.LLVMBuildCondBr(builder, cond, ret_bb, do_free_bb);

        core.LLVMPositionBuilderAtEnd(builder, do_free_bb);
        const next = core.LLVMBuildLoad2(builder, self.val_type, self.free_list.?, "next");
        const ptr_ptr = core.LLVMBuildIntToPtr(builder, ptr, core.LLVMPointerType(self.val_type, 0), "ptr_ptr");
        _ = core.LLVMBuildStore(builder, next, ptr_ptr);
        _ = core.LLVMBuildStore(builder, ptr, self.free_list.?);
        _ = core.LLVMBuildBr(builder, ret_bb);

        core.LLVMPositionBuilderAtEnd(builder, ret_bb);
        _ = core.LLVMBuildRetVoid(builder);

        // i64 nova_bytes_alloc(i64 size) — Pure Bump Allocator for Arena
        var alloc_params = [_]types.LLVMTypeRef{self.val_type};
        const alloc_type = core.LLVMFunctionType(self.val_type, &alloc_params, 1, 0);
        const alloc_fn = core.LLVMAddFunction(self.module, "nova_bytes_alloc", alloc_type);
        try self.func_map.put("nova_bytes_alloc", alloc_fn);

        const a_entry_bb = core.LLVMAppendBasicBlock(alloc_fn, "entry");
        const ab = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(ab);
        
        core.LLVMPositionBuilderAtEnd(ab, a_entry_bb);
        const a_size = core.LLVMGetParam(alloc_fn, 0);
        
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

        // i64 nova_bytes_alloc_persistent(i64 size) — First-Fit Free-List fallthrough to persistent_ptr
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

        // Cond Block
        core.LLVMPositionBuilderAtEnd(apb, ap_cond_bb);
        const ap_curr = core.LLVMBuildLoad2(apb, self.val_type, ap_curr_ptr, "curr");
        const ap_is_null = core.LLVMBuildICmp(apb, types.LLVMIntPredicate.LLVMIntEQ, ap_curr, core.LLVMConstInt(self.val_type, 0, 0), "is_null");
        _ = core.LLVMBuildCondBr(apb, ap_is_null, ap_bump_bb, ap_body_bb);

        // Body Block
        core.LLVMPositionBuilderAtEnd(apb, ap_body_bb);
        const ap_four = core.LLVMConstInt(self.val_type, 4, 0);
        const ap_size_addr = core.LLVMBuildSub(apb, ap_curr, ap_four, "size_addr");
        const ap_size_ptr = core.LLVMBuildIntToPtr(apb, ap_size_addr, core.LLVMPointerType(self.i32_type, 0), "size_ptr");
        const ap_block_size_i32 = core.LLVMBuildLoad2(apb, self.i32_type, ap_size_ptr, "block_size_i32");
        const ap_block_size = core.LLVMBuildZExt(apb, ap_block_size_i32, self.val_type, "block_size");
        const ap_is_ok = core.LLVMBuildICmp(apb, types.LLVMIntPredicate.LLVMIntUGE, ap_block_size, ap_size, "is_ok");
        _ = core.LLVMBuildCondBr(apb, ap_is_ok, ap_found_bb, ap_next_bb);

        // Next Block
        core.LLVMPositionBuilderAtEnd(apb, ap_next_bb);
        _ = core.LLVMBuildStore(apb, ap_curr, ap_prev_ptr);
        const ap_next_node_ptr = core.LLVMBuildIntToPtr(apb, ap_curr, core.LLVMPointerType(self.val_type, 0), "next_node_ptr");
        const ap_next_node = core.LLVMBuildLoad2(apb, self.val_type, ap_next_node_ptr, "next_node");
        _ = core.LLVMBuildStore(apb, ap_next_node, ap_curr_ptr);
        _ = core.LLVMBuildBr(apb, ap_cond_bb);

        // Found Block
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

        // Bump Block
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

        // End Block
        core.LLVMPositionBuilderAtEnd(apb, ap_end_bb);
        const ap_res = core.LLVMBuildPhi(apb, self.val_type, "alloc_res");
        var ap_phi_vals = [_]types.LLVMValueRef{ ap_curr, ap_curr, ap_client_ptr };
        var ap_phi_bbs = [_]types.LLVMBasicBlockRef{ ap_prev_null_bb, ap_prev_not_null_bb, ap_bump_bb };
        core.LLVMAddIncoming(ap_res, &ap_phi_vals, &ap_phi_bbs, 3);
        _ = core.LLVMBuildRet(apb, ap_res);

        // void nova_retain(i64 ptr)
        var retain_params = [_]types.LLVMTypeRef{self.val_type};
        const retain_type = core.LLVMFunctionType(self.void_type, &retain_params, 1, 0);
        const retain_fn = core.LLVMAddFunction(self.module, "nova_retain", retain_type);
        try self.func_map.put("nova_retain", retain_fn);
        const r_entry = core.LLVMAppendBasicBlock(retain_fn, "entry");
        const rb = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(rb);
        core.LLVMPositionBuilderAtEnd(rb, r_entry);
        _ = core.LLVMBuildRetVoid(rb);

        // void nova_release(i64 ptr, i64 dest)
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
        // F1 module-scoped types: a method's prefix is the module-unique struct name (its struct is
        // defined in the method's OWN file), so a colliding struct's methods mangle as
        // `<mod>_<Struct>_<method>` — matching what the call site derives via resolveExpressionTypeName.
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
                // A7 / F3 §5 stage 1: sizes come from the canonical `cgPrim` table.
                // `bool` is deliberately excluded here — today's `getTypeSize` has no
                // bool case, so a bool field falls through to the machine word below;
                // preserving that (honest 1-byte bool is F3 stage 4/5, not stage 1).
                if (types_mod.cgPrim(name)) |p| {
                    switch (p.repr) {
                        .i1 => {}, // bool: fall through to the word default (as today)
                        .i8 => return 1,
                        .i16 => return 2,
                        // A7 / F3 §5 stage 5 (honest slots): a real `int` field is 4 bytes
                        // on every target (was 8 native — the divergence §7 removes).
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
                    // A7 / F3 §5 stage 4: a real `double` arg crossing to the i64 ABI param.
                    casted_args[idx] = core.LLVMBuildBitCast(self.builder, arg, expected_t, "arg_double_to_val");
                } else if (expected_kind == types.LLVMTypeKind.LLVMDoubleTypeKind and actual_kind == types.LLVMTypeKind.LLVMIntegerTypeKind) {
                    // A double-typed param (e.g. a runtime float helper) fed an i64-encoded float.
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
                        // F4 4b: `Map_string_int_set` must match back to `Map.set`.
                        // This built only `Map_set` and returned null for every
                        // monomorphized callee — which skipped not just the ARC retain
                        // below but the TRAIT-OBJECT construction beside it, because
                        // both live under `if (getFunctionParamType(..)) |expected|`.
                        // That is why 12_traits_dispatch failed under mono: a null here
                        // is indistinguishable from "this param has no declared type".
                        //
                        // The type returned is the DECLARED one (`K`, not `string`):
                        // `current_instantiation` is null at a CALL SITE — the caller is
                        // not inside the instantiation — so `typeRefToString` does not
                        // substitute here, which is exactly what `retainIfGenericStore`
                        // needs to keep seeing.
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

    /// V1: like `getFunctionParamType` but returns the un-erased param TypeRef (so a `int | undefined`
    /// param is distinguishable from `int` — `typeRefToString` erases the optional). Used to decide
    /// box/unbox of a call argument at the value ↔ value-optional boundary. Mirrors the fn_decl and
    /// struct-method resolution; returns null when the callee/param can't be resolved (→ no coercion).
    pub fn getFunctionParamTypeRef(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?ast.TypeRef {
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
                            if (param_idx == 0) return null; // receiver
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

    /// V1 value-optional boxing — the PRODUCE half at a CALL ARGUMENT: a bare value passed to a
    /// value-optional parameter (`f(5)` where `f(x: int | undefined)`) must be BOXED. The CONSUME half
    /// (a value-optional arg → bare-value param) is handled uniformly in `compileCallArgument`, so this
    /// only boxes. `undefined`/an already-optional arg is untouched; a null/unknown param TypeRef is a
    /// no-op. Nova has no concrete value-optional params in the stdlib today, so this is a forward-
    /// looking completeness path — the value flows unchanged everywhere it currently matters.
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

    /// Find the monomorphized specialization of a MODULE-QUALIFIED generic FREE fn — `client.getJson<Info>`
    /// → `web_client_getJson__Info`. Builds the call-site name `<obj>_<field>__<mangled args>` and matches
    /// it against `func_map`: exactly, or (since the emitted symbol carries the FILE's module prefix, e.g.
    /// `web_client_…`) by the `_<name>` suffix — the same scan the non-generic namespaced-fn path uses.
    /// Returns null when no spec exists (the caller then falls through to the ordinary namespaced path).
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
        const spec_target = nb.items; // e.g. "client_getJson__Info"
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
        // §3.4h: SLOT 0 is the wrapped struct's destructor; methods follow at 1..N. That
        // is how `__destruct_trait` finds the concrete struct's destructor from a release
        // site that knows only the trait. Dispatch shifts its method index by +1.
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
        // A generic trait object (`Box<int>`) is stored under its BASE name's vtable (`Box`) — the
        // trait's methods are the same across instantiations, and the concrete impl supplies them.
        const trait_name = getStructBaseName(trait_name_raw);
        const ptr_size = @as(u32, 8);
        const size_val = core.LLVMConstInt(self.val_type, ptr_size * 2, 0);
        const trait_obj = try self.compileAlloc(size_val);

        // §3.4h: the trait object CO-OWNS the struct — retain it here, and
        // `__destruct_trait` (via vtable slot 0) releases it when the fat pointer dies.
        // A trait object built over a temporary (`f(Dog())`, `return JsonSource(..)`)
        // was otherwise the struct's only reference, and freeing the 16-byte fat pointer
        // without releasing it leaked the struct and everything it owned.
        try self.compileRetain(struct_ptr);

        const addr0 = trait_obj;
        const ptr0 = core.LLVMBuildIntToPtr(self.builder, addr0, core.LLVMPointerType(self.val_type, 0), "trait_struct_ptr");
        _ = core.LLVMBuildStore(self.builder, struct_ptr, ptr0);

        const addr1 = core.LLVMBuildAdd(self.builder, trait_obj, core.LLVMConstInt(self.val_type, ptr_size, 0), "vtable_addr");
        const ptr1 = core.LLVMBuildIntToPtr(self.builder, addr1, core.LLVMPointerType(self.val_type, 0), "trait_vtable_ptr");

        const vtable_global = try self.getGlobalVTable(struct_name, trait_name);
        const vtable_int = core.LLVMBuildPtrToInt(self.builder, vtable_global, self.val_type, "vtable_int");
        _ = core.LLVMBuildStore(self.builder, vtable_int, ptr1);

        // F5 §3.4f: the fat pointer is a `+1` that NOTHING names — `f(Dog())` coerces
        // its argument and then no one owns the 16 bytes. It was built here with
        // `compileAlloc`, never through `compileExpression`, so the temporary rule
        // could not see it and every trait coercion leaked one.
        //
        // Registered as a temporary, so it dies at the end of the statement like any
        // other. `let x: Speaker = Dog()` CONSUMES it (statements.zig) — the binding is
        // its owner then.
        //
        // It stores `struct_ptr` WITHOUT retaining (a borrow), so releasing the fat
        // pointer must NOT release the struct: the trait name has no destructor, which
        // is exactly right — freeing the 16 bytes is the whole job.
        try self.registerTemporary(trait_obj, trait_name);

        return trait_obj;
    }

    fn getOrCreateAtomicExternFn(self: *LlvmCompiler, fn_name: []const u8, t_name: []const u8, method_name: []const u8) !types.LLVMValueRef {
        if (self.func_map.get(fn_name)) |val| {
            return val;
        }
        
        // Define the return type and parameter types for the extern function
        const ret_llvm_type = if (std.mem.eql(u8, method_name, "compareAndSwap"))
            self.i32_type // CAS returns bool (i32 in our C runtime)
        else if (std.mem.eql(u8, method_name, "store"))
            self.void_type
        else
            if (std.mem.eql(u8, t_name, "i64") or std.mem.eql(u8, t_name, "u64") or std.mem.eql(u8, t_name, "double")) self.i64_type else if (std.mem.eql(u8, t_name, "bool")) self.i1_type else self.i32_type;

        var param_types = std.ArrayList(types.LLVMTypeRef).empty;
        defer param_types.deinit(self.allocator);
        
        // Parameter 0: ptr (i8* or pointer to T)
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
        // Create C-string for function name
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

        // Compile the object pointer (which has type Atomic<T> on the heap, wrapping ptr at offset 0)
        const atomic_obj_ptr = try self.compileExpression(obj_expr);
        // Load the actual pointer 'ptr' from offset 0
        const ptr_val = core.LLVMBuildLoad2(self.builder, self.ptr_type, core.LLVMBuildIntToPtr(self.builder, atomic_obj_ptr, core.LLVMPointerType(self.ptr_type, 0), "atomic_ptr_ptr"), "atomic_ptr");

        // Determine the C function name to call
        var fn_name: []const u8 = "";
        // Same canonical table as the cell allocation (expressions.zig) — so the ACCESS width
        // and the ALLOCATION width cannot disagree. They previously did: two independent
        // `t_name == "i64"` tests fed by two different renderings ("long" vs "i64") of one type,
        // giving a 4-byte cell and 8-byte accesses. See the note at the allocation site.
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

        // Add the extern function to LLVM module if not already present
        const atomic_fn = try self.getOrCreateAtomicExternFn(fn_name, t_name, method_name);
        
        // Prepare arguments
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

    /// F4-5: emit a call to a specialized generic-method body — `app.get<GetUser>(path)` ->
    /// `App_get__GetUser(app, path)`. Returns null when this is not an explicit-generic method call
    /// with a recorded specialization, so the caller falls through to the ordinary method path.
    pub fn compileExplicitGenericMethodCall(
        self: *LlvmCompiler,
        fa: ast.FieldAccess,
        type_args: []const ast.TypeRef,
        args_exprs: []const ast.Expression,
    ) anyerror!?types.LLVMValueRef {
        const obj_type = (try self.resolveExpressionTypeName(fa.object)) orelse return null;
        const base = getStructBaseName(obj_type);
        const s = self.structs.get(base) orelse return null;
        // The method must exist AND be generic (have its own type-params).
        var method_decl: ?ast.FunctionDecl = null;
        for (s.methods) |m| {
            if (std.mem.eql(u8, m.decl.name, fa.field)) {
                if (m.decl.type_params.len == type_args.len and type_args.len > 0) method_decl = m.decl;
                break;
            }
        }
        const mdecl = method_decl orelse return null;

        // Specialized symbol: methodSymbol(owner, field) ++ "__" ++ mangled(type_args) — must match
        // the name the emit loop produced.
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
        // `getFunctionParamType(spec_name, ..)` is unreliable for a synthesized specialized symbol,
        // so read the expected type from the METHOD DECL (params[0] is `self`, so arg i -> params[i+1]).
        // A trait param (`src: ValueSource`) must be WIDENED to a fat pointer here, exactly as the
        // ordinary method path does — otherwise the raw concrete handle is passed and trait dispatch
        // inside the body reads a garbage vtable.
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

    /// Resolve a callee's declared param type for the trait-widening decision. `getFunctionParamType`
    /// returns the DECLARED type (`V` for `Map<K,V>.set`, unsubstituted — `current_instantiation` is
    /// null at a call site), so a generic-container param whose value type is a TRAIT reads as `"V"`,
    /// `traits.contains("V")` is false, and a struct arg is stored RAW instead of widened to the trait
    /// object. That is a use-after-free: the map holds a bare struct, `get` returns it, and a trait
    /// method reads the struct's first words as {ptr,vtable} → garbage vtable → SEGV; the map's
    /// `__destruct_trait` then frees garbage. Substituting `V` through the receiver instantiation
    /// (`Map<string,Greeter>` → `Greeter`) restores the trait check.
    fn resolveParamTypeForWiden(self: *LlvmCompiler, obj_type_opt: ?[]const u8, expected_type: []const u8) []const u8 {
        const ot = obj_type_opt orelse return expected_type;
        if (std.mem.indexOfScalar(u8, ot, '<') == null) return expected_type; // not an instantiation
        return self.substituteFieldType(ot, expected_type) catch expected_type;
    }

    // Emit a trait-object dynamic-dispatch call through the vtable and return the raw call
    // result. For a SYNCHRONOUS trait method that is the method's return value; for an
    // `async fn` trait method the vtable slot holds the ramp, so it is the coroutine HANDLE
    // (the caller then drives or awaits it). Factored out so the sync-dispatch site and the
    // await path (awaitedCallHandle) share ONE lowering of the fat-pointer indirection.
    pub fn buildTraitVtableCall(self: *LlvmCompiler, fa: ast.FieldAccess, m_idx: usize, args_exprs: []const ast.Expression) anyerror!types.LLVMValueRef {
        const trait_obj_ptr = try self.compileExpression(fa.object.*);
        const ptr_size = @as(u32, 8);

        const struct_ptr_ptr = core.LLVMBuildIntToPtr(self.builder, trait_obj_ptr, core.LLVMPointerType(self.val_type, 0), "trait_struct_ptr_ptr");
        const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, struct_ptr_ptr, "trait_struct_ptr");

        const vtable_addr = core.LLVMBuildAdd(self.builder, trait_obj_ptr, core.LLVMConstInt(self.val_type, ptr_size, 0), "vtable_addr");
        const vtable_ptr_ptr = core.LLVMBuildIntToPtr(self.builder, vtable_addr, core.LLVMPointerType(self.val_type, 0), "trait_vtable_ptr_ptr");
        const vtable_ptr_int = core.LLVMBuildLoad2(self.builder, self.val_type, vtable_ptr_ptr, "trait_vtable_ptr_int");

        // §3.4h: vtable slot 0 is the struct destructor, so method `m_idx` lives at slot `m_idx + 1`.
        const fn_offset = core.LLVMConstInt(self.val_type, (m_idx + 1) * ptr_size, 0);
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
        // NO retain of the receiver (BORROW — a trait method does not store its `self`).
        args[0] = struct_ptr;
        for (args_exprs, 0..) |arg, idx| {
            args[idx + 1] = try self.compileCallArgument(arg);
        }

        return core.LLVMBuildCall2(self.builder, fn_t, fn_ptr, args.ptr, @intCast(total_args), "trait_call");
    }

    pub fn compileMethodOrNamespacedCall(self: *LlvmCompiler, callee_fa: ast.FieldAccess, args_exprs: []const ast.Expression) anyerror!types.LLVMValueRef {
        const fa = callee_fa;
        var obj_type = try self.resolveExpressionTypeName(fa.object);
        // F2-5: when the receiver is a TYPE NAME used as a namespace (`Status.Ok`, `Status.toCode(x)`,
        // `List.new()`) rather than a VARIABLE holding a value, route it as a namespace — exactly as it
        // did before the receiver ident was typed. Once F2-5 types these idents,
        // resolveExpressionTypeName returns the enum/struct and the method path below would compile the
        // bare type name as a receiver VALUE ("Identifier 'Status' not found"). Decide by MEMBERSHIP
        // (self.enums/self.structs) + not-a-variable, never by "has a sema type". Nulling obj_type
        // restores the pre-typing routing that already handled these correctly.
        if (fa.object.kind == .ident and !self.identNamesVariable(fa.object.kind.ident) and
            (self.enums.contains(fa.object.kind.ident) or self.structs.contains(fa.object.kind.ident)))
        {
            obj_type = null;
        }
        // `module.Struct.staticMethod()`: the receiver `module.Struct` is a field access
        // naming a TYPE, not a value, so it has no expression type. Recover the struct
        // name (the field of `module.Struct`) so the static-method resolution below finds
        // `Struct_method`. The bare `Struct.method()` case (object is an ident) is handled
        // by the namespaced-fn fallback further down.
        if (obj_type == null and fa.object.kind == .field_access) {
            const inner = fa.object.kind.field_access;
            if (self.isStructType(inner.field)) {
                obj_type = inner.field;
            }
            // `E.A.code()` — the receiver `E.A` is a PAYLOAD-LESS enum value: a field access
            // whose OBJECT names the enum (`E`) and whose FIELD names the variant (`A`). Sema
            // does not type it (`enum_init`'s payload-less form yields no expression type), so the
            // method receiver was null and dispatch found no `E_code`. The payload form `E.N(3)`
            // worked because it is a CALL, typed via the enum-construction path. Recover the enum
            // name from the object so `E.A.code()` reaches `E_code` like `E.N(3).code()` does.
            else if (inner.object.kind == .ident and self.enums.contains(inner.object.kind.ident)) {
                obj_type = inner.object.kind.ident;
            }
        }

        if (obj_type) |struct_name| {
            const base_struct = getStructBaseName(struct_name);
            if (std.mem.eql(u8, base_struct, "Atomic") and !std.mem.eql(u8, fa.field, "delete")) {
                return try self.compileAtomicCall(struct_name, fa.field, fa.object.*, args_exprs);
            }
            // `Storage` is dispatched in expressions.zig, NOT here. The dispatch that
            // used to sit at this spot was dead — instrumented across the whole corpus,
            // ZERO hits — because the call-expression path in expressions.zig gets
            // there first. See the deletion note on that path for why a second, silently
            // divergent copy was worse than none.
        }

        // 1. Enum Variant Constructor Call
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

                    // Store tag at offset 0
                    const tag_val = core.LLVMConstInt(self.val_type, tag, 0);
                    const tag_ptr = core.LLVMBuildIntToPtr(self.builder, union_ptr, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                    _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

                    // Store arguments
                    const ptr_size = @as(u32, 8);
                    for (args_exprs, 0..) |arg, idx| {
                        const arg_val = try self.compileCallArgument(arg);
                        // The box TAKES OWNERSHIP of an owned payload so `__destruct_<Enum>` can
                        // release it: a fresh temporary transfers its +1 (consume it, else the
                        // statement-end drain frees it early — the `E.Variant("a"+"b")` dangle), an
                        // r-var is retained (the box needs its own reference). Mirrors struct-init.
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

        // 2. Trait Method Dynamic Dispatch
        if (obj_type) |t_name_raw| {
            // A generic trait object's type is `Trait<Args>`; the traits table is keyed by the base
            // name (`Trait`). Strip the args so `box.get()` on a `Box<int>` dispatches.
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
                    // A1 async-first seam: an `async fn` trait method's vtable slot holds its
                    // ramp, so the indirect call yields the coroutine HANDLE. From a non-await
                    // context, drive it to completion and read its promise result. The `await`
                    // form is intercepted earlier by awaitedCallHandle (which returns this same
                    // handle), so control only reaches here for a direct (non-await) call.
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

            // F4 4b: `xs.push(v)` where `xs: List<string>` must call
            // `List_string_push` — the body where `T` IS `string` and ARC can decide
            // to retain. `getStructBaseName` strips the `<string>`, which is right for
            // finding the DECLARATION (the methods live on `List`) but wrong for
            // finding the BODY, and that conflation is the erasure at the call site.
            //
            // Tried FIRST, and falls back to the erased symbol when there is no
            // monomorphized body — mono off, or a generic that was never instantiated.
            // That fallback is what lets this land before every call site is proven:
            // a miss is the old behaviour, not a link error.
            // F4-5 ("4b's second half"): a receiver typed `List<T>` / `List<K>` inside a
            // monomorphized body must resolve to the CONCRETE instantiation's method, not the
            // erased one. `qualifySelfType` only rewrites a BARE `List` (the `self` case);
            // `substTypeParams` maps the nested type-PARAMETER against `current_instantiation`
            // (`List<string>` in a `List_string_*` body, `Map<string,i32>` for a `List<K>` inside
            // Map) — so `List<T>` -> `List<string>` -> `List_string_push` instead of the missing
            // `List_T_push` that fell back to the erased `List_push`. A method-level param (`U` in
            // `map<U>`) is not in the struct instantiation, so it stays abstract and still falls
            // back — the residual erased reliance, shrunk to that case.
            const subst_struct = self.substTypeParams(struct_name) catch struct_name;
            defer if (subst_struct.ptr != struct_name.ptr) self.allocator.free(subst_struct);
            const mono_name = try self.methodSymbol(self.qualifySelfType(subst_struct), method_name);
            defer self.allocator.free(mono_name);

            // M3: inferred-arg method<U> call → single specialization (see notes). Isolating the call-site
            // ARC effect: NO method-base flag change here, just the routing.
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
                // F4-5 shadow: classify this erased-body reliance. A mono_name that DIFFERS from the
                // erased full_name means an instantiated receiver whose monomorphized body was absent
                // from func_map — the residual reliance the erased-body deletion must first close.
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

        // #6/#7: only a MODULE namespace can name a function here (`string.hash`).
        // If the object is a VARIABLE, `x.foo()` is a method call or a fn-valued
        // field — never a global fn, even when one happens to share the name.
        //
        // This is the sibling of the value-path guard in expressions.zig
        // (`obj_is_variable`), added when `f.payload` resolved to a user
        // `fn payload` and the btree driver parsed a function address as a string
        // — §10 #6, misfiled for months as "string heap corruption". That fix
        // closed the value path only; this fallback stayed open. Verified before
        // this guard: `t.describe()` on a struct with no `describe` method emitted
        // `call i64 @describe()` against a 3-arg global. It failed loudly ONLY
        // because the arity differed — a SAME-ARITY collision compiles clean and
        // silently calls the wrong function.
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
            if (self.func_map.get(full_name)) |_| {
                resolved_name = full_name;
            } else if (self.func_map.get(cap_full_name)) |_| {
                resolved_name = cap_full_name;
            } else {
                var iter = self.func_map.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const suffix_len = full_name.len + 1;
                    if (key.len >= suffix_len) {
                        const suffix = key[key.len - suffix_len..];
                        if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], full_name)) {
                            resolved_name = key;
                            break;
                        }
                    }
                }
                if (resolved_name == null) {
                    iter = self.func_map.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const suffix_len = cap_full_name.len + 1;
                        if (key.len >= suffix_len) {
                            const suffix = key[key.len - suffix_len..];
                            if (suffix[0] == '_' and std.mem.eql(u8, suffix[1..], cap_full_name)) {
                                resolved_name = key;
                                break;
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
                // §3.4/P2-14: a method call on an absent optional (`l.get(i).m()` where get
                // returned undefined) would deref the receiver handle 0. Trap with a location
                // instead of SEGV. No-op when the receiver is not optional.
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

            // A1 async-first seam: calling an `async fn` METHOD (or namespaced async fn)
            // from a NON-await context drives the coroutine to completion and yields its
            // promise value — mirroring the free-fn path in compileExpression's `.call`
            // arm. `func_name` is the LLVM symbol, which is the same mangled name the
            // method's ramp was registered under in `async_fns`. Without this an async
            // method call from sync context returns the raw coroutine handle (garbage).
            if (self.async_fns.contains(func_name)) {
                return try self.buildDriveAsyncCall(fn_val, args);
            }

            return try self.buildCallWithCasts(fn_val, args);
        }

        // Check if it's a function pointer field access
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
                    // #18: a fn-valued field holds a box, exactly like a fn-valued
                    // local. Calling it as a raw code pointer here was the second
                    // of the two conventions — the divergence that made
                    // `(self.f)(x)` and `let f = self.f; (f)(x)` mean different
                    // things. Both now go through the one box-unpacking path.
                    const field_val = try self.compileExpression(.{ .kind = .{ .field_access = fa } });
                    return try self.buildClosureCall(field_val, args_exprs);
                }
            }
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

                var lambda_return_type: []const u8 = if (is_void_lambda) "void" else "i32";
                // If the checker typed this closure (from its expected context — a
                // `(ServiceProvider) -> Service` factory slot) as returning a TRAIT, carry that trait
                // name as the lambda's return type. The hardcoded "i32" otherwise left
                // `self.traits.contains(func.return_type)` FALSE in the return-statement trait-widening
                // (statements.zig), so a lambda returning a concrete impl was returned UNWIDENED (a raw
                // struct, not the fat pointer) and the caller's `x as Concrete` downcast crashed. Named
                // fns already carry their real return type; this closes the lambda-only gap. Pairs with
                // the infer.zig fix that records the closure's return AS the trait. Strictly additive:
                // falls back to "i32" when the closure's type is unknown or non-trait.
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

                // A1: every lambda takes a hidden leading `__env` parameter (the
                // closure's captured-variable environment). User params follow.
                const param_names = try self.allocator.alloc([]const u8, cl.params.len + 1);
                param_names[0] = "__env";
                for (cl.params, 0..) |p, i| {
                    param_names[i + 1] = p;
                }

                // Record explicit `(s: string)` param types so the body types them directly.
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
                    // F4 4b: the closure inherits its enclosing body's instantiation.
                    // `(k, v) => result.push(k)` inside `Map<string,i32>.keys()` is
                    // code FOR that instantiation; emitted without this it is erased,
                    // and `result.push(k)` binds to `List_push` — which does not
                    // retain, so the List's element has no owner (§3.4d).
                    .instantiation = self.current_collecting_instantiation,
                    // F4-5: the closure inherits its enclosing specialized method's subst too, so its
                    // body compiles with `T` -> concrete (the `serde.bind<T>` inside an `App.get<T>`
                    // dispatcher resolves the right binder).
                    .method_subst = self.current_collecting_method_subst,
                    // M3: a closure of an ERASED generic body is erased too — let R2 skip it when dead so
                    // it stops pinning the erased List_push/List_grow (the last abstract residue).
                    .erased_generic = self.current_collecting_erased_generic,
                    .source_file = cl.span.file,
                };                try self.functions.append(self.allocator, info);
                const ckey = try self.closureKey(cl.span, self.current_collecting_instantiation);
                try self.closure_lambdas.put(self.allocator, ckey, lambda_name);
                // Ensure every lambda has a (possibly empty) capture list.
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
            // `??` — a closure literal on either side (a default factory
            // `map.get(k) ?? ((sp) => ServiceImpl())`) must be collected, else it is never
            // registered and compiling it raises LambdaNotFound. This arm was missing.
            .nullish_coalesce => |nc| {
                try self.collectClosuresFromExpr(nc.left.*);
                try self.collectClosuresFromExpr(nc.right.*);
            },
            // A closure inside a cast (`(() => ...) as T`).
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

    /// Is `obj.member` a namespace access (module / type / builtin receiver) rather than
    /// a field access on a variable? Used by capture scanning so a receiver like `url`
    /// in `url.decode(...)` is not mistaken for a captured free variable.
    fn isNamespaceReceiver(self: *LlvmCompiler, obj_name: []const u8, member: []const u8) bool {
        // Module-qualified TYPE: `response.Response(...)` / `response.Response.ok(...)` — the
        // MEMBER names a type. Without this the module (`response`) is captured as a phantom
        // free variable when the reference sits inside a closure (mediator.nova's `send`
        // pipeline closures died with "Identifier 'response' not found").
        if (self.structs.contains(member)) return true;
        if (self.enums.contains(member)) return true;
        // Builtin receivers dispatched by name in codegen.
        if (std.mem.eql(u8, obj_name, "console") or std.mem.eql(u8, obj_name, "bytes")) return true;
        // F4-5: `serde` is the intrinsic pseudo-module for `serde.bind<T>` / `serde.typeName<T>`.
        // Not a real imported module, so it must be excluded from closure capture explicitly —
        // otherwise a dispatcher closure inside `App.get<T>` captures `serde` as a phantom local.
        if (std.mem.eql(u8, obj_name, "serde")) return true;
        // Types: `Point.origin()` (static method), enum variant access.
        if (self.structs.contains(obj_name)) return true;
        if (self.enums.contains(obj_name)) return true;
        // Modules: `url.decode` mangles to `web_url_decode` (path `/`→`_`), `string.split`
        // to `string_split`. So it is a module call iff some function equals `{obj}_{member}`
        // or ends with `_{obj}_{member}` (the multi-segment case, e.g. web.url).
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
                // Builtin receivers (`console.log`, `bytes.alloc`) are NOT variables — they
                // are dispatched by name in codegen. Capturing them as free variables made
                // a phantom capture of a non-existent local, so `console.log` inside a
                // closure died with "Identifier 'console' not found" (broke web/server).
                if (std.mem.eql(u8, name, "console") or std.mem.eql(u8, name, "bytes")) return;
                if (lambda_params.contains(name)) return;
                if (lambda_locals.contains(name)) return;
                if (self.constants.contains(name)) return;

                // Skip top-level functions — they are resolved by name at call-time,
                // not captured as variables.  Creating a captured global for them would
                // leave the global as NULL (never written by the parent), causing a
                // segfault when the lambda tries to call through the null pointer.
                // Function names may be module-prefixed (e.g. "web_server_handleConnection")
                // while the captured identifier is the bare name ("handleConnection").
                for (self.functions.items) |f| {
                    if (std.mem.eql(u8, f.name, name)) return;
                    // Check for module-prefixed names: "prefix_name"
                    const suffix = try std.fmt.allocPrint(self.allocator, "_{s}", .{name});
                    defer self.allocator.free(suffix);
                    if (std.mem.endsWith(u8, f.name, suffix)) return;
                }

                // Skip TYPE names — a struct/enum in `P(7)` or `E.Ok` is resolved by name at
                // codegen (its constructor is `P_init`/`P_new`, not a variable `P`), exactly
                // like a top-level function above. Without this, `let f = () => { return P(7); }`
                // captured `P` as a free variable, and the lifted body compiled `P` down the
                // ident path — "Identifier 'P' not found". Module-qualified `mod.P(...)` already
                // worked (its receiver is skipped by isNamespaceReceiver), which is why only the
                // ROOT-module struct ctor failed — the reverse of what §5 guessed.
                if (self.structs.contains(name)) return;
                if (self.enums.contains(name)) return;
                
                // A1: record `name` in the current lambda's ordered capture list
                // (deduplicated). The value is snapshotted into the closure's env
                // at codegen time; see the .closure case in expressions.zig.
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
                // `namespace.member` — where `namespace` is a module (`url.decode`), a
                // type (`Point.origin`), or a builtin receiver (`console.log`) — is NOT a
                // variable access, so the receiver must not be captured. Recursing here
                // captured the module name as a phantom free variable: `string.split`
                // survived only by accident (a `_string`-suffixed function made the
                // .ident scan skip it) while `url.decode` died with "Identifier 'url' not
                // found". Detect the namespace up front and skip it.
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
        // `<serde-generated>` is the parser label for the compiler-generated `<Struct>__bind` /
        // `__toJson` binders (main.zig:generateSerdeBinders). They are GLOBAL helpers with no module
        // scope — exactly like `helpers.nova` / `test_harness.nova` — and are CALLED bare
        // (`Order__bind(src)`). Emitting them with a `<serde-generated>_` module prefix (as any other
        // file gets) made the definition `<serde-generated>_Order__bind` while the call stayed
        // `Order__bind`, so exact resolution missed and the call fell through to the func_map suffix
        // SCAN (F1-3b). Treating them as global (null prefix) makes definition and call agree, so the
        // call resolves EXACTLY and — since the binders are sema-walked — carries a SymbolId. (F4-6)
        if (span.file.len == 0 or std.mem.eql(u8, span.file, self.program.span.file) or std.mem.eql(u8, span.file, "helpers.nova") or std.mem.eql(u8, span.file, "test_harness.nova") or std.mem.eql(u8, span.file, "<serde-generated>")) {
            return null;
        }
        // Strip whichever stdlib root this file was found under.
        //
        // This used to strip ONLY `src/std/` and `src/lib/` — but the loader falls
        // back to an ABSOLUTE "$HOME/.nova/std/{sub}" (main.zig:422), which matched
        // neither, so the whole absolute path got mangled into the linker symbol:
        //
        //     src/std/string.nova    -> string_hash
        //     ~/.nova/std/string.nova -> _Users_kamlesh_.nova_std_string_hash
        //
        // i.e. the SAME FILE produced a different symbol depending on which path it
        // was resolved through, and the developer's home directory ended up in the
        // binary — 109 of 204 symbols (53%) on ycsb.nova. Builds were not
        // reproducible across machines or checkouts.
        //
        // `indexOf` rather than `startsWith` so an absolute path containing the root
        // (e.g. /abs/checkout/lang/src/std/...) canonicalises too. The `.nova/std/`
        // case now yields exactly what the `src/std/` case already yielded, so
        // src-resolved builds are unchanged and HOME-resolved builds simply agree.
        // Verified with NOVA_SEMA_SHADOW=1 before cutover: 0 new collisions — which
        // mattered, because declarations.zig:737-748 dedups functions by name and a
        // collision introduced here would have silently dropped one.
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
            if (char == '/' or char == '\\') {
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
        // Pass 1: Collect structs
        for (program.declarations) |decl| {
            if (decl == .struct_decl) {
                const s = decl.struct_decl;
                // F1 module-scoped types: key a colliding struct under its module-unique name (the same
                // spelling `resolveExpressionTypeName` yields for a reference); a non-colliding struct
                // keys under its bare name, unchanged.
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

                    // F4 4b: ONE body per INSTANTIATION, not one erased body per
                    // declaration. `List<int>` and `List<string>` need different
                    // code — that is the whole claim of monomorphization — and the
                    // single `List_push` that served both is why ARC inside it could
                    // not decide whether to retain (F4 §5, 4b).
                    //
                    // The instantiation set comes from stage 3's worklist, which is
                    // exact and bounded (recursion-guarded, §3.6), so this cannot
                    // instantiate forever.
                    for (try self.instantiationsOf(s)) |inst_opt| {
                        // F1 module-scoped types: a colliding struct's method is emitted under its
                        // module-unique owner (`_mod_Widget_val`) so it matches the call site, which
                        // derives the same owner from resolveExpressionTypeName. Non-colliding → bare.
                        const owner = inst_opt orelse self.scopedStructName(s.name, s.span.file); // "List<string>" | scoped-or-bare
                        const full_name = try self.methodSymbol(owner, fn_decl.name);
                        // The return type is a DECLARED type, so it goes through
                        // typeRefToString — which substitutes only while the context
                        // is set. `List<T>.get` returns `T`; `List_string_get` must
                        // say it returns `string`, or the caller reads it as opaque.
                        const prev_inst = self.current_instantiation;
                        self.current_instantiation = inst_opt;
                        defer self.current_instantiation = prev_inst;

                        // F4-5 method-level monomorphization: for a generic METHOD (`get<T>`),
                        // emit one specialized body per recorded (receiver-inst × method ×
                        // concrete-args) from the sema worklist — `App_get__GetUser`. Inside each,
                        // `current_method_subst` makes `T` render concrete (so `json.parse<T>`
                        // reifies the right binder). When at least one specialization exists we do
                        // NOT emit the method-ERASED body: it would contain an unresolvable `T`
                        // (e.g. `json.parse<T>` -> no struct `T`), and every concrete call routes
                        // to a specialization anyway. Non-generic methods, and generic ones never
                        // called with concrete args, keep the single body below unchanged.
                        if (fn_decl.type_params.len > 0) {
                            for (sema_mono.method_insts.items) |mi| {
                                if (!std.mem.eql(u8, mi.inst_name, owner)) continue;
                                if (!std.mem.eql(u8, mi.method, fn_decl.name)) continue;
                                if (mi.params.len != fn_decl.type_params.len) continue;

                                const subst = try self.allocator.alloc(MethodParamBinding, mi.params.len);
                                for (mi.params, mi.args, 0..) |pn, an, i| {
                                    subst[i] = .{ .name = pn, .concrete = an };
                                }

                                // Specialized symbol: `App_get` ++ "__" ++ mangled args.
                                var name_buf = std.ArrayListUnmanaged(u8).empty;
                                try name_buf.appendSlice(self.allocator, full_name);
                                for (mi.args) |an| {
                                    const ma = try types_mod.mangleTypeName(self.allocator, an);
                                    defer self.allocator.free(ma);
                                    try name_buf.appendSlice(self.allocator, "__");
                                    try name_buf.appendSlice(self.allocator, ma);
                                }
                                const spec_name = try name_buf.toOwnedSlice(self.allocator);

                                // Compute the return type with BOTH the struct inst and the method
                                // subst installed, so a `T` return renders the concrete type.
                                const prev_ms = self.current_method_subst;
                                self.current_method_subst = subst;
                                const spec_ret = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void";
                                self.current_method_subst = prev_ms;

                                try self.functions.append(self.allocator, .{
                                    .name = spec_name,
                                    .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                                    .param_names = param_names,
                                    .return_type = spec_ret,
                                    // V1: keep the un-erased TypeRef; the return site substitutes
                                    // V→concrete via the installed `method_subst` when it renders it.
                                    .ret_type_ref = fn_decl.ret_type,
                                    .body = fn_decl.body,
                                    .is_async = fn_decl.is_async,
                                    .instantiation = inst_opt,
                                    .method_subst = subst,
                                    .source_file = fn_decl.span.file,
                                });
                            }
                        }

                        // Emit the method-erased/base body, EXCEPT for a generic method reached only
                        // by EXPLICIT-arg calls. Inferred-arg calls (`xs.map((x)=>..)`) route to this
                        // base name (`List_int_map`), so it must exist — skipping it broke map/reduce.
                        // Explicit-arg calls (`app.get<GetUser>`, `serde.bind<T>` reifies) route to a
                        // specialization, so the base is dead AND may not compile (a `<T>__bind` with
                        // no concrete T) — skip it there.
                        const skip_base = fn_decl.type_params.len > 0 and !sema_mono.baseIsNeeded(owner, fn_decl.name);
                        if (!skip_base) {
                            const info = FunctionInfo{
                                .name = full_name,
                                .param_count = if (is_constructor) fn_decl.params.len + 1 else fn_decl.params.len,
                                .param_names = param_names,
                                .return_type = if (fn_decl.ret_type) |ret| try self.typeRefToString(ret) else "void",
                                .ret_type_ref = fn_decl.ret_type, // V1 value-optional boxing
                                .body = fn_decl.body,
                                .is_async = fn_decl.is_async,
                                .instantiation = inst_opt,
                                // M3: erased iff (a) the struct-erased body of a generic struct, OR (b) the
                                // method-ERASED BASE of a generic method (`List_i32_map`, U unbound). An
                                // inferred-arg call now routes to the single specialization (ARC-reconciled),
                                // so this base is usually dead — internal linkage lets R2/globalDCE drop it
                                // when it has 0 uses; a still-referenced base (multi-spec) survives.
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
                        .ret_type_ref = fn_decl.ret_type, // V1 value-optional boxing
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

        // Pass 2: Collect functions (with auto-namespacing)
        for (program.declarations) |decl| {
            if (decl == .fn_decl) {
                const fn_decl = decl.fn_decl;
                // T3 FFI: an `extern("lib") fn` has no Nova body — it is declared as an LLVM
                // external in declarations.zig, not emitted here. Skip it so we never try to
                // build a body for it (which would clobber the external declaration).
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
                    .ret_type_ref = fn_decl.ret_type, // V1 value-optional boxing
                    .body = fn_decl.body,
                    .is_async = fn_decl.is_async,
                    .source_file = fn_decl.span.file,
                };

                // FREE-FN MONOMORPHIZATION: emit the erased base only for NON-generic or ASYNC fns. A SYNC
                // generic free fn never needs its T-erased base: Nova has no free-fn type-arg INFERENCE, so
                // every call carries explicit args and routes to a specialization (`maybe__int`), and an
                // uncalled one is dead. Skipping it is also NECESSARY — a generic body may contain reify
                // intrinsics (`serde.bind<T>` → `<T>__bind`) or value-representation-dependent code that only
                // compiles with a concrete T (exactly why struct methods skip their base). ASYNC generic fns
                // (`when_all<T>`) are the exception: the coroutine RAMP resolves to the base symbol, so it
                // must survive — and their bodies use no reify intrinsics.
                if (fn_decl.type_params.len == 0 or fn_decl.is_async) try self.functions.append(self.allocator, info);

                // Emit one SPECIALIZED body per recorded (fn × concrete-args) instantiation — `maybe__int`
                // — exactly as struct methods do (Pass 1 above). Inside each spec `current_method_subst`
                // binds T→concrete, so `T | undefined` boxes correctly (V1) and reifies resolve.
                if (fn_decl.type_params.len > 0) {
                    for (sema_mono.free_fn_insts.items) |fi| {
                        if (!std.mem.eql(u8, fi.fn_name, fn_decl.name)) continue;
                        if (fi.params.len != fn_decl.type_params.len) continue;

                        const subst = try self.allocator.alloc(MethodParamBinding, fi.params.len);
                        for (fi.params, fi.args, 0..) |pn, an, i| {
                            subst[i] = .{ .name = pn, .concrete = an };
                        }

                        // Specialized symbol: `<emitted base name>` ++ "__" ++ mangled args (mirrors the
                        // struct-method spec name AND the call-site resolver in the `.generic_call` arm).
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

                        // Render the return type with method_subst installed so `T | undefined` → the
                        // concrete `int | undefined` string (the `.optional` is erased by typeRefToString,
                        // but the return SITE reads `ret_type_ref` + the subst, so boxing still fires).
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

    /// Takes the block/statements BY REFERENCE. This pass resolves EVERY `let`
    /// initialiser in every function, so when it took `ast.Statement` by value every
    /// `&init` was a stack address — resolving correctly, matching the TypedIr
    /// never. That was the bulk of stage 3's "not in the IR".
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
                        // F5-2 (B1): the initializer is a tuple, so project element `idx`'s TypeId
                        // straight out of the tuple's TypeId — the destructured binding's ownership is
                        // then decided by the store, not by re-parsing the rendered element name.
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
                        // A2 coverage: an ANNOTATED let carries its type as a TypeRef, so key it by TypeId
                        // (lowered in the store) — its scope-exit release then selects the store-native
                        // destructor instead of the isRefCountedType(string) fallback.
                        if (self.current_local_type_ids) |ids| {
                            if (self.tidForTypeRef(t)) |tid| try ids.put(ls.name, tid);
                        }
                    } else if (ls.init) |*init| {
                        const resolved0 = try self.resolveExpressionTypeName(init);
                        // F4-5: inside a specialized generic-method/closure body the inferred type may
                        // still render as the method param; substitute to concrete so an owned local
                        // (`let req = serde.bind<T>(..)`) is recognized and RELEASED at scope exit.
                        // No-op outside a specialized body (method subst is null).
                        const resolved = if (resolved0) |r| try self.substTypeParams(r) else null;
                        if (resolved) |name| {
                            try map.put(ls.name, name);
                            // F5-2 (B3, the easy case): the initializer expression is in hand, so
                            // `typeOf` gives the TypeId directly — record it in the parallel map so
                            // this local's ownership is decided by the store, not the rendered name.
                            if (self.current_local_type_ids) |ids| {
                                if (self.typed_ir) |ir| {
                                    if (ir.typeOf(init)) |tid| {
                                        // F4 keystoneSubst removal (step 2): in a monomorphized body, store
                                        // the CONCRETE per-instantiation type (from inst_disp) so every
                                        // consumer of this map — isOwnedLocal, the local drain — decides
                                        // from the concrete type without codegen substituting.
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

    pub const compileStatement = statements_mod.compileStatement;
    pub const runErrdefers = statements_mod.runErrdefers;

    pub const compileExpression = expressions_mod.compileExpression;
    pub const consumeTemporary = expressions_mod.consumeTemporary;
    pub const atomicCell = expressions_mod.atomicCell;
    pub const guardOptionalDeref = expressions_mod.guardOptionalDeref;
    pub const registerTemporary = expressions_mod.registerTemporary;
    pub const drainTemporaries = expressions_mod.drainTemporaries;
    pub const buildClosureCall = expressions_mod.buildClosureCall;
    pub const buildBareFnBox = expressions_mod.buildBareFnBox;
    pub const fnBoxReturn = expressions_mod.fnBoxReturn;
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
    pub const numToString = expressions_mod.numToString;
    pub const numToStringImpl = expressions_mod.numToStringImpl;
    pub const numToStringT = expressions_mod.numToStringT;
    pub const compileJsxElement = expressions_mod.compileJsxElement;
    pub const compileGenericParse = expressions_mod.compileGenericParse;
    pub const compileDecodeBinaryRow = expressions_mod.compileDecodeBinaryRow;
    pub const compileBTreeQuery = expressions_mod.compileBTreeQuery;
    pub const convertValueToType = expressions_mod.convertValueToType;
    pub const resolveReifyTypeName = expressions_mod.resolveReifyTypeName;
    pub const getFunc = expressions_mod.getFunc;
};


pub const compile = declarations_mod.compile;
