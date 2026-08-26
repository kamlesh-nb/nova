# CLAUDE.md — Nova Language (compiler + runtime + stdlib)

## What this is

**Nova** is a statically-typed, ES6/TypeScript-flavoured language for server-side services, hypermedia
apps, and WebAssembly. This repo is the **language implementation**:

- **Compiler** — written in **Zig 0.16**, lowers Nova → **LLVM IR** → native object → linked binary
  (in-process LLD or `clang++`). WASM target via `wasm-ld`.
- **Runtime** — a small **C++20** core (`src/runtime/`): the reactor-native async scheduler
  (`concurrency.cpp`), LLVM-coroutine drive, sockets, and hardware-crypto hooks. **Boost.Asio and
  wolfSSL are RETIRED** — the event loop is Nova's own reactor (kqueue/epoll/io_uring/IOCP) and TLS +
  all crypto are self-hosted in pure Nova (hardware AES/SHA where available).
- **Standard library** — written in **Nova itself** (`src/lib/std/`): collections, string,
  json/yaml/bson, http/web framework, sql/db drivers, crypto + TLS, concurrency, regex, decimal128.

## Build / run / test

```bash
cd lang
zig build                       # builds `nova`, installs to ~/.nova/bin/nova, syncs std+runtime+deps to ~/.nova
NOVA_ASAN=1 zig build           # ALSO builds libnova_runtime_asan.a (needed for the ASAN gate)

nova <file.nova> -o out         # compile a single file to a native binary
nova test <file.nova>           # run @test functions
nova build [--release]          # project build → build/<profile>/{obj,bin} (reads project.json)
nova init web|desktop --name X  # scaffold an app

conformance/run.sh              # the corpus — run BEFORE and AFTER any change
conformance/run.sh -j           # SAME corpus, run in parallel (cores-1 workers) — ~5x faster (~2min vs >10min)
conformance/run.sh --asan       # AddressSanitizer gate (catches UAF/double-free). Requires NOVA_ASAN=1 build first.
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

## Build on Windows and WSL

Three supported ways to work with the repo on a Windows machine:

**A. WSL2 (Ubuntu) — the simplest, and the way to run the Linux gates.**
```bash
git config --global core.autocrlf input   # BEFORE cloning: keep bash scripts + .nova sources LF
# clone INSIDE the WSL filesystem, then:
cd lang
export NOVA_LLVM_PREFIX=/usr/lib/llvm-21   # point at a system LLVM (-Dstatic-llvm 404s on the mirror)
zig build                                  # Zig 0.16 required; normal Linux flow from here
conformance/run.sh -j
```

**B. Native Windows host (PowerShell) — run-verified, reactor and all.**
Requires Zig 0.16 and an LLVM install exposing `LLVM-C.dll` + `LLVM-C.lib` (LLVM 21 verified):
```powershell
$env:NOVA_LLVM_PREFIX = 'C:/LLVM'
$env:PATH = 'C:\LLVM\bin;' + $env:PATH     # bin/ on PATH for clang++/llvm-ar AND at RUN time
zig build                                  # build.zig has a PowerShell install step (no sh/rsync)
```
`C:\LLVM\bin` must stay on PATH at **run** time too — `nova.exe` links `LLVM-C.dll` dynamically. If it
is missing, every corpus case reports `<compile/link error>` and `nova.exe` exits `0xC0000135`
(STATUS_DLL_NOT_FOUND) with no output — reads exactly like a compiler regression, but it is the DLL.

**C. Cross-compile from macOS/Linux/WSL (no Windows host needed).**
```bash
nova app.nova --target windows-x86_64      # real PE32+ .exe; adds -lws2_32 -lmswsock -lbcrypt
```

**Windows internals worth knowing** (the port is Nova-over-Win32-FFI, not C++ shims; the
target-conditional file rule `targetVariantPath` swaps whole modules so shared callers are unchanged):
- The LLVM.org Windows `LLVM-C.dll` ships a REDUCED target set — referencing an absent
  `LLVMInitialize<T>*` is a hard LINK error; `deps/llvm-zig/src/target.zig` filters to what is present.
- The link path drives MSVC `link.exe`: `/OPT:REF` (not `--gc-sections`), the runtime COFF object (not
  `-lnova_runtime`, link.exe can't read llvm-ar's GNU archive), `-rtlib=compiler-rt`, and
  `-lc`/`-lm`/`-lpthread` dropped (MSVC folds them into its CRT).
- `os/windows/{fs,sys,proc}` reimplement file/dir/env/spawn (UCRT has no `<dirent.h>`, different
  `O_CREAT`/`O_TRUNC`, `st_mode` moved, no `setenv`).
- **WSAStartup**: initialise Winsock in `os/windows/sys.socket` + `getAddrInfo` yourself (no POSIX init
  step), else `bind`/hostname resolution fail while numeric addresses appear to work.
- **IOCP**: a socket must be `CreateIoCompletionPort`'d before its first overlapped op or the completion
  goes nowhere. `ConnectEx` is the one non-pure-FFI piece (resolved via
  `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` in `nova_wsa_connectex`, io.cpp).
- `/tmp` is not a Windows path (a leading `/` resolves against the current drive root) — use
  `dir.Dir.tempDir()`.
- `--asan`/`--arc` gates are not wired on Windows (the install step skips those runtimes).

## Layout

- `src/` — lexer, parser, `type_checker.zig`, **`sema/`** (infer/mono/ownership/lower/symbols — the
  authoritative typed-IR pass), **`codegen/`** (`llvm_codegen.zig`, `declarations.zig`, `expressions.zig`,
  `statements.zig`, `arc.zig`, `types.zig`), `main.zig` (driver + linking).
- `src/lib/std/` — the Nova standard library (compiled from source per build; import-graph gated).
- `src/runtime/` — the small C++20 runtime (`concurrency.cpp` = reactor scheduler + async I/O,
  `crypto.cpp` + `nova_crypto_arm64.S` = hardware AES/SHA hooks; TLS itself is pure Nova).
- `conformance/` — `cases/*.nova` (positive, run via `nova test`) + `expect_fail/` (must be rejected) +
  `run.sh` (the harness, self-tests its own negative-case classifier).
- `docs/design/` — **`execution-plan.md`** (the master status table + per-item design — READ THIS for
  roadmap state), plus per-feature specs. `docs/specs.md` is the language spec.
- `packages/nova-*` — the concrete DB drivers (postgres/mysql/mssql/novadb/mongodb); the `db` seam +
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

## Reactor backends — models, selection, and the hard-won gotchas

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

### Conformance across backends

epoll and io_uring have IDENTICAL failure lists — every reachable case passes on both. Windows/IOCP
trails by a few readiness cases (see below).

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

### Benchmarking + throughput regression-hunting

**Measure with a FIXED REQUEST COUNT (`-n`), not a time box (`-z`).** A time-boxed run stops at the
deadline and never waits for outstanding requests, so it reports "100% success" even when the server
is stranding connections — which is exactly how the IOCP stall below hid for so long. `-z` also
charges ~100 in-flight requests as "aborted due to deadline" at c=100, which reads as a fake 99.9%.
Run the load generator on a separate box where possible; co-resident it steals cores and the numbers
become lower bounds. Rough shape on a good single core: the Nova-owned reactor clears tens of
thousands of req/s (epoll ≈ io_uring, io_uring slightly hotter per request — see below).

io_uring is still slightly slower than epoll (~1.4x more CPU per request) because it is readiness
EMULATED on a completion engine — poll, then a separate read, plus a re-arm, where epoll does two
kernel interactions. Multishot `RECV` + `SQPOLL` is the real headroom there.

If throughput regresses, suspect these first:
1. **Persistent fd registration** (`net/ev/epoll`). The reactor used to `EPOLL_CTL_ADD` on every
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

`net/ev/<backend>.abandonOp(kq, op)` is the seam: it returns whether the CALLER still owns the record.
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

## Status & dependencies

Master roadmap: `docs/design/execution-plan.md` (per-item design + state). Language spec: `docs/specs.md`.
Depends on **NovaDB** (separate repo); pairs with **nls** (LSP) + the VSCode **extension**.

## Planned / next work

1. **All crypto hardware-asm for x86_64.** ARM64 has `src/runtime/nova_crypto_arm64.S` (AES + SHA-256
   via the ARMv8 crypto extensions, wired through `nova_has_asm_crypto()` / `nova_sha256_blocks` and
   `simd.aesenc`). Add the x86_64 equivalents — AES-NI, SHA-NI (`sha256rnds2`/`sha256msg1/2`), PCLMULQDQ
   for GHASH, and the AVX2 SHA path — behind the same gates, with runtime CPUID detection and a scalar
   fallback. Reference Go's `crypto/internal/fips140/sha256/_asm/sha256block_amd64_{shani,avx2}.go` and
   the AES-GCM assembly for the instruction sequences.

2. **A small CRUD web app on MSSQL** (like `nova-pg-web` is for Postgres) to exercise the web framework
   AND the `mssql` driver end to end — scaffold with `nova init web`, wire the `mssql` package as the
   `Connection`, run the same load/soak test. Shakes out driver + framework edges together.

3. **Orchestrator fd-handoff: io_uring test + a Windows port.** The zero-downtime handoff passes client
   sockets over an **AF_UNIX** control channel via **`SCM_RIGHTS`** (`src/net/proxy.nova`), with the
   rendezvous under `/tmp/nova-*.sock` — the short path is DELIBERATE (AF_UNIX `sun_path` caps at ~104
   bytes on macOS; `$TMPDIR`/`/var/folders` would overflow it, so do NOT "portably" swap `/tmp` for
   `dir.tempDir()`). It works on kqueue/epoll; still to do: **(a)** verify it on **io_uring** (a
   proactor's in-flight ops + inherited socket state differ from a readiness engine's); **(b)** a
   **Windows** path — `SCM_RIGHTS` does not exist there, so it needs `WSADuplicateSocket` (or a named
   pipe) plus re-associating the handed-off socket with the new process's IOCP. This is a genuine
   platform port, not a cross-platform find-replace. (Audit note: the DB drivers use the target-swapped
   `os.sys` seam and the novadb server `src/` cross-builds clean for Windows — both already portable;
   this handoff is the only POSIX-locked surface.)

4. **Windows/WSL parity gates.** Wire `--asan`/`--arc` on Windows and close the remaining IOCP
   readiness cases (`armRead`/`armWrite` have no proactor analogue; convert to the zero-byte-receive
   completion path already used by io_uring — see "Readiness on a proactor" above).
