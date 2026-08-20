# Memory Management Refinements

Tracking doc for the memory-management work that came out of the web performance
investigation (2026-08-09/10). The web app under real concurrent load (postgres pool,
`oha -n 20000 -c 50`) sat at roughly 200 to 1,200 rps per core, nowhere near Go or Rust.
A leaf self-time profile on the same M1 machine put about 88 percent of per-request CPU
inside memory management: malloc and free around 34 to 40 percent, ARC retain and release
27 percent, memset 11 percent, arena alloc 9 percent. Actual I/O was about 2 percent.

The root cause is architectural, not a hot-loop micro-bug. Every Nova `struct` today is a
reference type: `struct_init` lowers to `nova_bytes_alloc` plus an atomic refcount header.
So ordinary value-shaped data (a `ProductView`, a `DbValue`, a request context) pays a heap
allocation and an atomic refcount on every construction and every drop. That single fact
produces both the 40 percent malloc and the 27 percent ARC in the profile.

This doc collects the refinements. The master table below is **status only**. The "what and
how" for each item lives in the design sections underneath, one section per row, same order.

## Master tracking table

Legend: ☐ not started · ◐ in progress · ✅ done · ⏸ parked · ✗ dropped

| ID | Refinement | Status | Notes |
|----|-----------|--------|-------|
| **Architectural (the root fix)** | | | |
| M-1 | Value-type `struct` (inline, copied, no heap, no ARC) | ✅ | DEFAULT ON (`NOVA_VALUE_STRUCTS_OFF` reverts). Stack alloca, no ARC, copy-on-assign, owned-fields incl. grow, inline in `List` (M-10). Escape channels (return-construction incl. closures, field/type-param, tuple/error-union/optional slot, @serializable, trait-impl, colliding scoped name, any-box heap-promote) keep unsafe shapes on the heap; corpus + ASAN green under the flip |
| M-2 | Reference-type `class` (heap, ARC, identity, shared) | ✅ | keyword + plumbing; 7 collections + `App`, `ServiceProvider`/`ServiceCollection`, `TcpListener`/`TcpStream`/`TcpClient`, `TlsStream`/`AsyncStream`/`ReactorStream`, `Pool`/`ResilientPool` marked `class` (identity/aliased-mutation types) |
| M-3 | ARC only on heap/reference fields | ✅ | inherent in M-1: `retainValueStructOwnedFields` + the drop loop gate on `isOwnedDeclaredType`, so a value struct's copy/drop touches ONLY reference fields; scalars get zero ARC |
| M-4 | Non-atomic refcount on the single-thread reactor | ✅ | corpus+ASAN green; flips to atomic before any 2nd thread |
| M-5 | ARC elision (expand the borrowed-field prototype) | ✅ | borrowed-field prototype ON by default + `elideRedundantPairsInFn`: a `nova_retain(v)` whose next use of `v` in the block is `nova_release(v)` (nothing references `v` between) is a net-zero pair and both are removed -- covers pass-through / borrowed-call-arg shapes the prototype missed. Provably balance-preserving (the +1 is unobservable when nothing reads `v` in the span); `NOVA_ARC_ELIDE_OFF` disables |
| M-6 | Per-coroutine region arena + escape analysis | ◐ | Per-coroutine GROWABLE arena delivered + ARC-clean (case 318): `io/arena.Arena` is a per-instance object (each handler holds its own in its coroutine frame -> concurrent requests never share a cursor, the crux that sank the reverted shared-thread-arena), grows by chaining blocks on overflow instead of failing (no fixed-32MB starvation), and reclaims a whole request's scratch with one O(1) `reset` that settles back to one block. Remaining: AUTOMATIC escape-analysis routing of request allocations into the active arena (needs a per-coroutine active-arena carried across awaits + codegen routing) -- explicit use works today |
| **Native resource lifetime** | | | |
| M-7 | Owned-handle type (`Fd`/`Socket`) + RAII destructor | ✅ | `os/handle.nova` `Fd` single-owner `class`: its `delete` destructor hook (the compiler already calls `<Type>_delete` at last release) closes the fd exactly once; idempotent `close()` for the error path; composition via owned-field release. No `move` keyword needed -- a `class` is never value-copied, so one owner, one close. Proven (case 316): a real socket fd is closed on destruction (second close = EBADF) and explicit close is idempotent. Adoption into connection/stream/bio fields is the follow-on |
| M-8 | Singleton lifetime via root ownership + borrow | ✅ | singletons are `class` (M-2) owned by the DI container → `App` → `main`; `app.run()` never returns, so the chain lives for the process. Handlers borrow by reference (single-reactor, no per-request retain on the shared object) |
| **Data-shape slimming** | | | |
| M-9 | `DbValue` slimming | ✅ | `arr` lazy + 16-byte `dec` field removed (reconstructed from text); corpus+ASAN green |
| **Collections and buffers** | | | |
| M-10 | Retire `Storage` bespoke ARC + fixed 8-byte slot | ◐ | `List<value-struct>` inline COMPLETE (default, ARC-clean, case 317): scalar + owned-field value structs inline at real slot width. NOW IN PROGRESS: FULL retirement of the `.storage` intrinsic, Swift-grounded (`__ContiguousArrayStorage` = a `class` + `UnsafeMutablePointer` + `MemoryLayout.stride`). Split the two roles Nova's `.storage` conflates -> (P1) typed-element intrinsics `mem/witness.{sizeOf,copyElem,dropElem}<T>` = value witnesses, lowered to the struct field-walk's copy/drop [DONE, builds]; (P2) pure-Nova `class RawBuffer<T>` on them [DONE]; (P3) `List` on `RawBuffer` [DONE, corpus 319/320 + ASAN green: needed mono-worklist-follows-backing, a value-optional element ABI fix, and a closure-capture-vs-method-name fix]; (P4) `Map`/`Set` on it, then DELETE `.storage` + `isOwnedStorageElem` + `buildStorageDestructor` (~52 touchpoints -> 3 intrinsics), buffer becomes uniquely-owned (no buffer refcount). See the "Full retirement" subsection below. (Map/Set inline-of-value-optional + a pre-existing `Map<K,struct-with-owned-field>` leak remain, logged in the backlog.) |
| **Shipped micro-optimizations** | | | |
| S-1 | `escapeHtml` scan-and-run (no alloc when clean) | ✅ | corpus+ASAN green |
| S-2 | `bytes.copy` (memcpy) in StringBuilder + string.slice | ✅ | corpus+ASAN green |
| S-3 | Single-StringBuilder JSX tree render | ✅ | corpus+ASAN green |
| S-4 | Non-zeroing arena header write | ✅ | corpus+ASAN green |
| S-5 | Zero-copy postgres decode (PgFrame/PgCursor view) | ✅ | driver-side |
| S-6 | Lazy `DbValue.arr` (optional, guarded) | ✅ | part of M-9 |
| S-7 | `g_waiters` thread_local (drop multi-core lock) | ✅ | corpus green |
| S-8 | Multi-core reactor spawn (`nova_run_reactors`) | ✅ | opt-in |
| S-9 | Response cache in the web layer | ✅ | opt-in |
| S-10 | gzip off by default | ✅ | pure-Nova DEFLATE too costly |

---

## Design detail

Each section below explains the "what and how" for one row. Keep the table above free of
this detail; when a row's status changes, update the table cell only.

### M-1 Value-type `struct`

**What.** Make `struct` a value type in the C# and Swift sense: the data lives inline
(in the caller's frame, inside its containing object, or in a register), it is copied on
assignment and on pass-by-value, and it carries no heap allocation and no refcount header.
`class` (M-2) becomes the reference type for anything that needs identity or sharing.

**Why.** This is the root fix. Nova's structs are currently reference types: codegen lowers
`.struct_init` to `compileAlloc(struct_size)`, i.e. `nova_bytes_alloc` plus the 8-byte ARC
header (refcount at offset -8, length at -4). Every `ProductView(...)`, every `DbValue`,
every small request-scoped record therefore pays a heap allocation on construction and an
atomic decrement on drop. That is the mechanism behind both the 40 percent malloc and the
27 percent ARC in the leaf profile. Turning value-shaped structs back into values removes
the allocation and the refcount at the same time, for the common case, without any new user
syntax beyond choosing `struct` vs `class`.

**How (sketch).**
- Codegen: for a value `struct`, allocate storage in the enclosing frame or object (an LLVM
  `alloca` or an inlined field range), not via `compileAlloc`. Pass small ones by value in
  registers, larger ones by hidden pointer (sret / byval), matching the platform ABI.
- Copies: assignment and by-value argument passing become a field-wise copy (memcpy for
  trivially-copyable, or a generated copy that recurses into reference fields, retaining
  those per M-3). No refcount on the value itself.
- Ownership: a value struct has no shared identity, so there is nothing to retain or release
  for the struct as a whole. Its *reference-typed fields* still participate in ARC (M-3).
- Migration: this flips the default meaning of existing `struct` declarations. Needs a
  sweep of the stdlib and drivers to re-tag the few types that actually rely on reference
  identity (they become `class`), plus corpus and ASAN as the gate. Expect this to be the
  largest single change and the one that moves the profile the most.

**Default-flip: driven to 313/316 under `NOVA_VALUE_STRUCTS_ALL` (2026-08-10), kept opt-in.**
The full flip (value-by-default, `class` only for heap/shared-identity types) was implemented and
hardened. Steps that landed:
  - The 7 collection containers (`List`/`Map`/`Set`/`Deque`/`OrderedMap`/`Heap`/`StringBuilder`)
    are marked `class` (a value collection would copy its control block while sharing the buffer,
    so a mutating helper's changes would be lost / corrupt the shared buffer).
  - **Trait-impl escape channel**: a struct that implements any trait can be widened to that
    trait's fat pointer (which stores a pointer to it), so it is excluded from value-lowering.
    This fixed the `traits`/`enum-method`/`generic-traits` crashes.
  - **Scalar-only fail-safe**: a struct is value-lowered only when ALL its fields are scalar
    primitives (`int`/`long`/`float`/`bool`/...). A `string`/`decimal`/**function**/struct/
    container/optional field is owned or non-trivially copied, which the inline byte-copy path
    does not yet handle (leak / double-free / the `FnHolder` fn-field infinite recursion), so any
    such field forces the whole struct to the heap. This fixed `map` and is what makes DbValue
    (string/decimal/List fields) correctly stay heap until owned-field value structs exist.
With those, the corpus under the flip is **313/316** (the always-off-Linux `189` plus two real
failures). Both remaining failures are the SAME class -- a value struct stored in a
**pointer-slot aggregate**: `42` returns `(P{n:1}, P{n:2})` (value structs in a **tuple**), `123`
boxes a struct into **`any`** (an implicit widen when stored into `Map<string, any>`). A tuple or
`any`-box holds a pointer to the stack alloca -> dangling. The crux (found while implementing the fix): heap-promoting a value struct at the aggregate-store
site does NOT work cleanly, because the aggregate decides per-element ownership from the element's
TYPE, and a value struct is "not owned" (stack, no ARC) -- so a tuple/`any`-box would never free
the promoted heap copy (leak). Making a value struct safe inside a pointer-slot aggregate requires
it to be **value in one place and reference in another (per-use duality)** -- i.e. a real
ownership/borrow model, or inline storage + inline copy/drop in EVERY aggregate (tuple, `any`-box,
closure environment, async frame), the way `List`/`Storage` now inline. Either is a substantial,
soundness-critical slice. So the flip stays **opt-in** (default OFF -> all-reference, corpus
315/316); under `NOVA_VALUE_STRUCTS_ALL` it is 313/316. The value-struct machinery, the
`List<value-struct>` inline win, and the return/field/container/trait/scalar escape channels are
all done and verified. The remaining work for a *default-on* flip, in order: (1) uniform inline
value-struct storage in the other aggregates (tuple, `any`, closure, async) OR a per-use borrow
model; (2) **owned-field value structs** (generated copy = memcpy + retain-refs, generated drop =
release-refs + no-free) -- required before `DbValue`/`ProductView` themselves can be value types.
M-9 DbValue slimming is DONE (the 16-byte decimal field is gone). Items (1) and (2) are the
genuinely hard, soundness-critical parts.

**Owned-field value structs (implemented; works except container grow).** This turned out NOT to
need move semantics -- uniform COPY semantics (retain on every duplication, release on every drop,
exactly how reference types already balance) is sound. Implemented and verified ASAN + ARC-audit
clean for value structs with `int`+`string` fields (e.g. a `ProductView`-shape) as LOCALS, under
`let b = a` COPY, and in NON-growing `List`s:
  - `retainValueStructOwnedFields` retains a struct's owned fields after a byte-copy (copy / container-insert);
  - `dropValueStruct` calls the struct's destructor DIRECTLY at scope/temp end to release owned fields with NO free (it is a stack alloca) -- wired into `releaseLocalByName`, the temp drain, and owned-field-value-struct locals are registered for scope drop;
  - the `Storage` destructor gained an inline-element loop (`buildInlineValueStructStorageLoop`) that releases each inline element's owned fields in place;
  - `buildValueStructStorage` now ZERO-inits the alloca, so an owned field's init "release the old value" sees null (a fresh raw alloca is garbage -> that first release would nova_release a junk pointer, SIGSEGV -- fixed);
  - the scalar-only fail-safe was relaxed to also allow `string` fields.
GROW DOUBLE-FREE -- FIXED. The bug was that `newData.set(i, self.data.get(i))` in `grow()` treats
`self.data.get(i)` (a value struct BORROW -- the old buffer slot address) as an OWNED temporary and
drops it at statement end, releasing the buffer element it aliases. Fix: register a value struct as
a droppable temp ONLY when it is a CONSTRUCTION, not a borrow (`compileExpression` now checks
`returnIsBorrow`). Verified: `List<ProductView>` (int + 3 strings + double), 50 elements across
several grows, ASAN clean AND ARC-audit clean. Owned-field value structs are now sound for locals,
copies, and GROWING containers.

REMAINING (exposed by the full flip): with `string` fields allowed, `NOVA_VALUE_STRUCTS_ALL` drops
from 313/316 to 304/316 -- nine new failures in **serde-binding, `try`/error-union, `??` coalesce,
and async** contexts (`13_serde`, `159_micro_orm`, `309_generic_async_serde_bind`, `45_try_returns_owned`,
`78_coalesce_owned_default`, `269_async_try_propagate`, ...). So a string-field value struct that flows
through those paths is not yet handled (each is another aggregate/coercion site like tuple/`any` that
needs inline-aware copy/drop). The catalog `ProductView` is serde-bound, so the real hot type needs
those before it can be value-lowered by default. For NON-serde use (construct + List + read), owned-field
value structs are complete and verified. The DEFAULT gate stays OFF, corpus 315/316.

**Copy foundation (superseded by the above).** The COPY half is built and sound:
`retainValueStructOwnedFields(structAddr, name)` walks a value struct's fields and retains each
owned (reference) field after a byte-copy, so `let b = a` for an owned-field value struct gives
`b` its own refs. The DROP half is a value struct calling its destructor DIRECTLY at scope end
(release owned fields, NO nova_release/free -- it is a stack alloca). But wiring these to actually
enable owned-field value structs hits the same wall as the aggregates: a value struct entering a
CONTAINER needs MOVE semantics (memcpy, no retain, source consumed), and `list.push(Foo(...))`
(a temp) is a move while `list.push(existingFoo)` (a live var) is a copy -- a per-USE distinction
the per-TYPE value/reference model cannot express. Since exclusion is per-type, allowing an
owned-field struct to be a value local ALSO allows it as a container element, which then needs
the move/copy decision. So both (1) and (2) reduce to the same root: **per-use move/copy/borrow
tracking** (an ownership pass extension). That is the single keystone for finishing M-1's
default flip; it is a substantial, soundness-critical slice, not a same-session task. The
copy-retain helper is landed as its foundation.

**Progress (foundation, gated).** The core mechanism works end to end behind a per-type
rollout gate (`NOVA_VALUE_TYPES=A,B` or `NOVA_VALUE_STRUCTS_ALL`; default off, so codegen is
unchanged and the corpus stays 315/316). A gated `struct` (is_reference==false) is:
  - stored inline via a stack `alloca` at all struct construction sites (`buildValueStructStorage`
    replaces `compileAlloc` at the field-literal path plus the three constructor-call paths), and
  - treated as NOT owned by `isOwnedTypeId` (a `.struct_` arm consulting `isValueStructName` /
    `isValueStructTid`), so the whole ownership machinery emits no retain/release/free for it.
Verified: `Point{x:int,y:int}` lowers to an 8-byte stack alloca (`Point_init(%vstruct_addr,...)`,
no `nova_bytes_alloc`, no `nova_retain`/`nova_release`), returns correct results, and is ASAN
clean; the default-off corpus is unchanged at 315/316. Two traps banked: (1) `renderLegacy`
returns a BORROWED/interned string — never free it, or sema's name cache corrupts and method
resolution breaks; (2) struct construction has FOUR codegen sites, all of which must be gated.
Still open before this can flip on by default: field-wise **copy-on-assign** (today `let b = a`
copies the address = aliases, not a value copy), value structs **inline inside containers and
other structs** (needs the M-10 real-width slot, since a struct field is still an 8-byte slot),
**escape analysis** (a value struct returned/stored/captured must be promoted), and value
structs **with owned (reference) fields** (their fields need dropping without freeing the
container). The initial rollout is all-primitive, non-escaping local value structs only.

**Safety boundary (escape == UAF) — now mitigated by conservative exclusion.** A value struct
that escapes its constructing frame would be a use-after-free: `fn make(a,b): Point { return
Point(a,b); }` lowered to a stack alloca does `ret i64 %vstruct_addr`, returning the address of a
slot freed on return. (This does NOT trip the ASAN gate — ASAN instruments the C++ runtime, not
nova-generated code, and the read usually finds stale-but-intact bytes, so it passes by luck and
corrupts only under stack reuse.) This is now handled by a **whole-program escape exclusion**
(`computeValueEscapeSet`, consulted by `isValueStructName`): a struct that appears as a function/
method return type, a struct field type, or a container element / generic arg is NOT
value-lowered and stays on the heap. Verified: `make(): Point` now allocates on the heap
(`alloc_tmp`, safe), while a purely-local `Point` still value-lowers to the stack; default-off
corpus stays 315/316. So the gated rollout is memory-safe by construction. The eventual
performance path still wants the escaping cases handled properly (sret return / heap-promotion
with ownership) rather than merely excluded, so escaping structs can also drop their ARC — but
that is an optimisation on top of a now-safe base, not a prerequisite for safety.

**Copy-on-assign (done for `let b = a`).** Value semantics require `let b = a` to give `b` its
own storage with `a`'s bytes copied in, not to alias `a`. Implemented via `buildValueStructCopy`
(fresh stack storage + `nova_bytes_copy`), triggered in the let path only when the target is a
value struct and the RHS is a plain variable (a fresh `Point(...)` construction already yields
distinct storage). Verified: `let a = Point(1,2); let b = a; b.setX(99)` leaves `a.x == 1` and
`b.x == 99`, with one `nova_bytes_copy` emitted, ASAN clean, default-off corpus 315/316. Still
open on the copy side: **argument-passing copy** (`foo(p)` still passes p's address = a borrow;
fine for read-only or mutate-locally callees, but not yet a value copy) and plain
**reassignment** (`b = a` as a statement). These are lower priority than container-inline (M-10),
which is where the allocation-elimination win actually lives.

### M-2 Reference-type `class`

**What.** Introduce `class` as the explicit reference type: heap-allocated, ARC-managed,
with identity (two `class` handles can point at the same object) and shared mutation. This
is exactly today's struct behaviour, kept but renamed and made opt-in.

**Why.** Some things genuinely need reference semantics: the connection pool, a live socket
wrapper, DI singletons, the `App`, anything shared across handlers or mutated through several
aliases. Splitting value `struct` from reference `class` is the idiomatic C#/Swift model and
fits Nova's TypeScript and C# flavour. It gives the user a clear, familiar lever: pick
`struct` for data, `class` for shared/identity objects.

**How (sketch).**
- Parser and sema: add the `class` keyword producing a reference-typed declaration. Reuse
  the existing heap+ARC lowering that structs use today (so `class` is close to a rename of
  the current path).
- Method calls, field access, and trait impls work the same on both; the difference is the
  storage and copy semantics decided at the type level.
- `new` is not required; construction stays `ClassName(...)`. The type's kind (value vs
  reference) determines whether that allocates.
- Spec: document the value-vs-reference rule in `specs.md` before the flip (spec-first).

### M-3 ARC only on heap/reference fields

**What.** After M-1/M-2, run retain and release only on fields that are actually reference
types (`class`, `string`, `List`, `Map`, boxed `any`, trait objects, owned pointers). Value
structs and primitives get no ARC at all.

**Why.** Once structs are values, most of the retain/release traffic in the 27 percent ARC
slice simply should not exist. The generated copy and drop code for a value struct should
touch only its reference-typed members. This is what makes M-1 pay off end to end rather
than just moving the cost around.

**How (sketch).**
- The copy and drop routines generated per type walk the field list and emit
  `nova_retain`/`nova_release` only where `isOwned(TypeId)` is true (the machinery from the
  F5 TypeId migration already answers this).
- Value structs embedded in value structs recurse; reference fields get one retain on copy,
  one release on drop, as now.
- Verify with ASAN and the ARC balance check; the existing ownership pass and balance
  assertions are the guardrail.

### M-4 Non-atomic refcount on the single-thread reactor

**What.** When an object never crosses a thread boundary, use plain (non-atomic) increments
and decrements for its refcount instead of `__atomic_fetch_add`/`__atomic_fetch_sub` with a
full ACQ_REL barrier on every drop.

**Why.** The web runtime is single-reactor-per-process by default; request-scoped objects
live and die on one thread. Paying an atomic read-modify-write with a memory barrier on
every retain and every release of such objects is pure waste. Swift does exactly this split
(it tracks whether an object may be shared across threads and uses non-atomic RC when it
cannot be). On the single-thread reactor this shaves a large part of the 27 percent ARC
cost that survives M-1/M-3.

**How (sketch).**
- Add a per-object or per-type "may escape to another thread" bit. Objects that provably
  stay on their creating thread (request-scoped values, per-coroutine data on one reactor)
  use non-atomic RC ops; anything handed to a channel, another reactor, or a background
  thread uses the atomic ops.
- Conservative default: atomic unless proven single-thread, so correctness never depends on
  getting the analysis complete. Start by flagging the obvious request-scoped allocations
  on the reactor path.
- Runtime: two code paths in `nova_retain`/`nova_release`, or a header bit that selects the
  path. Keep the header layout (rc@-8, len@-4) unchanged.

**Shipped.** `alloc.cpp` carries a process-wide `g_arc_multithreaded` flag (starts false).
`nova_retain`/`nova_release` take a plain non-atomic integer path while it is false and the
existing atomic path once it is true. `nova_arc_go_multithreaded()` flips it to true, called
just before every OS-thread creation in the runtime: the multi-reactor spawn
(`nova_run_reactors`), the debug I/O watchdog, and the Windows IOCP timer-queue arm. Thread
creation is the happens-before edge, so a `false` reading is only ever observed while the
process is genuinely single-threaded, and an object straddling the transition stays consistent
(its non-atomic writes precede the flip, which precedes the first other thread). Verified:
corpus 315/316 (only `189` off-Linux) with every single-threaded case on the non-atomic path
and the multicore cases 195/206 on the atomic path; ASAN clean (only `189`). No observable
semantics changed.

### M-5 ARC elision (expand the borrowed-field prototype)

**What.** Statically remove retain/release pairs that cancel out, i.e. where an object is
only borrowed for the duration of a call and its refcount is provably stable. Grow the
existing prototype from the single borrowed-field pattern to the general case.

**Why.** Even with non-atomic RC, the cheapest refcount op is the one you do not emit.
Swift's optimiser elides ARC aggressively; Nova has the scaffolding but it is switched off.

**How (sketch).**
- The prototype lives in `arc.zig` as `elideBorrowedArc`, gated by `NOVA_ARC_ELIDE` with
  `elide_enabled = false`. It currently only handles the borrowed-field read pattern.
- Extend to: borrowed call arguments (callee does not store the arg), pass-through returns,
  and retain/release pairs with no escaping use between them.
- This must run after the ownership pass and be validated by the same balance check plus
  ASAN. Turn it on by default only once the corpus and ASAN gates stay green with it.

**Shipped (prototype on by default).** The borrowed-field prototype (`elideBorrowedArc` in
`arc.zig`, a conservative peephole that removes a `nova_retain` together with its paired
`nova_release`(s) when a local only ever holds a value copied out of a borrowed parameter's
field and never escapes) is now enabled by default in `main.zig`; `NOVA_ARC_ELIDE_OFF`
disables it for debugging. Verified balance-preserving: corpus 315/316 (only `189` off-Linux),
ASAN clean, and a differential `NOVA_ARC_AUDIT` check on 12 ARC-heavy cases (collections,
maps, closures, owned aggregates, try-returns-owned) reported `ARC audit: clean` identically
with elision off and on, so no release was wrongly dropped. Note: the full sequential `--arc`
gate hangs in this environment on a reactor/server case, so the differential per-case audit is
used as the leak check. Still open (the "expand" part): borrowed call arguments, pass-through
returns, and general retain/release pairs with no escaping use between them.

### M-6 Per-coroutine region arena + escape analysis

**What.** Give each in-flight request (each coroutine) its own bump arena that is reset to
empty when the request completes, so per-request allocations are freed in one pointer move
instead of individually. Pair it with escape analysis so only non-escaping, request-lifetime
allocations go into the region.

**Why.** Request handling allocates many short-lived objects that all die at end of request.
A per-request region turns thousands of frees into one reset. This is the classic web-server
allocation strategy.

**Status and the trap (why it is parked).** A first attempt used the *shared thread-arena*
(`nova_arena_mark`/`nova_arena_reset`) and reset it per request in `handleConn`. That failed
and was reverted: under `c=50` there are about 50 requests in flight on one reactor, their
allocations interleave, so a single shared arena has no LIFO discipline to mark and reset
against, and roughly 50 concurrent requests times about 1MB overflowed the 32MB
`FALLBACK_ARENA_SIZE`. The mark/reset primitives were kept as unused runtime primitives; the
`handleConn` usage and the StringBuilder-on-arena experiment were removed (StringBuilder went
back to `bytes.alloc_persistent_nz`).

**How (the real fix).**
- The arena must be **per coroutine**, not per thread: each request gets its own arena that
  lives exactly as long as the coroutine frame, so reset is unambiguous and concurrent
  requests do not share a bump pointer.
- Escape analysis decides what may go in the region: only allocations that do not outlive the
  request (do not get stored in a singleton, returned to the caller past the response, or
  handed to another coroutine). Escaping allocations use the persistent allocator.
- Sizing: per-coroutine arenas can start small and grow or spill to malloc on overflow, so
  one large request cannot starve the others.
- This depends on M-1 (fewer allocations to begin with) and interacts with M-4 (region
  objects are single-thread by construction, so they also get non-atomic RC).

### M-7 Owned-handle type (`Fd`/`Socket`) + RAII destructor

**What.** Model native resources (file descriptors, sockets, OS handles) as a single owned
handle type whose compiler-generated destructor closes the underlying resource. Composition
propagates it: a `class` or value struct that owns an `Fd` field gets its close run
automatically when the owner is destroyed. Provide an explicit, idempotent `close(): Result`
for the error path, with the destructor as the safety net.

**Why.** A socket or fd is a native resource with a lifetime that must end exactly once.
Nova's ARC is deterministic, so a destructor tied to the last release closes the resource at
a known point, which is strictly better than Go's non-deterministic GC finalizers (which can
leak fds under load) and matches Rust `Drop`, Swift `deinit`, C++ destructors, and C#
`Dispose` plus finalizer. Tying the close to the type, not to hand-written cleanup at every
call site, is what makes it reliable.

**How (sketch).**
- Define one owned-handle type (working name `Fd`, with a `Socket` built on it) that carries
  the raw handle and the close logic. It is the sole owner of the OS resource.
- Compiler-generated destructor: when a type is destroyed, its generated drop routine runs
  field destructors recursively; a field of handle type runs its close. This reuses the same
  field-walk as M-3, extended to call a destructor hook, not just release.
- Single-owner rule to prevent double-close: the handle is either move-only (transfer of
  ownership invalidates the source) or lives inside a single-owner `class` (one deinit). Two
  live copies that both close the same fd must be a compile error, not a runtime double-close.
- Explicit `close(): Result` is idempotent (closing twice is a no-op that returns already-
  closed rather than erroring), so the error path can close eagerly and the destructor
  closing again is harmless.
- The connection, pool, and TLS bio types wrap their fd/socket in this handle so leak-under-
  load goes away by construction.

### M-8 Singleton lifetime via root ownership + borrow

**What.** Long-lived shared objects (the connection pool, a shared connection, the `App`,
DI singletons) are reference types (`class`) owned by a root that lives for the whole
process. Request handlers **borrow** the singleton rather than retaining it per request.

**Why.** This answers "how does a singleton connection object live through the app's
lifetime": the `App` is held by `main`'s frame, and `app.run()` loops forever and never
returns, so everything transitively owned by `App` lives for the process. Handlers borrow
the pool by reference: zero copy, and crucially no per-request retain/release on the shared
object (which would otherwise be atomic contention across all requests). This mirrors Rust's
`Arc<Pool>` handed out as `&Pool`, Swift's shared class instance, and Go's heap object kept
alive by a package-level reference.

**How (sketch).**
- DI registers singletons as `class` instances owned by the container, which is owned by
  `App`, which is owned by `main`. One ownership chain rooted in the never-returning
  `app.run()`.
- Handler injection passes the singleton **by borrow** (a non-owning reference), so entering
  and leaving a handler does not touch the singleton's refcount. This is where M-4's
  single-thread analysis and M-5's elision matter most: the shared pool is read on every
  request and must not become a refcount hotspot.
- The rule to document: singletons are `class`, owned once by the root, borrowed everywhere
  else. Never store a per-request owning copy of a singleton.

### M-9 `DbValue` slimming

**What.** Shrink the `DbValue` record so each cell of a result set is cheaper to build and
carry. `DbValue` is currently a fat struct: `{ kind, i:long, f:double, dec:decimal, s:string,
arr:List<DbValue>|undefined }`, i.e. every scalar cell carries slots for a decimal, a string,
and an array even when it is a single int.

**Why.** A result set is thousands of `DbValue`s per query. Under the current reference-type
struct model each one is also a heap allocation (see M-1), and the fat layout means each
allocation is large and each copy touches more memory (feeding the 11 percent memset too).
Slimming the shape is complementary to M-1: fewer and smaller allocations per row.

**How and progress.**
- Done so far (S-6): `arr` was made lazy and optional. It initialises to `undefined` and the
  array accessors (`asArray`, `arrayLen`) are guarded, so scalar cells no longer allocate a
  `List<DbValue>` they never use.
- Done (M-9): the 16-byte inline `decimal` field (`dec`) was removed -- it was ~30% of every
  cell across thousands of cells per result set. A DECIMAL value is carried exactly by its
  canonical text in `s` (every driver already passed both `decimal.fromString(raw)` and `raw`),
  so `asDecimal()` reconstructs it on demand via `decimal.fromString(self.s)`; `dbDecimal(d)` now
  stores `` `${d}` `` in `s` to match. The 5-argument `init(kind,i,f,dec,s)` signature is kept
  (the `dec` param is accepted and ignored, `_ = dec;`) so the five drivers compile unchanged.
  Verified: decimal round-trips exact, corpus 315/316, ASAN clean on the decimal cases.
- Still open (needs M-1 value structs): the remaining `i`/`f` overlap, and ultimately making
  `DbValue` itself an inline value with NO per-cell heap allocation -- that is the end state and
  is gated on owned-field value structs (DbValue has a `string` field).

### M-10 Retire `Storage` bespoke ARC + fixed 8-byte slot

**What.** `List`, `Map`, and `Set` are all built on `Storage<T>`, a compiler-intrinsic backing
buffer. Fold what `Storage` hand-codes into the general value/reference model, and give it a
real per-element slot width instead of a fixed 8 bytes. The collection backbone (the control
block) becomes a value type that uniquely owns its buffer; the buffer stops being a
refcounted "persistent" object and becomes a uniquely-owned run freed by a destructor.

**Why (what `Storage` is today).** `Storage<T>` is not Nova source; it is a first-class
`.storage` kind special-cased in codegen. `Storage<T>(n)` allocates `n * 8` bytes on the
malloc heap (`compileAllocPersistent`, with the refcount header). Every slot is **8 bytes
regardless of `T`**. `.get`/`.set` are raw `base + i*8` load/stores; when the element is a
reference type, `.get` retains and `.set` retains-new-then-releases-old (`isOwnedStorageElem`),
and a generated Storage destructor (`buildStorageDestructor`) loops the buffer releasing each
owned element. So `Storage` already conflates three separate concerns that the value/reference
split lets us pull apart:

1. **Element ownership.** `isOwnedStorageElem` + the destructor loop are a hand-written version
   of "a field that owns its elements: copy retains, drop releases." Once M-3 lands (ARC only
   on reference fields via compiler-generated typed copy/drop), this special case disappears
   into the general machinery. `List<string>` owning its strings becomes the same path as any
   value struct owning a `string` field. Delete the bespoke codegen.
2. **Buffer lifetime.** "Persistent" means a real heap allocation with its own refcount header,
   as opposed to the per-request arena. If the collection is a value type that *uniquely owns*
   its buffer, the buffer needs no refcount at all, only a destructor that frees it on drop.
   That is the Rust `Vec` model: one owner, zero refcounting, deterministic free. Today the
   buffer carries an atomic refcount it does not need. The alternative, a shared `class`-owned
   buffer, brings the refcount back and forces copy-on-write (the Swift `Array` model). Use
   unique ownership for the collection backbone; reserve `class` for buffers meant to alias.
3. **The raw indexable run.** This is the one part `class` cannot replace. A `class` is a
   single named-field heap object, not a variable-length index-addressable growable array. Some
   low-level "contiguous run, addressable by index, reallocatable" primitive must remain (Rust
   keeps `RawVec`, C++ `operator new[]`, Swift `_ContiguousArrayBuffer`). `Storage` survives
   here, demoted from a magic owning ARC object to a typed array the compiler lays out.

**The fixed-slot payoff.** Because every slot is 8 bytes, anything larger than a scalar or a
pointer must be boxed to fit, which reintroduces a per-element heap allocation and per-element
ARC. `List<Point>`, `List<DbValue>`, `List<SomeStruct>` all pay that now. A monomorphized slot
of the element's real size makes those a flat buffer of inline values: no per-element box, no
per-element ARC, better cache behaviour. This hits the result-set path (`List<DbValue>` per
query, see M-9) directly and is arguably the largest single win in this row.

**How (sketch).**
- Reshape `.storage` into a typed buffer whose slot width is the monomorphized element size,
  not a constant 8. Scalars and value structs sit inline; reference types store their pointer.
- Delete `isOwnedStorageElem` / `buildStorageDestructor` as special cases; let the general
  typed copy/drop (M-3) generate element retain/release only for reference elements.
- Make the collection control block (`{data, len, cap}` for `List`; keys/vals/slots for `Map`)
  a value type (M-1) that uniquely owns its buffer, so the buffer is freed by the control
  block's destructor with no buffer-level refcount.
- Small-size specialisation (small-vector optimisation): reserve a few inline slots in the
  value control block so a small `List<int>` or `Map` never touches the heap, spilling to the
  owned buffer only past the inline capacity. Combined with escape analysis (M-6), a
  non-escaping small collection is entirely on the stack or in the per-coroutine arena.
- `Map`/`Set` already use open addressing over parallel `Storage` arrays (`keys`/`vals` plus a
  byte `slots` array), so they are one flat buffer set, not per-entry nodes: they get the same
  treatment as `List` with no extra work on the collision strategy.
- Gate: the collections are exercised across the whole corpus, so corpus plus ASAN are the
  authority here; watch the ARC balance check closely because this removes hand-written
  retain/release and relies on the generated equivalents being exact.

**Landing order.** This depends on M-1 (value control block, inline value elements), M-3 (typed
copy/drop replacing the bespoke element ARC), and pairs with M-9 (a slim, inline `DbValue` in a
real-width `List<DbValue>` slot). Do it after M-1/M-3 are stable.

**Full retirement, Swift-grounded (2026-08-10 — revises point 3 above).** Point 3 claimed a
`class` cannot be the raw run. Swift shows it can, and that there is no need for a separate
"storage type" at all -- so we retire the `.storage` INTRINSIC entirely rather than demote it.
Swift's array is `Array<T>` (value, copy-on-write) -> `_ContiguousArrayBuffer` ->
`__ContiguousArrayStorage`, and that last one is a **`class`**. The only primitives are:
`Builtin.allocWithTailElems` (tail-allocate the element run right after the class header),
`UnsafeMutablePointer<Element>` with `.initialize`/`.deinitialize`/`.move` (typed element
copy/drop), and `MemoryLayout<Element>.stride` (real slot width). Element cleanup is the storage
class's `deinit` calling the element type's value witness.

Nova's `.storage` conflates two roles Swift keeps apart: the **buffer object** (a `class` + a
`ptr`/`cap` field can be this -- `bytes.alloc` already gives the run) and the **typed element
witness** (copy/drop/stride for `T`, which Nova buries in `isOwnedStorageElem` +
`buildStorageDestructor`). Split them:

1. **Typed-element intrinsics = Nova's value witnesses. [P1 -- LANDED (commit 231762f), builds.]**
   `mem/witness.nova` declares `sizeOf<T>(): int`, `copyElem<T>(dst, src)` and `dropElem<T>(addr)`;
   codegen (`compileElemWitness` in `expressions.zig`, intercepted at the top of the `.generic_call`
   arm) lowers each call to exactly the typed copy/drop the struct field-walk (M-3) already emits --
   no new ownership logic, just exposed to Nova source. Slot model: a value struct occupies its real
   width inline (`copyElem` = `buildValueStructCopyInto` + `retainValueStructOwnedFields`; `dropElem`
   = the value-struct destructor); everything else is one 8-byte slot (load/store the value/pointer;
   `compileRetain`/`compileRelease` when `ownedByName`). Bodies are dead fallbacks so sema resolves +
   monomorphizes per `T`. These are Nova's `UnsafeMutablePointer.initialize`/`.deinitialize` +
   `MemoryLayout.stride`. STILL TO ADD for P2: value-in / value-out witnesses (`store`/`load`), since
   `copyElem` is slot-to-slot (addresses) but a collection pushes/reads a `T` in its native
   representation (address for a value struct, an 8-byte value for a scalar/reference).
2. **Pure-Nova `class RawBuffer<T>` [P2 -- LANDED (commit 9020fa8), ARC-clean case 319].** Holds
   `data`/`cap`/`len`; push/at/set/pop/insertAt/removeAt/clear go through the witnesses (incl.
   `store`/`storeOver`/`load`/`moveElem`/`moveOut`), grow MOVES the live prefix wholesale, `delete()`
   (the M-7 hook) drops every live element then frees the run. Uniquely owned -> no buffer refcount.
   Verified for scalar / reference / value-struct elements.
3. **Rebuild `List` on `RawBuffer<T>` [P3 -- DONE, corpus 319/320 + ASAN green].**
   `List`'s backing is now `data: RawBuffer<T>`, not `data: Storage<T>`. Getting there needed three
   codegen fixes, each a real defect the intrinsic `.storage` had hidden by never being a genuine
   generic Nova class:
   - **Mono worklist follows the backing chain.** In erased / default-ctor / nested-generic contexts
     `List<T>` referenced the ERASED `RawBuffer_init`/`RawBuffer_delete` (undefined at link) because
     the worklist did not instantiate `RawBuffer<X>` for every `List<X>` (same class as the B4 Set
     field-noting fix). Default-ctor field construction now substitutes type args, and RawBuffer
     erased fallbacks are emitted unconditionally (internal linkage, DCE-dropped if unreachable).
   - **Value-optional element ABI.** A `List<T | undefined>` stores each element as a heap value-box
     (0 = undefined, ptr = present); the box is created at the call site and must survive INTACT into
     the element slot. Two speculative unboxes stripped it -- the ident-unbox in `compileExpression`
     (fires when the checker records a bare use-type for a value-optional local) and the arg-unbox in
     `compileCallArgument`. Both are now gated by `suppress_valopt_unbox`, set on any method argument
     whose parameter (or whose own local slot) is a value-optional -- because monomorphisation
     collapses a generic container's value-optional type arg, so only the arg's slot type is reliable.
     The witness `store`/`load`/`dropElem` treat the box as an ordinary owned heap reference
     (retain-on-store, release-on-drop), balancing the call-site temp. Cases 280/286/311/312 pass
     ARC-clean.
   - **Closure capture vs method-name collision.** `scanExprCaptures` skipped a captured free
     variable when SOME function name ended in `_<name>` -- so a local `base` stopped being captured
     the moment a `RawBuffer_base` method existed, silently dropping the capture (case 68, a closure
     in a generic method). A name that is a PARAMETER of the enclosing function is now always treated
     as a capture, ahead of that loose function-suffix heuristic.

   P1+P2 (witnesses + `RawBuffer`) and now P3 (`List`) are landed and green.

4. **`Map`/`Set` on `RawBuffer<T>`, then delete `.storage` [P4 -- next].** With the mono, value-optional
   and capture fixes in place, `Map`/`Set` follow the same swap, after which `.storage`,
   `isOwnedStorageElem` and `buildStorageDestructor` (~52 touchpoints) can be deleted.

Expected perf: the largest memory win (inline value elements, no per-element box/ARC) already
landed with M-1 + List-inline; this adds dropping the buffer's own atomic refcount (one fewer ARC
object + its ops per collection) and removes the bespoke-ARC dispatch, plus a much simpler
compiler. Phased with a corpus+ASAN checkpoint after (a) the intrinsics [done], (b) `List` on
`RawBuffer`, (c) `Map`/`Set`, because it swaps hand-written retain/release for the generated
equivalents and the ARC balance must stay exact.

**Progress (Storage inline core done + a coupling found).** The `Storage<T>` intrinsic now
stores a value-struct element INLINE at its real width instead of as an 8-byte pointer slot
(gated behind the M-1 value gate, default off, so nothing changes by default; corpus 315/316):
  - `Storage<T>(n)` sizes the buffer by the element's real slot width (`n * getTypeSize`) rather
    than `n * 8`;
  - `.get(i)` returns the slot ADDRESS (the element is the inline bytes) and takes no ARC;
  - `.set(i, v)` memcpies the element's bytes into the slot (`buildValueStructCopyInto`) with no
    ARC, so the buffer owns the copy and the source stack alloca can safely die.
The escape exclusion (M-1) was refined to match: a container-wrapped type param (`data:
Storage<T>`) is inline-safe and no longer excluded; only a DIRECT type-param field (`Holder<T>{
p: T }`) still excludes its arg. A direct `List<Point>` test constructs and round-trips fine.

**Coupling found (the remaining blocker for `List<T>` inline).** `List.at(i): T` and
`get(i): T | undefined` RETURN the element by value, so the return-type escape channel
conservatively keeps `Point` on the heap — which means `List<Point>` currently stores heap
pointers, not inline values, even with the inline machinery in place. Inlining a value struct
into a `List` therefore requires the value-struct RETURN slice first: `List.at` must return the
inline slot address safely (a borrow into the buffer, valid until the next grow), and the
return-type channel must stop excluding value structs once returns are handled (sret for
constructed returns, buffer-interior address for container gets). So M-10's remaining work is
gated on the M-1 return-handling slice; the inline storage itself is done.

**Update: `List<value-struct>` inline now works end-to-end (gated, ASAN-clean).** Rather than
the full sret ABI change (which touches 90+ call sites), the return-type escape channel was made
precise: a value struct is excluded only when a function *constructs and returns* it (a fresh
stack alloca that would dangle), not when it is returned by borrow (`List.at -> self.data.get(i)`
returns a buffer-interior address, which is safe). Copy-on-assign was extended to value-struct
borrow-returns, so `let p = list.at(i)` copies the element out of the buffer (independent, and
safe across a later grow). Two traps fixed along the way: (1) `return undefined` and other
literals were mis-classified as constructions -- the borrow whitelist now includes literals,
reads, arithmetic, casts, and non-constructor calls, with everything else conservatively
excluded (fail-safe); (2) a value-struct construction was being registered as an ARC temporary
and `nova_release`d at end of statement -- freeing a stack alloca (SIGBUS) -- so value structs
are no longer registered as temporaries. Verified: `List<Point>` push/at/field-access/method
round-trips with the elements stored INLINE in the buffer (one `nova_bytes_copy` per push, zero
`nova_release`, zero per-element `nova_bytes_alloc`), ASAN clean, default-off corpus 315/316.
Remaining for M-10: `Map`/`Set` inline (only `List` exercised so far), value-struct elements
larger than a pointer or with owned (reference) fields, and finally retiring the bespoke
`isOwnedStorageElem` path for the reference-element case.

---

## Shipped micro-optimizations (S-rows)

These are already applied and corpus/ASAN green. They are real wins on the render and decode
path but they are *not* the root fix; M-1 through M-6 are. Recorded here so the table is
complete and nobody re-does them.

### S-1 `escapeHtml` scan-and-run
`escapeHtml` now scans the input first and returns the input string unchanged when there is
nothing to escape, instead of always building a new buffer. Most rendered text is clean, so
this removes an allocation and a copy from the common render path.
(`lang/src/std/web/response.nova`.)

### S-2 `bytes.copy` in StringBuilder and string.slice
Added a `bytes.copy(dst, src, len)` intrinsic backed by `nova_bytes_copy` (memmove).
`StringBuilder.append`/`toString`/`ensureCapacity` and `string.slice()` now use it instead of
byte-by-byte loops. `string.slice` is `bytes.copy(ptr as long, (s as long)+start, len)`.
(`string_builder.nova`, `string.nova`, `alloc.cpp`, `expressions.zig`.)

### S-3 Single-StringBuilder JSX tree render
JSX/NSX rendering was refactored to `emitJsxInto` with `jsxAppendVal`/`jsxAppendLiteral`/
`jsxAppendExpr`, so a whole element tree renders into one shared `StringBuilder` instead of
allocating and concatenating a string per node.
(`expressions.zig`, `llvm_codegen.zig` bindings.)

### S-4 Non-zeroing arena header write
The arena allocation path uses `write_header_nozero` instead of memset-zeroing freshly bumped
memory that is about to be overwritten anyway, trimming part of the 11 percent memset.
(`alloc.cpp`.)

### S-5 Zero-copy postgres decode
The postgres driver decodes rows as views over the receive buffer: `PgFrame{ftype,payload,
off,len}` for a 'D' message and a `PgCursor(buf,start,end)` that reads raw bytes via a
`bufSlice` memcpy, with `decodeDataRow(buf,off,len,cols)`. Avoids per-cell allocation while
parsing the wire protocol.
(`~/.nova/cache/nova-postgres/src/{proto,codec,postgres,auth}.nova`.)

### S-6 Lazy `DbValue.arr`
See M-9: `arr` is optional, initialised `undefined`, accessors guarded. Scalar cells no longer
allocate an array. (`db.nova`.)

### S-7 `g_waiters` thread_local
`g_waiters` in the concurrency runtime was made `thread_local` and the seven
`lock_guard(g_waiters_mu)` sites removed, so the reactor wait map is not a cross-core
serialization point. (`concurrency.cpp`.)

### S-8 Multi-core reactor spawn
`runReactors(n, worker)` maps to `nova_run_reactors`, which spawns `n` reactor threads
(`std::vector<std::thread>`). Opt-in via `NOVA_WEB_WORKERS`; single-reactor stays the default.
(`poller.nova`, `concurrency.cpp`, `app.nova`.)

### S-9 Response cache
The web layer can cache a rendered response (`cache`/`cacheable`/`enableCache`/`cachedCopy`)
so identical responses are not re-rendered. Opt-in; stale-on-write handled by the caller.
(`app.nova`.)

### S-10 gzip off by default
gzip is off by default because the pure-Nova DEFLATE was measured using about 60 percent more
CPU, which dominated the response path. Kept available, opt-in. (`app.nova`.)

---

## Sequencing

1. M-1 + M-2 first (value `struct` / reference `class`) with a spec update. Everything else
   compounds on top of it, and it moves the profile the most.
2. M-3 falls out of M-1/M-2 (ARC only on reference fields).
3. M-4 and M-5 (non-atomic RC on the reactor, expand elision) attack the ARC cost that
   survives.
4. M-6 (per-coroutine region + escape analysis) is the harder, second-order allocation win;
   parked until the per-coroutine arena exists, since the shared-arena version is proven not
   to work under concurrency.
5. M-7 and M-8 (native-resource RAII, singleton borrow) are correctness-and-lifetime work
   that ride on the value/reference split; M-8's design is settled, M-7 needs the destructor
   hook.
6. M-9 slimming lands cleanly once M-1 makes `DbValue` an inline value.
7. M-10 (retire `Storage`'s bespoke ARC and fixed slot) rides on M-1 and M-3, and pairs with
   M-9: a slim inline `DbValue` in a real-width `List<DbValue>` slot is the end state for the
   result-set path. Do it after M-1/M-3 are stable.

Gate every code change with the corpus (`conformance/run.sh -j`) and ASAN
(`NOVA_ASAN=1 zig build` then `conformance/run.sh --asan`). Verify memory with `--asan`, not
`--arc`.
