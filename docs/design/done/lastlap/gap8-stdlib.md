# Gap 8: Kyte Standard Library depth -- honest assessment

Assessed from the actual `.ky` source in `/Users/kamlesh/kyte-lang/lang/src/lib/std`
(144 `.ky` files, 28,592 lines) on 2026-08-15. Where a claim is a plan or a guess it is
labelled. Modules I did not open are marked NOT INSPECTED.

---

## 1. Gap (assessed)

### 1.1 Inventory (module areas)

The 144 files group into these areas (file counts):

| Area | Files | Notes |
|---|---|---|
| `crypto/` | 40 | hash (md5/sha1/sha256/sha512/sha), mac (hmac/poly1305/ghash), aead (aesgcm/chachapoly), cipher (aes/aesctr/chacha20), ecc (p256/p384/x25519), kdf (hkdf/pbkdf2), rsa, x509, ocsp, crl, scram, base64, random, full TLS 1.2 + 1.3 client/server. Pure Kyte (wolfSSL deleted per memory). |
| `web/` | 34 | app, routing, request/response, di, mediator, middleware, cors, csrf, session, cookie, multipart, static_content, rate_limit, circuit_breaker, secure_headers, mime, httpparser, controller, redact, logger, url, etc. |
| `os/` | 14 | darwin/linux/windows/posix backends (kqueue/epoll/winsock/socket/sys/fs/proc). |
| `net/` | 18 | tcp client/server/stream, dns, dial, url, aio, poller, eventedio, tls membio/async, ev/{epoll,kqueue,iocp}, httpsclient. |
| `collections/` | 8 | list, map, ordered_map, set, deque, heap, string_builder. |
| `serde/` | 4 | json, yaml, bson, source. |
| `concurrency/` | 7 | actor, channel, asyncchan, asynclock, atomic, async_util, (async combinators). |
| `mem/` | 5 | allocator, endian, rawbuffer, memory, witness. |
| `io/` | 4 | file, dir, arena, slab. |
| `data/` | 4 | db, orm, sql/pool. |
| `text/` | 2 | regex, utf8. |
| `compress/` | 3 | deflate, gzip, lz4. |
| `resilience/` | 1 | breaker. |
| Top-level | ~15 | string, str, math, datetime, fs, env, process, log, config, result, exception, assert, metrics, stopwatch, traits, webview. |

Note: there is **no `decimal.ky` module**. `decimal` is a **compiler-native type** (decimal128
BID per memory `kyte-decimal128`), surfaced in `serde/json.ky` as `decimalValue`/`asDecimal`.
So "decimal in the stdlib" is a codegen builtin, not a library module. Its arithmetic surface
was NOT INSPECTED here (lives in codegen, out of scope for this stdlib audit).

### 1.2 TODO / stub / panic tally

`grep -niE 'TODO|FIXME|unimplemented|not implemented|not yet|stub|panic\(|placeholder|for now|hack'`
across the tree returns **13 hits**, and on inspection **none is a genuine "feature missing" hole
in a core module**. They are:

- Stale/explanatory comments: `net/ev/epoll.ky` ("earlier note was stale"), `net/ev/iocp.ky`
  (Windows runtime not wired -- a real platform gap, but off the macOS/Linux primary target),
  `crypto/tls/13/handshake.ky` (only SHA-256 transcripts "for now"; SHA-384 suites are a follow-on
  -- a genuine TLS depth gap), `compress/deflate.ky` ("leak for now, a --asan pass will free them").
- Windows stubs returning -1: `os/windows/socket.ky`, `os/windows/sys.ky`, `process_windows.ky`
  (documented Windows-target incompleteness, consistent with CLAUDE.md "Windows is cross-compile only").
- Legitimate runtime panics for programmer error, not stubs: `collections/list.ky:14`
  (`List.at` out of bounds), `collections/map.ky:164` (`Map.at` key not found),
  `web/di.ky:59,109` (required service not registered).
- `concurrency/async_util.ky` "DEAD placeholders" -- **intentional**: `whenAny`/`selectAny` are
  compiler intrinsics lowered in `expressions.zig`; the `return 0` bodies only satisfy the type
  checker. Not a hole.

**Read: the stdlib is not littered with unfinished stubs.** The low TODO count is real, not gamed.
The depth risk lives elsewhere (below): thin per-module API surfaces and thin test coverage, not
`// not implemented` markers.

### 1.3 Sampled modules -- maturity

**collections/list.ky (82 lines, HAS @test, exercised by ~70 conformance cases).**
Present: push/get/at/set/insert/remove/size/forEach/map/filter/reduce/reverse/clear/first/last/pop/
findIndex/any/all/indexOf/contains/slice/concat/sort(cmp). Core is solid and heavily exercised (list
is the most-used stdlib type in the corpus). **Holes (verified MISSING):** `flatMap`, `unique`, `zip`,
`take`, `drop`, `chunk`, `sortBy`, `count`. `sort` takes an explicit comparator only (no default sort).
Verdict: **mature core, thin at the functional-combinator edge.**

**collections/map.ky (305 lines, HAS @test, 3 conformance cases).**
Present: set/get/at/delete_key/has/size/forEach/keys/values. **Holes (verified MISSING):** `clear`,
`entries`, `getOrDefault`, `merge`, `update`/upsert. No entry-iterator; you must `keys()` then `get()`.
Verdict: **functional but minimal.**

**collections/set.ky (109 lines, HAS @test, 2 cases).**
Present: add/has/remove/size/forEach/toList/unionWith/intersection/difference. Missing `isSubset`,
`addAll`. Verdict: **adequate.**

**collections/deque.ky, heap.ky (HAS conformance case each, NO inline @test).**
Deque: pushFront/Back, popFront/Back, peekFront/Back, size, isEmpty. Heap: push/pop/peek/size with a
`less` comparator. Verdict: **minimal but complete for their purpose.**

**string.ky (700 lines, HAS @test, used by 63 conformance cases -- the most-tested module).**
Present: len/concat/split/join/slice/trim/replace/toLowerCase/toUpperCase/startsWith/endsWith/contains/
indexOf/lastIndexOf/eql/compare/hash/parseI64/parseFloat/parseLong/parseInt/parseDouble. Parsing surface
is good (typed `... | undefined` fallible parses). **Holes (verified MISSING):** `padStart`, `padEnd`,
`repeat`, `format`/interpolation helper, `substring`, `charAt`, `trimStart`, `trimEnd`, `count`, `splitN`.
Verdict: **broad and well-tested core; missing several everyday conveniences.** `str.ky` (40 lines) is
the separate borrowed-`Str` view type (ptr+len, zero-copy), not a duplicate -- it is the ORM/DB fast path.

**math.ky (418 lines, HAS @test, 4 conformance cases incl. case 244 trig/log depth).**
Present: abs/sqrt/pow/min/max/clamp for int; fabs/fmin/fmax/fclamp/ffloor/fceil/fround/fsqrt/fpow/fln/
fexp/fpowf/log10/log2/sin/cos/tan/atan/atan2; checked+saturating int/long arithmetic (checkedAdd/Sub/Mul,
satAdd/Sub/Mul). Trig is range-reduced and tested to 1e-4 (case 244). **Holes (verified MISSING):** `gcd`,
`lcm`, `asin`, `acos`, hyperbolic (`sinh`/`cosh`/`tanh`), `hypot`, `cbrt`, a general float `random`.
Verdict: **genuinely deep where tested (trig/log/checked-arith), gaps at inverse-trig and number theory.**

**datetime.ky (492 lines, HAS @test, 1 conformance case -- case 244 timezone parse/format).**
Present: Duration struct, isLeapYear, daysInMonth, now/nowNs, parse/fromIso/fromIsoUtc, format(fmt),
toIso, addDays/Hours/Minutes/Seconds, dateDiff, tzOffsetSeconds, formatOffset. Timezone-offset-aware
parse and format are present and tested. **Holes:** no timezone *database* (only numeric offsets), no
weekday/day-of-year accessor exposed, no calendar arithmetic beyond add/diff. Verdict: **solid for
ISO-8601 + offsets; not a full temporal library.**

**text/regex.ky (533 lines, HAS inline @test at line 460 -- NOT reached by conformance import grep,
so easily undercounted).** Thompson-NFA engine (Inst program, parseAlt). Present: compile/matchAt/find/
test/execFrom/exec/findAll/replaceAll/group; supports alternation, anchors, char classes, `*`/`+`/`?`,
capture groups (numbered). `replaceAll` supports numeric group backrefs in the replacement (`repl[i+1]-48`,
so `$0`–`$9`). **Holes:** no lookahead/lookbehind, no backreferences *in the pattern*, no named groups,
no counted repetition `{n,m}` (verified: only star/plus/quest constructors exist). Verdict: **a real,
tested regex engine for the common subset; not PCRE-class.**

**serde/json.ky (433 lines, NO inline @test, but 17 conformance cases import serde.json).**
Present: JsonValue with null/bool/number/decimalValue/str/array/object constructors; typed accessors
asBool/asNumber/asFloat/asDecimal/asString/asArray/asObject; get/has/at/size navigation; parse/tryParse
(fallible)/stringify/quote. Decimal is first-class. Verdict: **complete for a JSON DOM + parse/serialise,
and heavily exercised at integration level.** yaml (596 lines, HAS @test, 2 cases) and bson (NO inline
@test, 3 cases) round out serde.

**net/url.ky (112 lines, HAS @test incl. IPv6).** `parse()` only -- returns
scheme/host/port/path/query/secure, handles bracketed IPv6 and default ports. **Holes:** no
percent-encode/decode, no query-string parsing into a map (query returned raw), no URL *building*, and
`path` retains the `?query` suffix (the test asserts this, so it is by-design but surprising). Verdict:
**parse-only and shallow.** (`web/url.ky` is a separate web-layer variant, HAS @test.)

**web/client.ky (435 lines, NO inline @test, 2 conformance cases).** HttpClient get/post/send, a
KeepAlivePool, an `Http` facade (request/requestTimeout/requestVia + get/post/put/patch/del/head +
verified TLS variants + getJson/postJson generics). Verdict: **broad HTTP client surface**, but thinly
covered by tests.

### 1.4 Test coverage -- the real depth risk

- **34 of 144 stdlib files carry an inline `@test`** (verified). The other **110 have none**.
- Conformance corpus = **321 cases**. The most-tested modules by import: `string` (63), `serde.source`
  (23), `web.status`/`serde.json` (17), `web.response`/`net.poller` (15), `web.routing` (13),
  `web.request` (12), `web.mediator` (10). Crypto is exercised heavily at the **integration** level:
  `crypto.tls.13.tlsClient` (7), `crypto.ecc.p256` (7), `crypto.x509` (6), plus mTLS/0-RTT cases
  (249/242). math (4) and datetime (1, case 244) have dedicated depth cases.
- **Notable gap: the crypto *primitives* have almost no inline unit tests.** sha256, sha512, sha1, md5,
  hmac, poly1305, ghash, aesgcm, chachapoly, aes, chacha20, hkdf, pbkdf2, p256, p384, x25519 -- all
  verified to carry **no inline `@test`**. They are validated only *transitively* by the TLS handshake
  conformance cases. That is real evidence the happy path works (a TLS 1.3 handshake will not complete
  with a broken SHA-256 or P-256), but there are **no known-answer-test (KAT) vectors** pinning each
  primitive against RFC test vectors. For a crypto library that is a genuine correctness risk at the
  edges (odd lengths, boundary blocks, empty input).

### 1.5 Honest breadth-vs-depth read

This stdlib is **broad, and deeper than a typical 70%-complete library on the paths that the platform
itself depends on** (string, list, json, the crypto->TLS stack, web routing/request/response,
net poller), because those are dogfooded by the compiler's own web/DB/TLS machinery and are exercised
by the conformance corpus. It is **shallow at the edges**: everyday convenience methods are missing
across the most-used types (list combinators, map entry/merge ops, string padding/repeat/format,
math inverse-trig/gcd, url encode/decode), and **~76% of files have no unit test of their own**, with
crypto primitives lacking KAT vectors. So the accurate characterisation is **not** "broad but uniformly
shallow" and **not** "deep everywhere" -- it is **"deep on the load-bearing spine, thin and unproven at
the leaves."** The 70% figure is fair for a *depth* metric; breadth alone would score higher.

---

## 2. Root cause

The library was written **fast for the common case that the platform needed**: enough of each module to
make the web-app-on-NovaDB slice, the TLS stack, and the conformance corpus pass. Convenience methods
that no internal caller needed (string padding, list `zip`, url encoding) were simply never added. Test
coverage followed the same logic: modules got tests when a corpus case or the language guide exercised
them; the many primitives that are only reached transitively (crypto, net internals, web middleware)
never got isolated tests. Nothing here is *broken*; it is *unfinished at the periphery and unpinned by
tests*.

---

## 3. Design to close (PLAN -- labelled)

Goal: raise the leaves to beta-adequate depth and pin behaviour with tests. Order by blast radius.

1. **Harden the three most-used value types first** (list, map, string). Add the verified-missing
   methods: list `flatMap/unique/zip/take/drop/chunk/sortBy/count` + a default `sort`; map
   `clear/entries/getOrDefault/merge/update`; string `padStart/padEnd/repeat/trimStart/trimEnd/
   substring/count`. Each new method ships with an inline `@test`. (PLAN)
2. **Pin crypto primitives with KAT vectors.** Add one `@test` per primitive using the published RFC
   test vectors (FIPS 180-4 for SHA, RFC 2104 HMAC, RFC 8439 ChaCha20-Poly1305, RFC 5869 HKDF,
   NIST P-256/P-384, RFC 7748 X25519). This is the highest-value coverage add because it converts
   "works in the TLS happy path" into "correct on boundary inputs". (PLAN -- confidence high that this
   is the right investment; the vectors are standard and unambiguous.)
3. **Round out math** (gcd/lcm/asin/acos/hyperbolic/hypot/cbrt) and **url** (percent encode/decode,
   query->map, builder) -- both are small, self-contained, and each gets `@test`. (PLAN)
4. **Coverage bar for the rest.** Every stdlib module that exposes a public API must gain at least one
   inline `@test` exercising its common surface. Prioritise the currently-untested but user-facing
   modules: `web/client`, `web/routing` (used but untested), `serde/json`+`bson` (used but no unit
   test), `datetime`, `net/url`, `resilience/breaker`, `collections/ordered_map`. Internal/platform
   modules (`os/*`, `net/ev/*`, `mem/*`) can be covered by integration cases. (PLAN)
5. **Document the decimal seam.** Since `decimal` is a codegen builtin, its arithmetic/rounding contract
   belongs in a spec doc + conformance cases (separate audit -- NOT INSPECTED here). (PLAN)

Confidence: **high** on the diagnosis (holes and coverage are directly grepped and cited). **Medium** on
effort sizing (below), because a few additions (default `sort` stability, string `format`) touch codegen
or ARC ownership and could surface the value-struct/ARC subtleties noted in memory.

Unknowns: whether `string.format`/interpolation needs compiler support (likely a codegen concern, larger
than a stdlib add); whether the crypto primitives currently produce correct output on empty/odd-length
inputs (the KAT pass in step 2 is exactly what would reveal this -- it may turn up real bugs, not just
missing tests).

---

## 4. Risk + effort (guess -- labelled)

- **Risk if shipped as-is:** MEDIUM. The load-bearing spine is proven, so a beta web+DB app works. But
  (a) crypto primitives without KAT vectors are a latent correctness risk on boundary inputs, and
  (b) missing convenience methods will make the library feel unfinished to app authors and push them to
  reimplement (padStart, url-encode, list zip) in user code. Neither is a soundness/crash class.
- **Effort (guess):**
  - Steps 1+3 (list/map/string/math/url convenience methods, each with a test): **~3-5 days.** Mostly
    straightforward Kyte, watch for ARC ownership on new string-returning methods.
  - Step 2 (crypto KAT vectors, ~16 primitives): **~3-4 days**, plus unknown remediation time if a
    vector fails.
  - Step 4 (a `@test` on every public-API module, ~40-50 modules): **~1-1.5 weeks.**
  - Total to a beta-adequate depth bar: **roughly 2.5-3 weeks of focused work** (guess).

---

## 5. Verify (measurable bar)

The gap is closed when:

1. **`grep -c 'fn <method>'` confirms** the enumerated missing methods now exist on list, map, string,
   math, and url (the exact set listed in section 1.3 / step 1+3).
2. **Every stdlib file that exports a public API contains at least one inline `@test`.** Concretely:
   `for f in $(find src/lib/std -name '*.ky'); do grep -q 'pub fn\|pub struct' "$f" && ! grep -q '@test' "$f" && echo "$f"; done` returns **only** platform-internal files (`os/*`, `net/ev/*`, `mem/*`)
   that are covered by integration cases -- no user-facing module.
3. **Each crypto primitive has a KAT `@test`** asserting output against its published RFC/NIST vector,
   and the full `kyte test` + conformance suite is green.
4. **0 genuine `unimplemented`/`not implemented`/stub-body markers** remain in the core modules
   (collections, string, math, serde, text, datetime) -- the current count is already 0 there; keep it 0.
5. The `decimal` builtin gains a dedicated spec doc + conformance cases (tracked separately).
