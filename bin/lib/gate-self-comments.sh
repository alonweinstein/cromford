#!/bin/bash
# bin/lib/gate-self-comments.sh — A LANE'S OUTPUT IS NEVER ITS OWN INPUT, for the
# GitHub-Issues gate fingerprint (BH-2133, 2026-09-24). Sourced by
# bin/triage-gate.sh; defines functions only (and sources bin/lib/harness-self.sh,
# which resolves its two knobs), nothing runs on source.
#
# THE LOOP. On a GitHub-Issues board the gate fingerprint carries each ai-build
# issue's comment COUNT and updatedAt, and bin/triage-gate.sh had no self-write
# absorption on that arm (the in-app arm has bin/gate-selfwrite.py). So a triage
# shard's own note on a ticket ("still blocked, nothing edited", posted as
# cromford-board[bot]) moved the row, the next tick answered `RUN
# board-changed`, the webhook delivery of the same comment answered `RUN
# event-wake` with that key in the diff, the per-ticket shard fingerprint
# (bin/lib/triage-shards-lib.sh _tsh_fp_pending, which reads this row) moved, and
# another paid shard posted another note. #1389 collected six of them in one
# afternoon; the board was paused at 20:18Z on 2026-09-24 to stop it.
#
# THE RULE. A row whose ONLY movement since the consumed fingerprint is new
# comments, every one of them written by one of the harness's OWN Apps, keeps
# the consumed row's `comments` and `updatedAt`. Then all three readers above
# see "unchanged" and nothing is bought. Everything else still wakes the tick,
# and every doubt does:
#   - a comment by anyone who is not one of our Apps (HARNESS_SELF_APPS, see
#     bin/lib/harness-self.sh): a person, the PAT login (operator is also the operator's
#     own hand), and ANY other bot — intercom[bot] relaying a client is a client;
#   - a comment of anyone else's EDITED since the consumed row (updated_at after
#     it, even though it was created before): an edit is a client turn;
#   - an edit to the issue itself — body, labels, assignees, milestone — seen as
#     a change of the per-issue content hash (`meta`, computed in
#     bin/triage-gate.sh from the same list response) since the consumed
#     fingerprint. This is what catches an edit made WHILE a session was in
#     flight, before its note: the note's timestamp would hide it;
#   - no consumed content hash to compare with (the first tick after this);
#   - a state or title change;
#   - a count that does not add up to the new comments found (a deletion);
#   - an updatedAt more than GATE_SELF_SLACK_S past the newest of our comments;
#   - a thread that could not be read, or more than 300 comments to read.
#
# A READ WE COULD NOT MAKE IS A FAIL-OPEN (the tick runs, as it did before this
# file), and a streak of them is counted in state/<p>.gate-self.failopen: at
# GATE_SELF_FAILOPEN_ALERT consecutive ticks ONE ALERTS.log line says so, since a
# rate-limited box would otherwise buy sessions quietly. A tick whose reads
# succeed resets it.
#
# THE COST. One REST read (`GET issues/<n>/comments?since=`) per row that moved,
# ONCE: the verdict is remembered in state/<project>.gate-self.json keyed on the
# live and consumed (count, updatedAt, content hash), so an absorbed row costs
# nothing on the next tick. At most GATE_SELF_MAX_ROWS rows are read per tick;
# the rest keep their live values and wake the tick, as before.
#
# flags/gate-self-absorb-off (or the `switch.gate-self-absorb-off` settings
# row), or GATE_SELF_ABSORB=0, is the behaviour before
# this file, byte for byte: no read, no memo, every bump wakes.

# shellcheck source=bin/lib/harness-self.sh
[ -r "${BASH_SOURCE[0]%/*}/harness-self.sh" ] && . "${BASH_SOURCE[0]%/*}/harness-self.sh"
# shellcheck source=bin/lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }

# _gsc_is_on <harness> — rc 0 when absorption is enabled.
_gsc_is_on() {
  [ "${GATE_SELF_ABSORB:-1}" = 0 ] && return 1
  [ -n "${1:-}" ] && HARNESS="$1" lane_switch gate-self-absorb-off file && return 1
  return 0
}

# _gsc_failopen <harness> <project> <fail|ok> — the streak counter (I3).
_gsc_failopen() {
  local h="$1" p="$2" f="$1/state/$2.gate-self.failopen" n thr
  if [ "$3" = ok ]; then printf '0\n' > "$f" 2>/dev/null; return 0; fi
  n=$(cat "$f" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); printf '%s\n' "$n" > "$f" 2>/dev/null
  thr="${GATE_SELF_FAILOPEN_ALERT:-6}"; case "$thr" in ''|*[!0-9]*) thr=6 ;; esac
  if [ "$thr" -gt 0 ] && [ "$n" -eq "$thr" ]; then
    mkdir -p "$h/logs" 2>/dev/null
    printf '%s [%s] gate-self-comments: %s consecutive ticks could not read a comment thread (last HTTP %s) and failed OPEN, so each ran a triage session a bot note alone would not have bought. Check the GitHub budget for this box (bin/lib/gh-budget.sh) and logs/%s.log; the count resets on the first tick whose reads succeed.\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$p" "$n" "${GH_REST_STATUS:-000}" "$p" >> "$h/logs/ALERTS.log"
  fi
  return 0
}

# gate_self_absorb <harness> <project> <owner/repo> <live-issues-json> <stored-gate-file> [live-meta-json]
#   stdout: the issues array, with harness-only comment bumps replaced by the
#   stored row's comments/updatedAt. On ANY internal failure it prints the live
#   array unchanged, which is exactly the fingerprint the gate computed before
#   BH-2133 (fail-open: a RUN, never a SKIP off a guess).
gate_self_absorb() {
  local h="${1:-}" p="${2:-}" slug="${3:-}" live="${4:-}" gatef="${5:-}" lmeta="${6:-}"
  local memof cands memo='{}' newmemo='{}' out n bc bu bm lc lu lm since acc page t rc verdict max slack apps key
  local failed=0 read_ok=0 mt
  printf '%s' "$live" | jq -e 'type == "array"' >/dev/null 2>&1 || { printf '%s\n' "$live"; return 0; }
  if ! _gsc_is_on "$h" || [ ! -s "$gatef" ] || [ -z "$slug" ] || ! command -v gh_rest >/dev/null 2>&1 \
     || ! command -v harness_self_apps_json >/dev/null 2>&1; then
    printf '%s\n' "$live"; return 0
  fi
  apps=$(harness_self_apps_json)
  # An empty allowlist makes nothing ours: no read, today's behaviour.
  [ -n "$apps" ] && [ "$apps" != '[]' ] || { printf '%s\n' "$live"; return 0; }
  printf '%s' "$lmeta" | jq -e 'type == "object"' >/dev/null 2>&1 || lmeta='{}'
  memof="$h/state/$p.gate-self.json"
  [ -s "$memof" ] && memo=$(jq -c 'if type == "object" then . else {} end' "$memof" 2>/dev/null) || true
  [ -n "$memo" ] || memo='{}'
  max="${GATE_SELF_MAX_ROWS:-10}"; case "$max" in ''|*[!0-9]*) max=10 ;; esac
  slack="${GATE_SELF_SLACK_S:-5}"; case "$slack" in ''|*[!0-9]*) slack=5 ;; esac

  # Candidates: same number, same state, same title, count strictly UP, and the
  # SAME content hash in the consumed and the live fingerprint (B1). TSV:
  # number, stored count, stored updatedAt, stored hash, live count, live updatedAt, live hash.
  cands=$(jq -r --slurpfile g "$gatef" --argjson lm "$lmeta" '
      (($g[0] // {}) | if type == "object" then . else {} end) as $G
      | (($G.issues // []) | map(select(type == "object") | {key: (.number | tostring), value: .}) | from_entries) as $old
      | (($G.meta // {}) | if type == "object" then . else {} end) as $om
      | .[] | select(type == "object") | . as $n
      | ($n.number | tostring) as $k
      | ($old[$k] // null) as $o
      | select($o != null)
      | select($o.state == $n.state and $o.title == $n.title)
      | select(($o.comments | type) == "number" and ($n.comments | type) == "number" and $n.comments > $o.comments)
      | select(($o.updatedAt | type) == "string" and ($n.updatedAt | type) == "string")
      | select(($om[$k] | type) == "string" and $om[$k] == $lm[$k])
      | [$k, ($o.comments | tostring), $o.updatedAt, $om[$k], ($n.comments | tostring), $n.updatedAt, $lm[$k]] | @tsv
    ' <<<"$live" 2>/dev/null) || { printf '%s\n' "$live"; return 0; }

  out="$live"
  t=$(mktemp "${TMPDIR:-/tmp}/gate-self.XXXXXX") || { printf '%s\n' "$live"; return 0; }
  while IFS=$'\t' read -r n bc bu bm lc lu lm; do
    [ -n "$n" ] || continue
    case "$n" in *[!0-9]*) continue ;; esac
    verdict=""
    key=$(jq -nc --argjson bc "$bc" --arg bu "$bu" --arg bm "$bm" --argjson lc "$lc" --arg lu "$lu" --arg lm "$lm" \
            '{base: [$bc, $bu, $bm], live: [$lc, $lu, $lm]}')
    # Remembered: the exact same (live, stored) pair was absorbed on an earlier tick.
    if jq -e --arg n "$n" --argjson k "$key" '.[$n] == $k' <<<"$memo" >/dev/null 2>&1; then
      verdict=self
    elif [ "$max" -gt 0 ]; then
      max=$((max - 1))
      # Every comment on #n UPDATED at or after the stored updatedAt, up to 3 pages.
      acc='[]'; since="$bu"; verdict="read"
      for page in 1 2 3; do
        rc=0
        gh_rest GET "repos/$slug/issues/$n/comments" -f since="$since" -F per_page=100 -F page="$page" > "$t" 2>/dev/null || rc=$?
        if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then verdict=""; failed=1; break; fi
        acc=$(jq -c --slurpfile pg "$t" '. + $pg[0]' <<<"$acc" 2>/dev/null) || { verdict=""; break; }
        [ "$(jq 'length' "$t")" -lt 100 ] && break
        [ "$page" = 3 ] && verdict=""
      done
      if [ "$verdict" = read ]; then
        read_ok=1
        # Created strictly AFTER the stored updatedAt (the comment that set that
        # stamp is already counted), all ours, exactly the count delta; no one
        # else's comment updated after the stored stamp (N1: an edit to an old
        # comment is a turn); and the issue's updatedAt no later than the newest
        # of ours plus the slack.
        verdict=$(jq -r --arg bu "$bu" --argjson d "$((lc - bc))" --arg lu "$lu" --argjson s "$slack" --argjson apps "$apps" \
          "$HARNESS_SELF_JQ_DEF"'
            def ep: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
            [ .[] | select(type == "object") ] as $all
            | [ $all[] | select(((.created_at // "") | tostring) > $bu) ] as $new
            | [ $all[] | select(hs_ours($apps) | not) | select((((.updated_at // .created_at) // "") | tostring) > $bu) ] as $theirs
            | if ($theirs | length) > 0 then "human"
              elif ($new | length) != $d or $d < 1 then "human"
              elif ([ $new[] | hs_ours($apps) ] | all) | not then "human"
              elif ((($lu | ep) - ([ $new[] | ((.updated_at // .created_at) | ep) ] | max)) > $s) then "human"
              else "self" end' <<<"$acc" 2>/dev/null) || verdict=""
      fi
    fi
    if [ "$verdict" = self ]; then
      out=$(jq -c --argjson n "$n" --argjson bc "$bc" --arg bu "$bu" \
              'map(if type == "object" and .number == $n then .comments = $bc | .updatedAt = $bu else . end)' <<<"$out" 2>/dev/null) \
        || { rm -f "$t"; printf '%s\n' "$live"; return 0; }
      newmemo=$(jq -c --arg n "$n" --argjson k "$key" '. + {($n): $k}' <<<"$newmemo" 2>/dev/null) || newmemo='{}'
    fi
  done <<<"$cands"
  rm -f "$t"
  # The streak: a failed read this tick counts; a tick whose reads all
  # succeeded resets it; a tick with nothing to read leaves it alone.
  if [ "$failed" = 1 ]; then _gsc_failopen "$h" "$p" fail
  elif [ "$read_ok" = 1 ]; then _gsc_failopen "$h" "$p" ok; fi
  # Only the rows absorbed THIS tick are remembered, so the memo never outgrows
  # the board. A unique temp file: two gate runs of one project cannot collide.
  if mt=$(mktemp "$memof.XXXXXX" 2>/dev/null); then
    printf '%s\n' "$newmemo" > "$mt" && mv -f "$mt" "$memof" 2>/dev/null || rm -f "$mt"
  fi
  printf '%s\n' "$out"
}
