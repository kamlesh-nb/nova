# The Runtime

The native runtime is written in **C++20**, and resides in `src/runtime/`. It is compiled into a static
archive (`~/.kyte/lib/libkyte_runtime.a`) that every native binary links. It provides the async scheduler,
the non blocking sockets and TLS, the channels and actors, the allocator, decimal128, and crypto. The
compiler communicates with it through a fixed **extern-C ABI seam**; the runtime may be rewritten so long
as that seam is held.

| File | Role |
|------|------|
| `concurrency.cpp` (about 790) | The scheduler: the Boost.Asio reactors, coroutine resume and suspend, `spawn`, `await`, and `when_all`, the channels, and the block drive entry `kyte_run_root`. |
| `io.cpp` (about 1120) | The non blocking sockets (async accept, connect, read, write, and deadline recv) and TLS (wolfSSL over an in memory BIO, pumped by Kyte async); and process spawn and isolation. |
| `alloc.cpp` (about 430) | The heap: `kyte_bytes_alloc`, the 8 byte header, `kyte_retain` and `kyte_release`, value optional boxing, and the persistent arena. |
| `core.cpp` (about 430) | The primitives: `kyte_panic`, string conversions, `kyte_f64_bits`, and args and env. |
| `decimal.cpp` (about 330) | IEEE-754 decimal128 (BID): parse and format, along with base-10 arithmetic with round half even. |
| `crypto.cpp` (about 280) | Real wolfCrypt: SHA, HMAC, and CSPRNG. |
| `kyte_abi.h` (about 225) | The extern-C declarations, that is, the seam against which the compiler emits calls. |

## The Scheduler, `concurrency.cpp`

### Share Nothing, Thread per Core (Path A, or N1)

The scheduler consists of **N (that is, cores minus 1) independent `boost::asio::io_context` reactors**,
each driven by one pinned thread. A coroutine, and the socket that it owns, lives entirely on its reactor
and never migrates; hence the per-coroutine strands are free no ops, and the per-reactor data structures
(for example the reverse proxy connection pool) require no locks, in the manner of the HAProxy
`idle_conn_srv[tid]` model. `KYTE_THREADS=1` collapses this to a single reactor (which is the exact old
behaviour, and serves as the rollback switch).

- **`kyte_run()`** starts the pinned reactor threads and drives them to idle.
- **`kyte_hold_all_reactors()`** installs a leaked `work_guard` per reactor, so that a *server's*
  `io.run()` blocks for the lifetime of the process instead of returning on a momentary idle. `App.run`
  calls this before its block drive, so that the per-reactor SO_REUSEPORT accept loops land on live
  reactors (in the nginx model), which yields real multi core operation with no cross reactor socket
  sharing.

### Coroutine Resume and Suspend

The `async fn`s are LLVM coroutines (split by `CoroSplit`). The runtime resumes them via a raw switched
resume ABI, tracks the parent to child waiter edges (`g_waiters`), and schedules a parent when its awaited
child completes. Lock striped maps (`g_corostates` and `g_heldargs`, with 64 stripes) keep contention off
the hot path.

### The Block Drive Seam and its Guard

A **synchronous** caller crosses into async by *block driving*: `kyte_run_root(handle)` schedules a
coroutine and pumps its reactor until it has actually completed (and not merely gone idle, since it re
drains while a wakeup is in flight, and aborts loudly on a genuinely lost wakeup rather than returning an
unwritten result). This is legal at a true top level, such as a sync `main` or `@test`.

Doing this from *inside* a running coroutine (that is, a sync function block driving async while it is
itself running on the event loop) re-enters `io.run()` on a context that never goes idle under a live
server, and hence deadlocks. A thread local **run depth counter** wraps every `io.run()`, and
`kyte_run_root` aborts with a precise message in case it is entered at a depth greater than 0. In
combination with the checker's function colouring rules (see [01-compiler.md](01-compiler.md)), this turns
a silent hang into either a compile error or a loud, actionable abort. This is the reason the web
framework's request handlers are `async fn` end to end.

### Channels and Actors

`kyte_channel_*` implement bounded blocking channels (using a mutex and a condition variable). The actor
standard library (`Mailbox<M>` and `Behavior<M>`) is built upon channels and coroutines, on top of this.

## Async I/O and TLS, `io.cpp`

The sockets are non blocking on the Asio reactor. `kyte_aaccept`, `kyte_aconnect`, `kyte_arecv`,
`kyte_asend`, and `kyte_arecv_deadline` all **park the coroutine** (they register a completion handler and
suspend) rather than block a thread. `kyte_arecv_deadline` races the recv against a timer, for per-read
timeouts (which provide slow loris protection).

**TLS is built the right way.** wolfSSL retains *all* crypto and X.509 verification, running against an
**in memory BIO**; the record pump alone is Kyte async over the socket. Thus a TLS read decrypts from an
internal buffer, and when it requires more ciphertext it `await`s a plain socket recv; every await parks
the coroutine, and no scheduler thread is held. `kyte_mtls_new` (client) and `kyte_mtls_new_server`
(server) build the context; the standard library `TlsStream` (for both the client `tlsConnect` and the
server `tlsAccept`) drives the handshake and the record pump. The App server terminates HTTPS in process
via `tlsAccept`.

There is a robustness seam worth an understanding: async I/O upon a **null or failed socket handle** (a
handle of `0` from a refused connect) returns `-1` instead of dereferencing null, so that a database
driver which sends its handshake before checking the connect result degrades gracefully, instead of
bringing down the process.

## Process Spawn and Isolation, `io.cpp`

`kyte_process_spawn`, `_write_stdin`, `_read_stdout`, `_try_wait` (WNOHANG), `_wait`, `_kill`, and `_pid`
implement POSIX process control (wherein the identity is the kernel PID). `kyte_process_spawn_isolated`
(on Linux) is a container grade shim: it does `clone()` into the PID, mount, UTS, IPC, net, and user
namespaces, then a `pivot_root` into a private rootfs, then drops all capabilities, then installs a seccomp
BPF filter, and finally does `execve`. Off Linux, it degrades to a plain spawn. This is the exec layer
upon which the (external) orchestrator package builds.

## The Heap, `alloc.cpp`

- `kyte_bytes_alloc(size)` allocates `header(8) + size` and returns the client pointer; the arena is a bump
  region with a free list on the persistent side.
- `kyte_valopt_box` and `_unbox` fix the value-optional-zero-reads-as-undefined bug: a value type optional
  is boxed into an 8 byte cell, so that a stored `0` is distinguishable from "absent" (a null box).
- The 8 byte header, along with `kyte_retain` and `kyte_release(ptr, dtor)`, is the ARC contract against
  which codegen emits.

## The ABI Seam, `kyte_abi.h`

The compiler emits `extern "C"` calls to a fixed set of symbols. The three seams that must be preserved
across any runtime rewrite are as follows.

1. **The extern-C symbol set** (`kyte_bytes_alloc`, `kyte_retain` and `kyte_release`, `kyte_arecv` and
   `kyte_asend`, `kyte_run` and `kyte_run_root`, `kyte_channel_*`, `kyte_mtls_*`, `kyte_process_*`,
   `kyte_decimal_*`, and so forth).
2. **ARC,** that is, the 8 byte heap header and the retain and release semantics.
3. **The coroutine ABI,** that is, the manner in which the scheduler resumes a split coroutine and reads
   its promise.

The runtime is a **single translation unit** (`runtime.cpp` includes the others), so it builds as one
object and cross compiles cleanly. Boost.Asio is vendored (a header subset in `deps/boost`), and wolfSSL
and zlib are vendored and built; there is no Homebrew dependency at build time.
