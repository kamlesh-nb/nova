# Kyte — Feature Roadmap (beyond the F1–F5 foundation)

**Written:** 2026-07-19. Companion to `foundation-pending.md` (which covers finishing F1–F5 itself).

This is the menu of *features* to build on the now-safe foundation. Each entry states **what**, its
**dependencies** (esp. on any pending foundation item), a rough **effort**, and a **stability note**
(does it touch the ARC boundary / need new gates). Ordering within a tier is a suggestion, not a lock.

> **Standing discipline (applies to every item):** grow the conformance corpus with each new pattern and
> pass `--arc` + `--asan` + `--shadow` before cutover (and `--wasm` for anything touching codegen — it
> gates that the corpus still compiles to a valid wasm module, baseline-gated). The foundation is safe
> *because* of this gate discipline — features inherit that only if they keep it.

---

## Tier 0 — Language-completeness quick wins (mostly ARC-independent) — ✅ SHIPPED (3 of 4)

Small, self-contained, high-leverage. The loop/entry-point quick wins are **done and gated**; the one
remaining row (explicit generic type-args) is genuinely still pending and has moved to **P0.5 #4** because
it is a prerequisite for the flagship generic traits.

| Feature | What | Status |
|---|---|---|
| **C-style `for` loop** | `for (init; cond; incr) body` desugared to `while`, with `incr` emitted at the continue-block so it runs on `continue` too. | ✅ **DONE** — commit `590856c`, gate `53_for_loops`. |
| **`main(args)`** | Real C `main(argc, argv)` + `kyte_set_args`/`kyte_arg_count`/`kyte_arg_at` runtime shim, `env.args(): List<string>`, optional `main` args param. | ✅ **DONE** — commit `e33615a`, gate `54_process_args` (`./app a b 42` → argc=4 end-to-end). |
| **Rust-like `for … in`** | All three iterator forms: `for x in xs` (collection, via `.size()`/`.get(i)`), `for (k,v) in map` (via `keys()`/`get()`, preserving `break`/`continue`), and `for i in 0..n` / `0..=n` (**ranges** — new `..`/`..=` lexer tokens + `RangeExpr` AST, no allocation). | ✅ **DONE** — commits `590856c` (ranges+C-style), `7265167` (collection), `5f03e20` (map), `e33615a` (ident no-hoist fix). Gate `53_for_loops` (17 subtests). |
| **Explicit generic type-args** | Consume `Foo<int>{ … }` explicit args. The parser currently parses the `<…>` then **discards** it — `StructInit` has no `type_args` field (`parser.zig:1816`), so this is **not** done. | ⏳ **PENDING → P0.5 #4 (F4-1)** — prereq for generic traits (flagship). |

---

## Tier 1 — Runtime & concurrency — ✅ CORE DONE (CLAUDE.md's "fragile C runtime" note is stale)

The C++20 async-runtime migration is **already in place** (`src/runtime/concurrency.cpp`, ~671 lines):
Boost.Asio `io_context` as the scheduler, LLVM coroutine switched-resume driven from Asio completion
handlers, a **multi-threaded** context (background thread pool, `KYTE_THREADS`), **per-coroutine /
per-socket strands** for cross-thread safety, and a race-free waiter registry. `async`/`await` codegen
lowers to native coroutines (`is_async_native`). Kyte `async fn` + `await` work end-to-end. This is
NOT pending — it's the substrate.

Remaining here is **polish on top of a working runtime**, not an architectural rewrite:

| Feature | What | Deps | Effort | Stability note |
|---|---|---|---|---|
| **Full channels** | Current channels are a **simple bounded blocking queue (v0 shim)**; a fuller fiber-aware / `asio` concurrent-channel impl is parked in `concurrency_boost.cpp.wip`. Upgrade to non-blocking, coroutine-aware channels. | runtime (done) | ~3–5 days | Message ownership transfer across threads = a `consumed` disposition case — grow cross-thread ARC cases. |
| **`async` stdlib utilities** | `parallel_for`, `when_all`/`when_any`, timeouts, cancellation — the ergonomics layer. | runtime (done) | ~1 wk | Owned futures/handles — needs `Handle<T>` typing (the one open F2 gap for `await`). |
| **Actor model** | Actors as a stdlib layer over strands + channels (CLAUDE.md). The primitives exist; this is the API. | full channels | ~1 wk | Message-ownership transfer = `consumed`. |
| **Networking maturity** | HTTP/1.1 + WebSocket via Boost.Beast, TLS via wolfSSL (partly present: `net/tls.ky`, `web/`). Harden on the Asio runtime; connection pooling / keep-alive. | runtime (done) | ~1–2 wk | Binary-safe I/O required (see the socket-send gap below). |

---

## Tier 1.5 — Web framework: typed routing via mediator ⭐ FLAGSHIP

**This is the feature the entire compiler/codegen overhaul was for** (generic traits, serde codegen,
tuple-return ARC, namespace-receiver capture, optional see-through). Full plan of record:
`lang/docs/design/done/route-handling-via-mediator.md` (the ratified design; follow it for the mediator/
generic-traits architecture). It supersedes the **rejected** string-keyed `app.get<T>`/`app.on<T>`
prototype. **This roadmap overrides that archived doc on one point: HTTP method names are the bare verbs
`get`/`post`/… (see below), not the `mapGet`/`mapPost` the archived doc still shows.** Memory:
`[[kyte-app-generic-mediator]]`.

**Target DX** — .NET MediatR (typed `IRequestHandler<TReq,TResp>`, auto-discovered handlers, pipeline
behaviors) fused with .NET Minimal API (`app.mapGet<T>`, automatic model-binding, automatic JSON out):

```kyte
@serializable struct GetUser impl Request<UserDto> { pub id: int }
@serializable struct UserDto { pub id: int, pub name: string }

struct GetUserHandler impl RequestHandler<GetUser, UserDto> {
    fn handle(self, req: GetUser): UserDto { return UserDto{ id: req.id, name: "Ada" }; }
}

let app = App();
app.get<GetUser>("/api/user/{id:int}");   // bind → mediator → handler → UserDto → JSON, one line
app.run(8080);
```

**Method names are the bare HTTP verbs** — `get` / `post` / `put` / `delete` / `patch` / `options` /
`head` (Express/Flask-style), **not** `mapGet`/`mapPost`. Note: this reuses the verb name of the earlier
**rejected** `app.get<T>` prototype, but only the *name* — the rejection was of the *mechanism*
(string-keyed routing, `handle(req: any)`, manual `as` downcast, separate `on<T>` registration), which is
gone. Here `app.get<T>` is the fully-typed generic-trait handler with compile-time discovery.

Behind `app.get<GetUser>(route)` the framework: finds the `RequestHandler<GetUser,_>` impl at compile time
(missing/ambiguous = **compile error**), reifies `GetUser__bind(src)`, builds the request `ValueSource`
(`@fromRoute` route/query params overlaid on `@fromBody`), dispatches through the canonical mediator
pipeline (behaviors, pre/post, exception handlers), then serializes the returned DTO via `UserDto__toJson`.
No `any`, no `as` downcast, no manual JSON, no separate registration.

### (a) Enabling language feature — **generic traits** (the one real blocker)

`trait Handler<Q,R>` today dies at the **parser** (`error.ExpectedToken`); `StructDecl.impls` stores trait
names as bare strings with **no type args**, so the compiler can't even represent `impl Handler<GetUser,UserDto>`.
**Crux that makes this cheap: trait dispatch is already fully type-erased** (every value is one i64 handle;
one vtable slot per method serves every instantiation), so `Q`/`R` are a **compile-time-checking concern
only — codegen needs ZERO changes, no trait monomorphization.**

| Stage | What | Risk | Effort |
|---|---|---|---|
| **Parser** | `parseTraitDecl` accept `<...>` type params (reuse the struct type-param loop); struct `impl` loop parse per-impl `<...>` type args. | very low (mirrors struct code) | ~1 hr |
| **AST** | `TraitDecl.type_params`; widen `impls: [][]const u8` → carry type args per impl (`{name, args:[]TypeRef}`); fix the 4 readers. | low (mechanical ripple) | ~2 hrs |
| **Sema** | `traitMethodReturn` must substitute `Q`/`R` (it punts today) — reuse generic-struct machinery (`subst.substitute`, `ParamScope`). Add `args` to the store's `trait_` type. Impl-conformance check substitutes trait params before comparing signatures. | **MODERATE — the only real logic** | ~1 day |
| **Codegen** | **nothing** — dispatch, vtable, 16-byte fat pointer, `__destruct_trait` all unchanged. | none | — |
| **Tests** | conformance: 1-param trait, 2-param, dispatch through trait object, impl-conformance error after substitution. | — | ~½ day |

**Estimate: ~2–3 focused days.** Risk concentrated entirely in the sema substitution. Depends on **F4-1**
(type args survive parse) for the impl-side arg storage.

### (b) Framework layer (on top of generic traits)

| Piece | What | Deps | Effort |
|---|---|---|---|
| **`RequestHandler<TReq,TResp>` trait** | in `web/mediator.ky`, `fn handle(self, req: TReq): TResp`. Replaces the `any`-based handler. Pipeline traits (`PipelineBehavior`, `PreProcessor`, `PostProcessor`, `ExceptionHandler`) stay. | generic traits | ~1–2 days |
| **Compile-time handler discovery** | scan structs impl-ing `RequestHandler<Q,_>` → request-type → (handler, `handle` fn-ptr, response type) map. Ambiguous/missing = compile error (MediatR-style, zero registration). | generic traits | ~2–3 days |
| **`get<T>`/`post<T>`/`put<T>`/`delete<T>`/`patch<T>`/`options<T>`/`head<T>`** | codegen lowering (same reify pattern as `json.parse<T>`): `T__bind` binder + discovered `handle` fn-ptr + `R__toJson` serializer, register route. Bare HTTP-verb names (not `mapGet`/…). | discovery, serde codegen (done) | ~3–4 days |
| **Typed dispatch + auto-JSON** | route match → build `ValueSource` (GET: `ParamSource(route+query)`; POST/PUT/PATCH: `CompositeSource(route,body)`, `@fromRoute` over `@fromBody`) → `T__bind` → mediator pipeline → `handle` → `R__toJson` → `Response`. Response type inferred from `handle` return. | above | folds in |
| **`kyte init app` template refresh** | rewrite the ASP.NET-style scaffold to the `mapGet<T>` + typed-handler API. | framework | ~1 wk (also Tier 6) |

**Naming standard (ratified):** descriptive `T`-prefix PascalCase for role params (`TRequest`, `TResponse`,
`THandler`); bare single letters (`T`,`K`,`V`,`E`) reserved for structural containers (`List<T>`, `Map<K,V>`).
Traits PascalCase, no `I`-prefix.

### (c) Keeper fixes surfaced while prototyping (some in-tree, reconcile before starting)

- **Tuple-return ARC** — COMMITTED (`4464c04`), gate `28_tuple_return_heap`. (ARC half done; the
  **type-checker half — D1/D2/D4** in route doc §8.D — still open: tuple element types + arity unchecked.)
- **Optional see-through for member access** — COMMITTED, gate `30_optional_member_access`. **⚠️ conflicts
  with optionals soundness (route doc §8.B4)** — see-through admits the exact unnarrowed access that
  segfaults; must be reconciled (restrict to `?.`/`??`, or admit optionals are unchecked) before either is "done".
- **Namespace-receiver capture** (module-qualified types in closures) — module-function form COMMITTED
  (`4464c04`); the **module-TYPE extension is UNCOMMITTED** and blocked by a codegen bug: constructing/calling
  a method on a module-qualified type **inside a closure in the main program** fails (`response.Response(...)`
  → `StructTypeNotFound`; `Status.Ok.toCode()` → `MethodOrFunctionNotFound`). **This blocks a clean
  standalone gate** and must be fixed for module-qualified types to work uniformly in closures.

---

## Tier 2 — Data & database drivers

**Shared prerequisite for every driver below:** the binary socket-send fix (`kyte_socket_send_n`) — the
current `kyte_socket_send` uses `strlen` and truncates binary wire data at the first null byte. Also a
shared **abstract DB driver** seam (connection / query / typed params / result rows / typed column decode)
that NovaDB, the SQL drivers, and Mongo all implement — the existing one is "too naive" (CLAUDE.md) and
should be redesigned **once, from the NovaDB work**, then implemented per-backend.

**Priority order: NovaDB (P2, Kyte's own engine — defines the seam) → SQL drivers (P3) → MongoDB (P6, lowest).**

### NovaDB integration — ⭐ PRIORITY DB (Kyte's own storage engine, P2)

CLAUDE.md's reason-to-exist storage engine and the **priority DB integration** — it's the native DB Kyte
apps target, it's locally/offline testable, and its SQL parser + query executor make it the natural place to
define the shared DB seam that the SQL drivers then reuse. NovaDB is a **separate project** built separately
(CLAUDE.md); the binary-protocol work on the btree side is tracked in `[[btree-readiness]]` /
`btree/btree_readiness_plan.md`. Below is the **Kyte-language-side** driver + benchmarks.

| Feature | What | Deps | Effort |
|---|---|---|---|
| **Shared abstract DB seam** | Redesign the "too naive" driver interface (connection / query / typed params / rows / typed decode). NovaDB is the reference; the seam must also fit the SQL drivers (and later Mongo). | binary socket I/O | ~2–3 days |
| **Kyte DB driver** | Target the **JSON protocol first** per `[[btree-readiness]]`, then the pure **binary protocol** (btree side has a `proto/` scaffold: wire/command/session). connect → query → typed rows, decimal round-trip. | seam, protocol | ~1–2 wk |
| **YCSB benchmarks** | Write YCSB workloads in Kyte against NovaDB (explicit CLAUDE.md goal). | driver | ~3–5 days |

### SQL drivers — PostgreSQL, MySQL, MSSQL (P3)

Three production SQL wire protocols, implemented natively in Kyte over the shared binary-socket I/O +
abstract DB driver seam. All three need: binary socket send, **crypto** (SHA-256/HMAC/PBKDF2 — Tier 3, and
shared with Mongo SCRAM), **decimal** for `NUMERIC`/`DECIMAL` columns (done), and typed row decoding. Build
**PostgreSQL first** — the cleanest, best-documented protocol and the reference implementation for the
shared driver abstraction; MySQL and MSSQL then follow the same shape.

| Driver | Protocol | Key work | Auth | Notes | Effort |
|---|---|---|---|---|---|
| **PostgreSQL** | v3 message protocol (typed message frames: `Startup`, `Query`, `Parse`/`Bind`/`Execute`, `DataRow`, `RowDescription`). | startup + parameter negotiation; simple query; **extended query** (prepared statements, bind params); text **and** binary result formats; typed decode by OID (int2/4/8, float, `numeric`→decimal, text, bool, bytea, timestamp). | MD5 + **SCRAM-SHA-256** (shares the SCRAM impl with Mongo). | Cleanest protocol — the reference driver. Offline-verifiable framing; live vs a local `postgres`. | ~1–2 wk |
| **MySQL** | client/server protocol, handshake v10; length-encoded ints/strings; `COM_QUERY` + `COM_STMT_PREPARE`/`COM_STMT_EXECUTE`. | handshake + capability flags; text protocol result set; **binary protocol** prepared statements; typed decode incl. `DECIMAL`→decimal; EOF/OK/ERR packet handling. | `mysql_native_password` + **`caching_sha2_password`** (default on MySQL 8 — RSA-encrypted password exchange or TLS). | `caching_sha2` needs the public-key fetch/RSA path or a TLS channel. | ~1–2 wk |
| **MSSQL** | **TDS** (Tabular Data Stream) — packet-framed, PRELOGIN → LOGIN7 → SQLBatch/RPC → `COLMETADATA`/`ROW` tokens. | packet framing/reassembly; PRELOGIN negotiation; LOGIN7; SQLBatch + RPC (param'd); token-stream row decode incl. `DECIMAL`/`NUMERIC`→decimal, TDS `MONEY`, unicode. | SQL-auth (LOGIN7); **TLS is mandatory during the login handshake** (encrypted PRELOGIN). | Most complex — TLS-during-handshake + token stream. Do last. | ~2–3 wk |

**Testability (all three):** wire-frame encode/decode + typed decode are **byte-verifiable offline** as
unit tests; the connect/query API then runs against a local server (`postgres`/`mysqld`/`sqlservr` in a
container). Land PostgreSQL end-to-end first, extract the shared driver abstraction from it, then MySQL and
MSSQL reuse it.

### MongoDB driver — ⬇ LOWEST PRIORITY (P6)

Was the earlier "immediate ask"; **explicitly deprioritized** behind NovaDB and the SQL drivers. Kept
because the wire + BSON + decimal path is offline-byte-verifiable and its SCRAM work is shared with
PostgreSQL — cheap to add once crypto + the seam exist. Uses the now-complete `decimal128` for BSON decimal
round-trips.

| Layer | What | Deps | Effort |
|---|---|---|---|
| **BSON decimal read accessor** | `findDecimal`/`docGetDecimal` (encode side + `entryDecimal` already exist). | bson.ky | ~½ day |
| **Wire protocol (OP_MSG)** | 16-byte msg header (length/requestID/responseTo/opCode) + OP_MSG sections; request/response framing. | binary send, BSON | ~2–3 days |
| **Driver core** | connect → `hello` handshake → command execution (a command is a BSON doc over OP_MSG): `insert`, `find`. Decimal document round-trip end-to-end. | wire protocol, seam | ~2–3 days |
| **SCRAM-SHA-256 auth** | client-first / server-first / client-final; HMAC + PBKDF2 over SHA-256. Shares the SCRAM impl with PostgreSQL. | crypto (SHA-256/HMAC/PBKDF2) | ~1 wk (crypto-heavy) |
| **More commands** | `update`, `delete`, `aggregate`, cursors (`getMore`). | driver core | ~1 wk |

**Testability:** the wire messages + BSON + decimal path are **byte-verifiable offline** (unit tests without
a live server); the connect/command API runs against a real `mongod` when available.

---

## Tier 3 — Standard library expansion

| Feature | What | State | Effort |
|---|---|---|---|
| **serde completeness** | JSON/YAML/BSON exist; finish serde source-gen fold into sema (foundation F4-6), decimal in JSON/YAML, streaming. | partial | ~1 wk |
| **crypto** | SHA-256/HMAC/PBKDF2 (needed for SCRAM), plus general hashing/AEAD. `crypto/` is empty; `crypto.ky` minimal. | thin | ~1 wk |
| **HTTP client/server** | `web/client.ky` + `web/server.ky` exist; mature on the C++20 runtime, add connection pooling, keep-alive. | partial | ~1 wk |
| **collections** | `list`/`map`/`set`/`string_builder` exist; add ordered map, deque, priority queue as needed. | good | as-needed |
| **text/regex** | UTF-8 exists (`text/utf8.ky`); a regex engine is missing. | thin | ~1–2 wk |
| **decimal follow-ups** | Div-by-zero policy (trap vs the current 0-stub), explicit `int`↔`decimal` conversion functions, decimal in more numeric contexts. | Stage-2 done | ~2–3 days |

---

## Tier 4 — Toolchain self-sufficiency + WASM (second axis — independent of F1–F5)

"Can Kyte build like Zig — without the user installing LLVM/clang/lld." Integration engineering, lower
risk, can run in parallel with the ownership/feature work.

### WASM backend — DECIDED: keep LLVM's `wasm32` backend; **no hand-rolled WASM compiler**

- **Kyte already compiles to WASM through LLVM** (AST → LLVM IR → LLVM `wasm32` → `.o`), with ~44
  `is_wasm` codegen branches for the host-import I/O model. This **reuses the entire backend** — one
  codebase, battle-tested LLVM output.
- **`discards/wasm.zig` (a 2,225-line hand-rolled WASM bytecode emitter) is dead and stays dead.** It
  covers only functions/structs/closures/`console.log` — essentially **zero** generics/traits/async/
  error-unions/optionals (10 mentions of all of those *combined*). Reviving it = re-implementing the
  whole language backend a second time by hand and keeping two backends in lockstep forever. Rejected.
- **Zig's self-hosted WASM backend is not reusable** — it compiles Zig's IR (AIR), not Kyte's AST. What
  Kyte shares with Zig is the LLVM path (Zig's own default backend), which Kyte is already on.
- **A Kyte self-hosted WASM backend is worth it ONLY if the hard goal is dropping LLVM entirely** —
  a multi-month project with low ROI while LLVM already produces good wasm. Not now.
- **Remaining WASM work is verification, not a new backend:** add a `--wasm` conformance run (the ~44
  branches emit + link but are unproven across the corpus), finalize the host-import I/O ABI.

### Self-contained linking — VERIFIED constraints (2026-07-19)

The current dep (`llvm-zig`, `build.zig.zon`) is **NOT self-contained**, confirmed by inspecting the package:
- `linker.zig` exposes **only `LLVMLinkModules2`** — the LLVM *IR-module* merger, **not** an object
  linker; it cannot produce a `.wasm` or an executable.
- `build.zig` uses `linkSystemLibrary("LLVM")` + `linkSystemLibrary("clang")` — a **system-installed**
  LLVM/clang shared lib, with **no `liblldELF`/`liblldWasm`/`liblldCommon`**.
- ⇒ Today Kyte needs **system LLVM *and* system clang** (the `clang++`/`clang -target wasm32` link
  shell-outs, `main.zig:1189` / `:1433`). LLD is not available *through the package*.

### On-disk inventory (this machine, 2026-07-19) — what "dependency-free" actually needs

The distinction that matters: `llvm-zig` doesn't *link* LLD, but the toolchain pieces are all **present
on disk** — so this is an integration/build-config job, not a sourcing problem, EXCEPT for one item.

| Component | Needed for | Present? | Form on disk |
|---|---|---|---|
| **LLVM codegen (static)** | Kyte → `.o`; static-link into `kyte` | ✅ | **206 `libLLVM*.a`** at `/opt/homebrew/opt/llvm/lib` (LLVM 21.1.7) |
| **LLVM (dynamic)** | what `kyte` links today | ✅ | `libLLVM.dylib` — the current runtime dep (`otool -L kyte`) |
| **clang** | building the C++20 runtime | ✅ | `libclang*.a` + `libclang-cpp.dylib` |
| **LLD** | the linker (replace the `clang`/`clang++` shell-out) | ✅ *but* | **binaries** `ld.lld`/`ld64.lld`/`wasm-ld` + **dylibs** `liblldWasm.dylib`/`liblldELF.dylib`/`liblldMachO.dylib`/… at `/opt/homebrew/opt/lld` — **NO `liblld*.a`** |
| **LLD (also)** | — | ✅ | bundled inside `~/zig` (verified: `zig cc` links a `.wasm` via it) |

**The one gap: LLD in *static* (`.a`) form.** Homebrew ships LLD only as binaries + dylibs. That matters
*only* for compiling the linker *into* `kyte` (in-process `lld::wasm::link()`). Everything else needed
for a self-contained toolchain — static LLVM archives, LLD binaries/dylibs, clang — is here.

> **⚠️ CORRECTION — 2026-07-20: the LLVM.org 22 drop is LTO bitcode, NOT directly linkable.** The earlier
> "gap closed" claim was wrong on the decisive point. The drop's `libLLVM*.a` / `liblld*.a` members are
> **LLVM bitcode** (`file` → "LLVM bitcode, wrapper"; magic `BC\xC0\xDE`), because the LLVM.org release is
> an **LTO build**. Zig's self-hosted linker can't consume them (`unknown cpu architecture: 0` — it parses
> bitcode as Mach-O), and Zig refuses LLD-for-Mach-O (`using LLD to link macho files is unsupported`). So
> the drop **cannot statically link `kyte` via Zig's build.** (It stays reserved for the future in-process
> LLD that links `kyte`'s *output* programs — a separate concern.)
>
> **✅ RESOLVED — native LLVM 22 by conversion.** A true from-source `LLVM_ENABLE_LTO=OFF` build was
> **infeasible on this machine** (needs ~20–40 GB; disk had 9 GB free at 95%). Instead
> `deps/llvm-zig/convert-drop-to-native.sh` ran all **3055** `libLLVM*.a`/`liblld*.a` members through the
> drop's own `llc -filetype=obj` and re-archived them → a **native LLVM 22** prefix (`…-native/`, 222 MB,
> **0 failures**). This reaches the same native archives from ~433 MB of bitcode, cheaply.
>
> **✅ What landed for static-LLVM (P5 #20, opt-in):** `zig build -Dstatic-llvm=true` static-links the
> **native LLVM 22** tree → a **132 MB self-contained `kyte`** whose only dylib deps are
> `/usr/lib/{libz,libxml2,libSystem}` (all OS libs — no `libLLVM.dylib`, no Homebrew paths). The LLVM
> **21→22 C-API bindings are compatible** (links with no undefined symbols). Gates green on the static
> binary: FUNC 74/74, ARC 128/128, SHADOW 128/128. Default `zig build` stays **dynamic** (5.4 MB, Homebrew
> 21, fast dev). `libzstd.a` vendored (`deps/zstd`); `z`/`xml2` resolve against the macOS SDK dylibs.
>
> **In-process LLD now UNBLOCKED:** because the tree is native LLVM 22 (not 21), the same conversion
> produced native `liblld*.a` — codegen-LLVM and LLD are the same version, so the fully-standalone single
> `kyte` (linker compiled in via `lld::{macho,wasm,elf}::link()`) is the next step, no longer version-blocked.

**The path (Zig's distribution model).** Kyte is already *built with* Zig 0.16.0, which bundles clang
21.1.0 (`zig cc`), LLD, and a self-hosted wasm backend — the exact "everything built-in" toolchain.
Easiest-first:

| Step | What | Notes | Effort |
|---|---|---|---|
| **WASM link via LLD** | Replace `clang -target wasm32 …` with a direct **`wasm-ld`** call (`/opt/homebrew/opt/lld/bin/wasm-ld`, or via `zig`). WASM is `-nostdlib` + host imports → **no C++ runtime to link**, just LLD on one `.o`. The cleanest first cut. | LLD binary already present — no sourcing needed. | ~2–3 days |
| **Native link via LLD** | Replace the `clang++` shell-out with **`ld64.lld`** (macOS) / **`ld.lld`** (Linux), linking `.o` + prebuilt runtime + wolfSSL. | LLD binaries already present at `/opt/homebrew/opt/lld/bin`. | ~1 wk |
| **Runtime via `zig c++`** | Build the C++20 runtime with Zig's bundled clang (or ship prebuilt per target) so no system clang++ is needed. | Zig at `~/zig` provides `zig c++`. | ~few days |
| **Static LLVM** | Switch `linkSystemLibrary("LLVM")` → static-link the **206 `libLLVM*.a`** archives (already on disk) so `kyte` carries codegen and needs no `libLLVM.dylib` at runtime. | Archives present; the `llvm-zig` `build.zig` needs to link the static components instead of the dylib (patch the dep or list the archives). | ~few days–1 wk |

**Sourcing decision to make explicit:** "self-contained" = either
- **(a) `kyte` shells out to LLD/clang binaries or `zig`** as the link/cc driver — **everything needed is
  already on disk** (LLD binaries at `/opt/homebrew/opt/lld/bin`, or `zig` which bundles LLD+clang+wasm).
  Fast path to "user installs nothing extra beyond Zig," no sourcing. Start here.
- **(b) fully-standalone single `kyte` binary** — static-link the 206 `libLLVM*.a` (present) **and**
  vendor **LLD static libs** to call `lld::*::link()` in-process. The **one missing piece is
  `liblld*.a`** (Homebrew ships only dylibs) → build LLD from source, or just rely on Zig per (a).

Recommendation: ship (a) — the machine already has every binary/dylib required; only insist on (b) if a
truly single-file `kyte` with the linker compiled in is a hard requirement.

---

## Tier 5 — FFI (third axis)

Call arbitrary C libraries. **Depends on** the ownership pass (for the ARC boundary — done) and the
linker work (for `-l`/`-L` and clang-free linking).

| Piece | What | Effort |
|---|---|---|
| **Syntax + sema** | `extern("libcurl") fn curl_easy_init(): ptr;` — generalize the hardcoded `kyte_*` extern path into a first-class extern decl. | ~2–3 days |
| **Type marshalling** | Kyte ↔ C ABI: int/long/ptr/bool/double direct; `string` ↔ `char*` (borrow vs copy — Kyte strings carry a length prefix); `extern struct` (repr-C) layout; array borrow-or-copy. **The substance.** | ~3–4 days |
| **Ownership boundary** | BORROW vs TRANSFER at the C boundary — built *on* the ownership pass's owned/borrowed/consumed disposition, not a second ad-hoc rule set. | folds into the above |
| **Callbacks (Kyte→C fn ptr)** | Optional/later: expose a non-capturing Kyte fn as a C function pointer. | ~2 days |

---

## Tier 6 — Tooling & developer experience

| Feature | What | State | Effort |
|---|---|---|---|
| **LSP maturity** | Diagnostics, hover, go-to-def, completion on the real symbol table. | basic | ~1–2 wk |
| **VSCode extension** | Beyond syntax highlighting: LSP client, debugging. | basic highlighter | ~1 wk |
| **Formatter** | `kyte fmt`. | none | ~1 wk |
| **Package manager / module system** | Finish real module scoping (foundation F1-4) → dependency resolution, versioning. | F1-4 in progress | ~2–3 wk |
| **`kyte init app` template** | Improve the ASP.NET-style web-app scaffold (CLAUDE.md); wire it to the mediator/routing + a DB driver. | exists, rough | ~1 wk |

---

## Prioritized TODO (2026-07-20)

Ordered by **what unblocks the most / risks the most**, not by tier number. Tier 0 (`for` loops,
`main(args)`) and `decimal128` are **DONE** and omitted. Effort in focused days. The gate discipline
(`--arc` + `--asan` + `--shadow` + a new conformance case per pattern) applies to every item — it is not a
line item, it is the definition of done.

Rationale for the ordering: **(1)** close the one remaining live memory-safety hole and the harness blind
spot that hides regressions — everything downstream is unverifiable until then; **(2)** land the small
unblockers every driver and the flagship depend on; **(3)** build the flagship (typed mediator routing) —
the reason the compiler was overhauled; **(4)** prove the whole stack with **NovaDB — Kyte's own storage
engine** (CLAUDE.md's reason to exist, and locally/offline testable), establishing the shared DB seam, then
fan out to the SQL drivers; **MongoDB is lowest priority** (P6); **(5)** concurrency/stdlib/toolchain polish,
which is additive and parallel-safe.

### P0 — Safety + verification integrity (blocks trusting everything else)

| # | Item | Why now | Ref | Effort |
|---|---|---|---|---|
| 1 | **Conformance harness integrity** — `expect_fail` asserts a real diagnostic, not just exit≠0 (a segfault currently reads as "rejected"). Fix the silently-regressed `return_type_mismatch`. Turn `KYTE_ARC_AUDIT` on in the corpus. | Every negative result is unfalsifiable until this lands; regressions hide. | route §8.A | ~1–2 days |
| 2 | **Optionals soundness reconciliation** — unnarrowed access on an absent optional (`l.get(5).length`) **segfaults today** and every unsound direction compiles with no diagnostic. Decide + implement: restrict the `30_optional_member_access` see-through to `?.`/`??`, OR add real narrowing enforcement. **Measure stdlib blast radius first** (grep-and-count, like the load-bearing numeric permissiveness). | Live null-deref crash; directly conflicts with a shipped keeper commit. | route §8.B | ~3–5 days |

### P0.5 — Small unblockers (tiny, gate the flagship + all drivers)

| # | Item | Unblocks | Ref | Effort |
|---|---|---|---|---|
| 3 | **`kyte_socket_send_n`** (length-aware binary send) + `TcpStream.writeBytes` — ✅ **LANDED** (`36b65f0`): sends exactly `len` raw bytes (embedded NULs and all), unlike header-length `write`. Wired across runtime/sema/codegen/stdlib; gate `62_socket_send_n` (loopback, binary payload with NULs, byte-exact). Also fixed a latent recv-typed-as-`.string` bug that ARC-released the integer byte-count as an owned string pointer → segfault on clean teardown. | **every** binary network driver | Tier 2 | ✅ done |
| 4 | **F4-1: type args survive parse** (`StructInit.type_args`) + consume explicit `Foo<int>{…}`. | generic-traits impl-side args (flagship), explicit generic type-args. | Tier 0 | ~1–2 days |
| 5 | **Module-qualified type inside a closure** codegen fix (`response.Response(...)` → `StructTypeNotFound`). | commits the namespace-type-capture keeper; unblocks a clean mediator gate. | Tier 1.5(c) | ~1–2 days |

### P1 — ⭐ Flagship: typed mediator routing (the reason for the overhaul)

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 6 | **Generic traits** — ✅ **LANDED** (`4873cb5`): `trait T<Q,R>` + `impl T<Concrete,…>`; sema substitutes trait type params before conformance (wrong concrete = compile error); codegen ZERO (type-erased). Gate `55_generic_traits`, native green (FUNC 75/75, ARC 130/130, SHADOW 130/130). | — | Tier 1.5(a) | ✅ done |
| 7 | **`RequestHandler<TReq,TResp>` trait** — ✅ **typed pipeline LANDED** (`3e6b629`, gate `56_typed_mediator`): the full `TReq__bind(source.fromJson) → handler.handle → TResp__toJson` flow works on native, no `any`/downcast (2 handlers, 2 instantiations). **Remaining:** compile-time handler **discovery** (scan `RequestHandler<Q,_>` impls → request-type→handler map; missing/ambiguous = compile error). | #6 ✅ | Tier 1.5(b) | ~2–3 days left |
| 8 | **`get<T>`/`post<T>`/…** lowering — ✅ **LANDED** (`aa180b0`, gate `58_typed_routing`): `app.get<GetUser>(path)` lowers to `app.__addRoute("GET", path, "GetUser")` (route keyed by request-type name), dispatched via the generated `__mediator_dispatch_by_name` (bind→handle→serialize). Zero registration. Sounder than the doc's fn-pointer plan (a fn-value of a struct-typed binder mis-marshals; a name+call doesn't). Native green FUNC 78/78, ARC/SHADOW 136/136. **Stdlib Router + @fromRoute + serve LANDED — flagship COMPLETE end-to-end** (`0f9a073`, `5faa532`, `7342d68`): `import web.routing` gives `RequestHandler<Q,R>` + `Router` — zero boilerplate. Pattern routes `/user/{id:int}` extract path params, overlay them on the body via `CompositeSource` (route wins). `Router.serve(req): Response` bridges the typed pipeline to the HTTP server — a live app is `server.listen(port, app.serve)`, no new networking code; 404 (no path) vs 405 (path matched, wrong method) distinguished. Gates `59_route_params`, `60_router_serve`. Native green FUNC 80/80, ARC/SHADOW 140/140, ASAN clean. (Found+deferred: a nested-owned-`List` ARC double-free; a cross-module `Status.toCode(x)` enum-method codegen gap — both in backlog.) | #7 ✅ | Tier 1.5(b) | ✅ done |
| 9 | **End-to-end conformance** — typed handler, route+query bind, `@fromRoute`+`@fromBody`, 404/405, auto-JSON. | #8 | route §7 | ~1 day |

### P2 — NovaDB integration (Kyte's own storage engine — first real driver; establishes the shared DB seam)

CLAUDE.md's reason-to-exist storage engine, and the **priority DB integration**. It goes first: it's the
native DB Kyte apps target, it's **locally/offline testable** (no third-party server), and — because NovaDB
carries its own SQL parser + query executor — the seam extracted here transfers directly to the SQL drivers.
NovaDB is a **separate project** built separately (CLAUDE.md); its binary protocol is tracked on the btree
side (`[[btree-readiness]]`, `btree/btree_readiness_plan.md`). These are the **Kyte-language-side** driver + benchmarks.

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 10 | **Shared abstract DB seam** — ✅ **LANDED** (`835abe6`, `b74f167`): new `src/std/data/db.ky` (`import db`). One typed cell `DbValue` (tag-struct, NOT enum-payload — that corrupts on f64/containers) for both bound params and decoded values; `DbType` mirrors the btree binary OIDs (+decimal, +Null); `Column`/`Row`(typed getters)/`ResultSet`/`ExecResult`/`DbError`; `Connection`(exec/query/close, typed params in, ResultSet out) + `Driver`(connect(dsn)) traits. Gates `63_db_seam` (typed accessors, exact decimal round-trip, NULL, nested ResultSet readback) + `64_db_connection` (mock backend queried through the Connection trait object). Surfaced+fixed a real trait-object ARC leak (widening leaked the fat pointer — affected DI/mediator too). Green FUNC 84/84, ARC 148/148, SHADOW 148/148, ASAN. | #3 ✅ | Tier 2 | ✅ done |
| 11 | **Kyte NovaDB driver** — ✅ **CODEC LANDED** (`aeadd17`): `data/btree/btreedb.ky` — typed `BTreeConnection impl db.Connection` + `BTreeDriver impl db.Driver` over the **binary** protocol (`[type:u8][len:u32 BE][payload]`). Went binary-first (reconciling the stale "JSON first" note — the btree side already shipped a verified binary path). Captures column OIDs from RowDescription → typed `DbType`; decodes text-format DataRow cells → typed `DbValue` (int/text/bool, NULL via -1 length); request frames sent binary-safe via `writeBytes`; client-side `$N` param substitution with the server's escaping. Gate `65_btreedb_codec` (offline byte-verified: frame encode, typed decode incl NULL, tag/error, params). **LIVE-VALIDATED end-to-end** against a running NovaDB (`:3009`): `connect` handshake → `CREATE`/`INSERT` (exec, `OK` tags) → `SELECT` (typed ResultSet, correct rows) → parameterized `WHERE id=$1` / `WHERE name=$1` (client-side substitution + escaping), all correct. **TYPED decode confirmed live**: after adding `QueryResponse.column_types` to the btree executor (schema-resolved per projection), `SELECT id,name,qty` returns typed columns → the driver's `getInt`/`getBool` yield real values (`sum(qty)=49` = arithmetic on decoded ints, not strings). Required a small btree-side wiring (route pg-style `'H'` startup to `proto/session.zig`; reconcile session/oidmap with the current executor; add `column_types` — btree is a separate project). Green FUNC 85/85, ARC 150/150, SHADOW 150/150, ASAN. **Remaining:** exact `decimal128` decode (text→decimal128 parser); extended Parse/Bind. | #10 ✅, #3 ✅ | Tier 2 | ✅ live typed |
| 12 | **YCSB benchmarks in Kyte** against NovaDB (explicit CLAUDE.md goal). | #11 | Tier 2 | ~3–5 days |

### P3 — SQL drivers (on the shared seam; PostgreSQL is the reference)

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 13 | **PostgreSQL** — ✅ **LANDED + LIVE-VERIFIED** (`cb4f228`): `data/sql/postgres.ky` — `PgConnection impl db.Connection` + `PgDriver` over the real pg v3 protocol (startup w/o type byte, cstring names/SQL, pg OIDs, `'R'` auth handshake, tagged `'E'` errors, DSN parse). Same seam as NovaDB → proves cross-backend abstraction. Live vs a running PostgreSQL: connect (trust) → CREATE/INSERT → SELECT with typed int + BOOL (getInt/getBool, sum over decoded ints) → parameterized `WHERE $1`. Gate `66_postgres_codec` (offline byte-verified). Green FUNC 86/86, ARC 152/152, SHADOW 152/152, ASAN. **The reference SQL driver** — its codec/auth/decode extract to MySQL/MSSQL. **Remaining:** extended query/prepared statements (server-side params); binary result format; MD5/SCRAM auth (this build disables MD5; SCRAM needs HMAC/PBKDF2 — crypto #16); `numeric`→exact decimal (text→decimal128 parser). | #3 ✅, #10 ✅ | Tier 2 | ✅ live (auth: trust/cleartext) |
| 14 | **MySQL** — ✅ **CODEC LANDED** (`b65a8ce`): `data/sql/mysql.ky` — `MyConnection impl db.Connection` + `MyDriver` over the MySQL protocol (u24-LE packet framing + seq, length-encoded ints/strings, Handshake v10 + HandshakeResponse41, COM_QUERY, column-def + text-row decode → typed DbValue). Third driver on the seam. Auth: `mysql_native_password` (SHA1 scramble) + `caching_sha2_password` fast path (SHA256) — added `crypto.sha1`/`mysqlNativeScramble`/`mysqlSha2Scramble` (runtime, golden-verified vs python hashlib). Gate `67_mysql_codec` (offline byte-verified) + `25_crypto` SHA-1 KAT. Green FUNC 87/87, ARC 154/154, SHADOW 154/154, ASAN. **NOT live-verified** (no MySQL server available) — connect/query is spec-followed but unproven live, unlike NovaDB/PostgreSQL. **Remaining:** live verification against a real MySQL; caching_sha2 full auth (TLS/RSA); prepared statements; EOF-deprecation handling. | #3 ✅, #10 ✅ | Tier 2 | ◑ codec done; live pending |
| 15 | **MSSQL** — TDS (PRELOGIN/LOGIN7/SQLBatch/RPC), TLS-during-handshake, token-stream decode. Most complex; do last. | #3, #10, TLS, crypto (#16) | Tier 2 | ~2–3 wk |

### P4 — Concurrency, stdlib, error model (additive, parallel-safe)

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 16 | **crypto** — SHA-256/HMAC/PBKDF2 (SCRAM/`caching_sha2` prerequisite), then AEAD. | — | Tier 3 | ~1 wk |
| 17 | **Error model `T \| Error`** (Zig-shaped: `try`/`catch`-expr/`errdefer`, two-register return) — replaces the broken `throw` longjmp. Spec-first (§5.5 rewrite). Fold in enum-payload-on-local fix (route §8.E1) + tuple type-checker half (§8.D1/2/4). | two-register return | route §8.C | ~2 wk |
| 18 | **Full channels → `async` utilities (`when_all`/`parallel_for`) → actor stdlib layer.** Runtime substrate is done; this is API/ergonomics. | runtime (done) | Tier 1 | ~2–3 wk |
| 19 | **serde completeness** (F4-6 fold into sema, decimal in JSON/YAML), **regex**. (NovaDB moved up to P2.) | seam | Tier 2/3 | ongoing |

### P5 — Toolchain self-sufficiency, FFI, tooling (separate axis, no ARC touch)

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 20 | **Toolchain self-sufficiency.** ✅ **Landed:** llvm-zig vendored (no GitHub fetch); `-Dstatic-llvm` static-links **native LLVM 22** (converted from the LTO drop via `llc`) → self-contained `kyte`, no `libLLVM.dylib`; `-Dinprocess-lld` compiles the native `liblld*.a` into `kyte` so it **links its own native executables via `lld::macho::link()` — no clang/ld shell-out** (gates green: FUNC 74/74, ARC 128/128 binaries run, SHADOW 128/128). The `--wasm` link is **also wired** to in-process `wasm-ld` and now works **end-to-end** — a kyte program compiles + links to a valid wasm module (the #23 codegen blockers are fixed: test-harness externs, i32→i64 `val_type` for f64, `--allow-undefined` for host-import runtime symbols). Default stays dynamic (fast dev). **Remaining for full "deploy only kyte":** replace the SDK-path lookup with **bundled macOS `.tbd` stubs** (currently uses the CLT/Xcode SDK); build the C++20 runtime with the bundled toolchain; ELF/Linux path (+musl+CRT). **Delivery invariant: users deploy only `kyte`.** | ✅ native LLVM 22 + LLD (native+wasm links in-process) | Tier 4 | ~2 days left |
| 21 | **`--wasm` conformance run** — ✅ **landed:** `./run.sh --wasm` compiles every case to wasm and gates a valid module, baseline-gated (`wasm-baseline.txt`) like `--arc`. **52/74 corpus compiles to wasm** (was 0/74 pre-#23), 0 fail. The 22-case climb came from: test-harness externs, i32→i64 `val_type` (f64), `--allow-undefined`, the **fnbox runtime-thunk-store** (function values in globals — +12), and **crypto/env host imports** (+2). **Remaining 2 not-yet** are genuine **concurrency/async gaps** (`10_async_go` = async coroutines unsupported in wasm; `11_channels` = native-runtime channels), needing a host-driven-async wasm story — not missing declarations. **Run harness landed** (`conformance/wasm-run.mjs`, Node): instantiates a module, supplies the 34 host imports, runs the `@test` exports. It **exposed a real execution bug** the link gate couldn't: modules compile+link but produce **garbage pointers at runtime** (a StringBuilder result comes back as `0x20_0000_001F`). Root cause: `val_type` i32→i64 (needed for f64) isn't matched by correct i32↔i64 handling of wasm's 32-bit pointers in `inttoptr`/`ptrtoint`/load-store. **Next #23 task: a wasm pointer-width audit** — until it lands, the 52 "compile" but don't *run* correctly. (Also fixed: `--initial-memory=128MB`, the bump heap put its arena at heap_start+32MB and never grew, so modules trapped.) | pointer-width audit | Tier 4 | ~2–3 days |
| 22 | **FFI** — `extern("lib") fn …`, C-ABI marshalling, ownership boundary. | linker (#20) | Tier 5 | ~1–2 wk |
| 23 | **Tooling** — LSP maturity, `kyte fmt`, package manager (finish F1-4), refresh `kyte init app` to the mediator API. | flagship (#8) | Tier 6 | ongoing |

### P6 — Lowest priority: MongoDB driver

Was the earlier "immediate ask"; **explicitly deprioritized** — NovaDB (Kyte's own engine) and the SQL
drivers come first. Kept on the roadmap because the wire + BSON + decimal path is offline-byte-verifiable
and the SCRAM work is shared with PostgreSQL, so it's cheap once crypto + the seam exist.

| # | Item | Deps | Ref | Effort |
|---|---|---|---|---|
| 24 | **MongoDB driver** — OP_MSG wire framing + BSON decimal round-trip + connect/`hello`/`insert`/`find` (offline-byte-verified first), SCRAM-SHA-256 follow-on. | #3, #10 (seam), crypto (#16) | Tier 2 | ~1 wk core |

### Foundation finishing (non-blocking polish — do opportunistically)

These do **not** gate anything above and none is memory-safety-critical (audited in `foundation-pending.md`):
F3-5 honest int local slots (i64→i32) + overflow trap · F1-6 Itanium mangling + F1-7 unresolved-call-is-error
· F1-4 real module scoping finish · function-visibility multi-segment-import hole.

**Critical dependency chain:** harness integrity (#1) → trustworthy gates · `kyte_socket_send_n` (#3) →
all drivers · F4-1 (#4) → generic traits (#6) → handler discovery (#7) → `get<T>`/`post<T>`/… (#8) → flagship ·
shared DB seam (#10) → NovaDB driver (#11) + Postgres/MySQL/MSSQL (#13–15) + MongoDB (#24) · crypto (#16)
→ SCRAM/auth · static LLVM + `liblld*.a` → linker (#20) → FFI (#22).
