# Per-core throughput: path to 3,000+ rps

## Context

Reference workload: the Postgres pizza-catalog web app (`plancksystems/perf/compare/nova`), one typed
route rendering 200 product cards (~193KB HTML) from a pooled Postgres connection. Measured with `oha`
at c=50, **fixed request count** (`-n`, never `-z`), release build. The Rust peer (axum + tokio +
tokio-postgres, same 10-column query, same box) does ~3,135 rps/core; this is the target.

**Baseline before this work: ~1,480 rps/core.** A profile-driven sweep (see "Landed" below) took it to
**~2,320 rps/core (+57%)**. This document tracks the remaining work to 3,000+.

### PER-CORE comparison — BYTE-IDENTICAL output (the honest one, 2026-08-11)
Earlier per-core ratios were unfair on two counts: different payload sizes (Rust/Go shipped 228 KB, Nova
194 KB) and Nova-single-core vs peer-multi-core (which is *oversubscribed* on this 4-core box + co-resident
oha, depressing the peer's per-core). Both are now fixed: the Go and Rust apps were edited to emit the
**exact same 194,739 bytes** as Nova (same escaping set, same card markup — a local benchmark change, not a
product change), and each is measured **single-core** (`GOMAXPROCS=1`, `TOKIO_WORKER_THREADS=1`, Nova's one
reactor). oha c=50, `ps -o %cpu`.

| | rps | CPU | **rps/core** | vs Nova |
|---|---|---|---|---|
| **Rust** (1 tokio worker) | ~4,300 | ~87% | **~4,300** | 1.8× faster |
| **Nova** (1 reactor) | ~2,360 | ~88% | **~2,360** | — |
| **Go** (`GOMAXPROCS=1`) | ~1,670 | ~95% | **~1,670** | 1.4× slower |

Honest ranking per core: **Rust > Nova > Go.** Nova is **~1.4× faster than Go** and **~1.8× slower than
Rust** (≈55% of Rust). The earlier "Nova ~84% of Rust" was a measurement artifact (bigger payload +
oversubscribed multi-core Rust) — corrected here. Multi-core note: both peers LOSE per-core efficiency when
threaded on this box (Go ~695/core at 3.45 cores; Rust ~2,430/core at ~2.95 cores) — the coordination/GC/
oversubscription tax that Nova's single-reactor model sidesteps. Nova's per-core number is the clean one.

### Where the 1.8× gap to Rust actually is (profile, byte-matched)
Roughly half allocation-model, half byte-throughput:
- **~31% allocation + ARC** (malloc/free ~23% + retain/release ~8%). **Rust pays ~0 here.**
- **~40% byte-work** (`memmove` + `escapeHtmlInto` + socket `write` for 194 KB). Rust pays this too but
  faster (SIMD escaping, no bounds checks).

### What is refcounted here (corrected — value structs are NOT the problem)
`ProductView`/`DbValue`/`Row` are **value structs** (the M-1/2/3 work): stored INLINE in one RawBuffer, NOT
individually heap-boxed, NOT refcounted. The struct-boxing problem is already solved. What allocates + ARCs
per request is:
1. **`string` FIELDS.** Nova has ONE string type: owned, heap, ARC-headered. Every `getText` / interpolation
   / concat mints an owned heap string. ~600 accessed cell strings + 200 `Row.raw` + render temporaries =
   the bulk of the churn (`nova_bytes_alloc` + `nova_release`).
2. **Container objects.** Each `List<T>` = heap object + RawBuffer; a `List<DbValue>` PER ROW → ~200 Lists +
   200 buffers (`RawBuffer_DbValue_push` / `List_DbValue_push`).

### The memory-model lever = a BORROWED string type (NOT a borrow checker)
Rust's edge is `&str`: a pointer+len slice, zero-alloc, no refcount, borrowing the DB row bytes and
constant template chunks (string literals baked into the binary — Nova already has these as immortal
literals, the L6 negative-refcount ones). Nova's single owned string forces ~600 heap allocs where Rust does
~0. The fix is a **borrowed-slice string type** (a pointer+len view: no header, no ARC, no allocation) scoped
to lifetimes we can prove are request-bound (the DB row buffer + the constant template text both qualify —
the buffer lives for the request, the literals live forever). P4 already prototypes it
for DB cells (lazy `DbValue` borrows a slice of `Row.raw`); the win was capped only because the render then
MATERIALISES the borrow via `getText`. Flowing the borrow THROUGH the render (NSX escapes directly from the
slice into the output buffer, never minting an owned string) is the structural fix. Do NOT adopt Rust's
whole-language borrow checker — it destroys Nova's ES6/TS ergonomics, which is the point of the language.
See P10/P11 below.

### What is NOT a fix (explicitly)
- **Trimming the SQL to the columns the view happens to use.** The app asked for those columns; the Rust
  comparison runs the same query. Changing the developer's query to suit us is gaming the workload, not
  improving the engine. The engine must make the query *as written* fast (that is what "lazy-decode",
  P3/P4 below, does — transparently, without touching the query).
- **gzip** — ruled out: the pure-Nova DEFLATE burns ~60% of a core and degrades throughput.
- **Blanket async per-request arena without escape analysis** — proven to UAF (see P7); only the
  synchronous `region.runStr` scope is safe as-is.
- **Multi-core** — scales *total* throughput (more workers/instances behind proxyd), not *per-core*.

---

## Master tracking table

Status: ✅ done · 🚧 in progress · 📐 designed · ⬜ todo · ❌ rejected

| ID | Fix | Tier | Touches | Status | Expected | Measured | Notes |
|----|-----|------|---------|--------|----------|----------|-------|
| L1 | `string.concat` byte-loop → memcpy | landed | stdlib | ✅ | — | **+36%** (1480→2010) | was 21% of all CPU |
| L2 | Fast number formatting (itoa + int-double dtoa) | landed | runtime | ✅ | — | **+15%** (2010→2320) | killed snprintf/dtoa storm |
| L3 | Sync buffered pg framing (`tryFrame`) | landed | pg driver | ✅ | — | 330→260µs/query | no per-row coro frame |
| L4 | Decimal-literal cache | landed | compiler | ✅ | — | 430→330µs/query | `0m` parsed once |
| L5 | Postgres numeric fast-path (parse from wire) | landed | pg driver | ✅ | — | 480→430µs/query | no per-cell string for ints/floats |
| L6 | Immortal string literals (neg refcount) | landed | compiler | ✅ | — | + fixes >1e8-reuse SIGABRT | |
| L7 | Escape-into-builder (XSS-safe, zero-alloc) | landed | compiler+stdlib | ✅ | — | neutral (already lean) | |
| P1 | Pre-size render StringBuilder | 1 | framework | ⬜ | +50–100 | — | `serialize` already pre-sizes; render builder needs a codegen size-hint (small) |
| P2 | Kill response-path copies (2-part send) | 1 | framework | ✅ | +100–150 | **~0 (neutral)** | `respondMissTo` sends headers+body separately (removes serialize append+toString). Copy saved ≈ extra header-send syscall — response path is I/O-bound at c=50 on this box |
| P3 | Lazy-decode unused columns | 1 | driver+seam | ✅ | +100–200 | **subsumed by P4** | realised by the P4 borrowed cell (an unread column never materialises) |
| P4 | Borrowed / lazy ResultSet | 2 | seam + pg driver | ✅ | +300–500 | **~+8–10%** (2256→~2450) | cells = (base,off,len) borrowing the Row's ARC `raw`; string-carried types only; pg first (other 4 drivers unchanged, still correct). Byte-identical output |
| P5 | Binary Postgres result format | 2 | pg driver | ✅ | +150–250 | **~0 (neutral here)** | Bind result-format=1, per-column (int/float only); byte-identical. Correct/consistent engine design but this workload has only 2 numeric cols so no throughput move |
| Rg | Sync-region split: build+render in `region.runStr` | app+stdlib | ✅ | +150–300 | **~+10%** (2360→~2600) | async fetch OUTSIDE region → sync decode+build+render INSIDE; reclaims render allocations O(1). Safe (sync, single escape). App-level plumbing |
| Ai | Inline ARC release fast-path (skip call for rc<0) | 2 | compiler (arc.zig) | ❌ reverted | +? | **profile ARC 20%→8%, wall-clock NEUTRAL** | `nova_release` 521→171 in profile, but workload is PAYLOAD-bound now so no rps gain, AND it taxes every positive-rc release (DB decode has thousands). Corpus+ASAN green but reverted — revisit for small-response/JSON workloads |
| P6 | Flatten `Row` (per-row `List<DbValue>` → `RawBuffer`) | 2 | seam | ✅ | +50–100 | **~+7%** (2725→~2920) | `List<DbValue>` was list-object + buffer = 2 allocs/row; `RawBuffer<DbValue>` is the buffer directly = 1 alloc/row (−200/query). Drivers `row.cells.push` unchanged. Byte-identical, broke 3k rps. Cumulative 2360→~2920 = +24%, ~68% of Rust |
| P9 | **SWAR escape scan** for `escapeHtmlInto` | 2 | stdlib+runtime | ✅ | part of the ~40% byte-work | **escaping 277→~109 samples (−60%)** | `nova_html_find_meta` (runtime SWAR, 8 bytes/iter branch-free, exact has-zero-byte trick) returns next-metachar index; `escapeHtmlInto` drives off it — 1 bulk scan per clean value, not per byte. Byte-identical, corpus 319/320. Strictly faster on ALL inputs, NO tax on any path (unlike the reverted ARC inline) → KEEP. General stdlib win (every HTML render). rps ~neutral here (payload-bound) |
| **P10** | **Borrowed string type (`str.Str` = ptr+len)** | 3 | language + compiler + stdlib | ✅ end-to-end | **+~15% cumulative** | **~2,360 → ~2,725/core** | Own module `str.nova` (`Str` value struct, `str.of/sub/raw`, `Str.toOwned`); `StringBuilder.appendBytes`; `escapeHtmlIntoView` (escape from a borrow, ZERO owned string); `DbValue.asView`/`Row.getView` (borrow the P4 cell). **NSX codegen**: `{v}` / `attr={v}` where `v` is a `Str` auto-escapes via the value-struct-arg lowering in `jsxAppendExpr` (fix: match `t=="Str"` and pass `val` DIRECTLY, NOT i64-coerced — that was the garbage). **App**: `ProductView` holds `Str` borrowing `rs.Row.raw`; render mints ~0 owned cell strings. Byte-identical, 100% success. Nova now ~63% of Rust/core (was ~55%). NOT a borrow checker |
| **P11** | **Compiler escape analysis → stack-alloc / ARC-elide + safe arena** | 3 | compiler | ✅ analysis + Stage C/D codegen (default-off) | closes the allocation half; makes P7 safe | REPORT + `NOVA_ESCAPE_REGION` | **ANALYSIS DONE, SOUND + PRECISE** (`src/sema/escape.zig`, behind `NOVA_ESCAPE_SHADOW`): per-function escape walk + interprocedural `methodSelfEscapes` FIXPOINT + assignment/field-store handling + **owned-field/element PRECISION** (typeOf2 + isOwned: a primitive `p.x` read does NOT escape p; an owned `p.name` does) + async-conservative. Sound UNDER-approximation (never marks a truly-escaping object local); non-empty. **Stage C/D codegen LANDED, default-off behind `NOVA_ESCAPE_REGION`:** `escape.isRegionSafe(fn)` = sync + >=1 heap alloc + ZERO escaping → codegen wraps the function body in a scope region (`nova_region_current/new/set` in the prologue at `declarations.zig`; `nova_region_set(saved)+nova_region_free(r)` in `releaseLocalVariables` = the universal pre-return hook, so every exit is covered; entry-block SSA dominates all returns). Region objects carry the immortal sentinel refcount so per-local releases are no-ops; the single free reclaims them all in O(1). **GATED:** corpus 320/321 (flag off, only inapplicable-off-Linux `189`), ASAN corpus + `str_borrow` GREEN with `NOVA_ESCAPE_REGION=1` (4 region-safe fns exercised, no UAF). Kept default-off pending a REAL-workload reached-after-scope gauge before flipping on; C's stack-alloc form of the same set + D's fold into the P7 blanket async arena remain the follow-ons. |
| P7 | Per-request arena (Design B) | 3 | compiler/runtime | 📐 | +500–800 | region-only +10% (Rg) | infra + gen-validation built; blanket-async form needs P11 escape analysis. Sync subset (Rg) is the safe part and shipped |
| P8 | Non-co-resident load generator | x | measurement | ⬜ | reveals real ceiling | — | oha off-box / pinned |

Cumulative note: byte-matched single-core, Nova ~2,360/core = ~55% of Rust (~4,300), ~1.4× Go (~1,670).
Closing the gap to Rust = P10 (borrowed strings) + P11 (escape analysis) for the allocation half, and P9
(SIMD escape) + P6 for the byte-work half. P10/P11 are language-level and worth doing FOR THE LANGUAGE, not
just this benchmark.

---

## Landed (L1–L7)
Profile-driven sweep. Each fix was found by `sample`-ing the live server under load, not by guessing.
Detail in memory `nova-per-core-perf-vs-rust` and `nova-per-request-arena`. All corpus-green (319/320);
ASAN pending on the combined state.

## P1 — Pre-size the render StringBuilder
A 190KB body built by doubling from cap 16 copies ~2×final ≈ 380KB (geometric). Pre-sizing the render
buffer to ~expected output makes it one allocation with zero regrow copies. Options: (a) bump the default
`StringBuilder` initial capacity (cheap, but the big doublings dominate, so small win); (b) a
`StringBuilder.withCapacity(n)` + a size hint from the `{for}` loop count in NSX codegen (bigger win,
more work). Start with (a)+ a modest hint.

## P2 — Kill response-path copies
Body path today: `productGrid` → `toString()` (190KB alloc+copy) → `Response(body)` → `resp.serialize()`
(headers+body concat = another 190KB alloc+copy) → `sendStr`. Two full copies before the write. Fix:
write the status line + headers, then the body, as separate `send`s (or `writev`), so the body is never
re-concatenated with headers. Saves one 190KB copy per request.

## P3 — Lazy-decode unused columns
Same query; `Row` retains the raw row bytes + column metadata and decodes a cell only when `getX(i)` is
called. Columns the view never reads never parse or allocate. Transparent (no query change). Stepping
stone to P4.

## P4 — Borrowed / lazy ResultSet (the structural fix)
Cells hold `(buf, off, len)` into a **retained** response buffer instead of an owned copy; a Nova string
is materialised only on `getText()` (and only for the accessed columns), and the `0m` decimal field is
dropped from `DbValue`. Removes the ~1,400 text-string copies + ~600 container allocs per 200-row query —
the core of the gap to Rust. Blast radius: the `data.db` seam (`Row`/`DbValue`) + all five drivers'
`decodeDataRow`, and the read-buffer lifetime (the ResultSet must own the response bytes, not reuse the
rolling 64KB reader). Nova strings need an 8-byte header, so a borrowed cell must materialise-on-read
rather than expose a bare mid-buffer pointer.

## P5 — Binary Postgres result format
Request binary result columns (`Bind` result-format code 1): int2/4/8, float4/8, timestamps arrive as
fixed big-endian bytes — no ASCII parse, smaller wire. Per-type binary decoders in the pg codec. Pairs
with P4.

## P6 — Flatten `Row`
`Row { cells: List<DbValue> }` is Row + List + RawBuffer = 3 allocs/row. A columnar or
Row-owns-buffer-directly layout → ~1 alloc/row (−400/request).

## P7 — Per-request arena (Design B)
Eliminates ~39% malloc+ARC wholesale. Infra built (chunked region pool, sentinel refcount,
`nova_bytes_persist`, `mem/region.runStr` synchronous scope) + **generation-validated per-coroutine
bindings** (fixes stale-binding crashes). BLOCKER: escape-object UAFs — a `Map`/cache allocated in the
region that outlives the request. Needs compiler **escape analysis** (auto-persist escapees) or a
complete framework-wide escape audit; the blanket wiring is proven unsafe and is disabled. Synchronous
`region.runStr` is the safe subset and ships.

## P8 — Measure off-box
`oha` co-resident eats ~3/4 cores. Run it from another host or pin it, and re-baseline — the real
per-core ceiling is above 2,320 (Rust proves it).

## P9 — SIMD / SWAR escape scan for `escapeHtmlInto`
`escapeHtmlInto` scans byte-by-byte for the 5 HTML metacharacters (`& < > " '`); it is ~8% of the core
and part of the ~40% byte-work bucket. Replace the byte loop with a **wordwise scan**: load 8 bytes at a
time and test all 8 for "is any a metacharacter" in a few ALU ops (SWAR: broadcast-compare + `haszero`
trick), OR a true SIMD path (NEON on arm64 / SSE on x86: `vceqq`/`pcmpeqb` against the 5 needles, `movemask`,
`ctz` to the first hit). Only when a chunk contains a metacharacter do we fall to the byte path for that
chunk; the common all-clear chunk is copied wholesale (`appendRange`). Two viable forms:
- **Inline Nova SWAR** — do the wordwise test in Nova over `long` reads (no call). Keeps it in the language.
- **A SIMD runtime intrinsic** — `nova_html_find_meta(ptr, len) -> first-meta-offset` vectorised in C++.
  CAVEAT (measured): a per-interpolation C FFI *call* (`nova_html_scan`) was tried and was SLOWER than the
  byte loop — the call overhead per `{expr}` dominated. So a SIMD intrinsic must scan a LARGE span in ONE
  call (e.g. the whole field, returning the next meta offset), not be called per interpolation. Prefer the
  inline SWAR unless the SIMD intrinsic clearly wins on large fields.

---

## Memory-model levers (the real path to Rust's per-core) — P10 / P11

Corrected diagnosis (2026-08-11, byte-matched): Nova's per-request churn is NOT struct boxing — `ProductView`
/`DbValue`/`Row` are value structs stored inline in RawBuffers (M-1/2/3 + M-10 did their job). The churn is
(1) **owned `string` fields** — Nova has ONE string type, owned+heap+ARC, so every materialised cell / concat
/ interpolation is a heap alloc + ARC pair (~600 cell strings + 200 `Row.raw` + render temporaries), and
(2) **per-container heap objects** (a `List<DbValue>` per row). Rust pays ~0 for (1) because its render is
`&str` borrows. So the memory-model gap is specifically the **string ownership model**, not the ownership
model at large — which is why the answer is a borrowed-string type, NOT a borrow checker.

## P10 — Borrowed string type (`str.Str` = Nova's `&str`)
A second string form: a **borrowed slice** `str.Str = {ptr, len}`, no ARC header, no allocation, no retain/
release. It borrows bytes it does not own: a slice of a DB row buffer (`Row.raw`), a constant/literal chunk of
NSX template text, a substring of another string. Lifetime obligation: a borrowed string must not outlive the
buffer it points into — enforced by scoping it to provably request-bound producers (the DB `ResultSet` and
static markup), NOT by a general borrow checker. Payoff: the render consumes borrowed slices and
`escapeHtmlIntoView` copies **from the slice straight into the output builder**, so the ~600 owned cell
strings become ~0 allocations.

**FOUNDATION LANDED + gated** (2026-08-11) — a real, verifiable first increment:
- `src/std/str.nova` (own module, registered in `std_modules`): `pub struct Str { ptr, len }` (a value
  struct → non-refcounted), `str.of(s)` (whole borrow), `str.sub(s, start, end)` (slice borrow — named `sub`
  not `slice` to dodge an unqualified cross-module collision with `string.slice`), `str.raw(ptr, n)`,
  `Str.toOwned()` (materialise at an escape boundary), `Str.size/byteAt`.
- `StringBuilder.appendBytes(srcPtr, n)` — the borrowed-bytes sink.
- `web.response.escapeHtmlIntoView(sb, v: str.Str)` — HTML-escape straight from a borrow (reuses the P9 SWAR
  `nova_html_find_meta`), minting NO owned string.
- `DbValue.asView()` / `Row.getView(i)` — borrow the P4 lazy cell as a `str.Str` (points into `Row.raw`).
- Conformance `str_borrow.nova` (whole / slice / clean-passthrough / toOwned) — 4 asserts, corpus + ASAN.

**REMAINING (task #142):** (a) NSX codegen — a `{view}` interpolation must auto-escape via
`escapeHtmlIntoView`; the hook is `jsxAppendExpr`, but a `Str` is a VALUE STRUCT and passing it as the `string`
path's coerced i64 produced garbage output — needs the real value-struct-argument lowering (the DIRECT call
already works, proving the normal ABI is fine — only the hand-built jsxAppendExpr call was wrong). (b) app
wiring: `ProductView` holds `str.Str` borrowing `rs.Row.raw`, render flows the borrow, then MEASURE the alloc
drop. This is the single highest-value language change for server throughput and realises the user's earlier
"non-ARC string" idea. NOT a whole-language borrow checker (which would trade away Nova's ES6/TS ergonomics).

## P11 — Compiler escape analysis → stack-alloc / ARC-elide + safe arena
A dataflow pass that, for each allocation, decides whether it can escape its creating scope. Non-escaping
objects get a **stack / scope-arena allocation and NO retain/release emitted** (transparent — no source
change, keeps ES6 ergonomics). This attacks the same allocation+ARC bucket as P10 but for objects generally
(container temporaries, intermediate builders), and — crucially — it is the SAME analysis the blanket
per-request arena (P7) needs: it tells the arena which allocations escape the request so they can be
auto-persisted, making Design B safe at last. Precedent: JVM/Go escape analysis → stack allocation. This is
a real, multi-quarter compiler investment with soundness obligations (the ARC/arena surface here is
unforgiving — see the reverted `Ai` inline and the P7 UAFs), but it is the one investment that pays off FOR
THE WHOLE LANGUAGE, not just this benchmark. Do NOT pursue a whole-language borrow checker: it would trade
away Nova's ES6/TS ergonomics, which is the reason the language exists.

### P11 — the STAGED, sound build plan (do NOT rush the codegen)
Hard lesson banked twice this cycle: rushed ARC/codegen changes (the reverted `Ai` inline-release, the P7
blanket-arena UAFs) LOOK fine and corrupt subtly. So P11 is built analysis-first, shadow-validated, codegen
LAST — the same discipline that made F2-6 (typed IR) land:

- **Stage A — the analysis pass (no codegen change).** A per-function dataflow that computes, for each heap
  allocation site, whether the object ESCAPES: returned, stored into a heap object / container / struct
  field, captured by a closure, passed to a function that escapes it, or live across an `await`. Non-escape
  = the object dies at scope end. Reuse the existing `types.zig` value-struct escape set as the seed; this
  generalises it to all heap allocations. Output: a set of NON-ESCAPING alloc-site IDs. Ships behind a flag,
  changes nothing.
- **Stage B — shadow validation (gauge, like `NOVA_SEMA_SHADOW`).** Run the analysis on the whole corpus and
  DISAGREE-count against a conservative oracle (assume-everything-escapes is trivially sound; the analysis
  must only ever be a SUBSET of "actually non-escaping"). Add a runtime audit: tag analysis-marked allocs
  and assert at program end that none were reached after their scope. Gate = zero unsound marks on corpus +
  ASAN. Only advance when the gauge is clean.
- **Stage C — codegen, one construct at a time.** For a proven-non-escaping alloc: (1) emit NO retain/release
  for it (it can't be shared), and where size is statically known, (2) stack/scope-arena allocate instead of
  malloc. Flip ONE construct (e.g. container temporaries first), re-run corpus + ASAN + ARC gate, measure,
  then the next. NEVER flip the whole language at once.
- **Stage D — fold into P7.** The same non-escape set tells the blanket per-request arena which allocations
  are safe to region-allocate and which to auto-persist — finally making Design B sound.

Effort: multi-quarter. Deliverable order matters more than speed; a half-correct escape set is a memory-safety
bug, not a perf regression. The concrete near-term wins (P6 ✅, Row-borrow) are independent and ship first.
