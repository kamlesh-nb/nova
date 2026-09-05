# Boxed `any` — owned dynamic values (design)

**Decision (user, 2026-07-24):** `any` is a **boxed, owned** value, so a heap payload parked in a container
(`Map<string, any>`, di.ky's singleton cache) is RETAINED by the container and freed with it — fixing the
dangling-pointer gap of the interim unowned `.ptr` representation. See `kyte-any-ownership-model` (memory) for the
options considered; this is "option 1: box value types."

## Status

- ✅ **Runtime foundation LANDED + verified** (`src/runtime/alloc.cpp`, `kyte_abi.h`): `kyte_any_box(payload, dtor)`,
  `kyte_any_unbox(box)`, `kyte_any_box_dtor(box)`. Zero behavior change until codegen wires them.
- ⏳ **Interim state:** `any` lowers to `.ptr` (`src/sema/lower.zig`) — resolved + non-owned; corpus 149/149 +
  272/272 ASAN, gate `123_any_container`. The heap-in-container case is documented as the known gap the box closes.
- ⬜ **Remaining (this doc):** the type-variant + codegen wiring below. It is a corpus-gated increment — the corpus
  includes the flagship mediator cases (`56_typed_mediator`, `58_typed_routing`) which exercise the `any` surface,
  so keeping them + `123` green (+ ASAN) validates the flagship is not broken. Revert path: keep `any`→`.ptr`.

## Box representation

A box is a normal ARC object (`kyte_bytes_alloc(16)`, rc=1, 8-byte header at `[ptr-8]`):

```
[payload: i64][dtor: i64]      // returned pointer is the payload word's address
```

- `payload` — the value word: an int inline, or a pointer to a heap object.
- `dtor` — the payload's destructor fn-pointer, or **0** for immediates / non-owned payloads.
- Boxing **MOVES** the payload's +1 into the box (no extra retain). Releasing the box calls `kyte_any_box_dtor`,
  which `kyte_release`s the inner value via `dtor` (if non-0); the box's own bytes are then freed by the
  `kyte_release(box, kyte_any_box_dtor)` that invoked it.

## Type system

1. **`types.zig` `Type` union** — add a nullary variant `any`. Represented as a machine word (a box pointer).
2. **`types.zig` `isOwned`** — `.any => true` (the box is an ARC allocation). `isOwnedSafe` inherits via `else`.
   Update `hashType`/`eql` for the new nullary variant (trivial).
3. **`sema/lower.zig`** — lower the `any` ident to `.any` (replace the interim `return self.store.ptrT()` for
   `any`). This is the one-line flip from `.ptr` back to a dedicated owned type.
4. **Exhaustive-switch ripple** — `zig build` will error on every unhandled `.any` arm across
   `main.zig`, `sema/{symbols,infer,mono,subst,shadow}.zig`, `codegen/{types,arc}.zig`. For each: treat `.any` like
   a nullary word type (mirror the `.ptr`/`.string` arm as appropriate — representation like `.ptr` (a word),
   ownership like `.string` (owned)). The Zig checker guarantees none is missed.

## Codegen

5. **LLVM type** (`codegen/types.zig`): `.any` → `val_type` (the machine word; the box pointer).
6. **`isOwnedTypeId`** (`codegen/types.zig`): `.any => true` (via `st.isOwned`).
7. **Destructor for `.any`**: `getOrCreateDestructorByTypeId(.any)` → the runtime `kyte_any_box_dtor` (register it
   in `func_map`, `declarations.zig`, like the other `kyte_*` intrinsics). So when a container element / local /
   field of type `any` is released, ARC calls `kyte_any_box_dtor`, which frees the inner value.
8. **Register intrinsics** (`declarations.zig`): `kyte_any_box` (i64,i64→i64), `kyte_any_unbox` (i64→i64),
   `kyte_any_box_dtor` (i64→void) in `func_map`.

### Box at `T → any` coercion (the crux — 4 site categories)

Box exactly when a **concrete** value becomes `any` (never re-box an already-`any` value). At each site: resolve
the source expr's type; if it is `any` already → pass through; else emit
`kyte_any_box(value, <dtor-of-T or 0>)` where the dtor is `getOrCreateDestructor(T)` when `isOwned(T)`, else 0.
The four categories (the same insertion points trait-widening uses):

- **(a) Return coercion** — a fn/closure whose declared return is `any` returning a concrete `T`. **This is di.ky's
  main path** (factory closures `(sp) => { return Logger(9); }`). Hook where the return value is coerced to the
  declared return type.
- **(b) Argument passing** — calling a fn whose param is `any` with a concrete arg (`map.set(k, L(7))`). Hook in the
  arg-coercion loop (near the trait-widening arg check, `expressions.zig` ~441).
- **(c) Slot store** — `let a: any = L(7);` / assigning a concrete value to an `any` field or container slot. Hook
  in the let/field/element store coercion (`statements.zig` let-store, `coerceToSlotType` neighbours).
- **(d) Enum payload** — constructing a variant whose payload type is `any` with a concrete value
  (`Resolved.Ok(x)` when `x` is concrete). Hook in enum-variant construction.

### Unbox at `any → T` (`as`)

- **`.cast` handler** (`expressions.zig` ~3698): if the source expr's type is `any` and the target is a concrete
  type (not `any`/`void`), emit `kyte_any_unbox(val)` and reinterpret as `T`. One site. (Optionally, later: check
  the box's `dtor`/a type tag for a *checked* cast that traps on mismatch — not required for v1.)

### Consistency invariant (the thing to get right)

**Every** `T→any` producer boxes, **every** `any→T` consumer unboxes. If a producer is missed, a later
`kyte_any_unbox` reads a non-box word → garbage/crash. The corpus flagship cases (56/58) + di (`123`) + ASAN are the
gate that this invariant holds. Bring the gate up green before considering it done; if a site resists, revert to
`.ptr` and keep this doc + the runtime foundation.

## DoD

- [x] Runtime `kyte_any_box`/`_unbox`/`_box_dtor` (landed, verified compiling).
- [ ] `.any` variant (owned) + lower `any`→`.any` + exhaustive-switch ripple resolved.
- [ ] Box at (a)-(d); unbox at `.cast`; `.any` destructor = `kyte_any_box_dtor`.
- [ ] Gate `123_any_container` EXTENDED to re-add the struct-parked-in-container case (which must now read back
      correctly, tag 7 not garbage) + a second-resolve of a singleton heap service.
- [ ] Full corpus + ASAN green (flagship 56/58/69 included); ARC-audit at floor.
