# 17. Building a web service

This is the capstone. Nova ships an ASP.NET style web framework, and `nova init web` scaffolds a
project around it. The design has three ideas working together:

1. **A request type per operation.** Each thing a client can ask for is a small `@serializable`
   struct, for example `GetProductById { id: int }`. Its response is another `@serializable` struct.
2. **A typed handler per request.** A handler implements `RequestHandler<TRequest, TResponse>`. Its
   `handle` method receives the request already deserialised and returns the response value. There is
   no `ValueSource` and no manual field reading: the framework binds the request for you and
   serialises the response to JSON.
3. **Routes, and a runtime mediator.** You map a route to a request type with `app.get<TReq>(path)` or
   `app.post<TReq>(path)`. On a request the framework binds it and calls the mediator's `send`, which
   picks the handler by request type, opens a per-request dependency-injection scope, runs the
   behaviour pipeline (validation, transactions, logging), and returns the response. The handler is
   discovered by its `RequestHandler<TReq, _>` impl, so the route is the only thing you register. This
   is the .NET MediatR pattern: the mediator lives in the framework, not the compiler.

This keeps each operation in its own small slice, easy to read, test, and grow. A real project puts
each slice under `Features/`, and that is exactly what the scaffold gives you.

## Scaffolding the project

```
nova init web --name webapp
```

This lays out a vertical-slice project:

```
webapp/
  project.json
  src/
    main.nova                         # composition root: routes, static files, run
    Features/Products/
      CreateProduct/
        command.nova                  # the request struct
        response.nova                 # the response DTO
        validator.nova                # a plain validation function
        handler.nova                  # RequestHandler<CreateProduct, ...>
      GetProductById/
        query.nova
        response.nova
        handler.nova
    Domain/entities/product.nova      # the domain object
  tests/features/products_test.nova
  wwwroot/index.html
```

Build it with `nova build` and run the tests with `nova test tests/features/products_test.nova`.

## A request and its typed handler

A read operation is a request struct, a response DTO, and a handler. The `id` is bound from the route
parameter `{id:int}`, so the handler receives a fully formed `GetProductById`.

```nova
// src/Features/Products/GetProductById/query.nova
import web.mediator;

// The query: fetch a product by id. Bound from the route param `{id:int}`. `impl Message` opts the
// request into the mediator: the framework binds it and `send`s it to the handler by request type.
@serializable pub struct GetProductById impl Message {
    pub id: int,
}
```

```nova
// src/Features/Products/GetProductById/response.nova
@serializable pub struct ProductDto {
    pub id: int,
    pub name: string,
}
```

```nova
// src/Features/Products/GetProductById/handler.nova
import web.routing;
import serde.json;
import Features.Products.GetProductById.query;
import Features.Products.GetProductById.response;

// Handles GetProductById. `id` is bound from the route param `{id:int}`. A handler that cannot fail
// simply returns its DTO, which the framework serialises as 200 JSON.
pub struct GetProductByIdHandler impl RequestHandler<GetProductById, ProductDto> {
    async fn handle(self: GetProductByIdHandler, q: GetProductById): ProductDto {
        // (load from a repository; stubbed here)
        return ProductDto{ id: q.id, name: "Sample Product" };
    }
}
```

The handler is pure: a typed request in, a typed response out. The `{id:int}` segment is a typed path
parameter. The framework parses it and binds it into `q.id`; a non integer where `int` is expected
becomes a `400 Bad Request` before your handler ever runs.

## A handler that can fail: `TResp | HttpError`

A write operation often needs to reject bad input. A handler that can fail returns
`TResp | HttpError`. The framework serialises the ok DTO as a 200 JSON response, and an `HttpError` as
its status code with the message as the body. Success and failure are both ordinary typed return
values, so there is no manual status juggling.

```nova
// src/Features/Products/CreateProduct/command.nova
import web.mediator;

// The command: what the client sends to create a product. @serializable lets the framework bind
// this struct from the request body (@fromBody), so the handler receives it already deserialised.
// `impl Message` opts it into the mediator, dispatched to its handler by request type.
@serializable pub struct CreateProduct impl Message {
    pub name: string,
    pub price: int,
}
```

```nova
// src/Features/Products/CreateProduct/response.nova
@serializable pub struct CreateProductResponse {
    pub id: int,
    pub name: string,
}
```

```nova
// src/Features/Products/CreateProduct/validator.nova
import Features.Products.CreateProduct.command;

// Validate a command before the handler runs. Returns "" when valid, else the error.
pub fn validateCreateProduct(cmd: CreateProduct): string {
    if (cmd.name.length == 0) { return "name is required"; }
    if (cmd.price < 0) { return "price must be >= 0"; }
    return "";
}
```

```nova
// src/Features/Products/CreateProduct/handler.nova
import web.response;
import web.routing;
import serde.json;
import Features.Products.CreateProduct.command;
import Features.Products.CreateProduct.response;
import Features.Products.CreateProduct.validator;

// Handles CreateProduct. The request arrives already deserialised (bound from the JSON body). The
// handler returns `CreateProductResponse | HttpError`: the framework serialises the ok DTO as 200
// JSON, and an HttpError as its status code with the message as the body. No ValueSource, no manual
// field reads, no manual status juggling.
pub struct CreateProductHandler impl RequestHandler<CreateProduct, CreateProductResponse | HttpError> {
    async fn handle(self: CreateProductHandler, cmd: CreateProduct): CreateProductResponse | HttpError {
        let err = validateCreateProduct(cmd);
        if (err.length != 0) {
            return HttpError(400, err);
        }
        // (persist here via a Shared/database repository, then return the new id)
        return CreateProductResponse{ id: 1, name: cmd.name };
    }
}
```

`HttpError(status, message)` comes from `web.response`. Because the error side of `TResp | HttpError`
is just a value, you can also build it once in a helper and return it from several branches, exactly
like any other error union from chapter 11.

## Wiring the routes

The composition root maps each route to its request type. Importing a slice's handler is what makes it
discoverable, so there is no separate handler registration.

```nova
// src/main.nova
import web.app;
import web.request;
import web.response;
import web.routing;
import serde.json;
import Features.Products.CreateProduct.command;
import Features.Products.CreateProduct.handler;
import Features.Products.GetProductById.query;
import Features.Products.GetProductById.handler;

fn buildApp(): App {
    let app = App();

    // Products feature, one route per slice. The handlers are found by their impls.
    app.post<CreateProduct>("/api/products");
    app.get<GetProductById>("/api/products/{id:int}");

    // Serve static assets (wwwroot/) for any unmatched GET.
    app.useStatic("/", "./wwwroot");
    return app;
}

fn main(): void {
    let app = buildApp();
    console.log("Listening on http://127.0.0.1:8080");
    app.run(8080);
}
```

## Route binding: `@fromRoute` and `@fromBody`

The request is bound from two sources, and both fill the same struct:

- **Route parameters** win first (think `@fromRoute`): `{id:int}` in the path fills `id`.
- **The request body** fills the rest (think `@fromBody`): for a POST, PUT, or PATCH the JSON body is
  parsed and its fields are bound. Form and multipart bodies are handled the same way.

So a `GET /api/products/7` binds `GetProductById { id: 7 }` from the path, and a
`POST /api/products` with `{"name":"Widget","price":9}` binds `CreateProduct { name: "Widget",
price: 9 }` from the body. You never read fields by hand.

## Testing it offline

A live server calls `app.run(8080)`, which listens and blocks. For tests, `app.dispatch` runs the very
same routing, binding, and handler path without a socket, so your tests exercise production code.

```nova
// tests/features/products_test.nova
@test
fn test_get_product(): void {
    let app = testApp();
    let req = Request.fromString("GET /api/products/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    let res = app.dispatch(req);
    assert.isTrue(string.indexOf(res.body, "\"id\":7") != -1);
}

@test
fn test_create_product(): void {
    let app = testApp();
    let req = Request.fromString("POST /api/products HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"name\":\"Widget\",\"price\":9}");
    let res = app.dispatch(req);
    assert.isTrue(string.indexOf(res.body, "Widget") != -1);
}
```

Run them:

```
nova test tests/features/products_test.nova
```

```
PASS  test_get_product
PASS  test_create_product
```

The GET returns `200` with `{"id":7,"name":"Sample Product"}`, the valid POST returns `200` with the
DTO, and a POST whose `name` is empty returns `400` with `name is required`, straight from the
handler's `HttpError`.

## A database-backed slice: repository, validator, and behaviours

The slices above stub out storage and validate inline. A real feature does neither: it reads and writes
through a repository, validates with a dedicated validator, and wraps the handler in cross-cutting
behaviours. The guide ships a complete, runnable version of exactly this under
[`examples/webapp/`](examples/webapp/). Build and test it the same way:

```
cd docs/guide/examples/webapp
nova build
nova test tests/features/products_test.nova
```

### The repository over the `Connection` seam

Data access goes through a repository written against the `Connection` trait and the micro-ORM, never
against a concrete driver. The example registers an `InMemoryConnection` that implements the same
`Connection` seam the real drivers (`nova-postgres`, `nova-mysql`, `nova-novadb`, and the rest)
implement, so swapping in a live database is a one-line change in `main.nova` and nothing in the
repository or the handlers moves.

```nova
// src/Features/Products/Shared/repository.nova
pub struct ProductRepository impl Service {
    conn: InMemoryConnection,
    init(conn: InMemoryConnection) { self.conn = conn; }

    pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
        let params = List<DbValue>();
        params.push(db.dbInt(id));
        // Await the I/O here (the connection is async), then bind the rows with the sync ORM binder.
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

Two things are worth calling out. First, the repository methods are `async fn` and `await` the
connection, because on the request path everything runs inside the event loop and a sync method that
block-drove an async connection would deadlock. Second, the I/O and the binding are kept apart:
`conn.query` returns a `ResultSet`, and `orm.bindOne<ProductDto>(rs)` maps its columns to the DTO by
name. The binder is generic over the concrete `ProductDto` at the call site, which is what lets the
compiler resolve the column mapping. `orm.bindAll<T>` does the same for a whole list.

### Constructor injection

The handler declares the repository as a constructor parameter, and the framework injects it from the
per-request scope. The handler stays pure business logic.

```nova
// src/Features/Products/GetProductById/handler.nova
pub struct GetProductByIdHandler impl RequestHandler<GetProductById, ProductDto | HttpError> {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn handle(self: GetProductByIdHandler, q: GetProductById): ProductDto | HttpError {
        let found = await self.repo.findById(q.id);
        if (found == undefined) {
            return HttpError(404, "product not found");
        }
        return found ?? ProductDto{ id: 0, name: "" };
    }
}
```

### A typed validator and the validation behaviour

Validation lives in its own type, `Validator<TReq>`, one per request that needs it. The compiler
generates the erased adapter and the app auto-registers it, so the single generic `ValidationBehavior`
runs the right validator before the handler and short-circuits with a `400` on failure. Rules live in
the validator; the handler never checks input again.

```nova
// src/Features/Products/CreateProduct/validator.nova
pub struct CreateProductValidator impl Validator<CreateProduct> {
    fn validate(self: CreateProductValidator, cmd: CreateProduct): List<string> {
        let errs = List<string>();
        if (cmd.name.length == 0) { errs.push("name is required"); }
        if (cmd.price < 0) { errs.push("price must be >= 0"); }
        return errs;
    }
}
```

### Cross-cutting behaviours

A behaviour implements `PipelineBehavior` and wraps every handler. It inspects the request, calls
`await next.proceed(ctx)` to continue, and may short-circuit by returning a `Response` without calling
`next`. The example ships two beyond validation: a logging behaviour that tags the response, and a
transaction behaviour that opens a transaction on the request's scoped connection, the same instance the
repository uses, and commits or rolls back by the outcome.

```nova
// src/Features/Products/Shared/behaviours.nova
pub struct TransactionBehavior impl PipelineBehavior {
    async fn handle(self: TransactionBehavior, ctx: RequestContext, next: Next): Response {
        let conn = ctx.scope.require("InMemoryConnection") as InMemoryConnection;
        let _ = await conn.begin();
        let res = await next.proceed(ctx);
        if (res.status.toCode() < 400) {
            let _ = await conn.commit();
        } else {
            let _ = await conn.rollback();
        }
        return res;
    }
}
```

This is why `send` opens one dependency-injection scope per request: the behaviour and the handler's
repository resolve the *same* scoped connection, so the transaction wraps the very writes the handler
makes.

### Composition root

`main.nova` registers the connection as a singleton and the repository as a scoped service injected with
it, then adds the behaviours outermost-first and maps the routes.

```nova
// src/main.nova
fn configureServices(): ServiceCollection {
    let services = ServiceCollection();
    services.addSingleton("InMemoryConnection", (sp) => { return InMemoryConnection(); });
    services.addScoped("ProductRepository", (sp) => { return ProductRepository(sp.require("InMemoryConnection") as InMemoryConnection); });
    return services;
}

fn buildApp(): App {
    let app = App();
    app.useServices(configureServices());

    // Outermost first: log, then validate (short-circuiting bad input with a 400), then transaction.
    app.useBehavior(LoggingBehavior{});
    app.useBehavior(ValidationBehavior{});
    app.useBehavior(TransactionBehavior{});

    app.post<CreateProduct>("/api/products");
    app.get<GetProductById>("/api/products/{id:int}");
    app.useStatic("/", "./wwwroot");
    return app;
}
```

On a request, `send` picks the handler by request type, opens the scope, runs `LoggingBehavior` then
`ValidationBehavior` then `TransactionBehavior`, and finally the handler, which reads and writes through
its injected repository. A `POST` with an empty name never reaches the handler: the validation behaviour
returns a `400` first. A `GET` for a missing id returns the handler's `404`. Everything else commits and
comes back as `200` JSON.

## What else the app gives you

| Feature | How |
|---------|-----|
| More verbs | `app.put<TReq>`, `app.delete<TReq>`, `app.patch<TReq>`, alongside `get` and `post`. |
| Static files | `app.useStatic("/", "./wwwroot")` serves assets for unmatched GET requests. |
| Dependency injection | Register services in a `ServiceCollection` and give them to the app with `app.useServices(...)`; a handler declares its collaborators (a repository, a database connection) as constructor parameters and the framework injects them, as the scaffold's `ProductRepository` shows. |
| Async handlers | A handler's `handle` is `async`, so it can `await` a database driver or another service. The framework awaits it on the request coroutine. |
| Pipeline behaviours | `app.useBehavior(b)` wraps every handler with cross-cutting logic (logging, validation, auth, timing). A behaviour inspects the request, calls `await next.proceed(src)` to continue, and may short-circuit by returning a `Response` without calling `next`. |
| TLS | `app.useTls(certPath, keyPath)` for HTTPS. |

## Where to go next

You have now seen every core construct in Nova, from primitives to a working web service. This app keeps
its products in memory; the next chapter points it at a real database. Good next steps:

- [Chapter 18, Data access and NovaDB](18-data-access.md): the `db` seam and the drivers, and how to
  move this exact web app onto a live NovaDB by changing one file.
- [Chapter 21, Deploying with the orchestrator](21-deploying-with-the-orchestrator.md): run the app as
  load-balanced replicas behind `proxyd`, supervised by `orchd`.
- The standard library packages. The database drivers (`nova-postgres`, `nova-mysql`, `nova-mssql`,
  `nova-mongodb`, `nova-novadb`) plug into the same app through repositories. See
  [`../packages.md`](../packages.md).
- The [language specification](../language-specification.md) for the precise, citation backed
  contract behind everything in this guide.
- `nova init web --name myapp` to scaffold your own vertical-slice project and start building.
