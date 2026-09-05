# Demand-driven monomorphization (build-speed) — Gap 8 / task #205

## Problem (measured, 2026-08-16)

A plaintext-HTTP web app (`plancksystems/perf/compare/kyte`) compiles **28,750** monomorphized
functions. From the T6 partition log:

- `list.ky` = 17,417 functions, `rawbuffer.ky` = 9,330 → **93% of the whole build**.
- ~500 crypto/TLS functions (p256/p384/rsa/x25519/aes/sha512/full TLS stack) for an app that never
  opens a TLS socket.

Two root causes, one fix:

1. **Type-instantiation-driven emission, not call-driven.** `collectFunctions`
   (`llvm_codegen.zig:2958,2973`) does `for (s.methods) × for (instantiationsOf(s))` — it emits the
   ENTIRE method surface of every seen generic instantiation, whether or not each method is ever called.
2. **Pruning too late.** The only dead-code removal is LLVM `globaldce` (`declarations.zig:1347`,
   `default<O0|O3>,globaldce`), which runs AFTER every function is codegen'd to IR + objects. With the
   T6 per-file split, cross-partition references keep the 17k `List` functions alive, so per-partition
   globaldce cannot drop them. All that LLVM time is spent on code that is either dropped or never used.

Debug already uses `O0` (fine). The 10-min build I hit was the O3 whole-program cost multiplied by the
10-30x over-emission, plus a one-time toolchain-bump cache-nuke.

## Fix: reachability-pruned emission (decl-level, call-graph-correct, type-arg-insensitive)

Compute the set of **function/method DECLS reachable from the program roots** via the call graph, and
emit `(instantiation × method)` only when that method's decl is reachable. Key insight: reachability is
computed on the DECL (SymbolId), context-insensitive on type arguments:

- `List.sort` reachable  ⟺  `sort` is called from some reachable decl. If reached, keep `sort` for
  EVERY `List<T>` instantiation (over-approximate → **sound**, never drops a live function). If never
  reached, drop `sort` for all `T`.
- The same walk drops unreachable modules: `aes.encrypt`'s decl is reachable only if TLS is reached
  from `main`, so a plaintext app never emits the crypto stack.

This avoids the hard part (per-instantiation type-substituted reachability) while capturing the win: the
reduction factor is `methods-used / methods-defined` per generic type, and unreachable subsystems drop
entirely.

### Roots (seed the worklist) — soundness-critical, from the codegen map

- **Entry:** `main` decl (native) OR every `@test` fn decl (`kyte test`, `tester.zig:28-46`). Mode-dependent.
- **Trait vtable slots (dynamic dispatch):** for every concrete type whose trait object is materialized
  (`constructTraitObject`/`getGlobalVTable:1650`), root ALL impl methods that can land in a vtable slot
  + slot-0 dtor. A method reachable only through `dyn` dispatch appears nowhere else.
- **serde binders:** a `serde.bind<T>` / `queryAs<T>` / `@serializable` use roots `T__bind` /
  `T__bindAll` / `T__serialize` (`pipeline.zig:846-975`; call sites `expressions.zig:3267…`). Address-
  taken by name, not a normal AST callee.
- **Closures/lambdas:** rooted transitively — a lambda is reachable iff its enclosing body is reachable
  (collected while walking reachable bodies, `declarations.zig:54-66`). `spawn`/`go` operands too.
- **Destructors:** demand-created at drop sites, so they piggyback on the code that drops them; but a
  live vtable's slot-0 dtor is an independent root (covered by the vtable rule above).
- **FFI/extern:** these are callees (imports), not roots.
- Conservative fallback: any decl the walk cannot resolve a callee for → keep (fail-open on that edge).

### Call-graph edges (how the walk resolves a callee)

Typed IR (`infer.zig TypedIr`): `expr_syms` (ExprId→SymbolId) is the call→callee-decl resolution;
method calls resolve to the method `mid` SymbolId (`infer.zig:1804`). Walk each reachable decl's AST
body; for each `call`/`generic_call`/`await`/`go`/`struct_init`/method-call, resolve the callee decl via
`expr_syms` and enqueue it. `struct_init` of `T` roots `T.init`/`new` and marks `T` constructed (for
serde/vtable/dtor rooting). Trait-object creation roots the concrete impl's vtable methods.

### Gate site

Filter `compiler.functions` between `collectFunctions` (`declarations.zig:52`) and the declaration loop
(`:824`), keyed by the mangled `FunctionInfo.name` OR by the method decl's SymbolId carried alongside.
Non-reachable, non-root functions are removed before any `LLVMAddFunction`/body emit. Everything the
runtime provides (kyte_* externs) is untouched.

## Phasing (measure-first, corpus-gated)

- **R0 — report-only shadow (`KYTE_REACH_SHADOW=1`).** Build the reachability walk + root set; compute
  the reachable decl set; PRINT `total / reachable / would-drop` counts and the full would-drop list.
  Emit nothing differently. Manually audit the drop list for anything live (a vtable method, a binder).
  Proves the win size AND that the set is a safe superset before any behaviour change.
- **R1 — gate emission.** Filter `compiler.functions` by the reachable set. Run the FULL conformance
  corpus + `--asan` + `--arc`. A missing root manifests as a link error (undefined symbol) or a crash —
  100% green under ASAN is the soundness proof. Measure build-time + function-count drop on the pizza app.
- **R2 — incremental follow-up (optional).** Finer partition granularity so the `List` partition is not
  one monolith (helps incremental rebuilds further). Not required for the headline win.

## Status (2026-08-19) — SOUND, default-ON for `kyte build`, corpus-gated

Implemented in `src/frontend/sema/reach.zig` (walk + gate). **`kyte build`: default-ON** (`KYTE_REACH_OFF`
is the escape hatch). `kyte test`: default-OFF, `KYTE_REACH_ON` opt-in (`KYTE_REACH_SHADOW` reports without
gating). The root design auto-roots **every free function + every method of a NON-generic struct** as walk
seeds, so the walk is sound against edges `expr_syms` doesn't model (trait/vtable dispatch, address-taken
serde binders, closures into higher-order fns). The gate then prunes only a **generic-struct non-constructor
method that NO reachable code calls**. Constructors (`init`/`new`) are always kept; `struct_init` and
`Type(...)`/`mod.Type(...)` construction sites root ctors explicitly.

**Soundness fix (2026-08-19): generic struct + trait impl.** A generic struct that IMPLS a trait has its
trait methods called through a VTABLE (dynamic dispatch), an edge the call-graph walk does not model.
Pruning such a method left the vtable slot pointing at a dropped function, so the first trait call CRASHED
at runtime (`307_generic_struct_impl_trait`, `364_generic_struct_trait_dispatch` compiled + linked, then
`Test process terminated abnormally`). Fix: a generic struct with any trait impl is treated as NON-prunable,
so all its methods are rooted (over-approximate, sound; only touches generic structs that actually implement
a trait). This bug was invisible to the plain corpus because that runs `kyte test` with the gate OFF, so a
new gate leg now re-runs the whole corpus with `KYTE_REACH_ON=1` (`gate.sh`) to keep the gate honest.

Measured on the pizza app (`plancksystems/perf/compare/kyte`, `[T6]` partition):

| | functions | list.ky | rawbuffer.ky |
|---|---|---|---|
| default (gate off) | 28,750 | 17,417 | 9,330 |
| gate on (sound)    | **12,468 (−57%)** | 4,355 (−75%) | 6,220 (−33%) |

Soundness so far (direct `kyte test`, gate on): all serde / trait-dispatch / closure / async / generic
/ enum / ORM / reactor cases exercised pass. `conformance/run.sh` cannot certify on this box — its
negative-classifier SELF-TEST fails environmentally (the crash self-test programs get SIGKILL'd with no
output → classified UNKNOWN → "HARNESS INTEGRITY BROKEN"), IDENTICALLY with and without the gate, so it
is not a gate regression; direct per-case invocation is the reliable check here.

Before default-on: broad direct-invocation batch green + `--asan` clean + a real app runs end-to-end.

## Verification

- `conformance/run.sh -j` (positive corpus) + `conformance/run.sh --asan` both green post-R1.
- Build-time + `[T6] function partition` total on the pizza app: before 28,750 → after (target: the
  reachable subset, expected 3-5x fewer). Report the measured delta, not a claim.
- Guard: keep `KYTE_REACH_SHADOW` report + a `KYTE_REACH_OFF` escape hatch to fall back to
  emit-everything if a soundness gap is found in the field.
