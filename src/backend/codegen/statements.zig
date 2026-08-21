//! Statement lowering for the LLVM backend: turns a Nova [`ast.Statement`] into
//! IR emitted through the active `LlvmCompiler` builder.
//!
//! This file owns the control-flow half of code generation. Every statement
//! form in the language dispatches here from [`compileStatement`]: `let`
//! bindings (including tuple destructuring), expression statements, blocks,
//! `if`/`while`/`for`, `switch` (including tagged-union pattern binding),
//! `return`, `break`/`continue`, and `defer`/`errdefer`. Expression evaluation
//! itself lives in `expressions.zig`; this module is about sequencing, basic
//! blocks, and the memory-management bookkeeping that has to happen at
//! statement boundaries.
//!
//! Two cross-cutting concerns dominate the code here and explain most of its
//! bulk:
//!
//!   1. **ARC ownership at scope boundaries.** Nova is reference-counted (see
//!      `arc.zig`), so the compiler must retain on copy and release on scope
//!      exit. A `let` that binds an owned value records the local in the current
//!      [`Scope.owned_locals`]; a block, `break`, `continue`, or `return`
//!      replays those releases in reverse order. Owned payloads bound out of a
//!      tagged-union `switch` case are retained on entry and released on every
//!      exit edge (fallthrough, guard failure, terminator). Getting an edge
//!      wrong is a leak or a use-after-free, so each control-flow arm is careful
//!      to release exactly on the paths it owns.
//!
//!   2. **Value-vs-reference and optional boxing.** Value structs are copied on
//!      binding ([`LlvmCompiler.buildValueStructCopy`]), value-optionals are
//!      boxed into a discriminated slot on `let`/`return` unless the initialiser
//!      already yields a box, trait targets widen a concrete struct into a fat
//!      pointer, and `any` targets coerce. `return` additionally has to compose
//!      these with error-union wrapping and the async-coroutine result-slot
//!      path. These transforms are order-sensitive and interlock, which is why
//!      [`compileStatement`]'s `.return_stmt` and `.let_stmt` arms are the
//!      longest.
//!
//! Terminator discipline: LLVM basic blocks may have at most one terminator, so
//! nearly every arm guards on `LLVMGetBasicBlockTerminator` before emitting a
//! branch, and [`compileStatement`] returns early if the current block is
//! already terminated (e.g. after a `return` inside a block).

const std = @import("std");
/// Nova AST node definitions; statements dispatch on [`ast.Statement`] and read
/// their embedded expressions and type references.
const ast = @import("../../frontend/ast.zig");
/// LLVM-C bindings package (builder, module, value/type refs).
const llvm = @import("llvm");
/// LLVM type-level enums (`LLVMIntPredicate`, type-kind tags).
const types = llvm.types;
/// LLVM-C core API: basic-block, builder, and instruction constructors.
const core = llvm.core;
/// Semantic type layer, used here for [`sema_types.TypeId`] when preferring a
/// resolved type id over a spelled name to select destructors.
const sema_types = @import("../../frontend/types.zig");

/// Strips a monomorphised/qualified struct name down to its base identifier
/// (e.g. `List_int` or a module-scoped name to `List`), so container and
/// destructor lookups match on the declared type.
const getStructBaseName = @import("types.zig").getStructBaseName;
/// The backend compiler state: holds the LLVM builder/module, the scope stack,
/// local/type maps, and every emit helper this file calls through `self`.
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
/// Per-function codegen context (name, declared return type + type-ref) passed
/// down so `return` can wrap/coerce to the right shape.
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
/// A lexical scope frame: its deferred/errdeferred statement lists and its
/// list of owned locals awaiting release on exit.
const Scope = @import("llvm_codegen.zig").Scope;

/// A "presence narrowing" fact recovered from an `if` condition of the form
/// `x != undefined` (or `x == undefined`).
///
/// When the compiler proves a named value is present on one branch it records
/// that in `narrowed_present` for the duration of that branch, which lets loads
/// of a value-optional skip the box on the narrowed side. See
/// [`detectPresenceNarrow`] for how it is extracted and the `.if_stmt` arm of
/// [`compileStatement`] for how it is applied.
const PresenceNarrow = struct {
    /// The identifier being tested against `undefined`.
    name: []const u8,
    /// Whether the narrowing (`name` is present) holds on the THEN branch. True
    /// for `!=`, false for `==` (where presence holds on the ELSE branch).
    then_branch: bool,
};
/// Recognises an `if` condition that narrows a value's presence, returning the
/// [`PresenceNarrow`] fact or `null` when the condition is not such a test.
///
/// Matches a binary `==`/`!=` where exactly one side is an identifier and the
/// other is the `undefined` literal (in either order). Any other condition
/// shape yields `null`, so narrowing is a best-effort optimisation and never a
/// correctness requirement.
fn detectPresenceNarrow(cond: ast.Expression) ?PresenceNarrow {
    if (cond.kind != .binary) return null;
    const bin = cond.kind.binary;
    if (bin.op != .ne and bin.op != .eq) return null;
    var name: ?[]const u8 = null;
    if (bin.left.kind == .ident and LlvmCompiler.isUndefinedLiteralExpr(bin.right)) {
        name = bin.left.kind.ident;
    } else if (bin.right.kind == .ident and LlvmCompiler.isUndefinedLiteralExpr(bin.left)) {
        name = bin.right.kind.ident;
    }
    const n = name orelse return null;
    return PresenceNarrow{ .name = n, .then_branch = (bin.op == .ne) };
}

/// Emits the pending `errdefer` expressions of every active scope, innermost
/// first, on an error-return path.
///
/// Walks the scope stack from top to bottom and, within each scope, replays its
/// `errdeferred_statements` in reverse registration order (LIFO), mirroring how
/// `defer` unwinds. Called from [`compileStatement`]'s `.return_stmt` arm only
/// when a value is being returned as the ERROR side of an error union, so the
/// clean-up registered by `errdefer` runs precisely on the failure path.
pub fn runErrdefers(self: *LlvmCompiler) anyerror!void {
    var si = self.scopes.items.len;
    while (si > 0) {
        si -= 1;
        const scope = &self.scopes.items[si];
        var i = scope.errdeferred_statements.items.len;
        while (i > 0) {
            i -= 1;
            _ = try self.compileExpression(scope.errdeferred_statements.items[i]);
        }
    }
}

/// Releases the owned locals of every scope inside the current loop body when
/// control leaves the loop early via `break` or `continue`.
///
/// A `break`/`continue` branches straight to the loop's exit/condition block,
/// bypassing the normal end-of-block release that the intervening scopes would
/// otherwise run, so those owned locals would leak. This walks the scope stack
/// down to (but not including) `current_loop_scope_depth`, the scope index
/// recorded when the loop was entered, releasing each scope's `owned_locals` in
/// reverse. It intentionally does NOT pop the scopes: they are still live and
/// their normal exit paths (or the surrounding block's `.block` handler) remain
/// responsible for structural teardown. Returns immediately if no loop is
/// active. See the `.break_stmt`/`.continue_stmt` arms of [`compileStatement`].
fn releaseScopesForLoopExit(self: *LlvmCompiler) anyerror!void {
    const depth = self.current_loop_scope_depth orelse return;
    var i = self.scopes.items.len;
    while (i > depth) {
        i -= 1;
        const scope = &self.scopes.items[i];

        var oi = scope.owned_locals.items.len;
        while (oi > 0) {
            oi -= 1;
            const ol = scope.owned_locals.items[oi];
            try self.releaseLocalByName(ol.name, ol.type_name);
        }
    }
}

/// Lowers a single Nova statement to LLVM IR under the active builder position.
///
/// This is the control-flow dispatcher for the backend. It first bails out if
/// the current basic block already has a terminator (so dead statements after a
/// `return`/`break` emit nothing), then attaches a debug location and, when
/// coverage is enabled for non-std sources, a per-statement coverage counter.
/// Temporaries created while evaluating the statement are drained at the end via
/// the `temp_mark` snapshot of `pending_temps`.
///
/// The `switch (stmt)` body handles each statement form. The heavy arms and
/// their subtleties:
///
///   - `.let_stmt`: registers owned locals for later release, evaluates the
///     initialiser, then applies the binding-time transforms in a specific
///     order: tuple destructuring (with per-element retain of owned slots),
///     trait widening, `any` coercion, deep-copy vs retain for owned r-values
///     (value-optional / tuple / heap-struct / plain retain), value-optional
///     boxing, and value-struct copy-with-field-retain. It also emits debug
///     info for the local. The ordering matters because each transform assumes
///     the prior ones have run.
///   - `.expr_stmt`: also drives JSX emission into a string builder and, for an
///     owned call/`struct_init` result whose value is discarded, releases it so
///     the temporary does not leak.
///   - `.block`: pushes a [`Scope`], compiles children until a terminator, then
///     on the non-terminated path runs deferred statements (LIFO) and releases
///     owned locals (LIFO) before tearing the scope down.
///   - `.if_stmt`: builds then/else/merge blocks and threads
///     [`PresenceNarrow`] facts into `narrowed_present` for the branch on which
///     the value is proven present.
///   - `.while_stmt`/`.for_stmt`: build cond/body/(incr/)exit blocks and save
///     and restore the break/continue targets and `current_loop_scope_depth`.
///     `.for_stmt` currently only lowers `for (i in a..b)` range loops and the
///     C-style init/cond/incr form; non-range iterables and destructuring
///     bindings error as unimplemented.
///   - `.switch_stmt`: for a tagged-union discriminant it loads the tag word,
///     and inside each case binds the variant payload(s) by offset into the
///     union, retaining owned payloads and releasing them on guard-failure,
///     fallthrough, and normal exit edges. Case values resolve enum variant
///     ordinals or integer literals.
///   - `.return_stmt`: composes value-optional boxing, trait widening, and
///     error-union wrapping in that order, runs `errdefer` on the error path,
///     retains an owned returned variable, replays all deferred statements and
///     releases locals, then emits the return itself, dispatching to the async
///     coroutine result-slot path, the `main` fallback, `_new` self-return, or
///     a plain ret/ret-void.
///   - `.break_stmt`/`.continue_stmt`: release loop-body scopes (see
///     [`releaseScopesForLoopExit`]) then branch to the saved target, erroring
///     if used outside a loop.
///   - `.defer_stmt`: appends the expression to the current scope's deferred or
///     errdeferred list; erroring if there is no active scope.
pub fn compileStatement(self: *LlvmCompiler, stmt: ast.Statement, func: FunctionInfo) anyerror!void {
    if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
        return;
    }

    if (self.di_scope != null) {
        const dbg_span = switch (stmt) {
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
        self.setDebugLoc(dbg_span.line, dbg_span.col);
    }

    const temp_mark = self.pending_temps.items.len;
    defer self.drainTemporaries(temp_mark) catch {};
    if (self.coverage_enabled and stmt != .block) {
        const span = switch (stmt) {
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
        const is_std = std.mem.indexOf(u8, span.file, "src/std/") != null or std.mem.eql(u8, span.file, "test_harness.nova");
        if (!is_std) {
            const desc = @tagName(stmt);
            if (self.cov_registry) |*reg| {
                const block_id = try reg.registerBlock(span.file, span.line, span.col, desc);
                try self.compileCoverageIncrement(block_id);
            }
        }
    }

    switch (stmt) {
        .let_stmt => |*ls| {

            if (self.scopes.items.len > 0) {
                if (self.current_local_types) |lt| {
                    if (ls.names) |names| {

                        for (names) |n| {
                            if (lt.get(n)) |vt| {
                                if (self.isOwnedLocal(n, vt) or (self.isValueStructName(vt) and self.valueStructHasOwnedFields(vt))) {
                                    const sc = &self.scopes.items[self.scopes.items.len - 1];
                                    try sc.owned_locals.append(self.allocator, .{ .name = n, .type_name = vt });
                                }
                            }
                        }
                    } else if (lt.get(ls.name)) |vt| {
                        if (self.isOwnedLocal(ls.name, vt) or (self.isValueStructName(vt) and self.valueStructHasOwnedFields(vt))) {
                            const sc = &self.scopes.items[self.scopes.items.len - 1];
                            try sc.owned_locals.append(self.allocator, .{ .name = ls.name, .type_name = vt });
                        }
                    }
                }
            }
            if (ls.init) |*init_ptr| {
                const init = init_ptr.*;
                var val = try self.compileExpression(init);

                if (ls.names == null) self.consumeTemporary(val);
                if (ls.names) |names| {

                    for (names, 0..) |name, idx| {
                        const alloca_val = self.locals.get(name) orelse {
                            std.debug.print("Variable '{s}' not found in locals for destructuring\n", .{name});
                            return error.VariableNotFound;
                        };
                        const element_size: usize = 8;
                        const offset = core.LLVMConstInt(self.val_type, @intCast(idx * element_size), 0);
                        const addr = core.LLVMBuildAdd(self.builder, val, offset, "tuple_addr");
                        const ptr = core.LLVMBuildIntToPtr(self.builder, addr, self.ptr_type, "tuple_ptr");
                        const elem_val = core.LLVMBuildLoad2(self.builder, self.val_type, ptr, "tuple_elem");

                        var target_type: ?[]const u8 = null;
                        if (self.current_local_types) |lt| {
                            target_type = lt.get(name);
                        }
                        if (target_type) |tt| {
                            if (self.isOwnedLocal(name, tt)) {
                                try self.compileRetain(elem_val);
                            }
                        }

                        const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                            core.LLVMGetAllocatedType(alloca_val)
                        else
                            self.val_type;
                        _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(elem_val, slot_ty), alloca_val);
                    }
                } else {
                    const alloca_val = self.locals.get(ls.name) orelse {
                        std.debug.print("Variable '{s}' not found in locals\n", .{ls.name});
                        return error.VariableNotFound;
                    };
                    var widened_to_trait = false;
                    if (ls.type_name) |t| {

                        const trait_decl_name: ?[]const u8 = switch (t) {
                            .ident => |n| n,
                            .generic => |g| g.name,
                            else => null,
                        };
                        if (trait_decl_name) |expected_type| {
                            if (self.traits.contains(expected_type)) {
                                if (try self.resolveExpressionTypeName(init_ptr)) |struct_name| {
                                    if (self.structs.contains(getStructBaseName(struct_name))) {
                                        const orig_struct = val;
                                        val = try self.constructTraitObject(orig_struct, struct_name, expected_type);

                                        self.consumeTemporary(val);
                                        widened_to_trait = true;

                                        if (self.acquisitionDisposition(&init) == .owned) {
                                            const stid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(init_ptr) else null;
                                            const sdtor = try self.getOrCreateDestructorPreferId(struct_name, stid);
                                            try self.compileRelease(orig_struct, sdtor);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    var target_type: ?[]const u8 = null;
                    if (self.current_local_types) |lt| {
                        target_type = lt.get(ls.name);
                    }
                    var widened_to_any = false;
                    if (target_type) |tt| {
                        if (!widened_to_trait and std.mem.eql(u8, tt, "any")) {
                            if (!self.isAnyExpr(init_ptr)) {
                                val = try self.coerceToAny(val, init_ptr);
                                self.consumeTemporary(val);
                                widened_to_any = true;
                            }
                        }
                    }
                    if (target_type) |tt| {

                        if (!widened_to_trait and !widened_to_any and self.isOwnedLocal(ls.name, tt)) {

                            const is_enum_variant_ctor = init.kind == .field_access and
                                init.kind.field_access.object.kind == .ident and
                                self.enums.contains(init.kind.field_access.object.kind.ident);
                            const is_r_var = (init.kind == .ident or init.kind == .field_access or init.kind == .index) and
                                !is_enum_variant_ctor;
                            if (is_r_var) {
                                var opt_inner: ?[]const u8 = null;
                                var is_tuple = false;
                                if (self.current_local_type_ids) |ids| {
                                    if (ids.get(ls.name)) |st_tid| {
                                        opt_inner = self.optionalInnerValueStructName(st_tid);
                                        if (self.type_store) |ts| is_tuple = ts.get(st_tid) == .tuple;
                                    }
                                }
                                if (opt_inner) |innerBase| {
                                    val = try self.buildOptionalStructDeepCopy(val, innerBase);
                                } else if (is_tuple) {
                                    if (self.resolveExpressionTypeName(init_ptr) catch null) |tname| {
                                        val = try self.buildTupleDeepCopy(val, tname);
                                    } else {
                                        try self.compileRetain(val);
                                    }
                                } else if (!self.isValueStructName(tt) and self.isPureValueStructName(tt)) {
                                    val = try self.buildHeapStructDeepCopy(val, tt);
                                } else {
                                    try self.compileRetain(val);
                                }
                            }
                        }
                    }

                    if (self.current_local_type_ids) |ids| {
                        if (ids.get(ls.name)) |slot_tid| {

                            if (self.valueOptionalInner(slot_tid) != null and
                                !LlvmCompiler.isUndefinedLiteralExpr(init_ptr) and
                                !self.exprYieldsValoptBox(init_ptr))
                            {
                                val = try self.buildValoptBox(self.coerceToSlotType(val, self.val_type));
                            }
                        }
                    }

                    if (target_type) |tt| {
                        if (self.isValueStructName(tt) and (init.kind == .ident or self.returnIsBorrow(&init))) {
                            const vsz = self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(tt) }, false);
                            val = try self.buildValueStructCopy(val, vsz);
                            try self.retainValueStructOwnedFields(val, tt);
                        }
                    }

                    const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                        core.LLVMGetAllocatedType(alloca_val)
                    else
                        self.val_type;
                    _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(val, slot_ty), alloca_val);

                    if (self.di_scope != null and ls.names == null) {
                        var lt_name: ?[]const u8 = if (self.current_local_types) |ltm| ltm.get(ls.name) else null;
                        if (lt_name == null) lt_name = self.resolveExpressionTypeName(init_ptr) catch null;
                        var owned: ?[]const u8 = null;
                        if (lt_name == null) {
                            if (self.current_local_type_ids) |ids| {
                                if (ids.get(ls.name)) |tid| {
                                    if (self.symbolName(tid)) |nm| {
                                        owned = nm;
                                        lt_name = nm;
                                    } else |_| {}
                                }
                            }
                        }
                        if (lt_name) |ln| {
                            const b = @import("types.zig").getStructBaseName(ln);
                            const is_container = std.mem.eql(u8, b, "List") or std.mem.eql(u8, b, "Map") or std.mem.eql(u8, b, "Set");
                            if (is_container and std.mem.eql(u8, ln, b)) {
                                if (self.current_local_type_ids) |ids| {
                                    if (ids.get(ls.name)) |tid| {
                                        if (self.symbolName(tid)) |nm| {
                                            if (owned) |o| self.allocator.free(o);
                                            owned = nm;
                                            lt_name = nm;
                                        } else |_| {}
                                    }
                                }
                            }
                        }
                        self.declareLocalVar(alloca_val, ls.name, lt_name, slot_ty);
                        if (owned) |o| self.allocator.free(o);
                    }
                }
            }
        },
        .expr_stmt => |*es| {
            if (self.current_string_builder) |sb| {
                if (es.expr.kind == .jsx_element) {
                    try self.emitJsxInto(sb, es.expr.kind.jsx_element);
                    try self.jsxFlushLiteral(sb);
                    return;
                }
            }
            const val = if (es.expr.kind == .go_expr)
                try self.buildGo(es.expr.kind.go_expr, true)
            else
                try self.compileExpression(es.expr);
            const expr_type = try self.resolveExpressionTypeName(&es.expr);
            if (self.current_string_builder) |sb| {
                const is_assign = (es.expr.kind == .binary and es.expr.kind.binary.op == .assign);
                if (!is_assign) {
                    try self.compileAppendToStringBuilder(sb, val, expr_type, es.expr);
                }
            } else {
                if (expr_type) |et| {

                    if (self.isOwnedExpr(&es.expr)) {
                        const should_release = (es.expr.kind == .call or es.expr.kind == .struct_init);
                        if (should_release) {

                            self.consumeTemporary(val);

                            const etid: ?sema_types.TypeId = if (self.typed_ir) |ir| ir.typeOf(&es.expr) else null;
                            const dest = try self.getOrCreateDestructorPreferId(et, etid);
                            try self.compileRelease(val, dest);
                        }
                    }
                }
            }
        },
        .block => |b| {
            try self.scopes.append(self.allocator, Scope{ .deferred_statements = std.ArrayList(ast.Expression).empty, .owned_locals = .empty });
            for (b.statements) |s| {
                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
                    break;
                }
                try self.compileStatement(s, func);
            }
            var scope = self.scopes.pop().?;
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                var idx = scope.deferred_statements.items.len;
                while (idx > 0) {
                    idx -= 1;
                    _ = try self.compileExpression(scope.deferred_statements.items[idx]);
                }

                var oi = scope.owned_locals.items.len;
                while (oi > 0) {
                    oi -= 1;
                    const ol = scope.owned_locals.items[oi];
                    try self.releaseLocalByName(ol.name, ol.type_name);
                }
            }

            if (self.current_local_types) |lt| {
                for (scope.owned_locals.items) |ol| _ = lt.remove(ol.name);
            }
            scope.owned_locals.deinit(self.allocator);
            scope.deferred_statements.deinit(self.allocator);

            scope.errdeferred_statements.deinit(self.allocator);
        },
        .if_stmt => |is| {
            const cond_val = try self.compileExpression(is.condition);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "ifcond");

            self.drainTemporaries(temp_mark) catch {};

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const then_bb = core.LLVMAppendBasicBlock(current_fn, "then");
            const else_bb = if (is.else_branch != null) core.LLVMAppendBasicBlock(current_fn, "else") else null;
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "ifcont");

            _ = core.LLVMBuildCondBr(self.builder, cond_i1, then_bb, else_bb orelse merge_bb);

            const pnarrow = detectPresenceNarrow(is.condition);

            core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
            const then_narrowed = if (pnarrow) |nw| (nw.then_branch and !self.narrowed_present.contains(nw.name)) else false;
            if (then_narrowed) try self.narrowed_present.put(pnarrow.?.name, {});
            try self.compileStatement(is.then_branch.*, func);
            if (then_narrowed) _ = self.narrowed_present.remove(pnarrow.?.name);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, merge_bb);
            }

            if (is.else_branch) |eb| {
                core.LLVMPositionBuilderAtEnd(self.builder, else_bb.?);
                const else_narrowed = if (pnarrow) |nw| (!nw.then_branch and !self.narrowed_present.contains(nw.name)) else false;
                if (else_narrowed) try self.narrowed_present.put(pnarrow.?.name, {});
                try self.compileStatement(eb.*, func);
                if (else_narrowed) _ = self.narrowed_present.remove(pnarrow.?.name);
                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                }
            }

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        },
        .while_stmt => |ws| {
            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const cond_bb = core.LLVMAppendBasicBlock(current_fn, "while_cond");
            const body_bb = core.LLVMAppendBasicBlock(current_fn, "while_body");
            const exit_bb = core.LLVMAppendBasicBlock(current_fn, "while_exit");

            const prev_break = self.current_break_bb;
            const prev_continue = self.current_continue_bb;
            const prev_loop_depth = self.current_loop_scope_depth;
            self.current_break_bb = exit_bb;
            self.current_continue_bb = cond_bb;

            self.current_loop_scope_depth = self.scopes.items.len;

            _ = core.LLVMBuildBr(self.builder, cond_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
            const cond_val = try self.compileExpression(ws.condition);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "whilecond");
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, body_bb, exit_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            try self.compileStatement(ws.body.*, func);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, cond_bb);
            }

            self.current_break_bb = prev_break;
            self.current_continue_bb = prev_continue;
            self.current_loop_scope_depth = prev_loop_depth;

            core.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
        },
        .break_stmt => {
            if (self.current_break_bb) |exit_bb| {
                try releaseScopesForLoopExit(self);
                _ = core.LLVMBuildBr(self.builder, exit_bb);
            } else {
                return error.BreakOutsideLoop;
            }
        },
        .continue_stmt => {
            if (self.current_continue_bb) |cond_bb| {
                try releaseScopesForLoopExit(self);
                _ = core.LLVMBuildBr(self.builder, cond_bb);
            } else {
                return error.ContinueOutsideLoop;
            }
        },
        .return_stmt => |rs| {
            var ret_val_opt = if (rs.value) |v| try self.compileExpression(v) else null;

            if (rs.value) |*v| {
                if (ret_val_opt) |rv| {
                    if (func.ret_type_ref) |rtr| {
                        const nested_ret = self.valoptTypeRefIsNested(rtr);
                        if (self.valoptTypeRefIsValue(rtr) and
                            !LlvmCompiler.isUndefinedLiteralExpr(v) and
                            (!self.exprYieldsValoptBox(v) or nested_ret))
                        {
                            ret_val_opt = try self.buildValoptBox(self.coerceToSlotType(rv, self.val_type));
                        }
                    }
                }
            }

            var widened_trait_ret = false;
            if (rs.value) |*v| {
                if (ret_val_opt) |rv| {
                    if (self.traits.contains(func.return_type)) {
                        if (try self.resolveExpressionTypeName(v)) |sname| {
                            if (self.structs.contains(sname)) {
                                ret_val_opt = try self.constructTraitObject(rv, sname, func.return_type);
                                widened_trait_ret = true;
                            }
                        }
                    }
                }
            }

            var wrapped_erru = false;
            if (rs.value) |*v| {
                if (ret_val_opt) |rv| {
                    if (self.errUnionParts(func.return_type)) |parts| {
                        defer self.allocator.free(parts.ok);
                        defer self.allocator.free(parts.err);
                        const vt = try self.resolveExpressionTypeName(v);

                        const is_err = if (vt) |x| std.mem.eql(u8, x, parts.err) else false;

                        var ok_rv: types.LLVMValueRef = rv;
                        if (!is_err and LlvmCompiler.valueOptionalName(parts.ok) and
                            !LlvmCompiler.isUndefinedLiteralExpr(v) and !self.exprYieldsValoptBox(v))
                        {
                            ok_rv = try self.buildValoptBox(self.coerceToSlotType(rv, self.val_type));
                        }

                        if (is_err) try self.runErrdefers();
                        ret_val_opt = try self.buildErrUnion(ok_rv, is_err, func.return_type);
                        wrapped_erru = true;
                    }
                }
            }

            if (ret_val_opt) |rv| self.consumeTemporary(rv);
            try self.drainTemporaries(temp_mark);

            if (ret_val_opt) |rv| {
                if (core.LLVMGetTypeKind(core.LLVMTypeOf(rv)) == .LLVMDoubleTypeKind) {
                    ret_val_opt = core.LLVMBuildBitCast(self.builder, rv, self.val_type, "ret_double_to_val");
                }
            }

            if (rs.value) |*v| {
                const is_var = (v.kind == .ident or v.kind == .field_access or v.kind == .index);
                if (wrapped_erru) {

                } else if (widened_trait_ret) {

                } else if (is_var) {

                    if (self.isOwnedExpr(v)) {
                        if (ret_val_opt) |rv| {
                            try self.compileRetain(rv);
                        }
                    }
                }

            }

            var scope_idx = self.scopes.items.len;
            while (scope_idx > 0) {
                scope_idx -= 1;
                const scope = &self.scopes.items[scope_idx];
                var def_idx = scope.deferred_statements.items.len;
                while (def_idx > 0) {
                    def_idx -= 1;
                    _ = try self.compileExpression(scope.deferred_statements.items[def_idx]);
                }
            }

            try self.releaseLocalVariables();

            if (self.current_async_promise) |promise| {

                if (ret_val_opt) |ret_val| {
                    const rslot = self.coroPromiseResultSlot(promise);
                    _ = core.LLVMBuildStore(self.builder, ret_val, rslot);
                }
                _ = core.LLVMBuildBr(self.builder, self.current_async_final_bb.?);
            } else if (std.mem.eql(u8, func.name, "main")) {

                if (ret_val_opt) |ret_val| {
                    _ = core.LLVMBuildRet(self.builder, ret_val);
                } else {
                    _ = core.LLVMBuildRet(self.builder, core.LLVMConstInt(self.val_type, 0, 0));
                }
            } else if (ret_val_opt) |ret_val| {
                _ = core.LLVMBuildRet(self.builder, ret_val);
            } else {
                const is_new = std.mem.endsWith(u8, func.name, "_new");
                if (is_new) {
                    if (self.locals.get("self")) |self_alloca| {
                        const self_val = core.LLVMBuildLoad2(self.builder, self.val_type, self_alloca, "self_val");
                        _ = core.LLVMBuildRet(self.builder, self_val);
                    } else {
                        _ = core.LLVMBuildRetVoid(self.builder);
                    }
                } else {
                    _ = core.LLVMBuildRetVoid(self.builder);
                }
            }
        },
.defer_stmt => |ds| {
            if (self.scopes.items.len > 0) {
                const current_scope = &self.scopes.items[self.scopes.items.len - 1];
                if (ds.is_err) {
                    try current_scope.errdeferred_statements.append(self.allocator, ds.expr);
                } else {
                    try current_scope.deferred_statements.append(self.allocator, ds.expr);
                }
            } else {
                std.debug.print("Error: defer statement outside of active scope\n", .{});
                return error.DeferOutsideScope;
            }
        },
        .switch_stmt => |*ss| {
            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            var discr_val = try self.compileExpression(ss.discriminant);
            const discr_type_name_opt = if (try self.resolveExpressionTypeName(&ss.discriminant)) |dt|
                self.scopedTypeName(dt, ss.span.file)
            else
                null;

            const is_tagged_union = blk: {
                if (discr_type_name_opt) |dt| {
                    if (self.enums.contains(dt)) {
                        const enum_decl = self.enums.get(dt).?;
                        for (enum_decl.variants) |v| {
                            if (v.type_name != null or v.fields != null) {
                                break :blk true;
                            }
                        }
                    }
                }
                break :blk false;
            };

            const union_ptr_val = discr_val;

            if (is_tagged_union) {
                const tag_ptr = core.LLVMBuildIntToPtr(self.builder, discr_val, core.LLVMPointerType(self.val_type, 0), "tag_ptr");
                discr_val = core.LLVMBuildLoad2(self.builder, self.val_type, tag_ptr, "tag_val");
            }

            const default_bb = core.LLVMAppendBasicBlock(current_fn, "switch_default");
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "switch_merge");

            const switch_inst = core.LLVMBuildSwitch(self.builder, discr_val, default_bb, @intCast(ss.cases.len));

            for (ss.cases) |c| {
                const case_bb = core.LLVMAppendBasicBlock(current_fn, "switch_case");
                core.LLVMPositionBuilderAtEnd(self.builder, case_bb);

                var retained_payloads = std.ArrayList(struct { name: []const u8, type_name: []const u8 }).empty;
                defer retained_payloads.deinit(self.allocator);

                if (is_tagged_union) {
                    const enum_decl = self.enums.get(discr_type_name_opt.?).?;
                    const ptr_size = @as(u32, 8);

                    for (c.values) |val_expr| {
                        if (val_expr.kind == .call) {
                            const call = val_expr.kind.call;
                            if (call.callee.kind == .field_access) {
                                const fa = call.callee.kind.field_access;
                                for (enum_decl.variants) |v| {
                                    if (std.mem.eql(u8, v.name, fa.field)) {
                                        if (v.type_name) |t_ref| {
                                            if (call.args.len > 0 and call.args[0].kind == .ident) {
                                                const var_name = call.args[0].kind.ident;
                                                const var_alloca = self.locals.get(var_name) orelse return error.VariableNotFound;
                                                const offset = core.LLVMConstInt(self.val_type, ptr_size, 0);
                                                const addr = core.LLVMBuildAdd(self.builder, union_ptr_val, offset, "payload_addr");
                                                const src_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                                                const loaded_val = core.LLVMBuildLoad2(self.builder, self.val_type, src_ptr, "payload_val");
                                                const t_str = try self.typeRefToString(t_ref);

                                                if (self.isOwnedDeclaredType(t_ref, t_str)) {
                                                    try self.compileRetain(loaded_val);
                                                    try retained_payloads.append(self.allocator, .{ .name = var_name, .type_name = t_str });
                                                }
                                                _ = core.LLVMBuildStore(self.builder, loaded_val, var_alloca);
                                            }
                                        } else if (v.fields) |payload_fields| {
                                            for (call.args, 0..) |arg, idx| {
                                                if (idx >= payload_fields.len or arg.kind != .ident) continue;
                                                const var_name = arg.kind.ident;
                                                const var_alloca = self.locals.get(var_name) orelse return error.VariableNotFound;
                                                const pf = payload_fields[idx];
                                                const offset = core.LLVMConstInt(self.val_type, ptr_size + idx * ptr_size, 0);
                                                const addr = core.LLVMBuildAdd(self.builder, union_ptr_val, offset, "payload_addr");
                                                const src_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                                                const loaded_val = core.LLVMBuildLoad2(self.builder, self.val_type, src_ptr, "payload_val");
                                                const t_str = try self.typeRefToString(pf.type_name);

                                                if (self.isOwnedDeclaredType(pf.type_name, t_str)) {
                                                    try self.compileRetain(loaded_val);
                                                    try retained_payloads.append(self.allocator, .{ .name = var_name, .type_name = t_str });
                                                }
                                                _ = core.LLVMBuildStore(self.builder, loaded_val, var_alloca);
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        } else if (val_expr.kind == .struct_init) {
                            const si = val_expr.kind.struct_init;
                            for (enum_decl.variants) |v| {
                                if (std.mem.eql(u8, v.name, si.type_name)) {
                                    if (v.fields) |payload_fields| {
                                        for (si.fields) |f_init| {
                                            for (payload_fields, 0..) |pf, idx| {
                                                if (std.mem.eql(u8, f_init.name, pf.name)) {
                                                    if (f_init.value.kind == .ident) {
                                                        const var_name = f_init.value.kind.ident;
                                                        const var_alloca = self.locals.get(var_name) orelse return error.VariableNotFound;
                                                        const offset = core.LLVMConstInt(self.val_type, ptr_size + idx * ptr_size, 0);
                                                        const addr = core.LLVMBuildAdd(self.builder, union_ptr_val, offset, "payload_addr");
                                                        const src_ptr = core.LLVMBuildIntToPtr(self.builder, addr, core.LLVMPointerType(self.val_type, 0), "payload_ptr");
                                                        const loaded_val = core.LLVMBuildLoad2(self.builder, self.val_type, src_ptr, "payload_val");
                                                        const t_str = try self.typeRefToString(pf.type_name);

                                                        if (self.isOwnedDeclaredType(pf.type_name, t_str)) {
                                                            try self.compileRetain(loaded_val);
                                                            try retained_payloads.append(self.allocator, .{ .name = var_name, .type_name = t_str });
                                                        }
                                                        _ = core.LLVMBuildStore(self.builder, loaded_val, var_alloca);
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

                if (c.guard) |g| {
                    const gfn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
                    const gval = self.coerceToSlotType(try self.compileExpression(g), self.val_type);
                    const gi1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, gval, core.LLVMConstInt(self.val_type, 0, 0), "case_guard");
                    const guard_body_bb = core.LLVMAppendBasicBlock(gfn, "switch_guard_body");
                    const guard_fail_bb = core.LLVMAppendBasicBlock(gfn, "switch_guard_fail");
                    _ = core.LLVMBuildCondBr(self.builder, gi1, guard_body_bb, guard_fail_bb);
                    core.LLVMPositionBuilderAtEnd(self.builder, guard_fail_bb);
                    for (retained_payloads.items) |rp| try self.releaseLocalByName(rp.name, rp.type_name);
                    _ = core.LLVMBuildBr(self.builder, default_bb);
                    core.LLVMPositionBuilderAtEnd(self.builder, guard_body_bb);
                }

                try self.compileStatement(c.body.*, func);

                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                    for (retained_payloads.items) |rp| {
                        try self.releaseLocalByName(rp.name, rp.type_name);
                    }
                }

                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                }

                for (c.values) |val_expr| {
                    var case_val: u64 = 0;
                    var resolved_enum = false;
                    if (discr_type_name_opt) |dt| {
                        if (self.enums.get(dt)) |enum_decl| {
                            resolved_enum = true;
                            var variant_name: ?[]const u8 = null;
                            switch (val_expr.kind) {
                                .field_access => |fa| variant_name = fa.field,
                                .call => |call| {
                                    if (call.callee.kind == .field_access) {
                                        variant_name = call.callee.kind.field_access.field;
                                    }
                                },
                                .struct_init => |si| variant_name = si.type_name,
                                else => {},
                            }
                            if (variant_name) |vn| {
                                for (enum_decl.variants, 0..) |v, idx| {
                                    if (std.mem.eql(u8, v.name, vn)) {
                                        const val = v.value orelse @as(i64, @intCast(idx));
                                        case_val = @bitCast(val);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (!resolved_enum) {
                        var neg = false;
                        var lit = val_expr.kind;
                        if (val_expr.kind == .unary and val_expr.kind.unary.op == .neg) {
                            neg = true;
                            lit = val_expr.kind.unary.operand.*.kind;
                        }
                        if (lit == .literal and lit.literal == .integer) {
                            const iv: i64 = @intCast(lit.literal.integer);
                            case_val = @bitCast(if (neg) -iv else iv);
                        }
                    }

                    core.LLVMAddCase(switch_inst, core.LLVMConstInt(self.val_type, case_val, 0), case_bb);
                }
            }

            core.LLVMPositionBuilderAtEnd(self.builder, default_bb);
            if (ss.default_case) |dc| {
                try self.compileStatement(dc.*, func);
            }
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, merge_bb);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        },
        .for_stmt => |fs| {

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const cond_bb = core.LLVMAppendBasicBlock(current_fn, "for_cond");
            const body_bb = core.LLVMAppendBasicBlock(current_fn, "for_body");
            const incr_bb = core.LLVMAppendBasicBlock(current_fn, "for_incr");
            const exit_bb = core.LLVMAppendBasicBlock(current_fn, "for_exit");

            var loop_var: ?types.LLVMValueRef = null;
            var range_end: types.LLVMValueRef = undefined;
            var range_inclusive = false;
            if (fs.iterator) |it| {

                if (it.iterable.kind != .range) {
                    std.debug.print("for-in over a non-range iterable is not implemented yet (only `for (i in a..b)`)\n", .{});
                    return error.UnsupportedStatement;
                }
                const name = switch (it.binding) {
                    .item => |n| n,
                    .destructure => {
                        std.debug.print("destructuring for-in bindings are not implemented yet\n", .{});
                        return error.UnsupportedStatement;
                    },
                };
                const r = it.iterable.kind.range;
                const start_v = try self.compileExpression(r.start.*);
                range_end = try self.compileExpression(r.end.*);
                range_inclusive = r.inclusive;
                const name_z = try self.allocator.dupeZ(u8, name);
                const a = core.LLVMBuildAlloca(self.builder, self.val_type, name_z.ptr);
                _ = core.LLVMBuildStore(self.builder, start_v, a);
                try self.locals.put(try self.allocator.dupe(u8, name), a);
                if (self.current_local_types) |lt| try lt.put(try self.allocator.dupe(u8, name), "int");
                loop_var = a;
            } else if (fs.initializer) |i| {
                try self.compileStatement(i.*, func);
            }

            const prev_break = self.current_break_bb;
            const prev_continue = self.current_continue_bb;
            const prev_loop_depth = self.current_loop_scope_depth;
            self.current_break_bb = exit_bb;
            self.current_continue_bb = incr_bb;
            self.current_loop_scope_depth = self.scopes.items.len;

            _ = core.LLVMBuildBr(self.builder, cond_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
            const cond_i1 = blk: {
                if (loop_var) |a| {
                    const cur = core.LLVMBuildLoad2(self.builder, self.val_type, a, "for_i");
                    const pred = if (range_inclusive) types.LLVMIntPredicate.LLVMIntSLE else types.LLVMIntPredicate.LLVMIntSLT;
                    break :blk core.LLVMBuildICmp(self.builder, pred, cur, range_end, "for_cmp");
                } else if (fs.condition) |c| {
                    const cv = try self.compileExpression(c);
                    break :blk core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cv, core.LLVMConstInt(self.val_type, 0, 0), "for_cmp");
                } else {
                    break :blk core.LLVMConstInt(core.LLVMInt1Type(), 1, 0);
                }
            };
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, body_bb, exit_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            try self.compileStatement(fs.body.*, func);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, incr_bb);
            }

            core.LLVMPositionBuilderAtEnd(self.builder, incr_bb);
            if (loop_var) |a| {
                const cur = core.LLVMBuildLoad2(self.builder, self.val_type, a, "for_i2");
                const next = core.LLVMBuildAdd(self.builder, cur, core.LLVMConstInt(self.val_type, 1, 0), "for_next");
                _ = core.LLVMBuildStore(self.builder, next, a);
            } else if (fs.increment) |inc| {
                _ = try self.compileExpression(inc);
            }
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, cond_bb);
            }

            self.current_break_bb = prev_break;
            self.current_continue_bb = prev_continue;
            self.current_loop_scope_depth = prev_loop_depth;

            core.LLVMPositionBuilderAtEnd(self.builder, exit_bb);
        },
    }
}
