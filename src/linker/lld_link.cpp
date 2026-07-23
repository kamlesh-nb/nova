//===- lld_link.cpp - in-process LLD entry points for nova ---------------===//
//
// Thin C ABI over LLD's library entry points so `nova` can link its output
// executables WITHOUT shelling out to clang/ld. Compiled into `nova` and linked
// against the native liblld*.a ONLY in the `-Dstatic-llvm -Dinprocess-lld`
// build (see build.zig configureLlvmLink / inprocess-lld wiring).
//
// Each nova_lld_link_* takes an argv/argc exactly as the corresponding linker
// binary would (argv[0] is the linker name, e.g. "ld64.lld"). Returns 0 on
// success, non-zero on link failure. Diagnostics go to stderr.
//
//===----------------------------------------------------------------------===//

#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Plugins/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"

#include <vector>

// Declares lld::<flavor>::link(...); each is defined in the matching liblld<F>.a.
LLD_HAS_DRIVER(macho)
LLD_HAS_DRIVER(wasm)
LLD_HAS_DRIVER(elf)

// The LLVM.org build enabled LLVM_POLLY_LINK_INTO_TOOLS, so libLLVMLTO
// references getPollyPluginInfo(); we don't link libPolly. Provide a no-op
// plugin so the LTO code path links. Polly passes are simply never registered —
// harmless for native-object links (which never run the LTO optimizer anyway).
llvm::PassPluginLibraryInfo getPollyPluginInfo();
llvm::PassPluginLibraryInfo getPollyPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "Polly", "stub",
          [](llvm::PassBuilder &) {}};
}

namespace {
// exitEarly=false  -> link() returns to us instead of calling exit().
// disableOutput=false -> the output file is written.
int run(bool (*link)(llvm::ArrayRef<const char *>, llvm::raw_ostream &,
                     llvm::raw_ostream &, bool, bool),
        const char **argv, int argc) {
  std::vector<const char *> args(argv, argv + argc);
  const bool ok = link(args, llvm::outs(), llvm::errs(),
                       /*exitEarly=*/false, /*disableOutput=*/false);
  return ok ? 0 : 1;
}
} // namespace

extern "C" {

// Darwin / Mach-O (ld64.lld-compatible args).
int nova_lld_link_macho(const char **argv, int argc) {
  return run(lld::macho::link, argv, argc);
}

// WebAssembly (wasm-ld-compatible args).
int nova_lld_link_wasm(const char **argv, int argc) {
  return run(lld::wasm::link, argv, argc);
}

// ELF (ld.lld-compatible args) — for future Linux targets.
int nova_lld_link_elf(const char **argv, int argc) {
  return run(lld::elf::link, argv, argc);
}

} // extern "C"
