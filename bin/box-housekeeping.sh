#!/bin/bash
# bin/box-housekeeping.sh [--dry-run] — the box housekeeping BH-4440 added to
# the daily disk-clean lane (bin/disk-clean.sh runs it as its stage 9, 04:47Z).
#
# Two sweeps, each one summary line in logs/disk-clean.log:
#   A. agent session ledgers: regular files under ~/.grok/sessions and
#      ~/.codex/sessions older than AGENT_SESSION_KEEP_DAYS days (default 7),
#      then the directories that left empty, never the sessions root itself.
#      bin/grok-usage.sh and bin/codex-usage.sh only read files newer than the
#      call in flight, so a week-old ledger is nobody's input.
#   B. /tmp top level: an entry whose NEWEST mtime anywhere inside it is older
#      than TMP_TOPLEVEL_STALE_D days (default 2). KEPT at any age: a basename
#      matching TMP_SWEEP_KEEP_GLOBS (dot-entries, systemd-private-*, tmux-*,
#      worktrees, repos, builds, ...), a socket or FIFO, a mount point, a git
#      worktree, anything a /proc/<pid>/fd or /proc/<pid>/cwd points into (no
#      lsof or fuser on these boxes), and anything whose age could not be read
#      inside TMP_AGE_SCAN_TIMEOUT_S. The sweep stops at TMP_SWEEP_DEADLINE_S and
#      says how many entries it left for tomorrow.
# A knob that is not a whole number at or over its minimum skips its sweep with
# a log line: these numbers gate deletion, so a guessed one is never used.
# Every count is bumped only after `[ ! -e ]` proved the removal, and the KB is
# measured before it. --dry-run prints `would remove <path> (<kb> KB)` and
# deletes nothing. It reaches nothing outside the two sessions roots and the
# top level of /tmp: never ~/.claude, /root/repos, /root/worktrees, builds/.
#
# Off: flags/lane-off-disk-clean (this is that lane's work). Knobs are
# disk-clean rows (catalog/lanes.d/disk-clean.json).
# Test seams (every default is the live path): HARNESS_ROOT, BOX_HK_HOME,
# BOX_HK_TMP, BOX_HK_PROC, BOX_HK_NOW.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
HK_HOME="${BOX_HK_HOME:-${HOME:-/root}}"
TMPROOT="${BOX_HK_TMP:-/tmp}"
PROC="${BOX_HK_PROC:-/proc}"
NOW_S="${BOX_HK_NOW:-$(date +%s)}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage: bin/box-housekeeping.sh [--dry-run]" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")
# Same lane gate and knob order as bin/disk-clean.sh: rows, then env/global.env,
# then the rows again so the box's env file cannot shadow a settings row.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit disk-clean
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean

LOG="$H/logs/disk-clean.log"
NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
mkdir -p "$H/logs" 2>/dev/null
say() { printf '%s [box-housekeeping] %s\n' "$NOW" "$*" >> "$LOG"; }
MODE=""; [ "$DRY" = 1 ] && MODE=" dry-run"

# int_knob <name> <value> <min> — the value as a number, rc 1 when it is not a
# whole number at or over min.
int_knob() {
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$2))" -ge "$3" ] || return 1
  printf '%s' "$((10#$2))"
}

kb_of() { # kb_of <path> — KB on this filesystem, empty when unreadable
  local k
  k=$(du -skx -- "$1" 2>/dev/null | cut -f1)
  case "$k" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

# ── A. agent session ledgers ─────────────────────────────────────────────────
s_files=0; s_dirs=0; s_kb=0; s_failed=0; s_would=0; s_absent=""
if ! KEEP_D=$(int_knob AGENT_SESSION_KEEP_DAYS "${AGENT_SESSION_KEEP_DAYS:-7}" 1); then
  say "AGENT_SESSION_KEEP_DAYS invalid (${AGENT_SESSION_KEEP_DAYS:-}) - session sweep skipped"
else
  SCUT=$((NOW_S - KEEP_D * 86400))
  for root in "$HK_HOME/.grok/sessions" "$HK_HOME/.codex/sessions"; do
    label="${root#"$HK_HOME"/}"
    if [ -L "$root" ]; then say "$label is a symlink - refused, not followed"; continue; fi
    [ -d "$root" ] || { s_absent="$s_absent $label"; continue; }
    declare -A EMPTIED=()
    while IFS= read -r -d '' rec; do
      mt="${rec%%.*}"; f="${rec#*$'\t'}"
      case "$mt" in ''|*[!0-9]*) continue ;; esac
      [ "$mt" -lt "$SCUT" ] || continue
      case "$f" in "$root"/?*) ;; *) continue ;; esac
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      kb=$(kb_of "$f") || kb=0
      if [ "$DRY" = 1 ]; then
        echo "would remove $f ($kb KB)"; s_would=$((s_would + 1)); continue
      fi
      rm -f -- "$f" 2>/dev/null
      if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        s_files=$((s_files + 1)); s_kb=$((s_kb + kb)); EMPTIED["${f%/*}"]=1
      else
        say "kept: $f could not be removed"; s_failed=$((s_failed + 1))
      fi
    done < <(find "$root" -mindepth 1 -type f -printf '%T@\t%p\0' 2>/dev/null)
    # Deepest first, so a parent is judged after its children. A dir goes when
    # this run emptied it or it was already empty past the cutoff; a fresh
    # empty dir is a writer's, and rmdir refuses one a writer just filled.
    while IFS= read -r -d '' rec; do
      mt="${rec%%.*}"; d="${rec#*$'\t'}"
      case "$d" in "$root"/?*) ;; *) continue ;; esac
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      case "$mt" in ''|*[!0-9]*) mt="$NOW_S" ;; esac
      [ -n "${EMPTIED[$d]:-}" ] || [ "$mt" -lt "$SCUT" ] || continue
      [ -z "$(find "$d" -mindepth 1 -print -quit 2>/dev/null)" ] || continue
      if [ "$DRY" = 1 ]; then
        echo "would remove $d (0 KB)"; s_would=$((s_would + 1)); continue
      fi
      if rmdir -- "$d" 2>/dev/null && [ ! -e "$d" ]; then
        s_dirs=$((s_dirs + 1)); EMPTIED["${d%/*}"]=1
      fi
    done < <(find "$root" -mindepth 1 -depth -type d -printf '%T@\t%p\0' 2>/dev/null)
    unset EMPTIED
  done
  say "box-housekeeping:$MODE sessions removed_files=$s_files removed_dirs=$s_dirs freed_kb=$s_kb failed=$s_failed would_remove=$s_would keep_days=$KEEP_D${s_absent:+ absent:$s_absent}"
fi

# ── B. /tmp top level ────────────────────────────────────────────────────────
t_removed=0; t_kb=0; t_held=0; t_unread=0; t_failed=0; t_would=0; t_left=0
TMPREAL=$(cd -P -- "$TMPROOT" 2>/dev/null && pwd)
if ! STALE_D=$(int_knob TMP_TOPLEVEL_STALE_D "${TMP_TOPLEVEL_STALE_D:-2}" 1); then
  say "TMP_TOPLEVEL_STALE_D invalid (${TMP_TOPLEVEL_STALE_D:-}) - tmp sweep skipped"
elif ! SCAN_T=$(int_knob TMP_AGE_SCAN_TIMEOUT_S "${TMP_AGE_SCAN_TIMEOUT_S:-60}" 5); then
  say "TMP_AGE_SCAN_TIMEOUT_S invalid (${TMP_AGE_SCAN_TIMEOUT_S:-}) - tmp sweep skipped"
elif ! DEADLINE=$(int_knob TMP_SWEEP_DEADLINE_S "${TMP_SWEEP_DEADLINE_S:-600}" 30); then
  say "TMP_SWEEP_DEADLINE_S invalid (${TMP_SWEEP_DEADLINE_S:-}) - tmp sweep skipped"
elif [ -z "$TMPREAL" ] || [ "$TMPREAL" = / ]; then
  say "tmp root $TMPROOT unreadable or / - tmp sweep skipped"
else
  TCUT=$((NOW_S - STALE_D * 86400))
  KEEP_GLOBS="${TMP_SWEEP_KEEP_GLOBS:-.* systemd-private-* snap-private-tmp tmux-* worktrees repos builds}"
  # The mount point, not st_dev: on overlayfs a file and its own directory
  # report different st_dev, which read every top-level file as a mount.
  TMPMNT=$(stat -c %m -- "$TMPREAL" 2>/dev/null)
  # One pass over /proc: every open fd target and every cwd.
  HELD=$( { find "$PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%l\n' 2>/dev/null
            find "$PROC"/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null; } | sort -u)
  START=$SECONDS
  while IFS= read -r -d '' e; do
    if [ $((SECONDS - START)) -ge "$DEADLINE" ]; then t_left=$((t_left + 1)); continue; fi
    case "$e" in "$TMPREAL"/?*) ;; *) continue ;; esac
    base="${e##*/}"
    case "$base" in .|..|*/*) continue ;; esac
    keep=0
    set -f
    for g in $KEEP_GLOBS; do
      # shellcheck disable=SC2254
      case "$base" in $g) keep=1; break ;; esac
    done
    set +f
    [ "$keep" = 1 ] && continue
    [ -S "$e" ] || [ -p "$e" ] && continue
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$(stat -c %m -- "$e" 2>/dev/null)" = "$TMPMNT" ] || continue
    [ ! -L "$e" ] && [ -e "$e/.git" ] && continue
    newest=$(timeout "$SCAN_T" find -P "$e" -xdev -printf '%T@\n' 2>/dev/null \
             | awk -F. '{ n = $1 + 0; if (!seen || n > m) { m = n; seen = 1 } } END { if (seen) print m }'
             exit "${PIPESTATUS[0]}")
    rc=$?
    case "$rc:$newest" in 0:[0-9]*) ;; *) t_unread=$((t_unread + 1)); continue ;; esac
    [ "$newest" -lt "$TCUT" ] || continue
    held=0
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      case "$c" in "$e"|"$e"/*|"$e (deleted)") held=1; break ;; esac
    done <<< "$HELD"
    [ "$held" = 1 ] && { t_held=$((t_held + 1)); continue; }
    kb=$(kb_of "$e") || kb=0
    if [ "$DRY" = 1 ]; then
      echo "would remove $e ($kb KB)"; t_would=$((t_would + 1)); continue
    fi
    rm -rf --one-file-system -- "$e" 2>/dev/null
    if [ ! -e "$e" ] && [ ! -L "$e" ]; then
      t_removed=$((t_removed + 1)); t_kb=$((t_kb + kb))
    else
      say "kept: $e could not be removed"; t_failed=$((t_failed + 1))
    fi
  done < <(find "$TMPREAL" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [ "$t_left" -gt 0 ] && say "tmp sweep hit TMP_SWEEP_DEADLINE_S=${DEADLINE}s - $t_left entries left for the next run"
  say "box-housekeeping:$MODE tmp removed=$t_removed freed_kb=$t_kb skipped_held=$t_held skipped_unreadable=$t_unread failed=$t_failed would_remove=$t_would left=$t_left stale_days=$STALE_D"
fi
exit 0
