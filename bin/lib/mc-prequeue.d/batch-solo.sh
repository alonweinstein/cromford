#!/bin/bash
# bin/lib/mc-prequeue.d/batch-solo.sh — A FAILED MERGIFY BATCH IS RE-RUN ONE
# MEMBER AT A TIME (BH-4550, #4545 child 4). Sourced by bin/lib/mc-prequeue.sh's
# hook loop, never executed.
#
# bs_batch <slug> <draft> prints one line per member of Mergify's batch draft:
#   <num> <head> reproduces|clean|could-not-run|pending
# and sets BS_SUITES (the draft's failing suites, comma-joined) and BS_BASE (the
# draft's base, 40 hex). Each member's head is merged ALONE onto that base and
# only those suites run, on the CI pool: pq_dispatch of prequeue-gate.yml with
# suites=S. No output means no solo run, and #4428's rule decides as before.
#
# No solo run when: MC_BATCH_SOLO=0; no prequeue-gate.yml in the repo; the
# draft is stacked or held one PR; it held more than MC_BATCH_SOLO_MAX_MEMBERS
# PRs (one log line); its failed runs' logs cannot be read in full; or any
# failing name is not a `tests/(mc/)?X.sh` path (a job: name, a test title).
# A partial suite list never runs. Observe mode (MERGES != 1) reads entries
# already on disk and dispatches nothing.
#
# THE WITNESS RULE. A red base fails for every member, so a member reproduces
# only once every member has a verdict and at least one of them is clean.
# Before that a red prints pending; with no clean witness it prints
# could-not-run.
#
# State. A member's verdict is the tracer's store, keyed
# pq_key <slug> <num> <head> <base40> <fp>, fp = the first 12 hex of the sha1
# of S (sorted, one per line): never the plain gate's key. The draft's facts are
# one line in $MC_STATE_DIR/prequeue/batchsolo_<owner_repo>_<draft>, either
# `ok <base40> <suites,> <members...>` or `skip <reason>`; a failed read is not
# written, and the next call asks again. Both are a memo of CI work: losing one
# costs a read or a run, never a park. A `<file>.log` next to either marks its
# one log line.
#
# The plain gate titles its runs the same way (pq_run_title). Its entry for a
# (PR, head, base) is terminal before that PR is ever enqueued, so it is never
# read again, and pq_read_run takes the newest run of a title: a solo run
# dispatched later reads its own.

BS_SUITE_RE='^tests/(mc/)?[A-Za-z0-9._-]+\.sh$'
BS_SUITES=""; BS_BASE=""

# _bs_log_once <marker> <text> — one log line per marker. The conductor's PR
#   workers run concurrently and can both miss the per-tick memo; the marker is
#   created with noclobber, so only one of them says it.
_bs_log_once() { ( set -C; : > "$1" ) 2>/dev/null && mc_log "$2"; return 0; }

# _bs_skip <file> <reason> — the draft's permanent no.
_bs_skip() { _bs_f="skip $2"; printf '%s\n' "$_bs_f" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null; return 0; }

# _bs_facts <slug> <draft> — sets _bs_f to the draft's facts line (cached, or
#   read and cached). rc 1 when a read failed: nothing is cached.
_bs_facts() {
  local slug="$1" d="$2" f raw t st m base7 stacked dh base40 ids id names all="" tag name job=0 other=0 n max
  f="$MC_STATE_DIR/prequeue/batchsolo_${slug//\//_}_$d"
  _bs_f=$(head -n1 "$f" 2>/dev/null)
  case "$_bs_f" in "ok "*|"skip "*) return 0 ;; esac
  _bs_f=""
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  mc_rest_var raw gh_rest GET "repos/$slug/pulls/$d" || return 1
  t=$(jq -r '.title // empty' <<<"$raw" 2>/dev/null); dh=$(jq -r '.head.sha // empty' <<<"$raw" 2>/dev/null)
  st=$(bej_draft_members "$t") || { _bs_skip "$f" not-a-draft; return 0; }
  IFS=$'\t' read -r m base7 _ stacked <<<"$st"
  [ "$stacked" = 1 ] && { _bs_skip "$f" stacked; return 0; }
  n=$(wc -w <<<"$m" | tr -d ' ')
  [ "$n" -ge 2 ] || { _bs_skip "$f" single; return 0; }
  max=$(pq_knob MC_BATCH_SOLO_MAX_MEMBERS)
  if [ "$n" -gt "$max" ]; then
    _bs_log_once "$f.log" "BATCH_SOLO_SKIP $slug draft #$d: $n members > $max, no solo run"
    _bs_skip "$f" too-many; return 0
  fi
  [[ "$dh" =~ ^[0-9a-f]{40}$ ]] || return 1
  mc_rest_var raw gh_rest GET "repos/$slug/commits/$base7" || return 1
  base40=$(jq -r '.sha // empty' <<<"$raw" 2>/dev/null | tr 'A-F' 'a-f')
  [[ "$base40" =~ ^[0-9a-f]{40}$ ]] && [ "${base40:0:${#base7}}" = "$base7" ] || return 1
  mc_rest_var raw gh_rest GET "repos/$slug/actions/runs?head_sha=$dh&per_page=100" || return 1
  ids=$(jq -r 'if (.total_count // 0) > (.workflow_runs | length) then error("partial") else
    .workflow_runs[] | select((.head_branch // "") | startswith("mergify/merge-queue/")) | select(.conclusion == "failure") | .id end' \
    <<<"$raw" 2>/dev/null) || return 1
  [ -n "$ids" ] || { _bs_skip "$f" no-failed-run; return 0; }
  command -v flaky_run_tests_strict >/dev/null 2>&1 || return 1
  for id in $ids; do
    names=$(flaky_run_tests_strict "$slug" "$id" 2>/dev/null) && [ -n "$names" ] || { _bs_skip "$f" log-unreadable; return 0; }
    all+="$names"$'\n'
  done
  while IFS=$'\t' read -r tag name; do
    [ -n "$tag" ] || continue
    case "$tag" in
      J) job=1 ;;
      P) [[ "$name" =~ $BS_SUITE_RE ]] && [[ "$name" != *..* ]] || other=1 ;;
      *) other=1 ;;
    esac
  done <<<"$all"
  [ "$job" = 1 ] && { _bs_skip "$f" job-only; return 0; }
  [ "$other" = 1 ] && { _bs_skip "$f" not-paths; return 0; }
  st=$(awk -F'\t' '$1 == "P" { print $2 }' <<<"$all" | sort -u | paste -sd, -)
  _bs_f="ok $base40 $st $m"
  printf '%s\n' "$_bs_f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  return 0
}

# _bs_member <slug> <num> <head> <base40> <suites> <fp> <draft> — this member's
#   solo run: dispatched on a miss, settled once it completed. Prints its raw
#   word: red (a parsed red that names a suite), clean, could-not-run, pending.
_bs_member() {
  local slug="$1" num="$2" head="$3" base="$4" suites="$5" fp="$6" d="$7" path st at id rest line su why rc
  path=$(pq_key "$slug" "$num" "$head" "$base" "$fp")
  read -r st at id rest <<<"$(pq_cache_get "$path")"
  if [ -z "$st" ]; then
    [ "${MERGES:-0}" = 1 ] || { echo pending; return 0; }
    rc=0; pq_dispatch "$slug" "$num" "$head" "$base" "$suites" "$fp" || rc=$?
    case "$rc" in 0|3) echo pending; return 0 ;; esac
    mc_log "BATCH_SOLO_DISPATCH_FAILED $slug#$num ${head:0:8} draft #$d: prequeue-gate.yml was not dispatched (rc $rc); #4428's rule decides for it"
    echo could-not-run; return 0
  fi
  if [ "$st" = pending ]; then
    rc=0; line=$(pq_read_run "$slug" "$(pq_run_title "$num" "$head" "$base")") || rc=$?
    [ "$rc" = 0 ] || { echo pending; return 0; }
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    if [ -z "$line" ]; then
      [ $(( $(date +%s) - at )) -lt "$(pq_knob MC_PREQUEUE_DEADLINE_S)" ] && { echo pending; return 0; }
      line="could-not-run - - deadline"
    fi
    read -r st id su why <<<"$line"
    [ "$su" = - ] && su=""
    pq_cache_put "$path" "$st" "$at" "$id" "$su" \
      || mc_log "BATCH_SOLO $slug#$num: could not record $st for ${head:0:8} on ${base:0:12}"
    _bs_log_once "$path.log" "BATCH_SOLO_RESULT $slug#$num ${head:0:8} draft #$d on ${base:0:12}: $st${su:+ suites=$su}${why:+ ($why)}"
    rest="$su"
  fi
  rest="${rest#alerted}"; rest="${rest# }"
  case "$st" in
    red) [ -n "$rest" ] && echo red || echo could-not-run ;;
    green) echo clean ;;
    pending) echo pending ;;
    *) echo could-not-run ;;
  esac
}

# bs_batch <slug> <draft> — see the header. Memoised per tick, so N members
#   asking in one tick cost one pass.
bs_batch() {
  local slug="$1" d="$2" memo="" base suites m fp raw h w out="" nums=() heads=() words=() i clean=0 pend=0
  BS_SUITES=""; BS_BASE=""
  [ "$(pq_knob MC_BATCH_SOLO)" = 0 ] && return 0
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "${MC_H:-}" ] && [ -n "$slug" ] && [ -n "$d" ] || return 0
  if [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ]; then
    memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").bs.${slug//\//_}_$d"
    if [ -r "$memo" ]; then { read -r _ BS_BASE BS_SUITES; cat; } < "$memo"; return 0; fi
  fi
  pq_wf_present "$slug"
  if [ "$_pq_wf" = yes ] && _bs_facts "$slug" "$d" && [ "${_bs_f%% *}" = ok ]; then
    read -r _ base suites m <<<"$_bs_f"
    fp=$(tr ',' '\n' <<<"$suites" | sha1sum | cut -c1-12)
    for i in $m; do
      h=""; mc_rest_var raw gh_rest GET "repos/$slug/pulls/$i" && h=$(jq -r '.head.sha // empty' <<<"$raw" 2>/dev/null)
      if [[ "$h" =~ ^[0-9a-f]{40}$ ]]; then w=$(_bs_member "$slug" "$i" "$h" "$base" "$suites" "$fp" "$d")
      else h=-; w=could-not-run; fi
      nums+=("$i"); heads+=("$h"); words+=("$w")
      case "$w" in clean) clean=1 ;; pending) pend=1 ;; esac
    done
    for i in "${!nums[@]}"; do
      w="${words[$i]}"
      if [ "$w" = red ]; then
        if [ "$pend" = 1 ]; then w=pending; elif [ "$clean" = 1 ]; then w=reproduces; else w=could-not-run; fi
      fi
      out+="${nums[$i]} ${heads[$i]} $w"$'\n'
    done
    BS_BASE="$base"; BS_SUITES="$suites"
  fi
  # tmp + mv: a worker reading the memo never sees half of it.
  [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null \
    && printf '@ %s %s\n%s' "$BS_BASE" "$BS_SUITES" "$out" > "$memo.tmp.$$" 2>/dev/null && mv -f "$memo.tmp.$$" "$memo" 2>/dev/null
  printf '%s' "$out"
}
