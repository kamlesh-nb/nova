#!/usr/bin/env bash
# Fetch the PINNED Zig toolchain for this host and verify it against the committed
# checksums, then print the bin dir on the last line (add it to PATH). This is the
# single reproducible-fetch path used by BOTH CI and developers (L4 toolchain pin).
#
#   eval "$(scripts/bootstrap-zig.sh)"        # dev: install + add to PATH for this shell
#   ZIG_BIN="$(scripts/bootstrap-zig.sh | tail -1)"   # CI: capture the bin dir
#
# It refuses to proceed if the download's sha256 does not match scripts/zig-checksums.txt,
# so a tampered or wrong-version tarball can never silently build the compiler.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/.zig-version")"
DEST="${ZIG_INSTALL_DIR:-$HOME/.kyte-zig}"

log() { echo "bootstrap-zig: $*" >&2; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   ARCH="x86_64-linux" ;;
  Linux-aarch64)  ARCH="aarch64-linux" ;;
  Darwin-arm64)   ARCH="aarch64-macos" ;;
  Darwin-x86_64)  ARCH="x86_64-macos" ;;
  *) log "unsupported host $(uname -s)-$(uname -m); use scripts/bootstrap-zig.ps1 on Windows"; exit 1 ;;
esac

TARBALL="zig-${ARCH}-${VERSION}.tar.xz"
DIR="$DEST/zig-${ARCH}-${VERSION}"
BIN="$DIR"

# Already installed and the right version? Skip the download.
if [ -x "$BIN/zig" ] && [ "$("$BIN/zig" version 2>/dev/null || true)" = "$VERSION" ]; then
  log "Zig $VERSION already present at $BIN"
  echo "$BIN"
  exit 0
fi

WANT="$(grep -E "  ${TARBALL}\$" "$ROOT/scripts/zig-checksums.txt" | awk '{print $1}')"
if [ -z "$WANT" ]; then
  log "no pinned checksum for $TARBALL in scripts/zig-checksums.txt"; exit 1
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://ziglang.org/download/${VERSION}/${TARBALL}"
log "downloading $URL"
curl -fSL --retry 3 -o "$TMP/$TARBALL" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
  GOT="$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')"
else
  GOT="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
fi
if [ "$GOT" != "$WANT" ]; then
  log "CHECKSUM MISMATCH for $TARBALL"
  log "  expected $WANT"
  log "  got      $GOT"
  log "refusing to install an unverified toolchain"; exit 1
fi
log "checksum OK ($GOT)"

rm -rf "$DIR"
tar -xJf "$TMP/$TARBALL" -C "$DEST"
[ -x "$BIN/zig" ] || { log "extracted tree has no zig at $BIN"; exit 1; }
log "installed Zig $VERSION to $BIN"
echo "$BIN"
