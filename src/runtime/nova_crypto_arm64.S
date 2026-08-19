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

// The AArch64 PCS requires the LOW 64 bits of v8..v15 (d8..d15) to be preserved across a call. All the
// multi-register routines below use v8..v15 as round-key / scratch registers, so they must save and restore
// d8..d15 or they will silently corrupt a caller that had live values there (a latent bug the 8-way seal
// finally surfaced). 64-byte frame, 16-byte aligned.
.macro SAVE_D8_D15
    stp d8, d9,   [sp, #-64]!
    stp d10, d11, [sp, #16]
    stp d12, d13, [sp, #32]
    stp d14, d15, [sp, #48]
.endm
.macro RESTORE_D8_D15
    ldp d10, d11, [sp, #16]
    ldp d12, d13, [sp, #32]
    ldp d14, d15, [sp, #48]
    ldp d8, d9,   [sp], #64
.endm

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
    SAVE_D8_D15
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
    RESTORE_D8_D15
    ret

// ---- Register-resident GHASH (stitched-seal step 2) --------------------------------------------------
// void nova_ghash(const uint8_t* hStd, const uint8_t* data, int len, uint8_t* y)
//   x0=hStd (H in "standard" bit order, per-byte bit-reversed E_K(0)), x1=data, w2=len, x3=y (16B acc, std
//   order, in/out). Absorbs len bytes (16B blocks, final <16 zero-padded) into y: for each block X,
//   y = (y ^ bitreverse_per_byte(X)) * H  in GF(2^128) with the forward poly (constant 0x87). H and the
//   accumulator stay in NEON registers; RBIT does the per-byte reflection in ONE instruction (the thing the
//   LLVM overloaded-intrinsic path miscompiled to v8i8). Byte-identical to the pure-Nova ghUpdate (gated 378).
// The reflect-back to GCM order is done by the caller (matches ghUpdate leaving y in standard order).

// v1 = v1 * v0 mod P (both operands std-order 128-bit). Karatsuba (3 pmull) + 0x87 reduction, faithful to
// the Nova gfmul. Scratch: v4..v14. v0=H, v30=poly{0x87,0x87}, v31=0 are preserved.
.macro GFMUL
    pmull   v4.1q,  v1.1d, v0.1d        // lo = a0*b0
    pmull2  v5.1q,  v1.2d, v0.2d        // hi = a1*b1
    ext     v6.16b, v1.16b, v1.16b, #8
    eor     v6.16b, v6.16b, v1.16b      // {a0^a1, a0^a1}
    ext     v7.16b, v0.16b, v0.16b, #8
    eor     v7.16b, v7.16b, v0.16b      // {b0^b1, b0^b1}
    pmull   v6.1q,  v6.1d, v7.1d        // mid_raw = (a0^a1)*(b0^b1)
    eor     v6.16b, v6.16b, v4.16b      // mid ^= lo
    eor     v6.16b, v6.16b, v5.16b      // mid = {m0, m1}
    ext     v8.16b, v31.16b, v6.16b, #8 // {0, m0}
    eor     v8.16b, v4.16b, v8.16b      // lo128 = {p0=l0, p1=l1^m0}
    ext     v9.16b, v6.16b, v31.16b, #8 // {m1, 0}
    eor     v9.16b, v5.16b, v9.16b      // hi128 = {p2=h0^m1, p3=h1}
    pmull   v11.1q, v9.1d, v30.1d       // cp = p2*0x87 -> {c0, c1}
    pmull2  v12.1q, v9.2d, v30.2d       // dp = p3*0x87 -> {d0, d1}
    ext     v13.16b, v12.16b, v31.16b, #8 // {d1, 0}
    pmull   v13.1q, v13.1d, v30.1d      // op = d1*0x87 -> {o0, .}
    eor     v1.16b, v8.16b, v11.16b     // {p0^c0, p1^c1}
    mov     v14.d[0], v13.d[0]          // o0
    mov     v14.d[1], v12.d[0]          // d0
    eor     v1.16b, v1.16b, v14.16b     // {r0=p0^c0^o0, r1=p1^c1^d0}
.endm

// Multiply the std-order block \va by the std-order key power \vhp and XOR the UN-reduced 256-bit product
// into the accumulator {v28=lo128, v29=hi128}. Scratch v4..v9. (Karatsuba, no reduction.)
.macro MULACC va, vhp
    pmull   v4.1q,  \va\().1d, \vhp\().1d
    pmull2  v5.1q,  \va\().2d, \vhp\().2d
    ext     v6.16b, \va\().16b, \va\().16b, #8
    eor     v6.16b, v6.16b, \va\().16b
    ext     v7.16b, \vhp\().16b, \vhp\().16b, #8
    eor     v7.16b, v7.16b, \vhp\().16b
    pmull   v6.1q,  v6.1d, v7.1d
    eor     v6.16b, v6.16b, v4.16b
    eor     v6.16b, v6.16b, v5.16b
    ext     v8.16b, v31.16b, v6.16b, #8
    eor     v8.16b, v4.16b, v8.16b     // lo128 = {p0, p1}
    ext     v9.16b, v6.16b, v31.16b, #8
    eor     v9.16b, v5.16b, v9.16b     // hi128 = {p2, p3}
    eor     v28.16b, v28.16b, v8.16b
    eor     v29.16b, v29.16b, v9.16b
.endm
// Reduce the accumulated {v28=lo128, v29=hi128} mod P (0x87) into v1. Scratch v11..v14.
.macro REDUCE_ACC
    pmull   v11.1q, v29.1d, v30.1d
    pmull2  v12.1q, v29.2d, v30.2d
    ext     v13.16b, v12.16b, v31.16b, #8
    pmull   v13.1q, v13.1d, v30.1d
    eor     v1.16b, v28.16b, v11.16b
    mov     v14.d[0], v13.d[0]
    mov     v14.d[1], v12.d[0]
    eor     v1.16b, v1.16b, v14.16b
.endm

.global _nova_ghash
.align 4
_nova_ghash:
    SAVE_D8_D15
    ld1     {v0.16b}, [x0]              // H (standard order)
    ld1     {v1.16b}, [x3]             // Y (standard order)
    movi    v31.16b, #0                // ZERO
    mov     x9, #0x87
    dup     v30.2d, x9                 // poly = {0x87, 0x87}
    // 4-way key-power aggregation for buffers >= 4 blocks. GHASH reduction is GF(2)-linear, so 4 blocks'
    // un-reduced products sum and reduce ONCE: y' = (y^X0)*H^4 ^ X1*H^3 ^ X2*H^2 ^ X3*H. Precompute H^2..H^4
    // ONLY here (skipped for small AAD / length blocks, which take the single-block path below).
    cmp     w2, #64
    b.lt    10f
    mov     v2.16b, v1.16b             // save Y
    mov     v1.16b, v0.16b             // v1 = H
    GFMUL                              // v1 = H^2
    mov     v25.16b, v1.16b
    GFMUL                              // v1 = H^3
    mov     v26.16b, v1.16b
    GFMUL                              // v1 = H^4
    mov     v27.16b, v1.16b
    mov     v1.16b, v2.16b             // restore Y
20:
    cmp     w2, #64
    b.lt    10f
    ld1     {v3.16b}, [x1], #16
    rbit    v3.16b, v3.16b
    eor     v3.16b, v3.16b, v1.16b     // (X0 ^ Y)
    ld1     {v16.16b}, [x1], #16
    rbit    v16.16b, v16.16b
    ld1     {v17.16b}, [x1], #16
    rbit    v17.16b, v17.16b
    ld1     {v18.16b}, [x1], #16
    rbit    v18.16b, v18.16b
    movi    v28.16b, #0                // clear accumulator
    movi    v29.16b, #0
    MULACC  v3,  v27                   // (Y^X0) * H^4
    MULACC  v16, v26                   // X1 * H^3
    MULACC  v17, v25                   // X2 * H^2
    MULACC  v18, v0                    // X3 * H^1
    REDUCE_ACC                         // v1 = new Y
    sub     w2, w2, #64
    b       20b
10:
    cmp     w2, #16
    b.lt    12f
    ld1     {v3.16b}, [x1], #16
    rbit    v3.16b, v3.16b            // per-byte bit reverse -> standard order
    eor     v1.16b, v1.16b, v3.16b    // Y ^= X'
    GFMUL
    sub     w2, w2, #16
    b       10b
12:
    cmp     w2, #0
    b.le    14f
    // final partial block: copy w2 bytes to a zero-filled 16B stack slot, then absorb
    sub     sp, sp, #16
    stp     xzr, xzr, [sp]
    mov     w10, #0
13:
    cmp     w10, w2
    b.ge    135f
    ldrb    w11, [x1, w10, uxtw]
    strb    w11, [sp, w10, uxtw]
    add     w10, w10, #1
    b       13b
135:
    ld1     {v3.16b}, [sp]
    add     sp, sp, #16
    rbit    v3.16b, v3.16b
    eor     v1.16b, v1.16b, v3.16b
    GFMUL
14:
    st1     {v1.16b}, [x3]            // store Y (standard order; caller reflects back)
    RESTORE_D8_D15
    ret

// ---- Fused stitched seal (stitched-seal step 3b) -----------------------------------------------------
// void nova_gcm_seal(const uint8_t* rk, int nr, const uint8_t* hpows, uint8_t* ctr,
//                    const uint8_t* in, int len, uint8_t* out, uint8_t* y)
//   x0=rk w1=nr x2=hpows (64B: H,H^2,H^3,H^4 std order) x3=ctr x4=in w5=len (MULTIPLE OF 64) x6=out x7=y.
// Encrypts `in` to `out` and GHASHes the ciphertext into y IN ONE LOOP: each group's AES-CTR (4-way,
// register-resident round keys) is immediately followed by the 4-block aggregated GHASH of the ciphertext it
// just produced — so the ct never round-trips to memory for GHASH, and the OoO core overlaps this group's
// GHASH PMULLs with the next group's AES AESEs (the AES unit and PMULL unit run in parallel). The <64-byte
// and length-block tail is handled by the caller via nova_aes_ctr + nova_ghash. y in/out (std order).
// Byte-identical to the separate CTR + GHASH passes (gated 378).

// Multiply block \va by H^k (loaded from [x2, #\hpoff]) and XOR the un-reduced product into acc {v28,v29}.
// Scratch v20..v23, v26, v27, v15 — all OUTSIDE the resident round keys v0..v14 and blocks v16..v19.
.macro MULACC_LD va, hpoff
    ldr     q26, [x2, #\hpoff]
    pmull   v20.1q, \va\().1d, v26.1d
    pmull2  v21.1q, \va\().2d, v26.2d
    ext     v22.16b, \va\().16b, \va\().16b, #8
    eor     v22.16b, v22.16b, \va\().16b
    ext     v23.16b, v26.16b, v26.16b, #8
    eor     v23.16b, v23.16b, v26.16b
    pmull   v22.1q, v22.1d, v23.1d
    eor     v22.16b, v22.16b, v20.16b
    eor     v22.16b, v22.16b, v21.16b
    ext     v27.16b, v31.16b, v22.16b, #8
    eor     v27.16b, v20.16b, v27.16b      // lo128
    ext     v15.16b, v22.16b, v31.16b, #8
    eor     v15.16b, v21.16b, v15.16b      // hi128
    eor     v28.16b, v28.16b, v27.16b
    eor     v29.16b, v29.16b, v15.16b
.endm
// Reduce acc {v28=lo, v29=hi} into Y (v25). Scratch v20..v23.
.macro REDUCE_SEAL
    pmull   v20.1q, v29.1d, v30.1d
    pmull2  v21.1q, v29.2d, v30.2d
    ext     v22.16b, v21.16b, v31.16b, #8
    pmull   v22.1q, v22.1d, v30.1d
    eor     v25.16b, v28.16b, v20.16b
    mov     v23.d[0], v22.d[0]
    mov     v23.d[1], v21.d[0]
    eor     v25.16b, v25.16b, v23.16b
.endm

.global _nova_gcm_seal
.align 4
_nova_gcm_seal:
    SAVE_D8_D15
    ldr     w9, [x3, #12]
    rev     w9, w9
    ld1     {v24.16b}, [x3]           // counter template
    ld1     {v25.16b}, [x7]          // Y
    movi    v31.16b, #0
    mov     x10, #0x87
    dup     v30.2d, x10
    cmp     w1, #14
    b.eq    200f
    ld1     {v0.16b, v1.16b, v2.16b, v3.16b}, [x0], #64
    ld1     {v4.16b, v5.16b, v6.16b, v7.16b}, [x0], #64
    ld1     {v8.16b, v9.16b, v10.16b}, [x0]
    b       201f
200:
    ld1     {v0.16b, v1.16b, v2.16b, v3.16b}, [x0], #64
    ld1     {v4.16b, v5.16b, v6.16b, v7.16b}, [x0], #64
    ld1     {v8.16b, v9.16b, v10.16b, v11.16b}, [x0], #64
    ld1     {v12.16b, v13.16b, v14.16b}, [x0]
201:
    cmp     w5, #0
    b.le    209f
202:
    // build 4 counter blocks
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
    // AES-CTR 4-way (register-resident keys)
    cmp     w1, #14
    b.eq    203f
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
    b       204f
203:
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
204:
    // XOR plaintext -> ciphertext, store
    ld1     {v20.16b, v21.16b, v22.16b, v23.16b}, [x4], #64
    eor     v16.16b, v16.16b, v20.16b
    eor     v17.16b, v17.16b, v21.16b
    eor     v18.16b, v18.16b, v22.16b
    eor     v19.16b, v19.16b, v23.16b
    st1     {v16.16b, v17.16b, v18.16b, v19.16b}, [x6], #64
    // GHASH the 4 ct blocks straight from registers (aggregated)
    rbit    v16.16b, v16.16b
    eor     v16.16b, v16.16b, v25.16b    // block0 ^ Y
    rbit    v17.16b, v17.16b
    rbit    v18.16b, v18.16b
    rbit    v19.16b, v19.16b
    movi    v28.16b, #0
    movi    v29.16b, #0
    MULACC_LD v16, 48                    // (Y^X0) * H^4
    MULACC_LD v17, 32                    // X1 * H^3
    MULACC_LD v18, 16                    // X2 * H^2
    MULACC_LD v19, 0                     // X3 * H^1
    REDUCE_SEAL                          // Y = reduce(acc)
    add     w9, w9, #4
    sub     w5, w5, #64
    cmp     w5, #0
    b.gt    202b
209:
    st1     {v25.16b}, [x7]             // store Y
    rev     w11, w9
    str     w11, [x3, #12]             // store advanced counter
    RESTORE_D8_D15
    ret

// ---- ChaCha20 4-way keystream XOR (RFC 8439) ---------------------------------------------------------
// void nova_chacha20_xor(const uint8_t* key, uint32_t counter, const uint8_t* nonce,
//                        const uint8_t* in, int len, uint8_t* out)
//   x0=key(32B) w1=counter(base block index) x2=nonce(12B) x3=in w4=len (MULTIPLE OF 256) x5=out
// Processes FOUR ChaCha blocks in parallel: each of the 16 state words is a u32x4 whose lane j is block
// (base+j)'s word, so the quarter-round is pure lane-wise add/xor/rotate with NO cross-lane shuffle (the
// thing that made single-block SIMD lose). After 20 rounds the 4x4 word groups are transposed (zip) to
// per-block order, XORed with the input, and stored. The <256-byte tail is the caller's (scalar Nova).
// Byte-identical to the pure-Nova keystream (RFC 8439 KAT-gated, 219/220/370).

.macro CC_ROTL v, n
    ushr v16.4s, \v\().4s, #(32 - \n)
    shl  \v\().4s, \v\().4s, #\n
    orr  \v\().16b, \v\().16b, v16.16b
.endm
.macro CC_QR a, b, c, d
    add \a\().4s, \a\().4s, \b\().4s
    eor \d\().16b, \d\().16b, \a\().16b
    CC_ROTL \d, 16
    add \c\().4s, \c\().4s, \d\().4s
    eor \b\().16b, \b\().16b, \c\().16b
    CC_ROTL \b, 12
    add \a\().4s, \a\().4s, \b\().4s
    eor \d\().16b, \d\().16b, \a\().16b
    CC_ROTL \d, 8
    add \c\().4s, \c\().4s, \d\().4s
    eor \b\().16b, \b\().16b, \c\().16b
    CC_ROTL \b, 7
.endm
.global _nova_chacha20_xor
.align 4
_nova_chacha20_xor:
    SAVE_D8_D15
    sub     sp, sp, #256               // initial-state save area
    adrp    x8, Lcc_const@PAGE
    add     x8, x8, Lcc_const@PAGEOFF
    adrp    x9, Lcc_incr@PAGE
    add     x9, x9, Lcc_incr@PAGEOFF
    ld1     {v20.4s}, [x9]             // [0,1,2,3] for per-lane counter
1:
    cmp     w4, #0
    b.le    9f
    // build 4-way state: constants (v0-3), key (v4-11), counter (v12), nonce (v13-15)
    mov     x10, x8
    ld1r    {v0.4s}, [x10], #4
    ld1r    {v1.4s}, [x10], #4
    ld1r    {v2.4s}, [x10], #4
    ld1r    {v3.4s}, [x10], #4
    mov     x10, x0
    ld1r    {v4.4s}, [x10], #4
    ld1r    {v5.4s}, [x10], #4
    ld1r    {v6.4s}, [x10], #4
    ld1r    {v7.4s}, [x10], #4
    ld1r    {v8.4s}, [x10], #4
    ld1r    {v9.4s}, [x10], #4
    ld1r    {v10.4s}, [x10], #4
    ld1r    {v11.4s}, [x10], #4
    dup     v12.4s, w1
    add     v12.4s, v12.4s, v20.4s     // counter base + [0,1,2,3]
    mov     x10, x2
    ld1r    {v13.4s}, [x10], #4
    ld1r    {v14.4s}, [x10], #4
    ld1r    {v15.4s}, [x10], #4
    // save initial state (st1 has no immediate offset form; advance a cursor)
    mov     x12, sp
    st1     {v0.4s, v1.4s, v2.4s, v3.4s},    [x12], #64
    st1     {v4.4s, v5.4s, v6.4s, v7.4s},    [x12], #64
    st1     {v8.4s, v9.4s, v10.4s, v11.4s},  [x12], #64
    st1     {v12.4s, v13.4s, v14.4s, v15.4s},[x12]
    // 10 double-rounds
    mov     w11, #10
2:
    CC_QR v0, v4, v8,  v12
    CC_QR v1, v5, v9,  v13
    CC_QR v2, v6, v10, v14
    CC_QR v3, v7, v11, v15
    CC_QR v0, v5, v10, v15
    CC_QR v1, v6, v11, v12
    CC_QR v2, v7, v8,  v13
    CC_QR v3, v4, v9,  v14
    subs    w11, w11, #1
    b.ne    2b
    // add initial state (cursor over the stack save area)
    mov     x12, sp
    ld1     {v16.4s, v17.4s, v18.4s, v19.4s}, [x12], #64
    add     v0.4s, v0.4s, v16.4s
    add     v1.4s, v1.4s, v17.4s
    add     v2.4s, v2.4s, v18.4s
    add     v3.4s, v3.4s, v19.4s
    ld1     {v16.4s, v17.4s, v18.4s, v19.4s}, [x12], #64
    add     v4.4s, v4.4s, v16.4s
    add     v5.4s, v5.4s, v17.4s
    add     v6.4s, v6.4s, v18.4s
    add     v7.4s, v7.4s, v19.4s
    ld1     {v16.4s, v17.4s, v18.4s, v19.4s}, [x12], #64
    add     v8.4s,  v8.4s,  v16.4s
    add     v9.4s,  v9.4s,  v17.4s
    add     v10.4s, v10.4s, v18.4s
    add     v11.4s, v11.4s, v19.4s
    ld1     {v16.4s, v17.4s, v18.4s, v19.4s}, [x12]
    add     v12.4s, v12.4s, v16.4s
    add     v13.4s, v13.4s, v17.4s
    add     v14.4s, v14.4s, v18.4s
    add     v15.4s, v15.4s, v19.4s
    // Transpose each word-group to per-block, XOR input, store. Row group words 0-3 (v0-3):
    zip1 v16.4s, v0.4s, v2.4s
    zip2 v17.4s, v0.4s, v2.4s
    zip1 v18.4s, v1.4s, v3.4s
    zip2 v19.4s, v1.4s, v3.4s
    zip1 v0.4s, v16.4s, v18.4s
    zip2 v1.4s, v16.4s, v18.4s
    zip1 v2.4s, v17.4s, v19.4s
    zip2 v3.4s, v17.4s, v19.4s
    // words 4-7 (v4-7):
    zip1 v16.4s, v4.4s, v6.4s
    zip2 v17.4s, v4.4s, v6.4s
    zip1 v18.4s, v5.4s, v7.4s
    zip2 v19.4s, v5.4s, v7.4s
    zip1 v4.4s, v16.4s, v18.4s
    zip2 v5.4s, v16.4s, v18.4s
    zip1 v6.4s, v17.4s, v19.4s
    zip2 v7.4s, v17.4s, v19.4s
    // words 8-11 (v8-11):
    zip1 v16.4s, v8.4s, v10.4s
    zip2 v17.4s, v8.4s, v10.4s
    zip1 v18.4s, v9.4s, v11.4s
    zip2 v19.4s, v9.4s, v11.4s
    zip1 v8.4s,  v16.4s, v18.4s
    zip2 v9.4s,  v16.4s, v18.4s
    zip1 v10.4s, v17.4s, v19.4s
    zip2 v11.4s, v17.4s, v19.4s
    // words 12-15 (v12-15):
    zip1 v16.4s, v12.4s, v14.4s
    zip2 v17.4s, v12.4s, v14.4s
    zip1 v18.4s, v13.4s, v15.4s
    zip2 v19.4s, v13.4s, v15.4s
    zip1 v12.4s, v16.4s, v18.4s
    zip2 v13.4s, v16.4s, v18.4s
    zip1 v14.4s, v17.4s, v19.4s
    zip2 v15.4s, v17.4s, v19.4s
    // Now: block j's four rows are v0/v4/v8/v12 (j=0), v1/v5/v9/v13 (j=1), v2/v6/v10/v14 (j=2), v3/v7/v11/v15 (j=3).
    // Block j occupies out[j*64 .. j*64+64]: row0 at +0, row1 at +16, row2 at +32, row3 at +48.
    ldr q16, [x3, #0];   eor v0.16b,  v0.16b,  v16.16b; str q0,  [x5, #0]
    ldr q16, [x3, #16];  eor v4.16b,  v4.16b,  v16.16b; str q4,  [x5, #16]
    ldr q16, [x3, #32];  eor v8.16b,  v8.16b,  v16.16b; str q8,  [x5, #32]
    ldr q16, [x3, #48];  eor v12.16b, v12.16b, v16.16b; str q12, [x5, #48]
    ldr q16, [x3, #64];  eor v1.16b,  v1.16b,  v16.16b; str q1,  [x5, #64]
    ldr q16, [x3, #80];  eor v5.16b,  v5.16b,  v16.16b; str q5,  [x5, #80]
    ldr q16, [x3, #96];  eor v9.16b,  v9.16b,  v16.16b; str q9,  [x5, #96]
    ldr q16, [x3, #112]; eor v13.16b, v13.16b, v16.16b; str q13, [x5, #112]
    ldr q16, [x3, #128]; eor v2.16b,  v2.16b,  v16.16b; str q2,  [x5, #128]
    ldr q16, [x3, #144]; eor v6.16b,  v6.16b,  v16.16b; str q6,  [x5, #144]
    ldr q16, [x3, #160]; eor v10.16b, v10.16b, v16.16b; str q10, [x5, #160]
    ldr q16, [x3, #176]; eor v14.16b, v14.16b, v16.16b; str q14, [x5, #176]
    ldr q16, [x3, #192]; eor v3.16b,  v3.16b,  v16.16b; str q3,  [x5, #192]
    ldr q16, [x3, #208]; eor v7.16b,  v7.16b,  v16.16b; str q7,  [x5, #208]
    ldr q16, [x3, #224]; eor v11.16b, v11.16b, v16.16b; str q11, [x5, #224]
    ldr q16, [x3, #240]; eor v15.16b, v15.16b, v16.16b; str q15, [x5, #240]
    add     x3, x3, #256
    add     x5, x5, #256
    add     w1, w1, #4                 // 4 blocks consumed
    sub     w4, w4, #256
    b       1b
9:
    add     sp, sp, #256
    RESTORE_D8_D15
    ret

.align 4
Lcc_const:
    .word 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
Lcc_incr:
    .word 0, 1, 2, 3

#endif // __aarch64__
