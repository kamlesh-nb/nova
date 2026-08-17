
pub const console_main_sample =
    \\import string;
    \\
    \\fn main(): void {
    \\    console.log("Hello, World from Nova console application!");
    \\}
;

// VS Code F5 debugging (Gap 4): lldb-dap over the debug build. Requires the "LLDB DAP" VS Code
// extension (ships with LLVM). `nova build` produces the debug binary with DWARF; the debug profile
// keeps the object files that lldb reads. No Python: primitives + strings show natively (strings are
// NUL-terminated). `${workspaceFolderBasename}` is the project (binary) name.
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
    \\      "preLaunchTask": "nova: build (debug)"
    \\    }
    \\  ]
    \\}
    \\
;

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

pub const console_test_sample =
    \\import assert;
    \\
    \\@test
    \\fn test_sample(): void {
    \\    assert.equalInt(1, 1);
    \\}
;


pub const web_main_sample =
    \\// main.nova, app composition root (= Program.cs): register routes, wire static files, run. Each
    \\// `get/post<TReq>` maps a route to a request type; the handler that implements
    \\// `RequestHandler<TReq, TResp>` is discovered by the compiler, so there is nothing else to register.
    \\// Vertical slices live under Features/. Importing a slice's handler is what makes it discoverable.
    \\import web.app;
    \\import web.di;
    \\import web.request;
    \\import web.response;
    \\import web.routing;
    \\import serde.json;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.GetProductById.handler;
    \\
    \\// Register the app's services. Handlers declare their dependencies as constructor parameters, and
    \\// the framework resolves them from here (ASP.NET-style constructor injection).
    \\fn configureServices(): ServiceCollection {
    \\    let services = ServiceCollection();
    \\    services.addSingleton("ProductRepository", (sp) => { return ProductRepository(); });
    \\    return services;
    \\}
    \\
    \\fn buildApp(): App {
    \\    let app = App();
    \\    app.useServices(configureServices());
    \\
    \\    // Products feature, one route per slice. The handlers are found by their impls, and their
    \\    // constructor dependencies are injected from the services above.
    \\    app.post<CreateProduct>("/api/products");
    \\    app.get<GetProductById>("/api/products/{id:int}");
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

pub const web_create_command_sample =
    \\import web.mediator;
    \\
    \\// The command: what the client sends to create a product. @serializable lets the framework bind
    \\// this struct from the request body (@fromBody), so the handler receives it already deserialised.
    \\// `impl Message` opts it into the mediator, dispatched to its handler by request type.
    \\@serializable pub struct CreateProduct impl Message {
    \\    pub name: string,
    \\    pub price: int,
    \\}
;

pub const web_create_response_sample =
    \\// The response DTO returned to the client.
    \\@serializable pub struct CreateProductResponse {
    \\    pub id: int,
    \\    pub name: string,
    \\}
;

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

pub const web_create_handler_sample =
    \\import web.response;
    \\import web.routing;
    \\import serde.json;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.response;
    \\import Features.Products.CreateProduct.validator;
    \\import Features.Products.Shared.repository;
    \\
    \\// Handles CreateProduct. The request arrives already deserialised (bound from the JSON body), and
    \\// the ProductRepository is injected through the constructor. The handler returns
    \\// `CreateProductResponse | HttpError`: the framework serialises the ok DTO as 200 JSON, and an
    \\// HttpError as its status code with the message as the body. No ValueSource, no manual field reads.
    \\pub struct CreateProductHandler impl RequestHandler<CreateProduct, CreateProductResponse | HttpError> {
    \\    repo: ProductRepository,
    \\    init(repo: ProductRepository) { self.repo = repo; }
    \\
    \\    async fn handle(self: CreateProductHandler, cmd: CreateProduct): CreateProductResponse | HttpError {
    \\        let err = validateCreateProduct(cmd);
    \\        if (err.length != 0) {
    \\            return HttpError(400, err);
    \\        }
    \\        let id = self.repo.create(cmd.name);
    \\        return CreateProductResponse{ id: id, name: cmd.name };
    \\    }
    \\}
;

pub const web_repository_sample =
    \\import web.di;
    \\import Features.Products.GetProductById.response;
    \\
    \\// A repository service. Handlers receive it through their constructor, and the DI container
    \\// resolves it (see main.nova, which registers it as a singleton). A real repository would talk to
    \\// a database driver; this one returns stub data. Implementing `Service` is what lets the container
    \\// store and hand it out.
    \\pub struct ProductRepository impl Service {
    \\    init() {}
    \\
    \\    pub fn findById(self: ProductRepository, id: int): ProductDto {
    \\        return ProductDto{ id: id, name: "Sample Product" };
    \\    }
    \\
    \\    pub fn create(self: ProductRepository, name: string): int {
    \\        return 1;
    \\    }
    \\}
;

pub const web_get_query_sample =
    \\import web.mediator;
    \\
    \\// The query: fetch a product by id. Bound from the route param `{id:int}`. `impl Message` opts the
    \\// request into the mediator: the framework binds it and `send`s it to the handler by request type.
    \\@serializable pub struct GetProductById impl Message {
    \\    pub id: int,
    \\}
;

pub const web_get_response_sample =
    \\@serializable pub struct ProductDto {
    \\    pub id: int,
    \\    pub name: string,
    \\}
;

pub const web_get_handler_sample =
    \\import web.routing;
    \\import serde.json;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.GetProductById.response;
    \\import Features.Products.Shared.repository;
    \\
    \\// Handles GetProductById. `id` is bound from the route param `{id:int}`. The `ProductRepository`
    \\// is injected through the constructor, resolved from the DI container. A handler that cannot fail
    \\// simply returns its DTO, which the framework serialises as 200 JSON.
    \\pub struct GetProductByIdHandler impl RequestHandler<GetProductById, ProductDto> {
    \\    repo: ProductRepository,
    \\    init(repo: ProductRepository) { self.repo = repo; }
    \\
    \\    async fn handle(self: GetProductByIdHandler, q: GetProductById): ProductDto {
    \\        return self.repo.findById(q.id);
    \\    }
    \\}
;

pub const web_view_sample =
    \\import web.response;
    \\
    \\// A per-feature NSX view. View code lives in `.nsx` files (same language as `.nova`, just filed apart
    \\// so markup stays separate from logic) and returns an HTML string the handler or a page route renders.
    \\// An NSX element is a `string`, so expressions embed inline with `{...}` and views compose directly.
    \\//
    \\// NSX inserts a `{expr}` string RAW so pre-rendered fragments compose; wrap any untrusted text in
    \\// `response.escapeHtml(...)` (the one canonical escaper in the stdlib) so you never redefine your own.
    \\pub fn productCard(name: string, price: int): string {
    \\    return <div class="rounded-lg border border-slate-200 p-4 shadow-sm">
    \\        <h3 class="font-semibold text-slate-800">{response.escapeHtml(name)}</h3>
    \\        <p class="mt-1 text-sm text-slate-500">{price}</p>
    \\    </div>;
    \\}
;

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

// Tailwind CLI project files. `npm install` pulls tailwindcss + the CLI; `npm run css` builds once and
// `npm run css:watch` rebuilds wwwroot/app.css whenever a class changes in the NSX views or the shell.
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

pub const web_tailwind_css_sample =
    \\@import "tailwindcss";
    \\
    \\/* The content globs (which files Tailwind scans for class names, including the `.nsx` views) live in
    \\   tailwind.config.js at the project root, loaded here. */
    \\@config "../tailwind.config.js";
;

// The content globs Tailwind scans. The `.nsx` glob is essential: views live in `.nsx` files, so without
// it every utility class used only in a view would be dropped from wwwroot/app.css.
pub const web_tailwind_config_sample =
    \\/** @type {import('tailwindcss').Config} */
    \\module.exports = {
    \\  content: [
    \\    "./src/**/*.{nsx,nova}",
    \\    "./wwwroot/*.html",
    \\  ],
    \\};
;

pub const web_gitignore_sample =
    \\node_modules/
    \\wwwroot/app.css
;

pub const web_test_sample =
    \\import assert;
    \\import string;
    \\import web.app;
    \\import web.di;
    \\import web.request;
    \\import web.response;
    \\import Features.Products.Shared.repository;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.GetProductById.handler;
    \\import Features.Products.views.product_card;
    \\
    \\fn testApp(): App {
    \\    let services = ServiceCollection();
    \\    services.addSingleton("ProductRepository", (sp) => { return ProductRepository(); });
    \\    let app = App();
    \\    app.useServices(services);
    \\    app.post<CreateProduct>("/api/products");
    \\    app.get<GetProductById>("/api/products/{id:int}");
    \\    return app;
    \\}
    \\
    \\@test
    \\fn test_get_product(): void {
    \\    let app = testApp();
    \\    let req = Request.fromString("GET /api/products/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    \\    let res = app.dispatch(req);
    \\    assert.isTrue(string.indexOf(res.body, "\"id\":7") != -1);
    \\}
    \\
    \\@test
    \\fn test_create_product(): void {
    \\    let app = testApp();
    \\    let req = Request.fromString("POST /api/products HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"name\":\"Widget\",\"price\":9}");
    \\    let res = app.dispatch(req);
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
