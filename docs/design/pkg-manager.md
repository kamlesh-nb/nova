# Nova package manager — locked design (2026-08-16)

The deliberately-small package manager for Nova. It is **Cargo-flavoured** in identity (clean by-NAME
imports; the name comes from each package's own manifest; multiple versions may coexist) and
**Zig-flavoured** in resolution (exact git-ref pins, git as the source of truth, no registry, no semver
ranges, no MVS). Reproducibility rests on git commit SHAs — git is content-addressed, so a recorded SHA is
both the version lock and the integrity check; there is no separate hash scheme.

Why this is feasible cheaply: Nova's symbol mangling is **path-derived** (`getModulePrefix` builds the
mangle prefix from the source file's path). So two versions of a package that live at different cache
paths (`X-<sha1>/…` vs `X-<sha2>/…`) mangle to distinct symbols automatically — multi-version coexistence
needs no codegen change.

This document is the CONTRACT. It was locked with the user before implementation; do not add scope
(registry, proxy, MVS, checksum-DB, version ranges) without re-opening it.

## 1. Manifest — `project.json`
```jsonc
{
  "name": "my-lib",
  "version": "1.2.3",
  "type": "library",                               // gates `nova publish`
  "repository": "https://github.com/u/my-lib",     // canonical git URL (optional; required by publish)
  "dependencies": [
    "https://github.com/u/dep#v1.0.0"              // "url#ref"; ref = tag/branch/commit; no "#ref" = default branch
  ]
}
```
- Dependencies are **strings** with an optional `#ref` suffix. The URL says WHERE to fetch and (via
  `#ref`) WHICH version. It does NOT determine the package's name.
- **A dependency's import NAME comes from that dependency's own `project.json` `name` field**, not from the
  URL/repo name (Cargo-style: the crate name lives in the crate's manifest). So the repo can be called
  anything; `import <name>` uses the declared `name`. This name is also the cache identity (§4).
- `repository` is optional; a leaf app omits it. `nova publish` requires it.

## 2. Lockfile — `project.lock.json`
```jsonc
{
  "lockfileVersion": 1,
  "dependencies": [
    { "url": "https://github.com/u/dep", "ref": "v1.0.0", "resolved": "<40-char SHA>", "name": "dep" }
  ]
}
```
- `resolved` = the exact commit the ref pointed to at first fetch. For an unpinned dep (no `#ref`),
  `resolved` is `null` and the dep is honestly unversioned.
- `name` = the dependency's declared package name (read from its own `project.json` after fetch). It fixes
  the cache dir (`<name>-<sha>`) and the import identity without re-reading the fetched manifest.
- The lock is **flat** and holds the WHOLE tree — direct AND transitive deps — so the entire graph is
  reproducible, not just the top level. Keyed by `url`.
- Committed to source control by the app author (like `Cargo.lock` / `package-lock.json`).

## 3. Resolution rule (builds never move the lock)
For each dependency, the fetch target is chosen by this precedence:
1. **`resolved` SHA from the lockfile, if present** → check that out. Immune to a moved tag or a new
   default-branch push. **`nova build` / `nova test` always honor the lock and never rewrite it.**
2. else the **`#ref`** from `project.json` → resolve to a SHA and **write it to the lock**.
3. else the **default branch** → `resolved: null` (unversioned).

Only the explicit commands `nova get` and `nova update` are allowed to MOVE a locked SHA.

## 4. Fetch + cache
- Cache dir: `~/.nova/cache/<name>-<sha8>`, where `<name>` is the dependency's DECLARED name (from its
  `project.json`) and `<sha8>` is the first 8 chars of the resolved commit. Different versions of the same
  package therefore live in different dirs and coexist. (Separator is `-`, not `@`, to keep the path an
  identifier-safe mangle prefix.) An unpinned dep with no resolvable SHA falls back to `<name>-branch`.
- Fetch: a pinned target (locked SHA or `#ref`) requires history, so `git clone <url> <tmp>` then
  `git -C <tmp> checkout <target>`; an unpinned dep uses `git clone --depth 1`. AFTER checkout, read the
  fetched `<tmp>/project.json` `name` and the resolved SHA, then move `<tmp>` to `~/.nova/cache/<name>-<sha8>`
  (or reuse it if that dir already exists = cache hit).
- The resolved SHA is read from `<tmp>/.git/HEAD` (a tag/SHA checkout leaves HEAD detached, so the file is
  the raw 40-char SHA; a branch HEAD is followed one level through the loose ref then `packed-refs`). No
  subprocess-output capture needed.

## 5. Transitive resolution (recursive, cache-deduped)
After fetching a package, read **its** `project.json` and, for each of its dependencies, resolve the same
way and fetch it **if that exact `<name>-<sha8>` is not already in the cache**. The version-keyed cache is
the visited-set, so:
- the same package at the same version, needed by several packages, is fetched once (dedup is free);
- the same package at DIFFERENT versions coexists (each is its own cache dir — see §6);
- cycles terminate (A→B→A stops when A-<sha> is already cached);
- it is a simple worklist — no version solving / MVS.

The recursion trusts each fetched package's declared dependency list. That is the point where a malicious
package could pull in arbitrary repos; defending against that (allow-lists, vendoring, review) is a KNOWN,
RECORDED out-of-scope limitation, not a surprise.

## 6. Version-aware import resolution (Cargo-style; versions coexist)
Imports stay clean and by-NAME (`import datastar;`). The name→version binding is resolved **per owning
package**, from that package's own manifest + lock — NOT globally. So:

- When resolving `import X` inside a source file, find the file's **owning package** = the nearest
  `project.json` up the directory tree from that file. Look up `X` among that package's dependencies →
  its locked `resolved` SHA → the cache dir `~/.nova/cache/X-<sha8>`.
- A dependency's files live under `~/.nova/cache/A-<shaA>/…`; when A itself does `import X`, the owning
  package is A, so it resolves against A's manifest — which may pin a DIFFERENT version of X than the app
  does. Both `X-<sha1>` and `X-<sha2>` sit in the cache and are imported by whoever pinned them.
- Because the cache path carries the version and mangling is path-derived (see the header note), the two
  X versions produce distinct symbols; no collision, no first-wins, no conflict warning. If code tries to
  pass `X-<sha1>.Foo` where `X-<sha2>.Foo` is expected, that is a legitimate TYPE ERROR (they are
  different types) — same as Cargo.

**Name-collision guard.** Two DIFFERENT urls that declare the SAME package `name` at the SAME version-slot
within one resolution scope is an identity clash the design cannot silently arbitrate (there is no registry
to make names unique). This is a hard ERROR with both urls named. (Different names, or the same url at
different refs, are fine.)

## 7. Commands
| Command | Contract |
|---|---|
| `nova get <url[#ref]>` | add the dep to `project.json`, resolve ref→SHA, fetch (+ transitive), write the lock. |
| `nova restore` | fetch every dep (direct + transitive) at its **locked SHA**; no re-resolution. Fails loudly on a missing lock entry only if the ref is also absent. |
| `nova update [dep]` | the ONLY command that moves a locked SHA to the ref's current tip. With no arg, updates all pinned deps; with a dep, just that one. Rewrites the lock. |
| `nova publish` | tag the current version and push it (see §8). |

Auto-fetch: `nova build` / `nova test` call the same resolver (honoring the lock, §3) before compiling, so
`git clone <app> && nova build` just works.

## 8. `nova publish`
1. Require `type == "library"` AND `repository` set → else a clear error.
2. Tag name = `v<version>` from `project.json`. Validate `version` looks like semver (`X.Y.Z`); warn if not.
3. **Refuse if the tag already exists** (locally or on the remote) — never clobber a released version.
4. **Warn, do not block, if the working tree is dirty** — uncommitted changes are not in the tag.
5. Create an **annotated** tag at HEAD: `git tag -a v<version> -m "v<version>"`.
6. Push to `origin`: `git push origin v<version>`.
7. Print the consume line: `nova get <repository>#v<version>`.

Publish only TAGS whatever `version` says — no version bump, no commit. (There is deliberately no `release`
command; bumping `version` is the author's own edit + commit before publishing.)

## 9. Explicit non-goals
- No version SOLVING: no MVS, no semver ranges, no unification of compatible versions. Each package uses
  the EXACT ref it pins; identical pins share a cache entry, different pins coexist (§6). (Cargo unifies
  compatible semver versions; we deliberately do not — exact pin only.)
- No registry, no module proxy, no checksum transparency log.
- No content-hash scheme (git SHAs are the integrity mechanism).
- No supply-chain defence on the recursive fetch (§5).

## 10. Acceptance (prove before calling it done)
A local multi-repo test, no network:
1. Repos A→B→C with tagged releases; `nova get A#v1` fetches all three; lock records three entries with
   resolved SHAs AND names taken from each repo's own `project.json` (not the repo name).
2. Move a tag; `nova build` still checks out the LOCKED SHA (reproducible); the lock is unchanged.
3. `nova update` moves it; the lock changes.
4. Multi-version: app pins `X#v1`, dependency B pins `X#v2` → BOTH `X-<sha1>` and `X-<sha2>` cached; the
   app's `import X` resolves to v1, B's `import X` resolves to v2; both compile (distinct symbols).
5. Name collision: two different urls both declare name `X` in one scope → hard error naming both urls.
6. `nova publish` on a library creates `v<version>` and pushes to origin; refuses on a re-publish.
