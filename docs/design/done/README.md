# Kyte Foundation — design program

**Status: design phase. No implementation until the document for a piece is agreed.**

This directory exists because of a specific, repeated failure: **Kyte's compiler decides semantics by
pattern-matching on the spelling of type names at codegen time.** There is no resolved, typed
representation between the AST and LLVM. Every foundational defect below is a consequence of that one
fact, and every previous fix has been a patch applied at the point where the missing information was
finally needed.

This is not a rewrite for its own sake. It is the smallest set of things that must be true before
*any* type-directed feature — ARC, generics, honest widths, unsigned arithmetic, overflow, a real type
checker — can be implemented rather than approximated.

---

## 1. The evidence (measured 2026-07-15, not asserted)

Four bugs were diagnosed and fixed in a single day. They present as unrelated. They are one bug.

| Symptom | Immediate cause | Root |
|---|---|---|
| `Map` SIGBUS on resize (§10 #16/#18) | two calling conventions for a fn value; a bare fn called as a closure box | no typed notion of "function value" |
| `f.payload` → wild read, misfiled for months as "string heap corruption" (§10 #6, §8) | `x.field` resolved against `func_map` by **string suffix scan** before checking if `x` was a variable | no symbol table |
| closure envs leak, linear, ~46 B each (§10 #15) | `isRefCountedType` does `indexOf(type_name, "=>") → false` | ownership decided by spelling |
| `List<string>` elements leak, linear (§10 #17) | `isRefCountedType("T") → false` (hardcoded "single uppercase letter"); elements live in a raw `bytes.alloc` buffer invisible to ARC | generics are type-erased; no element type at destruction |

The shared signature, in one line — `arc.zig:11`:

```zig
pub fn isRefCountedType(self: *LlvmCompiler, type_name: []const u8) bool
```

**Ownership is decided from a string.** When the string is `"T"`, or contains `"=>"`, the answer is
hardcoded `false`. Those hardcodes are not oversights; they are the only possible answers when the
type is not known. The function cannot be fixed. Its *signature* is the defect.

### Measured scale of the dishonesty

| Fact | Count |
|---|---|
| `: i32` annotations in the stdlib | **329** |
| `: int` / `: long` / `: double` annotations in the stdlib | **0** |
| `"i32"` string literals inside the compiler | 48 |
| type decisions by `mem.eql` on a type-name string (codegen + checker) | 31 |
| `func_map` suffix-scan resolution sites | 9 |
| `bytes.alloc` sites (pointer-stored-in-`i32`) | 53 |

The canonical type names from L1's own target table (`int`, `long`, `double`) appear **nowhere** in the
stdlib. The entire library is written in the fixed-width names that lie.

### This was all known

None of the above is new information. It was written down and deferred:

- Roadmap **A2 inc. 2**, risk note: *"arg-count checking is unsafe until **name resolution is
  namespaced** (checker keys functions by bare name, but the merged stdlib has cross-module name
  collisions → false positives)."* — That is exactly the bug that later cost months as "string heap
  corruption."
- Roadmap **A1**, remaining: *"env/box use `kyte_bytes_alloc_persistent` (they leak) → add ARC on
  environments + retain captured ref-counted values."* — That is the measured closure leak.
- Spec **§4.5**: *"Prefix your helpers. (It is also why the arg-count checker skips ambiguous names.)"*
  — A documented workaround standing in for a symbol table.
- `list.ky:165`: *"ARC: elements are reference-counted; **ARC releases them, NOT this method**."*
  — A comment asserting a mechanism that was never built.
- Roadmap **§1**: *"**Compiler foundations must lead.**"*

**The plan was right. The plan was skipped.** The cost is not the bugs; it is that every bug above was
diagnosed twice — once correctly on paper, then again months later through a debugger, from symptoms,
against a wrong premise.

**The rule this directory enforces:** a foundation piece is not started until its design document is
agreed, and no feature is built on a foundation piece that is still `Designed` rather than `Landed`.

---

## 2. The pieces, in dependency order

Each piece has its own document. The order is not a preference — each one is unimplementable without
its predecessor.

```
F1  Name resolution & modules   ──┐
                                  ├──> F2  Typed IR ──┬──> F3  Primitive types & representation
                                  │                   ├──> F4  Generics & monomorphization
                                  │                   └──> F5  ARC ownership model
                                  │                              ▲
                                  └──────────────────────────────┘   (F5 also needs F4)
```

| # | Piece | Document | Why it must precede the next | Status |
|---|---|---|---|---|
| **F1** | Name resolution & module namespacing | [`F1-name-resolution.md`](F1-name-resolution.md) | You cannot type what you cannot resolve. Blocks the checker's arg-count check (roadmap says so explicitly). Kills §10 #6/#7. | Design |
| **F2** | Typed IR — the semantic middle | [`F2-typed-ir.md`](F2-typed-ir.md) | The place where a type is a *value*, not a spelling. Kills `isRefCountedType([]const u8)` and all 31 string decisions. | Design |
| **F3** | Primitive types & value representation | [`F3-primitive-types.md`](F3-primitive-types.md) | L1 + L3. Honest widths, real slots, `ptr`. Needs F2 to enforce literal ranges and narrowing. Kills `data: i32`. | Design |
| **F4** | Generics & monomorphization | [`F4-generics.md`](F4-generics.md) | Makes `T` a concrete type at codegen. Needs F2. Prerequisite for ARC-on-generics. | Design |
| **F5** | ARC ownership model | [`F5-arc-ownership.md`](F5-arc-ownership.md) | Ownership as a pass over F2's IR with written rules. Needs F4 (element types) and F3 (what is a pointer). | Design |

**Nothing in `specs.md §12 (Planned)` — L2, L4, L5, L6, the web framework, the C++20 runtime — starts
before F1–F5 land.** They all sit on top of these. That ordering is the entire point.

---

## 2b. Cross-cutting: the compiler itself is untested

**Measured 2026-07-15.** The conformance corpus (`conformance/`, 28 cases) tests the **language**,
end-to-end. Nothing tests the **compiler**.

| File | Lines | Tests |
|---|---|---|
| `src/codegen/llvm_codegen.zig` | 2803 | **0** |
| `src/codegen/expressions.zig` | 2577 | **0** |
| `src/parser.zig` | 2171 | **0** |
| `src/main.zig` | 1654 | **0** |
| `src/codegen/declarations.zig` | 1390 | **0** |
| `src/type_checker.zig` | 1154 | **0** |
| `src/formatter.zig` | 930 | **0** |
| `src/lexer.zig` | 601 | **0** |
| `src/codegen/statements.zig` | 607 | **0** |
| `src/codegen/types.zig` | 577 | **0** |
| `src/ast.zig` | 470 | **0** |
| `src/codegen/arc.zig` | 198 | **0** |
| `src/types.zig` | 445 | **12** |

**~16,700 lines of compiler; 12 unit tests, all written on 2026-07-15 in the one new file.**

This is not a coverage complaint — it is the explanation for this whole directory. **Every bug fixed on
2026-07-15 lived in an untested pure function**, and each was found by a user-visible symptom (a SIGBUS,
a wrong number) months after it was written, rather than by a test at the point of the mistake:

| Bug | Lives in |
|---|---|
| §10 #6 — `f.payload` → wild read | `expressions.zig` field-access resolution |
| §10 #18 — bare fn called as a closure box | `expressions.zig` fn-value lowering |
| $HOME in every symbol (53%) | `llvm_codegen.zig:getModulePrefix` |
| §10 #23 — dead code segfaults live code | `collectLocalVarNames` / `collectLocalVarTypes` |

Spec §13 says *"a feature with no case here is unverified by construction."* **The same rule has never
been applied to the compiler's own internals** — and that is precisely where these bugs were.

### The plan

**Every `.zig` file gets a `test` block, and every file is registered in `src/root.zig`'s test block, so
`zig build test` exercises the whole tree in one go.** Zig only analyses what is referenced, so an
unlisted file's tests silently never run. (`root.zig` had **no test block at all** before 2026-07-15 —
`zig build test` was reaching almost nothing.)

**Start with the pure functions.** Most of codegen needs a live `LlvmCompiler` + LLVM context and is
awkward to unit-test — but the functions that actually broke are **pure**, and they are testable today
with no harness:

| Target | Why it earns a test |
|---|---|
| `llvm_codegen.zig:getModulePrefix` / `getStructPrefix` / `isAlreadyNamespaced` | the $HOME bug; the 40-entry allowlist that silently treats `map_reduce` as pre-namespaced |
| `codegen/types.zig:getStructBaseName` / `isPrimitiveTypeName` / `typeRefToString` | the generic-erasure function; the `", "` vs `","` round-trip inconsistency |
| `llvm_codegen.zig:getTypeSize` / `getFieldOffset` | hand-rolled layout arithmetic, duplicated in two places |
| `codegen/arc.zig:isRefCountedType` | ownership, decided from a string |
| `type_checker.zig:canonicalizeTypeName` / `typesAreEqual` / `isTypeCompatible` | maps `u32`→`i32`, so `u64` and `i64` are the same type to the checker |
| `sema/symbols.zig`, `sema/alpha.zig` | new; must not regress |
| `lexer.zig`, `parser.zig` | token stream and AST shape — currently pinned only via end-to-end cases |

**Rule going forward:** a foundation stage that touches a pure function lands with that function's unit
tests. F2 stage 1 did this (12 tests, `zig build test` green, verified to fail when broken). It is
cheaper than the alternative, which this project has now measured precisely: an untested pure function
costs months and a debugger.

---

## 3. Non-negotiables for every document here

Set deliberately, because "superficial" is the failure mode being corrected:

1. **Measured, not asserted.** Every claim about current behaviour cites `file:line` or a measurement
   with its method. No adjectives standing in for numbers.
2. **The design states its invariants.** What must be true after this lands, phrased so a violation is
   detectable. An invariant nobody can check is a comment, and `list.ky:165` is what comments are
   worth.
3. **Staged, each stage corpus-green.** A foundation change that cannot land incrementally will not
   land at all. Every stage names the conformance cases that must stay green and the new ones it adds.
4. **Verification before completion.** Per spec §13: *a feature with no case in `conformance/` is
   unverified by construction.* Every stage lands with cases, and each new case must be **shown to
   fail before the change** — a case that passes both before and after guards nothing.
5. **The corpus must be deterministic, or it gates nothing.** Every stage below is gated on "corpus
   green". A flaky case destroys that gate in both directions: a real regression gets waved through as
   "just the flake", and a phantom sends someone hunting for hours. **`10_async_go` was that flake and is FIXED** (2026-07-15,
   ~20% → 0/50; corpus 25/25 × 3 full runs). It was four distinct scheduler bugs — see specs §10 #22 and
   `repro/async_scheduler_race.ky`. **The gate is usable; F1 may start.** A residual race survives
   (1 bad `await` in ~18k drives) but cannot realistically flake a 2-drive case. If a corpus run ever
   fails in an async case, suspect that residual before suspecting your change — and reach for
   `KYTE_THREADS=1` as the control, not ASAN, which is blind to it.
6. **The migration is named.** How the 329 stdlib annotations / 53 pointer sites / 9 scan sites are
   moved, and what breaks. "Mechanical migration" is not a plan until the mechanism is written down.
7. **What this does NOT fix** is stated explicitly, so the next person doesn't assume it.

---

## 4. How to read this if you are picking it up cold

Read in order: this file → F1 → F2 → F3 → F4 → F5. F2 is the keystone; F1 is what makes F2 possible;
F3/F4/F5 are what F2 is *for*. If you only read one, read **F2**.

The corresponding "what exists today" reference is `../specs.md` (inventory + reference + spec, and
the source of truth for current behaviour). The sequencing context is
`../kyte-readiness-roadmap.md` (workstream A) and `../kyte-language-evolution-plan.md` (L1, L3).
Where those disagree with a document here, **the document here is the design and specs.md is the
present tense**; update specs.md as each stage lands.
