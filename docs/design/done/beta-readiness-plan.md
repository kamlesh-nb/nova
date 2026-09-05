# Kyte → Beta: The Final Plan

> **👉 For F1–F5 status, read `design/FOUNDATION-STATUS.md` — that is the board (scorecard +
> per-stage evidence + remaining-work task IDs). This file is the append-only progress log; scan the
> board first, dig here for the narrative.**

**Status:** Plan of record. Written 2026-07-17.
**Supersedes** the sequencing in `kyte-readiness-roadmap.md` and `kyte-language-evolution-plan.md` (both
substantially stale — see §5). **Does not supersede** `design/F1–F5` (the current foundation program) or
`runtime-cpp20-plan.md` (the current runtime program); this document *sequences* them and adds what
neither covers.

**Method.** Every state claim below was **measured** against the tree on 2026-07-17, not read from a doc.
Several long-standing doc claims did not survive that (§5). Where this plan says "works" or "broken",
there is a command behind it. Two of my own intermediate findings were **wrong** and were caught by
controls — that is the standard this plan holds itself to, and the reason §0 exists.

---

## ⏱ Progress log — 2026-07-18e (Lane A: map<U> residual FIXED at the sema layer — no method-mono needed)

`f35d8b4`. The `map<U>` residual (18d's NEXT) is fixed — and NOT the way 18d predicted. It was never a
codegen problem; it was a **sema** one. `xs.map((x) => `val${x}`)` typed as `List<U>` because the closure
arg was probed in a vacuum: `x` has no annotation, so it inferred `.unresolved`, `U` never solved, and the
erased `List_i32_map` body pushed string elements without retaining — **303 leaked / 100 iterations**,
values correct but the result type (`List<U>`) was a lie.

Fix (one seam): `inferExprQuietly` gained an `expected: ?TypeId`, and the solveParams loop hands each
declared param type `dp` (the method's `(T) -> U`) down as the closure's expected type. The param pins, the
body types, `U` solves to `string`, and the call is a real `List<string>` — an **owned** value the caller
releases, which balances the erased body's un-retained pushes.

**Result: 303 live → 3 (the harness floor = fully leak-free), values correct.** Gates: corpus **59/59**,
`--arc` **100/100**, `--asan` **100/100**, `zig build test`. New permanent gate `40_map_refcounted_closure`
(single + loop variants, arc-baseline 3) pins it.

KEY LESSON: the earlier method-level monomorphization attempt (specialized `List_int_map_string` bodies)
was **unnecessary AND actively harmful** — it made this exact case emit garbage (`Expected "val1", got
"�"`) from inconsistent string-resolution vs store-ownership inside the specialized body. Reverted in full;
kept only the (correct, orthogonal) sema fix. Method-mono is a **pure-optimization** follow-up, not a
correctness requirement — the erased body + correct result typing is already sound.

NEXT: delete the `substTypeParams`/`isOwnedRenderedFallback` reliance as remaining sites clear, then the
other decision families (getTypeSize/toLLVMType TypeId versions) — each behind the same shadow-diff.

## ⏱ Progress log — 2026-07-18d (Lane A: keystone CUT OVER — first real string→TypeId cutover)

`isOwnedTypeId`'s `.type_param` branch now substitutes against `current_instantiation_id` IN THE STORE
(`subst.substitute` → concrete TypeId → `store.isOwned`) instead of `substTypeParams` on a rendered
string. **Byte-identical** — shadow proved `disagree=0` and it STAYS 0 after cutover. Falls back to the
string path only for erased-body compiles (no inst ctx) or method-level params (`map<U>`). All 5 gates
green. **This is the first real string→TypeId cutover: struct-level type_param ownership decisions no
longer touch the string engine.**

NEXT: the `map<U>` residual (method-instantiation context so `still-blocked` → 0), then delete the
`substTypeParams`/`isOwnedRenderedFallback` reliance as the remaining sites clear, then the other
decision families (getTypeSize/toLLVMType TypeId versions) — each behind the same shadow-diff.

## ⏱ Progress log — 2026-07-18c (Lane A: keystone SHADOW landed — store substitution PROVEN correct)

Built the keystone shadow-first (all 5 gates green, report-only). Enabling state:
`mono.live_inst_ids` (instantiation name→TypeId) + codegen `current_instantiation_id`. The shadow-diff
harness now, for each `.type_param` ownership decision, substitutes it against the instantiation IN THE
STORE (`subst.substitute`) and compares the concrete result's ownership to today's string answer.

**Measured (13_serde / 14_map / 12_traits):**
- **keystone-DISAGREE = 0** — store substitution gives the EXACT same ownership answer as the string
  path. ⟹ the cutover is byte-identical-safe (proven, not hoped).
- **KEYSTONE-RESOLVES 193 / 79 / 120** — the struct-level `.type_param`s (~half the blocked sites)
  resolve correctly.
- **still-blocked 128 / 106 / 106** — method-level params (`map<U>`) + erased-body compiles (no inst
  ctx). The known method-mono follow-up, NOT a blocker for the struct-level cutover.

NEXT: **cut over** `isOwnedTypeId`'s `.type_param` branch to `subst.substitute` (store) instead of
`substTypeParams` (string) — disagree=0 makes it byte-identical; verify `td_blocked_typeparam` falls +
`td_disagree` stays 0 + all 5 gates. Then the method-instantiation context for the `map<U>` residual.

## ⏱ Progress log — 2026-07-18b (Lane A: shadow-diff harness LANDED — migration de-risked to ONE keystone)

Built the **string→TypeId shadow-diff harness** (report-only under KYTE_SEMA_SHADOW; all 5 gates green):
at every ownership decision (`isOwnedTypeId`) it computes BOTH the typed `store.isOwned(t)` and the
legacy `isRefCountedType(renderLegacy(t))` and classifies CONCRETE(agree/disagree) vs BLOCKED
(`.type_param`/`.unresolved`/`.enum_`). This is THE safety net — it turns "did I break an unexercised
path?" into a measured number before any cutover.

**Measured (13_serde / 14_map / 12_traits):**
- **DISAGREE = 0** everywhere — the two engines agree on EVERY concrete type ⟹ the migration is
  byte-identical-safe for the concrete sites.
- **~94% of ownership decisions are ALREADY TypeId-decidable** (4842/5163, 3054/3239, 3117/3343).
- **The blocked ~6% is ~100% `.type_param`** (unresolved=0, enum_=0 at the ownership level).

⟹ **The whole ARC-ownership migration collapses to ONE keystone**: per-instantiation typing to
eliminate `.type_param` at codegen. F2-5 (unresolved) and enum-awareness are NOT blockers at the
ownership-decision level. Drive `td_blocked→0` via the keystone, keep `td_disagree=0`, delete
`isRefCountedType`. Gate/verify: `KYTE_SEMA_SHADOW=1 kyte test <case>` → the
`string→TypeId shadow-diff` block. NEXT: build the keystone (per-instantiation re-typing via
`subst.substitute`, behind this shadow-diff — the blocked count must fall and disagree must stay 0).

## ⏱ Progress log — 2026-07-18 (Lane A: string→TypeId migration, SCOPED)

**Decision (user):** stop the piecemeal string-based ARC band-aids (they ADD string machinery — the
wrong layer, and the cause of the "fix one leak, break another" churn). Do **Lane A**: finish the
foundation *properly* by completing the string→TypeId migration in order. **First: scope it.** Done.

**The scope, measured** (4 parallel code inventories) — full plan in
`docs/design/string-to-typeid-migration.md`:
- **THE KEYSTONE:** monomorphization substitutes at RENDER TIME on strings, not in the store — an expr
  inside `List<T>`'s body carries a `.type_param` TypeId; codegen renders→string-substitutes it. The
  migration is blocked by this ONE architectural gap, not the ~450 call sites. Fix = a sema pass that
  re-types each generic body's `expr_types` per instantiation via the EXISTING `subst.substitute`
  (subst.zig:40) → concrete store TypeIds keyed `(ExprId, inst)`. Both scaffolding halves exist
  (`mono.Worklist.seen` + `subst.substitute`); only the join is missing.
- **Surface:** 2 string manufacturers (`resolveExpressionTypeName` 38, `typeRefToString` 42), ~35
  decision fns / ~450 call sites, ~35 string-surgery sites (**nearly all wasteful round-trips**:
  structured→renderLegacy→re-parsed), 5 `[]const u8` state fields (2 partial TypeId parallels).
- **Blocker confirmed:** `TypeStore.isOwned` panics on `.type_param`/`.unresolved` (types.zig:364-365);
  ~7,157 exprs reach codegen with those → string path mandatory until eliminated.
- **Order:** (1) keystone per-instantiation typing → (2) F2-5 unresolved-fatal → (3) flip isOwned arms
  + delete isRefCountedType (enum-variant awareness the one sub-piece) → (4) mechanical conversion of
  ~450 sites + delete the round-trip string-surgery (semi-scriptable + shadow-diff) → (5) complete
  state parallels, delete string maps.
- **Automation verdict:** ~70% is architectural (keystone/F2-5/enum/sizing — NOT scriptable); a script
  is a HELPER for step 4's uniform sites + a **shadow-diff harness** (compute TypeId-answer vs
  string-answer at every site, count agreement) — the safety net that converts "did I break an
  unexercised path?" into a measured number before cutover.
- **Why it converges:** every step REMOVES string sites, never adds them (unlike the band-aids). Finite
  and monotone. Reverted the in-progress method-specialization band-aid; tree green, 58/58.

## ⏱ Progress log — 2026-07-17 (17 commits, all gated + ASAN-clean)

Corpus grew **31→39 positive, 16→18 negative**; three new gates run every build:
`run.sh` (asserts the *reason* a negative case fails), `--arc` (leak baseline), `--asan`.

**✅ P0 — Truth: COMPLETE.** The whole point of P0 was that nothing else is verifiable first, and it is
now done:
- **P0-1** the negative harness asserts the failure *reason*, not exit≠0 — a segfault no longer reads as
  "rejected" (`92e51df`). **P0-3** `--arc` leak gate added with a per-case baseline (same commit).
- **P0-2** `return_type_mismatch` had *silently regressed* to compile-and-segfault; a blanket int-literal
  exemption disabled the check for every literal return. Fixed (`ccbdeaf`).
- **P0-4** doc-truth pass: F1–F5 headers corrected, db-drivers §0's fixed scares marked stale, the two
  planning docs bannered (`389b1d7`). Also found `lang/docs` was **gitignored** — the mediator plan had
  never been committed (`520bead`).
- **P0-5** a user's compile error no longer prints a *compiler* stack trace; the 4 crash-only cases now
  reject cleanly (`7944d5f`).
- **Bonus infra:** an **AddressSanitizer gate** (`a0906ce`) — found a live heap-buffer-overflow on its
  first run (`Atomic<long>` sized a 4-byte cell, accessed 8). That satisfies B-gate 1 (§4).

**✅ P2 — The error model (the user's foundational ask): the mechanism is DONE.**
- **P2-12** `throw`/`try`/`catch`-as-exceptions REMOVED — measured that the stdlib's only user caught
  `8472` (an i32-truncated string pointer); no unwinding, coroutine-UB (`715fb20`).
- **P2-13** `T | Error` WORKS — union type, `try` (propagate) / `catch` (default) as value operators,
  boxed `[tag,payload]` representation, payload enum carries the reason. Errors reach the caller with the
  message intact (`ee50e18`, `c2a6eb3`). Gated by `33_error_union.ky`.
- **P2-14** optional member-deref: the live SEGV is now an honest **located abort** (runtime guard on an
  optional-typed receiver). See-through ergonomics kept (`eea2139`). Gated by `38_optional_deref_guard`.
- **P2-16** the enum discriminant/payload bugs — payload binding stringifying a pointer (`c2a6eb3`), and
  a method on a payload-less enum value `E.A.code()` (`b9872a9`). Both were "sema didn't type it, so
  codegen guessed".
- **P2-18** tuples: the ARC half — box owns its elements, leak 68→3, the `return t` use-after-free gone
  (`fb77f0e`).

**✅ §8 closure/enum blockers for the mediator: ALL THREE CLEARED** (were "cannot be gated standalone",
all three misdiagnosed as one "module-qualified type in closure" bug — none actually was):
- module-qualified type in a closure (`476311a`, the §6 `isNamespaceReceiver` keeper, now gated)
- a closure returning a struct / a local struct ctor in a closure (`660a409`)
- a method on a payload-less enum value (`b9872a9`)

**✅ §6 keeper split (route-handling-via-mediator.md):** `isNamespaceReceiver` (`476311a`) and
`CompositeSource` (`54e6666`) committed with gates. `callBinder` + `app.ky` stay in the working tree —
they are genuinely coupled to the framework REWRITE (P5-31), not more KEEP work.

**Recurring finding, worth stating once:** nearly every bug above was the same root cause — *something
was not typed, so codegen guessed* (`isRefCountedType`'s catch-all, an untyped `E.A`, an untyped
destructured binding). That is `design/F1–F5`'s thesis, and it is why **P1 (foundation completion) is the
highest-leverage remaining work** — it deletes the guessing rather than fixing each guess. See §6 P1.

**What did NOT move:** P1 (F1–F5 done-criteria — still ~2 of 48 boxes; the atomics/harness fixes touched
M12 but the foundation itself is untouched), P2-15 (two-register returns — boxed instead, recorded),
P2-17 (async failure / `Handle<T>` — still no design), and all of P3–P6. The `throw`→`T | Error` arc
means the *language now has an error model*; the *foundation that would make it sound end-to-end* does
not yet exist.

---

## 0. The rule that makes the rest of this plan real

⚠️ **`conformance/run.sh` cannot tell "the compiler rejected it" from "it segfaulted".** Negative cases
are judged on exit code alone, and a crash also exits non-zero. Measured: of 16 `expect_fail` cases, all
16 report PASS; **only 10 genuinely reject**. `return_type_mismatch` **compiles and segfaults** while
`PENDING.md` documents that check as DONE.

**Nothing in this plan can be verified until that is fixed.** It is task **P0-1** and it is first, ahead
of every user-visible feature, because every "done" below is otherwise an opinion. This is the same
failure family as `kyte test` silently skipping `main()` ([[kyte-arc-measurement-traps]]) and the
compiler test-list running 0 tests while reporting 101/101 ([[kyte-test-discovery-guard]]). **Third
occurrence. The pattern is the finding, not the instance.**

---

## 1. The honest state (measured 2026-07-17)

Much better than the docs say in some places, much worse in others.

### Works — verified by running it
| Thing | Evidence |
|---|---|
| **C++20 runtime, Asio, multi-core** | `concurrency.cpp` includes `boost/asio.hpp`; `g_io.run()` on an N-thread pool. The "runtime is C / fragile" grade is **stale**. |
| **async/await, LLVM coroutines** | Runtime plan M0 gate PASSED; B (surface) + C (lowering) + D (Asio) landed. |
| **TLS via wolfSSL** | Verified against the real network; **fail-closed proven** (self-signed + wrong-host both rejected). |
| **Crypto is real** | `crypto.sha256("abc")` = `ba7816bf…f20015ad` — the correct KAT. wolfCrypt, with an honest `kyte_crypto_unavailable` fallback (never a silent stub). |
| **Crypto input is binary-safe** | `kyte_crypto_slen` reads the length header at `s-4`, not `strlen`. |
| **Map growth** | 5000 keys from a presize of 8, many resizes → clean. |
| **`${long}` / `${double}` interpolation** | Both fine. |
| **`let f = self.hashFn; (f)(k)`** | Fine. |
| **Enum payloads** | Work — with one sharp exception (§2.E). |
| **Optionals at runtime** | `??`, `?.`, `!= undefined` narrowing, `list.get` → undefined all correct. |
| **ARC** | corpus 2513 → 36 live (−98.6%). Essentially closed. |
| **F2 typed IR** | **The keystone landed.** Legacy resolver **deleted** (357 lines); 0 lossy fallbacks of 53,507. |

### Broken — status as of the 2026-07-17 session (see the progress log at the top)
| Thing | Status |
|---|---|
| ~~Optional enforcement: none~~ | ✅ **The SEGV is fixed (P2-14, `eea2139`)** — a member deref on an absent optional now traps with file:line instead of reading through address 0. ⏳ Assign/pass/return still not *statically* rejected (compile-time enforcement pending; they don't crash — no deref). |
| ~~Tuples: silent corruption~~ | ✅ **The corruption is fixed (P2-18, `fb77f0e`)** — box owns its elements, leak 68→3, `return t` UAF gone. ⏳ The *type-checker* half is still open: `v + e` (int+string) still compiles, arity unchecked. |
| ~~`throw` is an i32 longjmp~~ | ✅ **REMOVED (P2-12, `715fb20`).** Replaced by `T | Error` (P2-13). |
| **Stack traces don't exist** | Unchanged. `kyte_get_stacktrace()` returns an empty buffer. (`throw` never provided one either, so nothing was lost.) |
| **Bounded channels don't exist** | Unchanged. `kyte_chan_new`: `(void)capacity;` — gates R3 (P3-20). |
| **Build is macOS-hardcoded** | Unchanged. Runtime plan workstream **E is OPEN**. Blocks "production ready" on any other OS and B-gate 3. |
| ~~Negative-test harness~~ | ✅ **Fixed (P0, `92e51df`)** — asserts the failure reason; `--arc` + `--asan` gates added. |

### Foundation program (`design/F1–F5`) — real status
⚠️ **All five headers say `Status: Design`. All five are wrong** — the stage tables are the truth.
**48 done-criteria boxes across F1–F5; exactly 2 are ticked.**

| | Real status | What's left |
|---|---|---|
| **F1** name resolution | stages 1, 2, 3a landed | **3b** (cut codegen over), **4** (module scoping), **6** (mangling), **7** (N3 fatal) |
| **F2** typed IR | **1–4d landed. Legacy resolver deleted.** | stage 5 (unresolved fatal), stage 6 (checker writes, not discards) |
| **F3** primitives | 1, 2, 3, 4, 4b landed; **5 in progress** | 5 (honest i32 local slots, debug-trap), 6 (stdlib sweep), 5a (`decimal`), 7 (`orelse "i32"`) |
| **F4** generics | 2, 4, **4b landed and mandatory** | **Map excluded from mono — the next link**; 1, 3, 5, 6 |
| **F5** ARC | 3.4c–3.4j landed; ARC ≈ closed | **stage 2a (ordering-critical)**, 2, 4, 5, 6; `retainIfGenericStore` still undeletable (blocked on Map) |

**`design/README.md:99-101` gates the C++20 runtime and the web framework behind F1–F5. That gate was
already broken** — the runtime shipped A–D. Do not pretend otherwise; **§6 below re-states the real
gate.**

---

## 2. What we missed — not in ANY doc

The user's instinct was right: error handling and `undefined` were foundational and were never laid out.
The audit found the gap is wider than that.

- **M1. No error-handling model anywhere.** No `Result`, no propagation design, no `?`/`!`, in any of the
  9 docs. `throw` exists in codegen by accident of history, not by design.
- **M2. No optional *enforcement* design.** The runtime half shipped; the static half was never specified.
- **M3. ⚠️ ARC × unwinding is undefined.** F5's O4 says "scope exit | release every owned local", and
  §3.4e found that `break`/`continue` — "the exits that JUMP" — released **nothing**. **A `throw` is a
  third jumping exit and is covered by no rule.** Independently confirms §1's `throw` finding.
- **M4. ⚠️ No async failure story.** **No document states how an async task reports failure.** `go` yields
  an **untyped** handle (spec §7 stores them as `List<i64>`), so `await` is untypeable *by construction*
  (F2 §4b). F2 says it needs `Handle<T>`; the runtime plan defers `Future<T>`; **neither has a design.**
  This is exactly where an async error channel would live. **Blocks the error model for async code.**
- **M5. Tuple soundness** — the type checker never reads `ls.names`.
- **M6. WebSocket** — mentioned once as a D6 "stretch"; **absent from the runtime plan and from `src/`.**
- **M7. Actors** — CLAUDE.md promises the actor model. **No design in any doc.**
- **M8. Bounded channels** — the SSE bus's core property; unimplemented.
- **M9. Reference cycles** — F5 Q1: ARC cannot collect them; a parent↔child graph leaks today and will
  still leak after F5. **Undocumented in specs.** "Kyte has ARC" implies a cycle story to anyone from Swift.
- **M10. Cross-platform CI** — build is macOS-hardcoded; roadmap's own 1.0 list names portability.
- **M11. Package manager / registry, LSP hardening, diagnostics** (E3/E4) — open, unowned.
- **M12. `collections.array` segfaults on mere import** — a pre-existing codegen bug; array is never gated
  by the corpus. Also: `io.file` `FieldAccessObjectNotStruct`; `driver`/`client` `MethodOrFunctionNotFound`
  (hit live during this audit); `fiber.sleep` corrupts execution in a `@test` context.

---

## 3. The four new requirements — feasibility, measured

### R1. Webview desktop apps (`webview/webview`)
**Feasible, but blocked on a real architectural decision.**
- ⚠️ **Event-loop conflict.** `main()` → `__kyte_main()` → `kyte_run()` → `g_io.run()` **on the main
  thread**. macOS AppKit *requires* the UI loop on the main thread. Two loops, one thread.
- **Design:** main thread runs `webview_run()`; Asio `io_context` runs on worker threads only; Kyte async
  code runs on workers; UI updates marshalled via `webview_dispatch`. Needs a new entry mode
  (`kyte_webview_run()`) that inverts who owns `main`.
- **Blocked on:** cross-platform build (runtime **E**, open) — webview needs WebKitGTK (Linux) /
  WebView2 (Windows) / WKWebView (macOS). **Native only; never WASM.**
- Note `studio/` in the tree is currently a **Node.js** app (`server.js`, `node_modules`) — the Data
  Studio prototype is not Kyte today.

### R2. DB drivers — MySQL / Postgres / MSSQL / MongoDB
**`db-drivers.md` is ~5% of a spec and cannot be built from.** It contains the easy, re-derivable part
(framing, endianness, integer packing) and omits ~95% of the work:
- **Silent on:** authentication, TLS, pooling, prepared statements/params, type mapping, NULL,
  transactions, cursors/streaming, error codes. Every parser is a stub — `parseFieldName` literally
  `return "column_name";`.
- ⚠️ **`Row.cells: List<string>` is a *wrong foundation*, not an incomplete one.** No NULL, no binary, no
  types. Everything built on it gets rewritten later. **Fix `Value`/`Row` before writing one parser.**
- ⚠️ **No params ⇒ no SQL-injection-safe path exists in the specified API.** (The *btree* driver already
  has `execute(sql, params)` — the doc is behind the shipped code.)
- **Auth needs raw-byte crypto** (§R4) — SCRAM-SHA-256, caching_sha2, TDS. Not optional: you cannot
  connect to a default PG 14+/MySQL 8/Atlas without it.
- **TLS must negotiate mid-stream** (PG SSLRequest, MySQL capability flag, TDS PRELOGIN). Today's
  `TlsStream` is a blocking client-only wrapper and **cannot express that**.
- ⚠️ **Seriously price FFI (libpq / libmysqlclient / FreeTDS / mongo-c) for v1.** The doc never considered
  it, yet TLS is *already* FFI — so "no C bindings" is not a codebase principle, just an unexamined
  assumption. Four hand-rolled wire protocols is a multi-engineer-year commitment.
- ✅ **Correction:** db-drivers §0's scare-list is **stale** — Map-SIGBUS, `${i64}` SIGSEGV, and the
  fn-value crash are all **fixed** (measured). Do not let a stale doc set the risk posture.

### R3. Server-side event bus (ssehub, without change-streams)
**The most feasible of the four.** ~1100 lines excluding WatchClient and tests; the port cost is dominated
by runtime primitives, not logic.

**🔑 DECISION (user, 2026-07-17) — no WatchClient, no change-stream, no separate service.**
ssehub's WatchClient existed to fan a **change stream** out across **micro-services**. Neither applies here:
a change stream is implementable on NovaDB but **not** on Postgres/MySQL/MSSQL/Mongo, so it cannot be a
portable framework primitive; and Kyte targets a **monolith**, not micro-services. Therefore:
- **The bus is a library inside the web framework**, not a standalone service. It lives in-process with the
  app — `std/web/sse.ky` — and the app publishes to it directly.
- **There is no upstream-watch concept at all.** The "source" is ordinary application code calling
  `publish(topic, event)`. If NovaDB change-streams ever land, they become *one caller* of `publish`, not
  a component of the bus.
- This also **deletes the multi-process replay/resume complexity budget**: one process owns every topic.

**The cut is exceptionally clean** and this decision makes it cleaner. `event_bus.zig` does **not** import
`watch_client.zig` — the coupling is entirely one-way through a user hook that calls `bus.publish`. Drop
the file, its 3 re-exports, and the planck/bson/tls deps. **Nothing else changes.** The only residual
dependency is `utils.Now` (one function) → Kyte's monotonic clock.

**Also transport-agnostic:** the bus never opens, reads, or closes a socket. It receives a *writer* from
the HTTP layer; SSE framing is isolated in `wire.zig`. **Preserve that** — it is the best part of the
design.

⚠️ **The blocking prerequisite — M8, and it is sharper than "bounded".** The design's whole load-bearing
line is a **non-blocking try-send**: `queue.putUncancelable(io, &{owned}, 0)` with `min = 0`, meaning
"enqueue only if it won't block". Full queue → drop or disconnect; **the publish path never blocks on a
slow subscriber.** Kyte needs a bounded MPSC channel with `try_send` semantics. `kyte_chan_new` today
ignores capacity *and* offers no try-send. **Without try-send this design is not merely slower — it is
impossible.**

⚠️ **The port's scope *creates* a latent use-after-free.** `publish` fills `topic.snapshot_buf` under the
lock, then **iterates it after releasing the lock**. Two concurrent publishes to one topic → the second
`clearRetainingCapacity()`+`appendSlice()` reallocates the buffer under the first's iteration. It is safe
today *only because* the WatchClient architecture gives each topic exactly one publisher — **the very
thing we are deleting.** Fix: allocate the snapshot per-publish (as `heartbeatLoop` already correctly
does), or document a single-publisher bus. **Highest-severity item in the port.**

Other runtime primitives required: uncancelable mutex (every lock in the codebase is `lockUncancelable`
— locks must not be cancellation points); atomics with acquire/release + `fetchAdd`/`swap`; **spawn with
*guaranteed* concurrency** (a spawn that may run inline deadlocks `start()` on the heartbeat's infinite
loop — a latent trap, not theoretical); cancelable sleep; **monotonic clock**; a buffered writer whose
`flush()` surfaces errors — that is the *sole* dead-connection signal. Not needed: TCP, TLS, DNS, reads,
condvars, JSON.

Bugs to fix rather than port faithfully: **wall-clock used for latency/lifetime** (can go negative across
an NTP step — use monotonic); **replay gaps are silent** (`oldestId()` exists and is *never called* —
cheapest high-value correctness win); heartbeat is the magic string `"heartbeat"` (leaks a duped name;
make it a variant); `\r` unhandled and `event_name` unvalidated in `writeEvent` (frame-injection vector);
`Config.subscriber_queue_size` is dead; the `event_bus`↔`subscriber` circular import must become a leaf
types module in Kyte regardless. Consider a **refcounted shared payload** instead of the N-way
per-subscriber dupe — the main scalability win, and a port is when to take it.

### R4. Full crypto (`sha.ky`, `md5.ky`, `base64.ky`, `random.ky`)
`src/std/crypto/` is **an empty directory**; `src/std/crypto.ky` is a thin 4-function file.
- Have (real, KAT-correct, binary-safe **input**): `sha256`, `sha512`, `md5`, `hmac_sha256`, `random_hex`.
- ⚠️ **The gap is output: hex-only.** `kyte_hex(...)` means digests **cannot chain**. PBKDF2 is
  `HMAC(pw, salt‖i)` fed back round after round — that needs **raw bytes**. L4 designed `hash.sha256Bytes`;
  it never landed. Without it SCRAM is possible only via hex-decode between rounds — wasteful and silly.
- **Absent entirely:** base64, SHA-1, SHA-384, SHA-3, PBKDF2, HKDF, AEAD (AES-GCM / ChaCha20-Poly1305),
  constant-time compare, and a **seeded PRNG distinct from the CSPRNG**.
- **This is the unblocker for R2's auth.** Do it before the drivers, not alongside.

---

## 4. Beta criteria (the bar we are aiming at)

From `kyte-readiness-roadmap.md:358-370`, kept because it is good and still correct:

> Prototype → Alpha *(today)* → **Beta** → 1.0/Production.
> - **Sound-enough core**: real type checking, real generics, no closure/concurrency data-race landmines.
> - **A dependable runtime**: no fiber races, no leaks, real TLS security, competitive I/O via Asio.
> - **A usable stdlib**: collections/text/serde correct on real data; a web/tcp stack that can safely serve
>   real HTTP with routing, middleware, and TLS.
> - **Buildable, testable, documented** against an accurate spec.

**This plan adds three Beta gates the roadmap lacks**, all earned by this audit:
- **B-gate 1 — the harness proves things.** Negative cases assert a *reason*; the corpus runs under
  `KYTE_ARC_AUDIT`. *A green corpus must be evidence about the compiler, not about the harness.*
- **B-gate 2 — no silent memory unsoundness in a documented feature.** Optionals, tuples, and errors
  either enforce or are documented as unenforced. **No feature ships whose spec claims a guarantee the
  compiler does not make.**
- **B-gate 3 — it builds on Linux and Windows in CI.** Beta on one developer's Mac is not Beta.

---

## 5. Doc reconciliation — required, because they contradict each other

Cross-reading the 9 docs surfaced **~19 contradictions**. The worst, all needing a decision:

| # | Conflict | Resolution |
|---|---|---|
| 1 | `int` = 64 (roadmap A7) vs **`int` = 32** (evolution L1) | **32 wins** — shipped (`1f26aa8`). Roadmap stale. |
| 2 | Regex = hand-rolled Thompson NFA (roadmap) vs **Boost.Regex** (evolution) | **Boost** — but evolution's own Risks section still says "weeks". Both stale in part. |
| 3 | ICU: "don't vendor" / "no longer needed" / "take it, gate it" — **three positions** | **UNRESOLVED. Blocks L5 Unicode regex + L6 plurals.** Decide before either. |
| 4 | Runtime stackful (B) vs **stackless** (M3) | **Stackless** — shipped. |
| 5 | `arc.zig:11` "no change needed — it is what ships" (evolution) vs **"the function cannot be fixed; its *signature* is the defect"** (F-README) | **F-README wins.** |
| 6 | "string heap corruption" blocker (both plans) | **Misdiagnosed for months** — it was a `func_map` suffix-scan bug. Not just stale: *wrong*. |
| 7 | Crypto "is fake, returns `""`" | **Stale** — real wolfCrypt, KAT-verified. |
| 8 | Arg-count check: DONE (M2) vs BLOCKED (A3 + PENDING.md) | Resolve against the tree. |
| 9 | F1–F5 headers say `Status: Design` | **All five wrong.** Fix the headers. |
| 10 | `design/README` gates the runtime+web behind F1–F5 | Already violated. **§6 re-states the real gate.** |
| 11 | `data-studio.md` is written entirely against unbuilt features, and encodes a **fixed** bug as a design constraint (`// Pre-size to avoid resize SIGBUS`) | Rewrite after R2/R4. |

**P0-2 is a doc-truth pass.** Stale docs are not free: they set the risk posture (§R2) and they cost
this audit real time. Two beliefs I formed from docs this session were false until a control caught them.

---

## 6. The plan

Ordering principle, unchanged from the roadmap and re-proven by this audit: **compiler foundations lead**;
the four new requirements are *applications* of the foundation, and every one of them is blocked on
something below it.

### P0 — Truth (days). Nothing else is verifiable first. — ✅ COMPLETE (2026-07-17)
1. ✅ **Harness asserts the reason**, not exit≠0 (§0) — `92e51df`. (The `l.get(5)` segfault became the
   P2-14 runtime trap; the `return t` UAF is gated in `28_tuple_return_heap`.)
2. ✅ **Fixed the regressed `return_type_mismatch`** check — `ccbdeaf`.
3. ✅ **`--arc` leak gate** (opt-in, per-case baseline) in `conformance/run.sh` — `92e51df`.
4. ✅ **Doc-truth pass** — F1–F5 headers, stale-claim banners, db-drivers §0 — `389b1d7` (+ `520bead`,
   the gitignored-docs fix).
5. ✅ **The 4 crash-only cases produce clean rejections**, not Zig stack traces — `7944d5f`.
6. ✅ **Bonus: AddressSanitizer gate** (`--asan`) — `a0906ce`. Found a live heap overflow on run one.
   This is B-gate 1 (§4).

### P1 — Foundation completion (F1–F5 done criteria: 48 boxes, 2 ticked)

> **P1 progress 2026-07-17.** Four of the six items I planned here **did not exist**. Measured, not
> assumed — and the measuring is what produced the two real bugs found instead:
> - ✅ **P1-6 (Map → `Storage<T>`) was ALREADY DONE.** `map.ky` holds `Storage<K>`/`Storage<V>`;
>   `retainIfGenericStore` is deleted; `12_traits_dispatch`/`13_serde`/`14_collections_map` all pass.
>   **F4/F5's "Map is excluded — that is the next task" was stale, and my first doc-truth pass
>   REPEATED the stale claim** because I corrected the header from a summary instead of from the
>   tree. Corrected again. F5 stage 5 is unblocked.
> - ✅ **P1-11 (M12): 3 of 4 were stale** — `collections.array`, `io.file`, `data.btree.driver`
>   and `data.btree.client` all import and run clean.
> - ✅ **The 4th (M12d, "fiber.sleep corrupts execution in a @test") was REAL but MISDIAGNOSED**, and
>   fixing it is the substance of this session's P1 — see below.

**Landed in P1:**
- ✅ **`kyte_atomic_cas_i32` returned the expected value, not the success flag.** Codegen truncates
  to i1, so callers got **the low bit of the expected value**: `compareAndSwap(22, 30)` succeeded and
  reported `false`; the *failing* CAS also reported `false`, so `assert.isFalse` passed by accident
  and only success looked broken. Correct iff the expected value was odd. **Every atomic CAS in the
  language was wrong**, and nothing in the corpus imported `concurrency.atomic`.
- ✅ **`kyte_atomic_cas_i64` declared `int32_t desired`** while codegen passes i64 — silently
  truncating any desired value above 2^31. ABI mismatch, fixed in header + impl.
- ✅ **The test harness could not name a failing test.** `kyte_test_fail` `_Exit(1)`s, so the
  generated `FAIL <name>` branch and the whole `Results: N passed, M failed` path are **dead code**.
  A failure printed only `Assertion failed: <msg>` — no name, no summary. Since the merged stdlib
  runs every imported module's `@test`s, **an unrelated module's failing test was indistinguishable
  from your own**. Added `kyte_test_begin(name)`; a failure now prints `FAIL <test>` + the message +
  a note that the suite aborts at the first failure.
- ✅ **`test_fiber_execution` was never broken — it was NEVER RUNNING.** `test_atomic_i32` aborted
  the process first, so it (and `test_atomic_i64`, `test_atomic_bool`) never executed. The abort was
  misattributed to the fiber test and sat in `runtime-cpp20-plan.md` §6.6 for months as an
  "atomic/closure-capture defect". `spawn`, closure capture and the arena were all innocent.
  **Same shape as "string heap corruption" (a `func_map` suffix-scan bug misfiled for months): an
  instrument that cannot name a failure will misname it, and the wrong name sticks.**
- ✅ **`conformance/cases/31_atomics.ky`** gates all of it — int/long/bool load/store/add/sub/CAS,
  including an **even-expected-value** case (the shape the old code got wrong) and an
  **odd-expected-value** case (the shape it got right, so a half-fix cannot pass). **Shown to fail
  before the change**, per `design/README.md` §3 non-negotiable #4.

**Still open in P1:**
6. ~~**F4: migrate `Map` to `Storage<T>`**~~ — ✅ already done (above).
7. **F5 stage 2a** (static fn boxes writable + sentinel) — **ordering-critical**, must precede stage 3.
8. **F5 stage 2/4** — `isOwned(TypeId)`; O4 enforced. **Includes M3: define ARC × unwinding** (or delete
   `throw`, which makes the question moot — see P2).
9. **F3 stage 5 finish + stage 6 sweep** (Y2038 datetime, web counters, Content-Length >2GB).
10. **F1 3b/4/7**; **F2 stage 5/6** (unresolved fatal; checker writes instead of discarding).
11. **M12**: fix `collections.array`, `io.file`, `driver`/`client`, `fiber.sleep`.

### P2 — The error model (the user's foundational ask) — ✅ MECHANISM DONE (2026-07-17)
12. ✅ **Deleted `throw`/`try`/`catch`-as-exceptions** — `715fb20`. Measured: the stdlib's only user
    caught `8472`. Spec §5.5 rewritten.
13. ✅ **`T | Error` implemented** (spec §3.4b written first) — `ee50e18`, `c2a6eb3`. `try` propagates,
    `catch`/`catch (e)` defaults, error side is a payload enum consumed by `switch`, message intact.
    Gated `33_error_union.ky`. **Decisions taken with the user:** union not tuple (a tuple lets you
    drop the error); one error enum per signature; `T | E | undefined` for 404-vs-500; `exception`
    keyword rejected in favour of `error`/plain enums.
14. ✅ **P2-14 RESOLVED (runtime half)** — `eea2139`. The see-through segfault is now a located
    **runtime trap**; see-through ergonomics kept (the router + bson keep working). Gated
    `38_optional_deref_guard`. **Still pending: COMPILE-TIME enforcement** (reject unnarrowed
    assign/pass/return statically) — needs flow-narrowing (§3.4a) to be painless; the guard is
    memory-safe meanwhile. `950495c` reconciled: kept, guarded.
15. **Two-register `{i64 tag, i64 payload}` returns** — NOT done; `T | Error` is BOXED for now (one
    alloc on the error-union path, invisible to the user). Recorded as the optimisation. Still the
    one foundation that also gives tuples a proper destructor.
16. ✅ **Enum discriminant/payload bugs fixed** — `c2a6eb3` (payload binding stringified a pointer),
    `b9872a9` (a method on a payload-less enum value `E.A.code()`). Both "sema didn't type it, so
    codegen guessed". Gated `32_error_payloads`, `36_enum_method_dispatch`.
17. **`Handle<T>` / `Future<T>` + async failure (M4)** — NOT done. Still no design; `go` yields an
    untyped handle, so `await` is untypeable by construction. **This is the one genuinely-incomplete
    part of the error model: it does not cover `async fn` yet.**
18. ~~**Tuples**: `shadow.zig:588` is the cheap high-leverage fix~~ — ✅ **ARC HALF DONE 2026-07-17.**
    `28_tuple_return_heap` 68 → 3, `29_http_request_parse` 46 → 6; corpus above-floor ~118 → ~6; the
    `return t` use-after-free is fixed. **The predicted cheap fix measured exactly zero, twice** — the
    real causes were box-owns-nothing, box-never-released, destructured-locals-never-block-owned, and
    sema never binding destructured names (which made a rebuilt tuple an over-release). See
    `route-handling-via-mediator.md` §8.D. **Still open: the type-checker half (D1/D2/D4)** — `v + e`
    (int + string) still compiles; `type_checker.zig` still never reads `ls.names`.

### P3 — Runtime completion
19. **Cross-platform build (runtime E)** — macOS-hardcoded today. **Gates R1 and B-gate 3.**
20. **Bounded channels + `try_send` (M8)** — gates R3. Capacity *and* non-blocking try-send; the latter is
    the actual requirement (§R3).
21. **TLS-over-async server**; mid-stream TLS negotiation (gates R2).
22. **WebSocket (M6)** — currently absent everywhere.
23. Generic channel element types (i32-only today).

### P4 — The new requirements, in dependency order
24. **R4 crypto** — `crypto/sha.ky`, `md5.ky`, `base64.ky`, `random.ky` (CSPRNG **and** seeded
    PRNG), **raw-byte digest variants first**, then PBKDF2/HKDF, constant-time compare, NIST KATs.
    *Unblocks R2 auth.*
25. **R3 SSE event bus** — after P3-20. Cheapest of the four; highest ratio.
26. **R2 DB drivers — DEFERRED BY DECISION (user, 2026-07-17)**: not started until the foundation is solid
    and demonstrably working. When it starts — **rewrite `db-drivers.md` first** (it is not buildable). Redesign `Value`/`Row`
    with a type union + NULL; add `params`; then **spec ONE database end-to-end (Postgres — best-documented,
    and its framing already matches btree's) including auth and type mapping, ship it, and only then
    generalize.** Price FFI honestly as v1.
27. **R1 webview** — after P3-19. Resolve the main-thread/Asio inversion; `kyte_webview_run()`.
28. **Rewrite `data-studio.md`** against what then exists.

### P5 — Stdlib & web (roadmap C/D, unchanged and still open)
29. C1 collections completion; C3 serde (JSON escapes/`\uXXXX`, floats, depth limit); C4 datetime/math;
    C5 IO. C7/L5 regex + L6 i18n — **gated on the ICU decision (§5 #3)**.
30. D1–D5: HTTP server rewrite, router, middleware actually in-path (*"today they never execute"*),
    security (CSPRNG session IDs, CSRF, trusted proxy), HTTP client.
31. **The mediator work** (`route-handling-via-mediator.md` §7) lands here — it is D2/D3 done properly.

### P6 — Beta hardening
32. **CI on Linux + Windows + macOS** (B-gate 3). 33. Diagnostics with spans (E3). 34. LSP/formatter
hardening (E4). 35. Document the **cycle** story (M9) even though ARC won't solve it. 36. Compiler unit
tests — *~16,700 lines, 12 tests, all in one file* (design/README §2b).

---

## 7. Priority, honestly

> **Updated 2026-07-17 after the session.** P0 is done and P2's *mechanism* is done — the two things
> this section led with. The next-step calculus below has moved on accordingly.

**Where it now stands:** the language *has an error model* (`T | Error`, `try`/`catch`, no more `throw`),
optionals no longer SEGV, tuples no longer corrupt, and three gates (`run.sh`/`--arc`/`--asan`) keep it
honest. But nearly every bug fixed this session was the same root — *codegen guessing from an untyped
value* — and **that root is still there.** The fixes were point-repairs; `design/F1–F5` is the cure.

**The single highest-leverage remaining work is P1 — foundation completion.** F2 (typed IR) landed and
the legacy resolver is gone, but F5's `isOwned(TypeId)` (stage 2), F3 stage 5/6, and F1 3b/7 are not,
so `isRefCountedType`'s catch-all still decides ownership from a *string* and returns `true` — i.e.
"free it" — when confused. Every "unknown struct type='void'", every leaked-then-corrupt path, traces
to that. P1 deletes the guessing rather than fixing the next guess.

**Two genuinely-incomplete things to name, not bury:**
- **The error model does not cover `async fn`** (P2-17). `go` yields an untyped handle; `await` is
  untypeable by construction. `T | Error` works for synchronous code only.
- **Compile-time optional enforcement** (P2-14 second half) — the runtime guard is memory-safe, but
  `let x: string = opt` is still accepted. Needs flow-narrowing first.

**Then** the sequence toward the four requirements is unchanged: raw-byte crypto (P4-24, unblocks R2
auth) → R3 SSE (needs only bounded channels, P3-20) → R1 webview (needs cross-platform build, P3-19) →
R2 DB drivers (huge; a real spec first).

**The four new requirements rank:** R4 crypto (unblocks R2; small) → R3 SSE (one prerequisite; high
ratio) → R1 webview (one prerequisite; medium) → **R2 DB drivers (huge; needs a real spec first)**.

**Do not start R2 until:** the error model exists (a driver is 90% error paths), raw-byte crypto lands
(auth), TLS negotiates mid-stream, and `Value`/`Row` is redesigned. Starting it earlier means writing it
twice.

**Deferred to 1.0, explicitly** (roadmap `:372-381`, still right): mileage/dogfooding, API-stability
commitment, package manager + registry, tutorials, perf proof (YCSB), portability breadth.

---

## 8. Foundation completion — the bounded scope (the "are we ever done?" answer)

The recurring fear is that fixing the foundation is an unending spree — every session finds new holes.
**It is not, and here is the proof: the foundation defect is ONE root cause with a FINITE, GREPPABLE
surface. The numbers only go down; when they read zero, the class of bug is closed — provably, because
no code is left that can guess.** This section is the boundary as a spreadsheet, so "is it done" is a
command, not a feeling.

### The one root cause (design/README, confirmed by every bug this session)

> Kyte decides semantics by pattern-matching the *spelling* of a rendered type NAME at codegen time,
> and **guesses when it can't parse the name**. `isRefCountedType`'s catch-all returned `true` — "free
> it" — for anything unrecognised. Every corruption this session (tuple `(unresolved,unresolved)` freed
> as if owned, untyped `E.A`, closure-return-`void`) was that one mechanism in a different costume. Not
> ten root causes — one, ten times.

### The boundary map (measured 2026-07-17; each number is a `grep -c`)

| Surface | Sites | F-stage | Definition of done |
|---|---|---|---|
| `isRefCountedType([]const u8)` — ownership from a string | **33 → 9** ⬇ | F5-2 | deleted; `isOwned(TypeId)` is the sole decider |
| `getStructBaseName` used as a lookup key | **27** | F5-2 | keyed on `TypeId`/instantiation, not a stripped name |
| `"i32"` literal type strings in codegen | **26** | F3-5/6 | `PrimType`/`TypeId`, no bare `"i32"` |
| `mem.eql` on a type-NAME in codegen | **20** | F1/F2 | decisions read `TypeId`, not spelling |
| `func_map` suffix scans | **20** | F1-3b | resolution via `SymbolId` |
| `orelse "i32"` (guess i32 when unknown) | **4** → ~0 | F2-5 | ✅ **already at floor** — F2 removed the dangerous ones; the 4 left are legit canonicalization (`int`→`i32`) + `getTupleElementType`'s internal default, not corruption paths |

### F5 stage 2 — migration underway (the number is moving)

The vehicle is `isOwnedExpr(expr)` (codegen/types.zig): the typed `isOwned(TypeId)` for the
provably-agreeing majority (string / struct / array / tuple / storage / error_union / func / prim /
ptr / future / trait), the string path only for `.enum_` and `.type_param`, and skip for
`.unresolved`. Measured behavior-preserving (isOwned and `isRefCountedType(render)` agree on every
concrete type in the corpus). Committed so far:

- **Return-value ownership** now goes through `isOwnedExpr` (`isRefCountedType` 33 → 32). A concrete
  return's retain no longer depends on the renderer being right — the exact class that corrupted
  tuples/enums this session.
- **`isOwned(.trait_)` fixed to `true`** — a trait object is an owned fat pointer (§3.4f); it was
  `false`, diverging from the string path. One fewer type the fallback must special-case.
- **Central temporary-registration choke point** — `compileExpression` now decides temporary
  ownership via `isOwnedExpr` (the rendered name kept only as `.type_name` for the destructor).
  Committed (isolated from the framework WIP that shares the file).
- **`current_local_types` → `TypeId` cascade DONE.** A parallel `current_local_type_ids`
  (name → `TypeId`) is built alongside the string map and populated where an initializer expression
  is in hand (`let x = init` via `typeOf(init)`; tuple destructuring via the tuple's element
  `TypeId`s). A single `isOwnedLocal(name, string)` helper decides via the store when the name is
  recorded and falls back to `isRefCountedType` otherwise. **All eight `current_local_types`-backed
  ownership reads** now go through it: let-binding registration (single + destructure), tuple-element
  retain, function-exit drain, closure-cleanup, closure-creation retain, and assignment. Partial +
  additive, so behavior-preserving; gated 57/57 values, 96/96 arc, 96/96 asan, units.
- **Every ownership read that had an expression in hand is migrated.** Error-union OK-arm
  (try-payload retain + catch ok-branch, via `isOwnedErrUnionOk` projecting `.error_union.ok`),
  expr-statement temporary release, tuple-element retain at construction, and string-interp append —
  all decide via `isOwnedExpr` / a store projection now.
- **DECLARED types now lower to a TypeId at codegen** (`isOwnedDeclaredType`, codegen/types.zig).
  A `Lowerer` (`sema/lower.zig`) is built against `sema_shadow.live_sema.?.{store, tab}` — reachable
  with NO new plumbing, no sema/main/driver change, NOT the F2 stage-4 cutover. It trusts the typed
  answer only for a type the store decides DIRECTLY (`decidedDirectly`: not `.enum_`/`.type_param`/
  `.unresolved`), so a concrete declared type gets the typed answer and a generic one falls back to
  the string path — meaning `param_scopes` are unnecessary and scope-correctness cannot cause a wrong
  answer. **Consumers migrated:** the 4 struct/union field-init/assign retains and the 2 enum-variant
  payload retains. (Store interning during codegen verified safe: idempotent, existing TypeIds stable.)

Enum ownership — **FULLY FIXED 2026-07-18 (`e74d36d`, `dcb3da1`, `f5732e2`): single- AND struct-payload, box + payload + temp + extract.**
- ✅ **Payload-carrying enum boxes are now released.** A tagged-union enum (any variant with a payload
  — `enumIsTaggedUnion`) is a HEAP BOX `[tag, payload…]`; `arc.zig:25` used to return FALSE for every
  enum, so the box was never owned and leaked one-per-construction. Now `isRefCountedType` returns TRUE
  for a tagged-union enum, FALSE for a payload-less one (an immediate tag). Flipping enums to owned
  turned on release everywhere and exposed exactly one missing retain — the `catch |e|` binding stored
  the err payload WITHOUT retaining (the ok path already did), a UAF once enum releases were on; the
  symmetric err-binding retain fixed it. Effect: `32_error_payloads` 7→3, `33_error_union` 8→3,
  `36_enum_method_dispatch` 4→3; regression case `39` re-includes an enum-in-a-loop (43→3 live).
  98/98 values/arc/asan. (`isOwnedTypeId` still routes `.enum_` to the string fallback, which now
  answers correctly for enums.)
- ✅ **Owned payloads are now released, and a direct-TEMP payload no longer dangles** (was a
  pre-existing wrong-VALUE bug: `E.Variant("a" + "b")` read a FREED temp, confirmed present with the
  box-leak fix reverted). Two coordinated parts: (a) `getOrCreateEnumDestructor` (hooked into
  `getOrCreateDestructor`, which returned null for enums) — a tagged-union box gets `__destruct_<Enum>`
  that tag-switches and releases each variant's owned payload slots (single at `word`, struct fields
  at `word*(i+1)`), mirroring the err-union destructor; and (b) construction TAKES OWNERSHIP so that
  release is balanced — the positional form (which did neither) and struct-init now RETAIN an r-var
  payload and CONSUME a fresh-temp payload. Regression case `39` gained `test_enum_temp_payload`
  (computed payload in a loop): correct value + floor. 98/98 values/arc/asan.
- ✅ **STRUCT-payload variants** (`enum E { Pair { name: string, n: int } }`) — box leaked and the
  field extraction UAF'd. Root cause: sema types the struct-init construction `E.Pair{...}` AND the
  switch-bound payload var as `.unresolved` (a non-null but info-less TypeId), so the store-based
  deciders answered "not owned". Three recoveries, all "prefer the resolved NAME when the TypeId is
  `.unresolved`": `resolveExpressionTypeName` recovers the enum from an enum-variant struct-init's
  variant name; `isOwnedLocal` and `isOwnedExpr` fall back to `current_local_types` for an
  `.unresolved` name/ident (the latter makes `return nm` retain a switch-bound field, balancing the
  destructor — a UAF ASAN caught). Case `39` gained `test_struct_payload_variant` (r-var + temp owned
  fields, extracted+returned): correct values, ASAN clean, floor. The proper long-term fix is sema
  typing these constructs instead of `.unresolved`; these recoveries make ownership correct meanwhile.

**The 9 `isRefCountedType` decision-sites that remain split into follow-ups, each deliberate:**
1. **String-PARSED destructor machinery** (5 sites in `arc.zig`: `Storage<T>` element, err-union ok/err
   arms, tuple element — types recovered by *parsing a rendered name* like `"Storage<X>"` /
   `"ErrUnion(a,b)"`, with no `TypeRef` or `TypeId` in scope). Migrating these means threading `TypeId`s
   into the destructor generators (whose `getOrCreateDestructor` dispatches AND memoizes on the name
   string) — a subsystem refactor, not a swap. (The struct-field release, which HAD the declared
   `TypeRef` from the struct decl, was already migrated via `isOwnedDeclaredType`.)
2. **`Storage<T>` get/set** (2 sites) — the O4 ownership path, heavily annotated as delicate
   ("reasoning from a premise this file does not implement"); a focused, watched change.
3. **Return-site `return x ?? default`** (1 site, statements.zig) — decides from `func.return_type`
   (the declared return string); switching to `isOwnedExpr(v)` on the `??` risks UNDER-retaining
   (a UAF, not a leak) if the `??` node is untyped on some path, so it keeps the robust string source.
4. **String-interp append with an optional source-part** (1 site) — type passed as a string with only
   an OPTIONAL source expression; not a 1:1 swap.

Enhancement now unblocked (a watched follow-up, not required for the above): give `isOwnedDeclaredType`
`param_scopes` (mirroring `shadow.zig:213-261`) so GENERIC declared types also get a typed answer
instead of the string fallback — and populate params/`self`/annotations into `current_local_type_ids`.

(The 5 `isRefCountedType` calls in `codegen/types.zig` are the intended *fallback* inside
`isOwnedLocal`/`isOwnedErrUnionOk`/`isOwnedDeclaredType`/`isOwnedRenderedFallback`, not decision-sites.)

**This is the whole of it.** ~130 sites (with overlap), all greppable, all shrinking. When the top five
read zero, the compiler cannot decide semantics from a string, so the entire "codegen guessed" bug class
— the thing that has cost every recent session — is gone by construction, not by hoping.

### The sequencing, and the one measured blocker

The full `isRefCountedType` → `isOwned(TypeId)` swap (F5-2) is **blocked**, and this is measured, not
guessed: instrumented across the corpus, **7,157 expressions reach a type decision carrying a
`.type_param` (3,360) or `.unresolved` (3,797) TypeId**, and `isOwned` marks both `unreachable`. The
string path handles them because it *substitutes/renders* first. So `isOwned` cannot be the sole decider
until those never reach codegen — which is exactly:

- **F4 stage 5** — monomorphize so a generic body's `.type_param` becomes a concrete `TypeId` in the
  store (today substitution happens at *render* time, not in the store). Removes the 3,360.
- **F2 stage 5** — `.unresolved` fatal at end of sema. Removes the 3,797 (or reveals which are genuine
  and need sema to type them).

**Order is forced: F4-5 → F2-5 → F5-2.** That is not new scope discovered mid-flight; it is the
dependency the F-docs always stated (F5 depends on F4 and F2). What was wrong was believing the
foundation was *finished* — it was not; its hard architectural core (F2 typed IR) landed, its cleanup
did not.

### What has landed toward this (so the number isn't standing still)

- ✅ **The catch-all is now safe-by-construction** (`03c5353`, F5 stage 2 safety increment): asking ARC
  about an un-typeable whole-string (`unresolved`, `<tuple>`, `""`, …) **aborts loudly at the guess**
  instead of freeing a non-pointer. Measured behavior-preserving (no corpus case hits it) + a unit test
  pins the whole-string-vs-substring distinction. This converts the *entire remaining* string-guessing
  surface from "silent corruption when confused" to "loud, located failure when confused" — the same
  silent→visible transformation applied to `throw` and optionals. **So even un-migrated, the foundation
  can no longer silently corrupt from a rendering bug; the worst case is now an abort, not a UAF.**

### Definition of DONE (verifiable, not a feeling)

Foundation complete when these five commands read **0** (today: 33 / 27 / 26 / 20 / 20):
```
grep -rc "isRefCountedType(" src/codegen/          # → 0 (isOwned is sole decider)
grep -rc "getStructBaseName" src/codegen/          # → 0 as a lookup key
grep -rc '"i32"' src/codegen/                      # → 0 bare type strings
grep -rc "mem.eql(u8, .*type_name" src/codegen/    # → 0 spelling decisions
grep -rc "endsWith.*_.*name" src/codegen/          # → 0 suffix scans
```
If a future session must *add* a new grep to this list, that is the signal the scope was underbounded —
watch for it. It has not happened: every bug this session mapped to a row above.

---

## 9. Cross-references

`docs/route-handling-via-mediator.md` §8 — the 39-item measured backlog from the error-handling audit
(harness, optionals, error model, tuples, enum payloads) that P0/P2 draw from.
`docs/design/README.md` + F1–F5 — the foundation program (headers stale; stage tables true).
`docs/runtime-cpp20-plan.md` §6 — the live runtime backlog.
Memories: [[kyte-conformance-harness-trap]], [[kyte-arc-measurement-traps]], [[kyte-spec-first-workflow]],
[[kyte-app-generic-mediator]], [[kyte-deferred-backlog]].
