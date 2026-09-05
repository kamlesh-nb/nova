#!/usr/bin/env bash
# L5 stability guard: the version lives in several files that MUST agree. This fails loud if any
# drift, so a release can never ship a mismatched `kyte version` / build.zig.zon / ABI header.
#   - kyte_version   in build.zig  ==  .version  in build.zig.zon
#   - kyte_abi_version in build.zig ==  KYTE_ABI_VERSION in src/runtime/kyte_abi.h
# Wired into the CI soundness job; run it locally before cutting a release.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0

bz_ver="$(grep -oE 'kyte_version = "[^"]+"' "$ROOT/build.zig" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
zon_ver="$(grep -oE '\.version = "[^"]+"' "$ROOT/build.zig.zon" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
bz_abi="$(grep -oE 'kyte_abi_version: u32 = [0-9]+' "$ROOT/build.zig" | grep -oE '[0-9]+$')"
h_abi="$(grep -oE '#define KYTE_ABI_VERSION [0-9]+' "$ROOT/src/runtime/kyte_abi.h" | grep -oE '[0-9]+$')"

echo "version: build.zig=$bz_ver  build.zig.zon=$zon_ver"
echo "abi:     build.zig=$bz_abi  kyte_abi.h=$h_abi"

if [ "$bz_ver" != "$zon_ver" ]; then
  echo "ERROR: kyte_version ($bz_ver) != build.zig.zon .version ($zon_ver)"; fail=1
fi
if [ "$bz_abi" != "$h_abi" ]; then
  echo "ERROR: build.zig kyte_abi_version ($bz_abi) != kyte_abi.h KYTE_ABI_VERSION ($h_abi)"; fail=1
fi

# kynalyzer (the language server) ships in the SAME release archive as kyte, built from source pinned to this
# lang checkout, so its version MUST match. Only checked when the kynalyzer repo is present as a sibling (a
# lang-only clone skips it); the release runners always have it checked out, so a drift fails the release.
KYNALYZER_ZON=""
for p in "$ROOT/../kynalyzer/build.zig.zon" "$ROOT/kynalyzer/build.zig.zon"; do
  [ -f "$p" ] && { KYNALYZER_ZON="$p"; break; }
done
if [ -n "$KYNALYZER_ZON" ]; then
  kynalyzer_ver="$(grep -oE '\.version = "[^"]+"' "$KYNALYZER_ZON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  echo "kynalyzer:     build.zig.zon=$kynalyzer_ver  (lang=$bz_ver)"
  if [ "$kynalyzer_ver" != "$bz_ver" ]; then
    echo "ERROR: kynalyzer version ($kynalyzer_ver) != kyte_version ($bz_ver) -- bump kynalyzer/build.zig.zon to match"; fail=1
  fi
else
  echo "kynalyzer:     (repo not present as a sibling -- version-lock check skipped)"
fi

[ "$fail" -eq 0 ] && echo "version sync OK" || { echo "version drift -- fix the sites above"; exit 1; }
