#!/bin/bash
# tests/utilization-tickets.bh-3988-test.sh — BH-4009 (BH-3988.1): the tickets
# section bin/lib/utilization/section-tickets.sh, read through the REAL
# collector bin/utilization-push.sh and the real util_verdict.
#
# A scratch $HARNESS (symlink copy of bin/ and catalog/) runs the shipped lane.
# Stubbed: fleet-conf.sh (ghp on the GitHub-Issues lane, app on an in-app
# board), internal-token-for.sh, concurrency-plan.sh (FAKE_CAP), `gh` on PATH
# (gh_rest's `gh api -i -X GET <path>` form, answered from $GH_FIX/<path with
# every non-alphanumeric as _>.json, every call appended to $T/gh.calls) and
# curl (the jobs worker, the in-app board, PUT /api/utilization recorded to
# $H/puts.jsonl).
#
#   T1  Blocked-by: an open in-list blocker, a closed out-of-list blocker (not
#       blocked), a 404 out-of-list blocker (blocked); mid-line prose and a
#       cross-repo ref are not blockers; an issue-list PR item is dropped
#   T2  a HOLD comment: held 1, held_complete true
#   T3  UTIL_HOLD_READS_MAX=2 over 5 candidates: 2 comment reads,
#       held_complete false, the unchecked ones counted ready
#   T4  an open PR on ticket/gp-6 and a running GP-7 build take them out of ready
#   T5  in-app: waitingOn client / triageVerdict needs_clarification parked,
#       blocked:true blocked, done not counted, held unmeasured, rest ready
#   T6  gh rate limited (exit 75): null buckets, verdict unknown, NOT starved
#   T7  the in-app ticket read fails: app all null, verdict unknown
#   T8  an empty board with free slots is starved; at the cap with ready, saturated
#   T9  no POST, no issue create, in any gh call of the whole suite
#   T10 a running-jobs read at its 500 cap: ready null
#   T11 UTIL_HOLD_READS_MAX=abc behaves as 30
#   T12 an unreadable hold thread: held and ready null, verdict unknown
#   T13 an issue list whose third page is full: capped, null, never a count
#   T14 the knob from a settings row through lib_env_apply
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-tickets.bh-3988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

SECTION_SRC="$DIR/bin/lib/utilization/section-tickets.sh"
VERDICT_SRC="$DIR/bin/lib/utilization.sh"
for f in "$SECTION_SRC" "$VERDICT_SRC" "$DIR/bin/utilization-push.sh"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "utilization-tickets: 0 passed, 1 failed"; exit 1; }
done

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$T/stub" "$T/env"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh" "$H/bin/internal-token-for.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-} ${2:-}" in
  "--projects "*) printf 'ghp\napp\n' ;;
  "ghp board_prefix") echo - ;;
  "ghp repo") echo acme/ghp ;;
  "ghp prod") echo - ;;
  "app board_prefix") echo /api/board ;;
  "app repo") echo acme/app ;;
  "app prod") echo https://app.test ;;
  *) exit 1 ;;
esac
SH
cat > "$H/bin/internal-token-for.sh" <<'SH'
#!/bin/bash
[ "${1:-}" = app ] && echo tok
SH
cat > "$H/bin/concurrency-plan.sh" <<'SH'
#!/bin/bash
printf '[{"project":"%s","effective":"%s","bound_by":"fixture"}]\n' "$1" "${FAKE_CAP:-4}"
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
[ "${1:-}" = api ] || exit 1
shift; M=GET; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X) M="$2"; shift 2 ;;
    -H|-f|-F) shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
hdr() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n' "$1"; }
if [ "${FAKE_GH_RL:-}" = 1 ]; then hdr "403 Forbidden"; echo '{"message":"API rate limit exceeded for installation"}'; exit 1; fi
[ "$M" = GET ] || { hdr "422 Unprocessable"; echo '{}'; exit 1; }
F="$GH_FIX/$(printf '%s' "$P" | tr -c 'A-Za-z0-9' '_').json"
case "$P" in
  *"/comments?"*)
    if [ -n "${FAKE_COMMENTS_FAIL:-}" ] && [[ "$P" == */issues/"$FAKE_COMMENTS_FAIL"/comments* ]]; then
      hdr "500 Internal"; echo '{}'; exit 1
    fi
    hdr "200 OK"; if [ -f "$F" ]; then cat "$F"; else echo '[]'; fi; exit 0 ;;
  *"/issues?labels="*)
    if [ "${FAKE_FULL_PAGES:-}" = 1 ]; then
      hdr "200 OK"
      jq -nc '[range(0;100)|{number:(1000+.),title:"t",body:"",state:"open",labels:[{name:"ai-build"}]}]'
      exit 0
    fi ;;
esac
if [ -f "$F" ]; then hdr "200 OK"; cat "$F"; exit 0; fi
hdr "404 Not Found"; echo '{"message":"Not Found"}'; exit 1
SH
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
M=GET; D=""; U=""; F=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) D="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -sf|-fs|-f) F=1; shift ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
case "$U" in
  https://app.test/api/board/boards)
    echo '[{"id":"b1"}]'; exit 0 ;;
  https://app.test/api/board/boards/b1/tickets)
    [ "${FAKE_BOARD_FAIL:-}" = 1 ] && exit 22
    cat "$BOARD_FIX"; exit 0 ;;
  https://*) exit 22 ;;
esac
P="${U#http://jobs.test}"
case "$M $P" in
  "GET /api/jobs?"*)
    if [ -n "${FAKE_JOBS_N:-}" ]; then
      jq -nc --argjson n "$FAKE_JOBS_N" '{jobs:[range(0;$n)|{id:("j"+(.|tostring)),status:"running",kind:"build",ticket_id:("ZZ-"+(.|tostring))}]}'
    else
      jq -nc --argjson t "${FAKE_JOBS:-[\"GP-7\"]}" '{jobs:[$t[]|{id:("j-"+.),status:"running",kind:"build",ticket_id:.}]}'
    fi
    printf '\n200' ;;
  "PUT /api/utilization")
    case "$D" in @*) D=$(cat "${D#@}") ;; esac
    printf '%s\n' "$D" >> "$HARNESS/puts.jsonl"
    printf '{"ok":true}\n200' ;;
  "GET /api/settings")
    if [ -n "${FAKE_SETTINGS:-}" ]; then printf '%s\n200' "$FAKE_SETTINGS"; else printf '{"error":"x"}\n404'; fi ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/internal-token-for.sh" "$H/bin/concurrency-plan.sh" "$T/stub/gh" "$T/stub/curl"

# ── fixtures ────────────────────────────────────────────────────────────────
fx() { printf '%s' "$2" | tr -c 'A-Za-z0-9' '_' | sed "s|^|$1/|; s|$|.json|"; }
iss() { # iss <n> <body>
  jq -nc --argjson n "$1" --arg b "$2" '{number:$n,title:("ticket "+($n|tostring)),body:$b,state:"open",labels:[{name:"ai-build"}]}'
}
D1="$T/gh-default"; mkdir -p "$D1"
{
  echo '['
  iss 1 $'Some context.\n**Blocked-by:** #2 (hard)'; echo ,
  iss 2 $'see Blocked-by: #1 below\nBlocked-by: other/repo#7'; echo ,
  iss 3 'Blocked-by: #99'; echo ,
  iss 4 '- Blocked-by #98'; echo ,
  iss 5 'plain'; echo ,
  iss 6 'plain'; echo ,
  iss 7 'plain'; echo ,
  echo '{"number":50,"title":"a PR","body":"","state":"open","labels":[{"name":"ai-build"}],"pull_request":{"url":"x"}}'
  echo ']'
} > "$(fx "$D1" 'repos/acme/ghp/issues?labels=ai-build&state=open&per_page=100&page=1')"
echo '[{"number":60,"head":{"ref":"ticket/gp-6"}},{"number":61,"head":{"ref":"ticket/gp-60"}}]' \
  > "$(fx "$D1" 'repos/acme/ghp/pulls?state=open&per_page=100&page=1')"
echo '{"number":99,"state":"closed"}' > "$(fx "$D1" 'repos/acme/ghp/issues/99')"
echo '[{"id":501,"user":{"login":"operator","type":"User"},"body":"HOLD: wait for the vendor","created_at":"2026-10-03T10:00:00Z"}]' \
  > "$(fx "$D1" 'repos/acme/ghp/issues/5/comments?per_page=100&page=1')"
echo '[{"number":70,"head":{"ref":"ticket/ap-7"}}]' > "$(fx "$D1" 'repos/acme/app/pulls?state=open&per_page=100&page=1')"

D2="$T/gh-cap"; mkdir -p "$D2"
{ echo '['; for n in 11 12 13 14; do iss "$n" plain; echo ,; done; iss 15 plain; echo ']'; } \
  > "$(fx "$D2" 'repos/acme/ghp/issues?labels=ai-build&state=open&per_page=100&page=1')"
echo '[]' > "$(fx "$D2" 'repos/acme/ghp/pulls?state=open&per_page=100&page=1')"
echo '[]' > "$(fx "$D2" 'repos/acme/app/pulls?state=open&per_page=100&page=1')"

D3="$T/gh-empty"; mkdir -p "$D3"
echo '[]' > "$(fx "$D3" 'repos/acme/ghp/issues?labels=ai-build&state=open&per_page=100&page=1')"
echo '[]' > "$(fx "$D3" 'repos/acme/ghp/pulls?state=open&per_page=100&page=1')"
echo '[]' > "$(fx "$D3" 'repos/acme/app/pulls?state=open&per_page=100&page=1')"

BOARD="$T/board.json"
cat > "$BOARD" <<'JSON'
[
  {"key":"AP-1","status":"todo","waitingOn":"client"},
  {"key":"AP-2","status":"backlog","triage_verdict":"needs_clarification"},
  {"key":"AP-3","status":"todo","blocked":true},
  {"key":"AP-4","status":"Done"},
  {"key":"AP-5","status":"todo","triageVerdict":"ready"},
  {"key":null,"number":6,"status":"in_progress"},
  {"key":"AP-7","status":"todo"}
]
JSON

GH_CALLS="$T/gh.calls"; : > "$GH_CALLS"
# run_lane VAR=val... — the shipped lane from the scratch harness, clean env.
run_lane() {
  rm -f "$H/puts.jsonl"
  : > "$T/gh.run"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_BOX=hub-fixture JOBS_RETRY_SLEEP=0 GH_ETAG=0 \
    GH_CALLS="$T/gh.run" GH_FIX="$D1" BOARD_FIX="$BOARD" "$@" \
    bash "$H/bin/utilization-push.sh" > "$T/lane.out" 2> "$T/lane.err"
  cat "$T/gh.run" >> "$GH_CALLS"
}
tix()  { jq -c --arg p "$1" 'select(.project==$p)|.payload.tickets' "$H/puts.jsonl" 2>/dev/null; }
# TEST-CHANGE (merge with main's BH-4010): the pauses and prs sections add their
# own basis keys, pinned by tests/utilization-pauses-prs.bh-4010-test.sh. This
# drops exactly those two, so every key the tickets and builds sections write is
# still pinned whole, and an unexpected extra key still fails.
basis() { jq -c --arg p "$1" 'select(.project==$p)|.payload.basis|del(.pauses, .prs)' "$H/puts.jsonl" 2>/dev/null; }
verd() { jq -r --arg p "$1" 'select(.project==$p)|.verdict' "$H/puts.jsonl" 2>/dev/null; }

# ── T1 / T2 / T4 / T5: the default fixtures ─────────────────────────────────
run_lane FAKE_CAP=4; rc=$?
eq "T1 lane rc" "$rc" 0
eq "T1 both projects written" "$(tail -n 1 "$H/logs/utilization-push.log" | cut -d' ' -f2-)" "projects=2 written=2 failed=0 deferred=0"
# #1 blocked by open #2; #4 by a 404 #98 (fail toward not-ready); #3's #99 is
# closed; #2's mid-line prose and cross-repo ref block nothing. #6 has a PR, #7
# a running build; #5 is held; #2 and #3 are ready. #50 is a PR: dropped.
eq "T1/T2/T4 ghp tickets" "$(tix ghp)" '{"ready":2,"blocked":2,"held":1,"parked":null,"held_complete":true}'
eq "T1 ghp basis" "$(basis ghp)" '{"builds":"measured","parked":"unmeasured"}'
eq "T1 the out-of-list blockers were read" "$(grep -cE '^api -i -X GET repos/acme/ghp/issues/(98|99)$' "$T/gh.run")" 2
eq "T1 the open in-list blocker cost no read" "$(grep -c 'repos/acme/ghp/issues/2$' "$T/gh.run")" 0
eq "T1 one issue list read" "$(grep -c 'repos/acme/ghp/issues?labels=ai-build&state=open&per_page=100&page=1' "$T/gh.run")" 1
eq "T2 the hold reads went to the three candidates only" \
  "$(grep -oE 'repos/acme/ghp/issues/[0-9]+/comments' "$T/gh.run" | sort | tr '\n' ' ')" \
  "repos/acme/ghp/issues/2/comments repos/acme/ghp/issues/3/comments repos/acme/ghp/issues/5/comments "
eq "T1 ghp verdict (running GP-7)" "$(verd ghp)" busy
eq "T5 app tickets" "$(tix app)" '{"ready":2,"blocked":1,"held":null,"parked":2,"held_complete":null}'
eq "T5 app basis" "$(basis app)" '{"builds":"measured","held":"unmeasured"}'

# ── T3 / T11: the hold read cap ─────────────────────────────────────────────
run_lane FAKE_CAP=4 GH_FIX="$D2" UTIL_HOLD_READS_MAX=2
eq "T3 capped" "$(tix ghp)" '{"ready":5,"blocked":0,"held":0,"parked":null,"held_complete":false}'
eq "T3 exactly 2 hold reads" "$(grep -c '/comments' "$T/gh.run")" 2
run_lane FAKE_CAP=4 GH_FIX="$D2" UTIL_HOLD_READS_MAX=0
eq "T3 max 0: no hold read, incomplete" "$(tix ghp | jq -c '[.ready,.held_complete]')" '[5,false]'
eq "T3 max 0 reads" "$(grep -c '/comments' "$T/gh.run")" 0
run_lane FAKE_CAP=4 GH_FIX="$D2" UTIL_HOLD_READS_MAX=abc
eq "T11 a bad knob is 30" "$(tix ghp)" '{"ready":5,"blocked":0,"held":0,"parked":null,"held_complete":true}'
eq "T11 5 hold reads" "$(grep -c '/comments' "$T/gh.run")" 5

# T14: the knob as a settings row (lib.utilization-tickets.<project>.…),
# applied by lib_env_apply inside the section, not only as an env var.
scratch_rm "$H/state/settings-cache.json"; scratch_rm "$H/state/lane-gate"
run_lane FAKE_CAP=4 GH_FIX="$D2" \
  FAKE_SETTINGS='{"settings":[{"key":"lib.utilization-tickets.ghp.util_hold_reads_max","value":"1","actor":"operator"}]}'
eq "T14 settings row caps the reads" "$(tix ghp | jq -c '[.ready,.held_complete]')" '[5,false]'
eq "T14 one hold read" "$(grep -c '/comments' "$T/gh.run")" 1
scratch_rm "$H/state/settings-cache.json"; scratch_rm "$H/state/lane-gate"

# ── T6: rate limited ────────────────────────────────────────────────────────
run_lane FAKE_CAP=4 FAKE_JOBS='[]' FAKE_GH_RL=1
eq "T6 ghp null, never 0" "$(tix ghp)" '{"ready":null,"blocked":null,"held":null,"parked":null,"held_complete":null}'
eq "T6 ghp basis" "$(basis ghp)" '{"builds":"measured","ready":"unmeasured","blocked":"unmeasured","held":"unmeasured","parked":"unmeasured"}'
eq "T6 ghp verdict is unknown, not starved" "$(verd ghp)" unknown
eq "T6 app: no PR list, ready null" "$(tix app | jq -c '[.ready,.blocked,.parked]')" '[null,1,2]'
eq "T6 app verdict" "$(verd app)" unknown

# ── T7: the in-app ticket read fails ────────────────────────────────────────
run_lane FAKE_CAP=4 FAKE_JOBS='[]' FAKE_BOARD_FAIL=1
eq "T7 app null" "$(tix app)" '{"ready":null,"blocked":null,"held":null,"parked":null,"held_complete":null}'
eq "T7 app verdict" "$(verd app)" unknown

# ── T8: observable verdicts ─────────────────────────────────────────────────
run_lane FAKE_CAP=4 FAKE_JOBS='[]' GH_FIX="$D3"
eq "T8 empty board" "$(tix ghp)" '{"ready":0,"blocked":0,"held":0,"parked":null,"held_complete":true}'
eq "T8 empty board with free slots is starved" "$(verd ghp)" starved
run_lane FAKE_CAP=1 FAKE_JOBS='["ZZ-1"]' GH_FIX="$D2"
eq "T8 at the cap with ready is saturated" "$(verd ghp)" saturated

# ── T10: the running-jobs read at its cap ───────────────────────────────────
run_lane FAKE_CAP=unlimited FAKE_JOBS_N=500
eq "T10 ghp ready null" "$(tix ghp | jq -c '.ready')" null
eq "T10 app ready null" "$(tix app | jq -c '.ready')" null
eq "T10 verdicts unknown" "$(verd ghp) $(verd app)" "unknown unknown"

# ── T12: an unreadable hold thread ──────────────────────────────────────────
run_lane FAKE_CAP=4 FAKE_JOBS='[]' FAKE_COMMENTS_FAIL=3
eq "T12 held and ready null" "$(tix ghp | jq -c '[.ready,.blocked,.held,.held_complete]')" '[null,2,null,null]'
eq "T12 verdict" "$(verd ghp)" unknown

# ── T13: a full third issue page is capped ──────────────────────────────────
run_lane FAKE_CAP=4 FAKE_JOBS='[]' FAKE_FULL_PAGES=1
eq "T13 capped list is null" "$(tix ghp | jq -c '[.ready,.blocked,.held]')" '[null,null,null]'
eq "T13 three pages read" "$(grep -c 'issues?labels=ai-build' "$T/gh.run")" 3

# ── T9: nothing but GET ─────────────────────────────────────────────────────
eq "T9 gh was called" "$([ -s "$GH_CALLS" ] && echo yes)" yes
eq "T9 no POST / issue create" "$(grep -cE '(-X|--method) (POST|PATCH|PUT|DELETE)|issue create| -[fF] ' "$GH_CALLS")" 0
eq "T9 every gh call is a REST GET" "$(grep -cv '^api -i -X GET ' "$GH_CALLS")" 0

echo "utilization-tickets: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
