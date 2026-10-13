#!/bin/bash
# bin/cli-version-check.sh — HUB, daily at 05:40Z (23 minutes after every box's
# 05:17 update-runners tick): ssh each fleet.conf box, read the runner CLI
# versions (claude, codex and grok — the `clis` keys of the catalog, so the
# catalog is the one place a CLI is added) its CRON PATH resolves, the PATH the
# lanes actually run under, and its login PATH, and compare them against the
# hub's own versions and against
# the per-model floors in catalog/cli-min-versions.json. ONE ALERTS line per
# box that is behind the hub, below a floor for a model its env or the fleet
# defaults name, missing a CLI, or split between its two PATHs; a summary line
# in logs/cli-version-check.log otherwise. The whole fleet table also lands in
# the harness-jobs DB (cli_versions rows with source=check, box_status current
# state) — fail-soft, the log and state/cli-versions-fleet.tsv are the record
# when the worker is unreachable.
#
# Why (2026-09-06): the Fable 5.1 bump needed claude-code >= 2.1.251 and
# box-project-9-1 sat on 2.1.250 for days; its codex npm update failed
# every morning into its own log. Nothing compared versions across the fleet,
# so a stranded box looked exactly like a quiet one. Detection only — this
# script never installs or relinks anything on a box (that is
# bin/cli-update.sh, which every ALERT here names as the fix).
#
# SELF-REPORTS FIRST (BH-2626). Every box posts its claude/codex versions hourly
# (bin/box-self-report.sh). A box whose row is TRUSTED is judged from it and not
# ssh'd: fresher than CLI_CHECK_SELF_REPORT_FRESH_S (a settings row, default
# 7200), both versions present, and cli_checked_at == rules_reported_at on that
# row, i.e. the newest CLI stamp came from a self-report that saw both CLIs, not
# from cli-update.sh's per-CLI post or this script's own source=check post, and
# the box's last full ssh probe is younger than CLI_CHECK_FULL_PROBE_S (a
# settings row, default 604800 = a week). A DB-judged box is held to behind-hub
# and the fleet-default floors only (no grok, no per-box *_MODEL floors, no
# cron-vs-login split), and posts NO source=check row: the hub did not observe
# that version. Those three checks the row cannot answer run on the full probe:
# in steady state every row is trusted, and without it they would never run
# again. Its report line names what the row verified and when the rest last ran.
# Anything else, and the hub itself, is probed over ssh exactly as before; a box
# whose full probe is due and does not answer is UNREACHABLE, re-tried every
# run until it answers. 0 = ssh every box.
#
# Overrides (tests only): HARNESS, HARNESS_CHECKOUT, HARNESS_ALERTS,
# CLI_CHECK_BOXES ("local" = the hub), CLI_CHECK_SSH, CLI_CHECK_CATALOG; and,
# inside the probe (exported through the ssh stub): CLI_CHECK_ENV_FILE,
# CLI_CHECK_LOGIN_PATH, CLI_CHECK_HOME.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cli-version-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cli-version-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cli-version-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cli-version-check
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/cli-version.sh
. "$HERE/lib/cli-version.sh"
# shellcheck source=bin/lib/cron-lines.sh
[ -r "$HERE/lib/cron-lines.sh" ] && . "$HERE/lib/cron-lines.sh"
declare -F cron_box_id_for >/dev/null 2>&1 || cron_box_id_for() { local b="${1#box-}"; case "$b" in ''|local|1) echo hub ;; *) echo "${b%-[0-9]*}" ;; esac; }

LOG="$H/logs/cli-version-check.log"
ALERTS="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
TSV="$H/state/cli-versions-fleet.tsv"
CATALOG="${CLI_CHECK_CATALOG:-$CHECKOUT/catalog/cli-min-versions.json}"
[ -s "$CATALOG" ] || CATALOG="$H/catalog/cli-min-versions.json"
SSH_CMD="${CLI_CHECK_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/state" 2>/dev/null
AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cli-version-check
# shellcheck source=/dev/null
[ -f "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null

# --- which CLI a box is allowed to lack (BH-1636) ------------------------------
# CLI_CHECK_OPTIONAL is a settings row (lane.cli-version-check.cli_check_optional),
# a space-separated list of <cli>@<box-id> pairs, box ids as cron_box_id_for
# prints them. A listed pair whose CLI reads MISSING is not an alert: that box
# runs no lane that needs it. ONLY missing is waived. A listed CLI that IS
# installed still has to meet its floor, match the hub and agree across both
# PATHs, because a lane can still pick it up. Empty = every CLI required on
# every box, which is how the check behaved before the knob existed.
declare -A OPTIONAL=()
read -r -a _toks <<<"${CLI_CHECK_OPTIONAL:-}"   # split without globbing a stray '*'
for _tok in ${_toks[@]+"${_toks[@]}"}; do
  if [[ "$_tok" =~ ^[a-z0-9_-]+@[a-z0-9_-]+$ ]]; then
    OPTIONAL[$_tok]=1
  else
    echo "$(STAMP) CLI_CHECK_OPTIONAL: ignored malformed token '$_tok' (want <cli>@<box-id>, lowercase)" >> "$LOG"
  fi
done
unset _tok _toks

# --- the probe, run on each box via `bash -s` (and locally for the hub) -------
# Reads versions under the CRON PATH — the crontab's own PATH= line when it has
# one, cron's /usr/bin:/bin default otherwise — because that is the PATH
# run-triage/run-build/agent-call inherit, and under a LOGIN PATH, because a
# human at a shell sees that one. Model ids from the box's env (*_MODEL=) are
# model NAMES, not secrets, and are filtered to id-shaped characters anyway.
# The env file is sourced with set -a for the PATH-affecting variables it may
# carry; nothing from it is printed except those model ids.
read -r -d '' PROBE <<'PROBE_EOF'
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf '%s\n' /root/harness/env; }; E=$(harness_env_dir)
ENVF="${CLI_CHECK_ENV_FILE:-$E/global.env}"
set -a +u; . "$ENVF" 2>/dev/null; set +a -u
CRON_PATH=$(crontab -l 2>/dev/null | sed -n 's/^PATH=//p' | tail -1); CRON_PATH="${CRON_PATH:-/usr/bin:/bin}"
LOGIN_PATH="${CLI_CHECK_LOGIN_PATH:-/usr/local/bin:/usr/bin:/bin}"
GROK_LAUNCHER="${CLI_CHECK_HOME:-$HOME}/.grok/bin/grok"
ver() { local o; o=$(timeout 10 "$1" --version 2>/dev/null | head -1); printf '%s' "$o" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }
# grok's launcher before PATH, in BOTH views: xAI's installer never links into
# /usr/bin, and every lane prepends $HOME/.grok/bin (bin/agent-call.sh,
# bin/lane-probe.sh, bin/orchestrate.sh). PATH-only would report the whole
# fleet MISSING, and a box whose /usr/local/bin holds an older grok would read
# as a cron-vs-login split it does not have.
cli_in() { # cli_in <cli> <path-list> -> the binary the lanes would run
  [ "$1" = grok ] && [ -x "$GROK_LAUNCHER" ] && { printf '%s' "$GROK_LAUNCHER"; return 0; }
  ( PATH="$2"; command -v "$1" 2>/dev/null || true )
}
for c in $CLI_LIST; do
  p=$(cli_in "$c" "$CRON_PATH");  v="";  [ -n "$p" ]  && v=$(ver "$p")
  lp=$(cli_in "$c" "$LOGIN_PATH"); lv=""; [ -n "$lp" ] && lv=$(ver "$lp")
  echo "cli $c ${v:-missing} ${p:--} ${lv:-missing} ${lp:--}"
done
M=$(env | grep -E '^[A-Z_]*MODEL[A-Z_]*=' | cut -d= -f2- | tr -c 'A-Za-z0-9._/\n-' ' ' | tr '\n' ' ')
echo "models ${M:0:400}"
echo "box $(tr -dc 'a-z0-9-' < /root/harness/state/box-id 2>/dev/null) host $(hostname 2>/dev/null)"
echo "probe-done"
PROBE_EOF

# The CLIs to probe are the catalog's `clis` keys, not a second hardcoded list:
# the floors already live there, and a CLI added to the catalog with nothing
# probing it is a floor nobody checks. Prepended as the probe's first line so
# the ssh'd copy carries it (the heredoc above is quoted, on purpose).
# Filtered to id-shaped characters because this string is interpolated into a
# single-quoted shell line that is then piped to `bash -s` on ten boxes: one
# quote in a catalog key would otherwise be a broken probe on the whole fleet.
CLI_LIST=""
[ -s "$CATALOG" ] && command -v jq >/dev/null 2>&1 \
  && CLI_LIST=$(jq -r '.clis | keys[]?' "$CATALOG" 2>/dev/null | tr -cd 'A-Za-z0-9_\n-' | tr '\n' ' ')
[ -n "${CLI_LIST// /}" ] || CLI_LIST="claude codex grok"
PROBE="CLI_LIST='$CLI_LIST'
$PROBE"

# --- the box list: fleet.conf column 6 plus the hub; PARKED rows are comments --
if [ -n "${CLI_CHECK_BOXES:-}" ]; then
  BOXES="$CLI_CHECK_BOXES"
else
  BOXES=$(printf 'local\n%s\n' \
    "$(awk '!/^[[:space:]]*(#|$)/ && NF>=6 {print $6}' "$CHECKOUT/fleet.conf" 2>/dev/null)" \
    | grep -v '^$' | sort -u)
fi

# --- the floors: fleet defaults + whatever a box's env names -----------------
DEFAULT_MODELS=""
[ -s "$CATALOG" ] && command -v jq >/dev/null 2>&1 \
  && DEFAULT_MODELS=$(jq -r '.fleet_defaults[]? // empty' "$CATALOG" 2>/dev/null | tr '\n' ' ')

probe() { # probe <box> -> probe output (empty when unreachable)
  if [ "$1" = local ]; then bash -c "$PROBE" 2>/dev/null
  else $SSH_CMD "root@$1" "bash -s" <<<"$PROBE" 2>/dev/null; fi
}

# --- self-reports (BH-2626) ---------------------------------------------------
# Rows are keyed by the cron box id, as the hub's own rows are; where two rows
# answer for one id (a generation suffix) the newest cli_checked_at wins.
FRESH="${CLI_CHECK_SELF_REPORT_FRESH_S:-7200}"
case "$FRESH" in ''|*[!0-9]*) FRESH=7200 ;; esac
FULL="${CLI_CHECK_FULL_PROBE_S:-604800}"
case "$FULL" in ''|*[!0-9]*) FULL=604800 ;; esac
FPDIR="$H/state/cli-version-check"
mkdir -p "$FPDIR" 2>/dev/null
NOW=$(date +%s)
# full_probe_age <id> — seconds since the box last answered a full ssh probe,
# stamped in $FPDIR/fullprobe-<id>; empty when it never has (or the stamp is bad).
full_probe_age() {
  local e
  e=$(cat "$FPDIR/fullprobe-$1" 2>/dev/null)
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  echo $((NOW - e))
}
# sr_fresh <at> — rc 0 when <at> is the exact UTC stamp shape, at most 300 s in
# the future (clock skew) and younger than FRESH. Anything else is stale.
sr_fresh() {
  local e
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ -n "$1" ] || return 1
  e=$(date -u -d "$1" +%s 2>/dev/null) || return 1
  [ $((NOW - e + 300)) -ge 0 ] && [ $((NOW - e)) -lt "$FRESH" ]
}
declare -A SR_CLI=()   # cron id -> cli \037 codex \037 cli_checked_at \037 rules_reported_at
if [ "$FRESH" -gt 0 ] && declare -F box_self_reports >/dev/null 2>&1; then
  if SR=$(box_self_reports 2>/dev/null); then
    # \037, not a tab, as the read separator: tab is IFS whitespace, so an empty
    # column would collapse and shift every field after it.
    while IFS=$'\037' read -r SB SC SX SCA _ SRA; do
      [ -n "$SB" ] && [ -n "$SCA" ] || continue
      SID=$(cron_box_id_for "$SB")
      IFS=$'\037' read -r _ _ PCA _ <<<"${SR_CLI[$SID]:-}"
      if [ -z "${SR_CLI[$SID]:-}" ] || [[ "$SCA" > "$PCA" ]]; then
        SR_CLI[$SID]="$SC"$'\037'"$SX"$'\037'"$SCA"$'\037'"$SRA"
      fi
    done < <(printf '%s\n' "$SR" | tr '\t' '\037')
  else
    echo "$(STAMP) cli-version-check: self-report read failed; ssh for every box" >> "$LOG"
  fi
fi

declare -A HUBV=()
OK=0; BEHIND=0; UNREACH=0; REPORT=""; ROWS="[]"
: > "$TSV.tmp"
# The hub first, so every other box has something to be behind.
ORDERED=$(printf '%s\n' "$BOXES" | grep -x local; printf '%s\n' "$BOXES" | grep -vx local)
for BOX in $ORDERED; do
  ID=$(cron_box_id_for "$BOX")
  SR_AT=""
  if [ "$BOX" != local ] && [ -n "${SR_CLI[$ID]:-}" ]; then
    IFS=$'\037' read -r SC SX SCA SRA <<<"${SR_CLI[$ID]}"
    if [ -n "$SC" ] && [ -n "$SX" ] && [ "$SC" != missing ] && [ "$SX" != missing ] \
       && [ "$SCA" = "$SRA" ] && sr_fresh "$SCA"; then
      AGE=$(full_probe_age "$ID")
      if [ -n "$AGE" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$FULL" ]; then
        SR_AT="$SCA"; FP_AT=$(date -u -d "@$((NOW - AGE))" +%Y-%m-%dT%H:%M:%SZ)
      fi
    fi
  fi
  if [ -n "$SR_AT" ]; then
    # Judged from the row: the same lines the probe prints, path "self-report@<at>".
    OUT=$(printf 'cli claude %s self-report@%s %s self-report@%s\ncli codex %s self-report@%s %s self-report@%s\nmodels \nprobe-done\n' \
      "$SC" "$SR_AT" "$SC" "$SR_AT" "$SX" "$SR_AT" "$SX" "$SR_AT")
  else
    OUT=$(probe "$BOX")
  fi
  if ! grep -q '^probe-done' <<<"$OUT"; then
    UNREACH=$((UNREACH+1)); REPORT="$REPORT\n  $ID UNREACHABLE"
    echo "$(STAMP) [$ID] cli-version-check could not probe $BOX over ssh — its runner CLI versions are unverified today. Check the box is up and ssh works from the hub." >> "$ALERTS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" "-" "unreachable" "-" "-" "-" >> "$TSV.tmp"
    continue
  fi
  [ "$BOX" = local ] || [ -n "$SR_AT" ] || echo "$NOW" > "$FPDIR/fullprobe-$ID"
  MODELS="$DEFAULT_MODELS $(awk '/^models /{$1=""; print}' <<<"$OUT")"
  REASONS=""
  while read -r _ CLI V P LV LP; do
    [ -n "$CLI" ] || continue
    CLI_REASONS=""
    [ "$BOX" = local ] && HUBV[$CLI]="$V"
    CLI_NOTE=""
    if [ "$V" = missing ] && [ -n "${OPTIONAL[$CLI@$ID]:-}" ]; then
      CLI_NOTE="not required on this box (CLI_CHECK_OPTIONAL)"
    elif [ "$V" = missing ]; then
      CLI_REASONS="$CLI MISSING on the cron PATH"
    else
      if [ "$BOX" != local ] && [ -n "${HUBV[$CLI]:-}" ] && [ "${HUBV[$CLI]}" != missing ] \
         && ! cli_version_ge "$V" "${HUBV[$CLI]}"; then
        CLI_REASONS="$CLI $V behind hub ${HUBV[$CLI]}"
      fi
      for M in $MODELS; do
        read -r MC MMIN < <(cli_min_for_model "$CATALOG" "$M" 2>/dev/null) || continue
        [ "$MC" = "$CLI" ] || continue
        if ! cli_version_ge "$V" "$MMIN"; then
          CLI_REASONS="${CLI_REASONS:+$CLI_REASONS; }$CLI $V below the $MMIN floor for $M"
        fi
      done
    fi
    if [ "$LV" != "$V" ]; then
      CLI_REASONS="${CLI_REASONS:+$CLI_REASONS; }$CLI split: cron PATH $V ($P) vs login PATH $LV ($LP)"
    fi
    CLI_OK=1; [ -z "$CLI_REASONS" ] || CLI_OK=0
    REASONS="${REASONS:+$REASONS; }$CLI_REASONS"; REASONS="${REASONS%; }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" "$CLI" "$V" "$P" "$LV" "${CLI_REASONS:-${CLI_NOTE:-ok}}" >> "$TSV.tmp"
    # A DB-judged box posts no source=check row: the hub did not observe it.
    [ -n "$SR_AT" ] && continue
    ROWS=$(jq -c --arg b "$ID" --arg c "$CLI" --arg v "$V" --arg p "$P" --arg n "${CLI_REASONS:-$CLI_NOTE}" --arg ok "$CLI_OK" --arg t "$AT" \
      '. + [{box:$b,cli:$c,at:$t,source:"check",version_before:$v,version_after:$v,method:"check",ok:$ok,path:$p,note:$n}]' <<<"$ROWS" 2>/dev/null || echo "$ROWS")
  done < <(grep '^cli ' <<<"$OUT")
  if [ -n "$REASONS" ]; then
    BEHIND=$((BEHIND+1)); REPORT="$REPORT\n  $ID: $REASONS"
    FIX="/root/harness/bin/cli-update.sh on $ID"; [ "$BOX" = local ] || FIX="ssh root@$BOX /root/harness/bin/cli-update.sh"
    echo "$(STAMP) [$ID] CLI VERSIONS: $REASONS. Fix: $FIX, then re-run bin/cli-version-check.sh on the hub; details in logs/cli-version-check.log." >> "$ALERTS"
  else
    OK=$((OK+1))
    if [ -n "$SR_AT" ]; then
      REPORT="$REPORT\n  $ID ok (claude/codex via self-report $SR_AT; grok, model floors, PATH split via ssh $FP_AT)"
    else
      REPORT="$REPORT\n  $ID ok"
    fi
  fi
done
mv -f "$TSV.tmp" "$TSV" 2>/dev/null

HUBLINE=""
for C in $CLI_LIST; do HUBLINE="$HUBLINE $C ${HUBV[$C]:-?}"; done
SUMMARY="fleet CLI versions: $OK ok, $BEHIND need attention, $UNREACH unreachable — hub${HUBLINE:- ?}; floors from $(basename "$CATALOG") for: ${DEFAULT_MODELS:-none}"
{ echo "$(STAMP) $SUMMARY"; printf '%b\n' "$REPORT" | sed "s/^/$(STAMP)   /"; } >> "$LOG"
echo "$SUMMARY"; printf '%b\n' "$REPORT"

# The fleet table into the DB, one request, fail-soft.
if declare -F metric_cli_versions >/dev/null 2>&1 && [ "$(jq 'length' <<<"$ROWS" 2>/dev/null || echo 0)" -gt 0 ]; then
  BODY=$(mktemp "${TMPDIR:-/tmp}/cli-versions.XXXXXX")
  jq -c '{rows: .}' <<<"$ROWS" > "$BODY" 2>/dev/null
  metric_cli_versions "$BODY" || echo "$(STAMP) DB push failed/skipped (http=${JOBS_HTTP:-none}); $TSV is the record" >> "$LOG"
  rm -f "$BODY"
fi
[ "$BEHIND" -eq 0 ] && [ "$UNREACH" -eq 0 ]
