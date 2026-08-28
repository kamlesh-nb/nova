# 17. Building a web application

Nova ships a small, direct web framework in the standard library. There is no
mediator, no dependency-injection container, and no annotation magic in the
request path. A route maps a URL to a handler object, the handler reads its
typed input from the request and returns a response, and you wire the handlers
together in a plain composition root that you can read top to bottom.

The framework is built for **hypermedia** applications: handlers return HTML
fragments that the browser swaps into the page, so most features need no
client-side JavaScript. It works just as well for JSON APIs; the only
difference is what a handler puts in the response body.

The running example for this chapter is the project the toolchain scaffolds
with `nova init web`. The full source lives in
[`examples/webapp`](examples/webapp), builds offline, and its tests pass with
`nova test`. Every snippet below is taken from it.

## Vertical slices

The project is organised by **feature**, not by technical layer. Everything one
use case needs (its input type, its handler, its view, its validation) lives in
one folder under `Features/`. This is vertical slice architecture: to change
"create a product" you open one folder, not four parallel `controllers/`,
`models/`, `views/` trees.

```
src/
  main.nova                         composition root
  Domain/
    Entities/Product.nova           the business object (persistence-agnostic)
    Dtos/ProductDto.nova            the shape returned to clients
    Dtos/CreateProductDto.nova
  Features/
    Products/
      routes.nova                   this feature's route table
      CreateProduct/
        command.nova                the write input (a @serializable struct)
        handler.nova                the RouteHandler
        validator.nova              input checks
      GetProductById/
        query.nova                  the read input
        handler.nova
      Shared/
        repository.nova             data access for the feature
        database.nova               an in-memory Connection (the default)
      views/product_card.nsx        an NSX view
  wwwroot/                          static assets
```

## Scaffolding the project

```bash
nova init web --name shop
cd shop
nova build
./build/debug/bin/shop      # serves on http://127.0.0.1:8080
```

`nova init web` writes two manifests, and it is worth knowing which is which:

- **`project.json`** is the Nova manifest. It carries the project name,
  version, and the list of package dependencies the compiler resolves. This is
  the one the build reads. Chapter 19, Package management, covers it in full.
- **`package.json`** is only for the Tailwind CSS command-line tool (an npm
  dev dependency). The Nova build ignores it. If you do not use Tailwind you can
  delete it.

## A read slice: get a product by id

A slice starts with its **input type**. For a read that is a `query`: a plain
`@serializable` struct whose fields the framework fills from the request.

```nova
// Features/Products/GetProductById/query.nova
@serializable pub struct GetProductById {
    pub id: int,
    init() { self.id = 0; }
}
```

The **handler** implements the `RouteHandler` trait from `web.routing`. A
`RouteHandler` is a plain struct that holds its dependencies as fields and
exposes exactly one method, `serve(ctx)`. It reads its typed input with
`ctx.bind<T>()`, does its work, and returns a `Response`.

```nova
// Features/Products/GetProductById/handler.nova
import web.routing;
import web.response;
import web.status;
import Features.Products.GetProductById.query;
import Features.Products.Shared.repository;
import Features.Products.views.product_card;
import Domain.Dtos.ProductDto;

pub struct GetProductByIdHandler impl RouteHandler {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn serve(self: GetProductByIdHandler, ctx: Context): Response {
        let q = ctx.bind<GetProductById>();
        let found = await self.repo.findById(q.id);
        if (found == undefined) {
            return response.Response(Status.NotFound, "product not found");
        }
        let product = found ?? ProductDto{ id: 0, name: "", price: 0 };
        let html = productCard(product.name, product.price);
        return response.Response(Status.Ok, html)
            .setHeader("Content-Type", "text/html; charset=utf-8");
    }
}
```

`ctx.bind<GetProductById>()` fills `id` from the route parameter `{id:int}`.
The repository returns `ProductDto | undefined`, so a missing id is a plain 404;
there is nothing to catch and no exception to model.

## `ctx.bind`, and where the fields come from

`ctx.bind<T>()` deserialises `T` from ONE merged view of the request, so a
handler never parses a URL or a body by hand. The `Context` builds that view
from, in order:

- cookies,
- the query string,
- path parameters (`{id:int}` and friends),
- and, for `POST`/`PUT`/`PATCH`, the request body: `multipart/form-data`,
  `x-www-form-urlencoded`, or JSON, chosen by the `Content-Type`.

Later sources win over earlier ones, so a path parameter overrides a query
parameter of the same name. Two smaller accessors exist for when you want a
single raw value instead of a bound struct:

```nova
let raw = ctx.query("q");     // one query-string value, or ""
let ids = ctx.param("id");    // one path parameter, or ""
```

Because a hypermedia form POSTs `application/x-www-form-urlencoded`, the SAME
`ctx.bind<T>()` reads a submitted form with no extra work.

## Views: NSX

View code lives in `.nsx` files. NSX is the same language as `.nova`, just
filed apart so markup stays separate from logic. An NSX element is a `string`,
so views compose directly and expressions embed with `{...}`.

```nova
// Features/Products/views/product_card.nsx
pub fn productCard(name: string, price: int): Html {
    return <div class="rounded-lg border border-slate-200 p-4 shadow-sm">
        <h3 class="font-semibold text-slate-800">{name}</h3>
        <p class="mt-1 text-sm text-slate-500">{price}</p>
    </div>;
}
```

A `{expr}` interpolation is **HTML-escaped automatically**, so user text like a
product name is safe by default and you never call an escaper. To insert an
already-rendered fragment unescaped (one view composing another), wrap it in
`response.raw(fragment)` from `web.response`. That one boundary, escaped by
default and explicit `raw` when you mean it, is what keeps the views free of
cross-site-scripting holes.

## A write slice: create a product

The write input is a `command`, again a plain `@serializable` struct. Command
means write intent (a `POST`/`PUT`/`DELETE`); query means read intent. They are
the same kind of object, named for what they express.

```nova
// Features/Products/CreateProduct/command.nova
@serializable pub struct CreateProduct {
    pub name: string,
    pub price: int,
    init() { self.name = ""; self.price = 0; }
}
```

Validation is a plain function that returns "" when the input is good, or the
error text otherwise. There is no validator trait to implement and no framework
to register it with; the handler calls it.

```nova
// Features/Products/CreateProduct/validator.nova
pub fn validateCreateProduct(cmd: CreateProduct): string {
    if (cmd.name.length == 0) { return "name is required"; }
    if (cmd.price < 0) { return "price must be >= 0"; }
    return "";
}
```

The handler binds the command, validates it, does the work, and returns the new
product's card. Because this is hypermedia, the 201 body is the HTML fragment
the browser swaps in; for a JSON API you would `serde.json.stringify` a DTO
instead.

```nova
// Features/Products/CreateProduct/handler.nova
pub struct CreateProductHandler impl RouteHandler {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn serve(self: CreateProductHandler, ctx: Context): Response {
        let cmd = ctx.bind<CreateProduct>();
        let err = validateCreateProduct(cmd);
        if (err.length != 0) {
            return response.Response(Status.BadRequest, err);
        }
        let _ = await self.repo.create(cmd.name, cmd.price);
        let html = productCard(cmd.name, cmd.price);
        return response.Response(Status.Created, html)
            .setHeader("Content-Type", "text/html; charset=utf-8");
    }
}
```

## Wiring: routes and the composition root

Each feature owns a small `routes.nova` that binds its paths to handler
instances. `app.get`/`app.post`/`app.put`/`app.delete`/`app.patch` each take a
path and a handler INSTANCE, and you pass that handler its dependencies as plain
constructor arguments.

```nova
// Features/Products/routes.nova
pub fn registerProducts(app: App, repo: ProductRepository): void {
    app.post("/api/products", CreateProductHandler(repo));
    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
}
```

`{id:int}` is a typed path parameter: a non-numeric id never reaches the
handler, it is a 400 at the router. Plain `{name}` captures any single segment.

`main.nova` is the composition root. It builds the shared dependencies ONCE and
calls each feature's `register`. There is no container resolving things behind
your back: you can see every dependency being constructed.

```nova
// main.nova
import web.app;
import Features.Products.Shared.database;
import Features.Products.Shared.repository;
import Features.Products.routes;

fn buildApp(): App {
    let app = App();
    let conn = InMemoryConnection();
    let repo = ProductRepository(conn);
    registerProducts(app, repo);
    app.useStatic("/", "./wwwroot");
    return app;
}

fn main(): void {
    let app = buildApp();
    console.log("Listening on http://127.0.0.1:8080");
    app.run(8080);
}
```

As the app grows you add a feature folder with its own `register(app, deps...)`
and one call here. That is the whole scaling story for structure.

## The data seam

The repository is the one place that knows SQL. Its connection field is the
`Connection` **trait** from `data.db`, not a concrete database type, so the same
repository runs over an in-memory connection in tests and over a real database
in production with no change.

```nova
// Features/Products/Shared/repository.nova
pub struct ProductRepository {
    conn: Connection,
    init(conn: Connection) { self.conn = conn; }

    pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
        let params = List<DbValue>();
        params.push(db.dbInt(id));
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

The starter ships a tiny `InMemoryConnection impl Connection` (in
`Shared/database.nova`) so the app runs and its tests pass with no database
server. Parameters are built with `db.dbInt`/`db.dbText`/`db.dbLong` and bound
to `$1, $2, ...`; the micro-ORM (`orm.bindOne`/`orm.bindAll`) maps result rows
onto `ProductDto` by column name. Chapter 18, Data access and the ORM, covers
the seam, the `Repository<T>` helper, and connection strings in full.

## Testing offline

Handlers are objects, so a test builds the app the same way the composition
root does and drives one request through `app.dispatch(req)` with no socket
open. That makes feature tests fast and hermetic.

```nova
// tests/features/products_test.nova
fn testApp(): App {
    let conn = InMemoryConnection();
    let repo = ProductRepository(conn);
    let app = App();
    app.post("/api/products", CreateProductHandler(repo));
    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
    return app;
}

@test
fn test_get_missing_is_404(): void {
    let app = testApp();
    let req = Request.fromString("GET /api/products/999 HTTP/1.1\r\nHost: x\r\n\r\n");
    let res = app.dispatch(req);
    assert.equalInt(res.status.toCode(), 404);
}
```

```bash
nova test tests/features/products_test.nova
```

## The same app over a real database

The example includes `main_novadb.nova` at the project root: the SAME app over a
real NovaDB. Look at it beside `src/main.nova` and only the composition root
differs. Every feature slice, the repository, the handlers, and the views are
identical, because they depend on the `Connection` trait, never on a driver.

```nova
// main_novadb.nova  (excerpt)
fn buildApp(dsn: string, poolSize: int): App {
    let app = App();
    let conn = PooledConnection(dsn, poolSize);   // built now; connects lazily, per request
    let repo = ProductRepository(conn);
    registerProducts(app, repo);
    app.useStatic("/", "./wwwroot");
    return app;
}
```

`PooledConnection` (in `Shared/pooled_connection.nova`) wraps a
`pool.Pool(NovaDriver(), dsn, size)` and implements `Connection` by acquiring a
connection per call, running the statement, and releasing it. The pool is built
synchronously and opens its connections lazily inside a request, which is the
pattern to reach for: opening a connection is asynchronous, and you cannot drive
an asynchronous call to completion from the synchronous `main` before the event
loop starts. Chapters 18 and 20 build this out with the ORM and the concrete
drivers; the [`run-live.sh`](examples/run-live.sh) script runs the whole thing
against a real NovaDB and then behind the orchestrator.

## What else the app gives you

The framework in `web.*` covers the rest of a real application:

- **Server-sent events** for live updates: `app.sse(path, handler)` and an
  `EventBus` push HTML fragments to connected browsers (see `web.sse`).
- **Sessions and cookies**: `web.session` and `web.cookie` for signed,
  server-side sessions and cookie handling.
- **Middleware**: `app.use(mw)` runs cross-cutting logic (a `RouteMiddleware`)
  around every handler, and the library ships CORS, CSRF, rate limiting, a
  request-id tagger, secure headers, and a body-size limit.
- **Static files**: `app.useStatic(prefix, dir)`, as above.
- **The client side**: `web.client` is an HTTP client for calling other
  services, and TLS is built in (chapter 15 and the runtime crypto are pure
  Nova, no OpenSSL).

## Where to go next

- **Chapter 18, Data access and the ORM**, takes the `Connection` seam further:
  `DbValue`, the micro-ORM, the generic `Repository<T>`, connection strings, and
  backing this app with NovaDB.
- **Chapter 19, Package management**, explains `project.json` and how the
  compiler resolves a driver dependency.
- **Chapter 20, Database drivers**, introduces each driver (NovaDB, PostgreSQL,
  MySQL, SQL Server, MongoDB) and how to add it to a project.
- **Chapter 23, Deploying with the orchestrator**, runs replicas of this app
  behind a load balancer with a NovaDB-backed config store.
