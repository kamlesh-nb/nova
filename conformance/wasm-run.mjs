// Run a kyte-compiled wasm module under Node and report whether its @test
// functions pass. Turns the --wasm gate from "compiles+links" into "executes".
//
// kyte wasm modules delegate a small set of runtime functions to host imports
// (env.*). This harness implements them against the module's own memory +
// exported allocator (kyte_bytes_alloc writes the 8-byte header {refcount@0,
// length@4} and returns base+8; a kyte string is that byte pointer, length at
// [ptr-4]). Decimal128 is stubbed — those cases fail here but still link.
//
// Usage:  node wasm-run.mjs <module.wasm>
//   exit 0 = all @test functions ran with no failure/trap; non-zero otherwise.
import { readFileSync } from 'node:fs';
import crypto from 'node:crypto';

// --guard: bounds-checking mode. Static data ([0, __heap_base)) is effectively read-only for a running
// program (string/decimal literals, trait vtables), EXCEPT the allocator's own globals. After every
// @test we re-verify that region is byte-identical; the FIRST test that mutates it is the one doing an
// out-of-bounds write — which is exactly how a corrupted vtable/function-pointer becomes a
// call_indirect "null function". Reports the test, the changed offset(s), and old→new bytes.
const GUARD = process.argv.includes('--guard');
const path = process.argv.filter((a) => a !== '--guard')[2];
if (!path) { console.error('usage: wasm-run.mjs [--guard] <module.wasm>'); process.exit(2); }
const wasmBytes = readFileSync(path);

let memory, exports;
let failed = false, failMsg = '';

const u8 = () => new Uint8Array(memory.buffer);
const view = () => new DataView(memory.buffer);

// wasm32 ABI: a pointer is 32-bit, but kyte's universal value handle is i64 (it must hold an f64).
// A pointer therefore travels in the LOW 32 bits of that i64; the high bits are don't-care (inside
// wasm, `inttoptr i64->ptr` truncates to i32, so memory access is correct even when they are dirty —
// e.g. a re-entrant alloc leaves stack garbage there). But a HOST import receives the full i64, so it
// MUST mask to 32 bits before using it as a linear-memory offset. This is the wasm32 pointer ABI, not
// a workaround: every offset above is < 4GB, so the low 32 bits are the whole address.
const ptr32 = (x) => Number((typeof x === 'bigint' ? x : BigInt(x)) & 0xffffffffn);

// Read a kyte string (byte ptr; length at [ptr-4]).
function readStr(ptr) {
  ptr = ptr32(ptr);
  if (ptr === 0) return '';
  const len = view().getInt32(ptr - 4, true);
  return new TextDecoder().decode(u8().subarray(ptr, ptr + len));
}
// Read `len` raw bytes at ptr (for log, which is given the length).
function readN(ptr, len) {
  ptr = ptr32(ptr); len = Number(len);
  return new TextDecoder().decode(u8().subarray(ptr, ptr + len));
}
// Read a NUL-terminated C string (an LLVM global, e.g. a decimal literal handed to
// kyte_decimal_from_string) — NOT length-prefixed like a kyte string.
function readCStr(ptr) {
  ptr = ptr32(ptr);
  if (ptr === 0) return '';
  const mem = u8();
  let end = ptr;
  while (end < mem.length && mem[end] !== 0) end++;
  return new TextDecoder().decode(mem.subarray(ptr, end));
}
// Allocate a kyte string via the module allocator, return its byte ptr (BigInt).
function makeStr(s) {
  const b = new TextEncoder().encode(s);
  const ptr = ptr32(exports.ky_bytes_alloc(BigInt(b.length)));
  u8().set(b, ptr);
  return BigInt(ptr);
}
// Reinterpret an i64 (BigInt) bit pattern as an f64.
function bitsToF64(bits) {
  const d = new DataView(new ArrayBuffer(8));
  d.setBigInt64(0, BigInt.asIntN(64, bits), true);
  return d.getFloat64(0, true);
}

// Atomics: the pointer is i32 (a plain Number offset); i32 values are Numbers,
// i64 values are BigInts. CAS returns a *bool* (1 if swapped, 0 if not) — kyte's
// compareAndSwap(expected, desired): bool — NOT the old value.
const atomicRW = {
  load_i32: (p) => view().getInt32(ptr32(p), true),
  load_i64: (p) => view().getBigInt64(ptr32(p), true),
  load_bool: (p) => (u8()[ptr32(p)] ? 1 : 0),
  store_i32: (p, v) => { view().setInt32(ptr32(p), v, true); },
  store_i64: (p, v) => { view().setBigInt64(ptr32(p), v, true); },
  store_bool: (p, v) => { u8()[ptr32(p)] = v ? 1 : 0; },
  add_i32: (p, v) => { p = ptr32(p); const o = view().getInt32(p, true); view().setInt32(p, o + v, true); return o; },
  add_i64: (p, v) => { p = ptr32(p); const o = view().getBigInt64(p, true); view().setBigInt64(p, o + v, true); return o; },
  sub_i32: (p, v) => { p = ptr32(p); const o = view().getInt32(p, true); view().setInt32(p, o - v, true); return o; },
  cas_i32: (p, e, d) => { p = ptr32(p); const o = view().getInt32(p, true); if (o === e) { view().setInt32(p, d, true); return 1; } return 0; },
  cas_i64: (p, e, d) => { p = ptr32(p); const o = view().getBigInt64(p, true); if (o === e) { view().setBigInt64(p, d, true); return 1; } return 0; },
  cas_bool: (p, e, d) => { p = ptr32(p); const o = u8()[p] ? 1 : 0; if (o === e) { u8()[p] = d ? 1 : 0; return 1; } return 0; },
};

// decimal128 (BID) — a faithful BigInt port of src/runtime/decimal.cpp. A kyte `decimal` is a POINTER
// to a 16-byte little-endian BID128: number = (-1)^sign * coeff * 10^(biasedExp - 6176), with
// sign=bit127, biasedExp=bits126..113 (14b), coeff=bits112..0 (113b). BigInt is exact, so no u128
// overflow bookkeeping is needed except to match the C++ rounding at encode/align/div.
const DEC_BIAS = 6176, DEC_MAXD = 34, DEC_MAXBIASED = 12287;
const MASK113 = (1n << 113n) - 1n, MASK64 = (1n << 64n) - 1n;
const decNumDigits = (v) => (v === 0n ? 1 : String(v).length);
const decPow10 = (k) => 10n ** BigInt(k);
const decRoundDrop = (coeff, k) => {                    // drop low k digits, round-half-even
  if (k <= 0) return coeff;
  const div = decPow10(k), q = coeff / div, r = coeff % div, half = div / 2n;
  if (r > half) return q + 1n;
  if (r === half && (q & 1n) === 1n) return q + 1n;
  return q;
};
function decDecode(ptr) {
  const p = ptr32(ptr);
  const v = (view().getBigUint64(p + 8, true) << 64n) | view().getBigUint64(p, true);
  const sign = Number((v >> 127n) & 1n);
  if (((v >> 125n) & 3n) === 3n) return { sign, coeff: 0n, exp: 0, special: true };
  const biased = Number((v >> 113n) & 0x3fffn);
  return { sign, coeff: v & MASK113, exp: biased - DEC_BIAS, special: false };
}
function decPack(sign, coeff, exp) {
  let biased = exp + DEC_BIAS;
  if (biased < 0) biased = 0; if (biased > DEC_MAXBIASED) biased = DEC_MAXBIASED;
  let v = (coeff & MASK113) | (BigInt(biased & 0x3fff) << 113n);
  if (sign) v |= 1n << 127n;
  const p = ptr32(exports.ky_bytes_alloc(16n));
  view().setBigUint64(p, v & MASK64, true);
  view().setBigUint64(p + 8, (v >> 64n) & MASK64, true);
  return BigInt(p);
}
function decEncode(d) {
  let nd = decNumDigits(d.coeff);
  if (nd > DEC_MAXD) {
    const drop = nd - DEC_MAXD; d.coeff = decRoundDrop(d.coeff, drop); d.exp += drop;
    if (decNumDigits(d.coeff) > DEC_MAXD) { d.coeff = decRoundDrop(d.coeff, 1); d.exp += 1; }
  }
  if (d.coeff === 0n) d.sign = 0;
  return decPack(d.sign, d.coeff, d.exp);
}
function decAlign(a, b) {
  let E = Math.min(a.exp, b.exp);
  const msd = Math.max(a.exp + decNumDigits(a.coeff), b.exp + decNumDigits(b.coeff));
  if (E < msd - 37) E = msd - 37;
  for (const d of [a, b]) {
    if (d.exp > E) { d.coeff *= decPow10(d.exp - E); d.exp = E; }
    else if (d.exp < E) { d.coeff = decRoundDrop(d.coeff, E - d.exp); d.exp = E; }
  }
}
function decAddSigned(a, b) {
  if (a.special || b.special) return decPack(0, 0n, 0);
  decAlign(a, b);
  const r = { sign: 0, coeff: 0n, exp: a.exp, special: false };
  if (a.sign === b.sign) { r.coeff = a.coeff + b.coeff; r.sign = a.sign; }
  else if (a.coeff >= b.coeff) { r.coeff = a.coeff - b.coeff; r.sign = a.sign; }
  else { r.coeff = b.coeff - a.coeff; r.sign = b.sign; }
  return decEncode(r);
}
const dec = {
  fromStr(str) {
    str = str.trim(); let i = 0, sign = 0;
    if (str[i] === '+') i++; else if (str[i] === '-') { sign = 1; i++; }
    let coeff = 0n, frac = 0, seenDot = false, exp = 0;
    for (; i < str.length; i++) {
      const c = str[i];
      if (c === '.') { if (seenDot) break; seenDot = true; continue; }
      if (c === 'e' || c === 'E') { exp += parseInt(str.slice(i + 1), 10) || 0; i = str.length; break; }
      if (c < '0' || c > '9') break;
      coeff = coeff * 10n + BigInt(c.charCodeAt(0) - 48); if (seenDot) frac++;
    }
    exp -= frac;
    return decEncode({ sign, coeff, exp, special: false });
  },
  toStr(ptr) {
    const { sign, coeff, exp, special } = decDecode(ptr);
    if (special) return '0';
    const S = coeff === 0n ? '0' : String(coeff), nd = S.length;
    let out = (sign && !(nd === 1 && S === '0')) ? '-' : '';
    if (exp >= 0) out += S + '0'.repeat(exp);
    else {
      const point = nd + exp;
      if (point <= 0) out += '0.' + '0'.repeat(-point) + S;
      else out += S.slice(0, point) + '.' + S.slice(point);
    }
    return out;
  },
  add: (a, b) => decAddSigned(decDecode(a), decDecode(b)),
  sub: (a, b) => { const bb = decDecode(b); bb.sign ^= 1; return decAddSigned(decDecode(a), bb); },
  mul(a, b) {
    const x = decDecode(a), y = decDecode(b);
    if (x.special || y.special) return decPack(0, 0n, 0);
    return decEncode({ sign: x.sign ^ y.sign, coeff: x.coeff * y.coeff, exp: x.exp + y.exp, special: false });
  },
  div(a, b) {
    const x = decDecode(a), y = decDecode(b);
    if (x.special || y.special) return decPack(0, 0n, 0);
    if (y.coeff === 0n) { failed = true; failMsg = 'decimal divide by zero'; return decPack(0, 0n, 0); }
    if (x.coeff === 0n) return decPack(0, 0n, 0);
    let P = DEC_MAXD + 1 - decNumDigits(x.coeff); if (P < 0) P = 0;
    const num = x.coeff * decPow10(P), q0 = num / y.coeff, rem = num % y.coeff, twice = rem * 2n;
    let q = q0;
    if (twice > y.coeff) q += 1n; else if (twice === y.coeff && (q & 1n) === 1n) q += 1n;
    const r = { sign: x.sign ^ y.sign, coeff: q, exp: x.exp - y.exp - P, special: false };
    const pref = x.exp - y.exp;                          // preferred exponent: 0.25 not 0.2500…0
    while (r.exp < pref && r.coeff !== 0n && r.coeff % 10n === 0n) { r.coeff /= 10n; r.exp += 1; }
    return decEncode(r);
  },
  mod(a, b) {
    const x = decDecode(a), y = decDecode(b);
    if (x.special || y.special) return decPack(0, 0n, 0);
    if (y.coeff === 0n) { failed = true; failMsg = 'decimal modulo by zero'; return decPack(0, 0n, 0); }
    decAlign(x, y);
    return decEncode({ sign: x.sign, coeff: x.coeff % y.coeff, exp: x.exp, special: false });
  },
  cmp(a, b) {
    const x = decDecode(a), y = decDecode(b);
    if (x.special || y.special) return 0n;
    const xz = x.coeff === 0n, yz = y.coeff === 0n;
    if (xz && yz) return 0n;
    const xs = xz ? 0 : (x.sign ? -1 : 1), ys = yz ? 0 : (y.sign ? -1 : 1);
    if (xs !== ys) return xs < ys ? -1n : 1n;
    decAlign(x, y);
    const mag = x.coeff < y.coeff ? -1 : (x.coeff > y.coeff ? 1 : 0);
    return BigInt(xs < 0 ? -mag : mag);
  },
  fromInt(n) {
    n = BigInt.asIntN(64, n); const sign = n < 0n ? 1 : 0;
    return decEncode({ sign, coeff: n < 0n ? -n : n, exp: 0, special: false });
  },
  toInt(ptr) {
    const d = decDecode(ptr); if (d.special) return 0n;
    let mag = d.coeff;
    if (d.exp > 0) mag *= decPow10(d.exp);
    else if (d.exp < 0) mag = -d.exp >= 39 ? 0n : mag / decPow10(-d.exp);
    const IMAX = (1n << 63n) - 1n, IMINMAG = 1n << 63n;
    if (d.sign) {
      if (mag > IMINMAG) { failed = true; failMsg = 'decimal to int overflow'; return 0n; }
      return mag === IMINMAG ? -(1n << 63n) : -mag;
    }
    if (mag > IMAX) { failed = true; failMsg = 'decimal to int overflow'; return 0n; }
    return mag;
  },
};

const env = {
  log: () => {},                       // stdout suppressed for the gate
  kyte_test_fail: (p) => { failed = true; failMsg = readStr(p); },
  kyte_optional_deref_fail: (p) => { failed = true; failMsg = 'optional-deref: ' + readStr(p); },
  kyte_panic: (p) => { failed = true; failMsg = 'panic: ' + readStr(p); },

  // Value-optional boxing (fixes the value-0-reads-as-undefined bug): a box is a plain 8-byte ARC
  // cell holding one i64 word; null/0 = undefined. Mirror alloc.cpp's kyte_valopt_box/unbox exactly,
  // allocating in the module's own linear memory via its exported allocator.
  kyte_valopt_box: (value) => {
    const ptr = ptr32(exports.ky_bytes_alloc(8n));
    if (ptr === 0) return 0n;
    view().setBigInt64(ptr, BigInt.asIntN(64, value), true);   // `value` is the boxed word — NOT a ptr, no mask
    return BigInt(ptr);
  },
  kyte_valopt_unbox: (box) => {
    const p = ptr32(box);
    if (p === 0) return 0n;
    return view().getBigInt64(p, true);
  },

  kyte_i64_to_string: (n) => makeStr(BigInt.asIntN(64, n).toString()),
  // f64_to_string receives the f64 DIRECTLY (a JS Number), not i64 bits. kyte
  // prints 3.0 as "3", 2.5 as "2.5" — the shortest round-trip repr, == String(f).
  kyte_f64_to_string: (f) => makeStr(String(f)),
  kyte_bool_to_string: (b) => makeStr(Number(b) ? 'true' : 'false'),
  kyte_f64_bits: (d) => { const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, d, true); return dv.getBigInt64(0, true); },

  kyte_getenv: (p) => makeStr(process.env[readStr(p)] ?? ''),
  kyte_setenv: () => {},
  kyte_arg_count: () => 0n,
  kyte_arg_at: () => makeStr(''),

  kyte_sha256: (p) => makeStr(crypto.createHash('sha256').update(readStr(p)).digest('hex')),
  kyte_sha512: (p) => makeStr(crypto.createHash('sha512').update(readStr(p)).digest('hex')),
  kyte_hmac_sha256: (k, m) => makeStr(crypto.createHmac('sha256', readStr(k)).update(readStr(m)).digest('hex')),
  kyte_random_hex: (n) => makeStr(crypto.randomBytes(Number(n)).toString('hex')),

  // decimal128 (BID) — faithful BigInt port of decimal.cpp (see `dec` above).
  kyte_decimal_from_string: (p) => dec.fromStr(readCStr(p)),   // literal path: NUL-terminated C string
  kyte_decimal_from_string_n: (p, n) => dec.fromStr(readN(p, n)),
  kyte_decimal_to_string: (p) => makeStr(dec.toStr(p)),
  kyte_decimal_add: dec.add, kyte_decimal_sub: dec.sub, kyte_decimal_mul: dec.mul,
  kyte_decimal_div: dec.div, kyte_decimal_mod: dec.mod, kyte_decimal_cmp: dec.cmp,
  kyte_decimal_from_int: dec.fromInt, kyte_decimal_to_int: dec.toInt,

  kyte_atomic_load_i32: atomicRW.load_i32, kyte_atomic_load_i64: atomicRW.load_i64, kyte_atomic_load_bool: atomicRW.load_bool,
  kyte_atomic_store_i32: atomicRW.store_i32, kyte_atomic_store_i64: atomicRW.store_i64, kyte_atomic_store_bool: atomicRW.store_bool,
  kyte_atomic_add_i32: atomicRW.add_i32, kyte_atomic_add_i64: atomicRW.add_i64, kyte_atomic_sub_i32: atomicRW.sub_i32,
  kyte_atomic_cas_i32: atomicRW.cas_i32, kyte_atomic_cas_i64: atomicRW.cas_i64, kyte_atomic_cas_bool: atomicRW.cas_bool,

  // Non-zeroed persistent allocation: delegate to the module's own exported allocator (persistent if it
  // exports one, else the plain bump allocator). The gate does not free, so "persistent" is a no-op here.
  kyte_bytes_alloc_persistent_nz: (size) =>
    (exports.ky_bytes_alloc_persistent ? exports.ky_bytes_alloc_persistent(size) : exports.ky_bytes_alloc(size)),

  // Bulk memory primitives over the module's own linear memory (memmove/memset/memcmp/memchr). These are
  // imported by any module that uses RawBuffer/string copies or the mem.memory module.
  kyte_bytes_copy: (dst, src, len) => {
    const d = ptr32(dst), s = ptr32(src), n = Number(len);
    if (!d || !s || n <= 0) return;
    u8().copyWithin(d, s, s + n);          // copyWithin is overlap-safe (memmove semantics)
  },
  kyte_mem_set: (dst, val, len) => {
    const d = ptr32(dst), n = Number(len);
    if (!d || n <= 0) return;
    u8().fill(Number(val) & 0xff, d, d + n);
  },
  kyte_mem_cmp: (a, b, len) => {
    const pa = ptr32(a), pb = ptr32(b), n = Number(len);
    if (n <= 0) return 0n;
    const arr = u8();
    for (let i = 0; i < n; i++) { const d = arr[pa + i] - arr[pb + i]; if (d !== 0) return BigInt(d < 0 ? -1 : 1); }
    return 0n;
  },
  kyte_mem_find: (p, val, len) => {
    const pp = ptr32(p), n = Number(len), v = Number(val) & 0xff;
    if (!pp || n <= 0) return -1n;
    const arr = u8();
    for (let i = 0; i < n; i++) if (arr[pp + i] === v) return BigInt(i);
    return -1n;
  },
};

const mod = await WebAssembly.instantiate(wasmBytes, { env }).catch((e) => {
  console.error('instantiate failed:', e.message); process.exit(1);
});
exports = mod.instance.exports;
memory = exports.memory;

// kyte @test functions: exported, no params, name contains "test".
const tests = Object.keys(exports).filter(
  (k) => typeof exports[k] === 'function' && exports[k].length === 0 && /(^|_)test/i.test(k),
);
if (tests.length === 0) { console.error('no @test exports found'); process.exit(1); }

// ---- bounds-checking guard setup ----------------------------------------------------------------
let guardBase = 0, snapshot = null, allocGlobals = [];
if (GUARD) {
  // Watch ONLY true static data [0, __data_end) — the region holding string/decimal literals and trait
  // vtables. The SHADOW STACK lives in [__data_end, __heap_base) and mutates legitimately, so watching
  // up to __heap_base drowns the signal in stack noise. __data_end is the honest read-only boundary.
  guardBase = Number(exports.__data_end?.value ?? exports.__heap_base?.value ?? 0);
  // The allocator's bump pointers live INSIDE static data and change legitimately — exclude them.
  for (const g of ['heap_ptr', 'persistent_ptr', 'free_list']) {
    const gv = exports[g];
    if (gv) { const a = Number(gv.value); for (let i = a; i < a + 8; i++) allocGlobals.push(i); }
  }
  const excl = new Set(allocGlobals);
  snapshot = u8().slice(0, guardBase);
  for (const i of excl) snapshot[i] = 0; // normalize excluded bytes so they never count as a diff
  console.error(`[guard] watching static data [0, ${guardBase}) minus ${excl.size} allocator bytes`);
}
function guardCheck(afterName) {
  const cur = u8();
  const excl = new Set(allocGlobals);
  let first = -1, count = 0, sample = '';
  for (let i = 0; i < guardBase; i++) {
    const b = excl.has(i) ? 0 : cur[i];
    if (b !== snapshot[i]) {
      if (first < 0) { first = i; sample = `[${i}] ${snapshot[i]}->${cur[i]}`; }
      count++;
    }
  }
  if (first >= 0) {
    console.error(`[guard] CORRUPTION after '${afterName}': ${count} static-data byte(s) changed, first at offset ${first}  (${sample})`);
    // resync so we report each NEW corrupter, not the same one repeatedly
    snapshot = u8().slice(0, guardBase);
    for (const i of excl) snapshot[i] = 0;
    return true;
  }
  return false;
}

let failName = '';
let anyCorruption = false;
for (const name of tests) {
  let trap = null;
  try { exports[name](); }
  catch (e) { trap = e.message; }
  if (GUARD) {
    if (trap) console.error(`[guard] (test '${name}' trapped: ${trap})`);
    if (guardCheck(name)) anyCorruption = true;
    failed = false; // keep going — we want to see EVERY corrupter, not stop at the first symptom
    continue;
  }
  if (trap) { failed = true; failName = name; failMsg = `trap: ${trap}`; break; }
  if (failed) { failName = name; break; }
}
if (GUARD) {
  console.error(anyCorruption ? '[guard] static-data corruption detected (see first-offset above)'
                              : '[guard] static data intact across all tests');
  process.exit(anyCorruption ? 3 : 0);
}
if (failed) { console.error(`FAIL in ${failName}: ${failMsg}`); process.exit(1); }
console.error(`ok: ${tests.length} @test fn(s)`);
process.exit(0);
