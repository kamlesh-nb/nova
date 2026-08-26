//! Project scaffold file templates for `nova init`.
//!
//! Each `pub const` here is the verbatim text of ONE file that `nova init`
//! writes when creating a new project, stored as a Zig multiline string
//! literal. They are pure data: [`scaffold`] selects the right set for the
//! requested project kind (`console` / `web` / `desktop`) and writes each to
//! disk. The `web_*` set scaffolds a vertical-slice web app (command/query
//! request types, their handlers, a validator, a repository, an `.nsx` view,
//! and the front-end shell). Editing a template here changes what a freshly
//! initialised project looks like; it does not affect already-created apps.

/// The `main.nova` written by `nova init console`: a hello-world entry point.
pub const console_main_sample =
    \\import string;
    \\
    \\fn main(): void {
    \\    console.log("Hello, World from Nova console application!");
    \\}
;

/// `.vscode/launch.json`: the lldb-dap debug configuration, which imports the Nova value formatters so `List`/`Map`/`struct`/`str.Str` display cleanly.
pub const vscode_launch_json =
    \\{
    \\  "version": "0.2.0",
    \\  "configurations": [
    \\    {
    \\      "type": "lldb-dap",
    \\      "request": "launch",
    \\      "name": "Debug Nova (debug build)",
    \\      "program": "${workspaceFolder}/build/debug/bin/${workspaceFolderBasename}",
    \\      "cwd": "${workspaceFolder}",
    \\      "preLaunchTask": "nova: build (debug)",
    \\      "initCommands": [
    \\        "command script import ~/.nova/std/debug/nova_formatters.py"
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

/// `.vscode/tasks.json`: wires `nova build` (debug) as the editor's default build task, used by the launch config's preLaunchTask.
pub const vscode_tasks_json =
    \\{
    \\  "version": "2.0.0",
    \\  "tasks": [
    \\    {
    \\      "label": "nova: build (debug)",
    \\      "type": "shell",
    \\      "command": "nova build",
    \\      "problemMatcher": [],
    \\      "group": { "kind": "build", "isDefault": true }
    \\    }
    \\  ]
    \\}
    \\
;

/// A starter `@test` for a console project, asserting through the `assert` module (so `nova test` has something to run).
pub const console_test_sample =
    \\import assert;
    \\
    \\@test
    \\fn test_sample(): void {
    \\    assert.equalInt(1, 1);
    \\}
;


/// The web app composition root (`main.nova`, the Go "server struct" / Program.cs analogue): constructs
/// the shared dependencies once, lets each feature register its own routes, wires static files, runs.
pub const web_main_sample =
    \\// main.nova, the composition root. It constructs the app-wide dependencies ONCE (here just a
    \\// repository), then hands them to each feature's `register(...)` so the feature can wire its own
    \\// routes. A route maps a path to a handler INSTANCE that implements `RouteHandler` (one uniform
    \\// `async serve(ctx): Response` method) and holds its dependencies as fields. There is no mediator
    \\// and no DI container in the default setup: dependencies are plain constructor arguments, resolved
    \\// right here where you can see them. Vertical slices live under Features/.
    \\import web.app;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.routes;
    \\
    \\fn buildApp(): App {
    \\    let app = App();
    \\
    \\    // Build the shared dependencies once, then let each feature register its routes against them.
    \\    // As the app grows, add a feature module with its own `register(app, deps...)` and call it here.
    \\    let repo = ProductRepository();
    \\    registerProducts(app, repo);
    \\
    \\    // Serve static assets (wwwroot/) for any unmatched GET.
    \\    app.useStatic("/", "./wwwroot");
    \\    return app;
    \\}
    \\
    \\fn main(): void {
    \\    let app = buildApp();
    \\    console.log("Listening on http://127.0.0.1:8080");
    \\    app.run(8080);
    \\}
;

/// The Products feature's route table: maps each path to a handler instance, injecting the repository.
pub const web_routes_sample =
    \\// A feature's route table. Each `app.<verb>(path, Handler(deps))` binds a path to a handler
    \\// instance and injects that handler's dependencies (here the shared ProductRepository) as plain
    \\// constructor arguments. Keeping routes in one small file per feature is what keeps the composition
    \\// root (main.nova) tidy as the app grows: main builds the shared deps and calls one `register` per
    \\// feature. `{id:int}` is a typed path parameter, bound to the handler's request struct by name.
    \\import web.app;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.handler;
    \\
    \\pub fn registerProducts(app: App, repo: ProductRepository): void {
    \\    app.post("/api/products", CreateProductHandler(repo));
    \\    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
    \\}
;

/// Sample WRITE-side request type (a `create` command) for a vertical feature slice.
pub const web_create_command_sample =
    \\// The command: what the client sends to create a product. `@serializable` is what lets
    \\// `ctx.bind<CreateProduct>()` in the handler populate this struct from the request (the form or
    \\// JSON body for a POST, merged with any path/query params), so the handler works with typed fields
    \\// instead of reading the body by hand.
    \\@serializable pub struct CreateProduct {
    \\    pub name: string,
    \\    pub price: int,
    \\
    \\    init() {
    \\        self.name = "";
    \\        self.price = 0;
    \\    }
    \\}
;

/// The response type returned by the create handler.
pub const web_create_response_sample =
    \\// Create response DTO (Domain/Dtos). DTOs are the request/response shapes the
    \\// feature slices bind and return; entities (Domain/Entities) model the rows.
    \\@serializable pub struct CreateProductDto {
    \\    pub id: int,
    \\    pub name: string,
    \\}
;

/// A validator for the create command, run before the handler.
pub const web_create_validator_sample =
    \\import Features.Products.CreateProduct.command;
    \\
    \\// Validate a command before the handler runs. Returns "" when valid, else the error.
    \\pub fn validateCreateProduct(cmd: CreateProduct): string {
    \\    if (cmd.name.length == 0) { return "name is required"; }
    \\    if (cmd.price < 0) { return "price must be >= 0"; }
    \\    return "";
    \\}
;

/// The `RouteHandler` that implements the create command (the write handler).
pub const web_create_handler_sample =
    \\import web.routing;
    \\import web.response;
    \\import web.status;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.validator;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.views.product_card;
    \\
    \\// Handles POST /api/products. A `RouteHandler` is a plain struct that holds its dependencies as
    \\// fields (here the ProductRepository, injected in routes.nova) and exposes ONE uniform method,
    \\// `serve(ctx)`. It reads its typed input with `ctx.bind<CreateProduct>()`, does its work, and
    \\// returns a `Response`. This is a hypermedia app, so the response body is an HTML fragment (the new
    \\// product's card) that the browser swaps into the page; return JSON instead if you are building an API.
    \\pub struct CreateProductHandler impl RouteHandler {
    \\    repo: ProductRepository,
    \\    init(repo: ProductRepository) { self.repo = repo; }
    \\
    \\    async fn serve(self: CreateProductHandler, ctx: Context): Response {
    \\        let cmd = ctx.bind<CreateProduct>();
    \\        let err = validateCreateProduct(cmd);
    \\        if (err.length != 0) {
    \\            return response.Response(Status.BadRequest, err);
    \\        }
    \\        let id = self.repo.create(cmd.name);
    \\        let html = productCard(cmd.name, cmd.price);
    \\        return response.Response(Status.Created, html)
    \\            .setHeader("Content-Type", "text/html; charset=utf-8");
    \\    }
    \\}
;

/// A data repository for the feature over the `db` seam (the ORM bind + query surface).
pub const web_repository_sample =
    \\import Domain.Dtos.ProductDto;
    \\
    \\// A repository. Handlers receive it as a constructor argument (wired in Features/Products/routes.nova),
    \\// so it is a plain struct: no DI container, no marker trait to implement. This starter returns stub
    \\// data so the app runs with no database.
    \\//
    \\// For a real database, hold a connection (or a pool) and use the generic repository from the stdlib:
    \\//
    \\//     import data.db;
    \\//     import data.repository;
    \\//     let repo = Repository<ProductDto>(conn, "products");
    \\//     let rows = await repo.query("SELECT id, name, price FROM products WHERE id = $1", params);  // Rows<ProductDto>
    \\//     let _r  = await repo.add(entity);   // INSERT from a Domain.Entities.Product
    \\//
    \\// Repository<T> binds T from the ORM seam and keeps the connection, so slices stay free of bind code.
    \\// Connect ONCE at sync top level in main.nova (an async connect driven inside a request would abort),
    \\// then pass the connection down to the repositories here.
    \\pub struct ProductRepository {
    \\    init() {}
    \\
    \\    pub fn findById(self: ProductRepository, id: int): ProductDto {
    \\        return ProductDto{ id: id, name: "Sample Product", price: 999 };
    \\    }
    \\
    \\    pub fn create(self: ProductRepository, name: string): int {
    \\        return 1;
    \\    }
    \\}
;

/// Sample READ-side request type (a `get` query) for the feature slice.
pub const web_get_query_sample =
    \\// The query: fetch a product by id. `ctx.bind<GetProductById>()` populates `id` from the route
    \\// parameter `{id:int}` (path/query/body are merged into one source before binding), so the handler
    \\// reads a typed field rather than parsing the URL itself.
    \\@serializable pub struct GetProductById {
    \\    pub id: int,
    \\
    \\    init() {
    \\        self.id = 0;
    \\    }
    \\}
;

/// The response type returned by the get query handler.
pub const web_get_response_sample =
    \\// Read DTO (Domain/Dtos): the shape returned to clients and bound from query rows.
    \\@serializable pub struct ProductDto {
    \\    pub id: int,
    \\    pub name: string,
    \\    pub price: int,
    \\}
;

/// The `RouteHandler` that implements the get query (the read handler).
pub const web_get_handler_sample =
    \\import web.routing;
    \\import web.response;
    \\import web.status;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.views.product_card;
    \\
    \\// Handles GET /api/products/{id:int}. `ctx.bind<GetProductById>()` fills `id` from the route
    \\// parameter, the injected repository loads the product, and the NSX view renders it as an HTML
    \\// fragment. One `serve(ctx): Response` shape covers reads and writes alike.
    \\pub struct GetProductByIdHandler impl RouteHandler {
    \\    repo: ProductRepository,
    \\    init(repo: ProductRepository) { self.repo = repo; }
    \\
    \\    async fn serve(self: GetProductByIdHandler, ctx: Context): Response {
    \\        let q = ctx.bind<GetProductById>();
    \\        let product = self.repo.findById(q.id);
    \\        let html = productCard(product.name, product.price);
    \\        return response.Response(Status.Ok, html)
    \\            .setHeader("Content-Type", "text/html; charset=utf-8");
    \\    }
    \\}
;

/// The `.nsx` hypermedia view template that renders the feature's response as markup.
pub const web_view_sample =
    \\// A per-feature NSX view. View code lives in `.nsx` files (same language as `.nova`, just filed apart
    \\// so markup stays separate from logic) and returns an HTML string the handler or a page route renders.
    \\// An NSX element is a `string`, so expressions embed inline with `{...}` and views compose directly.
    \\//
    \\// A `{expr}` interpolation is HTML-ESCAPED automatically, so user text like a product name is safe by
    \\// default: you never call an escaper here. To insert an ALREADY-rendered HTML fragment unescaped (one
    \\// view composing another), wrap it in `response.raw(fragment)` from `web.response`.
    \\pub fn productCard(name: string, price: int): string {
    \\    return <div class="rounded-lg border border-slate-200 p-4 shadow-sm">
    \\        <h3 class="font-semibold text-slate-800">{name}</h3>
    \\        <p class="mt-1 text-sm text-slate-500">{price}</p>
    \\    </div>;
    \\}
;

/// The domain entity/model type the feature's repository maps to and from.
pub const web_domain_entity_sample =
    \\// Domain entity, the core business object (persistence-agnostic).
    \\pub struct Product {
    \\    pub id: int,
    \\    pub name: string,
    \\    pub price: int,
    \\
    \\    init(id: int, name: string, price: int) {
    \\        self.id = id;
    \\        self.name = name;
    \\        self.price = price;
    \\    }
    \\}
;

/// The root `index.html` shell the web app is served under.
pub const web_index_html_sample =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>Nova Web App</title>
    \\  <!-- Styles are built by Tailwind CLI from styles/app.css into wwwroot/app.css.
    \\       Run `npm install` once, then `npm run css:watch` while developing. -->
    \\  <link rel="stylesheet" href="/app.css">
    \\</head>
    \\<body class="mx-auto max-w-2xl p-10 font-sans text-slate-800">
    \\  <h1 class="text-2xl font-bold tracking-tight">Nova Web App</h1>
    \\  <p class="mt-2 text-slate-600">Vertical-slice API. Try <code class="rounded bg-slate-100 px-1.5 py-0.5">GET /api/products/1</code>.</p>
    \\</body>
    \\</html>
;

/// The `package.json` for the app's front-end tooling (Tailwind build, etc.).
pub const web_package_json_sample =
    \\{
    \\  "name": "nova-web-app",
    \\  "private": true,
    \\  "scripts": {
    \\    "css": "tailwindcss -i ./styles/app.css -o ./wwwroot/app.css --minify",
    \\    "css:watch": "tailwindcss -i ./styles/app.css -o ./wwwroot/app.css --watch"
    \\  },
    \\  "devDependencies": {
    \\    "@tailwindcss/cli": "^4.1.0",
    \\    "tailwindcss": "^4.1.0"
    \\  }
    \\}
;

/// The Tailwind entry stylesheet imported by the app shell.
pub const web_tailwind_css_sample =
    \\@import "tailwindcss";
    \\
    \\/* The content globs (which files Tailwind scans for class names, including the `.nsx` views) live in
    \\   tailwind.config.js at the project root, loaded here. */
    \\@config "../tailwind.config.js";
;

/// The Tailwind configuration (content globs + theme).
pub const web_tailwind_config_sample =
    \\/** @type {import('tailwindcss').Config} */
    \\module.exports = {
    \\  content: [
    \\    "./src/**/*.{nsx,nova}",
    \\    "./wwwroot/*.html",
    \\  ],
    \\};
;

/// The `.gitignore` written into a scaffolded project (ignores build output and local artefacts).
pub const web_gitignore_sample =
    \\node_modules/
    \\wwwroot/app.css
;

/// A starter `@test` for a web feature slice.
pub const web_test_sample =
    \\import assert;
    \\import string;
    \\import web.app;
    \\import web.request;
    \\import web.response;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.handler;
    \\import Features.Products.views.product_card;
    \\
    \\// Build the app exactly as the composition root does: construct the repository, register handler
    \\// instances on the routes. `app.dispatch(req)` runs one request through the router and handler
    \\// without opening a socket, so these tests are fully offline.
    \\fn testApp(): App {
    \\    let repo = ProductRepository();
    \\    let app = App();
    \\    app.post("/api/products", CreateProductHandler(repo));
    \\    app.get("/api/products/{id:int}", GetProductByIdHandler(repo));
    \\    return app;
    \\}
    \\
    \\@test
    \\fn test_get_product(): void {
    \\    let app = testApp();
    \\    let req = Request.fromString("GET /api/products/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    \\    let res = app.dispatch(req);
    \\    assert.equalInt(res.status.toCode(), 200);
    \\    // The handler renders the product card fragment (stub repo returns "Sample Product").
    \\    assert.isTrue(string.indexOf(res.body, "Sample Product") != -1);
    \\}
    \\
    \\@test
    \\fn test_create_product(): void {
    \\    let app = testApp();
    \\    // Hypermedia forms POST url-encoded, which `ctx.bind<CreateProduct>()` reads directly.
    \\    let req = Request.fromString("POST /api/products HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nname=Widget&price=9");
    \\    let res = app.dispatch(req);
    \\    assert.equalInt(res.status.toCode(), 201);
    \\    assert.isTrue(string.indexOf(res.body, "Widget") != -1);
    \\}
    \\
    \\@test
    \\fn test_product_card_view(): void {
    \\    // The `.nsx` view renders, and untrusted text is HTML-escaped via response.escapeHtml.
    \\    let html = productCard("<b>Gadget</b>", 42);
    \\    assert.isTrue(string.indexOf(html, "&lt;b&gt;Gadget") != -1);
    \\    assert.isTrue(string.indexOf(html, "42") != -1);
    \\}
;

/// The `main.nova` written by `nova init desktop`.
pub const desktop_main_sample =
    \\// main.nova, a native desktop app: a webview window rendering NSX, with a Nova
    \\// handler bound to a JS call. Build native and run to open the window.
    \\import webview;
    \\
    \\// JS -> Nova: window.greet(name) calls this; `req` is a JSON array of the JS args.
    \\fn greet(req: string): string {
    \\    return "\"Hello from Nova! args=" + req + "\"";
    \\}
    \\
    \\fn main(): void {
    \\    let w = webview.Webview(true);
    \\    w.setTitle("Nova Desktop");
    \\    w.setSize(900, 640, webview.HINT_NONE);
    \\
    \\    let page = <html>
    \\        <body style="font-family:system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0f172a;color:#e2e8f0">
    \\            <div style="text-align:center">
    \\                <h1>Nova Desktop</h1>
    \\                <button onclick="window.greet('world').then(r => document.querySelector('#out').textContent = r)">Call Nova</button>
    \\                <p id="out"></p>
    \\            </div>
    \\        </body>
    \\    </html>;
    \\
    \\    w.bind("greet", greet);
    \\    w.setHtml(page);
    \\    w.run();
    \\    w.delete();
    \\}
;
