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

# Parameters (M6-A): int/bool params flow as the i64 word; the param VALUE becomes an operand after mem2reg,
# so its width must be threaded (regression guard for the param-type stamping).
emit_case params '
fn add(a: int, b: int): int { return a + b; }
fn poly(x: int, y: int): int { return x * x + y * 2 - 1; }
fn less(a: int, b: int): bool { return a < b; }
fn dbl(x: int): int { return x + x; }                        // param used in arithmetic
fn povf(x: int): int { return x + x; }                       // 4e9 -> wrap at call site
fn main(): void { console.log(`${add(3, 4)} ${poly(5, 6)} ${less(2, 9)} ${dbl(21)} ${povf(2000000000)}`); }
'

# Control flow (M6-B): multi-block CFG (if/else, nested if, while loops with mutated locals). Exercises
# condbr/br terminators and mem2reg across blocks.
emit_case control '
fn absv(x: int): int { if (x < 0) { return 0 - x; } return x; }
fn clamp(x: int): int { if (x > 100) { return 100; } else { if (x < 0) { return 0; } } return x; }
fn sumto(n: int): int { let s = 0; let i = 1; while (i <= n) { s = s + i; i = i + 1; } return s; }
fn count(flag: bool): int { let c = 0; if (flag) { c = c + 10; } else { c = c + 20; } return c; }
fn main(): void { console.log(`${absv(0-7)} ${absv(5)} ${clamp(250)} ${clamp(0-5)} ${clamp(42)} ${sumto(100)} ${count(true)} ${count(false)}`); }
'

# Direct calls (M6-C): resolved by name to an all-word LLVM function; leaf, nested, and recursive. The
# nested case (add(sq(a),sq(b))) is the mem2reg-dangling-load regression guard (a load kept live by an
# opaque call between store and load must NOT have its slot removed by full promotion).
emit_case calls '
fn sq(x: int): int { return x * x; }
fn add(a: int, b: int): int { return a + b; }
fn hyp(a: int, b: int): int { return add(sq(a), sq(b)); }
fn fact(n: int): int { if (n <= 1) { return 1; } return n * fact(n - 1); }
fn fib(n: int): int { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
fn main(): void { console.log(`${sq(7)} ${add(3, 4)} ${hyp(3, 4)} ${fact(5)} ${fib(10)}`); }
'

# Structs (M6-D): heap struct with scalar fields -- construction (fresh, rc=1 return), field read/write on
# a param. Uses `class` because a plain `struct` is now a VALUE type (stack alloca, a different ABI the emit
# path leaves to the AST); `class` is the heap/reference case this slice emits. `shift` returns a BORROWED
# param, which needs a retain the emit path does not do, so it MUST fall back -- the binaries are ASAN-linked,
# so a wrongly-emitted shift would double-free and diverge here.
emit_case structs '
class Point { x: int, y: int }
fn mk(a: int, b: int): Point { return Point{x: a, y: b}; }
fn getx(p: Point): int { return p.x; }
fn dist2(p: Point): int { return p.x * p.x + p.y * p.y; }
fn shift(p: Point, dx: int): Point { p.x = p.x + dx; return p; }
fn main(): void { let p = mk(3, 4); console.log(`${getx(p)} ${dist2(p)} ${getx(shift(p, 10))}`); }
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
