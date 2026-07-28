
#include "nova_abi.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#ifndef _WIN32
#include <dlfcn.h>
#endif

namespace {

constexpr size_t FALLBACK_ARENA_SIZE = 32 * 1024 * 1024;
inline size_t arena_align(size_t s) { return (s + 7) & ~size_t(7); }

thread_local char *t_arena_start = nullptr;
thread_local char *t_arena_current = nullptr;

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

}

extern "C" {

long long nova_bytes_alloc(long long size) {
  if (size < 0)
    size = 0;
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
    t_arena_start = (char *)std::malloc(FALLBACK_ARENA_SIZE);
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
  write_header(curr, size);
  t_arena_current = curr + alloc_size;
  return (long long)(curr + NOVA_OBJ_HEADER_SIZE);
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
    return;
  audit_free(ptr - NOVA_OBJ_HEADER_SIZE, audit_size_of(ptr - NOVA_OBJ_HEADER_SIZE));
  std::free(ptr - NOVA_OBJ_HEADER_SIZE);
}

void nova_retain(long long ptr_val) {
  if (!ptr_val)
    return;
  char *ptr = (char *)ptr_val;
  if (is_in_arena(ptr))
    return;
  int32_t *rc = reinterpret_cast<int32_t *>(ptr - NOVA_OBJ_HEADER_SIZE);
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
