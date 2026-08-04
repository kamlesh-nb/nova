#!/usr/bin/env bash
# Nova conformance corpus runner (roadmap workstream E2).
#
# Runs `nova test` on every cases/*.nova file and reports pass/fail. This is the
# safety net: run it before and after any compiler/runtime/stdlib change to catch
# regressions. Exit code is non-zero if any case fails to compile or any test fails.
#
# Usage:  ./run.sh            # run all cases
#         ./run.sh 02         # run cases whose name contains "02"
set -u

NOVA="${NOVA:-$HOME/.nova/bin/nova}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# --arc : run every positive case under NOVA_ARC_AUDIT=1 and gate LEAK REGRESSIONS
# against conformance/arc-baseline.txt. Not on by default because the corpus is not
# at zero yet (the tuple leak alone is ~108 objects); a gate that is always red gates
# nothing. But leaks were previously not measured AT ALL by this harness, so any
# regression was invisible. Baseline-gating catches regressions today and ratchets
# down as leaks are fixed.
# Per-case wall-clock cap. A case that BLOCKS (a reactor waiting on an event its backend never
# delivers, say) used to stall the whole corpus with no output and no diagnosis — indistinguishable
# from a slow machine, and fatal to an unattended run. Bounded here instead, so a hang is reported as
# an ordinary failure and the run continues. macOS has no coreutils `timeout`, so this is the same
# background-killer shape the wasm path already uses. Override with NOVA_CASE_TIMEOUT.
CASE_TIMEOUT="${NOVA_CASE_TIMEOUT:-120}"
HAVE_TIMEOUT="$(command -v timeout || true)"   # coreutils on Linux/Git-Bash; absent on stock macOS

run_case() {
  local rc out
  if [[ -n "$HAVE_TIMEOUT" ]]; then
    out="$("$HAVE_TIMEOUT" -k 5 "$CASE_TIMEOUT" "$NOVA" test "$1" 2>&1)"; rc=$?
  else
    # No coreutils timeout (stock macOS): kill from a background sleeper. The sleeper is NOT
    # waited on — killing the subshell does not necessarily reap its `sleep` child, and waiting
    # for it would then cost the full timeout on EVERY case, turning the guard into the stall it
    # exists to prevent.
    local tmp cpid kpid
    tmp="$(mktemp -t novacase.XXXXXX)"
    ( "$NOVA" test "$1" >"$tmp" 2>&1 ) & cpid=$!
    ( sleep "$CASE_TIMEOUT"; kill -9 "$cpid" 2>/dev/null ) & kpid=$!
    wait "$cpid" 2>/dev/null; rc=$?
    kill "$kpid" 2>/dev/null
    out="$(cat "$tmp" 2>/dev/null)"
    rm -f "$tmp" 2>/dev/null
  fi
  printf '%s\n' "$out"
  # 124 is timeout(1)'s verdict; a background kill surfaces as 128+SIGKILL. Either way, say so —
  # otherwise a hang reads as an ordinary non-zero exit and gets misdiagnosed.
  { [[ $rc -eq 124 ]] || [[ $rc -ge 128 ]]; } && echo "(timed out after ${CASE_TIMEOUT}s)"
  return $rc
}

ARC_MODE=0
ASAN_MODE=0
TSAN_MODE=0
SHADOW_MODE=0
WASM_MODE=0
# --wasm : compile every positive case to a wasm module (`nova <file> --wasm`) and
# gate that it emits a VALID wasm binary (magic \0asm), i.e. codegen + wasm-ld link
# succeed across the corpus. Not all cases compile to wasm yet (the ~44 is_wasm
# branches are still filling in: heap/string round-trips, some methods), so this is
# baseline-gated against conformance/wasm-baseline.txt exactly like --arc: a case
# listed there that STOPS compiling is a regression (FAIL); a non-listed case that
# now compiles is a bonus (asks you to add it). Keeps wasm coverage ratcheting up
# and never silently sliding back.
if [[ "${1:-}" == "--wasm" ]]; then WASM_MODE=1; shift; fi
WASMRUN_MODE=0
# --wasm-run : compile every positive case to wasm AND RUN it under Node
# (conformance/wasm-run.mjs), gating that its @test functions execute without a
# failed assertion or trap. Behavioral coverage for the wasm target, one level up
# from --wasm (which only checks compile+link). Baseline-gated against
# conformance/wasm-run-baseline.txt like --arc: a listed case that stops passing is
# a regression; a new pass asks to be added. Requires `node`.
if [[ "${1:-}" == "--wasm-run" ]]; then WASMRUN_MODE=1; shift; fi
# --shadow : run every case under NOVA_SEMA_SHADOW=1 and gate the F5-2 migration invariant. The
# compiler's reportTypeIdDiff exits 1 if the string ownership engine and the TypeId engine DISAGREE
# on any concrete type or keystone substitution. Corpus-wide this is 0 today (that agreement is the
# license to delete isRefCountedType); this gate keeps it 0 so "ownership decided by name-matching"
# can never silently creep back — a divergence fails the build AT the divergence, with the type named.
if [[ "${1:-}" == "--shadow" ]]; then SHADOW_MODE=1; shift; fi
if [[ "${1:-}" == "--arc" ]]; then ARC_MODE=1; shift; fi
# --asan : run every positive case under AddressSanitizer. Catches USE-AFTER-FREE and
# DOUBLE-FREE, which is the failure mode ARC's string-typed ownership actually produces:
# `isRefCountedType`'s catch-all returns true for a name it does not recognise, so "the
# compiler is confused" means "free this memory". Without ASAN such a bug reports as a
# garbage VALUE at a random later point — `Expected "Host", got "\xef..."` — because
# nova_release on a freed block reads the header quietly and the damage only lands once
# malloc reuses it. With ASAN you get the use, the free, and the allocation, each with a
# function name. That is how "string heap corruption" stayed misfiled for months.
#
# Requires the sanitized runtime: `NOVA_ASAN=1 zig build` first.
# NOT a leak gate — LeakSanitizer is unsupported on Darwin; use --arc for leaks.
if [[ "${1:-}" == "--asan" ]]; then ASAN_MODE=1; shift; fi
# --tsan : run the concurrency subset under ThreadSanitizer with NOVA_THREADS=4. TSan finds
# DATA RACES in the multi-reactor runtime that the (single-threaded) corpus and ASAN gate
# cannot. This is the gate for the self-hosted runtime work — any race becomes a located
# report naming both accesses. Requires: NOVA_TSAN=1 zig build first.
if [[ "${1:-}" == "--tsan" ]]; then TSAN_MODE=1; shift; fi
# -j [N] / --parallel [N] : run the plain positive corpus N-way parallel (default: cores-1). Each case
# runs in its own temp dir so the hardcoded __nova_test output cannot collide, with packages/ symlinked
# in so driver-importing cases still resolve; server cases use ephemeral ports so they parallelise
# cleanly. Applies ONLY to the default `nova test` run — the sanitizer/wasm/arc modes stay sequential
# (baseline-gated, order-sensitive). The default (no -j) path is unchanged.
PARALLEL=0
if [[ "${1:-}" == "-j" || "${1:-}" == "--parallel" ]]; then
  shift
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then PARALLEL="$1"; shift
  else
    _nc="$( (command -v sysctl >/dev/null && sysctl -n hw.ncpu) 2>/dev/null || nproc 2>/dev/null || echo 4 )"
    PARALLEL=$(( _nc > 2 ? _nc - 1 : 2 ))
  fi
fi
FILTER="${1:-}"

if [[ ! -x "$NOVA" ]]; then
  echo "ERROR: nova compiler not found at $NOVA (build with 'zig build' in lang/)" >&2
  exit 2
fi

pass=0; fail=0; failed_cases=()
if [[ $PARALLEL -gt 0 && $WASM_MODE -eq 0 && $WASMRUN_MODE -eq 0 && $ASAN_MODE -eq 0 && $ARC_MODE -eq 0 && $TSAN_MODE -eq 0 ]]; then
  # ---- parallel default corpus (opt-in -j) : per-case temp dir + packages symlink ----
  # Self-contained worker (plain exported env vars propagate into the xargs child; an exported
  # function does not, reliably). Timeout via coreutils timeout/gtimeout, else a perl alarm.
  ROOT="$(cd "$HERE/.." && pwd)"
  export NOVA ROOT CASE_TIMEOUT
  echo "--- parallel: ${PARALLEL} workers (per-case temp dir; packages symlinked) ---"
  _verd="$(mktemp)"; _worker="$(mktemp)"
  # Worker is a tiny script (macOS xargs -I{} chokes on a long inline command; an exported function does
  # not reliably reach the xargs child). Reads $NOVA/$ROOT/$CASE_TIMEOUT from the exported env. Each case
  # runs in its own temp dir so the hardcoded __nova_test output cannot collide, with packages/ symlinked
  # so most driver-importing cases resolve; the per-case $CASE_TIMEOUT (perl alarm on stock macOS) caps a
  # case that waits on a live service. NOTE: a case that links a package's NATIVE lib (the mysql/mssql/pg
  # DB drivers) links it relative to the repo root, so it FAILS FAST here (link error) rather than in a
  # long serial hang — verify those few with the plain sequential run.
  cat > "$_worker" <<'WORKER'
f="$1"; name="$(basename "$f")"; wd="$(mktemp -d)"
ln -s "$ROOT/packages" "$wd/packages" 2>/dev/null
cd "$wd" || exit 0
if command -v timeout >/dev/null 2>&1; then out="$(timeout -k 5 "$CASE_TIMEOUT" "$NOVA" test "$f" 2>&1)"; code=$?
elif command -v gtimeout >/dev/null 2>&1; then out="$(gtimeout -k 5 "$CASE_TIMEOUT" "$NOVA" test "$f" 2>&1)"; code=$?
else out="$(perl -e "alarm $CASE_TIMEOUT; exec @ARGV" "$NOVA" test "$f" 2>&1)"; code=$?; fi
cd / ; rm -rf "$wd"
res="$(printf '%s\n' "$out" | grep -E '^Results:' | tail -1)"
if [ "$code" -eq 0 ] && printf '%s' "$res" | grep -q '0 failed'; then printf 'PASS\t%s\t%s\n' "$name" "$res"
else printf 'FAIL\t%s\t%s\n' "$name" "${res:-<compile/link or timeout>}"; fi
WORKER
  # Longest-first scheduling: cases that import the heavy stdlib graph (web/net/reactor/tls/crypto/
  # data) compile the whole 15k-line merged program and dominate wall time, so feed them to the
  # workers FIRST. xargs -P assigns items in order as workers free up, so starting the long poles
  # early lets the many short cases backfill the tail instead of a 9s case landing last on an idle
  # box. Weight 0 = heavy (first), 1 = light; sorted by (weight, path) for deterministic order.
  for f in "$HERE"/cases/*.nova; do
    n="$(basename "$f")"; [[ -n "$FILTER" && "$n" != *"$FILTER"* ]] && continue
    if grep -qE '^[[:space:]]*import[[:space:]]+(web|net|reactor|flagship|asynctls|tls|crypto|data)\b' "$f" 2>/dev/null; then
      printf '0\t%s\n' "$f"
    else
      printf '1\t%s\n' "$f"
    fi
  done | sort | cut -f2- | xargs -P "$PARALLEL" -n1 bash "$_worker" >> "$_verd"
  rm -f "$_worker"
  # tally (sorted for stable output)
  while IFS="$(printf '\t')" read -r v name res; do
    if [[ "$v" == "PASS" ]]; then printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$res"; pass=$((pass+1))
    else printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "$res"; fail=$((fail+1)); failed_cases+=("$name"); fi
  done < <(sort "$_verd")
  rm -f "$_verd"
else
for f in "$HERE"/cases/*.nova; do
  name="$(basename "$f")"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  if [[ $WASM_MODE -eq 1 ]]; then
    base="$HERE/cases/$name"
    wout="$(mktemp -t novawasm.XXXXXX)"; wout="$wout.wasm"
    out="$("$NOVA" "$base" --wasm -o "$wout" 2>&1)"; code=$?
    magic="$(head -c4 "$wout" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    rm -f "$wout" "$wout.o" 2>/dev/null
    in_base=0; grep -qxF "$name" "$HERE/wasm-baseline.txt" 2>/dev/null && in_base=1
    if [[ $code -eq 0 && "$magic" == "0061736d" ]]; then
      if [[ $in_base -eq 1 ]]; then
        printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "(wasm ok)"; pass=$((pass+1))
      else
        printf "  \033[32mNEW \033[0m  %-32s %s\n" "$name" "(wasm ok — add to wasm-baseline.txt)"; pass=$((pass+1))
      fi
    else
      if [[ $in_base -eq 1 ]]; then
        printf "  \033[31mFAIL\033[0m  %-32s \033[31m(wasm REGRESSION — was in baseline)\033[0m\n" "$name"
        printf '%s\n' "$out" | grep -vE '^DEBUG' | tail -4 | sed 's/^/          /'
        fail=$((fail+1)); failed_cases+=("$name:wasm-regress")
      else
        printf "  \033[33mskip\033[0m  %-32s %s\n" "$name" "(wasm not yet supported)"
      fi
    fi
    continue
  fi
  if [[ $WASMRUN_MODE -eq 1 ]]; then
    base="$HERE/cases/$name"
    wout="$(mktemp -t novawasm.XXXXXX)"; wout="$wout.wasm"
    "$NOVA" "$base" --wasm -o "$wout" >/dev/null 2>&1
    # A wasm @test can infinite-loop (synchronous — an in-JS timeout can't fire),
    # so wall-clock-limit node with a background killer (macOS has no `timeout`).
    ( node "$HERE/wasm-run.mjs" "$wout" >/tmp/nova_wr.$$ 2>&1 ) & npid=$!
    ( sleep 20; kill -9 "$npid" 2>/dev/null ) & kpid=$!
    wait "$npid" 2>/dev/null; code=$?
    kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
    out="$(cat /tmp/nova_wr.$$ 2>/dev/null); [[ $code -ge 128 ]] && echo '(timed out)'"
    rm -f "$wout" "$wout.o" /tmp/nova_wr.$$ 2>/dev/null
    in_base=0; grep -qxF "$name" "$HERE/wasm-run-baseline.txt" 2>/dev/null && in_base=1
    if [[ $code -eq 0 ]]; then
      if [[ $in_base -eq 1 ]]; then printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "(wasm runs)"; pass=$((pass+1));
      else printf "  \033[32mNEW \033[0m  %-32s %s\n" "$name" "(wasm runs — add to wasm-run-baseline.txt)"; pass=$((pass+1)); fi
    else
      if [[ $in_base -eq 1 ]]; then
        printf "  \033[31mFAIL\033[0m  %-32s \033[31m(wasm-run REGRESSION)\033[0m %s\n" "$name" "$out"
        fail=$((fail+1)); failed_cases+=("$name:wasm-run-regress")
      else
        printf "  \033[33mskip\033[0m  %-32s %s\n" "$name" "(wasm exec not yet passing)"
      fi
    fi
    continue
  fi
  # nova test emits DEBUG lines on stderr; capture everything, judge by exit code
  # and the "Results:" summary line.
  out="$(run_case "$f")"
  code=$?
  results="$(printf '%s\n' "$out" | grep -E '^Results:' | tail -1)"
  if [[ $code -eq 0 && "$results" == *"0 failed"* ]]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$results"
    pass=$((pass+1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "${results:-<compile/link error>}"
    printf '%s\n' "$out" | grep -vE '^DEBUG' | tail -6 | sed 's/^/          /'
    fail=$((fail+1)); failed_cases+=("$name")
  fi
done
fi

# Negative cases: each expect_fail/*.nova MUST be REJECTED, and must be rejected
# for the RIGHT REASON.
#
# ⚠️ Why this is not "exit code != 0": a SEGFAULT also exits non-zero. Judging by
# exit code alone made a case that COMPILES AND CRASHES indistinguishable from one
# the compiler rejected — and that is not hypothetical: `return_type_mismatch`
# regressed to compile-and-segfault while this harness reported it PASS, and
# expect_fail/PENDING.md still documents that check as DONE. A harness that cannot
# tell "rejected" from "crashed" gates nothing. (2026-07-17)
#
# Each case declares its expected rejection kind on a `// EXPECT-FAIL: <kind>` line:
#   typecheck      — sema/the checker emitted a diagnostic with file:line:col. The goal.
#   parse          — the parser rejected it, with a location.
#   codegen        — rejected, cleanly, but only at CODEGEN and WITHOUT a source span:
#                    the user gets a name, not a `file:line`. Honest debt: the fix is
#                    F1 stage 7 / F2 stage 5, which move these into sema where spans
#                    exist. Tracked in beta-readiness-plan.md P0-5.
#   compiler-crash — an unhandled Zig error escapes `main` and the runtime prints a
#                    COMPILER stack trace. Should now be ZERO; any case reporting this
#                    is a regression in main.zig's userErrorHint mapping.
# A case with no directive defaults to `typecheck`.
#
# Order matters: "COMPILED-THEN-CRASHED" must be tested before the reject kinds, since
# a case that compiles and segfaults must never be mistaken for one that was rejected.
classify_failure() {
  local out="$1" code="$2"
  if printf '%s' "$out" | grep -q "terminated abnormally"; then
    echo "COMPILED-THEN-CRASHED"     # the check is NOT firing; this is the bug
  elif printf '%s' "$out" | grep -q "Running [0-9]* test(s)" \
       && ! printf '%s' "$out" | grep -q "Results: .* passed"; then
    # Same verdict, reached without signals — required on Windows, harmless elsewhere.
    # Windows has no SIGSEGV: a crashing test process still reports `.exited`, carrying the
    # NTSTATUS exception code (0xC0000005 = access violation), and that code is truncated to
    # 8 bits before `nova test` sees it — so a segfault prints "Test suite FAILED (exit code
    # 5)", which no exit code alone can tell apart from an ordinary failure. The branch above
    # therefore never fires there, and a compile-and-crash would masquerade as a valid
    # rejection — exactly the failure this self-test exists to catch.
    #
    # What IS unambiguous on every platform: the suite announced "Running N test(s)" and then
    # never printed its "Results:" summary, i.e. the process died mid-run. Keyed on that
    # instead of on the exit status.
    echo "COMPILED-THEN-CRASHED"
  elif [[ $code -eq 0 ]]; then
    echo "COMPILED-AND-RAN"          # the check is NOT firing
  elif printf '%s' "$out" | grep -q "in main (nova)"; then
    echo "compiler-crash"            # a Zig backtrace reached the user
  elif printf '%s' "$out" | grep -q "Type checking failed\|undefined identifier\|is not public\|in module '"; then
    echo "typecheck"           # includes F1-4 cross-module visibility + F1-7 module-fn rejections
  elif printf '%s' "$out" | grep -q "Parser error\|Expect failed:"; then
    echo "parse"
  elif printf '%s' "$out" | grep -q "(compilation failed)"; then
    echo "codegen"
  else
    echo "UNKNOWN"
  fi
}

# ── HARNESS SELF-TEST (H1) ────────────────────────────────────────────────────
# The negative-case guard's WHOLE JOB is to tell "rejected" from "crashed/ran".
# That guard is only trustworthy if it is itself PROVEN — otherwise "our negative
# gates are green" is unfalsifiable (a silently-broken classifier reports every
# crash as a pass, exactly the 2026-07-17 regression). So before judging any real
# negative, feed the classifier two fixtures whose outcome is KNOWN and must NEVER
# be read as a valid rejection:
#   compiles-then-crashes → must classify COMPILED-THEN-CRASHED (a segfault)
#   compiles-and-runs     → must classify COMPILED-AND-RAN      (should've failed)
# If either is mislabeled as a reject kind, the guard is broken → ABORT the run.
if [[ -d "$HERE/harness-selftest" && $WASM_MODE -ne 1 && $WASMRUN_MODE -ne 1 ]]; then
  echo "--- harness self-test (proves the negative-case guard works) ---"
  selftest_ok=1
  check_selftest() {
    local file="$1" want="$2"
    local o c a
    o="$("$NOVA" test "$HERE/harness-selftest/$file" 2>&1)"; c=$?
    a="$(classify_failure "$o" "$c")"
    if [[ "$a" == "$want" ]]; then
      printf "  \033[32mPASS\033[0m  %-32s %s\n" "$file" "(classified: $a)"
    else
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$file" "(expected classify: $want, got: $a)"
      selftest_ok=0
    fi
  }
  check_selftest "compiles-then-crashes.nova" "COMPILED-THEN-CRASHED"
  check_selftest "compiles-and-runs.nova"     "COMPILED-AND-RAN"
  if [[ $selftest_ok -ne 1 ]]; then
    echo "  ✗ HARNESS INTEGRITY BROKEN: the negative-case classifier no longer detects a" >&2
    echo "    crash/compile-and-run. Every negative result is now UNTRUSTWORTHY. Fix" >&2
    echo "    classify_failure (or the compiler's crash/error output) before trusting this run." >&2
    exit 2
  fi
fi

if [[ -d "$HERE/expect_fail" && $WASM_MODE -ne 1 && $WASMRUN_MODE -ne 1 ]]; then
  echo "--- negative cases (must be rejected, FOR THE DECLARED REASON) ---"
  for f in "$HERE"/expect_fail/*.nova; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
    expected="$(grep -m1 -oE '^// EXPECT-FAIL:[[:space:]]*[a-z-]+' "$f" | sed -E 's|^// EXPECT-FAIL:[[:space:]]*||')"
    expected="${expected:-typecheck}"
    out="$("$NOVA" test "$f" 2>&1)"; code=$?
    actual="$(classify_failure "$out" "$code")"
    if [[ "$actual" == "$expected" ]]; then
      printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "(rejected: $actual)"
      pass=$((pass+1))
    else
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(expected: $expected, got: $actual)"
      printf '%s\n' "$out" | grep -vE '^DEBUG' | tail -4 | sed 's/^/          /'
      fail=$((fail+1)); failed_cases+=("$name")
    fi
  done
fi

# AddressSanitizer gate (opt-in: NOVA_ASAN=1 zig build && ./run.sh --asan)
if [[ $ASAN_MODE -eq 1 ]]; then
  echo "--- AddressSanitizer gate (use-after-free / double-free) ---"
  if [[ ! -f "$HOME/.nova/lib/libnovacore_asan.a" ]]; then
    echo "  ERROR: libnovacore_asan.a missing — run: NOVA_ASAN=1 zig build" >&2
    exit 2
  fi
  for f in "$HERE"/cases/*.nova; do
    name="$(basename "$f" .nova)"
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
    out="$(NOVA_ASAN=1 "$NOVA" test "$f" 2>&1)"
    if printf '%s' "$out" | grep -q "ERROR: AddressSanitizer"; then
      kind="$(printf '%s' "$out" | grep -m1 -oE 'AddressSanitizer: [a-z-]+' | sed 's/AddressSanitizer: //')"
      where="$(printf '%s' "$out" | grep -m1 -oE '#0 0x[0-9a-f]+ in [A-Za-z_][A-Za-z0-9_]*' | sed 's/.* in //')"
      printf "  \033[31mFAIL\033[0m  %-32s \033[31m%s\033[0m in %s\n" "$name" "$kind" "${where:-?}"
      printf '%s\n' "$out" | grep -E "freed by thread|previously allocated|#[0-9] .* in " | head -4 | sed 's/^/          /'
      fail=$((fail+1)); failed_cases+=("$name:asan-$kind")
    elif printf '%s' "$out" | grep -qE '^Results:.*0 failed'; then
      printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "(asan clean)"
      pass=$((pass+1))
    else
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(did not run cleanly under asan)"
      fail=$((fail+1)); failed_cases+=("$name:asan-run")
    fi
  done
fi

# ThreadSanitizer gate (opt-in: NOVA_TSAN=1 zig build && ./run.sh --tsan)
# Runs the multi-threaded subset under NOVA_THREADS=4; single-threaded cases would exercise
# no concurrency and are skipped. Extend TSAN_CASES as new concurrent code lands.
if [[ $TSAN_MODE -eq 1 ]]; then
  echo "--- ThreadSanitizer gate (data races, NOVA_THREADS=4) ---"
  if [[ ! -f "$HOME/.nova/lib/libnovacore_tsan.a" ]]; then
    echo "  ERROR: libnovacore_tsan.a missing — run: NOVA_TSAN=1 zig build" >&2
    exit 2
  fi
  TSAN_CASES=(10_async_go 11_channels 102_future_first_class 103_async_when_all 195_multicore_reactors 199_reactor_nested_await 200_reactor_async_io 201_reactor_tcp_connect_accept 202_asyncstream_on_reactor 203_reactor_resolve_connect 204_app_request_on_reactor 205_flagship_db_on_reactor 206_app_multicore_workers 207_reactor_native_timer 208_reactor_read_deadline 209_inbound_tls_on_reactor 210_cross_reactor_wakeup)
  for name in "${TSAN_CASES[@]}"; do
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
    f="$HERE/cases/$name.nova"
    [[ -f "$f" ]] || { printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(case missing)"; fail=$((fail+1)); continue; }
    out="$(NOVA_TSAN=1 NOVA_THREADS=4 "$NOVA" test "$f" 2>&1)"
    if printf '%s' "$out" | grep -q "data race"; then
      where="$(printf '%s' "$out" | grep -m1 -oE '#0 .* in [A-Za-z_][A-Za-z0-9_]*' | sed 's/.* in //')"
      printf "  \033[31mFAIL\033[0m  %-32s \033[31mdata race\033[0m in %s\n" "$name" "${where:-?}"
      printf '%s\n' "$out" | grep -E "Write of size|Read of size|Previous (read|write)|#[0-9] .* in " | head -6 | sed 's/^/          /'
      fail=$((fail+1)); failed_cases+=("$name:tsan-race")
    elif printf '%s' "$out" | grep -qE '^Results:.*0 failed'; then
      printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "(tsan clean, threads=4)"
      pass=$((pass+1))
    else
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(did not run cleanly under tsan)"
      fail=$((fail+1)); failed_cases+=("$name:tsan-run")
    fi
  done
fi

# ARC leak gate (opt-in: ./run.sh --arc)
if [[ $ARC_MODE -eq 1 ]]; then
  echo "--- ARC leak gate (live objects at exit vs arc-baseline.txt) ---"
  baseline_file="$HERE/arc-baseline.txt"
  if [[ ! -f "$baseline_file" ]]; then
    echo "  ERROR: $baseline_file missing" >&2; exit 2
  fi
  improved=()
  for f in "$HERE"/cases/*.nova; do
    name="$(basename "$f" .nova)"
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
    base="$(grep -E "^$name " "$baseline_file" | awk '{print $2}')"
    if [[ -z "$base" ]]; then
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(no baseline entry — add one)"
      fail=$((fail+1)); failed_cases+=("$name:arc-nobaseline"); continue
    fi
    out="$(NOVA_ARC_AUDIT=1 "$NOVA" test "$f" 2>&1 | grep -vE '^DEBUG')"
    if printf '%s' "$out" | grep -q "ARC audit: clean"; then live=0
    else live="$(printf '%s' "$out" | grep -oE 'ARC AUDIT FAILED: [0-9]+' | grep -oE '[0-9]+' | head -1)"; fi
    live="${live:-}"
    if [[ -z "$live" ]]; then
      printf "  \033[31mFAIL\033[0m  %-32s %s\n" "$name" "(audit produced no report — did it run?)"
      fail=$((fail+1)); failed_cases+=("$name:arc-noreport"); continue
    fi
    if (( live > base )); then
      printf "  \033[31mFAIL\033[0m  %-32s live=%s baseline=%s  \033[31m(+%s LEAK REGRESSION)\033[0m\n" \
        "$name" "$live" "$base" "$((live-base))"
      fail=$((fail+1)); failed_cases+=("$name:arc+$((live-base))")
    elif (( live < base )); then
      printf "  \033[32mPASS\033[0m  %-32s live=%s baseline=%s  \033[32m(-%s improved — lower the baseline)\033[0m\n" \
        "$name" "$live" "$base" "$((base-live))"
      pass=$((pass+1)); improved+=("$name:$base->$live")
    else
      printf "  \033[32mPASS\033[0m  %-32s live=%s\n" "$name" "$live"
      pass=$((pass+1))
    fi
  done
  if (( ${#improved[@]} > 0 )); then
    echo "  ↓ improved (update arc-baseline.txt): ${improved[*]}"
  fi
fi

# F5-2 migration-invariant gate (opt-in: ./run.sh --shadow)
if [[ $SHADOW_MODE -eq 1 ]]; then
  echo "--- F5-2 shadow gate (string vs TypeId ownership engines MUST agree) ---"
  for f in "$HERE"/cases/*.nova; do
    name="$(basename "$f" .nova)"
    [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
    out="$(NOVA_SEMA_SHADOW=1 "$NOVA" test "$f" 2>&1)"; code=$?
    if printf '%s' "$out" | grep -q "FOUNDATION GATE FAILED"; then
      printf "  \033[31mFAIL\033[0m  %-32s \033[31m(ownership engines DISAGREE)\033[0m\n" "$name"
      printf '%s' "$out" | grep -A3 "FOUNDATION GATE FAILED" | sed 's/^/          /'
      fail=$((fail+1)); failed_cases+=("$name:shadow-disagree")
    elif [[ $code -ne 0 ]]; then
      printf "  \033[31mFAIL\033[0m  %-32s (compiler exited %s under shadow)\n" "$name" "$code"
      fail=$((fail+1)); failed_cases+=("$name:shadow-exit$code")
    else
      printf "  \033[32mPASS\033[0m  %-32s (engines agree)\n" "$name"
      pass=$((pass+1))
    fi
  done
fi

echo "----------------------------------------------------------------"
echo "Cases: $((pass+fail))  Passed: $pass  Failed: $fail"
if [[ $fail -gt 0 ]]; then
  echo "Failed: ${failed_cases[*]}"
  exit 1
fi
