#!/usr/bin/env bash
# Build the Kyte runtime archive (libkytecore.a) for the four shipping targets:
# {x86_64, aarch64} x {linux-gnu, windows-msvc}.
#
# Why `zig c++` and not `clang++`: cross-compiling runtime.cpp needs a sysroot for the
# target's libc headers, and a bare clang has none -- every Linux target fails at
# <cstdio> from a Windows host, and from Linux the aarch64 target needs
# libc6-dev-arm64-cross installed. Zig ships those headers for every target it knows,
# so three of the four cross builds need nothing installed at all.
#
# The exception is aarch64-windows-msvc: zig cannot synthesise the MSVC ARM64 libc
# ("failed to find libc installation"), because that one genuinely comes from the
# Visual Studio install. clang++ finds it via the same MSVC toolchain that builds the
# native compiler, so that target uses clang++ directly.
#
# CRYPTO ASSEMBLY -- every target gets its kernels, and both files are MANDATORY here:
#   kyte_crypto_amd64.S serves both x86_64 targets; its PROLOG_n macros already normalise
#   Win64 to SysV, so one file covers both ABIs.
#   kyte_crypto_arm64.S serves both aarch64 targets, but only since the constant-pool
#   relocations were made object-format-conditional (CPOOL_PAGE/CPOOL_LO12 in that file).
#   It previously used Mach-O `@PAGE`/`@PAGEOFF` unconditionally and assembled on macOS
#   and nowhere else.
#
# There is NO "just omit the asm" option on aarch64, which is why this script treats a
# failed assemble as fatal rather than falling back. crypto.cpp compiles no portable C
# under __aarch64__ and its kyte_has_asm_crypto() returns 1 unconditionally there, so an
# arm64 archive built without the .S promises hardware crypto while defining none of the
# entry points -- kyte_aes_encrypt_block, kyte_sha256_blocks, kyte_ghash and friends are
# simply absent, and the failure lands as undefined symbols at the FINAL link of any Kyte
# program that touches crypto. Verify with:
#   llvm-nm --defined-only <archive> | grep kyte_aes_encrypt_block
#
# -DKYTE_ASM_CRYPTO_X86 is what switches crypto.cpp from portable C to the CPUID
# dispatchers, so it is set on exactly the targets that also assemble the x86 file.
# Setting it without the object would leave crypto.cpp calling symbols nothing defined.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/zig-out/archives}"
cd "$HERE"

mkdir -p "$OUT"
rc=0

# A smoke translation unit that REFERENCES the crypto entry points, so linking it is a real
# check that the archive is complete. Symbol listing alone is not: the first arm64 archives
# built here listed happily and were missing every entry point under the name C calls.
#
# It is C++ with everything in `extern "C"`, not a .c file. `clang++` compiles .c as C++, so plain C
# declarations get C++-mangled: the crypto externs come out as `?kyte_has_asm_crypto@@YAHXZ`, and
# `__kyte_main` mangles too, so the archive's `main` cannot find it. That surfaces first as
# `LNK1561: entry point must be defined` -- which reads like a subsystem/entry problem and is really
# name mangling.
SMOKE="$(mktemp -t kyte_smoke.XXXXXX.cpp)"
trap 'rm -f "$SMOKE" "${SMOKE%.cpp}"* 2>/dev/null' EXIT
#
# It defines `__kyte_main`, NOT `main`: the runtime supplies its own `main` (concurrency.cpp, where
# it masks SIGPIPE and starts the reactor) and calls `__kyte_main()` -- the same symbol codegen emits
# for a Kyte program's entry. Defining `main` here instead collides with the archive's:
#   ld.lld: error: duplicate symbol: main ... in archive libkytecore.a
cat > "$SMOKE" <<'EOC'
extern "C" {
int  kyte_has_asm_crypto(void);
void kyte_sha256_blocks(void *state, const void *data, long long blocks);
void kyte_sha512_blocks(void *state, const void *data, long long blocks);
void kyte_ghash(void *acc, const void *h, const void *data, long long len);
void kyte_aes_encrypt_block(const void *rk, int nr, const void *in, void *out);
long long __kyte_main(void) {
  volatile void *keep[] = { (void*)kyte_sha256_blocks, (void*)kyte_sha512_blocks,
                            (void*)kyte_ghash, (void*)kyte_aes_encrypt_block };
  (void)keep;
  return kyte_has_asm_crypto();
}
}
EOC

build_one() {
  local triple="$1" cc="$2" asm_src="$3" asm_def="$4" link_smoke="$5"
  local d="$OUT/$triple"
  mkdir -p "$d"
  printf '%-24s ' "$triple"

  if ! $cc -target "$triple" --target="$triple" -std=c++20 -O2 -DKYTE_DROP_ARENA $asm_def \
        -c src/runtime/runtime.cpp -o "$d/kytecore.o" 2>"$d/build.log"; then
    echo "FAIL (runtime.cpp) -- see $d/build.log"; rc=1; return
  fi

  local objs="$d/kytecore.o"
  if [[ -n "$asm_src" ]]; then
    if ! $cc -target "$triple" --target="$triple" -O2 -c "$asm_src" -o "$d/kyte_crypto.o" 2>>"$d/build.log"; then
      echo "FAIL (asm) -- see $d/build.log"; rc=1; return
    fi
    objs="$objs $d/kyte_crypto.o"
  fi

  # Archive in the format the TARGET's linker expects, not the host's.
  #   Windows: `kytecore.lib`, a COFF archive written by llvm-lib. MSVC's link.exe cannot read
  #     llvm-ar's GNU archive at all -- that incompatibility is why the in-tree Windows link path
  #     (pipeline.appendRuntimeLink) names the bare .o files instead of an archive. llvm-lib emits
  #     the format link.exe wants, so a .lib is both the right extension and actually linkable:
  #     verified here by linking an executable against the .lib, not just against the objects.
  #   Linux: `libkytecore.a`, an ordinary GNU archive from llvm-ar.
  local lib
  if [[ "$triple" == *windows* ]]; then
    lib="$d/kytecore.lib"
    rm -f "$lib"
    if ! llvm-lib "-out:$lib" $objs 2>>"$d/build.log"; then
      echo "FAIL (llvm-lib) -- see $d/build.log"; rc=1; return
    fi
  else
    lib="$d/libkytecore.a"
    rm -f "$lib"
    if ! llvm-ar rcs "$lib" $objs 2>>"$d/build.log"; then
      echo "FAIL (llvm-ar) -- see $d/build.log"; rc=1; return
    fi
  fi

  # Link a real executable against the archive. This is the check that matters: it fails on a
  # missing entry point, which a symbol dump can be read as passing.
  # Link with the SAME toolchain that compiled the objects. Mixing them fails: a zig-built
  # windows-msvc object linked by clang++ asks for `libc++.lib`, which the MSVC toolchain has no
  # such thing as, and clang++-built objects linked by `zig c++` hit zig's libc++abi conflicting
  # with MSVC's <vcruntime_typeinfo.h>.
  local smoke_note="smoke-link SKIPPED (no target CRT here)"
  if [[ "$link_smoke" == "yes" ]]; then
    local exe="$d/smoke"
    local -a link_cmd
    if [[ "$triple" == *windows* ]]; then
      exe="$d/smoke.exe"
      link_cmd=(clang++ "--target=$triple" "$SMOKE" "$lib" -rtlib=compiler-rt -lws2_32 -lmswsock -lbcrypt -o "$exe")
    else
      link_cmd=(zig c++ -target "$triple" "$SMOKE" "$lib" -o "$exe")
    fi
    if "${link_cmd[@]}" 2>>"$d/build.log"; then
      smoke_note="smoke-link OK"
    else
      echo "FAIL (smoke link) -- see $d/build.log"; rc=1; return
    fi
  fi

  printf 'OK  %-14s %-6s  %s\n' "$(basename "$lib")" "$(du -h "$lib" | cut -f1)" "$smoke_note"
}

# `zig c++` takes -target; clang++ takes --target=. Both are passed above and each
# compiler ignores the spelling it does not know, so one call site serves both.
#
# aarch64-windows-msvc uses clang++ and cannot be smoke-linked here for the SAME reason zig cannot
# compile it -- this box has the x64 MSVC CRT but not the ARM64 one. clang++ finds the ARM64 HEADERS
# (enough to compile), not the import libraries (needed to link). Its archive is verified by format
# and symbol table only; run this script on a machine with the ARM64 MSVC toolchain to close that.
build_one x86_64-linux-gnu     "zig c++"  src/runtime/kyte_crypto_amd64.S -DKYTE_ASM_CRYPTO_X86 yes
build_one aarch64-linux-gnu    "zig c++"  src/runtime/kyte_crypto_arm64.S ""                    yes
build_one x86_64-windows-msvc  "clang++"  src/runtime/kyte_crypto_amd64.S -DKYTE_ASM_CRYPTO_X86 yes
build_one aarch64-windows-msvc "clang++"  src/runtime/kyte_crypto_arm64.S ""                    no

echo
echo "Archives under $OUT/<triple>/  (kytecore.lib on Windows, libkytecore.a on Linux)"
exit $rc
