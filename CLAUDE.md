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
