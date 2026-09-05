#!/usr/bin/env bash
# Codegen SOUNDNESS fuzzer wrapper (F2-6 W11). Thin CI-parity wrapper over codegen_fuzz.py.
#
# Unlike fuzz.sh (front-end crash fuzzer: "the compiler must not crash"), this generates WELL-TYPED
# programs with a known answer (a Python oracle of Kyte's integer semantics), compiles+runs each, and
# fails on a MISCOMPILE (answer != oracle) -- the class fuzz.sh cannot catch. Each program is a full
# compile+run (~0.4s), so N is modest by default; raise it for a soak.
#
#   conformance/codegen_fuzz.sh                 # KYTE_CGFUZZ_N iterations
#   KYTE_CGFUZZ_N=1000 conformance/codegen_fuzz.sh
#   KYTE_CGFUZZ_SEED=42 conformance/codegen_fuzz.sh
#
# Exits non-zero and keeps the offending .ky under fuzz-artifacts/ on the first miscompile.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.kyte/bin:$PATH"
N="${KYTE_CGFUZZ_N:-120}"
SEED="${KYTE_CGFUZZ_SEED:-1}"
exec python3 "$here/codegen_fuzz.py" --n "$N" --seed "$SEED"
