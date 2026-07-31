// io_uring: the COMPLETION-based Linux reactor backend, the Linux peer of Windows IOCP (epoll is the
// readiness peer of kqueue). Linux-only; the whole file compiles to nothing elsewhere.
//
// Why any of this is C rather than a Nova `extern("c")` binding, given the project's rule that
// Windows/Linux syscalls should be bound from Nova: io_uring is not a syscall-per-operation API. It
// is two mmap'd ring buffers shared with the kernel, and advancing them correctly REQUIRES acquire/
// release memory ordering on the head/tail indices — a release store to the SQ tail is what makes
// the SQE contents visible to the kernel, and an acquire load of the CQ tail is what makes completed
// CQEs visible to us. Nova has no memory-ordering primitives, so the ring arithmetic cannot be
// expressed there at all. The syscalls themselves (io_uring_setup/io_uring_enter) are raw here too
// because glibc does not wrap them and liburing is deliberately not a dependency.
//
// What IS exposed to Nova is a small, stable ABI (nova_uring_*) that hides only the ring mechanics.

#ifdef __linux__

#include <linux/io_uring.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <signal.h>   // sigset_t, for io_uring_enter's signal-mask argument
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <cstdlib>   // getenv, for the backend selector
#include <cstring>
#include <atomic>

#define NOVA_HAVE_URING 1

namespace {

// glibc exposes no wrappers for these two, so they are issued directly.
inline int nova_sys_io_uring_setup(unsigned entries, struct io_uring_params *p) {
    return (int)::syscall(__NR_io_uring_setup, entries, p);
}
// The last argument is the SIZE of the signal mask in bytes, and it is the KERNEL's sigset_t that
// counts (64 bits on every Linux port), not glibc's — which is 128 bytes and would be rejected with
// EINVAL. Spelled out rather than using glibc's _NSIG, which is not exposed under every feature-test
// macro combination.
const unsigned NOVA_KERNEL_SIGSET_BYTES = 8;

inline int nova_sys_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                                   unsigned flags, sigset_t *sig) {
    return (int)::syscall(__NR_io_uring_enter, fd, to_submit, min_complete, flags, sig,
                          NOVA_KERNEL_SIGSET_BYTES);
}

struct NovaUring {
    int fd = -1;

    // Submission ring. `array` is an indirection table: the kernel reads SQE indices from it, which
    // is what allows SQEs to be reused out of order.
    unsigned *sq_head = nullptr;
    unsigned *sq_tail = nullptr;
    unsigned *sq_mask = nullptr;
    unsigned *sq_array = nullptr;
    struct io_uring_sqe *sqes = nullptr;
    unsigned sq_entries = 0;
    unsigned sq_local_tail = 0;   // SQEs prepared but not yet published to the kernel

    // Completion ring.
    unsigned *cq_head = nullptr;
    unsigned *cq_tail = nullptr;
    unsigned *cq_mask = nullptr;
    struct io_uring_cqe *cqes = nullptr;

    void *sq_ptr = nullptr;  size_t sq_sz = 0;
    void *cq_ptr = nullptr;  size_t cq_sz = 0;
    void *sqe_ptr = nullptr; size_t sqe_sz = 0;
};

}  // namespace

extern "C" {

// 1 if this kernel can create a ring at all. Probes by actually creating and tearing one down:
// io_uring can be present in the headers, absent in the kernel, or administratively disabled
// (/proc/sys/kernel/io_uring_disabled), and only an attempt distinguishes those.
int nova_uring_available(void) {
    struct io_uring_params p;
    std::memset(&p, 0, sizeof(p));
    int fd = nova_sys_io_uring_setup(4, &p);
    if (fd < 0) return 0;
    ::close(fd);
    return 1;
}

// Create a ring with at least `entries` submission slots. Returns an opaque handle, or 0.
long long nova_uring_create(int entries) {
    if (entries <= 0) entries = 64;

    struct io_uring_params p;
    std::memset(&p, 0, sizeof(p));
    int fd = nova_sys_io_uring_setup((unsigned)entries, &p);
    if (fd < 0) return 0;

    NovaUring *r = new NovaUring();
    r->fd = fd;
    r->sq_entries = p.sq_entries;

    r->sq_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
    r->cq_sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);

    // IORING_FEAT_SINGLE_MMAP lets both rings share one mapping; without it they are mapped apart.
    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        if (r->cq_sz > r->sq_sz) r->sq_sz = r->cq_sz;
        r->cq_sz = r->sq_sz;
    }

    r->sq_ptr = ::mmap(nullptr, r->sq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                       fd, IORING_OFF_SQ_RING);
    if (r->sq_ptr == MAP_FAILED) { ::close(fd); delete r; return 0; }

    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        r->cq_ptr = r->sq_ptr;
    } else {
        r->cq_ptr = ::mmap(nullptr, r->cq_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                           fd, IORING_OFF_CQ_RING);
        if (r->cq_ptr == MAP_FAILED) {
            ::munmap(r->sq_ptr, r->sq_sz); ::close(fd); delete r; return 0;
        }
    }

    r->sqe_sz = p.sq_entries * sizeof(struct io_uring_sqe);
    r->sqe_ptr = ::mmap(nullptr, r->sqe_sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                        fd, IORING_OFF_SQES);
    if (r->sqe_ptr == MAP_FAILED) {
        if (r->cq_ptr != r->sq_ptr) ::munmap(r->cq_ptr, r->cq_sz);
        ::munmap(r->sq_ptr, r->sq_sz);
        ::close(fd); delete r; return 0;
    }

    char *sq = (char *)r->sq_ptr;
    char *cq = (char *)r->cq_ptr;
    r->sq_head  = (unsigned *)(sq + p.sq_off.head);
    r->sq_tail  = (unsigned *)(sq + p.sq_off.tail);
    r->sq_mask  = (unsigned *)(sq + p.sq_off.ring_mask);
    r->sq_array = (unsigned *)(sq + p.sq_off.array);
    r->sqes     = (struct io_uring_sqe *)r->sqe_ptr;
    r->cq_head  = (unsigned *)(cq + p.cq_off.head);
    r->cq_tail  = (unsigned *)(cq + p.cq_off.tail);
    r->cq_mask  = (unsigned *)(cq + p.cq_off.ring_mask);
    r->cqes     = (struct io_uring_cqe *)(cq + p.cq_off.cqes);

    r->sq_local_tail = __atomic_load_n(r->sq_tail, __ATOMIC_RELAXED);
    return (long long)(intptr_t)r;
}

void nova_uring_destroy(long long ring) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r) return;
    if (r->sqe_ptr) ::munmap(r->sqe_ptr, r->sqe_sz);
    if (r->cq_ptr && r->cq_ptr != r->sq_ptr) ::munmap(r->cq_ptr, r->cq_sz);
    if (r->sq_ptr) ::munmap(r->sq_ptr, r->sq_sz);
    if (r->fd >= 0) ::close(r->fd);
    delete r;
}

// Stage one operation. `op` is an IORING_OP_* value; `addr`/`len` mean what that op expects (a
// buffer for RECV/SEND, a sockaddr for CONNECT/ACCEPT, a struct __kernel_timespec for TIMEOUT).
// user_data comes back verbatim on the completion — it carries the op record or coroutine handle.
// Returns 0 if staged, -1 if the submission queue is full (the caller should submit and retry).
// `off` is the SQE's off/addr2 union, which several ops need and which is NOT interchangeable with
// len: CONNECT puts the sockaddr LENGTH there (len is unused), and TIMEOUT puts the completion count
// there. Passing it via len instead is a silent EINVAL.
int nova_uring_prep(long long ring, int op, int fd, long long addr, int len, long long off,
                    long long user_data) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r) return -1;

    unsigned head = __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE);
    if (r->sq_local_tail - head >= r->sq_entries) return -1;   // ring full

    unsigned index = r->sq_local_tail & *r->sq_mask;
    struct io_uring_sqe *sqe = &r->sqes[index];
    std::memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = (uint8_t)op;
    sqe->fd = fd;
    sqe->addr = (uint64_t)addr;
    sqe->len = (uint32_t)len;
    sqe->off = (uint64_t)off;
    sqe->user_data = (uint64_t)user_data;

    r->sq_array[index] = index;
    r->sq_local_tail++;
    return 0;
}

// Publish staged SQEs and optionally block for completions. The RELEASE store on the tail is the
// barrier that makes the SQE bodies visible to the kernel — writing the tail without it is the
// classic io_uring corruption bug. Returns the number consumed, or -errno.
int nova_uring_submit_and_wait(long long ring, int wait_nr) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r) return -1;

    unsigned prev = __atomic_load_n(r->sq_tail, __ATOMIC_RELAXED);
    __atomic_store_n(r->sq_tail, r->sq_local_tail, __ATOMIC_RELEASE);
    unsigned to_submit = r->sq_local_tail - prev;

    if (to_submit == 0 && wait_nr == 0) return 0;
    unsigned flags = wait_nr > 0 ? IORING_ENTER_GETEVENTS : 0;
    int n = nova_sys_io_uring_enter(r->fd, to_submit, (unsigned)(wait_nr > 0 ? wait_nr : 0),
                                    flags, nullptr);
    if (n < 0) return -errno;
    return n;
}

// Number of completions currently ready. The ACQUIRE load pairs with the kernel's release of the
// CQ tail, so every CQE below it is fully written before we read it.
int nova_uring_cq_ready(long long ring) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r) return 0;
    unsigned tail = __atomic_load_n(r->cq_tail, __ATOMIC_ACQUIRE);
    unsigned head = __atomic_load_n(r->cq_head, __ATOMIC_RELAXED);
    return (int)(tail - head);
}

// Read the i-th ready completion without consuming it.
int nova_uring_peek(long long ring, int i, long long *user_data, int *res) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r) return -1;
    unsigned head = __atomic_load_n(r->cq_head, __ATOMIC_RELAXED) + (unsigned)i;
    struct io_uring_cqe *cqe = &r->cqes[head & *r->cq_mask];
    if (user_data) *user_data = (long long)cqe->user_data;
    if (res) *res = cqe->res;
    return 0;
}

// Consume `n` completions. The RELEASE store tells the kernel those CQE slots are reusable.
void nova_uring_advance(long long ring, int n) {
    NovaUring *r = (NovaUring *)(intptr_t)ring;
    if (!r || n <= 0) return;
    unsigned head = __atomic_load_n(r->cq_head, __ATOMIC_RELAXED);
    __atomic_store_n(r->cq_head, head + (unsigned)n, __ATOMIC_RELEASE);
}

// --- backend selection --------------------------------------------------------------------------
// Linux has TWO reactor backends, and the target-conditional file rule cannot choose between them:
// it selects by OS, and both are Linux. So the choice is made here, once per process, and every
// Linux-side branch (the C driver and net/eventloop_linux) asks this rather than deciding locally.
//
// epoll is the default because it works on every kernel. io_uring is opt-in via NOVA_REACTOR=uring
// and still probed, because the header being present says nothing about the running kernel — it can
// be too old, or io_uring can be switched off administratively.
const int NOVA_BACKEND_EPOLL = 0;
const int NOVA_BACKEND_URING = 1;

int nova_reactor_backend(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    const char *sel = std::getenv("NOVA_REACTOR");
    int want_uring = sel && (std::strcmp(sel, "uring") == 0 || std::strcmp(sel, "io_uring") == 0);
    cached = (want_uring && nova_uring_available()) ? NOVA_BACKEND_URING : NOVA_BACKEND_EPOLL;
    return cached;
}

// The ring the calling thread is driving. A ring handle is a heap pointer, so it cannot live in the
// reactor's `int kq` field the way an epoll fd does — this thread-local is how the free-function
// submit path (net/reactorio) reaches it without threading it through every call, mirroring what
// nova_reactor_current does for the readiness backends.
static thread_local long long g_current_ring = 0;
long long nova_uring_current(void) { return g_current_ring; }
void nova_uring_set_current(long long ring) { g_current_ring = ring; }

// Opcodes Nova needs, exposed as functions so the Nova side does not hardcode kernel constants that
// vary by header version.
int nova_uring_op_recv(void)    { return IORING_OP_RECV; }
int nova_uring_op_send(void)    { return IORING_OP_SEND; }
int nova_uring_op_accept(void)  { return IORING_OP_ACCEPT; }
int nova_uring_op_connect(void) { return IORING_OP_CONNECT; }
int nova_uring_op_timeout(void) { return IORING_OP_TIMEOUT; }
int nova_uring_op_poll_add(void){ return IORING_OP_POLL_ADD; }

}  // extern "C"

#endif  // __linux__
