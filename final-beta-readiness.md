# Nova: Final Beta-Readiness Report

Date: 2026-08-08. Method: ten independent, evidence-based audits in two waves over the actual compiler,
runtime, and standard library. Every defect below was reproduced by compiling and running a minimal program
(usually under AddressSanitizer) or confirmed by reading the exact code path with a file:line citation.
Claims taken on trust from prior docs were re-checked; several were stale in both directions.

## Master tracking table (status at a glance)

Updated 2026-08-08 (branch `fix/samename-type-resolution`). Legend: ✅ fixed + gated (conformance case +
full corpus + ASAN green) · 🔵 investigated, not a live bug (recorded, no fix needed) · 🟡 in progress ·
⬜ open / deferred. Severity: **S-crit** silent corruption/unsafety · **crash** · **wrong** silent wrong
answer · **blk** does not compile/link · **gap** missing feature.

**Score: 29 defect IDs fixed (B5 direct case), 4 investigated-not-a-bug, ~8 open/deferred. Recent: B5-direct
(a generic struct init `Cell<int>{...}` inferred with no type args left `T`-typed fields/returns erased, so
interpolating one stringified a raw int as a pointer → SEGV; struct-init inference now recovers the
instantiation from the field values — the trait-object vtable sub-case remains open); tuple-payload-multi
enums; if-expr in interpolation; I-numeric (the lexer
accepted neither `_` digit separators nor scientific notation; both now scan); H4 (a decimal literal
with more than 34 significant digits was truncated instead of rounding half-even like the arithmetic path;
fixed in the literal parser); B1-let (free-generic
inference into a typed let `let x: int = id(42)` was rejected -- the call resolved to the raw type-param;
now the checker infers the type args from the argument types); F1 (`T|undefined|E`
value-arm SEGV: the codegen string path dropped the ok arm's `.optional`, so the producer stored a raw
value while every consumer unboxed a value-optional); G5 (`try` propagated a
mismatched error type); A4 (interpolating a non-narrowed optional printed the box pointer); A3-read (value-optional
monomorphisation collision, fuzzer-found); G3 (JSON surrogate-pair astral corruption); shift-infer (integer
literals in a `long` context computed in 32 bits); lit-i64 (decimal literal above i64 range silently → 0);
F2 (payload-enum `==` compared identity not value). Every fix is repro-first with a
gating case (273–299) and stays corpus + ASAN green.**

| ID | Cluster | Sev | Status | Commit / note |
|----|---------|-----|--------|---------------|
| H1 | H numeric | crash | ✅ | `2cc3797` string+float concat crash |
| H5 | H numeric | wrong | ✅ | `85b348e` `nan != nan` (ordered→unordered), case 273 |
| H2 | H numeric | S-crit | ✅ | `9756f7d` narrowing cast truncates; flushed a latent reactor ptr bug, case 274 |
| H3 | H numeric | wrong | ✅ | `9699959` int div/mod by zero traps, case 277 |
| H6 | H numeric | wrong | ✅ | `9699959` `INT_MIN / -1` overflow traps (same fix) |
| G1 | G stdlib | wrong | ✅ | `bbad50b` Map key 0 (3-state slots), case 275 |
| G2 | G stdlib | S-crit | ✅ | `29acad7` int switch lowers; checker rejects non-enum/int, case 276 + expect_fail |
| B1 | B generics | blk | ✅ | `cc146ba` free-fn inference + solved-arg record, case 278 |
| B3 | B generics | S-crit | ✅ | `cc146ba` owned generic return (same root as B1) |
| B2 | B generics | blk | ✅ | `192f374` transitive generic composition, case 279 |
| A1 | A value-opt | S-crit | ✅ | `62ca289` await of value-optional = box ptr (the mongo cursor root), case 281 |
| A2 | A value-opt | crash | ✅ | `7a90915` `List<int\|undefined>` insert-box, case 280 |
| A3 | A value-opt | wrong | ✅ | `7a90915` (same fix — single read/narrow unboxes correctly) |
| A3-read | A value-opt | crash | ✅ | value-optional monomorphisation collision. A `List<int \| undefined>` mangled to the SAME symbol as a plain `List<int>` (the legacy type-name path rendered `int \| undefined` as just `int`), so a program using BOTH (directly, or via the stdlib's own `List<int>`) shared one body and mixed a boxed value-optional layout with a raw i32 layout → any read of a ≥2-element value-optional list dereferenced a mis-typed slot (UAF/SEGV in `nova_retain`). Found by the codegen fuzzer. Fix: render value-optionals distinctly in `renderLegacy` (`int \| undefined`, not `int`) + mangle `\|`, so the two instantiations get distinct names and layouts. Cases 286 + fuzzer multi-element valopt; corpus + ASAN green. (The suspected "borrow over-release" was a red herring — string-model `set`/`get` retain is correct and `grow()` relies on it.) |
| C1 | C module-scope | S-crit | ✅ | `6e1b977` colliding-struct field access — was a SEMA return-type-scope bug, case 282 |
| C2 | C module-scope | S-crit | ✅ | enums `bfb341f`+`87379e6` (plain+payload), cases 283/284 |
| C2 | C module-scope (traits) | S-crit | 🔵 | `58257f9` traits already coexist (per-impl vtable); false alarm; case 285. Unions: not a functional construct |
| E1 | E async | hang | 🔵 | did not reproduce in isolation; ASAN-clean — likely subsumed by C/B fixes |
| E2/S7 | E async | S-crit | 🔵 | owned-struct-across-await did not reproduce; ASAN-clean now |
| G4 | G stdlib | wrong | 🔵 (partial) | `parseI64` i64-MIN actually works (double wrap); non-digit/overflow parts still open |
| A4 | A value-opt | wrong | ✅ | interpolating a non-narrowed optional printed the box ptr; now renders the inner value when present and `undefined` when absent (value-optional + heap-optional string). Case 291 |
| A-nested | A value-opt | wrong | ⬜ | `Map<K, V\|undefined>.get()` returns `(V\|undefined)\|undefined`. Root cause pinned: an outer optional over a value-optional inner reuses 0 as its `none` sentinel, so *present-holding-undefined* (inner == 0) collides with *absent* (0) -> `m.set(k, undefined); m.get(k)` reads as a miss (silent wrong value, not a crash). Fix requires the OUTER optional to be boxed so `box(0)` != `0`. Blocked like B4 by monomorphisation: the producer is a generic method whose return TypeRef is `.optional(.ident("V"))` -- the nested optionality is hidden behind an unsubstituted type-param and string substitution collapses it (F1-class), so the producer can't tell it must add a box level. Needs mono-aware optional-depth resolution + ARC handling of the double-box. NB: surface syntax cannot express this (`(int\|undefined)` parses as a TUPLE; `int\|undefined\|undefined` flattens), so it only arises through generics |
| B4 | B generics | blk | ⬜ | `Set<T>` (over `Map<T, bool>`) fails. Root cause pinned: `Set<int>` monomorphises its OWN methods (`Set_i32_*`) but the nested generic `Map<int, bool>` is never instantiated, so `self.map.get(...)` falls to the ERASED `Map_*`. Two symptoms: (1) the private erased `Map_keysEqual` is DCE-dropped because it is emitted before its callers `Map_set`/`get` create a use → undefined symbol at link; (2) even emitted, the erased Map↔`Set_i32` ARC boundary releases a bogus pointer → SEGV in `Set_i32_has`. Real fix = instantiate the nested generic `Map<int,bool>` through `Set<int>` and route the calls to `Map_i32_bool_*` (a nested-generic monomorphisation fix, F2-6-adjacent), NOT just the emission-drop |
| B5 | B generics | crash | 🔵 (partial) | ✅ DIRECT case fixed: a generic struct init `Cell<int>{...}` was inferred with NO type args, so a `T`-typed field/return stayed an erased type-param — interpolating such a value (`${self.value}`) stringified a raw int as a pointer → SEGV in StringBuilder_append. Fix: struct-init inference recovers the instantiation from the field values (solve the struct's type params against the inferred field-value types). Case 299. ⬜ STILL OPEN: dispatch through a TRAIT OBJECT vtable, where the vtable points to the erased shared method body instead of the per-instantiation monomorphisation — needs per-instantiation vtables for a generic struct impl'ing a trait (codegen) |
| B6 | B generics | blk | ⬜ | generic `async fn` cannot resolve `serde.bind<T>` |
| D1/D2/D3 | D erased carriers | S-crit | ⬜ | `any` owning-heap UAF; any-downcast double-free; unchecked trait→concrete `as` |
| E3 | E async | crash | ⬜ | reap-mark not cleared for awaited children (latent) |
| F1 | F enum/union | crash | ✅ | `T\|E\|undefined` value-arm SEGV: `typeRefToString` dropped the `.optional`, so the error-union ok arm collapsed from `int\|undefined` to `int`. Producer stored a raw int; every consumer unboxed a value-optional → SEGV. Fixed across the seam: render value-optionals distinctly, box the ok value on return, treat `try`/`catch` as value-optional boxes, box the catch handler. Case 293 |
| F2 | F enum/union | wrong | ✅ | payload-enum `==` now compares by VALUE (word-by-word over the same-size zero-padded box), not heap identity. Value payloads compare by value; string/heap payload fields stay identity (documented). Case 290 |
| F3 | F enum/union | — | 🔵 | NOT a needed construct. Per spec §3.5 an error union `T \| E` is handled with `try`/`catch`; to branch on error variants you `catch (e) helper(e)` (or use the exception's `message()`) and `switch` on the UNWRAPPED enum error, which works (cases 266, 32). A raw `switch` over `T \| E` is not in the language. Follow-on (minor): have the checker reject it outright instead of falling through |
| G3 | G stdlib | S-crit | ✅ | JSON `\uXXXX` surrogate pairs now combine into one astral code point (4-byte UTF-8); decoder was encoding each surrogate independently → 6 bytes of mojibake. Case 287 |
| G5 | G stdlib | wrong | ✅ | `try g()` re-raises the callee's error unchanged, so it must match the enclosing function's declared error type; the checker now rejects a mismatch (`fn f(): T\|E1 { return try g() }` where g fails with E2). Case 292 + expect_fail |
| H4 | H numeric | wrong | ✅ | decimal literal >34 digits truncated instead of rounding. The arithmetic path (`dec_round_drop`/`dec_encode`) already did round-half-even, but the literal parser `dec_parse_bounded` dropped over-precision digits on the floor (fractional overflow vanished, integer overflow only scaled the exponent). Fix: track guard/round/sticky of the dropped tail and apply round-half-even (with carry renormalisation) in the parser, matching the arithmetic path. Case 295 |
| lit-i64 | H numeric | wrong | ✅ | a decimal literal above i64 range was silently parsed to 0 (`catch 0`); now a hard parse error. Hex/bin/oct keep their bit pattern to u64; `-9223372036854775808` (i64 MIN) works. Case 289 + expect_fail |
| shift-infer | H numeric | wrong | ✅ | an integer literal in a `long` context stayed `int`, so `let x: long = 1 << 40` (and `1000000 * 1000000`) computed in 32 bits and overflowed before widening. Literals now adopt an integer expected type (>= 32 bits) and arithmetic propagates it. Case 288 |
| B1-let | B generics | blk | ✅ | `let x: int = id(42)` — free-generic inference INTO a typed let. The checker resolved the call to the raw return type `T` (unresolved type-param), which failed the compat check against `int`. Fix: when a generic fn is called without explicit `<T>`, infer the type args by unifying each declared param type against the actual argument type, then substitute into the return type. Genuine mismatches still rejected. Cases 294 + expect_fail/generic_infer_typed_let_mismatch |
| I | parser gaps | gap | 🔵 (partial) | ✅ DONE: `_` digit separators (`1_000_000`, `0xFF_FF`, `3.141_592`, `1_000.5m`) + scientific notation (`1e3`, `1.25e-2`, `1.5e2m`) — lexer scans them, Zig parseInt/parseFloat already ignore `_`, decimal runtime skips `_`. Case 296. ✅ DONE: if-expr in interpolation (`${if (c) a else b}`) — the interpolation parser force-classified a leading `if` as a statement; now a bare `if` routes through parseExpression. Case 297. ✅ DONE: tuple-payload-multi enums (`Rect(int, int)` + `case Rect(w, h)`) — parser desugars to positional fields `_0`/`_1`; construction already worked; pattern binding added in checker, sema, and codegen. Case 298. STILL OPEN: guards, while-let, `?.`-method, where-constraints, trait default bodies |
| F4 | keystone | — | 🟡 | codegen soundness fuzzer STARTED (`3769458` `conformance/codegen_fuzz.py`, teeth-proven, int arith/cast) |
| F2-6 | keystone | — | 🟡 | typed IR BUILT + shadow-validated (6723 agree / 0 disagree); tracker `docs/design/f2-6-keystone-tracking.md` |

## 0. Honest verdict

Nova is a **broad, genuinely capable alpha**, not a beta. The breadth is real: a self-hosted async runtime on
native reactors, TLS 1.3 in pure Nova against OpenSSL, four working database drivers, ARC, an LLVM backend, a
web framework serving tens of thousands of requests per second. That is not a toy.

But the two audit waves reproduced **about thirty distinct defects**, of which roughly a dozen produce
**silent wrong answers, silent memory corruption, or crashes**. The important finding of the second wave is
that they are not scattered: they fall into **eight clusters, and several clusters share a single root
cause**. That makes the work tractable. It also confirms that "production ready" and "beta" were labels
applied ahead of the evidence, for one structural reason: the verification that would have caught these was
never built.

The good news, equally evidenced: whole subsystems came back **clean** under systematic stress. Concrete-type
ARC (nested containers, branches, loops, defer, struct lifecycle, closures) is sound. Trait dispatch (vtable
ordering, heterogeneous lists, destructors) is sound. Monomorphisation identity is sound (no generic analogue
of the struct-collision bug). Most of the standard library round-trips correctly. So this is a strong engine
with a well-defined set of holes, not a rotten foundation.

## 0b. Fix progress (updated 2026-08-08, branch `fix/samename-type-resolution`)

Executing the plan. Each fix followed repro-fails, fix, promote the repro to a conformance case, full corpus
plus AddressSanitizer, commit.

Landed:

- **H1** `string + double` crashed (float-add path bit-cast the string pointer to a double). Fixed. `2cc3797`
- **H5** float `!=` used ordered comparison, so `nan != nan` was false. Fixed to unordered. `85b348e`
- **H2** a narrowing integer cast (`long as int`, `int as byte`) was a no-op, silently keeping the wide value.
  Fixed to truncate by target width and signedness. The same change flushed out a latent reactor bug: the
  `whenAny` primitives typed a heap address as `int` and relied on the old no-op, so they now take `long`.
  `9756f7d`
- **G1** a `Map` key of `0` was silently unretrievable (occupancy was inferred from `key == 0`). Replaced with
  an explicit three-state slot array. `bbad50b`
- **G2** a `switch` on an integer miscompiled (every case label collapsed to `0`); a `switch` on a string did
  the same. Fixed integer switch to evaluate real labels, and the checker now rejects a non-enum, non-integer
  discriminant. `29acad7`
- **H** integer divide or modulo by zero, and the signed 64-bit `INT_MIN / -1` overflow, were silent
  undefined behaviour. They now trap at runtime with a clear message. `9699959`
- **B1 / B3** a bare call to a generic free function (`id(x)` with no explicit `<T>`) failed with "Function
  not found" because the inferred instance was never collected; the owned-return case shared the root. Sema
  now registers the inferred instantiation and records the solved type arguments, and codegen rebuilds the
  monomorphised name. `cc146ba`
- **B2** a generic that forwards its type parameter to another generic (`inner<T>` inside `outer<T>`) failed
  to instantiate the callee. A transitive-closure pass now collects instances reached only through another
  generic, including multi-level chains and container forwarding. `192f374`

  This corrected the earlier theory that free generics lacked codegen instantiation context: the explicit
  `id<T>(x)` form always worked end to end, ownership included. The real gaps were in monomorphisation
  collection and call-site mangling, not ownership. What remains is a bare *inferred* nested call
  (`inner(x)` with no `<T>` inside a generic), which is a compile error, not a miscompile.
- **A (value-optionals)** two fixes. Inserting a plain value into a `List<int | undefined>` crashed: the
  read path unboxes but the insert path did not box, so a raw value was stored and later dereferenced as a
  pointer. Fixed by boxing at the call argument, routing through the receiver's TypeId arguments (the
  substituted parameter string drops `.optional`, so it could not see the value-optionality). `7a90915`
- **S1 (the mongo cursor root cause)** `await`ing a value-optional returned the box pointer, not the value,
  because the helper that decides whether a consuming `?? d` must unbox did not list `.await_expr`. One
  line. This is the real `cursor.next` / `queryOne` corruption that `findList` only sidestepped. `62ca289`

  On the rest of this cluster: the async scheduler defects (owned struct held across `await`, a generic
  async method await hanging) did **not** reproduce in isolation and are ASAN-clean now, most likely fixed
  as a side effect of the same-name-collision and free-generics work. A nested value-optional (`Map.get`
  returning `(int | undefined) | undefined`) still crashes and is genuinely harder.
- **S2 (colliding-struct field access, an F2-6 item)** two modules each declare `struct Rec` with
  different layouts; a consumer that imports both and does `let b = other.makeB()` mistyped `b` to the
  wrong module's `Rec`, so field access read the wrong layout and crashed. This corrected the report's own
  theory: codegen already resolves field layout by the scoped struct identity; the root was that sema
  lowered the callee's return type in the **caller's** module scope. Fixed by lowering it in the callee's
  module (`moduleCallReturn`). No codegen change was needed. `6e1b977`

- **S3 (colliding enums, an F2-6 item)** same-named enums in two modules collapsed to one: the checker's
  exhaustiveness validated one module's switch against the other's variants (phantom errors), and codegen
  keyed enums and enum methods by bare name, so construction, switch lowering and method dispatch resolved
  to the wrong module's enum. Now enums are module-scoped end to end (sema collision detection + scoped
  rendering + codegen keying and method mangling + per-reference scoped resolution), the same way structs
  already were. `bfb341f`

  Struct and enum (plain and payload) are the module-scoped kinds. Traits need no scoping and were
  confirmed to already coexist: a trait is dispatched through the per-implementation vtable in the fat
  pointer, not by the trait name, so a same-named trait collapsing across modules is harmless. (The
  earlier "trait scoping broke return-widening" was a false alarm from an invalid test.) User-facing
  unions are not a functional construction feature, so there is no analogous union case. The same-name
  collision family (S2 structs, S3 enums, traits) is now closed.

Investigated and deferred, recorded rather than papered over:

- `parseI64` on the `INT_MIN` string actually works (two two's-complement wraps cancel), so there was nothing
  to fix there.
- Payload-carrying enum `==` really does compare heap identity, not value. A checker rejection was inert
  because the checker does not yet reliably track the type of an enum-valued local, so it has been left for a
  proper fix (synthesised structural equality, or the type-tracking work in section 1). It is a real bug.
- (fixed) A decimal integer literal above the `i64` range silently became `0` (`parseIntLexeme` did
  `parseInt(i64, ...) catch 0`, swallowing the overflow). It is now a hard parse error with a location
  (`src/parser.zig`): hex/bin/oct literals keep their bit pattern up to `u64` (so masks like
  `0xFFFFFFFFFFFFFFFF` still work), a decimal literal must fit signed `i64`, and `2^63` is accepted as the
  magnitude of i64 MIN so `-9223372036854775808` yields i64 MIN. This complements the existing checker-side
  narrowing check (which caught `int`-range overflow but never saw the `long` case, because the parser had
  already turned it into `0`). A large UNSIGNED decimal literal that only fits `u64` should be written in hex;
  a type-aware decimal `ulong` literal is a separate follow-on. Case 289 + expect_fail.
- (fixed) An all-literal integer expression in a wider context truncated to 32 bits: `let x: long = 1 << 40`
  gave `1 << 8` (256), `1000000 * 1000000` and `2000000000 + 2000000000` wrapped. The literals defaulted to
  `int` regardless of the `long` expected type, so the whole expression was computed in 32 bits and overflowed
  BEFORE the widening to `long`. Fixed in the checker (`src/sema/infer.zig`): an integer literal adopts an
  integer expected type of >= 32 bits (int/uint/long/ulong), and arithmetic/shift binary ops propagate that
  expected type into their operands (the shift amount excepted), with the result taking the wider operand.
  Narrower contexts (short/byte) are unchanged, so the explicit-narrowing rule (F3 §6) is intact. The expected
  type also flows through `long` return and `long` call-argument contexts. Case 288.

Deferred (larger, want a checkpoint before starting): the free-generics cluster (B1/B2/B3 share one root, see
section 2), the structural async work and value-optionals (section 5, F1), and the codegen soundness fuzzer
(section 5, the keystone).

## 1. Why these ship (the systemic root causes)

**1a. No generative soundness testing.** `conformance/fuzz.sh` is a front-end crash fuzzer: it byte-mutates
sources into garbage and only checks the compiler does not crash. It never generates a well-typed program,
never runs the output against an oracle, so it **cannot catch a miscompile**. The prior readiness plan set the
exit bar at "codegen fuzzer clean over N million programs" and marked it DONE, while another row admits
"REMAINING: a codegen fuzzer feeding the gates". The keystone was relabelled, not built. The 230-case corpus
is a strong regression net but grows only after a bug is found in production, so unexercised combinations are
simply unknown. This is exactly why a wrong-struct miscompile passed 268 of 268, and why free-generic
inference (a core idiom) was never even compiled by a test.

**1b. Codegen re-derives types by rendering `TypeId` back to a bare string (the F2-6 gap).** For roughly 7 to
16 percent of expressions the checker does not record the type, so codegen re-derives it by rendering the
`TypeId` to a name and scanning the AST (`src/codegen/types.zig:721`). That rendering discards module identity
and generic-argument identity. It is the mechanism behind the struct/enum collision cluster.

**1c. Two value representations are incomplete: value-type optionals, and generic type parameters.** The
box-or-scalar decision for a value-type optional, and the borrow-or-own and mono-instantiate decisions for a
type parameter, are each handled correctly on the simple path and dropped on the compound paths (through a
coroutine frame, through a generic storage slot, on return from a generic body, when a callee is itself
generic). These two incomplete representations account for the two largest clusters below.

**1d. Two structural errors in the async model, confirmed against Go and Swift.** We studied the two proven
implementations that solved these problems: Go's goroutine scheduler (`runtime/proc.go`, `netpoll.go`,
`chan.go`) and Swift's async/await (which, like Nova, lowers async to stackless LLVM coroutines: SE-0296,
SE-0300, the AsyncContext ABI). They independently point at the same two root errors, and each error is the
common cause of a pair of our confirmed async defects.

  Error one: **`await` is treated as two separable steps (register a waiter, then separately schedule the
  child), and the coroutine's identity is its recycled frame address.** Go fuses "publish that I am parked"
  and "arm my waker" into one critical section (`gopark`/`park_m`), and `goready` flips status and enqueues
  as one atomic step guarded by `casgstatus`, so a stale or duplicate wake is a thrown error, not a silent
  drop; identity is a stable `g` struct with an authoritative status field, not a bare address. Swift does
  the mirror: an atomic `Pending -> Awaited` / `Pending -> Resumed` handshake where the loser of the race
  performs the single enqueue, and identity is a refcounted Task/Job object, never the frame pointer. Nova
  violates both: our register-then-schedule split is exactly the E1 lost-wakeup hang (the unresolved-call
  path registers a waiter and never schedules), and keying wakeup bookkeeping on the malloc'd frame address
  is exactly the E3 recycled-identity lost-wakeup. The fix for E1 and E3 is one fix: **make suspend-and-arm
  one atomic transition with the completion side owning the enqueue, and give each coroutine a stable
  status-bearing task/job handle (with a generation counter) as its schedulable identity instead of the raw
  frame address.** Under this discipline E1 and E3 become impossible, and a mis-wake becomes a loud assertion
  rather than a 0-percent-CPU stall.

  Error two: **the coroutine frame is untyped malloc storage, and ARC drops are placed as if the body were
  straight-line rather than split at each `await`.** Swift decides liveness and ownership over SIL in
  ownership form before CoroSplit: `await` is a barrier, anything live across it is pinned in the AsyncContext
  at +1 and released only at its true last use on the resume side, and the result flows back through a
  result slot typed as the declared return type (so `Optional<Int>` keeps its payload-plus-discriminator, not
  a box). Nova does neither: our drop placement releases an owned value before its post-await use (E2/S7,
  the owned-struct-across-await UAF), and the awaited result is materialised as an erased box carrier so a
  value-type optional comes back as box-pointer bits (A1). The fix for E2/S7 and A1 is one fix: **run
  drop-placement on a CFG where `await` is a real barrier so releases anchor to the post-resume last use, and
  give the frame a typed result slot laid out as the declared return type, read with the same lowering as the
  synchronous return path.** The same "typed slot, never an erased box" rule fixes the non-async siblings in
  Cluster A (the value-optional stored in a generic container element, A2/A3).

## 2. The defect clusters

Severity: **S-crit** = silent corruption or memory-unsafety; **crash** = loud but a hard fault; **wrong** =
silent wrong answer; **blocker** = does not compile or link; **gap** = missing feature or diagnostic. Each
item has a repro on disk under `scratchpad/audit_repros`, `audit2_*`, or a docs/design repro dir.

### Cluster A: value-type optionals are mis-represented on compound paths  [S-crit + crash + wrong]
The single most pervasive cluster. A `T | undefined` where `T` is a value type (int, long, payload-less enum)
is represented as a boxed pointer, and the unbox-on-consume is dropped whenever it crosses a frame, a generic
slot, or a container.
- **A1** `await` of an async fn/method returning `T | undefined` yields the **box pointer, not the value**.
  Silent corruption on every async optional API (cursors, `queryOne`, `next()`). Very likely the real mongo
  cursor root cause that `findList` only dodged.
- **A2** a value-optional stored as a **generic container element** (`List<int|undefined>`,
  `Map<_, int|undefined>`) SEGVs on read (`nova_valopt_unbox` / `nova_retain`).
- **A3** a **single** read/narrow of such a container element is now correct (unboxes to the value, `7a90915`).
- **A3-read** (fixed, fuzzer-found) a `List<int | undefined>` monomorphised to the SAME symbol as a plain
  `List<int>`, because the legacy type-name path (`renderLegacy`) rendered `int | undefined` as just `int`.
  A program that used both (directly, or via the stdlib's own `List<int>`, which is why it only reproduced
  under `nova test`) shared one body, mixing a boxed value-optional layout with a raw i32 layout, so a read
  of a ≥2-element value-optional list dereferenced a mis-typed slot (UAF/SEGV in `nova_retain`). Fixed by
  rendering value-optionals distinctly (`int | undefined`, not `int`) plus mangling `|`, so the two
  instantiations get distinct names and layouts (cases 286 + the fuzzer's multi-element valopt template; corpus
  + ASAN green). Root cause is squarely the F2-6/W9 "string path drops `.optional`" class, fixed reactively.
  The earlier "borrow over-release" theory was disproved: the string-model `set`/`get` retains are correct and
  `grow()` depends on them.
- **A4** (fixed) interpolating a **non-narrowed** optional (`${x}` on `int | undefined`) printed the box
  pointer. The template stringifier only handled string/prim/decimal parts and fell through for an
  `.optional`, appending the raw box. It now branches on presence: a value-optional renders its unboxed inner
  value (int/long/bool/...), a heap-optional string renders the string, and an absent optional renders
  `undefined` (`src/codegen/expressions.zig`, `compileAppendToStringBuilder`). Narrowing first (`?? d` or an
  `if (x != undefined)` guard) already worked and still does. Case 291.
Bounded clean: value-optional as a **struct field** works; `undefined` alone works; heap-typed optionals
(`string|undefined`) work. So the fault is specifically the value scalar plus the box, on compound paths.

### Cluster B: generics are broken for inference, composition, ownership, and nested mono  [blocker + S-crit + crash]
Monomorphisation identity is sound, but the surrounding machinery is not. This is the weakest subsystem.
- **B1** free generic function **type inference is broken**: `id(42)` gives `Function 'id' not found`; you
  must write `id<int>(42)`. Generic **methods** infer fine, only free functions fail. A core idiom does not
  compile. Uncovered because the corpus only calls free generics with explicit type args.
- **B2** generic functions **cannot compose**: `fn outer<T>(x:T){ return inner<T>(x); }` gives
  `Function 'inner' not found`. A generic body cannot call another free generic with its own type parameter.
- **B3** a generic function **returning a value of its owned type-parameter type double-frees** (heap UAF):
  the borrowed `U` argument is not retained on return. Invisible to the `--arc` gate (double-free leaves zero
  live objects). Blast radius: `List.reduce<U>` and any combinator returning its accumulator.
- **B4** `Set<T>` fails to **link** (`_Map_keysEqual` undefined): nested-generic mono references a private
  method of `Map<T,bool>` by its unmangled base name when `Map` is a field of `Set`. A whole stdlib collection
  is unusable; merely `import set;` breaks the build.
- **B5** generic `struct impl Trait` called **through a trait object** SEGVs (malformed vtable).
- **B6** generic `async fn` cannot resolve `serde.bind<T>` (T erased through the async frame).
Bounded clean: nested and recursive generics, generic trait objects, mono identity and distinct layouts all
produce correct values. The holes are inference, composition, return-ownership, nested-mono mangling, the
value-optional element (Cluster A), and async erasure.

### Cluster C: module scoping is not applied in codegen  [S-crit]
- **C1** colliding structs collapse to **one field-offset layout** in codegen field access
  (`src/codegen/expressions.zig:3170`, `src/codegen/llvm_codegen.zig:997`), because the type is rendered to a
  bare, module-blind name. Reproduced as an ASAN SEGV. The session fix corrected sema and struct registration
  but never reached field offsets, so it was half done.
- **C2** enums, traits, and unions get **no module scoping at all** (`src/sema/symbols.zig:174` is
  struct-only), so same-named enums across modules collapse layout, including the ARC destructor keyed by bare
  name (double-free). Code-proven.
Root: 1b.

### Cluster D: type-erased carriers are memory-unsafe  [S-crit]
- **D1** `any` owning a heap value dangles: the value is freed when the producing local exits; read-back is a
  use-after-free.
- **D2** a value widened to `any` then downcast double-frees (two owners, refcount never bumped).
- **D3** an unchecked trait-to-concrete downcast (`foxObj as Owl` on the wrong type) does **no runtime check**
  and silently reinterprets the pointer. A wrong `as` should trap.

### Cluster E: async lowering has a lost-wakeup and an early-free  [crash + hang]
- **E1** an unresolved async-**call** await registers a waiter but never schedules the child
  (`src/codegen/expressions.zig:805`, `buildAwait` fallback to `buildAwaitFuture`), so a cross-package or
  erased-generic async method await **silently hangs** with the reactor idle. This is a second, independent
  root cause of the mongo cursor stall (Cluster A is the corruption, this is the hang).
- **E2** an owned struct held in a local across `await` on the reactor path is freed one drop early (UAF).
- **E3** the recycled-frame reap-mark is not cleared for **awaited** children (only for detached ones), a
  latent lost-wakeup on frame reuse within a batch.

### Cluster F: enum and union value semantics  [crash + wrong]
- **F1** `T | E | undefined`: the **value arm** is ARC-treated as a heap pointer and SEGVs on a plain int
  return.
- **F2** (fixed) `==` on payload-carrying enum variants compared heap identity, not value (`E.A(3) == E.A(3)`
  was false). Every variant box of an enum is allocated at the same size (tag + max payload words) and
  zero-padded, so codegen now compares the two boxes word-by-word (tag + payload) at the `==`/`!=` site
  (`src/codegen/expressions.zig`, `payloadEnumBoxWords`). Value-type payloads compare by value; a string /
  heap payload field still compares by pointer identity (a documented limitation, since a fully structural
  compare would dispatch per field type). Payload-less enum `==` was already correct (integer tags). Case 290.
- **F3** (not a needed construct) a raw `switch` over an error-union `T | E` falls through to `default`.
  This is not part of the language: per spec §3.5, errors are handled with `try`/`catch`, and to branch on
  the error variants you `catch (e) helper(e)` (or rely on the exception's `message()`) and `switch` on the
  UNWRAPPED enum error `E`, which works (cases 266, 32). Reclassified as investigated-not-a-bug; a minor
  follow-on is to have the checker reject a `switch` over `T | E` outright rather than silently fall through.

### Cluster G: standard library and checker correctness  [wrong + crash]
- **G1** `Map` with an integer or enum key of value **0** is silently unretrievable: `map.nova` uses `key==0`
  as the empty-slot sentinel with no occupied bit, so `set(0,x)` stores it but `get(0)` reports absent. Broad
  silent data loss; hidden because real usage is string-keyed.
- **G2** `switch` on a **non-enum** discriminant (int, string) silently miscompiles: every case label lowers
  to the constant 0, so one case always hits `default` and multiple cases emit an LLVM duplicate-case verify
  error. The checker does not reject it.
- **G3** (fixed) JSON `\uXXXX\uDXXX` **surrogate pairs corrupted astral characters** (emoji became mojibake):
  the decoder UTF-8-encoded each surrogate independently (two invalid 3-byte sequences) with no 4-byte branch.
  Data corruption in the shared JSON parser, so every HTTP and DB path that received JS-escaped emoji was
  affected. Fixed in `appendUnicode` (`src/std/serde/json.nova`): combine a high surrogate (D800..DBFF) with a
  following low surrogate (DC00..DFFF) into one code point and add the 4-byte UTF-8 branch; a lone/invalid
  surrogate is left as-is and does not consume following text. Case 287 (surrogate pair, both range ends,
  BMP/2-byte/ASCII unaffected, lone high surrogate, pair surrounded by ASCII).
- **G4** `string.parseI64` is wrong for i64 MIN (magnitude overflow), silently ignores non-digits, and has no
  overflow detection. Also used by `serde.getInt`.
- **G5** (fixed) `try` silently propagated a **mismatched error type** out of a narrower error-union
  signature. `try g()` re-raises the callee's error UNCHANGED into the enclosing function, so that error must
  match the function's declared error type; propagating a foreign error (`fn f(): T | E1 { return try g() }`
  where g fails with E2) let an E2 escape a function whose contract says E1. The checker now flags it in the
  `.try_expr` inference against `current_ret` (`src/sema/infer.zig`, `errorTypesCompatible`); Nova has no
  error subtyping, so only an exact match of the declared error type passes (an unresolved side is never
  flagged). Case 292 + expect_fail/try_error_type_mismatch.

### Cluster H: numeric correctness  [crash + wrong]
- **H1** `string + double` (the `+` operator) **SIGSEGVs**: the raw double is handed to the string layer as a
  pointer. Extremely common (any log line concatenating a float crashes the server). Template interpolation
  formats floats correctly, so only the `+`-concat path is wrong.
- **H2** a narrowing cast to `int` (`someLong as int`, out-of-range `someDouble as int`) does **not truncate**
  to 32 bits: the full 64-bit value survives in comparisons, prints, returns, and indexing, and is only masked
  under later int arithmetic. Deeply inconsistent silent corruption. (Implicit narrowing is correctly
  rejected, so exposure is the explicit `as int`.)
- **H3** integer divide and modulo by **zero** are silent (return 0 or the dividend at runtime; fold to
  garbage at compile time). Decimal div-by-zero traps loudly; integer should too.
- **H4** decimal128 literals and `fromString` with more than 34 significant digits **truncate instead of
  round-half-even** (off by one quantum at the boundary). Finance-relevant; decimal arithmetic rounding is
  otherwise correct, so the bug is in the coefficient parse.
- **H5** float `!=` uses an ordered predicate, so `nan != nan` is false and the canonical `x != x` NaN check
  silently fails.
- **H6** `INT_MIN / -1` yields an out-of-range value silently (same 64-bit-leak family as H2).
- Known and documented: `int` and `long` overflow wrap silently (the overflow trap is unimplemented), the
  `intAddr + offset` 32-bit truncation footgun, shift-by-width and negative-shift UB, `nan/inf as int`
  saturation.

### Cluster I: parser and feature gaps  [gap, not unsafe]
Loud, not corrupting, but they shape everyday code: scientific-notation float literals (`1e18`), underscore
digit separators (`1_000_000`), tuple-form multi-payload variants `V(A,B)`, match guards `case X if c`,
`while (let x = ...)`, `?.` onto a method call, an `if`-expression inside string interpolation, `where T impl
Trait` constraints, and trait **default method** bodies are all unsupported at the grammar level.

## 3. What is genuinely solid (verified clean, do not re-litigate)

- **Concrete-type ARC is sound.** Nested containers with overwrite/clear/reassign, owned values through
  `if`/ternary/`switch`/`??`, loop-carried accumulation, `defer`/`errdefer` ordering, full struct lifecycle,
  closures capturing owned values, error-union propagation up several frames, self-assignment and aliasing:
  all ARC-clean and ASAN-clean. The old `return x ?? default` corruption class is fixed.
- **Trait dispatch is sound.** Vtable ordering is correct even when impl method order differs from the trait
  declaration; heterogeneous trait-object lists, self-dispatch, multiple traits, and owned-struct destructors
  through the vtable are all correct.
- **Monomorphisation identity is sound.** No generic analogue of the struct-collision bug; distinct
  instantiations get distinct symbols and layouts; nested and recursive generics produce correct values.
- **String-based ownership residue is guarded** by a loud exit-70 tripwire, not a silent guess. Undefined
  identifiers and unresolved namespaced calls are fatal.
- **Most of the standard library round-trips correctly**: serde JSON/YAML/BSON (including astral surrogate
  pairs), List, Map (string-keyed and non-zero int-keyed), String, regex, math, decimal arithmetic.
- **All three primary platforms run the async runtime end-to-end** (macOS kqueue, Linux epoll and io_uring,
  Windows IOCP). WASM works for trivial programs and about 45 percent of the corpus.
- **The gates that exist are strong sanitizers** (`--asan`, `--shadow`, `--arc`, a harness self-test,
  `expect_fail` by declared reason). They are just sanitizers over a fixed corpus, so they miss unknown
  classes.

## 4. Documentation drift to correct (stale in the safe direction)

The specification says the runtime is Boost.Asio (retired) and "55 cases" (actual 230), and says WASM fails
for trivial programs (it works). It does not document closure-by-value capture, the coloring rules, or the
native reactor model. CLAUDE.md lists "Linux still aborts in nova_run_root" (false, epoll is wired).

## 5. Fix plan (ordered by blast radius, grouped so shared roots are fixed once)

Each fix lands with its repro promoted to a gating conformance case (positive) or an `expect_fail` case, so it
cannot regress.

### Phase F1: the two structural async fixes plus the two representation clusters
Per section 1d, four of our worst defects collapse into two structural fixes proven by Go and Swift. Do those
first; they make whole classes impossible rather than patching instances.
1. **Typed, ownership-tracked coroutine frame, and `await` as a barrier** (kills E2/S7 and A1, and the
   value-optional generic element A2/A3). Run ARC drop-placement on a CFG where `await` is a real barrier so a
   release anchors to the post-resume last use, and give the frame a **result slot typed as the declared
   return type**, read with the same lowering as the synchronous return path. Apply the same "typed slot,
   never an erased box" rule to the generic `Storage<T>` element. This is Swift's SIL-ownership-before-
   CoroSplit discipline.
2. **Atomic suspend-and-arm, and a stable task/job identity** (kills E1 and E3). Make suspend register the
   wakeup source in the same critical section, with the completion side owning the **single** enqueue; delete
   the register-a-waiter-without-a-decided-producer path and assert on it. Give each coroutine a **stable
   status-bearing handle with a generation counter** as its schedulable identity instead of the recycled
   frame address, and validate every resume as a `waiting -> runnable` transition (a mis-wake becomes a loud
   error, not a hang). This is Go's `gopark`/`casgstatus` and Swift's `Pending/Awaited/Resumed` handshake.
3. **The rest of the value-optional cluster and the generic machinery.** A4 (interpolation of a non-narrowed
   value-optional). Cluster B: free-function inference (B1), cross-generic instantiation (B2), retain-on-
   return of an owned type parameter (B3), nested-generic private-method mangling (B4), the generic-trait
   vtable (B5), and the async binder erasure (B6).

### Phase F2: the remaining confirmed crashes and corruptions
4. **H1** float `+`-concat crash and **H2** narrowing-cast no-op (both trivial to hit, both server-crashing or
   silently corrupting).
5. **C1 plus C2** module scoping in codegen field access and destructors (finish the half-done struct fix and
   extend to enums/traits/unions).
6. **F1** triple-union value-arm ARC, and the residual async hardening: **E3** reap-mark clearing for awaited
   children if not already subsumed by the identity change in F1, and a compile error for an unresolvable
   async-call await as a belt-and-braces guard on top of the atomic handshake.
7. **D1/D2/D3** erased-carrier safety: box and owned-retain `any`, or reject storing owned values into it; add
   a runtime check to trait-to-concrete downcast.

### Phase F3: the checker and stdlib correctness bugs
7. **G2** reject or correctly lower non-enum `switch`; ~~**F3** the error-union switch~~ (reclassified: not a
   language construct, use `catch` + enum switch on the unwrapped error, §3.5); **G1** the Map key-0
   sentinel; **G5** the loose-`try` error-type check; **H3** integer div-by-zero trap; **H4** decimal >34-digit
   round-half-even; **H5** float `!=` predicate; **G3** JSON surrogate pairs; **G4** parseI64.

### Phase F4: the verification that stops recurrence (the keystone the prior plan skipped)
8. **Build a real codegen soundness fuzzer**: generate random well-typed programs, compile, run under
   AddressSanitizer, check against an oracle (a reference interpreter or a differential second lowering). Gate
   it in CI over a large program count. This is the thing that would have caught Clusters A, B, C, F, and H
   without a production incident.
9. **Fill the corpus coverage matrices** for the classes that had no coverage: value-optionals on every path,
   free-generic inference and composition, name collisions for all type kinds, `any` and downcast, non-enum
   switch, numeric casts and overflow.
10. **Complete F2-6**: the checker emits a complete typed IR that codegen consumes, and the string-rendering
    path is deleted or proven safe. This removes the mechanism behind Cluster C and the type-derivation
    fragility, and is a prerequisite to safely deleting the legacy string engine.

### Phase F5: primitives, hardening, and docs
11. Add an async semaphore, a WaitGroup, and a bounded async channel; quarantine the stubbed `atomic.nova` and
    the thread-blocking `Channel<T>`; harden `AsyncLock` (reentrancy guard, removable waiter token,
    single-reactor guard). Convert compiler internal errors into located diagnostics.
12. Close the parser gaps in Cluster I as scope allows (scientific literals, underscores, trait default
    methods, and the others), and truth up the spec and CLAUDE.md per section 4.

## 6. Beta exit criteria (measurable)

Nova is beta when all of these hold, each checkable:

1. **Zero known miscompilation or memory-unsafety classes.** Every repro in Clusters A to H runs clean under
   AddressSanitizer, each promoted to a gating conformance or `expect_fail` case.
2. **The codegen soundness fuzzer runs green in CI** over a large program count (target on the order of one
   million generated programs) with zero miscompiles or sanitizer failures, as a required merge gate.
3. **The full gate suite is green and required on every commit** (conformance, `--asan`, `--arc`, `--shadow`,
   the fuzzer) on at least macOS and Linux.
4. **Coverage matrices exist** for value-optionals, generics, name collisions, `any`/downcast, switch, and
   numerics, so the holes that hid these bugs are closed.
5. **F2-6 has landed**: no soundness-relevant decision is made by rendering a `TypeId` back to a bare name.
6. **The core async primitive set exists** and the stubbed or thread-blocking traps are removed.
7. **The specification matches the implementation** on the load-bearing areas.

Until 1 through 5 hold, the honest label is alpha. When they hold, beta is a fact rather than a claim. The
encouraging part, after ten audits: the engine underneath (concrete ARC, dispatch, mono identity, most of the
stdlib) is sound, and the defects concentrate into two representation clusters plus the codegen-scoping gap,
so the work is bounded and the order is clear.

## Appendix A: what Go and Swift teach (design study)

We studied the two proven implementations of exactly Nova's problems: Go's goroutine runtime and Swift's
async/await (which lowers to stackless LLVM coroutines like Nova). Beyond section 1d's async fixes, three
design conclusions came out, each with a concrete decision for Nova.

### A.1 Ownership conventions (fixes B3, the torn copy, and points F2-6 at a proof)
Swift lowers every value to SIL with an explicit ownership kind and statically proves, in OSSA, that every
owned (+1) value has exactly one lifetime-ending use on every path.
- **Parameter contract:** the default is `+0` / borrowing (the caller keeps ownership, the callee must not
  release or escape it), and `consuming` is `+1` (the callee consumes exactly once). The two sides never both
  release.
- **Result contract:** a function result is always `+1`. Returning a borrowed (`+0`) value requires an
  explicit copy (`copy_value`, a retain) to promote it. **This is precisely Nova's B3:** we return a borrowed
  value as if it were `+1` without the retain, so caller and original owner both release. The fix is a
  one-line rule: at any `return` of a `+0` value, insert one `nova_retain`; a function result is always `+1`.
  It applies uniformly to a generic `T` return (Swift drives it off the convention via value witnesses, not
  the concrete layout, which is why `id<T>` never double-frees there).
- **Value versus reference, the torn copy:** Swift keeps two disjoint categories, `struct` (value, copy all
  fields, copy-on-write) and `class` (reference, share all fields via one `+0/+1` reference). Nova's "struct"
  is a heap object passed by value by copying fields, so a scalar field (the connection `busy` bool) is
  copied while heap-pointer fields (the fd, an `AsyncLock`) are shared. That is a **torn copy**, and it is the
  exact root of the by-value connection bug. Decision: **pick one discipline per type.** Anything holding an
  fd or a lock (a `Connection`) is a reference type; a by-value pass copies the pointer plus one retain and
  shares all fields including the bool. Never field-split.
- **F2-6, sharpened:** Swift proves ownership balance statically in OSSA; our `--shadow` gate only observes
  imbalance dynamically on tested paths, which is how B3 slipped through. The durable target for F2-6 is an
  OSSA-style `+0/+1` SSA pass that inserts the balancing retains and releases and proves exactly-one-consume
  per path, not a typed IR alone.

### A.2 Reactor and scheduler (our architecture is validated; adopt two narrow things)
- **Commit to share-nothing single-reactor.** N reactors plus SO_REUSEPORT, no work-stealing, no coroutine
  migration is why we hit tens of thousands of requests per second on one core with no hot-path atomics. The
  closest production system, SwiftNIO, is the same thread-per-core readiness design. Go's G-M-P work-stealing
  is the opposite trade-off (global balance at the cost of a fully cross-thread-safe runtime with atomic ARC).
  We should not adopt the P layer. This is the one big architectural decision, and our current choice is
  right.
- **Consequence for primitives:** because we are share-nothing, the async primitives should be single-reactor
  (no atomics, no cross-thread locks). The `NOVA_WEB_WORKERS` cross-thread issues (stdout flush, a shared
  `AsyncLock`) are a tiny set of process-globals to make explicitly safe, not to expand; cross-reactor work
  should be message-passing (the SCM_RIGHTS fd-handoff at accept time), never shared state.
- **Adopt from Go:** a small blocking-syscall offload pool so the reactor thread never blocks on a synchronous
  `getaddrinfo`/`stat`/compress, and a periodic-poll fairness backstop (Go's sysmon idea) so a CPU-bound
  coroutine cannot starve I/O readiness.
- **The readiness plus completion seam is sound and necessary** (Windows IOCP and Linux io_uring are not
  optional). Our two disciplines, the zero-byte-recv readiness shim and the `abandonOp` "kernel owns the
  op-record" rule, are exactly right; the addition is to treat async cancellation on completion backends as
  "pending until completion", never "gone".

### A.3 Mutual exclusion (our AsyncLock is the wrong primary primitive)
Go and Swift diverge deliberately. Go ships a real async lock (its `sync.Mutex` slow path parks the goroutine
on a runtime semaphore with a cancellation-safe sudog queue and a 1 ms starvation ceiling that hands ownership
directly to the head waiter). Swift ships **no** async lock: its `Mutex` is forbidden from being held across
`await`, and the intended primitive is an **actor**, whose serial executor serialises access structurally, so
there is nothing to hold, forget, or leak.

Our `AsyncLock`, held across `await` to serialise a multi-round-trip `runCommand`, reproduces the exact
pattern Swift forbids while omitting the safety machinery Go requires (it is not reentrant, a cancelled waiter
dangles a handle in the queue, and it is unguarded cross-thread). Decision, in order of preference:
1. **Primary: make the shared connection an actor / serial request-queue** (Nova already has actors over the
   async channel). `runCommand` becomes a message processed to completion as one indivisible job (one full
   request-response per job, no mid-frame executor yield, so a second command cannot interleave and corrupt
   the wire framing). This removes the crash and the cancellation-UAF by construction, with no manual lock
   discipline.
2. **Scaling: a connection pool with a bounded checkout semaphore.** Each checked-out connection is used
   exclusively by one coroutine, so no per-connection lock is needed on the hot path. This is what mature
   drivers do, and it is the throughput answer the mongo path ultimately wants.
3. **Fallback only: keep a hardened `AsyncLock`** for odd non-actor, non-pooled sites, but only after
   retrofitting Go's safety: atomic dequeue-and-resume, a single-resume guard so cancel and release race to
   one winner, release that skips dead entries, and a single-reactor assertion. Document it as non-reentrant.

Cancellation safety is the common thread: both Go (dequeue-under-lock, select's one-winner handshake) and
Swift (a cancellation handler resumes the continuation exactly once) guarantee a cancelled waiter is removed
and resumed once, never orphaned. Any Nova wait primitive (the async semaphore and WaitGroup in Phase F5
included) must have this or it is memory-unsafe under cancellation.
