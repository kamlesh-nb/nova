# Video 24: Artifact delivery, the blob store

- Chapter: [24-blob-store.md](../24-blob-store.md)
- Estimated length: ~10 minutes
- You will need: Nova installed and the guide's `packages/nova-orchestrator` handy. Watching Video 23 on the orchestrator first is essential, since this is how its manifests get their binaries.

## Hook (0:00)

**Say:** In the last video the manifest pointed at a binary already sitting on disk. That is fine on one machine. The moment you have several nodes, you need a way to get the exact same binary to each of them, and to be certain each node runs the binary you built and not something altered on the way. The orchestrator ships a small artifact origin for exactly this: artifactd, a content-addressed blob server, plus the client glue each node uses to pull a binary by hash. This is the final piece of the deploy path.

## What we will cover (0:30)

**On screen:**
```
- Content addressing: a binary is named by its own SHA-256
- The store: a sharded content-addressed store
- artifactd: PUT and GET over HTTP, Bearer auth
- Four safety properties: no bad bytes ever run
- The client: resolve, pull, verify, cache, run
```

## Segment: Why content addressing (1:00)

**Say:** A content-addressed store keys each blob by the SHA-256 hash of its own bytes. The name of a binary is the hash of the binary. That one idea buys three things.

**On screen:**
```
Integrity        wrong bytes cannot hash to the name you asked for
Deduplication    same binary, same name: upload twice is a no-op
Immutable target  artifact "sha256:abcd..." is one exact binary, forever
```

**Say:** There is no latest that quietly changes underneath you. A digest names one binary for all time.

## Segment: The store (2:30)

**Say:** BlobStore is the store. A blob's key is its 64-character hex digest, and that is also its file name. On disk it uses a two-level fan-out so one directory never fills up with thousands of entries.

**On screen:**
```
<root>/<first2>/<next2>/<sha>
put(sha, data)   verify then write
get(sha)         read, re-hash, return only if it matches
has(sha)         validSha then exists
```

**Say:** Blob bodies are ordinary Nova strings, which are length-prefixed and binary-safe, so a native binary round-trips through the file API with no text encoding in the way. On top of the raw store there is a naming layer, Registry, that maps app and version to a digest, so you can say shop version 1.4.0 is this digest, and later promote it to current.

## Segment: artifactd over HTTP (4:00)

**Say:** artifactd is the daemon that serves the store over HTTP. It reads its environment and serves content-addressed routes.

**On screen:**
```sh
artifactd
# NOVA_ARTIFACT_ROOT   blobs + apps root   (default ./artifacts-store)
# NOVA_ARTIFACT_TOKEN  deploy token        (empty = auth OFF, dev only)
# NOVA_PORT            listen port         (default 8135)

PUT /artifacts/{sha}          201 stored, 200 present, 409 body != sha, 413 too big
GET /artifacts/{sha}          the bytes, verified on read, 404 if absent
GET /artifacts/{sha}/exists   200 or 404
```

**Say:** The upload cap is 512 mebibytes, and it is a real limit, not a formality: the store holds a whole blob in memory during a write, so an unbounded body would be a trivial out-of-memory. The flow it is built for is: CI uploads a freshly built binary keyed by its hash, and each node later pulls it by hash before spawning a replica.

## Segment: Bearer auth (5:30)

**Say:** Every route is wrapped by a middleware, DeployAuth, installed with app.use. The token comes from the environment. If it is empty, auth is off and the daemon says so on startup, which is a development convenience only. With a token set, each request must carry Authorization Bearer token or it is rejected with 401. The comparison is constant-time, so it does not leak how many leading characters of a guess were right through its timing.

## Segment: The four safety properties (6:30)

**Say:** The store is written so a bad or hostile input cannot produce a runnable file. Four properties do the work.

**On screen:**
```
Verify before publish  put refuses bytes that do not hash to the given name
Atomic rename          write to a temp file, rename only on success; no half-blobs
Verify on read         get re-hashes on the way out; even bit-rot is caught
Path-traversal guard    validSha accepts only 64 hex chars: ../etc/passwd is impossible
```

**Say:** Together these give you the property that matters: a binary you fetch is the binary you built, checked on the way in and on the way out.

## Segment: The client side (8:00)

**Say:** On the consuming side, one small module turns an artifact reference into a local file orchd can execute. resolveBinary looks in the local cache: if the digest is there, it returns the path; if not, it returns a NotCached signal. That is the caller's cue to GET the blob from artifactd and then cacheArtifact the bytes, which verifies the hash and writes atomically, so a tampered download can never become a runnable file.

**On screen:**
```
spec.artifact = "sha256:abcd..."     on a workload
1. resolveBinary(cache)  -> NotCached
2. GET /artifacts/abcd... from artifactd
3. cacheArtifact         -> verifies hash, writes atomically
4. spawn the replica from the cached, verified path
```

**Say:** When spec.artifact is empty, the workload runs in the legacy local-path mode from the last video. When it is set, every node fetches and verifies exactly those bytes. The binary is named once, by digest.

## Segment: Current status, honestly (9:15)

**Say:** Be clear-eyed about what this is. The blob store is a stopgap that lives inside the orchestrator repository. It is deliberately simple: whole blob in memory during a write, plain HTTP with a bearer token that you would put behind TLS termination in production. A natural future direction is to move the bytes to an object store like MinIO or S3 behind the same PUT and GET interface, so the integrity contract stays identical while storage scales. But be honest that this is a direction, not a shipped feature: there is no such backend in the code today. The in-repo store is what runs.

## Recap and outro (10:00)

**Say:** That closes the deploy path, and the series. A binary is named by its own hash, artifactd serves it over a verified PUT and GET, four safety properties mean bad bytes never run, and each node pulls, verifies, caches, and spawns. You have now gone from your first console.log all the way to a NovaDB-backed web app, deployed behind a load balancer, with its binaries delivered by content address. One language, one toolchain, one storage engine, end to end. Now go and build something.
