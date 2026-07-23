# Nova Language — Production-Readiness Roadmap

> ## ⚠️ SUPERSEDED IN PART — READ `beta-readiness-plan.md` FIRST (2026-07-17)
>
> The **Beta criteria in §4 remain the bar** and are still correct. The **grades table (§1) and much
> of the sequencing are STALE** — the repo moved well past this doc. Measured 2026-07-17:
> - **"Runtime (C) / Fragile"** — false. The C++20 runtime is live: Boost.Asio, multi-core, LLVM
>   coroutines, async/await, wolfSSL TLS **verified fail-closed** against the real network.
> - **"Crypto / Fake"** — false. Real wolfCrypt; `sha256("abc")` returns the correct KAT.
> - **A7 `int` = 64** — superseded: **`int` = 32** shipped (`1f26aa8`).
> - **A8 "add string interpolation" + `format(fmt, ...)`** — Nova has had ES6 template strings all
>   along; `format` was explicitly rejected (evolution plan L2).
> - **A3 "arg-count check blocked"** — false, it is enforced (`wrong_arg_count.nova`).
> - **A4 floats** — done. **E1 spec rewrite** — done (L0).
> - **C7 regex "build a Thompson NFA"** — superseded by Boost.Regex (evolution plan L5).
> - **The "string heap corruption" blocker was MISDIAGNOSED** — it was a `func_map` suffix-scan
>   resolution bug, not string ARC. Misfiled for months.
>
> `docs/design/` (F1–F5) is the current foundation program and recategorizes several items here as
> symptoms of one root cause (no typed IR). **Sequencing of record: `beta-readiness-plan.md`.**


Master plan to take Nova from its current state to a production-usable language: stackful C++20
runtime, closed compiler gaps, and a production-grade standard library (collections, text, serde,
web, tcp). Derived from a full code audit (Aug 2026), not the stale `specs.md`.

---

## 1. Where Nova is today (audited, honest grades)

| Area | Grade | The disqualifiers |
|---|---|---|
| Language core (parser+codegen) | **Alpha** | Broad, working surface (structs, tagged enums, closures, exceptions, fibers, JSX, real LLVM backend) |
| Type checker | **Advisory only** | No arg/arity/return/condition checks; numeric+`any` free-for-all; generics erased at parse time |
| Primitive types | **Unsound** | `i32`/`int`/`u32` all alias one `val_type` that is **i64 native / i32 wasm** → `i32` is not 32-bit and the *same source has different arithmetic per target*; unsigned isn't unsigned (→ A7) |
| Crypto | **Fake** | `nova_sha256`/`nova_md5` are stubs returning `""` while their `@test` asserts a real digest; wolfSSL is vendored+linked but unused (→ C6) |
| Runtime (C) | **Fragile** | Fiber-on-two-threads race, leaked `poll_head`, single-thread reactor, TLS verify disabled, busy-waits |
| Collections | **Alpha** | Map infinite-loop under churn, Array broken beyond i32, element leaks, ~half the API missing |
| String / text | **Alpha** | ASCII-only (no UTF-8), no formatting, unsafe numeric parsing |
| Serde (json/yaml/bson) | **Prototype** | JSON escapes don't round-trip, no floats anywhere, BSON unexported |
| Web framework | **Prototype** | 8 KB single-read server, middleware is dead code, no routing in-path, insecure sessions/CSRF |
| TCP / TLS | **Alpha / insecure** | Works for small plaintext payloads; TLS cert verification disabled |

**Overall today: Alpha.** Impressive breadth, but the core type system is unsound, the runtime has
data races, and the "production" library pieces are naive or scaffolds.

**Critical insight — the ordering constraint:** many stdlib gaps are actually **blocked on the
compiler**. You cannot make collections/serde production-ready without first fixing generics
(monomorphization by size), floats, and `Hash`/`Eq` traits; and the web framework is unsafe partly
because of the closure-capture-via-globals bug. **Compiler foundations must lead.**

---

## 2. Workstreams (in dependency order)

### A. Compiler foundations — *must lead; everything depends on this*
- **A1. Real closure environments.** ✅ **IMPLEMENTED.** Replaced `captured_globals`
  global-promotion (shared mutable global → cross-instance corruption) with per-instance heap
  environments. Closures are now a heap box `{fn_ptr, env}`; each `__lambda_N` takes a hidden
  leading `env` param; captures are snapshotted into `env` at creation and read/written via env
  slots; indirect calls unpack the box (`buildClosureCall`). Verified by
  `conformance/cases/06_closures_advanced.nova` (returned closures independent, loop-capture
  independent, multi-variable capture) + `04`/`05` regression guards — 7/7 corpus green.
  **Remaining (follow-up):** env/box use `nova_bytes_alloc_persistent` (they leak, same as the old
  scheme — no regression) → add ARC on environments + retain captured ref-counted values; the old
  `captured_globals` code path is now dormant (always-empty map) and can be deleted; deeply nested
  closures not exhaustively tested.
  - *(historical)* **Confirmed bug** (was `conformance/acceptance_a1/closure_capture.nova`, now
    promoted into `06_closures_advanced.nova`):
    `make_adder(5)` then `make_adder(9)` → `add5(1)` returns **10, not 6** — both closures read
    the same promoted global `make_adder_n`.
  - **Design (heap environment):**
    1. Closure value becomes a 16-byte heap box `{fn_ptr:i64, env:i64}` (i64 pointer to it),
       replacing the bare fn-ptr at `expressions.zig:1253`.
    2. Each `__lambda_N` gains a hidden leading `env` param (special-case the uniform prototype
       gen in `declarations.zig` and the closure-call dispatch).
    3. At closure creation, alloc an env struct, **snapshot each captured var's current value**
       into it (ordered captured-name→offset layout), store fn_ptr+env into the box.
    4. Lambda body reads captured `n` from `env[offset]` instead of the global
       (`expressions.zig:64-96`); capture detection at `llvm_codegen.zig:1710` supplies the layout.
    5. Call dispatch (`expressions.zig:680,726`): load fn_ptr+env from the box, call
       `fn_ptr(env, args)`.
    6. ARC: box + env are heap objects (retain on store, release on scope exit); ref-counted
       captured values retained into env and released by an env destructor. Remove the
       `captured_globals` leak-skip in `arc.zig:164-168` once envs own the values.
  - Guarded by `conformance/cases/04_closures.nova` + `05_closures_capture.nova` (must stay green).
- **A2. Generics through the AST → monomorphization.**
  - ✅ **Increment 1 (done): carry type params through the AST.** `FunctionDecl`/`StructDecl` now
    have a `type_params: []const []const u8` field (default empty), populated by the parser instead
    of being discarded (`parser.zig` fn/struct decls). Additive — behavior unchanged; verified by
    `conformance/cases/07_generics.nova` (multi-param `Pair<A,B>` with mixed fields + generic
    `identity<T>`) and the full 8-case corpus staying green. Note: today's generics use type
    **erasure + uniform boxed (i64) representation**, which is why `List<i32>`/`Pair<i32,string>`
    already work; type params were previously thrown away at parse time.
  - **Increment 2 (next): use the type params — LARGER than it looks; scope carefully.**
    Architecture confirmed: generics today are **type erasure + one uniform boxed (i64) body per
    generic** (`substituteGenericArgs` only string-substitutes placeholders; no per-instantiation
    codegen). Implications:
    - **`size_of<T>` / unboxing / real monomorphization** requires *adding a monomorphization pass*
      (generate specialized bodies per instantiation) — a big, invasive codegen change. Not a
      quick win. Note `array.nova` is **dead code** (unused), so its `elem_size=4` bug is moot —
      the fix is to box like `List` or delete it (a C1 stdlib cleanup, not a compiler task).
    - **Generic type checking (arity/bounds)** needs prep first: the type checker (`type_checker.zig`)
      has no functions map (only `structs`), no recursive expression-checking walk, and
      `generic_call` covers many forms (`List<T>()`, `identity<T>()`, `Atomic<T>`, method calls) —
      a check must handle all without false positives. **Also needs a negative-test harness**
      (expected-compile-failure cases) in `conformance/` to verify a check that rejects code.
    - **`Hash`/`Eq` trait dispatch** for Map/Set — depends on real trait-method dispatch on type
      params; medium-large.
    Recommended order for increment 2: (a) add negative-test harness → (b) functions map + expr
    walk in the checker → (c) arity/bounds checking → (d) monomorphization pass → (e) Hash/Eq.
    - ✅ **Step (a) done: negative-test harness.** `conformance/expect_fail/*.nova` must fail to
      compile (runner asserts rejection); seeded with `undefined_variable`/`undefined_function`.
      `expect_fail/PENDING.md` captures the checks that *should* fail but don't yet.
    - ✅ **Steps (b)+(c) done: checker infrastructure + generic arity check.** Added a `functions`
      map and a recursive `checkExpr` walk to `type_checker.zig` (wired into let-init, expr/return
      statements, if/while conditions, defer). First real new check: **generic instantiation arity**
      — `Pair<i32>` on a two-param `Pair<A,B>` now errors `generic 'Pair' expects 2 type
      argument(s), got 1` with source location. Conservative (only fires on known generic decls →
      no false positives; stdlib + all positive cases stay green). Graduated to
      Graduated **3 generic checks** to `expect_fail/`: arity mismatch, type args on a non-generic
      type, and duplicate type-parameter names. Corpus now **13/13** (8 positive + 5 negative),
      zero false positives on stdlib.
      **Risk notes discovered (why other PENDING checks aren't landed yet):** arg-count checking is
      unsafe until name resolution is namespaced (checker keys functions by bare name, but the
      merged stdlib has cross-module name collisions → false positives); condition-must-be-bool is
      blocked because the resolver types comparisons as `i32` (would flag every `if`); return-type
      checking is blunted by the permissive `isTypeCompatible` (string⇄numeric allowed). Those need
      resolver/`isTypeCompatible` work (A3) first. Private-field access is still landable next.
- **A3. Sound(er) type checker.** Arg count/type checking, return-type checking, condition-is-bool,
  undefined var/type errors, remove numeric+`any` implicit-anything, real unsigned semantics.
  Turn "not supported in LLVM yet" printfs into hard compile errors.
  - ✅ **Started:** resolver now types comparison/logical operators as `bool` (were `i32`), and a
    **condition-must-be-bool** check rejects non-bool `if`/`while` conditions
    (`expect_fail/non_bool_condition.nova`). Corpus 14/14, no stdlib false positives.
  - ✅ **Assignment (let-init) soundness DONE.** Tightened `isTypeCompatible` to numeric⇄numeric
    only (removed string⇄numeric / numeric⇄anything). The one stdlib site that relied on the old
    permissiveness (injected `__i32_to_string` helper) was fixed with an explicit cast
    `(ptr + 4) as string`; the **whole stdlib type-checks clean** under the sound rule (verified via
    broad import). Implicit i32→pointer in a typed `let` is now caught.
  - ✅ **Return-type check: DONE (option-2 resolver-accuracy path).** Rather than a blind cast sweep,
    made `resolveExprType` accurate: bare & generic calls resolve to their declared return types,
    string concat (`+` with a string operand) → string, bitwise `&`/`|` → i32 (not bool), and
    `isTypeCompatible` treats erased generics (`List` ~ `List<T>`) and value↔optional as compatible.
    With accurate typing, only the genuine pointer-idiom returns remained (`return ptr + 4`), cast to
    `(expr) as T` across the stdlib (~18 returns + 1 let-init). The whole canonical stdlib type-checks
    clean with return checking ON; corpus 15/15 (8 positive + 7 negative, incl. `return_type_mismatch`).
  - **Arg-count check** still blocked on namespaced resolution (bare-name collisions in merged stdlib).
- **A4. Floating-point support.** Float literals/parsing + a real numeric tower. Unblocks serde
  floats, `math` float suite, datetime.
- **A5. Codebase hygiene.** ✅ Deleted the stale `llvm_codegen_fallback.zig` (5885 lines, unused),
  stripped all `DEBUG` prints (compiler output is now clean). **Decision: keep `switch` as the
  real construct; `match` stays a reserved-but-unimplemented keyword** (documented in the lexer)
  so pattern-matching can be added later without breaking code. Also fixed a duplicate-function
  link bug (a module imported via two paths produced `List_delete` twice → `List_delete.64`,
  leaving the ARC destructor's `List_delete` bodiless); dedup added in `declarations.zig`.
- **A6. Traits upgrade.** `Hash`/`Eq` (for Map/Set), and default methods / trait objects if desired.
- **A7. Honest primitive types — `int`, not `i32`.** *(Requested 2026-07-15. Verdict: DO IT, and do it
  early — it rewrites every signature, so the cost only grows.)*
  - **The finding is worse than naming — today's widths are a lie.** `types.zig:42` maps
    `i32`/`u32`/`int`/`uint` **all to `val_type`**, and `llvm_codegen.zig:240` sets
    `val_type = i64 (native) / i32 (wasm)`. So **`let a: i32 = 5000000000` prints 5000000000 on
    native** (verified) and would truncate on wasm: *the same source has different numeric semantics
    per target*, and `i32` is not 32 bits. `u*`/`uint` are not unsigned either (A3's "real unsigned
    semantics" is the same hole). Fixed-width names are actively misleading — a correctness bug, not
    taste.
  - **Design.** Canonical friendly set: `byte`/`short`/`int`/`long` (+ `ubyte`/`ushort`/`uint`/`ulong`),
    `float`/`double`, `bool`, `string`, `void`. Decide and *pin* `int`'s width **identically on native
    and wasm** (recommend `int` = 64-bit, matching today's native behaviour, so the stdlib doesn't
    silently change meaning; wasm then uses i64 for `int` rather than redefining the type per target).
    Keep `i8..i64`/`f32`/`f64` as **honest** fixed-width types for FFI/binary work — but only once they
    truly carry those widths (real truncation + overflow rules). Emit a deprecation on the old spellings,
    then delete them.
  - **Work.** (a) one canonical `PrimType` table in `types.zig` replacing the string-compare chains
    (~48 `"i32"` sites in the compiler); (b) real narrowing/truncation + unsigned ops in codegen;
    (c) mechanical migration of ~367 stdlib annotations; (d) negative tests pinning the widths
    (`int` overflow, `byte` wrap, unsigned compare) so this can never silently regress again.
  - **Depends on:** nothing. **Blocks:** A8 (conversions must name real types), C6/C7 (binary + text
    work need honest widths). **Risk:** touches everything — land it behind the corpus, in one sweep.
- **A8. Conversions & formatting — delete `__i32_to_string`.** *(Requested 2026-07-15. Verdict: DO IT;
  cheap and high-DX.)*
  - **Today:** compiler-injected `__i32_to_string` / `__bool_to_string` are the *only* way to stringify
    (22 uses in-tree). There is **no `__i64_to_string` and no `__f64_to_string`** — building the YCSB
    bench, printing an i64 or f64 was impossible without scaling to int by hand. It is also a leaky
    low-level construct in user-facing code.
  - **Design (three layers, in order):** (1) a `ToString`/`Display` trait with impls for every primitive
    → `x.toString()` (needs **A6**); (2) **string interpolation** `"n = ${x}"` desugaring to
    `toString()` calls — this is C2's "format/interpolation" and is the real ergonomic win;
    (3) `format(fmt, args...)` on top. **Do NOT overload `as` for this** — `as` is a *bit-level* cast
    (FPToSI etc.); making `x as string` mean "format" conflates representation with rendering and
    would be a wart we'd carry forever. Keep `as` numeric↔numeric only.
  - **Work.** Trait + primitive impls; parser/codegen for interpolation; migrate the 22 call sites;
    delete the injected builtins. **Depends on:** A6 (trait), A7 (type names).
- **A9. Parameter passing — `ref` params (and an honest pointer type).** *(Requested 2026-07-15.
  Verdict: DO the `ref` half; DON'T add raw pointers.)*
  - **Today:** structs are heap+ARC objects, so they *already* pass by reference (mutating a param's
    field is visible to the caller — the YCSB bench relies on this). Primitives pass by value, and
    there is **no way to write an out-param**. Meanwhile the stdlib *fakes* pointers by stashing heap
    addresses in `i32` fields (`bytes.alloc` → `Reader.buf: i32` in `data/btree/client.nova`), which
    only works because `int` is secretly 64-bit (see A7) — that is the unsafe underbelly and it will
    break the moment A7 makes `i32` honest.
  - **Design.** Add `ref` (in-out) params: `fn f(ref x: int)` lowers to pass-by-pointer with automatic
    deref at use sites; callers write `f(ref v)` so mutation is visible at the call site. **Reject raw
    C-style `*T`/`&x`:** they fight ARC (who retains?), break the WASM target, and undermine the safety
    story — the value is out-params, not pointer arithmetic. Instead add a distinct opaque `ptr` type
    for the FFI/`bytes` layer so the "address in an int" idiom becomes type-honest and A7-proof.
  - **Work.** Parser (`ref` in params + args), codegen (alloca ptr + deref), checker (ref args must be
    lvalues; no ref-to-temporary). **Depends on:** A7 for the `ptr` half.

### B. Runtime → stackful C++20 (Boost.Asio + Boost.Context)
Full detail in `runtime-cpp20-plan.md`. Freezes the ABI, moves the C runtime to `discards/`, ports
subsystem-by-subsystem onto `io_context` + Boost.Context fibers, fixes every concurrency bug and
the TLS-verify hole, adds `async`/`await` as sugar, and switches to a prebuilt `libnova_runtime.a`.
Depends on A1 (closures) for the async sugar; otherwise parallelizable with A.

### C. Standard library — data types & serde *(depends on A2, A4, A6)*
- **C1. Collections.** Fix the Map churn hang + resize-on-tombstones; fix List/Map element leaks;
  rewrite or drop Array; complete List (`pop/contains/indexOf/find/slice/sort/reverse/clear`),
  Set algebra (`union/intersection/difference/subset`); `Hash`/`Eq` instead of hash-pointer compare.
- **C2. String / text.** UTF-8 codepoint handling; `format`/interpolation, `repeat`, `pad*`,
  `trimStart/End`, `splitLines`, `lastIndexOf`; validating `parseInt`/`parseFloat`.
- **C3. Serde.** JSON: decode escapes + `\uXXXX`, floats/exponents, error positions, depth limit.
  YAML: floats, flow style, block scalars, escapes. BSON: public API + real f64/i64 codecs.
- **C4. datetime/math.** i64 timestamps (fix Y2038 + pre-1970), timezone offsets; float math suite.
- **C5. IO.** Buffered reader, line iterator, stat/metadata struct; robust error signaling.
- **C6. Crypto — expose wolfCrypt properly.** *(Requested 2026-07-15. Verdict: DO IT; best
  effort/value ratio on this list — the dependency is already vendored and linked.)*
  - **Today `crypto` is fake.** `runtime/core.cpp:202` — `nova_sha256` and `nova_md5` **return the
    empty string**:
    `char *nova_sha256(const char *input) { return nova_from_cstr(input ? "" : ""); }`.
    `crypto.nova`'s own `@test` asserts `sha256("hello") == "2cf24dba…"`, so that test has been
    passing vacuously or never running. Meanwhile **wolfSSL is already vendored, built and linked**
    (`deps/wolfssl/build/libwolfssl.a`, `-DNOVA_HAVE_WOLFSSL`) — wolfCrypt is sitting there unused.
  - **⚠️ Prerequisite (real blocker): binary-safe strings.** `nova_from_cstr` is **NUL-terminated**, so
    it cannot carry raw bytes — the moment a digest/ciphertext/random buffer contains `0x00` it
    truncates. Digests can dodge this by returning hex, but `randomBytes`/AES/sign **cannot**. Needs a
    length-aware constructor (`nova_from_bytes(ptr, len)`) writing the 8-byte header directly. Land
    this **first**; it also derisks the binary paths generally.
  - **Scope.** `crypto.hash` (SHA-256/384/512, SHA-3, MD5+SHA-1 marked legacy), `crypto.hmac`
    (HMAC-SHA256/512), `crypto.kdf` (PBKDF2, HKDF), `crypto.aead` (AES-GCM, ChaCha20-Poly1305),
    `crypto.cipher` (AES-CBC/CTR), `crypto.sign` (RSA, ECDSA), `crypto.ecdh` (X25519), `crypto.encode`
    (hex, base64), and **RNG split explicitly**: `crypto.random` = wolfCrypt `wc_RNG` **CSPRNG**
    (hardware-seeded — the only thing allowed near secrets) vs `crypto.prng` = a **seeded deterministic**
    generator for tests/benchmarks/simulation. Keeping those two apart in the *namespace* prevents the
    classic "used the fast PRNG for a session id" bug. Add `constantTimeEquals` (wolfCrypt has it) —
    D4 needs it.
  - **Work.** New `runtime/crypto.cpp` in the unity build, included **after `io.cpp`** (which already
    sequences wolfSSL's `options.h` vs Asio); every entry guarded by `NOVA_HAVE_WOLFSSL` with an honest
    **compile/run error** when absent — *never* a silent empty-string stub again. Then `std/crypto/*.nova`
    + real KATs (NIST vectors) in the corpus.
  - **Unblocks D4** (secure session IDs / CSRF tokens / constant-time compare are currently insecure
    precisely because there is no CSPRNG).
- **C7. `text` namespace — string, stringBuilder, regex, localization.** *(Requested 2026-07-15.
  Verdict: namespace + regex YES; full localization NO — scope it hard.)*
  - **Reorg.** Move `string`, `collections/string_builder` → `text.string`, `text.stringBuilder`, and
    add `text.regex`, `text.locale`. Cheap and correct — but it churns every import, so do it **with**
    A7's signature sweep, not separately.
  - **⚠️ Hard prerequisite: UTF-8 (C2).** Today's string is **ASCII-only**. Regex over bytes and
    localization over ASCII are both nonsense — `.` must match a codepoint, `toUpperCase` must know
    about `ß`/`İ`. **C2's UTF-8 work gates both.** Do not start regex before it.
  - **Regex — build it in Nova, as a Thompson NFA.** Options weighed: bind PCRE2/RE2 (new heavy C dep,
    fights the WASM target), bind `std::regex` (notoriously slow + huge), or implement. Recommend
    **implement**: a Thompson NFA/pike-VM has **no catastrophic backtracking** (a real security
    property for a web framework doing route/input matching), needs no new dependency, works on WASM,
    and dogfoods the language. Scope v1: literals, classes, anchors, `*+?`, `{n,m}`, alternation,
    groups, captures, lazy quantifiers. Explicitly **out**: backreferences and lookaround (they're what
    force backtracking). Honest estimate: this is **weeks**, not days — it is the biggest item on this
    list.
  - **Localization — do the 20% that matters, skip ICU.** Full ICU (collation, segmentation, full CLDR)
    is a multi-year dependency; do **not** vendor it. Scope: message catalogs with named args, **CLDR
    plural rules** (the part everyone gets wrong), locale-aware number/currency formatting, and date
    formatting via C4's timezone work. Explicitly out: collation, bidi, full case-mapping tables.
    Ship as data-driven tables so locales are additive.

### D. Web & TCP framework *(depends on B + A1 + C)*
- **D1. HTTP server rewrite.** Real request framing: read-loop until headers, body by
  Content-Length / chunked decode; header & body size limits; read/write/idle timeouts; keep-alive;
  connection/concurrency caps; graceful drain; remove request-dumping debug logs.
- **D2. Router.** Path params, wildcards, method-aware 405.
- **D3. Middleware pipeline.** A real executor that runs cors/csrf/session/rate_limit/body_limit/
  secure_headers/logger *in-path* (today they never execute).
- **D4. Security.** TLS `verify_peer` (client + server, TLS 1.3); cryptographically-random session
  IDs & CSRF tokens with constant-time compare; secure cookie defaults; trusted-proxy config for
  `X-Forwarded-For`.
- **D5. HTTP client.** TLS/HTTPS, chunked decode, redirects, timeouts; stop returning `undefined`
  streams on connect failure.
- **D6. Stretch:** WebSocket/`Upgrade`, static-file serving, compression, HTTP/2.
- **Deferred (not a priority): the app/composition layer (`app.nova`).** It needs a redesign
  (different from today); revisit after D1–D4. The router/middleware/DI can be wired without it.

### E. Spec, tests, tooling, diagnostics *(cross-cutting)*
- **E1. Reverse-engineer the language spec** from the implementation (replace stale `specs.md`):
  document actual behavior — `switch` not `match`, `T|undefined` optionals, fixed arrays only,
  library-level concurrency, name-erased→monomorphized generics.
- **E2. Conformance test corpus** pinning codegen behavior — the safety net that lets B/C/D proceed
  without regressions. (Leverage existing `nova test` + coverage.)
- **E3. Diagnostics quality** — errors with source spans and messages (huge "feels like a real
  language" multiplier).
- **E4. Tooling** — harden the LSP and formatter; dependency/package story.

---

## 3. Suggested sequence & milestones

1. **M1 — Foundations & safety net.** A1 (closures), A5 (hygiene), E2 (test corpus). *No new
   features; the code stops fighting you.*
2. **M2 — Type system & generics.** A2, A3, A4, A6. *The core becomes sound and generics real.*
   ✅ **Sound-core objective COMPLETE.** Delivered: A2 generic checks (arity, non-generic type-args,
   dup params); A3 full soundness (accurate resolver + condition-bool, let-init, return-type,
   arg-count checks, each with a negative test); A4 floats (fixed float-literal typing + float↔int
   cast codegen bugs; math suite + parseFloat); `&&`/`||` switch; Map churn-hang fix. Corpus: 18
   cases (10 positive + 8 negative), all green. **Deferred by decision** (not part of the sound-core
   goal): **A2(d) monomorphization** → future perf track (generics work via erasure; array.nova is
   dead); the **Map resize/allocator crash** (bump-alloc'd memory freed unsafely; same "abnormal
   termination" as arena_allocator + all-module import) → **fix in M3** when the allocator is rebuilt;
   **A6 Hash/Eq `eqFn`** API change → pairs with the Map rework (current `hashFn==string.hash`
   heuristic works for string/i32 keys). Generics are "real enough" for Beta via erasure.
3. **M3 — C++20 runtime + async.** *(Architecture changed — see `runtime-cpp20-plan.md`.)*
   - ✅ **v0 DONE:** C++20 runtime live, build restored, **corpus 18/18 green**. ABI frozen
     (`nova_abi.h`); arena-faithful ARC allocator; core subsystems; real file/dir (`std::filesystem`);
     cross-platform (`#ifdef _WIN32` guards); **synchronous concurrency shim** (stable default);
     runtime **prebuilt** into `~/.nova/lib/libnova_runtime.a` (fast per-build linking).
   - **Async architecture FINALIZED: stackless C++20 coroutines + Asio, multi-core** (io_context on a
     thread pool + strands) — *reversed* from the earlier stackful decision, for performance (fastest
     async; Asio's reactor is the scheduler). This makes async a **compiler project**: `async`/`await`
     + function coloring + codegen emitting `llvm.coro.*`. Sequenced M0→E in `runtime-cpp20-plan.md`.
   - **Gate M0:** wire a middle-end pass run (`LLVMRunPasses`) into the emit path so `llvm.coro.*`
     lowers; prove one Nova coroutine suspends/resumes via Asio.
   - **Prereq A:** make strings ARC-correct so the load-bearing arena can be dropped (thread-local
     arena breaks under multi-threaded task migration). Then races + TLS hole gone; real async lands.
4. **M4 — Stdlib production pass.** C1–C5 on the now-capable compiler.
5. **M5 — Web/TCP production pass.** D1–D5 (D6 stretch); app-layer redesign deferred.
6. **M6 — Spec + diagnostics + tooling.** E1, E3, E4; performance pass (ARC elision, non-atomic
   thread-local refcounts, stack pooling, LTO).

A/B can overlap once A1 lands; C waits on M2; D waits on M3 + C.

### M2.5 — Language ergonomics & honesty *(the 2026-07-15 request: A7, A8, A9, C6, C7)*

> **Full detail + worked code examples: [`nova-language-evolution-plan.md`](./nova-language-evolution-plan.md)**
> (items L1–L6 there map to A7/A8/A9 + C6/C7 here; L6 breaks i18n/l10n out as its own first-class item,
> since a web-first language needs locale negotiation, CLDR plurals and formatting on day one).

These five slot in as follows. **The ordering is not arbitrary** — three of them rewrite signatures or
imports, so doing them late means paying the migration twice.

| # | Item | Verdict | Do it when | Size |
|---|---|---|---|---|
| 1 | **A7** honest primitives (`int` not `i32`) | **Yes — first** | before any new stdlib | L (broad, mechanical) |
| 2 | **A8** conversions / kill `__i32_to_string` | Yes | after A6 + A7 | S–M |
| 4 | **A9** `ref` params (no raw pointers) | Yes | after A7 | M |
| 3 | **C6** crypto via wolfCrypt | **Yes — best ratio** | after binary-safe strings | M |
| 5 | **C7** text ns + regex + localization | Yes (scoped) | **after C2's UTF-8** | **XL** (regex ~weeks) |

**Sequence:** `binary-safe strings` → **A7** → (**A8** ‖ **A9** ‖ **C6**) → C2 UTF-8 → **C7**.

**Two blockers to clear before any of it:**
1. **The string heap bug is live.** ASAN puts a wild read in `string_slice` (a string whose length
   header is garbage) — repro + full ASAN recipe + already-eliminated hypotheses in
   `lang/repro/driver_alloc_churn_crash.nova`. This is very likely M3's *"Prereq A: make strings
   ARC-correct"* biting for real. **Fix before building more on strings** — A8/C6/C7 all pile onto
   exactly that code path.
2. **Binary-safe strings** (`nova_from_bytes(ptr,len)`) — gates C6 and every binary protocol.

**Why this ordering:** A7 changes every type annotation, C7 changes every text import — batch them with
one corpus sweep each. A8 and C7 both need a *correct* string; C6 needs binary-safe strings; regex needs
UTF-8. Ignoring the order means migrating the stdlib two or three times.

**What this buys:** A7 removes a real per-target soundness hole (`i32` is 64-bit natively, 32-bit on
wasm — same source, different arithmetic). A8+C7 are the "feels like a real language" multipliers. C6
turns a fake crypto module into a real one *and* unblocks D4's security work. A9 makes the stdlib's
"heap address in an int" idiom honest — which A7 would otherwise break.

---

## 4. Where this lands us: the readiness verdict

**Readiness scale:** Prototype → Alpha *(today)* → **Beta** *(after M1–M6)* → 1.0/Production.

**After completing all of the above, Nova would be a solid Beta.** Concretely that means:

- **Sound-enough core**: real type checking, real generics, no closure/concurrency data-race
  landmines. You can write non-trivial programs and trust the compiler to catch mistakes.
- **A dependable runtime**: no fiber races, no leaks, real TLS security, competitive I/O via Asio.
- **A usable stdlib**: collections/text/serde that behave correctly on real (non-ASCII, floating,
  escaped) data; a web/tcp stack that can safely serve real HTTP with routing, middleware, and TLS.
- **Buildable, testable, documented** against an accurate spec.

That is the level where **you and early adopters can build real services on it** — the BTreeDB
integration, YCSB benchmarks, and real Nova web apps all become realistic.

**What Beta still is NOT (the gap to a 1.0 you'd ask strangers to adopt):**
1. **Mileage.** Bugs surface only under real workloads; 1.0 needs months of dogfooding + a bug
   backlog burned down.
2. **Stability commitment.** Frozen syntax/stdlib APIs, deprecation policy, versioning — you must be
   willing to stop changing things.
3. **Ecosystem.** A package manager + registry, third-party libraries, editor support beyond basic.
4. **Docs & learning path.** Tutorials, API reference, guides — not just a spec.
5. **Performance proof.** Benchmarks (YCSB, HTTP throughput) showing it's competitive, plus the
   perf work (ARC elision, escape analysis, monomorphized inlining) actually landed and measured.
6. **Portability breadth.** Linux/macOS/Windows + WASM all first-class and CI-tested.

**Bottom line:** this roadmap converts Nova from "impressive alpha with an unsound core and unsafe
runtime" into "a real Beta language you can build production services on." Reaching a public 1.0
after that is less about more compiler features and more about **mileage, stability, ecosystem, and
docs** — a different kind of work than what's planned here.
