
#include "nova_abi.h"
#include "runtime_str.h"
#include <cstdio>
#include <cstdlib>

#ifdef NOVA_HAVE_WOLFSSL
#include <wolfssl/options.h>
#include <wolfssl/wolfcrypt/sha.h>
#include <wolfssl/wolfcrypt/sha256.h>
#include <wolfssl/wolfcrypt/sha512.h>
#include <wolfssl/wolfcrypt/md5.h>
#include <wolfssl/wolfcrypt/hmac.h>
#include <wolfssl/wolfcrypt/random.h>
#include <wolfssl/wolfcrypt/pwdbased.h>
#include <wolfssl/wolfcrypt/rsa.h>
#include <wolfssl/wolfcrypt/asn.h>
#include <wolfssl/wolfcrypt/coding.h>
#include <wolfssl/wolfcrypt/aes.h>                 // AES-GCM (M9 record layer)
#include <wolfssl/wolfcrypt/chacha20_poly1305.h>   // ChaCha20-Poly1305 (M9 record layer)
#include <cstring>
#endif

static inline int nova_crypto_slen(const char *s) {
  return s ? *reinterpret_cast<const int *>(s - 4) : 0;
}

extern "C" {

#ifdef NOVA_HAVE_WOLFSSL

static const char *nova_hex(const unsigned char *b, int n) {
  static const char hx[] = "0123456789abcdef";
  char *out = (char *)std::malloc((size_t)n * 2 + 1);
  if (!out)
    return nova_from_bytes("", 0);
  for (int i = 0; i < n; i++) {
    out[i * 2] = hx[(b[i] >> 4) & 0xF];
    out[i * 2 + 1] = hx[b[i] & 0xF];
  }
  const char *s = nova_from_bytes(out, (long long)n * 2);
  std::free(out);
  return s;
}

char *nova_sha256(const char *input) {
  unsigned char h[WC_SHA256_DIGEST_SIZE];
  wc_Sha256 sha;
  wc_InitSha256(&sha);
  wc_Sha256Update(&sha, (const byte *)(input ? input : ""), (word32)nova_crypto_slen(input));
  wc_Sha256Final(&sha, h);
  return const_cast<char *>(nova_hex(h, WC_SHA256_DIGEST_SIZE));
}

char *nova_sha512(const char *input) {
  unsigned char h[WC_SHA512_DIGEST_SIZE];
  wc_Sha512 sha;
  wc_InitSha512(&sha);
  wc_Sha512Update(&sha, (const byte *)(input ? input : ""), (word32)nova_crypto_slen(input));
  wc_Sha512Final(&sha, h);
  return const_cast<char *>(nova_hex(h, WC_SHA512_DIGEST_SIZE));
}

char *nova_sha1(const char *input) {
  unsigned char h[WC_SHA_DIGEST_SIZE];
  wc_Sha sha;
  wc_InitSha(&sha);
  wc_ShaUpdate(&sha, (const byte *)(input ? input : ""), (word32)nova_crypto_slen(input));
  wc_ShaFinal(&sha, h);
  return const_cast<char *>(nova_hex(h, WC_SHA_DIGEST_SIZE));
}

char *nova_mysql_scramble(const char *password, const char *salt, int salt_len) {
  const word32 pwlen = (word32)nova_crypto_slen(password);
  unsigned char stage1[WC_SHA_DIGEST_SIZE];
  unsigned char stage2[WC_SHA_DIGEST_SIZE];
  unsigned char seed[WC_SHA_DIGEST_SIZE];
  wc_Sha sha;

  wc_InitSha(&sha);
  wc_ShaUpdate(&sha, (const byte *)(password ? password : ""), pwlen);
  wc_ShaFinal(&sha, stage1);

  wc_InitSha(&sha);
  wc_ShaUpdate(&sha, stage1, WC_SHA_DIGEST_SIZE);
  wc_ShaFinal(&sha, stage2);

  wc_InitSha(&sha);
  wc_ShaUpdate(&sha, (const byte *)(salt ? salt : ""), (word32)(salt_len > 0 ? salt_len : 0));
  wc_ShaUpdate(&sha, stage2, WC_SHA_DIGEST_SIZE);
  wc_ShaFinal(&sha, seed);

  unsigned char out[WC_SHA_DIGEST_SIZE];
  for (int i = 0; i < WC_SHA_DIGEST_SIZE; i++) out[i] = stage1[i] ^ seed[i];
  return const_cast<char *>(nova_from_bytes((const char *)out, WC_SHA_DIGEST_SIZE));
}

char *nova_mysql_sha2_scramble(const char *password, const char *salt, int salt_len) {
  const word32 pwlen = (word32)nova_crypto_slen(password);
  unsigned char stage1[WC_SHA256_DIGEST_SIZE];
  unsigned char stage2[WC_SHA256_DIGEST_SIZE];
  unsigned char seed[WC_SHA256_DIGEST_SIZE];
  wc_Sha256 sha;

  wc_InitSha256(&sha);
  wc_Sha256Update(&sha, (const byte *)(password ? password : ""), pwlen);
  wc_Sha256Final(&sha, stage1);

  wc_InitSha256(&sha);
  wc_Sha256Update(&sha, stage1, WC_SHA256_DIGEST_SIZE);
  wc_Sha256Final(&sha, stage2);

  wc_InitSha256(&sha);
  wc_Sha256Update(&sha, stage2, WC_SHA256_DIGEST_SIZE);
  wc_Sha256Update(&sha, (const byte *)(salt ? salt : ""), (word32)(salt_len > 0 ? salt_len : 0));
  wc_Sha256Final(&sha, seed);

  unsigned char out[WC_SHA256_DIGEST_SIZE];
  for (int i = 0; i < WC_SHA256_DIGEST_SIZE; i++) out[i] = stage1[i] ^ seed[i];
  return const_cast<char *>(nova_from_bytes((const char *)out, WC_SHA256_DIGEST_SIZE));
}

char *nova_rsa_oaep_encrypt(const char *pem, const char *data, int data_len) {
  if (!pem || !data || data_len <= 0) return const_cast<char *>(nova_from_bytes("", 0));
  const int pem_len = nova_crypto_slen(pem);

  const char *begin = "-----BEGIN PUBLIC KEY-----";
  const char *end = "-----END PUBLIC KEY-----";
  const char *b = (const char *)memmem(pem, (size_t)pem_len, begin, std::strlen(begin));
  if (!b) return const_cast<char *>(nova_from_bytes("", 0));
  b += std::strlen(begin);
  const char *e = (const char *)memmem(b, (size_t)(pem + pem_len - b), end, std::strlen(end));
  if (!e) return const_cast<char *>(nova_from_bytes("", 0));
  unsigned char der[2048];
  word32 der_len = (word32)sizeof(der);
  if (Base64_Decode((const unsigned char *)b, (word32)(e - b), der, &der_len) != 0)
    return const_cast<char *>(nova_from_bytes("", 0));

  RsaKey key;
  if (wc_InitRsaKey(&key, nullptr) != 0) return const_cast<char *>(nova_from_bytes("", 0));
  word32 idx = 0;
  if (wc_RsaPublicKeyDecode(der, &idx, &key, (word32)der_len) != 0) {
    wc_FreeRsaKey(&key);
    return const_cast<char *>(nova_from_bytes("", 0));
  }

  WC_RNG rng;
  if (wc_InitRng(&rng) != 0) { wc_FreeRsaKey(&key); return const_cast<char *>(nova_from_bytes("", 0)); }

  const int out_sz = wc_RsaEncryptSize(&key);
  unsigned char *out = (unsigned char *)std::malloc((size_t)(out_sz > 0 ? out_sz : 1));
  int enc = -1;
  if (out) {
    enc = wc_RsaPublicEncrypt_ex((const unsigned char *)data, (word32)data_len,
                                 out, (word32)out_sz, &key, &rng,
                                 WC_RSA_OAEP_PAD, WC_HASH_TYPE_SHA, WC_MGF1SHA1, nullptr, 0);
  }
  wc_FreeRng(&rng);
  wc_FreeRsaKey(&key);
  if (enc <= 0) { if (out) std::free(out); return const_cast<char *>(nova_from_bytes("", 0)); }
  const char *s = nova_from_bytes((const char *)out, enc);
  std::free(out);
  return const_cast<char *>(s);
}

#ifndef NO_MD5
char *nova_md5(const char *input) {
  unsigned char h[WC_MD5_DIGEST_SIZE];
  wc_Md5 md5;
  wc_InitMd5(&md5);
  wc_Md5Update(&md5, (const byte *)(input ? input : ""), (word32)nova_crypto_slen(input));
  wc_Md5Final(&md5, h);
  return const_cast<char *>(nova_hex(h, WC_MD5_DIGEST_SIZE));
}
#else
char *nova_md5(const char *) {
  std::fprintf(stderr, "nova crypto: md5 is disabled in this wolfSSL build (NO_MD5)\n");
  std::_Exit(1);
  return nullptr;
}
#endif

char *nova_hmac_sha256(const char *key, const char *msg) {
  unsigned char out[WC_SHA256_DIGEST_SIZE];
  Hmac hmac;
  if (wc_HmacInit(&hmac, nullptr, INVALID_DEVID) != 0)
    return const_cast<char *>(nova_from_bytes("", 0));
  wc_HmacSetKey(&hmac, WC_SHA256, (const byte *)(key ? key : ""), (word32)nova_crypto_slen(key));
  wc_HmacUpdate(&hmac, (const byte *)(msg ? msg : ""), (word32)nova_crypto_slen(msg));
  wc_HmacFinal(&hmac, out);
  wc_HmacFree(&hmac);
  return const_cast<char *>(nova_hex(out, WC_SHA256_DIGEST_SIZE));
}

char *nova_hmac_sha256_raw(const char *key, const char *msg) {
  unsigned char out[WC_SHA256_DIGEST_SIZE];
  Hmac hmac;
  if (wc_HmacInit(&hmac, nullptr, INVALID_DEVID) != 0)
    return const_cast<char *>(nova_from_bytes("", 0));
  wc_HmacSetKey(&hmac, WC_SHA256, (const byte *)(key ? key : ""), (word32)nova_crypto_slen(key));
  wc_HmacUpdate(&hmac, (const byte *)(msg ? msg : ""), (word32)nova_crypto_slen(msg));
  wc_HmacFinal(&hmac, out);
  wc_HmacFree(&hmac);
  return const_cast<char *>(nova_from_bytes((const char *)out, WC_SHA256_DIGEST_SIZE));
}

char *nova_sha256_raw(const char *input) {
  unsigned char h[WC_SHA256_DIGEST_SIZE];
  wc_Sha256 sha;
  wc_InitSha256(&sha);
  wc_Sha256Update(&sha, (const byte *)(input ? input : ""), (word32)nova_crypto_slen(input));
  wc_Sha256Final(&sha, h);
  return const_cast<char *>(nova_from_bytes((const char *)h, WC_SHA256_DIGEST_SIZE));
}

char *nova_pbkdf2_hmac_sha256(const char *password, const char *salt, long long iterations, long long dklen) {
  if (dklen <= 0) dklen = WC_SHA256_DIGEST_SIZE;
  if (dklen > 1024) dklen = 1024;
  if (iterations <= 0) iterations = 1;
  unsigned char *out = (unsigned char *)std::malloc((size_t)dklen);
  if (!out) return const_cast<char *>(nova_from_bytes("", 0));
  int rc = wc_PBKDF2(out, (const byte *)(password ? password : ""), nova_crypto_slen(password),
                     (const byte *)(salt ? salt : ""), nova_crypto_slen(salt),
                     (int)iterations, (int)dklen, WC_SHA256);
  if (rc != 0) {
    std::free(out);
    std::fprintf(stderr, "nova crypto: wc_PBKDF2 failed (%d)\n", rc);
    std::_Exit(1);
  }
  const char *s = nova_from_bytes((const char *)out, dklen);
  std::free(out);
  return const_cast<char *>(s);
}

char *nova_random_hex(long long n) {
  if (n <= 0)
    n = 16;
  if (n > 4096)
    n = 4096;
  unsigned char *buf = (unsigned char *)std::malloc((size_t)n);
  if (!buf)
    return const_cast<char *>(nova_from_bytes("", 0));
  WC_RNG rng;
  if (wc_InitRng(&rng) != 0) {
    std::free(buf);
    std::fprintf(stderr, "nova crypto: wc_InitRng failed (no entropy source)\n");
    std::_Exit(1);
  }
  wc_RNG_GenerateBlock(&rng, buf, (word32)n);
  wc_FreeRng(&rng);
  const char *s = nova_hex(buf, (int)n);
  std::free(buf);
  return const_cast<char *>(s);
}

// AEAD primitives for TLS in Nova (M9). These are thin wrappers over vetted wolfCrypt AEAD ciphers;
// the record layer, key schedule, and handshake that drive them are written in Nova. Rule 1: never
// reimplement the primitives. All buffers are raw pointers with explicit lengths (the systems idiom),
// not the length-prefixed Nova string form. Each returns 0 on success and nonzero on failure; the
// open (decrypt) functions return nonzero on authentication failure, which the caller MUST treat as a
// fatal record error (a forged or corrupted record), never as recoverable.


#else

static char *nova_crypto_unavailable(const char *fn) {
  std::fprintf(stderr,
               "nova crypto: %s requires wolfSSL, which was not built into this "
               "runtime (rebuild with the vendored deps/wolfssl).\n",
               fn);
  std::_Exit(1);
  return nullptr;
}
char *nova_sha256(const char *) { return nova_crypto_unavailable("sha256"); }
char *nova_sha512(const char *) { return nova_crypto_unavailable("sha512"); }
char *nova_sha1(const char *) { return nova_crypto_unavailable("sha1"); }
char *nova_mysql_scramble(const char *, const char *, int) { return nova_crypto_unavailable("mysql_scramble"); }
char *nova_mysql_sha2_scramble(const char *, const char *, int) { return nova_crypto_unavailable("mysql_sha2_scramble"); }
char *nova_md5(const char *) { return nova_crypto_unavailable("md5"); }
char *nova_hmac_sha256(const char *, const char *) { return nova_crypto_unavailable("hmac_sha256"); }
char *nova_hmac_sha256_raw(const char *, const char *) { return nova_crypto_unavailable("hmac_sha256_raw"); }
char *nova_sha256_raw(const char *) { return nova_crypto_unavailable("sha256_raw"); }
char *nova_pbkdf2_hmac_sha256(const char *, const char *, long long, long long) { return nova_crypto_unavailable("pbkdf2_hmac_sha256"); }
char *nova_random_hex(long long) { return nova_crypto_unavailable("random"); }
char *nova_rsa_oaep_encrypt(const char *, const char *, int) { return nova_crypto_unavailable("rsa_oaep_encrypt"); }

#endif

}
