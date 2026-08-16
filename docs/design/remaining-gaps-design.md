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
3. **Ship `nls` in the bundles (user request: "make nls same as language").** `nls` is a SEPARATE project
   (`/nova-lang/nls`, own `build.zig`) currently SKIPPED in release.yml (`NOVA_ARCHIVE_SKIP_NLS=1`). Good
   news: `nls` is a **pure-Zig binary with NO LLVM link** (the LSP uses only the frontend re-exports via
   `-Dnova-src=…/lang/src/root.zig`; codegen/`llvm` is not reachable), ~5.8 MB, and "cross-compiles
   unchanged". **[verified]** So "same as language" is straightforward and actually EASIER than the
   compiler:
   - Build `nls` for all 6 targets — and because it is pure Zig, it can be **cross-compiled from a single
     runner** (no per-host LLVM), unlike the compiler.
   - Pin it to the SAME lang source revision (`-Dnova-src`) so `nls` and `nova` never drift, and stamp the
     SAME version (extend `check-version-sync.sh` to cover nls).
   - Include the `nls` binary in each release archive (drop `NOVA_ARCHIVE_SKIP_NLS`, or a companion
     `nls-<triple>` artifact) so an install carries the compiler + LSP together.
4. **Contributor dev builds** use dynamic system LLVM (fast) — fine; only release needs static.

**Recommendation:** delivery is DONE for the web-developer story. #3 (ship `nls`) is the one the user
explicitly wants and is small — a cross-compiled pure-Zig binary bundled alongside `nova`, version-locked to
the same lang source. Do #2 (un-hardcode) opportunistically; #1 (Windows single-file static) only if it
matters.

**Decision to lock:** (1) agree delivery is solved (no mirror work). (2) ship `nls` in the SAME archive as
`nova` vs a companion artifact? (3) version-lock `nls` to lang via `check-version-sync.sh`?

**Effort:** #3 (nls) = ~1 day (add an nls build+bundle leg, cross-compiled; extend version-sync). #2 = hours.
#1 (Windows static) = days, optional.

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

## Gap 6 — CORRECTED: reactor backends done; the item is orchestrator fd-handoff
**Correction (per user).** All four reactor backends are TESTED — kqueue (macOS), epoll + io_uring
(Linux), IOCP (Windows). The earlier "Windows IOCP readiness (192/194/195)" framing is retired; that is
not the open item. **[user-asserted]**

**The actual remaining networking item: fd-handoff through the orchestrator.** The SCM_RIGHTS fd-passing
primitive is built and the STANDALONE handoff demo works (`lang/docs/guide/examples/fd-handoff/` — a
service binds a TCP front port + an AF_UNIX rendezvous and hands each accepted client SOCKET to a backend
app; the app writes the response directly, proxy out of the data path). Runtime shims `nova_send_fd` /
`nova_recv_fd` + `os.socket.sendFd`/`recvFd`/AF_UNIX helpers exist. **[verified: demo + primitive]** Per the
fd-passing note, it was **not yet wired into `proxyd`** and not exercised end-to-end through `orchd`/`proxyd`
— that (wire if needed + TEST the orchestrator handoff path) is the open work. **[recall — reverify current
proxyd state]**

**Scope.**
1. Confirm current state: is fd-handoff already wired into `proxyd`, or only the standalone demo? (reverify)
2. If not wired: wire `proxyd` to hand accepted client fds to app replicas over the AF_UNIX rendezvous.
3. **Test the orchestrator handoff end-to-end**: `orchd` + `proxyd` + N app replicas, a client connection
   handed off, and — the payoff — a **zero-downtime deploy** where in-flight connections survive a replica
   swap. This is the acceptance the whole handoff design exists for.

**LOCKED design — fd-handoff is the data path on ALL platforms; veth is the Linux ISOLATION fence, not the
data path.** The key systems fact: netns isolation and fd-handoff are ORTHOGONAL, so we use both on Linux.
- A socket's network namespace is fixed at CREATION and does NOT change when the fd is passed; SCM_RIGHTS
  travels over an AF_UNIX channel that lives in the mount (not network) namespace. So `proxyd` (host netns,
  public IP) `accept()`s the client, hands the socket fd to the app in its OWN isolated netns, and the app
  does I/O on it directly — the kernel routes that through the socket's original (host) netns stack. The
  app is unreachable directly (pod-style isolation) AND the proxy is out of the data path (best perf).
- **Data path (all three platforms): fd-handoff.** macOS/Linux = SCM_RIGHTS over AF_UNIX; Windows =
  `WSADuplicateSocket`/handle duplication. Proxy leaves the steady-state path everywhere.
- **Isolation (Linux): netns + veth** = the fence (the "k8s pod": app not directly reachable). veth is NOT
  in the client data path — it carries the app's OTHER traffic (egress to the DB, health/metrics). macOS/
  Windows have no netns; they get handoff without the pod fence (or Job Objects / sandbox if wanted later).

**Mechanism (Nova already has the primitives).** To hand fds across BOTH a netns and a mount namespace,
don't depend on a shared AF_UNIX path: `orchd` creates a socketpair (`os.socket.unixPair`), spawns the
replica with one end as an inherited fd, THEN the replica enters its netns/pod. `proxyd` sends each client
fd over that pre-established socketpair (`sendFd`/`recvFd`, already built). No shared filesystem; clean
privilege boundary.

**Common app-facing seam.** On every platform the app receives a client socket fd from its handoff channel
and serves it — identical handler code; the platform difference (SCM_RIGHTS vs WSADuplicateSocket) and the
Linux isolation fence are hidden in `orchd`/`proxyd`.

**Privilege.** Creating netns + veth needs `CAP_NET_ADMIN`/root on Linux; the fd-handoff itself needs no
elevated privilege. So only the Linux ISOLATION setup is privileged — decide how `orchd` gets it (run
privileged, `setcap`, or a small privileged helper that sets up the pod then drops).

**Open design question (independent of platform):** does `proxyd` hand off EVERY connection (fire-and-forget,
proxy fully out of the steady path) or only pool/route normally and hand off during drain/deploy?

**Decision to lock:** (1) fire-and-forget every connection vs handoff-on-drain; (2) how `orchd` obtains
`CAP_NET_ADMIN` for the Linux pod setup; (3) is the zero-downtime-deploy handoff test a beta requirement?

**Effort:** the handoff data path (all platforms) = integration + test on the existing primitive, ~days.
The Linux isolation fence (netns + veth + privilege + spawn-with-inherited-fd) is the larger, separable
piece — ~1-2 weeks, needs a Linux host to verify. Ship handoff first; add the Linux fence second.

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
5. **Gap 6 (orchestrator fd-handoff: wire-if-needed + zero-downtime-deploy test)** and the **§B bug
   reverify** — integration + test on an existing primitive.
6. **Gap 5 (perf-B)** and **Gap 4 (debugger)** — bigger, post-beta unless a use-case forces them early.
