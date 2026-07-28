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

## Result (2026-07-28, Apple Silicon, 8 cores; the server used ONE)

| Server | Cores | Requests/sec |
|--------|------:|-------------:|
| **Nova reactor (this)** | **1** | **186,549** |
| Rust axum | 8 | 134,755 |
| C# Kestrel (minimal API) | 8 | 124,554 |
| Go net/http | 8 | 121,743 |
| Nova web.App | 8 | 55,409 |

100 percent success, 0.34 ms average latency.

**A single Nova reactor on one core out-throughputs every tuned framework's eight-core
number.** Per core the gap is larger still: about 27 times Nova's own `web.App`, and roughly
11 to 12 times Go, Rust, and C#. This is the plan's central thesis made concrete: the ceiling
was the runtime, not the compiler. The same LLVM-compiled Nova code that served 55k rps through
Asio and the framework serves 186k on one core through a purpose-built loop with pooled buffers.

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
