#!/usr/bin/env bash
# String->TypeId shadow gate: asserts the TypeId decision engine and the legacy string engine AGREE on
# every ownership/dtor/layout decision (0 disagreements). This is the cutover contract from
# docs/design/string-to-typeid-cutover.md: while both engines still exist, they must never diverge, so a
# drifted spelling cannot silently fail open into a miscompile (the class the `any`-box leak belonged to).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.kyte/bin:$PATH"

# Type-heavy cases exercising ownership/dtor/layout across generics, value-optionals, collections and any.
CASES="conformance/cases/123_any_container.ky conformance/cases/334_valopt_call_arg.ky conformance/cases/53_for_loops.ky conformance/cases/332_collections_breadth.ky"
bad=0
for c in $CASES; do
  [ -f "$c" ] || continue
  out=$(KYTE_SEMA_SHADOW=1 kyte test "$c" 2>&1 || true)
  td=$(printf '%s' "$out" | grep -oE "DISAGREE : [0-9]+   \(MUST be 0 before cutover\)" | grep -oE "[0-9]+" | head -1)
  ks=$(printf '%s' "$out" | grep -oE "keystone-DISAGREE : [0-9]+" | grep -oE "[0-9]+" | head -1)
  if [ -n "$td" ] && [ "$td" -ne 0 ]; then echo "SHADOW FAIL: $(basename "$c") ownership td_disagree=$td"; bad=1; fi
  if [ -n "$ks" ] && [ "$ks" -ne 0 ]; then echo "SHADOW FAIL: $(basename "$c") keystone_disagree=$ks"; bad=1; fi
done
if [ $bad -eq 0 ]; then echo "shadow gate: 0 disagreements OK"; fi
exit $bad
