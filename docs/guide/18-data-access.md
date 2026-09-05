# 18. Data access: the db seam, drivers, and the repository pattern

The web service in the previous chapter stored its products in memory. Real services keep their data in
a database. This chapter shows how Kyte talks to one: the `db` seam that every driver implements, the
drivers themselves (PostgreSQL, MySQL, SQL Server, MongoDB), the micro-ORM that turns rows into your
typed structs, and the repository pattern that keeps all of this out of your handlers. At the end we take
the exact web app from Chapter 17 and point it at a live PostgreSQL, changing one file.

The running code for this chapter is `examples/28_db_drivers.ky` (the seam and the ORM, verifiable
offline) and `examples/webapp/main_postgres.ky` (the same web app, backed by PostgreSQL).

## One seam, many drivers

Kyte has a single data-access interface, the `Connection` trait in `data.db`. Every driver is a separate
package that implements it:

| Database   | Import            | Open a connection |
|------------|-------------------|-------------------|
| PostgreSQL | `import postgres;`| `PgDriver().connect("postgresql://user:pass@127.0.0.1:5432/shop")` |
| MySQL      | `import mysql;`   | `MyDriver().connect("mysql://user:pass@127.0.0.1:3306/shop")` |
| SQL Server | `import mssql;`   | `MssqlDriver().connect("mssql://user:pass@127.0.0.1:1433/shop")` |
| MongoDB    | `import mongodb;` | a native document API (see [MongoDB: the document API](#mongodb-the-document-api) below) |

Because they share the `Connection` seam, the code you write against it does not change when you change
databases. You pick the driver in one place, at startup, and everything above it is driver-agnostic.

A driver package is laid out by responsibility, not by a per-file prefix: `connection` (the
connection-string parser), `codec` (the wire protocol), `proto` (transport framing), `typemap` (type
mapping), `auth`, and `stmt`. The one file a consumer touches is the seam module named after the database
(`postgres`, `mysql`, ...), which exposes the driver and connection types.

## Connection strings

A PostgreSQL connection string is a URL:

```
postgresql://user:password@host:port/database?sslmode=verify-full&sslrootcert=/etc/ca.pem
```

Everything except the host is optional, so all of these are valid:

```kyte
PgDriver().connect("postgresql://app:secret@db.internal:5432/shop");   // full URL
PgDriver().connect("postgresql://127.0.0.1:5432/shop");                // no credentials
PgDriver().connect("postgresql://127.0.0.1/shop");                     // minimal; defaults fill the rest
```

The database is a path segment (`/shop`). User, password, and database are percent-decoded (RFC 3986).
The query parameters are `sslmode` (`disable`, `require`, or `verify-full`), `sslrootcert` (a CA bundle
for verification), and `connect_timeout` (in seconds). When no port is given it defaults to `5432`, the
user defaults to `postgres`, and the database defaults to the user.

## Values and parameters

Never build SQL by concatenating strings. Kyte passes values as typed `DbValue` parameters, with `$1`,
`$2`, ... placeholders in the SQL that the driver fills in safely. You construct `DbValue`s with the
small constructors in `db`:

```kyte
import list;
import data.db;

let params = List<DbValue>();
params.push(db.dbInt(42));        // an int
params.push(db.dbText("Alice"));  // a string
params.push(db.dbLong(90000));    // a 64-bit value
// db.dbNull(), db.dbBool(...), db.dbDecimal(...) round out the set.
```

This is identical for every driver. A query then looks like:

```kyte
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
```

`query` returns a `ResultSet`: a list of `Column`s (name plus `DbType`) and a list of `Row`s. You can
read a row positionally when you do not want a struct:

```kyte
let r = rs.row(0);
let id   = r.getInt(0);
let name = r.getText(1);
```

`connect`, `query`, `exec`, `prepare`, and the transaction methods (`begin`/`commit`/`rollback`) are all
`async`; `close` and `setTimeout` are synchronous. Inside an `async` function you `await` the async ones.

## The micro-ORM: rows into structs

Reading cells by index gets tedious and fragile. The micro-ORM in `data.orm` binds a whole result set
into typed structs, mapping columns to fields by name. Mark the target struct `@serializable` so the
compiler generates the binder:

```kyte
import data.orm;

@serializable pub struct Product {
    pub id: int,
    pub name: string,
}

let products = orm.bindAll<Product>(rs);          // List<Product>
let one      = orm.bindOne<Product>(rs);          // Product | undefined (first row, or none)
```

`bindOne` returns `undefined` for an empty result set, so it fits Kyte's optionals: you narrow it with
`if (one == undefined)` before using it. `examples/28_db_drivers.ky` exercises all of this offline,
building a `ResultSet` by hand exactly as a driver would return it, then binding it. Run it with
`kyte test examples/28_db_drivers.ky`.

## The repository pattern

Put the data access behind a repository so your handlers never see SQL. The important detail is the
field type: the repository holds the `Connection` **trait**, not a concrete driver type, so the same
repository runs against the in-memory database, PostgreSQL, or any other driver.

```kyte
import data.db;
import data.orm;

pub struct ProductRepository {
    conn: Connection,                       // the trait, not a concrete type
    init(conn: Connection) { self.conn = conn; }

    pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
        let params = List<DbValue>();
        params.push(db.dbInt(id));
        // Await the I/O, then bind the rows with the synchronous ORM binder.
        let rs = await self.conn.query("SELECT id, name, price FROM products WHERE id = $1", params);
        return orm.bindOne<ProductDto>(rs);
    }

    pub async fn create(self: ProductRepository, name: string, price: int): int {
        let params = List<DbValue>();
        params.push(db.dbText(name));
        params.push(db.dbLong(price));
        let r = await self.conn.exec("INSERT INTO products (name, price) VALUES ($1, $2)", params);
        return r.rows_affected as int;
    }
}
```

This is the whole repository from `examples/webapp`. It is written once and never changes, whichever
database backs it.

## The generic `Repository<T>`

When a repository is a thin wrapper over one table, the stdlib gives you a ready one:
`data.repository.Repository<T>`. Bind it to an entity type and a table, and it maps rows to `T` by name
for you, so a slice never writes bind code:

```kyte
import data.db;
import data.repository;

let repo = Repository<Product>(conn, "products");
let all  = await repo.all();                                  // Rows<Product>: SELECT * FROM products
let one  = await repo.findBy("id", db.dbInt(7));              // Rows<Product> filtered by a column
let rows = await repo.query(                                   // your own SQL, still bound to Product
    "SELECT id, name, price FROM products WHERE price > $1", params);
let _r   = await repo.add(product);                           // INSERT every field of the entity
```

`Repository<T>` also offers `update`, `remove`, and the projection helpers `listAs<D>`/`oneAs<D>` for
reading into a DTO that differs from the table entity. The reads return a buffer-owning `Rows<T>`, which
is the sound path. There is also a lower-level `orm.queryAs<T>` that binds without owning the buffer, so
its `str.Str` fields dangle once the buffer is freed; prefer `queryRows<T>` or `Repository<T>` unless you
know the buffer outlives the rows.

One nicety worth knowing: a **literal** `SELECT` in `db.query<T>`, `orm.queryRows<T>`, `Repository.query`,
or a `querySql` tagged template is checked at COMPILE TIME. If the selected columns do not cover every
plain field of `T`, or the `$N` placeholders are not contiguous from `$1`, the build fails. A typo like
`naem` is a compile error, not a runtime surprise. The check skips `SELECT *` and computed expressions,
where it cannot know the shape.

## Swapping the web app onto PostgreSQL

Chapter 17's app built an `InMemoryConnection` in its composition root. `InMemoryConnection` implements
the same `Connection` trait the PostgreSQL driver does, which is why the repository never needed to know
the difference. To move the app onto a real database, change the composition root and nothing else. There
is no container and no downcast: you construct a different `Connection` and pass it to the same
`ProductRepository`.

`examples/webapp/src/main.ky` (the default, in-memory build):

```kyte
let conn = InMemoryConnection();
let repo = ProductRepository(conn);
registerProducts(app, repo);
```

`examples/webapp/main_postgres.ky` is the same app with a live PostgreSQL. The only change is the
connection:

```kyte
let conn = PooledConnection(dsn, poolSize);   // a Connection backed by a PostgreSQL pool
let repo = ProductRepository(conn);
registerProducts(app, repo);
```

There is one rule that shapes `PooledConnection`: **do not open a socket in `main`.** Connecting is
asynchronous, and you cannot drive an asynchronous call to completion from the synchronous `main` before
the event loop starts. So `PooledConnection` wraps a `pool.Pool(PgDriver(), dsn, size)`, which is
constructed synchronously and opens its connections LAZILY, inside a request, where the handler is already
awaiting:

```kyte
// Features/Products/Shared/pooled_connection.ky (a Connection over a pool)
pub struct PooledConnection impl Connection {
    p: pool.Pool,
    init(dsn: string, size: int) {
        self.p = pool.Pool(PgDriver(), dsn, size);
        self.p.configure(size, 0, false);
    }
    async fn query(self: PooledConnection, sql: string, params: List<DbValue>): ResultSet {
        let c = await self.p.acquire();          // opens on first use, reuses thereafter
        let rs = await c.query(sql, params);
        self.p.release(c);
        return rs;
    }
    // exec / queryWire / ... delegate the same way; close / setTimeout are synchronous.
}
```

Everything else, the features, handlers, DTOs, validators, routes, and views, is shared between the two
builds without a single change. That is the payoff of writing the repository against the seam. Because
`main_postgres.ky` imports the `postgres` package, the project needs that dependency and the driver
reachable; `run-live.sh` wires it up and builds it for you.

## Transactions

The `Connection` seam exposes `begin`, `commit`, and `rollback`. A transaction must run on ONE
connection, so you acquire a connection from the pool, run `begin`, do the writes on that same
connection (a `Repository<T>` built over it, or direct `exec` calls), then `commit` or `rollback`, and
release it:

```kyte
let c = await pool.acquire();
let _ = await c.begin();
let repo = Repository<Order>(c, "orders");
// ... writes on repo / c ...
let _ = await c.commit();     // or c.rollback() on failure
pool.release(c);
```

The `PooledConnection` adapter above acquires a fresh connection per call, which is correct for the
single-statement queries the demo issues but cannot span a transaction. For transactional work, hold a
connection explicitly as shown here.

## Streaming large result sets

`query` buffers the whole result in memory, which is fine for a page of rows but not for a report over
millions. Each SQL driver's concrete connection (from `postgres.open` / `mysql.open` / `mssql.open`)
offers `queryStream`, which returns an async cursor that pulls rows from the server in batches so the
full set never materialises:

```kyte
import postgres;

let conn = await postgres.open("postgresql://user@host/db");
let cur = await conn.queryStream("SELECT id, body FROM events ORDER BY id", db.noParams(), 500);
while (let row = await cur.next()) {      // fetches the next 500-row batch only when the current one drains
    // ... process row ...
}
let _ = await cur.close();               // release the server-side cursor if you stop early
```

The API is identical across the three SQL drivers; only the wire mechanism differs (Postgres portals,
MySQL a server-side cursor, SQL Server the TDS token stream). The batch size is the third argument.
Always `close()` the cursor when you finish, especially if you break out early, so the server-side
cursor is released and the connection returns to a clean state for reuse. MongoDB does not use
`queryStream`: it streams through the lazy `find()` cursor shown below (backed by `getMore`), which
pulls documents in batches the same way.

## Running it live

`examples/run-live.sh` runs the whole loop end to end: it connects to a PostgreSQL server on
`127.0.0.1:5432`, seeds the schema, builds `main_postgres`, starts the app, and curls a create and a read
so you can watch a value travel from an HTTP request into PostgreSQL and back out. It then puts the app
behind the orchestrator, which is the subject of Chapter 23.

## MongoDB: the document API

MongoDB is not relational, so it does not fit the `query`/`exec` seam the SQL drivers share. Instead the
`mongodb` package gives you a native document API: typed documents, a fluent filter and update builder,
lazy cursors, sessions and transactions, and a typed ORM that reads and writes your `@serializable`
structs directly. `MongoConnection` still implements the `Connection` trait, so it can sit behind the
same pool, but the document methods are what you use day to day.

The package is laid out by responsibility, matching the Go driver's names: `wiremessage` (OP_MSG
framing), `operation` (command builders), `dns` (the `mongodb+srv://` resolver), plus `document` (the
typed model) and `mongodb` (the client seam you import).

### Connecting

`mongodb.open` returns a live `MongoConnection`. The DSN is a standard MongoDB URI:

```kyte
import mongodb;

// A single server.
let conn = await mongodb.open("mongodb://user:pass@127.0.0.1:27017/shop");

// A replica set from a seed list. Unreachable seeds are skipped; the driver discovers the primary.
let rs = await mongodb.open("mongodb://h1:27017,h2:27017,h3:27017/shop?replicaSet=rs0");

// mongodb+srv:// resolves the seed list and options from DNS (SRV + TXT), and defaults to TLS.
let atlas = await mongodb.open("mongodb+srv://user:pass@cluster0.example.mongodb.net/shop");
```

The query options are `replicaSet`, `readPreference` (`primary` / `primaryPreferred` / `secondary` /
`secondaryPreferred` / `nearest`), `retryWrites` (`false` to disable), `tls` (`true` / `verify`) and
`tlsCAFile`. A connection that could not reach a usable node comes back marked failed, so the first
operation on it surfaces the reason rather than crashing.

Authentication is SCRAM-SHA-256 by default (username and password in the URI). Add
`authMechanism=SCRAM-SHA-1` for older servers or users created with SHA-1 credentials. The driver also
supports **X.509 client-certificate auth**, where the certificate presented during the TLS handshake is
the credential:

```kyte
// The client certificate is the identity: no password. tlsCertificateKeyFile is the combined cert+key
// PEM. Add tls=verify + tlsCAFile to also verify the server's chain (fully mutual, verified TLS).
let conn = await mongodb.open(
    "mongodb://cluster.example:27017/shop?tls=verify&tlsCAFile=/etc/ca.pem"
    + "&authMechanism=MONGODB-X509&tlsCertificateKeyFile=/etc/client.pem");
```

`conn.database(name).collection(name)` gives you a `Collection`, the handle for everything below.

### Documents: build and read

A `Doc` wraps a BSON document. You build one with fluent, typed setters, and read fields back with typed
getters that return `T | undefined`, so a missing or wrong-typed field is never a silent zero:

```kyte
let d = mongodb.doc()
    .setStr("name", "Margherita")
    .setInt("price", 9)
    .setBool("vegetarian", true);

let name = d.getStr("name");     // string | undefined
let price = d.getInt("price");   // long | undefined
```

The getters cover `getStr` / `getInt` / `getDouble` / `getBool` / `getDecimal` / `getObjectId` /
`getDate` / `getDoc` (a nested sub-document) / `getArray` (a list of typed `Value`s). `has(key)` tests
presence.

### Querying

Build a filter with the fluent `Filter`, and options (projection, sort, skip, limit) with `FindOptions`:

```kyte
let f = mongodb.filter()
    .eqStr("category", "pizza")
    .gtInt("price", 5);

let opts = mongodb.findOptions()
    .sortAsc("price")
    .include("name").include("price")   // projection
    .withLimit(20);

// find returns a LAZY cursor: it fetches batches with getMore until the server cursor is exhausted.
let cur = await coll.find(f, opts);
while (let doc = await cur.next()) {    // undefined ends the loop
    let n = doc.getStr("name");
    // ...
}
let _ = await cur.close();              // releases the server cursor if not fully drained

// Convenience: one document, or the whole result as a list.
let one = await coll.findOne(mongodb.filter().eqStr("name", "Margherita"));   // Doc | undefined
let all = await (await coll.find(mongodb.all(), mongodb.findOptions())).toList();
```

`Filter` also has `eqInt` / `eqBool` / `eqObjectId`, the range operators `gtInt` / `gteInt` / `ltInt` /
`lteInt` / `neInt`, `inStr` (an `$in` list), `regexStr`, and `raw(doc)` as an escape hatch for any
operator not wrapped yet. `mongodb.all()` is the empty filter that matches everything.

### Writing

Every write returns a small result carrying `.ok()` and a normalised `.err` (a `DbError` you can classify
with `isUniqueViolation()` and friends):

```kyte
let ins = await coll.insertOne(mongodb.doc().setStr("name", "Calzone").setInt("price", 11));
// insertOne generates an ObjectId _id when the document has none, returned in ins.insertedIds.

let upd = await coll.updateOne(
    mongodb.filter().eqStr("name", "Calzone"),
    mongodb.update().setInt("price", 12).incInt("stock", -1),   // { $set: {price}, $inc: {stock} }
    false);                                                       // upsert?

let del = await coll.deleteOne(mongodb.filter().eqStr("name", "Calzone"));

// Atomic read-modify-write, returning the pre- or post-image.
let doc = await coll.findOneAndUpdate(f, mongodb.update().incInt("views", 1), true, false);
```

The write methods are `insertOne` / `insertMany`, `updateOne` / `updateMany` / `replaceOne`,
`deleteOne` / `deleteMany`, and `findOneAndUpdate`. The `Update` builder emits `$set` (`setStr` / `setInt`
/ `setDouble` / `setBool`), `$inc` (`incInt`), and `$unset` (`unset`).

Single-document writes are **retryable**: on a transient failure the driver retries once, idempotently.
Multi-document writes stream their documents in an OP_MSG document sequence (the wire-efficient bulk
form) rather than nesting a large array in the command.

### Typed structs: the ORM both ways

Hand-building a `Doc` per field is tedious. Mark a struct `@serializable` and let the driver serialise it:

```kyte
@serializable pub struct Product {
    pub name: string,
    pub price: int,
    pub inStock: bool,
    init() { self.name = ""; self.price = 0; self.inStock = false; }   // @serializable needs a no-arg init
}

let p = Product();
p.name = "Margherita"; p.price = 9; p.inStock = true;

await coll.insertOne(mongodb.docOf<Product>(p));   // docOf serialises the struct to a Doc

// Read documents straight back into typed structs.
let products = mongodb.bindAll<Product>(await coll.find(mongodb.all(), mongodb.findOptions()).toList());
let first    = mongodb.bindOne<Product>(await coll.findOne(mongodb.all()));   // narrow the Doc|undefined first
```

`docOf`, `bindAll`, and `bindOne` are **synchronous** on purpose: the compiler resolves the concrete type
only outside an `async` frame, so you fetch first (the `await`) and then convert. It is the same fetch
then bind split the SQL micro-ORM uses.

### Typed values and decimals

`distinct` returns strings; `distinctValues` returns a typed `Value` for each element, so numbers stay
numbers:

```kyte
let prices = await coll.distinctValues("price", mongodb.all());
let i = 0;
while (i < prices.size()) {
    let v = prices.get(i);
    if (v != undefined) {
        let n = v.asInt();       // long | undefined; a cross-type accessor returns undefined
    }
    i = i + 1;
}
```

`Value` has `asStr` / `asInt` / `asDouble` / `asDecimal` / `asBool` / `asObjectId` / `asDate` / `asDoc` /
`asArray`, plus `toStr()` and `typeTag()`. BSON `decimal128` round-trips exactly through `getDecimal` and
`asDecimal`.

### Aggregation, counting, and indexes

```kyte
let cur = await coll.aggregate(pipeline);              // a List<Doc> of stages, returns a lazy cursor
let n   = await coll.countDocuments(mongodb.all());    // exact count
let est = await coll.estimatedDocumentCount();         // fast metadata count
let cats = await coll.distinct("category", mongodb.all());

await coll.createIndex(mongodb.doc().setInt("name", 1), "name_idx", true);   // keys, name, unique?
await coll.dropIndex("name_idx");
```

### Sessions and transactions

Multi-document transactions need a replica set. Open a session, bind a collection to it, and commit or
abort:

```kyte
let s = await conn.startSession();
s.startTransaction();
let acct = s.collection("bank", "accounts");        // this collection's writes join the transaction
let _ = await acct.updateOne(fromFilter, mongodb.update().incInt("balance", -100), false);
let _ = await acct.updateOne(toFilter,   mongodb.update().incInt("balance",  100), false);
let err = await s.commitTransaction();              // or s.abortTransaction() to roll back
if (!err.isEmpty()) { /* both updates rolled back atomically */ }
```

### bulkWrite

Queue a mix of operations and send them in grouped batches:

```kyte
let res = await coll.bulk()
    .insertOne(mongodb.doc().setStr("name", "A"))
    .updateOne(mongodb.filter().eqStr("name", "B"), mongodb.update().setInt("price", 5), true)
    .deleteOne(mongodb.filter().eqStr("name", "C"))
    .execute(true);                                 // ordered?
// res carries insertedCount / matchedCount / modifiedCount / deletedCount / upsertedCount.
```

### Replica sets and high availability

Give the driver a replica-set seed list (or a `mongodb+srv://` URI) and it discovers the topology,
connects to the primary, and heals on a failover **three ways**:

- **Reactively**: a write that hits a stepped-down primary re-discovers the new primary and retries once,
  transparently. You write no failover code.
- **Proactively**: `conn.startMonitor(intervalMs)` spawns a background heartbeat that keeps the topology
  fresh and reconnects on a change on its own; `conn.stopMonitor()` ends it.
- **On demand**: `conn.heartbeat()` runs one check and reconnects if the primary has moved.

`conn.serverType`, `conn.serverHost`, and `conn.members` expose what the driver resolved. Read
preference (`readPreference=secondary`, etc.) selects which member reads go to.

### Change streams

A change stream is a live feed of a collection's changes (insert, update, replace, delete). It needs a
replica set, since it reads from the oplog. `watch` opens one; poll it for events:

```kyte
let cs = await coll.watch(mongodb.docList(), "updateLookup");   // extra pipeline stages, fullDocument mode
while (true) {
    let ev = await cs.next(0);            // blocks for the next event (0 = poll forever)
    if (ev == undefined) { break; }       // stream invalidated (e.g. collection dropped)
    let op = ev.getStr("operationType") ?? "?";     // "insert" / "update" / "delete" / ...
    let full = ev.getDoc("fullDocument");           // the post-image, present under "updateLookup"
    // ... react to the change ...
}
let _ = await cs.close();
```

`coll.watchAll()` is the no-options form (no extra stages, default full-document). `next(maxPolls)` blocks
across idle windows until an event arrives; `tryNext()` polls exactly once and returns `undefined` if the
await window elapsed with nothing new, so you stay in control of the loop.

Every stream tracks a **resume token** (each event's `_id`, plus the cursor's post-batch resume token).
`cs.token()` gives you the latest one to persist; `coll.watchFrom(token, fullDocument)` reopens the stream
exactly where you left off. You rarely need this by hand for failover: a dropped primary is recovered
automatically, the driver reconnects and reopens from the last token without dropping an event.

### GridFS: large files

BSON documents cap at 16 MB, so larger files (images, videos, backups) go in GridFS, which splits a file
into fixed-size chunks across two collections (`<bucket>.files` for metadata, `<bucket>.chunks` for the
bytes). The `gridfs` module is a separate import, matching the Go driver's layout:

```kyte
import mongodb;
import gridfs;

let bk = gridfs.bucket(conn, "shop", "fs");   // the "fs" bucket on the "shop" database
let _ = await bk.ensureIndexes();             // once, when provisioning: the standard GridFS indexes

let up = await bk.upload("logo.png", bytes);  // bytes is a binary-carrying string; returns the hex _id
let dl = await bk.download(up.id);            // reassembles the chunks in order
if (dl.ok()) { /* dl.data is the file's bytes */ }

let f = await bk.findByName("logo.png");      // GridFSFile | undefined (newest wins on duplicate names)
let dl2 = await bk.downloadByName("logo.png");
let files = await bk.listFiles();
let _d = await bk.delete(up.id);              // removes the chunks and the files document
```

The default chunk size is 255 KiB; `gridfs.bucket(conn, db, "fs").withChunkSize(n)` overrides it. The
upload writes all the chunks first and the files document last, so a partial upload leaves no visible
file. The on-disk layout is the standard GridFS format, so files written here are readable by any other
MongoDB driver, and vice versa.

## Where to go next

- Chapter 17 for the web framework the repository plugs into.
- Chapter 19 for package management: how you add a driver dependency with `kyte get`.
- Chapter 20 for the database drivers, each with its intro, package deployment, and connection string.
- Chapter 23 for deploying this PostgreSQL-backed app under the orchestrator (service, orchd, orchctl).
- Chapter 16 for `@serializable`, which powers both JSON responses and the ORM binder.
