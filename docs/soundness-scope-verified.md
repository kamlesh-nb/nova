# Nova soundness scope — VERIFIED (2026-08-14)

This is the empirically re-verified soundness/correctness surface of the language, replacing the stale
status in `docs/gaps.md` (whose matrix was dated 2026-08-13 and predates the SE-A/B/C string-engine
cutover and much else). Every entry below was checked by compiling and running a minimal repro through
`~/.nova/bin/nova` under `NOVA_ASAN=1` (and `NOVA_ARC_AUDIT=1` for leaks) on 2026-08-14. Repros live in
the session scratchpad `verifyC/`, `verifyK/`, `verifyChk/`.

Headline: the crash / UAF / miscompile class that `gaps.md` still lists as open is **almost entirely
fixed**. What actually remains is a small set of **checker fail-open** holes (the checker accepts a few
ill-typed programs), **one codegen crash** (indexing a non-indexable type), one **stdlib correctness**
gap (JSON on malformed input), and one **unsupported syntax** form (tuple `.0`).

## STATUS: all five RESOLVED (2026-08-14)

Every LIVE defect below has since been fixed, each gated by the full corpus (and an `expect_fail`
regression for the checker rejections):
- **L1 (K6)** — FIXED (`0ca999b`). Checker rejects `[]` on a scalar/struct/enum (fail-closed); guard
  `expect_fail/index_non_indexable`. Known follow-up: the inferred `let p = P{...}; p[0]` case needs the
  separate privacy-model fix (see the detail note below).
- **L2 (C-chk-6)** — FIXED (`8a4a63f`). Optional-where-plain now rejected at let-binding and argument
  positions, and a narrowing is invalidated on reassignment; guards `assign_optional_to_plain`,
  `pass_optional_to_plain_param`.
- **L3 (C-chk-7)** — FIXED (`3f81640`). Tuple destructure arity checked + elements bound; guard
  `tuple_destructure_arity`.
- **L4 (E7)** — FIXED (`b35bc71`). `json.tryParse` returns `undefined` on malformed input; case 335.
- **L5 (K8 `.0`)** — FIXED (`31f3c47`). `tuple.N` desugars to `tuple[N]`; case 336.

The original analysis is preserved below.

## LIVE defects (the exact scope to fix) [now all RESOLVED — see status above]

| ID | Class | Severity | One line |
|---|---|---|---|
| **L1 (K6)** | codegen + checker | crash / S-crit | Indexing a non-indexable type (`p[0]` where `p` is a struct/int) is not type-checked; it lowers to raw pointer arithmetic — silently reads the first field, and segfaults (ASAN BUS) on a large index. |
| **L2 (C-chk-6)** | checker fail-open | crash | An optional `T \| undefined` is accepted where a plain `T` is expected in **let-binding** and **argument** positions (the RETURN position IS checked), and a narrowing is not invalidated on reassignment. Runtime crash. |
| **L3 (C-chk-7)** | checker fail-open | wrong / S-crit | A wrong-arity tuple destructure (`let (a,b,c) = pair` where `pair` is a 2-tuple) is accepted; the extra name binds garbage. |
| **L4 (E7)** | stdlib correctness | wrong | The JSON parser silently accepts malformed input: `json.parse("[1,2,")` returns `[1,2,null]` (size 3) with no error channel (`std/serde/json.nova` `parse` has no failure signal). |
| **L5 (K8 dot)** | unsupported syntax | low | Tuple positional dot-access `pair.0` is a parse error (unsupported). The index form `pair[0]` works and is correct, so this is a missing-feature, not a miscompile. |

### Detail

- **L1 / K6** — `type_checker` never checks the target of an index expression, and codegen emits a raw
  pointer load for `x[i]` regardless of `x`'s type. `p[0]` on a struct returns field 0; `p[1000000]`
  faults. Fix: reject `[]` on a non-indexable type in the checker (fail-closed). Guard with an
  `expect_fail` case.
- **L2 / C-chk-6** — the optional-where-plain check exists only for the return position
  (`return_optional_as_plain`, C-chk-3, fixed). Assignment (`let y: T = optionalValue`) and argument
  passing (`f(optionalValue)` into a plain-`T` param) fall open, and re-narrowing state is not reset on
  reassignment. Fix: apply the same possibly-undefined check at the let-init and call-argument coercion
  sites; invalidate a narrowing when the variable is reassigned.
- **L3 / C-chk-7** — tuple destructuring binds by position without an arity check against the tuple's
  element count. Fix: require the pattern arity to equal the tuple arity (fail-closed). Guard.
- **L4 / E7** — `std/serde/json.nova` `parse` returns a `JsonValue` with no error path;
  `parseArray`/`parseObject` break silently at end-of-input and a spurious `parseValue()` pushes a
  default. Fix: surface a parse error (a result/optional) on malformed input. Stdlib change, larger.
- **L5 / K8** — the parser rejects `.<integer>` as a field access. Fix (optional): parse `tuple.N` as a
  tuple index. Low priority since `tuple[N]` already works.

## VERIFIED FIXED (gaps.md is stale on these)

Codegen crash class — all fixed, ASAN-clean:
- **C2** `T | E | undefined` non-primitive ok-arm value-optional (no segfault).
- **C3** destructor dispatch across same-named colliding structs (TypeId dispatch from SE-C; correct dtor each).
- **C6 / C-lit** `@serializable` struct-literal layout (64-bit field survives; no i32 default).
- **C8 / K2** `Atomic<long>` width (full 64-bit, incl. through a generic); `Atomic<string>`/`Atomic<struct>` now rejected.
- **C9** nested non-primitive field loads (nested struct + wide long + owned string + optional all round-trip).

Type-system / ARC — fixed:
- **K3** `any` is an owned refcounted box (ASAN + ARC audit clean).
- **K4** enum/union refcounted payload destructors (string + struct payloads freed correctly).
- **K5** `T[N]` of refcounted elements — rejected at type-check (`array_string_element`/`array_struct_element`).
- **K8 index form** `pair[0]` works and is correct.

Checker fail-open — fixed with `expect_fail` guards:
- **C-chk-1** method-call arity (`method_arity_mismatch`).
- **C-chk-3** return optional as plain (`return_optional_as_plain`).
- **C-chk-4** non-bool condition (`non_bool_condition`, `if_optional_condition`).
- **C-chk-5** non-exhaustive enum switch (`switch_non_exhaustive_enum`).

Stdlib:
- **E-parse** `parseFloat("1e3") == 1000`, `parseInt` surfaces failure on garbage/empty (via
  `parseInt`/`parseLong`/`parseDouble`; the lenient `parseI64`/`parseFloat` are a documented
  driver-compat contract, not a defect).

Plus, from `final-beta-readiness.md`'s reproduced-defect register (independently corroborated by the
green corpus): F1 (`T|E|undefined`), B4 (`Set<T>`), B5 (generic trait widening), B6 (generic async serde),
A-nested (`Map<K, V|undefined>` present-null vs absent), C1/C2 (module-scoped structs/enums), D1 (`any`),
H1 (string+float).

## Out of scope for "language soundness" (tracked elsewhere)

`gaps.md`'s M (server-stability leaks: TLS scratch, pg reader/prepared-cache, JSX, cursor/pool), X
(concurrency: blocking channel deadlock, cross-reactor wakeup), Sec (driver security defaults), and T
(tooling/targets) sections are real but are stability/security/tooling concerns, not language
type-soundness. They are separate tracks.

## Fix order

L1 (K6) → L2 (C-chk-6) → L3 (C-chk-7) are the three checker/codegen soundness holes and are small,
fail-closed changes, each gated by the full corpus + `--asan` and an `expect_fail` regression case. L4
(E7) is a stdlib change (JSON error channel). L5 (K8 dot) is an optional parser feature.
