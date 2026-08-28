# 24. Artifact delivery: the blob store

Chapter 23 deployed a web app by pointing the manifest at a binary on disk (`workload.binary:
./build/release/bin/webapp`). That works when the binary already sits on every node. Once you have more
than one node, you need a way to get the exact same binary to each of them, and to be sure each node runs
the binary you built and not something that was altered on the way. The orchestrator ships a small
artifact origin for this: `artifactd`, a content-addressed blob server, plus the client-side glue that
each orchd node uses to pull a binary by hash before it spawns a replica.

Everything here lives in `packages/nova-orchestrator`, in `src/artifacts/` (the store) and
`src/orch/artifact.nova` (the client). It is a stopgap that lives inside the orchestrator repository; see
"Current status and future direction" at the end for exactly what that means.

## Why content-addressed delivery

A content-addressed store keys each blob by the SHA-256 hash of its own bytes. The name of a binary is
the hash of the binary. That single idea buys three things:

- **Integrity.** If you ask for `sha256:abcd...` and the bytes you get back do not hash to `abcd...`,
  they are the wrong bytes, full stop. Corruption in transit or on disk is detectable by construction,
  not by a separate checksum you have to remember to compare.
- **Deduplication and idempotency.** The same binary always has the same name, so uploading it twice is a
  no-op and every node that has already cached it can skip the download.
- **An immutable deploy target.** A manifest that references `artifact: "sha256:abcd..."` names one exact
  binary for all time. There is no "latest" that quietly changes underneath you.

## The store: a content-addressed store (CAS)

`BlobStore` (in `src/artifacts/blobstore.nova`) is the store. It has a single field, `root`, the
directory the blobs live in. A blob's key is its SHA-256 hex digest (64 lowercase hex characters), and
that is also its file name. On disk it uses a two-level fan-out shard so a single directory never fills up
with thousands of entries:

```
<root>/<first2>/<next2>/<sha>
```

So a blob with digest `ab12cd...` lands at `<root>/ab/12/ab12cd...`. The core methods are:

- `localPath(sha)` returns the sharded path for a digest.
- `validSha(sha)` returns true only when `sha` is exactly 64 lowercase hex characters.
- `has(sha)` checks `validSha` then whether the file exists.
- `get(sha)` reads the bytes back, re-hashes them, and returns them only if the hash matches; it returns
  `undefined` if the blob is absent or the on-disk bytes do not hash to their own name.
- `put(sha, data)` is the security-critical write; it is described under "Safety properties" below.

Blob bodies are ordinary Nova `string`s, which are length-prefixed and binary-safe, so a native binary
round-trips through the file API without any text encoding getting in the way. The digest is computed with
`sha.sha256` from the standard library.

On top of the raw store there is a naming layer, `Registry` (in `src/artifacts/registry.nova`), which maps
a human name and version to a digest. It keeps pointer files under `<root>/apps/<app>/<version>` (each
containing a `"sha256:<hex>"` line) and an `<root>/apps/<app>/current` pointer, with methods like `bind`,
`resolve`, `binary`, `promote`, `current`, and `versions`. The registry is how you say "app `shop`
version `1.4.0` is this digest" and later "promote `1.4.0` to current".

## The HTTP interface: artifactd

`artifactd` (in `bin/artifactd.nova`) is the daemon that serves the store over HTTP. On startup it reads
its environment, builds a `BlobStore` rooted at `<root>/blobs` and a `Registry` rooted at `<root>/apps`,
and serves:

```sh
artifactd
# NOVA_ARTIFACT_ROOT   blobs + apps root       (default ./artifacts-store)
# NOVA_ARTIFACT_TOKEN  the deploy token        (empty = auth OFF, dev only)
# NOVA_PORT            listen port             (default 8135)
```

Note the on-disk directory is `blobs/` but the HTTP route prefix is `artifacts/`. The content-addressed
routes are:

| Method and path             | Meaning                                                              |
|-----------------------------|---------------------------------------------------------------------|
| `GET  /artifacts/{sha}/exists` | 200 if the blob is present, 404 if absent.                       |
| `PUT  /artifacts/{sha}`     | Upload. 201 stored, 200 already present, 400 malformed sha, 409 if the body does not hash to `{sha}`, 413 if the body exceeds the cap. |
| `GET  /artifacts/{sha}`     | Download the bytes (octet-stream), 404 if absent. Verified on read. |

There is also the namespace layer served under `/apps/...` (`PUT /apps/{app}/{version}` to bind a
version, `GET /apps/{app}/{version}/digest`, `GET /apps/{app}/{version}`, `GET /apps/{app}` to list
versions, and `POST /apps/{app}/promote`).

The upload cap is 512 MiB, and an over-size body is rejected with 413. This is a real limit, not a
formality: the store holds a whole blob in memory during a write, so an unbounded body would be a trivial
out-of-memory. Raising it goes hand in hand with adding streaming I/O.

The end-to-end flow the daemon is built for: CI uploads a freshly built native binary keyed by its
SHA-256 (idempotent and verified), and each orchd node later pulls it by hash into a local cache before
spawning a replica.

## Bearer auth

Every route is wrapped by `DeployAuth`, a route middleware installed with `app.use(DeployAuth(token))`.
The token comes from `NOVA_ARTIFACT_TOKEN`. If it is empty, auth is disabled and the daemon logs
`auth=OFF (dev)` on startup, which is a development convenience only. When a token is set, each request
must carry `Authorization: Bearer <token>` or it is rejected with 401.

The comparison is constant-time. `ctEqual` XOR-accumulates over the whole string with no early exit, so it
does not leak how many leading characters of a guessed token were correct through its timing.

## Safety properties

The store is written so that a bad or hostile input cannot produce a runnable file. Four properties do the
work, and they are worth stating precisely because the whole design leans on them.

**Verify before publish.** `put(sha, data)` refuses to store anything whose bytes do not hash to the name
it was given. Before it writes, it checks `validSha(sha)` and then that `sha256(data) == sha`. A mismatch
returns false and nothing is written. So the store only ever contains blobs that hash to their own name.

**Atomic rename.** The write goes to a unique temporary file first (the name carries a random hex suffix,
so two writers on a shared mount cannot collide), and only a successful `rename` publishes it to the final
path. A reader therefore never sees a half-written blob: it sees either no file or the complete, verified
one. If the rename fails, the temp file is removed.

**Verify on read.** `get(sha)` does not trust the disk. It reads the bytes back and re-hashes them,
returning `undefined` on a mismatch. So even bit-rot on the storage medium is caught at read time rather
than handed to a caller as a good binary. (An earlier internal note claimed the store did not verify on
read; the code does, in `BlobStore.get`.)

**Path-traversal guard.** Every path is built from a validated digest. `validSha` accepts only exactly 64
lowercase hex characters, so a name like `../etc/passwd` can never be turned into a path in the first
place. `has`, `get`, and `put` all gate on `validSha`, and the HTTP `PUT` handler re-verifies that the raw
body hashes to the `{sha}` in the URL before publishing, returning 409 on a mismatch.

## The client side: pulling a binary into a deploy

On the consuming side, `src/orch/artifact.nova` is the glue orchd uses to turn an artifact reference into
a local file it can execute. It carries a small error type, `ArtifactError`, with `NotCached(sha)` and
`Corrupt(sha)` cases, and three functions:

- `shaOf(artifact)` strips a leading `"sha256:"` and returns the bare hex; a plain hex string passes
  through unchanged.
- `resolveBinary(artifact, binaryPath, cache)` is the lookup. If `artifact` is empty it returns
  `binaryPath` verbatim, which is the legacy local-path mode from Chapter 23. Otherwise it takes the
  digest, and if the cache already `has` it, returns its local path; if not, it returns
  `ArtifactError.NotCached(sha)`. That error is the signal for the caller to pull the blob over HTTP and
  retry.
- `cacheArtifact(cache, sha, data)` stores freshly downloaded bytes. It calls `cache.put(sha, data)`, and
  because `put` rejects any bytes that do not hash to `sha`, a tampered or corrupted download can never
  become a runnable file. On rejection it returns `ArtifactError.Corrupt(sha)`; on success it returns the
  cached local path.

The actual HTTP fetch (a `web.client` GET to `/artifacts/<sha>`) and setting the executable bit on the
cached file are left to the caller's integration step. Keeping the network out of `artifact.nova` is what
lets the verify-and-cache logic be unit-tested without a running server.

The manifest ties into this through `spec.artifact` (in `src/orch/spec.nova`), a `"sha256:<hex>"` string
on a workload. When it is set, orchd pulls the binary by hash into its blob cache and points the
workload's `binaryPath` at the cached file before spawning replicas. When it is empty, the workload runs
in the legacy local-path mode. So a fully hash-addressed deployment names its binary once, by digest, and
every node fetches and verifies exactly those bytes.

The typical sequence for one node:

1. read `spec.artifact` from the desired state (`"sha256:abcd..."`),
2. `resolveBinary` against the local cache; on `NotCached`, GET `/artifacts/abcd...` from `artifactd`,
3. `cacheArtifact` the downloaded bytes, which verifies the hash and writes atomically,
4. spawn the replica from the cached, verified path.

## Current status and future direction

Be clear-eyed about what this is. The blob store is a **stopgap content-addressed store that lives inside
the orchestrator repository**. It is deliberately simple: it holds a whole blob in memory during a write
(hence the 512 MiB cap and the note that raising it needs streaming I/O), and `artifactd` serves plain
HTTP with a bearer token, so you would put it behind TLS termination in a real deployment. What it does
give you today is the property that matters most for a deploy path: a binary you fetch is the binary you
built, verified on write and on read, and a bad download can never be run.

A natural future direction is to move the bytes to a dedicated object store such as MinIO or S3, sitting
behind the same content-addressed `PUT /artifacts/{sha}` and `GET /artifacts/{sha}` interface, so the
integrity contract stays identical while the storage scales. That is an aspirational design direction, not
a shipped feature: there is no MinIO or S3 backend anywhere in the repository today, and nothing in the
code selects one. Do not reach for it expecting it to exist; the in-repo `BlobStore` is what runs.

## Where to go next

- Chapter 23 for the orchestrator that consumes these artifacts: the manifest, the reconcile loop, and
  `spec.artifact` wired into a deploy.
- Chapter 22 for building and cross-compiling the binaries you upload here.
- The standard library's `sha.sha256`, the digest function the store is built on.
