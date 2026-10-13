#!/bin/bash
# tests/mc/foreign-red-followups.bh-3857-test.sh — BH-3857: the follow-ups to
# BH-3776's foreign-red attribution (bin/lib/mc-foreign-red.sh, bin/lib/flaky.sh).
#
#   CK  the harness repo's test-impact select runs against a real checkout on
#       main (MC_TI_ROOT, then harness-sync's <harness>/../harness-checkout);
#       with none, BH-636 exactly (nomap), logged once a head.
#   LB  a later green batch counts for a failing suite only when that batch's
#       CI-plan job log proves it ran the suite (no quarantine drop, no skipped
#       guard, not nightly-tier, mode=full). A read that fails is not a run.
#   RC  a cached own/foreign costs no attribution read on the next tick, nor
#       does an `unreadable` inside MC_FR_UNREADABLE_TTL_MINS.
#   SP  the strict parse takes the harness marker only in the runner's exact
#       shape, and a `FAIL <file>` token only when it is a test file.
#   AN  ANSI colour codes are stripped before the strict parse.
#
# Driven against the real bin/merge-conductor.sh and a fake gh that records
# every call. The plan-log fixtures are produced by the real bin/ci-plan.sh and
# bin/test-tiers.sh (D4), never hand-typed.
# Run from anywhere: tests/mc/foreign-red-followups.bh-3857-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
TODAY=$(date -u -d "@$NOW" +%Y-%m-%d)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
for f in merge-conductor-lib gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list flaky gh-ci-read mc-stale-dequeue; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/"
done
# The lib under test. Absent on main, which is exactly the red this suite opens on.
[ -r "$DIR/bin/lib/mc-foreign-red.sh" ] && cp "$DIR/bin/lib/mc-foreign-red.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=x\n' > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh

H1=aaaaaaaa11112222333344445555666677778888
HOLD=bbbbbbbb11112222333344445555666677778888
BATCH=cccccccc11112222333344445555666677778888
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# ---- fixture switches -------------------------------------------------------
# ckmode   stale | acked | stale_red | stale_big | none
#          stale     Mergify's queue rule failure + "Dequeued — checks failed"
#                    neutral, and one green github-actions run
#          acked     Mergify's queue check in progress (an acknowledgement)
# noflip   non-empty => the @mergifyio requeue post does NOT move the check
# vstatus  the lead-verdict commit status state
# cmfail   non-empty => issues/31/comments answers 502
# logmode  suite | none   (what `gh run view --log-failed` yields)
# files    the PR's changed files, one per line
# later    the actions/runs?event=pull_request answer (JSON)
# flakes   the GET /api/metrics/flakes answer (JSON)
# run2     the second failing run 5004 (named only when the comment lists it):
#          ok | nolog | nopath | nobase | nohead | notmq
dq_comment() { # dq_comment <left-at sha> [draft yes|no] [extra run id] [comment id] [updated_at]
  #   -> one mergify[bot] dequeue comment (JSON object)
  local body draft="" extra=""
  [ "${2:-yes}" = yes ] && draft=' · on draft #3767'
  [ -n "${3:-}" ] && extra=$(printf '\n- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/mgfy-os/actions/runs/%s/job/90002) ([job log](https://github.com/example-org/mgfy-os/actions/runs/%s/job/90002))' "$3" "$3")
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "dequeued", "queue_rule_name": "default"}\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-30 09:40 UTC` · Rule: `default`\n- ❌ **Checks failed**%s\n- 🚫 **Left the queue** — `2026-09-30 10:12 UTC` · at `%s`\n\n## Reason\n\nThe merge conditions cannot be satisfied due to failing checks\n\n- `Pure-logic gate fixtures`\n\nFailing checks:\n- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/mgfy-os/actions/runs/5003/job/90001) ([job log](https://github.com/example-org/mgfy-os/actions/runs/5003/job/90001))%s\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n' "$draft" "$1" "$extra")
  jq -nc --arg b "$body" --argjson id "${4:-7001}" --arg u "${5:-2026-09-30T10:12:00Z}" '{id: $id, user: {login: "mergify[bot]", type: "Bot"}, body: $b,
    created_at: "2026-09-30T09:40:00Z", updated_at: $u}'
}
older_comment() { # a mergify comment created EARLIER but edited LATER, naming another state
  jq -nc '{id: 6001, user: {login: "mergify[bot]", type: "Bot"},
    body: "-*- Mergify Payload -*-\n{\"version\": 1, \"state\": \"merged\"}\n-*- Mergify Payload End -*-\nold",
    created_at: "2026-09-29T09:00:00Z", updated_at: "2026-09-30T11:00:00Z"}'
}
later_run() { # later_run <id> <draft#> <path> <base7> <created_at> [conclusion]
  jq -nc --argjson id "$1" --argjson d "$2" --arg p "$3" --arg b "$4" --arg c "$5" --arg co "${6:-success}" \
    '{id: $id, head_branch: ("mergify/merge-queue/" + ($id|tostring)), path: $p, status: "completed",
      conclusion: $co, created_at: $c, head_sha: "dddd0000", event: "pull_request",
      display_title: ("merge queue: checking #3749 on main (" + $b + ")"),
      pull_requests: [{number: $d}]}'
}

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nH1=%s\nBATCH=%s\n' "$T" "$MGFY_YML" "$H1" "$BATCH"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
# jobs_json <failed job name>... — a run's jobs answer, every named job failed;
# gh's own -q is honoured, as the real gh does.
jobs_json() {
  local q="" prev=""
  for a in "${ARGS[@]}"; do [ "$prev" = -q ] && q="$a"; prev="$a"; done
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | {name: ., status: "completed", conclusion: "failure"})
    | {total_count: length, jobs: .} | if $tc != "" then .total_count = ($tc | tonumber) else . end' --arg tc "$(cat "$T/jobstotal" 2>/dev/null)" | if [ -n "$q" ]; then jq -r "$q"; else cat; fi
}
ARGS=("$@")
CK=$(cat "$T/ckmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
GHA_RED='{"name":"Pure-logic gate fixtures","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CK" in
      stale)     restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      stale_red) restpr --raw 200 "{\"total_count\":4,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK,$GHA_RED]}" ;;
      stale_big) restpr --raw 200 "{\"total_count\":150,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked)     restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
      *)         restpr --raw 200 '{"total_count":0,"check_runs":[]}' ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 "{\"state\":\"$(cat "$T/vstatus")\",\"statuses\":[{\"context\":\"lead-verdict\",\"state\":\"$(cat "$T/vstatus")\"}]}" ;;
  *"api -i -X GET repos/"*"/issues/31/comments"*)
    [ -s "$T/cmfail" ] && { restpr --raw 502 '{"message":"Server Error"}'; exit 0; }
    restpr --raw 200 "$(cat "$T/comments.json")" ;;
  *"api -i -X GET repos/"*"/actions/runs/5003"*)
    restpr --raw 200 "{\"id\":5003,\"head_branch\":\"mergify/merge-queue/abc123\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-30T10:00:00Z\",\"head_sha\":\"$BATCH\",\"display_title\":\"merge queue: checking #31 on main (474d69b)\",\"pull_requests\":[{\"number\":3767}]}" ;;
  *"api -i -X GET repos/"*"/actions/runs/5004"*)
    R2=$(cat "$T/run2" 2>/dev/null || echo ok)
    P='.github/workflows/harness-ci.yml'; BR='mergify/merge-queue/abc124'; HS="$BATCH"; TI='merge queue: checking #31 on main (474d69b)'
    case "$R2" in nopath) P="" ;; nobase) TI='merge queue: checking #31' ;; nohead) HS="" ;; notmq) BR='ticket/other' ;; esac
    restpr --raw 200 "{\"id\":5004,\"head_branch\":\"$BR\",\"path\":\"$P\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-30T10:00:00Z\",\"head_sha\":\"$HS\",\"display_title\":\"$TI\",\"pull_requests\":[]}" ;;
  *"run view 5004"*"--log-failed"*)
    case "$(cat "$T/run2" 2>/dev/null || echo ok)" in
      nolog) ;;
      jobonly) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z ##[error]Process completed with exit code 1.\n' ;;
      *) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/other-suite-test.sh rc=1 3s\n' ;;
    esac ;;
  *"api repos/"*"/actions/runs/5004/jobs"*)
    [ "$(cat "$T/run2" 2>/dev/null || echo ok)" = nolog ] || jobs_json 'Pure-logic gate fixtures' ;;
  # BH-3857: a later batch's jobs (the CI-plan job is 77<run id>) and that
  # job's raw log ($T/planlog-<job id>, else $T/planlog).
  *"api -i -X GET repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    [ -s "$T/planjobsfail" ] && { restpr --raw 502 '{"message":"Server Error"}'; exit 0; }
    restpr --raw 200 "{\"total_count\":2,\"jobs\":[{\"id\":77$RID,\"name\":\"CI plan (what this run tests)\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"id\":88$RID,\"name\":\"Tests, traced (shard 1/2)\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *"api repos/"*"/actions/jobs/"*"/logs"*)
    JID=$(sed -n 's|.*/actions/jobs/\([0-9]*\)/logs.*|\1|p' <<<"$*")
    [ -s "$T/planlogfail" ] && { echo "HTTP 410: gone" >&2; exit 1; }
    if [ -e "$T/planlog-$JID" ]; then cat "$T/planlog-$JID"; else cat "$T/planlog"; fi ;;
  *"api -i -X GET repos/"*"/actions/runs"*"event=pull_request"*)
    restpr --raw 200 "$(cat "$T/later")" ;;
  # logmode: suite (one harness suite line) | none (the log reads, but names no
  # test: the jobs API stands in) | fail (`gh run view` itself fails) | many (21
  # suites, the 21st last) | title (a vitest-style title that is not a path).
  *"run view 5003"*"--log-failed"*)
    case "$(cat "$T/logmode")" in
      suite) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n' ;;
      none)  printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z ##[error]Process completed with exit code 1.\n' ;;
      fail)  echo "failed to get run log: HTTP 410" >&2; exit 1 ;;
      ee1)   cat "$T/ee1.log" ;;
      many)  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
               printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/s%s-test.sh rc=1 3s\n' "$i"; done
             printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n' ;;
      title) printf 'Pure-logic gate fixtures\tvitest\t2026-09-30T10:05:00Z × Makefile 12ms\n' ;;
      # mixed: one shard names an untouched suite, the SPA job (a build this PR
      # broke) names nothing (BH-3776 round 3, N2).
      mixed) printf 'Tests, traced (shard 2 of 8)\tsuite\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n'
             printf 'Mission Control SPA — unit tests + build\tconsole-ui builds clean\t2026-09-30T10:06:00Z src/App.tsx(12,3): error TS2304: Cannot find name foo.\n'
             printf 'Mission Control SPA — unit tests + build\tconsole-ui builds clean\t2026-09-30T10:06:01Z ##[error]Process completed with exit code 2.\n' ;;
      # Runner titles and file lines as gh --log-failed really prints them:
      # "<job>\t<step>\t<timestamp> <runner line>" (#3798 round 4, F1/F3).
      advvitest) printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > GET /api/x > returns 200\n'
             printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:00Z    × GET /api/x > returns 200 12ms\n'
             printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advjest) printf 'test\tnpm test\t2026-09-30T10:05:00Z FAIL src/foo.test.ts\n'
             printf 'test\tnpm test\t2026-09-30T10:05:00Z   ● foo › works\n' ;;
      jestfile) printf 'test\tnpm test\t2026-09-30T10:05:00Z FAIL src/foo.test.ts\n' ;;
      # advone/advslash: vitest titles with no shape tell — one word, or a
      # slash — behind the file they ran in (#3798 round 5).
      advone) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > works\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z    × works 12ms\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advslash) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > api/health\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advbare) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z    × works 12ms\n' ;;
      # fanin*: the real harness-ci shape. A shard names the suite; the fan-in
      # check `Pure-logic gate fixtures` names none, only what bin/ci-verdicts.sh
      # printed ($T/fanin.txt, produced by the real script).
      fanin*) printf 'Tests, traced (shard 1/2)\ttests\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n'
             printf 'Tests, traced (shard 1/2)\ttests\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n'
             sed 's/^/Pure-logic gate fixtures\tverdicts\t2026-09-30T10:07:00Z /' "$T/fanin.txt" ;;
    esac ;;
  *"api repos/"*"/actions/runs/5003/jobs"*)
    if [ -s "$T/jobs5003" ]; then ( set -f; IFS=$'\n'; jobs_json $(cat "$T/jobs5003") ); else jobs_json 'Pure-logic gate fixtures'; fi ;;
  *"api -i -X GET repos/"*"/pulls/31/files"*)
    restpr --raw 200 "$(jq -Rsc '[split("\n")[] | select(length > 0) | {filename: .}]' < "$T/files")" ;;
  # ---- writes -------------------------------------------------------------
  *"api -i -X POST repos/"*"/issues/31/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    { cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) [ -s "$T/noflip" ] || echo acked > "$T/ckmode" ;; esac
    exit 0 ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main \
           "$LBL" MERGEABLE CLEAN operator ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'EOF'
URL="${!#}"; M=GET; B=""
while [ $# -gt 0 ]; do case "$1" in -X) M=$2; shift ;; --data-binary) B=$2; shift ;; esac; shift; done
case "$M $URL" in
  "PUT "*/api/metrics/flakes) printf '%s\n' "$B" >> "$T/flake-puts.txt"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/metrics/flakes\?*) printf '%s\n200\n' "$(cat "$T/flakes" 2>/dev/null || echo '{"flakes":[]}')" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"

mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <mergeState> <labels-csv>
  local lbl="[]"
  [ -n "${4:-}" ] && lbl=$(printf '%s' "$4" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
K31='example-org/mgfy-os#31'
EJWHY='queue-ejected — push a fix; the next head is enqueued on its own merits'
SENT_FOREIGN='re-queued: batch #3767 failed tests/fleet-propagate-test.sh, which this PR does not touch'
SENT_LATER='re-queued: batch #3767 failed tests/fleet-propagate-test.sh; #3768 on the same main passed it'
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# reset_case [mergeState] — the #3759 shape: an approved, green head, ejected
# last tick (a local `ejected` mark, Mergify's `dequeued` label), its batch red
# on a suite this PR does not touch, no later batch.
reset_case() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/attr-comments.txt"; : > "$T/flake-puts.txt"
  : > "$T/reruns.txt"; : > "$T/writes.txt"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" 2>/dev/null
  rm -f "$T/h/bin/test-impact.sh" "$T/jobs5003" "$T/jobstotal" "$T/h/bin/lib/train-shape.sh"
  echo stale > "$T/ckmode"; : > "$T/noflip"; echo success > "$T/vstatus"; : > "$T/cmfail"
  echo suite > "$T/logmode"; echo ok > "$T/run2"; printf 'bin/lib/mc/classify.sh\ntests/mc-x.bh-1-test.sh\n' > "$T/files"
  echo '{"total_count":0,"workflow_runs":[]}' > "$T/later"; echo '{"flakes":[]}' > "$T/flakes"
  printf '[%s,%s]' "$(older_comment)" "$(dq_comment "$H1")" > "$T/comments.json"
  printf 'dequeued\n' > "$T/labels"
  mkrec 31 "$H1"
  printf '[%s]' "$(list_row 31 "$H1" "${1:-UNSTABLE}" dequeued)" > "$T/list.json"
  echo "ejected $K31 $H1" >> "$A"
}
not_requeued() { # not_requeued <case>
  [ ! -s "$T/label-adds.txt" ] && ok || bad "$1: no merge-queue label may go on (got: $(cat "$T/label-adds.txt"))"
  grep -q '@mergifyio requeue' "$T/comments.txt" && bad "$1: no @mergifyio requeue (got: $(cat "$T/comments.txt"))" || ok
  grep -qE "^requeued $K31 " "$A" && bad "$1: no requeued mark (attempts: $(cat "$A"))" || ok
  grep -q 're-queued:' "$T/attr-comments.txt" && bad "$1: no re-queued comment (got: $(cat "$T/attr-comments.txt"))" || ok
  [ ! -s "$T/merges.txt" ] && ok || bad "$1: nothing merges (got: $(cat "$T/merges.txt"))"
}

# ---- BH-3857 fixtures --------------------------------------------------------
HR=(HARNESS_REPO=example-org/mgfy-os)
SUITE=tests/fleet-propagate-test.sh
SENT_LATER='re-queued: batch #3767 failed tests/fleet-propagate-test.sh; #3768 on the same main passed it'
SENT_BOTH="$SENT_FOREIGN; #3768 on the same main passed it"
# ti_stub <root> <always|none> — a test-impact stand-in at <root>/bin that logs
#   its argv: `always` ties the failing suite to every diff, `none` names no row.
ti_stub() {
  mkdir -p "$1/bin"
  { printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ti-calls.txt"\n' "$T"
    [ "$2" = always ] && printf 'printf "%s\\talways\\t*\\n"\n' "$SUITE"
    printf 'echo "impact: %s of 1516 suites (selected: 2 changed path(s))" >&2\n' "$([ "$2" = always ] && echo 1 || echo 0)"
  } > "$1/bin/test-impact.sh"
  chmod +x "$1/bin/test-impact.sh"
}
# mkco <dir> <branch> [always|none] — a scratch checkout: a git repo on
#   <branch>, a tests/ dir and a test-impact stand-in.
mkco() {
  scratch_rm "$1" || return 1; mkdir -p "$1/tests" "$1/catalog"
  ti_stub "$1" "${3:-none}"; : > "$1/tests/a-test.sh"
  cp "$T/h/catalog/test-tiers.tsv" "$1/catalog/" 2>/dev/null
  git -C "$1" init -q 2>/dev/null; git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}
real_ti() { # the REAL test-impact under MC_H, which has no tests/: nomap
  cp "$DIR/bin/test-impact.sh" "$T/h/bin/test-impact.sh"; cp "$DIR/bin/lib/train-shape.sh" "$T/h/bin/lib/" 2>/dev/null
}
later_pass() { # #3768 green on the same main (run 5010), a red one after it
  printf '{"total_count":2,"workflow_runs":[%s,%s]}' \
    "$(later_run 5010 3768 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:30:00Z)" \
    "$(later_run 5011 3769 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:40:00Z failure)" > "$T/later"
}
# The plan log of a later batch, produced by the REAL bin/ci-plan.sh and
# bin/test-tiers.sh (D4) with only test-impact faked, then given the Actions
# timestamp prefix every line of a raw job log carries.
cat > "$T/plan-impact.sh" <<'IMP'
#!/bin/bash
OUT=""; while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; esac; shift; done
N=$(grep -c . "$PLAN_ALL")
case "${TI_EVENT:-}" in
  pull_request) echo "impact: $N of $((N + 5)) suites (selected: 1 changed path(s))" >&2 ;;
  *) echo "impact: $N of $N suites (full: event '${TI_EVENT:-}' is not a pull request)" >&2 ;;
esac
cat "$PLAN_ALL" > "$OUT"
IMP
chmod +x "$T/plan-impact.sh"
printf '%s\ntests/other-suite-test.sh\ntests/g-test.sh\n' "$SUITE" > "$T/plan-all"
: > "$T/plan-prot"
# mkplan <out> <tier rows (printf)> <changed paths (printf)> [quarantine] [head ref]
mkplan() {
  printf "$2" > "$T/h/catalog/test-tiers.tsv"; printf "$3" > "$T/plan-changed"
  for d in "$T/co" "$T/harness-checkout"; do [ -d "$d/catalog" ] && cp "$T/h/catalog/test-tiers.tsv" "$d/catalog/"; done
  ( cd "$T" && env CI_EVENT=pull_request TI_PR_HEAD_REF="${5-mergify/merge-queue/lb}" PLAN_ALL="$T/plan-all" \
      CI_PLAN_IMPACT="$T/plan-impact.sh" CI_PLAN_CHANGED_FILE="$T/plan-changed" \
      CI_PLAN_TIER_FILE="$T/h/catalog/test-tiers.tsv" CI_PLAN_PROTECTED="$T/plan-prot" \
      CI_QUARANTINE="${4:-}" bash "$DIR/bin/ci-plan.sh" --out "$T/plan-list" ) 2>&1 \
    | sed 's/^/2026-09-30T10:31:00.1234567Z /' > "$1"
}
GUARD_ROW="tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n"
mkdir -p "$T/h/catalog"
reset3857() { # reset3857 [mergeState]
  reset_case "${1:-UNSTABLE}"
  rm -rf "$T/co" "$T/harness-checkout"
  rm -f "$T/planlog"* "$T/planjobsfail" "$T/planlogfail" "$T/ti-calls.txt"
  mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n'
}
fr_cf() { ls "$T/h/state/merge-conductor/foreign-red/"*mgfy-os_31_"$H1" 2>/dev/null; }
reads_of() { # reads_of <file> — the attribution reads a cached verdict must not spend
  grep -cE "commits/$H1/check-runs|commits/$H1/status|issues/31/comments|actions/runs/5003|run view 5003|actions/runs\?event=pull_request|pulls/31/files" "$1"
}

# ============================================================================
# CONTRACT — the plan job's name is what the lib looks for, and the plan-log
#            lines the lib reads are the ones the real scripts print.
# ============================================================================
PJ=$(awk '/^  plan:/{f=1; next} f && /^    name: /{sub(/^    name: /, ""); print; exit}' "$DIR/.github/workflows/harness-ci.yml")
GOT=$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${FR_PLAN_JOB:-}"' _ "$DIR/bin/lib/mc-foreign-red.sh")
{ [ -n "$PJ" ] && [ "$GOT" = "$PJ" ]; } && ok || bad "CONTRACT: FR_PLAN_JOB ('$GOT') must equal harness-ci.yml's plan job name ('$PJ')"
mkplan "$T/pl-q" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
grep -qE "^2026-09-30T10:31:00.1234567Z tiers: quarantine $SUITE — out of the batch" "$T/pl-q" && ok || bad "CONTRACT: the real ci-plan prints the quarantine line (got: $(cat "$T/pl-q"))"
grep -qE '^2026-09-30T10:31:00.1234567Z impact: [0-9]+ of [0-9]+ suites \(.*\) — [0-9]+ shard\(s\), mode=full$' "$T/pl-q" && ok || bad "CONTRACT: the real ci-plan prints the mode=full summary (got: $(cat "$T/pl-q"))"

# ============================================================================
# CK — WHERE THE HARNESS REPO'S MAP IS BUILT. MC_H (the hub's /root/harness)
#      has no tests/, so the real test-impact answers nomap there.
# ============================================================================
# CK1 — MC_TI_ROOT is a checkout on main with tests/: attributed, foreign.
reset3857; real_ti; mkco "$T/co" main none
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "CK1: a checkout with tests/ attributes the batch: QUEUED (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(cnt "REQUEUE_ATTRIBUTED $K31 $H1" "$CLOG")" = 1 ] && ok || bad "CK1: one REQUEUE_ATTRIBUTED line (log: $(grep -E 'FOREIGN_RED|REQUEUE' "$CLOG"))"
grep -q -- "--root $T/co\$" "$T/ti-calls.txt" 2>/dev/null && ok || bad "CK1: the checkout's own test-impact ran against the checkout (calls: $(cat "$T/ti-calls.txt" 2>/dev/null))"
[ "$(cnt "FOREIGN_RED_NOMAP" "$CLOG")" = 0 ] && ok || bad "CK1: not nomap"
# CK1b — the production default: harness-sync's checkout beside the harness.
reset3857; real_ti; mkco "$T/harness-checkout" main none
run_tick "${HR[@]}"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "CK1b: <harness>/../harness-checkout is used by default (got $(state_of "$K31"), '$(reason_of "$K31")')"
grep -q -- "--root $T/harness-checkout\$" "$T/ti-calls.txt" 2>/dev/null && ok || bad "CK1b: the select ran in the checkout (calls: $(cat "$T/ti-calls.txt" 2>/dev/null))"
# CK2 — no checkout at all: BH-636 (raw UNSTABLE is not re-queued), logged once.
reset3857; real_ti
run_tick "${HR[@]}"; run_tick "${HR[@]}"
not_requeued CK2
[ "$(cnt "FOREIGN_RED_NOMAP $K31 $H1" "$CLOG")" = 1 ] && ok || bad "CK2: one FOREIGN_RED_NOMAP line over two ticks (got $(cnt FOREIGN_RED_NOMAP "$CLOG"))"
[ "$(cnt "REQUEUE_ATTRIBUTED" "$CLOG")" = 0 ] && ok || bad "CK2: no REQUEUE_ATTRIBUTED"
# CK3 — a checkout on a side branch is not fresh: not used, nomap.
reset3857; real_ti; mkco "$T/co" side none; mkco "$T/harness-checkout" side none
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued CK3
[ "$(cnt "FOREIGN_RED_NOMAP $K31 $H1" "$CLOG")" = 1 ] && ok || bad "CK3: a checkout off main is nomap (got: $(grep -E 'FOREIGN_RED|REQUEUE' "$CLOG"))"
[ ! -s "$T/ti-calls.txt" ] && ok || bad "CK3: the side-branch checkout's test-impact never ran (calls: $(cat "$T/ti-calls.txt"))"
# CK3b — a checkout with no tests/ is not a map either.
reset3857; real_ti; mkco "$T/co" main none; rm -rf "$T/co/tests"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(cnt "FOREIGN_RED_NOMAP $K31 $H1" "$CLOG")" = 1 ] && ok || bad "CK3b: a checkout with no tests/ is nomap"

# ============================================================================
# LB — A LATER BATCH COUNTS ONLY IF IT RAN THE SUITE. Harness repo, the failing
#      suite is an `always` row (checked, untouched, but not "untouched path"):
#      only a later pass can move it, and only one that ran it.
# ============================================================================
# LB1 — the later batch quarantined the suite: not counted. Unknown, nothing ledgered.
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB1
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "LB1: a batch that dropped the suite proves nothing: unknown (got: $(grep -E 'FOREIGN_RED|REQUEUE' "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "LB1: no flake row (got: $(cat "$T/flake-puts.txt"))"
grep -q 'actions/jobs/775010/logs' "$T/gh-calls.txt" && ok || bad "LB1: the later batch's plan log was read"
# LB2 — the same batch without the drop: foreign, re-queued on the later pass.
reset3857; mkco "$T/co" main always; later_pass
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "LB2: a later batch that ran the suite lifts it (got $(state_of "$K31"), '$(reason_of "$K31")')"
grep -q "REQUEUE_ATTRIBUTED $K31 $H1 — $SENT_LATER" "$CLOG" && ok || bad "LB2: the later-batch sentence (log: $(grep REQUEUE_ATTRIBUTED "$CLOG"))"
[ -s "$T/h/state/merge-conductor/foreign-red/plan_5010" ] && ok || bad "LB2: the parsed plan is cached per run id"
# LB2-ledger — an untouched path (no map row): foreign either way, but the
# ledger row needs the later batch to have run it.
reset3857; mkco "$T/co" main none; later_pass
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(grep -c "^$SENT_BOTH\$" "$T/attr-comments.txt")" = 1 ] && ok || bad "LB2-ledger: foreign with the later pass (got: $(cat "$T/attr-comments.txt"))"
[ "$(grep -c . "$T/flake-puts.txt")" = 1 ] && ok || bad "LB2-ledger: one flake row (got: $(cat "$T/flake-puts.txt"))"
reset3857; mkco "$T/co" main none; later_pass
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(grep -c "^$SENT_FOREIGN\$" "$T/attr-comments.txt")" = 1 ] && ok || bad "LB1-ledger: foreign on the untouched path alone, no later-pass clause (got: $(cat "$T/attr-comments.txt"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "LB1-ledger: a later batch that dropped the suite writes NO ledger row (got: $(cat "$T/flake-puts.txt"))"
# LB3 — a guard the later batch skipped, and a nightly-tier suite: not counted.
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$SUITE\tguard\t5\tbin/x.sh\tr\n" 'src/x.ts\n'
grep -q "tiers: guard $SUITE skipped" "$T/planlog" && ok || bad "LB3-guard: fixture carries the real skip line"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB3-guard
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$SUITE\tnightly\t5\t-\tr\n" 'src/x.ts\n'
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB3-nightly
# LB3-guard-ran — the guard's path changed, so it ran: counted.
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$SUITE\tguard\t5\tbin/x.sh\tr\n" 'bin/x.sh\n'
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "LB3-guard-ran: a guard that ran counts (got $(state_of "$K31"), '$(reason_of "$K31")')"
# LB4 — the plan log cannot be read, or the jobs list cannot: not counted, no row.
for f in planlogfail planjobsfail; do
  reset3857; mkco "$T/co" main always; later_pass; echo 1 > "$T/$f"
  run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
  not_requeued "LB4-$f"
  [ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "LB4-$f: unknown (got: $(grep -E 'FOREIGN_RED|REQUEUE' "$CLOG"))"
  [ ! -s "$T/flake-puts.txt" ] && ok || bad "LB4-$f: no flake row"
  [ ! -e "$T/h/state/merge-conductor/foreign-red/plan_5010" ] && ok || bad "LB4-$f: a failed read is never cached"
done
# LB5 — not a full-mode plan (an ordinary PR run), and a log with no summary.
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "" ticket/other
grep -q 'mode=selected' "$T/planlog" && ok || bad "LB5: fixture is a selected-mode plan (got: $(cat "$T/planlog"))"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB5-selected
reset3857; mkco "$T/co" main always; later_pass
grep -v 'impact: ' "$T/planlog" > "$T/planlog.x"; mv "$T/planlog.x" "$T/planlog"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB5-nosummary
# LB6 — a changed path that SPELLS the tier-step-failed warning, in a guard
#       line, does not make a batch that quarantined the suite "ran everything".
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "tests/g-test.sh\tguard\t5\t*\tr\n" 'x ##[warning]ci-plan: the tier step failed, so this batch runs every suite.md\n' "$SUITE"
grep -q 'tier step failed' "$T/planlog" && ok || bad "LB6: fixture carries the spoofing path (got: $(cat "$T/planlog"))"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB6
# LB6b — the real warning, at line start, is every suite ran.
reset3857; mkco "$T/co" main always; later_pass
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
sed -i 's/^\(2026-09-30T10:31:00.1234567Z \)tiers: quarantine .*/\1##[warning]ci-plan: the tier step failed, so this batch runs every suite: boom/' "$T/planlog"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "LB6b: a tier step that failed ran every suite (got $(state_of "$K31"), '$(reason_of "$K31")')"
# LB7 — probes are bounded: three later batches that all dropped the suite,
#       MC_FR_LATER_PROBES=2 reads two of them; with 3, a third that ran it lifts.
lb7_later() {
  printf '{"total_count":3,"workflow_runs":[%s,%s,%s]}' \
    "$(later_run 5010 3768 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:30:00Z)" \
    "$(later_run 5012 3770 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:35:00Z)" \
    "$(later_run 5013 3771 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:45:00Z)" > "$T/later"
}
reset3857; mkco "$T/co" main always; lb7_later
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co" MC_FR_LATER_PROBES=2
not_requeued LB7-bound
[ "$(grep -c 'actions/runs/50[1-9][0-9]/jobs' "$T/gh-calls.txt")" = 2 ] && ok || bad "LB7: two probes, no more (got: $(grep 'actions/runs/50[1-9][0-9]/jobs' "$T/gh-calls.txt"))"
reset3857; mkco "$T/co" main always; lb7_later
mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"; mkplan "$T/planlog-775013" "$GUARD_ROW" 'src/x.ts\n'
run_tick "${HR[@]}" MC_TI_ROOT="$T/co" MC_FR_LATER_PROBES=3
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "LB7: the third probe ran the suite (got $(state_of "$K31"), '$(reason_of "$K31")')"
grep -q "REQUEUE_ATTRIBUTED $K31 $H1 — .*#3771 on the same main passed it" "$CLOG" && ok || bad "LB7: the batch that ran it is named (log: $(grep REQUEUE_ATTRIBUTED "$CLOG"))"
# LB8 — the cached unknown carries the suites: tick 2 re-judges against the
#       later batch's plan (cached) and still refuses one that dropped the suite.
reset3857; mkco "$T/co" main always
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
grep -qP '^S\t0\ttests/fleet-propagate-test.sh$' "$(fr_cf)" && ok || bad "LB8: the unknown cache records the suite (got: $(cat "$(fr_cf)"))"
later_pass; mkplan "$T/planlog" "$GUARD_ROW" 'src/x.ts\n' "$SUITE"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
not_requeued LB8-tick2
: > "$T/gh-calls.txt"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
grep -q 'actions/jobs/' "$T/gh-calls.txt" && bad "LB8: a run's plan is read once (got: $(grep 'actions/jobs' "$T/gh-calls.txt"))" || ok
# LB8-legacy — an unknown cached BEFORE this change (no S rows) is a cache miss:
#       re-attributed in full, and the later batch must still have run the suite.
reset3857; mkco "$T/co" main always
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
sed -i '/^S\t/d' "$(fr_cf)"; later_pass
: > "$T/gh-calls.txt"
run_tick "${HR[@]}" MC_TI_ROOT="$T/co"
grep -q 'actions/runs/5003' "$T/gh-calls.txt" && ok || bad "LB8-legacy: a legacy unknown is re-attributed in full"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "LB8-legacy: and lifted by a later batch that ran it (got $(state_of "$K31"), '$(reason_of "$K31")')"

# ============================================================================
# RC — A CACHED VERDICT COSTS NO ATTRIBUTION READ. MC_REQUEUE_CAP=0 defers the
#      requeue, so the row reaches the gate again on tick 2 on the same head.
# ============================================================================
# RC1 — cached foreign on UNSTABLE.
reset3857
run_tick MC_REQUEUE_CAP=0
[ "$(cnt "REQUEUE_DEFERRED $K31 $H1" "$CLOG")" = 1 ] && ok || bad "RC1: tick 1 is foreign and deferred (log: $(grep "$K31" "$CLOG" | tail -3))"
grep -qx foreign "$(fr_cf)" 2>/dev/null && ok || bad "RC1: foreign is cached"
: > "$T/gh-calls.txt"
run_tick MC_REQUEUE_CAP=0
[ "$(cnt "REQUEUE_DEFERRED $K31 $H1" "$CLOG")" = 2 ] && ok || bad "RC1: tick 2 is still foreign from the cache"
[ "$(reads_of "$T/gh-calls.txt")" = 0 ] && ok || bad "RC1: tick 2 spends 0 attribution reads (got: $(grep -E 'check-runs|/status|issues/31/comments|actions/runs|run view|pulls/31/files' "$T/gh-calls.txt"))"
# RC2 — cached own: 0 reads, one FOREIGN_RED_OWN line, never re-queued.
reset3857; printf '%s\n' "$SUITE" > "$T/files"
run_tick
: > "$T/gh-calls.txt"
run_tick
not_requeued RC2
[ "$(reads_of "$T/gh-calls.txt")" = 0 ] && ok || bad "RC2: a cached own spends 0 attribution reads (got: $(grep -E 'check-runs|/status|issues/31/comments|actions/runs|run view' "$T/gh-calls.txt"))"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "RC2: still one FOREIGN_RED_OWN (got $(cnt FOREIGN_RED_OWN "$CLOG"))"
# RC2-clean — a cached own on a raw CLEAN head never re-queues either.
reset3857 CLEAN; printf '%s\n' "$SUITE" > "$T/files"
run_tick; run_tick
not_requeued RC2-clean
# RC3 — a log that cannot be read: unreadable, cached for the TTL with its comment key.
reset3857; echo fail > "$T/logmode"
run_tick
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "RC3: unreadable (got '$(reason_of "$K31")')" ;; esac
{ [ "$(sed -n 1p "$(fr_cf)")" = unreadable ] && [ "$(sed -n 2p "$(fr_cf)")" = '7001@2026-09-30T10:12:00Z' ]; } && ok || bad "RC3: unreadable cached with the comment key (got: $(cat "$(fr_cf)" 2>/dev/null))"
: > "$T/gh-calls.txt"
run_tick
[ "$(reads_of "$T/gh-calls.txt")" = 0 ] && ok || bad "RC3: inside the TTL, 0 attribution reads (got: $(grep -E 'check-runs|/status|issues/31/comments|actions/runs|run view' "$T/gh-calls.txt"))"
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "RC3: still unreadable from the cache (got '$(reason_of "$K31")')" ;; esac
not_requeued RC3
touch -d '-20 min' "$(fr_cf)"
: > "$T/gh-calls.txt"
run_tick
grep -q 'run view 5003' "$T/gh-calls.txt" && ok || bad "RC3: past the TTL the reads happen again"
# RC3-clean — a cached unreadable never re-queues a raw CLEAN head.
reset3857 CLEAN; echo acked > "$T/ckmode"; echo fail > "$T/logmode"
run_tick; run_tick
not_requeued RC3-clean
# KN1 — MC_FR_UNREADABLE_TTL_MINS=0: never cached, read every tick.
reset3857; echo fail > "$T/logmode"
run_tick MC_FR_UNREADABLE_TTL_MINS=0
[ -z "$(fr_cf)" ] && ok || bad "KN1: TTL 0 caches nothing (got: $(cat "$(fr_cf)"))"
: > "$T/gh-calls.txt"
run_tick MC_FR_UNREADABLE_TTL_MINS=0
grep -q 'run view 5003' "$T/gh-calls.txt" && ok || bad "KN1: TTL 0 reads every tick"
# RC4 — an unreadable before the comment was read (no key) is not cached.
reset3857; echo 1 > "$T/cmfail"
run_tick
[ -z "$(fr_cf)" ] && ok || bad "RC4: an unreadable with no comment key is not cached (got: $(cat "$(fr_cf)"))"

# ============================================================================
# SP / AN — THE STRICT PARSE, through flaky_run_tests_strict with the fake gh.
# ============================================================================
strict() { # strict <log lines (printf)> — sets SOUT, SRC
  printf "$1" > "$T/strict.log"
  cat > "$T/fakebin/gh-strict" <<'GS'
#!/bin/bash
case "$*" in
  *"run view"*"--log-failed"*) cat "$STRICT_LOG" ;;
  *"/jobs"*) printf '{"total_count":1,"jobs":[{"name":"J","status":"completed","conclusion":"failure"}]}\n' ;;
esac
GS
  chmod +x "$T/fakebin/gh-strict"
  SOUT=$(cd "$T" && STRICT_LOG="$T/strict.log" bash -c '
    gh() { "$GH_STRICT" "$@"; }
    . "$1/bin/lib/flaky.sh" || exit 9
    flaky_run_tests_strict example-org/mgfy-os 9001' _ "$DIR" 2>/dev/null); SRC=$?
}
export GH_STRICT="$T/fakebin/gh-strict"
TS='J\tstep\t2026-09-30T10:05:00.1234567Z '
# SP1 — the runner's own marker is P; a test's stdout echoing one is not.
strict "${TS}--- tests/a-test.sh rc=1 4s\n${TS}  --- tests/b-test.sh rc=1\n"
{ [ "$SRC" = 0 ] && grep -qxP 'P\ttests/a-test.sh' <<<"$SOUT"; } && ok || bad "SP1: the anchored marker is P (rc=$SRC, got: $SOUT)"
grep -qP '^P\ttests/b-test.sh$' <<<"$SOUT" && bad "SP1: an indented echo of a marker is never P (got: $SOUT)" || ok
grep -qxP 'T\ttests/b-test.sh' <<<"$SOUT" && ok || bad "SP1: the echoed name is T (unattributable) (got: $SOUT)"
# SP1b — the marker without its seconds, at column 0, is not the runner's shape.
strict "${TS}--- tests/a-test.sh rc=1 4s\n${TS}--- tests/c-test.sh rc=1\n"
grep -qP '^P\ttests/c-test.sh$' <<<"$SOUT" && bad "SP1b: a marker with no seconds is not P (got: $SOUT)" || ok
# SP2 — `FAIL notes.txt` is not a runner test file.
strict "${TS}FAIL src/x.test.ts > works\n${TS}FAIL notes.txt\n"
grep -qP '^P\tnotes.txt$' <<<"$SOUT" && bad "SP2: FAIL notes.txt is never P (got: $SOUT)" || ok
# SP3 — a vitest FAIL line names its test file.
strict "${TS} FAIL  src/x.test.ts > works\n"
{ [ "$SRC" = 0 ] && grep -qxP 'P\tsrc/x.test.ts' <<<"$SOUT"; } && ok || bad "SP3: the vitest file is P (rc=$SRC, got: $SOUT)"
strict "${TS}FAIL src/__tests__/y.js\n"
grep -qxP 'P\tsrc/__tests__/y.js' <<<"$SOUT" && ok || bad "SP3: a __tests__ file is P (got: $SOUT)"
# AN1 — the same vitest line in colour.
strict "${TS}\033[31m FAIL \033[39m src/x.test.ts > works\n"
{ [ "$SRC" = 0 ] && grep -qxP 'P\tsrc/x.test.ts' <<<"$SOUT"; } && ok || bad "AN1: an ANSI-coloured FAIL line still names its file (rc=$SRC, got: $(cat -v <<<"$SOUT"))"
grep -q $'\033' <<<"$SOUT" && bad "AN1: no escape reaches a name (got: $(cat -v <<<"$SOUT"))" || ok

# ============================================================================
# EE1 — END TO END: a failing log whose only name is an echoed marker (a test's
#       stdout, not the runner's line) never reaches the ledger.
# ============================================================================
reset3857
cat > "$T/ee1.log" <<'EE'
Pure-logic gate fixtures	gate	2026-09-30T10:05:00Z   --- tests/echoed-test.sh rc=1 2s
EE
echo ee1 > "$T/logmode"
later_pass
run_tick
not_requeued EE1
[ ! -s "$T/flake-puts.txt" ] && ok || bad "EE1: an echoed marker is never ledgered (got: $(cat "$T/flake-puts.txt"))"

echo "foreign-red-followups.bh-3857: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
