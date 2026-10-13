#!/bin/bash
# bin/codegraph-harness-index.sh — keep a code graph of THIS box's harness
# checkout, and record whether it answers (BH-113).
#
# bin/codegraph-ensure.sh indexes target project clones for builds; the box's
# own /root/harness-checkout was never indexed, so harness self-modification
# tickets worked from grep alone. This runs that same ensure script against the
# checkout — it forks none of its logic — and writes its availability lines to
# state/codegraph-harness-checkout (first line `# <UTC timestamp>`), plus the
# first line to logs/update-runners.log.
#
# Called by bin/harness-sync.sh after the deploy is stamped. Always exits 0 and
# prints nothing a caller reads: an index is a convenience, never a reason for a
# sync to fail. Bounded by CODEGRAPH_INDEX_TIMEOUT_S (default 90 s, well inside
# fleet-propagate's `timeout 300`) and deduped with `flock -n` — a second run
# while one is indexing skips, it never waits. A timeout or an empty ensure
# answer is recorded NOT AVAILABLE, never AVAILABLE.
#
# HARNESS_CHECKOUT / HARNESS override the paths for tests, as in harness-sync.
set -uo pipefail
# The daily update-runners lane runs under the cron PATH (/usr/bin:/bin), where
# neither `codegraph` nor the `node` its shim execs resolves; both live in
# /usr/local/bin. Without this the backstop would record "CLI not installed" on a
# box that has it and skip the refresh.
export PATH="/usr/local/bin:$PATH"
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
HARNESS="${HARNESS:-/root/harness}"
TIMEOUT_S="${CODEGRAPH_INDEX_TIMEOUT_S:-90}"
LOG="$HARNESS/logs/update-runners.log"
NOTE="$HARNESS/state/codegraph-harness-checkout"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$HARNESS/locks" "$HARNESS/logs" "$HARNESS/state" 2>/dev/null

exec 9>"$HARNESS/locks/codegraph-harness-index.lock" || exit 0
if ! flock -n 9; then
  echo "$(STAMP) harness checkout code graph: another run is indexing, skipped" >> "$LOG"
  exit 0
fi

OUT=$(CODEGRAPH_REPO="$CHECKOUT" timeout "$TIMEOUT_S" \
  "$(dirname "$0")/codegraph-ensure.sh" cromford "$CHECKOUT" 2>/dev/null)
RC=$?
if [ "$RC" = 124 ]; then
  OUT="CODEGRAPH NOT AVAILABLE (indexing $CHECKOUT timed out after ${TIMEOUT_S}s)"
else
  case "$(head -1 <<<"$OUT")" in
    "CODEGRAPH AVAILABLE ("*|"CODEGRAPH NOT AVAILABLE ("*) ;;
    *) OUT="CODEGRAPH NOT AVAILABLE (ensure produced no verdict)" ;;
  esac
fi

{ printf '# %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; printf '%s\n' "$OUT"; } > "$NOTE.tmp" 2>/dev/null \
  && mv "$NOTE.tmp" "$NOTE" 2>/dev/null
echo "$(STAMP) harness checkout code graph: $(head -1 <<<"$OUT")" >> "$LOG"
exit 0
