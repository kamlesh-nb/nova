// core.cpp — Nova C++20 runtime: entry, logging, time, test harness, coverage,
// exceptions, env, sync/atomics, crypto (stub), and a SYNCHRONOUS-first
// concurrency shim (v0). Real async (Boost.Asio io_context + Boost.Context
// stackful fibers) replaces the concurrency section in a later step; the ABI
// stays identical so codegen is unaffected.
#include "nova_abi.h"
#include "runtime_str.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <queue>
#include <shared_mutex>
#include <thread>
#ifdef _WIN32
#include <io.h>      // _close
#include <stdlib.h>  // _putenv_s
#else
#include <unistd.h>  // close
#endif

extern "C" {

// (Program entry `main` lives in concurrency.cpp, which drives __nova_main on
//  the fiber scheduler.)

// ===== Logging =============================================================
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

// ===== T3 FFI string marshalling ===========================================
// nova_to_cstr / nova_from_cstr / nova_free_cstr are `static inline` in the shared
// header, so codegen cannot link to them. These exported wrappers give the FFI call
// path linkable symbols for Nova-string <-> C-`char*` conversion at the boundary.
//   IN  : a Nova string arg becomes a fresh NUL-terminated C string (freed after the
//         call by nova_ffi_free_cstr — the Nova string itself is untouched).
//   OUT : a C `char*` return is COPIED into a fresh Nova string (the caller does NOT
//         own the C pointer; if the callee malloc'd it, that is the C API's contract).
char *nova_ffi_to_cstr(const char *nova_str) { return nova_to_cstr(nova_str); }
void nova_ffi_free_cstr(const char *nova_str, char *c) { nova_free_cstr(nova_str, c); }
const char *nova_ffi_from_cstr(const char *c) {
  if (!c)
    return nova_from_cstr(""); // a null C return maps to the empty Nova string
  return nova_from_cstr(c);
}

// Invoke a Nova `(string) -> string` closure from C. A Nova closure value is a heap
// box {fn_ptr, env}; the Nova calling convention is fn_ptr(env, arg...). This is the
// primitive every FFI callback trampoline uses to cross back into Nova (e.g. the
// webview_bind bridge). `box`, `arg`, and the return are all Nova string handles.
typedef long long (*nova_str_closure_fn)(long long env, long long arg);
long long nova_invoke_str_closure(long long box, long long arg) {
  if (!box)
    return (long long)nova_from_cstr("");
  long long fn_ptr = *reinterpret_cast<long long *>(box);
  long long env = *reinterpret_cast<long long *>(box + sizeof(long long));
  return reinterpret_cast<nova_str_closure_fn>(fn_ptr)(env, arg);
}
// Invoke a Nova `() -> void` closure from C (webview_dispatch UI-thread callbacks).
typedef long long (*nova_void_closure_fn)(long long env);
void nova_invoke_void_closure(long long box) {
  if (!box)
    return;
  long long fn_ptr = *reinterpret_cast<long long *>(box);
  long long env = *reinterpret_cast<long long *>(box + sizeof(long long));
  reinterpret_cast<nova_void_closure_fn>(fn_ptr)(env);
}

// ===== exit / time =========================================================
// Use _Exit: with detached Boost.Fibers still alive, running static destructors
// (via std::exit) can deadlock in the fiber scheduler teardown. _Exit terminates
// immediately without destructors/atexit.
void nova_exit(int code) { std::_Exit(code); }
int64_t nova_time_now(void) {
  using namespace std::chrono;
  return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}
int64_t nova_time_now_ns(void) {
  using namespace std::chrono;
  return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
}

// ===== Test harness ========================================================
namespace {
thread_local int t_failed = 0;
thread_local char t_msg[1024] = {0};
} // namespace
void nova_test_reset(void) {
  t_failed = 0;
  t_msg[0] = '\0';
}
// The @test currently running. Set by nova_test_begin (emitted per test by the harness in
// main.zig's generateTestHarness) purely so a failure can NAME the test that failed.
//
// Why this exists: nova_test_fail ends in std::_Exit(1), so the harness's `FAIL <name>` branch —
// which prints the name and the message — is DEAD CODE and has never once run. The whole
// "Results: N passed, M failed" path is unreachable too. The observable behaviour was that a
// failing assertion printed `Assertion failed: Expected true, got false` and nothing else: no test
// name, no summary. With the merged stdlib every import also pulls in that module's own @tests, so
// an unrelated failing test looked exactly like YOUR test failing — which is not hypothetical, it
// misdirected this session's investigation of `Atomic<bool>` three times before the harness itself
// turned out to be the liar. (2026-07-17)
//
// _Exit stays: an assertion failure means the test's invariants are already broken, and Nova has no
// way to unwind out of the test function (no exceptions — and `throw` is being removed). Aborting
// is correct; aborting ANONYMOUSLY was the bug.
static char t_current[256] = "";
void nova_test_begin(const char *name) {
  if (!name) {
    t_current[0] = '\0';
    return;
  }
  int i = 0;
  // `name` is a Nova string (length header at -4), but it is also NUL-terminated by
  // nova_from_bytes, so a plain copy is safe and keeps this independent of the layout.
  while (name[i] && i < (int)sizeof(t_current) - 1) {
    t_current[i] = name[i];
    i++;
  }
  t_current[i] = '\0';
}

void nova_test_fail(const char *msg) {
  t_failed = 1;
  if (msg) {
    // ⚠️ Copy by the LENGTH HEADER, never by scanning for a NUL.
    //
    // A Nova string is length-prefixed ([ptr-4]) and `bytes.alloc(len)` returns exactly `len`
    // bytes — there is no terminator to find. The old `while (msg[i] && ...)` therefore read
    // past the payload into the adjacent heap object, and ASAN caught it the first time a test
    // failed with a CONCATENATED message (a literal has a NUL by luck; a built string does not):
    //     heap-buffer-overflow ... in nova_test_fail core.cpp:131
    // Silent for as long as the neighbouring bytes happened to contain a zero. (2026-07-17)
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

// ===== Coverage ============================================================
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
} // namespace
void nova_coverage_init(long long count) {
  if (count <= 0)
    return;
  __nova_cov_counters =
      (long long *)std::calloc((size_t)count, sizeof(long long));
  g_cov_count = count;
  std::atexit(cov_atexit);
}

// ===== Exceptions — REMOVED (specs §5.5, plan P2-12) =======================
// `nova_throw`, `nova_push_exception_frame`, `nova_pop_exception_frame` and the
// ExceptionFrame stack are gone, with the `throw`/`try`/`catch` language surface.
//
// The model was setjmp/longjmp, and it failed on three counts, each measured:
//   1. The thrown VALUE could not survive: nova_throw took a `long long` and codegen's
//      catch bound `zext(setjmp_res)` — an i32 — so `throw "DI Error: " + key` was caught
//      as the integer 8472. The stdlib's own only consumer logged
//      `[RECOVERY] Caught exception: 8472`, and web/mediator.nova had already stopped
//      reading `err` and passed a hardcoded string to its exception handlers instead.
//   2. No unwinding: ARC released only the catching frame's try-block locals, so every
//      frame between the throw and the catch leaked everything it owned.
//   3. longjmp out of a C++20 coroutine is UB — and `async fn` compiles to exactly that.
//      The one stdlib user was a pipeline behavior inside an async HTTP handler.
//
// Errors are VALUES now (`T | Error`, plan P2-13): checked by the type system, no
// unwinding, nothing for ARC to miss, and the message actually arrives.
//
// `nova_get_stacktrace` stays for now — it is a separate stub (it returns an empty
// buffer; Nova has never had stack traces) and is not part of the exception machinery.
// specs §3.4 / P2-14: a member access through an optional that turned out to be `undefined`.
// The see-through (950495c) lets `xs.get(i).field` resolve its member type, but `undefined` is
// the handle 0 — so without a guard `.field` reads through address 0 and SEGVs at 0xff..fc with
// no explanation. Codegen inserts `if (handle == 0) nova_optional_deref_fail(loc)` before such a
// deref, turning UB into an honest, LOCATED abort. `loc` is a C string literal (file:line).
void nova_optional_deref_fail(const char *loc) {
  std::fprintf(stderr,
    "\nabort: member access on an absent optional%s%s\n"
    "  a `T | undefined` value was `undefined` when a field/method was read.\n"
    "  narrow it first: `if (x != undefined) { x.field }`  (specs \u00a73.4)\n",
    loc ? " at " : "", loc ? loc : "");
  std::_Exit(134);
}

// A clean, Nova-callable panic: an unrecoverable programmer error (index out of bounds,
// a broken invariant). `msg` is a NOVA string (length-prefixed at [ptr-4]) — read it by the
// header, never by scanning for a NUL (same trap nova_test_fail documents). Prints a located
// abort and _Exit(134), so it terminates loudly instead of returning garbage / segfaulting.
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

// Same loud abort as nova_panic, but for RUNTIME-INTERNAL call sites that hold a plain C
// string literal (not a Nova heap string) — e.g. decimal divide-by-zero. Reads the message
// as a NUL-terminated C string, never by a [ptr-4] length header, so it must NOT be called
// with a Nova string. Prints the same "nova: panic:" prefix and _Exit(134).
void nova_panic_cstr(const char *msg) {
  std::fprintf(stderr, "\nnova: panic: %s\n", msg ? msg : "");
  std::_Exit(134);
}

long long nova_get_stacktrace(void) { return nova_bytes_alloc(0); }

// ===== Env =================================================================
// Returns "" for an unset variable, never null: the Nova signature is `get(name): string`, so a
// null here becomes a NULL pointer typed as a string and segfaults on first use (concat, compare,
// length). Callers distinguish unset by testing for the empty string.
char *nova_getenv(const char *name) {
  if (!name)
    return const_cast<char *>(nova_from_cstr(""));
  char *nm = nova_to_cstr(name);
  const char *v = nm ? std::getenv(nm) : nullptr;
  nova_free_cstr(name, nm);
  return const_cast<char *>(nova_from_cstr(v ? v : ""));
}
void nova_setenv(const char *name, const char *value) {
  if (!name || !value)
    return;
  char *nm = nova_to_cstr(name);
  char *vl = nova_to_cstr(value);
  if (nm && vl)
#ifdef _WIN32
    _putenv_s(nm, vl);
#else
    ::setenv(nm, vl, 1);
#endif
  nova_free_cstr(name, nm);
  nova_free_cstr(value, vl);
}

// ===== Command-line arguments ==============================================
// `main(argc, argv)` (concurrency.cpp) stashes them here before calling __nova_main;
// the stdlib builds a Nova `List<string>` from these two accessors (env.args()).
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

// ===== Number -> string (interpolation / concat) ===========================
// F3 §10 #2: `${x}` for a float used to fall through to StringBuilder_append,
// which treats its argument as a Nova string pointer — so a raw double's bits
// were dereferenced as a char*, segfaulting. These give codegen a real, safe
// conversion.
//
// Layout matters: a canonical Nova string writes its chars AT the payload and
// reuses the allocation header's size field as the length ([ptr-4]=len,
// [ptr-8]=refcount) — the canonical, ARC-correct, binary-safe layout, now provided
// by nova_from_bytes (runtime_str.h). Digits are pure ASCII (no embedded NUL), but
// using the one constructor keeps every string path on the same layout.
static char *nova_string_from(const char *c, int len) {
  const char *s = nova_from_bytes(c, (long long)len);
  return const_cast<char *>(s ? s : "");
}
char *nova_i64_to_string(long long v) {
  char buf[24]; // -9223372036854775808 = 20 chars + sign + NUL
  int n = std::snprintf(buf, sizeof(buf), "%lld", v);
  return nova_string_from(buf, n);
}
char *nova_f64_to_string(double v) {
  // Shortest round-tripping decimal: the smallest precision whose text parses
  // back to the exact same double. Avoids both "%g"'s 6-digit precision loss
  // and "%.17g"'s noisy 0.30000000000000004 tails. inf/nan fall out as "inf"/
  // "nan" at prec 1 (strtod round-trips them).
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
  // A8: replaces the compiler-injected `__bool_to_string` Nova prelude.
  return const_cast<char *>(nova_from_bytes(v ? "true" : "false", v ? 4 : 5));
}

// D6: decode little-endian IEEE-754 bytes (as sent by the MySQL binary protocol for FLOAT/DOUBLE
// columns) into the value's shortest round-tripping decimal TEXT — the driver then parses that
// back with the normal float parser. Returning text (not a raw double) keeps this a plain
// string-returning extern, and reuses nova_f64_to_string's exact shortest-decimal logic. `data`
// points at `len` raw bytes (len==4 -> float, len==8 -> double); any other length -> "0".
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

// Crypto (nova_sha256/md5/sha512/hmac/random) lives in crypto.cpp — real wolfCrypt.

// ===== Sync: mutex / condvar / rwlock (handles) ============================
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

// ===== Atomics (__atomic builtins over the caller's memory — portable) ======
int32_t nova_atomic_add_i32(int32_t *p, int32_t d) {
  return __atomic_fetch_add(p, d, __ATOMIC_SEQ_CST);
}
int32_t nova_atomic_sub_i32(int32_t *p, int32_t d) {
  return __atomic_fetch_sub(p, d, __ATOMIC_SEQ_CST);
}
// Returns 1 on success, 0 on failure — like the i64 and bool variants beside it.
//
// ⚠️ It used to `return e` (the expected value, which __atomic_compare_exchange_n overwrites with
// the ACTUAL value on failure) and discard the success flag entirely. Codegen truncates this
// result to i1 (`llvm_codegen.zig` — "cas_bool"), so the caller got the LOW BIT OF THE EXPECTED
// VALUE: `compareAndSwap(22, 30)` succeeded and reported false (22 & 1 == 0), while the *failing*
// CAS on 30 also reported false — so `assert.isFalse(cas_fail)` passed BY ACCIDENT and only the
// success case looked broken. It reported correctly if and only if the expected value was odd.
// Found via atomic.nova's own test_atomic_i32, which no conformance case ran. (2026-07-17)
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
// `des` is int64_t, not int32_t: codegen declares this as (ptr, i64, i64) -> i32, so the old
// int32_t parameter silently truncated any desired value above 2^31. (Fixed 2026-07-17.)
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

int nova_close(int fd) {
#ifdef _WIN32
  return _close(fd);
#else
  return ::close(fd);
#endif
}

// Concurrency (spawn/sleep/channels) and the program entry point live in
// concurrency.cpp (Boost.Context fibers + Boost.Asio).

} // extern "C"
