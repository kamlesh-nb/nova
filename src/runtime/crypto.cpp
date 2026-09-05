// M11 stage B completed the crypto migration: SHA-1/256/384/512, MD5, HMAC-SHA256, PBKDF2, the
// MySQL auth-scrambles, and RSA-OAEP encryption are all implemented in pure Kyte (crypto/hash/*,
// crypto/mac/hmac, crypto/kdf/pbkdf2, crypto/rsa, and the MySQL driver). No wolfCrypt symbol remains.
//
// The one crypto-adjacent primitive kept in C is kyte_getrandom: an honest kernel entropy source
// (getentropy(2), the same portable primitive on macOS and Linux; libc, NOT a crypto library). Sourcing
// randomness here rather than through the os.sys module keeps crypto/random free of the os.sys import,
// so the crypto/TLS stack does not drag os.sys's socket/file externs into every consumer's namespace.

#include <cstddef>
#include <cstdlib>

#ifdef _WIN32
// Windows: BCryptGenRandom with the system-preferred RNG is the CSPRNG (mingw-w64 provides bcrypt.h;
// links -lbcrypt). BCRYPT_USE_SYSTEM_PREFERRED_RNG lets the algorithm handle be NULL.
#include <windows.h>
#include <bcrypt.h>
extern "C" void kyte_getrandom(char *buf, long long n) {
  if (BCryptGenRandom(NULL, (PUCHAR)buf, (ULONG)n, 0x00000002 /*BCRYPT_USE_SYSTEM_PREFERRED_RNG*/) != 0) {
    for (long long i = 0; i < n; i++) buf[i] = 0;   // fail closed to zeros rather than hang
  }
}
#else
#include <sys/random.h>
extern "C" void kyte_getrandom(char *buf, long long n) {
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

// ---- x86_64 CPU feature probe -------------------------------------------------------------------------
// Unlike aarch64, where AES+PMULL+SHA2 are present on every part anyone runs this on, x86_64 feature
// availability is genuinely variable: AES-NI is 2010+, SHA-NI did not reach mainstream Intel until Ice
// Lake. So the x86 integrated-assembly path (kyte_crypto_amd64.S) is dispatched per feature at runtime,
// and this is the single cached probe every decision below reads. CPUID is issued once, on first use;
// the function-local static gives thread-safe initialisation without a separate init hook.
// Guarded on the ARCHITECTURE, not on KYTE_ASM_CRYPTO_X86, even though the assembly dispatch is this
// probe's main consumer. A plain CPUID read costs nothing to compile without the asm, and
// `kyte_cpu_has_aes()` below needs an answer on every x86_64 build — including the CROSS ones, where the
// asm is absent. It used to reach for `__builtin_cpu_supports()` there, which pulls in compiler-rt's
// `__cpu_model`; zig's musl link does not provide that, so `kyte <app> --target linux-x86_64` died with
// `undefined symbol: __cpu_model` referenced from `kyte_cpu_has_aes`. Issuing CPUID directly removes the
// runtime dependency entirely and gives the identical answer.
#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
#include <cpuid.h>
namespace {
struct KyteX86Features {
  bool ssse3, sse41, aes, pclmul, sha, avx2;
  // Set by KYTE_NO_ASM_CRYPTO=1. Suppresses kyte_has_asm_crypto() ONLY — the feature bits stay truthful,
  // so kyte_cpu_has_aes() still reports the real CPU and the standard library falls back to its pure-Kyte
  // SIMD implementations rather than to bitsliced software. That is exactly the A/B worth measuring
  // (hand-written assembly vs compiler-emitted SIMD), and it doubles as a way to bisect a suspected
  // miscompare without rebuilding the runtime.
  bool asm_disabled;
};
KyteX86Features kyte_x86_detect() {
  KyteX86Features f{};
  if (const char *off = std::getenv("KYTE_NO_ASM_CRYPTO"))
    f.asm_disabled = (off[0] == '1');
  unsigned int a = 0, b = 0, c = 0, d = 0;
  if (__get_cpuid(1, &a, &b, &c, &d)) {
    f.pclmul = (c >> 1)  & 1u;
    f.ssse3  = (c >> 9)  & 1u;
    f.sse41  = (c >> 19) & 1u;
    f.aes    = (c >> 25) & 1u;
  }
  if (__get_cpuid_count(7, 0, &a, &b, &c, &d)) {
    f.avx2 = (b >> 5)  & 1u;
    f.sha  = (b >> 29) & 1u;
  }
  return f;
}
const KyteX86Features &kyte_x86() {
  static const KyteX86Features f = kyte_x86_detect();
  return f;
}
}  // namespace
#endif

// Runtime detection of the CPU's AES + carryless-multiply instructions, so the hardware AES-GCM
// (crypto/aead/aesgcmhw, which lowers simd.aesenc/simd.clmul to those instructions) is only used when the
// host actually has them; otherwise callers fall back to the constant-time bitsliced AES + software GHASH.
// Returns 1 if both AES and PMULL/PCLMULQDQ are available, else 0.
#if defined(__aarch64__)
  #if defined(__APPLE__)
    extern "C" int kyte_cpu_has_aes(void) { return 1; }   // Apple Silicon always has the crypto extensions
  #elif defined(__linux__)
    #include <sys/auxv.h>
    #include <asm/hwcap.h>
    extern "C" int kyte_cpu_has_aes(void) {
      unsigned long hw = getauxval(AT_HWCAP);
      return ((hw & HWCAP_AES) && (hw & HWCAP_PMULL)) ? 1 : 0;
    }
  #else
    extern "C" int kyte_cpu_has_aes(void) { return 0; }   // conservative on unknown aarch64
  #endif
#elif defined(KYTE_ASM_CRYPTO_X86)
  extern "C" int kyte_cpu_has_aes(void) {
    return (kyte_x86().aes && kyte_x86().pclmul) ? 1 : 0;
  }
#elif (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
  // Same CPUID probe as the KYTE_ASM_CRYPTO_X86 branch above — this arm is reached on an x86_64 build
  // WITHOUT the assembly (notably every cross build), where the answer still matters because it selects
  // hardware AES-GCM in the pure-Kyte crypto. Deliberately not `__builtin_cpu_supports`: see the note on
  // the probe's guard about `__cpu_model` and the cross link.
  extern "C" int kyte_cpu_has_aes(void) {
    return (kyte_x86().aes && kyte_x86().pclmul) ? 1 : 0;
  }
#else
  extern "C" int kyte_cpu_has_aes(void) { return 0; }
#endif

// Integrated-assembly crypto path. On aarch64 the fast routines live in kyte_crypto_arm64.S (hand-written
// AArch64, linked into libkytecore.a, called from Kyte by symbol — no FFI). On every OTHER host the same
// symbols are provided here as portable C so a Kyte program that references them still links; these are the
// correctness fallbacks (a host without the asm also lacks the hardware anyway, so the Kyte SIMD path is
// what actually runs there — these are only reached if a caller invokes the symbol directly).
// 1 when the hand-written AArch64 crypto assembly is compiled into this runtime (aarch64 host). Kyte's
// GcmContext dispatches the hot AES-GCM routines to the asm only when this is 1; every other host runs the
// pure-Kyte SIMD path (the C fallbacks below exist only so the symbols resolve at link time).
//
// On x86_64 the answer is a RUNTIME one, not a compile-time one. The gate is AES-NI + PCLMULQDQ + SSSE3 +
// SSE4.1, which is every part from Westmere (2010) and Bulldozer (2011) onward. That specific set is the
// gate because it is exactly what makes the whole family of entry points available at once:
//   - AES-NI + SSE4.1 (PINSRD)  -> kyte_aes_encrypt_block / kyte_aes_ctr / kyte_gcm_seal
//   - PCLMULQDQ + SSSE3         -> kyte_ghash and the GHASH half of the seal
//   - SSE2 + SSSE3              -> the SHA-256/SHA-512 and ChaCha20 routines
//   - baseline x86_64           -> Poly1305 (plain 64-bit integer work)
// Returning 1 is a promise that ALL of them work, because the Kyte callers share this single gate; a
// finer-grained answer would need a per-family gate in the standard library. SHA-NI is deliberately NOT
// part of the gate: it only selects a faster SHA-256 kernel below, and its absence must not switch off
// AES-GCM on the many machines that have AES-NI without it.
#if defined(__aarch64__) || defined(__arm64__)
  extern "C" int kyte_has_asm_crypto(void) { return 1; }
#elif defined(KYTE_ASM_CRYPTO_X86)
  extern "C" int kyte_has_asm_crypto(void) {
    const KyteX86Features &f = kyte_x86();
    if (f.asm_disabled) return 0;
    return (f.aes && f.pclmul && f.ssse3 && f.sse41) ? 1 : 0;
  }
#else
  extern "C" int kyte_has_asm_crypto(void) { return 0; }
#endif

#if !(defined(__aarch64__) || defined(__arm64__))
namespace {
  // FIPS-197 AES S-box.
  static const unsigned char KYTE_SBOX[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
  };
  static inline unsigned char xtime(unsigned char a) { return (unsigned char)((a << 1) ^ ((a >> 7) * 0x1b)); }
}
// Portable single-block AES encrypt, matching kyte_crypto_arm64.S. rk = packed round keys ((nr+1)*16),
// nr = 10 or 14. Standard FIPS-197 round (SubBytes, ShiftRows, MixColumns, AddRoundKey), state column-major.
// On x86_64 this is the fallback the dispatcher picks when the CPU has no AES-NI; elsewhere it IS
// kyte_aes_encrypt_block, via the thin wrapper at the bottom of the file.
static void kyte_aes_encrypt_block_c(const unsigned char* rk, int nr, const unsigned char* in, unsigned char* out) {
  unsigned char s[16];
  for (int i = 0; i < 16; i++) s[i] = in[i] ^ rk[i];      // AddRoundKey(K0)
  for (int round = 1; round <= nr; round++) {
    for (int i = 0; i < 16; i++) s[i] = KYTE_SBOX[s[i]];   // SubBytes
    unsigned char t;                                        // ShiftRows (rows 1..3 rotate left by row index)
    t = s[1];  s[1]=s[5];   s[5]=s[9];   s[9]=s[13];  s[13]=t;
    t = s[2];  s[2]=s[10];  s[10]=t;  t=s[6];  s[6]=s[14];  s[14]=t;
    t = s[15]; s[15]=s[11]; s[11]=s[7]; s[7]=s[3];   s[3]=t;
    if (round != nr) {                                      // MixColumns (skipped on final round)
      for (int c = 0; c < 4; c++) {
        unsigned char* col = s + c*4;
        unsigned char a0=col[0],a1=col[1],a2=col[2],a3=col[3];
        unsigned char h = a0 ^ a1 ^ a2 ^ a3;
        col[0] = a0 ^ h ^ xtime((unsigned char)(a0 ^ a1));
        col[1] = a1 ^ h ^ xtime((unsigned char)(a1 ^ a2));
        col[2] = a2 ^ h ^ xtime((unsigned char)(a2 ^ a3));
        col[3] = a3 ^ h ^ xtime((unsigned char)(a3 ^ a0));
      }
    }
    for (int i = 0; i < 16; i++) s[i] ^= rk[round*16 + i];  // AddRoundKey(Kround)
  }
  for (int i = 0; i < 16; i++) out[i] = s[i];
}

// Portable AES-CTR fallback matching kyte_crypto_arm64.S kyte_aes_ctr. ctr's low 32 bits are a big-endian
// counter, advanced in place. Not perf-critical (used only on hosts without the asm, which run the Kyte
// SIMD path anyway); correctness only, via the single-block routine above.
static void kyte_aes_ctr_c(const unsigned char* rk, int nr, unsigned char* ctr,
                           const unsigned char* in, int len, unsigned char* out) {
  unsigned char ks[16];
  int done = 0;
  while (done < len) {
    kyte_aes_encrypt_block_c(rk, nr, ctr, ks);
    int n = (len - done < 16) ? (len - done) : 16;
    for (int i = 0; i < n; i++) out[done + i] = in[done + i] ^ ks[i];
    // increment the big-endian 32-bit counter in ctr[12..15]
    for (int i = 15; i >= 12; i--) { if (++ctr[i] != 0) break; }
    done += n;
  }
}
#if defined(KYTE_ASM_CRYPTO_X86)
// ---- x86_64 integrated-assembly dispatch ---------------------------------------------------------------
// kyte_crypto_amd64.S exports FEATURE-SUFFIXED symbols; the unsuffixed names Kyte calls are these thin
// dispatchers. Splitting it this way (rather than branching inside the assembly, as one might on aarch64
// where there is nothing to branch on) keeps the CPUID logic in C where it is readable and testable, and
// lets one entry point have two kernels — which kyte_sha256_blocks does.
//
// KYTE_ASM_CRYPTO_X86 is defined by build.zig ONLY on the path that actually assembles the .S file. That
// matters: a cross-compiled x86_64 runtime does not get the assembly, and without the define this file
// keeps the portable behaviour instead of emitting references to symbols that were never assembled.
extern "C" {
void kyte_aes_encrypt_block_aesni(const unsigned char*, int, const unsigned char*, unsigned char*);
void kyte_aes_ctr_aesni(const unsigned char*, int, unsigned char*, const unsigned char*, int, unsigned char*);
void kyte_ghash_clmul(const unsigned char*, const unsigned char*, int, unsigned char*);
void kyte_gcm_seal_aesni(const unsigned char*, int, const unsigned char*, unsigned char*,
                         const unsigned char*, int, unsigned char*, unsigned char*);
void kyte_sha256_blocks_shani(unsigned int*, const unsigned char*, int);
void kyte_sha256_blocks_sse(unsigned int*, const unsigned char*, int);
void kyte_sha512_blocks_sse(unsigned long long*, const unsigned char*, int);
void kyte_chacha20_xor_sse(const unsigned char*, unsigned int, const unsigned char*,
                           const unsigned char*, int, unsigned char*);
void kyte_poly1305_blocks_x64(unsigned long long*, const unsigned char*, int);
void kyte_poly1305_finish_x64(unsigned long long*, const unsigned char*, int, unsigned char*,
                              unsigned long long, unsigned long long);
}

// AES: these two are the only entry points reachable when kyte_has_asm_crypto() is 0 — conformance 380
// calls kyte_aes_encrypt_block directly to gate the assembly against the pure-Kyte encBlock — so they
// fall back to the portable C rather than trapping.
extern "C" void kyte_aes_encrypt_block(const unsigned char* rk, int nr, const unsigned char* in, unsigned char* out) {
  if (kyte_x86().aes) kyte_aes_encrypt_block_aesni(rk, nr, in, out);
  else                kyte_aes_encrypt_block_c(rk, nr, in, out);
}
extern "C" void kyte_aes_ctr(const unsigned char* rk, int nr, unsigned char* ctr,
                             const unsigned char* in, int len, unsigned char* out) {
  if (kyte_x86().aes && kyte_x86().sse41) kyte_aes_ctr_aesni(rk, nr, ctr, in, len, out);
  else                                    kyte_aes_ctr_c(rk, nr, ctr, in, len, out);
}

// The rest are only ever called behind kyte_has_asm_crypto(), whose gate already implies the features
// each one needs. The guards below are belt-and-braces for a future direct caller: trapping matches the
// convention established for the non-aarch64 stubs — fail loudly rather than return a wrong tag or a
// wrong digest.
extern "C" void kyte_ghash(const unsigned char* hStd, const unsigned char* data, int len, unsigned char* y) {
  if (!(kyte_x86().pclmul && kyte_x86().ssse3)) __builtin_trap();
  kyte_ghash_clmul(hStd, data, len, y);
}
extern "C" void kyte_gcm_seal(const unsigned char* rk, int nr, const unsigned char* hpows, unsigned char* ctr,
                              const unsigned char* in, int len, unsigned char* out, unsigned char* y) {
  if (!(kyte_x86().aes && kyte_x86().sse41 && kyte_x86().pclmul && kyte_x86().ssse3)) __builtin_trap();
  kyte_gcm_seal_aesni(rk, nr, hpows, ctr, in, len, out, y);
}
extern "C" void kyte_chacha20_xor(const unsigned char* key, unsigned int counter, const unsigned char* nonce,
                                  const unsigned char* in, int len, unsigned char* out) {
  if (!kyte_x86().ssse3) __builtin_trap();
  kyte_chacha20_xor_sse(key, counter, nonce, in, len, out);
}
// The one entry point with two kernels: SHA-NI where the silicon has it (a large win), otherwise the
// SIMD-message-schedule routine, which needs only SSSE3.
extern "C" void kyte_sha256_blocks(unsigned int* state, const unsigned char* data, int blocks) {
  if (kyte_x86().sha && kyte_x86().sse41) { kyte_sha256_blocks_shani(state, data, blocks); return; }
  if (!kyte_x86().ssse3) __builtin_trap();
  kyte_sha256_blocks_sse(state, data, blocks);
}
// x86 has no SHA-512 instruction on any mainstream part, so there is only the one kernel here.
extern "C" void kyte_sha512_blocks(unsigned long long* state, const unsigned char* data, int blocks) {
  if (!kyte_x86().ssse3) __builtin_trap();
  kyte_sha512_blocks_sse(state, data, blocks);
}
extern "C" void kyte_poly1305_blocks(unsigned long long* state, const unsigned char* data, int nblocks) {
  kyte_poly1305_blocks_x64(state, data, nblocks);
}
extern "C" void kyte_poly1305_finish(unsigned long long* state, const unsigned char* tail, int taillen,
                                     unsigned char* out, unsigned long long padLo, unsigned long long padHi) {
  kyte_poly1305_finish_x64(state, tail, taillen, out, padLo, padHi);
}
// One-shot Poly1305. No Kyte caller reaches this today (crypto/mac/poly1305 drives the incremental pair
// above), but the aarch64 assembly exports it, so the symbol exists on both sides. The clamp and the
// 44/44/42-bit limb layout here must match Poly1305.create exactly.
extern "C" void kyte_poly1305(const unsigned char* key, const unsigned char* msg, int len, unsigned char* out) {
  unsigned long long st[8], t0, t1, padLo, padHi;
  __builtin_memcpy(&t0, key, 8);
  __builtin_memcpy(&t1, key + 8, 8);
  st[0] = t0 & 0x00000ffc0fffffffULL;
  st[1] = ((t0 >> 44) | (t1 << 20)) & 0x00000fffffc0ffffULL;
  st[2] = (t1 >> 24) & 0x00000ffffffc0fULL;
  st[3] = st[1] * 20;
  st[4] = st[2] * 20;
  st[5] = st[6] = st[7] = 0;
  __builtin_memcpy(&padLo, key + 16, 8);
  __builtin_memcpy(&padHi, key + 24, 8);
  kyte_poly1305_blocks_x64(st, msg, len / 16);
  kyte_poly1305_finish_x64(st, msg + (len / 16) * 16, len % 16, out, padLo, padHi);
}

#else   // no integrated assembly on this host: portable AES, and the rest must not be reached

extern "C" void kyte_aes_encrypt_block(const unsigned char* rk, int nr, const unsigned char* in, unsigned char* out) {
  kyte_aes_encrypt_block_c(rk, nr, in, out);
}
extern "C" void kyte_aes_ctr(const unsigned char* rk, int nr, unsigned char* ctr,
                             const unsigned char* in, int len, unsigned char* out) {
  kyte_aes_ctr_c(rk, nr, ctr, in, len, out);
}
// Never reached (callers gate on kyte_has_asm_crypto()==0 and run the Kyte implementations), but the
// symbols must resolve. Trap rather than return a wrong tag if a future caller forgets the gate.
extern "C" void kyte_ghash(const unsigned char*, const unsigned char*, int, unsigned char*) { __builtin_trap(); }
extern "C" void kyte_gcm_seal(const unsigned char*, int, const unsigned char*, unsigned char*,
                              const unsigned char*, int, unsigned char*, unsigned char*) { __builtin_trap(); }
extern "C" void kyte_chacha20_xor(const unsigned char*, unsigned int, const unsigned char*,
                                  const unsigned char*, int, unsigned char*) { __builtin_trap(); }
extern "C" void kyte_sha256_blocks(unsigned int*, const unsigned char*, int) { __builtin_trap(); }
extern "C" void kyte_sha512_blocks(unsigned long long*, const unsigned char*, int) { __builtin_trap(); }
extern "C" void kyte_poly1305(const unsigned char*, const unsigned char*, int, unsigned char*) { __builtin_trap(); }
extern "C" void kyte_poly1305_blocks(unsigned long long*, const unsigned char*, int) { __builtin_trap(); }
extern "C" void kyte_poly1305_finish(unsigned long long*, const unsigned char*, int, unsigned char*,
                                     unsigned long long, unsigned long long) { __builtin_trap(); }
#endif  // KYTE_ASM_CRYPTO_X86
#endif  // !aarch64
