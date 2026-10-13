#!/bin/bash
# tests/review-autopilot-replay.bh-2310-test.sh — bin/review-autopilot.sh REPLAYS
# its verdict onto a head whose own patch did not change (BH-2310).
#
# The REAL lane in a scratch $HARNESS with the review-autopilot.bh-1066 rig (gh,
# agent-call and beat stubbed), and a REAL git fixture: a bare remote plus the
# hub checkout at $REPOS_ROOT/p1.
#
#   P1  first head R: 1 agent call, key `reviewed … verdict=MERGE` + `sha=<full R>`,
#       1 post, cap 1
#   P2  a fix round that only merged main: 0 new calls, 0 new posts, the cap
#       unchanged, the new head's key carries the SAME verdict in the shape
#       mc_autopilot_verdict used to read (BH-1951: it reads rows now, not this file)
#   P3  a real change on top: exactly 1 new call
#   P4  no checkout on this box: the moved head is reviewed (fail closed)
# Run from anywhere: bash tests/review-autopilot-replay.bh-2310-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
DAY=$(date -u -d "@$NOW" '+%Y%m%d')
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$H/env/global.env"
# BH-1510.1: this lane's model is a model_routes row, read through review_model;
# this worker-less box carries the resolver's cache of #1507's table.
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/patch-same.sh" "$H/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1

STATE="$H/state/review-autopilot"
CNTF="$STATE/count-p1-$DAY"
RLOG="$H/logs/review-autopilot.log"
ALOG="$H/logs/ALERTS.log"

# The one open PR every tick sees: harness-authored, non-draft, a day old.
pulls_for() { jq -n --arg sha "$1" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"; }

# --- the stubs --------------------------------------------------------------
# Every gh call is recorded and every posted comment is kept, so "did this tick
# post, how many times, and what bytes" is a fact about the run.
#
#   $T/gh-comment-fails          -> `gh pr comment` exits 1 and posts NOTHING
#   $T/gh-comment-lands-nonzero  -> it POSTS and THEN exits 1 (defect 3)
#   $T/gh-api-comments-fails     -> the issue-comments read exits 1
#   $T/gh-pulls-fails            -> the open-PR list fails on EVERY rung it has
#                                   (the REST pulls page AND the per-author
#                                   `gh pr list` fallback bin/lib/gh-pr-list.sh
#                                   drops to). Failing only the REST page is not
#                                   a failed list — the fallback then answers
#                                   "no open PRs", which is a different fact.
#   $T/comments.json             -> what the comments read answers (else [])
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  if [ -f "$T/gh-comment-fails" ]; then
    echo "gh: the comment could not be posted (HTTP 502)" >&2; exit 1
  fi
  cat "$BF" >> "$T/posted.txt"; echo post >> "$T/post-count.txt"
  # The shape that made this ticket: the comment IS on the PR and gh still
  # exits nonzero (a 502 on the response read, a token that expired after the
  # write). The caller cannot tell the two failures apart from the rc alone.
  [ -f "$T/gh-comment-lands-nonzero" ] && { echo "gh: HTTP 502 reading the response" >&2; exit 1; }
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = list ] && [ -f "$T/gh-pulls-fails" ]; then
  echo "gh: HTTP 502" >&2; exit 1
fi
case "$*" in
  api\ repos/o/p1/issues/7/comments*)
    [ -f "$T/gh-api-comments-fails" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [ -f "$T/comments.json" ]; then cat "$T/comments.json"; else printf '[]\n'; fi ;;
  *repos/o/p1/pulls/7)
    # The per-PR read the drain earns its delete with, answered the way
    # bin/lib/gh-rest.sh drives it (`gh api -i`: status line, blank line, body).
    # It is a DIFFERENT fact from the open-PR list — the list can come back
    # short with rc 0, this cannot. `gh-pulls-fails` takes the whole pulls
    # endpoint down with it, and a 5xx is rc 75 ("we could not look").
    if [ -f "$T/gh-pulls-fails" ] || [ -f "$T/gh-pr7-fails" ]; then
      printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0
    fi
    printf 'HTTP/2.0 200 OK\r\n\r\n'
    if [ -f "$T/pr-7.json" ]; then cat "$T/pr-7.json"; else printf '{"number":7,"state":"open","merged_at":null}\n'; fi ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    # TEST-CHANGE (BH-782): the open-PR list is a REST read through
    # bin/lib/gh-rest.sh now (`gh api -i -X GET ...`), so the argv carries -i
    # and the answer needs the status line the library parses. `gh-pulls-fails`
    # still takes the list down — as the 502 the library classifies, which is
    # the same fact the bare rc 1 was.
    if [ -f "$T/gh-pulls-fails" ]; then
      case "$*" in
        *" -i "*) printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0 ;;
      esac
      echo "gh: HTTP 502" >&2; exit 1
    fi
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# THE BILLABLE CALL. Its argv is appended (so the count of spends is a file) and
# its exit code is whatever $T/agent-rc says — the whole point of item 1.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
cat "$T/model-out" > "$5"
exit "$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
EOF
} > "$H/bin/agent-call.sh"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "${1:-}" >> "$T/beats.txt"
exit 0
EOF
} > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

GOOD_REVIEW='Nothing load-bearing was deferred; the diff does what the body says.

VERDICT: MERGE — reads fine'

PT=6
RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          REVIEW_AUTOPILOT_POST_TRIES="$PT" REPOS_ROOT="${REPOS:-$T/repos}" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
# `wc -l <`, not `grep -c`: grep exits 1 on a file with no matches, and the
# `|| echo 0` that would cover that prints a SECOND count.
CALLS()  { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS()  { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
CAP()    { cat "$CNTF" 2>/dev/null || echo 0; }
K1()     { head -1 "$KEY" 2>/dev/null; }
# Lines, never `grep -c` (same reason), and fixed-string so a scratch path full
# of dots cannot match something it does not equal.
COUNTF() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
APV() { ( HARNESS="$H" PATH="$T/fakebin:$PATH"
          # shellcheck source=/dev/null
          . "$H/bin/lib/gh-pr-list.sh"
          # shellcheck source=/dev/null
          . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
          mc_autopilot_verdict o/p1 7 'o/p1#7' "$1" ) 2>/dev/null; }
RESET()  { scratch_rm "$STATE"
           PT=6
           printf '0\n' > "$T/agent-rc"
           printf '%s\n' "$GOOD_REVIEW" > "$T/model-out"
           : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
           : > "$T/gh-calls.txt"; : > "$T/beats.txt"; : > "$RLOG"; : > "$ALOG"
           rm -f "$T/gh-comment-fails" "$T/gh-comment-lands-nonzero" \
                 "$T/gh-api-comments-fails" "$T/gh-pulls-fails" "$T/comments.json" \
                 "$T/gh-pr7-fails" "$T/pr-7.json"; }


# --- the git side -----------------------------------------------------------
W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }
fixture() {
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos" 2>/dev/null
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
  mkdir -p "$T/repos"; git clone -q "$T/remote.git" "$T/repos/p1"
}
main_merge() {
  w checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit m >/dev/null; push main
  w checkout -q pr; w merge -q --no-edit main >/dev/null 2>&1; push pr; w rev-parse HEAD
}
KEYOF() { printf '%s/o-p1-7-%s' "$STATE" "${1:0:12}"; }
: > "$T/run.log"

# ---- P1..P3
RESET; fixture; pulls_for "$R"; RUN
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && [ "$(CAP)" = 1 ] && ok || bad "P1 calls=$(CALLS) posts=$(POSTS) cap=$(CAP)"
[[ "$(head -1 "$(KEYOF "$R")" 2>/dev/null)" =~ ^reviewed\ .*\ verdict=MERGE$ ]] && ok || bad "P1 key: $(head -1 "$(KEYOF "$R")" 2>/dev/null)"

[ "$(sed -n 2p "$(KEYOF "$R")" 2>/dev/null)" = "sha=$R" ] && ok || bad "P1 the key must record the full reviewed sha (#2386 note 4): '$(sed -n 2p "$(KEYOF "$R")" 2>/dev/null)'"

H1=$(main_merge); pulls_for "$H1"; RUN
[ "$(CALLS)" = 1 ] && ok || bad "P2 a main-merge-only head must buy NO review (0 new agent calls), calls=$(CALLS)"
[ "$(POSTS)" = 1 ] && ok || bad "P2 a replay posts nothing, posts=$(POSTS)"
[ "$(CAP)" = 1 ] && ok || bad "P2 a replay does not charge the daily cap, cap=$(CAP)"
K=$(KEYOF "$H1")
[[ "$(head -1 "$K" 2>/dev/null)" =~ ^reviewed\ .*\ verdict=MERGE$ ]] && ok || bad "P2 the new head's key must carry the same verdict: '$(head -1 "$K" 2>/dev/null)'"
[ "$(sed -n 2p "$K" 2>/dev/null)" = "replayed_from=${R:0:12} how=main-merge" ] && ok || bad "P2 the replay must be recorded: '$(sed -n 2p "$K" 2>/dev/null)'"
[ "$(sed -n 3p "$K" 2>/dev/null)" = "sha=$H1" ] && ok || bad "P2 the replayed key records its own full sha: '$(sed -n 3p "$K" 2>/dev/null)'"
# TEST-CHANGE (BH-1951): the replayed key FILE is the lane's own ledger now; the
# conductor reads the box row the replay POSTs (none in this worker-less rig).
# tests/verdict-files-retired.bh-1951-test.sh A4 pins the replay's row end to end.
[ -z "$(APV "$H1")" ] && ok || bad "P2 the replayed key file alone must not be read by the conductor: '$(APV "$H1")'"
grep -q "verdict REPLAYED from ${R:0:12} (MERGE): own patch unchanged (main-merge)" "$RLOG" && ok || bad "P2 the log must say it replayed: $(tail -2 "$RLOG")"

edit 20 'line 20 REAL FIX'; H2=$(commit fix); push pr; pulls_for "$H2"; RUN
[ "$(CALLS)" = 2 ] && ok || bad "P3 a real change must buy exactly 1 new review, calls=$(CALLS)"

# ---- P4: no checkout here -> the moved head is reviewed
RESET; fixture; pulls_for "$R"; RUN
H1=$(main_merge); pulls_for "$H1"; REPOS="$T/no-repos" RUN
[ "$(CALLS)" = 2 ] && ok || bad "P4 with no checkout the moved head must be reviewed (fail closed), calls=$(CALLS)"

echo "review-autopilot-replay.bh-2310: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
