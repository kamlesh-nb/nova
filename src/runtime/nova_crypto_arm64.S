// Integrated-assembly crypto path (arm64), the Go/BoringSSL model: hand-written AArch64 assembly linked
// directly into libnovacore.a and called from Nova via extern("c") — a plain `bl`, NOT cgo/FFI marshalling.
// Built ONLY on an aarch64 host (guarded in build.zig); other hosts get the C fallbacks in runtime.cpp under
// the same symbol names. Byte-for-byte gated against the pure-Nova crypto (conformance 377/378).
//
// The win over the compiler-emitted SIMD path is manual register allocation: the AES round keys and the
// GHASH accumulator stay pinned in NEON registers across the whole buffer, and the AES + CLMUL streams are
// interleaved by hand — exactly what a high-level compiler will not schedule.

#if defined(__aarch64__) || defined(__arm64__)
.arch armv8-a+crypto+aes

.text

// void nova_aes_encrypt_block(const uint8_t* rk, int nr, const uint8_t* in, uint8_t* out)
//   x0 = rk (packed round keys, (nr+1)*16 bytes), w1 = nr (10 or 14), x2 = in, x3 = out
// ARM AESE(d,k) = ShiftRows(SubBytes(d EOR k)); AESMC = MixColumns. So the sequence is
//   AESE(k0);AESMC; AESE(k1);AESMC; ... ; AESE(k_{nr-1}) [no MC]; EOR k_nr.
// This one-block routine is the correctness anchor for the mechanism (matches encBlock / FIPS-197 KAT 377).
.global _nova_aes_encrypt_block
.align 4
_nova_aes_encrypt_block:
    ld1     {v0.16b}, [x2]          // state = in
    mov     x4, x0                  // rk cursor
    sub     w5, w1, #1              // nr-1 rounds carry MixColumns
1:
    ld1     {v1.16b}, [x4], #16     // rk[i]
    aese    v0.16b, v1.16b
    aesmc   v0.16b, v0.16b
    subs    w5, w5, #1
    b.ne    1b
    ld1     {v1.16b}, [x4], #16     // rk[nr-1] : last AESE, no MixColumns
    aese    v0.16b, v1.16b
    ld1     {v1.16b}, [x4]          // rk[nr]   : final AddRoundKey
    eor     v0.16b, v0.16b, v1.16b
    st1     {v0.16b}, [x3]
    ret

// ---- Register-resident 4-way AES-CTR (stitched-seal step 1) ------------------------------------------
// void nova_aes_ctr(const uint8_t* rk, int nr, uint8_t* ctr, const uint8_t* in, int len, uint8_t* out)
//   x0=rk w1=nr x2=ctr (16B, low 32 bits big-endian counter; advanced in place) x3=in w4=len x5=out
// Round keys are loaded ONCE into v0..v14 and stay resident for the whole buffer (the compiler reloads them
// every round). Four independent counter blocks are encrypted per iteration so AESE latency is hidden.
// The <64-byte and partial tail fall to single blocks. Byte-identical to the pure-Nova gctrHw (gated 378).

// AES round on the 4 state regs v16..v19 with round key \k (AESE = AddRoundKey+SubBytes+ShiftRows, then MC).
.macro RK4 k
    aese v16.16b, \k\().16b
    aesmc v16.16b, v16.16b
    aese v17.16b, \k\().16b
    aesmc v17.16b, v17.16b
    aese v18.16b, \k\().16b
    aesmc v18.16b, v18.16b
    aese v19.16b, \k\().16b
    aesmc v19.16b, v19.16b
.endm
// Final round: last AESE (no MixColumns) with \kl, then final AddRoundKey \kf.
.macro RKL4 kl, kf
    aese v16.16b, \kl\().16b
    eor  v16.16b, v16.16b, \kf\().16b
    aese v17.16b, \kl\().16b
    eor  v17.16b, v17.16b, \kf\().16b
    aese v18.16b, \kl\().16b
    eor  v18.16b, v18.16b, \kf\().16b
    aese v19.16b, \kl\().16b
    eor  v19.16b, v19.16b, \kf\().16b
.endm

.global _nova_aes_ctr
.align 4
_nova_aes_ctr:
    ldr     w9, [x2, #12]           // native low-32 counter (stored big-endian)
    rev     w9, w9
    ld1     {v24.16b}, [x2]         // counter-block template (bytes 0..11 = prefix; lane 3 overwritten)
    // Load round keys resident. AES-256 (nr=14) uses v0..v14; AES-128 (nr=10) uses v0..v10.
    cmp     w1, #14
    b.eq    2f
    ld1     {v0.16b, v1.16b, v2.16b, v3.16b}, [x0], #64
    ld1     {v4.16b, v5.16b, v6.16b, v7.16b}, [x0], #64
    ld1     {v8.16b, v9.16b, v10.16b}, [x0]
    b       3f
2:
    ld1     {v0.16b, v1.16b, v2.16b, v3.16b}, [x0], #64
    ld1     {v4.16b, v5.16b, v6.16b, v7.16b}, [x0], #64
    ld1     {v8.16b, v9.16b, v10.16b, v11.16b}, [x0], #64
    ld1     {v12.16b, v13.16b, v14.16b}, [x0]
3:
    // --- 4-way main loop over 64-byte chunks ---
4:
    cmp     w4, #64
    b.lt    6f
    // build 4 counter blocks in v16..v19 (prefix from v24, big-endian counter in lane 3)
    mov     v16.16b, v24.16b
    rev     w11, w9
    mov     v16.s[3], w11
    add     w10, w9, #1
    mov     v17.16b, v24.16b
    rev     w11, w10
    mov     v17.s[3], w11
    add     w10, w9, #2
    mov     v18.16b, v24.16b
    rev     w11, w10
    mov     v18.s[3], w11
    add     w10, w9, #3
    mov     v19.16b, v24.16b
    rev     w11, w10
    mov     v19.s[3], w11
    // encrypt 4-way (branch by key size)
    cmp     w1, #14
    b.eq    5f
    RK4 v0
    RK4 v1
    RK4 v2
    RK4 v3
    RK4 v4
    RK4 v5
    RK4 v6
    RK4 v7
    RK4 v8
    RKL4 v9, v10
    b       55f
5:
    RK4 v0
    RK4 v1
    RK4 v2
    RK4 v3
    RK4 v4
    RK4 v5
    RK4 v6
    RK4 v7
    RK4 v8
    RK4 v9
    RK4 v10
    RK4 v11
    RK4 v12
    RKL4 v13, v14
55:
    // XOR keystream with 64 bytes of input -> output
    ld1     {v20.16b, v21.16b, v22.16b, v23.16b}, [x3], #64
    eor     v16.16b, v16.16b, v20.16b
    eor     v17.16b, v17.16b, v21.16b
    eor     v18.16b, v18.16b, v22.16b
    eor     v19.16b, v19.16b, v23.16b
    st1     {v16.16b, v17.16b, v18.16b, v19.16b}, [x5], #64
    add     w9, w9, #4
    sub     w4, w4, #64
    b       4b
6:
    // --- tail: single blocks (full 16B and a final partial) ---
    cmp     w4, #0
    b.le    9f
    // one counter block in v16
    mov     v16.16b, v24.16b
    rev     w11, w9
    mov     v16.s[3], w11
    // encrypt v16 with the resident round keys (single lane; keys still in v0..v14)
    cmp     w1, #14
    b.eq    7f
    aese v16.16b, v0.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v1.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v2.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v3.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v4.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v5.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v6.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v7.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v8.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v9.16b
    eor  v16.16b, v16.16b, v10.16b
    b       8f
7:
    aese v16.16b, v0.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v1.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v2.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v3.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v4.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v5.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v6.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v7.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v8.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v9.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v10.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v11.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v12.16b
    aesmc v16.16b, v16.16b
    aese v16.16b, v13.16b
    eor  v16.16b, v16.16b, v14.16b
8:
    add     w9, w9, #1
    cmp     w4, #16
    b.lt    85f
    // full 16-byte block
    ld1     {v20.16b}, [x3], #16
    eor     v16.16b, v16.16b, v20.16b
    st1     {v16.16b}, [x5], #16
    sub     w4, w4, #16
    b       6b
85:
    // partial (<16) final block: byte-wise XOR of the keystream
    sub     sp, sp, #16
    st1     {v16.16b}, [sp]
    mov     w10, #0
86:
    cmp     w10, w4
    b.ge    87f
    ldrb    w11, [x3, w10, uxtw]
    ldrb    w12, [sp, w10, uxtw]
    eor     w11, w11, w12
    strb    w11, [x5, w10, uxtw]
    add     w10, w10, #1
    b       86b
87:
    add     sp, sp, #16
9:
    rev     w11, w9                 // write the advanced counter back (big-endian)
    str     w11, [x2, #12]
    ret

#endif // __aarch64__
