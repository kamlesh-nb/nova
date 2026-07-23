const std = @import("std");

// Vendored from kassane/llvm-zig (commit f56b9f0), trimmed to the `llvm` module
// only. The clang module, examples, and the test target (with its `test_runner`
// git sub-dependency) were removed — nova imports only the `llvm` module.
//
// LLVM/zstd/xml2/libc++ LINKING IS NOT DONE HERE. The consuming project (nova)
// owns the LLVM prefix and the vendored libzstd path, so it applies the static
// link inputs to this module from its own build.zig (see linkLlvmStatic there).
// Keeping the machine-specific toolchain wiring in one place.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llvm_module = b.addModule("llvm", .{
        .root_source_file = b.path("src/llvm-bindings.zig"),
        .target = target,
        .optimize = optimize,
    });

    llvm_module.addCMacro("_FILE_OFFSET_BITS", "64");
    llvm_module.addCMacro("__STDC_CONSTANT_MACROS", "");
    llvm_module.addCMacro("__STDC_FORMAT_MACROS", "");
    llvm_module.addCMacro("__STDC_LIMIT_MACROS", "");

    llvm_module.link_libc = true;
}
