# Network I/O stack: build our own loop vs stay on Asio — tradeoff analysis

**Status:** DECISION DOC (parked since 2026-07-25, revisited 2026-07-27 grounded in the actual runtime).
**TL;DR recommendation:** **Path A (share-nothing on Asio) now; io_uring as a later, measured, Linux-first
pluggable backend behind an executor-agnostic seam — not a from-scratch 3-platform loop.**

---

## 0. What we actually run today (verified, not remembered)

`src/runtime/concurrency.cpp` (888 lines) + `io.cpp` (976). The Asio surface is **~12 primitives**:
`io_context`, `tcp::{socket,acceptor,resolver,endpoint}`, `steady_timer`, `strand`/`make_strand`/
`bind_executor`, `async_{read,write,connect}`, `thread_pool`, `post`, `buffer`.

Crucially, **everything above the reactor is already Nova-owned**:

- **Coroutines** are LLVM-generated; `raw_coro_resume(h)` resumes them by reading the frame's
  resume/destroy pointers directly (the switched-resume ABI). Asio is NOT the coroutine engine — it only
  `post`s resume handlers onto the loop.
- **Composition** — `spawn`/`await`/`when_all`/`select`/whole-query-deadline — is Nova's own waiter
  registry, not Asio's `awaitable`/`co_spawn`.
- **Scheduling** — `nova_sched_schedule` posts a coroutine's resume to **its per-coroutine strand**
  (`CoroState.strand = make_strand(g_io)`).

So Asio provides exactly three things: **(1) the reactor** (epoll/kqueue/IOCP abstraction), **(2) socket +
timer objects**, **(3) the strand executor** for thread-safety. ~10% of the library.

**The one real pain:** a socket's async ops are bound to its coroutine's strand ("one connection = one
coroutine = one socket → per-coroutine strand IS per-socket strand"). Reusing a socket across coroutines
(what connection pooling needs) races under multi-threading → pooling reuse is **gated to 1 worker**.

**Measured ceiling today:** web ~108k rps (2.25× a Zig baseline); the bottleneck is
**IO + coroutine-scheduling, NOT the reactor**. epoll/kqueue is not what's limiting us.

---

## 1. The decision is not binary — it's three separable axes

| Axis | Today | Alternative |
|------|-------|-------------|
| **A. Reactor** | epoll/kqueue via Asio | io_uring (Linux) / kqueue (mac) / IOCP (Win), hand-rolled |
| **B. Threading model** | 1 shared `io_context` + per-coroutine strands | share-nothing thread-per-core (one loop per core, no shared sockets) |
| **C. Boost dependency** | vendored Asio subset (~7 MB) | none |

The trap is treating this as "Asio vs custom loop." **Axis B is where the pain is, and it's independent
of A and C.** You can fix the strand/pooling problem by changing *only* the threading model — on Asio,
keeping the reactor and Boost. That is Path A.

---

## 2. Path A — share-nothing thread-per-core, ON Asio

One `io_context` **per core**, each pinned to its own thread, **no shared state between them**;
`SO_REUSEPORT` so the kernel load-balances accepts across per-core listeners (the nginx model).

**Why it fixes the actual problem:** with no socket shared across threads, **strands become unnecessary**
— a connection lives entirely on one core's loop, so its socket is reused freely by any coroutine on that
core. The pooling limit dissolves *structurally*, not by locking.

- **Cost:** days. Restructure `nova_run` to N independent `io_context`s + per-core accept; drop the
  cross-coroutine strand posting; per-core connection pools (already per-thread lock-free — we built that
  for I1). TLS, timers, sockets, the coroutine seam — **all unchanged**.
- **Risk:** low. Same battle-tested Asio reactor; the async/TLS/timeout gates (113/114/115) are the guardrail.
- **Wins:** ~80% of the throughput story (multi-core pooled proxy/server), keeps cross-platform + TLS,
  no new dependency surface.
- **Loses:** doesn't leave Boost; doesn't get io_uring's batching.

**Path A is not throwaway even if we later do io_uring** — share-nothing IS the target architecture; the
reactor underneath it is a swappable detail. Path A is the prerequisite for Path B, not an alternative to it.

---

## 3. Path B — Nova-owned io_uring/kqueue/IOCP loop, leave Boost

### 3.1 The genuine case FOR
- **io_uring is materially faster than epoll** at high connection counts: batched submission (one syscall
  for many ops), no per-op syscall, registered buffers/fds, multishot accept/recv. For a proxy/server this
  is exactly the hot path.
- **Removes Boost** — build simplification (no vendored subset, no Boost headers).
- **Zero-indirection resume seam** — I/O completion can call `raw_coro_resume` directly, no Asio handler
  allocation per op. We already own the coroutine model, so this is a natural fit.
- **Share-nothing is native** — one ring per core.
- **btree disk I/O could ride io_uring too** — async file I/O for the storage engine, one model for net+disk.
- Asio's executor/strand model is something we **fight** (it caused the pooling limit); owning the loop
  lets the design match Nova's coroutine model instead of adapting to Asio's.

### 3.2 The genuine case AGAINST
- **We reimplement the 10% that is the hardest 10%.** epoll/kqueue/IOCP edge cases, socket lifetime,
  timer cancellation, completion ordering, back-pressure — years of Asio bug-fixes we'd re-discover. This
  session's recurring lesson was *uncovered code rots silently*; a hand-rolled reactor is the highest-stakes
  possible place to relearn that.
- **Three backends.** io_uring (Linux) + kqueue (mac, our dev platform) + IOCP (Windows, we cross-compile
  to it). That's 3× the surface. io_uring alone has a famously sharp API: kernel-version feature drift,
  distros disabling it for security, completion-lifetime rules, buffer ownership.
- **TLS-async is the danger zone.** wolfSSL memory-BIO must be pumped correctly by the new loop; a framing
  bug here is a *silent* corruption (the most expensive class — see this session's parseI64/serde finds).
- **Cancellation/deadline semantics** (whole-query timeout, select-over-futures) already work on Asio
  timers; all must be re-proven on the new timer source.
- **It optimizes the wrong layer first.** The measured ceiling is coroutine-scheduling + IO, not the
  reactor. io_uring speeds the reactor — not currently the bottleneck. Path A addresses the actual limit
  (threading/pooling); Path B addresses a limit we haven't hit yet.
- **Weeks-to-months + opportunity cost** against finishing the product (the btree app, the polish tail).

### 3.3 What Path B is NOT about
**Senders/Receivers (P2300 / stdexec) is irrelevant here.** It is a *composition* model (structured
async, `then`/`when_all` as a type-level algebra). Nova already composes async **in-language** via LLVM
coroutines + its own waiter registry; the C++ runtime is a thin event-loop + I/O + TLS glue. Adopting
stdexec buys ~nothing and would mean *more* C++ surface, not less. "Asio is dated / the committee moved to
S/R" is true but is a different problem than the one we have. Do not let it steer this decision.

---

## 4. Recommendation

1. **Do Path A now.** It fixes the real, measured pain (multi-core pooling), is low-risk and days-scale,
   keeps TLS + cross-platform + the coroutine seam untouched, and *is* the share-nothing architecture we'd
   want under any reactor. Ship it, re-benchmark pooled multi-core throughput on separate hosts (single-box
   proxy+backends+load-gen is too noisy to trust).

2. **Make TLS + timers executor-agnostic** as part of / right after Path A — so the reactor becomes a
   swappable backend behind one seam. This is the real enabling refactor, and it's small.

3. **Then, only if benchmarks show the reactor is the ceiling, add io_uring as a *pluggable Linux backend*
   behind that seam — keeping Asio as the portable fallback for mac/Windows.** This gives io_uring's ceiling
   on Linux (deploy target) without ever maintaining three hand-rolled backends. It is the disciplined,
   reversible version of "leave Boost": Boost stays as the portable path; io_uring is the fast path where it
   exists.

4. **Do not** start with a from-scratch 3-platform loop, and **do not** adopt Senders/Receivers.

**Sequencing guardrail:** the async_stream / async_tls / async_timeout conformance gates (113/114/115) plus
the driver overlap tests are the regression net for every step. Nothing merges that reddens them.

**Priority note:** this whole item is runtime *infrastructure* — per the standing LANGUAGE-FIRST policy it
sits behind finishing/polishing the language and the flagship btree app. Path A is cheap enough to slot in;
Path B is a deliberate project to schedule, not a detour to take mid-stream.
