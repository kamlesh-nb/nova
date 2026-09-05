// Integrated-assembly crypto path (x86_64), the Go/BoringSSL model: hand-written assembly linked directly
// into libkytecore.a and called from Kyte via extern("c") — a plain `call`, NOT cgo/FFI marshalling. The
// aarch64 twin is kyte_crypto_arm64.S; the two implement the SAME contracts byte-for-byte, so the Kyte
// callers (crypto/aead/aesgcmhw, crypto/hash/sha256, sha512, crypto/cipher/chacha20, crypto/mac/poly1305)
// are unchanged. Built only on an x86_64 host (guarded in build.zig).
//
// WHAT DIFFERS FROM THE ARM64 FILE, and why this is not a transliteration:
//
//   1. arm64 has ONE feature bit that matters in practice (Apple Silicon and every ARMv8 server part carry
//      AES+PMULL+SHA2), so kyte_crypto_arm64.S can assume its instructions exist. x86_64 CANNOT: AES-NI is
//      2010+, SHA-NI did not reach mainstream Intel until Ice Lake (this file's development host, an
//      i5-8210Y, has AES-NI + PCLMULQDQ + AVX2 and NO SHA-NI). So every routine here is exported under a
//      FEATURE-SUFFIXED symbol (…_aesni, …_clmul, …_shani, …_avx2) and crypto.cpp owns the CPUID dispatch
//      plus a portable-C fallback. Nothing in this file is reached without its feature bit confirmed.
//   2. arm64 keeps all 15 AES round keys resident in v0..v14. x86_64 has only 16 xmm registers total, so
//      AES-256 residency is impossible; the round keys are re-loaded from L1 each round and the latency is
//      hidden by running EIGHT counter blocks in flight instead of four.
//   3. arm64 reflects GHASH bytes with a single RBIT. x86 has no per-byte bit reverse, so BREV8 does it
//      with two PSHUFB nibble lookups (see the macro).
//   4. Two ABIs. SysV (Linux/macOS) passes rdi,rsi,rdx,rcx,r8,r9; Win64 passes rcx,rdx,r8,r9 + stack, makes
//      rdi/rsi/xmm6-15 callee-saved, and reserves 32 bytes of shadow space. The PROLOG/EPILOG macros
//      normalise Win64 into SysV register positions so each routine body is written once.
//
// DO NOT "SIMPLIFY" `$(0x39)` TO `$0x39`. Inside a `.macro` body the Darwin assembler expands `$0` as
// the macro's whole argument list, so `pshufd $0x39, ...` becomes `pshufd x39, ...` and the file stops
// assembling for x86_64 macOS — while remaining perfectly fine on Linux and Windows, which is what makes
// it easy to reintroduce. The parentheses stop `$` from being followed by a digit. Only `$0`-prefixed
// immediates are affected, which is why the rest are left bare. Verified by assembling this file for
// x86_64-linux-gnu, x86_64-macos and x86_64-windows-msvc.

#if defined(__x86_64__) || defined(_M_X64)

// ---- Symbol naming ------------------------------------------------------------------------------------
// Mach-O prefixes C symbols with an underscore; ELF and COFF-x64 do not.
#if defined(__APPLE__)
# define SYM(n) _##n
#else
# define SYM(n) n
#endif

// ---- ABI normalisation --------------------------------------------------------------------------------
// After PROLOG_<n>, arguments 1..6 are in rdi, rsi, rdx, rcx, r8, r9 regardless of host ABI, and rdi/rsi
// are saved on Win64 (where they are callee-saved). Stack arguments are read AFTER the two pushes, so the
// Win64 offsets below are the at-entry ones (+40, +48, +56) plus 16.
#if defined(_WIN32)
# define PROLOG_2 push %rdi; push %rsi; mov %rcx, %rdi; mov %rdx, %rsi
# define PROLOG_3 PROLOG_2; mov %r8, %rdx
# define PROLOG_4 PROLOG_3; mov %r9, %rcx
# define PROLOG_5 PROLOG_4; mov 56(%rsp), %r8
# define PROLOG_6 PROLOG_5; mov 64(%rsp), %r9
# define EPILOG   pop %rsi; pop %rdi
#else
# define PROLOG_2
# define PROLOG_3
# define PROLOG_4
# define PROLOG_5
# define PROLOG_6
# define EPILOG
#endif
// There is deliberately no PROLOG_7/PROLOG_8. The stack-argument offsets above are only correct while
// nothing else has been pushed, and the one routine with more than six arguments (kyte_gcm_seal_aesni)
// also needs callee-saved registers — so it spells its own prologue out, with the offsets adjusted for
// those pushes. A generic macro there would silently read the wrong slots.

// xmm6..xmm15 are callee-saved on Win64 and volatile on SysV. 168 bytes keeps rsp 16-byte aligned after the
// two PROLOG pushes (entry rsp ≡ 8 mod 16; +16 from the pushes; 168 ≡ 8 mod 16 → ≡ 0). movdqu is used so
// correctness does not depend on that, but a misaligned rsp would still be a latent trap for anything added
// later that spills with movdqa.
#if defined(_WIN32)
# define SAVE_XMM \
    sub $168, %rsp; \
    movdqu %xmm6,    0(%rsp); movdqu %xmm7,   16(%rsp); \
    movdqu %xmm8,   32(%rsp); movdqu %xmm9,   48(%rsp); \
    movdqu %xmm10,  64(%rsp); movdqu %xmm11,  80(%rsp); \
    movdqu %xmm12,  96(%rsp); movdqu %xmm13, 112(%rsp); \
    movdqu %xmm14, 128(%rsp); movdqu %xmm15, 144(%rsp)
# define REST_XMM \
    movdqu    0(%rsp), %xmm6;  movdqu  16(%rsp), %xmm7; \
    movdqu   32(%rsp), %xmm8;  movdqu  48(%rsp), %xmm9; \
    movdqu   64(%rsp), %xmm10; movdqu  80(%rsp), %xmm11; \
    movdqu   96(%rsp), %xmm12; movdqu 112(%rsp), %xmm13; \
    movdqu  128(%rsp), %xmm14; movdqu 144(%rsp), %xmm15; \
    add $168, %rsp
#else
# define SAVE_XMM
# define REST_XMM
#endif

.text

// ======================================================================================================
//   AES-NI
// ======================================================================================================

// void kyte_aes_encrypt_block_aesni(const uint8_t* rk, int nr, const uint8_t* in, uint8_t* out)
//   rdi = rk (packed round keys, (nr+1)*16 bytes), esi = nr (10 or 14), rdx = in, rcx = out.
// x86's AESENC(state, key) = MixColumns(ShiftRows(SubBytes(state))) XOR key — the key is applied at the
// END of the round, where ARM's AESE applies it at the start. So the x86 sequence is the textbook one:
//   AddRoundKey(k0); AESENC(k1..k_{nr-1}); AESENCLAST(k_nr).
// Correctness anchor for the whole mechanism (FIPS-197 KAT, conformance 380).
.globl SYM(kyte_aes_encrypt_block_aesni)
.p2align 4
SYM(kyte_aes_encrypt_block_aesni):
    PROLOG_4
    movdqu  (%rdx), %xmm0           // state = in
    movdqu  (%rdi), %xmm1
    pxor    %xmm1, %xmm0            // AddRoundKey(k0)
    lea     16(%rdi), %rax          // rk cursor -> k1
    mov     %esi, %r10d
    dec     %r10d                   // nr-1 AESENC rounds
1:
    movdqu  (%rax), %xmm1
    aesenc  %xmm1, %xmm0
    add     $16, %rax
    dec     %r10d
    jnz     1b
    movdqu  (%rax), %xmm1           // k_nr
    aesenclast %xmm1, %xmm0
    movdqu  %xmm0, (%rcx)
    EPILOG
    ret

// One AES round applied to the eight in-flight counter blocks xmm0..xmm7 with the round key in xmm8.
.macro AESENC8
    aesenc %xmm8, %xmm0
    aesenc %xmm8, %xmm1
    aesenc %xmm8, %xmm2
    aesenc %xmm8, %xmm3
    aesenc %xmm8, %xmm4
    aesenc %xmm8, %xmm5
    aesenc %xmm8, %xmm6
    aesenc %xmm8, %xmm7
.endm
.macro AESLAST8
    aesenclast %xmm8, %xmm0
    aesenclast %xmm8, %xmm1
    aesenclast %xmm8, %xmm2
    aesenclast %xmm8, %xmm3
    aesenclast %xmm8, %xmm4
    aesenclast %xmm8, %xmm5
    aesenclast %xmm8, %xmm6
    aesenclast %xmm8, %xmm7
.endm

// Build counter block \dst from the template in xmm15: copy the 12-byte prefix and splice the big-endian
// 32-bit counter (eax + \off) into dword lane 3. PINSRD is SSE4.1, which every AES-NI part has.
.macro CTRBLK dst, off
    movdqa  %xmm15, \dst
    lea     \off(%rax), %r11d
    bswap   %r11d
    pinsrd  $3, %r11d, \dst
.endm

// Run all AES rounds over xmm0..xmm7 with the round keys at rdi, branching once on key size.
// r10 is the round-key cursor; esi holds nr.
.macro AESROUNDS8
    movdqu  (%rdi), %xmm8
    pxor    %xmm8, %xmm0
    pxor    %xmm8, %xmm1
    pxor    %xmm8, %xmm2
    pxor    %xmm8, %xmm3
    pxor    %xmm8, %xmm4
    pxor    %xmm8, %xmm5
    pxor    %xmm8, %xmm6
    pxor    %xmm8, %xmm7
    lea     16(%rdi), %r10
    mov     %esi, %r11d
    dec     %r11d
9:
    movdqu  (%r10), %xmm8
    AESENC8
    add     $16, %r10
    dec     %r11d
    jnz     9b
    movdqu  (%r10), %xmm8
    AESLAST8
.endm

// void kyte_aes_ctr_aesni(const uint8_t* rk, int nr, uint8_t* ctr, const uint8_t* in, int len, uint8_t* out)
//   rdi=rk esi=nr rdx=ctr (16B; low 32 bits are a big-endian counter, advanced in place) rcx=in r8d=len r9=out
// Eight counter blocks per iteration: AESENC is latency 4 / throughput 1 on every part that has it, so
// eight independent chains are what saturates the unit (the arm64 twin needs only four because it can keep
// the round keys resident and issue two AES ops per cycle). The <128-byte and partial tails fall to single
// blocks. Byte-identical to the pure-Kyte gctrHw.
.globl SYM(kyte_aes_ctr_aesni)
.p2align 4
SYM(kyte_aes_ctr_aesni):
    PROLOG_6
    SAVE_XMM
    mov     4*3(%rdx), %eax         // native low-32 counter (stored big-endian)
    bswap   %eax
    movdqu  (%rdx), %xmm15          // counter-block template (bytes 0..11 = prefix; lane 3 overwritten)
    // --- 8-way main loop over 128-byte chunks ---
1:
    cmp     $128, %r8d
    jl      3f
    CTRBLK  %xmm0, 0
    CTRBLK  %xmm1, 1
    CTRBLK  %xmm2, 2
    CTRBLK  %xmm3, 3
    CTRBLK  %xmm4, 4
    CTRBLK  %xmm5, 5
    CTRBLK  %xmm6, 6
    CTRBLK  %xmm7, 7
    AESROUNDS8
    movdqu    0(%rcx), %xmm8; pxor %xmm8, %xmm0; movdqu %xmm0,   0(%r9)
    movdqu   16(%rcx), %xmm8; pxor %xmm8, %xmm1; movdqu %xmm1,  16(%r9)
    movdqu   32(%rcx), %xmm8; pxor %xmm8, %xmm2; movdqu %xmm2,  32(%r9)
    movdqu   48(%rcx), %xmm8; pxor %xmm8, %xmm3; movdqu %xmm3,  48(%r9)
    movdqu   64(%rcx), %xmm8; pxor %xmm8, %xmm4; movdqu %xmm4,  64(%r9)
    movdqu   80(%rcx), %xmm8; pxor %xmm8, %xmm5; movdqu %xmm5,  80(%r9)
    movdqu   96(%rcx), %xmm8; pxor %xmm8, %xmm6; movdqu %xmm6,  96(%r9)
    movdqu  112(%rcx), %xmm8; pxor %xmm8, %xmm7; movdqu %xmm7, 112(%r9)
    add     $128, %rcx
    add     $128, %r9
    add     $8, %eax
    sub     $128, %r8d
    jmp     1b
3:
    // --- tail: single blocks (full 16B), then a final partial ---
    cmp     $(0), %r8d
    jle     8f
    CTRBLK  %xmm0, 0
    movdqu  (%rdi), %xmm8
    pxor    %xmm8, %xmm0
    lea     16(%rdi), %r10
    mov     %esi, %r11d
    dec     %r11d
4:
    movdqu  (%r10), %xmm8
    aesenc  %xmm8, %xmm0
    add     $16, %r10
    dec     %r11d
    jnz     4b
    movdqu  (%r10), %xmm8
    aesenclast %xmm8, %xmm0
    inc     %eax
    cmp     $16, %r8d
    jl      6f
    movdqu  (%rcx), %xmm8
    pxor    %xmm8, %xmm0
    movdqu  %xmm0, (%r9)
    add     $16, %rcx
    add     $16, %r9
    sub     $16, %r8d
    jmp     3b
6:
    // partial (<16) final block: spill the keystream and XOR byte-wise
    sub     $16, %rsp
    movdqu  %xmm0, (%rsp)
    xor     %r10d, %r10d
7:
    cmp     %r8d, %r10d
    jge     75f
    movzbl  (%rcx,%r10), %r11d
    xorb    (%rsp,%r10), %r11b
    movb    %r11b, (%r9,%r10)
    inc     %r10d
    jmp     7b
75:
    add     $16, %rsp
8:
    bswap   %eax                    // write the advanced counter back (big-endian)
    mov     %eax, 4*3(%rdx)
    REST_XMM
    EPILOG
    ret

// ======================================================================================================
//   GHASH — PCLMULQDQ
// ======================================================================================================
// Same arithmetic as the arm64 twin: operands are in "standard" order (each byte bit-reversed relative to
// GCM's wire order), the field multiply uses the FORWARD polynomial constant 0x87, and the reduction folds
// the high half down in two steps. Only two things differ from the NEON version:
//
//   * ARM's `ext v6, v1, v1, #8` (rotate a vector by 8 bytes) is PSHUFD $(0x4e); `ext v8, zero, v6, #8`
//     (shift in from zero) is PSLLDQ $8, and the mirror-image `ext v9, v6, zero, #8` is PSRLDQ $8.
//   * ARM reflects bytes with a single RBIT. x86 has no per-byte bit reverse at all, so BREV8 splits each
//     byte into nibbles and does two PSHUFB table lookups — see the macro.
//
// EVERY load from a caller buffer is MOVDQU, deliberately. Kyte's bytes.alloc() returns malloc(n+8)+8 for
// the 8-byte object header, so a Kyte buffer is 8-byte aligned and NEVER 16-byte aligned. A legacy-SSE
// memory operand (including the implicit one in `pclmulqdq $(0), (%rdx), %xmm4`) faults on that. Only the
// .rodata constants below, which are .p2align 4, are safe to touch with an aligned form.

// Per-byte bit reversal of \v. Splits into nibbles and looks up two tables: BREV_HI maps a low nibble to
// its reversal placed in the HIGH nibble, BREV_LO maps a high nibble to its reversal in the low nibble; OR
// them and every byte is reversed. \mask must hold 0x0f in every byte. Clobbers \t1 and \t2.
// PSRLW shifts 16-bit lanes, so bits leak across the byte boundary — the PAND after it discards them.
.macro BREV8 v, mask, t1, t2
    movdqa  \v, \t1
    pand    \mask, \t1                  // low nibbles
    movdqa  BREV_HI(%rip), \t2
    pshufb  \t1, \t2                    // t2 = BREV_HI[low nibble]
    psrlw   $4, \v
    pand    \mask, \v                   // high nibbles
    movdqa  BREV_LO(%rip), \t1
    pshufb  \v, \t1                     // t1 = BREV_LO[high nibble]
    por     \t1, \t2
    movdqa  \t2, \v
.endm

// acc {xmm13=lo128, xmm14=hi128} ^= the UN-reduced 256-bit product \va * \vb. Karatsuba: three carryless
// multiplies (lo, hi, and the folded middle) instead of four. Deferring the reduction is what lets four
// blocks share one — the whole point of the aggregation. Scratch xmm4..xmm8.
.macro MULACC va, vb
    movdqa  \va, %xmm4
    pclmulqdq $(0x00), \vb, %xmm4         // lo = a0*b0 -> {l0,l1}
    movdqa  \va, %xmm5
    pclmulqdq $(0x11), \vb, %xmm5         // hi = a1*b1 -> {h0,h1}
    pshufd  $(0x4e), \va, %xmm6
    pxor    \va, %xmm6                  // {a0^a1, a0^a1}
    pshufd  $(0x4e), \vb, %xmm7
    pxor    \vb, %xmm7                  // {b0^b1, b0^b1}
    pclmulqdq $(0x00), %xmm7, %xmm6       // mid_raw = (a0^a1)*(b0^b1)
    pxor    %xmm4, %xmm6
    pxor    %xmm5, %xmm6                // mid = {m0, m1}
    movdqa  %xmm6, %xmm8
    pslldq  $8, %xmm8                   // {0, m0}
    pxor    %xmm4, %xmm8                // lo128 = {p0=l0, p1=l1^m0}
    psrldq  $8, %xmm6                   // {m1, 0}
    pxor    %xmm5, %xmm6                // hi128 = {p2=h0^m1, p3=h1}
    pxor    %xmm8, %xmm13
    pxor    %xmm6, %xmm14
.endm

// Reduce the accumulated {xmm13=lo128, xmm14=hi128} mod P into \dst. \poly holds {0x87, 0x87}.
// Two folds: p2 and p3 each multiplied by 0x87, then the carry-out d1 folded once more.
.macro REDUCE_ACC dst, poly
    movdqa  %xmm14, %xmm4
    pclmulqdq $(0x00), \poly, %xmm4       // p2*0x87 -> {c0, c1}
    movdqa  %xmm14, %xmm5
    pclmulqdq $(0x11), \poly, %xmm5       // p3*0x87 -> {d0, d1}
    movdqa  %xmm5, %xmm6
    psrldq  $8, %xmm6                   // {d1, 0}
    pclmulqdq $(0x00), \poly, %xmm6       // d1*0x87 -> {o0, .}
    punpcklqdq %xmm5, %xmm6             // {o0, d0}
    movdqa  %xmm13, \dst
    pxor    %xmm4, \dst                 // {p0^c0, p1^c1}
    pxor    %xmm6, \dst                 // {r0=p0^c0^o0, r1=p1^c1^d0}
.endm

// xmm1 = xmm1 * \vb, fully reduced. Clobbers xmm4..xmm8, xmm13, xmm14.
.macro GFMUL vb, poly
    pxor    %xmm13, %xmm13
    pxor    %xmm14, %xmm14
    MULACC  %xmm1, \vb
    REDUCE_ACC %xmm1, \poly
.endm

// void kyte_ghash_clmul(const uint8_t* hStd, const uint8_t* data, int len, uint8_t* y)
//   rdi=hStd (H, standard order), rsi=data, edx=len, rcx=y (16B accumulator, standard order, in/out).
// Absorbs len bytes (16B blocks; a final partial block is zero-padded): for each block X,
//   y = (y ^ bitreverse_per_byte(X)) * H.
// Buffers >= 64 bytes take the 4-way key-power aggregation: the reduction is GF(2)-linear, so four blocks'
// un-reduced products can be summed and reduced ONCE —
//   y' = (y^X0)*H^4 ^ X1*H^3 ^ X2*H^2 ^ X3*H.
// H^2..H^4 are derived here rather than passed in, so short AAD and the 16-byte length block skip the
// precompute entirely and take the single-block path.
// Register budget is exactly 16: xmm0=H, xmm1=Y, xmm2=poly, xmm3=nibble mask, xmm4-9 scratch,
// xmm10-12 = H^2..H^4, xmm13/14 = accumulator, xmm15 = the block in flight.
.globl SYM(kyte_ghash_clmul)
.p2align 4
SYM(kyte_ghash_clmul):
    PROLOG_4
    SAVE_XMM
    movdqu  (%rdi), %xmm0               // H (standard order)
    movdqu  (%rcx), %xmm1               // Y (standard order)
    movdqa  POLY87(%rip), %xmm2
    movdqa  MASK0F(%rip), %xmm3
    cmp     $64, %edx
    jl      3f
    // --- derive H^2, H^3, H^4 (only for buffers that will use the 4-way loop) ---
    movdqa  %xmm1, %xmm15               // park Y; GFMUL works in xmm1
    movdqa  %xmm0, %xmm1
    GFMUL   %xmm0, %xmm2                // H^2
    movdqa  %xmm1, %xmm10
    GFMUL   %xmm0, %xmm2                // H^3
    movdqa  %xmm1, %xmm11
    GFMUL   %xmm0, %xmm2                // H^4
    movdqa  %xmm1, %xmm12
    movdqa  %xmm15, %xmm1               // restore Y
1:
    // --- 4-way aggregated loop ---
    cmp     $64, %edx
    jl      3f
    pxor    %xmm13, %xmm13
    pxor    %xmm14, %xmm14
    movdqu    0(%rsi), %xmm15
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    pxor    %xmm1, %xmm15               // (X0 ^ Y)
    MULACC  %xmm15, %xmm12              // * H^4
    movdqu   16(%rsi), %xmm15
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    MULACC  %xmm15, %xmm11              // * H^3
    movdqu   32(%rsi), %xmm15
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    MULACC  %xmm15, %xmm10              // * H^2
    movdqu   48(%rsi), %xmm15
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    MULACC  %xmm15, %xmm0               // * H
    REDUCE_ACC %xmm1, %xmm2
    add     $64, %rsi
    sub     $64, %edx
    jmp     1b
3:
    // --- single-block loop ---
    cmp     $16, %edx
    jl      5f
    movdqu  (%rsi), %xmm15
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    pxor    %xmm15, %xmm1
    GFMUL   %xmm0, %xmm2
    add     $16, %rsi
    sub     $16, %edx
    jmp     3b
5:
    // --- final partial block: copy edx bytes into a zeroed 16-byte slot, then absorb ---
    cmp     $(0), %edx
    jle     8f
    sub     $16, %rsp
    pxor    %xmm15, %xmm15
    movdqu  %xmm15, (%rsp)
    xor     %r10d, %r10d
6:
    cmp     %edx, %r10d
    jge     7f
    movzbl  (%rsi,%r10), %r11d
    movb    %r11b, (%rsp,%r10)
    inc     %r10d
    jmp     6b
7:
    movdqu  (%rsp), %xmm15
    add     $16, %rsp
    BREV8   %xmm15, %xmm3, %xmm4, %xmm5
    pxor    %xmm15, %xmm1
    GFMUL   %xmm0, %xmm2
8:
    movdqu  %xmm1, (%rcx)               // store Y (standard order; the caller reflects back)
    REST_XMM
    EPILOG
    ret

// ======================================================================================================
//   Fused stitched seal — AES-NI + PCLMULQDQ
// ======================================================================================================
// void kyte_gcm_seal_aesni(const uint8_t* rk, int nr, const uint8_t* hpows, uint8_t* ctr,
//                          const uint8_t* in, int len, uint8_t* out, uint8_t* y)
//   rk, nr, hpows (64B: H,H^2,H^3,H^4 std order), ctr, in, len (MULTIPLE OF 64), out, y (in/out, std order).
// Encrypts `in` to `out` and GHASHes the ciphertext into y IN ONE LOOP, so the ciphertext never round-trips
// to memory for the hash and the out-of-order core overlaps this group's PCLMULQDQs with the next group's
// AESENCs — the two execution units are independent. The <64-byte and length-block tail is the caller's,
// via kyte_aes_ctr + kyte_ghash.
//
// Four blocks per group, not eight as in kyte_aes_ctr_aesni: the GHASH half needs xmm4..xmm9 for Karatsuba
// scratch plus xmm10-14 for the poly/mask/Y/accumulator, which leaves exactly four for blocks. The AES and
// GHASH phases run back to back rather than interleaved by hand; overlap comes from the OoO window across
// iterations, which is where it comes from on this microarchitecture anyway.
.globl SYM(kyte_gcm_seal_aesni)
.p2align 4
SYM(kyte_gcm_seal_aesni):
#if defined(_WIN32)
    push    %rdi
    push    %rsi
    push    %rbx
    push    %rbp
    mov     %rcx, %rdi                  // rk
    mov     %rdx, %rsi                  // nr
    mov     %r8,  %rdx                  // hpows
    mov     %r9,  %rcx                  // ctr
    mov     72(%rsp), %r8               // in     (entry rsp+40, plus 32 bytes of pushes)
    mov     80(%rsp), %r9d              // len
    mov     88(%rsp), %rbx              // out
    mov     96(%rsp), %rbp              // y
#else
    push    %rbx
    push    %rbp
    mov     24(%rsp), %rbx              // out    (entry rsp+8, plus 16 bytes of pushes)
    mov     32(%rsp), %rbp              // y
#endif
    SAVE_XMM
    mov     4*3(%rcx), %eax             // native low-32 counter
    bswap   %eax
    movdqu  (%rcx), %xmm15              // counter-block template
    movdqu  (%rbp), %xmm12              // Y
    movdqa  POLY87(%rip), %xmm10
    movdqa  MASK0F(%rip), %xmm11
    cmp     $(0), %r9d
    jle     9f
1:
    // ---- AES-CTR phase: four keystream blocks ----
    CTRBLK  %xmm0, 0
    CTRBLK  %xmm1, 1
    CTRBLK  %xmm2, 2
    CTRBLK  %xmm3, 3
    movdqu  (%rdi), %xmm4
    pxor    %xmm4, %xmm0
    pxor    %xmm4, %xmm1
    pxor    %xmm4, %xmm2
    pxor    %xmm4, %xmm3
    lea     16(%rdi), %r10
    mov     %esi, %r11d
    dec     %r11d
2:
    movdqu  (%r10), %xmm4
    aesenc  %xmm4, %xmm0
    aesenc  %xmm4, %xmm1
    aesenc  %xmm4, %xmm2
    aesenc  %xmm4, %xmm3
    add     $16, %r10
    dec     %r11d
    jnz     2b
    movdqu  (%r10), %xmm4
    aesenclast %xmm4, %xmm0
    aesenclast %xmm4, %xmm1
    aesenclast %xmm4, %xmm2
    aesenclast %xmm4, %xmm3
    // XOR plaintext -> ciphertext, store
    movdqu    0(%r8), %xmm4; pxor %xmm4, %xmm0; movdqu %xmm0,   0(%rbx)
    movdqu   16(%r8), %xmm4; pxor %xmm4, %xmm1; movdqu %xmm1,  16(%rbx)
    movdqu   32(%r8), %xmm4; pxor %xmm4, %xmm2; movdqu %xmm2,  32(%rbx)
    movdqu   48(%r8), %xmm4; pxor %xmm4, %xmm3; movdqu %xmm3,  48(%rbx)
    // ---- GHASH phase: the four ciphertext blocks, straight from registers ----
    BREV8   %xmm0, %xmm11, %xmm4, %xmm5
    pxor    %xmm12, %xmm0               // block0 ^ Y
    BREV8   %xmm1, %xmm11, %xmm4, %xmm5
    BREV8   %xmm2, %xmm11, %xmm4, %xmm5
    BREV8   %xmm3, %xmm11, %xmm4, %xmm5
    pxor    %xmm13, %xmm13
    pxor    %xmm14, %xmm14
    movdqu  48(%rdx), %xmm9;  MULACC %xmm0, %xmm9    // (Y^X0) * H^4
    movdqu  32(%rdx), %xmm9;  MULACC %xmm1, %xmm9    // X1 * H^3
    movdqu  16(%rdx), %xmm9;  MULACC %xmm2, %xmm9    // X2 * H^2
    movdqu    (%rdx), %xmm9;  MULACC %xmm3, %xmm9    // X3 * H^1
    REDUCE_ACC %xmm12, %xmm10
    add     $4, %eax
    add     $64, %r8
    add     $64, %rbx
    sub     $64, %r9d
    jg      1b
9:
    movdqu  %xmm12, (%rbp)              // store Y
    bswap   %eax
    mov     %eax, 4*3(%rcx)             // store the advanced counter
    REST_XMM
    pop     %rbp
    pop     %rbx
    EPILOG
    ret

// ======================================================================================================
//   SHA-256 — SHA-NI
// ======================================================================================================
// void kyte_sha256_blocks_shani(uint32_t state[8], const uint8_t* data, int blocks)
//   rdi = state (H0..H7 stored BIG-ENDIAN, as the Kyte software sha256 keeps them), rsi = data, edx = blocks.
//
// The round sequence is a faithful transliteration of Go's blockSHANI
// (crypto/internal/fips140/sha256/sha256block_amd64.s), which is in turn Intel's reference schedule. Go's
// Plan9 operand order for these three instructions is already (implicit-XMM0, src, dst), the same order GNU
// AT&T syntax wants, so the instruction stream maps 1:1 and stays auditable against the original.
//
// TWO deliberate differences from Go:
//   * Kyte stores the digest big-endian, Go stores it native, so PSHUFB with FLIP32 converts on the way in
//     and on the way out (the arm64 twin uses REV32 for the same reason).
//   * Go's K256 table duplicates each 4-constant group to 32 bytes for its AVX2 path; ours is a plain
//     256-byte table, so every Go offset is halved (Go 128(AX) -> 64(%rax)).
//
// SHA256RNDS2 keeps the state as two registers, xmm1 = {A,B,E,F} and xmm2 = {C,D,G,H}, and each instruction
// does TWO rounds writing the destination as the new ABEF — so the two registers ping-pong roles, which is
// why the calls alternate `%xmm1,%xmm2` and `%xmm2,%xmm1`. The PSHUFD $(0x0e) between them slides the second
// pair of W+K values down into the low quadword where the instruction reads them.
//
// NOTE ON VERIFICATION: this file's development host (i5-8210Y) has no SHA-NI, so this path could not be
// executed there. It was validated by emulating SHA256RNDS2/MSG1/MSG2 from the Intel SDM pseudocode in C
// and running THIS EXACT macro sequence against the SHA-256 KATs; the arrangement is correct, and what
// remains untested on real silicon is only the instruction encoding, which the assembler owns.

// One 4-round group of the steady-state schedule. \a is the message register being consumed, \b the one
// being completed by MSG2, \d the one MSG1 advances. \msg1 = 0 for the last two groups, where the schedule
// is already complete.
.macro SHANI_GRP a, b, d, koff, msg1
    movdqa  \a, %xmm0
    paddd   \koff(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    movdqa  \a, %xmm7
    palignr $(0x04), \d, %xmm7
    paddd   %xmm7, \b
    sha256msg2 \a, \b
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1
    .if \msg1
    sha256msg1 \a, \d
    .endif
.endm

.globl SYM(kyte_sha256_blocks_shani)
.p2align 4
SYM(kyte_sha256_blocks_shani):
    PROLOG_3
    SAVE_XMM
    cmp     $(0), %edx
    jle     9f
    movdqu    (%rdi), %xmm1             // H0..H3 (big-endian)
    movdqu  16(%rdi), %xmm2             // H4..H7 (big-endian)
    movdqa  FLIP32(%rip), %xmm8
    pshufb  %xmm8, %xmm1                // -> native u32 lanes [A,B,C,D]
    pshufb  %xmm8, %xmm2                // -> [E,F,G,H]
    // Re-lay the digest into the {A,B,E,F} / {C,D,G,H} split the instruction requires.
    pshufd  $(0xb1), %xmm1, %xmm1         // [B,A,D,C]
    pshufd  $(0x1b), %xmm2, %xmm2         // [H,G,F,E]
    movdqa  %xmm1, %xmm7
    palignr $(0x08), %xmm2, %xmm1         // xmm1 = ABEF
    pblendw $(0xf0), %xmm7, %xmm2         // xmm2 = CDGH
    lea     K256(%rip), %rax
1:
    movdqa  %xmm1, %xmm9                // save the digest for the feed-forward add
    movdqa  %xmm2, %xmm10
    // --- rounds 0-15: load and byte-swap the four message quadwords ---
    movdqu    (%rsi), %xmm0
    pshufb  %xmm8, %xmm0
    movdqa  %xmm0, %xmm3
    paddd     0(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1

    movdqu  16(%rsi), %xmm0
    pshufb  %xmm8, %xmm0
    movdqa  %xmm0, %xmm4
    paddd    16(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1
    sha256msg1 %xmm4, %xmm3

    movdqu  32(%rsi), %xmm0
    pshufb  %xmm8, %xmm0
    movdqa  %xmm0, %xmm5
    paddd    32(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1
    sha256msg1 %xmm5, %xmm4

    movdqu  48(%rsi), %xmm0
    pshufb  %xmm8, %xmm0
    movdqa  %xmm0, %xmm6
    paddd    48(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    movdqa  %xmm6, %xmm7
    palignr $(0x04), %xmm5, %xmm7
    paddd   %xmm7, %xmm3
    sha256msg2 %xmm6, %xmm3
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1
    sha256msg1 %xmm6, %xmm5
    // --- rounds 16-59 ---
    SHANI_GRP %xmm3, %xmm4, %xmm6,  64, 1
    SHANI_GRP %xmm4, %xmm5, %xmm3,  80, 1
    SHANI_GRP %xmm5, %xmm6, %xmm4,  96, 1
    SHANI_GRP %xmm6, %xmm3, %xmm5, 112, 1
    SHANI_GRP %xmm3, %xmm4, %xmm6, 128, 1
    SHANI_GRP %xmm4, %xmm5, %xmm3, 144, 1
    SHANI_GRP %xmm5, %xmm6, %xmm4, 160, 1
    SHANI_GRP %xmm6, %xmm3, %xmm5, 176, 1
    SHANI_GRP %xmm3, %xmm4, %xmm6, 192, 1
    SHANI_GRP %xmm4, %xmm5, %xmm3, 208, 0
    SHANI_GRP %xmm5, %xmm6, %xmm4, 224, 0
    // --- rounds 60-63 ---
    movdqa  %xmm6, %xmm0
    paddd   240(%rax), %xmm0
    sha256rnds2 %xmm0, %xmm1, %xmm2
    pshufd  $(0x0e), %xmm0, %xmm0
    sha256rnds2 %xmm0, %xmm2, %xmm1
    // feed-forward
    paddd   %xmm9, %xmm1
    paddd   %xmm10, %xmm2
    add     $64, %rsi
    dec     %edx
    jnz     1b
    // Undo the ABEF/CDGH split and the endian flip, then store.
    pshufd  $(0x1b), %xmm1, %xmm1
    pshufd  $(0xb1), %xmm2, %xmm2
    movdqa  %xmm1, %xmm7
    pblendw $(0xf0), %xmm2, %xmm1
    palignr $(0x08), %xmm7, %xmm2
    pshufb  %xmm8, %xmm1                // native u32 -> big-endian
    pshufb  %xmm8, %xmm2
    movdqu  %xmm1,   (%rdi)
    movdqu  %xmm2, 16(%rdi)
9:
    REST_XMM
    EPILOG
    ret

// ======================================================================================================
//   SHA-256 / SHA-512 without SHA-NI — SIMD message schedule + scalar rounds
// ======================================================================================================
// SHA-NI covers Ice Lake and newer Intel, and Zen and newer AMD. Everything older — including this file's
// development host — has AES-NI but no SHA extensions, and x86 has NO SHA-512 instruction on any
// mainstream part at all. So both hashes also get a portable-SSE2/SSSE3 implementation, which is what
// actually runs on those machines.
//
// The design is the standard one: the message schedule is the part that vectorises (four independent
// sigma computations for SHA-256, two for SHA-512), so it is computed 4/2 words at a time into a stack
// buffer with K already folded in, and the compression rounds then run scalar out of that buffer. The
// rounds themselves are inherently serial — each depends on the previous — so there is nothing to gain
// from widening them for a single buffer.
//
// This needs only SSE2 + SSSE3 (PALIGNR/PSHUFB), which is implied by the AES-NI gate the dispatcher uses,
// so there is no separate feature bit to test. HEADROOM, deliberately not taken here: Go's blockAVX2 hashes
// TWO blocks at once in 256-bit lanes for roughly another 1.3x. That is ~1100 lines of intricate register
// juggling whose payoff only exists on multi-block inputs and only on CPUs that lack SHA-NI — a poor
// risk/reward against this, which is a few hundred lines and verified byte-for-byte.
//
// The 8-round and 4-group macro bodies exist because the register rotation has period 8 (rounds) and 4
// (schedule groups): after that many steps every register is back in its original role, so the body can be
// `.rept`ed instead of unrolled by hand. Cursors in %rax (round constants) and %r12 (the W+K buffer)
// advance instead of using compile-time offsets, which is what makes the repetition legal.

// ---- SHA-256 ----------------------------------------------------------------------------------------
// sigma0(x) = ror7 ^ ror18 ^ shr3. The two halves of each rotate are disjoint, so PXOR doubles as POR.
.macro SIGMA0_32 v, t1, t2
    movdqa \v, \t1
    psrld  $7, \t1
    movdqa \v, \t2
    pslld  $25, \t2
    por    \t2, \t1
    movdqa \v, \t2
    psrld  $18, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    pslld  $14, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psrld  $3, \t2
    pxor   \t2, \t1
    movdqa \t1, \v
.endm
// sigma1(x) = ror17 ^ ror19 ^ shr10
.macro SIGMA1_32 v, t1, t2
    movdqa \v, \t1
    psrld  $17, \t1
    movdqa \v, \t2
    pslld  $15, \t2
    por    \t2, \t1
    movdqa \v, \t2
    psrld  $19, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    pslld  $13, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psrld  $10, \t2
    pxor   \t2, \t1
    movdqa \t1, \v
.endm

// Produce W[t..t+3] in \w0, given \w0..\w3 = W[t-16..t-1], and store W+K at (%r12).
//
// W[t] = W[t-16] + sigma0(W[t-15]) + W[t-7] + sigma1(W[t-2]) — and for a 4-wide group the LAST TWO lanes
// need sigma1 of W[t] and W[t+1], which this very group produces. Hence the two-step sigma1: first add
// sigma1({W[t-2],W[t-1]}) to finalise lanes 0-1, then add sigma1 of those finished lanes into lanes 2-3.
// No lane masking is needed either time: sigma1(0) == 0 covers the first step's unused high lanes, and
// PSLLDQ $8 zeroes the low lanes in the second.
.macro SCHED256 w0, w1, w2, w3
    movdqa \w1, %xmm4
    palignr $4, \w0, %xmm4              // W[t-15..t-12]
    SIGMA0_32 %xmm4, %xmm5, %xmm7
    paddd  %xmm4, \w0
    movdqa \w3, %xmm4
    palignr $4, \w2, %xmm4              // W[t-7..t-4]
    paddd  %xmm4, \w0
    movdqa \w3, %xmm4
    psrldq $8, %xmm4                    // {W[t-2], W[t-1], 0, 0}
    SIGMA1_32 %xmm4, %xmm5, %xmm7
    paddd  %xmm4, \w0                   // lanes 0-1 final
    movdqa \w0, %xmm4
    SIGMA1_32 %xmm4, %xmm5, %xmm7
    pslldq $8, %xmm4                    // {0, 0, s1(W[t]), s1(W[t+1])}
    paddd  %xmm4, \w0                   // lanes 2-3 final
    movdqa \w0, %xmm4
    paddd  (%rax), %xmm4
    movdqu %xmm4, (%r12)
    add    $16, %rax
    add    $16, %r12
.endm
// Four groups = one full turn of the w0..w3 rotation.
.macro SCHED256_4
    SCHED256 %xmm0, %xmm1, %xmm2, %xmm3
    SCHED256 %xmm1, %xmm2, %xmm3, %xmm0
    SCHED256 %xmm2, %xmm3, %xmm0, %xmm1
    SCHED256 %xmm3, %xmm0, %xmm1, %xmm2
.endm

// One SHA-256 round. T1 accumulates into \h, which then becomes the next round's `a`; \d becomes `e`.
// maj(a,b,c) is computed as ((a|c)&b) | (a&c), one operation shorter than the three-AND form.
.macro SHA256_RND a,b,c,d,e,f,g,h, woff
    mov   \e, %r14d
    ror   $6, %r14d
    mov   \e, %r15d
    ror   $11, %r15d
    xor   %r15d, %r14d
    mov   \e, %r15d
    ror   $25, %r15d
    xor   %r15d, %r14d                  // BS1(e)
    mov   \f, %r15d
    xor   \g, %r15d
    and   \e, %r15d
    xor   \g, %r15d                     // ch(e,f,g)
    add   %r15d, %r14d
    add   \woff(%r12), %r14d            // + W[i] + K[i]
    add   %r14d, \h                     // h = T1
    add   \h, \d                        // d += T1   (new e)
    mov   \a, %r14d
    ror   $2, %r14d
    mov   \a, %r15d
    ror   $13, %r15d
    xor   %r15d, %r14d
    mov   \a, %r15d
    ror   $22, %r15d
    xor   %r15d, %r14d                  // BS0(a)
    mov   \a, %r15d
    or    \c, %r15d
    and   \b, %r15d
    mov   \a, %r13d
    and   \c, %r13d
    or    %r13d, %r15d                  // maj(a,b,c)
    add   %r15d, %r14d                  // T2
    add   %r14d, \h                     // h = T1 + T2  (new a)
.endm
// Eight rounds = one full turn of the a..h rotation.
.macro SHA256_8RND
    SHA256_RND %eax, %ebx, %ecx, %edx, %r8d, %r9d, %r10d, %r11d, 0
    SHA256_RND %r11d, %eax, %ebx, %ecx, %edx, %r8d, %r9d, %r10d, 4
    SHA256_RND %r10d, %r11d, %eax, %ebx, %ecx, %edx, %r8d, %r9d, 8
    SHA256_RND %r9d, %r10d, %r11d, %eax, %ebx, %ecx, %edx, %r8d, 12
    SHA256_RND %r8d, %r9d, %r10d, %r11d, %eax, %ebx, %ecx, %edx, 16
    SHA256_RND %edx, %r8d, %r9d, %r10d, %r11d, %eax, %ebx, %ecx, 20
    SHA256_RND %ecx, %edx, %r8d, %r9d, %r10d, %r11d, %eax, %ebx, 24
    SHA256_RND %ebx, %ecx, %edx, %r8d, %r9d, %r10d, %r11d, %eax, 28
    add   $32, %r12
.endm

// Feed-forward one digest word: H[off] += working value, read and written in Kyte's big-endian layout.
// Reading the old H back out of memory avoids having to spill the eight starting values anywhere.
.macro SHA_FF32 off, r
    mov   \off(%rdi), %r14d
    bswap %r14d
    add   %r14d, \r
    bswap \r
    mov   \r, \off(%rdi)
.endm
.macro SHA_FF64 off, r
    mov   \off(%rdi), %r14
    bswap %r14
    add   %r14, \r
    bswap \r
    mov   \r, \off(%rdi)
.endm

// void kyte_sha256_blocks_sse(uint32_t state[8], const uint8_t* data, int blocks)
//   rdi = state (H0..H7 BIG-ENDIAN), rsi = data, edx = blocks.
.globl SYM(kyte_sha256_blocks_sse)
.p2align 4
SYM(kyte_sha256_blocks_sse):
    push  %rbx
    push  %rbp
    push  %r12
    push  %r13
    push  %r14
    push  %r15
    PROLOG_3
    SAVE_XMM
    sub   $256, %rsp                    // W+K buffer, 64 dwords
    mov   %edx, %ebp                    // block counter
    cmp   $(0), %ebp
    jle   9f
    movdqa FLIP32(%rip), %xmm6
1:
    lea   K256(%rip), %rax
    mov   %rsp, %r12
    // --- W[0..15]: load, byte-swap, keep raw in xmm0..3, store W+K ---
    movdqu   (%rsi), %xmm0
    pshufb  %xmm6, %xmm0
    movdqa  %xmm0, %xmm4
    paddd   (%rax), %xmm4
    movdqu  %xmm4, (%r12)
    add     $16, %rax
    add     $16, %r12
    movdqu 16(%rsi), %xmm1
    pshufb  %xmm6, %xmm1
    movdqa  %xmm1, %xmm4
    paddd   (%rax), %xmm4
    movdqu  %xmm4, (%r12)
    add     $16, %rax
    add     $16, %r12
    movdqu 32(%rsi), %xmm2
    pshufb  %xmm6, %xmm2
    movdqa  %xmm2, %xmm4
    paddd   (%rax), %xmm4
    movdqu  %xmm4, (%r12)
    add     $16, %rax
    add     $16, %r12
    movdqu 48(%rsi), %xmm3
    pshufb  %xmm6, %xmm3
    movdqa  %xmm3, %xmm4
    paddd   (%rax), %xmm4
    movdqu  %xmm4, (%r12)
    add     $16, %rax
    add     $16, %r12
    // --- W[16..63]: 12 groups = 3 turns of 4 ---
    .rept 3
    SCHED256_4
    .endr
    // --- 64 compression rounds out of the W+K buffer ---
    mov   %rsp, %r12
    mov     (%rdi), %eax
    bswap %eax
    mov    4(%rdi), %ebx
    bswap %ebx
    mov    8(%rdi), %ecx
    bswap %ecx
    mov   12(%rdi), %edx
    bswap %edx
    mov   16(%rdi), %r8d
    bswap %r8d
    mov   20(%rdi), %r9d
    bswap %r9d
    mov   24(%rdi), %r10d
    bswap %r10d
    mov   28(%rdi), %r11d
    bswap %r11d
    .rept 8
    SHA256_8RND
    .endr
    // --- feed-forward: H += working state, read and written big-endian in place ---
    SHA_FF32  0, %eax
    SHA_FF32  4, %ebx
    SHA_FF32  8, %ecx
    SHA_FF32 12, %edx
    SHA_FF32 16, %r8d
    SHA_FF32 20, %r9d
    SHA_FF32 24, %r10d
    SHA_FF32 28, %r11d
    add   $64, %rsi
    dec   %ebp
    jnz   1b
9:
    add   $256, %rsp
    REST_XMM
    EPILOG
    pop   %r15
    pop   %r14
    pop   %r13
    pop   %r12
    pop   %rbp
    pop   %rbx
    ret

// ---- SHA-512 ----------------------------------------------------------------------------------------
// sigma0(x) = ror1 ^ ror8 ^ shr7
.macro SIGMA0_64 v, t1, t2
    movdqa \v, \t1
    psrlq  $1, \t1
    movdqa \v, \t2
    psllq  $63, \t2
    por    \t2, \t1
    movdqa \v, \t2
    psrlq  $8, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psllq  $56, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psrlq  $7, \t2
    pxor   \t2, \t1
    movdqa \t1, \v
.endm
// sigma1(x) = ror19 ^ ror61 ^ shr6
.macro SIGMA1_64 v, t1, t2
    movdqa \v, \t1
    psrlq  $19, \t1
    movdqa \v, \t2
    psllq  $45, \t2
    por    \t2, \t1
    movdqa \v, \t2
    psrlq  $61, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psllq  $3, \t2
    pxor   \t2, \t1
    movdqa \v, \t2
    psrlq  $6, \t2
    pxor   \t2, \t1
    movdqa \t1, \v
.endm

// Produce W[t..t+1] in \w0 given the eight registers holding W[t-16..t-1] (two words each), and store W+K.
// Unlike SHA-256 there is NO intra-group dependency: with only two lanes, sigma1's inputs W[t-2] and
// W[t-1] are both already final — they are exactly \w7. That makes this the simpler of the two.
.macro SCHED512 w0, w1, w4, w5, w7
    movdqa \w1, %xmm8
    palignr $8, \w0, %xmm8              // {W[t-15], W[t-14]}
    SIGMA0_64 %xmm8, %xmm9, %xmm10
    paddq  %xmm8, \w0
    movdqa \w5, %xmm8
    palignr $8, \w4, %xmm8              // {W[t-7], W[t-6]}
    paddq  %xmm8, \w0
    movdqa \w7, %xmm8                   // {W[t-2], W[t-1]}
    SIGMA1_64 %xmm8, %xmm9, %xmm10
    paddq  %xmm8, \w0
    movdqa \w0, %xmm8
    paddq  (%rax), %xmm8
    movdqu %xmm8, (%r12)
    add    $16, %rax
    add    $16, %r12
.endm
// Eight groups = one full turn of the w0..w7 rotation.
.macro SCHED512_8
    SCHED512 %xmm0, %xmm1, %xmm4, %xmm5, %xmm7
    SCHED512 %xmm1, %xmm2, %xmm5, %xmm6, %xmm0
    SCHED512 %xmm2, %xmm3, %xmm6, %xmm7, %xmm1
    SCHED512 %xmm3, %xmm4, %xmm7, %xmm0, %xmm2
    SCHED512 %xmm4, %xmm5, %xmm0, %xmm1, %xmm3
    SCHED512 %xmm5, %xmm6, %xmm1, %xmm2, %xmm4
    SCHED512 %xmm6, %xmm7, %xmm2, %xmm3, %xmm5
    SCHED512 %xmm7, %xmm0, %xmm3, %xmm4, %xmm6
.endm

.macro SHA512_RND a,b,c,d,e,f,g,h, woff
    mov   \e, %r14
    ror   $14, %r14
    mov   \e, %r15
    ror   $18, %r15
    xor   %r15, %r14
    mov   \e, %r15
    ror   $41, %r15
    xor   %r15, %r14                    // BS1(e)
    mov   \f, %r15
    xor   \g, %r15
    and   \e, %r15
    xor   \g, %r15                      // ch(e,f,g)
    add   %r15, %r14
    add   \woff(%r12), %r14             // + W[i] + K[i]
    add   %r14, \h                      // h = T1
    add   \h, \d                        // d += T1   (new e)
    mov   \a, %r14
    ror   $28, %r14
    mov   \a, %r15
    ror   $34, %r15
    xor   %r15, %r14
    mov   \a, %r15
    ror   $39, %r15
    xor   %r15, %r14                    // BS0(a)
    mov   \a, %r15
    or    \c, %r15
    and   \b, %r15
    mov   \a, %r13
    and   \c, %r13
    or    %r13, %r15                    // maj(a,b,c)
    add   %r15, %r14                    // T2
    add   %r14, \h                      // h = T1 + T2  (new a)
.endm
.macro SHA512_8RND
    SHA512_RND %rax, %rbx, %rcx, %rdx, %r8, %r9, %r10, %r11, 0
    SHA512_RND %r11, %rax, %rbx, %rcx, %rdx, %r8, %r9, %r10, 8
    SHA512_RND %r10, %r11, %rax, %rbx, %rcx, %rdx, %r8, %r9, 16
    SHA512_RND %r9, %r10, %r11, %rax, %rbx, %rcx, %rdx, %r8, 24
    SHA512_RND %r8, %r9, %r10, %r11, %rax, %rbx, %rcx, %rdx, 32
    SHA512_RND %rdx, %r8, %r9, %r10, %r11, %rax, %rbx, %rcx, 40
    SHA512_RND %rcx, %rdx, %r8, %r9, %r10, %r11, %rax, %rbx, 48
    SHA512_RND %rbx, %rcx, %rdx, %r8, %r9, %r10, %r11, %rax, 56
    add   $64, %r12
.endm

// Load message quadword pair \n into \w, byte-swapped from big-endian, and store W+K.
.macro LDW512 w, off
    movdqu \off(%rsi), \w
    pshufb %xmm11, \w
    movdqa \w, %xmm8
    paddq  (%rax), %xmm8
    movdqu %xmm8, (%r12)
    add    $16, %rax
    add    $16, %r12
.endm

// void kyte_sha512_blocks_sse(uint64_t state[8], const uint8_t* data, int blocks)
//   rdi = state (H0..H7 BIG-ENDIAN), rsi = data (128-byte blocks), edx = blocks.
// SHA-384 shares this compression exactly; only the IV and the truncation differ, and both are the
// caller's business.
.globl SYM(kyte_sha512_blocks_sse)
.p2align 4
SYM(kyte_sha512_blocks_sse):
    push  %rbx
    push  %rbp
    push  %r12
    push  %r13
    push  %r14
    push  %r15
    PROLOG_3
    SAVE_XMM
    sub   $640, %rsp                    // W+K buffer, 80 quadwords
    mov   %edx, %ebp
    cmp   $(0), %ebp
    jle   9f
    movdqa FLIP64(%rip), %xmm11
1:
    lea   K512(%rip), %rax
    mov   %rsp, %r12
    LDW512 %xmm0,   0
    LDW512 %xmm1,  16
    LDW512 %xmm2,  32
    LDW512 %xmm3,  48
    LDW512 %xmm4,  64
    LDW512 %xmm5,  80
    LDW512 %xmm6,  96
    LDW512 %xmm7, 112
    // W[16..79]: 32 groups = 4 turns of 8
    .rept 4
    SCHED512_8
    .endr
    mov   %rsp, %r12
    mov     (%rdi), %rax
    bswap %rax
    mov    8(%rdi), %rbx
    bswap %rbx
    mov   16(%rdi), %rcx
    bswap %rcx
    mov   24(%rdi), %rdx
    bswap %rdx
    mov   32(%rdi), %r8
    bswap %r8
    mov   40(%rdi), %r9
    bswap %r9
    mov   48(%rdi), %r10
    bswap %r10
    mov   56(%rdi), %r11
    bswap %r11
    .rept 10
    SHA512_8RND
    .endr
    SHA_FF64  0, %rax
    SHA_FF64  8, %rbx
    SHA_FF64 16, %rcx
    SHA_FF64 24, %rdx
    SHA_FF64 32, %r8
    SHA_FF64 40, %r9
    SHA_FF64 48, %r10
    SHA_FF64 56, %r11
    add   $128, %rsi
    dec   %ebp
    jnz   1b
9:
    add   $640, %rsp
    REST_XMM
    EPILOG
    pop   %r15
    pop   %r14
    pop   %r13
    pop   %r12
    pop   %rbp
    pop   %rbx
    ret

// ======================================================================================================
//   ChaCha20 (RFC 8439)
// ======================================================================================================
// void kyte_chacha20_xor_sse(const uint8_t* key, uint32_t counter, const uint8_t* nonce,
//                            const uint8_t* in, int len, uint8_t* out)
//   rdi=key(32B) esi=counter(base block index) rdx=nonce(12B) rcx=in r8d=len r9=out
//
// The arm64 twin uses the WORD layout — 16 vectors, each holding one state word across four blocks — so a
// quarter-round is pure lane-wise arithmetic with no shuffles. That needs 17 vector registers and x86 has
// 16, so this uses the ROW layout instead: four registers hold one block's four rows, and the diagonal
// round is reached by rotating rows 1/2/3 by one/two/three lanes (PSHUFD) and rotating back afterwards.
// Two blocks are kept in flight for instruction-level parallelism.
//
// The two cheap rotates are PSHUFB byte shuffles (rotl16 and rotl8 are byte permutations); rotl12 and
// rotl7 are not, and take the shift/shift/or with a scratch register.
//
// Contract note: `len` is a multiple of 256 in every real caller (the pure-Kyte tail handles the rest),
// but this accepts any multiple of 64 — the 64-byte remainder path costs nothing and removes a footgun.

.macro CC_ROTL v, n, t
    movdqa \v, \t
    pslld  $\n, \v
    psrld  $(32-\n), \t
    por    \t, \v
.endm
// One ChaCha quarter-round, applied lane-wise to TWO independent blocks at once.
.macro CC_QR a1,b1,c1,d1, a2,b2,c2,d2
    paddd  \b1, \a1
    paddd  \b2, \a2
    pxor   \a1, \d1
    pxor   \a2, \d2
    pshufb %xmm10, \d1
    pshufb %xmm10, \d2
    paddd  \d1, \c1
    paddd  \d2, \c2
    pxor   \c1, \b1
    pxor   \c2, \b2
    CC_ROTL \b1, 12, %xmm8
    CC_ROTL \b2, 12, %xmm9
    paddd  \b1, \a1
    paddd  \b2, \a2
    pxor   \a1, \d1
    pxor   \a2, \d2
    pshufb %xmm11, \d1
    pshufb %xmm11, \d2
    paddd  \d1, \c1
    paddd  \d2, \c2
    pxor   \c1, \b1
    pxor   \c2, \b2
    CC_ROTL \b1, 7, %xmm8
    CC_ROTL \b2, 7, %xmm9
.endm
// The 20 rounds, as 10 column+diagonal double-rounds, on both blocks.
.macro CC_ROUNDS
    mov    $10, %eax
101:
    CC_QR  %xmm0,%xmm1,%xmm2,%xmm3, %xmm4,%xmm5,%xmm6,%xmm7
    pshufd $(0x39), %xmm1, %xmm1          // diagonalise: rows 1/2/3 rotate by 1/2/3 lanes
    pshufd $(0x4e), %xmm2, %xmm2
    pshufd $(0x93), %xmm3, %xmm3
    pshufd $(0x39), %xmm5, %xmm5
    pshufd $(0x4e), %xmm6, %xmm6
    pshufd $(0x93), %xmm7, %xmm7
    CC_QR  %xmm0,%xmm1,%xmm2,%xmm3, %xmm4,%xmm5,%xmm6,%xmm7
    pshufd $(0x93), %xmm1, %xmm1          // and back
    pshufd $(0x4e), %xmm2, %xmm2
    pshufd $(0x39), %xmm3, %xmm3
    pshufd $(0x93), %xmm5, %xmm5
    pshufd $(0x4e), %xmm6, %xmm6
    pshufd $(0x39), %xmm7, %xmm7
    dec    %eax
    jnz    101b
    paddd  %xmm12, %xmm0                // += initial state
    paddd  %xmm13, %xmm1
    paddd  %xmm14, %xmm2
    movdqu 16(%rsp), %xmm8
    paddd  %xmm8, %xmm3
    paddd  %xmm12, %xmm4
    paddd  %xmm13, %xmm5
    paddd  %xmm14, %xmm6
    movdqu 32(%rsp), %xmm8
    paddd  %xmm8, %xmm7
.endm
// Set up both blocks' state. Rows 0-2 (constants + key) are identical for every block and live in
// xmm12-14; only row 3 carries the counter, so it is rebuilt from the stack template each iteration and
// stashed there for the post-round add (there is no seventeenth register to hold it in).
.macro CC_SETUP
    mov    %esi, 0(%rsp)
    movdqu (%rsp), %xmm3
    movdqu %xmm3, 16(%rsp)
    lea    1(%rsi), %eax
    mov    %eax, 0(%rsp)
    movdqu (%rsp), %xmm7
    movdqu %xmm7, 32(%rsp)
    movdqa %xmm12, %xmm0
    movdqa %xmm13, %xmm1
    movdqa %xmm14, %xmm2
    movdqa %xmm12, %xmm4
    movdqa %xmm13, %xmm5
    movdqa %xmm14, %xmm6
.endm

.globl SYM(kyte_chacha20_xor_sse)
.p2align 4
SYM(kyte_chacha20_xor_sse):
    PROLOG_6
    SAVE_XMM
    sub    $48, %rsp                    // [0..15] row-3 template, [16..31] initA3, [32..47] initB3
    cmp    $(0), %r8d
    jle    9f
    movdqa CC_CONST(%rip), %xmm12
    movdqu   (%rdi), %xmm13             // key[0..15]
    movdqu 16(%rdi), %xmm14             // key[16..31]
    movdqa ROT16(%rip), %xmm10
    movdqa ROT8(%rip), %xmm11
    // Build the row-3 template as {counter, n0, n1, n2}. The nonce is only 12 bytes, so it is read as
    // 8+4 rather than one MOVDQU — a 16-byte load would run off the end of the caller's buffer.
    mov     (%rdx), %rax
    mov    %rax, 4(%rsp)
    mov    8(%rdx), %eax
    mov    %eax, 12(%rsp)
1:
    cmp    $128, %r8d
    jl     5f
    CC_SETUP
    CC_ROUNDS
    movdqu    0(%rcx), %xmm8; pxor %xmm8, %xmm0; movdqu %xmm0,   0(%r9)
    movdqu   16(%rcx), %xmm8; pxor %xmm8, %xmm1; movdqu %xmm1,  16(%r9)
    movdqu   32(%rcx), %xmm8; pxor %xmm8, %xmm2; movdqu %xmm2,  32(%r9)
    movdqu   48(%rcx), %xmm8; pxor %xmm8, %xmm3; movdqu %xmm3,  48(%r9)
    movdqu   64(%rcx), %xmm8; pxor %xmm8, %xmm4; movdqu %xmm4,  64(%r9)
    movdqu   80(%rcx), %xmm8; pxor %xmm8, %xmm5; movdqu %xmm5,  80(%r9)
    movdqu   96(%rcx), %xmm8; pxor %xmm8, %xmm6; movdqu %xmm6,  96(%r9)
    movdqu  112(%rcx), %xmm8; pxor %xmm8, %xmm7; movdqu %xmm7, 112(%r9)
    add    $128, %rcx
    add    $128, %r9
    add    $2, %esi
    sub    $128, %r8d
    jmp    1b
5:
    // 64-byte remainder: run the same two-block body and keep only block A.
    cmp    $64, %r8d
    jl     9f
    CC_SETUP
    CC_ROUNDS
    movdqu    0(%rcx), %xmm8; pxor %xmm8, %xmm0; movdqu %xmm0,  0(%r9)
    movdqu   16(%rcx), %xmm8; pxor %xmm8, %xmm1; movdqu %xmm1, 16(%r9)
    movdqu   32(%rcx), %xmm8; pxor %xmm8, %xmm2; movdqu %xmm2, 32(%r9)
    movdqu   48(%rcx), %xmm8; pxor %xmm8, %xmm3; movdqu %xmm3, 48(%r9)
    add    $64, %rcx
    add    $64, %r9
    inc    %esi
    sub    $64, %r8d
    jmp    5b
9:
    add    $48, %rsp
    REST_XMM
    EPILOG
    ret

// ======================================================================================================
//   Poly1305 (donna64: three 44/44/42-bit limbs)
// ======================================================================================================
// state = 8 u64: [r0, r1, r2, s1, s2, h0, h1, h2] at offsets 0,8,16,24,32,40,48,56, exactly as the arm64
// twin and as Poly1305.create lays it out (s1 = r1*20, s2 = r2*20 are the pre-folded reduction constants).
//
// This is pure 64-bit integer work — no vector unit is involved and no CPU feature beyond baseline x86_64
// is needed, so unlike the other routines here it has no feature gate of its own. MUL is used rather than
// MULX so that the code runs on pre-Haswell parts too; MULX would save the RAX/RDX shuffling but buys
// nothing on any machine where the AES-NI gate is already the binding constraint.
//
// Register map, which is exactly full: rbx=r0 rbp=r1 r12=r2 r13=s1 r14=s2, r8/r9/r10 = h0/h1/h2,
// r11/r15 = the 128-bit product accumulator, rcx = the inter-limb carry, rax/rdx = MUL's fixed operands.
// The loop counter therefore has to live on the stack, and so do the new h limbs: d1 and d2 are both
// computed from the ORIGINAL h, so h0..h2 cannot be overwritten until all three products are done.

// Fold one 16-byte message block (t0 = rax, t1 = rdx) into h, then multiply by r and reduce.
// \hibit = 1 for a full block (the implicit 2^128 bit), 0 for the length-padded final block.
.macro POLY_BLOCK hibit
    mov    %rax, %r11
    and    MASK44(%rip), %r11
    add    %r11, %r8                    // h0 += t0 & M44
    mov    %rax, %r11
    shr    $44, %r11
    mov    %rdx, %r15
    shl    $20, %r15
    or     %r15, %r11
    and    MASK44(%rip), %r11
    add    %r11, %r9                    // h1 += ((t0>>44)|(t1<<20)) & M44
    mov    %rdx, %r11
    shr    $24, %r11
    and    MASK42(%rip), %r11
    .if \hibit
    bts    $40, %r11                    // the 2^128 bit, in limb terms
    .endif
    add    %r11, %r10                   // h2 += ...
    // d0 = h0*r0 + h1*s2 + h2*s1
    mov    %r8, %rax
    mul    %rbx
    mov    %rax, %r11
    mov    %rdx, %r15
    mov    %r9, %rax
    mul    %r14
    add    %rax, %r11
    adc    %rdx, %r15
    mov    %r10, %rax
    mul    %r13
    add    %rax, %r11
    adc    %rdx, %r15
    mov    %r11, %rcx
    shrd   $44, %r15, %rcx              // carry out (d0 < 2^108, so 64 bits is enough)
    and    MASK44(%rip), %r11
    mov    %r11, 0(%rsp)                // new h0, parked until h0..h2 are no longer needed
    // d1 = h0*r1 + h1*r0 + h2*s2 + carry
    mov    %r8, %rax
    mul    %rbp
    mov    %rax, %r11
    mov    %rdx, %r15
    mov    %r9, %rax
    mul    %rbx
    add    %rax, %r11
    adc    %rdx, %r15
    mov    %r10, %rax
    mul    %r14
    add    %rax, %r11
    adc    %rdx, %r15
    add    %rcx, %r11
    adc    $(0), %r15
    mov    %r11, %rcx
    shrd   $44, %r15, %rcx
    and    MASK44(%rip), %r11
    mov    %r11, 8(%rsp)                // new h1
    // d2 = h0*r2 + h1*r1 + h2*r0 + carry
    mov    %r8, %rax
    mul    %r12
    mov    %rax, %r11
    mov    %rdx, %r15
    mov    %r9, %rax
    mul    %rbp
    add    %rax, %r11
    adc    %rdx, %r15
    mov    %r10, %rax
    mul    %rbx
    add    %rax, %r11
    adc    %rdx, %r15
    add    %rcx, %r11
    adc    $(0), %r15
    mov    %r11, %rcx
    shrd   $42, %r15, %rcx
    and    MASK42(%rip), %r11
    mov    %r11, %r10                   // h2
    // The 2^130 overflow wraps back in as *5 (mod 2^130-5), then one more carry into h1.
    mov    0(%rsp), %r8
    lea    (%rcx,%rcx,4), %rax
    add    %rax, %r8
    mov    %r8, %rax
    shr    $44, %rax
    and    MASK44(%rip), %r8
    mov    8(%rsp), %r9
    add    %rax, %r9
.endm

// Load the five key limbs and the running accumulator into registers.
.macro POLY_LOAD
    mov      (%rdi), %rbx               // r0
    mov     8(%rdi), %rbp               // r1
    mov    16(%rdi), %r12               // r2
    mov    24(%rdi), %r13               // s1
    mov    32(%rdi), %r14               // s2
    mov    40(%rdi), %r8                // h0
    mov    48(%rdi), %r9                // h1
    mov    56(%rdi), %r10               // h2
.endm
.macro POLY_STORE
    mov    %r8,  40(%rdi)
    mov    %r9,  48(%rdi)
    mov    %r10, 56(%rdi)
.endm
.macro POLY_PROLOG
    push   %rbx
    push   %rbp
    push   %r12
    push   %r13
    push   %r14
    push   %r15
.endm
.macro POLY_EPILOG
    pop    %r15
    pop    %r14
    pop    %r13
    pop    %r12
    pop    %rbp
    pop    %rbx
.endm

// void kyte_poly1305_blocks_x64(uint64_t state[8], const uint8_t* data, int nblocks)
//   rdi=state rsi=data edx=nblocks. Absorbs nblocks FULL 16-byte blocks; r/s are read-only, h updated.
//   This is the hot path — one call per AEAD record.
// PROLOG_n must run BEFORE the callee-saved pushes: on Win64 it reads stack arguments at fixed offsets
// that assume only its own two pushes have happened. The epilogues therefore unwind in the mirror order.
.globl SYM(kyte_poly1305_blocks_x64)
.p2align 4
SYM(kyte_poly1305_blocks_x64):
    PROLOG_3
    POLY_PROLOG
    sub    $32, %rsp                    // [0]=new h0, [8]=new h1, [16]=block counter
    mov    %edx, 16(%rsp)
    cmp    $(0), %edx
    jle    9f
    POLY_LOAD
1:
    mov      (%rsi), %rax
    mov     8(%rsi), %rdx
    add    $16, %rsi
    POLY_BLOCK 1
    decl   16(%rsp)
    jnz    1b
    POLY_STORE
9:
    add    $32, %rsp
    POLY_EPILOG
    EPILOG
    ret

// void kyte_poly1305_finish_x64(uint64_t state[8], const uint8_t* tail, int taillen, uint8_t* out16,
//                               uint64_t padLo, uint64_t padHi)
//   Absorbs the padded final block if taillen > 0 (a 0x01 byte after the data, and NO 2^128 bit — the
//   pad byte plays that role), then fully carries, does the constant-time "subtract 2^130-5 if it fits"
//   select, serialises to 128 bits and adds the key pad.
.globl SYM(kyte_poly1305_finish_x64)
.p2align 4
SYM(kyte_poly1305_finish_x64):
    PROLOG_6
    POLY_PROLOG
    sub    $64, %rsp                    // [0]=new h0 [8]=new h1 [16..31]=padded tail [32]=out [40]=padLo [48]=padHi
    // out/padLo/padHi arrive in rcx/r8/r9, all three of which this routine needs for other things
    // (POLY_BLOCK uses rcx as its carry; r8/r9 are h0/h1). Park them before POLY_LOAD.
    mov    %rcx, 32(%rsp)
    mov    %r8,  40(%rsp)
    mov    %r9,  48(%rsp)
    POLY_LOAD
    cmp    $(0), %edx
    jle    2f
    // Padded final block: taillen bytes, then a 0x01 byte, then zeros. The 0x01 replaces the 2^128 bit,
    // which is why POLY_BLOCK is invoked with hibit = 0 here.
    movq   $(0), 16(%rsp)
    movq   $(0), 24(%rsp)
    xor    %eax, %eax
11:
    cmp    %edx, %eax
    jge    12f
    movzbl (%rsi,%rax), %r11d
    movb   %r11b, 16(%rsp,%rax)
    inc    %eax
    jmp    11b
12:
    movb   $1, 16(%rsp,%rax)
    mov    16(%rsp), %rax
    mov    24(%rsp), %rdx
    POLY_BLOCK 0
2:
    // Full carry chain.
    mov    %r9, %rax
    shr    $44, %rax
    and    MASK44(%rip), %r9
    add    %rax, %r10
    mov    %r10, %rax
    shr    $42, %rax
    and    MASK42(%rip), %r10
    lea    (%rax,%rax,4), %rax
    add    %rax, %r8
    mov    %r8, %rax
    shr    $44, %rax
    and    MASK44(%rip), %r8
    add    %rax, %r9
    // g = h - (2^130-5), computed as h + 5 in limb form. Keep g only if it did not borrow, selected
    // branch-free from the sign of g2 so the timing does not depend on the accumulator.
    lea    5(%r8), %r11
    mov    %r11, %rax
    shr    $44, %rax
    and    MASK44(%rip), %r11            // g0
    lea    (%r9,%rax), %r15
    mov    %r15, %rax
    shr    $44, %rax
    and    MASK44(%rip), %r15            // g1
    lea    (%r10,%rax), %rdx
    mov    $1, %rax
    shl    $42, %rax
    sub    %rax, %rdx                    // g2 = h2 + carry - 2^42
    mov    %rdx, %rax
    sar    $63, %rax                     // all-ones if g2 went negative (h < 2^130-5, so keep h)
    not    %rax                          // all-ones when g is the value to keep
    and    %rax, %r11
    and    %rax, %r15
    and    %rax, %rdx
    not    %rax
    and    %rax, %r8
    and    %rax, %r9
    and    %rax, %r10
    or     %r11, %r8
    or     %r15, %r9
    or     %rdx, %r10
    // Collapse 3x44 limbs into 128 bits, add the key pad, store.
    mov    %r9, %r11
    shl    $44, %r11
    or     %r8, %r11                     // lo = h0 | h1<<44
    mov    %r9, %r15
    shr    $20, %r15
    mov    %r10, %rax
    shl    $24, %rax
    or     %rax, %r15                    // hi = h1>>20 | h2<<24
    add    40(%rsp), %r11
    adc    48(%rsp), %r15
    mov    32(%rsp), %rcx                // out
    mov    %r11,  (%rcx)
    mov    %r15, 8(%rcx)
    add    $64, %rsp
    POLY_EPILOG
    EPILOG
    ret

// ======================================================================================================
//   Read-only constants
// ======================================================================================================
// Mach-O has no `.rodata`; its read-only data section is __TEXT,__const. ELF and COFF both take the
// ELF spelling from the integrated assembler.
#if defined(__APPLE__)
.section __TEXT,__const
#else
.section .rodata
#endif
.p2align 4
// GF(2^128) reduction constant, both lanes, so PCLMULQDQ $(0x00) and $(0x11) can each pick it up.
POLY87:  .quad 0x87, 0x87
MASK0F:  .quad 0x0f0f0f0f0f0f0f0f, 0x0f0f0f0f0f0f0f0f
// BREV_LO[n] = n with its 4 bits reversed. BREV_HI[n] = the same, shifted into the high nibble.
BREV_LO: .byte 0x0,0x8,0x4,0xc,0x2,0xa,0x6,0xe,0x1,0x9,0x5,0xd,0x3,0xb,0x7,0xf
BREV_HI: .byte 0x00,0x80,0x40,0xc0,0x20,0xa0,0x60,0xe0,0x10,0x90,0x50,0xd0,0x30,0xb0,0x70,0xf0
// Byte-reverse within each 32-bit lane: converts Kyte's big-endian digest words and the big-endian SHA-256
// message words to native u32 and back. (The arm64 twin spells this REV32.)
.p2align 4
FLIP32:  .byte 3,2,1,0, 7,6,5,4, 11,10,9,8, 15,14,13,12
.p2align 6
K256:
    .long 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
    .long 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    .long 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
    .long 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    .long 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
    .long 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    .long 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
    .long 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    .long 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
    .long 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    .long 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
    .long 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    .long 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
    .long 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    .long 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
    .long 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
// Byte-reverse within each 64-bit lane, for SHA-512's big-endian digest and message words.
.p2align 4
FLIP64:  .byte 7,6,5,4,3,2,1,0, 15,14,13,12,11,10,9,8
// ChaCha20: the "expand 32-byte k" constants, and the two rotates that are byte permutations.
.p2align 4
CC_CONST: .long 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
ROT16:    .byte 2,3,0,1, 6,7,4,5, 10,11,8,9, 14,15,12,13
ROT8:     .byte 3,0,1,2, 7,4,5,6, 11,8,9,10, 15,12,13,14
// Poly1305 limb masks (44 and 42 bits); too wide for an immediate, so they live here.
.p2align 3
MASK44:  .quad 0x00000fffffffffff
MASK42:  .quad 0x000003ffffffffff
.p2align 6
K512:
    .quad 0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc
    .quad 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118
    .quad 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2
    .quad 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694
    .quad 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65
    .quad 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5
    .quad 0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4
    .quad 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70
    .quad 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df
    .quad 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b
    .quad 0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30
    .quad 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8
    .quad 0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8
    .quad 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3
    .quad 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec
    .quad 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b
    .quad 0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178
    .quad 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b
    .quad 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c
    .quad 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817

#endif // __x86_64__
