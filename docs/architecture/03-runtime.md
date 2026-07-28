# The Runtime

The native runtime is **C++20**, in `src/runtime/`, compiled to a static archive
(`~/.nova/lib/libnova_runtime.a`) that every native binary links. It provides the async scheduler,
non-blocking sockets and TLS, channels/actors, the allocator, decimal128, and crypto. The compiler talks
to it through a fixed **extern-C ABI seam** — the runtime can be rewritten as long as that seam holds.

| File | Role |
|------|------|
| `concurrency.cpp` (~790) | The scheduler: Boost.Asio reactors, coroutine resume/suspend, `spawn`/`await`/`when_all`, channels, the block-drive entry `nova_run_root`. |
| `io.cpp` (~1120) | Non-blocking sockets (async accept/connect/read/write, deadline recv) and TLS (wolfSSL over an in-memory BIO, pumped by Nova async); process spawn + isolation. |
| `alloc.cpp` (~430) | The heap: `nova_bytes_alloc`, the 8-byte header, `nova_retain`/`nova_release`, value-optional boxing, the persistent arena. |
| `core.cpp` (~430) | Primitives: `nova_panic`, string conversions, `nova_f64_bits`, args/env. |
| `decimal.cpp` (~330) | IEEE-754 decimal128 (BID): parse/format + base-10 arithmetic with round-half-even. |
| `crypto.cpp` (~280) | Real wolfCrypt: SHA/HMAC/CSPRNG. |
| `nova_abi.h` (~225) | The extern-C declarations — the seam the compiler emits calls against. |

## The scheduler — `concurrency.cpp`

### Share-nothing thread-per-core (Path A / N1)

The scheduler is **N = cores-1 independent `boost::asio::io_context` reactors**, each driven by one pinned
thread. A coroutine — and the socket it owns — lives entirely on its reactor and never migrates, so the
per-coroutine strands are free no-ops and per-reactor data structures (e.g. the reverse-proxy connection
pool) need no locks: the HAProxy `idle_conn_srv[tid]` model. `NOVA_THREADS=1` collapses to a single
reactor (exact old behavior — the rollback switch).

- **`nova_run()`** starts the pinned reactor threads and drives them to idle.
- **`nova_hold_all_reactors()`** installs a leaked `work_guard` per reactor so a *server's* `io.run()`
  blocks for the process lifetime instead of returning on a momentary idle. `App.run` calls this before its
  block-drive so the per-reactor SO_REUSEPORT accept loops land on live reactors (nginx model → real
  multi-core, no cross-reactor socket sharing).

### Coroutine resume/suspend

`async fn`s are LLVM coroutines (split by `CoroSplit`). The runtime resumes them via a raw switched-resume
ABI, tracks parent↔child waiter edges (`g_waiters`), and schedules a parent when its awaited child
completes. Lock-striped maps (`g_corostates`, `g_heldargs`, 64 stripes) keep contention off the hot path.

### The block-drive seam and its guard

A **synchronous** caller crosses into async by *block-driving*: `nova_run_root(handle)` schedules a
coroutine and pumps its reactor until it has actually completed (not merely idle — it re-drains while a
wakeup is in flight and aborts loudly on a genuinely lost wakeup rather than returning an unwritten
result). This is legal at a true top level (a sync `main`/`@test`).

Doing it from **inside** a running coroutine (a sync function block-driving async while itself running on
the event loop) re-enters `io.run()` on a context that never goes idle under a live server → deadlock. A
thread-local **run-depth counter** wraps every `io.run()`; `nova_run_root` aborts with a precise message
if entered at depth > 0. Combined with the checker's function-coloring rules ([01-compiler.md](01-compiler.md)),
this turns a silent hang into a compile error or a loud, actionable abort. This is why the web framework's
request handlers are `async fn` end-to-end.

### Channels & actors

`nova_channel_*` implement bounded blocking channels (mutex + condvar). The actor stdlib
(`Mailbox<M>`/`Behavior<M>`) is built on channels + coroutines on top of this.

## Async I/O and TLS — `io.cpp`

Sockets are non-blocking on the Asio reactor: `nova_aaccept` / `nova_aconnect` / `nova_arecv` /
`nova_asend` / `nova_arecv_deadline` all **park the coroutine** (register a completion handler and suspend)
rather than block a thread. `nova_arecv_deadline` races the recv against a timer for per-read timeouts
(slow-loris protection).

**TLS is built the right way:** wolfSSL keeps *all* crypto and X.509 verification, running against an
**in-memory BIO**; the record pump is Nova async over the socket. So a TLS read decrypts from an internal
buffer, and when it needs more ciphertext it `await`s a plain socket recv — every await parks the
coroutine, no scheduler thread is held. `nova_mtls_new` (client) / `nova_mtls_new_server` (server) build
the context; the stdlib `TlsStream` (both client `tlsConnect` and server `tlsAccept`) drives the handshake
and record pump. The App server terminates HTTPS in-process via `tlsAccept`.

Robustness seam worth noting: async I/O on a **null/failed socket handle** (handle `0` from a refused
connect) returns `-1` instead of dereferencing null — a DB driver that sends its handshake before checking
the connect result degrades gracefully instead of taking down the process.

## Process spawn & isolation — `io.cpp`

`nova_process_spawn`/`_write_stdin`/`_read_stdout`/`_try_wait` (WNOHANG)/`_wait`/`_kill`/`_pid` implement
POSIX process control (identity = kernel PID). `nova_process_spawn_isolated` (Linux) is a container-grade
shim: `clone()` into PID/mount/UTS/IPC/net/user namespaces → `pivot_root` a private rootfs → drop all
capabilities → install a seccomp-BPF filter → `execve`. Off-Linux it degrades to a plain spawn. This is
the exec layer the (external) orchestrator package builds on.

## The heap — `alloc.cpp`

- `nova_bytes_alloc(size)` allocates `header(8) + size`, returns the client pointer; the arena is a bump
  region with a free-list on the persistent side.
- `nova_valopt_box`/`_unbox` fix the value-optional-0-reads-as-undefined bug: a value-type optional is
  boxed into an 8-byte cell so a stored `0` is distinguishable from "absent" (a null box).
- The 8-byte header + `nova_retain`/`nova_release(ptr, dtor)` are the ARC contract codegen emits against.

## The ABI seam — `nova_abi.h`

The compiler emits `extern "C"` calls to a fixed set of symbols. The three seams that must be preserved
across any runtime rewrite:

1. **The extern-C symbol set** (`nova_bytes_alloc`, `nova_retain`/`nova_release`, `nova_arecv`/`nova_asend`,
   `nova_run`/`nova_run_root`, `nova_channel_*`, `nova_mtls_*`, `nova_process_*`, `nova_decimal_*`, …).
2. **ARC** — the 8-byte heap header and retain/release semantics.
3. **The coroutine ABI** — how the scheduler resumes a split coroutine and reads its promise.

The runtime is a **single translation unit** (`runtime.cpp` includes the others) so it builds as one
object and cross-compiles cleanly. Boost.Asio is vendored (a header subset in `deps/boost`), wolfSSL and
zlib are vendored/built — no Homebrew dependency at build time.
