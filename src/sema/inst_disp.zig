
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

const Ctx = struct {
    allocator: std.mem.Allocator,
    store: *TypeStore,
    ir: *TypedIr,
    decl: types.SymbolId,
    args: []const TypeId,
    inst: TypeId,

    fn visit(self: Ctx, e: *const ast.Expression) void {
        if (self.ir.typeOf(e)) |t| {
            const concrete = subst.substitute(self.store, t, self.decl, self.args) catch t;
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
