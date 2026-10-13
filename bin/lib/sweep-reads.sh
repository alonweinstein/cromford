#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # SWEEP_PRS_* are read by the sourcing lanes
# bin/lib/sweep-reads.sh — BH-1575: the per-PR GitHub reads of bin/merge-sweep.sh
# (the hub's */10 merge sweep). Sourced, never executed. A tree WITHOUT this
# file (an old box mid-rollout, a fixture that copies only the lane) keeps the
# lane's own reads exactly as they were: every call site tests `command -v`
# first.
#
# THE INCIDENT (2026-09-22 12:20-12:22Z). merge-sweep.log carried 70 lines of
# "read UNVERIFIABLE (HTTP 304)" in one tick, 69 PRs, while the App
# installation's bucket was drained. A 304 is an ETag HIT and gh_rest answers it
# rc 0 — the read that failed was something else. It ran inside
# `STATE=$(mc_pr_view …)`, so GH_REST_STATUS died with the subshell and the log
# printed whatever the parent shell's last read had said. The fix is to read in
# the CALLER's shell (sweep_pr_view_var), so the status the log names is the
# status of that read.
#
# THE ONE 304 THAT IS A FAILURE. gh_rest answers a 304 whose cache entry is gone
# (swept, or replaced by a concurrent writer between the request and the reply)
# as rc 75, reason `cache-miss`. That is not "GitHub would not answer", it is
# "we asked the wrong question": sweep_rest_get asks again once, WITHOUT
# If-None-Match, instead of skipping the tick. gh-rest.sh's own contract (75 on
# cache-miss, tests/gh-rest-etag-test.sh) is unchanged; the retry is the
# caller's decision, made here for this lane.
#
# THE READS THIS FILE SAVES (the gh-reads audit, 2026-09-23: merge-sweep ~965
# calls/h):
#   * one pulls/N read per PR per tick, memoised (sweep_pr_view_var) — the state
#     read, the REBASE note's head and the discounts' head were three reads of
#     one object;
#   * pulls/N/commits only when the head sha moved (sweep_head_date_var): the
#     head commit's date is a property of the sha, so a sha seen before answers
#     from state/<lane>-heads.tsv;
#   * no read at all when merge-conductor's pr-state.tsv answers for a FRESH
#     project (sweep_prstate_read): that project's tick-<P>.json finished
#     inside the knob and saw PRs. Not the file's mtime — any project's tick
#     rewrites the whole file. What a row may decide is narrow on purpose (see
#     sweep_prstate_custody): a row can make merge-sweep SKIP only in a state
#     stricter than its own gates, or record a MERGED (immutable) PR; it never
#     merges one. Every other word is read live.
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${SWEEP_READS_LIB:-}" ]; then return 0 2>/dev/null; fi
SWEEP_READS_LIB=1
SWEEP_MEMO_URL=""
SWEEP_MEMO_JSON=""

# sweep_rest_get <outfile> <path> [gh_rest args...] — gh_rest GET in THIS
# shell, so GH_REST_STATUS/GH_REST_REASON are the caller's afterwards. rc is
# gh_rest's (0/44/75). A cache-miss 304 is re-asked once without If-None-Match.
sweep_rest_get() {
  local out="${1:?outfile}" rc=0; shift
  if ! command -v gh_rest >/dev/null 2>&1; then
    GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75
  fi
  gh_rest GET "$@" > "$out" || rc=$?
  if [ "$rc" = 75 ] && [ "${GH_REST_REASON:-}" = cache-miss ]; then
    rc=0
    GH_ETAG=0 gh_rest GET "$@" > "$out" || rc=$?
  fi
  return "$rc"
}

# sweep_pr_memo_reset — forget the memoised pull object. The lanes call it at
# the top of every record, so a PR merged by this iteration is never answered
# from the read taken before the merge.
sweep_pr_memo_reset() { SWEEP_MEMO_URL=""; SWEEP_MEMO_JSON=""; }

# sweep_pr_view_var <var> <pr-url> [jq] — mc_pr_view's answer (the same
# MC_REST_NORM words: STATE, MSTATE, MERGEABLE, LABELS), assigned to <var> in
# the caller's shell. One pulls/N read per PR until sweep_pr_memo_reset. rc 0,
# 44 (absent) or 75 (unverifiable, or no conductor lib to normalise with); on a
# non-zero rc <var> is empty.
sweep_pr_view_var() {
  local _sv_var="${1:?var}" _sv_url="${2:-}" _sv_q="${3:-.}" _sv_t _sv_rc=0 _sv_sn _sv_slug _sv_num _sv_out
  printf -v "$_sv_var" '%s' ""
  if [ "$SWEEP_MEMO_URL" != "$_sv_url" ] || [ -z "$_sv_url" ]; then
    sweep_pr_memo_reset
    [ -n "${MC_REST_NORM:-}" ] || { GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75; }
    _sv_sn=$(mc_rest_slug_num "$_sv_url" 2>/dev/null) || { GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75; }
    read -r _sv_slug _sv_num <<<"$_sv_sn"
    _sv_t=$(mktemp "${TMPDIR:-/tmp}/sweep-pr.XXXXXX") || return 75
    sweep_rest_get "$_sv_t" "repos/$_sv_slug/pulls/$_sv_num" || _sv_rc=$?
    if [ "$_sv_rc" != 0 ]; then rm -f "$_sv_t"; return "$_sv_rc"; fi
    SWEEP_MEMO_JSON=$(jq -c "$MC_REST_NORM" "$_sv_t" 2>/dev/null) || SWEEP_MEMO_JSON=""
    rm -f "$_sv_t"
    [ -n "$SWEEP_MEMO_JSON" ] || { GH_REST_REASON=unparseable; return 75; }
    SWEEP_MEMO_URL="$_sv_url"
  fi
  _sv_out=$(printf '%s' "$SWEEP_MEMO_JSON" | jq -r "$_sv_q" 2>/dev/null) || return 75
  printf -v "$_sv_var" '%s' "$_sv_out"
  return 0
}

# _sweep_project_fresh <slug> <state-dir> <fresh-secs> <now> — rc 0 when a
# conductor project serving this repo finished a tick inside the knob AND saw
# PRs on it; prints that tick's age. FRESHNESS IS PER PROJECT (review of
# #1599): pr-state.tsv is rewritten whole by any project's tick, the resolver
# and the rebase jobs, so its mtime only says "some row moved". tick-<P>.json
# is written by EVERY tick of P, including the one whose PR list failed —
# which records prs_seen=0, the case that must fall back to GitHub. The
# project comes from fleet.conf's repo column (FLEET_CONF, else the harness
# root's fleet.conf), the file names from mc_safe_name's rule.
_sweep_project_fresh() {
  local slug="${1:-}" dir="${2:-}" fresh="${3:-}" now="${4:-}" conf p f fin seen
  conf="${FLEET_CONF:-}"
  [ -r "$conf" ] || conf="${dir%/state/merge-conductor}/fleet.conf"
  [ -r "$conf" ] || return 1
  while read -r p; do
    [ -n "$p" ] || continue
    f="$dir/tick-${p//[^A-Za-z0-9._-]/_}.json"
    [ -r "$f" ] || continue
    read -r fin seen < <(jq -r '"\(.finished_at // "") \(.prs_seen // "")"' "$f" 2>/dev/null)
    case "$fin$seen" in ''|*[!0-9]*) continue ;; esac
    [ "$seen" -gt 0 ] && [ "$fin" -le "$now" ] && [ $((now - fin)) -le "$fresh" ] || continue
    printf '%s\n' $((now - fin)); return 0
  done < <(awk -v s="$slug" '!/^[[:space:]]*#/ && NF>=2 && tolower($2)==tolower(s) {print $1}' "$conf" 2>/dev/null)
  return 1
}

# sweep_prstate_read <pr-url> <pr-state.tsv> <fresh-secs> — merge-conductor's
# row for this PR, when the conductor project that owns its repo is fresh (see
# _sweep_project_fresh). rc 0 sets SWEEP_PRS_STATE, SWEEP_PRS_HEAD and
# SWEEP_PRS_AGE (seconds since that project's last tick finished); rc 1 = no
# answer (knob off, empty or not a number, no fresh project tick, no row, a
# row whose head is not a sha) and the caller reads GitHub. The row is matched
# on the conductor's key (<slug>#<num>) or on its url.
sweep_prstate_read() {
  local url="${1:-}" f="${2:-}" fresh="${3:-}" now sn slug num row st hd age
  SWEEP_PRS_STATE=""; SWEEP_PRS_HEAD=""; SWEEP_PRS_AGE=""
  case "$fresh" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$url" ] && [ -r "$f" ] || return 1
  sn=$(mc_rest_slug_num "$url" 2>/dev/null) || return 1
  read -r slug num <<<"$sn"
  now=$(date +%s)
  age=$(_sweep_project_fresh "$slug" "$(dirname "$f")" "$fresh" "$now") || return 1
  row=$(awk -F'\t' -v k="$slug#$num" -v u="$url" '$1==k || $8==u {print $2 "\t" $4; exit}' "$f" 2>/dev/null)
  IFS=$'\t' read -r st hd <<<"$row"
  [[ "$st" =~ ^[A-Z_]+$ ]] && [[ "$hd" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  SWEEP_PRS_STATE="$st"; SWEEP_PRS_HEAD="$hd"; SWEEP_PRS_AGE="$age"
  return 0
}

# sweep_prstate_custody <state> — rc 0 only for the conductor words that are
# STRICTER than anything merge-sweep would decide on its own reading, so a
# skip can never cost a merge the sweep would have made:
#   NEEDS_REBASE, REBASING  the PR is DIRTY — the sweep never merges DIRTY;
#   QUEUED                  the repo's merge queue owns the landing;
#   STACKED_WAIT            based on another PR's branch — never merged;
#   ABANDONED               the resolver closed it.
# Everything else is read live (review of #1599): WAIT_CI and RED_TWICE are
# where the conductor holds a project-4 PR the sweep's E2E discount merges (the
# conductor has no such discount and rewrites those rows every tick);
# WAIT_REVIEW and HEAD_MOVED are states the sweep's head-bound gate passes when
# no reviewed sha exists; BLOCKED_HUMAN carries reasons the sweep does not
# share. READY, MERGED, CLOSED and unknown words are never custody either.
sweep_prstate_custody() {
  case "${1:-}" in
    NEEDS_REBASE|REBASING|QUEUED|STACKED_WAIT|ABANDONED) return 0 ;;
  esac
  return 1
}

# sweep_head_date_var <var> <cache.tsv> <pr-url> <head-sha> <commits-path> —
# the committer date of the PR's last listed commit (the REBASE note's
# evidence), assigned to <var>. A (PR, head) pair already in the cache answers
# without a read; otherwise pulls/N/commits is read through mc_rest_pages and
# the answer stored. An empty head is read and never stored. rc 0 always — an
# unread date is an EMPTY date, which the caller already treats as "not newer".
sweep_head_date_var() {
  local _hd_var="${1:?var}" cache="${2:-}" url="${3:-}" head="${4:-}" path="${5:-}" d="" tmp
  printf -v "$_hd_var" '%s' ""
  if [ -n "$head" ] && [ -r "$cache" ]; then
    d=$(awk -F'\t' -v u="$url" -v h="$head" '$1==u && $2==h {print $3; exit}' "$cache" 2>/dev/null)
    [ -n "$d" ] && { printf -v "$_hd_var" '%s' "$d"; return 0; }
  fi
  d=$(mc_rest_pages "$path" 2>/dev/null | jq -r '.[-1].commit.committer.date // ""' 2>/dev/null)
  printf -v "$_hd_var" '%s' "$d"
  [ -n "$head" ] && [ -n "$d" ] && [ -n "$cache" ] || return 0
  # One row per PR: the old head's date can never be asked for again.
  tmp=$(mktemp "${cache}.XXXXXX" 2>/dev/null) || return 0
  { awk -F'\t' -v u="$url" '$1!=u' "$cache" 2>/dev/null; printf '%s\t%s\t%s\n' "$url" "$head" "$d"; } > "$tmp" \
    && mv -f "$tmp" "$cache"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# sweep_probe_class_rest <owner/repo> [token] — merge-sweep's token probe
# (repos/<slug>) through gh_rest, so it is ledgered and ETag-conditional.
# Prints ok|invisible|transient with the classification bin/merge-sweep.sh's
# raw probe has always used (BH-796): 404/401 invisible; 403 transient only
# when GitHub says rate limit; 429/5xx/no status transient. Runs in a subshell
# so the token it tries never leaks into the caller.
sweep_probe_class_rest() (
  local slug="${1:-}" t rc=0
  if [ -n "${2-}" ]; then export GH_TOKEN="$2"; else unset GH_TOKEN; fi
  t=$(mktemp "${TMPDIR:-/tmp}/sweep-probe.XXXXXX") || { printf 'transient\n'; exit 0; }
  sweep_rest_get "$t" "repos/$slug" || rc=$?
  rm -f "$t"
  case "$rc" in
    0)  printf 'ok\n' ;;
    44) printf 'invisible\n' ;;
    *)  case "${GH_REST_STATUS:-000}" in
          401) printf 'invisible\n' ;;
          403) if [ "${GH_REST_REASON:-}" = rate-limit ]; then printf 'transient\n'; else printf 'invisible\n'; fi ;;
          *)   printf 'transient\n' ;;
        esac ;;
  esac
)

# sweep_ci_rest <owner/repo> <path> [-q|--jq <expr>] — the no-lib stand-in for
# gh_ci_api (bin/lib/gh-ci-read.sh), through gh_rest instead of a raw `gh api`.
# stdout is the body (or the jq projection), rc gh_rest's.
sweep_ci_rest() {
  local path="${2:-}" q="" t rc=0
  shift 2 2>/dev/null
  while [ $# -gt 0 ]; do
    case "$1" in -q|--jq) q="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  t=$(mktemp "${TMPDIR:-/tmp}/sweep-ci.XXXXXX") || return 75
  sweep_rest_get "$t" "$path" || rc=$?
  if [ "$rc" = 0 ]; then
    if [ -n "$q" ]; then jq -r "$q" "$t" 2>/dev/null || rc=75; else cat "$t"; fi
  fi
  rm -f "$t"
  return "$rc"
}
