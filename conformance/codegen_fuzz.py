#!/usr/bin/env python3
# Codegen SOUNDNESS fuzzer (F2-6 W11). Distinct from conformance/fuzz.sh, which is a FRONT-END crash
# fuzzer (mutate -> the compiler must not crash). This one generates WELL-TYPED Nova programs whose
# result is known independently (a Python oracle computing Nova's exact integer semantics), compiles and
# runs each, and reports a MISCOMPILE when the program's answer differs from the oracle -- the class of
# bug fuzz.sh cannot see. It targets the arithmetic / cast / comparison surface (the H-cluster fixed this
# session: 32-bit wrap, truncating divide/modulo, narrowing casts, NaN-free integer compares).
#
#   conformance/codegen_fuzz.py [--n N] [--seed S] [--keep]
#
# Exit non-zero and keep the offending .nova under fuzz-artifacts/ on the first miscompile or unexpected
# compile error (the program is well-typed, so it MUST compile and run).
import argparse
import os
import random
import subprocess
import sys
import tempfile

I32_MIN, I32_MAX = -(2**31), 2**31 - 1


def wrap(v, bits):
    """Two's-complement wrap to `bits`-wide signed."""
    v &= (1 << bits) - 1
    if v >= (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def wrap32(v):
    return wrap(v, 32)


def tdiv(a, b):
    """Truncate-toward-zero division (Nova / on int), matching C/LLVM sdiv."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def tmod(a, b):
    """Remainder with the sign of the dividend (Nova % on int), matching srem."""
    return a - tdiv(a, b) * b


class Gen:
    def __init__(self, rnd, nvars):
        self.rnd = rnd
        # A pool of int vars with fixed concrete values -- the oracle knows them, the program declares them.
        self.vars = {f"v{i}": wrap32(rnd.randint(I32_MIN, I32_MAX)) for i in range(nvars)}

    def expr(self, depth):
        """Return (nova_source, oracle_value) for an int-typed expression."""
        r = self.rnd
        if depth <= 0 or r.random() < 0.35:
            if self.vars and r.random() < 0.5:
                name = r.choice(list(self.vars))
                return name, self.vars[name]
            # Literal. Bias toward small values and boundaries to hit wrap/edge cases.
            lit = r.choice(
                [r.randint(-50, 50), r.randint(-1000, 1000), I32_MIN, I32_MAX, -1, 0, 1,
                 r.randint(I32_MIN, I32_MAX)])
            # A bare negative literal is `-N`; Nova parses that as unary neg of a positive literal.
            return (f"({lit})" if lit < 0 else str(lit)), wrap32(lit)

        op = r.choice(["+", "-", "*", "/", "%", "&", "|", "<<", ">>"])
        la, lv = self.expr(depth - 1)
        ra, rv = self.expr(depth - 1)

        if op == "+":
            val = wrap32(lv + rv)
        elif op == "-":
            val = wrap32(lv - rv)
        elif op == "*":
            val = wrap32(lv * rv)
        elif op == "/":
            if rv == 0:
                ra, rv = "1", 1  # avoid the (now-trapping) divide-by-zero; not the target here
            # INT_MIN / -1 at i64 word then canonicalized to i32 -> wraps (defined), model it exactly.
            val = wrap32(tdiv(lv, rv))
        elif op == "%":
            if rv == 0:
                ra, rv = "1", 1
            val = wrap32(tmod(lv, rv))
        elif op == "&":
            val = wrap32(lv & rv)
        elif op == "|":
            val = wrap32(lv | rv)
        elif op == "<<":
            sh = rv & 31          # Nova/LLVM shift amount is masked; use a defined 0..31
            ra = str(sh)
            val = wrap32(lv << sh)
        else:  # ">>"
            sh = rv & 31
            ra = str(sh)
            val = wrap32(lv >> sh)  # arithmetic shift on a signed i32 (Python >> is arithmetic)

        src = f"({la} {op} {ra})"

        # Occasionally wrap in a narrowing-then-widening cast chain (exercises the H2 cast fix).
        if r.random() < 0.3:
            kind, bits, signed = r.choice(
                [("byte", 8, False), ("sbyte", 8, True), ("short", 16, True), ("ushort", 16, False)])
            narrowed = val & ((1 << bits) - 1)
            widened = wrap(narrowed, bits) if signed else narrowed
            src = f"(({src} as {kind}) as int)"
            val = wrap32(widened)
        return src, val


def make_program(gen, depth):
    src, oracle = gen.expr(depth)
    lines = ["import assert;", "", "@test", "fn t(): void {"]
    for name, v in gen.vars.items():
        lit = f"({v})" if v < 0 else str(v)
        lines.append(f"    let {name}: int = {lit};")
    lines.append(f"    assert.equalInt({src}, {oracle});")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=int(os.environ.get("NOVA_CGFUZZ_N", "200")))
    ap.add_argument("--seed", type=int, default=int(os.environ.get("NOVA_CGFUZZ_SEED", "1")))
    ap.add_argument("--depth", type=int, default=4)
    ap.add_argument("--nvars", type=int, default=3)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    nova = os.path.expanduser("~/.nova/bin/nova")
    lang = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    artifacts = os.path.join(lang, "fuzz-artifacts")

    passed = 0
    for i in range(args.n):
        rnd = random.Random(args.seed + i)
        gen = Gen(rnd, args.nvars)
        prog = make_program(gen, args.depth)
        with tempfile.NamedTemporaryFile("w", suffix=".nova", delete=False) as f:
            path = f.name
            f.write(prog)
        try:
            res = subprocess.run([nova, "test", path], capture_output=True, text=True, timeout=60)
            out = res.stdout + res.stderr
            ok = ("0 failed" in out) and ("MISCOMPILE" not in out) and res.returncode == 0
            if not ok:
                os.makedirs(artifacts, exist_ok=True)
                keep = os.path.join(artifacts, f"cgfuzz_seed{args.seed + i}.nova")
                with open(keep, "w") as kf:
                    kf.write(prog)
                sys.stderr.write(
                    f"\nMISCOMPILE at seed {args.seed + i} (saved {keep}):\n{prog}\n--- output ---\n{out}\n")
                sys.exit(1)
            passed += 1
        finally:
            if not args.keep:
                try:
                    os.unlink(path)
                except OSError:
                    pass
        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{args.n} ok")

    print(f"codegen_fuzz: {passed}/{args.n} programs matched the oracle (seed {args.seed}, depth {args.depth}).")


if __name__ == "__main__":
    main()
