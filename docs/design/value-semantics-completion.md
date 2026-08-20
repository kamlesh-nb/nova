# Value-semantics completion (escape-channel elimination)

Status: SCOPE (2026-08-20). Owner: language core. Prereq reading: `arc.zig`, `types.zig`
`computeValueEscapeSet`, memory notes `nova-struct-value-semantics-fix`, `nova-nested-value-struct-dtor-leak`.

## Goal

The spec says `struct` = value type, `class` = reference type (`is_reference = is_class`). Value-lowering
plus **inline nested value storage** already landed (commit 9171c76; corpus 346/347, ASAN clean). But
`computeValueEscapeSet` (types.zig:614) still keeps six struct *shapes* on the heap with refcounting, so for
those shapes `let b = a` aliases instead of copying. This is **memory-safe** (over-exclusion is the safe
direction; only *under*-exclusion is a UAF) but violates value semantics. This project eliminates the escape
channels one at a time, each gated, so every struct shape delivers true value semantics — closing the last
spec-conformance gap and unlocking stack allocation for these shapes.

Non-goal: forcing genuinely shared-mutable infrastructure to be value types. Those must migrate to `class`
(see Framework migration). The reverted "struct ALWAYS value" experiment broke 12 corpus cases precisely
because serde/DI/mediator/reactor/pool rely on reference semantics through structs that *should* be `class`.

## Current escape channels (each = a struct shape kept reference-semantic)

From `computeValueEscapeSet`:

1. **Return-construction / non-borrow return of a bare local** — a value struct constructed in a return, or
   `return localStruct`, escapes (a fresh stack alloca would outlive the frame). types.zig:624-641.
2. **Trait-implementing struct** (`impls.len > 0`) — can be widened to a fat pointer `{ptr,vtable}`, so it
   must be heap. types.zig:647.
3. **@serializable struct** — constructed/returned by a generated `<T>__bind` binder through a type-param-
   erased generic; the binder/generic-return path is not inline-aware. types.zig:653.
4. **Non-scalar / non-string / non-value-struct field** — a `class` field (correct: forces reference), but
   also a container / optional / array / decimal / function field forces the *whole* struct to the heap.
   types.zig:669-671. This is the highest-real-world-impact channel (DTOs with a `List`/`Map`/`decimal`).
5. **Direct type-param field `p: T`** — the monomorphized arg lands in a raw 8-byte slot. types.zig:690-702.
6. **Tuple / optional / error-union payload** — a value struct in one of these coercion slots is stored as a
   pointer to a stack alloca and would dangle. types.zig:710-715.

## Cross-cutting prerequisites (correctness — do FIRST)

- **P0 — transitive "needs a destructor" predicate. ✅ DONE (2026-08-20).** `valueStructHasOwnedFields`
  (types.zig) checked only DIRECT fields, so `Outer{inner:S{data:string}}` got no drop scheduled and leaked
  `S.data` (600-object ARC-audit leak). Fixed: made the predicate transitive (recurse into nested value-
  struct fields, cycle-guarded), and taught the function-scope cleanup `releaseLocalVariables` (arc.zig) to
  drop such value structs in place via `dropValueStruct` (it previously handled only the block-scope path).
  The struct destructor already recurses into inline value-struct fields; only the "schedule a drop at all"
  decision was non-transitive. Gate: corpus 386/389 + ASAN 386/389 (3 pre-existing: 118/189/42, baseline-
  confirmed), new case `381_value_struct_transitive_dtor` green on plain + `--arc` + `--asan`.
- **P1 — deep owned-field-nested retain-on-copy. ✅ DONE (2026-08-20). Was a real UAF, not just a leak.**
  `retainValueStructOwnedFields` (expressions.zig) retained only DIRECT owned fields, so copying
  `Outer{inner:S{data:string}}` shared `S.data` without a reference and dropping both the original and the
  copy double-freed it (heap-use-after-free, `nova_release`). Fixed: made retain transitive
  (`retainValueStructOwnedFieldsDepth` recurses into nested value-struct fields at their INLINE address,
  depth-guarded), mirroring the destructor's inline recursion. Gate: corpus 387/390 + ASAN 387/390 (3
  pre-existing), case `381` extended with heap-string copy tests at 1 and 2 nesting levels (ARC/ASAN clean).
  (The destruct side was already transitive after P0; this closes the copy side.)
- **P2 — compiler validation for impossible value structs. ✅ DONE (2026-08-20).** A value `struct` that
  transitively contains itself by value (`Node{next:Node}`, mutual `A{b:B}/B{a:A}`) was silently accepted
  (then mislaid out / crashed on use). Added `checkValueStructCycles` in `type_checker.zig`: a DFS over the
  by-value edge graph (a bare `.ident` field whose type is a declared VALUE struct; `class`/optional/
  container/tuple/array fields break the cycle), reporting a clear error at the offending field. Rejects both
  cycle shapes; accepts class linked-lists, optional/container self-reference, and non-cyclic nested value
  structs (verified, no false positives — a corpus scan found no real self-referential value-struct fields).
  Gate: corpus 389/392 (3 pre-existing) + two new `expect_fail` cases (value_struct_self_cycle,
  value_struct_mutual_cycle) rejected at typecheck.

## Framework migration (parallel, BEFORE broadening channel 4/6)

Audit structs used as shared-mutable references and migrate genuine singletons / stateful services to
`class`. Already done: web `App`/`ServiceProvider`/`ServiceCollection`, reactor `Poller`, `SlabPool`,
conformance Counter/Flag control blocks. Remaining: stateful repos/services in app templates. The escape
analysis cannot catch these (inline byte-copy silently COPIES a shared nested handle instead of sharing) —
they must be declared `class`. Skipping this is what crashed the reverted experiment.

## Channel elimination order (value/risk-ranked)

Each channel is an independent, gated increment. Over-exclusion stays the safe fallback until each is proven.

1. **P0 → P1 → P2** (correctness prereqs).
2. **Channel 6 (tuple/optional/error-union slots)** — make these coercion slots give value semantics.
   NOTE (2026-08-20): full inline-by-value storage in these slots needs a NEW tagged optional layout —
   value-lowering the inner struct breaks `== undefined` (an inline struct has no null sentinel; proven by
   experiment). So 6 splits per slot, and the optional slice uses **Design B** (below) instead of a layout
   change.
   - **6a — optional-of-value-struct. ✅ DONE (2026-08-20, Design B).** Keep the heap-pointer layout (so
     `== undefined` is untouched); make a borrow-RHS copy (`let b = a`) DEEP-COPY the payload
     (`buildOptionalStructDeepCopy`: if present, fresh `compileAlloc` + `buildValueStructCopyInto` +
     transitive `retainValueStructOwnedFields`; if absent, null through) instead of aliasing via retain.
     Scoped to optional payloads only, so the "Direction B" shared-state regression (12 cases when applied
     to ALL structs) did not recur. Gate: value semantics (`let b=a; b.x=99` leaves `a.x`), corpus 389/392 +
     ASAN 389/392 (3 pre-existing), case `382_optional_value_struct_copy` (plain + `--arc` + `--asan`).
   - **6b — tuple. ✅ DONE (2026-08-20), two steps.** (1) SEMA: the inferer left a tuple-index expression
     `unresolved`, so `t[0].x` failed as "unknown struct type"; added a `.tuple` case resolving a constant-
     index element's type, scoped to NON-primitive elements (a primitive stays unresolved to preserve the
     raw-64-bit-word scalar read that case 358 depends on -- typing scalar elements at 32 bits would change
     tuple int arithmetic to wrap, a separate language change). (2) VALUE-LOWERING: `let u = t` used to alias
     the tuple box; `buildTupleDeepCopy` (arc.zig) builds a fresh box and deep-copies value-struct elements
     (retaining owned non-struct elements, copying scalars) so the copy is independent. Gate: corpus 391/394
     + ASAN 391/394 (3 pre-existing), case `383_tuple_struct_element` (access + `t.0` desugar + owned field +
     copy-independence) on plain + --arc + --asan; 358 stays green.
   - **6c — error-union: SKIPPED as near-worthless (2026-08-20, user-confirmed).** Value-struct-in-error-
     union already works and is ARC/ASAN-clean, including holding + copying an unwrapped error-union. The
     only gap is a value-semantics aliasing *surprise*, and it is unreachable: error-unions are consumed by
     `try`/`catch` (which collapses to the ok type), so there is no path to hold one, copy it, unwrap BOTH to
     a shared struct, and mutate through one. Design B for it is also more complex than 6a (the box carries
     `[tag][payload]`, not just a pointer). Payload stays on the heap (safe, functional). The `.error_union`
     exclusion in `computeValueEscapeSet` is intentionally kept.
3-5. **Channels 1 (return), 3 (@serializable), 5 (type-param field). ✅ DONE together (2026-08-20).** All
   three keep a *pure value DTO* on the heap for a benign reason. Rather than three different ABI changes,
   one uniform Design-B fix closes them: `isPureValueStructName` (types.zig) = a declared `struct` with no
   trait impl and only scalar/string/nested-pure-value-struct fields (this STRUCTURALLY excludes channels
   2/4 -- the trait/container shared-state types that must NOT be deep-copied and crashed the blanket
   experiment). At the let-binding copy site, a borrow-RHS whose type is such a struct but is escape-excluded
   (`!isValueStructName && isPureValueStructName`) is DEEP-COPIED via `buildHeapStructDeepCopy` (fresh alloc +
   copy + transitive retain) instead of aliased. Gate: value semantics (`let b=a; b.x=99` leaves `a.x`),
   owned-field copies ARC/ASAN clean, corpus 391/394 + ASAN 391/394 (3 pre-existing). Case
   `384_returned_value_struct_copy`.
6. **Channel 2 (trait-impl)** — box at the widening point: copy the value into a heap allocation only when
   creating the fat pointer, so the struct is value-semantic everywhere else. Must pin the boxed lifetime.
7. **Channel 4 (container/optional/decimal fields) — LAST and HARDEST; a real sub-project (scoped 2026-08-20,
   NOT started).** A `List<T>` field is a value struct `{data: RawBuffer<T>, len, cap}` wrapping a heap
   `RawBuffer`. The concrete blocker: codegen's struct copy is a BYTE MEMCPY, so it copies the List field's
   `{ptr,len,cap}` and SHARES the buffer; the copy then diverges len/cap independently → corruption. Fix
   requires: (a) a container deep-copy / copy-on-write primitive (stdlib has only `slice`, no `copy` hook;
   `List.copy()`/`Map.copy()` need adding, retaining owned elements); (b) making the struct copy path
   FIELD-AWARE for container fields -- after the memcpy, replace each shared container field with a fresh
   deep-copy, which means invoking the per-element-type monomorphized container copy from
   `retainValueStructOwnedFields`/`buildHeapStructDeepCopy` (calling a monomorphized generic Nova method from
   codegen is the intricate part); (c) then let such structs into `isPureValueStructName`. High risk (this is
   the exact shape that crashed the blanket experiment; touches List/Map/Set). Memory-safe today (reference-
   semantic). Recommended: a focused session, List first, gated. The deeper alternative is the class-migration
   audit (make shared-state structs `class`, then containers-in-value-structs become rare).

## Verification (per increment)

Every channel lands with: full corpus green + `--asan` + `--arc`, plus a NEW positive case asserting value
semantics for that shape (`let b = a; mutate b; assert a unchanged`) AND its destructor is ASAN/ARC clean,
plus an `expect_fail` where relevant. The `NOVA_VALUE_STRUCTS_OFF=1` escape hatch stays as the bisection
tool (it flipped 192 to passing and localised the reactor regression last time).

## Effort

Multi-session. P0 is a single small session (highest ROI). Channels 6/1/3/5 are ~1 session each. Channel 2
and especially channel 4 are the hard tail (container COW is itself a sub-project). Recommended first step:
P0 (transitive destructor) — small, closes a real leak, and is a prerequisite for every channel.
