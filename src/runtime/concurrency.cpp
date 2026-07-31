
#include "nova_abi.h"
#ifndef _WIN32
#include <sys/socket.h>
#endif
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/event.h>   // kqueue EVFILT_TIMER/EVFILT_USER, for the reactor driver (M4)
#include <unistd.h>      // close
#define NOVA_HAVE_KQUEUE 1
#endif
#ifdef _WIN32
#include <winsock2.h>    // MUST precede <windows.h> so the winsock v2 symbols win over v1
#include <windows.h>     // IOCP: the completion-based reactor driver, the Windows peer of kqueue
#define NOVA_HAVE_IOCP 1
#endif
#include <cstdio>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

extern "C" long long __nova_main(void);

// Forward declarations of reactor primitives defined later in this file / in core.cpp, used by
// nova_when_any_deadline (above their definitions) to arm a reactor-native deadline timer.
extern "C" long long nova_reactor_current(void);
extern "C" void nova_reactor_set_timer(long long handle, long long ms);
extern "C" void nova_reactor_cancel_timer(long long handle);
// int64_t, NOT `long long`: core.cpp defines this as int64_t, which is `long long` on macOS but
// `long` on Linux x86_64 — declaring it `long long` here makes the two differ only in return type,
// which C++ rejects outright ("functions that differ only in their return type cannot be overloaded").
extern "C" int64_t nova_mono_ms(void);
// nova_reactor_resume is defined further down; the IOCP support below (and only it) needs it
// ahead of that definition.
extern "C" long long nova_reactor_resume(long long handle);

#if defined(NOVA_HAVE_IOCP)
// --- IOCP reactor support (the Windows peer of the kqueue driver) ------------------------------
//
// Completion keys tell the three kinds of completion apart. A real I/O completion carries whatever
// key its handle was associated with (net/eventloop_windows uses the fd) plus a non-null OVERLAPPED
// that IS the op record; these two sentinels are reserved for completions the runtime posts itself.
// net/eventloop_windows.nova's Poller.poll must agree with this — keep the two in step.
const ULONG_PTR NOVA_WAKE_KEY = (ULONG_PTR)-1;    // cross-reactor wake; nothing to resume
const ULONG_PTR NOVA_TIMER_KEY = (ULONG_PTR)-2;   // lpOverlapped IS the coroutine handle

// Op-record offsets, mirroring the layout net/eventloop_windows.nova documents (its OVERLAPPED sits
// at offset 0, so a completion's lpOverlapped is the record's address).
const int NOVA_OP_DONE_OFF = 52;     // i32 flag: the op has completed
const int NOVA_OP_TOKEN_OFF = 56;    // coroutine handle to resume
const int NOVA_OP_RESULT_OFF = 64;   // i64 byte count / result

// TIMERS. kqueue has EVFILT_TIMER, so an armed timeout arrives as an ordinary event on the same
// queue the loop already waits on. A completion port has no timer source, so one is built: a
// one-shot timer-queue timer whose callback does nothing but PostQueuedCompletionStatus. The fire
// therefore arrives as a completion on the port, which means BOTH drivers see it — the C loop in
// nova_run_root and the Nova-side Poller in net/eventloop_windows — with no shared state between
// them. A thread-local list would only have worked for the first.
struct NovaIocpTimer {
    HANDLE timer;
    HANDLE port;
    long long handle;   // the coroutine to resume
};
std::mutex &g_iocp_timer_mu = *new std::mutex();
std::unordered_map<long long, NovaIocpTimer *> &g_iocp_timers =
    *new std::unordered_map<long long, NovaIocpTimer *>();

// Runs on a threadpool thread: touches only fields set before the timer was created, so it needs no
// lock. Posting is all it does; the resume happens on the reactor thread that drains the port.
static VOID CALLBACK nova_iocp_timer_cb(PVOID param, BOOLEAN) {
    NovaIocpTimer *t = reinterpret_cast<NovaIocpTimer *>(param);
    PostQueuedCompletionStatus(t->port, 0, NOVA_TIMER_KEY,
                               reinterpret_cast<LPOVERLAPPED>((uintptr_t)t->handle));
}

static void iocp_timer_cancel(long long handle) {
    NovaIocpTimer *t = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_iocp_timer_mu);
        auto it = g_iocp_timers.find(handle);
        if (it == g_iocp_timers.end()) return;
        t = it->second;
        g_iocp_timers.erase(it);
    }
    // A null completion event means "do not block if the callback is running", which is required
    // when cancelling from inside the dispatch of that timer's own fire.
    if (t->timer) DeleteTimerQueueTimer(nullptr, t->timer, nullptr);
    delete t;
}

static void iocp_timer_arm(long long handle, long long ms) {
    // nova_reactor_current(), not g_current_kq: that thread_local is defined further down the file.
    HANDLE port = (HANDLE)(intptr_t)nova_reactor_current();
    if (!port || !handle) return;
    iocp_timer_cancel(handle);   // re-arming replaces the pending deadline, as EV_ADD does

    NovaIocpTimer *t = new NovaIocpTimer{nullptr, port, handle};
    HANDLE h = nullptr;
    if (!CreateTimerQueueTimer(&h, nullptr, nova_iocp_timer_cb, t,
                               (DWORD)(ms < 0 ? 0 : ms), 0, WT_EXECUTEONLYONCE)) {
        delete t;
        return;
    }
    t->timer = h;
    // Registered after creation, so a timer that fires immediately may post before it is visible
    // here; the dispatch below then finds nothing to cancel and the next arm for this coroutine
    // reclaims it. Harmless, and it keeps the callback lock-free.
    std::lock_guard<std::mutex> lk(g_iocp_timer_mu);
    g_iocp_timers[handle] = t;
}

// Turn one completion into a coroutine resume.
static void iocp_dispatch(const OVERLAPPED_ENTRY &e) {
    if (e.lpCompletionKey == NOVA_WAKE_KEY) return;   // the wake IS the loop returning

    if (e.lpCompletionKey == NOVA_TIMER_KEY) {
        long long h = (long long)(uintptr_t)e.lpOverlapped;
        iocp_timer_cancel(h);   // one-shot: reclaim the timer object now that it has fired
        if (h) nova_reactor_resume(h);
        return;
    }

    // An I/O completion: IOCP is a proactor, so the byte count is already known and is written back
    // into the op record before the coroutine resumes. Readiness backends have nothing to write.
    char *op = reinterpret_cast<char *>(e.lpOverlapped);
    if (!op) return;
    *reinterpret_cast<int *>(op + NOVA_OP_DONE_OFF) = 1;
    *reinterpret_cast<long long *>(op + NOVA_OP_RESULT_OFF) =
        (long long)e.dwNumberOfBytesTransferred;
    long long token = *reinterpret_cast<long long *>(op + NOVA_OP_TOKEN_OFF);
    if (token) nova_reactor_resume(token);
}
#endif // NOVA_HAVE_IOCP


extern "C" {

void nova_concurrency_spawn(long long closure) {
    if (!closure) return;
    long long *box = reinterpret_cast<long long *>(closure);
    reinterpret_cast<void (*)(long long)>(box[0])(box[1]);
}
void nova_concurrency_sleep(long long ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

namespace {
struct Channel {
    std::mutex m;
    std::condition_variable cv;
    std::queue<long long> q;
    int capacity;
};
}
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

namespace {

thread_local int g_reactor_id = 0;
thread_local int g_pin_next = -1;

using nova_coro_fn = void (*)(void *);
inline void raw_coro_resume(long long h) {
    reinterpret_cast<nova_coro_fn *>(h)[0](reinterpret_cast<void *>(h));
}
inline bool raw_coro_done(long long h) {
    return reinterpret_cast<void **>(h)[0] == nullptr;
}

std::mutex &g_waiters_mu = *new std::mutex();
std::unordered_map<long long, long long> &g_waiters = *new std::unordered_map<long long, long long>();

extern "C++" {
constexpr size_t NSTRIPES = 64;
inline size_t stripe_of(long long handle) {
    unsigned long long x = static_cast<unsigned long long>(handle);
    x ^= x >> 16;
    x *= 0x9E3779B97F4A7C15ULL;
    x ^= x >> 32;
    return static_cast<size_t>(x & (NSTRIPES - 1));
}
template <typename V>
struct StripedMap {
    struct Stripe {
        std::mutex mu;
        std::unordered_map<long long, V> map;
    };
    Stripe *stripes;
    StripedMap() : stripes(new Stripe[NSTRIPES]) {}
    Stripe &at(long long handle) { return stripes[stripe_of(handle)]; }
};
}

StripedMap<std::vector<std::pair<long long, void (*)(long long)>>> &g_heldargs =
    *new StripedMap<std::vector<std::pair<long long, void (*)(long long)>>>();

static void nova_coro_release_held(long long coro) {
    std::vector<std::pair<long long, void (*)(long long)>> held;
    {
        auto &s = g_heldargs.at(coro);
        std::lock_guard<std::mutex> lk(s.mu);
        auto it = s.map.find(coro);
        if (it == s.map.end()) return;
        held = std::move(it->second);
        s.map.erase(it);
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

}

void nova_register_waiter(long long child, long long parent) {
    if (!child || !parent) return;
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    g_waiters[child] = parent;
}

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

namespace {
struct WhenAnyDeadline {
    bool fired = false;
    bool armed = false;
    bool reactor = false;    // armed on the reactor (EVFILT_TIMER)
    long long deadline = 0;  // monotonic-ms deadline
};
std::mutex &g_wadl_mu = *new std::mutex();
std::unordered_map<long long, WhenAnyDeadline> &g_wadl = *new std::unordered_map<long long, WhenAnyDeadline>();

void wadl_clear(long long self) {
    std::lock_guard<std::mutex> lk(g_wadl_mu);
    g_wadl.erase(self);
}

void wadl_disarm(const long long *h, long long n, long long self) {
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    for (long long j = 0; j < n; ++j) {
        auto it = g_waiters.find(h[j]);
        if (it != g_waiters.end() && it->second == self) g_waiters.erase(it);
    }
}
}

long long nova_when_any_deadline(long long buf, long long n, long long ms, long long self) {
    const long long *h = reinterpret_cast<const long long *>(buf);

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
    const bool reactor = nova_reactor_current() != 0;
    if (found >= 0) {
        if (reactor) nova_reactor_cancel_timer(self);
        wadl_clear(self);
        return found;
    }

    // Timed out? On the reactor the deadline is measured against the monotonic clock (the timer just
    // woke us to re-check); on Asio the timer callback set `fired`.
    bool timed_out = false;
    {
        std::lock_guard<std::mutex> lk(g_wadl_mu);
        auto it = g_wadl.find(self);
        if (it != g_wadl.end() && it->second.armed) {
            if (it->second.reactor) {
                if (nova_mono_ms() >= it->second.deadline) { g_wadl.erase(it); timed_out = true; }
            } else if (it->second.fired) {
                g_wadl.erase(it); timed_out = true;
            }
        }
    }
    if (timed_out) { wadl_disarm(h, n, self); return -2; }

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
            st.reactor = true;
            long long d = ms < 0 ? 0 : ms;
            st.deadline = nova_mono_ms() + d;
            nova_reactor_set_timer(self, d);
            (void)reactor;
        } else if (st.reactor) {
            // Resumed early (a future woke us but is not done, or a spurious wake) before the
            // deadline: re-arm the one-shot reactor timer for the remaining time and keep waiting.
            long long remaining = st.deadline - nova_mono_ms();
            nova_reactor_set_timer(self, remaining < 0 ? 0 : remaining);
        }
    }
    return -1;
}

long long nova_await_future(long long future, long long waiter) {
    if (!future) return 1;
    std::lock_guard<std::mutex> lk(g_waiters_mu);
    if (raw_coro_done(future)) return 1;
    if (waiter) g_waiters[future] = waiter;
    return 0;
}

void nova_coro_hold_arg(long long coro, long long ptr, void (*dtor)(long long)) {
    if (!coro || !ptr) return;
    auto &s = g_heldargs.at(coro);
    std::lock_guard<std::mutex> lk(s.mu);
    s.map[coro].push_back({ptr, dtor});
}

// Per-reactor-thread run queue for the self-hosted runtime (docs/design/self-hosted-runtime.md,
// phase 6). When a thread is in reactor mode, nested awaits and spawns (nova_sched_schedule) are
// pushed onto this queue and driven by the reactor loop, instead of being posted to Asio. This is
// what lets an `async fn` handler with nested `await` run on the Nova reactor. Off reactor threads
// (g_reactor_mode false) the existing Asio path is used unchanged.
thread_local std::queue<long long> *g_rq = nullptr;
thread_local bool g_reactor_mode = false;
// Top-level (fire-and-forget) reactor coroutines, e.g. a connection handler from coroStart.
// These are reaped when they finish. A spawned-and-awaited coroutine is NOT here: it is reaped by
// its awaiter (via nova_coro_release), so it must survive completion until the await reads it.
thread_local std::unordered_set<long long> *g_detached = nullptr;

extern "C" void nova_reactor_detach(long long h) {
    if (!g_detached) g_detached = new std::unordered_set<long long>();
    g_detached->insert(h);
    NOVA_TRACE("detach h=%lld", h);
}

// The current thread's reactor identity (its kqueue/epoll fd), share-nothing per reactor thread.
// A reactor worker sets this once at startup so a coroutine running on the thread can build a
// reactor-native stream (reactorio) without the reactor being threaded through every call. Zero
// means "no reactor on this thread" (an Asio thread, or the main thread), so the Asio I/O path is
// used. This is what lets AsyncStream pick the reactor path transparently on a reactor thread.
thread_local long long g_current_kq = 0;
extern "C" void nova_reactor_set_current(long long kq) { g_current_kq = kq; }
extern "C" long long nova_reactor_current(void) { return g_current_kq; }

// Cross-reactor wakeup (M4): the keystone for retiring Asio. A coroutine scheduled from one reactor
// thread can be handed to its owning reactor and wake that reactor's blocking poll. Each reactor
// registers under an index with its kqueue; a thread-safe inbox holds handles posted from other
// threads; an EVFILT_USER trigger wakes the target kqueue so its poll returns. Reactors are keyed by
// a small index (0..N-1), not by a shared address, so nothing crosses threads except through the
// mutex-guarded registry and the kernel trigger.
namespace {
struct WakeBox {
    long long kq = 0;
    std::mutex mu;
    std::queue<long long> q;
};
std::mutex &g_wake_reg_mu = *new std::mutex();
std::unordered_map<long long, WakeBox *> &g_wake_reg = *new std::unordered_map<long long, WakeBox *>();
WakeBox *wake_box(long long idx) {
    std::lock_guard<std::mutex> lk(g_wake_reg_mu);
    auto it = g_wake_reg.find(idx);
    return it == g_wake_reg.end() ? nullptr : it->second;
}
}

extern "C" void nova_reactor_wake_register(long long idx, long long kq) {
    WakeBox *b;
    {
        std::lock_guard<std::mutex> lk(g_wake_reg_mu);
        auto it = g_wake_reg.find(idx);
        if (it == g_wake_reg.end()) { b = new WakeBox(); g_wake_reg[idx] = b; }
        else b = it->second;
        b->kq = kq;
    }
#if defined(NOVA_HAVE_KQUEUE)
    struct kevent ev;
    EV_SET(&ev, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, nullptr);
    kevent((int)kq, &ev, 1, nullptr, 0, nullptr);
#endif
    // IOCP needs no registration step: any thread may PostQueuedCompletionStatus to the port, so
    // recording b->kq above is the whole setup.
}

// Post a handle to reactor `idx` from any thread, and wake its poll. Safe cross-thread: the inbox is
// mutex-guarded and the EVFILT_USER trigger is kernel-synchronized.
extern "C" void nova_reactor_post(long long idx, long long handle) {
    WakeBox *b = wake_box(idx);
    if (!b) return;
    { std::lock_guard<std::mutex> lk(b->mu); b->q.push(handle); }
#if defined(NOVA_HAVE_KQUEUE)
    struct kevent ev;
    EV_SET(&ev, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, nullptr);
    kevent((int)b->kq, &ev, 1, nullptr, 0, nullptr);
#elif defined(NOVA_HAVE_IOCP)
    // PostQueuedCompletionStatus is the completion-model analogue of NOTE_TRIGGER: it queues a
    // synthetic completion so a port blocked in GetQueuedCompletionStatusEx returns at once. The
    // null OVERLAPPED is what marks it as a wake rather than finished I/O (see iocp_dispatch).
    PostQueuedCompletionStatus((HANDLE)(intptr_t)b->kq, 0, NOVA_WAKE_KEY, nullptr);
#endif
}

// Pop one handle posted to reactor `idx` (0 if empty). The reactor loop drains on an EVFILT_USER event.
extern "C" long long nova_reactor_drain_one(long long idx) {
    WakeBox *b = wake_box(idx);
    if (!b) return 0;
    std::lock_guard<std::mutex> lk(b->mu);
    if (b->q.empty()) return 0;
    long long h = b->q.front();
    b->q.pop();
    return h;
}

extern "C" long long nova_evfilt_user(void) {
#if defined(NOVA_HAVE_KQUEUE)
    return (long long)EVFILT_USER;
#else
    return 0;
#endif
}


// Coroutines reaped during the current reactor poll batch. A deadline timer and a read can both be
// ready in the same kevent batch for the same coroutine; if the read is processed first the
// coroutine may finish and its frame be freed, so resuming it for the now-stale timer event would be
// a use-after-free. The reactor loop calls nova_reactor_batch_begin() before draining a batch;
// reaping records the handle here; nova_reactor_resume skips a handle recorded this batch without
// touching its (freed) frame. Only active on reactor threads (g_reactor_mode).
thread_local std::unordered_set<long long> *g_batch_reaped = nullptr;
// Only track reaps while a read-deadline timer is active this batch. Without a deadline a coroutine
// has at most one ready event per batch, so the stale-resume race cannot happen; keeping the set
// empty then means a loop that does not call batchBegin (e.g. a plain accept loop) is never poisoned
// by accumulated handles. batchBegin clears both, so any deadline-using loop resets per batch.
thread_local bool g_deadline_active = false;
extern "C" void nova_reactor_batch_begin(void) {
    if (g_batch_reaped) g_batch_reaped->clear();
    g_deadline_active = false;
}
static inline void mark_reaped_this_batch(long long h) {
    if (!g_reactor_mode || !g_deadline_active) return;
    if (!g_batch_reaped) g_batch_reaped = new std::unordered_set<long long>();
    g_batch_reaped->insert(h);
}


// Schedule a coroutine on the reactor run queue. In reactor mode reactor_pump drains it; the one
// out-of-reactor caller is the code generator scheduling a root before nova_run_root, which clears
// g_rq and drives the root directly, so that push is a no-op. No Asio.
void nova_sched_schedule(long long handle) {
    if (!handle) return;
    if (raw_coro_done(handle)) return;
    if (!g_rq) g_rq = new std::queue<long long>();
    NOVA_TRACE("sched->rq h=%lld qlen=%zu", handle, g_rq->size() + 1);
    g_rq->push(handle);
}

// A coroutine on the reactor finished. Release its held args, then: if it has a waiter, hand
// completion to the waiter (which reads the result and destroys the frame via nova_coro_release);
// else if it is a top-level (detached) coroutine, reap it now; else (a spawned coroutine not yet
// awaited) leave the frame alive so the eventual await can read it and reap it.
static void reactor_finish(long long h) {
    nova_coro_release_held(h);
    long long w = take_waiter(h);
    NOVA_TRACE("finish h=%lld waiter=%lld", h, w);
    if (w) {
        g_rq->push(w);
        return;
    }
    if (g_detached && g_detached->erase(h)) {
        NOVA_TRACE("finish-reap-detached h=%lld", h);
        mark_reaped_this_batch(h);
        reinterpret_cast<nova_coro_fn *>(h)[1](reinterpret_cast<void *>(h));
    } else {
        NOVA_TRACE("finish-orphan h=%lld (no waiter, not detached: leaked frame)", h);
    }
}

// Drive the reactor run queue to quiescence: resume each queued coroutine (a nested await or a
// spawn), and on completion run reactor_finish. Single reactor thread, so no lock.
static void reactor_pump() {
    while (g_rq && !g_rq->empty()) {
        long long h = g_rq->front();
        g_rq->pop();
        if (raw_coro_done(h)) { NOVA_TRACE("pump skip-done h=%lld", h); continue; }
        NOVA_TRACE("pump resume h=%lld", h);
        raw_coro_resume(h);
        bool done = raw_coro_done(h);
        NOVA_TRACE("pump post-resume h=%lld done=%d", h, (int)done);
        if (done) reactor_finish(h);
    }
    NOVA_TRACE("pump drained");
}

// Drive a coroutine directly from a Nova-owned reactor loop, bypassing Asio (self-hosted runtime,
// phase 4 and 6). The coroutine was created unscheduled (coroStart) and registered its fd with the
// reactor before suspending; when the fd is ready the reactor calls this with the handle. Resumes
// it, then drives the run queue so any nested awaits or spawns run on the reactor too. Returns 1 if
// the top coroutine finished (its frame is reaped), 0 if it suspended again.
extern "C" long long nova_reactor_resume(long long h) {
    if (!g_rq) {
        g_rq = new std::queue<long long>();
        g_reactor_mode = true;
    }
    // A stale event (e.g. a deadline timer) for a coroutine already reaped this batch: skip without
    // dereferencing its freed frame.
    if (g_batch_reaped && g_batch_reaped->count(h)) return 1;
    if (!h || raw_coro_done(h)) return 1;
    NOVA_TRACE("reactor_resume enter h=%lld", h);
    raw_coro_resume(h);
    bool done = raw_coro_done(h);
    NOVA_TRACE("reactor_resume post h=%lld done=%d", h, (int)done);
    if (done) reactor_finish(h);
    reactor_pump();
    NOVA_TRACE("reactor_resume exit h=%lld ret=%d", h, done ? 1 : 0);
    return done ? 1 : 0;
}

// Share-nothing multi-core (self-hosted runtime, phase 4). Spawn n OS threads, each running the
// Nova worker closure with its reactor index. Each thread sets up its own reactor and its own
// SO_REUSEPORT listener on the shared port, so the kernel load-balances connections and there is
// no shared state across cores. Blocks until the workers return (a server's workers loop forever).
extern "C" void nova_run_reactors(long long n, long long box) {
    if (!box || n <= 0) return;
    long long fn_ptr = *reinterpret_cast<long long *>(box);
    long long env = *reinterpret_cast<long long *>(box + sizeof(long long));
    typedef void (*worker_fn)(long long, long long);
    std::vector<std::thread> ts;
    ts.reserve(static_cast<size_t>(n));
    for (long long i = 0; i < n; i++) {
        ts.emplace_back([fn_ptr, env, i]() {
            reinterpret_cast<worker_fn>(fn_ptr)(env, i);
        });
    }
    for (auto &t : ts) t.join();
}

// nova_set_reuseport retired in M6: sys.setReusePort is pure Nova over setsockopt in os/sys.

// Reap a coroutine frame (the awaiter read its result). Single reactor thread, so it is never
// concurrently running here; just run its destroy function.
void nova_coro_release(long long handle) {
    if (!handle) return;
    mark_reaped_this_batch(handle);
    reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
}

// A detached (fire-and-forget) spawn: reap it on completion (via reactor_finish's detached set),
// then schedule it on the run queue.
void nova_sched_schedule_detached(long long handle) {
    if (!handle) return;
    if (raw_coro_done(handle)) {
        reinterpret_cast<nova_coro_fn *>(handle)[1](reinterpret_cast<void *>(handle));
        return;
    }
    nova_reactor_detach(handle);
    nova_sched_schedule(handle);
}

namespace {
unsigned nova_thread_count() {
    if (const char *e = std::getenv("NOVA_THREADS")) {
        int n = std::atoi(e);
        if (n > 0) return static_cast<unsigned>(n);
    }
    unsigned n = std::thread::hardware_concurrency();
    if (n <= 1) return 1;
    n -= 1;
    if (n > 16) n = 16;
    return n;
}

}

static thread_local int g_nova_tid = 0;
long long nova_thread_id(void) { return g_nova_tid; }

static thread_local int g_run_depth = 0;
long long nova_worker_count(void) { return (long long)nova_thread_count(); }

void nova_pin_next_coro(long long rid) { g_pin_next = (int)rid; }

// No-op now (the reactor is the driver); kept for the ABI the code generator emits.
void nova_hold_all_reactors(void) {}

void nova_run_root(long long root) {

    if (g_run_depth > 0) {
        std::fprintf(stderr,
                     "nova: fatal — an async call was block-driven from inside the event loop "
                     "(a sync function awaiting async work while running as a coroutine). This "
                     "would deadlock. Make the calling function `async fn` and `await` the call, "
                     "or move the work off the request path.\n");
        std::abort();
    }
    if (!root) return;
#if defined(NOVA_HAVE_KQUEUE)
    // Single-threaded reactor drive (no Asio): the driver for async @tests and standalone async main.
    // Resume the root on this thread's own reactor; compute and channels drain through the run queue
    // during the resume, and timers and reactor-native socket I/O come back through the kqueue, which
    // the poll loop services until the root completes. The prior nova_sched_schedule(root) from the
    // caller posted to a strand that is never run here, so it is a no-op; the reactor resume is the
    // one that runs the body.
    // Fresh scheduler state for this drive. g_reactor_mode is left true by nova_reactor_resume; if it
    // leaked across drives, the caller's nova_sched_schedule(root) for the NEXT root would divert it
    // into g_rq (double-driving it). So start clean and clear the flag again at the end.
    if (!g_rq) g_rq = new std::queue<long long>();
    while (!g_rq->empty()) g_rq->pop();
    g_reactor_mode = true;
    g_deadline_active = false;
    if (g_batch_reaped) g_batch_reaped->clear();

    int kq = kqueue();
    long long prev_kq = g_current_kq;
    nova_reactor_set_current((long long)kq);
    ++g_run_depth;
    nova_reactor_resume(root);   // kick past the initial suspend and drain the run queue
    int idle = 0;
    while (!raw_coro_done(root)) {
        struct kevent evs[64];
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 20 * 1000 * 1000;   // 20ms tick
        int n = kevent(kq, nullptr, 0, evs, 64, &ts);
        if (n <= 0) {
            if (++idle > 750) break;     // ~15s lost-wakeup cap
            continue;
        }
        idle = 0;
        nova_reactor_batch_begin();
        for (int i = 0; i < n; ++i) {
            nova_reactor_resume((long long)(intptr_t)evs[i].udata);
        }
    }
    --g_run_depth;
    nova_reactor_set_current(prev_kq);
    ::close(kq);
    // Leave reactor mode so the caller's next nova_sched_schedule (e.g. the next @test's root) takes
    // the ordinary path, not this thread's run queue.
    g_reactor_mode = false;
    if (!raw_coro_done(root)) {
        std::fprintf(stderr,
                     "nova: fatal — async root %p never completed (lost wakeup); "
                     "refusing to read its unwritten result\n",
                     reinterpret_cast<void *>(root));
        std::abort();
    }
#elif defined(NOVA_HAVE_IOCP)
    // Windows: same shape as the kqueue drive above, over a completion port. IOCP is a PROACTOR —
    // a completion says "the I/O you asked for has finished, here is the byte count" rather than
    // "this fd is ready" — so the driver writes that count back into the op record before resuming
    // (iocp_dispatch), which is the step the readiness backends do not need. Timers have no kernel
    // source here and are serviced from the driver's own list.
    if (!g_rq) g_rq = new std::queue<long long>();
    while (!g_rq->empty()) g_rq->pop();
    g_reactor_mode = true;
    g_deadline_active = false;
    if (g_batch_reaped) g_batch_reaped->clear();

    HANDLE port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nullptr, 0, 0);
    long long prev_port = g_current_kq;
    nova_reactor_set_current((long long)(intptr_t)port);
    ++g_run_depth;
    nova_reactor_resume(root);   // kick past the initial suspend and drain the run queue
    int idle = 0;
    while (!raw_coro_done(root)) {
        OVERLAPPED_ENTRY entries[64];
        ULONG removed = 0;
    BOOL ok = GetQueuedCompletionStatusEx(port, entries, 64, &removed, 20, FALSE);
        if (ok && removed > 0) {
            idle = 0;
            nova_reactor_batch_begin();
            for (ULONG i = 0; i < removed; ++i) iocp_dispatch(entries[i]);
        } else if (++idle > 750) {
            break;   // ~15s lost-wakeup cap, as on kqueue
        }
    }
    --g_run_depth;
    nova_reactor_set_current(prev_port);
    CloseHandle(port);
    g_reactor_mode = false;
    if (!raw_coro_done(root)) {
        std::fprintf(stderr,
                     "nova: fatal — async root %p never completed (lost wakeup); "
                     "refusing to read its unwritten result\n",
                     reinterpret_cast<void *>(root));
        std::abort();
    }
#else
    // Linux still needs the epoll reactor driver (a follow-on); no Asio fallback remains.
    (void)root;
    std::fprintf(stderr, "nova: fatal — no reactor driver on this platform (build the epoll backend)\n");
    std::abort();
#endif
}

long long nova_io_context(void) { return 0; }

namespace {
struct NovaChan {
    std::mutex m;
    std::queue<long long> values;
    std::queue<long long> recv_waiters;
};
}

long long nova_chan_new(long long capacity) {
    (void)capacity;
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
    if (waiter) nova_sched_schedule(waiter);
}

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

// The Asio async socket primitives have been retired: async socket I/O is reactor-native
// (net/reactorio over os/sys). These symbols remain only because the code generator emits calls to
// them in the now-dead Asio branch of AsyncStream (chosen at runtime only when a stream has no
// reactor, which no longer happens); reaching one is a bug, so they abort.
[[noreturn]] static void nova_asio_removed(const char *fn) {
    std::fprintf(stderr,
        "\n[nova runtime] FATAL: %s: the Asio async socket path has been removed; async socket I/O is\n"
        "reactor-native (net/reactorio). This code path should be unreachable.\n", fn);
    std::fflush(stderr);
    std::abort();
}
long long nova_io_take_result(long long) { nova_asio_removed("nova_io_take_result"); }
void nova_io_recv_async(long long, long long, long long, long long) { nova_asio_removed("nova_io_recv_async"); }
void nova_io_accept_async(long long, long long) { nova_asio_removed("nova_io_accept_async"); }
long long nova_aserver_listen(long long) { return 0; }
long long nova_aserver_listen_addr(long long, long long) { return 0; }
void nova_aaccept(long long, long long) { nova_asio_removed("nova_aaccept"); }
void nova_aconnect(long long, long long, long long) { nova_asio_removed("nova_aconnect"); }
void nova_arecv(long long, long long, long long, long long) { nova_asio_removed("nova_arecv"); }
void nova_arecv_deadline(long long, long long, long long, long long, long long) { nova_asio_removed("nova_arecv_deadline"); }
void nova_asend(long long, long long, long long) { nova_asio_removed("nova_asend"); }
void nova_aclose(long long) {}

// Reactor-native one-shot timer (M4, retiring the Asio steady_timer for reactor coroutines): arm an
// EVFILT_TIMER on the current reactor's kqueue keyed by the coroutine handle, so the reactor loop
// resumes the coroutine when it fires (udata carries the handle, exactly like a ready fd). No Asio,
// no thread held. One-shot, so it auto-removes after firing.
static void nova_reactor_arm_timer(long long handle, long long ms) {
#if defined(NOVA_HAVE_KQUEUE)
    int kq = (int)g_current_kq;
    if (kq <= 0) { NOVA_TRACE("reactor timer: no current kq h=%lld", handle); return; }
    struct kevent ev;
    EV_SET(&ev, (uintptr_t)handle, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0,
           (int64_t)(ms < 0 ? 0 : ms), (void *)(uintptr_t)handle);
    kevent(kq, &ev, 1, nullptr, 0, nullptr);
    NOVA_TRACE("reactor timer armed h=%lld ms=%lld kq=%d", handle, ms, kq);
#elif defined(NOVA_HAVE_IOCP)
    // No kernel timer source on a completion port; the driver's own list carries the deadline and
    // clamps the next poll timeout to it (see iocp_timer_arm).
    if (g_current_kq == 0) { NOVA_TRACE("reactor timer: no current port h=%lld", handle); return; }
    iocp_timer_arm(handle, ms);
    NOVA_TRACE("reactor timer armed h=%lld ms=%lld (iocp)", handle, ms);
#else
    (void)handle; (void)ms;   // Linux epoll timerfd path plugs in with the epoll backend.
#endif
}

// Explicit reactor-timer control for deadlines (reactorio.recvIntoDeadline): arm a one-shot timer
// keyed by the coroutine handle, and cancel it. nova_reactor_arm_timer is the shared implementation.
extern "C" void nova_reactor_set_timer(long long handle, long long ms) {
    if (!handle) return;
    g_deadline_active = true;   // arm the batch-reap guard for this batch's stale-timer protection
    nova_reactor_arm_timer(handle, ms);
}
extern "C" void nova_reactor_cancel_timer(long long handle) {
#if defined(NOVA_HAVE_KQUEUE)
    int kq = (int)g_current_kq;
    if (kq <= 0 || !handle) return;
    struct kevent ev;
    EV_SET(&ev, (uintptr_t)handle, EVFILT_TIMER, EV_DELETE, 0, 0, nullptr);
    kevent(kq, &ev, 1, nullptr, 0, nullptr);   // ENOENT if already fired/absent, harmless
#elif defined(NOVA_HAVE_IOCP)
    if (!handle) return;
    iocp_timer_cancel(handle);   // absent is fine (already fired), as with EV_DELETE's ENOENT
#else
    (void)handle;
#endif
}

void nova_await_timer(long long handle, long long ms) {
    if (!handle) return;
    nova_reactor_arm_timer(handle, ms);   // reactor-native; all async runs on the reactor now
}

long long nova_sched_next(void) { return 0; }

void nova_set_args(int argc, char **argv);
int main(int argc, char **argv) {
    nova_set_args(argc, argv);
    return static_cast<int>(__nova_main());
}

}
