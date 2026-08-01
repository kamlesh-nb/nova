# The OS abstraction layer: one blessed path, POSIX and Windows behind it

Status: DESIGN (analysis + cleanup plan). Written 2026-08-01 in response to the observation that
`declarations.zig` and the stdlib carry different names for the same OS operation. Implementation is
gated behind the current Windows/WSL bring-up (that testing tells us which Windows externs are actually
exercised before we lock the surface). Language and compiler work outrank this; schedule it deliberately.

## 1. The concern, stated precisely

Nova reaches the operating system through TWO mechanisms that grew in parallel:

- MECHANISM A (compiler ABI): about 130 `nova_*` extern symbols listed in `src/codegen/declarations.zig`,
  registered as builtins in `src/sema/builtins.zig`, implemented in the C++ runtime `src/runtime/*.cpp`.
  A Nova program calls these by bare name with no `extern` declaration; the compiler wires them.
- MECHANISM B (stdlib FFI): `extern("c") fn ...` declared directly in `src/std/os/*.nova`, both raw
  POSIX/Win32 names (`close`, `read`, `write`, `socket`, ...) and a few residual `nova_*` shims. Per-OS
  variants are selected by a whole-file swap in `src/main.zig` (`targetSuffixedPath`, main.zig:371): when
  the build target is Windows, a read of `os/sys.nova` transparently returns `os/sys_windows.nova` while
  the module identity stays `os.sys`, so importers are unchanged.

The complaint is correct: the SAME operation can have a name in A and a different name in B. The concrete
example is `nova_close` (A) versus `close` (B). That is a genuine smell.

## 2. The honest scope: this is nearly solved already

The map (whole-repo survey, 2026-08-01) shows the historical direction is one-way: milestones M5
(file/dir I/O), M6 (process/env/reuseport), M13 (TLS), and M14.2 (blocking sockets) moved almost all OS
reach OUT of Mechanism A and INTO Mechanism B. What remains of the divergence is a small residue, not a
pervasive problem:

- Exactly ONE surviving true A-vs-B name pair for a live operation: `nova_close` versus `close`, and the
  A side (`nova_close`) is DEAD (zero Nova callers; every close goes through the raw `close` extern via
  `sys.close`). Its runtime justification comment (core.cpp:525-528) is stale: it claims the tcp stack
  cannot import os/sys, but the M6 `os/socket` split happened and `net/tcp/stream.nova` uses
  `socket.close`.
- One more dead orphan with no pair: `nova_fs_watcher_free_event` (declarations.zig:402, a no-op in
  io.cpp:411, not even registered as a builtin, no caller).
- Everything else in Mechanism A that touches the OS is either genuinely live and correct (the reactor
  families `nova_reactor_*`/`nova_uring_*`/`nova_epoll_*`/`nova_op_*`, `nova_process_*`, `nova_getrandom`,
  `nova_set_nonblock`, `nova_ffi_errno`) or already retired and gone (`nova_getenv`/`nova_setenv`,
  `nova_set_reuseport`, `nova_gzip_*`, `nova_file_*`/`nova_dir_*`, `nova_socket_*`, the wolfSSL `nova_tls_*`
  family). `nova_open` is deliberately A-only (it is variadic; there is no raw `open` extern).

So the fix is a small, precise cleanup plus a written rule, not a rewrite.

## 3. The blessed layering rule (the "API layer" being asked for)

The layer the user wants already exists in shape; this makes it THE rule and the exclusive path.

RULE. Every operating-system syscall is reached through the Nova-level `os` modules (`os.sys`, `os.socket`),
which are the single blessed API layer. Each has a POSIX base file and a `_windows` swap file selected by
`targetSuffixedPath`; both files expose an IDENTICAL public surface, so no caller and no other stdlib
module ever needs to know which OS it is on. The compiler ABI (`declarations.zig`, Mechanism A) is reserved
for things that CANNOT be a plain FFI binding, namely:

  1. The ARC/allocator seam (`nova_bytes_alloc`, refcount ops) - compiler-emitted by contract.
  2. The scheduler / coroutine / reactor seam (`nova_reactor_*`, `nova_uring_*`, `nova_op_*`,
     `nova_epoll_*`, the async channel) - these hold runtime state and are the ABI codegen emits around
     `llvm.coro.*`.
  3. Compiler-internal entry/exit and audit (`nova_exit`, `nova_arc_audit_report`) - emitted into the
     generated `main`.
  4. A short, documented list of runtime-owned primitives that need per-thread or init state and so cannot
     be a naive C binding: `nova_ffi_errno`/`nova_ffi_set_errno` (errno is a per-thread macro),
     `nova_set_nonblock` (maps to `fcntl` on POSIX and `ioctlsocket` on Windows inside the runtime),
     `nova_getrandom`, and the `nova_process_*` family (POSIX spawn/stdio/wait; Windows uses the `winproc`
     Nova file instead). These stay in A on purpose.

COROLLARY. A raw syscall that is fully expressible as an FFI binding (open/close/read/write/mkdir/stat/
socket/...) belongs in Mechanism B ONLY. It must never ALSO have a live `nova_*` twin in A. `nova_close`
violates this and is deleted (section 4).

## 4. Cleanup work items (each independently shippable, corpus-gated)

1. DELETE `nova_close`: remove from declarations.zig:297-299, from builtins.zig:94, and the `core.cpp:529`
   implementation plus the stale core.cpp:525-528 comment. Verify no caller (already zero). [dead-code]
2. DELETE `nova_fs_watcher_free_event`: remove declarations.zig:402-403 and the io.cpp:411 no-op. [dead-code]
3. Add a NEGATIVE builtin assertion (mirroring the existing M5 `findExtern("nova_file_open") == null`
   pattern in builtins.zig:186) for `nova_close`, so a future reintroduction fails the build. This is the
   guardrail that keeps the layer from re-growing a second name. [regression-guard]
4. FIX the one real abstraction leak in `os/socket.nova` (section 5). [consistency]
5. DOC: a short "OS layer" section in the architecture docs stating the RULE and the reserved-A list, so
   the next syscall added goes to B by default and nobody adds an A twin. [docs]

Out of scope: the reactor/uring/epoll ABI (correctly in A), the `os/backend_*` constant seam (working as
intended), and any behavioural change to Windows (bring-up owns that).

## 5. The one real abstraction leak: `os/socket.nova` call-site OS branching

Beyond the name divergence, the survey found a second, subtler inconsistency worth folding into the same
cleanup. `os/socket.nova` is the POSIX BASE file compiled on BOTH macOS and Linux (there is no
`socket_linux.nova`; Linux uses the base). To cover the macOS/Linux constant differences it branches at the
CALL SITE on `platform.isLinux`:

  socket.nova:21  eagain()        -> if (platform.isLinux) 11 else 35
  socket.nova:22  solSocket()     -> if (platform.isLinux) 1 else 65535
  socket.nova:23  soErrorOpt()    -> if (platform.isLinux) 4 else 4103
  socket.nova:24  soReusePort()   -> if (platform.isLinux) 15 else 512
  socket.nova:73  einprogress()   -> if (platform.isLinux) 115 else 36
  socket.nova:89  soRcvTimeo()    -> if (platform.isLinux) 20 else 4102
  socket.nova:90  soSndTimeo()    -> if (platform.isLinux) 21 else 4101
  socket.nova:91  aiAddrOffset()  -> if (platform.isLinux) 24 else 32

The problem is not that branching is wrong; it is that these SAME constants ALSO live authoritatively in the
`os/backend_*` seam (backend_darwin.nova / backend_linux.nova already define SOCKOPT_ERROR, SOCKOPT_REUSEPORT,
ERR_AGAIN, ERR_INPROGRESS, ADDRINFO_ADDR_OFFSET, SOCKOPT_LEVEL, SOCK_RCVTIMEO/SNDTIMEO). So there are TWO
mechanisms for the macOS/Linux split - `os/sys.nova` reaches them via `import os.backend` (the seam), while
`os/socket.nova` keeps a parallel, hand-maintained copy via inline `platform.isLinux`. The two can drift.

FIX (two acceptable options; pick during implementation):
  (a) PREFERRED - route `os/socket.nova` through the backend seam: replace the eight inline branches with
      `import os.backend` and read `backend.ERR_AGAIN` etc. One mechanism (the seam) for all POSIX
      per-OS constants; the socket file stops carrying a duplicate table. Add any missing names to the
      backend_* files.
  (b) ALTERNATIVE - introduce `socket_linux.nova` and let the file swap handle it, matching how Windows is
      done. Cleaner conceptually but adds a whole file to maintain for what is currently eight integers;
      only worth it if the macOS/Linux socket bodies diverge further.

Recommendation: (a). It removes a divergence rather than adding a file, and it makes the seam the single
source of truth for POSIX ABI constants, consistent with `os/sys.nova`.

## 6. What "done" looks like

- `declarations.zig` contains NO OS syscall that is also a live stdlib FFI binding. The only `nova_*`
  symbols left are the reserved categories in section 3.
- `nova_close` and `nova_fs_watcher_free_event` are gone; a negative builtin assertion prevents `nova_close`
  from returning.
- `os.sys` and `os.socket` are the single blessed OS API; their POSIX and `_windows` files expose identical
  surfaces; no stdlib module branches on OS at a call site for an ABI value (the `os/socket.nova` branches
  are routed through the backend seam).
- The architecture docs state the layering rule and the reserved-A list, so the next syscall added has an
  obvious, single correct home.
- Corpus green on native (macOS + Linux) and the Windows conformance set unchanged, proving the cleanup is
  behaviour-preserving.

## 7. Why this is safe to defer until after Windows/WSL bring-up

Nothing here changes Windows behaviour; it deletes dead macOS/Linux-side symbols and unifies POSIX constant
sourcing. But the bring-up is the right forcing function for ONE decision: it confirms which Windows externs
in `sys_windows`/`socket_windows`/`winproc`/`winsock` are genuinely exercised, so when we write the "reserved
A list" and the "identical surface" guarantee into the docs, we are documenting a surface that has actually
run on all three targets rather than an assumed one. Do the cleanup once that evidence is in.
