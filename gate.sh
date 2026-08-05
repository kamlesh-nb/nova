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
  step "compiler fuzz (fixed-seed regression smoke; scale via NOVA_FUZZ_N/SEED for exploration)"
  NOVA_FUZZ_N="${NOVA_FUZZ_N:-40}" conformance/fuzz.sh || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  nova (lang)  [$OS]"; else echo "GATE FAIL  nova (lang)  [$OS]"; fi
exit $fail
