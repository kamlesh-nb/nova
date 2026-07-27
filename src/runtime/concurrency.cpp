// concurrency.cpp — Nova C++20 runtime: concurrency + program entry.
//
// CURRENT: synchronous v0 shim (spawn runs the fiber inline; channels are simple
// std blocking queues; entry calls __nova_main directly). This is stable and
// passes the (synchronous) corpus.
//
// The multi-threaded Boost.Fiber implementation (work-stealing scheduler +
// fiber-aware channels) is preserved in concurrency_boost.cpp.wip. It links and
// runs synchronous corpus programs sometimes but currently has a FLAKY hang
// (likely default fiber stack size / scheduler-setup) that needs debugger-level
// investigation before it can be switched on. Once fixed, swap it back in here.
#include "nova_abi.h"
#include <boost/asio.hpp>
#ifndef _WIN32
#include <sys/socket.h> // P4: SO_REUSEPORT / setsockopt
#endif
#include <cstdio>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_map>
#include <vector>

extern "C" long long __nova_main(void);

extern "C" {

// A Nova closure value is a heap box {fn_ptr, env} (A1). spawn unpacks and, for
// v0, runs it inline (synchronous).
void nova_concurrency_spawn(long long closure) {
    if (!closure) return;
    long long *box = reinterpret_cast<long long *>(closure);
    reinterpret_cast<void (*)(long long)>(box[0])(box[1]);
}
void nova_concurrency_sleep(long long ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ===== Channels (simple bounded blocking queue) ============================
namespace {
struct Channel {
    std::mutex m;
    std::condition_variable cv;
    std::queue<long long> q;
    int capacity;
};
} // namespace
long long nova_channel_create(int capacity) {
    auto *c = new Channel();
    c->capacity = capacity > 0 ? capacity : 1;
    return (long long)c;
}
void nova_channel_send(long long h, long long val) {
    if (!h) return;
    auto *c = reinterpret_cast<Channel *>(h);
    std::unique_lock<std::mutex> lk(c->m);
    c->cv.wait(lk, [&] { return (int)c->q.size() < c->capacity; });
    c->q.push(val);
    c->cv.notify_one();
}
long long nova_channel_recv(long long h) {
    if (!h) return 0;
    auto *c = reinterpret_cast<Channel *>(h);
    std::unique_lock<std::mutex> lk(c->m);
    c->cv.wait(lk, [&] { return !c->q.empty(); });
    long long v = c->q.front();
    c->q.pop();
    c->cv.notify_one();
    return v;
}
void nova_channel_destroy(long long h) { delete reinterpret_cast<Channel *>(h); }

// ===== Coroutine scheduler (M3-D: Asio io_context) =========================
// The scheduler is now an `asio::io_context`. Scheduling a coroutine posts a resume
// handler; nova_run() drains the context until idle. This replaces the M3-C FIFO
// and, crucially, keeps the loop alive across genuine I/O waits: a pending
// steady_timer / socket op is outstanding work, so run() blocks until it completes
// instead of returning on a momentarily-empty queue (which the FIFO couldn't model).
//
// Coroutines are resumed/inspected via the LLVM switched-resume ABI directly from
// C++ (the frame's first two pointers are resume/destroy; a null resume pointer
// means done) — verified against Nova-compiled coroutines. This lets Asio completion
// handlers drive Nova coroutines even though `llvm.coro.resume` is a compiler-only
// intrinsic.
namespace {
// Runtime singletons are intentionally LEAKED (references to heap objects, never
// deleted) so no static destructor runs at process exit. This avoids a
// static-destruction-order fiasco: background threads (the pool / scheduler) can
// still post to the io_context and touch these mutexes/maps during teardown, and
// destructing them first crashes with "mutex lock failed". The OS reclaims on exit.
// P0 (share-nothing, docs/design/path-a-share-nothing-scope.md): the reactor pool. A Reactor
// is one io_context that will (P3) own a pinned thread and share nothing with its peers. For P0
// there is exactly ONE reactor and `g_io` ALIASES it, so behavior is byte-identical to the old
// single shared io_context — this phase lands ONLY the abstraction (the struct + the pool + the
// accessors) that P1 (coroutine→reactor affinity) and P3 (N = cores-1) build on. Leaked like
// every runtime singleton (no static-destruction-order fiasco).
struct Reactor {
    boost::asio::io_context io;
    int id;
    explicit Reactor(int i) : id(i) {}
};
std::vector<Reactor *> &g_reactors = *new std::vector<Reactor *>{new Reactor(0)};
// P1: the reactor the CURRENT worker thread serves. In P0/P1 every thread serves the single
// reactor 0, so this stays 0; P3 (one pinned thread per reactor) sets it per reactor thread.
// DISTINCT from g_nova_tid (the thread index used by per-thread lock-free pools) — in P0/P1 N
// threads share reactor 0 so tids span 0..N-1 while reactor_id is 0; in P3 they coincide.
thread_local int g_reactor_id = 0;
// The historical name, now bound to reactor 0. Every existing use routes through the pool.
boost::asio::io_context &g_io = g_reactors[0]->io;

using nova_coro_fn = void (*)(void *);
inline void raw_coro_resume(long long h) {
    reinterpret_cast<nova_coro_fn *>(h)[0](reinterpret_cast<void *>(h));
}
inline bool raw_coro_done(long long h) {
    return reinterpret_cast<void **>(h)[0] == nullptr;
}

// M3-D-3: waiter registry (child handle → the coroutine awaiting it). Kept in the
// runtime, NOT in the coroutine promise, so that the awaiter is scheduled by the
// RESUMER *after* the child's resume fully returns — never while the child is still
// executing its epilogue. This closes a multi-thread use-after-free where a parent
// could resume on another core and coro.destroy the child mid-epilogue.
std::mutex &g_waiters_mu = *new std::mutex();
std::unordered_map<long long, long long> &g_waiters = *new std::unordered_map<long long, long long>();

// Owned arguments to release when a SPAWNED coroutine completes. A spawn reads its arguments
// asynchronously — after the spawning statement has drained its temporaries — so an owned-temporary
// argument (e.g. a trait object freshly widened for the call) must outlive that drain and be
// released when the coroutine finishes. buildGo retains such an arg and registers {ptr, dtor} here;
// nova_coro_release_held (called on completion) releases it, exactly as the statement drain would.
std::mutex &g_heldargs_mu = *new std::mutex();
std::unordered_map<long long, std::vector<std::pair<long long, void (*)(long long)>>> &g_heldargs =
    *new std::unordered_map<long long, std::vector<std::pair<long long, void (*)(long long)>>>();

// Release a completed coroutine's held args (call with NO held-args lock; it takes it itself).
static void nova_coro_release_held(long long coro) {
    std::vector<std::pair<long long, void (*)(long long)>> held;
    {
        std::lock_guard<std::mutex> lk(g_heldargs_mu);
        auto it = g_heldargs.find(coro);
        if (it == g_heldargs.end()) return;
        held = std::move(it->second);
        g_heldargs.erase(it);
    }
    for (auto &h : held) nova_release(h.first, h.second);
}

long long take_waiter(long long child) {
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    auto it = g_waiters.find(child);
    if (it == g_waiters.end()) return 0;
    long long w = it->second;
    g_waiters.erase(it);
    return w;
}

struct CoroState {
    std::mutex mu;
    bool running = false;
    bool pending_resume = false;
    bool is_detached = false;
    // Set when an awaiter wants the frame destroyed but the scheduler is still
    // inside raw_coro_resume() / still reading the frame. The scheduler performs
    // the destroy once it is done. See nova_coro_release().
    bool destroy_when_idle = false;
    // P1: this coroutine's REACTOR AFFINITY — captured at creation from the creating thread's
    // g_reactor_id and never changed. A coroutine (and the socket it owns) lives entirely on this
    // reactor. In P0/P1 there is one reactor so this is 0; P3 makes it meaningful. A `spawn`ed
    // child's CoroState is created on the parent's thread, so the child inherits the parent's reactor.
    int reactor_id;
    // M3-D-7: per-coroutine strand, now built from THIS coroutine's reactor (identical to the old
    // `make_strand(g_io)` while there is one reactor). All of this coroutine's resumes are posted
    // here and its async socket-op completions are bound here, so every operation on the socket it
    // owns runs serially. Asio requires this: a single tcp::socket must not be touched from multiple
    // threads without a strand. Once P3 makes each reactor single-threaded the strand is a free
    // no-op (no contention on a one-thread io_context); dropping it then is an optional optimization.
    boost::asio::strand<boost::asio::io_context::executor_type> strand;
    CoroState() : reactor_id(g_reactor_id), strand(boost::asio::make_strand(g_reactors[reactor_id]->io)) {}
};
std::mutex &g_corostates_mu = *new std::mutex();
std::unordered_map<long long, std::shared_ptr<CoroState>> &g_corostates =
    *new std::unordered_map<long long, std::shared_ptr<CoroState>>();

// Returns a shared_ptr, not a raw pointer, and that is load-bearing: the caller
// releases g_corostates_mu before it locks state->mu, so with a raw pointer the
// owning lambda could erase+delete the state in that window and the caller would
// lock a freed mutex. Sharing ownership makes the state outlive every holder --
// the "fiber on two threads" use-after-free. The map's entry is dropped by erase();
// the object dies when the last in-flight holder releases it.
std::shared_ptr<CoroState> get_coro_state(long long handle) {
    std::lock_guard<std::mutex> lk(g_corostates_mu);
    auto it = g_corostates.find(handle);
    if (it == g_corostates.end()) {
        auto state = std::make_shared<CoroState>();
        g_corostates[handle] = state;
        return state;
    }
    return it->second;
}
} // namespace

// Register `parent` as the coroutine to wake when `child` completes. Called (before
// scheduling the child) by an `await child()`; the registration is visible to the
// resumer via the mutex + Asio's happens-before on the scheduled resume.
void nova_register_waiter(long long child, long long parent) {
    if (!child || !parent) return;
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    g_waiters[child] = parent;
}

// `select`/`when_any` over a set of futures: `buf` points to `n` coroutine handles (int64 each).
// Returns the index of the FIRST already-completed future WITHOUT consuming it (the caller then
// awaits that one for its value), or -1 when none is ready — in which case `self` is armed as the
// waiter on ALL of them, so the first to complete reschedules `self` to poll again. On a hit, any
// arming this call placed for `self` is cleared, so a later-completing future does not reschedule a
// `self` that has moved on (its take_waiter then finds no entry). One lock hold makes the
// done-check + arm/disarm atomic against take_waiter (which takes the same lock), so no wakeup is
// lost even if a future completes on another core. NOTE: the losing futures keep running — the
// caller should await (drain) them to free their frames.
long long nova_when_any(long long buf, long long n, long long self) {
    const long long *h = reinterpret_cast<const long long *>(buf);
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    for (long long i = 0; i < n; ++i) {
        if (h[i] && raw_coro_done(h[i])) {
            for (long long j = 0; j < n; ++j) {
                auto it = g_waiters.find(h[j]);
                if (it != g_waiters.end() && it->second == self) g_waiters.erase(it);
            }
            return i;
        }
    }
    for (long long i = 0; i < n; ++i)
        if (h[i]) g_waiters[h[i]] = self;
    return -1;
}

// select-with-deadline: like nova_when_any, but ALSO races the futures against an `ms`-millisecond
// timer — the substrate for a WHOLE-QUERY deadline `select(query, timer)`. Returns the first
// completed future's index, or -2 if the deadline elapsed first, or -1 while still waiting (futures
// armed + a one-shot timer armed on the first call). No separate timer coroutine (which would
// linger the full `ms` and leak); the timer is a plain steady_timer whose completion just
// reschedules `self` to poll again. On resolution the timer is cancelled and its state erased.
namespace {
struct WhenAnyDeadline {
    std::shared_ptr<boost::asio::steady_timer> timer;
    bool fired = false;
    bool armed = false;
};
std::mutex &g_wadl_mu = *new std::mutex();
std::unordered_map<long long, WhenAnyDeadline> &g_wadl = *new std::unordered_map<long long, WhenAnyDeadline>();

// Erase self's deadline state and cancel its timer (call with NEITHER lock held).
void wadl_clear(long long self) {
    std::shared_ptr<boost::asio::steady_timer> t;
    {
        std::lock_guard<std::mutex> lk(g_wadl_mu);
        auto it = g_wadl.find(self);
        if (it == g_wadl.end()) return;
        t = it->second.timer;
        g_wadl.erase(it);
    }
    if (t) t->cancel();
}
// Disarm self as the waiter on every handle in [h, h+n) (call with NEITHER lock held).
void wadl_disarm(const long long *h, long long n, long long self) {
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    for (long long j = 0; j < n; ++j) {
        auto it = g_waiters.find(h[j]);
        if (it != g_waiters.end() && it->second == self) g_waiters.erase(it);
    }
}
} // namespace

long long nova_when_any_deadline(long long buf, long long n, long long ms, long long self) {
    const long long *h = reinterpret_cast<const long long *>(buf);
    // 1. A completed future wins over a simultaneous timeout (prefer the real result).
    long long found = -1;
    {
        std::lock_guard<std::mutex> lk(g_waiters_mu);
        for (long long i = 0; i < n; ++i)
            if (h[i] && raw_coro_done(h[i])) { found = i; break; }
        if (found >= 0) {
            for (long long j = 0; j < n; ++j) {
                auto it = g_waiters.find(h[j]);
                if (it != g_waiters.end() && it->second == self) g_waiters.erase(it);
            }
        }
    }
    if (found >= 0) { wadl_clear(self); return found; }

    // 2. Deadline elapsed?
    bool timed_out = false;
    {
        std::lock_guard<std::mutex> lk(g_wadl_mu);
        auto it = g_wadl.find(self);
        if (it != g_wadl.end() && it->second.fired) { g_wadl.erase(it); timed_out = true; }
    }
    if (timed_out) { wadl_disarm(h, n, self); return -2; }

    // 3. Arm the futures (waiters) + a one-shot timer on the first pass.
    {
        std::lock_guard<std::mutex> lk(g_waiters_mu);
        for (long long i = 0; i < n; ++i)
            if (h[i]) g_waiters[h[i]] = self;
    }
    {
        std::lock_guard<std::mutex> lk(g_wadl_mu);
        auto &st = g_wadl[self];
        if (!st.armed) {
            st.armed = true;
            st.timer = std::make_shared<boost::asio::steady_timer>(g_io);
            st.timer->expires_after(std::chrono::milliseconds(ms < 0 ? 0 : ms));
            long long self_c = self;
            st.timer->async_wait([self_c](const boost::system::error_code &ec) {
                if (ec) return; // cancelled (a future won)
                {
                    std::lock_guard<std::mutex> wl(g_wadl_mu);
                    auto it = g_wadl.find(self_c);
                    if (it != g_wadl.end()) it->second.fired = true;
                }
                nova_sched_schedule(self_c);
            });
        }
    }
    return -1;
}

// M3-D-4: `await <future>` on a task launched with `go`. Atomically (under the same
// registry mutex that `take_waiter` uses) either observes the task already complete
// (return 1 → caller reads the result inline, no suspend) or registers `waiter` and
// returns 0 (caller suspends; the runtime wakes it when the task completes). Doing
// the done-check and the registration under one lock closes the classic
// wait-registration race — no lost wakeup even if the task finishes on another core.
long long nova_await_future(long long future, long long waiter) {
    if (!future) return 1;
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    if (raw_coro_done(future)) return 1;
    if (waiter) g_waiters[future] = waiter;
    return 0;
}

// Schedule a coroutine handle to be resumed by the event loop. After the resume
// returns, if the coroutine has completed, wake its registered waiter (race-free:
// the waiter runs strictly after this resume returns).
// Register an owned arg (with its destructor) to be released when coroutine `coro` completes —
// C-linkage entry point for buildGo (see the g_heldargs comment). The map + release helper live in
// the file-local namespace above; this wrapper just exposes the insert with external linkage.
void nova_coro_hold_arg(long long coro, long long ptr, void (*dtor)(long long)) {
    if (!coro || !ptr) return;
    std::lock_guard<std::mutex> lk(g_heldargs_mu);
    g_heldargs[coro].push_back({ptr, dtor});
}

void nova_sched_schedule(long long handle) {
    if (!handle) return;
    if (raw_coro_done(handle)) return;

    auto state = get_coro_state(handle);
    {
        std::lock_guard<std::mutex> lk(state->mu);
        if (state->running) {
            state->pending_resume = true;
            return;
        }
        state->running = true;
    }

    boost::asio::post(state->strand, [handle, state]() {
        if (raw_coro_done(handle)) {
            // Already complete by the time we were dispatched (someone else drove it
            // to completion between nova_sched_schedule's done-check and this post).
            bool destroy_self;
            bool deferred_destroy;
            {
                std::lock_guard<std::mutex> lk(state->mu);
                state->running = false;
                destroy_self = state->is_detached;
                deferred_destroy = state->destroy_when_idle;
                state->destroy_when_idle = false;
            }
            // Drop the map's reference; any in-flight holder keeps the state
            // alive via its own shared_ptr (see get_coro_state).
            {
                std::lock_guard<std::mutex> glk(g_corostates_mu);
                g_corostates.erase(handle);
            }
            // take_waiter is MANDATORY here, exactly as in the post-resume path.
            // Omitting it leaked the registration in g_waiters forever — and
            // g_waiters is keyed by a coroutine handle, i.e. a heap address, which
            // is REUSED once the frame is freed. A later coroutine landing on that
            // address inherits the stale waiter, and take_waiter then hands back a
            // long-destroyed frame which the scheduler resumes: a jump through a
            // garbage function pointer (PC == the bad address). That was the
            // remaining `10_async_go` crash, and it needed two sequential async
            // drives to show up — one to leak the entry, one to reuse the address.
            nova_coro_release_held(handle);
            long long w = take_waiter(handle);
            if (w) {
                nova_sched_schedule(w);
            }
            if (deferred_destroy || (!w && destroy_self)) {
                reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
            }
            return;
        }

        raw_coro_resume(handle);

        bool resume_again = false;
        bool finished = false;
        bool destroy_self = false;
        bool deferred_destroy = false;
        {
            std::lock_guard<std::mutex> lk(state->mu);
            // raw_coro_done() reads the FRAME, so it must be serialised against
            // nova_coro_release() — which is why release() also takes state->mu and
            // defers while `running`. Without that, an awaiter on the ready path
            // (nova_await_future returned 1) destroys this frame while we are still
            // reading it. That is a genuine two-thread use-after-free: it vanishes
            // under NOVA_THREADS=1 and under ASAN (whose slowdown closes the window).
            if (raw_coro_done(handle)) {
                state->running = false;
                destroy_self = state->is_detached;
                deferred_destroy = state->destroy_when_idle;
                state->destroy_when_idle = false;
                finished = true;
            } else if (state->pending_resume) {
                state->pending_resume = false;
                // MUST clear `running` before re-scheduling. nova_sched_schedule()
                // swallows the request into pending_resume when running is still
                // set — and nothing ever re-checks it, so the wakeup is lost and
                // the coroutine never completes. nova_run() then drains and the
                // caller reads an unwritten promise slot (garbage, not a hang).
                // This was the `10_async_go` flake: ~20% of runs, `await` yielding
                // a stale pointer instead of a result.
                state->running = false;
                resume_again = true;
            } else {
                state->running = false;
            }
        }
        // state->mu is released above before the map entry is dropped.
        if (finished) {
            {
                std::lock_guard<std::mutex> glk(g_corostates_mu);
                g_corostates.erase(handle);
            }

            nova_coro_release_held(handle);
            long long w = take_waiter(handle);
            if (w) {
                nova_sched_schedule(w);
            }
            // Past this point we never touch the frame again, so it is safe to
            // honour a destroy that arrived while we were running. At most one of
            // these fires: a detached task owns itself; otherwise its awaiter does.
            if (deferred_destroy || (!w && destroy_self)) {
                reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
            }
            return;
        }

        if (resume_again) {
            nova_sched_schedule(handle);
        }
    });
}

// Destroy a coroutine frame, serialised against the scheduler.
//
// Replaces a bare `llvm.coro.destroy` at every site where one coroutine frees
// another's frame (an awaiter freeing the task it awaited). The bare intrinsic is
// unsafe there: the scheduler lambda reads the frame (raw_coro_done) after
// raw_coro_resume returns, and an awaiter that took the READY path — where
// nova_await_future observed the task already complete and returned 1 — would free
// the frame underneath it. Two threads, one frame: the crash disappears under
// NOVA_THREADS=1 and hides from ASAN.
//
// `running` is already the flag that says "the scheduler owns this frame right
// now"; this simply makes destruction respect it. If the scheduler is running, it
// performs the destroy when it is finished (destroy_when_idle); otherwise nobody
// else can be touching the frame and we destroy immediately.
void nova_coro_release(long long handle) {
    if (!handle) return;
    std::shared_ptr<CoroState> state;
    {
        std::lock_guard<std::mutex> glk(g_corostates_mu);
        auto it = g_corostates.find(handle);
        if (it != g_corostates.end()) state = it->second;
    }
    if (state) {
        {
            std::lock_guard<std::mutex> lk(state->mu);
            if (state->running) {
                // The scheduler is inside raw_coro_resume() or still reading the
                // frame. It will destroy on its way out.
                state->destroy_when_idle = true;
                return;
            }
        }
        // Drop the entry before freeing the frame: g_corostates is keyed by the
        // handle, and the address is reused once the frame is gone. A leftover
        // entry would hand the next coroutine at that address a stale state.
        std::lock_guard<std::mutex> glk(g_corostates_mu);
        g_corostates.erase(handle);
    }
    // No state (never scheduled, or the scheduler already finished and erased it)
    // or not running: nobody else can touch the frame.
    reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
}

void nova_sched_schedule_detached(long long handle) {
    if (!handle) return;
    if (raw_coro_done(handle)) {
        reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
        return;
    }
    auto state = get_coro_state(handle);
    {
        std::lock_guard<std::mutex> lk(state->mu);
        state->is_detached = true;
    }
    nova_sched_schedule(handle);
}

// P3: the REACTOR count (share-nothing = one pinned thread per reactor, so this is also the worker
// count). NOVA_THREADS overrides; else **cores − 1** (leave a core for the OS / block-drive caller),
// capped at 16, min 1. NOVA_THREADS=1 ⇒ one reactor ⇒ exactly the pre-share-nothing behavior.
namespace {
unsigned nova_thread_count() {
    if (const char *e = std::getenv("NOVA_THREADS")) {
        int n = std::atoi(e);
        if (n > 0) return static_cast<unsigned>(n);
    }
    unsigned n = std::thread::hardware_concurrency();
    if (n <= 1) return 1;
    n -= 1; // cores - 1
    if (n > 16) n = 16;
    return n;
}
// Grow the reactor pool to `n` (idempotent; called single-threaded from nova_run BEFORE any reactor
// thread starts, so no lock is needed). Reactor 0 already exists from static init.
void ensure_reactors(int n) {
    while (static_cast<int>(g_reactors.size()) < n)
        g_reactors.push_back(new Reactor(static_cast<int>(g_reactors.size())));
}
} // namespace

// Drive the event loop until all scheduled work (and pending I/O) is complete.
// M3-D-3: multi-core — run() on a pool of N threads so that when several coroutines
// are runnable at once (spawned tasks, concurrently-woken timers/sockets) they
// resume truly in parallel across cores. A coroutine may migrate threads across
// suspends; this is safe because the load-bearing thread-local arena is gone
// (workstream A) and ARC is atomic. Each run() returns when the context drains; we
// join and restart() for the next top-level drive. (The pool is per-drive for now —
// block-drive is a rare sync→async boundary, not a hot path; a persistent pool is a
// later optimization.)
// Worker-thread index [0, N). Set once per io_context worker; every coroutine resumed on that thread
// reads it via nova_thread_id(). This is what lets Nova code keep PER-THREAD, LOCK-FREE structures
// (the reverse-proxy connection pool): a per-thread slot is only ever touched by its own worker (a
// thread runs one coroutine at a time, and Nova's pool critical sections have no await), so no lock is
// needed — the HAProxy `idle_conn_srv[tid]` model. The main thread is 0; pool threads 1..N-1.
static thread_local int g_nova_tid = 0;
long long nova_thread_id(void) { return g_nova_tid; }
long long nova_worker_count(void) { return (long long)nova_thread_count(); }

void nova_run(void) {
    // P3 (share-nothing): N = cores-1 reactors, each an INDEPENDENT io_context driven by ONE pinned
    // thread — thread i sets g_reactor_id = g_nova_tid = i and runs reactor i. A coroutine (and the
    // socket it owns) lives entirely on its reactor; strands are now free no-ops on a one-thread loop.
    // (Until P4's per-reactor SO_REUSEPORT accept distributes connections, every coroutine traces back
    // to reactor 0, so reactors 1..N-1 are idle infrastructure here — gate-clean but single-core; P4
    // lights them up.) NOVA_THREADS=1 ⇒ one reactor ⇒ old behavior exactly.
    const int n = static_cast<int>(nova_thread_count());
    ensure_reactors(n);
    std::vector<std::thread> pool;
    if (n > 1) pool.reserve(static_cast<size_t>(n - 1));
    for (int i = 1; i < n; ++i)
        pool.emplace_back([i] {
            g_nova_tid = i;
            g_reactor_id = i;
            g_reactors[i]->io.run();
        });
    g_nova_tid = 0;
    g_reactor_id = 0;
    g_reactors[0]->io.run();
    for (auto &t : pool) t.join();
    for (int i = 0; i < n; ++i) g_reactors[i]->io.restart();
}

// Drive the loop until `root` has ACTUALLY COMPLETED, not merely until the
// io_context went idle. Those are different, and conflating them is a silent
// wrong answer: nova_run() returns on an idle context, but a caller
// (buildDriveAsyncCall) then reads root's promise slot unconditionally. If root
// is still pending, that slot was never written and the caller returns garbage —
// which is precisely how the `10_async_go` flake presented (`await` yielding a
// stale pointer instead of 30).
//
// An idle context with a pending root means a wakeup is in flight: one thread can
// observe an empty queue while another is between completing a child and posting
// the parent's resume. Draining again picks it up (handlers posted to a stopped
// context are queued and run after restart()).
//
// Bounded on purpose. If the root still cannot finish, a wakeup was genuinely
// lost, and that must fail LOUDLY here rather than hand the caller an unwritten
// promise. A crash naming the cause beats a plausible wrong number.
void nova_run_root(long long root) {
    nova_run();
    if (!root) return;
    for (int i = 0; i < 10000 && !raw_coro_done(root); ++i) {
        std::this_thread::yield();
        nova_run();
    }
    if (!raw_coro_done(root)) {
        std::fprintf(stderr,
                     "nova: fatal — async root %p never completed (lost wakeup); "
                     "refusing to read its unwritten result\n",
                     reinterpret_cast<void *>(root));
        std::abort();
    }
}

// Access to the io_context for timer/socket awaitables (returned as an opaque
// handle; the runtime dereferences it).
long long nova_io_context(void) { return reinterpret_cast<long long>(&g_io); }

// ===== Async channels (M3-D-6) =============================================
// A coroutine-aware channel: `send` enqueues a value and wakes one waiting receiver;
// `recv` either dequeues immediately or parks the calling coroutine until a value
// arrives (codegen emits the suspend + retry loop). Unbounded (send never blocks).
namespace {
struct NovaChan {
    std::mutex m;
    std::queue<long long> values;
    std::queue<long long> recv_waiters; // coroutine handles parked on recv
};
} // namespace

long long nova_chan_new(long long capacity) {
    (void)capacity; // unbounded for now
    return reinterpret_cast<long long>(new NovaChan());
}

void nova_chan_send(long long ch, long long val) {
    if (!ch) return;
    auto *c = reinterpret_cast<NovaChan *>(ch);
    long long waiter = 0;
    {
        std::lock_guard<std::mutex> lk(c->m);
        c->values.push(val);
        if (!c->recv_waiters.empty()) {
            waiter = c->recv_waiters.front();
            c->recv_waiters.pop();
        }
    }
    if (waiter) nova_sched_schedule(waiter); // wake a parked receiver
}

// Try to receive: if a value is available, store it in *out and return 1; otherwise
// park `self` as a receiver and return 0 (caller suspends; the runtime reschedules it
// when a send arrives, and it retries). Dequeue+park are atomic under the lock, so no
// value is lost between the check and the park even across cores.
long long nova_chan_recv(long long ch, long long self, long long *out) {
    if (!ch) return 1;
    auto *c = reinterpret_cast<NovaChan *>(ch);
    std::lock_guard<std::mutex> lk(c->m);
    if (!c->values.empty()) {
        *out = c->values.front();
        c->values.pop();
        return 1;
    }
    if (self) c->recv_waiters.push(self);
    return 0;
}

void nova_chan_free(long long ch) {
    if (ch) delete reinterpret_cast<NovaChan *>(ch);
}

// ===== Async socket I/O via offload (M3-D-6) ===============================
// A blocking socket op (recv/accept/connect) runs on a SEPARATE I/O thread pool so
// it never holds a coroutine-scheduler thread. The calling coroutine parks; when the
// op finishes, the worker stashes the result and reschedules the coroutine, which
// reads the result via nova_io_take_result. (This is the pragmatic step: it keeps
// the scheduler responsive; full asio non-blocking I/O for massive connection counts
// is a later architectural refinement.)
namespace {
// The blocking-offload I/O pool is created LAZILY, on first use. A `boost::asio::thread_pool(N)`
// spawns all N OS threads in its constructor, so an EAGER global here cost 64 idle threads in EVERY
// process — even the common case (an HTTP server using the non-blocking aaccept/arecv path, which
// never touches this pool). That inflated a plain web server's thread count to ~72 (8 scheduler + 64
// idle). Sizing from NOVA_THREADS (× a small blocking-fan-out factor, capped) keeps the offload path
// working for whoever DOES use it, without paying for threads a non-blocking app never runs.
boost::asio::thread_pool &io_pool() {
    static boost::asio::thread_pool *pool = [] {
        unsigned n = 8;
        if (const char *e = std::getenv("NOVA_THREADS")) {
            int v = std::atoi(e);
            if (v > 0) n = static_cast<unsigned>(v);
        } else {
            unsigned hc = std::thread::hardware_concurrency();
            if (hc > 0) n = hc;
        }
        // Blocking ops can fan out beyond the scheduler width, but keep it bounded — this pool exists
        // only for the legacy syscall-offload path, not the hot non-blocking loop.
        unsigned size = n * 4;
        if (size < 4) size = 4;
        if (size > 64) size = 64;
        return new boost::asio::thread_pool(size);
    }();
    return *pool;
}
std::mutex &g_ioresult_mu = *new std::mutex();
std::unordered_map<long long, long long> &g_ioresults = *new std::unordered_map<long long, long long>();

void stash_io_result(long long self, long long result) {
    std::lock_guard<std::mutex> lk(g_ioresult_mu);
    g_ioresults[self] = result;
}
} // namespace

long long nova_io_take_result(long long self) {
    std::lock_guard<std::mutex> lk(g_ioresult_mu);
    auto it = g_ioresults.find(self);
    if (it == g_ioresults.end()) return -1;
    long long r = it->second;
    g_ioresults.erase(it);
    return r;
}

// Offload a blocking recv; the worker fills `buf` (a stable heap buffer, not the coro
// frame — safe to write across the suspend) and reschedules `self` with the count.
void nova_io_recv_async(long long fd, long long buf, long long max_len, long long self) {
    boost::asio::post(io_pool(), [fd, buf, max_len, self]() {
        long long n = nova_socket_recv((int)fd, reinterpret_cast<char *>(buf), (int)max_len);
        stash_io_result(self, n);
        nova_sched_schedule(self);
    });
}

// Offload a blocking accept; result is the client fd (or -1).
void nova_io_accept_async(long long server_fd, long long self) {
    boost::asio::post(io_pool(), [server_fd, self]() {
        long long fd = nova_socket_accept((int)server_fd);
        stash_io_result(self, fd);
        nova_sched_schedule(self);
    });
}

// ===== Scalable async server sockets (M3-D-7, true non-blocking asio) =======
// Unlike the offload path above, these use asio's event-driven async ops
// (async_accept/async_read_some/async_write) directly on the io_context. A pending
// op holds NO thread — it's registered with kqueue/epoll — so N scheduler threads
// serve tens of thousands of connections, each a cheap coroutine (not a thread).
// This is the C10K/C100K path for HTTP servers. Handles are pointers to the structs.
namespace {
struct NovaAcceptor {
    boost::asio::ip::tcp::acceptor acc;
    NovaAcceptor(boost::asio::io_context &io, unsigned short port) : acc(io) {
        boost::asio::ip::tcp::endpoint ep(boost::asio::ip::tcp::v4(), port);
        acc.open(ep.protocol());
        acc.set_option(boost::asio::socket_base::reuse_address(true));
#ifdef SO_REUSEPORT
        // P4: SO_REUSEPORT lets EVERY reactor bind the SAME port; the kernel load-balances new
        // connections across the per-reactor acceptors (nginx / share-nothing model). Each reactor
        // then accepts and handles its own connections on its own thread — no cross-reactor socket
        // sharing. Guarded: Windows has no SO_REUSEPORT (reuse_address above is the closest analog).
        int one = 1;
        ::setsockopt(acc.native_handle(), SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
        acc.bind(ep);
        acc.listen();
    }
};
struct NovaSocket {
    boost::asio::ip::tcp::socket sock;
    explicit NovaSocket(boost::asio::io_context &io) : sock(io) {}
};
} // namespace

// Bind+listen on `port`; returns an acceptor handle (0 on failure, e.g. port in use).
long long nova_aserver_listen(long long port) {
    try {
        return reinterpret_cast<long long>(new NovaAcceptor(g_reactors[g_reactor_id]->io, (unsigned short)port));
    } catch (...) {
        return 0;
    }
}

// Async-accept the next connection: parks `self`; on arrival, stashes a new socket
// handle (0 on error) and reschedules self. No thread held while waiting.
void nova_aaccept(long long server, long long self) {
    auto *a = reinterpret_cast<NovaAcceptor *>(server);
    auto state = get_coro_state(self);
    auto *ns = new NovaSocket(g_reactors[state->reactor_id]->io);
    a->acc.async_accept(ns->sock, boost::asio::bind_executor(state->strand, [self, ns](const boost::system::error_code &ec) {
        long long result;
        if (ec) { delete ns; result = 0; }
        else { result = reinterpret_cast<long long>(ns); }
        stash_io_result(self, result);
        nova_sched_schedule(self);
    }));
}

// Async connect (scalable client): resolve `host`:`port`, connect, and resume `self`
// with a socket handle (0 on failure). Two-step async (resolve → connect); the
// resolver and socket are kept alive by the capture, and all completions run on the
// coroutine's strand. `host` is a Nova string (length at host-4).
void nova_aconnect(long long host, long long port, long long self) {
    auto state = get_coro_state(self);
    const char *h = reinterpret_cast<const char *>(host);
    int hlen = h ? *reinterpret_cast<const int *>(h - 4) : 0;
    auto host_s = std::make_shared<std::string>(h ? h : "", hlen < 0 ? 0 : hlen);
    auto port_s = std::make_shared<std::string>(std::to_string(port));
    auto ns = new NovaSocket(g_reactors[state->reactor_id]->io);
    auto resolver = std::make_shared<boost::asio::ip::tcp::resolver>(g_reactors[state->reactor_id]->io);
    resolver->async_resolve(*host_s, *port_s,
        boost::asio::bind_executor(state->strand,
            [self, ns, resolver, host_s, port_s](const boost::system::error_code &ec,
                                                 boost::asio::ip::tcp::resolver::results_type results) {
                if (ec) {
                    delete ns;
                    stash_io_result(self, 0);
                    nova_sched_schedule(self);
                    return;
                }
                auto state2 = get_coro_state(self);
                boost::asio::async_connect(ns->sock, results,
                    boost::asio::bind_executor(state2->strand,
                        [self, ns, resolver](const boost::system::error_code &ec2,
                                             const boost::asio::ip::tcp::endpoint &) {
                            if (ec2) { delete ns; stash_io_result(self, 0); }
                            else { stash_io_result(self, reinterpret_cast<long long>(ns)); }
                            nova_sched_schedule(self);
                        }));
            }));
}

// Async read up to max_len bytes into buf; parks self, resumes with the byte count
// (0 = EOF/peer closed, -1 = error).
void nova_arecv(long long sock, long long buf, long long max_len, long long self) {
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    auto state = get_coro_state(self);
    s->sock.async_read_some(
        boost::asio::buffer(reinterpret_cast<char *>(buf), (size_t)max_len),
        boost::asio::bind_executor(state->strand, [self](const boost::system::error_code &ec, size_t n) {
            stash_io_result(self, ec ? -1 : (long long)n);
            nova_sched_schedule(self);
        }));
}

// Async read up to max_len bytes into buf WITH a deadline: arms the recv AND a `ms`-millisecond
// timer, and resumes `self` with whichever fires first — bytes read (>=0) if data arrived, or -2
// if the deadline elapsed first (a non-blocking analog of SO_RCVTIMEO). Both completions run on
// the coroutine's strand, so the `done` flag is race-free; the loser is cancelled (the timer on a
// data win, the pending recv via socket.cancel() on a timeout). A timed-out connection is left in
// an indeterminate state — the caller should discard it.
void nova_arecv_deadline(long long sock, long long buf, long long max_len, long long ms, long long self) {
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    auto state = get_coro_state(self);
    auto done = std::make_shared<bool>(false);
    auto timer = std::make_shared<boost::asio::steady_timer>(g_io);
    timer->expires_after(std::chrono::milliseconds(ms < 0 ? 0 : ms));
    s->sock.async_read_some(
        boost::asio::buffer(reinterpret_cast<char *>(buf), (size_t)max_len),
        boost::asio::bind_executor(state->strand, [self, done, timer](const boost::system::error_code &ec, size_t n) {
            if (*done) return;          // the timer already won
            *done = true;
            timer->cancel();            // cancel the deadline
            stash_io_result(self, ec ? -1 : (long long)n);
            nova_sched_schedule(self);
        }));
    timer->async_wait(boost::asio::bind_executor(state->strand, [self, done, s](const boost::system::error_code &ec) {
        if (*done || ec) return;        // recv already won, or the timer was cancelled
        *done = true;
        boost::system::error_code ic;
        s->sock.cancel(ic);             // cancel the pending recv (its handler no-ops via `done`)
        stash_io_result(self, -2);      // -2 = deadline elapsed
        nova_sched_schedule(self);
    }));
}

// Async write the Nova string `data` (length at data-4) in full; parks self, resumes
// with bytes written (-1 on error). The buffer stays alive because the awaiting
// coroutine holds `data` across the suspend.
void nova_asend(long long sock, long long data, long long self) {
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    auto state = get_coro_state(self);
    const char *p = reinterpret_cast<const char *>(data);
    int len = p ? *reinterpret_cast<const int *>(p - 4) : 0;
    boost::asio::async_write(
        s->sock, boost::asio::buffer(p, (size_t)(len < 0 ? 0 : len)),
        boost::asio::bind_executor(state->strand, [self](const boost::system::error_code &ec, size_t n) {
            stash_io_result(self, ec ? -1 : (long long)n);
            nova_sched_schedule(self);
        }));
}

void nova_aclose(long long sock) {
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    if (!s) return;
    boost::system::error_code ec;
    // Graceful close. Two teardown hazards a bare close() hits:
    //   1. It RSTs (discarding the still-draining response!) if there are UNREAD
    //      request bytes in the receive buffer — and `arecv` (async_read_some) reads
    //      only one chunk, so under load the rest of the request is often unread.
    //   2. Even without that, closing before the send buffer drains can lose data.
    // Fix: shutdown(send) to queue our FIN after the response, then DRAIN any unread
    // inbound bytes (non-blocking, best-effort) so close() is clean and the client
    // reliably receives the full response.
    s->sock.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ec);
    s->sock.close(ec);
    delete s;
}

// M3-D: non-blocking timer await. Arms an asio::steady_timer for `ms` milliseconds;
// when it fires, the awaiting coroutine `handle` is rescheduled. The coroutine
// suspends immediately after calling this (codegen emits the suspend), so the
// thread is free to run other coroutines meanwhile — real cooperative async I/O,
// unlike the blocking nova_concurrency_sleep. The timer keeps itself alive via the
// shared_ptr captured in the completion handler.
void nova_await_timer(long long handle, long long ms) {
    if (!handle) return;
    auto timer = std::make_shared<boost::asio::steady_timer>(
        g_io, std::chrono::milliseconds(ms < 0 ? 0 : ms));
    timer->async_wait([handle, timer](const boost::system::error_code &) {
        nova_sched_schedule(handle);
    });
}

// Retained for the synchronous shim / older codegen paths (no longer used by the
// Asio driver, which resumes via posted handlers).
long long nova_sched_next(void) { return 0; }

// ===== Program entry =======================================================
void nova_set_args(int argc, char **argv);
int main(int argc, char **argv) {
    nova_set_args(argc, argv); // stash for env.args()
    return static_cast<int>(__nova_main());
}

} // extern "C"
