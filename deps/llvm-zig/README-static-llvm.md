# Vendored `llvm-zig` + LLVM linking (P5 #20)

## What this is

`deps/llvm-zig` is a local vendoring of [kassane/llvm-zig](https://github.com/kassane/llvm-zig)
(commit `f56b9f0`), the Zig bindings for the LLVM-C API that `nova`'s codegen uses. It was previously a
`git+https://…` dependency in `build.zig.zon`; vendoring removes the network fetch (toolchain
self-sufficiency) and lets `nova`'s own `build.zig` own the LLVM link.

**Trimmed vs upstream:** only the `llvm` module is kept. The `clang` module, the `examples`, and the test
target were removed — the test target pulled a `test_runner` git sub-dependency that `nova` does not need.
The vendored `build.zig` therefore defines the `llvm` module and does **no** LLVM linking; linking is
applied by `nova`'s `build.zig` (`configureLlvmLink`).

## Dynamic (default) vs static (`-Dstatic-llvm`)

| Build | Command | LLVM link | `nova` binary |
|---|---|---|---|
| **dev (default)** | `zig build` | dynamic `libLLVM.dylib` (Homebrew) | loads `libLLVM.dylib` at runtime; fast to build |
| **delivery** | `zig build -Dstatic-llvm=true` | static `libLLVM*.a` + zstd/z/xml2/libc++ | **self-contained** — no `libLLVM.dylib`; large binary, slow link |

Default stays dynamic because static-linking all of LLVM bloats the binary and slows every dev build, and
self-containment only matters at release. The delivery invariant ("users deploy only `nova`") is satisfied
by the static binary — the *build machine* still uses an LLVM install, which is fine.

Default prefixes (override either with `NOVA_LLVM_PREFIX`):
- **dynamic** → `/opt/homebrew/opt/llvm` (Homebrew LLVM 21 — has `libLLVM.dylib`).
- **static** → `/Users/kamlesh/LLVM-22.1.0-macOS-ARM64-native` (**native LLVM 22**, see below).

The static path reads the committed component list `llvm-libs.txt` (the native-22 set, 211 components — a
superset of Homebrew 21). Regenerate it for a different prefix with:

```
ls <prefix>/lib/libLLVM*.a | xargs -n1 basename | sed 's/^lib//;s/\.a$//' | sort > deps/llvm-zig/llvm-libs.txt
```

## The LLVM.org 22 drop is LTO bitcode → converted to native (✅ resolved)

`/Users/kamlesh/LLVM-22.1.0-macOS-ARM64` (provisioned for a fully-standalone `nova` with in-process LLD)
ships **LTO builds** — its `libLLVM*.a` / `liblld*.a` members are **LLVM bitcode**, not native Mach-O:

```
$ ar x libLLVMCore.a Core.cpp.o && file Core.cpp.o
Core.cpp.o: LLVM bitcode, wrapper      # magic BC\xC0\xDE, not a Mach-O object
```

Zig's self-hosted linker can't consume bitcode (`unknown cpu architecture: 0`) and Zig refuses LLD for
Mach-O (`using LLD to link macho files is unsupported`), so the drop **cannot be linked directly**.

**Resolution (2026-07-20):** `convert-drop-to-native.sh` runs every member (all 3055) through the drop's
own `llc -filetype=obj` and re-archives with `llvm-ar`, producing a **native LLVM 22** prefix at
`…-native/` (222 MB, 0 failures). `nova` static-links against it cleanly — the LLVM 21→22 C-API bindings
are compatible — yielding a **132 MB self-contained `nova`** (only `/usr/lib` system dylibs; no
`libLLVM.dylib`), gates green (FUNC 74/74, ARC 128/128, SHADOW 128/128). A true from-source build
(`LLVM_ENABLE_LTO=OFF`) was infeasible here — it needs ~20–40 GB and the disk had 9 GB free; the `llc`
conversion reaches the same native archives from ~433 MB of bitcode. Regenerate the native tree with:

```
deps/llvm-zig/convert-drop-to-native.sh   # [DROP_PREFIX] [OUT_PREFIX]
```

Because it's now native LLVM 22 (not 21), the same tree's `liblld*.a` were converted too — so this also
unblocks the **in-process LLD** step (codegen-LLVM and LLD are the same version). The native tree is a
machine-local build artifact (222 MB, not committed); the script + component list are the reproducible
source of truth.

## In-process LLD (`-Dinprocess-lld`)

With `-Dstatic-llvm -Dinprocess-lld`, nova links its **output** native executables itself — no `clang`/`ld`
shell-out. `src/linker/lld_link.cpp` is a thin C ABI over `lld::{macho,wasm,elf}::link()`; build.zig
compiles it (drop headers) and links the native `liblld*.a`. `main.zig`'s `--native` path reconstructs the
ld64.lld args the clang driver hides (`-arch arm64 -platform_version macos 11.0 11.0 -syslibroot <SDK>
-lSystem -lc++` + obj/runtime/wolfSSL) and calls the shim.

Notes:
- The shim provides a **no-op `getPollyPluginInfo()`** — the LLVM.org build set `LLVM_POLLY_LINK_INTO_TOOLS`,
  so `libLLVMLTO` references it; we don't link `libPolly`, and Polly never runs for native-object links.
- SDK path comes from `SDKROOT`, else the CLT SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`),
  else the Xcode SDK. `-platform_version` is fixed at 11.0 (ld64.lld only needs a plausible value).
- Proven: native gates green (FUNC 74/74, ARC 128/128 with binaries executing, SHADOW 128/128).
- **WASM works end-to-end** — `--wasm` calls `nova_lld_link_wasm` (`wasm-ld --no-entry --export-all
  --export-memory --allow-undefined <obj> -o <out>`). A nova program now compiles and links to a valid
  wasm module via in-process wasm-ld (the #23 codegen blockers — test-harness externs, i32/f64 `val_type`,
  undefined runtime symbols — are fixed). Broader wasm coverage (heap/string round-trips, a `--wasm`
  conformance run) is still open under #23.
- **Still shells out for:** ELF links (shim exposes `nova_lld_link_elf`, not wired — no Linux target yet)
  and the SDK lookup (replace with bundled `.tbd` stubs for true "deploy only nova").

## zstd / z / xml2

LLVM's static libs reference zstd, zlib, and libxml2. `z`/`xml2` resolve against the macOS SDK dylibs;
`zstd` has no OS equivalent and is vendored at `deps/zstd/libzstd.a` (see that dir's README).
