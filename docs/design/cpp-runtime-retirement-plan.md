# Retiring the C++ Runtime: A Structured Migration Plan

## Tracker

Statuses: DONE, WIP (in progress or partially landed), TODO. Update this table as the single source of
truth for progress; the phase details are below.

| Phase | What it retires or builds | Prereq | Status | Notes |
|-------|---------------------------|--------|--------|-------|
| Foundation | Event loop, buffers, HTTP parser, poll and socket layer, multi-core | none | DONE | `self-hosted-runtime.md` phases 1 to 5; race-free under `--tsan` |
| M0 | Tooling: file-based runtime trace, symbol audit | none | DONE | `NOVA_TRACE=<file>` trace (surfaces reliably), `tools/runtime-symbol-audit.sh` (221 exported / 203 referenced) |
| M1 | Async scheduler migration (per-reactor run queue) | M0 | DONE | Nested/multi-level `await` and `spawn`+`await` drain on the reactor (corpus 199, trace-proven); Asio-backed awaits on the reactor now fail fast via `nova_reactor_io_violation` instead of silently orphaning (their migration is M2) |
| M2 | Async socket I/O on the reactor | M1 | DONE | `net/reactorio` = reactor-native recv/send/connect/accept/resolve in Nova over `os/sys`; a thread-local current reactor; `asyncio.AsyncStream` dual-mode; `web/app.serveReactorConn`/`runReactor` run a whole request on the reactor. Corpus 200 to 204 (socketpair, loopback connect/accept, the AsyncStream seam, connect-by-name, and a full App request), all TSan clean. Remaining before flagship-DB-on-reactor (M3): multi-core reactor server (the `runReactors` worker cannot yet carry the App) and async DNS |
| M3 | Database drivers on the reactor | M2 | DONE (mock) | The drivers connect via `asyncConnect` and do I/O through `AsyncStream`, both reactor-native from M2, so they run on the reactor with no driver change. Corpus 205: an App handler makes a per-request DB call (mock DB on the same reactor) end to end, no Asio, closing the PH6 deadlock. A live-driver run needs a reachable database; the driver code is unchanged |
| M4 | Retire Boost.Asio | M1 to M3 | WIP | `App.run` is reactor-only; timers/read-deadlines/inbound-TLS reactor-native; the keystone `cross-reactor wakeup` (EVFILT_USER + thread-safe inbox, corpus 210, TSan clean cross-thread) is in. Remaining: rewrite `nova_run_root` (the multi-threaded async @test/standalone driver) on the reactor using cross-reactor scheduling, retire the 5 Asio-primitive corpus tests (superseded by 200 to 209), then delete the Asio code and drop Boost |
| M5 | File and directory I/O in Nova | M4 (soft) | TODO | `nova_file_*`, `nova_dir_*` over `os/sys` |
| M6 | Process and primitive shims | none | TODO | `core.cpp` shims to `os/sys`; tiny atomics FFI stays |
| M7 | Channels and actors in Nova | M1, M6 | TODO | Over the reactor; verify under `--tsan` |
| M8 | Allocator backing in Nova | none | TODO | `mmap` arena under `nova_bytes_alloc`; ABI-CORE unchanged |
| M9 | TLS 1.2 and 1.3 protocol in Nova | M2 | TODO | Protocol only; reference the Zig `std.crypto.tls`; crypto primitives stay vetted |

## Purpose

This is the plan of record for replacing the C++ runtime (`src/runtime/`) with Nova code over a thin
foreign-function surface, so that Nova stands on itself. It exists because the runtime work must stop
being piecemeal: a scheduler migration attempt that got single-level async working but hung on
multi-level (see `self-hosted-runtime.md`, phase 6) showed that this rewrite needs an agreed order,
firm rules, and a gate at every step, not opportunistic edits to a subsystem the whole language
depends on.

The companion document `self-hosted-runtime.md` is the design of the new Nova-native I/O stack (the
event loop, buffers, parser, poll layer) and the record of what is already built. This document is
narrower and more operational: it inventories what is in C++ today, classifies every piece by whether
it leaves or stays, and sequences the removal.

## The inventory (`src/runtime/`, 3772 lines)

| File | Lines | Responsibility | Classification |
|------|------:|----------------|----------------|
| `io.cpp` | 1116 | File and directory operations, blocking socket send and receive and connect, the wolfSSL memory-BIO TLS pump | MIGRATE (file, dir, socket, and the TLS protocol in M9) + STAY-FFI (crypto primitives under TLS) |
| `concurrency.cpp` | 833 | Boost.Asio reactors, the coroutine scheduler (`nova_sched_schedule`), async I/O (`nova_aaccept`/`aconnect`/`arecv`/`asend`/`aserver_listen`), channels, actors, `when_all`, timers, the `CoroState` machinery | MIGRATE (the core of the whole effort) |
| `core.cpp` | 438 | FFI helpers (errno, cstr marshalling), process args, exit, `f64_bits`, atomics, condition variables, mutexes, coverage, stack traces, `close`, `set_nonblock`, `reuseport` | MIGRATE (most) + a tiny atomics FFI |
| `alloc.cpp` | 426 | The ARC allocator, the 8-byte heap header, `nova_retain`/`nova_release`, `nova_bytes_alloc`/`free`, coroutine frame allocation, valopt and `any` boxing | ABI-CORE (stays; backing store may become Nova) |
| `decimal.cpp` | 328 | decimal128 BID arithmetic and codec | STAY-FFI (portable later, not blocking) |
| `crypto.cpp` | 279 | SHA, MD5, base64, CSPRNG over wolfCrypt | STAY-FFI (never reimplement crypto) |
| `compress.cpp` | 74 | gzip over zlib | STAY-FFI |
| `nova_abi.h`, `runtime_str.h` | 267 | The ABI header and string helpers | ABI-CORE |

## Classification legend

- **MIGRATE.** To be rewritten in Nova over the thin syscall FFI (`os/sys`, `os/kqueue`, `os/epoll`)
  and retired from C++. This is the bulk of the work.
- **STAY-FFI.** To remain as a thin C shim over a library that we must not reimplement (crypto, TLS,
  zlib) or that is not worth reimplementing yet (decimal BID). These are small, stable, and honest to
  keep behind FFI.
- **ABI-CORE.** The irreducible runtime seam that the compiler's code generation emits calls to
  directly: the ARC operations, the allocator entry points, the coroutine-frame glue, the heap header
  layout. These stay in a minimal C core for the foreseeable future because moving them into Nova
  would require the code generator to call Nova from contexts that do not yet have a Nova frame. Their
  backing (for example, the page source under the allocator) may become Nova; their entry points and
  the ABI they present may not change without a coordinated code-generation change.

## Target end state

A minimal C core plus a thin FFI surface, with everything else in Nova:

```
+-------------------------------------------------------------+
|  Nova runtime, written in Nova                              |
|  event loop, buffers, HTTP parser, poll and socket layer,   |
|  scheduler, channels, actors, file and directory I/O        |
+-------------------------------------------------------------+
|  Thin FFI shims (STAY-FFI): crypto primitives, zlib, decimal |
|  (TLS protocol in Nova after M9; primitives stay behind FFI) |
+-------------------------------------------------------------+
|  Minimal C core (ABI-CORE): ARC ops, allocator entry,       |
|  coroutine-frame glue, heap header                          |
+-------------------------------------------------------------+
|  Kernel: syscalls via os/sys, os/kqueue, os/epoll           |
+-------------------------------------------------------------+
```

Boost.Asio is removed entirely. The C line count drops from about 3772 to the ABI core plus the FFI
shims, on the order of a few hundred lines, with the crypto and TLS libraries linked but not written
by us.

## Rules that govern every step

1. **Never reimplement the crypto primitives; the TLS protocol may be built in Nova.** This rule has
   two halves that must not be confused. The cryptographic PRIMITIVES, that is, the block ciphers,
   hashes, curves, and their constant-time arithmetic (AES-GCM, ChaCha20-Poly1305, SHA-2, X25519,
   P-256, RSA), are never hand-rolled; they stay behind a vetted library. The TLS PROTOCOL, that is,
   the handshake state machine, the record layer, key schedule wiring, and the framing, is ordinary
   state-machine code and MAY be written in Nova, driving vetted primitives underneath. Building the
   protocol in Nova (phase M9) with a reference implementation is legitimate; reimplementing AES is
   not. Until M9 lands, TLS stays behind the wolfSSL memory-BIO pump.
2. **Additive and reversible.** Each migration keeps the C path working until the Nova path passes the
   gates, then removes the C path in a separate, revertable commit. No step leaves the tree in a state
   where the corpus is red.
3. **Gated at every step.** A step is done only when `conformance/run.sh` (native), `--asan`, and
   `--tsan` are green, plus a feature test for the thing that moved. Concurrency steps must be verified
   under `--tsan`, without exception, because the corpus alone cannot see a race.
4. **The ABI seam is sacred.** The symbols and layout in the ABI-CORE row do not change except through
   a deliberate, code-generation-coordinated change with its own review. Everything else is free to
   move.
5. **Measure where it matters.** I/O and scheduler changes carry a benchmark (the reactor servers in
   `flagship/bench/headtohead/nova-reactor/`), so a regression in throughput is caught, not discovered
   later.

## Tooling that must exist first

The scheduler attempt failed to be root-caused because runtime `fprintf` to standard error did not
surface in this environment (a binary-caching layer). Before the next concurrency step:

- **A file-based runtime trace.** A compile-time-guarded trace that writes to a file with an explicit
  flush, so the coroutine completion and requeue sequence is visible regardless of how the binary is
  built or cached. This is the single most important unblocker for the scheduler migration.
- **A runtime-symbol audit.** A small script that lists every `nova_*` symbol the C++ runtime exports
  and every symbol the code generator and the standard library reference, so that "what still depends
  on C++" is a fact, not a guess, and so that a retired symbol is proven unreferenced before deletion.

**M0 delivered (2026-07-28).** Both tools are built. The trace is a file-based, per-line-flushed
facility gated on `NOVA_TRACE=<file>`, callable from Nova (`nova_trace_msg`, `nova_trace_kv`) and from
C++ (the `NOVA_TRACE(...)` macro in `nova_abi.h`); it is a no-op with near-zero cost when unset,
verified to surface reliably where stderr did not. The audit is `tools/runtime-symbol-audit.sh`,
which reports 221 exported `nova_*` symbols, 203 referenced by the compiler or standard library, and
the current removal candidates; pass a symbol name to see exactly where it is referenced.

**Diagnostics workflow for the concurrency phases.** To trace runtime-internal code (for example the
scheduler in M1), add `NOVA_TRACE("sched pump h=%lld done=%d", h, done)` calls in the runtime, and run
with `NOVA_TRACE=/tmp/trace.log`. Because a compiled binary is cached by Nova-source hash, a
runtime-only change may not reach an unchanged test binary; run against a fresh or uncached test file
(or clear the build cache) so the updated runtime is linked. The trace file then contains the exact
sequence, flushed per line, regardless of how the binary is run.

## The phased migration

Each phase names its prerequisite, its deliverable, and its gate. The order is chosen so that each
phase removes a real dependency and is independently verifiable.

- **M0. Tooling.** The file-based trace and the symbol audit above. Gate: the trace shows the
  scheduler sequence on the failing multi-level-await case.
- **M1. Async scheduler migration. DONE.** The per-reactor run queue (`g_rq`, thread-local, entered
  by `nova_reactor_resume`) drives nested `await` and `spawn` on the reactor thread instead of Asio.
  When a reactor-driven coroutine schedules a child (nested await) or a spawn, `nova_sched_schedule`
  pushes onto `g_rq`; `reactor_pump` drains it to quiescence, running `reactor_finish` (release held
  args, hand completion to the awaiter, or reap a detached top-level coroutine) on each completion.
  Off reactor threads (`g_reactor_mode` false) the Asio path is unchanged, so the existing
  `NOVA_THREADS` deployment does not regress. Verified with `NOVA_TRACE`: the earlier "multi-level
  hangs" report was a conflation. Multi-level await (`top -> await middle -> await leaf`) and
  two-`spawn`+`await` both drain correctly and synchronously through the queue (corpus case 199).
  The genuine boundary the trace pinned down is different: an `await` that suspends on an
  **Asio-backed** primitive (`sleep`/timer, `arecv`, `asend`, `aconnect`, `aaccept`) can never
  complete on the reactor, because the reactor thread runs its own poll loop and never runs the Asio
  `io_context`, so the completion is orphaned. That is not a scheduler bug; it is exactly what M2
  removes. Until then those primitives fail fast on a reactor thread via `nova_reactor_io_violation`
  (a clear diagnostic naming the primitive, then `abort`), so the unsupported combination is loud
  instead of a silent hang or wrong value. Gate: corpus (incl. 199) and ASAN green; the Asio-abort
  path is proven out-of-corpus (a corpus case cannot abort). This unblocks M2.
- **M2. Async socket I/O onto the reactor. WIP.** Reimplement the async socket seam in Nova over
  `os/sys` non-blocking sockets driven by the reactor, retiring the Asio versions in `concurrency.cpp`.
  Prereq: M1.
  - **Done (this step): the reactor-native stream.** `src/std/net/reactorio.nova` (`ReactorStream` =
    a raw fd plus the kqueue it is registered on) provides `recvInto` / `sendBuf` / `sendStr` as
    `async fn`s that try a non-blocking `read`/`write` inline and, on `EAGAIN`, register readiness
    (`EVFILT_READ`, or one-shot `EVFILT_WRITE`) with the reactor carrying `currentCoro()` as the
    token, then `coroSuspend`; the reactor resumes them when the fd is ready. No Asio, no thread held
    while blocked. Reactor write-interest (`addWrite`/`delWrite`) was added to `net/reactor`. Proven
    by corpus case 200: two coroutines on one reactor complete a send and receive round trip over a
    socketpair, trace-confirmed to park on `EAGAIN` and resume on readiness. Native 193, ASAN 355,
    TSan 201 (200 tsan clean).
  - **Done: connect and accept.** `net/reactorio.reactorConnect` (non-blocking `connect` + await
    writability + `SO_ERROR` via a new `getsockopt` binding) and `reactorAccept` (accept loop
    awaiting readability), with `parseIPv4` for numeric hosts. Found and fixed a real portability
    bug: `SOL_SOCKET` was the Linux value (1); on macOS/BSD it is `0xffff`, so `getsockopt(SO_ERROR)`
    was failing (surfaced via `NOVA_TRACE`). Corpus case 201 does a loopback TCP client and server
    round trip on one reactor.
  - **Done: the current-reactor thread-local.** `nova_reactor_set_current`/`nova_reactor_current`
    (share-nothing per reactor thread), exposed as `reactor.setCurrent`/`currentKq`; a worker sets it
    once so a stream can be built deep in driver code without the reactor being threaded through.
  - **Done: the `AsyncStream` cutover.** `asyncio.AsyncStream` is dual-mode: `kq == 0` is the Asio
    stream (unchanged); `kq > 0` is reactor-native (`sock` is a raw fd, recv/send/close delegate to
    `net/reactorio`). `asyncConnect` picks the reactor path when `reactor.currentKq() > 0`, else Asio.
    Corpus case 202 runs a TCP round trip where the client goes entirely through the `AsyncStream`
    seam on the reactor; the M1 `nova_reactor_io_violation` guard proves the reactor path was taken
    (an Asio fallback on the reactor thread would have aborted). Backward compatible, Asio deployment
    untouched.
  - **Done: hostname resolution.** `net/reactorio.resolveHost4` parses numeric IPv4 directly and
    resolves a name via `getaddrinfo` (new `os/sys` bindings). `reactorConnect` takes a host name, so
    a driver reaches a named database host on the reactor. `getaddrinfo` is a blocking DNS lookup done
    once per connection (pooled), not per request; async DNS is a later step. Corpus case 203.
  - **Done: a whole request on the reactor.** `web/app.serveReactorConn` wraps an accepted fd in a
    reactor-native `AsyncStream` and runs the same `handleConn` pipeline (parse, route, mediator,
    handler, response) as the Asio path; `App.runReactor` is the opt-in single-reactor server (the
    default `run()` keeps Asio). Corpus case 204 serves a real App request (typed route plus handler)
    over a reactor-native stream on one reactor; the M1 io-violation guard confirms the reactor path
    (0 violations). So the request and any per-request database call now run on the reactor.
  - **Done: the multi-core reactor server.** `web/app.runReactorMC(port, workers)` serves
    share-nothing across N reactor threads, one reactor plus a `SO_REUSEPORT` listener per thread.
    The worker closure captures only the `App` (a lambda passed to `runReactors` resolves just its
    first capture, a real compiler limit; the port rides on a new `App.serverPort` field). Corpus
    case 206 proves each worker receives the `App` with its config intact, read concurrently, TSan
    clean; `server_app_mc.nova` is a load-tested multi-core App server. Note: a captured local named
    `app` shadowed the `app` module alias in other files (lambda capture tracking is name-based),
    which broke a static-content case until the local was renamed; a captured name matching a module
    alias is a latent cross-file hazard.
  - **Remaining before M3:** async DNS (`getaddrinfo` currently blocks the reactor briefly per
    connection).
  - Gate (M2): client and server round trip on the reactor, connect-by-name, and a full App request,
    all reactor-native (200 to 204); the Asio deployment does not regress. Native 197, ASAN 363,
    TSan 209.
- **M3. Database drivers onto the reactor. DONE (mock).** The drivers connect via
  `asyncio.asyncConnect` and do their I/O through `asyncio.AsyncStream` (`io.recvInto` / `io.sendStr`),
  both made reactor-native in M2, so on a reactor thread the whole driver runs reactor-native with no
  driver change. Corpus case 205 proves the flagship pattern end to end: a real App (typed route plus
  handler) served on one reactor, whose handler does `await asyncio.asyncConnect(host, port)` then a
  query round trip against a mock database server on the SAME reactor (standing in for a live BTreeDB,
  which uses the identical seam). Inbound accept, request parse, mediator dispatch, the handler's DB
  connect and query, and the response all run in one poll loop, no Asio. This closes the original PH6
  blocker (a handler's nested async DB call used to deadlock on the reactor). The M1 io-violation
  guard confirms the reactor path (0 violations; an Asio fallback for the DB I/O would have aborted),
  and the three coroutines complete with no ASAN leak. Prereq: M2. Gate: the flagship per-request
  database path works on the reactor (done, mock); a live-driver round trip additionally needs a
  reachable database, with the driver code unchanged. Native 198, ASAN 365, TSan 211.
- **M4. Retire Boost.Asio. WIP.** With the scheduler (M1), async I/O (M2), and databases (M3) on the
  reactor, remove the Asio reactors, strands, the `g_io` context, and the Asio socket/timer code from
  `concurrency.cpp`, and drop the vendored Boost from the build. Prereq: M1 to M3. Progress this far:
  - **Done: the reactor is the default server path.** `App.run` routes through `runReactorMC` (the
    share-nothing multi-core reactor) for plain HTTP; it falls back to the Asio server only for TLS
    (not yet on the reactor) or when `NOVA_ASIO=1` forces it. So a `nova init` app runs on the
    self-hosted runtime by default. Verified live (plain app served on the reactor; `NOVA_ASIO=1`
    falls back to Asio).
  - **Done: reactor-native timers.** `nova_await_timer` arms an `EVFILT_TIMER` on the current
    reactor's kqueue when on a reactor thread (the Asio `steady_timer` only off the reactor), so
    `await sleep` and, next, read deadlines no longer need Asio on the reactor. Corpus case 207.
    This also restores the timer capability that defaulting to the reactor had dropped.
  - **Done: read deadlines on the reactor.** `reactorio.recvIntoDeadline` bounds a read by a deadline
    against the monotonic clock (`nova_mono_ms`): a reactor timer only wakes the coroutine to re-check
    the clock, cancelled on any exit; on timeout it returns -2 and the server closes the connection.
    `AsyncStream.recvInto` routes to it when a timeout is set, so `handleConn`'s `readTimeoutMs` is
    enforced on the reactor. A batch-safe resume guard (`batchBegin` per poll batch, armed only while
    a deadline is active) stops a stale deadline-timer event from resuming a coroutine reaped earlier
    in the same batch. Corpus case 208 (times out, and data-arrives-first).
  - **Done: inbound TLS on the reactor.** No TLS-code change was needed: `asynctls.TlsStream` already
    does its socket I/O through `asyncio.AsyncStream` (`self.base.recvInto` / `sendStr`), and the
    wolfSSL memory-BIO pump (`nova_mtls_*`) is pure protocol state with no Asio, so wrapping a
    reactor-native `AsyncStream` in `tlsAccept` runs the whole handshake and data path on the reactor.
    `serveReactorConn` tlsAccepts when `app.tlsEnabled`; the `run()` TLS-to-Asio fallback is removed
    (only `NOVA_ASIO=1` selects Asio now). Corpus case 209 (in-Nova TLS handshake plus HTTP on one
    reactor, 0 io-violations) and a live `curl -k https://` / TLSv1.3 smoke test. Crypto primitives
    stay in wolfSSL.
  - **Done: the `NOVA_ASIO` fallback is retired.** `App.run` is reactor-only; the Asio server plumbing
    (`runServer`/`acceptLoop`/`handleConnPlain`/`handleConnTls`) is deleted from `app.nova`. The web
    framework no longer references the Asio async socket seam.
  - **Remaining to actually drop Boost (a real refactor, not a deletion).** Boost still backs two
    things the corpus depends on, and both must move off Asio first:
    1. **`nova_run_root`**, the driver for every async `@test` and standalone async `main`. It runs the
       Asio `io_context` across a **thread pool** (TSan exercises it at 4 threads). The share-nothing
       reactor is thread-local and has **no cross-thread coroutine wakeup**, which is exactly what
       Asio's `post`-to-another-strand gives channels and actors (a `send` on one thread waking a
       waiter on another). So dropping Boost needs a new primitive first: cross-reactor wakeup
       (an `eventfd`/self-pipe registered on each reactor's poll set), then `nova_run_root` rewritten
       as N reactor threads driven to root completion.
    2. **Five corpus tests use the raw Asio primitives directly** (`113` async-stream, `114`
       async-tls, `115` async-timeout, `184` null-socket, `186` inbound-TLS) via `aaccept`,
       `async_read`/`async_write`, `serverListen`. Their behaviour is now covered by the reactor tests
       `200` to `209`, so they are retired or converted as part of removing the primitives.
    Order: **(a) cross-reactor wakeup. DONE.** `reactor.registerWake`/`post`/`drainWake` over an
    `EVFILT_USER` trigger plus a per-index thread-safe inbox (a coroutine posted from another thread
    wakes the owning reactor's blocking poll and is drained on the `EVFILT_USER` event). Corpus case
    210, TSan clean cross-thread at 4 threads. Linux plugs an `eventfd` behind the same shape.
    (b) rewrite `nova_run_root` as N reactor threads with cross-thread scheduling (route
    `nova_sched_schedule` to the owning reactor's inbox via `reactor.post` when the target is on
    another thread); (c) retire/convert the 5 tests and delete `nova_arecv`/`asend`/`aconnect`/
    `aaccept`/`aserver_listen`/the Asio `nova_await_timer` branch/`when_any_deadline` timers; (d)
    delete `io_context`/strands/thread pool/`g_io` and drop vendored Boost from `build.zig` (Boost is
    confined to `concurrency.cpp`, so the final deletion is local). Gate each step on corpus, ASAN,
    and TSan.
  - Gate (full M4): the runtime builds and links with no Boost include; corpus, ASAN, TSan, and the
    head-to-head all green.
- **M5. File and directory I/O.** Reimplement `nova_file_*` and `nova_dir_*` in Nova over `os/sys`
  (`open`, `read`, `write`, `close`, `stat`, `mkdir`, `readdir`, `rename`, `unlink`). Prereq: none
  hard, but best after M4 so `io.cpp` shrinks to the TLS pump only. Gate: the `io/file` and `io/dir`
  conformance cases pass on the Nova path.
- **M6. Process and primitive shims.** Move the `core.cpp` shims (`close`, args, exit, `set_nonblock`,
  `reuseport`, errno) fully into `os/sys`, and provide atomics and one condition-variable primitive as
  a tiny, honest FFI (these are genuinely primitive and may stay behind a few-line C shim). Prereq:
  none. Gate: the relevant cases pass; `core.cpp` reduces to the ABI-CORE helpers.
- **M7. Channels and actors.** Reimplement channels and the actor mailbox in Nova over the reactor and
  the primitives from M6. Prereq: M1, M6. Gate: the channel and actor conformance cases pass under
  `--tsan`.
- **M8. Allocator backing.** Optionally move the page source under `nova_bytes_alloc` to a Nova
  `mmap`-backed arena, keeping the ARC entry points and the heap header unchanged (ABI-CORE stays).
  Prereq: none. Gate: corpus and ASAN green; allocation microbenchmark not regressed.

- **M9. TLS 1.2 and 1.3 protocol in Nova.** Write the TLS handshake state machine, the record layer,
  the key schedule, and the alert and framing logic in Nova, over the async socket seam (M2) and over
  vetted crypto primitives (AES-GCM, ChaCha20-Poly1305, SHA-2, X25519, P-256, RSA) that remain behind
  a library and are never hand-rolled (rule 1). Reference implementation: the Zig standard library's
  `std.crypto.tls` (a TLS 1.3 client) and `std.crypto` primitives, which are a clean, readable model
  for the protocol and a source of the primitive set to bind. This retires the wolfSSL memory-BIO pump
  in `io.cpp` and, together with the crypto-primitive question, is the last large piece of I/O in C++.
  Prereq: M2 (the async socket seam on the reactor). Gate: a real TLS 1.3 handshake and, separately, a
  TLS 1.2 handshake against a standard server and client (`curl`, `openssl s_client`), the inbound and
  outbound TLS conformance cases green on the Nova path, and no timing-sensitive primitive written by
  us. This is a substantial phase and may itself be split (record layer, then 1.3 handshake, then 1.2)
  when it is scheduled.

The decimal, crypto-primitive, and compress shims (STAY-FFI) are not phases; they remain as they are.
decimal may be ported to Nova later as pure-compute work, outside this plan's critical path. The
crypto primitives stay behind a vetted library permanently; only the TLS protocol on top of them moves
to Nova in M9.

## What must never break (the ABI seam)

These are the three contracts from the runtime ABI note that hold the whole thing together and that no
step in this plan may change without a coordinated code-generation change:

1. **The extern C symbol names and signatures** that the code generator emits: `nova_retain`,
   `nova_release`, `nova_bytes_alloc`, `nova_bytes_free`, the coroutine intrinsic glue, and the
   scheduler entry points during their migration.
2. **The ARC discipline:** every heap object carries an 8-byte header (refcount at offset minus 8,
   length at offset minus 4); ownership is decided in the semantic and code-generation passes.
3. **The coroutine-frame convention:** the resume function at frame offset 0, the destroy function at
   offset 1, done detected by a null resume slot. The reactor scheduler drives coroutines through
   exactly this convention.

## Risks

- **The scheduler completion path (M1). Resolved.** The run queue drains nested await and spawn on
  the reactor (corpus 199, trace-proven). The reactor-vs-Asio I/O boundary it exposed is guarded by
  a loud abort (`nova_reactor_io_violation`) and closed by M2.
- **The ABI seam.** A careless change to a code-generation-emitted symbol corrupts memory in a way
  that lands far from the cause. Mitigated by rule 4 and by the ASAN gate, which is the authority on
  ownership changes.
- **Cross-platform.** The Linux epoll backend compiles but is not yet verified on Linux; Windows IOCP
  is out of scope for now. Mitigated by keeping the poll layer behind the `Reactor` shape.
- **Calling Nova from a runtime thread.** Already proven by `nova_run_reactors`, but every migrated
  service must be reachable from a reactor thread without a hidden Asio dependency.

## Status snapshot (2026-07-28)

Already in Nova: the event loop (`net/reactor`), the buffer pools (`io/slab`, `io/arena`), the HTTP
parser (`web/httpparser`), the poll and socket layer (`os/sys`, `os/kqueue`, `os/epoll`), and the
share-nothing multi-core driver. Verified: a single reactor on one core out-throughputs the tuned
frameworks' eight-core numbers; the reactor is race-free under `--tsan`. Done: M0 (trace tooling),
M1 (the scheduler migration), M2 (async socket I/O on the reactor), and M3 (database drivers on the
reactor, proven with a mock) all landed. The reactor drives nested `await` and `spawn`; recv, send,
connect, accept, and resolve are reactor-native in Nova over `os/sys`; `AsyncStream` is dual-mode; a
whole App request runs on the reactor; the flagship pattern (a handler's per-request database call)
runs end to end on the reactor with no Asio, closing the PH6 deadlock; and the App serves share-nothing
multi-core (`runReactorMC`, `SO_REUSEPORT`). M4 is nearly done: `App.run` is reactor-only, the
`NOVA_ASIO` fallback is retired, and timers, read deadlines, and inbound TLS are all reactor-native.
Nothing on the web path uses Asio. Verified by corpus 199 to 209 plus a live `curl -k https://`
TLSv1.3 test, all TSan clean. The final step to drop Boost is a real refactor, not a deletion: Boost
still backs `nova_run_root` (the multi-threaded async `@test`/standalone driver, TSan at 4 threads) and
5 Asio-primitive corpus tests. The keystone that was missing, cross-reactor wakeup (`EVFILT_USER` plus
a thread-safe per-index inbox, corpus 210, TSan clean cross-thread), is now in. Next: rewrite
`nova_run_root` on the reactor with cross-thread scheduling, retire or convert the 5 tests, then delete
the Asio code and drop vendored Boost. Also pending: a live-driver round trip against a reachable
database (driver code unchanged) and async DNS.
