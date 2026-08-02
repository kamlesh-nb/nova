# Nova

Nova is a statically-typed, natively-compiled language for server-side services, hypermedia apps, and
(as a secondary target) WebAssembly. Its syntax is ES6/TypeScript-flavored; it compiles through LLVM to
a native binary with a C++20 async runtime and a standard library written in Nova itself.

**Status: 0.1.0 (Beta)** on the native target. A `0.x` version means there is no cross-version
stability guarantee yet (see [docs/STABILITY.md](docs/STABILITY.md)). Report the version with
`nova version`.

```nova
struct Point { pub x: int, pub y: int }

fn dist2(p: Point): int { return p.x * p.x + p.y * p.y; }

fn main(): void {
    let total = 0;
    for (i in 1..=100) { total = total + i; }
    console.log(`sum 1..100 = ${total}`);
    let p = Point { x: 3, y: 4 };
    console.log(`dist2(3,4) = ${dist2(p)}`);
}
```

## What is in this repository

This is the **language implementation** (`lang/`). Three cooperating codebases make up Nova:

| Component | Language | Location | Responsibility |
|---|---|---|---|
| Compiler | Zig 0.16 | `src/` | Lowers Nova to LLVM IR, then to a linked native executable. |
| Runtime | C++20 | `src/runtime/` | Async scheduler (LLVM coroutines), non-blocking sockets, channels, actors, allocator. |
| Standard library | Nova | `src/std/` | Collections, string, JSON/YAML/BSON serde, decimal128, regex, crypto + TLS, the HTTP/web framework, the DB seam. |

BTreeDB (a Zig storage engine, in a sibling repo) and the database drivers + orchestrator (published
Nova packages) are **consumers** of the language, not part of it.

## Quick start

Prerequisites: **Zig 0.16.0** and an **LLVM 21** install. The pinned toolchain fetch is scripted:

```bash
cd lang
export PATH="$(scripts/bootstrap-zig.sh | tail -1):$PATH"     # download + checksum-verify the pinned Zig, add to PATH
export NOVA_LLVM_PREFIX=/path/to/llvm  # e.g. $(brew --prefix llvm@21) on macOS
zig build                              # builds `nova`, installs to ~/.nova/bin/nova
```

Then compile and run a program:

```bash
nova hello.nova -o hello && ./hello
nova version                           # version + ABI + pinned Zig + host
```

Scaffold a project:

```bash
nova init web --name myapp             # or: console | desktop
cd myapp && nova build && nova test
```

Full walkthrough: [docs/getting-started.md](docs/getting-started.md).

## Documentation map

- [docs/getting-started.md](docs/getting-started.md) -- install, first program, first web app, adding a package.
- [docs/language-specification.md](docs/language-specification.md) -- the language reference (cited to conformance cases).
- [docs/architecture/](docs/architecture/) -- how the compiler, codegen, runtime, and stdlib work, subsystem by subsystem.
- [docs/packages.md](docs/packages.md) -- the package model: `project.json`, `nova get`, publishing.
- [docs/STABILITY.md](docs/STABILITY.md) -- versioning, the deprecation policy, and the runtime ABI contract.
- [CONTRIBUTING.md](CONTRIBUTING.md) -- building, the gate suite, and how to land a change.

## The gate suite (run before and after any change)

```bash
conformance/run.sh -j        # the conformance corpus, parallel (~2 min). AUTHORITATIVE.
conformance/run.sh --shadow  # the soundness gate (ownership-engine agreement + disposition + balance)
conformance/run.sh --asan    # AddressSanitizer gate (needs `NOVA_ASAN=1 zig build` first)
```

Use `-j`. The plain sequential `run.sh` and `--asan` have no per-case timeout and will hang on the
reactor/app cases that wait on a socket; `-j` applies per-case timeouts and is the mode that
terminates. See [CONTRIBUTING.md](CONTRIBUTING.md) for the details.

## License

See the repository root.
