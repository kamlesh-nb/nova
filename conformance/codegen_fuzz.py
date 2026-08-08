#!/usr/bin/env python3
# Codegen SOUNDNESS fuzzer (F2-6 W11). Distinct from conformance/fuzz.sh, which is a FRONT-END crash
# fuzzer (mutate -> the compiler must not crash). This one generates WELL-TYPED Nova programs whose
# result is known independently (a Python oracle computing Nova's exact integer semantics), compiles and
# runs each, and reports a MISCOMPILE when the program's answer differs from the oracle -- the class of
# bug fuzz.sh cannot see.
#
# Coverage: `int` (i32) and `long` (i64) arithmetic (+ - * / % & | << >>) with two's-complement wrap,
# truncate-toward-zero divide/modulo, narrowing-then-widening casts, and the six comparison operators
# (== != < > <= >=). Two program shapes: a value assertion (`assert.equalInt`) and a boolean assertion
# (`assert.isTrue`/`isFalse` on a comparison) -- the boolean shape also value-checks `long` without
# emitting a 64-bit oracle literal.
#
#   conformance/codegen_fuzz.py [--n N] [--seed S] [--keep]
#
# Exit non-zero and keep the offending .nova under fuzz-artifacts/ on the first miscompile or unexpected
# compile error (the program is well-typed, so it MUST compile and run).
#
# Deliberately avoided (they are separately-tracked OPEN items, not what this fuzzer targets, and would be
# false positives): divide/modulo by zero and i64 MIN / -1 (both now trap by design); integer literals at
# the i64 boundary (a known lexer bug); an unannotated `<< 63` (a known shift-result-inference bug).
import argparse
import os
import random
import subprocess
import sys
import tempfile

I32_MIN, I32_MAX = -(2**31), 2**31 - 1
# Keep long leaf literals well inside the i64 range to dodge the known i64-boundary lexer bug.
LONG_LIT_LIM = 2**60


def wrap(v, bits):
    v &= (1 << bits) - 1
    if v >= (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def tdiv(a, b):
    """Truncate-toward-zero division (Nova / on int/long), matching LLVM sdiv."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def tmod(a, b):
    """Remainder with the sign of the dividend (Nova %), matching srem."""
    return a - tdiv(a, b) * b


CMP = ["==", "!=", "<", ">", "<=", ">="]


def cmp_eval(op, a, b):
    return {"==": a == b, "!=": a != b, "<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]


class Gen:
    def __init__(self, rnd, nvars, typ):
        self.rnd = rnd
        self.typ = typ                      # "int" or "long"
        self.bits = 32 if typ == "int" else 64
        lim = I32_MAX if typ == "int" else LONG_LIT_LIM
        self.vars = {}
        for i in range(nvars):
            v = rnd.randint(-lim - (1 if typ == "int" else 0), lim)
            self.vars[f"v{i}"] = self.wrapT(v)

    def wrapT(self, v):
        return wrap(v, self.bits)

    def _lit(self):
        r = self.rnd
        if self.typ == "int":
            choices = [r.randint(-50, 50), r.randint(-1000, 1000), I32_MIN, I32_MAX, -1, 0, 1,
                       r.randint(I32_MIN, I32_MAX)]
        else:
            choices = [r.randint(-50, 50), r.randint(-1000, 1000), -1, 0, 1,
                       r.randint(-LONG_LIT_LIM, LONG_LIT_LIM)]
        return self.wrapT(r.choice(choices))

    def expr(self, depth):
        """Return (nova_source, oracle_value) for an expression of type self.typ."""
        r = self.rnd
        if depth <= 0 or r.random() < 0.35:
            if self.vars and r.random() < 0.5:
                name = r.choice(list(self.vars))
                return name, self.vars[name]
            lit = self._lit()
            src = f"({lit})" if lit < 0 else str(lit)
            # A bare small literal defaults to `int` in Nova. In a `long` expression that would make a
            # sub-operation 32-bit (e.g. a shift by >= 32 becomes UB) and diverge from the 64-bit oracle,
            # so pin every literal leaf to the expression's type.
            if self.typ == "long":
                src = f"({src} as long)"
            return src, lit

        op = r.choice(["+", "-", "*", "/", "%", "&", "|", "<<", ">>"])
        la, lv = self.expr(depth - 1)
        ra, rv = self.expr(depth - 1)

        if op == "+":
            val = self.wrapT(lv + rv)
        elif op == "-":
            val = self.wrapT(lv - rv)
        elif op == "*":
            val = self.wrapT(lv * rv)
        elif op in ("/", "%"):
            # Avoid the trapping cases (÷0, and long i64 MIN / -1). Replacing a -1 divisor with 1 is enough
            # to sidestep the overflow, and forcing nonzero sidesteps the div-by-zero trap.
            if rv == 0 or (self.typ == "long" and rv == -1):
                ra, rv = "1", 1
            val = self.wrapT(tdiv(lv, rv) if op == "/" else tmod(lv, rv))
        elif op == "&":
            val = self.wrapT(lv & rv)
        elif op == "|":
            val = self.wrapT(lv | rv)
        elif op == "<<":
            sh = rv & (self.bits - 1)       # masked, defined 0..bits-1
            ra = str(sh)
            val = self.wrapT(lv << sh)
        else:  # ">>"
            sh = rv & (self.bits - 1)
            ra = str(sh)
            val = self.wrapT(lv >> sh)      # arithmetic shift (Python >> on a signed int)

        src = f"({la} {op} {ra})"

        # Occasionally narrow-then-widen back to self.typ (exercises the H2 cast path at both widths).
        if r.random() < 0.3:
            kind, kbits, signed = r.choice(
                [("byte", 8, False), ("sbyte", 8, True), ("short", 16, True), ("ushort", 16, False)])
            low = val & ((1 << kbits) - 1)
            narrowed = wrap(low, kbits) if signed else low
            src = f"(({src} as {kind}) as {self.typ})"
            val = self.wrapT(narrowed)
        return src, val


def make_program(rnd, nvars, typ):
    gen = Gen(rnd, nvars, typ)
    lines = ["import assert;", "", "@test", "fn t(): void {"]
    for name, v in gen.vars.items():
        lit = f"({v})" if v < 0 else str(v)
        lines.append(f"    let {name}: {typ} = {lit};")

    # int values are checkable directly; long (and half the int cases) are checked via a comparison,
    # which needs no 64-bit oracle literal.
    if typ == "int" and rnd.random() < 0.5:
        src, oracle = gen.expr(4)
        lines.append(f"    assert.equalInt({src}, {oracle});")
    else:
        la, lv = gen.expr(4)
        # Bias toward operands that can actually be equal, so ==/<=/>= exercise their true branch.
        if rnd.random() < 0.4:
            ra, rv = la, lv                 # identical operand -> == true, != false
        else:
            ra, rv = gen.expr(4)
        op = rnd.choice(CMP)
        truth = cmp_eval(op, lv, rv)
        assertion = "isTrue" if truth else "isFalse"
        lines.append(f"    assert.{assertion}({la} {op} {ra});")

    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=int(os.environ.get("NOVA_CGFUZZ_N", "200")))
    ap.add_argument("--seed", type=int, default=int(os.environ.get("NOVA_CGFUZZ_SEED", "1")))
    ap.add_argument("--nvars", type=int, default=3)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    nova = os.path.expanduser("~/.nova/bin/nova")
    lang = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    artifacts = os.path.join(lang, "fuzz-artifacts")

    passed = 0
    for i in range(args.n):
        rnd = random.Random(args.seed + i)
        typ = rnd.choice(["int", "long"])
        prog = make_program(rnd, args.nvars, typ)
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
                    f"\nMISCOMPILE at seed {args.seed + i} ({typ}, saved {keep}):\n{prog}\n"
                    f"--- output ---\n{out}\n")
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

    print(f"codegen_fuzz: {passed}/{args.n} programs matched the oracle "
          f"(seed {args.seed}, int+long, arith/cast/compare).")


if __name__ == "__main__":
    main()
