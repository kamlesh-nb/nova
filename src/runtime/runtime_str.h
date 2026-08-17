
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
    return const_cast<char *>(s);
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

static inline const char *nova_from_bytes(const char *src, long long len) {
  if (len < 0)
    len = 0;
  // Allocate one extra byte for a NUL terminator so the debugger's built-in char* view (and C-FFI) can
  // read the string without Python formatters. The ARC header length stays the LOGICAL length -- we
  // over-allocate by one, then rewrite the length field, which nova_bytes_alloc set to len+1.
  char *p = (char *)nova_bytes_alloc(len + 1);
  if (!p)
    return nullptr;
  if (src && len > 0)
    std::memcpy(p, src, (size_t)len);
  p[len] = '\0';
  *reinterpret_cast<int *>(p - 4) = (int)len;
  return p;
}

static inline const char *nova_from_cstr(const char *c) {
  if (!c)
    return nullptr;
  return nova_from_bytes(c, (long long)std::strlen(c));
}
#endif
