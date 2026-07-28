
#include "nova_abi.h"
#include "runtime_str.h"
#include <zlib.h>
#include <cstdlib>
#include <cstring>

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
  if (inflateInit2(&zs, 15 + 16) != Z_OK)
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
    if (have == cap) {
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
    if (rc != Z_OK) break;
  }
  inflateEnd(&zs);
  const char *res = (rc == Z_STREAM_END) ? nova_from_bytes(out, (long long)have) : nova_from_bytes("", 0);
  std::free(out);
  return const_cast<char *>(res);
}

}
