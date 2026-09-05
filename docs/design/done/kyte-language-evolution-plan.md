# Kyte Language Evolution Plan — L1–L6

> ## ⚠️ SUPERSEDED IN PART — READ `beta-readiness-plan.md` FIRST (2026-07-17)
>
> Much of L1–L4 has **landed** since this was written; `docs/design/` (F1–F5) absorbed L1/L3 and is
> the current program. Corrections measured 2026-07-17:
> - **Both "blockers first" are CLOSED**: binary-safe strings landed (`ef04a61`); and the "string
>   heap bug" was **misdiagnosed** — it was a `func_map` suffix-scan bug, not string ARC.
> - **L2's headline 💥** (`${i64}`/`${f64}` SIGSEGV) is **fixed** (`5cf9a14`); `__i32_to_string`
>   deleted (`c52a05f`). **L4 crypto** is real (`d47b8d5`) — but **hex-only output**, so digests
>   cannot chain; the designed `hash.sha256Bytes` never landed and PBKDF2/SCRAM need it.
> - **§L5 Risks still says "regex is weeks"** — stale *within this doc*; §L5 itself revised to
>   Boost.Regex.
> - ⚠️ **§L1's `arc.zig:11` verdict ("already correct… no change needed to that model") is
>   CONTRADICTED by `design/README.md`**, which calls the same line the root defect: *"Ownership is
>   decided from a string… The function cannot be fixed. Its *signature* is the defect."*
>   **The F-series wins.**
> - ⚠️ **The ICU decision is still UNRESOLVED** and gates L5 Unicode regex + L6 plurals. This doc
>   holds three incompatible positions (§L5 "gated on ICU", §L6 "ICU no longer needed", §L6
>   "recommendation: take ICU, gate it behind `KYTE_HAVE_ICU`"). **Decide before starting either.**


Detail plan for the five language items raised on 2026-07-15, plus the i18n story a web-first language
needs. This is the **implementation detail**; `kyte-readiness-roadmap.md` §M2.5 is the index that points
here (items appear there as A7/A8/A9 + C6/C7).

| ID | Item | Verdict | Size | Gated by |
|---|---|---|---|---|
| **L0** | **Spec rewrite = inventory + reference** ✅ **DONE** → [`specs.md`](./specs.md) | **Did first — it already caught 2 planning errors** | S–M | — |
| **L1** | Honest primitive types (`int`, not `i32`) | Do | L | L0 |
| **L2** | Finish `${}` interpolation, kill `__i32_to_string` | Do | S–M | A6 traits, L1 |
| **L3** | `ref` params + opaque `ptr` | Do (no raw pointers) | M | L1 |
| **L4** | `crypto` namespace over wolfCrypt | Do (best ratio) | M | binary-safe strings |
| **L5** | `text` namespace + regex | Do | XL (regex ≈ weeks) | UTF-8 (C2) |
| **L6** | i18n / l10n (web-first) | Do (scoped) | L | L5, C4 |

**Sequence:** **L0** → `binary-safe strings` → **L1** → (**L2** ‖ **L3** ‖ **L4**) → `UTF-8` → **L5** → **L6**

**Two blockers first:** (1) the live string heap bug (ASAN: wild read in `string_slice` ⇒ a string with a
garbage length header — see `lang/repro/driver_alloc_churn_crash.ky`); (2) binary-safe strings
(`kyte_from_bytes(ptr,len)`). L2/L4/L5/L6 all pile onto the string path — fix it before building on it.

---

## L0 — Spec rewrite (inventory + reference) — ✅ DONE

`docs/specs.md` was **rewritten from scratch** (2026-07-15) against the implementation and now serves as
**the** inventory, reference manual and spec. The old v0.6.0 doc (dated 2025-07-05, *"Status: Planning"*)
was discarded wholesale — it was a plan in the present tense, and therefore actively misleading.

**Why this had to come first — it immediately caught two errors in this very plan:**

1. L2 originally proposed *"add string interpolation"* + a `text.format`. **Kyte has had ES6 template
   strings all along** (`lexer.zig:40`, `ast.zig:296`, used at `fs.ky:50`). The plan was inventing a
   shipped feature.
2. The old spec asserted *"There is no tuple type in v1"* — `tuple` **is** in the AST.

It also surfaced 💥 `${i64}`/`${f64}` **segfaulting at runtime while compiling clean** — a hole nobody
knew about because no corpus case covered it.

**What makes it different from the doc it replaced:**

- **Status marks per feature** — ✅ pinned / ⚠️ caveat / 💥 broken / 🔎 unverified / ❌ absent. "Does it
  exist" was never the useful question; "can I trust it" is.
- **`IS` is separated from `WILL BE`.** Everything unbuilt is quarantined in §12 and never present-tense.
- **§10 known-broken index** — the highest-value section. A green-looking API that crashes costs more
  than a missing one.
- **§11 canonical style** — one way per task (format → template strings; concurrency → `go`; timing →
  `nowNs`), which is what stops the divergence.
- **§13 ties features to the corpus** — no case ⇒ *unverified by construction*.

**Follow-ups (not done):** generate the keyword/AST/stdlib tables from source so additions appear
automatically; a CI check failing a new keyword/module with no reference entry.

---

## L1 — Honest primitive types

### The problem (measured, not stylistic)

`types.zig:42` maps `i32`, `u32`, `int`, `uint` **all to one `val_type`**, and `llvm_codegen.zig:240`
sets `val_type = i64 (native) / i32 (wasm)`. Consequences, all verified:

```kyte
let a: i32 = 5000000000;   // prints 5000000000 on native. i32 is NOT 32 bits.
                           // on wasm the same line truncates -> different arithmetic, same source.
let u: uint = 0 - 1;       // "unsigned" is not unsigned.
```

So: fixed-width names lie, `int` is already just an alias, and the language has **no portable numeric
semantics**. This is a correctness bug and it is the reason `__i32_to_string` can print 64-bit values.

### Target type table

| Kyte | Width | Signed | Notes |
|---|---|---|---|
| `bool` | 1 | — | |
| `byte` / `sbyte` | 8 | u / s | |
| `short` / `ushort` | 16 | s / u | |
| **`int`** / `uint` | **32** | s / u | **the default integer** |
| `long` / `ulong` | 64 | s / u | timestamps, counters, file sizes |
| `float` / `double` | 32 / 64 | — | |
| `string`, `void` | — | — | |
| `ptr` | word | — | opaque; FFI/`bytes` only (see L3) |

`i8/i16/i32/i64/u8/…/f32/f64` remain as **explicit fixed-width aliases** for FFI and binary code — but
only once they *honestly* carry those widths. Same types, precise spelling.

### Value vs reference semantics — already correct; the *widths* are not

**Everything above except `string` is a value type on the stack, and that is already how it works:**
`arc.zig:11` `isRefCountedType` returns **false** for primitives (also enums, closures), with the
comment *"Any other type (strings, lists, maps, structs) are reference counted pointers"*; locals and
params are `LLVMBuildAlloca` stack slots. `string` is heap + ARC because it is variable-length. **No
change needed to that model — it is the intended design and it is what ships.**

**The defect is the slot width.** `declarations.zig:884` allocates **every** local/param as
`compiler.val_type` — one uniform **i64 slot regardless of declared type**:

- a `byte` occupies 8 bytes; a `bool` occupies 8 bytes;
- an `f64` lives in an **integer** slot and is *reinterpreted as bits* (hence the "reinterpret bits as
  double, then FPToSI" path in `expressions.zig:1867`, the earlier `as`-cast bugs, and — very likely —
  the `${f64}` segfault in L2).

So L1's job is not "move primitives to the stack" (done) but: **make each value's storage its real
type** — `alloca i8` for `byte`, `alloca double` for `double`, `alloca i32` for `int` — so widths,
overflow, and float ops are honest rather than i64-bit-punned.

**Decision: `int` = 32-bit on every target.** Rationale: it matches C#/Java/TypeScript expectations
(Kyte already leans that way), it is efficient on wasm, and it's honest. The alternative (`int` = 64)
means less migration churn but permanently surprises newcomers and keeps a 64-bit `int` on a 32-bit
target. **Whichever is chosen, the width must be identical on native and wasm** — that per-target split
is the actual bug.

**Consequence to plan for:** 32-bit `int` breaks today's "heap address stashed in an `i32`" idiom
(`bytes.alloc` → `Reader.buf: i32`), which only works because `int` is secretly 64-bit. That's why L3's
`ptr` type is not optional — it's the honest replacement.

### Examples

```kyte
// ---- before (today) ----
fn hash(s: string, seed: i32): i32 { ... }
let n: i32 = 5000000000;              // silently OK natively, truncates on wasm
let t: i32 = datetime.now();          // seconds; Y2038 lands in an "i32" that is secretly 64-bit

// ---- after ----
fn hash(s: string, seed: int): int { ... }

let n: long = 5_000_000_000;          // explicit 64-bit
let small: int = 42;
let b: byte = 255;
let ratio: double = 0.5;
let t: long = datetime.now();         // 64-bit timestamps by construction (C4)

let bad: int = 5_000_000_000;         // COMPILE ERROR: literal out of range for `int` (max 2147483647)

// widening is explicit; narrowing must be a cast
let w: long = small;                  // ok: int -> long widens
let narrow: int = (n as int);         // explicit, truncates by documented rule
```

### Work

1. One canonical `PrimType` table in `types.zig` replacing the string-compare chains (~48 `"i32"` sites).
2. Real narrowing/truncation + unsigned ops in codegen (`u*` must use unsigned compares/div/shr).
3. Literal range checking in the type checker (the `bad` case above).
4. Mechanical migration of ~367 stdlib annotations; `ptr` for the pointer sites (L3).
5. Negative tests pinning widths (`int` overflow, `byte` wrap, unsigned compare, wasm==native parity) so
   this can never silently regress.

---

## L2 — Conversions & formatting

> **Corrected 2026-07-15.** An earlier draft of this section proposed "add string interpolation" and a
> `text.format`. **Both were wrong — Kyte already has ES6 template strings**, and `format` isn't needed.
> This is precisely the failure mode L0 exists to prevent: *inventing a feature that already ships.*

### What actually exists today (measured)

Kyte **already has** backtick template strings with `${}` interpolation — `lexer.zig:40-41`
(`template_string`, `interpolated_string`), `readTemplateString` on `` ` ``, `ast.zig:296`
(`template_expr`), parser at `1787/2075/2166`. It is used in the stdlib: `fs.ky:50` →
`` writeFsFile(`watch_test_dir/changed_${count}.txt`, "content") ``.

**But it is half-finished, and it fails at *runtime*, not compile time:**

| `${x}` where x is | Result |
|---|---|
| `int` | ✅ works |
| `bool` | ✅ works |
| `string` | ✅ works |
| **`i64` / `long`** | 💥 **SIGSEGV** (compiles clean) |
| **`f64` / `double`** | 💥 **SIGSEGV** (compiles clean) |

Same root as the builtins: only `__i32_to_string` / `__bool_to_string` exist (22 uses in-tree) — there
is **no `__i64_to_string`, no `__f64_to_string`**. Printing an `i64`/`f64` while building the YCSB bench
was impossible without hand-scaling to int. Very likely compounded by L1's slot problem (an `f64` living
in an `i64` stack slot and being reinterpreted).

### Design — two layers, not three

```kyte
// ---- before ----
console.log("count = " + __i32_to_string(n));   // low-level plumbing in user code
console.log("ratio = " + ???);                  // impossible: no __f64_to_string
console.log(`ratio = ${ratio}`);                // SIGSEGV today

// ---- after ----
// 1. ToString trait (needs A6) — every primitive implements it
console.log("count = " + n.toString());

// 2. template strings — ALREADY THE LANGUAGE'S WAY. Finish them, don't reinvent them.
console.log(`count = ${n}, ratio = ${ratio}, when = ${ts}`);   // int, double, long all work
```

**No `text.format`.** Template strings already cover the need; a second formatting API would be exactly
the "different different things" divergence to avoid. *(If width/precision is ever wanted, add it inside
the interpolation grammar — e.g. `${ratio:0.00}` — not as a rival function.)*

**`as` stays a bit-level numeric cast — it will NOT stringify:**

```kyte
let i: int = (d as int);        // double -> int, truncates
let d2: double = (i as double);
let s = n as string;            // COMPILE ERROR: use n.toString() / `${n}`
```

Overloading `as` for formatting conflates *representation* with *rendering* — a permanent wart.

### Work

1. **Fix `${}` for every primitive** (i64/f64 first — they segfault today). Interpolation lowers to
   `toString()`; add a corpus case per primitive so a silent runtime hole can't come back.
2. `ToString` trait + primitive impls (A6).
3. Migrate the 22 `__*_to_string` sites to `${}` / `.toString()`; **delete the injected builtins**.
4. Pick ONE canonical way in the style guide (template strings) and say so in L0's reference.

---

## L3 — `ref` params and an opaque `ptr`

### The problem

Structs already pass **by reference** (heap + ARC — mutating a param's field is visible to the caller).
Primitives pass by value and there is **no way to write an out-param**. Meanwhile the stdlib fakes
pointers by stashing heap addresses in `i32` fields — which L1 will break.

### Examples

```kyte
// ---- before: no out-params; a cursor had to be a struct or a return value ----
fn readByte(pos: int, buf: ptr): int { ... }   // caller must thread `pos` back manually

// ---- after ----
fn readByte(ref pos: int, buf: ptr): byte {
    let b = bytes.readByte(buf, pos);
    pos = pos + 1;                  // visible to the caller
    return b;
}

var p = 0;
let b0 = readByte(ref p, buf);      // `ref` at the CALL SITE too — mutation is never invisible
let b1 = readByte(ref p, buf);      // p is now 2

fn swap(ref a: int, ref b: int): void { let t = a; a = b; b = t; }

// structs already behave this way — no `ref` needed, and that stays true
fn bump(s: Stats): void { s.ops = s.ops + 1; }   // caller sees it
```

```kyte
// ---- the pointer idiom, made honest ----
// before: a 64-bit heap address smuggled through a 32-bit-named field
pub struct Reader { pub buf: i32, init(){ self.buf = bytes.alloc(65536); } }

// after
pub struct Reader { pub buf: ptr, init(){ self.buf = bytes.alloc(65536); } }
// `ptr` is opaque: no arithmetic, no implicit int conversion; only bytes.* / FFI consume it.
```

**Rejected: raw C pointers (`*T` / `&x`).** They fight ARC (who retains?), break the WASM target, and
undermine the safety story. The real need is out-params and an honest FFI handle — `ref` + `ptr` cover
both.

### Work

Parser (`ref` in params **and** args), codegen (pass the alloca, auto-deref at uses), checker (ref args
must be lvalues; no ref-to-temporary; `ptr` is opaque — no arithmetic, no implicit int conversion).

---

## L4 — `crypto` over wolfCrypt

### The problem

**Crypto is fake today.** `runtime/core.cpp:202`:

```cpp
char *kyte_sha256(const char *input) { return kyte_from_cstr(input ? "" : ""); }   // returns ""
char *kyte_md5   (const char *input) { return kyte_from_cstr(input ? "" : ""); }
```

…while `crypto.ky`'s own `@test` asserts `sha256("hello") == "2cf24dba…"` — passing vacuously.
wolfSSL is already vendored, built and linked (`deps/wolfssl/build/libwolfssl.a`, `-DKYTE_HAVE_WOLFSSL`);
wolfCrypt is sitting there unused.

**Blocker:** `kyte_from_cstr` is NUL-terminated ⇒ it cannot carry raw bytes. Digests can dodge via hex,
but `randomBytes`/AES/sign cannot. Land `kyte_from_bytes(ptr,len)` first.

### Examples

```kyte
import crypto.hash;
import crypto.hmac;
import crypto.random;
import crypto.encode;
import crypto.aead;

let hex  = hash.sha256("hello");                 // "2cf24dba5fb0a30e..."
let raw  = hash.sha256Bytes("hello");            // binary-safe (needs kyte_from_bytes)
let mac  = hmac.sha256(key, message);
let hk   = kdf.pbkdf2(password, salt, 600000, 32);

// CSPRNG — the ONLY thing allowed near secrets
let sessionId = encode.base64Url(random.bytes(32));
let n         = random.int(0, 100);

// AEAD
let ct = aead.aesGcmSeal(key, nonce, plaintext, aad);
let pt = aead.aesGcmOpen(key, nonce, ct, aad);   // string | undefined  (undefined = auth failure)

// constant-time compare — never `==` on a secret
if (crypto.constantTimeEquals(givenToken, expectedToken)) { ... }
```

```kyte
import crypto.prng;
// Deterministic, seeded — tests / benchmarks / simulation ONLY. Separate namespace so
// "I used the fast RNG for a session id" is a visible mistake, not an invisible one.
var rng = prng.Prng(12345);
let k = rng.int(0, 1000);
let d = rng.double();
```

### Work

`runtime/crypto.cpp` in the unity build, included **after `io.cpp`** (which already sequences wolfSSL's
`options.h` against Asio). Every entry guarded by `KYTE_HAVE_WOLFSSL` with an **honest error** when
absent — never a silent empty-string stub again. Then `std/crypto/*.ky` + NIST KATs in the corpus.
**Unblocks D4**: session IDs/CSRF are insecure today precisely because there is no CSPRNG.

---

## L5 — `text` namespace + regex

### Hard prerequisite: UTF-8 (C2)

Today's string is **ASCII-only**. Regex over bytes and localization over ASCII are both nonsense — `.`
must match a codepoint; `toUpperCase` must know `ß`/`İ`. **Do not start regex before UTF-8 lands.**

### Layout

`text.string`, `text.stringBuilder`, `text.regex`, `text.locale`, `text.i18n`. Moving `string` +
`collections/string_builder` churns every import — batch it with L1's signature sweep.

### Examples

```kyte
import text;

let s = "héllo wörld";
text.length(s);                 // 11 codepoints (NOT 13 bytes)
text.byteLength(s);             // 13
text.charAt(s, 1);              // "é"
text.toUpperCase(s);            // "HÉLLO WÖRLD"

let sb = text.StringBuilder();
sb.append("a"); sb.appendLine("b");
let out = sb.toString();
```

```kyte
import text.regex;

// Compile once, reuse (compilation is the expensive part)
let re = regex.compile("^/users/(\\d+)/posts/(\\d+)$");

let m = regex.match(re, "/users/42/posts/7");     // Match | undefined
if (m != undefined) {
    let uid = m.group(1);       // "42"
    let pid = m.group(2);       // "7"
}

// named groups read better in routes
let route = regex.compile("^/users/(?<id>\\d+)$");
let rm = regex.match(route, "/users/42");
if (rm != undefined) { let id = rm.name("id"); }

regex.test(re, path);                          // bool
regex.replace(re2, input, "***");              // string
regex.split(regex.compile("\\s+"), "a  b c");  // List<string>
for (m in regex.findAll(re3, doc)) { ... }
```

### Engine — ✅ **use Boost.Regex** (revised 2026-07-15)

An earlier draft said "implement a Thompson NFA in Kyte (~weeks)". **That was wrong: Boost.Regex is
already installed and prebuilt** — `/opt/homebrew/include/boost/regex.hpp` +
`libboost_regex.a`/`.dylib`, Boost **1.90.0**. Boost.Asio is already the runtime's backbone, so this is
the *same* dependency family, not a new one. **This saves weeks.**

**But three facts have to be designed around — none are blockers, all are real:**

1. ⚠️ **Boost.Regex backtracks.** It is Perl-compatible, so **ReDoS is possible** — the thing a Thompson
   NFA would have given us for free, and it matters because these regexes will touch routes and user
   input. **Mitigation is available and mandatory:** cap it via `BOOST_REGEX_MAX_STATE_COUNT` /
   `match_flag_type` so a pathological pattern raises an **error instead of hanging**. Bounded, not
   immune — so the wrapper must never expose an unbounded match, and untrusted patterns stay a
   documented no-go.
2. ⚠️ **Unicode needs ICU.** Plain `boost::regex` is **narrow-char/byte** oriented. UTF-8-aware matching
   (`.` = one codepoint, Unicode classes) is `boost::u32regex` from `boost/regex/icu.hpp`, which
   **requires ICU** — and the installed Boost was built **without** it (see L6). So: byte-regex is free
   today; **codepoint-regex is gated on the ICU decision**.
3. ⚠️ **The runtime links no Boost lib today** (Asio is header-only). Boost.Regex is a **compiled**
   library, so it changes the runtime build *and every user-program link*, and it is **hostile to the
   WASM target** — which `CLAUDE.md` calls a primary target wanting "a small, runtime-free binary".
   WASM is currently on hold, so this is a *deferred* conflict, not an immediate one — but do not
   pretend it isn't one.

**Decision:** bind Boost.Regex for **native**, behind a thin Kyte-facing API (`text.regex`) that hides
`boost::regex` entirely — so a future pure-Kyte or ICU-backed engine can be swapped underneath without
touching a line of user code. Revisit a hand-written NFA only if/when WASM demands it.

**v1 scope:** literals, classes, escapes, anchors, `. * + ? {n,m}`, alternation, groups (capturing,
named, non-capturing), lazy quantifiers. **Deliberately not exposed:** unbounded catastrophic patterns
(capped), and — pending ICU — Unicode-aware classes.

---

## L6 — i18n / l10n (web-first)

Kyte is a **web** language: the *first* thing a real app needs after routing is "render this in the
user's language and locale". This is a first-class stdlib concern, not an afterthought.

### 🔑 Design decision (2026-07-15): **delegate formatting to the browser's `Intl`; the stdlib keeps only what the browser cannot do**

Asked: *"can i18n be handled in HTML itself, from within the browser, so we don't need it in the
stdlib?"* — **Mostly yes, and it is the best cost-cut on this plan. It deletes the ICU question for
i18n.**

**Every browser already ships ICU**, exposed as `Intl`, at **zero payload**:

| Need | Browser gives it free | Server cost if we do it |
|---|---|---|
| Number / currency / percent | `Intl.NumberFormat` | CLDR tables |
| Dates / times / timezones | `Intl.DateTimeFormat` | CLDR + tz |
| **Plural category selection** | **`Intl.PluralRules`** (full CLDR) | CLDR plural rules |
| "3 days ago" | `Intl.RelativeTimeFormat` | CLDR |
| "a, b and c" | `Intl.ListFormat` | CLDR |
| Sorting | `Intl.Collator` | **ICU-sized** collation tables |
| Word/grapheme boundaries | `Intl.Segmenter` | **ICU-sized** |
| Bidi rendering, hyphenation, font choice | `<html lang dir>` | — |
| Locale preference | `Accept-Language` (sent automatically) | — |

**⇒ Drop all of that from the stdlib.** Re-implementing it server-side means shipping ICU (~30MB) to
duplicate something already in the client, for free, better maintained.

### But three things the browser genuinely cannot do

1. **Translations.** `Intl` **formats**; it does **not** translate. The French *words* come from your
   catalogs. There is no browser API for "what is 'cart.empty' in fr-FR".
2. **Server-rendered HTML — which is Kyte's whole point.** `CLAUDE.md` positions Kyte for
   *"hypermedia applications"* (NSX views, ASP.NET-style). If the server emits the HTML, **the
   translated strings must exist server-side**. Client-side translation means the first paint is
   untranslated — fatal for SEO, crawlers, `<title>`, meta/OG tags, `hreflang`, and no-JS clients. A
   hypermedia framework cannot outsource its text to the client.
3. **Non-HTML output.** Emails, PDFs, SMS, API error messages, logs, CSV exports. **No browser
   involved.**

### The split — what actually stays in the stdlib (small)

| Stays server-side (`text.i18n`) | Why | Cost |
|---|---|---|
| Locale **negotiation** (`Accept-Language` → best match + fallback) | must pick before rendering | ~100 lines, no ICU |
| **Message catalogs** + lookup + fallback chain + missing-key reporting | browser has no translations | small |
| **CLDR plural *rules*** (to pick a form when server-rendering) | needed to emit "3 articles" | **~KB, not ICU** — plural rules are a tiny compiled table (what `messageformat` ships); the 30MB in ICU is collation/tz/transliteration/display-names, **not** plurals |
| `lang` / `dir` metadata, `Content-Language`, `Vary: Accept-Language` | response correctness | trivial |
| Minimal number/date formatting **for non-HTML output** (emails/PDF) | no browser there | keep small; don't chase CLDR parity |

| Delegated to the browser | How |
|---|---|
| All rich formatting in **interactive** views | `Intl.*` from NSX/JS |
| Sorting, segmentation | `Intl.Collator` / `Intl.Segmenter` |
| Bidi, hyphenation | `<html lang dir>` |

### Consequences

- ✅ **ICU is no longer needed for i18n.** The remaining server-side piece (negotiation + catalogs +
  plural rules) is **ICU-free and small** — L6 drops from **L → S/M**.
- ⚠️ **The ICU question does not disappear entirely** — it still governs **`boost::u32regex`** (L5
  Unicode regex) and any server-side collation. But that is now a *regex/text* decision, not an i18n one,
  and it is much easier to say no to.
- ✅ **Boost.Locale is largely unnecessary too.** Its value was CLDR formatting — which the browser does.
  We'd use it, if at all, only for gettext `.mo` catalog loading; a plain catalog reader may be simpler
  than the dependency.

**Rule of thumb:** *the server decides **which language** and supplies **the words**; the browser decides
**how the numbers, dates and sorting look**.*

---

### Engine — Boost.Locale: ⚠️ now mostly *not* needed (kept for reference)

**Revised 2026-07-15.** An earlier draft said "hand-roll CLDR tables; do not vendor ICU". **Boost.Locale
is already installed and prebuilt** (`boost/locale.hpp` + `libboost_locale.a`/`.dylib`, Boost 1.90.0) —
so hand-rolling is off the table. But there is a catch that decides how much this actually buys:

> ⚠️ **The installed `libboost_locale.dylib` does NOT link ICU.** `otool -L` shows only
> `boost_thread/chrono/container/atomic`. Homebrew built it **without the ICU backend** — so out of the
> box it falls back to the **std/posix** backends. ICU4C **78 is installed**, but keg-only
> (`/opt/homebrew/opt/icu4c/lib`), i.e. not linked into Boost as shipped.

**What that costs, concretely — this is the fork in the road:**

| | Boost.Locale **without** ICU (as installed) | Boost.Locale **with** ICU |
|---|---|---|
| Message catalogs (gettext `.mo`) | ✅ | ✅ |
| Plurals | ⚠️ gettext `Plural-Forms` only (a C expr in the catalog header) | ✅ **full CLDR** rules |
| Number / currency / date formatting | ⚠️ via `std::locale` facets — weak, platform-dependent | ✅ real CLDR |
| Collation | ⚠️ weak | ✅ |
| Boundary analysis (segmentation) | ❌ | ✅ |
| Case conversion | ⚠️ ASCII-ish | ✅ full Unicode |
| **Unicode regex** (`boost::u32regex`, L5) | ❌ | ✅ |
| Cost | free — it's already built | ICU dep: **~30MB**, distribution + cross-platform build, **hostile to WASM** |

**The tension is real and worth naming:** `CLAUDE.md` calls WASM a primary target wanting *"a small,
runtime-free binary"*. ICU is the opposite of that. But WASM is **currently on hold**, and *without* ICU
the two things this item exists for — **CLDR plurals** and **codepoint-correct text** — are exactly what
you don't get.

**Recommendation: take ICU for the native target, gate it behind a build flag.**
`KYTE_HAVE_ICU`, mirroring the existing `KYTE_HAVE_WOLFSSL` pattern — full i18n + Unicode regex where
ICU is present, an honest degraded path (gettext plurals, no `u32regex`) where it isn't, and **never a
silent stub** (that is exactly how `crypto.sha256` came to return `""`). Keep the Kyte-facing API
(`text.i18n`, `text.regex`) identical either way, so the backend is swappable and WASM can later take a
different one without touching user code.

**Decide before building L5/L6:** ICU or not. Everything below assumes *with* ICU; without it, plurals
degrade to gettext `Plural-Forms` and `text.length` stays byte-oriented.

### The web request path

```kyte
import text.i18n;

// 1. Negotiate a locale from the request (RFC 4647 lookup + q-values)
let loc = i18n.negotiate(
    req.header("Accept-Language"),          // "fr-FR,fr;q=0.9,en;q=0.8"
    ["en-US", "fr-FR", "ar-EG"],            // what we actually ship
    "en-US"                                 // fallback
);                                          // -> Locale("fr-FR")

// 2. Per-request locale in context, so views/handlers don't thread it by hand
ctx.locale = loc;

// 3. Tell caches/clients what we produced
res.header("Content-Language", loc.tag());  // "fr-FR"
res.vary("Accept-Language");                // correctness for shared caches
```

### Messages + plurals (the part everyone gets wrong)

```
# locales/fr-FR.msg
cart.items    = {count, plural, one {# article} other {# articles}}
cart.empty    = Votre panier est vide
user.greeting = Bonjour, {name} !
```

```kyte
i18n.t(loc, "cart.items", { count: 0 });      // "0 articles"
i18n.t(loc, "cart.items", { count: 1 });      // "1 article"
i18n.t(loc, "cart.items", { count: 3 });      // "3 articles"
i18n.t(loc, "user.greeting", { name: n });    // "Bonjour, Amélie !"

// Arabic exercises all six CLDR plural categories — the reason a naive
// `if (n == 1) singular else plural` is wrong in most of the world.
i18n.t(ar, "cart.items", { count: 2 });       // dual form
```

Plural selection uses **CLDR plural rules** (`zero/one/two/few/many/other`) per locale — not `n == 1`.
Missing keys fall back along the chain `fr-FR → fr → en-US` and are reported (never silently blank).

### Formatting

```kyte
i18n.number(loc, 1234567.89);            // fr-FR: "1 234 567,89"   en-US: "1,234,567.89"
i18n.currency(loc, 42.5, "EUR");         // fr-FR: "42,50 €"        en-US: "€42.50"
i18n.percent(loc, 0.755);                // "75,5 %"
i18n.date(loc, ts, .medium);             // "15 juil. 2026"          (needs C4 timezones)
i18n.time(loc, ts, .short, tz);          // "14:30"
i18n.relativeTime(loc, -3, .day);        // "il y a 3 jours"
i18n.list(loc, ["a","b","c"]);           // "a, b et c"
```

### Direction (RTL) — cheap, and web-visible

```kyte
loc.direction();     // .ltr | .rtl
```

```nsx
<html lang={loc.tag()} dir={loc.direction()}>
  <p>{t("cart.items", { count: n })}</p>
</html>
```

Direction metadata + `lang`/`dir` attributes get ~90% of RTL correctness for free (the browser does the
bidi rendering). Full bidi *processing* stays out of scope.

### Scope boundary

| In | Out (use a binding if ever needed) |
|---|---|
| Locale negotiation, catalogs + fallback chain | Collation / locale-aware sorting |
| CLDR plural + ordinal rules | Bidi algorithm (browser does it) |
| Number / currency / percent / date / time / relative-time / list | Full case-mapping & segmentation tables |
| `dir` metadata, `Content-Language`, `Vary` | Transliteration, calendars beyond Gregorian |
| Extraction tooling (`kyte i18n extract`) | |

### Work

`text.locale` (tag parse/negotiate/fallback), `text.i18n` (catalog loader, ICU-style message parser,
CLDR plural rules, formatters), CLDR data as generated Kyte tables (a subset, per-locale, additive), and
`kyte i18n extract` to pull keys out of source/NSX. Depends on **L5** (UTF-8 + regex for the message
parser) and **C4** (timezones for dates).

---

## Milestones

| M | Contains | Exit criteria |
|---|---|---|
| **L-0** | binary-safe strings; **fix the string heap bug** | `driver_alloc_churn_crash.ky` passes; ASAN clean under churn |
| **L-1** | L1 types | corpus pins widths; native==wasm arithmetic; stdlib migrated; `ptr` in place |
| **L-2** | L2 ‖ L3 ‖ L4 | `__*_to_string` deleted; `ref`/`ptr` shipped; crypto passes NIST KATs; D4 unblocked |
| **L-3** | UTF-8 (C2) → L5 | codepoint-correct text; regex v1 + ReDoS-resistance tests |
| **L-4** | L6 | negotiation + plurals + formatters; a demo app served in en/fr/ar |

## Risks

- **L1 is a big sweep.** ~367 stdlib annotations + ~48 compiler sites. Mitigation: land behind the
  corpus in one pass; add width negative-tests *first*.
- **`int` = 32 breaks the pointer idiom by design.** That's the point — but L3's `ptr` must land in the
  same milestone or the stdlib won't compile.
- **Regex is weeks, not days.** Don't start it before UTF-8; don't let it block L4/L6 planning.
- **i18n scope creep toward ICU.** Hold the boundary table above. Collation is the usual gateway.
- **The heap bug is upstream of all of it.** L2/L4/L5/L6 all pile onto the string path.
