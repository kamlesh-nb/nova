
#ifndef KYTE_ABI_H
#define KYTE_ABI_H

#include <stdint.h>
#include <stddef.h>

// L5 stability: the extern-C runtime ABI contract version. The STABLE seam this pins is the
// heap-object layout and the reference-counting entry points (see docs/abi/runtime-abi.md):
//   * every heap object carries an 8-byte header; refcount is a u32 at [ptr-8], byte-length a
//     u32 at [ptr-4]; the object payload starts at ptr.
//   * kyte_retain(ptr) / kyte_release(ptr, dtor) are the ref-count entry points.
//   * kyte_bytes_alloc / kyte_bytes_free are the allocation entry points.
// The compiler emits code against exactly this layout (KYTE_OBJ_HEADER_SIZE, mirrored in
// src/codegen/arc.zig and surfaced as build_options.kyte_abi_version). Bump this ONLY on a
// breaking change to that stable seam -- NOT for adding async/reactor/syscall symbols below,
// which are INTERNAL (compiler<->its own runtime) and not a third-party contract.
#define KYTE_ABI_VERSION 1

#define KYTE_OBJ_HEADER_SIZE 8

#ifdef __cplusplus
extern "C" {
#endif

// Runtime trace facility (M0 of the C++ runtime retirement plan). Writes to the file named by the
// KYTE_TRACE environment variable, with an explicit flush per line, so runtime diagnostics surface
// reliably regardless of how the binary is built, cached, or run (the scheduler debug was blocked
// by stderr not surfacing). Disabled and near-zero-cost when KYTE_TRACE is unset. Thread-safe.
// Use from C++ via the KYTE_TRACE macro; callable from Kyte via kyte_trace_msg / kyte_trace_kv.
int  kyte_trace_enabled(void);
void kyte_trace_line(const char *s);           // one pre-formatted line (a newline is appended)
void kyte_trace_msg(long long kyte_str);        // a Kyte string (callable from Kyte)
void kyte_trace_kv(long long kyte_str, long long value); // "tag=value" (callable from Kyte)
void kyte_tracef(const char *fmt, ...);          // printf-style, C++-internal; a newline is appended

// C++-internal trace macro. Zero-argument-overhead when KYTE_TRACE is unset (a load-once flag
// short-circuits before the format is evaluated). Example: KYTE_TRACE("sched pump h=%lld", h);
#ifdef __cplusplus
} // extern "C"
#endif
#define KYTE_TRACE(...) do { if (kyte_trace_enabled()) kyte_tracef(__VA_ARGS__); } while (0)
#ifdef __cplusplus
extern "C" {
#endif

long long kyte_bytes_alloc(long long size);
long long kyte_bytes_alloc_persistent(long long size);
void      kyte_bytes_free(long long ptr_val);
void      kyte_retain(long long ptr_val);
void      kyte_release(long long ptr_val, void (*destructor)(long long));

long long kyte_any_box(long long payload, long long dtor);
long long kyte_any_unbox(long long box);
void      kyte_any_box_dtor(long long box);

long long kyte_valopt_box(long long value);
long long kyte_valopt_unbox(long long box);

char *kyte_i64_to_string(long long v);
char *kyte_f64_to_string(double v);
char *kyte_bool_to_string(long long v);

long long   kyte_decimal_from_string(const char *s);
const char *kyte_decimal_to_string(long long ptr);

void        kyte_set_args(int argc, char **argv);
long long   kyte_arg_count(void);
char       *kyte_arg_at(long long i);

long long   kyte_decimal_add(long long a, long long b);
long long   kyte_decimal_sub(long long a, long long b);
long long   kyte_decimal_mul(long long a, long long b);
long long   kyte_decimal_div(long long a, long long b);
long long   kyte_decimal_mod(long long a, long long b);
long long   kyte_decimal_cmp(long long a, long long b);

extern long long __kyte_main(void);
void kyte_concurrency_spawn(long long closure);
void kyte_concurrency_sleep(long long ms);

long long kyte_coro_alloc(long long size);
void      kyte_coro_free(long long frame);

void      kyte_sched_schedule(long long handle);
void      kyte_sched_schedule_detached(long long handle);
long long kyte_sched_next(void);

void      kyte_run(void);
long long kyte_thread_id(void);
long long kyte_worker_count(void);
void kyte_pin_next_coro(long long rid);
void kyte_hold_all_reactors(void);

void      kyte_run_root(long long root);

void      kyte_coro_release(long long handle);
long long kyte_io_context(void);

void      kyte_register_waiter(long long child, long long parent);

long long kyte_await_future(long long future, long long waiter);

long long kyte_chan_new(long long capacity);
void      kyte_chan_send(long long ch, long long val);
long long kyte_chan_recv(long long ch, long long self, long long *out);
void      kyte_chan_free(long long ch);

void      kyte_io_recv_async(long long fd, long long buf, long long max_len, long long self);
void      kyte_io_accept_async(long long server_fd, long long self);
long long kyte_io_take_result(long long self);

long long kyte_aserver_listen(long long port);
long long kyte_aserver_listen_addr(long long host, long long port);
void      kyte_aconnect(long long host, long long port, long long self);
void      kyte_aaccept(long long server, long long self);
void      kyte_coro_hold_arg(long long coro, long long ptr, void (*dtor)(long long));
long long kyte_when_any(long long buf, long long n, long long self);
long long kyte_when_any_deadline(long long buf, long long n, long long ms, long long self);
void      kyte_arecv(long long sock, long long buf, long long max_len, long long self);
void      kyte_arecv_deadline(long long sock, long long buf, long long max_len, long long ms, long long self);
void      kyte_asend(long long sock, long long data, long long self);
void      kyte_aclose(long long sock);

void      kyte_await_timer(long long handle, long long ms);

long long kyte_channel_create(int capacity);
void      kyte_channel_send(long long channel_handle, long long val);
long long kyte_channel_recv(long long channel_handle);
void      kyte_channel_destroy(long long channel_handle);

long long kyte_spin_create(void);
void      kyte_spin_lock(long long h);
void      kyte_spin_unlock(long long h);
long long kyte_mutex_create(void);
void      kyte_mutex_lock(long long h);
void      kyte_mutex_unlock(long long h);
void      kyte_mutex_destroy(long long h);
long long kyte_condvar_create(void);
void      kyte_condvar_wait(long long cv, long long m);
void      kyte_condvar_signal(long long cv);
void      kyte_condvar_broadcast(long long cv);
void      kyte_condvar_destroy(long long cv);
long long kyte_rwlock_create(void);
void      kyte_rwlock_acquire_read(long long h);
void      kyte_rwlock_release_read(long long h);
void      kyte_rwlock_acquire_write(long long h);
void      kyte_rwlock_release_write(long long h);
void      kyte_rwlock_destroy(long long h);
int32_t kyte_atomic_add_i32(int32_t *p, int32_t d);
int32_t kyte_atomic_sub_i32(int32_t *p, int32_t d);
int32_t kyte_atomic_cas_i32(int32_t *p, int32_t expected, int32_t desired);
int32_t kyte_atomic_load_i32(int32_t *p);
void    kyte_atomic_store_i32(int32_t *p, int32_t v);
int64_t kyte_atomic_add_i64(int64_t *p, int64_t d);
int64_t kyte_atomic_sub_i64(int64_t *p, int64_t d);
int32_t kyte_atomic_cas_i64(int64_t *p, int64_t expected, int64_t desired);
int64_t kyte_atomic_load_i64(int64_t *p);
void    kyte_atomic_store_i64(int64_t *p, int64_t v);
int32_t kyte_atomic_cas_bool(uint8_t *p, int32_t expected, int32_t desired);
int32_t kyte_atomic_load_bool(uint8_t *p);
void    kyte_atomic_store_bool(uint8_t *p, int32_t v);

long long kyte_get_stacktrace(void);
void      kyte_optional_deref_fail(const char *loc);

int64_t   kyte_time_now(void);
int64_t   kyte_time_now_ns(void);
void      kyte_log_string(const char *s);
void      kyte_log_info(const char *s);
void      kyte_log_debug(const char *s);
void      kyte_log_err(const char *s);
void      kyte_exit(int code);

void        kyte_test_reset(void);
void        kyte_test_begin(const char *name);
void        kyte_test_fail(const char *msg);
int         kyte_test_did_fail(void);
const char* kyte_test_fail_message(void);
extern long long *__kyte_cov_counters;
void        kyte_coverage_init(long long count);
void        kyte_coverage_dump(long long count);

// File and directory I/O moved to Kyte over os/sys in M5 (see src/std/io/file.ky and
// src/std/io/dir.ky); the kyte_file_*/kyte_dir_* C surface is retired. The only remaining
// shim is kyte_open (variadic open(2)), declared inline where it is used.
long long kyte_open(const char *path, long long flags, long long mode);
void kyte_sleep_ms(long long ms);   // coarse blocking sleep (polling/retry backoffs)

// fd passing (SCM_RIGHTS): the connection-handoff primitive for a fire-and-forget proxy. See core.cpp.
long long kyte_send_fd(long long sock, const char *data, long long len, long long fd);
long long kyte_recv_fd(long long sock, char *buf, long long cap, long long out_fd_ptr);

int  kyte_socket_connect(const char *host, int port);
int  kyte_close(int fd);
int  kyte_socket_listen(int port);
int  kyte_socket_accept(int server_fd);
int  kyte_socket_send(int fd, const char *data);
int  kyte_socket_send_n(int fd, const char *data, int len);
int  kyte_socket_recv(int fd, char *buf, int max_len);
// TLS is pure Kyte as of M13 (crypto/tls + net/tlsmembio + net/tls12bio); no C TLS declarations remain.

typedef struct ProcessContext ProcessContext;
ProcessContext* kyte_process_spawn(const char *cmd, const char *args_str);
int  kyte_process_write_stdin(ProcessContext *ctx, const char *data);
int  kyte_process_read_stdout(ProcessContext *ctx, char *buf, int max_len);
int  kyte_process_wait(ProcessContext *ctx);
long long kyte_process_pid(ProcessContext *ctx);
ProcessContext *kyte_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                            const char *rootfs, const char *hostname, int drop_caps,
                                            int no_new_privs, int seccomp_deny);
int  kyte_process_try_wait(ProcessContext *ctx);
int  kyte_process_kill(ProcessContext *ctx, int sig);
void kyte_process_free(ProcessContext *ctx);
typedef struct WatcherContext WatcherContext;
WatcherContext* kyte_fs_watcher_create(const char *path);
const char* kyte_fs_watcher_next_event(WatcherContext *ctx);
void kyte_fs_watcher_free_event(const char *ptr);
void kyte_fs_watcher_close(WatcherContext *ctx);

#ifdef __cplusplus
}
#endif
#endif
