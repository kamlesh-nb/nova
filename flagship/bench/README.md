# Flagship benchmarks

## IMPORTANT: this measures the compute core, NOT HTTP throughput

The numbers below are a **pure in-process microbenchmark** of one request's CPU work.
They are **not** end-to-end web-server throughput. There is **no networking** in these
figures: no TCP, no socket read or write, no HTTP parsing off the wire, no connection
accept, no scheduler, no response flush. It is a tight loop calling `handleOne(body)`,
which does only `fromJson -> bind -> validate -> render`.

For the flagship's **real HTTP throughput** (native, over actual TCP), see the
orchestrator perf test in `docs/design/execution-plan.md`: roughly **48.9k rps** direct,
47.6k through the proxy, 10.2k on the per-request DB path. The gap between ~500k here and
~49k there is exactly the I/O, HTTP framing, connection lifecycle, and scheduling cost
that this microbenchmark deliberately excludes. A request spends about 1.95 us computing
and the rest (~18 us at 49k rps) in that machinery, so the compute core is not the
bottleneck.

## What is measured, and why it is scoped this way

The flagship is a **web server**. It stands on the async socket and TLS runtime, which
are native only. It therefore **cannot compile to WebAssembly** at all: the target
capability gate rejects it with clean, located errors (async/await, sockets, TLS have no
coroutine runtime on wasm). There is consequently no "flagship web server running in
wasm" to load test.

What a wasm deployment does run is the **per request compute core**: the host performs
the I/O and calls into the module with the request body. `compute_core.ky` is exactly
the `CreateProduct` handler with the `async` and the database removed, that is, the pure
work of one request:

```
source.fromJson(body)  ->  bind the command  ->  validate  ->  render the JSON response
```

The same source compiles to native and to wasm, so the two may be compared honestly. The
"req/s" in the table below is therefore **compute cores per second**, i.e. `1 / (time per
handleOne call)`, not requests served over a socket.

## Running it

```sh
cd lang

# native (main() runs 2,000,000 iterations; time the whole process)
kyte flagship/bench/compute_core.ky -o /tmp/flagbench
/usr/bin/time -p /tmp/flagbench

# wasm (a Node harness times runBench() across a range of iteration counts)
kyte flagship/bench/compute_core.ky --wasm -o /tmp/flagbench.wasm
node flagship/bench/wasm-bench.mjs /tmp/flagbench.wasm
```

## Results (2026-07-28, Apple Silicon)

| Target | Compute cores/s | Per core | Notes |
|--------|-----------------|----------|-------|
| Native | ~513k /s | ~1.95 us | 2M iterations; ARC frees each request. NOT HTTP rps (that is ~49k) |
| Wasm (Node) | ~690k /s | ~1.45 us | steady state, 5k to 100k iterations; bump allocator |

Both produce identical results (the checksum is 24 per request and scales exactly with
the iteration count, so the loop is real and not optimised away). Wasm module: ~82 KB;
native binary: ~142 KB.

Wasm edges out native by roughly 1.35 times on this compute core. This is not wasm being
faster in general; it is the allocation model. Wasm uses the pure bump allocator and does
not free, whereas native pays ARC retain, release, and free on every short lived request
string. For a request scoped, torn down per invocation edge deployment that is the right
trade; for a long lived native server, the freeing is what keeps memory bounded. The bump
allocator held about 100k requests within the module's 128 MB before nearing its ceiling.
