//! Per-instantiation disposition and type recording for monomorphised generics.
//!
//! When a generic body is type-checked it is checked ONCE against its type
//! parameters (`T`, `U`, ...), so the typed-IR records only the abstract type of
//! each expression (e.g. `T`, or `List<T>`). But ARC and codegen need to know, at
//! every use site inside a CONCRETE instantiation, two facts that the abstract
//! check cannot answer:
//!
//!   1. **Ownership disposition**, does this expression PRODUCE an owned value
//!      that the surrounding scope is responsible for releasing? A `T` might
//!      monomorphise to `int` (never owned) or to `List<int>` (heap, owned), so
//!      the answer differs per instantiation of the SAME source expression.
//!
//!   2. **Concrete type**, the actual [`TypeId`] the abstract type resolves to
//!      once the instantiation's type arguments are substituted in, so later
//!      passes can emit the right dtor / layout without re-substituting.
//!
//! This module makes a SECOND pass, after monomorphisation has discovered which
//! instantiations actually exist, and walks each instantiation's body recording
//! both facts into the shared [`TypedIr`], keyed by `(expr.id, inst)`. The same
//! source expression therefore carries a distinct disposition and concrete type
//! for every instantiation it appears in.
//!
//! Three entry points cover the three shapes a generic can take, and they share
//! the recursive walker in [`Ctx`]:
//!
//!   * [`run`], generic STRUCTs reached as concrete instantiations, walking the
//!     bodies of every method the struct declares.
//!   * [`runFreeFns`] / [`recordFreeFnInst`], generic FREE functions, using the
//!     instantiation list `mono` collected during monomorphisation.
//!   * [`runMethods`], generic METHODS (which have their OWN type parameters on
//!     top of the receiver's), needing a two-level substitution ([`Ctx.decl2`] /
//!     [`Ctx.args2`]).
//!
//! Every recording call is best-effort: allocation or interning failure is
//! swallowed (`catch continue` / `catch {}`) rather than propagated, because a
//! missing disposition record degrades to the conservative default elsewhere in
//! codegen rather than being a hard error. This pass adds precision, it is not a
//! correctness gate.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
/// Type-parameter substitution helper: rewrites an abstract [`TypeId`] into its
/// concrete form given an owner declaration and that instantiation's arguments.
/// See [`Ctx.concreteOf`], the only caller.
const subst = @import("subst.zig");
/// Provides the [`TypedIr`] the whole pass reads abstract types from and writes
/// per-instantiation dispositions/types back into.
const infer = @import("infer.zig");

/// Interner and query surface for types; owns the `type_param` / `struct_`
/// entries this pass reads and the [`TypeStore.isOwnedSafe`] ownership oracle.
const TypeStore = types.TypeStore;
/// Interned handle for a type; the key half of every `(expr.id, inst)` record.
const TypeId = types.TypeId;
/// The typed-IR side table this pass both reads abstract expression types from
/// and records per-instantiation dispositions and concrete types into.
const TypedIr = infer.TypedIr;
/// Maps a [`types.SymbolId`] back to its declaration, used to fetch method and
/// function bodies to walk.
const SymbolTable = symbols.SymbolTable;

/// Records dispositions for every concrete instantiation of a generic STRUCT.
///
/// For each `inst` that is a `struct_` with type arguments: binds the struct's
/// type parameters to the instantiation's arguments via
/// [`TypedIr.recordTpResolve`], then walks the body of every method the struct
/// declares through [`Ctx.stmt`], recording per-expression owned-disposition and
/// concrete-type facts keyed by `inst`.
///
/// Instantiations that are not structs, or are the un-parameterised base
/// (`args.len == 0`), are skipped. All recording is best-effort, matching the
/// module contract that missing records degrade rather than error.
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

/// Records dispositions for every concrete instantiation of a generic FREE
/// function.
///
/// Iterates the instantiation list `mono.free_fn_insts` gathered during
/// monomorphisation and delegates each to [`recordFreeFnInst`]. Imports `mono`
/// lazily to avoid a top-level import cycle between the sema passes.
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

/// Records dispositions for ONE instantiation of a generic free function.
///
/// `owner_opt`/`args_opt`/`key_opt` come from a `mono` instantiation record and
/// are all optional; if any is `null` the instantiation is not one this pass can
/// process and the call returns early. Binds the function's type parameters to
/// `args_opt` (owner = the function's [`types.SymbolId`]), finds the source
/// declaration by name via [`findFreeFn`], and walks its body through
/// [`Ctx.stmt`] keyed by `key_opt`.
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

/// Finds a generic free function declaration by name in the program.
///
/// Matches only functions that both bear `name` and declare at least one type
/// parameter (`type_params.len > 0`), since a non-generic function of the same
/// name is not an instantiation target. Returns `null` if none matches.
fn findFreeFn(program: ast.Program, name: []const u8) ?*const ast.FunctionDecl {
    for (program.declarations) |*d| {
        if (d.* == .fn_decl and std.mem.eql(u8, d.fn_decl.name, name) and d.fn_decl.type_params.len > 0) {
            return &d.fn_decl;
        }
    }
    return null;
}

/// Records dispositions for every concrete instantiation of a generic METHOD.
///
/// A generic method has TWO layers of type parameters: those of its receiver
/// struct and its own method-level ones. This walks `mono.method_insts` and for
/// each binds BOTH layers via [`TypedIr.recordTpResolve`] (receiver params keyed
/// on `si.decl`, method params keyed on `mowner`), then walks the method body
/// through a [`Ctx`] carrying both substitution contexts ([`Ctx.decl`]/[`Ctx.args`]
/// for the receiver, [`Ctx.decl2`]/[`Ctx.args2`] for the method) so
/// [`Ctx.concreteOf`] can resolve types mentioning either.
///
/// Records whose receiver is not a `struct_`, or whose method owner does not
/// resolve to a function declaration, are skipped.
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
        for (si.args, 0..) |arg, j| {
            const tp = store.intern(.{ .type_param = .{ .owner = si.decl, .index = @intCast(j) } }) catch continue;
            ir.recordTpResolve(allocator, tp, key, arg) catch {};
        }
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

/// The recursive AST walker for one instantiation.
///
/// Holds everything needed to resolve an abstract type to its concrete form and
/// to write records: the substitution context(s) and the destination
/// [`TypedIr`]. Passed by value (it is small and immutable per walk) to
/// [`stmt`]/[`visit`]/[`children`], which recurse over the body. The `decl2` /
/// `args2` pair is populated only for generic-method walks (see [`runMethods`]);
/// struct and free-function walks leave it at its `null` / empty defaults.
const Ctx = struct {
    /// Allocator for the side-table insertions made while walking.
    allocator: std.mem.Allocator,
    /// Type interner and ownership oracle ([`TypeStore.isOwnedSafe`]).
    store: *TypeStore,
    /// Destination for the disposition and concrete-type records this walk emits.
    ir: *TypedIr,
    /// Owner of the FIRST substitution layer (the struct, free fn, or method
    /// receiver) whose type parameters map to [`args`].
    decl: types.SymbolId,
    /// The concrete type arguments for [`decl`], positionally matching its type
    /// parameters.
    args: []const TypeId,
    /// The instantiation key every record produced by this walk is tagged with;
    /// distinguishes the same source expression across instantiations.
    inst: TypeId,
    /// Owner of the SECOND substitution layer, set only for generic methods (the
    /// method's own type parameters); `null` for struct/free-fn walks.
    decl2: ?types.SymbolId = null,
    /// Concrete type arguments for [`decl2`]; empty unless walking a generic
    /// method.
    args2: []const TypeId = &.{},

    /// Substitutes an abstract [`TypeId`] down to its concrete form for this
    /// instantiation.
    ///
    /// Applies the receiver/owner substitution first, then, when present, the
    /// method-level one on top, so a type mentioning both a receiver param and a
    /// method param resolves fully. A substitution failure falls back to the
    /// input unchanged rather than erroring.
    fn concreteOf(self: Ctx, t: TypeId) TypeId {
        var c = subst.substitute(self.store, t, self.decl, self.args) catch t;
        if (self.decl2) |d2| c = subst.substitute(self.store, c, d2, self.args2) catch c;
        return c;
    }

    /// Records disposition and concrete type for one expression, then recurses.
    ///
    /// If the abstract type of `e` is known, resolves it via [`concreteOf`],
    /// records whether `e` yields an owned value ([`disposition`]) keyed by
    /// [`inst`], and, WHEN the concrete type actually differs from the abstract
    /// one, also records the concrete [`TypeId`] so codegen need not re-substitute.
    /// Always descends into sub-expressions via [`children`].
    fn visit(self: Ctx, e: *const ast.Expression) void {
        if (self.ir.typeOf(e)) |t| {
            const concrete = self.concreteOf(t);
            self.ir.recordOwnedInst(self.allocator, e.id, self.inst, disposition(e.kind, concrete, self.store)) catch {};

            if (concrete != t) self.ir.recordTypeInst(self.allocator, e.id, self.inst, concrete) catch {};
        }
        self.children(e);
    }

    /// Visits every sub-expression (and nested statement) of `e`.
    ///
    /// One arm per compound [`ast.ExprKind`], forwarding each child to [`visit`]
    /// and each nested statement (block bodies, closure blocks) to [`stmt`]. Leaf
    /// expressions fall through the `else`, terminating the recursion. Keeping the
    /// structural descent here, separate from the per-node recording in
    /// [`visit`], means every expression in the tree is both recorded and
    /// traversed exactly once.
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

    /// Walks the expressions reachable from a statement.
    ///
    /// One arm per compound [`ast.Statement`], visiting every embedded expression
    /// through [`visit`] and recursing into nested statements through [`stmt`].
    /// Statements with no expressions of interest fall through the `else`. This is
    /// the entry the three top-level passes call for each statement of a body.
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

/// Decides whether an expression PRODUCES an owned value in this instantiation.
///
/// Returns `false` for expression kinds that merely REFERENCE or borrow an
/// existing value rather than producing a fresh owned one, so the scope does not
/// try to release something it does not own:
///   * `ident` / `field_access` / `index`, read an existing binding or member.
///   * `binary` with `op == .assign`, an assignment yields nothing to own.
///   * `literal`, non-heap constants.
///   * `try_expr` / `cast` / `await_expr` / `go_expr` / `optional_chaining`,
///     forward or transform an inner value without minting new ownership here.
///
/// For every other kind, ownership follows the concrete TYPE: returns
/// [`TypeStore.isOwnedSafe`], i.e. true exactly when `t` is a heap-managed type
/// that carries an ARC obligation. `t` is the CONCRETE type from
/// [`Ctx.concreteOf`], which is why the answer is instantiation-specific: the
/// same source expression is owned when `t` monomorphises to `List<int>` and not
/// when it monomorphises to `int`.
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
