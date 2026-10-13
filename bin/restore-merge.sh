#!/bin/bash
# bin/restore-merge.sh — merge a harness backup snapshot INTO a live tree,
# without ever overwriting live content with older snapshot content.
#
# WHY IT EXISTS. On 2026-09-15 the hub's /root/harness/{env,bin,prompts,logs,
# builds} vanished under a running system (example-org/cromford#388; parent
# #396). The recovery restored a backup over what survived, and the merge policy
# that did it lived only in the operator's shell. The original
# /root/restore-merge.sh is not reachable from any worker box and is in no rescue
# branch, so this is a REIMPLEMENTATION from the policy stated in #446, #396 and
# #388 — whoever can reach the hub should diff the two.
#
# THE CURSOR LESSON, which is the expensive half of that incident. The restored
# logs/ALERTS.log was longer than the live one, and flags/.alerts-cursor — a
# plain byte offset that bin/poll-commands.sh tails from (~line 378) — still
# pointed at an offset inside the OLD content. poll-commands then re-beat every
# historical alert behind it: #388 counts 424 alerts re-sent, and the ticket
# rounds the operator-visible flood to ~1,000. So this script writes the cursor
# to `wc -c` of the merged ALERTS.log, LAST, after the whole walk: a crash
# mid-apply leaves the old cursor and poll-commands re-beats (duplicates over
# silence), and a stale LARGER cursor is overwritten rather than trusted.
# --keep-cursor (#1923) is the one opt-out: bin/state-restore.sh --standby
# merges a tree it has already pruned of logs/, every 15 minutes, into a box
# whose OWN poll-commands owns the cursor. Rewriting it there to `wc -c` would
# skip whatever standby alerts poll-commands had not sent yet.
#
# THE RULES, first match wins, per snapshot file (relative path):
#   1. SAME       live exists and compares equal            -> nothing
#   2. ADD        missing in live                           -> copy, parents, mode
#   3. LEDGER     logs/<n>.{log,csv,jsonl,tsv},             -> snapshot lines, then
#                 builds/<dir>/{pipeline.log,cost.csv}         live lines not already
#                 and live differs                             present (exact-line set)
#   4. UNION      state/merge-conductor/pr-state.tsv        -> every live row, then
#                 and live differs                             snapshot rows whose
#                                                              column-1 key is absent;
#                                                              header (col 1 == "key")
#                                                              kept once, from live
#   5. KEEP-LIVE  everything else that differs              -> live wins, reported
# env/**, state/quota/**, flags/**, state/pr-owners/*.json,
# logs/*.log.gz and every nested near-miss (logs/sub/x.log, builds/a/b/pipeline.log)
# fall to rule 5 by construction: the ledger globs match ONE path segment only.
# meta/** is PRINTED for the operator and never applied — the crontab is shown,
# not installed. orchestrator/** is routed to --orchestrator-live and only ever
# takes rules 1, 2 and 5.
#
# Every file rule 3 or rule 4 replaces is copied to <backup-dir>/<rel> FIRST; a
# failed backup means no rewrite. Rewrites go through a same-directory temp file
# and an atomic mv. Dry run (the default) performs zero writes.
#
# LOCKING: none, deliberately. bin/lib/merge-conductor-lib.sh rewrites
# pr-state.tsv under its own pr-state.tsv.lock; --apply here is an operator
# action taken with the lanes fenced (see the parent's RESTORE.md), not a
# concurrent writer.
#
# PURE LOCAL: no S3, no age, no network, no gh. It reads two trees and writes to
# the live one. Output is PATHS ONLY, never file contents — env/ holds secrets.
#
# Usage:
#   bin/restore-merge.sh --snapshot <dir> --live <dir> [--apply]
#                        [--backup-dir <dir>] [--orchestrator-live <dir>]
#                        [--keep-cursor]
#
#   --snapshot <dir>           the restored backup tree (required, must exist)
#   --live <dir>               the harness tree to merge into (required, must exist)
#   --apply                    actually write; without it nothing is written
#   --backup-dir <dir>         default /root/restore-merge-backup/<YYYYMMDDTHHMMSSZ>
#                              (RESTORE_NOW, epoch seconds, is the tests-only
#                              time override). Created lazily, on the first
#                              replaced file, under --apply only.
#   --orchestrator-live <dir>  default /root/orchestrator
#   --keep-cursor              never write flags/.alerts-cursor (the standby
#                              stream; see THE CURSOR LESSON above)
#
# Exit: 0 when every planned action landed, 1 when any copy or rewrite failed
# (the summary names each one), 2 on a usage error.
set -uo pipefail

SELF=$(basename "$0")

usage() {
  echo "$SELF: usage: $SELF --snapshot <dir> --live <dir> [--apply] [--backup-dir <dir>] [--orchestrator-live <dir>] [--keep-cursor]" >&2
  echo "$SELF:        default is a DRY RUN: one line per snapshot file plus a summary, writes nothing." >&2
  exit 2
}

SNAP=""; LIVE=""; APPLY=0; BACKUP_DIR=""; ORCH_LIVE="/root/orchestrator"; KEEP_CURSOR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot)          [ $# -ge 2 ] || usage; SNAP="$2"; shift 2 ;;
    --live)              [ $# -ge 2 ] || usage; LIVE="$2"; shift 2 ;;
    --backup-dir)        [ $# -ge 2 ] || usage; BACKUP_DIR="$2"; shift 2 ;;
    --orchestrator-live) [ $# -ge 2 ] || usage; ORCH_LIVE="$2"; shift 2 ;;
    --apply)             APPLY=1; shift ;;
    --keep-cursor)       KEEP_CURSOR=1; shift ;;
    -h|--help)           sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *)                   echo "$SELF: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$SNAP" ] && [ -d "$SNAP" ] || { echo "$SELF: --snapshot must name an existing directory" >&2; usage; }
[ -n "$LIVE" ] && [ -d "$LIVE" ] || { echo "$SELF: --live must name an existing directory" >&2; usage; }
SNAP=${SNAP%/}; LIVE=${LIVE%/}; ORCH_LIVE=${ORCH_LIVE%/}

# One timestamp for the whole run, so the default backup dir is a single path.
BK="${BACKUP_DIR:-/root/restore-merge-backup/$(date -u -d "@${RESTORE_NOW:-$(date +%s)}" +%Y%m%dT%H%M%SZ)}"
BK=${BK%/}
BK_USED=0

N_SAME=0; N_ADD=0; N_LEDGER=0; N_UNION=0; N_KEEP=0; N_META=0; N_FAIL=0
FAILED_LIST=()
ALERTS_FAILED=0

note_fail() { # $1 = rel, $2 = why
  N_FAIL=$((N_FAIL + 1))
  FAILED_LIST+=("$1")
  printf 'FAIL %s: %s\n' "$1" "$2"
  case "$1" in logs/ALERTS.log) ALERTS_FAILED=1 ;; esac
}

# Copy the live file we are about to replace into the backup tree. Any failure
# here cancels the rewrite: an unbacked-up overwrite is the one irreversible
# thing this script could do.
backup_live() { # $1 = rel, $2 = live path
  mkdir -p -- "$BK/$(dirname -- "$1")" 2>/dev/null || return 1
  cp -p -- "$2" "$BK/$1" 2>/dev/null || return 1
  BK_USED=1
  return 0
}

# Ledger globs match ONE path segment under logs/ and one build dir under
# builds/. `*` in a case pattern crosses slashes, so the nested shapes are
# refused explicitly first — they are reported KEEP-LIVE, which is reversible.
is_ledger() { # $1 = rel
  case "$1" in
    logs/*/*|builds/*/*/*) return 1 ;;
    logs/*.log|logs/*.csv|logs/*.jsonl|logs/*.tsv) return 0 ;;
    builds/*/pipeline.log|builds/*/cost.csv) return 0 ;;
  esac
  return 1
}

# Snapshot already contained in live as a leading prefix: a re-run over an
# already-merged ledger, and the reason --apply twice is byte-identical.
is_prefix_of() { # $1 = snapshot file, $2 = live file
  local n
  n=$(wc -c < "$1") || return 1
  head -c "$n" -- "$2" 2>/dev/null | cmp -s - "$1"
}

while IFS= read -r -d '' f; do
  rel=${f#"$SNAP/"}

  case "$rel" in
    meta/*)
      printf 'META %s (shown, not applied)\n' "$rel"
      N_META=$((N_META + 1)); continue ;;
    orchestrator/*) dst="$ORCH_LIVE/${rel#orchestrator/}" ;;
    *)              dst="$LIVE/$rel" ;;
  esac

  # 1. SAME
  if [ -f "$dst" ] && cmp -s -- "$f" "$dst"; then
    printf 'SAME %s\n' "$rel"; N_SAME=$((N_SAME + 1)); continue
  fi

  # 2. ADD
  if [ ! -e "$dst" ]; then
    if [ "$APPLY" -eq 1 ]; then
      if mkdir -p -- "$(dirname -- "$dst")" 2>/dev/null && cp -p -- "$f" "$dst" 2>/dev/null; then
        printf 'ADD %s\n' "$rel"; N_ADD=$((N_ADD + 1))
      else
        note_fail "$rel" "copy failed"
      fi
    else
      printf 'ADD %s\n' "$rel"; N_ADD=$((N_ADD + 1))
    fi
    continue
  fi

  # 3. LEDGER (harness tree only; the globs are keyed on harness-tree paths)
  case "$rel" in orchestrator/*) ;; *)
    if is_ledger "$rel"; then
      if is_prefix_of "$f" "$dst"; then
        printf 'SAME %s (snapshot is a prefix of live)\n' "$rel"
        N_SAME=$((N_SAME + 1)); continue
      fi
      if [ "$APPLY" -eq 1 ]; then
        tmp="$dst.restore-merge.tmp"
        if ! backup_live "$rel" "$dst"; then
          note_fail "$rel" "backup failed"; continue
        fi
        if awk 'NR==FNR { seen[$0]=1; print; next } !($0 in seen)' "$f" "$dst" > "$tmp" 2>/dev/null \
           && chmod --reference="$dst" "$tmp" 2>/dev/null \
           && mv -f -- "$tmp" "$dst" 2>/dev/null; then
          printf 'LEDGER %s\n' "$rel"; N_LEDGER=$((N_LEDGER + 1))
        else
          rm -f -- "$tmp"
          note_fail "$rel" "ledger merge failed"
        fi
      else
        printf 'LEDGER %s\n' "$rel"; N_LEDGER=$((N_LEDGER + 1))
      fi
      continue
    fi

    # 4. UNION
    if [ "$rel" = "state/merge-conductor/pr-state.tsv" ]; then
      if [ "$APPLY" -eq 1 ]; then
        tmp="$dst.restore-merge.tmp"
        if ! backup_live "$rel" "$dst"; then
          note_fail "$rel" "backup failed"; continue
        fi
        if awk -F'\t' 'NR==FNR { if (NF) seen[$1]=1; print; next } $1=="key" { next } !($1 in seen)' \
             "$dst" "$f" > "$tmp" 2>/dev/null \
           && chmod --reference="$dst" "$tmp" 2>/dev/null \
           && mv -f -- "$tmp" "$dst" 2>/dev/null; then
          printf 'UNION %s\n' "$rel"; N_UNION=$((N_UNION + 1))
        else
          rm -f -- "$tmp"
          note_fail "$rel" "union merge failed"
        fi
      else
        printf 'UNION %s\n' "$rel"; N_UNION=$((N_UNION + 1))
      fi
      continue
    fi
  ;; esac

  # 5. KEEP-LIVE
  printf 'KEEP-LIVE %s\n' "$rel"; N_KEEP=$((N_KEEP + 1))
done < <(find "$SNAP" -type f -print0 | sort -z)

# The cursor, LAST. Unconditional on --apply whenever live has an ALERTS.log —
# added, merged or untouched — because a cursor left behind old content is what
# re-beat the alert history in #388. The single exception: if the ALERTS.log
# merge itself failed, live is not what we think it is, so the cursor is left
# alone and poll-commands re-beats rather than skipping lines it never sent.
if [ "$APPLY" -eq 1 ] && [ -f "$LIVE/logs/ALERTS.log" ]; then
  if [ "$KEEP_CURSOR" -eq 1 ]; then
    echo 'CURSOR kept: --keep-cursor'
  elif [ "$ALERTS_FAILED" -eq 1 ]; then
    echo 'CURSOR skipped: logs/ALERTS.log merge failed'
  elif N=$(wc -c < "$LIVE/logs/ALERTS.log") \
       && mkdir -p -- "$LIVE/flags" 2>/dev/null \
       && printf '%s\n' "$N" > "$LIVE/flags/.alerts-cursor" 2>/dev/null; then
    printf 'CURSOR flags/.alerts-cursor -> %s\n' "$N"
  else
    note_fail "flags/.alerts-cursor" "cursor write failed"
  fi
fi

if [ "$N_FAIL" -gt 0 ]; then
  for r in "${FAILED_LIST[@]}"; do printf 'FAILED %s\n' "$r"; done
fi

if [ "$APPLY" -eq 1 ]; then
  [ "$BK_USED" -eq 1 ] && BK_SHOWN="$BK" || BK_SHOWN="none"
  MODE=apply
else
  BK_SHOWN="$BK"   # the dir an --apply would use; nothing is created in a dry run
  MODE=dry-run
fi
printf 'SUMMARY mode=%s same=%d add=%d ledger=%d union=%d keep-live=%d meta=%d failed=%d backup=%s\n' \
  "$MODE" "$N_SAME" "$N_ADD" "$N_LEDGER" "$N_UNION" "$N_KEEP" "$N_META" "$N_FAIL" "$BK_SHOWN"

[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
