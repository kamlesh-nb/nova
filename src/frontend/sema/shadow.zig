//! Shadow-diff harness for the semantic-analysis pass: it runs the NEW typed
//! engine (symbol table + [`typesys.TypeStore`] + [`infer.TypedIr`]) alongside
//! the OLD string/name-matching engine and measures where they DISAGREE, so a
//! risky migration can be proven equivalent BEFORE the old code is cut out.
//!
//! ## Why this file exists
//!
//! Nova's compiler grew a first generation of resolution that decided almost
//! everything from mangled name STRINGS: which function a call names, what a
//! type is, and, most dangerously, whether a value is heap-owned (and so must
//! be ARC-released) by matching its type NAME. Deciding ownership from a string
//! is a corruption class in its own right (a name-match that guesses wrong frees
//! a live value or leaks a dead one, i.e. a use-after-free or a leak). The fix
//! is a real typed IR keyed on interned [`typesys.TypeId`]s. But you cannot
//! flip a load-bearing decision engine in one commit and hope; you run both,
//! diff every decision, and only cut over once the disagreement count is a known,
//! explained set (ideally zero).
//!
//! That is what this module is: a REPORT-ONLY observer. [`run`] is the entry
//! point sema calls after building the symbol table. It never changes program
//! behaviour on the happy path; its only job is to accumulate counters (the many
//! `pub var`s below) and print human-readable comparison reports gated behind the
//! `*_enabled` flags. The one place it is NOT passive is the FOUNDATION GATES:
//! when a difference is in the dangerous class (an unexplained ownership
//! divergence, an owned value the balance check cannot prove is consumed exactly
//! once, a non-`pub` symbol used cross-module), it prints a diagnostic and calls
//! [`std.process.exit`] to fail the build. That is deliberate: those are the
//! exact latent-corruption shapes the typed engine exists to eliminate, so the
//! harness refuses to let them land.
//!
//! ## The staged nomenclature (F1 / F2 / F2-6 / F4-5 / F5)
//!
//! The counter and report names carry a migration-stage tag. F1 is symbol-table
//! resolution vs the legacy suffix-scan (does the new table name the same
//! function?). F2 is the typed-IR type surface (did every declared type and
//! expression get a TypeId?). F2-6 is the ownership/temporaries pass (are owned
//! locals and temporaries provably balanced?). F4-5 is monomorphized-vs-erased
//! method resolution. F5 is the ownership DECISION diff (does `isOwnedTypeId`
//! agree with the legacy string ownership rule?). These are stages of one long
//! cut-over, not separate features.
//!
//! ## Global mutable state, and why it is acceptable here
//!
//! This module keeps its accumulators as file-level `pub var`s rather than
//! threading a context struct through every call site. That is a deliberate
//! trade: the shadow instrumentation is sprinkled across codegen and inference
//! at points where passing an extra parameter would be invasive and would
//! entangle report-only bookkeeping with real compilation. The counters are
//! written from a single-threaded compile, read only by the `report*`
//! functions, and reset per process. The `live_*` pointers ([`live_sema`],
//! [`live_store`], [`live_ir`]) and [`diff_tab`] are late-bound handles the
//! instrumentation needs but cannot receive as arguments; [`run`] and
//! [`setDiffTable`] install them.

const std = @import("std");
/// The AST node definitions ([`ast.Program`], [`ast.Expression`], [`ast.Span`])
/// this pass walks and reports source locations from.
const ast = @import("../ast.zig");
/// The symbol table ([`symbols.SymbolTable`], [`symbols.Symbol`]): the NEW
/// name-resolution side of every F1 comparison.
const symbols = @import("symbols.zig");
/// The type system: interned [`typesys.TypeId`]s and the [`typesys.TypeStore`]
/// whose `.get`/`.isOwned` answers are diffed against the legacy string rules.
const typesys = @import("../types.zig");
/// The declared-type lowerer ([`lower.Lowerer`]) that turns AST type syntax into
/// TypeIds; [`runTypeLowering`] drives it to measure the F2 declared-type surface.
const lower = @import("lower.zig");
/// The expression type-inferer ([`infer.Inferer`]) that builds the authoritative
/// [`infer.TypedIr`]; its per-error lists are what the FOUNDATION GATES read.
const infer = @import("infer.zig");
/// The static ownership/balance pass ([`ownership.analyze`]); its report feeds
/// the F2-6 owned-value balance gate in [`runTypeLowering`].
const ownership = @import("ownership.zig");
/// The owning sema context ([`sema_mod.Sema`]): holds the symbol table, type
/// store, typed IR, and name cache the shadow harness reads through [`live_sema`].
const sema_mod = @import("sema.zig");

/// Master switch for the F1 resolution-trace reports ([`reportResolution`],
/// [`reportDiff`]). Off by default so a normal build is silent.
pub var trace_resolution: bool = false;

/// Master switch for the F2 / F2-6 / F4-5 / F5 shadow reports and the ownership
/// pass in [`runTypeLowering`]. When off, [`out`] swallows every report line and
/// the ownership balance gate is skipped entirely.
pub var report_enabled: bool = false;

/// Enables the "TypeId census", a tally of expressions the legacy string engine
/// resolves but whose TypeId is null (Phase-1 coverage gaps), printed by
/// [`tidCensusReport`].
pub var tid_census: bool = false;
/// Count of census sites where the string engine answered but the TypeId is null.
pub var census_total: usize = 0;
/// Of [`census_total`], those on a bare identifier expression.
pub var census_kind_ident: usize = 0;
/// Of [`census_total`], those on an index expression (`xs[i]`).
pub var census_kind_index: usize = 0;
/// Of [`census_total`], those on a plain function call.
pub var census_kind_call: usize = 0;
/// Of [`census_total`], those on a field access (`x.f`).
pub var census_kind_field: usize = 0;
/// Of [`census_total`], those on a method call (`x.m(...)`).
pub var census_kind_method: usize = 0;
/// Of [`census_total`], every other expression kind not broken out above.
pub var census_kind_other: usize = 0;

/// Count of census sites where BOTH engines answered but the answers DISAGREE
/// (Phase-1a accuracy gaps, worse than a null, since one engine is wrong).
pub var census_disagree: usize = 0;
/// Of [`census_disagree`], those on a bare identifier.
pub var census_dis_ident: usize = 0;
/// Of [`census_disagree`], those on an index expression.
pub var census_dis_index: usize = 0;
/// Of [`census_disagree`], those on a plain call.
pub var census_dis_call: usize = 0;
/// Of [`census_disagree`], those on a generic call (`f<T>(...)`).
pub var census_dis_gcall: usize = 0;
/// Of [`census_disagree`], those on a field access.
pub var census_dis_field: usize = 0;
/// Of [`census_disagree`], those on a binary expression.
pub var census_dis_binary: usize = 0;
/// Of [`census_disagree`], every other expression kind.
pub var census_dis_other: usize = 0;
/// Fixed 128-byte scratch holding the string-engine answer of the most recent
/// disagreement, for the "e.g." example line; a buffer (not a slice) so it needs
/// no allocation and outlives the transient render it captured.
pub var census_dis_last_str: [128]u8 = undefined;
/// Number of valid bytes in [`census_dis_last_str`].
pub var census_dis_last_str_len: usize = 0;
/// Fixed 128-byte scratch holding the TypeId-engine answer of the most recent
/// disagreement, paired with [`census_dis_last_str`] in the example line.
pub var census_dis_last_tid: [128]u8 = undefined;
/// Number of valid bytes in [`census_dis_last_tid`].
pub var census_dis_last_tid_len: usize = 0;

/// Prints the TypeId-census summary (null-total and disagree-total, broken down
/// by expression kind, with one worked example) to stderr.
///
/// A no-op unless [`tid_census`] is set. Reads only the `census_*` counters, so
/// it is meaningful only after a compile has run the instrumentation that fills
/// them.
pub fn tidCensusReport() void {
    if (!tid_census) return;
    std.debug.print("=== TID census: string resolves, TypeId null (Phase-1 gaps) ===\n", .{});
    std.debug.print("  null_total={d}  ident={d} index={d} call={d} field={d} method_call={d} other={d}\n", .{
        census_total, census_kind_ident, census_kind_index, census_kind_call, census_kind_field, census_kind_method, census_kind_other,
    });
    std.debug.print("=== TID census: string vs TypeId DISAGREE (Phase-1a accuracy gaps) ===\n", .{});
    std.debug.print("  disagree_total={d}  ident={d} index={d} call={d} gcall={d} field={d} binary={d} other={d}\n", .{
        census_disagree, census_dis_ident, census_dis_index, census_dis_call, census_dis_gcall, census_dis_field, census_dis_binary, census_dis_other,
    });
    if (census_disagree > 0) {
        std.debug.print("  e.g. string='{s}' typeid='{s}'\n", .{ census_dis_last_str[0..census_dis_last_str_len], census_dis_last_tid[0..census_dis_last_tid_len] });
    }
}

/// Gated `std.debug.print`: emits a report line only when [`report_enabled`].
///
/// Every non-error, report-only line in this module goes through here so a
/// normal (non-shadow) build stays completely silent, the hard error diagnostics
/// that precede a gate exit deliberately bypass it and use `std.debug.print`
/// directly, because they must print whether or not reporting is enabled.
fn out(comptime fmt: []const u8, args: anytype) void {
    if (report_enabled) std.debug.print(fmt, args);
}

/// Enables serving expression types from the F2 typed IR (rather than the legacy
/// string resolver) at instrumented codegen sites; a migration toggle.
pub var f2_types_enabled: bool = false;

/// Count of type queries answered by the F2 typed engine.
pub var f2_served: usize = 0;
/// Total calls into [`renderLegacy`] (the TypeId → legacy-name renderer).
pub var render_calls: usize = 0;
/// Renders that had to allocate a fresh name string (composite types).
pub var render_allocs: usize = 0;
/// Total bytes allocated across all rendered names, for churn accounting.
pub var render_bytes: usize = 0;
/// Renders satisfied from [`sema_mod.Sema`]'s interned name cache (no allocation).
pub var render_cache_hits: usize = 0;
/// Count of sites where the F2 engine could not answer and fell back to legacy.
pub var f2_fellback: usize = 0;

/// Of [`f2_fellback`], those where the fallback was LOSSY (the legacy answer
/// carried information the TypeId path dropped), the coverage debt to close.
pub var f2_fellback_lossy: usize = 0;

/// Live calls into the IR-backed concrete-type resolver (`irct` = IR concrete type).
pub var irct_live_calls: usize = 0;
/// Of the `irct` calls, those decided as a primitive.
pub var irct_primitive: usize = 0;
/// Of the `irct` calls, those resolved to a concrete TypeId.
pub var irct_resolved: usize = 0;
/// Of the `irct` calls, those still decided by the legacy STRING rule (residual
/// reliance the migration aims to drive to zero, tracked in [`reportTypeIdDiff`]).
pub var irct_string_decided: usize = 0;

/// Late-bound handle to the active [`sema_mod.Sema`], installed by [`run`].
///
/// The instrumentation reaches the store/IR/name-cache through this rather than
/// receiving them as arguments; `null` before [`run`] (or in a non-shadow build)
/// means "no live compile", and readers fall back to an uncached path.
pub var live_sema: ?*sema_mod.Sema = null;
/// Late-bound handle to the active [`typesys.TypeStore`], installed by
/// [`runTypeLowering`]; used by rendering/ownership instrumentation.
pub var live_store: ?*typesys.TypeStore = null;
/// Late-bound handle to the active [`infer.TypedIr`], installed by
/// [`runTypeLowering`]; the authoritative expression-type source.
pub var live_ir: ?*infer.TypedIr = null;
/// Count of legacy calls that fell through to a name SUFFIX SCAN (the fragile
/// resolution path F1 measures), reported by [`reportResolution`].
pub var scan_hits: usize = 0;
/// Of [`scan_hits`], those with more than one candidate (resolution decided by
/// hash order, a latent wrong-callee bug).
pub var scan_ambiguous: usize = 0;
/// Of [`scan_hits`], those that resolved to nothing (a silent failure).
pub var scan_unresolved: usize = 0;

/// A classified resolution divergence between the two engines.
///
/// Currently a descriptive record produced for reporting; [`kind`] names the
/// failure shape and [`detail`] carries a human-readable specifics string.
pub const Divergence = struct {
    /// Which divergence shape this is: a legacy mangled-name collision, an
    /// ambiguous suffix match, a bare name shadowing a qualified one, or a symbol
    /// whose identity depends on an absolute filesystem path.
    kind: enum { legacy_collision, ambiguous_suffix, bare_shadows_qualified, path_dependent_symbol },
    /// Free-form description of this specific divergence (names, locations).
    detail: []const u8,
};

/// Entry point sema calls after parsing: builds the symbol table, runs the F1
/// name-resolution shadow report, then hands off to [`runTypeLowering`] for the
/// F2 type/ownership stages.
///
/// Installs [`live_sema`] and [`diff_tab`] as a side effect so downstream
/// instrumentation can reach them. The F1 half is pure reporting (collisions,
/// ambiguous suffix matches, root-vs-module shadows, canonical-prefix
/// pre-collisions, path-dependent symbols) and changes no behaviour; the F2 half
/// it delegates to CAN fail the build via the foundation gates. A failure inside
/// [`runTypeLowering`] that is not a gate exit is caught and merely reported,
/// because the harness must not break a build over its own bookkeeping.
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

    for (tab.symbols.items, 0..) |a, i| {
        for (tab.symbols.items[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.legacy_mangled, b.legacy_mangled)) continue;
            if (a.kind == .method and b.kind == .method and a.owner != null and b.owner != null and
                std.mem.eql(u8, a.owner.?, b.owner.?)) continue;
            collisions += 1;
            const ma = tab.moduleOf(a.module);
            const mb = tab.moduleOf(b.module);
            out("  [COLLISION] legacy symbol '{s}' <- {s}:{d} ({s}.{s}) AND {s}:{d} ({s}.{s})\n", .{
                a.legacy_mangled, a.span.file, a.span.line, ma.path, a.name,
                b.span.file, b.span.line, mb.path, b.name,
            });
        }
    }

    for (tab.symbols.items) |s| {
        if (s.kind != .function) continue;
        var matches: usize = 0;
        var first: ?symbols.Symbol = null;
        for (tab.symbols.items) |t| {
            if (t.kind != .function) continue;
            if (!std.mem.endsWith(u8, t.legacy_mangled, s.name)) continue;
            const pre = t.legacy_mangled.len - s.name.len;

            if (pre != 0 and t.legacy_mangled[pre - 1] != '_') continue;
            matches += 1;
            if (first == null) first = t;
        }
        if (matches > 1) {
            ambiguous += 1;
            out("  [AMBIGUOUS] bare '{s}' suffix-matches {d} symbols -> resolved by HASH ORDER\n", .{ s.name, matches });
        }
    }

    for (tab.symbols.items) |a| {
        if (a.kind != .function) continue;
        const ma = tab.moduleOf(a.module);
        if (!std.mem.eql(u8, ma.path, "<root>")) continue;
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

    var canon_collisions: usize = 0;
    for (tab.symbols.items, 0..) |a, i| {
        if (a.kind != .function) continue;
        for (tab.symbols.items[i + 1 ..]) |b| {
            if (b.kind != .function) continue;
            if (!std.mem.eql(u8, a.canonical_mangled, b.canonical_mangled)) continue;
            if (std.mem.eql(u8, a.legacy_mangled, b.legacy_mangled)) continue;
            canon_collisions += 1;
            out("  [NEW-COLLISION] fixing the prefix would map BOTH onto '{s}': {s}:{d} and {s}:{d}\n", .{
                a.canonical_mangled, a.span.file, a.span.line, b.span.file, b.span.line,
            });
        }
    }
    if (canon_collisions == 0) {
        out("  [canonical-prefix] 0 new collisions, the $HOME fix is safe to cut over\n", .{});
    }

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

/// Runs the F2 type stages: lowers every declared type to a TypeId, infers every
/// expression's type into the [`infer.TypedIr`], prints the coverage reports, and
/// enforces the FOUNDATION GATES.
///
/// The flow is: (1) mark tagged enums in the store; (2) lower parameter, return,
/// field and method types via [`lower.Lowerer`], accumulating resolved/unresolved
/// counts; (3) run [`infer.Inferer`] over every function and method (with the
/// correct `self` type and type-param scopes) to build the typed IR; (4) drain
/// the inferer's error lists and, if any are non-empty, print the user-facing
/// diagnostic and [`std.process.exit(1)`], these are the real type-checker errors
/// (visibility, const-reassign, optional-deref, catch/try mismatches, non-bool
/// conditions, optional-return, method arity, generic-method placement, undefined
/// idents/calls); (5) print the F2 coverage summary; (6) when [`report_enabled`],
/// run the [`ownership.analyze`] balance pass and fail the build if any owned value
/// is not provably consumed exactly once.
///
/// The many `l.param_scopes = ...` assignments install the in-scope generic type
/// parameters (struct's, then method's) before lowering/inferring each declaration,
/// and are reset to empty afterwards so a later declaration cannot see stale ones.
fn runTypeLowering(allocator: std.mem.Allocator, program: ast.Program, tab: *const symbols.SymbolTable, sm: *sema_mod.Sema) !void {

    const store = &sm.store;
    live_store = store;

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
    l.symtab = tab;

    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |f| {

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

    var inf = infer.Inferer.init(allocator, store, tab, &l);
    defer inf.deinit();

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

                const self_ty: ?infer.TypeId = blk: {
                    const sid = tab.findTypeInModule(ed.name, tab.findModuleByFile(ed.span.file)) orelse break :blk null;
                    break :blk try store.intern(.{ .enum_ = sid });
                };
                for (ed.methods) |m| {
                    inf.inferFunctionWithSelf(self_ty, &m.decl) catch { walk_errors += 1; };
                }
            },
            .struct_decl => |sd| {

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

    if (inf.visibility_errors.items.len > 0) {

        for (inf.visibility_errors.items) |ve| {
            switch (ve.kind) {
                .function => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}.{s}' is not public, a non-`pub` function cannot be called from another module. Mark it `pub`, or call it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.recv, ve.field },
                ),
                .type_ => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}' is not public, a non-`pub` type cannot be used from another module. Mark it `pub`, or use it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.field },
                ),
                .const_ => std.debug.print(
                    "\x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '{s}' is not public, a non-`pub` const cannot be read from another module. Mark it `pub`, or read it from its own module.\x1b[0m\n",
                    .{ ve.span.file, ve.span.line, ve.span.col, ve.field },
                ),
            }
        }
        std.process.exit(1);
    }

    if (inf.const_reassign_errors.items.len > 0) {

        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.const_reassign_errors.items.len});
        for (inf.const_reassign_errors.items) |ce| {
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m cannot assign to '{s}', it is a `const`. Use `let` for a variable you reassign.\x1b[0m\n",
                .{ ce.span.file, ce.span.line, ce.span.col, ce.name },
            );
        }
        std.process.exit(1);
    }

    if (inf.optional_deref_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.optional_deref_errors.items.len});
        for (inf.optional_deref_errors.items) |oe| {
            const what = if (oe.is_method) "method" else "field";
            switch (oe.kind) {
                .opt => std.debug.print(
                    "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '.{s}', {s} access on a possibly-`undefined` value. Make it present first: `xs.at(i)` / `x ?? default` / `x?.{s}` / narrow with `if (x != undefined) {{ ... }}`.\x1b[0m\n",
                    .{ oe.span.file, oe.span.line, oe.span.col, oe.field, what, oe.field },
                ),
                .err => std.debug.print(
                    "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m '.{s}', {s} access on a `T | E` value that may be an ERROR. Handle it first: `try x` (propagate) or `x catch <fallback>` (specs §3.4b).\x1b[0m\n",
                    .{ oe.span.file, oe.span.line, oe.span.col, oe.field, what },
                ),
            }
        }
        std.process.exit(1);
    }

    if (inf.catch_mismatch_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.catch_mismatch_errors.items.len});
        for (inf.catch_mismatch_errors.items) |ce| {
            const ok_name = renderLegacy(allocator, store, ce.ok) catch "<type>";
            const handler_name = renderLegacy(allocator, store, ce.handler) catch "<type>";
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m catch handler has type '{s}', but the value before `catch` is `{s} | E`, so both must agree, a `catch` yields the ok type. Convert the handler to '{s}' (e.g. return a string on both sides, or map the error to the ok type).\x1b[0m\n",
                .{ ce.span.file, ce.span.line, ce.span.col, handler_name, ok_name, ok_name },
            );
        }
        std.process.exit(1);
    }

    if (inf.try_error_mismatch_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.try_error_mismatch_errors.items.len});
        for (inf.try_error_mismatch_errors.items) |te| {
            const callee_name = renderLegacy(allocator, store, te.callee_err) catch "<type>";
            const fn_name = renderLegacy(allocator, store, te.fn_err) catch "<type>";
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m `try` propagates an error of type '{s}', but the enclosing function is declared to fail with '{s}'. `try` re-raises the error unchanged, so the types must match, `catch` and map to '{s}', or widen the function's error type.\x1b[0m\n",
                .{ te.span.file, te.span.line, te.span.col, callee_name, fn_name, fn_name },
            );
        }
        std.process.exit(1);
    }

    if (inf.cond_type_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.cond_type_errors.items.len});
        for (inf.cond_type_errors.items) |ce| {
            const got_name = renderLegacy(allocator, store, ce.got) catch "<type>";
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m the condition of `{s}` must be a `bool`, but this expression has type '{s}'. Compare explicitly (e.g. `x != 0`, `x != undefined`, `x == SomeEnum.Case`); a non-bool value is not implicitly truthy.\x1b[0m\n",
                .{ ce.span.file, ce.span.line, ce.span.col, ce.ctx, got_name },
            );
        }
        std.process.exit(1);
    }

    if (inf.ret_optional_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.ret_optional_errors.items.len});
        for (inf.ret_optional_errors.items) |re| {
            const ret_name = renderLegacy(allocator, store, re.ret) catch "<type>";
            const val_name = renderLegacy(allocator, store, re.val) catch "<type>";
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m returning a possibly-`undefined` value of type '{s}' where the function is declared to return '{s}'. Make it present first: `x ?? default`, or narrow with `if (x != undefined) {{ return x; }}` and return a fallback otherwise, or widen the return type to '{s}'.\x1b[0m\n",
                .{ re.span.file, re.span.line, re.span.col, val_name, ret_name, val_name },
            );
        }
        std.process.exit(1);
    }

    if (inf.valopt_pos_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.valopt_pos_errors.items.len});
        for (inf.valopt_pos_errors.items) |ve| {
            const want_name = renderLegacy(allocator, store, ve.want) catch "<type>";
            const got_name = renderLegacy(allocator, store, ve.got) catch "<type>";
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m a possibly-`undefined` value of type '{s}' {s} '{s}'. Make it present first: `x ?? default`, or narrow with `if (x != undefined) {{ ... }}`.\x1b[0m\n",
                .{ ve.span.file, ve.span.line, ve.span.col, got_name, ve.ctx, want_name },
            );
        }
        std.process.exit(1);
    }

    if (inf.method_arity_errors.items.len > 0) {
        std.debug.print("Type checking failed with {d} error(s):\n", .{inf.method_arity_errors.items.len});
        for (inf.method_arity_errors.items) |me| {
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m method '{s}' expects {d} argument(s), got {d}.\x1b[0m\n",
                .{ me.span.file, me.span.line, me.span.col, me.name, me.expected, me.got },
            );
        }
        std.process.exit(1);
    }

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
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m generic method `{s}` must be defined INSIDE its type's body, a free `fn {s}<...>(self: ...)` on a generic receiver is not resolvable (put a generic type's methods in the struct, like List/Map/Set).\x1b[0m\n",
                .{ f.span.file, f.span.line, f.span.col, f.name, f.name },
            );
        }
        if (count > 0) std.process.exit(1);
    }

    if (inf.fatal_unresolved_idents > 0) {
        const more = inf.fatal_unresolved_idents - 1;
        if (inf.first_fatal_span) |sp| {
            std.debug.print(
                "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m undefined identifier '{s}'\x1b[0m, not a value, type, module, or known builtin.{s}\n",
                .{ sp.file, sp.line, sp.col, inf.first_fatal_ident orelse "?", if (more > 0) " (first of several)" else "" },
            );
        } else {
            std.debug.print(
                "\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m undefined identifier '{s}'\x1b[0m (and {d} more), not a value, type, module, or known builtin. (F2-5)\n",
                .{ inf.first_fatal_ident orelse "?", more },
            );
        }
        std.process.exit(1);
    }

    if (inf.fatal_unresolved_calls > 0) {
        const sp = inf.first_fatal_call_span orelse ast.Span{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "" };
        std.debug.print(
            "  \x1b[1m{s}:{d}:{d}: \x1b[31merror:\x1b[0m\x1b[1m no function '{s}' in module '{s}'\x1b[0m, check the name and that it is `pub`.\n",
            .{ sp.file, sp.line, sp.col, inf.first_fatal_call_field orelse "?", inf.first_fatal_call_recv orelse "?" },
        );
        std.process.exit(1);
    }

    const etotal = inf.stats.typed + inf.stats.unresolved;
    const pct: usize = if (etotal == 0) 0 else (inf.stats.typed * 100) / etotal;
    out("=== F2 shadow: EXPRESSION surface ===\n", .{});
    out("  expressions seen : {d}\n", .{etotal});
    out("  typed            : {d}  ({d}%)\n", .{ inf.stats.typed, pct });
    out("  UNRESOLVED       : {d}\n", .{inf.stats.unresolved});

    const ns = inf.stats.unresolved_ns_ident + inf.stats.unresolved_ns_field;
    const genuine = inf.stats.unresolved -| ns;
    out("    namespace (not-a-value: module/builtin/access-on-them) : {d}\n", .{ns});
    out("    GENUINE (the real F2-6 coverage debt)                  : {d}\n", .{genuine});
    out("  F2-5 GENUINE-UNDEFINED idents (fatal-ready, must be 0) : {d}\n", .{inf.fatal_unresolved_idents});

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

    const rec = ir.count();
    const unres = ir.unresolvedCount(store);
    const rpct: usize = if (rec == 0) 0 else ((rec - unres) * 100) / rec;
    out("    walk errors (functions sema failed to walk) : {d}\n", .{walk_errors});
    out("  -- TypedIr (authoritative: distinct expressions) --\n", .{});
    out("    recorded   : {d}\n", .{rec});
    out("    typed      : {d}  ({d}%)\n", .{ rec - unres, rpct });
    out("    unresolved : {d}\n", .{unres});

    out("    calls->SymbolId (F1-3b) : {d}\n", .{ir.expr_syms.count()});
    out("=== end F2 shadow (report only) ===\n\n", .{});

    if (report_enabled) {
        const os = ownership.analyze(allocator, store, ir, &program);
        out("=== F2-6 stage 5 step 2: ownership pass (owned-local dup/drop + balance check) ===\n", .{});
        out("  functions walked                     : {d}\n", .{os.fns_walked});
        out("  owned let-locals                     : {d}\n", .{os.owned_locals});
        out("    analyzed (balance claim made+held) : {d}\n", .{os.analyzed});
        out("    deferred (nested CFG/reassign/shadow, increment 2) : {d}\n", .{os.deferred_cfg});
        out("    deferred (init untyped in IR, coverage gap)        : {d}\n", .{os.deferred_untyped});
        out("  ops inserted : drop={d}  move-out={d}  dup={d}\n", .{ os.drop_ops, os.move_outs, os.dup_ops });
        out("  BALANCE VIOLATIONS (use-after-move; MUST be 0)        : {d}\n", .{os.balance_violations});
        if (os.balance_violations > 0) out("    first: owned local '{s}'\n", .{os.first_violation});

        const temp_accounted = os.temp_moves + os.temp_drops;
        const temp_total = ir.ownedTrueCount();
        const tpct: usize = if (temp_total == 0) 100 else (temp_accounted * 100) / temp_total;
        out("  owned TEMPORARIES: move={d}  drop={d}  accounted={d}/{d} ({d}%)  unaccounted={d}\n", .{ os.temp_moves, os.temp_drops, temp_accounted, temp_total, tpct, temp_total -| temp_accounted });
        out("=== end ownership pass ===\n\n", .{});

        if (os.balance_violations > 0 or temp_accounted < temp_total) {
            std.debug.print(
                "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F2-6 ownership balance):\x1b[0m\x1b[1m an owned value is not provably consumed exactly once\x1b[0m\n" ++
                "  LOCALS use-after-move violations : {d}   (MUST be 0, a use-after-move is a UAF)\n" ++
                "  TEMPORARIES unaccounted          : {d}   (MUST be 0, an owned temp with no move/drop is a leak-shaped hole)\n" ++
                "  first local violation: '{s}'\n" ++
                "  The static balance check found an owned value the pass cannot prove is consumed exactly\n" ++
                "  once. That is the leak / use-after-free class this pass exists to catch AT BUILD TIME.\n",
                .{ os.balance_violations, temp_total -| temp_accounted, os.first_violation },
            );
            std.process.exit(1);
        }
    }
}

/// Prints how often legacy callee resolution fell through to the fragile suffix
/// scan, and how many of those were ambiguous or resolved to nothing.
///
/// A no-op unless [`trace_resolution`]. Reads [`scan_hits`], [`scan_ambiguous`],
/// [`scan_unresolved`]; a non-zero ambiguous or unresolved count is the concrete
/// evidence that the legacy path is unsafe and the symbol table must replace it.
pub fn reportResolution() void {
    if (!trace_resolution) return;
    std.debug.print("\n=== F1 shadow: resolveCalleeName suffix-scan usage ===\n", .{});
    std.debug.print("  fell through to a SUFFIX SCAN : {d}\n", .{scan_hits});
    std.debug.print("  ...of those, AMBIGUOUS (>1 candidate) : {d}\n", .{scan_ambiguous});
    std.debug.print("  resolved to NOTHING (silent failure)  : {d}\n", .{scan_unresolved});
    std.debug.print("=== end ===\n\n", .{});
}

/// F5 ownership decision: times the string engine and `isOwnedTypeId` AGREE on
/// a concrete type.
pub var td_agree: usize = 0;
/// F5: times they DISAGREE on a concrete type, MUST be 0 before cutover, since a
/// divergent ownership decision is a use-after-free or leak; fails the F5-2 gate.
pub var td_disagree: usize = 0;
/// F5: decisions blocked because the type is an unbound method type-param
/// (decided by the principled erasure rule: unbound → non-owned).
pub var td_blocked_typeparam: usize = 0;
/// F5: decisions blocked because the body is erased with no instantiation context
/// (same erasure rule applies).
pub var td_blocked_noctx: usize = 0;
/// F5: type-param decisions the "keystone" substitution RESOLVED to a concrete
/// type in the store, and which then agreed with the string engine.
pub var td_keystone_resolves: usize = 0;
/// F5: keystone-substituted decisions that DISAGREED, MUST be 0 (a keystone bug);
/// fails the F5-2 gate alongside [`td_disagree`].
pub var td_keystone_disagree: usize = 0;
/// F5: decisions blocked because the type was unresolved (an F2-5 fatal).
pub var td_blocked_unresolved: usize = 0;
/// F5: decisions blocked on an enum (needs variant-aware ownership awareness).
pub var td_blocked_enum: usize = 0;

/// F2-6 disposition: times the checker's ownership disposition matches codegen's
/// `acquisitionDisposition`.
pub var disp_agree: usize = 0;
/// F2-6: times they DISAGREE (see the residue breakdown; only `.other` is fatal).
pub var disp_disagree: usize = 0;

/// The explained categories a disposition disagreement can fall into.
///
/// `type_param`, `enum_` and `not_owned` are gate-proven-safe boundaries (safe
/// direction: the checker under-claims owned, never over-claims); `other` is an
/// unexplained divergence and MUST be 0, it fails the F2-6 disposition gate.
pub const DispResidue = enum { type_param, enum_, not_owned, other };
/// Disposition disagreements on a generic erased return (`.type_param`), closed
/// by monomorphization at F4, safe.
pub var disp_disagree_typeparam: usize = 0;
/// Disposition disagreements on an enum (`.enum_`), safe-direction under-claim,
/// verified ASAN-clean across the corpus.
pub var disp_disagree_enum: usize = 0;
/// Disposition disagreements on a non-owned primitive (`.not_owned`), no
/// retain/release either way, so harmless.
pub var disp_disagree_not_owned: usize = 0;
/// Disposition disagreements with NO explanation (`.other`), a real disposition
/// bug; MUST be 0 or [`reportTypeIdDiff`] fails the build.
pub var disp_disagree_other: usize = 0;
/// Expression kind of the most recent `.other` disagreement, for the diagnostic.
pub var disp_last_kind: []const u8 = "";
/// Type name of the most recent `.other` disagreement, for the diagnostic.
pub var disp_last_type: []const u8 = "";

/// F2-6 temp ops: times codegen's per-expression drop/move matches the pass's op.
pub var op_agree: usize = 0;
/// F2-6: times they DISAGREE, must stay within the two explained buckets below.
pub var op_disagree: usize = 0;
/// Disagreements where codegen DROPPED but the pass said move (return retain+drop
/// or trait-coercion copy+drop, the pass is right; the flip removes the redundancy).
pub var op_disagree_cg_drop: usize = 0;
/// Disagreements where codegen MOVED but the pass said drop (constructor/consuming
/// args, needs the `consuming` mark the pass lacks).
pub var op_disagree_cg_move: usize = 0;
/// Explicitly-registered temporaries the pass never saw (no pass op), expected.
pub var op_no_op: usize = 0;
/// Type name of the most recent temp-op disagreement, for the diagnostic.
pub var op_last_disagree: []const u8 = "";
/// Rendered type of the most recent concrete F5 ownership disagreement.
pub var td_last_disagree: []const u8 = "";
/// The typed engine's ownership verdict for [`td_last_disagree`].
pub var td_last_disagree_typed: bool = false;
/// The string engine's ownership verdict for [`td_last_disagree`].
pub var td_last_disagree_string: bool = false;

/// Stage-4 destructor naming: times the dtor name from the TypeId matches the
/// name from the legacy string.
pub var dtor_name_agree: usize = 0;
/// Stage-4: times the dtor names DISAGREE, MUST be 0 to key dtors on TypeId.
pub var dtor_name_disagree: usize = 0;
/// Stage-4: sites with no TypeId, so the dtor name still comes from the string.
pub var dtor_name_no_id: usize = 0;
/// String-derived dtor name of the most recent stage-4 disagreement.
pub var dtor_name_last_disagree_string: []const u8 = "";
/// TypeId-derived dtor name of the most recent stage-4 disagreement.
pub var dtor_name_last_disagree_typed: []const u8 = "";

/// Stage-4 RAW (no `substTypeParams`): agreements, a 0 disagree count proves
/// the substitution is redundant when draining dtors.
pub var dtor_name_raw_agree: usize = 0;
/// Stage-4 RAW: disagreements between the substituted and un-substituted names.
pub var dtor_name_raw_disagree: usize = 0;
/// The most recent raw-only rendered dtor name, for the diagnostic.
pub var dtor_name_raw_last: []const u8 = "";

/// Stage-4 tuple element dtors: times building from store elements matches parsing.
pub var tuple_elem_agree: usize = 0;
/// Stage-4 tuple: disagreements, 0 means tuple dtors can be built from the store.
pub var tuple_elem_disagree: usize = 0;
/// The most recent tuple-element mismatch, for the diagnostic.
pub var tuple_elem_last: []const u8 = "";

/// Stage-4 error-union arm dtors: store-vs-parse agreements.
pub var erru_elem_agree: usize = 0;
/// Stage-4 error-union: disagreements.
pub var erru_elem_disagree: usize = 0;
/// The most recent error-union arm mismatch, for the diagnostic.
pub var erru_elem_last: []const u8 = "";
/// Stage-4 storage-element dtors: store-vs-parse agreements.
pub var storage_elem_agree: usize = 0;
/// Stage-4 storage: disagreements.
pub var storage_elem_disagree: usize = 0;
/// The most recent storage-element mismatch, for the diagnostic.
pub var storage_elem_last: []const u8 = "";

/// Stage-4 struct-field dtors: store-vs-parse agreements.
pub var struct_field_agree: usize = 0;
/// Stage-4 struct fields: disagreements, 0 means struct dtors can be built from
/// the store's field list.
pub var struct_field_disagree: usize = 0;
/// The most recent struct-field mismatch, for the diagnostic.
pub var struct_field_last: []const u8 = "";
/// Baseline count of legacy string-ownership calls made during the shadow run.
pub var a2_irct_calls: usize = 0;
/// Of those, the ones on a composite (non-primitive) type.
pub var a2_irct_composite: usize = 0;

/// Stage-5 PhaseA release-site: times the store-native dtor was selected (flip).
pub var phaseA_flip: usize = 0;
/// Stage-5 PhaseA: times an unresolved type-param in an erased body kept the
/// string path (split).
pub var phaseA_split: usize = 0;
/// Stage-5 PhaseA: release sites with no TypeId at all.
pub var phaseA_no_id: usize = 0;
/// The most recent PhaseA split case, for the diagnostic.
pub var phaseA_split_last: []const u8 = "";

/// Prints the F5 ownership-decision diff, the F2-6 temp-op diff, and the F2-6
/// disposition diff, then enforces their gates.
///
/// A no-op unless [`report_enabled`]. After printing, it fails the build (prints
/// a FOUNDATION GATE diagnostic and [`std.process.exit(1)`]) if
/// [`disp_disagree_other`] is non-zero (an unexplained checker-vs-codegen
/// ownership divergence) or if [`td_disagree`]/[`td_keystone_disagree`] is
/// non-zero (the string and TypeId ownership engines decided differently). Those
/// are precisely the latent-corruption shapes the migration must not ship.
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
    out("    .type_param keystone-DISAGREE : {d}  (MUST be 0, a keystone bug)\n", .{td_keystone_disagree});
    out("    .type_param method-param      : {d}  (map<U>, decided by PRINCIPLED ERASURE RULE: unbound -> non-owned) ✅\n", .{td_blocked_typeparam});
    out("    .type_param no-inst-ctx       : {d}  (erased body, decided by PRINCIPLED ERASURE RULE: unbound -> non-owned) ✅\n", .{td_blocked_noctx});
    out("    .unresolved  : {d}  (F2-5: unresolved fatal)\n", .{td_blocked_unresolved});
    out("    .enum_       : {d}  (isOwned enum-variant awareness)\n", .{td_blocked_enum});
    out("=== end string→TypeId shadow-diff ===\n\n", .{});

    if (op_agree + op_disagree + op_no_op > 0) {
        out("=== F2-6 stage 5 step 5: temp ops, codegen action vs pass op (per ExprId) ===\n", .{});
        out("  agree    : {d}  (codegen's drop/move matches the pass)\n", .{op_agree});
        out("  DISAGREE : {d}  (MUST be a known set before the flip)\n", .{op_disagree});
        out("    codegen DROPPED, pass said move : {d}  (return retain+drop / trait-coercion copy+drop, pass is right, the FLIP removes codegen's redundancy)\n", .{op_disagree_cg_drop});
        out("    codegen MOVED, pass said drop   : {d}  (constructor/consuming args, needs the arc.md §3 `consuming` mark the pass lacks)\n", .{op_disagree_cg_move});
        if (op_disagree > 0) out("    last-disagree type: {s}\n", .{op_last_disagree});
        out("  no pass op: {d}  (explicitly-registered temps the pass never saw, expected)\n", .{op_no_op});

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
        out("  stage 5 PhaseA release-site flip: flip={d} (store-native selected)  split={d} (unresolved type-param in erased body, kept string)  no-id={d}\n", .{ phaseA_flip, phaseA_split, phaseA_no_id });
        if (phaseA_split > 0) out("    last split: '{s}'\n", .{phaseA_split_last});
        out("  ownedByName split: primitive={d}  resolved-by-TypeId={d}  erased-residual={d}  (L1 migration: only bare type-params in dead erased bodies should remain in erased-residual)\n", .{ irct_primitive, irct_resolved, irct_string_decided });
        out("  legacyStringOwnership calls (shadow baseline only): {d}\n", .{a2_irct_calls});
        out("=== end temp-op diff ===\n\n", .{});
    }

    const disp_total = disp_agree + disp_disagree;
    if (disp_total > 0) {
        out("=== F2-6 stage 5: checker ownership-disposition vs codegen acquisitionDisposition ===\n", .{});
        out("  occurrences compared : {d}\n", .{disp_total});
        out("    agree    : {d}\n", .{disp_agree});
        out("    DISAGREE : {d}   (all in the SAFE direction: checker under-claims owned, never over-claims)\n", .{disp_disagree});
        out("      .type_param (generic erased return -> codegen monomorphizes to owned; closes with F4) : {d}\n", .{disp_disagree_typeparam});
        out("      .enum_      (SAFE: variant-aware ownership; safe-direction under-claims, ASAN-clean corpus)   : {d}\n", .{disp_disagree_enum});
        out("      .not_owned  (SAFE: disagreement on a non-owned primitive; no retain/release either way)   : {d}\n", .{disp_disagree_not_owned});
        out("      OTHER       (unexplained, a real disposition bug; MUST be 0)                            : {d}\n", .{disp_disagree_other});
        if (disp_disagree_other > 0) out("        e.g. kind='{s}' type='{s}'\n", .{ disp_last_kind, disp_last_type });
        out("=== end disposition shadow-diff ===\n\n", .{});
    }

    if (disp_disagree_other > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F2-6 disposition):\x1b[0m\x1b[1m an UNEXPLAINED checker-vs-codegen ownership-disposition divergence appeared\x1b[0m\n" ++
            "  OTHER  disagreements : {d}   (MUST be 0, an unexplained checker-vs-codegen ownership divergence)\n" ++
            "  last OTHER: kind='{s}' type='{s}'\n" ++
            "  Allowed, gate-proven-safe boundaries (do NOT fail the gate): `.type_param` (erased container\n" ++
            "  methods), `.enum_` (variant-aware ownership; the disagreements are safe-direction under-claims,\n" ++
            "  verified ASAN-clean across the corpus), and `.not_owned` (a primitive that is never retained).\n" ++
            "  OTHER is a NEW ownership guess, the corruption class F2-6 exists to eliminate. Fix it before this lands.\n",
            .{ disp_disagree_other, disp_last_kind, disp_last_type },
        );
        std.process.exit(1);
    }

    if (td_disagree > 0 or td_keystone_disagree > 0) {
        std.debug.print(
            "\x1b[1m\x1b[31mFOUNDATION GATE FAILED (F5-2):\x1b[0m\x1b[1m the string ownership engine and the TypeId engine DISAGREE\x1b[0m\n" ++
            "  concrete disagreements: {d}   keystone-substitution disagreements: {d}   (both MUST be 0)\n" ++
            "  last: '{s}'  typed-engine={}  string-engine={}\n" ++
            "  Ownership is being decided differently by name-matching vs the type store, the exact\n" ++
            "  latent-corruption class F5 exists to eliminate. A value one engine frees and the other keeps\n" ++
            "  is a use-after-free or a leak. Fix the divergence before this lands.\n",
            .{ td_disagree, td_keystone_disagree, td_last_disagree, td_last_disagree_typed, td_last_disagree_string },
        );
        std.process.exit(1);
    }
}

/// F1 stage-3b: times `symOf(call)`'s legacy_mangled matches the func-map scan.
pub var f1_3b_agree: usize = 0;
/// F1-3b: times the SymbolId and the scan DISAGREE.
pub var f1_3b_disagree: usize = 0;
/// F1-3b: calls with no SymbolId recorded, so the scan is still needed.
pub var f1_3b_sym_absent: usize = 0;
/// The SymbolId-resolved name of the most recent F1-3b disagreement.
pub var f1_3b_last_disagree_sym: []const u8 = "";
/// The scan-resolved name of the most recent F1-3b disagreement.
pub var f1_3b_last_disagree_scan: []const u8 = "";

/// Histogram of call names that had NO SymbolId (still resolved by scan), keyed
/// by name; populated by [`noteF13bAbsent`] and printed by [`reportDiff`].
pub var f1_3b_absent_names: std.StringHashMapUnmanaged(usize) = .empty;
/// Records one occurrence of a call `name` that lacked a SymbolId.
///
/// Increments the per-name count in [`f1_3b_absent_names`]; a failed allocation is
/// swallowed (this is diagnostics, never worth failing a compile over).
pub fn noteF13bAbsent(a: std.mem.Allocator, name: []const u8) void {
    const gop = f1_3b_absent_names.getOrPut(a, name) catch return;
    if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
}

/// F4-5: method resolutions that reached a CONCRETE monomorphized body.
pub var f45_mono_hit: usize = 0;
/// F4-5: fallbacks to an ERASED body carrying an INSTANTIATED name, residual
/// reliance that MUST reach 0.
pub var f45_erased_fallback: usize = 0;
/// F4-5: correct fallbacks to an erased body (non-generic or genuinely erased ctx).
pub var f45_erased_nongeneric: usize = 0;
/// Histogram of the missing mono symbols behind erased fallbacks, keyed by name;
/// filled by [`noteF45Erased`] and printed by [`reportF45`].
pub var f45_erased_by_name: std.StringHashMapUnmanaged(usize) = .empty;
/// Records one erased-fallback occurrence for the missing mono symbol name.
///
/// A no-op unless [`report_enabled`]. On first insertion the name is duplicated
/// into the allocator so the key outlives the transient caller buffer; a failed
/// dupe degrades to storing the borrowed slice rather than failing.
pub fn noteF45Erased(a: std.mem.Allocator, missing_mono: []const u8) void {
    if (!report_enabled) return;

    const gop = f45_erased_by_name.getOrPut(a, missing_mono) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
    } else {
        gop.key_ptr.* = a.dupe(u8, missing_mono) catch missing_mono;
        gop.value_ptr.* = 1;
    }
}
/// Prints the F4-5 erased-vs-monomorphized method-resolution summary, listing up
/// to 20 of the missing mono symbols behind any residual erased fallbacks.
///
/// A no-op unless [`report_enabled`]. The `erased_fallback` line reaching 0 is the
/// success condition (every generic method resolves to its concrete body).
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

/// F2 stage-3: expressions where the typed IR and the legacy resolver AGREE.
pub var diff_agree: usize = 0;
/// F2 stage-3: the legacy resolver ANSWERED but F2 says `<unresolved>`, a legacy
/// "invention" (the string path guessed a type the typed engine could not justify).
pub var diff_legacy_invented: usize = 0;
/// F2 stage-3: F2 typed the expression where the legacy resolver gave up.
pub var diff_f2_better: usize = 0;
/// F2 stage-3: both answered but DIFFERENTLY (a genuine coverage/accuracy debt).
pub var diff_disagree: usize = 0;
/// F2 stage-3: codegen asked about an expression that is NOT in the IR (sema never
/// walked it), the "absent" case broken down by tag/function below.
pub var diff_absent: usize = 0;

/// Histogram of AST tags for the `diff_absent` expressions (which node kinds
/// codegen asks about that sema never recorded).
pub var diff_absent_tags: std.StringHashMapUnmanaged(usize) = .empty;

/// Histogram of the functions codegen was compiling when it hit an absent
/// expression, keyed by mangled function name.
pub var diff_absent_fns: std.StringHashMapUnmanaged(usize) = .empty;
/// Count of functions the inferer FAILED to walk (each caught error bumps this).
pub var walk_errors: usize = 0;
/// Set of function names sema successfully walked; used by [`reportDiff`] to answer
/// "did sema actually see this function?" for each absent-expression cluster.
pub var walked_fns: std.StringHashMapUnmanaged(void) = .empty;
/// Ring of up to 8 "file:line (tag)" strings for the first absent expressions, so
/// the report can show WHERE the gaps are without unbounded memory.
var absent_spans: [8][]const u8 = undefined;
/// Number of valid entries in [`absent_spans`].
var absent_span_n: usize = 0;

/// Extracts the source span of an expression, for report location strings.
///
/// Returns `null` for expression kinds that carry no span field (literals,
/// identifiers, etc.); only the compound kinds that own a `.span` are handled.
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
/// The allocator most recently seen by [`recordDiff`], stashed so the deferred
/// report ([`reportDiff`]) can allocate/free its scratch without re-threading it.
pub var diff_absent_alloc: ?std.mem.Allocator = null;
/// Ring of up to 12 example divergences as `{tag, legacy, f2}` triples, shown in
/// the report so a reader sees concrete shapes, not just counts.
var diff_examples: [12][3][]const u8 = undefined;
/// Number of valid entries in [`diff_examples`].
var diff_example_n: usize = 0;

/// Rewrites a rendered type string so the LLVM-style primitive names and Nova's
/// surface aliases become ONE canonical spelling, so the two engines are compared
/// on the type they mean, not on how each spells it.
///
/// `i32`→`int`, `u8`/`ubyte`→`byte`, `f64`→`double`, and so on, applied only at
/// whole-token boundaries (via [`isIdentChar`]) so `myi32var` and `i32_helper` are
/// left untouched, a rewriter that "invented" agreement inside identifiers would
/// be worse than none. Returns the input slice unchanged if nothing matched or an
/// allocation failed; otherwise an owned slice the caller frees.
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

/// True if `c` can appear inside a Nova identifier (alphanumeric or `_`).
///
/// Used by [`canonicalTypeStr`] to decide whether an alias match sits at a real
/// token boundary rather than in the middle of a longer name.
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Renders a [`typesys.TypeId`] to its legacy human-readable name, going through
/// [`sema_mod.Sema`]'s interned-name cache when a live sema is installed.
///
/// The cache path exists because rendering composite types allocates and this is
/// called a great deal: a cache hit returns the interned string directly; a miss
/// renders via [`renderUncached`] and, only for types that actually allocate (see
/// [`allocatesFor`]), interns the result and frees the transient copy. With no
/// [`live_sema`] it renders uncached every time. Propagates allocation errors.
pub fn renderLegacy(allocator: std.mem.Allocator, store: *const typesys.TypeStore, id: typesys.TypeId) anyerror![]const u8 {
    render_calls += 1;
    if (live_sema) |sm| {
        if (sm.cachedName(id)) |n| {
            render_cache_hits += 1;
            return n;
        }
        const rendered = try renderUncached(allocator, store, id);
        if (allocatesFor(store.get(id))) {
            const interned = try sm.internName(id, rendered);
            allocator.free(rendered);
            return interned;
        }
        return rendered;
    }
    return try renderUncached(allocator, store, id);
}

/// True if rendering this type ALLOCATES a fresh name string (and so is worth
/// caching): a generic struct (`args.len > 0`), a storage type, or a function type.
///
/// Non-generic structs, enums, primitives etc. render to a borrowed slice and do
/// not need caching; [`renderLegacy`] uses this to decide whether to intern.
fn allocatesFor(t: typesys.Type) bool {
    return switch (t) {
        .struct_ => |st| st.args.len > 0,
        .storage => true,
        .func => true,
        else => false,
    };
}

/// Renders a [`typesys.TypeId`] to its legacy name WITHOUT consulting the cache.
///
/// Handles every variant of [`typesys.Type`]: primitives map to their legacy
/// spelling (note the SIMD-encoded widths like `8016`→`u8x16` and `float` bits
/// `256`→`f64x4`), composites (struct/func/tuple/error-union/storage) recurse
/// through [`renderLegacy`] and allocate, and `optional` boxes only when the inner
/// type is a non-void primitive or a non-owned enum (matching how the codegen
/// represents `T | undefined`). Struct/enum/trait names come from [`diff_tab`],
/// which MUST be installed (via [`setDiffTable`]) or this dereferences null.
/// `future` deliberately renders as `i64` (its runtime representation).
fn renderUncached(allocator: std.mem.Allocator, store: *const typesys.TypeStore, id: typesys.TypeId) anyerror![]const u8 {
    return switch (store.get(id)) {
        .unresolved => "<unresolved>",
        .string => "string",
        // `Html` renders as `string` for codegen: it IS a string at runtime and
        // must take every string codegen path. The nominal distinction is carried
        // by the TypeId itself and read only by the NSX escape decision (via
        // `isHtmlExpr`), never by name.
        .html => "string",
        .decimal => "decimal",
        .any_ => "any",

        .error_union => |eu| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.appendSlice(allocator, "ErrUnion(");
            try buf.appendSlice(allocator, try renderLegacy(allocator, store, eu.ok));
            try buf.append(allocator, ',');
            try buf.appendSlice(allocator, try renderLegacy(allocator, store, eu.err));
            try buf.append(allocator, ')');
            break :blk try buf.toOwnedSlice(allocator);
        },
        .ptr => "ptr",

        .prim => |p| switch (p.kind) {
            .bool => "bool",
            .void_ => "void",
            .float => if (p.bits == 256) "f64x4" else if (p.bits == 32) "f32" else "f64",
            .int => switch (p.bits) {
                1 => "bool",
                8 => if (p.signed) "i8" else "u8",
                16 => if (p.signed) "i16" else "u16",
                64 => if (p.signed) "i64" else "u64",
                8016 => "u8x16",
                32004 => "u32x4",
                64002 => "u64x2",
                else => if (p.signed) "i32" else "u32",
            },
        },
        .struct_ => |st| blk: {
            const sym = diff_tab.?.symbolAt(st.decl);

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
        .enum_ => |sid| blk: {
            const sym = diff_tab.?.symbolAt(sid);
            break :blk sym.scoped_name orelse sym.name;
        },
        .trait_ => |sid| diff_tab.?.symbolAt(sid).name,

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
        .optional => |inner| blk: {
            const inner_r = try renderLegacy(allocator, store, inner);
            const boxed = switch (store.get(inner)) {
                .prim => |p| p.kind != .void_,
                .enum_ => !store.isOwned(inner),
                else => false,
            };
            if (!boxed) break :blk inner_r;
            break :blk try std.fmt.allocPrint(allocator, "{s} | undefined", .{inner_r});
        },

        .future => "i64",

        .storage => |elem| blk: {
            var buf = std.ArrayListUnmanaged(u8).empty;
            try buf.appendSlice(allocator, "Storage<");
            try buf.appendSlice(allocator, try renderLegacy(allocator, store, elem));
            try buf.append(allocator, '>');
            break :blk try buf.toOwnedSlice(allocator);
        },

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

        .type_param => |tp| typeParamName(tp) orelse "<T>",
    };
}

/// Resolves a [`typesys.TypeParam`] back to its declared NAME (e.g. `T`, `K`) by
/// looking up its owner symbol's type-parameter list in [`diff_tab`].
///
/// Returns `null` if the table is not installed, the owner is neither a function
/// nor a struct, or the index is out of range; [`renderUncached`] then falls back
/// to `<T>`.
fn typeParamName(tp: typesys.TypeParam) ?[]const u8 {
    const tab = diff_tab orelse return null;
    const owner = tab.symbolAt(tp.owner);
    const names: []const []const u8 = switch (owner.decl) {
        .function => |f| f.type_params,
        .struct_ => |s| s.type_params,

        else => return null,
    };
    if (tp.index >= names.len) return null;
    return names[tp.index];
}

/// Histogram of divergence "clusters": distinct `kind name in fn: legacy -> f2`
/// keys mapped to how many times that exact shape occurred, so the report can rank
/// the biggest systematic gaps rather than list every instance.
pub var diff_clusters: std.StringHashMapUnmanaged(usize) = .empty;

/// For each cluster key in [`diff_clusters`], one representative `file:line` so the
/// report can point at a concrete example of the shape.
pub var diff_cluster_where: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Extracts a short human "name" for an expression to make a cluster key readable:
/// the identifier, the accessed field, or a call's callee name.
///
/// Returns `null` for expressions with no obvious name (e.g. a call on a computed
/// callee); [`noteCluster`] then keys on the shape alone.
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

/// Records one `legacy -> f2` divergence into the [`diff_clusters`] histogram,
/// building a readable key from the expression's kind, name hint and enclosing fn.
///
/// On first sighting of a key it also stores a `file:line` example in
/// [`diff_cluster_where`]; on a repeat it increments the count and FREES the
/// freshly-formatted key (the stored one is kept). Allocation failures are
/// swallowed, losing a diagnostic must never break a compile.
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

/// The symbol table the renderers ([`renderUncached`], [`typeParamName`]) resolve
/// struct/enum/trait/type-param names through; installed by [`setDiffTable`].
var diff_tab: ?*const symbols.SymbolTable = null;
/// Installs the symbol table used for name resolution during rendering.
///
/// Must be called (it is, from [`run`]) before any [`renderLegacy`] on a
/// struct/enum/trait/type-param, or that render dereferences a null [`diff_tab`].
pub fn setDiffTable(t: *const symbols.SymbolTable) void {
    diff_tab = t;
}

/// Compares the legacy string type-name for one expression against the typed IR's
/// answer and files the result into the F2 stage-3 counters.
///
/// The instrumentation seam codegen calls per expression. If the IR has NO type
/// for `e`, it counts [`diff_absent`] (with tag/fn/span breakdown) and returns.
/// Otherwise it renders the IR type, canonicalises both sides with
/// [`canonicalTypeStr`] so spelling differences do not read as disagreements, and
/// classifies: legacy-invented (IR unresolved but legacy answered), agree, or
/// disagree (recording a cluster + example). When `legacy` is null it credits F2
/// for typing something legacy could not. Errors are swallowed, this must not
/// perturb codegen.
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

/// Prints the accumulated F1-3b (SymbolId vs scan) and F2 stage-3 (TypedIr vs
/// legacy) diffs, including absent-expression locations and the clustered
/// divergences ranked biggest-first.
///
/// A no-op unless [`trace_resolution`]. Purely a reporter over the `f1_3b_*`,
/// `diff_*`, `diff_clusters`, `walked_fns` and `absent_spans` state that
/// [`recordDiff`] and friends accumulated; it never fails the build. Uses
/// [`diff_absent_alloc`] for the temporary sort buffer.
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

/// Alias for `std.testing`, used by the unit tests below.
const testing = std.testing;

// Verifies [`canonicalTypeStr`] folds each LLVM-style primitive spelling onto its
// Nova alias (`i32`→`int`, `f64`→`double`, ...), including nested inside generic
// arguments (`Map<string, i32>`→`Map<string, int>`), so two engines naming the
// same type never read as a disagreement.
test "canonicalTypeStr: i32 and int are ONE type, so they must render as one word" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "i32", .want = "int" },
        .{ .in = "int", .want = "int" },
        .{ .in = "f64", .want = "double" },
        .{ .in = "i64", .want = "long" },
        .{ .in = "u32", .want = "uint" },

        .{ .in = "i8", .want = "sbyte" },
        .{ .in = "u8", .want = "byte" },
        .{ .in = "i16", .want = "short" },
        .{ .in = "u16", .want = "ushort" },
        .{ .in = "f32", .want = "float" },

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

// Verifies [`canonicalTypeStr`] rewrites ONLY at whole-token boundaries: aliases
// embedded in longer identifiers (`myi32var`, `i32_helper`, `Xi32`) and
// non-alias strings are returned untouched, so the canonicaliser can never invent
// a false agreement.
test "canonicalTypeStr: only whole tokens, a rewriter that invents agreement is worse than none" {
    const a = testing.allocator;

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
