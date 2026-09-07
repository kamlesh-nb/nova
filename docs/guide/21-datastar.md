# 21. Datastar: server-driven hypermedia

Chapter 17 showed the web framework returning HTML fragments that the browser
swaps into the page. That is hypermedia over a normal request and response: the
browser asks, the server answers once, the exchange ends. **Datastar** extends
the same idea to a live connection. The browser opens one long-lived response
and the server keeps pushing small events down it: patch this piece of the DOM,
update these reactive values, run this script, redirect. The page reacts as the
events arrive, and you still write no client-side JavaScript of your own.

Kyte talks to a Datastar front end through the **`nova-datastar`** package, a
port of the official [`datastar-go`](https://github.com/starfederation/datastar-go)
server SDK. It speaks the Datastar v1 protocol (`datastar-patch-elements` and
`datastar-patch-signals`) and it is the piece that turns high-level calls
("patch these elements", "merge these signals") into the exact Server-Sent
Events (SSE) frames the Datastar client library understands.

This chapter assumes you have read chapter 17 (the web framework), chapter 15
(`async`/`await`), and chapter 19 (adding a package to a project).

## Adding the package

The easiest way is to let the scaffolder do it. Scaffolding a web app with the
`datastar` framework wires the `nova-datastar` dependency into `project.json`
for you, so you never hand-edit it:

```bash
kyte init web --name shop --framework datastar
```

The generated `project.json` already carries the dependency:

```json
{
  "name": "shop",
  "version": "0.1.0",
  "type": "web",
  "dependencies": [
    "https://github.com/kamlesh-nb/nova-datastar"
  ]
}
```

The other frameworks (htmx, Unpoly, htmz, Alpine) consume the plain HTML
fragments your handlers already return, so they need no package and leave
`dependencies` empty.

To add `nova-datastar` to an existing project instead, use `kyte get`, which
appends the git URL to `dependencies` for you (chapter 19 covers this in full):

```bash
kyte get https://github.com/kamlesh-nb/nova-datastar
```

Either way, `kyte build` resolves the dependency (locally from a sibling
`packages/` root, or by fetching the git URL). Once resolved, these modules are
importable:

| Import         | What it gives you                                                        |
|----------------|--------------------------------------------------------------------------|
| `datastar`     | `Sse`, the generator a handler calls to push events. The public face.    |
| `ds_response`  | `patch(fragment)`, a one-shot patch response for `@get`/`@post` actions. |
| `ds_signals`   | `PatchSignalOptions` and `readSignalsRaw(req)`, the inbound-signal reader.|
| `ds_elements`  | `PatchElementOptions` and the element/script line builders.              |
| `ds_const`     | Protocol constants: event names, patch modes, namespaces, defaults.      |
| `ds_sink`      | The transport seam: `SseSink` trait, `StreamSink`, `IoSink`, `BufferSink`.|
| `ds_wire`      | The low-level SSE frame encoder (you rarely call it directly).           |

Most application code touches only `datastar`, `ds_response`, `ds_signals`, and
`ds_elements`.

## The mental model

A Datastar exchange is one SSE stream. The server writes named events, each
carrying one or more `data:` lines, and the Datastar client applies them:

- **Patch elements**: send a fragment of HTML plus a target selector and a merge
  mode (replace, inner, append, remove, and so on). The client splices it into
  the live DOM. This is the workhorse: a fragment that carries its own `id` is
  morphed onto the element with the same `id`.
- **Patch signals**: send a JSON object of reactive values. The client merges it
  into its signal store, and any part of the page bound to those signals updates.
- **Execute a script**: run a snippet of JavaScript in the browser. Datastar has
  no dedicated script event, so the SDK delivers it as a `<script>` element patch
  that removes itself after running.
- **Redirect**: a small script that navigates the browser, deferred one tick so
  the current response finishes cleanly first.

You produce all of these through one type, `datastar.Sse`.

## Two shapes of a response

There are two ways to send Datastar events, and the difference is whether the
connection stays open.

1. **A one-shot patch.** A Datastar `@get`/`@post` action fires, your handler
   answers with a tiny `text/event-stream` body carrying one or a few patch
   frames, and the response completes. This is the common case: a click, a form
   submit, a fragment swapped in. It fits the normal `RouteHandler` from
   chapter 17, because it is still one request and one response.
2. **A live stream.** The browser opens a long-lived connection and the server
   pushes events over it for as long as it stays open (a status feed, a
   dashboard, a chat). This uses the framework's `app.sse` seam and an
   `SseHandler`.

### One-shot patches

The simplest form is `ds_response.patch`, which wraps a single self-identifying
fragment in a one-shot patch response:

```kyte
import web.response;
import ds_response;
import Features.Products.views.product;

pub class CreateProductHandler impl RouteHandler {
    repo: ProductRepository,
    init(repo: ProductRepository) { self.repo = repo; }

    async fn handle(self: CreateProductHandler, ctx: Context): response.Response {
        let cmd = ctx.bind<CreateProduct>();
        let saved = await self.repo.create(cmd);
        // product.card(saved) renders <article id="product-42">...</article>;
        // the client morphs it onto the matching element by id.
        return await ds_response.patch(product.card(saved));
    }
}
```

When you need to patch more than one region in a single response (say a list and
a toast), build the frames yourself over a `BufferSink` and set the headers. A
`BufferSink` is an in-memory sink: the same `Sse` verbs write into it instead of
a socket, and `contents()` gives you the accumulated bytes.

```kyte
import web.response;
import web.status;
import datastar;
import ds_sink;

async fn twoPatches(list: string, toast: string): response.Response {
    let buf = ds_sink.BufferSink();
    let sse = datastar.Sse.overBuffer(buf);
    let _1 = await sse.patchElementsSimple(list);
    let _2 = await sse.patchElementsSimple(toast);
    return response.Response(Status.Ok, buf.contents())
        .setHeader("Content-Type", "text/event-stream")
        .setHeader("Cache-Control", "no-cache");
}
```

Every `Sse` verb is `async` and returns the `int` byte count the sink accepted,
so the `let _ = await ...` shape is normal here.

### A live stream

For a connection that stays open, register an `SseHandler` with `app.sse`. The
framework hands your handler the raw connection as an `aio.AsyncIO`; you wrap it
with `Sse.overStreamIO`, write the SSE headers once, then push events in a loop.
This is the live order-status feed from the `nova-pg-web` sample app:

```kyte
import web.app;
import web.request;
import net.aio;
import datastar;

pub class OrderEventsSse impl SseHandler {
    repo: OrderRepository,
    init(repo: OrderRepository) { self.repo = repo; }

    async fn stream(self: OrderEventsSse, req: request.Request, io: aio.AsyncIO): void {
        let ds = datastar.Sse.overStreamIO(io);
        let _h = await ds.writeHeaders();          // SSE preamble, once, up front
        let id = req.query.get("id") ?? "";

        // Seed the current state so the viewer sees where things stand now.
        let cur = await self.repo.status(id);
        let _s = await ds.patchElementsSimple(orders.statusView(id, cur));

        // Then tail a feed and patch each new fragment as it arrives.
        let lastId = await self.repo.latestEventId(id);
        let alive = true;
        while (alive) {
            let evs = await self.repo.pollEvents(id, lastId);
            let i = 0;
            while (i < evs.items.size()) {
                let e = evs.items.get(i) ?? OrderEvent{ id: 0 as long, order_id: "", fragment: "", created_at: "" };
                lastId = e.id;
                let w = await ds.patchElementsSimple(e.fragment);
                if (w < 0) { alive = false; }       // a negative write means the client went away
                i = i + 1;
            }
            if (alive) { await aio.delay(1000); }
        }
    }
}
```

Register it in the composition root beside your normal routes:

```kyte
app.sse("/orders/{id}/events", OrderEventsSse(orderRepo));
```

Two things to note. `writeHeaders` is called exactly once and only on the live
path (the one-shot path sets its headers on the `Response` instead). And a write
that returns a negative count means the browser has disconnected, which is your
cue to stop the loop and let the handler return.

> Back-pressure is automatic on the live path. `StreamSink`/`IoSink` write is
> `async`, so a slow client suspends your loop at the `await` rather than letting
> the server race ahead and buffer without bound. The `BufferSink` never
> suspends, which is exactly why it suits tests and one-shot buffering.

## Patching elements

`patchElementsSimple(html)` uses the default options: the fragment carries its
own `id` and the client merges it onto the matching element. When you need to
say where and how, pass `PatchElementOptions`. Build it with a factory rather
than by hand so every field starts defined:

```kyte
import ds_elements;

// Replace the inner HTML of #cart-count:
await sse.patchElements("<span>3</span>", ds_elements.PatchElementOptions.inner("#cart-count"));

// Target a selector but keep the default (outer) merge mode:
await sse.patchElements(fragment, ds_elements.PatchElementOptions.withSelector("#panel"));
```

`PatchElementOptions` carries the target `selector`, the merge `mode` (the
`ds_const.MODE_*` values below), an optional DOM `namespace` for SVG or MathML,
a `useViewTransition` flag to animate the change, and the per-event `eventId` and
`retryMs`. A line goes on the wire only when a field differs from the Datastar
default, so a plain patch stays as small as possible.

To delete nodes, name a selector:

```kyte
await sse.removeElement("#spinner");
```

The merge modes live in `ds_const`:

| Constant       | Effect                                                    |
|----------------|-----------------------------------------------------------|
| `MODE_OUTER`   | Replace the whole target element (the default).           |
| `MODE_INNER`   | Replace only the target's inner HTML.                     |
| `MODE_REPLACE` | Replace the target with the supplied markup.              |
| `MODE_PREPEND` | Insert as the first children of the target.               |
| `MODE_APPEND`  | Insert as the last children of the target.                |
| `MODE_BEFORE`  | Insert immediately before the target.                     |
| `MODE_AFTER`   | Insert immediately after the target.                      |
| `MODE_REMOVE`  | Remove the target (what `removeElement` uses).            |

## Patching signals

Signals are Datastar's reactive state: a flat JSON object the client keeps and
binds to the page. Merge into it with `patchSignals`:

```kyte
await sse.patchSignals("{\"count\":3,\"open\":true}");
```

`patchSignalsIfMissing` merges only keys the client does not already hold, which
is how you seed initial state without clobbering a value the user has since
changed:

```kyte
await sse.patchSignalsIfMissing("{\"theme\":\"dark\"}");
```

Rather than hand-format the JSON, you can build it with the `serde.json` helpers
and let the SDK stringify it correctly (escaping and all). Kyte has no runtime
reflection, so where `datastar-go` marshals an arbitrary struct, the Kyte SDK
takes a `json.JsonValue`:

```kyte
import serde.json;

let sig = json.object();
sig.set("count", json.number(3.0));
sig.set("name", json.str(user.name));       // escaped correctly by stringify
await sse.marshalAndPatchSignals(sig);
```

For full control over the per-event options (the if-missing flag plus `eventId`
and `retryMs`) use `patchSignalsWith` with a `ds_signals.PatchSignalOptions`.

### Reading inbound signals

Datastar sends the client's current signals back with each action, but not in
the same place for every verb: a GET or DELETE has no body, so the signals ride
in a `datastar` query parameter, while a POST/PUT/PATCH sends them in the body.
`ds_signals.readSignalsRaw(req)` hides that split and hands you the raw JSON:

```kyte
import ds_signals;

async fn handle(self: SearchHandler, ctx: Context): response.Response {
    let signalsJson = ds_signals.readSignalsRaw(ctx.request);
    // signalsJson is the client's signal state as raw JSON; parse it with serde.json.
    ...
}
```

It returns the JSON exactly as received, with no parsing, and yields the empty
string (rather than failing) when a GET or DELETE arrives without the parameter.
A typed `readSignals<T>` binder is a planned follow-on; for now parse the raw
JSON yourself with `serde.json`.

## Running scripts and redirecting

`executeScript` runs a snippet of JavaScript. It is delivered as a self-removing
`<script>` element patch, so the tag cleans itself out of the DOM after running:

```kyte
await sse.executeScript("console.log('saved')");
```

`executeScriptRaw(src, autoRemove)` lets you keep the tag in place, and
`executeScriptWith(src, autoRemove, attributes)` adds raw attributes such as
`type="module"`. `redirect` navigates the browser, deferred one tick so the SSE
response finishes before the navigation aborts the connection, with the URL
safely encoded as a JavaScript string literal:

```kyte
await sse.redirect("/dashboard");
```

## Testing the wire bytes

Because every verb writes through the `SseSink` seam, and `BufferSink` captures
the exact bytes with no socket involved, you can golden-test the frames a handler
would produce. Drive the same builders you use in production and assert on
`contents()`:

```kyte
import datastar;
import ds_sink;
import string;

@test
async fn patch_frame_is_wellformed(): void {
    let buf = ds_sink.BufferSink();
    let sse = datastar.Sse.overBuffer(buf);
    let _ = await sse.patchElementsSimple("<div id=greeting>hello</div>");

    let out = buf.contents();
    assert(string.contains(out, "event: datastar-patch-elements"));
    assert(string.contains(out, "data: elements <div id=greeting>hello</div>"));
}
```

The package ships its own golden tests under `tests/` (`01_wire.ky`,
`02_generator.ky`, `03_deltas.ky`) that verify the wire format byte for byte and
run ASAN-clean.

## How it fits together

The package is deliberately split so each responsibility has one home, and the
public `Sse` stays a readable list of verbs:

| Module        | Responsibility                                                            |
|---------------|---------------------------------------------------------------------------|
| `ds_const`    | Protocol constants: event names, patch modes, `data:` keys, defaults.     |
| `ds_wire`     | The SSE frame encoder, the one place that knows the on-the-wire layout.   |
| `ds_elements` | Element, remove, and script line builders plus `PatchElementOptions`.     |
| `ds_signals`  | The signal patch builder plus `readSignalsRaw`.                           |
| `ds_sink`     | The transport seam: `SseSink` trait and its stream and buffer sinks.      |
| `datastar`    | `Sse`, the public generator that composes the above over a sink.          |

The key decision is that `Sse` depends on the `SseSink` trait, never a concrete
transport. That is why the live reactor path (`StreamSink`/`IoSink`) and the
offline test path (`BufferSink`) are interchangeable, and why the same handler
code runs whether the events go out over a keep-alive socket or into a buffer.

## Status and limits

`nova-datastar` covers the Datastar v1 element and signal protocol with the
verbs above, verified byte-exact and ASAN-clean offline. A few things are still
follow-ons worth knowing before you lean on them:

- A typed `readSignals<T>` binder, once the serde binder is exposed as a callable
  seam. Today read signals as raw JSON and parse with `serde.json`.
- First-class router integration so a `RouteHandler` can return a long-lived SSE
  stream directly. For now the live path is the `app.sse` + `SseHandler` seam
  shown above.
- `datastar-go`'s gzip compression parity.
- Verification against a live Datastar client in the browser.

## Where to go next

- **Chapter 17, Building a web application**, is the framework this builds on:
  `RouteHandler`, `ctx.bind`, views, and the `app.sse` seam.
- **Chapter 15, Concurrency**, explains the `async`/`await` the live streaming
  loop relies on.
- **Chapter 19, Package management**, covers `project.json` and `kyte get` in
  full.
