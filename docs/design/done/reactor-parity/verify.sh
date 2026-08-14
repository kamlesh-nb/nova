#!/usr/bin/env bash
# Runtime-verify the deadline-timer path (nova_reactor_set_timer + opDone + abandonOp) that the
# connect/TLS/recv deadlines depend on, on the completion/readiness backends. macOS/kqueue runs
# natively; Linux epoll + io_uring run the same cross-compiled static ELF in a Debian container.
# Expected on every backend: "timeout case: got=998", "complete case: got=1002", "PARITY OK".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "== macOS / kqueue =="; nova "$HERE/deadline_parity.nova" -o /tmp/dlp_mac && /tmp/dlp_mac
nova "$HERE/deadline_parity.nova" --target linux-x86_64 -o /tmp/dlp_linux
echo "== Linux / epoll ==";     docker run --rm -v /tmp/dlp_linux:/dlp:ro debian:stable-slim /dlp
echo "== Linux / io_uring =="; docker run --rm -e NOVA_REACTOR=uring -v /tmp/dlp_linux:/dlp:ro debian:stable-slim /dlp
