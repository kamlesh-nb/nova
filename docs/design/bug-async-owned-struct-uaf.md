# BUG: use-after-free of an owned struct held across `await` in the reactor path

Status: OPEN (lang-track, runtime/ARC + coroutine lowering)
Found: 2026-08-08, via the mongodb document-API driver used from the web reactor.
Severity: high — corrupts memory (SIGSEGV / wild control-flow) on a normal, idiomatic pattern.

## One-line

An ARC-owned aggregate (a struct that owns a heap `List`) that is created in an `async fn`, returned to a
caller, and then **held in a local across `await`s while a method is called on it**, is freed too early by
ARC in the real reactor path. The next access reads freed memory whose bytes have been recycled into a
string, so the load of the list's backing pointer faults.

## Reproducer (real)

`nova-mongodb`'s native document API, driven from a `web.app` handler:

```nova
// store.categories() -- async handler path
let cur  = await coll.find(mongodb.all(), mongodb.findOptions()); // find() is async; returns a Cursor
                                                                  //   that OWNS `batch: List<Doc>`
let out  = list.List<catalog.CategoryView>();
while (true) {
    let dn = await cur.next();          // async METHOD, self: Cursor by value; reads self.batch
    if (dn == undefined) { break; }
    out.push(categoryFromDoc(dn));
}
```

`Cursor.next()` (driver) first line:

```nova
pub async fn next(self: Cursor): document.Doc | undefined {
    if (self.pos < self.batch.size()) { ... self.batch.get(self.pos) ... }  // <-- faults here on 1st call
```

Every request 500s/aborts; under load the benchmark shows `0.00% ok`.

## lldb evidence (clean debug build, original driver)

```
stop reason = EXC_BAD_ACCESS (code=1, address=0x627568617acda030)
frame #0: 0x…  nova`List_Row_get + 120
->  ldr  x0, [x8]        ; x8 = the list's backing-data pointer
    bl   nova_retain
```

* The faulting load is `List<T>.get` reading the list's **backing pointer**, which is
  `0x627568617acda030`. The high bytes are ASCII: `62 75 68 61` = `"buha"`. The `Cursor.batch` list
  struct was **freed and its memory reallocated to hold a string**, so its `data` field now contains
  character bytes, and dereferencing it faults.
* `List_Row_get` is the real crash site, not mis-symbolication: `List<Doc>.get` and `List<Row>.get`
  share the monomorphized symbol. The debug build's PC is genuinely inside that function.
* The `.ips` crash reports show garbage frames (`List_Row_get <- web_app_reactorWorkerBody <- start`)
  because the fault is a use-after-free, not a clean call — the unwinder has no valid stack above it.

Conclusion: **the `Cursor` (or its owned `batch`) has been released while the caller's `cur` local is
still live**, i.e. an ARC refcount reached zero one drop too early, across the `await`.

## Why the SQL drivers do NOT hit this

Same `List`, different lifetime. The SQL drivers (`postgres`/`mysql`/`mssql`) do
`let rs = await conn.query(...)` — **one** round-trip that returns a fully materialized `ResultSet` —
then iterate it with **synchronous** `rs.row(i)` calls. The owned result is never held across a second
suspension, so ARC keeps it alive for the whole (synchronous) walk. The mongodb document API is a **lazy
cursor**: the owned `Cursor` is held across `await cur.next()`, which is exactly the pattern that frees
early. (The mongodb driver's *own* `query()` seam materializes like the SQL drivers, and it works — so
this is not a mongodb-specific defect, it is the lazy-cursor lifetime.)

Confirmed the crash is intrinsic to the cursor, not the store loop: switching the store to the driver's
`Cursor.toList()` (materialize) still crashes, because `toList` drains via the same `await self.next()`.

## What is NOT the cause (ruled out)

* Not driver logic. Rebuilding the batch directly into the cursor (avoiding an intermediate
  `CursorPage`) produced a byte-identical crash.
* Not the migration/app code. It compiles cleanly (debug + release); the identical app shape over the
  SQL seam works.
* Not the data or environment. mongod up, `pizzahub` seeded (17 categories / 201 products, verified).

## Repro boundary (honest: the exact codegen trigger is NOT yet pinned)

Standalone, block-driven reductions of the shape **all pass** — see
`scratchpad/repro{1..6}.nova`. They cover: async fn returning a struct that owns a `List`; an async
method taking `self` by value and reading the list; nested element structs owning strings (incl.
heap-allocated); the cursor also owning a large by-value struct field (a `MongoConnection` stand-in);
`next()` mutating `self.pos`; a real suspension via `spawn`; and returning `Item | undefined` from the
async method with the loop null-check. None crash.

So the simple shapes are safe. The trigger requires the **real reactor path**: multiple *genuine* I/O
suspensions (a plain `main` block-drives coroutines to completion and never spills/reuses the frame the
way the reactor does), the concrete `MongoConnection` carrying a live `aio.AsyncIO`, and the deep async
call chain `handler -> ensure() [connect I/O] -> find() [find I/O] -> next()`. This matches the runtime
note in `lang/CLAUDE.md`: "A coroutine handle is a FRAME ADDRESS — and addresses get recycled." A frame
reaped mid-batch whose address is handed to a new allocation is exactly the shape that turns an early
release into a string-bytes-in-a-pointer fault.

## Root cause (hypothesis, consistent with all evidence)

An ARC-owned by-value value that is **live across a suspension point** in the reactor is released one
drop early. The most likely site is the coroutine lowering: when an owned aggregate (a `self`/param, or a
local like `cur`) must persist across `await`, it is spilled into the LLVM coroutine frame, and the
retain/release balance that the ownership pass proves correct **on the stack** is not preserved when the
value crosses into the heap coro frame + its `coro.destroy`/cleanup path. The sync path is fine; the
async+reactor path drops the extra reference.

This is precisely the class the `--asan` gate is meant to catch, and it is **green (266/266)** only
because no conformance case holds an owned aggregate across `await method()` under a real reactor.

## ASAN pin-down (2026-08-08) — CONFIRMS coroutine-frame corruption

`nova build` was made ASAN-aware (default ON for debug native builds; see main.zig `asan` in the
`--native` path). Building the app with it and firing one request:

```
==ERROR: AddressSanitizer: BUS on unknown address (pc 0x000d00001103 ...)
    #0 0x000d00001103  (<unknown module>)               <- jumped to a GARBAGE pc
    #1 web_app_reactorWorkerBody+0x210 (nova)            <- the reactor resuming a coroutine
SUMMARY: AddressSanitizer: BUS (<unknown module>)
```

This is a second, independent tool agreeing with the lldb finding, and it SHARPENS it: the fault is a
**wild jump out of the coroutine-resume in `web_app_reactorWorkerBody`** — the reactor resumed a
coroutine whose saved resume target (in its frame) was garbage. So the corruption is of the **coroutine
FRAME** (its resume pointer and/or the owned locals spilled into it), not a plain data read of a freed
`List`. That rules out a driver-data UAF for good and pins the class to coroutine-frame lifetime in the
reactor resume path — cf. `lang/CLAUDE.md`: "A coroutine handle is a FRAME ADDRESS — and addresses get
recycled."

Limitation: ASAN reports this as a BUS/SEGV with no alloc/free provenance, because the faulting access is
in **Nova-generated code, which is not ASAN-instrumented** (the `--asan` gate and this `nova build` ASAN
mode both rely on the sanitized *runtime* `novacore_asan`, not on instrumenting Nova code — deliberately,
to avoid false positives on Nova's `ptr-8` header idioms). Getting the exact premature `nova_release` line
would require adding the AddressSanitizer LLVM pass to the Nova codegen pipeline (`emitModule`), which is a
larger, riskier change; the crash class is now confirmed without it.

## Proposed fix (direction)

1. **Coroutine frame ARC discipline.** When an ARC-owned value (`isOwnedTypeId`) is captured into the
   coroutine frame because it is live across a suspension, it must be **retained on capture (at
   `coro.begin`) and released exactly once on frame destruction** — giving the frame its own reference for
   its lifetime, independent of the caller's. Symmetrically, a **borrowed** by-value receiver/param must
   NOT be released on frame teardown. Files: `src/codegen/declarations.zig` (coro frame setup / param +
   cross-suspend local spill) and `src/codegen/arc.zig` (retain/release emission); ownership comes from
   the TypeId engine.
2. **Pin it first, don't guess** (I have guessed wrong on this bug before): build the failing app against
   `libnova_runtime_asan.a` (`NOVA_ASAN=1`) and run one request — ASAN will report the exact
   alloc/free/use stacks and name the premature `nova_release`. Alternatively, an lldb **watchpoint** on
   the `Cursor`'s refcount word (`ptr-8`) will stop on the drop-to-zero, giving the offending frame.

## Validation plan

* Add a conformance case that reproduces under the reactor: an async fn returns a struct owning a
  `List`, a handler holds it in a local and calls an `async` method on it across `await` in a loop; assert
  the collected values. Gate it under `conformance/run.sh --asan` (it must catch the UAF before the fix
  and pass after).
* Re-run the full corpus + `--asan` + `--arc` after the fix.

## Interim workaround (unblocks the benchmark without the lang fix)

Do not hold a lazy `Cursor` across `await`s in application code. Either use the mongodb `query()` seam
(materializes, proven to work), or add a driver method that materializes a `find` into a plain
`List<Doc>` **within one async scope** (no long-lived `Cursor` struct spanning suspensions) and iterate
that list synchronously — the same shape the SQL drivers use.

## Artifacts

* Crash: `~/Library/Logs/DiagnosticReports/nova-2026-08-08-11*.ips` (+ the lldb transcript above).
* Repro boundary set: `scratchpad/repro{1..6}.nova` (all pass — they bound the problem).
* Live reproducer: `plancksystems/perf/compare/nova-mongo` (document-API store) against a seeded mongod.
