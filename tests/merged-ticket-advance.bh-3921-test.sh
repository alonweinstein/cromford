#!/bin/bash
# tests/merged-ticket-advance.bh-3921-test.sh — BH-3927 (BH-3921, part 5 of 5):
# bin/merged-ticket-advance.sh, the lane that moves an in-app ticket on once
# its PR merged and the post-merge deploy audit passed.
#
# WHAT THIS PINS. The REAL bin/merged-ticket-advance.sh, argv and all, against a
# stubbed board API, plus (M10/M11) the REAL inapp_released_lines from
# bin/lib/rt/scope.sh with the REAL bin/decompose-parent-close.sh behind it.
# Assertions read only what came out: the stub's request log, stdout, stderr
# and logs/<p>.log. Nothing here greps a script's source (D3).
#
# THE BOARD IS STATEFUL. One db.json holds every ticket; a move rewrites the
# ticket's status and a comment lands on its thread under the board's self
# actor, the way a real in-app board authors it (`{userId:"u-h", name:"System
# Harness"}`, never userId `system`; SELF_NAME overrides the name), so a second
# run sees exactly what a real board would show it, and "the re-run posts
# nothing" is a real idempotency check rather than a fixture that hides work.
#
# THE FIXTURES ARE THE PRODUCERS' SHAPES. builds/<p>-<KEY>-<12 digits>/RESULT
# as bin/run-build.sh writes it, and state/postmerge-qa-done.txt lines as
# bin/postmerge-qa.sh's mark_done writes them:
# `<YYYY-MM-DD HH:MM:SSZ> <basename> <sha8> <verdict>`. Every time is computed
# from `date -u` relative to now, never a literal date.
#
# Run from anywhere: tests/merged-ticket-advance.bh-3921-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "merged-ticket-advance: jq is required"; exit 1; }

H="$T/h"
B="$T/board"
mkdir -p "$H/bin/lib/rt" "$H/env" "$H/logs" "$H/state" "$H/flags" "$T/fakebin" "$B"
# The lane under test may not exist yet (the red run); everything else must.
ln -s "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
if [ -f "$DIR/bin/merged-ticket-advance.sh" ]; then
  scratch_install_closure bin/merged-ticket-advance.sh "$H" >/dev/null || { echo "closure install failed for bin/merged-ticket-advance.sh"; exit 1; }
fi
# bin/alert-line.sh: the lane's one alert when a move gives up (M18).
for s in bin/decompose-parent-close.sh bin/internal-token-for.sh bin/lib/rt/scope.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
chmod +x "$H/bin/"*.sh

# x-os is an in-app board; ghproj is a GitHub-Issues row (`-`).
cat > "$H/fleet.conf" <<'CONF'
x-os    example-org/x-os    https://x.test  /api/board  3  local
ghproj  example-org/ghproj  -               -           5  local
CONF
: > "$H/env/global.env"
printf 'X_API_BASE=https://x.test\nX_INTERNAL_API_TOKEN=tok-fixture-never-logged\n' > "$T/x-os.env.src"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" REVDEP_WAKE=1 STUBDIR="$B"
export PATH="$T/fakebin:$PATH"
unset GH_ISSUES_REPO MERGED_ADVANCE_MAX MERGED_ADVANCE_COOLDOWN_S \
      PARENT_CLOSE_MAX PARENT_CLOSE_COOLDOWN_S 2>/dev/null || true

# ── the board, as a stateful file-backed API ─────────────────────────────────
# REQS.log: one `METHOD URL` line per request of any kind.
# POSTS.jsonl: one line per POST (url, idempotency key, bearer present, body).
# Knobs: COMMENT_CODE (answer every comment POST with that code),
# COMMENT_NOPERSIST (a 200 whose comment never shows on the thread, so only the
# marker remembers it), MOVE_FAIL_ONCE (answer the next move 500 and forget
# it), MOVE_FAIL (answer every move 500), MOVE_NOECHO (a 200
# whose body does not carry the new status), rec-<id>.code (answer that
# ticket's GET with that code).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; DATA=""; IDEM=""; AUTH=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift ;;
    -X) METHOD="$2"; shift ;;
    --data-binary) DATA="${2#@}"; shift ;;
    -H) case "$2" in
          Idempotency-Key:*) IDEM="${2#Idempotency-Key: }" ;;
          Authorization:*)   AUTH=1 ;;
        esac; shift ;;
    http*) URL="$1" ;;
    *) ;;
  esac
  shift
done
DB="$STUBDIR/db.json"
w() { if [ -n "$OUT" ]; then printf '%s' "$1" > "$OUT"; else printf '%s' "$1"; fi; }
echo "$METHOD $URL" >> "$STUBDIR/REQS.log"
CODE=200
if [ "$METHOD" = POST ]; then
  BODY=$(cat "$DATA" 2>/dev/null)
  jq -cn --arg u "$URL" --arg i "$IDEM" --argjson a "$AUTH" --arg b "$BODY" \
         '{url:$u, idem:$i, auth:$a, body:$b}' >> "$STUBDIR/POSTS.jsonl"
  id=$(printf '%s' "$URL" | sed -E 's@.*/tickets/([^/]+)/.*@\1@')
  case "$URL" in
    */move)
      if [ -e "$STUBDIR/MOVE_FAIL_ONCE" ]; then
        rm -f "$STUBDIR/MOVE_FAIL_ONCE"; w '{"error":"boom"}'; printf 500; exit 0
      fi
      [ -e "$STUBDIR/MOVE_FAIL" ] && { w '{"error":"boom"}'; printf 500; exit 0; }
      to=$(printf '%s' "$BODY" | jq -r '.toStatus')
      jq --arg id "$id" --arg to "$to" 'map(if (.id|tostring) == $id then .status = $to else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      if [ -e "$STUBDIR/MOVE_NOECHO" ]; then w '{"ok":true}'
      else w "$(jq -cn --arg id "$id" --arg to "$to" '{id:$id, status:$to}')"; fi ;;
    */comments)
      if [ -r "$STUBDIR/COMMENT_CODE" ]; then
        CODE=$(cat "$STUBDIR/COMMENT_CODE"); w '{}'; printf '%s' "$CODE"; exit 0
      fi
      [ -e "$STUBDIR/COMMENT_NOPERSIST" ] && { w '{"id":1}'; printf 200; exit 0; }
      now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
      me="System Harness"; [ -r "$STUBDIR/SELF_NAME" ] && me=$(cat "$STUBDIR/SELF_NAME")
      jq --arg id "$id" --arg now "$now" --arg me "$me" --arg b "$(printf '%s' "$BODY" | jq -r '.body')" \
         'map(if (.id|tostring) == $id
              then .comments += [{author:{userId:"u-h", name:$me}, createdAt:$now, body:$b}] else . end)' \
         "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
      w '{"id":1}' ;;
    *) CODE=404; w '{}' ;;
  esac
  printf '%s' "$CODE"; exit 0
fi
case "$URL" in
  */boards) w '{"boards":[{"id":"b1","name":"Main"}]}' ;;
  */boards/*/tickets)
    w "$(jq -c '. as $db | {tickets: map(
          (if .childIds then .children = [ .childIds[] as $c | $db[] | select(.id == $c)
                                          | {id, key, status} ] else . end)
          | del(.childIds, .comments))}' "$DB")" ;;
  */tickets/*)
    id="${URL##*/}"
    [ -r "$STUBDIR/rec-$id.code" ] && CODE=$(cat "$STUBDIR/rec-$id.code")
    w "$(jq -c --arg id "$id" '[.[] | select((.id|tostring) == $id)][0] // {} | del(.childIds)' "$DB")" ;;
  *) CODE=404; w '{}' ;;
esac
printf '%s' "$CODE"
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# ── fixture helpers ──────────────────────────────────────────────────────────
DONE="$H/state/postmerge-qa-done.txt"
PRU="https://github.com/example-org/x-os/pull"
reset() {
  scratch_rm "$B"; mkdir -p "$B"
  echo '[]' > "$B/db.json"; : > "$B/REQS.log"; : > "$B/POSTS.jsonl"
  scratch_rm "$H/logs"; scratch_rm "$H/builds"; scratch_rm "$H/state"; scratch_rm "$H/flags"
  mkdir -p "$H/logs" "$H/builds" "$H/state" "$H/flags"
  rm -f "$H/bin/lib/ledger-twin.sh"
  cp "$T/x-os.env.src" "$H/env/x-os.env"
  unset MERGED_ADVANCE_MAX MERGED_ADVANCE_COOLDOWN_S PARENT_CLOSE_COOLDOWN_S 2>/dev/null || true
}
tsago()  { date -u -d "-$1 min" +%Y%m%d%H%M; }               # build dir stamp
stago()  { date -u -d "-$1 min" '+%Y-%m-%d %H:%M:%SZ'; }     # done-file stamp
isoago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%S.000Z; }   # board createdAt
# tk <id> <key> <status> <reporterUserId|-> [childIds-json] — add a ticket
tk() {
  local rep="$4" kids="${5:-null}"
  jq --argjson id "$1" --arg k "$2" --arg s "$3" --arg r "$rep" --argjson c "$kids" \
     '. + [ {id:$id, key:$k, title:("Ticket " + $k), status:$s, comments:[]}
            + (if $r == "-" then {} else {reporter:{userId:$r, name:"R"}} end)
            + (if $c == null then {} else {childIds:$c} end) ]' \
     "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
}
# comment <id> <userId> <minutes-ago> <body> [author name]
comment() {
  jq --argjson id "$1" --arg u "$2" --arg t "$(isoago "$3")" --arg b "$4" --arg n "${5:-}" \
     'map(if .id == $id then .comments += [{author:({userId:$u} + (if $n == "" then {} else {name:$n} end)),
                                             createdAt:$t, body:$b}] else . end)' \
     "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
}
# build <key> <minutes-ago> [RESULT first line] -> prints the basename
build() {
  local bn="x-os-$1-$(tsago "$2")"
  mkdir -p "$H/builds/$bn"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$H/builds/$bn/RESULT"
  printf '%s' "$bn"
}
# audit <basename> <sha8> <verdict> <minutes-ago>
audit() { printf '%s %s %s %s\n' "$(stago "$4")" "$1" "$2" "$3" >> "$DONE"; }

run() { "$H/bin/merged-ticket-advance.sh" "$@" 2>"$T/err.txt"; }
posts()   { awk 'END{print NR}' "$B/POSTS.jsonl"; }
reqs()    { awk 'END{print NR}' "$B/REQS.log"; }
post_f()  { sed -n "$2p" "$B/POSTS.jsonl" | jq -r ".$1" 2>/dev/null; }
cposts()  { grep -c '/comments"' "$B/POSTS.jsonl"; }
mposts()  { grep -c '/move"' "$B/POSTS.jsonl"; }
plog()    { cat "$H/logs/x-os.log" 2>/dev/null; }
advlog()  { grep 'MERGED_ADVANCE moved=' "$H/logs/x-os.log" 2>/dev/null | tail -1; }
status_of() { jq -r --argjson id "$1" '.[] | select(.id == $id) | .status' "$B/db.json"; }

# one eligible ticket: PASS audit, system reporter, in_progress
eligible() { # eligible <id> <key> <status> <reporter> <verdict>
  local bn
  tk "$1" "$2" "$3" "$4"
  bn=$(build "$2" 30 "PR_CREATED $PRU/$1 | QUEUED: tier 2")
  audit "$bn" abc12345 "$5" 10
}

# ---------------------------------------------------------------------------
# M1: PASS + system reporter + in_progress -> one comment, then a move to done
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "M1: rc 0 (got $RC)"
[ "$(posts)" = 2 ] && ok || bad "M1: exactly 2 POSTs (got $(posts): $(cat "$B/POSTS.jsonl"))"
case "$(post_f url 1)" in */tickets/101/comments) ok ;; *) bad "M1: first POST is the comment (got $(post_f url 1))" ;; esac
case "$(post_f url 2)" in */tickets/101/move) ok ;; *) bad "M1: second POST is the move (got $(post_f url 2))" ;; esac
BODY=$(post_f body 1 | jq -r '.body' 2>/dev/null)
grep -qF "$PRU/101" <<<"$BODY" && ok || bad "M1: the comment carries the PR URL: $BODY"
grep -qF 'commit abc12345' <<<"$BODY" && ok || bad "M1: the comment names the commit: $BODY"
grep -qF 'post-merge check passed in production' <<<"$BODY" && ok || bad "M1: PASS wording: $BODY"
grep -qF 'Moving it to done.' <<<"$BODY" && ok || bad "M1: says where it goes: $BODY"
grep -q '—' <<<"$BODY" && bad "M1: no em dash in a client comment: $BODY" || ok
grep -qF '"toStatus":"done"' <<<"$(post_f body 2)" && ok || bad "M1: move body targets done (got $(post_f body 2))"
grep -qF 'MERGED_ADVANCE moved=1 comment-only=0 skipped: no-audit=0 audit-fail=0 newer-build=0 client-spoke=0 client-review=0' <<<"$(advlog)" \
  && ok || bad "M1: the run's log line (got '$(advlog)')"
[ "$(grep -c 'MERGED_ADVANCE moved=' "$H/logs/x-os.log" 2>/dev/null)" = 1 ] && ok || bad "M1: exactly one summary line: $(plog)"
[ "$OUT" = "TK-101" ] && ok || bad "M1: stdout is the key (got '$OUT')"
[ "$(post_f auth 1)" = 1 ] && [ "$(post_f auth 2)" = 1 ] && ok || bad "M1: both writes authenticated"
grep -rq 'tok-fixture-never-logged' "$H/logs" && bad "M1: token in a log" || ok

# ---------------------------------------------------------------------------
# M2: the same fixture run again posts nothing
# ---------------------------------------------------------------------------
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M2: a re-run posts nothing (got $(posts): $(cat "$B/POSTS.jsonl"))"
[ -z "$OUT" ] && ok || bad "M2: nothing on stdout (got '$OUT')"
# …and even with the ticket dragged back to in_progress by hand, the marker
# and the thread stop a second comment.
jq 'map(.status = "in_progress")' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
rm -f "$H/state"/merged-advance-x-os-101-*.mark
OUT=$(run x-os)
[ "$(cposts)" = 0 ] && ok || bad "M2: the thread witness alone stops a second comment (comments=$(cposts))"
# …and the person's move back wins: the moved marker (lead review
# lr-4034-93265e68e589) means no second move either (see M17).
[ "$(mposts)" = 0 ] && [ "$(status_of 101)" = in_progress ] && ok \
  || bad "M2: a ticket dragged back after the lane's move is not moved again (moves=$(mposts) status=$(status_of 101))"

# ---------------------------------------------------------------------------
# M3: FAIL and NOT_COVERED_DEPLOY_TIMEOUT -> no POST, audit-fail=1
# ---------------------------------------------------------------------------
for v in FAIL NOT_COVERED_DEPLOY_TIMEOUT; do
  reset
  eligible 101 TK-101 in_progress system "$v"
  OUT=$(run x-os)
  [ "$(posts)" = 0 ] && ok || bad "M3 $v: no POST (got $(posts))"
  grep -qF 'audit-fail=1' <<<"$(advlog)" && ok || bad "M3 $v: audit-fail=1 (got '$(advlog)')"
  grep -qF 'moved=0' <<<"$(advlog)" && ok || bad "M3 $v: moved=0 (got '$(advlog)')"
done

# ---------------------------------------------------------------------------
# M4: no audit; an audit only for an older build; a CX-1 audit vs CX-12
# ---------------------------------------------------------------------------
reset
tk 101 TK-101 in_progress system
build TK-101 30 "PR_CREATED $PRU/101" >/dev/null
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M4a: no audit, no POST (got $(posts))"
grep -qF 'no-audit=1' <<<"$(advlog)" && ok || bad "M4a: no-audit=1 (got '$(advlog)')"

reset
tk 101 TK-101 in_progress system
OLD=$(build TK-101 120 "PR_MERGED $PRU/90")
build TK-101 30 "PR_CREATED $PRU/101" >/dev/null
audit "$OLD" 0ld0ld00 PASS 60
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M4b: an older build's audit is not this build's (got $(posts))"
grep -qF 'no-audit=1' <<<"$(advlog)" && ok || bad "M4b: no-audit=1 (got '$(advlog)')"

reset
tk 112 CX-12 in_progress system
build CX-12 30 "PR_CREATED $PRU/112" >/dev/null
CX1=$(build CX-1 30 "PR_CREATED $PRU/111")
audit "$CX1" abc12345 PASS 10
# the CX-1 audit names a basename that is a prefix-collision of CX-12's
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M4c: CX-1's audit must not advance CX-12 (got $(posts))"
grep -qF 'no-audit=1' <<<"$(advlog)" && ok || bad "M4c: no-audit=1 (got '$(advlog)')"

# a CX-1 ticket must never pick up a CX-12 build dir as its own newest
reset
tk 111 CX-1 in_progress system
CX1=$(build CX-1 60 "PR_CREATED $PRU/111")
audit "$CX1" abc12345 PASS 10
build CX-12 5 "PLAN_BLOCKED" >/dev/null
OUT=$(run x-os)
[ "$OUT" = "CX-1" ] && ok || bad "M4d: CX-12's newer dir is not CX-1's newer build (got '$OUT', log '$(advlog)')"

# a dir for the key with no 12-digit stamp is not a build, and never "newer"
reset
eligible 101 TK-101 in_progress system PASS
mkdir -p "$H/builds/x-os-TK-101-scratch"
OUT=$(run x-os)
[ "$OUT" = "TK-101" ] && ok || bad "M4e: an unstamped dir is not a build (got '$OUT', log '$(advlog)')"

# ---------------------------------------------------------------------------
# M5: NOT_COVERED_NO_QA_ENV wording names the real rung
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system NOT_COVERED_NO_QA_ENV
OUT=$(run x-os)
BODY=$(post_f body 1 | jq -r '.body' 2>/dev/null)
[ "$(posts)" = 2 ] && ok || bad "M5: NOT_COVERED_NO_QA_ENV still advances (got $(posts))"
grep -qF 'production is serving it' <<<"$BODY" && ok || bad "M5: serving wording: $BODY"
grep -qF 'Nobody has clicked through it in production yet.' <<<"$BODY" && ok || bad "M5: unclicked wording: $BODY"
grep -qF 'passed' <<<"$BODY" && bad "M5: must not say passed: $BODY" || ok
grep -q '—' <<<"$BODY" && bad "M5: no em dash: $BODY" || ok

# ---------------------------------------------------------------------------
# M6: client reporter + in_progress -> review; reporter absent -> review too
# ---------------------------------------------------------------------------
for rep in u_7 -; do
  reset
  eligible 101 TK-101 in_progress "$rep" PASS
  OUT=$(run x-os)
  BODY=$(post_f body 1 | jq -r '.body' 2>/dev/null)
  grep -qF '"toStatus":"review"' <<<"$(post_f body 2)" && ok || bad "M6 rep=$rep: moves to review (got $(post_f body 2))"
  case "$BODY" in *'Moving it to review so you can check it.</p>') ok ;; *) bad "M6 rep=$rep: body ending: $BODY" ;; esac
  [ "$(status_of 101)" = review ] && ok || bad "M6 rep=$rep: board shows review"
done

# ---------------------------------------------------------------------------
# M7: client reporter + review -> nothing, not even the ticket GET
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 review u_7 PASS
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M7: no POST (got $(posts))"
grep -q '/tickets/101$' "$B/REQS.log" && bad "M7: no ticket GET for a client review ticket: $(cat "$B/REQS.log")" || ok
grep -qF 'client-review=1' <<<"$(advlog)" && ok || bad "M7: client-review=1 (got '$(advlog)')"
# …but a system-filed ticket in review goes to done
reset
eligible 101 TK-101 review system PASS
OUT=$(run x-os)
grep -qF '"toStatus":"done"' <<<"$(post_f body 2)" && ok || bad "M7b: system review -> done (got $(post_f body 2))"

# ---------------------------------------------------------------------------
# M8: a client spoke after the audit -> hold; a system comment does not count
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
comment 101 u_7 9 "One more thing on this"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M8: client comment after the audit holds it (got $(posts))"
grep -qF 'client-spoke=1' <<<"$(advlog)" && ok || bad "M8: client-spoke=1 (got '$(advlog)')"
reset
eligible 101 TK-101 in_progress system PASS
comment 101 system 9 "Build started"
comment 101 u_7 20 "Before the audit, so it does not count"
OUT=$(run x-os)
[ "$(posts)" = 2 ] && ok || bad "M8b: system comments and older client ones do not hold it (got $(posts))"
# the board's self actor is the harness, not the client: a later triage
# comment under that name does not hold it, by the generic name or by the
# project's BOARD_SELF_ACTORS
reset
eligible 101 TK-101 in_progress system PASS
comment 101 u-h 5 "Triage: looks ready" "System Harness"
OUT=$(run x-os)
[ "$(posts)" = 2 ] && ok || bad "M8d: a System Harness comment does not hold it (got $(posts), log '$(advlog)')"
reset
printf 'BOARD_SELF_ACTORS="X Team"\n' >> "$H/env/x-os.env"
eligible 101 TK-101 in_progress system PASS
comment 101 u-h 5 "Triage: looks ready" "X Team Harness"
OUT=$(run x-os)
[ "$(posts)" = 2 ] && ok || bad "M8e: a BOARD_SELF_ACTORS comment does not hold it (got $(posts), log '$(advlog)')"
# …and a client under any other name still does
reset
eligible 101 TK-101 in_progress system PASS
comment 101 u_7 5 "Wait, one thing" "Dana"
OUT=$(run x-os)
grep -qF 'client-spoke=1' <<<"$(advlog)" && ok || bad "M8f: a named client still holds it (got '$(advlog)')"
# an unparseable createdAt is unknown, and unknown is not older (D11)
reset
eligible 101 TK-101 in_progress system PASS
jq 'map(.comments = [{author:{userId:"u_7"}, createdAt:"yesterday-ish", body:"?"}])' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && ok || bad "M8c: an unparseable client createdAt holds it (got $(posts))"
# A client who QUOTES the lane's sentence is still the client (lead review
# lr-4034-93265e68e589 NOTE): only the lane's own sentence naming this
# commit is its own comment.
reset
eligible 101 TK-101 in_progress system PASS
comment 101 u_7 5 "You wrote: This is merged and the post-merge check passed. But the button still fails." "Dana"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && grep -qF 'client-spoke=1' <<<"$(advlog)" && ok \
  || bad "M8g: a client quoting 'This is merged and' still holds it (posts=$(posts), log '$(advlog)')"

# ---------------------------------------------------------------------------
# M9: a newer build without RESULT, or with BLOCKED -> newer-build
# ---------------------------------------------------------------------------
for nr in "" "BLOCKED: tests red"; do
  reset
  eligible 101 TK-101 in_progress system PASS
  build TK-101 5 "$nr" >/dev/null
  OUT=$(run x-os)
  [ "$(posts)" = 0 ] && ok || bad "M9 '$nr': no POST (got $(posts))"
  grep -qF 'newer-build=1' <<<"$(advlog)" && ok || bad "M9 '$nr': newer-build=1 (got '$(advlog)')"
done
# a ticket this box never built is not this lane's business, and not a counter
reset
tk 101 TK-101 in_progress system
OUT=$(run x-os)
grep -qF 'moved=0 comment-only=0 skipped: no-audit=0 audit-fail=0 newer-build=0 client-spoke=0 client-review=0' <<<"$(advlog)" \
  && ok || bad "M9b: never built is uncounted (got '$(advlog)')"

# ---------------------------------------------------------------------------
# M10/M11: through inapp_released_lines, a split's last child advances and the
# parent closes in the same tick (done for a system parent, review for a client)
# ---------------------------------------------------------------------------
tick() { # one in-app tick through the real scope stage
  ( cd "$T" && HARNESS="$H" PROJECT=x-os LOG="$H/logs/x-os.log" bash -c \
      '. "$HARNESS/bin/lib/rt/scope.sh"; inapp_released_lines' >/dev/null 2>"$T/tick.err" )
}
for prep in system u_7; do
  reset
  export MERGED_ADVANCE_COOLDOWN_S=0 PARENT_CLOSE_COOLDOWN_S=0
  tk 201 TK-201 done system
  eligible 202 TK-202 in_progress system PASS
  tk 200 TK-200 in_progress "$prep" '[201,202]'
  tick
  want=done; [ "$prep" = u_7 ] && want=review
  [ "$(posts)" = 4 ] && ok || bad "M10 parent=$prep: child comment+move, parent comment+move (got $(posts): $(cat "$B/POSTS.jsonl"))"
  case "$(post_f url 1)|$(post_f url 2)|$(post_f url 3)|$(post_f url 4)" in
    */tickets/202/comments\|*/tickets/202/move\|*/tickets/200/comments\|*/tickets/200/move) ok ;;
    *) bad "M10 parent=$prep: order child then parent (got $(jq -r .url "$B/POSTS.jsonl" | tr '\n' ' '))" ;;
  esac
  grep -qF '"toStatus":"done"' <<<"$(post_f body 2)" && ok || bad "M10 parent=$prep: child moves to done"
  grep -qF "\"toStatus\":\"$want\"" <<<"$(post_f body 4)" && ok || bad "M10 parent=$prep: parent moves to $want (got $(post_f body 4))"
  grep -qF 'parts of this one are in, so I am closing it.' <<<"$(post_f body 3)" && ok \
    || bad "M11 parent=$prep: the parent comment text is unchanged (got $(post_f body 3))"
  grep -qF "PARENT_CLOSED TK-200 (moved to $want)" <<<"$(plog)" && ok || bad "M11 parent=$prep: log names the status: $(plog)"
  [ "$(status_of 200)" = "$want" ] && ok || bad "M10 parent=$prep: board shows $want (got $(status_of 200))"
  : > "$B/POSTS.jsonl"
  tick
  [ "$(posts)" = 0 ] && ok || bad "M10 parent=$prep: a second tick posts nothing (got $(posts): $(cat "$B/POSTS.jsonl"))"
done

# ---------------------------------------------------------------------------
# M12: the move answers 500 once -> next run retries the move only
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
: > "$B/MOVE_FAIL_ONCE"
OUT=$(run x-os)
[ "$(cposts)" = 1 ] && [ "$(mposts)" = 1 ] && ok || bad "M12 run 1: 1 comment + 1 move (c=$(cposts) m=$(mposts))"
grep -qF 'moved=0 comment-only=1' <<<"$(advlog)" && ok || bad "M12 run 1: comment-only=1 (got '$(advlog)')"
[ -z "$OUT" ] && ok || bad "M12 run 1: stdout only on a real move (got '$OUT')"
[ "$(post_f idem 1)" = "advance-x-os-101-abc12345-comment" ] && ok || bad "M12: comment key (got '$(post_f idem 1)')"
[ "$(post_f idem 2)" = "advance-x-os-101-abc12345-move" ] && ok || bad "M12: move key (got '$(post_f idem 2)')"
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(cposts)" = 0 ] && [ "$(mposts)" = 1 ] && ok || bad "M12 run 2: 0 comments + 1 move (c=$(cposts) m=$(mposts))"
grep -qF 'moved=1 comment-only=0' <<<"$(advlog)" && ok || bad "M12 run 2: moved=1 (got '$(advlog)')"
[ "$(post_f idem 1)" = "advance-x-os-101-abc12345-move" ] && ok || bad "M12 run 2: same move key (got '$(post_f idem 1)')"
[ "$OUT" = TK-101 ] && ok || bad "M12 run 2: stdout is the key (got '$OUT')"
# the retry does not depend on knowing the self actor's name: the lane's own
# sentence is never the client speaking (review finding 1)
reset
eligible 101 TK-101 in_progress system PASS
echo "Renamed Board Bot" > "$B/SELF_NAME"
: > "$B/MOVE_FAIL_ONCE"
OUT=$(run x-os)
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(cposts)" = 0 ] && [ "$(mposts)" = 1 ] && ok || bad "M12e run 2: 0 comments + 1 move (c=$(cposts) m=$(mposts), log '$(advlog)')"
grep -qF 'moved=1 comment-only=0' <<<"$(advlog)" && ok || bad "M12e run 2: moved=1 (got '$(advlog)')"
grep -qF 'client-spoke=0' <<<"$(advlog)" && ok || bad "M12e run 2: its own comment is not client-spoke (got '$(advlog)')"
# a 200 that does not echo the target status is not a move (D9)
reset
eligible 101 TK-101 in_progress system PASS
: > "$B/MOVE_NOECHO"
OUT=$(run x-os)
grep -qF 'moved=0 comment-only=1' <<<"$(advlog)" && ok || bad "M12b: an echo-less 200 is comment-only (got '$(advlog)')"
# the marker alone (a thread that does not show the comment yet) stops a
# second comment on the move retry
reset
eligible 101 TK-101 in_progress system PASS
: > "$B/COMMENT_NOPERSIST"; : > "$B/MOVE_FAIL_ONCE"
OUT=$(run x-os)
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(cposts)" = 0 ] && [ "$(mposts)" = 1 ] && ok \
  || bad "M12d: the marker alone stops a second comment (c=$(cposts) m=$(mposts))"
# a comment that does not land: no move, nothing marked
reset
eligible 101 TK-101 in_progress system PASS
echo 500 > "$B/COMMENT_CODE"
OUT=$(run x-os)
[ "$(cposts)" = 1 ] && [ "$(mposts)" = 0 ] && ok || bad "M12c: no move after a failed comment (c=$(cposts) m=$(mposts))"
grep -qF 'MERGED_ADVANCE_FAILED TK-101 comment HTTP 500' <<<"$(plog)" && ok || bad "M12c: failure logged: $(plog)"
grep -qF 'moved=0 comment-only=0' <<<"$(advlog)" && ok || bad "M12c: counts nothing (got '$(advlog)')"
rm -f "$B/COMMENT_CODE"; : > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(cposts)" = 1 ] && [ "$(mposts)" = 1 ] && ok || bad "M12c: the retry sends both (c=$(cposts) m=$(mposts))"

# ---------------------------------------------------------------------------
# M13: kill switch, cap, cooldown, GitHub board, dry run
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
: > "$H/flags/merged-advance-off"
OUT=$(run x-os)
[ "$(reqs)" = 0 ] && ok || bad "M13a: kill switch makes no request (got $(reqs))"

reset
eligible 101 TK-101 in_progress system PASS
eligible 102 TK-102 in_progress system PASS
export MERGED_ADVANCE_MAX=1
OUT=$(run x-os)
[ "$OUT" = TK-101 ] && ok || bad "M13b: MAX=1 advances one (got '$OUT')"
grep -q 'MERGED_ADVANCE_CAPPED 1' <<<"$(plog)" && ok || bad "M13b: the capped remainder is named: $(plog)"
OUT=$(run x-os)
[ "$OUT" = TK-102 ] && ok || bad "M13b: the next run takes the other (got '$OUT')"
export MERGED_ADVANCE_MAX=0
: > "$B/REQS.log"
OUT=$(run x-os)
[ "$(reqs)" = 0 ] && ok || bad "M13b: MAX=0 is off (got $(reqs) requests)"
unset MERGED_ADVANCE_MAX

reset
eligible 101 TK-101 in_progress system PASS
OUT=$(run x-os --cooled)
[ "$OUT" = TK-101 ] && ok || bad "M13c: the first cooled run works (got '$OUT')"
: > "$B/REQS.log"
OUT=$(run x-os --cooled)
[ "$(reqs)" = 0 ] && ok || bad "M13c: the second cooled run makes no request (got $(reqs))"

reset
OUT=$(run ghproj); RC=$?
[ "$RC" = 0 ] && [ "$(reqs)" = 0 ] && ok || bad "M13d: a - board makes no request (rc=$RC reqs=$(reqs))"
[ ! -s "$H/logs/ghproj.log" ] && ok || bad "M13d: and logs nothing"
# no in-app env: silent rc 0, no log line
reset
rm -f "$H/env/x-os.env"
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && [ "$(reqs)" = 0 ] && [ ! -s "$H/logs/x-os.log" ] && ok \
  || bad "M13d: no board env is silent (rc=$RC reqs=$(reqs) log=$(plog))"

reset
eligible 101 TK-101 in_progress system PASS
OUT=$(run x-os --dry-run)
[ "$(posts)" = 0 ] && ok || bad "M13e: dry run posts nothing (got $(posts))"
[ "$(grep -c '^DRYRUN POST https://x.test/api/board/tickets/101/' "$T/err.txt")" = 2 ] && ok \
  || bad "M13e: DRYRUN names both calls on stderr: $(cat "$T/err.txt")"

# ---------------------------------------------------------------------------
# M14: the ledger fallback (no done-file line, a postmerge_qa row says PASS)
# ---------------------------------------------------------------------------
reset
tk 101 TK-101 in_progress system
LBN=$(build TK-101 30 "PR_CREATED $PRU/101")
cat > "$H/bin/lib/ledger-twin.sh" <<SH
lt_read() { LT_VAL=""; [ "\$1" = postmerge_qa ] && [ "\$2" = "$LBN" ] && { LT_VAL=PASS; return 0; }; return 2; }
SH
OUT=$(run x-os)
[ "$OUT" = TK-101 ] && ok || bad "M14: a ledger PASS row advances (got '$OUT', log '$(advlog)')"
BODY=$(post_f body 1 | jq -r '.body' 2>/dev/null)
grep -qF 'commit ' <<<"$BODY" && bad "M14: no commit claimed without a sha: $BODY" || ok
TS=${LBN##*-}
[ "$(post_f idem 1)" = "advance-x-os-101-$TS-comment" ] && ok || bad "M14: build stamp is the dedupe token (got '$(post_f idem 1)')"

# ---------------------------------------------------------------------------
# M15: held tickets never starve the rest (review finding 2)
# ---------------------------------------------------------------------------
# Three tickets the client keeps holding sit ahead of one that can move. With
# MAX=2 the first run spends its cap on two of them; the next run starts where
# that one stopped and reaches the movable ticket.
reset
for i in 1 2 3; do
  eligible "30$i" "TK-30$i" in_progress system PASS
  comment "30$i" u_7 5 "still looking" "Dana"
done
eligible 304 TK-304 in_progress system PASS
export MERGED_ADVANCE_MAX=2
OUT=$(run x-os)
[ -z "$OUT" ] && ok || bad "M15 run 1: nothing moves (got '$OUT')"
grep -q 'MERGED_ADVANCE_CAPPED 2' <<<"$(plog)" && ok || bad "M15 run 1: two left (log $(plog))"
OUT=$(run x-os)
[ "$OUT" = TK-304 ] && ok || bad "M15 run 2: the movable ticket is reached (got '$OUT', log '$(advlog)')"
[ "$(status_of 304)" = done ] && ok || bad "M15 run 2: board shows done (got $(status_of 304))"
unset MERGED_ADVANCE_MAX
OUT=$(run x-os)
[ ! -e "$H/state/merged-advance-x-os.next" ] && ok || bad "M15: an uncapped run clears the start point"

# A client-filed parent already in review is dropped from the parent-close
# list before any request, so it never spends PARENT_CLOSE_MAX: with MAX=1 the
# system parent behind it still closes, and none of its children is read.
reset
tk 401 TK-401 done u_7
tk 400 TK-400 review u_7 '[401]'
tk 411 TK-411 done system
tk 410 TK-410 in_progress system '[411]'
OUT=$(PARENT_CLOSE_MAX=1 "$H/bin/decompose-parent-close.sh" x-os 2>"$T/err.txt")
[ "$OUT" = TK-410 ] && ok || bad "M16: the system parent closes past a client review parent (got '$OUT')"
grep -qE '/tickets/(400|401)$' "$B/REQS.log" && bad "M16: no GET for the client review parent or its child: $(cat "$B/REQS.log")" || ok
[ "$(status_of 400)" = review ] && ok || bad "M16: the client parent stays in review"

# ---------------------------------------------------------------------------
# M17: a person's move back wins (lead review lr-4034-93265e68e589). Once the
# lane's move landed, a ticket found open again was moved back by a person:
# held as moved-back, never moved again, nothing posted.
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
OUT=$(run x-os)
[ "$(status_of 101)" = done ] && ok || bad "M17 setup: the first run moved it to done (got $(status_of 101))"
jq 'map(if .id == 101 then .status = "in_progress" else . end)' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
: > "$B/POSTS.jsonl"
for i in 1 2; do OUT=$(run x-os); done
[ "$(posts)" = 0 ] && ok || bad "M17: a ticket a person moved back is never moved or commented again (posts=$(posts): $(cat "$B/POSTS.jsonl"))"
[ "$(status_of 101)" = in_progress ] && ok || bad "M17: it stays where the person put it (got $(status_of 101))"
grep -qF 'moved-back=1' <<<"$(advlog)" && ok || bad "M17: counted moved-back=1 (got '$(advlog)')"
[ -z "$OUT" ] && ok || bad "M17: nothing on stdout (got '$OUT')"
# the client case: in_progress -> review by the lane, then the client drags it
# back to in_progress
reset
eligible 102 TK-102 in_progress client-a PASS
OUT=$(run x-os)
[ "$(status_of 102)" = review ] && ok || bad "M17b setup: moved to review (got $(status_of 102))"
jq 'map(if .id == 102 then .status = "in_progress" else . end)' "$B/db.json" > "$B/db.tmp" && mv "$B/db.tmp" "$B/db.json"
: > "$B/POSTS.jsonl"
OUT=$(run x-os)
[ "$(mposts)" = 0 ] && [ "$(status_of 102)" = in_progress ] && ok \
  || bad "M17b: the client's move back wins (moves=$(mposts) status=$(status_of 102))"

# ---------------------------------------------------------------------------
# M18: a move that keeps failing retries to MERGED_ADVANCE_MOVE_TRIES, then
# stops with ONE alert; it never posts again after that.
# ---------------------------------------------------------------------------
reset
eligible 101 TK-101 in_progress system PASS
: > "$B/MOVE_FAIL"
for i in 1 2 3 4; do OUT=$(MERGED_ADVANCE_MOVE_TRIES=2 run x-os); done
[ "$(cposts)" = 1 ] && ok || bad "M18: one comment over four runs (got $(cposts))"
[ "$(mposts)" = 2 ] && ok || bad "M18: exactly MERGED_ADVANCE_MOVE_TRIES=2 move attempts over four runs (got $(mposts))"
[ "$(grep -c 'MERGED_ADVANCE_GAVE_UP TK-101' "$H/logs/x-os.log" 2>/dev/null)" = 1 ] && ok \
  || bad "M18: one MERGED_ADVANCE_GAVE_UP line (log: $(plog))"
[ "$(grep -c 'TK-101' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "M18: exactly one alert (ALERTS.log: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -qF 'move-gave-up=1' <<<"$(advlog)" && ok || bad "M18: the last run counts move-gave-up=1 (got '$(advlog)')"
# the default cap is 3 attempts
reset
eligible 101 TK-101 in_progress system PASS
: > "$B/MOVE_FAIL"
for i in 1 2 3 4 5; do OUT=$(run x-os); done
[ "$(mposts)" = 3 ] && ok || bad "M18b: the default cap is 3 move attempts (got $(mposts))"

echo "merged-ticket-advance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
