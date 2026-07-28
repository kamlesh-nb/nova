#!/usr/bin/env bash
# Load-test the minimal HTTP server built on the Nova-owned event loop (net/reactor over kqueue,
# no Asio, no web.App). Same constant JSON and same oha settings as the head-to-head peers, so the
# number is directly comparable. This is the gap-8 measurement of docs/design/self-hosted-runtime.md.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LANG_ROOT="$(cd "$HERE/../../.." && pwd)"
DUR="${DUR:-15s}"; CONN="${CONN:-64}"; PORT="${PORT:-8099}"

command -v oha >/dev/null 2>&1 || { echo "oha not installed"; exit 1; }

# SERVER=coro measures the coroutine handler; anything else measures the callback loop.
SRC="server.nova"; [ "${SERVER:-}" = "coro" ] && SRC="server_coro.nova"
echo "building the Nova reactor server ($SRC, release)..."
nova "$HERE/$SRC" --release -o /tmp/nova_reactor || { echo "build failed"; exit 1; }

PORT="$PORT" /tmp/nova_reactor >/tmp/nova_reactor.log 2>&1 &
srv=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
echo "up; sanity: $(curl -s http://127.0.0.1:$PORT/)"
echo "warm-up..."; oha --no-tui -z 4s -c "$CONN" "http://127.0.0.1:$PORT/" >/dev/null 2>&1
echo "measuring $DUR @ $CONN conns (single reactor, one core)..."
oha --no-tui -z "$DUR" -c "$CONN" "http://127.0.0.1:$PORT/" 2>&1 | grep -iE "Requests/sec|Success rate|Average:"
kill -9 "$srv" 2>/dev/null
echo "hardware: $(uname -m), $(sysctl -n hw.ncpu 2>/dev/null) cores (server used ONE)"
