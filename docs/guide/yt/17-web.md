# Video 17: Building a web application

- Chapter: [17-web.md](../17-web.md)
- Estimated length: ~16 minutes
- You will need: Nova installed, a terminal, and the guide's `examples/webapp` project handy. Watching Video 16 on serialization first will help, because request binding uses the same `@serializable`.

## Hook (0:00)

**Say:** In this video we build a real web application in Nova, and we do it the way the standard library actually works: no mediator, no dependency-injection container, no annotation magic. A URL maps to a handler object, the handler reads its typed input and returns a response, and you wire it all up in a plain composition root you can read top to bottom. It is a hypermedia app, so handlers return HTML fragments and the browser swaps them in, and you write almost no client-side JavaScript. Let us scaffold it and walk one feature end to end.

## What we will cover (0:30)

**On screen:**
```
- nova init web: vertical slices, not layers
- The RouteHandler trait: one serve(ctx) method
- ctx.bind<T>(): typed input from query, path, and form
- NSX views: auto-escaped {expr}, response.raw for fragments
- Wiring: routes.nova per feature + a plain composition root
- The Connection seam: in-memory now, real PostgreSQL by changing one file
- Testing offline with app.dispatch
```

## Segment: Scaffold and the shape of a project (1:00)

**Say:** One command scaffolds the project.

**On screen:**
```bash
nova init web --name shop
cd shop
nova build
./build/debug/bin/shop      # http://127.0.0.1:8080
```

**Say:** The project is organised by feature, not by layer. Everything one use case needs lives in one folder under `Features/`. To change "create a product" you open one folder, not three parallel controllers, models, and views trees. This is vertical slice architecture.

**On screen:**
```
Features/Products/
  routes.nova                 this feature's routes
  CreateProduct/command.nova  write input   (a @serializable struct)
  CreateProduct/handler.nova  the RouteHandler
  CreateProduct/validator.nova
  GetProductById/query.nova   read input
  GetProductById/handler.nova
  Shared/repository.nova       data access
  views/product_card.nsx       an NSX view
```

**Say:** One note on the two manifest files. `project.json` is the Nova manifest, the one the build reads. `package.json` is only for the Tailwind CSS tool; the Nova build ignores it.

## Segment: A read slice and the handler (3:00)

**Say:** A slice starts with its input type. For a read, that is a query: a plain serializable struct the framework fills from the request.

**On screen:**
```nova
@serializable pub struct GetProductById {
    pub id: int,
    init() { self.id = 0; }
}
```

**Say:** The handler implements the `RouteHandler` trait. It is a plain struct that holds its dependencies as fields and has exactly one method, `serve(ctx)`. It reads its typed input with `ctx.bind`, does its work, and returns a Response.

**On screen:**
```nova
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
        return response.Response(Status.Ok, productCard(product.name, product.price))
            .setHeader("Content-Type", "text/html; charset=utf-8");
    }
}
```

**Say:** A missing product is just a 404. There is no exception to throw and nothing to catch, because the repository returns an optional.

## Segment: ctx.bind, where the fields come from (5:30)

**Say:** `ctx.bind` deserialises your struct from one merged view of the request, so you never parse a URL or a body by hand. It pulls from cookies, the query string, path parameters, and for POST, PUT, and PATCH the request body, whether that is a form or JSON, chosen by the content type. Later sources win, so a path parameter beats a query parameter of the same name.

**On screen:**
```
cookies  <  query string  <  path params  <  request body (form / json)

ctx.query("q")   one query value
ctx.param("id")  one path parameter
```

**Say:** And because a hypermedia form posts url-encoded, the very same `ctx.bind` reads a submitted form with no extra work.

## Segment: NSX views (7:00)

**Say:** Views live in dot-nsx files. NSX is the same language as Nova, just filed apart. An element is a string, so views compose, and expressions embed with curly braces.

**On screen:**
```nova
pub fn productCard(name: string, price: int): Html {
    return <div class="rounded-lg border p-4 shadow-sm">
        <h3 class="font-semibold">{name}</h3>
        <p class="text-sm text-slate-500">{price}</p>
    </div>;
}
```

**Say:** This is important: a curly-brace interpolation is HTML-escaped automatically. User text like a product name is safe by default, and you never call an escaper. When you deliberately want to insert an already-rendered fragment unescaped, one view inside another, you wrap it in `response.raw`. Escaped by default, explicit raw when you mean it. That single rule is what keeps the views free of cross-site-scripting holes.

## Segment: The write slice (8:30)

**Say:** The write input is a command. Command means write intent, query means read intent; same kind of object, named for what it expresses. Validation is a plain function that returns empty when the input is good. No validator trait, no registration.

**On screen:**
```nova
pub fn validateCreateProduct(cmd: CreateProduct): string {
    if (cmd.name.length == 0) { return "name is required"; }
    if (cmd.price < 0) { return "price must be >= 0"; }
    return "";
}
```

**On screen:**
```nova
async fn serve(self: CreateProductHandler, ctx: Context): Response {
    let cmd = ctx.bind<CreateProduct>();
    let err = validateCreateProduct(cmd);
    if (err.length != 0) { return response.Response(Status.BadRequest, err); }
    let _ = await self.repo.create(cmd.name, cmd.price);
    return response.Response(Status.Created, productCard(cmd.name, cmd.price))
        .setHeader("Content-Type", "text/html; charset=utf-8");
}
```

**Say:** The 201 body is the HTML fragment the browser swaps in. For a JSON API you would stringify a DTO instead; nothing else changes.

## Segment: Wiring it together (10:30)

**Say:** Each feature owns a small routes file that binds paths to handler instances, passing dependencies as plain constructor arguments.

**On screen:**
```nova
pub fn registerProducts(app: App, repo: ProductRepository): void {
    app.post("/api/products", CreateProductHandler(repo));
    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
}
```

**Say:** Curly-brace-id-colon-int is a typed path parameter; a non-numeric id is a 400 at the router and never reaches the handler. And main.nova is the composition root: it builds the shared dependencies once and calls each feature's register. No container resolving things behind your back; you see every dependency constructed.

**On screen:**
```nova
fn buildApp(): App {
    let app = App();
    let conn = InMemoryConnection();
    let repo = ProductRepository(conn);
    registerProducts(app, repo);
    app.useStatic("/", "./wwwroot");
    return app;
}
```

## Segment: The data seam and testing (12:30)

**Say:** The repository holds a `Connection`, which is a trait, not a concrete database. The starter ships a tiny in-memory connection so the app runs and its tests pass with no server. Because the field is the trait, the exact same repository runs over a real database later.

**On screen:**
```nova
pub struct ProductRepository {
    conn: Connection,
    pub async fn findById(self, id: int): ProductDto | undefined {
        let params = List<DbValue>(); params.push(db.dbInt(id));
        let rs = await self.conn.query("SELECT id, name, price FROM products WHERE id = $1", params);
        return orm.bindOne<ProductDto>(rs);
    }
}
```

**Say:** Handlers are objects, so tests build the app just like the composition root and drive a request with `app.dispatch`, no socket. Fast and hermetic.

**On screen:**
```nova
let req = Request.fromString("GET /api/products/999 HTTP/1.1\r\nHost: x\r\n\r\n");
let res = app.dispatch(req);
assert.equalInt(res.status.toCode(), 404);
```

## Segment: The same app, real database (14:00)

**Say:** The project also has main_postgres.nova at its root: the same app over a real PostgreSQL. Put it next to src/main.nova and only the composition root differs. Every slice, the repository, the handlers, the views are identical, because they depend on the Connection trait, never on a driver.

**On screen:**
```nova
let conn = PooledConnection(dsn, poolSize);   // built now; connects lazily, per request
let repo = ProductRepository(conn);
registerProducts(app, repo);
```

**Say:** The pooled connection is built synchronously and opens PostgreSQL connections lazily, inside requests. That matters: opening a connection is asynchronous, and you cannot drive an asynchronous call from the synchronous main before the event loop starts. We take this apart properly in the next video.

## Recap and outro (15:30)

**Say:** That is a Nova web application. Vertical slices, one RouteHandler per feature, typed input from ctx.bind, auto-escaped NSX views, a plain composition root, and a Connection seam that lets you go from in-memory to a real database by changing one file. There is more in the box: server-sent events for live updates, sessions and cookies, and middleware for CORS, CSRF, and rate limiting. In the next video we wire this app to a live PostgreSQL, meet the micro-ORM and the drivers, and see the whole data-access story.

**On screen:**
```
Next: Video 18, Data access and PostgreSQL
```
