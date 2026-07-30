// M11 stage B completed the crypto migration: SHA-1/256/384/512, MD5, HMAC-SHA256, PBKDF2, the
// MySQL auth-scrambles, and RSA-OAEP encryption are all implemented in pure Nova (crypto/hash/*,
// crypto/mac/hmac, crypto/kdf/pbkdf2, crypto/rsa, and the MySQL driver). No wolfCrypt symbol remains.
//
// The one crypto-adjacent primitive kept in C is nova_getrandom: an honest kernel entropy source
// (getentropy(2), the same portable primitive on macOS and Linux; libc, NOT a crypto library). Sourcing
// randomness here rather than through the os.sys module keeps crypto/random free of the os.sys import,
// so the crypto/TLS stack does not drag os.sys's socket/file externs into every consumer's namespace.

#include <cstddef>

#ifdef _WIN32
// Windows: BCryptGenRandom with the system-preferred RNG is the CSPRNG (mingw-w64 provides bcrypt.h;
// links -lbcrypt). BCRYPT_USE_SYSTEM_PREFERRED_RNG lets the algorithm handle be NULL.
#include <windows.h>
#include <bcrypt.h>
extern "C" void nova_getrandom(char *buf, long long n) {
  if (BCryptGenRandom(NULL, (PUCHAR)buf, (ULONG)n, 0x00000002 /*BCRYPT_USE_SYSTEM_PREFERRED_RNG*/) != 0) {
    for (long long i = 0; i < n; i++) buf[i] = 0;   // fail closed to zeros rather than hang
  }
}
#else
#include <sys/random.h>
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
#endif
