# 25. NovaDB: the database itself

The earlier chapters met NovaDB from the outside, as a connection string and a driver. Chapter 18 pointed
a web app at it and Chapter 20 listed it alongside the SQL and MongoDB drivers. This chapter turns the
thing over and looks at NovaDB on its own terms: what it is, what it is built out of, how to run and
configure the server, and, just as importantly, what it is not meant to be.

NovaDB is a **separate project** from the Nova language. It has its own repository, its own build, and its
own version. Nova talks to it only over the binary wire protocol, through the `nova-novadb` driver you saw
in Chapter 20. You can build and run NovaDB without Nova, and you version the two independently. Everything
in this chapter is about the database server itself, not the driver.

## What NovaDB is

NovaDB is an **embedded B+Tree storage engine** with a SQL surface and a document (NoSQL) surface, written
in Zig. Despite the word "embedded" in its lineage, you deploy it as its own service: it listens on a TCP
port and speaks a binary wire protocol, and clients connect over that. A single native binary carries the
whole engine, so there is nothing else to install alongside it.

Its intended, supported role is a **small embedded database for a Nova application**: bounded,
low-churn data such as an app's own tables and documents, configuration, and local development where a
single self-contained binary is a pleasure to work with. In that role it is solid and verified, with a
SQL and a document surface both exercised by soundness batteries, and it recovers correctly across a
restart.

(Earlier revisions of this guide cast NovaDB as the Nova orchestrator's config store. That is no longer
the case: the orchestrator now keeps its tiny control-plane state in `artifactd`, its blob service, and
does not run a database at all. See Chapter 23. NovaDB stands on its own as an application database.)

## What NovaDB is not

It is worth being just as clear about the boundary. NovaDB is **not a general-purpose OLTP or document
database at scale**, and it is not trying to be. A benchmark of ten million rows made the limits concrete:
the on-disk footprint is larger than the logical data, the buffer pool and scan paths are not I/O-efficient
once the working set grows past the pool, index builds re-scan per index, and for some shapes the planner
scans where a larger engine would seek. Those are the honest gaps of an engine designed for small,
in-memory-friendly data, and closing them is a large systems project rather than a patch.

So the guidance is simple. Use NovaDB where its shape fits: an application's own bounded tables and
documents, configuration, small datasets, and local development where a single self-contained binary is a
pleasure to work with.
For a large transactional or analytical workload, reach for one of the other drivers in Chapter 20
(PostgreSQL, MySQL, SQL Server) instead, over the very same `Connection` seam.

## How it is built

A handful of classic storage-engine pieces sit behind the wire protocol.

- **Slotted-page B+Tree.** Records are variable-length cells packed into fixed-size pages. Each page grows
  in two directions at once: a slot directory grows down from the top while the cell payloads grow up from
  the bottom, and they meet in the middle. Values too large for a page spill into overflow pages. The tree
  gives O(log n) lookups, inserts, and range scans. This is the core of the engine.
- **Segmented buffer pool and pager.** A page cache sits over the data file, with checkpointing to bound
  how much has to be replayed after a crash. The pool size is the main memory knob you tune (see the config
  below).
- **MVCC with an undo log.** Multi-version concurrency control gives readers a consistent view without
  blocking writers, and the undo log lets a transaction roll back.
- **Write-ahead log and checkpoints.** Durability rides on a WAL: a change is logged before it is applied,
  so a crash can be recovered by replaying the log up to the last checkpoint.
- **SQL layer.** A parser, a query executor, and a schema catalog turn SQL text into work against the tree.
- **Document layer.** A BSON-backed document store with a Mongo-style filter and find surface, secondary
  indexes, and the same MVCC and durability underneath.
- **Binary wire protocol.** Sessions, a message-buffer pool, an object-id map, and typed decoding. This is
  the path the `nova-novadb` driver speaks.

On concurrency, the old database-wide write lock is gone. A db-wide lock now only gates schema changes
(DDL) and cross-table statements. Each user table has its own access lock: a SELECT takes it in read mode
so readers run concurrently, an INSERT takes it in write mode so writers run concurrently, and an
UPDATE or DELETE takes it exclusively because it scans. Concurrent writers on one tree are kept safe by a
per-tree structure lock, held shared for in-place changes and exclusively for a page split or merge.

## One data model per instance

A NovaDB instance serves **one surface, not both at once**. It is either relational (SQL) or document
(NoSQL), chosen by the `mode` setting, and it defaults to relational. The reason is the connection
contract: an app opens a single connection with a single contract, and a mixed instance would force every
app to hold two connections, one SQL and one NoSQL, to reach one server. Keeping a server to one model
keeps that contract clean.

The rule is enforced, not just documented. A relational instance rejects document requests, and a document
instance rejects the SQL query, parse, bind, describe, and execute frames as well as the HTTP `/query`
endpoint. If you need both models, run two instances.

## Running the server

NovaDB builds with the bundled Zig toolchain and produces two executables: `novadb`, the server, and
`novadb-cli`, the command-line client.

```sh
# from the NovaDB repository
zig build                 # builds novadb + novadb-cli
zig build run             # or run ./zig-out/bin/novadb directly
zig build test            # the unit-test suite
```

By default the server binds `127.0.0.1:3009` and keeps its data under a `data` directory next to the
process. With no config file at all it boots on those defaults, which makes a fresh checkout runnable
straight away.

## Configuration: db.json

The server reads a single `db.json` at startup, and that file IS the schema. The config struct is
deserialised directly from the JSON, so the field names below are exactly the keys the file accepts, and
the defaults shown are the shipped defaults. Two design choices are worth knowing before you edit it:

- **All-defaults if absent.** A missing `db.json` is treated as an empty object, so the server starts on
  defaults with no file present.
- **Fail closed, fail loud.** Parsing is strict. A stray or mistyped key, a wrong value type, or malformed
  JSON aborts startup with a specific reason rather than being silently ignored, so a typo can never
  quietly drop a setting. After a good parse, a validation pass rejects a config that would parse but leave
  the server unable to run (an empty bind address, a zero port, a zero `max_sessions` or `pool_size`, an
  empty `base_dir`, or replication enabled without a peer port).

A representative file, with every top-level key shown at its default:

```json
{
  "mode": "relational",
  "address": "127.0.0.1",
  "port": 3009,
  "primary": true,
  "max_sessions": 100,
  "base_dir": "data",
  "durability": {
    "enabled": true,
    "synchronous_commit": false
  },
  "pool_size": 10000,
  "query_memory_limit_bytes": 536870912,
  "mmap_reads": false,
  "tls": {
    "enabled": false,
    "cert_file": "",
    "key_file": ""
  },
  "security": {
    "enabled": false
  },
  "replica": {
    "enabled": false,
    "sync_interval_ms": 1000,
    "address": "127.0.0.1",
    "port": 3010,
    "uid": "",
    "key": ""
  }
}
```

What each key does:

| Key | Default | Meaning |
|-----|---------|---------|
| `mode` | `relational` | The single data model this instance serves, `relational` or `document`. |
| `address` | `127.0.0.1` | Interface the server binds and listens on. |
| `port` | `3009` | TCP port for the binary wire protocol. Must be non-zero. |
| `primary` | `true` | Whether this node starts as the writable replication primary. A follower sets it false. |
| `max_sessions` | `100` | Hard cap on concurrent client sessions. Must be greater than zero. |
| `base_dir` | `data` | Directory holding the database files. Relative paths resolve against the working directory. Must not be empty. |
| `durability.enabled` | `true` | Master switch for WAL-backed durability. |
| `durability.synchronous_commit` | `false` | When true, a commit waits for its WAL record to be fsynced, so a crash cannot lose an acknowledged transaction. When false, a commit returns once the record is buffered and a background flusher pushes it to disk, which is faster but can lose the very last commits on a crash. |
| `pool_size` | `10000` | Buffer pool size in pages. The main memory knob. Must be non-zero. |
| `query_memory_limit_bytes` | `536870912` (512 MiB) | Cap on the memory a single query may allocate while it runs. A query that would exceed it fails with "Query Memory Limit Exceeded" rather than growing the process until the OS kills the server. Set to 0 to disable the cap. |
| `mmap_reads` | `false` | Serve clean page reads borrowed from a read-only mmap of the data file instead of copying them. This is not a query speed-up over a well-sized pool and not a steady-state memory saving; its one benefit is that the residency is reclaimable file cache the OS can drop under pressure. POSIX only, ignored on Windows. |
| `tls.enabled` | `false` | Require TLS for client connections. When true, both `cert_file` and `key_file` must be set. |
| `tls.cert_file` / `tls.key_file` | `""` | PEM certificate and private-key paths. |
| `security.enabled` | `false` | Master switch for the security features. |
| `replica.enabled` | `false` | Whether replication is active on this node. When true, a non-zero `replica.port` is required. |
| `replica.sync_interval_ms` | `1000` | How often a follower syncs from the primary, in milliseconds. |
| `replica.address` / `replica.port` | `127.0.0.1` / `3010` | The replication peer to dial (the primary, for a follower). |
| `replica.uid` / `replica.key` | `""` | Identity and shared secret used to authenticate the replication link. |

## Durability and recovery

With durability enabled, every change is written to the WAL before it touches a page, and checkpoints keep
the log bounded so recovery does not have to replay from the beginning of time. On restart the server
replays the WAL, restores the set of committed transactions that was persisted at the last checkpoint, and
brings each collection's B+Tree root back to a reachable state (a root is persisted when a page splits, so
a collection is fully reachable again after a restart). The net effect is that NovaDB comes back correctly
after a crash or a kill, which is exactly the property an application store depends on.

The one dial you trade off here is `durability.synchronous_commit`. Leave it false for lower commit latency
and accept that a hard crash can lose the last few commits that were buffered but not yet flushed. Set it
true when an acknowledged commit must survive a crash, and accept the fsync on the commit path.

## Cross-compiling and releases

NovaDB is pure Zig, so it cross-compiles from any host with only the bundled toolchain, the same story as
the Nova toolchain in Chapter 22. Build one target with `-Dtarget=<triple>`, or stamp out every supported
target at once:

```sh
zig build -Dtarget=aarch64-macos      # one target into zig-out/bin
zig build cross                        # all supported targets into zig-out/cross/<triple>/
```

The supported set is macOS, Linux, and Windows on both x86_64 and aarch64. The repository also ships a
GitHub release workflow that runs `zig build cross` on a single runner and publishes a packaged archive
plus a checksums file per target, so a tagged release carries binaries for every platform. One honest
caveat: the Windows server binary builds and links, but its runtime is not yet run-verified, so treat
Windows as a cross-compile target rather than a supported production host for now.

## How this connects back to Nova

From a Nova program you never touch any of the above directly. You add the `nova-novadb` package, build a
`novadb://` connection string, and use the `Connection` seam and the micro-ORM exactly as Chapter 18
showed. NovaDB is the server on the other end of that connection. This chapter is the map of what is
running there.

## Where to go next

- Chapter 18 for using NovaDB from a Nova web app: the `db` seam, the repository pattern, and swapping the
  app onto a live NovaDB by changing one file.
- Chapter 20 for the `nova-novadb` driver in the context of all five drivers, the DSN format, and the
  connection pool.
- Chapter 23 for running a NovaDB-backed service under the orchestrator (whose own config store is on
  artifactd, not NovaDB).
