# Retiring the C++ Runtime: A Structured Migration Plan

## Tracker

Statuses: DONE, WIP (in progress or partially landed), TODO. Update this table as the single source of
truth for progress; the phase details are below.

| Phase | What it retires or builds | Prereq | Status | Notes |
|-------|---------------------------|--------|--------|-------|
| Foundation | Event loop, buffers, HTTP parser, poll and socket layer, multi-core | none | DONE | `self-hosted-runtime.md` phases 1 to 5; race-free under `--tsan` |
| M0 | Tooling: file-based runtime trace, symbol audit | none | TODO | Unblocks M1; stderr diagnostics did not surface last time |
| M1 | Async scheduler migration (per-reactor run queue) | M0 | WIP | Single-level await works; multi-level and spawn hang; reverted, diff at `scheduler-migration-wip.patch` |
| M2 | Async socket I/O on the reactor | M1 | TODO | `arecv`/`asend`/`aconnect`/`aaccept` in Nova over `os/sys` |
| M3 | Database drivers on the reactor | M2 | TODO | No driver change; they already speak the async seam |
| M4 | Retire Boost.Asio | M1 to M3 | TODO | Remove reactors, strands, `g_io`; drop vendored Boost |
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

## The phased migration

Each phase names its prerequisite, its deliverable, and its gate. The order is chosen so that each
phase removes a real dependency and is independently verifiable.

- **M0. Tooling.** The file-based trace and the symbol audit above. Gate: the trace shows the
  scheduler sequence on the failing multi-level-await case.
- **M1. Finish the async scheduler migration.** Complete the per-reactor run queue so nested `await`
  and `spawn` are driven by the reactor, not Asio. The work-in-progress diff is at
  `scheduler-migration-wip.patch`; the remaining bug is in the completion-and-requeue path for a
  queued coroutine that suspends on its own nested await. Prereq: M0. Gate: multi-level await and
  `spawn`+`await` on the reactor pass, corpus and ASAN and TSan green. This is the keystone; nothing
  downstream proceeds without it.
- **M2. Async socket I/O onto the reactor.** Reimplement `nova_arecv`, `nova_asend`, `nova_aconnect`,
  `nova_aaccept`, and the listen path in Nova over `os/sys` non-blocking sockets driven by the reactor,
  retiring the Asio versions in `concurrency.cpp`. Prereq: M1. Gate: an async client and server round
  trip on the reactor; the async stream and TLS conformance cases pass with the new path.
- **M3. Database drivers onto the reactor.** The drivers already speak the async seam (`arecv`/`asend`
  over `AsyncStream`); once M2 provides that seam on the reactor, they run on the reactor with no
  driver change. Prereq: M2. Gate: a live driver round trip on the reactor (offline-gated codecs stay
  green); the flagship's per-request database path works on the reactor.
- **M4. Retire Boost.Asio.** With the scheduler (M1), async I/O (M2), and timers moved off Asio, remove
  the Asio reactors, strands, and the `g_io` context from `concurrency.cpp`, and drop the vendored
  Boost from the build. Prereq: M1 to M3. Gate: the runtime builds and links with no Boost include;
  corpus, ASAN, TSan, and the head-to-head all green.
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

- **The scheduler completion path (M1).** The known-hard bug. Mitigated by M0 tooling and by verifying
  under `--tsan` before it lands.
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
frameworks' eight-core numbers; the reactor is race-free under `--tsan`. Blocked: M1, the scheduler
migration, which gates M2 through M4 and therefore the whole retirement. Next action: M0 tooling, then
M1.
