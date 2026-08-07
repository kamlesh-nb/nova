# Nova DB drivers: gap analysis and fix plan

Comparison of the four Nova SQL/NoSQL drivers against their canonical Go counterparts, with a
phased plan to close the gaps. Reviewed 2026-08-06.

References: `lib/pq` (postgres), `go-sql-driver/mysql`, `microsoft/go-mssqldb`, `mongodb/mongo-go-driver`.

Scope: `packages/nova-{postgres,mysql,mssql,mongodb}/src/`, the shared seam
`lang/src/std/data/db.nova` + `lang/src/std/data/sql/pool.nova`, and `lang/src/std/serde/bson.nova`.

## Executive summary

The three SQL drivers (postgres, mysql, mssql) are competent happy-path implementations: connect,
authenticate, run a query, decode common types. They share the same four structural weaknesses,
so fixing them once at the seam plus once per driver clears most of the list. The mongodb driver is
different in kind: it is a proof-of-concept wire client bolted onto a SQL-shaped seam, and needs a
native document API before it can be called a driver.

Four cross-cutting workstreams account for the majority of the high-severity findings:

1. **Client-side parameter substitution is the default path on every SQL driver** (an injection
   surface and a correctness hazard for non-text params). The safe server-bound path exists in each
   driver but is opt-in only.
2. **TLS is fail-open**: `sslmode=require` silently means "encrypt but do not verify" (mysql), or a
   server that refuses TLS is silently downgraded to cleartext (postgres), or the cert chain is not
   validated at all (mssql). A MITM defeats the intended trust posture.
3. **The server error number/code is decoded and then discarded**, so callers cannot classify
   deadlock / duplicate-key / transient failures. Deadlock-retry and unique-violation handling are
   impossible today across all four.
4. **Whole result sets are buffered in memory**; there is no streaming ResultSet in the seam, and
   two drivers have a hard cap on a single value/packet size.

## Per-driver critical correctness bugs (break real apps, fix first)

These are not feature gaps, they are latent defects that corrupt data or the connection:

- **mssql: date/time columns desync the entire token stream.** `parseTypeInfo` has no case for
  DATE / TIME / DATETIME / DATETIME2 / DATETIMEOFFSET / SMALLDATETIME, so `readValue` returns null
  without advancing the cursor and every subsequent column/row is garbage. Our comparison app only
  dodged this by storing timestamps as `NVARCHAR`. (`codec.nova` parseTypeInfo/readValue)
- **mssql: VARBINARY(MAX) / XML / SQL_VARIANT / TEXT / NTEXT / IMAGE also desync** the same way
  (no PLP path for MAX binary; no type-info case for the others).
- **mssql: a failed login returns a live-looking but dead connection** (logs to stderr, still
  returns the object). The caller gets no error. (`mssql.nova` msConnectAsync)
- **mssql: query cancellation is fire-and-forget** — ATTENTION is sent but the attention-ack is
  never drained, leaving unread tokens on the socket so the next request desyncs.
- **mysql: binary-protocol TIME (type 11) is mis-decoded** as a lenenc string, desyncing the row
  stream. (`codec.nova` decodeBinaryCell)
- **mysql: a single value/packet larger than the 64 KB reader ring cannot be read** (common for
  TEXT/BLOB/JSON). (`proto.nova`)
- **mysql: unsigned BIGINT > 2^63 wraps to a negative number.**
- **mongodb: `exec()` performs no write** — it runs a `find` and returns `rowsAffected = ok ? 1 : 0`.
  The driver cannot write through its public API.
- **mongodb: `getMore` is not implemented** — only `find.firstBatch` is read, so any result the
  server splits is silently truncated. (mitigated today by a `batchSize:100000` stopgap)
- **mongodb: transactions (`begin`/`commit`/`rollback`) are silent no-ops** that report success.
- **mongodb: the BSON parser infinite-loops on an unknown type byte** (advances offset by 0) — a
  reply containing regex/code/minkey/timestamp-in-some-positions hangs the client (DoS).

## Cross-cutting workstreams

### X1. Route the default query/exec path through server-bound parameters
`query`/`exec` on postgres, mysql and mssql all inline-substitute values into SQL text. Each driver
already has the safe path built (postgres Parse/Bind/Execute, mysql COM_STMT_PREPARE/EXECUTE, mssql
sp_executesql). Move the default path onto it, or where that is too invasive keep substitution but
make the escaper GUC/sql_mode/charset-aware and NUL-safe, and emit typed literals (mssql needs
`N'...'` for unicode, correct VARBINARY and date/time literals; today a Blob param is emitted as a
number). Effort: M per driver.

### X2. Make TLS fail-closed and complete the sslmode ladder
- postgres: fail closed on a server `'N'` (TLS refused) when mode >= require; add `verify-ca` distinct
  from `verify-full`; change default to `prefer`; make cancel use the same TLS posture (today it is
  always plaintext).
- mysql: `require` must still verify (today it does not); add `preferred`, and separate
  `verify-ca` from `verify-identity` (hostname).
- mssql: honour ENCRYPT_REQ(3) (server-forced encryption), validate the cert chain in the TLS 1.2
  tunnel (today `trustCert=true` by default and no CA validation), and add a strict/TDS-8.0 path
  later. Effort: M per driver, plus L for mssql cert validation and TDS 8.0.

### X3. Preserve and classify the server error code/number
Add a numeric code field to `DbError` and populate it: postgres SQLSTATE (already partly captured,
widen to Detail/Hint/Position/Constraint and add class helpers), mysql u16 error number (currently
read then discarded), mssql TDS error number (currently discarded). Add helpers like `isDeadlock()`,
`isUniqueViolation()`, `isTransient()`. This unblocks retry logic. Effort: S per driver + S in the seam.

### X4. Streaming ResultSet in the seam
Introduce an iterator/cursor abstraction in `db.nova` so drivers can yield rows instead of buffering
the whole set. Then: postgres uses portals with a batch size, mysql stops pushing all rows, mssql
streams tokens, mongodb drains the cursor via getMore lazily. This is the one workstream blocked on a
seam/runtime change (and an async wait primitive for idle delivery). Effort: L (seam) + M per driver.

### X5. Connection robustness in the seam and drivers
- Hard pool cap with an async wait queue (blocked on `aio.sleep`/an async wait primitive), plus
  bad-connection eviction (mark a connection poisoned after a protocol desync / broken frame so it is
  not returned to the pool). (`pool.nova` maxOpen is a soft cap today)
- Per-driver liveness: mysql COM_PING / COM_RESET_CONNECTION and graceful COM_QUIT on close; a
  postgres/mysql/mssql connect+handshake deadline (today an unresponsive host hangs the connecting
  coroutine with no bound).
Effort: M.

## Per-driver gap tables (condensed)

Severity H/M/L, effort S/M/L. Cross-cutting items above are not repeated here.

### PostgreSQL (vs lib/pq)
| Gap | Sev | Eff |
|---|---|---|
| No MD5 auth (historical default; many live servers) | H | S |
| Arrays / money / inet / interval / range / enum collapse to Text (arrays returned as raw string) | M | M |
| No COPY IN (bulk load); COPY OUT buffered not streamed | M | M |
| LISTEN/NOTIFY has no idle delivery loop (needs a query in flight to observe) | M | M |
| DSN URL-only: no percent-decode of credentials, no keyword/value, no connect_timeout, no IPv6 | M | M |
| Binary param/result formats unsupported (float/numeric text round-trip loses precision) | M | L |
| No isolation levels / savepoints / read-only tx | M | S |
| NoticeResponse + ParameterStatus ignored (compounds the escaper GUC dependency) | L | S |
| No multi-host failover / target_session_attrs | L | M |
| No GSSAPI/Kerberos | L | L |

### MySQL (vs go-sql-driver/mysql)
| Gap | Sev | Eff |
|---|---|---|
| No capability negotiation; MULTI_RESULTS/MULTI_STATEMENTS/DEPRECATE_EOF/CONNECT_ATTRS not set (the multi-resultset loop is dead code) | M | S-M |
| No mysql_clear_password (PAM/LDAP), no sha256_password path, no MariaDB ed25519 | M | S-M |
| Server RSA public key fetched over the wire, unpinnable (MITM on plaintext recovers password) | M | M |
| Prepared params bound as VAR_STRING text not typed binary; no COM_STMT_SEND_LONG_DATA | M | M |
| COM_STMT_CLOSE never sent: server-side prepared-statement leak on long-lived connections | M | S |
| BLOB subtypes + binary/charset collapse to Text (binary corrupts through the text path) | M | M |
| Placeholder is `$N` not MySQL-native `?` (divergent from COM_STMT_PREPARE which uses `?`) | M | S |
| DATE/TIME/YEAR text-mapped to Text; YEAR should be int | L | S |
| BIT/JSON/ENUM/SET/GEOMETRY collapse to Text | L-M | M |
| LOAD DATA LOCAL INFILE unhandled (latent desync if a server sends 0xfb) | L | M |

### MSSQL (vs go-mssqldb) — excludes the just-fixed PLP terminator and `$N` items
| Gap | Sev | Eff |
|---|---|---|
| ENVCHANGE ignored: no routing (read-only replica redirect), collation, packet-size, txn descriptor | H | M |
| No Windows/Integrated auth (NTLM/Kerberos/SSPI); no Azure AD / fed-auth | H | L |
| No multiple-result-set support (rows from several SELECTs merge into one ResultSet) | H | M |
| Transaction descriptor hardcoded 0; multi-batch transactions not bound to server context | M-H | M |
| VARCHAR/CHAR decoded ignoring collation codepage (non-Latin-1 corrupts) | M | M |
| DONE rowcount read without checking DONE_COUNT bit; multi-statement counts overwritten not summed | M | S |
| Output params / RETURNSTATUS not surfaced | M | M |
| FEATUREEXTACK/SSPI/FEDAUTHINFO/TABNAME/COLINFO unknown-token → silent truncation | M | S-M |
| PRELOGIN advertises only 3 options (no MARS/FEDAUTHREQUIRED/NONCE); packet size fixed 4096 | M | S-M |
| TVP (table-valued params) and BCP bulk insert absent | M | L |
| No isolation-level API; no MARS; no connection resiliency | L-M | S-L |

### MongoDB (vs mongo-go-driver): native document API now SHIPPED

**Status (updated).** The mongodb driver is no longer a wire proof-of-concept: it has a native document
API (`Collection` / `Doc` / `Filter` / `Update` / lazy `Cursor`), the full read + write surface, sessions
and multi-document transactions, replica-set topology with failover, and a typed ORM both ways. Almost
every row below is now DONE and verified live against a real `mongod`; the only remaining open items are the
non-X.509 alternative auth mechanisms (SCRAM-SHA-1, AWS, LDAP, GSSAPI, OIDC) and BSON binary-subtype
preservation.

| Gap | Sev | Status |
|---|---|---|
| The SQL seam blocks the document model: no filter/projection/sort/limit, writes have nowhere to go | H | DONE: native `Collection`/`Doc`/`Filter`/`FindOptions` + lazy `Cursor` (getMore/killCursors) |
| No update/delete/replace/findAndModify/aggregate/count/distinct/bulkWrite builders | H | DONE: all present, incl. `bulkWrite` |
| No `mongodb+srv://` and no multi-host: cannot use standard Atlas / replica-set URIs | H | DONE: seed lists + a `mongodb+srv://` DNS SRV/TXT resolver |
| No topology / SDAM / replica-set discovery / failover / read preference | H | DONE: SDAM discovery, read preference, and failover three ways (background heartbeat monitor, reactive auto-failover on a not-primary error, on-demand `heartbeat`/`reconnect`) |
| ObjectId is decode-only and has no serialise case: cannot query or round-trip by `_id` | H | DONE: build + query + round-trip by `_id` |
| No client sessions (lsid), so no retryable writes; retryable reads/writes absent | M-H | DONE: client sessions, multi-document transactions, and retry-once retryable writes |
| killCursors missing (server-side cursor leak once getMore lands) | M | DONE |
| SCRAM-SHA-1 absent; authSource not honoured (defaults wrong); no x509/AWS/LDAP/GSSAPI/OIDC | M | PARTIAL: SCRAM-SHA-256 + MONGODB-X509 (client-cert mutual TLS, verified live) done; SCRAM-SHA-1 / AWS / LDAP / GSSAPI / OIDC not built |
| BSON gaps: dates/timestamps decode-only + indistinguishable, binary subtypes discarded, regex/code/minkey unhandled | M-H | MOSTLY DONE: typed date/timestamp/int64/double/decimal128 build+read; binary subtype preservation still open |
| OP_MSG document sequences (kind 1), flag bits, OP_COMPRESSED absent | L-M | kind-1 DONE (all writes stream a document sequence); OP_COMPRESSED still open |
| No connection pool (single socket, busy-bool rejects concurrency) | M-H | DONE: `data.sql.Pool(MongoDriver(), dsn, n)` is Mongo-aware for free |
| No max-message-size guard; short-read returns truncated buffer without error; auth failure swallowed | M | DONE: 64 MiB frame bound, short-read returns "", auth failure marks the connection dead |
| Change streams, GridFS, index management absent | L-M | ALL DONE: change streams (`watch`/`watchAll`/`watchFrom` with resume tokens + auto-recovery), GridFS (`gridfs.bucket` upload/download/delete/list, pymongo-interop verified), index management (`createIndex`/`dropIndex`) |

Beyond this table, the driver also gained a typed ORM surface not originally scoped: `docOf<T>` (serialise
a `@serializable` struct to a document) and `bindAll<T>`/`bindOne<T>` (read documents back into structs),
plus a typed `Value` union for `distinct`/array reads.

## Phased roadmap

**Phase 0 - correctness bugs (highest priority, mostly S-M).**
mssql date/time + VARBINARY(MAX)/XML type-info cases (stop the desync); mssql return an error on login
failure; mssql drain the attention-ack on cancel; mysql binary TIME decode; mysql grow the reader ring
past 64 KB; mysql unsigned BIGINT; mongodb BSON unknown-type guard (stop the infinite loop); mongodb
short-read and auth-failure error surfacing.

**Phase 1 - the four cross-cutting workstreams.**
X1 server-bound params (kills the injection default on all SQL drivers), X2 fail-closed TLS, X3 error
code classification. These are the security and correctness backbone and share design across drivers.

**Phase 2 - auth and type breadth (per driver).**
postgres MD5 + arrays; mysql capability negotiation + cleartext/sha256 plugins + typed binary prepared
params + COM_STMT_CLOSE; mssql ENVCHANGE (collation + txn descriptor) + multiple result sets + integrated
auth; mongodb writes (real insert/update/delete) + a filter builder + ObjectId serialise + getMore +
killCursors.

**Phase 3 - streaming and architecture (needs seam/runtime work).**
X4 streaming ResultSet + X5 pool hard-cap/eviction (blocked on an async wait primitive); mongodb native
document API (`Collection` with typed BSON docs and lazy cursors) + SRV/replica-set/topology + sessions
and real transactions.

**Phase 4 - long tail.**
postgres binary formats + COPY IN + multi-host; mysql compression + LOAD DATA + ed25519; mssql TDS 8.0
strict + TVP/BCP + Azure AD; mongodb change streams + GridFS + indexes + compression + AWS/LDAP/OIDC auth.

## Seam and runtime dependencies (not per-driver)

Several gaps cannot be closed inside a driver package:

- A **streaming ResultSet / cursor** abstraction in `db.nova` (blocks X4 and mongodb lazy cursors).
- An **async wait primitive** (`aio.sleep` is a stub) — blocks the pool hard-cap wait queue and
  postgres idle LISTEN/NOTIFY delivery.
- A wider **`DbError`** (numeric code + severity + detail) — blocks X3.
- Optional temporal/array/binary **DbValue variants** for full type fidelity.

The mongodb driver additionally needs an architectural decision: a **native document API** alongside
the SQL seam, since bolting more onto `query`/`exec` keeps hitting the seam wall.
