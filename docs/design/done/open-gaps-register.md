# Open-gaps register (2026-08-16)

The honest list of what is still worth closing on Kyte, after the OSSA-lite ownership verifier landed and
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
The reframing (`swift-arch-comparison.md`) established these were one gap: Kyte had no ownership IR.
- ✅ **Soundness verifier — delivered + gated.** OSSA-lite lowering + release-balance verifier over
  **100% of functions**, 0 false positives, non-vacuous (8 verifier unit tests). `KYTE_OSSA=hard` fails
  the build on a proven leak/double-free; wired into `gate.sh` via `conformance/ossa-gate.sh`. **[verified]**
  Verify: `bash conformance/ossa-gate.sh` → `ossa gate: 0 release imbalances OK`.
- ⚠️ **Verifier completeness hole (open).** Destructured bindings (`let {a,b} = …`) are untracked, so a
  leak *through a destructuring pattern* is not caught. The gate proves "no proven imbalance", not "no
  possible leak". Sound (never false-accuses); incomplete. **[verified]**
  Close it: track per-binding ownership for destructuring (needs per-binding type info in the lowering).
- ⚠️ **Gate breadth (open, minor).** `ossa-gate.sh` runs 6 type-heavy cases (each pulls in the full
  stdlib). Could widen the case list or make `KYTE_OSSA=hard` a dedicated CI leg over the whole corpus.
  A full-corpus sweep this session confirmed **0 imbalances across 329 cases** (`bad=[]`), so the hard gate
  cannot false-fail a legitimate build and widening the gate's case list is safe. **[verified]**
- ✅ **Perf (Gap 3) — CLOSED as resolved (2026-08-16), not deferred.** Optimiser scrapped; two independent
  measurements (E2 borrow-skip at the LLVM level, Track A redundant-copy on the OSSA IR) both found ~0
  headroom, re-verified fresh on `13_serde` (borrow-skip 0/0, forwarding 0/0). Kyte's ARC cost is
  fundamental per-object retain/release; forwarding cannot remove it; LLVM O3 already gives competitive
  codegen. The only remaining perf lever = per-request allocation COUNT = Gap 5 (below).
  Full closure of record: `done/gap3-closed.md`. **[verified]**
- 🔧 **Perf (Gap 5, allocation count) — ACTIVE (reopened 2026-08-16).** "Beating Rust/Go is not a stop
  condition." Built an allocation-count harness (`KYTE_ALLOC_COUNT` / `kyte_alloc_total`). Measured profile:
  collections ~0 allocs/op, strings ~1/op (builder remedy), JSON parse+bind = the hotspot. **Win #1 landed:
  lazy JsonValue arr/obj → 114 → 58 allocs/parse (49%), all serde cases green, ASAN + ARC audit clean.**
  Targeted + measure-first (the P7 blanket arena stays scrapped; escape-arena is low-headroom at 4% local).
  Plan + method + next candidates: `gap5-perf-plan.md`. **[verified]**

## B. Previously-tracked language crash bugs — ALL MARKED FIXED (do not treat as open) **[register]**
Each has a memory note stating it is resolved, with a pinned conformance case. Listed so they are not
re-opened by mistake. Reverify a specific one only if it resurfaces.
- Multi-arg stored closure SIGSEGV — FIXED 2026-08-04 (type-inference lookahead). **[register]**
- `Set<T>` standalone LLVMVerifyError — FIXED 2026-08-15 (Set-only mono). **[register]**
- `T|E|undefined` triple union SIGSEGV — FIXED; case `293_triple_union_value_arm`. **[register]**
- `(T)` parsed as one-tuple → nested-optional SIGSEGV — FIXED (commit 81eabc1); case `363`. **[register]**
- Value-optional 0/undefined collision (Map/List storing 0) — FIXED 2026-07-24 (V1 boxing, f9bfc60). **[register]**
- mongodb Cursor crash (same-named struct collision) — FIXED 2026-08-08 (43be68e); case `78`. **[register]**

### Genuinely-uncertain residuals in this area — BOTH RESOLVED (2026-08-18, re-verified) **[verified]**
- **mongo async-handler HANG** at concurrency > 1 — **FIXED.** Root cause = concurrent `runCommand` on the
  SHARED cached connection interleaving frames on the socket; fix = reactor-aware `AsyncLock` guarding
  `runCommand` (nova-mongodb `2e4b6f8`). Bench: c=50 crash → 100% success, bench4 green. A live re-run needs
  a running `mongod` + a concurrent app; the fix + bench are the evidence of record.
- **Value-optional PARAM present-0-as-absent variant** — **RESOLVED (re-run, not recall).** A present
  `0`/`false`/`0.0` passed as a value-optional ARG reads PRESENT (the R2/C10 param-ABI fix covers it). Now a
  permanent regression guard: `127_value_optional_zero.ky` `test_param_widths`. Both are beta-checklist
  item 3 (`docs/design/beta-checklist.md`), now green.

## C. Tooling (Gap 5) — **[register]**
- **Package manager — IMPLEMENTED (2026-08-18).** The git-clone stub is replaced by the full
  `pkg-manager.md` design: `project.lock.json` (flat, declared name + resolved SHA per dep), version-keyed
  cache `~/.kyte/cache/<name>-<sha8>`, transitive cache-deduped resolution, build-honors-lock, `get`/
  `restore`/`update`/`publish`, and version-aware per-owner import resolution (multi-version coexistence +
  name-collision guard). All six §10 acceptance items pass locally (`conformance/pkg-acceptance.sh`, no
  network); wired into `gate.sh`. **[verified]**
- **Debugger — DONE (2026-08-18).** In-editor DWARF + lldb-dap + formatters (C#-quality value display).
  **[verified]**
- **LSP** improved (R4 binding-accurate rename/refs) but still broad-but-basic.

## D. Cross-platform / CI (Gap 7) — open; see also the build.zig appendix **[verified build.zig / register]**
- **Windows `--asan` / `--arc` gates** not wired (the install step skips those runtimes). **[register]**
- **Windows IOCP readiness** cases 192/194/195 — a proactor has no "tell me when readable"; needs the
  completion-API conversion the design notes plan. **[register]**
- **`build.zig` delivery — CORRECTED: already solved.** Self-contained static binaries ship: `release.yml`
  publishes 6 bundles (macOS/Linux arm64+x86_64 static via `-Dstatic-llvm`; Windows bundles `LLVM-C.dll`).
  End users never install LLVM. The old static-LLVM mirror was removed on purpose (CI uses OS-package static
  archives). Remaining is polish only: Windows single-file static (optional), un-hardcode the local static
  default, verify `kynalyzer` is in the bundles. See `remaining-gaps-design.md` Gap 2. **[verified]**
- **WASM** is best-effort (deliberately dropped as the primary target, 2026-07-28). **[register]**

## E. Ecosystem (Gap 6) — not started; separate repos, weeks+. **[register]**

## F. Stdlib (Gap 8) — spine solid, leaves thin. **[register]**
The real risk is TEST COVERAGE, not missing features: a broad per-module `@test` sweep is the long tail.

## G. Operational — open **[verified]**
- Branch `feat/memory-management-refinements` is **~90 commits ahead of upstream and never pushed**,
  including this whole session's OSSA verifier + gate. Pushing is a standalone decision.

---

## Appendix 1 — `build.zig` delivery (CORRECTED — already solved)
Earlier text here claimed a missing static-LLVM mirror was the root gap. That was wrong. Verified against
`build.zig`, `deps/llvm-zig/README-static-llvm.md`, and `release.yml`:

**Self-contained static delivery already ships.** `release.yml` builds+publishes 6 bundles:

| Bundle | Link | End-user gets |
|---|---|---|
| macOS arm64 | **static** (`-Dstatic-llvm`) | single self-contained `kyte` |
| macOS x86_64 | **static** | single self-contained `kyte` |
| Linux x86_64 | **static** | single self-contained `kyte` |
| Linux arm64 | **static** | single self-contained `kyte` |
| Windows x86_64 | dynamic + **bundled `LLVM-C.dll`** | `kyte.exe` + dll, one zip |
| Windows arm64 | dynamic + bundled dll | `kyte.exe` + dll, one zip |

The LTO-bitcode blocker is resolved (`convert-drop-to-native.sh`); CI static-links the OS package manager's
`libLLVM*.a` (no mirror needed — the old fetched `llvm-dist` was removed on purpose). Web developers download
an archive and never install LLVM. Remaining is **polish only**: (1) Windows single-file static (optional —
the bundle is still one download), (2) un-hardcode `build.zig`'s local `static_llvm_prefix` (cosmetic; CI
overrides via `KYTE_LLVM_PREFIX`), (3) verify `kynalyzer` is inside the release archives. See
`remaining-gaps-design.md` Gap 2. Contributor DEV builds use dynamic system LLVM (fast); only release is static.

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
