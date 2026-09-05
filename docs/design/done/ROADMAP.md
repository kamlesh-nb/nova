# Kyte — design roadmap (front door, 2026-08-16)

Single entry point to the design state: what is done, what is locked, what decisions are open, and the
sequence to beta. Every claim is tagged **[verified]** (checked against code this session) / **[register]**
(from a doc/note) / **[reverify]** (recall, must re-run before trusting).

## 1. Where Kyte is (honest one-paragraph)
Kyte compiles Kyte → LLVM IR → native, ARC-managed, with a **self-hosted C++20 reactor runtime** — its own
async event loop over kqueue/epoll/io_uring/IOCP (all tested). Boost.Asio is retired and wolfSSL deleted
(build.zig: "no Boost, no wolfSSL; reactor runtime"); TLS and crypto are pure Kyte. This cycle closed the reframed "no ownership IR" gap: a real
compile-time ownership (ARC release-balance) verifier now covers **100% of functions**, 0 false positives,
and is **gated** in CI; the in-house LLVM-emit optimiser was **scrapped** (measured ~0 realized perf) and
the ARC-optimisation perf lever was **measured to have ~0 headroom** and closed. Self-contained static
delivery already ships (web devs download `kyte`, never LLVM). Remaining work is the package manager (fully
designed, not built), a handful of narrow polish items, and the bigger post-beta pieces (debugger, perf).

## 2. Done / locked this cycle **[verified]**
- **Ownership verifier (soundness).** OSSA-lite lowering + release-balance verifier, 100% coverage, 0 false
  positives (329-case sweep), enforced via `KYTE_OSSA=hard` + `conformance/ossa-gate.sh` in `gate.sh`.
  Rationale + IR: `swift-arch-comparison.md`, `ossa-lite-tasks.md`. Verify: `bash conformance/ossa-gate.sh`.
- **Gap 3 (optimiser / ARC-perf) CLOSED.** No in-house optimiser; `--release` = LLVM `default<O3>` +
  vectorization. ARC-forwarding measured at ~0 headroom twice (E2 + Track A), re-verified fresh. The only
  perf lever left = allocation count = Gap 5 (separate/optional). Closure of record: `done/gap3-closed.md`;
  rationale: `sil-arc-optimiser-direction.md`. Do NOT reintroduce an optimiser without a measured delta.
- **Static delivery.** `release.yml` publishes 6 self-contained bundles (mac/linux static, windows +bundled
  `LLVM-C.dll`). See `remaining-gaps-design.md` Gap 2. No mirror work needed.

## 3. Locked designs, NOT yet implemented
- **Package manager** — `pkg-manager.md`. Cargo-style: by-name imports; a dep's name comes from its own
  manifest; `url#ref` pins version; `project.lock.json` records resolved SHAs; versions COEXIST (cache
  `<name>-<sha8>`, per-owning-package resolution, feasible because mangling is path-derived); recursive
  transitive fetch; `kyte publish` = annotated tag + push. No MVS/registry/proxy. **Fully locked; the one
  real build risk is the version-aware resolver in `pipeline.zig` — spike it first.**
- **Connection forwarding (orchestrator)** — `remaining-gaps-design.md` Gap 6. fd-handoff is the data path
  on ALL platforms (proxy out of the path, best perf); Linux adds veth+netns as an ISOLATION fence (k8s-pod
  style), NOT the data path — the two are orthogonal (a socket keeps its creating netns; SCM_RIGHTS rides
  AF_UNIX). Primitive exists (`unixPair`/`sendFd`/`recvFd`); wiring into `proxyd`/`orchd` + the Linux fence
  remain.
- **Debugger** — `remaining-gaps-design.md` Gap 4. In-editor DAP (F5 in VS Code), never lldb CLI. DWARF via
  DIBuilder + `lldb-dap` + **lldb data formatters** so values (string/List/Map/optional) show — C#-quality,
  not addresses. MVP = lines + complete DIType + formatters as ONE deliverable. Post-beta.

## 4. Open decisions to lock (before building each)
- **Pkg manager:** ready to build; only the resolver spike gates it.
- **Verifier (Gap 3):** enforce corpus-wide (cheap) + accept the destructuring false-negative? (recommend yes)
- **Forwarding (Gap 6):** fire-and-forget every connection vs handoff-on-drain? how `orchd` gets
  `CAP_NET_ADMIN`? is the zero-downtime-deploy test a beta requirement?
- **Debugger (Gap 4):** DWARF+lldb-dap+formatters as one MVP? bundle `lldb-dap`+formatters? post-beta?
- **Perf (Gap 5): ACTIVE** — targeted, measure-first allocation reduction. Harness built; win #1 landed
  (JSON parse+bind 114→58 allocs, 49%). Next candidates in `gap5-perf-plan.md`. Not a stop condition that
  we beat Rust/Go.
- **kynalyzer:** ship in the same archive as `kyte` vs a companion artifact? version-lock via `check-version-sync.sh`?
- **Beta bar (Gap 7):** lock the 6-item release checklist.

## 5. Roadmap sequence (recommended, not a decree)
**Near-term (cheap, unblocking):**
1. Gap 3 corpus-wide verifier gate — hours, immediate soundness value.
2. `kynalyzer` bundled into the release (pure-Zig, cross-compiles from one runner) — ~1 day.
3. Adopt the Gap 7 beta checklist — free; it drives everything else.
4. Package-manager resolver spike → then implement `pkg-manager.md`.

**To beta:**
5. `gate.sh` green on all 6 hosts (delivery already works; this is CI coverage).
6. Reverify the §B residual bugs (mongo async-handler hang, valopt-param variant) — cheap, and the only
   correctness unknowns.
7. Package manager implemented + its §10 acceptance passing.

**Post-beta (bigger):**
8. Orchestrator fd-handoff test + the Linux veth isolation fence.
9. Debugger (Gap 4) — DWARF + lldb-dap + formatters, must clear the value-display bar.

*(Gap 5 perf is CLOSED as accepted — not on the roadmap; reopen only against a specific measured failing
target, per its standing rule.)*

## 6. Beta bar (the checklist — lock its contents)
Nothing ships "beta" until, by command:
1. `gate.sh` green on mac arm64/x86_64, linux/WSL, Windows.
2. Ownership verifier enforced corpus-wide.
3. Zero KNOWN live crash bugs (re-run, not recall).
4. Package manager implemented to `pkg-manager.md` (or explicitly labelled "tooling: alpha").
5. `docs/guide` compiles + examples run (dogfood gate exists).
6. Debugger NOT required for beta (post-beta), if documented.

## 7. Active design docs (index)
- **This file** — front door.
- `open-gaps-register.md` — the honest gap register (confidence-tagged).
- `remaining-gaps-design.md` — per-gap options/recommendation/decision (Gaps 2-8).
- `pkg-manager.md` — locked package-manager design.
- `sil-arc-optimiser-direction.md` — why no optimiser + the closed perf question.
- `swift-arch-comparison.md`, `ossa-lite-tasks.md` — the ownership-IR reframing + verifier design.
- `perf-improvement.md`, `p7-sound-arena.md`, `further-refinement.md` — perf references (Gap 5).
- `memory-management-refinements.md` — the M-series ARC/value-struct work.
- `lld/` — the compiler architecture map (living reference).

## 8. Archived
Superseded/scrapped docs live in `docs/design/done/`: the scrapped optimiser (`optimiser.md`,
`optimiser-pending.md`), the completed string→TypeId cutover (`string-to-typeid-cutover.md`,
`string-engine-removal.md`), and the prior gap register (`last-lap-of-gaps.md`, `lastlap/`), all superseded
by `open-gaps-register.md` + `remaining-gaps-design.md` + this roadmap.
