#!/bin/bash
# bin/lib/extra-usage-read.sh — the reader of the harness-jobs
# `extra_usage_snapshots` table, so the hub never has to cat a box's
# logs/extra-usage.csv over ssh to learn its account meter (BH-2527).
#
# Every box's bin/extra-usage-track.sh already posts one row per poll to
# POST /api/metrics/extra-usage (bin/lib/jobs/cost.sh metric_extra_usage),
# keyed by the ACCOUNT LABEL it polled. This file reads that series back in the
# tracker's own CSV shape, so a caller that parsed the box's file by column name
# (bin/cost-rollup.sh's read_overage_meter) keeps its parsing unchanged.
#
#   extra_usage_fetch <label> <out-csv>
#       GET /api/metrics/extra-usage?box=<label>&limit=1000. Writes the
#       tracker's header plus every snapshot, OLDEST FIRST (the route answers
#       newest-first, and read_overage_meter takes the last row as the newest).
#       A NULL column renders empty, the way the tracker writes a failed poll.
#       rc 0 = the table answered (possibly with no rows: a header-only file);
#       rc 1 = unreadable (no client, a failed request, a body that is not the
#       route's shape) and <out-csv> is NOT written. Unreadable is never an
#       empty meter: the caller names it.
#
#   extra_usage_label_for_box <box>
#       The label a box's DEFAULT login (/root/.claude) posts under: the
#       catalog/cost-accounts.json account whose login.box is <box> and whose
#       login.config_dir is /root/.claude, else <box> itself — the same
#       resolution bin/extra-usage-track.sh makes when it polls.

EXTRA_USAGE_READ_HDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status'

# Sibling-first, like bin/lib/cost-rows-read.sh's _cost_rows_client.
_extra_usage_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  local _p
  for _p in "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh" \
            "${HARNESS:-/root/harness}/bin/jobs-client.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_p" ] && { . "$_p"; break; }
  done
  command -v _jobs_req >/dev/null 2>&1
}

extra_usage_fetch() {
  local label="${1:-}" out="${2:-}" resp
  [ -n "$label" ] && [ -n "$out" ] || return 1
  _extra_usage_client || return 1
  resp=$(_jobs_req GET "/api/metrics/extra-usage?box=$label&limit=1000" 2>/dev/null) || return 1
  printf '%s' "$resp" | python3 -c '
import json, sys
cols = sys.argv[1].split(",")
try:
    rows = json.load(sys.stdin).get("snapshots")
except Exception:
    sys.exit(1)
if not isinstance(rows, list):
    sys.exit(1)
def cell(v):
    if v is None:
        return ""
    return str(v).replace(",", " ").replace("\n", " ").replace("\r", "")
print(",".join(cols))
for r in sorted((r for r in rows if isinstance(r, dict)), key=lambda r: str(r.get("ts") or "")):
    print(",".join(cell(r.get(c)) for c in cols))
' "$EXTRA_USAGE_READ_HDR" > "$out.tmp.$$" 2>/dev/null \
    && mv -f "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; return 1; }
}

extra_usage_label_for_box() {
  local box="${1:-}" f="${COST_ACCOUNTS_FILE:-}" lbl=""
  if [ -z "$f" ]; then
    for f in "${HARNESS:-/root/harness}/catalog/cost-accounts.json" \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/cost-accounts.json"; do
      [ -r "$f" ] && break
    done
  fi
  [ -r "$f" ] && lbl=$(python3 - "$f" "$box" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for label, a in sorted((d.get("accounts") or {}).items()):
    login = (a or {}).get("login") or {}
    if login.get("box") == sys.argv[2] and login.get("config_dir") == "/root/.claude":
        print(label)
        break
PY
)
  printf '%s\n' "${lbl:-$box}"
}
