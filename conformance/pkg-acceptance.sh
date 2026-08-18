#!/usr/bin/env bash
# Package-manager acceptance (pkg-manager.md §10), fully LOCAL — no network. Builds three git repos
# A -> B -> C with file:// urls and tagged releases, then exercises fetch/lock/build-honors-lock/update/
# publish. Run: bash conformance/pkg-acceptance.sh
set -uo pipefail
export PATH="$HOME/.nova/bin:$PATH"
git config --global protocol.file.allow always 2>/dev/null || true

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail=0
say() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# --- build a package repo: mkrepo <dir> <name> <version> <src-fn-body> <dep-url-or-empty> ---
mkrepo() {
  local dir="$1" name="$2" ver="$3" body="$4" dep="$5"
  local bare="$WS/$name.git"
  git init -q --bare "$bare"
  git init -q "$dir"; ( cd "$dir"
    local deps="[]"; [ -n "$dep" ] && deps="[\"$dep\"]"
    cat > project.json <<JSON
{
  "name": "$name",
  "version": "$ver",
  "type": "library",
  "repository": "file://$bare",
  "dependencies": $deps
}
JSON
    mkdir -p src
    printf 'pub fn %s_hello(): string {\n    return "%s";\n}\n' "$name" "$name" > "src/$name.nova"
    git add -A; git commit -qm "init $name $ver"
    git tag -a "v$ver" -m "v$ver"
    git remote add origin "$bare"; git push -q origin HEAD:refs/heads/main; git push -q origin "v$ver"
  )
  echo "$bare"
}

C_BARE="$(mkrepo "$WS/C" cpkg 1.0.0 c "")"
B_BARE="$(mkrepo "$WS/B" bpkg 1.0.0 b "file://$C_BARE#v1.0.0")"
A_BARE="$(mkrepo "$WS/A" apkg 1.0.0 a "file://$B_BARE#v1.0.0")"

# fresh package cache so counts are deterministic
CACHE="$HOME/.nova/cache"; SAVED=""
if [ -d "$CACHE" ]; then SAVED="$(mktemp -d)"; mv "$CACHE" "$SAVED/cache"; fi
restore_cache() { rm -rf "$CACHE"; [ -n "$SAVED" ] && mv "$SAVED/cache" "$CACHE"; }
trap 'restore_cache; rm -rf "$WS"' EXIT
mkdir -p "$CACHE"

# ---- app that depends on A ----
APP="$WS/app"; mkdir -p "$APP/src"; ( cd "$APP"
  cat > project.json <<JSON
{ "name": "app", "version": "0.1.0", "type": "console", "dependencies": [] }
JSON
  printf 'import string;\nfn main(): void { console.log("app"); }\n' > src/main.nova
  git init -q .; git add -A; git commit -qm init
)

# ===== Acceptance 1: nova get A#v1 fetches A,B,C; lock has 3 entries w/ SHAs + DECLARED names =====
say "1. nova get (transitive fetch + lock)"
( cd "$APP" && nova get "file://$A_BARE#v1.0.0" ) >/dev/null 2>&1
LOCK="$APP/project.lock.json"
if [ -f "$LOCK" ]; then ok "lock created"; else bad "no project.lock.json"; fi
n=$(grep -c '"resolved"' "$LOCK" 2>/dev/null || echo 0)
[ "$n" -eq 3 ] && ok "lock has 3 resolved entries" || bad "expected 3 lock entries, got $n"
for nm in apkg bpkg cpkg; do
  grep -q "\"name\": \"$nm\"" "$LOCK" && ok "lock records declared name $nm" || bad "lock missing name $nm"
  ls -d "$CACHE/$nm-"* >/dev/null 2>&1 && ok "cache dir for $nm" || bad "no cache dir $nm-<sha8>"
done

# ===== Acceptance 2: move a tag; nova restore checks out the LOCKED SHA; lock unchanged =====
say "2. build/restore honors the lock (immune to a moved tag)"
LOCKED_A=$(grep -A3 "$A_BARE" "$LOCK" | grep '"resolved"' | grep -oE '[0-9a-f]{40}' | head -1)
( cd "$WS/A" && echo "// moved" >> "src/apkg.nova" && git commit -qam move && git tag -f -a v1.0.0 -m v1.0.0 && git push -qf origin v1.0.0 ) >/dev/null 2>&1
cp "$LOCK" "$WS/lock.before"
( cd "$APP" && nova restore ) >/dev/null 2>&1
if diff -q "$WS/lock.before" "$LOCK" >/dev/null; then ok "lock unchanged after a moved tag"; else bad "restore rewrote the lock (should honor it)"; fi
NOW_A=$(grep -A3 "$A_BARE" "$LOCK" | grep '"resolved"' | grep -oE '[0-9a-f]{40}' | head -1)
[ "$LOCKED_A" = "$NOW_A" ] && ok "apkg still pinned to the locked SHA" || bad "apkg SHA moved without update"

# ===== Acceptance 3: nova update moves the locked SHA; lock changes =====
say "3. nova update moves the pin"
( cd "$APP" && nova update "file://$A_BARE" ) >/dev/null 2>&1
UPD_A=$(grep -A3 "$A_BARE" "$LOCK" | grep '"resolved"' | grep -oE '[0-9a-f]{40}' | head -1)
[ "$UPD_A" != "$LOCKED_A" ] && ok "update moved apkg to the new tip ($LOCKED_A -> $UPD_A)" || bad "update did not move the pin"

# ===== Acceptance 6: publish creates v<version> + pushes; refuses re-publish =====
say "6. nova publish (tag + push; refuse re-publish)"
PUB="$WS/pubpkg"; PBARE="$WS/pubpkg.git"; git init -q --bare "$PBARE"
git init -q "$PUB"; ( cd "$PUB"
  cat > project.json <<JSON
{ "name": "pubpkg", "version": "2.0.0", "type": "library", "repository": "file://$PBARE", "dependencies": [] }
JSON
  mkdir -p src; printf 'pub fn hi(): string { return "hi"; }\n' > src/pubpkg.nova
  git add -A; git commit -qm init; git remote add origin "$PBARE"; git push -q origin HEAD:refs/heads/main
)
( cd "$PUB" && nova publish ) >/dev/null 2>&1
( cd "$PUB" && git ls-remote --tags "$PBARE" | grep -q "refs/tags/v2.0.0" ) && ok "publish pushed tag v2.0.0" || bad "publish did not push v2.0.0"
# re-publish must refuse
if ( cd "$PUB" && nova publish ) >/dev/null 2>&1; then bad "re-publish succeeded (should refuse)"; else ok "re-publish refused"; fi

echo
if [ $fail -eq 0 ]; then echo "PKG ACCEPTANCE: PASS"; else echo "PKG ACCEPTANCE: FAIL"; fi
exit $fail
