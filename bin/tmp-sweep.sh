#!/bin/bash
# bin/tmp-sweep.sh [--dry-run] — the /tmp sweep on every box (BH-5007, BH-5608).
# Cron runs it every 15 min, and bin/lib/review-pool.sh's rpool_init runs it at
# the start of each review-prs and lead-review tick, before the pool sizes
# itself from free /tmp.
#
# WHY. On 2026-10-06 box-small's 8 GB /tmp filled inside hours with
# suite and prototype leftovers (pb*-proto, bh*-rp, scratch.*, impact-gate.*,
# ...) and every lane on the box failed with ENOSPC. bin/box-housekeeping.sh
# sweeps /tmp once a day at a 2-day age, which cannot keep up with that, and it
# cannot remove a tree holding a chattr +a/+i file. A hand-made stopgap
# (/etc/cron.d/tmp-sweep) carried the box until this lane existed. On
# 2026-10-08 nine builder and reviewer checkouts (rv*, wt*, r<N>, bh<N>-*, up
# to 470 MB each) that no pattern matched cut review-prs to 1 worker for 2 h
# (BH-5608). On 2026-10-11 a 2-day-old /tmp/bh5775 (1.1 GB, no dash after the
# number) and pr<N> checkouts held lead-review at 1 worker for hours (BH-6041).
#
# WHAT. One pass over the TOP LEVEL of /tmp. An entry is removed only when ALL
# of these hold:
#   - its basename matches one of TMP_SWEEP_PATTERNS (the deletion scope:
#     the suite and prototype leftovers, plus the builder and reviewer
#     checkouts rv*, wt*, r[0-9]*, bh[0-9]*, pr[0-9]*, pb*-*, lanes-build.*,
#     review-prs-*, a lead-review worker's own lr[0-9]* dir and a
#     rules-pack-snap.* snapshot a killed worker left);
#   - it is not a symlink, socket or FIFO, and sits on the same mount as /tmp;
#   - its NEWEST mtime anywhere inside is older than MIN_AGE_MIN minutes
#     (default 180), read within TMP_SWEEP_SCAN_TIMEOUT_S, else it is kept;
#   - no live process has its cwd, an open fd, or an argv argument under it;
#   - no line of a live job claim (state/claims/<project>/<KEY>) names a path
#     under it.
# When `rm -rf` leaves the entry behind, the sweep clears chattr +i/+a inside it
# (`chattr -R -ia`) and tries once more. Every count moves only after
# `[ ! -e ]` proved the removal, and the KB is measured before it. The whole
# run stops at TMP_SWEEP_RUN_DEADLINE_S and counts what it left (left=).
# It never touches /tmp itself, anything below the top level that is not part
# of a removed entry, or anything across a mount. Each removal logs
# `removed <path> <kb> KB age_min=<n>`.
#
# WORKTREES. A removed entry whose .git file points into <repo>/worktrees/ was
# a git worktree; after the loop `git worktree prune` runs once in each such
# repo (logged `pruned worktrees in <dir>`, or `worktree prune failed`).
#
# After the sweep: one summary line in logs/tmp-sweep.log with the /tmp Use%
# and free MB, the box-health ledger row (kind box_health, key
# `tmp-sweep <host>`, detail freed_bytes, removed, failed and the df reading)
# through bin/jobs-client.sh, and a warn (the batched digest, not a page) through
# bin/lane-alert.sh as tmp-high-<host> when /tmp is still over TMP_ALERT_PCT
# (default 85); resolved when it drops back. An unreadable df is unknown: no
# warn and no resolve.
#
# STOPGAP RETIREMENT. After a real sweep, /etc/cron.d/tmp-sweep is removed when
# its only non-comment line is the BH-5007 stopgap line; any other content is
# left alone and logged once.
#
# --dry-run prints `would remove <path> (<kb> KB)`, deletes nothing, prunes
# nothing, writes no ledger row, alerts nothing and retires nothing. A sweep problem is a log line: exit is 0 after
# the gate (2 on a usage error).
#
# Off: flags/lane-off-tmp-sweep. Knobs: catalog/lanes.d/tmp-sweep.json
# (bin/harness-ctl.sh set tmp-sweep MIN_AGE_MIN <n>, or the settings page).
# Test seams (every default is the live path, none settable from a page):
# HARNESS_ROOT, TMP_SWEEP_ROOT, TMP_SWEEP_PROC, TMP_SWEEP_NOW,
# TMP_SWEEP_STOPGAP_FILE, TMP_SWEEP_CLAIMS. Under HARNESS_TEST_SANDBOX=1 with no
# TMP_SWEEP_ROOT the sweep is skipped, so a suite never sweeps the real /tmp.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage: bin/tmp-sweep.sh [--dry-run]" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")
# Same gate and knob order as bin/box-housekeeping.sh: rows, then
# env/global.env, then the rows again so the box's env file cannot shadow a
# settings row.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit tmp-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    tmp-sweep
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    tmp-sweep

ROOT="${TMP_SWEEP_ROOT:-/tmp}"
PROC="${TMP_SWEEP_PROC:-/proc}"
NOW_S="${TMP_SWEEP_NOW:-$(date +%s)}"
STOPGAP="${TMP_SWEEP_STOPGAP_FILE:-/etc/cron.d/tmp-sweep}"
PATTERNS="${TMP_SWEEP_PATTERNS:-pb*-proto pb*-sg bh*-proto bh*-rp scratch.* impact-gate.* rules-pack.* rv* wt* r[0-9]* bh[0-9]* pr[0-9]* lr[0-9]* rules-pack-snap.* pb*-* lanes-build.* review-prs-*}"
CLAIMS="${TMP_SWEEP_CLAIMS:-$H/state/claims}"
HOST=$(hostname)

mkdir -p "$H/logs" "$H/locks" "$H/state/tmp-sweep" 2>/dev/null
LOG="$H/logs/tmp-sweep.log"
# Dedupe, never a queue: a run still going owns this slot.
exec 9>"$H/locks/tmp-sweep.lock" || exit 0
flock -n 9 || exit 0

NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
say() { printf '%s %s\n' "$NOW" "$*" >> "$LOG"; }
MODE=""; [ "$DRY" = 1 ] && MODE=": dry-run"

# int_knob <value> <min> [max] — the value as a number, rc 1 when it is not a
# whole number inside the bounds. These numbers gate deletion or an alert, so a
# guessed one is never used.
int_knob() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -ge "$2" ] || return 1
  [ -z "${3:-}" ] || [ "$((10#$1))" -le "$3" ] || return 1
  printf '%s' "$((10#$1))"
}

kb_of() { # kb_of <path> — KB on this filesystem, empty when unreadable
  local k
  k=$(du -skx -- "$1" 2>/dev/null | cut -f1)
  case "$k" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

# held_set <tmpreal> <root> — every path under <tmpreal> a live process names:
# its cwd, an open fd, or an argv argument (anywhere in the argument, so
# --dir=/tmp/x counts; a path spelled through <root> is rewritten onto
# <tmpreal>). One line each, sorted unique, with whatever followed the path in
# its argument still attached: is_held matches by prefix, so a tail like
# `:/tmp/y` or ` (deleted)` can only make MORE held. Matching is literal string
# work, never a regex built from the path. An unreadable /proc entry (a race,
# another user) is skipped.
held_set() {
  local real="$1" root="$2" p arg rest pre pres line args
  pres=("$real"); [ "$root" != "$real" ] && pres+=("$root")
  {
    find "$PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%l\n' 2>/dev/null
    find "$PROC"/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null
    for p in "$PROC"/[0-9]*/cmdline; do
      [ -r "$p" ] || continue
      # One mapfile, never a `read` loop: a process that exits mid-read makes
      # every further read fail with the last argument still set, and a loop
      # that also continues on a non-empty partial read spins forever.
      args=()
      mapfile -d '' -t args 2>/dev/null < "$p" || continue
      for arg in "${args[@]}"; do
        for pre in "${pres[@]}"; do
          rest="$arg"
          while [[ $rest == *"$pre/"* ]]; do
            rest="${rest#*"$pre/"}"
            [ -n "$rest" ] && printf '%s/%s\n' "$real" "$rest"
          done
        done
      done
    done
  } | while IFS= read -r line; do
    case "$line" in "$real"/?*) printf '%s\n' "$line" ;; esac
  done | sort -u
}

# claim_set <tmpreal> <root> — every path under <tmpreal> a line of a live job
# claim names (<claims>/<project>/<KEY>, one path a line; a path spelled
# through <root> is rewritten onto <tmpreal>). Literal prefix work, as in
# held_set. A missing or unreadable claims dir adds nothing.
claim_set() {
  local real="$1" root="$2" f line
  for f in "$CLAIMS"/*/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$real"/?*) printf '%s\n' "$line" ;;
        "$root"/?*) printf '%s/%s\n' "$real" "${line#"$root"/}" ;;
      esac
    done < "$f"
  done
}

# is_held <entry> <held set>
is_held() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    # the entry itself, below it, or the entry followed by something that cannot
    # continue a file name (` (deleted)`, `:`, `,`): scratch.ABC is not held by
    # scratch.ABCdef
    case "$c" in "$1"|"$1"/*|"$1"[!A-Za-z0-9._-]*) return 0 ;; esac
  done <<< "$2"
  return 1
}

removed=0; freed=0; WTDIRS=(); held_n=0; fresh=0; unread=0; unlocked=0; failed=0; would=0; left=0
SWEPT=0; SKIP_WHY=""
TMPREAL=$(cd -P -- "$ROOT" 2>/dev/null && pwd)
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -z "${TMP_SWEEP_ROOT:-}" ]; then
  SKIP_WHY="TMP_SWEEP_ROOT unset under HARNESS_TEST_SANDBOX - sweep skipped"
elif ! MIN_AGE=$(int_knob "${MIN_AGE_MIN:-180}" 30); then
  SKIP_WHY="MIN_AGE_MIN invalid (${MIN_AGE_MIN:-}) - sweep skipped"
elif ! SCAN_T=$(int_knob "${TMP_SWEEP_SCAN_TIMEOUT_S:-60}" 5); then
  SKIP_WHY="TMP_SWEEP_SCAN_TIMEOUT_S invalid (${TMP_SWEEP_SCAN_TIMEOUT_S:-}) - sweep skipped"
elif ! DEADLINE=$(int_knob "${TMP_SWEEP_RUN_DEADLINE_S:-900}" 30); then
  SKIP_WHY="TMP_SWEEP_RUN_DEADLINE_S invalid (${TMP_SWEEP_RUN_DEADLINE_S:-}) - sweep skipped"
elif [ -z "$TMPREAL" ] || [ "$TMPREAL" = / ]; then
  SKIP_WHY="tmp root $ROOT unreadable or / - sweep skipped"
fi

if [ -n "$SKIP_WHY" ]; then
  say "tmp-sweep$MODE $SKIP_WHY"
else
  SWEPT=1
  CUT=$((NOW_S - MIN_AGE * 60))
  # The mount point, not st_dev: on overlayfs a file and its own directory
  # report different st_dev (bin/box-housekeeping.sh learned this).
  TMPMNT=$(stat -c %m -- "$TMPREAL" 2>/dev/null)
  HELD=$(held_set "$TMPREAL" "$ROOT"; claim_set "$TMPREAL" "$ROOT")
  START=$SECONDS
  while IFS= read -r -d '' e; do
    if [ $((SECONDS - START)) -ge "$DEADLINE" ]; then left=$((left + 1)); continue; fi
    case "$e" in "$TMPREAL"/?*) ;; *) continue ;; esac
    base="${e##*/}"
    case "$base" in .|..|*/*) continue ;; esac
    match=0
    set -f
    for g in $PATTERNS; do
      # shellcheck disable=SC2254
      case "$base" in $g) match=1; break ;; esac
    done
    set +f
    [ "$match" = 1 ] || continue
    [ -L "$e" ] && continue
    [ -S "$e" ] || [ -p "$e" ] && continue
    [ -e "$e" ] || continue
    [ "$(stat -c %m -- "$e" 2>/dev/null)" = "$TMPMNT" ] || continue
    newest=$(timeout "$SCAN_T" find -P "$e" -xdev -printf '%T@\n' 2>/dev/null \
             | awk -F. '{ n = $1 + 0; if (!seen || n > m) { m = n; seen = 1 } } END { if (seen) print m }'
             exit "${PIPESTATUS[0]}")
    rc=$?
    case "$rc:$newest" in 0:[0-9]*) ;; *) unread=$((unread + 1)); continue ;; esac
    [ "$newest" -lt "$CUT" ] || { fresh=$((fresh + 1)); continue; }
    is_held "$e" "$HELD" && { held_n=$((held_n + 1)); continue; }
    kb=$(kb_of "$e") || kb=0
    if [ "$DRY" = 1 ]; then
      echo "would remove $e ($kb KB)"; would=$((would + 1)); continue
    fi
    # a git worktree's .git is a file: `gitdir: <repo>/worktrees/<name>`
    wtcommon=""
    if [ -f "$e/.git" ] && [ ! -L "$e/.git" ]; then
      IFS= read -r gd < "$e/.git" 2>/dev/null || gd=""
      case "$gd" in "gitdir: "*/worktrees/*) gd="${gd#gitdir: }"; wtcommon="${gd%/worktrees/*}" ;; esac
    fi
    rm -rf --one-file-system -- "$e" 2>/dev/null
    if [ -e "$e" ] && command -v chattr >/dev/null 2>&1; then
      chattr -R -ia -- "$e" 2>/dev/null && unlocked=$((unlocked + 1))
      rm -rf --one-file-system -- "$e" 2>/dev/null
    fi
    if [ ! -e "$e" ] && [ ! -L "$e" ]; then
      removed=$((removed + 1)); freed=$((freed + kb))
      say "removed $e $kb KB age_min=$(( (NOW_S - newest) / 60 ))"
      [ -n "$wtcommon" ] && WTDIRS+=("$wtcommon")
    else
      failed=$((failed + 1))
      say "kept: $e could not be removed"
    fi
  done < <(find "$TMPREAL" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  # Prune each repo that owned a removed worktree, once. A failure is a log
  # line and never changes the exit code.
  if [ "${#WTDIRS[@]}" -gt 0 ]; then
    while IFS= read -r gcd; do
      [ -d "$gcd" ] || continue
      timeout 60 git --git-dir="$gcd" worktree prune >/dev/null 2>&1; rc=$?
      if [ "$rc" = 0 ]; then say "pruned worktrees in $gcd"; else say "worktree prune failed in $gcd rc=$rc"; fi
    done < <(printf '%s\n' "${WTDIRS[@]}" | sort -u)
  fi
fi

# shellcheck disable=SC1091
. "$H/bin/lib/disk-guard.sh" 2>/dev/null
DF_AT="${TMPREAL:-$ROOT}"
PCT=""; AVAIL=""
if command -v disk_used_pct >/dev/null 2>&1; then
  PCT=$(disk_used_pct "$DF_AT"); AVAIL=$(disk_free_mb "$DF_AT")
fi
if [ "$SWEPT" = 1 ]; then
  say "tmp-sweep$MODE removed=$removed freed_kb=$freed skipped_held=$held_n skipped_fresh=$fresh skipped_unreadable=$unread unlocked=$unlocked failed=$failed would_remove=$would left=$left min_age_min=$MIN_AGE tmp_use=${PCT:-unknown}% tmp_avail_mb=${AVAIL:-unknown}"
fi

# ── the box-health row ───────────────────────────────────────────────────────
# Every real sweep writes it, also with nothing removed: the row says the sweep
# is alive, and a 0 there is a measured 0. A failed write is a log line.
if [ "$DRY" = 0 ] && [ "$SWEPT" = 1 ]; then
  if [ -r "$H/bin/jobs-client.sh" ]; then
    HARNESS="$H"
    # shellcheck disable=SC1091
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  if command -v job_ledger_put >/dev/null 2>&1; then
    detail=$(jq -nc --argjson fb "$((freed * 1024))" --argjson r "$removed" --argjson f "$failed" \
      --arg p "$PCT" --arg a "$AVAIL" --arg at "$NOW" \
      '{freed_bytes:$fb, removed:$r, failed:$f,
        tmp_use_pct:($p|if test("^[0-9]+$") then tonumber else null end),
        tmp_avail_mb:($a|if test("^[0-9]+$") then tonumber else null end), at:$at}' 2>/dev/null)
    if [ -z "$detail" ]; then
      say "box-health row not written (no jq)"
    else
      job_ledger_put box_health "tmp-sweep $HOST" ok "$detail" >/dev/null 2>&1; rc=$?
      [ "$rc" = 0 ] || say "box-health row not written (rc=$rc)"
    fi
  else
    say "box-health row not written (no jobs client)"
  fi
fi

# ── the /tmp warn ────────────────────────────────────────────────────────────
if [ "$DRY" = 0 ] && [ -n "$PCT" ]; then
  if ! ALERT_PCT=$(int_knob "${TMP_ALERT_PCT:-85}" 50 99); then
    say "TMP_ALERT_PCT invalid (${TMP_ALERT_PCT:-}) - using 85"; ALERT_PCT=85
  fi
  LA="$H/bin/lane-alert.sh"
  if [ "$PCT" -gt "$ALERT_PCT" ]; then
    if [ "$SWEPT" = 1 ]; then
      WHAT="The sweep removed $removed dirs ($((freed / 1024)) MB). What is left is held or younger than $MIN_AGE min: see logs/tmp-sweep.log."
    else
      WHAT="The sweep did not run: $SKIP_WHY. See logs/tmp-sweep.log."
    fi
    "$LA" --id "tmp-high-$HOST" --severity warn tmp-sweep \
      "/tmp on $HOST at $PCT% after the sweep (${AVAIL:-?} MB free, warn over $ALERT_PCT%). $WHAT" >/dev/null 2>&1 || true
  else
    "$LA" --resolve --id "tmp-high-$HOST" tmp-sweep \
      "/tmp on $HOST back to $PCT% (warn over $ALERT_PCT%)." >/dev/null 2>&1 || true
  fi
fi

# ── stopgap retirement ───────────────────────────────────────────────────────
MARK="$H/state/tmp-sweep/stopgap-mismatch-logged"
if [ "$DRY" = 0 ] && [ "$SWEPT" = 1 ]; then
  if [ -f "$STOPGAP" ] && [ ! -L "$STOPGAP" ]; then
    body=$(grep -vE '^[[:space:]]*(#|$)' -- "$STOPGAP" 2>/dev/null)
    if [ -n "$body" ] && [ "$(printf '%s\n' "$body" | wc -l)" = 1 ] \
       && [[ $body =~ ^[0-9]+\ \*\ \*\ \*\ \*\ root\ /root/bhfix-lane/tmp-sweep\.sh(\ [0-9]+)?(\ .*)?$ ]]; then
      rm -f -- "$STOPGAP" 2>/dev/null
      if [ ! -e "$STOPGAP" ]; then
        say "retired stopgap $STOPGAP (repo lane tmp-sweep now owns this)"
      else
        say "stopgap $STOPGAP could not be removed"
      fi
    elif [ ! -e "$MARK" ]; then
      say "stopgap $STOPGAP not retired: content is not the BH-5007 stopgap"
      : > "$MARK" 2>/dev/null
    fi
  elif [ -L "$STOPGAP" ] && [ ! -e "$MARK" ]; then
    say "stopgap $STOPGAP not retired: it is a symlink"
    : > "$MARK" 2>/dev/null
  fi
fi
exit 0
