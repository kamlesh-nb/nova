# Gap 7 -- Cross-platform completeness (deep, honest analysis)

Scope: native macOS / Linux / Windows, cross-compilation, and WASM. Verified against
`lang/src/pipeline.zig`, `lang/src/backend/codegen/*`, `lang/src/frontend/*`,
`lang/src/runtime/concurrency.cpp`, `lang/src/lib/std/net/ev/*`, and the conformance harness.

**Host used for verification: macOS (arm64, Darwin 24.6.0), Zig 0.16.0, prebuilt `~/.kyte/bin/kyte`.**
Everything marked "verified here" was actually run on this box. Everything marked "documented,
host-dependent" could NOT be re-verified (no Linux/Windows host, no CI on other OSes here) and is
taken from CLAUDE.md / code inspection with that caveat stated.

Headline number in the brief was "~70%". After verification I would put native + cross at ~90%
solid, and WASM at a genuine "best-effort" that is better than the stale baseline implies but still
excludes the entire runtime-touching half of the language. The 70% aggregate is fair only if WASM is
weighted heavily.

---

## 1. Gap (assessed) -- per target

### 1a. macOS native (arm64) -- WORKS, verified here
- `kyte m.ky -o mn` produced a `Mach-O 64-bit executable arm64`, ran, exit 0. **Verified here.**
- Default build links the ASAN runtime (`Native output written to mn (ASAN)`), i.e. the dev default
  on this host is an ASAN build. Reactor backend = kqueue (`platform.os == "darwin"`,
  `pipeline.zig:459`).
- Corpus on macOS/kqueue: the project's normal gate. Not re-counted here end-to-end, but individual
  cases compiled and the harness exists (`conformance/run.sh`).
- **Open on macOS: essentially none at the target level.** This is the primary, best-supported host.

### 1b. Linux native (x86_64/arm64) -- cross-EMIT verified here; run + gate host-dependent
- `kyte m.ky --target linux-x86_64 -o ml` produced a **statically-linked ELF x86-64** and
  triggered a one-time cross-compile of the C++ runtime to `x86_64-linux-musl`
  (`~/.kyte/lib/kytecore_x86_64-linux-musl.o`, confirmed present, 2.1 MB). **Verified here (emit).**
- `mapCrossTarget` (`pipeline.zig:139-140`) maps linux triples to `x86_64/aarch64-linux-musl`,
  `static = true`. `-no-pie` applied on Linux hosts (`pie_flags`, `pipeline.zig:25`).
- Reactor: epoll is the default on Linux, with io_uring behind `KYTE_REACTOR=uring` + a runtime
  probe (CLAUDE.md reactor table). Throughput figures (75.6k rps epoll, ~65k io_uring on a WSL2
  4-core box) are **documented, host-dependent, not re-verified here.**
- **KEY FINDING -- the CLAUDE.md "Still open" item 3 is STALE.** CLAUDE.md (dated 2026-07-31) says
  "Linux still aborts in `kyte_run_root` -- it needs the epoll driver." The code disproves this:
  `src/runtime/concurrency.cpp:1016` `kyte_run_root` now branches
  `#if KYTE_HAVE_KQUEUE / #elif KYTE_HAVE_IOCP / #elif KYTE_HAVE_EPOLL / #else abort`. The epoll
  driver EXISTS (`#include <sys/epoll.h>`, `KYTE_HAVE_EPOLL` support block from line ~120, timerfd +
  eventfd wake). So async programs no longer abort on Linux at the driver level. Whether the full
  async corpus passes on a Linux host is documented (Linux/epoll 225-passing table) and
  **not re-verified here.**

### 1c. Windows native -- cross-EMIT verified here; native build + run host-dependent
- `kyte m.ky --target windows-x86_64 -o mw.exe` produced a real **PE32+ executable (console)
  x86-64**, cross-compiling the runtime to `x86_64-windows-gnu`
  (`~/.kyte/lib/kytecore_x86_64-windows-gnu.o`, present, 1.27 MB). **Verified here (emit).**
- Cross link adds the Windows system libs and drives the gnu path; `mapCrossTarget` returns
  `x86_64-windows-gnu`, `static = false` (`pipeline.zig:142`). On a genuine Windows HOST the build
  drives MSVC `link.exe` (`/OPT:REF`, COFF runtime object, `-rtlib=compiler-rt`) -- that path is in
  `pipeline.zig` (`.windows` branches at 31, 80, 241) but is **documented, not exercised here.**
- Native `zig build` on a Windows host, run-verified reactor (IOCP), Win32-FFI syscall modules
  (`os/windows/{fs,proc,winsock,sys}`), WSAStartup, ConnectEx via `WSAIoctl`: all **documented,
  host-dependent, not re-verifiable here.**
- Reactor: IOCP, completion/proactor model (`pipeline.zig:459` selects `iocp` for `os == "windows"`).

**Open items on Windows:**
1. **Readiness cases 192/194/195** (`192_reactor_echo`, `194_coroutine_reactor`,
   `195_multicore_reactors`). CLAUDE.md "Still open" item 1 says `armRead`/`armWrite` have no IOCP
   analogue. **Partially stale in code:** `src/lib/std/net/ev/iocp.ky:263-264` now implement
   `armRead`/`armWrite` via `armZeroByte(...)` (the zero-byte-receive readiness trick the reactor
   section describes as done). So the readiness *primitive* exists. Whether cases 192/194/195
   actually PASS on a Windows host is **not re-verifiable here** and there is a documentation gap
   (see next point).
2. **`conformance/windows-baseline.txt` is referenced but DOES NOT EXIST in the repo.** CLAUDE.md:75
   points to it for the Windows corpus; `ls` confirms it is absent. So the Windows pass/fail set is
   not tracked in-tree -- the "224/234 on Windows" figure lives only in prose, un-gated. Real gap.
3. **`--asan` / `--arc` gates not wired on Windows** (install step skips those runtimes). Documented;
   plausible given `~/.kyte/lib` only caches `kytecore_asan.o` for the host, not per-cross-target.
   Not re-verifiable here.

### 1d. Cross-compilation (from macOS) -- WORKS, verified here
- All three cross targets (linux-x86_64, windows-x86_64, native) emitted correct binaries in one
  session (see 1b/1c). The runtime is cross-compiled once per target via bundled `zig c++`
  (`crossLinkViaZig`, `pipeline.zig:164-201`) and cached in `~/.kyte/lib`. **Verified here.**
- arm64 variants (`aarch64-linux-musl`, `aarch64-windows-gnu`) are in `mapCrossTarget` but were not
  emitted in this session -- **documented, not re-verified here.**
- This is the strongest cross-platform story: from one macOS host you get ELF, PE32+, and Mach-O.

### 1e. WASM -- BEST-EFFORT, verified here (and better than the baseline implies)
- `kyte m.ky --wasm -o m.wasm` produced a valid `WebAssembly (wasm) binary module version 0x1
  (MVP)`, magic `\0asm`. **Verified here.** Target triple `wasm32-unknown-unknown`
  (`llvm_codegen.zig:252-253`), ptr size 4, `is_posix = false` (`pipeline.zig:359-360`). Link via
  in-process `wasm-ld` with `--no-entry --export-all --allow-undefined --initial-memory=128MiB`
  (`pipeline.zig:212`).
- **The baseline UNDERSTATES real wasm coverage.** `wasm-baseline.txt` lists 104 of 321 corpus cases
  (32%); 217 are "skipped". But the baseline is explicitly a ratchet ("a case that now compiles is a
  bonus, asks you to add it") and is under-maintained: I compiled several *un-listed* cases to valid
  wasm here -- `215_sha256_kyte`, `266_exception`, `337_module_private`, `261_simd_f64x4`,
  `336_tuple_dot_index` all emitted WebAssembly. So the pure-computation surface that actually
  compiles to wasm is materially larger than 104. **Verified here.**
- **What wasm genuinely does NOT support** (verified here via the diagnostics):
  - **async / await / spawn / actors** -- hard-rejected with a principled diagnostic:
    `'async fn ...' is not available on the wasm target -- async has no coroutine runtime in wasm`
    (`type_checker.zig:389/916/929/1475/1589`). Confirmed on `10_async_go` and `118_actor`.
    Codegen also gates: `is_async_native = func.is_async and !is_wasm`
    (`declarations.zig:845`).
  - **native-only runtime symbols** -- `82_ffi_extern` failed with `'abs' is native-only and not
    available on the wasm target (it resolves to a native runtime symbol with no wasm host import)`;
    `163_process` failed on `kyte_process_spawn`. Verified here.
  - **networking / sockets / sys** -- `os/socket`, `os/sys` resolve to native-only modules; wasm
    builds cannot pull them (`62_socket_send_n`, `192_reactor_echo` failed). Verified here.
  - **SIMD degrades to scalar** -- `simd_target = .none` for wasm (`llvm_codegen.zig:350`); the
    vectorised paths have no wasm-SIMD lowering, they fall back.
- **The `@native { ... }` / `@wasm { ... }` escape hatch is REAL but UNUSED.** The parser handles
  both block forms at declaration and statement scope (`parser.zig:238-240`, `1215-1217`, keyed off
  `self.is_wasm`), and the error messages point users to it. But `grep` finds **zero** `@native`/
  `@wasm` blocks in the stdlib (`src/lib/std/`). So the mechanism to provide a wasm alternative
  exists syntactically, yet no stdlib module actually ships a wasm path. Concretely: any program that
  imports async, networking, process, or most of the runtime cannot compile to wasm today, and the
  stdlib gives it no wasm fallback to lean on.
- **There is no production wasm host.** `--allow-undefined` turns unresolved runtime calls into host
  imports (`env.*`). The only implementation of those imports is the **test harness**
  `conformance/wasm-run.mjs` (~35 `env.*` functions: `kyte_bytes_alloc`, `kyte_test_fail`, decimal
  helpers, etc.), used by `run.sh --wasm-run` under Node. That is enough to *execute pure-Kyte @tests*
  under Node, not to run a real wasm application against a browser/WASI host.

---

## 2. Root cause / why incomplete (from code)

- **WASM has no coroutine runtime.** async in Kyte is LLVM coroutines lowered by CoroSplit into a
  native scheduler (`concurrency.cpp`). wasm32-unknown-unknown has no thread/coroutine driver and no
  `kyte_run_root` peer, so async is rejected at type-check rather than mis-compiled. This is a
  *correct* fail-closed choice, not a bug -- but it means the concurrency half of the language is
  simply absent on wasm.
- **WASM has no host ABI for I/O.** The target is `unknown-unknown` (not WASI), `is_posix = false`,
  and native runtime symbols (sockets, process, filesystem, even `abs`) have no wasm import binding.
  Anything touching the runtime resolves to an undefined symbol → rejected. The stdlib was written
  native-first and never grew `@wasm` alternatives, so the escape hatch has nothing to escape to.
- **Proactor readiness (Windows/IOCP, Linux/io_uring) is fundamentally awkward.** A proactor gives
  you "tell me when this operation completed", not "tell me when this fd is readable". The zero-byte
  receive trick (`armZeroByte` in `iocp.ky`) synthesises a readiness edge from a completion -- it
  works but is why `armRead`/`armWrite` needed bespoke Windows code and why cases 192/194/195 lagged.
- **`kyte_run_root` is per-OS by construction.** Each reactor model needs its own driver
  (kqueue/IOCP/epoll). The `#else abort` fallback is why any *new* target starts life aborting until
  someone writes its driver -- this is the shape that produced the (now-stale) "Linux aborts" note and
  would recur for, say, FreeBSD or WASI-threads.
- **Windows corpus isn't tracked in-tree** (`windows-baseline.txt` absent), so Windows regressions
  cannot be caught by a bare clone; the number lives in prose only.

---

## 3. Design to close (PLAN -- confidence + unknowns)

### P-1. Ship the Windows baseline file (item 1c-2)
- Plan: commit `conformance/windows-baseline.txt` (and the `--asan`/`--arc` skip list) generated on
  the Windows host, exactly like `wasm-baseline.txt`.
- Confidence: **high** (it is a data file + a `run.sh` read). Unknown: needs one clean run on a real
  Windows host to author it honestly.

### P-2. Confirm/close readiness cases 192/194/195 on Windows (item 1c-1)
- Plan: the primitive already exists (`armZeroByte`); run the three cases on a Windows host, and if
  green, add them to the Windows baseline; if not, the failure is now in the *drain* path, not the
  arm path.
- Confidence: **medium** -- code suggests done, but proactor readiness has a history of "looks armed,
  never fires" bugs (the abandoned-op / recycled-frame classes in CLAUDE.md). Unknown: only a Windows
  run settles it.

### P-3. Wire `--asan`/`--arc` on Windows (item 1c-3)
- Plan: build the ASAN/ARC runtime variants in the PowerShell install step (the host already builds
  `kytecore_asan.o` on macOS/Linux). Mostly a build-graph addition.
- Confidence: **medium**. Unknown: MSVC ASAN interop with the existing link line (`/OPT:REF`,
  compiler-rt) may need flag work; clang-cl `-fsanitize=address` vs MSVC `link.exe` is finicky.

### P-4. Give WASM a real host path (the big one)
- Two independent sub-goals, pick per intent:
  - **(a) WASI target.** Switch/allow `wasm32-wasi`, map file/clock/random to WASI imports, so
    non-async server-ish code runs under wasmtime. Grows the compilable set toward the pure-stdlib
    surface.
  - **(b) `@wasm` stdlib alternatives.** Author `@wasm { ... }` bodies for the leaf modules people
    actually want in a browser (json, collections, crypto-hash, string). The compiler support is
    already there; this is stdlib authoring.
- Confidence: **medium-low** on effort predictability. Unknowns: async-on-wasm would need
  Asyncify or the JS-Promise-Integration proposal -- both are real projects, out of scope for
  "best-effort"; networking in a browser means fetch/WebSocket host imports, a design not started.

### P-5. Generalise the reactor-driver seam
- Plan: make `#else abort` in `kyte_run_root` the *only* place a new target is missing, and document
  `KYTE_HAVE_*` as the template (CLAUDE.md already frames IOCP as the template). No code change
  needed today; it is a documented extension point.
- Confidence: **high** as documentation; **low** value until a 4th native target is actually wanted.

---

## 4. Risk + effort (guess, labelled -- not measured)

| Item | Effort (guess) | Risk (guess) | Note |
|---|---|---|---|
| P-1 Windows baseline file | S (hours) | Low | Needs a Windows host to author honestly |
| P-2 Confirm 192/194/195 | S-M | Medium | Proactor readiness has a bug history; a run may reopen it |
| P-3 `--asan`/`--arc` on Windows | M (days) | Medium | MSVC/clang-cl sanitizer link interop unknown |
| P-4a WASI target | M-L (days-weeks) | Medium | New target plumbing + import mapping |
| P-4b `@wasm` stdlib bodies | M, ongoing | Low | Mechanism exists; per-module authoring grind |
| P-4 async-on-wasm | L (weeks+) | High | Needs Asyncify/JSPI; explicitly beyond "best-effort" |
| P-5 reactor seam doc | S | Low | Documentation only |

All effort/risk labels are engineering guesses, not benchmarked estimates.

---

## 5. Verify -- the gate per platform

- **macOS / kqueue** (verified reachable here): `cd lang/conformance && ./run.sh` -- the primary gate;
  `./run.sh --asan` is the memory gate (ASAN is the authority per CLAUDE.md, "verify with --asan not
  --arc"). ASAN runtime present at `~/.kyte/lib/kytecore_asan.o`.
- **Linux / epoll** (documented, host-dependent): same `./run.sh` inside WSL2/Linux; io_uring via
  `KYTE_REACTOR=uring ./run.sh`. Documented pass set: 225 (epoll and io_uring identical failure list).
  Structural fails: 8 DB/codec cases (need `packages/`), `189_epoll_event_layout` (asserts epoll
  layout, passes only on Linux). `kyte_run_root` epoll branch confirmed in code, so async cases are
  expected to run -- not re-verified here.
- **Windows / IOCP** (documented, host-dependent, and UNDER-GATED): CLAUDE.md cites 224-passing, but
  `conformance/windows-baseline.txt` is **absent from the repo** -- there is no in-tree gate. Author it
  (P-1) before trusting the number. `188_kqueue_readiness` is inapplicable off macOS by design.
- **Cross-compile** (verified here): the emit gate is `kyte <case> --target <triple> -o out` +
  `file out` shows the right container. All three ran clean here. No execution gate for cross targets
  on a foreign host from macOS (you can build a PE/ELF but not run it here).
- **WASM** (verified here): `./run.sh --wasm` compiles+links every case, baseline-gated against
  `conformance/wasm-baseline.txt` (104 cases); `./run.sh --wasm-run` additionally EXECUTES @tests
  under Node via `conformance/wasm-run.mjs`, gated against `wasm-run-baseline.txt` (92 cases). Both
  files exist and are real. The gate ratchets up; async/networking/process cases are intentionally
  excluded, not regressions.

---

### Corrections to CLAUDE.md found during verification
1. "Linux still aborts in `kyte_run_root`" (Still-open item 3) is **stale** -- the `KYTE_HAVE_EPOLL`
   branch exists in `concurrency.cpp:1016+`.
2. "Readiness cases 192/194/195 have no IOCP analogue" (Still-open item 1) is **partially stale**  -- 
   `iocp.ky:263-264` implement `armRead`/`armWrite` via `armZeroByte`; only their pass/fail on a
   Windows host is genuinely open.
3. `conformance/windows-baseline.txt` is referenced (CLAUDE.md:75) but **does not exist** -- the
   Windows corpus is not gated in-tree.
4. The wasm `wasm-baseline.txt` (104) **understates** what compiles; multiple unlisted pure-compute
   cases emit valid wasm today.
