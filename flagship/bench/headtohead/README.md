# Head-to-head: Nova vs Go vs Rust vs C#

A same-box, same-load comparison of end-to-end HTTP throughput. Each peer is a minimal
server that answers `GET /` with the **same constant JSON body**
(`{"message":"Hello, World!"}`, `Content-Type: application/json`). This is the
TechEmpower "JSON serialization" shape, minus the serialization: a constant body isolates
the **HTTP stack and framework overhead**, which is what differs between the languages.

Unlike the sibling `compute_core` bench (which measures pure in-process CPU work and is
NOT rps), these ARE real requests over TCP, measured with a load generator.

## The peers (each idiomatic for its ecosystem)

| Dir | Stack | Notes |
|-----|-------|-------|
| `nova/` | `web.App` | The real framework the flagship uses: typed mediator routing, per-request `ValueSource`, trait dispatch. |
| `go/` | `net/http` | The standard library server. |
| `rust/` | `axum` + `tokio` | The idiomatic async web stack. Release build: LTO, 1 codegen unit, panic=abort. |
| `csharp/` | ASP.NET Core minimal API on Kestrel | `Results.Content` (constant string, no serializer). |

## Running it

```sh
cd lang
DUR=15s CONN=64 ./flagship/bench/headtohead/run.sh
```

The runner detects each toolchain, builds it in release, warms up, then loads with `oha`
for `DUR` at `CONN` keep-alive connections. Missing toolchains or failed builds (for
example, Rust with no crates.io access) are skipped, not fatal. `oha` is required.

## Results after the self-hosted reactor (2026-07-29, Apple Silicon, 8 cores, 15s @ 64 connections)

With the async runtime moved off Boost.Asio onto the Nova reactor (see
`../../../docs/design/cpp-runtime-retirement-plan.md`, M0 to M4). Two things changed: `web.App`
now serves on the reactor, and there is a raw-reactor path that runs the real request pipeline
without the framework abstraction.

| Stack | Requests/sec | Success | Note |
|-------|-------------:|--------:|------|
| **Nova raw reactor + flagship pipeline** (one core) | **164,196** | 100% | zero-copy parse + serde bind + validate + render, no `web.App` |
| Rust (axum) | 134,755 | 100% | 8 cores |
| C# (ASP.NET minimal API on Kestrel) | 124,554 | 100% | 8 cores |
| Go (net/http) | 121,743 | 100% | 8 cores |
| **Nova (`web.App`, reactor)** | **69,404** | 100% | the framework, now on the reactor |
| Nova (`web.App`, Asio — retired) | 55,409 | 100% | the previous baseline |

Two readings, both true:

1. **The runtime is in the top tier.** The raw reactor running the actual flagship pipeline
   (zero-copy parse, bind, validation, render) does **164k rps on ONE core**, ahead of Go, C#, and
   Rust's eight-core numbers. This is the point of the self-hosted-runtime work, now confirmed on a
   Boost-free runtime.
2. **`web.App` gained 25 percent for free** by moving off Asio onto the reactor (55,409 to 69,404 rps,
   no framework change), but the framework abstraction (mediator dispatch, DI/`ValueSource`, routing,
   per-request allocation) still costs the difference between 164k and 69k. That gap is now clearly
   framework engineering (zero-copy, zero-allocation on the App hot path), not the runtime and not
   codegen.

Reactor server variants measured the same run (single core unless noted, fixed JSON unless noted):
`coro` (raw reactor coroutine handler) 185,404; `flagship` (raw reactor, real pipeline) 164,196;
`mc` (multi-core, fixed JSON) 154,990; `appmc` (`web.App` multi-core) 69,404. Note `mc` is LOWER than
single-core `coro`: this box is CPU-contended (the `oha` load generator shares the 8 cores with the
server), so the multi-core figures are pinned by the load generator, not the server. A separate
load-gen machine would show higher multi-core throughput; these are conservative same-box numbers.

### Results before the reactor (optimization pass 1)

| Language (stack) | Requests/sec | Nova as fraction |
|------------------|-------------:|-----------------:|
| Rust (axum) | 134,755 | 0.41x |
| C# (ASP.NET minimal API) | 124,554 | 0.44x |
| Go (net/http) | 121,743 | 0.46x |
| **Nova (web.App, Asio)** | **55,409** | 1.00x |

Nova was roughly 2.2x to 2.4x behind the tuned frameworks on the Asio `web.App`, down from 2.5x to
2.9x after pass 1.

### Optimization pass 1 (measured, +14 percent for Nova)

Guided by the profile in `../PROFILE.md`, two low-risk changes:

1. **Runtime: removed a per-allocation guard.** The ARC audit hooks gated on a
   function-local `static` (`audit_enabled()` / `dump_enabled()`), which compiles to a
   thread-safe-static guard check on every alloc and free and also blocks inlining. Changed
   to a load-once global, so the disabled path folds away and the hooks inline. (The audit
   feature still works when `NOVA_ARC_AUDIT` is set.)
2. **Framework: less eager per-request allocation.** `Request.fromString` built three
   `Map<string,string>` hash maps (query, headers, cookies) at capacity 16 on every
   request, even when unused. Query and cookies (usually empty) now start at capacity 1 to
   4, headers at 8; the maps still auto-resize, so behaviour is unchanged.

Nova went from 48,737 to 55,409 rps at c=64 (reproduced twice). Native corpus 180/180 and
ASAN 329/329 remained green. This is a first pass; the larger levers (a per-reactor
lockless CoroState, full per-request arena, and syscall batching) are still open, per
`../PROFILE.md`.

### Earlier baseline (before pass 1)

| Rust | Go | C# | Nova |
|-----:|---:|---:|-----:|
| 143,120 | 121,954 | 120,107 | 48,737 |

## Honest reading

Nova serves this workload at roughly **one third** of the tuned frameworks: about 2.5x
behind Go and C#, and about 2.9x behind Rust. That is the real end-to-end story today, and
it is worth stating plainly rather than leaning on the flattering compute-core number.

Two things to keep separate:

1. **This is not a codegen gap.** Nova compiles through LLVM, the same backend as Rust and
   Clang, and the `compute_core` bench shows the per-request CPU work is already in the
   native tier (about 1.95 microseconds for parse plus render). The throughput gap is in
   everything around that: the socket and HTTP machinery, the coroutine scheduling, and
   the per-request allocation traffic that ARC has to retain and release.

2. **Framework versus framework, and the frameworks are not equal in maturity.** Go's
   `net/http`, Rust's `axum`, and Kestrel have each had years of profiling and zero-copy,
   zero-allocation tuning on the hot path. Nova's `web.App` is young, and it does real
   per-request work here (typed mediator dispatch, a `ValueSource`, trait-object dispatch)
   that a bare `net/http` handler does not. Part of the gap is the HTTP and I/O stack; part
   is the framework doing more per request.

So the placement is: **Nova's language and codegen belong in the Rust/Go/C# tier, but its
web stack does not yet deliver that tier's throughput.** Closing the gap is engineering on
the runtime and framework hot path (zero-copy request parsing, fewer per-request
allocations, cheaper dispatch), not a change of compiler or memory model. The headroom is
real and identifiable, which is the useful outcome of measuring instead of estimating.

## Reconciling with the earlier "~108k rps" figure

An earlier note recorded the Nova web framework at ~108k rps (2.25x a same-machine Zig
baseline). That is **not** the same measurement as the 48.7k here, and the difference is
methodology, not a regression:

- **That number was the cached, pipelined path.** The plan describes it as "keep-alive ->
  response cache -> cache-before-parse -> zero-copy framing" with HTTP pipelining. It
  serves a memoized response and batches many requests per network round-trip.
- **This head-to-head is non-pipelined, uncached, one request per round-trip** (`oha`,
  which does not pipeline), running the full framework path (mediator dispatch, a
  `ValueSource`, `json()` render) on every request. That is the realistic
  "independent client requests per second" number.

Measured on this box to confirm:

| Path | rps |
|------|----:|
| `oha`, no pipelining, no cache (the head-to-head) | ~48.7k |
| `oha`, cache enabled | ~51k (cache barely helps: +6%) |
| pipelined client, cache on, depth 64, 128 conns | ~84.5k |

So enabling the cache alone does almost nothing; **pipelining is the lever** that lifts the
number toward the earlier figure (the remaining gap to 108k is machine and pipeline depth).
Crucially, the non-pipelined ~48.7k here matches the post-share-nothing orchestrator perf
test (~48.9k direct), so the share-nothing / per-socket-strand work did **not** regress the
per-request path. The 108k and the 48.7k simply measure different things: a best-case
pipelined-throughput ceiling versus realistic per-request throughput.

## Caveats

- One machine, one load tool (`oha`), one connection count, keep-alive. Not a TechEmpower
  submission. Absolute numbers move with hardware, connection count, and payload.
- None of the peers is tuned; each is the straightforward minimal server. That is fair, but
  it means the ceiling for every language here is higher than shown.
- Nova was built with `--release` (`-O3`); Go with `go build`; Rust with
  `cargo build --release` (LTO); C# with `dotnet publish -c Release`.
