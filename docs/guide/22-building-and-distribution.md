# 22. Building and distributing

This chapter covers the mechanics of turning Kyte source into something you can ship: compiling a
single file, building a project, choosing a hypermedia framework for a web app, and cross-compiling a
program for another operating system.

## Compiling one file

The simplest build takes one file to one native executable:

```sh
kyte hello.ky -o hello
./hello
```

`kyte test file.ky` compiles and runs the `@test` functions in a file instead of producing a
standalone binary. This is what the guide's examples use.

## Building a project

Real applications are more than one file. `kyte init` scaffolds a project, and `kyte build` compiles
it:

```sh
kyte init web --name shop      # scaffold a web app (also: desktop)
cd shop
kyte build                     # debug build
kyte build --release           # optimised build
```

A project has a `project.json` at its root that names it, sets its version and type, and lists its
package dependencies. `kyte build` reads it, compiles every source file under `src/`, links against the
runtime, and writes the result under `build/<profile>/`, with the binary in `build/<profile>/bin/`.
Dependencies declared in `project.json` are fetched with `kyte get`.

## Choosing a hypermedia framework for a web app

A `web` project is hypermedia-first: handlers return small HTML fragments, and a client-side library
swaps those fragments into the page. `kyte init web` wires one such library into the scaffold's
`wwwroot/index.html` (its CDN `<script>` tag and a small demo widget) so a new app is interactive out of
the box. Pick it with `--framework` (short form `-f`):

```sh
kyte init web --name shop                      # htmx (the default)
kyte init web --name shop --framework datastar
kyte init web --name shop -f unpoly
```

The accepted values are:

| `--framework` | What it is |
|---------------|------------|
| `htmx` (default) | The most widely used option. Attributes like `hx-get` fetch a fragment and swap it into a target element. |
| `datastar` | Signals-based reactivity driven from the server. Its server actions read a live stream, which Kyte serves through `web.sse` (Chapter 17). |
| `unpoly` | Progressive enhancement built around full-page-feeling fragment updates, layers, and forms. |
| `htmz` | A tiny (roughly one line) approach that targets a hidden iframe; the smallest possible footprint. |
| `alpine` | Alpine.js with its AJAX plugin, for sprinkling behaviour into markup with `x-` attributes. |

All five suit the "handler returns an HTML fragment" model, so the rest of the project, the routes,
handlers, and views, is identical whichever you choose; only `wwwroot/index.html` differs. Single-page
and JSON-first frameworks are deliberately not offered, because they do not match this server-rendered
model. An unrecognised value is rejected with the list of valid ones. You can always change your mind
later by editing `wwwroot/index.html` and swapping the `<script>` tag by hand.

## Cross-compiling a program

Kyte can build a program for a different operating system than the one you are on, because the compiler
carries a cross-capable C++ toolchain for the runtime. Pass a target:

```sh
kyte app.ky --target linux-x86_64   -o app-linux
kyte app.ky --target linux-arm64    -o app-linux-arm64
kyte app.ky --target windows-x86_64 -o app.exe
```

The target names a program build as `<os>-<arch>`. The compiler builds the runtime for that target the
first time it sees it and caches it, then links a real ELF or PE executable. This is a best-effort
convenience for shipping a service built on your development machine; the native target is always the
most exercised.

## Where to go next

- Chapter 17 for the web framework the `--framework` scaffold sets up.
- Chapter 23 for running a built service in production with Kynator.
- Chapter 1 to return to the everyday `kyte` and `kyte test` workflow.
