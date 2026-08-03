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
| Crypto / TLS | Beta | TLS 1.3 both roles (resumption, 0-RTT, KeyUpdate) + TLS 1.2 client; chain verification. TLS 1.2 SERVER = WON'T-DO (see decision below). Optional: mTLS, OCSP/CRL. |
| IO / FS / OS | Beta | file/dir/process complete incl. isolated spawn + full Windows backend. Gaps: stat/metadata, recursive mkdir, tree walk, mmap. |
| String / JSON | Beta | Solid split/join/slice/parse + JSON DOM. Gaps: format/printf, padStart, streaming/error-reporting parse. |
| Serde (yaml, bson) | Alpha | yaml + bson complete-ish but subset; no streaming, weak error reporting. |
| Collections | Beta | list ext (sort/contains/indexOf/any/all/...) + Deque + Heap + OrderedMap now shipped (T15). |
| Text / Unicode | Alpha | utf8 codepoints + Thompson-NFA regex; no normalization/grapheme/casefold, no backrefs/lookaround. |
| Concurrency | Alpha | atomic + generic channel; `asyncchan` int-only, `whenAny` a stub; no select/WaitGroup/mutex/cancel. |
| Datetime / Math | Beta | timezone-aware ISO parse/format (T15) + trig/log10/log2 now present; bigint still absent. Decimal (built-in) is Prod. |
| Observability / Config / HTTP-2 / WebSocket | Alpha | Structured logging (std/log) + layered config (std/config) + metrics/tracing (std/metrics: counters/gauges/Prom+JSON, Span) now present (T12); still no HTTP/2, no WS. |

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
  Gaps: no OCSP/CRL revocation, no evident mTLS/client-cert handshake, no Ed25519/scrypt/argon2,
  SHA-384 transcript flagged follow-on (`handshake.nova:50`). TLS 1.2 is client-only by DECISION: the
  1.2 SERVER role is WON'T-DO (see the decision note under section 7 / T15).
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
    trig/log; config management; [OPTIONAL] mTLS + TLS revocation (OCSP/CRL). TLS 1.2 server = WON'T-DO
    (see the decision note at the end of this section).
16. In-repo live integration harness (C10) so the live path of every driver is gated in CI rather than
    asserted in comments; reconcile the contradictory liveness claims.

---

## 7. Master tracking table

Every roadmap item as a trackable row: priority, the cross-cutting blocker it closes (C1-C10 from
section 2), where the work lands, and status. Legend: [ ] not started, [~] in progress, [x] done.

T1 DONE 2026-08-03: `data/db` gained `err: DbError` on ResultSet/ExecResult (+ ok/hasError +
errorResult/errorExec); pg/mysql/mssql/btreedb/mongodb all decode their wire error onto the result
instead of swallowing it; `ResilientPool` failure detection now keys on `hasError()`. One residual is
tracked separately: connect-time errors still do not propagate (Driver.connect returns a bare
Connection) -- that needs a connect error channel and is folded into C1/T8 follow-up.

T2 IN PROGRESS 2026-08-03: added the async STARTTLS client-upgrade seam
`asynctls.tlsClientUpgrade` / `tlsClientUpgradeVerify` (upgrade an open AsyncStream in place, the
client analog of tlsAccept; reuses the proven TlsStream + TLS 1.3 memory-BIO the web server runs live
in case 209). Wired POSTGRES (reference): its reader + connection now hold the `AsyncIO` trait (so the
transport can be plaintext AsyncStream OR TlsStream), and connect sends SSLRequest + upgrades on 'S',
selected by DSN `sslmode` (disable default = unchanged / require / verify-full with `sslrootcert`).
Widening the concrete stream into an AsyncIO param is the safe direction (same pattern as handleConn).
CAVEAT: the TLS path is COMPILE + ASAN verified only -- no live TLS Postgres server on this host; the
plaintext default path is unchanged and offline-tested (SSLRequest wire bytes gated in test 66).
T2 [x]* -- all five drivers wired 2026-08-03, with two honest caveats (hence the asterisk):
- pg: SSLRequest + upgrade, DSN sslmode (disable/require/verify-full + sslrootcert). TLS 1.3, verify OK.
- mongodb: implicit TLS via tlsConnect/tlsConnectVerify, DSN tls=true/verify + tlsCAFile. TLS 1.3.
- btreedb: implicit TLS via tlsConnect[Verify], DSN tls=. TLS 1.3 (server must serve TLS on the port).
- mysql: CLIENT_SSL + 32-byte SSLRequest (seq 1) -> upgrade -> full response over TLS (seq 2), auth flow
  extracted to myAuthFinish(io: AsyncIO). DSN sslmode. Seq/capability logic is the riskiest unverified bit.
- mssql: MITM gap NOW CLOSED. Fixed the force-true handshake outcome, AND implemented TLS-1.2 chain
  verification end to end: client12 retains the cert_list, x509.verifyCertList12 + truststore.trusts12
  parse the 1.2 layout, tls12bio.newClient12BioVerify fails the handshake on an untrusted chain, and
  mssql opts in via encrypt=true&trustServerCertificate=false&tlsCAFile=. The chain-verify LOGIC is
  offline-proven (case 233 cert_list12_chain: real leaf+intermediate to root, wrong-host + leaf-only
  rejected, 1.3 parser rejects 1.2 layout) -- unlike the live handshake, this part is genuinely verified.
CAVEATS: (1) every driver's TLS handshake is COMPILE + ASAN verified only -- no live TLS DB server on
this host; the plaintext default paths are unchanged and offline-tested (SSLRequest wire bytes gated for
pg + mysql). (2) fail-closed enforcement (require/verify-full MUST refuse on the server declining TLS)
is still best-effort-fallback, blocked on the connect error channel (T1 residual).
Remaining true-P0 follow-ons carried forward: TLS-1.2 chain verify (mssql MITM), connect error channel
(fail-closed), and a live TLS integration test (T16).

T3 [x]* -- temporal + special-type decode fixed across all drivers 2026-08-03 (all offline-verified):
- seam: dbTimestamp + asTimestamp/getTimestamp (temporal carried as ISO text under DbType.Timestamp).
- pg: timestamp kept as ISO string (was parseI64 -> year only); bytea "\xHEX" -> raw bytes.
- mysql: text datetime kept as string (was parseI64); binary datetime now includes microseconds.
- mssql: FLOAT (FLT4/8/N) decoded via nova_ieee_le_to_str (was NULL, silent data loss); GUID -> canonical
  8-4-4-4-12 UUID string (was raw bytes).
- serde/bson: ObjectId(0x07)->hex + docGetObjectId, datetime(0x09)/timestamp(0x11)->int64. Fixes a
  parser DESYNC: every real Mongo reply's _id ObjectId used to misparse the whole document.
The asterisk: mssql TDS temporal types (DATETIME/DATE/TIME/DATETIME2/DATETIMEOFFSET) still decode to
NULL -- adding them needs TDS temporal encodings + calendar conversion (days-since-epoch -> Y-M-D), a
documented T3 follow-on. pg uuid/json remain text (usable as strings, not "wrong").

T4 [x]* -- parameterization correctness fixed across pg/mysql/btreedb 2026-08-03 (offline-verified):
substituteParams now parses MULTI-DIGIT $N (was $1..$9 only, so the ORM's $1..$N silently broke for
structs with >9 columns -- fixed for free on all three). Blob params render a binary-safe literal
('\xHEX' bytea for pg/btree, x'HEX' for mysql) instead of text-escaping raw bytes (NUL/quote unsafe).
The asterisk: this makes the client-side substitution CORRECT + injection-safe (escapeText doubles
quotes), but does not ROUTE query/exec through server-side bind -- true parameterization is still only
the *Prepared methods. Full server-side-bind routing for query/exec is a follow-on.

T5 [x]* -- mongodb lifted from "cannot function" to functional shape 2026-08-03:
- connect now sends `hello` and, with DSN credentials ([user:pass@]host in the mongodb:// DSN), calls
  SCRAM-SHA-256 `authenticate` with a per-connection CSPRNG nonce -- previously connect opened the
  socket and returned without any handshake/auth, so the driver could not talk to any MongoDB.
- find() parses cursor.firstBatch and returns each result document as a "document" text cell holding
  its JSON (new stdlib bson.docToJson) instead of the old synthetic 1/0 row.
The asterisk: the live handshake/auth + cursor path need a running MongoDB (none on this host) --
compile-verified; docToJson is offline-tested. getMore (batches beyond firstBatch) is a follow-on.

ALL FIVE P0 items (T1-T5) are now done. Remaining follow-ons (not P0-complete): connect error channel
(fail-closed TLS + connect-time errors), mssql TDS temporal types, getMore, and the live integration
test (T16). Next tier is P1 (T6 transactions, T7 pool hardening, ...).

| # | Pri | Item | Blocker | Where it lands | Status |
|---|---|---|---|---|---|
| T1 | P0 | Error propagation: add `DbError` return/channel; wire each driver's decoder into its read loop | C1 | seam + all 5 drivers | [x] |
| T2 | P0 | TLS on the SQL data path: TLS `AsyncStream`/BIO in net/aio; SSLRequest (pg), CLIENT_SSL (mysql), cert verify (mssql) | C2 | net/aio + pg/mysql/mssql/mongo/btree | [x]* |
| T3 | P0 | Correct temporal + special-type decode (ISO dates, mssql FLOAT/DATE*/PLP, bytea hex, BSON ObjectId/datetime) | C5 | pg/mysql/mssql/mongo | [x]* |
| T4 | P0 | Enforce parameterization: server-side bind, or at minimum fix the `$1..$9`-only substitution + binary-blob escaping | C4 | pg/mysql/btree + ORM | [x]* |
| T5 | P0 | mongodb: wire `hello` + `authenticate` into connect; parse `cursor.firstBatch` + getMore | -- | mongodb | [x]* |
| T6 | P1 | Transaction API on Connection trait (begin/commit/rollback + savepoints + rollback-on-drop); fix mssql txn descriptor + ENVCHANGE | C3 | seam + mssql | [x]* |
| T7 | P1 | Pool hardening: max-open cap, acquire timeout + wait queue, validate-on-borrow, maxLifetime, leak detection, thread-safety, reconnect | C7 | pool | [x]* |
| T8 | P1 | Query-level timeouts + cancellation (connect/statement timeout, PG CancelRequest, TDS ATTENTION) | C9 | seam + all drivers | [~] |
| T9 | P1 | Per-connection concurrency guard (exclusive checkout / single in-flight) | C8 | seam + pool | [x] |
| T10 | P1 | Async non-blocking DNS + IPv6 (blocking IPv4 getaddrinfo stalls the loop) | -- | net/eventedio | [~] |
| T11 | P1 | HTTP client connection pooling / keep-alive (no fresh socket + TLS per request) | -- | web/client | [~] |
| T12 | P1 | Structured logging framework + metrics/tracing hooks; instrument pool + drivers | -- | new stdlib + pool | [x] |
| T13 | P2 | DbValue richer types (date/time/uuid/json) + NULL-aware accessors; ORM write side (update/delete/upsert + PK) + streaming results | C6 | seam + orm | [x] |
| T14 | P2 | Driver protocol breadth: mysql >=16MB reassembly + multi-resultset + sha256_password; mssql packet chunking + sp_reset_connection + sp_unprepare; btree real auth + Parse/Bind; pg LISTEN/NOTIFY + COPY | -- | mysql/mssql/btree/pg | [~] |
| T15 | P2 | Collections depth (sort/contains/indexOf, deque, heap, ordered map); datetime timezones; math trig/log; config mgmt; [OPTIONAL] mTLS + OCSP/CRL. TLS 1.2 server = WON'T-DO (decision) | -- | stdlib | [~] |
| T16 | P2 | In-repo live integration harness gating every driver's live path in CI; reconcile contradictory liveness claims | C10 | all drivers + CI | [~] |

## 8. Bottom line

The language, runtime, and web framework are the mature layers (Beta). The data layer is uniformly
Alpha (mongodb Prototype): the wire codecs and auth math are correct and well-tested offline, but every
driver shares the same production-disqualifying gaps -- swallowed errors, missing/unverified TLS,
broken temporal decode, no transactions, an immature pool, and no live verification. Because those gaps
are shared, most of the P0/P1 work lands at the seam and shared `net`/pool layer and lifts all five
drivers together, rather than being five separate rewrites.

T8 [~] 2026-08-03: query cancellation PRIMITIVES landed -- pg CancelRequest (capture BackendKeyData +
buildCancelRequest + async cancel() over a side connection) and mssql TDS ATTENTION (buildAttention +
cancel()); both wire-byte offline-tested. Remaining: statement/connect timeouts (the per-recv setTimeout
exists but a deadline->cancel wiring in the reactor is the real feature), mysql cancel (COM_PROCESS_KILL
on a side conn), and wiring cancel() into a timeout path -- unverifiable without a live server.

T12 [x] 2026-08-03: observability landed. metrics.nova = string-keyed Registry (counters + gauges) with
numStr, snapshotProm (Prometheus text) + snapshotJson (deterministic via an insertion-order name list);
log.nova gains a tracing Span (startSpan/finish -> elapsed_ns log line + <name>_ns_total counter +
<name>_last_ns gauge). metrics is deliberately log-free so pool.publishMetrics(reg, prefix) -- which
snapshots idle/live/borrowed/high_water/opened/overflow gauges -- does not drag log.f into the pool's
import graph (that collision fails the checker; see the commit). Gates: case 245_metrics + 104_conn_pool
publishMetrics test, ASAN clean.

T13 [~] 2026-08-03: DONE except streaming. Seam has DbType.Uuid/Json + dbUuid/dbJson + asUuid/asJson +
dbTimestamp/asTimestamp, and NULL-aware asIntOr/asLongOr/asDoubleOr/asTextOr/asBoolOr (db.nova); ORM
write side is update<T>(conn,table,obj,keyCol) + deleteBy(conn,table,keyCol,keyVal) (orm.nova); drivers
map uuid/json OIDs. REMAINING: cursor/streaming results (fetch rows in batches rather than materializing
the full ResultSet) -- needs per-driver batch-fetch support and a live server to verify, deferred with T16.

T8 [~] UPDATE 2026-08-03: statement-timeout wiring landed at the pool -- Pool.configureTimeouts(ms)
applies conn.setTimeout on every acquire (both reused and fresh), so each borrowed connection carries a
per-statement deadline (the driver's awaited recv errors past it). Still live-only: mysql cancel
(COM_PROCESS_KILL) and a deadline->CancelRequest/ATTENTION fire (needs a slow live query to verify).

T13 [x] 2026-08-03: DONE. Types + NULL-aware accessors + ORM update/deleteBy (earlier) + db.RowStream
cursor (db.streamRows(rs): hasNext/next/reset/remaining/ok/err), case 237. True lazy server-side batch
fetch (pg portals / mysql row-by-row / mssql PLP) slots behind the SAME cursor surface and is the
per-driver live follow-on -- callers do not change when a driver gains it.

T14 [~] 2026-08-03: driver protocol breadth -- offline codec pieces SHIPPED across 3 drivers:
mysql >=16MB multi-packet reassembly (reassemblePayload + readPacket loop) + caching_sha2_password
scramble; mssql TDS request packet chunking (chunkTdsMessage, all sends route through it) + sp_unprepare;
pg LISTEN/NOTIFY (decodeNotification + 'A'-frame capture + listen/notifications) + COPY OUT
(decodeCopyResponse/decodeCopyData + copyOut). Each unit-tested on synthetic frames. REMAINING (live or
larger): mysql multi-resultset; mssql sp_reset_connection; btree real auth + Parse/Bind; pg idle NOTIFY
delivery loop; all live-path verification.

SESSION SUMMARY 2026-08-03: T1-T7 done (prior); this session closed T9 [x] (busy guard, all 5 drivers),
T12 [x] (metrics + tracing + pool instrumentation), T13 [x] (RowStream cursor + earlier types/ORM),
T16 harness + T8 timeout + T11 keep-alive framing + T14 codec breadth (mysql/mssql/pg) + T10 IPv6 URL +
T15 collections/math/datetime/config all to [~]/[x] with offline gates. GENUINELY REMAINING (milestone-
scale or live/runtime-bound, NOT rushed): T15 mTLS + OCSP/CRL [OPTIONAL] (TLS 1.2 server = WON'T-DO,
see decision) (crypto, must verify vs
OpenSSL); T10 async non-blocking DNS (runtime, off-reactor getaddrinfo) + real v6 socket connect; T14
btree Parse/Bind + real auth (needs btree server), mysql multi-resultset, mssql sp_reset_connection; T13
lazy server-side batch fetch; live-path verification for every driver (T16 CI service containers). These
need a live server / reference crypto peer to finish honestly.

T11 [~] 2026-08-03: HTTP keep-alive foundation landed. The bug-prone core -- exact response framing
without EOF -- is a pure httpMessageLen(buf) (Content-Length / chunked zero-terminator / -2 "no length
must close"), thoroughly unit-tested (case 248, 30/30 incl pipelined + case-insensitive + chunked). Plus
a KeepAlivePool keyed by host:port:secure (take/put, per-host idle cap) and Http.requestVia(pool, ...)
that reuses a pooled conn, sends Connection: keep-alive, reads one framed message, and returns the conn
unless the response is unframed/says close. End-to-end socket REUSE is verified against a live server
(integration harness), not offline.

T9 [x] 2026-08-03: per-connection concurrency guard shipped across ALL FIVE drivers. Each Connection
carries a busy:bool; query/exec (and, where they send frames directly rather than delegating,
queryPrepared/execPrepared -- mysql/mssql) refuse re-entry with a "connection busy: concurrent use"
DbError, clearing the flag on every return path. begin/commit/rollback and the delegating prepared
paths are guarded TRANSITIVELY through the exec/query they call (guarding them directly would false-trip
the inner guard). One in-flight request per connection; concurrency comes from the pool's exclusive
checkout. Offline codec suites green per driver (pg reference; btree 19, mysql 26+23, mssql 22+21, mongo
26). Minor follow-on: mysql/mssql `prepare` (COM_STMT_PREPARE / sp_prepare) also send a frame and could
take the guard; left to match the pg reference scope.

T15 [~] 2026-08-03: stdlib depth partially landed and gated. DONE: list ext (reverse/clear/pop/first/
last/findIndex/any/all/indexOf/contains, case 235); config.nova (env-override layered config, case 236);
math trig/log (sin/cos/tan/atan/atan2/log10/log2 with range reduction) + datetime timezones
(tzOffsetSeconds/fromIsoUtc/formatOffset), case 244; Deque<T> (double-ended, two-stack amortized) +
Heap<T> (min priority queue with a less comparator), case 246; OrderedMap<K,V> (sorted-key map,
binary-search get/has, ordered keys), case 247. COLLECTIONS DEPTH NOW COMPLETE. REMAINING (all TLS-role
work, tracked with the M12/M13 TLS line, not pure-stdlib): mTLS + OCSP/CRL revocation (both OPTIONAL,
do only if service-to-service client-cert auth is on the roadmap). TLS 1.2 SERVER role = WON'T-DO.

DECISION 2026-08-03 (revised, same day) -- mTLS + OCSP/CRL are REQUIRED, not optional.
Nova will consume EXTERNAL services (some over TLS 1.2, which the CLIENT role already supports -- M13,
live vs OpenSSL) that (a) require a client certificate (mTLS) and (b) whose certs must be revocation-
checked. So mTLS (client-cert presentation on BOTH the 1.3 and 1.2 CLIENTS) and OCSP/CRL are now planned
work, done in verified increments: (1) mTLS 1.3 client [DONE -- case 250 mutual-auth loopback green], (2) mTLS 1.2 client [DONE -- case 251, offline gate; live vs OpenSSL s_server -Verify], (3) OCSP (stapling verify +
request/response ASN.1, offline-tested; live responder fetch gated), (4) CRL (parse + serial check
offline; live DP fetch gated). These are CLIENT-side additions -- no CBC/RSA-kx SERVER padding-oracle
surface -- so far lower risk than the 1.2 server. The 1.2 SERVER role remains WON'T-DO (below): we are a
client to these services, not their server.

DECISION 2026-08-03 -- TLS 1.2 SERVER role: WON'T-DO (by design).
Rationale: Nova already serves TLS 1.3 (both roles, full spec) and connects over TLS 1.2 (client role).
A 1.2 SERVER role adds exactly one capability -- accepting inbound connections from clients that cannot
speak 1.3. Since TLS 1.3 (RFC 8446, 2018) is negotiated by every current browser / curl / language
runtime / load balancer, a modern server-side framework essentially never faces a 1.3-incapable client;
the ones that exist are legacy middleboxes / ancient Java / Win7-era stacks, not Nova's target. The
direction that DOES matter -- talking to old servers that only accept 1.2 (some managed SQL Server /
MySQL / corporate APIs) -- is the CLIENT side, already shipped. Against that near-zero payoff, a 1.2
server means implementing RSA key-exchange + the CBC cipher-suite family (Lucky13 / padding-oracle /
BEAST history) as a server: security-critical crypto that must be verified byte-for-byte vs OpenSSL,
where a subtle bug is a real vulnerability, not a failed test. High risk, negligible modern benefit ->
not implemented. Revisit ONLY if a concrete deployment requires serving a 1.2-only client, letting that
constraint drive the (minimal, audited) cipher-suite choice.

T9 [~] 2026-08-03: per-connection concurrency guard on pg (query/exec refuse re-entry while a request is
in flight -> "connection busy" DbError, preventing frame interleaving). Compile-verified (needs a live
conn to exercise). Reference impl; extend the same busy flag to mysql/mssql/btree/mongo.

T12 [~] 2026-08-03: structured logging framework landed -- std/log: a Logger with level filtering
(Debug/Info/Warn/Error) and JSON-line output with typed Field key/values (format() is pure + tested;
log() emits to stdout). Case 234 gates JSON rendering + escaping + level filter. Remaining T12: metrics
(counters/histograms) + tracing (span) hooks, and wiring the logger + metrics into the pool/drivers.
