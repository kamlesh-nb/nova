# The Nova Language Guide

A hands-on, example-driven tour of Nova, a statically-typed language built for **hypermedia web
applications**: the server renders HTML that the browser swaps in. Your whole service compiles to a
single native binary, with the runtime, web framework, TLS, and database drivers all coming from one
toolchain. It pairs with **NovaDB**, a database built for the same stack and deployed as its own service,
and a native orchestrator to run it in production. Every construct here is shown with a **complete,
runnable program**. Each example lives under [`examples/`](examples/) as a real `.nova` file that
compiles and runs; the output shown in each chapter is the program's actual output.

For the terse, citation-backed reference, see [`../language-specification.md`](../language-specification.md).
This guide is the *learning path*; the spec is the *contract*.

## Running the examples

```sh
# from the lang/ directory
nova docs/guide/examples/01_hello.nova -o /tmp/hello && /tmp/hello
```

`nova <file>.nova -o <out>` compiles a native executable; run it directly. Examples that use `@test`
functions run with `nova test <file>.nova`.

## Chapters

| # | Chapter | Covers |
|---|---------|--------|
| 1 | [Getting started](01-getting-started.md) | `main`, `console.log`, the toolchain |
| 2 | [Values & types](02-values-and-types.md) | `int`/`long`/`float`/`bool`, operators, casts, `let`/`const`, destructuring |
| 3 | [Strings](03-strings.md) | UTF-8 strings, template literals, the `string` stdlib |
| 4 | [Control flow](04-control-flow.md) | `if`/`while`, `if`-expression, the four `for` forms, `switch` |
| 5 | [Functions & closures](05-functions-and-closures.md) | functions, generics, closures, higher-order functions |
| 6 | [Collections](06-collections.md) | `List`, `Map`, `Set` |
| 7 | [Structs](07-structs.md) | fields, `init`, methods, visibility |
| 8 | [Enums](08-enums.md) | payload-less & payload variants, method dispatch |
| 9 | [Traits](09-traits.md) | dynamic dispatch, factories, downcasts, generic traits |
| 10 | [Optionals](10-optionals.md) | `T \| undefined`, narrowing, `?.`, `??` |
| 11 | [Error handling](11-error-handling.md) | `T \| E`, `exception` + `message()`, `try`, `catch`, `errdefer` |
| 12 | [Decimal](12-decimal.md) | exact `decimal128` arithmetic |
| 13 | [Ownership & memory](13-ownership.md) | ARC, borrow semantics, deterministic cleanup |
| 14 | [Modules & visibility](14-modules.md) | `import`, `pub`, the `platform` module |
| 15 | [Concurrency](15-concurrency.md) | `async`/`await`/`spawn`, futures, channels |
| 16 | [Serialization](16-serialization.md) | `@serializable`, JSON/BSON |
| 17 | [Web applications](17-web.md) | vertical slices, `RouteHandler`, `ctx.bind`, NSX views, the composition root |
| 18 | [Data access & the ORM](18-data-access.md) | the `db` seam, `DbValue`, the micro-ORM, `Repository<T>`, connection strings, backing the web app with NovaDB |
| 19 | [Package management](19-package-management.md) | `project.json`, `nova get`, the lockfile, `nova init`, import resolution |
| 20 | [Database drivers](20-database-drivers.md) | NovaDB, PostgreSQL, MySQL, SQL Server, MongoDB: intro, package deployment, connect, and notes |
| 21 | [How Nova works: architecture](21-architecture.md) | the compiler pipeline, ARC memory, the concurrency engine, self-contained delivery |
| 22 | [Building & distributing](22-building-and-distribution.md) | `nova build`, cross-compiling programs, packaging toolchain bundles + checksums |
| 23 | [Deploying with the orchestrator](23-deploying-with-the-orchestrator.md) | `service`/`orchd`/`orchctl`, load-balanced replicas, the config store on NovaDB |
| 24 | [Artifact delivery: the blob store](24-blob-store.md) | content-addressed `artifactd`, sha PUT/GET, Bearer auth, deploy by digest |

> **Version:** tracks `nova version` (Beta 0.1.0). Syntax may still change per
> [`../STABILITY.md`](../STABILITY.md).
