// driver.zig — the middle-end entry point.
//
// Orchestrates AST+TypedIr -> HIR -> MIR -> [optimiser passes] -> LIR, running the MIR verifier after
// every pass in debug builds. This is what builder.zig calls between sema and codegen (gated by NOVA_OPT
// during the rollout; see docs/design/optimiser.md).
//
// Status: M1a. The middle-end does not yet EMIT (codegen still lowers from the AST). What runs today,
// when NOVA_OPT is set, is `lowerProgramShadow`: lower every function AST->HIR and report coverage. This
// exercises the lowering on real corpus code with zero risk to the emitted program, exactly the
// shadow-first method that de-risked the string-engine removal. HIR->MIR->LIR emission is the next work.

const std = @import("std");
const builtin = @import("builtin");

const ast = @import("../frontend/ast.zig");
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
};

// M1a shadow: lower every function in the program AST->HIR and report coverage. Does NOT emit; the AST
// path still produces the program. Gated by NOVA_OPT in builder.zig. Never fatal: a lowering that hits a
// not-yet-handled form records it as `.unsupported` and keeps going, so this is safe to run over the whole
// corpus. Prints a summary and, with NOVA_OPT_VERBOSE, the unsupported-tag histogram.
pub fn lowerProgramShadow(allocator: std.mem.Allocator, program: ast.Program, verbose: bool) !Coverage {
    var cov = Coverage{};
    var unsupported_by_tag = std.StringHashMap(usize).init(allocator);
    defer unsupported_by_tag.deinit();

    for (program.declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| try lowerOneShadow(allocator, fd, &cov, &unsupported_by_tag),
            .struct_decl => |sd| for (sd.methods) |m| try lowerOneShadow(allocator, m.decl, &cov, &unsupported_by_tag),
            else => {},
        }
    }

    std.debug.print("[opt] AST->HIR shadow: {d} functions, {d} HIR nodes, {d} unsupported ({d:.1}% covered)\n", .{
        cov.funcs, cov.nodes, cov.unsupported,
        if (cov.nodes == 0) @as(f64, 100.0) else 100.0 * @as(f64, @floatFromInt(cov.nodes - cov.unsupported)) / @as(f64, @floatFromInt(cov.nodes)),
    });
    if (verbose) {
        var it = unsupported_by_tag.iterator();
        while (it.next()) |e| std.debug.print("[opt]   unsupported {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    return cov;
}

fn lowerOneShadow(allocator: std.mem.Allocator, fd: ast.FunctionDecl, cov: *Coverage, hist: *std.StringHashMap(usize)) !void {
    if (fd.extern_lib != null) return; // no body to lower
    var func = try lower_ast_hir.lowerFunc(allocator, fd, null);
    defer func.deinit(allocator);
    cov.funcs += 1;
    cov.nodes += func.nodes.items.len;
    for (func.nodes.items) |node| {
        if (node.kind == .unsupported) {
            cov.unsupported += 1;
            const gop = try hist.getOrPut(node.kind.unsupported);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        }
    }
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
