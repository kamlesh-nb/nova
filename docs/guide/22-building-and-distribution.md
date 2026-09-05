# 22. Building and distributing

This chapter covers the mechanics of turning Nova source into something you can ship: compiling a
single file, building a project, cross-compiling a program for another operating system, and, at the
end, building the Nova toolchain itself into a distributable bundle (including for other
architectures). The last part is only for people packaging Nova; everything before it is for everyday
use.

## Compiling one file

The simplest build takes one file to one native executable:

```sh
nova hello.nova -o hello
./hello
```

`nova test file.nova` compiles and runs the `@test` functions in a file instead of producing a
standalone binary. This is what the guide's examples use.

## Building a project

Real applications are more than one file. `nova init` scaffolds a project, and `nova build` compiles
it:

```sh
nova init web --name shop      # scaffold a web app (also: desktop)
cd shop
nova build                     # debug build
nova build --release           # optimised build
```

A project has a `project.json` at its root that names it, sets its version and type, and lists its
package dependencies. `nova build` reads it, compiles every source file under `src/`, links against the
runtime, and writes the result under `build/<profile>/`, with the binary in `build/<profile>/bin/`.
Dependencies declared in `project.json` are fetched with `nova get`.

## Cross-compiling a program

Nova can build a program for a different operating system than the one you are on, because the compiler
carries a cross-capable C++ toolchain for the runtime. Pass a target:

```sh
nova app.nova --target linux-x86_64   -o app-linux
nova app.nova --target linux-arm64    -o app-linux-arm64
nova app.nova --target windows-x86_64 -o app.exe
```

The target names a program build as `<os>-<arch>`. The compiler builds the runtime for that target the
first time it sees it and caches it, then links a real ELF or PE executable. This is a best-effort
convenience for shipping a service built on your development machine; the native target is always the
most exercised.

## Building the toolchain itself

The rest of this chapter is for packaging Nova, not for using it. It builds the `nova` compiler and its
bundle, so skip it unless that is your job.

The toolchain is built with Zig (0.16). A plain build compiles the compiler and installs it, along with
the prebuilt runtime and the standard library, into `~/.nova`:

```sh
zig build                      # builds nova, installs to ~/.nova, syncs std + runtime + deps
```

This is the developer build. It dynamically links LLVM (fast to build) and is what you use while
working on the compiler. `conformance/run.sh` runs the test corpus against the installed `~/.nova`
binary.

## Packaging a distributable bundle

`zig build archive` packages a **self-installing, versioned, checksummed** bundle of the whole
toolchain (the compiler, the standard library, the prebuilt runtime, and the sources the cross-compiler
needs) for the host it runs on:

```sh
NOVA_VERSION=v0.1.0 NOVA_LLVM_PREFIX="$(brew --prefix llvm@21)" \
  zig build archive -Dstatic-llvm=true
```

Two things are worth knowing:

- `-Dstatic-llvm=true` statically links LLVM into `nova`, so the delivered binary carries LLVM and
  loads no shared `libLLVM`. Combined with in-process LLD, the shipped toolchain needs no `clang` and
  no system LLVM on the user's machine.
- `NOVA_LLVM_PREFIX` points the build at an installed LLVM 21 (from Homebrew or apt) whose static
  component archives are linked in. `NOVA_VERSION` names the archive and defaults to `dev`. Set
  `NOVA_ARCHIVE_SKIP_NLS=1` to skip building the language server into the bundle.

The step writes two files into `zig-out/`:

```
nova-<version>-<os>-<arch>.tar.gz          # the bundle   (.zip on Windows)
nova-<version>-<os>-<arch>.tar.gz.sha256   # its checksum (.zip.sha256 on Windows)
```

The checksum is produced by the step itself (`sha256sum` on Linux, `shasum -a 256` on macOS, the .NET
`SHA256` type on Windows), so there is no separate command to run. Verify a bundle later with:

```sh
cd zig-out && shasum -a 256 -c nova-v0.1.0-macos-arm64.tar.gz.sha256   # sha256sum -c on Linux
```

The bundle carries a small `install` script that copies the tree into the user's `~/.nova`, plus a
`VERSION` file, so it is self-installing and verifiable.

## Cross-building the toolchain

You can build the toolchain bundle for a different architecture than the host, so one machine per
operating system can produce both of that OS's builds. The target is a Zig triple (`<arch>-<os>`), and
you supply the target architecture's LLVM:

```sh
# On an arm64 Mac, build the x86_64 macOS bundle:
NOVA_VERSION=v0.1.0 NOVA_LLVM_PREFIX=<x86_64 macOS LLVM> \
  zig build archive -Dtarget=x86_64-macos -Dstatic-llvm

# On WSL2 (x86_64 Linux), build the arm64 Linux bundle:
NOVA_VERSION=v0.1.0 NOVA_LLVM_PREFIX=<arm64 Linux LLVM> \
  zig build archive -Dtarget=aarch64-linux-gnu -Dstatic-llvm

# On x86_64 Windows, build the arm64 Windows bundle:
NOVA_VERSION=v0.1.0 NOVA_LLVM_PREFIX=<arm64 Windows LLVM> \
  zig build archive -Dtarget=aarch64-windows -Dstatic-llvm
```

### The full host build matrix

Builds are done on the host, and each operating system produces both of its architectures. The target
is always a Zig triple passed with `-Dtarget`, and you point `NOVA_LLVM_PREFIX` at that architecture's
LLVM static archives. A native build (the host's own architecture) needs no `-Dtarget`. The six
supported host builds:

| Host | Build for | Invocation |
|------|-----------|------------|
| macOS | macOS arm64 (native on Apple silicon) | `zig build archive -Dstatic-llvm` |
| macOS | macOS x86_64 (Intel) | `NOVA_LLVM_PREFIX=<x86_64 macOS LLVM> zig build archive -Dtarget=x86_64-macos -Dstatic-llvm` |
| Windows | Windows x86_64 (native on x64) | `zig build archive -Dstatic-llvm` |
| Windows | Windows arm64 | `NOVA_LLVM_PREFIX=<arm64 Windows LLVM> zig build archive -Dtarget=aarch64-windows -Dstatic-llvm` |
| WSL2 / Linux | Linux x86_64 (native on x64) | `zig build archive -Dstatic-llvm` |
| WSL2 / Linux | Linux arm64 | `NOVA_LLVM_PREFIX=<arm64 Linux LLVM> zig build archive -Dtarget=aarch64-linux-gnu -Dstatic-llvm` |

The one input Zig cannot synthesise is the target architecture's LLVM, so a second-architecture build
on the same host needs that architecture's LLVM install pointed at by `NOVA_LLVM_PREFIX`. The native
build needs no target flag and links the host LLVM (the hardcoded dev prefix, or your
`NOVA_LLVM_PREFIX`). The same matrix applies to the sibling toolchain repos (nls and the
orchestrator): each uses the same `-Dtarget` pass-through, and only the ones that link LLVM (the
compiler and nls) need the per-architecture `NOVA_LLVM_PREFIX`.

What makes this work:

- The **compiler** is cross-compiled by Zig for the target, linking the target architecture's LLVM that
  you point `NOVA_LLVM_PREFIX` at.
- The **runtime** (`libnovacore.a`) is cross-compiled with the bundled `zig c++`, which targets any
  architecture with no extra toolchain. The host's archiver then bundles the target-architecture
  object; this is why same-operating-system, cross-architecture builds are the supported shape.
- **In-process LLD is on by default for a cross static build**, so the cross-built `nova` also carries
  its own linker and needs no `clang` on the target machine, exactly like a native bundle.
- The archive is **named for the target**, not the build host, so an arm64 Mac produces
  `nova-<version>-macos-x86_64.tar.gz`.

The one thing Zig cannot synthesise is the target architecture's LLVM static archives; you provide
those through `NOVA_LLVM_PREFIX`. Everything else, the compiler, the runtime, the linker, and the
checksum, the single `zig build archive` command produces.

## Where to go next

- Chapter 21 for why the toolchain is self-contained (in-process LLD, the prebuilt runtime).
- Chapter 1 to return to the everyday `nova` and `nova test` workflow.
