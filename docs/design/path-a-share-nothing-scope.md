# Path A — share-nothing thread-per-core on Asio: implementation scope

**Goal:** replace the single shared `io_context` + per-coroutine strands with **N = (cores − 1)
independent reactors**, each an `io_context` pinned to its own thread, sharing nothing. This dissolves
the per-coroutine-strand pooling limit *structurally* (a connection lives on one reactor, so its socket is
freely reused by any coroutine on that reactor) and removes three global mutexes.

See `network-io-stack-tradeoff.md` for why this over a from-scratch loop. Reactor count is **cores − 1**
(leave one core for the OS / accept bookkeeping / the block-drive caller); `NOVA_THREADS` overrides.

---

## Current state (verified, `src/runtime/concurrency.cpp`)

- One global `g_io` (`io_context`); `nova_run()` runs it on N threads (work-stealing). Coroutines
  **migrate** threads across suspends.
- Because of migration, the coroutine bookkeeping is **shared and mutex-guarded**: `g_corostates`
  (+`g_corostates_mu`), `g_waiters` (+`g_waiters_mu`), `g_heldargs` (+`g_heldargs_mu`), plus a per-
  `CoroState` mutex. Every schedule/lookup takes a global lock.
- Thread-safety within a coroutine's ops comes from `CoroState.strand = make_strand(g_io)` — one strand
  per coroutine = per socket. **This is the reuse limiter.**
- `nova_thread_id()` = worker index (0 = main, 1..N−1 pool); Nova's per-thread lock-free pools key off it.

## Target state

- N reactors, each `{io_context io; std::thread; int id;}`, one pinned thread each, **N = max(1,
  hardware_concurrency() − 1)** (cap 16; `NOVA_THREADS` overrides).
- A coroutine is **assigned to one reactor at creation and never migrates**. All its resumes, socket ops,
  and timers post to *its* reactor's executor.
- Because each reactor is single-threaded, **strands are unnecessary** — the io_context's own executor
  serializes everything on it. `CoroState.strand` → the owning reactor's executor.
- The coroutine maps become **per-reactor `thread_local`** (`g_corostates`, `g_waiters`, `g_heldargs`) →
  the three global mutexes and the per-CoroState mutex are **deleted** (only ever touched by the owning
  reactor thread).
- Accept fan-out via **`SO_REUSEPORT`**: each reactor binds its own listener on the server port; the
  kernel load-balances new connections; an accepted connection stays on the reactor that accepted it.
- Connection pools stay per-reactor lock-free (already keyed by `nova_thread_id()` = reactor id) → the
  proxy reuse gate is **lifted** (`Backend.reuse = true` always).

`NOVA_THREADS=1` ⇒ exactly one reactor ⇒ **behaviorally identical to today** → the built-in rollback.

---

## Phases (each independently buildable + gated; async/TLS/timeout gates 113/114/115 are the net)

### P0 — Reactor abstraction, single reactor (no behavior change)
Introduce `struct Reactor { io_context io; int id; }` and a `g_reactors` vector; route everything through
`g_reactors[0].io` instead of `g_io`. Keep N=1. **Prove:** full suite + ASAN identical. This is pure
plumbing — isolates the mechanical `g_io → reactor.io` substitution from any semantic change.

### P1 — Coroutine → reactor affinity (strands STAY) ✅
CORRECTION found while implementing: strands **cannot be dropped at P1**. Today N threads share ONE
io_context and the strand is what serializes each coroutine's ops across those threads; dropping it before
reactors are single-threaded (P3) would race. So P1 only adds the *affinity*, and routes the strand
**through the reactor**:
- `thread_local int g_reactor_id` (the reactor the current worker serves; 0 in P0/P1; per-reactor in P3).
  Distinct from `g_nova_tid` (thread index) — they coincide only in P3 (one thread per reactor).
- `CoroState` gains `int reactor_id = g_reactor_id` (captured at creation, never changed); the strand is
  built from `g_reactors[reactor_id]->io` instead of `g_io` — identical while there is one reactor.
- `spawn`'s child CoroState is created on the parent's thread, so it **inherits the parent's reactor**
  automatically (no cross-core spawn).
- The 9 `bind_executor(state->strand, …)` sites are unchanged — they already route through the strand,
  which now comes from the right reactor.
- Once P3 makes each reactor single-threaded, a strand on a one-thread io_context is a **free no-op**;
  *dropping* it is then an optional micro-opt, not a correctness step.
- **Proven:** N=1 identical — native 177/177, ASAN clean.

### P2 — Per-reactor thread_local state maps; delete global mutexes
- `g_corostates`, `g_waiters`, `g_heldargs` → `thread_local` per reactor thread. Delete `g_corostates_mu`,
  `g_waiters_mu`, `g_heldargs_mu`, and the per-`CoroState` mutex (a state is only touched by its reactor).
- **Prove:** N=1 identical + ASAN clean (thread_local teardown ordering — mind the "OS reclaims on exit"
  note; do NOT destruct maps that pending I/O still touches). This is the highest-ASAN-risk phase → land it
  alone.

### P3 — Multi-reactor drive: N = cores − 1
- `nova_run()` starts N reactors, each `io.run()` on its pinned thread (`g_nova_tid = reactor id`); the
  main thread drives reactor 0 (or joins). `nova_worker_count()` = N.
- Block-drive (`nova_run` for the sync→async boundary) drives all N until drained.
- **Prove:** the async runtime gate (multi-core 8-task parallelism) still speeds up; gates 113/114/115
  green across reactors; ASAN clean. Benchmark note: **separate hosts** — single-box proxy+backends+load
  is too noisy (run-to-run 77↔3700 rps observed).

### P4 — SO_REUSEPORT accept fan-out
- Server listen path: each reactor binds its own `tcp::acceptor` with `SO_REUSEPORT` on the port; each runs
  its own accept loop; accepted conn's coroutine gets that reactor's id.
- `App.configureServer` / the listen entrypoint sets up N listeners.
- **Prove:** live server accepts across reactors (log the accepting reactor id per connection); an existing
  server gate stays green.

### P5 — Lift the pooling reuse gate
- `src/std/net/proxy.nova`: `Backend.reuse = true` unconditionally (per-reactor pools are single-threaded);
  remove the `nova_worker_count() == 1` guard. Add a gate: multi-reactor keep-alive reuse across requests
  on the same reactor (round-robin A,B,A with reuse, N>1). This is the payoff — multi-core pooled proxy.

### P6 — Cross-reactor primitives (only what breaks)
- Audit actors/channels (`concurrency/*`) for cross-reactor sends. A channel `send` from reactor i to a
  coroutine on reactor j needs a **cross-reactor post** (`post(reactors[j].io, resume)`) — the ONE place a
  handle crosses threads, so that post is the synchronization point (Asio's post is thread-safe). Keep it
  minimal and explicit; share-nothing's whole point is that this is rare.
- **Prove:** the actor gate (118/120) + a cross-reactor channel test.

---

## Risk register

| Risk | Phase | Mitigation |
|------|-------|------------|
| thread_local teardown / UAF on shutdown | P2 | leak-on-exit (as the current code already does for the global maps); ASAN gate alone on P2 |
| a handle crossing reactors without a post (data race) | P1/P6 | affinity is set once and asserted; the ONLY cross-reactor path is the explicit `post` in P6 |
| TLS memory-BIO assuming the old strand/executor | P1 | TLS pump must use the coroutine's reactor executor; gate 114 (async_tls) is the check |
| timer (deadline) on the wrong reactor | P1 | `steady_timer` constructed with the coroutine's reactor executor; gate 115 |
| accept thundering-herd / uneven load | P4 | SO_REUSEPORT (kernel balances); measure per-reactor accept counts |
| benchmark noise hides regressions/wins | P3/P5 | separate hosts; fixed core pinning; report per-reactor throughput |

## Rollback
`NOVA_THREADS=1` → one reactor → today's behavior exactly. Every phase preserves this, so a regression at
any phase is bisectable and single-reactor stays a safe fallback.

## Out of scope (Path B territory, do NOT pull in here)
io_uring / kqueue / IOCP custom reactor; leaving Boost; Senders/Receivers. Path A stays on Asio's reactor.
The executor-agnostic TLS+timer refactor (the enabler for a future io_uring backend) can ride P1's executor
threading but the reactor swap itself is a separate project.

## First concrete step
P0 + P1 together behind `NOVA_THREADS=1` (no observable change), landing the `Reactor` struct, the
`g_io → g_reactors[0].io` substitution, `CoroState.reactor_id`, and strand→reactor-executor — the
mechanical spine, fully gated identical, before any multi-reactor semantics.
