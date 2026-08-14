// driver.zig — the middle-end entry point.
//
// Orchestrates AST+TypedIr -> HIR -> MIR -> [optimiser passes] -> LIR, running the MIR verifier after
// every pass in debug builds. This is what builder.zig calls between sema and codegen (gated by NOVA_OPT
// during the rollout; see docs/design/optimiser.md).
//
// Status: M1 lowering complete (AST->HIR->MIR->LIR) + M2 verifier + M3 passes (mem2reg/constfold/
// copyprop/dce/simplifycfg) firing; M4 arc_elision + M5 inline implemented + unit-tested but dormant
// until ARC-op / call-graph threading. The middle-end does NOT yet EMIT (codegen still lowers from the
// AST); NOVA_OPT runs the whole chain as a shadow and reports coverage. See docs/design/optimiser.md.

const std = @import("std");
const builtin = @import("builtin");

const ast = @import("../frontend/ast.zig");
const infer = @import("../frontend/sema/infer.zig");
const symbols = @import("../frontend/sema/symbols.zig");
const inline_pass = @import("passes/inline.zig");
const hir = @import("hir.zig");
const mir = @import("mir.zig");
const lir = @import("lir.zig");
const pass = @import("pass.zig");
const verify = @import("verify.zig");

const lower_ast_hir = @import("lower_ast_hir.zig");
const lower_hir_mir = @import("lower_hir_mir.zig");
const lower_mir_lir = @import("lower_mir_lir.zig");

// The pass pipeline, in dependency order (see the doc). All no-ops until M3/M4.
pub const pipeline = [_]pass.Pass{
    @import("passes/mem2reg.zig").pass,
    @import("passes/constfold.zig").pass,
    @import("passes/copyprop.zig").pass,
    @import("passes/dce.zig").pass,
    @import("passes/arc_elision.zig").pass,
    @import("passes/inline.zig").pass,
    @import("passes/simplifycfg.zig").pass,
};

// Optimise one MIR function: run the pipeline to a bounded fixpoint, verifying after each sweep in debug
// builds. Returns the number of sweeps performed.
pub fn optimise(allocator: std.mem.Allocator, func: *mir.Func) !usize {
    const sweeps = try pass.runToFixpoint(allocator, func, &pipeline, 16);
    if (builtin.mode == .Debug) {
        const violations = try verify.verify(allocator, func);
        defer allocator.free(violations);
        std.debug.assert(violations.len == 0);
    }
    return sweeps;
}

pub const Coverage = struct {
    funcs: usize = 0,
    nodes: usize = 0,
    unsupported: usize = 0,
    mir_blocks: usize = 0,
    mir_insts: usize = 0,
    verify_errors: usize = 0,
    insts_removed: usize = 0, // by the optimiser pipeline (mem2reg/constfold/dce/...)
    lir_ops: usize = 0,
    arc_ops: usize = 0, // retain/release ops threaded into MIR (before opt)
    arc_removed: usize = 0, // retain/release ops removed (mostly by arc_elision)
    typed_values: usize = 0, // MIR values carrying a real (non-placeholder) TypeId
    total_values: usize = 0,
    calls_total: usize = 0,
    calls_resolved: usize = 0, // call ops whose callee SymbolId is resolved (not the unresolved sentinel)
    calls_inlined: usize = 0, // calls replaced by inlining a small callee (M5)
};

// M1a shadow: lower every function in the program AST->HIR and report coverage. Does NOT emit; the AST
// path still produces the program. Gated by NOVA_OPT in builder.zig. Never fatal: a lowering that hits a
// not-yet-handled form records it as `.unsupported` and keeps going, so this is safe to run over the whole
// corpus. Prints a summary and, with NOVA_OPT_VERBOSE, the unsupported-tag histogram.
pub fn lowerProgramShadow(allocator: std.mem.Allocator, program: ast.Program, ir: ?*const infer.TypedIr, tab: ?*const symbols.SymbolTable, verbose: bool) !Coverage {
    var cov = Coverage{};
    var unsupported_by_tag = std.StringHashMap(usize).init(allocator);
    defer unsupported_by_tag.deinit();

    // Two-pass: lower ALL functions to MIR first (so a call graph exists), then inline + optimise each.
    var funcs = std.ArrayListUnmanaged(mir.Func).empty;
    defer {
        for (funcs.items) |*f| f.deinit(allocator);
        funcs.deinit(allocator);
    }
    var own_syms = std.ArrayListUnmanaged(?mir.SymbolId).empty;
    defer own_syms.deinit(allocator);

    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                const s: ?mir.SymbolId = if (tab) |t| t.findFunction(fd.name) else null;
                try lowerToMir(allocator, fd, ir, s, &cov, &unsupported_by_tag, &funcs, &own_syms);
            },
            .struct_decl => |sd| for (sd.methods) |m| {
                try lowerToMir(allocator, m.decl, ir, null, &cov, &unsupported_by_tag, &funcs, &own_syms);
            },
            else => {},
        }
    }

    // Build the call graph: single-block, small, symbol-resolved functions are the inline candidates.
    for (funcs.items, own_syms.items) |*f, s| {
        if (s) |sv| f.sym = sv;
    }
    var callees = std.ArrayListUnmanaged(inline_pass.Callee).empty;
    defer callees.deinit(allocator);
    for (funcs.items, own_syms.items) |*f, s| {
        if (s) |sv| {
            if (f.blocks.items.len == 1 and countInsts(f) <= 16) {
                try callees.append(allocator, .{ .sym = sv, .func = f });
            }
        }
    }

    // Pass 2: inline small callees (M5), then run the optimiser pipeline + lower to LIR, measuring.
    for (funcs.items) |*f| {
        const calls_before = countCalls(f);
        _ = inline_pass.inlineSmallCallees(allocator, f, callees.items, 16) catch false;
        const calls_after = countCalls(f);
        if (calls_before > calls_after) cov.calls_inlined += calls_before - calls_after;

        const before = countInsts(f);
        const arc_before = countArc(f);
        cov.arc_ops += arc_before;
        _ = optimise(allocator, f) catch 0;
        const after = countInsts(f);
        if (before > after) cov.insts_removed += before - after;
        const arc_after = countArc(f);
        if (arc_before > arc_after) cov.arc_removed += arc_before - arc_after;

        var lfunc = lower_mir_lir.lowerFunc(allocator, f.*) catch continue;
        defer lfunc.deinit(allocator);
        cov.lir_ops += lfunc.ops.items.len;
    }

    std.debug.print("[opt] AST->HIR->MIR->LIR shadow: {d} fns, {d} HIR nodes ({d:.1}% covered), {d} MIR blocks, {d} MIR insts, {d} verify errors, {d} insts removed, {d} LIR ops | ARC: {d} ops threaded, {d} removed by arc_elision\n", .{
        cov.funcs, cov.nodes,
        if (cov.nodes == 0) @as(f64, 100.0) else 100.0 * @as(f64, @floatFromInt(cov.nodes - cov.unsupported)) / @as(f64, @floatFromInt(cov.nodes)),
        cov.mir_blocks, cov.mir_insts, cov.verify_errors, cov.insts_removed,
        cov.lir_ops, cov.arc_ops, cov.arc_removed,
    });
    std.debug.print("[opt]   type-threading: {d}/{d} MIR values typed ({d:.1}%); call callees resolved: {d}/{d} ({d:.1}%)\n", .{
        cov.typed_values, cov.total_values,
        if (cov.total_values == 0) @as(f64, 0.0) else 100.0 * @as(f64, @floatFromInt(cov.typed_values)) / @as(f64, @floatFromInt(cov.total_values)),
        cov.calls_resolved, cov.calls_total,
        if (cov.calls_total == 0) @as(f64, 0.0) else 100.0 * @as(f64, @floatFromInt(cov.calls_resolved)) / @as(f64, @floatFromInt(cov.calls_total)),
    });
    std.debug.print("[opt]   call graph: {d} calls inlined by M5\n", .{cov.calls_inlined});
    if (verbose) {
        var it = unsupported_by_tag.iterator();
        while (it.next()) |e| std.debug.print("[opt]   unsupported {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    return cov;
}

// Pass 1: lower one function AST -> HIR -> MIR, count coverage, and STORE the MIR (kept alive so a call
// graph across all functions exists). Optimisation + LIR happen in pass 2. `own_sym` is the function's own
// SymbolId (free fns; null for methods), the key it is entered into the call graph under.
fn lowerToMir(
    allocator: std.mem.Allocator,
    fd: ast.FunctionDecl,
    ir: ?*const infer.TypedIr,
    own_sym: ?mir.SymbolId,
    cov: *Coverage,
    hist: *std.StringHashMap(usize),
    funcs: *std.ArrayListUnmanaged(mir.Func),
    own_syms: *std.ArrayListUnmanaged(?mir.SymbolId),
) !void {
    if (fd.extern_lib != null) return; // no body to lower

    // AST -> HIR (with ARC ops threaded when the TypedIr is available)
    var hfunc = try lower_ast_hir.lowerFunc(allocator, fd, ir);
    defer hfunc.deinit(allocator);
    cov.funcs += 1;
    cov.nodes += hfunc.nodes.items.len;
    for (hfunc.nodes.items) |node| {
        if (node.kind == .unsupported) {
            cov.unsupported += 1;
            const gop = try hist.getOrPut(node.kind.unsupported);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        }
    }

    // HIR -> MIR (kept; freed by lowerProgramShadow's defer)
    var mfunc = try lower_hir_mir.lowerFunc(allocator, hfunc);
    cov.mir_blocks += mfunc.blocks.items.len;
    cov.mir_insts += countInsts(&mfunc);
    // Type-threading + call-resolution coverage (measured before opt/inline).
    cov.total_values += mfunc.value_types.items.len;
    for (mfunc.value_types.items) |vt| {
        if (vt != mir.unset_ty) cov.typed_values += 1;
    }
    for (mfunc.blocks.items) |b| for (b.insts.items) |inst| {
        if (inst.op == .call) {
            cov.calls_total += 1;
            if (inst.op.call.callee != lower_hir_mir.unresolved_callee) cov.calls_resolved += 1;
        }
    };

    // Verify the structural MIR (M2).
    const violations = try verify.verify(allocator, &mfunc);
    defer allocator.free(violations);
    cov.verify_errors += violations.len;

    try funcs.append(allocator, mfunc);
    try own_syms.append(allocator, own_sym);
}

fn countCalls(mf: *const mir.Func) usize {
    var n: usize = 0;
    for (mf.blocks.items) |b| for (b.insts.items) |inst| {
        if (inst.op == .call) n += 1;
    };
    return n;
}

fn countInsts(mf: *const mir.Func) usize {
    var n: usize = 0;
    for (mf.blocks.items) |b| n += b.insts.items.len;
    return n;
}

fn countArc(mf: *const mir.Func) usize {
    var n: usize = 0;
    for (mf.blocks.items) |b| for (b.insts.items) |inst| {
        if (inst.op == .retain or inst.op == .release) n += 1;
    };
    return n;
}

pub const enabled: bool = false;

// Referenced so the exe build compiles the HIR->MIR->LIR chain even before it emits.
pub fn run() void {
    _ = &lower_hir_mir.lowerFunc;
    _ = &lower_mir_lir.lowerFunc;
    _ = hir.HirId.none;
    _ = mir.Value.invalid;
    _ = lir.Reg;
}
