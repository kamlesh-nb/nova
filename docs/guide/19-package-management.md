# 19. Package management

Nova's package manager is deliberately small. There is no central registry, no
account to sign up for, and no separate `nova-pm` binary. A dependency is just a
git repository, named by its URL, and the same `nova` compiler that builds your
code also fetches and pins those repositories for you.

If you have used npm, Cargo or Go modules, the closest thing here is Go: like
`go get`, you point at a git URL and the toolchain clones it into a shared cache
and records the exact commit in a lockfile. Unlike npm there is no `node_modules`
folder in your project, and unlike Cargo there is no `crates.io` in the middle.
Everything is git.

This chapter covers the `project.json` manifest, adding a dependency with
`nova get`, the `project.lock.json` lockfile and reproducible builds, the
`nova init` project kinds, how an `import` finds a module, the build and test
commands, and how you publish a package of your own.

## The `project.json` manifest

Every Nova project has a `project.json` at its root. It is a small JSON file that
names the project and lists its dependencies. Here is a real one, from the
PostgreSQL web app in this repository:

```json
{
    "name": "nova-pg-web",
    "version": "0.1.0",
    "type": "web",
    "dependencies": [
        "https://github.com/kamlesh-nb/nova-postgres"
    ]
}
```

The compiler reads this shape (defined in `src/pipeline.zig`, `ProjectJson`):

- **`name`** (required): the project or package name. This drives two things: the
  name of the output binary, and, when this project is used as a dependency, the
  name of its directory in the shared cache.
- **`version`** (required): a version string such as `"0.1.0"`. Only
  `nova publish` reads it, where it becomes the git tag `v<version>`.
- **`type`** (optional): a free-form string. The build path does **not** read it,
  so it does not change how your project compiles. `nova init` writes one of
  `console`, `web` or `desktop`, and the drivers in this repository use
  `library`, but the only command that actually enforces a value is
  `nova publish`, which requires `"type": "library"`. Treat it as a label, not a
  build switch.
- **`dependencies`** (required, may be empty): an array of git URLs. Each element
  is a URL, optionally pinned with a `#ref` suffix (a branch name, a tag, or a
  full commit SHA), for example
  `"https://github.com/kamlesh-nb/nova-postgres#v1.2.0"`. These are git URLs, not
  `name@version` strings and not local paths.
- **`repository`** (optional): the canonical git URL for this package. It is not
  needed to build, but `nova publish` requires it.
- **`registry`** (optional): a git URL or local path for an index that lets you
  write `name@^1.2.0` style dependencies instead of raw URLs. It is off by
  default, and direct git URLs bypass it entirely. Most projects never set it.

Unknown fields are ignored, so a `project.json` with extra keys still parses.

A project with no dependencies is perfectly normal. The guide's own example web
app has an empty list:

```json
{
  "name": "webapp",
  "version": "0.1.0",
  "type": "web",
  "dependencies": []
}
```

## Adding a dependency: `nova get`

To add a dependency you do not hand-edit the `dependencies` array (though you
may). The command is:

```bash
nova get https://github.com/kamlesh-nb/nova-postgres
```

Note the name: it is `nova get`, following Go's `go get`. There is no
`nova add <package>` and no `nova install`. (`nova add` exists but only for a
different job, `nova add feature <name>`, covered later.)

`nova get <git-url>` does the following, in order:

1. Reads `project.json` from the current directory. If there is none, it tells
   you to run `nova init` first.
2. Appends the URL to `dependencies`, unless it is already there (so running it
   twice is harmless), and writes `project.json` back out, pretty-printed.
3. Resolves the whole dependency tree and writes `project.lock.json`.

Resolution is where the fetching happens. For each dependency the compiler:

- Clones the git repository into a scratch directory under the shared cache
  (`~/.nova/cache/.fetch-tmp`), checks out the requested ref (or takes a shallow
  clone of the default branch when the dependency floats), reads the dependency's
  own declared `name` and its checked-out commit SHA, and atomically moves the
  clone into its final home.
- The final home is content-addressed:
  `~/.nova/cache/<name>-<first 8 chars of the commit SHA>`, for example
  `~/.nova/cache/nova-postgres-a1b2c3d4`. Two projects that depend on the same
  commit share one checkout. A dependency that floats on a moving branch (no
  pinned ref) is cached under `~/.nova/cache/<name>-branch` instead, a single
  slot that later updates overwrite.
- Reads that dependency's own `project.json` and enqueues its dependencies too,
  so the whole transitive graph is resolved breadth-first. Diamonds (the same
  package reached by two paths) are de-duplicated.

Git is driven as ordinary `git` subprocesses, so you need `git` on your PATH, and
private repositories work exactly as your git credentials allow.

If you ever add a dependency by editing `project.json` by hand, run `nova get`
with no arguments to re-resolve. With no URL, `nova get` behaves the same as
`nova restore`.

You can now use the package. A PostgreSQL driver is imported as `postgres` (more
on how that name is derived below):

```nova
import postgres;
import db;

let conn = await postgres.PgDriver().connect(
    "postgresql://user:pass@127.0.0.1:5432/mydb");
```

## The lockfile and reproducible builds

`project.lock.json` records the exact commit every dependency resolved to. It is
generated for you, and you should commit it to version control. Its shape
(`lockfileVersion` plus a flat list of resolved entries) looks like this:

```json
{
  "lockfileVersion": 1,
  "dependencies": [
    {
      "url": "https://github.com/kamlesh-nb/nova-postgres",
      "ref": null,
      "resolved": "a1b2c3d4e5f6....",
      "name": "nova-postgres"
    }
  ]
}
```

Each entry carries the `url`, the requested `ref` (or `null` when the dependency
floats), the `resolved` commit SHA, and the dependency's declared `name`. The
`resolved` SHA together with `name` is what reconstructs the cache directory
(`<name>-<8 chars of SHA>`), so the lock points at one precise checkout.

The important property is that **the lockfile is authoritative for a build**. Once
`project.lock.json` exists, `nova build` reuses the locked commit and the existing
cache and does no network access at all. A plain build is offline. Only
`nova update` re-fetches a moving ref. This is what makes builds reproducible: the
same lock plus the same cache gives the same bytes, and a fresh machine gets the
same commits.

Two commands manage the lock directly:

- **`nova restore`** resolves the dependency tree from `project.json` and writes
  the lock. Use it after cloning a project on a new machine, or after editing the
  dependency list by hand. This is also what a bare `nova get` (no URL) does.
- **`nova update [<url>]`** advances floating dependencies to the current tip of
  their ref and rewrites the lock. With a URL it updates only that one; with no
  argument it updates all of them. This is the one path that deliberately
  re-fetches an already-locked moving ref, so it is how you pick up new commits on
  a branch you track.

You do not normally run `nova restore` by hand before a build. Every project build
resolves dependencies implicitly first: if there is no `project.json` or the
dependency list is empty it is a no-op, and otherwise it only rewrites the lock
when resolution actually differs from what is recorded.

## Starting a project: `nova init`

You scaffold a new project with `nova init`:

```bash
nova init web --name myapp
nova init console --name mytool
nova init desktop --name mywidget
```

The kind is one of `console`, `web` or `desktop`, and `--name` (or `-n`) sets the
project name, which is also the name of the directory created. `nova init app` is
a deprecated alias that now scaffolds a `web` project and prints a note. Any other
kind is rejected with a usage message.

Every kind lays down the same common files:

- `project.json`, with your chosen `name`, `"version": "0.1.0"`, the `type` set to
  the kind you chose, and an empty `"dependencies": []`.
- `.gitignore` covering `build/` and `*.o`.
- `.vscode/launch.json` and `.vscode/tasks.json` for editor integration.

What differs is the source tree:

- **`console`** lays down `src/main.nova` and `tests/main_test.nova`. This is the
  right starting point for a command-line tool or a service you drive yourself.
- **`web`** lays down a full ASP.NET-style vertical-slice tree: `src/main.nova` as
  the composition root, a `src/Features/Products/` slice (routes plus
  `CreateProduct` and `GetProductById` handlers), a shared repository, an `.nsx`
  view, domain entities and DTOs under `src/Domain/`, a `wwwroot/index.html`,
  and a feature test. It also writes an `app.yaml` at the project root (the
  file-based config the app reads through `app.config`; see Chapter 18), and
  drops `package.json`, `tailwind.config.js` and a `styles/` folder for styling
  (see the Tailwind aside at the end).
- **`desktop`** lays down just `src/main.nova`.

The default source file a project build compiles is `src/main.nova`, which is why
every kind provides one.

There is a second, related command, `nova add feature <name>`, which scaffolds a
new vertical slice inside an existing project. It creates a `features/<name>/`
directory with `model.nova`, `service.nova`, `view.nova` and a
`<name>.nova` handler file, and registers the feature in a `"features"` array in
`project.json` if one is present. Note that this is the only thing `nova add`
does; it is not the command for adding a dependency (that is `nova get`).

## How an import finds a module

An `import` in Nova names a module, and the compiler maps that name to a `.nova`
file. Chapter 14 covered the two everyday cases: a sibling file in the same
directory, and a stdlib module such as `collections.list` or `serde.json`. This
section covers the third case, a module that comes from a dependency.

The compiler tries a sequence of locations and takes the first hit. Roughly, in
order:

1. **Standard library and built-ins.** `platform`, anything under `std/`, and a
   fixed list of stdlib module names (`web/app`, `serde/json`, `data/db` and so
   on), plus short aliases like `list`, `map`, `set`, `db` and `pool`. These
   resolve inside the compiler's own `std` tree, so they never need a dependency.
2. **Sibling and ancestor files.** Walking up from the importing file, it tries
   `<dir>/src/<module>.nova` and `<dir>/<module>.nova` at each level, then the
   current directory. This is how your own project's modules resolve.
3. **Locked dependency packages.** Using `project.lock.json`, it matches a
   manifest dependency to a lock entry and looks inside that dependency's cache
   directory (`~/.nova/cache/<name>-<8 sha>`) for `src/<module>.nova` or
   `<module>.nova`. If two different URLs both claim the same import name it stops
   with a package-name-collision error rather than guess.
4. **Local `packages/` roots.** It scans `packages/`, `../packages` and so on up
   a few levels for a `nova-<module>/src/<module>.nova`. This is how the in-repo
   drivers under `packages/nova-*` resolve without a lock.
5. **The cache, scanned by filename.** Finally it scans every directory under
   `~/.nova/cache/` for a matching `src/<module>.nova` or `<module>.nova`.

The practical rule that falls out of this: **a package's importable name is the
name of the `.nova` file under its `src/` directory, not the repository name.**
The PostgreSQL driver lives in a repository called `nova-postgres`, and its
`project.json` `name` is also `nova-postgres`, but the module file is
`src/postgres.nova`, so you write `import postgres;`. The convention across the
Nova drivers is a repository named `nova-<module>` whose importable module is
`<module>`: `nova-postgres` gives `postgres`, `nova-mysql` gives `mysql`,
`nova-mssql` gives `mssql`, and so on.

Stdlib modules (chapter 14) and dependency modules therefore live in different
resolution stages, but at the call site they look identical: you write
`import <name>;` and qualify by the last segment. `import db;` reaches into the
standard library for the database seam, `import postgres;` reaches into a
dependency for the driver, and nothing in the syntax tells them apart.

## Building, testing and running a project

The compiler's subcommands are the whole interface; there is no separate build
tool. The ones you use day to day:

- **`nova build`** compiles the project, reading `project.json`, resolving
  dependencies, and writing output under `build/<profile>/` (a `debug` or
  `release` profile, each with its own `bin/` and `obj/`). It defaults to
  compiling `src/main.nova`; `--file <path>` overrides that, `-o <path>` sets the
  output, and `--release` (or `-r`) selects the release profile. There is also
  `--watch` to rebuild on change, and target switches such as
  `--target linux-x86_64` or `--target windows-x86_64` for cross-compilation.
- **`nova <file.nova>`** compiles a single file directly, without needing a
  project. Any first argument the compiler does not recognise as a subcommand is
  treated as a file to build, so `nova app.nova -o app` just works. This is the
  quickest way to try something out.
- **`nova test [<file>]`** runs the `@test` functions in a file or project (see
  chapter 1). It skips `main()` and runs only the tests.
- **`nova fmt [<file>]`** formats Nova source.
- **`nova version`** (also `--version`, `-v`) prints the compiler version, ABI
  version and host.

One thing worth stating plainly: **there is no `nova run`.** To run a project you
build it and then execute the binary that lands in `build/<profile>/bin/`, or for
a quick one-off you compile a single file with `nova file.nova -o out` and run
`./out`.

## Publishing a package

Publishing a Nova package means creating a git tag. There is no server to upload
to.

```bash
nova publish
```

`nova publish` reads `project.json` and enforces a few guardrails:

- `"type"` must be `"library"`. Only libraries publish.
- `repository` must be set to a non-empty canonical git URL, the one consumers
  will clone.
- The version becomes the tag `v<version>` (for example `0.1.0` becomes `v0.1.0`),
  and that tag must not already exist locally or on the remote. A released version
  is never overwritten.

A version that is not plain `X.Y.Z`, or a dirty working tree, only produce a
warning, since both still capture a real commit. On success it creates an
annotated git tag, pushes it to `origin`, and prints the line a consumer uses to
depend on that exact release:

```
nova get https://github.com/you/nova-widget#v0.1.0
```

So a consumer pins a published version with the `#ref` suffix on the URL, and
that pin flows straight into their lockfile.

## An aside: the Tailwind `package.json`

A web project scaffolded by `nova init web` contains a `package.json` as well as a
`project.json`, and this trips people up. The `package.json` is an **npm** file,
and it exists solely to run the Tailwind CSS command-line tool that builds your
stylesheet. The Nova build ignores it completely. Nova's own manifest is
`project.json`; `package.json` belongs to the JavaScript toolchain that produces
CSS. If you are not using Tailwind you can delete it, and it never affects how
your Nova code compiles or which dependencies it pulls.

## Where to go next

- **Chapter 20, Database drivers**, is the canonical place this all comes
  together: adding a driver such as `nova-postgres` or `nova-mysql` to a project
  is the textbook use of `nova get`, and each driver's chapter shows the git URL
  to add, the module name to import, and the connection string to pass.
- **Chapter 14, Modules and visibility**, covers the sibling-file and stdlib
  import cases that this chapter built on.
- **Chapter 18, Data access and the ORM**, shows what you do with a driver once it
  is wired in: `DbValue`, the micro-ORM and the generic `Repository<T>`.
