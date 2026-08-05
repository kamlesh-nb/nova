# Coroutine Handle Generations: Killing the Stale-Resume Use-After-Free

## RESOLVED (2026-08-03): root cause found + permanent fix

`connpass` is FIXED. It was never the reactor, token identity, ARC refcounting, or coroutine frame spill (all
ruled out across the passes below). The root cause: an implicit, unsound TRAIT -> CONCRETE narrowing at a
call argument.

- `BTreeDriver.connect` returns `Connection` (the trait), so `let conn = await driver.connect(...)` is a
  TRAIT OBJECT: a fat pointer {struct_ptr, vtable} (the IR shows `connect` allocating 16 bytes + a
  `nova_retain` of the underlying struct).
- connpass then passes `conn` to `doQuery(conn: BTreeConnection)` -- a CONCRETE parameter. The codegen
  already implicitly WIDENS a concrete arg to a trait param (awaitedCallHandle constructs a trait object),
  but it did NOT handle the reverse. So the raw fat pointer was passed AS the concrete struct: the callee
  read `self.reader` as the fat pointer's vtable slot and ran a mismatched ARC destructor -> the connection
  struct was freed while `fill` (deep in the nested-await chain) still read `conn.reader` -> `r`=0xfc ->
  SIGBUS on resume. connIn (one coroutine) never splits the value into a concrete-typed slot, so it is fine.
  Confirmed by flipping `doQuery`'s param to `Connection`: connpass passes cleanly.

FIX (src/codegen/expressions.zig, `awaitedCallHandle`): mirror the existing concrete->trait widening. When a
call argument is a TRAIT object and the parameter type is a CONCRETE struct, DOWNCAST -- load `struct_ptr`
from the fat pointer -- before passing. Borrow semantics (no retain): the trait object still owns the struct.
This completes the codegen's trait/concrete conversion handling (it did widening but not narrowing).
connpass now passes (regular AND `--asan`); offline conformance 226/226.

### Completeness pass (2026-08-03): the checker now REJECTS the narrowing (both call shapes)

The codegen downcast (f124052) makes the implicit conversion sound-of-layout, but the RIGHT fix is to reject
it at the type checker so the mistake is a clear compile error instead of a silent reinterpretation. Two
enabling gaps were closed and the rejection landed:

1. INFERENCE FIX (`resolveExprType`): a module-qualified constructor `module.StructName(...)` now resolves to
   `StructName`. Previously the object (`btreedb`) is a module, not a typed value, so it resolved to null and
   any value derived from such a constructor (e.g. `let d = btreedb.BTreeDriver()`) stayed untyped -- which is
   exactly what blocked catching `await d.connect()` narrowing. Fixed by: if `resolveExprType(object)` is null
   and the field names a known struct, return that struct type.

2. REJECTION (`rejectNarrowingArgs`, shared helper): for each (arg, param) pair where the parameter is a
   CONCRETE struct and the argument resolves to a TRAIT, emit an error requiring an explicit `as` downcast or a
   trait-typed parameter. Wired at BOTH call shapes -- free-function calls (`f.params`) AND method calls
   (`obj.method(...)`, resolving the receiver's struct + method and skipping the implicit `self` at param 0).
   Concrete -> trait WIDENING stays allowed (that is the sound direction). `let x: Concrete = traitVal` was
   already rejected by the existing `assignable` check.

Validated: connpass (concrete free-fn param) REJECTED with a clear message; a method-call narrowing repro
REJECTED; the connpass_trait / method-widening positives still compile; offline conformance 227/227 (includes
the new `expect_fail/trait_to_concrete_narrowing.nova` regression guard); orchestrator suite 13/13; the 15
async/trait cases ASAN-clean. The codegen downcast (f124052) is kept as defense-in-depth for any narrowing the
checker does not yet reach (e.g. returns / struct-field init narrowing -- follow-on).

FOLLOW-ONS still open: extend the rejection to RETURN positions (returning a trait where the fn declares a
concrete type) and STRUCT-FIELD init; audit the SYNC call-arg codegen path for a defense-in-depth downcast
symmetric to f124052 (async-only today) in case a future narrowing site escapes the checker.

## Status (historical -- superseded by RESOLVED above)

PARTIALLY IMPLEMENTED on branch `coro-handle-generations` (2026-08-03, WIP commit, NOT merged). The
generation infrastructure below is built for the kqueue backend and is NON-REGRESSING (offline conformance
226/226, async/reactor subset 21/21), but it does NOT yet fix the `connpass` cross-coroutine repro. See
"Implementation finding" at the end: generations are NECESSARY but NOT SUFFICIENT here; there is an
additional, deeper await-lowering bug that produces a stale `nova_sched_schedule` of an already-reaped
handle. An earlier address-liveness attempt was tried and proven insufficient (reverted, not merged). This
is a crown-jewel-runtime change with high blast radius; it must land as a dedicated, fully-gated effort. See
the paired memory note `nova-conn-byvalue-async-arg-crash` for the live-debugging trail.

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

`/tmp/connpass.nova` shape (needs a live NovaDB on 127.0.0.1:3009):

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

Note this is a SEPARATE bug from the NovaDB server WAL data race fixed in `btree@6600c4d` (that was a
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
5. The 60-concurrent-client NovaDB stress (the `stressclient` from this session) -- server AND clients
   clean, no SIGBUS on the client side.

Diagnostics that cracked this: `NOVA_TRACE=<path>` (per-coroutine schedule/finish/resume log) and
`NOVA_CRASH_TRACE=1` (backtrace + fault address on an alternate signal stack). macOS has no `timeout`; use
`gtimeout` or the perl-alarm the harness already uses.

## Estimated size

Multi-day. The mechanical surface is moderate (one C++ table, four eventloop backends kept in sync, two
scheduler container element types), but the risk is in COMPLETENESS: every token-storage site must capture
and every resume site must check, or async hangs. Budget most of the time for the cross-backend reactor
gating, not the edit.

## Implementation finding (2026-08-03): generations are necessary but NOT sufficient

The kqueue-backend generation infrastructure above was implemented (branch `coro-handle-generations`, WIP
commit) and is non-regressing (offline 226/226, async/reactor 21/21), but `connpass` still crashes. Tracing
(`NOVA_TRACE`) shows why, and it changes the picture:

- The op-completion gen gate (`Poller.poll`) is a correct no-op here: a `recvInto` coroutine is never reaped
  while its op is pending (it is suspended ON that op and only its completion resumes it), so no stale OP is
  ever produced to drop. `skip-stale-gen` in `Poller.poll` and the op-token gate never fire for this repro.
- The crash is in `reactor_pump`: a handle X finishes (`finish h=X`), and LATER `sched->rq h=X` +
  `pump resume h=X` -> raw_coro_resume on the freed frame -> SIGBUS. The run-queue gen gate does NOT catch
  it (`skip-stale-gen` count 0), because the stale `nova_sched_schedule(X)` happens AFTER X was reaped, so
  it captures the already-BUMPED generation; the entry's captured gen equals the address's current gen at
  pop, so it is not skipped.

So the real defect is UPSTREAM of the queue: something calls `nova_sched_schedule` with a handle whose frame
was already reaped. Generations cannot gate this, because the capture happens post-reap. The await lowering
(`src/codegen/expressions.zig` `buildAwaitExpr` / `awaitedCallHandle`) schedules each child exactly once and
reaps it once, so per-await it is clean; the stale schedule comes from the interaction of that lowering with
rapid frame-address RECYCLING down the driver's deep nested-await chain, specifically on the trait-async
dispatch path (`conn.query` is a `Connection`-trait vtable async call -- `buildTraitVtableCall`), and only
when the connection is used from a DIFFERENT coroutine than created it (connIn, same-coroutine, is fine).

Remaining investigation (the actual blocker, a coroutine-frame-lifecycle bug, not a token-identity one):
1. Instrument to find the FIRST stale resume in the trace (the first `resume h=H` where H was `finish`ed
   without a genuine rebirth) -- the cascade of recycled-address schedules flows from that one.
2. Focus on `buildTraitVtableCall` (async trait-method await) + `awaitedCallHandle`: does the child handle it
   returns/schedules ever alias a frame that is reaped on a different path, or get scheduled twice? Check the
   immediately-completing-child case (child runs to done inside `awaitedCallHandle` before
   `nova_sched_schedule`, which then no-ops on `raw_coro_done`, leaving the waiter chain in an odd state).
3. Consider whether the fix belongs in the codegen (capture the child's gen at await time when it is known
   live, and pass it to `nova_sched_schedule` so a post-reap re-schedule carries the OLD gen and is gated) --
   this is the codegen-touching variant the base design hoped to avoid, and it is the natural home if the
   stale schedule cannot be eliminated at its source.

The generation infrastructure remains the correct FOUNDATION (it closes the reaped-after-enqueue and stale
-op windows for other workloads) and should be kept, but this frame-lifecycle bug must be fixed on top of it
before `connpass` / connection-pooling works.

## Decisive redirection (2026-08-03, second pass): it is NOT a stale-frame resume at all

A precise live-frame diagnostic settled it. Added a temporary exact live-set (born at
`nova_register_waiter(child)` + `nova_reactor_detach`; dead at reap) plus a log of the resume-fn pointer
`h[0]` immediately before every `raw_coro_resume`. Result on the connpass crash:

- The crashing handle is IN the live set (`live_is` true): it was born and not reaped. NO "STALE RESUME"
  event ever fires.
- Its resume-fn pointer `h[0]` is a VALID code address (same text-segment range as every other coroutine's),
  not garbage. All generations match (`egen == cur`).

So the frame being resumed is a LIVE, correctly-initialized coroutine, and the fault happens INSIDE its body
(or a nested resume it triggers), not at the resume dispatch. This rules out the entire token-identity /
use-after-free-of-a-freed-frame premise that motivated this whole document, INCLUDING the earlier "stale
`nova_sched_schedule`" reading (that address WAS a live recycled coroutine, resumed with matching gen; the
crash is deeper in its execution).

The likely real cause is CROSS-COROUTINE DATA CORRUPTION of the connection, not the scheduler:
`BTreeConnection` is passed BY VALUE into `doQuery`, copying its `BtReader` (which owns a raw `buf: ptr` via
a `delete()` destructor, see memory `nova-ptr-field-arc-ownership`) and its `AsyncStream` (socket fd) into
`doQuery`'s coroutine frame. When `doQuery` drives I/O on that copied reader/socket while `run` still holds
the original, the shared raw `buf` / socket state is read/written/freed from two owners, corrupting the data
the coroutine body then dereferences. connIn (connect+query in ONE coroutine) is fine because there is a
single owner; connpass splits ownership across two coroutine frames. connP (pass conn, do NOT use it in the
callee) is also fine.

IMPORTANT CONSTRAINT from connP: a callee that merely RECEIVES `conn` by value and returns (its frame is
created and destroyed) does NOT crash. So it is NOT a clean "callee frame's destructor frees `buf` while the
caller still owns it" double-free -- if it were, connP would crash too. The crash needs the callee to
actually DRIVE I/O on the copied reader/socket (call `conn.query`). So the mechanism is subtler than a
by-value-arg destructor double-free: likely aliased/interleaved mutation of the shared `BtReader` state
(`buf`, `pos`, `len`) or the socket across the two frames, or an ownership edge that only triggers once the
reader is used. Do not assume the pure double-free shape; let ASAN name it.

### ASAN CONFIRMED it (2026-08-03, third pass) -- the smoking gun

`NOVA_ASAN=1 nova test /tmp/connpass.nova` (the asan runtime just needed a fresh `NOVA_ASAN=1 zig build`;
`runtime.cpp` already includes `core.cpp`, so `nova_op_alloc`/`nova_op_free` are present -- the earlier link
failure was a stale asan lib). Result:

```
AddressSanitizer: BUS ... in ..packages_nova-novadb_src_btreedb_fill.resume+0x250
  #0 btreedb_fill.resume        <- BtReader.fill(), resuming after its await
  #1 test_connpass
Register x[1] = 0xfcfcfcfcfcfcfcfc   <- ASAN heap-FREED poison
```

So on resume, `fill`'s `r` (a `BtReader`, a ref-counted heap struct) points at FREED memory: the connection's
reader was ARC-freed while `fill` was parked on `await r.io.recvInto(...)`. This is an ARC OVER-RELEASE of the
connection / its `BtReader` on the by-value-async-arg path, NOT the reactor and NOT token identity. It is
triggered specifically by the extra by-value `conn` pass (run -> doQuery); connIn (single coroutine) keeps a
stable owner and is fine.

Three synthetic non-reactor repros did NOT reproduce it (a ptr+dtor struct passed by value into an async fn
across a real `asyncio.sleep` park, incl. awaiting a method on a nested field), so the trigger is a subtle
combination in the real driver: `BTreeConnection{io, reader, prepared: List}` returned from an async
`connect()`, `query` awaiting `sendFrame(self.io)` THEN `readFrame(self.reader)`, `List<DbValue>` params,
and the 5-deep nested-await chain. Use connpass-under-ASAN as the verification harness for the fix.

### It is NOT an ARC refcount bug -- it is coroutine-frame corruption (2026-08-03, fourth pass)

Two more diagnostics narrowed it decisively AWAY from ARC:
- The runtime's built-in double-release detector (`NOVA_ARC_AUDIT=1 NOVA_ARC_DUMP=1`,
  `check_release_of_dead` in alloc.cpp) reports NOTHING on connpass -- no double release, no release-of
  -untracked. So the BtReader is not over-released.
- Instrumenting `nova_release` to log every destructor that runs (dladdr on the dtor fn ptr) shows the freed
  destructors are `__destruct_ReactorStream` (x8, the per-recvInto temporaries), `__destruct_BtFrame` (x7),
  `__destruct_BtCursor` (x2), etc. -- but `__destruct_BtReader` NEVER FIRES. The BtReader is never ARC-freed
  via its destructor.

Yet ASAN shows `fill`'s `r` is `0xfcfcfcfc` (ASAN heap-FREED poison) on resume. `0xfc` is specifically the
poison ASAN writes into FREED heap memory (fresh allocations get a different magic). So `fill`'s coroutine
frame slot for its by-value `BtReader` parameter `r` reads STALE freed-heap memory on resume: the parameter
was not correctly preserved across the `await r.io.recvInto(...)` suspend, and the frame slot was reused
from a recently-freed (poisoned) allocation without being re-materialized. This is a COROUTINE-FRAME
lowering bug for a suspended coroutine's by-value struct parameter, NOT an ARC over-release and NOT the
reactor. A synthetic with the same shape (by-value struct param, await a method on a nested field, use the
param after) PASSES, so the trigger is specific to the real driver's deep async chain (real socket
`recvInto` with its own nested awaits + ReactorStream temporaries; the 5-deep chain; `need`'s loop). Next
investigation is the LLVM-coroutine frame spill of struct-typed parameters across suspends
(`buildAwaitSuspend` + how params are stored in / reloaded from the coro frame; whether a struct param is
marked live-across-suspend). This is deep LLVM-coro territory; budget accordingly.

### CORRECTION (2026-08-03, fifth pass, IR-level): NOT a frame-spill bug. The connection (a TRAIT OBJECT) is freed.

Dumped the pre-CoroSplit IR (`__nova_test.ll`, written by the test path) and ran the LLVM coro passes
(`opt -passes='coro-early,cgscc(coro-split),coro-cleanup'`) to get `fill.resume`. Findings:
- The CoroSplit frame spill of `fill`'s `r` is CORRECT: `fill.resume` reloads `r` from the frame field
  `%r.reload.addr` (a GEP into the coro Frame), not a fresh stack alloca. So this is NOT a frame-spill bug
  (correcting the fourth-pass conclusion).
- On resume the frame is INTACT: `n` (the recvInto result, another frame field) reads a valid count (else
  `if (n<=0) return false` would fire and there would be no crash). Only `r`'s value is `0xfc`. So the
  reader POINTER stored at `fill` entry (`%0`) was ALREADY `0xfc` -- the reader is freed UPSTREAM, before
  `fill` is even called.
- `need` passes the reader POINTER straight to `fill` (`load %r; call fill(ptr)`), no struct copy. So the
  `0xfc` reader pointer propagates from higher up: `self.reader` read `0xfc`, i.e. the CONNECTION struct
  `conn` is freed and `self.reader` is an interior/loaded read of freed memory.
- `conn` is a `Connection` TRAIT OBJECT: `BTreeDriver.connect` returns `Connection` (the trait), so
  `let conn = await driver.connect(...)` is a fat pointer {struct_ptr, vtable}. No `__destruct_BTreeConnection`
  fires (named) under ASAN, but a `(nodtor)` free of a struct-sized object does -- the trait object's
  underlying struct is freed via the trait vtable destructor (anonymous, shows as nodtor), over-released on
  the by-value trait-object-async-arg pass (run -> doQuery). connIn (one coroutine, one owner) is fine.

FIVE synthetic repros now do NOT reproduce it (concrete struct by-value + real park; method-on-nested-field;
conn-returned-from-async; send-before-read; and a TRAIT OBJECT returned from async, passed by value into an
async fn, driving a deep await chain on a field). So the trigger needs the real driver's exact structure and
must be chased against connpass-under-ASAN with IR, not a synthetic.

WHAT TO DO NEXT: trace the reader/conn pointer's PROVENANCE through the full real chain in the IR
(run -> doQuery(conn) -> conn.query [trait vtable async] -> readFrame(self.reader) -> need -> fill), finding
where the trait object's underlying struct gets its extra release. Focus on the trait-object ARC on the
by-value-async-arg + trait-vtable-async-method path (memory: trait-object fat-pointer ARC, DB-seam trait ARC,
F5 arg-ownership). Interim WORKAROUND to unblock connection pooling: have the driver NOT return/pass the
connection as a trait object across coroutines (keep it concrete + single-strand), or hold an explicit extra
reference to `conn` for the duration. Harness = `NOVA_ASAN=1 nova test /tmp/connpass.nova`; opt-split recipe
above gives the post-CoroSplit IR.
2. Inspect how a struct with a raw `ptr` field + `delete()` destructor is copied when passed BY VALUE into an
   async fn: does the callee frame take an OWNING copy (so its destructor frees `buf` while the caller still
   owns it), or a borrow? The fix is almost certainly ARC/ownership at the by-value-async-arg boundary for
   destructor-bearing structs (relates to memory `nova-ptr-field-arc-ownership`, `nova-semantics-from
   -strings`, and the F5 arg-ownership work), NOT the reactor.
3. Only after the data-ownership bug is fixed, re-evaluate whether any residual scheduler stale-token issue
   remains that the generation work should cover.
