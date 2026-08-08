#!/usr/bin/env python3
# Codegen SOUNDNESS fuzzer (F2-6 W11). Distinct from conformance/fuzz.sh, which is a FRONT-END crash
# fuzzer (mutate -> the compiler must not crash). This one generates WELL-TYPED Nova programs whose
# result is known independently (a Python oracle computing Nova's exact integer semantics), compiles and
# runs each, and reports a MISCOMPILE when the program's answer differs from the oracle -- the class of
# bug fuzz.sh cannot see.
#
# Coverage:
#   - int (i32) and long (i64) arithmetic (+ - * / % & | << >>) with two's-complement wrap,
#     truncate-toward-zero divide/modulo, narrowing-then-widening casts, and the six comparisons.
#   - STRUCTS: a generated struct with int/long fields is constructed with known values, its fields are
#     read back and combined -> exercises field-offset codegen and struct lifecycle (cluster C).
#   - GENERICS: a generic box `Box<T>`, a free generic fn `id<T>` called both explicitly (`id<int>(x)`)
#     and via inference (`id(x)`), and generic composition (`outer<T>` calling `inner<T>`) -> exercises
#     monomorphisation, free-fn inference and cross-generic instantiation (cluster B). T in {int, long}.
#
# The value is always ultimately an int/long/bool checked against the oracle, so structs and generics are
# validated by round-tripping known values through them.
#
#   conformance/codegen_fuzz.py [--n N] [--seed S] [--keep]
#
# Exit non-zero and keep the offending .nova under fuzz-artifacts/ on the first miscompile or unexpected
# compile error (the program is well-typed, so it MUST compile and run).
#
# Deliberately avoided (separately-tracked OPEN items, would be false positives): divide/modulo by zero
# and i64 MIN / -1 (both trap by design); i64-boundary integer literals (a lexer bug); an unannotated
# `<< 63` (a shift-result-inference bug).
import argparse
import os
import random
import subprocess
import sys
import tempfile

I32_MIN, I32_MAX = -(2**31), 2**31 - 1
LONG_LIT_LIM = 2**60          # keep long leaf literals inside i64 to dodge the boundary lexer bug
CMP = ["==", "!=", "<", ">", "<=", ">="]


def wrap(v, bits):
    v &= (1 << bits) - 1
    if v >= (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def tdiv(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def tmod(a, b):
    return a - tdiv(a, b) * b


def cmp_eval(op, a, b):
    return {"==": a == b, "!=": a != b, "<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]


def lit_src(v, typ):
    """A literal source for value `v` of type `typ`. Long literals are pinned `as long` so a sub-op is
    never silently 32-bit (a bare small literal defaults to int)."""
    s = f"({v})" if v < 0 else str(v)
    return f"({s} as long)" if typ == "long" else s


class Gen:
    """Builds an int/long expression tree over a fixed set of named leaves (name -> known value)."""

    def __init__(self, rnd, typ, varmap):
        self.rnd = rnd
        self.typ = typ
        self.bits = 32 if typ == "int" else 64
        self.vars = dict(varmap)

    def wrapT(self, v):
        return wrap(v, self.bits)

    def _lit(self):
        r = self.rnd
        if self.typ == "int":
            pool = [r.randint(-50, 50), r.randint(-1000, 1000), I32_MIN, I32_MAX, -1, 0, 1,
                    r.randint(I32_MIN, I32_MAX)]
        else:
            pool = [r.randint(-50, 50), r.randint(-1000, 1000), -1, 0, 1,
                    r.randint(-LONG_LIT_LIM, LONG_LIT_LIM)]
        return self.wrapT(r.choice(pool))

    def expr(self, depth):
        r = self.rnd
        if depth <= 0 or r.random() < 0.35:
            if self.vars and r.random() < 0.55:
                name = r.choice(list(self.vars))
                return name, self.vars[name]
            lit = self._lit()
            return lit_src(lit, self.typ), lit

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
            if rv == 0 or (self.typ == "long" and rv == -1):
                ra, rv = lit_src(1, self.typ), 1
            val = self.wrapT(tdiv(lv, rv) if op == "/" else tmod(lv, rv))
        elif op == "&":
            val = self.wrapT(lv & rv)
        elif op == "|":
            val = self.wrapT(lv | rv)
        elif op == "<<":
            sh = rv & (self.bits - 1)
            ra = str(sh)
            val = self.wrapT(lv << sh)
        else:
            sh = rv & (self.bits - 1)
            ra = str(sh)
            val = self.wrapT(lv >> sh)

        src = f"({la} {op} {ra})"
        if r.random() < 0.3:
            kind, kbits, signed = r.choice(
                [("byte", 8, False), ("sbyte", 8, True), ("short", 16, True), ("ushort", 16, False)])
            low = val & ((1 << kbits) - 1)
            narrowed = wrap(low, kbits) if signed else low
            src = f"(({src} as {kind}) as {self.typ})"
            val = self.wrapT(narrowed)
        return src, val


def rand_val(rnd, typ):
    lim = I32_MAX if typ == "int" else LONG_LIT_LIM
    lo = I32_MIN if typ == "int" else -LONG_LIT_LIM
    return wrap(rnd.randint(lo, lim), 32 if typ == "int" else 64)


# ---- templates: each returns (top_decls, setup_lets, varmap) whose leaves have known values ----

def tmpl_plain(rnd, typ):
    lets, varmap = [], {}
    for i in range(3):
        v = rand_val(rnd, typ)
        lets.append(f"    let v{i}: {typ} = {lit_src(v, typ)};")
        varmap[f"v{i}"] = v
    return [], lets, varmap


def tmpl_struct(rnd, typ):
    k = rnd.randint(2, 4)
    fields = [f"f{i}" for i in range(k)]
    vals = [rand_val(rnd, typ) for _ in range(k)]
    field_decls = ", ".join(f"pub {f}: {typ}" for f in fields)
    assigns = " ".join(f"self.{f} = a{i};" for i, f in enumerate(fields))
    params = ", ".join(f"a{i}: {typ}" for i in range(k))
    decl = [f"struct S {{ {field_decls}, init({params}) {{ {assigns} }} }}"]
    args = ", ".join(lit_src(v, typ) for v in vals)
    lets = [f"    let s = S({args});"]
    varmap = {f"s.{f}": v for f, v in zip(fields, vals)}
    return decl, lets, varmap


def tmpl_gbox(rnd, typ):
    # Generic box round-trip: the value must survive construction + field read at the concrete T.
    val = rand_val(rnd, typ)
    decl = ["struct Box<T> { pub v: T, init(x: T) { self.v = x; } }"]
    lets = [f"    let b = Box<{typ}>({lit_src(val, typ)});"]
    varmap = {"b.v": val}
    # add a plain var too for richer expressions
    v = rand_val(rnd, typ)
    lets.append(f"    let w: {typ} = {lit_src(v, typ)};")
    varmap["w"] = v
    return decl, lets, varmap


def tmpl_gfn(rnd, typ):
    # Free generic fn. Explicit form uses a typed let; inference form drops the annotation (both compile).
    # NOTE: `let g: T = ident(v)` -- inference INTO a typed let -- is a separate open checker gap, avoided.
    val = rand_val(rnd, typ)
    decl = ["fn ident<T>(x: T): T { return x; }"]
    if rnd.random() < 0.5:
        lets = [f"    let g = ident({lit_src(val, typ)});"]          # inference, no annotation (B1)
    else:
        lets = [f"    let g: {typ} = ident<{typ}>({lit_src(val, typ)});"]  # explicit type args
    varmap = {"g": val}
    return decl, lets, varmap


def tmpl_gcompose(rnd, typ):
    # Generic composition: outer<T> forwards its type param to inner<T> (exercises B2). Explicit args.
    val = rand_val(rnd, typ)
    decl = [
        "fn inner<T>(x: T): T { return x; }",
        "fn outer<T>(x: T): T { return inner<T>(x); }",
    ]
    lets = [f"    let g: {typ} = outer<{typ}>({lit_src(val, typ)});"]
    varmap = {"g": val}
    return decl, lets, varmap


def tmpl_valopt_list(rnd, typ):
    # A value-optional container: push a random mix of known values and `undefined` into a
    # List<T | undefined>, then read each back with `at(k) ?? default`. The oracle knows each read is the
    # pushed value if present (INCLUDING a present 0, which must read back as 0, not the default) or the
    # default if it was undefined -> exercises box-on-insert / unbox-on-read (cluster A, cases 280/281).
    bits = 32 if typ == "int" else 64
    # Push a mix of known values and `undefined` across ENOUGH elements to force a storage growth (the
    # initial capacity is 4), then read each element back. This is the shape that surfaced A3-read: a
    # `List<T | undefined>` monomorphised to the same symbol as a plain `List<int>` (the legacy type-name
    # path rendered `int | undefined` as `int`), so a >=2-element read dereferenced a mis-typed slot. It is
    # fixed (case 286: value-optionals render distinctly); the fuzzer now reads multiple elements again.
    n = rnd.randint(2, 6)
    lets = [f"    let xs = List<{typ} | undefined>();"]
    reads = []
    varmap = {}
    for k in range(n):
        d = rnd.randint(1, 40)
        if rnd.random() < 0.6:
            v = rand_val(rnd, typ)
            lets.append(f"    xs.push({lit_src(v, typ)});")
            leafval = v
        else:
            lets.append("    xs.push(undefined);")
            leafval = wrap(d, bits)
        # Read each element ONCE into a local, then the expression combines the locals. The oracle knows
        # each read is the pushed value if present (INCLUDING a present 0) or the default if it was undefined.
        reads.append(f"    let r{k}: {typ} = xs.at({k}) ?? {lit_src(d, typ)};")
        varmap[f"r{k}"] = leafval
    return [], lets + reads, varmap


TEMPLATES = [tmpl_plain, tmpl_plain, tmpl_struct, tmpl_gbox, tmpl_gfn, tmpl_gcompose, tmpl_valopt_list]


def make_program(rnd):
    typ = rnd.choice(["int", "long"])
    top_decls, setup_lets, varmap = rnd.choice(TEMPLATES)(rnd, typ)
    gen = Gen(rnd, typ, varmap)

    imports = ["import assert;"]
    if any("List<" in l for l in setup_lets):
        imports.append("import list;")
    lines = imports + [""]
    lines += top_decls
    if top_decls:
        lines.append("")
    lines += ["@test", "fn t(): void {"]
    lines += setup_lets

    if typ == "int" and rnd.random() < 0.5:
        src, oracle = gen.expr(4)
        lines.append(f"    assert.equalInt({src}, {oracle});")
    else:
        la, lv = gen.expr(4)
        if rnd.random() < 0.4:
            ra, rv = la, lv
        else:
            ra, rv = gen.expr(4)
        op = rnd.choice(CMP)
        assertion = "isTrue" if cmp_eval(op, lv, rv) else "isFalse"
        lines.append(f"    assert.{assertion}({la} {op} {ra});")

    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=int(os.environ.get("NOVA_CGFUZZ_N", "200")))
    ap.add_argument("--seed", type=int, default=int(os.environ.get("NOVA_CGFUZZ_SEED", "1")))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    nova = os.path.expanduser("~/.nova/bin/nova")
    lang = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    artifacts = os.path.join(lang, "fuzz-artifacts")

    passed = 0
    for i in range(args.n):
        rnd = random.Random(args.seed + i)
        prog = make_program(rnd)
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

    print(f"codegen_fuzz: {passed}/{args.n} programs matched the oracle "
          f"(seed {args.seed}, int+long, arith/cast/compare/struct/generic/valopt).")


if __name__ == "__main__":
    main()
