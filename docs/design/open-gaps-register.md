# Open-gaps register (2026-08-16)

The honest list of what is still worth closing on Nova, after the OSSA-lite ownership verifier landed and
the ARC-optimisation perf question was measured and closed this session. This is a *map*, not a promise:
nothing here is called "done" — done is what you verify with the command each item names.

**Confidence tags** on every claim:
- **[verified]** — checked against the real code or a command whose output was seen this session.
- **[register]** — grounded in `last-lap-of-gaps.md` / a memory note, not re-run this session.
- **[reverify]** — from recall; must be re-run before it is trusted or acted on.

**Correction on record:** an earlier draft of this list named six "live crash bugs" (multi-arg closure,
`Set<T>` standalone, `T|E|undefined`, nested value-optional arg, valopt-zero, mongo cursor). Re-checking
their memory notes showed **all six are marked FIXED** (see §B). They must NOT be treated as open. The
error is kept visible here because the register's value is its honesty.

---

## A. Ownership IR (Gap 1 soundness + Gap 3 perf) — the one-gap reframing. LARGELY CLOSED.
The reframing (`swift-arch-comparison.md`) established these were one gap: Nova had no ownership IR.
- ✅ **Soundness verifier — delivered + gated.** OSSA-lite lowering + release-balance verifier over
  **100% of functions**, 0 false positives, non-vacuous (8 verifier unit tests). `NOVA_OSSA=hard` fails
  the build on a proven leak/double-free; wired into `gate.sh` via `conformance/ossa-gate.sh`. **[verified]**
  Verify: `bash conformance/ossa-gate.sh` → `ossa gate: 0 release imbalances OK`.
- ⚠️ **Verifier completeness hole (open).** Destructured bindings (`let {a,b} = …`) are untracked, so a
  leak *through a destructuring pattern* is not caught. The gate proves "no proven imbalance", not "no
  possible leak". Sound (never false-accuses); incomplete. **[verified]**
  Close it: track per-binding ownership for destructuring (needs per-binding type info in the lowering).
- ⚠️ **Gate breadth (open, minor).** `ossa-gate.sh` runs 6 type-heavy cases (each pulls in the full
  stdlib). Could widen the case list or make `NOVA_OSSA=hard` a dedicated CI leg over the whole corpus.
  A full-corpus sweep this session confirmed **0 imbalances across 329 cases** (`bad=[]`), so the hard gate
  cannot false-fail a legitimate build and widening the gate's case list is safe. **[verified]**
- ✅ **Perf — measured and CLOSED, not deferred.** Two independent measurements (E2 borrow-skip at the
  LLVM level, Track A redundant-copy on the OSSA IR) both found ~0 headroom. Nova's ARC cost is
  fundamental per-object retain/release for genuinely-owned values; forwarding cannot remove it. No work
  item unless the real lever — reducing per-request allocation COUNT (arena/value-types, architectural,
  partly explored in P7) — is pursued. **[verified]** Doc: `sil-arc-optimiser-direction.md`.

## B. Previously-tracked language crash bugs — ALL MARKED FIXED (do not treat as open) **[register]**
Each has a memory note stating it is resolved, with a pinned conformance case. Listed so they are not
re-opened by mistake. Reverify a specific one only if it resurfaces.
- Multi-arg stored closure SIGSEGV — FIXED 2026-08-04 (type-inference lookahead). **[register]**
- `Set<T>` standalone LLVMVerifyError — FIXED 2026-08-15 (Set-only mono). **[register]**
- `T|E|undefined` triple union SIGSEGV — FIXED; case `293_triple_union_value_arm`. **[register]**
- `(T)` parsed as one-tuple → nested-optional SIGSEGV — FIXED (commit 81eabc1); case `363`. **[register]**
- Value-optional 0/undefined collision (Map/List storing 0) — FIXED 2026-07-24 (V1 boxing, f9bfc60). **[register]**
- mongodb Cursor crash (same-named struct collision) — FIXED 2026-08-08 (43be68e); case `78`. **[register]**

### Genuinely-uncertain residuals in this area (do reverify)
- **mongo async-handler HANG** at concurrency > 1 — the async_owned_struct note says a "separate
  app-level async-handler hang remains (not the compiler bug)". Status unclear. **[reverify]**
  Check: run the mongo driver at c>1 and observe.
- **Possible value-optional PARAM present-0-as-absent variant** — a 2026-08-13 note flagged "valopt-zero
  (present 0 reads absent) still open, orthogonal" *after* the value-level fix; may be a param-passing
  variant of the same class (or already covered by the R2/C10 param-ABI fix). **[reverify]**

## C. Tooling (Gap 5) — open **[register]**
- **Package manager** is a git-clone stub — no lockfile, versioning, or registry. (Network-dependent to
  verify; not startable in the sandbox.)
- **No debugger** — no DWARF/lldb integration. Large; independent of other gaps.
- **LSP** improved (R4 binding-accurate rename/refs) but still broad-but-basic.

## D. Cross-platform / CI (Gap 7) — open; see also the build.zig appendix **[verified build.zig / register]**
- **Windows `--asan` / `--arc` gates** not wired (the install step skips those runtimes). **[register]**
- **Windows IOCP readiness** cases 192/194/195 — a proactor has no "tell me when readable"; needs the
  completion-API conversion the design notes plan. **[register]**
- **`build.zig` per-host bring-up** — ~70% there; the real gap is the missing static-LLVM mirror (every
  host must bring its own LLVM). Detail in Appendix 1. **[verified]**
- **WASM** is best-effort (deliberately dropped as the primary target, 2026-07-28). **[register]**

## E. Ecosystem (Gap 6) — not started; separate repos, weeks+. **[register]**

## F. Stdlib (Gap 8) — spine solid, leaves thin. **[register]**
The real risk is TEST COVERAGE, not missing features: a broad per-module `@test` sweep is the long tail.

## G. Operational — open **[verified]**
- Branch `feat/memory-management-refinements` is **~90 commits ahead of upstream and never pushed**,
  including this whole session's OSSA verifier + gate. Pushing is a standalone decision.

---

## Appendix 1 — `build.zig` per host (mac arm64/intel, Windows, WSL/Ubuntu)
Already ~70% there, not greenfield: `build.zig` has `os_tag` branches (Windows/Linux/macOS), separate LLVM
lib manifests (`llvm-libs.txt` / `llvm-libs-linux.txt`), a `NOVA_LLVM_PREFIX` override, and a `release.yml`
CI that installs LLVM 21 per host. **[verified]**

| Host | State | Gap |
|---|---|---|
| macOS arm64 | works | falls back to a **hardcoded dev prefix** — brittle across machines |
| macOS x86_64 | handled in the macos-13 release cell | needs `NOVA_LLVM_PREFIX`; not a clean bare `zig build` |
| WSL / Ubuntu | works (Linux path) | must point `NOVA_LLVM_PREFIX` at apt `llvm@21` |
| Windows | works | needs `NOVA_LLVM_PREFIX` + LLVM `bin` on PATH at build AND run time |

**Root gap:** there is **no fetched static-LLVM mirror** (`-Dstatic-llvm` 404s; mirror upload "pending" per
CLAUDE.md), so every host brings its own LLVM. To close for clean per-host CI, either (a) finish the
static-LLVM mirror upload, or (b) standardise "provision `llvm@21` + set `NOVA_LLVM_PREFIX`" in each host's
runner and drop the hardcoded dev-prefix fallback. **nls** (the LSP server) likely needs the same treatment
— NOT yet verified whether it builds through this `build.zig` or a separate one; scope that first. **[verified/reverify]**

## Appendix 2 — optimiser switches vs `--release`
**`--release` handles all optimisation; do not add optimiser switches.** **[verified]**
`declarations.zig:1347`: `passes = is_release ? "default<O3>,globaldce" : "default<O0>,globaldce"`, with
loop + SLP vectorization and loop unrolling enabled in release. So `--release` = full LLVM `-O3`, default =
`-O0`. The only optimisation LLVM cannot do is ARC elision, and that was measured at ~0 headroom twice this
session — an in-house switch would toggle a no-op pass. The single legitimate *optional* addition is
ergonomic, not perf: exposing `-O1/-O2/-Os` (size) for embedding/WASM, since today it is binary
release/debug only.

## Suggested priority for a beta (my read, not a decision)
1. Push the branch (operational, §G) — 90 unpushed commits is real risk.
2. Reverify §B residuals (mongo hang, valopt-param variant) — cheap, and they are the only correctness unknowns.
3. Static-LLVM mirror / per-host CI (§D + Appendix 1) — unblocks reproducible multi-host builds.
4. Package manager, then debugger (§C) — the tooling the ecosystem needs.
5. Stdlib `@test` sweep (§F) and destructuring completeness (§A) — hardening, in parallel.
