#!/bin/bash
# tests/merge-conductor-dqw-culprit.bh-3719-test.sh — BH-3728 (BH-3719): A HEAD
# DEQUEUE-WATCH NAMED THE CULPRIT OF ITS BATCH IS NOT RE-QUEUED.
#
# The BH-636 re-entry arm puts an ejected, green, approved-on-head, CLEAN PR
# back in the Mergify queue once per (PR, sha). When dequeue-watch has named
# that exact head the culprit of its batch (the `dqwculprit <key> <sha>` mark),
# a fix round owns it: the conductor holds the row at WAIT_CI, logs
# DQW_CULPRIT once per (PR, sha), and spends no requeue. A culprit mark on an
# OLDER head does not block the current one.
#
# Driven against the real bin/merge-conductor.sh with the fixture and gh stub
# of tests/merge-queue-reentry.bh-636-test.sh. MM re-runs M2 against a copy of
# the conductor with the arm deleted and requires M2 to FAIL there.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-dqw-culprit.bh-3719-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# gh-rest.sh rides with the conductor lib: since BH-784 every decision read in
# the lib goes through it, and a tree without it keeps the fail-closed shims,
# which answer "unverifiable" to everything. tests/lib/rest-emit.sh is the shared
# emitter the stub `gh` answers `gh api -i -X …` with — the contract judges the
# HTTP STATUS LINE, not gh's exit code, so an `echo` of JSON reads as no answer.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

H1=aaaaaaaa1111
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
echo none > "$T/checkmode"        # none | running | failed
echo green > "$T/cistate"         # green | red
: > "$T/labels"                   # the labels on PR 31 (one per line)
echo ok > "$T/qview"              # ok | fail   (the mc_queue_state read)
: > "$T/dqfail"                   # non-empty => the dequeued DELETE is refused 403

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  # The Mergify check-runs read is a REST decision read on the contract now
  # (BH-784): it answers with a status line, and "no check" is an answered empty
  # list rather than an echoed blank. Same facts as the old arm.
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # ---- writes -------------------------------------------------------------
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    [ -s "$T/dqfail" ] && { echo "gh: HTTP 403: Resource not accessible" >&2; exit 1; }
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/merge-queue"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  # THE DECISION READS ARE REST NOW (BH-784): `gh api -i -X GET`, judged on the
  # HTTP status line, so restpr prints a whole response instead of one echoed
  # line. Every `--json` arm below collapses into the single pulls/<n> read —
  # the pull object carries state, head sha, head ref, labels, mergeable,
  # mergeStateStatus and author all at once — so the facts are the same ones,
  # read out of one answer.
  # The diff shares the pulls path and is told apart by its Accept header, so it
  # is matched first; so are the sub-resources, which this fixture answers with
  # nothing exactly as it did before.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    # qview=fail is the outage the old `--json state,headRefOid,labels` arm
    # expressed with `exit 1`. Over REST a read that could not answer is a
    # non-2xx, and 403 is the one the contract maps to UNVERIFIABLE.
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && { restpr --raw 403 '{"message":"Forbidden"}'; exit 0; }
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main \
           "$LBL" MERGEABLE CLEAN operator ;;
  *"--json state,headRefOid,labels"*)
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && exit 1
    SHA=$(sed -n "s|.*/pull/\([0-9]*\).*|\1|p" <<<"$*"); echo "OPEN $(cat "$T/head-$SHA" 2>/dev/null || echo unknown) $LBL" ;;
  *"--json state,headRefName"*) echo "OPEN ticket/mg-31" ;;
  *"--json state,headRefOid"*)  echo "OPEN $(cat "$T/head-31" 2>/dev/null)" ;;
  *"--json labels"*) echo "$LBL" ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator $(cat "$T/head-31" 2>/dev/null)" ;;
  *"--json state"*) echo OPEN ;;
  *"--json mergeCommit"*) echo "" ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  # The PR object over REST (BH-597): state, head sha and labels come from this
  # one call now instead of the paired GraphQL reads above. The $T/qview=fail
  # switch still makes the read FAIL, because that is what this suite pins.
  "api repos/example-org/mgfy-os/pulls/"[0-9]*)
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && exit 1
    RN=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    RLB=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
    RLJ=$(printf '%s' "$RLB" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/{"name":"&"}/' | paste -sd, -)
    printf '{"number":%s,"html_url":"https://github.com/example-org/mgfy-os/pull/%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"%s","ref":"ticket/mg-31"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[%s],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
      "$RN" "$RN" "$(cat "$T/head-$RN" 2>/dev/null || cat "$T/head-31" 2>/dev/null || echo unknown)" "$RLJ" ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*)
    case "$(cat "$T/cistate" 2>/dev/null)" in
      red) restpr --runs 'completed|failure' ;;
      *)   restpr --runs 'completed|success' ;;
    esac ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
for f in gh-calls label-adds label-removes comments merges reruns writes; do : > "$T/$f.txt"; done
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <mergeState> <mergeable> <labels-csv>
  local lbl="[]"
  [ -n "${5:-}" ] && lbl=$(printf '%s' "$5" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$4" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "${CONDUCTOR:-$T/h/bin/merge-conductor.sh}" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
H0=bbbbbbbb0000
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
reset_case() {
  : > "$A"; : > "$T/labels"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"
  : > "$T/comments.txt"; : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  echo green > "$T/cistate"; echo running > "$T/checkmode"; echo ok > "$T/qview"
}
# The C1 READY/ejected fixture of bh-636: green, approved on H1, CLEAN, ejected.
c1_fixture() {
  reset_case
  mkrec 31 "$H1"
  printf 'dequeued\n' > "$T/labels"
  printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
  echo "ejected $K31 $H1" >> "$A"
}
requeues() { grep -c 'labels\[\]=merge-queue' "$T/label-adds.txt"; }
culprit_logs() { grep -c "DQW_CULPRIT $K31 $H1" "$CLOG"; }

# m2_run — the M2 scenario against $CONDUCTOR; rc 0 iff every M2 assertion holds,
# the first failing one on stdout.
m2_run() {
  c1_fixture
  echo "dqwculprit $K31 $H1" >> "$A"
  run_tick
  [ "$(requeues)" = 0 ] || { echo "a culprit head was re-queued ($(requeues) label writes)"; return 1; }
  grep -qE "^requeued $K31 $H1( |$)" "$A" && { echo "a requeued mark was spent on a culprit head"; return 1; }
  [ "$(state_of "$K31")" = WAIT_CI ] || { echo "state is '$(state_of "$K31")', want WAIT_CI"; return 1; }
  case "$(reason_of "$K31")" in *"dequeue-watch named this head the culprit"*) ;;
    *) echo "WHY is '$(reason_of "$K31")'"; return 1 ;; esac
  [ "$(culprit_logs)" = 1 ] || { echo "DQW_CULPRIT logged $(culprit_logs) times after tick 1, want 1"; return 1; }
  run_tick
  [ "$(culprit_logs)" = 1 ] || { echo "DQW_CULPRIT logged $(culprit_logs) times after tick 2, want 1"; return 1; }
  [ "$(requeues)" = 0 ] || { echo "re-queued on tick 2 ($(requeues) label writes)"; return 1; }
  return 0
}

# M1 — no mark: the BH-636 re-entry is untouched.
c1_fixture
run_tick
if [ "$(requeues)" = 1 ] && grep -qE "^requeued $K31 $H1( |$)" "$A"; then pass "M1: no culprit mark -> exactly one requeue, recorded"
else fail "M1: want 1 requeue + requeued mark (writes $(requeues); attempts: $(tr '\n' '|' < "$A"))"; fi

# M2 — culprit mark on the current head: held, logged once, never re-queued.
if WHYF=$(m2_run); then pass "M2: culprit head held at WAIT_CI, DQW_CULPRIT once over two ticks, 0 requeues"
else fail "M2: $WHYF"; fi

# M3 — culprit mark on an OLD head does not block the current one.
c1_fixture
echo "dqwculprit $K31 $H0" >> "$A"
run_tick
if [ "$(requeues)" = 1 ]; then pass "M3: a culprit mark on an older head -> the current head is re-queued"
else fail "M3: want 1 requeue, got $(requeues) (state $(state_of "$K31"), why '$(reason_of "$K31")')"; fi

# MM — mutation: the conductor with the arm deleted must fail M2.
MUT="$T/h/bin/merge-conductor.mut.sh"
sed '/elif mc_attempt_has "dqwculprit /,/dqwculpritlog/d' "$T/h/bin/merge-conductor.sh" > "$MUT"
GONE=$(( $(wc -l < "$T/h/bin/merge-conductor.sh") - $(wc -l < "$MUT") ))
if cmp -s "$T/h/bin/merge-conductor.sh" "$MUT"; then
  fail "MM: the arm is not in bin/merge-conductor.sh — the mutant is identical, so the mutation proves nothing"
elif [ "$GONE" != 3 ]; then
  fail "MM: deleting the arm removed $GONE lines, want exactly 3"
elif MWHY=$(CONDUCTOR="$MUT" m2_run); then
  fail "MM: M2 still passes with the arm deleted — M2 does not pin it"
else
  pass "MM: M2 fails without the arm ($MWHY)"
fi

echo "merge-conductor-dqw-culprit.bh-3719: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
