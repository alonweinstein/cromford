#!/bin/bash
# tests/mc/batch-solo-rerun.bh-4545-test.sh — BH-4550 (#4545 child 4): a failed
# Mergify batch draft has its failing suites re-run against each member merged
# ALONE onto the draft's base, on the CI pool (prequeue-gate.yml, suites=S).
# Only a member that reproduces is parked `prequeue-red`; a clean one goes back
# in once per head; anything else leaves #4428's rule in charge, unchanged.
#
#   B1-B5    the ticket's acceptance cases, through the real bin/merge-conductor.sh
#   N-*      the negatives: none of them parks anything
#   L        bs_batch's printed contract, sourced from the scratch tree
#
# Driven, not grepped: every case runs the conductor WHOLE in a scratch tree with
# the real libs (bin/lib/mc-batch-eject.sh, bin/lib/mc-prequeue.sh and its
# mc-prequeue.d hooks). Assertions read the sinks: the dispatch argv
# ($T/dispatch.txt), the row table, the prequeue cache, the requeue writes and
# logs/merge-conductor.log.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/batch-solo-rerun.bh-4545-test.sh
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/mgfy-os
FX="$DIR/tests/fixtures/bh-4428"
BS_LIB="$DIR/bin/lib/mc-prequeue.d/batch-solo.sh"
DRAFT=900
BASE7=c0ffee1
BASE40="${BASE7}000000000000000000000000000000000"
DH=$(printf 'd%.0s' $(seq 40))
SUITE=tests/x-test.sh
FP=$(printf '%s\n' "$SUITE" | sha1sum | cut -c1-12)
hd() { printf "$1%.0s" $(seq 20); }     # hd <2-digit num> -> a 40-hex head
H41=$(hd 41); H42=$(hd 42); H43=$(hd 43)
[ -r "$BS_LIB" ] || bad "setup: bin/lib/mc-prequeue.d/batch-solo.sh is missing (the red this suite opens on)"

# ============================================================================
# The scratch tree (the shape of tests/mc-batch-eject-bystander.bh-4428-test.sh
# plus the pre-queue gate and its hooks).
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc-prequeue.d" "$T/h/logs" "$T/h/state" "$T/h/flags" \
         "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/solo"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
for f in merge-conductor-lib gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list flaky gh-ci-read mc-stale-dequeue \
         mc-foreign-red main-red-gate mc-batch-eject mc-prequeue; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/" || exit 1
done
cp "$DIR"/bin/lib/mc-prequeue.d/*.sh "$T/h/bin/lib/mc-prequeue.d/" 2>/dev/null
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=x\n' > "$T/h/env/global.env"
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/catalog"; printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$T/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure lane-alert; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# The stub gh. Per-PR files as in the #4428 suite (comments-<n>.json, labels-<n>,
# head-<n>, ckmode-<n>), plus: draft.title (the draft's title), log555 (the
# draft's failed run's --log-failed; logfail = that read fails), solo/<n> (the
# member's prequeue-gate run: "<status> <conclusion>") and solo/<n>.msg (its one
# annotation), no-wf (the workflow probe 404s), dispatch.rc.
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\nDRAFT=%s\nDH=%s\nBASE7=%s\nBASE40=%s\n' \
    "$T" "$MGFY_YML" "$SLUG" "$DRAFT" "$DH" "$BASE7" "$BASE40"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
ARGS=("$@")
pr_of() { sed -n 's|.*/issues/\([0-9]*\)/.*|\1|p; s|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*" | head -1; }
jobs_json() {
  local q="" prev=""
  for a in "${ARGS[@]}"; do [ "$prev" = -q ] && q="$a"; prev="$a"; done
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | {name: ., status: "completed", conclusion: "failure"})
    | {total_count: length, jobs: .}' | if [ -n "$q" ]; then jq -r "$q"; else cat; fi
}
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  "workflow run prequeue-gate.yml"*)
    printf '%s\n' "$*" >> "$T/dispatch.txt"
    exit "$(cat "$T/dispatch.rc" 2>/dev/null || echo 0)" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*)
    R='[]'
    for f in "$T"/solo/[0-9]*; do
      case "$f" in *.msg) continue ;; esac
      [ -e "$f" ] || continue
      n=${f##*/}; read -r st co < "$f"
      R=$(jq -c --argjson a "$R" --argjson n "$n" --arg h "$(cat "$T/head-$n")" --arg b "$BASE40" --arg s "$st" --arg c "$co" -n \
        '$a + [{id: (7000 + $n), display_title: "prequeue pr=\($n) head=\($h) main=\($b)", status: $s,
                conclusion: (if $c == "-" then null else $c end), created_at: "2026-10-05T03:00:00Z"}]')
    done
    restpr --raw 200 "{\"workflow_runs\":$R}" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    if [ -e "$T/no-wf" ]; then restpr --raw 404 '{"message":"Not Found"}'; else restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}'; fi ;;
  *"api -i -X GET repos/$SLUG/actions/runs/70"[0-9][0-9]"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/70\([0-9][0-9]\)/jobs.*|\1|p' <<<"$*")
    restpr --raw 200 "{\"total_count\":1,\"jobs\":[{\"id\":80$RID,\"name\":\"gate\"}]}" ;;
  *"api -i -X GET repos/$SLUG/check-runs/80"[0-9][0-9]"/annotations"*)
    N=$(sed -n 's|.*/check-runs/80\([0-9][0-9]\)/annotations.*|\1|p' <<<"$*")
    M=$(cat "$T/solo/$N.msg" 2>/dev/null)
    if [ -n "$M" ]; then restpr --raw 200 "$(jq -nc --arg m "$M" '[{title: "prequeue-verdict", message: $m}]')"
    else restpr --raw 200 '[]'; fi ;;
  *"api -i -X GET repos/$SLUG/commits/$BASE7"|*"api -i -X GET repos/$SLUG/commits/$BASE7 "*|*"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*)
    restpr --raw 200 "{\"sha\":\"$BASE40\"}" ;;
  *"actions/runs?head_sha=$DH"*)
    restpr --raw 200 "{\"total_count\":2,\"workflow_runs\":[{\"id\":555,\"head_branch\":\"mergify/merge-queue/abc555\",\"head_sha\":\"$DH\",\"status\":\"completed\",\"conclusion\":\"failure\"},{\"id\":556,\"head_branch\":\"mergify/merge-queue/abc555\",\"head_sha\":\"$DH\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *"run view 555 "*"--log-failed"*)
    [ -e "$T/logfail" ] && exit 1
    cat "$T/log555" ;;
  *"api repos/$SLUG/actions/runs/555/jobs"*) jobs_json gate ;;
  # ---- the #4428 suite's arms, unchanged -----------------------------------
  *"api -i -X GET repos/"*"/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    SHA=$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"$*")
    N=$(grep -lx "$SHA" "$T"/head-* 2>/dev/null | head -1); N=${N##*-}
    case "$(cat "$T/ckmode-$N" 2>/dev/null || echo stale)" in
      stale) restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked) restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*)
    restpr --raw 200 "$(cat "$T/comments-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/branches/"*)
    restpr --raw 200 "{\"name\":\"main\",\"commit\":{\"sha\":\"89f7dd83c7020a196f9a5082fd2a51e91398200a\"}}" ;;
  *"api -i -X GET repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    restpr --raw 200 "{\"total_count\":1,\"jobs\":[{\"id\":77$RID,\"name\":\"CI plan (what this run tests)\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *"api repos/"*"/actions/runs/"*"/jobs"*) jobs_json 'Pure-logic gate fixtures' ;;
  *"api -i -X GET repos/"*"/actions/runs"*"event=pull_request"*) restpr --raw 200 '{"total_count":0,"workflow_runs":[]}' ;;
  *"api -i -X GET repos/"*"/actions/runs/"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p' <<<"$*")
    restpr --raw 200 "{\"id\":$RID,\"head_branch\":\"mergify/merge-queue/abc$RID\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-10-04T01:00:00Z\",\"head_sha\":\"cccccccc11112222333344445555666677778888\",\"display_title\":\"merge queue: checking #1 on main (a00ade0)\",\"pull_requests\":[]}" ;;
  *"run view "*"--log-failed"*)
    printf 'Pure-logic gate fixtures\tgate\t2026-10-04T01:05:00Z ##[error]Process completed with exit code 1.\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*)
    restpr --raw 200 '[{"filename":"bin/lib/mc/classify.sh"}]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    { printf '<<PR %s>>\n' "$(pr_of "$*")"; cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels-$N" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels-$N"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-$N"; sort -u -o "$T/labels-$N" "$T/labels-$N"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) echo acked > "$T/ckmode-$N" ;; esac
    exit 0 ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(pr_of "$*")
    if [ "$PN" = "$DRAFT" ]; then
      restpr --raw 200 "$(jq -nc --argjson n "$PN" --arg t "$(cat "$T/draft.title")" --arg h "$DH" '{number: $n, title: $t, state: "closed", head: {sha: $h}}')"
    elif [ -e "$T/head-$PN" ]; then
      LBL=$(tr '\n' ',' < "$T/labels-$PN" 2>/dev/null | sed 's/,$//')
      restpr OPEN "$(cat "$T/head-$PN")" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator
    else
      restpr --raw 404 '{"message":"Not Found"}'
    fi ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
PQD="$T/h/state/merge-conductor/prequeue"

key_of() { printf '%s#%s' "$SLUG" "$1"; }
state_of()  { awk -F'\t' -v k="$(key_of "$1")" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$(key_of "$1")" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
requeues_of()  { local n; n=$(grep -c "issues/$1/comments.*@mergifyio requeue" "$T/comments.txt" 2>/dev/null); echo "${n:-0}"; }
labeladds_of() { local n; n=$(grep -c "issues/$1/labels" "$T/label-adds.txt" 2>/dev/null); echo "${n:-0}"; }
dispatches() { local n; n=$(grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null); echo "${n:-0}"; }
fpkey()    { printf '%s/%s_%s_%s_%s_%s' "$PQD" "${SLUG//\//_}" "$1" "$(cat "$T/head-$1")" "$BASE40" "$FP"; }
plainkey() { printf '%s/%s_%s_%s_%s' "$PQD" "${SLUG//\//_}" "$1" "$(cat "$T/head-$1")" "$BASE40"; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_MAIN_RED_DETECT=0 FLAKY_LOG_MAX=2000000 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }

# The dequeue comment Mergify posts on member <n> of draft #900: #4121's real
# payload, its last `Checks failed` line moved to this draft (named or not) and
# its `Left the queue` sha moved to this member's head.
dq_comment() { # dq_comment <num> <named 0|1>
  local tail=""; [ "$2" = 1 ] && tail=" · identified as the failing PR"
  jq -c --arg d "on draft #$DRAFT$tail" --arg h "$(cat "$T/head-$1")" \
    '.body |= sub("on draft #4279 · identified as the failing PR"; $d) | .body |= gsub("2150c8f1f93ef0c0a94b05c09e87c425903e4eeb"; $h)
     | . + {user: {login: "mergify[bot]", type: "Bot"}}' "$FX/pr4121-dequeue.json"
}
mkrec() { # mkrec <num> — an approved build record at the member's head
  local d="$T/h/builds/pool-mgfy-MG-$1-20261005$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  cat "$T/head-$1" > "$d/reviewed-sha"; : > "$d/pipeline.log"
}
list_row() { # list_row <num> <labels-csv>
  local lbl; lbl=$(printf '%s' "$2" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/%s/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$SLUG" "$1" "$(cat "$T/head-$1")" "$1" "$lbl"
}
# list_now — the open list as the stub's label files say it is: a PR whose
# labels hold merge-queue was re-queued (Mergify checking it), else dequeued.
list_now() {
  local n parts="" sep=""
  for n in $MEMBERS_ADDED; do
    if grep -qx merge-queue "$T/labels-$n" 2>/dev/null; then parts+="$sep$(list_row "$n" merge-queue)"
    else parts+="$sep$(list_row "$n" dequeued)"; fi
    sep=,
  done
  printf '[%s]' "$parts" > "$T/list.json"
}
tick() { list_now; run_tick "$@"; }
reset_case() { # reset_case <draft title>
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"; : > "$T/dispatch.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/attr-comments.txt"; : > "$T/reruns.txt"; : > "$T/writes.txt"; : > "$CLOG"
  rm -f "$T"/ckmode-* "$T"/labels-* "$T"/comments-*.json "$T"/head-* "$T/h/flags/main-red-mgfy" "$T/logfail" "$T/no-wf" "$T/dispatch.rc"
  rm -f "$T"/solo/*
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" "$T/h/state/merge-conductor/batch-eject" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" "$T/h/state/merge-conductor/handoff" \
         "$PQD" 2>/dev/null
  rm -rf "$T/h/builds/"pool-mgfy-* 2>/dev/null
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
  printf '%s' "$1" > "$T/draft.title"
  # The draft's failed run names one harness suite, from its only failed job.
  printf 'gate\tRun tests\t2026-10-05T01:05:00.0000000Z --- %s rc=1 3s\ngate\tRun tests\t2026-10-05T01:05:01.0000000Z ##[error]Process completed with exit code 1.\n' "$SUITE" > "$T/log555"
  MEMBERS_ADDED=""
}
add_pr() { # add_pr <num> <named 0|1> — ejected from draft #900, approved, green
  hd "$1" > "$T/head-$1"
  dq_comment "$1" "$2" | jq -s -c . > "$T/comments-$1.json"
  printf 'dequeued\n' > "$T/labels-$1"; echo stale > "$T/ckmode-$1"
  mkrec "$1"
  echo "ejected $(key_of "$1") $(cat "$T/head-$1")" >> "$A"
  MEMBERS_ADDED="$MEMBERS_ADDED $1"
}
TITLE3="merge queue: checking #41 + #42 + #43 together on main ($BASE7)"
# solo <num> <status> <conclusion|-> [annotation] — member <n>'s prequeue-gate run.
solo() { printf '%s %s\n' "$2" "$3" > "$T/solo/$1"; printf '%s' "${4:-}" > "$T/solo/$1.msg"; }
verdict_msg() { printf '%s main=%s head=%s suites=%s' "$1" "${3:-$BASE40}" "$(cat "$T/head-$2")" "${4:-}"; }
solo_green() { solo "$1" completed success "$(verdict_msg green "$1")"; }
solo_red()   { solo "$1" completed success "$(verdict_msg red "$1" "$BASE40" "$SUITE")"; }
abc_case() { # a 3-member draft, #42 named by Mergify
  reset_case "$TITLE3"
  add_pr 41 0; add_pr 42 1; add_pr 43 0
}
no_park() { # no_park <case> <num>
  [ "$(state_of "$2")" = BLOCKED_HUMAN ] && bad "$1: #$2 must not be parked (got BLOCKED_HUMAN '$(reason_of "$2")')" || ok
  case "$(reason_of "$2")" in prequeue-red*) bad "$1: #$2 has no prequeue-red reason (got '$(reason_of "$2")')" ;; *) ok ;; esac
}

# ============================================================================
# B1 + B2 + B5 — members A (#41) and C (#43) bystanders, B (#42) named. Only
# B's solo run reproduces: B parks, A and C go back in once each.
# ============================================================================
abc_case
tick
# B1: one dispatch per member, with the batch's suites and its base.
[ "$(dispatches)" = 3 ] && ok || bad "B1: exactly 3 dispatches (got: $(cat "$T/dispatch.txt"))"
for n in 41 42 43; do
  grep -q "^workflow run prequeue-gate.yml -R $SLUG --ref main -f pr=$n -f head=$(cat "$T/head-$n") -f main=$BASE40 -f suites=$SUITE\$" "$T/dispatch.txt" \
    && ok || bad "B1: #$n dispatched with suites=$SUITE on main=$BASE40 (got: $(grep "pr=$n " "$T/dispatch.txt"))"
  [ "$(cut -d' ' -f1 "$(fpkey "$n")" 2>/dev/null)" = pending ] && ok || bad "B1: #$n's fp-keyed entry is pending (got '$(cat "$(fpkey "$n")" 2>/dev/null)'; dir: $(ls "$PQD" 2>/dev/null))"
  [ -e "$(plainkey "$n")" ] && bad "B1: no plain gate key for #$n" || ok
done
# Tick 1 is today's #4428: A and C re-queued, B WAIT_CI queue-ejected.
[ "$(state_of 41)" = QUEUED ] && [ "$(state_of 43)" = QUEUED ] && ok || bad "B5: A and C re-queued by #4428 on tick 1 (got $(state_of 41)/$(state_of 43))"
[ "$(state_of 42)" = WAIT_CI ] && ok || bad "B5: B is WAIT_CI on tick 1 (got $(state_of 42) '$(reason_of 42)')"
grep -q "BATCH_SOLO_PENDING $(key_of 42) $H42" "$CLOG" && ok || bad "B5: tick 1 logs B's solo verdict as pending (log: $(grep BATCH_SOLO "$CLOG"))"
# B2: the runs are still going. No second dispatch.
for n in 41 42 43; do solo "$n" in_progress -; done
tick
[ "$(dispatches)" = 3 ] && ok || bad "B2: still 3 dispatches while the runs are in progress (got $(dispatches))"
[ "$(state_of 42)" = WAIT_CI ] && ok || bad "B2: B waits (got $(state_of 42) '$(reason_of 42)')"
# B5: A green, B red, C green.
solo_green 41; solo_red 42; solo_green 43
tick
[ "$(dispatches)" = 3 ] && ok || bad "B2: still 3 dispatches once the runs completed (got $(dispatches))"
WANT="prequeue-red: $SUITE (reproduced alone on ${BASE40:0:12}, batch #$DRAFT)"
[ "$(state_of 42)" = BLOCKED_HUMAN ] && ok || bad "B5: B is BLOCKED_HUMAN (got $(state_of 42) '$(reason_of 42)')"
[ "$(reason_of 42)" = "$WANT" ] && ok || bad "B5: B's reason is '$WANT' (got '$(reason_of 42)')"
[ "$(mc_state_display "$(state_of 42)" "$(reason_of 42)")" = BLOCKED_AGENT ] && ok || bad "B5: B displays as BLOCKED_AGENT"
[ -s "$(mc_handoff_file "$(key_of 42)")" ] && ok || bad "B5: B's hand-off is recorded"
grep -q "BATCH_SOLO_REPRODUCES $(key_of 42) $H42" "$CLOG" && ok || bad "B5: BATCH_SOLO_REPRODUCES for B (log: $(grep BATCH_SOLO "$CLOG"))"
for n in 41 43; do
  grep -q "BATCH_SOLO_RESULT $(key_of "$n") $(cut -c1-8 "$T/head-$n") draft #$DRAFT .*: green" "$CLOG" \
    && ok || bad "B5: the log names #$n's solo verdict (log: $(grep BATCH_SOLO "$CLOG"))"
  [ "$(requeues_of "$n")" = 1 ] && [ "$(labeladds_of "$n")" = 1 ] && ok || bad "B5: #$n re-queued exactly once (requeues $(requeues_of "$n"), label adds $(labeladds_of "$n"))"
done
grep -q "BATCH_SOLO_RESULT $(key_of 42) ${H42:0:8} draft #$DRAFT .*: red suites=$SUITE" "$CLOG" && ok || bad "B5: the log names B's solo verdict (log: $(grep BATCH_SOLO "$CLOG"))"
[ "$(requeues_of 42)" = 0 ] && [ "$(labeladds_of 42)" = 0 ] && ok || bad "B5: B is never re-queued"
[ ! -s "$T/merges.txt" ] && ok || bad "B5: nothing merges"
# The next tick: B's park is sticky, C is still queued and not re-queued again.
tick
grep -q "$(key_of 42) PARKED .* BLOCKED_AGENT (prequeue-red" "$CLOG" && ok || bad "B5: B's park is sticky on the next tick (log: $(grep -F "$(key_of 42)" "$CLOG" | tail -3))"
[ "$(state_of 42)" = BLOCKED_HUMAN ] && [ "$(reason_of 42)" = "$WANT" ] && ok || bad "B5: B still parked (got $(state_of 42) '$(reason_of 42)')"
[ "$(state_of 43)" = QUEUED ] && ok || bad "B5: C is still QUEUED (got $(state_of 43) '$(reason_of 43)')"
[ "$(requeues_of 43)" = 1 ] && [ "$(requeues_of 41)" = 1 ] && ok || bad "B5: no second requeue of A or C"
[ "$(dispatches)" = 3 ] && ok || bad "B2: still 3 dispatches on the fourth tick (got $(dispatches))"

# ---- L: bs_batch's printed contract, from the same cache (observe mode reads, never dispatches).
if [ -r "$T/h/bin/lib/mc-prequeue.d/batch-solo.sh" ]; then
  out=$( ( MERGES=0; MC_TICK_ID=""; . "$T/h/bin/lib/mc-batch-eject.sh"; . "$T/h/bin/lib/mc-prequeue.sh"
           bs_batch "$SLUG" "$DRAFT"; printf 'BS %s %s\n' "$BS_SUITES" "$BS_BASE" ) 2>/dev/null )
  [ "$out" = "41 $H41 clean
42 $H42 reproduces
43 $H43 clean
BS $SUITE $BASE40" ] && ok || bad "L: bs_batch prints one line per member and sets BS_SUITES/BS_BASE (got: $out)"
else
  bad "L: no batch-solo.sh in the scratch tree"
fi

# ============================================================================
# B3 — the batch's log names only a failed JOB: no solo run, #4428 decides.
# ============================================================================
abc_case
printf 'gate\tRun tests\t2026-10-05T01:05:01.0000000Z ##[error]Process completed with exit code 1.\n' > "$T/log555"
tick; tick
[ "$(dispatches)" = 0 ] && ok || bad "B3: nothing dispatched on job: names (got: $(cat "$T/dispatch.txt"))"
[ "$(cat "$PQD/batchsolo_${SLUG//\//_}_$DRAFT" 2>/dev/null)" = "skip job-only" ] && ok || bad "B3: the draft is cached 'skip job-only' (got '$(cat "$PQD/batchsolo_${SLUG//\//_}_$DRAFT" 2>/dev/null)')"
[ "$(requeues_of 41)" = 1 ] && [ "$(requeues_of 43)" = 1 ] && ok || bad "B3: the bystanders are re-queued once, as #4428 does"
[ "$(state_of 42)" = WAIT_CI ] && ok || bad "B3: the culprit is WAIT_CI (got $(state_of 42))"
case "$(reason_of 42)" in queue-ejected*) ok ;; *) bad "B3: the culprit's reason is #4428's (got '$(reason_of 42)')" ;; esac
grep -q "BATCH_EJECT_CULPRIT $(key_of 42) $H42 draft=#$DRAFT" "$CLOG" && ok || bad "B3: #4428's culprit line"

# ============================================================================
# B4 — 14 members, MAX 13: nothing dispatched, one log line across two ticks.
# ============================================================================
reset_case "merge queue: checking #41 + #42 + #43 + #44 + #45 + #46 + #47 + #48 + #49 + #50 + #51 + #52 + #53 + #54 together on main ($BASE7)"
add_pr 41 0; add_pr 42 1
tick; tick
[ "$(dispatches)" = 0 ] && ok || bad "B4: nothing dispatched over the cap (got: $(cat "$T/dispatch.txt"))"
[ "$(grep -c "BATCH_SOLO_SKIP $SLUG draft #$DRAFT: 14 members > 13, no solo run" "$CLOG")" = 1 ] && ok \
  || bad "B4: exactly one BATCH_SOLO_SKIP line (log: $(grep BATCH_SOLO "$CLOG"))"
# ...and at 14 it runs: the cap is the knob, not a literal.
reset_case "merge queue: checking #41 + #42 + #43 + #44 + #45 + #46 + #47 + #48 + #49 + #50 + #51 + #52 + #53 + #54 together on main ($BASE7)"
add_pr 41 0; add_pr 42 1
tick MC_BATCH_SOLO_MAX_MEMBERS=14
[ "$(dispatches)" = 2 ] && ok || bad "B4: MAX 14 dispatches for the two readable members (got: $(cat "$T/dispatch.txt"))"

# ============================================================================
# NEGATIVES
# ============================================================================
# N-green — every solo run is green: B, the named culprit, is re-queued once.
abc_case
tick
solo_green 41; solo_green 42; solo_green 43
tick
[ "$(state_of 42)" = QUEUED ] && ok || bad "N-green: B re-queued (got $(state_of 42) '$(reason_of 42)')"
[ "$(requeues_of 42)" = 1 ] && ok || bad "N-green: B re-queued exactly once (got $(requeues_of 42))"
grep -q "BATCH_SOLO_CLEAN $(key_of 42) $H42" "$CLOG" && ok || bad "N-green: BATCH_SOLO_CLEAN for B"
grep -q "passed with only this PR merged onto main" "$T/attr-comments.txt" && ok || bad "N-green: the requeue note says the solo run passed (got: $(cat "$T/attr-comments.txt"))"
tick
[ "$(requeues_of 42)" = 1 ] && ok || bad "N-green: no second requeue of B"
no_park N-green 42

# N-witness — every solo run is red (the base itself is red): nobody parks.
abc_case
tick
solo_red 41; solo_red 42; solo_red 43
tick
no_park N-witness 42
[ "$(state_of 42)" = WAIT_CI ] && ok || bad "N-witness: B stays on #4428's WAIT_CI (got $(state_of 42) '$(reason_of 42)')"
grep -q "BATCH_SOLO_COULD_NOT_RUN $(key_of 42) $H42" "$CLOG" && ok || bad "N-witness: B's word is could-not-run (log: $(grep BATCH_SOLO "$CLOG"))"

# N-members — the draft title is not a Mergify checking title: #4428 in charge.
reset_case garbage
add_pr 41 0; add_pr 42 1
tick
[ "$(dispatches)" = 0 ] && ok || bad "N-members: nothing dispatched"
[ "$(requeues_of 41)" = 0 ] && ok || bad "N-members: no requeue (unknown, today's fr_reentry_gate)"
grep -q "FOREIGN_RED_UNKNOWN $(key_of 42) $H42" "$CLOG" && ok || bad "N-members: today's fr_reentry_gate decided"
no_park N-members 42

# N-log — the batch's log cannot be read: no solo run.
abc_case
: > "$T/logfail"
tick
[ "$(dispatches)" = 0 ] && ok || bad "N-log: nothing dispatched"
[ "$(cat "$PQD/batchsolo_${SLUG//\//_}_$DRAFT" 2>/dev/null)" = "skip log-unreadable" ] && ok || bad "N-log: cached 'skip log-unreadable' (got '$(cat "$PQD/batchsolo_${SLUG//\//_}_$DRAFT" 2>/dev/null)')"

# N-off — MC_BATCH_SOLO=0.
abc_case
tick MC_BATCH_SOLO=0
[ "$(dispatches)" = 0 ] && ok || bad "N-off: nothing dispatched"
[ "$(requeues_of 41)" = 1 ] && ok || bad "N-off: #4428 still re-queues the bystander"

# N-nowf — the repo has no prequeue-gate.yml.
abc_case
: > "$T/no-wf"
tick
[ "$(dispatches)" = 0 ] && ok || bad "N-nowf: nothing dispatched"

# N-observe — merge mode off: nothing dispatched.
abc_case
rm -f "$T/h/flags/merge-conductor-merge"
tick
[ "$(dispatches)" = 0 ] && ok || bad "N-observe: nothing dispatched in observe mode"

# N-freeze — the main-red freeze is on and B reproduces: no park.
abc_case
echo "main red" > "$T/h/flags/main-red-mgfy"
tick MC_MAIN_RED_TEST_PATHS='tests/*'
solo_green 41; solo_red 42; solo_green 43
tick MC_MAIN_RED_TEST_PATHS='tests/*'
grep -q 'MAIN_RED_FREEZE in force' "$CLOG" && ok || bad "N-freeze: the freeze is in force"
no_park N-freeze 42
[ "$(requeues_of 41)" = 0 ] && [ "$(requeues_of 43)" = 0 ] && ok || bad "N-freeze: no requeue under the freeze"

# N-adversarial — B's solo run is not a parsed red for this head and base.
adv() { # adv <case> <status> <conclusion> <annotation>
  abc_case
  tick
  solo_green 41; solo "42" "$2" "$3" "$4"; solo_green 43
  tick
  no_park "N-adv-$1" 42
  [ "$(state_of 42)" = WAIT_CI ] && ok || bad "N-adv-$1: B stays on #4428's WAIT_CI (got $(state_of 42) '$(reason_of 42)')"
}
hd 42 > "$T/head-42"
adv cancelled completed cancelled "$(verdict_msg red 42 "$BASE40" "$SUITE")"
adv otherhead completed success "red main=$BASE40 head=$H41 suites=$SUITE"
adv othermain completed success "$(verdict_msg red 42 "$(printf 'e%.0s' $(seq 40))" "$SUITE")"
adv nosuites completed success "$(verdict_msg red 42 "$BASE40" "")"
adv conflict completed success "$(verdict_msg conflict 42)"

echo "batch-solo-rerun (BH-4550): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
