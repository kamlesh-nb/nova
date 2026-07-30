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
conformance/run.sh --asan       # AddressSanitizer gate (catches UAF/double-free; 266/266). Requires NOVA_ASAN=1 build first.
conformance/run.sh --arc        # ARC leak gate (baseline-gated)
NOVA_ARC_AUDIT=1 nova test f    # per-run ARC audit ("ARC audit: clean" or survivors)
```

## Working on Windows — read this first if the repo is cloned on a Windows host

**Native Windows builds of the `nova` compiler are NOT wired up. Do not expect `zig build` to work on a
bare Windows host — it will fail.** Two hard blockers:
- `build.zig`'s install step runs `sh -c` with `rsync`/`mkdir -p` (around line 448), so it needs a Unix
  shell + rsync on PATH (Git Bash / MSYS2) at minimum.
- The static LLVM the compiler links is only configured for **macOS and Linux hosts**
  (`build.zig` `configureLlvmLink`); there is **no Windows-host LLVM dist**, so the compiler cannot link
  itself on Windows.

**→ The comfortable path on a Windows machine is WSL2 (Ubuntu).** Clone the repo *inside* WSL, install
**Zig 0.16**, and use the normal Linux flow — `zig build`, `nova <file>.nova`, `conformance/run.sh`,
`conformance/run.sh --asan` all work there (Linux is a first-class, gated target). Develop in WSL; treat
the Windows side as a *target*, not a dev host. (Before cloning, `git config --global core.autocrlf input`
so the bash scripts and `.nova` sources keep LF.)

**What "Windows support" currently means: cross-compilation, not native dev.** From macOS / Linux / WSL,
`nova app.nova --target windows-x86_64` produces a real **PE32+ .exe** — the C++ runtime and the full
reactor stack cross-compile and link (adds `-lws2_32 -lmswsock -lbcrypt`). This is **compile+link
verified only**: runtime EXECUTION on Windows — especially the async reactor (the IOCP `Poller`,
`nova_run_reactors` on Windows threads, socket→port association, `AcceptEx`/`ConnectEx`) — has **not**
been run-verified (there is no Windows host in the loop). Non-async programs are the most likely to run;
the reactor is the risky part. See `docs/design/cpp-runtime-retirement-plan.md` and the reactor design
notes for exactly what is stubbed vs done.

**If asked to make `zig build` run natively on a Windows host** (not just cross-compile *to* Windows), the
two unstarted pieces are: (1) replace the `sh`/`rsync` install step with a cross-platform copy (a small
Zig `Step` or per-OS branch), and (2) add a Windows-host static-LLVM dist to `configureLlvmLink` (mirror
the linux/macos entries). Until both exist, direct Windows-host development is not possible; use WSL.

### Windows host TODO — the plan for when a real Windows 10 machine is available

Everything below is **compile-verified (cross-compiles to a PE32+ .exe) but NOT run-verified** — there has
been no Windows host in the loop. On a Windows 10 box, do these in order and verify each *live* (a real
run + assert), not just a compile. Detail lives in `docs/design/cpp-runtime-retirement-plan.md` and the
memory notes `nova-reactor-eventloop-iocp`, `nova-windows-runtime-port`, `nova-m14-max-ffi-reach`.

1. **Get a native toolchain first.** Either finish the two native-`zig build` blockers above, OR build the
   `nova` compiler under WSL and cross-compile programs to Windows, then run the `.exe` on the Windows
   side. (You need runnable Windows binaries to test any of the below.)

2. **IOCP reactor runtime** (`src/std/net/eventloop_windows.nova` — the `Poller`). It cross-compiles and is
   selected on Windows, but the runtime is unproven and these pieces are **stubbed / unfinished**:
   - `nova_run_reactors` on the C side is kqueue/POSIX-oriented — needs a **Windows-threads** path
     (`concurrency.cpp` is `#ifndef _WIN32`-guarded; the coroutine scheduler + thread spawn need a Windows
     impl or verification).
   - **socket→port association**: each socket must be `CreateIoCompletionPort`'d before overlapped I/O
     (`eventloop_windows.associate`); reactorio does not call it yet — wire it in.
   - **AcceptEx / ConnectEx**: `submit` returns -1 for `OP_ACCEPT`/`OP_CONNECT` today (only `WSARecv`/
     `WSASend` are done). Implement them (they need `WSAIoctl` to fetch the function pointers).
   - **int-kq vs 64-bit port HANDLE**: `Reactor.kq` is `int` but the IOCP port is a 64-bit `HANDLE`; the
     `Poller` keeps the full-width `port` but the reactor's shared int field truncates it — reconcile.
   - **Cross-reactor wake**: use `PostQueuedCompletionStatus` (the completion-model analogue of
     EVFILT_USER / eventfd).
   - **Test**: conformance reactor cases (192, 200-205, 209) + a live reactor echo/HTTP server + the
     async HTTPS client, all run on Windows.

3. **Process management on Windows** (M14.1, `io.cpp` `nova_process_*`). The POSIX path is real; the
   `#else` Windows path is **stubs returning -1**. Implement over `CreateProcessW` + `CreatePipe` +
   `WaitForSingleObject` + `GetExitCodeProcess` + `TerminateProcess` (or, if M14.1 lands first, expose the
   POSIX-neutral `os/proc` seam and add `os/proc_windows`). **Test**: `process.nova`'s spawn + stdin/stdout
   round trip + wait + kill.

4. **File / dir on Windows** (currently NOT Windows-native). File/dir I/O is Nova over `os/sys`, which is
   **POSIX-flavored** — on Windows it rides mingw's compat layer (`open`/`read`/`mkdir`/`dirent`), which
   covers the basics but not long paths, UTF-16 names, or proper Windows semantics. First **verify** the
   mingw path actually works at runtime (read/write a file, list a dir); if it falls short, add an
   `os/fs_windows` split (mirror `os/socket_windows`) over `CreateFileW`/`ReadFile`/`WriteFile`/
   `CreateDirectoryW`/`FindFirstFileW`/`FindNextFileW`. **Test**: `io/file` read/write + `io/dir` listing.

5. **Then run the full corpus on Windows** (`conformance/run.sh` under Git Bash / MSYS) and record a
   Windows baseline the way there is a `wasm-run-baseline.txt`.

Order of dependence: (1) toolchain → then (4) file/dir + (3) process are independent and simplest to
verify → (2) IOCP reactor is the largest and should be last. The linker already adds
`-lws2_32 -lmswsock -lbcrypt`.

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

## Status

See `docs/design/execution-plan.md` — the master table (27/31 items ✅). Recent: **T6 per-file `.o` split
DONE** (default-on, content-hash cache, F4-6 satisfied); **T1 cross-compilation** — from macOS build Linux
x86_64/arm64 (static ELF) + Windows x86_64 (PE32+) via bundled `zig c++`; **build deps generalized off
Homebrew** — vendored Boost.Asio subset (`deps/boost`) + static LLVM from a self-hosted lazy `build.zig.zon`
mirror (`kamlesh-nb/llvm-dist`; tarballs staged in `~/.nova-llvmdist`, upload pending). Depends on **BTreeDB**
(separate repo) and pairs with **nls** (LSP) + the VSCode **extension**.
