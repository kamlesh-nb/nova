#!/bin/bash
# Convert an LLVM.org release drop's LTO-bitcode archives (libLLVM*.a + liblld*.a)
# into NATIVE Mach-O archives that Zig's linker can static-link.
#
# The LLVM.org macOS binaries are LTO builds: their .a members are LLVM bitcode,
# not native objects, so Zig's linker rejects them ("unknown cpu architecture: 0").
# This runs each member through the drop's own `llc` (per-file → memory-safe),
# re-archives with `llvm-ar`, and writes a NATIVE prefix `nova` can link against
# via NOVA_LLVM_PREFIX / static_llvm_prefix in build.zig.
#
# Usage:  convert-drop-to-native.sh [DROP_PREFIX] [OUT_PREFIX]
#   DROP_PREFIX  default: /Users/kamlesh/LLVM-22.1.0-macOS-ARM64
#   OUT_PREFIX   default: ${DROP_PREFIX}-native   (only lib/*.a is produced)
# Idempotent/resumable (skips archives already converted); aborts if free disk
# drops below 2 GB. ~6 min for 3055 members on an M1.
set -u
D="${1:-/Users/kamlesh/LLVM-22.1.0-macOS-ARM64}"
OUTP="${2:-${D}-native}"
OUT="$OUTP/lib"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/llvmconv.XXXXXX")"
LLC="$D/bin/llc"; AR="$D/bin/llvm-ar"
MIN_FREE_GB=2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
archives=( "$D"/lib/libLLVM*.a "$D"/lib/liblld*.a )
total=${#archives[@]}; i=0; conv_ok=0; conv_fail=0; started=$(date +%s)
echo "=== LLVM bitcode->native: $total archives  $D -> $OUT ==="
for a in "${archives[@]}"; do
  i=$((i+1)); base=$(basename "$a")
  free_gb=$(df -g "$OUT" | tail -1 | awk '{print $4}')
  [ "$free_gb" -lt "$MIN_FREE_GB" ] && { echo "!! ABORT: free ${free_gb}GB < ${MIN_FREE_GB}GB before $base"; exit 3; }
  [ -f "$OUT/$base" ] && { echo "[$i/$total] $base (exists, skip)"; continue; }
  wd="$WORK/$base.d"; rm -rf "$wd"; mkdir -p "$wd/ex" "$wd/nat"
  ( cd "$wd/ex" && "$AR" x "$a" ) 2>/dev/null
  members=$(ls "$wd/ex"/*.o 2>/dev/null | wc -l | tr -d ' '); ok=0; fail=0
  for o in "$wd/ex"/*.o; do
    [ -e "$o" ] || continue
    if "$LLC" -filetype=obj -O2 "$o" -o "$wd/nat/$(basename "$o")" 2>>"$wd/llc.err"; then ok=$((ok+1))
    elif file "$o" | grep -q "Mach-O"; then cp "$o" "$wd/nat/$(basename "$o")"; ok=$((ok+1))
    else fail=$((fail+1)); echo "   FAIL llc: $base :: $(basename "$o")"; fi
  done
  "$AR" rcs "$OUT/$base" "$wd/nat"/*.o 2>/dev/null
  conv_ok=$((conv_ok+ok)); conv_fail=$((conv_fail+fail))
  echo "[$i/$total] $base  members=$members ok=$ok fail=$fail"
  rm -rf "$wd"
done
echo "=== DONE in $(( $(date +%s) - started ))s : converted=$conv_ok failed=$conv_fail ==="
du -sh "$OUT" 2>/dev/null
[ "$conv_fail" -eq 0 ] && echo "RESULT: SUCCESS" || { echo "RESULT: $conv_fail failures"; exit 1; }
echo "Now regenerate the component list for build.zig:"
echo "  ls $OUT/libLLVM*.a | xargs -n1 basename | sed 's/^lib//;s/\\.a\$//' | sort > deps/llvm-zig/llvm-libs.txt"
