# Standard Library and Web Framework

Kyte's standard library is written **in Kyte itself**, under `src/std/`. There is no precompiled standard
library binary: the modules that a program imports are compiled from source on every build, through the
very same pipeline as user code. This keeps the language honest, since the standard library is the largest
real world test of the compiler, and a standard library module that ceases to compile is caught in the
same manner as user code.

## Layout

```
src/std/
  collections/   list, map, set, string_builder, storage
  string  datetime  math  assert  traits  env  exception
  serde/         json, yaml, bson, source            (@serializable produces a generated __bind)
  data/          db (the database seam), sql/pool, orm
  net/           asyncio, asynctls, tcp/*, tls, url
  web/           app, request, response, router, mediator, di, middleware, static_content,
                 controller, cors, csrf, session, recovery, rate_limit, client, circuit_breaker, and so on
  concurrency/   fiber, channel, asyncchan, atomic, actor
  crypto/        sha, md5, base64, random, scram
  compress/      gzip
  text/          utf8, regex
  io/            file, dir     mem/  allocator, arena_allocator, memory
```

The set of standard library modules that the compiler knows how to resolve is registered in `main.zig`
(the `std_modules` list). An `import <mod>` resolves to `src/std/<mod>.ky` (in checkout), or
`~/.kyte/std/<mod>.ky` (installed), or a fetched package's `src/<mod>.ky` (`~/.kyte/cache/<repo>`).
The identity is the **canonical `src/std/...` spelling**, irrespective of the location from which the
bytes are read, so that a module imported in two ways is collected only once.

## Representative Subsystems

- **Collections** are monomorphised generics over `Storage<T>` (which is a typed slot array, and not raw
  bytes), so that ARC releases a *typed* field via the generated `__destruct_Storage_T`. `Map<K,V>` is open
  addressing with linear probing and a pluggable `hashFn` (as in `Map<string,int>(16, string.hash)`).
- **serde.** A `@serializable` struct receives a compiler generated `<Struct>__bind(ValueSource)`
  deserialiser (which is source generated and re-parsed, so there is no reflection), recursive, over a
  `ValueSource` abstraction that backs JSON, form, and BSON uniformly. The write side generates
  `<Struct>__dump` into a `ValueSink`. A `decimal` round trips exactly (as BSON type `0x13`).
- **decimal128** is a first class type: `m` suffixed literals, exact arithmetic (with no implicit int to
  decimal conversion), and div and mod by zero traps. The runtime (`decimal.cpp`) performs the BID codec
  and the base-10 mathematics.
- **crypto** is real wolfCrypt (SHA, HMAC, CSPRNG), along with base64 implemented in Kyte. `random` exposes
  both a CSPRNG (for salts, nonces, and tokens) and a seedable PCG32 `Prng` (for reproducible tests and
  sampling); these two are kept deliberately distinct, so that a reviewer cannot mistake one for the other.
- **async utilities.** `net/asyncio` (with `AsyncStream` and awaitable socket I/O), `net/asynctls` (with
  `TlsStream`), the channels, and the actors are the Kyte level surface over the runtime's async seam.

## The Database Seam, `data/db.ky`

Programs never talk to a concrete driver; they program against a trait seam, so that the backend is
swappable.

```kyte
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

`exec`, `query`, and `prepare` are `async fn`, so that a driver's socket recv **parks the coroutine** (in
a non blocking manner). `DbValue` is a tag struct union of the SQL value kinds; `ResultSet` and `Row`
decode the typed cells. The concrete drivers (Postgres, MySQL, MSSQL, NovaDB, MongoDB) are **separate
published packages** (`kyte-<name>`), fetched via `kyte get`; only the seam and the generic connection pool
reside in std. A repository merely constructs a driver and awaits it.

```kyte
let conn = await driver.connect(dsn);
let rs   = await conn.query("SELECT name FROM products WHERE id = $1", params);
```

## The Web Framework, `web/app.ky`

The App is a **minimal API, MediatR style** HTTP framework built on the async runtime. Three
responsibilities are kept separate.

- **Registration** (`app.get<TReq>(path)`, `post`, and so on) records `(method, path, type-key)`, which is
  plain data with no dispatch. The type key is `serde.typeName<TReq>()`, so that a route and its handler
  agree *by type*.
- **Handlers** (`MessageHandler.handle(src): Response`) bind the request from a `ValueSource` themselves,
  which is visible, debuggable Kyte with no hidden binder, and return a `Response`.
- **Dispatch** (`App.dispatch`) is the one request to Response site: it matches the route, builds the
  source, resolves the handler by type key from the `AppMediator`, and runs it.

The whole chain, that is, `handleConn` (the async accept loop coroutine), then `App.respondMiss`, then
`App.dispatch`, then `AppMediator.send`, then `MessageHandler.handle`, and finally a repository's async
database call, is **`async fn` end to end**, so that a request is served on one coroutine with no nested
block drive. This is what makes per-request database access work without deadlocking (please see the block
drive guard in [03-runtime.md](03-runtime.md)).

There are other pieces as well: **DI** (`web/di.ky`, providing `ServiceProvider` and `ServiceScope`,
singleton, scoped, and transient lifetimes, and constructor injection via `handleFrom<T>`), a request
pipeline (middleware, pre, post, and exception), `useStatic` (LRU cached static files), gzip content
negotiation, inbound TLS (`app.useTls(cert, key)`, which gives in process HTTPS), and W6 hardening
(chunked decode, per-read timeouts, and 431 and 413 caps).

### The Server Loop

`App.run` calls `holdReactors()` and thereafter block drives the async accept fan out: one SO_REUSEPORT
accept loop per reactor (reactor 0 inline, and reactors 1 to N minus 1 spawned and pinned). The kernel
load balances the new connections across the per-reactor acceptors; each connection's handler stays on its
accepting reactor, so that the per-reactor connection pools reuse safely. The request loop frames HTTP
directly on the receive buffer (that is, zero copy), and serves a cacheable GET from a response cache
without building the request string or dispatching.

## Templates and Scaffolding

`kyte init web|desktop` scaffolds an app (see `src/templates.zig` and `src/main.zig`) in an ASP.NET style,
vertical slice layout: features under `Features/<Area>/<UseCase>/{command,query,handler,validator}`, an
`Infrastructure/` for repositories over the `db` seam, and a `main.ky` composition root that registers
the handlers and routes and calls `app.run(port)`. The `lang/flagship` app is the reference.
