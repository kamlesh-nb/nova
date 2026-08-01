# CLAUDE.md — Nova Language (compiler + runtime + stdlib)

## What this is

**Nova** is a statically-typed, ES6/TypeScript-flavoured language for server-side services, hypermedia
apps, and WebAssembly. This repo is the **language implementation**:

- **Compiler** — written in **Zig 0.16**, lowers Nova → **LLVM IR** → native object → linked binary
  (in-process LLD or `clang++`). WASM target via `wasm-ld`.
- **Runtime** — **C++20** (`src/runtime/`), on **Boost.Asio** with C++20 coroutines: a real async
  scheduler (io_context + per-coroutine strands), non-blocking sockets, TLS via **wolfSSL** (memory-BIO
  pumped by Nova async — crypto stays in wolfSSL), channels, actors.
- **Standard library** — written in **Nova itself** (`src/std/`): collections, string, json/yaml/bson,
  http/web framework, sql/db drivers, crypto, concurrency, regex, decimal128.

## Build / run / test

```bash
cd lang
zig build                       # builds `nova`, installs to ~/.nova/bin/nova, syncs std+runtime+deps to ~/.nova
NOVA_ASAN=1 zig build           # ALSO builds libnova_runtime_asan.a (needed for the ASAN gate)

nova <file.nova> -o out         # compile a single file to a native binary
nova test <file.nova>           # run @test functions
nova build [--release]          # project build → build/<profile>/{obj,bin} (reads project.json)
nova init web|desktop --name X  # scaffold an app

conformance/run.sh              # the corpus — run BEFORE and AFTER any change (currently 148/148)
conformance/run.sh -j           # SAME corpus, run in parallel (cores-1 workers) — ~5x faster (~2min vs >10min)
conformance/run.sh --asan       # AddressSanitizer gate (catches UAF/double-free; 266/266). Requires NOVA_ASAN=1 build first.
conformance/run.sh --arc        # ARC leak gate (baseline-gated)
NOVA_ARC_AUDIT=1 nova test f    # per-run ARC audit ("ARC audit: clean" or survivors)
```

### Running the corpus in parallel (`-j`)

The default `conformance/run.sh` is sequential (~10 min, and the reactor cases push it longer). `-j`
runs the same positive corpus across `cores-1` workers (~2 min); `-j N` sets the worker count. It applies
ONLY to the plain `nova test` run — the `--asan` / `--arc` / `--wasm` modes stay sequential (baseline-gated,
order-sensitive), and the harness self-test + `expect_fail` gates run after, unchanged.

How it stays correct in parallel — two things had to be handled:
- **`nova test` writes a hardcoded `__nova_test` output file**, so parallel instances would clobber each
  other → each worker runs the case in its OWN temp dir (with `packages/` symlinked in so most
  driver-importing cases still resolve). This is why concurrent runs were "banned" — it was fixable.
- **Per-case timeout** via coreutils `timeout`/`gtimeout`, else a `perl` `alarm` (stock macOS has no
  `timeout`), so a case that waits on a live service can't stall the batch.

Known limitation: a case that links a package's **native** lib (the `mysql`/`mssql`/`pg` DB drivers,
`67/100/109/110`) links it relative to the repo root, so under `-j` it **fails fast** in the temp dir
(link error) and `-j` exits non-zero. Those few are environment-dependent anyway (some need a live DB) —
verify them with the plain sequential `run.sh`. Everything else is authoritative under `-j`.

## Working on Windows — read this first if the repo is cloned on a Windows host

**Native `zig build` on a Windows host now works, and the runtime is run-verified there** — see the
status section below for the exact invocation, what was implemented, and what is still open. Both of
the original blockers are gone: the install step no longer needs `sh`/`rsync` (there is a PowerShell
branch), and the compiler links the LLVM **C API** dynamically instead of needing a Windows-host
static-LLVM dist.

**WSL2 (Ubuntu) remains a fine path too**, and is still the way to exercise the Linux gates. Clone
the repo *inside* WSL, install **Zig 0.16**, and use the normal Linux flow. (Before cloning,
`git config --global core.autocrlf input` so the bash scripts and `.nova` sources keep LF.) Note that
`-Dstatic-llvm` currently 404s on the mirror, so point `NOVA_LLVM_PREFIX` at a system LLVM instead.

**Cross-compilation still works and is unchanged.** From macOS / Linux / WSL,
`nova app.nova --target windows-x86_64` produces a real **PE32+ .exe** (adds
`-lws2_32 -lmswsock -lbcrypt`). What changed is that Windows is no longer *only* a cross-target:
execution — including the async reactor — is now exercised on a real host.

### Windows host status — native dev + runtime, as of 2026-07-31

A Windows 10 host is now in the loop, and the port is **run-verified**, not just compile-verified.
Corpus on Windows: see `conformance/windows-baseline.txt`.

**Native `zig build` on a Windows host works.** Requirements: Zig 0.16, and an LLVM install with
`LLVM-C.dll` + `LLVM-C.lib` (LLVM 21 verified) pointed at by `NOVA_LLVM_PREFIX`, with its `bin/` on
PATH for `clang++`/`llvm-ar`:

```powershell
$env:NOVA_LLVM_PREFIX = 'C:/LLVM'; $env:PATH = 'C:\LLVM\bin;' + $env:PATH; zig build
```

`C:\LLVM\bin` must be on PATH at **RUN** time too, not only to build: the produced `nova.exe`
links `LLVM-C.dll` dynamically. Without it EVERY corpus case reports `<compile/link error>` and
the harness declares its own negative-case classifier broken — which reads exactly like a compiler
regression. The tell is `nova.exe` exiting `0xC0000135` (STATUS_DLL_NOT_FOUND) with no output.

Both original blockers are resolved: `build.zig` has a PowerShell install step (no sh/rsync), and
the dynamic path links the LLVM **C API** rather than needing a static Windows LLVM dist. Two
Windows-specific traps are handled and worth knowing about:
- The LLVM.org Windows `LLVM-C.dll` ships a REDUCED target set (AArch64, ARM, BPF, NVPTX, RISCV,
  WebAssembly, X86). Referencing an absent `LLVMInitialize<T>*` is a hard link error, not a runtime
  no-op — `deps/llvm-zig/src/target.zig` filters the aggregate initializers to what is present.
- The link path drives MSVC's `link.exe`: `/OPT:REF` not `--gc-sections`, the runtime's COFF object
  not `-lnova_runtime` (link.exe cannot read llvm-ar's GNU archive), `-rtlib=compiler-rt` for the
  128-bit helpers, and `-lc`/`-lm`/`-lpthread` dropped (MSVC folds them into its CRT).

**Windows syscalls are Nova over Win32 FFI**, mirroring how `os/socket_windows` sits over
`os/winsock` — not C++ shims in the runtime. The target-conditional file rule (`targetSuffixedPath`)
swaps the whole module, so shared callers are unchanged:
- `os/winfs` + `os/sys_windows` — file/dir/env. MSVC's UCRT has no `<dirent.h>`, its `O_CREAT`/
  `O_TRUNC` are NOT the macOS values `os/sys` declares, its `struct stat` puts `st_mode` elsewhere,
  and `setenv` is absent — so this is a real reimplementation, not a thin alias.
- `os/winproc` + `std/process_windows` — spawn/stdio/wait/kill over CreateProcessW + pipes.
- IOCP reactor: `nova_run_root` in `concurrency.cpp` has a Windows branch (it was kqueue-only, so
  EVERY async program aborted with "no reactor driver" — note this still applies to **Linux**).

Things that bite, recorded so they are not rediscovered:
- **WSAStartup**: POSIX has no init step so callers do not make one. `os/sys_windows.socket` and
  `socket_windows.getAddrInfo` initialise Winsock themselves; without that, `bind` and hostname
  resolution fail while a numeric address appears to work.
- **Timers**: IOCP has no `EVFILT_TIMER` equivalent. Deadlines use a one-shot timer-queue timer whose
  callback only `PostQueuedCompletionStatus`es, so the fire arrives as a completion and BOTH drivers
  (the C loop and the Nova-side `Poller`) see it. A thread-local list only serves the former.
- **Association**: a socket must be `CreateIoCompletionPort`'d before its first overlapped op or the
  completion is delivered nowhere and the op silently never finishes.
- **ConnectEx** is the one piece that is NOT pure FFI, unavoidably: `AcceptEx` is a real mswsock.lib
  export and binds by name, but ConnectEx is only reachable through
  `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` as a runtime pointer, and Nova FFI binds named
  symbols only. `nova_wsa_connectex` (`io.cpp`) does that one resolution + indirect call.
- `nova_run_reactors` did **not** need a Windows-threads path — it already uses `std::thread`.
- `/tmp` is not a path on Windows (Win32 resolves a leading `/` against the current drive root); use
  `dir.Dir.tempDir()`.

**Still open on Windows:**
1. **Readiness cases 192/194/195** — `armRead`/`armWrite` have no IOCP analogue (a proactor has no
   "tell me when readable"). These need converting to the completion API, which the design notes
   already plan; the draining half (`waitReady`/`ev*`) is implemented and shares the completion path.
2. **`--asan` / `--arc` gates** are not wired on Windows (the install step skips those runtimes).
3. **Linux still aborts in `nova_run_root`** — it needs the epoll driver, exactly as Windows needed
   the IOCP one. Same shape; `NOVA_HAVE_IOCP` is the template.

## Layout

- `src/` — lexer, parser, `type_checker.zig`, **`sema/`** (infer/mono/ownership/lower/symbols — the
  authoritative typed-IR pass), **`codegen/`** (`llvm_codegen.zig`, `declarations.zig`, `expressions.zig`,
  `statements.zig`, `arc.zig`, `types.zig`), `main.zig` (driver + linking).
- `src/std/` — the Nova standard library (compiled from source per build; import-graph gated).
- `src/runtime/` — the C++20 runtime (`concurrency.cpp` = scheduler + async I/O, `io.cpp` = TLS memory-BIO).
- `conformance/` — `cases/*.nova` (positive, run via `nova test`) + `expect_fail/` (must be rejected) +
  `run.sh` (the harness, self-tests its own negative-case classifier).
- `docs/design/` — **`execution-plan.md`** (the master status table + per-item design — READ THIS for
  roadmap state), plus per-feature specs. `docs/specs.md` is the language spec.
- `packages/nova-*` — the concrete DB drivers (postgres/mysql/mssql/btreedb/mongodb); the `db` seam +
  generic pool stay in std.

## Core concepts (how it actually works)

- **ARC** — automatic reference counting, decided in codegen/sema (not a GC). Every heap object has an
  8-byte header (refcount @-8, length @-4). `nova_retain`/`nova_release(ptr, dtor)`. **Verify memory
  changes with `--asan`, NOT just `--arc`** — the ARC audit misses use-after-frees that ASAN catches.
- **Monomorphization** — generics are instantiated (`List<int>` → `List_int_*`), NOT type-erased. Mono is
  mandatory. An erased body is a link-time fallback with `internal` linkage that globalDCE drops.
- **Traits** — dynamic dispatch via fat pointers `{struct_ptr, vtable}`; vtable slot 0 is the destructor.
  Generic trait objects (`Beh<M>`) erase the arg for dispatch (shared base-name vtable `_vtable_S_Trait`).
- **async** — LLVM coroutines (presplitcoroutine → CoroSplit → `.resume`/`.destroy`), `spawn` (fork,
  returns a `future<T>`) + `await` (join). `when_all`/`selectAny` combinators. A **generic async method
  is only spawnable from a CONCRETE instantiation**, not an erased-M context.
- **Module scoping** — same-named structs across modules coexist (module-unique names).

## Gotchas (bitten before)

- **`int` is 32-bit, `long` is 64-bit.** Heap ADDRESSES must be `long`/`ptr` — `intAddr + offset`
  TRUNCATES to 32 bits (LLVM `trunc i64→i32`) → garbage pointer → SIGSEGV. Address-dependent, so it fakes
  a heisenbug. `bytes.read_byte`/`write_byte` compute the offset internally at i64 (safe), but explicit
  `buf + off` in Nova needs `buf: long`.
- **Env vars: `init.environ_map.get("VAR")`** — NOT `std.c.getenv` / `std.posix.getenv` (neither works in
  this Zig). `std.StringArrayHashMap` is absent → use `std.StringHashMap`.
- **Spec-first**: check/update `docs/specs.md` before adding a language feature.
- **Never `git reset`** in this repo (git stash is fine). `zig build` recovers `build.zig` from its cache.
- **`nova test` skips `main()`** and runs imported `@test`s — a source of measurement traps; use
  `NOVA_ARC_DUMP`/`NOVA_ARC_AUDIT` to see survivors.
- Debug output: `NOVA_DUMP_MERGED=1` writes the merged IR; `NOVA_SEMA_SHADOW=1` diffs the type engines.

## Reactor backends — status, corpus, and measured throughput

Four backends now exist, selected per target (and, on Linux, per run):

| Backend | Target | Model | Selected by |
|---|---|---|---|
| kqueue | macOS/BSD | readiness | `platform.os == "darwin"` |
| epoll | Linux | readiness | default on Linux |
| io_uring | Linux | **completion** (proactor) | `NOVA_REACTOR=uring` + a runtime probe |
| IOCP | Windows | **completion** (proactor) | `platform.os == "windows"` |

Linux has TWO backends and the target-conditional file rule selects by OS, so it cannot choose
between them: `nova_reactor_backend()` decides once per process. The probe matters — the uapi header
being present says nothing about the running kernel, which can be too old or have io_uring disabled
administratively (`/proc/sys/kernel/io_uring_disabled`).

### Conformance (234 cases, run 2026-08-01)

| Backend | Passed | Failed |
|---|---|---|
| Windows / IOCP | **224** | 10 |
| Linux / epoll | **225** | 9 |
| Linux / io_uring | **225** | 9 |

epoll and io_uring have IDENTICAL failure lists — every reachable case passes on both.

Run the corpora ONE AT A TIME. Running two concurrently on a 4-core box starves the app/server cases
past the per-case timeout and invents phantom failures (they report a timeout, which is how to
recognise it). `conformance/run.sh -j` fixed the per-case output collision that used to make this
unavoidable, but it does NOT make a genuinely MULTI-THREADED case safe: `195_multicore_reactors`
spawns its own reactor threads and intermittently times out under `-j` on a 4-core box while passing
cleanly on its own. Re-check any `-j` failure sequentially before believing it.

Every remaining failure is structural, not a bug to chase:
- **8 DB/codec cases** (`64/65/66/67`, `100/105/107/109/110`) import the drivers from `packages/`,
  which is NOT tracked in this repo — they live in separate repos. They cannot pass from a bare
  clone on any platform.
- **`188_kqueue_readiness`** asserts kqueue struct layouts (fails off macOS) and
  **`189_epoll_event_layout`** asserts epoll's (fails off Linux). Inapplicable by design.
(`210_cross_reactor_wakeup` was an io_uring-only failure and is fixed — see the SQE note below.)

### Throughput (oha, release build)

**Measure with a FIXED REQUEST COUNT (`-n`), not a time box (`-z`).** A time-boxed run stops at the
deadline and never waits for outstanding requests, so it reports "100% success" even when the server
is stranding connections — which is exactly how the IOCP stall below hid for so long. `-z` also
charges ~100 in-flight requests as "aborted due to deadline" at c=100, which reads as a fake 99.9%.

Measured on a 4-core box with the load generator CO-RESIDENT, so these are lower bounds. Two servers:
`web.app` with one typed JSON route (workers = `nproc - 1`), and the flagship's Nova-owned reactor
(`flagship/bench/headtohead/nova-reactor/server.nova`, ONE core).

| Server / backend | req/s | Cores | Success |
|---|---|---|---|
| Nova reactor / epoll | 75,621 | 0.87 | 300,000/300,000 |
| Nova reactor / io_uring | ~65,000 | 0.93 | 299,995/300,000 |
| web.app / epoll | 26,599 | ~3 | 100% |
| web.app / io_uring | ~30,000 | ~3 | 100% |
| web.app / IOCP (Windows) | ~11,300-13,200 | ~3 | 300,000/300,000 |

### The kqueue gap is mostly the ENVIRONMENT — measured, not assumed

The M1 figure (186k on one core) is ~2.6x this box. That is NOT a Linux-backend deficiency: the
head-to-head peers were built and run here with the identical method, and they degrade as much or
more.

| Server | req/s here | Cores | per core |
|---|---|---|---|
| Nova reactor / epoll | 75,621 | 0.87 | **86,921** |
| Rust axum + tokio | 55,094 | 1.74 | 31,663 |
| Go net/http | 15,846 | 1.57 | 10,092 |

Go scores 15,846 here against 121,743 on the M1 — a **7.7x** environment penalty; Rust drops 2.4x;
Nova 2.6x. So Nova's fall is in-band. Contributors, in order: WSL2 virtualises syscalls and loopback
(worst case for a syscall-per-request path), the load generator takes ~3 of 4 cores, and the M1
P-core is simply faster. On THIS box one Nova reactor core beats Rust axum's 1.74 and Go's 1.57.

**The one genuinely OURS**: io_uring is still slower than epoll (65k at 93% CPU vs 75.6k at 87%),
~1.4x more CPU per request, because it is readiness EMULATED on a completion engine — poll, then a
separate read, plus a re-arm, where epoll does two kernel interactions. Multishot `RECV` + `SQPOLL`
is the real headroom. That comparison is same-box/same-minute, so unlike the M1 numbers it is not
confounded.

**Earlier figures for regression-hunting were 8.0k / 14.1k / 13.6k (web.app, time-boxed).** If
throughput regresses, suspect these first:
1. **Persistent fd registration** (`eventloop_linux`). The reactor used to `EPOLL_CTL_ADD` on every
   submit and `EPOLL_CTL_DEL` on every completion — four `epoll_ctl` calls per keep-alive request on
   top of recv/send. It now ADDs once, re-arms with `EPOLL_CTL_MOD` + `EPOLLONESHOT`, and only DELs
   on close: ~7 syscalls per request down to ~3. Registration state is thread-local in the runtime
   because `reactorio`'s free-function submit path needs it too, not just the Poller.
2. **Batched io_uring submission.** `submit` only STAGES an SQE; the next `poll` publishes the whole
   batch with one `io_uring_enter`. Submitting per operation costs a syscall each, which is exactly
   what a ring exists to avoid — it was worth +53%.
3. **Pooled op records** (`nova_op_alloc`/`nova_op_free`, core.cpp). `reactorio` allocated and freed
   a record per read AND per write; reuse is now a pointer swap on a thread-local free list. This one
   is cross-platform and is where IOCP's +26% came from.

Next wins, in order: per-request allocations in `web/app` + the HTTP parser (helps ALL backends,
including Windows), io_uring `SQPOLL` (zero syscalls on the hot path) and multishot recv/accept, then
full edge-triggered epoll to drop the remaining `MOD`.

### On a proactor the KERNEL owns the op record — never "give up and free"

The single most expensive class of bug in this codebase's IOCP/io_uring work, and it always presents
the same way: a connection hangs forever, the server sits at 0% CPU, and the fault (if any) lands
somewhere unrelated. On kqueue/epoll, abandoning an operation means deregistering an *interest* —
afterwards nothing in the kernel refers to the op record, so freeing it is safe. On IOCP the kernel
holds `lpOverlapped == op`, and on io_uring a submitted SQE holds it as `user_data`, until the
operation completes or is cancelled. Free it there and the pooled record is handed out again, the
next submit zeroes its OVERLAPPED (`issue()` does this first), and the ORIGINAL completion is
delivered nowhere.

`net/eventloop*.abandonOp(kq, op)` is the seam: it returns whether the CALLER still owns the record.
epoll/kqueue answer false (free it); IOCP and io_uring answer true, having marked the record
`OP_ABANDONED` and issued CancelIoEx / ASYNC_CANCEL — the drain frees it when the completion lands.
Rules that follow, all of which were violated and cost real debugging:
- A resume is NOT proof your op finished. `recvInto`/`sendBuf` wait for `opDone == 1`; a stale timer
  or batch wake can resume the coroutine while the op is still in flight.
- One outstanding op per record. Re-issuing on a live OVERLAPPED destroys the first op's bookkeeping.
- Dropping an arm does not free it — cancel, and leave the record in the per-fd arm map for reuse.

### A coroutine handle is a FRAME ADDRESS — and addresses get recycled

This one cost days and hid behind four unrelated-looking fixes, so it is worth stating outright.
`nova_reactor_resume` skips handles recorded in `g_batch_reaped`, a guard that exists so a stale
deadline-timer event cannot resume a coroutine whose frame was already freed this batch. But the
handle IS the frame address, frames are heap-allocated, and the set is only cleared at the START of
a batch. So when a frame was reaped mid-batch and the allocator handed the SAME address to a
brand-new coroutine, that coroutine inherited the stale mark and its first legitimate resume was
dropped on the floor — leaving its connection ESTABLISHED forever with nothing outstanding and the
server at 0% CPU. `nova_reactor_detach` now erases the mark: reaching it means the address is live
again.

It presented as a Windows/IOCP bug (stalls at c>=50) but lives in `concurrency.cpp` and is shared by
ALL backends — IOCP merely hit the timing first. Any "connection hangs and the server is idle" report
on any backend should suspect this shape.

**Diagnosing this class**: two opt-in runtime facilities exist because inference was not enough.
`NOVA_IO_WATCHDOG=1` prints `issued/completed/outstanding/resume_skipped` every 2s, which separates
the three possibilities that look identical from outside — the kernel never completed an operation
(outstanding stuck > the parked acceptors), the app stopped issuing one (outstanding == acceptors),
or a resume was swallowed (resume_skipped > 0). `NOVA_CRASH_TRACE=1` prints a backtrace and fault
address on an alternate signal stack, so a stack-exhaustion SIGSEGV still reports instead of dying
silently. Measure before theorising; each of these ruled out an entire class in one run.

### Readiness on a proactor

Neither IOCP nor io_uring has "tell me when this fd is readable" — you hand them an operation, not an
interest. Both get readiness from a **zero-byte receive**: it completes exactly when data arrives and
consumes none of it, so the completion IS the readiness edge and the caller then does a normal read.
The per-fd arm records are shared between the two backends (`nova_reactor_arm_*`), since the trick is
identical and only the spelling differs (`WSARecv` vs `IORING_OP_RECV`). `evBytes` falls back to
`FIONREAD` because a zero-byte completion has no count to report.

### Cross-reactor wake on io_uring — and an SQE trap worth remembering

The wake channel is an eventfd on both Linux backends; what differs is how its readability is
observed. epoll registers it in the set. io_uring has no set, so it watches the fd with a ONE-SHOT
`IORING_OP_POLL_ADD`, which must be drained and re-armed after every fire — from the C driver AND
from the Nova-side poll, because a reactor loop driven from Nova reaps completions itself and never
reaches the C dispatch.

The trap: in `io_uring_sqe`, **`poll32_events` unions with `off`/`addr2`**. Setting the event mask
while ALSO leaving `off` populated makes addr2 non-zero, the kernel rejects the SQE with -EINVAL, and
the completion comes back instantly carrying the correct `user_data`. That presents as a wake that
fires the moment it is armed: the poll returns, the filter correctly reports a user wake, and only
the empty inbox reveals anything is wrong. `nova_uring_prep` now clears `off` for POLL_ADD.

Worth knowing generally — several io_uring opcodes alias fields through that union, so "set the field
the docs name" is not sufficient; the ones it overlaps have to be cleared.

## Status

See `docs/design/execution-plan.md` — the master table (27/31 items ✅). Recent: **T6 per-file `.o` split
DONE** (default-on, content-hash cache, F4-6 satisfied); **T1 cross-compilation** — from macOS build Linux
x86_64/arm64 (static ELF) + Windows x86_64 (PE32+) via bundled `zig c++`; **build deps generalized off
Homebrew** — vendored Boost.Asio subset (`deps/boost`) + static LLVM from a self-hosted lazy `build.zig.zon`
mirror (`kamlesh-nb/llvm-dist`; tarballs staged in `~/.nova-llvmdist`, upload pending). Depends on **BTreeDB**
(separate repo) and pairs with **nls** (LSP) + the VSCode **extension**.
