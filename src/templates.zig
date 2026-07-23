// src/templates.zig

pub const console_main_sample =
    \\import string;
    \\
    \\fn main(): void {
    \\    console.log("Hello, World from Nova console application!");
    \\}
;

pub const console_test_sample =
    \\import assert;
    \\
    \\@test
    \\fn test_sample(): void {
    \\    assert.equalInt(1, 1);
    \\}
;

pub const app_main_sample =
    \\import web.server;
    \\import web.router;
    \\import web.di;
    \\import web.mediator;
    \\import web.controller;
    \\import web.logger;
    \\import web.middleware;
    \\import web.methods;
    \\import web.response;
    \\import features.home.controllers.index;
    \\import features.home.services.index;
    \\import features.home.handlers.index;
    \\
    \\fn main(): void {
    \\    let services = ServiceCollection();
    \\
    \\    // Register application dependencies in the DI container
    \\    services.addSingleton("Logger", (sp) => {
    \\        return Logger("app.log");
    \\    });
    \\
    \\    services.addSingleton("LoggerMiddleware", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return LoggerMiddleware(log);
    \\    });
    \\
    \\    services.addSingleton("HomeService", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return HomeService(log);
    \\    });
    \\
    \\    services.addTransient("IndexHandler", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let service = provider.resolve("HomeService") as HomeService;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return IndexHandler(service, log);
    \\    });
    \\
    \\    services.addSingleton("Mediator", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let m = Mediator();
    \\        let handler = provider.resolve("IndexHandler") as RequestHandler;
    \\        m.registerHandler("home.index", handler);
    \\        return m;
    \\    });
    \\
    \\    services.addTransient("HomeController", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let m = provider.resolve("Mediator") as Mediator;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return HomeController(m, log);
    \\    });
    \\
    \\    let sp = services.buildServiceProvider();
    \\
    \\    // Resolve controller and register routes
    \\    let router = Router();
    \\    let homeCtrl = sp.resolve("HomeController") as HomeController;
    \\    homeCtrl.registerRoutes(router);
    \\
    \\    // Start HttpServer with routing and middleware
    \\    let logger_mw = sp.resolve("LoggerMiddleware") as LoggerMiddleware;
    \\    let app = HttpServer();
    \\    defer app.delete();
    \\    app.listen(8080, (req) => {
    \\        let res_dummy = Response.ok("");
    \\        let action = logger_mw.execute(req, res_dummy);
    \\        if (action == MiddlewareAction.Stop) {
    \\            return res_dummy;
    \\        }
    \\        let res = router.route(req);
    \\        let route = MatchedRoute{
    \\            method: Method.fromString(req.method),
    \\            pattern: req.path,
    \\        };
    \\        logger_mw.after(req, res, route);
    \\        return res;
    \\    });
    \\}
;

pub const app_view_sample =
    \\import string;
    \\
    \\pub struct IndexView {
    \\    message: string,
    \\    init(message: string) {
    \\        self.message = message;
    \\    }
    \\    pub fn render(self: IndexView): string {
    \\        return (<div>
    \\            <h1>{self.message}</h1>
    \\        </div>);
    \\    }
    \\}
;

pub const app_service_sample =
    \\import string;
    \\import web.di;
    \\import web.logger;
    \\
    \\pub struct HomeService impl Service {
    \\    pub logger: Logger,
    \\    init(logger: Logger) {
    \\        self.logger = logger;
    \\    }
    \\    pub fn getWelcomeMessage(self: HomeService): string {
    \\        self.logger.info("getWelcomeMessage called in HomeService");
    \\        return "Welcome to your DI & Controller-based Nova Web App!";
    \\    }
    \\}
;

pub const app_handler_sample =
    \\import string;
    \\import web.mediator;
    \\import web.di;
    \\import web.logger;
    \\import features.home.services.index;
    \\import features.home.views.index;
    \\
    \\pub struct IndexHandler impl RequestHandler, Service {
    \\    pub service: HomeService,
    \\    pub logger: Logger,
    \\
    \\    init(service: HomeService, logger: Logger) {
    \\        self.service = service;
    \\        self.logger = logger;
    \\    }
    \\
    \\    pub fn handle(self: IndexHandler, req: any): any {
    \\        let request = req as Request;
    \\        self.logger.info("IndexHandler handling request");
    \\        let msg = self.service.getWelcomeMessage();
    \\        let view = IndexView(msg);
    \\        return html(view.render());
    \\    }
    \\}
;

pub const app_controller_sample =
    \\import web.request;
    \\import web.response;
    \\import web.router;
    \\import web.controller;
    \\import web.di;
    \\import web.mediator;
    \\import web.logger;
    \\
    \\pub struct HomeController impl Controller, Service {
    \\    pub mediator: Mediator,
    \\    pub logger: Logger,
    \\
    \\    init(mediator: Mediator, logger: Logger) {
    \\        self.mediator = mediator;
    \\        self.logger = logger;
    \\    }
    \\
    \\    @get("/")
    \\    pub fn index(self: HomeController, req: Request): Response {
    \\        self.logger.info("HomeController index called");
    \\        return self.mediator.send("home.index", req) as Response;
    \\    }
    \\}
;

pub const app_test_sample =
    \\import assert;
    \\import map;
    \\import string;
    \\import web.di;
    \\import web.mediator;
    \\import web.request;
    \\import web.response;
    \\import web.logger;
    \\import features.home.services.index;
    \\import features.home.handlers.index;
    \\
    \\@test
    \\fn test_home_flow(): void {
    \\    let services = ServiceCollection();
    \\    services.addSingleton("Logger", (sp) => {
    \\        return Logger("test_app.log");
    \\    });
    \\    services.addSingleton("HomeService", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return HomeService(log);
    \\    });
    \\    services.addTransient("IndexHandler", (sp) => {
    \\        let provider = sp as ServiceProvider;
    \\        let service = provider.resolve("HomeService") as HomeService;
    \\        let log = provider.resolve("Logger") as Logger;
    \\        return IndexHandler(service, log);
    \\    });
    \\
    \\    let sp = services.buildServiceProvider();
    \\    let handler = sp.resolve("IndexHandler") as IndexHandler;
    \\    assert.isTrue(handler != undefined);
    \\
    \\    let req = Request{
    \\        method: "GET",
    \\        path: "/",
    \\        query: Map<string, string>(16, string.hash),
    \\        headers: Map<string, string>(16, string.hash),
    \\        cookies: Map<string, string>(16, string.hash),
    \\        body: "",
    \\    };
    \\
    \\    let res = handler.handle(req) as Response;
    \\    assert.isTrue(res != undefined);
    \\}
;

// ============================================================================
// `nova init web` — vertical-slice (VSA) web app templates (T5).
// Each feature slice is a self-contained folder; the mediator wires request TYPE ->
// handler. Verified to compile as a multi-file project.
// ============================================================================

pub const web_main_sample =
    \\// main.nova — app composition root (= Program.cs): register handlers + routes, wire
    \\// static files, run. Each `handle<TReq>` binds a request type to its handler; the
    \\// matching `get/post<TReq>` registers the route. Vertical slices live under Features/.
    \\import web.app;
    \\import web.request;
    \\import web.response;
    \\import serde.source;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.GetProductById.handler;
    \\
    \\fn buildApp(): App {
    \\    let app = App();
    \\
    \\    // Products feature — one registration per slice.
    \\    app.handle<CreateProduct>(CreateProductHandler{});
    \\    app.post<CreateProduct>("/api/products");
    \\
    \\    app.handle<GetProductById>(GetProductByIdHandler{});
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
    \\// The command: what the client sends to create a product. @serializable makes the
    \\// compiler generate its binder so `CreateProduct{ name: src.getString("name") }` works.
    \\@serializable pub struct CreateProduct {
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
    \\import web.status;
    \\import serde.source;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.validator;
    \\
    \\// Handles CreateProduct: bind the command (visible, debuggable), validate, respond.
    \\pub struct CreateProductHandler impl MessageHandler {
    \\    fn handle(self: CreateProductHandler, src: ValueSource): Response {
    \\        let cmd = CreateProduct{ name: src.getString("name"), price: src.getInt("price") as int };
    \\        let err = validateCreateProduct(cmd);
    \\        if (err.length != 0) {
    \\            return Response(Status.BadRequest, err);
    \\        }
    \\        // (persist here via a Shared/database repository, then return the new id)
    \\        return json(`{"id":1,"name":"${cmd.name}"}`);
    \\    }
    \\}
;

pub const web_get_query_sample =
    \\// The query: fetch a product by id. Bound from the route param `{id:int}`.
    \\@serializable pub struct GetProductById {
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
    \\import web.response;
    \\import web.status;
    \\import serde.source;
    \\import Features.Products.GetProductById.query;
    \\
    \\pub struct GetProductByIdHandler impl MessageHandler {
    \\    fn handle(self: GetProductByIdHandler, src: ValueSource): Response {
    \\        let q = GetProductById{ id: src.getInt("id") as int };
    \\        // (load from a repository; stubbed here)
    \\        return json(`{"id":${q.id},"name":"Sample Product"}`);
    \\    }
    \\}
;

pub const web_view_sample =
    \\import web.response;
    \\
    \\// A per-feature NSX/JSX view — returns an HTML string the handler (or a page route)
    \\// can render. Feature views live beside the slices that use them.
    \\pub fn productCard(name: string, price: int): string {
    \\    return <div class="card">
    \\        <h3>{name}</h3>
    \\        <p class="price">{price}</p>
    \\    </div>;
    \\}
;

pub const web_domain_entity_sample =
    \\// Domain entity — the core business object (persistence-agnostic).
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
    \\<head><meta charset="utf-8"><title>Nova Web App</title></head>
    \\<body style="font-family:system-ui;max-width:40rem;margin:4rem auto">
    \\  <h1>Nova Web App</h1>
    \\  <p>Vertical-slice API. Try <code>GET /api/products/1</code>.</p>
    \\</body>
    \\</html>
;

pub const web_test_sample =
    \\import assert;
    \\import web.app;
    \\import web.request;
    \\import web.response;
    \\import serde.source;
    \\import Features.Products.CreateProduct.command;
    \\import Features.Products.CreateProduct.handler;
    \\import Features.Products.GetProductById.query;
    \\import Features.Products.GetProductById.handler;
    \\
    \\fn testApp(): App {
    \\    let app = App();
    \\    app.handle<CreateProduct>(CreateProductHandler{});
    \\    app.post<CreateProduct>("/api/products");
    \\    app.handle<GetProductById>(GetProductByIdHandler{});
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
;

// ============================================================================
// `nova init desktop` — webview desktop app template (T5, W1).
// ============================================================================

pub const desktop_main_sample =
    \\// main.nova — a native desktop app: a webview window rendering NSX, with a Nova
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
