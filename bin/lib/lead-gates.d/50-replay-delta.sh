#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/50-replay-delta.sh — gate 3 of bin/lead-review-enqueue.sh
# (BH-3930, BH-5294, BH-5582), ported to the worklist: the lead's word on an
# earlier head G is kept when this head carries the same patch.
#   It runs when gate 10 left the head unapproved or rebound, or when
#   bin/lib/lead-delta.sh is loaded (the enqueue's condition). Gate 10's
#   LGB_* globals for this (slug, PR, head) say which; without them the head
#   counts as approved and not rebound.
#   GET /api/verdicts?repo=&pr= (the whole history):
#     unreadable or truncated            rc 0, a full review (the enqueue fell
#                                        through to its request here too).
#     a lead row on this head with a
#       `lead-replay:` note              rc 12: already replayed, never twice.
#     unapproved and a lead, human or
#       risk-tier row on this head       rc 10 [skip verdict].
#   G is the newest lead MERGE, MERGE-WITH-NOTES or BLOCK row on another head
#   whose note is not itself a `lead-replay:` (bin/lib/lead-worklist.sh
#   lw_replay's rule). A BLOCK is a source only for a rebound head.
#   The class: a cached delta.tsv row, else patch_same_fetch, then ld_classify
#   (or patch_same alone without bin/lib/lead-delta.sh).
#     replay <how>   bin/lead-verdict.sh post <G's word> --source lead --note
#                    "lead-replay:<G12> how:<how>". Exit 0, 4 or 5: one
#                    modes.tsv `replay` row and rc 12. Any other exit: rc 11.
#                    With no readable lead token file on this box it posts
#                    nothing and returns 0: review_one's own lw_replay then
#                    replays a MERGE through /result.
#     delta ...      (G's word not BLOCK) LG_MODE=delta and rc 0. It writes no
#                    modes.tsv `delta` row: review_one does not read LG_MODE
#                    yet, so the review that runs is a full one.
#     full ..., no G, or any read or lib failure   rc 0.
# State: state/lead-review-enqueue/delta.tsv and modes.tsv, the enqueue's own
# files, columns and keys (pruned 7 and 30 days, once per process).
# Sourced by bin/lib/lead-gates.sh, never run.

declare -g _LGR_TICKED="" _LGR_LDMAX="" _LGR_LDPMAX=""

_lgr_state() { local root="${HARNESS:-${H:-}}"; [ -n "$root" ] || return 1; printf '%s\n' "$root/state/lead-review-enqueue"; }

# _lgr_skip <slug> <n> <head> <class> <text> — lgs_skip_once (05-skip-ledger.sh);
#   without it the `[skip <class>]` line is logged on every tick.
_lgr_skip() {
  if command -v lgs_skip_once >/dev/null 2>&1; then lgs_skip_once "$@"
  else _lgt_log "[skip $4] $1#$2 @${3:0:12} $5"; fi
}

lg_tick_replay_delta() {
  local st now f
  [ -n "$_LGR_TICKED" ] && return 0
  _LGR_TICKED=1
  if command -v ld_classify >/dev/null 2>&1; then
    _LGR_LDMAX=$(ld_knob LEAD_DELTA_REVIEW_MAX_LINES) || _LGR_LDMAX="unresolved"
    _LGR_LDPMAX=$(ld_knob LEAD_DELTA_PROTECTED_MAX_LINES) || _LGR_LDPMAX="unresolved"
  fi
  st=$(_lgr_state) || return 0
  mkdir -p "$st" 2>/dev/null || return 0
  now=$(date +%s)
  f="$st/delta.tsv"
  [ -f "$f" ] && awk -F'\t' -v c=$((now - 604800)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  f="$st/modes.tsv"
  [ -f "$f" ] && awk -F'\t' -v c=$((now - 2592000)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  rm -f "$st"/*.tmp."$$" 2>/dev/null
  return 0
}

lg_gate_replay_delta() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" approved=1 rebound=0 ld=0 st vd d
  local ph="" pw="" pid="" project repo cls="" how prc out tok box
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  [ -n "$_LGR_TICKED" ] || lg_tick_replay_delta "$slug"
  if [ "${LGB_KEY:-}" = "$slug#$n@$head" ]; then approved="${LGB_APPROVED:-1}"; rebound="${LGB_REBOUND:-0}"; fi
  command -v ld_classify >/dev/null 2>&1 && ld=1
  [ "$rebound" = 1 ] || [ "$approved" = 0 ] || [ "$ld" = 1 ] || return 0
  d=$(lgs_dir 2>/dev/null) || { _lgt_log "$slug#$n @$h12: no scratch dir; no replay, full review"; return 0; }
  vd="$d/vd-$n"
  # A truncated history cannot prove which lead row is newest: unreadable.
  if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$n" > "$vd" 2>/dev/null \
     || ! jq -e '(.rows | type) == "array" and .truncated != true' "$vd" >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: verdicts read failed; full review"; return 0
  fi
  if jq -e --arg h "$head" 'any(.rows[]; .source == "lead" and ((.head_sha // "") | ascii_downcase) == $h
       and ((.note // "") | split(" ") | any(startswith("lead-replay:"))))' "$vd" >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: lead word already replayed onto this head; no post, no review"
    return 12
  fi
  if [ "$approved" = 0 ] && jq -e --arg h "$head" 'any(.rows[]; ((.head_sha // "") | ascii_downcase) == $h
       and ((.source // "") | IN("lead", "human", "risk-tier")))' "$vd" >/dev/null 2>&1; then
    _lgr_skip "$slug" "$n" "$head" verdict "a lead, human or risk-tier verdict is on this head"; return 10
  fi
  IFS=$'\t' read -r ph pw pid < <(jq -r --arg h "$head" '[.rows[] | select(.source == "lead"
      and ((.head_sha // "") | ascii_downcase) != $h
      and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
      and (((.note // "") | contains("lead-replay:")) | not))]
    | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)\t\(.id)"' "$vd" 2>/dev/null)
  [[ "$ph" =~ ^[0-9a-f]{40}$ ]] || return 0
  # BH-5294: a BLOCK never leaves its own head but through BH-3930's rebound replay.
  [ "$pw" = BLOCK ] && [ "$rebound" != 1 ] && return 0
  st=$(_lgr_state) || { _lgt_log "$slug#$n @$h12: no harness root; no replay, full review"; return 0; }
  mkdir -p "$st" 2>/dev/null
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  repo="${REPOS_ROOT:-/root/repos}/$project"
  if [ "$ld" = 1 ]; then
    # A protected or over-max class is only reused under the same allowance and word (BH-5582).
    cls=$(awk -F'\t' -v s="$slug" -v n="$n" -v g="$ph" -v h="$head" -v m="$_LGR_LDMAX" -v k="$_LGR_LDPMAX:$pw" \
      '$2 == s && $3 == n && $4 == g && $5 == h && $6 == m \
       && (($7 !~ /^full (protected:|over-max:)/ && $7 !~ / protected:/) || $8 == k) {c = $7} END {print c}' "$st/delta.tsv" 2>/dev/null)
  fi
  if [ -n "$cls" ]; then :
  elif ! command -v patch_same >/dev/null 2>&1; then _lgt_log "$slug#$n @$h12: bin/lib/patch-same.sh not loaded; full review"; return 0
  elif [ -z "$project" ] || [ ! -d "$repo/.git" ]; then _lgt_log "$slug#$n @$h12: no checkout at $repo; full review"; return 0
  elif ! patch_same_fetch "$repo" "$ph" "$head"; then _lgt_log "$slug#$n @$h12: fetch of ${ph:0:12}/$h12 failed; full review"; return 0
  elif [ "$ld" = 1 ]; then
    cls=$(ld_classify "$repo" origin/main "$ph" "$head" "$slug" "$pw")
    # Only answers git settled are cached; a knob or read that failed is asked again.
    case "$cls" in
      "full protected:"*|"full over-max:"*|"delta "*" protected:"*)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$ph" "$head" "$_LGR_LDMAX" "$cls" "$_LGR_LDPMAX:$pw" >> "$st/delta.tsv" ;;
      "replay "*|"delta "*|"full binary"|"full knob-off")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$ph" "$head" "$_LGR_LDMAX" "$cls" >> "$st/delta.tsv" ;;
    esac
  elif how=$(patch_same "$repo" origin/main "$ph" "$head"); then cls="replay $how"
  else _lgt_log "$slug#$n @$h12: patch changed since ${ph:0:12}; full review"; return 0
  fi
  case "$cls" in
    "replay "*)
      how=${cls#replay }
      tok="${LEAD_VERDICT_TOKEN_FILE:-${HOME:-}/.config/cromford/lead-verdict-token}"
      if [ ! -r "$tok" ]; then
        _lgt_log "$slug#$n @$h12: since ${ph:0:12}: $cls; no lead token on this box, so review_one's own replay decides"
        return 0
      fi
      box="${JOBS_BOX:-}"; [ -n "$box" ] || box=$(local_box_name 2>/dev/null)
      prc=0; out=$("$root/bin/lead-verdict.sh" post "$slug" "$n" "$head" "$pw" --source lead --reviewer "box:${box:-unknown}" \
        --note "lead-replay:${ph:0:12} how:$how" 2>&1) || prc=$?
      case "$prc" in
        0|4|5)
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y%m%d)" replay "$slug" "$n" "$head" \
            "from=${ph:0:12} how=$how" >> "$st/modes.tsv" 2>/dev/null || true
          _lgt_log "$slug#$n @$h12: lead $pw replayed from ${ph:0:12} (how:$how, post rc $prc); no review"
          return 12 ;;
      esac
      _lgt_log "$slug#$n @$h12: lead $pw replay from ${ph:0:12} not recorded (post rc $prc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)); held"
      return 11 ;;
    "delta "*)
      if [ "$pw" != BLOCK ]; then
        LG_MODE=delta
        _lgt_log "$slug#$n @$h12: since ${ph:0:12}: $cls; LG_MODE=delta (lead $pw, verdict row #$pid)"
      fi ;;
    *) _lgt_log "$slug#$n @$h12: since ${ph:0:12}: ${cls}; a full lead review" ;;
  esac
  return 0
}
