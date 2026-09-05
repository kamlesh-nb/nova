# DB Production-Readiness Roadmap

**Purpose.** The Kyte DB drivers (NovaDB, PostgreSQL, MySQL, MSSQL, MongoDB) are protocol-complete and
live-verified, but they are *beta*, not production. This document is the plan to close that gap — the operational
layer (pooling, transactions, timeouts, retries, real parameterization) that turns "four drivers that work in a
demo" into "a data layer you would ship." **MongoDB is the first driver targeted for production readiness**
(`packages/nova-mongodb`) — it is already an isolated package, its SCRAM auth is done, and its document model
sidesteps the SQL-string-injection concern, so it is the cleanest place to establish the production patterns that
then port to the SQL drivers.

Tracking convention mirrors `execution-plan.md`: each item has a **DoD** and a **Status** (⬜ TODO · ◑ partial ·
✅ done). Nothing is ✅ until its DoD is met and gated against a real server.

---

## 1. Where we are (honest current state, 2026-07-22)

**Solid foundation:** five real wire protocols live-verified; typed decode incl. **exact decimal128**;
**memory-safe** (ARC + ASAN clean on live paths); one clean `db.Driver`/`db.Connection` seam (Mongo uses its own
richer surface). MongoDB (`packages/nova-mongodb`): OP_MSG + BSON (binary/embedded/decimal128) + SCRAM-SHA-256,
`hello`/`insert`/`find` live vs `mongod`.

**The gaps that make it beta, not production** (apply to ALL drivers unless noted):
1. **No connection pooling** — every connect is a fresh TCP + auth handshake.
2. **No real prepared statements (SQL drivers)** — client-side string substitution → injection surface + no plan
   caching. *(Mongo is exempt in the SQL sense — commands are BSON docs — but has the analogous "operator
   injection" risk when a query document is built from untrusted input.)*
3. **No transaction API** — autocommit only; no managed scope, rollback, or isolation control.
4. **No timeouts / cancellation / reconnect** — a blocking `recv` hangs forever on a stalled server.
5. **Unsafe concurrency by construction** — one socket + one blocking reader per connection; sharing corrupts the
   stream. Safe concurrency *requires* the pool that does not exist yet.
6. **Auth breadth gaps** — Mongo: only SCRAM-SHA-256 (no SCRAM-SHA-1 / x.509 / cloud-IAM). SQL: MySQL full-auth,
   PG SCRAM, MSSQL NTLM all absent.
7. **Full result-set materialization** — no cursors/streaming; a large query OOMs. *(Mongo especially: `find`
   returns a CURSOR — the current driver reads only the first batch.)*
8. **No TLS to Mongo yet** — but this is easy: unlike TDS (which tunnels TLS in PRELOGIN), MongoDB does plain TLS
   over the socket, so the existing fd-based `kyte_tls_new`/`handshake`/`read`/`write` applies directly.
9. **Thin error taxonomy + no observability** — protocol errors are partially surfaced; no command monitoring,
   metrics, or logging hooks.

---

## 2. Definition of a production-ready driver (the checklist)

A driver is "production-ready" when ALL of these hold, verified against a real server (and, for Mongo, a real
replica set / Atlas):

- **Pooling** — bounded pool (min/max/idle), checkout/checkin, health check + lifecycle (max-age, max-idle),
  fair waiting with a checkout timeout.
- **Concurrency-safe** — a checked-out connection is used by exactly one operation at a time; the pool is the
  isolation boundary; N concurrent callers → N pooled connections, no stream corruption.
- **Timeouts everywhere** — connect timeout, socket read/write timeout, per-operation/server timeout
  (`maxTimeMS` for Mongo), and honest cancellation (or at least a hard deadline that closes the socket).
- **Resilience** — dead-socket never segfaults (done); transient-error retry with backoff; reconnect/eviction of
  broken connections; **retryable reads/writes** where the protocol supports it (Mongo 3.6+).
- **Safe parameterization** — SQL: server-side prepared statements (values sent out-of-band, never concatenated).
  Mongo: a typed command/query builder so untrusted values cannot inject operators.
- **Transactions** — managed scope with commit/rollback, isolation/read-write-concern control, and Mongo sessions
  (`lsid`) + multi-document transactions.
- **Streaming results** — cursors (Mongo `getMore`/`killCursors`; SQL server-side cursors or at least bounded
  fetch) so large result sets do not materialize in memory.
- **Auth breadth** — the auth mechanisms real deployments use (Mongo: SCRAM-SHA-256/1, x.509; SQL: the driver's
  primary mechanism at minimum).
- **TLS** — verified-peer TLS to the server (Atlas mandates it).
- **Typed errors** — a structured error taxonomy (server code/message vs network vs write-concern vs timeout) the
  caller can branch on.
- **Observability** — command-started/succeeded/failed hooks; enough to build metrics + slow-query logs.
- **Test depth** — beyond happy-path YCSB: failure injection (kill the server mid-op), a soak run (hours,
  leak-watched), and adversarial/fuzz input on the codec.

---

## 3. MongoDB-first plan (phased)

MongoDB is the pilot. Each phase has a DoD gated against a live `mongod` (standalone first, then a 3-node replica
set), leak-checked under ARC. Phases are ordered by "what unblocks a real app soonest."

### M1 — TLS + Atlas connectivity ⬜  *(fast; unblocks cloud)*
Wire the existing fd-based `kyte_tls_*` (verify_peer, SNI) into the Mongo `TcpClient` path; add a `tls=true` /
`mongodb+srv://` connection-string option. **DoD:** connect + `hello` + `insert`/`find` over TLS against a TLS
`mongod` and against a MongoDB Atlas free-tier cluster (the real-world bar). *(No TDS-style tunneling needed —
Mongo is plain TLS.)*

### M2 — Cursors (getMore / killCursors) ⬜  *(correctness: today `find` truncates to one batch)*
A `find` reply carries a `cursor.id` + `firstBatch`; the driver must iterate `getMore` until the cursor is
exhausted and `killCursors` on early close. **DoD:** a `find` returning > one batch (e.g. 10k docs) returns ALL
docs; early break kills the cursor server-side (verify via `$currentOp`/server cursor count); ARC clean.

### M3 — Connection pool ⬜  *(the concurrency + performance keystone)*
A bounded pool: min/max size, idle reaping, max-connection-age, per-checkout wait timeout, health check on
checkout. A `MongoClient` owns the pool; `client.database(...).collection(...)` operations check out → use →
check in. **DoD:** N concurrent callers run correctly with ≤ max connections, no stream corruption (a
concurrency test), pool metrics exposed; broken connections evicted, not reused.

### M4 — Timeouts + resilience + retryable writes ⬜
Connect/socket timeouts; per-op `maxTimeMS`; on a transient network error, evict the connection and (for
idempotent/retryable ops) retry once per the MongoDB retryable-writes spec (`txnNumber` on a session). **DoD:** a
killed connection mid-`find` surfaces a typed timeout/network error (no hang, no segfault); a retryable `insert`
survives a single transient blip; a `maxTimeMS` breach returns the server's timeout error.

### M5 — Write concern / read concern + typed errors ⬜
`w`/`wtimeout`/`j` write concern and `readConcern` on commands; parse `writeErrors`/`writeConcernError`/command
`errmsg`+`code` into a structured `MongoError` taxonomy (network vs command vs write vs write-concern vs timeout).
**DoD:** `w:majority` acknowledged writes; a duplicate-key insert yields a typed error with the code; a
write-concern timeout is distinguishable from a command error.

### M6 — Sessions + multi-document transactions ⬜  *(needs a replica set)*
Logical sessions (`lsid`), `startTransaction`/`commitTransaction`/`abortTransaction`, causal consistency
(`afterClusterTime`). **DoD:** a two-collection transaction commits atomically and rolls back on error against a
3-node replica set; a conflicting txn aborts cleanly.

### M7 — Topology / replica-set awareness (SDAM) ⬜  *(production Mongo is rarely standalone)*
Server Discovery And Monitoring: parse `mongodb+srv`/seed list, monitor member `hello`, track primary/secondary,
route by **read preference** (`primary`/`secondaryPreferred`/…), fail over on primary step-down. **DoD:** writes
go to the primary, `secondaryPreferred` reads hit a secondary, and a forced primary step-down is followed without
a client restart.

### M8 — Auth breadth + BSON completeness + query builder ⬜
Add SCRAM-SHA-1 and x.509 auth; fill BSON type gaps (ObjectId, UTC datetime, arrays, boolean, null, regex,
timestamp, int32/int64/double — beyond the binary/embedded/decimal128 already done); a typed, injection-safe
command/query builder (no raw untrusted operator interpolation). **DoD:** x.509 auth against a configured server;
every BSON type round-trips; a query built from user input cannot inject `$where`/operators.

### M9 — Observability + production test suite ⬜
Command-monitoring hooks (started/succeeded/failed); a failure-injection test (kill `mongod` mid-op), a
multi-hour soak (leak-watched), and a codec fuzz pass. **DoD:** the soak run is leak-free; failure injection
produces typed errors, never a crash/hang; monitoring hooks fire.

---

## 4. The typed-query / micro-ORM layer (where it fits — cap, not foundation)

A Dapper-style materializer (row/doc → typed struct) is **ergonomics on top of a hardened driver, not a
substitute for it.** It reuses the existing serde machinery: the compiler already generates
`<Struct>__bind(src: ValueSource)` for `@serializable` structs, and `ValueSource` is already implemented for
JSON/form/multipart. A **`DocSource impl ValueSource`** (Mongo BSON doc → `ValueSource`) makes
`Query__bind(DocSource(doc))` materialize a typed struct with **zero reflection**, compiled at build time. The
mirror (`__toBson` / struct → command params) gives injection-safe binding. **This lands AFTER M2–M5** so it
inherits cursors, pooling, timeouts, and typed errors rather than papering over their absence. Prototyping the
**read-side** materializer (`find → List<T>`) early is safe (reads carry no injection risk) and validates the
shape.

---

## 5. Sequencing & priorities

1. **M1 (TLS/Atlas) + M2 (cursors)** first — they make the driver *usable against real data*, and are cheap
   (TLS reuses `kyte_tls_*`; cursors are a known protocol loop).
2. **M3 (pool) + M4 (timeouts/resilience)** — the safety-and-scale keystone; nothing is production without them.
3. **M5 (concern/errors)** — correctness of durability + a real error surface.
4. Read-side **micro-ORM prototype** (§4) — high value, low risk, proves the ergonomic layer.
5. **M6 (transactions) + M7 (topology)** — the replica-set-dependent features; land once a 3-node set is available.
6. **M8 (auth/BSON/builder) + M9 (observability/soak)** — breadth + the production test bar.

**Then port the patterns to the SQL drivers** (D6-expanded): pooling and timeouts are protocol-agnostic and reuse
directly; prepared statements are the SQL-specific must (server-side `Parse`/`Bind`/`Execute` for PG, `COM_STMT_*`
for MySQL, `sp_prepexec`/RPC for MSSQL) — the injection + plan-cache fix. Transactions map to `BEGIN/COMMIT`.

---

## 6. Non-goals (explicitly out of scope)

- A full ORM (LINQ-style query generation, change tracking, migrations, lazy loading) — Kyte targets the *micro*-
  ORM point (SQL/command in, typed objects out). Migrations/change-tracking can be separate libraries later.
- ODM/aggregation-pipeline DSLs beyond a thin typed builder.
- Multi-driver distributed transactions / 2PC.
