# Remaining gaps — design proposals (2026-08-16)

Design-discussion doc for the gaps that need a DECISION before code (per `open-gaps-register.md`). Gap #1
(module identity / package manager) is already locked in `pkg-manager.md`. Each section below is
Problem / Options / Recommendation / **Decision to lock** / Effort, so we settle each before implementing —
same discipline as the package manager. Nothing here is built yet.

Every factual claim is tagged **[verified]** (checked against the code this session) or **[recall]**.

---

## Gap 2 — Toolchain distribution (LLVM) — CORRECTED: delivery already works
**Correction (2026-08-16):** an earlier draft claimed "no static-LLVM mirror; every host brings its own
LLVM" and recommended bring-your-own. That was WRONG, from stale recall. Verified against `build.zig`,
`build.zig.zon`, `deps/llvm-zig/README-static-llvm.md`, and `.github/workflows/release.yml`:

**Self-contained delivery already exists and ships.** **[verified]**
- `zig build -Dstatic-llvm=true` static-links LLVM's component archives into `nova` → a **~132 MB
  self-contained binary** (only system dylibs; no `libLLVM.dylib`), gates green. "Users deploy only `nova`".
- The LLVM.org LTO-bitcode blocker (Zig's linker can't consume bitcode) is **RESOLVED** by
  `convert-drop-to-native.sh` (runs each archive member through `llc -filetype=obj`, re-archives native).
- `release.yml` builds **6 bundles** and publishes them: macOS {arm64, x86_64} and Linux {arm64, x86_64}
  are **statically linked** (`-Dstatic-llvm=true`, globbing the OS package-manager's `libLLVM*.a`);
  Windows {x86_64, arm64} ships `nova.exe` + a **bundled `LLVM-C.dll`** in the zip (dynamic, still one
  self-contained archive). In every case the end user downloads an archive and never installs LLVM.
- The old fetched `llvm-dist` mirror was **removed on purpose** — CI uses the OS package manager's static
  archives instead, which is reproducible without hosting ~GB tarballs. So "finish the mirror" is NOT a task.

**Actual remaining items (all narrow):**
1. **Windows single-file static.** Windows currently bundles `LLVM-C.dll` beside `nova.exe` rather than
   static-linking (needs static LLVM `.lib` + `link.exe` static link). Arguably unnecessary — the bundle
   is still "download the zip and run" — so this is polish, not a blocker.
2. **Un-hardcode the local static default.** `build.zig`'s `static_llvm_prefix` is a hardcoded dev-machine
   path; it only affects a `-Dstatic-llvm` build run locally off that box without `NOVA_LLVM_PREFIX`. CI
   overrides it, so this is cosmetic — make it a sensible per-OS default or require `NOVA_LLVM_PREFIX`.
3. **`nls` in the bundles?** Verify whether the LSP server ships in the release archives; if not, add it.
4. **Contributor dev builds** use dynamic system LLVM (fast) — fine; only release needs static.

**Recommendation:** delivery is DONE for the web-developer story. Treat 1-3 as small polish items, not a
gap. Do #3 (verify/bundle `nls`) and #2 (un-hardcode) opportunistically; #1 only if single-file Windows
matters.

**Decision to lock:** agree delivery is solved (no mirror work); pick up #2/#3 as polish? Pursue #1 or not?

**Effort:** #2/#3 = hours. #1 (Windows static) = days, finicky, optional.

---

## Gap 3 — Ownership verifier: gate-default + completeness
**Problem.** The OSSA verifier is opt-in (`NOVA_OSSA=hard`), 100% coverage, 0 false positives on a 329-case
sweep, wired as a 6-case `ossa-gate.sh` leg in `gate.sh`. **[verified]** Two open points: (a) it is not
enforced on the whole corpus, only 6 cases; (b) it has a false-NEGATIVE hole — destructured bindings are
untracked, so a leak *through* a destructuring pattern is not caught. **[verified]**

**Options.**
- (a) Enforcement: **A** keep the 6-case gate leg only; **B** additionally run `NOVA_OSSA=hard` across the
  WHOLE conformance corpus (cheap — it runs during sema, before the test binary) so every case is checked;
  **C** make it default in every `nova build` (dev friction + per-build sema cost).
- (b) Completeness: **A** close the destructuring hole (track per-binding ownership; needs per-binding
  type info from sema — moderate); **B** accept sound-but-incomplete and document it (it is a false
  negative, never blocks correct code).

**Recommendation:** enforcement **B** (corpus-wide, cheap, high value), completeness **B** (accept the hole
now; it cannot break a build; close later only if destructuring-heavy code appears).

**Decision to lock:** corpus-wide gate (enforcement-B) + accept destructuring hole (completeness-B)?

**Effort:** enforcement-B = hours (extend the gate script/harness). completeness-A (if chosen) = a slice
in the lowering.

---

## Gap 4 — Debugger
**Problem.** **No debug info is emitted at all** (no DWARF / DIBuilder anywhere in codegen). **[verified]**
So stepping, breakpoints, and variable inspection are impossible today; the debugger is greenfield.

**Options.**
- **A — DWARF via LLVM DIBuilder + external debugger (lldb/gdb).** Emit line tables first (breakpoints +
  step = ~80% of the value), then `DISubprogram`/`DILocalVariable`/`DIType` for variable inspection. Reuses
  the entire mature debugger ecosystem; the standard path for an LLVM language. Complications: attach a
  `DILocation` to every instruction, map Nova types → DWARF, and ARC/coroutine frames make locals tricky.
- **B — DAP (Debug Adapter Protocol) server for editors.** DAP is the *transport* for editor integration;
  it still needs debug info underneath. So A is a prerequisite for a good B, not an alternative.

**Recommendation: A, staged — line tables first, locals/types second.** The design decision is committing
to DWARF-via-DIBuilder. **Needs a spike** to confirm the LLVM-zig bindings expose DIBuilder before scoping.
This is a multi-week effort and is almost certainly **post-beta**.

**Decision to lock:** (1) DWARF-via-DIBuilder, line-tables-first? (2) Is a debugger a beta requirement or
post-beta? (I recommend post-beta.)

**Effort:** line tables = ~1-2 weeks incl. the binding spike. Full locals/types = several more.

---

## Gap 5 — Perf: allocation count (the only real per-core lever)
**Problem.** ARC-forwarding is measured at ~0 headroom (E2 + Track A this session), so the remaining
per-core lever is **reducing the per-request allocation count** (~3000 ARC objects/request vs Rust's ~50).
`escape.zig` already computes Stage-1 (local vs escapes) + Stage-2 (interprocedural may-escape), report-only.
**[verified]** A blanket per-request arena was tried and rolled back (28% slower — ARC follows pointers
across the region); the sound path is escape analysis, but function-escape is the wrong granularity (needs
request/persistent-sink escape). **[recall]**

**Options.**
- **A — Escape-driven stack/arena allocation.** Values `escape.zig` proves LOCAL get stack/arena
  allocation instead of heap+ARC. Sound, seed exists. Cost: multi-day+, escape→codegen wiring, and solving
  the request-escape (persistent-sink) granularity — the hard part.
- **B — Targeted hot-path reduction.** The ORM/web path allocates per-row containers + owned-string fields;
  reuse buffers, widen value-struct usage, fuse binders. Incremental, measured per change, low risk.
- **C — Accept current perf.** Already beats Rust/Go per-core on some benches; don't invest.

**Recommendation:** gate on whether per-core perf actually matters for the target use. If yes, **B first**
(low-risk, measurable), and only then **A** (the escape-arena rework) with a measured target — never blind
(that is how the P7 arena regressed).

**Decision to lock:** is perf a priority now? If yes, B-targeted first; A only against a measured goal.

**Effort:** B = per-change days, incremental. A = multi-day+ with real regression risk.

---

## Gap 6 — Windows IOCP readiness (cases 192/194/195)
**Problem.** `armRead`/`armWrite` (readiness: "tell me when readable") have no proactor analog on IOCP. The
design already exists in the notes: a **zero-byte receive** whose completion IS the readiness edge, with the
draining half (`waitReady`/`ev*`) already implemented sharing the completion path; io_uring shares the arm
records. **[recall — from CLAUDE.md]** So this is largely execution of a known design, not a design fork.

**Options.**
- **A — Implement the zero-byte-receive arming** for readiness on IOCP (+ shared io_uring records).
- **B — Leave readiness-style APIs unsupported on Windows; document it** (readiness is emulated on a
  proactor and rarely needed if apps use the completion API directly).

**Recommendation: A** — it is well-scoped (design known, draining half done). But it is Windows-only polish;
sequence it after the CI/toolchain (Gap 2) so it can actually be run-verified on a Windows host.

**Decision to lock:** commit to execute A, or accept B as a documented limitation for beta?

**Effort:** A = days (execution of a known design) + Windows-host verification.

---

## Gap 7 — Beta bar (release checklist)
**Problem.** Version drift is already guarded (`check-version-sync.sh`: `build.zig` == `build.zig.zon`
version, `build.zig` == `nova_abi.h` ABI). **[verified]** The real gap is the absence of an explicit,
agreed **beta checklist** (there is a history of declaring beta then walking it back).

**Proposal — the beta gate is met when ALL of:**
1. `gate.sh` green on every supported host: mac arm64, mac x86_64, linux/WSL, Windows (**depends on Gap 2**).
2. Ownership verifier enforced corpus-wide (**Gap 3 enforcement-B**).
3. **Zero KNOWN live crash bugs — verified by re-running, not recall** (the §B residuals in the register:
   mongo async-handler hang, valopt-param variant).
4. Package manager implemented to `pkg-manager.md` and its §10 acceptance passing (or explicitly labelled
   "tooling: alpha" with the limitation documented).
5. `docs/guide` compiles and its examples run (the dogfood gate already exists).
6. Debugger is **not** required for beta (post-beta), if documented.

**Recommendation:** adopt this as the checklist; nothing ships "beta" until items 1-5 are green by command.

**Decision to lock:** the exact contents of the beta checklist (add/remove items?).

**Effort:** the checklist is free; closing its items is Gaps 2/3 + the §B reverify.

---

## Gap 8 — Supply-chain trust (future; couples to Gap 1)
**Problem.** The package manager's recursive fetch trusts each package's declared dep list (recorded
out-of-scope in `pkg-manager.md` §5/§9). Fine now; a real concern once an ecosystem exists.

**Proposal.** First cheap defence when needed: **`nova vendor`** — copy the resolved dependency tree into
`./vendor/` and build offline from it (Go-style), so a build depends only on reviewed, checked-in code.
Signing / allow-lists / a registry come later and only if the ecosystem grows.

**Decision to lock:** nothing now — record `nova vendor` as the first future step; revisit after Gap 1 ships.

---

## Suggested sequence (my read, not a decision)
1. **Gap 3 enforcement-B** — hours, immediate soundness value, no design risk.
2. **Gap 2 (C: bring-your-own-LLVM now)** — unblocks the multi-host CI matrix.
3. **Package manager** implementation (Gap 1, already designed) — after the resolver spike.
4. **Gap 7 beta checklist** — adopt it; it drives everything else.
5. **Gap 6 (Windows readiness)** and the **§B bug reverify** — narrow, do when the host/CI is ready.
6. **Gap 5 (perf-B)** and **Gap 4 (debugger)** — bigger, post-beta unless a use-case forces them early.
