// inst_disp.zig — F4 erased-body elimination: make the checker INSTANTIATION-AWARE about ownership.
//
// THE GAP. `store.isOwned(.type_param)` is false (the erasure rule), so the checker types
// `self.data.get(i)` inside `List<T>.get` as borrowed. But codegen compiles the MONOMORPHIZED body
// `List_string_get`, where that same occurrence is `string` = OWNED — and today codegen re-derives that
// with a side-channel (`current_instantiation` → `keystoneSubst`), NOT from the IR. That side-channel is
// the last place codegen decides a type from context the typed IR does not carry — the exact thing F2-6
// exists to kill, and the sole reason the `principledDisposition` fallback still exists.
//
// THE FIX (this pass). For every reachable instantiation (`List<string>`, `Map<string,int>`, …), walk
// its type's method bodies ONCE, read each expression's already-recorded (erased) type, SUBSTITUTE the
// type parameters against the instantiation's args, and record the disposition of the CONCRETE type into
// `TypedIr.expr_owned_inst[(ExprId, instantiation)]`. No re-inference — it reads recorded types and
// substitutes — so it is side-effect-free and cannot perturb the erased walk. Codegen then reads the
// per-instantiation disposition when compiling a monomorphized body, and `keystoneSubst` + the fallback
// can go. The erased body stays (it is runtime-referenced; this does not touch it).

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

/// Populate `ir.expr_owned_inst` for every instantiation in `insts` (concrete struct TypeIds).
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
        if (st.args.len == 0) continue; // the generic itself (`List<T>`), not an instantiation

        // F4: precompute the bare-type-param resolution for this instantiation — `type_param{decl,i}`
        // resolves to `args[i]`. This is the field-level path (a struct field / destructor element has
        // no ExprId) that lets codegen READ the concrete type instead of substituting (keystoneSubst).
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
    decl: types.SymbolId, // the generic type whose params `args` substitute
    args: []const TypeId, // this instantiation's concrete args
    inst: TypeId, // the instantiation struct TypeId (the map key)

    /// Record the concrete disposition of `e` under this instantiation.
    fn visit(self: Ctx, e: *const ast.Expression) void {
        if (self.ir.typeOf(e)) |t| {
            const concrete = subst.substitute(self.store, t, self.decl, self.args) catch t;
            self.ir.recordOwnedInst(self.allocator, e.id, self.inst, disposition(e.kind, concrete, self.store)) catch {};
            // Also record the concrete TYPE, so codegen reads it from the IR instead of substituting
            // (`keystoneSubst`) — but only when substitution actually resolved it (else it stays the
            // erased type_param, which the erased path already handles).
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

/// The ownership disposition of a concrete type at an expression of `kind` — IDENTICAL to
/// `Inferer.ownedDisposition` (borrow kinds + non-producing forms are borrowed; else `isOwnedSafe`).
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
