// Demand-driven monomorphization — reachability pass (Gap 8 / task #205).
//
// Computes the set of function/method DECLS reachable from the program roots via the call graph,
// so codegen can emit only reachable (instantiation x method) pairs instead of the whole method
// surface of every generic instantiation (see docs/design/demand-driven-mono.md).
//
// Reachability is keyed on the DECL (SymbolId), CONTEXT-INSENSITIVE on type arguments: if `List.push`
// is reached from any reachable decl, `push` is kept for EVERY `List<T>` (over-approximate -> sound).
// The same walk drops unreachable subsystems: `aes.encrypt` is reachable only if TLS is reached from a
// root, so a plaintext app never emits the crypto stack.
//
// Phase R0 is report-only (NOVA_REACH_SHADOW): it prints total/reachable/would-drop and the drop list
// so the set can be audited for soundness before emission is gated in R1.

const std = @import("std");
const ast = @import("../ast.zig");
const symbols = @import("symbols.zig");
const infer = @import("infer.zig");

const SymbolId = symbols.SymbolId;
const SymbolTable = symbols.SymbolTable;
const TypedIr = infer.TypedIr;

pub const Result = struct {
    reachable: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,
    total_fn_decls: usize = 0,
    reachable_fn_decls: usize = 0,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.reachable.deinit(gpa);
    }

    pub fn contains(self: *const Result, sid: SymbolId) bool {
        return self.reachable.contains(sid);
    }
};

// ---- Global handoff to codegen (populated in builder.zig/tester.zig, read in collectFunctions) ----
// Keyed by "owner|method" for methods and bare "name" for free functions, using BASE (non-instantiated)
// owner names so the gate keeps a reached method for EVERY instantiation (context-insensitive).
pub var gate_on: bool = false;
pub var reachable_keys: std.StringHashMapUnmanaged(void) = .empty;

/// True if codegen should EMIT this generic method. Conservative: only a non-constructor method of a
/// generic struct whose (owner|method) key is absent from the reachable set is dropped. Everything
/// else (constructors, non-generic, unknown) is kept.
pub fn methodIsReachable(owner_base: []const u8, method: []const u8) bool {
    if (!gate_on) return true;
    if (std.mem.eql(u8, method, "init") or std.mem.eql(u8, method, "new")) return true;
    // Channel 4 (value-semantics): a value struct with a container field deep-copies that field on copy by
    // calling the container's `copy` from codegen -- an edge the call-graph walk does not model (like init/
    // new and vtable dispatch). Keep `copy` for the container types so the monomorphised body is emitted.
    if (std.mem.eql(u8, method, "copy") and
        (std.mem.eql(u8, owner_base, "List") or std.mem.eql(u8, owner_base, "Map") or std.mem.eql(u8, owner_base, "Set")))
        return true;
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ owner_base, method }) catch return true;
    return reachable_keys.contains(key);
}

/// Populate the name-keyed reachable set from a computed Result. Call once after compute().
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

const Ctx = struct {
    gpa: std.mem.Allocator,
    tab: *const SymbolTable,
    ir: *const TypedIr,
    reachable: *std.AutoHashMapUnmanaged(SymbolId, void),
    queue: *std.ArrayListUnmanaged(SymbolId),
    // Prebuilt O(1) indices (built ONCE in compute), so the per-expression walk never linear-scans the
    // symbol table. Without these the walk is O(expressions × symbols) — fine on a 100-symbol test,
    // minutes on a 30k-symbol app.
    struct_names: *const std.StringHashMapUnmanaged(void),
    ctors_by_owner: *const std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)),

    fn enqueue(self: *Ctx, sid: SymbolId) void {
        const gop = self.reachable.getOrPut(self.gpa, sid) catch return;
        if (gop.found_existing) return;
        self.queue.append(self.gpa, sid) catch {};
    }

    // A struct_init / construction of type `base` roots its init+new constructors (they are not
    // referenced through expr_syms — the struct_init expr resolves to the TYPE, not the ctor).
    fn enqueueCtors(self: *Ctx, base: []const u8) void {
        if (self.ctors_by_owner.get(base)) |list| {
            for (list.items) |sid| self.enqueue(sid);
        }
    }

    fn isStructName(self: *Ctx, name: []const u8) bool {
        return self.struct_names.contains(name);
    }
};

// Strip a generic instantiation suffix so `List<int>` / `List__int` reduce to the base name `List`.
fn baseName(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, "<")) |i| return name[0..i];
    if (std.mem.indexOf(u8, name, "__")) |i| return name[0..i];
    return name;
}

/// Compute the reachable decl set. `is_test` picks the roots: build => `main`, test => every @test fn.
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

    // Build O(1) lookup indices ONCE (struct-name set + owner->constructors), so the per-expression walk
    // never linear-scans the symbol table. This is the difference between milliseconds and minutes on a
    // large app.
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

    // The gate ONLY ever prunes methods of GENERIC structs. So everything else — every free function
    // and every method of a NON-generic struct — is kept regardless, and must be walked so that the
    // generic methods IT calls are discovered as reachable. Auto-rooting all of them as walk seeds makes
    // the walk sound against edges expr_syms doesn't model (trait/vtable dispatch, address-taken serde
    // binders, closures passed to higher-order fns): the only thing left to prune is a generic-struct
    // method that NO reachable code calls. Trades a little raw win for provable soundness.
    var generic_structs: std.StringHashMapUnmanaged(void) = .empty;
    defer generic_structs.deinit(gpa);
    // A generic struct that IMPLS a trait has its trait methods invoked through a VTABLE (dynamic
    // dispatch), which is an edge the call-graph walk below does not model. Pruning such a method leaves
    // the vtable slot pointing at a dropped function -> a runtime crash on the first trait call (this was
    // 307_generic_struct_impl_trait / 364_generic_struct_trait_dispatch). So we treat a generic struct
    // with any trait impl as NON-prunable: all its methods are rooted, exactly like a non-generic struct.
    // Over-approximate (a non-trait method of such a struct is kept too) but sound; only affects generic
    // structs that actually implement a trait, so the extra emission is small.
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
        // Seed everything the gate can't prune. Generic-struct methods are left for the walk to reach.
        if (!is_generic_method) {
            ctx.enqueue(sid);
        } else if (is_test and isTestFn(sym)) {
            ctx.enqueue(sid);
        }
    }

    // BFS over the call graph.
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

    // Destructor->`delete` edge (SOUNDNESS, not perf). A struct's SYNTHETIC destructor
    // (codegen `__destruct_<T>`) calls the type's `delete` method (arc.zig), but NO Nova call site
    // references it, so the BFS above never reaches it. For a GENERIC struct that would let demand-mono
    // prune e.g. `RawBuffer<T>.delete`, and codegen then emits a NO-OP `__destruct_RawBuffer_<T>`
    // (LLVMGetNamedFunction finds no delete) -> the element run and every element's owned fields LEAK
    // on drop. (Non-generic `delete` is already seeded, so only generic structs are affected.) Any
    // generic struct with a reachable method is instantiated and therefore destructed, so keep its
    // `delete` and continue the BFS so what `delete` calls (slot, per-element drops, nested delete) is
    // reached too. Iterate to a fixpoint: reaching one `delete` can make a nested generic struct live.
    {
        // index: generic-struct `delete` method decls, by owner base name.
        var delete_by_owner: std.StringHashMapUnmanaged(SymbolId) = .empty;
        defer delete_by_owner.deinit(gpa);
        for (tab.symbols.items, 0..) |sym, i| {
            if (sym.kind != .method) continue;
            if (!std.mem.eql(u8, sym.name, "delete")) continue;
            const owner = sym.owner orelse continue;
            if (!generic_structs.contains(owner)) continue;
            delete_by_owner.put(gpa, owner, @enumFromInt(@as(u32, @intCast(i)))) catch {};
        }
        if (delete_by_owner.count() > 0) {
            var pending: std.ArrayListUnmanaged(SymbolId) = .empty;
            defer pending.deinit(gpa);
            var pass: usize = 0;
            while (pass < 128) : (pass += 1) {
                const before = res.reachable.count();
                // Collect `delete` for every generic struct that owns a reachable method. Collect first,
                // then enqueue — enqueue mutates res.reachable and would invalidate this iterator.
                pending.clearRetainingCapacity();
                var rit = res.reachable.keyIterator();
                while (rit.next()) |k| {
                    const s = tab.symbolAt(k.*);
                    if (s.kind != .method) continue;
                    const o = s.owner orelse continue;
                    if (delete_by_owner.get(o)) |del_sid| pending.append(gpa, del_sid) catch {};
                }
                for (pending.items) |del_sid| ctx.enqueue(del_sid);
                // Drain the BFS so the newly-reachable `delete` bodies pull in their callees.
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

fn isTestFn(sym: symbols.Symbol) bool {
    const fd: *const ast.FunctionDecl = switch (sym.decl) {
        .function => |f| f,
        else => return false,
    };
    for (fd.attributes) |a| if (a == .@"test") return true;
    return false;
}

fn isExported(sym: symbols.Symbol) bool {
    const fd: *const ast.FunctionDecl = switch (sym.decl) {
        .function => |f| f,
        else => return false,
    };
    return fd.is_exported;
}

fn walkBlock(ctx: *Ctx, b: ast.Block) void {
    for (b.statements) |*s| walkStmt(ctx, s);
}

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

fn walkExpr(ctx: *Ctx, e: *const ast.Expression) void {
    // Harvest a resolved symbol reference for THIS expression (call callees, method calls, plain
    // function references all land in expr_syms) and enqueue its decl.
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

// `Type(...)` / `Type<...>(...)` and module-qualified `mod.Type(...)` construct `Type` -> root its
// constructors. The callee is an ident or a field_access whose final segment names a struct.
fn rootIfConstruction(ctx: *Ctx, callee: *const ast.Expression) void {
    const nm: []const u8 = switch (callee.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        else => return,
    };
    const base = baseName(nm);
    if (ctx.isStructName(base)) ctx.enqueueCtors(base);
}

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

/// R0 report-only: print total/reachable/would-drop + the drop list. Gated by NOVA_REACH_SHADOW.
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

    // Print the first N unreachable decls so the drop list can be audited for anything live.
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
