#!/usr/bin/env bash
# M0 of the C++ runtime retirement plan (docs/design/cpp-runtime-retirement-plan.md): audit which
# nova_* symbols the C++ runtime EXPORTS versus which the compiler and standard library REFERENCE.
# The point is that "what still depends on C++" is a fact, and that a symbol proposed for removal is
# proven unreferenced before it is deleted.
#
# Usage:  tools/runtime-symbol-audit.sh            # summary + unreferenced (removal candidates)
#         tools/runtime-symbol-audit.sh <name>     # is this one symbol referenced, and where
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HOME/.nova/lib/libnovacore.a"
[ -f "$LIB" ] || { echo "runtime not built: $LIB missing (run: zig build)"; exit 2; }

# EXPORTED: defined text symbols in the runtime archive (macOS prefixes with an underscore).
exported() { nm -g "$LIB" 2>/dev/null | grep -E ' T _?nova_' | sed -E 's/.* _?(nova_[A-Za-z0-9_]+).*/\1/' | sort -u; }

# REFERENCED: every nova_* token in the compiler (codegen + main) and the standard library, minus
# the runtime's own source (self-references do not count as an external dependency).
referenced() {
  { grep -rhoE 'nova_[A-Za-z0-9_]+' "$HERE/src/codegen" "$HERE/src/main.zig" "$HERE/src/sema" 2>/dev/null
    grep -rhoE 'nova_[A-Za-z0-9_]+' "$HERE/src/std" 2>/dev/null
  } | sort -u
}

if [ $# -ge 1 ]; then
  sym="$1"
  echo "symbol: $sym"
  nm -g "$LIB" 2>/dev/null | grep -qE " T _?$sym\$" && echo "  exported by the runtime: yes" || echo "  exported by the runtime: NO"
  hits="$(grep -rlE "\\b$sym\\b" "$HERE/src/codegen" "$HERE/src/main.zig" "$HERE/src/sema" "$HERE/src/std" 2>/dev/null | sed "s#$HERE/##")"
  if [ -n "$hits" ]; then echo "  referenced in:"; echo "$hits" | sed 's/^/    /'; else echo "  referenced: NO (removal candidate)"; fi
  exit 0
fi

EXP="$(exported)"; REF="$(referenced)"
nexp=$(printf '%s\n' "$EXP" | grep -c .)
echo "=== runtime symbol audit ==="
echo "exported nova_* symbols: $nexp"
echo ""
echo "--- exported but NOT referenced by compiler or stdlib (removal candidates) ---"
unref="$(comm -23 <(printf '%s\n' "$EXP") <(printf '%s\n' "$REF"))"
if [ -n "$unref" ]; then printf '%s\n' "$unref" | sed 's/^/  /'; else echo "  (none)"; fi
echo ""
echo "count referenced: $(comm -12 <(printf '%s\n' "$EXP") <(printf '%s\n' "$REF") | grep -c .)  /  $nexp exported"
echo "Note: a removal candidate may still be reached indirectly (e.g. a symbol the linker keeps for"
echo "another symbol); confirm with 'tools/runtime-symbol-audit.sh <name>' and a build before deleting."
