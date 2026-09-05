#!/usr/bin/env python3
"""
Kyte foundation probe harness  (deterministic, local, no LLM)

Systematically stress-tests the danger zones that have produced foundation bugs
(erasure x ARC seam: container-of-trait/struct, `?? default` on owned values,
tuples, enums, closures-in-generics, unnarrowed optionals, trait widening at every
argument position, string aliasing) and reports what CRASHES / LEAKS / DISAGREES.

It does NOT reason about the spec or invent new gaps — it CONFIRMS a fixed matrix of
adversarial patterns. Add probes to PROBES to widen coverage.

Run from the `lang/` dir:   python3 foundation_probe.py
Requires: zig at ~/zig/zig (edit ZIG below), a buildable kyte.

Modes per probe:
  FUNC   -> `kyte test`                  : does it compile+run and pass?
  ASAN   -> KYTE_ASAN=1 build + run      : heap-use-after-free / double-free?
  SHADOW -> KYTE_SEMA_SHADOW=1 run       : static-vs-dynamic ownership DISAGREE?
  ARC    -> KYTE_ARC_AUDIT=1 run         : leak (live objects at exit)?

Each probe declares `expect`: "ok" (should be clean) or "known-bad" (documents a
known-open gap). The report flags OK-probes that fail (regressions / new gaps) and
known-bad probes that now pass (fixed).
"""
import os, subprocess, tempfile, sys, textwrap, shutil

ZIG   = os.path.expanduser("~/zig/zig")
LANG  = os.getcwd()                      # run from lang/
KYTE  = os.path.join(LANG, "zig-out", "bin", "kyte")
TMP   = tempfile.mkdtemp(prefix="kyteprobe_")

# ---------------------------------------------------------------- probe matrix
# code: a full .ky @test file.   expect: "ok" | "known-bad"
PROBES = [
 # ---- container-of-trait / struct (the Map<K,Trait>.get family) ----
 dict(name="map_trait_narrow", cat="container", expect="ok", code=r'''
import assert; import map; import string;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 7; } }
@test fn t(): void {
  let m = Map<string, G>(8, string.hash); m.set("a", A{});
  let h = m.get("a"); if (h == undefined) { assert.equalInt(0,1); return; }
  assert.equalInt(h.hi(), 7);
}'''),
 dict(name="map_trait_coalesce", cat="container", expect="known-bad", code=r'''
import assert; import map; import string;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 7; } }
@test fn t(): void {
  let m = Map<string, G>(8, string.hash); m.set("a", A{});
  assert.equalInt((m.get("a") ?? A{}).hi(), 7);
}'''),
 dict(name="map_struct_coalesce", cat="container", expect="known-bad", code=r'''
import assert; import map; import string;
struct P { pub x: int, init(x: int) { self.x = x; } }
@test fn t(): void {
  let m = Map<string, P>(8, string.hash); m.set("p", P(42));
  assert.equalInt((m.get("p") ?? P(0)).x, 42);
}'''),
 dict(name="list_trait_get", cat="container", expect="ok", code=r'''
import assert; import list;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 5; } }
@test fn t(): void {
  let xs = List<G>(); xs.push(A{});
  let h = xs.get(0); if (h == undefined) { assert.equalInt(0,1); return; }
  assert.equalInt(h.hi(), 5);
}'''),

 # ---- optionals / ?? on owned values ----
 dict(name="opt_unnarrowed_access", cat="optional", expect="known-bad", code=r'''
import assert; import list;
@test fn t(): void {
  let xs = List<string>();  // empty
  let s = xs.get(5);        // undefined
  assert.equalInt(s.length, 0);  // unnarrowed access to absent optional
}'''),
 dict(name="coalesce_owned_string", cat="optional", expect="ok", code=r'''
import assert; import map; import string;
@test fn t(): void {
  let m = Map<string, string>(8, string.hash); m.set("a", "hi");
  assert.equalStr(m.get("a") ?? "", "hi");
}'''),

 # ---- tuples ----
 dict(name="tuple_return_heap", cat="tuple", expect="ok", code=r'''
import assert; import string;
fn split(s: string): (string, string) { return (string.slice(s,0,1), string.slice(s,1,s.length)); }
@test fn t(): void { let (a,b) = split("hello"); assert.equalStr(a,"h"); assert.equalStr(b,"ello"); }'''),
 dict(name="tuple_return_via_local", cat="tuple", expect="known-bad", code=r'''
import assert; import string;
fn split(s: string): (string, string) { let t = (string.slice(s,0,1), string.slice(s,1,s.length)); return t; }
@test fn t(): void { let (a,b) = split("hello"); assert.equalStr(a,"h"); assert.equalStr(b,"ello"); }'''),
 dict(name="tuple_element_type_unchecked", cat="tuple", expect="known-bad", code=r'''
import assert;
fn d(): (int, string) { return (5, "x"); }
@test fn t(): void { let (v, e) = d(); let bad = v + e; assert.equalInt(bad, bad); }'''),  # int+string should be a type error

 # ---- enums ----
 dict(name="enum_switch_on_param", cat="enum", expect="ok", code=r'''
import assert;
enum E { A(int), B }
fn code(e: E): int { switch (e) { case E.A(n): return n; case E.B: return -1; } }
@test fn t(): void { assert.equalInt(code(E.A(9)), 9); }'''),
 dict(name="enum_switch_on_local", cat="enum", expect="known-bad", code=r'''
import assert;
enum E { A(int), B }
@test fn t(): void { let e = E.A(9); switch (e) { case E.A(n): assert.equalInt(n,9); case E.B: assert.equalInt(0,1); } }'''),

 # ---- closures ----
 dict(name="closure_capture_owned", cat="closure", expect="ok", code=r'''
import assert; import string;
@test fn t(): void { let s = "hi" + "!"; let f = (x) => s; assert.equalStr(f(0), "hi!"); }'''),
 dict(name="closure_in_generic_method", cat="closure", expect="ok", code=r'''
import assert; import serde.source;
@serializable struct U { pub id: int }
struct R { init() {} fn run<T>(self: R, s: ValueSource): string { let f = (x) => serde.typeName<T>(); return f(s); } }
@test fn t(): void { let r = R(); assert.equalStr(r.run<U>(source.fromJson("{}")), "U"); }'''),

 # ---- generics / monomorphization ----
 dict(name="generic_method_reify", cat="generic", expect="ok", code=r'''
import assert; import serde.source;
@serializable struct U { pub id: int }
struct R { init() {} fn dec<T>(self: R, s: ValueSource): T { return serde.bind<T>(s); } }
@test fn t(): void { let r = R(); assert.equalInt(r.dec<U>(source.fromJson("{\"id\": 3}")).id, 3); }'''),
 dict(name="nested_generic_map_key", cat="generic", expect="ok", code=r'''
import assert; import map; import string; import list;
@test fn t(): void {
  let m = Map<string, List<int>>(8, string.hash); let l = List<int>(); l.push(1); m.set("a", l);
  let g = m.get("a"); if (g == undefined) { assert.equalInt(0,1); return; }
  assert.equalInt(g.size(), 1);
}'''),

 # ---- string aliasing (shadow) ----
 dict(name="string_reassign_alias", cat="string", expect="ok", code=r'''
import assert; import string;
fn firstWord(s: string): string {
  let sp = string.indexOf(s, " ");
  let w = s;
  if (sp != -1) { w = string.slice(s, 0, sp); }
  return w;
}
@test fn t(): void { assert.equalStr(firstWord("hello world"), "hello"); }'''),

 # ---- trait widening at various positions ----
 dict(name="widen_fn_arg", cat="trait-widen", expect="ok", code=r'''
import assert;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 7; } }
fn call(g: G): int { return g.hi(); }
@test fn t(): void { assert.equalInt(call(A{}), 7); }'''),
 dict(name="widen_struct_field", cat="trait-widen", expect="ok", code=r'''
import assert;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 7; } }
struct Box { pub g: G, init(g: G) { self.g = g; } }
@test fn t(): void { let b = Box(A{}); assert.equalInt((b.g).hi(), 7); }'''),
 dict(name="widen_coalesce_default", cat="trait-widen", expect="known-bad", code=r'''
import assert; import map; import string;
trait G { fn hi(self: G): int; }
struct A impl G { fn hi(self: A): int { return 7; } }
@test fn t(): void {
  let m = Map<string, G>(8, string.hash); m.set("a", A{});
  assert.equalInt((m.get("z") ?? A{}).hi(), 7);  // default struct in trait-typed ??
}'''),
]

# ---------------------------------------------------------------- runners
def sh(cmd, env=None, timeout=90):
    e = dict(os.environ);
    if env: e.update(env)
    try:
        p = subprocess.run(cmd, shell=True, cwd=LANG, env=e, capture_output=True, timeout=timeout)
        dec = lambda b: (b or b"").decode("utf-8", "replace")
        return p.returncode, dec(p.stdout) + dec(p.stderr)
    except subprocess.TimeoutExpired:
        return 124, "(timeout)"

def build(asan):
    env = {"KYTE_ASAN": "1"} if asan else {}
    rc, out = sh(f"{ZIG} build", env=env, timeout=600)
    return rc == 0, out

def write_probe(p):
    path = os.path.join(TMP, p["name"] + ".ky")
    with open(path, "w") as f: f.write(p["code"])
    return path

def classify_func(out):
    if "terminated abnormally" in out or "SEGV" in out: return "CRASH"
    if "Results:" in out and " 0 failed" in out: return "pass"
    if "compilation failed" in out or "Parser error" in out or "Type checking failed" in out: return "compile-err"
    if "Results:" in out: return "test-fail"
    return "?"

def classify_asan(out):
    if "heap-use-after-free" in out: return "UAF"
    if "double-free" in out or "attempting double-free" in out: return "double-free"
    if "AddressSanitizer" in out and ("SEGV" in out or "SUMMARY" in out): return "SEGV/asan"
    if "Results:" in out and " 0 failed" in out: return "clean"
    return "?"

def classify_shadow(out):
    if "FOUNDATION GATE FAILED" in out or "DISAGREE" in out: return "DISAGREE"
    if "Results:" in out: return "agree"
    return "?"

def classify_arc(out):
    if "ARC AUDIT FAILED" in out:
        import re
        m = re.search(r"ARC AUDIT FAILED: (\d+)", out)
        return f"leak={m.group(1)}" if m else "leak"
    if "ARC audit: clean" in out: return "clean"
    return "?"

# ---------------------------------------------------------------- drive
def main():
    if not os.path.exists(ZIG):
        print(f"!! zig not found at {ZIG} — edit ZIG at top of script"); sys.exit(2)
    print(f"probe dir: {TMP}\n")

    results = {p["name"]: {} for p in PROBES}

    # phase 1: non-ASAN binary -> FUNC / SHADOW / ARC
    print("building non-ASAN kyte ...", flush=True)
    ok, out = build(False)
    if not ok: print("BUILD FAILED (non-asan):\n" + out[-2000:]); sys.exit(1)
    for p in PROBES:
        path = write_probe(p)
        _, o = sh(f"{KYTE} test {path}");                    results[p["name"]]["FUNC"]   = classify_func(o)
        _, o = sh(f"{KYTE} test {path}", {"KYTE_SEMA_SHADOW":"1"}); results[p["name"]]["SHADOW"] = classify_shadow(o)
        _, o = sh(f"{KYTE} test {path}", {"KYTE_ARC_AUDIT":"1"});   results[p["name"]]["ARC"]    = classify_arc(o)
        print(f"  {p['name']:<30} FUNC={results[p['name']]['FUNC']:<12} SHADOW={results[p['name']]['SHADOW']:<10} ARC={results[p['name']]['ARC']}", flush=True)

    # phase 2: ASAN binary -> ASAN
    print("\nbuilding ASAN kyte ...", flush=True)
    ok, out = build(True)
    if not ok:
        print("BUILD FAILED (asan):\n" + out[-2000:])
    else:
        for p in PROBES:
            path = os.path.join(TMP, p["name"] + ".ky")
            _, o = sh(f"{KYTE} test {path}", {"KYTE_ASAN":"1"})
            results[p["name"]]["ASAN"] = classify_asan(o)
            print(f"  {p['name']:<30} ASAN={results[p['name']]['ASAN']}", flush=True)

    # restore non-ASAN binary for the user
    print("\nrestoring non-ASAN build ...", flush=True); build(False)

    # ---------------------------------------------------------------- report
    print("\n" + "=" * 92)
    print(f"{'PROBE':<30} {'CAT':<12} {'EXPECT':<10} FUNC/ASAN/SHADOW/ARC")
    print("-" * 92)
    surprises = []
    for p in PROBES:
        r = results[p["name"]]
        row = f"{r.get('FUNC','?')}/{r.get('ASAN','?')}/{r.get('SHADOW','?')}/{r.get('ARC','?')}"
        bad = any(v in ("CRASH","UAF","double-free","SEGV/asan","DISAGREE") or (isinstance(v,str) and v.startswith("leak"))
                  for v in r.values())
        # OK-probe that misbehaves = new/regression gap; known-bad that's clean = fixed
        flag = ""
        if p["expect"] == "ok" and bad:        flag = "  <== REGRESSION / GAP"; surprises.append((p["name"],"ok-but-bad"))
        if p["expect"] == "known-bad" and not bad: flag = "  <== now FIXED (retire known-bad)"; surprises.append((p["name"],"fixed"))
        print(f"{p['name']:<30} {p['cat']:<12} {p['expect']:<10} {row}{flag}")
    print("=" * 92)
    print(f"\n{len(surprises)} surprise(s):")
    for n, k in surprises: print(f"  - {n}: {k}")
    print(f"\nlegend: FUNC pass/CRASH/compile-err | ASAN clean/UAF/double-free | SHADOW agree/DISAGREE | ARC clean/leak=N")
    print("known-bad = a documented-open gap; 'ok' that shows CRASH/UAF/leak/DISAGREE is a NEW gap to record.")

if __name__ == "__main__":
    main()
