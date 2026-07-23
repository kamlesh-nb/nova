#!/usr/bin/env bash
# pkg-manager-check.sh — proves the Nova package manager end-to-end:
#   manifest (project.json) -> `nova get` fetch into ~/.nova/cache -> import
#   resolution from the cache -> compile + run (both `nova test` and a binary).
#
# A 2-package example: a `mathlib` library package and a `consumer` that depends
# on it. Every step must succeed AND the consumer's tests must pass using symbols
# that ONLY exist in the fetched package.
#
# Usage:  NOVA=./zig-out/bin/nova ./conformance/pkg-manager-check.sh
set -u
NOVA="${NOVA:-./zig-out/bin/nova}"
NOVA="$(cd "$(dirname "$NOVA")" && pwd)/$(basename "$NOVA")"   # absolutize
TMP="$(mktemp -d)"
CACHE="$HOME/.nova/cache/nova-pkgtest-mathlib"
cleanup() { rm -rf "$TMP" "$CACHE"; }
trap cleanup EXIT
fail() { echo "FAIL: $1"; exit 1; }

# --- library package (its own git repo) ---
mkdir -p "$TMP/nova-pkgtest-mathlib/src"
cat > "$TMP/nova-pkgtest-mathlib/src/pkgtestlib.nova" <<'EOF'
pub fn square(x: int): int { return x * x; }
pub fn cube(x: int): int { return x * x * x; }
EOF
( cd "$TMP/nova-pkgtest-mathlib" && git init -q && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm lib ) || fail "git init lib"

# --- consumer project (depends on the library) ---
mkdir -p "$TMP/consumer/src" "$TMP/consumer/tests"
cat > "$TMP/consumer/project.json" <<EOF
{ "name": "consumer", "version": "0.1.0", "type": "console",
  "dependencies": ["$TMP/nova-pkgtest-mathlib"] }
EOF
cat > "$TMP/consumer/src/main.nova" <<'EOF'
import pkgtestlib;
fn main(): void {
    let r = square(9);
    console.log("ok");
}
EOF
cat > "$TMP/consumer/tests/main_test.nova" <<'EOF'
import assert;
import pkgtestlib;
@test
fn test_pkg_symbols(): void {
    assert.equalInt(square(9), 81);
    assert.equalInt(cube(4), 64);
}
EOF

cd "$TMP/consumer" || fail "cd consumer"

# 1. Restore from the manifest (no URL) — must fetch the dep into the cache.
"$NOVA" get >/dev/null 2>&1 || fail "nova get (restore) exited nonzero"
[ -f "$CACHE/src/pkgtestlib.nova" ] || fail "dependency not fetched into ~/.nova/cache"

# 2. Import resolution + compile + run under `nova test`.
out="$("$NOVA" test 2>&1)"
echo "$out" | grep -q "PASS  test_pkg_symbols" || { echo "$out"; fail "consumer tests did not pass"; }
echo "$out" | grep -q "0 failed" || { echo "$out"; fail "some consumer tests failed"; }

# 3. Compile the consumer's main to a native binary and run it.
"$NOVA" src/main.nova -o consumer_bin >/dev/null 2>&1 || fail "binary compile failed"
[ "$(./consumer_bin 2>&1)" = "ok" ] || fail "consumer binary did not run/print correctly"

# 4. Restore is idempotent — a second run fetches nothing.
"$NOVA" get 2>&1 | grep -q "0 fetched" || fail "restore not idempotent"

echo "----------------------------------------------------------------"
echo "package manager: fetch + resolve + compile + run + idempotent restore — ALL OK"
