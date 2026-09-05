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

  # The PostgreSQL-backed build of the SAME app (main_postgres.nova, at the project root so it never
  # clashes with the in-memory src/main.nova). Running it needs a live PostgreSQL server (see
  # run-live.sh), so here we only COMPILE-check it: copy the project to a temp dir, swap
  # main_postgres.nova in as src/main.nova, wire the nova-postgres dependency, and point packages/ at the
  # monorepo so no network is needed.
  PKGS="$(cd "$HERE/../../../../packages" && pwd)"
  if [ -f "$WEBAPP/main_postgres.nova" ] && [ -d "$PKGS/nova-postgres" ]; then
    TMPW="$(mktemp -d)"
    cp -r "$WEBAPP" "$TMPW/webapp"; ( cd "$TMPW/webapp" && rm -rf build packages )
    mv "$TMPW/webapp/main_postgres.nova" "$TMPW/webapp/src/main.nova"
    python3 - "$TMPW/webapp/project.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["dependencies"]=["https://github.com/kamlesh-nb/nova-postgres"]
json.dump(d,open(p,"w"),indent=2)
PY
    ln -sfn "$PKGS" "$TMPW/webapp/packages"
    if ( cd "$TMPW/webapp" && "$NOVA" build >/dev/null 2>&1 ); then echo "PASS (compile) webapp[postgres]"; else echo "FAIL (compile) webapp[postgres]"; fail=1; fi
    rm -rf "$TMPW"
  fi

  rm -rf "$WEBAPP/build" "$WEBAPP/__nova_test" "$WEBAPP/__nova_test.ll"
fi

exit $fail
