import fs from 'fs';
const wasmPath = process.argv[2];
const b = fs.readFileSync(wasmPath);
let memory, exports;
const view = () => new DataView(memory.buffer);
const u8 = () => new Uint8Array(memory.buffer);
const p32 = (x) => Number((typeof x === 'bigint' ? x : BigInt(x)) & 0xffffffffn);
const box = (v) => { const p = p32(exports.nova_bytes_alloc(8n)); view().setBigInt64(p, BigInt.asIntN(64, v), true); return BigInt(p); };
const env = new Proxy({
  nova_valopt_box: box,
  nova_valopt_unbox: (bx) => { const p = p32(bx); return p ? view().getBigInt64(p, true) : 0n; },
}, { get(t, k) { return t[k] ?? (() => 0n); } });
const m = await WebAssembly.instantiate(b, { env });
exports = m.instance.exports; memory = exports.memory;
const maxPages = memory.buffer.byteLength / 65536;
// warm up
exports.runBench(1000n);
for (const N of [5000, 20000, 50000, 100000]) {
  // fresh instance each run so the bump allocator resets
  const mm = await WebAssembly.instantiate(b, { env });
  exports = mm.instance.exports; memory = exports.memory;
  let ok = true, chk = 0n, secs = 0;
  try {
    const t0 = process.hrtime.bigint();
    chk = exports.runBench(BigInt(N));
    const t1 = process.hrtime.bigint();
    secs = Number(t1 - t0) / 1e9;
  } catch (e) { ok = false; console.log(`  N=${N}: TRAP (${e.message}) — bump allocator ceiling`); continue; }
  const pages = memory.buffer.byteLength / 65536;
  console.log(`  N=${N}: ${secs.toFixed(3)}s  ->  ${Math.round(N/secs).toLocaleString()} req/s   (mem ${Math.round(pages*64/1024)}MB, chk=${chk})`);
}
