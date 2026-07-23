# Vendored `libzstd.a`

Prebuilt static Zstandard library, vendored into the Nova toolchain so a **static** `nova`
(in-process LLVM + LLD, path (b)) links without depending on a Homebrew install.

## Why this is here

The static LLVM 22.1.0 drop (`/Users/kamlesh/LLVM-22.1.0-macOS-ARM64`) was built with zstd enabled.
`llvm-config --link-static --system-libs all` therefore emits:

```
-lm -lz /opt/homebrew/lib/libzstd.a -lxml2
```

- `-lm` → macOS libSystem (always present).
- `-lz`, `-lxml2` → satisfied by the macOS SDK stubs (`libz.tbd`, `libxml2.tbd`).
- **`/opt/homebrew/lib/libzstd.a`** → a hardcoded **Homebrew** path. macOS has **no** zstd equivalent
  (it ships `libcompression`, not zstd), so this is the one static lib with no OS/SDK fallback. Vendoring
  it removes the Homebrew dependency and makes "users deploy only `nova`" achievable.

Rebuilding the prebuilt LLVM drop with `LLVM_ENABLE_ZSTD=OFF` would drop the dependency instead, but that
requires recompiling LLVM — vendoring the 750 KB archive is the pragmatic path.

## Provenance

| Field | Value |
|---|---|
| Version | zstd v1.5.7 (Yann Collet) |
| Source | Homebrew `/opt/homebrew/opt/zstd/lib/libzstd.a` (Cellar `zstd/1.5.7_1`) |
| Arch | `arm64` (matches the LLVM-22.1.0-macOS-ARM64 drop) |
| SHA-256 | `e2e020e745e2334e44ea9241ff447ca5ca40ebe2ad1ad8ef1725ddf1abb75e6c` |

## How the build must use it (static-LLVM link step — roadmap P5 #20)

When wiring the static-LLVM link, do **not** pass `llvm-config --system-libs` verbatim (it points at the
Homebrew path). Substitute the zstd entry with this vendored copy, e.g.:

```
-L <repo>/lang/deps/zstd  -lzstd     # or the absolute path lang/deps/zstd/libzstd.a
```

Other arches: this archive is arm64-only. Vendor the matching slice (or a universal `.a`) when Nova
targets x86_64 macOS / Linux.
