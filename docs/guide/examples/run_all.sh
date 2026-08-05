#!/usr/bin/env bash
# Compile + run every guide example, reporting pass/fail. Run from anywhere.
# Examples that define @test run via `nova test`; the rest compile to a binary and execute.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
NOVA="${NOVA:-$HOME/.nova/bin/nova}"
# Absolutise NOVA so it still resolves after we `cd` into the web-app project below.
case "$NOVA" in
  /*) ;;
  */*) NOVA="$(cd "$(dirname "$NOVA")" && pwd)/$(basename "$NOVA")" ;;
esac
fail=0
for f in "$HERE"/*.nova; do
  name="$(basename "$f")"
  if grep -q '@test' "$f"; then
    out="$("$NOVA" test "$f" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then echo "PASS (test) $name"; else echo "FAIL (test) $name"; echo "$out" | tail -5; fail=1; fi
  else
    bin="/tmp/nova_guide_${name%.nova}"
    out="$("$NOVA" "$f" -o "$bin" 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then echo "FAIL (compile) $name"; echo "$out" | grep -i error | head -3; fail=1; continue; fi
    if "$bin" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL (run) $name"; fail=1; fi
  fi
done

# The web example is a full `nova init web` project (Features/ slices, typed handlers), not a single
# file. Build it and run its feature tests.
WEBAPP="$HERE/webapp"
if [ -d "$WEBAPP" ]; then
  if ( cd "$WEBAPP" && "$NOVA" build >/dev/null 2>&1 ); then echo "PASS (build) webapp"; else echo "FAIL (build) webapp"; fail=1; fi
  wout="$("$NOVA" test "$WEBAPP/tests/features/products_test.nova" 2>&1)"; wrc=$?
  if [ $wrc -eq 0 ]; then echo "PASS (test) webapp"; else echo "FAIL (test) webapp"; echo "$wout" | tail -5; fail=1; fi

  # The NovaDB-backed build of the SAME app (main_novadb.nova). Running it needs a live NovaDB server
  # (see run-live.sh), so here we only compile-check it. It imports the novadb driver from packages/,
  # so symlink packages/ into the project first (transient; gitignored), then remove it.
  ln -sfn "$HERE/../../../../packages" "$WEBAPP/packages"
  if ( cd "$WEBAPP" && "$NOVA" build --file src/main_novadb.nova -o /tmp/nova_guide_webapp_novadb >/dev/null 2>&1 ); then echo "PASS (compile) webapp[novadb]"; else echo "FAIL (compile) webapp[novadb]"; fail=1; fi
  rm -f "$WEBAPP/packages"

  rm -rf "$WEBAPP/build" "$WEBAPP/__nova_test" "$WEBAPP/__nova_test.ll"
fi

exit $fail
