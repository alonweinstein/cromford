#!/bin/bash
# bin/lib/review-bought.sh — BH-3930: never pay to re-review an unchanged PR
# head. Sourced, never executed. This file is the CONTRACT slice (BH-3937): the
# names every review lane imports. No lane sources it yet. BH-3938 gives
# review_bought its body: three GET-only reads of the jobs worker (rrverdict
# attempts, /api/verdicts, verdict history) through the caller's jobs client.
#
# Knobs (catalog/lanes.d/_lib.review-bought.json; settings rows
# lib.review-bought.<env lowercased>, applied once per process by _rb_env through
# lib_env_apply review-bought):
#   REVIEW_DEDUPE              1 | 0 — 0 skips the "already bought?" reads
#   REVIEW_DEDUPE_REBUY_AFTER  unix epoch, 0 = off — the operator's
#                              prompt/model-changed lever (review_rebuy_after)
#
# The harness root is ${HARNESS:-${H:-}} only (BH-2613); with no root the
# log lines (a dropped fp reason, a bad re-buy epoch) are skipped, nothing else
# changes.
[ -n "${_RB_LOADED:-}" ] && return 0
_RB_LOADED=1
# rp_prov_is_claude (bin/lib/review-provenance.sh) decides which serving words
# are Claude for review_bought_prov. Loaded once, never fatal: without it only
# the literal words below count.
# shellcheck source=bin/lib/review-provenance.sh
command -v rp_prov_is_claude >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/review-provenance.sh" 2>/dev/null || true

RB_SOURCE=""; RB_WORD=""; RB_CLASS=""; RB_SERVED=""
_RB_ENV_SET="${_RB_ENV_SET:-}"

# _rb_log <text> — one line in logs/review-bought.log; skipped with no root.
_rb_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf 'review-bought: %s\n' "${1:-}" 2>/dev/null >> "$h/logs/review-bought.log"
  return 0
}

# _rb_env — apply the settings rows once per process (memoised like
# verdict_single_home_on); fail-soft without lane-gate.
_rb_env() {
  [ "${_RB_ENV_SET:-}" = 1 ] && return 0
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply review-bought >/dev/null 2>&1
  _RB_ENV_SET=1
}

# review_dedupe_on — is the dedupe read on?
review_dedupe_on() { _rb_env; [ "${REVIEW_DEDUPE:-1}" != 0 ]; }

# review_rebuy_after — prints the operator's re-buy epoch, 0 = off. Anything
# not a whole number is 0, said in the log, never guessed.
review_rebuy_after() {
  local v
  _rb_env; v="${REVIEW_DEDUPE_REBUY_AFTER:-0}"
  case "$v" in
    ''|*[!0-9]*) _rb_log "REVIEW_DEDUPE_REBUY_AFTER '$v' is not a unix epoch, re-buy is OFF"; printf 0 ;;
    *) printf '%s' "$((10#$v))" ;;
  esac
}

# review_bought <slug> <num> <sha> [--class review|lead] [--except-builder]
#   Has a verdict already been paid for on exactly this head?
#   rc 0 = covered: prints `<source>\t<WORD>` and sets RB_SOURCE, RB_WORD,
#          RB_CLASS (approve|block) and RB_SERVED (BH-4134: the lane that served
#          the hit — the rrverdict line's 4th field, a history round's
#          detail.served_by else detail.provenance; "" when the row does not
#          say, which is always so for /api/verdicts). review_bought_prov
#          classifies it.
#   rc 2 = miss: buy the review. Every read answered and none bound this sha,
#          or REVIEW_DEDUPE=0 (then no request is made at all).
#   rc 1 = a read failed and nothing hit, the jobs client is not loaded, or the
#          args are invalid.
#   The reads run in order and stop at the first hit:
#     1 rrverdict attempt lines `<sha> <WORD> <epoch> [<served>]` -> source mc-rereview
#     2 GET /api/verdicts rows at head_sha -> lead | human | box
#     3 GET /api/verdict/history rounds at reviewed_sha -> review-prs, or a
#       source-less/run-build round (reported as run-build) unless
#       --except-builder. A settled:false round never covers; any other
#       source (review-rescue-backfill, ...) never covers.
#   --class lead runs read 2 only and takes lead/human rows only. The sha match
#   is exact string equality. A row older than REVIEW_DEDUPE_REBUY_AFTER (or
#   with a date that does not parse, while it is set) never covers. Several
#   matches: the newest wins. The jobs client (_jobs_req, pr_attempt_list,
#   job_verdict_history) is the caller's to load; this file never sources it.
review_bought() {
  RB_SOURCE=""; RB_WORD=""; RB_CLASS=""; RB_SERVED=""
  local slug="${1:-}" num="${2:-}" sha="${3:-}" cls=review exb=0
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$num" =~ ^[0-9]+$ ]] || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) case "${2:-}" in review|lead) cls="$2"; shift 2 ;; *) return 1 ;; esac ;;
      --except-builder) exb=1; shift ;;
      *) return 1 ;;
    esac
  done
  review_dedupe_on || return 2
  declare -F _jobs_req pr_attempt_list job_verdict_history >/dev/null || return 1
  local rebuy failed=0 hit rc
  rebuy=$(review_rebuy_after)
  if [ "$cls" = review ]; then
    hit=$(_rb_read_rr "$slug" "$num" "$sha" "$rebuy"); rc=$?
    [ "$rc" = 0 ] && { _rb_hit "$hit"; return 0; }
    [ "$rc" = 1 ] && failed=1
  fi
  hit=$(_rb_read_verdicts "$slug" "$num" "$sha" "$rebuy" "$cls"); rc=$?
  [ "$rc" = 0 ] && { _rb_hit "$hit"; return 0; }
  [ "$rc" = 1 ] && failed=1
  if [ "$cls" = review ]; then
    hit=$(_rb_read_history "$slug" "$num" "$sha" "$rebuy" "$exb"); rc=$?
    [ "$rc" = 0 ] && { _rb_hit "$hit"; return 0; }
    [ "$rc" = 1 ] && failed=1
  fi
  [ "$failed" = 1 ] && return 1
  return 2
}

# _rb_norm <word> — approve | block | nothing (not a verdict). Exact, case-sensitive.
_rb_norm() {
  case "${1:-}" in
    MERGE|MERGE-WITH-NOTES|APPROVE) printf approve ;;
    BLOCK|REQUEST_CHANGES) printf block ;;
  esac
}

# _rb_fresh <epoch-or-date> <rebuy> — rc 0 when the row may cover: re-buy off,
# or the row is at/after the re-buy epoch. A value that does not parse is old.
_rb_fresh() {
  local v="${1:-}" rebuy="${2:-0}" e
  [ "$rebuy" = 0 ] && return 0
  case "$v" in
    '') return 1 ;;
    *[!0-9]*) e=$(date -u -d "$v" +%s 2>/dev/null) || return 1
              [[ "$e" =~ ^-?[0-9]+$ ]] || return 1 ;;
    *) e=$((10#$v)) ;;
  esac
  [ "$e" -ge "$rebuy" ]
}

# _rb_hit <source>\t<WORD>\t<served> — set RB_* and print `<source>\t<WORD>`.
# A served of "-" (the read had none) is "".
_rb_hit() {
  local rest
  RB_SOURCE="${1%%$'\t'*}"; rest="${1#*$'\t'}"
  RB_WORD="${rest%%$'\t'*}"; RB_SERVED="${rest#*$'\t'}"
  [ "$RB_SERVED" = "$rest" ] && RB_SERVED=""
  [ "$RB_SERVED" = - ] && RB_SERVED=""
  RB_CLASS=$(_rb_norm "$RB_WORD")
  printf '%s\t%s\n' "$RB_SOURCE" "$RB_WORD"
}

# review_bought_prov — after a hit, who served it, as one word:
#   cleared   the source is lead or human: a lead/human MERGE row clears
#             provenance (BH-1525, mc_prov_cleared -> vd_clears)
#   unknown   the hit does not say which lane served it
#   claude    rp_prov_is_claude says the serving word is Claude
#   fallback  any other lane
# Only an APPROVE needs this (BH-4134): a reused BLOCK never merges anything.
review_bought_prov() {
  case "${RB_SOURCE:-}" in lead|human) printf cleared; return 0 ;; esac
  case "${RB_SERVED:-}" in ''|-|null) printf unknown; return 0 ;; esac
  if command -v rp_prov_is_claude >/dev/null 2>&1; then
    rp_prov_is_claude "$RB_SERVED" && { printf claude; return 0; }
  else
    case "$RB_SERVED" in claude|claude-via-openrouter) printf claude; return 0 ;; esac
  fi
  printf fallback
}

# A TSV field the reads split on is never empty (read collapses a run of tabs,
# which would shift every later column): null or "" prints as "-".
_RB_JQ_F='def f: (. // "" | tostring | if . == "" then "-" else . end); '

# Each read prints `<source>\t<WORD>\t<served or ->` and returns 0 on a hit, 2 when it
# answered with no hit, 1 when it failed (an outage, or a body it cannot parse).

# _rb_read_rr <slug> <num> <sha> <rebuy> — rrverdict attempt lines; newest epoch wins.
_rb_read_rr() {
  local lines rc a w e s best="" bests="" beste=-1 ev
  lines=$(pr_attempt_list "$1" "$2" rrverdict); rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && return 2; return 1; }
  while read -r a w e s _; do
    [ "$a" = "$3" ] || continue
    [ -n "$(_rb_norm "$w")" ] || continue
    _rb_fresh "$e" "$4" || continue
    if [[ "$e" =~ ^[0-9]+$ ]]; then ev=$((10#$e)); else ev=0; fi
    [ "$ev" -gt "$beste" ] && { beste=$ev; best="$w"; bests="${s:--}"; }
  done <<< "$lines"
  [ -n "$best" ] || return 2
  printf 'mc-rereview\t%s\t%s' "$best" "$bests"
}

# _rb_read_verdicts <slug> <num> <sha> <rebuy> <class> — /api/verdicts rows,
# newest first; no &head=, so the human_verdict_mode read never gates dedupe.
_rb_read_verdicts() {
  local q resp rc rows h w s c srcs=" lead human box "
  [ "$5" = lead ] && srcs=" lead human "
  q=$(jq -nr --arg r "$1" --arg n "$2" '"repo="+($r|@uri)+"&pr="+($n|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdicts?$q"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  rows=$(printf '%s' "$resp" | jq -r "$_RB_JQ_F"'.rows | if type == "array" then .[]
      | [(.head_sha | f), (.verdict | f), (.source | f), (.created_at | f)] | @tsv else error end' 2>/dev/null) || return 1
  while IFS=$'\t' read -r h w s c; do
    [ "$h" = "$3" ] || continue
    case "$srcs" in *" $s "*) ;; *) continue ;; esac
    [ -n "$(_rb_norm "$w")" ] || continue
    _rb_fresh "$c" "$4" || continue
    printf '%s\t%s\t-' "$s" "$w"; return 0
  done <<< "$rows"
  return 2
}

# _rb_read_history <slug> <num> <sha> <rebuy> <except-builder 0|1> — the
# verdict_history rounds of https://github.com/<slug>/pull/<num>, oldest first,
# so the last match wins. Read through _jobs_req rather than
# job_verdict_history because the settled flag lives in `detail`, which that
# helper's TSV does not carry; parsed the way job_verdict_covers parses it.
# The served word is detail.served_by, else detail.provenance (a null
# served_by falls through; a literal "-" is "", unknown, which errs safe).
_rb_read_history() {
  local q resp rc rows w h s c st sv best=""
  q=$(jq -nr --arg v "https://github.com/$1/pull/$2" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict/history?$q"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  rows=$(printf '%s' "$resp" | jq -r "$_RB_JQ_F"'.rounds | if type == "array" then .[]
      | ((try (.detail // "" | fromjson) catch {}) as $o | if ($o | type) == "object" then $o else {} end) as $o
      | [(.verdict | f), (.reviewed_sha | f), (.source | f), (.created_at | f),
         (if $o.settled == false then "0" else "1" end), (($o.served_by // $o.provenance) | f)] | @tsv else error end' 2>/dev/null) || return 1
  while IFS=$'\t' read -r w h s c st sv; do
    [ "$h" = "$3" ] || continue
    [ -n "$(_rb_norm "$w")" ] || continue
    [ "$st" = 1 ] || continue
    _rb_fresh "$c" "$4" || continue
    case "$s" in
      review-prs) ;;
      -|null|run-build) [ "$5" = 1 ] && continue; s=run-build ;;
      *) continue ;;
    esac
    best="$s"$'\t'"$w"$'\t'"${sv:--}"
  done <<< "$rows"
  [ -n "$best" ] || return 2
  printf '%s' "$best"
}

# _rb_fp <prefix> <slug> <num> <sha> [reason] — the shared per-head guard
# fingerprint `<prefix>:<slug>#<num>@<sha>[~<reason>]`. A reason that is not
# ^[a-z0-9]{1,24}$ is dropped with one log line.
_rb_fp() {
  local p="${1:-}" slug="${2:-}" num="${3:-}" sha="${4:-}" r="${5:-}"
  if [ -n "$r" ] && ! [[ "$r" =~ ^[a-z0-9]{1,24}$ ]]; then
    _rb_log "dropped bad fp reason '$r' for $slug#$num"
    r=""
  fi
  printf '%s:%s#%s@%s%s' "$p" "$slug" "$num" "$sha" "${r:+~$r}"
}
review_fp() { _rb_fp review "$@"; }
lead_fp()   { _rb_fp lead "$@"; }

# review_skip_log <logfile> <slug> <num> <sha> <lane> — the one line a lane
# writes when it skips a review it already paid for. Never fails.
review_skip_log() {
  printf '%s review_skip_unchanged %s#%s@%s lane=%s by=%s/%s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    "${2:-}" "${3:-}" "$(printf '%s' "${4:-}" | cut -c1-12)" "${5:-}" "${RB_SOURCE:-}" "${RB_WORD:-}" \
    2>/dev/null >> "${1:-/dev/null}"
  return 0
}
