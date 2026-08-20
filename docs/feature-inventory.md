# Nova platform inventory (features, soundness, and acceptance criteria)

Status: LIVE INVENTORY, started 2026-08-20. This is the authoritative register of what the Nova PLATFORM has
(language + runtime, the NovaDB engine, and the orchestrator / control plane), how sound each piece is, and
the ACCEPTANCE CRITERIA that define "done and sound" for it. When we harden a feature, we make its unmet
criteria pass, and we test against exactly these criteria.

It is not a comparison to other languages and it does not enumerate absences. Anything not here is something we
chose not to build; it is not a gap. A green test is only as strong as what it exercises: several areas are
gated over IN-PROCESS SIMULATIONS (a fake connection, a shared in-memory store, virtual replicas), which proves
the algorithm but NOT the real distributed system. That is called out per feature.

## How to read this

Each feature has a **status**, a **verification method**, and a checklist of **acceptance criteria**.

Status: **SOUND** (implemented, gated, no known hole) / **PARTIAL** (works, documented limitation) /
**UNSOUND** (a confirmed correctness or safety defect).

Criterion mark: **[x]** met (evidence exists) / **[~]** partial or unverified / **[ ]** not met.

Verification method (strongest wins): **probe** (compiled + run this session) / **case N** (a conformance case
gates it) / **read** (source read first-hand this session) / **swept** (broad audit sweep only; weakest;
verify before trusting). When a swept claim and a probe disagree, the probe wins.

A feature is only "SOUND and complete" when every one of its criteria is [x]. A SOUND status with a [~] or [ ]
criterion means sound-for-what-it-does but not complete.

## The shape of Nova (the model we built)

Deliberate architectural choices, stated as what we HAVE. The identity of the platform. All SOUND.

- **Single-reactor, share-nothing, thread-per-core runtime.** Scale is per-process: N single-reactor instances
  behind `proxyd`, horizontal. Web-first by intent.
- **ARC for memory** (deterministic destructors, no GC).
- **Native-first compilation** (Zig frontend, LLVM backend, in-process LLD; WASM secondary).
- **Value-based errors** (`T | E` + `try` / `catch` / `errdefer`; no unwinding).
- **Structural generic dispatch** (monomorphised; trait dispatch by shape).
- **struct = value, class = reference** with inline nested value storage.

---

# Stream 1: Language and runtime (PRIORITY)

### Monomorphisation ; SOUND ; probe
- [x] Concrete generic instantiations produce correct code (case-gated).
- [x] Method-level generics tracked separately (`List<T>.map<U>`).
- [x] Field-type and return-type recursion instantiated (the `Set<T>{map:Map<T,bool>}` fix).
- [x] Deep nesting does not crash; falls back to the erased body and runs (probe: depth-4 runs).
- [~] Eager instantiation beyond nesting depth 2 (perf only, not correctness; deeper uses the erased path).
- [x] No `LLVMVerifyError` from a standalone generic that never reached the worklist.

### Traits and dynamic dispatch ; SOUND ; case
- [x] Dynamic dispatch via fat pointers `{struct_ptr, vtable}`; vtable slot 0 is the destructor.
- [x] Checked downcast (`x as T`) traps on a wrong concrete type.
- [~] Trait default methods work cross-module (currently same-module only).
- [~] Generic trait dispatch is monomorphic, not type-erased (currently erased, one slot per method).

### Generic bounds (`where T: Bound`) ; PARTIAL ; read
- [x] `where` clauses parse and document intent.
- [ ] A type that does not satisfy a bound is rejected at compile time (currently advisory only).

### Enums and pattern matching ; SOUND ; case
- [x] Payload-less, single-payload, tuple-form, and struct-form variants.
- [x] `switch` with destructuring binds payloads.
- [x] Case guards (`case v if cond`).
- [x] ARC destructors run for refcounted enum payloads.
- [~] Exhaustiveness is always enforced (currently skipped when the discriminant type cannot be resolved).

### Error handling (`T | E`, `try`, `catch`, `errdefer`) ; SOUND ; case
- [x] `try` propagates the error arm to the enclosing function.
- [x] `catch` handles; both arms unify to one type.
- [x] `errdefer` runs only on the error path, LIFO.
- [x] `T | E | undefined` composes optional over error.

### Optionals and narrowing (`T | undefined`) ; PARTIAL ; probe
- [x] Member access through an optional is guarded, not a null deref.
- [x] `if (x != undefined)` narrows `x` to its inner type in the branch.
- [x] Reassigning a narrowed variable invalidates the narrowing.
- [x] Nested optionals from generics (`Map<K, int|undefined>`) are handled.
- [x] `x ?? d` returns the present value for a present non-zero, and the default for genuine absent.
- [ ] `x ?? d` returns the present value for a present ZERO after narrowing (UNSOUND, see below).

### `x ?? d` on a narrowed present 0 ; UNSOUND ; probe
- [ ] A present `0` in a narrowed value-optional coalesces to `0`, not the default.
- Root: `??` presence test is `left != 0` (`expressions.zig:4643`); a narrowed value-optional is a raw value
  where present-0 and the absent sentinel are both 0. NOT fixable at the `??` site (three guard attempts each
  regressed serde/DI/try). Real fix is representational: keep value-optionals boxed, or a reliable narrowing
  signal in the typed IR. Test criterion: the narrow-then-coalesce-zero probe passes AND the full corpus stays
  at 395/398.

### Closures / lambdas ; PARTIAL ; probe
- [x] A stored / aliased multi-argument closure calls correctly (`let g = f; g(3,4)`).
- [x] Per-instance heap environments; loop captures are independent.
- [ ] Closure parameters are typed (currently untyped, inferred from the call site).
- [ ] An escaping closure environment is freed (currently leaks, see below).

### Escaping closure environment leak ; UNSOUND ; swept
- [ ] A returned closure's environment box is ARC'd and freed (currently leaks ~46 B, not ARC'd).
- Test criterion: an ASAN run over a function that returns a capturing closure shows 0 leaks.

### Integers (`int` 32-bit, `long` 64-bit) ; SOUND ; probe
- [x] `int` is 32-bit two's-complement with defined wraparound; `long` is 64-bit.
- [x] Address arithmetic uses `long`/`ptr` (no 32-bit truncation of heap addresses).
- [~] A checked/overflow-trapping integer mode exists (not built; wraparound is the defined behaviour).

### `Atomic<T>` compile-time check ; SOUND ; probe
- [x] An invalid atomic element type (`Atomic<string>`) is rejected at compile time.
- [ ] The `Atomic<T>` stdlib type has a working runtime (currently a stub: load undefined, CAS false).

### `decimal128` ; SOUND ; case
- [x] Arithmetic, parse, and round-trip through JSON / YAML / BSON with fidelity.
- [x] No implicit int/decimal coercion.

### Type-checker soundness (fail-closed) ; PARTIAL ; read
- [x] Method-call arity is checked; unresolved calls are located errors.
- [x] Non-bool `if`/`while` conditions are rejected (allowlist).
- [x] Optional/error assigned or passed where a plain value is required is rejected.
- [ ] Every checked position fails CLOSED: an expression whose type cannot be resolved is a compile error, not
  a skipped check (5+ live `resolveExprType(...) orelse return` sites remain: condition, return, switch
  discriminant, field access).

### async / await ; SOUND ; case
- [x] `async fn` compiles to an LLVM coroutine; `spawn` returns a future; `await` joins.
- [x] Function colouring enforced (`await`/`spawn` only inside `async fn`).
- [x] `when_all` / `select` over a homogeneous future list.
- [~] Heterogeneous-type combinator (`join!`-style) (only homogeneous `List<future<T>>` today).

### Reactor (kqueue / epoll / io_uring / IOCP) ; SOUND ; case
- [x] All four backends run-verified against the conformance corpus.
- [x] Deadlines / timeouts are reactor-native on every backend.
- [~] io_uring uses multishot recv / SQPOLL (currently readiness-emulated, slower than epoll).
- [ ] IOCP readiness cases 192/194/195 pass (open).

### Channels and actors ; PARTIAL ; read
- [x] A blocking cross-thread `Channel<T>` (buffered) works.
- [x] An async channel (reactor-aware) works.
- [x] Actor mailboxes with `async receive`.
- [ ] Bounded async channel with backpressure.
- [ ] `select` over channel operations (only over futures today).
- [ ] Actor supervision / restart / registry.

### ARC memory management ; SOUND ; case + asan
- [x] Retain/release inserted by codegen; destructors free owned objects (ASAN-clean corpus).
- [x] struct = value, class = reference, with inline nested value storage.
- [x] Value-semantics escape channels closed (return/serde/type-param/trait/container-COW).

### OSSA static leak / double-free verifier ; SOUND ; case + gate
- [x] Proves every owned value is consumed exactly once on covered functions (leak / double-free /
  use-after-consume / path-imbalance).
- [x] Default-on and fail-closed; rejects a proven imbalance at compile time.
- [x] 99-100% corpus coverage; reassign deferral bucket is 0 (if/loop/switch/break/continue via phis).
- [~] It is a compiler-correctness ARC-balance self-check, NOT a Rust-style borrow checker (by scope).

---

# Stream 2: Standard library

### Collections (Map / Set / List) ; PARTIAL ; case
- [x] Map/Set are a real open-addressing hash table (tombstones, resize).
- [x] List has a rich functional API (map/filter/reduce/slice/etc.).
- [ ] `List.sort` is O(n log n) (currently insertion sort, O(n^2)).

### Strings and text ; SOUND ; case
- [x] Complete byte-oriented API (split/join/slice/trim/replace/case/compare).
- [x] UTF-8 codepoint decode/encode.
- [~] Unicode normalisation / grapheme / collation / case-fold (codepoint-level only).

### Regex ; PARTIAL ; case
- [x] Alternation, char classes, anchors, `* + ?`, capture groups, find/replace.
- [ ] Linear-time (no catastrophic backtracking; currently a backtracking VM).
- [ ] Common escapes and counted repetition (`\d` `\w` `\b` `{n,m}`, lazy quantifiers).

### Serialisation (JSON / YAML / BSON) ; SOUND ; case
- [x] Parse and serialise with numeric fidelity (int fast-path, decimals as text).
- [x] Malformed input sets a failed flag (no silent partial parse).
- [~] YAML is full 1.2 (subset today: no verified merge keys / complex tags).

### Crypto and TLS ; SOUND (unaudited) ; case
- [x] SHA / AES-GCM / ChaCha20-Poly1305 / P-256 / P-384 / X25519 / RSA, KAT + differential tested.
- [x] TLS 1.3 client + server with 0-RTT, resumption, mTLS; TLS 1.2 client.
- [ ] SHA-384 transcript (AES-256-GCM-SHA384-only servers currently fail).
- [ ] Independent security audit (hand-rolled, unaudited).

### Compression (deflate / gzip) ; PARTIAL ; case
- [x] RFC-1951 decoder, byte-exact against system gzip.
- [ ] Encoder emits dynamic Huffman + lazy matching (currently fixed-Huffman greedy; weaker ratio).

### HTTP / web framework ; SOUND ; case
- [x] HTTP/1.1 server + client, typed path params, DI, mediator, full middleware, hypermedia/SSE.
- [~] HTTP/2 or HTTP/3 (HTTP/1.1 only).

### datetime ; PARTIAL ; swept
- [x] ISO-8601 / RFC-3339 parse, format, and arithmetic.
- [ ] 64-bit epoch (currently 32-bit, Year-2038).
- [ ] Timezone database (treats wall-clock as UTC).

---

# Stream 3: Database drivers (the `db` seam)

### Wire protocols (pg / mysql / mssql / mongo) ; SOUND ; read
- [x] Real binary protocols, server-side prepared statements, transactions.
- [x] Connection pooling with idle/open caps and lifetime eviction.
- [~] Micro-ORM has relations / migrations / query builder (data-mapper only).

### BSON ORM `long` fidelity ; UNSOUND ; swept
- [ ] The ORM bind path preserves 64-bit `long` (currently truncates to 32 bits).

### MSSQL transport defaults ; UNSOUND ; read
- [ ] Encryption is on by default.
- [ ] The server certificate is verified by default.
- Currently `encrypt=false` and `trustCert=true` unless the connection string overrides both.

### MySQL / SCRAM auth trust ; UNSOUND ; swept
- [ ] MySQL caching_sha2 does not send the password against an unverified server RSA key over plaintext.
- [ ] The SCRAM ServerSignature is verified (currently never checked; rogue-server accept).

### Per-connection buffer leaks ; UNSOUND ; swept
- [ ] Postgres does not leak its ~64 KB reader buffer per connection.
- [ ] TlsStream does not leak ~16 KB per connection.

---

# Stream 4: Tooling

### Compiler + build ; SOUND ; build
- [x] Cross-compilation to linux / macos / windows produces real binaries.
- [x] Per-file object caching skips unchanged files.
- [~] Incremental compilation is query-granular (currently coarse file-hash / split-object).

### Package manager ; PARTIAL ; read
- [x] Git-pin dependency resolution with a lockfile.
- [ ] A central registry / discovery.
- [ ] Semver range resolution and version unification.

### LSP (`nls`) ; PARTIAL ; read
- [x] Completion, hover, definition, symbols, semantic tokens.
- [~] Rename / references are semantic cross-file (currently text-based for globals).
- [ ] Cross-file (import-resolved) diagnostics (currently single-file).

### Debugger ; SOUND ; read
- [x] DWARF line tables + DITypes, lldb-dap, data formatters for List/Map/Set/struct.
- [~] Non-macOS wiring and full formatter coverage.

### Formatter and test runner ; PARTIAL ; build
- [x] `nova fmt` with a token-stream-equivalence self-check.
- [x] `nova test` runs `@test` functions with assertions and a pass/fail tally.
- [ ] Coverage, benchmarks, name filters, fixtures in the test runner.

---

# Stream 5: NovaDB (the database engine)

Merge gate is `zig build test` (44 leak-checked integration/durability/replication cases in `src/root.zig`);
shell harnesses are manual and non-gating.

### B+tree index ; SOUND ; case
- [x] search / insert / update / delete / range scan.
- [x] page split, merge, borrow; underflow handling.
- [x] A randomised insert/delete/search fuzzer stays model-consistent and structurally invariant.

### Storage (pool / pager / page / overflow) ; SOUND ; case
- [x] CRC32 checksum written on flush and validated on read (fail-fast on corruption).
- [x] Doublewrite buffer protects against torn writes.
- [x] Free-page recycling; eviction respects the WAL-before-page gate.

### WAL durability + crash recovery ; SOUND ; case
- [x] Kill-9 with unflushed pages recovers every committed row.
- [x] Kill-9 under eviction pressure recovers every committed row (WAL-before-page reorder).
- [x] A torn WAL tail recovers cleanly (garbage tail stopped at).
- [x] ENOSPC on commit is never falsely ACKed.
- [x] 3-phase recovery re-bootstraps the system catalog (the fixed Phase-2 data-loss bug).

### Replication safety ; SOUND ; case
- [x] Log-shipping with logical follower apply (cross-node page-id fork resolved).
- [x] Fencing epochs reject a stale-epoch writer.
- [x] Quorum-ack durable commit (RPO=0).
- [x] Partition-then-heal soak keeps at most one leader; corrupted frames rejected; mTLS + auth.
- [ ] Automatic leader election / lease-driven failover (currently manual `SET FENCE EPOCH`).

### MVCC ; PARTIAL ; read
- [x] Uncommitted rows invisible; committed visible; rolled-back invisible (Read Committed).
- [ ] Snapshot / repeatable-read / serializable isolation.
- [ ] An aborted row is never visible in memory before restart (documented abort-visibility gap).
- [ ] The in-memory committed-txn set is bounded (currently unbounded; GC is disk-side only).

### Transactions and isolation ; PARTIAL ; case
- [x] BEGIN / COMMIT / ROLLBACK.
- [ ] Selectable isolation level (`SET TRANSACTION ISOLATION LEVEL`).
- [ ] SAVEPOINT / ROLLBACK TO.

### Concurrency and locking ; PARTIAL ; case
- [x] Per-table GroupLock (SELECT read / INSERT concurrent-write / UPDATE-DELETE exclusive).
- [x] Per-tree structure lock (shared in-place / exclusive split-merge) with optimistic fast paths.
- [x] Structured concurrent-writer stress cases are gated.
- [ ] The harshest randomised concurrent same-tree mutation is gated (currently OFF by default; expected to
  corrupt per its own comment).
- [~] Write scalability beyond ~5 writers (deliberate ceiling today).

### SQL parser ; PARTIAL ; read
- [x] CREATE/ALTER/DROP TABLE, PK, NOT NULL, single-col FK, CREATE/DROP INDEX.
- [x] Single-row INSERT, UPDATE, DELETE; SELECT with projection, 5 aggregates, GROUP BY, LIMIT, JOINs.
- [ ] Subqueries, IN/LIKE/BETWEEN/IS NULL, expressions/arithmetic, UNION, HAVING, multi-row INSERT.

### SQL correctness (silent-wrong) ; UNSOUND ; read
- [ ] ORDER BY actually sorts the result (currently parsed but never executed).
- [ ] Column types are stored as declared (currently DATE/DECIMAL/etc. silently collapse to TEXT).
- [ ] COUNT(DISTINCT) deduplicates; UNIQUE is enforced; FK actions are enforced.

### Query executor ; PARTIAL ; read
- [x] Volcano iterators: table scan, index scan, nested-loop join, hash join, filter, project.
- [x] Aggregates + GROUP BY.
- [ ] A statistics-driven cost-based optimiser (currently rule-based; docs overstate "CBO Implemented").

### Binary wire protocol ; PARTIAL ; case
- [x] Versioned, length-prefixed frames; startup/query/parse/bind/execute; oversized-frame reject.
- [x] SQL-injection-neutralisation tests on the command path.
- [ ] The simple-query executor accepts server-side bound parameters (prepared path only today).

---

# Stream 6: Orchestrator / control plane

Read first: the offline gate tests ALGORITHMS OVER IN-PROCESS FAKES (shared in-memory store, virtual replicas,
a `FakeConn`); the real cross-process/cross-node paths are only in manual, non-gating tests. And the offline
gate does not currently reproduce green on this checkout (see the two UNSOUND rows).

### proxyd data plane (LB, pool, discovery) ; SOUND (logic) ; case
- [x] RoundRobin / Weighted / LeastConn / ConsistentHash strategies, per-reactor lock-free.
- [x] Backend pool with keep-alive safe reuse.
- [x] Discovery-file publish (atomic temp+rename) and consume.
- [ ] Verified against live socket forwarding (tests exercise `Pool.select` logic only).

### proxyd health checks and VIP ; PARTIAL ; case
- [x] Rise/fall hysteresis, drain/restore decision logic.
- [ ] A gating LIVE probe sweep.
- [ ] VIP bind for a non-dotted-quad host (currently IPv4-only, else INADDR_ANY fallback).

### orchd reconcile (desired-vs-actual) ; PARTIAL (simulated) ; probe
- [x] Diff logic: start-new / replace-changed / poll-unchanged / keep-unreadable / stop-when-gone.
- [x] Store-driven reconcile parses YAML/JSON and validates.
- [ ] Reconcile drives REAL process lifecycle (currently `simulated=true`, virtual replicas).
- [ ] `181_orchestrator` runs to completion (currently crashes entering the async reconcile subtest).

### Leader lease (fencing epochs) ; SOUND (logic) ; case
- [x] Fencing-after-promotion; a stale-epoch renew is rejected.
- [x] Clock-skew and 3-node election gated over a shared in-process store.
- [ ] Verified as a real distributed system (currently one shared in-process store + mock clock).

### Leader-lease live create-race ; UNSOUND ; read
- [ ] Two nodes racing a FREE lease cannot both win epoch 1.
- Currently `casBy(expectedRevision==0)` does `exists()` then an unconditional INSERT and discards the result;
  the PK conflict is never checked. Test criterion: a concurrent two-node `tryAcquire(0)` race yields exactly
  one winner.

### Orchestrator offline gate reproducibility ; UNSOUND ; probe
- [ ] `185_sqlconfig` compiles (currently fails: `FakeConn` missing `queryWire`; the `Connection` trait
  drifted and the package was not rebuilt against it).
- [ ] Async tests (181/186/187/192/193/195) run to completion (currently abort after their sync subtests).
- Test criterion: the whole `packages/nova-orchestrator/tests` suite builds and passes on a clean checkout.

### Autoscaler (PID) ; PARTIAL ; case
- [x] PID controller with anti-windup, output clamp, dt-guarded derivative.
- [x] Real in-flight / cgroup CPU signal (Linux).
- [ ] The CPU signal is per-replica, not aggregate-across-replicas against a per-replica setpoint.
- [ ] Scale-down does not block the reactor (`p.wait()` on reactor 0 today).

### Rolling upgrade + HA membership ; SOUND (simulated) ; case
- [x] Workload rolling update (one replica at a time, N-1 keep serving).
- [x] Control-plane drain/promote/upgrade/rejoin with rollback.
- [x] HA property test: RPO=0 each round, RTO measured, epoch monotonicity.
- [ ] Verified over real processes / a real cluster (currently simulated replicas + one shared store).

### Config store on NovaDB ; PARTIAL ; read
- [x] In-memory reference store with atomic CAS.
- [x] Async `SqlConfigStore` code path over the `Connection` seam.
- [ ] Its gating test builds and exercises the CAS revision guard (currently `185` does not build; the fake
  ignored the guard anyway).
- [ ] Transactions on the seam are used (currently `begin/commit/rollback` never called).

### Isolation / sandbox / netns ; PARTIAL ; case
- [x] cgroups-v2 limits, namespaces, netns+veth recipe; honest no-op off Linux.
- [x] Supervisor selects handoff / netns / sandbox / plain per spec; reports when limits are unavailable.
- [ ] Live-verified on Linux (this host is macOS; only the no-op and command recipe are gated).
- [ ] `applyLimits` checks write results (currently ignores them; silent downgrade on unprivileged Linux).

### Observability, backup, orchctl ; PARTIAL ; case
- [x] `/healthz` `/readyz` `/metrics` renderers and alerts (pure-data path gated).
- [x] Logical backup/restore and offline `orchctl inspect/members/upgrade-plan`.
- [ ] Output escaping in health/metrics/backup (a tab or newline in a value corrupts the dump).
- [ ] `192`/`193` observability tests run to completion (currently crash on this host).

---

## The unmet-criteria worklist (the UNSOUND rows and the biggest gaps)

Ordered with the language stream first (the priority).

Language:
1. `x ?? d` on a narrowed present 0 (representational fix).
2. Escaping closure environment leak.
3. Type-checker fully fail-closed (the remaining `orelse return` sites).

Drivers:
4. BSON ORM `long` truncation.
5. MSSQL secure-by-default transport.
6. MySQL RSA-over-plaintext and unverified SCRAM signature.
7. pg / TLS per-connection buffer leaks.

NovaDB:
8. SQL silent-wrong (ORDER BY sort, typed storage, DISTINCT/UNIQUE/FK enforcement).

Orchestrator:
9. Offline gate reproducibility (`queryWire` drift + async-test crashes) ; a prerequisite for trusting the rest.
10. Leader-lease live create-race split-brain.

The best-proven parts of the platform are NovaDB durability/crash-recovery and replication safety, and the
language's ARC + OSSA verifier. The least-proven are the orchestrator paths that are green only over an
in-process simulation. When we work an item, "done" means every acceptance criterion for that feature is [x],
with the stated test as the gate.
