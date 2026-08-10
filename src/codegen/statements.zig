const std = @import("std");
const ast = @import("../ast.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;
const sema_types = @import("../types.zig");

const getStructBaseName = @import("types.zig").getStructBaseName;
const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
const Scope = @import("llvm_codegen.zig").Scope;

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

pub fn compileStatement(self: *LlvmCompiler, stmt: ast.Statement, func: FunctionInfo) anyerror!void {
    if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) != null) {
        return;
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
                                // A value struct with owned fields also needs a scope-end drop (to
                                // release those fields via dropValueStruct, not nova_release).
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
                                    // Check the BASE name so a generic instantiation (`Cell<int>`) widens too --
                                    // `structs` is keyed by base name, so `contains("Cell<int>")` is false and
                                    // the widening would be skipped, storing the raw struct pointer where a
                                    // trait fat-pointer is expected (B5 SEGV on the first vtable dispatch).
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
                    // Widen a value into an owning `any` local: box it into a `{payload, dtor}` carrier so the
                    // local owns a real refcounted box. Skip the generic owned-retain below -- coerceToAny has
                    // already balanced the payload's refcount.
                    var widened_to_any = false;
                    if (target_type) |tt| {
                        if (!widened_to_trait and std.mem.eql(u8, tt, "any")) {
                            const src = (try self.resolveExpressionTypeName(init_ptr)) orelse "";
                            if (!std.mem.eql(u8, src, "any")) {
                                val = try self.coerceToAny(val, init_ptr);
                                // The local takes ownership of the box; drop the temp registration so it is
                                // not double-released at statement end (the local's own drop releases it).
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
                                try self.compileRetain(val);
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

                    // M-1 copy-on-assign: `let b = a` where `a` is a value struct must copy `a`'s
                    // bytes into `b`'s own storage, not alias it. Only the plain-variable RHS needs
                    // this; a fresh `Point(...)` construction already yields distinct storage. (Value
                    // structs live only as locals — field/return/container uses are escape-excluded.)
                    // Copy when the RHS is a BORROW of a value struct (a variable, field, index, or a
                    // container get like list.at(i)) so the local is independent of the source buffer.
                    // A fresh `Point(...)` construction already yields its own storage (not a borrow).
                    if (target_type) |tt| {
                        if (self.isValueStructName(tt) and self.returnIsBorrow(&init)) {
                            const vsz = self.getTypeSize(ast.TypeRef{ .ident = getStructBaseName(tt) }, false);
                            val = try self.buildValueStructCopy(val, vsz);
                            // Owned (reference) fields are now aliased by source + copy; retain them
                            // in the copy so its own scope-end drop is balanced (uniform copy semantics).
                            try self.retainValueStructOwnedFields(val, tt);
                        }
                    }

                    const slot_ty = if (core.LLVMIsAAllocaInst(alloca_val) != null)
                        core.LLVMGetAllocatedType(alloca_val)
                    else
                        self.val_type;
                    _ = core.LLVMBuildStore(self.builder, self.coerceToSlotType(val, slot_ty), alloca_val);
                }
            }
        },
        .expr_stmt => |*es| {
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

            core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
            try self.compileStatement(is.then_branch.*, func);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, merge_bb);
            }

            if (is.else_branch) |eb| {
                core.LLVMPositionBuilderAtEnd(self.builder, else_bb.?);
                try self.compileStatement(eb.*, func);
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
                        // NESTED value-optional return (`(int | undefined) | undefined`, e.g.
                        // `Map<K, int | undefined>.get()` returning `self.vals.get(idx)`): the returned
                        // expression ALREADY yields the inner value-optional box, which normally suppresses
                        // re-boxing. But here the KEY WAS FOUND, so the OUTER level must be materialised as a
                        // present box wrapping the inner (box or 0) -- otherwise present-holding-undefined
                        // (inner 0) is indistinguishable from absent (the `return undefined` arm, which yields
                        // 0 and is correctly NOT boxed by the isUndefinedLiteralExpr guard). The outer box
                        // BORROWS the inner; see valoptTypeRefIsValue's nested comment for the ARC ledger.
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

                        // `T | E | undefined` reads as `(T | undefined) | E`, so the OK arm is a value-optional
                        // box. A plain `return 42` yields a RAW int, which every consumer (`catch`, `try`, `??`)
                        // then treats as a boxed value-optional and ARC-releases as a pointer -> SEGV (F1). Box
                        // the ok value first, unless it is `undefined` (0 is the undefined box) or already a
                        // value-optional box.
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
            // Resolve a colliding enum discriminant to the module-scoped enum this switch's file declares,
            // so variant tags and case-label lowering use the correct variant set (S3).
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
                                            // Tuple-form multi-payload pattern `Rect(w, h)`: load each payload
                                            // field (at slot `ptr_size + idx*ptr_size`) into its positional binding.
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

                // A case guard (`case v if cond:`) is evaluated after the payload bindings it may reference.
                // If it is false, release any retained payloads and fall through to `default`.
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
                    // Non-enum discriminant (int/long/short/byte/...): evaluate the integer literal case
                    // label, supporting a negative label via unary `-`. Previously the tag was only
                    // computed when the discriminant type was unknown (null), so a known integer type
                    // fell through with every case label left at 0 -> duplicate switch cases / wrong branch.
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
