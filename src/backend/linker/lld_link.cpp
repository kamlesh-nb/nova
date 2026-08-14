
#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Plugins/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"

#include <vector>

LLD_HAS_DRIVER(macho)
LLD_HAS_DRIVER(wasm)
LLD_HAS_DRIVER(elf)

llvm::PassPluginLibraryInfo getPollyPluginInfo();
llvm::PassPluginLibraryInfo getPollyPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "Polly", "stub",
          [](llvm::PassBuilder &) {}};
}

namespace {

int run(bool (*link)(llvm::ArrayRef<const char *>, llvm::raw_ostream &,
                     llvm::raw_ostream &, bool, bool),
        const char **argv, int argc) {
  std::vector<const char *> args(argv, argv + argc);
  const bool ok = link(args, llvm::outs(), llvm::errs(),
                       false, false);
  return ok ? 0 : 1;
}
}

extern "C" {

int nova_lld_link_macho(const char **argv, int argc) {
  return run(lld::macho::link, argv, argc);
}

int nova_lld_link_wasm(const char **argv, int argc) {
  return run(lld::wasm::link, argv, argc);
}

int nova_lld_link_elf(const char **argv, int argc) {
  return run(lld::elf::link, argv, argc);
}

}
