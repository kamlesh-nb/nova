# Design: a native MongoDB document API for nova-mongodb

Status: design (no implementation yet). Author pass 2026-08-07.

## Why

The `nova-mongodb` driver today implements the SQL-shaped `db` seam (`Driver.connect ->
Connection`, `Connection.query(sql, params)`, `exec`). MongoDB is document-oriented, so that seam
is the wall (see `docs/design/driver-gap-plan.md`, section M):

- `query(collection, _)` runs `find` with an EMPTY filter, so there is no way to express a
  server-side filter, projection, sort, skip, or limit. Clients must fetch the whole collection and
  filter in Nova.
- `exec` has nowhere to carry a document, so writes degrade to a `find` and perform nothing.
- Results are flattened to a single `Text` column holding each document's JSON, so type fidelity is
  lost.
- `prepare`/`queryPrepared`/`begin`/`commit`/`rollback` are meaningless stubs.

The fix is a native document API alongside the seam, not a replacement. Everything already built
stays: the OP_MSG framing (`proto`/`codec`), `runCommand`, SCRAM auth, the BSON codec, connection
setup. The new API is a typed surface on top of `runCommand`.

## Principles

1. **Reuse the wire core.** `runCommand(BsonDocument) -> BsonDocument` is the one primitive; every
   document operation is a command builder plus a typed result reader over it.
2. **Coexist with the seam.** `MongoConnection impl Connection` stays for generic tooling that speaks
   the seam; the document API is reached through new accessors and is what real apps use.
3. **Typed in, typed out.** Callers build filters and documents with builders (not raw JSON strings)
   and read results through typed accessors, never by re-parsing `docToJson`.
4. **Lazy cursors.** `find`/`aggregate` return a `Cursor` that drains `firstBatch` then `getMore`s,
   and `killCursors` on close. No more "read only the first batch" truncation and no `batchSize`
   stopgap.
5. **Nova constraints are first-class** (see the Constraints section): closures cannot `await`, so
   iteration is method-based; async methods return `T | error`; BSON buffers are `ptr`-backed and
   ARC-owned with care.

## Surface

Entry points hang off the existing connection:

```
let conn = await mongodb.MongoDriver().connect("mongodb://127.0.0.1:27017/shop");
let db = conn.database("shop");            // or conn.defaultDatabase()
let users = db.collection("users");
```

### Document model (`mongodb.Doc` + `mongodb.Value`)

A read/write document with typed access, replacing "documents as JSON strings". It wraps a
`bson.BsonDocument` but exposes typed getters and a builder so callers never touch raw BSON offsets.

```
pub struct Doc {
    // builder
    pub fn set(self: Doc, key: string, v: Value): Doc     // fluent, returns self
    pub fn setStr(self, key: string, v: string): Doc
    pub fn setInt(self, key: string, v: long): Doc
    pub fn setDouble(self, key: string, v: double): Doc
    pub fn setBool(self, key: string, v: bool): Doc
    pub fn setDoc(self, key: string, v: Doc): Doc
    pub fn setArray(self, key: string, v: List<Value>): Doc
    pub fn setObjectId(self, key: string, v: ObjectId): Doc
    pub fn setDate(self, key: string, epochMillis: long): Doc
    pub fn setNull(self, key: string): Doc

    // reader
    pub fn has(self: Doc, key: string): bool
    pub fn getStr(self, key: string): string | undefined
    pub fn getInt(self, key: string): long | undefined       // int32 + int64 both widen to long
    pub fn getDouble(self, key: string): double | undefined
    pub fn getBool(self, key: string): bool | undefined
    pub fn getDoc(self, key: string): Doc | undefined
    pub fn getArray(self, key: string): List<Value> | undefined
    pub fn getObjectId(self, key: string): ObjectId | undefined
    pub fn getDate(self, key: string): long | undefined      // epoch millis
    pub fn keys(self: Doc): List<string>
    pub fn toJson(self: Doc): string                          // relaxed extended JSON (debug)
}

pub fn doc(): Doc                                             // empty builder
```

`Value` is the element union so heterogeneous arrays and generic access work:

```
pub enum ValueKind { Null, Str, Int, Double, Bool, Doc, Array, ObjectId, Date, Binary, Decimal }
pub struct Value {
    pub kind: ValueKind
    pub fn asStr / asInt / asDouble / asBool / asDoc / asArray / asObjectId / asDate ...
}
pub fn vStr(s) / vInt(n) / vDouble(d) / vBool(b) / vDoc(d) / vArray(xs) / vObjectId(o) / vDate(ms) ...
```

`ObjectId` is a first-class 12-byte value with generation and hex round-trip (closes the BSON gap
where ObjectId is decode-only today):

```
pub struct ObjectId { pub fn hex(self): string }
pub fn newObjectId(): ObjectId          // 4-byte time + 5-byte random + 3-byte counter
pub fn objectIdFromHex(s: string): ObjectId | undefined
```

### Filter and update builders

A fluent filter that lowers to a BSON filter document. It only assembles BSON (which the codec
already does), so it is thin:

```
pub struct Filter {
    pub fn eq(self, field: string, v: Value): Filter
    pub fn ne / gt / gte / lt / lte (self, field, v): Filter
    pub fn inList(self, field: string, vs: List<Value>): Filter
    pub fn ninList(self, field: string, vs: List<Value>): Filter
    pub fn exists(self, field: string, b: bool): Filter
    pub fn regex(self, field: string, pattern: string, opts: string): Filter
    pub fn and(self, other: Filter): Filter
    pub fn or(self, other: Filter): Filter
    pub fn raw(self, d: Doc): Filter          // escape hatch: arbitrary filter doc
    fn toBson(self): bson.BsonDocument
}
pub fn filter(): Filter
pub fn all(): Filter                          // matches everything ({}), replaces today's empty find
```

Updates use the same shape for `$set`/`$inc`/`$push`/`$unset`:

```
pub struct Update { pub fn set / inc / push / unset / raw ... }
pub fn update(): Update
```

### Collection

```
pub struct Collection {
    // read
    pub async fn find(self, f: Filter, opts: FindOptions): Cursor
    pub async fn findOne(self, f: Filter): Doc | undefined
    pub async fn countDocuments(self, f: Filter): long
    pub async fn estimatedDocumentCount(self): long
    pub async fn distinct(self, field: string, f: Filter): List<Value>
    pub async fn aggregate(self, pipeline: List<Doc>): Cursor

    // write (return typed results, not the seam's ExecResult)
    pub async fn insertOne(self, d: Doc): InsertResult
    pub async fn insertMany(self, docs: List<Doc>): InsertResult
    pub async fn updateOne(self, f: Filter, u: Update, opts: UpdateOptions): UpdateResult
    pub async fn updateMany(self, f: Filter, u: Update): UpdateResult
    pub async fn replaceOne(self, f: Filter, replacement: Doc, opts: UpdateOptions): UpdateResult
    pub async fn deleteOne(self, f: Filter): DeleteResult
    pub async fn deleteMany(self, f: Filter): DeleteResult
    pub async fn findOneAndUpdate(self, f: Filter, u: Update, opts): Doc | undefined
    pub async fn bulkWrite(self, ops: List<WriteOp>): BulkResult

    // indexes (thin)
    pub async fn createIndex(self, keys: Doc, opts: IndexOptions): string
    pub async fn dropIndex(self, name: string): void
}

pub struct FindOptions { pub projection: Doc, pub sort: Doc, pub skip: long, pub limit: long, pub batchSize: int }
pub struct UpdateOptions { pub upsert: bool }
pub struct InsertResult { pub insertedCount: long, pub insertedIds: List<ObjectId>, pub err: DbError }
pub struct UpdateResult { pub matched: long, pub modified: long, pub upsertedId: ObjectId | undefined, pub err: DbError }
pub struct DeleteResult { pub deletedCount: long, pub err: DbError }
```

Every result carries a `DbError` classified onto the shared `DBERR_*` taxonomy (write errors,
duplicate key = `DBERR_UNIQUE_VIOLATION`, etc.), consistent with the SQL drivers.

### Cursor (lazy, getMore + killCursors)

```
pub struct Cursor {
    pub async fn next(self: Cursor): Doc | undefined     // undefined when exhausted; drives getMore
    pub async fn toList(self: Cursor): List<Doc>          // eager drain (bounded by the result)
    pub async fn forEachDoc(self: Cursor): ...            // see Constraints: method loop, not a closure
    pub async fn close(self: Cursor): void                // killCursors if cursor.id != 0
    pub fn batch(self: Cursor): List<Doc>                 // the current in-memory batch
}
```

Iteration is `while (let d = await cur.next()) { ... }` style (method-based) because Nova closures
cannot `await` (so a `forEach(fn)` that awaits inside `fn` is not expressible).

## Wire mapping (command builders to add to `commands.nova`)

All are `runCommand` payloads. The current `findCommand(dbName, coll, filter)` is extended and joined
by the rest:

| API call | Command document |
|---|---|
| `find` | `{find, filter, projection, sort, skip, limit, batchSize, $db}` |
| cursor drain | `{getMore: <cursorId int64>, collection, batchSize, $db}` |
| `close` | `{killCursors: coll, cursors: [<id>], $db}` |
| `insertOne/Many` | `{insert: coll, documents: [...], ordered, $db}` |
| `updateOne/Many/replaceOne` | `{update: coll, updates: [{q, u, upsert, multi}], $db}` |
| `deleteOne/Many` | `{delete: coll, deletes: [{q, limit}], $db}` |
| `countDocuments` | `{aggregate: coll, pipeline: [{$match}, {$count}], cursor:{}, $db}` |
| `distinct` | `{distinct: coll, key, query, $db}` |
| `aggregate` | `{aggregate: coll, pipeline: [...], cursor:{batchSize}, $db}` |
| `createIndex` | `{createIndexes: coll, indexes: [{key, name, unique}], $db}` |

Reply reading uses the existing `cursor.firstBatch` / `cursor.nextBatch` extraction, generalized to
capture `cursor.id` (an int64) so the `Cursor` can `getMore`. Write replies carry `n`, `nModified`,
`upserted`, and a `writeErrors` array which maps to the typed results above.

Multi-document writes should use OP_MSG **section kind 1** document sequences (the `documents` /
`updates` / `deletes` payload) rather than a body array, which is both the canonical framing and the
efficient one. Kind-1 support is a `codec.encodeOpMsg` extension (today it writes kind 0 only).

## BSON codec work this unblocks (do first)

The document model needs these `bson.nova` gaps closed (from the gap analysis, section I):

1. **ObjectId**: add `entryObjectId` + a serialise case for type 7 + generation; today it is
   decode-only, so you cannot query or round-trip by `_id`. This is prerequisite for almost every
   operation.
2. **Date (type 9) and Timestamp (type 17)**: typed build + read (they currently decode to an
   ambiguous int64 with no builder).
3. **int64 / double native accessors**: expose 64-bit and floating reads (today only int32/string/
   bool/binary/doc/array are readable; int64 and double are hi/lo-split with no accessor).
4. **Binary subtypes**: preserve the subtype byte (UUID subtype 4 in particular).
5. The unknown-type parser guard already landed (stops the desync/infinite-loop), so it is safe to
   extend the type set incrementally.

## Coexistence with the SQL seam

`MongoConnection` keeps `impl Connection` (query/exec/prepare/begin/...) unchanged, so anything that
speaks the generic `db` seam still works (with the documented loose semantics). The document API is
additive:

```
pub fn database(self: MongoConnection, name: string): Database
pub fn defaultDatabase(self: MongoConnection): Database    // the DSN's db
```

`Database.collection(name) -> Collection`. The seam methods and the document API share the one
`runCommand` and the one socket + busy guard, so concurrency rules are unchanged (one in-flight op
per connection; use a pool for parallelism).

## Nova-specific constraints (call out, do not rediscover)

- **Closures cannot `await`.** Cursor iteration and `bulkWrite` must be method/loop driven, not
  `forEach(asyncFn)`. (Same lesson as the web mediator's `next.proceed()`.)
- **Async fn returns `T | error`.** Document methods surface failures either as `.err` on a result
  struct (writes) or as an error union (connect/auth). Keep it consistent with the SQL drivers'
  `rs.err`.
- **BSON buffers are `ptr`-backed and ARC-owned.** `serialize` returns a `ptr`; adopt it as a string
  where ARC should free it, and free scratch buffers in `delete`. Follow the existing
  `nova-ptr-field-arc-ownership` rule and verify with `--asan`.
- **`getText` on a numeric `DbValue` returns ""** in the SQL seam; the document API sidesteps this by
  having typed getters return `T | undefined` rather than reusing `DbValue`.
- **One connection = one socket + busy guard.** True concurrency needs a Mongo-aware pool (a later
  phase); the document API must not assume otherwise.

## Phasing

Each phase is independently shippable and live-verifiable against a local mongod.

- **P1 - BSON foundation:** ObjectId (build/serialise/generate) + Date/Timestamp + int64/double
  accessors + binary subtype. Unit-gated offline. Unblocks everything.
- **P2 - read path:** `Doc`/`Value` model, `Filter` builder, `Collection.find/findOne` with
  server-side filter/projection/sort/skip/limit, and a lazy `Cursor` with `getMore` + `killCursors`.
  Removes the `batchSize` stopgap. Verify: seed a collection > one batch, filter + sort + limit, drain.
- **P3 - write path:** `insertOne/Many`, `updateOne/Many`, `replaceOne`, `deleteOne/Many`,
  `findOneAndUpdate`, typed results with `DBERR_*` classification, OP_MSG kind-1 document sequences.
  Verify: insert, read back by `_id`, update, delete, duplicate-key → `isUniqueViolation()`.
- **P4 - aggregation and admin:** `aggregate`, `countDocuments`, `estimatedDocumentCount`,
  `distinct`, `bulkWrite`, index create/drop.
- **P5 - sessions and durability:** client sessions (`lsid`), retryable writes (`txnNumber`), read/
  write concern, multi-document transactions.
- **P6 - topology:** `mongodb+srv://` (DNS SRV/TXT), multi-host + replica-set discovery (SDAM), read
  preference, load-balanced mode, a Mongo-aware connection pool.

P1 to P4 make it a usable document driver; P5 to P6 make it production-grade for replica sets and
Atlas. The SQL seam remains throughout for compatibility.

## Open questions

1. **Where does `Doc`/`Value`/`ObjectId` live?** Option A: in `nova-mongodb` (driver-local, keeps the
   seam pure). Option B: a shared `data/document` stdlib module if a document seam is ever wanted for
   other document stores. Recommendation: start driver-local (A); promote later only if a second
   document backend appears.
2. **Reuse `bson.BsonDocument` vs a new `Doc`?** `Doc` should wrap `BsonDocument` (not replace it) so
   the codec stays the single source of truth; `Doc` adds the typed read/write ergonomics the raw
   `docGet*` API lacks.
3. **Error surface for reads:** `find` errors via the returned `Cursor` (a `Cursor.err` +
   `Cursor.ok()`), mirroring `ResultSet.err`, rather than an error union, so iteration stays simple.
