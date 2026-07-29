
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
#include <io.h>
#include <stdlib.h>
#else
#include <unistd.h>
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

long long nova_ffi_errno(void) { return (long long)errno; }
void nova_ffi_set_errno(long long v) { errno = (int)v; }
// fcntl is variadic; a non-variadic FFI declaration mispasses the third arg on some ABIs
// (arm64 passes varargs on the stack). This shim lets C handle the varargs correctly.
long long nova_set_nonblock(long long fd) {
  int f = fcntl((int)fd, F_GETFL, 0);
  if (f < 0) return -1;
  return (long long)fcntl((int)fd, F_SETFL, f | O_NONBLOCK);
}
// open(2) is variadic (int open(const char*, int, ...)); a non-variadic FFI declaration
// mispasses the mode argument on arm64 (varargs go on the stack, not in registers), exactly
// as with fcntl above. This tiny shim lets C forward the mode correctly. It is the only C
// left under io/file after M5; everything else in file and directory I/O is Nova over os/sys.
long long nova_open(const char *path, long long flags, long long mode) {
  return (long long)::open(path, (int)flags, (unsigned int)mode);
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
  std::fprintf(stderr, "\n  (the suite aborts at the first failing assertion — a test cannot be\n"
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

long long nova_get_stacktrace(void) { return nova_bytes_alloc(0); }

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

static char *nova_string_from(const char *c, int len) {
  const char *s = nova_from_bytes(c, (long long)len);
  return const_cast<char *>(s ? s : "");
}
char *nova_i64_to_string(long long v) {
  char buf[24];
  int n = std::snprintf(buf, sizeof(buf), "%lld", v);
  return nova_string_from(buf, n);
}
char *nova_f64_to_string(double v) {

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

}
