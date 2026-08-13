# Nova language soundness baseline (specification vs. implementation)

This is the LIVING status record for the language: what is specified, what is implemented, and where the
implementation is unsound. It is the single source of truth for tracking soundness. The three docs have
distinct jobs and must not be merged:

- `language-specification.md` is NORMATIVE: what Nova is. It carries no status and no bugs.
- This file (`gaps.md`) is STATUS: implemented vs missing vs unsound, measured against the spec.
- `design/further-refinement.md` is the PLAN: how to close these gaps.

`design/done/execution-plan.md` and `design/done/feature-roadmap.md` are ARCHIVED and may contradict current
reality (for example the WASM claim). Do not read them as live status; reconcile any still-true content here.

## How to read the matrix

Each language feature is scored on the axes that actually determine soundness. A feature is DONE only when
its whole row is green.

- **Spec §**: the `language-specification.md` section that defines it.
- **Checker**: does the checker REJECT the invalid uses (fail-closed)? A `no` means the checker fails open
  (accepts an ill-typed program), which is the root of the crash class.
- **Codegen**: does codegen compile every VALID shape correctly? A `no` means a valid program crashes or
  miscompiles.
- **Conf +**: a positive conformance case exists (the feature works on valid input).
- **Fail -**: an `expect_fail` case exists (the invalid use is rejected).
- **Crash-regr**: an `expect_fail: compiler-crash` case guards a known crash-on-valid. Currently ZERO exist
  across the whole tree, so every known crash is unguarded against regression. This column is the highest-
  leverage gap: adding these cases is what stops a red cell silently going green.

Legend: `ok` sound / present, `NO` gap, `~` partial, `-` not applicable, `?` unverified. Gap IDs (Cx / Kx /
Mx / Ax / Sx / Ex / Tx) link to the detail sections below.

## Soundness matrix

| Feature | Spec § | Checker | Codegen | Conf + | Fail - | Crash-regr | Gaps |
|---|---|---|---|---|---|---|---|
| Primitives, sized ints | 3.1 | ok | ~ (honest-int overflow pending) | ok | ok | - | K7 |
| `string` | 3.3 | ok | ok | ok | ok | - | |
| Value vs reference structs | 3.2 | ok | ok | ok | ok | - | |
| Optionals `T?` (`T \| undefined`) | 3.4 | ~ (A1: return-optional-as-plain now checked; assign/pass C6 open) | **NO** | ok | ~ (return_optional_as_plain) | **NO** | C3, C6 |
| Error unions (`T \| E`) | 3.5 | ~ | **NO** (`T\|E\|undefined`) | ok | ~ | **NO** | C2 |
| `decimal` | 3.6 | ok | ok | ok | ok | - | |
| Containers / generics | 3.7 | ~ | **NO** (`Set<T>` erased) | ok | ~ | **NO** | C5, K2, K8 |
| Tuples | 3.7 | **NO** | **NO** | NO | NO | **NO** | C7, K8 |
| `Atomic<T>` | 3.7 / 9 | **NO** | **NO** (width by name) | ~ | NO | **NO** | C8, K2 |
| Structs / enums / traits | 3.8 | ~ | ~ (colliding, literal+NSX) | ok | ~ | **NO** | C6, C-lit, T3 |
| Trait default methods | 3.8 | - | - (unsupported) | - | - | - | T3 |
| `any` | 3.8 | ~ | **NO** (ARC bypass) | ok | NO | **NO** | K3 |
| Ownership / ARC | 4 | - | ~ (fail-open owned) | ok | - | **NO** | C1, C3, M1..M4 |
| Functions, methods, closures | 5.1 | ~ (A1: method arity now checked; closure arity C4 open) | **NO** (stored closure) | ok | ok (method_arity_mismatch) | ~ | C1(chk) done, C4 |
| Unresolved call | 5.1 / 8 | **NO** (N3) | crash no-span | - | ~ | **NO** | C2(chk) |
| `if` / `while` condition | 6.1 | ok (A1: sema requires bool, fail-closed) | miscompile | ok | ok (if_optional_condition) | ~ | C4(chk) done |
| `for` (all forms) | 6.2 | ok | ok | ok | ok | - | |
| `switch` exhaustiveness | 6.3 | **NO** | UB fall-through | ok | NO | **NO** | C5(chk) |
| `defer` / `break` / `continue` | 6.4 | - | **NO** (skipped on loop jump; no all-path defer) | ~ | NO | - | K1, E-defer |
| Modules & visibility | 8 | ~ (multi-seg hole) | ok | ok | ~ | - | S1 |
| Concurrency (channels, locks, pool) | 9 | - | **NO** (blocking-chan deadlock) | ~ | NO | - | X1..X4 |
| Serialization (json/bson) | 10 | - | **NO** (bson long trunc; json partial) | ok | NO | - | E1, E7 |
| Numeric parsing (`parse*`) | 12 | - | **NO** (parseFloat/parseI64) | ~ | NO | - | E-parse |

Two structural notes that the matrix encodes:
1. The `Checker = NO` and `Codegen = NO` cells share ONE root: both ends of the pipeline FAIL OPEN. The
   checker skips a check when it cannot type an expression (`resolveExprType(...) orelse return`); codegen
   assumes owned / `i32` when it cannot resolve a type name. Flipping both to FAIL CLOSED (unknown type is a
   hard error, not a skip or a guess) collapses most of the red cells and is the single highest-leverage fix.
2. The `Crash-regr = NO` column is empty everywhere. A segfault exits non-zero, so the conformance harness
   mistakes a crash for a normal rejection. Add `expect_fail: compiler-crash` cases for every known crash so
   the cells cannot silently go green.

---

## C. Checker soundness (accepts programs it should reject)

Root: every check is gated on the type resolving to a simple `.ident`, and any expression the checker cannot
type is silently skipped. Fix direction throughout: fail closed (an unknown type in a checked position is a
hard error).

- **C-chk-1 Method-call arity is never checked.** `type_checker.zig:671-708`. Free functions and constructors
  get an arity check; methods do not, so `b.take(1,2,3)` on a 1-arg method compiles into a mismatched call.
- **C-chk-2 Unresolved bare/method call is not a located error** (pending N3). `infer.zig:748`. Falls through
  to a codegen crash with no source span.
- **C-chk-3 `checkReturnType` skips non-`.ident`/unknown values.** `type_checker.zig:389-407`. Returning
  `string|undefined` as `string`, or any call it cannot type, is waved through into a wrong-representation
  return.
- **C-chk-4 Non-bool condition is a 4-name blocklist, not an allowlist.** `type_checker.zig:324-333`.
  `if (x)` where `x` is int/long/optional/enum is accepted.
- **C-chk-5 Switch exhaustiveness is silently skipped when the discriminant cannot be typed.**
  `type_checker.zig:893-898`. UB fall-through on a missing enum arm.
- **C-chk-6 Optional/error-union assign/pass/return is not checked** (only member-deref is), and a narrowing
  is not invalidated on reassignment. `infer.zig:1362, 189`.
- **C-chk-7 Tuples are invisible to the checker** (no `.tuple` in `resolveExprType`). Wrong-arity
  destructuring and `int + string` accepted.

## Codegen soundness (crashes / miscompiles a valid program)

Root: ARC ownership, destructor dispatch, and field/payload layout are chosen from rendered type-name STRINGS
with a fail-OPEN default (unknown name assume owned; unknown field/atomic assume `i32`).

- **C1 `erasedOwnershipDefault` returns owned for any unresolved composite name** (`arc.zig:47`): frees a
  non-pointer word.
- **C2 `T | E | undefined`** modeled by string-splitting an ErrUnion plus a primitive-only value-optional test
  (`arc.zig:1247`, `types.zig:159`): a non-primitive ok-arm value-optional segfaults.
- **C3 Destructor dispatch is name-string keyed** (`arc.zig:660-745`): an unknown name gets no free (leak) or
  the wrong struct's destructor (crash).
- **C4 `buildClosureCall` builds the callee fn-type from the call-site arity** (`expressions.zig:440-465`),
  not the stored closure's real signature: a stored multi-arg closure crashes.
- **C5 Standalone generic never reaching the mono worklist -> erased body -> LLVMVerifyError**
  (`mono.zig:265`, `declarations.zig:867`): the `Set<T>` crash.
- **C6 / C-lit `@serializable` struct-literal vs NSX layout divergence** (`expressions.zig:3510-3629`,
  field type defaults to `i32`): the literal-plus-render crash.
- **C7 `buildCallWithCasts` silently ignores an arg-count mismatch** (`llvm_codegen.zig:1264`).
- **C8 Generic/aliased atomics pick element width by name-whitelist else `i32`** (`llvm_codegen.zig:1576`):
  a 64-bit `Atomic<long>` under an alias truncates to 32 bits, an address-dependent SIGSEGV.
- **C9 Non-primitive types load as one `ptr`/`i32` word when the field type is not matched**
  (`types.zig:192`).
- **C10 [FIXED 2026-08-13] value-optional PARAMETER representation was inconsistent (raw vs boxed).** Root:
  `typeRefToString` DROPS `.optional`, so a param declared `int | undefined` was registered as `"int"` and
  got NO entry in `current_local_type_ids`, and flow-narrowing after `if (x == undefined)` recorded it as
  bare `int` in the typed IR. A narrowed/bare-seen callee then treated its value-optional param as the RAW
  value (no unbox on `??`/use), while a plain `o ?? d` callee unboxed it (expected a BOX) -- contradictory
  ABIs for one signature. Nesting compounded it: `List<int | undefined>.get()` returns
  `(int | undefined) | undefined` (box-of-box). Fix (first slice of R1/string->TypeId, uniform BOXED ABI):
  (1) populate value-optional params into `current_local_type_ids` with their real depth-carrying TypeId
  (`tidForTypeRef`, optionality preserved) at all three param sites in `declarations.zig`, so value-use
  codegen recognises the boxed slot and unboxes on `??`/comparison irrespective of narrowing; (2) in
  `coerceValoptArg`, peel a nested argument down to the PARAMETER's declared box depth (`arg_depth -
  param_depth` levels), and save/restore `suppress_valopt_unbox` around the sub-evaluation in
  `compileCallArgument` so the caller baseline is uniform across ident/call. Verified across flat/nested x
  direct/local x narrowing/non-narrowing callees; corpus case 334; full corpus + `--asan` green. Orthogonal
  and still open: a present value of `0` (value-optional-zero collision) reads as absent through this path;
  that is the separate value-optional-zero limitation, not this ABI bug.

Two takeaways: flip the fallbacks to FAIL CLOSED (unknown type -> borrowed / hard error), and add
crash-regression cases (none exist).

## K. Type-system and ARC gaps (from the earlier spec-vs-impl pass)

- **K1 `defer` skipped on `break`/`continue`** (§6.4, `statements.zig:26-41`): `releaseScopesForLoopExit`
  releases owned locals but does not run deferred statements, so a `defer` in a loop body is skipped on early
  exit.
- **K2 `Atomic<T>` unrestricted** (§3.7/9, `type_checker.zig`, `llvm_codegen.zig:1266`): `Atomic<string>` /
  `Atomic<MyStruct>` accepted; codegen falls back to 32-bit atomics -> pointer truncation + ARC bypass.
- **K3 `any` bypasses ARC** (§3.8, `type_checker.zig:1120`, `types.zig:228`): classified primitive, so no
  retain/release/destructor -> leak or double-free when a refcounted object is stored in `any`.
- **K4 Missing ARC destructors for unions** (§3.8, `arc.zig:725`): untagged unions get `null` destructor, so
  refcounted fields leak; and there is no rule preventing refcounted types inside a union.
- **K5 Missing ARC destructors for fixed-size arrays `T[N]`** (§4, `arc.zig:725`): elements leak.
- **K6 Index `[]` expressions are not type-checked** (§3.7, `type_checker.zig:615`): indexing a non-indexable
  type compiles to raw pointer arithmetic -> segfault.
- **K7 Honest 32-bit int slots + overflow trap** still pending (§3.1), the F3-5 item.
- **K8 Tuple index access (`pair.0` / `pair[0]`) unsupported** (§3.7, `infer.zig:931`): poisons inference,
  falls back to raw pointer load. (Distinct from C7: this is member/index access, C7 is destructuring.)

## M. Memory and resource leaks (server-stability)

Unbounded per-connection leaks sink a long-running server.

- **M1 `TlsStream.scratch` leaks 16 KB on EVERY TLS connection** (`asynctls.nova:34`; no `delete()`,
  `close()` frees bio+base but not scratch). Blast radius: every driver over TLS, HTTPS client, web TLS
  accept.
- **M2 Postgres `PgReader.buf` leaks 64 KB on EVERY pg connection** (`proto.nova:19`, no `delete()`). Clear
  asymmetry: mysql/mssql/novadb all free their reader buffer.
- **M3 Postgres prepared-statement cache is unbounded** (no cap, no Close/DEALLOCATE); mysql caps at 256 with
  COM_STMT_CLOSE.
- **M4 JSX variable interpolation leaks** (§7, `expressions.zig:3248`): retain with no balancing release, plus
  the 24-byte StringBuilder header box leaks on every JSX element.
- **M5 Streaming cursor poisons the pooled connection**: `queryStream` sets `conn.busy`, cleared only in
  `finish()`/`cur.close()`; an early break leaves `busy` true and `Pool.release` re-pools it unchecked, so
  the next borrower gets "connection busy" for the connection's life (`postgres.nova:385/446`,
  `pool.nova:156`; same on mysql).
- **M6 `reactorConnect` leaks the socket fd on submit failure** (`eventedio.nova:293`).

## X. Concurrency and async

- **X1 Blocking `Channel<T>` from a reactor coroutine deadlocks the reactor** (`channel.nova` over
  `concurrency.cpp:466`): parks the whole OS thread on a condvar; same-reactor producer -> permanent
  self-deadlock. REACHABLE.
- **X2 `nova_chan_send` / `AsyncLock.release` resume a waiter via the thread-local run queue**
  (`nova_sched_schedule`) instead of the owning reactor (`nova_reactor_post`): UAF + lost wakeup once channels
  or actors are wired cross-reactor. LATENT.
- **X3 `AsyncLock`** additionally has a stale-waiter-on-cancel UAF and no error-path release.
- **X4 Pool acquire-to-release and driver `busy` have no try/finally**, so IF a Nova `await` propagates an
  unwind, a leaked borrow wedges the pool at its hard cap and a stuck `busy` poisons the connection. OPEN
  QUESTION: does `await` unwind? Decides the severity of X4 and M5.

## E. Stdlib correctness (silent wrong results and stubs)

- **E-parse `string.parseFloat` has no exponent/Infinity/NaN grammar** (`string.nova:498`): `"1e3"` -> 13,
  on the float-decode path of postgres/mysql/novadb. `parseI64` returns 0 on garbage and truncates at the
  first non-digit. FIX: the `parseInt`/`parseLong`/`parseDouble` failure-surfacing family (see
  further-refinement.md).
- **E1 ORM to BSON truncates every `long` to 32 bits** (§10, `orm.nova:214` uses `entryInt(key, val as int)`;
  `entryInt64Val` is unused).
- **E7 JSON parser returns a partial node and NO error on malformed input** (`serde/json.nova`
  parseArray/parseObject/parseValue): `"[1,2,"` -> `[1,2]`, no success/failure signal.
- **E2 `fs.Watcher` is an unconditional runtime stub** (`io.cpp:403`): delivers no events on any platform.
- **E3 `net.aio.sleep(ms)` is a no-op** (`aio.nova:144`, `return 0`).
- **E4 ORM cannot bind array/nested/child columns** (`orm.nova:61`): binds empty.
- **E5 "Streaming" is not lazy** (`db.nova:467`): iterates an already-materialised ResultSet.
- **E6 `hexNibble` returns 0 for invalid hex** (pg typemap): corrupt bytea decodes wrong-but-plausible.
- **E8 GridFS metadata defaults missing length/chunkSize to 0** (mongo `gridfs.nova:163`).
- **E9 MongoDB DocSource accessors conflate absent/wrong-type with the zero value** (`document.nova:127`).
- **E10 TLS 1.3 supports only SHA-256 transcripts** (`handshake.nova:50`): AES-256-GCM-SHA384-only servers
  fail.

## Sec. Security (drivers, exploitable under default settings)

- **Sec1 CRITICAL MSSQL sends the password with NO encryption by default** (`connection.nova:42`, `encrypt`
  defaults false): LOGIN7 over plaintext, only a reversible obfuscation. Fix: default `encrypt` true.
- **Sec2 CRITICAL MSSQL `trustServerCertificate` defaults TRUE** (`connection.nova:45`): MITM even with
  `encrypt=true`. Fix: default false.
- **Sec3 HIGH MySQL caching_sha2 full-auth trusts the server-supplied RSA public key over plaintext**
  (`mysql.nova:711`): key-substitution recovers the password. Fix: RSA key-exchange only over verified TLS,
  or a pinned key.
- **Sec4 MEDIUM NovaDB primary `query`/`exec` uses client-side string interpolation** (`novadb.nova:63,85`):
  the only SQL driver whose main path is not server-bound; `escapeText` misses backslash, Decimal text is
  raw-unquoted (`1 OR 1=1` injects). Fix: route through the server-bound Parse/Bind path.
- **Sec5 MEDIUM SCRAM ServerSignature never verified and combined nonce not checked** (pg `auth.nova` ignores
  SASLFinal kind 12; mongo returns success without checking `v=`; `scram.nova:102`): a rogue server can claim
  success. Password not disclosed (one-way proof).
- **Sec6 LOW** plaintext-by-default transport (pg/mysql/novadb); `tls=true` without cert verify on
  mongo/novadb; MySQL multi-packet reassembly has no aggregate cap (OOM); x509 accepts a bare-TLD wildcard;
  the static-file `..` check is a raw substring (verify the router decodes before serve).

Verified SOUND (not re-investigated): pg/mysql/mssql bind params server-side; CSPRNG for all
keys/nonces/IVs/session ids; monotonic GCM nonce; x509 validity + SAN + fail-closed (no CN fallback); wire
length fields capped before alloc.

## T. Ecosystem, tooling, targets

- **T1 SHIP-BLOCKER mongo/novadb/btreedb/orchestrator drivers lack `queryWire`** and fail to build against
  current lang (the `Connection` trait now requires it); the flagship depends on mongo+novadb. Fix: the
  one-line `wireRowsFromResultSet` fallback each. Root cause: trait has no default methods (T3) and nothing
  gates a lang trait change against the out-of-repo drivers (T2).
- **T2 Two-copy driver trap + unpinned deps** (`main.zig:530-555`): the resolver prefers a sibling
  `packages/` copy over the `~/.nova/cache` copy apps use; dependencies are raw GitHub URLs with no lockfile
  or ref. Fix: a lockfile with pinned commit SHAs.
- **T3 Trait default methods unsupported** (§3.8): every impl must define every method, which is what makes a
  trait change a breaking change. This is a LANGUAGE gap, not just tooling.
- **T4 No `library` init template; desktop template is a single file** (`main.zig:1811`, `templates.zig`).
- **T5 LSP (nls)** now has rename, find-references, code-actions, semantic tokens, and workspace symbols on
  top of hover/goto/completion/diagnostics (`nls/src/server.zig`). References/rename are binding-accurate for
  function-locals (confined to the enclosing function's brace-matched extent); non-locals fall back to the
  cross-file whole-word match. Remaining: intra-function shadowing is not split, and cross-file binding
  resolution for globals/members is still name-based rather than resolved through the symbol table.
- **T6 WASM product build disabled + contradictory docs** (§1, `build.zig:284-301` commented out; the spec
  says "fails on trivial programs", the archived execution-plan claims 104/104). Reconcile and wire the
  product path.
- **T7 Windows** run-verified but readiness cases 192/194/195 fail (IOCP has no armRead/armWrite analogue,
  `ev/iocp.nova:201`), and `--asan`/`--arc` gates are not wired there.

---

## Graduation rule

A language feature graduates from this list only when its whole matrix row is green: specified, checker
fails-closed on its invalid uses, codegen sound for every valid shape, and gated by a positive conformance
case, an `expect_fail` negative case, and (for anything that has ever crashed) an `expect_fail:
compiler-crash` regression case. The immediate priorities, in order: the security defaults (Sec1-Sec3), the
`queryWire` ship-blocker (T1), the parse-family and BSON corruption (E-parse, E1), the two unbounded leaks
(M1, M2), then the fail-closed pass across the checker and codegen that turns the red cells green as a class.
