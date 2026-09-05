//! Whole-program reachability analysis for demand-driven monomorphisation.
//!
//! Kyte monomorphises generics: `List<int>` becomes a concrete `List_int_*`,
//! not a type-erased body. Left unchecked, the type-driven monomorphiser emits
//! the ENTIRE method surface of every generic instantiation, and measurements
//! showed roughly 93% of the ~28,750 emitted functions were never actually
//! called. This pass computes the set of functions and methods that are truly
//! reachable from the program's roots so codegen can prune everything else,
//! which is what makes builds fast without changing behaviour.
//!
//! The algorithm is a plain worklist mark-and-sweep over the typed IR:
//!
//!   1. Seed the queue with the ROOTS: every ordinary function and every method
//!      of a NON-generic (or generic-but-trait-implementing) struct. Concrete
//!      code is always kept; only a generic struct's own methods are held back
//!      until a call site proves they are wanted. Under test mode, `@test`
//!      functions on generic owners are additionally rooted.
//!   2. Drain the queue: for each reachable function, walk its body AST and
//!      enqueue every callee resolved by [`infer.TypedIr.expr_syms`], plus the
//!      constructors of any struct that is constructed (via `struct_init` or a
//!      call whose callee names a struct type).
//!   3. A fixpoint fixup adds `delete`/`copy` methods of generic owners whose
//!      OTHER methods became reachable. This exists because ARC-inserted
//!      destructor and container copy calls are synthesised in codegen and do
//!      not appear as ordinary call expressions in the source AST, so the walk
//!      alone would miss them and drop a live destructor. Missing that was a
//!      real crash (a pruned vtable destructor of a generic struct).
//!
//! Two consumption paths exist. [`Result`] answers "is this SymbolId reachable"
//! by id, used by codegen when it has the symbol in hand. The module-level
//! [`reachable_keys`] set plus [`methodIsReachable`] answer the same question by
//! `owner|method` NAME string, used from places that only have names; it is
//! populated by [`publish`] and consulted only when [`gate_on`] is set, so with
//! the gate off everything is treated as reachable and nothing is pruned.
//!
//! [`report`] is a report-only diagnostic ("demand-mono shadow") that prints the
//! would-drop percentage and a sample of dropped decls, so a live-but-dropped
//! function can be caught by audit before the pruning is trusted. The pass never
//! mutates the program; it only produces a reachable-set the caller may act on.

const std = @import("std");
/// The AST node definitions (`Program`, `Statement`, `Expression`, ...) that the
/// body walk traverses to discover callees and constructions.
const ast = @import("../ast.zig");
/// The symbol table and [`SymbolId`] definitions this pass keys its reachable set
/// on and iterates to find function/method roots.
const symbols = @import("symbols.zig");
/// The type-inference pass, whose [`infer.TypedIr`] maps call expressions to the
/// callee symbols the mark-and-sweep follows.
const infer = @import("infer.zig");

/// Stable index of a symbol in the [`symbols.SymbolTable`], re-exported here so
/// callers of this module need not reach into `symbols.zig` directly.
const SymbolId = symbols.SymbolId;
/// The semantic-analysis symbol table: the authoritative list of every function,
/// method, struct and so on, indexed by [`SymbolId`]. Reachability is computed
/// over the function/method entries of one such table.
const SymbolTable = symbols.SymbolTable;
/// The typed intermediate representation produced by inference. Its
/// `expr_syms` map is how the body walk resolves a call expression to the
/// [`SymbolId`] of the callee it actually dispatches to.
const TypedIr = infer.TypedIr;

/// The output of [`compute`]: the set of functions/methods reachable from the
/// program roots, plus the totals used by [`report`].
///
/// Owns its `reachable` map; the caller must call [`Result.deinit`] with the
/// same allocator that [`compute`] was given.
pub const Result = struct {
    /// Set of reachable function/method symbols, keyed by [`SymbolId`] (the
    /// value is unit, this is a set, not a map). A [`SymbolId`] present here is
    /// live and must be emitted; anything absent may be pruned by codegen.
    reachable: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    /// Total count of function and method declarations seen in the table. Used
    /// only as the denominator for the would-drop percentage in [`report`].
    total_fn_decls: usize = 0,
    /// Count of reachable function/method declarations, i.e. `reachable.count()`
    /// captured at the end of [`compute`]. Reported against `total_fn_decls`.
    reachable_fn_decls: usize = 0,

    /// Frees the `reachable` map. Pass the allocator used by [`compute`].
    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.reachable.deinit(gpa);
    }

    /// Reports whether the symbol `sid` was found reachable. This is the by-id
    /// query used from codegen when the [`SymbolId`] is already in hand; the
    /// by-name equivalent is [`methodIsReachable`].
    pub fn contains(self: *const Result, sid: SymbolId) bool {
        return self.reachable.contains(sid);
    }
};

/// Global switch for the by-name reachability gate. When false (the default),
/// [`methodIsReachable`] answers true for everything, so pruning is a no-op and
/// the build behaves as if this pass did not run. Codegen turns it on (driven by
/// `KYTE_REACH_ON`) once the reachable set has been [`publish`]ed.
pub var gate_on: bool = false;
/// Module-global set of reachable methods keyed by the string `"owner|method"`,
/// populated by [`publish`] and read by [`methodIsReachable`].
///
/// This exists because some codegen call sites only know the owner and method
/// NAMES, not the [`SymbolId`], so they cannot use [`Result.contains`]. The set
/// stores duped key strings owned with the allocator passed to [`publish`]; it
/// is cleared and rebuilt on each [`publish`], never shrinking its backing
/// capacity ([`clearRetainingCapacity`]).
pub var reachable_keys: std.StringHashMapUnmanaged(void) = .empty;

/// Reports, by NAME, whether a method should be emitted, the by-name twin of
/// [`Result.contains`], consulted from codegen sites that lack the [`SymbolId`].
///
/// Returns true unconditionally when the gate is off ([`gate_on`] false), so
/// disabling the gate disables pruning entirely. Constructors (`init`/`new`) are
/// always considered reachable because they are the roots of construction, and
/// the container `copy` of `List`/`Map`/`Set` is always kept because it is
/// synthesised by ARC on value copies rather than called explicitly and so would
/// otherwise be missed. All other methods are looked up in [`reachable_keys`]
/// under the `"owner_base|method"` key. If formatting that key overflows the
/// fixed 512-byte buffer the function fails OPEN (returns true), preferring to
/// keep a method over risking dropping a live one.
pub fn methodIsReachable(owner_base: []const u8, method: []const u8) bool {
    if (!gate_on) return true;
    if (std.mem.eql(u8, method, "init") or std.mem.eql(u8, method, "new")) return true;
    if (std.mem.eql(u8, method, "copy") and
        (std.mem.eql(u8, owner_base, "List") or std.mem.eql(u8, owner_base, "Map") or std.mem.eql(u8, owner_base, "Set")))
        return true;
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ owner_base, method }) catch return true;
    return reachable_keys.contains(key);
}

/// Projects a computed [`Result`] into the by-name [`reachable_keys`] set so
/// [`methodIsReachable`] can serve name-only queries.
///
/// Clears the previous contents (retaining capacity), then for every reachable
/// function/method symbol inserts a key: `"owner|name"` for methods (an owner is
/// present) or just `name` for free functions. Key strings are allocated with
/// `gpa` and owned by the set. Per-key allocation failures are skipped silently
/// (`catch continue` / `catch {}`) rather than propagated, since a missing key
/// only causes that method to be treated as reachable, which is the safe
/// direction. Call this after [`compute`] and before setting [`gate_on`].
pub fn publish(gpa: std.mem.Allocator, res: *const Result, tab: *const SymbolTable) void {
    reachable_keys.clearRetainingCapacity();
    for (tab.symbols.items, 0..) |sym, i| {
        if (sym.kind != .function and sym.kind != .method) continue;
        const sid: SymbolId = @enumFromInt(@as(u32, @intCast(i)));
        if (!res.reachable.contains(sid)) continue;
        const key = if (sym.owner) |o|
            std.fmt.allocPrint(gpa, "{s}|{s}", .{ o, sym.name }) catch continue
        else
            gpa.dupe(u8, sym.name) catch continue;
        reachable_keys.put(gpa, key, {}) catch {};
    }
}

/// Mutable state threaded through the recursive body walk ([`walkStmt`],
/// [`walkExpr`], etc.).
///
/// Bundles the borrowed inputs (symbol table, typed IR, precomputed name maps)
/// with the two mutable outputs (the reachable set and the worklist queue) so
/// the walk functions can stay free functions taking a single `*Ctx`.
const Ctx = struct {
    /// Allocator for growing the reachable set and the queue.
    gpa: std.mem.Allocator,
    /// The symbol table being analysed (borrowed, read-only).
    tab: *const SymbolTable,
    /// Typed IR whose `expr_syms` resolves call expressions to callee symbols.
    ir: *const TypedIr,
    /// The reachable set being built, points into [`Result.reachable`].
    reachable: *std.AutoHashMapUnmanaged(SymbolId, void),
    /// The worklist of symbols discovered-but-not-yet-walked. [`enqueue`] pushes;
    /// [`compute`]'s drain loop pops from the front.
    queue: *std.ArrayListUnmanaged(SymbolId),
    /// Set of all struct type names, used by [`rootIfConstruction`] to decide
    /// whether a call whose callee is a bare name is actually a constructor call.
    struct_names: *const std.StringHashMapUnmanaged(void),
    /// Map from struct owner name to its constructor (`init`/`new`) symbol ids,
    /// so a construction site can root every matching constructor by name.
    ctors_by_owner: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)),

    /// Marks `sid` reachable and, if it was newly added, pushes it onto the
    /// worklist to be walked. Idempotent: a symbol already in the set is not
    /// re-queued, which is what makes the mark-and-sweep terminate. Allocation
    /// failure is swallowed (the symbol is simply not enqueued).
    fn enqueue(self: *Ctx, sid: SymbolId) void {
        const gop = self.reachable.getOrPut(self.gpa, sid) catch return;
        if (gop.found_existing) return;
        self.queue.append(self.gpa, sid) catch {};
    }

    /// Enqueues every constructor of the struct named `base`, i.e. roots its
    /// `init`/`new` methods. Called when a value of that struct is constructed so
    /// its constructor (which may not appear as an ordinary callee) is kept.
    fn enqueueCtors(self: *Ctx, base: []const u8) void {
        if (self.ctors_by_owner.get(base)) |list| {
            for (list.items) |sid| self.enqueue(sid);
        }
    }

    /// Reports whether `name` is the name of a struct type in this program.
    fn isStructName(self: *Ctx, name: []const u8) bool {
        return self.struct_names.contains(name);
    }
};

/// Strips a monomorphisation/mangling suffix to recover the plain type name.
///
/// A generic instantiation is spelled `List<int>` and a mangled member is
/// spelled `Owner__method`, so this returns everything before the first `<` or
/// `__` (whichever appears), letting the analysis key on the base type name
/// (`List`, `Owner`) regardless of instantiation. Names with neither marker are
/// returned unchanged.
fn baseName(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "<")) |i| return name[0..i];
    if (std.mem.indexOf(u8, name, "__")) |i| return name[0..i];
    return name;
}

/// Computes the reachable function/method set for one program.
///
/// Runs the three-phase mark-and-sweep described in the module header:
///   1. Build helper indexes: `struct_names`, `ctors_by_owner` (constructors per
///      owner), `generic_structs` (structs with type params) and
///      `generic_trait_structs` (those additionally implementing traits).
///   2. Root every function and every method whose owner is not a plain generic
///      struct; a generic struct's own methods are held back, EXCEPT that under
///      `is_test` a generic owner's `@test` methods are still rooted so tests run.
///      Then drain the worklist, walking each rooted body and enqueuing callees
///      and constructors.
///   3. Fixpoint fixup (bounded to 128 passes): for any generic owner whose
///      methods became reachable, additionally root its `delete` method and, for
///      `List`/`Map`/`Set`, its `copy` method, the ARC-synthesised calls the
///      source walk cannot see, re-draining until the set stops growing.
///
/// The returned [`Result`] owns memory and must be freed with [`Result.deinit`].
/// `tab`, `ir` and `program` are borrowed for the duration of the call only.
pub fn compute(
    gpa: std.mem.Allocator,
    tab: *const SymbolTable,
    ir: *const TypedIr,
    program: ast.Program,
    is_test: bool,
) !Result {
    var res = Result{};

    var queue: std.ArrayListUnmanaged(SymbolId) = .empty;
    defer queue.deinit(gpa);

    var struct_names: std.StringHashMapUnmanaged(void) = .empty;
    defer struct_names.deinit(gpa);
    var ctors_by_owner: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)) = .empty;
    defer {
        var vit = ctors_by_owner.valueIterator();
        while (vit.next()) |v| v.deinit(gpa);
        ctors_by_owner.deinit(gpa);
    }
    for (tab.symbols.items, 0..) |sym, i| {
        if (sym.kind == .struct_) {
            struct_names.put(gpa, sym.name, {}) catch {};
        } else if (sym.kind == .method and (std.mem.eql(u8, sym.name, "init") or std.mem.eql(u8, sym.name, "new"))) {
            if (sym.owner) |o| {
                const gop = ctors_by_owner.getOrPut(gpa, o) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(gpa, @enumFromInt(@as(u32, @intCast(i)))) catch {};
            }
        }
    }

    var ctx = Ctx{
        .gpa = gpa,
        .tab = tab,
        .ir = ir,
        .reachable = &res.reachable,
        .queue = &queue,
        .struct_names = &struct_names,
        .ctors_by_owner = &ctors_by_owner,
    };

    var generic_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer generic_structs.deinit(gpa);
    var generic_trait_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer generic_trait_structs.deinit(gpa);
    for (program.declarations) |d| {
        if (d == .struct_decl and d.struct_decl.type_params.len > 0) {
            generic_structs.put(gpa, d.struct_decl.name, {}) catch {};
            if (d.struct_decl.impls.len > 0) {
                generic_trait_structs.put(gpa, d.struct_decl.name, {}) catch {};
            }
        }
    }

    for (tab.symbols.items, 0..) |sym, i| {
        if (sym.kind != .function and sym.kind != .method) continue;
        res.total_fn_decls += 1;
        const sid: SymbolId = @enumFromInt(@as(u32, @intCast(i)));
        const is_generic_method = sym.kind == .method and
            (if (sym.owner) |o| (generic_structs.contains(o) and !generic_trait_structs.contains(o)) else false);
        if (!is_generic_method) {
            ctx.enqueue(sid);
        } else if (is_test and isTestFn(sym)) {
            ctx.enqueue(sid);
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const sid = queue.items[head];
        head += 1;
        const sym = tab.symbolAt(sid);
        const fd: *const ast.FunctionDecl = switch (sym.decl) {
            .function => |f| f,
            else => continue,
        };
        walkBlock(&ctx, fd.body);
    }

    {
        var delete_by_owner: std.StringHashMapUnmanaged(SymbolId) = .empty;
        defer delete_by_owner.deinit(gpa);
        var copy_by_owner: std.StringHashMapUnmanaged(SymbolId) = .empty;
        defer copy_by_owner.deinit(gpa);
        for (tab.symbols.items, 0..) |sym, i| {
            if (sym.kind != .method) continue;
            const owner = sym.owner orelse continue;
            if (!generic_structs.contains(owner)) continue;
            const sid: SymbolId = @enumFromInt(@as(u32, @intCast(i)));
            if (std.mem.eql(u8, sym.name, "delete")) {
                delete_by_owner.put(gpa, owner, sid) catch {};
            } else if (std.mem.eql(u8, sym.name, "copy") and
                (std.mem.eql(u8, owner, "List") or std.mem.eql(u8, owner, "Map") or std.mem.eql(u8, owner, "Set")))
            {
                copy_by_owner.put(gpa, owner, sid) catch {};
            }
        }
        if (delete_by_owner.count() + copy_by_owner.count() > 0) {
            var pending: std.ArrayListUnmanaged(SymbolId) = .empty;
            defer pending.deinit(gpa);
            var pass: usize = 0;
            while (pass < 128) : (pass += 1) {
                const before = res.reachable.count();
                pending.clearRetainingCapacity();
                var rit = res.reachable.keyIterator();
                while (rit.next()) |k| {
                    const s = tab.symbolAt(k.*);
                    if (s.kind != .method) continue;
                    const o = s.owner orelse continue;
                    if (delete_by_owner.get(o)) |del_sid| pending.append(gpa, del_sid) catch {};
                    if (copy_by_owner.get(o)) |cp_sid| pending.append(gpa, cp_sid) catch {};
                }
                for (pending.items) |sid| ctx.enqueue(sid);
                while (head < queue.items.len) {
                    const sid = queue.items[head];
                    head += 1;
                    const sym = tab.symbolAt(sid);
                    const fd: *const ast.FunctionDecl = switch (sym.decl) {
                        .function => |f| f,
                        else => continue,
                    };
                    walkBlock(&ctx, fd.body);
                }
                if (res.reachable.count() == before) break;
            }
        }
    }

    res.reachable_fn_decls = res.reachable.count();
    return res;
}

/// Reports whether a symbol is a `@test` function, by scanning its declaration's
/// attributes for the `test` attribute. Non-function declarations answer false.
/// Used to keep test methods of generic owners reachable in test builds.
fn isTestFn(sym: symbols.Symbol) bool {
    const fd: *const ast.FunctionDecl = switch (sym.decl) {
        .function => |f| f,
        else => return false,
    };
    for (fd.attributes) |a| if (a == .@"test") return true;
    return false;
}

/// Reports whether a symbol's declaration is marked exported (`is_exported`).
/// Non-function declarations answer false. Currently unused by [`compute`]'s
/// rooting logic but kept as a predicate over the same symbol shape.
fn isExported(sym: symbols.Symbol) bool {
    const fd: *const ast.FunctionDecl = switch (sym.decl) {
        .function => |f| f,
        else => return false,
    };
    return fd.is_exported;
}

/// Walks every statement of a block, discovering callees in each. One half of
/// the mutually recursive body traversal with [`walkStmt`] and [`walkExpr`].
fn walkBlock(ctx: *Ctx, b: ast.Block) void {
    for (b.statements) |*s| walkStmt(ctx, s);
}

/// Recursively walks a statement, descending into its sub-statements and
/// expressions so that any call, construction or closure reachable from it is
/// marked. Every statement variant that can contain an expression or nested
/// statement is handled explicitly; `break`/`continue` carry nothing to walk.
fn walkStmt(ctx: *Ctx, s: *const ast.Statement) void {
    switch (s.*) {
        .block => |b| walkBlock(ctx, b),
        .let_stmt => |l| if (l.init) |e| walkExpr(ctx, &e),
        .expr_stmt => |es| walkExpr(ctx, &es.expr),
        .if_stmt => |i| {
            walkExpr(ctx, &i.condition);
            walkStmt(ctx, i.then_branch);
            if (i.else_branch) |eb| walkStmt(ctx, eb);
        },
        .while_stmt => |w| {
            walkExpr(ctx, &w.condition);
            walkStmt(ctx, w.body);
        },
        .for_stmt => |f| {
            if (f.initializer) |init| walkStmt(ctx, init);
            if (f.condition) |c| walkExpr(ctx, &c);
            if (f.increment) |inc| walkExpr(ctx, &inc);
            if (f.iterator) |it| walkExpr(ctx, it.iterable);
            walkStmt(ctx, f.body);
        },
        .switch_stmt => |sw| {
            walkExpr(ctx, &sw.discriminant);
            for (sw.cases) |*c| {
                for (c.values) |*v| walkExpr(ctx, v);
                walkStmt(ctx, c.body);
            }
            if (sw.default_case) |dc| walkStmt(ctx, dc);
        },
        .return_stmt => |r| if (r.value) |e| walkExpr(ctx, &e),
        .defer_stmt => |d| walkExpr(ctx, &d.expr),
        .break_stmt, .continue_stmt => {},
    }
}

/// Recursively walks an expression, marking every function it can reach.
///
/// The core discovery step is at the top: if this expression node has a resolved
/// symbol in [`infer.TypedIr.expr_syms`] (a call whose callee inference pinned
/// down), that callee is enqueued. Expressions with an `unassigned` id carry no
/// resolution and are skipped. The `switch` then recurses into every sub-
/// expression of every variant so nested calls are not missed; `call`/
/// `generic_call` additionally run [`rootIfConstruction`] on their callee, and
/// `struct_init` roots the target type's constructors via [`Ctx.enqueueCtors`].
fn walkExpr(ctx: *Ctx, e: *const ast.Expression) void {
    if (e.id != .unassigned) {
        if (ctx.ir.expr_syms.get(e.id)) |callee| ctx.enqueue(callee);
    }

    switch (e.kind) {
        .literal => |lit| switch (lit) {
            .array => |xs| for (xs) |*x| walkExpr(ctx, x),
            .array_repeat => |ar| walkExpr(ctx, ar.value),
            .object => |fs| for (fs) |*f| walkExpr(ctx, &f.value),
            else => {},
        },
        .ident => {},
        .binary => |b| {
            walkExpr(ctx, b.left);
            walkExpr(ctx, b.right);
        },
        .unary => |u| walkExpr(ctx, u.operand),
        .call => |c| {
            rootIfConstruction(ctx, c.callee);
            walkExpr(ctx, c.callee);
            for (c.args) |*a| walkExpr(ctx, a);
        },
        .generic_call => |c| {
            rootIfConstruction(ctx, c.callee);
            walkExpr(ctx, c.callee);
            for (c.args) |*a| walkExpr(ctx, a);
        },
        .field_access => |fa| walkExpr(ctx, fa.object),
        .index => |ix| {
            walkExpr(ctx, ix.object);
            walkExpr(ctx, ix.index);
        },
        .struct_init => |si| {
            ctx.enqueueCtors(si.type_name);
            for (si.fields) |*f| walkExpr(ctx, &f.value);
        },
        .enum_init => |ei| for (ei.fields) |*f| walkExpr(ctx, &f.value),
        .cast => |cst| walkExpr(ctx, cst.expr),
        .range => |r| {
            walkExpr(ctx, r.start);
            walkExpr(ctx, r.end);
        },
        .optional_chaining => |oc| walkExpr(ctx, oc.object),
        .nullish_coalesce => |nc| {
            walkExpr(ctx, nc.left);
            walkExpr(ctx, nc.right);
        },
        .jsx_element => |je| walkJsx(ctx, je),
        .closure => |cl| switch (cl.body) {
            .expr => |ex| walkExpr(ctx, ex),
            .block => |bl| walkBlock(ctx, bl),
        },
        .tuple => |xs| for (xs) |*x| walkExpr(ctx, x),
        .if_expr => |ie| {
            walkExpr(ctx, ie.condition);
            walkExpr(ctx, ie.then_branch);
            walkExpr(ctx, ie.else_branch);
        },
        .block_expr => |b| walkBlock(ctx, b),
        .try_expr => |t| walkExpr(ctx, t),
        .catch_expr => |ce| {
            walkExpr(ctx, ce.expr);
            walkExpr(ctx, ce.handler);
        },
        .template_expr => |te| for (te.parts) |*p| walkExpr(ctx, p),
        .await_expr => |aw| walkExpr(ctx, aw.operand),
        .go_expr => |ge| walkExpr(ctx, ge.operand),
    }
}

/// If a call's callee names a struct type, roots that struct's constructors.
///
/// A construction like `Point(1, 2)` appears as a `call` whose callee is an
/// identifier (or a `field_access` for a qualified name) naming the type, not a
/// resolved constructor symbol, so the ordinary `expr_syms` lookup misses it.
/// This extracts the callee name, reduces it with [`baseName`], and if it is a
/// known struct name enqueues its constructors. Callees that are not a bare name
/// or field access are ignored.
fn rootIfConstruction(ctx: *Ctx, callee: *const ast.Expression) void {
    const nm: []const u8 = switch (callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => return,
    };
    const base = baseName(nm);
    if (ctx.isStructName(base)) ctx.enqueueCtors(base);
}

/// Walks a JSX element, marking callees inside attribute-value expressions and
/// recursing into child elements, expressions and embedded statements.
///
/// Called from [`walkExpr`] for the `jsx_element` variant. Static string
/// attribute values and plain text children contain no code and are skipped;
/// nested elements recurse back through this function.
fn walkJsx(ctx: *Ctx, je: ast.JsxElement) void {
    for (je.attributes) |attr| switch (attr.value) {
        .expression => |ex| walkExpr(ctx, &ex),
        .string_literal => {},
    };
    for (je.children) |child| switch (child) {
        .element => |el| walkJsx(ctx, el),
        .expression => |ex| walkExpr(ctx, &ex),
        .statement => |st| walkStmt(ctx, &st),
        .text => {},
    };
}

/// Prints the report-only "demand-mono shadow" diagnostic to stderr.
///
/// Shows how many function/method decls exist, how many are reachable, and the
/// would-drop count and percentage, then lists up to 200 sample would-drop decls
/// (`owner.name` or `name`) so a human can audit for anything live but wrongly
/// dropped before the pruning is trusted. This purely observes [`Result`] and
/// the table; it changes nothing. `drop` is clamped at zero to guard against the
/// degenerate case where `reach` exceeds `total`.
pub fn report(res: *const Result, tab: *const SymbolTable) void {
    const out = std.debug.print;
    const total = res.total_fn_decls;
    const reach = res.reachable_fn_decls;
    const drop = if (total >= reach) total - reach else 0;
    out("\n=== [REACH] demand-mono shadow (report-only) ===\n", .{});
    out("  function/method decls : {d}\n", .{total});
    out("  reachable from roots  : {d}\n", .{reach});
    out("  would-drop            : {d}", .{drop});
    if (total > 0) {
        const pct = @as(f64, @floatFromInt(drop)) * 100.0 / @as(f64, @floatFromInt(total));
        out("  ({d:.1}%)\n", .{pct});
    } else out("\n", .{});

    out("  --- sample would-drop decls (audit for live-but-dropped) ---\n", .{});
    var n: usize = 0;
    for (tab.symbols.items, 0..) |sym, i| {
        if (sym.kind != .function and sym.kind != .method) continue;
        const sid: SymbolId = @enumFromInt(@as(u32, @intCast(i)));
        if (res.reachable.contains(sid)) continue;
        if (n >= 200) break;
        if (sym.owner) |o| out("    {s}.{s}\n", .{ o, sym.name }) else out("    {s}\n", .{sym.name});
        n += 1;
    }
    out("=== [REACH] end ===\n", .{});
}
