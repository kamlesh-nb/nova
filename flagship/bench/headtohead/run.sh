#!/usr/bin/env bash
# Head-to-head: Nova (web.App) vs Go (net/http) vs Rust (axum) vs C# (ASP.NET minimal API).
# Each serves the SAME constant JSON at GET /. We build release, warm up, then load with `oha`.
# Missing toolchains and failed builds are skipped, not fatal. Requires `oha` for the load phase.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LANG_ROOT="$(cd "$HERE/../../.." && pwd)"   # the lang/ repo root
DUR="${DUR:-15s}"
CONN="${CONN:-64}"
WARM="${WARM:-4s}"
RESULTS=()

have() { command -v "$1" >/dev/null 2>&1; }

# oha prints a text summary containing a "Requests/sec:" line under --no-tui.
measure() { oha --no-tui -z "$DUR" -c "$CONN" "$1" 2>/dev/null | grep -iE "Requests/sec" | head -1 | awk '{print $2}'; }

wait_up() {  # $1=url  -> 0 when it answers, 1 after ~10s
  for _ in $(seq 1 100); do curl -fs "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1
}

run_one() {  # $1=name  $2=port  $3=start-command (backgrounded)
  local name="$1" port="$2" cmd="$3" url="http://127.0.0.1:$2/"
  printf "\n[%s] starting on :%s\n" "$name" "$port"
  PORT="$port" bash -c "$cmd" >/tmp/h2h_$name.log 2>&1 &
  local pid=$!
  if ! wait_up "$url"; then
    echo "[$name] did not come up (see /tmp/h2h_$name.log)"; kill $pid 2>/dev/null; wait $pid 2>/dev/null; return
  fi
  echo "[$name] up; sanity: $(curl -s "$url")"
  echo "[$name] warm-up ${WARM}"; oha --no-tui -z "$WARM" -c "$CONN" "$url" >/dev/null 2>&1
  echo "[$name] measuring ${DUR} @ ${CONN} conns"
  local rps; rps="$(measure "$url")"
  RESULTS+=("$name|$rps")
  echo "[$name] Requests/sec: $rps"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  sleep 1
}

if ! have oha; then echo "oha not installed — install it to run the load phase (brew install oha)"; exit 1; fi

# ---- Nova (web.App) ----
if have nova; then
  echo "building Nova (release)..."
  if nova "$HERE/nova/server.nova" --release -o /tmp/h2h_nova >/tmp/h2h_nova_build.log 2>&1; then
    run_one nova 8080 "/tmp/h2h_nova"
  else echo "nova build FAILED (see /tmp/h2h_nova_build.log)"; fi
fi

# ---- Go (net/http) ----
if have go; then
  echo "building Go (release)..."
  if (cd "$HERE/go" && go build -o /tmp/h2h_go .) >/tmp/h2h_go_build.log 2>&1; then
    run_one go 8081 "/tmp/h2h_go"
  else echo "go build FAILED (see /tmp/h2h_go_build.log)"; fi
fi

# ---- Rust (axum) ----
if have cargo; then
  echo "building Rust (release; first build downloads crates)..."
  if (cd "$HERE/rust" && cargo build --release) >/tmp/h2h_rust_build.log 2>&1; then
    run_one rust 8082 "$HERE/rust/target/release/bench"
  else echo "rust build FAILED (likely offline / no crates.io — see /tmp/h2h_rust_build.log)"; fi
fi

# ---- C# (ASP.NET minimal API) ----
if have dotnet; then
  echo "building C# (Release)..."
  if (cd "$HERE/csharp" && dotnet publish -c Release -o /tmp/h2h_cs_pub) >/tmp/h2h_cs_build.log 2>&1; then
    run_one csharp 8083 "/tmp/h2h_cs_pub/bench"
  else echo "dotnet build FAILED (see /tmp/h2h_cs_build.log)"; fi
fi

echo ""
echo "================= HEAD-TO-HEAD (GET / constant JSON, ${DUR} @ ${CONN} conns) ================="
printf "%-10s %15s\n" "language" "Requests/sec"
printf "%-10s %15s\n" "--------" "------------"
for r in "${RESULTS[@]}"; do printf "%-10s %15s\n" "${r%%|*}" "${r##*|}"; done
echo "hardware: $(uname -m), $(sysctl -n hw.ncpu 2>/dev/null || nproc) cores"
