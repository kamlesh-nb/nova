# Linux static LLVM — the self-hosted mirror artifact

Proven (2026-07-24): a **static-LLVM aarch64-linux `nova` cross-built on macOS** runs on Linux and
its LLVM-backed codegen works (parsed a program + emitted a native `.o`). `ldd` shows **no libLLVM**
— only `libstdc++`, `libgcc_s`, `libm`, `libc` (universal). That's "deploy only nova" for Linux.

## Why Linux is easier than macOS
apt `llvm-21-dev` ships **native ELF** `libLLVM*.a` (226 components) — NOT LTO bitcode, so **no
`llc` conversion** (unlike the macOS-22 drop, see README-static-llvm.md).

## What the mirror tarball must contain (per arch)
Under `llvm-21-<triple>/lib/`:
- `libLLVM*.a` — 226 native ELF component archives (from `/usr/lib/llvm-21/lib`)
- LLVM's C-lib deps as STATIC archives: `libz.a`, `libzstd.a`, `libxml2.a`, `liblzma.a`
  (xml2 → lzma). From `zlib1g-dev libzstd-dev libxml2-dev liblzma-dev`.
- `libstdc++.so.6` + `libstdc++.so` symlink, and `libgcc_s.so.1` + `libgcc_s.so` symlink.
  Prebuilt LLVM uses the **libstdc++** ABI (std::__cxx11/GLIBCXX), NOT libc++.

## How the build consumes it (build.zig configureLlvmLink, os_tag == .linux)
- component list = `llvm-libs-linux.txt` (226) instead of the macOS `llvm-libs.txt`.
- z/zstd/xml2/lzma linked STATIC from the prefix.
- **libstdc++ + libgcc_s linked as POSITIONAL `.so` inputs** (`addObjectFile`), NOT `-lstdc++`:
  zig aliases `-lstdc++` to its own libc++ (wrong ABI), and a static libstdc++.a hits ld.lld's
  archive-cycle limit (macOS ld auto-resolves cycles; ld.lld needs --start-group, unavailable in
  zig-build). Dynamic libstdc++/libgcc_s are order-independent and universal on Linux.
- Build with `-Dstatic-llvm -Dtarget=aarch64-linux-gnu.2.39` (glibc pin → __isoc23_*/mallinfo2/
  arc4random resolve) and `NOVA_LLVM_PREFIX=<extracted prefix>`.

Produce the tarball in a container: see the produce steps in the deps-generalization notes.
