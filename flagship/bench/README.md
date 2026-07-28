# Flagship benchmarks

## What is measured, and why it is scoped this way

The flagship is a **web server**. It stands on the async socket and TLS runtime, which
are native only. It therefore **cannot compile to WebAssembly** at all: the target
capability gate rejects it with clean, located errors (async/await, sockets, TLS have no
coroutine runtime on wasm). There is consequently no "flagship web server running in
wasm" to load test.

What a wasm deployment does run is the **per request compute core**: the host performs
the I/O and calls into the module with the request body. `compute_core.nova` is exactly
the `CreateProduct` handler with the `async` and the database removed, that is, the pure
work of one request:

```
source.fromJson(body)  ->  bind the command  ->  validate  ->  render the JSON response
```

The same source compiles to native and to wasm, so the two may be compared honestly.

## Running it

```sh
cd lang

# native (main() runs 2,000,000 iterations; time the whole process)
nova flagship/bench/compute_core.nova -o /tmp/flagbench
/usr/bin/time -p /tmp/flagbench

# wasm (a Node harness times runBench() across a range of iteration counts)
nova flagship/bench/compute_core.nova --wasm -o /tmp/flagbench.wasm
node flagship/bench/wasm-bench.mjs /tmp/flagbench.wasm
```

## Results (2026-07-28, Apple Silicon)

| Target | Throughput | Per request | Notes |
|--------|-----------|-------------|-------|
| Native | ~513k req/s | ~1.95 us | 2M iterations; ARC frees each request |
| Wasm (Node) | ~690k req/s | ~1.45 us | steady state, 5k to 100k iterations; bump allocator |

Both produce identical results (the checksum is 24 per request and scales exactly with
the iteration count, so the loop is real and not optimised away). Wasm module: ~82 KB;
native binary: ~142 KB.

Wasm edges out native by roughly 1.35 times on this compute core. This is not wasm being
faster in general; it is the allocation model. Wasm uses the pure bump allocator and does
not free, whereas native pays ARC retain, release, and free on every short lived request
string. For a request scoped, torn down per invocation edge deployment that is the right
trade; for a long lived native server, the freeing is what keeps memory bounded. The bump
allocator held about 100k requests within the module's 128 MB before nearing its ceiling.
