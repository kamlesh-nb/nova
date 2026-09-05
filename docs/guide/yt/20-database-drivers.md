# Video 20: Database drivers

- Chapter: [20-database-drivers.md](../20-database-drivers.md)
- Estimated length: ~14 minutes
- You will need: Kyte installed, `git`, and, if you want to run the queries, one of the databases to hand. Watching Video 18 on data access and Video 19 on package management first is ideal.

## Hook (0:00)

**Say:** Kyte talks to a database through one interface and many drivers. The interface is the Connection seam in the standard library; each database ships as its own git package that implements it. In this video we tour all four: PostgreSQL, MySQL, SQL Server, and MongoDB. For each you will see the one command that adds it, the import, the connection string, and how you connect. Because every SQL driver speaks the same seam, the query code is identical whichever engine you point at.

## What we will cover (0:30)

**On screen:**
```
- One seam: Connection / Driver / DbValue
- Bind values, never concatenate
- One pool for every driver
- PostgreSQL, MySQL, SQL Server: same seam
- MongoDB: the document exception
```

## Segment: One seam (1:00)

**Say:** The core types live in the standard library and never change from driver to driver. A Driver has one method, connect, returning a Connection. A Connection carries query, exec, prepare, and begin, commit, rollback. DbValue is one database cell, built with the small dbX constructors. And a driver is a git package: kyte get its URL, import the module, done.

**On screen:**
```
Driver.connect(dsn) -> Connection
Connection: query / exec / prepare / begin / commit / rollback
DbValue: db.dbInt, db.dbText, db.dbLong, db.dbBool, db.dbDecimal, db.dbUuid, ...
```

## Segment: Bind values, never concatenate (2:15)

**Say:** The one rule that applies to every SQL driver: pass values as DbValue parameters with dollar-one, dollar-two placeholders, and never join strings. That is how injection bugs get in, and bound parameters close the door by construction.

**On screen:**
```kyte
let params = List<DbValue>();
params.push(db.dbInt(42));         // $1
params.push(db.dbText("Alice"));   // $2
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1 AND name = $2", params);
```

**Say:** The dollar-N style is the same across all three SQL drivers; each rewrites it to its own engine internally.

## Segment: One pool for every driver (3:30)

**Say:** A single connection serves one query at a time, so a server wants a pool. The standard library ships one driver-agnostic pool that works with all of them: give it a Driver, a DSN, and an idle size.

**On screen:**
```kyte
import pool;
import postgres;
let p = pool.Pool(PgDriver(), "postgresql://app:secret@127.0.0.1:5432/shop", 8);
let conn = await p.acquire();      // opens one if the idle set is empty
let rs = await conn.query("SELECT id, name FROM users WHERE id = $1", params);
p.release(conn);
```

**Say:** The same Pool backs every driver: PgDriver, MyDriver, MssqlDriver, MongoDriver, no per-driver pool. Now the drivers, one at a time. The pattern is always the same three lines: kyte get the URL, import the module, connect with a URL.

## Segment: PostgreSQL, MySQL, SQL Server (5:00)

**Say:** The three SQL engines follow the identical pattern; only the URL and the driver type change.

**On screen:**
```
PostgreSQL
  kyte get https://github.com/kamlesh-nb/nova-postgres
  import postgres;
  await PgDriver().connect("postgresql://user:pass@127.0.0.1:5432/shop")

MySQL
  kyte get https://github.com/kamlesh-nb/nova-mysql
  import mysql;
  await MyDriver().connect("mysql://user:pass@127.0.0.1:3306/shop")

SQL Server
  kyte get https://github.com/kamlesh-nb/nova-mssql
  import mssql;
  await MssqlDriver().connect("mssql://user:pass@127.0.0.1:1433/shop")
```

**Say:** For Postgres and MySQL the database is the path segment. SQL Server is encrypted by default, so a local server without a trusted certificate needs trustServerCertificate turned on in the query string. And this is the payoff of the seam: the query and exec code above these three lines is byte-for-byte identical across the three engines. Change the driver and the URL, keep the queries.

## Segment: MongoDB, the document exception (9:30)

**Say:** MongoDB is not relational, so it does not fit query and exec. Instead the mongodb package gives you a native document API: typed documents, a fluent filter and update builder, lazy cursors, sessions and transactions, and a typed ORM that reads and writes your serializable structs.

**On screen:**
```
kyte get https://github.com/kamlesh-nb/nova-mongodb
import mongodb;
let conn = await mongodb.open("mongodb://user:pass@127.0.0.1:27017/shop");

let coll = conn.database("shop").collection("products");
let one  = await coll.findOne(mongodb.filter().eqStr("name", "Margherita"));
await coll.insertOne(mongodb.doc().setStr("name", "Calzone").setInt("price", 11));
```

**Say:** MongoConnection still implements the Connection trait, so it can sit behind the same pool, but the document methods are what you use day to day. The full document API, including replica sets, change streams, transactions, and GridFS, is in the Data access chapter.

## Segment: From driver to data layer (12:00)

**Say:** Everything so far stayed close to the wire. Above the driver, the data layer is where you spend your time: the micro-ORM binds rows into your structs with bindAll and bindOne, and the generic Repository-of-T maps a whole table for you. Both work over any of these drivers, because they only speak the Connection seam. And remember the compile-time SQL check: a literal SELECT that does not cover every field of your struct is a build error, not a runtime surprise.

**On screen:**
```kyte
let repo = Repository<Product>(conn, "products");
let all  = await repo.all();              // Rows<Product>
let rows = await repo.query("SELECT id, name, price FROM products WHERE price > $1", params);
```

## Recap (13:15)

**Say:** Four drivers, one seam. Each is a git package you add with kyte get, import by its module name, and connect with a URL. The three SQL drivers share the same query code; MongoDB brings a document API. Put a pool in front for a real server, and write your data access against the Connection trait so none of it cares which database is underneath. Next we take a database-backed app and deploy it.

**On screen:**
```
Next: Video 23, Deploying with the orchestrator
```
