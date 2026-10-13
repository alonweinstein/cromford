#!/bin/bash
# tests/pr-attempts-idempotent.bh-1387-test.sh — BH-1387 (BH-1025.2): the
# conductor's PR-keyed attempt ledger goes through the contract helpers
# (mc_attempt_has / mc_attempt_put), state transitions append pr_state_events
# rows, and pr-state.tsv rehydrates from the pr_state view.
#
# WHAT IT PINS.
#   1. (a)-(e) through rebase_consume's `rebasedone` read-once guard, which was
#      a bare file read before this change. With the flag on and an EMPTY
#      attempts.txt, a warm pr_attempts row warms the file and the finished
#      rebase is NOT re-applied; a row for a different head does not dedupe; an
#      outage (curl exit 7) fails open, raises one ALERTS line and is paid once;
#      a 500 on the PUT still leaves the file line (file first).
#   2. With the flag off the conductor makes no /api/pr-attempts,
#      /api/pr-state-events or /api/pr-state request at all, and the
#      pr-state.tsv and attempts.txt it leaves behind are the ones origin/main's
#      code leaves (7c2, when origin/main is readable).
#   3. A transition and the budget alert that follows it each append exactly one
#      pr_state_events row, after the ledgers row, with the same state/since and
#      the file's alert mark; a dead event POST changes nothing upstream. The
#      held-page flush's alert mark (6d) appends one too, with no ledgers row,
#      and with the flag off it leaves the same pr-state.tsv.
#   4. Rehydrate prefers the pr_state view (8 columns, alerted sixth, since an
#      epoch); a 404 view or one longer than MC_REHYDRATE_PAGES falls back to the
#      ledger path and never writes a partial file; MC_REHYDRATE=0 still wins.
#   5. A line that is not PR-keyed makes NO /api/pr-attempts request at all,
#      beside a positive control that does.
#
# HOW IT MEASURES. Artifacts only: the curl request sink, the git-shim log,
# state/merge-conductor/attempts.txt, state/merge-conductor/pr-state.tsv, and
# logs/merge-conductor.log / jobs-client.log. Never a grep over source text.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-attempts-idempotent.bh-1387-test.sh (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" \
         "$H/flags" "$H/logs" "$H/locks" "$H/state/merge-conductor" \
         "$H/state/merge-conductor/rr" "$H/state/merge-conductor/rb" \
         "$H/state/merge-conductor/dv" "$H/repos/a/.git" "$T/fakebin" \
         "$H/tmp/conductor" "$H/builds"

# Copy the conductor and every helper it may reach. Fail-open stubs below cover
# the libs a scratch tree does not need.
cp "$DIR/bin/merge-conductor.sh" "$H/bin/" || exit 1
cp "$DIR/bin/fleet-conf.sh"      "$H/bin/" || exit 1
cp "$DIR/bin/jobs-client.sh"     "$H/bin/" || exit 1
cp "$DIR/bin/lib/env-path.sh"    "$H/bin/lib/" || exit 1
cp "$DIR/bin/lib/jobs/"*.sh      "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/mc/"*.sh        "$H/bin/lib/mc/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
# NOT gh-limit-logger.sh: it defines its own `gh()` that calls `command gh`,
# which would shadow the REST list bridge sourced below (the conductor sources it
# only when it is readable, so leaving it out is a supported shape).
for s in gh-pr-list.sh gh-rest.sh gh-budget.sh gh-repo-token.sh gh-app-auth.sh \
         gh-pr-merge.sh main-red-gate.sh block-gate.sh \
         pr-dep-gate.sh lane-gate.sh lane-env.sh heartbeat.sh flaky.sh \
         review-provenance.sh review-post.sh hotfix-lib.sh gh-push-identity.sh; do
  [ -r "$DIR/bin/lib/$s" ] && cp "$DIR/bin/lib/$s" "$H/bin/lib/" 2>/dev/null || true
done

ATT="$H/state/merge-conductor/attempts.txt"
ROW="$H/state/merge-conductor/pr-state.tsv"
REQ="$T/req.log"
ERR="$T/err.log"
GITLOG="$T/git.log"
GHLOG="$T/gh.log"
GHWARN="$T/gh-writes.txt"

SLUG=example-org/a
KEY="$SLUG#7"
URL="https://github.com/$SLUG/pull/7"
H1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
H2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SINCE_EPOCH=1727001600
SINCE_ISO=2026-09-22T10:00:00Z

# The project fleet.conf: one project 'a' mapped to example-org/a.
printf '%s\n' 'a example-org/a https://demo.example /api/board 2 box-a' > "$H/fleet.conf"

# Silence land-rebase (BH-870) so the tick stays on the single PR.
: > "$H/env/global.env"

# ── the curl shim ───────────────────────────────────────────────────────────
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
[ "${CURL_MODE:-ok}" = down ] && exit 7
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
DEFBODY='{"ok":true}'
case "$URL" in
  */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;;
  */api/pr-attempts*)
    if [ "$METHOD" = GET ]; then
      # A MISS IS A 404, because that is what pr_attempt_has reads as rc 2 (a
      # real miss). A 200 with {"count":0} is rc 0 — "the row is there" — and a
      # shim that answered that way would dedupe every attempt in the suite.
      ksha=$(ud "$(qp sha)"); kkind=$(ud "$(qp kind)")
      # TEST-CHANGE (BH-2357): a LIST (no sha) is always a 200, as the route
      # answers it (worker/jobs/src/routes/pr-state.js). read_memo_fp now lists
      # a PR's rows every tick, and a 404 there is a wire the worker never
      # sends: the client reads it as an outage and latches the tick's rows off.
      [ -z "$ksha" ] && { printf '{"attempts":[],"count":0}\n200\n'; exit 0; }
      if [ -n "${PR_ATTEMPT_WARM:-}" ] && case " ${PR_ATTEMPT_WARM_KIND:-rebase} " in *" $kkind "*) true ;; *) false ;; esac; then
        if [ "$PR_ATTEMPT_WARM" = 1 ] || [ "$PR_ATTEMPT_WARM" = "$ksha" ]; then
          printf '{"count":1}\n200\n'; exit 0
        fi
      fi
      printf '{"error":"not found"}\n404\n'; exit 0
    fi
    if [ "$METHOD" = PUT ] && [ "${PUT_MODE:-ok}" = fail ]; then
      printf '{"error":"boom"}\n500\n'; exit 0
    fi
    printf '%s\n%s\n' '{"ok":true}' 200; exit 0 ;;
  */api/pr-state\?*)
    if [ -n "${PR_STATE_FILE:-}" ]; then
      printf '%s\n200\n' "$(cat "$PR_STATE_FILE")"; exit 0
    fi
    if [ -n "${PR_STATE_ROWS:-}" ]; then
      printf '%s\n200\n' "$PR_STATE_ROWS"; exit 0
    fi
    if [ "${CURL_STATUS:-200}" = 404 ]; then
      printf '{"error":"not found"}\n404\n'; exit 0
    fi
    printf '{"rows":[]}\n200\n'; exit 0 ;;
  */api/pr-state-events)
    [ "${EVENTS_MODE:-ok}" = down ] && exit 7
    printf '%s\n%s\n' '{"ok":true}' 200; exit 0 ;;
  */api/ledger\?*)
    if [ -n "${LEDGER_ROWS:-}" ]; then
      jq -nc --argjson rows "$(cat "$LEDGER_ROWS")" '{ledgers:$rows}'; printf '\n200\n'; exit 0
    fi
    printf '{"error":"not found"}\n404\n'; exit 0 ;;
  */api/ledger)
    printf '%s\n%s\n' '{"ok":true}' 200; exit 0 ;;
  */api/conductor/held/release) printf '{"released":1}\n200\n'; exit 0 ;;
  */api/conductor/held\?*)
    if [ -s "${HELD_JSON:-}" ]; then printf '%s\n200\n' "$(cat "$HELD_JSON")"; exit 0; fi
    printf '{"rows":[]}\n200\n'; exit 0 ;;
esac
printf '%s\n%s\n' "${CURL_BODY:-$DEFBODY}" "${CURL_STATUS:-200}"
CURL
chmod +x "$T/fakebin/curl"

# ── the git shim ─────────────────────────────────────────────────────────────
# Counts rev-parse HEAD calls so the first (post-checkout) returns the original
# head and the second (pre-push) returns the new head. Push is recorded and fails.
cat > "$T/fakebin/git" <<GIT
#!/bin/bash
printf '%s\n' "\$*" >> "$GITLOG"
cmd="\$*"
case "\$cmd" in
  *"ls-remote"*) exit 0 ;;
  *"remote set-url"*) exit 0 ;;
  *"fetch"*) exit 0 ;;
  *"worktree add"*)
    wt=\$(printf '%s\n' "\$cmd" | sed 's/.*worktree add -f //; s/ origin.*//')
    mkdir -p "\$wt/.git"
    exit 0 ;;
  *"rev-parse HEAD"*)
    cntf="$T/git-rev-count"
    n=\$(cat "\$cntf" 2>/dev/null || echo 0)
    n=\$((n + 1))
    printf '%s\n' "\$n" > "\$cntf"
    if [ "\$n" -eq 1 ]; then printf '%s\n' "\${GIT_HEAD:-$H1}"
    else printf '%s\n' "\${GIT_NEW_HEAD:-$H2}"; fi
    exit 0 ;;
  *"merge -q --no-edit"*) exit 0 ;;
  *"diff --name-only --diff-filter=U"*) exit 0 ;;
  *"diff --cached --quiet"*) exit 0 ;;
  *"commit"*) exit 0 ;;
  *"push"*) exit 1 ;;
  *"checkout"*) exit 0 ;;
  *"rev-parse --is-shallow-repository"*) echo false; exit 0 ;;
  *"merge --abort"*) exit 0 ;;
  *"worktree remove"*) exit 0 ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$T/fakebin/git"

# ── the gh shim ──────────────────────────────────────────────────────────────
# Provides one open, conflicted harness PR for project a and fails on any write.
# GH_HEAD env overrides the PR head (default H1).
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$GHLOG"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB: \$*" >> "$GHWARN"; exit 1 ;;
  *"pr list -R $SLUG --state open"*)
    head="\${GH_HEAD:-$H1}"
    cat <<J
[{"number":7,"url":"https://github.com/$SLUG/pull/7","headRefOid":"\$head","headRefName":"ticket/bh-1387","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"repos/$SLUG/pulls?state=closed"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
GH
chmod +x "$T/fakebin/gh"
# The open-PR list is REST since BH-1585 (a `pulls?state=open` page plus lazy
# per-PR reads). This stub still describes it as the GraphQL `pr list --state
# open`, so the bridge answers the REST reads from that description, as in every
# sibling conductor suite. Without it the tick sees no PR at all.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1

# ── beat / agent-call / deploy-verify stubs ───────────────────────────────────
for s in beat.sh agent-call.sh deploy-verify.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"
done

# ── run_tick: invoke the copied merge-conductor.sh with a clean request sink ─
run_tick() {
  : > "$REQ"
  : > "$ERR"
  : > "$GITLOG"
  rm -f "$T/git-rev-count"
  ( cd "$T" &&
    PATH="$T/fakebin:$PATH" \
    HARNESS="$H" \
    HARNESS_SECRET=x \
    JOBS_BOX=testbox \
    JOBS_RETRIES=0 \
    JOBS_ALERT="${JOBS_ALERT:-0}" \
    JOBS_URL=http://jobs.test \
    MC_REPOS="$H/repos" \
    MC_RR_PATH="$T/fakebin:$PATH" \
    REQ_LOG="$REQ" \
    GITLOG="$GITLOG" \
    GHLOG="$GHLOG" \
    GHWARN="$GHWARN" \
    CURL_MODE="${CURL_MODE:-ok}" \
    CURL_STATUS="${CURL_STATUS:-}" \
    CURL_BODY="${CURL_BODY:-}" \
    GH_HEAD="${GH_HEAD:-}" \
    PR_ATTEMPT_WARM="${PR_ATTEMPT_WARM:-}" \
    PR_ATTEMPT_WARM_KIND="${PR_ATTEMPT_WARM_KIND:-rebase}" \
    PR_STATE_ROWS="${PR_STATE_ROWS:-}" \
    PR_STATE_FILE="${PR_STATE_FILE:-}" \
    EVENTS_MODE="${EVENTS_MODE:-ok}" \
    HELD_JSON="${HELD_JSON:-}" \
    MC_REHYDRATE_PAGES="${MC_REHYDRATE_PAGES:-5}" \
    LEDGER_ROWS="${LEDGER_ROWS:-}" \
    PUT_MODE="${PUT_MODE:-ok}" \
    GIT_HEAD="${GIT_HEAD:-$H1}" \
    GIT_NEW_HEAD="${GIT_NEW_HEAD:-$H2}" \
    MC_DETACHED_REBASE="${MC_DETACHED_REBASE:-0}" \
    MC_REHYDRATE="${MC_REHYDRATE:-1}" \
    bash "$H/bin/merge-conductor.sh" >/dev/null 2>>"$ERR" ) || {
      echo "NOTE: tick rc=$? stderr:" >&2
      tail -10 "$ERR" >&2
    }
}

flag_on()  { : > "$H/flags/pr-state-rows"; }
flag_off() { rm -f "$H/flags/pr-state-rows"; }
actions_on()  { : > "$H/flags/merge-conductor-actions"; }
actions_off() { rm -f "$H/flags/merge-conductor-actions"; }
tighten_on()  { : > "$H/flags/review-tighten-example-org-a"; }
tighten_off() { rm -f "$H/flags/review-tighten-example-org-a"; }
reset_state() { : > "$ATT"; : > "$ROW"; rm -f "$H"/logs/*.log "$H"/flags/alerted-jobs-client-*; }

npr()   { grep -c '/api/pr-' "$REQ" 2>/dev/null || true; }
lastreq() { grep -v '/api/flags/' "$REQ" 2>/dev/null | tail -1; }
mu()    { printf '%s' "$1" | awk '{print $1" "$2}'; }
has_git_push() { grep -q ' push ' "$GITLOG" 2>/dev/null; }

# Helper: write a pr-state.tsv row.
row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$ROW"
}

# Helper: write a done detached-rebase job file for (slug,num,head).
# Uses the same key convention as mc_rr_key: owner_repo_<num>_<head>.
job_done() {
  local slug="$1" num="$2" head="$3" rc="$4" out="$5" jf of now
  jf="$H/state/merge-conductor/rebase/${slug//\//_}_${num}_${head}.json"
  of="${jf%.json}.out"
  mkdir -p "$(dirname "$jf")"
  printf '%s' "$out" > "$of"
  now=$(date +%s)
  jq -nc --arg s done --argjson p "$$" --argjson st "$now" --argjson fin "$now" \
    --arg rc "$rc" --arg pr "$slug#$num" --arg sha "$head" --arg b "-" --arg o "$of" \
    '{status:$s,pid:$p,started_at:$st,finished_at:$fin,rc:$rc,project:$pr,sha:$sha,build:$b,out_file:$o}' \
    > "$jf" 2>/dev/null
  printf '%s\n' "$jf"
}

# Helper: assert attempts.txt contains a line for (kind,key,head).
attempt_line() {
  local kind="$1" k="$2" h="$3"
  grep -qxF "$kind $k $h" "$ATT" 2>/dev/null
}

# Helper: return the number of POST /api/pr-state-events bodies.
n_events() {
  grep -c '^POST http://jobs.test/api/pr-state-events ' "$REQ" 2>/dev/null || true
}

# Helper: the Nth POST /api/pr-state-events body.
event_body() {
  awk -v n="$1" '
    /^POST http:\/\/jobs.test\/api\/pr-state-events / {
      if (++c == n) { body=$0; sub(/^[^ ]+ [^ ]+ /,"",body); print body; exit }
    }
  ' "$REQ"
}

# Helper: count log lines matching a pattern in merge-conductor.log.
nlog() {
  local pat="$1"
  grep -c "$pat" "$H/logs/merge-conductor.log" 2>/dev/null || true
}

# Helper: count jobs-client.log lines matching a pattern.
njobs() {
  local pat="$1"
  grep -c "$pat" "$H/logs/jobs-client.log" 2>/dev/null || true
}

# THE CONSUME PATH IS THE ONE UNDER TEST FOR (a)-(e). The inline rebase site
# already went through mc_attempted before this change, so a warm `rebase` row
# proves nothing about it; `rebasedone` (rebase_consume's read-once guard) was a
# bare file read until BH-1387, so a warm row for it is the case that tells
# the two apart. Every case seeds a FINISHED detached job for (#7, H1) that
# pushed H2, and a row that is not NEEDS_REBASE, so the only way that result
# gets applied is a rebasedone miss.
seed_done_job() {
  row "$KEY" WAIT_CI "$SINCE_EPOCH" "$H1" "-" "-" "fixture" "$URL"
  job_done "$SLUG" 7 "$H1" 0 "$H2" >/dev/null
}
applied() { grep -c "$KEY rebased" "$H/logs/merge-conductor.log" 2>/dev/null || true; }

echo "== 1. (a) a warm rebasedone/rebase row dedupes: no re-apply, no push, file warmed =="
reset_state
flag_on
actions_on
rm -f "$GHWARN"
seed_done_job
MC_DETACHED_REBASE=1 PR_ATTEMPT_WARM="$H1" PR_ATTEMPT_WARM_KIND="rebasedone rebase" run_tick
[ "$(applied)" -eq 0 ] && ok || bad "1: a warm rebasedone row must stop the re-apply, got $(applied) 'rebased' line(s): $(grep rebased "$H/logs/merge-conductor.log")"
has_git_push && bad "1: git push was attempted despite warm rows: $(cat "$GITLOG")" || ok
attempt_line "rebasedone" "$KEY" "$H1" && ok || bad "1: attempts.txt did not warm rebasedone $KEY $H1: $(cat "$ATT")"
grep -q "^GET http://jobs.test/api/pr-attempts?.*kind=rebasedone&sha=$H1" "$REQ" && ok \
  || bad "1: no GET /api/pr-attempts for kind=rebasedone: $(grep pr-attempts "$REQ")"
[ ! -s "$GHWARN" ] && ok || bad "1: a write verb ran while the work was skipped: $(cat "$GHWARN")"

echo "== 2. (b) flag off: no row requests, the result is applied once =="
reset_state
flag_off
actions_on
seed_done_job
MC_DETACHED_REBASE=1 PR_ATTEMPT_WARM="$H1" PR_ATTEMPT_WARM_KIND="rebasedone rebase" run_tick
[ "$(grep -c '/api/pr-attempts' "$REQ")" -eq 0 ] && ok || bad "2: dark mode made /api/pr-attempts requests: $(grep pr-attempts "$REQ")"
[ "$(applied)" -eq 1 ] && ok || bad "2: dark mode must apply the finished rebase exactly once, got $(applied)"
attempt_line "rebasedone" "$KEY" "$H1" && ok || bad "2: attempts.txt did not record rebasedone $KEY $H1: $(cat "$ATT")"

echo "== 3. (c) flag on, curl exit 7: fail-open, the result is applied, one unreachable line =="
reset_state
flag_on
actions_on
seed_done_job
MC_DETACHED_REBASE=1 CURL_MODE=down JOBS_ALERT=1 run_tick
[ "$(applied)" -eq 1 ] && ok || bad "3: an outage must fail open and apply the result, got $(applied)"
attempt_line "rebasedone" "$KEY" "$H1" && ok || bad "3: attempts.txt did not record rebasedone after the outage: $(cat "$ATT")"
# ONE outage line for the day, and the pr-attempts read paid ONCE: the first
# rc 1 latches the twin off for the rest of the process.
nalert=$(grep -c 'harness-jobs unreachable' "$H/logs/ALERTS.log" 2>/dev/null || true)
[ "${nalert:-0}" -eq 1 ] && ok || bad "3: expected exactly one 'harness-jobs unreachable' line, got ${nalert:-0}: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(njobs 'GET /api/pr-attempts.*transport rc=7')" -eq 1 ] && ok || bad "3: expected the pr-attempts outage paid once, got $(njobs 'GET /api/pr-attempts.*transport rc=7'): $(grep pr-attempts "$H/logs/jobs-client.log" 2>/dev/null)"

echo "== 4. (d) a row at a DIFFERENT head does not dedupe =="
reset_state
flag_on
actions_on
seed_done_job
MC_DETACHED_REBASE=1 PR_ATTEMPT_WARM="$H2" PR_ATTEMPT_WARM_KIND="rebasedone rebase" run_tick
[ "$(applied)" -eq 1 ] && ok || bad "4: a row for another head must not dedupe this one, got $(applied)"
attempt_line "rebasedone" "$KEY" "$H1" && ok || bad "4: attempts.txt should record rebasedone for $H1: $(cat "$ATT")"
grep -q "^GET http://jobs.test/api/pr-attempts?.*kind=rebasedone&sha=$H1" "$REQ" && ok \
  || bad "4: the miss was never asked of the row twin: $(grep pr-attempts "$REQ")"

echo "== 5. (e) a 500 on the PUT still leaves the file line =="
reset_state
flag_on
actions_on
seed_done_job
MC_DETACHED_REBASE=1 PUT_MODE=fail run_tick
attempt_line "rebasedone" "$KEY" "$H1" && ok || bad "5: a 500 PUT must not lose the rebasedone file line: $(cat "$ATT")"
grep -q '^PUT http://jobs.test/api/pr-attempts .*"kind":"rebasedone"' "$REQ" && ok || bad "5: expected a PUT /api/pr-attempts for rebasedone: $(grep pr-attempts "$REQ")"

echo "== 6. events: one transition + one budget alert -> two state events, file first =="
reset_state
flag_on
actions_on
tighten_on
run_tick
ne="$(n_events)"
[ "$ne" -eq 2 ] && ok || bad "6: expected exactly 2 POST /api/pr-state-events, got $ne: $(cat "$REQ")"
e1=$(event_body 1); e2=$(event_body 2)
jq -e --arg u "$URL" --arg h "$H1" '.repo=="example-org/a" and .number==7 and (.state|length>0)
  and (.since|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and .head==$h and .url==$u' <<<"$e1" >/dev/null 2>&1 \
  && ok || bad "6: the transition event lacks repo/number/state/ISO since/head/url: $e1"
[ "$(jq -r .alerted <<<"$e1" 2>/dev/null)" = "-" ] && ok || bad "6: first event (transition) should have alerted='-': $e1"
a2=$(jq -r .alerted <<<"$e2" 2>/dev/null)
[ -n "$a2" ] && [ "$a2" != "-" ] && [ "$a2" != null ] && ok || bad "6: second event (budget alert) should carry the alert mark: $e2"
[ "$(jq -r '.state+" "+.since' <<<"$e1" 2>/dev/null)" = "$(jq -r '.state+" "+.since' <<<"$e2" 2>/dev/null)" ] && ok \
  || bad "6: the alert event must repeat the transition's state and since: $e1 / $e2"
# ORDER: the ledgers PUT for a transition precedes its event POST.
awk '/^PUT http:\/\/jobs.test\/api\/ledger /{l=NR} /^POST http:\/\/jobs.test\/api\/pr-state-events /{if(!l){bad=1}; exit} END{exit bad}' "$REQ" \
  && ok || bad "6: an event POST went out before the ledgers PUT: $(grep -n 'api/ledger \|pr-state-events' "$REQ")"
# The alert mark in the event is the one the FILE holds.
[ "$(awk -F'\t' -v k="$KEY" '$1==k{print $6}' "$ROW")" = "$a2" ] && ok || bad "6: the event's alerted '$a2' is not the file's: $(cat "$ROW")"

# Flag off: zero state events, the same file.
reset_state
flag_off
actions_on
tighten_on
run_tick
[ "$(n_events)" -eq 0 ] && ok || bad "6b: flag off must produce zero state events, got $(n_events): $(cat "$REQ")"

# The event POST dies (curl exit 7 on that path only): the file row and the
# ledgers PUT are exactly where a healthy run leaves them.
reset_state
flag_on
actions_on
tighten_on
EVENTS_MODE=down run_tick
grep -q "^example-org/a#7	BLOCKED_HUMAN	" "$ROW" && ok || bad "6c: a dead event POST must leave the pr-state.tsv row: $(cat "$ROW")"
[ "$(grep -c '^PUT http://jobs.test/api/ledger .*example-org/a#7' "$REQ")" -eq 2 ] && ok || bad "6c: a dead event POST must leave both ledgers PUTs: $(grep 'api/ledger ' "$REQ")"
[ "$(n_events)" -ge 1 ] && ok || bad "6c: the event POST was never attempted: $(cat "$REQ")"
tighten_off

echo "== 6d. events: flush — the held-page flush's alert mark appends one state event =="
# BH-1382's flush (mc_hold_flush_one, BUDGET arm) spends a row's alert mark with
# its own mc_row_put and no ledgers row. Under the flag it appends exactly one
# pr_state_events row, whose alerted is the mark the file now holds; flag off it
# sends none and leaves the same pr-state.tsv. a#8 is not in the open list, so
# the flush is the only writer of its row this tick (actions mode: the flush runs
# in actions|merge).
U8="https://github.com/$SLUG/pull/8"
jq -nc --arg h "$H2" '{rows:[{repo:"example-org/a",number:8,state:"READY",head:$h,kind:"BUDGET",
  text:"20m in READY: held a#8",mark:"READY@900",mode:"kill-switch",
  first_held_at:"2026-09-23T00:00:00Z",last_seen_at:"2026-09-23T00:00:00Z"}],n_total:1}' > "$T/held8.json"
ev8() { grep '^POST http://jobs.test/api/pr-state-events ' "$REQ" 2>/dev/null | sed 's/^[^ ]* [^ ]* //' | jq -c 'select(.number == 8)' 2>/dev/null; }
normrow() { awk -F'\t' 'BEGIN{OFS="\t"} {$3="<since>"; print}' "$ROW"; }
reset_state
flag_on
actions_on
tighten_off
row "$SLUG#8" READY 900 "$H2" "-" "-" clean "$U8"
HELD_JSON="$T/held8.json" run_tick
[ "$(nlog 'example-org/a#8 BUDGET flushed')" -eq 1 ] && ok || bad "6d: the flush did not page a#8 (fixture drift): $(cat "$H/logs/merge-conductor.log")"
[ "$(ev8 | grep -c .)" -eq 1 ] && ok || bad "6d: expected exactly 1 state event for a#8, got $(ev8 | grep -c .): $(grep pr-state-events "$REQ")"
f6=$(awk -F'\t' -v k="$SLUG#8" '$1==k{print $6}' "$ROW")
[ "$f6" = "READY@900" ] && ok || bad "6d: the flush did not record the mark in the file: $(cat "$ROW")"
[ "$(ev8 | jq -r .alerted)" = "$f6" ] && ok || bad "6d: the event's alerted '$(ev8 | jq -r .alerted)' is not the file's '$f6'"
ev8 | jq -e --arg h "$H2" --arg u "$U8" '.repo=="example-org/a" and .state=="READY" and .head==$h and .url==$u
  and (.since|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' >/dev/null 2>&1 \
  && ok || bad "6d: the flush event lacks repo/state/head/url/ISO since: $(ev8)"
grep -q '^PUT http://jobs.test/api/ledger .*example-org/a#8' "$REQ" && bad "6d: the flush wrote a ledgers row it never wrote before: $(grep 'api/ledger ' "$REQ")" || ok
normrow > "$T/flush-on.tsv"
reset_state
flag_off
actions_on
row "$SLUG#8" READY 900 "$H2" "-" "-" clean "$U8"
HELD_JSON="$T/held8.json" run_tick
[ "$(nlog 'example-org/a#8 BUDGET flushed')" -eq 1 ] && ok || bad "6d: flag off, the flush did not page a#8: $(cat "$H/logs/merge-conductor.log")"
[ "$(n_events)" -eq 0 ] && ok || bad "6d: flag off must send zero state events, got $(n_events)"
normrow > "$T/flush-off.tsv"
cmp -s "$T/flush-on.tsv" "$T/flush-off.tsv" && ok || bad "6d: the flag changed pr-state.tsv: $(diff "$T/flush-on.tsv" "$T/flush-off.tsv")"
actions_off

echo "== 7. Rehydrate from pr_state view preserves alerted; fallback to ledger works =="

# 7a: view fixture with two rows, one alerted (PR 8 is not in the gh list, so it
# survives any project-loop overwrite).
reset_state
flag_on
: > "$ROW"
PR_STATE_ROWS='{"rows":[{"repo":"example-org/a","number":7,"state":"WAIT_CI","since":"2026-09-22T10:00:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewed":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"fixture","url":"https://github.com/example-org/a/pull/7","alerted":"-"},{"repo":"example-org/a","number":8,"state":"BLOCKED_HUMAN","since":"2026-09-22T09:00:00Z","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewed":"-","reason":"conflict-unresolvable: x","url":"https://github.com/example-org/a/pull/8","alerted":"BLOCKED_HUMAN@1727005200@20260922"}]}'
actions_off
run_tick
grep -q 'example-org/a#8' "$ROW" && ok || bad "7a: pr-state.tsv missing #8 after view rehydrate: $(cat "$ROW")"
grep -q 'BLOCKED_HUMAN@1727005200@20260922' "$ROW" && ok || bad "7a: alerted column not preserved from view: $(cat "$ROW")"
# Eight columns, alerted SIXTH, since an EPOCH. The view carries ISO and
# mc_budget_check does `$(mc_now) - since`, so an ISO string in column 3 ages
# every row to nonsense and no budget alert ever fires again.
v7nf=$(awk -F'\t' '$1=="example-org/a#8" {print NF; exit}' "$ROW")
[ "${v7nf:-0}" -eq 8 ] && ok || bad "7a: #8 row is not 8 columns, got ${v7nf:-0}: $(cat "$ROW")"
v7al=$(awk -F'\t' '$1=="example-org/a#8" {print $6; exit}' "$ROW")
[ "$v7al" = 'BLOCKED_HUMAN@1727005200@20260922' ] && ok || bad "7a: alerted is not column 6, got '$v7al': $(cat "$ROW")"
v7si=$(awk -F'\t' '$1=="example-org/a#8" {print $3; exit}' "$ROW")
case "$v7si" in ''|*[!0-9]*) bad "7a: since must be an epoch, got '$v7si': $(cat "$ROW")" ;; *) ok ;; esac
# TEST-CHANGE (BH-2357): scoped to the pr_state ledger, which is the rehydrate
# fallback this case is about. Since BH-2357 every tick with the flag up also
# reads the land watermark (`/api/ledger?kind=mc_land`), which is not a
# rehydrate.
[ "$(grep -c '^GET http://jobs.test/api/ledger?kind=pr_state' "$REQ")" -eq 0 ] && ok || bad "7a: view rehydrate should not have hit the pr_state ledger: $(cat "$REQ")"

# 7b: view 404/empty + ledger fixture -> rows from ledger (PR 9 is not in gh list).
reset_state
flag_on
: > "$ROW"
PR_STATE_ROWS=""
CURL_STATUS=404
LEDGER_ROWS="$T/ledger-rows.json"
cat > "$LEDGER_ROWS" <<'LEDGER'
[{"key":"example-org/a#7","status":"WAIT_CI","detail":"{\"since\":\"2026-09-22T10:00:00Z\",\"head_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reviewed_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"verdict\":\"-\",\"merge_state\":\"-\",\"reason\":\"fixture\",\"record\":\"-\",\"url\":\"https://github.com/example-org/a/pull/7\",\"alerted\":\"-\"}"},
{"key":"example-org/a#9","status":"READY","detail":"{\"since\":\"2026-09-22T11:00:00Z\",\"head_sha\":\"cccccccccccccccccccccccccccccccccccccccc\",\"reviewed_sha\":\"cccccccccccccccccccccccccccccccccccccccc\",\"verdict\":\"APPROVE\",\"merge_state\":\"CLEAN\",\"reason\":\"approved\",\"record\":\"-\",\"url\":\"https://github.com/example-org/a/pull/9\",\"alerted\":\"READY@1727008800@20260922\"}"}]
LEDGER
actions_off
run_tick
grep -q 'example-org/a#9' "$ROW" && ok || bad "7b: pr-state.tsv missing #9 after ledger fallback: $(cat "$ROW")"
grep -q 'READY@1727008800@20260922' "$ROW" && ok || bad "7b: alerted column not preserved from ledger: $(cat "$ROW")"
# TEST-CHANGE (BH-2357): scoped to kind=pr_state, or the land watermark's own
# `kind=mc_land` read would satisfy it with no fallback at all.
[ "$(grep -c '^GET http://jobs.test/api/ledger?kind=pr_state' "$REQ")" -ge 1 ] && ok || bad "7b: ledger fallback should have hit the pr_state ledger: $(cat "$REQ")"
unset CURL_STATUS LEDGER_ROWS
CURL_STATUS=""; LEDGER_ROWS=""

# 7b2: a view LONGER than MC_REHYDRATE_PAGES pages is not a view read at all.
# One full page (1000 rows, so more are outstanding) under a cap of 1: the view
# half must drop what it read and hand over to the ledger path — never a file
# holding the first page and calling itself the fleet (D12).
reset_state
flag_on
: > "$ROW"
jq -nc '{rows:[range(2000;1000;-1) | {id:., repo:"example-org/z", number:., state:"WAIT_CI",
  since:"2026-09-22T10:00:00Z", head:"dddd", reviewed:"-", reason:"page", url:"u", alerted:"-"}]}' > "$T/view-full.json"
[ "$(jq '.rows|length' "$T/view-full.json")" = 1000 ] || bad "7b2: fixture is not one full page"
LEDGER_ROWS="$T/ledger-rows.json"
actions_off
MC_REHYDRATE_PAGES=1 PR_STATE_FILE="$T/view-full.json" LEDGER_ROWS="$LEDGER_ROWS" run_tick
LEDGER_ROWS=""
grep -q 'example-org/z#' "$ROW" && bad "7b2: a capped view read was written to pr-state.tsv: $(grep -c 'example-org/z#' "$ROW") row(s)" || ok
grep -q 'example-org/a#9' "$ROW" && ok || bad "7b2: a capped view must fall back to the ledger rows: $(cat "$ROW")"
[ "$(grep -c '^GET http://jobs.test/api/pr-state?' "$REQ")" -ge 1 ] && ok || bad "7b2: the view was never asked: $(cat "$REQ")"
nlog 'falling back to ledgers' | grep -qx 1 && ok || bad "7b2: expected one 'falling back to ledgers' line: $(grep rehydrat "$H/logs/merge-conductor.log")"

# 7c: BYTE IDENTITY WITH THE FLAG ABSENT. The same view fixture, the same ledger
# fixture, the flag off — the file the tick leaves behind must be the one an
# unflagged box writes, or "dark" is a word rather than a property.
reset_state
flag_off
: > "$ROW"
actions_off
run_tick
# `since` is `now` on a fresh transition and the two runs are seconds apart, so
# it is the one column that legitimately differs; everything else — the key, the
# state, the heads, the alert mark, the reason, the url — must match byte for
# byte, and it is a row of `-` in column 3 that the view would have filled.
norm() { awk -F'\t' 'BEGIN{OFS="\t"} {$3="<since>"; print}' "$1"; }
norm "$ROW" > "$T/rows-dark-1.tsv"
reset_state
flag_off
: > "$ROW"
PR_STATE_ROWS='{"rows":[{"repo":"example-org/a","number":8,"state":"BLOCKED_HUMAN","since":"2026-09-22T09:00:00Z","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewed":"-","reason":"x","url":"https://github.com/example-org/a/pull/8","alerted":"BLOCKED_HUMAN@1727005200@20260922"}]}'
run_tick
PR_STATE_ROWS=""
norm "$ROW" > "$T/rows-dark-2.tsv"
cmp -s "$T/rows-dark-1.tsv" "$T/rows-dark-2.tsv" && ok || bad "7c: flag-off pr-state.tsv is not byte-identical with a view standing by: $(diff "$T/rows-dark-1.tsv" "$T/rows-dark-2.tsv")"
[ "$(grep -c '^GET http://jobs.test/api/pr-state?' "$REQ")" -eq 0 ] && ok || bad "7c: flag off must not read the pr_state view: $(cat "$REQ")"

# 7c2: ...and against MAIN'S OWN CODE. The same flag-off tick (a transition, an
# alert, a ledger rehydrate) run once over this tree and once over origin/main's
# bin/lib/mc + conductor must leave the same pr-state.tsv and attempts.txt, with
# only the wall-clock epochs normalised. When origin/main cannot be read (a
# shallow CI checkout) this says so and asserts nothing; the 7c pair above still
# holds either way.
normt() { sed -E 's/[0-9]{10}/<t>/g' "$1"; }
dark_run() { # $1 = tag
  reset_state; flag_off; actions_on; tighten_on
  LEDGER_ROWS="$T/ledger-rows.json" run_tick
  tighten_off; LEDGER_ROWS=""
  normt "$ROW" > "$T/rows-$1.tsv"; normt "$ATT" > "$T/att-$1.txt"
}
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1 \
   && git -C "$DIR" archive origin/main bin/merge-conductor.sh bin/lib/mc 2>/dev/null | tar -x -C "$T" 2>/dev/null \
   && [ -s "$T/bin/merge-conductor.sh" ]; then
  dark_run branch
  cp -a "$H/bin/merge-conductor.sh" "$T/mc-branch.sh"; cp -a "$H/bin/lib/mc" "$T/mc-branch"
  cp "$T/bin/merge-conductor.sh" "$H/bin/merge-conductor.sh"; cp "$T"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
  dark_run main
  cp "$T/mc-branch.sh" "$H/bin/merge-conductor.sh"; cp "$T"/mc-branch/*.sh "$H/bin/lib/mc/"
  cmp -s "$T/rows-branch.tsv" "$T/rows-main.tsv" && ok || bad "7c2: flag-off pr-state.tsv differs from origin/main's: $(diff "$T/rows-main.tsv" "$T/rows-branch.tsv")"
  cmp -s "$T/att-branch.txt" "$T/att-main.txt" && ok || bad "7c2: flag-off attempts.txt differs from origin/main's: $(diff "$T/att-main.txt" "$T/att-branch.txt")"
  [ -s "$T/rows-branch.tsv" ] && ok || bad "7c2: the flag-off run wrote no rows at all, so the cmp proved nothing"
else
  echo "NOTE: 7c2 skipped — origin/main is not readable from $DIR"
fi

# 7d: MC_REHYDRATE=0 still means never rebuild, with the flag ON. The kill
# switch is the operator's, and a new source for the rows does not get to
# ignore it.
reset_state
flag_on
: > "$ROW"
PR_STATE_ROWS='{"rows":[{"repo":"example-org/a","number":8,"state":"BLOCKED_HUMAN","since":"2026-09-22T09:00:00Z","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewed":"-","reason":"x","url":"https://github.com/example-org/a/pull/8","alerted":"-"}]}'
actions_off
MC_REHYDRATE=0 run_tick
# A `VAR=x func` assignment persists in the calling shell, so it is put back.
MC_REHYDRATE=1
PR_STATE_ROWS=""
grep -q 'example-org/a#8' "$ROW" && bad "7d: MC_REHYDRATE=0 must not rebuild from the view: $(cat "$ROW")" || ok
[ "$(grep -c '^GET http://jobs.test/api/pr-state?' "$REQ")" -eq 0 ] && ok || bad "7d: MC_REHYDRATE=0 must not read the view at all: $(cat "$REQ")"

echo "== 8. Negative keys: a line that is not PR-keyed makes NO /api/pr-attempts request =="
# Driven through the real helpers (bin/lib/mc/locks.sh's mc_attempt_has /
# mc_attempt_put), with the flag ON and the request sink watching: the gate is
# mc_attempt_pr_key, and a wrong key means a PR skipped for ever.
reset_state
flag_on
printf '%s\n' \
  'identityalert hub gh-app 20260922' \
  'dvread project-5 abc123' \
  'lanefail example-org/a#7' \
  ' rebase example-org/a#7 abc' \
  'mergetree example-org/a#notanumber abc' \
  'red example-org/a#7' > "$T/negatives.txt"
: > "$REQ"
(
  cd "$T" &&
  PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
  JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
  bash -c '
    . "$0/bin/lib/merge-conductor-lib.sh"
    mc_init
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      mc_attempt_has "$line" 2>/dev/null
      mc_attempt_put "$line" 2>/dev/null
    done < "$1"
  ' "$H" "$T/negatives.txt"
) >/dev/null 2>&1
[ "$(grep -c '/api/pr-attempts' "$REQ")" -eq 0 ] && ok || bad "8: a non-PR-keyed line reached /api/pr-attempts: $(grep '/api/pr-attempts' "$REQ")"
[ "$(grep -c . "$ATT")" -eq 6 ] && ok || bad "8: every negative line must still be written to the FILE, got $(grep -c . "$ATT"): $(cat "$ATT")"

# ...and the POSITIVE control on the same driver: a real PR-keyed line DOES
# become a row, so the assertion above is about the key and not about a driver
# that never reaches the client.
reset_state
flag_on
: > "$REQ"
(
  cd "$T" &&
  PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
  JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
  bash -c '
    . "$0/bin/lib/merge-conductor-lib.sh"
    mc_init
    mc_attempt_has "rebase example-org/a#7 abcdef" 2>/dev/null
    mc_attempt_put "rebase example-org/a#7 abcdef" 2>/dev/null
  ' "$H"
) >/dev/null 2>&1
[ "$(grep -c '^GET http://jobs.test/api/pr-attempts' "$REQ")" -eq 1 ] && ok || bad "8: the positive control made no GET /api/pr-attempts: $(cat "$REQ")"
[ "$(grep -c '^PUT http://jobs.test/api/pr-attempts' "$REQ")" -eq 1 ] && ok || bad "8: the positive control made no PUT /api/pr-attempts: $(cat "$REQ")"

echo "pr-attempts-idempotent.bh-1387-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
