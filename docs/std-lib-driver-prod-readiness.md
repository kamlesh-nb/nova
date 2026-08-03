# Nova Standard Library + DB Driver Production Readiness

Status date: 2026-08-03
Scope: the Nova standard library (`lang/src/std/`, 126 files, ~23k LOC) and the five
database driver packages (`packages/nova-{postgres,mysql,mssql,mongodb,btreedb}`) plus the
shared DB seam (`data/db.nova`, `data/sql/pool.nova`, `data/orm.nova`).
Method: per-area source audit, evidence cited as `file:line`. Grades are
Prototype < Alpha < Beta < Prod.

This document is an assessment, not a task list with commitments. The prioritized roadmap at
the end is the recommended order of work; nothing here has been changed yet.

---

## 1. Grade summary

### DB drivers + seam

| Component | Grade | One-line justification |
|---|---|---|
| DB seam (`data/db.nova`) | Alpha | No transaction API, no error channel, lossy `DbValue`, client-side param interpolation. |
| Pool (`data/sql/pool.nova`) | Alpha | No max-open cap, no validation-on-borrow, no reconnect, not concurrency-safe. |
| Micro-ORM (`data/orm.nova`) | Alpha | Read side + thin `insert<T>`; no update/delete/upsert, no PK, scalar-only binding. |
| nova-postgres | Alpha | Correct codec + SCRAM + prepared stmts, but no TLS, errors swallowed, timestamp/bytea broken. |
| nova-mysql | Alpha | Solid codec + auth math, but no TLS at all, errors swallowed, text-datetime decode wrong. |
| nova-mssql (TDS) | Alpha | Real sp_prepare + tunneled TLS, but cert verification off, FLOAT/temporal decode to NULL, no PLP. |
| nova-btreedb | Alpha | Real typed binary protocol + defensive framing, but hardcoded creds, `'E'` frames swallowed. |
| nova-mongodb | Prototype | `hello`/auth never wired into `connect`, no cursor/getMore, BSON lacks ObjectId/datetime. |

### Standard library (non-DB)

| Area | Grade | Note |
|---|---|---|
| Web framework | Beta | The most mature area: DI, mediator, middleware, unified router, CORS/CSRF/session/rate-limit, TLS server, multi-core reactor. |
| Crypto / TLS | Beta | TLS 1.3 both roles (resumption, 0-RTT, KeyUpdate); chain verification. Gaps: no OCSP/CRL, TLS 1.2 server, mTLS. |
| IO / FS / OS | Beta | file/dir/process complete incl. isolated spawn + full Windows backend. Gaps: stat/metadata, recursive mkdir, tree walk, mmap. |
| String / JSON | Beta | Solid split/join/slice/parse + JSON DOM. Gaps: format/printf, padStart, streaming/error-reporting parse. |
| Serde (yaml, bson) | Alpha | yaml + bson complete-ish but subset; no streaming, weak error reporting. |
| Collections | Alpha | Generic list/map/set but bare: no sort/contains/indexOf, no deque/heap/ordered map. |
| Text / Unicode | Alpha | utf8 codepoints + Thompson-NFA regex; no normalization/grapheme/casefold, no backrefs/lookaround. |
| Concurrency | Alpha | atomic + generic channel; `asyncchan` int-only, `whenAny` a stub; no select/WaitGroup/mutex/cancel. |
| Datetime / Math | Alpha | epoch/UTC only (no timezones); math has no trig/log10/bigint. Decimal (built-in) is Prod. |
| Observability / Config / HTTP-2 / WebSocket | Missing | No metrics, no tracing, no structured logging framework, no layered config, no HTTP/2, no WS. |

---

## 2. Cross-cutting blockers (shared across every driver)

These are the patterns that repeat across all five drivers and the seam. Fixing them once at
the seam/shared layer lifts every driver at once, so they are the highest-leverage work.

### C1. Errors are silently swallowed on the live path (correctness + operability blocker)
Every SQL driver implements an error decoder and then never calls it on the live query path.
- postgres: `decodeError` exists (`postgres.nova:262-274`) but `query`/`exec` never inspect the
  `'E'` frame; a failed query returns an empty ResultSet with `tag==""` (`postgres.nova:387-409`).
  Prepared paths only `break` on `'E'` (`:447,471,489`).
- mysql: `decodeErr` fully implemented + tested (`mysql.nova:499-510`) but live paths return only
  `tag="ERROR"` / `ExecResult(0,"ERROR")` (`:618,649,711,743`); connect-time auth ERR ignored.
- mssql: login failure logs to stderr and still returns a live-looking connection (`mssql.nova:877`).
- btreedb: `query`/`exec` loops do not handle frame type 69 (`btreedb.nova:353-363,371-377`).
- mongodb: `runCommand` never inspects `ok:0`/`errmsg`/`code` (`mongodb.nova:178-184`).
Impact: applications cannot distinguish success from failure, cannot log a SQLSTATE/message, and
`ResilientPool` only guesses failure from an empty tag (which also misfires on legitimately empty
results). This is the single most important fix and it belongs at the seam (a `DbError` return or
out-channel on `query`/`exec`/prepared).

### C2. Transport security is absent or unverified (security blocker)
- No TLS at all: postgres (no SSLRequest), mysql (no CLIENT_SSL), mongodb, btreedb. `net/aio.nova`
  has no TLS entry point (`aio.nova:70-124`), so there is nothing to drop in. Cleartext passwords and
  data on the wire; mysql even sends the RSA-full-auth password over plaintext.
- TLS present but unverified: mssql tunnels the TLS handshake in TDS packets but forces
  `handshakeOk=true` and never validates the certificate (`mssql.nova:824-854`) -- unconditional
  TrustServerCertificate, MITM-exploitable, no opt-in.
Note: the stdlib already has verified-TLS client BIOs, a truststore PEM loader, and full x509 chain
verification (`crypto/x509.nova`, `crypto/tls/truststore.nova`); the drivers simply do not use them.

### C3. No transaction API on the seam (correctness blocker)
The `Connection` trait has exec/query/prepare/queryPrepared/execPrepared/close/setTimeout only
(`db.nova:117-133`) -- no begin/commit/rollback, no savepoints, no isolation levels, no
rollback-on-drop. Callers must hand-issue `exec("BEGIN")` with no guarantee. On mssql this is worse:
the TDS transaction descriptor is hardcoded 0 and ENVCHANGE is ignored (`mssql.nova:179,199,577`),
so an explicit BEGIN TRAN will not bind the right descriptor.

### C4. Parameterization is not enforced; `$N` substitution is single-digit
`query`/`exec` do client-side string interpolation via `substituteParams` on postgres/mysql/btreedb,
handling only `$1..$9` (`postgres.nova:516-537`, `mysql.nova:782`, `btreedb.nova:101-124`). `$10+`
silently mis-substitute. The ORM `insert<T>` emits `$1..$N` into `exec` (`orm.nova:92-112`), so any
struct with more than nine columns is broken, and on non-PG drivers `$N` is not even a placeholder.
Only the `*Prepared` methods use true server-side binding. Blob params are escaped as text
(`db.nova:51`, `postgres.nova:116,510`), so binary with NUL/quotes is unsafe on the simple path.

### C5. Temporal + special types decode incorrectly (silent data corruption)
- postgres: Timestamp decoded with `parseI64` on an ISO string -> reads `2024` only
  (`postgres.nova:224`); bytea hex `\x` not decoded (`:231`); uuid/json/arrays fall through to raw text.
- mysql: text-protocol datetime does `parseI64("2024-01-01 10:00:00")` (`mysql.nova:277,97-98`),
  disagreeing with the (correct) binary path; binary drops microseconds (`:466`).
- mssql: FLOAT/FLT4/FLT8 decode to NULL (`mssql.nova:470-479`); DATE/TIME/DATETIME/DATETIME2/
  DATETIMEOFFSET not decoded at all; no PLP so nvarchar(max)/varbinary(max) desync the stream (`:441`);
  GUID returned as raw bytes.
- This ties back to C6 (the `DbValue` model has a Timestamp tag with no constructor/accessor,
  `db.nova:44-51`, and no date/time/uuid/json types).

### C6. `DbValue` model is lossy and incomplete
Single struct with `i:long/f:double/dec:decimal/s:string` (`db.nova:20-33`). Missing dedicated
date/time, UUID, JSON. NULL is a tag but accessors return 0/"" silently (no null-vs-zero on read,
`db.nova:35-37`). `asInt` truncates long->int. Blob is stored in the string slot.

### C7. Pool is not production-grade
`Pool` (`pool.nova:7-68`): no max-open/total cap (opens a new conn whenever idle is empty,
`:24-32`), no acquire timeout, no wait queue/fairness, no validation-on-borrow/ping, no
maxLifetime/idle-eviction, no leak detection, and `idle`/`live` mutated without synchronization.
No reconnect anywhere -- a dead pooled connection is handed out and fails. `ResilientPool` adds a
circuit breaker + out-of-band HTTP health probe but keys failure on the empty-tag heuristic (C1).

### C8. Concurrency: one in-flight request per connection, unguarded
Every driver is a single request/response channel over a shared reader buffer with no locking.
Two coroutines on the same connection interleave frames and corrupt the stream. Safety depends
entirely on the pool handing one connection per coroutine, and nothing enforces exclusive checkout.

### C9. No query timeout / cancellation
Only a per-recv socket deadline exists (`setTimeout` -> io layer). No connect timeout, no
statement/query timeout, no cancellation (PG CancelRequest, TDS ATTENTION). A runaway query cannot
be cancelled, and on mssql a timeout permanently desyncs the stream (no ATTENTION handling).

### C10. Verification gap: everything beyond the byte codec is unproven in-repo
Every driver has offline codec tests only. Live connect/query/auth/TLS paths are exercised by no
in-repo automated test and cannot run from a bare clone (per `lang/CLAUDE.md`). Several drivers carry
contradictory liveness claims (mysql header says "not yet live-verified" while test 109 says "verified
LIVE against MySQL 9"). Treat all live behavior as unproven until an integration harness exists.

---

## 3. DB seam, pool, ORM

Grade: Alpha. Files: `data/db.nova` (133), `data/sql/pool.nova` (135), `data/orm.nova` (131).

- Connection trait: 6 async + 2 sync methods (`db.nova:117-133`). No transactions (C3), no batch,
  no streaming/cursor (results fully materialized, `db.nova:77-93`), no error channel (C1).
- DbValue: lossy + incomplete (C6).
- ORM read side: `queryAs<T>`/`queryOne<T>` via `RowSource impl ValueSource` (`orm.nova:10-68`),
  case-insensitive column index; scalar-only (`getChild` returns self, arrays/child -> empty,
  `orm.nova:37,43-47`). Write side: `insert<T>` exists (`orm.nova:92-112`) but emits `$N` (C4) and
  has no update/delete/upsert/select-builder/PK handling; `ParamSink` cannot round-trip a null field.
  No migrations anywhere.
- Pool: see C7.
- Missing for prod: retries (breaker only fails fast), query-level timeouts/cancellation,
  observability hooks (no metrics/tracing/logging in the seam or pool), prepared-statement cache
  bounding (per-connection, unbounded, lost on discard), named parameters, enforced parameterization.

---

## 4. Per-driver deep dives

### 4.1 nova-postgres -- Alpha
Strengths: correct startup + framing (64MB guard, buffered reader), cleartext + SCRAM-SHA-256 auth
with CSPRNG nonce, extended-query/prepared machinery with a per-connection dedup cache
(`postgres.nova:429-452`), exact decimal128.
Blockers: no TLS (C2); errors swallowed (C1); SCRAM server signature never verified though the helper
exists (`postgres.nova:572-573`, `crypto/scram.nova:44`); timestamp/bytea decode wrong (C5); MD5 auth
unsupported (`:573-574`); no LISTEN/NOTIFY, COPY, cursor/streaming, or transaction API; pool + concurrency
per C7/C8; `$1..$9`-only + literal-blind substitution (C4).

### 4.2 nova-mysql -- Alpha
Strengths: handshake v10 parse, full text-protocol result decode with correct EOF handling,
binary-protocol prepared statements with correct NULL bitmap, mysql_native_password +
caching_sha2_password (fast + RSA full-auth OAEP) auth math golden-tested, deliberate ARC/leak care.
Blockers: no TLS at all (C2) -- RSA-full-auth password over plaintext; errors swallowed (C1);
text-datetime decode wrong and disagreeing with binary path (C5); no >=16MB packet reassembly/split
(desyncs on large rows, `mysql.nova:578-582`); multi-resultset unsupported (stored procs desync);
sha256_password unsupported; prepared-stmt COM_STMT_CLOSE dead code (server-side leak); affected_rows
truncated to int; no reconnect/liveness (C7); params sent as text-typed VAR_STRING only.

### 4.3 nova-mssql (TDS 7.4) -- Alpha
Strengths: PRELOGIN/LOGIN7/SQLBatch, real server-side sp_prepare/sp_execute RPC, tunneled TLS
handshake coalesced into single PRELOGIN packets, broad TOKEN-stream decode, exact decimal128,
solid inbound multi-packet reassembly.
Blockers: TLS cert verification disabled unconditionally (C2, `mssql.nova:824-854`); FLOAT + all
temporal types decode to NULL/absent (C5, `:470-479`); no PLP so max-types desync (`:441`); login
errors surface as live connections (C1, `:877`); no outbound packet chunking so large messages violate
framing (`:84-90`); prepared params all NVARCHAR(4000) + sp_unprepare never called (handle leak,
`:195,211,768`); no ATTENTION/cancel + timeout desyncs stream (C9); transaction descriptor hardcoded 0
+ ENVCHANGE ignored (C3); no sp_reset_connection on pool reuse (leaked session state); Windows/NTLM/
Kerberos/AAD auth all absent; unknown-token hard-stop truncates results (`:600`).

### 4.4 nova-btreedb -- Alpha
Strengths: genuine Postgres-convention binary protocol (typed OID cell decode, big-endian framing),
defensive length guard against desync (`btreedb.nova:313`), buffered reader with compaction + dtor
freeing (past-leak fix), exact decimal128, documented reason for abrupt close (avoids nested-drive
deadlock).
Blockers: hardcoded `admin`/`nova` credentials, DSN credentials ignored, no auth exchange
(`btreedb.nova:419`); `'E'` error frames swallowed (C1); prepared statements emulated via `$N` text
substitution, single-digit only, no real Parse/Bind (`:101-124,391-408`); no TLS (C2); no transaction
API (C3). Most mature of the two non-SQL drivers.

### 4.5 nova-mongodb -- Prototype
Strengths: offline OP_MSG round-trip, find/insert command shapes, SCRAM-SHA-256 payload framing, and
the RFC 7677 proof vector are all correct and tested.
Blockers: `hello`/isMaster never sent -- `connect` opens the socket and returns (`mongodb.nova:237-247`);
`authenticate` is dead code from the seam's view (never called by connect); no cursor -- `find` reply
`cursor.firstBatch`/id never read, no getMore/killCursors; `query`/`exec` are stubs returning a synthetic
1/0 row, never actual documents (`:200-214`); BSON lacks ObjectId(0x07), UTC datetime(0x09),
timestamp(0x11) so `_id` and dates cannot round-trip; only single-doc insert, no update/delete/aggregate;
`ok:0` errors treated as success (C1); no TLS (C2); clientNonce is caller-supplied not random. It cannot
function against a real MongoDB today.

---

## 5. Standard library completeness (non-DB)

Overall the non-DB stdlib is finished code, not scaffolding: only 3 TODO/FIXME markers across the tree
(`compress/deflate.nova:482`, `crypto/tls/13/handshake.nova:50`, `net/tcp/client.nova:15`), plus two
genuine stubs (`async_util.whenAny` returns 0, `aio.sleep` returns 0). The gaps are missing modules,
not half-written ones.

- Web framework (Beta, most mature): DI (singleton/scoped/transient), mediator/CQRS, middleware
  pipeline, the unified router (post-consolidation), CORS/CSRF/sessions/rate-limit (token bucket)/
  circuit-breaker/secure-headers/request-id/recovery/body-limit/redact/multipart/static+LRU/mime,
  TLS server, multi-core reactor (`runReactorMC`). Rivals a real web stack.
- Crypto/TLS (Beta): 204 pub fns. TLS 1.3 client AND server (SNI, ALPN, HRR, resumption + 0-RTT +
  KeyUpdate, AES-GCM + ChaCha20-Poly1305, X25519/P256/P384), x509 chain verification + truststore.
  Gaps: no OCSP/CRL revocation, TLS 1.2 is client-only (no 1.2 server), no evident mTLS/client-cert
  handshake, no Ed25519/scrypt/argon2, SHA-384 transcript flagged follow-on (`handshake.nova:50`).
- IO/FS/OS (Beta): file + dir complete; process strong incl. `spawnIsolated` (namespaces/rootfs) and a
  full Windows backend set. Gaps: stat/metadata (size/mtime/perms), recursive mkdir, copy, tree walk/
  glob, symlinks, mmap; `fs.nova` is only a Watcher.
- String/JSON (Beta): solid. Gaps: format/printf, repeat, padStart/padEnd, splitLines; JSON has no
  streaming parser and no structured parse-error reporting.
- Serde yaml/bson (Alpha): complete-ish subsets; no streaming; weak error surfacing.
- Collections (Alpha): generic but bare -- no sort/pop/contains/indexOf/reverse/slice on List; map has
  no entries()/ordering; missing deque, heap/priority-queue, ordered/sorted map.
- Text/Unicode (Alpha): utf8 codepoints + Thompson-NFA regex (groups, no backrefs/lookaround); no
  normalization (NFC/NFD), grapheme clusters, or Unicode case folding (case ops are ASCII-only).
- Concurrency (Alpha): atomic + generic channel good; `asyncchan` is int-only; `async_util.whenAny`/
  `whenAnyDeadline` are stubs; no select-over-channels, WaitGroup/barrier, mutex/rwlock, or structured
  cancellation in stdlib.
- Datetime/Math (Alpha), Decimal (Prod): datetime is epoch/UTC only (no timezones, no locale); math has
  no trig/log10/log2/hypot/bigint. Decimal is a built-in Prod type used throughout serde.
- Missing entirely: observability (metrics/tracing), a structured logging framework (only a basic
  request logger), layered config management (only env get/set/args), HTTP/2, WebSocket (client + server).

---

## 6. Prioritized roadmap to production

Ordered by leverage. P0 = security/correctness blockers that make current behavior unsafe or silently
wrong; P1 = required for a real deployment; P2 = completeness/ergonomics.

### P0 -- unblock safe, correct usage
1. Error propagation at the seam (C1). Add a `DbError` return/out-channel to
   query/exec/queryPrepared/execPrepared; wire each driver's existing decoder into its read loop.
   Single highest-value fix; touches the seam + all five drivers.
2. TLS on the SQL data path (C2). Add a TLS `AsyncStream`/BIO variant to `net/aio.nova`, then wire
   SSLRequest (pg), CLIENT_SSL (mysql), and real cert verification on mssql (turn on the existing
   x509/truststore path). Cleartext credentials today.
3. Correct temporal + special-type decode (C5). Real ISO/date parsing for pg + mysql text paths;
   FLOAT + DATE/TIME/DATETIME2/DATETIMEOFFSET + PLP for mssql; bytea hex decode; BSON ObjectId/datetime
   for mongodb. Prevents silent data corruption.
4. Enforce parameterization (C4). Route query/exec through server-side bind, or at minimum fix the
   `$1..$9`-only substitution (multi-digit) and binary-blob escaping. Fixes ORM insert >9 columns too.
5. mongodb: wire `hello` + `authenticate` into `connect` and parse `cursor.firstBatch` + getMore so
   `find` returns documents (C1/protocol). Without this the driver is non-functional.

### P1 -- required for a real deployment
6. Transaction API on the Connection trait (C3): begin/commit/rollback + savepoints + rollback-on-drop;
   fix the mssql transaction descriptor + honor ENVCHANGE.
7. Pool hardening (C7): max-open cap, acquire timeout + wait queue, validation-on-borrow/ping,
   maxLifetime + idle eviction, leak detection, thread-safety, and reconnect.
8. Query-level timeouts + cancellation (C9): connect/statement timeouts, PG CancelRequest, TDS ATTENTION.
9. Per-connection concurrency guard (C8): enforce exclusive checkout / single in-flight request.
10. Async non-blocking DNS + IPv6 (stdlib gap 1): the current blocking IPv4-only getaddrinfo stalls the
    event loop (`net/eventedio.nova:70`).
11. HTTP client connection pooling / keep-alive (stdlib gap 2): every request currently opens a new
    socket + full TLS handshake.
12. Observability + structured logging (stdlib gaps 3-4): a logging framework (levels, JSON fields,
    sinks) and metrics/tracing hooks; add pool + driver instrumentation.

### P2 -- completeness + ergonomics
13. `DbValue` richer types + NULL-aware accessors (C6); ORM write side (update/delete/upsert + PK) and
    streaming/cursor results for large sets.
14. Driver protocol breadth: mysql large-packet (>=16MB) reassembly + multi-resultset + sha256_password;
    mssql outbound packet chunking + sp_reset_connection on reuse + sp_unprepare; btreedb real auth +
    Parse/Bind; pg LISTEN/NOTIFY + COPY.
15. Collections depth (sort/contains/indexOf, deque, heap, ordered map); datetime timezones; math
    trig/log; config management; TLS revocation (OCSP/CRL) + TLS 1.2 server + mTLS.
16. In-repo live integration harness (C10) so the live path of every driver is gated in CI rather than
    asserted in comments; reconcile the contradictory liveness claims.

---

## 7. Master tracking table

Every roadmap item as a trackable row: priority, the cross-cutting blocker it closes (C1-C10 from
section 2), where the work lands, and status. Legend: [ ] not started, [~] in progress, [x] done.

| # | Pri | Item | Blocker | Where it lands | Status |
|---|---|---|---|---|---|
| T1 | P0 | Error propagation: add `DbError` return/channel; wire each driver's decoder into its read loop | C1 | seam + all 5 drivers | [ ] |
| T2 | P0 | TLS on the SQL data path: TLS `AsyncStream`/BIO in net/aio; SSLRequest (pg), CLIENT_SSL (mysql), cert verify (mssql) | C2 | net/aio + pg/mysql/mssql/mongo/btree | [ ] |
| T3 | P0 | Correct temporal + special-type decode (ISO dates, mssql FLOAT/DATE*/PLP, bytea hex, BSON ObjectId/datetime) | C5 | pg/mysql/mssql/mongo | [ ] |
| T4 | P0 | Enforce parameterization: server-side bind, or fix `$1..$9`-only + binary-blob escaping | C4 | pg/mysql/btree + ORM | [ ] |
| T5 | P0 | mongodb: wire `hello` + `authenticate` into connect; parse `cursor.firstBatch` + getMore | -- | mongodb | [ ] |
| T6 | P1 | Transaction API on Connection trait (begin/commit/rollback + savepoints + rollback-on-drop); fix mssql txn descriptor + ENVCHANGE | C3 | seam + mssql | [ ] |
| T7 | P1 | Pool hardening: max-open cap, acquire timeout + wait queue, validate-on-borrow, maxLifetime, leak detection, thread-safety, reconnect | C7 | pool | [ ] |
| T8 | P1 | Query-level timeouts + cancellation (connect/statement timeout, PG CancelRequest, TDS ATTENTION) | C9 | seam + all drivers | [ ] |
| T9 | P1 | Per-connection concurrency guard (exclusive checkout / single in-flight) | C8 | seam + pool | [ ] |
| T10 | P1 | Async non-blocking DNS + IPv6 (blocking IPv4 getaddrinfo stalls the loop) | -- | net/eventedio | [ ] |
| T11 | P1 | HTTP client connection pooling / keep-alive (no fresh socket + TLS per request) | -- | web/client | [ ] |
| T12 | P1 | Structured logging framework + metrics/tracing hooks; instrument pool + drivers | -- | new stdlib + pool | [ ] |
| T13 | P2 | DbValue richer types (date/time/uuid/json) + NULL-aware accessors; ORM write side (update/delete/upsert + PK) + streaming results | C6 | seam + orm | [ ] |
| T14 | P2 | Driver protocol breadth: mysql >=16MB reassembly + multi-resultset + sha256_password; mssql packet chunking + sp_reset_connection + sp_unprepare; btree real auth + Parse/Bind; pg LISTEN/NOTIFY + COPY | -- | mysql/mssql/btree/pg | [ ] |
| T15 | P2 | Collections depth (sort/contains/indexOf, deque, heap, ordered map); datetime timezones; math trig/log; config mgmt; TLS revocation (OCSP/CRL) + TLS 1.2 server + mTLS | -- | stdlib | [ ] |
| T16 | P2 | In-repo live integration harness gating every driver's live path in CI; reconcile contradictory liveness claims | C10 | all drivers + CI | [ ] |

## 8. Bottom line

The language, runtime, and web framework are the mature layers (Beta). The data layer is uniformly
Alpha (mongodb Prototype): the wire codecs and auth math are correct and well-tested offline, but every
driver shares the same production-disqualifying gaps -- swallowed errors, missing/unverified TLS,
broken temporal decode, no transactions, an immature pool, and no live verification. Because those gaps
are shared, most of the P0/P1 work lands at the seam and shared `net`/pool layer and lifts all five
drivers together, rather than being five separate rewrites.
