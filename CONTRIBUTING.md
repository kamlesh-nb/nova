# Contributing to Kyte

Kyte is in Beta and this document is meant to lower the barrier to a first contribution: how to build,
how to prove a change is correct, and the conventions that keep the tree green. If anything here is
wrong or stale, fixing this file is itself a welcome contribution.

## Build

Prerequisites: **Zig 0.16.0** (pinned) and an **LLVM 21** install.

```bash
cd lang
export PATH="$(scripts/bootstrap-zig.sh | tail -1):$PATH"       # fetch + checksum-verify the pinned Zig (see .zig-version)
export KYTE_LLVM_PREFIX=/path/to/llvm     # macOS: $(brew --prefix llvm@21)
zig build                                 # builds kyte -> ~/.kyte/bin/kyte, syncs std+runtime to ~/.kyte
KYTE_ASAN=1 zig build                     # ALSO builds the ASAN runtime (needed for the --asan gate)
```

The build is pinned to exactly Zig 0.16.0; a different Zig fails the configure step with a clear
message. Pass `-Dallow-zig-drift=true` only when intentionally moving the pin (and update
`.zig-version`, `build.zig`, and `scripts/zig-checksums.txt` together).

## The gate suite

Run the gates **before and after** every change. They are the definition of correct.

```bash
conformance/run.sh -j          # positive corpus + negative (expect_fail) + harness self-test. ~2 min.
conformance/run.sh --shadow    # soundness: ownership-engine agreement + disposition + balance.
KYTE_ASAN=1 zig build && conformance/run.sh --asan   # use-after-free / double-free gate.
zig build test                 # the Zig unit tests.
```

### Always use `-j`; never wait on the sequential modes

The plain `conformance/run.sh` and `conformance/run.sh --asan` run **sequentially with no per-case
timeout**. Several cases (the reactor/app/server cases, roughly `192`-`205`) start a server and wait
on a socket, so a sequential run **hangs forever** on them. `-j` runs each case in its own temp dir
with a per-case timeout, so it terminates and is the **authoritative** result.

- Need an ASAN signal without the hang? Run the ownership-relevant cases individually under
  `KYTE_ASAN=1` with your own timeout wrapper, in parallel. A sequential `--asan` over the whole
  corpus is not worth waiting on.
- A `-j` failure on a genuinely multi-threaded case (`195_multicore_reactors`) can be a load flake on
  a small box. Re-check that one case on its own before believing it.

### The soundness gate (`--shadow`)

`--shadow` runs every case under `KYTE_SEMA_SHADOW=1` and fails on any `FOUNDATION GATE FAILED`. It
bundles three invariants, all of which must stay at zero divergences:

1. **Engine agreement** -- the resolved-TypeId ownership engine agrees with the legacy string-rule
   baseline (the historical regression guard).
2. **Disposition** -- the checker's ownership disposition matches codegen's, modulo the recognized
   safe boundaries (enums, primitives, type parameters).
3. **Ownership balance** -- every owned value is provably consumed exactly once.

This gate guards the memory-safety model. If you touch anything under `src/sema/` or
`src/codegen/arc.zig`, run it.

## Verifying memory-safety changes

**Verify with `--asan`, not just `--arc`.** The ARC audit misses use-after-frees that AddressSanitizer
catches. Ownership is decided on resolved **TypeIds** (`isOwnedTypeId`), never by string-matching a
type name; if you find yourself branching on a type-name string in a codegen ownership decision, that
is the anti-pattern the L1 migration removed. Route through the TypeId.

## How the compiler is laid out

See [docs/architecture/](docs/architecture/) for the subsystem-by-subsystem reference. The short
version:

- `src/` -- lexer, parser, `type_checker.zig`, `sema/` (the authoritative typed-IR pass:
  infer/mono/ownership/lower), `codegen/` (LLVM emission + ARC), `main.zig` (driver + linking).
- `src/std/` -- the standard library, compiled from source every build.
- `src/runtime/` -- the C++20 runtime.
- `conformance/` -- `cases/` (positive), `expect_fail/` (must be rejected), `run.sh` (the harness).

**Adding a language feature?** Start with [docs/architecture/05-adding-a-feature.md](docs/architecture/05-adding-a-feature.md),
and update [docs/language-specification.md](docs/language-specification.md) first (spec-first).

## Landing a change

1. Branch off the default branch; do not commit directly to it.
2. Add a conformance case for new behavior (a positive case in `conformance/cases/`, or a negative one
   in `conformance/expect_fail/` if the change is a new rejection). A new case that links a native
   package lib is environment-dependent; keep hermetic cases hermetic.
3. Green gates: `run.sh -j`, `--shadow`, and `--asan` for anything touching memory or ownership.
4. Keep documentation ASCII only in prose: use `--`, never an em or en dash.
5. Write a commit message that explains the *why*, not just the *what*.

## Reporting problems

An issue is most actionable with: the `kyte version` output, the smallest program that reproduces it,
the exact command, and the full compiler/runtime output. For a suspected miscompilation, a case that
fails under `--asan` is the strongest possible report.
