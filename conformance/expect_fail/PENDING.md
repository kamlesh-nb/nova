# Pending negative tests (checks that SHOULD fail but don't yet)

These document real soundness gaps. Each snippet **currently compiles** but *should* be a
compile error. When the check lands, move the snippet into `expect_fail/` as a real `.nova`
case with an `// EXPECT-FAIL: typecheck` directive — the harness then verifies it is rejected
**for that reason**.

Do NOT put these in `expect_fail/` yet — they'd make the harness red (they compile).

> **Audited 2026-07-17.** Every claim below was re-verified by running it. Three entries were
> stale (documented as pending/blocked while actually enforced) and one — return-type — was the
> reverse: documented DONE while **silently regressed**. Do not trust this file without a run;
> that is exactly how the regression survived. See `docs/beta-readiness-plan.md` §0.

---

## ✅ DONE — enforced, verified 2026-07-17

- **Generic instantiation arity mismatch** → `generic_arity_mismatch.nova`
- **Type args on a non-generic type** → `type_args_on_non_generic.nova`
- **Duplicate type parameter names** → `duplicate_type_param.nova`
- **Condition must be boolean** → `non_bool_condition.nova`
- **Assignment (let-init) type mismatch** — `isTypeCompatible` is numeric⇄numeric only.
- **Argument count mismatch** → `wrong_arg_count.nova`. *(Was documented "BLOCKED on namespaced
  resolution"; that is **stale** — F1 stage 3a's ambiguity-is-an-error check unblocked it and it
  now rejects with no stdlib false positives. Verified by running PENDING's own snippet.)*
- **Constructor arg count** → `constructor_arg_count.nova`
- **Narrowing / signedness / ptr truncation / int literal overflow / decimal** → their own cases.
- **Return type mismatch** → `return_type_mismatch.nova`.
  ⚠️ **This check REGRESSED and was repaired 2026-07-17.** `checkReturnType` exempted *every* int
  literal (`if (intLiteralValue(value) != null) return;`) so that `return 4000000000` from a `uint`
  fn could adapt — but the exemption was unconditional, so **`fn f(): string { return 42; }`
  compiled and segfaulted**. The exemption is now gated on the declared return being numeric.
  The harness could not see the regression because it judged negative cases on exit code alone and
  **a segfault also exits non-zero**; it now asserts the *reason*.

---

## Optional narrowing — RESOLVED at runtime (P2-14, 2026-07-17); compile-time enforcement still pending

✅ **The live SEGFAULT is FIXED.** `let s = l.get(5); let n = s.length;` on an absent optional
used to read through address 0 and SEGV. It now ABORTS with
`member access on an absent optional at <file>:<line>` — codegen guards a member deref whose
object is optional-typed (specs §3.4, gated by `cases/38_optional_deref_guard.nova`; corpus
ASAN-clean). See-through ergonomics (`xs.get(i).field`, commit 950495c) are kept; the guard is a
no-op on present values.

**Still PENDING: COMPILE-TIME rejection.** Catching unnarrowed optional use statically — the spec's
original intent — is the soundness endgame, but it needs flow-narrowing better than today's
branch-scoped rule (§3.4a: an early-exit `if (x==undefined) return;` does not narrow after it) or
optionals become painful. These are the cases that should eventually be a compile error rather than
a runtime trap:

```nova
let s: string | undefined = "hi";
let x: string = s;                 // should ERROR: string | undefined is not string
let n = takes(s);                  // should ERROR: passing optional where string expected
fn f(): string { return s; }       // should ERROR: returning optional as T
```
`type_checker.zig` has no narrowing machinery (every "narrow" hit is integer-width conversion) and
no `.optional` arm in the field-access path, so none of these is caught today. The runtime guard
makes the member-deref case memory-safe; these assignment/pass/return cases are not yet even
runtime-guarded (they do not deref), and are the remaining static-soundness work.

## Tuples are invisible to the type checker (plan P2-18)

No `.tuple` case in `resolveExprType`; **`ls.names` — the destructuring field — is never read in
`type_checker.zig`**, so destructured bindings are never registered and have no type.

```nova
fn divide(a: int, b: int): (int, string) { return (a / b, "err"); }
@test
fn t(): void {
    let (v, e) = divide(10, 2);
    let n = v + e;                 // ERROR: int + string. Compiles → 4304536869 (a raw pointer)
    let (a, b, c) = divide(1, 1);  // ERROR: 3 names from a 2-tuple. Compiles, reads out of bounds
}
fn bad(): (int, string) { return (1, "x", 42); }  // ERROR: 3-tuple from a 2-tuple signature
```

Also **not** a type-checker issue but recorded here because it is the same feature: every tuple
leaks its box and elements (`28_tuple_return_heap` = 68 live, `29_http_request_parse` = 46 — see
`arc-baseline.txt`), and `return t` via a local is a **use-after-free** (the retain guard is
syntactic on `v.kind == .tuple`, so it only fires for a tuple *literal* in return position).
Full detail: `docs/route-handling-via-mediator.md` §8.D.

## ✅ Null-coalesce present-path type reinterpret (`opt ?? Fallback().field`) — CHECK LANDED 2026-09-03

Now enforced: `expect_fail/null_coalesce_scalar_reinterpret.nova`. The type checker rejects a
`??` whose unwrapped-present type and fallback type are a scalar-vs-heap-aggregate mismatch (the
pointer-as-scalar reinterpret shape), e.g. `Box | undefined ?? int`, with a diagnostic that also
points at the usual cause: `.field`/`.method()` binding to the FALLBACK
(`opt ?? fb().field` parses as `opt ?? (fb().field)`; parenthesise as `(opt ?? fb()).field`).

The guard (`type_checker.zig`, `nullish_coalesce` case in `resolveExprType` +
`isScalarReinterpretMismatch`) is deliberately narrow to avoid false positives from the
best-effort resolver: it fires ONLY on scalar<->heap-aggregate pairs (numeric<->numeric,
text<->text, trait<->struct are all left alone), and ONLY when the left operand is resolved
through a reliable path (`leftTypeIsReliableForNc` excludes bare-name free-function calls, whose
flat by-name table mis-resolves `parse(x)` across modules). Full corpus stayed 444/444.

## Private field access from outside the struct (F1 stage 4)
```nova
struct Secret { hidden: i32, init() { self.hidden = 5; } }
@test
fn t(): void {
    let s = Secret();
    let v = s.hidden;          // ERROR: 'hidden' is private (compiles today)
}
```
Enforcing it will break stdlib code — size that in F1 stage 4 (`F1-name-resolution.md` §6 Q3).

## Four cases reject by CRASHING the compiler, not diagnosing (plan P0-5)
`undefined_variable`, `undefined_function`, `method_shadowed_by_global_fn`, `ambiguous_bare_call`
exit non-zero via an unhandled Zig error + stack trace rather than a user-facing diagnostic. They
are marked `// EXPECT-FAIL: compiler-crash` so the debt is visible instead of passing as if it
were a real error message. Each should become `typecheck`.
