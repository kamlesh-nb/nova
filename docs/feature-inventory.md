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

Criterion mark: **[x]** met, and met ONLY by working code verified this session (a passing probe, a conformance
case, or a fix that was gated) / **[ ]** not met. A feature's status is SOUND ONLY when EVERY criterion is [x];
a single [ ] means the feature is not SOUND yet (PARTIAL, or UNSOUND if the unmet criterion is a confirmed
defect). INTEGRITY RULE: a criterion is NEVER marked [x] by reframing it, and is NEVER removed to make a status
pass. A criterion may be dropped only by an explicit, recorded decision that it is genuinely out of scope
(by-design), and that decision is stated, not silently applied.

Verification method (strongest wins): **probe** (compiled + run this session) / **case N** (a conformance case
gates it) / **read** (source read first-hand this session) / **swept** (broad audit sweep only; weakest;
verify before trusting). When a swept claim and a probe disagree, the probe wins.

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

Empirical triage (2026-08-20): 5 language features are genuinely fully SOUND (Error handling, Atomic,
decimal128, ARC, OSSA). Probing (running code) confirmed some things WORK that were marked broken: the
`Atomic<T>` runtime (a real codegen intercept), deep-nested generics run, switch exhaustiveness is enforced
for typed discriminants, used generic bounds are structurally enforced, and the "escaping closure environment
leak" was DISPROVEN (2M closures stay flat at 1.4 MB) - those are legitimate [x] marks because a probe
verified them. The rest of the language features are PARTIAL and their unmet criteria are NOT fixed: nested-
generic depth cap, cross-module trait default methods, monomorphic (non-erased) generic trait dispatch, typed
closure params, checked-integer overflow, an unused-bound check, the untypeable-discriminant exhaustiveness /
fail-closed edge, a heterogeneous future combinator, bounded channels + select + actor supervision, IOCP
readiness. (UPDATE 2026-08-20: worked in doc order, Monomorphisation / Traits / Generic-bounds / Enums /
Optionals are now SOUND with real fixes; the former `x ?? d` present-0 DEFECT is FIXED via a codegen
narrowed-present tracker, not a representational change.) Marking any remaining criterion [x] requires an
actual code fix that a probe or gate verifies, not a reframing.

### Monomorphisation ; SOUND ; case + probe

- [x] Concrete generic instantiations produce correct code (case-gated).
- [x] Method-level generics tracked separately (`List<T>.map<U>`).
- [x] Field-type and return-type recursion instantiated (the `Set<T>{map:Map<T,bool>}` fix).
- [x] Deep nesting does not crash; falls back to the erased body and runs (probe: depth-4 runs).
- [x] No `LLVMVerifyError` from a standalone generic that never reached the worklist.
- [x] Nested generics beyond depth 2 are eagerly monomorphised, not left to the erased fallback (FIXED: the
      `max_depth=2` cap now applies ONLY to the SPECULATIVE method-return-type cascade -- the thing that
      balloons `chunk(): List<List<T>>` into dead 16-deep nestings -- via a `noteImpl(t, speculative)` split
      in `mono.zig`. An EXPLICITLY-used type (a seed from `expr_types`, its structural args, and struct
      fields) is instantiated at ANY depth. Proven both ways on `List<List<List<int>>>`: old binary emits 0
      `List_List_List_i32_*` bodies (erased), new binary emits the full monomorphised set; case 390 runs the
      value-optional `get()` path that the erased layout mishandles. Corpus 399/402, baseline unchanged, no
      instantiation bloat -- the speculative cascade stays capped).

### Traits and dynamic dispatch ; SOUND ; case + probe

- [x] Dynamic dispatch via fat pointers `{struct_ptr, vtable}`; vtable slot 0 is the destructor.
- [x] Checked downcast (`x as T`) traps on a wrong concrete type.
- [x] Trait default methods work cross-module (FIXED: `pipeline.expandTraitDefaults` re-runs the default-body
      copy on the fully-merged decls; probe: a struct in one module inherits a default from a trait in another;
      corpus 395/398, same-module case 301 green).
- [x] Generic trait dispatch is monomorphic, not type-erased (FIXED: each `impl Producer<M>` now names its
      vtable per-M -- `_vtable_IntMaker_Producer_i32`, `_vtable_StrMaker_Producer_string` -- instead of a single
      M-erased `_vtable_..._Producer`. The M comes from the struct's own impl `type_args` in `getGlobalVTable`,
      so trait-object construction AND the downcast check derive the SAME name and never diverge; a plain
      non-generic trait has no type_args so its vtable name is byte-identical (no regression). Proven: IR shows
      the per-M names; case 391 dispatches `Producer<int>`/`Producer<string>` through trait values correctly;
      corpus 400/403 with downcast (71), per-instantiation (299), and generic-trait (55/56/57/120) all green).

### Generic bounds (`where T: Bound`) ; SOUND ; case + probe

- [x] `where` clauses parse.
- [x] A generic body that calls a bounded method is rejected when instantiated with a type lacking it (probe:
      structural dispatch catches it; `totalArea<Sq>` compiles, a type without the method errors).
- [x] An UNUSED declared bound is enforced (FIXED: the `where` clause is now CAPTURED into the AST
      (`ast.WhereBound`, parser `parseWhereClause`) instead of discarded, and the type checker rejects an
      explicit type argument that is a known struct not declaring a known bound trait even when the body never
      calls the method (`checkGenericBounds`, nominal via `structImplementsTrait`). Conservative: primitives /
      type-parameters / unknown names / unknown traits are not newly rejected. Gated: positive case 389 +
      negative `expect_fail/unused_bound_violation.nova`; corpus 398/401, baseline unchanged).

### Enums and pattern matching ; SOUND ; case + probe

- [x] Payload-less, single-payload, tuple-form, and struct-form variants.
- [x] `switch` with destructuring binds payloads.
- [x] Case guards (`case v if cond`).
- [x] ARC destructors run for refcounted enum payloads.
- [x] A non-exhaustive switch on a typed enum is a compile error (probe: "variant not handled").
- [x] Exhaustiveness is enforced even when the discriminant type cannot be resolved (FIXED: when
      `resolveExprType` cannot type the discriminant (e.g. `switch (list[i])` -- an `.index` expression the
      resolver leaves untyped), `checkSwitch` now recovers the enum from the case values (`recoverEnumFromCases`)
      and runs a coverage-only check (`checkEnumCoverageOnly`) instead of skipping exhaustiveness. Additive: an
      integer/other switch (literal case values) never triggers it. Proven before/after: the old binary
      compiles an incomplete `switch (list[i])` silently (fail-open), the new binary rejects it at type-check
      ("Enum variant 'Color.Blue' not handled"). Gated: `expect_fail/untypeable_switch_nonexhaustive.nova`;
      corpus baseline unchanged. NB: a SEPARATE pre-existing codegen bug -- a COMPLETE `switch (list[i])` on an
      enum hits an `LLVMVerificationError` -- was discovered here and is logged in the worklist; it is not part
      of this criterion, which is a type-check-time property.)

### Error handling (`T | E`, `try`, `catch`, `errdefer`) ; SOUND ; case

- [x] `try` propagates the error arm to the enclosing function.
- [x] `catch` handles; both arms unify to one type.
- [x] `errdefer` runs only on the error path, LIFO.
- [x] `T | E | undefined` composes optional over error.

### Optionals and narrowing (`T | undefined`) ; SOUND ; case + probe

- [x] Member access through an optional is guarded, not a null deref.
- [x] `if (x != undefined)` narrows `x` to its inner type in the branch.
- [x] Reassigning a narrowed variable invalidates the narrowing.
- [x] Nested optionals from generics (`Map<K, int|undefined>`) are handled.
- [x] `x ?? d` returns the present value for a present non-zero, and the default for genuine absent.
- [x] `x ?? d` returns the present value for a present ZERO after narrowing (FIXED, see below).

### `x ?? d` on a narrowed present 0 ; SOUND ; case + probe

- [x] A present `0` in a narrowed value-optional coalesces to `0`, not the default (FIXED). Root: the `??`
  presence test is `left != 0`; a RAW value-optional stores a present 0 identically to the absent sentinel, so
  a present 0 read as absent. The prior three site-local guards regressed serde/DI/try because they could not
  tell a narrowed-present raw from a genuinely-optional raw. The fix supplies the missing signal WITHOUT a
  representational change: codegen tracks locals proven present by an enclosing `if (x != undefined)` (a scoped
  `narrowed_present` set, populated per-branch in `statements.zig` and invalidated on reassignment), and the
  `??` operator short-circuits a narrowed-present RAW PRIMITIVE left to its present value. Tightly scoped: the
  BOXED case already tests the box pointer correctly, and a pointer-typed inner has null==0==absent with no
  valid present 0, so only the raw-primitive case is touched (no ARC surface). Gated: case 392 (present-0 ->
  0, genuine-absent -> default, reassign-to-absent -> default); corpus 402/405, baseline unchanged, and the
  serde/DI/try canaries that broke the prior attempts stay green.

### Closures / lambdas ; SOUND ; case + probe

- [x] A stored / aliased multi-argument closure calls correctly (`let g = f; g(3,4)`).
- [x] Per-instance heap environments; loop captures are independent.
- [x] Creating and dropping a closure reclaims its memory (no leak, no unbounded growth). Empirically verified:
      2,000,000 closures created + dropped (List capture and owned-string capture) stay flat at ~1.2 to 1.4 MB
      versus 26 MB for a genuinely-growing 2M-element List. This CORRECTS an earlier UNSOUND leak mark: the
      measurement disproves it (`leaks`/LSan also report 0). Lesson: measure, do not infer from the alloc call.
- [x] A mismatched-arity/type stored closure is caught (FIXED: the checker now tracks a closure's signature
      per local -- `let f = (x:int) => ...`, and `let g = f` aliases it -- in a `closure_sigs` map, and a call
      `f(args)` is ARITY-checked always and TYPE-checked for its explicitly-typed params. An untyped param
      still infers from the call site (so `list.map((x) => ...)` is NOT rejected), which is the intended
      behaviour, not a gap -- requiring types would break ~50 legitimate infer-from-context closures. Gated:
      case 393 (typed + aliased + untyped-infer all compile/run) and negative
      `expect_fail/closure_arity_mismatch.nova` ("closure 'g' expects 1 argument(s), got 2"); corpus 404/407,
      baseline unchanged.

### Integers (`int` 32-bit, `long` 64-bit) ; SOUND ; case + probe

- [x] `int` is 32-bit two's-complement with defined wraparound; `long` is 64-bit.
- [x] Address arithmetic uses `long`/`ptr` (no 32-bit truncation of heap addresses).
- [x] A checked / overflow-detecting arithmetic mode exists (STALE MARK CORRECTED by a probe: the claim "no
      way to detect overflow" was wrong). `math.checked{Add,Sub,Mul}Int` return `int | undefined` -- undefined
      on overflow -- by computing in 64-bit and range-checking; `checked{Add,Sub,Mul}Long` detect 64-bit
      overflow directly; `sat{Add,...}Int` saturate (clamp) instead. The default `+ - *` still wrap (defined
      behaviour, kept); these are the opt-in honest-overflow path, and they compose with `??`. Gated: case 394
      (INT_MAX+1 / INT_MIN-1 / 10^10 mul / LONG_MAX+1 all -> undefined; saturating clamps; in-range returns the
      value).

### `Atomic<T>` ; SOUND ; case + probe

- [x] An invalid atomic element type (`Atomic<string>`) is rejected at compile time.
- [x] The runtime works: `load`/`store`/`compareAndSwap`/`add`/`sub`/`delete` for `int` (i32) and `long`
      (i64). Implemented as a codegen intercept (`compileAtomicCall`) over the runtime `nova_atomic_*_i32/i64`,
      not the stub stdlib body. Gated by case 31_atomics (7/7) and probed (int + long) ASAN-clean. The earlier
      "stub" mark read the dead stdlib body; the codegen path is real.

### `decimal128` ; SOUND ; case

- [x] Arithmetic, parse, and round-trip through JSON / YAML / BSON with fidelity.
- [x] No implicit int/decimal coercion.

### Type-checker fail-closed ; PARTIAL ; probe

- [x] Method-call arity is checked; unresolved calls are located errors.
- [x] Non-bool `if`/`while` conditions are rejected (probe: `if (s)` on a string errors).
- [x] Optional/error assigned or passed where a plain value is required is rejected (probe: both error).
- [x] Return-type mismatch is rejected (probe: returning a string from an int fn errors).
- [ ] Every checked position fails closed for a genuinely-untypeable expression (the remaining
      `resolveExprType(...) orelse return` sites). Defence-in-depth, not a live bug. BLOCKED on resolver
      completeness (#174); PROGRESS + precise diagnosis this session:
      - Resolver step 1 DONE (committed): `resolveExprType` now handles `.unary` (`!` -> bool, `-`/`~` ->
        numeric), `.index` (List/Map/array element, string -> int), and `.tuple`. Net-positive -- it also
        EXPOSED and fixed a real latent stdlib bug (`net/eventedio` returned a bare `-1` where a `ReactorStream`
        was declared). Corpus stayed 406/409.
      - Flipping the condition site to fail-closed STILL regresses ~all cases (351). Diagnosed: it is NOT the
        case bodies (even `00_smoke`'s `i < 5` resolves to bool). The dominant residual cause is a handful of
        `.call`-kind conditions in the STDLIB (imported by every case) whose method-call RETURN TYPE the
        resolver cannot determine -- resolving those needs the receiver-type cascade (a value's type ->
        its method's declared return), which is exactly the deep typed-IR-accuracy work of #174. So the flip
        breaks the stdlib and fans out to all cases. Kept [ ] honestly; the path forward is `.call`/method
        return-type resolution, tracked under #174.

### async / await ; SOUND ; case

- [x] `async fn` compiles to an LLVM coroutine; `spawn` returns a future; `await` joins.
- [x] Function colouring enforced (`await`/`spawn` only inside `async fn`).
- [x] `when_all` / `select` over a homogeneous future list.
- [x] Heterogeneous-type combinator (`join!`-style) (ADDED: `async_util.join2<A,B>` / `join3<A,B,C>` await
      futures of DIFFERENT types together and return a tuple, each result keeping its own type -- `let (a, b)
      = await join2<A,B>(spawn fa(), spawn fb())`. Pure stdlib (generic async + tuple return, no codegen
      change). Gated: case 395 (join2 `(int,string)` and join3 `(int,string,int)` return correct typed values);
      corpus baseline unchanged, only the 3 known failures).

### Reactor (kqueue / epoll / io_uring / IOCP) ; PARTIAL ; case

- [x] kqueue / epoll / io_uring / IOCP run-verified against the conformance corpus.
- [x] Deadlines / timeouts are reactor-native on every backend.
- [ ] IOCP readiness cases 192/194/195 pass (open). PLATFORM-BLOCKED on this checkout: IOCP is the WINDOWS
      backend; these cases can only be run-verified on a Windows host (this is macOS/kqueue). Not falsifiable
      here, so left [ ] rather than assumed.
- [ ] io_uring uses multishot recv / SQPOLL (currently readiness-emulated, slower than epoll). PLATFORM-BLOCKED:
      io_uring is a LINUX backend and this is a throughput property that needs a Linux host + benchmark to
      verify; cannot be done or measured on macOS.

### Channels and actors ; SOUND ; case

- [x] A blocking cross-thread `Channel<T>` (buffered) works.
- [x] An async channel (reactor-aware) works.
- [x] Actor mailboxes with `async receive`.
- [x] Bounded async channel with backpressure (ADDED: `asyncchan.AsyncChannel<T>` -- a sender parks when the
      buffer is full, a receiver parks when empty; pure Nova over the single-reactor park/resume, like
      AsyncLock. Case 396: a capacity-2 channel carries 10 values producer->consumer, forcing backpressure).
- [x] `select` over channel operations (ADDED: `asyncchan.selectRecv<T>(channels)` parks on every channel and
      wakes when any delivers, returning its index -- the channel analogue of `selectAny` over futures. Case
      398: delivery only on the 2nd channel wakes the select and it picks index 1).
- [x] Actor supervision / restart / registry (ADDED to `actor.nova`: `ActorRegistry` resolves an actor by
      name; `Supervisor<M>` runs a `SupervisedBehavior<M>` and RESTARTS it (reset + count) on a fault, up to
      maxRestarts, then stops it -- the one-for-one "let it crash" strategy. Case 399: a behavior that faults
      on a poison message is restarted twice, keeps working in between, then stops when the budget is spent;
      the registry registers/looks-up/unregisters by name).

### ARC memory management ; SOUND ; case + asan

- [x] Retain/release inserted by codegen; destructors free owned objects (ASAN-clean corpus).
- [x] struct = value, class = reference, with inline nested value storage.
- [x] Value-semantics escape channels closed (return/serde/type-param/trait/container-COW).

### OSSA static leak / double-free verifier ; SOUND ; case + gate

- [x] Proves every owned value is consumed exactly once on covered functions (leak / double-free /
      use-after-consume / path-imbalance).
- [x] Default-on and fail-closed; rejects a proven imbalance at compile time.
- [x] 99-100% corpus coverage; reassign deferral bucket is 0 (if/loop/switch/break/continue via phis).
- Scope note (not a criterion): this is a compiler-correctness ARC-balance self-check, not a Rust-style borrow
  checker.

---

# Stream 2: Standard library

### Collections (Map / Set / List) ; SOUND ; case

- [x] Map/Set are a real open-addressing hash table (tombstones, resize).
- [x] List has a rich functional API (map/filter/reduce/slice/etc.).
- [x] `List.sort` / `sortBy` are O(n log n) (FIXED: in-place heapsort, was insertion sort O(n^2)). Swaps go
      through a new ARC-neutral `RawBuffer.swap` (raw byte swap of the two slots -- no retain, no drop -- which
      also fixed the same latent hazard in `List.reverse`). Gated: case 400 (1000-element shuffle, a
      2000-element reverse worst case, descending + sortBy) on scalar element types.
- [x] Sorting a List of OWNED REFERENCES (`List<string>`) with a comparator works (FIXED). It used to
      crash -- a `(T,T)->int` comparator called with owned-reference args inside `List<T>.sort` was handed a
      garbage pointer (the old insertion sort crashed identically). Root: passing `self.data.at(x)` (which
      RETAINS an owned element) DIRECTLY as a fn-pointer argument mishandles the temporary's ARC in this
      generic context. Fix: bind each `at()` result to a LOCAL before the comparator/key call (in
      `heapSiftDown`/`heapSiftDownBy`). Gated: case 405 (string sort, sortBy by length, a 100-element
      sorted-order check) on an ASAN build.

### Strings and text ; PARTIAL ; case

- [x] Complete byte-oriented API (split/join/slice/trim/replace/case/compare).
- [x] UTF-8 codepoint decode/encode.
- [ ] Unicode normalisation / grapheme / collation / case-fold (codepoint-level only). LARGE: requires
      shipping the Unicode data tables (NFC/NFD decomposition, grapheme-break, case-fold, collation weights) --
      a multi-day data + algorithm effort, out of scope for an incremental pass. Left [ ] honestly.

### Regex ; SOUND ; case

- [x] Alternation, char classes, anchors, `* + ?`, capture groups, find/replace.
- [x] Common escapes and counted repetition (`\d` `\w` `\b` `{n,m}`, lazy quantifiers). `\d \D \w \W \s \S`,
      `{n,m}` (parseBrace) already existed; ADDED the missing `\b`/`\B` word-boundary assertions (OP_BOUND,
      zero-width; they used to match a literal `b`, case 402) AND real lazy quantifiers `*? +? ??` (the parser
      never consumed the trailing `?`, so `.+?` had compiled as greedy-`+` then a literal `?`; now `starLazy`/
      `plusLazy`/`optLazy` swap the SPLIT priority so the exit branch is preferred). Cases 402, 406.
- [x] Linear-time (no catastrophic backtracking). REWROTE the matcher as a **Pike VM**: Thompson-NFA threads
      run in lockstep, one input position at a time, with a per-position sparse-set pc-dedup (`mark`/`gen`) so
      at most `prog.size()` threads are live per position -> O(n*m). The old recursive `vmMatch` re-explored
      SPLIT branches exponentially; patterns like `(a*)*c`, `(a+)+$` over a long run of `a` now terminate in
      bounded work. Captures, alternation priority (leftmost-first) and lazy quantifiers are preserved
      (verified against the greedy-backtracking `<(.+)>` -> `"a><b"` case). Case 406 (6 assertions incl. two
      catastrophic-backtracking terminators); corpus 417/420 (3 baseline fails).

### Serialisation (JSON / YAML / BSON) ; PARTIAL ; case

- [x] Parse and serialise with numeric fidelity (int fast-path, decimals as text).
- [x] Malformed input sets a failed flag (no silent partial parse).
- [ ] YAML is full 1.2 (subset today: no verified merge keys / complex tags). LARGE: full YAML 1.2 (anchors/aliases across the doc, merge keys, the complex tag + schema resolution rules, flow/block edge cases) is a substantial parser project. Left [ ] honestly. JSON/BSON are complete; YAML is the subset gap.

### Crypto and TLS ; PARTIAL (unaudited) ; case

- [x] SHA / AES-GCM / ChaCha20-Poly1305 / P-256 / P-384 / X25519 / RSA, KAT + differential tested.
- [x] TLS 1.3 client + server with 0-RTT, resumption, mTLS; TLS 1.2 client.
- [ ] SHA-384 transcript (AES-256-GCM-SHA384-only servers currently fail). MEDIUM but security-critical + not verifiable on this host (no SHA384-only server); deferred rather than changed blind in the TLS state machine.
- [ ] Independent security audit (hand-rolled, unaudited). IMPOSSIBLE for me to satisfy: an INDEPENDENT third-party audit is by definition external work, not something the implementer can perform. This criterion can only be closed by commissioning an audit -- so Crypto/TLS cannot be marked SOUND by code changes alone.

### Compression (deflate / gzip) ; SOUND ; case

- [x] RFC-1951 decoder, byte-exact against system gzip.
- [x] Encoder emits dynamic Huffman + lazy matching (STALE MARK corrected by a probe -- it is NOT fixed-Huffman
      greedy). The encoder chooses the smallest of stored / fixed / DYNAMIC (BTYPE=10) per block
      (deflate.nova:1115-1123) and uses a dual-hash LAZY matcher (Go compress/flate level-6 model,
      deflate.nova:644, `prevLen`). Case 401: a byte-exact round trip at >20x ratio (only dynamic + good
      matching reaches it) plus tiny/empty round trips.

### HTTP / web framework ; PARTIAL ; case

- [x] HTTP/1.1 server + client, typed path params, DI, mediator, full middleware, hypermedia/SSE.
- [ ] HTTP/2 or HTTP/3 (HTTP/1.1 only). LARGE: HTTP/2 is a new framing layer (HPACK header compression, stream multiplexing, flow control, priority) -- a substantial protocol implementation. Left [ ] honestly.

### datetime ; SOUND ; case

- [x] ISO-8601 / RFC-3339 parse, format, and arithmetic.
- [x] 64-bit epoch (no Year-2038 wrap). The epoch type is `long` across the whole datetime API
      (now/parse/format/add*/dateDiff/*Iso), with `SECONDS_PER_MINUTE`/`MINUTES_PER_HOUR`/`HOURS_PER_DAY` as
      `long` and small date components cast to int only at the wall-clock boundary. `now()` = `nowNs()/1e9`.
      Case 403: a round trip of an instant beyond 2038 plus 64-bit arithmetic/diff.
- [x] Timezone database (DST-aware; no longer treats wall-clock as UTC). `tz.nova` is a compact named-zone db
      (UTC, US/EU/AU/India/JP/CN zones) with the current-era US/EU/Australia DST rules: `offsetAt(zone,
      utcEpoch)` returns the correct DST-aware offset (transition instants via nth-weekday-of-month), and
      `toLocal`/`formatInZone` render a UTC instant as the zone's wall clock. Not the full IANA historical
      dataset (pre-2007 rules, micro-zones, leap seconds) but a genuine, correct tz facility. Case 404 (US DST
      spring-forward/fall-back, EU vs no-DST zones, to-local wall clock).

---

# Stream 3: Database drivers (the `db` seam)

### Wire protocols (pg / mysql / mssql / mongo) ; PARTIAL ; read

- [x] Real binary protocols, server-side prepared statements, transactions.
- [x] Connection pooling with idle/open caps and lifetime eviction.
- [ ] Micro-ORM has relations / migrations / query builder (data-mapper only).

### BSON ORM `long` fidelity ; SOUND ; case + probe

- [x] The ORM write path preserves 64-bit `long` (FIXED: `BsonSink.putInt` stores int32 when the value fits
      and int64 otherwise, instead of `val as int`). Probe + case 388: `5_000_000_000` round-trips as int64
      (type 18, correct hi/lo); a small value stays int32 (type 16); BSON cases 51/90/161 unaffected.

### MSSQL transport defaults ; SOUND ; case + probe

- [x] Encryption is on by default (FIXED: `connection.parse` now `encrypt=true` unless `?encrypt=false`).
- [x] The server certificate is verified by default (FIXED: `trustCert=false` unless `?trustServerCertificate=true`).
- Probe `nova-mssql/tests/111_connection_secure.nova`: a plain connection string yields `encrypt=true` /
  `trustCert=false`; explicit `?encrypt=false&trustServerCertificate=true` is honoured. Matches modern
  drivers (.NET SqlClient encrypt=true default). Committed nova-mssql 23b2c79.

### MySQL / SCRAM auth trust ; UNSOUND ; swept

- [ ] MySQL caching_sha2 does not send the password against an unverified server RSA key over plaintext.
- [ ] The SCRAM ServerSignature is verified (currently never checked; rogue-server accept).

### Per-connection buffer leaks ; UNSOUND ; swept

- [ ] Postgres does not leak its ~64 KB reader buffer per connection.
- [ ] TlsStream does not leak ~16 KB per connection.

---

# Stream 4: Tooling

### Compiler + build ; PARTIAL ; build

- [x] Cross-compilation to linux / macos / windows produces real binaries.
- [x] Per-file object caching skips unchanged files.
- [ ] Incremental compilation is query-granular (currently coarse file-hash / split-object).

### Package manager ; PARTIAL ; read

- [x] Git-pin dependency resolution with a lockfile.
- [x] A package's own module wins over a same-named sibling/cached package (FIXED lang 6c14e13: import
      resolution now checks the CWD/package-root `./<mod>.nova` + `./src/<mod>.nova` as the final
      importer-relative step, before the global scans. Previously a bare-filename or `tests/`-relative importer
      fell through to `~/.nova/cache` and `import connection` could bind to a DIFFERENT package's module, e.g.
      mssql resolving nova-postgres's `ConnectionOptions` -> `FieldNotFound`. Corpus 396/399, baseline unchanged).
- [ ] A central registry / discovery.
- [ ] Semver range resolution and version unification.

### LSP (`nls`) ; PARTIAL ; read

- [x] Completion, hover, definition, symbols, semantic tokens.
- [ ] Rename / references are semantic cross-file (currently text-based for globals).
- [ ] Cross-file (import-resolved) diagnostics (currently single-file).

### Debugger ; PARTIAL ; read

- [x] DWARF line tables + DITypes, lldb-dap, data formatters for List/Map/Set/struct.
- [ ] Non-macOS wiring and full formatter coverage.

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

### Replication safety ; PARTIAL ; case

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
- [ ] Write scalability beyond ~5 writers (deliberate ceiling today).

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

### proxyd data plane (LB, pool, discovery) ; PARTIAL (logic) ; case

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

### Leader lease (fencing epochs) ; PARTIAL (logic) ; case

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

### Rolling upgrade + HA membership ; PARTIAL (simulated) ; case

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

1. ~~`x ?? d` on a narrowed present 0.~~ FIXED (codegen narrowed-present tracker, case 392).
2. Type-checker fully fail-closed (the remaining `orelse return` sites).
2b. Codegen: a COMPLETE `switch (list[i])` on an enum (subscript discriminant) hits an `LLVMVerificationError`
   (discovered while gating the exhaustiveness fix). Subscript-of-enum feeding a switch mis-lowers; the
   incomplete case is now caught at type-check, but the complete case should codegen and run.
   (The "escaping closure environment leak" was investigated and DISPROVEN empirically this session; it is not a
   defect. The single-file `nova x -o out` build for `List` programs was fixed as a byproduct.)

Drivers: 4. ~~BSON ORM `long` truncation.~~ FIXED (lang 6e83b1b, case 388). 5. ~~MSSQL secure-by-default transport.~~ FIXED (nova-mssql 23b2c79, test 111). 6. MySQL RSA-over-plaintext and unverified SCRAM signature. 7. pg / TLS per-connection buffer leaks. 8. Driver-package source/test skew (exposed once import resolution was fixed): nova-mysql `codec`
arity mismatch (`buildStmtPrepare` / a 2-vs-3-arg call in tests/109); nova-postgres mock `EchoConn`
missing the `Connection.queryWire` trait method (tests/105). Pre-existing package bugs, not language.

NovaDB: 8. SQL silent-wrong (ORDER BY sort, typed storage, DISTINCT/UNIQUE/FK enforcement).

Orchestrator: 9. Offline gate reproducibility (`queryWire` drift + async-test crashes) ; a prerequisite for trusting the rest. 10. Leader-lease live create-race split-brain.

The best-proven parts of the platform are NovaDB durability/crash-recovery and replication safety, and the
language's ARC + OSSA verifier. The least-proven are the orchestrator paths that are green only over an
in-process simulation. When we work an item, "done" means every acceptance criterion for that feature is [x],
with the stated test as the gate.
