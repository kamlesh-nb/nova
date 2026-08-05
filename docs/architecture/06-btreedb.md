# NovaDB, Architecture

NovaDB is a high performance, embeddable and serverable **B+Tree storage engine and SQL database**,
written in **Zig**. It is the storage engine behind the Nova ecosystem, yet it stands alone as a database
in its own right. Nova connects to it over a binary wire protocol; NovaDB is intentionally a *separate*
project, and is to be built and versioned separately (it resides in `../../btree/`, not in this
repository).

> This is a navigable overview in the manner of the Nova architecture set. For the authoritative design
> specification, including the exact page layout, the B+Tree invariants, and the concurrency protocols,
> kindly refer to `btree/architecture.md` within the NovaDB repository.

## Layout (`btree/src/`)

| Directory | Responsibility |
|-----------|----------------|
| `storage/` | `btree.zig`, `pager.zig`, `page.zig`, `pool.zig`, `overflow.zig`. The slotted page B+Tree and the buffer pool. **This is the core.** |
| `durability/` | `write_ahead_log.zig`, `checkpoint.zig`, `wal_error.zig`. The write ahead log and recovery. |
| `concurrency/` | `transaction.zig`, `undo.zig`, `security.zig`. MVCC, the undo log, and access control. |
| `schema/` | `database.zig`, `catalog.zig`, `table.zig`, `types.zig`, `row.zig`. The SQL schema and catalog. |
| `sql/` | `lexer.zig`, `parser.zig`, `ast.zig`. The SQL front end. |
| `query/` | `query_executor.zig`, `iterator.zig`, `tcp_server.zig`, `replication.zig`, `stats.zig`. Execution and the network server. |
| `proto/` | `protocol.zig`, `wire.zig`, `session.zig`, `session_pool.zig`, `command.zig`, `oidmap.zig`, `message_buffer_pool.zig`. The binary server protocol. |
| `common/` | `config.zig`, `service.zig`, `time.zig`, and other shared utilities. |
| `src/main.zig`, `src/cli.zig`, `src/root.zig` | The entry point and the CLI. |

## The Storage Core, `storage/`

### The Slotted Page

A page is **16 KB** (`PAGE_SIZE = 16384`). Both leaf and internal pages use a **slotted page** layout so as
to store variable length records (called cells) with a two way growth model.

```
+-------------------------------------------------------------+
| PageHeader (24 bytes)                                       |
+-------------------------------------------------------------+
| Slot 0 (offset, size) | Slot 1 | Slot 2 ...                 |
|  ---------> the slot directory grows downwards              |
+-------------------------------------------------------------+
|                      <--- free space --->                   |
+-------------------------------------------------------------+
|                          ... | Cell 2 | Cell 1 | Cell 0 |   |
|                          the cell payloads grow upwards <-- |
+-------------------------------------------------------------+
```

Each slot is a `CellPtr` (8 bytes: `offset`, `key_size`, `value_size`, and per cell `flags`). On deletion,
the slot is removed and all subsequent slots are shifted left by one entry, so that the directory remains
strictly contiguous and indexable without any holes; the freed payload space is marked as fragmented. When
the cumulative free space suffices but is fragmented, the page performs an **in place, zero heap
compaction**: the payloads are re-packed contiguously from the bottom of the page, purely within the raw
byte array, and the slot offsets are updated, all with no allocator involvement.

Large values do not sit inline. A cell whose `value_overflow` flag is set stores an `OverflowDescriptor`
instead of the value bytes, and the real value resides in a chain of **overflow pages** (`overflow.zig`).

### The Buffer Pool and Latch Crabbing

The `PagePool` (`pool.zig`) is a page cache over the file, **segmented** into N independent instances
(default N is 8). A request for `page_id` maps to an instance by `page_id % N`, so that each instance has
its own mutex and hash table, and hence thread contention is localised to one Nth of the page space. The
B+Tree traversal uses **latch crabbing** (lock coupling), whereby a child latch is acquired before the
parent latch is released, so as to keep concurrent readers and writers correct without a single global tree
lock.

The `pager.zig` layer maps pages to and from the file and coordinates with checkpointing.

## Durability, `durability/`

Every mutation is first appended to the **write ahead log** (`write_ahead_log.zig`), so that a crash after
an acknowledged write is recoverable. **Checkpoints** (`checkpoint.zig`) periodically flush dirty pages and
truncate the log. On startup, recovery replays the WAL from the last checkpoint. `wal_error.zig` carries
the recovery error taxonomy.

## Concurrency, `concurrency/`

- **MVCC.** Multi version concurrency control gives readers a consistent snapshot without blocking writers;
  the **undo log** (`undo.zig`) records the prior versions so that a reader may reconstruct the version
  appropriate to its snapshot, and so that a transaction may roll back.
- **Transactions** (`transaction.zig`) coordinate the WAL, the undo log, and the page latches.
- **The concurrency ceiling.** A **global `db.rw_lock`** serialises writers, which places the practical
  ceiling at roughly five concurrent threads. This lock is **load bearing for correctness**, and hence
  removing it is not a deletion but a rewrite towards finer grained, latch coupled locking with a latch
  safe structure modification (SMO) protocol. Any such change is to be gated on measured evidence; kindly
  see `btree_readiness_plan.md` for the phased plan and the known critical items.

## The SQL Layer, `sql/` and `query/`

`sql/lexer.zig` and `sql/parser.zig` produce an AST (`sql/ast.zig`). The `query/query_executor.zig` walks
that AST against the schema and catalog (`schema/`), producing rows through `query/iterator.zig` (a
pull based iterator model). `query/stats.zig` maintains statistics, and `query/replication.zig` carries
the replication machinery.

## The Server and Binary Protocol, `query/tcp_server.zig` and `proto/`

`query/tcp_server.zig` listens for clients and hands each connection to the protocol layer. The **binary
wire protocol** (`proto/`) is the intended path for Nova's driver.

- `protocol.zig` and `wire.zig` define the framing and the typed encode and decode of values on the wire.
- `session.zig` and `session_pool.zig` manage a client session and pool sessions across connections.
- `command.zig` dispatches the request commands.
- `oidmap.zig` maps object identifiers, and `message_buffer_pool.zig` reuses message buffers so as to keep
  allocation off the hot path.

## Relationship to Nova

Nova (the `lang` repository) talks to NovaDB through this binary protocol, by way of the published
**`nova-novadb`** driver package, which implements the `db` seam (see [04-stdlib.md](04-stdlib.md)). From
Nova's side, NovaDB is simply one interchangeable backend behind the `Driver` and `Connection` traits; a
program may swap it for Postgres, MySQL, MSSQL, or MongoDB without touching the call sites. NovaDB, for its
part, remains independent, and knows nothing of Nova beyond the wire.

## Build, Run, Test

```sh
cd btree
zig build                 # build the `btree` and `btree-cli` executables
zig build run             # or run ./zig-out/bin/btree
zig build test            # unit tests
```

The configuration resides in `db.yaml`, and the server listens for binary protocol clients. Kindly note
that `nova.db` is a test artifact (regenerated by running the engine), and is not to be hand edited. The
earlier WASM and wasmer embedding has been removed; the database builds with no wasmer dependency at
present.
