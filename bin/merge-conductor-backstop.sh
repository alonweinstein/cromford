#!/bin/bash
# bin/merge-conductor-backstop.sh — BH-3436.2 (BH-3454): the */5 KEYED backstop
# for the merge conductor. Worst case green -> queued is 5 minutes without the
# heavy full tick, which stays */30 (BH-1389, cron/lanes/410).
#
# WHAT IT READS: state/merge-conductor/pr-state.tsv, nothing else. A candidate
# is a row in WAIT_CI or READY whose reviewed sha equals its head. No candidate
# = one log line and exit 0, with no GitHub call and no conductor run.
# Otherwise the first MC_BACKSTOP_MAX_KEYS (default 6, 0 = no cap) are handed
# to ONE keyed conductor run, MC_ONLY_PR=<keys>, in the foreground under
# `timeout MC_BACKSTOP_TIMEOUT_S` (default 240) so it never overlaps the next
# fire, with each PR worker capped below that timeout (MC_WORKER_DEADLINE_CAP_S,
# BH-4918). A worker the timeout still kills is stamped in the fan-in ledger
# (BH-4842), and a PR missing that way on two fires in a row is worked alone
# by the conductor itself. That run skips the fleet sweeps, the main-red
# detector and mc_tick_metrics (the cadence hold is not reset), and runs
# ae_project over its filtered rows, so a green row goes READY and is enqueued
# in the same run.
#
# THE RUN FITS THE WINDOW (BH-4842). A run that takes more keys than it can
# finish is killed before fan-in and enqueues nothing: 14 keys died at timeout
# 290 on 2026-10-08, "enumerated 7 accounted 0". So the key count is not the
# only bound. The run gets MC_WORKERS_DONE_BY, the epoch second by which its
# workers must be gone (start + WD, below), and MC_WINDOW_DEFER_FILE. The
# conductor starts a worker only while at least 15 s are left until then, and
# caps that worker at what is left, so the 45 s after WD stay for the run's
# own fan-in and enqueue. A key it does not start is accounted deferred:window
# and written to that file, and this fire puts those keys at the head of the
# carry.
#
# THE ORDER, AND THE CARRY (BH-4842). The candidates are taken in this order:
# the keys the last capped fire deferred (state/merge-conductor/backstop-carry),
# in the order it deferred them, then the harness's own repo (HARNESS_REPO,
# bin/lib/deployment.sh), then the oldest `since`. A capped fire writes its
# remainder, in that order, to the carry file, so the next fire takes those
# first and every key gets its turn. The carry goes ahead of the harness's own
# repo: with the harness first, a repo with as many candidates as the cap took
# every slot on every fire, and no other project's key was ever taken.
#
# WHAT IT COSTS: nothing on an idle fleet. Per project that owns a candidate,
# one open-PR list; per candidate, the conductor's usual per-PR reads (pull,
# check-runs, thread; the read memo skips unchanged heads) and at most one
# `@mergifyio queue` post.
#
# OFF: bin/harness-ctl.sh off merge-conductor-backstop. It also stands down,
# exit 0, when flags/automerge-disabled or the conductor's own
# lane-off-merge-conductor is set.
set -uo pipefail
HARNESS="${HARNESS:-${H:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}}"
[ -n "$HARNESS" ] || { echo "merge-conductor-backstop: no harness root" >&2; exit 1; }
export HARNESS; H="$HARNESS"
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# HARNESS_REPO: the project this fire takes first. Fail-soft: without the file,
# no project goes first.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" 2>/dev/null || true

# >>> lane gate — flags/all-off or flags/lane-off-merge-conductor-backstop (or a
# pause_flags row driving either) exits 0; lane_env_apply then lets a settings
# row reach MC_BACKSTOP_MAX_KEYS and MC_BACKSTOP_TIMEOUT_S. Both fail OPEN.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-conductor-backstop
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-conductor-backstop
# <<< lane gate

say() { printf '%s merge-conductor-backstop: %s\n' "$(date -u '+%F %T')Z" "$*"; }
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
flag_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi; }
for _f in automerge-disabled lane-off-merge-conductor; do
  flag_on "$_f" && { say "flags/$_f is set — standing down"; exit 0; }
done

ROWS="$H/state/merge-conductor/pr-state.tsv"
CAP="${MC_BACKSTOP_MAX_KEYS:-6}"
[[ "$CAP" =~ ^[0-9]+$ ]] || CAP=6
TO="${MC_BACKSTOP_TIMEOUT_S:-240}"
[[ "$TO" =~ ^[0-9]+$ ]] && [ "$TO" -gt 0 ] || TO=240
CARRY="$H/state/merge-conductor/backstop-carry"
# key state since head reviewed alerted reason url — carried, then own repo,
# then oldest `since` (header: THE ORDER, AND THE CARRY).
CANDS=$(awk -F'\t' -v own="${HARNESS_REPO:-}" -v carry="$({ tr '\n' ' ' < "$CARRY"; } 2>/dev/null)" '
  BEGIN { n = split(carry, cc, " "); for (i = 1; i <= n; i++) if (!(cc[i] in c)) c[cc[i]] = i; own = tolower(own) }
  ($2=="WAIT_CI"||$2=="READY") && $4!="" && $4!="-" && $4==$5 && $1 ~ /^[^#[:space:]]+#[0-9]+$/ {
  s=$3; if (s !~ /^[0-9]+$/) s=0; r = $1; sub(/#.*/, "", r)
  print ($1 in c ? c[$1] : 999999) "\t" (own != "" && tolower(r) == own ? 0 : 1) "\t" s "\t" $1 }' "$ROWS" 2>/dev/null \
  | sort -t$'\t' -k1,1n -k2,2n -k3,3n -k4,4 | cut -f4)
N=$(grep -c . <<<"$CANDS")
[ "$N" -gt 0 ] || { say "0 candidates — nothing to do"; : > "$CARRY" 2>/dev/null; exit 0; }
KEYS="$CANDS"; REST=""
if [ "$CAP" -gt 0 ] && [ "$N" -gt "$CAP" ]; then
  KEYS=$(head -n "$CAP" <<<"$CANDS"); REST=$(tail -n +"$((CAP + 1))" <<<"$CANDS")
  say "$((N - CAP)) deferred (cap MC_BACKSTOP_MAX_KEYS=$CAP) — the next fire takes them first: $(paste -sd, - <<<"$REST")"
fi
# Written before the run, so a fire the timeout kills still hands its remainder on.
{ [ -z "$REST" ] || printf '%s\n' "$REST"; } > "$CARRY.tmp.$$" 2>/dev/null && mv -f "$CARRY.tmp.$$" "$CARRY" 2>/dev/null
KEYS=$(paste -sd, - <<<"$KEYS")
say "$(grep -c . <<<"${KEYS//,/$'\n'}") of $N candidate(s) → keyed conductor run: $KEYS"
# THE WORKER DEADLINE FIRES BEFORE THE TIMEOUT (BH-4918). `timeout` signals the
# run's whole process group, every PR worker in it, so one slow PR used to take
# its healthy siblings and the run's enqueue pass down with it. The keyed run
# gets MC_WORKER_DEADLINE_CAP_S = TO - 45 (never under 30): mc_worker_bounded
# kills a worker past min(its own MC_WORKER_DEADLINE_S, that cap) alone, and the
# 45 s are what the rest of the run needs after the last worker is gone.
WD=$((TO - 45)); [ "$WD" -ge 30 ] || WD=30
say "keyed conductor run: worker deadline capped at ${WD}s under timeout ${TO}s"
DEFER="$CARRY.window.$$"; : > "$DEFER" 2>/dev/null
MC_ONLY_PR="$KEYS" WAKE_LAUNCH=1 MC_WORKER_DEADLINE_CAP_S="$WD" \
  MC_WORKERS_DONE_BY=$(( $(date +%s) + WD )) MC_WINDOW_DEFER_FILE="$DEFER" timeout "$TO" "$H/bin/merge-conductor.sh"
RC=$?
[ "$RC" = 124 ] && say "keyed conductor run hit timeout $TO — killed" || say "keyed conductor run rc=$RC"
# The keys the run had no window for go to the head of the carry, then this
# fire's remainder (header: THE RUN FITS THE WINDOW).
if [ -s "$DEFER" ]; then
  say "$(grep -c . "$DEFER") key(s) had no window left in this run — the next fire takes them first: $(paste -sd, - < "$DEFER")"
  { cat "$DEFER"; [ -z "$REST" ] || printf '%s\n' "$REST"; } 2>/dev/null | awk 'NF && !seen[$0]++' > "$CARRY.tmp.$$" 2>/dev/null \
    && mv -f "$CARRY.tmp.$$" "$CARRY" 2>/dev/null
fi
rm -f "$DEFER" "$CARRY.tmp.$$" 2>/dev/null
exit 0
