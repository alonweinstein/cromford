#!/bin/bash
# bin/config-inventory.sh — BH-1511.0: classify every `${VAR:-literal}` read
# and every hardcoded endpoint literal the fleet ships, so #1511's conversion
# slices (.1 .. N) know which of the ~1,600 names should become a settings
# row and which are plumbing this generator can already explain away.
#
# NO NETWORK, NO GIT WRITE. This is a pure scan-and-classify pass over the
# tree it is pointed at (default: the repo this script lives in) — see
# bin/config-inventory.py's own docstring for the classification rules.
#
# Usage:
#   bin/config-inventory.sh [--root <path>] [--out <dir>]
#   bin/config-inventory.sh --check [--root <path>]
#     --root   tree to scan (default: this repo's root)
#     --out    where to write the renders (default: <root>/docs/config-inventory)
#     --check  BH-5518: the freshness proof. Writes nothing under the repo. It
#              renders the same tree twice, at once, into mktemp dirs and
#              compares the outputs. That catches nondeterminism inside one
#              render (set or dict order under different Python hash seeds). It
#              does not catch drift across checkouts (an mtime, or a path that
#              depends on where the tree sits). No path under
#              docs/config-inventory may be tracked (the renders are
#              git-ignored); deployment.md must record zero un-allowlisted
#              literals.
#
# Output, all written every run (not with --check):
#   <out>/inventory.json   the whole answer — variables, endpoints, conflicts,
#                          duplicates and the proposed conversion slices.
#   <out>/index.html       a self-contained, sortable-table summary of the
#                          same data, for a human to read without jq.
#   <out>/deployment.{json,md}  the BH-4080 deployment-literal report, when
#                          the tree has catalog/deployment-literals.tsv.
# None of them is committed (BH-5518, .gitignore): every reader renders first.
#
# Exit, plain run: the generator's (0 for any scan; a scan that finds nothing is
# still a valid, if suspicious, answer — tests/config-inventory.bh-1511-test.sh
# is what asserts the counts look right, not this wrapper).
# Exit, --check: 0 clean; 1 a finding (a render differs between two runs, a
# render is tracked, an un-allowlisted literal); 2 could not run (no python3, no
# git, the generator failed). 2 is never a pass.
set -uo pipefail
# BH-1138: no __pycache__ next to a bin/*.py this repo tracks. This script
# invokes config-inventory.py directly (`python3 <path>`), and CPython can
# write a bytecode cache next to an invoked script the same way it does for
# an imported module — gitignore has no say over a path that is already
# tracked, and tests/pycache-untracked.bh-1138-test.sh is CI's tripwire for
# it landing on main again.
export PYTHONDONTWRITEBYTECODE=1
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
OUT=""
CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "config-inventory.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "config-inventory.sh: python3 not found" >&2; exit 2; }

if [ "$CHECK" = 0 ]; then
  ARGS=(--root "$ROOT")
  [ -n "$OUT" ] && ARGS+=(--out "$OUT")
  python3 "$SELF/config-inventory.py" "${ARGS[@]}"
  exit $?
fi

# ── --check (BH-5518) ────────────────────────────────────────────────────────
[ -z "$OUT" ] || { echo "config-inventory.sh: --check writes nothing; --out does not apply" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "config-inventory.sh: git not found" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/config-inventory-check.XXXXXX") \
  || { echo "config-inventory.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# The two renders run at once: one render of the real tree takes ~25 s.
python3 "$SELF/config-inventory.py" --root "$ROOT" --out "$WORK/a" >"$WORK/a.log" 2>&1 & PA=$!
python3 "$SELF/config-inventory.py" --root "$ROOT" --out "$WORK/b" >"$WORK/b.log" 2>&1 & PB=$!
wait "$PA"; RA=$?
wait "$PB"; RB=$?
if [ "$RA" != 0 ] || [ "$RB" != 0 ]; then
  echo "config-inventory: could not run: the generator exited $RA and $RB" >&2
  cat "$WORK/a.log" "$WORK/b.log" >&2
  exit 2
fi
cat "$WORK/a.log"

RC=0
# deployment.{json,md} exist only when the tree has a families catalog; a tree
# without one has neither file in either render, so there is nothing to compare.
for f in inventory.json index.html deployment.json deployment.md; do
  [ -e "$WORK/a/$f" ] || [ -e "$WORK/b/$f" ] || continue
  cmp -s "$WORK/a/$f" "$WORK/b/$f" || { echo "config-inventory: render not deterministic: $f"; RC=1; }
done

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for f in inventory.json index.html deployment.json deployment.md registry-drift.tsv; do
    if git -C "$ROOT" ls-files --error-unmatch "docs/config-inventory/$f" >/dev/null 2>&1; then
      echo "config-inventory: docs/config-inventory/$f is tracked; it is generated (BH-5518)"
      RC=1
    fi
  done
else
  echo "config-inventory: $ROOT is not a git work tree; nothing in it can be tracked"
fi

if [ -e "$WORK/a/deployment.md" ] && ! grep -q 'Un-allowlisted literals: \*\*0\*\*' "$WORK/a/deployment.md"; then
  echo "config-inventory: deployment.md records un-allowlisted literals; run bin/deployment-lint.sh"
  RC=1
fi

[ "$RC" = 0 ] && echo "config-inventory: --check ok (two renders identical, nothing under docs/config-inventory tracked)"
exit "$RC"
