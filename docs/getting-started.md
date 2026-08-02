# Getting Started with Nova

This guide takes you from an empty machine to a running Nova program, a scaffolded project, and a
dependency pulled from git. Nova is in Beta (0.1.0); expect rough edges and pin an exact version if you
need reproducibility.

## 1. Install the toolchain

Nova compiles through LLVM, so you need the Nova compiler plus an LLVM install. The Nova compiler is
built from this repository with a pinned Zig.

```bash
cd lang
export PATH="$(scripts/bootstrap-zig.sh | tail -1):$PATH"        # download + checksum-verify Zig 0.16.0, add to PATH
export NOVA_LLVM_PREFIX=/path/to/llvm      # macOS: $(brew --prefix llvm@21); Linux: /usr/lib/llvm-21
zig build                                  # builds `nova`, installs to ~/.nova/bin/nova
```

Put `~/.nova/bin` on your PATH, then confirm:

```bash
nova version
# nova 0.1.0
#   abi:    1    (extern-C runtime ABI contract; ...)
#   zig:    0.16.0    (pinned; see .zig-version)
#   host:   aarch64-macos
```

## 2. Your first program

```nova
// hello.nova
fn main(): void {
    let name = "world";
    console.log(`hello, ${name}`);

    let total = 0;
    for (i in 1..=10) { total = total + i; }
    console.log(`sum 1..10 = ${total}`);
}
```

Compile it to a native binary and run:

```bash
nova hello.nova -o hello
./hello
# hello, world
# sum 1..10 = 55
```

A few things to know from the start:

- `int` is 32-bit; `long` is 64-bit. Heap addresses must be `long`/`ptr` (a 32-bit `int` truncates a
  pointer). Memory is managed by deterministic ARC, not a garbage collector.
- Two variable keywords: `let` (mutable) and `const` (immutable). There is no `var`.
- Template strings use backticks and `${...}`. Ranges: `1..=10` inclusive, `1..10` exclusive.

The authoritative surface reference is
[language-specification.md](language-specification.md), with every claim cited to an executable
conformance case.

## 3. Scaffold a project

```bash
nova init web --name myapp        # templates: console | web | desktop  (`app` is an alias for web)
cd myapp
```

This creates a `project.json`, a `src/` with an entry point, and a `tests/` directory. Build and test:

```bash
nova build                        # -> build/<profile>/{obj,bin}; reads project.json
nova build --release              # optimized build
nova test                         # runs @test functions in the import graph
```

A test is any `fn` annotated `@test`:

```nova
import assert;

@test
fn adds(): void {
    assert.equalInt(2 + 2, 4);
}
```

Note that `nova test` runs the `@test` functions reachable through imports (including a library's own
tests), and it does not run `main()`.

## 4. Formatting

```bash
nova fmt path/to/file.nova        # canonical formatting
```

## 5. Add a dependency

Nova packages are git repositories. Add one to the current project:

```bash
nova get https://github.com/<owner>/<repo>     # clones into the cache, records it in project.json
nova get                                       # with no URL: restore all recorded dependencies
```

Then `import` the package's modules from your Nova source. The dependency is recorded in
`project.json` under `dependencies`, so a fresh checkout can restore it with a bare `nova get`. See
[packages.md](packages.md) for the full model, including how to publish your own package.

## 6. Cross-compiling

From a macOS or Linux host you can produce binaries for other targets with the bundled toolchain:

```bash
nova app.nova --target linux-x86_64   -o app-linux
nova app.nova --target windows-x86_64 -o app.exe
```

Linux and Windows binaries are produced this way today; the Windows runtime is run-verified, and Linux
is the standard native path.

## Where to go next

- [packages.md](packages.md) -- publish and consume packages.
- [architecture/](architecture/) -- how Nova is built (for contributors).
- [../CONTRIBUTING.md](../CONTRIBUTING.md) -- the gate suite and how to land a change.
- [STABILITY.md](STABILITY.md) -- what "Beta" guarantees and what it does not.
