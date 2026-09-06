// Trimmed to the submodules the Kyte codegen actually imports (@import("llvm")):
// core/types + target/target_machine/transform for emit, analysis for verify, and
// debuginfo for DWARF. The JIT/ORC/LTO/disassembler/linker/object/clang bindings
// that kassane/llvm-zig ships were removed as unused (see deps/llvm-zig/build.zig).
pub const analysis = @import("analysis.zig");
pub const core = @import("core.zig");
pub const debug = @import("debuginfo.zig");
pub const errors = @import("errors.zig");
pub const target = @import("target.zig");
pub const target_machine = @import("target_machine.zig");
pub const transform = @import("transform.zig");
pub const types = @import("types.zig");

const std = @import("std");

test "all LLVM modules" {
    _ = analysis;
    _ = core;
    _ = debug;
    _ = errors;
    _ = target;
    _ = target_machine;
    _ = transform;
    _ = types;
}

test "PassBuilder options create and dispose" {
    const opts = transform.LLVMCreatePassBuilderOptions();
    try std.testing.expect(opts != null);
    transform.LLVMDisposePassBuilderOptions(opts);
}

test "TargetMachineOptions create and dispose" {
    const opts = target_machine.LLVMCreateTargetMachineOptions();
    try std.testing.expect(opts != null);
    target_machine.LLVMDisposeTargetMachineOptions(opts);
}

test "LLVMRunPasses with verify pipeline returns success" {
    const mod = core.LLVMModuleCreateWithName("test_passes");
    defer core.LLVMDisposeModule(mod);
    const opts = transform.LLVMCreatePassBuilderOptions();
    defer transform.LLVMDisposePassBuilderOptions(opts);
    const err = transform.LLVMRunPasses(mod, "verify", null, opts);
    defer if (err != null) errors.LLVMConsumeError(err);
    try std.testing.expect(err == null);
}

test "LLVMCantFail with success (null) error does not panic" {
    // null is the LLVM success value for LLVMErrorRef
    errors.LLVMCantFail(null);
}

// In LLVM 21, new debug format (RemoveDIs) is always enabled; the setter is a no-op.
test "new debug format is always enabled in LLVM 21" {
    const mod = core.LLVMModuleCreateWithName("test_dbg_fmt");
    defer core.LLVMDisposeModule(mod);
    try std.testing.expect(core.LLVMIsNewDbgInfoFormat(mod) != 0);
}
