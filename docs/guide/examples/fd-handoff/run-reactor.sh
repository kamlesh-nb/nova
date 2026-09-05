#!/usr/bin/env bash
# Verify the SCM_RIGHTS fd-handoff on BOTH Linux reactor backends -- the open item in CLAUDE.md
# ("works on kqueue/epoll; what remains is verifying it on io_uring").
#
# run.sh proves the handoff mechanic, but its worker serves the client with BLOCKING send/recv and so
# never enters the reactor: KYTE_REACTOR=uring changes nothing there and KYTE_IO_WATCHDOG=1 prints
# nothing, because no reactor loop is ever driven. It therefore cannot verify io_uring, no matter what
# the environment says.
#
# worker_async.ky closes that gap by registering the INHERITED descriptor with net.poller.Reactor
# and polling it before replying. Same binary both times; only KYTE_REACTOR differs, which is what
# makes the comparison meaningful -- a difference in outcome can only come from the backend.
set -u
export PATH="$HOME/.kyte/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

N="${N:-300}"          # requests per backend
CONC="${CONC:-8}"

# Kill the previous run and WAIT for the listener to actually disappear, rather than sleeping a
# guessed interval. `kill` only requests exit; the port stays bound until the process is reaped, and
# a fixed sleep raced it -- the second backend then died with "TCP :8099 bind failed", which reads
# like a backend problem and is purely a harness one. (SO_REUSEADDR is already set by listenAny, so
# TIME_WAIT is not the cause and adding a longer sleep would not have fixed it either.)
port_busy() { ss -ltn 2>/dev/null | grep -q ':8099 '; }

cleanup() {
  pkill -9 -x router >/dev/null 2>&1
  pkill -9 -x worker_async >/dev/null 2>&1
  rm -f /tmp/kyte_handoff.sock
  local i=0
  while port_busy && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
  [[ $i -ge 100 ]] && echo "  WARNING: :8099 still bound after 10s"
  return 0
}
trap cleanup EXIT

build() {
  kyte router.ky       -o router       >/dev/null 2>&1 || { echo "router build failed";  exit 1; }
  kyte worker_async.ky -o worker_async >/dev/null 2>&1 || { echo "worker build failed";  exit 1; }
}

# $1 = backend label passed as KYTE_REACTOR ("epoll" is not a recognised value -- anything that is not
# uring/io_uring falls through to epoll, which is exactly the default path we want to compare against).
run_backend() {
  local backend="$1" rc=0
  cleanup
  echo "=================================================================="
  echo " backend: KYTE_REACTOR=$backend"
  echo "=================================================================="

  KYTE_REACTOR="$backend" WORKERS=2 ./router >/tmp/kyte_router_$backend.log 2>&1 &
  sleep 1.2
  KYTE_REACTOR="$backend" WORKER_ID=A ./worker_async >/tmp/kyte_wa_$backend.log 2>&1 &
  KYTE_REACTOR="$backend" WORKER_ID=B ./worker_async >/tmp/kyte_wb_$backend.log 2>&1 &
  sleep 1.5

  if ! grep -q "up;" /tmp/kyte_router_$backend.log 2>/dev/null; then
    echo "  ROUTER FAILED TO START:"; sed 's/^/    /' /tmp/kyte_router_$backend.log; return 1
  fi

  echo "--- 4 sample requests (reply comes straight from the worker) ---"
  for i in 1 2 3 4; do
    curl -s -m 5 "http://127.0.0.1:8099/req$i" || { echo "  curl FAILED"; rc=1; }
    echo
  done

  # Fixed request COUNT, never a time box: a time-boxed run stops at the deadline without waiting for
  # outstanding requests and reports 100% success while stranding connections (see CLAUDE.md).
  if command -v oha >/dev/null 2>&1; then
    echo "--- $N requests, concurrency $CONC ---"
    oha -n "$N" -c "$CONC" --no-tui "http://127.0.0.1:8099/bench" 2>&1 \
      | grep -iE "Success rate|Requests/sec|^\s+\[200\]|^\s+\[5[0-9][0-9]\]|Error distribution"
  fi

  echo "--- worker A said ---"; sed 's/^/    /' /tmp/kyte_wa_$backend.log
  if grep -qi "FAILED to arm" /tmp/kyte_wa_$backend.log /tmp/kyte_wb_$backend.log 2>/dev/null; then
    echo "  *** ARMING AN INHERITED FD ON THE REACTOR FAILED ***"; rc=1
  fi

  # Kill the router FIRST: closing the control channel is what makes each worker's recvFd return
  # -1, which is its normal shutdown path and prints the served/via_reactor tally we want to read.
  pkill -9 -x router >/dev/null 2>&1
  sleep 0.4
  echo "--- worker A on shutdown ---"; sed 's/^/    /' /tmp/kyte_wa_$backend.log
  pkill -9 -x worker_async >/dev/null 2>&1
  cleanup
  return $rc
}

build
fail=0
run_backend epoll || fail=1
run_backend uring || fail=1

echo
if [[ $fail -eq 0 ]]; then
  echo "RESULT: fd-handoff serves correctly on BOTH backends."
else
  echo "RESULT: at least one backend FAILED -- see the logs above."
fi
exit $fail
