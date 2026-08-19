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
    ret

#endif // __aarch64__
