// compress.cpp — W7 gzip compression over the already-linked zlib.
//
// zlib (`-lz`) is present in every Nova link (LLVM references it; we add `-lz` explicitly for programs
// that don't pull LLVM). `<zlib.h>` ships in both SDKs. These are a THIN wrapper — no new dependency.
//
// ABI: input is a Nova string (binary-safe; length from the ARC header via nova_str_len). Output is a
// length-prefixed binary buffer built with nova_from_bytes (gzip output contains NULs, so it is NOT a
// NUL-terminated C string — same convention as nova_sha256_raw). Both directions use the gzip wrapper
// (window bits 15+16). Returns an empty buffer on error, never a dangling/garbage pointer.
#include "nova_abi.h"
#include "runtime_str.h"
#include <zlib.h>
#include <cstdlib>
#include <cstring>

// `nova_str_len` (the Nova-string length from the ARC header) is defined inline in io.cpp, which is
// included before this file in the unity build — no forward declaration (it is already in scope, and
// declaring it here collides with the existing signature).

extern "C" {

char *nova_gzip_compress(const char *input) {
  long long ilen = input ? nova_str_len(input) : 0;
  if (ilen < 0) ilen = 0;
  z_stream zs;
  std::memset(&zs, 0, sizeof(zs));
  if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    return const_cast<char *>(nova_from_bytes("", 0));
  uLong bound = deflateBound(&zs, (uLong)ilen);
  char *out = (char *)std::malloc(bound ? bound : 1);
  if (!out) {
    deflateEnd(&zs);
    return const_cast<char *>(nova_from_bytes("", 0));
  }
  zs.next_in = (Bytef *)(input ? input : "");
  zs.avail_in = (uInt)ilen;
  zs.next_out = (Bytef *)out;
  zs.avail_out = (uInt)bound;
  int rc = deflate(&zs, Z_FINISH);
  long long olen = (long long)(bound - zs.avail_out);
  deflateEnd(&zs);
  const char *res = (rc == Z_STREAM_END) ? nova_from_bytes(out, olen) : nova_from_bytes("", 0);
  std::free(out);
  return const_cast<char *>(res);
}

char *nova_gzip_decompress(const char *input) {
  long long ilen = input ? nova_str_len(input) : 0;
  if (ilen <= 0) return const_cast<char *>(nova_from_bytes("", 0));
  z_stream zs;
  std::memset(&zs, 0, sizeof(zs));
  if (inflateInit2(&zs, 15 + 16) != Z_OK) // gzip
    return const_cast<char *>(nova_from_bytes("", 0));
  zs.next_in = (Bytef *)input;
  zs.avail_in = (uInt)ilen;

  size_t cap = (size_t)ilen * 4 + 64;
  char *out = (char *)std::malloc(cap);
  if (!out) {
    inflateEnd(&zs);
    return const_cast<char *>(nova_from_bytes("", 0));
  }
  size_t have = 0;
  int rc = Z_OK;
  while (true) {
    if (have == cap) { // grow
      size_t ncap = cap * 2;
      char *nout = (char *)std::realloc(out, ncap);
      if (!nout) { rc = Z_MEM_ERROR; break; }
      out = nout;
      cap = ncap;
    }
    zs.next_out = (Bytef *)(out + have);
    zs.avail_out = (uInt)(cap - have);
    rc = inflate(&zs, Z_NO_FLUSH);
    have = cap - zs.avail_out;
    if (rc == Z_STREAM_END) break;
    if (rc != Z_OK) break; // Z_BUF_ERROR with avail_in==0 also lands here → treated as error/empty
  }
  inflateEnd(&zs);
  const char *res = (rc == Z_STREAM_END) ? nova_from_bytes(out, (long long)have) : nova_from_bytes("", 0);
  std::free(out);
  return const_cast<char *>(res);
}

} // extern "C"
