
const std = @import("std");
const ast = @import("../ast.zig");
const ids = @import("ids.zig");
const subst = @import("subst.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");
const lower = @import("lower.zig");
const builtins = @import("builtins.zig");
const mono = @import("mono.zig");

pub const TypeId = types.TypeId;

pub const Stats = struct {
    typed: usize = 0,
    unresolved: usize = 0,

    unresolved_ns_ident: usize = 0,
    unresolved_ns_field: usize = 0,

    by_tag: std.StringHashMapUnmanaged(usize) = .empty,

    by_name: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.by_tag.deinit(allocator);
        self.by_name.deinit(allocator);
    }
};

const Binding = struct { name: []const u8, ty: TypeId, is_const: bool = false };

pub const OwnOp = enum { move, drop };

pub const InstKey = struct { id: ast.ExprId, inst: TypeId };

pub const TpKey = struct { tp: TypeId, inst: TypeId };

pub const TypedIr = struct {

    expr_types: std.AutoHashMapUnmanaged(ast.ExprId, TypeId) = .empty,

    expr_syms: std.AutoHashMapUnmanaged(ast.ExprId, types.SymbolId) = .empty,

    expr_method_args: std.AutoHashMapUnmanaged(ast.ExprId, []const TypeId) = .empty,

    expr_owned: std.AutoHashMapUnmanaged(ast.ExprId, bool) = .empty,

    expr_op: std.AutoHashMapUnmanaged(ast.ExprId, OwnOp) = .empty,

    expr_owned_inst: std.AutoHashMapUnmanaged(InstKey, bool) = .empty,

    expr_types_inst: std.AutoHashMapUnmanaged(InstKey, TypeId) = .empty,

    tp_resolve: std.AutoHashMapUnmanaged(TpKey, TypeId) = .empty,

    unassigned_rejected: usize = 0,

    pub fn deinit(self: *TypedIr, allocator: std.mem.Allocator) void {
        self.expr_types.deinit(allocator);
        self.expr_syms.deinit(allocator);
        var mit = self.expr_method_args.valueIterator();
        while (mit.next()) |v| allocator.free(v.*);
        self.expr_method_args.deinit(allocator);
        self.expr_owned.deinit(allocator);
        self.expr_op.deinit(allocator);
        self.expr_owned_inst.deinit(allocator);
        self.expr_types_inst.deinit(allocator);
        self.tp_resolve.deinit(allocator);
    }

    pub fn recordOwnedInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, owned: bool) !void {
        if (id == .unassigned) return;
        try self.expr_owned_inst.put(allocator, .{ .id = id, .inst = inst }, owned);
    }

    pub fn ownedOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?bool {
        if (id == .unassigned) return null;
        return self.expr_owned_inst.get(.{ .id = id, .inst = inst });
    }

    pub fn recordTypeInst(self: *TypedIr, allocator: std.mem.Allocator, id: ast.ExprId, inst: TypeId, t: TypeId) !void {
        if (id == .unassigned) return;
        try self.expr_types_inst.put(allocator, .{ .id = id, .inst = inst }, t);
    }

    pub fn typeOfInst(self: *const TypedIr, id: ast.ExprId, inst: TypeId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types_inst.get(.{ .id = id, .inst = inst });
    }

    pub fn recordTpResolve(self: *TypedIr, allocator: std.mem.Allocator, tp: TypeId, inst: TypeId, concrete: TypeId) !void {
        try self.tp_resolve.put(allocator, .{ .tp = tp, .inst = inst }, concrete);
    }

    pub fn tpResolve(self: *const TypedIr, tp: TypeId, inst: TypeId) ?TypeId {
        return self.tp_resolve.get(.{ .tp = tp, .inst = inst });
    }

    pub fn recordOp(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, op: OwnOp) !void {
        if (e.id == .unassigned) return;
        try self.expr_op.put(allocator, e.id, op);
    }

    pub fn opOf(self: *const TypedIr, id: ast.ExprId) ?OwnOp {
        if (id == .unassigned) return null;
        return self.expr_op.get(id);
    }

    pub fn typeOf2(self: *const TypedIr, id: ast.ExprId) ?TypeId {
        if (id == .unassigned) return null;
        return self.expr_types.get(id);
    }

    pub fn recordOwned(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, owned: bool) !void {
        if (e.id == .unassigned) return;
        try self.expr_owned.put(allocator, e.id, owned);
    }

    pub fn ownedOf(self: *const TypedIr, e: *const ast.Expression) ?bool {
        if (e.id == .unassigned) return null;
        return self.expr_owned.get(e.id);
    }

    pub fn ownedTrueCount(self: *const TypedIr) usize {
        var n: usize = 0;
        var it = self.expr_owned.valueIterator();
        while (it.next()) |v| {
            if (v.*) n += 1;
        }
        return n;
    }

    pub fn recordMethodArgs(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, args: []const TypeId) !void {
        if (e.id == .unassigned) return;
        if (self.expr_method_args.get(e.id)) |old| allocator.free(old);
        const dup = try allocator.dupe(TypeId, args);
        try self.expr_method_args.put(allocator, e.id, dup);
    }

    pub fn methodArgsOf(self: *const TypedIr, e: *const ast.Expression) ?[]const TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_method_args.get(e.id);
    }

    pub fn recordSym(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, sid: types.SymbolId) !void {
        if (e.id == .unassigned) return;
        try self.expr_syms.put(allocator, e.id, sid);
    }

    pub fn symOf(self: *const TypedIr, e: *const ast.Expression) ?types.SymbolId {
        if (e.id == .unassigned) return null;
        return self.expr_syms.get(e.id);
    }

    pub fn record(self: *TypedIr, allocator: std.mem.Allocator, e: *const ast.Expression, t: TypeId) !void {
        if (e.id == .unassigned) {
            self.unassigned_rejected += 1;
            return;
        }
        try self.expr_types.put(allocator, e.id, t);
    }

    pub fn typeOf(self: *const TypedIr, e: *const ast.Expression) ?TypeId {
        if (e.id == .unassigned) return null;
        return self.expr_types.get(e.id);
    }

    pub fn count(self: *const TypedIr) usize {
        return self.expr_types.count();
    }

    pub fn unresolvedCount(self: *const TypedIr, store: *const types.TypeStore) usize {
        var n: usize = 0;
        var it = self.expr_types.valueIterator();
        while (it.next()) |t| {
            if (store.get(t.*) == .unresolved) n += 1;
        }
        return n;
    }
};

const Narrowing = struct {
    name: []const u8,

    when_true: bool,
};

fn narrowedBinding(cond: ast.BinaryExpr) ?Narrowing {
    const when_true = switch (cond.op) {
        .ne => true,
        .eq => false,
        else => return null,
    };
    const l_undef = cond.left.kind == .literal and cond.left.kind.literal == .undefined;
    const r_undef = cond.right.kind == .literal and cond.right.kind.literal == .undefined;

    if (l_undef == r_undef) return null;
    const other = if (l_undef) cond.right else cond.left;
    if (other.kind != .ident) return null;
    return .{ .name = other.kind.ident, .when_true = when_true };
}

fn branchTerminates(s: *const ast.Statement) bool {
    return switch (s.*) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        .block => |b| b.statements.len > 0 and branchTerminates(&b.statements[b.statements.len - 1]),
        else => false,
    };
}

fn earlyExitNarrowing(s: *const ast.Statement) ?Narrowing {
    if (s.* != .if_stmt) return null;
    const i = s.if_stmt;
    if (i.condition.kind != .binary) return null;
    const n = narrowedBinding(i.condition.kind.binary) orelse return null;
    if (n.when_true) {

        const e = i.else_branch orelse return null;
        if (!branchTerminates(e)) return null;
    } else {

        if (i.else_branch != null) return null;
        if (!branchTerminates(i.then_branch)) return null;
    }
    return n;
}

pub const VisKind = enum { function, type_, const_ };

pub const VisError = struct {
    span: ast.Span,
    recv: []const u8,
    field: []const u8,

    kind: VisKind = .function,
};

pub const ConstReassignError = struct {
    span: ast.Span,
    name: []const u8,
};

pub const OptDerefKind = enum { opt, err };
pub const OptDerefError = struct {
    span: ast.Span,
    field: []const u8,
    is_method: bool,
    kind: OptDerefKind = .opt,
};

pub const CatchMismatchError = struct {
    span: ast.Span,
    ok: TypeId,
    handler: TypeId,
};

// A `try g()` whose propagated error type does not match the enclosing function's declared error type.
// `try` re-raises the callee's error unchanged, so `fn f(): T | E1 { return try g() }` where g fails with
// E2 is a soundness hole -- the caller's contract says E1 but an E2 escapes (G5).
pub const TryErrorMismatch = struct {
    span: ast.Span,
    callee_err: TypeId,
    fn_err: TypeId,
};

// A1 fail-closed soundness pass (gaps.md C-chk-4). A condition in `if` / `while` / `for` must be a `bool`.
// A non-bool condition (int/long/enum/optional/string) was silently accepted and its discriminant/word used
// as truthiness -- silent wrong control flow. `.unresolved` is left alone (fail-open only where sema genuinely
// could not type the expression, to avoid false positives from the incomplete inferrer).
pub const CondTypeError = struct {
    span: ast.Span,
    got: TypeId,
    ctx: []const u8,
};

// A1 (gaps.md C-chk-3). Returning a `T | undefined` value where the function is declared to return a plain
// non-optional `T`. The unwrapped path reads the value word of an absent optional and dereferences the
// `undefined` sentinel -- a runtime SEGV with no compile error. Narrowing-safe: sema rebinds a narrowed
// optional to its non-optional inner type in scope, so a guarded `return x` inside `if (x != undefined)` is
// already non-optional here and does not fire.
pub const RetOptionalError = struct {
    span: ast.Span,
    ret: TypeId,
    val: TypeId,
};

// A1 (gaps.md C-chk-1). A method call `obj.m(...)` whose argument count does not match the method's declared
// parameters (Nova has no default or variadic params, so the arity is exact). Was previously unchecked and
// produced an LLVMVerificationError with no source span; free-function/constructor arity was already checked
// in the legacy pass.
pub const MethodArityError = struct {
    span: ast.Span,
    name: []const u8,
    expected: usize,
    got: usize,
};

pub const Inferer = struct {
    allocator: std.mem.Allocator,
    store: *types.TypeStore,
    symtab: *const symbols.SymbolTable,
    lowerer: *lower.Lowerer,

    scopes: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    const_depth: usize = 0,

    current_ret: ?TypeId = null,

    current_module: ?symbols.ModuleId = null,

    visibility_errors: std.ArrayListUnmanaged(VisError) = .empty,

    const_reassign_errors: std.ArrayListUnmanaged(ConstReassignError) = .empty,

    optional_deref_errors: std.ArrayListUnmanaged(OptDerefError) = .empty,

    // A `catch` whose handler value does not match the ok side of the error union. Both arms must
    // unify (the catch yields the ok type), so e.g. `intFn() catch (e) e.describe()` (ok=int,
    // handler=string) is a soundness error, not silent garbage.
    catch_mismatch_errors: std.ArrayListUnmanaged(CatchMismatchError) = .empty,

    try_error_mismatch_errors: std.ArrayListUnmanaged(TryErrorMismatch) = .empty,

    cond_type_errors: std.ArrayListUnmanaged(CondTypeError) = .empty,

    ret_optional_errors: std.ArrayListUnmanaged(RetOptionalError) = .empty,

    method_arity_errors: std.ArrayListUnmanaged(MethodArityError) = .empty,

    fatal_unresolved_idents: usize = 0,

    first_fatal_ident: ?[]const u8 = null,
    first_fatal_span: ?ast.Span = null,
    // F1-7: a qualified call `mod.fn(...)` where `mod` is a known module but has no function `fn` — the
    // confident subset of the codegen MethodOrFunctionNotFound, rejected here so it fires before codegen.
    fatal_unresolved_calls: usize = 0,
    first_fatal_call_recv: ?[]const u8 = null,
    first_fatal_call_field: ?[]const u8 = null,
    first_fatal_call_span: ?ast.Span = null,

    captured_return: ?TypeId = null,

    in_call_callee: bool = false,

    // The statement list currently being inferred (set by inferStmtSeq). Lets a
    // `let name = closure` look ahead to a call site `name(args)` in the same block and
    // pin the closure's param types from the argument types, so the closure (and any local
    // that holds its result) is correctly typed on the first pass.
    current_stmt_seq: ?[]ast.Statement = null,

    ir: ?*TypedIr = null,
    stats: Stats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        store: *types.TypeStore,
        symtab: *const symbols.SymbolTable,
        lowerer: *lower.Lowerer,
    ) Inferer {
        return .{ .allocator = allocator, .store = store, .symtab = symtab, .lowerer = lowerer };
    }

    pub fn deinit(self: *Inferer) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.stats.deinit(self.allocator);
        self.visibility_errors.deinit(self.allocator);
        self.const_reassign_errors.deinit(self.allocator);
        self.optional_deref_errors.deinit(self.allocator);
        self.catch_mismatch_errors.deinit(self.allocator);
        self.try_error_mismatch_errors.deinit(self.allocator);
    }

    fn push(self: *Inferer) !void {
        try self.scopes.append(self.allocator, .empty);
    }
    fn pop(self: *Inferer) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }
    fn bind(self: *Inferer, name: []const u8, ty: TypeId) !void {
        try self.bindC(name, ty, false);
    }

    fn bindC(self: *Inferer, name: []const u8, ty: TypeId, is_const: bool) !void {
        if (self.scopes.items.len == 0) try self.push();
        try self.scopes.items[self.scopes.items.len - 1].append(self.allocator, .{ .name = name, .ty = ty, .is_const = is_const });
    }

    fn lookupIsConst(self: *Inferer, name: []const u8) bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b.is_const;
            }
        }
        return false;
    }

    fn rebind(self: *Inferer, name: []const u8, ty: TypeId) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |*b| {
                if (std.mem.eql(u8, b.name, name)) {
                    b.ty = ty;
                    return;
                }
            }
        }
    }

    fn lookup(self: *Inferer, name: []const u8) ?TypeId {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].items) |b| {
                if (std.mem.eql(u8, b.name, name)) return b.ty;
            }
        }
        return null;
    }

    fn unresolved(self: *Inferer, tag: []const u8) !TypeId {
        self.stats.unresolved += 1;
        const gop = try self.stats.by_tag.getOrPut(self.allocator, tag);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        return self.store.unresolvedT();
    }

    fn note(self: *Inferer, name: []const u8) !void {
        const gop = try self.stats.by_name.getOrPut(self.allocator, name);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    fn lubTraitOfStructs(self: *Inferer, tt: TypeId, et: TypeId) !?TypeId {
        if (self.store.get(tt) != .struct_ or self.store.get(et) != .struct_) return null;
        const t_sym = self.symtab.symbolAt(self.store.get(tt).struct_.decl);
        const e_sym = self.symtab.symbolAt(self.store.get(et).struct_.decl);
        if (t_sym.decl != .struct_ or e_sym.decl != .struct_) return null;
        var found: ?TypeId = null;
        for (t_sym.decl.struct_.impls) |ti| {
            for (e_sym.decl.struct_.impls) |ei| {
                if (!std.mem.eql(u8, ti.name, ei.name)) continue;
                const sid = self.symtab.findTypeInModule(ti.name, self.current_module) orelse continue;
                if (self.symtab.symbolAt(sid).decl != .trait_) continue;
                const trait_tid = try self.store.intern(.{ .trait_ = sid });
                if (found) |f| {
                    if (f != trait_tid) return null;
                } else found = trait_tid;
            }
        }
        return found;
    }
    fn ok(self: *Inferer, id: TypeId) TypeId {
        self.stats.typed += 1;
        return id;
    }

    // Do the two arms of a `catch` unify? The result type is the ok side; the handler must produce
    // a value usable as it. Conservative to avoid false positives: same type is fine, unresolved is
    // skipped, and the only rejected shape is a heap `string`/`decimal` on one arm and something
    // else on the other, which is exactly the case codegen would mis-stringify or mis-free (e.g. an
    // `int` ok side with a `string` handler). Numeric/struct/trait/enum variety is allowed.
    fn catchArmsCompatible(self: *Inferer, ok_t: TypeId, handler_t: TypeId) bool {
        if (ok_t == handler_t) return true;
        const ko = self.store.get(ok_t);
        const kh = self.store.get(handler_t);
        if (ko == .unresolved or kh == .unresolved) return true;
        if ((ko == .string) != (kh == .string)) return false;
        if ((ko == .decimal) != (kh == .decimal)) return false;
        return true;
    }

    // Two error types match if they are the same declared type (same enum/exception SymbolId, or same
    // struct decl, or the identical TypeId). An unresolved side is never flagged (avoid false positives on
    // types sema could not pin). Nova has no error-type subtyping, so a mismatch is always a G5 error.
    fn errorTypesCompatible(self: *Inferer, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        const sa = self.store.get(a);
        const sb = self.store.get(b);
        if (sa == .unresolved or sb == .unresolved) return true;
        if (sa == .enum_ and sb == .enum_) return sa.enum_ == sb.enum_;
        if (sa == .struct_ and sb == .struct_) return sa.struct_.decl == sb.struct_.decl;
        return false;
    }

    pub fn inferExpr(self: *Inferer, ep: *const ast.Expression) anyerror!TypeId {
        return self.inferExprExpecting(ep, null);
    }

    pub fn inferExprExpecting(self: *Inferer, ep: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const t = try self.inferExprInner(ep.*, expected);
        if (self.ir) |ir| {
            try ir.record(self.allocator, ep, t);

            try ir.recordOwned(self.allocator, ep, self.ownedDisposition(ep.kind, t));
        }
        return t;
    }

    fn ownedDisposition(self: *Inferer, kind: ast.ExprKind, t: TypeId) bool {
        switch (kind) {
            .ident, .field_access, .index => return false,
            .binary => |b| if (b.op == .assign) return false,

            .literal => |lit| if (lit != .decimal) return false,
            .try_expr, .cast, .await_expr, .go_expr, .optional_chaining => return false,
            else => {},
        }

        return self.store.isOwnedSafe(t);
    }

    fn inferExprInner(self: *Inferer, e: ast.Expression, expected: ?TypeId) anyerror!TypeId {
        switch (e.kind) {

            .range => |r| {
                _ = try self.inferExpr(r.start);
                _ = try self.inferExpr(r.end);
                return self.ok(try self.store.intT());
            },
            .literal => |lit| return switch (lit) {

                // An untyped integer literal adopts an integer `expected` type. Without this,
                // `let x: long = 1 << 40` (or `1000000 * 1000000`) types the literals as `int`, computes the
                // whole expression in 32 bits, and overflows BEFORE the widening to `long` -- silent wrong
                // values. Only integer expected types apply; a non-integer context falls back to `int`.
                .integer => {
                    if (expected) |exp| {
                        const et = self.store.get(exp);
                        // Only WIDEN (>= 32 bits: int/uint/long/ulong). Adopting a narrower expected type
                        // (short/byte) would collide with the explicit-narrowing rule (F3 §6); a bare
                        // literal keeps defaulting to `int` there.
                        if (et == .prim and et.prim.kind == .int and et.prim.bits >= 32) return self.ok(exp);
                    }
                    return self.ok(try self.store.intT());
                },
                .float => self.ok(try self.store.doubleT()),
                .string => self.ok(try self.store.stringT()),
                .bool => self.ok(try self.store.boolT()),

                .decimal => self.ok(try self.store.decimalT()),

                .array => |items| {
                    if (items.len == 0) return self.unresolved("literal");
                    const elem = try self.inferExpr(&items[0]);
                    for (items[1..]) |*it| _ = try self.inferExpr(it);
                    if (self.store.get(elem) == .unresolved) return self.unresolved("literal");
                    return self.ok(try self.store.intern(.{ .array = .{ .elem = elem, .len = items.len } }));
                },
                .array_repeat => |ar| {
                    const elem = try self.inferExpr(ar.value);
                    if (self.store.get(elem) == .unresolved) return self.unresolved("literal");
                    return self.ok(try self.store.intern(.{ .array = .{ .elem = elem, .len = ar.count } }));
                },
                else => self.unresolved("literal"),
            },
            .ident => |name| {
                if (self.lookup(name)) |t| return self.ok(t);

                if (try self.constType(name)) |t| return self.ok(t);

                if (self.symtab.findFunction(name)) |sid| {
                    if (self.symtab.symbolAt(sid).decl == .function) {
                        return self.ok(try self.fnType(self.symtab.symbolAt(sid).decl.function));
                    }
                }

                if (builtins.findExtern(name)) |b| {
                    return self.ok(try builtins.retType(self.store, b.ret));
                }
                if (self.symtab.findTypeInModule(name, self.current_module)) |sid| {
                    const tsym = self.symtab.symbolAt(sid);
                    switch (tsym.decl) {
                        .struct_ => return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } })),
                        .enum_ => return self.ok(try self.store.intern(.{ .enum_ = sid })),
                        else => {},
                    }
                }

                if (self.isFatalUnresolvedIdent(name)) {
                    self.fatal_unresolved_idents += 1;
                    if (self.first_fatal_ident == null) self.first_fatal_ident = name;
                    // Prefer the first ident that actually carries a source location (line > 0);
                    // synthesized idents have the default unset span.
                    if (self.first_fatal_span == null and e.span.line > 0) {
                        self.first_fatal_span = e.span;
                        self.first_fatal_ident = name;
                    }
                } else {

                    self.stats.unresolved_ns_ident += 1;
                }
                try self.note(name);
                return self.unresolved("ident");
            },
            .binary => |b| {
                switch (b.op) {

                    .eq, .ne, .lt, .gt, .le, .ge, .And, .Or => {
                        _ = try self.inferExpr(b.left);
                        _ = try self.inferExpr(b.right);
                        return self.ok(try self.store.boolT());
                    },

                    .assign => {
                        const lt = try self.inferExpr(b.left);
                        if (b.left.kind == .ident and self.lookupIsConst(b.left.kind.ident)) {
                            self.const_reassign_errors.append(self.allocator, .{ .span = b.span, .name = b.left.kind.ident }) catch {};
                        }
                        const at = try self.inferExpr(b.right);
                        if (self.store.get(lt) == .unresolved) {
                            return if (self.store.get(at) == .unresolved)
                                self.unresolved("assign")
                            else
                                self.ok(at);
                        }
                        return self.ok(lt);
                    },
                    else => {},
                }

                // Arithmetic / bitwise / shift. An integer `expected` type propagates into the operands so an
                // all-literal expression is computed at the target width (`let x: long = 1 << 40` runs in 64
                // bits, not 32-then-widen). The shift AMOUNT is left as-is (a widened count would fight the
                // value width), and the result takes the WIDER of the two operand integer types so a single
                // widened literal lifts the whole expression.
                const int_expected: ?TypeId = blk: {
                    const exp = expected orelse break :blk null;
                    const et = self.store.get(exp);
                    break :blk if (et == .prim and et.prim.kind == .int) exp else null;
                };
                const is_shift = (b.op == .shl or b.op == .shr);
                const lt = try self.inferExprExpecting(b.left, int_expected);
                const rt = if (is_shift) try self.inferExpr(b.right) else try self.inferExprExpecting(b.right, int_expected);

                if (b.op == .add and (self.store.get(lt) == .string or self.store.get(rt) == .string)) {
                    return self.ok(try self.store.stringT());
                }
                if (self.store.get(lt) == .unresolved) {

                    return if (self.store.get(rt) == .unresolved) self.unresolved("binary") else self.ok(rt);
                }
                if (!is_shift) {
                    const lk = self.store.get(lt);
                    const rk = self.store.get(rt);
                    if (lk == .prim and lk.prim.kind == .int and rk == .prim and rk.prim.kind == .int and rk.prim.bits > lk.prim.bits) {
                        return self.ok(rt);
                    }
                }
                return self.ok(lt);
            },
            .unary => |u| {
                const t = try self.inferExpr(u.operand);
                return if (self.store.get(t) == .unresolved) self.unresolved("unary") else self.ok(t);
            },
            .cast => |c| {
                _ = try self.inferExpr(c.expr);
                const t = try self.lowerer.lower(c.target_type);
                return if (self.store.get(t) == .unresolved) self.unresolved("cast") else self.ok(t);
            },
            .call => |c| {

                self.in_call_callee = true;
                const callee_t = try self.inferExpr(c.callee);
                self.in_call_callee = false;
                self.stats.typed -|= 1;

                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;
                    if (fa.object.kind == .ident) {
                        if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                            const decl = self.symtab.symbolAt(sid).decl;

                            if (decl == .enum_) {
                                var is_variant = false;
                                for (decl.enum_.variants) |v| {
                                    if (std.mem.eql(u8, v.name, fa.field)) {
                                        is_variant = true;
                                        break;
                                    }
                                }
                                if (is_variant) {
                                    for (c.args) |*a| _ = try self.inferExpr(a);
                                    return self.ok(try self.store.intern(.{ .enum_ = sid }));
                                }
                            }
                        }
                    }
                }

                const want = try self.calleeParamTypes(c.callee);
                defer if (want) |w| self.allocator.free(w);

                var arg_types = std.ArrayListUnmanaged(TypeId).empty;
                defer arg_types.deinit(self.allocator);
                for (c.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (want) |w| (if (i < w.len) w[i] else null) else null;
                    const at = try self.inferExprExpecting(a, exp);
                    try arg_types.append(self.allocator, at);
                }
                if (c.callee.kind == .ident) {

                    if (builtins.findExtern(c.callee.kind.ident)) |b| {
                        return self.ok(try builtins.retType(self.store, b.ret));
                    }

                    const bare_fn_sid: ?symbols.SymbolId = blk: {
                        if (self.current_module) |cm| {
                            if (self.symtab.findFunctionIn(cm, c.callee.kind.ident)) |s| break :blk s;
                        }
                        break :blk self.symtab.findFunction(c.callee.kind.ident);
                    };
                    if (bare_fn_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .function) {

                            if (!self.symtab.findFunctionAmbiguous(c.callee.kind.ident)) {
                                if (self.ir) |ir| try ir.recordSym(self.allocator, &e, sid);
                            }
                            const fd = sym.decl.function;
                            self.warnIfDeprecated(fd, c.span); // FR-safety-6
                            if (fd.ret_type) |r| {

                                if (fd.type_params.len > 0) {
                                    if (try self.freeFnReturn(sid, fd, r, arg_types.items, &e)) |t| {
                                        if (self.store.get(t) != .unresolved) return self.ok(t);
                                    }
                                }
                                const t = try self.lowerer.lower(r);
                                if (self.store.get(t) != .unresolved) return self.ok(t);
                            } else return self.ok(try self.store.voidT());
                        }
                    }

                    if (self.symtab.findTypeInModule(c.callee.kind.ident, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }
                }
                if (c.callee.kind == .field_access) {
                    const fa = c.callee.kind.field_access;

                    if (try self.builtinCallReturn(fa)) |t| return self.ok(t);
                    var modsym: ?types.SymbolId = null;
                    if (try self.moduleCallReturn(fa, &modsym)) |t| {
                        if (modsym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(t);
                    }
                    var msym: ?types.SymbolId = null;
                    if (try self.methodReturn(fa, c.args, &msym, &e)) |t| {
                        if (msym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(t);
                    }

                    if (self.symtab.findTypeInModule(fa.field, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                    }

                    if (try self.staticMethodReturn(fa)) |t| return self.ok(t);
                    // F1-7: every resolution path above failed. If the receiver is a KNOWN MODULE and the
                    // module has no such function, this is a genuinely unresolved qualified call — the
                    // confident subset of codegen's MethodOrFunctionNotFound, so reject it here (located)
                    // before codegen. Value/struct method calls stay with codegen (generics/traits).
                    if (fa.object.kind == .ident) {
                        const recv = fa.object.kind.ident;
                        if (self.lookup(recv) == null and self.isKnownModule(recv) and
                            self.resolveModuleFn(recv, fa.field, fa.span) == null)
                        {
                            self.fatal_unresolved_calls += 1;
                            if (self.first_fatal_call_recv == null) {
                                self.first_fatal_call_recv = recv;
                                self.first_fatal_call_field = fa.field;
                                self.first_fatal_call_span = fa.span;
                            }
                        }
                    }
                    if (fa.object.kind == .ident) try self.note(fa.object.kind.ident);
                }

                if (self.store.get(callee_t) == .func) {
                    return self.ok(self.store.get(callee_t).func.ret);
                }
                if (c.callee.kind == .ident) try self.note(c.callee.kind.ident);
                return self.unresolved("call");
            },
            .field_access => |fa| {

                const is_callee = self.in_call_callee;
                self.in_call_callee = false;

                _ = try self.inferExpr(fa.object);
                self.stats.typed -|= 1;

                if (try self.moduleFnValue(fa)) |t| return self.ok(t);
                if (try self.fieldType(fa)) |t| return self.ok(t);

                if (try self.stringProperty(fa)) |t| return self.ok(t);

                if (fa.object.kind == .ident) {
                    if (self.symtab.findTypeInModule(fa.object.kind.ident, self.current_module)) |sid| {
                        if (self.symtab.symbolAt(sid).decl == .enum_) {
                            return self.ok(try self.store.intern(.{ .enum_ = sid }));
                        }
                    }
                }

                if (fa.object.kind == .field_access) {
                    const inner = fa.object.kind.field_access;
                    if (inner.object.kind == .ident and self.lookup(inner.object.kind.ident) == null) {
                        if (self.symtab.findTypeInModule(inner.field, self.current_module)) |sid| {
                            if (self.symtab.symbolAt(sid).decl == .enum_) {
                                return self.ok(try self.store.intern(.{ .enum_ = sid }));
                            }
                        }
                    }
                }

                // Module-qualified constant: `module.CONST`. The object is a module
                // reference (an ident with no local binding) and the field names a
                // `pub const`. Resolve to the constant's declared type. Without this the
                // access stays `unresolved`, so downstream `+` dispatch and codegen guess
                // it as an int: `mod.STR + x` renders the string POINTER as a decimal, and
                // `mod.A + mod.B` becomes a numeric add of two pointers -> a wild pointer
                // stored as a string -> heap corruption on the later ARC free.
                if (fa.object.kind == .ident and self.lookup(fa.object.kind.ident) == null) {
                    if (try self.constType(fa.field)) |t| return self.ok(t);
                }

                if (fa.object.kind == .ident) {
                    const obj = fa.object.kind.ident;
                    if (self.lookup(obj) == null and !self.isFatalUnresolvedIdent(obj)) {
                        self.stats.unresolved_ns_field += 1;
                        return self.unresolved("field_access");
                    }
                }

                if (is_callee) {
                    self.stats.unresolved_ns_field += 1;
                    return self.unresolved("field_access");
                }

                try self.note(fa.field);
                return self.unresolved("field_access");
            },
            .optional_chaining => |o| {

                const obj_t = try self.inferExpr(o.object);
                self.stats.typed -|= 1;
                var struct_tid = obj_t;
                if (self.store.get(obj_t) == .optional) struct_tid = self.store.get(obj_t).optional;
                const st = self.store.get(struct_tid);
                if (st == .struct_) {
                    const sym = self.symtab.symbolAt(st.struct_.decl);
                    if (sym.decl == .struct_) {
                        for (sym.decl.struct_.fields) |f| {
                            if (std.mem.eql(u8, f.name, o.field)) {
                                const ft = try self.lowerInStructScope(st.struct_, f.type_name);

                                if (self.store.get(ft) == .optional) return self.ok(ft);
                                return self.ok(try self.store.intern(.{ .optional = ft }));
                            }
                        }
                    }
                }
                return self.unresolved("optional_chaining");
            },
            .nullish_coalesce => |n| {
                const lt = try self.inferExpr(n.left);
                const rt = try self.inferExpr(n.right);
                if (self.store.get(lt) == .unresolved)
                    return if (self.store.get(rt) == .unresolved) self.unresolved("nullish") else self.ok(rt);

                const l = self.store.get(lt);
                if (l == .optional) return self.ok(l.optional);
                return self.ok(lt);
            },

            .template_expr => |t| {
                for (t.parts) |*p| _ = try self.inferExpr(p);
                return self.ok(try self.store.stringT());
            },
            .if_expr => |ie| {
                _ = try self.inferExpr(ie.condition);
                const tt = try self.inferExprExpecting(ie.then_branch, expected);
                const et = try self.inferExprExpecting(ie.else_branch, expected);

                if (expected) |exp_t| {
                    if (self.store.get(exp_t) == .trait_ and
                        self.store.get(tt) == .struct_ and self.store.get(et) == .struct_)
                        return self.ok(exp_t);
                }
                if (tt == et) return self.ok(tt);

                if (try self.lubTraitOfStructs(tt, et)) |lub| return self.ok(lub);
                return self.unresolved("if_expr");
            },
            .struct_init => |si| {

                const decl_sid = self.symtab.findTypeInModule(si.type_name, self.current_module);

                // The struct's type parameters, so we can recover the instantiation (`Cell<int>`) from the
                // field values. A generic struct init previously interned with NO args, so any `T`-typed
                // field or method return stayed an erased type-param -- interpolating such a value then
                // stringified a raw int as a pointer and SEGV'd (B5).
                var type_params: []const []const u8 = &.{};
                if (decl_sid) |sid| {
                    const sym = self.symtab.symbolAt(sid);
                    if (sym.decl == .struct_) type_params = sym.decl.struct_.type_params;
                }
                const solved = try self.allocator.alloc(?TypeId, type_params.len);
                defer self.allocator.free(solved);
                @memset(solved, null);

                for (si.fields) |*f| {
                    var expected_field: ?TypeId = null;
                    var declared_in_scope: ?TypeId = null;
                    if (decl_sid) |sid| {
                        const sym = self.symtab.symbolAt(sid);
                        if (sym.decl == .struct_) {
                            for (sym.decl.struct_.fields) |sf| {
                                if (std.mem.eql(u8, sf.name, f.name)) {
                                    expected_field = self.lowerer.lower(sf.type_name) catch null;
                                    // Lower the declared field type in the struct's param scope so `T`
                                    // becomes a type-param we can solve against the actual value type.
                                    if (type_params.len > 0) {
                                        const saved = self.lowerer.param_scopes;
                                        const scopes = [_]lower.ParamScope{.{ .owner = sid, .names = type_params }};
                                        self.lowerer.param_scopes = &scopes;
                                        declared_in_scope = self.lowerer.lower(sf.type_name) catch null;
                                        self.lowerer.param_scopes = saved;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    const actual = try self.inferExprExpecting(&f.value, expected_field);
                    if (declared_in_scope) |dts| {
                        if (decl_sid) |sid| subst.solveParams(self.store, dts, actual, sid, solved);
                    }
                }
                self.recordTypeVis(si.type_name, si.span);
                if (decl_sid) |sid| {
                    if (type_params.len > 0) {
                        const args = try self.allocator.alloc(TypeId, type_params.len);
                        defer self.allocator.free(args);
                        for (solved, 0..) |m, i| args[i] = m orelse try self.store.unresolvedT();
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }));
                    }
                    return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid } }));
                }
                return self.unresolved("struct_init");
            },
            .index => |ix| {
                const obj = try self.inferExpr(ix.object);
                _ = try self.inferExpr(ix.index);
                switch (self.store.get(obj)) {

                    .string => return self.ok(try self.store.intT()),
                    .array => |a| return self.ok(a.elem),
                    else => return self.unresolved("index"),
                }
            },

            .go_expr => |g| {
                const inner = try self.inferExpr(g.operand);
                if (self.store.get(inner) == .unresolved) return self.unresolved("go");
                return self.ok(try self.store.intern(.{ .future = inner }));
            },
            .await_expr => |a| {
                const inner = try self.inferExpr(a.operand);

                return switch (self.store.get(inner)) {
                    .future => |t| self.ok(t),
                    .unresolved => try self.unresolved("await"),
                    else => self.ok(inner),
                };
            },
            .tuple => |items| {
                const elems = try self.allocator.alloc(TypeId, items.len);
                defer self.allocator.free(elems);

                const exp_elems: ?[]const TypeId = if (expected) |exp_t| blk: {
                    const ei = self.store.get(exp_t);
                    break :blk if (ei == .tuple and ei.tuple.len == items.len) ei.tuple else null;
                } else null;
                for (items, 0..) |*it, i| {
                    const exp_i: ?TypeId = if (exp_elems) |xe| xe[i] else null;
                    const actual = try self.inferExprExpecting(it, exp_i);
                    elems[i] = if (exp_i) |xi|
                        (if (self.store.get(xi) == .trait_ and self.store.get(actual) == .struct_) xi else actual)
                    else
                        actual;
                }
                return self.ok(try self.store.intern(.{ .tuple = elems }));
            },
            .closure => |cl| {

                // A closure whose param types cannot be pinned from its body alone (e.g.
                // `(a, b) => a + b`, where both params are only used with each other) infers as
                // unresolved on the first pass. closureSecondPass then re-infers it from a call
                // site's argument types and records the resolved `.func` type. On a re-inference
                // with no expected type, reuse that cached resolution instead of recomputing to
                // unresolved again — otherwise the call site (and any local bound to its result)
                // stays untyped, and a later `${r}` picks the wrong stringifier and crashes.
                if (expected == null) {
                    if (self.ir) |ir| {
                        if (ir.typeOf(&e)) |cached| {
                            if (self.store.get(cached) == .func) {
                                const cft = self.store.get(cached).func;
                                var all_resolved = self.store.get(cft.ret) != .unresolved and cft.params.len == cl.params.len;
                                for (cft.params) |pt| {
                                    if (self.store.get(pt) == .unresolved) all_resolved = false;
                                }
                                if (all_resolved) return self.ok(cached);
                            }
                        }
                    }
                }

                const want: ?types.FuncType = if (expected) |x| switch (self.store.get(x)) {
                    .func => |ft| ft,
                    else => null,
                } else null;

                try self.push();
                defer self.pop();
                for (cl.params, 0..) |p, i| {

                    const pt = if (want) |ft|
                        (if (i < ft.params.len and ft.params.len == cl.params.len)
                            ft.params[i]
                        else
                            try self.store.unresolvedT())
                    else
                        try self.store.unresolvedT();
                    try self.bind(p, pt);
                }

                for (cl.params) |p| {
                    if (self.lookup(p)) |cur| {
                        if (self.store.get(cur) != .unresolved) continue;
                        if (try self.paramFromUse(p, cl.body)) |t| self.rebind(p, t);
                    }
                }
                const body_t: TypeId = switch (cl.body) {
                    .expr => |ex| try self.inferExpr(ex),
                    .block => |*b| blk: {

                        const saved_cap = self.captured_return;
                        self.captured_return = null;
                        try self.inferBlock(b);
                        const rt = self.captured_return orelse try self.store.voidT();
                        self.captured_return = saved_cap;
                        break :blk rt;
                    },
                };

                if (want) |ft| {
                    if (ft.params.len == cl.params.len) {

                        const ret = if (self.store.get(ft.ret) == .trait_ and self.store.get(body_t) != .unresolved)
                            ft.ret
                        else if (self.store.get(body_t) != .unresolved)
                            body_t
                        else
                            ft.ret;
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ft.params, .ret = ret } }));
                    }
                }

                {
                    const ps = try self.allocator.alloc(TypeId, cl.params.len);
                    defer self.allocator.free(ps);
                    for (cl.params, 0..) |p, i| {
                        ps[i] = self.lookup(p) orelse try self.store.unresolvedT();
                    }

                    if (self.store.get(body_t) != .unresolved) {
                        return self.ok(try self.store.intern(.{ .func = .{ .params = ps, .ret = body_t } }));
                    }
                }
                return self.unresolved("closure");
            },

            .try_expr => |inner| {
                const it = try self.inferExpr(inner);
                const ity = self.store.get(it);
                if (ity == .error_union) {
                    // `try` re-raises the callee's error UNCHANGED into the enclosing function, so that
                    // error must match the function's declared error type (G5). Only flag when both are
                    // resolved error unions with genuinely different error types.
                    if (self.current_ret) |rt| {
                        const rty = self.store.get(rt);
                        if (rty == .error_union and !self.errorTypesCompatible(ity.error_union.err, rty.error_union.err)) {
                            const sp = if (e.span.line > 0) e.span else inner.span;
                            self.try_error_mismatch_errors.append(self.allocator, .{
                                .span = sp,
                                .callee_err = ity.error_union.err,
                                .fn_err = rty.error_union.err,
                            }) catch {};
                        }
                    }
                    return self.ok(ity.error_union.ok);
                }

                return self.ok(it);
            },

            .catch_expr => |*ce| {
                const it = try self.inferExpr(ce.expr);
                const ity = self.store.get(it);
                if (ity == .error_union) {
                    if (ce.err_name) |n| try self.bind(n, ity.error_union.err);
                    const ok_ty = ity.error_union.ok;
                    // The catch yields the ok type, so the handler value must match it. Infer the
                    // handler with the ok type expected, then verify they unify.
                    const ht = try self.inferExprExpecting(ce.handler, ok_ty);
                    if (!self.catchArmsCompatible(ok_ty, ht)) {
                        const sp = if (ce.handler.span.line > 0) ce.handler.span else ce.expr.span;
                        self.catch_mismatch_errors.append(self.allocator, .{ .span = sp, .ok = ok_ty, .handler = ht }) catch {};
                    }
                    return self.ok(ok_ty);
                }
                _ = try self.inferExpr(ce.handler);
                return self.ok(it);
            },
            .block_expr => |*b| {
                try self.inferBlock(b);
                return self.unresolved("block_expr");
            },
            .generic_call => |g| {

                if (g.callee.kind == .field_access) {
                    const sfa = g.callee.kind.field_access;
                    if (sfa.object.kind == .ident and std.mem.eql(u8, sfa.object.kind.ident, "serde") and g.type_args.len == 1) {
                        if (std.mem.eql(u8, sfa.field, "bind") or std.mem.eql(u8, sfa.field, "bindRow")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            return self.ok(try self.lowerer.lower(g.type_args[0]));
                        }
                        if (std.mem.eql(u8, sfa.field, "bindAll") or std.mem.eql(u8, sfa.field, "bindWire")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            var params = [_]ast.TypeRef{g.type_args[0]};
                            const list_ref = ast.TypeRef{ .generic = .{ .name = "List", .params = &params } };
                            return self.ok(try self.lowerer.lower(list_ref));
                        }
                        if (std.mem.eql(u8, sfa.field, "planFor")) {
                            for (g.args) |*a| _ = try self.inferExpr(a);
                            var params = [_]ast.TypeRef{ast.TypeRef{ .ident = "int" }};
                            const list_ref = ast.TypeRef{ .generic = .{ .name = "List", .params = &params } };
                            return self.ok(try self.lowerer.lower(list_ref));
                        }
                        if (std.mem.eql(u8, sfa.field, "typeName")) {
                            return self.ok(try self.store.stringT());
                        }
                        if (std.mem.eql(u8, sfa.field, "dump")) {

                            for (g.args) |*a| _ = try self.inferExpr(a);
                            return self.ok(try self.store.voidT());
                        }
                    }
                    // FR-mem: the mem byte/bit builtins. mem.load<T>/rotl<T>/rotr<T>/bswap<T> return T;
                    // mem.ctz<T>/clz<T> return int; mem.store<T> returns void. All take T as the single
                    // type argument and lower to one or two LLVM instructions in codegen.
                    if (sfa.object.kind == .ident and std.mem.eql(u8, sfa.object.kind.ident, "mem") and g.type_args.len == 1) {
                        for (g.args) |*a| _ = try self.inferExpr(a);
                        if (std.mem.eql(u8, sfa.field, "load") or std.mem.eql(u8, sfa.field, "rotl") or
                            std.mem.eql(u8, sfa.field, "rotr") or std.mem.eql(u8, sfa.field, "bswap"))
                        {
                            return self.ok(try self.lowerer.lower(g.type_args[0]));
                        }
                        if (std.mem.eql(u8, sfa.field, "ctz") or std.mem.eql(u8, sfa.field, "clz")) {
                            return self.ok(try self.store.intT());
                        }
                        if (std.mem.eql(u8, sfa.field, "store")) {
                            return self.ok(try self.store.voidT());
                        }
                    }
                }
                _ = try self.inferExpr(g.callee);
                self.stats.typed -|= 1;

                var gwant: ?[]TypeId = null;
                if (g.callee.kind == .field_access) gwant = self.calleeParamTypes(g.callee) catch null;
                defer if (gwant) |w| self.allocator.free(w);
                for (g.args, 0..) |*a, i| {
                    const exp: ?TypeId = if (gwant) |w| (if (i < w.len) w[i] else null) else null;
                    _ = try self.inferExprExpecting(a, exp);
                }

                if (g.callee.kind == .field_access) {
                    const bfa = g.callee.kind.field_access;
                    if (bfa.object.kind == .ident and std.mem.eql(u8, bfa.object.kind.ident, "bytes") and
                        g.type_args.len == 1 and
                        (std.mem.eql(u8, bfa.field, "new") or
                            std.mem.eql(u8, bfa.field, "new_persistent") or
                            std.mem.eql(u8, bfa.field, "new_with_allocator")))
                    {
                        return self.ok(try self.lowerer.lower(g.type_args[0]));
                    }
                }

                if (g.callee.kind == .field_access) {
                    var vmsym: ?types.SymbolId = null;
                    if (try self.explicitMethodReturn(g.callee.kind.field_access, g.type_args, g.args, &vmsym)) |mt| {
                        if (vmsym) |mid| if (self.ir) |ir| try ir.recordSym(self.allocator, &e, mid);
                        return self.ok(mt);
                    }
                }

                const tname: ?[]const u8 = switch (g.callee.kind) {
                    .ident => |n| n,
                    .field_access => |fa| fa.field,
                    else => null,
                };
                if (tname) |n| {

                    const args = try self.allocator.alloc(TypeId, g.type_args.len);
                    defer self.allocator.free(args);
                    for (g.type_args, 0..) |ta, i| args[i] = try self.lowerer.lower(ta);

                    if (std.mem.eql(u8, n, "Storage") and args.len == 1) {
                        return self.ok(try self.store.intern(.{ .storage = args[0] }));
                    }
                    if (self.symtab.findTypeInModule(n, self.current_module)) |sid| {
                        return self.ok(try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }));
                    }

                    if (self.symtab.findFunction(n)) |fid| {
                        const sym = self.symtab.symbolAt(fid);
                        if (sym.decl == .function) {
                            const fd = sym.decl.function;
                            const ret = fd.ret_type orelse return self.ok(try self.store.voidT());
                            const saved = self.lowerer.param_scopes;
                            defer self.lowerer.param_scopes = saved;
                            const scope = [_]lower.ParamScope{.{ .owner = fid, .names = fd.type_params }};
                            self.lowerer.param_scopes = &scope;
                            const raw = try self.lowerer.lower(ret);
                            const sub = try subst.substitute(self.store, raw, fid, args);
                            if (self.store.get(sub) != .unresolved) {

                                var all_concrete = fd.type_params.len > 0 and args.len == fd.type_params.len;
                                for (args) |a| {
                                    switch (self.store.get(a)) {
                                        .type_param, .unresolved => all_concrete = false,
                                        else => {},
                                    }
                                }
                                if (all_concrete) {
                                    mono.noteFreeFnInst(self.store, n, fd.type_params, args);
                                }
                                return self.ok(sub);
                            }
                        }
                    }
                }

                return self.unresolved("generic_call");
            },
            .enum_init => |ei| {
                for (ei.fields) |*f| _ = try self.inferExpr(&f.value);
                if (self.symtab.findTypeInModule(ei.enum_name, self.current_module)) |sid| return self.ok(try self.store.intern(.{ .enum_ = sid }));
                return self.unresolved("enum_init");
            },
            .jsx_element => |jsx| {
                // An NSX element lowers to a StringBuilder-built `string` (see compileJsxElement). Infer
                // it as `string` so it composes like any other string: as a `+` operand, a `{expr}` child,
                // or a string-typed argument. Recurse into attribute/child expressions so their own types
                // resolve (and any nested elements get walked).
                try self.inferJsxElement(&jsx);
                return self.ok(try self.store.stringT());
            },
        }
    }

    // Walk an NSX element's attribute-value and child expressions (recursing into nested elements and
    // child statements) so every embedded `{expr}` is type-inferred. The element itself is `string`.
    fn inferJsxElement(self: *Inferer, jsx: *const ast.JsxElement) anyerror!void {
        for (jsx.attributes) |*attr| {
            switch (attr.value) {
                .expression => |*ex| _ = try self.inferExpr(ex),
                .string_literal => {},
            }
        }
        for (jsx.children) |*child| {
            switch (child.*) {
                .element => |*el| try self.inferJsxElement(el),
                .expression => |*ex| _ = try self.inferExpr(ex),
                .statement => |*st| try self.inferStmt(st),
                .text => {},
            }
        }
    }

    fn fnType(self: *Inferer, f: *const ast.FunctionDecl) !TypeId {
        const params = try self.allocator.alloc(TypeId, f.params.len);
        defer self.allocator.free(params);
        for (f.params, 0..) |p, i| {
            params[i] = if (p.type_name) |t| try self.lowerer.lower(t) else try self.store.unresolvedT();
        }
        const ret = if (f.ret_type) |r| try self.lowerer.lower(r) else try self.store.voidT();
        return self.store.intern(.{ .func = .{ .params = params, .ret = ret } });
    }

    fn lowerInStructScope(self: *Inferer, st: types.StructType, tr: ast.TypeRef) !TypeId {
        const sym = self.symtab.symbolAt(st.decl);
        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scope = [_]lower.ParamScope{.{
            .owner = st.decl,
            .names = if (sym.decl == .struct_) sym.decl.struct_.type_params else &.{},
        }};
        self.lowerer.param_scopes = &scope;
        const raw = try self.lowerer.lower(tr);
        return try subst.substitute(self.store, raw, st.decl, st.args);
    }

    fn lowerInMethodScope(
        self: *Inferer,
        st: types.StructType,
        mid: types.SymbolId,
        fd: *const ast.FunctionDecl,
        tr: ast.TypeRef,
    ) !TypeId {
        const owner = self.symtab.symbolAt(st.decl);
        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scopes = [_]lower.ParamScope{
            .{ .owner = st.decl, .names = if (owner.decl == .struct_) owner.decl.struct_.type_params else &.{} },
            .{ .owner = mid, .names = fd.type_params },
        };
        self.lowerer.param_scopes = &scopes;
        const raw = try self.lowerer.lower(tr);

        return try subst.substitute(self.store, raw, st.decl, st.args);
    }

    fn freeFnReturn(
        self: *Inferer,
        fid: types.SymbolId,
        fd: *const ast.FunctionDecl,
        ret_tr: ast.TypeRef,
        arg_types: []const TypeId,
        call_expr: *const ast.Expression,
    ) !?TypeId {

        const saved = self.lowerer.param_scopes;
        defer self.lowerer.param_scopes = saved;
        const scopes = [_]lower.ParamScope{.{ .owner = fid, .names = fd.type_params }};
        self.lowerer.param_scopes = &scopes;

        const sub = try self.lowerer.lower(ret_tr);

        const solved = try self.allocator.alloc(?TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        @memset(solved, null);

        for (fd.params, 0..) |p, i| {
            if (i >= arg_types.len) break;
            const tr = p.type_name orelse continue;
            const dp = try self.lowerer.lower(tr);
            subst.solveParams(self.store, dp, arg_types[i], fid, solved);
        }

        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;
            out = try subst.substituteOne(self.store, out, fid, @intCast(i), bound);
        }

        // B1: register the INFERRED instantiation so codegen emits `fn__T` for a bare call `fn(x)`
        // (the explicit `fn<T>(x)` path already does this at the .generic_call site). Only when every
        // type parameter solved to a concrete type -- a still-abstract type_param arg would poison the
        // monomorphised name and is handled by the enclosing generic's own instantiation instead.
        if (fd.type_params.len > 0 and arg_types.len >= fd.params.len) {
            var all_concrete = true;
            const solved_args = self.allocator.alloc(TypeId, solved.len) catch return out;
            defer self.allocator.free(solved_args);
            for (solved, 0..) |maybe, i| {
                const bound = maybe orelse {
                    all_concrete = false;
                    break;
                };
                switch (self.store.get(bound)) {
                    .type_param, .unresolved => {
                        all_concrete = false;
                    },
                    else => {},
                }
                solved_args[i] = bound;
            }
            if (all_concrete) {
                mono.noteFreeFnInst(self.store, fd.name, fd.type_params, solved_args);
                // Record the SOLVED concrete type args on the call expression so codegen can rebuild the
                // monomorphised name `fn__T` for a bare `fn(x)` call (no explicit `<T>` to mangle from).
                // Reuses the same per-expression side table method calls use.
                if (self.ir) |ir| ir.recordMethodArgs(self.allocator, call_expr, solved_args) catch {};
            }
        }

        return out;
    }

    fn recordOptDeref(self: *Inferer, fa: ast.FieldAccess, is_method: bool, kind: OptDerefKind) void {
        if (std.c.getenv("NOVA_OPT_AUDIT") != null)
            std.debug.print("OPT-SEETHROUGH {s} {s}:{d}:{d} .{s}\n", .{ if (is_method) "method" else "field", fa.span.file, fa.span.line, fa.span.col, fa.field });
        self.optional_deref_errors.append(self.allocator, .{ .span = fa.span, .field = fa.field, .is_method = is_method, .kind = kind }) catch {};
    }

    fn fieldType(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        const obj = try self.inferExpr(fa.object);

        self.stats.typed -|= 1;
        const t = self.store.get(obj);

        if (t == .optional) {
            self.recordOptDeref(fa, false, .opt);
            return null;
        }

        if (t == .error_union) {
            self.recordOptDeref(fa, false, .err);
            return null;
        }
        if (t != .struct_) return null;
        const sym = self.symtab.symbolAt(t.struct_.decl);
        if (sym.decl != .struct_) return null;
        for (sym.decl.struct_.fields) |f| {

            if (std.mem.eql(u8, f.name, fa.field)) {
                return try self.lowerInStructScope(t.struct_, f.type_name);
            }
        }
        return null;
    }

    fn moduleOfObject(self: *Inferer, fa: ast.FieldAccess) ?symbols.ModuleId {
        if (fa.object.kind != .ident) return null;
        const name = fa.object.kind.ident;
        if (self.lookup(name) != null) return null;

        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name)) |mid| return mid;
        }
        return self.symtab.findModuleBySegment(name);
    }

    fn constType(self: *Inferer, name: []const u8) !?TypeId {
        if (self.const_depth > 8) return null;
        for (self.symtab.symbols.items) |sym| {
            if (sym.kind != .constant) continue;
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (sym.decl != .constant) return null;

            if (self.current_module) |cm| {
                if (sym.module != cm and sym.visibility != .public) {
                    const seen = self.visibility_errors.items.len > 0 and blk: {
                        const last = self.visibility_errors.items[self.visibility_errors.items.len - 1];
                        break :blk last.kind == .const_ and std.mem.eql(u8, last.field, name);
                    };
                    if (!seen) self.visibility_errors.append(self.allocator, .{ .span = sym.span, .recv = "", .field = name, .kind = .const_ }) catch {};
                }
            }
            self.const_depth += 1;
            defer self.const_depth -= 1;
            const before = self.stats.typed;
            const t = try self.inferExpr(&sym.decl.constant.value);

            self.stats.typed = before;
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return null;
    }

    fn stringProperty(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (!std.mem.eql(u8, fa.field, "length") and !std.mem.eql(u8, fa.field, "len")) return null;
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        const k = self.store.get(obj);
        if (k != .string and k != .array) return null;   // .length/.len: string byte count OR array element count
        return try self.store.intT();
    }

    fn builtinCallReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;
        if (!builtins.isReceiver(recv)) return null;
        const b = builtins.find(recv, fa.field) orelse return null;
        return try builtins.retType(self.store, b.ret);
    }

    fn recordTypeVis(self: *Inferer, name: []const u8, span: ast.Span) void {

        if (span.file.len > 0 and span.file[0] == '<') return;
        const cm = self.current_module orelse return;
        const sid = self.symtab.findTypeInModule(name, self.current_module) orelse return;
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;

        if (self.visibility_errors.items.len > 0) {
            const last = self.visibility_errors.items[self.visibility_errors.items.len - 1];
            if (last.span.line == span.line and last.span.col == span.col and std.mem.eql(u8, last.field, name)) return;
        }
        self.visibility_errors.append(self.allocator, .{ .span = span, .recv = "", .field = name, .kind = .type_ }) catch {};
    }

    fn checkTypeRefVis(self: *Inferer, tr: ast.TypeRef, span: ast.Span) void {
        switch (tr) {
            .ident => |name| self.recordTypeVis(name, span),
            .optional => |inner| self.checkTypeRefVis(inner.*, span),
            .error_union => |eu| {
                self.checkTypeRefVis(eu.ok.*, span);
                self.checkTypeRefVis(eu.err.*, span);
            },
            .fixed_array => |fa| self.checkTypeRefVis(fa.element.*, span),
            .generic => |g| {
                self.recordTypeVis(g.name, span);
                for (g.params) |p| self.checkTypeRefVis(p, span);
            },
            .func => |f| {
                for (f.params) |p| self.checkTypeRefVis(p, span);
                self.checkTypeRefVis(f.ret.*, span);
            },
            .tuple => |elems| for (elems) |e| self.checkTypeRefVis(e, span),
        }
    }

    fn resolveModuleFn(self: *Inferer, recv: []const u8, field: []const u8, span: ast.Span) ?types.SymbolId {
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, recv)) |mid| {
                if (self.symtab.findFunctionIn(mid, field)) |sid| {
                    self.recordFnVisibility(sid, cm, recv, field, span);
                    return sid;
                }
            }
        }

        if (self.symtab.findFunctionBySegment(recv, field)) |sid| {
            if (self.current_module) |cm| self.recordFnVisibility(sid, cm, recv, field, span);
            return sid;
        }
        return null;
    }

    fn recordFnVisibility(self: *Inferer, sid: types.SymbolId, cm: symbols.ModuleId, recv: []const u8, field: []const u8, span: ast.Span) void {
        const sym = self.symtab.symbolAt(sid);
        if (sym.module == cm or sym.visibility == .public) return;

        const dup = self.visibility_errors.items.len > 0 and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.line == span.line and
            self.visibility_errors.items[self.visibility_errors.items.len - 1].span.col == span.col;
        if (!dup) self.visibility_errors.append(self.allocator, .{ .span = span, .recv = recv, .field = field }) catch {};
    }

    fn isFatalUnresolvedIdent(self: *Inferer, name: []const u8) bool {
        if (std.mem.eql(u8, name, "self")) return false;

        if (std.mem.startsWith(u8, name, "nova_")) return false;

        const magic = [_][]const u8{ "bytes", "console", "sync", "atomic" };
        for (magic) |m| if (std.mem.eql(u8, name, m)) return false;

        if (builtins.isReceiver(name)) return false;

        const builtin_types = [_][]const u8{ "Storage", "Atomic" };
        for (builtin_types) |t| if (std.mem.eql(u8, name, t)) return false;

        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name) != null) return false;
        }
        if (self.symtab.findModuleByImportName(name) != null) return false;
        if (self.symtab.findModuleBySegment(name) != null) return false;
        return true;
    }

    fn isKnownModule(self: *Inferer, name: []const u8) bool {
        if (self.current_module) |cm| {
            if (self.symtab.resolveImportedModule(cm, name) != null) return true;
        }
        if (self.symtab.findModuleByImportName(name) != null) return true;
        if (self.symtab.findModuleBySegment(name) != null) return true;
        return false;
    }

    fn moduleCallReturn(self: *Inferer, fa: ast.FieldAccess, out_sym: *?types.SymbolId) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;

        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;

        out_sym.* = sid;
        if (sym.decl.function.ret_type) |r| {
            // Lower the return type in the CALLEE's module scope, not the caller's. A bare type name in
            // the signature (e.g. `Rec`) must bind to the module that DECLARED the function -- otherwise,
            // when the caller also imports a same-named type, the return value is mistyped to the caller's
            // version and later field access reads the wrong layout (S2). Save/restore the module context.
            const saved_mod = self.lowerer.current_module;
            self.lowerer.current_module = sym.module;
            defer self.lowerer.current_module = saved_mod;
            const t = try self.lowerer.lower(r);
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return try self.store.voidT();
    }

    fn moduleFnValue(self: *Inferer, fa: ast.FieldAccess) !?TypeId {
        if (fa.object.kind != .ident) return null;
        const recv = fa.object.kind.ident;
        if (self.lookup(recv) != null) return null;
        const sid = self.resolveModuleFn(recv, fa.field, fa.span) orelse return null;
        const sym = self.symtab.symbolAt(sid);
        if (sym.decl != .function) return null;
        return try self.fnType(sym.decl.function);
    }

    fn staticMethodReturn(self: *Inferer, fa: ast.FieldAccess) !?TypeId {

        const type_name = switch (fa.object.kind) {
            .ident => |n| n,
            .field_access => |ofa| ofa.field,
            else => return null,
        };

        const tsid = self.symtab.findTypeInModule(type_name, self.current_module) orelse return null;
        const tmod = self.symtab.symbolAt(tsid).module;
        const mid = self.symtab.findMethodInModule(type_name, fa.field, tmod) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();
        const lowered = try self.lowerer.lower(ret);
        if (self.store.get(lowered) == .unresolved) return null;
        return lowered;
    }

    fn methodReturn(self: *Inferer, fa: ast.FieldAccess, args: []const ast.Expression, out_sym: *?types.SymbolId, call_ep: *const ast.Expression) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        const t = self.store.get(obj);

        if (t == .optional) {
            self.recordOptDeref(fa, true, .opt);
            return null;
        }
        if (t == .error_union) {
            self.recordOptDeref(fa, true, .err);
            return null;
        }

        if (t == .trait_) return try self.traitMethodReturn(t.trait_, fa.field);

        if (t == .storage) {
            if (std.mem.eql(u8, fa.field, "get")) return t.storage;
            if (std.mem.eql(u8, fa.field, "set")) return try self.store.voidT();
            return null;
        }

        if (t == .enum_) {
            const owner = self.symtab.symbolAt(t.enum_);
            const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
            out_sym.* = mid;
            const m = self.symtab.symbolAt(mid);
            if (m.decl != .function) return null;
            self.checkMethodArity(m.decl.function.params, args, fa, owner.name, fa.span);
            const ret = m.decl.function.ret_type orelse return try self.store.voidT();
            const lowered = try self.lowerer.lower(ret);
            if (self.store.get(lowered) == .unresolved) return null;
            return lowered;
        }
        if (t != .struct_) return null;
        const owner = self.symtab.symbolAt(t.struct_.decl);
        const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;

        out_sym.* = mid;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        self.checkMethodArity(m.decl.function.params, args, fa, owner.name, fa.span);
        const ret = m.decl.function.ret_type orelse return try self.store.voidT();

        const fd0 = m.decl.function;
        const sub = try self.lowerInMethodScope(t.struct_, mid, fd0, ret);

        const fd = fd0;
        if (fd.type_params.len == 0) {
            if (self.store.get(sub) == .unresolved) return null;
            return sub;
        }
        const solved = try self.allocator.alloc(?TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        @memset(solved, null);

        var declared_l = std.ArrayListUnmanaged(TypeId).empty;
        defer declared_l.deinit(self.allocator);
        for (fd.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            const tr = p.type_name orelse {
                try declared_l.append(self.allocator, try self.store.unresolvedT());
                continue;
            };
            try declared_l.append(self.allocator, try self.lowerInMethodScope(t.struct_, mid, fd, tr));
        }
        const declared = declared_l.items;
        for (declared, 0..) |dp, i| {
            if (i >= args.len) break;

            const actual = try self.inferExprExpecting(&args[i], dp);
            subst.solveParams(self.store, dp, actual, mid, solved);
        }

        var out = sub;
        for (solved, 0..) |maybe, i| {
            const bound = maybe orelse continue;

            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }

        if (self.ir) |ir| {
            var all_concrete = true;
            for (solved) |ma| {
                const mt = ma orelse {
                    all_concrete = false;
                    break;
                };
                const k = self.store.get(mt);
                if (k == .type_param or k == .unresolved) {
                    all_concrete = false;
                    break;
                }
            }
            if (all_concrete) {
                const buf = try self.allocator.alloc(TypeId, solved.len);
                defer self.allocator.free(buf);
                for (solved, 0..) |ma, i| buf[i] = ma.?;
                try ir.recordMethodArgs(self.allocator, call_ep, buf);

                mono.noteMethodInst(self.store, obj, fa.field, fd.type_params, buf);

                mono.noteBaseNeeded(self.store, obj, fa.field);
            }
        }
        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    fn explicitMethodReturn(
        self: *Inferer,
        fa: ast.FieldAccess,
        type_args: []ast.TypeRef,
        args: []const ast.Expression,
        out_sym: *?types.SymbolId,
    ) !?TypeId {
        const obj = try self.inferExpr(fa.object);
        self.stats.typed -|= 1;
        var t = self.store.get(obj);
        if (t == .optional) t = self.store.get(t.optional);
        if (t != .struct_) return null;
        const owner = self.symtab.symbolAt(t.struct_.decl);
        const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
        const m = self.symtab.symbolAt(mid);
        if (m.decl != .function) return null;
        const fd = m.decl.function;

        if (fd.type_params.len == 0 or fd.type_params.len != type_args.len) return null;
        out_sym.* = mid;

        const pts = self.paramTypesOf(fd, t.struct_) catch null;
        defer if (pts) |p| self.allocator.free(p);
        for (args, 0..) |*a, i| {
            const exp: ?TypeId = if (pts) |p| (if (i < p.len) p[i] else null) else null;
            _ = try self.inferExprExpecting(a, exp);
        }

        const ret = fd.ret_type orelse return try self.store.voidT();
        const solved = try self.allocator.alloc(TypeId, fd.type_params.len);
        defer self.allocator.free(solved);
        for (type_args, 0..) |ta, i| solved[i] = try self.lowerer.lower(ta);

        var out = try self.lowerInMethodScope(t.struct_, mid, fd, ret);
        for (solved, 0..) |bound, i| {
            out = try subst.substituteOne(self.store, out, mid, @intCast(i), bound);
        }

        if (self.ir) |_| {
            var all_concrete = true;
            for (solved) |s| {
                const k = self.store.get(s);
                if (k == .type_param or k == .unresolved) {
                    all_concrete = false;
                    break;
                }
            }
            if (all_concrete) {
                mono.noteMethodInst(self.store, obj, fa.field, fd.type_params, solved);
            }
        }

        if (self.store.get(out) == .unresolved) return null;
        return out;
    }

    fn narrowedBranch(self: *Inferer, narrow: ?Narrowing, is_then: bool, branch: *const ast.Statement) anyerror!void {
        const n = narrow orelse return self.inferStmt(branch);
        if (n.when_true != is_then) return self.inferStmt(branch);
        const cur = self.lookup(n.name) orelse return self.inferStmt(branch);
        const t = self.store.get(cur);
        if (t != .optional) return self.inferStmt(branch);
        try self.push();
        defer self.pop();
        try self.bind(n.name, t.optional);
        try self.inferStmt(branch);
    }

    fn calleeParamTypes(self: *Inferer, callee: *const ast.Expression) !?[]TypeId {
        switch (callee.kind) {
            .ident => |n| {
                const sid = self.symtab.findFunction(n) orelse return null;
                const sym = self.symtab.symbolAt(sid);
                if (sym.decl != .function) return null;
                return try self.paramTypesOf(sym.decl.function, null);
            },
            .field_access => |fa| {

                const obj = self.typeOfObjectQuietly(fa.object) orelse return null;
                const t = self.store.get(obj);
                if (t != .struct_) return null;
                const owner = self.symtab.symbolAt(t.struct_.decl);
                const mid = self.symtab.findMethodInModule(owner.name, fa.field, owner.module) orelse return null;
                const m = self.symtab.symbolAt(mid);
                if (m.decl != .function) return null;
                return try self.paramTypesOf(m.decl.function, t.struct_);
            },
            else => return null,
        }
    }

    fn paramTypesOf(self: *Inferer, fd: *const ast.FunctionDecl, recv: ?types.StructType) !?[]TypeId {
        var out = std.ArrayListUnmanaged(TypeId).empty;
        errdefer out.deinit(self.allocator);
        for (fd.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            const tr = p.type_name orelse {
                try out.append(self.allocator, try self.store.unresolvedT());
                continue;
            };
            const t = if (recv) |r|
                try self.lowerInStructScope(r, tr)
            else
                try self.lowerer.lower(tr);
            try out.append(self.allocator, t);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn typeOfObjectQuietly(self: *Inferer, obj: *const ast.Expression) ?TypeId {
        switch (obj.kind) {
            .ident => |n| return self.lookup(n),
            .field_access => |fa| {
                const recv = self.typeOfObjectQuietly(fa.object) orelse return null;
                const t = self.store.get(recv);
                if (t != .struct_) return null;
                const sym = self.symtab.symbolAt(t.struct_.decl);
                if (sym.decl != .struct_) return null;
                for (sym.decl.struct_.fields) |f| {
                    if (std.mem.eql(u8, f.name, fa.field)) {
                        return self.lowerInStructScope(t.struct_, f.type_name) catch return null;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn traitMethodReturn(self: *Inferer, tid: types.SymbolId, field: []const u8) !?TypeId {
        const sym = self.symtab.symbolAt(tid);
        if (sym.decl != .trait_) return null;
        for (sym.decl.trait_.methods) |m| {
            if (!std.mem.eql(u8, m.name, field)) continue;
            const ret = m.ret_type orelse return try self.store.voidT();
            const t = try self.lowerer.lower(ret);
            if (self.store.get(t) == .unresolved) return null;
            return t;
        }
        return null;
    }

    fn paramFromUse(self: *Inferer, param: []const u8, body: ast.ClosureBody) anyerror!?TypeId {
        return switch (body) {
            .expr => |e| try self.paramFromUseExpr(param, e),

            .block => null,
        };
    }

    fn paramFromUseExpr(self: *Inferer, param: []const u8, e: *const ast.Expression) anyerror!?TypeId {
        switch (e.kind) {
            .binary => |b| {
                switch (b.op) {
                    .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or => {},

                    else => return (try self.paramFromUseExpr(param, b.left)) orelse
                        try self.paramFromUseExpr(param, b.right),
                }
                const l_is = b.left.kind == .ident and std.mem.eql(u8, b.left.kind.ident, param);
                const r_is = b.right.kind == .ident and std.mem.eql(u8, b.right.kind.ident, param);
                if (l_is != r_is) {
                    const other = if (l_is) b.right else b.left;
                    const t = try self.inferExprQuietly(other, null);
                    if (self.store.get(t) != .unresolved) return t;

                }

                return (try self.paramFromUseExpr(param, b.left)) orelse
                    try self.paramFromUseExpr(param, b.right);
            },
            .unary => |u| return try self.paramFromUseExpr(param, u.operand),
            else => return null,
        }
    }

    fn inferExprQuietly(self: *Inferer, e: *const ast.Expression, expected: ?TypeId) anyerror!TypeId {
        const saved_ir = self.ir;
        const saved = self.stats.typed;
        // A quiet inference must not leak diagnostics. It is used for look-ahead (e.g. typing a
        // call's arguments before the surrounding locals are bound), so an "undefined identifier"
        // it hits is not a real error — snapshot and restore the fatal-diagnostic counters too.
        const saved_fatal_idents = self.fatal_unresolved_idents;
        const saved_first_ident = self.first_fatal_ident;
        const saved_first_span = self.first_fatal_span;
        const saved_fatal_calls = self.fatal_unresolved_calls;
        const saved_first_call_recv = self.first_fatal_call_recv;
        const saved_first_call_field = self.first_fatal_call_field;
        const saved_first_call_span = self.first_fatal_call_span;
        self.ir = null;
        defer {
            self.ir = saved_ir;
            self.stats.typed = saved;
            self.fatal_unresolved_idents = saved_fatal_idents;
            self.first_fatal_ident = saved_first_ident;
            self.first_fatal_span = saved_first_span;
            self.fatal_unresolved_calls = saved_fatal_calls;
            self.first_fatal_call_recv = saved_first_call_recv;
            self.first_fatal_call_field = saved_first_call_field;
            self.first_fatal_call_span = saved_first_call_span;
        }
        return self.inferExprInner(e.*, expected);
    }

    pub fn inferBlock(self: *Inferer, b: *const ast.Block) anyerror!void {
        try self.push();
        defer self.pop();
        try self.inferStmtSeq(b.statements);
    }

    pub fn inferStmtSeq(self: *Inferer, statements: []ast.Statement) anyerror!void {
        const saved_seq = self.current_stmt_seq;
        self.current_stmt_seq = statements;
        defer self.current_stmt_seq = saved_seq;
        for (statements, 0..) |*s, idx| {
            try self.inferStmt(s);
            if (earlyExitNarrowing(s)) |n| {
                const cur = self.lookup(n.name) orelse continue;
                const t = self.store.get(cur);
                if (t == .optional) {

                    try self.push();
                    defer self.pop();
                    try self.bind(n.name, t.optional);
                    try self.inferStmtSeq(statements[idx + 1 ..]);
                    return;
                }
            }
        }
    }

    pub fn inferStmt(self: *Inferer, sp: *const ast.Statement) anyerror!void {
        switch (sp.*) {
            .block => |*b| try self.inferBlock(b),
            .let_stmt => |*ls| {
                var t: TypeId = undefined;
                if (ls.type_name) |declared| {
                    t = try self.lowerer.lower(declared);
                    self.checkTypeRefVis(declared, ls.span);

                    if (ls.init) |*i| _ = try self.inferExprExpecting(i, t);
                } else if (ls.init) |*i| {
                    // A closure whose param types cannot be pinned from its body alone (e.g.
                    // `let add = (a, b) => a + b`) infers as unresolved on its own. Look ahead to a
                    // call site `name(args)` in this block and use the argument types as the
                    // closure's expected param types, so the closure and any local holding its
                    // result are typed correctly on the first pass.
                    if (i.kind == .closure and i.kind.closure.params.len > 0 and ls.names == null) {
                        if (try self.closureCallExpectation(ls.name, i.kind.closure.params.len)) |exp| {
                            t = try self.inferExprExpecting(i, exp);
                        } else {
                            t = try self.inferExpr(i);
                        }
                    } else {
                        t = try self.inferExpr(i);
                    }
                } else {
                    t = try self.store.unresolvedT();
                }

                if (ls.names) |names| {
                    const ty = self.store.get(t);
                    if (ty == .tuple and ty.tuple.len == names.len) {
                        for (names, ty.tuple) |n, elem_t| try self.bindC(n, elem_t, ls.is_const);
                    } else {
                        for (names) |n| try self.bindC(n, try self.store.unresolvedT(), ls.is_const);
                    }
                } else {
                    try self.bindC(ls.name, t, ls.is_const);
                }
            },
            .expr_stmt => |*es| _ = try self.inferExpr(&es.expr),
            .if_stmt => |*i| {
                try self.checkCond(&i.condition, "if");

                const narrow: ?Narrowing = if (i.condition.kind == .binary)
                    narrowedBinding(i.condition.kind.binary)
                else
                    null;

                try self.narrowedBranch(narrow, true, i.then_branch);
                if (i.else_branch) |e| try self.narrowedBranch(narrow, false, e);
            },
            .while_stmt => |*w| {
                try self.checkCond(&w.condition, "while");
                try self.inferStmt(w.body);
            },
            .for_stmt => |*f| {
                try self.push();
                defer self.pop();

                if (f.initializer) |i| try self.inferStmt(i);
                if (f.condition) |*c| try self.checkCond(c, "for");
                if (f.increment) |*inc| _ = try self.inferExpr(inc);

                if (f.iterator) |*it| {
                    _ = try self.inferExpr(it.iterable);
                    switch (it.binding) {
                        .item => |n| {
                            const elem_t = if (it.iterable.kind == .range) try self.store.intT() else try self.store.unresolvedT();
                            try self.bindC(n, elem_t, false);
                        },
                        .destructure => |d| {
                            try self.bindC(d.key, try self.store.unresolvedT(), false);
                            try self.bindC(d.value, try self.store.unresolvedT(), false);
                        },
                    }
                }
                try self.inferStmt(f.body);
            },
            .switch_stmt => |*sw| {
                const disc_t = try self.inferExpr(&sw.discriminant);
                for (sw.cases) |*c| {

                    try self.bindSwitchPayloads(disc_t, c);
                    for (c.values) |*v| _ = try self.inferExpr(v);
                    if (c.guard) |*g| _ = try self.inferExpr(g);
                    try self.inferStmt(c.body);
                }
                if (sw.default_case) |d| try self.inferStmt(d);
            },
            .return_stmt => |*r| {

                if (r.value) |*v| {
                    const rt = try self.inferExprExpecting(v, self.current_ret);

                    // A1 (C-chk-3): returning an optional where a plain non-optional is declared. `rt` is the
                    // value's type AFTER narrowing, so a guarded `return x` is already non-optional and safe.
                    if (self.current_ret) |crt| {
                        const rtk = self.store.get(rt);
                        const crtk = self.store.get(crt);
                        const declared_plain = crtk != .optional and crtk != .unresolved and
                            crtk != .any_ and crtk != .error_union;
                        if (rtk == .optional and declared_plain) {
                            self.ret_optional_errors.append(self.allocator, .{ .span = v.span, .ret = crt, .val = rt }) catch {};
                        }
                    }

                    if (self.store.get(rt) != .unresolved) self.captured_return = rt;
                }
            },
            .defer_stmt => |*d| _ = try self.inferExpr(&d.expr),
.break_stmt, .continue_stmt => {},
        }
    }

    // A1 (C-chk-4): a control-flow condition must be a `bool`. Infer it (so its subexpressions are still typed
    // and any narrowing bindings are computed by the caller), then reject a resolved non-bool. `.unresolved` is
    // exempt so the incomplete inferrer does not raise false positives on expressions it cannot type.
    fn checkCond(self: *Inferer, cond: *const ast.Expression, ctx: []const u8) !void {
        const t = try self.inferExpr(cond);
        const ty = self.store.get(t);
        const is_bool = ty == .prim and ty.prim.kind == .bool;
        if (!is_bool and ty != .unresolved) {
            self.cond_type_errors.append(self.allocator, .{ .span = cond.span, .got = t, .ctx = ctx }) catch {};
        }
    }

    // A1 (C-chk-1): exact method-call arity. `fnp` includes the leading `self`. Two call forms reach here and
    // pass `self` differently: an INSTANCE call `x.m(a)` passes only the explicit args (self is the receiver,
    // implicit), whereas a STATIC/UFCS call `Type.m(x, a)` passes the receiver as the FIRST explicit arg (self
    // is explicit). We detect the static form by the receiver being the bare owner type name and not a bound
    // local, and count `self` in the expected total there. Nova has no default/variadic params, so this is
    // exact equality once the form is known.
    fn checkMethodArity(self: *Inferer, fnp: []const ast.Param, args: []const ast.Expression, fa: ast.FieldAccess, owner_name: []const u8, span: ast.Span) void {
        const has_self = fnp.len > 0 and std.mem.eql(u8, fnp[0].name, "self");
        const self_explicit = fa.object.kind == .ident and
            self.lookup(fa.object.kind.ident) == null and
            std.mem.eql(u8, fa.object.kind.ident, owner_name);
        var expected: usize = fnp.len;
        if (has_self and !self_explicit) expected -= 1;
        if (args.len != expected) {
            self.method_arity_errors.append(self.allocator, .{ .span = span, .name = fa.field, .expected = expected, .got = args.len }) catch {};
        }
    }

    // FR-safety-6: emit a compile-time WARNING (not an error) at a call site whose callee function carries
    // `@deprecated`, including the optional suggested replacement. Warnings go to stderr and never fail the
    // build, which is the whole point: the stdlib can deprecate `parseI64` in favour of `parseLong`, give
    // users a migration window, then remove it.
    fn warnIfDeprecated(self: *Inferer, fd: *const ast.FunctionDecl, span: ast.Span) void {
        _ = self;
        for (fd.attributes) |attr| {
            switch (attr) {
                .deprecated => |dep_note| {
                    if (dep_note) |msg| {
                        std.debug.print("  \x1b[1m{s}:{d}:{d}: \x1b[33mwarning:\x1b[0m\x1b[1m '{s}' is deprecated: {s}\x1b[0m\n", .{ span.file, span.line, span.col, fd.name, msg });
                    } else {
                        std.debug.print("  \x1b[1m{s}:{d}:{d}: \x1b[33mwarning:\x1b[0m\x1b[1m '{s}' is deprecated\x1b[0m\n", .{ span.file, span.line, span.col, fd.name });
                    }
                    return;
                },
                else => {},
            }
        }
    }

    fn bindSwitchPayloads(self: *Inferer, disc_t: TypeId, c: *const ast.SwitchCase) anyerror!void {
        const dt = self.store.get(disc_t);
        if (dt != .enum_) return;
        const sym = self.symtab.symbolAt(dt.enum_);
        if (sym.decl != .enum_) return;
        const enum_decl = sym.decl.enum_;
        for (c.values) |v| {
            switch (v.kind) {

                .call => |call| {
                    if (call.callee.kind != .field_access) continue;
                    const variant_name = call.callee.kind.field_access.field;
                    for (enum_decl.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, variant_name)) continue;
                        if (variant.type_name) |payload_ref| {
                            if (call.args.len == 0) break;
                            if (call.args[0].kind != .ident) break;
                            try self.bind(call.args[0].kind.ident, try self.lowerer.lower(payload_ref));
                        } else if (variant.fields) |vfields| {
                            // Tuple-form multi-payload pattern `Rect(w, h)`: bind each positional binding to
                            // the matching payload field's type.
                            for (call.args, 0..) |arg, i| {
                                if (i < vfields.len and arg.kind == .ident) {
                                    try self.bind(arg.kind.ident, try self.lowerer.lower(vfields[i].type_name));
                                }
                            }
                        }
                        break;
                    }
                },

                .struct_init => |si| {
                    const tn = si.type_name;
                    const variant_name = if (std.mem.lastIndexOfScalar(u8, tn, '.')) |i| tn[i + 1 ..] else tn;
                    for (enum_decl.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, variant_name)) continue;
                        const vfields = variant.fields orelse break;
                        for (si.fields) |fi| {
                            if (fi.value.kind != .ident) continue;
                            for (vfields) |vf| {
                                if (!std.mem.eql(u8, vf.name, fi.name)) continue;
                                try self.bind(fi.value.kind.ident, try self.lowerer.lower(vf.type_name));
                                break;
                            }
                        }
                        break;
                    }
                },
                else => {},
            }
        }
    }

    pub fn inferFunction(self: *Inferer, f: *const ast.FunctionDecl) !void {
        return self.inferFunctionWithSelf(null, f);
    }

    pub fn inferFunctionWithSelf(self: *Inferer, self_ty: ?TypeId, f: *const ast.FunctionDecl) !void {
        try self.push();
        defer self.pop();

        const saved_module = self.current_module;
        defer self.current_module = saved_module;
        self.current_module = self.symtab.findModuleByFile(f.span.file);
        const saved_lowerer_module = self.lowerer.current_module;
        defer self.lowerer.current_module = saved_lowerer_module;
        self.lowerer.current_module = self.current_module;

        const saved_ret = self.current_ret;
        defer self.current_ret = saved_ret;
        self.current_ret = if (f.ret_type) |r| try self.lowerer.lower(r) else null;
        if (self_ty) |t| try self.bind("self", t);
        for (f.params) |p| {
            const t = if (p.type_name) |tn| try self.lowerer.lower(tn) else try self.store.unresolvedT();
            try self.bind(p.name, t);
        }
        try self.inferStmtSeq(f.body.statements);

        _ = try self.closureSecondPass(&f.body);
    }

    // Recursively search an expression tree for a call `name(args)` with `arity` args, returning
    // the argument types (quietly inferred). Unlike callArgTypesInExpr this descends into every
    // sub-expression (templates, binary ops, casts, ...), so it also finds `${name(a, b)}`.
    fn callArgTypesDeep(self: *Inferer, e: *const ast.Expression, name: []const u8, arity: usize) anyerror!?[]TypeId {
        switch (e.kind) {
            .call => |call| {
                if (call.callee.kind == .ident and std.mem.eql(u8, call.callee.kind.ident, name) and call.args.len == arity) {
                    const out = try self.allocator.alloc(TypeId, arity);
                    for (call.args, 0..) |*a, i| out[i] = try self.inferExprQuietly(a, null);
                    return out;
                }
                if (try self.callArgTypesDeep(call.callee, name, arity)) |r| return r;
                for (call.args) |*a| if (try self.callArgTypesDeep(a, name, arity)) |r| return r;
            },
            .generic_call => |gc| {
                if (try self.callArgTypesDeep(gc.callee, name, arity)) |r| return r;
                for (gc.args) |*a| if (try self.callArgTypesDeep(a, name, arity)) |r| return r;
            },
            .template_expr => |te| for (te.parts) |*p| { if (try self.callArgTypesDeep(p, name, arity)) |r| return r; },
            .binary => |b| {
                if (try self.callArgTypesDeep(b.left, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(b.right, name, arity)) |r| return r;
            },
            .unary => |u| { if (try self.callArgTypesDeep(u.operand, name, arity)) |r| return r; },
            .cast => |c| { if (try self.callArgTypesDeep(c.expr, name, arity)) |r| return r; },
            .nullish_coalesce => |n| {
                if (try self.callArgTypesDeep(n.left, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(n.right, name, arity)) |r| return r;
            },
            .optional_chaining => |o| { if (try self.callArgTypesDeep(o.object, name, arity)) |r| return r; },
            .field_access => |fa| { if (try self.callArgTypesDeep(fa.object, name, arity)) |r| return r; },
            .index => |ix| {
                if (try self.callArgTypesDeep(ix.object, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ix.index, name, arity)) |r| return r;
            },
            .if_expr => |ie| {
                if (try self.callArgTypesDeep(ie.condition, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ie.then_branch, name, arity)) |r| return r;
                if (try self.callArgTypesDeep(ie.else_branch, name, arity)) |r| return r;
            },
            .try_expr => |tx| { if (try self.callArgTypesDeep(tx, name, arity)) |r| return r; },
            .await_expr => |ae| { if (try self.callArgTypesDeep(ae.operand, name, arity)) |r| return r; },
            .go_expr => |ae| { if (try self.callArgTypesDeep(ae.operand, name, arity)) |r| return r; },
            .tuple => |elems| for (elems) |*el| { if (try self.callArgTypesDeep(el, name, arity)) |r| return r; },
            else => {},
        }
        return null;
    }

    // Look ahead in the current statement block for a call `name(args)` matching `arity`, and if
    // found with at least one known argument type, return the expected `.func` type (params =
    // argument types, ret = unresolved). Used to pin a closure's param types on the first pass.
    fn closureCallExpectation(self: *Inferer, name: []const u8, arity: usize) anyerror!?TypeId {
        const stmts = self.current_stmt_seq orelse return null;
        for (stmts) |*s| {
            const ep: ?*const ast.Expression = switch (s.*) {
                .expr_stmt => |*es| &es.expr,
                .let_stmt => |*ls| if (ls.init) |*i| i else null,
                .return_stmt => |*rs| if (rs.value) |*v| v else null,
                else => null,
            };
            if (ep) |e| {
                if (try self.callArgTypesDeep(e, name, arity)) |arg_types| {
                    defer self.allocator.free(arg_types);
                    var any_known = false;
                    for (arg_types) |at| if (self.store.get(at) != .unresolved) { any_known = true; };
                    if (!any_known) continue;
                    return try self.store.intern(.{ .func = .{ .params = arg_types, .ret = try self.store.unresolvedT() } });
                }
            }
        }
        return null;
    }

    fn closureSecondPass(self: *Inferer, fn_body: *const ast.Block) anyerror!bool {
        var retyped_any = false;
        for (fn_body.statements) |*s| {
            if (s.* != .let_stmt) continue;
            const ls = &s.let_stmt;
            const cl_init = if (ls.init) |*i| i else continue;
            if (cl_init.kind != .closure) continue;
            if (try self.retypeBoundClosure(fn_body, ls.name, cl_init)) retyped_any = true;
        }
        return retyped_any;
    }

    fn retypeBoundClosure(self: *Inferer, fn_body: *const ast.Block, name: []const u8, cl_init: *const ast.Expression) anyerror!bool {
        const cl = cl_init.kind.closure;
        if (cl.params.len == 0) return false;

        if (self.ir) |ir| {
            if (ir.typeOf(cl_init)) |t| {
                if (self.store.get(t) == .func) {
                    const ft = self.store.get(t).func;
                    var any_unresolved = false;
                    for (ft.params) |pt| {
                        if (self.store.get(pt) == .unresolved) any_unresolved = true;
                    }
                    if (!any_unresolved) return false;
                }
            }
        }
        const arg_types = (try self.findCallArgTypes(fn_body, name, cl.params.len)) orelse return false;
        defer self.allocator.free(arg_types);

        var any_known = false;
        for (arg_types) |at| if (self.store.get(at) != .unresolved) { any_known = true; };
        if (!any_known) return false;

        const exp = try self.store.intern(.{ .func = .{ .params = arg_types, .ret = try self.store.unresolvedT() } });
        const ct = try self.inferExprExpecting(cl_init, exp);
        // Only worth a re-inference of the enclosing body if we actually produced a resolved func.
        if (self.store.get(ct) == .func and self.store.get(self.store.get(ct).func.ret) != .unresolved) {
            return true;
        }
        return false;
    }

    fn findCallArgTypes(self: *Inferer, block: *const ast.Block, name: []const u8, arity: usize) anyerror!?[]TypeId {
        for (block.statements) |*s| {
            const e: ?*const ast.Expression = switch (s.*) {
                .expr_stmt => |*es| &es.expr,
                .let_stmt => |*ls| if (ls.init) |*i| i else null,
                .return_stmt => |*rs| if (rs.value) |*v| v else null,
                else => null,
            };
            if (e) |ep| {
                if (try self.callArgTypesInExpr(ep, name, arity)) |r| return r;
            }
            switch (s.*) {
                .block => |*b| { if (try self.findCallArgTypes(b, name, arity)) |r| return r; },
                .if_stmt => |*is| {
                    if (try self.findCallArgTypesStmt(is.then_branch, name, arity)) |r| return r;
                    if (is.else_branch) |eb| if (try self.findCallArgTypesStmt(eb, name, arity)) |r| return r;
                },
                .while_stmt => |*ws| { if (try self.findCallArgTypesStmt(ws.body, name, arity)) |r| return r; },
                .for_stmt => |*fs| { if (try self.findCallArgTypesStmt(fs.body, name, arity)) |r| return r; },
                else => {},
            }
        }
        return null;
    }

    fn findCallArgTypesStmt(self: *Inferer, sp: *const ast.Statement, name: []const u8, arity: usize) anyerror!?[]TypeId {
        if (sp.* == .block) return self.findCallArgTypes(&sp.block, name, arity);
        const e: ?*const ast.Expression = switch (sp.*) {
            .expr_stmt => |*es| &es.expr,
            .let_stmt => |*ls| if (ls.init) |*i| i else null,
            .return_stmt => |*rs| if (rs.value) |*v| v else null,
            else => null,
        };
        if (e) |ep| return self.callArgTypesInExpr(ep, name, arity);
        return null;
    }

    fn callArgTypesInExpr(self: *Inferer, ep: *const ast.Expression, name: []const u8, arity: usize) anyerror!?[]TypeId {
        switch (ep.kind) {
            .call => |call| {
                if (call.callee.kind == .ident and std.mem.eql(u8, call.callee.kind.ident, name) and call.args.len == arity) {
                    const out = try self.allocator.alloc(TypeId, arity);
                    for (call.args, 0..) |*a, i| out[i] = try self.inferExprQuietly(a, null);
                    return out;
                }
                for (call.args) |*a| {
                    if (try self.callArgTypesInExpr(a, name, arity)) |r| return r;
                }
            },
            else => {},
        }
        return null;
    }
};

const testing = std.testing;

const Fixture = struct {
    store: types.TypeStore,
    tab: symbols.SymbolTable,
    low: lower.Lowerer,

    fn init(a: std.mem.Allocator) Fixture {
        return .{
            .store = types.TypeStore.init(a),
            .tab = symbols.SymbolTable.init(a),
            .low = undefined,
        };
    }
    fn deinit(self: *Fixture) void {
        self.low.deinit();
        self.tab.deinit();
        self.store.deinit();
    }
};

test "infer: literals get honest types — an int literal is int, not the machine word" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var e_int = ast.Expression{ .kind = .{ .literal = .{ .integer = 42 } } };
    var e_str = ast.Expression{ .kind = .{ .literal = .{ .string = "x" } } };
    var e_bool = ast.Expression{ .kind = .{ .literal = .{ .bool = true } } };
    var e_flt = ast.Expression{ .kind = .{ .literal = .{ .float = 1.5 } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&e_int));
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&e_str));
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&e_bool));
    try testing.expectEqual(try f.store.doubleT(), try inf.inferExpr(&e_flt));
}

test "infer: a comparison is BOOL, not i32" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var cmp_e = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .lt, .span = sp } } };
    const cmp = try inf.inferExpr(&cmp_e);
    try testing.expectEqual(try f.store.boolT(), cmp);
    try testing.expect(cmp != try f.store.intT());
}

test "T4: a binary over two unknowns is UNRESOLVED, not i32" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var l = ast.Expression{ .kind = .{ .ident = "nope" } };
    var r = ast.Expression{ .kind = .{ .ident = "alsonope" } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var add_e = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .add, .span = sp } } };
    const t = try inf.inferExpr(&add_e);
    try testing.expect(f.store.get(t) == .unresolved);
    try testing.expect(t != try f.store.intT());
}

test "infer: a let binding's type flows to its uses" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    try inf.push();
    try inf.bind("s", try f.store.stringT());
    var e_s = ast.Expression{ .kind = .{ .ident = "s" } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&e_s));

    var e_ghost = ast.Expression{ .kind = .{ .ident = "ghost" } };
    const u = try inf.inferExpr(&e_ghost);
    try testing.expect(f.store.get(u) == .unresolved);
}

fn stampIds(a: *ids.Assigner, exprs: []const *ast.Expression) void {
    for (exprs) |e| a.walkExpr(e) catch unreachable;
}

test "TypedIr: records by expression identity and reads back" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var e1 = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var e2 = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{ &e1, &e2 });
    _ = try inf.inferExpr(&e1);
    _ = try inf.inferExpr(&e2);
    try testing.expectEqual(@as(usize, 2), ir.count());

    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e1).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&e2).?);

    var never = ast.Expression{ .kind = .{ .literal = .{ .integer = 3 } } };
    stampIds(&idg, &.{&never});
    try testing.expect(ir.typeOf(&never) == null);
}

test "TypedIr: sub-expressions are recorded too, not just the root" {
    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 2 } } };
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var add = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .add, .span = sp } } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{&add});
    _ = try inf.inferExpr(&add);

    try testing.expectEqual(@as(usize, 3), ir.count());
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&l).?);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(&add).?);
}

test "TypedIr: unresolvedCount is the honest coverage number" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var known = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var unknown = ast.Expression{ .kind = .{ .ident = "ghost" } };
    var idg = ids.Assigner.init();
    stampIds(&idg, &.{ &known, &unknown });
    _ = try inf.inferExpr(&known);
    _ = try inf.inferExpr(&unknown);
    try testing.expectEqual(@as(usize, 2), ir.count());
    try testing.expectEqual(@as(usize, 1), ir.unresolvedCount(&f.store));
}

test "TypedIr: refuses `.unassigned` rather than colliding every un-walked expr on id 0" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);

    var no_id = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var also_no_id = ast.Expression{ .kind = .{ .literal = .{ .string = "x" } } };
    try testing.expectEqual(ast.ExprId.unassigned, no_id.id);

    try ir.record(a, &no_id, try f.store.intT());
    try ir.record(a, &also_no_id, try f.store.stringT());

    try testing.expectEqual(@as(usize, 0), ir.count());
    try testing.expectEqual(@as(usize, 2), ir.unassigned_rejected);

    try testing.expect(ir.typeOf(&also_no_id) == null);
}

test "infer: bitwise `&`/`|` yield the OPERAND type, not bool" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };

    var l = ast.Expression{ .kind = .{ .literal = .{ .integer = 6 } } };
    var r = ast.Expression{ .kind = .{ .literal = .{ .integer = 3 } } };

    var band = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .bit_and, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&band));

    var bor = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .bit_or, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&bor));

    var land = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .And, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&land));

    var lor = ast.Expression{ .kind = .{ .binary = .{ .left = &l, .right = &r, .op = .Or, .span = sp } } };
    try testing.expectEqual(try f.store.boolT(), try inf.inferExpr(&lor));
}

test "infer: assignment yields the assigned VALUE, not void" {

    const a = testing.allocator;
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };

    try inf.push();
    try inf.bind("x", try f.store.intT());
    var lhs = ast.Expression{ .kind = .{ .ident = "x" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .{ .integer = 5 } } };
    var asn = ast.Expression{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .assign, .span = sp } } };

    const t = try inf.inferExpr(&asn);
    try testing.expectEqual(try f.store.intT(), t);
    try testing.expect(t != try f.store.voidT());
}

fn genericListProgram(sp: ast.Span, methods: []ast.MethodDecl) [1]ast.Declaration {
    return [_]ast.Declaration{.{ .struct_decl = .{
        .name = "List",
        .fields = &.{},
        .methods = methods,
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{"T"},
        .span = sp,
    } }};
}

test "F4: `List<string>.get()` is string — substitute T from the RECEIVER's args" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var methods = [_]ast.MethodDecl{.{
        .is_public = true,
        .is_static = false,
        .decl = .{
            .name = "get",
            .params = &.{},
            .ret_type = .{ .ident = "T" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .span = sp,
        },
    }};
    var decls = genericListProgram(sp, &methods);
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    const list_str = try f.low.lower(.{ .generic = .{ .name = "List", .params = &str_args } });
    var int_args = [_]ast.TypeRef{.{ .ident = "int" }};
    const list_int = try f.low.lower(.{ .generic = .{ .name = "List", .params = &int_args } });
    try testing.expect(list_str != list_int);

    try inf.push();
    try inf.bind("list", list_str);
    try inf.bind("nums", list_int);

    var obj_s = ast.Expression{ .kind = .{ .ident = "list" } };
    var fa_s = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_s, .field = "get", .span = sp } } };
    var call_s = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_s, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call_s));

    var obj_i = ast.Expression{ .kind = .{ .ident = "nums" } };
    var fa_i = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj_i, .field = "get", .span = sp } } };
    var call_i = ast.Expression{ .kind = .{ .call = .{ .callee = &fa_i, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call_i));
}

test "F4: a generic FUNCTION call substitutes from its explicit type args" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var decls = [_]ast.Declaration{
        .{ .fn_decl = .{
            .name = "allocCopy",
            .params = &.{},
            .ret_type = .{ .ident = "int" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .type_params = &.{"T"},
            .span = sp,
        } },
        .{ .fn_decl = .{
            .name = "wrap",
            .params = &.{},
            .ret_type = .{ .ident = "T" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .type_params = &.{"T"},
            .span = sp,
        } },
    };
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    try inf.push();

    var ac_callee = ast.Expression{ .kind = .{ .ident = "allocCopy" } };
    var ac_targs = [_]ast.TypeRef{.{ .ident = "int" }};
    var ac = ast.Expression{ .kind = .{ .generic_call = .{
        .callee = &ac_callee,
        .type_args = &ac_targs,
        .args = &.{},
        .span = sp,
    } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&ac));

    var w_callee = ast.Expression{ .kind = .{ .ident = "wrap" } };
    var w_targs = [_]ast.TypeRef{.{ .ident = "string" }};
    var w = ast.Expression{ .kind = .{ .generic_call = .{
        .callee = &w_callee,
        .type_args = &w_targs,
        .args = &.{},
        .span = sp,
    } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&w));
}

test "F4: a generic struct's FIELD substitutes too — `Box<string>.v` is string" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var fields = [_]ast.Field{.{ .name = "v", .type_name = .{ .ident = "T" }, .is_public = true, .span = sp }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Box",
        .fields = &fields,
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{"T"},
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    const box_str = try f.low.lower(.{ .generic = .{ .name = "Box", .params = &str_args } });
    try inf.push();
    try inf.bind("b", box_str);

    var obj = ast.Expression{ .kind = .{ .ident = "b" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "v", .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&fa));
}

test "F4: calling a field that HOLDS a function — `(self.hashFn)(key)`" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    const k_ref = ast.TypeRef{ .ident = "K" };
    var int_ref = ast.TypeRef{ .ident = "int" };
    var k_params = [_]ast.TypeRef{k_ref};
    var fields = [_]ast.Field{.{
        .name = "hashFn",
        .type_name = .{ .func = .{ .params = &k_params, .ret = &int_ref } },
        .is_public = true,
        .span = sp,
    }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Map",
        .fields = &fields,
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{ "K", "V" },
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    var args = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const map_si = try f.low.lower(.{ .generic = .{ .name = "Map", .params = &args } });
    try inf.push();
    try inf.bind("self", map_si);

    var obj = ast.Expression{ .kind = .{ .ident = "self" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "hashFn", .span = sp } } };
    const ft = try inf.inferExpr(&fa);
    try testing.expect(f.store.get(ft) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(ft).func.ret);
    try testing.expectEqual(try f.store.stringT(), f.store.get(ft).func.params[0]);

    const key = ast.Expression{ .kind = .{ .ident = "key" } };
    var call_args = [_]ast.Expression{key};
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &call_args, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call));
}

test "F2: `if (s != undefined)` narrows s inside the branch (specs.md 3.4a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    const str = try f.store.stringT();
    const opt_str = try f.store.intern(.{ .optional = str });
    try inf.push();
    try inf.bind("s", opt_str);

    var lhs = ast.Expression{ .kind = .{ .ident = "s" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .undefined } };
    var o2 = ast.Expression{ .kind = .{ .ident = "s" } };
    const len_in = ast.Expression{ .kind = .{ .field_access = .{ .object = &o2, .field = "length", .span = sp } } };
    var then_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = len_in, .span = sp } }};
    var then_blk = ast.Statement{ .block = .{ .statements = &then_stmts, .span = sp } };
    var if_stmt = ast.Statement{ .if_stmt = .{
        .condition = .{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .ne, .span = sp } } },
        .then_branch = &then_blk,
        .else_branch = null,
        .span = sp,
    } };
    var idg = ids.Assigner.init();
    try idg.walkStmt(&if_stmt);
    try inf.inferStmt(&if_stmt);

    const inner = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    try testing.expectEqual(try f.store.intT(), ir.typeOf(inner).?);

    var o3 = ast.Expression{ .kind = .{ .ident = "s" } };
    var after = ast.Expression{ .kind = .{ .field_access = .{ .object = &o3, .field = "length", .span = sp } } };
    try idg.walkExpr(&after);
    try testing.expect(f.store.get(try inf.inferExpr(&after)) == .unresolved);
}

test "F2: `if (s == undefined)` narrows the ELSE branch (specs.md 3.4a)" {
    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    const str = try f.store.stringT();
    try inf.push();
    try inf.bind("s", try f.store.intern(.{ .optional = str }));

    var lhs = ast.Expression{ .kind = .{ .ident = "s" } };
    var rhs = ast.Expression{ .kind = .{ .literal = .undefined } };
    var o_then = ast.Expression{ .kind = .{ .ident = "s" } };
    const in_then = ast.Expression{ .kind = .{ .field_access = .{ .object = &o_then, .field = "length", .span = sp } } };
    var then_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = in_then, .span = sp } }};
    var then_blk = ast.Statement{ .block = .{ .statements = &then_stmts, .span = sp } };

    var o_else = ast.Expression{ .kind = .{ .ident = "s" } };
    const in_else = ast.Expression{ .kind = .{ .field_access = .{ .object = &o_else, .field = "length", .span = sp } } };
    var else_stmts = [_]ast.Statement{.{ .expr_stmt = .{ .expr = in_else, .span = sp } }};
    var else_blk = ast.Statement{ .block = .{ .statements = &else_stmts, .span = sp } };

    var if_stmt = ast.Statement{ .if_stmt = .{
        .condition = .{ .kind = .{ .binary = .{ .left = &lhs, .right = &rhs, .op = .eq, .span = sp } } },
        .then_branch = &then_blk,
        .else_branch = &else_blk,
        .span = sp,
    } };
    var idg = ids.Assigner.init();
    try idg.walkStmt(&if_stmt);
    try inf.inferStmt(&if_stmt);

    const then_e = &if_stmt.if_stmt.then_branch.block.statements[0].expr_stmt.expr;
    const else_e = &if_stmt.if_stmt.else_branch.?.block.statements[0].expr_stmt.expr;
    try testing.expect(f.store.get(ir.typeOf(then_e).?) == .unresolved);
    try testing.expectEqual(try f.store.intT(), ir.typeOf(else_e).?);
}

test "F2: only a plain BINDING narrows — a field does not (specs.md 3.4a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    try inf.push();
    try inf.bind("s", try f.store.intern(.{ .optional = try f.store.stringT() }));

    var obj = ast.Expression{ .kind = .{ .ident = "s" } };
    var fld = ast.Expression{ .kind = .{ .field_access = .{ .object = &obj, .field = "inner", .span = sp } } };
    var undef = ast.Expression{ .kind = .{ .literal = .undefined } };
    const cond = ast.BinaryExpr{ .left = &fld, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(cond) == null);

    var id = ast.Expression{ .kind = .{ .ident = "s" } };
    const ok_cond = ast.BinaryExpr{ .left = &id, .right = &undef, .op = .ne, .span = sp };
    try testing.expect(narrowedBinding(ok_cond) != null);
    try testing.expectEqualStrings("s", narrowedBinding(ok_cond).?.name);
    try testing.expect(narrowedBinding(ok_cond).?.when_true);
}

test "F2: a closure's params come from the EXPECTED type (specs.md 6.3a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    const k_ref = ast.TypeRef{ .ident = "K" };
    const v_ref = ast.TypeRef{ .ident = "V" };
    var void_ref = ast.TypeRef{ .ident = "void" };
    var kv = [_]ast.TypeRef{ k_ref, v_ref };
    var params = [_]ast.Param{.{
        .name = "fn",
        .type_name = .{ .func = .{ .params = &kv, .ret = &void_ref } },
        .span = sp,
    }};
    var methods = [_]ast.MethodDecl{.{
        .is_public = true,
        .is_static = false,
        .decl = .{
            .name = "forEach",
            .params = &params,
            .ret_type = .{ .ident = "void" },
            .body = .{ .statements = &.{}, .span = sp },
            .is_exported = false,
            .attributes = &.{},
            .span = sp,
        },
    }};
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "Map",
        .fields = &.{},
        .methods = &methods,
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .type_params = &.{ "K", "V" },
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;

    var targs = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const map_si = try f.low.lower(.{ .generic = .{ .name = "Map", .params = &targs } });
    try inf.push();
    try inf.bind("m", map_si);

    var body_k = ast.Expression{ .kind = .{ .ident = "k" } };
    var clo_params = [_][]const u8{ "k", "v" };
    const closure = ast.Expression{ .kind = .{ .closure = .{
        .params = &clo_params,
        .body = .{ .expr = &body_k },
        .span = sp,
    } } };
    var recv = ast.Expression{ .kind = .{ .ident = "m" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "forEach", .span = sp } } };
    var args = [_]ast.Expression{closure};

    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &args, .span = sp } } };

    var idg = ids.Assigner.init();
    try idg.walkExpr(&call);
    _ = try inf.inferExpr(&call);

    const inner = args[0].kind.closure.body.expr;
    try testing.expectEqual(try f.store.stringT(), ir.typeOf(inner).?);
}

test "F2: a method call on a TRAIT receiver resolves (`src.getString(k)`)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var tm = [_]ast.TraitMethodDecl{
        .{ .name = "getString", .params = &.{}, .ret_type = .{ .ident = "string" }, .span = sp },
        .{ .name = "arrayLen", .params = &.{}, .ret_type = .{ .ident = "int" }, .span = sp },
        .{ .name = "close", .params = &.{}, .ret_type = null, .span = sp },
    };
    var decls = [_]ast.Declaration{.{ .trait_decl = .{
        .name = "ValueSource",
        .methods = &tm,
        .is_public = true,
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();

    const vs = try f.low.lower(.{ .ident = "ValueSource" });
    try testing.expect(f.store.get(vs) == .trait_);
    try inf.push();
    try inf.bind("src", vs);

    var recv = ast.Expression{ .kind = .{ .ident = "src" } };
    var fa = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "getString", .span = sp } } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &fa, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.stringT(), try inf.inferExpr(&call));

    var fa2 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "arrayLen", .span = sp } } };
    var call2 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa2, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&call2));

    var fa3 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "close", .span = sp } } };
    var call3 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa3, .args = &.{}, .span = sp } } };
    try testing.expectEqual(try f.store.voidT(), try inf.inferExpr(&call3));

    var fa4 = ast.Expression{ .kind = .{ .field_access = .{ .object = &recv, .field = "nosuch", .span = sp } } };
    var call4 = ast.Expression{ .kind = .{ .call = .{ .callee = &fa4, .args = &.{}, .span = sp } } };
    try testing.expect(f.store.get(try inf.inferExpr(&call4)) == .unresolved);
}

test "F2: `go` yields future<T> and `await` unwraps it (specs.md 7.1)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();

    var decls = [_]ast.Declaration{.{ .fn_decl = .{
        .name = "square",
        .params = &.{},
        .ret_type = .{ .ident = "int" },
        .body = .{ .statements = &.{}, .span = sp },
        .is_exported = false,
        .attributes = &.{},
        .is_async = true,
        .span = sp,
    } }};
    try f.tab.build(.{ .declarations = &decls, .span = sp });
    f.low.symtab = &f.tab;

    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    try inf.push();

    var callee = ast.Expression{ .kind = .{ .ident = "square" } };
    var call = ast.Expression{ .kind = .{ .call = .{ .callee = &callee, .args = &.{}, .span = sp } } };
    var aw_call = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &call, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_call));

    var go_e = ast.Expression{ .kind = .{ .go_expr = .{ .operand = &call, .span = sp } } };
    const h = try inf.inferExpr(&go_e);
    try testing.expect(f.store.get(h) == .future);
    try testing.expectEqual(try f.store.intT(), f.store.get(h).future);
    try testing.expect(h != try f.store.intT());

    try inf.bind("h", h);
    var h_id = ast.Expression{ .kind = .{ .ident = "h" } };
    var aw_h = ast.Expression{ .kind = .{ .await_expr = .{ .operand = &h_id, .span = sp } } };
    try testing.expectEqual(try f.store.intT(), try inf.inferExpr(&aw_h));

    const fut_str = try f.store.intern(.{ .future = try f.store.stringT() });
    try testing.expect(fut_str != h);
}

test "F2: a closure param is inferred from its USE in the body (specs.md 6.3a)" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;
    try inf.push();

    var xi = ast.Expression{ .kind = .{ .ident = "x" } };
    var one = ast.Expression{ .kind = .{ .literal = .{ .integer = 1 } } };
    var body = ast.Expression{ .kind = .{ .binary = .{ .left = &xi, .right = &one, .op = .add, .span = sp } } };
    var params = [_][]const u8{"x"};
    var clo = ast.Expression{ .kind = .{ .closure = .{ .params = &params, .body = .{ .expr = &body }, .span = sp } } };
    var idg = ids.Assigner.init();
    try idg.walkExpr(&clo);
    const t = try inf.inferExpr(&clo);

    try testing.expectEqual(try f.store.intT(), ir.typeOf(&xi).?);

    try testing.expect(f.store.get(t) == .func);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.params[0]);
    try testing.expectEqual(try f.store.intT(), f.store.get(t).func.ret);
}

test "F2: `(a, b) => a + b` stays unresolved — the limit, not a guess" {

    const a = testing.allocator;
    const sp = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "t.nova" };
    var f = Fixture.init(a);
    f.low = lower.Lowerer.init(a, &f.store);
    defer f.deinit();
    var inf = Inferer.init(a, &f.store, &f.tab, &f.low);
    defer inf.deinit();
    var ir = TypedIr{};
    defer ir.deinit(a);
    inf.ir = &ir;
    try inf.push();

    var ai = ast.Expression{ .kind = .{ .ident = "a" } };
    var bi = ast.Expression{ .kind = .{ .ident = "b" } };
    var body = ast.Expression{ .kind = .{ .binary = .{ .left = &ai, .right = &bi, .op = .add, .span = sp } } };
    var params = [_][]const u8{ "a", "b" };
    var clo = ast.Expression{ .kind = .{ .closure = .{ .params = &params, .body = .{ .expr = &body }, .span = sp } } };
    var idg = ids.Assigner.init();
    try idg.walkExpr(&clo);
    _ = try inf.inferExpr(&clo);
    try testing.expect(f.store.get(ir.typeOf(&ai).?) == .unresolved);
    try testing.expect(f.store.get(ir.typeOf(&bi).?) == .unresolved);
}
