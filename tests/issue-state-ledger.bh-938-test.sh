#!/bin/bash
# tests/issue-state-ledger.bh-938-test.sh — BH-938: the hub lane
# bin/issue-state-ledger.sh, run for real from a scratch harness with the real
# bin/lib/gh-rest.sh beside it. Only the edges are stubbed: fakebin/gh serves
# fixture pages (with a status line, as `gh api -i` does) and records every
# path; bin/jobs-client.sh is a file-backed ledger that records every PUT;
# bin/fleet-conf.sh knows one GitHub-issues project and one board project.
#
# The cases, from the plan:
#   I1 no watermark: since = 14 days back; closed/completed, closed/not_planned
#      and open are PUT closed, closed, open; the PR item is not PUT; the
#      watermark is the last updated_at
#   I2 a board-prefix project gets no GitHub call and no PUT
#   I3 429 on page 2: page-1 rows are PUT and the watermark stops at page 1
#   I4 a PUT fails on item k: the watermark is item k-1; the next run re-PUTs k
#   I5 the watermark read is an outage (rc 1): no GitHub call for the project
#   I6 ISSUE_STATE_MAX_PUTS=2: two PUTs, a DEFERRED line, watermark at the 2nd
#   I7 the lock is held: exit 0, no calls
#   I8 a watermark that exists is the since, verbatim
#
# MUTATION GUARD: I3 and I4 are what catch "advance the watermark before the
# PUTs" (or "to the page's last updated_at"): either swap moves the watermark
# past an item that was never recorded, and both cases assert it did not.
#
# Run from anywhere: tests/issue-state-ledger.bh-938-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

mkdir -p "$T/fakebin"
# gh api -i -X GET <path> ... — answers from $FIX/p<page>.json, or with the
# status in $FIX/p<page>.status. Records the path it was asked for.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
[ "$1" = api ] || exit 1
path=""
for a in "$@"; do case "$a" in repos/*) path=$a ;; esac; done
echo "$path" >> "$GHCALLS"
page=$(printf '%s' "$path" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
if [ -f "$FIX/p$page.status" ]; then
  printf 'HTTP/2 %s\r\n\r\n{"message":"API rate limit exceeded"}\n' "$(cat "$FIX/p$page.status")"
  exit 1
fi
if [ -f "$FIX/p$page.json" ]; then
  printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; cat "$FIX/p$page.json"; exit 0
fi
printf 'HTTP/2 200\r\n\r\n[]\n'
EOF
chmod +x "$T/fakebin/gh"

H=""; FIX=""; GHCALLS=""; PUTS=""; LEDGER=""
setup() {
  H=$T/h$1; scratch_rm "$H"
  mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/locks" "$H/ledger"
  cp "$DIR/bin/issue-state-ledger.sh" "$H/bin/" 2>/dev/null
  cp "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
  : > "$H/env/global.env"
  cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
if [ "$1" = --projects ]; then printf 'project-1\nproject-5\n'; exit 0; fi
case "$1:$2" in
  project-1:repo) echo example-org/project-1 ;;
  project-1:board_prefix) echo /api/board ;;
  project-5:repo) echo example-org/project-5 ;;
  project-5:board_prefix) echo - ;;
  *) exit 1 ;;
esac
EOF
  # A file-backed ledger. WM_GET_RC forces the watermark read's rc; PUT_FAIL
  # names one key whose PUT fails.
  cat > "$H/bin/jobs-client.sh" <<'EOF'
_lf() { printf '%s/ledger/%s__%s' "$HARNESS" "$1" "$(printf '%s' "$2" | tr '/#' '__')"; }
job_ledger_get() {
  [ -n "${WM_GET_RC:-}" ] && return "$WM_GET_RC"
  local f; f=$(_lf "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"
}
job_ledger_put() {
  [ -n "${PUT_FAIL:-}" ] && [ "$2" = "$PUT_FAIL" ] && return 1
  echo "$1 $2 $3" >> "$PUTLOG"; printf '%s' "$3" > "$(_lf "$1" "$2")"
}
EOF
  chmod +x "$H/bin/"*.sh
  FIX=$T/fix$1; mkdir -p "$FIX"
  GHCALLS=$T/gh$1; PUTS=$T/puts$1; : > "$GHCALLS"; : > "$PUTS"
}
issue() { # issue <n> <state> <reason> <updated_at> [pr]
  local pr=""; [ -n "${5:-}" ] && pr=',"pull_request":{"url":"x"}'
  printf '{"number":%s,"state":"%s","state_reason":%s,"updated_at":"%s"%s}' \
    "$1" "$2" "$( [ "$3" = null ] && echo null || echo "\"$3\"")" "$4" "$pr"
}
page() { local f=$1; shift; local IFS=,; printf '[%s]\n' "$*" > "$FIX/p$f.json"; }
full_page() { # full_page <page> <first n> <day> — 100 open issues
  local out=() i
  for i in $(seq 0 99); do out+=("$(issue $(($2 + i)) open null "2026-09-$3T00:$(printf %02d $((i / 60))):$(printf %02d $((i % 60)))Z")"); done
  page "$1" "${out[@]}"
}
wm() { cat "$H/ledger/issue_state_wm__project-5" 2>/dev/null; }
run() { HARNESS=$H GHCALLS=$GHCALLS PUTLOG=$PUTS FIX=$FIX PATH="$T/fakebin:$PATH" bash "$H/bin/issue-state-ledger.sh"; }

# I1 ------------------------------------------------------------------------
setup 1
page 1 "$(issue 551 closed completed 2026-09-20T01:00:00Z)" \
       "$(issue 552 closed not_planned 2026-09-20T02:00:00Z)" \
       "$(issue 553 open null 2026-09-20T03:00:00Z)" \
       "$(issue 554 closed null 2026-09-20T04:00:00Z pr)"
run; eq "I1 rc" "$?" 0
eq "I1 puts" "$(grep '^issue_state ' "$PUTS")" "$(printf 'issue_state project-5#551 closed\nissue_state project-5#552 closed\nissue_state project-5#553 open')"
grep -q '#554' "$PUTS" && bad "I1 a PR item was written" || ok
# The PR is the last item processed; skipping it on purpose still moves past it.
eq "I1 watermark" "$(wm)" 2026-09-20T04:00:00Z
since=$(sed -n '1s/.*since=\([^&]*\).*/\1/p' "$GHCALLS")
want=$(date -u -d '14 days ago' +%s); got=$(date -u -d "$since" +%s 2>/dev/null || echo 0)
d=$((got - want)); [ "${d#-}" -le 120 ] && ok || bad "I1 since [$since] is not 14 days back"
grep -q 'repos/example-org/project-5/issues?state=all&since=.*&sort=updated&direction=asc&per_page=100&page=1' "$GHCALLS" \
  && ok || bad "I1 path shape: $(head -1 "$GHCALLS")"
grep -q 'projects=1 puts=3 closed=2 open=1' "$H/logs/issue-state-ledger.log" && ok || bad "I1 summary: $(cat "$H/logs/issue-state-ledger.log")"

# I2 ------------------------------------------------------------------------
grep -q project-1 "$GHCALLS" && bad "I2 board project was read from GitHub" || ok
grep -q project-1 "$PUTS" && bad "I2 board project was written" || ok

# I3 ------------------------------------------------------------------------
setup 3
full_page 1 1000 21
echo 429 > "$FIX/p2.status"
page 3 "$(issue 9999 closed completed 2026-09-22T00:00:00Z)"
run; eq "I3 rc" "$?" 0
eq "I3 page-1 puts" "$(grep -c '^issue_state ' "$PUTS")" 100
grep -q '#9999' "$PUTS" && bad "I3 read past the failed page" || ok
eq "I3 watermark stops at page 1" "$(wm)" 2026-09-21T00:01:39Z
grep -q 'STOP project-5' "$H/logs/issue-state-ledger.log" && ok || bad "I3 no STOP line"

# I4 ------------------------------------------------------------------------
setup 4
page 1 "$(issue 1 closed completed 2026-09-20T01:00:00Z)" \
       "$(issue 2 closed completed 2026-09-20T02:00:00Z)" \
       "$(issue 3 open null 2026-09-20T03:00:00Z)"
PUT_FAIL='project-5#2' run
eq "I4 puts before the failure" "$(grep -c '^issue_state ' "$PUTS")" 1
eq "I4 watermark is item k-1" "$(wm)" 2026-09-20T01:00:00Z
: > "$PUTS"; : > "$GHCALLS"
run
grep -q 'issue_state project-5#2 closed' "$PUTS" && ok || bad "I4 the next run did not re-PUT item k"
grep -q 'since=2026-09-20T01:00:00Z' "$GHCALLS" && ok || bad "I4 next run since: $(cat "$GHCALLS")"
eq "I4 watermark after recovery" "$(wm)" 2026-09-20T03:00:00Z

# I5 ------------------------------------------------------------------------
setup 5
page 1 "$(issue 1 closed completed 2026-09-20T01:00:00Z)"
WM_GET_RC=1 run; eq "I5 rc" "$?" 0
eq "I5 github calls" "$(grep -c . "$GHCALLS")" 0
eq "I5 puts" "$(grep -c . "$PUTS")" 0
grep -q 'SKIP project-5' "$H/logs/issue-state-ledger.log" && ok || bad "I5 no SKIP line"
grep -q 'skipped=1' "$H/logs/issue-state-ledger.log" && ok || bad "I5 summary does not count the skip"

# I6 ------------------------------------------------------------------------
setup 6
page 1 "$(issue 1 closed completed 2026-09-20T01:00:00Z)" \
       "$(issue 2 open null 2026-09-20T02:00:00Z)" \
       "$(issue 3 closed completed 2026-09-20T03:00:00Z)"
ISSUE_STATE_MAX_PUTS=2 run
eq "I6 puts" "$(grep -c '^issue_state ' "$PUTS")" 2
eq "I6 watermark" "$(wm)" 2026-09-20T02:00:00Z
grep -q 'DEFERRED project-5 at 2026-09-20T02:00:00Z' "$H/logs/issue-state-ledger.log" && ok || bad "I6 no DEFERRED line"
# A page cap defers the same way.
setup 66
full_page 1 1000 21; full_page 2 2000 22
ISSUE_STATE_MAX_PAGES=1 run
eq "I6b one page read" "$(grep -c . "$GHCALLS")" 1
eq "I6b watermark" "$(wm)" 2026-09-21T00:01:39Z
grep -q 'DEFERRED project-5' "$H/logs/issue-state-ledger.log" && ok || bad "I6b no DEFERRED line"

# I7 ------------------------------------------------------------------------
setup 7
page 1 "$(issue 1 closed completed 2026-09-20T01:00:00Z)"
exec 8>"$H/locks/issue-state-ledger.lock"; flock -n 8
run; eq "I7 rc" "$?" 0
exec 8>&-
eq "I7 github calls" "$(grep -c . "$GHCALLS")" 0
eq "I7 puts" "$(grep -c . "$PUTS")" 0

# I8 ------------------------------------------------------------------------
setup 8
printf '2026-09-19T10:00:00Z' > "$H/ledger/issue_state_wm__project-5"
run
grep -q 'since=2026-09-19T10:00:00Z&' "$GHCALLS" && ok || bad "I8 since: $(cat "$GHCALLS")"
eq "I8 watermark unmoved on an empty page" "$(wm)" 2026-09-19T10:00:00Z

echo "issue-state-ledger: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
