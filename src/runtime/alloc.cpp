// alloc.cpp — Nova ARC allocator (C++20 runtime).
//
// Faithfully reproduces the old C runtime's model (discards/runtime-c-20260713/
// allocator.c), because it is LOAD-BEARING, not just an optimization:
//
//   * `nova_bytes_alloc` bump-allocates from a per-thread 32MB fallback arena.
//     Arena objects are REFCOUNT-EXEMPT (retain/release/free are no-ops for
//     them) — the stdlib relies on this: string.nova builds a string as
//     `bytes.alloc(4+len)` and returns `ptr+4`, so a string's bytes do not line
//     up with the 8-byte ARC header; exemption is what makes that safe.
//   * On arena overflow, and for `nova_bytes_alloc_persistent`, objects are
//     malloc'd and honestly reference-counted (header aligns, used directly).
//
// Heap-object header (see nova_abi.h): int32 refcount @-8, int32 length @-4,
// payload @0. Refcount < 0 is a freed/exempt sentinel.
#include "nova_abi.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#ifndef _WIN32
#include <dlfcn.h> // NOVA_ARC_DUMP: dladdr, to name a survivor's allocation site (POSIX only)
#endif

namespace {

constexpr size_t FALLBACK_ARENA_SIZE = 32 * 1024 * 1024; // 32MB
inline size_t arena_align(size_t s) { return (s + 7) & ~size_t(7); }

// Per-thread bump arena. Objects here are refcount-exempt.
thread_local char *t_arena_start = nullptr;
thread_local char *t_arena_current = nullptr;

inline bool is_in_arena(const char *ptr) {
  return t_arena_start && ptr >= t_arena_start &&
         ptr < t_arena_start + FALLBACK_ARENA_SIZE;
}

// ===== ARC audit (F5 §3.5.1) ===============================================
//
// "A leak becomes a test failure, not a 900MB RSS reading."
//
// Lands BEFORE any ARC fix on purpose (F5 §5 stage 1): otherwise "fixed" is an
// opinion. A dose-response RSS curve distinguishes a leak from a high-water mark,
// but it cannot fail a test.
//
// Two atomic counters, NOT a map of live pointers. The map version linked against
// std::unordered_map and failed with an undefined `std::__1::__hash_memory` — a
// libc++ mismatch between how the runtime compiles and how the test binary links.
// Counters need no libc++, no lock, and answer the question the stage actually
// asks: did everything get released?
//
// ⚠️ The tradeoff, recorded: §3.5.1 wants survivors reported BY ALLOCATION SITE.
// Counters say how many and how many bytes, not which. That is enough to FAIL a
// test — which is this stage's whole point — and not enough to debug one. Per-site
// attribution needs the pointer map (and a libc++ that links), and is deferred
// rather than pretended.
//
// Arena objects are refcount-exempt (is_in_arena) and deliberately untracked: they
// are bulk-freed, so counting them would report the arena itself as a leak. The
// runtime is built -DNOVA_DROP_ARENA, so in practice every object is honest.
inline bool audit_enabled() {
  static const bool on = std::getenv("NOVA_ARC_AUDIT") != nullptr;
  return on;
}

std::atomic<long long> g_audit_live{0};
std::atomic<long long> g_audit_bytes{0};

// ===== survivor ATTRIBUTION (NOVA_ARC_DUMP=1) ==============================
//
// The note above defers "which objects survived" because the map version linked
// against std::unordered_map and died on `std::__1::__hash_memory`. That deferral
// cost real time: `14_collections_map` leaks 1898 objects and a COUNT cannot say
// what they are, so the next move was a guess. This is the un-deferral, and it
// keeps the constraint that killed the last attempt: NO libc++ containers.
//
// A flat malloc'd array with linear removal — not a hash map. The LIVE set is what
// gets scanned, and a leak worth debugging has a small live set (1898 here), so
// O(live) per free is nothing next to being able to see the survivors. It costs
// nothing when off, and the counters above stay exactly as they were.
inline bool dump_enabled() {
  static const bool on = std::getenv("NOVA_ARC_DUMP") != nullptr;
  return on;
}

struct LiveEntry {
  const char *base; // the header, not the payload
  long long size;
  const void *site; // NOVA_ARC_DUMP: the caller of the alloc (dladdr'd to a fn name)
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
    // plain realloc: this table must never allocate through the tracked path
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

/// Is this object currently live? The registry is ground truth, and it is what makes
/// a double release VISIBLE.
///
/// `nova_release` on an already-freed object usually returns early on the -999
/// sentinel and looks harmless. It is not: once malloc REUSES that block, the stale
/// release decrements a DIFFERENT object's refcount and frees it early. That is why a
/// double release presents as an intermittent crash somewhere else entirely — the
/// symptom's location depends on the allocator, not on the bug. Checking the registry
/// catches it at the release, before the corruption.
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

// A ring of RECENTLY FREED objects, with a snapshot of what they held.
//
// "Double release at 0x1006e8520" names an address, and an address is not a finding.
// The object is gone by then, so its identity has to be captured at the free — then a
// dead release can say WHAT was released twice ("the string \"Nova\"", "a 24-byte
// List"), which is the difference between a bug report and a bug fix.
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
  // A STRING LITERAL is not a leak and not a double free. It is emitted as a global
  // `{i32 refcount, i32 len, [N x i8]}` with refcount = 100000000 (declarations.zig)
  // — a "never free me" sentinel with 100M of headroom, so releasing one merely
  // decrements it and is harmless. It is untracked because it was never malloc'd.
  // Without this, literals drown the report: `?? ""` releases one per call.
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
  for (size_t i = g_live_n; i-- > 0;) { // backwards: frees skew recent
    if (g_live[i].base == base) {
      dead_ring_record(base, g_live[i].size); // snapshot before it is gone
      g_live[i] = g_live[g_live_n - 1]; // swap-remove; order is not meaningful
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

/// The recorded size of a live object, read from its 8-byte header.
inline long long audit_size_of(const char *base) {
  return (long long)*reinterpret_cast<const int32_t *>(base + 4);
}

inline void write_header(char *base, long long size) {
  *reinterpret_cast<int32_t *>(base) = 1;                 // refcount
  *reinterpret_cast<int32_t *>(base + 4) = (int32_t)size; // length
  std::memset(base + NOVA_OBJ_HEADER_SIZE, 0, (size_t)size);
}

} // namespace

extern "C" {

long long nova_bytes_alloc(long long size) {
  if (size < 0)
    size = 0;
#ifdef NOVA_DROP_ARENA
  // Workstream A experiment: bypass the arena entirely — every object is a real
  // malloc'd, honestly reference-counted heap object (is_in_arena → false → ARC
  // active). Reveals latent retain/release imbalances the arena used to hide.
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
    t_arena_start = (char *)std::malloc(FALLBACK_ARENA_SIZE);
    t_arena_current = t_arena_start;
  }
  size_t alloc_size = arena_align((size_t)size + NOVA_OBJ_HEADER_SIZE);
  char *curr = t_arena_current;
  if (!t_arena_start ||
      curr + alloc_size > t_arena_start + FALLBACK_ARENA_SIZE) {
    // Arena exhausted (or unavailable) → malloc a refcounted object.
    char *ptr = (char *)std::malloc((size_t)size + NOVA_OBJ_HEADER_SIZE);
    if (!ptr)
      return 0;
    write_header(ptr, size);
    return (long long)(ptr + NOVA_OBJ_HEADER_SIZE);
  }
  write_header(curr, size);
  t_arena_current = curr + alloc_size;
  return (long long)(curr + NOVA_OBJ_HEADER_SIZE);
}

// ===== Boxed `any` (owned dynamic value) ===================================
// `any` is a boxed, owned value so a heap payload parked in a container (e.g.
// `Map<string, any>`) is RETAINED by the container and freed with it — fixing the
// dangling-pointer gap of the old unowned `.ptr` representation. Layout of the box
// (a normal ARC object from nova_bytes_alloc, rc=1, 8-byte header at [ptr-8]):
//     [payload: i64][dtor: i64]
// `payload` is the value word (an int inline, or a pointer to a heap object).
// `dtor` is the payload's destructor fn-pointer (0 for immediates / non-owned
// payloads). When the box is released, nova_any_box_dtor releases the inner value
// via that destructor, then the box's own bytes are freed by the nova_release that
// called it. Boxing MOVES the payload's +1 into the box (no extra retain).
extern "C" void nova_release(long long ptr_val, void (*destructor)(long long));

extern "C" long long nova_any_box(long long payload, long long dtor) {
  long long box = nova_bytes_alloc(16);
  if (box == 0) return 0;
  ((long long *)box)[0] = payload;
  ((long long *)box)[1] = dtor;
  return box;
}

extern "C" long long nova_any_unbox(long long box) {
  if (box == 0) return 0; // an absent/undefined `any` unboxes to 0
  return ((long long *)box)[0];
}

// The box's own destructor (passed to nova_release when the box is freed): release
// the inner value if it carries a destructor, then return — the caller frees the box.
extern "C" void nova_any_box_dtor(long long box) {
  if (box == 0) return;
  long long payload = ((long long *)box)[0];
  long long dtor = ((long long *)box)[1];
  if (dtor != 0)
    nova_release(payload, (void (*)(long long))dtor);
}

// ===== Value-type optionals (V1: boxed presence) ===========================
// A value-type optional (`int | undefined`, `long?`, `float?`, `double?`, `bool?`) is a POINTER to a
// heap cell holding the value, or null (0) for `undefined`. This is Nova's `Nullable<T>` (C#-inspired
// EXPLICIT presence): a stored `0`/`0.0`/`false` becomes a NON-NULL box, so it is distinguishable from
// absent — fixing the value-0-reads-as-undefined soundness bug uniformly across all value widths (a
// sentinel could not: `long`/`double` use all 64 bits). Pointer/`decimal` optionals are already
// heap-null-representable and are UNCHANGED. See docs/design/value-optional-boxing.md.
//
// The box is a plain ARC object (nova_bytes_alloc, rc=1) holding one word; it carries no nested owned
// value, so its destructor is null — releasing it just frees the 8 bytes.
extern "C" long long nova_valopt_box(long long value) {
  long long box = nova_bytes_alloc(8);
  if (box == 0) return 0;
  *(long long *)box = value;
  return box;
}

extern "C" long long nova_valopt_unbox(long long box) {
  if (box == 0) return 0; // null/undefined unboxes to 0; callers null-check FIRST (`?? `/`!= undefined`)
  return *(long long *)box;
}

// ===== Coroutine frame allocation (M3-C) ===================================
// Plain malloc/free — a coroutine frame is opaque LLVM-managed storage, NOT a
// Nova ARC object, so no 8-byte header and no arena. A per-task pool can replace
// this later (workstream D) with no codegen change.
long long nova_coro_alloc(long long size) {
  if (size < 0)
    size = 0;
  return (long long)std::malloc((size_t)size);
}

void nova_coro_free(long long frame) {
  if (frame)
    std::free((void *)frame);
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

void nova_bytes_free(long long ptr_val) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return; // arena: bulk-freed, no-op
  audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
  std::free(ptr - NOVA_OBJ_HEADER_SIZE);
}

void nova_retain(long long ptr_val) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return; // arena: exempt
  int32_t *rc = reinterpret_cast<int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE);
  if (__atomic_load_n(rc, __ATOMIC_RELAXED) < 0)
    return; // freed sentinel
  __atomic_fetch_add(rc, 1, __ATOMIC_RELAXED);
}

void nova_release(long long ptr_val, void (*destructor)(long long)) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return; // arena: exempt
  check_release_of_dead(ptr);
  int32_t *rc = reinterpret_cast<int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE);
  if (__atomic_load_n(rc, __ATOMIC_ACQUIRE) < 0)
    return; // freed sentinel
  if (__atomic_fetch_sub(rc, 1, __ATOMIC_ACQ_REL) == 1) {
    __atomic_store_n(rc, -999, __ATOMIC_RELAXED);
    if (destructor)
      destructor(ptr_val);
    audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
    std::free(ptr - NOVA_OBJ_HEADER_SIZE);
  }
}

void nova_arc_dump_survivors(void); // defined below; the report calls it

// Reports survivors and returns how many. 0 when the audit is off, so a caller can
// unconditionally treat non-zero as a failure.
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

// What the survivors ARE — `NOVA_ARC_DUMP=1`. A count says a leak exists; this says
// what leaked, which is the difference between a finding and a guess.
//
// Clusters by (size, payload preview) with counts, rather than printing 1898 lines.
// That grouping is the same discipline F2 used on its 1792 "divergences", which were
// really 21 clusters and then 9: a number is not a finding until you can see what it
// is made of.
void nova_arc_dump_survivors(void) {
  if (!dump_enabled())
    return;
  live_lock();
  std::fprintf(stderr, "\n--- ARC survivors (NOVA_ARC_DUMP) ---\n");
  // O(n^2) clustering over the LIVE set only. n is a leak's size, not the
  // program's allocation count; at n=1898 this is instant and needs no map.
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
    // Payload preview: printable ASCII identifies a string instantly; anything
    // else falls back to hex, which identifies a Storage slot array just as well.
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
    // The REFCOUNT is the whole diagnosis: rc=1 means nobody released it, rc=2 means
    // someone retained it twice. Printing the count without it just says "a leak".
    const int32_t rc = *reinterpret_cast<const int32_t *>(g_live[i].base);
    // Name the ALLOCATION SITE: dladdr the captured return address to the enclosing
    // compiled function (e.g. `string_slice`, `nova_bytes_alloc_persistent`'s caller).
    // This is §3.5.1's "survivors BY ALLOCATION SITE" — the count says how many, this
    // says WHERE, which is the difference between a finding and a guess.
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

} // extern "C"
