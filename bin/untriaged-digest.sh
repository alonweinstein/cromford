#!/bin/bash
# Untriaged-ticket digest (BH-2756, ask 4 of BH-2751): a pipeline-health count,
# one line per project per UTC day — "N open tickets with no triage verdict
# older than Xh". Covers the GitHub-Issues boards (bin/lib/untriaged-lib.sh:
# open ai-build issues with no comment) and every in-app board the registry
# lists (bin/fleet-conf.sh --projects-with-board, read through
# bin/lib/untriaged-board-read.sh, the same read bin/untriaged-sweep.sh alerts
# on). A read that fails says "could not count", never 0 and never nothing.
# N = 0 sends no line. Deterministic: no LLM. Cron: 17 6 * * * on the hub.
set -uo pipefail
# HARNESS is overridable so tests/untriaged-digest.bh-2756-test.sh can drive the
# SHIPPED script against a scratch tree. Cron sets it nowhere.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# global.env only. Each in-app project's base and token are read from its own
# $HENV/<p>.env by bin/lib/board-creds.sh, so no project is named here.
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate — flags/all-off or flags/lane-off-untriaged-digest stops the
# lane here, before any board is read; lane_env_apply puts this lane's settings
# rows (UNTRIAGED_ALERT_AFTER_H) into the environment. Both fail OPEN.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off untriaged-digest.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit untriaged-digest
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    untriaged-digest

# One registry for both halves: ut_gh_projects reads it directly and
# bin/fleet-conf.sh reads FLEET_CONF first.
export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
DAY=$(date -u +%Y%m%d)
SENT=0; FAILED=0; READ=0
alert() { # project text — one line per project per UTC day (the --id dedupes)
  "$H/bin/lane-alert.sh" --severity warn --id "untriaged-digest:$1:$DAY" untriaged-digest "$2" </dev/null
  SENT=$((SENT+1))
}
cant() { alert "$1" "[$1] could not count untriaged tickets ($2)"; FAILED=$((FAILED+1)); }
report() { # project "N NUM AGE_H" | fail  [capped]
  local n num age
  [ "$2" = fail ] && { cant "$1" "count failed"; return 0; }
  read -r n num age <<<"$2"
  READ=$((READ+1))
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  [ "${3:-0}" = 1 ] && n="$n+"
  alert "$1" "[$1] $n open tickets with no triage verdict older than ${AFTER_H}h (oldest #$num, ${age}h)"
}

# The knob: a whole number of hours >= 1. Anything else is refused, not clamped.
AFTER_H="${UNTRIAGED_ALERT_AFTER_H:-6}"
case "$AFTER_H" in ''|*[!0-9]*|0*) AFTER_H=bad ;; esac
if [ "$AFTER_H" = bad ]; then
  "$H/bin/lane-alert.sh" --severity warn --id "untriaged-digest:config:$DAY" untriaged-digest \
    "UNTRIAGED_ALERT_AFTER_H='${UNTRIAGED_ALERT_AFTER_H:-}' is not a whole number of hours >= 1; no project counted"
  exit 0
fi
MIN_S=$((AFTER_H*3600))

# shellcheck source=bin/lib/untriaged-lib.sh
. "$H/bin/lib/untriaged-lib.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/untriaged-lib.sh" 2>/dev/null
# shellcheck source=bin/lib/untriaged-board-read.sh
. "$H/bin/lib/untriaged-board-read.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/untriaged-board-read.sh" 2>/dev/null
# shellcheck source=bin/lib/board-creds.sh
. "$H/bin/lib/board-creds.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/board-creds.sh" 2>/dev/null

TMP=$(mktemp "${TMPDIR:-/tmp}/utd.XXXXXX") || exit 0
trap 'rm -f "$TMP"' EXIT

# ── GitHub-Issues boards ────────────────────────────────────────────────────
PROJECTS=""
if ! command -v ut_open_issues >/dev/null 2>&1; then cant fleet "bin/lib/untriaged-lib.sh did not load"
elif ! PROJECTS=$(ut_gh_projects "$FLEET_CONF"); then cant fleet "fleet.conf unreadable"; PROJECTS=""
fi
while read -r P SLUG; do
  [ -n "${P:-}" ] || continue
  GH_REST_REASON=""; GH_REST_STATUS=""
  # A plain command, never $( ): GH_REST_REASON/GH_REST_STATUS must survive.
  if ! ut_open_issues "$SLUG" > "$TMP"; then
    cant "$P" "${GH_REST_REASON:-${GH_REST_STATUS:-read failed}}"; continue
  fi
  report "$P" "$(jq -r --argjson min "$MIN_S" '
      [.[] | select((.comments // 0) == 0)
           | {n: .number, t: (.created_at | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)}
           | select(now - .t > $min)]
      | if length == 0 then "0" else (min_by(.t)) as $o
        | "\(length) \($o.n) \(((now - $o.t) / 3600) | floor)" end' "$TMP" 2>/dev/null || echo fail)" \
    "$UT_OPEN_ISSUES_CAPPED"
done <<< "$PROJECTS"

# ── In-app boards: every registry row with a board prefix ───────────────────
INAPP=""
if ! command -v ut_inapp_untriaged >/dev/null 2>&1 || ! command -v board_token_var >/dev/null 2>&1; then
  cant fleet "bin/lib/untriaged-board-read.sh or bin/lib/board-creds.sh did not load"
elif ! INAPP=$("$H/bin/fleet-conf.sh" --projects-with-board 2>/dev/null); then
  cant fleet "fleet.conf unreadable"; INAPP=""
fi
while read -r P; do
  [ -n "${P:-}" ] || continue
  ENVF="$HENV/$P.env"
  TV=$(board_token_var "$P" "$ENVF" untriaged-digest) || { cant "$P" "no board token"; continue; }
  BV=$(board_base_var "$P" "$ENVF" untriaged-digest)  || { cant "$P" "no board base"; continue; }
  PFX=$("$H/bin/fleet-conf.sh" "$P" board_prefix 2>/dev/null) || { cant "$P" "no board prefix"; continue; }
  if ! ut_inapp_untriaged "$P" "$(board_env_value "$BV" "$ENVF")" "$(board_env_value "$TV" "$ENVF")" "$PFX" "$MIN_S" > "$TMP"; then
    cant "$P" "board read failed"; continue
  fi
  report "$P" "$(jq -Rrn '
      [inputs | split("\t") | select(length >= 3)
       | {n: .[1], t: (.[2] | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)}]
      | if length == 0 then "0" else (min_by(.t)) as $o
        | "\(length) \($o.n) \(((now - $o.t) / 3600) | floor)" end' "$TMP" 2>/dev/null || echo fail)"
done <<< "$INAPP"

mkdir -p "$H/logs" 2>/dev/null
echo "$(STAMP) untriaged-digest after=${AFTER_H}h counted=$READ sent=$SENT failed=$FAILED" >> "$H/logs/untriaged-digest.log"
exit 0
