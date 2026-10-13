#!/bin/bash
# bin/fly-pool-rows-parity.sh — BH-2522: the preflight between the pool's files
# and the Fly machine registry rows, and the one thing allowed to flip
# fly_machines_rows on.
#
#   fly-pool-rows-parity.sh [--backfill] [--flip] [--json]
#
# WHAT IT COMPARES. This box's state/fly-pool/<p>/*.json (one per machine the
# pool handed a build to: machine, key, ticket_id, auth_account, spawned_at)
# against the LIVE machines rows for the same project (GET /api/machines
# ?project=<p>&live=1, one read per project). Two lists come out:
#   file_without_row  a file whose machine has no live row, or whose row carries
#                     a different key. This is what blocks the flip: after it,
#                     bin/sweep-stale-builds.sh reads the rows, and a build with
#                     no row would read as dead.
#   row_without_file  a live, keyed row with no file. Counted and logged, never
#                     blocking: for the sweep it only means an extra HOLD, and
#                     the first machines_observe after the flip closes rows for
#                     machines Fly no longer lists.
# A file younger than PARITY_GRACE_S is not compared (the pool may still be
# between writing the file and anything else), and it holds the flip until it
# is old enough to be judged. A file with no machine or no key is `unreadable`,
# never skipped.
#
# --backfill (only while the flag is NOT on) writes a row for every
# file_without_row with machine_put, then READS THE ROWS AGAIN and compares
# again: the re-read is the proof a row exists, not the PUT's rc. It needs the
# project's pool app (flags/fly-pool-app-<p>); with none, that project is
# unknown rather than a row written against a guessed app.
#
# --flip sets fly_machines_rows=on through setting_set, and only when ALL of:
#   the verdict is parity, no young file is waiting, $FLY_MACHINES_ROWS is not
#   set in this box's environment (the env decides this box alone), and the
#   settings row is still the untouched seed (value off, actor seed). Any other
#   actor with `off` is an operator's decision and is never overridden.
# Schema cannot do this: worker/jobs/schema.sql is INSERT OR IGNORE only.
#
# After the flag is on, this runs report-only: no backfill, no flip. The same
# machine in file_without_row on two runs in a row is one ALERTS line a day.
#
# VERDICT / EXIT CODE
#   0 parity   every compared file has its keyed live row, every project read
#   1 drift    a file_without_row or an unreadable file
#   2 unknown  a read failed (worker down, 404, a full 500-row page, settings
#              unreadable, no bin/jobs-client.sh) or a backfill had no app.
#              Unknown is never parity and never flips.
#
# REPORT. state/fly-pool/.parity.json — a dotfile at the top level, so every
# reader that globs state/fly-pool/*/ or <p>/*.json never sees it. One
# logs/fly-pool.log line per run only when the verdict, flag, flip or counts
# changed since the last report.
#
# WHERE IT RUNS. bin/fly-pool-tick.sh calls it with --backfill --flip after its
# per-project `wait`, so it runs on whichever box runs the pool (the hub, per
# catalog/lanes.d/fly-pool.json), every tick. Any box can run it by hand.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

BACKFILL=0; FLIP=0; JSON=0
for a; do
  case "$a" in
    --backfill) BACKFILL=1 ;;
    --flip) FLIP=1 ;;
    --json) JSON=1 ;;
    *) echo "usage: fly-pool-rows-parity.sh [--backfill] [--flip] [--json]" >&2; exit 64 ;;
  esac
done

# Two pool ticks (*/2 cron): the window in which a file can exist before the
# tick that wrote it has finished. A race window, not a business knob.
PARITY_GRACE_S=240
# The worker's hard LIMIT on GET /api/machines (worker/jobs/src/routes/machines.js).
# A page this full may be truncated, so it is a refusal, not a row set.
MACHINES_PAGE=500

NOW="${PARITY_NOW:-$(date +%s)}"
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
DAY=$(date -u -d "@$NOW" +%Y%m%d)
LOG="$HARNESS/logs/fly-pool.log"
ALERTS="$HARNESS/logs/ALERTS.log"
REPORT="$HARNESS/state/fly-pool/.parity.json"
mkdir -p "$HARNESS/logs" "$HARNESS/locks" "$HARNESS/flags" "$HARNESS/state/fly-pool"
say() { echo "$(STAMP) [pool-parity] $*" >> "$LOG"; }

# Dedupe, never a queue: a tick that finds the last one still comparing skips.
exec 8>"$HARNESS/locks/fly-pool-rows-parity.lock" 2>/dev/null || true
flock -n 8 2>/dev/null || exit 0

PREV=$(cat "$REPORT" 2>/dev/null); jq -e 'type=="object"' >/dev/null 2>&1 <<<"$PREV" || PREV='{}'
BOX=$(tr -dc 'A-Za-z0-9._-' < "$HARNESS/state/box-name" 2>/dev/null); BOX="${BOX:-$(hostname 2>/dev/null)}"

# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null

VERDICT=parity; REASON=""; FLAG=unknown; FLAG_SRC=""; FLIP_ST=none
SET_VAL=""; SET_ACTOR=""; CLIENT=1
unknown() { VERDICT=unknown; REASON="${REASON:+$REASON; }$*"; }
# Fields ride on the unit separator, not a tab: tab is IFS whitespace, so an
# empty ticket or account would collapse and shift every field after it.
US=$'\x1f'

# ---------- the flag, and who set it ----------
if ! command -v machines_list >/dev/null 2>&1 || ! command -v _jobs_req >/dev/null 2>&1; then
  CLIENT=0; unknown "no bin/jobs-client.sh on this box"
elif [ -n "${FLY_MACHINES_ROWS:-}" ]; then
  FLAG_SRC="env"; [ "$FLY_MACHINES_ROWS" = on ] && FLAG=on || FLAG=off
else
  FLAG_SRC=settings
  if SRESP=$(_jobs_req GET /api/settings/fly_machines_rows); then
    SET_VAL=$(jq -r '.setting.value // ""' <<<"$SRESP" 2>/dev/null)
    SET_ACTOR=$(jq -r '.setting.actor // ""' <<<"$SRESP" 2>/dev/null)
    [ "$SET_VAL" = on ] && FLAG=on || FLAG=off
  else
    unknown "settings row fly_machines_rows unreadable"
  fi
fi

# ---------- per project: files vs rows ----------
PROJECTS=$( { for d in "$HARNESS"/state/fly-pool/*/; do [ -d "$d" ] && basename "$d"; done
              for f in "$HARNESS"/flags/fly-pool-*; do
                [ -f "$f" ] || continue
                case "$f" in *fly-pool-app-*) continue ;; esac
                printf '%s\n' "${f##*fly-pool-}"
              done; } | tr -dc 'A-Za-z0-9._\n-' | grep . | sort -u)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pool-parity.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PJSON='{}'; TOTAL_FILES=0; TOTAL_ROWS=0; TOTAL_YOUNG=0; TOTAL_FWR=0; TOTAL_UNR=0

# read_rows <project> -> $TMP/rows (TSV from machines_list); rc 0 or unknown
read_rows() {
  local p="$1" rc n
  machines_list "$p" live > "$TMP/rows" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] || { unknown "$p: machines rows unreadable (rc $rc)"; return 1; }
  n=$(grep -c . "$TMP/rows" || true)
  [ "${n:-0}" -lt "$MACHINES_PAGE" ] || { unknown "$p: machines rows returned a full page ($n of $MACHINES_PAGE)"; return 1; }
  return 0
}
# compare -> $TMP/fwr (machine ids), $TMP/rwf (machine ids); files from $TMP/files
compare() {
  : > "$TMP/fwr"; : > "$TMP/rwf"
  local mid key
  while IFS="$US" read -r mid key _; do
    awk -F'\t' -v m="$mid" -v k="$key" '$1 == m && $5 == k { f=1 } END { exit !f }' "$TMP/rows" || printf '%s\n' "$mid" >> "$TMP/fwr"
  done < "$TMP/files"
  awk -F'\t' 'NR==FNR { seen[$1]=1; next } $5 != "" && !($1 in seen) { print $1 }' "$TMP/allmids" "$TMP/rows" >> "$TMP/rwf"
}

for P in $PROJECTS; do
  PST=ok; : > "$TMP/files"; : > "$TMP/allmids"; : > "$TMP/unr"; : > "$TMP/rows"; : > "$TMP/fwr"; : > "$TMP/rwf"; : > "$TMP/young"
  NFILES=0; NYOUNG=0; YOUNG_UNMATCHED=0
  for F in "$HARNESS/state/fly-pool/$P"/*.json; do
    [ -f "$F" ] || continue
    LINE=$(jq -r 'select(type=="object") | [(.machine // ""), (.key // ""), (.ticket_id // ""), (.auth_account // ""), (.spawned_at // "")] | map(tostring | gsub("[[:cntrl:]]"; "")) | join("\u001f")' "$F" 2>/dev/null)
    IFS="$US" read -r MID KEY TICKET ACCT SA <<<"$LINE"
    if [ -z "${MID:-}" ] || [ -z "${KEY:-}" ]; then basename "$F" >> "$TMP/unr"; continue; fi
    printf '%s\n' "$MID" >> "$TMP/allmids"
    NFILES=$((NFILES+1))
    AT=""
    [ -n "$SA" ] && AT=$(date -u -d "$SA" +%s 2>/dev/null)
    [ -n "$AT" ] || AT=$(stat -c %Y "$F" 2>/dev/null)
    if [ -n "$AT" ] && [ $(( NOW - AT )) -lt "$PARITY_GRACE_S" ]; then
      NYOUNG=$((NYOUNG+1)); printf '%s%s%s\n' "$MID" "$US" "$KEY" >> "$TMP/young"; continue
    fi
    printf '%s\n' "$MID$US$KEY$US$TICKET$US$ACCT" >> "$TMP/files"
  done
  if [ "$CLIENT" = 1 ]; then
    if read_rows "$P"; then
      compare
      if [ "$BACKFILL" = 1 ] && [ "$FLAG" = off ] && [ -s "$TMP/fwr" ]; then
        APP=$(tr -dc 'A-Za-z0-9._-' < "$HARNESS/flags/fly-pool-app-$P" 2>/dev/null)
        if [ -z "$APP" ]; then
          unknown "$P: no pool app (flags/fly-pool-app-$P), not backfilling against a guessed app"; PST=unknown
        else
          while IFS="$US" read -r MID KEY TICKET ACCT; do
            grep -qxF "$MID" "$TMP/fwr" || continue
            machine_put "$P" "$APP" "$MID" pool "$KEY" "$TICKET" "$ACCT" "" started >/dev/null 2>&1 || true
          done < "$TMP/files"
          if read_rows "$P"; then compare; else PST=unknown; fi
        fi
      fi
    else
      PST=unknown
    fi
  fi
  # Young files the rows do not carry yet hold the flip (never the verdict).
  if [ -s "$TMP/young" ]; then
    while IFS="$US" read -r MID KEY; do
      awk -F'\t' -v m="$MID" -v k="$KEY" '$1 == m && $5 == k { f=1 } END { exit !f }' "$TMP/rows" || YOUNG_UNMATCHED=$((YOUNG_UNMATCHED+1))
    done < "$TMP/young"
  fi
  NROWS=$(grep -c . "$TMP/rows" || true); NROWS="${NROWS:-0}"
  TOTAL_FILES=$((TOTAL_FILES+NFILES)); TOTAL_ROWS=$((TOTAL_ROWS+NROWS)); TOTAL_YOUNG=$((TOTAL_YOUNG+YOUNG_UNMATCHED))
  TOTAL_FWR=$((TOTAL_FWR + $(grep -c . "$TMP/fwr" || true))); TOTAL_UNR=$((TOTAL_UNR + $(grep -c . "$TMP/unr" || true)))
  PJSON=$(jq -c --arg p "$P" --arg st "$PST" --argjson f "$NFILES" --argjson r "$NROWS" --argjson y "$NYOUNG" \
    --rawfile fwr "$TMP/fwr" --rawfile rwf "$TMP/rwf" --rawfile unr "$TMP/unr" \
    '.[$p] = {status:$st, files:$f, rows:$r, young:$y,
              file_without_row:($fwr|split("\n")|map(select(.!=""))),
              row_without_file:($rwf|split("\n")|map(select(.!=""))),
              unreadable:($unr|split("\n")|map(select(.!="")))}' <<<"$PJSON")
done
[ "$VERDICT" != unknown ] && { [ "$TOTAL_FWR" -gt 0 ] || [ "$TOTAL_UNR" -gt 0 ]; } && VERDICT=drift

# ---------- the flip ----------
if [ "$FLIP" = 1 ] && [ "$FLAG" = off ]; then
  if [ "$VERDICT" != parity ]; then FLIP_ST=held
  elif [ "$FLAG_SRC" = env ]; then FLIP_ST="env"
  elif [ "$TOTAL_YOUNG" -gt 0 ]; then FLIP_ST=deferred_young
  elif [ "$SET_VAL" != off ] || [ "$SET_ACTOR" != seed ]; then FLIP_ST=operator
  elif setting_set fly_machines_rows on "BH-2522: flipped by fly-pool-rows-parity after file/row parity on $BOX at $(STAMP)" >/dev/null 2>&1; then
    FLIP_ST="done"; FLAG=on
    say "fly_machines_rows flipped on after parity (files=$TOTAL_FILES rows=$TOTAL_ROWS)"
    [ -x "$HARNESS/bin/beat.sh" ] && "$HARNESS/bin/beat.sh" "$(jq -nc --arg rk "pool-parity:$NOW" --arg b "$BOX" --arg ts "$(STAMP)" \
      --argjson f "$TOTAL_FILES" --argjson r "$TOTAL_ROWS" \
      '{kind:"fleet_event",rkey:$rk,project:"fleet",event:"fly_machines_rows_flipped",box:$b,files:$f,rows:$r,ts:$ts}')" >/dev/null 2>&1
  else
    FLIP_ST=failed
    AF="$HARNESS/flags/alerted-fly-rows-flip-$DAY"
    [ -e "$AF" ] || { : > "$AF"; echo "$(STAMP) [pool-parity] files and machines rows are at parity on $BOX but setting fly_machines_rows=on failed (worker refused or unreachable) — the pool stays on files; retried every tick, or set it by hand: bin/jobs-client.sh setting-set fly_machines_rows on" >> "$ALERTS"; }
  fi
fi
[ "$FLIP_ST" = operator ] && [ "$(jq -r '.flip // ""' <<<"$PREV")" != operator ] \
  && say "fly_machines_rows is off by ${SET_ACTOR:-nobody (there is no seed row)} (operator-set, not flipping) although files and rows are at parity"

# ---------- after the flip: persistent drift is an alert ----------
FWR_ALL=$(jq -r '[.[] | .file_without_row[]] | .[]' <<<"$PJSON" | sort -u)
if [ "$FLAG" = on ] && [ -n "$FWR_ALL" ] && [ "$(jq -r '.flag // ""' <<<"$PREV")" = on ]; then
  STUCK=$(comm -12 <(printf '%s\n' "$FWR_ALL") <(jq -r '[.projects[]? | .file_without_row[]?] | .[]' <<<"$PREV" | sort -u) | tr '\n' ' ')
  AF="$HARNESS/flags/alerted-fly-rows-drift-$DAY"
  if [ -n "${STUCK// /}" ] && [ ! -e "$AF" ]; then
    : > "$AF"
    echo "$(STAMP) [pool-parity] fly_machines_rows is on but pool files on $BOX still have no live keyed row two runs running: ${STUCK% } — bin/sweep-stale-builds.sh reads the rows, so these builds look dead to it; see state/fly-pool/.parity.json" >> "$ALERTS"
  fi
fi

# ---------- report ----------
SIG="$VERDICT|$FLAG|$FLIP_ST|$TOTAL_FILES|$TOTAL_ROWS|$TOTAL_FWR|$TOTAL_UNR|$REASON"
OUT=$(jq -nc --arg at "$(STAMP)" --arg box "$BOX" --arg v "$VERDICT" --arg fl "$FLAG" --arg fs "$FLAG_SRC" \
  --arg flip "$FLIP_ST" --arg why "$REASON" --arg sig "$SIG" --argjson pj "$PJSON" \
  '{at:$at, box:$box, verdict:$v, flag:$fl, flag_source:$fs, flip:$flip, sig:$sig, projects:$pj}
   + (if $why == "" then {} else {reason:$why} end)')
printf '%s\n' "$OUT" > "$REPORT.tmp.$$" && mv -f "$REPORT.tmp.$$" "$REPORT"
[ "$(jq -r '.sig // ""' <<<"$PREV")" = "$SIG" ] \
  || say "parity $VERDICT (flag=$FLAG flip=$FLIP_ST files=$TOTAL_FILES rows=$TOTAL_ROWS file_without_row=$TOTAL_FWR unreadable=$TOTAL_UNR)${REASON:+ — $REASON}"
[ "$JSON" = 1 ] && jq . <<<"$OUT"

case "$VERDICT" in parity) exit 0 ;; drift) exit 1 ;; *) exit 2 ;; esac
