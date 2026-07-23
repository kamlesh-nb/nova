// runtime_str.h — Nova string <-> C string helpers, shared across runtime TUs.
//
// CANONICAL Nova string layout (the one ARC and codegen agree on): the string
// pointer `s` is a `nova_bytes_alloc` PAYLOAD — chars live at s[0..len], the length
// is the allocation header's size field at (s - 4), and the refcount is at (s - 8).
// There is NO separate length prefix inside the payload.
#ifndef NOVA_RUNTIME_STR_H
#define NOVA_RUNTIME_STR_H
#include "nova_abi.h"
#include <cstdlib>
#include <cstring>

static inline char *nova_to_cstr(const char *s) {
  if (!s)
    return nullptr;
  int len = *reinterpret_cast<const int *>(s - 4);
  if (len < 0 || len > 1024 * 1024)
    return const_cast<char *>(s); // fallback: treat as C string
  char *out = (char *)std::malloc(len + 1);
  if (out) {
    std::memcpy(out, s, len);
    out[len] = '\0';
  }
  return out;
}
static inline void nova_free_cstr(const char *nova_str, char *c) {
  if (c && c != nova_str)
    std::free(c);
}

// nova_from_bytes — the BINARY-SAFE, ARC-correct string constructor. Copies exactly
// `len` raw bytes (embedded NUL and all — no strlen), writing the CANONICAL layout so
// the refcount lands at s-8 and the length at s-4. This is the one every binary path
// (crypto digests, random bytes, wire buffers) must use.
static inline const char *nova_from_bytes(const char *src, long long len) {
  if (len < 0)
    len = 0;
  char *p = (char *)nova_bytes_alloc(len); // header set: rc=1, size=len
  if (!p)
    return nullptr;
  if (src && len > 0)
    std::memcpy(p, src, (size_t)len);
  return p;
}

// nova_from_cstr — a NUL-terminated C string as a Nova string. Delegates to
// nova_from_bytes with strlen. (Historically this wrote a redundant length prefix and
// returned payload+4, which slid the refcount onto the size field — every string it
// made was ARC-broken; canonical layout fixes it and drops the wasted 4 bytes.)
static inline const char *nova_from_cstr(const char *c) {
  if (!c)
    return nullptr;
  return nova_from_bytes(c, (long long)std::strlen(c));
}
#endif // NOVA_RUNTIME_STR_H
