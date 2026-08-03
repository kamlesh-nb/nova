# Nova Stdlib Restructure Plan -- platform-axis folders (os/arch)

Status date: 2026-08-03
Owner: language/stdlib
State: PLANNED (not started). No files moved yet.

## Problem

Target-varying stdlib code is encoded with filename suffixes/prefixes and a flat `os/` directory,
and the compiler selects files by a bespoke `_<os>` string scan that is disconnected from the
`platform` module. It reads as naive and does not scale:

- Suffix variants: `os/sys.nova` + `os/sys_windows.nova`, `os/socket.nova` + `os/socket_windows.nova`,
  `os/backend_{darwin,linux,windows}.nova`, `net/eventloop_{darwin,linux,windows}.nova`.
- Win-prefix single-OS modules: `os/windows.nova`, `os/winfs.nova`, `os/winproc.nova`, `os/winsock.nova`.
- Flat single-OS syscall wrappers: `os/kqueue.nova` (darwin), `os/epoll.nova` (linux).

Two concrete defects (the reason for this rewrite):
1. Selection keys on `os` ONLY, never `arch`. The moment we need aarch64-vs-x86_64 syscall numbers,
   struct layouts, or SIMD, the suffix scheme cannot express it. Arch is handled today only in the
   build/link layer (`main.zig` triple selection), disconnected from stdlib file selection.
2. The `_<os>` scan is a SECOND representation of "what target is this," able to drift from the
   `platform` module, which is the real target-identity model.

Goal: replace the suffix/prefix scheme with a `platform`-axis variant resolver -- os first, arch as an
optional second axis -- backed by directories, with `platform` as the single source of truth.

## Single source of truth: the `platform` module (already built)

`platform` is a real, compiler-SYNTHESIZED module (`genPlatformSource`, `main.zig:326-348`) -- generated
in memory per target, never a file on disk. It already exposes both axes:

```
platform.os          // "darwin" | "linux" | "windows" | "wasm"
platform.arch        // "aarch64" | "x86_64" | "wasm32"
platform.pointerSize
platform.isDarwin / isLinux / isWindows / isWasm / isPosix
```

It is live: `os/socket.nova:21-23` uses `platform.isLinux` to pick the darwin-vs-linux errno/sockopt
constants inside ONE shared file. The variant resolver must derive its target axes from these SAME
values, so there is exactly one notion of the target.

## Two mechanisms, kept distinct (do not conflate)

- `platform.*` in-code conditionals -- for divergences where EVERY branch compiles AND links on EVERY
  target (integer constants, small branches). Example: `os/socket.nova` is a single file for both POSIX
  targets, switching constants with `if platform.isLinux`.
- Whole-file variant selection -- MANDATORY where the branches cannot coexist in one translation unit.
  The decisive reason is FFI: an `extern` symbol absent on the target is a hard LINK error, not a dead
  branch (see the LLVMInitialize / reduced-target trap in `lang/CLAUDE.md`). `os/sys` binds
  `CreateProcessW`/`WSAStartup` on Windows and `fork`/`socket` on POSIX; those extern sets can never sit
  in one file behind an `if`. So `platform.*` conditionals CANNOT replace whole-file selection for
  divergent-extern modules -- both mechanisms are needed, for different jobs.

## Design: platform-axis variant resolver

One rule, `resolvePlatformVariant(module, os, arch)`, derives an ordered candidate search from the
platform axes and returns the first file that exists (most specific wins). For an import `dir/name`
(e.g. `os/sys`):

1. `dir/<os>/<arch>/name.nova`   (os + arch specific; e.g. `os/linux/aarch64/sys.nova`)
2. `dir/<os>/name.nova`          (os specific;        e.g. `os/windows/sys.nova`, `os/linux/backend.nova`)
3. `dir/posix/<arch>/name.nova`  (posix-family + arch; only when `isPosix`)
4. `dir/posix/name.nova`         (posix-family shared; only when `isPosix`; e.g. `os/posix/sys.nova`)
5. `dir/name.nova`               (flat base; back-compat fallback)

The MODULE IDENTITY stays the base import name (`os.sys`), independent of which file compiled, so
`import os.sys;` links on every target and its importers never change. Properties:
- 2-way modules (sys, socket): a shared `posix/` file (rule 4) serves darwin+linux; a `windows/` file
  (rule 2) serves windows. No darwin/linux files needed.
- 3-way modules (backend, eventloop): a per-os file each under `<os>/` (rule 2); no posix fallback used.
- Arch axis (rules 1, 3): available now, unused today; aarch64-vs-x86_64 divergence gets a home without
  another redesign. `platform.arch` is the key.
- "posix" is the family fallback the folder layout centers on; per-os folders OVERRIDE it (rule 2 before
  rule 4), so a linux-specific override coexists with the shared posix default.

OS-specific modules that are NOT variants of a shared name (raw syscall wrappers, Win32 FFI) do NOT use
the resolver; their OS is part of the import path (`import os.linux.epoll`, `import os.windows.win32`),
and they are only ever imported by matching-os code, so their platform-specific externs never reach the
wrong target.

## Constraint: epoll and io_uring are both Linux, selected at RUNTIME

`eventloop_linux.nova` holds BOTH the epoll and io_uring paths and dispatches per call via
`usingUring()` / `nova_reactor_backend()` (`eventloop_linux.nova:85,401`; runtime `uring.cpp:295`). They
are not compile-time-separable by target. To give io_uring its own file, the Linux eventloop VARIANT
becomes a thin selector that imports BOTH `net/ev/epoll` and `net/ev/io_uring` and runtime-dispatches.
Mechanism impls live in `net/ev/` by name (readability); the os-variant `net/eventloop` selects them.
(Alternative: leave io_uring inside `ev/epoll.nova` -> 3 files, no linux selector. Rejected: does not
match the requested four-file layout.)

## Target tree

```
src/std/os/
  posix/                shared non-windows variant impls (rule 4)
    sys.nova            (was os/sys.nova)
    socket.nova         (was os/socket.nova)
  windows/              windows variant impls (rule 2) + windows-only modules
    sys.nova            (was os/sys_windows.nova)
    socket.nova         (was os/socket_windows.nova)
    win32.nova          (was os/windows.nova    -- Win32 FFI)
    fs.nova             (was os/winfs.nova)
    proc.nova           (was os/winproc.nova)
    winsock.nova        (was os/winsock.nova     -- raw WinSock FFI; distinct from windows/socket.nova)
  darwin/               darwin-only modules (path-qualified, not variant-resolved)
    kqueue.nova         (was os/kqueue.nova)
    backend.nova        (was os/backend_darwin.nova)   [or folded into net/ev/kqueue -- see R0]
  linux/                linux-only modules
    epoll.nova          (was os/epoll.nova)
    backend.nova        (was os/backend_linux.nova)    [or folded -- see R0]
  # os/windows/backend.nova (was backend_windows) likewise per R0

src/std/net/
  ev/                   event-loop backend impls, named by mechanism (path-qualified, not resolved)
    kqueue.nova         (was net/eventloop_darwin.nova)
    epoll.nova          (was net/eventloop_linux.nova, epoll path)
    io_uring.nova       (split out of net/eventloop_linux.nova, io_uring path)
    iocp.nova           (was net/eventloop_windows.nova)
  darwin/eventloop.nova   (NEW selector: re-exports net.ev.kqueue)
  linux/eventloop.nova    (NEW selector: imports net.ev.epoll + net.ev.io_uring, runtime dispatch)
  windows/eventloop.nova  (NEW selector: re-exports net.ev.iocp)
```

Import names that DO NOT change (resolver-only): `os.sys`, `os.socket`, `net.eventloop`.
Import names that DO change (path now carries the os/mechanism): `os.kqueue` -> `os.darwin.kqueue`,
`os.epoll` -> `os.linux.epoll`, `os.windows`/`winfs`/`winproc`/`winsock` -> `os.windows.{win32,fs,proc,winsock}`,
`os.backend` -> per R0, and the eventloop backends are now `net.ev.{kqueue,epoll,io_uring,iocp}`.

## Compiler changes (src/main.zig)

1. Replace `targetSuffixedPath` (`main.zig:371`, the `_{os_tag}` scan) with `resolvePlatformVariant`
   implementing the 5-rule os+arch search above. It takes `tinfo.os` AND `tinfo.arch` (the same values
   fed to `genPlatformSource`), so the resolver and the `platform` module share one target definition.
   Keep the base-file fallback (rule 5) so un-migrated modules still resolve during the transition.
2. Update `resolveImportPath` + the hardcoded `std_modules` allow-list (`main.zig:390`): the
   resolver-only variant modules (`os/sys`, `os/socket`, `net/eventloop`) keep their names; remove the
   old flat/suffix/win entries; add the new path-qualified module names (`os/darwin/kqueue`,
   `os/linux/epoll`, `os/windows/win32`, `os/windows/fs`, `os/windows/proc`, `os/windows/winsock`,
   `net/ev/kqueue`, `net/ev/epoll`, `net/ev/io_uring`, `net/ev/iocp`).
3. `genPlatformSource` is unchanged (already emits os+arch); it becomes the documented single source of
   truth the resolver keys off. Add a comment cross-linking the two.
4. `build.zig` copies `src/std` wholesale, so nested folders carry automatically -- verify (R23).

## Blast radius (importers to update)

Measured 2026-08-03 (stdlib + packages):
- `os.sys` 9, `os.socket` 5, `net.eventloop` 2 -> NO import-name change (resolver-only). Zero edits.
- `os.kqueue` 1, `os.epoll` 1 -> `os.darwin.kqueue` / `os.linux.epoll`.
- `os.windows` 1, `os.winfs` 2, `os.winproc` 1, `os.winsock` 3 -> `os.windows.*`.
- `os.backend` 3 -> per R0.
Plus internal cross-imports among the moved files; update in lockstep. Package repos importing these
(drivers, orchestrator) bump alongside, same as the earlier net rename.

## Master tracking table

Legend: [ ] not started, [~] in progress, [x] done.

| # | Item | From | To / Action | Kind | Status |
|---|---|---|---|---|---|
| R0 | Decide os.backend: fold identity into net/ev/* vs keep slim per-os `os/<os>/backend.nova` | -- | Phase 0 decision | design | [ ] |
| R1 | Compiler: `resolvePlatformVariant(os,arch)` 5-rule resolver, keyed off the same axes as `platform` | `targetSuffixedPath` main.zig:371 | replace | compiler | [ ] |
| R2 | Compiler: update `resolveImportPath` + `std_modules` allow-list | main.zig:390 | edit | compiler | [ ] |
| R3 | genPlatformSource: document as single source of truth; cross-link resolver | main.zig:326 | docs | compiler | [ ] |
| R4 | Move os.sys posix impl | os/sys.nova | os/posix/sys.nova | move | [ ] |
| R5 | Move os.sys windows impl | os/sys_windows.nova | os/windows/sys.nova | move | [ ] |
| R6 | Move os.socket posix impl | os/socket.nova | os/posix/socket.nova | move | [ ] |
| R7 | Move os.socket windows impl | os/socket_windows.nova | os/windows/socket.nova | move | [ ] |
| R8 | Move darwin syscalls | os/kqueue.nova | os/darwin/kqueue.nova | move | [ ] |
| R9 | Move linux syscalls | os/epoll.nova | os/linux/epoll.nova | move | [ ] |
| R10 | Move Win32 FFI | os/windows.nova | os/windows/win32.nova | move+rename | [ ] |
| R11 | Move Windows fs | os/winfs.nova | os/windows/fs.nova | move+rename | [ ] |
| R12 | Move Windows proc | os/winproc.nova | os/windows/proc.nova | move+rename | [ ] |
| R13 | Move WinSock FFI | os/winsock.nova | os/windows/winsock.nova | move | [ ] |
| R14 | Move os.backend (per R0) | backend_{darwin,linux,windows}.nova | os/<os>/backend.nova or net/ev/* | move | [ ] |
| R15 | Move kqueue eventloop backend | net/eventloop_darwin.nova | net/ev/kqueue.nova | move+rename | [ ] |
| R16 | Move epoll eventloop backend | net/eventloop_linux.nova (epoll path) | net/ev/epoll.nova | move+split | [ ] |
| R17 | Split io_uring backend out | net/eventloop_linux.nova (uring path) | net/ev/io_uring.nova | split | [ ] |
| R18 | Move iocp eventloop backend | net/eventloop_windows.nova | net/ev/iocp.nova | move+rename | [ ] |
| R19 | Create per-os eventloop selectors | -- | net/{darwin,linux,windows}/eventloop.nova | new | [ ] |
| R20 | Update importers of os.kqueue/os.epoll | 2 files | os.darwin.* / os.linux.* | edit | [ ] |
| R21 | Update importers of os.win* | ~7 files | os.windows.* | edit | [ ] |
| R22 | Update importers of os.backend | 3 files | per R0 | edit | [ ] |
| R23 | build.zig: verify std sync carries nested folders | build.zig | verify/patch | build | [ ] |
| R24 | Update internal cross-imports among moved files | moved files | new paths | edit | [ ] |
| R25 | Update docs referencing old paths/suffix rule | CLAUDE.md, specs, design docs | edit | docs | [ ] |
| G1 | Gate: `zig build` clean (host = darwin) | -- | run | gate | [ ] |
| G2 | Gate: `conformance/run.sh -j` 230/230 | -- | run | gate | [ ] |
| G3 | Gate: cross-compile linux x86_64 + windows-x86_64 still link | -- | `nova x --target ...` | gate | [ ] |
| G4 | Gate: reactor cases 192-210 green (darwin) | -- | run | gate | [ ] |
| G5 | Gate: residual sweep -- no `_darwin`/`_linux`/`_windows`/`win*` paths or old imports remain | -- | grep | gate | [ ] |
| G6 | Gate: arch axis proof -- a throwaway `os/linux/aarch64/probe.nova` resolves over `os/linux/probe.nova` | -- | targeted build | gate | [ ] |

## Phasing

- Phase 0: R0 decision; confirm build.zig folder handling (R23); land R1 with rules 1-5 but keep every
  old flat/suffix file in place (rule 5 fallback) so nothing breaks mid-move. Gate G1 + G6 (prove the
  os+arch resolver works before any move).
- Phase 1 (os folders): R4-R13 + R20-R21 + R24. `git mv` per cohesive group (sys, socket, single-os,
  win*), rebuild + G1/G2 after each. Low risk: darwin runtime behavior unchanged; windows is
  cross-compile-only (verify via G3).
- Phase 2 (net/ev): R14-R19 + R22 + R24. Highest risk -- the io_uring split (R17) + selectors (R19)
  touch the reactor hot path. G4 (reactor cases) + G2. Linux epoll/io_uring + windows iocp are
  cross-compile-verified (G3) until run on those hosts.
- Phase 3: R25 docs + G5 residual sweep; drop the rule-5 flat fallback once every variant module has
  moved into a folder.

## Risks

- io_uring split (R17) + selectors (R19) change how the Linux reactor picks a backend; a mistake
  regresses throughput or deadlocks the reactor, and cannot be run-verified on the darwin dev host
  (relies on G3 link checks + the Linux CI cell). Do R16/R17/R19 as the smallest possible diff and keep
  the `nova_reactor_backend()` runtime contract byte-identical.
- The resolver change (R1) affects EVERY os.* import; a wrong candidate order silently compiles the
  wrong-target file. G5 (residual grep) + G2 + G3 must all pass before removing the rule-5 fallback.
- Do not let the resolver and `genPlatformSource` diverge: both must read `tinfo.os`/`tinfo.arch`. R3
  documents this so a future arch change updates one definition, not two.

## Relationship to other plans

Orthogonal to `std-lib-driver-prod-readiness.md` (functional gaps in drivers + stdlib). No dependency
either way; can proceed independently.
