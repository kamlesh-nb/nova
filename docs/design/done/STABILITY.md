# Kyte Stability and Versioning Policy

This document is the contract for how Kyte versions itself and what "stable" means for each
surface a user depends on. It is the L5 deliverable of the production-readiness plan.

Current release: **0.1.0 (Beta)**. Report it with `kyte version`.

## 1. Versioning scheme

Kyte uses **Semantic Versioning** (`MAJOR.MINOR.PATCH`) for the toolchain as a whole. The single
source of truth is `build.zig` (`kyte_version`), mirrored in `build.zig.zon` `.version`; `kyte
version` prints it. There is a SEPARATE, independently incremented **ABI version** for the
extern-C runtime seam (see section 4 and `docs/abi/runtime-abi.md`).

While Kyte is in the **0.x series it is BETA**: a `0.x` number is a deliberate signal that there
is **no cross-version stability guarantee yet**. Any `0.MINOR` bump may change syntax, semantics,
the standard library, the ABI, or the CLI. Pin an exact `0.x.y` if you need reproducibility today.

Once Kyte reaches **1.0.0**, the guarantees in section 3 take effect and the scheme becomes:

- **MAJOR** -- a breaking change to any STABLE surface (section 3). Accompanied by a migration note.
- **MINOR** -- backward-compatible additions (new syntax that does not invalidate old programs,
  new stdlib APIs, new CLI flags).
- **PATCH** -- bug fixes and internal changes with no surface change.

## 2. Surfaces

Kyte exposes five distinct surfaces. Each has its own stability level, because they mature at
different rates:

| Surface | What it is | Stability today (0.1.0) |
|---|---|---|
| Language syntax + semantics | What `docs/language-specification.md` describes | Beta -- pinned by the conformance corpus, but may still change |
| Standard library | `src/std/*` APIs imported by user code | Beta -- the shape is settling; breaking changes possible |
| Runtime ABI | The extern-C seam the compiler emits against (section 4) | Versioned (ABI v1); the header/ref-count core is intended to be long-lived |
| CLI | `kyte <file>`, `kyte build/test/fmt/init/get/version` | Beta -- subcommands stable in spirit, flags may be added |
| On-disk formats | `project.json`, the build cache (`CACHE_VERSION`) | Internal -- may change between any versions; the cache is self-invalidating |

## 3. What "stable" will guarantee at 1.0

For a surface marked stable at 1.0, within a MAJOR series:

- A program that compiles and passes its tests on `1.x` continues to compile and behave the same
  on `1.y` for `y > x`. New warnings are allowed; new hard errors on previously-valid code are not.
- The conformance corpus (`conformance/cases/`) is the executable definition of language behavior.
  A case, once green in a stable release, is a regression if it breaks -- that is what the CI
  `soundness` job enforces on every commit.
- Removing or renaming a public stdlib symbol requires the deprecation process (section 5).

## 4. The runtime ABI

The compiler emits native code that calls a fixed set of extern-C symbols and assumes a fixed
heap-object layout. That contract is versioned independently as **KYTE_ABI_VERSION** (currently
**1**), defined in `src/runtime/kyte_abi.h` and surfaced via `kyte version` and
`build_options.ky_abi_version`. Its STABLE core -- the 8-byte heap header (refcount `u32` at
`[ptr-8]`, length `u32` at `[ptr-4]`) and the `kyte_retain` / `kyte_release` / `kyte_bytes_alloc`
/ `kyte_bytes_free` entry points -- is documented and frozen in `docs/abi/runtime-abi.md`. The
async/reactor/syscall symbols in the same header are INTERNAL (compiler talking to its own
runtime), not a third-party contract, and are not covered by the ABI version.

The ABI version bumps ONLY on a breaking change to that stable core, independently of the
language version. A compiler and a runtime library link-compatibly iff their ABI versions match.

## 5. Deprecation policy (effective at 1.0)

Removing anything from a stable surface follows a fixed, warning-first path so no program breaks
without notice:

1. **Deprivation announced** -- the symbol/flag/syntax is marked deprecated in its doc and the
   release notes, with the replacement named. It keeps working unchanged.
2. **Warned** -- for at least **one full MINOR release**, using it emits a compiler warning
   (`deprecated: <what> -- use <replacement>`), never an error. Warnings are suppressible per
   invocation but on by default.
3. **Removed** -- only in the next **MAJOR** release, never sooner. The migration note tells users
   exactly what to change.

During 0.x (Beta) this process is aspirational: deprecations are documented in release notes but
the one-minor-warning window is not yet guaranteed. It becomes binding at 1.0.

## 6. How a release is cut

1. Bump `kyte_version` in `build.zig` and `.version` in `build.zig.zon` (keep them equal).
2. If the stable ABI core changed, bump `KYTE_ABI_VERSION` in `kyte_abi.h` and `kyte_abi_version`
   in `build.zig`, and note the break in `docs/abi/runtime-abi.md`.
3. The CI `soundness` job (build + conformance + `--shadow`) must be green on the commit.
4. Tag the commit `v<version>`; write release notes covering additions, fixes, and any deprecations.
