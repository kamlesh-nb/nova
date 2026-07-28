# Nova — Architecture Overview

This directory is the technical architecture reference for the Nova language implementation
(the `lang/` repository). It explains **how Nova is built**, subsystem by subsystem, so a new
contributor can navigate the code and extend it with confidence.

> Nova is **Beta** on its primary, native target. WebAssembly is a secondary / best-effort target.
> For *what the language is* and its surface semantics, see [`../language-specification.md`](../language-specification.md).
> For *roadmap and status*, see [`../design/execution-plan.md`](../design/execution-plan.md).

## The three programs

Nova is three cooperating codebases:

| Component | Language | Where | Job |
|-----------|----------|-------|-----|
| **Compiler** | Zig 0.16 | `src/` (this repo) | Lowers Nova source → LLVM IR → native object → linked executable. |
| **Runtime** | C++20 | `src/runtime/` | Linked into every native binary: async scheduler (Boost.Asio + LLVM coroutines), non-blocking sockets, TLS (wolfSSL), channels/actors, allocator. |
| **Standard library** | Nova | `src/std/` | Collections, string, serde (JSON/YAML/BSON), decimal128, regex, crypto, the HTTP/web framework, the DB seam. Compiled from source on every build. |

Two sibling projects live outside this repo: **BTreeDB** (the Zig storage engine, `../../btree/`) and
**nova-orchestrator** + the DB drivers (published Nova packages). They are consumers of the language, not
part of it.

## The compilation pipeline (one glance)

```
source.nova
   │  main.zig: loadProgram  ── recursively resolve + merge imports ──► one AST (Program)
   ▼
sema/alpha.zig      α-rename    (same-scope shadowing → unique names)
sema/ids.zig        assign IDs  (NodeId / ModuleId on every node)
type_checker.zig    check       (arg counts, visibility, ownership/pointer-truncation,
                                  function coloring, optionals soundness — DIAGNOSTICS)
sema/ (shadow.zig)  typed IR    (infer → subst → lower → symbols → ownership:
                                  the AUTHORITATIVE typed intermediate representation)
sema/mono.zig       monomorph.  (worklist discovers live generic instantiations)
codegen/            emit        (declarations → expressions/statements → arc → LLVM IR)
   │  LLVM verify + CoroSplit + globalDCE  →  object file(s)
   ▼
main.zig: link      (in-process LLD for Mach-O/WASM, or clang++ / `zig c++` for cross-targets)
   ▼
executable  (native)  |  module.wasm  (freestanding + host imports)
```

Every stage is one directory or file, and each has a deep-dive below.

## Deep dives

1. **[The Compiler](01-compiler.md)** — the pipeline in detail: lexer, parser/AST, the semantic
   passes (`sema/`), monomorphization, and how `main.zig` drives and links it.
2. **[Code Generation](02-codegen.md)** — how the typed IR becomes LLVM IR: the value model
   (`val_type` = i64), traits as fat pointers, ARC, async as coroutines, and the native/WASM splits.
3. **[The Runtime](03-runtime.md)** — the C++20 runtime: the share-nothing Asio scheduler, async
   socket/TLS I/O, channels/actors, the ARC heap header, and the ABI seam the compiler depends on.
4. **[Standard Library & Web Framework](04-stdlib.md)** — how the Nova stdlib is structured and
   compiled, the `db` seam, and the MediatR-style `App` HTTP framework.
5. **[Adding a Feature](05-adding-a-feature.md)** — the contributor workflow: where a new keyword /
   type / builtin / stdlib module goes, and the conformance gate that must stay green.

## Ground rules that shape everything

These invariants recur throughout the code; internalize them before editing:

- **`int` is 32-bit, `long`/`ptr` are 64-bit.** A heap address must be `long`/`ptr`. `intAddr + offset`
  truncates to 32 bits (LLVM `trunc i64→i32`) → garbage pointer → address-dependent SIGSEGV.
- **The universal value handle is 64-bit (`val_type` = i64)** on both native and WASM — it must hold an
  `f64`. On WASM32 a pointer is i32 and rides the low 32 bits of that i64.
- **Monomorphization is mandatory.** Generics are instantiated (`List<int>` → `List_int_*`), never
  type-erased at runtime. An erased body is only a link-time fallback that `globalDCE` drops.
- **ARC, not GC.** Every heap object has an 8-byte header (`refcount @ -8`, `length @ -4`); ownership is
  decided in the semantic/codegen passes. **Verify memory changes with AddressSanitizer** (`run.sh --asan`),
  not just the ARC audit — the audit misses use-after-frees that ASAN catches.
- **The conformance corpus is the contract.** `conformance/run.sh` (positive cases via `nova test`,
  `expect_fail/` negatives, `--asan` memory gate) runs before and after any change.

## Build, run, test

```sh
cd lang
zig build                    # build `nova` → ~/.nova/bin, sync std+runtime+deps to ~/.nova
NOVA_ASAN=1 zig build        # also build the ASAN runtime (for the --asan gate)

nova file.nova -o out        # compile one file to a native binary
nova test file.nova          # run its @test functions
nova build [--release]       # project build (reads project.json) → build/<profile>/{obj,bin}

conformance/run.sh           # the corpus (native)
conformance/run.sh --asan    # AddressSanitizer memory gate
conformance/run.sh --wasm    # WASM compile gate;  --wasm-run  executes under Node
```
