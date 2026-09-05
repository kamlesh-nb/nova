#!/usr/bin/env bash
# QUICK spot-check (6 type-heavy cases) for fast local iteration. The AUTHORITATIVE gate is now
# CORPUS-WIDE: `conformance/run.sh --ossa [-j]` compiles every positive case under KYTE_OSSA=hard, and
# gate.sh runs THAT (Gap 3 enforcement-B, remaining-gaps-design.md). This script stays as a seconds-long
# smoke you can run by hand without sweeping the whole corpus.
#
# OSSA ownership gate: the OSSA-lite lowering + release-balance verifier (docs/design/ossa-lite-tasks.md)
# must find ZERO release imbalances (a leak or double-free it proved) on every function it fully models.
# Run with KYTE_OSSA=hard so a proven imbalance fails the compile; this script asserts no gate failure on
# a set of type-heavy programs that, together with the whole stdlib each compile pulls in, exercise owned
# locals across all control flow (branches, loops, for-in, switch, break/continue, nested scopes).
#
# Note on scope: the verifier is SOUND (it never falsely accuses) but not complete — destructured
# bindings are untracked, so a leak THROUGH a destructuring pattern is not caught here. The gate therefore
# proves "no proven imbalance", not "no possible leak". See the tasks doc.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.kyte/bin:$PATH"

CASES="conformance/cases/02_generics_destructor.ky conformance/cases/13_serde.ky \
conformance/cases/14_collections_map.ky conformance/cases/53_for_loops.ky \
conformance/cases/332_collections_breadth.ky conformance/cases/03_strings.ky"

bad=0
for c in $CASES; do
  [ -f "$c" ] || continue
  out=$(KYTE_OSSA=hard kyte test "$c" 2>&1 || true)
  if printf '%s' "$out" | grep -q "OSSA OWNERSHIP GATE FAILED"; then
    n=$(printf '%s' "$out" | grep -oE "GATE FAILED:.[0-9m]*[0-9]+ function" | grep -oE "[0-9]+ function" | grep -oE "[0-9]+")
    echo "OSSA GATE FAIL: $(basename "$c") — ${n:-?} imbalanced function(s)"
    bad=1
  fi
done
if [ $bad -eq 0 ]; then echo "ossa gate: 0 release imbalances OK"; fi
exit $bad
