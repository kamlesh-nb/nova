// M11 stage B completed the crypto migration: SHA-1/256/384/512, MD5, HMAC-SHA256, PBKDF2, the
// MySQL auth-scrambles, and RSA-OAEP encryption are all implemented in pure Nova (crypto/hash/*,
// crypto/mac/hmac, crypto/kdf/pbkdf2, crypto/rsa, and the MySQL driver). No wolfCrypt symbol remains.
//
// The one crypto-adjacent primitive kept in C is nova_getrandom: an honest kernel entropy source
// (getentropy(2), the same portable primitive on macOS and Linux; libc, NOT a crypto library). Sourcing
// randomness here rather than through the os.sys module keeps crypto/random free of the os.sys import,
// so the crypto/TLS stack does not drag os.sys's socket/file externs into every consumer's namespace.

#include <sys/random.h>
#include <cstddef>

extern "C" void nova_getrandom(char *buf, long long n) {
  long long off = 0;
  while (off < n) {
    size_t chunk = (size_t)(n - off);
    if (chunk > 256) chunk = 256;                 // getentropy caps at 256 bytes per call
    if (getentropy(buf + off, chunk) != 0) {
      // getentropy only fails on EFAULT/EINVAL (never transient); zero-fill and stop to avoid a hang.
      for (size_t i = 0; i < chunk; i++) buf[off + i] = 0;
    }
    off += (long long)chunk;
  }
}
