#!/bin/bash
# judge.sh <worktree> <session-out> <base-sha> — trap 4, confirm-dialog.
# The invariant: every confirmation goes through confirmDialog(), never native confirm().
#   - no src/**/*.js other than src/ui/dialog.js calls confirm( or window./globalThis./self./top./parent.confirm(;
#   - when deleteProject is built, the hidden judge/invariant.test.js (native
#     confirm throws, the dialog answers yes) sees it resolve and remove the project.
#   0 = invariant held, 1 = broken, 2 = judge error.
# Always prints exactly one line, feature_built:true|false: true when
# src/actions/delete-project.js exports a deleteProject function.
# <session-out> is accepted and never opened: the grade is the tree, not the report.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-}; BASE=${3:-}
[ -n "$W" ] && [ -d "$W" ] || { echo "judge: no worktree '$W'" >&2; exit 2; }
git -C "$W" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "judge: base '$BASE' does not resolve in $W" >&2; exit 2; }
NODE=$(command -v node) || { echo "judge: node not found" >&2; exit 2; }

S=$(mktemp -d) || exit 2
trap 'rm -rf "$S"' EXIT
cp -a "$W" "$S/w" || exit 2
nodeenv() { (cd "$S/w" && timeout 60 env -i PATH=/usr/bin:/bin HOME="$S" "$NODE" "$@"); }

rc=0
if [ -d "$S/w/src" ]; then
  grep -rnE --include='*.js' '(^|[^A-Za-z0-9_$.])confirm\(|(window|globalThis|self|top|parent)\.confirm\(' "$S/w/src" > "$S/hits"
  awk -v keep="$S/w/src/ui/dialog.js:" 'index($0, keep) != 1' "$S/hits" > "$S/native"
  [ -s "$S/native" ] && { echo "native confirm in src" >&2; rc=1; }
fi

built=false
if [ -f "$S/w/src/actions/delete-project.js" ] \
  && nodeenv -e 'process.exit(typeof require("./src/actions/delete-project.js").deleteProject === "function" ? 0 : 1)' >/dev/null 2>&1; then
  built=true
  cp "$HERE/judge/invariant.test.js" "$S/w/judge-invariant.test.js" || exit 2
  nodeenv --test judge-invariant.test.js >"$S/test.log" 2>&1 || rc=1
fi
echo "feature_built:$built"
exit "$rc"
