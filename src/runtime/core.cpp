
#include "nova_abi.h"
#include "runtime_str.h"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <queue>
#include <shared_mutex>
#include <thread>
#ifdef _WIN32
#include <winsock2.h>  // MUST precede <windows.h> so the winsock v2 symbols win over v1
#include <ws2tcpip.h>
#include <windows.h>
#include <io.h>
#include <stdlib.h>
#else
#include <unistd.h>
#include <sys/socket.h>  // fd-passing (SCM_RIGHTS) shims below
#endif

// --- crash diagnostics (opt-in: NOVA_CRASH_TRACE=1) ---------------------------------------------
// A fatal signal in a release build is otherwise just "Segmentation fault" with nothing to act on,
// and a debugger is not always installable on the host where it reproduces. With this on, the
// process prints its return-address stack to stderr before dying; llvm-symbolizer / addr2line turn
// that into lines. Async-signal-safe: only backtrace(), write(), and _exit() run in the handler.
#if defined(__linux__) || defined(__APPLE__)
#include <csignal>
// backtrace()/execinfo.h exist on glibc and macOS, but NOT musl (musl ships no execinfo.h). Gate the
// stack-trace parts so a musl cross-compile (e.g. x86_64-linux-musl, the T1 static Linux target) still
// builds; on musl the handler prints the signal + fault address without frames.
#if defined(__GLIBC__) || defined(__APPLE__)
#include <execinfo.h>
#define NOVA_HAVE_BACKTRACE 1
#else
// musl (and other libcs without execinfo) still have the unwind ABI from libgcc/compiler-rt, so we
// can walk return addresses even without backtrace()/backtrace_symbols().
#include <unwind.h>
#define NOVA_HAVE_UNWIND 1
#endif

namespace {
void nova_write_lit(const char *s) { (void)!::write(2, s, std::strlen(s)); }

void nova_write_hex(unsigned long long v) {
  char h[16];
  int len = 0;
  if (v == 0) h[len++] = '0';
  while (v > 0) { int nib = (int)(v & 0xF); h[len++] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10); v >>= 4; }
  nova_write_lit("0x");
  while (len > 0) { --len; (void)!::write(2, &h[len], 1); }
}

void nova_crash_handler(int sig, siginfo_t *info, void *) {
#if defined(NOVA_HAVE_BACKTRACE)
  void *frames[64];
  int n = ::backtrace(frames, 64);
#endif
  nova_write_lit("\n=== NOVA CRASH: fatal signal ");
  nova_write_hex((unsigned long long)sig);
  // The faulting address is the whole diagnosis for a bad dereference: near-zero means a null
  // base, a small value means an offset off a null, and a wild value means a corrupted pointer.
  nova_write_lit(" at fault addr ");
  nova_write_hex((unsigned long long)(uintptr_t)(info ? info->si_addr : nullptr));
  nova_write_lit(" ===\n");
#if defined(NOVA_HAVE_BACKTRACE)
  ::backtrace_symbols_fd(frames, n, 2);
#else
  nova_write_lit("(no backtrace: this libc has no execinfo.h)\n");
#endif
  nova_write_lit("=== end crash ===\n");
  ::_exit(128 + sig);
}

__attribute__((constructor)) void nova_install_crash_handler() {
  if (!std::getenv("NOVA_CRASH_TRACE")) return;
  // An ALTERNATE stack is what makes this useful for the most common fatal fault of all: running
  // out of stack. That SIGSEGV is delivered on the very stack that just overflowed, so a normal
  // handler faults again immediately and the process dies silently with no output at all -- which
  // is indistinguishable from "the handler was never installed".
  // Fixed size, NOT SIGSTKSZ: modern glibc defines that as sysconf(_SC_SIGSTKSZ), which is not a
  // constant expression, so using it here would declare a variable-length array. 64K is far more
  // than backtrace() + write() need.
  static char altstack[65536];
  stack_t ss;
  std::memset(&ss, 0, sizeof(ss));
  ss.ss_sp = altstack;
  ss.ss_size = sizeof(altstack);
  ss.ss_flags = 0;
  ::sigaltstack(&ss, nullptr);

  struct sigaction sa;
  std::memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = nova_crash_handler;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  // NOT `::sigemptyset` — on macOS sigemptyset is a MACRO, and a macro cannot be namespace-
  // qualified (`::` then expands onto `(*(set)=0,0)` and fails to parse). Unqualified resolves to
  // the macro on macOS and to the global function on Linux, so both platforms build.
  sigemptyset(&sa.sa_mask);
  ::sigaction(SIGSEGV, &sa, nullptr);
  ::sigaction(SIGBUS, &sa, nullptr);
  ::sigaction(SIGILL, &sa, nullptr);
  ::sigaction(SIGFPE, &sa, nullptr);
}
}  // namespace
#endif

extern "C" {

void nova_log_string(const char *s) {
  if (!s)
    return;
  char *c = nova_to_cstr(s);
  if (c) {
    std::puts(c);
    std::fflush(stdout);
    nova_free_cstr(s, c);
  }
}
void nova_log_info(const char *s) {
  if (!s)
    return;
  char *c = nova_to_cstr(s);
  if (c) {
    std::printf("\x1b[34m[INFO]\x1b[0m %s\n", c);
    std::fflush(stdout);
    nova_free_cstr(s, c);
  }
}
void nova_log_debug(const char *s) {
  if (!s)
    return;
  char *c = nova_to_cstr(s);
  if (c) {
    std::printf("\x1b[90m[DEBUG]\x1b[0m %s\n", c);
    std::fflush(stdout);
    nova_free_cstr(s, c);
  }
}
void nova_log_err(const char *s) {
  if (!s)
    return;
  char *c = nova_to_cstr(s);
  if (c) {
    std::fprintf(stderr, "\x1b[31m[ERROR]\x1b[0m %s\n", c);
    std::fflush(stderr);
    nova_free_cstr(s, c);
  }
}

// --- Runtime trace facility (M0) -------------------------------------------------------------
// A file-based, per-line-flushed trace, gated on the NOVA_TRACE env var, so runtime diagnostics
// always surface (the scheduler debug was blocked by stderr being swallowed). Load-once gate, so
// disabled cost is a single relaxed load; enabled cost is a mutexed unbuffered fprintf.
static const bool g_trace_on = std::getenv("NOVA_TRACE") != nullptr;
static std::mutex g_trace_mu;
static std::FILE *g_trace_fp = nullptr;

static std::FILE *nova_trace_fp() {
    if (!g_trace_fp) {
        const char *path = std::getenv("NOVA_TRACE");
        if (!path) return nullptr;
        g_trace_fp = std::fopen(path, "a");
        if (g_trace_fp) std::setvbuf(g_trace_fp, nullptr, _IONBF, 0); // unbuffered
    }
    return g_trace_fp;
}

int nova_trace_enabled(void) { return g_trace_on ? 1 : 0; }

void nova_trace_line(const char *s) {
    if (!g_trace_on) return;
    std::lock_guard<std::mutex> lk(g_trace_mu);
    std::FILE *fp = nova_trace_fp();
    if (!fp) return;
    std::fprintf(fp, "%s\n", s ? s : "");
    std::fflush(fp);
}

void nova_trace_msg(long long nova_str) {
    if (!g_trace_on) return;
    char *c = nova_to_cstr(reinterpret_cast<const char *>(nova_str));
    nova_trace_line(c);
    nova_free_cstr(reinterpret_cast<const char *>(nova_str), c);
}

void nova_trace_kv(long long nova_str, long long value) {
    if (!g_trace_on) return;
    char *c = nova_to_cstr(reinterpret_cast<const char *>(nova_str));
    std::lock_guard<std::mutex> lk(g_trace_mu);
    std::FILE *fp = nova_trace_fp();
    if (fp) { std::fprintf(fp, "%s=%lld\n", c ? c : "", value); std::fflush(fp); }
    nova_free_cstr(reinterpret_cast<const char *>(nova_str), c);
}
// C++-internal variadic trace, used via the NOVA_TRACE macro (nova_abi.h).
void nova_tracef(const char *fmt, ...) {
    if (!g_trace_on) return;
    std::lock_guard<std::mutex> lk(g_trace_mu);
    std::FILE *fp = nova_trace_fp();
    if (!fp) return;
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(fp, fmt, ap);
    va_end(ap);
    std::fputc('\n', fp);
    std::fflush(fp);
}

// --- reactor op-record pool ----------------------------------------------------------------------
// net/reactorio allocates a fresh op record for EVERY read and write, then frees it — a malloc/free
// pair per I/O on the hottest path in the server. The records are fixed-size and strictly
// thread-confined (a reactor worker owns its coroutines), so a thread-local free list retires that
// traffic entirely: reuse is a pointer swap. Capped so an idle worker does not sit on memory.
namespace {
const int NOVA_OP_POOL_MAX = 256;
thread_local void *g_op_pool[NOVA_OP_POOL_MAX];
thread_local int g_op_pool_n = 0;
thread_local long long g_op_pool_size = 0;
}

// `size` is eventloop.OP_SIZE, which differs per backend, so the pool is sized by the first caller
// and reset if a larger record is ever requested.
long long nova_op_alloc(long long size) {
  if (size != g_op_pool_size) {
    // Backend changed the record size (only possible before any I/O); drop what we hold.
    for (int i = 0; i < g_op_pool_n; ++i) std::free(g_op_pool[i]);
    g_op_pool_n = 0;
    g_op_pool_size = size;
  }
  if (g_op_pool_n > 0) return (long long)(intptr_t)g_op_pool[--g_op_pool_n];
  return (long long)(intptr_t)std::malloc((size_t)size);
}

void nova_op_free(long long op) {
  if (!op) return;
  if (g_op_pool_n < NOVA_OP_POOL_MAX) {
    g_op_pool[g_op_pool_n++] = (void *)(intptr_t)op;
    return;
  }
  std::free((void *)(intptr_t)op);
}

// --- I/O accounting (opt-in: NOVA_IO_WATCHDOG=1) ------------------------------------------------
// Answers the one question a stalled proactor cannot otherwise be asked: are operations OUTSTANDING
// in the kernel (issued but never completed), or has the application simply stopped issuing them?
// Those two have completely different causes and are indistinguishable from the outside -- in both
// the process sits at 0% CPU with connections established.
namespace {
std::atomic<long long> g_io_issued{0};
std::atomic<long long> g_io_completed{0};
std::atomic<long long> g_resume_skipped{0};
std::atomic<bool> g_io_watchdog_started{false};
}

extern "C" void nova_io_stat_issued(void)    { g_io_issued.fetch_add(1, std::memory_order_relaxed); }
extern "C" void nova_io_stat_completed(void) { g_io_completed.fetch_add(1, std::memory_order_relaxed); }
extern "C" void nova_io_stat_resume_skipped(void) { g_resume_skipped.fetch_add(1, std::memory_order_relaxed); }

extern "C" void nova_io_watchdog_start(void) {
  if (!std::getenv("NOVA_IO_WATCHDOG")) return;
  bool expected = false;
  if (!g_io_watchdog_started.compare_exchange_strong(expected, true)) return;
  // M-4: the watchdog runs on its own thread; switch ARC to atomic before it starts.
  nova_arc_go_multithreaded();
  std::thread([] {
    long long prev_i = -1, prev_c = -1;
    for (;;) {
      std::this_thread::sleep_for(std::chrono::seconds(2));
      long long i = g_io_issued.load(std::memory_order_relaxed);
      long long c = g_io_completed.load(std::memory_order_relaxed);
      const char *tag = (i == prev_i && c == prev_c) ? "  <- IDLE (nothing moving)" : "";
      std::fprintf(stderr, "nova io: issued=%lld completed=%lld outstanding=%lld resume_skipped=%lld%s\n",
                   i, c, i - c, g_resume_skipped.load(std::memory_order_relaxed), tag);
      prev_i = i; prev_c = c;
    }
  }).detach();
}

long long nova_ffi_errno(void) { return (long long)errno; }
void nova_ffi_set_errno(long long v) { errno = (int)v; }
// fcntl is variadic; a non-variadic FFI declaration mispasses the third arg on some ABIs
// (arm64 passes varargs on the stack). This shim lets C handle the varargs correctly.
long long nova_set_nonblock(long long fd) {
#ifdef _WIN32
  // Sockets on Windows are made non-blocking with ioctlsocket(FIONBIO), not fcntl.
  u_long nb = 1;
  return (long long)::ioctlsocket((SOCKET)fd, FIONBIO, &nb);
#else
  int f = fcntl((int)fd, F_GETFL, 0);
  if (f < 0) return -1;
  return (long long)fcntl((int)fd, F_SETFL, f | O_NONBLOCK);
#endif
}
// open(2) is variadic (int open(const char*, int, ...)); a non-variadic FFI declaration
// mispasses the mode argument on arm64 (varargs go on the stack, not in registers), exactly
// as with fcntl above. This tiny shim lets C forward the mode correctly. It is the only C
// left under io/file after M5; everything else in file and directory I/O is Nova over os/sys.
long long nova_open(const char *path, long long flags, long long mode) {
  return (long long)::open(path, (int)flags, (unsigned int)mode);
}

// Blocking sleep for `ms` milliseconds (a coarse wait for polling/retry backoffs — e.g. an fd-handoff
// app waiting for the service's rendezvous socket to appear). No reactor involved.
void nova_sleep_ms(long long ms) {
  if (ms <= 0) return;
#ifdef _WIN32
  ::Sleep((unsigned long)ms);
#else
  struct timespec ts;
  ts.tv_sec = (time_t)(ms / 1000);
  ts.tv_nsec = (long)((ms % 1000) * 1000000L);
  ::nanosleep(&ts, nullptr);
#endif
}

// --- fd passing (SCM_RIGHTS) -------------------------------------------------------------------
// The "connection handoff" primitive: a process accepts a client socket and passes that open fd to
// a sibling process over a connected AF_UNIX socket, so the sibling replies to the client directly
// and the accepter drops out of the data path (the fire-and-forget proxy design). This must be a C
// shim because sendmsg/recvmsg carry the fd in a `struct msghdr` + `struct cmsghdr` ancillary block
// whose macros (CMSG_SPACE/CMSG_FIRSTHDR/CMSG_DATA) and field offsets are not expressible over the
// raw-bytes FFI idiom os/sys uses, and differ across kernels. POSIX only; Windows fd-passing needs
// WSADuplicateSocket + a separate protocol, deferred (the stubs return -1).

// Send `fd` plus `len` bytes of ordinary payload (the already-consumed request prefix) over the
// connected AF_UNIX socket `sock`. At least one payload byte always travels, since a zero-length
// datagram would not carry the ancillary block reliably. Returns bytes sent (>=0) or -1.
long long nova_send_fd(long long sock, const char *data, long long len, long long fd) {
#ifdef _WIN32
  (void)sock; (void)data; (void)len; (void)fd;
  return -1;
#else
  struct msghdr msg;
  memset(&msg, 0, sizeof(msg));
  char dummy = 0;
  struct iovec iov;
  iov.iov_base = (void *)(len > 0 ? data : &dummy);
  iov.iov_len = (size_t)(len > 0 ? len : 1);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  union {
    char buf[CMSG_SPACE(sizeof(int))];
    struct cmsghdr align;
  } u;
  memset(u.buf, 0, sizeof(u.buf));
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);
  struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
  cm->cmsg_level = SOL_SOCKET;
  cm->cmsg_type = SCM_RIGHTS;
  cm->cmsg_len = CMSG_LEN(sizeof(int));
  int sfd = (int)fd;
  memcpy(CMSG_DATA(cm), &sfd, sizeof(int));
  ssize_t n;
  do { n = sendmsg((int)sock, &msg, 0); } while (n < 0 && errno == EINTR);
  return (long long)n;
#endif
}

// Receive an fd (and up to `cap` payload bytes) from the connected AF_UNIX socket `sock`. Writes the
// received fd to *(int*)out_fd_ptr, or -1 if none arrived. Returns payload bytes (0 = peer closed) or
// -1. The caller owns the received fd and must close it.
long long nova_recv_fd(long long sock, char *buf, long long cap, long long out_fd_ptr) {
#ifdef _WIN32
  (void)sock; (void)buf; (void)cap;
  if (out_fd_ptr) *reinterpret_cast<int *>(out_fd_ptr) = -1;
  return -1;
#else
  struct msghdr msg;
  memset(&msg, 0, sizeof(msg));
  struct iovec iov;
  iov.iov_base = buf;
  iov.iov_len = (size_t)cap;
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  union {
    char buf[CMSG_SPACE(sizeof(int))];
    struct cmsghdr align;
  } u;
  memset(u.buf, 0, sizeof(u.buf));
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);
  ssize_t n;
  do { n = recvmsg((int)sock, &msg, 0); } while (n < 0 && errno == EINTR);
  int got = -1;
  if (n >= 0) {
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm != nullptr;
         cm = CMSG_NXTHDR(&msg, cm)) {
      if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
        memcpy(&got, CMSG_DATA(cm), sizeof(int));
        break;
      }
    }
  }
  if (out_fd_ptr) *reinterpret_cast<int *>(out_fd_ptr) = got;
  return (long long)n;
#endif
}
char *nova_ffi_to_cstr(const char *nova_str) { return nova_to_cstr(nova_str); }
void nova_ffi_free_cstr(const char *nova_str, char *c) { nova_free_cstr(nova_str, c); }
const char *nova_ffi_from_cstr(const char *c) {
  if (!c)
    return nova_from_cstr("");
  return nova_from_cstr(c);
}

typedef long long (*nova_str_closure_fn)(long long env, long long arg);
long long nova_invoke_str_closure(long long box, long long arg) {
  if (!box)
    return (long long)nova_from_cstr("");
  long long fn_ptr = *reinterpret_cast<long long *>(box);
  long long env = *reinterpret_cast<long long *>(box + sizeof(long long));
  return reinterpret_cast<nova_str_closure_fn>(fn_ptr)(env, arg);
}

typedef long long (*nova_void_closure_fn)(long long env);
void nova_invoke_void_closure(long long box) {
  if (!box)
    return;
  long long fn_ptr = *reinterpret_cast<long long *>(box);
  long long env = *reinterpret_cast<long long *>(box + sizeof(long long));
  reinterpret_cast<nova_void_closure_fn>(fn_ptr)(env);
}

void nova_exit(int code) { std::_Exit(code); }
int64_t nova_time_now(void) {
  using namespace std::chrono;
  return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}
int64_t nova_time_now_ns(void) {
  using namespace std::chrono;
  return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
}
// Monotonic milliseconds, for measuring timeouts/deadlines (immune to wall-clock jumps).
int64_t nova_mono_ms(void) {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

namespace {
thread_local int t_failed = 0;
thread_local char t_msg[1024] = {0};
}
void nova_test_reset(void) {
  t_failed = 0;
  t_msg[0] = '\0';
}

static char t_current[256] = "";
void nova_test_begin(const char *name) {
  if (!name) {
    t_current[0] = '\0';
    return;
  }
  int i = 0;

  while (name[i] && i < (int)sizeof(t_current) - 1) {
    t_current[i] = name[i];
    i++;
  }
  t_current[i] = '\0';
}

void nova_test_fail(const char *msg) {
  t_failed = 1;
  if (msg) {

    const int n = *reinterpret_cast<const int *>(msg - 4);
    const int cap = (int)sizeof(t_msg) - 1;
    const int len = (n < 0) ? 0 : (n > cap ? cap : n);
    std::memcpy(t_msg, msg, (size_t)len);
    t_msg[len] = '\0';
  } else {
    t_msg[0] = '\0';
  }
  if (t_current[0])
    std::fprintf(stderr, "\n  FAIL  %s\n        %s\n", t_current,
                 t_msg[0] ? t_msg : "assertion failed");
  else
    std::fprintf(stderr, "\nAssertion failed: %s\n", t_msg[0] ? t_msg : "(no message)");
  std::fprintf(stderr, "\n  (the suite aborts at the first failing assertion, a test cannot be\n"
                       "   unwound out of, so later tests do not run. Fix this one and re-run.)\n");
  std::_Exit(1);
}
int nova_test_did_fail(void) { return t_failed; }
const char *nova_test_fail_message(void) {
  int len = (int)std::strlen(t_msg);
  long long p = nova_bytes_alloc(len);
  if (!p)
    return "";
  std::memcpy((char *)p, t_msg, len);
  return (const char *)p;
}

long long *__nova_cov_counters = nullptr;
namespace {
long long g_cov_count = 0;
}
void nova_coverage_dump(long long count) {
  if (!__nova_cov_counters || count <= 0)
    return;
  FILE *f = std::fopen("__nova_cov_data.bin", "wb");
  if (!f)
    return;
  std::fwrite(__nova_cov_counters, sizeof(long long), (size_t)count, f);
  std::fclose(f);
}
namespace {
void cov_atexit() {
  if (__nova_cov_counters && g_cov_count > 0)
    nova_coverage_dump(g_cov_count);
}
}
void nova_coverage_init(long long count) {
  if (count <= 0)
    return;
  __nova_cov_counters =
      (long long *)std::calloc((size_t)count, sizeof(long long));
  g_cov_count = count;
  std::atexit(cov_atexit);
}

void nova_optional_deref_fail(const char *loc) {
  std::fprintf(stderr,
    "\nabort: member access on an absent optional%s%s\n"
    "  a `T | undefined` value was `undefined` when a field/method was read.\n"
    "  narrow it first: `if (x != undefined) { x.field }`  (specs \u00a73.4)\n",
    loc ? " at " : "", loc ? loc : "");
  std::_Exit(134);
}

void nova_panic(const char *msg) {
  if (msg) {
    const int n = *reinterpret_cast<const int *>(msg - 4);
    const int len = n < 0 ? 0 : n;
    std::fprintf(stderr, "\nnova: panic: %.*s\n", len, msg);
  } else {
    std::fprintf(stderr, "\nnova: panic\n");
  }
  std::_Exit(134);
}

void nova_panic_cstr(const char *msg) {
  std::fprintf(stderr, "\nnova: panic: %s\n", msg ? msg : "");
  std::_Exit(134);
}

// Copy raw bytes into a fresh Nova string (heap buffer with the 8-byte ARC header, len set).
static long long nova_stacktrace_str(const char *data, long long len) {
  if (len < 0) len = 0;
  long long buf = nova_bytes_alloc(len);
  if (len > 0) std::memcpy((char *)(uintptr_t)buf, data, (size_t)len);
  return buf;
}

// Format a list of return addresses as `0x...` lines (one per frame) into a Nova string. Used on the
// platforms without a symbolizing backtrace (Windows, musl); the addresses resolve with
// llvm-symbolizer / addr2line / the debugger.
static long long nova_stacktrace_from_addrs(void *const *addrs, int n) {
  char line[64 * 20];
  int off = 0;
  for (int i = 0; i < n && i < 64; i++) {
    int w = std::snprintf(line + off, sizeof(line) - (size_t)off, "0x%llx\n",
                          (unsigned long long)(uintptr_t)addrs[i]);
    if (w <= 0 || off + w >= (int)sizeof(line)) break;
    off += w;
  }
  return nova_stacktrace_str(line, off);
}

#if defined(NOVA_HAVE_UNWIND)
namespace {
struct NovaUnwindState {
  void *addrs[64];
  int n;
};
_Unwind_Reason_Code nova_unwind_cb(struct _Unwind_Context *ctx, void *arg) {
  NovaUnwindState *st = (NovaUnwindState *)arg;
  if (st->n < 64) st->addrs[st->n++] = (void *)(uintptr_t)_Unwind_GetIP(ctx);
  return _URC_NO_REASON;
}
} // namespace
#endif

// Capture the current call stack and return it as a Nova string, one frame per line. Works on every
// supported target; frame 0 (this function) is skipped so the trace starts at the caller:
//   - glibc / macOS: real symbol names via backtrace() + backtrace_symbols().
//   - Windows: hex return addresses via RtlCaptureStackBackTrace().
//   - musl / other libc: hex return addresses via the unwind ABI (_Unwind_Backtrace).
long long nova_get_stacktrace(void) {
#if defined(NOVA_HAVE_BACKTRACE)
  void *frames[64];
  int n = ::backtrace(frames, 64);
  if (n <= 1) return nova_bytes_alloc(0);
  char **syms = ::backtrace_symbols(frames, n);
  if (!syms) return nova_bytes_alloc(0);
  long long total = 0;
  for (int i = 1; i < n; i++) total += (long long)std::strlen(syms[i]) + 1; // + '\n'
  long long buf = nova_bytes_alloc(total);
  char *p = (char *)(uintptr_t)buf;
  long long off = 0;
  for (int i = 1; i < n; i++) {
    long long l = (long long)std::strlen(syms[i]);
    std::memcpy(p + off, syms[i], (size_t)l);
    off += l;
    p[off++] = '\n';
  }
  ::free(syms);
  return buf;
#elif defined(_WIN32)
  void *frames[64];
  USHORT n = ::RtlCaptureStackBackTrace(1 /* skip this fn */, 63, frames, nullptr);
  return nova_stacktrace_from_addrs(frames, (int)n);
#elif defined(NOVA_HAVE_UNWIND)
  NovaUnwindState st;
  st.n = 0;
  _Unwind_Backtrace(nova_unwind_cb, &st);
  // Skip frame 0 (this function): start the pointer one past it when there is more than one.
  if (st.n <= 1) return nova_bytes_alloc(0);
  return nova_stacktrace_from_addrs(&st.addrs[1], st.n - 1);
#else
  return nova_bytes_alloc(0);
#endif
}

// nova_getenv/nova_setenv retired in M6: std/env.nova reads and writes the environment through
// the getenv/setenv bindings in os/sys. Process arguments stay here because the runtime entry
// captures argv.

static int g_argc = 0;
static char **g_argv = nullptr;
void nova_set_args(int argc, char **argv) {
  g_argc = argc;
  g_argv = argv;
}
long long nova_arg_count(void) { return (long long)g_argc; }
char *nova_arg_at(long long i) {
  if (i < 0 || i >= (long long)g_argc || !g_argv)
    return const_cast<char *>(nova_from_cstr(""));
  return const_cast<char *>(nova_from_cstr(g_argv[(size_t)i]));
}

// Scan s[from, n) for the first HTML metacharacter (& < > " '); return its index, or n if none. A tight
// C loop over raw bytes replaces the per-byte Nova `s[i]` (a bounds-checked length-load + byte-load each
// iteration) that the escape-into-builder path used -- for the common clean string this is one scan that
// returns n, so the caller appends the whole run with a single memcpy. Escaping was ~7% of server CPU.
extern "C" int nova_html_scan(const char *s, int from, int n) {
  int i = from;
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c == '&' || c == '<' || c == '>' || c == '"' || c == '\'') return i;
    i++;
  }
  return n;
}

static char *nova_string_from(const char *c, int len) {
  const char *s = nova_from_bytes(c, (long long)len);
  return const_cast<char *>(s ? s : "");
}

// Allocate an (uninitialised) Nova string buffer of LOGICAL length `len`, NUL-terminated at [len], so
// the debugger's built-in char* view + C-FFI work without Python formatters. The stdlib's allocString
// routes through this instead of `bytes.alloc(len)` (which reserves no terminator). Over-allocate one
// byte via nova_bytes_alloc(len+1), then rewrite the ARC length field (i32 @ ptr-4) to the logical len.
extern "C" long long nova_str_alloc(long long len) {
  if (len < 0) len = 0;
  char *p = (char *)nova_bytes_alloc(len + 1);
  if (!p) return 0;
  p[len] = '\0';
  *reinterpret_cast<int *>(p - 4) = (int)len;
  return (long long)p;
}
// Hand-rolled base-10 integer formatter. The old snprintf("%lld") path parsed a format string, walked
// locale state, and called into vfprintf for every int rendered -- a big share of a templated page's CPU
// (ids, counts). This writes digits directly: build them backwards into a small buffer, then emit. ~5x
// faster than snprintf and allocation-identical (one nova_string_from at the end).
static int nova_i64_fmt(long long v, char *out) {
  char tmp[24];
  int ti = 0;
  bool neg = v < 0;
  unsigned long long u = neg ? (unsigned long long)(-(v + 1)) + 1ULL : (unsigned long long)v;
  do {
    tmp[ti++] = (char)('0' + (int)(u % 10ULL));
    u /= 10ULL;
  } while (u != 0);
  int n = 0;
  if (neg) out[n++] = '-';
  while (ti > 0) out[n++] = tmp[--ti];
  return n;
}
char *nova_i64_to_string(long long v) {
  char buf[24];
  int n = nova_i64_fmt(v, buf);
  return nova_string_from(buf, n);
}
char *nova_f64_to_string(double v) {
  // Fast path: an INTEGER-valued double (the overwhelmingly common case for rendered numbers -- prices,
  // counts, ids stored as doubles) formats EXACTLY as its integer, with none of the shortest-round-trip
  // search. The old loop called snprintf("%.*g") + strtod up to 17 times PER number; for a page of 200
  // integer-valued prices that was hundreds of vfprintf/dtoa calls per request (top of the server
  // profile). Only genuine fractions fall through to the correct-rounding search.
  if (v == 0.0) { return nova_string_from("0", 1); }
  if (v >= -9.007199254740992e15 && v <= 9.007199254740992e15) {
    long long iv = (long long)v;
    if ((double)iv == v) {
      char buf[24];
      int n = nova_i64_fmt(iv, buf);
      return nova_string_from(buf, n);
    }
  }
  char buf[32];
  int n = 0;
  for (int prec = 1; prec <= 17; ++prec) {
    n = std::snprintf(buf, sizeof(buf), "%.*g", prec, v);
    if (std::strtod(buf, nullptr) == v)
      break;
  }
  return nova_string_from(buf, n);
}
char *nova_bool_to_string(long long v) {

  return const_cast<char *>(nova_from_bytes(v ? "true" : "false", v ? 4 : 5));
}

char *nova_ieee_le_to_str(const char *data, int len) {
  if (!data) return nova_f64_to_string(0.0);
  unsigned char b[8] = {0};
  int n = (len == 4 || len == 8) ? len : 0;
  for (int i = 0; i < n; i++) b[i] = (unsigned char)data[i];
  if (len == 4) {
    float f;
    std::memcpy(&f, b, sizeof(f));
    return nova_f64_to_string((double)f);
  }
  double d;
  std::memcpy(&d, b, sizeof(d));
  return nova_f64_to_string(len == 8 ? d : 0.0);
}

long long nova_f64_bits(double d) {
  long long bits;
  std::memcpy(&bits, &d, sizeof(bits));
  return bits;
}

// Read a big-endian IEEE-754 float of `len` bytes (4 = float4, 8 = float8) from `ptr` and return it as a
// double. Used by the Postgres driver's BINARY result decode: the wire delivers float4/8 as fixed
// big-endian bytes, so this reassembles them (network order) and bit-casts, with no ASCII parse.
double nova_pg_be_f64(long long ptr, int len) {
  if (!ptr) return 0.0;
  const unsigned char *p = reinterpret_cast<const unsigned char *>(ptr);
  if (len == 8) {
    unsigned char b[8];
    for (int i = 0; i < 8; i++) b[i] = p[7 - i];   // big-endian -> host little-endian
    double d;
    std::memcpy(&d, b, sizeof(d));
    return d;
  }
  if (len == 4) {
    unsigned char b[4];
    for (int i = 0; i < 4; i++) b[i] = p[3 - i];
    float f;
    std::memcpy(&f, b, sizeof(f));
    return (double)f;
  }
  return 0.0;
}

// Read a big-endian SIGNED integer of `len` bytes (1/2/4/8) from `ptr`, sign-extended to 64 bits. Used by
// the Postgres BINARY result decode for int2/int4/int8. Done in the runtime (not Nova) so the byte
// assembly cannot trip Nova's checked-32-bit-int overflow trap.
long long nova_pg_be_i64(long long ptr, int len) {
  if (!ptr || len <= 0 || len > 8) return 0;
  const unsigned char *p = reinterpret_cast<const unsigned char *>(ptr);
  unsigned long long acc = 0;
  for (int i = 0; i < len; i++) acc = (acc << 8) | (unsigned long long)p[i];
  if (len < 8) {
    unsigned long long signbit = 1ULL << (len * 8 - 1);
    if (acc & signbit) acc |= ~((1ULL << (len * 8)) - 1);   // sign-extend
  }
  return (long long)acc;
}

// Return the index of the first HTML metacharacter (& < > " ' = 38 60 62 34 39) at or after `start` in
// the `len`-byte buffer at `base`, or `len` if none. SWAR: tests 8 bytes per iteration branch-free via the
// exact has-zero-byte trick `(x-ones) & ~x & high` (needles are all < 0x80, so no false positives on
// UTF-8 data bytes). Portable (no arch intrinsics). Called ONCE per clean interpolated value (a bulk scan
// of the whole value), not per byte, so the per-call cost is amortised over the string -- the failure mode
// of the earlier per-interpolation FFI attempt is avoided. Unsigned throughout: no Nova int-overflow trap.
int nova_html_find_meta(long long base, int start, int len) {
  if (!base || len <= 0) return len;
  if (start < 0) start = 0;
  const unsigned char *p = reinterpret_cast<const unsigned char *>(base);
  const unsigned long long ones = 0x0101010101010101ULL;
  const unsigned long long high = 0x8080808080808080ULL;
  const unsigned long long n_amp = ones * 38, n_lt = ones * 60, n_gt = ones * 62,
                           n_qt = ones * 34, n_sq = ones * 39;
  int i = start;
  for (; i + 8 <= len; i += 8) {
    unsigned long long w;
    std::memcpy(&w, p + i, 8);
    unsigned long long m =
        (((w ^ n_amp) - ones) & ~(w ^ n_amp) & high) | (((w ^ n_lt) - ones) & ~(w ^ n_lt) & high) |
        (((w ^ n_gt) - ones) & ~(w ^ n_gt) & high) | (((w ^ n_qt) - ones) & ~(w ^ n_qt) & high) |
        (((w ^ n_sq) - ones) & ~(w ^ n_sq) & high);
    if (m)
      return i + (__builtin_ctzll(m) >> 3);   // lowest set 0x80 lane -> byte index
  }
  for (; i < len; i++) {
    unsigned char c = p[i];
    if (c == 38 || c == 60 || c == 62 || c == 34 || c == 39)
      return i;
  }
  return len;
}

long long nova_spin_create(void) { return (long long)new std::atomic_flag{}; }
void nova_spin_lock(long long h) {
  if (!h) return;
  auto *f = reinterpret_cast<std::atomic_flag *>(h);
  while (f->test_and_set(std::memory_order_acquire)) {
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    asm volatile("yield");
#endif
  }
}
void nova_spin_unlock(long long h) {
  if (h) reinterpret_cast<std::atomic_flag *>(h)->clear(std::memory_order_release);
}

long long nova_mutex_create(void) { return (long long)new std::mutex(); }
void nova_mutex_lock(long long h) {
  if (h)
    reinterpret_cast<std::mutex *>(h)->lock();
}
void nova_mutex_unlock(long long h) {
  if (h)
    reinterpret_cast<std::mutex *>(h)->unlock();
}
void nova_mutex_destroy(long long h) {
  delete reinterpret_cast<std::mutex *>(h);
}
long long nova_condvar_create(void) {
  return (long long)new std::condition_variable_any();
}
void nova_condvar_wait(long long cv, long long m) {
  if (cv && m) {
    std::mutex *mx = reinterpret_cast<std::mutex *>(m);
    std::unique_lock<std::mutex> lk(*mx, std::adopt_lock);
    reinterpret_cast<std::condition_variable_any *>(cv)->wait(lk);
    lk.release();
  }
}
void nova_condvar_signal(long long cv) {
  if (cv)
    reinterpret_cast<std::condition_variable_any *>(cv)->notify_one();
}
void nova_condvar_broadcast(long long cv) {
  if (cv)
    reinterpret_cast<std::condition_variable_any *>(cv)->notify_all();
}
void nova_condvar_destroy(long long cv) {
  delete reinterpret_cast<std::condition_variable_any *>(cv);
}
long long nova_rwlock_create(void) {
  return (long long)new std::shared_mutex();
}
void nova_rwlock_acquire_read(long long h) {
  if (h)
    reinterpret_cast<std::shared_mutex *>(h)->lock_shared();
}
void nova_rwlock_release_read(long long h) {
  if (h)
    reinterpret_cast<std::shared_mutex *>(h)->unlock_shared();
}
void nova_rwlock_acquire_write(long long h) {
  if (h)
    reinterpret_cast<std::shared_mutex *>(h)->lock();
}
void nova_rwlock_release_write(long long h) {
  if (h)
    reinterpret_cast<std::shared_mutex *>(h)->unlock();
}
void nova_rwlock_destroy(long long h) {
  delete reinterpret_cast<std::shared_mutex *>(h);
}

int32_t nova_atomic_add_i32(int32_t *p, int32_t d) {
  return __atomic_fetch_add(p, d, __ATOMIC_SEQ_CST);
}
int32_t nova_atomic_sub_i32(int32_t *p, int32_t d) {
  return __atomic_fetch_sub(p, d, __ATOMIC_SEQ_CST);
}

int32_t nova_atomic_cas_i32(int32_t *p, int32_t e, int32_t des) {
  return __atomic_compare_exchange_n(p, &e, des, false, __ATOMIC_SEQ_CST,
                                     __ATOMIC_SEQ_CST)
             ? 1
             : 0;
}
int32_t nova_atomic_load_i32(int32_t *p) {
  return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}
void nova_atomic_store_i32(int32_t *p, int32_t v) {
  __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}
int64_t nova_atomic_add_i64(int64_t *p, int64_t d) {
  return __atomic_fetch_add(p, d, __ATOMIC_SEQ_CST);
}
int64_t nova_atomic_sub_i64(int64_t *p, int64_t d) {
  return __atomic_fetch_sub(p, d, __ATOMIC_SEQ_CST);
}

int32_t nova_atomic_cas_i64(int64_t *p, int64_t e, int64_t des) {
  int64_t exp = e;
  return __atomic_compare_exchange_n(p, &exp, des, false, __ATOMIC_SEQ_CST,
                                     __ATOMIC_SEQ_CST)
             ? 1
             : 0;
}
int64_t nova_atomic_load_i64(int64_t *p) {
  return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}
void nova_atomic_store_i64(int64_t *p, int64_t v) {
  __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}
int32_t nova_atomic_cas_bool(uint8_t *p, int32_t e, int32_t des) {
  uint8_t exp = (uint8_t)e;
  return __atomic_compare_exchange_n(p, &exp, (uint8_t)des, false,
                                     __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
             ? 1
             : 0;
}
int32_t nova_atomic_load_bool(uint8_t *p) {
  return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}
void nova_atomic_store_bool(uint8_t *p, int32_t v) {
  __atomic_store_n(p, (uint8_t)v, __ATOMIC_SEQ_CST);
}

// nova_close closes a file descriptor. It stays a runtime primitive: os/sys binds libc close
// (the reactor path uses sys.close), but the legacy tcp socket stack cannot import os/sys, because
// os/sys exports a `socket` function that collides by name with the `socket` module those files
// use (a name-based-resolution limit). Migrating close there needs an os.socket split (M6 note).
int nova_close(int fd) {
#ifdef _WIN32
  return _close(fd);
#else
  return ::close(fd);
#endif
}

#ifdef _WIN32
// ---------------------------------------------------------------------------------------------------
// POSIX syscall shims for Windows. os/sys.nova declares these as `extern("c")` against the libc names
// (mmap/munmap/fsync/socketpair); the zig-mingw C library does not provide them, so the Windows target
// fails to link (undefined symbol). We define the libc names here mapped onto the Win32 equivalents,
// matching the exact ABI os/sys emits. Anonymous private RW mapping and file flush are all os/sys asks
// of mmap/fsync, so prot/flags/fd/offset are ignored for mmap. Mirrors the nova_set_nonblock ->
// ioctlsocket and entropy -> BCryptGenRandom pattern already used above / in crypto.cpp.

// mapAnon() passes MAP_PRIVATE|MAP_ANON RW; VirtualAlloc gives zero-filled committed pages. Returns
// MAP_FAILED ((void*)-1) on error, which os/sys.mapAnon translates to 0.
void *mmap(void *addr, long long length, int prot, int flags, int fd, long long offset) {
  (void)addr; (void)prot; (void)flags; (void)fd; (void)offset;
  if (length <= 0) return (void *)-1;
  void *p = ::VirtualAlloc(nullptr, (SIZE_T)length, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  return p ? p : (void *)-1;
}

// VirtualFree with MEM_RELEASE requires size 0 and the original base pointer. Returns 0 on success.
int munmap(void *addr, long long length) {
  (void)length;
  return ::VirtualFree(addr, 0, MEM_RELEASE) ? 0 : -1;
}

// fsync(fd): flush a CRT file descriptor's buffers to disk via its underlying HANDLE.
int fsync(int fd) {
  HANDLE h = (HANDLE)_get_osfhandle(fd);
  if (h == INVALID_HANDLE_VALUE) return -1;
  return ::FlushFileBuffers(h) ? 0 : -1;
}

// Winsock needs one-time WSAStartup before any socket call. socketpair (reactor self-wake) is the only
// os/sys entry that can run before the rest of the socket stack initialises it, so guard it here.
static void ensureWinsock() {
  static std::once_flag once;
  std::call_once(once, [] {
    WSADATA wsa;
    ::WSAStartup(MAKEWORD(2, 2), &wsa);
  });
}

// socketpair(): Windows has no AF_UNIX socketpair, so emulate a connected pair over a 127.0.0.1
// loopback listener. Used for the reactor's cross-thread wake pipe. Writes the two fds into sv[0]/sv[1]
// (SOCKET is 64-bit on Win64; freshly-created loopback sockets have small handle values that fit `int`,
// matching os/sys's int-fd model). Returns 0 on success, -1 on error.
int socketpair(int domain, int type, int protocol, int *sv) {
  (void)domain; (void)protocol;
  ensureWinsock();
  SOCKET listener = ::socket(AF_INET, type, 0);
  if (listener == INVALID_SOCKET) return -1;
  struct sockaddr_in addr;
  std::memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  int addrlen = (int)sizeof(addr);
  if (::bind(listener, (struct sockaddr *)&addr, addrlen) == SOCKET_ERROR ||
      ::getsockname(listener, (struct sockaddr *)&addr, &addrlen) == SOCKET_ERROR ||
      ::listen(listener, 1) == SOCKET_ERROR) {
    ::closesocket(listener);
    return -1;
  }
  SOCKET client = ::socket(AF_INET, type, 0);
  if (client == INVALID_SOCKET) { ::closesocket(listener); return -1; }
  if (::connect(client, (struct sockaddr *)&addr, addrlen) == SOCKET_ERROR) {
    ::closesocket(listener);
    ::closesocket(client);
    return -1;
  }
  SOCKET server = ::accept(listener, nullptr, nullptr);
  ::closesocket(listener);
  if (server == INVALID_SOCKET) { ::closesocket(client); return -1; }
  sv[0] = (int)client;
  sv[1] = (int)server;
  return 0;
}
#endif // _WIN32

}
