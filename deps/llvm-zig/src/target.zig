const std = @import("std");
const builtin = @import("builtin");
const LLVMtype = @import("types.zig");

// Backends the linked LLVM actually ships. The LLVM.org *Windows* binary release builds
// LLVM-C.dll with a reduced LLVM_TARGETS_TO_BUILD, and referencing an LLVMInitialize<T>*
// the DLL does not export is a hard link error (`lld-link: undefined symbol`), not a
// runtime no-op — so the aggregate initializers below enumerate only what is present.
// Every backend nova emits for (x86_64, aarch64, arm, wasm32) is inside this set.
// macOS/Linux LLVM drops carry all backends and take the unfiltered path.
const windows_backends = [_][]const u8{ "AArch64", "ARM", "BPF", "NVPTX", "RISCV", "WebAssembly", "X86" };

fn haveBackend(comptime name: []const u8) bool {
    if (builtin.target.os.tag != .windows) return true;
    for (windows_backends) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

// Full per-category backend lists. AsmParser/Disassembler legitimately omit backends that
// have no such component upstream (NVPTX has neither; XCore has no AsmParser).
const all_backends = [_][]const u8{ "AArch64", "AMDGPU", "ARM", "AVR", "BPF", "Hexagon", "Lanai", "Mips", "MSP430", "NVPTX", "PowerPC", "RISCV", "Sparc", "SystemZ", "WebAssembly", "X86", "XCore", "VE" };
const asm_parser_backends = [_][]const u8{ "AArch64", "AMDGPU", "ARM", "AVR", "BPF", "Hexagon", "Lanai", "Mips", "MSP430", "PowerPC", "RISCV", "Sparc", "SystemZ", "WebAssembly", "X86", "VE" };
const disassembler_backends = [_][]const u8{ "AArch64", "AMDGPU", "ARM", "AVR", "BPF", "Hexagon", "Lanai", "Mips", "MSP430", "PowerPC", "RISCV", "Sparc", "SystemZ", "VE", "WebAssembly", "X86", "XCore" };

fn initBackends(comptime backends: []const []const u8, comptime component: []const u8) void {
    inline for (backends) |b| {
        if (comptime haveBackend(b)) @field(@This(), "LLVMInitialize" ++ b ++ component)();
    }
}

pub extern fn LLVMInitializeAArch64TargetInfo() void;
pub extern fn LLVMInitializeAMDGPUTargetInfo() void;
pub extern fn LLVMInitializeARMTargetInfo() void;
pub extern fn LLVMInitializeAVRTargetInfo() void;
pub extern fn LLVMInitializeBPFTargetInfo() void;
pub extern fn LLVMInitializeHexagonTargetInfo() void;
pub extern fn LLVMInitializeLanaiTargetInfo() void;
pub extern fn LLVMInitializeMipsTargetInfo() void;
pub extern fn LLVMInitializeMSP430TargetInfo() void;
pub extern fn LLVMInitializeNVPTXTargetInfo() void;
pub extern fn LLVMInitializePowerPCTargetInfo() void;
pub extern fn LLVMInitializeRISCVTargetInfo() void;
pub extern fn LLVMInitializeSparcTargetInfo() void;
pub extern fn LLVMInitializeSystemZTargetInfo() void;
pub extern fn LLVMInitializeWebAssemblyTargetInfo() void;
pub extern fn LLVMInitializeX86TargetInfo() void;
pub extern fn LLVMInitializeXCoreTargetInfo() void;
pub extern fn LLVMInitializeVETargetInfo() void;

pub extern fn LLVMInitializeAArch64Target() void;
pub extern fn LLVMInitializeAMDGPUTarget() void;
pub extern fn LLVMInitializeARMTarget() void;
pub extern fn LLVMInitializeAVRTarget() void;
pub extern fn LLVMInitializeBPFTarget() void;
pub extern fn LLVMInitializeHexagonTarget() void;
pub extern fn LLVMInitializeLanaiTarget() void;
pub extern fn LLVMInitializeMipsTarget() void;
pub extern fn LLVMInitializeMSP430Target() void;
pub extern fn LLVMInitializeNVPTXTarget() void;
pub extern fn LLVMInitializePowerPCTarget() void;
pub extern fn LLVMInitializeRISCVTarget() void;
pub extern fn LLVMInitializeSparcTarget() void;
pub extern fn LLVMInitializeSystemZTarget() void;
pub extern fn LLVMInitializeWebAssemblyTarget() void;
pub extern fn LLVMInitializeX86Target() void;
pub extern fn LLVMInitializeXCoreTarget() void;
pub extern fn LLVMInitializeVETarget() void;

pub extern fn LLVMInitializeAArch64TargetMC() void;
pub extern fn LLVMInitializeAMDGPUTargetMC() void;
pub extern fn LLVMInitializeARMTargetMC() void;
pub extern fn LLVMInitializeAVRTargetMC() void;
pub extern fn LLVMInitializeBPFTargetMC() void;
pub extern fn LLVMInitializeHexagonTargetMC() void;
pub extern fn LLVMInitializeLanaiTargetMC() void;
pub extern fn LLVMInitializeMipsTargetMC() void;
pub extern fn LLVMInitializeMSP430TargetMC() void;
pub extern fn LLVMInitializeNVPTXTargetMC() void;
pub extern fn LLVMInitializePowerPCTargetMC() void;
pub extern fn LLVMInitializeRISCVTargetMC() void;
pub extern fn LLVMInitializeSparcTargetMC() void;
pub extern fn LLVMInitializeSystemZTargetMC() void;
pub extern fn LLVMInitializeWebAssemblyTargetMC() void;
pub extern fn LLVMInitializeX86TargetMC() void;
pub extern fn LLVMInitializeXCoreTargetMC() void;
pub extern fn LLVMInitializeVETargetMC() void;

pub extern fn LLVMInitializeAArch64AsmPrinter() void;
pub extern fn LLVMInitializeAMDGPUAsmPrinter() void;
pub extern fn LLVMInitializeARMAsmPrinter() void;
pub extern fn LLVMInitializeAVRAsmPrinter() void;
pub extern fn LLVMInitializeBPFAsmPrinter() void;
pub extern fn LLVMInitializeHexagonAsmPrinter() void;
pub extern fn LLVMInitializeLanaiAsmPrinter() void;
pub extern fn LLVMInitializeMipsAsmPrinter() void;
pub extern fn LLVMInitializeMSP430AsmPrinter() void;
pub extern fn LLVMInitializeNVPTXAsmPrinter() void;
pub extern fn LLVMInitializePowerPCAsmPrinter() void;
pub extern fn LLVMInitializeRISCVAsmPrinter() void;
pub extern fn LLVMInitializeSparcAsmPrinter() void;
pub extern fn LLVMInitializeSystemZAsmPrinter() void;
pub extern fn LLVMInitializeWebAssemblyAsmPrinter() void;
pub extern fn LLVMInitializeX86AsmPrinter() void;
pub extern fn LLVMInitializeXCoreAsmPrinter() void;
pub extern fn LLVMInitializeVEAsmPrinter() void;

pub extern fn LLVMInitializeAArch64AsmParser() void;
pub extern fn LLVMInitializeAMDGPUAsmParser() void;
pub extern fn LLVMInitializeARMAsmParser() void;
pub extern fn LLVMInitializeAVRAsmParser() void;
pub extern fn LLVMInitializeBPFAsmParser() void;
pub extern fn LLVMInitializeHexagonAsmParser() void;
pub extern fn LLVMInitializeLanaiAsmParser() void;
pub extern fn LLVMInitializeMipsAsmParser() void;
pub extern fn LLVMInitializeMSP430AsmParser() void;
pub extern fn LLVMInitializePowerPCAsmParser() void;
pub extern fn LLVMInitializeRISCVAsmParser() void;
pub extern fn LLVMInitializeSparcAsmParser() void;
pub extern fn LLVMInitializeSystemZAsmParser() void;
pub extern fn LLVMInitializeWebAssemblyAsmParser() void;
pub extern fn LLVMInitializeX86AsmParser() void;
pub extern fn LLVMInitializeVEAsmParser() void;

pub extern fn LLVMInitializeAArch64Disassembler() void;
pub extern fn LLVMInitializeAMDGPUDisassembler() void;
pub extern fn LLVMInitializeARMDisassembler() void;
pub extern fn LLVMInitializeAVRDisassembler() void;
pub extern fn LLVMInitializeBPFDisassembler() void;
pub extern fn LLVMInitializeHexagonDisassembler() void;
pub extern fn LLVMInitializeLanaiDisassembler() void;
pub extern fn LLVMInitializeMipsDisassembler() void;
pub extern fn LLVMInitializeMSP430Disassembler() void;
pub extern fn LLVMInitializePowerPCDisassembler() void;
pub extern fn LLVMInitializeRISCVDisassembler() void;
pub extern fn LLVMInitializeSparcDisassembler() void;
pub extern fn LLVMInitializeSystemZDisassembler() void;
pub extern fn LLVMInitializeVEDisassembler() void;
pub extern fn LLVMInitializeWebAssemblyDisassembler() void;
pub extern fn LLVMInitializeX86Disassembler() void;
pub extern fn LLVMInitializeXCoreDisassembler() void;

pub fn LLVMInitializeAllTargetInfos() callconv(.c) void {
    initBackends(&all_backends, "TargetInfo");
}
pub fn LLVMInitializeAllTargets() callconv(.c) void {
    initBackends(&all_backends, "Target");
}
pub fn LLVMInitializeAllTargetMCs() callconv(.c) void {
    initBackends(&all_backends, "TargetMC");
}
pub fn LLVMInitializeAllAsmPrinters() callconv(.c) void {
    initBackends(&all_backends, "AsmPrinter");
}
pub fn LLVMInitializeAllAsmParsers() callconv(.c) void {
    initBackends(&asm_parser_backends, "AsmParser");
}
pub fn LLVMInitializeAllDisassemblers() callconv(.c) void {
    initBackends(&disassembler_backends, "Disassembler");
}
pub fn LLVMInitializeNativeTarget() callconv(.c) LLVMtype.LLVMBool {
    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    return 0;
}
pub fn LLVMInitializeNativeAsmParser() callconv(.c) LLVMtype.LLVMBool {
    LLVMInitializeX86AsmParser();
    return 0;
}
pub fn LLVMInitializeNativeAsmPrinter() callconv(.c) LLVMtype.LLVMBool {
    LLVMInitializeX86AsmPrinter();
    return 0;
}
pub fn LLVMInitializeNativeDisassembler() callconv(.c) LLVMtype.LLVMBool {
    LLVMInitializeX86Disassembler();
    return 0;
}

pub extern fn LLVMGetModuleDataLayout(M: LLVMtype.LLVMModuleRef) LLVMtype.LLVMTargetDataRef;
pub extern fn LLVMSetModuleDataLayout(M: LLVMtype.LLVMModuleRef, DL: LLVMtype.LLVMTargetDataRef) void;
pub extern fn LLVMCreateTargetData(StringRep: [*c]const u8) LLVMtype.LLVMTargetDataRef;
pub extern fn LLVMDisposeTargetData(TD: LLVMtype.LLVMTargetDataRef) void;
pub extern fn LLVMAddTargetLibraryInfo(TLI: LLVMtype.LLVMTargetLibraryInfoRef, PM: LLVMtype.LLVMPassManagerRef) void;
pub extern fn LLVMCopyStringRepOfTargetData(TD: LLVMtype.LLVMTargetDataRef) [*c]u8;
pub extern fn LLVMByteOrder(TD: LLVMtype.LLVMTargetDataRef) c_int;
pub extern fn LLVMPointerSize(TD: LLVMtype.LLVMTargetDataRef) c_uint;
pub extern fn LLVMPointerSizeForAS(TD: LLVMtype.LLVMTargetDataRef, AS: c_uint) c_uint;
pub extern fn LLVMIntPtrType(TD: LLVMtype.LLVMTargetDataRef) LLVMtype.LLVMTypeRef;
pub extern fn LLVMIntPtrTypeForAS(TD: LLVMtype.LLVMTargetDataRef, AS: c_uint) LLVMtype.LLVMTypeRef;
pub extern fn LLVMIntPtrTypeInContext(C: LLVMtype.LLVMContextRef, TD: LLVMtype.LLVMTargetDataRef) LLVMtype.LLVMTypeRef;
pub extern fn LLVMIntPtrTypeForASInContext(C: LLVMtype.LLVMContextRef, TD: LLVMtype.LLVMTargetDataRef, AS: c_uint) LLVMtype.LLVMTypeRef;
pub extern fn LLVMSizeOfTypeInBits(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_ulonglong;
pub extern fn LLVMStoreSizeOfType(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_ulonglong;
pub extern fn LLVMABISizeOfType(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_ulonglong;
pub extern fn LLVMABIAlignmentOfType(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_uint;
pub extern fn LLVMCallFrameAlignmentOfType(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_uint;
pub extern fn LLVMPreferredAlignmentOfType(TD: LLVMtype.LLVMTargetDataRef, Ty: LLVMtype.LLVMTypeRef) c_uint;
pub extern fn LLVMPreferredAlignmentOfGlobal(TD: LLVMtype.LLVMTargetDataRef, GlobalVar: LLVMtype.LLVMValueRef) c_uint;
pub extern fn LLVMElementAtOffset(TD: LLVMtype.LLVMTargetDataRef, StructTy: LLVMtype.LLVMTypeRef, Offset: c_ulonglong) c_uint;
pub extern fn LLVMOffsetOfElement(TD: LLVMtype.LLVMTargetDataRef, StructTy: LLVMtype.LLVMTypeRef, Element: c_uint) c_ulonglong;
