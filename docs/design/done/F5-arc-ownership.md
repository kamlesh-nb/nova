# F5 — ARC ownership model

**Depends on:** F2 (ownership must be a property of a *type*, not a spelling), F4 (a destructor cannot
release an element whose type it does not know), F3 (what is a pointer vs a number).
**Absorbs:** roadmap **A1 remaining** (ARC on closure envs) and **C1** (element leaks).
**Status:** 🔨 **SUBSTANTIALLY LANDED — this header said `Design` after ~8 fixes shipped.**
§3.4c–3.4j landed (temporary rule, break/continue exits, trait co-ownership, refcounted
closures, …). **Corpus ARC 2513 → ~211 live**, most cases at the floor of 3.
**Open: stage 2a (static fn boxes writable + sentinel — ORDERING-CRITICAL, must precede stage
3)**, stage 2 (`isOwned(TypeId)`), 4 (O4 enforced), 5 (reified destructors), 6.
✅ **Stage 5 is UNBLOCKED**: `Map` is on `Storage<K>`/`Storage<V>` and **`retainIfGenericStore` is
deleted** (verified 2026-07-17) — the §3.4b/F4 note saying otherwise is stale.
⚠️ **The two largest remaining leaks are TUPLES** (`28_tuple_return_heap` 68,
`29_http_request_parse` 46 — ~108 of ~118 above-floor objects). See `../conformance/arc-baseline.txt`.
⚠️ **ARC × unwinding is UNDEFINED**: §3.4e found `break`/`continue` — 'the exits that JUMP' —
released nothing. **A `throw` is a third jumping exit and is covered by no rule** (plan P2-12).
*(Corrected 2026-07-17 — see `../beta-readiness-plan.md` §1.)*

---

## 1. The claim

> ARC is **retain-only for generics**. `+1` on the way in, `+0` on the way out. Exactly one leaked
> refcount per element, by construction — not a bug in the implementation, but the arithmetic the
> current design produces.

And the second claim, which matters more:

> **There is no ownership model.** There is no document, anywhere, stating who owns what and where
> retain/release are inserted. `list.ky:165` asserts a rule the compiler never implemented. This
> document is the model that was missing.

---

## 2. Current state (measured, file:line)

### 2.1 The asymmetry

**Retain side** — `arc.zig:41-47`:
```zig
pub fn retainIfGenericStore(self, expected_type: []const u8, arg, val) !void {
    if (expected_type.len != 1 or expected_type[0] < 'A' or expected_type[0] > 'Z') return;
    const arg_type = (try self.resolveExpressionTypeName(arg)) orelse return;
    if (self.isRefCountedType(arg_type)) try self.compileRetain(val);   // +1
}
```
When a parameter is declared `T`, the compiler **peeks at the call site's concrete type** and retains.
`xs.push("elem")` → `+1`.

**Release side** — `arc.zig:80-152` `getOrCreateDestructor`:
```zig
const base_struct = getStructBaseName(type_name);   // :81 — "List<string>" -> "List"
```
The destructor calls `{Struct}_delete` if it has 1 param (`:107-122`), then releases each ref-counted
**declared field** (`:125-143`). `List<T>`'s fields are `data: i32`, `len: i32`, `cap: i32` — all
primitives. **Nothing is released.**

Two independent reasons the elements are invisible:
1. `isRefCountedType("T")` → `false`, hardcoded (`arc.zig:13-15`).
2. Elements live inside `data`, a raw `bytes.alloc_persistent` buffer written via `bytes.write_ptr`
   (`list.ky:4-9`). **ARC has no view into raw memory.** Even if (1) were fixed, there is no traversal.

### 2.2 The measurement that proves the model

Peak RSS, `/usr/bin/time -l`, dose-response (2026-07-15):

| Program | Scaling | Verdict |
|---|---|---|
| baseline, no alloc | — | 5.9 MB |
| `List<int>` × 100 elems | 200k→495MB, 3.2M→**618MB** | **bounded** |
| `List<string>` × 20 elems | 50k→66.7MB, 200k→249.8MB, 800k→**927.4MB** | **linear, unbounded** |
| closures (box+env) | 1M→51.9MB, 4M→189.5MB, 16M→**740.4MB** | **linear, unbounded**, ~46 B each |

**`List<int>` is bounded.** `int` is not ref-counted → no retain → nothing to leak. Same code, opposite
behaviour, explained by §2.1 exactly. *(Measured as `List<i32>`, today's spelling — `i32` and `int` are
the same type until F3 lands.)*

This is the key diagnostic result: **the allocator, buffer reuse, and `List.delete()` all work.** The
defect is *exclusively* the release of ref-counted things. Everything else is fine.

### 2.3 Automatic destruction already works

Worth stating plainly, because it changes the size of this problem:

`releaseLocalVariables` (`arc.zig:153-198`) releases every ref-counted local at scope exit, calling
`getOrCreateDestructor`, which invokes `<Struct>_delete`. **`delete()` is a destructor hook — `deinit` —
and it is called automatically.** A user does not, and must not, call it.

`List<int>` being bounded is the proof: its buffer is freed with no explicit `delete()` anywhere.

**So the model is already Swift-shaped.** The hole is narrow and specific: *ARC cannot see through a
generic into a raw buffer.* F5 is not "build ARC" — it is "close the two holes".

### 2.4 The false comment

`list.ky:165-170`:
> *"ARC: elements are reference-counted; ARC releases them, **NOT this method**. The old pre-ARC loop
> `bytes.free`'d each element by raw pointer — wrong under ARC…"*

The reasoning for *removing* the old loop was correct — freeing by raw pointer ignored refcounts and
corrupted the heap for value elements. But the replacement it names **does not exist**. The stdlib was
written against a contract the compiler never signed.

`arc.zig:34-40` is honest about it:
> *"Elements then leak on container drop **until reified-generic destructors exist**, which is acceptable
> versus a crash."*

Both comments are correct about their local decision. Neither is wrong. **The gap is that no document
owned the invariant across them.** That is what this file is for.

### 2.5 Closure envs

`isRefCountedType` (`arc.zig:19-20`): a type whose *name contains* `"=>"` or `"->"` → `false`. So closure
boxes are never retained or released. Box and env are `alloc_persistent`'d
(`expressions.zig:1676`, `:1689`) and **nothing frees them** — ~46 B leaked per closure created, forever.
Captured ref-counted values are never released either.

Roadmap A1 flagged this on delivery: *"env/box use `kyte_bytes_alloc_persistent` (they leak, same as the
old scheme — no regression) → add ARC on environments + retain captured ref-counted values."*

### 2.6 The arena confound

`kyte_bytes_alloc` (`alloc.cpp:45-78`) bump-allocates from a **per-thread 32MB arena**, and arena objects
are **refcount-exempt** — `kyte_retain`, `kyte_release`, `kyte_bytes_free` are all no-ops for them
(`alloc.cpp:105-113`, `:114-125`). The pointer only moves forward; the arena is never reset. Past 32MB,
allocations fall back to `malloc` and *are* honestly counted.

**Consequence for anyone measuring ARC:** in the first 32MB per thread, ARC bugs are invisible — retain
and release both no-op, so an imbalance has no effect. `-DKYTE_DROP_ARENA` exists precisely to expose
this (*"Reveals latent retain/release imbalances the arena used to hide"* — `alloc.cpp:49-52`).

**Every ARC correctness test in F5 must run with `KYTE_DROP_ARENA`.** Without it, a passing test proves
nothing. This is why §2.2's numbers are the ones that matter — they exceed 32MB.

---

## 3. Target model

### 3.1 Ownership rules — the thing that did not exist

Stated so a violation is mechanically detectable.

**O1 — Every value has exactly one owner at a time.** A ref-counted value's refcount equals the number
of live owning references.

**O2 — What is owned.** `string`, `struct`, `enum` with ref payload, `List`/`Map`/collections, closure
box+env. **Not owned:** primitives, `ptr` (F3 — explicitly unowned), trait vtables (static), string
literals (refcount sentinel `100000000`, `llvm_codegen.zig:357`).

**O3 — Owning locations** are: a local/param slot, a struct field, a collection element, a closure env
slot. Each is `+1`.

**O4 — Transfer points, exhaustively:**

| Point | Rule |
|---|---|
| `let x = e` | `e` produces owned → move (no retain). `e` borrowed → retain. |
| `x = e` (assign) | retain new, **release old**, in that order. |
| store to field | retain new, release old |
| push into a collection | **retain** (collection becomes an owner) |
| pop/remove from a collection | **transfer** to caller; no retain, no release |
| pass as argument | **borrow** — callee does not retain unless it stores |
| return | transfer to caller |
| capture into closure env | **retain** (env becomes an owner) |
| scope exit | release every owned local |
| destructor | release every owned field **and every owned element** |

> ### ⚠️ O4 rule "return | transfer" is NOT IN FORCE (found 2026-07-16)
>
> **`Storage<T>.get` does not retain.** Measured: `List_string_get` has `retain=0, release=0`.
>
> `a53827f` — *"fix(F5 O4): `Storage<T>.get` transfers ownership — a read returns +1, not a borrow"* —
> **landed in dead code.** There were TWO Storage implementations with exactly opposite semantics:
> `expressions.zig` (live — `get` does not retain, `set` retains + releases old) and
> `compileStorageCall` in `llvm_codegen.zig` (dead — `get` retains, `set` does not). The call-expression
> path reaches a Storage call first, so `compileStorageCall` never ran: instrumented across the whole
> corpus, **zero hits**. It has been deleted (2026-07-16); IR byte-identical on all 17 cases, which is
> what "dead" means.
>
> **What this invalidates.** a53827f's reasoning — "`Storage<T>.get` now retains (O4: return |
> transfer), which makes 'a call result is owned' TRUE, which makes this rule sound" — is quoted in
> `retainIfGenericStore`'s doc comment and in F4 §5. It is false: whatever stabilised
> `12_traits_dispatch`, it was not that code, because that code never executed. **Do not reason from
> "every call returns owned"** — the live `get` returns a borrow.
>
> **`set` DOES retain and release the old**; that half of O4 is real, and it is what keeps a
> container's elements alive.
>
> **Consequence for §3.4b's chain.** "Map on `Storage<T>` → `Map.get` returns owned → the Level-0 borrow
> dies" **only holds if `get` retains**. Migrating `Map` alone would move it onto Storage and leave
> `map.ky:125` a borrow exactly as it is. So `get`'s retain must be enabled first — and it cannot be
> enabled alone: `List.grow`'s `newData.set(i, self.data.get(i))` becomes `+2` with nothing owning the
> temporary. **get-retains and temporary-release land together, or neither** (the "three rules are ONE
> system" note above, now with a concrete instance).

**O5 — A destructor releases everything it owns.** Fields *and* elements. Requires F4: the element type
must be known.

**O6 — Retain and release are symmetric and paired.** Every `+1` has a matching `-1` on a path an
invariant checker can enumerate. The current `retainIfGenericStore` (§2.1) violates this by construction
and is deleted.

**O7 — ARC is inserted by a pass over F2's typed IR**, not decided ad-hoc at emission. Ownership is a
function of `TypeId`, never of a name.

### 3.2 `isRefCountedType`, corrected

```zig
pub fn isOwned(store: *TypeStore, id: TypeId) bool {
    return switch (store.get(id)) {
        .prim, .ptr, .void => false,
        .string, .struct_, .array, .tuple => true,
        .func => true,                       // <-- closure box IS owned (fixes §2.5)
        .enum_ => |e| enumHasRefPayload(store, e),
        .optional => |inner| isOwned(store, inner),
        .type_param => unreachable,          // <-- F4 substituted it; G5
        .unresolved => unreachable,          // <-- F2 T4
    };
}
```

The two `unreachable`s are the whole point. Today they are `return false` — the hardcodes at
`arc.zig:13-15` and `:19-20`. **After F2 and F4 they are not answerable-wrongly; they are
unrepresentable.**

### 3.3 Collections: elements become visible

Two candidate mechanisms.

**(a) Reified destructors (needs F4).** `__destruct_List<string>` knows its element type, so it loops the
buffer releasing each element. This is exactly what `arc.zig:34-40` calls "reified-generic destructors".
- Requires the container to expose its element storage to the generated destructor.
- Fits the existing machinery: `getOrCreateDestructor` already recurses into field types (`arc.zig:139`)
  and already memoises per name (`:91`). F4 changes its key from base name to instantiation.

**(b) Element-destructor field (a value witness).** The container carries
`elem_destroy: fn(word) -> void`, set at construction from the known `T`.
- Works **without** F4 — the compiler knows `T` at `List<string>()`.
- Swift does effectively this (value witness tables), so it is not a hack *if adopted deliberately*.
- But it is per-container opt-in: it does not fix a user's own `struct Box<T> { v: T }`.

**Recommendation: (a), with (b) available as an interim.**

(a) is general — it fixes user generics too — and it deletes a special case rather than adding one. (b)
is a legitimate stopgap **only** if working collections are needed before F4 lands, and then it must be
written into the spec as a deliberate interim step with a removal plan. It must not be slipped in as a
patch; that is the pattern this whole program exists to end.

**The raw buffer is the deeper issue.** Even with (a), `List` stores elements via `bytes.write_ptr` into
an untyped buffer. The destructor can only traverse it because *it* was generated knowing the layout. A
stronger end-state is a compiler-known element array (F4b, unboxed) where the buffer is typed. Out of
scope here; recorded so it is not assumed.

### 3.3a Who allocates a collection's buffer — *not* codegen

**Question raised 2026-07-15:** every collection hand-writes `bytes.alloc_persistent` in `init` (10 sites
— `list.ky:6,17,26,70`, `map.ky:11`, `string_builder.ky:13,37,50`). Should codegen inject it, the
way it injects the refcount header?

**No — and the distinction is the point.**

- The **refcount header is a language invariant**: every heap object has one, the compiler defines its
  layout, no library may opt out. It is not a decision, so the compiler makes it.
- A collection's **buffer allocation is library policy**: initial capacity 4, growth 2×, when to
  realloc, whether to over-allocate. Inject it and `List`'s growth policy lives in the *compiler*, and
  every new collection — including a user's own — needs a compiler change. Rust's `Vec` and Swift's
  `Array` both allocate in library code for exactly this reason.

Injecting would add a **new special case to codegen**, the opposite direction from F1–F5, all of which
exist to remove them.

**But the complaint is correct.** The defect is not *who calls alloc* — it is that the primitive is
**untyped and unowned**:

- `bytes.alloc_persistent(n)` returns a raw address as an `i32` (F3 §2.4 — the lie)
- ARC cannot see through it (§2.1)
- `alloc_persistent` unconditionally bypasses the arena (§2.6)

**The fix is a typed, owned buffer**, not injection:

```kyte
struct List<T> {
    data: Storage<T>,      // compiler-known: owns cap slots of T; ARC-visible
    len:  int,
    cap:  int,
}
```

> **Naming — decided 2026-07-15, do not re-litigate.** `Storage<T>`. Rejected, with reasons, because
> naming is permanent and load-bearing:
>
> | Rejected | Why |
> |---|---|
> | `Heap<T>` | `Heap<T>` means **priority queue** in Rust (`BinaryHeap`), Java, C++, Python (`heapq`), Go. Collections are graded "~half the API missing" — that name will be wanted. Also collides with "the heap" as a region, which `specs.md` uses 10× ("heap object layout", "heap box"). |
> | `Arc<T>` | Rust's `Arc<T>` is a **shared pointer to one value**, not storage for N — it reads exactly backwards. Collides with Kyte's own ARC *model* (§8, `arc.zig`, this document): *"`Arc<T>` is ARC'd — and so is `string`, which is not an `Arc<T>`"* is unwritable. And it forecloses `Arc<T>` for a real shared-ownership pointer later (§6 Q4's cross-task sharing). |
> | `Buffer<T>` | Node's `Buffer` is a **byte array**; Kyte targets web developers, so it invites the raw-bytes reading this design exists to remove. |
> | `Memory<T>` | .NET's `Memory<T>`/`Span<T>` are **non-owning views** — actively misleading, worse than a neutral name. |
>
> **The principle:** in Kyte, *heap-allocated* and *reference-counted* are true of **every** `string`,
> `List`, `Map` and struct (§3.2). A name built on either property distinguishes nothing. The name must
> say what the thing **is** — it owns N contiguous slots of `T`. Precedent: Swift's `ManagedBuffer` /
> `_ContiguousArrayStorage`.

`Storage<T>` is one primitive the compiler *does* understand. Then ARC releases `data` because it is a
**typed field** — the mechanism that already works (§2.3) — and the destructor knows to release `cap`
elements of `T` because F4 made `T` concrete. Nothing is special-cased per collection, and **a user
writing their own container gets ARC for free**, which injection would never give them.

This is F3 (typed) + F4 (`T` is real) + F5 (owned) doing the work the compiler would otherwise hardcode.
It also subsumes §3.3's "the raw buffer is the deeper issue": with `Storage<T>`, there is no raw buffer.

**Consequence for §3.3:** with `Storage<T>`, mechanism (a) — reified destructors — is the *only* one
needed. The element-destructor field (b) exists solely to bridge the gap before F4, and `Storage<T>` is
its retirement.

### 3.3b The stdlib has two allocation models, and one has no second implementation

Measured 2026-07-15:

| Model | Users | Implementations |
|---|---|---|
| explicit `Allocator` struct (`mem/allocator.ky`) | `File`, `Dir`, `TcpListener`, `Channel` (4 types, 11 call sites) | **1** — `globalAllocator()` |
| raw `bytes.alloc_persistent` | `List`, `Map`, `StringBuilder` | — |

`new_with_allocator<T>` is called 3 times, **always with `globalAllocator()`**. `ArenaAllocator` exists
with an adapter (`arena_allocator.ky:40`) and **nothing uses it**. So the `Allocator` abstraction has
no second case — it is ceremony — while the collections bypass it entirely. That is the §11 *"different
different things"* divergence, in the memory model.

**Open decision (§6 Q6), and it must be made before `Storage<T>` is built:**
- **(a) Delete `Allocator`; `Storage<T>` everywhere.** Consistent with ARC + the global arena; the
  language already allocates implicitly. *Recommended* — the abstraction is not earning its keep.
- **(b) Commit to explicit allocators everywhere** (`List`/`Map` take one). That is Zig's model, and it
  contradicts ARC's implicitness. Choosing it means committing *all* collections, not four types.

**Live bug found while measuring — `globalAllocator()` allocates per call.** It returns a *struct
literal*, so every call heap-allocates a fresh `Allocator` (verified: two calls compare unequal). At 11
sites, including hot paths — `file.ky:111` is `allocator.globalAllocator().alloc(size + 1)`, i.e. **an
allocation in order to allocate**, plus a retain/release since `Allocator` is a struct. `dir.ky:48,117`
likewise. It must be a singleton regardless of which model wins. Filed in specs §10.

### 3.4 Closure envs

The compiler knows each lambda's captures (`lambda_captures`, `llvm_codegen.zig:92`) and, after F2, their
types. So:
- The box `{fn_ptr, env}` becomes a ref-counted heap object (`alloc`, not `alloc_persistent`).
- Generate `__destruct_lambda_N` releasing each **owned** capture, then the env.
- Capture into env = retain (O4). Box released at scope exit like any owned local.
- `.func` becomes owned in `isOwned` (§3.2) — deleting the `indexOf(name, "=>")` hardcode.

Note the interaction with **F1**: `arc.zig:164-168` currently skips releasing captured variables
("to let them survive async execution") because A1's dormant `captured_globals` path promoted locals to
globals. Roadmap A1 says to delete that skip once envs own their values. F5 does that.

**Escape analysis is not required.** A returned closure keeps its box alive by refcount — that is what
ARC is for. Cycles are the exception (§6 Q1).

#### 3.4a ⚠️ A fn value has TWO representations, and one is read-only

**This is a hazard in §3.2 as written, found 2026-07-15. Read before implementing `.func => true`.**

After the #18 fix, a fn value is uniformly a box `{fn_ptr, env}` — but it comes from two places:

| Kind | Built by | Storage | Owned? |
|---|---|---|---|
| **heap closure box** | `expressions.zig` `.closure` | `alloc_persistent` | **yes** — §3.4 makes it ARC'd |
| **static bare-fn box** | `expressions.zig:buildBareFnBox` | module-level global, **`LLVMSetGlobalConstant(box_g, 1)`** (`:97`) → `__DATA_CONST` | **must not be** |

`__DATA_CONST` is **mapped read-only at runtime**. So `isOwned(.func) == true` (§3.2) makes ARC retain a
static bare-fn box → `kyte_retain` writes the refcount at `[box-8]` → **BUS**.

**Not speculative — this exact crash was traced today.** `___fnbox_payload` at `0x10011cb00`, inside
`__DATA_CONST,__const`, faulting in `kyte_retain` (`alloc.cpp:123`) on a *write* after the refcount
*read* succeeded — the signature of a read-only page. `nm -n` named the symbol outright.

And there is a live instance waiting: `mem/allocator.ky` declares
`allocFn: (i32, i32) -> i32` and stores the **bare fn** `cAllocFn` in it. The emitted globals
`__fnbox_..._cAllocFn` / `__fnbox_..._cFreeFn` are read-only constants today. This is safe **only**
because `isRefCountedType` currently returns `false` for any name containing `->` (§2.5) — the very
hardcode F5 deletes. **F5 as drafted would reintroduce the bug F3-era work just fixed.**

**The fix has a precedent in-tree — string literals** (`llvm_codegen.zig:351-357`):
```zig
core.LLVMSetGlobalConstant(global_var, 0);                    // WRITABLE, deliberately
const ref_const = core.LLVMConstInt(self.i32_type, 100000000, 0);  // sentinel refcount
```
A string literal is a static object that ARC retains and releases *harmlessly*, because it is writable
and its refcount starts at a sentinel it can never decrement to zero.

**So a static fn box must be built the same way:**
1. `SetGlobalConstant(box_g, **0**)` — writable (change `expressions.zig:97`)
2. give it the standard 8-byte header, so `[ptr-8]` is a real refcount and `[ptr-4]` a length
3. initialise the refcount to the **`100000000` sentinel**, exactly as string literals do

Then retain/release on a fn value are correct and uniform for **both** representations, with no branch
and no second rule — which is the same principle the #18 fix used to kill the two calling conventions.

**Do not instead special-case "is this box static?" at each retain site.** That is two conventions
again, and it is how #18 happened.

*(Trait vtables are also `SetGlobalConstant(1)` (`llvm_codegen.zig:875`) and stay read-only — correct: a
vtable is a dispatch table, never a fn **value**, and is never retained.)*

### 3.4b Temporaries have no owner — and why the fix is blocked on F4 4b

**Measured 2026-07-15/16.** The last of the `List<string>` leak is not about generics at all:

```kyte
ignore(string.concat("a", "b"))   // `ignore(s: string)` — NOT generic
```
leaks **exactly one object per call** (108 live at N=100; floor is 8). Bind it first —
`let x = concat(..); ignore(x)` — and it is clean. **An owned temporary passed as an argument has
no owner, so nothing releases it.** That is the remaining 2/iter for `List<string>`
(`push(concat(..))`) and the ARC audit's floor (the harness's own `console.log("Results: " + ..)`).

**The fix is one rule** — a temporary dies at the end of the full statement (the C++ rule; drained at
statement boundaries, not per-call, because `f(g(), h())` must keep g's result alive until f runs).
Implemented and **measured working**: `List<string>` 208 → **8, flat across N=100/400/1600**.

**And it is UNSOUND today**, which is the point:

```
release temporaries  needs ->  every call returns OWNED
Map.get              returns ->  a BORROW (`return bytes.read_ptr(self.valsPtr, ..)`, map.ky:125)
                                  the ONLY Level-0 borrow left (see F4's audit)
fixing Map.get       needs ->  Map on Storage<T>  (Storage.get retains)
Storage<K> inside Map<K,V> needs ->  K concrete in the method body  =  F4 stage 4b
```

Releasing a borrow returned by `Map.get` frees the map's own value: `13_serde` crashes ("Test process
terminated abnormally"), consistently. So the rule is correct, ready, and **gated on 4b** — not on
another idea.

> ### ✅ RESOLVED 2026-07-16 — `Map` is on `Storage<K>`/`Storage<V>`, and mono is MANDATORY
>
> 4b landed, `Map` migrated, the exclusion is deleted, and **the `KYTE_F4_MONO` flag is gone**. Corpus
> 28/28 **stable across 6 runs**; 107/107 unit tests. Measured, `Map_string_i32_set`:
> **`retain=0, write_ptr=14` → `retain=3, release=2, write_ptr=4`** (the 4 remaining are tombstone byte
> writes, which correctly stay raw). The container now owns its keys.
>
> **Why the flag had to go, rather than default to on.** An ERASED `Storage<K>` has inert ARC
> (`isRefCountedType("K")` is false), so nothing retains the key — while the call-site retain still
> fires. The two do not compose: mono OFF with the migrated Map is an intermittent use-after-free,
> **4 of 6 corpus runs** failing on 12_traits_dispatch. That is exactly why the first attempt at this
> migration (`5c6c0cc`) was reverted four minutes after landing. A switch whose "off" position selects
> memory corruption is a trap, not a fallback.
>
> **Two claims in this section were WRONG and are corrected:**
>
> 1. ~~**Temporary-release has no customer.**~~ **RETRACTED — §3.4b was right; I measured nothing.**
>    See the box below. `ignore(string.concat("a","b"))` leaks **exactly 1 per call**, reproduced:
>    **108 live at N=100, 408 at N=400**, against a floor of 8. Linear. The rule has a real customer and
>    is the cause of the 1898-object leak on `14_collections_map`.
>
>    > ### ⚠️ `kyte test` DOES NOT RUN `main()` — and it cost me three false conclusions
>    >
>    > Every repro written as `fn main() { ... }` and run under `kyte test` **never executed**. The
>    > harness runs `@test` functions only. `main` is silently skipped: no error, no warning, exit 0, and
>    > a **passing audit at the floor of 8** — which reads exactly like "clean".
>    >
>    > Three claims were built on programs that never ran:
>    > - "temporary-release has no customer" (**false** — 1 leak/call, linear)
>    > - "`List<string>` is flat at 8, therefore clean" (**unmeasured**)
>    > - "there is no floor of 8; a clean program audits at 0" (**false** — that program failed to
>    >   COMPILE, `MethodOrFunctionNotFound`, exit 1, and I read the absent audit line as "0 live")
>    >
>    > **The floor is real and it is 8** — an empty `@test` file audits at 8 objects / 146 bytes.
>    >
>    > **The rule: an ARC repro must be an `@test` function, and you must confirm it ran.** A number from
>    > code that did not execute is not a weaker measurement, it is not a measurement — and it looks
>    > identical to a good result. This is the stale-binary trap (§3.5, and `kyte-arc-storage-model`
>    > trap #1) wearing a third costume: *check that the thing you are measuring actually happened.*
> 2. **Migrating `Map` did not kill the Level-0 borrow**, because `Storage.get` never retained (see §3.3's
>    correction — `a53827f` landed in dead code). `get` now retains for real, which costs **+2 objects on
>    13_serde and nothing else** across the corpus.
>
> **`14_collections_map` still leaks 1898 objects.** This migration does not touch it — it is a separate,
> pre-existing defect, and `5c6c0cc` already flagged it ("Map still leaks 1,588 — a separate defect"). It
> is the largest single leak in the corpus and the obvious next target.
>
> **✅ `retainIfGenericStore` IS DELETED.** I expected it to survive for generic FUNCTIONS (`fn f<T>`,
> which 4b does not monomorphize) — wrong. Instrumented across the whole corpus: **ZERO firings**. Deleted
> (50 lines), and the **IR is byte-identical on all 17 cases**, which is what "dead" means. The
> `mono_symbols` set that existed only to gate it went with it.
>
> This is the workaround the erasure forced, and it outlived its cause by exactly one migration. F4 §5
> said "do NOT delete it until method bodies are monomorphized" — they are, so it is gone, and the proof
> is mechanical rather than argued.

### 3.4c ✅ The temporary rule — LANDED 2026-07-16

A temporary dies at the end of the full statement. **Corpus 28/28 stable across 6 runs; 13_serde 8/8;
zero double releases corpus-wide; 107/107 unit tests.**

| | before | after |
|---|---|---|
| **corpus total live** | **2513** | **1377** (−45%) |
| `14_collections_map` | 1898 | **942** (−50%) |
| empty `@test` — the "floor" | 8 | **2** |
| `00_smoke` / `03_strings` / `07_generics` / … | 8 / 14 / 8 | **2 / 2 / 2** |
| `16_block_scope` | 16 | 6 |

**The "floor of 8" was itself a leak** — the harness's own `console.log("Results: " + ..)` temporaries.
The thing doing the measuring was leaking; there is no fixed floor.

**The mechanism.** `compileExpression` wraps the real compile and registers the `+1` from a producing
kind; `compileStatement` MARKS the pending list and drains at the statement's end; every point that
takes ownership CONSUMES the value first. Mark-and-drain, never clear — statements nest, and clearing
would free an enclosing statement's temporaries early.

**Temporaries are SPILLED to a zeroed stack slot.** A temporary born in a branch (`a ?? f()`) is
released in the merge block, which the producer does not dominate — not a subtle bug, it fails LLVM
verification outright (`Instruction does not dominate all uses`). The slot is zeroed in the entry block
and re-zeroed after each release, or the next loop iteration releases a freed pointer.

**Every ownership-taking point must consume, and each miss was a different disaster:**

1. **`.assign` is not a producer.** `x = e` hands back what it *stored*; registering it released the
   variable's own value — killed all 17 cases at once.
2. **`.expr_stmt` already releases a statement-level `.call`** (statements.zig). The drain released it a
   second time. That hand-written release IS this rule for one case; the drain generalises it, so the
   value is consumed there.
3. **`??` yields a PHI, not its operand.** `let i0 = o.items.get(0) ?? Item()` binds i0 to the phi, so
   `let`'s consume missed `get`'s temporary — which the drain then released while i0 released the same
   object at scope exit. **Ownership flows through the phi**: `.nullish_coalesce` consumes both operands
   and is registered in their place. This was the whole of the 5/8 flake on 13_serde.

**A double release is invisible until it isn't.** `kyte_release` on a freed object returns early on the
-999 sentinel and looks harmless — until malloc REUSES the block, and then it decrements a *different*
object's refcount. The crash lands somewhere unrelated, and its location depends on the allocator, not
the bug. That is why this presented as an intermittent failure in a test that does not contain the bug.
`KYTE_ARC_DUMP=1` now reports it at the release (§3.5.1).

**Two leaks fixed alongside, both found by looking at the survivors rather than reasoning:**

- **Every template literal leaked its StringBuilder.** `compileAppendToStringBuilder` retained the
  builder on EVERY part, with a comment claiming "the callee consumes/releases its receiver parameter"
  — it does not: a PARAMETER is never registered as an owned local, so nothing in `StringBuilder_append`
  releases `self`. O4 already had the rule ("pass as argument | BORROW"). The survivors named it exactly:
  `{buf=0, len=4}` x100 for 200 `` `k${i}` `` evaluations — buf zeroed by `delete()`, len still holding
  the key's length. That is a StringBuilder and nothing else.
- `StringBuilder.delete()` frees the buffer, not the object, so the object is now released too.

**The interpolation intermediates are fixed too** (same day). `` `k${i}` `` called `__i32_to_string`,
appended the result, and never released it — `append` COPIES bytes into its own buffer and never stores
the pointer, so the converted string is dead the moment it returns. The temporary rule could not see
these: they are built with `LLVMBuildCall2` directly, not through `compileExpression`. Same for
`__bool_to_string`.

**Corpus total live: 2513 → 753 (−70%).** `14_collections_map` 1898 → **320**; `16_block_scope` 16 → 4;
the floor 8 → 2.

### 3.4d The last ARC leak: `Map.resize` over-retains its keys

**`14_collections_map` 320 and `13_serde` 361 remain.** For the map the survivors are exactly the KEYS,
and the cause is isolated:

| | |
|---|---|
| `Map<string,int>(512)`, 200 template keys — **no resize** | **CLEAN (floor)** |
| `Map<string,int>(4)`, 200 template keys — **many resizes** | **194 leak** |
| 200 lookups of ONE key (probing only) | **CLEAN** |
| one key via `concat`, no template | **CLEAN** |

So it is `resize`, not `set`, not probing, not the template. **The refcounts name the shape** (add
`KYTE_ARC_DUMP=1`):

```
x1  size=4  rc=2   "k188"
x1  size=4  rc=1   "k189"
x1  size=2  rc=17  "k0"     <- the FIRST key: survives the most resizes
```

`rc` climbs with the number of resizes a key lives through, and `k189` survives at **rc=1** — nobody
released it at all, so the final `Storage`'s destructor never released its slots.

#### ✅ FIXED (2026-07-16): `14_collections_map` 1898 → **6**. Two bugs, cancelling, fixed together.

**Both landed at once, because either alone is worse than neither:** closures are monomorphized, and
sema types `Storage<T>.get`. Corpus 28/28 **stable ×6**; `14_collections_map` and `13_serde` **8/8**;
**zero** double releases; 107/107 unit tests. Corpus total **2513 → 439**.

The diagnosis below is kept because it is the reason the order mattered.

**`methodReturn` (infer.zig) reads `if (t != .struct_) return null`, and `Storage<T>` is `.storage`, not
`.struct_`.** So every `s.get(i)` / `s.set(i,v)` is UNRESOLVED. §3.8 has specified `get`/`set` since it
was written; sema simply never answered. Sema types the *constructor* (`infer.zig:633`) and nothing else.

**Why that leaks:** an untyped `let` is never recorded in `local_types`, so it is never an OWNED local,
so ARC never releases it. `let key = oldKeys.get(i)` in `Map.resize` retains (+1 — `Storage.get`
transfers) and nothing gives it back. Proven by printing `local_types` for `Map_string_i32_resize`:
`key`, `val` and `cur` are ABSENT while `tomb`, `hash`, `nt`, `idx` — same and deeper nesting — are
present. The three missing ones are exactly the `<storage>.get(...)` initialisers.

**The one-line fix works and is NOT SHIPPED**, because it uncovers a second bug that the first was
paying for:

```zig
// infer.zig methodReturn, before the `.struct_` check:
if (t == .storage) {
    if (std.mem.eql(u8, fa.field, "get")) return t.storage;      // the slot's T
    if (std.mem.eql(u8, fa.field, "set")) return try self.store.voidT();
    return null;
}
```
With it: `key: string`, and **`14_collections_map` 320 → 5**, every map repro at the floor, corpus total
753 → 438. **But `14_collections_map` then FLAKES 2 of 6** with a double release of the map's keys.

**The second bug — CLOSURES INSIDE GENERIC BODIES ARE NOT MONOMORPHIZED.** A lambda is collected once
per SOURCE SPAN (`getClosureUniqueId(cl.span)`, llvm_codegen.zig ~1740), so the closure in
`Map.keys()` — `self.forEach((k, v) => result.push(k))` — is SHARED by every instantiation and stays
erased. Measured: all four `__lambda_N` call `@List_push` (retain=**0**), never `@List_string_push`
(retain=**1**). So `result.push(k)` never retains the key, the List's element has no owner, the List's
destructor frees it, and the Map's destructor then releases it again.

**That has always been true.** The untyped-`key` leak was silently paying for the missing retain — two
bugs cancelling, which is why the corpus was stable with BOTH and flakes with ONE.

**So the order was: monomorphize closures first, then land the sema fix.** Both are in.

**What monomorphizing closures actually took — the N copies were already there.** The collection loop
walks `compiler.functions.items`, which already holds `Map_keys` AND `Map_string_i32_keys`, so it
already called `collectClosuresFromBlock` once per instantiation and already minted a fresh
`__lambda_N` each time. Two things threw that away:

1. `closure_lambdas` was keyed by SPAN alone, so `put` **overwrote** — N lambdas emitted, one
   remembered, every instantiation resolving to whichever was collected last. Now keyed by
   `(span, instantiation)`.
2. The lambda's `FunctionInfo.instantiation` was `null`, so its body compiled ERASED. It now inherits
   `current_collecting_instantiation`.

Measured, the closure in `Map.keys()` / `Map.values()`:

```
before: __lambda_0..3  ALL -> @List_push        (retain=0)   <- nothing retained the key
after : __lambda_1     -> @List_string_push     (retain=1)
        __lambda_3     -> @List_i32_push
        __lambda_0/2   -> @List_push            (the erased bodies' own copies)
```

A `.closure` with no instantiation-specific lambda falls back to the erased key, so an ordinary
function's closure is unaffected.

### 3.4e Two more holes in "scope exit | release every owned local" — the exits that JUMP

**`break` and `continue` released NOTHING.** A `.block` releases its owned locals only
`if (terminator == null)`, and `break`/`continue` ARE terminators. `return` was already handled
(`.return_stmt` → `releaseLocalVariables`); these two were simply missed, and the omission is silent —
it leaks rather than crashes.

The customer is the JSON parser, written as `while (true) { ... break; }`:

| | before | after |
|---|---|---|
| `json.parse("{\"a\":1}")` | 11 | **2** (the floor) |
| `json.parse("{\"a\":1,\"b\":2}")` | 11 | **2** |
| `json.parse("[1,2,3]")` | 10 | **2** |
| `json.parse("7")` / `"{}"` / `"[]"` | 2 | 2 |

**The tell was that one field and two fields leaked IDENTICALLY** — only the LAST iteration breaks — and
that `{}` (which `return`s before the loop) was clean. Fixed by releasing every scope out to the loop
body's own, before the branch. It does not pop them: the `.block` handler still does, and still skips
its own release, so nothing is released twice.

**And the temporary rule skipped a return's INNER temporaries.** `drainTemporaries` bails once the block
has a terminator (nothing can follow `ret`), so a `return` dropped its whole pending list — including
temporaries that were NOT the returned value. `return JsonSource(json.parse(body))` leaked the entire
parsed tree (25 objects) because `json.parse(body)`'s `+1` was never given back, while `json.parse`
called on its own was clean. Now the returned value is CONSUMED (it transfers to the caller) and the
rest are drained before the `ret` is built. `source.fromJson(..)`: **27 → 2**.

### 3.4f ✅ Traits: the fat pointer had no owner, and the call retained its receiver

**Corpus 439 → 226.** `13_serde` 361 → **157**; `12_traits_dispatch` 13 → **4**;
`Tiny__bind(source.fromJson(raw))` **20 → 2** (the floor).

Two bugs, and the second was almost all of it:

1. **The trait object had no owner.** `constructTraitObject` allocates a `{struct_ptr, vtable}` fat
   pointer with `compileAlloc` — a `+1` that nothing names — so every coercion leaked 16 bytes. It is
   built outside `compileExpression`, so the temporary rule could not see it; `registerTemporary` is now
   the door for exactly this. `let x: Speaker = Dog()` CONSUMES it (the binding is its owner), which the
   `let` path must do AFTER coercing, since the coercion makes a *new* temporary. Worth **1 object**.
2. **A trait method call RETAINED its receiver and never released it** — worth **17 of the 18**. O4 says
   "pass as argument | BORROW; the callee does not retain unless it stores", and a trait method does not
   store its `self`.

**The measurement that isolated it:** `Tiny__bind` on a struct whose only field is a `long` — nothing
ref-counted anywhere — still leaked the WHOLE parsed JSON tree. The `JsonSource` was released correctly
(`__destruct_JsonSource` is right there in the IR) and *still* survived at **rc=1**, because
`src.getInt("id")` had already retained it. One `+1` on the receiver pinned everything the receiver
owned.

**This is the third "safety retain" that was a leak** — `compileAppendToStringBuilder` retained the
StringBuilder per part (§3.4c), the array-conversion codegen retains `arr_val` per call, and this. The
comment on the first one claimed "the callee consumes/releases its receiver parameter"; it does not, and
neither does any other callee. **A retain on a borrow is not caution, it is a leak.**

### 3.4g `13_serde` 157 — and two hypotheses that were WRONG

Corpus is **226** (from 2513). `13_serde` 157 and `06_closures_advanced` 22 are the only cases above 9.
Per-test, after the trait fix: `list_of_structs` 78, `list_of_primitives` 50, `scalar_and_nested` 29,
`tojson_roundtrip` **6**.

**Both recorded suspects were wrong. Do not re-derive them:**

1. ~~"`convertValueToType` builds Lists via `getFunc("List_push")` — the ERASED symbol — so it does not
   retain."~~ True about the code, irrelevant to serde: **that path is never reached by 13_serde**
   (instrumented: **0 hits**). `convertValueToType` serves `db.query<T>()`, not the generated binder.
   The binder is ordinary Kyte source, so its `push` already monomorphizes. Making the four `getFunc`
   lookups instantiation-aware changed 13_serde by **exactly zero** and was reverted — a correct change
   to a path with no test and no customer is speculation. **It remains a latent bug for `db.query<T>()`**,
   and the fix is one line each: prefer `methodSymbol("List<elem>", "push")` with the erased name as
   fallback (destination is `List<elem>`, source `arr_val` is `List<JsonValue>`).
2. ~~"The 5 argument-borrow retains in `convertValueToType` leak."~~ Real O4 violations, but removing
   them also changed 13_serde by **exactly zero**. Same verdict, same reason.

**What the survivors actually say** (`KYTE_ARC_DUMP=1` on `{"tags":["a","b"]}`): the JSON tree's LEAF
`JsonValue`s survive at **rc=1** — nobody released them — while `"a"`/`"b"` sit at **rc=2** (one ref from
the leaf's `sval`, one from the bound `List<string>`, which is correct). The array `JsonValue` (kind=4)
is NOT among them, so it was freed — its `arr` list's elements were not. So the next question is narrow:
**why does freeing the array `JsonValue` not release its `arr` elements?** Note `json.array(val)` does
`let v = JsonValue(4); v.arr = val;` — the init already allocated an empty `List`, and the field assign
replaces it, so the ownership of the parser's list is the thing to audit.

### 3.4h `return getter() ?? default` retained an already-owned value

`13_serde` **157 → 129**, `List<string>` binding **18 → 2** (floor); corpus 226 → 198.

`return x ?? default` had a special-case retain, to balance the `releaseLocalVariables` that frees the
returned value when it is a local (kyte-nested-arc-corruption). **It was written when `Map.get`/`List.get`
returned BORROWS.** They now return OWNED (Storage.get transfers), and `??` consumes its operands, so for
`return arr.get(i) ?? JsonValue(0)` the return already owns the value — the retain is an unbalanced `+1`
nothing releases.

Measured on `json.at` (`return val.arr.get(index) ?? JsonValue(0)`): every array/object element read
through it came back at rc+1, so freeing the tree left each leaf at rc=1. Gated the retain to an `.ident`
LHS — the only case where the returned value IS a releasable local — and the element leak is gone.

### 3.4i ✅ Trait objects now OWN their wrapped struct — `13_serde` 129 → 3

**Corpus 198 → 71.** `13_serde` **129 → 3**, `12_traits_dispatch` 4 → 3, all nested/list-of-struct
repros at the floor. Stable ×6, `13_serde`/`12_traits_dispatch` 8/8, zero double releases.

A trait object is a `{struct_ptr, vtable}` fat pointer, and it now co-owns the struct it wraps. FOUR
interacting parts, and parts 1–3 alone were **exactly zero-effect** (the retain and release cancelled
around a ref that part 4's ordering bug had orphaned — a "more correct" change that measured nothing,
caught only by reverting zero-effect memory codegen):

1. **`constructTraitObject` retains `struct_ptr`** — the trait object co-owns.
2. **vtable slot 0 = the struct's destructor**, methods shift to `1..N`; the one dispatch site uses
   `(m_idx + 1)`.
3. **`getOrCreateDestructor(trait)` returns a generic `__destruct_trait`** that loads `struct_ptr` and
   `vtable[0]` and releases the struct — one function for every trait, since the concrete destructor is
   only known at runtime, from the vtable.
4. **The RETURN path coerces to a trait BEFORE consume/drain.** It used to compile the value,
   `consumeTemporary` it, drain, THEN wrap — so `return JsonSource(json.get(..))` left the inner struct
   at rc 2 with only the fat pointer as owner (`__destruct_trait` releasing once → rc 1, leak). Coercing
   first makes the fat pointer the return value; the inner struct temp is drained (its construction ref
   released) and the fat pointer holds the sole retain, which its destructor gives back.

Isolated the way it was found: `parse nested JSON` clean, `bind a flat struct from nested JSON` clean,
`bind READING a nested field via getChild` leaked 17 → the `getChild`/`itemChild` return path.

The ARG path (`f(fromJson(x))`) was already correct — it does not consume, so both the source temp and
the fat pointer drain, and the co-ownership retain balances. `let x: Speaker = Dog()` rides the same
`constructTraitObject` retain + `__destruct_trait` on the owned-local release.

### 3.4j Closures leak their box + env — and why it is a REPRESENTATION decision, not a bug fix

`06_closures_advanced` 22 is the last corpus case above 9, and it is the §10 #15 leak: **a closure's
`{fn_ptr, env}` box and its env are never freed.** Linear and unbounded — `make_adder(i)` in a loop:
N=10 → 22 live, N=40 → 82, N=160 → 322, i.e. **2 per closure** (the 16-byte box + the env).

**Root cause:** `isRefCountedType` returns FALSE for any type containing `=>`/`->`, so a closure-typed
`let` local is never registered as owned and never released. The box and env are
`kyte_bytes_alloc_persistent`'d and dropped.

**Why the one-line "flip isRefCountedType for function types" is UNSAFE — proven, not assumed.** Function
values are NOT uniform:

- `let f = (x) => x + n` → a **heap box** `{fn_ptr @0, env_ptr @8}` (16 B) + a heap env.
- `let g = dbl` (a bare function) → a **raw code pointer**, `store i64 ptrtoint(@dbl)`, no allocation,
  and already clean at the floor.

Releasing a raw code pointer makes `kyte_release` read `[@dbl - 8]` as a refcount and corrupt the code
segment — and raw function pointers are everywhere: `string.hash` as a value, vtable method slots,
callbacks. So the release must reach heap closures WITHOUT touching function pointers.

**The fix is a representation decision, one of:**
1. **Uniform boxing** — box every function value (even `dbl`) so all function-typed values are heap
   closures; then `isRefCountedType` can safely say true. Touches every function-value site (vtables,
   `hashFn` fields, method refs) — the biggest change, but the cleanest invariant.
2. **A closure tag / distinguishable header** — mark heap closures so `kyte_release` (or a dedicated
   `kyte_release_closure`) can no-op on a raw pointer. Localised, but adds a runtime check.
3. **Init-expression tracking** — treat a `let`/return whose value is a `.closure` literal as an owned
   heap closure; leave `.call`-returned function values alone. Contained, but misses closures that
   escape through a returning call (`let add5 = make_adder(5)`), so incomplete.

**And every closure also needs a per-lambda DESTRUCTOR** that frees the env and releases the env's
refcounted captures (a captured `string` leaks its own object on top of the box+env). The capture types
are in `lambda_captures`. Escape is already handled by the owned-local + retain-on-return machinery once
closures are refcounted — `make_adder` returning its closure transfers ownership like any other owned
value.

### ✅ 3.4j LANDED — closures are refcounted; `06_closures_advanced` 22 → 2, corpus → 36

Uniform boxing, and the fn-typed container HAD to be monomorphized (erased was impossible — see below).
Five pieces:

1. **The global fnbox gets an ARC header.** `__fnbox_dbl` → `{i32 rc=100_000_000, i32 len, [2 x i64]}`
   (writable, sentinel refcount like a string literal), payload at `+8`. A bare function value is now
   safely releasable (a harmless decrement); fn-value equality (`self.hashFn == string.hash`) holds
   because the payload address is stable.
2. **`isRefCountedType` returns true for function types.** Both box kinds (heap closure, sentinel global)
   are safe to release, so a closure-typed `let` local finally gets released.
3. **A generic `__destruct_closure`** frees the env at `box[8]` (`kyte_bytes_free`, null-safe).
4. **`isFunctionType` — the load-bearing distinction.** A closure destructor must fire for a function
   type `(int) => int` but NOT for `List<(int) => int>` (a container OF functions). The test is the
   arrow's bracket DEPTH: depth 0 = function, depth 1 (inside `<>`) = container. Getting this wrong gave
   `List<(int)=>int>` the closure destructor, which read `list[8]` (the `len` field = 3) as an env and
   freed `0x3` — the crash that made the first attempt look unfixable. It was one predicate.
5. **Fn-typed containers are monomorphized** (injective `mangleTypeName` for `( ) - =`, `.closure` a
   producer). **"Keep them erased" is structurally impossible:** the container's destructor is generated
   on demand and DOES release its refcounted closure elements, but an erased `push` never RETAINED them,
   so `f0` and the list both release each closure at rc 1 — a double free. Monomorphizing makes push
   retain and the destructor release, balanced.

Result: every closure repro at the floor; the dose-response is FLAT (was 22/82/322 for N=10/40/160);
`06_closures_advanced` 22 → 2; corpus 71 → 36. Stable ×6, 12_traits/13_serde 8/8, zero double releases.

**✅ inc4 DONE — captured ref-counted values are retained AND released.** It was worse than a leak: the
env stored the capture WITHOUT retaining, so a closure over a heap `string` (`string.concat(..)`) DANGLED
once the creating scope released it — a use-after-free returning garbage. The corpus hid it by only ever
capturing string LITERALS (sentinel refcount, never freed); `make_greeter("bob")` binds its param to a
literal. Two halves:
- **Retain on capture** (the correctness fix): the env-build loop retains a ref-counted capture, so the
  env owns it. `current_local_types` gives the capture's type at the creation site.
- **Release on destroy** (the leak fix): the closure box gains a third slot `{fn, env, cleanup}` holding a
  per-lambda `__clocleanup_<lambda>` that releases the env's ref-counted capture slots; the generic
  `__destruct_closure` calls it (0 when nothing captured is ref-counted, the common case). Only heap
  closures reach `__destruct_closure` — a global fnbox has the 100M sentinel — so only heap boxes carry
  the third slot; callers still read only `fn@0`/`env@8`.

Measured: a closure capturing `string.concat(..)` in a loop is now FLAT (was +1/iter), correctness
restored, corpus at the floor. Pinned by `06_closures_advanced.test_capture_heap_string` — a heap capture
the corpus previously lacked.

<details><summary>Original attempt notes (superseded — kept for the reasoning trail)</summary>

**Uniform boxing ATTEMPTED and reverted (2026-07-16) — it works for non-container closures, but the
fn-typed CONTAINER path has deeper mono bugs.** Recording exactly how far it got, because the non-container
half is done-and-correct and the wall is specific:

WHAT WORKED (measured, then reverted with the rest):
- **inc1 — the global fnbox gets an ARC header.** `__fnbox_dbl` becomes `{i32 rc=100_000_000, i32 len,
  [2 x i64]}` (writable, sentinel refcount like a string literal), payload pointer at `+8`. So a bare
  function value is now safely releasable (a harmless decrement), and fn-value equality
  (`self.hashFn == string.hash`) still holds because the payload address is stable. Inert; corpus green.
- **inc2 — `isRefCountedType` returns true for `=>`/`->` types.** Both box kinds are now safe to release
  (heap closure, or sentinel global). Closure-typed `let` locals get released → the box is freed.
- **inc3 — a generic `__destruct_closure`** frees the env at `box[8]` (`kyte_bytes_free`, null-safe for a
  bare-fn box). ONE function for every closure — the env is a raw buffer at a fixed offset.
- **Result on non-container closures: the unbounded leak is GONE.** `cl_local` → floor; the dose-response
  went flat (N=10/160 → 2, was 22/322). `test_capture_string`, `test_returned_closures`,
  `test_multi_capture` all clean.

THE WALL — `List<(int) => int>` (closures in a container):
- Fn-typed instantiations were skipped by `mono` (the §3.4 mangling-collision guard). An injective
  `mangleTypeName` (distinct tokens `_lp _rp _da _eq` for `( ) - =`) let them monomorphize —
  `List__lpi32_rp__da_i32_push/get` emit — BUT `__destruct_Storage_<fntype>` was NOT generated (the
  Storage destructor for the fn element type is missing), and a `kyte_bytes_free` fired on `env == 0x3`
  (a garbage pointer): `__destruct_closure` ran on something that was not a closure box. So fn-typed
  monomorphization has its own bugs (missing Storage destructor; a value released as a closure). Adding
  `.closure` to `producesOwnedTemporary` (the right ownership model — a closure literal is a `+1`) did
  not resolve it and made the isolated case crash too, so the accounting is wrong somewhere deeper in the
  fn-typed Storage path.

NEXT PASS: land inc1–inc3 for non-container closures (they are correct), and treat the fn-typed container
as its OWN task — fix `mono` to emit `__destruct_Storage_<fntype>`, and find why a non-box value reaches
`__destruct_closure` (`env == 0x3`). Do NOT ship without `06_closures_advanced` (which has the fn-typed
`List`) stable across repeated runs. inc4 (release refcounted CAPTURES — a captured `string` still leaks
its own object) remains after that, and needs per-lambda capture types from `lambda_captures`.

</details>

### 3.5 Verification: the invariant must be checkable

Per README non-negotiable #2 — an invariant nobody can check is a comment, and §2.4 shows what comments
are worth.

1. **Debug refcount audit.** Under `KYTE_ARC_AUDIT`, the runtime tracks every live object and, at exit,
   reports non-zero refcounts by allocation site. **A leak becomes a test failure, not a 900MB RSS
   reading.**
2. **Dose-response cases in the corpus.** Encode §2.2: allocate N and 4N, assert peak RSS grows
   sub-linearly. This is the *only* method that distinguishes a leak from a high-water mark — `ps`
   sampling missed peaks by 3× and RSS plateaus produced a false "bounded" reading during the
   2026-07-15 investigation.
3. **All ARC cases run with `KYTE_DROP_ARENA`** (§2.6), or they prove nothing.

---

## 4. What this fixes

- **§10 #15** closure envs leak — measured 46 B/closure, linear (§2.2)
- **§10 #17** `List`/`Map` element leaks — measured, linear (§2.2)
- `isRefCountedType`'s two hardcodes — made unrepresentable, not patched
- The false contract at `list.ky:165` — the comment becomes true
- The `captured_globals` release-skip (`arc.zig:164-168`) and the dormant path — deleted (roadmap A1)
- **The absence of a written ownership model** — the actual root

**Does NOT fix:** reference cycles (§6 Q1); the arena's refcount exemption (§6 Q2); unboxed elements
(F4b); ARC *performance* (no retain/release elision — §6 Q3).

---

## 5. Staging

**Ordering note:** F5 lands *last* of the five. It is the only piece whose bug is a *runtime resource
leak* rather than a miscompilation — everything else is worse. Do not reorder it earlier because it is
the one the user can see.

| # | Stage | Content | Guard |
|---|---|---|---|
| 1 | **Make leaks measurable** | `KYTE_ARC_AUDIT` (§3.5.1) + dose-response harness. **Land before any fix** — otherwise "fixed" is an opinion. | new cases: today's leaks **fail** |
| 2 | **`isOwned(TypeId)`** | Replace `isRefCountedType([]const u8)`. Needs F2. `.type_param`/`.unresolved` → `unreachable`. | corpus green; audit unchanged |
| 2a | **Static fn boxes become writable + sentinel** | §3.4a. `expressions.zig:97` → `SetGlobalConstant(0)`, add the 8-byte header, refcount = `100000000`. **MUST land before stage 3** — otherwise `.func => true` BUSes on `Allocator.allocFn`. | new case: retain/release a **bare fn** stored in a struct field (would BUS without this) |
| 3 | **Closure env ARC** | §3.4. Needs F2 only — **not F4**. Delete the `=>` hardcode and the `captured_globals` skip. | audit: closure test leak-free; 16M-closure case bounded (**fails today**) |
| 4 | **O4 written down and enforced** | Audit every insertion point against the table. Expect to find *unbalanced* pairs, not just missing ones. | audit green on corpus |
| 5 | **Reified container destructors** | §3.3(a). Needs F4. Delete `retainIfGenericStore`. | audit: `List<string>` leak-free; 800k-round case bounded (**fails today**) |
| 6 | **Remove the interim** | If (b) was taken, remove it. | audit green |

Stage 1 first is the lesson from 2026-07-15: the first leak measurement that day was **wrong** — `ps`
sampling under-read peaks 3×, and a plateau nearly produced a false "catastrophic leak" verdict for
`List<int>`, which does not leak at all. **Without a harness, this work cannot be evaluated, only
believed.**

---

## 6. Open questions

1. **Cycles.** ARC cannot collect them. `weak`/`unowned` (Swift), or documented and ignored? A parent↔
   child graph leaks today and will still leak after F5. *Recommendation:* document in F5, design `weak`
   separately — but **say so in specs**, because "Kyte has ARC" implies a cycle story to anyone from
   Swift.
2. **The arena's refcount exemption (§2.6).** Keep (fast, hides bugs) or drop (honest, slower, exposes
   every latent imbalance)? *Recommendation:* keep for release, **drop for debug/test by default** so
   correctness is what CI measures. Note `alloc.cpp:6-13` says the exemption is load-bearing for
   `string.ky`'s `bytes.alloc(4+len)`/`ptr+4` trick — that trick must go (F3's `ptr`) before the arena
   can be dropped wholesale.
3. **Elision.** Naive ARC retains/releases on every store. Swift elides aggressively. Out of scope, but
   confirm the model permits it later (it does, if O4 is honoured).
4. **Thread safety.** `kyte_retain` uses `__atomic_fetch_add` relaxed (`alloc.cpp:123`). Is a
   ref-counted value shareable across `go` tasks? If yes, relaxed ordering on the *release* path needs
   review (`alloc.cpp:132` uses acq_rel — probably right, but it is unstated).
5. **`delete()` naming.** It is `deinit`. Keep the name and document it, or rename? It currently reads
   as manual API and misled a reader today. *Recommendation:* rename to `deinit` — a one-line spec change
   that prevents a recurring misunderstanding.
6. **Which allocation model** (§3.3b) — delete `Allocator` and use `Storage<T>` everywhere (recommended),
   or commit to explicit allocators in *all* collections? **Blocking `Storage<T>`.** Today's answer is
   "both, inconsistently, and one has a single implementation".
7. **Does `Storage<T>` replace `bytes.*` in the stdlib entirely** (§3.3a), or do raw `bytes` primitives
   remain for FFI/protocol code? *Recommendation:* `Storage<T>` for anything owned; `bytes`/`ptr` (F3)
   stay for genuinely untyped wire data — but then `bytes` must be **unowned by definition**, not
   ownership-ambiguous as today.

---

## 7. Done criteria

- [ ] A written ownership model exists (§3.1) and specs §8 links it
- [ ] `isOwned(TypeId)`; zero ownership decisions from a string; both hardcodes unrepresentable
- [ ] `KYTE_ARC_AUDIT` reports zero live objects at exit for the whole corpus, **with `KYTE_DROP_ARENA`**
- [ ] Dose-response cases: closures (16M) and `List<string>` (800k) **bounded** — both fail today
- [ ] `retainIfGenericStore` deleted
- [ ] `list.ky:165`'s comment is **true**, and the `arc.zig:34-40` "until reified-generic destructors
      exist" caveat is deleted
- [ ] `captured_globals` skip + dormant path deleted (closes roadmap A1)
- [ ] specs §10 #15 and #17 marked FIXED with the measurement that proves it
- [ ] Cycle behaviour documented in specs (even if unsolved)
