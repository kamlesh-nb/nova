#!/usr/bin/env bash
# Assemble a runnable Kyte distribution: the `kyte` COMPILER plus the `.ky` home tree it
# needs at run time (stdlib source, runtime archive, runtime C++ source, vendored deps).
#
# This is the piece `scripts/build-archives.sh` does NOT produce. That script builds the
# runtime archive for each target, which is what a program LINKS against; this one produces
# the compiler you actually invoke on a .ky file.
#
# WHY THIS IS HOST-ONLY, and what it would take to change that
# ------------------------------------------------------------
# `kyte` links LLVM itself (LLVM-C dynamically, or the static component libs) out of
# KYTE_LLVM_PREFIX. Cross-building the compiler therefore needs LLVM built FOR THE TARGET,
# not just a cross C++ toolchain -- `zig build -Dtarget=x86_64-linux-gnu` fails with:
#
#     error: unable to find dynamic system library 'LLVM' ... searched:
#            C:\LLVM\lib\libLLVM.so   C:\LLVM\lib\libLLVM.a
#
# Zig can synthesise a libc for any target; it cannot synthesise LLVM. So each host builds
# its own compiler, which is why this script takes no target argument.
#
# Note this does NOT block producing binaries for other architectures: `kyte app.ky
# --target linux-arm64` cross-compiles from an x86_64 host and works (it consumes the
# per-target runtime object, which pipeline.zig builds and caches). What needs a native
# build is RUNNING the compiler on that architecture.
#
# To add an arm64 host: install or build LLVM for it, point KYTE_LLVM_PREFIX at that, and
# run this script there. Nothing in the tree is x86-specific -- the crypto assembly now
# assembles for ELF, COFF and Mach-O on both architectures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# Host triple, in the same spelling scripts/build-archives.sh uses for its output dirs.
case "$(uname -s)" in
  Linux)   os=linux-gnu ;;
  Darwin)  os=macos ;;
  MINGW*|MSYS*|CYGWIN*) os=windows-msvc ;;
  *) echo "unrecognised host OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) echo "unrecognised host arch: $(uname -m)" >&2; exit 1 ;;
esac
TRIPLE="$arch-$os"
OUT="${1:-$HERE/zig-out/dist/$TRIPLE}"

EXE=kyte; [[ "$os" == windows-msvc ]] && EXE=kyte.exe
if [[ ! -x "zig-out/bin/$EXE" && ! -f "zig-out/bin/$EXE" ]]; then
  echo "zig-out/bin/$EXE not found -- run 'zig build -Doptimize=ReleaseFast' first." >&2
  echo "(A Debug build cannot pass the corpus; see CLAUDE.md on the leak gate.)" >&2
  exit 1
fi

echo "Assembling $TRIPLE distribution into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/kyte-home/lib" "$OUT/kyte-home/src"

cp "zig-out/bin/$EXE" "$OUT/bin/$EXE"
cp -r src/lib/std   "$OUT/kyte-home/std"
cp -r src/runtime   "$OUT/kyte-home/src/runtime"
cp -r deps          "$OUT/kyte-home/deps"

# The runtime archive/objects for THIS host. build-archives.sh writes per-target copies under
# zig-out/archives/<triple>/; fall back to the ones `zig build` installed into ~/.kyte/lib.
if [[ -d "zig-out/archives/$TRIPLE" ]]; then
  cp zig-out/archives/"$TRIPLE"/*.a zig-out/archives/"$TRIPLE"/*.lib zig-out/archives/"$TRIPLE"/*.o "$OUT/kyte-home/lib/" 2>/dev/null
else
  cp "$HOME"/.kyte/lib/* "$OUT/kyte-home/lib/" 2>/dev/null
fi

cat > "$OUT/INSTALL.txt" <<EOF
Kyte distribution -- $TRIPLE

  bin/$EXE      the compiler
  kyte-home/    its runtime home: stdlib source, runtime archive, runtime C++ source, deps

The compiler resolves its home as \$HOME/.kyte, so install with:

  cp -r kyte-home/*  \$HOME/.kyte/
  cp bin/$EXE        \$HOME/.kyte/bin/

Then:  kyte yourfile.ky -o yourprog

Cross-compiling to another architecture does NOT need a compiler built for it:

  kyte yourfile.ky --target linux-arm64    -o prog
  kyte yourfile.ky --target windows-arm64  -o prog.exe

Accepted: linux-x86_64, linux-arm64, windows-x86_64, windows-arm64,
          macos-x86_64, macos-arm64.
EOF

echo "  bin/$EXE  $(du -h "$OUT/bin/$EXE" | cut -f1)"
echo "  kyte-home $(du -sh "$OUT/kyte-home" | cut -f1)"
echo "Done. See $OUT/INSTALL.txt"
