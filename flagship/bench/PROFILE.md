# Where the flagship's request time actually goes

A CPU profile of the `web.App` server under load, taken to decide the real question:
is Asio (the reactor) the bottleneck, or is it what sits above it? The short answer
is the second, and by a wide margin.

## Method

`sample` (macOS, no instrumentation) on the release server (`headtohead/kyte/server.ky`,
uncached path) for 10 seconds while `oha -c 128` saturated it. Samples are wall-clock
stack captures across all threads, so threads parked in the reactor show up as `kevent`.

## Headline: the reactor is idle, not busy

`kevent` (the kqueue wait) accounted for **50,807** samples against **8,116** non-idle
on-CPU samples, that is, the reactor threads spend the overwhelming majority of their time
**parked waiting for I/O**, not working. The Asio scheduler machinery itself is only about
6 percent of on-CPU time. Replacing the reactor with a hand-rolled or tokio-style loop
would therefore target roughly a 6 percent slice. It is not where the time goes.

## Where the on-CPU time goes (8,116 non-idle samples)

| Category | % of on-CPU | What it is |
|----------|------------:|------------|
| syscall send/recv | 28.7 | one `sendto` + one `recvfrom` per request, unbatched |
| malloc/free | 22.3 | per-request heap churn |
| ARC retain/release + destructors | 12.2 | refcount traffic on request strings and structs |
| locking (pthread / std mutex) | 8.8 | mostly the CoroState map and allocator mutexes |
| per-coroutine state + scheduling | 7.8 | a `shared_ptr<CoroState>` in a mutex-guarded hash map, per connection |
| HTTP parse + framework | 7.3 | `Request_fromString`, a `Map<string,string>` of headers per request, `Response_serialize`, mediator dispatch |
| Asio scheduler machinery | 6.0 | the reactor glue |
| ARC audit hooks | ~1 to 2 | `audit_alloc` / `audit_free`, still compiled into the `--release` binary |
| other | 5.8 | |

Grouping these: **memory management (malloc/free + ARC + audit) plus the per-coroutine
state churn plus the locking around them is roughly half of all on-CPU work.** The syscall
pair is the next ~29 percent. The actual HTTP parsing and framework dispatch is only ~7
percent, and the reactor is ~6 percent.

## What this says about "should we build a tokio-style runtime"

It says no, not as the first move. A tokio-style rewrite replaces the reactor and the task
scheduler, which together are the ~6 percent that is already fast and mostly idle. The
bottleneck is allocation, refcount traffic, per-coroutine state, and unbatched syscalls,
all of which are fixable **on** Asio. The earlier tradeoff note reached the same conclusion
from coarser evidence ("the bottleneck is IO plus coroutine-scheduling, not the reactor");
this profile confirms it and names the specific costs.

## Status

Pass 1 done (commit lands with this file): removed the per-allocation audit guard (item 3)
and cut the eager per-request map capacities (a first slice of item 1). Measured result:
Kyte 48,737 -> 55,409 rps at c=64 (+14 percent), corpus 180/180 and ASAN 329/329 green.
The larger levers (2, 4, and the rest of 1) remain open.

## Ranked, actionable wins (all on the current runtime, no rewrite)

1. **Kill per-request allocation (biggest lever, ~35 percent).** PARTIALLY DONE (map
   capacities cut). Still open: parse headers in place as buffer slices, per-request arena. The request path builds a
   `Map<string,string>` for headers (a hash map allocated per request), splits and trims
   strings, and allocates a `Request`, a `ValueSource`, and the response string, each
   refcounted and freed. Parse headers in place as slices into the read buffer, keep them
   in a small fixed array rather than a hash map, and use a per-request arena. This attacks
   malloc/free, ARC, and part of the locking at once.
2. **Fix the per-coroutine CoroState (~8 percent plus much of the 9 percent locking).** It
   is a `shared_ptr<CoroState>` in a global, mutex-guarded `unordered_map<long long, ...>`,
   allocated, hashed, and erased per connection. Make it per-reactor (thread-local, so no
   lock) and pool or inline it to remove the heap allocation, the shared_ptr refcount, and
   the mutex. A blocking mutex in the async hot path has already been observed to cost
   dramatically here.
3. **Compile out the ARC audit hooks in release (~1 to 2 percent, free).** DONE. The cost
   was not the hooks themselves but the function-local `static` guard in `audit_enabled()`
   and `dump_enabled()` (a thread-safe-static check on every alloc and free, which also
   blocked inlining); changed to a load-once global.
4. **Batch syscalls (~29 percent).** Coalesce headers and body into a single `writev`, and
   use larger receive buffers, to cut the send/recv count per request.

Items 1 through 3 are runtime and framework hot-path engineering; item 4 is I/O batching.
None of them is a change of reactor, runtime, or memory model. That is the useful outcome
of profiling before rewriting.

See `profile-top-of-stack.txt` for the raw leaf hotspots.
