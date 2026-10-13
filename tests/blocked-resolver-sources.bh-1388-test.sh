#!/bin/bash
# tests/blocked-resolver-sources.bh-1388-test.sh — BH-1388 (BH-1025.3): the
# resolver's hand-off source and its ladder caps read the PR-state ROWS, not
# only the hub's own files.
#
# WHY THIS EXISTS. Every durable thing this lane knows lives in two files on ONE
# box: `logs/merge-conductor.log` (which hand-offs happened) and
# `state/blocked-resolver/<p>/<key>.json` (how many rungs this ticket has
# already bought). A rebuilt hub has neither, so the lane forgets every open
# hand-off and — worse — forgets that a ticket has already been rebuilt three
# times, which makes the ABANDONED cap evadable by losing a file. BH-1025.0
# (#1385) put both facts in rows; this ticket reads them.
#
# WHAT IS DRIVEN. The REAL bin/blocked-resolver.sh, end to end, in a scratch
# $HARNESS, with the REAL bin/jobs-client.sh behind a curl shim that records
# every method, path and body. Nothing here greps the lane's source: every
# assertion is a line in the lane's own log, a field in the record JSON it
# wrote, or a request in the sink.
#
# THE FLAG IS THE POINT. `pr-state-rows` ships OFF, so every case has a
# flag-off twin: with the flag down the decisions are the ones this lane made
# yesterday and the sink holds no /api/pr-* request at all.
#
# Run from anywhere: bash tests/blocked-resolver-sources.bh-1388-test.sh
# (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every age
# below is derived from it, so "older than the age knob" is true by
# construction whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" \
         "$H/env" "$H/builds" "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1
# THE REAL JOBS CLIENT, not a stub: pr_rows_on, pr_state_events_page,
# pr_state_page, pr_attempt_put and pr_attempt_count are the contract under
# test, so the fixture drives the shipped ones behind a curl shim (BH-1194: the
# client refuses to run without bin/lib/jobs/*.sh beside it).
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
chmod +x "$H/bin/"*.sh
printf 'tproj example-org/x - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

# ── the curl shim ───────────────────────────────────────────────────────────
# The BH-1385 shape, extended with the three routes this ticket reads:
#   /api/pr-state-events  answered from $EVENTS_JSON   (404 when absent)
#   /api/pr-state         answered from $STATE_JSON    (404 when absent)
#   /api/pr-attempts      GET -> {"count":N} from $ATTEMPT_COUNT for that kind;
#                         PUT -> recorded, 200.
# /api/flags/* is always a 404, so flag_active falls to the FILE — its own
# documented contract, and what makes `flags/pr-state-rows` the switch here.
# CURL_DOWN_PATH makes exactly one route family a TRANSPORT failure (exit 7),
# which is what a worker outage looks like to bin/lib/jobs/req.sh — and it is
# surgical on purpose: "the rows are out" must not also mean "the queue is out".
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s|-L|-f) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
if [ -n "${CURL_DOWN_PATH:-}" ]; then
  case "$URL" in *"$CURL_DOWN_PATH"*) exit 7 ;; esac
fi
case "$URL" in
  */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;;
  */api/pr-state-events*)
    if [ -s "${EVENTS_JSON:-/dev/null}" ]; then cat "$EVENTS_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi
    exit 0 ;;
  */api/pr-state*)
    if [ -s "${STATE_JSON:-/dev/null}" ]; then cat "$STATE_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi
    exit 0 ;;
  */api/pr-attempts*)
    if [ "$METHOD" = PUT ]; then
      [ -n "${ATTEMPT_PUTS:-}" ] && printf '%s\n' "$BODY" >> "$ATTEMPT_PUTS"
      printf '{"ok":true}\n200\n'; exit 0
    fi
    K=$(ud "$(qp kind)")
    N=$(awk -F'\t' -v k="$K" '$1==k {print $2; exit}' "${ATTEMPT_COUNT:-/dev/null}" 2>/dev/null)
    if [ -n "$N" ]; then jq -nc --argjson n "$N" '{count:$n}'; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi
    exit 0 ;;
  */api/queue*)
    if [ "$METHOD" = GET ]; then
      # A row in a TERMINAL status: br_rebuild_inflight reads "not in flight"
      # (rc 1) from it, which is the state every ladder case here wants — and a
      # 404 would be read as "the queue is unreadable" (rc 2) instead, which
      # HOLDS at the cap rather than abandoning.
      jq -nc --arg e "${QUEUE_ENQ:-2026-09-22T00:00:00Z}" \
        '{queue:[{project:"tproj",ticket_key:"TK-9",ticket_id:"9",status:"done",target:"fly",attempt:0,claimed_by:"-",enqueued_at:$e,reason:"-"}]}'
      printf '\n200\n'; exit 0
    fi
    [ -n "${QUEUE_PUTS:-}" ] && printf '%s\n' "$BODY" >> "$QUEUE_PUTS"
    printf '{"ok":true}\n200\n'; exit 0 ;;
  */api/ledger*) printf '{"error":"not found"}\n404\n'; exit 0 ;;
esac
printf '{"ok":true}\n200\n'
CURL
chmod +x "$T/fakebin/curl"

# ── the gh shim ─────────────────────────────────────────────────────────────
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a parked ticket' "\$N" > "$T/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"
: > "$T/mergedprs"; printf '[]\n' > "$T/openprs"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"; : > "$T/ssh.txt"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# The fixture issue, unlabelled-held, so the hold gate never refuses a rung.
jq -nc --arg t "TK-9: a parked ticket" --arg c "$(ISO 604800)" \
  '{number:9,state:"open",labels:[{name:"ai-build"}],title:$t,body:"## Scope",created_at:$c}' \
  > "$T/issue-9.json"
echo '[]' > "$T/comments-9.json"

URL="https://github.com/example-org/x/pull/9"
HEAD9=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RLOG="$H/logs/blocked-resolver.log"
REQ="$T/req.log"
ROWS="$H/state/merge-conductor/pr-state.tsv"
EVENTS="$T/events.json"
STATE="$T/state.json"
ATTC="$T/attempt-count.tsv"
PUTS="$T/attempt-puts.txt"
QPUTS="$T/queue-puts.txt"

RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           HARNESS_SECRET=x JOBS_BOX=testbox JOBS_URL=http://jobs.test \
           JOBS_RETRIES=0 JOBS_ALERT=0 REQ_LOG="$REQ" \
           EVENTS_JSON="$EVENTS" STATE_JSON="$STATE" \
           ATTEMPT_COUNT="$ATTC" ATTEMPT_PUTS="$PUTS" QUEUE_PUTS="$QPUTS" \
           CURL_DOWN_PATH="${CURL_DOWN_PATH:-}" \
           BR_HANDOFF_MAX_AGE_SECS="${BR_HANDOFF_MAX_AGE_SECS:-172800}" \
           ROUTING_ROWS=off \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }

RESET() {
  : > "$RLOG"; : > "$REQ"; : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"
  : > "$T/alerts.txt"; : > "$T/ssh.txt"; : > "$T/run.log"; : > "$PUTS"; : > "$QPUTS"
  rm -f "$H/logs/ALERTS.log" "$H/logs/merge-conductor.log" "$EVENTS" "$STATE" "$ATTC"
  : > "$ROWS"
  scratch_rm "$H/state/blocked-resolver" 2>/dev/null
  scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
  scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
  scratch_rm "$H/state/flags-db" 2>/dev/null
  echo OPEN > "$T/prstate"
  printf '%s' "$HEAD9" > "$T/prhead"
  CURL_DOWN_PATH=""
  BR_HANDOFF_MAX_AGE_SECS=172800
}
FLAG_ON()  { touch "$H/flags/pr-state-rows"; }
FLAG_OFF() { rm -f "$H/flags/pr-state-rows"; }
OBSERVE_ON()  { touch "$H/flags/blocked-resolver-observe"; }
OBSERVE_OFF() { rm -f "$H/flags/blocked-resolver-observe"; }

# EVENT <reason> <head> <at-seconds-ago> [state] — one pr_state_events row.
EVENT() {
  jq -nc --arg r "${4:-BLOCKED_HUMAN}" --arg rs "$1" --arg h "$2" --arg u "$URL" \
         --arg si "$(ISO "${3:-600}")" --arg at "$(ISO "${3:-600}")" \
    '{rows:[{id:1,repo:"example-org/x",number:9,state:$r,since:$si,head:$h,
             reviewed:"-",reason:$rs,url:$u,alerted:"-",at:$at}]}' > "$EVENTS"
}
# VIEW <state> — the pr_state view's answer for example-org/x#9.
VIEW() { jq -nc --arg s "$1" '{rows:[{repo:"example-org/x",number:9,state:$s}]}' > "$STATE"; }
# CANDIDATE — did the lane offer this park a rung at all?
CANDIDATE() { grep -q 'tproj/example-org-x-9 \[conductor/' "$RLOG"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
REASON="conflict-unresolvable: CONFLICT (content): Merge conflict in a.txt"

# ===========================================================================
# 1. THE HAND-OFF SOURCE
# ===========================================================================
echo "== hand-off rows =="
OBSERVE_ON

# (a) THE ROWS ALONE. No merge-conductor.log, no pr-state.tsv, no hand-off
#     file — a rebuilt hub. The rows are the only record that this PR was
#     handed over, and the lane must still offer it a rung.
RESET; FLAG_ON
EVENT "$REASON" "$HEAD9" 600; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && ok || bad "(a) a hand-off that exists only as rows must be offered: $(cat "$RLOG")"
grep -q 'conflict-unresolvable' "$RLOG" && ok \
  || bad "(a) the raw row reason must normalize to the ladder's word: $(cat "$RLOG")"
grep -q 'GET http://jobs.test/api/pr-state-events' "$REQ" && ok \
  || bad "(a) the event page must actually be read: $(cat "$REQ")"

# (b) FLAG OFF is the shipped state: the same rows, no candidate, and not one
#     /api/pr-state request in the sink.
RESET; FLAG_OFF
EVENT "$REASON" "$HEAD9" 600; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && bad "(b) with the flag off the rows must not be read: $(cat "$RLOG")" || ok
grep -q '/api/pr-state' "$REQ" \
  && bad "(b) a dark lane must make no pr-state request: $(grep '/api/pr-state' "$REQ")" || ok

# (c) THE ROWS ARE OUT and the log has the hand-off: today's path, unchanged.
RESET; FLAG_ON
EVENT "$REASON" "$HEAD9" 600; VIEW BLOCKED_HUMAN
CURL_DOWN_PATH=/api/pr-state
printf '%s example-org/x#9 BLOCKED_AGENT conflict-unresolvable: a.txt — handed to bin/blocked-resolver.sh (fix round, or a fresh rebuild): %s\n' \
  "$(date -u -d "@$((NOW - 600))" '+%Y-%m-%d %H:%M:%S')Z" "$URL" > "$H/logs/merge-conductor.log"
mkdir -p "$H/state/merge-conductor/handoff"
printf '%s\t%s\n' "$((NOW - 600))" "$HEAD9" > "$H/state/merge-conductor/handoff/example-org_x_9"
RUN
CANDIDATE && ok || bad "(c) a rows OUTAGE must fall back to the hand-off log: $(cat "$RLOG")"

# (f) A FULL PAGE IS NOT AN ANSWER (lead review N3). pr_state_page is one page
#     of 1000; with more PR states than that, this PR's latest state can sit on
#     a page never read, and "missing from the view" would read as "no longer
#     parked" — an rc 2 that silences the log too. A page that came back full
#     must be rc 1 instead, so the log (today's path) answers.
RESET; FLAG_ON
EVENT "$REASON" "$HEAD9" 600
jq -nc '{rows:[range(1000) | {repo:"example-org/y", number:(. + 1), state:"MERGED"}]}' > "$STATE"
printf '%s example-org/x#9 BLOCKED_AGENT conflict-unresolvable: a.txt — handed to bin/blocked-resolver.sh (fix round, or a fresh rebuild): %s\n' \
  "$(date -u -d "@$((NOW - 600))" '+%Y-%m-%d %H:%M:%S')Z" "$URL" > "$H/logs/merge-conductor.log"
mkdir -p "$H/state/merge-conductor/handoff"
printf '%s\t%s\n' "$((NOW - 600))" "$HEAD9" > "$H/state/merge-conductor/handoff/example-org_x_9"
RUN
CANDIDATE && ok || bad "(f) a full pr_state page must fall back to the hand-off log, not read as 'none': $(cat "$RLOG")"
grep -q 'recovered from the hand-off rows' "$RLOG" \
  && bad "(f) a full page must not be read as the rows' answer: $(cat "$RLOG")" || ok

# (d) THE VIEW SAYS THE PARK IS OVER. The event happened, but this PR's latest
#     state is NEEDS_REBASE — the conductor owns it again and a rebuild here
#     would race it.
RESET; FLAG_ON
EVENT "$REASON" "$HEAD9" 600; VIEW NEEDS_REBASE
RUN
CANDIDATE && bad "(d) a PR whose latest state is NEEDS_REBASE is not a hand-off: $(cat "$RLOG")" || ok

# (e) TOO OLD. The age knob is the same one the log source has always used.
RESET; FLAG_ON
BR_HANDOFF_MAX_AGE_SECS=60
EVENT "$REASON" "$HEAD9" 6000; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && bad "(e) an event older than BR_HANDOFF_MAX_AGE_SECS must not be offered: $(cat "$RLOG")" || ok

# --- adversarial negatives. The rows source gates a REBUILD, which is a spend.
# A reason the conductor does not hand over (mc_handoff_owns says no).
RESET; FLAG_ON
EVENT "migration-gated: waiting on an apply" "$HEAD9" 600; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && bad "neg1: a reason the conductor never hands over must not be offered: $(cat "$RLOG")" || ok

# A contested loser: br_reason_of answers empty, so no rung is ever offered.
RESET; FLAG_ON
EVENT "contested: a.txt held by TK-3" "$HEAD9" 600; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && bad "neg2: a contested loser must not be offered: $(cat "$RLOG")" || ok

# The PR has since MERGED: the #304 guard still runs on a rows-sourced park.
RESET; FLAG_ON
EVENT "$REASON" "$HEAD9" 600; VIEW BLOCKED_HUMAN
echo MERGED > "$T/prstate"
RUN
grep -q 'tproj/example-org-x-9 \[conductor/conflict-unresolvable\] ->' "$RLOG" \
  && bad "neg3: a merged PR must never reach a rung: $(cat "$RLOG")" || ok

# The head moved under the hand-off: somebody is working on it.
RESET; FLAG_ON
EVENT "$REASON" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 600; VIEW BLOCKED_HUMAN
RUN
CANDIDATE && bad "neg4: a park whose live head differs from the event head must not be offered: $(cat "$RLOG")" || ok

# ===========================================================================
# 2. THE LADDER — attempts are rows too, and the cap survives a wiped file
# ===========================================================================
echo "== ladder =="
OBSERVE_OFF
# TEST-CHANGE (BH-1372, cbb8e7f5): br_enqueue_fresh routes through
# br_pool_routed -> routing_builder (bin/lib/jobs/routing.sh), which answers
# `pool` only when BOTH flags/builder-fly-<p> and flags/fly-pool-<p> exist. The
# fixture's project is a pool project, so it carries both; ROUTING_ROWS=off in
# RUN keeps routing_builder on those files and off the unstubbed worker.
touch "$H/flags/fly-pool-tproj" "$H/flags/builder-fly-tproj"
MFT="merge-failed-twice: gh pr merge refused"
# ROWADD — one conductor row in the FILE source, which this ticket does not
# touch: the ladder cases are about what br_record and the caps do, not about
# where the park was found.
ROWADD() { printf 'example-org/x#9\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$((NOW - 600))" "$HEAD9" "$HEAD9" "$1" "$URL" >> "$ROWS"; }

# (i) A DRIVEN REBUILD writes the file line AND the row, in that order.
RESET; FLAG_ON
ROWADD "$MFT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 1 ] && ok \
  || bad "(i) the rebuild rung must have run (record: $(STATEJSON tproj-TK-9 | jq -c '{rebuilds,outcome}') log: $(tail -5 "$RLOG"))"
[ "$(grep -c '"kind":"rebuild"' "$PUTS")" = 1 ] && ok \
  || bad "(i) exactly one pr_attempts row must be written for the rebuild (puts: $(cat "$PUTS"))"
# TEST-CHANGE (BH-2358): releasing the hand-off is now a `handoff-rel` row for
# the parked head as well, so $PUTS holds two rows; the rebuild row is picked
# out by kind (its count is pinned above) and the release row is pinned too.
jq -se 'map(select(.kind == "rebuild")) | length == 1 and all(.repo == "example-org/x" and .number == 9 and .sha == "-")' \
  < "$PUTS" >/dev/null 2>&1 && ok \
  || bad "(i) the attempt row must name the repo, the number and the kind: $(cat "$PUTS")"
jq -se --arg h "$HEAD9" 'map(select(.kind == "handoff-rel")) | length == 1 and all(.repo == "example-org/x" and .number == 9 and .sha == $h)' \
  < "$PUTS" >/dev/null 2>&1 && ok \
  || bad "(i) the hand-off release must be one handoff-rel row for the parked head: $(cat "$PUTS")"
grep -q 'PUT http://jobs.test/api/pr-attempts' "$REQ" && ok \
  || bad "(i) the attempt row must be a real PUT: $(cat "$REQ")"

# (ii) THE FILE IS GONE AND THE ROWS REMEMBER. A rebuilt hub: three rebuild
#      attempts are on record in the rows, no file at all. The cap must hold —
#      losing a file must not buy a fourth build.
RESET; FLAG_ON
printf 'rebuild\t3\n' > "$ATTC"
ROWADD "$MFT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] && ok \
  || bad "(ii) THE CAP MUST SURVIVE A WIPED FILE (record: $(STATEJSON tproj-TK-9 | jq -c '{rebuilds,outcome}') log: $(tail -6 "$RLOG"))"
[ "$(grep -c 'POST http://jobs.test/api/queue' "$REQ")" = 0 ] && ok \
  || bad "(ii) an exhausted ladder must enqueue nothing: $(grep 'api/queue' "$REQ")"
grep -q 'pr_attempts holds 3' "$RLOG" && ok \
  || bad "(ii) the lane must SAY it read the cap off the rows: $(tail -6 "$RLOG")"

# (iii) FLAG OFF, same fixture: today's behaviour exactly — the rows are never
#       read, the cap is the file's zero, and the rebuild is enqueued.
RESET; FLAG_OFF
printf 'rebuild\t3\n' > "$ATTC"
ROWADD "$MFT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] \
  && bad "(iii) with the flag off a wiped file starts from zero, as today: $(STATEJSON tproj-TK-9 | jq -c '{rebuilds,outcome}')" || ok
[ "$(grep -c 'POST http://jobs.test/api/queue' "$REQ")" = 1 ] && ok \
  || bad "(iii) the dark lane must still enqueue the rebuild: $(grep 'api/queue' "$REQ")"
[ ! -s "$PUTS" ] && ok || bad "(iii) a dark lane must write no attempt row: $(cat "$PUTS")"
grep -q '/api/pr-attempts' "$REQ" \
  && bad "(iii) a dark lane must make no pr-attempts request: $(grep '/api/pr-attempts' "$REQ")" || ok

# (iv) AN OUTAGE IS NEVER A COUNT (D11). The rows are unreachable; the cap falls
#      back to the file's own counter and the rebuild goes ahead.
RESET; FLAG_ON
printf 'rebuild\t3\n' > "$ATTC"
CURL_DOWN_PATH=/api/pr-attempts
ROWADD "$MFT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] \
  && bad "(iv) an unreadable attempts route must never abandon a ticket: $(tail -6 "$RLOG")" || ok
[ "$(grep -c 'POST http://jobs.test/api/queue' "$REQ")" = 1 ] && ok \
  || bad "(iv) an attempts outage must leave the rebuild exactly as today: $(grep 'api/queue' "$REQ")"

echo "blocked-resolver-sources.bh-1388-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
