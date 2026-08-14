#!/usr/bin/env bash
# emit-differential.sh — regression gate for the optimiser LIR->LLVM emit path (NOVA_OPT_EMIT).
#
# The emit path emits the optimised MIR for a small airtight subset (paramless, straight-line, signed
# int/bool) and falls back to the AST for everything else. This gate compiles a set of integer programs
# BOTH ways -- the trusted AST path and the emit path -- runs each, and asserts the output is byte-identical.
# It is the differential oracle the emit path was built against: exercises 32-bit-honest wrap, chained
# overflow (width-honest constfold), comparisons, and bitops -- the cases that a naive i64 fold or a missing
# canonicalize would silently miscompile. Off by default in the corpus; run this explicitly.
#
# Usage: conformance/emit-differential.sh   (expects `nova` on PATH)
set -u

NOVA="${NOVA:-nova}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

emit_case() { # name  body
    printf '%s\n' "$2" > "$TMP/$1.nova"
}

# Each case: a set of paramless int/bool functions printed via main(), so the emit path takes them.
emit_case arith '
fn a(): int { let x = 2; let y = 3; return x * y + 1; }
fn ov(): int { let b = 2000000000; return b + b; }          // 32-bit wrap: -294967296
fn chain(): int { let b = 2000000000; return (b + b) / 1000; } // chained overflow, width-honest fold
fn modw(): int { let b = 2000000000; return (b + b) % 100000; }
fn cmp(): bool { let p = 5; let q = 9; return p < q; }
fn bits(): int { let m = 12; let n = 10; return (m & n) | (m ^ n); }
fn shl(): int { let s = 1; return s << 5; }
fn main(): void { console.log(`${a()} ${ov()} ${chain()} ${modw()} ${cmp()} ${bits()} ${shl()}`); }
'

for f in "$TMP"/*.nova; do
    name="$(basename "$f" .nova)"
    if ! "$NOVA" "$f" -o "$TMP/${name}_ast" >/dev/null 2>&1; then
        echo "FAIL  $name: AST-path compile failed"; fail=1; continue
    fi
    if ! NOVA_OPT_EMIT=1 "$NOVA" "$f" -o "$TMP/${name}_emit" >/dev/null 2>&1; then
        echo "FAIL  $name: emit-path compile failed"; fail=1; continue
    fi
    a_out="$("$TMP/${name}_ast")"
    e_out="$("$TMP/${name}_emit")"
    if [ "$a_out" = "$e_out" ]; then
        echo "PASS  $name  ($a_out)"
    else
        echo "FAIL  $name: AST=[$a_out] EMIT=[$e_out]"; fail=1
    fi
done

if [ "$fail" -eq 0 ]; then echo "emit-differential: all cases identical AST vs emit"; else echo "emit-differential: DIVERGENCE"; fi
exit "$fail"
