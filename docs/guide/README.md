# The Nova Language Guide

A hands-on, example-driven tour of Nova, where every construct is shown with a **complete, runnable
program**. Each example lives under [`examples/`](examples/) as a real `.nova` file that compiles and
runs; the output shown in each chapter is the program's actual output.

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
| 17 | [Building a web service](17-web.md) | request/response, routing, the capstone |
| 18 | [How Nova works: architecture](18-architecture.md) | the compiler pipeline, ARC memory, the concurrency engine, self-contained delivery |
| 19 | [Building & distributing](19-building-and-distribution.md) | `nova build`, cross-compiling programs, packaging toolchain bundles + checksums |

> **Version:** tracks `nova version` (Beta 0.1.0). Syntax may still change per
> [`../STABILITY.md`](../STABILITY.md).
