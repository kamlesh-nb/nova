# Nova, Architecture Overview

This directory is the technical architecture reference for the Nova language implementation, that is, the
`lang/` repository. It explains how Nova is built, subsystem by subsystem, so that a new contributor may
navigate the code and extend it with confidence.

> Nova is at present in **Beta** on its primary, native target. WebAssembly is a secondary, best effort
> target. For an understanding of *what the language is* and its surface semantics, kindly refer to
> [`../language-specification.md`](../language-specification.md). For the roadmap and status, please see
> [`../design/execution-plan.md`](../design/execution-plan.md).

## The Three Programs

Nova is composed of three cooperating codebases.

| Component | Language | Location | Responsibility |
|-----------|----------|----------|----------------|
| **Compiler** | Zig 0.16 | `src/` (this repo) | Lowers Nova source to LLVM IR, then to a native object, and finally to a linked executable. |
| **Runtime** | C++20 | `src/runtime/` | Linked into every native binary. It provides the async scheduler (Boost.Asio with LLVM coroutines), non blocking sockets, TLS (wolfSSL), channels and actors, and the allocator. |
| **Standard library** | Nova | `src/std/` | Collections, string, serde (JSON, YAML, BSON), decimal128, regex, crypto, the HTTP and web framework, and the database seam. It is compiled from source on every build. |

Two sibling projects reside outside this repository, namely **NovaDB** (the Zig storage engine,
`../../btree/`) and **nova-orchestrator** along with the database drivers (which are published Nova
packages). These are consumers of the language and are not a part of it.

## The Compilation Pipeline at a Glance

```
source.nova
   |  main.zig: loadProgram  .. recursively resolve and merge imports ..>  one AST (Program)
   v
sema/alpha.zig      alpha-rename   (same-scope shadowing to unique names)
sema/ids.zig        assign IDs     (NodeId and ModuleId on every node)
type_checker.zig    check          (arg counts, visibility, ownership and pointer truncation,
                                    function colouring, optionals soundness; these are DIAGNOSTICS)
sema/ (shadow.zig)  typed IR       (infer, subst, lower, symbols, ownership:
                                    the AUTHORITATIVE typed intermediate representation)
sema/mono.zig       monomorphise   (a worklist discovers live generic instantiations)
codegen/            emit           (declarations, then expressions and statements, then arc, to LLVM IR)
   |  LLVM verify, CoroSplit, globalDCE  ..>  object file(s)
   v
main.zig: link      (in-process LLD for Mach-O and WASM, or clang++ / `zig c++` for cross targets)
   v
executable  (native)  |  module.wasm  (freestanding, with host imports)
```

Every stage corresponds to one directory or file, and each of them has a deep dive below.

## Deep Dives

1. **[The Compiler](01-compiler.md).** The pipeline in detail: the lexer, the parser and AST, the semantic
   passes (`sema/`), monomorphisation, and the manner in which `main.zig` drives and links the whole.
2. **[Code Generation](02-codegen.md).** How the typed IR becomes LLVM IR: the value model (`val_type`,
   which is i64), traits as fat pointers, ARC, async as coroutines, and the native and WASM splits.
3. **[The Runtime](03-runtime.md).** The C++20 runtime: the share nothing Asio scheduler, async socket and
   TLS I/O, channels and actors, the ARC heap header, and the ABI seam upon which the compiler depends.
4. **[Standard Library and Web Framework](04-stdlib.md).** The manner in which the Nova standard library is
   structured and compiled, the `db` seam, and the MediatR style `App` HTTP framework.
5. **[Adding a Feature](05-adding-a-feature.md).** The contributor workflow: where a new keyword, type,
   builtin, or standard library module is to be placed, and the conformance gate that must remain green.
6. **[NovaDB](06-btreedb.md).** The sibling storage engine (a separate repository, in Zig): the slotted
   page B+Tree, the segmented buffer pool, MVCC and the WAL, the SQL layer, and the binary wire protocol
   that Nova's driver speaks.
7. **[The Orchestrator](07-orchestrator.md).** The sibling control plane (a separate Nova package): the L7
   proxy and load balancer, the reconcile loop node agent, cgroups limits, PID autoscaling, and native
   container grade isolation.

## Ground Rules That Shape Everything

The following invariants recur throughout the code, and they should be internalised before any editing is
undertaken.

- **`int` is 32 bit, whereas `long` and `ptr` are 64 bit.** A heap address must therefore be `long` or
  `ptr`. The expression `intAddr + offset` truncates to 32 bits (an LLVM `trunc i64 to i32`), which yields
  a garbage pointer, and hence an address dependent SIGSEGV.
- **The universal value handle is 64 bit (`val_type`, which is i64)** on both native and WASM, because it
  must be able to hold an `f64`. On WASM32 a pointer is i32 and rides in the low 32 bits of that i64.
- **Monomorphisation is mandatory.** Generics are instantiated (`List<int>` becomes `List_int_*`); they are
  never type erased at runtime. An erased body is merely a link time fallback that `globalDCE` drops.
- **The scheme is ARC, and not GC.** Every heap object carries an 8 byte header (`refcount` at offset minus
  8, `length` at offset minus 4); ownership is decided in the semantic and codegen passes. Kindly verify
  memory changes with AddressSanitizer (`run.sh --asan`), and not merely with the ARC audit, since the
  audit does miss use after free cases that ASAN catches.
- **The conformance corpus is the contract.** `conformance/run.sh` (positive cases via `nova test`,
  negatives under `expect_fail/`, and the `--asan` memory gate) is to be run before and after any change.

## Build, Run, Test

```sh
cd lang
zig build                    # build `nova` to ~/.nova/bin, and sync std, runtime, deps to ~/.nova
NOVA_ASAN=1 zig build        # additionally build the ASAN runtime (required for the --asan gate)

nova file.nova -o out        # compile one file to a native binary
nova test file.nova          # run its @test functions
nova build [--release]       # project build (reads project.json) to build/<profile>/{obj,bin}

conformance/run.sh           # the corpus (native)
conformance/run.sh --asan    # the AddressSanitizer memory gate
conformance/run.sh --wasm    # the WASM compile gate; --wasm-run executes under Node
```
