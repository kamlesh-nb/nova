# Nova video tutorials

This folder holds presenter-ready scripts for a full video series on the Nova language, following the
[written guide](../README.md) in order. There is a script per usage chapter; the two reference chapters,
19 Architecture and 20 Building and distributing, have no companion video, so the series runs
17, 18, then 21. Each script is a spoken walkthrough with on-screen code and live runs, so you can record
straight from it.

Every code block and every program output in these scripts is copied from the guide's runnable
examples in [`../examples/`](../examples), which are compiled and run by `run_all.sh`. So what you show
on screen is exactly what the compiler produces, nothing is faked.

## How each script is laid out

- A short hook to open the video.
- A "what we will cover" list.
- Numbered segments, each with what to **Say**, what to put **On screen**, the command to **Run it**,
  and the real output.
- A recap and an outro that points to the next video.

The timestamps are a guide, not a rule. Speak at your own pace and adjust.

## The series

| # | Video | Covers |
|---|-------|--------|
| 01 | [Getting started](01-getting-started.md) | Installing, your first program, how to run it |
| 02 | [Values and types](02-values-and-types.md) | Primitives, `let` and `const`, honest sizes |
| 03 | [Strings](03-strings.md) | Text, indexing, interpolation, the `string` module |
| 04 | [Control flow](04-control-flow.md) | `if`, `while`, `for`, ranges, `switch` |
| 05 | [Functions and closures](05-functions-and-closures.md) | Parameters, returns, closures, capture |
| 06 | [Collections](06-collections.md) | `List`, `Map`, `Set` |
| 07 | [Structs](07-structs.md) | Fields, `init`, methods, visibility |
| 08 | [Enums](08-enums.md) | Tagged unions, payloads, `switch` |
| 09 | [Traits](09-traits.md) | Dynamic dispatch, trait objects |
| 10 | [Optionals](10-optionals.md) | `T \| undefined`, guarded access |
| 11 | [Error handling](11-error-handling.md) | `exception` + `message()`, `try`, `catch`, `defer`, `errdefer` |
| 12 | [Decimal](12-decimal.md) | Exact `decimal` arithmetic |
| 13 | [Ownership](13-ownership.md) | ARC, who owns what, no leaks |
| 14 | [Modules](14-modules.md) | `import`, visibility, project layout |
| 15 | [Concurrency](15-concurrency.md) | `async`, `await`, `spawn`, channels |
| 16 | [Serialization](16-serialization.md) | JSON serde, `@serializable` |
| 17 | [Web](17-web.md) | The `nova init web` template and the mediator pipeline |
| 18 | [Data access and NovaDB](18-data-access.md) | The `db` seam, the drivers, connection strings, the micro-ORM, backing the web app with NovaDB |
| 21 | [Deploying with the orchestrator](21-deploying-with-the-orchestrator.md) | `proxyd`/`orchd`/`orchctl`, load-balanced replicas, the config store on NovaDB |

## Suggested recording order

Record in numbered order. Each video assumes the viewer has watched the ones before it, and the outros
are written to lead into the next one. Videos 01 to 06 are the fundamentals, 07 to 11 are the type and
error model, 12 to 14 fill in the details, 15 to 17 build up to real concurrent and web apps, 18 backs
the app with NovaDB, and 21 deploys it with the orchestrator.
