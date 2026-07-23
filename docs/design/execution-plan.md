# Nova — Execution Plan & Design (every incomplete roadmap item)

**Purpose.** The roadmap (`feature-roadmap.md`) says *what* and *why*; it is too coarse to implement
from without drift. This document is the *how* — one design per incomplete item — and the single place
completion is tracked. **Rule of work: nothing is implemented until its design section here is agreed;
nothing is marked ✅ until its Definition of Done is fully met and gated.**

## Status legend
- ⬜ **TODO** — not started, design below.
- ✍️ **DESIGNED** — design agreed, ready to implement.
- 🔨 **WIP** — in progress.
- ✅ **DONE** — Definition of Done met, gates green in the full suite, commit recorded.
- 🅱️ **BLOCKED** — waiting on a dependency (named).

## Tracking convention (the "clarity after each completion" ask)
Every item has an **ID**, a **Definition of Done (DoD)** checklist, and a **Tracking** stub. On completion:
1. Every DoD checkbox is ticked.
2. The item's gate(s) are green in the **full suite** (`FUNC / ARC / SHADOW`, ASAN where relevant).
3. The **Tracking** line is filled: `✅ <date> · commit <sha> · gates <names> · <one-line note>`.
4. The **master table** status is flipped to ✅.
5. If the work changed the public surface, `feature-roadmap.md` row is updated to point here.

An item is **never** ✅ on "it compiles" or "the happy path works" — only on DoD + gates.

---

## ✅ Recently completed (2026-07-21 session) — foundation closed, roadmap advancing

These are DONE and verified (ASAN + `NOVA_ARC_AUDIT` + corpus), not "compiles":
- **F1–F5 memory-safety CLOSED** — A1 (`??` owned-default UAF), C2 (heterogeneous if-expr SEGV), the
  struct-field/tuple/err-union destructor cutover, nested-owned-list dtor, array-literal owned-temp, and
  the trait-widening fat-pointer leak all fixed. Corpus 103/103; ASAN + ARC-audit at floor.
- **Monomorphization COMPLETE** — abstract residue fully eliminated (`c8e1769`); worklist discovers
  method-return instantiations, spec-vs-base ARC reconciled, erased dead bodies dropped via reachability
  closure (M3-R1 `88db887` / R2 `992a6bb`).
- **BTreeDB end-to-end LIVE** — Nova → running server: connect / DDL / insert / query / typed-decode,
  ARC-clean (2 driver leaks fixed, `9a86f41`).
- **D4 — YCSB A–F in Nova vs live BTreeDB** ✅ — full suite runs (release: ~20–30K ops/sec), ARC-clean,
  **measurably faster than the Python YCSB baseline** (`4c17abd`, `8a5da75`).
- **Async runtime confirmed REAL** — multi-core (8 tasks 98 ms vs 616 ms serial; scales with
  `NOVA_THREADS`), async I/O (8 concurrent sleeps 201 ms on 1 thread). Not the "synchronous shim" the
  old roadmap claimed.
- **`fiber` retired → `spawn` keyword** — the C-runtime fiber shim deleted (`64df8f5`); `go`→`spawn`
  contextual keyword (`2a3573a`), soft so `process.spawn` still parses.
- **PRODUCT SURFACE COMPLETE — T3 → W1 → W2 → W3 → T5** (see the "🏁 Product surface COMPLETE" section below
  and the master table): FFI (`extern("lib")`), native webview (bind/dispatch/NSX, 100%), `App.useStatic`
  (LruCache + static store), outbound circuit breaker, and `nova init web`/`desktop` scaffolds.
- **Bitwise operators `^` and `~`** (2026-07-22) — closed the incomplete bitwise set (`& | << >>` had no
  `^`/`~`). `^` = XOR with C-family precedence `& > ^ > |`; `~` = one's complement (lowers to LLVM `xor`/`not`);
  integers only. Spec §operators updated; gate `88_bitwise_xor` (values, precedence, `~`, `x & ~mask`, 64-bit
  ulong). Retired the `(a|b)-(a&b)` XOR workaround in `crypto/random.nova`. Unblocks C1 (SCRAM's `ClientProof =
  ClientKey ^ ClientSignature`). Also added the **bitwise compound-assignments** `&= |= ^= <<= >>=` (desugar to
  `a = a <op> b`, like `+=`). The bitwise operator set (`& | ^ ~ << >>` + compounds) is now complete.
- **General language/stdlib fixes landed this session** (all gated, corpus 103→108):
  - **typed lambda params** `(s: string) => …` (§10 #19) + **module-qualified const access** `mod.CONST` +
    confirmed function-type return annotations (`29a1f07`, gate `84`).
  - **FFI callbacks** — `nova_invoke_str_closure` primitive; C invokes a Nova closure (gate `83`).
  - **`nova test` was broken for EVERY user project** — std read from `~/.nova/std` took its absolute HOME
    path as identity → stdlib free fn collected/called under different spellings → `nextPowerOfTwo not found`;
    fixed in loadProgram (canonical `src/std/…` spelling) + a project-root `src/<module>` import fallback (`c13fb7c`).
  - **latent stdlib bugs** exercised for the first time and fixed: `nova_file_read_all` typed `.string` →
    `.int` (was ARC-releasing an int as a pointer → SIGSEGV, broke `File.readText`); `client.nova` `Request{…}`
    missing `cookies`.

The foundation + product surface are done. Remaining work is the non-product backlog: harness integrity (H1),
optionals soundness (H2), the F1–F5 finishers, crypto/drivers (X2/C1/D2/D3), serde/regex/decimal (S1–S4), and
toolchain/tooling (T1/T2/T4).

---

## Master status table

| ID | Item | Prio | Status | Gate(s) | Commit |
|----|------|------|--------|---------|--------|
| **X1** | Flagship redesign — clean `app.get<T>` (no `__addRoute`) + pipeline, per design | ⭐P1 | ✅ | `69_app_typed_routing`, `68_generic_verb_fnptr`, `70_trait_in_generic_container` | `02210b6` |
| **X2** | Crypto folder refactor (`crypto/{sha,md5,base64,random}`) — split + base64 + CSPRNG/PCG32 | ⭐user | ✅ | `25_crypto` + `87_crypto_base64` | (this session) |
| **H1** | Conformance harness integrity — self-testing negative-case guard (aborts if broken) | P0 | ✅ | `harness-selftest/` + self-test in `run.sh` | (this session) |
| **H2** | Optionals soundness — trapping `at()` + `??` strips optional + narrowing; unguarded access is a compile error | P0 | ✅ | `optional_unguarded` + `91_optional_soundness` | (this session) |
| **F1** | F4-1: type args survive parse — explicit `Foo<int>{}` + generic-trait impl | P0.5 | ✅ | `80_struct_init_typeargs` | (verified) |
| **F2** | Module-qualified type inside a closure | P0.5 | ✅ | `34_module_type_in_closure` | (verified) |
| **F3** | F3-5: honest i32 slots ✅ (out-of-range literal rejected); overflow WRAPS (defined) — trap deferrable | found | ◑ | `int_overflow_trap` | (verified) |
| **F4** | F1-7: unresolved-call is a hard error ✅ (F2-5); F1-6 Itanium mangling still open | found | ◑ | `undefined_function` | (verified) |
| **F5** | F1-4: function-visibility across multi-segment imports | found | ✅ | `private_fn_cross_module` | (verified) |
| **C1** | crypto expansion: PBKDF2 + SCRAM-SHA-256 primitives | P4 | ✅ | `89_crypto_scram` (RFC 7677) | (this session) |
| **D1** | MySQL live verification (MySQL 9, caching_sha2 auth) | P3 | ✅ | live via `ycsb_mysql` (A–F) | (this session) |
| **D2** | MSSQL driver (TDS 7.4) — offline codec + **live SQL-auth (cleartext AND TLS/ENCRYPT_ON)**, decimal/money/unicode exact; NTLM deferred | P3 | ✅ | `100_mssql_codec` | `d72dac1`, `d377cf1`, `1f8448b`, `48b47f2` |
| **D3** | MongoDB driver (OP_MSG + SCRAM) — shipped as a **PACKAGE**; now **async/non-blocking** + all 4 SQL drivers ALSO moved to `packages/nova-<name>` (db seam + generic pool stay std) | ⭐P6 | ✅ | `90_bson_binary` + package `tests/` (17/17) + live vs mongod | (this session) |
| **D4** | YCSB benchmarks in Nova vs BTreeDB | P2 | ✅ | bench A–F (live BTreeDB) | `4c17abd` `8a5da75` |
| **D5** | YCSB over the `Driver` trait — driver-generic; **ALL FOUR engines (BTreeDB + Postgres + MySQL + MSSQL) live** ✅ by swapping only the Driver | ⭐P3 | ✅ | `repro/ycsb/` (4 engines live) | (this session) |
| **D6** | Driver **hardening + completeness DONE**: timeouts + pooling + circuit-breaker + **all auth** (MySQL fast **& RSA full**, **PG SCRAM**) + **real server-side prepared statements on all 4 engines** (PG extended-query, MySQL COM_STMT binary, MSSQL sp_prepare RPC, BTreeDB); live on all. Async-recv now DONE under A1 (async-first seam → drivers non-blocking) | P3 | ✅ | `104`–`110` + driver gates + live | (this session) |
| **E1** | Error model `T \| Error` — `try`/`catch`/`catch (e)` + **`errdefer`** ✅; unguarded `.field` on `T\|E` = located typecheck error; `throw` removed (two-register-return = deferred perf opt) | P4 | ✅ | `32`/`33`/`45`/`101_errdefer` + `errunion_unguarded` | (this session) |
| **A1** | async: **`future<T>` first-class** ✅ + **`when_all`/`parallel_for` fan-out/join** ✅ + **async METHODS + async TRAIT methods w/ dynamic dispatch** ✅ + **AsyncStream (parking socket I/O)** ✅ + **non-blocking TLS** (wolfSSL memory-BIO pumped by Nova async; crypto stays in wolfSSL) ✅ + **AsyncIO trait** ✅ + **async-first `Connection` seam — ALL 5 drivers non-blocking** ✅ (PG+MySQL LIVE-PROVEN: 5 concurrent server-side sleeps on ONE scheduler thread overlap ~0.3–0.7s vs ~1.5s serial; MSSQL TDS-tunneled async TLS; MongoDB async live) + **async `Driver.connect` → pooling works INSIDE coroutines** ✅ (live: concurrent handlers each `await pool.acquire()`+query+release, second wave reuses idle conns) + **awaited-deadline recv timeouts** ✅ (`Connection.setTimeout` real on the async transport — recv raced against a timer, `nova_arecv_deadline`; live: `pg_sleep(1)` under 150ms → empty in ~0.15s) + **`select` over futures** ✅ (`selectAny<T>` — await first of N, non-consuming) + **whole-query deadline** ✅ (`withTimeout<T>`/`selectTimeout<T>`; live: `pg_sleep(2)` bounded to 300ms) + **actor stdlib layer** ✅ (`Mailbox<M>`+`Behavior<M>` trait+`runActor<M>`; required **generic trait objects**, also fixed) + **generic-return typecheck** ✅ (`foo<int>()` result resolves `T`→`int`, `List<T>`→`List<int>`, etc.). **A1 COMPLETE** | P4 | ✅ | `102_future_first_class`, `103_async_when_all`, `111`–`119` (async_trait / stream / tls / timeout / select / whole_query_deadline / actor / generic_return) | `e645bb7`,`bdf60f2`,(this session) |
| **S1** | serde completeness — exact decimal in JSON/YAML via manual API **and** `@serializable` structs ✅ + 2 pre-existing yaml ARC/co-import bugs fixed ✅ (F4-6 reparse-removal relocated to T6-1b; streaming = future enhancement) | P4 | ✅ | `96`–`99` (`serde_decimal_json/yaml`, `coimport`, `struct_decimal`) | `92b507f`, `9d7553a`, `0f41faa` |
| **S2** | regex engine (bytecode-VM backtracking) + foundational early-`return`-in-loop double-free fix | P4/Tier3 | ✅ | `92_regex`, `93_loop_early_return_arc` | `54e31b4` |
| **S3** | decimal follow-ups: div/mod-by-zero TRAP + explicit `int↔decimal` conv | Tier3 | ✅ | `94_decimal_conv` | `8541922` |
| **S4** | text→decimal128 parser (`decimal.fromString`) + 3 DB drivers switched to exact `.dec` | P3 dep | ✅ | `95_decimal_parse` | `4c5adcc` |
| **T1** | Toolchain: bundled `.tbd` stubs + C++ runtime + ELF/Linux | P5 | ◑ | build (manual) | — |
| **T2** | WASM pointer-width audit (modules run correctly) | P5 | ⬜ | `--wasm-run` | — |
| **T3** | FFI (`extern("lib") fn`) — **keystone for W1/W2/W3** | ⭐P2 | ✅ v1 | `82_ffi_extern` | `97ba8ef` `1e31ad1` |
| **T4** | Tooling: LSP FULL ✅ + package manager ✅ + `nova fmt` comment-preserving/idempotent ✅ (44→53 coverage); fmt construct long-tail remains | P5/6 | ◑ | `fmt-check.sh` + nls e2e + `pkg-manager-check.sh` | `4e4571c` |
| **T5** | `nova init` templates → **`web` (VSA + per-feature JSX) AND `desktop` (webview)**, replacing `app` | ⭐P3 | ✅ | scaffold build+test (manual) | `c13fb7c` |
| **W1** | Webview in the runtime (desktop GUI over HTML/JS/NSX) | ⭐P3 | ✅ | `webview_*` (manual) + `83`/`84` | `513ecf2`+`29a1f07` |
| **W2** | `App.useStatic(...)` — static content store + LRU cache | ⭐P3 | ✅ | `85_static_content` | `ddd2c08` |
| **W3** | Circuit breaker for the OUTBOUND TCP/TLS client (external calls) | ⭐P4 | ✅ | `86_circuit_breaker` | `a63ffa4` |
| **T6** | Phase 1a ✅ (`nova build` + `build/<profile>/{obj,bin}` + content-hash cache + debug/release); **Phase 2 dead-code strip ✅ (`-dead_strip`/`--gc-sections`, 71% smaller binaries)**; **Phase 1b (per-file `.o` split) IN PROGRESS** — increment 1 (per-file fn partition, `NOVA_T6_SPLIT`, 0 uncategorized) ✅ + increment 2 step 1 (`emitModule` extraction) ✅; remaining: the per-file emission loop (+ F4-6 reparse removal, landed together) | ⭐user P5 | ◑ | `nova build` (manual e2e); `NOVA_T6_SPLIT` partition | `1b85154`,`af4932a`,`4d1bb61` |

Legend for the "◑" rows: partially landed; the *remaining* scope is the design below.

**Current state (2026-07-24):** corpus **148/148 functional, 266/266 ASAN** clean; ARC-audit at floor. **25 of 31
items ✅** (5 ◑ partial, 1 not started). Since the last update this session also: closed the last **A1** follow-ons
(actor stdlib as `ActorCell.run()` generic-async METHOD + generic-trait-FIELD dispatch fix, gate 120; channel-gated
fan-out overlap gate 121); fixed two real **sema** bugs found by running a scaffolded web app (enum-method return
types + field-receiver closure param typing, gate 122); took the **web framework** to ~108k rps / 2.25× a same-machine
Zig baseline (keep-alive → response cache → cache-before-parse → zero-copy framing) and root-caused the
"read_string ARC crash" as a **pointer-truncation** bug (int-typed address arithmetic truncates to 32 bits → type
buffer addresses `long`); and advanced **T6** (dead-strip + per-file split increments 1 & 2-step-1). **A1 (async) is
COMPLETE** — the async-first DB seam plus the full async
combinator set (timeouts, select, whole-query deadline, actors) and generic-return typechecking. All five
drivers — Postgres,
MySQL, MSSQL (TDS-tunneled async TLS), BTreeDB, MongoDB — are non-blocking over one `db.Connection`/`db.Driver`
seam, their socket recv PARKS the coroutine instead of holding the scheduler thread (PG+MySQL live-proven: 5
concurrent server-side sleeps on ONE thread overlap ~0.3–0.7s vs ~1.5s serial). Non-blocking TLS was built the
right way — wolfSSL keeps all crypto + cert-verification (memory-BIO), only the record pump is Nova async. The
concrete drivers now live in **`packages/nova-<name>`** (the `db` seam + generic `pool` stay in std). Also live:
**timeouts + pooling + circuit-breaker + full auth + real server-side prepared statements on every engine**; error
model (`try`/`catch`/`errdefer`) complete; `future<T>` first-class + `when_all`/`parallel_for`.
✅ done (25): X1, X2, H1, H2, F1, F2, F5, C1, D1, **D2**, D3, D4, **D5**, **D6**, **E1**, **A1**, S1, S2, S3, S4,
T3, T5, W1, W2, W3. ◑ partial (5 — remaining scope in the design below): F3 (overflow-trap deferred by design),
F4 (Itanium mangling), T1 (ELF/Linux toolchain), T4 (fmt long-tail), T6 (Phase 1b).
⬜/🅱️
not started (1): T2 (WASM pointer-width audit). The single largest deferred keystone is **T6 Phase 1b** — the
per-file `.o` split, which now also absorbs **F4-6** (retiring the serde/mediator source-gen+reparse; relocated
from S1 because it is behavior-neutral and only pays off with per-unit compilation).

---

# ⭐ X1 — Flagship redesign: clean `app.get<T>`, per the ratified design

**Why re-do it.** The current flagship works at the call site (`app.get<GetUser>(path)` returns typed JSON)
but the *architecture* is a workaround the design (`route-handling-via-mediator.md`) did not sanction:
- `pub fn __addRoute(...)` is exposed on the App API (never agreed);
- dispatch routes by **type-name string** via a generated `__mediator_dispatch_by_name` switch, not by a
  reified per-request dispatcher — this is the *flavor* the design set out to remove;
- the typed handler lives in a **separate `web/routing.nova` Router**, not in `App`/`web/mediator.nova`;
- the **mediator pipeline** (behaviors/pre/post/exception) is not threaded through dispatch.

**Target public surface (the ONLY thing users see) — bare verbs (roadmap override of the doc's `map` prefix):**
```nova
struct GetUserHandler impl RequestHandler<GetUser, UserDto> {     // web/mediator.nova
    fn handle(self, req: GetUser): UserDto { return UserDto{ id: req.id, name: "Ada" }; }
}
let app = App();
app.get<GetUser>("/api/user/{id:int}");   // + post/put/delete/patch/options/head
app.run(8080);
```
`App` exposes **only**: `get<T>/post<T>/put<T>/delete<T>/patch<T>/options<T>/head<T>`, `run(port)`, and
`dispatch(req): Response` (for in-process testing). **No `__addRoute`, no `Mediator`, no `MessageHandler`.**

**Design of the internals (the part that must change):**
1. **`RequestHandler<TRequest,TResponse>`** trait moves to `web/mediator.nova` (per design §4.1);
   `web/routing.nova` is **deleted**, its Router folded away. Pipeline traits (`PipelineBehavior`,
   `PreProcessor`, `PostProcessor`, `ExceptionHandler`) are defined here too (design §1.5 table).
2. **Per-request dispatcher stays compiler-generated** — `__mediator_dispatch_<Q>(src: ValueSource): string`
   emits `TResp__toJson(pipeline(H{}.handle(Q__bind(src))))`. This is `ptr→ptr` and **marshals fine as a
   value** (verified) — unlike the raw `handle` (struct→struct) which does not.
3. **The lowering reifies the dispatcher as a fn-pointer, not a name.** `app.get<GetUser>(path)` lowers to
   an **internal, non-`pub`** registration `self.__register("GET", path, &__mediator_dispatch_GetUser)`
   where the 3rd arg is a `(ValueSource) -> string` fn-value. The route stores `{method, segs, dispatch}`.
   Dispatch calls `route.dispatch(src)` directly — **no name switch, no `__mediator_dispatch_by_name`.**
   - **Crux / risk:** codegen must resolve a *generated* function as a fn-value from a *synthesized* call
     (today a bare generated-fn used as a value doesn't resolve — SymbolId vs plain-name in `func_map`).
     This is the one real implementation task. Fallback if it proves hard: keep `__register` internal and
     name-keyed, but **still remove it from the public API** (the user's hard requirement is the clean
     surface + no `__addRoute`, not the internal encoding). The design *prefers* fn-ptr; the API cleanliness
     is non-negotiable, the fn-ptr internal is the target.
4. **Pipeline threading:** `dispatch` runs discovered `PipelineBehavior`s around `handle`, `PreProcessor`s
   before, `PostProcessor`s after, `ExceptionHandler`s on failure. Additive; ships after the core is clean.
5. **`@fromRoute` over `@fromBody`:** unchanged — `CompositeSource(ParamSource(routeParams), bodySource)`.
6. **`app.run`:** keep app.nova's existing async server (asyncio, Content-Length, 100-continue); it calls
   the new `dispatch`.

**Files:** `web/mediator.nova` (RequestHandler + pipeline traits), `web/app.nova` (App rewrite),
delete `web/routing.nova`; `src/codegen/expressions.zig` (verb lowering → fn-ptr register), `src/main.zig`
(`generateMediatorDispatch` — keep per-Q dispatchers, drop the by-name switch), migrate gates 58/59/60 → App.

**Definition of Done:**
- [x] `App` public API is exactly `get/post/put/delete/patch/options/head<T>`, `run`, `dispatch`; no `__addRoute`, no `Mediator`/`MessageHandler` types. (all 7 verbs in `routeVerbMethod`; `__route` is the internal lowering target, fn-pointer-based.)
- [x] `web/routing.nova` deleted; `RequestHandler` + pipeline traits in `web/mediator.nova`.
- [x] Route stores a reified dispatcher fn-pointer — dispatch calls it directly, no public string switch. (enabled by generated-fn-as-value fix `d19699c`.)
- [x] Gate `69_app_typed_routing`: `app.get<T>` → typed JSON; `@fromRoute` over `@fromBody`; 404/405; auto-JSON.
- [x] Gate `69` (pipeline): `app.use(behavior)` — a `PipelineBehavior` wraps the response, short-circuits without running the handler, and two behaviors nest in order.
- [x] Old flagship gates 58/59/60 superseded by 69; full suite green (87/154/154) + ASAN.
- [x] Prove-first: spikes A/B + gate `68_generic_verb_fnptr` demonstrated the clean lowering before the stdlib rewrite.

**Status: ✅ COMPLETE. Two enabling compiler fixes landed en route: (1) `d19699c` generated-fn-as-value
resolution; (2) `7424e27` trait-widening at generic method params (`List<Trait>.push(concrete)` — the
REAL root cause of the "closure crash"; the closure was never the problem). Pipeline behaviors are
envelope-level (`ValueSource → string`, MediatR wrap/short-circuit semantics); per-TRequest-typed
behaviors would need per-request-type codegen — a documented future refinement, not a gap in the wrap.**
**Dependencies:** `d19699c`, `7424e27`.
**Tracking:** ✅ 2026-07-20 · commits `d19699c` `3689378` `7424e27` `02210b6` · gates `68`/`69`/`70` green (FUNC 87/87, ARC 154/154, SHADOW 154/154, ASAN)

---

# ⭐ X2 — Crypto folder refactor

**Why.** You asked for a `crypto/` folder with focused files; instead the code piled into a single naive
`crypto.nova`, and MySQL auth scrambles were dumped there (they don't belong in a general crypto module).

**Target layout:**
```
src/std/crypto/
  sha.nova      # sha1, sha256, sha512, hmacSha256 (+ hmacSha1 if a driver needs it)
  md5.nova      # md5 (build currently sets NO_MD5 — wrapper + honest "unavailable" error)
  base64.nova   # encode / decode, standard + url-safe (implemented in Nova over bytes)
  random.nova   # BOTH generators (see below): CSPRNG + seedable PRNG
```
Import as `crypto.sha` / `crypto.md5` / `crypto.base64` / `crypto.random`; call `sha.sha256(...)`,
`base64.encode(...)`, etc.

**`random.nova` must provide BOTH an RNG and a PRNG (user, 2026-07-22) — they are different tools, do not
conflate them:**
- **CSPRNG (true/secure RNG)** — OS entropy via wolfCrypt (`randomBytes(n)` / `randomHex(n)` / `randomInt`).
  UNSEEDABLE and unpredictable; the ONLY correct source for salts, nonces, tokens, session/CSRF ids, SCRAM
  client-nonces, and any security context. This is what the DB drivers' auth flows must call.
- **Seedable PRNG (deterministic)** — a small fast generator (e.g. **xoshiro256\*\*** or **PCG**, superseding
  the ad-hoc LCG YCSB currently hand-rolls) exposed as a `Prng` value seeded from an explicit `u64`:
  `Prng.seed(s)` → `next()` / `nextInt(n)` / `nextFloat()`. REPRODUCIBLE by design — for tests, YCSB
  key/Zipfian distributions (D4/D5), sampling, jitter. **Never** use it where unpredictability matters.
- **Guard-rail:** the PRNG type/names must read as non-secure (`Prng`, `seed`) so a reviewer can't mistake it
  for the CSPRNG. A KAT pins the PRNG's sequence for a fixed seed (proves determinism); the CSPRNG gets a
  liveness/uniqueness check only (its output is by definition unpredictable).

**Moves / deletions:**
- **Delete `crypto.nova`.** Split its contents into the files above.
- **Move `mysqlNativeScramble` / `mysqlSha2Scramble` OUT of crypto** → private helpers in the MySQL driver
  (`data/sql/mysql.nova`, or `data/sql/mysql_auth.nova`). The raw runtime primitives (`nova_mysql_scramble`,
  `nova_mysql_sha2_scramble`) stay in the runtime; only the Nova wrapper relocates.
- Update **every** `import crypto` / `crypto.*` call site across the stdlib to the new module paths.
- Register the new modules in `src/main.zig` (`std_modules` + aliases).

**base64 (new):** standard `A–Za–z0–9+/` with `=` padding, plus url-safe `-_` no-pad variant; encode/decode
over `bytes`. KAT against RFC 4648 vectors.

**Definition of Done:**
- [x] `crypto/{sha,md5,base64,random}.nova` exist; `crypto.nova` deleted.
- [x] `random.nova` exposes **both** a CSPRNG (`randomBytes`/`randomHex`/`randomInt`) and a seedable `Prng`
      (PCG32, verified against published reference vectors).
- [x] MySQL scrambles no longer in crypto; moved into `data/sql/mysql.nova` (now `pub`, driver-owned); gate 67
      green.
- [x] All stdlib `crypto.*` call sites updated; nothing imports the old `crypto` module.
- [x] Gate `25_crypto` (SHA-1/256/512 + HMAC KATs, CSPRNG liveness, **PCG32 reference vectors + determinism**) +
      `87_crypto_base64` (RFC 4648 encode/decode + URL-safe) green.
- [x] Full suite green (**109/109**) + ASAN clean.

**Crypto needed by the drivers (why this precedes D2/C1/D3):** SCRAM-SHA-256 (Postgres/Mongo) needs
HMAC-SHA-256 + PBKDF2 (C1); **MSSQL/TDS** needs TLS-in-handshake (have wolfSSL) + the SQL Server password
**obfuscation** (nibble-swap then XOR `0xA5`, UTF-16LE) for SQL auth — a driver-private helper, NOT general
crypto; **Windows/NTLM** auth (if/when supported) additionally needs **MD4 + HMAC-MD5** (NTLMv2). Scope MSSQL as
**SQL auth first** (TLS + obfuscation), NTLM later. So the crypto build order is: X2 (sha/hmac/base64/random) →
C1 (PBKDF2 + SCRAM) → drivers; MD4/HMAC-MD5 only enter if NTLM is taken up.

**Dependencies:** none. **Precedes** C1 (SCRAM primitives extend `crypto/sha`) and D2/D3 (driver auth).
**Tracking:** ✅ 2026-07-22 · `crypto/{sha,md5,base64,random}.nova` (crypto.nova deleted); base64 in Nova over
`bytes` (RFC 4648); random = wolfCrypt CSPRNG + seedable **PCG32** (reference-vector KAT); MySQL scrambles
relocated into the driver. Gates `25_crypto` + `87_crypto_base64`; corpus 109/109 + ASAN clean. **Note:** MD5 is
`NO_MD5` in this wolfSSL build — `md5.nova` wraps it with an honest abort; enabling it (for MSSQL/NTLM) is a
build-flag flip + re-add the KAT.

---

# H1 — Conformance harness integrity (P0, route §8.A)

**Problem.** `run.sh` `expect_fail` treats any non-zero exit as "correctly rejected" — **a segfault reads as
a pass**. `return_type_mismatch` has silently regressed (compiles + crashes). The corpus never sets
`NOVA_ARC_AUDIT` by default in FUNC mode.

**Design:**
- `expect_fail` must assert the **reason**: the compiler prints a machine-checkable diagnostic tag (e.g.
  `error[typecheck]:`), and the harness greps for the expected category, not just exit≠0. A segfault (signal
  exit 139/138) is an explicit **FAIL** in `expect_fail`, never a pass.
- Fix the regressed `return_type_mismatch` (`fn f(): string { return 42; }` must be a typecheck error, not a
  crash).
- Convert the 4 crash-as-rejection negatives (`undefined_variable`, `undefined_function`,
  `method_shadowed_by_global_fn`, `ambiguous_bare_call`) into real diagnostics.

**Definition of Done:**
- [x] `expect_fail` asserts a diagnostic category; a segfault in a negative case FAILS. (`classify_failure`
      distinguishes `COMPILED-THEN-CRASHED`/`COMPILED-AND-RAN` from the reject kinds; a crash ≠ any declared
      kind → FAIL.)
- [x] `return_type_mismatch` rejects with a typecheck diagnostic (no crash). Verified: `rejected: typecheck`.
- [x] The 4 crash-negatives emit user diagnostics: `undefined_variable`/`undefined_function`/`ambiguous_bare_call`
      → `typecheck`; `method_shadowed_by_global_fn` → `codegen` (clean rejection, honest-debt span). None crash.
- [x] **Harness self-test** (`conformance/harness-selftest/` + a pre-flight in `run.sh`): two fixtures with
      KNOWN outcomes — `compiles-then-crashes.nova` must classify `COMPILED-THEN-CRASHED`, `compiles-and-runs.nova`
      must classify `COMPILED-AND-RAN`. If either is mislabeled as a reject kind, the classifier is broken and
      the run **ABORTS (exit 2)** — "every negative result is UNTRUSTWORTHY." **Proven**: neutering the crash-
      detection grep makes the self-test FAIL and abort with exit 2; the correct classifier passes both and
      proceeds (112/112). The negative gate is now itself falsifiable and continuously checked.

**Dependencies:** none — **done first**. **Tracking:** ✅ 2026-07-22 · `run.sh` self-test + `harness-selftest/`
fixtures; guard proven to abort on regression; corpus 112/112.

---

# H2 — Optionals soundness reconciliation (P0, route §8.B)

**Problem.** `l.get(5).length` on an absent optional **segfaults today**; assigning/passing/returning
`T | undefined` where `T` is expected compiles with no diagnostic. This directly conflicts with the shipped
`30_optional_member_access` see-through keeper.

**Design (decision required — recommend option A):**
- **A (recommended):** restrict the see-through to the *guarded* forms `?.` and `??`; bare
  `optional.field`/`optional.method()` becomes a **typecheck error** ("value may be undefined; use `?.`,
  `??`, or narrow with `if (x != undefined)`"). Add early-exit narrowing (`if (x == undefined) return;`
  narrows the rest of the block — needs reachability).
- **B:** full flow-narrowing everywhere (bigger; a real narrowing pass in `type_checker.zig`).
- **First: measure blast radius** — grep+count stdlib sites doing unnarrowed optional access (precedent: the
  load-bearing numeric permissiveness). Report the count before choosing.

**Definition of Done:**
- [x] Blast-radius count reported: **137 unguarded sites** (88 stdlib incl. 47-counted in bson, 49 corpus).
      Option **A** chosen (user): trapping accessor + compile-time reject (Rust/Swift model).
- [x] `l.get(5).length` (unguarded) is a **compile error**, not a crash: a located `Type checking failed`
      diagnostic with fix suggestions. Gate `expect_fail/optional_unguarded` (negative, classifies `typecheck`).
- [x] `at()`/`??`/`?.`/narrowed access still compile. Gate `91_optional_soundness` (positive, all four forms).
- [x] Full suite green (stdlib migrated to `at()`/`??`/narrowing). Corpus **114/114**, ARC + ASAN clean.

**What landed (2026-07-22):**
- **Trapping accessors** `List.at(i): T` / `Map.at(k): V` — return the value directly, LOUD `nova: panic`
  (new `nova_panic` runtime primitive) on absent, never a silent read. The ergonomic "I know it's valid" path.
- **`??` now strips the optional** — `xs.get(i) ?? d` is `T`, not `T | undefined` (it wasn't; even the guarded
  form still "saw through"). This one fix cleared ~half the sites.
- **Early-exit narrowing** (specs §3.4a) — `if (x == undefined) { return; } … x.field` narrows `x` to `T` for the
  rest of the block (fresh shadowing scope, correctly popped past nested guards). Plus the existing in-branch
  `if (x != undefined) { x.field }`.
- **The flip**: `fieldType`/`methodReturn` no longer see through an optional receiver — they record a hard error
  (`optional_deref_errors`, surfaced in `shadow.zig` like the visibility/const errors). The P2-14 runtime guard
  (`nova_optional_deref_fail`) remains as a backstop but is now unreachable for direct access.
- **Migrated all 137 sites**: bson `entries.get→at`, web/app + routing + multipart bounded loops → `at`, routing
  `for-in`→indexed `at`, db drivers already used `??` (fixed by the coalesce change), field-optionals bound to a
  local + narrowed, corpus 30/38/43/44/81 reframed to the sound forms.

**Note (memory-safety was already closed):** the *silent segfault* the problem statement described was fixed at
runtime in P2-14 (loud located abort). H2 adds the COMPILE-TIME soundness that P2-14 explicitly deferred.

**Dependencies:** H1 (done — negative gate is trustworthy). **Tracking:** ✅ 2026-07-22 · `at()` + `??` fix +
early-exit narrowing + see-through→hard-error; gates `optional_unguarded` + `91_optional_soundness`; 114/114.

---

# F1 — F4-1: type args survive parse (P0.5)

**Problem.** `StructInit` drops explicit type args; `Foo<int>{…}` and impl-side `impl Handler<A,B>` arg
storage rely on this. **Design:** add `type_args: []TypeRef` to `StructInit` (parser + AST), thread through
sema so `Foo<int>{…}` type-checks and monomorphizes correctly. **DoD:** gate `generic_type_args` (explicit
`Foo<int>{…}`, and an impl with type args round-trips); full suite green. **Deps:** none. **Tracking:** _pending_

# F2 — Module-qualified type inside a closure (P0.5)

**Problem.** `response.Response(...)` / `Status.Ok.toCode()` inside a closure → `StructTypeNotFound` /
`MethodOrFunctionNotFound` (the lifted closure loses qualified-name resolution). Also the cross-module
`Status.toCode(x)` gap found this session. **Design:** in the closure-lifting pass, carry the module/type
resolution context so qualified constructors + enum methods resolve inside the lifted function body. **DoD:**
gate `ns_type_in_closure` (construct a module-qualified struct + call an enum method inside a closure); the
`Status.toCode(x)` cross-module gate passes; full suite green. **Deps:** none. **Tracking:** _pending_

# F3 — F3-5: honest int slots + overflow trap (foundation)

**Problem.** `int` locals are i64 slots; arithmetic silently wraps at i32 in places (the NULL-detect bug this
session). **Design:** per the F3 staged plan — int locals become i32 with checked arithmetic + an overflow
trap (or explicit wrapping ops). Migrate stdlib last. **DoD:** gate `int_overflow_trap` (overflow traps, not
wraps); the `0xFFFFFFFF` round-trips are explicit; full suite green. **Deps:** none, but touches many sites —
schedule deliberately.

**State (verified 2026-07-22):** honest i32 slots are DONE — an out-of-range literal (`let x: int = 5000000000`) is rejected at compile time ("out of range for 'int' — use 'long'"). Arithmetic overflow currently WRAPS two's-complement (`i32max + 1 == i32min`) — DEFINED behavior, not UB, so it is memory-safe. A trap-on-overflow is a footgun-preventer, NOT a soundness hole, and it CONFLICTS with the energy-efficiency goal (checks cost cycles) AND with the stdlib's intentional wrapping (the LCG/PRNG/hashing use `long`/`ulong` wrap on purpose). Recommended: DEFER; if taken, use the Rust model (checked in debug/test, wrap in release so energy-critical release binaries pay nothing) + explicit `wrapping_*` for intentional wrap. **Tracking:** ◑ verified — honest slots done; overflow-trap deferred by design.

# F4 — F1-6/F1-7: mangling + unresolved-call-is-error (foundation)

**Design:** F1-7 makes an unresolved call at end-of-sema a hard error (N3); F1-6 adds Itanium name mangling
for overloadable symbols. **DoD:** negative gate `unresolved_call` (rejected with diagnostic); mangled
symbols don't collide across modules; full suite green. **Deps:** H1. **Tracking:** _pending_

# F5 — F1-4 finish + function-visibility multi-segment-import hole (foundation)

**Problem.** Multi-segment imports resolve types robustly but **functions** have a visibility hole (task #21).
**Design:** make function visibility across multi-segment imports enforce the same `pub` rule as types
(uniform module scoping). **DoD:** negative gate `fn_visibility` (non-pub fn across a multi-segment import is
rejected); positive still works; full suite green. **Deps:** none. **Tracking:** partially in progress (task #9/#21).

---

# C1 — Crypto expansion: PBKDF2 + SCRAM primitives (P4) ✅

**Depends on X2** (extends `crypto/sha`). **Design:** add `pbkdf2HmacSha256(pw, salt, iters, dkLen)` and the
SCRAM-SHA-256 building blocks (client-first/server-first/client-final message helpers, `Hi`, `H`, `HMAC`,
`XOR`) — shared by PostgreSQL SCRAM auth and MongoDB. Primitives in `crypto/sha.nova` + a `crypto/scram.nova`.

**What landed (2026-07-22):**
- **Runtime, byte-accurate.** The existing `nova_sha256`/`nova_hmac_sha256` are binary-safe on INPUT (Nova
  strings carry their length) but return HEX — no good for a key chain that XORs/re-hashes 32-byte binary
  blocks. Added three RAW-byte wolfCrypt primitives: `nova_pbkdf2_hmac_sha256` (wc_PBKDF2), `nova_hmac_sha256_raw`,
  `nova_sha256_raw`. Declared native in codegen; fallback stubs abort honestly without wolfSSL.
- **`crypto/sha.nova`** now exposes `pbkdf2HmacSha256`, `hmacSha256Raw`, `sha256Raw`, `toHex`. PBKDF2 KATs
  (published `"password"`/`"salt"` vectors, 1 / 2 / 4096 iters) green.
- **`crypto/scram.nova`** — the full SCRAM-SHA-256 client: low-level primitives (`saltedPassword`/`clientKey`/
  `storedKey`/`clientSignature`/`clientProof`/`serverKey`/`serverSignature`, `clientProof` = `ClientKey ^
  ClientSignature` using the new `^`), plus a high-level `ScramClient` (clientFirstMessage / clientFinalMessage
  that parses the server-first-message and emits `c=biws,r=…,p=…`).
- **KAT is the RFC 7677 §3 reference exchange** (user `user`, password `pencil`): the computed base64
  ClientProof == `dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=` and ServerSignature ==
  `6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=` — proves the entire chain end to end. Gate `89_crypto_scram`.

**DoD:** [x] PBKDF2 KATs; [x] known SCRAM exchange (RFC 7677); [x] gate `89_crypto_scram`; [x] corpus 111/111,
ASAN + ARC-audit clean. [ ] Postgres SCRAM auth against a live SCRAM-only server (manual — deferred to D-series
driver verification, where the driver calls `ScramClient`). **Deps:** X2 (done), `^` (done). **Tracking:**
✅ 2026-07-22 · `crypto/scram.nova` + raw-byte runtime primitives · gate `89_crypto_scram` · RFC 7677 verified.

---

# D1 — MySQL live verification (P3) ✅

**State:** codec + auth were golden-verified but never live. **Now LIVE-VERIFIED against MySQL 9.7** (Homebrew)
via the D5 YCSB runner (`repro/ycsb/ycsb_mysql.nova`): full A–F, correct query/scan rows, ARC + ASAN clean.

**What the live run revealed + fixed (the handshake flow):**
- **AuthSwitchRequest (0xfe).** MySQL 8/9 replies to the handshake response with an AuthSwitchRequest naming the
  plugin + a FRESH 20-byte salt; the driver now parses it, re-scrambles (`caching_sha2` / native) against the
  new salt, and replies at `seq+1`. Without it, auth silently DESYNCED — every subsequent command returned a
  spurious OK while nothing actually executed (the classic "it says OK but the table isn't there").
- **Empty password → empty scramble** (a computed 32-byte scramble fails an empty-password account).
- **caching_sha2 fast-auth-success** (`AuthMoreData 0x01 0x03`) → consume the trailing real OK.
- **Live-path ARC leaks fixed:** `MyReader`'s 64KB buffer (a `delete()` destructor frees it) and the per-packet
  payload (bind `as string` to a local before the `Packet(...)` ctor) — same class as the BtReader fixes.
- **Auth caveat:** caching_sha2 FULL auth (uncached password over a plaintext channel → RSA public-key exchange)
  is NOT implemented; use TLS or a password already cached by the server. Empty and cached passwords work.

**DoD:** [x] live A–F run, correct rows, gate 67 still green (corpus 112/112), ARC + ASAN clean. **Deps:** a
running MySQL (done). **Tracking:** ✅ 2026-07-22 · live vs MySQL 9.7 via `ycsb_mysql`; AuthSwitchRequest +
fast-auth + ARC fixes.

# D2 — MSSQL driver (TDS) (P3)

**Design:** TDS packet framing/reassembly → PRELOGIN (encrypted) → LOGIN7 → SQLBatch/RPC → `COLMETADATA`/`ROW`
token-stream decode → typed `DbValue` (incl. `DECIMAL`/`NUMERIC`, `MONEY`, unicode). **TLS is mandatory during
login** — needs the wolfSSL channel wired into the handshake. Implements `db.Connection`/`db.Driver`. Offline
byte-verify the token stream first; live vs a container `sqlservr`.

**Auth scope — SQL auth first, NTLM later.** SQL-Server login needs only TLS (have) + the password
**obfuscation** (nibble-swap + XOR `0xA5`, UTF-16LE) — a driver-private helper, no new general crypto.
Windows/NTLM auth is a later, optional phase and is what pulls in **MD4 + HMAC-MD5** (NTLMv2); do not block the
driver on it. Like the other engines, MSSQL is a **package** target (see the driver-distribution policy), built
against the std seam.

**DoD:** gate `mssql_codec` (PRELOGIN + LOGIN7 + token-stream row decode offline); SQL-auth login works live;
NTLM deferred; live optional. **Deps:** X2 (crypto/random, TLS), TLS-in-handshake. **Tracking:** ✅ 2026-07-22 ·
gate `100_mssql_codec` · commits `d72dac1`/`d377cf1`/`1f8448b` + TLS live.
**Landed:** the TDS 7.4 driver (`data/sql/mssql.nova`) — packet framing/reassembly, PRELOGIN, LOGIN7 (94-byte
header + UTF-16LE, nibble-swap+XOR password obfuscation), SQLBatch, token-stream decode (COLMETADATA/ROW/DONE/
ERROR) → typed `DbValue`: INT (INTN 1/2/4/8), BIT, VARCHAR/NVARCHAR (unicode UTF-16→UTF-8), DECIMAL/NUMERIC and
MONEY (**scale-preserving**, exact decimal128), GUID/blob. **LIVE-VERIFIED (cleartext, ENCRYPT_NOT_SUP)** against
SQL Server 2022: PRELOGIN→LOGIN7→DDL/DML/SELECT round-trip, ARC+ASAN clean, correct 19.9900/1234.5600/-0.0001/
-50.0000/int/nvarchar/bit. Offline gate `100_mssql_codec` (obfuscation vector + full row decode).
En route fixed the S3-deferred decimal-arith inference bug (a `9.99m` literal typed `null` in
`type_checker.resolveExprType` → `decimal <op> decimal` mis-typed i32; added the `.decimal` literal arm).
**TLS (ENCRYPT_ON) — LIVE-VERIFIED.** TDS-tunneled TLS: custom wolfSSL I/O callbacks (`nova_tds_tls_*` in io.cpp)
that wrap the TLS handshake in PRELOGIN packets, then raw TLS; driver `?encrypt=true` DSN option + TLS channel
(`chanSend`/`tfill`). Two things were load-bearing and diagnosed via wolfSSL debug logging + an OpenSSL reference:
(1) wolfSSL rebuilt with **`WOLFSSL_SECURE_RENEGOTIATION`** (build.zig) so the ClientHello carries
`renegotiation_info` (Schannel requires it); (2) **coalescing each TLS FLIGHT into ONE PRELOGIN packet**
(`nova_tds_flush` buffers wolfSSL's per-record sends, flushed before each read) — SQL Server 2022 rejects a
flight split across packets. Verified: encrypted CREATE/INSERT/SELECT round-trip (`?encrypt=true`), TLS 1.2
ECDHE, exact decimal/money/unicode, ARC+ASAN clean. **Deferred:** NTLM (MD4+HMAC-MD5).

# D3 — MongoDB driver (OP_MSG + SCRAM), shipped as a PACKAGE (P6, ⭐packaging vehicle) ✅

**Design:** OP_MSG 16-byte header + sections; connect → `hello` → `insert`/`find` (a command is a BSON doc);
SCRAM-SHA-256 (reuses C1). Offline byte-verify wire+BSON first; live vs `mongod`.

**What landed (2026-07-22) — `packages/nova-mongodb/`, a real package:**
- **Scaffolded with `nova init console`**, imports stdlib only (`serde.bson`, `crypto.scram`, `net.tcp`, `db`).
  `src/mongodb.nova` is the importable module; `tests/main_test.nova` is the offline codec gate.
- **OP_MSG wire codec** — `encodeOpMsg`/`decodeOpMsg` (16-byte header + flagBits + section-kind-0 + BSON body),
  byte-verified (opcode 2013, length prefix, requestID, round-trip).
- **Command builders** — `helloCommand`, `insertCommand` (documents array), `findCommand` (filter),
  `saslStartCommand`/`saslContinueCommand` (SCRAM payloads as BSON binary).
- **SCRAM auth** via `crypto.scram.ScramClient`; `MongoConnection.authenticate` runs saslStart→saslContinue.
  The offline gate drives the RFC 7677 exchange through the driver's command path and matches the reference proof.
- **db seam** — `MongoDriver impl Driver` + `MongoConnection impl Connection` (+ the native `runCommand`).
  (Finding: the SQL-shaped `exec/query` seam is a poor fit for a document DB; the native `runCommand`/command
  builders are the real interface, and the seam is a thin adapter.)
- **Enabling std work:** added **BSON binary (type 0x05)** to `serde/bson.nova` (`entryBinary`/`docGetBinary`),
  and fixed a latent **ARC leak in BSON embedded docs/arrays** — `entryDoc`/`entryArray` now adopt the sub-doc
  bytes as an ARC-owned string (`str_val`) instead of a leaking raw `ptr` in `int_val`. `docGetDoc`/`docGetArray`
  return the embedded bytes as a string. Gate `90_bson_binary`.
- **Package flow proven end to end:** `nova-mongodb` as a git repo → consumer `project.json` deps → `nova get`
  fetches it into `~/.nova/cache/` → `import mongodb` resolves from the cache → consumer tests pass + a binary
  runs, using the driver's codec. (The package source lives at `packages/nova-mongodb/`; publish to a remote to
  `nova get` it elsewhere.)

**DoD:** [x] OP_MSG framing + hello/insert/find offline; [x] BSON binary + embedded round-trips
(`90_bson_binary`); [x] SCRAM via C1 (RFC 7677 through the driver); [x] package fetched + consumed via
`nova get`; [x] package tests ARC + ASAN clean; corpus 112/112. [ ] live vs `mongod` (deferred — no server);
[ ] full cursor decode of `find` results into `DbValue` rows (follow-up). **Deps:** X2/C1, seam, T4 package
manager (all done). **Tracking:** ✅ 2026-07-22 · `packages/nova-mongodb` · gate `90_bson_binary` + the
package's own `tests/` · fetch-and-consume demonstrated.

# Driver distribution policy — seam + first-party in std, third-party drivers as PACKAGES

**Question (user, 2026-07-22):** should mysql/postgres/mssql/btree drivers ship out-of-the-box in the stdlib?
**Recommendation: NO for the third-party engines; keep only the SEAM + the first-party BTreeDB driver in std.**

- **In std (blessed, versioned with the language):** the DB abstraction — `db.Connection`/`db.Driver` traits,
  `DbValue`, the binary-protocol helpers, `decimal128`/BSON codecs — plus **BTreeDB** (Nova's own engine, the
  batteries-included default so `nova init` apps work with zero deps).
- **As packages (`nova get`):** PostgreSQL, MySQL, **MSSQL**, MongoDB. Each is a security-sensitive network
  client that tracks a database's own release cadence (new auth methods, protocol features); as a package it
  patches and versions independently of the compiler, doesn't bloat the std/compile surface, and keeps the
  language's trust surface small.
- **Precedent:** Go ships `database/sql` (the interface) in std but `pq`/`go-sql-driver`/`go-mssqldb` are
  external; Rust `sqlx`/`tokio-postgres` are crates; Python bundles only `sqlite3`, `psycopg`/`pymysql` are pip.
  The consistent industry shape is **abstraction in std, drivers as packages** — which is exactly why the
  MongoDB driver is the package-manager's proving ground.
- **Migration note:** postgres/mysql currently live under `src/std/data/sql/` (bundled). Long-term they move to
  packages too; keep them in-tree until the package flow is battle-tested via MongoDB, then extract. BTreeDB
  stays. (Not urgent — record the direction; don't churn working drivers yet.)

# D4 — YCSB benchmarks in Nova vs BTreeDB (P2, CLAUDE.md goal) ✅

**Design:** YCSB core workloads (A–F) written in Nova against the BTreeDB driver: load phase + transaction
phase, Zipfian (Gray et al., θ=0.99) / uniform key distributions via an LCG PRNG, latency/throughput reporting.
**DoD:**
- [x] Workloads **A–F** run against a live BTreeDB and report throughput+latency.
- [x] Load + transaction phases; zero-padded string keys (`user00000001`); typed row decode.
- [x] ARC-clean under sustained load; release build ~20–30K ops/sec.
- [x] Numbers recorded; **faster than the Python YCSB baseline**.

**Status: ✅ COMPLETE.** BTreeDB (releasefast) + YCSB Nova (release), 10K-record run + full A–F sweep.
**Deps:** BTreeDB driver (done), running engine. **Tracking:** ✅ 2026-07-21 · commits `4c17abd` `8a5da75` ·
bench A–F live · Nova+BTreeDB both beat Python.

# D5 — YCSB over the `Driver` trait: PostgreSQL / MySQL / MSSQL (⭐user P3, driver test harness) ◑

**Why (user, 2026-07-22):** YCSB is the best DRIVER test — one workload exercises a driver's whole surface end
to end against a REAL server: connect, auth, DDL, parameterized statements, typed encode/decode across every
column type, batching, range scans, and error paths. Unit tests miss protocol/codec bugs; YCSB (a behavioural
test, not mocks) catches them — it already surfaced the BTreeDB driver leaks in D4. Running the SAME A–F
workloads across engines also yields an apples-to-apples correctness + performance matrix.

**Design:** refactor the D4 YCSB core to run against **any** `db.Driver`/`db.Connection` — parameterize the
harness by driver instead of hard-coding BTreeDB — then instantiate it for PostgreSQL, MySQL, and (once D2
lands) MSSQL. Each run: load phase → transaction phase (A–F), typed reads validated, latency/throughput
reported. The refactor is itself a proof the DB abstraction is real (same code, swapped driver).

**Scope note:** YCSB is CRUD+scan-shaped, so it does NOT cover driver-specific features (LISTEN/NOTIFY, COPY,
MSSQL bulk insert / `TVP`, Mongo aggregation) — pair it with a small per-driver feature-conformance suite for
those. YCSB is the PRIMARY driver test, not the only one.

**What landed (2026-07-22) — driver-generic core + two live engines:**
- **`repro/ycsb/ycsb_core.nova`** — the whole A–F suite factored onto a `db.Connection` + portable SQL, exposed
  as `runSuite(engineName, conn, createTableSql, records, ops, theta)`. The D4 benchmark's `Bench` already ran on
  the seam; this lifts the connect/schema/load/run driver out of it so ONE implementation drives every engine.
- **Thin per-driver runners** — `ycsb_btree.nova`, `ycsb_postgres.nova`, `ycsb_mysql.nova`: each connects with its
  driver + DSN and passes the engine's CREATE-TABLE dialect (Postgres/BTree `TEXT PK`; MySQL `VARCHAR(64) PK`).
- **Verified live against THREE engines by swapping only the driver** (proves the abstraction is real; same
  `runSuite`, same workload code, different `Driver`):
  - **BTreeDB** — A 26.9K / B 26.6K / C 23.1K / D 29.0K / E 19.2K / F 17.3K ops/sec.
  - **PostgreSQL** — A 10.5K / B 18.5K / C 20.0K / D 18.3K / E 1.9K / F 7.9K ops/sec (trust auth; `E` scans slow
    without an index, as expected).
  - **MySQL 9** — A 16.8K / B 15.2K / C 19.4K / D 15.7K / E 10.3K / F 11.2K ops/sec (caching_sha2, fast-auth).
  - **MSSQL (SQL Server 2022)** — LOAD 692 / A 1.15K / B 2.62K / C 2.23K / D 1.62K / E 0.93K / F 0.95K ops/sec
    (`ycsb_mssql.nova`, SQL auth). Slower than the others: every statement is a full SQLBatch TDS round-trip
    (COLMETADATA + token stream) with no prepared statements/batching, and SQL Server autocommit fsyncs per
    INSERT. ARC clean under the full A–F workload (the driver leak test). The scan (E) uses the MSSQL dialect
    `SELECT TOP n … ORDER BY` (no `LIMIT`) via `runSuite`'s new `scanTop` flag — a portable-SQL exception the
    driver-generic core now parameterizes. `import mssql` alias added in main.zig.
- **Enabling MySQL driver fixes (D1 also, see below):** MySQL 8/9 sends **AuthSwitchRequest (0xfe)** after the
  handshake response (fresh salt + plugin) — the driver now re-scrambles against it and replies; plus empty-
  password → empty scramble, and caching_sha2 fast-auth-success (`AuthMoreData 0x01 0x03` → consume the trailing
  OK). Without this, auth silently desynced and every command spuriously "OK"d while nothing executed. Also fixed
  the driver's live-path ARC leaks (MyReader 64KB buffer via a `delete()` destructor; packet payload via
  bind-`as string` — same class as the BtReader fixes). MySQL query/scan return correct rows, ARC + ASAN clean.

**Remaining:** [x] driver-generic core; [x] BTreeDB live; [x] PostgreSQL live; [x] **MySQL live**; [x] **MSSQL
live** (D2 landed); [ ] a persisted cross-driver table + per-driver feature smoke (non-CRUD). Note: `query`
typed-row VALIDATION is light here (throughput focus) — pair with the drivers' own codec gates. **Deps:** D2 ✅.
**Tracking:** ✅ 2026-07-22 · `repro/ycsb/` driver-generic; **ALL FOUR engines (BTreeDB + PostgreSQL + MySQL +
MSSQL) live-verified** by swapping only the `Driver` — the abstraction is real.

## D5b — Concurrency-scaling benchmark (multi-process load generator) ⭐

**Why:** the single-threaded YCSB numbers say nothing about how an engine behaves under CONCURRENT clients —
the real production question (and the one that decides the "is BTreeDB fast enough" debate). The drivers'
`readAll` is a synchronous blocking `recv`, so in-process `spawn` would need one OS thread per in-flight op and
is fragile; the robust design (like pgbench/sysbench/memtier) is **multi-process**: C independent client
PROCESSES, each its own connection, all running a fixed-duration workload at once, op-counts summed → aggregate
ops/sec. `repro/ycsb/`: `ycsb_client_core.nova` (env-configured load/run modes) + `client_{btree,postgres,mysql}.nova`
(`fn main()` binaries) + `conc_scaling.sh` (loads once, sweeps C=1,2,4,…, prints aggregate + per-client + scaling).

**Findings (8-core box, 2026-07-22):**
- **⚠️ BTreeDB CRASHES under concurrent WRITES** — the 2nd concurrent writer kills the server
  (`error(wal): Failed to write WAL header during rotation: NotOpenForWriting` — a WAL-rotation race). A single
  writer is fine (~55K ops/s mixed). This is machine-independent, reproducible, and a hard production blocker:
  BTreeDB cannot currently serve concurrent writers at all. **This reframes the "2× faster than Postgres" story
  — the single-threaded speed is moot until concurrent writes are safe.** (Tracks the readiness note's global
  `db.rw_lock` / ~5-thread ceiling, but the failure mode is a CRASH, not a plateau.)
- **Read-only scaling is machine-bound here, not cleanly engine-bound** — BTreeDB and PostgreSQL BOTH plateau at
  ~3.2–3.6× (BTree ~105K, PG ~74K ops/s) around C=4–8. Since both hit the wall at the same place on an 8-core box,
  that plateau is the **heavy Nova clients + server competing for 8 cores**, NOT each engine's internal lock —
  can't attribute BTreeDB's read plateau to the rw_lock without lighter clients or a separate load machine.
  Honest read: read-concurrency is inconclusive on this single-box setup; the WRITE crash is the real result.
- **PostgreSQL handles concurrent writes fine** — mixed 50/50 scales to 4.5×+ at C=16 and keeps climbing, never
  crashes. The contrast with BTreeDB's write crash is the headline.

**Driver hardening the benchmark forced (real bugs):** the BTreeDB/PostgreSQL drivers' `readFrame` did
`bytes.alloc(len - 4)` with NO sanity check — when a server crashes mid-stream and sends a partial/corrupt
frame, `plen` goes negative or multi-GB → **client SIGSEGV**. Added a guard (`plen < 0 || plen > 64MB` →
treat as broken connection, return the -1 frame callers already handle). A DB client must never segfault on a
dead socket. (MySQL's u24 length is self-bounding, already safe.)

**Remaining:** the read-scaling measurement needs lighter clients (or a separate load box) to decouple client
CPU from engine concurrency; and BTreeDB's WAL-rotation-under-concurrent-writes crash is a btree-side fix.
**Tracking:** ⭐ 2026-07-22 · `repro/ycsb/conc_scaling.sh` + `client_*.nova`; found the BTreeDB concurrent-write
crash + hardened two drivers against dead-socket segfaults.

> **BTreeDB is PARKED (separate project).** The concurrency crash + the go-forward engine plan (Phase 1 stop-
> the-crash: WAL mutex + BgWriter under the DB lock; Phase 2 lightweight latches + group-commit WAL for write
> concurrency; Phase 3 multi-model SQL **and** NoSQL/document) are documented in **`btree/execution-plan-btree.md`**.
> Not a Nova-language task — Nova's driver + benchmark harness are done and hardened. This plan resumes NOVA work.

## D6 — Driver hardening & completeness (found under concurrent load, 2026-07-22) ✅

The D5b concurrency benchmark exercised the PostgreSQL / MySQL / BTreeDB drivers far harder than the codec
gates did, and surfaced real robustness + completeness gaps. **Fixed** ones are recorded so they don't regress;
**open** ones are the remaining driver work — the drivers today are single-connection, blocking, synchronous
clients that are fine for a benchmark or a simple app but not yet production-grade under concurrency.

**Fixed this session (regression-guard here):**
- [x] **Dead-socket SIGSEGV (Postgres + BTreeDB).** `readFrame` did `bytes.alloc(len - 4)` with no bounds
      check — when a server crashed mid-stream and sent a partial/corrupt frame, `plen` went negative or
      multi-GB → **client segfault**. Guarded (`plen < 0 || plen > 64 MB` → treat as broken connection). A DB
      client must never segfault on a dead socket. (MySQL's u24 length is self-bounding — already safe.)
- [x] **MySQL caching_sha2 handshake (MySQL 8/9).** AuthSwitchRequest (fresh salt) re-scramble; empty-password →
      empty scramble; fast-auth-success (`AuthMoreData 0x01 0x03`). Without these, auth silently desynced and
      every command spuriously "OK"d. (D1/D5.)
- [x] **Live-path ARC leaks** (MyReader 64 KB buffer + per-packet payload; BtReader earlier). ARC + ASAN clean.
- [x] **Timeouts / cancellation (connect + per-op).** Two runtime primitives — `nova_socket_connect_timeout(host,
      port, ms)` (non-blocking connect + `select` deadline; restores blocking mode on success) and
      `nova_socket_set_timeout(fd, ms)` (SO_RCVTIMEO/SO_SNDTIMEO) — surfaced as `TcpClient.connectTimeout` /
      `TcpStream.setTimeout` and, at the seam, `Connection.setTimeout(ms)` (a new trait method, implemented by all
      four drivers). Every driver's `connect` now uses a **10 s connect deadline** by default (a black-hole host
      returns fd -1 in ~ms instead of hanging ~75 s), and an app bounds per-op I/O with `conn.setTimeout(ms)` so a
      hung-but-not-closed server returns instead of blocking forever. Verified: black-hole connect bounded to
      ~305 ms; live PG connect+`setTimeout(30000)`+query still returns rows. (commit `f6650c3`)

- [x] **Connection pooling.** `data/sql/pool.nova` — a driver-generic `Pool` over the `Driver`/`Connection`
      seam: `acquire()` reuses a warm idle connection (LIFO) or opens a new one; `release(c)` returns it (or
      closes the surplus past `maxIdle`); `closeAll()` drains at shutdown; `opened`/`live`/`idle` diagnostics.
      Programs against the traits, so the same pool serves BTreeDB/PG/MySQL/MSSQL by swapping the driver. Reuse
      avoids paying the connect+auth handshake per request — what the async web app needs. Verified: live PG
      acquire→query→release→**reuse** (opened stays 1), concurrent checkout opens a 2nd, `closeAll` drains; a
      counting-mock gate (`104_conn_pool`, 9 assertions) proves the semantics offline. ARC+ASAN clean.
      (commit `bcf7775`)

- [x] **Prepared statements (handle-based seam API).** `Connection` gains `prepare(sql) -> int` +
      `queryPrepared`/`execPrepared(handle, params)` (handle-based so no connection alias escapes into a
      statement object — all state stays on the connection; per-connection cache, deduped by SQL). **PostgreSQL:
      real server-side extended query** — Parse+Describe once (caching the assigned name + RowDescription
      columns, which Execute never resends), then Bind (text-format params) + Execute + Sync per run; the server
      parses/plans a given SQL a single time. The other three drivers (MySQL/BTreeDB/MSSQL) + mocks get an
      **emulated fallback** (client-side `$N` substitution via their own `query`/`exec` — same API +
      injection-safety, no server-side plan cache); real MySQL `COM_STMT_*` / MSSQL `sp_prepare` are follow-ons.
      Verified live: PG prepare→queryPrepared with two different param sets, dedup (same SQL → same handle, no
      round-trip), and a quote-bearing param bound literally (injection-safe); MySQL emulated path live too.
      Gate `105_prepared_statements` (11 assertions: PG Parse/Bind/Describe/Execute/Sync frame shapes offline +
      the emulated seam contract — param threading, dedup, out-of-range handle, exec count). ARC+ASAN clean.
      (commit `9a51aa2`)

- [x] **Circuit-breaker resilience (ResilientPool).** Timeouts stop one call hanging, but a DB that is DOWN still
      gets hammered — every request pays the full connect+timeout. Extracted the pure `CircuitBreaker` state
      machine to `resilience/breaker.nova` (datetime-only, so the DB layer shares it without pulling the web
      client stack), and added `ResilientPool` = `Pool` + breaker to `data/sql/pool.nova`. Every query/exec
      fast-fails with a `CIRCUIT_OPEN` tag while OPEN (backend untouched); a failing call DISCARDS its connection
      (new `Pool.discard` — a dead socket must not re-enter the idle set); after the cooldown a probe reopens the
      path (HALF_OPEN → CLOSED). Failure read from the empty command tag drivers leave on a broken connection.
      Gate `106_resilient_pool` (10 assertions: opens after threshold, fast-fails without touching the backend,
      half-open recovery, failed-probe reopen, exec guarded). ARC+ASAN clean. (commit `6aed1c7`)

- [x] **PostgreSQL SCRAM-SHA-256 auth.** The pg driver did only cleartext/trust; a server requiring
      `scram-sha-256` (the PostgreSQL default for password auth since v14) could not be reached. Now speaks the
      full `AuthenticationSASL`→`SASLContinue`→`SASLFinal` exchange via the RFC 7677-verified `ScramClient` (C1);
      new `buildSASLInitial`/`buildSASLResponse` builders; client nonce from the CSPRNG builtin `nova_random_hex`.
      **Verified LIVE against PostgreSQL 18** (scram-password role behind a user-specific pg_hba line, connected +
      queried, then reverted). Gate `107_pg_scram_auth` (offline SASL frame shapes + RFC 7677 client-first/final).
      ARC+ASAN clean. (commit `8b6922f`)

- [x] **MySQL caching_sha2 FULL auth (uncached password).** New runtime `nova_rsa_oaep_encrypt` (crypto.cpp:
      PEM → DER via Base64_Decode → `wc_RsaPublicKeyDecode`, then `wc_RsaPublicEncrypt_ex` with
      WC_RSA_OAEP_PAD/SHA-1/MGF1-SHA1 = MySQL's RSA_PKCS1_OAEP_PADDING). On AuthMoreData 0x04 the driver requests
      the server's public key (0x02), XORs (password+NUL) with the nonce cyclically, RSA-OAEP-encrypts, and sends
      it. **Verified LIVE against MySQL 9.7** with an uncached caching_sha2 user (first connect forced full auth);
      fast-auth + no-password paths still work. Gate `108_mysql_rsa_auth`. (commit `0058512`)
- [x] **Real server-side prepared statements — MySQL** (`COM_STMT_PREPARE`/`EXECUTE`, binary protocol incl. the
      full BINARY row decoder: null bitmap, two's-complement signed ints, IEEE FLOAT/DOUBLE via new
      `nova_ieee_le_to_str`, lenenc decimals/strings, binary date/time). Live vs MySQL 9.7; gate
      `109_mysql_binary_protocol`; caught + fixed a real 1-byte/execute null-bitmap leak. (commit `b57b12f`)
      **and MSSQL** (`sp_prepare`/`sp_execute` over TDS RPC, `$N`→`@PN`, NVARCHAR-bound params, RETURNVALUE handle
      parse). En route fixed a real PRE-EXISTING bug: SQL Server sends NBCROW (0xD2) for any row with NULLs, which
      the decoder ignored → every NULL-bearing query (plain OR prepared) decoded as 0 rows. Live vs SQL Server
      2022; gate `110_mssql_prepared`. (commit `6603d21`)

**Open — an A1-scoped seam redesign, NOT a D6 driver gap:**
- [ ] **Async socket path in the drivers.** Timeouts are bounded, but `readAll` is still a *blocking* `recv`. Making
      it non-blocking is not a driver tweak — the whole read chain (query → readMessage → fill → recv) and the
      seam's `query`/`exec` trait methods would become `async fn` (returning futures), rippling through every DB
      consumer. That is an **async-first redesign of the `Connection` trait**, which belongs to A1 (async
      ergonomics), not D6 hardening. Deferred to A1 by scope, not left undone.

**Deps:** SCRAM wiring depended on C1 (done); TLS-in-handshake shared with D2 (MSSQL). **Tracking:** ✅ 2026-07-23
· dead-socket + ARC + **timeouts** + **connection pooling** + **circuit-breaker resilience** + **all auth**
(MySQL native/caching_sha2 fast **and RSA full-auth**, **PG SCRAM-SHA-256**) + **real server-side prepared
statements on ALL FOUR engines** (PG extended-query, MySQL COM_STMT binary, MSSQL sp_prepare RPC; BTreeDB
emulated over its own protocol) all landed + live-verified. D6 driver hardening + completeness is DONE. The one
remaining item (non-blocking async recv) is an async-first redesign of the `Connection` seam — A1 scope, not a
D6 gap. En route also fixed two real pre-existing bugs (MySQL null-bitmap leak, MSSQL NBCROW NULL-row decode).

---

# E1 — Error model `T | Error` (P4, route §8.C)

**Spec-first** (rewrite `specs.md`/`language-specification.md` §5.5 before implementing). **Design:** Zig-shaped
`!T`-style union + `try` (propagate) + `catch` as an expression + `errdefer`; error side is an ordinary tagged
enum with payloads consumed by `switch`. Representation: **two-register return** `{i64 tag, i64 payload}`
(AArch64/x86-64 return 16-byte aggregates in registers — zero heap traffic), which **also** fixes tuples
properly (§8.D6). Remove the broken `throw` longjmp. Fold in the enum-payload-on-a-local fix (§8.E1) and the
tuple type-checker half (§8.D1/2/4). **DoD:** spec section landed; gates `error_union_try`, `error_union_catch`,
`errdefer`, enum-payload-on-local; `throw` removed; full suite + ASAN green. **Deps:** two-register return
codegen (shared with tuples). **Tracking:** ✅ 2026-07-22 · spec §3.5 + gates `32`/`33`/`45`/`101_errdefer` +
`errunion_unguarded`/`throw_removed`/`try_catch_removed`.
**Landed:** `try` (propagate), `catch h` / `catch (e) h` (expression handler binding the error), unguarded
`.field` on `T|E` = located typecheck error, `throw` removed. **`errdefer` DONE this session** — a new keyword
(lexer/parser) + `DeferStmt.is_err` + a per-scope `errdeferred_statements` list run by `runErrdefers` at BOTH
error-return sites: the explicit error-side `return` (`statements.zig`, gated on `is_err`) and a `try` that
propagates (`expressions.zig` prop block); LIFO across the active scope stack, before locals drain; discarded on
a normal scope exit. Gate `101_errdefer` (fires-on-error / skipped-on-ok / fires-on-try-propagation / LIFO),
ASAN+ARC clean. **Deferred optimization (NOT a correctness gap):** the **two-register return** `{i64 tag, i64
payload}` — error unions (and tuples) currently return a HEAP BOX `[tag, payload]`, which is correct and ARC-clean;
§3.4b records the zero-alloc two-register form as a perf optimization for later (also improves tuples). Corpus
125/125 functional, 226/226 ASAN.

# A1 — async utilities + actor layer (P4) ◑

**Design:** on the existing runtime substrate, add `when_all`, `parallel_for`, `select`, timeouts; then an
actor stdlib layer over channels + coroutines. API/ergonomics, not new runtime. **DoD:** gates `async_when_all`,
`async_parallel_for`; actor example gated. **Deps:** runtime (done).

**Async error model — DECIDED (specs §7 OPEN DECISION 3 resolved):** an `async fn` returns `T | E` (a normal
E1 error union); `await` yields `T|E`, handled with `try`/`catch`. ONE error model for sync and async, no second
mechanism. (E1 landed — see above.)

**LANDED (2026-07-22) — `future<T>` first-class (commit `e645bb7`):** the type lowerer maps `future<T>` → the
`.future` store type (like `Storage<T>`), so a future — a scheduler-managed i64 coroutine handle, ARC-non-owned —
is storable in `List<future<T>>`, passable, and awaitable out of a container. This is the enabling keystone for
concurrent fan-out (spawn N, collect futures, await each). Gate `102_future_first_class`, ARC+ASAN clean.

**LANDED (2026-07-22) — `when_all`/`parallel_for` fan-out/join (commit `bdf60f2`):** `concurrency/async_util.nova`
ships `when_all<T>`, `wait_all<T>`, `when_first_n<T>` — the fan-out/join layer over `spawn`/`await`. The
spawn-loop + `when_all` IS the parallel-map / parallel-for pattern (launch N tasks concurrently, collect results
in order). Gate `103_async_when_all` (8 assertions: ordered collect, sum, bounded join, mixed fanout), ARC+ASAN
clean.
- **Root cause that was blocking it (single fix, not three):** `awaitedCallHandle` (expressions.zig) only ramped
  a bare-ident `.call`. `await async_util.when_all<int>(fs)` is a `.generic_call` with a *field_access* callee
  whose emitted symbol is the full module path (`concurrency_async_util_when_all`); it fell through to the
  "await a handle" path (assumes already scheduled) → runtime "lost wakeup." The generic free call resolves to
  the erased BASE async fn — which IS already in `async_fns` — so only the ramp needed teaching about
  `.generic_call` + module-qualified callees (resolve the async symbol via the same `<obj>_<field>` suffix scan
  the main call path uses, then schedule). The earlier "3 root causes" collapsed to one: the base is registered
  and driven; no per-mono `async_fns` entry was needed.

**Known limitation (documented in gate 103):** generic FREE-function bodies are still type-ERASED (F4 call-site
mono-routing gap — see F4/M3 in the mono notes), so inside `when_all<T>` a `List<T>.get` uses a 0 = null optional
sentinel — a genuine value of 0 reads back as null. General to every generic free function (a non-async
`fn idlist<T>` shows the same), NOT an async defect. Fixing it = monomorphizing generic free functions (F4).

**REMAINING:** `type_checker.resolveExprType` still doesn't substitute a generic call's type args into its return,
so an explicit `let f: future<int> = spawn genericAsync<int>(…)` returning a bare `T` can misread (does NOT block
`when_all`/`parallel_for`, which return `List<T>` and skip the check). **`select`/timeouts/actor layer** remain
(need a runtime timer + select-over-futures primitive). **Tracking:** ◑ 2026-07-22 — future<T> first-class +
when_all/parallel_for done; generic-return type_checker substitution + select/timeouts/actors remain.

# S1 — serde completeness (P4) — ✅ DONE

**Design:** decimal fields in JSON/YAML encode/decode (the substantive scope). **DoD:** decimal round-trips
through JSON+YAML — via BOTH the manual `JsonValue`/`YamlValue` API AND `@serializable` structs; gates green;
full suite green. **Deps:** S4 (decimal parse) — done. **Tracking:** ✅ 2026-07-22 · gates `96_serde_decimal_json`,
`97_serde_decimal_yaml`, `98_serde_json_yaml_coimport`, `99_serde_struct_decimal` · commits `92b507f`, `9d7553a`,
`0f41faa`.

**Landed:**
- **Manual API** — JSON numbers are stored as raw text, so a decimal round-trips exactly: `json.decimalValue(d)`
  + `json.asDecimal(v)` (parses the number text via `decimal.fromString`). YAML got a new
  `YamlValue.Decimal(decimal)` variant + `yaml.decimalValue`/`yaml.asDecimal`; the parser routes a fractional/
  exponent scalar (`isDecimalNumeric`) to Decimal while a bare integer stays `Number`.
- **`@serializable` structs** — `ValueSource` gained `getDecimal`/`itemDecimal` (all four sources); the
  compiler-generated binders route a `decimal` field/element to them (was the lossy `getFloat`, and `__toJson`
  SKIPPED it) and `__toJson` emits it as an unquoted JSON number via `${}` (exact BID, no f64 hop). Gate `99`.
- En route fixed a compiler bug: `optionalDecimal == undefined` hit `UnsupportedBinaryOp` (the decimal-arith block
  treated the `undefined` literal as a mixed operand) — now a null/undefined literal falls through to the pointer
  null-check, like the string path. Also fixed two pre-existing yaml bugs (see `SERDE-YAML-BUGS`).

**Scope decision (2026-07-22):** the original DoD listed "F4-6 removes the source-gen+reparse". That work is
**relocated to T6 Phase 1b** (separate compilation) — it is behavior-neutral and its only payoff (one-file-edit
incrementality) lands *with* per-unit compilation, so doing it speculatively ahead of T6-1b is pure churn (and the
riskiest part, the mediator dispatch generator, gains nothing). S1 is DONE on its substantive scope; the reparse
removal is tracked under **T6 → Phase 1b → F4-6** below. **Streaming parse** was a design-blurb stretch, never in
the DoD — deferred as a separate future enhancement (not an S1 gap). Corpus 123/123 functional, 222/222 ASAN.

### SERDE-YAML-BUGS — BOTH FIXED (2026-07-22, gate `98_serde_json_yaml_coimport`)
Gate 97 was the FIRST conformance case to `import serde.yaml`, exposing two latent bugs (both reproduced on a
clean tree, no decimal involved). NOT destructor/mono cross-contamination as first suspected — the real roots:
1. **Co-import crash — FIXED.** `str`/`number`/`object` are defined in BOTH serde.json and serde.yaml, and
   sema's bare-call return-type resolution used a GLOBAL first-match (`findFunction`), so a bare `str("x")` in
   yaml.nova was TYPED as json's `str` (return JsonValue) while codegen dispatched module-scoped to yaml's `str`
   (YamlValue). That divergence released a YamlValue temp through `__destruct_JsonValue` (a co-import BUS). Fix
   (`src/sema/infer.zig`): resolve a bare call's function MODULE-SCOPED first (`findFunctionIn(current_module,…)`),
   matching codegen's dispatch.
2. **Nested-enum leak — FIXED (three ARC fixes).** (a) A `switch`-case destructure (`case Arr(dummy)`) RETAINED
   the owned payload but relied on function-exit release; in a LOOP the alloca is overwritten each iteration, so
   every iteration but the last leaked its retained payload. Fix (`statements.zig`): release the retained payload
   at case-body exit (the earlier alloca-nulling in `releaseLocalByName` makes the function-exit drain a safe
   no-op). This was the main leak. (b) A payload-less enum-variant construction `V.Null` PARSES as `.field_access`
   so the `let`-binding co-own retain treated it as a borrow → over-retain leak; excluded enum-variant ctors from
   `is_r_var` (`statements.zig`). (c) Same construction was `.borrowed` in `principledDisposition` so an inline
   `x != V.Null` never registered the box as a drainable temp; now recognized as a producer (`arc.zig`).
**Verified:** yaml module ARC-clean, gate 98 (co-import + nested roundtrip) ASAN+ARC clean, gate 97 re-baselined
5→0. Corpus 122/122 functional, 220/220 ASAN.

# S2 — regex engine (P4/Tier3)

**Design:** a bytecode-VM regex: pattern → flat instruction program with RELATIVE jump offsets (sub-programs
splice trivially) → BACKTRACKING VM. `src/std/text/regex.nova`. Features: literals, `.`, classes `[...]`/`[^...]`
with ranges + `\d\w\s\D\W\S`, quantifiers `*+?` and `{n}`/`{n,}`/`{n,m}` (greedy), alternation `|`, capturing
`(...)` + non-capturing `(?:...)` groups, anchors `^`/`$`, escapes. API: `compile`/`test`/`find`/`exec`/`findAll`/
`replaceAll` (`$n` group refs in the template). **DoD:** gate `92_regex` (literals, classes, `*+?`, `{n,m}`,
groups, anchors, findAll, replace) — ASAN+ARC clean; full suite green. **Deps:** none. **Tracking:** ✅ 2026-07-22.
**Note:** backtracking (simple + correct); a linear-time Thompson/Pike VM is the eventual upgrade for pathological
patterns. En route, fixed a FOUNDATIONAL compiler bug: an early `return` inside a loop double-freed a block-scoped
owned local declared textually after the return (the function-drain released the prior iteration's freed pointer);
fixed by nulling an owned local's slot after its block-scope release. Regression gate `93_loop_early_return_arc`.

# S3 — decimal follow-ups (Tier3)

**Design:** div-by-zero policy (trap vs current 0-stub — recommend trap), explicit `int↔decimal` conversion
functions, decimal in more numeric contexts. **DoD:** gate `decimal_conv` (int↔decimal explicit, div-by-zero
traps). **Deps:** none. **Tracking:** ✅ 2026-07-22 (gate `94_decimal_conv`).
**Landed:** (1) divide- AND modulo-by-zero now TRAP loudly (`nova: panic`, _Exit(134)) via a new
`nova_panic_cstr` C-string runtime abort (core.cpp) — the silent `0`-stub returned a wrong answer.
(2) `decimal.fromInt(n)` / `decimal.toInt(d)` — a new `decimal` builtin namespace (sema/builtins.zig table +
codegen dispatch + `nova_decimal_from_int`/`nova_decimal_to_int` runtime). `toInt` truncates toward zero and
TRAPS on out-of-i64 range (no silent wrap). `isFatalUnresolvedIdent` now exempts any builtin-table receiver so
`decimal.*` isn't flagged undefined. Corpus 118/118 functional, 212/212 ASAN. **Deferred (not S3):** the
`let x: decimal = <decimal arith>` annotation path mis-types (works un-annotated / inline `${}`); decimal in
more numeric contexts (mixed int/decimal expr) still needs the no-implicit-coercion story extended.

# S4 — text→decimal128 parser (shared dependency)

**Problem.** No `string → decimal128` exists, so DB `numeric`/`DECIMAL` columns come back as text, not exact
decimals (open across BTreeDB, Postgres, MySQL, and BSON/JSON serde). **Design:** parse a decimal string
(sign, integer, fraction, exponent) into the 128-bit BID representation, round-half-even to 34 digits —
mirror the existing decimal literal path. Runtime primitive `nova_decimal_from_string` (or Nova-side).
**DoD:** KAT `decimal_parse` (`"3.14"`, `"-0.1"`, `"1e10"`, edge exponents) exact; DB drivers switch numeric
columns to real `DbValue.dec`. **Deps:** none — **unblocks exact decimal everywhere**. **Tracking:** ✅ 2026-07-22
(gate `95_decimal_parse`).
**Landed:** `decimal.fromString(s: string): decimal` — a new entry in the `decimal` builtin namespace routing
to the existing BID parser `nova_decimal_from_string` (Nova strings are NUL-terminated and decimal text is pure
ASCII, so the runtime pointer is C-compatible — no length-aware variant needed). Handles sign / integer / fraction
/ `e`/`E` exponents, round-half-even to 34 digits, exact (no f64 hop). **Consumer switch:** `decodeCell` in all
three SQL drivers (`postgres`/`mysql`/`btreedb`) now build `DbValue(Decimal, …, decimal.fromString(raw), raw)` —
`asDecimal()` is exact while `asText()` still returns the raw text. Gate 95 also asserts the driver path via the
public `db.dbDecimal(decimal.fromString(...))` seam. Corpus 119/119 functional, 214/214 ASAN clean.

---

# T1 — Toolchain self-sufficiency (remaining) (P5)

**State:** static LLVM + in-process LLD (native+wasm) landed. **Remaining design:** bundle macOS `.tbd` SDK
stubs (drop the CLT/Xcode SDK path lookup); build the C++20 runtime with the bundled toolchain; ELF/Linux link
path (+ musl + CRT). **Invariant:** users deploy only `nova`. **DoD:** a machine with no Xcode/CLT builds+runs
a nova native binary; Linux/ELF path builds+runs. **Deps:** none. **Tracking:** _pending (◑)_

# T2 — WASM pointer-width audit (P5)

**Problem.** Modules compile+link (52/74) but produce **garbage pointers at runtime** — `val_type` is i64 for
f64, but wasm pointers are 32-bit and `inttoptr`/`ptrtoint`/load-store don't consistently truncate/extend.
**Design:** audit every ptr↔int conversion in codegen for wasm; ensure 32-bit pointer semantics under the i64
value slot. **DoD:** `--wasm-run` gate — the 52 compiling cases **run correctly** (StringBuilder returns a real
string, not `0x20_0000_001F`); baseline ratcheted. **Deps:** none. **Tracking:** _pending_

# T3 — FFI (⭐P2 — promoted; keystone for W1/W2/W3)

**Why now.** FFI is no longer a "someday P5" — it is the **keystone** for the product surface the user just
requested: the **webview (W1)** binds a native webview lib; **`useStatic` (W2)** and the **outbound circuit
breaker (W3)** can *bind* the proven Zig implementations in `~/plancksystems` (LRU cache 430 lines, static
content store 134 lines, circuit breaker 109 lines) instead of re-porting ~670 lines into Nova. Do FFI first
and the rest become thin Nova wrappers over battle-tested code.

**Design:** `extern("lib") fn name(args): ret;` — C-ABI marshalling (Nova types ↔ C types), ownership boundary
rules (who frees across the seam — reuse the ARC/heap-header discipline from `nova-runtime-abi-seam`),
dlopen/link the named lib. The Zig deps expose C-ABI entry points (or a thin `extern "C"` shim per lib).
Enables embedding wasmtime, using system libs, and the W-items below.

**Ratified surface (2026-07-21):** `extern("lib") fn name(params): ret;` — per-decl library name; the linker
adds `-l<lib>` (system + default `-L` search paths). `spawn`-style soft-keyword: `name` is the bare C symbol,
no mangling.

**DoD:**
- [x] Parse `extern("lib") fn sig;` (bodiless); lexer `extern` keyword; AST `FunctionDecl.extern_lib`.
- [x] Codegen emits an LLVM external with a C-mapped signature; reuses runtime-shared symbols (no `malloc.57`).
- [x] Linker collects distinct libs → `-l<lib>` on native (in-process LLD + clang) and `nova test` paths.
- [x] Marshal **scalars** (int→i32, long→i64, bool→i8) + **ptr** + **void** — boundary casts via buildCallWithCasts.
- [x] Marshal **string** both directions (Nova↔C `char*`: arg→NUL-term temp then freed; return→copied Nova string).
- [x] **struct-by-pointer** — Nova struct value (heap ptr, C-compatible layout) passes as `void*`.
- [x] Gate `82_ffi_extern` (libc abs/labs/malloc/memset/free/strlen/getenv/memcmp); corpus 104/104; ARC + ASAN clean.

**Status: ✅ v1 COMPLETE.** Only **float/double** marshalling deferred (maps to i64 today; FP must not yet
cross FFI — a small follow-up adding FPTrunc/SIToFP at the boundary). **Deps:** linker (done).
**Tracking:** ✅ 2026-07-21 · commits `97ba8ef` (stage 1: scalars/ptr/void) `1e31ad1` (stage 2/3: string +
struct) · gate `82_ffi_extern` · unblocks W1/W2/W3.

# T4 — Tooling: LSP, `nova fmt`, package manager (P5/6) ◑

**Design:** mature the LSP (diagnostics, hover, go-to-def, completion on the real type info); `nova fmt` (the
formatter exists — wire a CLI + idempotence gate); a package manager (module resolution, a manifest, fetch).

**What landed (2026-07-21, `4e4571c`) — `nova fmt` made NON-DESTRUCTIVE:**
- Fixed real formatter corruption bugs: `extern("lib") fn` was rewritten to an empty `fn {}`, `async` was
  dropped, and `struct Pair<A,B>` / `fn map<T>` lost their type params. Now emitted correctly (generics from
  the AST, not a source-span scrape); `pub` emitted instead of `export`.
- **Non-destructive guard:** `formatFile` compares the meaningful TOKEN STREAM of the output to the original
  and only writes when identical — otherwise it SKIPS the file (reports it) and leaves it byte-unchanged. So
  `nova fmt` can never corrupt code. Gate `conformance/fmt-check.sh`: wrote=44 skipped=41 **corruptions=0**.
- `nova get <git-url>` (package manager — clones a dep into `~/.nova/cache`) and the `nls` LSP already exist.

**What landed (2026-07-22) — LSP made FULLY FUNCTIONAL:**
The `nls` server was a stub: completion returned two hard-coded strings, hover only covered top-level fns/structs,
and it did not even compile against the current AST (`TypeRef` had gained `error_union`). It now provides a
genuinely useful IDE experience, all verified end-to-end by driving the real `nls` binary over LSP stdio (two
Python harnesses) plus 7 in-tree unit tests:
- **Completion** — context-aware. `receiver.` → the receiver's fields + methods, resolved through a lightweight
  local type environment (params, `let` bindings, `self`, and **call-return inference** so `let c = Conn.open();
  c.` offers `Conn`'s members, not a global soup). `Type.` → static methods + enum variants. Bare identifier →
  in-scope locals (sorted first), top-level fns/structs/enums/consts/traits, imports, primitive types, keywords.
  The buffer is repaired (cursor line blanked, braces kept) when mid-edit code won't parse, with a `parseBest`
  that prefers the real parse so already-valid buffers aren't degraded.
- **Hover** — functions, methods, structs, enums, enum variants, consts, traits, struct fields, **locals/params**,
  and builtin type keywords; each with its `///` doc comment.
- **Go-to-definition** — top-level decls, methods, fields, variants, and **locals** (jumps to the declaration,
  not the use), with precise name ranges, across all open files.
- **Document symbols** — a nested outline (struct → fields+methods, enum → variants+methods) with correct
  `SymbolKind`s (static methods render as Function, instance as Method).
- **Signature help** — parameter hints with active-parameter tracking for free functions and static/instance
  methods.
- **Root parser fix (the enabling change):** enum/const/let/struct/field/variant spans were built from the
  TRAILING `self.span()`, so `.span.start` pointed at the *next* token — useless for anchoring hover docs and
  go-to-def. Now they capture the start span (mirroring `parseFunctionDecl`). Compiler test baseline, conformance
  (108/108), and `fmt-check.sh` (0 corruptions) all unchanged by it. `nls`: `analysis.zig` (semantic core, unit-
  tested) + a rewritten `server.zig`.

**What landed (2026-07-22) — package manager made manifest-driven:**
`nova get` was git-clone-only and fetched deps were **unusable** (nothing resolved `import <dep>` against them).
Now:
- **`nova get` (no URL)** restores every dependency in `project.json` into `~/.nova/cache/<repo>/` (idempotent —
  a present cache dir is a hit, no re-clone/clobber). **`nova get <url>`** clones + records it in the manifest.
- **Import resolution** searches each cached package's `src/<module>.nova` (then its root) — so the manifest
  drives *fetching* and the cache drives *resolution* (the resolver needs no manifest parse).
- Verified e2e by a **2-package example** (`conformance/pkg-manager-check.sh`): a `mathlib` library package + a
  `consumer` that depends on it — restore → resolve → `nova test` passes using symbols that exist ONLY in the
  fetched package → the consumer's `main` also compiles to a native binary and runs. Corpus 108/108 unchanged.

**What landed (2026-07-22) — `nova fmt` made COMMENT-PRESERVING + wider coverage:**
The formatter silently **deleted every comment** on write (the guard compared only CODE tokens, so comment loss
passed it — active data loss on real files). Now:
- **Comment re-injection.** After the AST format, `reinjectComments` splices the source's `//` comments back
  into the identical code-token stream — as a trailing `// …` on the previous token's line, or standalone at the
  next token's indentation. Needed a 1-line lexer change (`tok_start`: punctuation lexemes are static literals,
  so their offset can't come from the lexeme pointer). Verified comment-preserving + **idempotent** across all
  53 written corpus files.
- **Fixed construct round-trip bugs** that made the guard skip: template strings (backtick + `${…}`, was `"…"` +
  `{…}`), the invalid invented `static ` keyword (Nova infers static from no-`self`), **for-in loops** (`for (x
  in xs)` was emitted as an empty C-style header), braceless single-statement `if`/branches, and generic-trait
  type params (`trait T<Q, R>`). Coverage rose **44 → 53** of 85 checked files, still **0 corruptions**.
- Gate `fmt-check.sh` now also asserts comment preservation + idempotence. `NOVA_FMT_DEBUG=1` prints the first
  token divergence for any skipped file.

**Remaining (why ◑, not ✅):**
- [x] `nova fmt` CLI + non-destructive gate.
- [x] **LSP maturity: completion / hover / go-to-def / document-symbols / signature-help** — done 2026-07-22.
- [x] **Package manager: manifest-driven resolution of a 2-package example** — done 2026-07-22
      (`pkg-manager-check.sh`).
- [x] **`nova fmt` comment preservation + idempotence** — done 2026-07-22 (data-loss bug fixed).
- [ ] `nova fmt` **remaining construct coverage** — 32/85 corpus files still SKIP (left byte-unchanged, never
      corrupted) on deeper constructs: trait-widening struct inits, module-qualified generic types (`list.List<T>`
      — a parser AST limitation: the `list.` prefix isn't retained), JSX/NSX, the mediator/routing and DB-codec
      files. Also `->` vs `=>` for a function type both parse to one AST (no arrow record), so only the majority
      style round-trips. Closing these needs per-construct emit fixes (and a couple of small AST additions).
- [ ] LSP semantic diagnostics beyond the first parse error (undefined names, type errors) — would run the
      checker; left out to avoid pulling the checker's global state into the server. NOTE: a dev-machine `nls`
      re-syncing `~/.nova/std` under concurrent builds caused flaky `nextPowerOfTwo` failures — the LSP should
      not touch the shared std tree while a build reads it.
- [ ] Package manager follow-ups (nice-to-have, not blocking): version pinning / a lockfile, transitive deps.

**Deps:** F5 (module scoping). **Tracking:** ◑ 2026-07-22 · LSP FULL + package manager manifest-driven + `nova
fmt` comment-preserving/idempotent (44→53 coverage), all e2e-verified (`fmt-check.sh` + nls e2e +
`pkg-manager-check.sh`). Remaining: the fmt construct long-tail (32 skips) + LSP semantic diagnostics.

# T5 — `nova init` templates: `web` (VSA) + `desktop` (webview) (⭐P3, user-specified)

**Two templates replace `nova init app`** (user, 2026-07-21): **`nova init web`** = the vertical-slice web app
below; **`nova init desktop`** = a webview-based desktop app (W1) — `import webview;`, a `Webview` window that
renders NSX and binds Nova handlers to JS, optionally driving an in-process `App` for local data. Keep `app`
as a deprecated alias that prints a hint. `src/main.zig` `cmdInit` dispatches on the subcommand.

**Why re-do it.** The current scaffold (`src/main.zig` ~764–794, `src/templates.zig`) emits the old
`features/home/{views,services,handlers,controllers}` layer-per-type shape with `req: any` controllers. The
user specified a **vertical-slice** layout (ASP.NET VSA style) where each feature slice is self-contained.

**Target layout (user-provided, mapped to Nova):**
```
MyApp/
├── Features/                       # MAIN entry point for features
│   ├── Products/                   # feature group / aggregate root
│   │   ├── CreateProduct/          # one vertical slice = one folder
│   │   │   ├── endpoint.nova       # app.post<CreateProduct>("/products") registration
│   │   │   ├── command.nova        # @serializable CreateProduct { ... }
│   │   │   ├── handler.nova        # impl RequestHandler<CreateProduct, CreateProductResponse>
│   │   │   ├── validator.nova      # validate(cmd) -> errors
│   │   │   └── response.nova       # @serializable CreateProductResponse
│   │   ├── GetProductById/         # query slice (Query/Handler/Response)
│   │   └── views/                  # ⭐ PER-FEATURE JSX/NSX templates (user emphasis)
│   │       ├── product_card.nova
│   │       └── product_list.nova
│   └── Orders/PlaceOrder/place_order.nova   # single-file slice style (alternative)
├── Domain/
│   ├── entities/ (product.nova, order.nova)
│   └── exceptions/ (domain_exception.nova)
├── Shared/
│   ├── database/ (app_db.nova)              # DB context / connection wiring (BTreeDB driver)
│   ├── behaviors/ (validation.nova, logging.nova)   # pipeline behaviors (X1 PipelineBehavior)
│   └── middleware/ (exception_handling.nova)
├── main.nova                       # = Program.cs: DI registration + pipeline setup + app.run
└── nova.json
```
**Key points:**
- **Per-slice files**: endpoint + command|query + handler + validator + response, built on the X1 typed API
  (`app.get/post<T>`, `RequestHandler<Q,R>`, `@serializable`, `ValueSource`).
- **⭐ Per-feature `views/`** holding JSX/NSX templates — each feature owns its view templates, NOT one
  global views dir (explicit user requirement).
- **`Shared/behaviors/`** = X1 pipeline behaviors (validation, logging) wired in `main.nova`.
- `main.nova` maps to `Program.cs`: register handlers/behaviors, `app.useStatic(...)` (W2), `app.run(port)`.

**Files:** `src/templates.zig` (new template strings per slice file + per-feature view), `src/main.zig`
scaffold (replace the flat `features/home/...` writes with the VSA tree; generate a sample `Products/CreateProduct`
+ `GetProductById` slice + a per-feature view).

**DoD:**
- [x] `nova init web foo` scaffolds the VSA tree; builds native + dispatches both routes; `nova test` passes.
- [x] `nova init desktop foo` scaffolds a webview app; builds native.
- [x] `nova init console` still works; `app` is a deprecated alias → web.

**Status: ✅ COMPLETE.** Fixed two foundation bugs en route: a project-root `src/<module>` import fallback
(so a `tests/` tree can import project modules), and — significant — **`nova test` was broken for EVERY user
project** (a std module read from `~/.nova/std` took its absolute HOME path as identity, so under the
test-harness merge a stdlib free function was collected under one spelling and called under another →
`nextPowerOfTwo not found`); loadProgram now keeps the canonical `src/std/…` spelling. **Deps:** X1, W2 (done).
**Tracking:** ✅ 2026-07-21 · commit `c13fb7c`.

---

## 🏁 Product surface COMPLETE (T3 → W1 → W2 → W3 → T5)

The FFI-enabled product track is done: **T3** FFI ✅ · **W1** webview ✅ (100%) · **W2** useStatic ✅ ·
**W3** circuit breaker ✅ · **T5** init web/desktop ✅. Recurring theme: each surfaced a latent stdlib/compiler
bug that had never been exercised (nova_file_read_all `.string`→`.int` SIGSEGV, client.nova missing `cookies`,
logger's `io.file.File`, the user-project `nova test` std-identity bug) — all now fixed and gated. Corpus grew
103 → 108. Remaining open items are the non-product foundation/driver/tooling backlog (H1, H2, F1–F5, S/D).

---

# W1 — Webview in the runtime (⭐P3, user-requested) ✅ v1

**Goal.** Let a Nova app open a native desktop window rendering HTML/JS/NSX (not just serve HTTP) — a GUI
target alongside the server target.

**What landed:** vendored `webview/webview` 0.10.0 (single-header, MIT) → `deps/webview/`, built by build.zig
into `libwebview.a` (macOS Cocoa/WKWebView, ObjC++). Nova `Webview` struct (`src/std/webview.nova`) over
`extern("webview")` FFI bindings: create / setTitle / setSize / navigate / setHtml / initScript / eval / run /
terminate / delete. Linker `appendFfiLib` links the vendored `.a` by path + `-framework WebKit -framework
Cocoa` (frameworks aren't `-l`).

**DoD:**
- [x] `import webview;` → `Webview(debug)` opens/configures a window; setHtml/navigate/eval work.
- [x] Links libwebview.a + WebKit/Cocoa; all webview symbols resolve; a real WKWebView instantiates at runtime.
- [x] Builds from scratch via build.zig; corpus 105/105.
- [x] **JS→Nova callbacks** — `bind(name, handler)`: JS `window.name(args)` invokes a Nova `(string)->string`
      handler (JSON req in, JSON result out) via a C trampoline; `dispatch(task)` runs a Nova `()->void` on the
      UI thread; `unbind`. Built on `nova_invoke_str_closure` (invoke a Nova closure from C via box{fn_ptr,env}),
      headlessly gated (`83_ffi_callback`, ARC+ASAN clean).
- [x] **NSX/JSX → setHtml** — JSX renders to a Nova string; `w.setHtml(<html>…</html>)` works.
- [x] Natural idioms all work: qualified/unqualified `Webview(...)` ctor, `webview.HINT_*` const, typed-lambda
      OR named-fn `bind` handlers. (Closed the enabling language gaps — see below.)
- [ ] The *visible* `run()` loop + an interactive JS→Nova round-trip updating the DOM — **manual GUI gate**
      (headless corpus can't display); the mechanism is verified end-to-end, only the pixels need a desktop.

**Status: ✅ COMPLETE (100%).** Display + Nova→JS eval + JS→Nova bind/dispatch + NSX rendering, with every
natural idiom working. Closing W1 to 100% drove three GENERAL language fixes (commit `29a1f07`): typed lambda
params `(s: string) => …` (§10 #19 — parser+AST+codegen), module-qualified const access `mod.CONST`, and
confirmed function-type return annotations. The FFI callback need was met via a runtime closure-invoke
primitive + in-libwebview trampolines (gate `83`), not general FFI fn-pointer marshalling.

The ONLY thing not automatable is the visible window (a headless corpus can't open a GUI) — the full
mechanism (bind trampoline → Nova handler → webview_return) is verified; a desktop run of `repro/webview_demo.nova`
shows it. **Not W1 gaps (unrelated features):** general FFI fn-pointer marshalling for arbitrary C callback
signatures; float/double FFI. **Deps:** T3 (done). **Tracking:** ✅ 2026-07-21 · commits `513ecf2` (display)
`6119c79` (bind/dispatch) `29a1f07` (enabling language fixes) · gates `83_ffi_callback` + `84_typed_lambda_params`
+ manual demo `repro/webview_demo.nova`.

---

# W2 — `App.useStatic(...)` — static content serving (⭐P3, user-requested) ✅

**Goal.** `app.useStatic("/static", "./wwwroot")` serves files from disk, cached.

**Decision (2026-07-21): REIMPLEMENTED IN NOVA, not bound from Zig.** On inspection the referenced Zig files
are comptime-generic + `std.Io`/allocator-heavy (`LruCache(comptime K,V)`, `StaticContentStore` over
`StringHashMap`) — a C-ABI FFI shim over them would be fragile, and Nova already has `Map`/`List`/`bytes`/
`io.file`/`web.mime`. The Nova version is ~130 lines, portable (wasm-ready), and dogfoods the stdlib. (FFI
stays the path for genuinely-C libraries like webview.)

**What landed** (`src/std/web/static_content.nova`):
- **LruCache** — bounded key→content, LRU eviction, hit/miss stats + `hitRate()`.
- **StaticMount** — `prefix`→`dir`; `serve(reqPath)` derives Content-Type from the extension, rejects `..`
  traversal (403), maps `/`→`index.html`, checks cache then disk.
- **App.useStatic(prefix, dir)** + `dispatch()` falls through to the mounts for GET requests that match no API
  route (routes win). `web/mime.nova` gained a `contentType(ext)` free function so the mime lookup crosses
  module boundaries without hitting the cross-module enum-method codegen gap.

**DoD:**
- [x] `useStatic` serves a file with correct MIME; second request is an LRU hit (stats confirm).
- [x] `../` traversal rejected (403); missing file → 404; API routes take precedence.
- [x] Gate `85_static_content`; corpus 107/107; ARC-audit + ASAN clean.

Fixed a latent crash en route: `nova_file_read_all` was typed `.string` in the sema builtins table but returns
an int byte-count, so codegen ARC-released the count as a pointer → SIGSEGV (broke `File.readText` for every
caller). Now `.int`. **Deferred (not W2):** etag/304, binary large files streamed (readText loads whole file),
`loadDirectory` pre-index. **Deps:** none (Nova-native). **Tracking:** ✅ 2026-07-21 · commit `ddd2c08` · gate
`85_static_content`.

---

# W3 — Circuit breaker for the OUTBOUND TCP/TLS client (⭐P4, user-clarified) ✅

**Goal.** Wrap the client that calls **external services** so a failing upstream trips the breaker instead of
being hammered — a resilience primitive on the outbound path, **separate from static serving**.

**Decision: REIMPLEMENTED IN NOVA** (like W2) — it is a pure state machine + a millisecond clock, so an FFI
bind of `circuit_breaker.zig` would be pointless. Modelled on `~/plancksystems/utils/src/circuit_breaker.zig`.

**What landed** (`src/std/web/circuit_breaker.nova`):
- **CircuitBreaker** — CLOSED/OPEN/HALF_OPEN; `failureThreshold`/`successThreshold`/`timeoutMs`;
  `shouldAllow` / `recordSuccess` / `recordFailure` / `getState` / `reset`. OPEN fails fast until `timeoutMs`
  elapses (`datetime.nowNs`/1e6), then a HALF_OPEN probe; M successes close it, any probe failure re-opens.
- **ResilientClient** — wraps `HttpClient` (get/post/send); connection-error/5xx → `recordFailure`, else
  `recordSuccess` (4xx is the caller's fault, not the upstream's); returns 503 fast without touching the
  network when OPEN.

**DoD:**
- [x] N consecutive failures open the breaker; calls then fail fast.
- [x] After `timeoutMs`, a probe passes (HALF_OPEN); M successes close it; a failed probe re-opens.
- [x] `ResilientClient` returns 503 without network when OPEN; 5xx trips it, 4xx does not.
- [x] Gate `86_circuit_breaker` (6 tests); corpus 108/108; ARC + ASAN clean.

Fixed a latent bug en route: `client.nova`'s `Request{...}` literals omitted the required `cookies` field
(client.nova was never compiled). **Deferred:** live integration against a flaky upstream (manual); wiring the
breaker into TLS/socket-level errors (currently keys off connection failure + HTTP 5xx). **Deps:** none
(Nova-native). **Tracking:** ✅ 2026-07-21 · commit `a63ffa4` · gate `86_circuit_breaker`.

---

# T6 — Separate compilation + `build/` layout (⭐user-specified, P5)

**User proposal (2026-07-22):** stop compiling the project as one merged unit. Instead: (1) create a `build/`
folder if absent; (2) emit one object file per *project* file and per *used* std file (not the whole stdlib);
(3) build objects into `build/obj`; (4) link the binary from those objects into `build/bin`; (5) — open
question — add `debug/`+`release/` tiers above `obj/`+`bin/`.

## My opinion — adopt it, with two corrections to the framing

**Yes, this is the right direction** and it's overdue: per-file object files with a real link step is how every
serious compiler is structured, and it unlocks the things the monolith can't give us. But two parts of the
stated rationale need adjusting so we build the right thing:

1. **"This would compile only the used std files, not everything" — we ALREADY do that.** Today
   `loadProgram` (src/main.zig) walks the **import graph** and only pulls in files that are actually imported
   (plus a couple of always-on preloads like `string_builder`). It does **not** glob the whole `src/std` tree.
   So separate compilation does **not** change *which files* compile — the import graph already gates that.
   What it *does* change, and why it's worth doing:
   - **Incremental rebuilds** — cache each `.o` by a content hash; an unchanged file is a cache hit, so a
     one-line edit stops recompiling all of std. This is the real prize (today every build reparses+recodegens
     the entire merged program — see the `merged.nova` write in `loadProgram`).
   - **Parallelism** — object files build concurrently.
   - **Honest diagnostics** — errors carry the true file/line, not an offset into a synthetic `merged.nova`.
   - **Function-level dead-code** — link with `--gc-sections` (+ `internal`/COMDAT linkage) to drop unused
     functions of an imported file. *This* is the grain of truth in "don't compile everything": today an
     imported file's every function is codegen'd even if one symbol is used; link-time GC trims that.

2. **True cross-unit separate *type-checking* is a big dependency, so phase it.** Nova currently type-checks,
   resolves names, monomorphizes generics (type-erased → instantiated), and decides ARC ownership **across the
   whole merged program in one pass**. You cannot naively compile file B in isolation because it needs A's
   types and the monomorphized instances A/B share. Splitting the *checker* per-unit needs interface/signature
   extraction + cross-module mono (COMDAT/weak symbols to dedup instantiations at link) and would also have to
   move the serde source-gen+reparse pass off the merged program. That is a large item gated on the F-series
   (F2-6 typed IR, F4 monomorphization, F5 module scoping). **So we split codegen first, checker later.**

### Recommended phased plan
- **Phase 1 (= "Phase 1b" in the tracking) — split codegen, keep one checker pass (the sweet spot).** Keep the
  single whole-program type-check/mono pass (so cross-file resolution and generics keep working *unchanged*), but
  **emit one LLVM module → one `.o` per source file** instead of one giant module, and **cache each `.o` by a
  content hash**. Link the cached objects into the final binary. This delivers incrementality + parallelism +
  honest diagnostics + link-time GC with **no change to the type system** — the lowest-risk, highest-value step,
  and it retires `merged.nova`.
  - **F4-6 — retire the serde/mediator source-gen+reparse (relocated here from S1).** `generateSerdeBinders`
    (`<Struct>__bind`/`__toJson`) and `generateMediatorDispatch` (`__mediator_dispatch_<Q>` + by-name switch)
    currently emit Nova SOURCE TEXT and RE-PARSE it against the merged program (`main.zig`, label
    `<serde-generated>`). That is the last pass that *requires* the whole merged program, so it must move as part
    of the per-file split — either by building the AST directly (no reparse) or by emitting the generated units as
    their own cacheable `.o`. **Deliberately NOT done ahead of this phase:** it is behavior-neutral (the reparse
    works and is fully gated — 13_serde, 56–60, 68–70, 99), the mediator generator is the riskiest part and gains
    nothing until per-unit compilation exists, so doing it speculatively is pure churn. Land it *with* the split.
- **Phase 2 — link-time dead-code + object cache invalidation.** `--gc-sections`, `internal` linkage for
  non-exported fns, and a cache key that also folds the *signature hash of each dependency* (so a changed
  callee signature correctly invalidates callers).
- **Phase 3 — true separate compilation (per-unit checking).** Interface extraction + cross-TU
  monomorphization. Gated on F2-6/F4/F5. Only pursue once Phase 1/2 pay off and the foundation is solid.

## On debug/release folders — **yes, split them (do it from Phase 1).**
Debug and release are **different codegen** — opt level, symbols, ASAN, and the `NOVA_ARC_AUDIT`/coverage
instrumentation — so their objects must **never share a cache directory**. Mixing them silently serves stale or
mismatched objects; this repo has already been bitten by stale-binary measurement traps
(see [[nova-arc-measurement-traps]], [[nova-buildzig-must-rebuild]]). Keying the object cache by profile is the
fix, and it matches what Nova devs expect from Cargo (`target/debug`, `target/release`) and CMake. Layout:

```
build/
  debug/   { obj/*.o , bin/<exe> }     # -O0 -g, ASAN/ARC-audit allowed
  release/ { obj/*.o , bin/<exe> }     # -O2/3, no debug instrumentation
```

Selected by `nova build` (default debug) vs `nova build --release`. The object cache lives under the profile
dir, so switching profiles never reuses the wrong objects. A future `nova clean` just removes `build/`.

## DoD
**Phase 1a — LANDED 2026-07-22** (`nova build` + `build/<profile>` layout + whole-program content-hash cache):
- [x] `nova build` creates `build/<profile>/{obj,bin}` (mkdir-p, idempotent); `merged.nova` no longer written
      (opt-in via `NOVA_DUMP_MERGED=1`).
- [x] The object is emitted into `build/<profile>/obj/<name>.o` and the binary linked into `build/<profile>/bin/<name>`
      (name from `project.json`; entry defaults to `src/main.nova`). `nova init` now writes a `.gitignore` with `build/`.
- [x] **Content-hash cache**: an unchanged build is SKIPPED ("… is up to date — nothing to rebuild"); editing any
      source → rebuild. Key = order-independent XOR of every input file's (path+content), folded with profile +
      `CACHE_VERSION`. Cache HIT requires the binary to still exist. (Whole-program granularity — see Phase 1b.)
- [x] `--release` / `--debug` select separate `build/release` vs `build/debug` trees (distinct codegen: `-O3`
      vs `-O0 -g`); they never cross-read (keyed by profile dir).
- [x] The direct `nova <file> -o out` path is **untouched** (all changes gated on `build_mode`), so the test
      harness + scripts keep their simple behaviour. Corpus **115/115**.

**Phase 1b — DEFERRED (the per-file object split).** Codegen is deeply single-module (shared `heap_ptr`/string
globals, cross-file refs without external decls, whole-program monomorphization), so emitting ONE `.o` PER SOURCE
FILE — the true per-file incrementality — is a large, risky refactor. The cache above already delivers the
common win (no-change rebuild = instant) at whole-program granularity; per-file granularity (edit one file →
recompile only that object) needs the codegen split + external-decl emission. Sequenced after the codebase is
past sound-beta.

- [ ] **Phase 1b:** one `.o` per source file into `build/<profile>/obj/`; per-file cache invalidation.
- [ ] **Phase 2:** link-time dead-code (`--gc-sections` + `internal` linkage), dep-signature-hash in the key.
- [ ] **Phase 3:** true per-unit checking (interface extraction + cross-TU mono) — gated on F2-6/F4/F5.

**Deps:** Phase 1a landed (nothing new). Phase 3 depends on F2-6 typed IR + F4 mono + F5 scoping. **Tracking:**
◑ 2026-07-22 · Phase 1a done (`nova build`, `build/<profile>/{obj,bin}`, content-hash cache, debug/release,
merged.nova retired, init .gitignore); per-file split (1b) deferred as a codegen refactor.

---

## Suggested execution order (dependency-aware)
1. **H1** (harness) — makes every later negative gate trustworthy.
2. **X2** (crypto folder) — concrete, low-risk, exactly as requested; unblocks C1.
3. ~~**T3 (FFI)**~~ ✅ **DONE** (2026-07-21, v1: scalars/ptr/string/struct; float/double deferred) — the
   keystone that lets **W1/W2/W3** bind proven Zig code instead of re-porting.
4. **W1/W2/W3 + T5** — the product surface: webview, static serving, outbound resilience, VSA template.
   **← next.** Now unblocked by FFI: each can bind its `~/plancksystems` Zig implementation via `extern("lib")`.
5. **F1/F2** (small unblockers) — make drivers/closures cleaner.
6. **H2** (optionals) — soundness; larger.
7. **S4** (decimal parser) — unblocks exact decimal across all drivers + serde.
8. Then drivers/error-model/async/tooling per priority (D1, C1→D2/D3, E1, A1, S1/S2, T1/T2, T4).

Foundation-finishing (F3/F4/F5) is scheduled opportunistically — none gates the above. Foundation
memory-safety + monomorphization + BTreeDB e2e + YCSB (D4) + async/spawn are **done** (see the completed
banner at the top).
