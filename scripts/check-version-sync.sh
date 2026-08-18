#!/usr/bin/env bash
# L5 stability guard: the version lives in several files that MUST agree. This fails loud if any
# drift, so a release can never ship a mismatched `nova version` / build.zig.zon / ABI header.
#   - nova_version   in build.zig  ==  .version  in build.zig.zon
#   - nova_abi_version in build.zig ==  NOVA_ABI_VERSION in src/runtime/nova_abi.h
# Wired into the CI soundness job; run it locally before cutting a release.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0

bz_ver="$(grep -oE 'nova_version = "[^"]+"' "$ROOT/build.zig" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
zon_ver="$(grep -oE '\.version = "[^"]+"' "$ROOT/build.zig.zon" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
bz_abi="$(grep -oE 'nova_abi_version: u32 = [0-9]+' "$ROOT/build.zig" | grep -oE '[0-9]+$')"
h_abi="$(grep -oE '#define NOVA_ABI_VERSION [0-9]+' "$ROOT/src/runtime/nova_abi.h" | grep -oE '[0-9]+$')"

echo "version: build.zig=$bz_ver  build.zig.zon=$zon_ver"
echo "abi:     build.zig=$bz_abi  nova_abi.h=$h_abi"

if [ "$bz_ver" != "$zon_ver" ]; then
  echo "ERROR: nova_version ($bz_ver) != build.zig.zon .version ($zon_ver)"; fail=1
fi
if [ "$bz_abi" != "$h_abi" ]; then
  echo "ERROR: build.zig nova_abi_version ($bz_abi) != nova_abi.h NOVA_ABI_VERSION ($h_abi)"; fail=1
fi

# nls (the language server) ships in the SAME release archive as nova, built from source pinned to this
# lang checkout, so its version MUST match. Only checked when the nls repo is present as a sibling (a
# lang-only clone skips it); the release runners always have it checked out, so a drift fails the release.
NLS_ZON=""
for p in "$ROOT/../nls/build.zig.zon" "$ROOT/nls/build.zig.zon"; do
  [ -f "$p" ] && { NLS_ZON="$p"; break; }
done
if [ -n "$NLS_ZON" ]; then
  nls_ver="$(grep -oE '\.version = "[^"]+"' "$NLS_ZON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  echo "nls:     build.zig.zon=$nls_ver  (lang=$bz_ver)"
  if [ "$nls_ver" != "$bz_ver" ]; then
    echo "ERROR: nls version ($nls_ver) != nova_version ($bz_ver) -- bump nls/build.zig.zon to match"; fail=1
  fi
else
  echo "nls:     (repo not present as a sibling -- version-lock check skipped)"
fi

[ "$fail" -eq 0 ] && echo "version sync OK" || { echo "version drift -- fix the sites above"; exit 1; }
