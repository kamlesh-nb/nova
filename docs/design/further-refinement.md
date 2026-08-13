# Further refinement: TLS, DEFLATE, mem builtins, and the arena sweep

Status: proposed (2026-08-12). Author: performance investigation off the pizzahub driver benchmark.

This document collects the follow-on refinements found while profiling the pizzahub web benchmark: revising
the pure-Nova TLS record layer and DEFLATE compressor, the shared `mem` byte and bit builtins they both need,
and a cleanup sweep that removes the parked per-request region arena that the same investigation concluded is
not worth completing.

## Why this document exists

The SQL Server driver looked "almost dead" in the pizzahub web benchmark (about 88 requests per second on
`/products` against roughly 4,600 for Postgres and MySQL). Isolating the cause showed it was not the TDS
protocol or the driver at all. SQL Server forces the connection to be encrypted, while the Postgres and MySQL
runs were plaintext on the local socket, so mssql alone was paying a TLS tax. Turning encryption off took the
same driver from 88 to 905 requests per second on `/products` and from 2,150 to 9,962 on `/categories`, a
10x and 4.6x jump. So around 90 percent of the "deadness" was Nova's TLS record layer, not the database.

That raised a fair question from the review: is our TLS poorly written, the same way our DEFLATE is? This
document records the profiling that answers it for both, separates the part that is a naive-algorithm problem
(fixable in pure Nova today) from the part that needs hardware acceleration (a codegen feature), and proposes
a concrete revision plan for each.

Both subsystems are pure Nova by design. wolfSSL and wolfCrypt were retired so the runtime carries no native
crypto dependency. That decision is sound, but it means the crypto and compression inner loops are Nova code
compiled through LLVM, with no access to hardware instructions unless the compiler exposes them. The findings
below fall into two buckets that matter for planning:

- Software wins: the code uses a correct but slow reference algorithm where a faster, still-portable
  algorithm exists. Fixable now, in Nova, with no compiler change.
- Hardware wins: the operation is fundamentally bounded by instructions the CPU has (AES-NI, carryless
  multiply, SIMD) that Nova cannot yet emit. These need a codegen intrinsics feature and are a later, larger
  investment.

## How the numbers were taken

Both were profiled with a temporary phase timer added to the real stdlib functions (`aesgcm.seal` and
`deflate.deflateRaw`), driven by a small microbenchmark, then removed. The binaries were ASAN builds, so the
absolute times are inflated by the sanitiser. The phase split (the percentages) is what matters and is not
distorted by ASAN. Representative inputs were used: for TLS a 96 byte record (a small database reply packet)
and a 1,024 byte record; for DEFLATE the real 194 KiB `/products` HTML page and a synthetic page with
repeated structure but varying content.

## Tracking table

Status values: `not started`, `in progress`, `blocked`, `done`, `deferred`. "Master" cross-references the
consolidated plan at `../../../PLATFORM-PLAN.md`. For the current push only the soundness items that feed
Workstream A are in scope; the performance, crypto, SIMD, and arena work is deferred.

Granular per sub-item so "what is done" is unambiguous. Status: `not started`, `in progress`, `done`,
`deferred`. Every `done` row names its verification.

| ID | Item | Priority | Status |
|----|------|----------|--------|
| A-1 | Fail-closed soundness pass (checker + codegen loud on unresolved type) | P0 | done (3 defects landed with expect_fail guards; slice 7/7; corpus green) |
| A-2 | Parse-family (parseInt/parseLong/parseDouble optionals) + small stdlib gaps | P0 | done (optionals + exponent grammar in std/string.nova; parseI64/parseFloat kept for drivers) |
| **FR-mem-1** | `mem.load<T>` / `mem.store<T>` + `Endian` enum (Tier 1 builtins) | P2 | done (compiler builtins: sema/infer.zig types the return from T, codegen/expressions.zig compileMemCall lowers to unaligned load/store + compile-time-folded byte swap; Endian enum in std/mem/endian.nova; verified LE/BE + signedness across byte..long in corpus case 322; corpus 326/327, only the off-platform epoll case failing) |
| **FR-mem-2** | `rotl` / `rotr` / `ctz` / `clz` / `bswap` scalar bit builtins (Tier 2) | P2 | done (rotl/rotr lower to llvm.fshl/fshr, ctz/clz to llvm.cttz/ctlz, bswap reuses the folded byte-reverse; return-type from T in sema/infer.zig, ctz/clz return int; verified across u32/u64/u16 in corpus case 323; corpus 327/328, only the off-platform epoll case failing) |
| **FR-mem-3** | `xorBytes(dst,a,b,len)` (Tier 3, AES-GCM keystream/tag XOR) | P2 | done (mem.xorBytes builtin -> nova_mem_xor runtime helper, word-at-a-time with a byte tail; non-generic so typed void via the builtins table; verified full-word / word+tail / in-place-alias in corpus case 324) |
| **FR-mem-4** | Reconcile `bytes.read_i32`/`write_i32` through `mem.load/store<int>` | P3 | done (the bytes.* raw accessors emit byte-identical IR to mem.load/store<int> with Endian.little on a little-endian host; documented the equivalence at codegen/expressions.zig read_i32 and kept both, the bytes.* terse fast path and the mem.* endianness-explicit superset, rather than adding call indirection for zero IR change) |
| **FR-deflate-3** | Best-length-first skip in the chain walk | P2 | done (zlib's data[cand+bestLen]/[-1] pre-check kills most candidates before any full compare; output is bit-identical because the full loop already keeps the nearest match of a given length via l>bestLen, so rejecting non-beating candidates changes nothing chosen; verified by corpus 320 roundtrip + external system gunzip on the 24964-byte source, byte-identical) |
| **FR-deflate-4** | SWAR word-at-a-time match extension (64-bit load + ctz) | P2 | done (mem.load<ulong> both sides + XOR; a full 8-byte window advances l by 8, a mismatch takes mem.ctz(x)>>3 low matching bytes then the byte tail finishes; window guarded by l+8<=maxLen so no over-read past n; byte-identical output, verified corpus 320 long-match SWAR guard + external gunzip) |
| **FR-deflate-5** | Per-matched-byte hash-update + BitWriter output review | P3 | done (hot hash-chain slots wr32/rd32 now single mem.store/load<int> not four byte ops, rd32 raw-combine and mem.load<int> sign-ext agree on stored positions and the -1 sentinel; BitWriter.writeBits accumulates all n bits and drains whole bytes instead of a branch per bit; byte-identical, verified corpus 320 + external gunzip. hash3 left as 3 byte reads: callers guarantee only pos+2<n, so a 4-byte word load would over-read) |
| **FR-tls-1** | Shoup-table GHASH (4-bit table, per-key) | P2 | done (per-key 16-entry product table + 16-entry reduction table built from the verified single-bit mulX, so correct by construction; hot path is 32 nibble steps of a 4-bit shift + two block XORs vs 128 single-bit steps; GCM Test Case 2 + reference vectors + AEAD/TLS cases 222/223/230/231/235 all green, byte-identical, ARC delta zero) |
| **FR-tls-2** | Cache AES key schedule + H (+ GHASH table) per cipher context | P2 | done (aesgcm.GcmContext caches the AES key schedule + H + GHASH tables; seal/open free fns are now one-shot wrappers over it; TLS 1.2 client (client12, the mssql TDS path that motivated the whole TLS finding) holds a per-direction context built lazily and reused for every record, so setup is paid once per connection not per record; verified 223/230/231/235/251 + client12 record roundtrip, corpus 328/329. TLS 1.3's rotating-epoch keys can adopt the same primitive per epoch) |
| **FR-simd-L1** | Integer-vector SIMD (u8x16/u32x4/u64x2/i128 + ops + movemask) | P3 | not started (extend the f64x4 codegen-builtin mechanism) |
| **FR-simd-L2** | Target crypto intrinsics (AES-NI, PCLMULQDQ, ARM pmull) + fallback | P3 | not started (target-gated; FR-tls software path is the fallback) |
| **FR-arena** | Remove the parked per-request region arena (region.nova + runtime state) | P3 | not started (ONE isolated commit; keep io/arena.nova) |
| **FR-safety** | Nova-native safety ergonomics (T? sugar, all-path defer, exhaustive switch, try?, default trait methods, Result, @deprecated) | P1 | not started (language features; the soundness floor) |
| aux-deflate-verify | Confirm DEFLATE byte-correctness / gzip interop before the perf rewrites | P2 | done (bidirectional system-gzip interop verified; corpus case 320 added as the regression guard the perf rewrites must not break) |
| aux-wasm-gate | Restore the `--wasm-run` behavioural gate | P2 | done (harness env was missing nova_bytes_copy + nova_bytes_alloc_persistent_nz; added; instantiate restored. Residual: string.parseDouble asserts diverge under WASM, a narrow tracked wasm-float item) |

## Finding 1: TLS AES-GCM record layer

Per-phase share of one `seal` call:

| phase                        | 96 byte record | 1,024 byte record | nature                         |
|------------------------------|----------------|-------------------|--------------------------------|
| GHASH (authentication)       | 58 percent     | 61 percent        | bit by bit, software-fixable   |
| AES-CTR (encryption)         | 24 percent     | 35 percent        | bitsliced, one block at a time |
| setup (key schedule plus H)  | 16 percent     | 2 percent         | recomputed per record, waste   |
| j0 (per-record IV counter)   | about 0        | about 0           | negligible                     |

Three separate issues, in priority order.

### 1a. GHASH is the slowest possible multiply (software-fixable, biggest win)

`crypto/mac/ghash.nova` `gmult` does the reference bitwise GF(2^128) multiply: for each of 16 bytes, for each
of 8 bits, it does two 16 byte inner passes (a masked XOR accumulate and a one-bit shift with reduction).
That is roughly 128 iterations of 16 byte work per block, and it is 60 percent of the whole seal. A single
128 bit multiply should not cost twice the AES rounds. The standard portable fix is Shoup's table method:
precompute a small table from H once per connection (a 16 entry 4-bit table, or a 256 entry 8-bit table),
then each block becomes a handful of table lookups and XORs. This is pure Nova, needs no hardware, and is
worth roughly 8x to 16x on GHASH.

### 1b. Key schedule and H are recomputed on every record (software-fixable)

`aesgcm.seal` and `aesgcm.open` call `aes.Aes.create` (the key expansion) and `computeH` (H equals the
cipher applied to a zero block) on every call. Both are constant for the lifetime of a connection's key. On a
96 byte record this per-record setup is 16 percent of the cost, and small records are exactly the database
and RPC shape. Caching the expanded key schedule and H on the connection's cipher state removes almost all of
it. This pairs naturally with 1a, because Shoup's GHASH table is also a per-key value that should be computed
once and cached alongside H.

### 1c. AES-CTR is bitsliced but single-block (partly software, mostly hardware)

`crypto/cipher/aes.nova` `encryptBlock` uses a bitsliced, constant-time design (the `ortho`/`q` state). That
is a deliberate and reasonable choice, not sloppy code. Bitsliced AES is built to process two blocks in
parallel (the `q` state has even and odd slots), but the current code fills only one and zeroes the other, so
it wastes half the throughput. Doing two CTR blocks per call is a real software win of up to about 2x. The
large remaining gap to a native cipher needs AES-NI, which is a hardware intrinsic (see the codegen section).

## Finding 2: DEFLATE compression

`compress/deflate.nova` `deflateRaw` is a standard hash-chain LZ77 with fixed Huffman output. Per-phase share:

| input                                    | match search | Huffman emit plus hash update |
|------------------------------------------|--------------|-------------------------------|
| real 194 KiB `/products` HTML            | 56 percent   | 43 percent                    |
| synthetic page, structure repeats        | 81 percent   | 18 percent                    |

(An earlier synthetic input that repeated one identical template gave the opposite split, match search only
10 percent, because identical repetition produces very long matches that are found immediately, so the cost
moves entirely into the per-matched-byte hash updates. That input is not representative of real HTML. The
two rows above are.)

Match search dominates on realistic input, and it uses the naive reference approach with the two classic zlib
optimisations missing.

### 2a. No "check the byte at best length first" skip (software-fixable, biggest win)

The chain walk compares every candidate from offset zero with a byte-by-byte loop. zlib's key trick is to
check `data[cand + bestLen]` against `data[pos + bestLen]` (and the byte before it) before doing any full
compare, and to skip the candidate entirely if it cannot beat the current best match. On real data most
candidates are rejected by this one comparison, which commonly cuts match search by 2x to 4x. Pure Nova, no
hardware.

### 2b. Byte-by-byte match extension instead of word at a time (software-fixable)

The extension loop reads one byte at a time from both positions and compares. zlib reads a machine word (8
bytes) from each side, XORs them, and counts the matching bytes from the trailing-zero count. On the long
matches that HTML produces this is several times faster. In Nova this is reading `long` values and comparing,
a SWAR technique we already use elsewhere (the escape scanner). No hardware needed.

### 2c. Per-matched-byte hash update and bit-at-a-time Huffman output (software-fixable)

After a match of length L the code inserts a hash entry for every one of the L positions (`hash3` plus two
32 bit writes and a read each). For very repetitive data this becomes the dominant cost. It is necessary for
future match quality, but the inner work can be tightened, and the `BitWriter` output path should be reviewed
for the same word-at-a-time treatment rather than per-bit calls. These are smaller wins than 2a and 2b but
sit in the 18 to 43 percent "emit plus hash" band.

## The shared conclusion

The reviewer's instinct was right, and it is the same root cause in both subsystems. On the shapes that
matter (small TLS records and real HTML), the majority of the cost is a correct-but-naive reference algorithm
where a faster portable algorithm was never put in:

- TLS: about 60 percent GHASH (bitwise) plus 16 percent per-record setup on small records is software-
  fixable. That is roughly three quarters of the cost on the database and RPC shape, addressable in pure Nova
  with no compiler change.
- DEFLATE: about 56 to 81 percent match search, most of which is addressable by the best-length skip and
  word-at-a-time compare, again pure Nova.

The remainder (native-speed AES, native-speed carryless multiply) is a genuine hardware gap that a codegen
intrinsics feature would close later.

## Foundation: the `mem` byte and bit builtins

Both Phase A plans lean on the same low-level operations, and today every crypto, compression, and database
wire-codec module hand-rolls them as byte-at-a-time loops. `aes.nova` has its own `le32` and `putLe32`,
`deflate.nova` has `wr16`/`rd16`/`wr32`/`rd32`, GCM does big-endian lengths by hand, and each of the four
database drivers repeats the same little-endian and big-endian reads. Every one of these compiles to a loop
of `read_byte` calls with shifts, when the CPU can do the whole read as one wide load and an optional byte
swap. So before the algorithm rewrites, we add a small set of shared compiler builtins that lower to one or
two LLVM instructions each. They replace the hand-rolled copies with one fast primitive and are the base the
Phase A fixes stand on: the deflate word-at-a-time compare needs a 64-bit load plus a trailing-zero count,
GHASH and the SHA family need rotations, and the whole record layer needs endian-aware reads and writes.

Nova's integer types carry both width and signedness (`byte`/`ubyte`, `short`/`ushort`, `int`/`uint`,
`long`/`ulong`, mapped in `sema/lower.zig` to a width in bits and a sign flag), so a single generic surface
over `T` covers every case. This mirrors the existing generic intrinsics `serde.bindRow<T>` and
`serde.bindWire<T>`, which already resolve their return type from the type argument in `sema/infer.zig`.

### Surface

```
enum Endian { little, big }        // a normal Nova enum in the mem stdlib module

mem.load<T>(p: ptr, off: int, e: Endian): T            // zero-alloc typed read; T fixes width + signedness
mem.store<T>(p: ptr, off: int, v: T, e: Endian): void  // zero-alloc typed write into an existing buffer

mem.rotl<T>(x: T, n: int): T       mem.rotr<T>(x: T, n: int): T
mem.ctz<T>(x: T): int              mem.clz<T>(x: T): int
mem.bswap<T>(x: T): T
mem.xorBytes(dst: ptr, a: ptr, b: ptr, len: int): void
```

`load` and `store` are zero-alloc by design: they read from and write into a caller-owned buffer at an
offset and never allocate a fresh byte array. An allocating convenience form was considered and rejected for
the hot path, since a malloc per record or per byte is exactly what makes the current code slow.

### Lowering

- `mem.load<T>` with endianness `little`: an unaligned load of the integer width `T` names, a byte swap only
  when the host byte order differs, then a zero or sign extend chosen by `T`'s sign flag. `mem.store<T>` is
  the mirror: truncate to `T`'s width, byte swap if needed, unaligned store.
- `mem.rotl` and `mem.rotr` lower to `llvm.fshl` and `llvm.fshr`, `mem.ctz` and `mem.clz` to `llvm.cttz` and
  `llvm.ctlz`, `mem.bswap` to `llvm.bswap`, all single instructions on a modern target.
- `mem.xorBytes` lowers to a word-at-a-time XOR loop that the optimiser vectorises.
- The `Endian` argument is a compile-time constant at every real call site, so the lowering constant-folds a
  literal `.little` or `.big` and emits the branch-free path (byte swap or not, decided at compile time). A
  non-literal `Endian` value falls back to a runtime branch on the enum tag, which keeps the rare dynamic case
  correct without penalising the common one.

The implementation follows the serde-intrinsic pattern: a checker special case in `sema/infer.zig` that
resolves the return type from the type argument, plus a lowering in `codegen/expressions.zig` that reads the
width and sign flag already available from `sema/lower.zig`. No new type-system work is needed; the `simd`
builtins and the serde intrinsics are the templates. The `Endian` enum itself is a normal Nova enum in a
`mem` stdlib module; `load`, `store`, `rotl` and the rest are the compiler-recognised generic builtins.

### Signedness is a free correctness win

Because `T` carries the sign, `mem.load<byte>` sign extends and `mem.load<ubyte>` zero extends, with no manual
step. That directly replaces the hand-written `signExtend(v, 1)` and `signExtend(v, 2)` calls in the MySQL
binary decoder (`decodeBinaryCell`) and the similar sign handling scattered across the drivers.

### Priority and cleanup

Tier 1 is `mem.load` and `mem.store`. Tier 2 is the scalar bit operations (`rotl`, `rotr`, `ctz`, `clz`,
`bswap`), which are what make the SHA family and the deflate match extension fast. Tier 3 is `mem.xorBytes`
for the AES-GCM keystream, accumulate, and tag XORs. Do Tier 1 and Tier 2 first as one batch, since each is a
one-line table entry plus a short lowering and they are the base the Phase A fixes stand on.

One cleanup to fold in: the existing `bytes.read_i32` and `bytes.write_i32` builtins predate this design.
Confirm their byte order and either re-express them through `mem.load<int>` and `mem.store<int>` or leave them
as thin aliases, so there is a single story for typed reads and writes.

## Proposed work

### Phase A: pure-Nova algorithm fixes on top of the mem builtins

These are the algorithm rewrites. They are pure Nova and depend only on the `mem` builtins above (the one
small compiler addition); no other compiler change is needed.

TLS:
1. Shoup table GHASH. Add a per-key table to the `Ghash`/GCM state, computed once, and replace `gmult` with
   table lookups. Start with the 4-bit table (16 entries, low memory), measure, then consider 8-bit.
2. Cache the AES key schedule and H (and the new GHASH table) on the connection's cipher context so `seal`
   and `open` stop recomputing them per record.

DEFLATE:
3. Add the best-length-first skip to the chain walk.
4. Replace the byte-by-byte match extension with a word-at-a-time (SWAR) compare.
5. Review the per-matched-byte hash update and the `BitWriter` output path.

Expected effect: on the small-record TLS path a rough 3x to 4x on the record layer, which would take mssql
from about 88 toward the low hundreds of requests per second on this box before any hardware work, and it
lifts every TLS workload (HTTPS, the web server, all four drivers over TLS), not just mssql. On DEFLATE a
similar multiple on compress throughput, which helps HTTP response gzip across the board.

### Phase B: the SIMD facility (compiler feature, larger)

The remaining native-speed gap (byte scanning, AES rounds, carryless multiply) is closed by giving Nova a
proper SIMD facility. This is not new ground: the compiler already has a working SIMD path. The `f64x4`
builtins map the type name to `LLVMVectorType(LLVMDoubleType(), 4)` in `codegen/types.zig`, keep vector
values in their own `<4 x double>` local slots so they stay in NEON or SSE registers, and lower the `simd.*`
builtins to LLVM vector ops in `compileSimdCall` (`codegen/expressions.zig`). It is a lightweight,
codegen-only vector facility (the vector is a recognised builtin-slot type, not a first-class checker type),
which is exactly why extending it is cheap: add a type name, map it to an LLVM vector, add the ops. Adding
SIMD is two layers on top of that proven mechanism.

Everything stays pure Nova with no C dependency: the vector types and the crypto intrinsics lower straight
through LLVM, and the Phase A scalar and SWAR versions remain the fallback on targets that lack the
instructions.

#### Layer 1: portable integer-vector SIMD

Add integer vector types the same way `f64x4` was added: `u8x16`, `u32x4`, `u64x2`, and `i128` as
`<2 x i64>`, with the operations byte work needs:

- load and store (unaligned), splat, extract and insert lane.
- bitwise (`and`, `or`, `xor`, `not`, shifts) and lane arithmetic (`add`, `sub`, `mul`).
- compare to a per-lane mask (`pcmpeqb`) and movemask (`pmovmskb`: collapse each lane's top bit into an
  `int`).

The compare-plus-movemask pair is the one thing SWAR cannot do well, and it is what makes true `memchr`,
`eql`, and case-fold run at 16 bytes per instruction, with a `ctz` on the mask giving the exact match offset.
This layer is portable: LLVM lowers `<16 x i8>` to SSE, NEON, or scalar depending on the target, so the
fallback is automatic and no target detection is needed. It accelerates the `string.nova` scanning functions
beyond SWAR, the DEFLATE match compare, and it is the substrate the crypto vectors sit on.

#### Layer 2: target-specific crypto intrinsics

On the vector types, expose the actual crypto instructions, which are themselves SIMD ops on 128-bit vectors:

- AES-NI (`llvm.x86.aesni.aesenc` and friends) on `<2 x i64>` for the AES rounds and key schedule.
- PCLMULQDQ (`llvm.x86.pclmulqdq`) for GHASH.
- the ARM equivalents (the `crypto` AES instructions and `pmull`).

These are target-specific, so they need a compile-time target check plus a fallback. The fallback is exactly
the pure-Nova software work from Phase A (Shoup-table GHASH, bitsliced AES), so that effort is not wasted: it
becomes the portable path. This layer is what takes AES-GCM from the software ceiling to native speed and, on
the mssql shape, from the low hundreds of requests per second toward the no-crypto ceiling of around 900.

#### Scope and caveats

- Staying with the codegen-only builtin-vector style (like `f64x4`) keeps this small and gets the
  performance. A fully general portable-SIMD type (`Vec<T, N>`, in the style of Rust's `std::simd`) is a much
  larger language feature and is not needed for any of these goals.
- WASM has its own 128-bit SIMD that LLVM can target; treat it as later surface, not a blocker.
- Do Layer 1 first (proven by `f64x4`, fully portable, immediately useful for `string.nova` and DEFLATE),
  then Layer 2 on top (the crypto ceiling, target-gated with the Phase A software fallback).

## Cleanup sweep: remove the parked per-request region arena

The same investigation looked at the incomplete per-request region arena (the P7 sound-arena effort) to see
whether completing it would help, and concluded it would not, at least not as the next move. The reasoning:

- The lever it targeted, per-request ARC and malloc churn, was real when the P7 doc was written, but most of
  it has since been captured by a different, sound technique: the wire-to-struct decode plus `str.Str`
  borrowing. That work cut `nova_release` from about 959 to 267 and RSS from 37 to 21 MB by not materialising
  the per-row object graph, and it is why `/products` now beats Rust. So the arena would be fighting for a
  much smaller residual.
- The sound version needs an analysis we do not have. The shipped escape gauge, run on the current app,
  classifies only about 10 percent of allocation sites as function-local. The other 90 percent escape their
  function but are mostly request-local, which the function-escape analysis cannot prove. Proving
  request-locality needs a whole-program "does this ever reach a persistent sink" analysis (globals, pooled
  connections, static caches, a response held past the request). That is genuinely multi-day, and a wrong
  "local" is a use-after-free.
- Even done correctly a region can lose. The earlier blanket version, once made correct, was about 28 percent
  slower with multi-GB RSS, because keeping every chunk mapped for the range check blew the working set 6 to
  10 times into cache thrash.

So the plan is to remove the parked scaffolding, keep the one genuinely useful piece, and prefer
borrow-not-materialise plus the crypto and compression primitives above for further gains.

### Keep

- `src/std/io/arena.nova` `Arena` (the per-COROUTINE bump allocator). This is not the failed experiment. It
  is a working, tested, live feature used by conformance cases 191 and 318, a general-purpose scratch
  allocator for raw bytes, sound and orthogonal to the ARC-churn problem.

### Remove (the per-REQUEST region, never completed and inert)

- `src/std/mem/region.nova` (the `runStr` synchronous region scope). Dead, zero callers.
- In `src/runtime/concurrency.cpp`: `nova_web_region_enter`, `nova_web_region_exit`,
  `nova_coro_region_track`, `nova_coro_region_untrack`, the `g_region_active` / `g_coro_region` state, and the
  per-resume region swap inside `raw_coro_resume`. This is inert (`g_region_active` never becomes true), and
  it sits in the single hottest and most delicate runtime function. Removing it simplifies the resume path
  back to `set current coro, run, restore`.
- In `src/runtime/alloc.cpp`: the region primitives `nova_region_new` / `set` / `current` / `free` / `gen`
  and `region_alloc`, once the concurrency.cpp callers above are gone and nothing else references them.
- `src/sema/escape.zig` (the report-only escape gauge) and its wiring in `src/main.zig` (the import plus the
  two `NOVA_ESCAPE_REPORT` call sites). The gauge drives nothing, and its own design admits function-escape
  is the wrong granularity for the real opportunity, so a clean sweep is better than carrying a pass that
  points at the wrong question. If a future Stage 3 ARC-elision is ever wanted, it is a fresh analysis
  anyway, not this one.

### Procedure and verification

- First confirm nothing live references the removed symbols: grep the stdlib and runtime for `region.run`,
  `runStr`, `nova_web_region`, `nova_coro_region`, `nova_region_`, `region_alloc`, and `sema_escape` /
  `NOVA_ESCAPE_REPORT`, and confirm the only hits are the definitions and the call sites being removed.
- Do it as ONE isolated commit, not bundled with the TLS, DEFLATE, or builtins work, because the resume path
  is delicate.
- Rebuild, then run the full corpus (`conformance/run.sh -j`) plus the ASAN gate (`conformance/run.sh
  --asan`), since this touches the shared scheduler. The corpus must stay at its baseline (320 of 321 on
  macOS, the one failure being the off-platform epoll layout case), and ASAN must be clean.
- This reverses the "parked scaffolding" portion of the earlier perf commit; the commit message should say so
  and reference this document.

## Verification

- Re-profile `seal`/`open` and `deflateRaw` with the same temporary phase timer after each change, on a
  non-ASAN release build, and record before and after MB per second.
- Byte-correctness: AES-GCM must round-trip against the existing crypto conformance vectors and the live
  TLS handshake tests; DEFLATE output must still `gunzip` correctly and stay within the offline gzip gate.
  The GHASH and match-finder changes must be output-identical, since they only change how the same result is
  computed.
- End-to-end: re-run the mssql pizzahub benchmark with encryption on and confirm the record-layer share of a
  request drops, and re-run the web server gzip path.
- Gates: full conformance corpus plus the ASAN gate before any commit, since these touch shared stdlib
  crypto and compression used across the tree.

## Broader refinement backlog (beyond performance)

The performance work above is bounded and well understood, but it is not the most important thing to refine.
This section records the wider gaps, in priority order. The headline: for a language at Nova's stage, which
is feature-rich but still ALPHA on correctness, soundness matters more than more performance or more
features. A language that segfaults on a valid program cannot credibly call itself Beta, and it undermines
every other investment.

### Priority 1: soundness (valid programs must not crash)

There are live codegen defects where a valid program crashes or miscompiles:
- a stored multi-argument closure segfaults;
- a standalone `Set<T>` fails LLVM verification;
- a `T | E | undefined` value segfaults;
- an `@serializable` struct built with a struct literal and then rendered through NSX segfaults (found in the
  pizza app; sidestepped there with a positional init, not root-caused).

The notes trace the shared root to the codegen still carrying type identity as STRINGS (deciding ownership,
dispatch, and ARC by comparing type-name strings) instead of a `TypeId` over a typed IR. That is the
"semantics from strings" trap, and it is why these read as unrelated crashes but share one cause. The deep
fix is the F-series direction: the checker writes a typed IR and codegen consumes `TypeId`, never re-derives
meaning from a name. This is less glamorous than SIMD, but it is what turns Nova from an impressive demo into
something people trust in production, so it should get the deepest effort.

### Priority 2: ecosystem and tooling

- **A `library` template for `nova init`.** The manifest already supports it (`nova-postgres`'s
  `project.json` is `{"name","version","type":"library","dependencies":[]}`), so the resolver and cache
  already understand library packages. Only the `init` scaffold is missing, and every real package (the five
  drivers, datastar, the orchestrator) is hand-rolled today. `nova init library <name>` should scaffold
  `project.json` (type `library`), `src/lib.nova` (the public re-export surface), `tests/lib_test.nova` (one
  `@test` so `nova test` works immediately), a `README.md` and a `.gitignore`. One rule to settle: make
  `import <name>` resolve to `<pkg>/src/lib.nova`, so the canonical entry is `lib.nova` rather than a file
  that must match the package name. This is small and self-contained, and it is the on-ramp for the package
  ecosystem Nova clearly wants.
- **Package versioning and a registry.** Dependencies are raw GitHub URLs pinned to a branch, which is why
  the two-copy trap exists (a driver in `lang/packages/*` versus the one the app resolves from
  `~/.nova/cache/nova-*`). A real semver + lockfile + index story removes that whole class of "which copy am
  I building against" confusion.
- **LSP maturity.** The server is basic; go-to-definition, hover types, diagnostics-on-save, and rename are
  what keep people inside the language.
- **Error-message quality.** Spans, "did you mean", and the trait-method-missing and narrowing errors reading
  as guidance rather than internal jargon.

### Priority 3: targets and portability

- **WASM.** A task notes the trivial program fails to build; if WASM is still a goal it needs a pass, and if
  it is genuinely secondary (the 2026-07-28 decision) the docs should say so plainly so it stops reading as a
  silent gap.
- **Windows runtime.** Compile-verified and partially run-verified; finish the run-verification and the open
  readiness cases (the IOCP `armRead`/`armWrite` conversion) rather than leaving it half-proven.

### Priority 4: language-completeness gaps (shared foundation with Priority 1)

The F-series backlog: honest 32-bit `int` local slots with an overflow trap, real module scoping and
visibility, and making an unresolved call an error rather than a silent fallthrough. These sit on the same
typed-IR foundation as Priority 1, so they are best done together.

### Cross-driver consistency (found while doing the wire-path work)

The `mongo` and `novadb` drivers do NOT implement `queryWire`, which the committed lang now requires on the
`Connection` trait, so they will fail to build against current lang. Each needs the one-line
`wireRowsFromResultSet` fallback (or a native `queryWire`) added, the same as mysql and mssql received. This
is a concrete, small task and a good check that no other `Connection` impl was missed.

### Additional gaps from the review sweep

A four-agent review (codegen soundness, stdlib stubs, silent-failure patterns, tooling and ecosystem)
surfaced the following, ranked. The soundness and data-corruption items are the ones that matter; the rest
are catalogued for the backlog. Items marked (verified) were confirmed by reading the code directly.

#### Soundness: codegen decides memory-critical facts from type-name strings, fail-open

Nine crash or miscompile sites, all one root cause: ARC ownership, destructor dispatch, and field or payload
layout are chosen from rendered type-name STRINGS, and every fallback fails OPEN (unknown name means assume
owned; unknown field or atomic means assume `i32`). A wrong guess is a free of a bogus pointer, a truncated
64-bit value, or a mis-offset read. The four known crashes (multi-arg closure, standalone `Set<T>`,
`T | E | undefined`, `@serializable` literal plus NSX) are instances; the sweep found five more:
- `arc.zig:47` `erasedOwnershipDefault` returns owned for any unresolved composite name, so a non-pointer
  word is freed.
- `arc.zig:660-745` destructor dispatch is name-string keyed; an unknown name gets no free (leak) or the
  wrong struct's destructor via the `getStructBaseName` collapse (frees fields at wrong offsets).
- `expressions.zig:440-465` `buildClosureCall` builds the callee function type from the CALL SITE arity, never
  the stored closure's real signature, so a wrong-arity indirect call is emitted.
- `llvm_codegen.zig:1264` `buildCallWithCasts` silently truncates on an arg-count mismatch.
- `llvm_codegen.zig:1576` `Atomic<T>` element width is chosen by a name whitelist else `i32`, so a 64-bit
  atomic under an alias (`Atomic<long>`) is truncated to 32 bits, an address-dependent SIGSEGV.
- `types.zig:192` non-primitive types load as one `ptr` or `i32` word when the field type is not matched.

Two high-value takeaways beyond the deep TypeId fix:
1. Flip the fallbacks from fail-open to fail-closed: an unknown type means borrowed (no free) or a hard
   compile error, not owned or `i32`. This converts the whole class from crashes into safe leaks or clean
   rejections, far cheaper than the full migration and a real safety floor to land first.
2. There are NO `expect_fail` compiler-crash cases for the known crashes, and a segfault exits non-zero, so
   the harness mistakes a crash for a normal rejection. Add crash-regression cases and a crash-versus-reject
   distinction to the gate.

#### Data corruption (silent wrong results the caller trusts)

- (verified) `string.parseFloat` (string.nova:498) has NO exponent, Infinity, or NaN handling: `"1e3"`
  becomes 13, `"1.5e3"` becomes 1.53, `"Infinity"` becomes 0. It is on the float-decode path of the postgres,
  mysql, and novadb drivers (`decodeCell` Float goes through `dbDouble(parseFloat(raw))`), and both pg and
  mysql emit exponent form for large or small magnitudes, so real float columns silently corrupt. Highest
  impact; roughly a ten-line fix. Small integer prices did not trip it, which is why the pizza byte-match
  held.
- (verified) ORM to BSON truncates every `long` to 32 bits: `orm.nova:214` `BsonSink.putInt` does
  `entryInt(key, val as int)` while `entryInt64Val(val: long)` sits unused at `bson.nova:86`. Any Mongo model
  `long` over 2^31 (ids, millisecond timestamps, counters) is written corrupted. One-line fix.
- `string.parseI64` (string.nova:440) returns 0 on empty or garbage input and truncates at the first
  non-digit; used for every integer cell and the postgres CommandComplete affected-row count
  (codec.nova:453), so a corrupt tag yields a trusted 0.
- `hexNibble` (nova-postgres typemap) returns 0 for invalid hex, so a corrupt bytea decodes wrong but
  plausible.
- GridFS metadata (nova-mongodb gridfs.nova:163) defaults a missing `length` or `chunkSize` to 0, so a
  corrupt entry reads back as a valid empty file.
- The JSON parser (serde/json.nova `parseArray`/`parseObject`/`parseValue`) returns a partial node and NO
  error on malformed input: `"[1,2,"` becomes `[1,2]`, with no success or failure signal.
- MongoDB DocSource accessors (nova-mongodb document.nova:127) conflate absent or wrong-BSON-type with the
  zero value (partly by design, but a real silent-default seam).

#### Numeric parsing API (the fix for the parse-family corruption)

The parse-family corruption above (`parseFloat`, `parseI64`) is a symptom of a weak API: one `parseI64` that
returns a `long` and silently yields 0 on failure, and one `parseFloat` with no exponent grammar. Replace it
with a proper, failure-surfacing family:

- `parseInt(s: string): int | undefined` (32-bit; `undefined` on overflow or malformed input).
- `parseLong(s: string): long | undefined` (64-bit; supersedes `parseI64`).
- `parseDouble(s: string): double | undefined` (full grammar: sign, integer, fraction, `e`/`E` exponent with
  sign, plus Infinity and NaN; supersedes `parseFloat`).

Returning an optional (`T | undefined`) makes a parse failure impossible to ignore silently: a caller writes
`parseInt(s) ?? default` when a default is genuinely wanted, and a wire decoder turns `undefined` into a
surfaced DB error instead of a trusted 0. Keep `parseI64` and `parseFloat` as thin deprecated aliases during
the migration, then remove them. Migrate the driver `decodeCell` paths (postgres, mysql, novadb typemaps) and
the postgres affected-row-count parse to the new functions, surfacing a malformed value as an error rather
than a zero. The sized-integer types make `parseUint` and `parseUlong` a natural later addition, but
`parseInt`, `parseLong`, and `parseDouble` are the core.

#### Ship-blocker (a regression from the queryWire trait change)

(verified) Adding `queryWire` to the `Connection` trait broke every driver that lacks it: nova-mongodb,
nova-novadb, nova-btreedb, and nova-orchestrator define 10 of the 11 trait methods and fail conformance on
the 11th, so they will not build against committed lang. The flagship app depends on nova-novadb and
nova-mongodb, so the flagship is broken against HEAD. Fix: the one-line `wireRowsFromResultSet` fallback in
each, exactly as mysql and mssql received. The underlying cause is the ecosystem gap below (nothing gates a
lang trait change against the out-of-repo drivers).

#### Correctness footguns and stdlib stubs

- (verified) `TcpClient.connect` and `connectTimeout` (net/tcp/client.nova) return `undefined` typed as a
  live `TcpStream` on connect failure; the caller cannot tell and faults on first use. Return an optional or
  an `ok()`-checkable stream.
- `fs.Watcher` is an unconditional runtime stub (io.cpp:403): create and next-event return null on every
  platform, so the published `Watcher` API silently delivers no events.
- `net.aio.sleep(ms)` (aio.nova:144) is `return 0`, a no-op that does not sleep; the real facility is the
  async `delay(ms)`.
- ORM row binding cannot handle array, nested, or child columns (orm.nova:61): `arrayLen` 0, `itemX` empty,
  `getChild` returns self, so a struct with a list or nested-object field binds empty. Flat scalars are fine.
- Streaming is not lazy: `streamRows` and `Cursor` (db.nova:467) iterate an already-materialised
  `ResultSet`, so large queries get no memory relief.
- TLS 1.3 supports only SHA-256 transcripts (handshake.nova:50); a server that only offers
  `TLS_AES_256_GCM_SHA384` fails the handshake.
- Windows IOCP readiness arming is a no-op (ev/iocp.nova:201); conformance 192/194/195 fail on Windows, and
  the `--asan` and `--arc` gates are not wired there.

#### Ecosystem and tooling (expands Priority 2 above)

- The two-copy driver trap is structural: `resolvePath` (main.zig:530-555) prefers a sibling `packages/` copy
  over the `~/.nova/cache` copy apps actually use, and dependencies are raw GitHub URLs pinned to a branch
  with no lockfile, ref, or integrity hash. This is why the queryWire break landed unnoticed. A lockfile with
  pinned commit SHAs is the high-value minimum.
- No `library` init template (confirmed); the desktop template is a single `main.nova` with no project.json
  or tests.
- LSP (nls) has hover, goto-definition, completion, signatureHelp, documentSymbol, formatting, and
  diagnostics, but NOT rename, find-references, code-actions, or semantic tokens.
- WASM: `build.zig:284-301` has the wasm build artifact commented out, and the docs contradict each other
  (execution-plan.md claims `--wasm` 104/104 resolved; language-specification.md:478 says it "fails even for
  trivial programs"). Reconcile the docs and wire the product build path.

#### Confirmed NOT bugs (checked, so they are not re-investigated)

`sendBuf` loops correctly on short writes (eventedio.nova:189); discarded `sendFrame` return values only drop
a -1 that the next read surfaces anyway; the TLS handshake result is discarded but `ok()` surfaces failure;
the pg and mongo frame readers turn short reads and EOF into a surfaced broken-connection sentinel; and the
collections, the string module, and the JSON parser's valid-input path are complete (the JSON parser even
handles astral-plane surrogate pairs).

### Round 2 sweep: security, server stability, checker soundness, concurrency

A second sweep (concurrency, security, checker accepts-invalid, resource leaks) found the following. The
security defaults are the most serious items in either round: under DEFAULT settings they expose the database
password to an on-path attacker. Security-insecure-defaults join soundness at the top of the priority list.

#### Security (exploitable under default settings)

- CRITICAL: MSSQL sends the password with NO encryption by default. `connection.nova:42` sets `encrypt` true
  only if the literal `"encrypt=true"` is present, so the default is FALSE and LOGIN7 goes over plaintext
  TCP; the password's only cover is a fixed reversible obfuscation (UTF-16LE plus nibble-swap plus XOR 0xA5,
  which the code itself labels "not encryption"). An on-path observer recovers the cleartext password. Fix:
  default `encrypt` to true; never send LOGIN7 in the clear unless the operator explicitly opts out.
- CRITICAL: MSSQL `trustServerCertificate` defaults TRUE (`connection.nova:45`), so `verify` is false and the
  client bio skips chain and hostname checks; a MITM with any self-signed cert decrypts LOGIN7 even when
  `encrypt=true`. This is the one driver that defaults its verify flag insecurely. Fix: default to false.
- HIGH: MySQL caching_sha2 full-auth blindly trusts the server-supplied RSA public key (`mysql.nova:711`)
  over a plaintext connection (`sslmode=disable` default). A MITM substitutes its own key, receives the
  RSA-OAEP ciphertext of password XOR salt, and recovers the password (the salt is sent in the clear). Fix:
  only do RSA key-exchange over verified TLS, or require a pinned server public key.
- MEDIUM: NovaDB's primary `query`/`exec` uses CLIENT-SIDE string interpolation (`novadb.nova:63,85` through
  `typemap.substituteParams`), the only SQL driver whose main path is not server-bound. `escapeText` does not
  escape backslash, and a Decimal `DbValue`'s text is inserted raw and unquoted, so an attacker-influenced
  Decimal (`1 OR 1=1`) injects. Fix: route `query`/`exec` through the server-bound Parse/Bind path the
  prepared methods already use.
- MEDIUM: SCRAM mutual auth is not completed. The server's ServerSignature (`v=`) is never verified (pg
  `auth.nova` ignores SASLFinal kind 12; mongo returns success without checking `v=`), and the combined nonce
  is not verified to be prefixed by the client nonce (`scram.nova:102`). A rogue server can claim success
  without proving it knows the stored key. The password is not disclosed (one-way proof), hence medium. Fix:
  compute and compare the server signature; check the nonce prefix.
- LOW: plaintext-by-default transport on pg/mysql/novadb; `tls=true` on mongo/novadb encrypts but does NOT
  verify the cert (a "sounds secure" trap); MySQL multi-packet reassembly has no aggregate cap (a malicious
  server can drive client OOM); x509 accepts a bare-TLD wildcard (`*.com`); the static-file `..` check is a
  raw substring that a later percent-decode could bypass (verify the router decodes before `serve()`).

Verified SOUND, so not re-investigated: pg/mysql/mssql bind parameters server-side (the client-side escape
helpers are unreachable legacy); the CSPRNG is used for all keys/nonces/IVs/session ids (the PCG PRNG is
seeds and jitter only); the TLS 1.2 GCM nonce is a monotonic per-connection sequence (no reuse); x509
enforces the validity window plus SAN hostname and fails closed (no CN fallback); and every SQL driver caps
wire length fields before allocating.

#### Server stability: unbounded leaks and a pool poison (a long-running server dies without these)

- HIGH: `TlsStream.scratch` leaks 16 KB on EVERY TLS connection (`asynctls.nova:34`; no `delete()`, and
  `close()` frees bio and base but not scratch). Blast radius: every DB driver over TLS, the HTTPS client,
  and the web server's TLS accept. Fix: free scratch in `close()` and add a `delete()`.
- HIGH: Postgres `PgReader.buf` leaks 64 KB on EVERY pg connection (`proto.nova:19`, no `delete()`). Clear
  asymmetry: mysql, mssql, and novadb all free their reader buffer; postgres alone omits it. Fix: add the
  same `delete()`.
- MEDIUM-HIGH: the Postgres prepared-statement cache is unbounded (no cap, no Close/DEALLOCATE); mysql caps
  at 256 and flushes with COM_STMT_CLOSE. Long-lived pooled connections running dynamic SQL grow both the
  Nova list and the server plan cache forever. Fix: bound and evict with a Close frame.
- HIGH: the streaming cursor poisons the pooled connection. `queryStream` sets `conn.busy` and it is cleared
  only in `finish()` or an explicit `cur.close()`; the documented `while (let row = await cur.next())` loop
  with an early break never closes, so `busy` stays true, and `Pool.release` re-pools it WITHOUT checking
  `busy`, so the next borrower gets "connection busy" for the connection's life (`postgres.nova:385,446`,
  `pool.nova:156`; same on mysql). Fix: clear `busy` from the cursor destructor, or evict a still-busy
  connection on release.
- LOW: `reactorConnect` leaks the socket fd on submit failure (`eventedio.nova:293`).

#### Checker accepts-invalid (the fail-open mirror of the codegen crashes)

Same structural flaw as codegen, at the other end of the pipeline: every check is gated on the type resolving
to a simple `.ident`, and any expression the checker cannot type is silently SKIPPED
(`resolveExprType(...) orelse return`). The checker fails open, then codegen fails open. Ranked:
1. Method-call arity is NEVER checked (`type_checker.zig:671`); free functions and constructors are checked,
   methods are not, so `b.take(1,2,3)` on a 1-arg method compiles into a mismatched call (garbage or crash).
2. An unresolved bare or method call is not a located error (`infer.zig:748`, the pending N3), so codegen
   crashes with no source span.
3. `checkReturnType` skips non-`.ident`/unknown values (`type_checker.zig:389`): returning `string|undefined`
   as `string`, or any call it cannot type, is waved through into a wrong-representation return (segfault).
4. The non-bool condition test is a 4-name blocklist, not an allowlist (`type_checker.zig:324`), so `if (x)`
   where `x` is int/long/optional/enum is accepted and the wrong branch is lowered.
5. Switch exhaustiveness is silently skipped when the discriminant cannot be typed (`type_checker.zig:893`),
   giving a UB fall-through on a missing enum arm.
6. Optional and error-union assign/pass/return is not checked (only member-deref is), and a narrowing is not
   invalidated on reassignment (`infer.zig:1362,189`), so an optional flows into a `T` slot and later
   segfaults.
7. Tuples are invisible to the checker (no `.tuple` arm in `resolveExprType`): wrong-arity destructuring and
   `int + string` are accepted, giving out-of-bounds reads.

The remediation is the same fail-closed principle as codegen: an unknown type in a checked position is a hard
error, not a skip.

#### Concurrency (one reachable, the rest latent)

- REACHABLE: a blocking `Channel<T>` called from a reactor coroutine parks the whole OS thread on a condvar
  (`channel.nova` over `concurrency.cpp:466`); if the producer is a coroutine on the same reactor it is a
  permanent self-deadlock. Fix: make async channels reactor-native (`coroSuspend` plus an owning-reactor
  post), and keep the blocking `Channel` sync-thread-only.
- LATENT: `nova_chan_send` and `AsyncLock.release` resume a waiter via the thread-local run queue
  (`nova_sched_schedule`) instead of the owning reactor (`nova_reactor_post`), which becomes a UAF plus a
  lost wakeup the moment channels or actors are wired across reactors; `AsyncLock` also has a
  stale-waiter-on-cancel UAF and no error-path release.
- OPEN QUESTION that gates two findings: does a Nova `await` propagate an unwind (panic or cancel)? If it
  does, the pool acquire-to-release and the driver `busy` flag (neither wrapped in try/finally) leak a borrow
  (wedging the pool at its hard cap) and poison a connection respectively. This is a single, decidable
  runtime property worth settling before ranking those two.

## Nova-native safety ergonomics (closing the soundness gaps in Nova's own idiom)

The review sweep showed Nova crashes on valid programs because the checker and codegen fail open on
optionals, exhaustiveness, and cleanup. The fix for that class is a set of safety ergonomics that the modern
generation (Kotlin, Rust, Zig, C#, and yes Swift) all landed on independently, because they were invented to
prevent exactly this bug class. Nova should adopt the PRINCIPLES, expressed in the idiom it already has, not
import another language's machinery. Nova already carries the raw materials: union optionals
(`string | undefined`), error unions (`T | E`), Zig-style `errdefer`, `??`, and try/catch. Each item below is
a thin, Nova-native layer over those, and each one closes a specific gap the sweep found. None of it touches
Nova's identity (a pure-Nova, no-C-dependency, single-reactor, server- and hypermedia-first runtime); these
are the table-stakes safety floor a language needs to be past beta.

### Optionals: `T?` sugar over the union, with enforced unwrapping

Nova optionals are already just unions, which is more first-class than a special Optional type. Keep that and
add:
- `T?` as pure SUGAR for `T | undefined` (so `string?` is exactly `string | undefined`, not a new type).
- Enforced narrowing in the checker: a `T?` is NOT usable where `T` is expected; using it requires an unwrap.
  This is the fail-closed fix for checker gap 6 (an optional flowing into a `T` slot unchecked, which
  currently segfaults): the compiler refuses the program instead of crashing at runtime.
- Unwrap forms, over the union Nova already narrows on `!= undefined`: `if let x = opt { ... }` and
  `guard let x = opt else { return }` (bind the narrowed value for the scope), `opt?.field` (optional
  chaining, `undefined` if the receiver is), `opt ?? default` (already present), and `opt!` (force unwrap,
  traps on `undefined`). Reassignment inside a narrowed scope invalidates the narrowing (the sweep flagged the
  missing invalidation).

### `defer`: all-path cleanup (extends `errdefer`)

Nova has `errdefer` (error path only). Add a plain `defer` that runs on EVERY scope exit, normal or error, in
reverse order of declaration, exactly like the Zig `defer` Nova is written on top of, and like Go's. This is
the ergonomic, unwind-safe fix for the resource-leak cluster: `let c = pool.acquire(); defer pool.release(c);`
immediately after acquire guarantees release on any exit, which closes the pool poison, the streaming-cursor
`busy` leak, and the per-connection TlsStream and PgReader leaks by construction rather than by remembering to
free.

### Default trait-method bodies

Nova traits require every impl to define every method, which is why adding `queryWire` broke four drivers and
the flagship. Allow a trait method to carry a DEFAULT body (as Rust, Java, and C# interfaces do). A trait can
then grow a method with a sensible default (the `wireRowsFromResultSet` fallback) without breaking a single
conformer. This removes the trait-break class, not just the one instance, and it is the single highest-leverage
ecosystem fix.

### Enforced exhaustive `switch`

A `switch` over an enum must cover every case or carry a `default`; a missing arm is a compile error, not a
silent skip. This is the fail-closed fix for checker gap 5 (exhaustiveness skipped when the discriminant
cannot be typed, giving a UB fall-through).

### Error ergonomics over the union model

Nova errors are `T | E` unions plus try/catch/errdefer. Add, all as thin layers over that:
- `try?`: turn a throwing or error-union call into an optional (the value, or `undefined` on error). This
  composes directly with the optional work above and with the parse-family redesign: `parseInt(s): int?`,
  then `parseInt(s) ?? 0` or surface the `undefined`.
- an explicit error marker on a fallible function or async signature (the moral equivalent of `throws(E)`), so
  a function advertises its error type rather than leaving it implicit inside the return union.
- `Result<T, E>` as a named stdlib alias over `T | E` with `map` / `flatMap` / `get`, for callback and async
  seams where a value-style error reads better than try/catch.

### API evolution: deprecation attributes

An `@available` or `@deprecated` attribute that makes the compiler emit a warning (with a suggested
replacement) rather than a hard break. This is how the stdlib evolves past beta cleanly: deprecate `parseI64`
and `parseFloat` in favour of `parseLong` and `parseDouble`, give users a migration window, then remove them.

### What Nova deliberately does NOT take

The point is the safety principles, not another language's whole design. Nova keeps its own model and avoids
the parts that do not fit: a large generics-plus-associated-types-plus-existentials system (Nova's
monomorphised generics are enough and far cheaper to compile), a magic Optional or `throws` runtime machinery
(unions already express both), reference-counting as the primary memory model beyond what Nova already does,
and any design that trades away Nova's fast, simple checking or slow compilation onto it.

### Why this closes the soundness class

Every item above is the same fail-closed principle as the codegen and checker remediation: an unknown or
un-narrowed type in a checked position is a compile error, not a skip or a guess. The optional and
exhaustiveness rules make the checker reject the programs that currently reach codegen and crash; `defer` and
default methods remove the leak and trait-break classes structurally. Together they turn "Nova crashes on
valid code" into "Nova refuses to compile the bug", which is the real content of a step past beta.

## Notes

- The mssql slowness is not a reason to drop SQL Server support. The driver is byte-correct and on the same
  seam as the others; the cost is the shared TLS record layer, which Phase A improves for the whole platform.
- These profiles were ASAN builds; treat the percentages as the signal and re-take absolute throughput on a
  release build when implementing.
- Priority order in the backlog above is deliberate: soundness first, then ecosystem and tooling, then the
  performance plan in the earlier sections (a known quantity), then targets. Do not let the performance work,
  which is where the excitement is, crowd out the soundness work, which is what makes the performance
  reachable in production.
