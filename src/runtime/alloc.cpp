
#include "nova_abi.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#ifndef _WIN32
#include <dlfcn.h>
#include <sys/mman.h>
#ifndef MAP_ANON
#define MAP_ANON MAP_ANONYMOUS
#endif
#endif

namespace {

constexpr size_t FALLBACK_ARENA_SIZE = 32 * 1024 * 1024;
inline size_t arena_align(size_t s) { return (s + 7) & ~size_t(7); }

thread_local char *t_arena_start = nullptr;
thread_local char *t_arena_current = nullptr;

// The bump arena's backing pages come from the kernel directly (mmap of anonymous memory), not the
// C heap: M8 moves the allocator's page source off libc malloc. The arena is a leaked-forever
// per-thread bump region (arena objects are never individually freed, so nova_bytes_free no-ops on
// them), which is exactly the shape a single anonymous mapping wants. Individual overflow and
// persistent objects still use malloc, because they are freed one at a time and mapping each would
// round every small object up to a whole page. On Windows the page source stays malloc for now.
inline char *arena_page_alloc(size_t size) {
#ifdef _WIN32
  return (char *)std::malloc(size);
#else
  void *p = ::mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  return (p == MAP_FAILED) ? nullptr : (char *)p;
#endif
}

inline bool is_in_arena(const char *ptr) {
  return t_arena_start && ptr >= t_arena_start &&
         ptr < t_arena_start + FALLBACK_ARENA_SIZE;
}

const bool g_audit_enabled_v = std::getenv("NOVA_ARC_AUDIT") != nullptr;
inline bool audit_enabled() { return g_audit_enabled_v; }

std::atomic<long long> g_audit_live{0};
std::atomic<long long> g_audit_bytes{0};

const bool g_dump_enabled_v = std::getenv("NOVA_ARC_DUMP") != nullptr;
inline bool dump_enabled() { return g_dump_enabled_v; }

struct LiveEntry {
  const char *base;
  long long size;
  const void *site;
};
LiveEntry *g_live = nullptr;
size_t g_live_n = 0;
size_t g_live_cap = 0;
std::atomic_flag g_live_lock = ATOMIC_FLAG_INIT;

inline void live_lock() {
  while (g_live_lock.test_and_set(std::memory_order_acquire)) {
  }
}
inline void live_unlock() { g_live_lock.clear(std::memory_order_release); }

inline void live_insert(const char *base, long long size, const void *site) {
  live_lock();
  if (g_live_n == g_live_cap) {
    size_t ncap = g_live_cap ? g_live_cap * 2 : 1024;

    LiveEntry *nt = (LiveEntry *)std::realloc(g_live, ncap * sizeof(LiveEntry));
    if (!nt) {
      live_unlock();
      return;
    }
    g_live = nt;
    g_live_cap = ncap;
  }
  g_live[g_live_n].base = base;
  g_live[g_live_n].size = size;
  g_live[g_live_n].site = site;
  g_live_n++;
  live_unlock();
}

inline bool live_contains(const char *base) {
  live_lock();
  bool found = false;
  for (size_t i = g_live_n; i-- > 0;) {
    if (g_live[i].base == base) {
      found = true;
      break;
    }
  }
  live_unlock();
  return found;
}

std::atomic<long long> g_dead_releases{0};

struct DeadEntry {
  const char *base;
  long long size;
  char preview[17];
  bool printable;
};
constexpr size_t DEAD_RING = 512;
DeadEntry g_dead_ring[DEAD_RING];
size_t g_dead_ring_n = 0;

inline void dead_ring_record(const char *base, long long size) {
  DeadEntry &e = g_dead_ring[g_dead_ring_n % DEAD_RING];
  g_dead_ring_n++;
  e.base = base;
  e.size = size;
  size_t n = (size_t)size;
  if (n > 16)
    n = 16;
  const unsigned char *p = (const unsigned char *)(base + NOVA_OBJ_HEADER_SIZE);
  e.printable = n > 0;
  for (size_t k = 0; k < n; k++)
    if (p[k] < 32 || p[k] > 126)
      e.printable = false;
  std::memcpy(e.preview, p, n);
  e.preview[n] = '\0';
}

inline const DeadEntry *dead_ring_find(const char *base) {
  const size_t lim = g_dead_ring_n < DEAD_RING ? g_dead_ring_n : DEAD_RING;
  for (size_t i = 0; i < lim; i++)
    if (g_dead_ring[i].base == base)
      return &g_dead_ring[i];
  return nullptr;
}

inline void check_release_of_dead(const char *payload) {
  if (!audit_enabled() || !dump_enabled())
    return;
  const char *base = payload - NOVA_OBJ_HEADER_SIZE;
  if (live_contains(base))
    return;

  const int32_t rc = *reinterpret_cast<const int32_t *>(base);
  if (rc > 1000000)
    return;
  const long long n = g_dead_releases.fetch_add(1, std::memory_order_relaxed);
  if (n >= 8)
    return;
  live_lock();
  const DeadEntry *e = dead_ring_find(base);
  if (e) {
    if (e->printable)
      std::fprintf(stderr,
                   "\n*** DOUBLE RELEASE #%lld: size=%lld was \"%s\"\n", n + 1,
                   e->size, e->preview);
    else {
      char hex[64];
      size_t w = 0;
      size_t hn = (size_t)e->size;
      if (hn > 16) hn = 16;
      for (size_t k = 0; k < hn && w + 3 < sizeof(hex); k++)
        w += (size_t)std::snprintf(hex + w, sizeof(hex) - w, "%02x ",
                                   (unsigned char)e->preview[k]);
      hex[w] = '\0';
      std::fprintf(stderr, "\n*** DOUBLE RELEASE #%lld: size=%lld [%s]\n",
                   n + 1, e->size, hex);
    }
  } else {
    std::fprintf(stderr,
                 "\n*** RELEASE OF AN UNTRACKED OBJECT #%lld at %p (never "
                 "allocated through the audited path?)\n",
                 n + 1, (const void *)payload);
  }
  live_unlock();
}

inline void live_remove(const char *base) {
  live_lock();
  for (size_t i = g_live_n; i-- > 0;) {
    if (g_live[i].base == base) {
      dead_ring_record(base, g_live[i].size);
      g_live[i] = g_live[g_live_n - 1];
      g_live_n--;
      break;
    }
  }
  live_unlock();
}

inline void audit_alloc(const char *base, long long size, const void *site) {
  if (!audit_enabled())
    return;
  g_audit_live.fetch_add(1, std::memory_order_relaxed);
  g_audit_bytes.fetch_add(size, std::memory_order_relaxed);
  if (dump_enabled())
    live_insert(base, size, site);
}

inline void audit_free(const char *base, long long size) {
  if (!audit_enabled())
    return;
  g_audit_live.fetch_sub(1, std::memory_order_relaxed);
  g_audit_bytes.fetch_sub(size, std::memory_order_relaxed);
  if (dump_enabled())
    live_remove(base);
}

inline long long audit_size_of(const char *base) {
  return (long long)*reinterpret_cast<const int32_t *>(base + 4);
}

inline void write_header(char *base, long long size) {
  *reinterpret_cast<int32_t *>(base) = 1;
  *reinterpret_cast<int32_t *>(base + 4) = (int32_t)size;
  std::memset(base + NOVA_OBJ_HEADER_SIZE, 0, (size_t)size);
}

// Header WITHOUT zeroing the payload. Two callers rely on this being safe: (1) the bump arena, whose
// pages come from mmap(MAP_ANON) already zero-filled and which never reuses memory, so the payload is
// already zero; (2) buffers the caller fills completely before any read (StringBuilder). Skipping the
// memset removes a redundant second write over every byte -- on a large response body that memset was
// half the buffer's memory traffic.
inline void write_header_nozero(char *base, long long size) {
  *reinterpret_cast<int32_t *>(base) = 1;
  *reinterpret_cast<int32_t *>(base + 4) = (int32_t)size;
}

}  // end anonymous namespace

// ---- Per-request (per-coroutine) region arena --------------------------------------------------------
// A region is a chain of mmap'd chunks; allocation bump-pointers within the active chunk and grabs a new
// chunk (from a capped free-list, else fresh mmap) when the current one is full, so a big request just
// chains more chunks. Request-region objects are stamped with a NEGATIVE sentinel refcount, so the
// EXISTING `*rc < 0` guards in nova_retain/nova_release/nova_bytes_free already treat them as immortal --
// no per-object ARC, no per-object free. The whole region is reclaimed in O(chunks) on reset (chunks go
// back to the pool). When no region is active (t_region == nullptr) allocation uses the default 32MB
// thread arena UNCHANGED, so non-web programs and startup allocations are entirely unaffected.
constexpr size_t REGION_CHUNK_SIZE = 512 * 1024;
constexpr int MAX_POOLED_CHUNKS = 16;               // cap idle chunks per thread (16 * 512KB = 8MB)
constexpr int32_t REGION_RC = -1431655765;          // negative => immortal to ARC (any negative works)

struct RegionChunk {
  char *base;
  char *cur;
  char *end;
  size_t size;
  RegionChunk *next;
};
struct Region {
  RegionChunk *chunks;         // linked list; head is the active (bump target)
  unsigned magic;              // 0x9E90 while live, cleared on free (belt-and-suspenders guard)
  bool freed;                  // set on reset/free
  Region *pool_next;           // free-list link when this struct sits in the Region pool
  unsigned long long gen;      // MONOTONIC generation: uniquely identifies this region's current lifetime
};
static const unsigned REGION_MAGIC = 0x9E90;
static std::atomic<long long> g_region_stale_hits{0};
static std::atomic<unsigned long long> g_region_gen_ctr{1};   // never reuses a value (0 = invalid)

thread_local Region *t_region = nullptr;            // active region, or null = default arena
thread_local RegionChunk *t_free_chunks = nullptr;  // capped pool of reusable chunks
thread_local int t_free_count = 0;
thread_local Region *t_region_pool = nullptr;       // pool of reusable Region structs (never std::free'd)
thread_local int t_region_pool_count = 0;
constexpr int MAX_POOLED_REGIONS = 512;             // >> realistic concurrency; bounds struct memory

static RegionChunk *region_chunk_new(size_t need) {
  size_t sz = need > REGION_CHUNK_SIZE ? need : REGION_CHUNK_SIZE;
  if (t_free_chunks && sz <= REGION_CHUNK_SIZE) {   // reuse a pooled default-size chunk
    RegionChunk *c = t_free_chunks;
    t_free_chunks = c->next;
    t_free_count--;
    c->cur = c->base;
    c->next = nullptr;
    return c;
  }
  RegionChunk *c = (RegionChunk *)std::malloc(sizeof(RegionChunk));
  if (!c) return nullptr;
  c->base = arena_page_alloc(sz);
  if (!c->base) { std::free(c); return nullptr; }
  c->cur = c->base;
  c->end = c->base + sz;
  c->size = sz;
  c->next = nullptr;
  return c;
}

// Return a region's chunks to the pool (default-size ones, up to the cap) or unmap them (oversized/excess),
// then release the Region record. O(number of chunks).
static void region_recycle_chunks(Region *r) {
  RegionChunk *c = r->chunks;
  while (c) {
    RegionChunk *nxt = c->next;
    if (c->size == REGION_CHUNK_SIZE && t_free_count < MAX_POOLED_CHUNKS) {
      c->next = t_free_chunks;
      t_free_chunks = c;
      t_free_count++;
    } else {
#ifdef _WIN32
      std::free(c->base);
#else
      ::munmap(c->base, c->size);
#endif
      std::free(c);
    }
    c = nxt;
  }
  r->chunks = nullptr;
}

// Bump `size+header` from the active region, chaining a chunk if needed. Writes the negative sentinel
// refcount + the length; payload of an mmap chunk is zero-filled by the kernel and never reused across a
// live region, so no memset is needed (matches write_header_nozero on the default arena).
extern "C" long long nova_bytes_alloc(long long size);   // fwd for diagnostic fallback
static long long region_alloc(Region *r, long long size) {
  if (r->magic != REGION_MAGIC || r->freed) {   // DIAGNOSTIC: stale region use -> log once, don't crash
    long long n = g_region_stale_hits.fetch_add(1, std::memory_order_relaxed);
    if (n < 12)
      std::fprintf(stderr, "*** STALE REGION USE #%lld: region=%p magic=%x freed=%d (falling back)\n",
                   n + 1, (void *)r, r->magic, (int)r->freed);
    Region *saved = t_region;
    t_region = nullptr;
    long long p = nova_bytes_alloc(size);   // allocate from the default arena instead of the freed region
    t_region = saved;
    return p;
  }
  size_t need = arena_align((size_t)size + NOVA_OBJ_HEADER_SIZE);
  RegionChunk *c = r->chunks;
  if (!c || c->cur + need > c->end) {
    RegionChunk *nc = region_chunk_new(need);
    if (!nc) return 0;
    nc->next = r->chunks;   // new chunk becomes the active head
    r->chunks = nc;
    c = nc;
  }
  char *base = c->cur;
  c->cur = base + need;
  *reinterpret_cast<int32_t *>(base) = REGION_RC;
  *reinterpret_cast<int32_t *>(base + 4) = (int32_t)size;
  return (long long)(base + NOVA_OBJ_HEADER_SIZE);
}

extern "C" {

// Region control (void* handles for clean cross-TU use by concurrency.cpp's coroutine machinery).
void *nova_region_current(void) { return (void *)t_region; }
void nova_region_set(void *r) { t_region = (Region *)r; }
void *nova_region_new(void) {
  Region *r;
  if (t_region_pool) {                       // reuse a pooled Region struct (chunks field links the pool)
    r = t_region_pool;
    t_region_pool = r->pool_next;
    t_region_pool_count--;
  } else {
    r = (Region *)std::malloc(sizeof(Region));
    if (!r) return nullptr;
  }
  r->chunks = nullptr;
  r->magic = REGION_MAGIC;
  r->freed = false;
  r->gen = g_region_gen_ctr.fetch_add(1, std::memory_order_relaxed);   // fresh, unique generation
  return (void *)r;
}
// Current generation of a region (0 if it has been freed). A binding stores the generation it captured;
// concurrency.cpp validates region->gen against it on every resume so a stale or reused struct is rejected.
unsigned long long nova_region_gen(void *rr) { return rr ? ((Region *)rr)->gen : 0ULL; }
// Reclaim a region: recycle its chunks to the chunk pool, then return the Region STRUCT to a bounded pool.
// The struct is NEVER std::free'd within the cap -- doing so was the crash (a coroutine's stale binding
// dereferenced the freed struct). Pooled structs stay valid memory; a rare stale binding aliases a live
// pooled struct, and the permanent magic/freed guard in region_alloc still routes any freed region's
// allocation to the default arena rather than faulting.
void nova_region_reset(void *rr) { if (rr) { Region *r = (Region *)rr; region_recycle_chunks(r); r->freed = true; } }
void nova_region_free(void *rr) {
  if (!rr) return;
  Region *r = (Region *)rr;
  region_recycle_chunks(r);
  r->freed = true;
  r->magic = 0;
  r->gen = 0;   // invalidate: any binding holding the old generation now fails validation
  if (t_region_pool_count < MAX_POOLED_REGIONS) {
    r->pool_next = t_region_pool;   // link into the struct pool
    t_region_pool = r;
    t_region_pool_count++;
  }
  // else: leak this struct (bounded event) rather than std::free -- a stale binding must never hit free memory.
}

long long nova_bytes_alloc(long long size) {
  if (size < 0)
    size = 0;
  // Per-request region: when a region is active (a synchronous region-scope, mem/region.runStr), bump-
  // allocate there (stamped with the REGION_RC sentinel so ARC leaves it alone); the whole region is
  // reclaimed in O(1) at scope end. No region active -> the default arena / malloc path below, unchanged.
  if (t_region) {
    return region_alloc(t_region, size);
  }
#ifdef NOVA_DROP_ARENA

  {
    char *ptr = (char *)std::malloc((size_t)size + NOVA_OBJ_HEADER_SIZE);
    if (!ptr)
      return 0;
    write_header(ptr, size);
    audit_alloc(ptr, size, __builtin_return_address(0));
    return (long long)(ptr + NOVA_OBJ_HEADER_SIZE);
  }
#endif
  if (!t_arena_start) {
    t_arena_start = arena_page_alloc(FALLBACK_ARENA_SIZE);
    t_arena_current = t_arena_start;
  }
  size_t alloc_size = arena_align((size_t)size + NOVA_OBJ_HEADER_SIZE);
  char *curr = t_arena_current;
  if (!t_arena_start ||
      curr + alloc_size > t_arena_start + FALLBACK_ARENA_SIZE) {

    char *ptr = (char *)std::malloc((size_t)size + NOVA_OBJ_HEADER_SIZE);
    if (!ptr)
      return 0;
    write_header(ptr, size);
    return (long long)(ptr + NOVA_OBJ_HEADER_SIZE);
  }
  write_header_nozero(curr, size);   // arena pages are mmap-zero already; skip the redundant memset
  t_arena_current = curr + alloc_size;
  return (long long)(curr + NOVA_OBJ_HEADER_SIZE);
}

// Same allocation as nova_bytes_alloc, but returns a real pointer so codegen keeps pointer provenance
// for fixed arrays (perf: lets LLVM disambiguate arrays and vectorize/hoist array loops). See
// docs/design/perf-ceiling.md.
extern "C" void *nova_array_alloc(long long size) {
  return (void *)nova_bytes_alloc(size);
}

// --- Request-scoped region (arena mark / reset) -------------------------------
// Return the current bump position. Save it before a request, pass it to nova_arena_reset after, and the
// whole request's arena allocations are reclaimed in O(1) (no per-object free/ARC/memset). ONLY safe when
// nothing allocated after the mark outlives the reset -- escaping objects (persistent state) must use the
// malloc path (nova_bytes_alloc_persistent). This is a measurement prototype for region allocation.
extern "C" long long nova_arena_mark() {
  return (long long)t_arena_current;
}
extern "C" void nova_arena_reset(long long mark) {
  char *m = (char *)mark;
  // Only rewind within the live arena; ignore a mark taken before the arena existed or after an overflow
  // fell back to malloc (those objects are freed by ARC as usual).
  if (t_arena_start && m >= t_arena_start && m <= t_arena_current) {
    t_arena_current = m;
  }
}

extern "C" void nova_release(long long ptr_val, void (*destructor)(long long));

extern "C" long long nova_any_box(long long payload, long long dtor) {
  long long box = nova_bytes_alloc(16);
  if (box == 0) return 0;
  ((long long *)box)[0] = payload;
  ((long long *)box)[1] = dtor;
  return box;
}

extern "C" long long nova_any_unbox(long long box) {
  if (box == 0) return 0;
  return ((long long *)box)[0];
}

extern "C" void nova_any_box_dtor(long long box) {
  if (box == 0) return;
  long long payload = ((long long *)box)[0];
  long long dtor = ((long long *)box)[1];
  if (dtor != 0)
    nova_release(payload, (void (*)(long long))dtor);
}

extern "C" long long nova_valopt_box(long long value) {
  long long box = nova_bytes_alloc(8);
  if (box == 0) return 0;
  *(long long *)box = value;
  return box;
}

extern "C" long long nova_valopt_unbox(long long box) {
  if (box == 0) return 0;
  return *(long long *)box;
}

// A new coroutine inherits the region active at its creation (so a request's nested async calls -- the DB
// query, its framing coroutines -- allocate into the SAME per-request region as the serve coroutine).
// nova_coro_region_track / _untrack live in concurrency.cpp (they own the coro->region map); when no region
// is active anywhere they are near-free (a single flag check).
extern "C" void nova_coro_region_track(long long frame);
extern "C" void nova_coro_region_untrack(long long frame);

long long nova_coro_alloc(long long size) {
  if (size < 0)
    size = 0;
  long long frame = (long long)std::malloc((size_t)size);
  if (frame) nova_coro_region_track(frame);
  return frame;
}

void nova_coro_free(long long frame) {
  if (frame) {
    nova_coro_region_untrack(frame);
    std::free((void *)frame);
  }
}

long long nova_bytes_alloc_persistent(long long size) {
  if (size < 0)
    size = 0;
  char *ptr = (char *)std::malloc((size_t)size + NOVA_OBJ_HEADER_SIZE);
  if (!ptr)
    return 0;
  write_header(ptr, size);
  audit_alloc(ptr, size, __builtin_return_address(0));
  return (long long)(ptr + NOVA_OBJ_HEADER_SIZE);
}

// Copy a string/byte object to the PERSISTENT (malloc) heap, returning a fresh normal ARC object. Used to
// lift a value out of a per-request region before caching it in longer-lived state (e.g. a driver's
// prepared-statement cache): the region is reclaimed on request completion, so anything that outlives the
// request must be persisted first. A null/empty input yields "".
extern "C" long long nova_bytes_persist(long long s) {
  if (!s) return 0;
  // Only region- or literal-backed objects (negative refcount) need copying out; a value already on the
  // normal malloc heap (positive refcount) is returned as-is, so persisting a StringBuilder.toString()
  // result -- the common region-scope return value -- is free (no redundant 190KB copy).
  const int32_t rc = *reinterpret_cast<const int32_t *>((const char *)s - NOVA_OBJ_HEADER_SIZE);
  if (rc >= 0) return s;
  int32_t len = *reinterpret_cast<const int32_t *>((const char *)s - 4);
  if (len <= 0) return nova_bytes_alloc_persistent(0);
  long long out = nova_bytes_alloc_persistent((long long)len);
  if (!out) return 0;
  std::memcpy((void *)out, (const void *)s, (size_t)len);
  return out;
}

// Persistent (malloc-backed) allocation that does NOT zero the payload. ONLY for callers that fill the
// buffer completely before reading it (StringBuilder's buffer and toString result). malloc memory is not
// zero, so this is unsafe for anything that reads uninitialised bytes -- do not wire it in generally.
extern "C" long long nova_bytes_alloc_persistent_nz(long long size) {
  if (size < 0)
    size = 0;
  char *ptr = (char *)std::malloc((size_t)size + NOVA_OBJ_HEADER_SIZE);
  if (!ptr)
    return 0;
  write_header_nozero(ptr, size);
  audit_alloc(ptr, size, __builtin_return_address(0));
  return (long long)(ptr + NOVA_OBJ_HEADER_SIZE);
}

void nova_bytes_free(long long ptr_val) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return;
  // Region objects (and immortal literals) carry a negative refcount; they are never individually freed --
  // a region is reclaimed wholesale on request completion. Guard before std::free so a stray bytes.free on
  // a region-allocated buffer (e.g. StringBuilder over an arena buffer) can't hand a chunk pointer to malloc.
  if (*reinterpret_cast<const int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE) < 0)
    return;
  audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
  std::free(ptr - NOVA_OBJ_HEADER_SIZE);
}

// Bulk byte copy: memcpy `len` bytes from absolute address `src` to absolute address `dst`. Backs the
// `bytes.copy` intrinsic so hot paths (StringBuilder append/toString/grow, buffer assembly) copy at
// memcpy speed instead of a per-byte Nova loop, which was the response-render throughput ceiling. dst/src
// are raw addresses the caller has already offset; memmove is used so overlapping ranges are safe.
extern "C" void nova_bytes_copy(long long dst, long long src, long long len) {
  if (!dst || !src || len <= 0)
    return;
  std::memmove((void *)dst, (void *)src, (size_t)len);
}

// M-4 (memory-management-refinements.md): single-thread fast path for ARC.
//
// The default web runtime is single-reactor-per-process; request-scoped objects live and die on one
// OS thread, so paying an atomic read-modify-write (plus an ACQ_REL barrier on every release) is pure
// waste. `g_arc_multithreaded` starts false and flips to true exactly once, just BEFORE any second OS
// thread is created (see nova_arc_go_multithreaded call sites: nova_run_reactors and the debug
// watchdog). Thread creation is a happens-before edge: every non-atomic op done while the flag was
// false completed before the new thread started, and every op after the flip is atomic. It never flips
// back. So a false reading is only ever observed while genuinely single-threaded, and the plain
// integer arithmetic below is race-free. This shaves most of the ARC cost on the hot single-threaded
// path without changing any observable semantics.
static std::atomic<bool> g_arc_multithreaded{false};

extern "C" void nova_arc_go_multithreaded(void) {
  g_arc_multithreaded.store(true, std::memory_order_release);
}

extern "C" bool nova_arc_is_multithreaded(void) {
  return g_arc_multithreaded.load(std::memory_order_acquire);
}

void nova_retain(long long ptr_val) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return;
  int32_t *rc = reinterpret_cast<int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE);
  if (!g_arc_multithreaded.load(std::memory_order_acquire)) {
    if (*rc < 0)
      return;
    *rc += 1;
    return;
  }
  if (__atomic_load_n(rc, __ATOMIC_RELAXED) < 0)
    return;
  __atomic_fetch_add(rc, 1, __ATOMIC_RELAXED);
}

void nova_release(long long ptr_val, void (*destructor)(long long)) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return;
  check_release_of_dead(ptr);
  int32_t *rc = reinterpret_cast<int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE);
  if (!g_arc_multithreaded.load(std::memory_order_acquire)) {
    if (*rc < 0)
      return;
    *rc -= 1;
    if (*rc == 0) {
      *rc = -999;
      if (destructor)
        destructor(ptr_val);
      audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
      std::free(ptr - NOVA_OBJ_HEADER_SIZE);
    }
    return;
  }
  if (__atomic_load_n(rc, __ATOMIC_ACQUIRE) < 0)
    return;
  if (__atomic_fetch_sub(rc, 1, __ATOMIC_ACQ_REL) == 1) {
    __atomic_store_n(rc, -999, __ATOMIC_RELAXED);
    if (destructor)
      destructor(ptr_val);
    audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
    std::free(ptr - NOVA_OBJ_HEADER_SIZE);
  }
}

void nova_arc_dump_survivors(void);

long long nova_arc_audit_report(void) {
  if (!audit_enabled())
    return 0;
  const long long live = g_audit_live.load(std::memory_order_acquire);
  const long long bytes = g_audit_bytes.load(std::memory_order_acquire);
  if (live <= 0) {
    std::fprintf(stderr, "\nARC audit: clean — every object released.\n");
    return 0;
  }
  std::fprintf(stderr,
               "\nARC AUDIT FAILED: %lld object(s) still live at exit (%lld "
               "bytes leaked)\n",
               live, bytes);
  nova_arc_dump_survivors();
  return live;
}

void nova_arc_dump_survivors(void) {
  if (!dump_enabled())
    return;
  live_lock();
  std::fprintf(stderr, "\n--- ARC survivors (NOVA_ARC_DUMP) ---\n");

  bool *seen = (bool *)std::calloc(g_live_n, sizeof(bool));
  if (!seen) {
    live_unlock();
    return;
  }
  size_t clusters = 0;
  for (size_t i = 0; i < g_live_n; i++) {
    if (seen[i])
      continue;
    long long count = 1;
    for (size_t j = i + 1; j < g_live_n; j++) {
      if (seen[j] || g_live[j].size != g_live[i].size)
        continue;
      if (std::memcmp(g_live[i].base + NOVA_OBJ_HEADER_SIZE,
                      g_live[j].base + NOVA_OBJ_HEADER_SIZE,
                      (size_t)g_live[i].size) != 0)
        continue;
      seen[j] = true;
      count++;
    }

    char buf[49];
    size_t n = (size_t)g_live[i].size;
    if (n > 16)
      n = 16;
    const unsigned char *p =
        (const unsigned char *)(g_live[i].base + NOVA_OBJ_HEADER_SIZE);
    bool printable = n > 0;
    for (size_t k = 0; k < n; k++)
      if (p[k] < 32 || p[k] > 126)
        printable = false;

    const int32_t rc = *reinterpret_cast<const int32_t *>(g_live[i].base);

    const char *site_name = "?";
#ifndef _WIN32
    Dl_info dli;
    if (g_live[i].site && dladdr(g_live[i].site, &dli) && dli.dli_sname)
      site_name = dli.dli_sname;
#endif
    if (printable) {
      std::memcpy(buf, p, n);
      buf[n] = '\0';
      std::fprintf(stderr, "  x%-5lld  size=%-5lld  rc=%-3d  \"%s\"   @ %s\n", count,
                   g_live[i].size, rc, buf, site_name);
    } else {
      size_t w = 0;
      for (size_t k = 0; k < n && w + 3 < sizeof(buf); k++)
        w += (size_t)std::snprintf(buf + w, sizeof(buf) - w, "%02x ", p[k]);
      buf[w] = '\0';
      std::fprintf(stderr, "  x%-5lld  size=%-5lld  rc=%-3d  [%s]   @ %s\n", count,
                   g_live[i].size, rc, buf, site_name);
    }
    clusters++;
    if (clusters >= 25) {
      std::fprintf(stderr, "  ... (25 clusters shown)\n");
      break;
    }
  }
  std::free(seen);
  std::fprintf(stderr, "--- end (%zu live) ---\n", g_live_n);
  live_unlock();
}

}
