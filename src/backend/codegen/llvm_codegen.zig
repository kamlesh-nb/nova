//! The LLVM code-generation backend: the compiler's final lowering stage, where
//! the type-checked Nova program becomes an LLVM module ready to be optimised and
//! emitted as a native object (or a WASM module).
//!
//! This file defines [`LlvmCompiler`], the single large stateful object that owns
//! the whole codegen pass: the LLVM module and IR builder, the target machine, all
//! the symbol tables carried over from the frontend (structs, enums, unions, traits,
//! constants, functions), the caches that make per-expression type resolution cheap,
//! and the debug-info (DWARF) machinery. Every other file in `codegen/` hangs methods
//! off this struct rather than defining a parallel state object, which is why the
//! bottom of this file is a long list of `pub const foo = other_module.foo;` lines:
//! they graft the methods implemented in `arc.zig`, `types.zig`, `statements.zig`,
//! `expressions.zig`, and `declarations.zig` onto [`LlvmCompiler`] so that, from a
//! caller's point of view, `self.compileExpression(...)`, `self.compileRetain(...)`
//! and the local helpers here all live on one object. The split is purely to keep
//! each source file to a workable size; semantically it is one class.
//!
//! Key design decisions and invariants this file embodies:
//!
//!   - **One machine word is `i64` (`val_type`).** Almost every Nova value flows
//!     through codegen as a 64-bit integer, whether it is a real integer, a float
//!     bit-cast into a word, or a heap address. Heap addresses MUST stay 64-bit:
//!     computing `addr + offset` at `i32` truncates the pointer and produces a
//!     wild address, which is the single most common class of miscompile here.
//!     Pointer-sized helpers ([`LlvmCompiler.ptrElemSize`], [`LlvmCompiler.valSlotSize`])
//!     exist because WASM is a 32-bit target where a word is 4 bytes.
//!
//!   - **Monomorphization, not type erasure.** Generics are instantiated per
//!     concrete type argument. [`LlvmCompiler.collectFunctions`] walks every struct
//!     method and free function and, for each recorded instantiation (from
//!     `sema/mono.zig`), registers a distinct mangled `FunctionInfo`. An erased
//!     "base" body is emitted only as an `internal`-linkage fallback that later
//!     dead-code elimination usually drops. [`LlvmCompiler.expandFreeFnInstsTransitively`]
//!     fixes the point where one generic instantiation calls another until no new
//!     instantiation is discovered.
//!
//!   - **ARC, decided in codegen.** There is no garbage collector. Ownership is
//!     resolved here and in `arc.zig`: heap objects carry an 8-byte header
//!     (refcount at -8, length at -4), `nova_retain`/`nova_release` bracket
//!     borrows and drops, and value structs are copied inline with their owned
//!     fields deep-retained. This file provides the allocation primitives
//!     ([`LlvmCompiler.compileAlloc`], [`LlvmCompiler.compileAllocPersistent`],
//!     [`LlvmCompiler.compileFree`]) and the WASM in-IR allocator
//!     ([`LlvmCompiler.generateWasmMemoryFunctions`]); the retain/release policy
//!     itself is grafted in from `arc.zig`.
//!
//!   - **Traits dispatch through fat pointers.** A trait object is a two-word heap
//!     block `{struct_ptr, vtable_ptr}`; vtable slot 0 is always the destructor and
//!     slots 1..N are the trait methods in declaration order. See
//!     [`LlvmCompiler.getGlobalVTable`], [`LlvmCompiler.constructTraitObject`] and
//!     [`LlvmCompiler.buildTraitVtableCall`].
//!
//!   - **Value optionals ("valopt") are a real ABI, not just null.** A value type
//!     wrapped in an optional (`int?`, an unowned enum, or a nested `int??`) is
//!     boxed so that "present zero" is distinguishable from "absent". The
//!     [`LlvmCompiler.valueOptionalInner`] / [`LlvmCompiler.valoptDepth`] pair and
//!     the `buildValopt*`/`coerceValoptArg` helpers implement the boxing rules and
//!     the depth-matching a call site needs when an argument is more deeply boxed
//!     than the parameter expects.
//!
//! The debug-info half of the file (all the `di*` helpers) builds DWARF only for
//! native, non-release builds; every one of those functions is a no-op when
//! `di_builder` is null, so callers never have to guard the debug case themselves.

const std = @import("std");
/// The abstract syntax tree the frontend produced; codegen reads declarations,
/// statements, expressions and type references straight off it.
const ast = @import("../../frontend/ast.zig");
/// Monomorphization bookkeeping: the recorded set of concrete generic
/// instantiations ([`sema_mono.method_insts`], `free_fn_insts`) that this pass
/// turns into distinct emitted functions.
const sema_mono = @import("../../frontend/sema/mono.zig");
/// Reachability analysis: lets codegen skip generic struct methods that are never
/// actually called, so the erased base body is not emitted needlessly.
const sema_reach = @import("../../frontend/sema/reach.zig");
/// The LLVM-C binding (`deps/llvm-zig`), re-exported below as `types`/`core`/etc.
const llvm = @import("llvm");

/// LLVM opaque handle types (`LLVMValueRef`, `LLVMTypeRef`, enums for linkage,
/// predicates, and so on).
const types = llvm.types;
/// The LLVM-C `Core` API: module/builder/type/value construction and the IR
/// builder instructions (`LLVMBuild*`).
const core = llvm.core;
/// The LLVM-C target-initialisation API (`LLVMInitializeAll*`).
const target = llvm.target;
/// The LLVM-C debug-info API (`LLVMDIBuilder*`) used to emit DWARF.
const debug = llvm.debug;
/// The LLVM-C target-machine API: triple resolution, host CPU/features, data layout.
const target_machine = llvm.target_machine;
/// The LLVM-C module-verification API. Imported for completeness; verification is
/// driven from the driver, not from this file.
const analysis = llvm.analysis;
/// Coverage-instrumentation support (block registry + emitted counters).
const coverage_mod = @import("coverage.zig");
/// One instrumented basic block in the coverage map; re-exported so callers reach
/// it as `LlvmCompiler.CoverageBlock`.
pub const CoverageBlock = coverage_mod.CoverageBlock;
/// The per-module registry of coverage blocks, populated when `coverage_enabled`.
pub const CoverageRegistry = coverage_mod.CoverageRegistry;

/// Shared codegen type utilities (name mangling, primitive classification, LLVM
/// type mapping, expression-type resolution). Most of its functions are grafted
/// onto [`LlvmCompiler`] at the bottom of this file.
const types_mod = @import("types.zig");
/// The frontend's typed IR: the authoritative `TypeId`-annotated view of every
/// expression, consulted whenever a legacy name-based decision is not precise enough.
const sema_infer = @import("../../frontend/sema/infer.zig");
/// The frontend type store and `TypeId` model; the source of truth for ownership
/// and the value/reference distinction.
const sema_types = @import("../../frontend/types.zig");
/// The shadow/diagnostic layer that cross-checks the legacy string-based type
/// engine against the typed IR, plus `renderLegacy` for turning a `TypeId` back
/// into a mangled name.
const sema_shadow = @import("../../frontend/sema/shadow.zig");
/// Strips a generic type's `<...>` suffix to its base name (e.g. `List<int>` ->
/// `List`); used constantly to look a type up in the struct/enum tables.
const getStructBaseName = types_mod.getStructBaseName;
/// Predicate: whether a type name is one of the built-in primitive scalar types.
const isPrimitiveTypeName = types_mod.isPrimitiveTypeName;
/// The ARC (retain/release/destructor) policy module, grafted onto [`LlvmCompiler`] below.
const arc_mod = @import("arc.zig");
/// Statement lowering (`compileStatement`, `runErrdefers`), grafted on below.
const statements_mod = @import("statements.zig");
/// The top-level compile driver (`compile`) and codegen flags.
const declarations_mod = @import("declarations.zig");
/// Expression lowering (the bulk of `compile*` methods), grafted on below.
const expressions_mod = @import("expressions.zig");

/// Decodes the C-style backslash escapes in a Nova string literal into their
/// actual bytes, returning a freshly allocated slice the caller owns.
///
/// The lexer keeps literals in their escaped source form (`\n`, `\t`, `\\`,
/// `\"`, `\'`); codegen calls this to get the real byte content before laying it
/// out as an LLVM constant array (see [`LlvmCompiler.getOrCreateStringLiteral`]).
/// An unrecognised escape is passed through verbatim, backslash and all, rather
/// than being dropped, so no information is lost on a malformed literal. A
/// trailing lone backslash (no following byte) is emitted as-is.
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

/// A single function or method scheduled for emission, in the flattened,
/// monomorphized form codegen actually walks.
///
/// [`LlvmCompiler.collectFunctions`] produces one `FunctionInfo` per concrete
/// thing to emit: a plain function, a struct/enum method, one generic
/// instantiation, or a synthesised lambda body. A generic method with N recorded
/// instantiations becomes N entries with distinct mangled [`FunctionInfo.name`]s
/// plus, unless `sema_mono.baseIsNeeded` says otherwise, one erased base entry.
/// The `declarations.zig` emission pass consumes this list.
pub const FunctionInfo = struct {
    /// The fully mangled symbol name to emit (module prefix, struct owner and
    /// type-argument suffix already applied).
    name: []const u8,
    /// Number of LLVM parameters, counting the leading `self` for methods and the
    /// leading `__env` for lambdas.
    param_count: usize,
    /// Parameter names in order, parallel to `param_count`. Several `FunctionInfo`s
    /// for the same method may share one backing slice; `deinit` frees each unique
    /// pointer only once.
    param_names: []const []const u8,
    /// The rendered return-type name (`"void"` when the source had none), used for
    /// void-call detection and slot typing.
    return_type: []const u8,

    /// The un-rendered return type reference, kept so codegen can re-render it
    /// under the correct instantiation context; null for constructors/lambdas.
    ret_type_ref: ?ast.TypeRef = null,
    /// The function body to lower.
    body: ast.Block,
    /// The source parameter list (empty for constructors, which synthesise `self`).
    params: []const ast.Param = &.{},

    /// Whether this is an `async` function, lowered to an LLVM coroutine.
    is_async: bool = false,

    /// The owning concrete instantiation name (e.g. `List_int`) when this entry is
    /// a specialised method; null for non-generic or erased entries.
    instantiation: ?[]const u8 = null,
    /// The `TypeId` of the instantiation, the precise counterpart to
    /// `instantiation`, used to render types exactly under this specialisation.
    instantiation_id: ?sema_types.TypeId = null,

    /// True for the erased "base" body of a generic: emitted with internal linkage
    /// as a link-time fallback that global DCE normally removes.
    erased_generic: bool = false,

    /// The source file this declaration came from, used to compute its module
    /// prefix and to attach debug info to the right compile unit.
    source_file: []const u8 = "",
};

/// One lexical scope on the codegen scope stack, holding the cleanup work that
/// must run when control leaves the scope.
///
/// Nova's `defer` and `errdefer` and its ARC drops are all resolved by walking
/// this stack. On normal exit the deferred statements run and `owned_locals` are
/// released; on the error path the errdeferred statements additionally run.
pub const Scope = struct {
    /// `defer`red expressions, run in reverse on any exit from the scope.
    deferred_statements: std.ArrayList(ast.Expression),

    /// `errdefer`red expressions, run in reverse only when leaving via an error.
    errdeferred_statements: std.ArrayList(ast.Expression) = .empty,

    /// Heap-owning locals declared in this scope, released (via their destructor)
    /// when the scope ends.
    owned_locals: std.ArrayList(OwnedLocal) = .empty,
};

/// A heap-owning local variable tracked for automatic release at scope exit.
pub const OwnedLocal = struct {
    /// The local's name, keyed against `locals`.
    name: []const u8,
    /// The local's rendered type name, used to pick the correct destructor.
    type_name: []const u8,
};

/// A temporary value produced mid-expression whose ARC release is deferred to the
/// end of the enclosing statement.
///
/// Sub-expressions that allocate (a `new`, a container literal, a boxed optional)
/// register the result here so it is dropped once the full statement has consumed
/// it, rather than leaking or being freed too early. `consumeTemporary` removes an
/// entry when ownership is handed off instead.
pub const PendingTemp = struct {
    /// The temporary value (an `i64` word, usually a heap address).
    val: types.LLVMValueRef,

    /// The stack slot the value was spilled to, if one was materialised.
    slot: types.LLVMValueRef,
    /// The rendered type name, so the right destructor is chosen at drain time.
    type_name: []const u8,

    /// The AST expression id that produced this temporary, used to match a
    /// consumer that later takes ownership.
    expr_id: ast.ExprId = .unassigned,
};

/// Which SIMD instruction family the current target supports, selected from the
/// triple: `none` (including WASM), NEON on `aarch64`, or SSE/AVX on `x86_64`.
pub const SimdTarget = enum { none, aarch64, x86_64 };

/// Cache key for a type-parameter substitution: identifies an (input type string,
/// instantiation) pair by the pointer+length of the input slice plus the
/// instantiation pointer and its `TypeId`, so a repeated substitution is a hash
/// lookup rather than a re-render.
pub const SubstKey = struct { in_ptr: usize, in_len: usize, inst_ptr: usize, inst_id: u32 };

/// The whole LLVM code-generation pass, as one stateful object.
///
/// It owns the LLVM `module`/`builder`/`target_machine`, every symbol table the
/// frontend produced (structs, enums, unions, traits, constants, and the
/// `functions` worklist), the caches that keep per-expression type queries cheap,
/// the debug-info state, and a large family of `current_*` cursors that track
/// where lowering currently is (which function, which instantiation, which loop,
/// which async coroutine). Methods are spread across `arc.zig`, `types.zig`,
/// `statements.zig`, `expressions.zig` and `declarations.zig` and grafted on at
/// the bottom of this file, so this one struct is the codegen "God object".
///
/// Lifecycle: [`LlvmCompiler.new`] builds it, `collectFunctions` +
/// `collectStringLiterals` + the emission driver fill the module, and
/// [`LlvmCompiler.deinit`] frees everything. Many maps borrow slices from the AST
/// or from other tables, so `deinit` is careful about which keys/values it owns.
pub const LlvmCompiler = struct {
    /// The allocator backing every table and every transient buffer here.
    allocator: std.mem.Allocator,
    /// The LLVM module being built: the container for all emitted globals and
    /// functions, and the final unit handed to the optimiser/emitter.
    module: types.LLVMModuleRef,
    /// The shared IR builder; its insert point is repositioned constantly as
    /// lowering moves between basic blocks.
    builder: types.LLVMBuilderRef,
    /// The target machine (triple + CPU + features + data layout) that fixes ABI,
    /// pointer size and codegen options.
    target_machine: types.LLVMTargetMachineRef,
    /// The DWARF debug-info builder, or null when debug info is off (release or
    /// WASM). All `di*` helpers short-circuit to a no-op when this is null.
    di_builder: types.LLVMDIBuilderRef = null,
    /// The single DWARF compile unit, created lazily on the first function that
    /// needs debug info (see [`LlvmCompiler.ensureDebugCU`]).
    di_cu: types.LLVMMetadataRef = null,
    /// The compile unit's primary file metadata.
    di_file: types.LLVMMetadataRef = null,
    /// The working directory used to absolutise relative source paths for DWARF.
    di_cwd: ?[]const u8 = null,
    /// The current DWARF lexical scope (subprogram) that new instructions attach to.
    di_scope: types.LLVMMetadataRef = null,
    /// The file metadata paired with `di_scope`.
    di_scope_file: types.LLVMMetadataRef = null,
    /// Whether debug info is being emitted (native, non-release).
    debug_enabled: bool = false,
    /// Guard so [`LlvmCompiler.finalizeDebug`] runs the DIBuilder finalize exactly once.
    di_finalized: bool = false,
    /// Path -> DWARF file metadata cache, so each source file is described once.
    di_files: std.StringHashMap(types.LLVMMetadataRef) = undefined,
    /// Type-name -> DWARF type metadata cache (basic, struct, container and Str types).
    di_types: std.StringHashMap(types.LLVMMetadataRef) = undefined,
    /// Names already `llvm.dbg.declare`d in the current function, reset per function
    /// to avoid duplicate variable records.
    dbg_declared: std.StringHashMap(void) = undefined,
    /// The worklist of functions/methods/lambdas to emit, built by
    /// [`LlvmCompiler.collectFunctions`].
    functions: std.ArrayList(FunctionInfo),
    /// The de-duplicated set of string literals seen in the program, each of which
    /// becomes one interned global.
    strings: std.ArrayList([]const u8),
    /// The lexical scope stack (see [`Scope`]) driving defer/errdefer/ARC cleanup.
    scopes: std.ArrayList(Scope),
    /// Name -> stack-slot for the locals in the function currently being emitted.
    locals: std.StringHashMap(types.LLVMValueRef),
    /// Symbol name -> LLVM function value, the authoritative call target table
    /// (also used to lazily declare runtime `nova_*` externs).
    func_map: std.StringHashMap(types.LLVMValueRef),
    /// Cache for [`LlvmCompiler.getFunctionParamTypeRef`], keyed by `name\0index`.
    param_type_cache: std.StringHashMap(?ast.TypeRef),
    /// Cache for [`LlvmCompiler.getFunctionParamType`] (rendered string form).
    param_type_str_cache: std.StringHashMap(?[]const u8),
    /// Optional set of struct names known to escape (populated by escape analysis);
    /// reserved hook, currently unused by the hot path.
    value_escape_set: ?std.StringHashMap(void) = null,
    /// Struct declarations keyed by module-scoped name; the layout/method source of truth.
    structs: std.StringHashMap(ast.StructDecl),
    /// Union declarations keyed by name.
    unions: std.StringHashMap(ast.UnionDecl),
    /// Enum declarations keyed by module-scoped name (payload enums included).
    enums: std.StringHashMap(ast.EnumDecl),
    /// Trait declarations keyed by base name; drives vtable slot ordering.
    traits: std.StringHashMap(ast.TraitDecl),

    /// FFI `extern` function declarations keyed by name.
    ffi_externs: std.StringHashMap(ast.FunctionDecl),
    /// Compile-time constants keyed by name, inlined at use sites.
    constants: std.StringHashMap(ast.Expression),
    /// Borrowed pointer to the current function's local name -> rendered type map,
    /// or null outside a function body.
    current_local_types: ?*std.StringHashMap([]const u8),

    /// Borrowed pointer to the current function's local name -> `TypeId` map, the
    /// precise counterpart to `current_local_types`.
    current_local_type_ids: ?*std.StringHashMap(sema_types.TypeId),

    /// Set of local names that flow narrowing has proven "present" (non-null) at
    /// the current point, so an optional access can skip the null guard. This is
    /// the fix for the `?? present-0` value-optional bug.
    narrowed_present: std.StringHashMap(void),

    /// The active [`PendingTemp`] list for the statement being lowered.
    pending_temps: std.ArrayList(PendingTemp) = .empty,
    /// The struct whose method is currently being emitted (for `self`-relative
    /// name resolution), or null.
    current_struct_name: ?[]const u8,

    /// The concrete instantiation name in force while emitting a generic body,
    /// so type parameters render to their concrete arguments.
    current_instantiation: ?[]const u8,

    /// The `TypeId` of `current_instantiation`, its precise form.
    current_instantiation_id: ?sema_types.TypeId = null,

    /// When set, suppress the automatic unbox of a value-optional argument (used
    /// where the callee expects the boxed form).
    suppress_valopt_unbox: bool = false,

    /// Recursion guard/counter for synthesised default constructors, to bound
    /// mutually recursive default-init.
    default_ctor_depth: u32 = 0,

    /// Optional cache mapping a rendered type name back to its `TypeId`.
    rendered_name_ids: ?std.StringHashMapUnmanaged(sema_types.TypeId) = null,
    /// The module prefix of the function currently being emitted.
    current_module_prefix: ?[]const u8,
    /// The name of the function currently being emitted.
    current_function_name: ?[]const u8,

    /// The scope depth of the innermost loop, so `break`/`continue` know how many
    /// scopes to unwind for cleanup.
    current_loop_scope_depth: ?usize,
    /// The function name in force during the closure-collection pre-pass (which
    /// runs before emission, hence a separate cursor from `current_function_name`).
    current_collecting_function_name: ?[]const u8,

    /// The instantiation in force during closure collection.
    current_collecting_instantiation: ?[]const u8,

    /// The `TypeId` form of `current_collecting_instantiation`.
    current_collecting_instantiation_id: ?sema_types.TypeId = null,

    /// Whether the closure-collection pass is inside an erased generic body.
    current_collecting_erased_generic: bool = false,
    /// Lambda name -> the enclosing function whose locals it may capture.
    lambda_parents: std.StringHashMap([]const u8),

    /// Lambda name -> its declared parameter types (parallel to its params).
    lambda_param_types: std.StringHashMap([]const ?[]const u8),
    /// Function name -> its local name/type map, retained across passes.
    function_local_types: std.StringHashMap(std.StringHashMap([]const u8)),

    /// Function name -> its local name/`TypeId` map.
    function_local_type_ids: std.StringHashMap(std.StringHashMap(sema_types.TypeId)),
    /// Names captured by reference as module globals (keys are owned and freed in
    /// `deinit`).
    captured_globals: std.StringHashMap(types.LLVMValueRef),

    /// Lambda name -> the ordered list of variable names it captures into its `__env`.
    lambda_captures: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Globals that hold boxed bare-function values, keyed by function name.
    fn_box_globals: std.StringHashMap(types.LLVMValueRef),

    /// Borrowed handle to the frontend's typed IR, consulted for precise
    /// per-expression `TypeId`s; null if unavailable.
    typed_ir: ?*const sema_infer.TypedIr = null,

    /// Whether the typed-IR ("F2 types") path is active for type decisions.
    f2_types: bool = false,
    /// Borrowed handle to the type store, the source of truth for ownership and
    /// the value/reference distinction.
    type_store: ?*const sema_types.TypeStore = null,
    /// The lambda whose captures are currently being scanned (guards recursive scans).
    current_scanning_lambda: ?[]const u8 = null,
    /// The whole program AST; scanned repeatedly for declarations and generic call sites.
    program: ast.Program,
    /// Whether the program uses `log`/`console`, so the log runtime is declared.
    has_log: bool,
    /// Monotonic counter minting unique `__lambda_N` names.
    next_lambda_id: u32,

    /// Closure-key -> synthesised lambda name, so a closure expression resolves to
    /// the function that was collected for it.
    closure_lambdas: std.StringHashMapUnmanaged([]const u8),
    /// Saved capture values for the closure currently being built.
    current_saved_captures: std.StringHashMap(types.LLVMValueRef),
    /// Whether the target is WebAssembly (32-bit words, in-IR allocator, no DWARF).
    is_wasm: bool,
    /// The SIMD family available on the target (see [`SimdTarget`]).
    simd_target: SimdTarget = .none,
    /// Whether coverage instrumentation is being emitted.
    coverage_enabled: bool,
    /// The coverage block registry, present only when `coverage_enabled`.
    cov_registry: ?CoverageRegistry,
    /// The string builder value in scope while lowering a template/JSX expression.
    current_string_builder: ?types.LLVMValueRef = null,
    /// Accumulated literal bytes pending flush during JSX lowering.
    jsx_pending_literal: std.ArrayListUnmanaged(u8) = .empty,
    /// Parameter names of the function currently being emitted.
    current_param_names: ?[]const []const u8 = null,

    /// The promise value of the async coroutine currently being emitted.
    current_async_promise: ?types.LLVMValueRef = null,
    /// The coroutine's final/return basic block.
    current_async_final_bb: ?types.LLVMBasicBlockRef = null,
    /// The coroutine handle of the async function currently being emitted.
    current_async_hdl: ?types.LLVMValueRef = null,
    /// The coroutine's suspend basic block.
    current_async_suspend_bb: ?types.LLVMBasicBlockRef = null,
    /// The coroutine's cleanup basic block.
    current_async_cleanup_bb: ?types.LLVMBasicBlockRef = null,

    /// Set of async function names, so a call to one is driven as a coroutine.
    async_fns: std.StringHashMap(void) = undefined,

    /// Cached `i1` (bool) LLVM type.
    i1_type: types.LLVMTypeRef,
    /// Cached `i8` LLVM type.
    i8_type: types.LLVMTypeRef,
    /// Cached `i32` LLVM type (`int`).
    i32_type: types.LLVMTypeRef,
    /// Cached `i64` LLVM type (`long`).
    i64_type: types.LLVMTypeRef,
    /// Cached `void` LLVM type.
    void_type: types.LLVMTypeRef,
    /// Cached opaque pointer LLVM type.
    ptr_type: types.LLVMTypeRef,
    /// The universal Nova value type: `i64`. Nearly every value flows through
    /// codegen as this word (integer, bit-cast float, or heap address).
    val_type: types.LLVMTypeRef,

    /// String literal text -> its interned global (see
    /// [`LlvmCompiler.getOrCreateStringLiteral`]); keys are owned.
    string_globals: std.StringHashMap(types.LLVMValueRef),
    /// `TypeId` -> its cached rendered name, to avoid re-rendering.
    type_name_cache: std.AutoHashMapUnmanaged(sema_types.TypeId, []const u8) = .empty,
    /// Cache for type-parameter substitution results (see [`SubstKey`]).
    subst_cache: std.AutoHashMapUnmanaged(SubstKey, []const u8) = .empty,
    /// Decimal-literal digits -> a lazily-initialised cache global holding the
    /// parsed decimal (see [`LlvmCompiler.getOrCreateDecimalLiteral`]); keys are owned.
    decimal_globals: std.StringHashMap(types.LLVMValueRef),

    /// Lazily-declared `puts` runtime function.
    puts_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared `printf` runtime function.
    printf_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared `nova_log_string` runtime function.
    nova_log_string_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared `nova_log_info` runtime function.
    nova_log_info_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared `nova_log_debug` runtime function.
    nova_log_debug_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared `nova_log_err` runtime function.
    nova_log_err_fn: ?types.LLVMValueRef = null,
    /// Lazily-declared generic log function.
    log_fn: ?types.LLVMValueRef = null,
    /// The bump-allocator heap pointer global (used by the in-IR WASM allocator).
    heap_ptr: ?types.LLVMValueRef = null,
    /// The persistent-allocation free-list head global.
    free_list: ?types.LLVMValueRef = null,
    /// The persistent-arena bump pointer global.
    persistent_ptr: ?types.LLVMValueRef = null,
    /// The `break` target basic block of the innermost loop.
    current_break_bb: ?types.LLVMBasicBlockRef = null,
    /// The `continue` target basic block of the innermost loop.
    current_continue_bb: ?types.LLVMBasicBlockRef = null,

    /// Constructs a fresh compiler for one target: initialises all LLVM targets,
    /// resolves the triple, creates the target machine, module, builder and data
    /// layout, and (for native non-release builds) the DWARF DIBuilder.
    ///
    /// `is_wasm` forces the `wasm32-unknown-unknown` triple and disables debug
    /// info; otherwise `target_triple_opt` selects a cross-target or, when null,
    /// the host default triple with host CPU + feature detection. `is_release`
    /// picks aggressive vs. no optimisation and turns debug info off. Returns an
    /// error if the triple or target machine cannot be created.
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
            .narrowed_present = std.StringHashMap(void).init(allocator),
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

    /// Returns (and caches) the DWARF file metadata for a source path, resolving
    /// it to an absolute directory + basename so a debugger can find the file.
    ///
    /// Synthetic files (basename starting with `<`) and already-absolute paths are
    /// used as-is; `src/std/...` paths are remapped to the installed
    /// `~/.nova/std/...` location; everything else is joined against `di_cwd`. If
    /// the resolved absolute file does not actually exist on disk, it caches and
    /// returns null so no bogus DWARF file is emitted. A null `di_builder` short-
    /// circuits to null.
    fn diFileFor(self: *LlvmCompiler, path: []const u8) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_files.get(path)) |f| return f;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir_rel = if (slash) |s| path[0..s] else ".";
        const base_s = if (slash) |s| path[s + 1 ..] else path;
        const synthetic = base_s.len > 0 and base_s[0] == '<';
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_s: []const u8 = blk: {
            if (synthetic) break :blk dir_rel;
            if (dir_rel.len > 0 and dir_rel[0] == '/') break :blk dir_rel;
            if (std.mem.startsWith(u8, dir_rel, "src/std")) {
                if (std.c.getenv("HOME")) |home_c| {
                    const rest = dir_rel["src/std".len..];
                    const joined = std.fmt.bufPrint(&abs_buf, "{s}/.nova/std{s}", .{ std.mem.span(home_c), rest }) catch break :blk dir_rel;
                    break :blk joined;
                }
            }
            const cwd = self.di_cwd orelse break :blk dir_rel;
            const joined = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd, dir_rel }) catch break :blk dir_rel;
            break :blk joined;
        };
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

    /// Lazily creates the single DWARF compile unit on first use, anchored to the
    /// given source file. Idempotent: does nothing once `di_cu` exists or when
    /// debug info is off. The producer is labelled `"nova"` and the source
    /// language is recorded as C99 (the closest DWARF language LLVM offers here).
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

    /// Opens a new DWARF subprogram scope for a function about to be emitted and
    /// attaches it to `fn_val`, so line/variable records land in the right place.
    ///
    /// Resets the per-function `dbg_declared` set and the current debug location,
    /// ensures the compile unit exists, and creates a subroutine type + function
    /// metadata. Synthetic files (name empty or starting with `<`) and the null-
    /// builder case return early, leaving `di_scope` null so later debug calls
    /// no-op. Line 0 is normalised to 1 (DWARF has no line 0).
    pub fn beginFunctionDebug(self: *LlvmCompiler, fn_val: types.LLVMValueRef, name: []const u8, file: []const u8, line: usize) void {
        self.di_scope = null;
        self.di_scope_file = null;
        if (self.debug_enabled) self.dbg_declared.clearRetainingCapacity();
        core.LLVMSetCurrentDebugLocation2(self.builder, null);
        if (self.di_builder == null or file.len == 0 or file[0] == '<') return;
        self.ensureDebugCU(file);
        const dif = self.diFileFor(file) orelse return;
        self.di_scope_file = dif;
        var params0 = [_]types.LLVMMetadataRef{null};
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
        self.setDebugLoc(line, 0);
    }

    /// Sets the IR builder's current debug location to `line:col` within the
    /// active subprogram, so subsequent instructions are attributed to that source
    /// position. No-ops when there is no active `di_scope`; line 0 becomes 1.
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

    /// Returns (and caches by name) a DWARF basic-type descriptor for a scalar of
    /// the given bit width and DWARF encoding (e.g. 5 = signed, 7 = unsigned,
    /// 2 = boolean, 4 = float). Cached because the same scalar recurs constantly.
    fn diBasicType(self: *LlvmCompiler, name: []const u8, size_bits: u64, encoding: c_uint) types.LLVMMetadataRef {
        if (self.di_types.get(name)) |t| return t;
        const name_z = self.allocator.dupeZ(u8, name) catch return null;
        defer self.allocator.free(name_z);
        const t = debug.LLVMDIBuilderCreateBasicType(self.di_builder, name_z.ptr, name.len, size_bits, encoding, .LLVMDIFlagZero);
        self.di_types.put(name, t) catch {};
        return t;
    }

    /// Maps a Nova local's type to its best DWARF descriptor, given both the
    /// rendered type name and the LLVM slot type.
    ///
    /// Doubles map to `f64`; for integer slots it dispatches on the name:
    /// `string`/`Str` get their struct descriptors, primitives get a basic type
    /// (word-repr and f32/f64-in-word cases return null so no misleading type is
    /// shown), `List`/`Map`/`Set` get a container descriptor, and a known struct
    /// gets its full member layout. Returns null when nothing sensible applies.
    fn diTypeFor(self: *LlvmCompiler, type_name: ?[]const u8, slot_ty: types.LLVMTypeRef) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        const kind = core.LLVMGetTypeKind(slot_ty);
        if (kind == .LLVMDoubleTypeKind) return self.diBasicType("f64", 64, 4);
        if (kind == .LLVMIntegerTypeKind) {
            const tn = type_name orelse return null;
            if (std.mem.eql(u8, tn, "string")) return self.diStringType();
            if (types_mod.cgPrim(tn)) |p| {
                if (p.repr == .word) return null;
                if (p.repr == .i1) return self.diBasicType("bool", 8, 2);
                if (p.repr == .f32 or p.repr == .f64) return null;
                return self.diBasicType(tn, 64, if (p.signed) 5 else 7);
            }
            const base = getStructBaseName(tn);
            if (std.mem.eql(u8, base, "List") or std.mem.eql(u8, base, "Map") or std.mem.eql(u8, base, "Set"))
                return self.diContainerType(tn);
            if (std.mem.eql(u8, base, "Str")) return self.diStrType();
            if (self.structs.get(base) != null) return self.diStructType(base);
        }
        return null;
    }

    /// Builds a minimal DWARF struct descriptor for a `List`/`Map`/`Set`: a single
    /// `ptr` member pointing at the element storage, enough for a debugger to show
    /// the handle. Cached by the full generic name.
    fn diContainerType(self: *LlvmCompiler, tn: []const u8) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get(tn)) |t| return t;
        const byte_t = self.diBasicType("u8", 8, 7);
        const ptr = debug.LLVMDIBuilderCreatePointerType(self.di_builder, byte_t, 64, 0, 0, "", 0);
        const tn_z = self.allocator.dupeZ(u8, tn) catch return null;
        defer self.allocator.free(tn_z);
        const member = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "ptr", "ptr".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, ptr);
        var members = [_]types.LLVMMetadataRef{member};
        const st = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, tn_z.ptr, tn.len, self.di_file, 0, 64, 0, .LLVMDIFlagZero, null, &members, 1, 0, null, "", 0);
        self.di_types.put(tn, st) catch {};
        return st;
    }

    /// Builds and caches the DWARF descriptor for the built-in `string` type: a
    /// struct with a single `data` pointer member.
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

    /// Like [`LlvmCompiler.diBasicType`] but bypasses the cache, for cases where
    /// the same name is wanted at a different bit width (e.g. a sized struct field
    /// vs. the canonical scalar) and caching by name alone would be wrong.
    fn diBasicTypeUncached(self: *LlvmCompiler, name: []const u8, size_bits: u64, encoding: c_uint) types.LLVMMetadataRef {
        const name_z = self.allocator.dupeZ(u8, name) catch return null;
        defer self.allocator.free(name_z);
        return debug.LLVMDIBuilderCreateBasicType(self.di_builder, name_z.ptr, name.len, size_bits, encoding, .LLVMDIFlagZero);
    }

    /// Builds and caches the DWARF descriptor for the `Str` string handle: a
    /// pointer to an inner `StrData { ptr: long, len: int }` body, mirroring the
    /// runtime's two-field owned-string representation.
    fn diStrType(self: *LlvmCompiler) types.LLVMMetadataRef {
        if (self.di_builder == null) return null;
        if (self.di_types.get("Str")) |t| return t;
        const long_t = self.diBasicType("long", 64, 5);
        const int_t = self.diBasicType("int", 32, 5);
        const m_ptr = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "ptr", "ptr".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, long_t);
        const m_len = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "len", "len".len, self.di_file, 0, 32, 0, 64, .LLVMDIFlagZero, int_t);
        var body_members = [_]types.LLVMMetadataRef{ m_ptr, m_len };
        const body = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, "StrData", "StrData".len, self.di_file, 0, 128, 0, .LLVMDIFlagZero, null, &body_members, 2, 0, null, "", 0);
        const objp = debug.LLVMDIBuilderCreatePointerType(self.di_builder, body, 64, 0, 0, "", 0);
        const m_obj = debug.LLVMDIBuilderCreateMemberType(self.di_builder, self.di_cu, "obj", "obj".len, self.di_file, 0, 64, 0, 0, .LLVMDIFlagZero, objp);
        var members = [_]types.LLVMMetadataRef{m_obj};
        const st = debug.LLVMDIBuilderCreateStructType(self.di_builder, self.di_cu, "Str", "Str".len, self.di_file, 0, 64, 0, .LLVMDIFlagZero, null, &members, 1, 0, null, "", 0);
        self.di_types.put("Str", st) catch {};
        return st;
    }

    /// Picks the DWARF descriptor for a struct field of rendered type `tn` and
    /// byte size `f_size`. Strings and `Str` use their handle descriptors;
    /// primitives use an uncached basic type sized to the field; anything else
    /// (a nested owned reference) falls back to a generic `uptr` pointer word.
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
        return self.diBasicTypeUncached("uptr", 64, 7);
    }

    /// Builds and caches a full DWARF descriptor for a user struct: one member per
    /// field with computed byte offsets (respecting each field's alignment),
    /// wrapped in a pointer + typedef so the debugger sees the struct by its name
    /// through the heap handle. Returns null if the struct is unknown or debug is off.
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
            const fname = self.typeRefToString(field.type_name) catch "";
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
        const ptr = debug.LLVMDIBuilderCreatePointerType(self.di_builder, st, 64, 0, 0, "", 0);
        const td = debug.LLVMDIBuilderCreateTypedef(self.di_builder, ptr, base_z.ptr, base.len, self.di_file, 0, self.di_cu, 0);
        self.di_types.put(base, td) catch {};
        return td;
    }

    /// Emits an `llvm.dbg.declare` associating the stack slot `storage` with a
    /// source variable, so a debugger can name and inspect it.
    ///
    /// Skips silently when there is no active scope/builder, when the name was
    /// already declared in this function, or when no DWARF type can be derived.
    /// Synthesises a debug location if none is currently set.
    pub fn declareLocalVar(self: *LlvmCompiler, storage: types.LLVMValueRef, name: []const u8, type_name: ?[]const u8, slot_ty: types.LLVMTypeRef) void {
        if (self.di_scope == null or self.di_builder == null) return;
        if (self.dbg_declared.contains(name)) return;
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

    /// Finalises DWARF once the module is fully built: strips subprogram metadata
    /// from any function that ended up with no basic blocks (a declaration-only
    /// stub whose dangling subprogram would fail the verifier), then runs the
    /// DIBuilder finalize exactly once. No-op when debug info is off.
    pub fn finalizeDebug(self: *LlvmCompiler, module: types.LLVMModuleRef) void {
        const dib = self.di_builder orelse return;
        var f = core.LLVMGetFirstFunction(module);
        while (f != null) : (f = core.LLVMGetNextFunction(f)) {
            if (core.LLVMCountBasicBlocks(f) == 0 and debug.LLVMGetSubprogram(f) != null) {
                debug.LLVMSetSubprogram(f, null);
            }
        }
        if (!self.di_finalized) {
            debug.LLVMDIBuilderFinalize(dib);
            self.di_finalized = true;
        }
    }

    /// Tears down the compiler: disposes the LLVM builder, module and target
    /// machine and frees every owned table.
    ///
    /// The subtle part is ownership. `param_names` slices are shared across the
    /// several `FunctionInfo`s of one method, so they are freed exactly once via a
    /// pointer-keyed `freed` set. Several maps own their keys (or their keys and
    /// values, or nested maps) and are iterated to free those before `deinit`ing
    /// the map itself; maps that only borrow AST slices are simply `deinit`ed.
    /// The debug tables are only torn down when `debug_enabled`.
    pub fn deinit(self: *LlvmCompiler) void {
        if (self.debug_enabled) {
            self.di_files.deinit();
            self.di_types.deinit();
            self.dbg_declared.deinit();
        }
        core.LLVMDisposeBuilder(self.builder);
        core.LLVMDisposeModule(self.module);
        target_machine.LLVMDisposeTargetMachine(self.target_machine);
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
        self.narrowed_present.deinit();
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

    /// Grafted from `types.zig`: whether a (possibly generic) type name refers to a
    /// known struct.
    pub const isStructType = types_mod.isStructType;
    /// Grafted from `types.zig`: whether a type name is one whose optional form is a
    /// value optional (primitive, unowned enum, or nested value optional).
    pub const valueOptionalName = types_mod.valueOptionalName;

    /// Computes the stable key identifying the closure at `span` under the currently
    /// active instantiation, so a closure expression and the lambda collected for it
    /// agree on one name. Delegates to [`LlvmCompiler.closureKeyM`] with the active
    /// instantiation id resolved via [`LlvmCompiler.closureKeyActiveInstId`].
    pub fn closureKey(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8) ![]const u8 {
        return self.closureKeyM(span, inst, self.closureKeyActiveInstId());
    }

    /// The instantiation id to use for closure keying: the collection-pass cursor
    /// if set, otherwise the emission-pass cursor. The two passes use different
    /// cursors but must produce the same key.
    fn closureKeyActiveInstId(self: *LlvmCompiler) ?sema_types.TypeId {
        return self.current_collecting_instantiation_id orelse self.current_instantiation_id;
    }

    /// Formats the closure key as `uniqueId|instName|instId`, combining the span's
    /// content hash (see [`LlvmCompiler.getClosureUniqueId`]) with the
    /// instantiation name and id so the same closure under two instantiations keys
    /// distinctly. Caller owns the returned string.
    pub fn closureKeyM(self: *LlvmCompiler, span: ast.Span, inst: ?[]const u8, inst_id: ?sema_types.TypeId) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}|{s}|{d}", .{
            getClosureUniqueId(span),
            inst orelse "",
            if (inst_id) |id| @intFromEnum(id) else 0,
        });
    }

    /// Hashes a source span (file + line + column) into a stable id that uniquely
    /// identifies a closure by where it is written, independent of pointer identity
    /// so it survives across the collection and emission passes.
    pub fn getClosureUniqueId(span: ast.Span) usize {
        var h = std.hash.Wyhash.init(0);
        h.update(span.file);
        h.update(std.mem.asBytes(&span.line));
        h.update(std.mem.asBytes(&span.col));
        return h.final();
    }

    /// Extracts the type of the `idx`-th element from a rendered tuple type string
    /// like `(int, string, List<int>)`, returning a freshly allocated slice.
    ///
    /// Splits on top-level commas only, tracking `<>`/`()` nesting depth so a comma
    /// inside a generic argument or a nested tuple does not split. Falls back to
    /// `"i32"` when the input is not a tuple or the index is out of range.
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

    /// Grafted from `arc.zig`: the legacy name-based ownership heuristic for strings.
    pub const legacyStringOwnership = arc_mod.legacyStringOwnership;
    /// Grafted from `arc.zig`: lowers a call argument, applying the correct
    /// retain/borrow/move ARC disposition.
    pub const compileCallArgument = arc_mod.compileCallArgument;
    /// Grafted from `arc.zig`: decides whether acquiring a value should retain,
    /// move, or borrow.
    pub const acquisitionDisposition = arc_mod.acquisitionDisposition;
    /// Grafted from `arc.zig`: takes ownership of an element read out of a container.
    pub const takeOwnedElement = arc_mod.takeOwnedElement;

    /// Returns the interned global for a string literal as an `i64` pointer to its
    /// character data, creating it on first use.
    ///
    /// Each literal is laid out as a packed struct `{ i32 refcount, i32 len, [N] i8
    /// chars }` with an internal-linkage global. The refcount field is initialised
    /// to the sentinel -1000000000 so the runtime treats a string constant as
    /// non-refcounted (never freed). On a cache hit it re-derives the char pointer
    /// from the existing global; on a miss it builds and interns a new one (the key
    /// is a duplicated copy of `str`). Note the cache-miss path allocates one extra
    /// trailing byte for a NUL terminator.
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

        var field_types = [_]types.LLVMTypeRef{ self.i32_type, self.i32_type, core.LLVMArrayType(self.i8_type, @intCast(unescaped.len + 1)) };
        const struct_type = core.LLVMStructType(&field_types, 3, 1);

        const global_var = core.LLVMAddGlobal(self.module, struct_type, "str_literal");
        core.LLVMSetGlobalConstant(global_var, 0);
        core.LLVMSetLinkage(global_var, types.LLVMLinkage.LLVMInternalLinkage);

        const str_z = try self.allocator.dupeZ(u8, unescaped);
        defer self.allocator.free(str_z);
        const ref_const = core.LLVMConstInt(self.i32_type, @as(c_ulonglong, @bitCast(@as(i64, -1000000000))), 0);
        const len_const = core.LLVMConstInt(self.i32_type, @intCast(unescaped.len), 0);
        const chars_const = core.LLVMConstString(str_z.ptr, @intCast(unescaped.len), 0);

        var field_values = [_]types.LLVMValueRef{ ref_const, len_const, chars_const };
        const init_const = core.LLVMConstStruct(&field_values, 3, 1);
        core.LLVMSetInitializer(global_var, init_const);

        const dup_str = try self.allocator.dupe(u8, str);
        try self.string_globals.put(dup_str, global_var);

        const chars_ptr = core.LLVMBuildStructGEP2(self.builder, struct_type, global_var, 2, "chars_ptr");
        return core.LLVMBuildPtrToInt(self.builder, chars_ptr, self.val_type, "str_ptr_int");
    }

    /// Returns a decimal128 value parsed from `digits`, parsed at most once at
    /// runtime and memoised in a per-literal cache global.
    ///
    /// Because decimal parsing is not a compile-time constant here, this emits a
    /// lazy-init pattern: load the cache global, and if it is still zero, branch to
    /// an init block that calls `nova_decimal_from_string`, stamps the parsed
    /// object's header refcount to the -1000000000 sentinel (so it is treated as a
    /// non-freed constant) and stores it back, then a phi merges the cached and
    /// freshly-parsed values. The cache global's key slice is owned.
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

        core.LLVMPositionBuilderAtEnd(self.builder, init_bb);
        const dz = try self.allocator.dupeZ(u8, digits);
        defer self.allocator.free(dz);
        const str_global = core.LLVMBuildGlobalString(self.builder, dz.ptr, "dec_lit");
        const str_ptr = core.LLVMBuildBitCast(self.builder, str_global, self.ptr_type, "dec_lit_ptr");
        var args = [_]types.LLVMValueRef{str_ptr};
        const parsed = core.LLVMBuildCall2(self.builder, from_t, from_fn, &args, 1, "dec_parse_once");
        const hdr_addr = core.LLVMBuildSub(self.builder, parsed, core.LLVMConstInt(self.val_type, 8, 0), "dec_hdr_addr");
        const hdr_ptr = core.LLVMBuildIntToPtr(self.builder, hdr_addr, self.ptr_type, "dec_hdr_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i32_type, @as(c_ulonglong, @bitCast(@as(i64, -1000000000))), 0), hdr_ptr);
        _ = core.LLVMBuildStore(self.builder, parsed, cache_g);
        _ = core.LLVMBuildBr(self.builder, cont_bb);
        const init_end_bb = core.LLVMGetInsertBlock(self.builder);

        core.LLVMPositionBuilderAtEnd(self.builder, cont_bb);
        const phi = core.LLVMBuildPhi(self.builder, self.val_type, "dec_val");
        var inc_vals = [_]types.LLVMValueRef{ cached, parsed };
        var inc_bbs = [_]types.LLVMBasicBlockRef{ entry_bb, init_end_bb };
        core.LLVMAddIncoming(phi, &inc_vals, &inc_bbs, 2);
        return phi;
    }

    /// Grafted from `arc.zig`: emits a `nova_retain` on a heap value (increments refcount).
    pub const compileRetain = arc_mod.compileRetain;
    /// Grafted from `arc.zig`: splits an error-union value into its ok/err parts.
    pub const errUnionParts = arc_mod.errUnionParts;
    /// Grafted from `arc.zig`: constructs an error-union value from a payload/error.
    pub const buildErrUnion = arc_mod.buildErrUnion;
    /// Grafted from `arc.zig`: emits a `nova_release` with the appropriate destructor.
    pub const compileRelease = arc_mod.compileRelease;
    /// Grafted from `arc.zig`: elides a retain/release pair that is provably a borrow.
    pub const elideBorrowedArc = arc_mod.elideBorrowedArc;
    /// Grafted from `arc.zig`: the OSSA self-verifier that checks retain/release balance.
    pub const verifyArcBalance = arc_mod.verifyArcBalance;
    /// Grafted from `arc.zig`: snapshots the ARC census before a region, for balance checking.
    pub const arcCensusBefore = arc_mod.arcCensusBefore;
    /// Grafted from `arc.zig`: snapshots the ARC census after a region and diffs it.
    pub const arcCensusAfter = arc_mod.arcCensusAfter;
    /// Grafted from `arc.zig`: gets or emits the destructor for a struct by name.
    pub const getOrCreateDestructor = arc_mod.getOrCreateDestructor;
    /// Grafted from `arc.zig`: gets or emits a trait object's destructor.
    pub const getOrCreateTraitDestructor = arc_mod.getOrCreateTraitDestructor;
    /// Grafted from `arc.zig`: gets or emits a destructor keyed by `TypeId`.
    pub const getOrCreateDestructorByTypeId = arc_mod.getOrCreateDestructorByTypeId;
    /// Grafted from `arc.zig`: gets or emits a destructor, preferring the `TypeId`
    /// over the name when both are available.
    pub const getOrCreateDestructorPreferId = arc_mod.getOrCreateDestructorPreferId;
    /// Grafted from `arc.zig`: releases all owned locals of the current scope.
    pub const releaseLocalVariables = arc_mod.releaseLocalVariables;
    /// Grafted from `arc.zig`: emits a deep copy of a tuple value (per-element retain/copy).
    pub const buildTupleDeepCopy = arc_mod.buildTupleDeepCopy;
    /// Grafted from `arc.zig`: releases a single named local.
    pub const releaseLocalByName = arc_mod.releaseLocalByName;
    /// Grafted from `arc.zig`: drops a value struct, releasing its owned fields.
    pub const dropValueStruct = arc_mod.dropValueStruct;
    /// Grafted from `arc.zig`: substitutes type parameters within a field type under
    /// the current instantiation.
    pub const substituteFieldType = arc_mod.substituteFieldType;
    /// Grafted from `arc.zig`: substitutes type parameters in a type name string.
    pub const substTypeParams = arc_mod.substTypeParams;
    /// Grafted from `types.zig`: substitutes type parameters across a method's params.
    pub const substMethodParams = types_mod.substMethodParams;
    /// Grafted from `types.zig`: builds the mangled symbol name of a method on a
    /// given (possibly instantiated) owner.
    pub const methodSymbol = types_mod.methodSymbol;
    /// Grafted from `types.zig`: enumerates the concrete instantiations of a struct
    /// (returns a slice including null for the erased base).
    pub const instantiationsOf = types_mod.instantiationsOf;
    /// Grafted from `types.zig`: rewrites `Self`/type-param references to the
    /// concrete owner under the current instantiation.
    pub const qualifySelfType = types_mod.qualifySelfType;

    /// Emits a heap allocation of `size` bytes via the `nova_bytes_alloc` runtime
    /// function, declaring that extern lazily on first use. Returns the client
    /// pointer as an `i64` word.
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

    /// Emits an array allocation of `size` bytes via `nova_array_alloc`, declaring
    /// the extern lazily. Unlike [`LlvmCompiler.compileAlloc`] this returns a real
    /// pointer (`ptr_type`), used where a typed array base is needed.
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

    /// Emits an allocation from the persistent arena via
    /// `nova_bytes_alloc_persistent`, for objects (like interned constants) that
    /// must outlive the normal request/arena lifetime and are never freed.
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

    /// If `tid` is a value optional, returns the `TypeId` it wraps; otherwise null.
    ///
    /// A value optional is one whose payload does not carry its own null bit, so it
    /// must be boxed to distinguish "present zero" from "absent": primitives always
    /// qualify, an enum qualifies only if it is NOT an owned/tagged-union type, and
    /// a nested optional qualifies only if it too is a value optional (recursively).
    /// This is the core predicate behind the whole valopt ABI; see
    /// [`LlvmCompiler.valoptDepth`].
    pub fn valueOptionalInner(self: *LlvmCompiler, tid: sema_types.TypeId) ?sema_types.TypeId {
        const st = self.type_store orelse return null;
        const info = st.get(tid);
        if (info != .optional) return null;
        return switch (st.get(info.optional)) {
            .prim => info.optional,

            .enum_ => if (st.isOwned(info.optional)) null else info.optional,
            .optional => if (self.valueOptionalInner(info.optional) != null) info.optional else null,
            else => null,
        };
    }

    /// Counts how many value-optional layers wrap `tid`, i.e. how many box levels a
    /// value of this type carries (0 for a non-valopt, 2 for `int??`). Used to match
    /// an argument's box depth to the parameter's expected depth at a call site.
    pub fn valoptDepth(self: *LlvmCompiler, tid: sema_types.TypeId) usize {
        var d: usize = 0;
        var cur = tid;
        while (self.valueOptionalInner(cur)) |inner| {
            d += 1;
            cur = inner;
        }
        return d;
    }

    /// Boxes a bare value into a value-optional via `nova_valopt_box`, so a present
    /// value (including a present zero) is distinguishable from absence. Declares
    /// the extern lazily.
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

    /// Unboxes one value-optional layer via `nova_valopt_unbox`, recovering the
    /// underlying value word. The inverse of [`LlvmCompiler.buildValoptBox`].
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

    /// Boxes a value into an `any` via `nova_any_box`, pairing the payload word with
    /// a destructor function pointer (zero for a non-owning payload) so the boxed
    /// value can be released correctly later. Declares the extern lazily.
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

    /// Recovers the payload word from an `any` box via `nova_any_unbox`. The inverse
    /// of [`LlvmCompiler.buildAnyBox`].
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

    /// Coerces a concrete value into an `any` box, capturing the right destructor
    /// and doing the right ARC bookkeeping for the source's ownership category.
    ///
    /// Already-`any` values pass through. A value struct is copied onto the heap
    /// (its owned fields deep-retained) and boxed with the struct's destructor. A
    /// heap-owned reference is boxed with its destructor and either retained (when
    /// the source expression is a borrow: an ident/field/index) or has its
    /// temporary consumed (when it is a freshly produced value), preserving the
    /// refcount invariant. The resulting box is registered as a temporary so it is
    /// released at statement end.
    pub fn coerceToAny(self: *LlvmCompiler, val: types.LLVMValueRef, src_expr: *const ast.Expression) anyerror!types.LLVMValueRef {
        const payload = self.coerceToSlotType(val, self.val_type);
        const src_name = (try self.resolveExpressionTypeName(src_expr)) orelse "";
        if (std.mem.eql(u8, src_name, "any")) return payload;
        // FAIL-CLOSED (harden #3): boxing a trait object into `any` is unsound today. The
        // value reaching here is a fat pointer {struct_ptr, vtable} (or, on some call paths,
        // a not-yet-widened concrete pointer typed as the trait), but the `any` box pairs it
        // with the trait destructor and later reads it as the wrong shape -> UAF / SIGSEGV at
        // container teardown, or a silent wrong value on `as Concrete`. The proper fix
        // (fat-pointer-aware `any` box + centralised concrete->trait arg widening) is a deep,
        // cross-cutting codegen change; until then reject it with a clear diagnostic and a
        // workaround rather than emit crashing IR. Homogeneous trait containers (List<Trait>,
        // dispatched by trait method) are the sound seam and are unaffected.
        if (self.traits.contains(getStructBaseName(src_name))) {
            const sp = src_expr.span;
            std.debug.print(
                "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m cannot store a trait value (`{s}`) into `any`\x1b[0m\n" ++
                "  Boxing a trait object into `any` is not sound in Nova today: the erased box loses the\n" ++
                "  fat-pointer shape and its destructor corrupts memory when the container is torn down.\n" ++
                "  Use a homogeneous trait container instead, e.g. `List<{s}>` dispatched by trait method,\n" ++
                "  or downcast to the concrete type before boxing (`let c: ConcreteType = value;`).\n",
                .{ sp.file, sp.line, sp.col, src_name, src_name },
            );
            std.debug.print("(compilation failed)\n", .{});
            std.process.exit(70);
        }
        var dtor = core.LLVMConstInt(self.val_type, 0, 0);
        const src_tid = self.typeOfExprConcrete(src_expr);
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
        try self.registerTemporary(box, "any");
        return box;
    }

    /// Whether an AST type reference denotes a value optional (the syntactic
    /// counterpart of [`LlvmCompiler.valueOptionalInner`], used where only the
    /// `TypeRef` is available, e.g. a parameter's declared type).
    ///
    /// Resolves the optional's inner type (preferring a concrete `TypeId` render
    /// when possible), then applies the value-optional rules: not `ptr`, primitive
    /// -> true, nested value-optional name -> true, an enum that is not a tagged
    /// union -> true, otherwise false.
    pub fn valoptTypeRefIsValue(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        const inner = blk: {
            if (self.concreteTidForTypeRef(tr.optional.*)) |itid| {
                break :blk self.symbolName(itid) catch (self.typeRefToString(tr.optional.*) catch return false);
            }
            break :blk self.typeRefToString(tr.optional.*) catch return false;
        };
        if (std.mem.eql(u8, inner, "ptr")) return false;
        if (types_mod.cgPrim(inner) != null) return true;
        if (valueOptionalName(inner)) return true;

        const base = getStructBaseName(inner);
        if (self.enums.contains(base) and !arc_mod.enumIsTaggedUnion(self, base)) return true;
        return false;
    }

    /// Whether an AST optional type is doubly-nested (its inner type is itself a
    /// value-optional name, e.g. `int??`), so a call site knows the parameter
    /// expects box depth 2 rather than 1.
    pub fn valoptTypeRefIsNested(self: *LlvmCompiler, tr: ast.TypeRef) bool {
        if (tr != .optional) return false;
        const inner = self.typeRefToString(tr.optional.*) catch return false;
        return valueOptionalName(inner);
    }

    /// Whether an argument expression is a plain local whose type is a value
    /// optional, i.e. it already holds a box. Lets the caller avoid re-boxing an
    /// argument that is already in boxed form.
    pub fn argIsValoptLocal(self: *LlvmCompiler, arg: *const ast.Expression) bool {
        if (arg.kind != .ident) return false;
        const ids = self.current_local_type_ids orelse return false;
        const slot_tid = ids.get(arg.kind.ident) orelse return false;
        return self.valueOptionalInner(slot_tid) != null;
    }

    /// Whether the `param_idx`-th parameter of `method_name` on the receiver's
    /// concrete type resolves (through the receiver's generic arguments) to a value
    /// optional.
    ///
    /// This handles the case where a method parameter is written in terms of a type
    /// parameter (`fn set(v: T)`) and the receiver instantiates `T` with a value-
    /// optional type: it finds the matching type parameter position in the struct's
    /// type-arg list and checks that argument. Accounts for the implicit `self`
    /// when computing the real parameter index.
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

    /// Whether an expression already evaluates to a value-optional box (as opposed
    /// to a bare value that would need boxing).
    ///
    /// Only certain expression shapes carry the box through: reads
    /// (ident/field/index), calls, optional chaining, await/catch/try, and nullish
    /// coalescing. Anything else that has a valopt type would produce a bare value,
    /// so the caller must box it. Returns false for non-valopt types.
    pub fn exprYieldsValoptBox(self: *LlvmCompiler, e: *const ast.Expression) bool {
        const tid = self.typeOfExprConcrete(e) orelse return false;
        if (self.valueOptionalInner(tid) == null) return false;
        return switch (e.kind) {
            .ident, .field_access, .call, .generic_call, .index, .optional_chaining, .await_expr, .catch_expr, .try_expr => true,
            .nullish_coalesce => true,
            else => false,
        };
    }

    /// Whether an expression is the `undefined` or `null` literal, i.e. an explicit
    /// absent value that must NOT be boxed as a present value at a valopt call site.
    pub fn isUndefinedLiteralExpr(e: *const ast.Expression) bool {
        return e.kind == .literal and (e.kind.literal == .undefined or e.kind.literal == .null);
    }

    /// The size in bytes of a pointer/word element on the target: 4 on WASM (a
    /// 32-bit target), 8 elsewhere. Used to stride through vtables and pointer arrays.
    pub fn ptrElemSize(self: *LlvmCompiler) u64 {
        return if (self.is_wasm) 4 else 8;
    }

    /// The size in bytes of one value slot in a captured-environment layout. Fixed
    /// at 8 (values are stored as full words even on WASM), independent of `self`.
    pub fn valSlotSize(self: *LlvmCompiler) usize {
        _ = self;

        return 8;
    }

    /// Returns the index of `name` within the current lambda's capture list, or
    /// null if it is not a capture. Only meaningful inside a `__lambda_*` function;
    /// used to load a captured variable from the `__env` block.
    pub fn envCaptureIndex(self: *LlvmCompiler, name: []const u8) ?usize {
        const fn_name = self.current_function_name orelse return null;
        if (!std.mem.startsWith(u8, fn_name, "__lambda_")) return null;
        const caps = self.lambda_captures.get(fn_name) orelse return null;
        for (caps.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, name)) return i;
        }
        return null;
    }

    /// Computes the address of the `index`-th capture slot inside the current
    /// lambda's `__env` block (env base pointer + index * slot size). Errors if the
    /// `__env` local is not in scope.
    pub fn envSlotAddr(self: *LlvmCompiler, index: usize) anyerror!types.LLVMValueRef {
        const env_slot = self.locals.get("__env") orelse return error.EnvNotFound;
        const env_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, env_slot, "env_ptr");
        const off = core.LLVMConstInt(self.val_type, index * self.valSlotSize(), 0);
        return core.LLVMBuildAdd(self.builder, env_ptr, off, "env_slot_addr");
    }

    /// Emits a `nova_bytes_free` on a heap pointer (declaring the extern lazily) and
    /// returns a zero word, so it can be used where an expression value is expected.
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

    /// Emits the whole memory-management runtime directly as LLVM IR, for targets
    /// (chiefly WASM) that cannot link the C++ runtime.
    ///
    /// It defines, in IR: `nova_bytes_free` (a free-list push that no-ops for null,
    /// arena-region and, on WASM, all pointers), a bump-pointer `nova_bytes_alloc`
    /// (writing a 4-byte size header, 8-byte aligning, seeding the heap from
    /// `__heap_base` on WASM), a first-fit persistent `nova_bytes_alloc_persistent`
    /// that reuses the free list before bumping the persistent arena, and no-op
    /// `nova_retain`/`nova_release` stubs (WASM programs run to completion without
    /// reclamation). Each function is built with its own temporary IR builder.
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

    /// If a free function is really a struct method (its first parameter is `self`
    /// of a known struct, or it is a `new` returning a known struct), returns that
    /// struct's module-scoped name so the function can be mangled under it;
    /// otherwise null.
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

    /// Whether a function name already carries one of the well-known stdlib module
    /// prefixes (e.g. `net_http_request_`, `collections_list_`), so codegen does not
    /// prepend a second module prefix and produce a doubly-namespaced symbol. The
    /// prefix must be followed by `_` to count, avoiding false matches like `list`
    /// inside `listener`.
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

    /// Whether a struct with base name `base` is stored inline in its container/field
    /// (i.e. it is a value struct) rather than behind a heap pointer. The layout
    /// decision that drives [`LlvmCompiler.getTypeSize`] and field offsets.
    pub fn fieldStoredInline(self: *LlvmCompiler, base: []const u8) bool {
        return self.isValueStructName(base);
    }

    /// Computes the byte alignment of a type. Primitives use their natural
    /// alignment; a value struct takes the maximum alignment of its fields
    /// (computed recursively); everything else is pointer-aligned (8).
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

    /// Computes the byte size of a type, in one of two modes selected by `is_field`.
    ///
    /// When `is_field` is true the size is the storage occupied as a struct field
    /// or container element: a heap-stored struct/union/generic occupies one 8-byte
    /// pointer, whereas a value struct is measured by its full inline payload.
    /// When `is_field` is false the size is the full object size (used to size an
    /// allocation). Primitives return their scalar width; unions return the size of
    /// their largest variant; unknown types default to a word (8).
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

    /// Lays out a struct's fields (each field padded up to its alignment) and
    /// returns the total size rounded up to the struct's own alignment, i.e. the C
    /// struct-packing computation. The layout must match [`LlvmCompiler.getFieldOffset`].
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

    /// Grafted from `types.zig`: maps a Nova type name to its LLVM type.
    pub const toLLVMType = types_mod.toLLVMType;
    /// Grafted from `types.zig`: maps a primitive repr kind to its LLVM type.
    pub const llvmForRepr = types_mod.llvmForRepr;
    /// Grafted from `types.zig`: the `<4 x double>` SIMD vector LLVM type.
    pub const vecF64x4Type = types_mod.vecF64x4Type;
    /// Grafted from `types.zig`: bit-casts/extends a typed value up to the `i64` word.
    pub const castToValType = types_mod.castToValType;
    /// Grafted from `types.zig`: narrows/bit-casts an `i64` word back to a concrete type.
    pub const castFromValType = types_mod.castFromValType;
    /// Grafted from `types.zig`: the LLVM slot type to allocate for a local by name.
    pub const slotTypeForLocal = types_mod.slotTypeForLocal;
    /// Grafted from `types.zig`: the slot type for a local by `TypeId`.
    pub const slotTypeForLocalId = types_mod.slotTypeForLocalId;
    /// Grafted from `types.zig`: coerces a value into a given slot type for store/load.
    pub const coerceToSlotType = types_mod.coerceToSlotType;

    /// Computes the byte offset of a named field within a struct, applying the same
    /// alignment-padding layout as [`LlvmCompiler.structPayloadSize`].
    ///
    /// A union always reports offset 0 (its variants overlap). Errors with
    /// `StructTypeNotFound` or `FieldNotFound` if the struct or field is unknown.
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

    /// Emits a call to `fn_val`, coercing each argument to the callee's declared
    /// parameter type and coercing the result back to the `i64` value word.
    ///
    /// Because most values are carried as `i64` while runtime/FFI functions have
    /// precise signatures, each argument is bridged as needed: int<->pointer,
    /// int<->double bit-casts, and integer trunc/zext to the exact width. A void
    /// return yields a zero word so the call is usable as an expression. A fixed-
    /// arity mismatch is a COMPILER bug (sema should have caught it): it prints a
    /// diagnostic and exits with code 70 rather than emitting broken IR.
    pub fn buildCallWithCasts(self: *LlvmCompiler, fn_val: types.LLVMValueRef, args: []const types.LLVMValueRef) anyerror!types.LLVMValueRef {
        const fn_t = core.LLVMGlobalGetValueType(fn_val);
        const param_count = core.LLVMCountParamTypes(fn_t);
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

    /// Returns the rendered type-name of a function's `param_idx`-th parameter,
    /// memoised in `param_type_str_cache` keyed by `name\0index`.
    ///
    /// The cache stores an owned duplicate of the result (or null), so lookups are
    /// cheap on the hot call-lowering path. Delegates the real work to
    /// [`LlvmCompiler.getFunctionParamTypeUncached`].
    pub fn getFunctionParamType(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?[]const u8 {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ func_name, param_idx }) catch return self.getFunctionParamTypeUncached(func_name, param_idx);
        if (self.param_type_str_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        const result = self.getFunctionParamTypeUncached(func_name, param_idx);
        const stored: ?[]const u8 = if (result) |r| (self.allocator.dupe(u8, r) catch null) else null;
        self.param_type_str_cache.put(key, stored) catch {
            if (stored) |s| self.allocator.free(s);
            self.allocator.free(key);
            return stored;
        };
        return stored;
    }

    /// The uncached body of [`LlvmCompiler.getFunctionParamType`]: scans program
    /// declarations to find `func_name` and render its parameter type.
    ///
    /// Matches both free functions (accounting for module-prefix mangling) and
    /// struct methods across every instantiation (parameter index 0 is the receiver
    /// `self`, whose type is the struct; `init`/`new` shift the index by one). For a
    /// method it renders the type under that method's owning instantiation so type
    /// parameters resolve concretely.
    fn getFunctionParamTypeUncached(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?[]const u8 {
        for (self.program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| {
                    var name = f.name;
                    var name_owned = false;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        defer self.allocator.free(mod_prefix);
                        if (!LlvmCompiler.isAlreadyNamespaced(f.name)) {
                            name = std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_prefix, f.name }) catch return null;
                            name_owned = true;
                        }
                    }
                    defer if (name_owned) self.allocator.free(name);
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
                    const insts = self.instantiationsOf(s) catch continue;
                    defer self.allocator.free(insts);
                    for (s.methods) |m| {
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            defer self.allocator.free(full_name);
                            if (!std.mem.eql(u8, full_name, func_name)) continue;
                            if (param_idx == 0) return s.name;
                            const is_constructor = std.mem.eql(u8, m.decl.name, "init") or std.mem.eql(u8, m.decl.name, "new");
                            const actual_idx = if (is_constructor) param_idx - 1 else param_idx;
                            if (actual_idx < m.decl.params.len) {
                                if (m.decl.params[actual_idx].type_name) |t| {
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

    /// Like [`LlvmCompiler.getFunctionParamType`] but returns the raw AST
    /// `TypeRef` (unrendered), memoised in `param_type_cache`. Preferred where the
    /// structured type is needed, e.g. valopt coercion decisions.
    pub fn getFunctionParamTypeRef(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?ast.TypeRef {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ func_name, param_idx }) catch return self.getFunctionParamTypeRefUncached(func_name, param_idx);
        if (self.param_type_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        const result = self.getFunctionParamTypeRefUncached(func_name, param_idx);
        self.param_type_cache.put(key, result) catch self.allocator.free(key);
        return result;
    }

    /// The uncached body of [`LlvmCompiler.getFunctionParamTypeRef`]: the same
    /// declaration scan as [`LlvmCompiler.getFunctionParamTypeUncached`] but
    /// returning the parameter's raw `TypeRef` instead of a rendered string.
    fn getFunctionParamTypeRefUncached(self: *LlvmCompiler, func_name: []const u8, param_idx: usize) ?ast.TypeRef {
        for (self.program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |f| {
                    var name = f.name;
                    var name_owned = false;
                    if (self.getModulePrefix(f.span)) |mod_prefix| {
                        defer self.allocator.free(mod_prefix);
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
                    const insts = self.instantiationsOf(s) catch continue;
                    defer self.allocator.free(insts);
                    for (s.methods) |m| {
                        for (insts) |inst_opt| {
                            const owner = inst_opt orelse s.name;
                            const full_name = self.methodSymbol(owner, m.decl.name) catch continue;
                            defer self.allocator.free(full_name);
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

    /// Bridges an argument value to what a parameter expects for value-optional and
    /// `any` parameters, boxing, unboxing or widening as needed.
    ///
    /// For an `any` parameter, a non-`any` argument is coerced to a box. For a
    /// value-optional parameter: if the argument already yields a box that is more
    /// deeply nested than the parameter wants, it is unboxed the difference in depth;
    /// if the argument is a bare (non-box, non-`undefined`) value, it is boxed once.
    /// Otherwise the value passes through unchanged.
    pub fn coerceValoptArg(self: *LlvmCompiler, val: types.LLVMValueRef, arg: *const ast.Expression, param_tr_opt: ?ast.TypeRef, param_str_opt: ?[]const u8) anyerror!types.LLVMValueRef {
        if (param_str_opt) |param_str| {
            if (std.mem.eql(u8, param_str, "any")) {
                if (!self.isAnyExpr(arg)) return try self.coerceToAny(val, arg);
                return val;
            }
        }
        const param_tr = param_tr_opt orelse return val;
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

    /// Finds the emitted specialisation for a namespaced generic call
    /// `obj.field<type_args...>`, matching by the mangled `obj_field__T1__T2` symbol.
    ///
    /// Tries the exact mangled name first, then falls back to any function whose
    /// name ends with `_<mangled>` (to catch a module-prefixed emission of the same
    /// specialisation). Returns null when no matching function exists.
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

    /// Whether every method the trait declares has been emitted concretely for
    /// `struct_name` (all its mangled symbols exist in `func_map`).
    ///
    /// Used by [`LlvmCompiler.constructTraitObject`] to decide whether to build the
    /// vtable against the fully-scoped struct name or fall back to the base name.
    pub fn hasConcreteTraitMethods(self: *LlvmCompiler, struct_name: []const u8, trait_name: []const u8) !bool {
        const trait_decl = self.traits.get(getStructBaseName(trait_name)) orelse return false;
        for (trait_decl.methods) |tm| {
            const mn = try self.methodSymbol(struct_name, tm.name);
            defer self.allocator.free(mn);
            if (!self.func_map.contains(mn)) return false;
        }
        return true;
    }

    /// Returns (creating on first use) the constant global vtable for a
    /// `struct implements trait` pair.
    ///
    /// The layout is `[N+1 x ptr]`: slot 0 is the struct's destructor and slots
    /// 1..N are the trait methods in declaration order, resolved by mangled name
    /// (with a lowercased-struct fallback), leaving a null slot where a method is
    /// missing. The symbol name encodes the mangled struct, the trait and, for a
    /// generic trait impl, the mangled trait type arguments, so distinct impls get
    /// distinct vtables. Errors with `TraitNotFound` if the trait is unknown.
    pub fn getGlobalVTable(self: *LlvmCompiler, struct_name: []const u8, trait_name: []const u8) !types.LLVMValueRef {
        const mangled = try types_mod.mangleTypeName(self.allocator, struct_name);
        defer self.allocator.free(mangled);

        const trait_base = getStructBaseName(trait_name);
        var mono_suffix = std.ArrayList(u8).empty;
        defer mono_suffix.deinit(self.allocator);
        if (self.structs.get(getStructBaseName(struct_name))) |sdecl| {
            for (sdecl.impls) |impl| {
                if (std.mem.eql(u8, getStructBaseName(impl.name), trait_base) and impl.type_args.len > 0) {
                    for (impl.type_args) |ta| {
                        const ta_str: []const u8 = switch (ta) {
                            .ident => |n| n,
                            .generic => |g| g.name,
                            else => "x",
                        };
                        const ta_mangled = try types_mod.mangleTypeName(self.allocator, ta_str);
                        defer self.allocator.free(ta_mangled);
                        try mono_suffix.append(self.allocator, '_');
                        try mono_suffix.appendSlice(self.allocator, ta_mangled);
                    }
                    break;
                }
            }
        }

        const base_name = try std.fmt.allocPrint(self.allocator, "_vtable_{s}_{s}{s}", .{ mangled, trait_name, mono_suffix.items });
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

    /// Builds a trait object (fat pointer) wrapping a concrete struct value.
    ///
    /// Allocates a two-word heap block, stores the retained struct pointer in word
    /// 0 and the address of the appropriate global vtable in word 1, then registers
    /// the block as a temporary for release at statement end. The struct pointer is
    /// retained because the trait object now holds a reference to it. The vtable is
    /// chosen from the fully-scoped struct name when all its trait methods are
    /// concrete, else from the base name (see [`LlvmCompiler.hasConcreteTraitMethods`]).
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

        const vtable_global = if (try self.hasConcreteTraitMethods(struct_name, trait_name))
            try self.getGlobalVTable(struct_name, trait_name)
        else
            try self.getGlobalVTable(getStructBaseName(struct_name), trait_name);
        const vtable_int = core.LLVMBuildPtrToInt(self.builder, vtable_global, self.val_type, "vtable_int");
        _ = core.LLVMBuildStore(self.builder, vtable_int, ptr1);

        try self.registerTemporary(trait_obj, trait_name);

        return trait_obj;
    }

    /// Declares (and caches) the runtime extern for an atomic operation with the
    /// correct signature for the atomic's element type and the specific method.
    ///
    /// Return type and parameter list depend on the method: `compareAndSwap`
    /// returns an `i32` success flag and takes expected+desired, `store` returns
    /// void and takes one value, `add`/`sub` return and take the element type, and
    /// `load` returns the element type. The element type maps 64-bit ints/doubles
    /// to `i64`, bool to `i1`, everything else to `i32`. The `func_map` key is owned.
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

    /// Lowers a method call on an `Atomic<T>` to the matching `nova_atomic_*`
    /// runtime call.
    ///
    /// Parses the element type `T` out of the `Atomic<T>` name, loads the atomic
    /// cell's inner pointer, selects the `nova_atomic_{add,sub,load,store,cas}_{i32,
    /// i64,bool}` function by method and width, and coerces each argument to the
    /// element's LLVM type. `store` produces no value; `compareAndSwap`'s `i32`
    /// result is truncated to `i1` (a Nova bool). Errors on an unknown method.
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

    /// Lowers a method call with explicit type arguments (`obj.method<T>(...)`) by
    /// resolving to the emitted specialisation for those arguments.
    ///
    /// Finds the generic method on the receiver's struct, builds the mangled
    /// specialisation name (`Owner_method__T1__T2`), and looks it up in `func_map`.
    /// Arguments are lowered with ARC-correct handling and, where a parameter type
    /// is a trait, widened into a trait object. Returns null (a signal to fall back
    /// to another lowering path) when the method is not generic or the
    /// specialisation was not emitted.
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

    /// Resolves a parameter's declared type against the receiver's concrete generic
    /// arguments, so a type-parameter parameter (`T`) becomes the concrete type
    /// before the caller decides whether to widen the argument into a trait object.
    /// Returns `expected_type` unchanged when the receiver is not generic.
    fn resolveParamTypeForWiden(self: *LlvmCompiler, obj_type_opt: ?[]const u8, expected_type: []const u8) []const u8 {
        const ot = obj_type_opt orelse return expected_type;
        if (std.mem.indexOfScalar(u8, ot, '<') == null) return expected_type;
        return self.substituteFieldType(ot, expected_type) catch expected_type;
    }

    /// Emits an indirect (dynamic-dispatch) call through a trait object's vtable.
    ///
    /// Loads the fat pointer's two words (struct pointer at offset 0, vtable pointer
    /// at offset 8), loads the function pointer from vtable slot `m_idx + 1` (slot 0
    /// being the destructor), and calls it with the struct pointer as the implicit
    /// receiver followed by the lowered arguments. All parameters and the result are
    /// modelled as the `i64` value word.
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

    /// The central dispatcher for any `object.field(args)` call: figures out what
    /// the callee actually is and lowers it accordingly.
    ///
    /// It resolves, in order: atomics (`Atomic<T>` methods), enum-variant
    /// construction (`Color.Red(...)` builds a tagged union), trait method calls
    /// (dynamic dispatch), concrete struct/enum methods and static functions
    /// (trying mono, erased, and lowercased name forms, and preferring the single
    /// unambiguous monomorphized specialisation when one exists), free functions
    /// reached through a module/namespace receiver (with capitalised and
    /// suffix-match fallbacks), constructor calls (`Struct(...)` allocates then runs
    /// `init`/`new`), and finally a struct field holding a closure. Arguments get
    /// ARC-correct handling, trait/`any` widening, valopt boxing, and payload
    /// retain/consume as appropriate; async callees are driven as coroutines. Emits
    /// a source-located "no method or function" error and returns
    /// `MethodOrFunctionNotFound` if nothing resolves.
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

            if (sema_shadow.live_sema) |sm| {
                if (sm.tab.findModuleByImportNameForImporter(fa.object.kind.ident, fa.span.file)) |mid| {
                    if (sm.tab.findFunctionIn(mid, fa.field)) |sid| {
                        const legacy = sm.tab.symbolAt(sid).legacy_mangled;
                        if (self.func_map.contains(legacy)) resolved_name = legacy;
                    }
                }
            }

            if (resolved_name != null) {
            } else if (self.func_map.get(full_name)) |_| {
                resolved_name = full_name;
            } else if (self.func_map.get(cap_full_name)) |_| {
                resolved_name = cap_full_name;
            } else {
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
                            if (!self.isAnyExpr(arg)) {
                                val = try self.coerceToAny(val, arg);
                                widened_any = true;
                            }
                        }
                    }
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
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m no method or function '{s}' on '{s}'\x1b[0m, check the name and that it is `pub`.\n",
                .{ fa.span.file, fa.span.line, fa.span.col, fa.field, recv },
            );
        }
        return error.MethodOrFunctionNotFound;
    }

    /// Heuristically decides whether a call expression returns void, so the caller
    /// knows a void-lambda body needs no return value.
    ///
    /// Recognises known void-returning builtins by receiver/name (`console.log`,
    /// `router.register`, `bytes.write*`, container mutators like `push`/`set`/
    /// `add`/`insert`/`forEach`), then falls back to looking the resolved function
    /// name up in the `functions` worklist and checking its `return_type`.
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

    /// Entry point of the closure-collection pre-pass over a block: walks each
    /// statement to find and register every closure literal before emission begins.
    /// See [`LlvmCompiler.collectClosuresFromExpr`] for what registration does.
    pub fn collectClosuresFromBlock(self: *LlvmCompiler, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectClosuresFromStatement(stmt);
        }
    }

    /// Recurses through a statement's sub-expressions and nested blocks looking for
    /// closures, as part of the closure-collection pre-pass.
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

    /// Whether a statement subtree contains any `return`, used to tell a
    /// value-returning closure body from a void one. Recurses through blocks and
    /// control-flow arms but not into nested function/closure bodies.
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

    /// The heart of the closure-collection pre-pass: when it finds a closure
    /// literal it synthesises and registers a top-level `__lambda_N` function for it.
    ///
    /// It normalises the body into a block (wrapping an expression body in either a
    /// `return` or an expression statement depending on whether the lambda is void),
    /// infers the return type (defaulting to `i32`, upgrading to a trait return type
    /// from the typed IR), prepends the implicit `__env` parameter, records declared
    /// param types, appends a [`FunctionInfo`], maps the closure key to the lambda
    /// name, and runs capture analysis ([`LlvmCompiler.scanStatementCaptures`] /
    /// [`LlvmCompiler.scanExprCaptures`]) to compute its captured-variable list. It
    /// also recurses into all other expression shapes so nested closures are found.
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

    /// Walks a lambda body statement to discover which enclosing-scope variables it
    /// captures, threading the set of lambda-local names (params + `let`s) so those
    /// are excluded. `let` bindings add to `lambda_locals`; every sub-expression is
    /// handed to [`LlvmCompiler.scanExprCaptures`].
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

    /// Whether `obj_name` in `obj_name.member` denotes a namespace/type receiver
    /// (a struct, enum, a known builtin like `console`/`bytes`/`serde`, or a name
    /// that forms a known flat/suffixed function symbol) rather than a captured
    /// variable. Lets capture analysis skip these so a module name is not mistaken
    /// for a captured local.
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

    /// Walks a lambda body expression and records any free identifier as a capture
    /// of the current lambda.
    ///
    /// An identifier is a capture unless it is `self`, a builtin, a lambda param or
    /// local, a constant, a parent-function parameter (those are reached directly),
    /// a global function (by exact or suffix-matched name), or a type name. New
    /// captures are appended once to the current lambda's list in `lambda_captures`.
    /// Namespace-receiver field accesses are not descended into.
    fn scanExprCaptures(self: *LlvmCompiler, expr: ast.Expression, parent_name: []const u8, lambda_params: std.StringHashMap(void), lambda_locals: *std.StringHashMap(void)) anyerror!void {
        switch (expr.kind) {
            .ident => |name| {
                if (std.mem.eql(u8, name, "self")) return;

                if (std.mem.eql(u8, name, "console") or std.mem.eql(u8, name, "bytes")) return;
                if (lambda_params.contains(name)) return;
                if (lambda_locals.contains(name)) return;
                if (self.constants.contains(name)) return;

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
                        // A suffix match is meant to recognise a module-qualified FREE
                        // function (e.g. `web_validation_notEmpty` for `notEmpty`) so it
                        // is reached directly, not captured. It must NOT match a METHOD
                        // symbol (`Type_method`, e.g. `Rules_result`): a same-suffixed
                        // method name would otherwise shadow a captured local like
                        // `result`, so the local is never captured and codegen cannot
                        // find it. Methods take `self` as their first parameter, so skip
                        // those and let the identifier fall through to the capture path.
                        if (std.mem.endsWith(u8, f.name, suffix)) {
                            const is_method = f.param_names.len > 0 and std.mem.eql(u8, f.param_names[0], "self");
                            if (!is_method) return;
                        }
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

    /// Derives a symbol namespace prefix from a declaration's source file, so
    /// same-named functions in different modules get distinct mangled names.
    ///
    /// Returns null for the main program file and a few well-known synthetic files
    /// (so their symbols stay unprefixed). Otherwise it strips a leading
    /// `src/std/`, `src/lib/`, `.nova/std/` or `.nova/lib/` root and the file
    /// extension, then replaces path separators and dots with `_`. Caller owns the
    /// returned slice.
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
            if (char == '/' or char == '\\' or char == '.') {
                prefix[idx] = '_';
            }
        }
        return prefix;
    }

    /// Whether a function named `name` exists, checking both the emitted-value map
    /// (`func_map`) and the pending emission worklist (`functions`).
    pub fn hasFunction(self: *LlvmCompiler, name: []const u8) bool {
        if (self.func_map.contains(name)) return true;
        for (self.functions.items) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    /// Grafted from `types.zig`: resolves a bare callee identifier to its mangled
    /// function name.
    pub const resolveCalleeName = types_mod.resolveCalleeName;

    /// Grafted from `types.zig`: renders an AST `TypeRef` to its canonical type-name
    /// string.
    pub const typeRefToString = types_mod.typeRefToString;

    /// Builds the `functions` emission worklist by walking every program
    /// declaration and flattening generics into concrete instantiations.
    ///
    /// For each struct it registers the type, then for each method emits one
    /// `FunctionInfo` per recorded method instantiation (skipping unreachable
    /// generic methods, and suppressing the erased base when `sema_mono.baseIsNeeded`
    /// says it is not required). Enums and unions are registered similarly. After a
    /// transitive expansion pass ([`LlvmCompiler.expandFreeFnInstsTransitively`]) it
    /// walks free functions, applying struct/module name mangling and emitting a
    /// specialisation per recorded free-function instantiation. Constructors get a
    /// synthesised leading `self` parameter. The `current_instantiation*` cursors
    /// are set around each so return types render concretely.
    pub fn collectFunctions(self: *LlvmCompiler, program: ast.Program) !void {

        for (program.declarations) |decl| {
            if (decl == .struct_decl) {
                const s = decl.struct_decl;

                try self.structs.put(self.scopedStructName(s.name, s.span.file), s);
                for (s.methods) |method| {
                    const fn_decl = method.decl;
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
                    .params = fn_decl.params,
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

                        try self.functions.append(self.allocator, .{
                            .name = spec_name,
                            .param_count = fn_decl.params.len,
                            .param_names = spec_params,
                            .return_type = spec_ret,
                            .ret_type_ref = fn_decl.ret_type,
                            .body = fn_decl.body,
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

    /// Closes the set of generic free-function instantiations under "one
    /// instantiation calls another".
    ///
    /// A concrete call `f<int>` may, inside `f`'s body, call `g<int>`, which sema's
    /// initial pass did not see because it never walked `f` under that
    /// instantiation. This runs a fixed-point loop: for each currently-recorded
    /// free-fn instantiation it re-walks the callee body under that instantiation
    /// id, registering any newly-discovered generic call, until a pass adds nothing
    /// (bounded by a large guard to prevent runaway). Without this, transitively
    /// reached specialisations would be missing at link time.
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

                const prev_iid = self.current_instantiation_id;
                self.current_instantiation_id = fi.inst_key;
                defer self.current_instantiation_id = prev_iid;

                if (try self.discoverGenericCallsInBlock(fd.body, &gmap)) changed = true;
            }

            // Also walk generic METHOD instantiation bodies. A generic method that
            // forwards its own type parameter into a generic free-function call
            // (for example `orm.queryAs<T>(self.conn, ...)` inside `Db.query<T>`)
            // only becomes concrete at the method instantiation, so inference never
            // records the nested free-fn instantiation. With the method's
            // instantiation as the active substitution, `discoverGenericCallsInBlock`
            // renders the forwarded `T` to its concrete type (via `typeRefToString`)
            // and registers the free-fn inst, so its body gets emitted and the call
            // site resolves. Mirrors the free-fn loop above; the fixpoint quiesces
            // once every nested instantiation has been recorded.
            if (sema_shadow.live_sema) |sm| {
                for (sema_mono.method_insts.items) |mi| {
                    const key = mi.inst_key orelse continue;
                    const mowner = mi.method_owner orelse continue;
                    const msym = sm.tab.symbolAt(mowner);
                    if (msym.decl != .function) continue;
                    const mfd = msym.decl.function;
                    if (mfd.type_params.len == 0) continue;

                    const prev_iid_m = self.current_instantiation_id;
                    self.current_instantiation_id = key;
                    defer self.current_instantiation_id = prev_iid_m;

                    if (try self.discoverGenericCallsInBlock(mfd.body, &gmap)) changed = true;
                }
            }

            // Also walk generic-STRUCT (class) method bodies, once per concrete
            // instantiation. A non-generic method on a generic class forwards the
            // CLASS type parameter T into a generic free-function call (for example
            // `Repository<T>.all()` calling `db.query<T>`), which only becomes
            // concrete at the struct instantiation. Setting both the instantiation
            // name and its interned id lets `typeRefToString`/`concreteTidForTypeRef`
            // render T to the instantiation's type argument, so the nested free-fn
            // instantiation is registered and emitted.
            for (program.declarations) |decl| {
                if (decl != .struct_decl) continue;
                const s = decl.struct_decl;
                if (s.type_params.len == 0) continue;
                const insts = self.instantiationsOf(s) catch continue;
                defer self.allocator.free(insts);
                for (insts) |inst_opt| {
                    const inst = inst_opt orelse continue;
                    const prev_ci = self.current_instantiation;
                    const prev_iid_s = self.current_instantiation_id;
                    self.current_instantiation = inst;
                    self.current_instantiation_id = sema_mono.live_inst_ids.get(inst);
                    defer {
                        self.current_instantiation = prev_ci;
                        self.current_instantiation_id = prev_iid_s;
                    }
                    for (s.methods) |method| {
                        if (method.decl.type_params.len > 0) continue; // generic methods: handled above
                        if (try self.discoverGenericCallsInBlock(method.decl.body, &gmap)) changed = true;
                    }
                }
            }
        }
    }

    /// Walks a block for generic-function call sites during transitive
    /// instantiation discovery, returning true if any new instantiation was
    /// registered. `gmap` is the name -> declaration map of the program's generic
    /// free functions.
    fn discoverGenericCallsInBlock(self: *LlvmCompiler, block: ast.Block, gmap: *const std.StringHashMap(ast.FunctionDecl)) anyerror!bool {
        var any = false;
        for (block.statements) |stmt| {
            if (try self.discoverGenericCallsInStmt(stmt, gmap)) any = true;
        }
        return any;
    }

    /// Recurses a statement's sub-expressions and nested blocks for generic call
    /// sites during transitive instantiation discovery; returns true if any new
    /// instantiation was registered.
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

    /// Recurses an expression for generic call sites; when it finds a
    /// `callee<type_args>` whose callee is one of the program's generic free
    /// functions and whose type arguments match arity, it registers that
    /// instantiation (see [`LlvmCompiler.registerGenericFnInst`]) and reports whether
    /// anything new was added.
    fn discoverGenericCallsInExpr(self: *LlvmCompiler, expr: ast.Expression, gmap: *const std.StringHashMap(ast.FunctionDecl)) anyerror!bool {
        var any = false;
        switch (expr.kind) {
            .generic_call => |gc| {
                // The callee is either a bare `fn<T>(...)` (ident) or a
                // module-qualified `mod.fn<T>(...)` (field access, e.g.
                // `orm.queryAs<T>`). Match its final name against the generic
                // free-function map either way; matching by name mirrors the
                // ident path and is safe, since a spurious match only records an
                // unused instantiation that later DCE drops.
                var callee_name: ?[]const u8 = null;
                if (gc.callee.kind == .ident) {
                    callee_name = gc.callee.kind.ident;
                } else if (gc.callee.kind == .field_access) {
                    callee_name = gc.callee.kind.field_access.field;
                }
                if (callee_name) |cn| {
                    if (gmap.get(cn)) |callee_fd| {
                        if (gc.type_args.len == callee_fd.type_params.len and gc.type_args.len > 0) {
                            if (try self.registerGenericFnInst(callee_fd, gc.type_args)) any = true;
                        }
                    }
                }
                if (try self.discoverGenericCallsInExpr(gc.callee.*, gmap)) any = true;
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

    /// Records a concrete instantiation of a generic free function, returning true
    /// if it was newly added.
    ///
    /// Only fully-concrete type arguments are recorded (an argument that is still
    /// one of the callee's own type parameters is rejected). When the live sema
    /// tables are available it records the instantiation by `TypeId` and drives the
    /// typed-IR instantiation dispatcher so the specialisation's body is realised;
    /// otherwise it falls back to a string-based record. This is the registration
    /// step invoked from [`LlvmCompiler.discoverGenericCallsInExpr`].
    fn registerGenericFnInst(self: *LlvmCompiler, callee_fd: ast.FunctionDecl, type_args: []const ast.TypeRef) anyerror!bool {
        const rendered = try self.allocator.alloc([]const u8, type_args.len);
        defer {
            for (rendered) |r| self.allocator.free(r);
            self.allocator.free(rendered);
        }
        var all_concrete = true;
        for (type_args, 0..) |ta, idx| {
            rendered[idx] = try self.typeRefToString(ta);
            for (callee_fd.type_params) |tp| {
                if (std.mem.eql(u8, rendered[idx], tp)) all_concrete = false;
            }
        }
        if (!all_concrete) return false;

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

    /// Pre-pass that gathers every distinct string literal in the program (function,
    /// method and enum-method bodies) into `strings`, so each can be interned once
    /// as a global before emission.
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

    /// Walks a block collecting its string literals into `strings`, part of the
    /// [`LlvmCompiler.collectStringLiterals`] pre-pass.
    pub fn collectStringsFromBlock(self: *LlvmCompiler, block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectStringsFromStatement(stmt);
        }
    }

    /// Recurses a statement's sub-expressions and nested blocks collecting string
    /// literals.
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

    /// Recurses an expression collecting string literals, de-duplicating against
    /// `strings` (a literal already present is not added twice). Descends into array
    /// and object literal elements, call arguments, closures, templates and so on.
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

    /// Collects the names of all locals declared in a block (including
    /// switch-pattern-bound payload names and JSX-embedded statements), so the
    /// function prologue can pre-allocate a stack slot for each. See
    /// [`LlvmCompiler.collectLocalVarNamesFromStatement`].
    pub fn collectLocalVarNames(self: *LlvmCompiler, list: *std.ArrayList([]const u8), block: ast.Block) anyerror!void {
        for (block.statements) |stmt| {
            try self.collectLocalVarNamesFromStatement(list, stmt);
        }
    }

    /// Returns the name of the enum that declares a given variant, or null if no
    /// enum has such a variant. Used to resolve an unqualified variant reference to
    /// its enum type.
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

    /// If both operands are the same payload-carrying enum, returns the enum's
    /// boxed size in 8-byte words (tag word plus the largest variant payload);
    /// otherwise null.
    ///
    /// Used where a binary operation on two enum values needs to know the boxed
    /// footprint (e.g. to copy a tagged union). Enums with no payload return null.
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

    /// Computes a variant's numeric tag and the enum's total boxed byte size, and
    /// writes them through the out-parameters.
    ///
    /// The tag is the variant's declaration index. The size is one pointer word for
    /// the tag plus the largest variant payload across the whole enum (each field is
    /// counted as one pointer word), so every variant fits the same allocation.
    /// Errors with `EnumNotFound`/`VariantNotFound` if the names are unknown.
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

    /// Returns the enum type name of a `switch` discriminant expression if it is an
    /// enum, else null. Lets the local-collection passes bind payload names from
    /// enum-pattern cases.
    fn resolveDiscriminantEnumName(self: *LlvmCompiler, discr: *const ast.Expression) ?[]const u8 {
        const t = self.resolveExpressionTypeName(discr) catch return null;
        if (t) |name| {
            if (self.enums.contains(name)) return name;
        }
        return null;
    }

    /// Recurses a statement collecting local variable names into `list`.
    ///
    /// Handles `let` (single and destructuring), nested control flow, and the
    /// tricky case of `switch` over an enum: for each enum-pattern case it binds the
    /// payload argument names (from either a call-style or struct-init-style
    /// pattern) so the extracted payloads get their own slots. JSX-embedded
    /// statements are descended into as well.
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
            .expr_stmt => |es| if (es.expr.kind == .jsx_element) try self.collectLocalVarNamesFromJsx(list, es.expr.kind.jsx_element),
            .return_stmt => |rs| if (rs.value) |v| if (v.kind == .jsx_element) try self.collectLocalVarNamesFromJsx(list, v.kind.jsx_element),
            else => {},
        }
    }

    /// Descends a JSX element tree collecting local variable names from any embedded
    /// statements and nested elements.
    fn collectLocalVarNamesFromJsx(self: *LlvmCompiler, list: *std.ArrayList([]const u8), jsx: ast.JsxElement) anyerror!void {
        for (jsx.children) |child| {
            switch (child) {
                .statement => |stmt| try self.collectLocalVarNamesFromStatement(list, stmt),
                .element => |sub| try self.collectLocalVarNamesFromJsx(list, sub),
                else => {},
            }
        }
    }

    /// Builds the current function's local name -> rendered type map (and, when
    /// `current_local_type_ids` is set, the parallel name -> `TypeId` map) by
    /// walking a block. See [`LlvmCompiler.collectLocalVarTypesFromStatement`].
    pub fn collectLocalVarTypes(self: *LlvmCompiler, map: *std.StringHashMap([]const u8), block: ast.Block) anyerror!void {
        for (block.statements) |*stmt| {
            try self.collectLocalVarTypesFromStatement(map, stmt);
        }
    }

    /// Recurses a statement inferring each local's type and recording it in `map`.
    ///
    /// For a `let` it uses the declared type if present, else the resolved
    /// initialiser type (substituting type parameters), and for a destructuring
    /// `let` it splits a tuple type per element. Where the typed IR is available it
    /// stores a precise `TypeId` (preferring the per-instantiation type), skipping
    /// unresolved/type-parameter types. Enum-`switch` cases bind their payload
    /// argument types the same way [`LlvmCompiler.collectLocalVarNamesFromStatement`]
    /// binds names.
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
            .expr_stmt => |es| if (es.expr.kind == .jsx_element) try self.collectLocalVarTypesFromJsx(map, es.expr.kind.jsx_element),
            .return_stmt => |rs| if (rs.value) |v| if (v.kind == .jsx_element) try self.collectLocalVarTypesFromJsx(map, v.kind.jsx_element),
            else => {},
        }
    }

    /// Descends a JSX element tree inferring local variable types from embedded
    /// statements and nested elements.
    fn collectLocalVarTypesFromJsx(self: *LlvmCompiler, map: *std.StringHashMap([]const u8), jsx: ast.JsxElement) anyerror!void {
        for (jsx.children) |child| {
            switch (child) {
                .statement => |stmt| try self.collectLocalVarTypesFromStatement(map, &stmt),
                .element => |sub| try self.collectLocalVarTypesFromJsx(map, sub),
                else => {},
            }
        }
    }

    /// Emits the instrumentation that bumps the coverage counter for one basic
    /// block: loads the external `__nova_cov_counters` array pointer (declaring the
    /// global on first use), indexes it by `block_id`, and stores `counter + 1`.
    /// Only called when `coverage_enabled`.
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

    // The following `pub const` lines graft type-analysis helpers from `types.zig`
    // onto [`LlvmCompiler`]. They are the codegen-side ownership/typing oracle:
    // most take an expression, name, or `TypeId` and answer a classification
    // question (is it owned? a value struct? a string? which `TypeId`?).

    /// Grafted from `types.zig`: resolves an expression to its rendered type name.
    pub const resolveExpressionTypeName = types_mod.resolveExpressionTypeName;
    /// Grafted from `types.zig`: the cached rendered name for a `TypeId`.
    pub const cachedTypeName = types_mod.cachedTypeName;
    /// Grafted from `types.zig`: the module-scoped unique name for a struct.
    pub const scopedStructName = types_mod.scopedStructName;
    /// Grafted from `types.zig`: the module-scoped unique name for any type.
    pub const scopedTypeName = types_mod.scopedTypeName;
    /// Grafted from `types.zig`: whether a struct name collides across modules and
    /// needs scoping.
    pub const isCollidingStruct = types_mod.isCollidingStruct;
    /// Grafted from `types.zig`: whether an expression has optional type.
    pub const isOptionalExpr = types_mod.isOptionalExpr;
    /// Grafted from `types.zig`: the concrete `TypeId` of an expression, if known.
    pub const typeOfExprConcrete = types_mod.typeOfExprConcrete;
    /// Grafted from `types.zig`: whether an expression yields a heap-owned value.
    pub const isOwnedExpr = types_mod.isOwnedExpr;
    /// Grafted from `types.zig`: whether a `TypeId` denotes an owned type.
    pub const isOwnedTypeId = types_mod.isOwnedTypeId;
    /// Grafted from `types.zig`: whether a named local is heap-owned.
    pub const isOwnedLocal = types_mod.isOwnedLocal;
    /// Grafted from `types.zig`: whether a type name denotes a value struct.
    pub const isValueStructName = types_mod.isValueStructName;
    /// Grafted from `types.zig`: whether a `TypeId` denotes a value struct.
    pub const isValueStructTid = types_mod.isValueStructTid;
    /// Grafted from `types.zig`: whether a value struct has any heap-owning fields
    /// (so copies must deep-retain).
    pub const valueStructHasOwnedFields = types_mod.valueStructHasOwnedFields;
    /// Grafted from `types.zig`: whether a function's return is a borrow (not an
    /// owning transfer).
    pub const returnIsBorrow = types_mod.returnIsBorrow;
    /// Grafted from `types.zig`: whether an error-union's ok payload is owned.
    pub const isOwnedErrUnionOk = types_mod.isOwnedErrUnionOk;
    /// Grafted from `types.zig`: whether an expression has string type.
    pub const isStringExpr = types_mod.isStringExpr;
    /// Grafted from `types.zig`: whether an expression has floating-point type.
    pub const isFloatExpr = types_mod.isFloatExpr;
    /// Grafted from `types.zig`: whether an expression has bool type.
    pub const isBoolExpr = types_mod.isBoolExpr;
    /// Grafted from `types.zig`: whether an expression has void type.
    pub const isVoidExpr = types_mod.isVoidExpr;
    /// Grafted from `types.zig`: whether an expression has `any` type.
    pub const isAnyExpr = types_mod.isAnyExpr;
    /// Grafted from `types.zig`: whether an expression has decimal type.
    pub const isDecimalExpr = types_mod.isDecimalExpr;
    /// Grafted from `types.zig`: the mangled symbol name for a `TypeId`.
    pub const symbolName = types_mod.symbolName;
    /// Grafted from `types.zig`: the trait name of a tuple element, if it is one.
    pub const tupleElemTraitName = types_mod.tupleElemTraitName;
    /// Grafted from `types.zig`: whether an error-union's error payload is owned.
    pub const isOwnedErrUnionErr = types_mod.isOwnedErrUnionErr;
    /// Grafted from `types.zig`: whether a storage element (container slot) is owned.
    pub const isOwnedStorageElem = types_mod.isOwnedStorageElem;
    /// Grafted from `types.zig`: whether a storage element is owned, by type name.
    pub const isOwnedStorageElemByName = types_mod.isOwnedStorageElemByName;
    /// Grafted from `types.zig`: the `TypeId` for a rendered type name.
    pub const typeIdForRenderedName = types_mod.typeIdForRenderedName;
    /// Grafted from `types.zig`: whether an error-union payload is owned, by name.
    pub const isOwnedErrUnionPayloadByName = types_mod.isOwnedErrUnionPayloadByName;
    /// Grafted from `types.zig`: whether a tuple element is owned, by name.
    pub const isOwnedTupleElemByName = types_mod.isOwnedTupleElemByName;
    /// Grafted from `types.zig`: whether a declared type is owned (given the
    /// `TypeRef` and its rendered name).
    pub const isOwnedDeclaredType = types_mod.isOwnedDeclaredType;
    /// Grafted from `types.zig`: the `TypeId` for an AST `TypeRef` (may be generic).
    pub const tidForTypeRef = types_mod.tidForTypeRef;
    /// Grafted from `types.zig`: the concrete `TypeId` for a `TypeRef` under the
    /// current instantiation.
    pub const concreteTidForTypeRef = types_mod.concreteTidForTypeRef;
    /// Grafted from `types.zig`: the `TypeId` for a rendered type name.
    pub const tidForName = types_mod.tidForName;
    /// Grafted from `types.zig`: whether a type name is owned.
    pub const ownedByName = types_mod.ownedByName;

    /// Grafted from `statements.zig`: lowers one statement to IR.
    pub const compileStatement = statements_mod.compileStatement;
    /// Grafted from `statements.zig`: runs the scope's errdefer statements on the
    /// error path.
    pub const runErrdefers = statements_mod.runErrdefers;

    // The remaining `pub const` lines graft the expression-lowering surface from
    // `expressions.zig`: the bulk of codegen (arithmetic, calls, containers,
    // async/await, SIMD, JSX, ORM/query lowering) lives there and is exposed here
    // as methods on [`LlvmCompiler`].

    /// Grafted from `expressions.zig`: lowers one expression to an `i64` value word.
    pub const compileExpression = expressions_mod.compileExpression;
    /// Grafted from `expressions.zig`: lowers a reference to a compile-time constant.
    pub const compileConstRef = expressions_mod.compileConstRef;
    /// Grafted from `expressions.zig`: default-initialises a struct's container fields.
    pub const initDefaultContainerFields = expressions_mod.initDefaultContainerFields;
    /// Grafted from `expressions.zig`: removes a pending temporary whose ownership
    /// was handed off (so it is not double-released).
    pub const consumeTemporary = expressions_mod.consumeTemporary;
    /// Grafted from `expressions.zig`: builds an `Atomic<T>` cell value.
    pub const atomicCell = expressions_mod.atomicCell;
    /// Grafted from `expressions.zig`: emits a null-guard before dereferencing an
    /// optional.
    pub const guardOptionalDeref = expressions_mod.guardOptionalDeref;
    /// Grafted from `expressions.zig`: registers a value as a [`PendingTemp`] for
    /// end-of-statement release.
    pub const registerTemporary = expressions_mod.registerTemporary;
    /// Grafted from `expressions.zig`: releases all pending temporaries at statement end.
    pub const drainTemporaries = expressions_mod.drainTemporaries;
    /// Grafted from `expressions.zig`: emits an indirect call through a closure value.
    pub const buildClosureCall = expressions_mod.buildClosureCall;
    /// Grafted from `expressions.zig`: lowers a floating-point SIMD intrinsic call.
    pub const compileSimdCall = expressions_mod.compileSimdCall;
    /// Grafted from `expressions.zig`: lowers an integer SIMD intrinsic call.
    pub const compileIntSimd = expressions_mod.compileIntSimd;
    /// Grafted from `expressions.zig`: emits a 64-bit carry-less multiply (for CRC/GCM).
    pub const compileClmul64 = expressions_mod.compileClmul64;
    /// Grafted from `expressions.zig`: emits a hardware AES round intrinsic.
    pub const compileAesRound = expressions_mod.compileAesRound;
    /// Grafted from `expressions.zig`: lowers a `mem`/allocator method call.
    pub const compileMemCall = expressions_mod.compileMemCall;
    /// Grafted from `expressions.zig`: loads an array element as a float value.
    pub const arrayElemFloatLLVM = expressions_mod.arrayElemFloatLLVM;
    /// Grafted from `expressions.zig`: computes the base pointer of an array's storage.
    pub const arrayBasePtr = expressions_mod.arrayBasePtr;
    /// Grafted from `expressions.zig`: boxes a bare function pointer into a closure value.
    pub const buildBareFnBox = expressions_mod.buildBareFnBox;
    /// Grafted from `expressions.zig`: returns the boxed-function global for a name.
    pub const fnBoxReturn = expressions_mod.fnBoxReturn;
    /// Grafted from `expressions.zig`: the integer function-reference value for a name.
    pub const fnRefInt = expressions_mod.fnRefInt;
    /// Grafted from `expressions.zig`: whether an identifier names a variable (vs. a
    /// type/function/namespace).
    pub const identNamesVariable = expressions_mod.identNamesVariable;
    /// Grafted from `expressions.zig`: widens a branch's value into a trait object to
    /// unify the branches of an `if`/`switch` expression.
    pub const widenBranchToTrait = expressions_mod.widenBranchToTrait;
    /// Grafted from `expressions.zig`: allocates inline storage for a value struct.
    pub const buildValueStructStorage = expressions_mod.buildValueStructStorage;
    /// Grafted from `expressions.zig`: copies a value struct, returning the copy.
    pub const buildValueStructCopy = expressions_mod.buildValueStructCopy;
    /// Grafted from `expressions.zig`: copies a value struct into a given destination.
    pub const buildValueStructCopyInto = expressions_mod.buildValueStructCopyInto;
    /// Grafted from `expressions.zig`: emits the element type-witness for a container.
    pub const compileElemWitness = expressions_mod.compileElemWitness;
    /// Grafted from `expressions.zig`: deep-retains a value struct's owned fields
    /// after an inline copy.
    pub const retainValueStructOwnedFields = expressions_mod.retainValueStructOwnedFields;
    /// Grafted from `expressions.zig`: the value-struct name inside an optional, if any.
    pub const optionalInnerValueStructName = expressions_mod.optionalInnerValueStructName;
    /// Grafted from `expressions.zig`: deep-copies an optional wrapping a value struct.
    pub const buildOptionalStructDeepCopy = expressions_mod.buildOptionalStructDeepCopy;
    /// Grafted from `expressions.zig`: deep-copies a heap struct value.
    pub const buildHeapStructDeepCopy = expressions_mod.buildHeapStructDeepCopy;
    /// Grafted from `types.zig`: whether a type name is a pure value struct (no
    /// owned fields).
    pub const isPureValueStructName = types_mod.isPureValueStructName;
    /// Grafted from `expressions.zig`: drives an async function call as a coroutine
    /// to its first suspend.
    pub const buildDriveAsyncCall = expressions_mod.buildDriveAsyncCall;
    /// Grafted from `expressions.zig`: drives an async coroutine handle.
    pub const buildDriveAsyncHandle = expressions_mod.buildDriveAsyncHandle;
    /// Grafted from `expressions.zig`: the LLVM type of a coroutine promise.
    pub const coroPromiseType = expressions_mod.coroPromiseType;
    /// Grafted from `expressions.zig`: the promise slot within a coroutine frame.
    pub const coroPromiseSlot = expressions_mod.coroPromiseSlot;
    /// Grafted from `expressions.zig`: the result slot within a coroutine promise.
    pub const coroPromiseResultSlot = expressions_mod.coroPromiseResultSlot;
    /// Grafted from `expressions.zig`: the waiter slot within a coroutine promise
    /// (the coroutine to resume on completion).
    pub const coroPromiseWaiterSlot = expressions_mod.coroPromiseWaiterSlot;
    /// Grafted from `expressions.zig`: computes the pointer to a coroutine's promise.
    pub const buildCoroPromisePtr = expressions_mod.buildCoroPromisePtr;
    /// Grafted from `expressions.zig`: the coroutine handle produced by an awaited call.
    pub const awaitedCallHandle = expressions_mod.awaitedCallHandle;
    /// Grafted from `expressions.zig`: lowers an `await` expression.
    pub const buildAwait = expressions_mod.buildAwait;
    /// Grafted from `expressions.zig`: emits the suspend point of an `await`.
    pub const buildAwaitSuspend = expressions_mod.buildAwaitSuspend;
    /// Grafted from `expressions.zig`: lowers an `await sleep(ms)`.
    pub const awaitSleepMillis = expressions_mod.awaitSleepMillis;
    /// Grafted from `expressions.zig`: lowers a `spawn`/`go` expression (forks a future).
    pub const buildGo = expressions_mod.buildGo;
    /// Grafted from `expressions.zig`: awaits (joins) a future value.
    pub const buildAwaitFuture = expressions_mod.buildAwaitFuture;
    /// Grafted from `expressions.zig`: extracts the channel argument of an awaited recv.
    pub const awaitChanRecvArg = expressions_mod.awaitChanRecvArg;
    /// Grafted from `expressions.zig`: lowers a channel receive.
    pub const buildChanRecv = expressions_mod.buildChanRecv;
    /// Grafted from `expressions.zig`: lowers a `whenAny`/`selectAny` combinator.
    pub const buildWhenAny = expressions_mod.buildWhenAny;
    /// Grafted from `expressions.zig`: detects an awaited async-I/O call.
    pub const awaitAsyncIoCall = expressions_mod.awaitAsyncIoCall;
    /// Grafted from `expressions.zig`: lowers an async-I/O operation.
    pub const buildAsyncIo = expressions_mod.buildAsyncIo;
    /// Grafted from `expressions.zig`: appends a value to the active string builder.
    pub const compileAppendToStringBuilder = expressions_mod.compileAppendToStringBuilder;
    /// Grafted from `expressions.zig`: lowers a method call on an optional receiver.
    pub const compileOptionalMethodCall = expressions_mod.compileOptionalMethodCall;
    /// Grafted from `expressions.zig`: canonicalises an integer value to its declared width.
    pub const canonicalizeInt = expressions_mod.canonicalizeInt;
    /// Grafted from `expressions.zig`: emits a divide-by-zero guard before integer division.
    pub const emitIntDivGuard = expressions_mod.emitIntDivGuard;
    /// Grafted from `expressions.zig`: emits a conditional trap.
    pub const emitTrapIf = expressions_mod.emitTrapIf;
    /// Grafted from `expressions.zig`: converts a number to its string representation.
    pub const numToString = expressions_mod.numToString;
    /// Grafted from `expressions.zig`: the implementation body of number-to-string.
    pub const numToStringImpl = expressions_mod.numToStringImpl;
    /// Grafted from `expressions.zig`: number-to-string for a specific numeric type.
    pub const numToStringT = expressions_mod.numToStringT;
    /// Grafted from `expressions.zig`: lowers a JSX element to HTML-building IR.
    pub const compileJsxElement = expressions_mod.compileJsxElement;
    /// Grafted from `expressions.zig`: emits a JSX subtree into a string builder.
    pub const emitJsxInto = expressions_mod.emitJsxInto;
    /// Grafted from `expressions.zig`: appends a computed value to JSX output.
    pub const jsxAppendVal = expressions_mod.jsxAppendVal;
    /// Grafted from `expressions.zig`: appends a literal chunk to JSX output.
    pub const jsxAppendLiteral = expressions_mod.jsxAppendLiteral;
    /// Grafted from `expressions.zig`: flushes buffered JSX literal bytes.
    pub const jsxFlushLiteral = expressions_mod.jsxFlushLiteral;
    /// Grafted from `expressions.zig`: appends an interpolated expression to JSX output.
    pub const jsxAppendExpr = expressions_mod.jsxAppendExpr;
    /// Grafted from `expressions.zig`: sets the source location for JSX debug info.
    pub const jsxSetLoc = expressions_mod.jsxSetLoc;
    /// Grafted from `expressions.zig`: lowers a generic `parse<T>` call.
    pub const compileGenericParse = expressions_mod.compileGenericParse;
    /// Grafted from `expressions.zig`: lowers decoding of one binary result-set row
    /// (the ORM fast path).
    pub const compileDecodeBinaryRow = expressions_mod.compileDecodeBinaryRow;
    /// Grafted from `expressions.zig`: lowers a NovaDB query expression.
    pub const compileNovaQuery = expressions_mod.compileNovaQuery;
    /// Grafted from `expressions.zig`: converts a value to a target type.
    pub const convertValueToType = expressions_mod.convertValueToType;
    /// Grafted from `expressions.zig`: resolves the type name for a reification/`reify` site.
    pub const resolveReifyTypeName = expressions_mod.resolveReifyTypeName;
    /// Grafted from `expressions.zig`: looks up (or lazily declares) a function by name.
    pub const getFunc = expressions_mod.getFunc;
};

/// The codegen entry point: compiles a whole type-checked program into an LLVM
/// module and drives it through to a native object/binary. Implemented in
/// `declarations.zig`; re-exported here as the file's public surface.
pub const compile = declarations_mod.compile;
/// The codegen flags/options struct that parameterises [`compile`] (target,
/// release, WASM, coverage, and so on). Implemented in `declarations.zig`.
pub const flags = declarations_mod.flags;
