# Foundation (F1–F5) — Pending Work & Stability Impact

**Audited:** 2026-07-19 (this session), by direct code inspection — not doc-trusted.
**Gates at audit time:** conformance **72/72** · `--arc` **124/124** · `--asan` **124/124** · `--shadow` **124/124** · `zig build test` ✅.

> This file supersedes the "open" columns of `FOUNDATION-STATUS.md` and `resume.md`, both of which
> predate this session's landings (the ownership-pass **static balance check** `6b32c98`, the F4
> per-instantiation ownership IR that retired `keystoneSubst`, and decimal128 stages 1–3). Where they
> say a thing is "OPEN — the one hard blocker" (the chained-map leak, F2-6), it has since **landed**.

---

## 🎯 The headline

**No pending F1–F5 item is in the memory-safety class.** Every remaining item is a correctness *edge*,
a diagnostics/DX gap, or cleanliness/perf. The dangerous class — "codegen decides ownership/semantics by
string-matching type names" — is **closed and enforced**:

- The ownership pass computes owned/borrowed per expression and runs a **static balance check** for both
  locals (use-after-move) and temporaries (completeness) — a build error if violated (`ownership.zig:285`).
- The disposition oracle agrees with codegen **corpus-wide (disagree = 0)**, enforced as a build gate.
- `isRefCountedType` is demoted to a principled *fallback* (primitive table / erasure rule / enum
  registry / loud tripwire); no unprincipled string guess drives an ownership decision.
- `--asan` is a **required** gate (it catches the UAF/double-frees `--arc` is structurally blind to).
- Errors are **error-unions** (`try`/`catch` → ok/err basic blocks, not stack unwinding), so ARC × errors
  is ordinary control flow the pass handles — not an undefined unwinding path.

So the pending list below is about **polish, encapsulation, diagnostics, and code-size**, not about
whether the compiler emits safe code. That is why building stdlib/features on this foundation is sound.

---

## Severity legend

| Tag | Meaning | Can it corrupt / crash / leak? |
|---|---|---|
| 🟠 **Correctness-edge** | A silently-wrong result is *possible* in a narrow, uncommon case | No memory unsafety; wrong value/acceptance only |
| 🟡 **Diagnostics/DX** | Behavior is correct; the error is late or ugly | No |
| ⚪ **Cleanliness/Perf** | No behavior change at all | No |

---

## Pending items

### 🟠 Correctness-edge (2)

| Item | Stage | Current state | What's pending | Impact | Severity |
|---|---|---|---|---|---|
| **Cross-module visibility** | F1-4 | Imports are now kept and the symbol table records the import graph (`main.zig` F1-4 block; `symbols.build`). Resolution works. | `is_public` is **not enforced across modules** — `lower.zig` marks decls public and no pass rejects a cross-module reference to a `private` symbol. | A `private` item can be referenced from another module without an error. **Encapsulation gap, not a miscompile** — the reference resolves and runs correctly; the language just fails to *forbid* it. | Medium (in-progress) |
| **Explicit struct type-args** | F4-1 | `StructInit` type args are dropped at parse; instantiation relies on **inference** from field values, which covers the corpus. | Store and consume explicit `Foo<int>{ … }` type args. | In a case where inference cannot determine the element type (e.g. an explicitly-typed empty container), the type could fall to `unresolved` or mis-instantiate. Rare — no consumer exists yet, so adding storage without a consumer is premature. | Low–Medium |

### 🟡 Diagnostics / DX (2)

| Item | Stage | Current state | What's pending | Impact | Severity |
|---|---|---|---|---|---|
| **Unresolved-call = error** | F1-7 | An unresolved call silently does `return callee_name` (`types.zig:892,938`). | Make an unresolved call a located sema error. | An undefined call is still caught — but **late**, at codegen ("Identifier not found"), not as a clean sema diagnostic. Wrong code is rejected; the message is just worse. | Low |
| **End-of-sema undefined-ident fatal** | F2-5 | The codegen decision-site tripwire **is on** (`isOwnedTypeId(.unresolved)` → loud `exit 70`). The *earlier* end-of-sema ident fatal is **shadow only** — counted, not erroring (`infer.zig:613`), pending validation of the exclusion set + per-ident spans. | Enable the end-of-sema fatal. | Undefined idents are already caught (at codegen); this only moves the error earlier for a better message. Corpus proves the genuine-undefined count is 0. | Low |

### ⚪ Cleanliness / Perf / Code-size (5)

| Item | Stage | Current state | What's pending | Impact | Severity |
|---|---|---|---|---|---|
| **Erased generic body still emitted** | F4-5 | **Soundness closed**: ownership is decided from the per-instantiation IR (disagree = 0, gated); no ARC decision reads an erased `.type_param`. The erased body is still emitted as a **link fallback** (`types.zig:104` "the erased body, always") for generic-from-generic calls. | Thread instantiation context through every generic call so no site resolves to an erased body, then drop it + assert `.type_param` unreachable. | Extra code size + one more codepath. **Not soundness** — keeping it makes a resolution miss a missed *optimization*, not a crash. | Cleanliness |
| **Serde/harness into sema** | F4-6 | serde binders (`<Struct>__bind`) and the test harness are still **source-gen-and-reparse** (`llvm_codegen.zig:2252`); generated code is not sema-walked. | Generate binders directly in sema. | Generated calls miss the SymbolId path, so they rely on the func_map **suffix scan** (which keeps F1-3b's ~227-line scan alive) and don't get typed-IR guarantees. **A less-verified codepath** (latent surface), but no known bug. | Cleanliness → Low |
| **func_map suffix scan deletion** | F1-3b | SymbolId cutover done for **user-code** call paths; the scan physically remains as the fallback for the generated code above. | Delete the ~227-line scan — **gated on F4-6**. | Code size. Behavior-preserving fallback. | Cleanliness |
| **Honest int local slots** | F3-5 | Int **correctness is done** — arithmetic wraps at 32 bits via `canonicalizeInt` on every op (`19_int_overflow` passes). Only the **slot** is wide: int locals are stored in i64 (`slotTypeForLocal` returns `val_type` for non-float). | Narrow int slots to i32; optional overflow debug-trap. | Memory/perf only (8 bytes vs 4 per int local). No correctness change. | Perf |
| **Itanium mangling** | F1-6 | Mangling is `$HOME`-free and works via a 40-entry allowlist + `self`-spelling struct detection. | Length-prefixed Itanium mangling. | Theoretical name collision on a pathological identifier; not observed. Cosmetic. | Cosmetic |

---

## What is DONE (do not re-litigate — these were the risky parts)

- **Ownership / ARC** — acquisition rewrite (one principled `acquisitionDisposition`/`takeOwnedElement`
  decision from the TypeId store), per-instantiation ownership IR (`keystoneSubst` deleted), and the
  **static balance check** for locals *and* temporaries, enforced at build time. Cases 41–49 fixed 9
  real UAF/leak defects the corpus had been dodging. `--asan` + `--shadow` are hard gates.
- **F2 typed IR / F5 ownership decider** — every ownership decision is store/rule-based; `isRefCountedType`
  is a principled fallback only.
- **F3 primitives** — honest widths, int overflow wraps correctly, `decimal128` complete (all 3 stages:
  type/literals/toString, arithmetic + compare, BSON codec).
- **F4 generics** — bodies genuinely monomorphized with per-instantiation ARC; the `.type_param`
  corruption class and the chained-generic-method leak are both closed.

## Bottom line

The foundation is **safe to build on today.** The pending work is one encapsulation rule (F1-4, in
progress), a couple of nicer error messages (F1-7, F2-5), and code-size/perf cleanup (F4-5, F4-6, F3-5,
F1-6). None of it gates correctness or memory safety, so feature work (see `feature-roadmap.md`) can
proceed in parallel — with the standing discipline that **every new pattern grows the corpus and passes
`--asan`/`--shadow` before cutover.**
