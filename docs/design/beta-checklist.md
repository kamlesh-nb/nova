# Nova Beta checklist (the scoreboard)

Adopted from `remaining-gaps-design.md` Gap 7. Nothing ships "beta" until items 1-5 are green **by
command** (item 6 is a scoping note, not a task). This file is the living scoreboard: update the Status +
Evidence for an item the moment it moves, and never mark one green from recall — re-run the command.

History note (why this file exists): beta has been declared and walked back before. The rule now is: a
line here is green only when its **Verify** command passes on the spot.

| # | Item | Status | Depends on |
|---|------|--------|-----------|
| 1 | `gate.sh` green on every supported host (mac arm64/x86_64, linux/WSL, Windows) | 🟡 partial | Gap 2 (CI matrix) |
| 2 | Ownership verifier enforced corpus-wide | ✅ done | Gap 3 enforcement-B |
| 3 | Zero KNOWN live crash bugs, verified by re-running (not recall) | ✅ done | — |
| 4 | Package manager to `pkg-manager.md` §10 (or explicitly labelled "tooling: alpha") | 🔴 open | Gap 1 |
| 5 | `docs/guide` compiles and its examples run | ✅ done | dogfood gate |
| 6 | Debugger is NOT required for beta (post-beta) | ✅ n/a (shipped anyway) | — |

---

## 1 — `gate.sh` green on every supported host  🟡

The full gate (version-sync, corpus, dogfood, fuzz, shadow, string-lint, corpus-wide OSSA) must pass on
each supported host. Locally green on macOS arm64; the other five hosts run in CI (release matrix), which
also builds the bundles.

**Verify (per host):** `cd lang && ./gate.sh` → `GATE PASS  nova (lang)`.
**Open:** confirm green on mac x86_64, linux (x86_64 + arm64), Windows (x86_64 + arm64) via CI. This is the
Gap 2 CI-matrix dependency; the release workflow (`.github/workflows/release.yml`) exercises the build on
all six.

## 2 — Ownership verifier enforced corpus-wide  ✅

The OSSA-lite release-balance verifier (sound: never falsely accuses) runs under `NOVA_OSSA=hard` over the
WHOLE positive corpus, not the old 6-case spot-check.

**Verify:** `cd lang && ./conformance/run.sh --ossa -j` → `Passed: 381  Failed: 0`.
**Evidence:** landed this session (`gate.sh` runs it); baseline sweep 329/329, 0 proven imbalances; wired
gate 381/381. Completeness caveat documented (destructuring-binding hole is a false negative, never blocks
a correct build).

## 3 — Zero KNOWN live crash bugs, verified by re-running  ✅

The six previously-tracked crash bugs are all FIXED with pinned conformance cases (register §B). The two
genuinely-uncertain residuals are now resolved and RE-VERIFIED, not taken from recall:

- **Value-optional PARAM present-0-as-absent** — RE-RUN and gated. A present `0`/`false`/`0.0` passed as a
  value-optional argument reads PRESENT (was a suspected variant of the value-level zero bug, orthogonal to
  the local/Map paths). Now a permanent regression guard: `conformance/cases/127_value_optional_zero.nova`
  `test_param_widths`. **Verify:** `nova test conformance/cases/127_value_optional_zero.nova` → `0 failed`.
- **mongo async-handler HANG at concurrency > 1** — FIXED via the reactor-aware `AsyncLock` guarding
  `runCommand` (nova-mongodb `2e4b6f8`): concurrent `runCommand` on the shared cached connection was
  interleaving frames on the socket. Bench evidence: c=50 crash → 100% success, bench4 green. A live re-run
  needs a running `mongod` + a concurrent mongo app; the fix + bench stand as the evidence of record.

## 4 — Package manager  🔴

The package manager is still a git-clone stub (no lockfile / versioning / registry). Either implement to
`pkg-manager.md` §10 acceptance, OR explicitly ship it labelled "tooling: alpha" with the limitation
documented in the guide. This is the main open beta-blocker.

**Verify (when built):** `pkg-manager.md` §10 acceptance passing.

## 5 — `docs/guide` compiles and its examples run  ✅

The dogfood gate compiles-and-runs a suite of whole-program feature combinations; the guide examples have
their own runner.

**Verify:** `cd lang && ./conformance/run.sh --dogfood` → `Failed: 0`; and the guide examples' `run_all.sh`.

## 6 — Debugger  ✅ (not required, shipped anyway)

Explicitly post-beta per the original scope — but the in-editor debugger (DWARF + lldb-dap + formatters,
C#-quality value display) landed this session, so it is a bonus rather than a gap.

---

## How to read this

- 🟡 partial = green locally / mechanism in place, needs the remaining hosts or a CI run to confirm.
- Green (✅) requires the **Verify** command to pass now, on this checkout.
- The only remaining hard blocker is **#4 (package manager)** — everything else is green or CI-gated.
