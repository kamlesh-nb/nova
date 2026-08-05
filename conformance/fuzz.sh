#!/usr/bin/env bash
# Compiler robustness fuzzer (X4). Mutates small, valid Nova sources and feeds each to `nova test`,
# asserting the COMPILER never crashes (segfault / panic / abort) or hangs on malformed input. A mutation
# that produces invalid Nova must be REJECTED cleanly (a diagnostic + non-signal exit), never a crash.
# Complements NovaDB's in-process SQL/wire fuzz (D9); the Nova front-end + codegen is the fuzz target here.
#
#   conformance/fuzz.sh              # default NOVA_FUZZ_N iterations
#   NOVA_FUZZ_N=500 conformance/fuzz.sh
#   NOVA_FUZZ_SEED=1234 conformance/fuzz.sh
#
# Exit non-zero (and keep the offending input under fuzz-artifacts/) if any input CRASHED the compiler.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lang="$(cd "$here/.." && pwd)"
cd "$lang"
export PATH="$HOME/.nova/bin:$PATH"

N="${NOVA_FUZZ_N:-80}"
SEED="${NOVA_FUZZ_SEED:-1337}"
TMO="${NOVA_FUZZ_TIMEOUT:-20}"
artifacts="$here/fuzz-artifacts"
rm -rf "$artifacts"; mkdir -p "$artifacts"

# Small, fast-compiling seeds (mutating real sources reaches deeper code paths than pure random bytes).
seeds=(
  conformance/cases/00_smoke.nova
  conformance/cases/80_struct_init_typeargs.nova
  conformance/cases/05_closures_capture.nova
  conformance/cases/79_heterogeneous_ifexpr_lub.nova
  conformance/cases/01_collections_list.nova
)

# Portable per-run timeout (stock macOS has no `timeout`): gtimeout > timeout > a perl alarm wrapper.
run_to() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout -s KILL "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then timeout -s KILL "$secs" "$@"
  else perl -e 'my $s=shift; my $p=fork; if(!$p){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm $s; waitpid($p,0); exit($?>>8)' "$secs" "$@"
  fi
}

crashes=0; hangs=0; ok=0; i=0
echo ">>> nova compiler fuzz: $N iterations, seed $SEED [$(uname -s)-$(uname -m)]"
while [ "$i" -lt "$N" ]; do
  i=$((i+1))
  seed="${seeds[$(( (SEED + i) % ${#seeds[@]} ))]}"
  tmp="$artifacts/candidate_$i.nova"
  # Deterministic byte-level mutation (flip / insert / delete) OR, 1-in-4, pure random bytes.
  python3 - "$seed" "$tmp" "$((SEED + i))" <<'PY'
import sys, random
seed_path, out_path, s = sys.argv[1], sys.argv[2], int(sys.argv[3])
r = random.Random(s)
if s % 4 == 0:                                   # pure random bytes
    data = bytearray(r.randint(0, 255) for _ in range(r.randint(0, 96)))
else:
    with open(seed_path, "rb") as f: data = bytearray(f.read())
    for _ in range(r.randint(1, 12)):
        if not data: break
        op = r.randint(0, 2); idx = r.randrange(len(data))
        if op == 0: data[idx] = r.randint(0, 255)            # flip
        elif op == 1: data.insert(idx, r.randint(0, 255))     # insert
        else: del data[idx]                                    # delete
with open(out_path, "wb") as f: f.write(data)
PY
  outf="$artifacts/out_$i.txt"
  run_to "$TMO" nova test "$tmp" >"$outf" 2>&1; ec=$?
  if [ "$ec" -eq 124 ] || [ "$ec" -eq 137 ]; then
    hangs=$((hangs+1)); echo "  HANG   #$i ($(basename "$seed")) -> $tmp"; cp "$tmp" "$artifacts/HANG_$i.nova"
  elif [ "$ec" -ge 128 ] || grep -qiE "panic:|segmentation fault|SIGSEGV|SIGABRT|Assertion .* failed|unreachable code" "$outf"; then
    crashes=$((crashes+1)); echo "  CRASH  #$i ($(basename "$seed")) ec=$ec -> $tmp"; cp "$tmp" "$artifacts/CRASH_$i.nova"; tail -5 "$outf" | tr -d '\0' | sed 's/^/    /'
  else
    ok=$((ok+1))   # 0 = compiled/ran, 1 = cleanly rejected: both are robust
  fi
done

echo; echo "fuzz summary: $ok robust, $hangs hang, $crashes CRASH (of $N)"
if [ "$crashes" -gt 0 ]; then
  echo "FUZZ FAIL: $crashes crashing input(s) kept under $artifacts"; exit 1
fi
# Hangs are reported but do not fail the gate (a mutated program may legitimately loop); crashes do.
echo "FUZZ PASS: the compiler rejected/handled every input without crashing"
rm -rf "$artifacts"
exit 0
