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

## Null-coalesce present-path type reinterpret (`opt ?? Fallback().field`)

**Re-confirmed still latent 2026-09-02** by running the exact shape below with the shipped
`nova` binary: it compiles, and the PRESENT branch returns the optional's payload (a heap
pointer) reinterpreted as the fallback branch's type, with no type error.

```nova
class Box { pub v: int, init(x: int) { self.v = x; } }
fn present(): Box | undefined { return Box(7); }
fn fb(): Box { return Box(99); }
@test
fn coalesce_field_reinterpret(): void {
    let opt: Box | undefined = present();   // PRESENT
    // parses as `opt ?? (fb().v)`: present branch is Box (a pointer), fallback
    // branch is int. Should be a TYPE ERROR (mismatched `??` branch types).
    let n: int = opt ?? fb().v;
    // observed: n == a heap address (e.g. 4381662584), NOT 7 — the Box pointer
    // read as an int. Different value every run (classic pointer-as-int UB).
}
```

Two defects in one: (1) `.field`/`.method()` binds to the FALLBACK only (`opt ?? (fb().v)`),
so the accessor never applies to the unwrapped optional; (2) the type checker does not reject
`optional<T> ?? U` when `T != U`, so the present path silently reinterprets the payload.
The correct spelling parenthesises the unwrap: `(opt ?? fb()).v` — verified to return `7`
deterministically, so that is the workaround until the checker rejects the mismatched form.

When the check lands, move this into `expect_fail/` as a real case with
`// EXPECT-FAIL: typecheck`. Do NOT add it to `cases/` today — it compiles and mis-runs, so it
would make the corpus red. Ties the same pointer-as-primitive reinterpret class as `any`.

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
