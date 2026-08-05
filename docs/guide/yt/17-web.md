# Video 17: Building a web service

- Chapter: [17-web.md](../17-web.md)
- Estimated length: ~15 minutes
- You will need: Nova installed, a terminal, and the guide's `examples/webapp/` project handy. Watching Video 16 on serialization and Video 11 on error handling first will help.

## Hook (0:00)

**Say:** This is the capstone. Nova ships an ASP.NET style web framework, and `nova init web` scaffolds a whole vertical-slice project around it. In this video you will see how a Nova web service is built: a typed request, a typed handler that receives the request already deserialised, and automatic wiring that finds the handler for you. You will see how a handler reports success and failure as ordinary typed values, and how to test the whole thing offline without a socket. By the end you will understand every core piece of a Nova web app.

## What we will cover (0:30)

- The three ideas: a typed request, a typed handler, and automatic wiring
- Scaffolding a project with `nova init web`
- A read handler that returns a DTO
- A write handler that returns `TResp | HttpError`
- How route and body binding fill the request
- Testing without a socket

## Segment: The three ideas (1:00)

**Say:** Before any code, here is the shape of the whole thing. The design has three ideas working together.

**On screen:**
```
1. A request type per operation.   A small @serializable struct, e.g. GetProductById { id: int },
                                   with another @serializable struct for its response.
2. A typed handler per request.    A struct implementing RequestHandler<TRequest, TResponse>. Its
                                   handle receives the request already deserialised, returns the DTO.
3. Routes + a runtime mediator.   app.get<TReq>(path) maps a route to a request type; the framework
                                   binds it and mediator.send picks the handler by type (MediatR-style).
```

**Say:** So each thing a client can ask for is its own small request struct, with a response struct beside it. Each request type has one handler, and the handler receives the request already deserialised: no ValueSource, no reading fields by hand. And you never register the handler separately. You map a route to a request type, and the compiler discovers the handler by its `RequestHandler` impl. Every operation lives in its own small slice, easy to read, test, and grow.

## Segment: Scaffolding the project (2:15)

**Say:** Let us not hand-write the layout. The framework scaffolds it.

**Run it:** `nova init web --name webapp`

**On screen:**
```
webapp/
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
  tests/features/products_test.nova
  wwwroot/index.html
```

**Say:** This is the vertical-slice layout. Each feature is a folder, and inside it the request, the response, the handler, and any validation sit together. You build it with `nova build` and run the tests with `nova test`. Let us look at the two slices it gives us.

## Segment: A read handler that returns a DTO (3:45)

**Say:** Start with the read slice, GetProductById. It is a request struct, a response DTO, and a handler.

**On screen:**
```nova
// src/Features/Products/GetProductById/query.nova
import web.mediator;

// The query: fetch a product by id. Bound from the route param `{id:int}`. `impl Message` opts it into the mediator.
@serializable pub struct GetProductById impl Message {
    pub id: int,
}
```

**On screen:**
```nova
// src/Features/Products/GetProductById/response.nova
@serializable pub struct ProductDto {
    pub id: int,
    pub name: string,
}
```

**Say:** Both are `@serializable`. That is what lets the framework bind the request from the route and the body, and serialise the response DTO to JSON. Now the handler.

**On screen:**
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

**Say:** Look how clean this is. The handler implements `RequestHandler<GetProductById, ProductDto>`. Its `handle` takes a fully formed `GetProductById`, with the id already parsed out of the path, and returns a `ProductDto`. That is it. No ValueSource, no `src.getInt`, no manual JSON. A handler that cannot fail just returns its DTO and the framework serialises it as a 200.

## Segment: A write handler that can fail (6:00)

**Say:** Now the write slice, CreateProduct. A write often needs to reject bad input, and this is where Nova's error handling from Video 11 pays off. A handler that can fail returns `TResp | HttpError`.

**On screen:**
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

**Say:** The return type is `CreateProductResponse | HttpError`, an error union, exactly like the ones from the error-handling video. On the happy path we return the DTO and the framework replies 200. If validation fails we return `HttpError(400, err)`, and the framework replies with that status code and the message as the body. Success and failure are both just typed return values. There is no ValueSource, no reading fields, and no juggling status codes by hand.

## Segment: Wiring the routes (8:15)

**Say:** Now the composition root, main.nova, ties the routes to the request types.

**On screen:**
```nova
// src/main.nova
fn buildApp(): App {
    let app = App();

    // Products feature, one route per slice. The handlers are found by their impls.
    app.post<CreateProduct>("/api/products");
    app.get<GetProductById>("/api/products/{id:int}");

    // Serve static assets (wwwroot/) for any unmatched GET.
    app.useStatic("/", "./wwwroot");
    return app;
}
```

**Say:** Two routes, one per slice. `app.post<CreateProduct>` and `app.get<GetProductById>` map a path to a request type, and that is all: the handlers are discovered by their impls, so there is nothing else to register. Notice the GET path, `"/api/products/{id:int}"`. That `{id:int}` is a typed path parameter. The framework parses it as an int, and a non-integer where an int is expected becomes a 400 before your handler runs.

## Segment: How binding fills the request (9:45)

**Say:** So where do the request fields come from? Two sources fill the same struct.

**On screen:**
```
Route parameters win first  (@fromRoute):  {id:int} in the path fills GetProductById.id
The request body fills the rest (@fromBody): the JSON body fills CreateProduct.name / .price
```

**Say:** A `GET /api/products/7` binds `GetProductById { id: 7 }` from the path. A `POST /api/products` with a JSON body of name and price binds `CreateProduct` from that body. Route parameters take priority, then the body fills the rest. You never read a field by hand: the handler always gets a complete, typed request.

## Segment: Testing without a socket (10:45)

**Say:** A live server calls `app.run(8080)`, which listens and blocks. For tests, `app.dispatch` runs the exact same routing, binding, and handler path, just without a socket.

**On screen:**
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

**Run it:** `nova test tests/features/products_test.nova`

```
PASS  test_get_product
PASS  test_create_product
```

**Say:** The first test dispatches a GET, the id is bound from the path, and the DTO comes back as JSON. The second dispatches a POST, the body binds into CreateProduct, and the response carries the name back. Because `app.dispatch` runs the real router and the real binding, these tests exercise the same code path as production, without a network. Fast and honest.

## Segment: A database-backed slice (12:00)

**Say:** The two slices so far stub out storage and validate inline. A real feature reads and writes through a repository, validates with a dedicated validator, and wraps the handler in cross-cutting behaviours. The guide ships a complete, runnable version of this under `examples/webapp/`. Let me show the three pieces that make it real.

**Say:** First, the repository. It is written against the `Connection` trait and the micro-ORM, never against a concrete driver.

**On screen:**
```nova
// src/Features/Products/Shared/repository.nova
pub async fn findById(self: ProductRepository, id: int): ProductDto | undefined {
    let params = List<DbValue>();
    params.push(db.dbInt(id));
    let rs = await self.conn.query("SELECT id, name, price FROM products WHERE id = $1", params);
    return orm.bindOne<ProductDto>(rs);   // I/O awaited, then the sync ORM binder maps columns to the DTO
}
```

**Say:** Two things matter here. The method is `async` and awaits the connection, because on the request path everything runs inside the event loop. And the I/O and the binding are kept apart: `conn.query` returns a result set, and `orm.bindOne` of `ProductDto` maps its columns to the DTO by name. The repository is injected into the handler through its constructor, so the handler just calls `await self.repo.findById` and returns a 404 when it is undefined.

**Say:** Second, validation lives in its own type, one per request.

**On screen:**
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

**Say:** The compiler generates the erased adapter and the app auto-registers it, so one generic `ValidationBehavior` runs the right validator before the handler and short-circuits with a 400. The handler never checks input again.

**Say:** Third, cross-cutting behaviours. Each implements `PipelineBehavior` and wraps every handler. The example ships a logging behaviour and a transaction behaviour, which opens a transaction on the request's scoped connection, the same instance the repository uses, and commits or rolls back by the outcome.

**On screen:**
```nova
// src/main.nova
services.addSingleton("InMemoryConnection", (sp) => { return InMemoryConnection(); });
services.addScoped("ProductRepository", (sp) => { return ProductRepository(sp.require("InMemoryConnection") as InMemoryConnection); });

app.useBehavior(LoggingBehavior{});       // outermost first
app.useBehavior(ValidationBehavior{});
app.useBehavior(TransactionBehavior{});
```

**Say:** This is why `send` opens one dependency-injection scope per request: the transaction behaviour and the handler's repository resolve the same scoped connection, so the transaction wraps the very writes the handler makes. Register a real driver instead of the in-memory connection and nothing else changes.

## Segment: What else the app gives you (14:00)

**Say:** The framework has more once you need it.

**On screen:**
```
More verbs             app.put<TReq>, app.delete<TReq>, app.patch<TReq>, alongside get and post.
Static files           app.useStatic("/", "./wwwroot") serves assets for unmatched GET requests.
Validators             one Validator<TReq> per request; the generic ValidationBehavior runs it.
Behaviours             app.useBehavior(b) wraps every handler with logging, transactions, auth.
TLS                    app.useTls(certPath, keyPath) for HTTPS.
```

**Say:** So you get the other HTTP verbs, static file serving for unmatched GETs, per-type validators run by the validation behaviour, your own pipeline behaviours for cross-cutting concerns, and TLS for HTTPS.

## Recap (14:45)

**Say:** Let us recap the capstone.

- A Nova web app is typed slices: a request struct, a response DTO, and a handler implementing `RequestHandler<TRequest, TResponse>`.
- The handler receives the request already deserialised and returns the response value. No ValueSource, no manual field reads.
- A handler that can fail returns `TResp | HttpError`; the framework replies 200 with the DTO or the error's status with its message.
- You map routes with `app.get<TReq>` and `app.post<TReq>`; the handler is discovered by its impl.
- `app.dispatch` runs the real path offline, so tests hit the same code as production.

## Outro (15:00)

**Say:** You have now built a working web service, the capstone of the core language. But it keeps its data in memory. In the next video we give it a real database: Nova's `Connection` seam, the drivers, and how to move this exact app onto a live NovaDB by changing one file. After that, Video 21 deploys it behind a load balancer with the orchestrator. See you in Video 18.
