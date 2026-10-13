#!/bin/bash
# bin/gh-pat-charge-alert.sh — say so when a fleet lane spends a PERSONAL ACCESS
# TOKEN's GitHub quota. Hub cron, hourly at :17.
#
# WHY. The fleet is moving to "App tokens everywhere, keyring logged out": every
# GitHub call should draw on a GitHub App installation bucket, never on a
# person's 5,000/h user bucket. On 2026-09-24 the hub alone still charged ~330
# calls/hour to `pat-default` (gh's keyring login, which is operator on every box):
# blocked-resolver.sh 213, tickets-snapshot-push.sh 101, wake-loop.sh 11,
# pipeline-health.sh 4 — and small, project-4, project-3-2, project-9 and project-5 had PAT
# callers too. bin/gh-quota-report.sh --fleet shows that when asked; nothing
# said it unprompted, so the migration had no counter. This lane is the counter:
# it goes quiet when the last PAT caller is converted.
#
# WHAT IT DOES. For the last COMPLETE UTC hour (or GH_PAT_CHARGE_ALERT_HOUR,
# YYYY-MM-DDTHH, for a re-check) it reads the fleet's GitHub-call ledger — the
# SAME read bin/gh-quota-report.sh --fleet makes: GET /api/metrics/gh-ledger on
# harness-jobs, the aggregates bin/gh-ledger-push.sh upserts from every box's
# state/gh-rest-ledger/ — and keeps every (box, bucket) whose bucket (the
# ledger's column 10, `meter` in D1, from gh_quota_bucket) matches
# ^(graphql-)?pat- with COUNTED calls >= GH_PAT_CHARGE_ALERT_MIN (default 1). A
# 304 or a 000 is ledgered with counted=0 and is not a charge.
#
# Each such pair is ONE logs/ALERTS.log line per UTC day (marker
# state/gh-pat-charge-alert/<day>/<box>__<bucket>): the box, the bucket in words,
# the counted calls that hour, the top 3 callers, and the remedy. Every run also
# writes one line to logs/gh-pat-charge-alert.log.
#
# WHEN THE WORKER CANNOT BE READ (no HARNESS_SECRET, no jobs-client, a non-2xx,
# an unparseable answer) it falls back to THIS box's own ledger file for that
# hour and says so, in the lane log (source=local why=…) and in the alert
# ("this box's ledger only").
#
# WHAT IT NEVER DOES. It costs ZERO GitHub API calls — it reads harness-jobs and
# files, nothing else. It never reads, prints or logs a token value: a bucket is
# already a label (`pat-<sha1 prefix>`), and that label is all that is written.
# rc 0 always from cron.
#
# Off with GH_PAT_CHARGE_ALERT=0, flags/lane-off-gh-pat-charge-alert, or
# bin/harness-ctl.sh off gh-pat-charge-alert.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-gh-pat-charge-alert
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.d/gh-pat-charge-alert.json. Operator: bin/harness-ctl.sh off gh-pat-charge-alert.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit gh-pat-charge-alert
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-pat-charge-alert
# global.env is sourced HERE because cron does not — HARNESS_SECRET and JOBS_URL
# live there. `+u` around it: an unbound reference must not kill the lane.
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
# BH-4080: HARNESS_OPERATOR_LOGIN names the keyring login in the alert's words.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
# Applied again below the env load: `set -a; . env/global.env` re-assigns every
# name it carries, which would drop a settings row for a knob the file also sets.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-pat-charge-alert
[ "${GH_PAT_CHARGE_ALERT:-1}" = 0 ] && exit 0

ARGBOX="${1:-}"   # optional box id, as gh-ledger-push.sh takes it
MIN="${GH_PAT_CHARGE_ALERT_MIN:-1}"
case "$MIN" in ''|*[!0-9]*|0) MIN=1 ;; esac
LOG="$H/logs/gh-pat-charge-alert.log"
ALERTS="$H/logs/ALERTS.log"
SDIR="$H/state/gh-pat-charge-alert"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" "$SDIR" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }

exec 9>"$H/locks/gh-pat-charge-alert.lock" || { say "cannot open locks/gh-pat-charge-alert.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }

# ── the hour: the last complete UTC hour, GNU then BSD date ─────────────────
HOUR="${GH_PAT_CHARGE_ALERT_HOUR:-}"
if [ -z "$HOUR" ]; then
  prev=$(( $(date -u +%s) - 3600 ))
  HOUR=$(date -u -d "@$prev" +%Y-%m-%dT%H 2>/dev/null || date -u -r "$prev" +%Y-%m-%dT%H 2>/dev/null)
fi
case "$HOUR" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]) ;;
  *) say "hour='${HOUR:0:32}' is not YYYY-MM-DDTHH — skipped"; exit 0 ;;
esac
DAY=${HOUR%T*}

# ── the rows: box<TAB>lane<TAB>meter<TAB>counted ────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-pat-charge-alert.XXXXXX") || { say "hour=$HOUR mktemp failed — skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
SRC=fleet; WHY=""
fleet_rows() {
  local resp="$WORK/resp.json"
  [ -n "${HARNESS_SECRET:-}" ] || { WHY="no HARNESS_SECRET"; return 1; }
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck disable=SC1090
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC"; break; }
  done
  command -v _jobs_req >/dev/null 2>&1 || { WHY="bin/jobs-client.sh missing"; return 1; }
  # The gh-quota-report --fleet read, bounded to ONE hour. JOBS_HTTP is the
  # status _jobs_req leaves behind; set here so `set -u` can never trip on it.
  JOBS_HTTP=""
  if ! JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$HOUR&until=$HOUR" > "$resp" 2>/dev/null; then
    WHY="worker unreachable, http=${JOBS_HTTP}"; return 1
  fi
  jq -e '.rows | type == "array"' "$resp" >/dev/null 2>&1 || { WHY="unparseable answer"; return 1; }
  [ "$(jq -r '.truncated // false' "$resp" 2>/dev/null)" = true ] && WHY="fleet answer TRUNCATED"
  jq -r '.rows[] | [(.box // "-"), (.lane // "-"), (.meter // "-"), ((.counted // 0) | tostring)] | @tsv' \
    "$resp" > "$WORK/rows.tsv" 2>/dev/null || { WHY="unparseable rows"; return 1; }
  return 0
}
if ! fleet_rows; then
  SRC=local
  # The label gh-ledger-push.sh gives this box's rows: argv first (the hub cron
  # passes `hub` to both), then bin/lib/box-id.sh — so a fallback hour can never
  # alert the same box a second time under another name.
  LBOX=$(printf '%s' "$ARGBOX" | tr -dc 'A-Za-z0-9._-')
  # shellcheck source=bin/lib/box-id.sh
  [ -n "$LBOX" ] || { . "$H/bin/lib/box-id.sh" 2>/dev/null && command -v box_id_get >/dev/null 2>&1 && LBOX=$(box_id_get 2>/dev/null); }
  LBOX=$(printf '%s' "${LBOX:-this-box}" | tr -dc 'A-Za-z0-9._-')
  F="$H/state/gh-rest-ledger/$HOUR.tsv"
  if [ -f "$F" ]; then
    awk -F'\t' -v b="$LBOX" 'NF >= 10 { printf "%s\t%s\t%s\t%s\n", b, $2, $10, ($7 ~ /^[0-9]+$/ ? $7 : 0) }' "$F" > "$WORK/rows.tsv" 2>/dev/null
  else
    : > "$WORK/rows.tsv"
    WHY="$WHY; no ledger file for $HOUR on this box"
  fi
fi

# ── fold: per (box, PAT bucket) the counted total and the top 3 callers ─────
# Output: box<TAB>bucket<TAB>total<TAB>"caller n, caller n, caller n"
awk -F'\t' -v min="$MIN" '
  $3 ~ /^(graphql-)?pat-[A-Za-z0-9._-]*$/ && ($4 + 0) > 0 {
    k = $1 "\t" $3
    if (!(k in tot)) keys[nk++] = k
    tot[k] += $4
    c = k "\t" $2
    if (!(c in cc)) { ncl[k]++; cl[k, ncl[k]] = $2 }
    cc[c] += $4
  }
  END {
    for (i = 0; i < nk; i++) {
      k = keys[i]
      if (tot[k] < min) continue
      n = ncl[k]
      for (a = 1; a <= n; a++) { nm[a] = cl[k, a]; v[a] = cc[k "\t" nm[a]] }
      for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++)
        if (v[b] > v[a] || (v[b] == v[a] && nm[b] < nm[a])) { t = v[a]; v[a] = v[b]; v[b] = t; t = nm[a]; nm[a] = nm[b]; nm[b] = t }
      top = ""
      for (a = 1; a <= n && a <= 3; a++) top = top (a > 1 ? ", " : "") nm[a] " " v[a]
      printf "%s\t%d\t%s\n", k, tot[k], top
    }
  }' "$WORK/rows.tsv" | LC_ALL=C sort > "$WORK/hits.tsv" 2>/dev/null

words() { # words <bucket> — the bucket label in words; never a token value
  local b="$1" g="" base
  case "$b" in graphql-*) g="GraphQL charged to "; base=${b#graphql-} ;; *) base=$b ;; esac
  case "$base" in
    pat-default) printf '%s = %sthe gh keyring login (%s)' "$b" "$g" "$HARNESS_OPERATOR_LOGIN" ;;
    *)           printf '%s = %sa PAT exported as GH_TOKEN' "$b" "$g" ;;
  esac
}

# ── one ALERTS.log line per (box, bucket, UTC day) ──────────────────────────
ALERTED=0; DEDUPED=0; PAIRS=0
mkdir -p "$SDIR/$DAY" 2>/dev/null
while IFS=$'\t' read -r box bucket total top; do
  [ -n "$box" ] || continue
  PAIRS=$((PAIRS + 1))
  sbox=$(printf '%s' "$box" | tr -dc 'A-Za-z0-9._-')
  sbkt=$(printf '%s' "$bucket" | tr -dc 'A-Za-z0-9._-')
  marker="$SDIR/$DAY/${sbox}__${sbkt}"
  if [ -e "$marker" ]; then DEDUPED=$((DEDUPED + 1)); continue; fi
  src_note="fleet ledger"
  case "$WHY" in *TRUNCATED*) src_note="fleet ledger, answer TRUNCATED — counts may be low" ;; esac
  [ "$SRC" = local ] && src_note="this box's ledger only — the fleet read failed ($WHY)"
  line="PAT CHARGE on ${sbox}: ${total} counted GitHub call(s) in ${HOUR} UTC on $(words "$sbkt"); top callers: ${top} (${src_note}). Remedy: resolve an App installation token before the call — gh_default_auth_for_slug / gh_auth_for in bin/lib/gh-app-auth.sh. Once per box+bucket per UTC day; lane gh-pat-charge-alert."
  # Through bin/alert-line.sh (alert-writer ratchet, BH-2314): it stamps, dedups
  # and beats the line. It never fails the caller, so success is the line landing.
  before=$(wc -l < "$ALERTS" 2>/dev/null || echo 0)
  HARNESS="$H" ALERT_LINE_STAMP="$(STAMP)" "$(dirname "$0")/alert-line.sh" "[gh-pat-charge-alert] $line"
  if [ "$(wc -l < "$ALERTS" 2>/dev/null || echo 0)" -gt "$before" ]; then
    : > "$marker" 2>/dev/null
    ALERTED=$((ALERTED + 1))
  fi
done < "$WORK/hits.tsv"

# Markers of an earlier UTC day are spent: the day they dedupe is over. The
# cutoff is the EARLIER of the hour's day and the real UTC day, so an overridden
# future GH_PAT_CHARGE_ALERT_HOUR can never prune today's markers.
CUT="$DAY"; TODAY=$(date -u +%Y-%m-%d)
[[ "$TODAY" < "$CUT" ]] && CUT="$TODAY"
for d in "$SDIR"/*/; do
  d=${d%/}; n=${d##*/}
  case "$n" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
  [[ "$n" < "$CUT" ]] && rm -rf "$d" 2>/dev/null
done

say "hour=$HOUR source=$SRC${WHY:+ why=\"$WHY\"} min=$MIN pat_pairs=$PAIRS alerted=$ALERTED deduped=$DEDUPED"
exit 0
