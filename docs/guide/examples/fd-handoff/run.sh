#!/usr/bin/env bash
# Fire-and-forget proxy PROTOTYPE: fd-passing (SCM_RIGHTS) connection handoff.
#
# The router (proxy role) accepts TCP clients and hands each client SOCKET to a worker (app role)
# over a named AF_UNIX rendezvous socket. The worker then writes the HTTP response DIRECTLY to the
# client; the router is out of the data path. With WORKERS=2 the router round-robins the handoff
# across two workers, which is the proxy -> N app-replicas shape.
#
# This is a synchronous, blocking prototype that proves the mechanic (not the reactor throughput path).
set -u
export PATH="$HOME/.kyte/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

cleanup() { pkill -9 -x router 2>/dev/null; pkill -9 -x worker 2>/dev/null; rm -f /tmp/kyte_handoff.sock; }
trap cleanup EXIT
cleanup; sleep 0.3

echo "building router + worker ..."
kyte router.ky -o router  >/dev/null || { echo "router build failed"; exit 1; }
kyte worker.ky -o worker  >/dev/null || { echo "worker build failed"; exit 1; }

echo "starting router (TCP :8099) with WORKERS=2 ..."
WORKERS=2 ./router & sleep 1
echo "starting two workers (app-A, app-B) ..."
WORKER_ID=app-A ./worker &
WORKER_ID=app-B ./worker &
sleep 1

echo "--- 6 requests through the router; replies come straight from the workers, round-robin ---"
for i in 1 2 3 4 5 6; do curl -s -m 3 "http://127.0.0.1:8099/api/products/$i"; echo; done

if command -v oha >/dev/null 2>&1; then
  echo "--- 2000-request correctness check through the fd-passing router ---"
  oha -n 2000 -c 16 --no-tui http://127.0.0.1:8099/bench 2>&1 | grep -iE "Success rate|Requests/sec|\[200\]|\[5"
fi
echo "done."
