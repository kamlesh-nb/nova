
#include "nova_abi.h"
#include <boost/asio.hpp>
#ifndef _WIN32
#include <sys/socket.h>
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
#include <unordered_set>
#include <vector>

extern "C" long long __nova_main(void);

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

struct Reactor {
    boost::asio::io_context io;
    int id;
    explicit Reactor(int i) : id(i) {}
};
std::vector<Reactor *> &g_reactors = *new std::vector<Reactor *>{new Reactor(0)};

thread_local int g_reactor_id = 0;

thread_local int g_pin_next = -1;

boost::asio::io_context &g_io = g_reactors[0]->io;

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

struct CoroState {
    std::mutex mu;
    bool running = false;
    bool pending_resume = false;
    bool is_detached = false;

    bool destroy_when_idle = false;

    int reactor_id;

    boost::asio::strand<boost::asio::io_context::executor_type> strand;

    CoroState()
        : reactor_id(g_pin_next >= 0 ? g_pin_next : g_reactor_id),
          strand(boost::asio::make_strand(g_reactors[reactor_id]->io)) {
        if (g_pin_next >= 0) g_pin_next = -1;
    }
};

StripedMap<std::shared_ptr<CoroState>> &g_corostates = *new StripedMap<std::shared_ptr<CoroState>>();

std::shared_ptr<CoroState> get_coro_state(long long handle) {
    auto &s = g_corostates.at(handle);
    std::lock_guard<std::mutex> lk(s.mu);
    auto it = s.map.find(handle);
    if (it == s.map.end()) {
        auto state = std::make_shared<CoroState>();
        s.map[handle] = state;
        return state;
    }
    return it->second;
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
    std::shared_ptr<boost::asio::steady_timer> timer;
    bool fired = false;
    bool armed = false;
};
std::mutex &g_wadl_mu = *new std::mutex();
std::unordered_map<long long, WhenAnyDeadline> &g_wadl = *new std::unordered_map<long long, WhenAnyDeadline>();

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
    if (found >= 0) { wadl_clear(self); return found; }

    bool timed_out = false;
    {
        std::lock_guard<std::mutex> lk(g_wadl_mu);
        auto it = g_wadl.find(self);
        if (it != g_wadl.end() && it->second.fired) { g_wadl.erase(it); timed_out = true; }
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
            st.timer = std::make_shared<boost::asio::steady_timer>(g_io);
            st.timer->expires_after(std::chrono::milliseconds(ms < 0 ? 0 : ms));
            long long self_c = self;
            st.timer->async_wait([self_c](const boost::system::error_code &ec) {
                if (ec) return;
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

// Loud abort when a coroutine driven by the Nova reactor suspends on an Asio-backed I/O primitive.
// The reactor thread runs its own poll loop (kqueue/epoll) and never runs the Asio io_context, so
// such a completion can never fire: the coroutine (and its connection) would be silently orphaned.
// Rather than hang or return a wrong value, we fail fast and name the primitive, so the boundary is
// explicit. These primitives are migrated to the reactor in a later phase of the retirement plan
// (docs/design/cpp-runtime-retirement-plan.md); until then, use the reactor-native socket path
// (os.read / os.write + coroSuspend) inside reactor handlers, or run the handler under the Asio
// scheduler (NOVA_THREADS) instead of the reactor.
[[noreturn]] static void nova_reactor_io_violation(const char *prim) {
    NOVA_TRACE("FATAL reactor_io_violation prim=%s", prim);
    std::fprintf(stderr,
        "\n[nova runtime] FATAL: awaited '%s' (Asio-backed I/O) on a coroutine driven by the Nova\n"
        "reactor. The reactor does not run the Asio io_context, so this completion can never fire\n"
        "and the coroutine would be orphaned. Asio-backed I/O is not yet migrated to the reactor\n"
        "(see docs/design/cpp-runtime-retirement-plan.md). Use the reactor-native socket path\n"
        "(os.read / os.write + coroSuspend), or run this handler under NOVA_THREADS, not the reactor.\n",
        prim);
    std::fflush(stderr);
    std::abort();
}
#define NOVA_REACTOR_GUARD(prim) do { if (g_reactor_mode) nova_reactor_io_violation(prim); } while (0)

void nova_sched_schedule(long long handle) {
    if (!handle) return;
    if (raw_coro_done(handle)) return;

    if (g_reactor_mode) { NOVA_TRACE("sched->rq h=%lld qlen=%zu", handle, g_rq->size() + 1); g_rq->push(handle); return; }

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

            bool destroy_self;
            bool deferred_destroy;
            {
                std::lock_guard<std::mutex> lk(state->mu);
                state->running = false;
                destroy_self = state->is_detached;
                deferred_destroy = state->destroy_when_idle;
                state->destroy_when_idle = false;
            }

            {
                auto &cs = g_corostates.at(handle);
                std::lock_guard<std::mutex> glk(cs.mu);
                cs.map.erase(handle);
            }

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

            if (raw_coro_done(handle)) {
                state->running = false;
                destroy_self = state->is_detached;
                deferred_destroy = state->destroy_when_idle;
                state->destroy_when_idle = false;
                finished = true;
            } else if (state->pending_resume) {
                state->pending_resume = false;

                state->running = false;
                resume_again = true;
            } else {
                state->running = false;
            }
        }

        if (finished) {
            {
                auto &cs = g_corostates.at(handle);
                std::lock_guard<std::mutex> glk(cs.mu);
                cs.map.erase(handle);
            }

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

        if (resume_again) {
            nova_sched_schedule(handle);
        }
    });
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

// SO_REUSEPORT via the C macro (portable; the numeric value differs by platform).
extern "C" long long nova_set_reuseport(long long fd) {
    int one = 1;
    int r = 0;
#ifdef SO_REUSEPORT
    r = ::setsockopt((int)fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
    return (long long)r;
}

void nova_coro_release(long long handle) {
    if (!handle) return;
    std::shared_ptr<CoroState> state;
    {
        auto &cs = g_corostates.at(handle);
        std::lock_guard<std::mutex> glk(cs.mu);
        auto it = cs.map.find(handle);
        if (it != cs.map.end()) state = it->second;
    }
    if (state) {
        {
            std::lock_guard<std::mutex> lk(state->mu);
            if (state->running) {

                state->destroy_when_idle = true;
                return;
            }
        }

        auto &cs = g_corostates.at(handle);
        std::lock_guard<std::mutex> glk(cs.mu);
        cs.map.erase(handle);
    }

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

void ensure_reactors(int n) {
    while (static_cast<int>(g_reactors.size()) < n)
        g_reactors.push_back(new Reactor(static_cast<int>(g_reactors.size())));
}
}

static thread_local int g_nova_tid = 0;
long long nova_thread_id(void) { return g_nova_tid; }

static thread_local int g_run_depth = 0;
long long nova_worker_count(void) { return (long long)nova_thread_count(); }

void nova_pin_next_coro(long long rid) { g_pin_next = (int)rid; }

void nova_run(void) {

    const int n = static_cast<int>(nova_thread_count());
    ensure_reactors(n);
    std::vector<std::thread> pool;
    if (n > 1) pool.reserve(static_cast<size_t>(n - 1));
    for (int i = 1; i < n; ++i)
        pool.emplace_back([i] {
            g_nova_tid = i;
            g_reactor_id = i;
            ++g_run_depth;
            g_reactors[i]->io.run();
            --g_run_depth;
        });
    g_nova_tid = 0;
    g_reactor_id = 0;
    ++g_run_depth;
    g_reactors[0]->io.run();
    --g_run_depth;
    for (auto &t : pool) t.join();
    for (int i = 0; i < n; ++i) g_reactors[i]->io.restart();
}

std::vector<boost::asio::executor_work_guard<boost::asio::io_context::executor_type>> &g_server_guards =
    *new std::vector<boost::asio::executor_work_guard<boost::asio::io_context::executor_type>>();
void nova_hold_all_reactors(void) {
    const int n = static_cast<int>(nova_thread_count());
    ensure_reactors(n);
    for (int i = 0; i < n; ++i)
        g_server_guards.push_back(boost::asio::make_work_guard(g_reactors[i]->io));
}

void nova_run_root(long long root) {

    if (g_run_depth > 0) {
        std::fprintf(stderr,
                     "nova: fatal — an async call was block-driven from inside the event loop "
                     "(a sync function awaiting async work while running as a coroutine). This "
                     "would deadlock. Make the calling function `async fn` and `await` the call, "
                     "or move the work off the request path.\n");
        std::abort();
    }
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

long long nova_io_context(void) { return reinterpret_cast<long long>(&g_io); }

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

namespace {

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
}

long long nova_io_take_result(long long self) {
    std::lock_guard<std::mutex> lk(g_ioresult_mu);
    auto it = g_ioresults.find(self);
    if (it == g_ioresults.end()) return -1;
    long long r = it->second;
    g_ioresults.erase(it);
    return r;
}

void nova_io_recv_async(long long fd, long long buf, long long max_len, long long self) {
    boost::asio::post(io_pool(), [fd, buf, max_len, self]() {
        long long n = nova_socket_recv((int)fd, reinterpret_cast<char *>(buf), (int)max_len);
        stash_io_result(self, n);
        nova_sched_schedule(self);
    });
}

void nova_io_accept_async(long long server_fd, long long self) {
    boost::asio::post(io_pool(), [server_fd, self]() {
        long long fd = nova_socket_accept((int)server_fd);
        stash_io_result(self, fd);
        nova_sched_schedule(self);
    });
}

namespace {
struct NovaAcceptor {
    boost::asio::ip::tcp::acceptor acc;

    NovaAcceptor(boost::asio::io_context &io, const std::string &host, unsigned short port) : acc(io) {
        boost::asio::ip::tcp::endpoint ep(boost::asio::ip::tcp::v4(), port);
        if (!host.empty()) {
            boost::system::error_code aec;
            auto a = boost::asio::ip::make_address(host, aec);
            if (!aec)
                ep = boost::asio::ip::tcp::endpoint(a, port);
        }
        acc.open(ep.protocol());
        acc.set_option(boost::asio::socket_base::reuse_address(true));
#ifdef SO_REUSEPORT

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
}

long long nova_aserver_listen(long long port) {
    try {
        return reinterpret_cast<long long>(new NovaAcceptor(g_reactors[g_reactor_id]->io, "", (unsigned short)port));
    } catch (...) {
        return 0;
    }
}

long long nova_aserver_listen_addr(long long host, long long port) {
    const char *h = reinterpret_cast<const char *>(host);
    int hlen = h ? *reinterpret_cast<const int *>(h - 4) : 0;
    std::string host_s(h ? h : "", hlen < 0 ? 0 : hlen);
    try {
        return reinterpret_cast<long long>(new NovaAcceptor(g_reactors[g_reactor_id]->io, host_s, (unsigned short)port));
    } catch (...) {
        return 0;
    }
}

void nova_aaccept(long long server, long long self) {
    NOVA_REACTOR_GUARD("aaccept");
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

void nova_aconnect(long long host, long long port, long long self) {
    NOVA_REACTOR_GUARD("aconnect");
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

static inline bool nova_io_bad_socket(NovaSocket *s, long long self) {
    if (s) return false;
    stash_io_result(self, -1);
    nova_sched_schedule(self);
    return true;
}

void nova_arecv(long long sock, long long buf, long long max_len, long long self) {
    NOVA_REACTOR_GUARD("arecv");
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    if (nova_io_bad_socket(s, self)) return;
    auto state = get_coro_state(self);
    s->sock.async_read_some(
        boost::asio::buffer(reinterpret_cast<char *>(buf), (size_t)max_len),
        boost::asio::bind_executor(state->strand, [self](const boost::system::error_code &ec, size_t n) {
            stash_io_result(self, ec ? -1 : (long long)n);
            nova_sched_schedule(self);
        }));
}

void nova_arecv_deadline(long long sock, long long buf, long long max_len, long long ms, long long self) {
    NOVA_REACTOR_GUARD("arecv_deadline");
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    if (nova_io_bad_socket(s, self)) return;
    auto state = get_coro_state(self);
    auto done = std::make_shared<bool>(false);
    auto timer = std::make_shared<boost::asio::steady_timer>(g_io);
    timer->expires_after(std::chrono::milliseconds(ms < 0 ? 0 : ms));
    s->sock.async_read_some(
        boost::asio::buffer(reinterpret_cast<char *>(buf), (size_t)max_len),
        boost::asio::bind_executor(state->strand, [self, done, timer](const boost::system::error_code &ec, size_t n) {
            if (*done) return;
            *done = true;
            timer->cancel();
            stash_io_result(self, ec ? -1 : (long long)n);
            nova_sched_schedule(self);
        }));
    timer->async_wait(boost::asio::bind_executor(state->strand, [self, done, s](const boost::system::error_code &ec) {
        if (*done || ec) return;
        *done = true;
        boost::system::error_code ic;
        s->sock.cancel(ic);
        stash_io_result(self, -2);
        nova_sched_schedule(self);
    }));
}

void nova_asend(long long sock, long long data, long long self) {
    NOVA_REACTOR_GUARD("asend");
    auto *s = reinterpret_cast<NovaSocket *>(sock);
    if (nova_io_bad_socket(s, self)) return;
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

    s->sock.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ec);
    s->sock.close(ec);
    delete s;
}

void nova_await_timer(long long handle, long long ms) {
    if (!handle) return;
    NOVA_REACTOR_GUARD("sleep/timer");
    auto timer = std::make_shared<boost::asio::steady_timer>(
        g_io, std::chrono::milliseconds(ms < 0 ? 0 : ms));
    timer->async_wait([handle, timer](const boost::system::error_code &) {
        nova_sched_schedule(handle);
    });
}

long long nova_sched_next(void) { return 0; }

void nova_set_args(int argc, char **argv);
int main(int argc, char **argv) {
    nova_set_args(argc, argv);
    return static_cast<int>(__nova_main());
}

}
