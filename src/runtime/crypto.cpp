
#include "nova_abi.h"
#include "runtime_str.h"
#include <cstdio>
#include <cstdlib>

// M11 stage A retired the wolfCrypt hashing/HMAC/PBKDF2/random shims: SHA-1/256/512, MD5, HMAC-SHA256,
// PBKDF2-HMAC-SHA256, and the CSPRNG are now implemented in pure Nova (crypto/hash/*, crypto/mac/hmac,
// crypto/kdf/pbkdf2, crypto/random over /dev/urandom). What remains here is the MySQL auth-scramble and
// RSA-OAEP surface, which stage B migrates to Nova before wolfSSL is dropped entirely.

#ifdef NOVA_HAVE_WOLFSSL
#include <wolfssl/options.h>
#include <wolfssl/wolfcrypt/sha.h>
#include <wolfssl/wolfcrypt/sha256.h>
#include <wolfssl/wolfcrypt/random.h>
#include <wolfssl/wolfcrypt/rsa.h>
#include <wolfssl/wolfcrypt/asn.h>
#include <wolfssl/wolfcrypt/coding.h>
#include <cstring>
#endif

static inline int nova_crypto_slen(const char *s) {
  return s ? *reinterpret_cast<const int *>(s - 4) : 0;
}

extern "C" {

#ifdef NOVA_HAVE_WOLFSSL

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

#else

static char *nova_crypto_unavailable(const char *fn) {
  std::fprintf(stderr,
               "nova crypto: %s requires wolfSSL, which was not built into this "
               "runtime (rebuild with the vendored deps/wolfssl).\n",
               fn);
  std::_Exit(1);
  return nullptr;
}
char *nova_mysql_scramble(const char *, const char *, int) { return nova_crypto_unavailable("mysql_scramble"); }
char *nova_mysql_sha2_scramble(const char *, const char *, int) { return nova_crypto_unavailable("mysql_sha2_scramble"); }
char *nova_rsa_oaep_encrypt(const char *, const char *, int) { return nova_crypto_unavailable("rsa_oaep_encrypt"); }

#endif

}
