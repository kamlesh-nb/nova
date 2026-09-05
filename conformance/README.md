# Kyte conformance corpus (roadmap workstream E2)

The **safety net** for the production-readiness work. Each `cases/*.ky` file is a
set of `@test` functions that pins current, known-good compiler/runtime/stdlib
behavior. Run it before and after every change so refactors (the C++20 runtime, the
type-checker work, the stdlib hardening) can't silently regress.

## Run

```sh
cd lang && zig build          # (re)build the compiler → ~/.kyte/bin/kyte
./conformance/run.sh          # run all cases
./conformance/run.sh 02       # run cases matching "02"
```

Exit code is non-zero if any case fails to compile/link or any test fails.

## Negative cases (`expect_fail/`)

Programs in `expect_fail/*.ky` **must fail to compile** — the runner reports PASS
when they're rejected and FAIL if one unexpectedly compiles (a check regressed).
This is the harness for verifying type-checker checks that *reject* code (A2
increment 2 / A3). Seeded with `undefined_variable` and `undefined_function`.

`expect_fail/PENDING.md` lists checks that *should* fail but don't yet (generic
arity mismatch, private-field access, arg-count/return/condition type errors) —
move each into `expect_fail/` as a real case once its check lands.

## Adding cases

Add a `cases/NN_topic.ky` with `@test fn` functions (see existing cases). Prefer
one concept per file. When you fix a bug, add a case that would have caught it — e.g.
`02_generics_destructor.ky` guards the duplicate-function link bug (a user struct
owning a `List<T>` failed to link with `undefined symbol _List_delete`).

## Coverage today (seed)

- `00_smoke` — arithmetic, while/if control flow, assert mechanics
- `01_collections_list` — `List<T>` push/get/set/size + growth
- `02_generics_destructor` — struct owning `List<T>` + `delete()` (link regression)
- `03_strings` — ASCII string ops (len/startsWith/contains/case/concat)
- `04_closures` — lambdas via `List.map`/`reduce` (guards the A1 closure rewrite)
- `14_collections_map` — `Map<K,V>` across resize + delete/tombstone churn, and the
  fn-value convention under it (guards specs §10 #16/#18: a bare `fn` stored then
  called through a local used to SIGBUS)

## TODO (grow alongside the roadmap)

- Set, enums + switch
  exhaustiveness, exceptions (try/catch/throw), fibers + channels, serde round-trips,
  numeric/UTF-8 edge cases. Add a **negative** suite (programs that MUST fail to
  compile) once the type checker is tightened (A3).
