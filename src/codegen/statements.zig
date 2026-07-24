const std = @import("std");
const ast = @import("../ast.zig");
const llvm = @import("llvm");
const types = llvm.types;
const core = llvm.core;
const sema_types = @import("../types.zig");

const LlvmCompiler = @import("llvm_codegen.zig").LlvmCompiler;
const FunctionInfo = @import("llvm_codegen.zig").FunctionInfo;
const Scope = @import("llvm_codegen.zig").Scope;

/// F5 O4 "scope exit | release every owned local" — for the exits that JUMP.
///
/// A `.block` releases its owned locals only `if (terminator == null)`, so a block
/// ending in `break`/`continue` released NOTHING. `return` was already handled
/// (`.return_stmt` → `releaseLocalVariables`); these two were not, and the omission is
/// silent: it leaks rather than crashes.
///
/// Measured on the JSON parser, which is written as `while (true) { ...; break; }`:
/// the LAST iteration's locals always leaked, so `{"a":1}` and `{"a":1,"b":2}` leaked
/// the SAME 9 objects — only the final iteration breaks. `{}` and `[]` return before
/// the loop and were clean, which is what localised it.
///
/// Releases every scope from the innermost out to the loop BODY's own (inclusive).
/// It does not pop them: the `.block` handler still does that, and still skips its own
/// release because the terminator is now there — so nothing is released twice.
/// E1 `errdefer`: run every registered errdefer expression across the CURRENTLY-ACTIVE scope
/// stack, LIFO (innermost scope first, reverse within each). Called at each error-path return —
/// an explicit error-side return (`return SomeError`) and a `try` that propagates — BEFORE the
/// function drains its locals, so an `errdefer conn.close()` can still see `conn`.
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
        // Reverse order, like the normal scope exit: a later local may hold a
        // reference it got from an earlier one.
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
    // F5 §3.4b: an owned temporary dies at the end of the FULL statement. Everything
    // this statement produces and nobody names is released below.
    //
    // A MARK, not a clear: statements nest — a `while` body's statements compile
    // inside the `while` statement — so releasing everything would free an enclosing
    // statement's temporaries early. That is a use-after-free where the bug being
    // fixed is only a leak.
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
            // F5 O4: a ref-counted local declared inside a BLOCK is that block's to
            // release. Registered here; released at the block's exit below, and
            // removed from the function-level map so it is not released twice.
            if (self.scopes.items.len > 0) {
                if (self.current_local_types) |lt| {
                    if (ls.names) |names| {
                        // Destructured bindings are block-owned too. This was gated on
                        // `ls.names == null` and so skipped them entirely — which is invisible at
                        // function scope (releaseLocalVariables catches the alloca's LAST value at
                        // function exit) and a linear leak inside a LOOP: 20 iterations of
                        // `let (k, v) = splitOnColon(..)` released only the final pair and leaked
                        // the other 19, because each iteration overwrites the same alloca.
                        // Measured exactly that: `x19 "A"`, `x19 "B"` survivors in
                        // 28_tuple_return_heap. (2026-07-17)
                        for (names) |n| {
                            if (lt.get(n)) |vt| {
                                // F5-2: decide via the store (`isOwnedLocal`) when this name is in the
                                // parallel TypeId map; `vt` is still kept for the destructor lookup.
                                if (self.isOwnedLocal(n, vt)) {
                                    const sc = &self.scopes.items[self.scopes.items.len - 1];
                                    try sc.owned_locals.append(self.allocator, .{ .name = n, .type_name = vt });
                                }
                            }
                        }
                    } else if (lt.get(ls.name)) |vt| {
                        if (self.isOwnedLocal(ls.name, vt)) {
                            const sc = &self.scopes.items[self.scopes.items.len - 1];
                            try sc.owned_locals.append(self.allocator, .{ .name = ls.name, .type_name = vt });
                        }
                    }
                }
            }
            if (ls.init) |*init_ptr| {
                const init = init_ptr.*;
                var val = try self.compileExpression(init);
                // F5 O4 "let x = e | e produces OWNED -> move (no retain)". The local
                // is now the owner, so the statement's drain must not also release it.
                //
                // ⚠️ That rule holds only for a SINGLE binding. Under destructuring
                // (`let (k, v) = f()`) the local owns an ELEMENT, not the box — no local
                // owns the box, so consuming it here meant nothing ever released it and
                // every tuple leaked its box. Leave it registered: the statement's drain
                // releases it through `__destruct_tuple_*`, which releases the elements the
                // box retained at construction; the destructured locals took their own
                // retain below and release at scope exit. Both halves balance.
                if (ls.names == null) self.consumeTemporary(val);
                if (ls.names) |names| {
                    // Tuple destructuring
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
                        // The declared trait may be non-generic (`.ident`, e.g. `Connection`) or a
                        // generic trait object (`.generic`, e.g. `Box<int>`); widen to its BASE name.
                        const trait_decl_name: ?[]const u8 = switch (t) {
                            .ident => |n| n,
                            .generic => |g| g.name,
                            else => null,
                        };
                        if (trait_decl_name) |expected_type| {
                            if (self.traits.contains(expected_type)) {
                                if (try self.resolveExpressionTypeName(init_ptr)) |struct_name| {
                                    if (self.structs.contains(struct_name)) {
                                        const orig_struct = val;
                                        val = try self.constructTraitObject(orig_struct, struct_name, expected_type);
                                        // The coercion happens AFTER the consume above,
                                        // and it makes a NEW temporary (the fat
                                        // pointer). `x` is that one's owner, so it must
                                        // be consumed too — otherwise the drain frees
                                        // the object the variable holds.
                                        self.consumeTemporary(val);
                                        widened_to_trait = true;
                                        // The STRUCT's construction ref is orphaned ONLY when the
                                        // RHS was a FRESH owned temporary (`let s: Speaker = Cat()`):
                                        // the binding now owns the fat pointer, not the struct, so
                                        // that stray +1 must be released or the struct leaks at rc=1.
                                        // But when the RHS is a BORROW of an existing owner
                                        // (`let c: Compute = a`, a named local), the struct's
                                        // construction ref belongs to THAT owner (`a`), which releases
                                        // it at scope exit — releasing it here as well under-counts
                                        // and double-frees the struct (rc→0 early, then `a` and
                                        // __destruct_trait each release again). Observed only under
                                        // full scope cleanup (the @test harness); `main` exits before
                                        // running it. constructTraitObject already gave the trait its
                                        // own +1 either way, so the borrow case needs NO release here.
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
                    if (target_type) |tt| {
                        // `val` here is a FRESH fat pointer (constructTraitObject +1, just
                        // consumed into this binding), NOT a borrow of the r-value `c` — so the
                        // co-own retain below would over-retain it to rc=2 and leak the 16-byte
                        // fat pointer at scope exit (`let t: Conn = c`, one object). The widen
                        // already gave the binding its +1.
                        if (!widened_to_trait and self.isOwnedLocal(ls.name, tt)) {
                            // A `V.Null` payload-less enum-variant construction PARSES as `.field_access`
                            // (object = enum name, field = variant), but it is a FRESH owned box (+1), not a
                            // borrow of an existing r-var. The co-own retain below would over-retain it and
                            // leak the 16-byte box at scope exit — the same trait-widen hazard noted above.
                            // (`let y = V.Null` leaked 1; measured via the yaml enum comparisons.)
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

                    // A7 / F3 §5 stage 4: coerce to the slot's honest type — a float
                    // local is `alloca double`, so an i64-ABI value (e.g. a call result)
                    // is reinterpreted to double here; a `double` value stores directly.
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
                    // F5-2: the ownership gate goes through the store (`es.expr` is in hand);
                    // `et` is still kept below as the destructor's `.type_name`.
                    if (self.isOwnedExpr(&es.expr)) {
                        const should_release = (es.expr.kind == .call or es.expr.kind == .struct_init);
                        if (should_release) {
                            // This IS the temporary rule, hand-written for the one case
                            // where the statement is nothing but the call. §3.4b's rule
                            // generalises it — so take the value off the pending list
                            // and keep releasing it HERE, exactly once.
                            //
                            // Without this, the drain releases it a second time. That
                            // double free is not a crash you can trust to show up:
                            // 13_serde passed 3 of 8 runs, and passed every run before
                            // the rule existed. An intermittent failure means the model
                            // is wrong somewhere else — this was the somewhere else.
                            self.consumeTemporary(val);
                            // Stage 5 Phase B: store-native dtor via the same-symbol gate (es.expr in hand).
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
                // F5 O4 — "scope exit | release every owned local". Reverse order:
                // a later local may hold a reference obtained from an earlier one.
                //
                // AFTER the deferred statements, which may still read these.
                var oi = scope.owned_locals.items.len;
                while (oi > 0) {
                    oi -= 1;
                    const ol = scope.owned_locals.items[oi];
                    try self.releaseLocalByName(ol.name, ol.type_name);
                }
            }
            // Remove from the function-level map WHATEVER the terminator did: if the
            // block ended in a `return`, that path already released them
            // (statements.zig `.return_stmt` calls releaseLocalVariables), and if it
            // fell through, the loop above did. Leaving them would emit a SECOND
            // release at function exit — a double-free, not a leak.
            if (self.current_local_types) |lt| {
                for (scope.owned_locals.items) |ol| _ = lt.remove(ol.name);
            }
            scope.owned_locals.deinit(self.allocator);
            scope.deferred_statements.deinit(self.allocator);
            // errdefers are DISCARDED on a normal scope exit (they only fire on an error return
            // while the scope is live). runErrdefers iterates the still-active scope stack.
            scope.errdeferred_statements.deinit(self.allocator);
        },
        .if_stmt => |is| {
            const cond_val = try self.compileExpression(is.condition);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "ifcond");
            // Drain the CONDITION's temporaries HERE, before the branches. If a branch early-returns,
            // the statement's deferred drain is emitted at merge_bb (unreachable), so a condition temp
            // like `string.toLowerCase(key)` in `if (toLowerCase(key)==x) { return ... }` would leak
            // (29_http). Safe: the comparison above already consumed the condition value; `let`-bound
            // names are released by releaseLocalVariables, not here.
            self.drainTemporaries(temp_mark) catch {};

            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const then_bb = core.LLVMAppendBasicBlock(current_fn, "then");
            const else_bb = if (is.else_branch != null) core.LLVMAppendBasicBlock(current_fn, "else") else null;
            const merge_bb = core.LLVMAppendBasicBlock(current_fn, "ifcont");

            _ = core.LLVMBuildCondBr(self.builder, cond_i1, then_bb, else_bb orelse merge_bb);

            // Compile then branch
            core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
            try self.compileStatement(is.then_branch.*, func);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, merge_bb);
            }

            // Compile else branch
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
            // F5 O4: everything the BODY pushes from here on is a scope that a `break`
            // or `continue` jumps out of, and must release on the way. Recorded before
            // the body is compiled, because the body's own block scope is the first one.
            self.current_loop_scope_depth = self.scopes.items.len;

            _ = core.LLVMBuildBr(self.builder, cond_bb);

            // Compile cond block
            core.LLVMPositionBuilderAtEnd(self.builder, cond_bb);
            const cond_val = try self.compileExpression(ws.condition);
            const cond_i1 = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntNE, cond_val, core.LLVMConstInt(self.val_type, 0, 0), "whilecond");
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, body_bb, exit_bb);

            // Compile body block
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

            // Coerce a concrete struct to a trait object when the function's declared
            // return type is a trait (`fn make(): Speaker { return Dog(); }`).
            //
            // §3.4h: this MUST run BEFORE the consume/drain below. `constructTraitObject`
            // makes a NEW temporary (the fat pointer) that CO-OWNS the struct via a
            // retain — so the returned value is the fat pointer, and the INNER struct
            // temp must be drained here (releasing its construction ref), leaving the
            // struct held solely by the fat pointer's retain. Coercing AFTER the drain
            // instead consumed the struct temp and then wrapped it, orphaning one ref:
            // the struct ended at rc 2 with only the fat pointer as owner, and
            // `__destruct_trait` releasing once left rc 1 — the whole getChild/itemChild
            // subtree leak (13_serde).
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

            // specs §3.4b — `fn f(): T | E`. WRAP the returned value in the error-union box.
            //
            // Both `return "x"` and `return DiError.NotRegistered(k)` are legal in the same
            // function, so which side this is must be decided HERE, from the value's own type:
            //   tag 0 = ok  (payload is the T)
            //   tag 1 = err (payload is the E — an enum box)
            // Unlike `optional`, which is a 0 SENTINEL, the error side is a real value, so the
            // discriminant has to be real too. Boxing (rather than a two-register return) keeps
            // every value one i64 wide, which is what the rest of codegen assumes; §3.4b records
            // the zero-alloc version as the optimisation.
            // Whether the return value was WRAPPED into an error-union box below. If so, the
            // is_var/nullish retain further down MUST NOT fire (F5, task #14): `buildErrUnion` already
            // retained the owned PAYLOAD to survive the callee's `releaseLocalVariables`, and
            // `ret_val_opt` is now the freshly-built BOX (rc 1) that transfers to the caller unretained.
            // Retaining the box there was a band-aid that padded its rc so the caller's single drain
            // left it at 1 — a LEAK — instead of letting `__destruct_ErrUnion` run. That leak was
            // masking a real double-free of the payload (a `try f()` on an owned payload registered the
            // payload as a temp TWICE; see expressions.zig `.try_expr`). With that double-registration
            // fixed, the box owns-then-frees its payload correctly, and this retain must be gone.
            var wrapped_erru = false;
            if (rs.value) |*v| {
                if (ret_val_opt) |rv| {
                    if (self.errUnionParts(func.return_type)) |parts| {
                        defer self.allocator.free(parts.ok);
                        defer self.allocator.free(parts.err);
                        const vt = try self.resolveExpressionTypeName(v);
                        // The value is the ERROR side only if its type is exactly the declared error
                        // type. Anything else is the ok side — including `undefined`.
                        const is_err = if (vt) |x| std.mem.eql(u8, x, parts.err) else false;
                        // E1: an error-side return fires the active errdefers (before locals drain).
                        if (is_err) try self.runErrdefers();
                        ret_val_opt = try self.buildErrUnion(rv, is_err, func.return_type);
                        wrapped_erru = true;
                    }
                }
            }

            // (The tuple return-boundary retain that used to live here is GONE.)
            //
            // It existed because a tuple box stored each element's word RAW and owned nothing, so
            // a returned box escaped pointing at elements the callee had already freed. It bought
            // correctness at the price of "a bounded per-element leak" — and the leak was not
            // bounded in any useful sense: it was one ref per element per CALL, unbalanced by
            // anything, and it was ~108 of the ~118 above-floor live objects in the whole corpus.
            //
            // Worse, the guard was SYNTACTIC — `v.kind == .tuple` — so it only fired for a tuple
            // LITERAL in return position. `let t = (key, val); return t;` is `.ident`, got no
            // retain, and was a genuine use-after-free (conformance 28's own splitOnColon, with
            // one extra binding, returned garbage).
            //
            // The box now RETAINS its elements at construction (expressions.zig) and RELEASES them
            // in `__destruct_tuple_*` (arc.zig). Ownership is a property of the box, not of the
            // syntax at one use site, so every path — `return t`, a tuple in a struct field, a
            // tuple captured by a closure — is correct for the same reason.

            // F5 §3.4b: the RETURNED value transfers to the caller, so it must not be
            // released here. Everything else this statement produced still must be —
            // and `drainTemporaries` bails once the block has a terminator, so it has to
            // run HERE, before the `ret`. `return JsonSource(json.parse(body))` otherwise
            // leaked the parsed tree; the inner struct temp of a trait coercion leaks the
            // same way if the coercion above did not run first.
            if (ret_val_opt) |rv| self.consumeTemporary(rv);
            try self.drainTemporaries(temp_mark);

            // A7 / F3 §5 stage 4: the return ABI is uniformly i64 (val_type). A float
            // expression now yields a real `double`; reinterpret it to the i64 word at
            // this boundary. Refcounted/struct/pointer returns are already i64.
            if (ret_val_opt) |rv| {
                if (core.LLVMGetTypeKind(core.LLVMTypeOf(rv)) == .LLVMDoubleTypeKind) {
                    ret_val_opt = core.LLVMBuildBitCast(self.builder, rv, self.val_type, "ret_double_to_val");
                }
            }

            if (rs.value) |*v| {
                const is_var = (v.kind == .ident or v.kind == .field_access or v.kind == .index);
                if (wrapped_erru) {
                    // Wrapped into an error-union box above: buildErrUnion already balanced the owned
                    // payload against the scope-exit local release, and the box transfers unretained.
                    // No retain here (see the wrapped_erru comment) — else the box leaks at rc 1.
                } else if (widened_trait_ret) {
                    // `return c` widened to a trait: `ret_val_opt` is the FRESH fat pointer (rc 1),
                    // not the variable `c`. constructTraitObject already retained the wrapped struct
                    // to co-own it (balanced by releaseLocalVariables' release of the `c` local), and
                    // the fat pointer transfers to the caller unretained. Retaining here (because `c`
                    // is an .ident) over-retains the fat pointer to rc 2 — the caller's single drain
                    // leaves it at 1 and the whole wrapped-struct graph leaks (Driver.connect()).
                } else if (is_var) {
                    // F5 stage 2: the ownership decision goes through the TYPED store for a concrete
                    // return (isOwnedExpr), not the renderer — so a rendering bug can't misjudge a
                    // concrete return's retain. Generic returns fall back to the string path inside
                    // isOwnedExpr. Behavior-preserving (isOwned agrees with the string path on
                    // concrete types); was `resolveExpressionTypeName(v)` + `isRefCountedType`.
                    if (self.isOwnedExpr(v)) {
                        if (ret_val_opt) |rv| {
                            try self.compileRetain(rv);
                        }
                    }
                }
                // `return x ?? default`: NO retain-on-return here anymore. The `??` operator now
                // applies PER-EDGE ownership (expressions.zig `.nullish_coalesce`) so the phi it
                // yields is uniformly owned — a borrowed `x` is retained AT the operator. Retaining
                // again here would double it (the +286 serde-binder leak through `json.get`'s
                // `return r ?? JsonValue(0)`). The per-edge retain balances `releaseLocalVariables`
                // exactly, in both return and non-return position (the latter fixes the
                // `let h = m.get(); (h ?? d)` double-free that this return-only special case missed).
            }

            // Execute all deferred statements in LIFO order (innermost to outermost scope)
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

            // Disable restoring captured globals to allow async/concurrent closures to survive
            // var iter = self.current_saved_captures.iterator();
            // while (iter.next()) |entry| {
            //     const global_key = entry.key_ptr.*;
            //     const backup_slot = entry.value_ptr.*;
            //     const global_var = self.captured_globals.get(global_key).?;
            //     const saved_val = core.LLVMBuildLoad2(self.builder, self.val_type, backup_slot, "backup_restore_load");
            //     _ = core.LLVMBuildStore(self.builder, saved_val, global_var);
            // }

            // Release local variables
            try self.releaseLocalVariables();

            if (self.current_async_promise) |promise| {
                // M3-C: inside an async fn, `return e` stashes e in the coroutine
                // promise's result field and branches to the final suspend instead
                // of emitting ret.
                if (ret_val_opt) |ret_val| {
                    const rslot = self.coroPromiseResultSlot(promise);
                    _ = core.LLVMBuildStore(self.builder, ret_val, rslot);
                }
                _ = core.LLVMBuildBr(self.builder, self.current_async_final_bb.?);
            } else if (std.mem.eql(u8, func.name, "main")) {
                // Program entry is emitted as `i64 __nova_main()`; `return <value>`
                // propagates as the process exit code (0 when main returns nothing).
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
            const discr_type_name_opt = try self.resolveExpressionTypeName(&ss.discriminant);

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

                // The owned payloads this case RETAINED into destructure bindings — released at the
                // end of the case body so the +1 balances per-ITERATION. Without this, the binding's
                // alloca is a function-level local released only ONCE at function exit, so in a loop
                // every iteration but the last leaks its retained payload (measured: a recursive yaml
                // stringify over a map with a container value leaked the container subtree).
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
                                                // F5-2: declared enum-payload type lowered to a TypeId; `t_str` is the fallback.
                                                if (self.isOwnedDeclaredType(t_ref, t_str)) {
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
                                                        // F5-2: declared payload-field type lowered to a TypeId; `t_str` is the fallback.
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

                try self.compileStatement(c.body.*, func);

                // Balance the destructure retain(s) at case-body exit (only if the body falls through —
                // a `return` inside the case already ran the function drain). `releaseLocalByName` nulls
                // the alloca, so the function-exit drain of this same binding is then a safe no-op.
                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                    for (retained_payloads.items) |rp| {
                        try self.releaseLocalByName(rp.name, rp.type_name);
                    }
                }

                if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                    _ = core.LLVMBuildBr(self.builder, merge_bb);
                }

                for (c.values) |val_expr| {
                    var case_val: u32 = 0;
                    if (discr_type_name_opt) |dt| {
                        if (self.enums.get(dt)) |enum_decl| {
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
                                        case_val = @intCast(val);
                                        break;
                                    }
                                }
                            }
                        }
                    } else {
                        if (val_expr.kind == .literal and val_expr.kind.literal == .integer) {
                            case_val = @intCast(val_expr.kind.literal.integer);
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
            // Both forms share one block layout: cond → body → INCR → cond, exit on cond-false. The
            // increment lives in its OWN block that `continue` jumps to (not `cond`), so a C-style
            // `for (…;…;i++)` and a range `for (i in a..b)` both run their step on `continue` — the one
            // thing a plain `while`-desugar gets wrong.
            const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
            const cond_bb = core.LLVMAppendBasicBlock(current_fn, "for_cond");
            const body_bb = core.LLVMAppendBasicBlock(current_fn, "for_body");
            const incr_bb = core.LLVMAppendBasicBlock(current_fn, "for_incr");
            const exit_bb = core.LLVMAppendBasicBlock(current_fn, "for_exit");

            // ── init ──────────────────────────────────────────────────────────────────────
            var loop_var: ?types.LLVMValueRef = null; // the range loop-variable's alloca (null for C-style)
            var range_end: types.LLVMValueRef = undefined;
            var range_inclusive = false;
            if (fs.iterator) |it| {
                // for-in. Only ranges codegen today; a collection iterable is a follow-up.
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
            self.current_continue_bb = incr_bb; // `continue` runs the increment, then re-tests cond
            self.current_loop_scope_depth = self.scopes.items.len;

            _ = core.LLVMBuildBr(self.builder, cond_bb);

            // ── cond ──────────────────────────────────────────────────────────────────────
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
                    break :blk core.LLVMConstInt(core.LLVMInt1Type(), 1, 0); // no condition = infinite
                }
            };
            _ = core.LLVMBuildCondBr(self.builder, cond_i1, body_bb, exit_bb);

            // ── body ──────────────────────────────────────────────────────────────────────
            core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            try self.compileStatement(fs.body.*, func);
            if (core.LLVMGetBasicBlockTerminator(core.LLVMGetInsertBlock(self.builder)) == null) {
                _ = core.LLVMBuildBr(self.builder, incr_bb);
            }

            // ── incr (the `continue` target) ────────────────────────────────────────────────
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
