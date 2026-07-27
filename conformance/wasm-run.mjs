// Run a nova-compiled wasm module under Node and report whether its @test
// functions pass. Turns the --wasm gate from "compiles+links" into "executes".
//
// nova wasm modules delegate a small set of runtime functions to host imports
// (env.*). This harness implements them against the module's own memory +
// exported allocator (nova_bytes_alloc writes the 8-byte header {refcount@0,
// length@4} and returns base+8; a nova string is that byte pointer, length at
// [ptr-4]). Decimal128 is stubbed — those cases fail here but still link.
//
// Usage:  node wasm-run.mjs <module.wasm>
//   exit 0 = all @test functions ran with no failure/trap; non-zero otherwise.
import { readFileSync } from 'node:fs';
import crypto from 'node:crypto';

const path = process.argv[2];
if (!path) { console.error('usage: wasm-run.mjs <module.wasm>'); process.exit(2); }
const wasmBytes = readFileSync(path);

let memory, exports;
let failed = false, failMsg = '';

const u8 = () => new Uint8Array(memory.buffer);
const view = () => new DataView(memory.buffer);

// wasm32 ABI: a pointer is 32-bit, but nova's universal value handle is i64 (it must hold an f64).
// A pointer therefore travels in the LOW 32 bits of that i64; the high bits are don't-care (inside
// wasm, `inttoptr i64->ptr` truncates to i32, so memory access is correct even when they are dirty —
// e.g. a re-entrant alloc leaves stack garbage there). But a HOST import receives the full i64, so it
// MUST mask to 32 bits before using it as a linear-memory offset. This is the wasm32 pointer ABI, not
// a workaround: every offset above is < 4GB, so the low 32 bits are the whole address.
const ptr32 = (x) => Number((typeof x === 'bigint' ? x : BigInt(x)) & 0xffffffffn);

// Read a nova string (byte ptr; length at [ptr-4]).
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
// Allocate a nova string via the module allocator, return its byte ptr (BigInt).
function makeStr(s) {
  const b = new TextEncoder().encode(s);
  const ptr = ptr32(exports.nova_bytes_alloc(BigInt(b.length)));
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
// i64 values are BigInts. CAS returns a *bool* (1 if swapped, 0 if not) — nova's
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

const env = {
  log: () => {},                       // stdout suppressed for the gate
  nova_test_fail: (p) => { failed = true; failMsg = readStr(p); },
  nova_optional_deref_fail: (p) => { failed = true; failMsg = 'optional-deref: ' + readStr(p); },
  nova_panic: (p) => { failed = true; failMsg = 'panic: ' + readStr(p); },

  // Value-optional boxing (fixes the value-0-reads-as-undefined bug): a box is a plain 8-byte ARC
  // cell holding one i64 word; null/0 = undefined. Mirror alloc.cpp's nova_valopt_box/unbox exactly,
  // allocating in the module's own linear memory via its exported allocator.
  nova_valopt_box: (value) => {
    const ptr = ptr32(exports.nova_bytes_alloc(8n));
    if (ptr === 0) return 0n;
    view().setBigInt64(ptr, BigInt.asIntN(64, value), true);   // `value` is the boxed word — NOT a ptr, no mask
    return BigInt(ptr);
  },
  nova_valopt_unbox: (box) => {
    const p = ptr32(box);
    if (p === 0) return 0n;
    return view().getBigInt64(p, true);
  },

  nova_i64_to_string: (n) => makeStr(BigInt.asIntN(64, n).toString()),
  // f64_to_string receives the f64 DIRECTLY (a JS Number), not i64 bits. nova
  // prints 3.0 as "3", 2.5 as "2.5" — the shortest round-trip repr, == String(f).
  nova_f64_to_string: (f) => makeStr(String(f)),
  nova_bool_to_string: (b) => makeStr(Number(b) ? 'true' : 'false'),

  nova_getenv: (p) => makeStr(process.env[readStr(p)] ?? ''),
  nova_setenv: () => {},
  nova_arg_count: () => 0n,
  nova_arg_at: () => makeStr(''),

  nova_sha256: (p) => makeStr(crypto.createHash('sha256').update(readStr(p)).digest('hex')),
  nova_sha512: (p) => makeStr(crypto.createHash('sha512').update(readStr(p)).digest('hex')),
  nova_hmac_sha256: (k, m) => makeStr(crypto.createHmac('sha256', readStr(k)).update(readStr(m)).digest('hex')),
  nova_random_hex: (n) => makeStr(crypto.randomBytes(Number(n)).toString('hex')),

  // Decimal128 is not reimplemented in JS; these cases fail here but still link.
  nova_decimal_from_string: () => 0n,
  nova_decimal_to_string: () => makeStr('<decimal-unsupported>'),
  nova_decimal_add: () => 0n, nova_decimal_sub: () => 0n, nova_decimal_mul: () => 0n,
  nova_decimal_div: () => 0n, nova_decimal_mod: () => 0n, nova_decimal_cmp: () => 0n,

  nova_atomic_load_i32: atomicRW.load_i32, nova_atomic_load_i64: atomicRW.load_i64, nova_atomic_load_bool: atomicRW.load_bool,
  nova_atomic_store_i32: atomicRW.store_i32, nova_atomic_store_i64: atomicRW.store_i64, nova_atomic_store_bool: atomicRW.store_bool,
  nova_atomic_add_i32: atomicRW.add_i32, nova_atomic_add_i64: atomicRW.add_i64, nova_atomic_sub_i32: atomicRW.sub_i32,
  nova_atomic_cas_i32: atomicRW.cas_i32, nova_atomic_cas_i64: atomicRW.cas_i64, nova_atomic_cas_bool: atomicRW.cas_bool,
};

const mod = await WebAssembly.instantiate(wasmBytes, { env }).catch((e) => {
  console.error('instantiate failed:', e.message); process.exit(1);
});
exports = mod.instance.exports;
memory = exports.memory;

// nova @test functions: exported, no params, name contains "test".
const tests = Object.keys(exports).filter(
  (k) => typeof exports[k] === 'function' && exports[k].length === 0 && /(^|_)test/i.test(k),
);
if (tests.length === 0) { console.error('no @test exports found'); process.exit(1); }

let failName = '';
for (const name of tests) {
  try { exports[name](); }
  catch (e) { failed = true; failName = name; failMsg = `trap: ${e.message}`; break; }
  if (failed) { failName = name; break; }
}
if (failed) { console.error(`FAIL in ${failName}: ${failMsg}`); process.exit(1); }
console.error(`ok: ${tests.length} @test fn(s)`);
process.exit(0);
