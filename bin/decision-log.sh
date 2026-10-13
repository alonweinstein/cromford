#!/bin/bash
# bin/decision-log.sh <project> <gate> <scope> <session-out-file>
#
# Decision observability (2026-08-23, graph-engineering wave 2): cost.csv says
# what a triage tick COST; nothing said what it DECIDED or why. Post-mortems
# (the TK-42 twin-PR class) had to reverse-engineer routing decisions out of
# session transcripts. The triage prompt (run-triage.sh AGENT_SYSTEM_APPEND)
# asks the session to end with one line per ticket it acted on:
#   DECISION: <ticket-key> :: <action> :: <one-line reason>
# This extracts those lines from the session's output file and appends them,
# stamped with project/gate/scope, to logs/decisions.log — one greppable line
# per routing decision, next to the tick that made it.
#
# Fail-open by design: no DECISION lines, a missing file, a malformed block —
# all exit 0 and never break the triage tick. Cap 40 lines/tick, ~320 chars
# each (a session that floods the block is telling us something else is wrong).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
P="${1:-}"; GATE="${2:-?}"; SCOPE="${3:-?}"; OUT="${4:-}"
[ -n "$P" ] && [ -n "$OUT" ] && [ -f "$OUT" ] || exit 0
DLOG="$HARNESS/logs/decisions.log"
mkdir -p "$HARNESS/logs"
STAMP=$(date -u '+%Y-%m-%d %H:%M:%SZ')
# WRITE-THROUGH (BH-436): the hub wipe on 2026-09-15 took this log with it, so
# the same lines are mirrored to the coordination DB's append log. FILE FIRST,
# ROW SECOND, on every branch — the local file is the delivery, the POST is a
# copy, and nothing here is ever stamped "sent". $TMP is /tmp-derived and
# collected on exit; when mktemp fails we simply do not mirror this tick.
TMP=$(mktemp -d 2>/dev/null) || TMP=""
[ -n "$TMP" ] && trap 'rm -rf "$TMP"' EXIT
grep -a '^DECISION:' "$OUT" 2>/dev/null | head -40 | cut -c1-330 | while IFS= read -r L; do
  printf '%s [%s] gate=%s scope=%s %s\n' "$STAMP" "$P" "$GATE" "$SCOPE" "${L#DECISION: }" >> "$DLOG"
  # `line` is the file line MINUS its 20-char stamp and the one space after it,
  # because log_rehydrate re-emits each row as `stamp + " " + line`. Anything
  # else and a rehydrated file is not the file that was written.
  [ -n "$TMP" ] || continue
  jq -nc --arg s "$STAMP" --arg g "$GATE" --arg sc "$SCOPE" --arg p "$P" --arg pl "${L#DECISION: }" \
    '{stamp:$s,gate:$g,scope:$sc,ticket:($pl|split(" :: ")[0]),
      line:("["+$p+"] gate="+$g+" scope="+$sc+" "+$pl)}' >> "$TMP/rows.ndjson" 2>/dev/null
done
# No DECISION lines -> no rows file -> no request. Stderr is silenced on both
# the source and the verb: run-triage.sh and triage-shard.sh call this with
# `2>>"$ALERTS"`, and a coordination hiccup is not an ALERTS line.
if [ -n "$TMP" ] && [ -s "$TMP/rows.ndjson" ] && [ -r "$HARNESS/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  jq -s . "$TMP/rows.ndjson" > "$TMP/rows.json" 2>/dev/null \
    && decisions_put "$P" "$TMP/rows.json" >/dev/null 2>&1 || true
fi
# THE SKIP AUDIT (BH-5125): a skip/defer that claims a fix, round, build or
# rebuild is in progress must carry an [evidence: …] tag that checks out, or it
# is not honoured — one gate=audit handoff line here and one deduped ALERTS
# line (bin/lib/triage-skip-evidence.sh). After the mirror, so the rows the DB
# copy holds are the harvested lines only. Fail-open: no lib, no audit.
if [ -r "$HARNESS/bin/lib/triage-skip-evidence.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/triage-skip-evidence.sh" 2>/dev/null && tse_audit "$P" "$OUT" 2>/dev/null
fi
exit 0
