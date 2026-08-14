
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const subst = @import("subst.zig");
const infer = @import("infer.zig");

const TypeStore = types.TypeStore;
const TypeId = types.TypeId;
const TypedIr = infer.TypedIr;
const SymbolTable = symbols.SymbolTable;

pub fn run(
    allocator: std.mem.Allocator,
    store: *TypeStore,
    tab: *const SymbolTable,
    ir: *TypedIr,
    insts: []const TypeId,
) void {
    for (insts) |inst| {
        const info = store.get(inst);
        if (info != .struct_) continue;
        const st = info.struct_;
        if (st.args.len == 0) continue;

        for (st.args, 0..) |arg, i| {
            const tp = store.intern(.{ .type_param = .{ .owner = st.decl, .index = @intCast(i) } }) catch continue;
            ir.recordTpResolve(allocator, tp, inst, arg) catch {};
        }

        const sym = tab.symbolAt(st.decl);
        if (sym.decl != .struct_) continue;
        const sd = sym.decl.struct_;
        const ctx = Ctx{ .allocator = allocator, .store = store, .ir = ir, .decl = st.decl, .args = st.args, .inst = inst };
        for (sd.methods) |m| {
            for (m.decl.body.statements) |*s| ctx.stmt(s);
        }
    }
}

// String-engine-removal (free-fn overlay): give free generic FUNCTION instantiations the same TypeId
// overlay struct methods already get. For each recorded free-fn instance (mono.free_fn_insts) with a
// concrete inst_key, record tp_resolve[{fn-type-param, inst_key}] and walk the fn body recording
// expr_types_inst + owned_inst via subst.substitute. This makes typeOfExprConcrete and isOwnedTypeId total
// inside free-generic-fn bodies (current_instantiation_id = inst_key), so decisions there no longer need the
// string engine. Directly-discovered instances only; the transitive path (noteFreeFnInstStr) has no
// inst_key yet (B1).
pub fn runFreeFns(
    allocator: std.mem.Allocator,
    store: *TypeStore,
    ir: *TypedIr,
    program: ast.Program,
) void {
    const mono = @import("mono.zig");
    for (mono.free_fn_insts.items) |fi| {
        recordFreeFnInst(allocator, store, ir, program, fi.fn_name, fi.owner, fi.args_tids, fi.inst_key);
    }
}

// Record the TypeId overlay (tp_resolve + expr_types_inst/owned_inst) for ONE free-fn instance. Callable
// both from sema (runFreeFns, direct instances) and from codegen's transitive fixpoint as new TypeId-native
// instances are discovered (B1). No-op unless owner/args/key are all present.
pub fn recordFreeFnInst(
    allocator: std.mem.Allocator,
    store: *TypeStore,
    ir: *TypedIr,
    program: ast.Program,
    fn_name: []const u8,
    owner_opt: ?types.SymbolId,
    args_opt: ?[]const TypeId,
    key_opt: ?TypeId,
) void {
    const owner = owner_opt orelse return;
    const args = args_opt orelse return;
    const key = key_opt orelse return;
    for (args, 0..) |arg, i| {
        const tp = store.intern(.{ .type_param = .{ .owner = owner, .index = @intCast(i) } }) catch continue;
        ir.recordTpResolve(allocator, tp, key, arg) catch {};
    }
    const fd = findFreeFn(program, fn_name) orelse return;
    const ctx = Ctx{ .allocator = allocator, .store = store, .ir = ir, .decl = owner, .args = args, .inst = key };
    for (fd.body.statements) |*s| ctx.stmt(s);
}

fn findFreeFn(program: ast.Program, name: []const u8) ?*const ast.FunctionDecl {
    for (program.declarations) |*d| {
        if (d.* == .fn_decl and std.mem.eql(u8, d.fn_decl.name, name) and d.fn_decl.type_params.len > 0) {
            return &d.fn_decl;
        }
    }
    return null;
}

// B2: TypeId overlay for generic METHOD instances (`List<T>.map<U>`). For each recorded method instance,
// record tp_resolve for BOTH the struct T-params (from the receiver struct instance) AND the method U-params,
// under a COMBINED inst_key, then walk the method body applying both substitutions. This makes the method
// body's type-params (T and U) resolve via TypeIds under current_instantiation_id = inst_key.
pub fn runMethods(
    allocator: std.mem.Allocator,
    store: *TypeStore,
    tab: *const SymbolTable,
    ir: *TypedIr,
) void {
    const mono = @import("mono.zig");
    for (mono.method_insts.items) |mi| {
        const key = mi.inst_key orelse continue;
        const recv = mi.recv orelse continue;
        const mowner = mi.method_owner orelse continue;
        const margs = mi.args_tids orelse continue;
        if (store.get(recv) != .struct_) continue;
        const si = store.get(recv).struct_;
        // struct T-params
        for (si.args, 0..) |arg, j| {
            const tp = store.intern(.{ .type_param = .{ .owner = si.decl, .index = @intCast(j) } }) catch continue;
            ir.recordTpResolve(allocator, tp, key, arg) catch {};
        }
        // method U-params
        for (margs, 0..) |arg, i| {
            const tp = store.intern(.{ .type_param = .{ .owner = mowner, .index = @intCast(i) } }) catch continue;
            ir.recordTpResolve(allocator, tp, key, arg) catch {};
        }
        const msym = tab.symbolAt(mowner);
        if (msym.decl != .function) continue;
        const fd = msym.decl.function;
        const ctx = Ctx{
            .allocator = allocator,
            .store = store,
            .ir = ir,
            .decl = si.decl,
            .args = si.args,
            .inst = key,
            .decl2 = mowner,
            .args2 = margs,
        };
        for (fd.body.statements) |*s| ctx.stmt(s);
    }
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    store: *TypeStore,
    ir: *TypedIr,
    decl: types.SymbolId,
    args: []const TypeId,
    inst: TypeId,
    // Optional SECOND (owner, args) substitution, applied after the first. For a generic METHOD body (B2) the
    // first is the struct's (decl, T-args) and the second the method's (mid, <U>-args), so both the struct's
    // T and the method's U resolve. Null for struct/free-fn bodies (single owner).
    decl2: ?types.SymbolId = null,
    args2: []const TypeId = &.{},

    fn concreteOf(self: Ctx, t: TypeId) TypeId {
        var c = subst.substitute(self.store, t, self.decl, self.args) catch t;
        if (self.decl2) |d2| c = subst.substitute(self.store, c, d2, self.args2) catch c;
        return c;
    }

    fn visit(self: Ctx, e: *const ast.Expression) void {
        if (self.ir.typeOf(e)) |t| {
            const concrete = self.concreteOf(t);
            self.ir.recordOwnedInst(self.allocator, e.id, self.inst, disposition(e.kind, concrete, self.store)) catch {};

            if (concrete != t) self.ir.recordTypeInst(self.allocator, e.id, self.inst, concrete) catch {};
        }
        self.children(e);
    }

    fn children(self: Ctx, e: *const ast.Expression) void {
        switch (e.kind) {
            .call => |c| {
                self.visit(c.callee);
                for (c.args) |*a| self.visit(a);
            },
            .generic_call => |c| {
                self.visit(c.callee);
                for (c.args) |*a| self.visit(a);
            },
            .binary => |b| {
                self.visit(b.left);
                self.visit(b.right);
            },
            .unary => |u| self.visit(u.operand),
            .field_access => |fa| self.visit(fa.object),
            .index => |ix| {
                self.visit(ix.object);
                self.visit(ix.index);
            },
            .cast => |c| self.visit(c.expr),
            .optional_chaining => |oc| self.visit(oc.object),
            .nullish_coalesce => |nc| {
                self.visit(nc.left);
                self.visit(nc.right);
            },
            .template_expr => |tp| for (tp.parts) |*p| self.visit(p),
            .tuple => |elems| for (elems) |*x| self.visit(x),
            .struct_init => |si| for (si.fields) |*fld| self.visit(&fld.value),
            .enum_init => |ei| for (ei.fields) |*fld| self.visit(&fld.value),
            .if_expr => |ie| {
                self.visit(ie.condition);
                self.visit(ie.then_branch);
                self.visit(ie.else_branch);
            },
            .block_expr => |b| for (b.statements) |*s| self.stmt(s),
            .try_expr => |t| self.visit(t),
            .catch_expr => |c| {
                self.visit(c.expr);
                self.visit(c.handler);
            },
            .await_expr, .go_expr => |a| self.visit(a.operand),
            .closure => |cl| switch (cl.body) {
                .expr => |ce| self.visit(ce),
                .block => |b| for (b.statements) |*s| self.stmt(s),
            },
            else => {},
        }
    }

    fn stmt(self: Ctx, s: *const ast.Statement) void {
        switch (s.*) {
            .block => |b| for (b.statements) |*x| self.stmt(x),
            .let_stmt => |ls| if (ls.init) |init| self.visit(&init),
            .expr_stmt => |es| self.visit(&es.expr),
            .return_stmt => |r| if (r.value) |v| self.visit(&v),
            .if_stmt => |iff| {
                self.visit(&iff.condition);
                self.stmt(iff.then_branch);
                if (iff.else_branch) |e| self.stmt(e);
            },
            .while_stmt => |w| {
                self.visit(&w.condition);
                self.stmt(w.body);
            },
            .for_stmt => |fo| {
                if (fo.condition) |c| self.visit(&c);
                if (fo.increment) |c| self.visit(&c);
                if (fo.iterator) |it| self.visit(it.iterable);
                self.stmt(fo.body);
            },
            .switch_stmt => |sw| {
                self.visit(&sw.discriminant);
                for (sw.cases) |c| {
                    for (c.values) |*v| self.visit(v);
                    self.stmt(c.body);
                }
                if (sw.default_case) |d| self.stmt(d);
            },
            .defer_stmt => |d| self.visit(&d.expr),
            else => {},
        }
    }
};

fn disposition(kind: ast.ExprKind, t: TypeId, store: *const TypeStore) bool {
    switch (kind) {
        .ident, .field_access, .index => return false,
        .binary => |b| if (b.op == .assign) return false,
        .literal => return false,
        .try_expr, .cast, .await_expr, .go_expr, .optional_chaining => return false,
        else => {},
    }
    return store.isOwnedSafe(t);
}
