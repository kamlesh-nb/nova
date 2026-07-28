# The Nova-owned event loop, load-tested

`server.nova` is a minimal HTTP/1.1 server built directly on the Nova event loop
(`net/reactor` over kqueue), with **no Asio and no web.App framework**. It answers every
request with the same constant JSON as the head-to-head peers, so `oha` can drive it and
the number is directly comparable. This is the gap-8 measurement of
`../../../../docs/design/self-hosted-runtime.md`: how fast is the Nova loop itself.

## Running it

```sh
cd lang
DUR=15s CONN=64 ./flagship/bench/headtohead/nova-reactor/run.sh
```

## Result (2026-07-28, Apple Silicon, 8 cores; the Nova servers used ONE)

There are two Nova reactor servers here. `server.nova` uses a flat callback loop.
`server_coro.nova` handles each connection with a real Nova `async fn` coroutine driven
by the loop (`coroStart` / `currentCoro` / `coroSuspend` / `nova_reactor_resume`), which is
the ergonomic form a real application would use.

| Server | Cores | Requests/sec |
|--------|------:|-------------:|
| **Nova reactor, callback** (`server.nova`) | **1** | **186,549** |
| **Nova reactor, coroutine** (`server_coro.nova`) | **1** | **168,529** |
| Rust axum | 8 | 134,755 |
| C# Kestrel (minimal API) | 8 | 124,554 |
| Go net/http | 8 | 121,743 |
| Nova web.App | 8 | 55,409 |

Both Nova servers: 100 percent success, about 0.34 to 0.38 ms average latency.

**The async layer costs about 10 percent** (168.5k versus 186.5k): per request the coroutine
suspends, the reactor resumes and reaps, and the fd is re-registered, where the callback loop
does none of that. That is a small, reasonable price for real `async`/`await` in the handler,
and the coroutine server still out-throughputs every tuned framework's eight-core number on a
single core. `run.sh` measures the callback server; set `SERVER=coro` to measure the coroutine
one.

**A single Nova reactor on one core out-throughputs every tuned framework's eight-core
number.** Per core the gap is larger still: about 27 times Nova's own `web.App`, and roughly
11 to 12 times Go, Rust, and C#. This is the plan's central thesis made concrete: the ceiling
was the runtime, not the compiler. The same LLVM-compiled Nova code that served 55k rps through
Asio and the framework serves 186k on one core through a purpose-built loop with pooled buffers.

## Multi-core (`server_mc.nova`)

`server_mc.nova` runs `NOVA_REACTORS` share-nothing threads, each with its own reactor and its
own `SO_REUSEPORT` listener (the kernel spreads connections), its own slab pool, and its own
coroutines. Run it with `SERVER=mc NOVA_REACTORS=8 ./run.sh` (or set `NOVA_REACTORS` when
launching `server_mc` directly).

The multi-core scaling **cannot be measured on a single machine**, and the data says so clearly:

- The sweep plateaus at about 185k rps whether 2, 4, or 8 reactors are used (1 reactor gave
  155k, so 1 to 2 did help), and 8 reactors slightly *drops* from core contention.
- Driving 8 reactors with two parallel `oha` instances summed to 164k, which is *less* than one
  `oha` instance's 185k, while the server used only **69.6 percent of one core**.

So the server is mostly idle and has large unused headroom; the load generator, co-located on the
same eight cores and competing for them, is the bottleneck, along with loopback networking. The
single-core numbers already saturate the local client. A real multi-core throughput figure needs a
**separate load-generation machine** (or a real network with dedicated clients), which this
environment does not have.

What *is* verified here is that the multi-core path is **correct and race-free**: four concurrent
reactors, each running coroutines over a slab pool and the shared allocator, are clean under
ThreadSanitizer (`conformance/cases/195`, in the `--tsan` gate). The share-nothing design and the
lockless per-reactor coroutine drive hold up under TSan.

## Honest caveats

This is a first, deliberately narrow measurement, and the number must be read with its
limits, not oversold:

1. **Fixed response, no request parsing yet.** The server reads the request and replies with a
   constant; it does not parse the HTTP request. The head-to-head peers do route the request
   through their frameworks. When the zero-copy picohttpparser-style parser lands (phase 5),
   parsing cost is added back, though it is designed to be small (a `memchr` scan and a fixed
   header array, no per-request allocation).
2. **Single reactor, one core.** The peers ran on eight cores. That the Nova loop beats their
   eight-core totals on one core is the headline, but a same-core comparison would pin the peers
   to one core too. Share-nothing multi-core (SO_REUSEPORT across N reactor threads) is the next
   step and should scale the Nova number further.
3. **No TLS, keep-alive only** (oha default). TLS reuses the existing wolfSSL memory-BIO seam.

So the honest claim is not "Nova is 3x Rust." It is: **the Nova-owned event loop removes the
runtime ceiling that the profile identified, by a wide margin, and the direction is validated.**
The next measurements (with parsing, and multi-core) will give the real end-to-end figure.
