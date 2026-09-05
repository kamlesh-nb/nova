# 20. Database drivers

Nova talks to a database through one interface and many drivers. The interface is the `Connection` seam
in the standard library (`data.db`); each concrete database ships as its own package that implements the
seam. You add the driver you need with `nova get`, import it, and write your queries against the shared
seam. Because every SQL driver speaks the same `Connection` vocabulary, the query and exec code you write
is identical whichever engine you point it at. MongoDB is the one exception: it is not relational, so it
carries a native document API alongside the seam.

This chapter is a tour of the four drivers (PostgreSQL, MySQL, SQL Server, MongoDB), how to add each one
to a project, and how to connect and run a query. The data layer above the driver, the ORM and the
repository, is covered in the Data access chapter; here we stay close to the wire.

## One seam, many packages

The core types live in the standard library and never change from driver to driver:

- `Connection` and `Driver` are the two traits every driver implements (`data.db`). A `Driver` has one
  method, `connect(dsn)`, which returns a `Connection`. A `Connection` carries `query`, `exec`,
  `prepare`, `queryWire`, and the transaction methods `begin` / `commit` / `rollback`.
- `DbValue` is one tagged database cell, and the `dbX` constructor family (`dbInt`, `dbLong`, `dbText`,
  `dbDouble`, `dbBool`, `dbDecimal`, `dbUuid`, `dbTimestamp`, `dbJson`, `dbBlob`, `dbNull`) builds the
  parameters you bind into a statement.
- `ResultSet`, `Row`, and `Column` are the materialised result a `query` returns; `Rows<T>` is the
  typed, buffer-owning result the micro-ORM returns.

A driver is a git-backed package under its own repository. You do not vendor it or copy files: you add its
URL to your project and import the module. Package management is covered in its own chapter; the short
version is that `nova get <url>` appends the dependency to `project.json` and resolves it, and then
`import <name>;` makes the driver types available.

### Bind values, never concatenate

The single rule that applies to every SQL driver: pass values as `DbValue` parameters with `$1`, `$2`,
`...` placeholders, and never build SQL by joining strings. String concatenation is how injection bugs
get in; bound parameters close that door by construction.

```nova
import list;
import data.db;

let params = List<DbValue>();
params.push(db.dbInt(42));         // $1
params.push(db.dbText("Alice"));   // $2

let rs = await conn.query("SELECT id, name FROM users WHERE id = $1 AND name = $2", params);
```

`db.noParams()` is the tidy way to spell an empty parameter list for a statement that binds nothing. The
placeholder style is PostgreSQL-flavoured (`$1`, `$2`) across all three SQL drivers, and each driver
rewrites it to its own engine's placeholder syntax internally.

`query` returns a `ResultSet` you can read positionally:

```nova
let r = rs.row(0);
let id   = r.getInt(0);
let name = r.getText(1);
```

`connect`, `query`, `exec`, `prepare`, and the transaction methods are all `async`, so you `await` them
inside an `async` function. `close` and `setTimeout` are synchronous.

## Pooling

A single connection serves one query at a time, so a server that handles concurrent requests wants a
pool. The standard library ships one driver-agnostic pool, `pool.Pool`, that works with every driver: you
give it a `Driver`, a DSN, and an idle size, and it hands out connections and takes them back.

```nova
import pool;
import postgres;

let p = pool.Pool(PgDriver(), "postgresql://app:secret@127.0.0.1:5432/shop", 8);

let conn = await p.acquire();      // borrow a live connection (opens one if the idle set is empty)
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
p.release(conn);                   // return it to the pool for reuse
```

`Pool(driver, dsn, maxIdle)` is the constructor; `acquire()` is `async` (it may need to open a fresh
connection), and `release(conn)` is synchronous. `configure(maxOpen, maxLifetimeMs, validateOnBorrow)`
tunes the bounds, and `discard(conn)` drops a connection you no longer trust rather than returning it.
The same `Pool` type backs `PgDriver`, `MyDriver`, `MssqlDriver`, and `MongoDriver` without change: there
is no per-driver pool. `ResilientPool` wraps a `Pool` with a circuit breaker for services that must
degrade gracefully when the database is unreachable.

Now the drivers, one at a time.

## PostgreSQL

PostgreSQL is the widely deployed open-source relational database. The Nova driver speaks the v3 wire
protocol with SCRAM-SHA-256 authentication and server-side prepared statements.

### Add it to your project

```sh
nova get https://github.com/kamlesh-nb/nova-postgres
```

```json
{
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-postgres"
  ]
}
```

```nova
import postgres;
import db;
```

The driver type is `PgDriver` and the connection type is `PgConnection`.

### Connect and query

```nova
let drv  = PgDriver();
let conn = await drv.connect("postgresql://user:pass@127.0.0.1:5432/mydb");

let params = List<DbValue>();
params.push(db.dbInt(1));
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
```

### Connection string

```
postgresql://user:password@host:port/database?sslmode=...&sslrootcert=...&connect_timeout=...
```

- The scheme is optional. User, password, and database are percent-decoded (RFC 3986), so `p%40ss`
  becomes `p@ss`. IPv6 literals in brackets, `[::1]:5432`, are handled without splitting inside the
  address.
- The database is a path segment (`/mydb`). Defaults: user `postgres`, database equal to the user, port
  `5432`.
- `sslmode` is `disable` (the default), `require`, or `verify-full`; `sslrootcert` is the CA bundle for
  verification; `connect_timeout` is in seconds and defaults to 10.

### Notes

The driver uses server-side prepared statements with a per-connection statement cache. For results too
large to hold in memory, `PgConnection.queryStream(sql, params, batchSize)` returns an async `Cursor`
that pages rows from the server so the full set never materialises:

```nova
import postgres;

let conn = await postgres.open("postgresql://user@127.0.0.1:5432/db");
let cur = await conn.queryStream("SELECT id, body FROM events ORDER BY id", db.noParams(), 500);
while (let row = await cur.next()) {   // fetches the next 500-row batch only when the current drains
    // ... process row ...
}
let _ = await cur.close();             // release the server-side cursor if you stop early
```

`postgres.open(dsn)` returns the concrete `PgConnection` (the type that carries `queryStream`), whereas
`PgDriver().connect(dsn)` returns the `Connection` trait. TLS runs over the standard-library async TLS
stack, and the driver also supports LISTEN/NOTIFY and COPY.

## MySQL

MySQL (and MariaDB) is another widely deployed open-source relational database. The Nova driver handles
the native, sha2, caching_sha2, and RSA authentication methods and uses server-side prepared statements
over the binary protocol.

### Add it to your project

```sh
nova get https://github.com/kamlesh-nb/nova-mysql
```

```json
{
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-mysql"
  ]
}
```

```nova
import mysql;
import db;
```

The driver type is `MyDriver` and the connection type is `MyConnection`.

### Connect and query

```nova
let conn = await MyDriver().connect("mysql://root:pass@127.0.0.1:3306/mydb");

let params = List<DbValue>();
params.push(db.dbInt(1));
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
```

### Connection string

```
mysql://user:password@host:port/database?sslmode=...&sslrootcert=...&connect_timeout=...&allowPublicKeyRetrieval=...
```

- The scheme is optional. Unlike PostgreSQL there is no percent-decoding. Defaults: user `root`, empty
  database, port `3306`.
- `sslmode` is `disable` (the default), `skip-verify` (encrypt without verifying the certificate),
  `require`, `verify-ca`, or `verify-full`; the last three verify the CA bundle and fail closed.
- `allowPublicKeyRetrieval` defaults to false. Setting it true opts in to fetching the server's RSA
  public key for caching_sha2 full authentication over a plaintext link, which carries a
  man-in-the-middle risk, so leave it off unless you understand the trade-off.

### Notes

`MyConnection.queryStream(sql, params, batchSize)` returns an async `Cursor` over a server-side cursor,
the same streaming shape as PostgreSQL. `mysql.open(dsn)` returns the concrete `MyConnection`.

## SQL Server

Microsoft SQL Server is the enterprise relational database. The Nova driver speaks TDS 7.4 with the
PRELOGIN and LOGIN7 handshake, over TLS, with server-side prepared statements.

### Add it to your project

```sh
nova get https://github.com/kamlesh-nb/nova-mssql
```

```json
{
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-mssql"
  ]
}
```

```nova
import mssql;
import db;
```

The driver type is `MssqlDriver` and the connection type is `MssqlConnection`.

### Connect and query

```nova
let conn = await MssqlDriver().connect("mssql://sa:pass@127.0.0.1:1433/mydb");

let params = List<DbValue>();
params.push(db.dbInt(1));
let rs = await conn.query("SELECT TOP 1 id, name FROM users WHERE id = $1", params);
```

### Connection string

```
mssql://user:password@host:port/database?encrypt=...&trustServerCertificate=...&tlsCAFile=...&connect_timeout=...
```

- The scheme is optional. Defaults: user `sa`, database `master`, port `1433`.
- It is secure by default. TLS is on unless you set `?encrypt=false`, and the server certificate is
  verified against `?tlsCAFile=<path>` unless you set `?trustServerCertificate=true`. A development
  server without TLS needs an explicit `?encrypt=false`.

### Notes

SQL Server does not accept `LIMIT`; use `SELECT TOP n` instead. NVARCHAR and VARCHAR columns are
transcoded from UTF-16LE and CP1252 into UTF-8, so there is no zero-copy lazy string path here (unlike
PostgreSQL and MySQL, where a text cell can be borrowed straight from the wire buffer). Streaming works
the same way: `MssqlConnection.queryStream(sql, params, batchSize)` returns an async `Cursor`, and
`mssql.open(dsn)` returns the concrete `MssqlConnection`.

One historical note on credentials: TDS obfuscates the password on the wire with a trivial nibble-swap,
which is not encryption. Your credentials are protected by TLS, not by that obfuscation, which is another
reason the driver is secure by default.

## MongoDB

MongoDB is a document database, not a relational one, so it does not fit the `query` / `exec` seam the
SQL drivers share. `MongoConnection` still implements the `Connection` trait (so it can sit behind the
same `pool.Pool`), but day to day you use the native document API: typed documents, a fluent filter and
update builder, lazy cursors, and a typed ORM over your `@serializable` structs.

### Add it to your project

```sh
nova get https://github.com/kamlesh-nb/nova-mongodb
```

```json
{
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-mongodb"
  ]
}
```

```nova
import mongodb;
```

The driver type is `MongoDriver` and the connection type is `MongoConnection`. `MongoDriver().connect(dsn)`
returns the `Connection` trait, but the document API hangs off the concrete type, which you reach through
`mongodb.open(dsn)`.

### Connect

```nova
// A single server.
let conn = await mongodb.open("mongodb://user:pass@127.0.0.1:27017/shop");

// A replica set from a seed list. Unreachable seeds are skipped; the driver discovers the primary.
let rs = await mongodb.open("mongodb://h1:27017,h2:27017,h3:27017/shop?replicaSet=rs0");

// mongodb+srv:// resolves the seed list and options from DNS (SRV + TXT) and defaults to TLS.
let atlas = await mongodb.open("mongodb+srv://user:pass@cluster0.example.mongodb.net/shop");
```

The DSN is a standard MongoDB URI:

```
mongodb://[user:pass@]host:port[,host2:port2...][/db][?replicaSet=NAME&readPreference=...&tls=...]
```

- Defaults: port `27017`, database `test`. A comma-separated seed list triggers topology discovery.
- Query options are `replicaSet`, `readPreference`, `retryWrites` (default true), `tls` (`true` or
  `verify`), `tlsCAFile`, `authMechanism` (`SCRAM-SHA-1` or `MONGODB-X509`; the default is
  SCRAM-SHA-256), `tlsCertificateKeyFile`, and `connectTimeoutMS`.

### The document API

`conn.database(name).collection(name)` gives you a `Collection`, the handle for reads and writes. Build a
filter with `mongodb.filter()`, an update with `mongodb.update()`, and a document with `mongodb.doc()`:

```nova
let coll = conn.database("shop").collection("products");

// Read.
let cur = await coll.find(mongodb.filter().eqStr("category", "pizza"), mongodb.findOptions());
while (let doc = await cur.next()) {
    let name = doc.getStr("name");   // string | undefined
}
let _ = await cur.close();

let one = await coll.findOne(mongodb.filter().eqStr("name", "Margherita"));   // Doc | undefined

// Write. Every write returns a result carrying .ok() and a normalised .err (a DbError).
let ins = await coll.insertOne(mongodb.doc().setStr("name", "Calzone").setInt("price", 11));
let upd = await coll.updateOne(
    mongodb.filter().eqStr("name", "Calzone"),
    mongodb.update().setInt("price", 12),
    false);   // upsert?
let del = await coll.deleteOne(mongodb.filter().eqStr("name", "Calzone"));
```

The full surface is in the Data access chapter: `insertMany`, `updateMany`, `deleteMany`,
`findOneAndUpdate`, `aggregate`, `countDocuments`, `bulk()`, plus sessions and transactions, change
streams, and GridFS for large files.

### The typed ORM

Rather than hand-building a `Doc` per field, mark a struct `@serializable` and let the driver serialise
it. The bridge functions are `docOf<T>` (struct to `Doc`), `bindOne<T>` (`Doc` to struct), and
`bindAll<T>` (list of docs to list of structs):

```nova
@serializable pub struct Product {
    pub name: string,
    pub price: int,
    init() { self.name = ""; self.price = 0; }   // @serializable needs a no-arg init
}

let p = Product();
p.name = "Margherita"; p.price = 9;
await coll.insertOne(mongodb.docOf<Product>(p));

let products = mongodb.bindAll<Product>(await coll.find(mongodb.all(), mongodb.findOptions()).toList());
```

`docOf`, `bindOne`, and `bindAll` are synchronous on purpose: you fetch first (the `await`) and then
convert, because the compiler resolves the concrete type only outside the async frame.

## Repository and the ORM

You rarely read cells by index in application code. The micro-ORM in `data.orm` maps a result set onto
your typed structs by column name, and the generic `Repository<T>` wraps a `Connection` so your handlers
never see SQL. This layer is shared across all three SQL drivers, since it is written against the seam.

Mark the target struct `@serializable` so the compiler generates the binder, then bind a result set:

```nova
import data.orm;

@serializable pub struct Product {
    pub id: int,
    pub name: string,
}

let products = await orm.queryRows<Product>(conn, "SELECT id, name FROM products", db.noParams());
```

`Repository<T>(conn, "products")` gives you `all`, `findBy(keyCol, val)`, `query(sql, params)`, `add`,
`update`, `remove`, and the DTO-mapping `listAs<D>` / `oneAs<D>` on top of that. The reads go through the
buffer-safe path (`queryRows`), so they are always sound. `bindOne<T>` and `bindAll<T>` bind a `ResultSet`
you already hold.

### The compile-time SQL check

A typed query whose SQL is a string literal is checked at build time, before your program ever runs:

- Placeholders must be contiguous. `$N` must form a run `1..max` with no `$0` and no gaps, or the build
  fails.
- A literal `SELECT` must cover every plain field of `T`. If `T` has a `name` field and you write
  `SELECT id, naem FROM products`, the typo is a compile error, not a runtime surprise. The check skips
  `SELECT *` (it cannot know the columns), unnameable expression columns without an alias, and fields
  carrying `@from` / `@derive` attributes (which may map a differently named column).

If a `schema.sql` file is present in the compile directory, the check additionally verifies column
existence and type compatibility against your `CREATE TABLE` definitions.

### The zero-copy `Str` caveat

There are two read paths and the difference matters. `queryRows<T>` (and every `Repository` read, which
uses it) returns a `Rows<T>` that owns the wire buffer, so any zero-copy `str.Str` text field in `T` stays
valid as long as you hold the `Rows`. This is the sound, fast path.

`queryAs<T>` returns a bare `List<T>` and drops the result set. If any text field of `T` binds as a
zero-copy `str.Str` view (the common, fast case), those views dangle once the buffer is gone. Use
`queryAs<T>` only when every text field of `T` is an owned `string`. When in doubt, use `queryRows<T>` or
a `Repository`. `str.Str.toOwned()` promotes a view to an owned string when a value must outlive its row.

## Where to go next

- The Data access chapter puts the seam to work inside a web app: the repository pattern, transactions
  on a held connection, and swapping the same app from an in-memory connection onto a live PostgreSQL by
  changing one file. It also covers the full MongoDB document API.
- The Deploying chapter runs a PostgreSQL-backed service under the orchestrator, which keeps its own
  control-plane state in `artifactd`.
