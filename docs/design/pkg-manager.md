# Nova package manager — locked design (2026-08-16)

The deliberately-small package manager for Nova. It is Zig-flavoured (exact ref pins, git as the source of
truth, no registry) rather than Go-modules-flavoured (no semver ranges, no MVS). Reproducibility rests on
git commit SHAs — git is content-addressed, so a recorded SHA is both the version lock and the integrity
check; there is no separate hash scheme.

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
- Dependencies are **strings** with an optional `#ref` suffix — backward-compatible, no schema change.
- `repository` is optional; a leaf app omits it. `nova publish` requires it.

## 2. Lockfile — `project.lock.json`
```jsonc
{
  "lockfileVersion": 1,
  "dependencies": [
    { "url": "https://github.com/u/dep", "ref": "v1.0.0", "resolved": "<40-char commit SHA>" }
  ]
}
```
- `resolved` = the exact commit the ref pointed to at first fetch. For an unpinned dep (no `#ref`),
  `resolved` is `null` and the dep is honestly unversioned.
- The lock is **flat** and holds the WHOLE tree — direct AND transitive deps — so the entire graph is
  reproducible, not just the top level. Keyed by `url`.
- Committed to source control by the app author (like `package-lock.json` / `go.sum`).

## 3. Resolution rule (builds never move the lock)
For each dependency, the fetch target is chosen by this precedence:
1. **`resolved` SHA from the lockfile, if present** → check that out. Immune to a moved tag or a new
   default-branch push. **`nova build` / `nova test` always honor the lock and never rewrite it.**
2. else the **`#ref`** from `project.json` → resolve to a SHA and **write it to the lock**.
3. else the **default branch** → `resolved: null` (unversioned).

Only the explicit commands `nova get` and `nova update` are allowed to MOVE a locked SHA.

## 4. Fetch + cache
- Cache root: `~/.nova/cache/<repo-name>` (one directory per package name — see §6).
- A pinned target (locked SHA or `#ref`) requires history, so: `git clone <url> <dir>` then
  `git -C <dir> checkout <target>`. An unpinned dep uses `git clone --depth 1`.
- The resolved SHA is read from `<dir>/.git/HEAD` (a tag/SHA checkout leaves HEAD detached, so the file is
  the raw 40-char SHA; a branch HEAD is followed one level through the loose ref then `packed-refs`). No
  subprocess-output capture needed.

## 5. Transitive resolution (recursive, cache-deduped)
After fetching a package, read **its** `project.json` and, for each of its dependencies, resolve the same
way and fetch it **if it is not already in the cache**. The name-keyed cache is the visited-set, so:
- a package needed by several others is fetched once (dedup is free);
- cycles terminate (A→B→A stops when A is already cached);
- it is a simple worklist — no version solving.

The recursion trusts each fetched package's declared dependency list. That is the point where a malicious
package could pull in arbitrary repos; defending against that (allow-lists, vendoring, review) is a KNOWN,
RECORDED out-of-scope limitation, not a surprise.

## 6. The one-version-per-name rule (a consequence, not a shortcut)
Nova imports are **by name** (`import datastar;`) and resolve to the single directory
`~/.nova/cache/<name>`. Two versions of the same package therefore **cannot coexist** — this is inherent to
name-based imports, not a corner cut. So transitive resolution is necessarily:

> **First-fetched-wins, one version per package name, globally.** If A needs `X#v1` and B needs `X#v2`,
> whichever is fetched first wins and the other silently gets that version.

To keep this honest rather than silent, the fetcher **warns** when a dependency requests a package that is
already cached at a different resolved SHA:
`[deps] warning: B requests X#v2 but X is already at v1 (<sha>); using the cached version.`

Allowing two coexisting majors would require `name@version` cache dirs AND version-aware import resolution
— i.e. the MVS / Go-modules machinery this design explicitly rejects. One-version-per-name is the correct
match for the current import model.

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
- No transitive VERSION resolution / MVS / semver ranges (exact pin only; one-version-per-name, §6).
- No registry, no module proxy, no checksum transparency log.
- No content-hash scheme (git SHAs are the integrity mechanism).
- No supply-chain defence on the recursive fetch (§5).

## 10. Acceptance (prove before calling it done)
A local multi-repo test, no network:
1. Repos A→B→C with tagged releases; `nova get A#v1` fetches all three, lock records three resolved SHAs.
2. Move a tag; `nova build` still checks out the LOCKED SHA (reproducible); the lock is unchanged.
3. `nova update` moves it; the lock changes.
4. Conflict: A needs `X#v1`, B needs `X#v2` → first wins + the warning fires.
5. `nova publish` on a library creates `v<version>` and pushes to origin; refuses on a re-publish.
