# 18. Data access: the db seam, drivers, and NovaDB

The web service in the previous chapter stored its products in memory. Real services keep their data in
a database. This chapter shows how Nova talks to one: the `db` seam that every driver implements, the
drivers themselves (NovaDB, PostgreSQL, MySQL, SQL Server, MongoDB), the micro-ORM that turns rows into
your typed structs, and the repository pattern that keeps all of this out of your handlers. At the end we
take the exact web app from Chapter 17 and point it at a live NovaDB, changing one file.

The running code for this chapter is `examples/28_db_drivers.nova` (the seam and the ORM, verifiable
offline) and `examples/webapp/src/main_novadb.nova` (the same web app, backed by NovaDB).

## One seam, many drivers

Nova has a single data-access interface, the `Connection` trait in `data.db`. Every driver is a separate
package that implements it:

| Database   | Import            | Open a connection |
|------------|-------------------|-------------------|
| NovaDB     | `import novadb;`  | `NovaDriver().connect("novadb://user:pass@127.0.0.1:3009?db=shop")` |
| PostgreSQL | `import postgres;`| `PgDriver().connect("postgresql://user:pass@127.0.0.1:5432/shop")` |
| MySQL      | `import mysql;`   | `MyDriver().connect("mysql://user:pass@127.0.0.1:3306/shop")` |
| SQL Server | `import mssql;`   | `MssqlDriver().connect("mssql://user:pass@127.0.0.1:1433/shop")` |
| MongoDB    | `import mongodb;` | document API over the same package layout |

Because they share the `Connection` seam, the code you write against it does not change when you change
databases. You pick the driver in one place, at startup, and everything above it is driver-agnostic.

A driver package is laid out by responsibility, not by a per-file prefix: `connection` (the
connection-string parser), `codec` (the wire protocol), `proto` (transport framing), `typemap` (type
mapping), `auth`, and `stmt`. The one file a consumer touches is the seam module named after the database
(`novadb`, `postgres`, ...), which exposes the driver and connection types.

## Connection strings

A NovaDB connection string is a URL:

```
novadb://user:password@host:port?db=name&tls=verify&tlsCAFile=/etc/ca.pem
```

Everything except the host is optional. The bare `host:port` form works too, so all of these are valid:

```nova
NovaDriver().connect("novadb://app:secret@db.internal:3009?db=shop");  // full URL
NovaDriver().connect("127.0.0.1:3009?db=shop");                        // no scheme, no credentials
NovaDriver().connect("127.0.0.1:3009");                               // minimal; defaults fill the rest
```

The query parameters are `db` (database name), `user`/`password` (an alternative to the `user:pass@`
userinfo), `tls` (`true` to encrypt, `verify` to also validate the server certificate), and `tlsCAFile`
(a PEM bundle for verification). When no port is given it defaults to `3009`.

## Values and parameters

Never build SQL by concatenating strings. Nova passes values as typed `DbValue` parameters, with `$1`,
`$2`, ... placeholders in the SQL that the driver fills in safely. You construct `DbValue`s with the
small constructors in `db`:

```nova
import list;
import data.db;

let params = List<DbValue>();
params.push(db.dbInt(42));        // an int
params.push(db.dbText("Alice"));  // a string
params.push(db.dbLong(90000));    // a 64-bit value
// db.dbNull(), db.dbBool(...), db.dbDecimal(...) round out the set.
```

This is identical for every driver. A query then looks like:

```nova
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
```

`query` returns a `ResultSet`: a list of `Column`s (name plus `DbType`) and a list of `Row`s. You can
read a row positionally when you do not want a struct:

```nova
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

```nova
import data.orm;

@serializable pub struct Product {
    pub id: int,
    pub name: string,
}

let products = orm.bindAll<Product>(rs);          // List<Product>
let one      = orm.bindOne<Product>(rs);          // Product | undefined (first row, or none)
```

`bindOne` returns `undefined` for an empty result set, so it fits Nova's optionals: you narrow it with
`if (one == undefined)` before using it. `examples/28_db_drivers.nova` exercises all of this offline,
building a `ResultSet` by hand exactly as a driver would return it, then binding it. Run it with
`nova test examples/28_db_drivers.nova`.

## The repository pattern

Put the data access behind a repository so your handlers never see SQL. The important detail is the
field type: the repository holds the `Connection` **trait**, not a concrete driver type, so the same
repository runs against the in-memory database, NovaDB, or any other driver.

```nova
import data.db;
import data.orm;

pub struct ProductRepository impl Service {
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

## Swapping the web app onto NovaDB

Chapter 17's app registered an `InMemoryConnection`. `InMemoryConnection` implements the same
`Connection` trait NovaDB does, which is why the repository never needed to know the difference. To move
the app onto a real database, change the composition root and nothing else.

`examples/webapp/src/main.nova` (the default, in-memory build) registers the connection under the
`Connection` seam key. The composition root knows the concrete type, so it downcasts to it; the
repository constructor then widens that concrete value into its `Connection` field:

```nova
services.addSingleton("Connection", (sp) => { return InMemoryConnection(); });
services.addScoped("ProductRepository", (sp) => { return ProductRepository(sp.require("Connection") as InMemoryConnection); });
```

`examples/webapp/src/main_novadb.nova` is the same app with a live NovaDB. It registers the same key with
a NovaDB-backed connection, and the factory downcasts to that concrete type:

```nova
services.addSingleton("Connection", (sp) => { return NovaDbConnection("novadb://admin@127.0.0.1:3009?db=nova"); });
services.addScoped("ProductRepository", (sp) => { return ProductRepository(sp.require("Connection") as NovaDbConnection); });
```

There is one rule that shapes `NovaDbConnection`: **do not open the socket in `main`.** Connecting is
asynchronous and must run on the reactor, which only exists once `app.run` starts; block-driving a
connect from a cold `main` crashes. So `NovaDbConnection` connects **lazily**, on its first query, which
is always inside an async request handler where the reactor is live:

```nova
// Features/Products/Shared/novadb_connection.nova (a Connection that opens itself on first use)
async fn ensure(self: NovaDbConnection): Connection {
    let existing = self.conn;
    if (existing != undefined) { return existing; }
    let c = await self.driver.connect(self.dsn);   // on the reactor, inside a request
    // create the schema once (NovaDB supports CREATE TABLE IF NOT EXISTS), then reuse the connection
    return c;
}
```

Everything else, the features, handlers, DTOs, validators, behaviours, routes, and views, is shared
between the two builds without a single change. That is the payoff of writing the repository against the
seam. Build it with `nova build --file src/main_novadb.nova` (the app imports the `novadb` package, so
the project needs `packages/` reachable; `run-live.sh` sets that up for you).

## Transactions

The `Connection` seam exposes `begin`, `commit`, and `rollback`. In the web app they are wired as a
behaviour (`TransactionBehavior` in `examples/webapp`): the mediator pipeline opens a transaction around
every command, commits when the handler returns normally, and rolls back if it reports an error. Your
handler code stays free of transaction plumbing, exactly as validation and logging do.

## Running it live

`examples/run-live.sh` runs the whole loop end to end: it builds and starts a NovaDB server on
`127.0.0.1:3009`, builds `main_novadb`, starts the app, and curls a create and a read so you can watch a
value travel from an HTTP request into NovaDB and back out. It then puts the app behind the orchestrator,
which is the subject of Chapter 21.

## Where to go next

- Chapter 17 for the web framework the repository plugs into.
- Chapter 21 for deploying this NovaDB-backed app under the orchestrator (proxyd, orchd, orchctl).
- Chapter 16 for `@serializable`, which powers both JSON responses and the ORM binder.
- The database driver packages (`nova-postgres`, `nova-mysql`, `nova-mssql`, `nova-mongodb`,
  `nova-novadb`) for the connection-string options each one accepts.
