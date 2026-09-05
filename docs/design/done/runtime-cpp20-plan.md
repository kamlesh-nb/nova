# Kyte Async Runtime Plan — Asio + C++20 stackless coroutines (multi-core)

Status: **active plan** (supersedes the earlier stackful design). Scope: `lang/`
(compiler + runtime).

This document tracks the architecture, **what changed and why**, the **current
state**, and the **plan forward**.

---

## 1. Decision history — what changed and why

| When | Decision | Reason |
|---|---|---|
| Initial | Rewrite the fragile C runtime in C++20 | C runtime had data races, TLS-verify-off, leaks |
| Then | **Stackful** (Boost.Asio io_context + Boost.Context fibers) | Keep the `extern "C"` blocking ABI; leave codegen untouched |
| Mid-M3 | Detoured to **Boost.Fiber** (work-stealing) | Ready-made multi-threaded scheduler + fiber channels, race-free |
| **Now** | **Stackless C++20 coroutines + Asio, multi-core** | *Fastest* async model (no per-task stack, exact-sized elidable frames); Asio's reactor **is** the scheduler (Boost.Fiber left I/O unsolved); scales across cores via an io_context thread pool. Aligns with the "high-performance language" goal. |

**Why the reversal from stackful is accepted:** stackless coroutines are the
fastest and cleanest for an **I/O-centric** runtime, but they require the **Kyte
compiler to emit coroutine lowering** (Kyte compiles to LLVM IR, so Clang can't do
it for us). We are explicitly taking on that compiler work. The stackful path would
have left codegen untouched but is slower and bolts a second scheduler layer on top
of Asio.

**Boost.Fiber attempt:** preserved at `lang/src/runtime/concurrency_boost.cpp.wip`
(multi-threaded work-stealing + fiber channels). It links and runs synchronous
programs but had a flaky hang (default fiber stacks / thread-migration vs. the
thread-local arena — see §5). Kept as reference; not the chosen path.

---

## 2. Multi-core model (finalized)

- The scheduler is a single `asio::io_context`, **`run()` on N threads** (a thread
  pool sized to cores). Coroutines are distributed across all cores; different Kyte
  async tasks run truly in parallel.
- A single coroutine may **resume on a different thread** after each `co_await`
  (thread migration). Where ordering / shared-state serialization is needed, wrap in
  an **`asio::strand`** (lock-free "one handler at a time"). No global locks.
- Default: multi-core (io_context thread pool). Single-thread is just N=1.

---

## 3. Current state (what works today)

✅ **M3 v0 runtime is live and the build is restored — corpus 18/18 green.**
`lang/src/runtime/`:
- `kyte_abi.h` — frozen ABI (8-byte header, i64-pointer discipline, all ~104
  `extern "C"` symbols).
- `alloc.cpp` — ARC allocator, **arena-faithful** (arena is load-bearing: string
  ARC exemption depends on it — see §5).
- `core.cpp` — logging, time (`std::chrono`), test harness, coverage, exceptions,
  env, sync, atomics (`__atomic` builtins), crypto stub. Cross-platform (`#ifdef
  _WIN32` guards for `close`/`setenv`).
- `io.cpp` — file/dir via **`std::filesystem`** (portable); socket/TLS/process/
  watcher **stubs**.
- `concurrency.cpp` — **synchronous shim** (spawn runs inline; std channels; entry
  calls `__kyte_main`). Stable, corpus-green. This is the shipping default until the
  coroutine path is proven.
- Build: **prebuilt** into `~/.kyte/lib/libkyte_runtime.a` by `build.zig` (compile
  once; `kyte build` just links it — was 7s/build, now sub-second). `BOOST_PREFIX`
  configurable per platform. `main.zig` links `-lkyte_runtime -lboost_fiber
  -lboost_context` (Boost still linked for the .wip; will drop to Asio-only).

Cross-platform: runtime code is portable (std::filesystem/chrono, guards). Build
flags still hardcode `/opt/homebrew` (macOS); Windows/Linux need their Boost/prefix
wired (a build.zig follow-up).

---

## 4. The plan forward (coroutine workstream, sequenced)

Do these in order; keep the synchronous shim as the stable default throughout.

- ✅ **M0 — feasibility spike: PASSED (gate cleared).** Wired
  `LLVMRunPasses(module, "default<O0>"/"default<O3>", tm)` into the emit path
  (`declarations.zig`, before `LLVMTargetMachineEmitToFile`; guarded `!is_wasm`).
  The binding (`llvm.transform`) exposes `LLVMRunPasses`/`LLVMCreatePassBuilderOptions`.
  Verified: (1) the pipeline runs cleanly on real Kyte code — **corpus 18/18 still
  green**; (2) `"default<O0>"` **lowers coroutine intrinsics** — a hand-written coro
  `.ll` through `opt -passes='default<O0>'` split into `f.resume`/`f.destroy` and
  removed `llvm.coro.begin`. (3) A **complete coroutine program ran end-to-end**
  (create → suspend → `llvm.coro.resume` → continue): printed `observable=1` then
  `observable=2` after opt-lower + clang-link + run. **Residual CLOSED:** Kyte links
  `/opt/homebrew/opt/llvm/lib/libLLVM.dylib` **v21.1.7 — the same LLVM `opt` used**,
  so the toolchain lowers coroutines identically. Only workstream C (Kyte *codegen*
  emitting the intrinsics — mechanical `LLVMBuildCall` to declared coro intrinsics)
  and ARC-across-suspend remain; both are implementation, not feasibility risk.
- **A — arena / string cleanup. HALF DONE (alignment landed; arena-drop scoped).**
  - **Alignment: DONE + validated (corpus 18/18; string stress 11/11; json/yaml/
    datetime paths verified).** Converted all **22** string-construction sites (20
    from the inventory + 2 inline ones in data/btree/driver.ky) from the
    `bytes.alloc(4+len)` + `write_i32(ptr,0,len)` + `return (ptr+4) as string` idiom
    to `bytes.alloc(len)` + `return ptr as string`. This works because
    `kyte_bytes_alloc(len)` already writes the 8-byte ARC header (refcount @base+0,
    length @base+4) and returns base+8 — so heap strings now match string LITERALS
    (which were already `{refcount,length,data}` at base+8). Worst-case-buffer sites
    (json/yaml escapers, datetime, file.readText) set the length header explicitly
    via `write_i32(ptr-4, 0, actualLen)`. **Behaviorally inert while the arena
    stays** (arena objects are `is_in_arena` → ARC-exempt), which is why it's safe.
  - **Arena-drop: DONE (arena off by default; corpus 18/18 + all string/serde/
    async suites green).** `build.zig` now compiles the runtime with
    `-DKYTE_DROP_ARENA`, so `kyte_bytes_alloc` always mallocs a real refcounted
    object (`is_in_arena` → false → ARC active on every heap object). The
    use-after-free this unmasked (`split()`→`join()` = `"a-a"`) was a generic-
    container ARC gap: `List.push` stores the raw pointer (`write_ptr`) without
    retaining, and generic code can't ARC-manage its element type. **Fix — a
    codegen rule (`retainIfGenericStore`, arc.zig):** at a call site, retain a
    refcounted argument when the callee's parameter type is a *bare* generic type
    param (single uppercase, e.g. `List<T>.push(value: T)`). Generic code treats T
    opaquely and never retains/releases it (`isRefCountedType("T")` = false), so the
    caller-side retain transfers ownership to the container and it outlives the
    caller's local. Applied in all method-arg loops + the namespaced-call loop
    (llvm_codegen.zig). Container **elements leak on container drop** (generic
    destructors can't release T yet — needs reified generics / A2(d)); acceptable
    versus a crash, and no worse than the old arena (which never freed anything).
    Verified with arena off: corpus 18/18; string stress 11/11 (incl. split/join);
    List<string> push/get; Map<string,string> — *pre-existing* Map codegen bug
    (LLVM "Incorrect number of arguments", fails identically for `Map<i32,i32>`
    where the retain never fires → unrelated to A; tracked in the deferred backlog);
    json/yaml/datetime 8/8; **async + string held across `await` 6/6** (partial
    ARC-across-suspend now works for string locals). Struct-fields-with-strings were
    already fine (struct_init retains concrete refcounted fields).
    NOTE: the arena code stays behind `#ifdef` for now (easy A/B toggle); can be
    deleted once this soaks.
  - **Container/ARC reconcile (follow-up, DONE this round):**
    - **Map "bug" was misuse, not a codegen bug.** `Map<K,V>(initialCap, hashFn)`
      genuinely requires 2 args (there is no default key-hash); `Map<i32,i32>()`
      was invalid and produced an ill-formed `Map_init(self)` call that only failed
      at LLVM verification. Fixed by adding **constructor-arity checking** in the
      type checker (`structInitParamCount` + checks in `checkExpr` for both generic
      `Map<..>(..)` and non-generic `Foo(..)` construction) → now a clean
      `constructor 'Map' expects N argument(s), got M`. Locked with
      `conformance/expect_fail/constructor_arg_count.ky`. Correct usage
      (`Map<string,i32>(16, string.hash)`) verified 6/6. (Int-keyed maps/sets are
      usable via `i32Hash` in set.ky.)
    - **Stripped the pre-ARC element-free loop from `List.delete`.** It was legacy
      from the allocator + `defer delete()` era: it `bytes.free`'d each element by
      raw pointer, which under ARC ignores refcounts (breaks shared elements) and,
      for value-typed elements (`List<i32>`), freed an integer-as-pointer →
      heap corruption. Now `delete` frees only the list's own backing buffer;
      elements are ARC-managed. `List<i32>`/`List<string>` now drop cleanly (no
      crash). Map/Set/Array/StringBuilder `delete` were already clean (own-buffer
      only). Element release on container drop still awaits reified-generic
      destructors (A2(d)) — benign leak until then, no crashes.
- ✅ **B — language surface: DONE (corpus 18/18 green, fully additive).**
  `async fn` and `await <expr>` are in the lexer (`keyword_async`/`keyword_await`),
  AST (`FunctionDecl.is_async`; `Expression.await_expr: AwaitExpr{operand, span}`),
  parser (async fn at top-level + as methods; `await` prefix in `parseUnary`),
  and formatter. **Function coloring** lives in the type checker: an `in_async`
  flag set per `checkFunction`; `await` outside an `async fn` is a spanned error;
  `resolveExprType(await e)` == `resolveExprType(e)` (transparent). Codegen has an
  explicit guard that fails loudly (`error.AwaitCodegenNotImplemented`) until C.
  **Deliberately deferred to C:** wrapping an async call's result in `Future<T>`
  (async call → Future) — the representation is C's to decide, so full coloring of
  the *call* side waits for it. Today an async fn type-checks/compiles as an ordinary
  fn (its declared T flows straight through).
- **C — codegen coroutine lowering. SPIKE DONE (end-to-end through Kyte codegen,
  corpus 18/18 green).** An `async fn` now lowers to a real LLVM coroutine:
  - Validated the exact IR shape first by hand (`opt default<O0>` split it into
    ramp/resume/destroy; linked binary printed `res=42`) before wiring codegen.
  - Runtime: `kyte_coro_alloc/free` (kyte_abi.h + alloc.cpp, plain malloc/free —
    frames are NOT ARC objects).
  - Codegen decls: `setupCoroutineSupport` declares `llvm.coro.*` via the
    intrinsic-ID path (LLVM builds the token-typed signatures) + `kyte_coro_*`.
  - `FunctionInfo.is_async` threaded; async ramp returns i64 (the coroutine
    handle), marked `presplitcoroutine`.
  - Prologue (`emitCoroPrologue`): promise alloca + coro.id/size/`kyte_coro_alloc`/
    begin + initial suspend switch → body. Return value carried in the coroutine
    **promise** (no signature change beyond the handle).
  - `return e` in an async fn (statements.zig) stores e→promise and branches to the
    final suspend (via `current_async_promise`/`current_async_final_bb`).
  - Epilogue (`emitCoroEpilogue`): final suspend + trap + cleanup (`coro.free`→
    `kyte_coro_free`) + `coro.end` + `ret handle`.
  - Sync-context call (`buildDriveAsyncCall`): ramp→`coro.resume`→`coro.promise`
    load→`coro.destroy` (block-on-future). Verified: params, locals, arithmetic,
    nested async calls all correct.
  - **Real `await` suspension: DONE (corpus 18/18 green).** Validated the
    scheduler+waiter design in hand IR first (`outer` awaits `inner`, suspends,
    resumes → 11), then wired codegen:
    - Promise widened to `{ i64 result, i64 waiter }`. `waiter` = handle of a
      coroutine awaiting this one (0 = none); set 0 in the prologue.
    - `await inner()` (expressions.zig `buildAwait`): emit inner's ramp (handle, at
      initial suspend — NOT block-driven, via `awaitedCallHandle`); store self's
      handle into inner's `promise.waiter`; `kyte_sched_schedule(inner)`; emit a
      mid-body `coro.suspend` (switch → `await.resume` / suspend / cleanup); on
      resume read inner's `promise.result` and `coro.destroy` it.
    - Epilogue: on completion, if `promise.waiter != 0`, `kyte_sched_schedule(waiter)`
      before the final suspend.
    - Minimal scheduler: `kyte_sched_schedule`/`kyte_sched_next` (single-threaded
      FIFO in concurrency.cpp); `buildDriveAsyncCall` now schedules the root and
      pumps a `llvm.coro.done`/`resume` loop to completion.
    - Verified: mid-body suspension, **state preserved across await** (locals spilled
      to frame by CoroSplit), and **multi-level await** (chain→outer→inner). Needs a
      direct async-call operand for now (`await someAsyncFn(args)`).
  - **Still TODO in C:** (6) **ARC across suspends** — a refcounted value (string/
    object) live across an `await` must sit in the frame with balanced retain/
    release. Value types (i32/i64) already work; this is tied to workstream A
    (arena/string ARC-correctness). Also: `await` on non-direct-call Futures,
    and forbidding `async` under wasm at the type-check layer.
- **D — Asio runtime. IN PROGRESS (scheduler + timer awaitable DONE).**
  - **Enabler proven:** C++ can resume Kyte's LLVM coroutines directly via the
    switched-resume ABI — the frame's first two pointers are resume/destroy, a null
    resume pointer means done (verified against Kyte-compiled coroutines). So Asio
    completion handlers can drive coroutines even though `llvm.coro.resume` is a
    compiler-only intrinsic.
  - **D-step-1 (Asio io_context scheduler): DONE.** Replaced the M3-C FIFO with
    `boost::asio::io_context` (concurrency.cpp). `kyte_sched_schedule(h)` posts a
    resume handler; `kyte_run()` = `io_context.run()` + `restart()`. Codegen's
    `buildDriveAsyncCall` now emits `schedule(root) + kyte_run()` (no more codegen
    pump loop) then reads the promise + destroys. Corpus 19/19; async/await suite
    (outer/inner/chain/work) green.
  - **D-step-2 (timer awaitable): DONE.** `await sleep(ms)` lowers to a NON-blocking
    timer: `kyte_await_timer(self_handle, ms)` arms an `asio::steady_timer` that
    reschedules the coroutine when it fires, then the coroutine suspends
    (`buildAwaitSuspend`, shared with child-await). The thread is free meanwhile —
    `io_context.run()` blocks on the pending timer (which the FIFO couldn't model).
    Detected in `buildAwait` via `awaitSleepMillis` (callee named `sleep`, ident or
    `mod.sleep`). Verified: state preserved across timer suspend, two sequential
    sleeps, correct ~ms timing.
  - **D-step-3 (multi-core): DONE (infrastructure + race-free; parallelism payoff
    needs D-4 spawn to observe).** `kyte_run()` now drives `io_context.run()` on a
    pool of N threads (`KYTE_THREADS` env override, else `hardware_concurrency`
    capped at 16; join + `restart()` per top-level drive). Safe because the load-
    bearing thread-local arena is gone (workstream A) and ARC is atomic, so a
    coroutine may migrate cores across suspends. **Fixed a latent multi-thread
    use-after-free in the waiter mechanism:** previously the child scheduled its own
    waiter (parent) in its epilogue *before* the final suspend returned, so under
    real parallelism a parent could resume on another core and `coro.destroy` the
    child mid-epilogue. Redesigned: the waiter lives in a **runtime-side registry**
    (`kyte_register_waiter(child, parent)`, a mutex-guarded map), and the RUNTIME
    schedules the waiter *after* the child's resume fully returns
    (`kyte_sched_schedule` post-resume: `if done → take_waiter → schedule`). Codegen:
    `await child()` calls `kyte_register_waiter` before scheduling the child; the
    epilogue no longer schedules its own waiter. Check-vs-register and
    complete-vs-take are both under the registry mutex → no lost wakeups. Validated:
    async/await/timer suites green on KYTE_THREADS=1/4/8; corpus 19/19. NOTE: with no
    `spawn` yet, task trees are sequential (one runnable coroutine at a time), so the
    N threads don't yet run coroutines concurrently — real parallelism + a multi-
    thread ARC stress test arrive with D-4.
  - **D-step-4 (concurrent tasks — `go` + Future): DONE.** New keyword **`go
    <async-call>`** launches the call as a concurrent task and returns a Future
    handle (i64); it does NOT suspend the caller. (`spawn` was taken by the legacy
    `fiber.spawn`, so `go`, Go-style.) Threaded through lexer (`keyword_go`), AST
    (`go_expr: AwaitExpr`), parser (prefix in `parseUnary`), type checker (coloring:
    `go` only in async; type transparent), formatter, codegen (`buildGo`: ramp +
    `kyte_sched_schedule`, return handle). **`await <future>`**: `buildAwait` now
    falls through (when the operand isn't `sleep` or a direct async call) to
    `buildAwaitFuture` → `kyte_await_future(future, self)` which, **under the waiter-
    registry mutex**, atomically either reports the task already-done (return 1 →
    read result inline, no suspend) or registers the waiter (return 0 → suspend);
    closes the wait-registration race. **Verified:** `go`+concurrent `await` correct
    (ready path + suspend path); **concurrency is real** — 3×400ms tasks run
    concurrent (`go`) in ~1×400ms vs sequential (`await`) ~3×400ms; **multi-thread
    ARC stress** (5 concurrent tasks doing heap/string/refcount work) correct+stable
    on KYTE_THREADS=1/4/8 ×3 runs. Corpus 20/20 (added
    `conformance/cases/10_async_go.ky`).
  - ~~**NOTE — `test_fiber_execution` is a SEPARATE bug, NOT fixed by `go`.** It uses
    the legacy `fiber.spawn(() => void)` (closure, inline shim) + `Atomic<bool>` +
    closure capture; it fails with the arena on OR off and is unrelated to
    scheduling — a pre-existing atomic/closure-capture defect.~~
  - ✅ **RESOLVED 2026-07-17 — and there was never an "atomic/closure-capture defect".
    `test_fiber_execution` was MISATTRIBUTED: it was not failing, it was NEVER RUNNING.**
    The real bug was `kyte_atomic_cas_i32`, which discarded the result of
    `__atomic_compare_exchange_n` and returned `e` (the expected value, which the intrinsic
    overwrites with the *actual* value on failure). Codegen truncates that to i1, so callers
    got **the low bit of the expected value** — `compareAndSwap(22, 30)` succeeded and reported
    `false`, while the *failing* CAS also reported `false`, so `assert.isFalse` passed by
    accident and only success looked broken. It was correct iff the expected value was odd.
    That made `atomic.ky`'s own `test_atomic_i32` fail, and `kyte_test_fail` calls
    `std::_Exit(1)` — so the suite aborted there and `test_atomic_i64`, `test_atomic_bool` and
    `test_fiber_execution` never executed at all. `spawn`, closure capture and the arena were
    all innocent.
    **Why it survived:** (1) no conformance case imported `concurrency.atomic`, so every atomic
    op in the language was ungated; (2) the harness never printed WHICH test failed (the
    generated `FAIL <name>` branch is dead code past `_Exit`), so an abort in one module read
    as a failure in another. Both fixed: `kyte_test_begin` now names the running test, and
    `conformance/cases/31_atomics.ky` gates all of it (shown to fail before the fix).
    Also fixed alongside: `kyte_atomic_cas_i64` declared `int32_t desired` while codegen passes
    i64 — silently truncating any desired value above 2^31.
    *Same shape as "string heap corruption" (a `func_map` suffix-scan bug misfiled for months):
    **an instrument that cannot name the failure will misname it, and the wrong name sticks.***
  - **D-step-5 (sockets + wolfSSL TLS): DONE — real HTTPS with verify_peer works.**
    Implemented the `kyte_socket_*` + `kyte_tls_*` ABI (io.cpp), replacing the stubs:
    - **Sockets:** blocking POSIX (`getaddrinfo`/`socket`/`connect`/`bind`/`listen`/
      `accept`/`send`/`recv`), cross-platform (`#ifdef _WIN32` Winsock + `WSAStartup`;
      `kyte_close_fd`). `send` uses the Kyte string length (`s-4`), binary-safe.
    - **TLS via wolfSSL** (`#ifdef KYTE_HAVE_WOLFSSL`): `kyte_tls_new` builds a client
      `WOLFSSL_CTX`, sets `WOLFSSL_VERIFY_PEER`, `wolfSSL_CTX_load_system_CA_certs`,
      `wolfSSL_set_fd(fd)`, SNI + `wolfSSL_check_domain_name(hostname)`; handshake =
      `wolfSSL_connect`; read/write = `wolfSSL_read/write`. **Fail-closed** (no
      verify-off). Without wolfSSL the TLS fns stay stubbed (sockets still work).
    - **Build wiring:** build.zig builds the vendored wolfSSL static lib if missing
      (cmake) and compiles the runtime with `-DKYTE_HAVE_WOLFSSL -Ideps/wolfssl
      -Ideps/wolfssl/build`; main.zig links `libwolfssl.a` (+ macOS Security/
      CoreFoundation frameworks) via `appendWolfsslLink`, guarded on the .a existing
      (kept in sync with the compile define). **Unity-build fix:** include
      concurrency.cpp (Asio) BEFORE io.cpp (wolfSSL) in runtime.cpp — wolfSSL's
      options.h otherwise pollutes a macro Asio's platform detection needs.
    - **VERIFIED against real network:** GET example.com:443 → handshake=0 (cert +
      hostname verified) → `HTTP/1.1 200 OK` (864 bytes). Fail-closed proven:
      self-signed.badssl.com and wrong.host.badssl.com handshakes both REJECTED.
      Corpus 20/20. NOTE: sockets/TLS are BLOCKING (a `recv` holds a pool thread) —
      correct + usable now; non-blocking async socket I/O (suspend on would-block,
      cooperating with coroutines) is a later refinement. Cross-platform CA: macOS
      uses `load_system_CA_certs` (Apple store); Windows/Linux load their system
      store too, with an explicit CA-bundle fallback still available if needed.
  - **D-step-6 (channels + async socket I/O + cleanup): DONE — workstream D COMPLETE.**
    - **Async channels** (concurrency/asyncchan.ky free-fn API): `chanNew/chanSend/
      chanRecv/chanFree` over `kyte_chan_*`. `recv` is awaitable — `await chanRecv(ch)`
      lowers (buildChanRecv) to a park+retry loop: `kyte_chan_recv` under a mutex
      either dequeues (status 1) or parks the coroutine (status 0); `chanSend` wakes
      one parked receiver. Verified producer/consumer via `go`. (i32 values; generic
      element types are a follow-on. Kept in a standalone module to dodge channel.ky's
      pre-existing transitive `fiber` import error.)
    - **Non-blocking async socket I/O** (net/asyncio.ky): `await socketRecvAsync(fd,
      buf,max)` / `socketAcceptAsync(fd)` offload the blocking op to a dedicated
      `asio::thread_pool(64)` so no coroutine-scheduler thread is held; the coroutine
      parks and the worker stashes the result (runtime registry) + reschedules it
      (buildAsyncIo → offload + buildAwaitSuspend + kyte_io_take_result). Verified:
      real HTTP GET with offloaded recv → `HTTP/` response. (Thread-per-op pool;
      true asio non-blocking sockets for massive fan-in is a later refinement.)
    - **Dropped** the dead `-lboost_fiber -lboost_context` link flags (Asio is
      header-only; the Boost.Fiber attempt is `.wip`, not compiled).
    - **Fixed an exit crash** (`mutex lock failed`): the io_context/thread_pool/mutex
      globals are now intentionally LEAKED (references to heap objects, never
      destructed) so no static-destruction-order fiasco when background threads touch
      them during teardown.
    - Corpus 21/21 (added `conformance/cases/11_channels.ky`).
  - **STILL open (outside D):** ~~the separate `test_fiber_execution` atomic/closure bug~~
    ✅ **RESOLVED 2026-07-17 — it was `kyte_atomic_cas_i32` returning the expected value
    instead of the success flag; the fiber test was never running (see D-4's note).**
    Generic channel/container element types + reified-generic destructors (A2(d)); true asio
    non-blocking sockets (vs the current offload) for very high connection counts.
    **Also open and newly recorded:** `kyte_chan_new` ignores its `capacity` argument
    (`(void)capacity; // unbounded for now`) and offers no non-blocking `try_send` — both are
    hard prerequisites for the SSE event bus (`beta-readiness-plan.md` §R3, P3-20).
  - **TLS DECISION: wolfSSL, NOT asio::ssl/OpenSSL** (matches CLAUDE.md "wolfSSL
    integrated with Asio"). The whole TLS surface is already behind a 5-function C
    ABI — `kyte_tls_new/handshake/write/read/free` (io.cpp, currently stubs) — so
    this is a runtime-impl choice, no codegen/stdlib impact. `asio::ssl` is hard-
    wired to OpenSSL, so we use **path B: wolfSSL's native API directly over
    `asio::ip::tcp`** — Asio owns the async socket, wolfSSL owns the TLS record layer
    via custom I/O callbacks (`wolfSSL_CTXSetIORecv/Send`). `verify_peer` =
    `wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, NULL)` + CA loading (closes the
    disabled-cert-verification hole). **VENDORED + PROVEN:** wolfSSL cloned into
    `deps/wolfssl` (clean, no .git; ~141M, same pattern as deps/mbedtls), built
    static via cmake (`-DBUILD_SHARED_LIBS=OFF -DWOLFSSL_TLS13=yes
    -DWOLFSSL_EXAMPLES=no -DWOLFSSL_CRYPT_TESTS=no -DWOLFSSL_OPENSSLEXTRA=no`) →
    `deps/wolfssl/build/libwolfssl.a`. A TLS 1.3 client ctx + verify_peer link test
    passed. Include: `-Ideps/wolfssl -Ideps/wolfssl/build` (generated options.h in
    build/wolfssl/options.h; must be included BEFORE ssl.h). Link: `libwolfssl.a`
    plus, **on macOS**, `-framework Security -framework CoreFoundation` (Apple native
    cert validation). CROSS-PLATFORM (Windows requirement): the Apple-framework dep
    is macOS-only — for Windows/Linux either configure per-platform cert validation
    or, more portably, load an explicit CA bundle via
    `wolfSSL_CTX_load_verify_locations(ca-certs.pem)` instead of platform-native
    stores. Wire the wolfSSL build + link into build.zig at D-step-5. NOTE: `concurrency.fiber`'s `test_fiber_execution`
    (legacy `spawn` + `Atomic<bool>` + closure capture) FAILS — PRE-EXISTING (fails
    with arena on OR off; `spawn` is the unchanged inline shim, unrelated to async/
    await); will be resolved when `spawn` becomes Asio-backed.
    BUILD CAVEAT: `zig build` doesn't always re-run the opaque runtime-compile system
    command on concurrency.cpp-only edits — if a runtime change seems absent,
    force-rebuild: `clang++ -std=c++20 -O2 -pthread -DKYTE_DROP_ARENA -c
    -I/opt/homebrew/include src/runtime/runtime.cpp -o ~/.kyte/lib/kyte_runtime.o &&
    ar rcs ~/.kyte/lib/libkyte_runtime.a ~/.kyte/lib/kyte_runtime.o`.
- **E — build/cross-platform.** Make `build.zig` discover Boost/Asio per platform
  (or vendor standalone Asio, which is header-only), and wire the Windows/Linux link
  flags (currently macOS-hardcoded).

### New ABI symbols (added to kyte_abi.h when C lands)
`kyte_coro_alloc(i64)->i64`, `kyte_coro_free(i64)`, `kyte_coro_resume(i64)`,
`kyte_coro_schedule(i64)`, `kyte_await_timer/channel/socket_*`, `kyte_spawn_task`,
`kyte_future_await`. The existing blocking `kyte_channel_*`/`kyte_concurrency_*`
stay for non-async code / the synchronous shim.

---

## 5. Open issues / risks (tracked)

- **Arena is load-bearing** (blocks multi-threaded async): `string.ky`'s
  `allocString` returns `ptr+4`, so a string's ARC header is misaligned; the C
  runtime relied on **arena objects being refcount-exempt** so ARC never touched
  them. Fix = make strings ARC-correct (workstream A) → then the arena is optional.
- **M0 unknown**: whether the kassane/llvm-zig binding exposes `LLVMRunPasses`/
  `LLVMPassBuilderOptions`. De-risk first.
- **Map crash on ~60+ inserts** (pre-existing, NOT the allocator; same "abnormal
  termination" as `arena_allocator` + all-module import) — separate investigation,
  possibly related to the arena/string representation.
- **WASM + async**: WASM target is runtime-free; `async` has no scheduler there —
  forbid `async` under wasm or back awaitables with host imports.
- **Cross-platform build flags** currently macOS-hardcoded (`/opt/homebrew`).

---

## 6. Pending — pick up tomorrow (2026-07-14 handoff)

Focus for tomorrow (user): **refine the web framework + HTTP server/client** and test
the async server under load. Everything below is open.

### 6.1 ✅ FIXED — concurrent HTTP server responses (was: multi-thread strand bug)
**Root cause (found via research, not trial-and-error):** the server was correct
single-threaded (KYTE_THREADS=1 → 100/100 concurrent), but multi-threaded it
corrupted (KYTE_THREADS=4 → ~19/100; =8 → ~4/100). A raw Python concurrent client
proved the server side was fine and **curl was a red herring** (the shell harness
spawning dozens of background curl procs). The real bug: **no Asio strand** — a single
`tcp::socket`'s async ops ran across different io_context threads without
serialization, corrupting Asio's per-socket internal state (Beast/Asio thread-safety
rule: one strand per socket).
**Fix:** a **per-coroutine strand** in `CoroState` (`make_strand(g_io)`);
`kyte_sched_schedule` posts resumes onto `state->strand`, and `kyte_arecv`/`kyte_asend`/
`kyte_aaccept` `bind_executor(state->strand, ...)` their completions. Each connection
= one coroutine = one socket, so a per-coroutine strand serializes that socket's ops
across threads. **Verified:** 100/100 and 500/500 concurrent at KYTE_THREADS=1/4/8
(~7500 req/s, Python-client-bound); corpus 21/21; async/channel/timer suites green at
KYTE_THREADS=8. (Superseded the notes below — the RST/close theories were wrong; a bare
graceful `shutdown(send)`+close is fine once ops are strand-serialized.)

### 6.2 ✅ FIXED — fire-and-forget `go` leak
`go <call>;` used as a STATEMENT (result discarded) now lowers to
`kyte_sched_schedule_detached`, which self-destroys the coroutine frame on completion
(codegen: statements.zig expr_stmt → `buildGo(...,true)`; `let h = go ...` stays
awaitable via `buildGo(...,false)`). Runtime `CoroState.is_detached` drives the
self-destroy. **Verified leak-free:** a `go handle(client);` server holds flat RSS
(~6.3 MB) across 6000+ requests. (Caveat: a handler's `bytes.alloc(buf)` is a raw i32-
typed buffer, NOT ARC-managed, so it must be `bytes.free`d explicitly — the web
framework should own that buffer's lifecycle. Was the only per-request growth.)

### 6.1-OLD (superseded theories, kept for history) — concurrent HTTP server responses
The scalable async server (D-7: `net/asyncio.ky` `serverListen`/`aaccept`/`arecv`/
`asend`/`aclose` over true asio `async_accept`/`async_read_some`/`async_write`) is
**built and the server side is proven correct** — an instrumented run showed all N
connections **accepted** and all handlers ran fully (`H-start`/`H-recv`/`H-sent`).
Sequential requests: **5/5 pass**. But **concurrent** requests only deliver the
response to ~1/N clients.
- Diagnosis so far: the *server* handles every connection; the *response* doesn't
  reach concurrent clients. Classic cause = `close()` on a socket with unread
  request bytes sends a **RST**, discarding the queued response. Added a graceful
  `shutdown(send)` before `close` in `kyte_aclose` (concurrency.cpp) — **did NOT fix
  it** (still 1/50). So the cause is something else or additional.
- Next hypotheses to check: (a) `async_write` completes but data isn't actually
  flushed before teardown under concurrency; (b) the `arecv` reads only a partial
  request (async_read_some), leaving unread bytes → RST despite shutdown(send);
  (c) a race in the per-coroutine result registry (`g_ioresults` keyed by handle)
  when many handlers resume at once; (d) test-harness artifact (unlikely — server
  trace proved 8/8 sent, only client delivery failed). Reproduce:
  build a native server binary (`kyte server.ky --native -o server`), run it,
  fire N concurrent `curl` (wait on explicit curl PIDs, NOT bare `wait` — that also
  waits on the forever-running server). Instrument by logging in `handle`.
- Likely real fix: read the FULL HTTP request (until `\r\n\r\n`) before responding,
  and/or verify the write fully drains; consider `SO_LINGER`/half-close ordering.

### 6.2 Fire-and-forget `go` task leak (needed for a long-running server)
`go handle(conn)` with no `await` never destroys the coroutine frame → **one frame
leaked per connection**. A server can't leak per request. Need a detached-task model:
a `go` task with no waiter should self-destroy on completion. Careful: the block-drive
root also has no waiter but its promise is read after `kyte_run` — must distinguish
"detached go task" from "block-driven root" (e.g. a detached flag, or the root uses a
distinct drive path). Runtime hook point: `kyte_sched_schedule` post-resume, where
`take_waiter(handle)==0` today.

### 6.3 Web framework / HTTP layer refinement (user's main task)
- Build the HTTP server/client on top of the async sockets (parse request line +
  headers + body; build responses; routing). `src/std/web/` has server/client/router/
  middleware scaffolding (ASP.NET-style) that predates the async runtime — reconcile
  it with `go`/`await`/async sockets.
- `app.ky` template (`kyte init app`) improvements (user flagged it as "different
  than what it is").

### 6.4 Async I/O polish — PARTIALLY DONE
- ✅ **Async client connect (`aconnect`) DONE.** `await aconnect(host, port)` → socket
  handle (0 on failure): async resolve + `async_connect` on the coroutine's strand
  (net/asyncio.ky + `kyte_aconnect`). Verified: async client fetched example.com:80
  (`aconnect`→`asend`→`arecv`) 5/5. So the full async socket set — accept/connect/
  recv/send/close — is complete and strand-safe.
- ⏳ **TLS-over-async server** still TODO: `kyte_tls_*` is blocking wolfSSL over a raw
  fd (fine for the client). An async TLS server/client needs wolfSSL driven over the
  asio socket via its I/O callbacks (`wolfSSL_CTXSetIORecv/Send` returning WANT_READ/
  WRITE + coroutine suspend).
- ⏳ Offload path (`socketRecvAsync`/`socketAcceptAsync`, thread-per-op) is superseded
  by the true-async path for servers — decide whether to keep it for blocking-fd use.

### 6.4-OLD Async I/O polish
- Currently BOTH exist: D-6 offload path (`socketRecvAsync`/`socketAcceptAsync`, raw
  fd, thread-per-op via `g_io_pool(64)`) AND D-7 true-async path (`arecv`/`aaccept`/
  `asend`, asio sockets, event-driven). The offload path is superseded for servers by
  D-7 — decide whether to keep it (client-side blocking-fd offload) or drop it.
- `asend` currently sends a Kyte string (length at s-4). Add async connect
  (`aconnect(host,port)` for a scalable client) if the web *client* needs it.
- TLS-over-async: `kyte_tls_*` is blocking wolfSSL over a raw fd; a TLS *server*
  needs wolfSSL driven over the asio socket (I/O callbacks) — not yet done.

### 6.5 Generics: channel/container element types + ARC (A2(d))
- Async channels carry **i32** only (`kyte_chan_*` + asyncchan.ky). Generalize to
  any T (strings/objects) — needs the uniform-rep + retain-on-send.
- Container elements (List/Map/Set) still **leak on drop** — the ARC-correct fix is
  reified-generic destructors (store a per-instance element destructor set at
  construction). Same mechanism would let channels/containers hold refcounted T.

### 6.6 Smaller open items
- ✅ **`test_fiber_execution` — RESOLVED 2026-07-17, and it was never a fiber/closure/atomic-capture
  bug.** It was **not failing; it was never running.** `kyte_atomic_cas_i32` returned the expected
  value instead of the success flag (codegen truncates to i1 → the caller got the low bit of the
  *expected* value, so CAS reported success only when that value was odd). That made
  `atomic.ky`'s `test_atomic_i32` fail, and `kyte_test_fail` `_Exit(1)`s — aborting the suite
  before `test_atomic_i64`, `test_atomic_bool` and `test_fiber_execution` ever ran. `spawn`, closure
  capture and the arena were all innocent. Now gated by `conformance/cases/31_atomics.ky` (shown
  to fail before the fix), and the harness names the failing test (`kyte_test_begin`). Fixed
  alongside: `kyte_atomic_cas_i64` declared `int32_t desired` while codegen passes i64.
  **The lesson, for the next entry in this list: "X fails" was an inference from an unnamed abort,
  and it was wrong for months. Confirm WHICH test failed before writing down WHY.**
- **`channel.ky`** still has a transitive `Identifier 'fiber' not found` when imported (why
  asyncchan is a separate module). Unrelated to the above; still open.
- ⚠️ **`kyte_chan_new` ignores its capacity** — `(void)capacity; // unbounded for now` — and there is
  no non-blocking `try_send`. Both are hard prerequisites for the SSE event bus, whose entire design
  rests on a bounded queue with a non-blocking put (drop/disconnect a slow subscriber rather than
  block the publisher). See `beta-readiness-plan.md` §R3 and P3-20.
- **Test-path string helpers** (main.zig ~899–957) still use the pre-workstream-A
  misaligned `+4` idiom (corpus green, but inconsistent). Native-path helpers were
  fixed today (native build now works). Align the test-path ones too.
- **wolfSSL cross-platform CA**: macOS uses Apple's store (Security/CoreFoundation
  frameworks); Windows/Linux need `wolfSSL_CTX_load_system_CA_certs` verified or an
  explicit CA-bundle fallback (`wolfSSL_CTX_load_verify_locations`).
- **build.zig reliability**: `zig build` doesn't reliably re-run the opaque runtime-
  compile system command on `concurrency.cpp`-only edits. Force-rebuild:
  `clang++ -std=c++20 -O2 -pthread -DKYTE_DROP_ARENA -DKYTE_HAVE_WOLFSSL
  -Ideps/wolfssl -Ideps/wolfssl/build -c -I/opt/homebrew/include
  src/runtime/runtime.cpp -o ~/.kyte/lib/kyte_runtime.o && ar rcs
  ~/.kyte/lib/libkyte_runtime.a ~/.kyte/lib/kyte_runtime.o`. Consider making the
  runtime a tracked build step so it rebuilds on source change.
- **Deferred backlog**: A6 Hash/Eq eqFn; delete the arena `#ifdef` in alloc.cpp once
  the arena-off model has soaked; forbid `async`/`go` under the wasm target.
