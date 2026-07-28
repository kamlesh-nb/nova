# Standard Library & Web Framework

Nova's standard library is written **in Nova itself**, under `src/std/`. There is no precompiled stdlib
binary: the modules a program imports are compiled from source on every build, through the exact same
pipeline as user code. This keeps the language honest — the stdlib is the biggest real-world test of the
compiler, and a stdlib module that stops compiling is caught the same way user code is.

## Layout

```
src/std/
  collections/   list, map, set, string_builder, storage
  string  datetime  math  assert  traits  env  exception
  serde/         json, yaml, bson, source            (@serializable → generated __bind)
  data/          db (the DB seam), sql/pool, orm
  net/           asyncio, asynctls, tcp/*, tls, url
  web/           app, request, response, router, mediator, di, middleware, static_content,
                 controller, cors, csrf, session, recovery, rate_limit, client, circuit_breaker, ...
  concurrency/   fiber, channel, asyncchan, atomic, actor
  crypto/        sha, md5, base64, random, scram
  compress/      gzip
  text/          utf8, regex
  io/            file, dir     mem/  allocator, arena_allocator, memory
```

The set of stdlib modules the compiler knows how to resolve is registered in `main.zig` (`std_modules`);
`import <mod>` resolves to `src/std/<mod>.nova` (in-checkout), `~/.nova/std/<mod>.nova` (installed), or a
fetched package's `src/<mod>.nova` (`~/.nova/cache/<repo>`). Identity is the **canonical `src/std/…`
spelling** regardless of where the bytes are read from, so a module imported two ways is collected once.

## Representative subsystems

- **Collections** are monomorphized generics over `Storage<T>` (a typed slot array, not raw bytes), so ARC
  releases a *typed* field via the generated `__destruct_Storage_T`. `Map<K,V>` is open-addressing with
  linear probing and a pluggable `hashFn` (`Map<string,int>(16, string.hash)`).
- **serde** — `@serializable` structs get a compiler-generated `<Struct>__bind(ValueSource)` deserializer
  (source-generated and re-parsed — no reflection), recursive, over a `ValueSource` abstraction that backs
  JSON/form/BSON uniformly. The write side generates `<Struct>__dump` into a `ValueSink`. `decimal`
  round-trips exactly (BSON type `0x13`).
- **decimal128** is a first-class type: `m`-suffixed literals, exact arithmetic (no implicit int↔decimal),
  div/mod-by-zero traps. The runtime (`decimal.cpp`) does the BID codec + base-10 math.
- **crypto** is real wolfCrypt (SHA/HMAC/CSPRNG) plus base64 implemented in Nova; `random` exposes both a
  CSPRNG (for salts/nonces/tokens) and a seedable PCG32 `Prng` (for reproducible tests/sampling) — kept
  deliberately distinct so a reviewer can't mistake one for the other.
- **async utilities** — `net/asyncio` (`AsyncStream`, awaitable socket I/O), `net/asynctls`
  (`TlsStream`), channels, actors — the Nova-level surface over the runtime's async seam.

## The database seam — `data/db.nova`

Programs never talk to a concrete driver; they program against a trait seam so the backend is swappable:

```nova
pub trait Driver     { async fn connect(self, dsn: string): Connection; }
pub trait Connection {
    async fn exec(self, sql: string, params: List<DbValue>): ExecResult;
    async fn query(self, sql: string, params: List<DbValue>): ResultSet;
    fn close(self): void;
    async fn prepare(self, sql: string): int;
    async fn queryPrepared(self, stmt: int, params: List<DbValue>): ResultSet;
    async fn execPrepared(self, stmt: int, params: List<DbValue>): ExecResult;
}
```

`exec`/`query`/`prepare` are `async fn` — a driver's socket recv **parks the coroutine** (non-blocking).
`DbValue` is a tag-struct union of SQL value kinds; `ResultSet`/`Row` decode typed cells. The concrete
drivers (Postgres/MySQL/MSSQL/BTreeDB/MongoDB) are **separate published packages** (`nova-<name>`),
fetched via `nova get`; only the seam and the generic connection pool live in std. A repository just
constructs a driver and awaits it:

```nova
let conn = await driver.connect(dsn);
let rs   = await conn.query("SELECT name FROM products WHERE id = $1", params);
```

## The web framework — `web/app.nova`

The App is a **minimal-API, MediatR-style** HTTP framework on the async runtime. Three responsibilities are
kept separate:

- **Registration** (`app.get<TReq>(path)` / `post`/…) records `(method, path, type-key)` — plain data, no
  dispatch. The type key is `serde.typeName<TReq>()`, so a route and its handler agree *by type*.
- **Handlers** (`MessageHandler.handle(src): Response`) bind the request from a `ValueSource` themselves —
  visible, debuggable Nova, no hidden binder — and return a `Response`.
- **Dispatch** (`App.dispatch`) is the one request→Response site: match the route, build the source, resolve
  the handler by type-key from the `AppMediator`, run it.

The whole chain — `handleConn` (the async accept-loop coroutine) → `App.respondMiss` → `App.dispatch` →
`AppMediator.send` → `MessageHandler.handle` → a repository's async DB call — is **`async fn` end to end**,
so a request is served on one coroutine with no nested block-drive. This is what makes per-request DB work
without deadlocking (see the block-drive guard in [03-runtime.md](03-runtime.md)).

Other pieces: **DI** (`web/di.nova` — `ServiceProvider`/`ServiceScope`, singleton/scoped/transient,
constructor injection via `handleFrom<T>`), a request pipeline (middleware/pre/post/exception),
`useStatic` (LRU-cached static files), gzip content-negotiation, inbound TLS (`app.useTls(cert, key)` →
in-process HTTPS), and W6 hardening (chunked decode, per-read timeouts, 431/413 caps).

### The server loop

`App.run` calls `holdReactors()` then block-drives the async accept fan-out: one SO_REUSEPORT accept loop
per reactor (reactor 0 inline, 1..N-1 spawned and pinned). The kernel load-balances new connections across
the per-reactor acceptors; each connection's handler stays on its accepting reactor, so per-reactor
connection pools reuse safely. The request loop frames HTTP directly on the receive buffer (zero-copy) and
serves a cacheable GET from a response cache without building the request string or dispatching.

## Templates & scaffolding

`nova init web|desktop` scaffolds an app (`src/templates.zig`, `src/main.zig`) in an ASP.NET-style,
vertical-slice layout: features under `Features/<Area>/<UseCase>/{command,query,handler,validator}`, an
`Infrastructure/` for repositories over the `db` seam, and a `main.nova` composition root that registers
handlers + routes and calls `app.run(port)`. The `lang/flagship` app is the reference.
