# Coroutine Handle Generations: Killing the Stale-Resume Use-After-Free

## Status

PROPOSED (2026-08-03). Root cause proven, an address-liveness attempt tried and proven insufficient
(reverted, not merged), correct design specified below. Not yet implemented. This is a crown-jewel-runtime
change with high blast radius; it must land as a dedicated, fully-gated effort. See the paired memory note
`nova-conn-byvalue-async-arg-crash` for the live-debugging trail.

## Problem

A coroutine handle is a raw frame ADDRESS (an LLVM coroutine frame pointer). `raw_coro_resume(h)` calls the
resume function stored at `h[0]`; `raw_coro_done(h)` reads `h[0] == nullptr`. When a coroutine finishes, its
frame is freed (`nova_coro_release` / the detached-reap in `reactor_finish`) and the allocator recycles the
address for the next coroutine.

The runtime stores a handle as a bare address in several places that OUTLIVE the frame:
- reactor ops (`net/eventloop_*.makeOp` stores `token` at op offset [24]),
- the run queue `g_rq` (nested awaits, waiters, spawns),
- the waiters map `g_waiters` (child -> parent),
- reactor timers (`nova_reactor_set_timer(handle, ms)`),
- reactor event `udata` (per backend).

A STALE reference to a freed address then gets resumed. Two sub-cases:

1. reaped-not-reused: the address is still free. `raw_coro_done`/`raw_coro_resume` read freed memory ->
   SIGBUS (or, if the freed bytes happen to look "done", a silent skip).
2. reaped-AND-reused (the one that actually bites): the address now holds a DIFFERENT live coroutine. The
   stale reference resumes the wrong coroutine, double-advancing its state machine; it later finishes early,
   is reaped, and its real completion then resumes a freed frame -> SIGBUS.

### Reproduction

`/tmp/connpass.nova` shape (needs a live BTreeDB on 127.0.0.1:3009):

```
async fn doQuery(conn: btreedb.BTreeConnection): int {
    let none = list.List<DbValue>();
    let rs = await conn.query("SELECT 1", none);   // socket I/O in doQuery's coroutine
    return rs.rowCount();
}
async fn run(...): void {
    let conn = await driver.connect("127.0.0.1:3009");  // socket created in run's coroutine
    let n = await doQuery(conn);                          // conn used from a DIFFERENT coroutine
    conn.close();
}
```

Crash: `SIGBUS` at `nova_reactor_resume + N` (which inlines `reactor_pump`), fault address in the code
segment (a garbage resume-fn pointer). Connect+query in the SAME coroutine (`/tmp/connIn.nova`) is fine; the
extra coroutine level here deepens the driver's nested-await chain (`query -> readFrame -> fill -> recvInto`,
each an `async fn` = a coroutine that is born, submits an op, completes, and is reaped in rapid succession),
which drives the recycle-then-stale-resume pattern.

### Why it matters

Single-strand driver use is safe (e.g. `SqlConfigStore.get` does `self.conn.query` on one strand, and the
whole reactor-server corpus passes). The bug BITES a connection POOL shared across concurrent request-handler
coroutines: connect on one coroutine, hand the connection to another to do I/O. That is a first-class server
pattern, so this blocks connection pooling on the Nova reactor.

Note this is a SEPARATE bug from the BTreeDB server WAL data race fixed in `btree@6600c4d` (that was a
missing lock on the server side; this is a client-side Nova-runtime scheduler issue).

## What was tried and why it cannot work

Attempt: make the existing per-batch `g_batch_reaped` guard into a PERSISTENT address dead-set (stop
clearing it each `nova_reactor_batch_begin`), always-track reaps, add a check to `reactor_pump` (only
`nova_reactor_resume` had one), and erase-on-rebirth (`mark_reborn`) wherever a handle is scheduled.

It does not fix the reaped-and-reused case, and the trace shows precisely why:

```
finish h=X            X finishes
mark_reaped h=X       X's frame freed; X recorded dead (set len 31)
sched->rq h=X         a STALE schedule of the freed X arrives
                      -> mark_reborn ERASES X's dead mark here (the fatal step)
pump resume h=X       raw_coro_resume on the freed frame -> SIGBUS
```

At the `sched->rq`, the runtime cannot tell a genuine REBIRTH (a new coroutine malloc'd at X) from a STALE
reference to the freed X: both are the bare address `X`, and `raw_coro_done(X)` on freed memory is
unreliable. Address identity is ambiguous the moment a frame is freed. No address-only scheme (dead-set,
live-set, per-batch guard) can disambiguate. DO NOT retry any address-liveness variant.

## Design: generation-tagged tokens

Keep the frame ADDRESS as the thing you resume (no change to the codegen, `currentCoro()`, or the LLVM frame
layout). Add a per-address GENERATION that increments each time a frame at that address is reaped. A stored
token captures the generation at store time; a resume checks the stored generation against the current one
for that address and skips on mismatch. A recycled address has a strictly higher generation, so a stale
token is unambiguously rejected while the live coroutine at that address resumes normally.

### Generation table (C++, `concurrency.cpp`)

```cpp
// address -> current generation. Bumped on every reap. A missing address reads as generation 0.
thread_local std::unordered_map<long long, uint64_t> *g_coro_gen = nullptr;

static inline uint64_t coro_gen(long long h) {
    if (!g_coro_gen) return 0;
    auto it = g_coro_gen->find(h);
    return it == g_coro_gen->end() ? 0 : it->second;
}
extern "C" unsigned long long nova_coro_gen(long long h) { return coro_gen(h); }

// Call at EVERY reap (frame free) site, immediately before the destroy call.
static inline void bump_gen(long long h) {
    if (!g_reactor_mode) return;
    if (!g_coro_gen) g_coro_gen = new std::unordered_map<long long, uint64_t>();
    (*g_coro_gen)[h] += 1;
}
```

The table is per reactor thread (single reactor thread owns it; the share-nothing multi-core model gives
each thread its own reactor, so no lock). Unlike the address dead-set, the generation table only ever GROWS
per distinct address; bound it the same way (size backstop clear, or better, prune an entry when its address
is handed to a brand-new frame -- but pruning is unnecessary for correctness and can be a follow-up). A
`uint64_t` generation never realistically wraps.

### Reap sites (bump the generation) -- all found this session

- `nova_coro_release(handle)` (the awaiter reaps a child) -- already calls the old `mark_reaped`; replace
  with `bump_gen(handle)` before the destroy.
- `reactor_finish` detached-reap branch -- same.
- `nova_sched_schedule_detached` already-done branch -- currently reaps WITHOUT any mark; add `bump_gen`.
  (This missing mark is a pre-existing gap.)
- Audit `nova_run_root` / the block-drive root reaps: a root frame is driven directly, not by a stored
  token, so it is not strictly required, but bump it for uniformity and cheap insurance.

### Token-storage sites (capture the generation) and resume sites (check it)

1. Reactor OPS. Widen the op record: add `gen i64` at offset [40], `OP_SIZE` 40 -> 48 (all four
   `net/eventloop_*` backends declare this layout, keep them in sync). `makeOp(op, kind, fd, buf, len,
   token)` captures `gen = nova_coro_gen(token)` and writes it at [40]; add `opGen(op)`. At completion in
   each backend's `pollComplete` (where it reads `opToken` and marks the op done): if
   `nova_coro_gen(opToken(op)) != opGen(op)`, the submitting coroutine was reaped since submit -> DROP the
   completion (do not deliver the token to the resume path; free/abandon the op per that backend's rules).
   This is the primary fix: it stops a stale socket completion from ever reaching `nova_reactor_resume`.

2. Run queue `g_rq`. Change the element type from `long long` to `struct { long long h; uint64_t gen; }`.
   `nova_sched_schedule(h)` and the waiter-push in `reactor_finish` capture `coro_gen(h)`. `reactor_pump`
   pops `{h, gen}` and skips if `coro_gen(h) != gen` (in addition to the existing `raw_coro_done` check).

3. Waiters map `g_waiters`. Store `{parent_handle, parent_gen}`; when `reactor_finish` takes the waiter to
   schedule it, carry the captured gen into the `g_rq` push (item 2). (A parent is normally alive when it is
   a waiter, but capturing keeps the invariant uniform and closes the recycle window.)

4. Timers. `nova_reactor_set_timer(handle, ms)` -- the timer's completion also resumes `handle`. Capture
   `coro_gen(handle)` with the timer and check it when the timer fires (per backend). The read-deadline path
   (`recvIntoDeadline`) is the consumer.

5. Reactor `udata` / direct `nova_reactor_resume(token)`. `nova_reactor_resume` already receives a bare
   token from the pump loop. With item 1 in place, a stale SOCKET token never reaches it. For defense in
   depth, `nova_reactor_resume` can also take an optional expected-gen and skip on mismatch, but items 1-4
   remove the sources, so this is optional.

### Invariant

Every place that stores a coroutine handle for LATER resumption stores `{address, gen=coro_gen(address)}`.
Every resume validates `coro_gen(address) == stored_gen` before touching the frame. Reaping bumps
`coro_gen(address)`. Therefore a token can only resume the exact coroutine instance that stored it; a reaped
or recycled address is rejected. This is the property the address dead-set lacked.

## Files touched

- `src/runtime/concurrency.cpp` -- generation table + `nova_coro_gen`; `bump_gen` at reap sites; `g_rq` and
  `g_waiters` element types; gen checks in `reactor_pump` (and optionally `nova_reactor_resume`); remove the
  now-subsumed per-batch `g_batch_reaped` machinery (or keep as a fast-path, but the generation table is
  authoritative).
- `src/std/net/eventloop_darwin.nova`, `eventloop_linux.nova`, `eventloop_windows.nova` -- `OP_SIZE`
  40 -> 48, `makeOp` gen capture, `opGen`, and the gen check in each backend's completion loop. The
  io_uring backend shares op records with IOCP; keep both in step.
- `src/std/net/reactorio.nova` -- no signature change (makeOp gains the capture internally); confirm the
  timer arm/cancel path carries a gen.
- `src/runtime/nova_abi.h` -- declare `nova_coro_gen`.

No codegen change: `coroStart`, the await lowering, and `currentCoro()` keep emitting bare addresses; the
generation is captured and checked entirely inside the runtime + eventloop layer.

## Test and gating plan

Gate on the FULL matrix; a missed capture/check reads as either a HANG (a live coroutine skipped) or a
surviving crash, so partial validation is worthless here.

1. `conformance/run.sh` (or `-j`) on native -- 180+ cases, 0 regressions.
2. The reactor corpus on EACH backend, one at a time (they starve each other if concurrent):
   kqueue (macOS), epoll and io_uring (Linux), IOCP (Windows). Target the current baselines
   (see `lang/CLAUDE.md`: ~225 reachable per backend; the DB-driver cases need `packages/`).
3. `conformance/run.sh --asan` (329) -- ASAN is the authority for the use-after-free class; it must be
   clean. Note ASAN cannot link reactor programs today (the asan runtime lacks `nova_op_alloc`); wire the
   reactor objects into the asan build, or validate the reactor path with `NOVA_CRASH_TRACE` + the stress
   repros instead, and state which.
4. The direct repros: `/tmp/connpass.nova`, `/tmp/connU.nova` must PASS; `/tmp/locq.nova`,
   `/tmp/connIn.nova` must stay passing.
5. The 60-concurrent-client BTreeDB stress (the `stressclient` from this session) -- server AND clients
   clean, no SIGBUS on the client side.

Diagnostics that cracked this: `NOVA_TRACE=<path>` (per-coroutine schedule/finish/resume log) and
`NOVA_CRASH_TRACE=1` (backtrace + fault address on an alternate signal stack). macOS has no `timeout`; use
`gtimeout` or the perl-alarm the harness already uses.

## Estimated size

Multi-day. The mechanical surface is moderate (one C++ table, four eventloop backends kept in sync, two
scheduler container element types), but the risk is in COMPLETENESS: every token-storage site must capture
and every resume site must check, or async hangs. Budget most of the time for the cross-backend reactor
gating, not the edit.
