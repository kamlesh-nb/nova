#!/usr/bin/env bash
# Integrated fd-passing handoff: the REAL proxyd + the REAL web app, both in handoff mode.
#
# proxyd (NOVA_HANDOFF_SOCK set) binds a TCP front port and an AF_UNIX rendezvous, and hands each
# accepted client SOCKET to a backend app over the rendezvous (SCM_RIGHTS). Each app (NOVA_HANDOFF_SOCK
# set) connects to the rendezvous and serves handed-off sockets on its reactor, replying to the client
# directly. proxyd is out of the data path: it does not parse HTTP or copy response bytes.
#
# Contrast with the classic mode (no NOVA_HANDOFF_SOCK): proxyd reads the request, forwards it to a
# backend over a pooled TCP connection, and streams the response back (in the data path).
set -u
export PATH="$HOME/.nova/bin:$PATH"
REPO=/Users/kamlesh/nova-lang
PROXYD="$REPO/packages/nova-orchestrator/build/debug/bin/proxyd"
APP="$REPO/lang/docs/guide/examples/webapp/build/debug/bin/webapp"
SOCK=/tmp/nova_proxyd_handoff.sock

cleanup(){ pkill -9 -x proxyd 2>/dev/null; pkill -9 -x webapp 2>/dev/null; rm -f "$SOCK"; }
trap cleanup EXIT
cleanup; sleep 0.3

[ -x "$PROXYD" ] || { echo "build proxyd first: (cd packages/nova-orchestrator && ./build.sh)"; exit 1; }
[ -x "$APP" ]    || { echo "build the app first: (cd lang/docs/guide/examples/webapp && nova build)"; exit 1; }

echo "starting proxyd (fd-handoff, TCP :8095, rendezvous $SOCK) ..."
NOVA_HANDOFF_SOCK="$SOCK" NOVA_PORT=8095 PROXYD_CONFIG="$REPO/packages/nova-orchestrator/proxyd.json" "$PROXYD" & sleep 1
echo "starting two apps in handoff mode ..."
NOVA_HANDOFF_SOCK="$SOCK" "$APP" &
NOVA_HANDOFF_SOCK="$SOCK" "$APP" &
sleep 1.5

echo "--- POST a product (round-robins to one app), then GET it back from THAT app may 404 on the other ---"
curl -s -m 3 -X POST -H 'Content-Type: application/json' -d '{"name":"Keyboard","price":4500}' http://127.0.0.1:8095/api/products; echo
echo "--- GET /api/products/1 through the handoff proxy ---"
curl -s -m 3 http://127.0.0.1:8095/api/products/1; echo

if command -v oha >/dev/null 2>&1; then
  echo "--- load through the fd-handoff proxy (n=20000 c=32) ---"
  oha -n 20000 -c 32 --no-tui http://127.0.0.1:8095/api/products/1 2>&1 | grep -iE "Success rate|Requests/sec|Status code|\[[0-9]"
fi
echo "done."
