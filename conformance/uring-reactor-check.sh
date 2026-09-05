#!/usr/bin/env bash
# Run the reactor-dependent conformance cases under BOTH Linux backends and diff the verdicts.
#
# The corpus never does this: run.sh selects no backend, so every case runs on epoll (the default)
# and io_uring is only ever exercised by hand. CLAUDE.md's claim that "epoll and io_uring have
# IDENTICAL failure lists" therefore has no gate behind it -- this script is that gate.
set -u
export PATH="$HOME/.kyte/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"

CASES="192_reactor_echo 194_coroutine_reactor 195_multicore_reactors 199_reactor_nested_await
200_reactor_async_io 201_reactor_tcp_connect_accept 202_asyncstream_on_reactor
203_reactor_resolve_connect 204_app_request_on_reactor 207_reactor_native_timer
208_reactor_read_deadline 210_cross_reactor_wakeup 212_eventloop_completion_echo"

run_one() {   # $1 = case, $2 = backend
  local case="$1" backend="$2" d out rc
  d="$(mktemp -d)"
  out="$(cd "$d" && KYTE_REACTOR="$backend" timeout -k 5 120 kyte test "$HERE/cases/$case.ky" 2>&1)"
  rc=$?
  rm -rf "$d"
  if [[ $rc -eq 0 ]] && grep -q "0 failed" <<<"$out"; then echo "PASS"
  elif [[ $rc -eq 124 ]] || [[ $rc -ge 128 ]]; then echo "TIMEOUT/SIGNAL($rc)"
  else echo "FAIL($rc)"; fi
}

printf '%-34s %-10s %-10s\n' CASE epoll io_uring
printf '%-34s %-10s %-10s\n' "----" "-----" "--------"
differs=0
for c in $CASES; do
  [[ -f "$HERE/cases/$c.ky" ]] || { printf '%-34s %s\n' "$c" "(absent)"; continue; }
  e="$(run_one "$c" epoll)"
  u="$(run_one "$c" uring)"
  mark=""
  if [[ "$e" != "$u" ]]; then mark="   <-- DIFFERS"; differs=1; fi
  printf '%-34s %-10s %-10s%s\n' "$c" "$e" "$u" "$mark"
done

echo
if [[ $differs -eq 0 ]]; then
  echo "RESULT: epoll and io_uring agree on every case above."
else
  echo "RESULT: the backends DISAGREE on at least one case."
fi
exit $differs
