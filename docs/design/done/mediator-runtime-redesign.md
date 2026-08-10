# Runtime mediator redesign (MediatR-parity, Minimal-API style)

**Status:** Proposed. Date: 2026-08-04. No code yet, this is the design of record for review.

**Goal.** Make Nova's web framework mirror .NET MediatR point to point, as a real runtime framework
that lives in the standard library, not in the compiler. The HTTP layer should only bind a request and
call `mediator.send(request)`. The mediator picks the handler for that request type, runs the pipeline
of behaviours around it, and returns the response. This matches ASP.NET Minimal API + MediatR:

```csharp
app.MapGet("/contacts",  async (IMediator m) => await m.Send(new GetContactsQuery()));
app.MapPost("/contacts", async (IMediator m, CreateContactCommand cmd) => await m.Send(cmd));
```

---

## 1. Why we are changing what we have

What shipped is a hybrid: the compiler bakes handler dispatch (`__mediator_dispatch_<Q>` in
`main.zig` generates `bind -> construct handler -> call -> serialise`), and only the pipeline is
runtime. That has real problems, and it is not what was agreed at design time:

1. **Framework logic lives in the compiler.** Evolving the mediator (scopes, ordering, request-typed
   behaviours) means editing `main.zig`, so the framework is coupled to the compiler.
2. **`send` is not a first-class operation.** Today you can only reach a handler through an HTTP route.
   MediatR's whole point is `mediator.send(request)` callable anywhere: one handler sending another
   request, a background job, a CLI command, a test. We cannot do that.
3. **No per-request DI scope.** The baked dispatch resolves from the root provider, so a transaction or
   unit-of-work behaviour cannot share a scoped connection with the handler. Scoped services are the
   normal MediatR pattern and we block them.
4. **No runtime flexibility.** Handlers are hardcoded, so no decorators, no test doubles, no
   conditional registration.
5. **Opaque generated code and string-keyed DI that fails at request time**, not at startup.

MediatR (confirmed from the source) is fully runtime: `Send` resolves `IRequestHandler<TReq,TResp>`
and the `IPipelineBehavior<TReq,TResp>` chain from the DI container, per request, from a scope.

---

## 2. The Nova constraint that shapes everything

Nova has **no runtime reflection**, and generics are **monomorphised** (erased at runtime to i64 value
words). So we cannot, at runtime, take a request object and reflect its type to find a handler the way
MediatR does. Two facts save us:

- **`send<TReq, TResp>(req)` is generic, so it is monomorphised at each call site.** Every place that
  calls `send` (an HTTP endpoint, another handler, a test) knows `TReq` at compile time. So `send` can
  compute a stable key with `serde.typeName<TReq>()` and look the handler up in a runtime map.
- **The compiler can scan `impl RequestHandler<Q,R>` at build time** and generate the code that
  *registers* each handler into that runtime map. This is registration source-generation, the same
  idea as MediatR's assembly scan, done at compile time but producing ordinary runtime registration
  rather than baked dispatch.

So the compiler's job shrinks to the **irreducible type-directed minimum**: per handler, emit a small
adapter and a registration call; per route, emit a small endpoint that binds the request type and
serialises the response type. Everything else (the registry, `send`, the pipeline, DI, scopes,
ordering) is ordinary Nova in the stdlib, where it can be read, tested, and evolved.

---

## 3. Core abstractions (mirror MediatR)

All in `web` / a new `mediator` stdlib module, none in the compiler.

| MediatR | Nova | Shape |
|---|---|---|
| `IRequest<TResponse>` | `Request<TResponse>` | marker trait on a request struct, declares its response type |
| `IRequestHandler<TRequest,TResponse>` | `RequestHandler<TRequest,TResponse>` | `async fn handle(self, req: TRequest): TResponse` |
| `IPipelineBehavior<TRequest,TResponse>` | `PipelineBehavior` (erased) | `async fn handle(self, ctx: RequestContext, next: Next): Response`-shaped, runs around every handler |
| `IServiceProvider` scope | `ServiceScope` | one per `send`, so handler + behaviours share scoped services |
| `ISender.Send` | `Mediator.send<TReq,TResp>(req): TResp` | runtime dispatch |

```nova
@serializable struct GetUserById impl Request<UserDto> { pub id: int }

struct GetUserByIdHandler impl RequestHandler<GetUserById, UserDto> {
    repo: UserRepository,                       // injected from the request scope
    init(repo: UserRepository) { self.repo = repo; }
    async fn handle(self, req: GetUserById): UserDto {
        return await self.repo.byId(req.id);
    }
}
```

`Request<TResponse>` is the key addition: it lets `send(req)` know the response type from the request
alone, so a caller writes `mediator.send(GetUserById{ id: 7 })` and gets a `UserDto`, no second type
argument. (If associated-type inference is too much for the checker initially, the fallback is an
explicit `send<GetUserById, UserDto>(req)`, uglier but mechanical. Decision flagged below.)

---

## 4. The runtime Mediator (all stdlib)

### 4.1 The registry

```
Mediator {
    handlers:  Map<string, HandlerAdapter>,     // typeName<TReq>()  -> adapter
    behaviors: List<PipelineBehavior>,           // ordered, wrap every send
    pre:       List<PreProcessor>,
    post:      List<PostProcessor>,
    provider:  ServiceProvider,                   // root; send() opens a scope off it
}
```

`HandlerAdapter` is the type-erased executor for one handler. It is a trait object so the map can hold
adapters for many request types uniformly:

```nova
trait HandlerAdapter {
    // req and the return travel as erased value words; the concrete adapter casts.
    async fn execute(self, req: <erased>, scope: ServiceScope): <erased>;
}
```

**This erased carrier is the one hard mechanism to nail down** (section 7). Because Nova trait dispatch
is already fully type-erased (every value is an i64 word), a compiler-generated
`GetUserByIdHandler__Adapter impl HandlerAdapter` can take the erased request word, treat it as
`GetUserById`, resolve `GetUserByIdHandler` from the scope, `await handle(req)`, and return the
`UserDto` word. `send<TReq,TResp>` supplies a `TReq` word and reads back a `TResp` word. The key
guarantees the adapter and the caller agree on the concrete types.

### 4.2 `send`

```nova
async fn send<TReq, TResp>(self: Mediator, req: TReq): TResp {
    let key   = serde.typeName<TReq>();
    let scope = self.provider.createScope();          // one scope per send (per request)
    let adapter = self.handlers.get(key) ?? <no-handler error>;

    // terminal: run the resolved handler adapter
    let terminal = AdapterTerminal(adapter, scope);
    // pre -> behaviours(terminal) -> post, exactly like today, but the terminal is the adapter
    let resp = await self.runPipeline(req, scope, terminal);
    return resp as TResp;
}
```

The pipeline (`runPipeline`, `Next`) is the machinery we already built and tested; only the terminal
changes from "compiler-baked dispatch" to "resolved handler adapter". Behaviours stay ordered and can
short-circuit or wrap, and now they share `scope` with the handler.

### 4.3 Registration (compiler-generated, but ordinary Nova)

The compiler scans `impl RequestHandler<Q,R>` and emits one visible function:

```nova
// <generated>, but real registration, not baked dispatch
fn __registerHandlers(m: Mediator): void {
    m.register("GetUserById", GetUserByIdHandler__Adapter{});
    m.register("CreateUser",  CreateUserHandler__Adapter{});
    // ...
}
```

`App` calls `__registerHandlers(self.mediator)` at startup. Missing handler for a routed request type
becomes a **startup check** (or a compile-time diagnostic if we scan routes too), not a request-time
panic. A developer can also `m.register(...)` or decorate by hand for tests, which restores the runtime
flexibility MediatR has.

---

## 5. The HTTP layer becomes thin (Minimal-API style)

`app.get<GetUserById>("/api/users/{id:int}")` registers a route keyed by `typeName<GetUserById>()`. On
a request the endpoint does only three things, all type-directed so the compiler emits the small glue,
but the glue calls the runtime mediator:

```
1. bind:      GetUserById req = GetUserById__bind(routeParams over body)   // @fromRoute / @fromBody
2. dispatch:  UserDto dto     = await app.mediator.send(req)               // runtime
3. serialise: Response        = 200 + UserDto__toJson(dto)  (or HttpError -> its status)
```

So the HTTP layer never knows about handlers. It binds, calls `send`, serialises. Exactly the
`app.MapPost("/x", (cmd, m) => m.Send(cmd))` shape, with binding and serialisation generated because
they need the concrete types.

`send` is also directly callable off the App (`app.mediator.send(...)`) from anywhere: another handler,
a `spawn`ed job, a test. That is the first-class `send` we are missing today.

---

## 6. Behaviours and their registration

Behaviours wrap every `send` in registration order (MediatR semantics: first registered is outermost).
They receive a `RequestContext` (the erased request, its type key, and the per-request `ServiceScope`)
and a `Next`, and return the response. Because they share the scope, a transaction behaviour and the
handler use the same connection.

### 6.1 Three registration channels

Following MediatR + FluentValidation, specificity does **not** come from registering behaviours per
handler. It comes from three channels:

| Thing | Registered how | Applies to |
|---|---|---|
| **Handlers** | compiler auto-registers (scan `impl RequestHandler<Q,R>`) | one per request type |
| **Validators** | compiler auto-registers (scan `impl Validator<T>`) | per request type; resolved by the generic ValidationBehavior |
| **Generic behaviours** (logging, exception, transaction, and the one ValidationBehavior) | explicit, ordered: `app.useBehavior(b)` | every `send` |
| **Handler-specific behaviours** (rare: caching, authz) | a **marker trait** on the request; the generic behaviour acts only when the request carries the marker | request types that opt in via the marker |

So `useBehavior` registers the pipeline **stages** (where order is the developer's decision). It stays
explicit and ordered on purpose; you cannot auto-discover order.

### 6.2 Validation is generic behaviour + per-type validator (the FluentValidation pattern)

The validation **behaviour** is generic and registered once. The validation **rules** are a per-type
`Validator<T>`, auto-registered by the compiler exactly like handlers (mirrors
`AddValidatorsFromAssembly`). The generic behaviour resolves the validator for the current request by
its type key and short-circuits on failure.

```nova
// Per-type rules, auto-discovered by the compiler (scan impl Validator<T>):
struct CreateProductValidator impl Validator<CreateProduct> {
    fn validate(self, cmd: CreateProduct): List<string> {
        let errs = List<string>();
        if (cmd.name.length == 0) { errs.push("name is required"); }
        if (cmd.price < 0)        { errs.push("price must be >= 0"); }
        return errs;
    }
}

// ONE generic behaviour, registered once, works for every request type:
struct ValidationBehavior impl PipelineBehavior {
    async fn handle(self, ctx: RequestContext, next: Next): Response {
        let v = ctx.validatorFor(ctx.requestType);        // per-type validator, resolved at runtime
        if (v != undefined) {
            let errs = v.validate(ctx.request);            // the validator casts the erased request
            if (errs.size() > 0) { return Response(Status.BadRequest, errs.join(", ")); }
        }
        return await next.proceed(ctx);                    // else continue to the handler
    }
}
```

`app.useBehavior(ValidationBehavior{})` once, and every command that has a `Validator<T>` is validated;
requests without one pass straight through. No per-handler validation wiring.

### 6.3 Generic behaviours by example

- **Transaction / unit of work**: open a transaction on the scoped connection, `await next.proceed`,
  commit on success, roll back on the error path. Needs the per-request scope (section 4.2), which is
  the whole reason scopes are in this design.
- **Exception handling**: wrap `next`, map a returned/`exception` error to a Response.
- **Logging / timing**: read the context, `await next`, annotate the response.

### 6.4 Handler-specific behaviours via a marker trait (decided)

For the rare genuinely per-request-type behaviour, the request opts in with a **marker trait**, and a
single generic behaviour acts only when the request carries it. This is MediatR's marker-interface
idiom (`request is ICacheable`) and keeps registration to one `useBehavior`, no per-type wiring:

```nova
// Marker: this request's response may be cached.
trait Cacheable {}
@serializable struct GetProductById impl Request<ProductDto>, Cacheable { pub id: int }

struct CachingBehavior impl PipelineBehavior {
    async fn handle(self, ctx: RequestContext, next: Next): Response {
        if (!ctx.requestIs("Cacheable")) { return await next.proceed(ctx); }   // only cacheable requests
        // ... check cache by ctx.requestKey, else run next and store ...
        return await next.proceed(ctx);
    }
}
```

`ctx.requestIs("Cacheable")` tests the marker on the concrete request type. (Mechanism: the compiler
records, per request type, which marker traits it implements, so the runtime can answer the check by
type key. This is a tiny addition to the same scan that registers handlers.)

Behaviours are **singleton instances**; per-request state is read from `ctx.scope` inside `handle`, so
a transaction behaviour is one instance that pulls the scoped connection per request. No behaviour
factories.

---

## 7. The erased carrier: confirmed mechanism (spiked 2026-08-04)

Everything rests on carrying a typed request through the runtime registry to its handler. A spike
settled how, empirically:

**What does NOT work:**
- `any` as the carrier: it **corrupts** a heap struct on the round trip (the open `any`-ownership hole,
  memory `nova-any-ownership-model`).
- Inline `x as Message` upcast: **crashes**.
- Generic widen `fn box<T>(x: T): Message { return x }`: **type error** (no widening of an unconstrained
  `T`). Trait bounds `<T: Message>` **do not parse** (unsupported syntax).

**What DOES work (all verified):**
- **Widen at a concrete return boundary**: `fn asMsg(g: GetUser): Message { return g }`.
- **Store `Message` trait objects in `Map<string, Message>`, retrieve, and `as GetUser` downcast** — the
  same pattern the DI `Service` seam uses (case 124).

### The mechanism

- A base marker trait **`Message`** that every request implements is the erased carrier (a trait object,
  never `any`).
- The runtime `send` is **non-generic**: `send(req: Message, key: string): Response`. It looks up the
  registered adapter by `key`, opens a scope, runs the pipeline with the adapter as terminal, returns a
  `Response`.
- The **compiler generates the tiny per-type glue** where concrete types are needed, all ordinary Nova:
  - per handler `impl RequestHandler<Q,R>`: an adapter `Q__Adapter impl HandlerAdapter` whose
    `execute(req: Message, scope)` does `let q = req as Q` (concrete downcast, works), builds the
    handler from the scope (DI), `await handle(q)`, and serialises `R` to a `Response`; plus a
    registration `m.register(typeName<Q>(), Q__Adapter{})`.
  - per route `app.get<Q>(url)`: the endpoint `let q = Q__bind(src); return await
    mediator.send(Q__asMessage(q), typeName<Q>())`, where `Q__asMessage` is the concrete widen.
- The **response is uniform (`Response`)**, so there is no erasure problem on the way back.
- **Validators are typed** the same way: `Validator<CreateProduct>` downcasts the `Message` `as
  CreateProduct` (concrete downcast in the validator) and validates. The generic `ValidationBehavior`
  resolves the validator by key and hands it the `Message`.

So the handler and the validator both receive the **typed** request (via the concrete downcast the
compiler emits), the mediator/pipeline/DI/scope are runtime stdlib, and the compiler only writes the
thin type-directed widen/adapter/bind/serialise glue.

### Deferred: typed internal `send` returning `TResp`

`send` returning a uniform `Response` fully serves the HTTP framework (bind, send, Response). MediatR's
`send` returns the typed `TResp`, which one handler uses to call another. That needs the **response**
un-erased too, which hits the same generic-downcast wall on the way back. It is deferred to a follow-on
(candidate: a compiler-generated typed `send<Q>` shim per request type, or closing generic
downcast/`any` ownership). Not needed for the web use case or the webapp demo.

---

## 8. Dependency injection and scopes

- `send` opens **one `ServiceScope` per call** off the App-owned provider. Handler and all behaviours
  resolve from that scope, so scoped services (a DB connection, a unit of work) are shared for the
  request and disposed at the end.
- The adapter resolves the handler and its constructor dependencies from the scope (not string-baked
  into the compiler output; the adapter is generated but calls `scope.require(...)`, and we should move
  to a typed `scope.get<T>()` to drop the string key). Singleton and transient lifetimes work as today.
- This is the piece that makes transaction/unit-of-work behaviours real.

---

## 9. What this means for the "remove the legacy path" task

The legacy `MessageHandler` + `app.handle` + `mediator.send(key, provider, src)` path is a **runtime
registry** already. It is closer to this design than the compile-time baking is. So we do **not** delete
the runtime idea; we **evolve** it:

- Replace the `ValueSource`-taking `MessageHandler` with the typed `HandlerAdapter` + typed `send`.
- Keep and generalise the runtime registry, pipeline, pre/post, DI (add scopes).
- Delete the compile-time **baked dispatch** (`__mediator_dispatch_<Q>` / `__mediator_dispatch_by_name`)
  in favour of compiler-generated **registration** + endpoint glue that call the runtime `send`.
- Migrate cases 69 / 124 / 125 / 204 / 205 and the scaffold to the typed `send` model.

So the cleanup still happens, but the target is this design, not "keep baking and just remove the old
map".

---

## 10. Migration plan (once the design is agreed)

1. **Spike (A):** confirm a generic handler-adapter trait object can be stored in a `Map` and invoked
   from a monomorphic `send<TReq,TResp>`. This de-risks section 7. (No framework changes yet.)
2. **`Request<TResponse>` marker + `send` inference** (or the explicit two-type fallback). Decide the
   ergonomics.
3. **Runtime `Mediator`**: registry, `send`, scope-per-send, reuse the existing pipeline/`Next`.
4. **Compiler:** replace baked dispatch generation with adapter + `__registerHandlers` generation
   (much smaller, and it emits ordinary Nova). Endpoint glue calls `send`.
5. **HTTP layer:** `app.get<T>` binds + `send` + serialise; `App` exposes `app.mediator` for direct
   `send`.
6. **Behaviours:** port validation (per-type validator), transaction (scoped), exception, logging.
7. **Remove** the legacy `MessageHandler`/`app.handle` path; migrate cases 69/124/125/204/205 + scaffold
   + guide + YT.
8. **Gates:** `send` outside HTTP; scoped-DI transaction behaviour; validation short-circuit; decorator
   / test-double registration.

---

## 11. Decisions

Resolved (2026-08-04):

- **Behaviours erased + per-type validator + marker trait for handler-specific ones.** DECIDED. See
  section 6. Generic behaviours via `useBehavior`; per-type validators auto-registered; handler-specific
  behaviours opt in via a marker trait (`Cacheable`, etc.), not per-type registration.
- **Erased carrier: plan (C) built on (A).** The compiler generates the per-type adapter + registration
  (tiny, type-directed); the runtime owns the registry, `send`, pipeline, DI. Confirm (A) storage with a
  spike first (step 1 of the migration plan).

Still to settle as we build (do not block the spike):

1. **`send` ergonomics:** `Request<TResponse>` marker so `send(req): TResp` infers the response type
   (nicest, small checker change) vs explicit `send<TReq, TResp>(req)` (mechanical fallback). Start with
   whichever the spike shows is cheaper; converge on the marker.
2. **Notifications** (`INotification` + multiple handlers, publish): later phase, not the first cut.
3. **Scope lifetime hooks:** ARC end-of-scope release for the first cut; add explicit `dispose` on
   scoped services (real connection cleanup) as a follow-on.
