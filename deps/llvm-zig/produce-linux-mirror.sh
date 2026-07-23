#!/usr/bin/env bash
# Produce a Linux static-LLVM mirror tarball for github.com/kamlesh-nb/llvm-dist.
# Run INSIDE a native Ubuntu 24.04 container for the target arch, e.g.:
#   docker run --rm --platform linux/arm64 -v "$PWD":/w ubuntu:24.04 bash /w/produce-linux-mirror.sh aarch64
# Emits llvm-21-<arch>-linux.tar.gz (lib/ = 226 libLLVM*.a + z/zstd/xml2/lzma static + libstdc++/libgcc_s .so).
set -e
ARCH="${1:-$(uname -m)}"                        # aarch64 | x86_64
case "$ARCH" in aarch64) TRIPLE=aarch64 ;; x86_64) TRIPLE=x86_64 ;; *) echo "arch?"; exit 1 ;; esac
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget lsb-release software-properties-common gnupg xz-utils \
    zlib1g-dev libzstd-dev libxml2-dev liblzma-dev g++ >/dev/null
wget -q https://apt.llvm.org/llvm.sh -O /llvm.sh && chmod +x /llvm.sh && /llvm.sh 21 >/dev/null 2>&1
apt-get install -y -qq llvm-21-dev >/dev/null
P="/out/llvm-21-${TRIPLE}-linux"; mkdir -p "$P/lib"
cp /usr/lib/llvm-21/lib/libLLVM*.a "$P/lib/"                                   # 226 native ELF components
G="/usr/lib/${ARCH}-linux-gnu"
cp "$G/libz.a" "$G/libzstd.a" "$G/libxml2.a" "$G/liblzma.a" "$P/lib/"          # LLVM's C-lib deps (static)
SO=$(find / -name libstdc++.so.6 | head -1); cp "$SO" "$P/lib/"; ln -sf libstdc++.so.6 "$P/lib/libstdc++.so"
GS=$(find / -name libgcc_s.so.1 | head -1);  cp "$GS" "$P/lib/"; ln -sf libgcc_s.so.1  "$P/lib/libgcc_s.so"
( cd "$P" && tar czf "/w/llvm-21-${TRIPLE}-linux.tar.gz" lib )
echo "wrote /w/llvm-21-${TRIPLE}-linux.tar.gz ($(du -h /w/llvm-21-${TRIPLE}-linux.tar.gz|cut -f1))"
echo "then: zig fetch <tarball>  → put the printed hash in build.zig.zon"
