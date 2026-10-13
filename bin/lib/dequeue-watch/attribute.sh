#!/bin/bash
# shellcheck shell=bash
# bin/lib/dequeue-watch/attribute.sh — BH-3728 (BH-3719.2): culprit or bystander
# for a PR Mergify dequeued, decided from files and strings the caller already
# read. Sourced, never run.
#
# PURE. No network, no clock, no harness root (D43), no jobs calls: every input
# is a file path or a string, so the dequeue-watch lane (BH-3719) does the reads
# and this file only decides. A read that failed reaches here as a missing or
# unreadable file, and that is `unknown`, never `bystander` (D9/D11): a
# bystander verdict is what lets the lane requeue a PR without a fix, so it is
# only ever printed on positive evidence.
#
#   dqw_parse_payload_md <body>
#       ONE Mergify comment body. rc 1 unless its payload state is `dequeued`.
#       Prints one TSV line `draft run_id left_at_sha checks`; a field the body
#       does not carry is `-` (D26). checks = the "Failing checks:" names, `,`.
#   dqw_batch_members <runs-json-file> <run_id>
#       The `#N`s in that run's title, sorted, one per line. rc 1 when the file
#       is unreadable, the run is absent or its title names no PR.
#   dqw_bisect_word <runs-json-file> <pr> <red_run_id> <members>
#       A later, completed, non-stacked merge-queue run on a strict subset of
#       <members> that holds <pr>: any success → bystander, else any failure →
#       culprit, else rc 1.
#   dqw_diff_touch <pr> <sources-file> <files-dir> [members]
#       <files-dir>/pr-files-<n>.json is the pulls/<n>/files array. This PR
#       touches a source → culprit; this PR's files read and touch none AND
#       another member's files read and touch one → bystander; else rc 1.
#   dqw_attribute <pr> <payload-tsv> <runs-json-file> <sources-file> <files-dir>
#       `word<TAB>how`, first match wins: no run id → unknown/no-run; a batch of
#       one → culprit/batch-of-one (over any later bisect evidence); the bisect
#       word; the diff-touch word; else unknown/undecided.

[ -n "${_DQW_ATTRIBUTE_SH:-}" ] && return 0
_DQW_ATTRIBUTE_SH=1

dqw_parse_payload_md() {
  local body="${1:-}" payload state draft run sha checks
  payload=$(printf '%s\n' "$body" | sed -n '/-\*- Mergify Payload -\*-/,/-\*- Mergify Payload End -\*-/p' | sed '1d;$d')
  [ -n "$payload" ] || return 1
  state=$(printf '%s' "$payload" | jq -r '.state // empty' 2>/dev/null) || return 1
  [ "$state" = dequeued ] || return 1
  draft=$(printf '%s\n' "$body" | grep -oE 'on draft #[0-9]+' | head -1 | grep -oE '[0-9]+$')
  run=$(printf '%s\n' "$body" | grep -oE '/actions/runs/[0-9]+' | head -1 | grep -oE '[0-9]+$')
  sha=$(printf '%s\n' "$body" | grep -E 'Left the queue' | grep -oE 'at `[0-9a-f]{40}`' | head -1 | tr -d '`' | sed 's/^at //')
  checks=$(printf '%s\n' "$body" | awk '
    /^Failing checks:/ { on = 1; next }
    on && /^[[:space:]]*$/ { exit }
    on && /❌ \[`/ { s = $0; sub(/^.*❌ \[`/, "", s); sub(/`\].*$/, "", s); print s }' | paste -sd, -)
  printf '%s\t%s\t%s\t%s\n' "${draft:--}" "${run:--}" "${sha:--}" "${checks:--}"
}

dqw_batch_members() {
  local runs="${1:-}" id="${2:-}" out
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$runs" ] || return 1
  out=$(jq -r --argjson id "$id" '
    [.workflow_runs[]? | select(.id == $id)][0].display_title // ""
    | [scan("#([0-9]+)")[0] | tonumber] | unique[]' "$runs" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

dqw_bisect_word() {
  local runs="${1:-}" pr="${2:-}" red="${3:-}" members="${4:-}" word
  case "$pr$red" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$runs" ] || return 1
  word=$(jq -r --argjson pr "$pr" --argjson red "$red" --arg m "$members" '
    ($m | [scan("[0-9]+") | tonumber] | unique) as $all
    | [.workflow_runs[]?
       | select(.id > $red and .status == "completed"
                and ((.head_branch // "") | startswith("mergify/merge-queue/"))
                and ((.display_title // "") | test("stacked on") | not))
       | {c: .conclusion, m: ((.display_title // "") | [scan("#([0-9]+)")[0] | tonumber] | unique)}
       | select((.m | index($pr)) != null and (.m | length) < ($all | length)
                and (.m - $all | length) == 0)
       | .c] as $cs
    | if ($cs | index("success")) != null then "bystander"
      elif ($cs | index("failure")) != null then "culprit" else "" end' "$runs" 2>/dev/null) || return 1
  [ -n "$word" ] || return 1
  printf '%s\n' "$word"
}

# _dqw_touches <files-json> <sources-file> — rc 0 touches, 1 touches none,
# 2 unreadable.
_dqw_touches() {
  local names
  [ -r "${1:-}" ] || return 2
  names=$(jq -r '.[].filename' "$1" 2>/dev/null) || return 2
  [ -n "$names" ] && grep -qxF -f "$2" <<<"$names" && return 0
  return 1
}

dqw_diff_touch() {
  local pr="${1:-}" src="${2:-}" dir="${3:-}" members="${4:-}" m rc
  [ -n "$pr" ] && [ -n "$dir" ] && [ -s "$src" ] || return 1
  grep -q '[^[:space:]]' "$src" || return 1
  _dqw_touches "$dir/pr-files-$pr.json" "$src"; rc=$?
  [ "$rc" = 0 ] && { echo culprit; return 0; }
  [ "$rc" = 1 ] || return 1
  for m in $members; do
    [ "$m" = "$pr" ] && continue
    _dqw_touches "$dir/pr-files-$m.json" "$src" && { echo bystander; return 0; }
  done
  return 1
}

dqw_attribute() {
  local pr="${1:-}" tsv="${2:-}" runs="${3:-}" src="${4:-}" dir="${5:-}" run members word
  run=$(printf '%s' "$tsv" | cut -f2)
  case "$run" in ''|-|*[!0-9]*) printf 'unknown\tno-run\n'; return 0 ;; esac
  if members=$(dqw_batch_members "$runs" "$run"); then
    if [ "$members" = "$pr" ]; then printf 'culprit\tbatch-of-one\n'; return 0; fi
    if word=$(dqw_bisect_word "$runs" "$pr" "$run" "$members"); then
      printf '%s\tbisect\n' "$word"; return 0
    fi
  else
    members="$pr"
  fi
  if word=$(dqw_diff_touch "$pr" "$src" "$dir" "$members"); then
    printf '%s\tdiff-touch\n' "$word"; return 0
  fi
  printf 'unknown\tundecided\n'
}
