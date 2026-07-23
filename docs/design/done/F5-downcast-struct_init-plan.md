# F5 fix plan — trait downcast ownership + `struct_init` temporaries (land together)

Status: PLANNED (2026-07-18). Fixes task #13. Non-corrupting leaks today; the fix is corruption-prone
if done in halves, so this documents the *coordinated* change and its refcount derivation before code.

## The two defects, and why they are one fix

**Leak (what we want to fix).** A struct *literal* passed as an owned argument a callee stores leaks:
`xs.push(User{...})`, `m.set(k, User{...})`. Root: `.struct_init` is not registered as a drainable
temporary (`producesOwnedTemporary`, expressions.zig), while constructor results are. So `push`
retains its stored copy (rc 2) and nothing drains the literal back to 1.

**Why the obvious fix (make `.struct_init` a temp) crashes.** It exposes a *second*, compensating
defect in the trait **downcast** `x as T` (expressions.zig:2719–2732): the downcast loads the struct
pointer out of the fat pointer and returns it **as a borrow — no retain** — yet `let m = msg as T`
binds `m` as an owned local that `releaseLocalVariables` releases at scope exit. Today that
scope-release is *exactly* what consumes the struct literal's construction ref, because the literal is
not also a temp. Add `.struct_init` as a temp and you introduce a THIRD release → use-after-free via
`__destruct_trait`.

**Minimal repro** (scratchpad `probe/13c_downcast.nova`): struct literal → trait arg → `let m = msg as
Doubling`. Clean today; UAF with `.struct_init` as a temp. `--asan` catches it; **`--arc` reports it
CLEAN** (object ends at rc 0, nothing "live at exit"). Simple trait-arg coercion *without* a downcast
(constructor or literal, single dispatch — probes 13a/13b) is already clean under `.struct_init`-temp.
`12_traits_dispatch` crashes only because `DoublingHandler.handle` does `msg as Doubling`.

## Refcount derivation (the proof the fix balances)

Notation: rc of the concrete struct. `T` = the struct-literal caller temp (new). `FP` =
`constructTraitObject` fat-pointer temp (existing). `__destruct_trait` releases the struct once (the
retain `constructTraitObject` takes at llvm_codegen.zig:1114). Drain order is LIFO.

Case `useMsg(Doubling{val:21})` where `useMsg` does `let m = msg as Doubling`:

| step | today (literal NOT a temp) | naive (literal a temp, downcast still borrow) | **FIX (literal a temp + downcast retains)** |
|---|---|---|---|
| literal built | rc 1 | rc 1, temp **T** | rc 1, temp **T** |
| coerce to trait arg (retain) | rc 2, FP temp | rc 2, FP temp | rc 2, FP temp |
| `let m = msg as Doubling` | m = borrow (no retain) | m = borrow (no retain) | **downcast retains → rc 3**, m owns |
| callee scope exit: release m | rc 1 | rc 1 | rc 2 |
| caller drain FP → `__destruct_trait` | rc 0 ✅ | rc 0 | rc 1 |
| caller drain T | — (no T) | **rc −1 → UAF** ❌ | rc 0 ✅ |

The fix column balances: two owning refs contributed (construction + `constructTraitObject` retain +
downcast retain = 3 "+1"s) against three releases (m scope-exit + `__destruct_trait` + T drain). The
today column balances only by *omitting* both T and the downcast retain — two wrongs cancelling.

Neither half is safe alone (both leak without the other — verified by derivation and by probe): this
**must land as one change**.

## The change

Two edits, plus verification.

### 1. `producesOwnedTemporary` (expressions.zig) — register struct literals

```zig
.struct_init => true,
```
Add to the `=> true` set. Gated downstream by `isOwnedExpr` in `compileExpression` (a struct type is
owned), so only owned struct literals register; the `.type_name` for the drain destructor comes from
`resolveExpressionTypeName` (yields e.g. `"User"`). This is the whole leak fix on its own — it is the
downcast that makes it unsafe, addressed next.

### 2. Trait→struct downcast (expressions.zig:2727–2731) — make `m` a real owned ref

Today:
```zig
if (self.traits.contains(src) and self.isStructType(target)) {
    const sp_ptr = ...;
    return core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "downcast_struct_ptr");
}
```
Change to retain the extracted struct AND register it as a temporary, so it is a normal owned producer
(consumed by `let m = ...`, or drained if used inline like `(msg as T).field`):
```zig
if (self.traits.contains(src) and self.isStructType(target)) {
    const sp_ptr = ...;
    const struct_ptr = core.LLVMBuildLoad2(self.builder, self.val_type, sp_ptr, "downcast_struct_ptr");
    // The fat pointer OWNS this struct (constructTraitObject retained it); the downcast previously
    // returned a BORROW, and `let m = msg as T` then released m at scope exit anyway — balanced only
    // because struct literals were not temps. Retain so m is a genuine independent owned reference,
    // then register it as a temporary so an unbound `(msg as T).f` also drains. Pairs with
    // `.struct_init` becoming a temp; neither is correct alone.
    try self.compileRetain(struct_ptr);
    try registerTemporary(self, struct_ptr, try self.allocator.dupe(u8, target));
    return struct_ptr;
}
```
Do NOT add `.cast => true` to `producesOwnedTemporary` — that would wrongly register the pass-through
and numeric cast results too. The registration is inline here, scoped to the trait→struct arm only
(the same discipline `.try_expr` uses at expressions.zig:2462).

## Verification matrix (gate hard on `--asan` — `--arc` is blind to these UAFs)

Build both runtimes (`zig build`, `NOVA_ASAN=1 zig build`). Every row must pass `--arc` AND `--asan`.

Fixes (must flip from broken→clean):
- probe 13c (downcast of a struct-literal trait arg) — was UAF under the naive change.
- `12_traits_dispatch` (mediator: `msg as Doubling` in `handle`) — was UAF under the naive change.
- probe 01 / 01d (`m.set(k, User{...})`, `xs.push(User{...})`) — was LEAK(2).

Must stay clean (regression surface for the two edits):
- `13_serde` — uses trait downcasts and struct fields heavily.
- let-trait binding with a struct **literal**: `let s: Speaker = Cat{}` (not `Cat()`) — struct_init-temp
  now interacts with statements.zig:127 (single-binding consume) + 168–184 (manual orig_struct
  release). Add a probe; the corpus only has the constructor form `Cat()`.
- return-trait with a struct literal: `fn f(): Speaker { return Dog{} }` — statements.zig:391–401.
- downcast of a NON-temp source: `let s: Speaker = Cat(); let c = s as Cat;` — s is a variable; the
  downcast retain must balance against c's scope release, s untouched.
- downcast used inline, unbound: `return (msg as Doubling).val;` — the temp must drain.
- numeric / pass-through casts (`x as int`, `x as f64`) — must be UNAFFECTED (no retain, not registered).
- full corpus, `--arc`, `--asan`, `--shadow`, `zig build test`.

New corpus cases to add once green: promote probe 13c and a downcast/mediator case; add the let-trait
and return-trait struct-literal forms — these patterns are exactly the coverage the corpus lacked and
that hid the defect.

## Risk & sequencing

- The refcounts run through trait dispatch, downcast, and Map storage; balances are subtle and the
  corpus has coverage gaps, so a wrong version reads as green under `--arc` while corrupting. `--asan`
  is the real gate. Do not commit on `--arc` alone.
- Land both edits in ONE commit (they are unsafe apart). If `--asan` shows any UAF/leak in the matrix,
  revert whole — do not patch individual sites, re-derive the table first.
- This unblocks registering `.struct_init` as a temp, which is also the precondition for cleanly
  fixing task #14 (error-union `try` box) the same way (register the box as a draining temp) once its
  type-string canonicalization lands.
```
