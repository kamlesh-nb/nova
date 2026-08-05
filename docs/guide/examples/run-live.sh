#!/usr/bin/env bash
# End-to-end live demonstration: the guide web app, backed by a real NovaDB, then put behind the
# orchestrator (proxyd load-balancing two replicas, orchctl operating the config store).
#
# This is NOT part of the offline gate (run_all.sh) because it needs a running NovaDB server. It builds
# what it needs from the monorepo and cleans up after itself. Run it from anywhere:
#
#   lang/docs/guide/examples/run-live.sh
#
# Requirements: a built toolchain (`nova` on PATH or ~/.nova/bin), Zig (to build the NovaDB server), and
# curl. Everything else it builds.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"          # examples -> guide -> docs -> lang -> repo root
NOVA="${NOVA:-$HOME/.nova/bin/nova}"
WEBAPP="$HERE/webapp"
NOVADB="$REPO/novadb"
ORCH="$REPO/packages/nova-orchestrator"
WORK="$(mktemp -d)"
PIDS=()

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

cleanup() {
  say "cleanup"
  for p in "${PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done
  rm -f "$WEBAPP/packages"
  rm -rf "$WORK"
  note "stopped all processes, removed temp files"
}
trap cleanup EXIT INT TERM

wait_port() { # host port label
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; then exec 3>&- 3<&-; note "$3 is up on $1:$2"; return 0; fi
    sleep 0.2
  done
  note "TIMEOUT waiting for $3 on $1:$2"; return 1
}

# ---------------------------------------------------------------------------------------------------
say "1/5  build + start the NovaDB server on 127.0.0.1:3009"
if [ ! -x "$NOVADB/zig-out/bin/novadb" ]; then
  note "building NovaDB (zig build) ..."
  ( cd "$NOVADB" && zig build ) || { note "NovaDB build failed"; exit 1; }
fi
( cd "$NOVADB" && rm -rf data/nova.db data/wal && ./zig-out/bin/novadb ) >"$WORK/novadb.log" 2>&1 &
PIDS+=($!)
wait_port 127.0.0.1 3009 "NovaDB" || exit 1

# Seed the schema + a few rows ONCE, up front, over NovaDB's HTTP SQL endpoint (:3008). Doing it here
# (rather than letting each app replica seed on first connect) keeps the demo deterministic: two replicas
# connecting to a fresh database at the same moment would otherwise race to create + seed it.
seed() { curl -s -m 5 -X POST http://127.0.0.1:3008/query -H 'Content-Type: application/json' -d "{\"sql\": $1, \"session_token\": \"\"}" >/dev/null; }
seed '"CREATE TABLE IF NOT EXISTS products (id INT PRIMARY KEY, name TEXT, price INT)"'
seed '"INSERT INTO products (id, name, price) VALUES (1, '"'"'Keyboard'"'"', 4500)"'
seed '"INSERT INTO products (id, name, price) VALUES (2, '"'"'Mouse'"'"', 1800)"'
seed '"INSERT INTO products (id, name, price) VALUES (3, '"'"'Monitor'"'"', 22000)"'
note "seeded products 1..3 via the SQL endpoint"

# ---------------------------------------------------------------------------------------------------
say "2/5  build the NovaDB-backed web app (main_novadb.nova)"
ln -sfn "$REPO/packages" "$WEBAPP/packages"           # so `import novadb` resolves
( cd "$WEBAPP" && "$NOVA" build --file src/main_novadb.nova -o "$WORK/webapp" ) \
  || { note "web app build failed"; exit 1; }
note "built $WORK/webapp"

say "     start two replicas (NOVA_PORT) on 8080 and 8081"
( cd "$WEBAPP" && NOVA_PORT=8080 "$WORK/webapp" ) >"$WORK/app8080.log" 2>&1 & PIDS+=($!)
( cd "$WEBAPP" && NOVA_PORT=8081 "$WORK/webapp" ) >"$WORK/app8081.log" 2>&1 & PIDS+=($!)
wait_port 127.0.0.1 8080 "app replica A" || exit 1
wait_port 127.0.0.1 8081 "app replica B" || exit 1

# ---------------------------------------------------------------------------------------------------
say "3/5  exercise the app directly (write -> NovaDB -> read back)"
note "POST /api/products  (create)"
curl -s -X POST http://127.0.0.1:8080/api/products \
  -H 'Content-Type: application/json' -d '{"name":"Webcam","price":5500}' ; echo
note "GET /api/products/1  (read; served from NovaDB)"
curl -s http://127.0.0.1:8080/api/products/1 ; echo

# ---------------------------------------------------------------------------------------------------
say "4/5  put the app behind proxyd (data plane, load-balancing the two replicas)"
( cd "$ORCH" && ./build.sh ) >"$WORK/orch-build.log" 2>&1 || { note "orchestrator build failed"; exit 1; }
PROXYD="$ORCH/build/debug/bin/proxyd"
ORCHCTL="$ORCH/build/debug/bin/orchctl"

cat > "$WORK/proxyd.json" <<'JSON'
{
  "listenHost": "", "listenPort": 8090, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/", "intervalMs": 2000, "timeoutMs": 1000, "rise": 1, "fall": 3 },
  "backends": [ { "host": "127.0.0.1", "port": 8080, "weight": 1 },
                { "host": "127.0.0.1", "port": 8081, "weight": 1 } ]
}
JSON
"$PROXYD" "$WORK/proxyd.json" --check || { note "proxyd config invalid"; exit 1; }
"$PROXYD" "$WORK/proxyd.json" >"$WORK/proxyd.log" 2>&1 & PIDS+=($!)
if wait_port 127.0.0.1 8090 "proxyd"; then
  note "GET through proxyd on :8090 three times (round-robins across the two replicas)"
  for _ in 1 2 3; do curl -s http://127.0.0.1:8090/api/products/1 ; echo; done
else
  note "NOTE: proxyd did not bind (is the port free?)."
fi

# ---------------------------------------------------------------------------------------------------
say "5/5  operate the config store with orchctl (offline ops CLI)"
# orchctl works on a backup dump of the config store (key<TAB>value). Seed one that mimics what orchd
# would persist to NovaDB (members + a workload), then inspect it and print the rolling-upgrade order.
printf 'members/node-1\t127.0.0.1:7001\n' >  "$WORK/store.dump"
printf 'members/node-2\t127.0.0.1:7002\n' >> "$WORK/store.dump"
printf 'members/node-3\t127.0.0.1:7003\n' >> "$WORK/store.dump"
printf 'workloads/web\treplicas=2\n'       >> "$WORK/store.dump"
"$ORCHCTL" inspect "$WORK/store.dump"
"$ORCHCTL" members "$WORK/store.dump"
"$ORCHCTL" upgrade-plan "$WORK/store.dump"

say "done  (in production, orchd would supervise the replicas, persist membership/workloads to NovaDB via"
note "storeConnectionString's novadb:// URL, and write the discovery file proxyd reads instead of static"
note "backends. See lang/docs/guide/21-deploying-with-the-orchestrator.md.)"
