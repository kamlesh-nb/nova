#!/usr/bin/env bash
# conc_scaling.sh — concurrency-scaling benchmark for a Kyte DB driver (D5b).
#
# Launches C independent CLIENT PROCESSES (each its own connection), all running a
# fixed-duration workload at once, and sums their op counts -> aggregate ops/sec.
# Sweeping C reveals whether the ENGINE scales with concurrent clients or hits a
# ceiling (e.g. a global rw_lock). This is how pgbench/sysbench/memtier measure
# server concurrency: real OS-level parallelism, no in-process async.
#
# Usage:
#   conc_scaling.sh <client_binary> [readpct] [duration_ms] [records] "[levels]"
#     readpct     100 = pure read, 50 = mixed 50/50 read/update  (default 100)
#     duration_ms fixed run window per client                    (default 5000)
#     records     keyspace size                                  (default 10000)
#     levels      concurrency points to sweep         (default "1 2 4 8 16 32 64")
#
# Env passthrough: set YCSB_DSN to override the client's default DSN.
set -u
CLIENT="${1:?usage: conc_scaling.sh <client_binary> [readpct] [duration_ms] [records] \"[levels]\"}"
READPCT="${2:-100}"
DUR_MS="${3:-5000}"
RECORDS="${4:-10000}"
LEVELS="${5:-1 2 4 8 16 32 64}"
DUR_S=$(awk "BEGIN{print $DUR_MS/1000}")

mix="read-only"; [ "$READPCT" -lt 100 ] && mix="mixed ${READPCT}r/$((100-READPCT))w"

echo "=================================================================="
echo " Concurrency scaling  |  client=$(basename "$CLIENT")  workload=$mix"
echo " records=$RECORDS  duration=${DUR_MS}ms  dsn=${YCSB_DSN:-<client default>}"
echo "=================================================================="

# --- load the table once ---
echo -n "loading $RECORDS rows... "
YCSB_MODE=load YCSB_RECORDS="$RECORDS" "$CLIENT" >/dev/null 2>&1 || { echo "LOAD FAILED"; exit 1; }
echo "done"

printf "\n%5s | %16s | %16s | %8s\n" "conc" "aggregate ops/s" "per-client ops/s" "scaling"
printf -- "------+------------------+------------------+---------\n"

base=0
for C in $LEVELS; do
  tmp=$(mktemp -d)
  for i in $(seq 1 "$C"); do
    YCSB_MODE=run YCSB_RECORDS="$RECORDS" YCSB_DURATION_MS="$DUR_MS" \
      YCSB_READPCT="$READPCT" YCSB_SEED=$((i * 7919 + 13)) \
      "$CLIENT" > "$tmp/c$i.out" 2>&1 &
  done
  wait
  total=0
  for f in "$tmp"/c*.out; do
    ops=$(grep -oE 'ops=[0-9]+' "$f" 2>/dev/null | head -1 | cut -d= -f2)
    total=$((total + ${ops:-0}))
  done
  rm -rf "$tmp"
  agg=$(awk "BEGIN{printf \"%d\", $total/$DUR_S}")
  per=$(awk "BEGIN{printf \"%d\", $agg/$C}")
  [ "$C" = "1" ] && base=$agg
  scale=$(awk "BEGIN{printf \"%.2f\", $agg/$base}")
  printf "%5d | %16d | %16d | %7sx\n" "$C" "$agg" "$per" "$scale"
done
echo ""
echo "Ideal linear scaling => aggregate grows with conc, per-client stays flat."
echo "A ceiling => aggregate plateaus, per-client falls ~1/conc past the knee."
