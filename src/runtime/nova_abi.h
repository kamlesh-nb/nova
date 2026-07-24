// nova_abi.h — FROZEN ABI contract between the Nova LLVM codegen and the runtime.
//
// The compiler emits LLVM IR that calls these symbols by their plain, unmangled
// C names. Any runtime (the old C one, or this C++20 rewrite) MUST export every
// symbol with C linkage (extern "C") and the exact signatures below, and MUST
// reproduce the heap-object memory layout, or generated code breaks.
//
// Source of truth for what codegen depends on: lang/src/codegen/declarations.zig.
// Reference implementation being replaced: discards/runtime-c-20260713/.
#ifndef NOVA_ABI_H
#define NOVA_ABI_H

#include <stdint.h>
#include <stddef.h>

// ---------------------------------------------------------------------------
// Value representation (NON-NEGOTIABLE — codegen hardcodes this)
// ---------------------------------------------------------------------------
// Every Nova value is passed as a 64-bit integer (`long long`, LLVM i64; i32
// under wasm). Heap objects (string, list, map, struct, closure) are pointers
// stored in that integer. Codegen moves between i64 and pointers via
// IntToPtr/PtrToInt; the runtime must keep pointers representable as i64.
//
// Heap-object header — 8 bytes IMMEDIATELY BEFORE the returned pointer:
//
//     offset -8 .. -5 :  int32  refcount   (atomic; initialized to 1)
//     offset -4 .. -1 :  int32  length     (payload byte length)
//     offset  0 ..     :  payload (zero-initialized)
//
// The pointer handed to Nova code points at the payload (raw + 8). Codegen reads
// the string length INLINE at (ptr - 4). ARC uses the refcount at (ptr - 8), with
// sentinel refcount < 0 marking a freed/exempt object. Objects allocated in a
// fiber arena are refcount-exempt (retain/release/free are no-ops for them).
#define NOVA_OBJ_HEADER_SIZE 8

#ifdef __cplusplus
extern "C" {
#endif

// ===== Memory / ARC (allocator) ============================================
long long nova_bytes_alloc(long long size);            // arena-first; header set, rc=1
long long nova_bytes_alloc_persistent(long long size); // never arena (malloc)
void      nova_bytes_free(long long ptr_val);
void      nova_retain(long long ptr_val);
void      nova_release(long long ptr_val, void (*destructor)(long long));

// Boxed `any` — an owned dynamic value: [payload:i64][dtor:i64] in an ARC object.
// box: MOVE payload's +1 into the box; unbox: read payload (borrow); box_dtor:
// release the inner value via its carried destructor when the box is freed.
long long nova_any_box(long long payload, long long dtor);
long long nova_any_unbox(long long box);
void      nova_any_box_dtor(long long box);

// Value-type optionals (V1) — a value-optional is a pointer to a boxed value, or null for `undefined`.
// Present-`0` becomes a non-null box, so it is distinguishable from absent (uniform across all widths).
long long nova_valopt_box(long long value);
long long nova_valopt_unbox(long long box);

// ===== Number -> string (interpolation / concat) ===========================
char *nova_i64_to_string(long long v); // fresh Nova string (+1)
char *nova_f64_to_string(double v);    // fresh Nova string (+1), shortest round-trip
char *nova_bool_to_string(long long v); // "true"/"false"

// ===== decimal128 (IEEE 754-2008, BID — BSON-wire-compatible) ================
long long   nova_decimal_from_string(const char *s); // fresh 16-byte heap decimal (+1)
const char *nova_decimal_to_string(long long ptr);   // fresh Nova string (+1)
// Stage 2 arithmetic + compare. Each op reads its operands and returns a fresh decimal (+1);
// cmp returns a three-way {-1, 0, 1}.
// ===== Command-line arguments ==============================================
void        nova_set_args(int argc, char **argv); // called by main() before __nova_main
long long   nova_arg_count(void);                 // argc
char       *nova_arg_at(long long i);             // argv[i] as a fresh Nova string (+1)

// ===== decimal128 arithmetic ===============================================
long long   nova_decimal_add(long long a, long long b);
long long   nova_decimal_sub(long long a, long long b);
long long   nova_decimal_mul(long long a, long long b);
long long   nova_decimal_div(long long a, long long b);
long long   nova_decimal_mod(long long a, long long b);
long long   nova_decimal_cmp(long long a, long long b);

// ===== Program entry / concurrency =========================================
// Program entry lives in the runtime; it drives __nova_main (emitted by codegen).
extern long long __nova_main(void);
void nova_concurrency_spawn(long long closure);   // closure = boxed {fn_ptr, env} or fn ptr
void nova_concurrency_sleep(long long ms);

// ===== Coroutine frames (M3-C) =============================================
// Backing store for LLVM coroutine frames. The compiler emits, per `async fn`:
//   frame = nova_coro_alloc(llvm.coro.size)   (llvm.coro.begin uses it)
//   nova_coro_free(llvm.coro.free(...))        (in the cleanup path)
// Raw malloc/free today; a per-task pool can slot in later (workstream D) without
// touching codegen. Frames are NOT ARC objects — no 8-byte header.
long long nova_coro_alloc(long long size);
void      nova_coro_free(long long frame);

// Single-threaded ready-queue scheduler for coroutine handles (M3-C). schedule
// enqueues a handle to resume; next dequeues one (0 = queue empty). Codegen emits
// the resume loop; the Asio io_context supersedes this in workstream D.
void      nova_sched_schedule(long long handle);
void      nova_sched_schedule_detached(long long handle);
long long nova_sched_next(void);
// M3-D: the scheduler is an Asio io_context. nova_run drives it until all scheduled
// coroutines (and pending timers/sockets) complete; nova_io_context exposes the
// context for timer/socket awaitables.
void      nova_run(void);
// Drives the loop until `root` actually completes (not merely until the context
// is idle). Aborts loudly on a genuinely lost wakeup rather than letting the
// caller read an unwritten promise slot.
void      nova_run_root(long long root);
// Destroy a coroutine frame, serialised against the scheduler. Use instead of a
// bare llvm.coro.destroy wherever one coroutine frees another's frame.
void      nova_coro_release(long long handle);
long long nova_io_context(void);
// M3-D-3: register `parent` to be woken when coroutine `child` completes. The
// runtime (not the coroutine) schedules the waiter after the child's resume returns
// — race-free under multi-threaded execution. Call before scheduling the child.
void      nova_register_waiter(long long child, long long parent);
// M3-D-4: await a `go`-launched task. Returns 1 if already complete (read result
// inline), else registers `waiter` and returns 0 (caller suspends). Race-free.
long long nova_await_future(long long future, long long waiter);
// M3-D-6: coroutine-aware channels. recv returns 1 (value in *out) or 0 (parked
// `self`; caller suspends and retries when a send wakes it).
long long nova_chan_new(long long capacity);
void      nova_chan_send(long long ch, long long val);
long long nova_chan_recv(long long ch, long long self, long long *out);
void      nova_chan_free(long long ch);
// M3-D-6: async socket I/O via offload. The *_async fns park `self` (the caller
// suspends); a worker performs the blocking op and reschedules self. take_result
// returns the op's result after resume.
void      nova_io_recv_async(long long fd, long long buf, long long max_len, long long self);
void      nova_io_accept_async(long long server_fd, long long self);
long long nova_io_take_result(long long self);
// M3-D-7: scalable async server sockets (true non-blocking asio; pending ops hold no
// thread). listen/close are synchronous; aaccept/arecv/asend park `self` and resume
// via nova_io_take_result. Handles are opaque pointers.
long long nova_aserver_listen(long long port);
void      nova_aconnect(long long host, long long port, long long self);
void      nova_aaccept(long long server, long long self);
void      nova_coro_hold_arg(long long coro, long long ptr, void (*dtor)(long long));
long long nova_when_any(long long buf, long long n, long long self);
long long nova_when_any_deadline(long long buf, long long n, long long ms, long long self);
void      nova_arecv(long long sock, long long buf, long long max_len, long long self);
void      nova_arecv_deadline(long long sock, long long buf, long long max_len, long long ms, long long self);
void      nova_asend(long long sock, long long data, long long self);
void      nova_aclose(long long sock);
// M3-D: non-blocking timer await — arm a timer for `ms` ms, then reschedule the
// awaiting coroutine `handle` when it fires. The coroutine suspends after calling.
void      nova_await_timer(long long handle, long long ms);

// ===== Channels (long long handles) ========================================
long long nova_channel_create(int capacity);
void      nova_channel_send(long long channel_handle, long long val);
long long nova_channel_recv(long long channel_handle);
void      nova_channel_destroy(long long channel_handle);

// ===== Sync primitives (long long handles) =================================
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
int32_t nova_atomic_cas_i64(int64_t *p, int64_t expected, int64_t desired); // desired is 64-bit: codegen passes i64
int64_t nova_atomic_load_i64(int64_t *p);
void    nova_atomic_store_i64(int64_t *p, int64_t v);
int32_t nova_atomic_cas_bool(uint8_t *p, int32_t expected, int32_t desired);
int32_t nova_atomic_load_bool(uint8_t *p);
void    nova_atomic_store_bool(uint8_t *p, int32_t v);

// ===== Exceptions — REMOVED (specs §5.5, plan P2-12) =======================
// ExceptionFrame, nova_push_exception_frame, nova_pop_exception_frame and nova_throw are
// gone with `throw`/`try`/`catch`. The value was truncated to i32 (so a thrown string
// arrived as a number), nothing unwound (so every intervening frame leaked), and longjmp
// out of a coroutine — which every `async fn` is — is UB. Errors are values now.
long long nova_get_stacktrace(void); // separate stub: returns an empty buffer
void      nova_optional_deref_fail(const char *loc); // §3.4 P2-14: absent-optional deref abort

// ===== Time / logging / env / crypto / exit ================================
int64_t   nova_time_now(void);
int64_t   nova_time_now_ns(void);
void      nova_log_string(const char *s);
void      nova_log_info(const char *s);
void      nova_log_debug(const char *s);
void      nova_log_err(const char *s);
char*     nova_getenv(const char *name);
void      nova_setenv(const char *name, const char *value);
char*     nova_sha256(const char *input);       // lowercase hex digest (wolfCrypt)
char*     nova_sha512(const char *input);
char*     nova_sha1(const char *input);
char*     nova_md5(const char *input);
char*     nova_mysql_scramble(const char *password, const char *salt, int salt_len);      // native_password, 20 raw bytes
char*     nova_mysql_sha2_scramble(const char *password, const char *salt, int salt_len); // caching_sha2 fast, 32 raw bytes
char*     nova_hmac_sha256(const char *key, const char *msg);
char*     nova_random_hex(long long n);          // n CSPRNG bytes as 2n hex chars
void      nova_exit(int code);

// ===== Test harness / coverage =============================================
void        nova_test_reset(void);
void        nova_test_begin(const char *name); // names the running @test so a failure can report it
void        nova_test_fail(const char *msg);
int         nova_test_did_fail(void);
const char* nova_test_fail_message(void);
extern long long *__nova_cov_counters;
void        nova_coverage_init(long long count);
void        nova_coverage_dump(long long count);

// ===== File I/O ============================================================
typedef struct NovaFileStat { long size; int mode; long atime, mtime, ctime; int is_dir, is_reg, is_symlink; } NovaFileStat;
int   nova_file_stat(const char *path, NovaFileStat *out);
void *nova_file_open(const char *path, const char *mode);
int   nova_file_close(void *fp);
int   nova_file_read(void *fp, char *buf, int size);
int   nova_file_read_all(void *fp, char *buf, int size);
int   nova_file_write(void *fp, const char *buf, int size);
int   nova_file_write_all(void *fp, const char *buf, int size);
int   nova_file_seek(void *fp, long offset, int whence);
long  nova_file_tell(void *fp);
int   nova_file_eof(void *fp);
int   nova_file_flush(void *fp);
const char *nova_file_error(void);
int   nova_file_exists(const char *path);

// ===== Directory ops =======================================================
typedef int (*nova_dir_walk_callback)(const char *path, int is_dir, void *userdata);
int   nova_dir_walk(const char *root, nova_dir_walk_callback cb, void *userdata);
const char *nova_dir_error(void);
void *nova_dir_open(const char *path);
int   nova_dir_close(void *dir);
const char *nova_dir_read(void *dir);
int   nova_dir_create(const char *path, int mode);
int   nova_dir_remove(const char *path);
int   nova_dir_rename(const char *oldp, const char *newp);
int   nova_dir_exists(const char *path);
int   nova_dir_is_dir(const char *path);
char *nova_dir_getcwd(void);
int   nova_dir_chdir(const char *path);

// ===== Sockets / TLS (Boost.Asio in the full runtime) ======================
int  nova_socket_connect(const char *host, int port);
int  nova_close(int fd);
int  nova_socket_listen(int port);
int  nova_socket_accept(int server_fd);
int  nova_socket_send(int fd, const char *data);
int  nova_socket_send_n(int fd, const char *data, int len);
int  nova_socket_recv(int fd, char *buf, int max_len);
typedef struct TlsContext TlsContext;
TlsContext* nova_tls_new(int fd, const char *hostname);
int  nova_tls_handshake(TlsContext *ctx);
int  nova_tls_write(TlsContext *ctx, const char *data);
int  nova_tls_read(TlsContext *ctx, char *buf, int max_len);
void nova_tls_free(TlsContext *ctx);

// ===== Process / filesystem watcher ========================================
typedef struct ProcessContext ProcessContext;
ProcessContext* nova_process_spawn(const char *cmd, const char *args_str);
int  nova_process_write_stdin(ProcessContext *ctx, const char *data);
int  nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len);
int  nova_process_wait(ProcessContext *ctx);
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
#endif // NOVA_ABI_H
