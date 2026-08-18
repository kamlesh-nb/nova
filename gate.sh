#!/usr/bin/env bash
# Host gate for the Nova language (compiler + runtime + stdlib). Builds and runs the full gate suite on
# THIS host OS, exiting non-zero on any failure. Nova's native toolchain (LLVM + the C++/Boost runtime)
# cannot build on hosted GitHub Actions, so every host runs its own gate -- see CI-POLICY.md. Nothing
# merges red.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.nova/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

step "zig build (compiler + runtime + stdlib, installs nova)"
zig build || fail=1

if [ $fail -eq 0 ] && [ -x scripts/check-version-sync.sh ]; then
  step "version sync"
  scripts/check-version-sync.sh || fail=1
fi

if [ $fail -eq 0 ]; then
  step "conformance corpus (parallel)"
  # -j runs the positive corpus across cores-1 workers; the harness self-test + expect_fail gates run after.
  conformance/run.sh -j || fail=1
fi

if [ $fail -eq 0 ]; then
  step "dogfood suite (realistic feature-combination whole programs; must compile + exit 0)"
  # Inherits NOVA_ASAN: plain here catches crashes; run `NOVA_ASAN=1 conformance/run.sh --dogfood`
  # separately (after a sanitized build) for use-after-free coverage.
  conformance/run.sh --dogfood || fail=1
fi

if [ $fail -eq 0 ]; then
  step "compiler fuzz (fixed-seed regression smoke; scale via NOVA_FUZZ_N/SEED for exploration)"
  NOVA_FUZZ_N="${NOVA_FUZZ_N:-40}" conformance/fuzz.sh || fail=1
fi

if [ $fail -eq 0 ]; then
  step "string->TypeId shadow gate (0 disagreements: TypeId engine == string engine)"
  bash conformance/shadow-gate.sh || fail=1
fi

if [ $fail -eq 0 ]; then
  step "string type-decision lint (no NEW codegen string type-decisions; ratchet toward 0)"
  bash conformance/string-typedecision-lint.sh || fail=1
fi

if [ $fail -eq 0 ]; then
  step "OSSA ownership gate, CORPUS-WIDE (release-balance verifier: 0 proven leaks/double-frees)"
  # Enforcement-B (remaining-gaps-design.md, Gap 3): compile EVERY positive case under NOVA_OSSA=hard, not
  # the 6-case spot-check in ossa-gate.sh. The verifier runs during sema (cheap), so this only adds a
  # compile pass; -j runs it across cores-1 workers. Verified 381/381 clean when wired.
  conformance/run.sh --ossa -j || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  nova (lang)  [$OS]"; else echo "GATE FAIL  nova (lang)  [$OS]"; fi
exit $fail
