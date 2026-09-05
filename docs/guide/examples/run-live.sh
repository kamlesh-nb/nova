#!/usr/bin/env bash
# End-to-end live demonstration: the guide web app, backed by a real PostgreSQL, then put behind the
# orchestrator (service load-balancing two replicas, orchctl operating the config store).
#
# This is NOT part of the offline gate (run_all.sh) because it needs a running PostgreSQL server. It
# builds what it needs from the monorepo and cleans up after itself. Run it from anywhere:
#
#   lang/docs/guide/examples/run-live.sh
#
# Requirements: a built toolchain (`kyte` on PATH or ~/.kyte/bin), a reachable PostgreSQL, `psql`, and
# curl. Point it at your server with KYTE_DB_DSN (default: postgresql://postgres@127.0.0.1:5432/shop);
# create the database first, e.g. `createdb shop`.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"          # examples -> guide -> docs -> lang -> repo root
KYTE="${KYTE:-$HOME/.kyte/bin/kyte}"
WEBAPP="$HERE/webapp"
ORCH="$REPO/packages/nova-orchestrator"
DSN="${KYTE_DB_DSN:-postgresql://postgres@127.0.0.1:5432/shop}"
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
say "1/5  seed the schema into PostgreSQL"
# Seed the schema + a few rows ONCE, up front, with psql. Doing it here (rather than letting each app
# replica seed on first connect) keeps the demo deterministic: two replicas connecting to a fresh
# database at the same moment would otherwise race to create + seed it.
if ! command -v psql >/dev/null 2>&1; then note "psql not found; install the PostgreSQL client"; exit 1; fi
psql "$DSN" -v ON_ERROR_STOP=1 -f "$WEBAPP/schema.sql" >"$WORK/seed.log" 2>&1 \
  || { note "schema seed failed (is PostgreSQL running and the database created?)"; cat "$WORK/seed.log"; exit 1; }
note "seeded products 1..3 into $DSN"

# ---------------------------------------------------------------------------------------------------
say "2/5  build the PostgreSQL-backed web app (main_postgres.ky)"
# main_postgres.ky lives at the project root so it never clashes with the in-memory src/main.ky.
# Build it in a throwaway copy: swap it in as src/main.ky, wire the nova-postgres dependency, and point
# packages/ at the monorepo so `import postgres` resolves with no network.
BUILDDIR="$WORK/webapp-src"
cp -r "$WEBAPP" "$BUILDDIR"; ( cd "$BUILDDIR" && rm -rf build packages )
mv "$BUILDDIR/main_postgres.ky" "$BUILDDIR/src/main.ky"
python3 - "$BUILDDIR/project.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["dependencies"]=["https://github.com/kamlesh-nb/nova-postgres"]
json.dump(d,open(p,"w"),indent=2)
PY
ln -sfn "$REPO/packages" "$BUILDDIR/packages"           # so `import postgres` resolves
( cd "$BUILDDIR" && "$KYTE" build -o "$WORK/webapp" ) \
  || { note "web app build failed"; exit 1; }
WEBAPP="$BUILDDIR"                                       # replicas below run from here (static assets)
note "built $WORK/webapp"

say "     start two replicas (KYTE_PORT) on 8080 and 8081"
( cd "$WEBAPP" && KYTE_DB_DSN="$DSN" KYTE_PORT=8080 "$WORK/webapp" ) >"$WORK/app8080.log" 2>&1 & PIDS+=($!)
( cd "$WEBAPP" && KYTE_DB_DSN="$DSN" KYTE_PORT=8081 "$WORK/webapp" ) >"$WORK/app8081.log" 2>&1 & PIDS+=($!)
wait_port 127.0.0.1 8080 "app replica A" || exit 1
wait_port 127.0.0.1 8081 "app replica B" || exit 1

# ---------------------------------------------------------------------------------------------------
say "3/5  exercise the app directly (write -> PostgreSQL -> read back)"
note "POST /api/products  (create)"
curl -s -X POST http://127.0.0.1:8080/api/products \
  -H 'Content-Type: application/json' -d '{"name":"Webcam","price":5500}' ; echo
note "GET /api/products/1  (read; served from PostgreSQL)"
curl -s http://127.0.0.1:8080/api/products/1 ; echo

# ---------------------------------------------------------------------------------------------------
say "4/5  put the app behind service (data plane, load-balancing the two replicas)"
( cd "$ORCH" && ./build.sh ) >"$WORK/orch-build.log" 2>&1 || { note "orchestrator build failed"; exit 1; }
SVC="$ORCH/build/debug/bin/service"
ORCHCTL="$ORCH/build/debug/bin/orchctl"

cat > "$WORK/service.json" <<'JSON'
{
  "listenHost": "", "listenPort": 8090, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/", "intervalMs": 2000, "timeoutMs": 1000, "rise": 1, "fall": 3 },
  "backends": [ { "host": "127.0.0.1", "port": 8080, "weight": 1 },
                { "host": "127.0.0.1", "port": 8081, "weight": 1 } ]
}
JSON
"$SVC" "$WORK/service.json" --check || { note "service config invalid"; exit 1; }
"$SVC" "$WORK/service.json" >"$WORK/service.log" 2>&1 & PIDS+=($!)
if wait_port 127.0.0.1 8090 "service"; then
  note "GET through service on :8090 three times (round-robins across the two replicas)"
  for _ in 1 2 3; do curl -s http://127.0.0.1:8090/api/products/1 ; echo; done
else
  note "NOTE: service did not bind (is the port free?)."
fi

# ---------------------------------------------------------------------------------------------------
say "5/5  operate the config store with orchctl (offline ops CLI)"
# orchctl works on a backup dump of the config store (key<TAB>value). Seed one that mimics what orchd
# would persist to the artifactd-hosted config store (members + a workload), then inspect it and print
# the rolling-upgrade order.
printf 'members/node-1\t127.0.0.1:7001\n' >  "$WORK/store.dump"
printf 'members/node-2\t127.0.0.1:7002\n' >> "$WORK/store.dump"
printf 'members/node-3\t127.0.0.1:7003\n' >> "$WORK/store.dump"
printf 'workloads/web\treplicas=2\n'       >> "$WORK/store.dump"
"$ORCHCTL" inspect "$WORK/store.dump"
"$ORCHCTL" members "$WORK/store.dump"
"$ORCHCTL" upgrade-plan "$WORK/store.dump"

say "done  (in production, orchd would supervise the replicas, persist membership/workloads to the"
note "artifactd-hosted config store over its /cfg/* HTTP routes (config.snap snapshot), and write the"
note "discovery file service reads instead of static backends. See"
note "lang/docs/guide/23-deploying-with-the-orchestrator.md.)"
