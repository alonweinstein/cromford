#!/bin/bash
# gh-identity: app-token
# bin/needs-human-hold.sh <project> <issue> <fp> <action> <source> — places a
# needs-human hold on an issue (BH-3433; the placer is BH-3443). A review block
# whose only open finding is a step a person has to take is parked on the
# ticket instead of being rebuilt: BH-3348 paid $6.53 in rebuilds of a block
# only the hub could clear.
#
# ORDER, and each step is the reason for the next:
#   0. argv: 5 args, a numeric issue, a hex fp; otherwise usage and exit 2.
#   1. the kill switch `lane_switch needs-human-hold-off` -> log, exit 0.
#   2. an issues board only (board_prefix "-", repo owner/name) -> else exit 0.
#   3. bin/lib/hold.sh, needs-human.sh and gh-app-auth.sh, fail-open; no
#      hold_check -> exit 75, nothing posted.
#   4. the pre-read (hold_check): unreadable -> 75. Already stopped by state
#      (closed, de-labelled, the `hold` label) -> exit 0 with no marker, since
#      no comment could win over it. Already waiting on a human with THIS fp
#      (the newest marker carries nh-fp:<fp>) -> exit 0: one marker per ask.
#   5. the action is flattened and any token in it masked (gh[pousr]_,
#      github_pat_, sk-; a prefix inside a word is prose, not a token).
#   6. POST the marker as the App. A failed POST -> one alert, exit 1.
#   7. re-read: anything but hold:waiting-on-human -> one alert, exit 1. A
#      retry is safe: step 4 finds the fp and posts nothing twice.
#   8. the one ask, `[needs-human] <p>#<n> needs a human: <action> — <url>`,
#      only now; exit 0.
# Exit: 0 placed / already held / switch on / not an issues board / already
# stopped; 1 could not place; 2 usage; 75 thread unreadable.
#
# NO ROOT DEFAULT: the root is $HARNESS, then $H. With neither (the contract
# suite runs it that way) there is no switch to read and no log to write.
usage() { echo "usage: needs-human-hold.sh <project> <issue> <fp> <action> <source>" >&2; exit 2; }
[ "$#" -eq 5 ] || usage
P="$1" N="$2" FP="$3" ACT="$4" SRC="$5"
case "$N" in ''|*[!0-9]*) usage ;; esac
case "$FP" in ''|*[!0-9a-f]*) usage ;; esac

BIN=$(cd "$(dirname "$0")" && pwd)
H="${HARNESS:-${H:-}}"
[ -n "$H" ] && export HARNESS="$H"
nhh_log() {
  echo "needs-human-hold: $*" >&2
  [ -n "$H" ] && [ -d "$H/logs" ] && printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$P" "$*" >> "$H/logs/needs-human.log"
  return 0
}
alert() { "$BIN/alert-line.sh" --project "$P" "$1" >/dev/null 2>&1 </dev/null; }

# 1. the kill switch
if [ -n "$H" ]; then
  # shellcheck source=/dev/null
  . "$BIN/lib/lane-switch.sh" 2>/dev/null
  if command -v lane_switch >/dev/null 2>&1 && lane_switch needs-human-hold-off; then
    nhh_log "switch needs-human-hold-off is on — no hold placed on $P#$N"; exit 0
  fi
fi

# 2. the board
bp=$("$BIN/fleet-conf.sh" "$P" board_prefix 2>/dev/null)
slug=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null)
case "$bp:$slug" in
  -:*/*) ;;
  *) nhh_log "$P is not an issues board — nothing placed"; exit 0 ;;
esac

# 3. the libraries
for l in hold needs-human gh-app-auth; do
  # shellcheck source=/dev/null
  [ -r "$BIN/lib/$l.sh" ] && . "$BIN/lib/$l.sh" 2>/dev/null
done
command -v hold_check >/dev/null 2>&1 || { nhh_log "bin/lib/hold.sh did not load — nothing posted on $slug#$N"; exit 75; }
command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
done_auth() { command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; return 0; }

# 4. the pre-read
out=$(hold_check "$slug" "$N"); rc=$?
why="${out#*$'\t'}"
case "$rc" in
  2) nhh_log "thread of $slug#$N unreadable ($why) — nothing posted"; done_auth; exit 75 ;;
  1)
    case "$why" in
      hold:waiting-on-human*)
        raw=$(gh api --paginate "repos/$slug/issues/$N/comments?per_page=100" 2>/dev/null) \
          || { nhh_log "comments of $slug#$N unreadable — nothing posted"; done_auth; exit 75; }
        last=$(printf '%s' "$raw" | jq -rs '[ .[] | if type == "array" then .[] else . end
                 | select(((.body // "") | tostring) | test("(?m)^NEEDS-HUMAN:")) ]
                 | sort_by(.created_at // "") | last | (.body // "")' 2>/dev/null) \
          || { nhh_log "comments of $slug#$N did not parse — nothing posted"; done_auth; exit 75; }
        case "$last" in *"${NH_FP_TAG:-nh-fp}:$FP"*)
          nhh_log "$P#$N already held for ${NH_FP_TAG:-nh-fp}:$FP"; done_auth; exit 0 ;;
        esac ;;
      # A person's HOLD or ABANDON: the ask still goes out, and their word
      # outlives the later done (bin/lib/hold.sh's recency law).
      hold:comment*|hold:title*|hold:body*|abandon:*) ;;
      # A state, not a comment (closed, label-absent, the hold label): no
      # marker could win over it, so posting one could only fail step 7.
      *) nhh_log "$P#$N already stopped ($why) — no marker"; done_auth; exit 0 ;;
    esac ;;
esac

# 5. mask
# A token starts a word (so "task-list" is prose) and runs at least 16 characters.
ACT=$(printf '%s' "$ACT" | tr '\n\t' '  ' \
  | sed -E 's/(^|[^A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{16,}/\1\2[masked]/g' | cut -c1-300)

# 6. post the marker
BODY="${NH_MARKER_PREFIX:-NEEDS-HUMAN:} $ACT

Builds of this ticket are paused until a person does the step above. We can't do it from a build box. (Raised by $SRC.)
When it's done, reply with a comment that starts \`${NH_DONE_PREFIX:-HUMAN-STEP-DONE:}\` and says what you ran and what it printed. A \`RESUME\` comment also lifts the pause.
<!-- ${NH_FP_TAG:-nh-fp}:$FP -->"
if ! jq -nc --arg b "$BODY" '{body:$b}' | gh api -X POST "repos/$slug/issues/$N/comments" --input - >/dev/null 2>&1; then
  nhh_log "the marker POST on $slug#$N failed"
  alert "[needs-human] could not place hold on $P#$N"; done_auth; exit 1
fi

# 7. verify
out=$(hold_check "$slug" "$N")
case "$out" in
  "held	hold:waiting-on-human"*) ;;
  *) nhh_log "posted on $slug#$N but the thread reads '${out//$'\t'/ }' — not placed"
     alert "[needs-human] could not place hold on $P#$N"; done_auth; exit 1 ;;
esac

# 8. the one ask
alert "[needs-human] $P#$N needs a human: $ACT — https://github.com/$slug/issues/$N"
nhh_log "placed on $slug#$N (${NH_FP_TAG:-nh-fp}:$FP, from $SRC)"
done_auth
exit 0
