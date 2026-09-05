# CLAUDE.md — Kyte Language (compiler + runtime + stdlib)

## What this is

**Kyte** is a statically-typed, ES6/TypeScript-flavoured language for server-side services, hypermedia
apps, and WebAssembly. This repo is the **language implementation**:

- **Compiler** — written in **Zig 0.16**, lowers Kyte → **LLVM IR** → native object → linked binary
  (in-process LLD or `clang++`). WASM target via `wasm-ld`.
- **Runtime** — a small **C++20** core (`src/runtime/`): the reactor-native async scheduler
  (`concurrency.cpp`), LLVM-coroutine drive, sockets, and hardware-crypto hooks. **Boost.Asio and
  wolfSSL are RETIRED** — the event loop is Kyte's own reactor (kqueue/epoll/io_uring/IOCP) and TLS +
  all crypto are self-hosted in pure Kyte (hardware AES/SHA where available).
- **Standard library** — written in **Kyte itself** (`src/lib/std/`): collections, string,
  json/yaml/bson, http/web framework, sql/db drivers, crypto + TLS, concurrency, regex, decimal128.

## Build / run / test

```bash
cd lang
zig build                       # builds `kyte`, installs to ~/.kyte/bin/kyte, syncs std+runtime+deps to ~/.kyte
KYTE_ASAN=1 zig build           # ALSO builds libkyte_runtime_asan.a (needed for the ASAN gate)

kyte <file.ky> -o out         # compile a single file to a native binary
kyte test <file.ky>           # run @test functions
kyte build [--release]          # project build → build/<profile>/{obj,bin} (reads project.json)
kyte init web|desktop --name X  # scaffold an app

conformance/run.sh              # the corpus — run BEFORE and AFTER any change
conformance/run.sh -j           # SAME corpus, run in parallel (cores-1 workers) — ~5x faster (~2min vs >10min)
conformance/run.sh --asan       # AddressSanitizer gate (catches UAF/double-free). Requires KYTE_ASAN=1 build first.
conformance/run.sh --arc        # ARC leak gate (baseline-gated — currently NOISE, see its section)
KYTE_ARC_AUDIT=1 kyte test f    # per-run ARC audit ("ARC audit: clean" or survivors)

scripts/build-archives.sh       # runtime archives for all 4 shipping targets (see below)
```

### Runtime archives for the shipping targets (`scripts/build-archives.sh`)

Builds `libkytecore.a` for {x86_64, aarch64} × {linux-gnu, windows-msvc} into
`zig-out/archives/<triple>/`, each WITH its integrated-assembly crypto. This is separate from
`zig build`, which produces the archive for the HOST only.

**Use `zig c++`, not `clang++`.** Cross-compiling `runtime.cpp` needs the target's libc headers, and a
bare clang has no sysroot for them: every Linux target fails at `<cstdio>` from a Windows host, and from
Linux the aarch64 target needs `libc6-dev-arm64-cross` installed. Zig ships those headers for every
target it knows, so three of the four need nothing installed. The exception is **aarch64-windows-msvc**,
where zig reports `failed to find libc installation: LibCStdLibHeaderNotFound` because that libc really
does come from the Visual Studio install — `clang++` finds it through the same MSVC toolchain that builds
the native compiler, so that one target uses clang++.

`asmCryptoFor()` in `build.zig` deliberately returns null for a cross build, so `zig build` never puts
assembly in a cross archive; this script assembles it explicitly per target instead. Verify a produced
archive before trusting it — the arm64 failure mode is silent (see the crypto section):

```bash
llvm-objdump -f zig-out/archives/<triple>/kytecore.o | grep 'file format'
llvm-nm --defined-only zig-out/archives/<triple>/libkytecore.a | grep kyte_aes_encrypt_block
```

Windows note: the `.a` is a convenience only — `link.exe` cannot read llvm-ar's GNU archive, so the
Windows link path names the bare `kytecore.o` + `kyte_crypto.o`, which are kept beside it. (It CAN read
llvm-lib's COFF archive; the script emits `kytecore.lib` for Windows targets and link-verifies it.)

### The compiler itself (`scripts/build-dist.sh`) — and why it is HOST-ONLY

`build-archives.sh` produces what a program LINKS against. `build-dist.sh` produces what you INVOKE:
`zig-out/dist/<host-triple>/` with `bin/kyte` plus the `kyte-home/` tree it resolves at run time
(`std/`, `lib/`, `src/runtime/`, `deps/`), and an `INSTALL.txt`. Both distributions here were verified
by installing into a CLEAN `HOME` and compiling + running a crypto-using `.ky` file — not by
checking the binary exists.

It takes no target argument, because **`kyte` links LLVM itself** (LLVM-C, or the static component
libs, out of `KYTE_LLVM_PREFIX`). Cross-building it needs LLVM built FOR THE TARGET, not merely a cross
C++ toolchain, and `zig build -Dtarget=x86_64-linux-gnu` says so plainly:

```
error: unable to find dynamic system library 'LLVM' ... searched:
       C:\LLVM\lib\libLLVM.so   C:\LLVM\lib\libLLVM.a
```

Zig can synthesise a libc for any target; it cannot synthesise LLVM. So each host builds its own
compiler — x86_64-windows-msvc natively, x86_64-linux-gnu in WSL, and an arm64 host would need an
arm64 LLVM and a native build there.

**This does NOT block producing arm64 binaries.** `kyte app.ky --target linux-arm64` (or
`windows-arm64`) cross-compiles from an x86_64 host and is verified working from the distribution
itself — the cross path builds and caches the per-target runtime object, and since the fixes above it
also assembles the per-target crypto. What needs a native arm64 build is RUNNING the compiler on
arm64, which is a packaging question, not a portability one: nothing in the tree is x86-specific.

### Running the corpus in parallel (`-j`)

The default `conformance/run.sh` is sequential (~10 min, and the reactor cases push it longer). `-j`
runs the same positive corpus across `cores-1` workers (~2 min); `-j N` sets the worker count. It applies
ONLY to the plain `kyte test` run — the `--asan` / `--arc` / `--wasm` modes stay sequential (baseline-gated,
order-sensitive), and the harness self-test + `expect_fail` gates run after, unchanged.

How it stays correct in parallel — two things had to be handled:
- **`kyte test` writes a hardcoded `__kyte_test` output file**, so parallel instances would clobber each
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
git config --global core.autocrlf input   # BEFORE cloning: keep bash scripts + .ky sources LF
# clone INSIDE the WSL filesystem, then:
cd lang
export KYTE_LLVM_PREFIX=/usr/lib/llvm-21   # point at a system LLVM (-Dstatic-llvm 404s on the mirror)
zig build                                  # Zig 0.16 required; normal Linux flow from here
conformance/run.sh -j
```

**B. Native Windows host (PowerShell) — run-verified, reactor and all.**
Requires Zig 0.16 and an LLVM install exposing `LLVM-C.dll` + `LLVM-C.lib` (LLVM 21 verified):
```powershell
$env:KYTE_LLVM_PREFIX = 'C:/LLVM'
$env:PATH = 'C:\LLVM\bin;' + $env:PATH     # bin/ on PATH for clang++/llvm-ar AND at RUN time
zig build                                  # build.zig has a PowerShell install step (no sh/rsync)
```
`C:\LLVM\bin` must stay on PATH at **run** time too — `kyte.exe` links `LLVM-C.dll` dynamically. If it
is missing, every corpus case reports `<compile/link error>` and `kyte.exe` exits `0xC0000135`
(STATUS_DLL_NOT_FOUND) with no output — reads exactly like a compiler regression, but it is the DLL.

**Build `-Doptimize=ReleaseFast` before running the corpus. A Debug build cannot pass it, for reasons
that have nothing to do with the cases.** `cli.run` installs a leak-detecting allocator in Debug and
ends with `if (gpa.detectLeaks() > 0) std.process.exit(1)`. On the current Zig the driver leaks ~12k
allocations across dozens of sites (net-live, per `KYTE_ALLOC_PROFILE=1`; almost certainly std API
drift, since this tree also needed three unrelated Zig-0.16 fixes), so **every** `kyte test` exits 1
while printing `Results: N passed, 0 failed` — and `conformance/run.sh` keys off the exit code, so the
entire corpus reports FAIL with passing output. It also prints ~9k lines of leak traces per case, and
Debug codegen makes each case ~40x slower (**~60s vs ~1.4s**), which turns the corpus from ~20 minutes
into ~7 hours. If you see a red corpus where every case says it passed, this is why; it is not a
regression in the cases. Repairing the leak gate itself is separate outstanding work.

Note that readiness cases 192/194/195, listed as open in an earlier revision of this file, now PASS —
`iocp.ky` grew `armZeroByte`.

### Windows release: what ships now, and the static DLL-free upgrade

**Both Windows x86_64 AND arm64 are shipped** (dynamic LLVM-C). `release.yml` builds `kyte.exe` on a
`windows-latest` (x64) and a `windows-11-arm` (arm64) runner, linking `LLVM-C.dll` and bundling that DLL
beside `kyte.exe`. x64 gets LLVM-C from Chocolatey; arm64 downloads the LLVM.org
`clang+llvm-<v>-aarch64-pc-windows-msvc` drop (repo variable `WIN_LLVM_ARM64_URL`, pinned to LLVM 22 to
match `deps/llvm-zig`). The earlier claim that "no arm64 Windows LLVM exists" was wrong: that full
`clang+llvm` drop is a complete install tree, and combined with GitHub's `windows-11-arm` runners it is
all that was needed to build kyte natively for arm64.

The **static, DLL-free** path is the eventual upgrade (a `kyte.exe` that needs no `LLVM-C.dll`). macOS
and Linux already ship static by globbing the OS LLVM's `libLLVM*.a`; on Windows the
`-Dstatic-llvm` glob enumerates the `LLVM*.lib` static components instead. Worth knowing: the full
`clang+llvm` Windows drop DOES ship those static components too (verified: 147 `LLVM*.lib`, native
arm64/x64 COFF, not LTO bitcode — so no `llc` conversion like the macOS-22 drop needs), alongside
`LLVM-C.dll`. So the drop can drive EITHER path. The reason the static path is still future work is the
CRT + feature flags: the drop is built with the dynamic MSVC CRT and may enable zlib/zstd/libxml, whereas
`build.zig`'s static-Windows link line adds only a fixed Win32 lib set and expects an `MT`-CRT build with
those features OFF (see the CMake recipe below). Point `KYTE_LLVM_PREFIX` at such a prebuilt (repo vars
`WIN_STATIC_LLVM_{X64,ARM64}_URL`) and build `zig build archive -Dstatic-llvm=true`; no `LLVM-C.dll` is
bundled. The x64 recipe below carries over to arm64 (`-A ARM64`).

**How `build.zig` links it:** the `-Dstatic-llvm` glob branch, when `os_tag == .windows`, enumerates
`<prefix>/lib/LLVM*.lib` (skipping `LLVM-C.lib`, whose presence would drag the DLL back in) and adds the
Win32 system libs LLVM's own CMake needs (`ntdll ole32 oleaut32 uuid psapi shell32 advapi32 version`)
from the runner's Windows SDK. So the prebuilt's `lib/` contents ARE the link line — they must match.

**Build the prebuilt (once per arch, on a Windows box with VS + CMake + Ninja).** The flags matter,
because `build.zig` links ONLY the Win32 libs above — anything else LLVM depends on must be turned OFF
or the final link fails with unresolved symbols:

```
cmake -S llvm -B build -G Ninja -A <x64|ARM64> ^
  -DCMAKE_BUILD_TYPE=Release -DLLVM_USE_CRT_RELEASE=MT ^
  -DBUILD_SHARED_LIBS=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_BUILD_LLVM_C_DYLIB=OFF ^
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF ^
  -DLLVM_TARGETS_TO_BUILD=X86;AArch64 -DLLVM_INCLUDE_TESTS=OFF
cmake --build build --target install --config Release   # installs prefix/{lib,include,bin}
```

Then tar the install prefix, publish it (a release asset works), and set the repo variable to its URL.
Pin the LLVM MAJOR version to whatever `deps/llvm-zig` expects (22) — a mismatch is a link/ABI error.
`LLVM_USE_CRT_RELEASE=MT` static-links the MSVC CRT so users need no VC++ redistributable either.

**Still NOT self-contained after this — and deliberately out of scope here:** the shipped `kyte.exe`
no longer needs `LLVM-C.dll`, but it still shells out to `link.exe` to link the USER's programs (same
as every native host). Making it linker-free too means in-process LLD — and `addInprocessLld` currently
links `lldMachO/Wasm/ELF/Common` but **no `lldCOFF`**, so that is a separate piece of work. DLL-free
(this section) and linker-free (lldCOFF) are two different goals; only the first is done.

### Corpus status, measured on three hosts (ReleaseFast, `run.sh -j 3`)

| Gate | Windows / IOCP | Linux / epoll (WSL2, Ubuntu 24.04) | macOS / kqueue (arm64) |
|---|---|---|---|
| positive corpus | **442/444** | **443/444** | **444/444** |
| `--asan` | crypto subset clean | **443/444** | crypto subset clean (445) |

Windows and Linux are each at their ceiling: their only remaining failures are the two cases that
cannot LINK off their own platform. `188_kqueue_readiness` needs macOS (`kqueue`/`kevent`) and
`189_epoll_event_layout` needs Linux (`epoll_ctl`) — mirror images, both `LNK2019`-class failures
that never reach a test off-platform. macOS clears the whole 444: it links `kqueue` natively AND
`189` (which only asserts the epoll event struct's layout/constants, needing no `epoll_ctl` link),
so it is the one host with no platform-excluded case. Full Windows/Linux per-case history in
`win-lin-failures.md`.

macOS is the host that finally exercised the arm64 ChaCha20 kernel's store path at the ABI boundary
(`445`), which is what surfaced the `;`-as-comment assembler bug fixed in the crypto section — a bug
that assembled and ran fine on Linux/Windows and was invisible there. The lesson the three-host table
encodes: a green corpus on two hosts is not proof for the third, especially for hand-written
per-architecture assembly.

Running BOTH hosts is what made the earlier list interpretable, because "fails on Windows" turned out
to mean four different things and three of the seven were not Windows problems at all. Do not assume a
failure is a platform gap without checking the other host. The five that were real, all now fixed:

- **`42_nested_owned_aggregates` (both hosts) — value-struct copy settled no ownership.**
  `buildValueStructCopyInto` copies inline bytes without touching refcounts and REQUIRES the caller to
  follow up; every call site did except the struct-literal field loop, which did neither that nor
  `consumeTemporary`. So `Outer{ inner: Inner{ items: List<string>() } }` let the `Inner` temporary
  release the very list `Outer` had copied a pointer to. Binding the inner literal to a variable first
  survived only because the `let` copy added a retain of its own — which is what made it look like a
  nesting bug. Now uses the same borrow-vs-temporary split as `takeOwnedElement`.
- **`118_actor` (both hosts) — a generic field's LAYOUT and its STORE PATH disagreed.**
  `getTypeSize(t, true)` sizes a `.generic` field as 8 bytes unconditionally (a generic *declaration*
  cannot be laid out — a field of the bare type parameter has no size until instantiation), but the
  store paths asked `fieldStoredInline(baseName)`, which only sees `"Mailbox"` and says "value struct,
  inline it". `ActorCell<M>` reserved 8 bytes for `mbox: Mailbox<M>` and copied 16, so `mbox.signal`
  physically overwrote `behavior`; the next assignment then released that word as the field's previous
  value. `signal` holds a raw `kyte_chan_new` pointer with NO ARC header, hence ASAN's read 8 bytes
  before a plain malloc block. NOT the "ARC guessed from the type name" failure it was first recorded
  as — ownership was decided correctly; the bytes were in the wrong place. Fixed with
  `fieldStoredInlineRef(type_ref)`, phrased as `getTypeSize(t,true) == getTypeSize(t,false)` so the
  store decision is DERIVED from the layout and the two cannot drift apart again.
- **Windows stdlib gaps (2), both passing on Linux:** `163_process` passed a `T | undefined` from
  `List.get` to a `string` parameter (the POSIX module escapes it only by concatenating rather than
  passing as an argument); `256_dns_ipv6` wanted `socket.connectBlocking6`, which `os/windows/socket`
  never implemented. Note `AF_INET6` is 23 on Windows vs 10 Linux / 30 Darwin — the one sockaddr
  constant that differs on all three.
- **`413_file_write_ok` was a TEST bug, not a stdlib gap:** it hardcoded `/tmp/...`, which on Windows
  resolves against the current drive root (`C:\tmp\`). `dir.Dir.tempDir()` is the portable spelling.
- **`189_epoll_event_layout` — an `int` constant that does not fit an `int`.** Recorded earlier as "a
  signedness bug in the epoll event accessor"; that was WRONG and blamed the innocent side. `evEvents`
  correctly sign-extends `0x80000001` to `-2147483647`. The wrong side was the constant expression:
  `EPOLLET` was declared `int = 2147483648`, which does not fit 32-bit signed, so `EPOLLIN | EPOLLET`
  folded to `2147483649`. Now spelled as the signed bit pattern `-2147483648`. **Still open:** the
  compiler neither truncates nor rejects an out-of-range `int` constant — a language-semantics call
  (truncate like C, or error) that wants a spec change rather than a quiet edit.
- **Found ONLY by `--asan` (FIXED):** `123_any_container` passed the plain corpus while
  double-releasing. See the `any` note under Gotchas — it is the one type that is both "primitive" and
  owned, and a `??` fast path trusted the wrong predicate. Precisely the class of bug the ASAN gate
  exists for: invisible to a passing test, located exactly by ASAN.

### `--arc` is currently NOISE — read this before believing a leak regression

The gate reports **304 failures out of 818** on a green tree. That is not a tree full of leaks; the
BASELINE is stale. `arc-baseline.txt` holds **109 entries against 374 positive cases**, so roughly
**280 cases report `no baseline entry`** — an earlier note in this file claimed the gap was only
"244, 344, 440-444", which was wrong by two orders of magnitude. Do not repeat that number without
counting the file.

Worse, ~12 cases have an explicit `0` entry while genuinely leaking, so they report as
`(+N LEAK REGRESSION)` on a tree nobody touched: `52_decimal_arith` +24, `94_decimal_conv` +11,
`50_decimal`/`98_serde_json_yaml_coimport`/`99_serde_struct_decimal`/`106_resilient_pool` +6,
`63_db_seam` +4, `51_bson_decimal`/`64_db_connection`/`96_serde_decimal_json` +2,
`97_serde_decimal_yaml`/`104_conn_pool` +1. A `0` in that file means "never measured", NOT "was clean".

**How to tell a real regression from the stale baseline: A/B the compiler, do not reason about it.**
Check out the pre-change commit, `zig build -Doptimize=ReleaseFast`, run `run.sh --arc <filter>` on the
flagged cases, and compare live counts. `run.sh` takes a substring filter, so `--arc decimal` covers a
whole cluster in one go. Done once already for the value-struct work above: 12 of the 13 flagged cases
were byte-identical before and after, which is what proved the retains it added leak nothing.

The 13th is a real new number and worth chasing: **`118_actor` now leaks 12 objects.** It is not a
regression — the case used to CRASH before reaching the audit, so its `0` was never a measurement —
but fixing the corruption exposed a leak that was hiding underneath it.

**Windows: kill orphaned `kyte.exe` before rebuilding.** A `--arc`/`--asan` run killed by a timeout can
leave `~/.kyte/bin/kyte` running, and the next `zig build` then dies in its install step with
`Copy-Item : The process cannot access the file ... because it is being used by another process`. That
reads like a build-script bug and is a file lock: `taskkill //F //IM kyte.exe //T`, then rebuild.

Three Windows-host build breakages were fixed to get here, all Zig/UCRT drift rather than design:
`w.WINAPI` and `w.kernel32.GetCurrentProcess` no longer exist and `w.BOOL` became a distinct type
(`src/backend/codegen/declarations.zig`), and `SIGUSR1` does not exist in the UCRT, so the ARC
mid-run dump hook is now POSIX-only (`src/runtime/alloc.cpp`).

**The `--asan` gate now works on Windows.** clang's AddressSanitizer is fully functional here against
the MSVC runtime, so `KYTE_ASAN=1 zig build` builds `kytecore_asan.o` in the PowerShell branch exactly
as the sh branch does. Two things to know:
- **`clang_rt.asan_dynamic-x86_64.dll` must be on PATH at run time.** It lives in
  `<llvm>/lib/clang/<ver>/lib/windows`, NOT in `bin`, so adding `C:\LLVM\bin` is not enough. Without it
  the instrumented test binary cannot load and the harness reports `Test suite FAILED (exit code 53)`
  with no ASAN output at all — the same shape as the LLVM-C.dll trap, and just as misleading.
- ASAN is selected by the **`--asan` flag**, not by `KYTE_ASAN` in the environment. `run.sh` maps the
  env var onto the flag; invoking `kyte test` by hand needs `kyte test --asan <file>`. Setting only the
  env var silently runs an ordinary uninstrumented build.
Prefer `--asan -j`: the sequential ASAN branch has no per-case timeout, so one server/reactor case that
waits on a socket wedges the whole gate with no output. Measured here: the crypto subset (the 14 cases
covering the new x86_64 assembly) is ASAN-clean.

**C. Cross-compile from macOS/Linux/WSL (no Windows host needed).**
```bash
kyte app.ky --target windows-x86_64      # real PE32+ .exe; adds -lws2_32 -lmswsock -lbcrypt
```
Accepted switches are `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `windows-arm64`, `macos-x86_64`,
`macos-arm64` (`builder.zig`); anything else is `Unsupported target switch`. All four linux/windows
targets are link-verified against a crypto-using program. Two bugs made that not the case until
recently, BOTH invisible to the corpus because the corpus only ever builds for the host:

- **arm64 targets failed with `undefined symbol: kyte_sha256_blocks`** (and every other kernel) for any
  program touching crypto — i.e. all of TLS and hashing. `crossLinkViaZig` linked only
  `kytecore_<triple>.o`, and on arm64 there is no fallback to fall back to: crypto.cpp compiles no
  portable C under `__aarch64__`. It now also cross-assembles `kyte_crypto_<triple>.o`, cached the same
  way. This was unfixable until `kyte_crypto_arm64.S` stopped being Darwin-only (see the crypto section).
- **`linux-x86_64` failed with `undefined symbol: __cpu_model`**, referenced from `kyte_cpu_has_aes`.
  That branch used `__builtin_cpu_supports()`, which pulls compiler-rt's `__cpu_model`; zig's musl link
  does not provide it. The CPUID probe that the assembly dispatch already uses was gated behind
  `KYTE_ASM_CRYPTO_X86` and so unavailable on a cross build, which never defines it. The probe is now
  guarded on the ARCHITECTURE and `kyte_cpu_has_aes` reads it directly — same answer, no runtime dep.

x86_64 cross builds still compile `runtime.cpp` WITHOUT `-DKYTE_ASM_CRYPTO_X86` and so use the portable
C crypto, which is correct but not the fast path. Turning that on is a perf change needing its own
validation (the single CPUID gate promises every entry point works), not a link fix.

**Windows internals worth knowing** (the port is Kyte-over-Win32-FFI, not C++ shims; the
target-conditional file rule `targetVariantPath` swaps whole modules so shared callers are unchanged):
- The LLVM.org Windows `LLVM-C.dll` ships a REDUCED target set — referencing an absent
  `LLVMInitialize<T>*` is a hard LINK error; `deps/llvm-zig/src/target.zig` filters to what is present.
- The link path drives MSVC `link.exe`: `/OPT:REF` (not `--gc-sections`), the runtime COFF object (not
  `-lkyte_runtime`, link.exe can't read llvm-ar's GNU archive), `-rtlib=compiler-rt`, and
  `-lc`/`-lm`/`-lpthread` dropped (MSVC folds them into its CRT).
- `os/windows/{fs,sys,proc}` reimplement file/dir/env/spawn (UCRT has no `<dirent.h>`, different
  `O_CREAT`/`O_TRUNC`, `st_mode` moved, no `setenv`).
- **WSAStartup**: initialise Winsock in `os/windows/sys.socket` + `getAddrInfo` yourself (no POSIX init
  step), else `bind`/hostname resolution fail while numeric addresses appear to work.
- **IOCP**: a socket must be `CreateIoCompletionPort`'d before its first overlapped op or the completion
  goes nowhere. `ConnectEx` is the one non-pure-FFI piece (resolved via
  `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` in `kyte_wsa_connectex`, io.cpp).
- `/tmp` is not a Windows path (a leading `/` resolves against the current drive root) — use
  `dir.Dir.tempDir()`.

## Layout

- `src/` — lexer, parser, `type_checker.zig`, **`sema/`** (infer/mono/ownership/lower/symbols — the
  authoritative typed-IR pass), **`codegen/`** (`llvm_codegen.zig`, `declarations.zig`, `expressions.zig`,
  `statements.zig`, `arc.zig`, `types.zig`), `main.zig` (driver + linking).
- `src/lib/std/` — the Kyte standard library (compiled from source per build; import-graph gated).
- `src/runtime/` — the small C++20 runtime (`concurrency.cpp` = reactor scheduler + async I/O,
  `crypto.cpp` + `kyte_crypto_arm64.S` + `kyte_crypto_amd64.S` = the integrated-assembly crypto kernels
  and their dispatch; TLS itself is pure Kyte).
- `conformance/` — `cases/*.ky` (positive, run via `kyte test`) + `expect_fail/` (must be rejected) +
  `run.sh` (the harness, self-tests its own negative-case classifier).
- `docs/design/` — **`execution-plan.md`** (the master status table + per-item design — READ THIS for
  roadmap state), plus per-feature specs. `docs/specs.md` is the language spec.
- `packages/kyte-*` — the concrete DB drivers (postgres/mysql/mssql/novadb/mongodb); the `db` seam +
  generic pool stay in std.

## Core concepts (how it actually works)

- **ARC** — automatic reference counting, decided in codegen/sema (not a GC). Every heap object has an
  8-byte header (refcount @-8, length @-4). `kyte_retain`/`kyte_release(ptr, dtor)`. **Verify memory
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

- **`any` is the one type that is BOTH "primitive" and OWNED.** `isPrimitiveTypeName("any")` is true
  (it is a single word, not a struct) and `ownedByName("any")` is ALSO true (that word points at a
  refcounted `kyte_any_box`). Any codegen path that asks "is this primitive?" as a stand-in for "does
  this need reference counting?" is therefore wrong for `any` alone, and wrong in the dangerous
  direction: it skips a retain. That is what made `(m.get(k) ?? 0)` on a `Map<string, any>` a
  use-after-free — the `??` narrowed-present fast path returned the payload as a borrow with no
  retain, and it was then released by both the local and the map's destructor. When you need the ARC
  question, ask `ownedByName`. `isPrimitiveTypeName` answers a layout question, not an ownership one.
- **A vector load/store needs an EXPLICIT alignment, or LLVM assumes the type's ABI alignment.** A
  `<4 x double>` wants 32 bytes; Kyte arrays and `bytes.alloc` buffers are 8-byte aligned. Omit the
  alignment and EVERY x86_64 target gets an aligned 32-byte move against an 8-aligned address — #GP.
  Confirmed at the codegen level rather than inferred: for both the linux-gnu and windows-msvc
  triples, `load <4 x double>, ptr %p` emits `vmovaps` and `... , align 8` emits `vmovups`. It is
  INVISIBLE on arm64, where NEON does not fault on a misaligned load, so the identical IR works there
  and the bug looks like "SIMD only supports arm64" — it is not, `simd_target` dispatches AES/CLMUL to
  x86 correctly and everything else is target-neutral IR. This bit `simd.load4`/`store4` (fixed,
  conformance 261, which was broken on Windows AND Linux); `compileIntSimd` already set `align 1`. The
  same trap applies to hand-written asm: a legacy-SSE memory operand requires 16-byte alignment, which
  a Kyte buffer never has — see the integrated-assembly section.
- **`int` is 32-bit, `long` is 64-bit.** Heap ADDRESSES must be `long`/`ptr` — `intAddr + offset`
  TRUNCATES to 32 bits (LLVM `trunc i64→i32`) → garbage pointer → SIGSEGV. Address-dependent, so it fakes
  a heisenbug. `bytes.read_byte`/`write_byte` compute the offset internally at i64 (safe), but explicit
  `buf + off` in Kyte needs `buf: long`.
- **Env vars: `init.environ_map.get("VAR")`** — NOT `std.c.getenv` / `std.posix.getenv` (neither works in
  this Zig). `std.StringArrayHashMap` is absent → use `std.StringHashMap`.
- **Spec-first**: check/update `docs/specs.md` before adding a language feature.
- **Never `git reset`** in this repo (git stash is fine). `zig build` recovers `build.zig` from its cache.
- **`kyte test` skips `main()`** and runs imported `@test`s — a source of measurement traps; use
  `KYTE_ARC_DUMP`/`KYTE_ARC_AUDIT` to see survivors.
- Debug output: `KYTE_DUMP_MERGED=1` writes the merged IR; `KYTE_SEMA_SHADOW=1` diffs the type engines.

## Reactor backends — models, selection, and the hard-won gotchas

Four backends now exist, selected per target (and, on Linux, per run):

| Backend | Target | Model | Selected by |
|---|---|---|---|
| kqueue | macOS/BSD | readiness | `platform.os == "darwin"` |
| epoll | Linux | readiness | default on Linux |
| io_uring | Linux | **completion** (proactor) | `KYTE_REACTOR=uring` + a runtime probe |
| IOCP | Windows | **completion** (proactor) | `platform.os == "windows"` |

Linux has TWO backends and the target-conditional file rule selects by OS, so it cannot choose
between them: `kyte_reactor_backend()` decides once per process. The probe matters — the uapi header
being present says nothing about the running kernel, which can be too old or have io_uring disabled
administratively (`/proc/sys/kernel/io_uring_disabled`).

### Conformance across backends

epoll and io_uring have IDENTICAL failure lists — every reachable case passes on both. Windows/IOCP
now trails only by `189_epoll_event_layout`, which cannot link there (see the corpus status table).

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
become lower bounds. Rough shape on a good single core: the Kyte-owned reactor clears tens of
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
3. **Pooled op records** (`kyte_op_alloc`/`kyte_op_free`, core.cpp). `reactorio` allocated and freed
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
`kyte_reactor_resume` skips handles recorded in `g_batch_reaped`, a guard that exists so a stale
deadline-timer event cannot resume a coroutine whose frame was already freed this batch. But the
handle IS the frame address, frames are heap-allocated, and the set is only cleared at the START of
a batch. So when a frame was reaped mid-batch and the allocator handed the SAME address to a
brand-new coroutine, that coroutine inherited the stale mark and its first legitimate resume was
dropped on the floor — leaving its connection ESTABLISHED forever with nothing outstanding and the
server at 0% CPU. `kyte_reactor_detach` now erases the mark: reaching it means the address is live
again.

It presented as a Windows/IOCP bug (stalls at c>=50) but lives in `concurrency.cpp` and is shared by
ALL backends — IOCP merely hit the timing first. Any "connection hangs and the server is idle" report
on any backend should suspect this shape.

**Diagnosing this class**: two opt-in runtime facilities exist because inference was not enough.
`KYTE_IO_WATCHDOG=1` prints `issued/completed/outstanding/resume_skipped` every 2s, which separates
the three possibilities that look identical from outside — the kernel never completed an operation
(outstanding stuck > the parked acceptors), the app stopped issuing one (outstanding == acceptors),
or a resume was swallowed (resume_skipped > 0). `KYTE_CRASH_TRACE=1` prints a backtrace and fault
address on an alternate signal stack, so a stack-exhaustion SIGSEGV still reports instead of dying
silently. Measure before theorising; each of these ruled out an entire class in one run.

### Readiness on a proactor

Neither IOCP nor io_uring has "tell me when this fd is readable" — you hand them an operation, not an
interest. Both get readiness from a **zero-byte receive**: it completes exactly when data arrives and
consumes none of it, so the completion IS the readiness edge and the caller then does a normal read.
The per-fd arm records are shared between the two backends (`kyte_reactor_arm_*`), since the trick is
identical and only the spelling differs (`WSARecv` vs `IORING_OP_RECV`). `evBytes` falls back to
`FIONREAD` because a zero-byte completion has no count to report.

### Cross-reactor wake on io_uring — and an SQE trap worth remembering

The wake channel is an eventfd on both Linux backends; what differs is how its readability is
observed. epoll registers it in the set. io_uring has no set, so it watches the fd with a ONE-SHOT
`IORING_OP_POLL_ADD`, which must be drained and re-armed after every fire — from the C driver AND
from the Kyte-side poll, because a reactor loop driven from Kyte reaps completions itself and never
reaches the C dispatch.

The trap: in `io_uring_sqe`, **`poll32_events` unions with `off`/`addr2`**. Setting the event mask
while ALSO leaving `off` populated makes addr2 non-zero, the kernel rejects the SQE with -EINVAL, and
the completion comes back instantly carrying the correct `user_data`. That presents as a wake that
fires the moment it is armed: the poll returns, the filter correctly reports a user wake, and only
the empty inbox reveals anything is wrong. `kyte_uring_prep` now clears `off` for POLL_ADD.

Worth knowing generally — several io_uring opcodes alias fields through that union, so "set the field
the docs name" is not sufficient; the ones it overlaps have to be cleared.

## Integrated-assembly crypto (the `kyte_*` kernels)

Hand-written assembly linked straight into `libkytecore.a` and called from Kyte by symbol via
`extern("c")` — a plain `call`, no cgo/FFI marshalling. Two architectures have kernels:
`kyte_crypto_arm64.S` (ARMv8 crypto extensions) and `kyte_crypto_amd64.S` (AES-NI, PCLMULQDQ, SHA-NI, and
SSE fallbacks). `build.zig`'s `asmCryptoFor()` picks one from the RESOLVED TARGET — not `uname -m`, so a
cross build never assembles the host's asm — and the same helper decides whether to pass
`-DKYTE_ASM_CRYPTO_X86`, which is what switches `crypto.cpp` to the CPUID dispatchers.

**arm64 assumes, x86 dispatches.** Every ARMv8 part anyone runs this on has AES+PMULL+SHA2, so the arm64
file calls its instructions unconditionally. x86 cannot: AES-NI is 2010+, and SHA-NI did not reach
mainstream Intel until Ice Lake. So `kyte_crypto_amd64.S` exports FEATURE-SUFFIXED symbols
(`…_aesni`, `…_clmul`, `…_shani`, `…_sse`, `…_x64`) and `crypto.cpp` owns the CPUID logic in C, where it
is readable. `kyte_has_asm_crypto()` is therefore a RUNTIME answer on x86, gated on
AES-NI + PCLMULQDQ + SSSE3 + SSE4.1. That set is the gate because the Kyte callers share ONE gate, so
returning 1 promises that every entry point works. SHA-NI is deliberately outside it — it only selects a
faster SHA-256 kernel, and its absence must not switch off AES-GCM on the very many machines that have
AES-NI without it. `KYTE_NO_ASM_CRYPTO=1` forces the gate off (A/B measurement, or bisecting a suspected
miscompare) while leaving `kyte_cpu_has_aes()` truthful, so the fallback is Kyte's SIMD path rather than
bitsliced software.

Things that bite, recorded so they are not rediscovered:
- **`kyte_crypto_arm64.S` was Darwin-ONLY, and failed in two different ways.** It was written on an
  arm64 Mac and had never been assembled for another object format. Both problems are pure syntax —
  the instruction stream is identical everywhere — but they fail at opposite ends of the build:
  (1) it addressed its constant pools with Mach-O `sym@PAGE`/`sym@PAGEOFF`, where ELF and COFF spell
  the low half `:lo12:sym`, which is a LOUD failure (`error: invalid variant 'PAGE'`); and (2) it
  declared its entry points as `_kyte_*`, the Mach-O underscore convention that ELF and COFF-arm64
  do not use, which is a SILENT one — the file assembles perfectly and simply exports names no C
  caller ever looks up. Now conditional via `CPOOL_PAGE`/`CPOOL_LO12` and `SYM()`, the last being
  the same macro `kyte_crypto_amd64.S` already had for the same reason.
  Verified non-regressive rather than assumed: the Darwin object is byte-identical to the previous
  file (same size, identical `llvm-objdump -d`, same `_kyte_*` symbols), and the ELF/Mach-O
  relocation pairs land at identical offsets (`R_AARCH64_ADR_PREL_PG_HI21`/`ADD_ABS_LO12_NC` against
  `ARM64_RELOC_PAGE21`/`PAGEOFF12`). Not silicon-tested — there is no arm64 host here — so it stands
  exactly where SHA-NI does: encoding verified, execution unexercised.
- **`;` is a STATEMENT SEPARATOR on GNU/ELF but a COMMENT START on the Apple/Mach-O clang integrated
  assembler.** The ChaCha20 store block wrote three ops per source line, `ldr q16,[x3]; eor …; str
  q,[x5]`. On Linux/WSL (where this file was developed and gated) all three assembled; on macOS the
  assembler dropped everything after the first `;`, so the keystream was LOADED and never XORed or
  stored — `kyte_chacha20_xor` produced all-zero output, silently, on macOS ONLY. It went unseen
  because the pure-Kyte ChaCha KATs (219/220/370) drive short inputs that never reach the ≥256-byte
  fused asm path, and `445` — the first KAT straight at the ABI boundary — was added on the very
  branch that had only ever been run on Linux. Fixed by putting one instruction per line; the
  instruction stream is identical everywhere. Two lessons: (a) never use `;` to pack asm statements —
  newline-separate; (b) the "Darwin object is byte-identical" check above proves a CHANGE didn't alter
  codegen, but cannot catch a bug that predates the change and lives on Darwin all along — only an
  EXECUTION KAT on each host can, which is why 445 exists and why it must be run on macOS too, not
  just Linux/Windows. (`grep` for a `;` that precedes any `//` on a line to audit for more.)
- **An arm64 archive built WITHOUT that file is actively dangerous, not merely slow.** crypto.cpp
  compiles no portable C under `__aarch64__` (`#if !(defined(__aarch64__) ...)`) and its
  `kyte_has_asm_crypto()` returns 1 unconditionally there. So dropping the asm yields an archive that
  PROMISES hardware crypto while defining none of `kyte_aes_encrypt_block`, `kyte_sha256_blocks`,
  `kyte_ghash` … — an undefined-symbol failure at the FINAL link of any Kyte program that touches
  crypto, arbitrarily far from the cause. This is the exact inverse of the trap `asmCryptoFor`'s
  comment describes for x86 (define without object); on arm64 there is no "just omit it" option.
  Always check with `llvm-nm --defined-only <archive> | grep kyte_aes_encrypt_block`.
- **A Kyte buffer is NEVER 16-byte aligned.** `bytes.alloc(n)` is `malloc(n+8)+8` for the object header,
  so it is 16-byte aligned *plus 8*. Legacy-SSE memory operands require 16-byte alignment and fault
  otherwise — and that includes the implicit one in `pclmulqdq $0,(%rdx),%xmm4` or `paddd (%rsi),%xmm0`.
  Every load from a caller buffer must be `movdqu` into a register first. Only the file's own `.rodata`
  (`.p2align`ed) may be touched with an aligned form.
- **Two ABIs, and Windows is the awkward one.** Win64 passes rcx/rdx/r8/r9 + stack, reserves 32 bytes of
  shadow space, and makes rdi/rsi AND xmm6-xmm15 callee-saved. The `PROLOG_n`/`SAVE_XMM` macros normalise
  it to SysV so each body is written once. The stack-argument offsets in `PROLOG_5/6` are only valid
  before any other push, which is why the 8-argument `kyte_gcm_seal_aesni` spells its prologue out by
  hand rather than using a macro.
- **Windows links the runtime as a bare COFF object**, not the archive, so `kyte_crypto.o` must be
  named explicitly on the link line — `pipeline.appendRuntimeLink`, gated on the `has_asm_crypto_obj`
  build option. On macOS/Linux it simply rides along inside `libkytecore.a`. Forgetting this is an
  unresolved-symbol error, not a silent miss.
  The reason is narrower than "link.exe cannot read an archive": it cannot read **llvm-ar's GNU**
  archive. `llvm-lib` writes the COFF archive format link.exe does accept, and a `kytecore.lib` built
  that way links an executable fine (verified in `scripts/build-archives.sh`). So the bare-object
  workaround is a consequence of the ARCHIVER chosen in `build.zig`, not a hard platform limit — worth
  knowing before anyone designs around the stronger claim.
- **x86 has no per-byte bit reverse.** GHASH's "standard order" reflection is a single `RBIT` on arm64;
  here it is `BREV8`, two `PSHUFB` nibble-table lookups.
- **x86 has no SHA-512 instruction** on any mainstream part, and no SHA-256 one before Ice Lake, so both
  hashes also carry a SIMD-message-schedule + scalar-rounds kernel. That is what actually runs on
  pre-Ice-Lake hardware.
- **SHA-NI is validated but not silicon-tested.** The development host has no SHA-NI. The sequence was
  checked by emulating SHA256RNDS2/MSG1/MSG2 from the SDM pseudocode and replaying the exact macro
  sequence against the SHA-256 KATs, so the arrangement is right; only the encoding is unexercised.
  Re-run `conformance/cases/445_asm_crypto_kernels.ky` on an Ice Lake or Zen box to close that. Every
  OTHER kernel is executed and differentially checked on both ABIs — Win64 natively and SysV under WSL,
  same 3563 checks — because the ABI shim is exactly the kind of thing that passes on one and not the
  other.

Gates: `380_asm_crypto_path` (AES block vs pure-Kyte `encBlock`), `378_aesgcm_hw` (AES-GCM differential
against the independent `crypto/aead/aesgcm`), `445_asm_crypto_kernels` (FIPS 180-4 and RFC 8439 KATs
straight at the ABI boundary — the digest state is BIG-ENDIAN and the count is BLOCKS, not bytes, and
both are easy to get wrong in a way that still looks plausible).

## Status & dependencies

Master roadmap: `docs/design/execution-plan.md` (per-item design + state). Language spec: `docs/specs.md`.
Depends on **NovaDB** (separate repo); pairs with **nls** (LSP) + the VSCode **extension**.

## Planned / next work

1. ~~**All crypto hardware-asm for x86_64.**~~ DONE — see "Integrated-assembly crypto" above.
   `src/runtime/kyte_crypto_amd64.S` implements AES-NI (block, 8-way CTR, stitched GCM seal), PCLMULQDQ
   GHASH, SHA-NI SHA-256, SIMD-schedule SHA-256/SHA-512, ChaCha20 and Poly1305, all behind CPUID dispatch
   in `crypto.cpp`. Remaining headroom, deliberately not taken: Go's `blockAVX2` hashes TWO SHA-256
   blocks at once in 256-bit lanes for perhaps another 1.3x, but it is ~1100 lines of intricate register
   juggling that only pays off on multi-block input AND only on CPUs lacking SHA-NI — poor risk/reward
   against the SIMD-schedule kernel that is there now. Also open: SHA-NI has no silicon test (see above).

2. **A small CRUD web app on MSSQL** (like `kyte-pg-web` is for Postgres) to exercise the web framework
   AND the `mssql` driver end to end — scaffold with `kyte init web`, wire the `mssql` package as the
   `Connection`, run the same load/soak test. Shakes out driver + framework edges together.

3. **Orchestrator fd-handoff: verify it on io_uring.** The zero-downtime handoff passes client
   sockets over an **AF_UNIX** control channel via **`SCM_RIGHTS`** (`src/net/proxy.ky`), with the
   rendezvous under `/tmp/kyte-*.sock` — the short path is DELIBERATE (AF_UNIX `sun_path` caps at ~104
   bytes on macOS; `$TMPDIR`/`/var/folders` would overflow it, so do NOT "portably" swap `/tmp` for
   `dir.tempDir()`). It works on kqueue/epoll; what remains is verifying it on **io_uring**, where a
   proactor's in-flight ops and inherited socket state differ from a readiness engine's.

   **A Windows port is explicitly NOT planned. The handoff is POSIX-only by design.** The orchestrator
   is a Linux production concern — Windows is a development host here, the same way k8s is not a Windows
   story. A port was prototyped and then dropped, and the reason is worth keeping because it is a design
   fact rather than an effort estimate: the two mechanisms do not abstract behind one API.
   `SCM_RIGHTS` hands a descriptor to whoever holds the other end of the socket, whereas
   `WSADuplicateSocketW` prepares a duplicate **for a process named by PID**. That forces a PID
   handshake into the shared surface, makes `sendFd(sock, fd, payload)` unimplementable on Windows
   (nowhere to put the pid), and needs a second wire format because the descriptor travels as ordinary
   stream bytes rather than ancillary data. The result would be a permanently divergent protocol in
   shared code, maintained for a platform that never runs it. (All of it does *work* — AF_UNIX,
   `WSADuplicateSocketW` → `WSASocketW` across a process boundary, and overlapped `WSARecv` on AF_UNIX
   for the IOCP op were each probed successfully on Windows 10 — so this is a scope decision, not a
   blocked one.) (Audit note: the DB drivers use the target-swapped
   `os.sys` seam and the novadb server `src/` cross-builds clean for Windows — both already portable;
   this handoff is the only POSIX-locked surface.)

4. **Windows/WSL parity gates.** Mostly done, and the two headline items turned out not to be the
   real blockers:
   - `--asan` is now wired on Windows (`KYTE_ASAN=1 zig build` builds `kytecore_asan.o` in the
     PowerShell branch). See the Windows section for the `clang_rt.asan_dynamic-x86_64.dll`-on-PATH
     requirement and the `--asan`-flag-vs-env-var distinction, both of which fail confusingly.
   - The IOCP readiness cases (192/194/195) **already pass** — `iocp.ky` grew `armZeroByte`, the
     zero-byte-receive completion path this item asked for.
   - What actually blocked every gate on Windows was neither: a **Debug** build of the driver cannot
     pass the corpus at all, because `cli.run`'s leak gate exits 1 on a compiler that legitimately
     leaks. Build `-Doptimize=ReleaseFast`. Details in the Windows section.

   - `--arc` works on Windows now too, after fixing what turned out to be the same root cause in a
     different place: **the sequential harness paths ran every case in the repo root**, so each one
     reused the hardcoded `build/test/__kyte_test{,.o}`. On Windows the previous case's object or
     binary is still locked when the next link opens it, and the link fails with `LNK1104 cannot open
     file` roughly HALF the time — measured 3/6 sharing a directory against 6/6 isolated. It presents
     as a random `<compile/link error>` on an unrelated case, and because the case then never prints
     "Running N test(s)", the harness self-test trips too and aborts the run with HARNESS INTEGRITY
     BROKEN, which reads like a classifier regression rather than the file lock it is. `run_case`, the
     `--asan` sequential loop, the `--arc` loop and the self-test now each run in their own temp dir,
     the way the `-j` worker already did. That is also why the `-j` corpus was reliable while every
     sequential gate looked broken.

   The corpus itself is DONE on both hosts: Windows 442/444, Linux 443/444, the only failures being
   the two cases that cannot link off their own platform. See `win-lin-failures.md` for the per-case
   history and the five real bugs that were fixed to get there.

   Still open: **repair the driver's leak gate** (~12k live allocations across dozens of sites, so
   `zig build` + `run.sh` is red on Debug everywhere, not just Windows — almost certainly Zig-0.16 std
   drift); **regenerate `arc-baseline.txt`, which is far staler than previously recorded** (see the
   `--arc` section below — it is 109 entries against 374 cases, not the handful of missing ones this
   file used to claim, and the gate is currently noise); and decide what an
   **out-of-range `int` constant** should do (see `189_epoll_event_layout` above — `const X: int =
   2147483648` is today neither truncated nor rejected, it is silently carried at 64 bits, so the
   constant disagrees with its own 32-bit round trip). That last one is a spec question first.
