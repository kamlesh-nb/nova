// shadow.zig — F1 stage 1: diff the symbol table against legacy resolution.
//
// Report-only. Runs under NOVA_SEMA_SHADOW=1 and changes NO behaviour — the point
// is to make the blast radius observable BEFORE it is taken (F1 §5 stage 1), since
// today's resolution is nondeterministic and a big-bang cutover would be
// unreviewable.
//
// It answers four questions the design asserts but had not measured:
//
//   A. Do two declarations collide onto one legacy mangled name? Types are keyed by
//      BARE name (llvm_codegen.zig:76-79, `put` with no collision check), so two
//      modules declaring `struct Config` silently overwrite each other.
//   B. Would a suffix scan be AMBIGUOUS — i.e. does the trailing-`_`-match hit two
//      or more different symbols? Those resolve by hash-iteration order: the
//      compiler picks one nondeterministically (F1 §2.3).
//   C. Does a bare name shadow a module-qualified one? This is the class that
//      produced §10 #6 — `f.payload` resolving to a user `fn payload`.
//   D. Is a legacy symbol path-dependent (contains $HOME)? That is F1 §2.2: the
//      same file yields a different linker symbol depending on where it was found.
const std = @import("std");
const ast = @import("../ast.zig");
const symbols = @import("symbols.zig");
const typesys = @import("../types.zig");
const lower = @import("lower.zig");
const infer = @import("infer.zig");
const ownership = @import("ownership.zig");
const sema_mod = @import("sema.zig");

/// F1 stage 2: when set, resolveCalleeName reports every time it falls through to
/// a SUFFIX SCAN, how many candidates matched, and which one it picked. Set from
/// main.zig under NOVA_SEMA_SHADOW=1. Observation only — resolution is unchanged.
pub var trace_resolution: bool = false;
/// Print the shadow reports (NOVA_SEMA_SHADOW=1). Separate from everything else:
/// sema now runs on EVERY compile (stage 4c), and a compiler that narrates its own
/// type inference on every build is unusable. Building and reporting are different
/// decisions.
pub var report_enabled: bool = false;

fn out(comptime fmt: []const u8, args: anytype) void {
    if (report_enabled) std.debug.print(fmt, args);
}
/// F2 stage 4b: codegen READS the TypedIr instead of re-deriving types
/// (NOVA_F2_TYPES=1). Separate from trace_resolution: measuring the difference and
/// taking it are different decisions, and conflating them is how a shadow becomes
/// a cutover nobody reviewed.
pub var f2_types_enabled: bool = false;
/// How many resolutions the cutover actually ANSWERED from the IR, and how many
/// fell back to legacy. Without these, "the IR is byte-identical" is
/// indistinguishable from "the cutover never ran" — which is the same shape as a
/// revert-test that does not build and reports PASS.
pub var f2_served: usize = 0;
pub var render_calls: usize = 0;
pub var render_allocs: usize = 0;
pub var render_bytes: usize = 0;
pub var render_cache_hits: usize = 0;
pub var f2_fellback: usize = 0;
/// Fallbacks where LEGACY had an answer — the only ones that block 4d.
pub var f2_fellback_lossy: usize = 0;
/// F2 stage 3: sema's artefacts, kept alive for codegen's diff. Deliberately
/// leaked for the process lifetime — a compiler run is short and this is
/// shadow-only scaffolding, not the cutover's ownership model.
/// F2 stage 4c: sema's artefacts, OWNED by main (sema/sema.zig) and BORROWED here.
///
/// These were heap-allocated and leaked on purpose — codegen reads them after the
/// shadow returns, so a `defer deinit()` was a use-after-free that only showed up
/// under NOVA_SEMA_SHADOW=1. They are now views into a Sema that main creates and
/// destroys; nothing below owns them.
pub var live_sema: ?*sema_mod.Sema = null;
pub var live_store: ?*typesys.TypeStore = null;
pub var live_ir: ?*infer.TypedIr = null;
pub var scan_hits: usize = 0;
pub var scan_ambiguous: usize = 0;
pub var scan_unresolved: usize = 0;

pub const Divergence = struct {
    kind: enum { legacy_collision, ambiguous_suffix, bare_shadows_qualified, path_dependent_symbol },
    detail: []const u8,
};

/// Report-only. `sm` is OWNED BY THE CALLER (main) and outlives codegen — which is
/// the point of stage 4c: this used to create and leak the table, store and IR
/// because codegen reads them after this returns.
pub fn run(allocator: std.mem.Allocator, program: ast.Program, sm: *sema_mod.Sema) !void {
    live_sema = sm;
    const tab = &sm.tab;
    try tab.build(program);

    out("\n=== F1 shadow: symbol table vs legacy resolution ===\n", .{});
    out("  modules: {d}   symbols: {d}\n", .{ tab.modules.items.len, tab.symbols.items.len });
    for (tab.modules.items) |m| out("    module: path='{s}' file='{s}'\n", .{ m.path, m.file });

    var collisions: usize = 0;
    var ambiguous: usize = 0;
    var shadowed: usize = 0;
    var path_dep: usize = 0;

    // ---- A. two symbols, one legacy mangled name -------------------------
    for (tab.symbols.items, 0..) |a, i| {
        for (tab.symbols.items[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.legacy_mangled, b.legacy_mangled)) continue;
            if (a.kind == .method and b.kind == .method and a.owner != null and b.owner != null and
                std.mem.eql(u8, a.owner.?, b.owner.?)) continue; // same method, collected twice
            collisions += 1;
            const ma = tab.moduleOf(a.module);
            const mb = tab.moduleOf(b.module);
            out("  [COLLISION] legacy symbol '{s}' <- {s}:{d} ({s}.{s}) AND {s}:{d} ({s}.{s})\n", .{
                a.legacy_mangled, a.span.file, a.span.line, ma.path, a.name,
                b.span.file, b.span.line, mb.path, b.name,
            });
        }
    }

    // ---- B. would the suffix scan be ambiguous? --------------------------
    // Legacy: on an exact miss, scan every key for one ending in `_<name>` and take
    // the FIRST in hash order. If 2+ symbols match, the pick is nondeterministic.
    for (tab.symbols.items) |s| {
        if (s.kind != .function) continue;
        var matches: usize = 0;
        var first: ?symbols.Symbol = null;
        for (tab.symbols.items) |t| {
            if (t.kind != .function) continue;
            if (!std.mem.endsWith(u8, t.legacy_mangled, s.name)) continue;
            const pre = t.legacy_mangled.len - s.name.len;
            // the scan requires the char before the match to be '_' (or an exact hit)
            if (pre != 0 and t.legacy_mangled[pre - 1] != '_') continue;
            matches += 1;
            if (first == null) first = t;
        }
        if (matches > 1) {
            ambiguous += 1;
            out("  [AMBIGUOUS] bare '{s}' suffix-matches {d} symbols -> resolved by HASH ORDER\n", .{ s.name, matches });
        }
    }

    // ---- C. a bare (root) name shadowing a module-qualified one ----------
    for (tab.symbols.items) |a| {
        if (a.kind != .function) continue;
        const ma = tab.moduleOf(a.module);
        if (!std.mem.eql(u8, ma.path, "<root>")) continue; // only user/root decls
        for (tab.symbols.items) |b| {
            if (b.kind == .function and !std.mem.eql(u8, tab.moduleOf(b.module).path, "<root>") and
                std.mem.eql(u8, a.name, b.name))
            {
                shadowed += 1;
                out("  [SHADOW] root fn '{s}' ({s}:{d}) shares a bare name with {s}.{s} ({s}:{d})\n", .{
                    a.name, a.span.file, a.span.line,
                    tab.moduleOf(b.module).path, b.name, b.span.file, b.span.line,
                });
            }
        }
    }

    // ---- D2. PREDICT: would the canonical prefix create a NEW collision? ----
    // declarations.zig:737-748 dedups `functions` by name, so a collision created
    // by fixing the prefix would SILENTLY DROP one. Check before cutting over.
    var canon_collisions: usize = 0;
    for (tab.symbols.items, 0..) |a, i| {
        if (a.kind != .function) continue;
        for (tab.symbols.items[i + 1 ..]) |b| {
            if (b.kind != .function) continue;
            if (!std.mem.eql(u8, a.canonical_mangled, b.canonical_mangled)) continue;
            if (std.mem.eql(u8, a.legacy_mangled, b.legacy_mangled)) continue; // already collided
            canon_collisions += 1;
            out("  [NEW-COLLISION] fixing the prefix would map BOTH onto '{s}': {s}:{d} and {s}:{d}\n", .{
                a.canonical_mangled, a.span.file, a.span.line, b.span.file, b.span.line,
            });
        }
    }
    if (canon_collisions == 0) {
        out("  [canonical-prefix] 0 new collisions — the $HOME fix is safe to cut over\n", .{});
    }

    // ---- D. path-dependent / $HOME-bearing legacy symbols ----------------
    for (tab.symbols.items) |s| {
        if (std.mem.indexOf(u8, s.legacy_mangled, "Users_") != null or
            std.mem.indexOf(u8, s.legacy_mangled, "home_") != null)
        {
            path_dep += 1;
            if (path_dep <= 3) {
                out("  [PATH-DEP] legacy symbol embeds an absolute path: '{s}'\n", .{s.legacy_mangled});
            }
        }
    }
    if (path_dep > 3) out("  [PATH-DEP] ... and {d} more\n", .{path_dep - 3});

    out("  --- totals: {d} collisions, {d} ambiguous, {d} shadowed, {d} path-dependent ---\n", .{
        collisions, ambiguous, shadowed, path_dep,
    });
    out("=== end F1 shadow (report only; no behaviour changed) ===\n\n", .{});

    setDiffTable(tab);
    runTypeLowering(allocator, program, tab, sm) catch |e| {
        out("F2 type-lowering shadow failed: {any}\n", .{e});
    };
}

/// F2 stage 2: lower every DECLARED type in the program to a TypeId and report how
/// much of the surface can actually be typed. Report only — nothing consumes it.
///
/// This is the honest measure of what F2 can carry today, and the input that
/// decides stage 4's cutover. Anything that cannot be lowered becomes `.unresolved`
/// — a real, distinct type — never a silent `int`, which is the whole point of T4.
fn runTypeLowering(allocator: std.mem.Allocator, program: ast.Program, tab: *const symbols.SymbolTable, sm: *sema_mod.Sema) !void {
    // Heap-allocated and deliberately LEAKED: codegen's stage-3 diff reads these
    // after this function returns, and a TypeStore copied by value would carry
    // copied hashmaps whose TypeIds index a different table. A compiler run is
    // short and this is shadow-only scaffolding; stage 4 gives sema a real
    // ownership model rather than inheriting this one.
    const store = &sm.store;
    live_store = store;

    // F2-6 enum-variant awareness: teach the store which enums are TAGGED UNIONS (>=1 payload variant
    // -> heap box, OWNED) vs payload-less (immediate tag, NOT owned), so `store.isOwned(.enum_)` decides
    // correctly instead of the coarse `false`. Populated once from the declarations, keyed by the SAME
    // SymbolId the `.enum_` type interns under (`tab.findType`). Not gated by report_enabled — it is a
    // correctness input to `isOwned`, which the sema ownership pass and the flip both consult.
    for (program.declarations) |decl| {
        if (decl != .enum_decl) continue;
        const ed = decl.enum_decl;
        const sid = tab.findType(ed.name) orelse continue;
        var tagged = false;
        for (ed.variants) |v| {
            if (v.type_name != null or v.fields != null) {
                tagged = true;
                break;
            }
        }
        store.setEnumTagged(sid, tagged) catch {};
    }

    var l = lower.Lowerer.init(allocator, store);
    l.symtab = tab; // the F1<->F2 join

    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |f| {
                // `owner` is what makes `List<T>`'s T a DIFFERENT type from
                // `Map<K,V>`'s K. Leaving it unset collapsed every param onto one
                // TypeId; lower.zig now refuses an ownerless param outright.
                const fscope = [_]lower.ParamScope{.{
                    .owner = tab.findFunction(f.name) orelse continue,
                    .names = f.type_params,
                }};
                l.param_scopes = &fscope;
                for (f.params) |p| {
                    if (p.type_name) |t| _ = try l.lower(t);
                }
                if (f.ret_type) |r| _ = try l.lower(r);
                l.param_scopes = &.{};
            },
            .struct_decl => |sd| {
                const ssym = tab.findType(sd.name) orelse continue;
                const sscope = [_]lower.ParamScope{.{ .owner = ssym, .names = sd.type_params }};
                l.param_scopes = &sscope;
                for (sd.fields) |fld| _ = try l.lower(fld.type_name);
                for (sd.methods) |m| {
                    // A method sees the STRUCT's type params AND ITS OWN:
                    //     pub fn map<U>(self: List<T>, fn: (T) => U): List<U>
                    // `T` comes from `struct List<T>`, `U` from the method. Using
                    // only the struct's params left every `U` unresolved — which is
                    // exactly what the first run of this report showed (6 x "U"),
                    // and it was a gap in THIS harness, not in the compiler.
                    // TWO scopes, not one merged list: in `fn map<U>(self: List<T>)`
                    // T is {List, 0} and U is {map, 0} — each index 0 of its OWN
                    // declaration. Merging made U into {List, 1}, an index List does
                    // not have, so it never substituted. Innermost last.
                    const mscopes = [_]lower.ParamScope{
                        .{ .owner = ssym, .names = sd.type_params },
                        .{ .owner = tab.findMethod(sd.name, m.decl.name) orelse ssym, .names = m.decl.type_params },
                    };
                    l.param_scopes = &mscopes;
                    for (m.decl.params) |p| {
                        if (p.type_name) |t| _ = try l.lower(t);
                    }
                    if (m.decl.ret_type) |r| _ = try l.lower(r);
                    l.param_scopes = &sscope;
                }
            },
            else => {},
        }
    }
    l.param_scopes = &.{};

    const total = l.stats.lowered + l.stats.unresolved;
    out("=== F2 shadow: declared-type surface ===\n", .{});
    out("  declared types seen : {d}\n", .{total});
    out("  lowered to a TypeId : {d}\n", .{l.stats.lowered});
    out("  UNRESOLVED          : {d}\n", .{l.stats.unresolved});
    out("  distinct types interned: {d}\n", .{store.count()});

    // Report the distinct names F2 cannot yet type, most common first — that list
    // IS stage 4's remaining work.
    var seen = std.StringHashMap(usize).init(allocator);
    defer seen.deinit();
    for (l.stats.unresolved_names.items) |n| {
        const gop = try seen.getOrPut(n);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    out("  distinct unresolved names: {d}\n", .{seen.count()});
    var it = seen.iterator();
    var shown: usize = 0;
    while (it.next()) |e| {
        if (shown >= 12) break;
        out("    {s} (x{d})\n", .{ e.key_ptr.*, e.value_ptr.* });
        shown += 1;
    }
    // ---- F2 stage 2c: the EXPRESSION surface -----------------------------
    var inf = infer.Inferer.init(allocator, store, tab, &l);
    defer inf.deinit();
    // Stage 2i: persist what inference computes, so codegen can READ instead of
    // re-deriving at every use site.
    const ir = &sm.ir;
    live_ir = ir;
    inf.ir = ir;
    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |f| {
                const efscope = [_]lower.ParamScope{.{
                    .owner = tab.findFunction(f.name) orelse continue,
                    .names = f.type_params,
                }};
                l.param_scopes = &efscope;
                walked_fns.put(allocator, f.name, {}) catch {};
                inf.inferFunction(&f) catch { walk_errors += 1; };
            },
            .enum_decl => |ed| {
                // Enums have methods too. The walk's `else => {}` skipped them
                // entirely, so every expression in an enum method was invisible to
                // sema while codegen still compiled it — which is part of the
                // "not in the IR" count the stage-3 diff surfaced.
                const self_ty: ?infer.TypeId = blk: {
                    const sid = tab.findTypeInModule(ed.name, tab.findModuleByFile(ed.span.file)) orelse break :blk null;
                    break :blk try store.intern(.{ .enum_ = sid });
                };
                for (ed.methods) |m| {
                    inf.inferFunctionWithSelf(self_ty, &m.decl) catch { walk_errors += 1; };
                }
            },
            .struct_decl => |sd| {
                // Bind `self` to the owning struct: a constructor's body uses it
                // without declaring it (parser.zig:470).
                // F1 module-scoped types: resolve THIS struct's own symbol (module-scoped), so a colliding
                // `Widget` binds `self` to the Widget declared in THIS module — not the global first-match.
                const sd_mod = tab.findModuleByFile(sd.span.file);
                const self_ty: ?infer.TypeId = blk: {
                    const sid = tab.findTypeInModule(sd.name, sd_mod) orelse break :blk null;
                    break :blk try store.intern(.{ .struct_ = .{ .decl = sid } });
                };
                const esym = tab.findTypeInModule(sd.name, sd_mod) orelse continue;
                for (sd.methods) |m| {
                    const escopes = [_]lower.ParamScope{
                        .{ .owner = esym, .names = sd.type_params },
                        .{ .owner = tab.findMethod(sd.name, m.decl.name) orelse esym, .names = m.decl.type_params },
                    };
                    l.param_scopes = &escopes;
                    inf.inferFunctionWithSelf(self_ty, &m.decl) catch { walk_errors += 1; };
                }
            },
            else => {},
        }
    }
    l.param_scopes = &.{};

    // F1-4 VISIBILITY ENFORCEMENT: a cross-module reference to a non-pub symbol is a hard error
    // (NOT gated by report_enabled — it is enforcement, not a shadow diagnostic). The corpus is clean
    // (0 violations once `pub fn` was honored), so this rejects only genuine over-reaches.
    if (inf.visibility_errors.items.len > 0) {
        // Abort HERE (like isRefCountedType's placeholder abort) rather than returning an error for a
        // caller to handle: sema runs on every compile before codegen, so exiting here rejects the
        // program cleanly with the located diagnostic already shown — no dependence on which pipeline
        // (cmdTest / compileProgram) invoked us or whether it propagates the error.
        for (inf.visibility_errors.items) |ve| {
            switch (ve.kind) {
                .function => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}.{s}' is not public — a non-`pub` function cannot be called from another module. Mark it `pub`, or call it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.recv, ve.field },
                ),
                .type_ => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}' is not public — a non-`pub` type cannot be used from another module. Mark it `pub`, or use it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.field },
                ),
                .const_ => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}' is not public — a non-`pub` const cannot be read from another module. Mark it `pub`, or read it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.field },
                ),
            }
        }
        std.process.exit(1);
    }

    // `const` IMMUTABILITY ENFORCEMENT: reassigning a `const` binding is a hard error (the
    // enforced-immutable half of the two-keyword `let`/`const` model). Enforcement, not a shadow
    // diagnostic — same reject-here pattern as visibility above.
    if (inf.const_reassign_errors.items.len > 0) {
        // Same header the type checker prints, so the UX (and the conformance classifier, which keys
        // "typecheck" off this line) treat it uniformly with every other typecheck error.
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.const_reassign_errors.items.len});
        for (inf.const_reassign_errors.items) |ce| {
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m cannot assign to '{s}' — it is a `const`. Use `let` for a variable you reassign.\x1b[0m\n",
                .{ ce.span.file, ce.span.line, ce.span.col, ce.name },
            );
        }
        std.process.exit(1);
    }

    // H2 OPTIONAL SOUNDNESS: a bare member access on a `T | undefined` value is a hard error —
    // the value must be made present first. Same reject-here pattern + "Type checking failed"
    // header (so the conformance classifier keys it as `typecheck`).
    if (inf.optional_deref_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.optional_deref_errors.items.len});
        for (inf.optional_deref_errors.items) |oe| {
            const what = if (oe.is_method) "method" else "field";
            switch (oe.kind) {
                .opt => std.debug.print(
                    "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '.{s}' — {s} access on a possibly-`undefined` value. Make it present first: `xs.at(i)` / `x ?? default` / `x?.{s}` / narrow with `if (x != undefined) {{ … }}`.\x1b[0m\n",
                    .{ oe.span.file, oe.span.line, oe.span.col, oe.field, what, oe.field },
                ),
                .err => std.debug.print(
                    "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '.{s}' — {s} access on a `T | E` value that may be an ERROR. Handle it first: `try x` (propagate) or `x catch <fallback>` (specs §3.4b).\x1b[0m\n",
                    .{ oe.span.file, oe.span.line, oe.span.col, oe.field, what },
                ),
            }
        }
        std.process.exit(1);
    }

    // GENERIC-UFCS GUARDRAIL: a GENERIC free function whose first parameter is `self` is a UFCS method
    // on a generic receiver (`fn push<T>(self: Container<T>, …)`). The checker does not solve `self`'s
    // type parameter at the call site, so `x.m()` on such a receiver would SILENTLY not type — the
    // exact class that hid the `Array<T>` cascade. A generic type's methods must live in its body
    // (as List/Map/Set do); non-generic UFCS (`fn hash(self: string)`) is fine and unaffected. Turn
    // the silent gap into a located error (specs §4.2).
    {
        var count: usize = 0;
        for (program.declarations) |decl| {
            if (decl != .fn_decl) continue;
            const f = decl.fn_decl;
            if (f.type_params.len == 0 or f.params.len == 0) continue;
            if (!std.mem.eql(u8, f.params[0].name, "self")) continue;
            if (count == 0) std.debug.print("Type checking failed with error(s):\n", .{});
            count += 1;
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m generic method `{s}` must be defined INSIDE its type's body — a free `fn {s}<…>(self: …)` on a generic receiver is not resolvable (put a generic type's methods in the struct, like List/Map/Set).\x1b[0m\n",
                .{ f.span.file, f.span.line, f.span.col, f.name, f.name },
            );
        }
        if (count > 0) std.process.exit(1);
    }

    // F2-5 FATAL: a genuinely-undefined identifier (not a value, type, runtime extern, or namespace)
    // is a hard error at end of sema — the .unresolved-fatal the stage is named for. Measured 0 across
    // the whole corpus (validated by isFatalUnresolvedIdent's exclusions: modules / magic builtins /
    // self / container types / nova_* externs), so this rejects only genuine typos. Undefined idents
    // were already caught at codegen ("Identifier not found"); this moves the check earlier, to sema.
    if (inf.fatal_unresolved_idents > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m undefined identifier '{s}'\x1b[0m (and {d} more) — not a value, type, module, or known builtin. (F2-5)\n",
            .{ inf.first_fatal_ident orelse "?", inf.fatal_unresolved_idents - 1 },
        );
        std.process.exit(1);
    }

    const etotal = inf.stats.typed + inf.stats.unresolved;
    const pct: usize = if (etotal == 0) 0 else (inf.stats.typed * 100) / etotal;
    out("=== F2 shadow: EXPRESSION surface ===\n", .{});
    out("  expressions seen : {d}\n", .{etotal});
    out("  typed            : {d}  ({d}%)\n", .{ inf.stats.typed, pct });
    out("  UNRESOLVED       : {d}\n", .{inf.stats.unresolved});
    // F2-6 stage 0: split UNRESOLVED into NOT-A-VALUE (namespace: modules/builtins/container-types,
    // and accesses on them) vs the GENUINE coverage debt. The namespace count is not a gap — a
    // complete typed IR marks those `namespace`, it does not type them. `genuine` is the real
    // denominator F2-6 stage 1 drives toward 0.
    const ns = inf.stats.unresolved_ns_ident + inf.stats.unresolved_ns_field;
    const genuine = inf.stats.unresolved -| ns;
    out("    namespace (not-a-value: module/builtin/access-on-them) : {d}\n", .{ns});
    out("    GENUINE (the real F2-6 coverage debt)                  : {d}\n", .{genuine});
    out("  F2-5 GENUINE-UNDEFINED idents (fatal-ready, must be 0) : {d}\n", .{inf.fatal_unresolved_idents});
    // Which GENUINE shapes fail (namespace subtracted from ident/field_access) — this names the next
    // increment stage 1 must close, instead of guessing at it.
    out("  -- GENUINE shapes (by_tag, namespace subtracted) --\n", .{});
    var bt = inf.stats.by_tag.iterator();
    while (bt.next()) |e| {
        var v = e.value_ptr.*;
        if (std.mem.eql(u8, e.key_ptr.*, "ident")) v -|= inf.stats.unresolved_ns_ident;
        if (std.mem.eql(u8, e.key_ptr.*, "field_access")) v -|= inf.stats.unresolved_ns_field;
        if (v > 0) out("    {s}: {d}\n", .{ e.key_ptr.*, v });
    }
    out("  -- names behind the failures --\n", .{});
    var bn = inf.stats.by_name.iterator();
    var shown2: usize = 0;
    while (bn.next()) |e| {
        if (shown2 >= 16) break;
        out("    {s} (x{d})\n", .{ e.key_ptr.*, e.value_ptr.* });
        shown2 += 1;
    }
    // The authoritative numbers: the IR is a SET keyed by expression identity, so
    // each expression counts once. The stats above are event counters and
    // over-count re-visits — worth keeping only because they name the SHAPES.
    const rec = ir.count();
    const unres = ir.unresolvedCount(store);
    const rpct: usize = if (rec == 0) 0 else ((rec - unres) * 100) / rec;
    out("    walk errors (functions sema failed to walk) : {d}\n", .{walk_errors});
    out("  -- TypedIr (authoritative: distinct expressions) --\n", .{});
    out("    recorded   : {d}\n", .{rec});
    out("    typed      : {d}  ({d}%)\n", .{ rec - unres, rpct });
    out("    unresolved : {d}\n", .{unres});
    // F1 stage 3b groundwork: how many CALLs sema resolved to a SymbolId (recorded in the IR for
    // codegen to consult instead of the func_map suffix scan). Drive this UP toward the total call
    // count before the scan is deleted — the same shadow-then-cutover discipline as expr_types.
    out("    calls->SymbolId (F1-3b) : {d}\n", .{ir.expr_syms.count()});
    out("=== end F2 shadow (report only) ===\n\n", .{});

    // F2-6 stage 5 step 2: the OWNERSHIP PASS (arc.md §5) — turn the disposition (step 1) into actual
    // dup/drop/move OPS on owned `let`-locals and run the §6.1 STATIC BALANCE CHECK. Report-only;
    // codegen behaviour is untouched. Runs only under --shadow (like every diagnostic here), so it adds
    // zero cost to a normal build. The precondition that made step 1 land — TypeId ownership, no
    // strings — is what this consumes: every owned-local decision comes from `store.isOwnedSafe`.
    if (report_enabled) {
        const os = ownership.analyze(allocator, store, ir, &program);
        out("=== F2-6 stage 5 step 2: ownership pass (owned-local dup/drop + balance check) ===\n", .{});
        out("  functions walked                     : {d}\n", .{os.fns_walked});
        out("  owned let-locals                     : {d}\n", .{os.owned_locals});
        out("    analyzed (balance claim made+held) : {d}\n", .{os.analyzed});
        out("    deferred (nested CFG/reassign/shadow — increment 2) : {d}\n", .{os.deferred_cfg});
        out("    deferred (init untyped in IR — coverage gap)        : {d}\n", .{os.deferred_untyped});
        out("  ops inserted : drop={d}  move-out={d}  dup={d}\n", .{ os.drop_ops, os.move_outs, os.dup_ops });
        out("  BALANCE VIOLATIONS (use-after-move; MUST be 0)        : {d}\n", .{os.balance_violations});
        if (os.balance_violations > 0) out("    first: owned local '{s}'\n", .{os.first_violation});
        // Owned TEMPORARIES: every owned producer occurrence gets a consumer — MOVED into a
        // bind/return/aggregate, or DROPPED at the enclosing statement's end. Completeness is measured
        // against the disposition oracle: `ownedOf==true` marks EVERY owned occurrence (closure interiors
        // now descended too), so `accounted == total` means the pass gave EVERY owned value a consumer.
        const temp_accounted = os.temp_moves + os.temp_drops;
        const temp_total = ir.ownedTrueCount();
        const tpct: usize = if (temp_total == 0) 100 else (temp_accounted * 100) / temp_total;
        out("  owned TEMPORARIES: move={d}  drop={d}  accounted={d}/{d} ({d}%)  unaccounted={d}\n", .{ os.temp_moves, os.temp_drops, temp_accounted, temp_total, tpct, temp_total -| temp_accounted });
        out("=== end ownership pass ===\n\n", .{});

        // FOUNDATION GATE (F2-6 ownership pass, 2026-07-19). The static balance check has teeth for BOTH
        // owned-value classes now, and both are ENFORCED here:
        //   1. LOCALS — the CFG last-use analysis proves each owned local is consumed exactly once on
        //      every path; a use-after-MOVE is a real UAF and MUST be 0 (teeth: a synthetic `let b=a;
        //      use(a)` is flagged).
        //   2. TEMPORARIES — an owned temp is single-use in the source (anonymous), so it cannot be
        //      used-after-move; its balance risk is a MISSED temp (a leak-shaped hole the pass never
        //      saw). So the invariant is COMPLETENESS: every owned occurrence the disposition oracle
        //      counts MUST have a pass op (move/drop). `accounted < total` means a construct produced an
        //      owned temp the pass did not account for — exactly where an un-dropped leak would hide.
        // A future construct that breaks either invariant fails the build here, not at a runtime leak
        // months later — the same "nothing bites" enforcement as the disposition gate.
        if (os.balance_violations > 0 or temp_accounted < temp_total) {
            std.debug.print(
                "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F2-6 ownership balance):\x1b[0m\x1b[1m an owned value is not provably consumed exactly once\x1b[0m\n" ++
                "  LOCALS use-after-move violations : {d}   (MUST be 0 — a use-after-move is a UAF)\n" ++
                "  TEMPORARIES unaccounted          : {d}   (MUST be 0 — an owned temp with no move/drop is a leak-shaped hole)\n" ++
                "  first local violation: '{s}'\n" ++
                "  The static balance check found an owned value the pass cannot prove is consumed exactly\n" ++
                "  once. That is the leak / use-after-free class this pass exists to catch AT BUILD TIME.\n",
                .{ os.balance_violations, temp_total -| temp_accounted, os.first_violation },
            );
            std.process.exit(1);
        }
    }
}

/// F1 stage 2: totals from the instrumented resolveCalleeName. Printed after
/// codegen, since the counters accumulate during it.
pub fn reportResolution() void {
    if (!trace_resolution) return;
    std.debug.print("\n=== F1 shadow: resolveCalleeName suffix-scan usage ===\n", .{});
    std.debug.print("  fell through to a SUFFIX SCAN : {d}\n", .{scan_hits});
    std.debug.print("  ...of those, AMBIGUOUS (>1 candidate) : {d}\n", .{scan_ambiguous});
    std.debug.print("  resolved to NOTHING (silent failure)  : {d}\n", .{scan_unresolved});
    std.debug.print("=== end ===\n\n", .{});
}


// ---------------------------------------------------------------------------
// F2 stage 3: diff the TypedIr against the legacy resolver, on every real
// expression codegen asks about.
// ---------------------------------------------------------------------------
// ── string→TypeId migration: the shadow-diff harness ───────────────────────────────────────────
// At every OWNERSHIP decision (isOwnedTypeId), compute BOTH answers — the typed `store.isOwned(t)`
// and the legacy `isRefCountedType(renderLegacy(t))` — and classify the site. This is the safety net
// for the whole migration: `td_disagree` MUST stay 0 (a concrete type the two engines disagree on is
// a real bug); `td_blocked_*` quantifies EXACTLY what the keystone (type_param) + F2-5 (unresolved) +
// enum-awareness must clear before the string engine can be deleted. Report-only under NOVA_SEMA_SHADOW.
pub var td_agree: usize = 0; // concrete type, both engines agree — already convertible
pub var td_disagree: usize = 0; // concrete type, engines DIFFER — a bug to fix before cutover
pub var td_blocked_typeparam: usize = 0; // has instantiation ctx but unresolved — a METHOD-level param (map<U>)
pub var td_blocked_noctx: usize = 0; // no instantiation ctx (erased-body compile) — resolves when erased body goes
pub var td_keystone_resolves: usize = 0; // KEYSTONE SHADOW: substituting against current_instantiation gives a concrete type whose ownership AGREES with today's string answer — i.e. the keystone would convert this site correctly
pub var td_keystone_disagree: usize = 0; // substitutes concrete but DISAGREES — a keystone bug to fix
pub var td_blocked_unresolved: usize = 0; // needs F2-5 (unresolved fatal)
pub var td_blocked_enum: usize = 0; // needs isOwned enum-variant awareness
/// F2-6 stage 5: does the CHECKER's ownership disposition (TypedIr.expr_owned) agree with codegen's
/// `acquisitionDisposition`? disagree must reach a known, small residue (payload-enum coarseness)
/// before the checker can OWN the decision and the balance check runs on it.
pub var disp_agree: usize = 0;
pub var disp_disagree: usize = 0;
/// Which known keystone gap a disposition disagreement falls into (classified by the type the
/// CHECKER assigned). `.other` is the tripwire: any disagreement NOT explained by one of the two
/// documented gaps, which the report surfaces with a sample.
pub const DispResidue = enum { type_param, enum_, other };
pub var disp_disagree_typeparam: usize = 0;
pub var disp_disagree_enum: usize = 0;
pub var disp_disagree_other: usize = 0;
pub var disp_last_kind: []const u8 = "";
pub var disp_last_type: []const u8 = "";

/// F2-6 stage 5 step 5 (codegen cutover, shadow half): at codegen's EXACT temp sites — a `drop` in
/// `drainTemporaries`, a `move` in `consumeTemporary` — does codegen's action match the op the pass
/// recorded for that ExprId? This is the §7.1 per-site shadow for the temp construct; agreement is the
/// license to flip codegen to obey the pass (delete the `pending_temps` heuristic). `no_op` counts temps
/// with no recorded pass op (explicitly-registered temps the pass never saw — not a disagreement).
pub var op_agree: usize = 0;
pub var op_disagree: usize = 0;
pub var op_disagree_cg_drop: usize = 0; // codegen DROPPED, pass said MOVE
pub var op_disagree_cg_move: usize = 0; // codegen MOVED, pass said DROP
pub var op_no_op: usize = 0;
pub var op_last_disagree: []const u8 = "";
pub var td_last_disagree: []const u8 = "";
pub var td_last_disagree_typed: bool = false;
pub var td_last_disagree_string: bool = false;

// F2-6 stage 4: is a temp's stored destructor `type_name` derivable from its TypeId (via `expr_id`)?
// Proving `dtor_name_disagree == 0` corpus-wide is the precondition for keying destructors on the
// TypeId (and deleting the stored string), because a divergent destructor NAME is CORRUPTION, not a
// leak. Report-only; the `no_id` bucket is temps the pass never id'd (registered outside the choke
// point) — not a divergence, just unmeasurable here.
pub var dtor_name_agree: usize = 0;
pub var dtor_name_disagree: usize = 0;
pub var dtor_name_no_id: usize = 0;
pub var dtor_name_last_disagree_string: []const u8 = "";
pub var dtor_name_last_disagree_typed: []const u8 = "";
// The RAW render (no substTypeParams). raw_disagree==0 means the concrete TypeId already carries the
// resolved type, so substTypeParams is redundant at the drain — the deletion target.
pub var dtor_name_raw_agree: usize = 0;
pub var dtor_name_raw_disagree: usize = 0;
pub var dtor_name_raw_last: []const u8 = "";
// Do a tuple's STORE elements (st.get(t).tuple) match the string-PARSE (getTupleElementType) — same
// arity, per-element ownership, and rendered name? disagree==0 is the gate to build the tuple destructor
// from the store elements (dropping getTupleElementType's fragile depth-aware string parse).
pub var tuple_elem_agree: usize = 0;
pub var tuple_elem_disagree: usize = 0;
pub var tuple_elem_last: []const u8 = "";
// Same store-vs-parse gate for the err-union payload arms and the storage element (before those
// builders read ok/err/elem from the store instead of parsing `ErrUnion(ok,err)` / `Storage<T>`).
pub var erru_elem_agree: usize = 0;
pub var erru_elem_disagree: usize = 0;
pub var erru_elem_last: []const u8 = "";
pub var storage_elem_agree: usize = 0;
pub var storage_elem_disagree: usize = 0;
pub var storage_elem_last: []const u8 = "";
// Struct FIELDS: does the store-resolved concrete field TypeId (lower-in-struct-scope + subst) match
// substituteFieldType (the string T→concrete)? disagree==0 is the gate to build the struct destructor
// from store field TypeIds — the increment that also retires substituteFieldType + storageElem.
pub var struct_field_agree: usize = 0;
pub var struct_field_disagree: usize = 0;
pub var struct_field_last: []const u8 = "";
pub var a2_irct_calls: usize = 0;
pub var a2_irct_composite: usize = 0;
// Stage 5 Phase A: at a release site with a known TypeId, does the TypeId's destructor SYMBOL match the
// string path's? `flip` = same symbol, selected via the store-native builder (the cutover). `split` = the
// two-renderer i32/int class — symbols would DIFFER, so kept on the string path (safe) until stage-6
// renderer unification. `no_id` = no usable TypeId, string fallback. split>0 is expected, not a bug.
pub var phaseA_flip: usize = 0;
pub var phaseA_split: usize = 0;
pub var phaseA_no_id: usize = 0;
pub var phaseA_split_last: []const u8 = "";

pub fn reportTypeIdDiff() void {
    if (!report_enabled) return;
    const concrete = td_agree + td_disagree;
    const blocked = td_blocked_typeparam + td_blocked_unresolved + td_blocked_enum;
    out("\n=== string→TypeId shadow-diff: ownership decisions (isOwnedTypeId) ===\n", .{});
    out("  decisions seen : {d}\n", .{concrete + blocked});
    out("  CONCRETE (TypeId can decide) : {d}\n", .{concrete});
    out("    agree    : {d}\n", .{td_agree});
    out("    DISAGREE : {d}   (MUST be 0 before cutover)\n", .{td_disagree});
    if (td_disagree > 0) out("      e.g. '{s}' typed={} string={}\n", .{ td_last_disagree, td_last_disagree_typed, td_last_disagree_string });
    out("  NOT-CONCRETE (keystone cannot substitute) : {d}\n", .{blocked + td_keystone_resolves + td_keystone_disagree});
    out("    .type_param KEYSTONE-RESOLVES : {d}  (subst in store -> concrete, AGREES with string) ✅\n", .{td_keystone_resolves});
    out("    .type_param keystone-DISAGREE : {d}  (MUST be 0 — a keystone bug)\n", .{td_keystone_disagree});
    out("    .type_param method-param      : {d}  (map<U> — decided by PRINCIPLED ERASURE RULE: unbound -> non-owned) ✅\n", .{td_blocked_typeparam});
    out("    .type_param no-inst-ctx       : {d}  (erased body — decided by PRINCIPLED ERASURE RULE: unbound -> non-owned) ✅\n", .{td_blocked_noctx});
    out("    .unresolved  : {d}  (F2-5: unresolved fatal)\n", .{td_blocked_unresolved});
    out("    .enum_       : {d}  (isOwned enum-variant awareness)\n", .{td_blocked_enum});
    out("=== end string→TypeId shadow-diff ===\n\n", .{});

    // F2-6 stage 5 step 5: the ownership PASS's per-temp op vs what CODEGEN actually did, keyed by ExprId
    // at the exact site (drop=drainTemporaries, move=consumeTemporary). disagree MUST reach a known set
    // before codegen can be flipped to obey the pass. `no_op` = temps the pass never recorded (explicitly
    // registered, e.g. the try-payload / downcast-struct sites) — expected, not a disagreement.
    if (op_agree + op_disagree + op_no_op > 0) {
        out("=== F2-6 stage 5 step 5: temp ops — codegen action vs pass op (per ExprId) ===\n", .{});
        out("  agree    : {d}  (codegen's drop/move matches the pass)\n", .{op_agree});
        out("  DISAGREE : {d}  (MUST be a known set before the flip)\n", .{op_disagree});
        out("    codegen DROPPED, pass said move : {d}  (return retain+drop / trait-coercion copy+drop — pass is right, the FLIP removes codegen's redundancy)\n", .{op_disagree_cg_drop});
        out("    codegen MOVED, pass said drop   : {d}  (constructor/consuming args — needs the arc.md §3 `consuming` mark the pass lacks)\n", .{op_disagree_cg_move});
        if (op_disagree > 0) out("    last-disagree type: {s}\n", .{op_last_disagree});
        out("  no pass op: {d}  (explicitly-registered temps the pass never saw — expected)\n", .{op_no_op});
        // F2-6 stage 4: is a DROPPED temp's destructor NAME recoverable from its TypeId (via expr_id)?
        // Proving DISAGREE==0 corpus-wide is the precondition for keying the destructor on the TypeId and
        // dropping the stored `type_name` — a divergent destructor name is corruption, not a leak.
        out("  stage 4 dtor-name from TypeId: agree={d}  DISAGREE={d}  (MUST be 0 to key on TypeId)  no-id={d}\n", .{ dtor_name_agree, dtor_name_disagree, dtor_name_no_id });
        if (dtor_name_disagree > 0) out("    last disagree: string='{s}'  typed='{s}'\n", .{ dtor_name_last_disagree_string, dtor_name_last_disagree_typed });
        out("  stage 4 RAW (no substTypeParams): agree={d}  DISAGREE={d}  (0 ⇒ substTypeParams redundant at drain)\n", .{ dtor_name_raw_agree, dtor_name_raw_disagree });
        if (dtor_name_raw_disagree > 0) out("    last raw-only: rendered='{s}'\n", .{dtor_name_raw_last});
        out("  stage 4 tuple elems store-vs-parse: agree={d}  DISAGREE={d}  (0 ⇒ build tuple dtor from store elements)\n", .{ tuple_elem_agree, tuple_elem_disagree });
        if (tuple_elem_disagree > 0) out("    last tuple mismatch: '{s}'\n", .{tuple_elem_last});
        out("  stage 4 erru arms store-vs-parse: agree={d}  DISAGREE={d}\n", .{ erru_elem_agree, erru_elem_disagree });
        if (erru_elem_disagree > 0) out("    last erru mismatch: '{s}'\n", .{erru_elem_last});
        out("  stage 4 storage elem store-vs-parse: agree={d}  DISAGREE={d}\n", .{ storage_elem_agree, storage_elem_disagree });
        if (storage_elem_disagree > 0) out("    last storage mismatch: '{s}'\n", .{storage_elem_last});
        out("  stage 4 struct fields store-vs-parse: agree={d}  DISAGREE={d}  (0 ⇒ build struct dtor from store fields)\n", .{ struct_field_agree, struct_field_disagree });
        if (struct_field_disagree > 0) out("    last struct mismatch: '{s}'\n", .{struct_field_last});
        out("  stage 5 PhaseA release-site flip: flip={d} (store-native selected)  split={d} (i32/int, kept string)  no-id={d}\n", .{ phaseA_flip, phaseA_split, phaseA_no_id });
        if (phaseA_split > 0) out("    last split: '{s}'\n", .{phaseA_split_last});
        out("  a2 isRefCountedType calls: {d}  (string ownership decisions still made — target: only primitives/erased)\n", .{a2_irct_calls});
        out("  a2 isRefCountedType COMPOSITE (parser path): {d}\n", .{a2_irct_composite});
        out("=== end temp-op diff ===\n\n", .{});
    }

    // F2-6 stage 5 (balance-check step 1): does the CHECKER's recorded disposition agree with
    // codegen's `acquisitionDisposition`? This is the precondition for the static balance check —
    // the checker cannot own the ownership decision (dup/drop ops, linear-use check) unless it
    // agrees with the ground truth codegen acts on. Report-only for now: a nonzero disagree is the
    // known enum-awareness residue (payload enums read coarsely by `store.isOwned`), not yet a gate.
    const disp_total = disp_agree + disp_disagree;
    if (disp_total > 0) {
        out("=== F2-6 stage 5: checker ownership-disposition vs codegen acquisitionDisposition ===\n", .{});
        out("  occurrences compared : {d}\n", .{disp_total});
        out("    agree    : {d}\n", .{disp_agree});
        out("    DISAGREE : {d}   (all in the SAFE direction: checker under-claims owned, never over-claims)\n", .{disp_disagree});
        out("      .type_param (generic erased return -> codegen monomorphizes to owned; closes with F4) : {d}\n", .{disp_disagree_typeparam});
        out("      .enum_      (payload enum — CLOSED: isOwned is now variant-aware via the enum_tagged table) : {d}\n", .{disp_disagree_enum});
        out("      OTHER       (unexplained — a real disposition bug; MUST be 0)                            : {d}\n", .{disp_disagree_other});
        if (disp_disagree_other > 0) out("        e.g. kind='{s}' type='{s}'\n", .{ disp_last_kind, disp_last_type });
        out("=== end disposition shadow-diff ===\n\n", .{});
    }

    // FOUNDATION GATE (F2-6 disposition oracle, 2026-07-19). The checker's recorded ownership
    // DISPOSITION is the source codegen now OBEYS (the flip). It agrees with codegen's
    // acquisitionDisposition on EVERY occurrence except ONE characterized, correct boundary:
    // `.type_param` from ERASED CONTAINER METHODS (`Storage<T>.get` in an erased List/Map body), where
    // the checker applies the erasure rule (unbound T = non-owned) and codegen monomorphizes the body
    // (T = the concrete instantiation = owned). Both are correct for their vantage point; the
    // `principledDisposition` fallback covers it and `--arc`/`--asan` prove it leak-free. THAT boundary
    // is allowed. But `.enum_` disagreements are now impossible (isOwned is variant-aware), and `.other`
    // is by definition an UNEXPLAINED checker-vs-codegen divergence — a NEW ownership decision made two
    // different ways, the exact latent-corruption class this whole effort kills (a value one path frees
    // and the other keeps = a use-after-free or leak surfacing months later as "string heap corruption").
    // Either is a HARD build failure here, so the residue can NEVER silently grow past the one known,
    // correct boundary. This is the ENFORCED "nothing bites" invariant: the foundation refuses to build
    // if an ownership-disposition disagreement appears outside the erasure boundary.
    if (disp_disagree_enum > 0 or disp_disagree_other > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F2-6 disposition):\x1b[0m\x1b[1m an ownership-disposition disagreement appeared OUTSIDE the one allowed erasure boundary\x1b[0m\n" ++
            "  .enum_ disagreements : {d}   (MUST be 0 — enum ownership is now variant-aware)\n" ++
            "  OTHER  disagreements : {d}   (MUST be 0 — an unexplained checker-vs-codegen ownership divergence)\n" ++
            "  last OTHER: kind='{s}' type='{s}'\n" ++
            "  Only `.type_param` from erased container methods is an allowed boundary (the erasure rule,\n" ++
            "  gate-proven leak-free). Anything else is a NEW ownership guess — the corruption class F2-6\n" ++
            "  exists to eliminate. Fix the divergence before this lands.\n",
            .{ disp_disagree_enum, disp_disagree_other, disp_last_kind, disp_last_type },
        );
        std.process.exit(1);
    }

    // FOUNDATION GATE (F5-2, 2026-07-18). The whole point of the store-typed ownership engine is that
    // ownership is a property of a TYPE, not of a spelling. This shadow proved corpus-wide that the
    // TypeId engine and the legacy string engine give the IDENTICAL answer on every concrete decision
    // (agree=N, disagree=0) and every keystone substitution (keystone-resolves=N, keystone-disagree=0).
    // That agreement is the LICENSE to delete the string engine — but it is only meaningful if it stays
    // true. A future change that makes the two engines diverge on a CONCRETE type is precisely the
    // "ownership decided by name-matching" latent-corruption class F5 exists to kill (a value freed by
    // one engine and kept by the other = a use-after-free or a leak, discovered months later as
    // "string heap corruption"). So under the shadow flag this is no longer report-only: a disagreement
    // is a HARD build failure, here, at the divergence, with the offending type named. This is the
    // silent→loud transformation, applied to the migration invariant itself.
    if (td_disagree > 0 or td_keystone_disagree > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F5-2):\x1b[0m\x1b[1m the string ownership engine and the TypeId engine DISAGREE\x1b[0m\n" ++
            "  concrete disagreements: {d}   keystone-substitution disagreements: {d}   (both MUST be 0)\n" ++
            "  last: '{s}'  typed-engine={}  string-engine={}\n" ++
            "  Ownership is being decided differently by name-matching vs the type store — the exact\n" ++
            "  latent-corruption class F5 exists to eliminate. A value one engine frees and the other keeps\n" ++
            "  is a use-after-free or a leak. Fix the divergence before this lands.\n",
            .{ td_disagree, td_keystone_disagree, td_last_disagree, td_last_disagree_typed, td_last_disagree_string },
        );
        std.process.exit(1);
    }
}

// F1 stage 3b: does sema's recorded callee SymbolId (symOf -> legacy_mangled) AGREE with what
// the func_map suffix scan (resolveCalleeName) resolves a bare-name call to? Counted at the main
// named-call codegen path. When agree is high and disagree is 0, the scan can be replaced by the
// SymbolId lookup — the shadow-then-cutover gate for deleting the 227-line scan.
pub var f1_3b_agree: usize = 0;
pub var f1_3b_disagree: usize = 0;
pub var f1_3b_sym_absent: usize = 0; // sema recorded no SymbolId for this call (scan still needed)
pub var f1_3b_last_disagree_sym: []const u8 = "";
pub var f1_3b_last_disagree_scan: []const u8 = "";
/// The bare CALLEE names with no recorded SymbolId — names the shape of the coverage gap so the
/// next `recordSym` branch is chosen from evidence, not guessed.
pub var f1_3b_absent_names: std.StringHashMapUnmanaged(usize) = .empty;
pub fn noteF13bAbsent(name: []const u8) void {
    const gop = f1_3b_absent_names.getOrPut(std.heap.page_allocator, name) catch return;
    if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
}

// F4-5 shadow: at a generic method call, did the receiver resolve to the CONCRETE monomorphized
// body (e.g. `List_i32_push`) or fall back to the ERASED body (`List_push`)? The erased body cannot
// be deleted while any call still lands on it, and the design says exactly that ("Deleting it is
// separate work"). This names the residual erased-reliance so the cutover is driven by evidence, not
// guessed at: f45_erased_by_name records the MISSING mono symbols (the `List_i32_push` that was not
// in func_map so the call fell to `List_push`), which is the precise work-list for closing coverage.
// Report-only under NOVA_SEMA_SHADOW.
pub var f45_mono_hit: usize = 0; // resolved to a concrete monomorphized body — good
pub var f45_erased_fallback: usize = 0; // an INSTANTIATED mono_name missed func_map -> fell to erased
pub var f45_erased_nongeneric: usize = 0; // mono_name == erased (non-generic / erased-context) — correct
pub var f45_erased_by_name: std.StringHashMapUnmanaged(usize) = .empty;
pub fn noteF45Erased(missing_mono: []const u8) void {
    if (!report_enabled) return;
    // The caller frees `missing_mono` (a `defer allocator.free` on `mono_name`) right after this
    // returns, so the map MUST own a copy or it stores a dangling pointer (prints garbage bytes).
    const gop = f45_erased_by_name.getOrPut(std.heap.page_allocator, missing_mono) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
    } else {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, missing_mono) catch missing_mono;
        gop.value_ptr.* = 1;
    }
}
pub fn reportF45() void {
    if (!report_enabled) return;
    out("\n=== F4-5 shadow: erased vs monomorphized method resolution ===\n", .{});
    out("  resolved to CONCRETE mono body : {d}\n", .{f45_mono_hit});
    out("  fell back to ERASED (non-generic / erased ctx, correct) : {d}\n", .{f45_erased_nongeneric});
    out("  fell back to ERASED with an INSTANTIATED name (residual reliance, MUST reach 0) : {d}\n", .{f45_erased_fallback});
    var it = f45_erased_by_name.iterator();
    var shown: usize = 0;
    while (it.next()) |e| {
        if (shown >= 20) break;
        out("    missing mono symbol: {s} (x{d})\n", .{ e.key_ptr.*, e.value_ptr.* });
        shown += 1;
    }
    out("=== end F4-5 shadow ===\n\n", .{});
}

pub var diff_agree: usize = 0;
pub var diff_legacy_invented: usize = 0; // legacy answered; F2 says unresolved
pub var diff_f2_better: usize = 0; // legacy gave up; F2 typed it
pub var diff_disagree: usize = 0; // both answered, differently
pub var diff_absent: usize = 0; // not in the IR at all
/// Which SHAPES are absent. A count says how bad; a shape says what to do.
pub var diff_absent_tags: std.StringHashMapUnmanaged(usize) = .empty;
/// WHICH functions codegen compiles that sema never walked. The shape says what;
/// this says where.
pub var diff_absent_fns: std.StringHashMapUnmanaged(usize) = .empty;
pub var walk_errors: usize = 0;
pub var walked_fns: std.StringHashMapUnmanaged(void) = .empty;
var absent_spans: [8][]const u8 = undefined;
var absent_span_n: usize = 0;

/// Best-effort source location for an expression — enough to go and LOOK.
fn spanOf(e: *const ast.Expression) ?ast.Span {
    return switch (e.kind) {
        .binary => |b| b.span,
        .call => |c| c.span,
        .unary => |u| u.span,
        .index => |i| i.span,
        .generic_call => |g| g.span,
        .field_access => |f| f.span,
        .cast => |c| c.span,
        .struct_init => |si| si.span,
        else => null,
    };
}
pub var diff_absent_alloc: ?std.mem.Allocator = null;
var diff_examples: [12][3][]const u8 = undefined;
var diff_example_n: usize = 0;

/// Render a TypeId in the LEGACY vocabulary so the two can be compared at all.
/// Necessarily lossy — that is the point: the legacy side has no way to SAY some
/// of what F2 knows. `ptr` renders as "i32" because that is the only spelling
/// legacy has for an address (codegen/types.zig:252), which is exactly the `data:
/// i32` lie; they will "agree" there while meaning different things.

/// Rewrite a legacy type STRING into canonical spellings: `i32` -> `int`,
/// `f64` -> `double`, and so on, including inside generics (`List<i32>`).
///
/// lower.zig accepts both spellings and interns them to one type, so `i32` and
/// `int` were never different types — only different words for one. Legacy echoes
/// whatever the source said; the stdlib says `i32` in 481 places and `int` in 4.
/// Without this the diff reports the stdlib's inconsistency as a type system
/// defect, which sends you to fix code that is already correct.
fn canonicalTypeStr(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    const alias = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "i32", .to = "int" },     .{ .from = "u32", .to = "uint" },
        .{ .from = "i64", .to = "long" },    .{ .from = "u64", .to = "ulong" },
        .{ .from = "i16", .to = "short" },   .{ .from = "u16", .to = "ushort" },
        .{ .from = "i8", .to = "sbyte" },    .{ .from = "u8", .to = "byte" },
        .{ .from = "ubyte", .to = "byte" },
        .{ .from = "f32", .to = "float" },   .{ .from = "f64", .to = "double" },
    };
    var buf = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        // Only rewrite whole identifier tokens: `Li32st` must not become `Lintst`.
        const at_start = i == 0 or !isIdentChar(s[i - 1]);
        if (at_start) {
            for (alias) |a| {
                if (std.mem.startsWith(u8, s[i..], a.from)) {
                    const end = i + a.from.len;
                    if (end == s.len or !isIdentChar(s[end])) {
                        buf.appendSlice(allocator, a.to) catch return s;
                        i = end;
                        continue :outer;
                    }
                }
            }
        }
        buf.append(allocator, s[i]) catch return s;
        i += 1;
    }
    return buf.toOwnedSlice(allocator) catch s;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The type's name in CODEGEN's vocabulary (see the `.prim` arm).
///
/// INTERNED per TypeId when an owning Sema is available. A TypeId is interned, so
/// its name is a pure function of it — rendering it twice is pure waste, and the
/// 4b cutover renders on EVERY resolution: 9,222 renders / 296 allocations on one
/// corpus case, none of them freed, because codegen never frees what
/// resolveExpressionTypeName returns. Now: rendered once per distinct type, owned
/// by the Sema, freed with it.
pub fn renderLegacy(allocator: std.mem.Allocator, store: *const typesys.TypeStore, id: typesys.TypeId) anyerror![]const u8 {
    render_calls += 1;
    if (live_sema) |sm| {
        if (sm.cachedName(id)) |n| {
            render_cache_hits += 1;
            return n;
        }
    }
    const rendered = try renderUncached(allocator, store, id);
    // Only composite renders allocate; a prim returns a literal, which must NOT be
    // interned — the map would try to free static memory at destroy().
    if (live_sema) |sm| {
        if (allocatesFor(store.get(id))) return try sm.internName(id, rendered);
    }
    return rendered;
}

/// Does rendering this type allocate? Mirrors the arms of renderUncached that call
/// toOwnedSlice/allocPrint. Kept next to it deliberately: interning a string
/// literal would free static memory, and NOT interning an allocation leaks it.
fn allocatesFor(t: typesys.Type) bool {
    return switch (t) {
        .struct_ => |st| st.args.len > 0,
        .storage => true,
        .func => true,
        else => false,
    };
}

fn renderUncached(allocator: std.mem.Allocator, store: *const typesys.TypeStore, id: typesys.TypeId) anyerror![]const u8 {
    return switch (store.get(id)) {
        .unresolved => "<unresolved>",
        .string => "string",
        .decimal => "decimal",
        // specs §3.4b — the SAME spelling `codegen/types.zig`'s typeRefToString emits, or the
        // two renderers disagree about one type, which is how `Atomic<long>` ended up with a
        // 4-byte cell and 8-byte accesses. One spelling, both paths.
        .error_union => |eu| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.appendSlice(allocator, "ErrUnion(");
            try buf.appendSlice(allocator, try renderUncached(allocator, store, eu.ok));
            try buf.append(allocator, ',');
            try buf.appendSlice(allocator, try renderUncached(allocator, store, eu.err));
            try buf.append(allocator, ')');
            break :blk try buf.toOwnedSlice(allocator);
        },
        .ptr => "ptr", // F3 §5 stage 2: `ptr` is now a first-class codegen primitive
        // CODEGEN's vocabulary, deliberately — `i32`, not the canonical `int`.
        //
        // This renderer feeds the stage-4b cutover, and codegen compares type names
        // as STRINGS: `expressions.zig:2136` tests `eql(t, "i32")` to route `${n}`
        // through __i32_to_string, and does NOT accept "int". Handing it the
        // canonical spelling would silently stop template interpolation working.
        // F3 migrates codegen's vocabulary; until then the cutover speaks its.
        //
        // The DIFF does not suffer for it: recordDiff canonicalises BOTH sides
        // (canonicalTypeStr), so `i32` and `int` still compare equal there — the
        // spelling is a codegen interface detail, not a type distinction.
        .prim => |p| switch (p.kind) {
            .bool => "bool",
            .void_ => "void",
            .float => if (p.bits == 32) "f32" else "f64",
            .int => switch (p.bits) {
                1 => "bool",
                8 => if (p.signed) "i8" else "u8",
                16 => if (p.signed) "i16" else "u16",
                64 => if (p.signed) "i64" else "u64",
                else => if (p.signed) "i32" else "u32",
            },
        },
        .struct_ => |st| blk: {
            const sym = diff_tab.?.symbolAt(st.decl);
            // F1 module-scoped types: a struct whose bare name collides across modules renders under its
            // module-unique `scoped_name` (precomputed, owned by the table) so codegen keys it distinctly.
            // A non-colliding struct has `scoped_name == null` → bare name, unchanged (the no-op case).
            const base = sym.scoped_name orelse sym.name;
            if (st.args.len == 0) break :blk base;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(allocator, base);
            try buf.append(allocator, '<');
            for (st.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, try renderLegacy(allocator, store, a));
            }
            try buf.append(allocator, '>');
            const r = try buf.toOwnedSlice(allocator);
            render_allocs += 1;
            render_bytes += r.len;
            break :blk r;
        },
        .enum_ => |sid| diff_tab.?.symbolAt(sid).name,
        .trait_ => |sid| diff_tab.?.symbolAt(sid).name,
        // Render the real signature. `<fn>` was a placeholder, so EVERY function
        // type "disagreed" with legacy's `(int) -> int` — 9 of 21 clusters, and the
        // largest group. Exactly the `<T>` bug from earlier in the same function:
        // a printer that cannot spell a type reports it as a defect in the type.
        .func => |ft| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.append(allocator, '(');
            for (ft.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, try renderLegacy(allocator, store, p));
            }
            try buf.appendSlice(allocator, ") -> ");
            try buf.appendSlice(allocator, try renderLegacy(allocator, store, ft.ret));
            const r = try buf.toOwnedSlice(allocator);
            render_allocs += 1;
            render_bytes += r.len;
            break :blk r;
        },
        .optional => |inner| try renderLegacy(allocator, store, inner),
        // A handle is a bare i64 at runtime (specs 7.1), and this renderer feeds
        // CODEGEN. Rendering "future<int>" would hand codegen a name it does not
        // know, and toLLVMType maps everything unknown to `ptr` — silently turning
        // a handle into a pointer. The TYPE knows it is a future; the ABI does not.
        .future => "i64",
        // Rendered for CODEGEN, which dispatches `.get`/`.set` on this exact spelling
        // (llvm_codegen.zig compileStorageCall).
        .storage => |elem| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.appendSlice(allocator, "Storage<");
            try buf.appendSlice(allocator, try renderLegacy(allocator, store, elem));
            try buf.append(allocator, '>');
            break :blk try buf.toOwnedSlice(allocator);
        },
        // Rendered for CODEGEN as `(a,b)` — the spelling getTupleElementType parses.
        //
        // ⚠️ This used to render the literal string `"<tuple>"`, which does not start with `(`, so
        // getTupleElementType returned "i32" for EVERY element of EVERY destructuring, always. That
        // made `isRefCountedType` false for every tuple element, so the destructuring retain never
        // fired and the locals were never released — codegen simply did not know which elements were
        // heap. Every tuple leaked its box and all its elements (28_tuple_return_heap = 68 live
        // objects, 29_http_request_parse = 46 — together ~108 of the ~118 above-floor objects in the
        // whole corpus).
        //
        // Separator is "," with NO space, matching lower.zig's note that generics render with ", "
        // and tuples with ",". getTupleElementType is depth-aware over <> and () so a
        // `(Map<string,int>, int)` element is not split down the middle.
        .tuple => |elems| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.append(allocator, '(');
            for (elems, 0..) |e, i| {
                if (i > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, try renderLegacy(allocator, store, e));
            }
            try buf.append(allocator, ')');
            break :blk try buf.toOwnedSlice(allocator);
        },
        .array => "<array>",
        // Render the param's REAL name (`T`), not a placeholder. `<T>` made every
        // generic render as `List<<T>>` against legacy's `List<T>` and counted as
        // a disagreement — a defect in this printer being reported as a defect in
        // the type system. A harness that invents divergences is worse than none:
        // it sends you to fix code that was already right.
        .type_param => |tp| typeParamName(tp) orelse "<T>",
    };
}

/// The name of a type param, via its owner's declaration. `TypeParam` stores only
/// {owner, index}, because a TypeId is interned and a name is not part of identity.
fn typeParamName(tp: typesys.TypeParam) ?[]const u8 {
    const tab = diff_tab orelse return null;
    const owner = tab.symbolAt(tp.owner);
    const names: []const []const u8 = switch (owner.decl) {
        .function => |f| f.type_params,
        .struct_ => |s| s.type_params,
        // EnumDecl has no type_params — generic enums are not parsed today.
        else => return null,
    };
    if (tp.index >= names.len) return null;
    return names[tp.index];
}

/// F2 stage 4b: divergences aggregated by (shape, legacy -> F2), with counts.
///
/// 564 divergences is not 564 problems. Triaging by reading the first 12 examples
/// is sampling, and sampling picks the loudest cluster, not the biggest one. The
/// counts are what say which single fix is worth the most — and which "divergence"
/// is this harness's own bug.
pub var diff_clusters: std.StringHashMapUnmanaged(usize) = .empty;
/// One real source location per cluster. A cluster with no example is a claim;
/// with a file:line it is checkable. Every verdict below was reached by opening
/// one of these, not by reasoning about the tag name.
pub var diff_cluster_where: std.StringHashMapUnmanaged([]const u8) = .empty;

/// The NAME behind a divergence, when the shape has one. `ident` carries no span
/// (it is a bare `[]const u8`), so span-based examples render as `?` for the
/// largest gap clusters — the ones that most need locating. A shape says "38 idents
/// are unresolved"; a name says WHICH, which is the difference between a number and
/// a next action.
fn nameHint(e: *const ast.Expression) ?[]const u8 {
    return switch (e.kind) {
        .ident => |n| n,
        .field_access => |fa| fa.field,
        .call => |c| switch (c.callee.kind) {
            .ident => |n| n,
            .field_access => |fa| fa.field,
            else => null,
        },
        .generic_call => |g| switch (g.callee.kind) {
            .ident => |n| n,
            .field_access => |fa| fa.field,
            else => null,
        },
        else => null,
    };
}

fn noteCluster(allocator: std.mem.Allocator, e: *const ast.Expression, legacy: []const u8, f2: []const u8, in_fn: ?[]const u8) void {
    const key = if (nameHint(e)) |n|
        std.fmt.allocPrint(allocator, "{s} `{s}` in {s}: '{s}' -> '{s}'", .{ @tagName(e.kind), n, in_fn orelse "?", legacy, f2 }) catch return
    else
        std.fmt.allocPrint(allocator, "{s}: '{s}' -> '{s}'", .{ @tagName(e.kind), legacy, f2 }) catch return;
    const gop = diff_clusters.getOrPut(allocator, key) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
        allocator.free(key);
    } else {
        gop.value_ptr.* = 1;
        if (spanOf(e)) |sp| {
            const w = std.fmt.allocPrint(allocator, "{s}:{d}", .{ sp.file, sp.line }) catch return;
            _ = diff_cluster_where.put(allocator, key, w) catch {};
        }
    }
}

var diff_tab: ?*const symbols.SymbolTable = null;
pub fn setDiffTable(t: *const symbols.SymbolTable) void {
    diff_tab = t;
}

/// Called from resolveExpressionTypeName with BOTH answers.
pub fn recordDiff(
    allocator: std.mem.Allocator,
    store: *const typesys.TypeStore,
    ir: *const infer.TypedIr,
    e: *const ast.Expression,
    legacy: ?[]const u8,
    in_fn: ?[]const u8,
) void {
    diff_absent_alloc = allocator;
    const f2 = ir.typeOf(e) orelse {
        diff_absent += 1;
        if (diff_absent_alloc) |a| {
            if (absent_span_n < absent_spans.len) {
                if (spanOf(e)) |sp| {
                    absent_spans[absent_span_n] = std.fmt.allocPrint(a, "{s}:{d} ({s})", .{ sp.file, sp.line, @tagName(e.kind) }) catch "?";
                    absent_span_n += 1;
                }
            }
            const gop = diff_absent_tags.getOrPut(a, @tagName(e.kind)) catch return;
            if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            const g2 = diff_absent_fns.getOrPut(a, in_fn orelse "<none>") catch return;
            if (g2.found_existing) g2.value_ptr.* += 1 else g2.value_ptr.* = 1;
        }
        return;
    };
    diff_absent_alloc = allocator;
    const f2_raw = renderLegacy(allocator, store, f2) catch return;
    const f2_unres = std.mem.eql(u8, f2_raw, "<unresolved>");
    // Both sides canonicalised: the renderer speaks codegen's `i32` (see above) and
    // legacy echoes whatever the source said, so comparing raw strings would report
    // one type under two spellings as a divergence. It did — 48 of them.
    const f2s = canonicalTypeStr(allocator, f2_raw);

    if (legacy) |l_raw| {
        const l = canonicalTypeStr(allocator, l_raw);
        if (f2_unres) {
            diff_legacy_invented += 1;
            noteCluster(allocator, e, l, "<unresolved>", in_fn);
            if (diff_example_n < diff_examples.len) {
                diff_examples[diff_example_n] = .{ @tagName(e.kind), l, "<unresolved>" };
                diff_example_n += 1;
            }
        } else if (std.mem.eql(u8, l, f2s)) {
            diff_agree += 1;
        } else {
            diff_disagree += 1;
            noteCluster(allocator, e, l, f2s, in_fn);
            if (diff_example_n < diff_examples.len) {
                diff_examples[diff_example_n] = .{ @tagName(e.kind), l, f2s };
                diff_example_n += 1;
            }
        }
    } else {
        if (f2_unres) diff_agree += 1 else diff_f2_better += 1;
    }
}

pub fn reportDiff() void {
    if (!trace_resolution) return;
    const f13b_total = f1_3b_agree + f1_3b_disagree + f1_3b_sym_absent;
    out("\n=== F1 stage 3b: symOf(call)->legacy_mangled  vs  func_map scan ===\n", .{});
    out("  named calls compared : {d}\n", .{f13b_total});
    out("  AGREE (SymbolId resolves same as scan) : {d}\n", .{f1_3b_agree});
    out("  DISAGREE : {d}\n", .{f1_3b_disagree});
    out("  no SymbolId recorded (scan still needed) : {d}\n", .{f1_3b_sym_absent});
    if (f1_3b_disagree > 0) out("    e.g. sym='{s}' scan='{s}'\n", .{ f1_3b_last_disagree_sym, f1_3b_last_disagree_scan });
    {
        var it = f1_3b_absent_names.iterator();
        var shown: usize = 0;
        while (it.next()) |e| {
            if (shown >= 20) break;
            out("      absent-call '{s}' (x{d})\n", .{ e.key_ptr.*, e.value_ptr.* });
            shown += 1;
        }
    }
    const total = diff_agree + diff_legacy_invented + diff_f2_better + diff_disagree + diff_absent;
    out("\n=== F2 stage 3: TypedIr vs resolveExpressionTypeName ===\n", .{});
    out("  resolutions compared : {d}\n", .{total});
    out("  agree                : {d}\n", .{diff_agree});
    out("  F2 typed it, legacy gave up : {d}\n", .{diff_f2_better});
    out("  LEGACY ANSWERED, F2 says unresolved : {d}\n", .{diff_legacy_invented});
    out("  BOTH answered, DIFFERENTLY : {d}\n", .{diff_disagree});
    out("  not in the IR (codegen asked about an expr sema never saw) : {d}\n", .{diff_absent});
    var at = diff_absent_tags.iterator();
    while (at.next()) |e| out("      absent {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    out("    -- absent: where are they? --\n", .{});
    for (absent_spans[0..absent_span_n]) |sp| out("      {s}\n", .{sp});
    out("    -- absent, by the function codegen was compiling --\n", .{});
    out("    (did sema walk it? bare name looked up in walked_fns)\n", .{});
    var af = diff_absent_fns.iterator();
    var n: usize = 0;
    while (af.next()) |e| {
        if (n >= 14) break;
        // strip the module prefix to get the source name sema knows
        const mangled = e.key_ptr.*;
        const bare = if (std.mem.lastIndexOfScalar(u8, mangled, '_')) |i| mangled[i + 1 ..] else mangled;
        const walked = walked_fns.contains(mangled) or walked_fns.contains(bare);
        out("      {s}: {d}   sema-walked={}\n", .{ mangled, e.value_ptr.*, walked });
        n += 1;
    }
    if (diff_example_n > 0) {
        if (diff_clusters.count() > 0) {
        var rows = std.ArrayListUnmanaged(struct { k: []const u8, n: usize }).empty;
        defer rows.deinit(diff_absent_alloc.?);
        var it = diff_clusters.iterator();
        while (it.next()) |kv| rows.append(diff_absent_alloc.?, .{ .k = kv.key_ptr.*, .n = kv.value_ptr.* }) catch {};
        std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
            fn lt(_: void, a: @TypeOf(rows.items[0]), b: @TypeOf(rows.items[0])) bool {
                return a.n > b.n;
            }
        }.lt);
        out("  -- divergences CLUSTERED (biggest first) --\n", .{});
        var shown: usize = 0;
        for (rows.items) |r| {
            if (shown >= 20) break;
            const where = diff_cluster_where.get(r.k) orelse "?";
            out("    {d:>5}  {s}\n             e.g. {s}\n", .{ r.n, r.k, where });
            shown += 1;
        }
        out("    ({d} distinct clusters)\n", .{diff_clusters.count()});
    }
    out("  -- examples (shape: legacy -> F2) --\n", .{});
        for (diff_examples[0..diff_example_n]) |ex| {
            out("    {s}: '{s}' -> '{s}'\n", .{ ex[0], ex[1], ex[2] });
        }
    }
    out("=== end ===\n\n", .{});
}

// ---------------------------------------------------------------------------
// Tests (docs/design/README.md §2b).
// ---------------------------------------------------------------------------
const testing = std.testing;

test "canonicalTypeStr: i32 and int are ONE type, so they must render as one word" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "i32", .want = "int" },
        .{ .in = "int", .want = "int" }, // already canonical — unchanged
        .{ .in = "f64", .want = "double" },
        .{ .in = "i64", .want = "long" },
        .{ .in = "u32", .want = "uint" },
        // F3 §3.1: `byte` is UNSIGNED 8 and `sbyte` is SIGNED 8 — so i8 is NOT
        // `byte`. Mapping both onto `byte` would have canonicalised a signed type
        // to an unsigned name and called two different types equal.
        .{ .in = "i8", .want = "sbyte" },
        .{ .in = "u8", .want = "byte" },
        .{ .in = "i16", .want = "short" },
        .{ .in = "u16", .want = "ushort" },
        .{ .in = "f32", .want = "float" },
        // inside generics, and both spellings of the SAME map must converge
        .{ .in = "Map<string, i32>", .want = "Map<string, int>" },
        .{ .in = "Map<string, int>", .want = "Map<string, int>" },
        .{ .in = "List<i32>", .want = "List<int>" },
        .{ .in = "Map<i32, List<f64>>", .want = "Map<int, List<double>>" },
    };
    for (cases) |c| {
        const got = canonicalTypeStr(a, c.in);
        defer if (got.ptr != c.in.ptr) a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "canonicalTypeStr: only whole tokens — a rewriter that invents agreement is worse than none" {
    const a = testing.allocator;
    // `i32` inside a longer identifier is NOT the type i32. Rewriting it would
    // make unrelated names collide and manufacture agreement the diff would then
    // report as progress.
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "myi32var", .want = "myi32var" },
        .{ .in = "i32_helper", .want = "i32_helper" },
        .{ .in = "Xi32", .want = "Xi32" },
        .{ .in = "<unresolved>", .want = "<unresolved>" },
        .{ .in = "string", .want = "string" },
    };
    for (cases) |c| {
        const got = canonicalTypeStr(a, c.in);
        defer if (got.ptr != c.in.ptr) a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}
