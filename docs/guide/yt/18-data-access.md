# Video 18: Data access and NovaDB

- Chapter: [18-data-access.md](../18-data-access.md)
- Estimated length: ~15 minutes
- You will need: Nova installed, a terminal, and the guide's `examples/` folder handy (`28_db_drivers.nova` and the `webapp/` project). Watching Video 16 on serialization and Video 17 on the web service first will help.

## Hook (0:00)

**Say:** In the last video we built a web service, but it kept its products in memory. Real services use a database. In this video you will see how Nova talks to one. There is a single interface, the `Connection` seam, that every driver implements, so the code you write does not change when you change databases. You will see the drivers, the connection strings, how the micro-ORM turns rows into your typed structs, and finally we will take the exact web app from the last video and point it at a live NovaDB by changing one file.

## What we will cover (0:30)

**On screen:**
```
- One seam, many drivers: NovaDB, PostgreSQL, MySQL, SQL Server, MongoDB
- Connection strings: the novadb:// URL and the bare form
- Typed parameters: DbValue and $1 placeholders, never string concatenation
- The micro-ORM: bindAll and bindOne into @serializable structs
- The repository: written against the Connection trait
- Swapping the web app onto a real NovaDB
```

## Segment: One seam, many drivers (1:00)

**Say:** Nova has one data-access interface, the `Connection` trait in `data.db`. Every database is a separate driver package that implements it. You pick the driver in one place, and everything above it is driver-agnostic.

**On screen:**
```
NovaDB      import novadb;    NovaDriver().connect("novadb://user:pass@127.0.0.1:3009?db=shop")
PostgreSQL  import postgres;  PgDriver().connect("postgresql://user:pass@127.0.0.1:5432/shop")
MySQL       import mysql;     MyDriver().connect("mysql://user:pass@127.0.0.1:3306/shop")
SQL Server  import mssql;     MssqlDriver().connect("mssql://user:pass@127.0.0.1:1433/shop")
MongoDB     import mongodb;   mongodb.open("mongodb://user:pass@127.0.0.1:27017/shop")
```

**Say:** For the four SQL databases it is the same seam, so the query code you write is identical whichever one you use. MongoDB is the exception: it is not relational, so instead of `query` and `exec` the `mongodb` package gives you a native document API, typed documents, a filter and update builder, lazy cursors, sessions and transactions, and a typed ORM that reads and writes your `@serializable` structs. Chapter 18 in the written guide has the full walkthrough. A driver package is organised by responsibility, not by prefixed file names: a `connection` module that parses the connection string, a `codec` for the wire protocol, `proto` for framing, `typemap`, `auth`. The one file you touch is the seam module named after the database.

## Segment: Connection strings (2:30)

**Say:** A NovaDB connection string is a URL. Everything except the host is optional, and the bare host and port form works too.

**On screen:**
```
novadb://user:password@host:port?db=name&tls=verify&tlsCAFile=/etc/ca.pem

NovaDriver().connect("novadb://app:secret@db.internal:3009?db=shop");  // full URL
NovaDriver().connect("127.0.0.1:3009?db=shop");                        // no scheme, no credentials
NovaDriver().connect("127.0.0.1:3009");                               // minimal; defaults fill the rest
```

**Say:** The query parameters are the database name, credentials as an alternative to the userinfo, and TLS options: `tls=true` to encrypt, `tls=verify` to also validate the server certificate against a CA file. No port defaults to 3009.

## Segment: Typed parameters (3:45)

**Say:** Now, the most important rule in this whole video: never build SQL by pasting values into strings. Nova passes values as typed `DbValue` parameters, with dollar-one, dollar-two placeholders that the driver fills in safely.

**On screen:**
```nova
import list;
import data.db;

let params = List<DbValue>();
params.push(db.dbInt(42));        // an int
params.push(db.dbText("Alice"));  // a string
params.push(db.dbLong(90000));    // a 64-bit value

let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
```

**Say:** `query` returns a `ResultSet`: the columns, each with a name and a type, and the rows. This is identical for every driver, and it is what keeps injection attacks out by construction. Note the `await`: `connect`, `query`, and `exec` are async, so inside an async function you await them.

## Segment: The micro-ORM (5:15)

**Say:** Reading cells by index is tedious. The micro-ORM in `data.orm` binds a whole result set into your typed structs, matching columns to fields by name. Mark the struct `@serializable` and the compiler generates the binder.

**On screen:**
```nova
import data.orm;

@serializable pub struct Product {
    pub id: int,
    pub name: string,
}

let products = orm.bindAll<Product>(rs);   // List<Product>
let one      = orm.bindOne<Product>(rs);   // Product | undefined
```

**Say:** `bindAll` gives you a typed list, `bindOne` gives you the first row or `undefined` for an empty result, which fits Nova's optionals. The example `28_db_drivers.nova` builds a result set exactly the way a driver returns one, then binds it, all offline. Let us run it.

**Run it:**
```sh
nova test docs/guide/examples/28_db_drivers.nova
```

**On screen:**
```
PASS  typed_parameters
PASS  bind_all_rows
PASS  bind_one_or_undefined
PASS  positional_read

Results: ... passed, 0 failed
```

**Say:** So the seam, the parameters, and the ORM are all verifiable without a running server. Now let us put them behind a repository.

## Segment: The repository (7:30)

**Say:** Keep the data access out of your handlers by putting it behind a repository. The key detail is the field type: it holds the `Connection` trait, not a concrete driver, so the same repository runs against any database.

**On screen:**
```nova
pub struct ProductRepository impl Service {
    conn: Connection,                       // the trait, not a concrete type
    init(conn: Connection) { self.conn = conn; }

    pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
        let params = List<DbValue>();
        params.push(db.dbInt(id));
        let rs = await self.conn.query("SELECT id, name, price FROM products WHERE id = $1", params);
        return orm.bindOne<ProductDto>(rs);
    }
}
```

**Say:** This is the whole repository from the web app. Await the I/O, then bind the rows with the synchronous binder. It is written once and never changes, whichever database backs it.

## Segment: Swapping the web app onto NovaDB (9:15)

**Say:** Here is the payoff. The web app from Video 17 built an in-memory connection in its composition root. That in-memory connection implements the same `Connection` trait NovaDB does, which is why the repository never noticed the difference. To move onto a real database we change the composition root and nothing else. There is no container and no downcast: we construct a different `Connection` and pass it to the same repository.

**On screen:**
```nova
// main.nova (in-memory, the default build)
let conn = InMemoryConnection();
let repo = ProductRepository(conn);

// main_novadb.nova (the same app, live NovaDB): only the connection changes
let conn = PooledConnection(dsn, poolSize);   // a Connection over a NovaDB pool
let repo = ProductRepository(conn);
```

**Say:** One rule matters here. Opening a connection is asynchronous, and you cannot drive an asynchronous call to completion from the synchronous `main` before the event loop starts. So `PooledConnection` wraps a pool that is built synchronously and opens its connections lazily, inside a request, where the handler is already awaiting. Everything else, the features, handlers, DTOs, validators, and routes, is shared between the two builds unchanged. That is the whole point of writing the repository against the seam.

## Segment: Transactions (11:30)

**Say:** The seam also has begin, commit, and rollback. A transaction runs on one connection, so you acquire a connection from the pool, begin, do the writes on that same connection, then commit or roll back, and release it. The per-call pooled connection is fine for single statements; for a transaction you hold a connection explicitly.

## Segment: Running it live (12:30)

**Say:** To see it end to end, the guide ships `run-live.sh`. It starts a NovaDB server, builds the NovaDB-backed app, and curls a create and a read, so you watch a value travel from an HTTP request into NovaDB and back.

**Run it:**
```sh
cd docs/guide/examples && ./run-live.sh
```

**Say:** It builds everything it needs and cleans up after itself. We will use the second half of that script, the orchestrator, in the next video.

## Recap (13:45)

**Say:** Let us recap.

- Nova has one data-access seam, `Connection`, and a driver per database: NovaDB, PostgreSQL, MySQL, SQL Server, MongoDB.
- A connection string is a URL, `novadb://user:pass@host:port?db=name`, and a bare host and port works too.
- Values are typed `DbValue` parameters with dollar-N placeholders, never string-concatenated.
- The micro-ORM binds rows into `@serializable` structs with `bindAll` and `bindOne`.
- Write your repository against the `Connection` trait, and the same code runs on any database.
- Swapping the web app onto NovaDB changed one file, because the repository depends on the seam.

## Outro (15:00)

**Say:** Your web app now reads and writes a real database. In the next video we run it in production shape: several replicas behind a load balancer, supervised and kept alive. That is the orchestrator. See you in Video 21.
