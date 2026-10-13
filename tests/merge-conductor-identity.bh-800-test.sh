#!/bin/bash
# tests/merge-conductor-identity.bh-800-test.sh — BH-800, the conductor half.
#
# `mergeState=BLOCKED` with NO required status checks and NO required reviews is
# not "a required context is not green" — there is no required context. It is
# GitHub saying the token in hand may not push to that branch. The conductor
# used to write the false reason AND spend the BH-636 flake ladder on it: a
# second `actions/runs` read per row and, at rung 0, a CI re-run kick. That is
# the burned retry the ticket names — and the stuck detector would go on to
# close and reopen the PR, which cannot add a push permission either.
#
# Two halves, both driven:
#   1. mc_classify itself, sourced from the real lib (C1).
#   2. bin/merge-conductor.sh run WHOLE against a scratch $HARNESS with a fake
#      gh, the way tests/hotfix-conductor-degraded-test.sh runs it (C2-C7) —
#      the production entry point (D2). What is asserted is the log, the ALERT,
#      the attempts file, the row and the gh calls the stub recorded.
#
# Run from anywhere: tests/merge-conductor-identity.bh-800-test.sh (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/lib/gh-push-identity.sh" "$T/h/bin/lib/" 2>/dev/null || true
# BH-1586: the protection and CI reads are gh_rest now (and protection rides the
# policy cache, whose TTL resolves to 0 here: no lane-gate in this tree), so the
# fixture carries the REST library and the shared HTTP answer emitter.
cp "$DIR"/bin/lib/gh-rest*.sh "$DIR/bin/lib/gh-policy-cache.sh" "$T/h/bin/lib/"
mkdir -p "$T/fakebin" && cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"

# ===========================================================================
# 1. The classifier, pure (C1)
# ===========================================================================
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111
cls() { mc_classify OPEN "$1" MERGEABLE $H1 $H1 APPROVE claude "$2" 0 0 0 0 - -; }

# C1 — the conductor set the named variable, so the row says what is actually
# wrong and names the identity. The STATE word does not change: WAIT_CI's
# budget, its stuck detector and its age alert all still apply, and nothing is
# handed to bin/blocked-resolver.sh (whose ladder ends in a closed PR — 42 PRs
# closed for a config gap is the cure being worse than the disease).
OUT=$(MC_IDENTITY_BLOCKED=1 MC_IDENTITY_WORD=app/cromford cls BLOCKED green)
[ "$(cut -f1 <<<"$OUT")" = WAIT_CI ] \
  && ok || bad "C1: the state word must stay WAIT_CI (got $(cut -f1 <<<"$OUT"))"
case "$(cut -f2 <<<"$OUT")" in
  "IDENTITY_NOT_PERMITTED app/cromford:"*) ok ;;
  *) bad "C1: the reason must lead with IDENTITY_NOT_PERMITTED and the identity (got '$(cut -f2 <<<"$OUT")')" ;;
esac
grep -q "required context not green" <<<"$OUT" \
  && bad "C1: the false 'required context not green' claim must be REPLACED, not kept alongside" || ok
OUT=$(MC_IDENTITY_BLOCKED=1 cls BLOCKED green)
grep -q "IDENTITY_NOT_PERMITTED unknown:" <<<"$OUT" \
  && ok || bad "C1: with no identity word the reason says unknown, never a plausible login (got '$OUT')"
# ...and everything else is untouched.
[ "$(cls BLOCKED green | cut -f2)" = "mergeState BLOCKED (required context not green)" ] \
  && ok || bad "C1: without the named variable BLOCKED keeps today's reason (got '$(cls BLOCKED green | cut -f2)')"
[ "$(MC_IDENTITY_BLOCKED=0 cls BLOCKED green | cut -f2)" = "mergeState BLOCKED (required context not green)" ] \
  && ok || bad "C1: MC_IDENTITY_BLOCKED=0 is today's behaviour exactly"
[ "$(MC_IDENTITY_BLOCKED=1 MC_IDENTITY_WORD=app/cromford cls UNSTABLE green | cut -f2)" = "mergeState UNSTABLE (required context not green)" ] \
  && ok || bad "C1: UNSTABLE is not this bug — its reason is unchanged"
[ "$(MC_CI_FLAKE=1 cls BLOCKED green | cut -f2)" = "checks flake — a required context was cancelled/timed_out; re-run once" ] \
  && ok || bad "C1: the BH-636 flake reason still wins when there is no identity block"
case "$(MC_CI_FLAKE=1 MC_IDENTITY_BLOCKED=1 MC_IDENTITY_WORD=operator cls BLOCKED green | cut -f2)" in
  "IDENTITY_NOT_PERMITTED operator:"*) ok ;;
  *) bad "C1: an identity block outranks a flake — a rerun cannot add a push permission" ;;
esac

# ===========================================================================
# 2. The production entry point: the whole script (C2-C6)
# ===========================================================================
printf 'bh example-org/bh-os - - 2 box-b\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
for stub in deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$stub"; chmod +x "$T/h/bin/$stub"; done
PRHEAD=aaaaaaaa0080
for N in 80 81 82 83; do
  REC="$T/h/builds/pool-bh-BH-8$N-2026091800$N"; mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/bh-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$PRHEAD" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done

TICKET_PROT='{"required_status_checks":null,"required_pull_request_reviews":null,
  "required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},
  "restrictions":{"users":[{"login":"operator"},{"login":"hstevens"}],"apps":[]}}'
prot() { printf '%s\n' "$1" | jq -c . > "$T/protection.json"; }

list_json() { # list_json <mergeStateStatus> <mergeable> [<extra pr numbers>...]
  local ms="$1" mg="$2"; shift 2
  { printf '['
    local first=1 n
    for n in 80 "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"number":%s,"url":"https://github.com/example-org/bh-os/pull/%s","headRefOid":"%s","headRefName":"ticket/bh-8%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","isInMergeQueue":false,"labels":[],"baseRefName":"main"}' \
        "$n" "$n" "$PRHEAD" "$n" "$ms" "$mg"
    done
    printf ']\n'; } > "$T/list.json"
}

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api repos/example-org/bh-os/rulesets"*) echo "" ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  *"api repos/example-org/bh-os -q .id"*) echo 1 ;;
  # A healthy budget, answered the way GitHub answers it. Not decoration: with
  # an EMPTY answer bin/lib/gh-budget.sh caches a zero-byte file and the NEXT
  # tick dies inside gh_budget_low on an arithmetic expansion over it, which
  # would make every second-tick assertion below vacuous.
  "api rate_limit")
    printf '{"resources":{"core":{"remaining":4900,"limit":5000,"reset":%s},"graphql":{"remaining":4900,"limit":5000,"reset":%s}}}\n' 9999999999 9999999999 ;;
  "api user -q .login") cat "$T/userlogin" 2>/dev/null ;;
  *"/branches/"*"/protection"*)
    MODE=\$(cat "$T/protmode" 2>/dev/null || echo ok)
    # BH-1586: gh_rest reads protection, so each mode is a whole HTTP answer.
    case "\$MODE" in
      ok)  restpr --raw 200 "\$(cat "$T/protection.json")"; exit 0 ;;
      403) restpr --raw 403 '{"message":"Resource not accessible by integration"}'; exit 0 ;;
      404) restpr --raw 404 '{"message":"Branch not protected"}'; exit 0 ;;
    esac ;;
  # Both mc_ci_state and mc_ci_flake_runs read this endpoint (BH-1586: through
  # gh_rest, applying their own jq to the REST run list). \$T/ci holds the run
  # lines (status|conclusion); no run on this head died, so the flake read
  # finds nothing — the shape the incident actually had, and the reason the
  # second read is pure waste.
  *"actions/runs?head_sha="*)
    restpr --runs - < "$T/ci"
    exit 0 ;;
  *"run rerun"*) printf '%s\n' "\$*" >> "$T/rerun-calls.txt"; exit 0 ;;
  # The CI kick is mc_kick_ci's close/reopen pair, and it is a REST PATCH on the
  # pull, not \`gh pr close\` — matching the friendlier spelling would record
  # nothing and make C3's assertion vacuous.
  *"-X PATCH repos/example-org/bh-os/pulls/"*) printf '%s\n' "\$*" >> "$T/kick-calls.txt"; exit 0 ;;
  *"pr list -R example-org/bh-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"pr view"*"--json state,headRefOid"*) echo "OPEN $PRHEAD" ;;
  *"pr view"*"--json state"*) echo OPEN ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{\\"error\\":\\"not found\\"}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
ATT="$T/h/state/merge-conductor/attempts.txt"
TICKDIR="$T/h/state/merge-conductor/tick"
CLOG="$T/h/logs/merge-conductor.log"
KEY="example-org/bh-os#80"
row_field() { awk -F'\t' -v k="$KEY" '$1==k {print $'"$1"'}' "$ROWS" 2>/dev/null; }
reset_tick() { # reset_tick <mergeState> <mergeable> <ci-line> <protmode> [extra prs...]
  rm -rf "$T/h/state/merge-conductor"
  : > "$T/gh-calls.txt"; : > "$T/rerun-calls.txt"; : > "$T/kick-calls.txt"
  : > "$CLOG"; : > "$T/h/logs/ALERTS.log"
  echo somebody-else > "$T/userlogin"
  rm -f "$T/h/flags/"alerted-identity-not-permitted-*
  printf '%s\n' "$3" > "$T/ci"; printf '%s\n' "$4" > "$T/protmode"
  prot "$TICKET_PROT"
  local ms="$1" mg="$2"; shift 4; list_json "$ms" "$mg" "$@"
}
# HOW MANY PR WORKERS A TICK FORKS. 1 keeps the single-PR cases deterministic;
# PRODUCTION runs the default 0 = UNLIMITED (bin/lib/merge-conductor-lib.sh), and
# C4 — the case that asserts one protection read per repo per tick — drives that
# default, because the property is only worth anything on the path the hub runs.
MCPP=1
run_tick() { # run_tick [EXTRA=env ...]
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x GH_TOKEN=ghp_fake \
      MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PR_PARALLEL="$MCPP" \
      "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}

# ---------------------------------------------------------------------------
# C2 — the whole lane, on the ticket's shape: BLOCKED, green, nothing required,
#      on an identity that is not in the branch's push allow-list. The distinct
#      line, the row reason, and the retries that must NOT burn.
# ---------------------------------------------------------------------------
reset_tick BLOCKED MERGEABLE 'completed|success' ok
run_tick
grep -q "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$CLOG" \
  && ok || bad "C2: the lane must write the distinct line (log: $(tail -3 "$CLOG"))"
[ "$(row_field 2)" = WAIT_CI ] && ok || bad "C2: the row state stays WAIT_CI (got '$(row_field 2)')"
case "$(row_field 7)" in
  "IDENTITY_NOT_PERMITTED somebody-else:"*) ok ;;
  *) bad "C2: the row reason must name the identity (got '$(row_field 7)')" ;;
esac
# THE BURNED RETRY. The flake ladder's second actions/runs read and its rerun
# kick are what this ticket calls the burned retry: on an identity block there
# is no flake to re-run, and re-running CI cannot add a push permission.
[ "$(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt")" = 1 ] \
  && ok || bad "C2: the flake ladder must not buy a second Actions read (got $(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt"))"
[ ! -s "$T/rerun-calls.txt" ] && ok || bad "C2: no CI rerun may be kicked on an identity block ($(cat "$T/rerun-calls.txt"))"
grep -q "pr merge" "$T/gh-calls.txt" && bad "C2: no merge may be attempted on an identity block" || ok

# ---------------------------------------------------------------------------
# C4 — ONE protection read per (repo, base) per tick with FOUR PRs and the
#      PRODUCTION worker setting (MC_PR_PARALLEL unlimited), ONE page per (repo,
#      identity, UTC day) however many ticks run, and never a silent tick.
#
#      The parallelism is the point, not a detail. The workers are subshells that
#      all reach the identity block inside the same second: with the cache file
#      written unlocked, all four find no file and buy their own protection read
#      (the incident's shape is 42 PRs on one repo — ~84 extra REST calls every
#      five minutes on the PAT whose secondary rate limit started all this), and
#      a worker that reads the file mid-write gets nothing back, leaves
#      MC_IDENTITY_BLOCKED at 0 and spends the flake ladder and the rung-0 rerun
#      after all. Both are asserted below.
# ---------------------------------------------------------------------------
MCPP=0
reset_tick BLOCKED MERGEABLE 'completed|success' ok 81 82 83
run_tick
[ "$(grep -c "branches/main/protection" "$T/gh-calls.txt")" = 1 ] \
  && ok || bad "C4: four PRs of one repo in one tick must cost ONE protection read (got $(grep -c "branches/main/protection" "$T/gh-calls.txt"))"
[ "$(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt")" = 4 ] \
  && ok || bad "C4: no worker may slip past the identity block onto the flake ladder — 4 PRs, one CI read each (got $(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt"))"
[ ! -s "$T/rerun-calls.txt" ] \
  && ok || bad "C4: no CI rerun may be kicked on an identity block, at any parallelism ($(cat "$T/rerun-calls.txt"))"
[ "$(grep -c "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$CLOG")" = 4 ] \
  && ok || bad "C4: every one of the four PRs must say so in the log (got $(grep -c "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$CLOG"))"
ls "$TICKDIR"/*.idv-* >/dev/null 2>&1 \
  && ok || bad "C4: the per-tick verdict cache file must exist ($(ls "$TICKDIR" 2>/dev/null | tr '\n' ' '))"
[ "$(grep -c "^identityalert example-org/bh-os somebody-else " "$ATT")" = 1 ] \
  && ok || bad "C4: one identityalert marker (got $(grep -c identityalert "$ATT"))"
[ "$(grep -c "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "C4: exactly one ALERT (got $(grep -c IDENTITY_NOT_PERMITTED "$T/h/logs/ALERTS.log"))"
run_tick
[ "$(grep -c "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$CLOG")" = 8 ] \
  && ok || bad "C4: every tick must still say so in the log for every PR (want 8, got $(grep -c IDENTITY_NOT_PERMITTED "$CLOG"))"
[ "$(grep -c "^identityalert example-org/bh-os somebody-else " "$ATT")" = 1 ] \
  && ok || bad "C4: the second tick must not page again the same day"
[ "$(grep -c "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "C4: still exactly one ALERT after two ticks"
grep -rq ghp_fake "$T/h/logs/" && bad "C4: a token VALUE reached a log" || ok
MCPP=1

# ---------------------------------------------------------------------------
# C3 — the stuck detector. A WAIT_CI row past its TTL is otherwise CLOSED AND
#      REOPENED to fire a workflow; a close/reopen cannot add a push permission,
#      so an identity block stops there and the ALERT is the action. Driven with
#      the actions flag ON, so "no pr close" is a real assertion and not the
#      observe mode answering for it.
# ---------------------------------------------------------------------------
touch "$T/h/flags/merge-conductor-actions"
reset_tick BLOCKED MERGEABLE '' ok
run_tick MC_CI_KICK_MIN_AGE=99999999 MC_TTL_WAIT_CI=60
[ "$(row_field 2)" = WAIT_CI ] && ok || bad "C3: setup — the row must be WAIT_CI before it can be stuck (got '$(row_field 2)')"
AGED=$(( $(date +%s) - 9999 ))
awk -F'\t' -v OFS='\t' -v a="$AGED" '{ $3=a; print }' "$ROWS" > "$ROWS.aged" && mv "$ROWS.aged" "$ROWS"
: > "$T/kick-calls.txt"; : > "$CLOG"
run_tick MC_CI_KICK_MIN_AGE=99999999 MC_TTL_WAIT_CI=60
grep -q "a close/reopen cannot add a push permission" "$CLOG" \
  && ok || bad "C3: the stuck re-kick must refuse an identity block and say why (log: $(grep -i stuck "$CLOG" | head -2))"
[ ! -s "$T/kick-calls.txt" ] \
  && ok || bad "C3: a stuck identity block must never be closed and reopened ($(cat "$T/kick-calls.txt"))"

# ---------------------------------------------------------------------------
# C7 — the OTHER close/reopen. A head GitHub has never run a workflow on gets one
#      kick from its own block, and `checks none` wins over the BLOCKED arm in
#      mc_classify, so an identity-blocked head with no run lands there and used
#      to be closed and reopened right after it paged. Same answer as C3: a
#      close/reopen cannot add a push permission. Driven with the actions flag
#      ON and the age window open, which is exactly what C3 pins shut.
# ---------------------------------------------------------------------------
reset_tick BLOCKED MERGEABLE '' ok
run_tick MC_CI_KICK_MIN_AGE=99999999 MC_TTL_WAIT_CI=99999999
AGED=$(( $(date +%s) - 9999 ))
awk -F'\t' -v OFS='\t' -v a="$AGED" '{ $3=a; print }' "$ROWS" > "$ROWS.aged" && mv "$ROWS.aged" "$ROWS"
: > "$T/kick-calls.txt"; : > "$CLOG"
run_tick MC_CI_KICK_MIN_AGE=1 MC_TTL_WAIT_CI=99999999
grep -q "IDENTITY_NOT_PERMITTED example-org/bh-os somebody-else" "$CLOG" \
  && ok || bad "C7: setup — a run-less head must still reach the identity block (log: $(tail -3 "$CLOG"))"
[ ! -s "$T/kick-calls.txt" ] \
  && ok || bad "C7: a run-less identity block must not be closed and reopened either ($(cat "$T/kick-calls.txt"))"
grep -qxF "cikick $KEY $PRHEAD" "$ATT" \
  && bad "C7: no cikick may be recorded for a kick that must not happen" || ok
# The control that makes the two lines above probative: the SAME row, the same
# age, the same actions flag — only the branch is genuinely protected now, and
# the kick fires exactly as it does today.
prot '{"required_status_checks":{"contexts":["Typecheck"]},"required_pull_request_reviews":null,"restrictions":null}'
: > "$T/kick-calls.txt"
run_tick MC_CI_KICK_MIN_AGE=1 MC_TTL_WAIT_CI=99999999
[ -s "$T/kick-calls.txt" ] \
  && ok || bad "C7: control — a run-less head on a protected branch must still get its one CI kick"
rm -f "$T/h/flags/merge-conductor-actions"

# ---------------------------------------------------------------------------
# C5 — the negatives that prove this is about the allow-list and not about the
#      word BLOCKED: a real required check keeps today's reason AND today's
#      ladder; a RED head is the red ladder's and never buys a protection read.
# ---------------------------------------------------------------------------
reset_tick BLOCKED MERGEABLE 'completed|success' ok
prot '{"required_status_checks":{"contexts":["Typecheck"]},"required_pull_request_reviews":null,"restrictions":null}'
run_tick
grep -q IDENTITY_NOT_PERMITTED "$CLOG" "$T/h/logs/ALERTS.log" \
  && bad "C5: a real required check must never be the identity error" || ok
[ "$(row_field 7)" = "mergeState BLOCKED (required context not green)" ] \
  && ok || bad "C5: a genuinely protected branch keeps today's reason (got '$(row_field 7)')"
[ "$(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt")" = 2 ] \
  && ok || bad "C5: the flake ladder must still run on a genuinely protected branch (got $(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt") reads)"

reset_tick BLOCKED MERGEABLE 'completed|failure' ok
run_tick
[ "$(grep -c "branches/main/protection" "$T/gh-calls.txt")" = 0 ] \
  && ok || bad "C5: a red head must not buy a protection read"
grep -q IDENTITY_NOT_PERMITTED "$CLOG" && bad "C5: a red head is not an identity block" || ok
case "$(row_field 7)" in
  "checks red"*) ok ;;
  *) bad "C5: a red head keeps the red ladder's reason (got '$(row_field 7)')" ;;
esac

reset_tick DIRTY CONFLICTING 'completed|success' ok
run_tick
[ "$(row_field 2)" = NEEDS_REBASE ] && ok || bad "C5: DIRTY must still be NEEDS_REBASE (got '$(row_field 2)')"
[ "$(grep -c "branches/main/protection" "$T/gh-calls.txt")" = 0 ] \
  && ok || bad "C5: a conflicted head must not buy a protection read"

# ---------------------------------------------------------------------------
# C6 — fail-open. Everything the read cannot settle leaves the lane exactly as
#      it is today: today's reason, today's ladder, and no page. A feature that
#      can only ADD a line and an alert can never silently swallow a row.
# ---------------------------------------------------------------------------
for CASE in "403:a protection we cannot read" "nolist:a branch with no push allow-list at all" "unknown:an identity we cannot name"; do
  reset_tick BLOCKED MERGEABLE 'completed|success' ok
  case "${CASE%%:*}" in
    403)     echo 403 > "$T/protmode"; run_tick ;;
    nolist)  prot '{"required_status_checks":null,"required_pull_request_reviews":null,"restrictions":null}'; run_tick ;;
    unknown) : > "$T/userlogin"; run_tick GH_TOKEN= ;;
  esac
  grep -q IDENTITY_NOT_PERMITTED "$CLOG" "$T/h/logs/ALERTS.log" \
    && bad "C6: ${CASE#*:} must never page as an identity error" || ok
  [ "$(row_field 7)" = "mergeState BLOCKED (required context not green)" ] \
    && ok || bad "C6: ${CASE#*:} keeps today's reason (got '$(row_field 7)')"
  [ "$(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt")" = 2 ] \
    && ok || bad "C6: ${CASE#*:} leaves the flake ladder running exactly as today (got $(grep -c "actions/runs?head_sha=" "$T/gh-calls.txt") reads)"
done

echo "merge-conductor-identity.bh-800: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
