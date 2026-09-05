# Kyte Packages

Kyte's package model is deliberately small: a package is a **git repository** containing Kyte source,
and a project declares its dependencies in `project.json`. There is no central registry to operate or
trust; resolution is by git URL. This is the ecosystem seam that lets the language grow beyond a single
codebase.

## project.json

`kyte init` writes a `project.json` at the project root:

```json
{
  "name": "myapp",
  "version": "0.1.0",
  "type": "web",
  "dependencies": []
}
```

- `name` -- the project name.
- `version` -- your project's version (semver recommended; see [STABILITY.md](STABILITY.md)).
- `type` -- the scaffold kind (`console`, `web`, or `desktop`).
- `dependencies` -- a list of git URLs, one per package.

## Consuming a package

```bash
kyte get https://github.com/<owner>/<repo>
```

This clones the repository into the local package cache and appends its URL to `dependencies` in
`project.json`. In your Kyte source you then `import` the package's modules by their module path, the
same way you import the standard library:

```kyte
import somepkg.client;      // a module provided by the fetched package
```

On a fresh checkout, restore every recorded dependency with a bare:

```bash
kyte get                    # no URL: reads project.json and restores all dependencies
```

Because dependencies are plain git URLs, pinning is done the git way: point at a repository whose tag
or commit you trust. For reproducibility, depend on a tagged release rather than a moving branch.

## Publishing a package

To publish, you make a git repository that other projects can `kyte get`:

1. Put your Kyte modules under a clear module path (the directory layout is the import path).
2. Include a `project.json` describing the package.
3. If the package needs native code, keep that build self-contained and documented; a package that
   links a native library is environment-dependent for its consumers, so prefer pure Kyte where you
   can.
4. Tag releases (`vX.Y.Z`) so consumers can pin an exact version.
5. Push to a git host. Consumers add it with `kyte get <your-repo-url>`.

There is no publish step beyond `git push`: the URL *is* the package identity.

## Existing packages (the seed ecosystem)

The database drivers (PostgreSQL, MySQL, MSSQL, MongoDB, NovaDB) and the orchestrator are maintained
as separate Kyte packages rather than living in the standard library. They are the working examples of
the package model: real Kyte code, consumed by applications via `kyte get`, versioned in their own
repositories. The database *seam* (the `Connection`/`Driver` traits and the generic pool) stays in the
standard library so that drivers are interchangeable.

## Relationship to the standard library

The standard library (`src/std/`) ships with the compiler and is imported without a `kyte get` step:
`import json`, `import http`, `import list`, and so on. Everything else -- drivers, frameworks,
domain libraries -- is a package. The dividing line is deliberate: the stdlib is the language's own
batteries; packages are the community's.
