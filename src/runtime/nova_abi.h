
#ifndef NOVA_ABI_H
#define NOVA_ABI_H

#include <stdint.h>
#include <stddef.h>

// L5 stability: the extern-C runtime ABI contract version. The STABLE seam this pins is the
// heap-object layout and the reference-counting entry points (see docs/abi/runtime-abi.md):
//   * every heap object carries an 8-byte header; refcount is a u32 at [ptr-8], byte-length a
//     u32 at [ptr-4]; the object payload starts at ptr.
//   * nova_retain(ptr) / nova_release(ptr, dtor) are the ref-count entry points.
//   * nova_bytes_alloc / nova_bytes_free are the allocation entry points.
// The compiler emits code against exactly this layout (NOVA_OBJ_HEADER_SIZE, mirrored in
// src/codegen/arc.zig and surfaced as build_options.nova_abi_version). Bump this ONLY on a
// breaking change to that stable seam -- NOT for adding async/reactor/syscall symbols below,
// which are INTERNAL (compiler<->its own runtime) and not a third-party contract.
#define NOVA_ABI_VERSION 1

#define NOVA_OBJ_HEADER_SIZE 8

#ifdef __cplusplus
extern "C" {
#endif

// Runtime trace facility (M0 of the C++ runtime retirement plan). Writes to the file named by the
// NOVA_TRACE environment variable, with an explicit flush per line, so runtime diagnostics surface
// reliably regardless of how the binary is built, cached, or run (the scheduler debug was blocked
// by stderr not surfacing). Disabled and near-zero-cost when NOVA_TRACE is unset. Thread-safe.
// Use from C++ via the NOVA_TRACE macro; callable from Nova via nova_trace_msg / nova_trace_kv.
int  nova_trace_enabled(void);
void nova_trace_line(const char *s);           // one pre-formatted line (a newline is appended)
void nova_trace_msg(long long nova_str);        // a Nova string (callable from Nova)
void nova_trace_kv(long long nova_str, long long value); // "tag=value" (callable from Nova)
void nova_tracef(const char *fmt, ...);          // printf-style, C++-internal; a newline is appended

// C++-internal trace macro. Zero-argument-overhead when NOVA_TRACE is unset (a load-once flag
// short-circuits before the format is evaluated). Example: NOVA_TRACE("sched pump h=%lld", h);
#ifdef __cplusplus
} // extern "C"
#endif
#define NOVA_TRACE(...) do { if (nova_trace_enabled()) nova_tracef(__VA_ARGS__); } while (0)
#ifdef __cplusplus
extern "C" {
#endif

long long nova_bytes_alloc(long long size);
long long nova_bytes_alloc_persistent(long long size);
void      nova_bytes_free(long long ptr_val);
void      nova_retain(long long ptr_val);
void      nova_release(long long ptr_val, void (*destructor)(long long));

long long nova_any_box(long long payload, long long dtor);
long long nova_any_unbox(long long box);
void      nova_any_box_dtor(long long box);

long long nova_valopt_box(long long value);
long long nova_valopt_unbox(long long box);

char *nova_i64_to_string(long long v);
char *nova_f64_to_string(double v);
char *nova_bool_to_string(long long v);

long long   nova_decimal_from_string(const char *s);
const char *nova_decimal_to_string(long long ptr);

void        nova_set_args(int argc, char **argv);
long long   nova_arg_count(void);
char       *nova_arg_at(long long i);

long long   nova_decimal_add(long long a, long long b);
long long   nova_decimal_sub(long long a, long long b);
long long   nova_decimal_mul(long long a, long long b);
long long   nova_decimal_div(long long a, long long b);
long long   nova_decimal_mod(long long a, long long b);
long long   nova_decimal_cmp(long long a, long long b);

extern long long __nova_main(void);
void nova_concurrency_spawn(long long closure);
void nova_concurrency_sleep(long long ms);

long long nova_coro_alloc(long long size);
void      nova_coro_free(long long frame);

void      nova_sched_schedule(long long handle);
void      nova_sched_schedule_detached(long long handle);
long long nova_sched_next(void);

void      nova_run(void);
long long nova_thread_id(void);
long long nova_worker_count(void);
void nova_pin_next_coro(long long rid);
void nova_hold_all_reactors(void);

void      nova_run_root(long long root);

void      nova_coro_release(long long handle);
long long nova_io_context(void);

void      nova_register_waiter(long long child, long long parent);

long long nova_await_future(long long future, long long waiter);

long long nova_chan_new(long long capacity);
void      nova_chan_send(long long ch, long long val);
long long nova_chan_recv(long long ch, long long self, long long *out);
void      nova_chan_free(long long ch);

void      nova_io_recv_async(long long fd, long long buf, long long max_len, long long self);
void      nova_io_accept_async(long long server_fd, long long self);
long long nova_io_take_result(long long self);

long long nova_aserver_listen(long long port);
long long nova_aserver_listen_addr(long long host, long long port);
void      nova_aconnect(long long host, long long port, long long self);
void      nova_aaccept(long long server, long long self);
void      nova_coro_hold_arg(long long coro, long long ptr, void (*dtor)(long long));
long long nova_when_any(long long buf, long long n, long long self);
long long nova_when_any_deadline(long long buf, long long n, long long ms, long long self);
void      nova_arecv(long long sock, long long buf, long long max_len, long long self);
void      nova_arecv_deadline(long long sock, long long buf, long long max_len, long long ms, long long self);
void      nova_asend(long long sock, long long data, long long self);
void      nova_aclose(long long sock);

void      nova_await_timer(long long handle, long long ms);

long long nova_channel_create(int capacity);
void      nova_channel_send(long long channel_handle, long long val);
long long nova_channel_recv(long long channel_handle);
void      nova_channel_destroy(long long channel_handle);

long long nova_spin_create(void);
void      nova_spin_lock(long long h);
void      nova_spin_unlock(long long h);
long long nova_mutex_create(void);
void      nova_mutex_lock(long long h);
void      nova_mutex_unlock(long long h);
void      nova_mutex_destroy(long long h);
long long nova_condvar_create(void);
void      nova_condvar_wait(long long cv, long long m);
void      nova_condvar_signal(long long cv);
void      nova_condvar_broadcast(long long cv);
void      nova_condvar_destroy(long long cv);
long long nova_rwlock_create(void);
void      nova_rwlock_acquire_read(long long h);
void      nova_rwlock_release_read(long long h);
void      nova_rwlock_acquire_write(long long h);
void      nova_rwlock_release_write(long long h);
void      nova_rwlock_destroy(long long h);
int32_t nova_atomic_add_i32(int32_t *p, int32_t d);
int32_t nova_atomic_sub_i32(int32_t *p, int32_t d);
int32_t nova_atomic_cas_i32(int32_t *p, int32_t expected, int32_t desired);
int32_t nova_atomic_load_i32(int32_t *p);
void    nova_atomic_store_i32(int32_t *p, int32_t v);
int64_t nova_atomic_add_i64(int64_t *p, int64_t d);
int64_t nova_atomic_sub_i64(int64_t *p, int64_t d);
int32_t nova_atomic_cas_i64(int64_t *p, int64_t expected, int64_t desired);
int64_t nova_atomic_load_i64(int64_t *p);
void    nova_atomic_store_i64(int64_t *p, int64_t v);
int32_t nova_atomic_cas_bool(uint8_t *p, int32_t expected, int32_t desired);
int32_t nova_atomic_load_bool(uint8_t *p);
void    nova_atomic_store_bool(uint8_t *p, int32_t v);

long long nova_get_stacktrace(void);
void      nova_optional_deref_fail(const char *loc);

int64_t   nova_time_now(void);
int64_t   nova_time_now_ns(void);
void      nova_log_string(const char *s);
void      nova_log_info(const char *s);
void      nova_log_debug(const char *s);
void      nova_log_err(const char *s);
void      nova_exit(int code);

void        nova_test_reset(void);
void        nova_test_begin(const char *name);
void        nova_test_fail(const char *msg);
int         nova_test_did_fail(void);
const char* nova_test_fail_message(void);
extern long long *__nova_cov_counters;
void        nova_coverage_init(long long count);
void        nova_coverage_dump(long long count);

// File and directory I/O moved to Nova over os/sys in M5 (see src/std/io/file.nova and
// src/std/io/dir.nova); the nova_file_*/nova_dir_* C surface is retired. The only remaining
// shim is nova_open (variadic open(2)), declared inline where it is used.
long long nova_open(const char *path, long long flags, long long mode);

// fd passing (SCM_RIGHTS): the connection-handoff primitive for a fire-and-forget proxy. See core.cpp.
long long nova_send_fd(long long sock, const char *data, long long len, long long fd);
long long nova_recv_fd(long long sock, char *buf, long long cap, long long out_fd_ptr);

int  nova_socket_connect(const char *host, int port);
int  nova_close(int fd);
int  nova_socket_listen(int port);
int  nova_socket_accept(int server_fd);
int  nova_socket_send(int fd, const char *data);
int  nova_socket_send_n(int fd, const char *data, int len);
int  nova_socket_recv(int fd, char *buf, int max_len);
// TLS is pure Nova as of M13 (crypto/tls + net/tlsmembio + net/tls12bio); no C TLS declarations remain.

typedef struct ProcessContext ProcessContext;
ProcessContext* nova_process_spawn(const char *cmd, const char *args_str);
int  nova_process_write_stdin(ProcessContext *ctx, const char *data);
int  nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len);
int  nova_process_wait(ProcessContext *ctx);
long long nova_process_pid(ProcessContext *ctx);
ProcessContext *nova_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                            const char *rootfs, const char *hostname, int drop_caps,
                                            int no_new_privs, int seccomp_deny);
int  nova_process_try_wait(ProcessContext *ctx);
int  nova_process_kill(ProcessContext *ctx, int sig);
void nova_process_free(ProcessContext *ctx);
typedef struct WatcherContext WatcherContext;
WatcherContext* nova_fs_watcher_create(const char *path);
const char* nova_fs_watcher_next_event(WatcherContext *ctx);
void nova_fs_watcher_free_event(const char *ptr);
void nova_fs_watcher_close(WatcherContext *ctx);

#ifdef __cplusplus
}
#endif
#endif
