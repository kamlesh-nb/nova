# A Self-Reliant Nova Runtime: Study First, Then Build

## Decision (2026-07-28)

Stop the piecemeal tuning of the Asio-based runtime. The head-to-head measurements are clear:
Nova serves about 55k rps where Go, C#, and Rust serve 120k to 135k, that is, roughly 2.2x
to 2.4x behind (see `../../flagship/bench/headtohead/`). The profile
(`../../flagship/bench/PROFILE.md`) is equally clear that this is not a codegen problem, the
compute core is already native-tier, but a runtime problem: per-request allocation, refcount
traffic, per-coroutine state churn behind a mutex, and unbatched syscalls. Chasing these one
at a time on top of Boost.Asio is trial and error against a design we did not choose and do
not fully control.

The correct path is to study the best known implementations of the exact things we need, adopt
their proven structure, and build a runtime that Nova owns end to end. Boost.Asio was a
reasonable bootstrap, but it is a general-purpose C++ library, it is a large external
dependency, and its per-coroutine strand model is the source of the cross-thread state we have
been fighting. The language now has a solid compute core and a working FFI. That is exactly the
foundation from which a language should reduce its reliance on external C++ libraries and stand
on its own.

This document is the study and the plan. No code is to be written against it until the
reference model and the architecture below are agreed.

## What is already good and must be preserved

- **The compute core and codegen.** LLVM backend, native-tier per-request CPU cost (about
  1.95 microseconds for parse plus render). This is not the problem and must not be disturbed.
- **LLVM stackless coroutines.** The `async`/`await` mechanism is sound and is the same family
  as Rust futures. We keep the coroutine intrinsics; we change who drives them.
- **FFI (`extern("lib") fn`).** The keystone that makes a Nova-owned syscall layer possible.
- **The wolfSSL memory-BIO TLS seam.** TLS is already pumped by Nova over an in-memory BIO, not
  by Asio. This design already points the right way and is reused unchanged.
- **ARC for application objects.** ARC is correct for user data. What must change is that the
  I/O hot path (buffers, headers) must stop flowing through ARC (see buffers below).

## Reference implementations to study, and what each teaches

| Project | Language | What to take from it |
|---------|----------|----------------------|
| **Seastar** (ScyllaDB) | C++ | The canonical share-nothing thread-per-core reactor. One shard per core, no shared mutable state, explicit message passing across shards, per-core allocator, io_uring backend, `temporary_buffer` for refcounted zero-copy slices. This is the closest match to our target and the primary reference. |
| **glommio** (Datadog) | Rust | Thread-per-core on io_uring, done as a library rather than a framework. Good model for how a thread-per-core reactor exposes `async`/`await` without a work-stealing scheduler. |
| **monoio** (ByteDance) | Rust | io_uring-first thread-per-core, with an epoll fallback, and a completion-based buffer ownership model (buffers are moved into the kernel and returned). The reference for a portable completion or readiness split. |
| **tokio + mio** | Rust | mio is the minimal, portable readiness reactor (epoll, kqueue, IOCP, and now io_uring). The reference for the low-level event source abstraction we must build in Nova. Tokio itself is work-stealing, which we do not want, but its `Bytes`/`BytesMut` are the reference for refcounted, cheaply sliceable buffers. |
| **libuv** (Node.js) | C | The most portable event loop in existence (epoll, kqueue, IOCP, io_uring, event ports). The reference for cross-platform structure, the handle and request lifecycle, and the timer, signal, and async-wakeup integration. |
| **nginx** | C | Worker-per-core share-nothing, its own memory pools (`ngx_pool_t`, allocate-many free-once per request), buffer chains (`ngx_chain_t`), and kernel zero-copy for static content (`sendfile`, `splice`). The reference for per-request arena allocation and zero-copy pass-through. |
| **h2o + picohttpparser** | C | picohttpparser is the fastest HTTP/1 parser, and it is zero-copy: it returns slices into the read buffer and allocates nothing. The reference for our request parser, which today builds three hash maps per request. |
| **hyper + httparse** | Rust | Zero-copy, SIMD-accelerated HTTP/1 parsing, and the buffer and backpressure discipline that makes axum fast. |
| **Kestrel + System.IO.Pipelines** (.NET) | C# | The `Pipe`: a single ring buffer between a producer and a consumer, with backpressure and zero-copy `ReadOnlySequence<byte>` reads, over a pooled slab allocator (`MemoryPool`, `ArrayPool`). Since Nova's `App` framework is deliberately ASP.NET-shaped, Pipelines is the natural model for our buffer and connection I/O layer. |
| **io_uring** (Linux kernel) | - | Submission and completion queues, registered (fixed) buffers, and provided-buffer rings for zero-copy receive. The endgame for Linux I/O; the design must leave room for it as a backend. |

The common thread across every fast server above: **share-nothing per core, a small purpose-built
event loop over the raw kernel interface, pooled and reused buffers, and zero-copy parsing that
slices the read buffer instead of allocating.** None of them is built on a general-purpose async
library layered over the kernel. That is the lesson.

## Target architecture

The shape to build, borrowing directly from Seastar and glommio for the core, Kestrel Pipelines
for buffers, and picohttpparser for parsing:

1. **Share-nothing thread-per-core.** N reactors, one per core, each with its own event loop,
   its own connection set, its own buffer pools, and its own timer wheel. No shared mutable
   state on the hot path. SO_REUSEPORT for accept fan-out (we already do this). Cross-core
   communication, when unavoidable, is an explicit lock-free wakeup (`eventfd` on Linux, a
   self-pipe or `EVFILT_USER` on macOS), never a shared lock. This directly removes the
   cross-thread CoroState problem, because a connection and its coroutine tree live and die on
   one core and are never touched by another.

2. **A Nova-owned event loop over raw syscalls.** A per-core reactor written in Nova, calling
   the kernel through a thin FFI syscall layer:
   - macOS: `kqueue` / `kevent` (readiness).
   - Linux: `io_uring` (completion) as the primary backend, `epoll` (readiness) as the
     portable fallback.
   - The loop owns a per-core, lock-free `fd -> waiting coroutine` map (an array indexed by fd,
     not a hash map behind a mutex), registers interest, waits, and resumes the coroutine whose
     fd became ready or whose operation completed.
   - Timers via `timerfd` (Linux) or `EVFILT_TIMER` (kqueue), integrated into the same wait.

3. **Reusable, refcounted, zero-copy buffers (the Pipelines model).** A per-core slab allocator
   hands out fixed-size buffer blocks that are recycled, never freed per request, and never
   flow through ARC. A connection reads into a ring of these blocks. Parsers and handlers take
   `Bytes`-style slices (offset and length into a block, with a cheap refcount on the block, in
   the manner of tokio `Bytes` and Seastar `temporary_buffer`), so no request data is copied or
   individually allocated. Responses are assembled as a scatter-gather list and written with a
   single `writev`. Static files use `sendfile` or `splice`.

4. **Zero-copy HTTP parsing, and SIMD.** Replace `Request.fromString` (which today splits
   strings and builds three `Map<string,string>` per request) with a picohttpparser-style parser
   that records header name and value as slices into the read buffer and stores them in a small
   fixed array. Header lookup is a short linear scan, which is faster than a hash map for the
   typical five to fifteen headers and allocates nothing. picohttpparser's speed is its **SIMD**
   delimiter scan, and there are two levels of that, the first of which is already available:
   - **Level 1, libc.** `memchr`, `memcmp`, `memcpy`, and `strlen` in the platform libc are
     already hand-tuned NEON on macOS and arm64 and AVX on x86_64. Bound over the existing FFI
     (`os/sys`, done 2026-07-28, `conformance/cases/193`), `memchr` is the SIMD delimiter scan the
     parser needs, and routing `string.indexOf`, `string.eql`, and `string.compare` through
     `memchr` and `memcmp` makes general string handling faster too, with no compiler work.
   - **Level 2, first-class Nova SIMD.** For kernels the libc functions do not cover, Nova would
     gain vector types lowered to LLVM's portable vector IR (which already targets NEON, SSE, and
     AVX). This is a real but separable compiler capability, a track of its own, not a blocker for
     the loop. Recommend level 1 now, and scoping level 2 as a language feature after the loop
     lands.

5. **The coroutine seam stays, the driver changes.** We keep LLVM coroutines. The reactor
   resumes and suspends them directly through the existing raw coroutine intrinsics. Because
   each coroutine is confined to one core, the scheduler state (running, pending, the fd it
   waits on) is single-threaded and needs no mutex and no shared map, which is the lockless
   CoroState we could not safely retrofit onto Asio.

## Design gaps and blockers, honestly enumerated

These are the things that must be resolved or built before the architecture above is reachable.
They are the reason this is a study-and-plan document and not a patch.

1. **FFI expressiveness (the keystone).** A Nova-owned syscall layer needs the FFI to express,
   with exact C ABI layout: structs by pointer and by value (`sockaddr_in`, `kevent`,
   `epoll_event`, `io_uring` SQE and CQE, `iovec`, `timespec`), fixed-size arrays of those
   structs (an `epoll_event[]` or `kevent[]` batch), out-parameters, `errno` access, and a few
   variadic calls (`fcntl`, `open`). We must audit exactly what the current FFI supports and
   close the gaps, with conformance tests, before anything else. This is task one.

2. **Raw memory outside ARC.** The buffer pools must be `mmap`-backed arenas that ARC never
   touches. Nova can already hold 64-bit addresses (`long`) and read and write through them
   (`bytes.read`/`write`), but we need first-class, safe primitives for slab and ring buffers,
   for pointer-sliced `Bytes`, and for a per-request arena (the nginx pool model), none of which
   should incur retain and release.

3. **Non-blocking discipline.** Every fd must be `O_NONBLOCK`, and the loop must correctly
   handle `EAGAIN`, partial reads and writes, and short `writev`. This is straightforward but
   pervasive and must be got right once, in one place.

4. **The readiness versus completion split.** kqueue and epoll are readiness (tell me when I can
   act), io_uring and IOCP are completion (tell me when the act is done). Buffer ownership
   differs: completion models hand the buffer to the kernel and get it back later (see monoio).
   The abstraction must accommodate both without leaking one model into the other. Recommend
   starting with readiness (kqueue on macOS, epoll on Linux) because it is simpler and portable,
   and adding an io_uring completion backend later behind the same interface.

5. **Cross-core wakeup.** Rare but necessary (a timer or a result produced on another core).
   Needs an `eventfd` or self-pipe wakeup and a lock-free SPSC or MPSC queue, not a shared
   mutex. Keep it off the common path entirely.

6. **Cancellation, timeouts, backpressure, graceful shutdown.** These must be designed into the
   loop from the start, not bolted on. Kestrel Pipelines backpressure and libuv handle teardown
   are the references.

7. **Windows.** IOCP is a completion model and a different beast. Recommend deferring Windows
   server support explicitly and keeping the door open through the completion abstraction.

8. **The hot-loop overhead risk of writing the loop in Nova.** This is the honest counter-risk
   to self-hosting. If ARC, bounds checks, or optional-unwrapping creep into the innermost loop,
   Nova-level overhead could eat the win. Mitigation: keep the loop body allocation-free and
   ARC-free by construction (raw arenas and slices), measure the empty-loop and echo-server cost
   very early (phase 4), and be willing to push the tightest inner step behind FFI if Nova-level
   overhead is shown to dominate. Measure before deciding, do not assume either way.

## Phased plan

Each phase ends with a measurement or a conformance gate, so we never fly blind again.

- **Phase 0. Agree the reference model.** Ratify: thread-per-core in the Seastar and glommio
  mould, Pipelines-style pooled buffers, picohttpparser-style zero-copy parse, readiness loop
  first (kqueue and epoll) with io_uring as a later backend. Write the interface contracts.
- **Phase 1. Harden FFI** to the syscall surface in gap 1, with conformance tests. Keystone.
  **DONE (2026-07-28).** Delivered: `nova_ffi_errno`/`nova_ffi_set_errno` runtime helpers (errno
  is now readable after a failing call); `bytes.read_u16`/`write_u16` builtins (16-bit C struct
  fields; the existing `read_i32`/`write_i32` and `read_ptr`/`write_ptr` already cover 32-bit and
  64-bit); and `src/std/os/sys.nova`, a first cut of the POSIX bindings (socket, socketpair, bind,
  listen, accept, connect, setsockopt, fcntl, read, write, close, plus `setNonBlocking`,
  `makeSockaddrIn`, `htons`). Proven end to end and offline by `conformance/cases/187_ffi_syscall
  _surface.nova`: a real kernel socketpair write and read round-trip, errno after a failing
  `close(-1)` (EBADF), and building and reading a `sockaddr_in` in a raw buffer via the typed
  accessors. Native corpus 181/181, ASAN 331/331. **What this establishes:** scalars, pointer and
  out-parameter buffers, errno, and C structs and arrays of structs as raw buffers with typed
  field access (the systems idiom) all compose correctly for the syscall surface. **Deferred as
  not-on-the-syscall-path:** full struct-by-value FFI marshalling and true C variadics (`printf`
  style); fixed-argument-count calls to variadic C functions such as `fcntl` already work.
- **Phase 2. `os/sys` syscall bindings in Nova**: sockets, `accept4`, `epoll`/`kqueue`,
  `read`/`write`/`writev`, `close`, `mmap`, `eventfd`/`timerfd`, non-blocking. Tested against
  the kernel. **Poll mechanism DONE (2026-07-28).** `src/std/os/kqueue.nova` (macOS and BSD
  readiness reactor: `kqueue`, `kevent`, the 32-byte `struct kevent` build-and-read helpers, the
  filter and flag constants, plus `registerOne` and `wait`) is proven end to end on macOS by
  `conformance/cases/188`: register read-interest on a socket, write to its peer, and `kevent`
  reports the correct fd, filter, byte count, and udata token. `src/std/os/epoll.nova` (Linux:
  `epoll_create1`/`epoll_ctl`/`epoll_wait`, `eventfd`, `timerfd_create`/`timerfd_settime`, the
  constants, and the `struct epoll_event` helpers) compiles and links on macOS (its syscalls are
  dropped by globalDCE where uncalled) and its x86_64 layout logic is covered by
  `conformance/cases/189`; the epoll syscall round-trip and the aarch64 layout switch
  (`EPOLL_EVENT_SIZE = 16`, data at offset 8) are to be verified in a Linux pass. Added a
  sign-extending `bytes.read_i16` for signed 16-bit fields (`kevent.filter`). Native corpus
  183/183, ASAN 335/335. **Still open in phase 2:** `accept4`, `writev`, `mmap`, and the Linux
  eventfd and timerfd round-trip verification.
- **Phase 3. Buffer infrastructure in Nova**: slab pool, ring buffer, refcounted `Bytes` slice,
  per-connection arena. Benchmarked in isolation against malloc and against ARC. **Started
  (2026-07-28).** `src/std/io/slab.nova` (`SlabPool`): one backing allocation, fixed-size blocks
  on an intrusive free list, a manual per-block refcount so a block can be shared zero-copy and
  is recycled automatically at zero references, all as plain `long` addresses OUTSIDE ARC (the
  nginx-pool and Kestrel-MemoryPool model, with the tokio-Bytes and Seastar-temporary_buffer
  refcount). `src/std/io/arena.nova` (`Arena`): a bump allocator for per-connection scratch that
  reclaims a whole request's memory with one `reset`, no per-object free (the nginx ngx_pool_t
  model). Proven by `conformance/cases/190` (acquire, distinct blocks, payload read and write,
  the retain and release refcount lifecycle, recycling, exhaustion) and `191` (bump, alignment,
  reset reuse, exhaustion). Native corpus 185/185, ASAN 339/339. **Still open in phase 3:** the
  ring buffer over a chain of slab blocks (the per-connection read buffer), the refcounted `Bytes`
  slice as a first-class value (blocked on a language value-type or stack-struct feature, since a
  Nova struct is itself an ARC heap object; for now a slice is passed as an explicit base, offset,
  length triple with the block refcount for sharing), and an isolation benchmark versus malloc and
  ARC.
- **Phase 4. The per-core event loop in Nova**, driving coroutines directly. First milestone: a
  raw echo server. Measure the empty-loop and echo cost immediately (gap 8). Compare to an Asio
  echo baseline. **Milestone 1 STARTED (2026-07-28).** `src/std/net/reactor.nova` (`Reactor`): a
  per-core kqueue event loop that owns its `kqueue` fd, an event buffer, and a read-buffer
  `SlabPool`, with `addRead`/`delRead`, `poll`, and `readyFd`/`readyToken`/`readyBytes`/`readyEof`
  accessors; the udata token on each event is where a connection identity (later a coroutine
  handle) rides, so the loop finds the right connection in O(1) with no map and no lock. Proven by
  `conformance/cases/192`: a request served entirely through the Nova loop with no Asio, a
  connected fd pair standing in for an accepted connection, register read-interest, block in
  kqueue, wake on readiness, read into a recycled slab block, echo back, client receives it. Native
  corpus 187/187, ASAN clean. **Milestone 2 DONE (2026-07-28): the load-tested server, and the
  gap-8 measurement is emphatic.** `flagship/bench/headtohead/nova-reactor/server.nova` is a minimal
  HTTP/1.1 server on the reactor (listener, `accept`, non-blocking, keep-alive, a fixed constant-JSON
  response, a `SlabPool` read buffer), no Asio and no web.App. Driven by `oha` at the same settings
  as the head-to-head, a **single reactor on one core sustains about 186,500 req/s at 100 percent
  success and 0.34 ms average**, which beats every tuned framework's eight-core number in the
  head-to-head (Rust axum 134.8k, C# Kestrel 124.6k, Go net/http 121.7k) and is about 27 times
  Nova's own eight-core web.App (55.4k) per core. This is the plan's thesis made concrete: the
  ceiling was the runtime, not the compiler. Caveats recorded in the bench README: the server does
  not yet parse the request (fixed response), it is single-core (the peers ran eight), and there is
  no TLS. A real finding en route: `fcntl` is variadic and a non-variadic FFI declaration mispasses
  its third argument on arm64 (varargs go on the stack), which silently left the listener blocking;
  fixed with a tiny runtime shim `nova_set_nonblock` (the general lesson for variadic syscalls until
  first-class variadic FFI lands). **Milestone 3 DONE (2026-07-28): LLVM coroutines driven directly
  by the reactor, no Asio.** A normal `async fn` handler registers its own coroutine handle with the
  reactor and yields; the reactor resumes it on readiness. Three ADDITIVE primitives (they do not
  touch any existing `await` path, so the whole async stack is unaffected): `coroStart(asyncCall)`
  creates a coroutine WITHOUT scheduling it on Asio (spawn is exactly `awaitedCallHandle` plus a
  separable `nova_sched_schedule`, so omitting the schedule yields an Asio-free handle) and kicks it
  once past the async initial-suspend so its body registers; `currentCoro()` returns the running
  coroutine's handle to use as the reactor token; `coroSuspend()` yields to the reactor (reusing the
  existing `buildAwaitSuspend`). The runtime `nova_reactor_resume(h)` resumes via `raw_coro_resume`
  and reaps the frame when the coroutine finishes; single reactor thread, so no CoroState and no
  mutex, which is the lockless per-reactor drive we could not safely retrofit onto Asio. Proven by
  `conformance/cases/194` (a coroutine echo over a socketpair), clean under `--tsan`. Native 188/188,
  ASAN 345/345, TSan subset 193/193, case 194 zero races. **Wired into the server and re-measured
  (2026-07-28):** `flagship/bench/headtohead/nova-reactor/server_coro.nova` handles each connection
  with a real `async fn` coroutine (await-style suspension) instead of the callback loop. Single
  reactor, one core: about **168,500 req/s** at 100 percent success, versus **186,500** for the
  callback server. **The async layer costs about 10 percent**, a small and reasonable price for real
  `async`/`await` in the handler, and the coroutine server still beats every tuned framework's
  eight-core head-to-head number on one core. **Share-nothing multi-core DONE (2026-07-28), verified
  race-free.** `nova_run_reactors(n, worker)` spawns n OS threads (via the FFI box convention, exposed
  as the typed `reactor.runReactors`), each running an independent reactor with its own
  `SO_REUSEPORT` listener, its own slab pool, and its own coroutines, with no shared state;
  `server_mc.nova` is the multi-core server. The multi-core code is CLEAN under ThreadSanitizer
  (`conformance/cases/195`: four concurrent reactors running coroutines over a slab pool and the
  shared allocator, in the `--tsan` gate); the share-nothing design and the lockless per-reactor
  coroutine drive hold up. The multi-core THROUGHPUT, however, cannot be measured on a single
  machine: the sweep plateaus at about 185k rps regardless of reactor count, two `oha` instances
  against eight reactors summed to less than one instance, and the server used only about 70 percent
  of one core, so the co-located load generator and loopback, not the server, are the bottleneck. A
  real figure needs a separate load-generation machine. **Still open in phase 4:** the Linux epoll
  backend behind the same `Reactor` shape.
- **Phase 5. Zero-copy HTTP/1 parser** (picohttpparser model), replacing the per-request maps.
  **DONE (2026-07-28).** `src/std/web/httpparser.nova` (`HttpRequest`): parses a request in place,
  recording the method, path, and each header as an (offset, length) slice into the read buffer,
  never copied and never individually allocated; delimiter scanning uses the SIMD-backed libc
  `memchr`; matching is by byte comparison (`methodEq`, `pathEq`, case-insensitive `header`), so
  the hot path materialises no Nova string. The struct is created once per connection and reused,
  so a whole request costs no allocation. Proven correct by `conformance/cases/196` (complete and
  incomplete detection, case-insensitive header lookup, path matching). `server_parse.nova` wires
  it into the reactor server and routes on the parsed method. Cost: on the network benchmark the
  parse is below the noise floor (parse and no-parse both land in the same client-bound 150k to
  185k band); microbenchmarked in isolation, `parse()` runs **5,000,000 four-header requests in
  0.33 s of CPU, about 66 ns per request**, roughly one percent of the per-request budget, which is
  why it does not move the throughput. This retires the old `Request.fromString` path that built
  three `Map<string,string>` per request.
- **Phase 6. Port the `App` server** onto the Nova reactor. Re-run the head-to-head. Target is
  parity within about 1.2x to 1.5x of Go and Kestrel, which the profile says is reachable.
  **Started (2026-07-28), and it surfaced the one real blocker.** The flagship's actual per-request
  business logic (the `CreateProduct` slice: zero-copy parse, serde-bind the JSON body, validate,
  render) runs on the reactor as a coroutine per connection
  (`flagship/bench/headtohead/nova-reactor/server_flagship.nova`), at about **146k req/s on one
  core** at 100 percent success, with the real bind and validation observable (an invalid body is
  rejected). But the FULL async `App` framework cannot yet run on the reactor, and this was
  verified rather than assumed: the `App` mediator dispatch is built on **nested `async`/`await`**,
  and Nova's nested `await` and `spawn` route through the Asio scheduler (`nova_sched_schedule`),
  which the reactor bypasses, so a reactor-driven coroutine that performs a nested `await`
  DEADLOCKS (a minimal test hangs). **The remaining piece is therefore the async scheduler
  migration:** replace `nova_sched_schedule`'s Asio post with a per-reactor run queue (set a
  thread-local reactor mode; the reactor loop drains the queue and reproduces the waiter and
  held-argument completion logic), so nested awaits and spawns are driven by the reactor. This is
  the largest and most delicate remaining item because it touches the coroutine ABI the whole async
  stack depends on, and it must be done under the `--tsan` gate. Once it lands, the whole async
  `App` (mediator, DI, middleware, and eventually the reactor-native DB drivers) runs on the loop.
- **Phase 7. io_uring completion backend** on Linux, and `sendfile`/`splice` for static content.
- **Retirement.** Keep Asio as a fallback until the Nova loop meets or beats it on the
  head-to-head, then remove the Boost dependency and delete the Asio path.

## Success criteria

- Head-to-head GET throughput within about 1.2x to 1.5x of Go net/http and Kestrel on the same
  box, not 2.5x behind.
- The Boost.Asio dependency removed from the default native build.
- No shared mutable state and no mutex on the request hot path, verified under a ThreadSanitizer
  build (which we must add regardless, and which is the prerequisite for trusting any concurrent
  runtime code).
- The existing corpus and ASAN gates stay green throughout; the runtime rewrite does not regress
  language or memory-safety behaviour.

## Open decisions to settle in Phase 0

1. **Loop in Nova versus a thin purpose-built C++ reactor.** The user's direction is to reduce
   external reliance and to implement the loop in Nova over FFI. The counter-risk is hot-loop
   overhead (gap 8). Recommendation: commit to the Nova loop, but validate the overhead at
   phase 4 with a hard measurement, and keep a thin-FFI escape hatch for the single tightest
   step if the data demands it. Decide on data, not preference.
2. **Readiness first or io_uring first.** Recommendation: readiness first for portability and
   simplicity (macOS development uses kqueue anyway), io_uring as a phase-7 backend.
3. **Add the ThreadSanitizer build now. DONE (2026-07-28).** `NOVA_TSAN=1 zig build` builds
   `libnova_runtime_tsan.a` (the C++ runtime instrumented with `-fsanitize=thread`), mirroring the
   ASAN build; `nova test` links it and `-fsanitize=thread` when `NOVA_TSAN=1`; and
   `conformance/run.sh --tsan` runs the concurrency subset (`10_async_go`, `11_channels`,
   `102_future_first_class`, `103_async_when_all`, `113_async_stream_io`) under `NOVA_THREADS=4`,
   turning any data race in the multi-reactor runtime into a located report. All five pass clean
   today, which also establishes that the existing async runtime's `when_all`, channel, future, and
   async-socket paths are race-free under TSan at four threads. Extend `TSAN_CASES` as the event
   loop lands. This is the gate the event-loop and lockless-CoroState work will be verified against.
