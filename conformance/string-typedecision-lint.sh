#!/usr/bin/env bash
# Baseline-gated lint for the string->TypeId cutover (docs/design/string-to-typeid-cutover.md).
# The string engine is being removed: type DECISIONS must route through a TypeId predicate
# (store.get(tid) / isStringExpr / isOwnedTypeId / ...), NOT a comparison against a rendered type-name
# spelling. This counts the remaining string type-name comparisons in src/codegen and FAILS if the count
# increases above the baseline. Lower BASELINE whenever sites migrate; the target is 0.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

BASELINE=55
count=$(grep -rcE 'std\.mem\.eql\(u8, [a-z_]+, "(int|long|string|bool|byte|short|double|float|void|any|char|f32|f64|decimal|i32|i64|u32|u64)"\)' src/codegen/*.zig | awk -F: '{s+=$2} END {print s+0}')
echo "codegen string type-decisions: $count (baseline $BASELINE, target 0)"
if [ "$count" -gt "$BASELINE" ]; then
  echo "LINT FAIL: string type-decisions increased $BASELINE -> $count."
  echo "  Route the new decision through a TypeId predicate (store.get(tid) / isStringExpr / isOwnedTypeId),"
  echo "  not a std.mem.eql against a rendered type name. See docs/design/string-to-typeid-cutover.md."
  exit 1
fi
if [ "$count" -lt "$BASELINE" ]; then
  echo "NOTE: string type-decisions dropped to $count; lower BASELINE in $(basename "$0") to $count to ratchet."
fi
exit 0
