# Nova feature-parity scorecard (vs Rust and Go)

Status: HONEST ASSESSMENT, 2026-08-20. Author: language soundness review. This document is an
evidence-backed, deliberately unflattering audit of where Nova actually stands against Rust and Go, based on
reading the compiler, runtime, and standard library source (not the aspirational specification prose). It
exists so we do not mislead ourselves about maturity. Where a claim is measured, the measurement is cited;
where something is naive or fragile, it says so plainly.

Companion documents that this cross-checks against: `docs/gaps.md` (the defect register, mostly accurate but
see the caveat below), the top-level `CLAUDE.md` (some prose is stale, trust the code and the conformance
table), and `docs/design/ossa-static-ownership-verifier.md` (the ownership guarantee, measured).

## Method and its limits (read this before trusting any single line)

This audit was produced by a BROAD, PARALLEL EXPLORATION SWEEP: several read-only agents read excerpts across
the compiler, runtime, and standard library and cross-checked the project's own `docs/gaps.md`. That is a good
map of the KNOWN and MAJOR gaps. It is NOT a line-by-line audit, and because it leaned on a self-reported
defect register it inherits that register's blind spots in both directions:

- It can UNDER-sample: a gap that is neither obvious in an excerpt nor listed in gaps.md will be missed. Do not
  read the absence of a gap here as proof one does not exist.
- It can OVER-state: at least one severity label was wrong. gaps.md called the NovaDB primary query path
  "SQL-injectable" (Sec4); reading `typemap.nova` first-hand shows text params ARE escaped client-side
  (single-quote doubling, hex blobs), so the honest severity is lower (see the ship-readiness section). That
  correction was only found by reading the actual code, which the sweep did not do for every claim.

A genuinely careful verdict requires reading the code claim-by-claim, as was done for the two most serious DB
items. Treat every row here as "worth verifying", not "verified", except where a line explicitly says it was
confirmed first-hand or is backed by a conformance case number.

## The one-line verdict

Nova is **not at par with Rust or Go overall**. It has the *shape* of a peer across an impressive range of
features, plus a few areas where it genuinely stands up or leads, but most dimensions are the intentionally
minimal version of what the mature toolchains ship. The honest label is **capable advanced-alpha, approaching
beta**. The gap is rarely "missing"; it is "present but shallow, naive, or not yet battle-tested". Almost all
of it is engineering, not new language theory.

## Scorecard

Verdict legend: **Ahead** / **At par** / **Near par** / **Behind** / **Well behind**, judged on the features
Nova actually has today, not on ambition.

| Dimension | Nova today | Verdict vs Rust/Go |
|---|---|---|
| async / await ergonomics | LLVM stackless coroutines, spawn/await/when_all/select, enforced colouring, deadlines | At par (common path) |
| Single-core reactor throughput | 168 to 186k rps per core on M1; one core beat 8-core peers on that box | Ahead per core (with caveats) |
| Error handling | value-based `T \| E`, try / catch / errdefer, no unwinding | At par with Go, cleaner |
| Enums / ADTs / switch | multi-payload variants, case guards, exhaustiveness | Near par |
| Static memory safety | ARC plus default-on OSSA leak / double-free verifier (~99% coverage, fail-closed) | Novel middle ground, see note |
| Crypto and TLS | pure-Nova primitives, TLS 1.3 client and server, 0-RTT, mTLS, KAT-gated | Feature-competitive, unaudited |
| Database drivers | pg / mysql / mssql / mongo real wire protocols, pooling, transactions | Near Go's database/sql breadth |
| Web framework | routing, DI, mediator, full middleware suite, hypermedia / SSE | Broad, HTTP/1.1 only |
| Generics | full monomorphisation, capped at nesting depth 2, bounds advisory only | Behind both |
| Concurrency runtime | share-nothing thread-per-core, no work-stealing, no preemption, no cancellation | Well behind |
| Collections and stdlib depth | rich List API, but O(n^2) sort, backtracking regex, no bignum, 32-bit int and time | Behind |
| Tooling | compiler, cross-compile, DWARF debugger, LSP, git package manager, formatter | About 20 to 30 percent of cargo |

### Note on the ownership verdict

The OSSA ownership verifier is a genuine and slightly unusual differentiator, so state it precisely. It proves
that the compiler's own ARC insertion is balanced, that is, every owned value is consumed exactly once on
every path, which means no compiler-introduced leak, double-free, or use-after-consume for owned values. As of
this session it is default-on and fail-closed (it rejects a build on a proven imbalance), and the measured
coverage on the conformance corpus is 99 to 100 percent of functions with the reassign deferral bucket now at
zero. That is a real static leak and double-free guarantee that neither Go (garbage-collected) nor Rust offers
in this exact form.

It is NOT Rust's borrow checker. It does not check aliasing-xor-mutation, it gives no data-race freedom, and
it has no lifetime or dangling-reference analysis. It is a compiler-correctness self-check, not a user-facing
safety net against ownership mistakes (in Nova the user cannot make those, because ARC is automatic). Do not
oversell it as "Rust-safe".

## Where Nova genuinely stands up

1. **Async ergonomics and single-core network throughput.** LLVM coroutines put spawn / await / select in the
   same family as Rust futures, and the reactor's per-core numbers are real. Caveat below on what the headline
   number does and does not include.
2. **Default-on static leak and double-free verification.** Described above. High coverage, zero false
   positives, CI and default-build enforced.
3. **Crypto, TLS, and DB-driver breadth.** All punch above the project's age. The crypto is KAT and
   differential tested; the TLS 1.3 stack does 0-RTT, resumption, and mTLS; the DB drivers speak real binary
   protocols with pooling and transactions.

## Where Nova is clearly behind

### Language

- No borrow checker, no lifetimes. Safety rests on ARC plus the balance verifier.
- No macros. No const generics. No higher-kinded or associated types. No blanket impls.
- Generic bounds (`where T: Bound`) parse but are advisory only; a wrong bound is not a compile error.
- Monomorphisation is capped at container nesting depth 2; deeper nests are refused, not just slow.
- Escaping closure environments are not ARC'd and leak (about 46 bytes each). Closure parameters are untyped
  and inferred from the call site, and a stored multi-argument closure has a known arity crash (gaps.md C4).
- The type checker's historical root weakness is fail-open: when an expression's type cannot be resolved the
  check is skipped and codegen guesses. Many items are fixed for resolvable types, but an untypeable
  expression can still slip a check. This has been tightened, not proven.

### Concurrency runtime

- No in-process work-stealing multicore scheduler. Cores are balanced only by the kernel's SO_REUSEPORT accept
  fan-out. A hot connection or a CPU-heavy coroutine cannot be rebalanced to an idle core. This is the biggest
  structural difference from Go.
- No preemption. Scheduling is cooperative, so a CPU-bound coroutine that never awaits monopolises its reactor
  thread. Go preempts at safepoints.
- No cancellation. A timed-out or losing task keeps running to completion. There is no cancellation token, no
  structured-concurrency nursery, no `context.Context` equivalent.
- Channels are weak. The cross-thread `Channel<T>` blocks an OS thread and is marked vestigial; the async
  channel is unbounded with no backpressure; there is no select over channel operations.
- `Atomic<T>` is a stub (load returns undefined, compareAndSwap returns false). Multi-core only wires up on the
  server path; ordinary async programs run a single reactor thread.

### Standard library

- List sort is insertion sort, O(n^2). There is no fast general-purpose sort.
- The regex engine is a recursive backtracking VM: it can catastrophically backtrack on adversarial patterns,
  is byte-only (no Unicode classes), and lacks `{n,m}`, `\d`, `\w`, `\b`, lazy quantifiers, and backreferences.
- The deflate encoder is fixed-Huffman greedy only, so its compression ratio is materially worse than zlib or
  Go's compress/flate. The decoder is fully compatible.
- No bignum. `int` silently wraps at 32 bits (honest or checked overflow is not implemented). The datetime
  epoch is a 32-bit int, so it has a Year-2038 problem, and there is no timezone database.
- Unicode support is minimal: no normalisation, grapheme clusters, collation, or case folding.

### Tooling

- No package registry, no discovery, no semver resolution or version unification (exact git pins only).
- No linter (no clippy, go vet, or staticcheck equivalent).
- The test runner has no coverage, no benchmarks, no fuzzing, no name filters, and no fixtures beyond `@test`.
- LSP rename and references are text-based across files rather than semantic; diagnostics are single-file
  (imports are not resolved live). There are only two canned code actions and no inlay hints.
- Incremental compilation is coarse (whole-file hash or split-object), not query-incremental like rustc or
  package-cache-granular like Go.

## Ship-readiness defects (not just immaturity)

These are confirmed in code and tracked in `docs/gaps.md`. They are the difference between an impressive demo
and something safe to run in production, and they should be treated as blockers, not polish.

- **MSSQL driver defaults to plaintext passwords** (`encrypt=false`) and **trusts any server certificate**
  (`trustServerCertificate=true`) in `packages/nova-mssql/.../connection.nova`. Credentials over the wire in
  clear, and a MITM is accepted by default. (Sec1, Sec2)
- **MySQL caching_sha2 full-auth trusts the server RSA key over plaintext.** (Sec3)
- **NovaDB's primary query and exec path uses client-side parameter substitution, not server-side binding.**
  Verified first-hand (`packages/nova-novadb/src/typemap.nova`): `substituteParams` interpolates each value via
  `valueToSql`, and text values ARE escaped by `escapeText` (single-quote doubling `'` to `''`, quoted) with
  blobs hex-encoded by `byteaLiteral`. So classic quote-break injection is blocked, and a server-bound path
  (`queryPrepared` / `execPrepared` via Parse / Bind / Execute) exists. The accurate residual risk is narrower
  than "SQL-injectable": `escapeText` only handles the single quote, so safety depends on the NovaDB server's
  string-literal parsing (backslash escapes and standard-conforming-strings behaviour), which lives in the
  separate NovaDB repo and was not read for this audit. Correction: the earlier "SQL-injectable" label
  (inherited from gaps.md Sec4) OVERSTATED this; the honest statement is "escaped client-side but not
  server-bound, residual depends on the server". (Sec4, corrected)
- **SCRAM ServerSignature is never verified**, so a rogue server is accepted. (Sec5)
- **Connection leaks**: Postgres leaks about 64 KB of reader buffer per connection; the TLS stream leaks about
  16 KB per connection. (M1, M2)
- **The BSON ORM path truncates every `long` to 32 bits**, a numeric-fidelity defect on the ORM seam. (E1)
- **`string.parseFloat` has no exponent, Infinity, or NaN grammar** (`"1e3"` parses to 13), and `parseI64`
  returns 0 on garbage, which is a real hazard on DB float-decode paths. (E-parse)
- **`fs.Watcher` and `net.aio.sleep` are silent stubs** that deliver no events and do nothing respectively.
  (E2, E3)
- **TLS 1.3 transcript hashing is SHA-256 only**, so AES-256-GCM-SHA384-only servers fail. (E10)

## Honest caveats on the performance story

The single-core reactor numbers are real, but read them with the caveats the docs themselves state:

- The headline raw-reactor number does no request parsing (fixed response). The full async web framework is 3
  to 5 times slower (about 26.6k rps versus 75.6k on the same box), because of per-request allocation in the
  App and mediator layers.
- The M1 figure compared one Nova core against peers' 8-core numbers. That is a striking result, but it is not
  a same-core comparison.
- Multi-core scaling is unmeasured. The sweep plateaus at about 185k regardless of reactor count because the
  co-resident load generator and loopback saturate first. A real multi-core figure needs a separate
  load-generation machine.
- io_uring is readiness-emulated on a completion engine, so it is currently slower than epoll (about 65k
  versus 75.6k) and uses about 1.4 times the CPU per request. Multishot receive and SQPOLL are unbuilt
  headroom.

## Prioritised roadmap toward parity

Ranked by leverage, cheapest and highest-stakes first. None of these require new language theory.

1. **Close the security-default and injection defects.** Flip MSSQL to encrypt-by-default and verify
   certificates; make NovaDB's primary path server-bound (parameterised); verify the SCRAM ServerSignature;
   stop trusting server RSA keys over plaintext. Cheap, high stakes. (Sec1 to Sec5)
2. **Fix the connection and closure leaks.** Postgres 64 KB per connection, TLS 16 KB per connection, and the
   escaping closure environment leak. These bite any long-running server. (M1, M2, and the closure-env leak)
3. **Concurrency structural gaps.** In priority order: cancellation (a token plus structured scope), bounded
   async channels with backpressure and a channel select, then either work-stealing or at least a documented
   story for CPU-bound work across cores. Implement `Atomic<T>` for real.
4. **Standard library correctness and scaling.** A real O(n log n) sort, a linear-time or at least
   non-backtracking regex engine with the common escapes and counted repetition, 64-bit int and time, and
   honest or checked integer overflow.
5. **Type-checker soundness.** Convert the remaining fail-open decision sites to fail-closed so an untypeable
   expression is a compile error rather than a silent guess. Fix the closure-arity crash (C4) and the
   value-optional-zero collision (C10 tail).
6. **Tooling depth.** Semantic (not text-based) LSP rename and references, cross-file diagnostics, coverage and
   benchmarks in the test runner, and a basic linter. A package registry and semver resolution are larger and
   can come later.
7. **Numeric fidelity on the ORM seam.** Fix the BSON `long` to 32-bit truncation and the parseFloat grammar.

## Bottom line

Nova is at par with Go and Rust on async ergonomics and per-core network performance, ahead of both on the
narrow axis of default-on static leak and double-free checking, broadly comparable in surface across
stdlib, web, and DB, and materially behind on multicore concurrency, generics power, stdlib scaling and
correctness, tooling depth, and hardening. It is a genuinely impressive one-team language that has the shape of
a peer without yet having the depth or the proving. The path to closing the gap is engineering, and the first
steps are cheap and high-stakes: fix the security defaults and the leaks.
