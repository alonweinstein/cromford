#!/bin/bash
# tests/merge-queue-reentry.bh-636-test.sh — BH-636 W2: A PR MERGIFY EJECTED
# FOR A FLAKE HAS TO BE ABLE TO GET BACK IN.
#
# WHERE THE PRs WENT. `An ejected head is never re-enqueued` was the rule, and
# it is right for a head whose batch build genuinely failed. But Mergify ejects
# the culprit of a BATCH, and a batch goes red for reasons that have nothing to
# do with the culprit — a sibling's flake, a killed runner, a timed-out job.
# Those PRs then sat in `WAIT_CI queue-ejected` with every required check green
# at their head and an approval bound to that exact sha, waiting for a push
# that was never coming.
#
# THE REPLACEMENT RULE, AND ITS GUARDS. A PR goes back in exactly once per
# (PR, sha), and only when every check at the CURRENT head is green, the
# approval is bound to THAT head, and the merge is clean: GitHub's CLEAN, or
# (BH-3776, bin/lib/mc-foreign-red.sh) UNSTABLE only through Mergify's own
# bookkeeping checks with the batch failure attributed `foreign`; an `own` or
# `unreadable` attribution never goes back in. A
# red head is left alone and named once (DEQUEUED_RED). A PR ejected a SECOND
# time after a requeue is not re-queued again — it goes to the resolver. And
# nothing on this path ever merges: a requeue Mergify does not acknowledge
# parks the row, it does not fall through to the direct merge.
#
# Driven against the real bin/merge-conductor.sh and a fake gh that records
# every label write, comment and merge call. One clock read (NOW).
# Run from anywhere: tests/merge-queue-reentry.bh-636-test.sh  (exit 0 = all pass)
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
NOW=$(date -u +%s)

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
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31

# ============================================================================
# A. The live-ejection predicate — "is this head still OUT of the queue"
# ============================================================================
: > "$A"
echo "ejected $K31 $H1" >> "$A"
mc_ejection_live "$K31" "$H1" && ok || bad "A1: an ejected head with no requeue must read as a LIVE ejection"
echo "requeued $K31 $H1 $((NOW-100))" >> "$A"
mc_ejection_live "$K31" "$H1" && bad "A2: a head we have already put back is not still ejected — that is how a PR loops for ever" || ok
echo "reejected $K31 $H1" >> "$A"
mc_ejection_live "$K31" "$H1" && ok || bad "A3: ejected AGAIN after a requeue is live again — and it is the resolver's, not the queue's"
: > "$A"
mc_ejection_live "$K31" "$H1" && bad "A4: a head with no marks at all was never ejected" || ok
[ -n "$(mc_requeued_mark "$K31" "$H1")" ] && bad "A4: and it carries no requeue mark either" || ok

# ============================================================================
# B. mc_requeue_mergify — the three writes, and the refusal that writes nothing
# ============================================================================
: > "$A"; : > "$T/labels"; printf 'dequeued\n' > "$T/labels"
: > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
echo running > "$T/checkmode"
mc_requeue_mergify example-org/mgfy-os "$U31" "$H1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "B1: with Mergify witnessing the entry the requeue must succeed (rc $RC)"
grep -q 'labels/dequeued' "$T/label-removes.txt" && ok || bad "B1: Mergify's dequeued label must come off (got: $(cat "$T/label-removes.txt"))"
grep -q 'labels\[\]=merge-queue' "$T/label-adds.txt" && ok || bad "B1: our trigger label must go back on (got: $(cat "$T/label-adds.txt"))"
grep -q '@mergifyio requeue' "$T/comments.txt" && ok || bad "B1: the requeue COMMAND is what re-embarks a dequeued PR (got: $(cat "$T/comments.txt"))"

# B2 — a DELETE the API refuses for any reason but 404 stops everything.
: > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
echo x > "$T/dqfail"
OUT=$(mc_requeue_mergify example-org/mgfy-os "$U31" "$H1"); RC=$?
[ "$RC" = 1 ] && ok || bad "B2: a refused label DELETE must be rc 1 (got $RC)"
[ ! -s "$T/label-adds.txt" ] && ok || bad "B2: and nothing else may be written — a PR labelled merge-queue AND dequeued is a PR nobody queues (got: $(cat "$T/label-adds.txt"))"
[ ! -s "$T/comments.txt" ] && ok || bad "B2: and no comment either (got: $(cat "$T/comments.txt"))"
[ -n "$OUT" ] && ok || bad "B2: the failure must say why, for the log line"
: > "$T/dqfail"

# B3 — the plain enqueue is byte-identical: three args still say `queue`.
: > "$T/comments.txt"; printf 'dequeued\n' > "$T/labels"
mc_enqueue_mergify example-org/mgfy-os "$U31" "$H1" >/dev/null
grep -q '@mergifyio queue' "$T/comments.txt" && ok || bad "B3: an ordinary enqueue must still post @mergifyio queue (got: $(cat "$T/comments.txt"))"
grep -q '@mergifyio requeue' "$T/comments.txt" && bad "B3: and must not have become a requeue" || ok

# ============================================================================
# C. The re-entry arm, through the real conductor
# ============================================================================
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
reset_case() {
  : > "$A"; : > "$T/labels"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"
  : > "$T/comments.txt"; : > "$T/merges.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  echo green > "$T/cistate"; echo running > "$T/checkmode"; echo ok > "$T/qview"
}

# C1 — green at the head, approved at the head, CLEAN, locally ejected: back in.
reset_case
mkrec 31 "$H1"
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
echo "ejected $K31 $H1" >> "$A"
run_tick
grep -q 'labels/dequeued' "$T/label-removes.txt" && ok || bad "C1: the dequeued label must come off (calls: $(cat "$T/label-removes.txt"))"
grep -q 'labels\[\]=merge-queue' "$T/label-adds.txt" && ok || bad "C1: the merge-queue label must go back on (calls: $(cat "$T/label-adds.txt"))"
grep -qE "^requeued $K31 $H1 [0-9]+$" "$A" && ok || bad "C1: the requeue must be recorded once per (PR, sha) (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "C1: a witnessed requeue puts the row back in the queue (got $(state_of "$K31"), reason '$(reason_of "$K31")')"
grep -q "REQUEUED $K31 $H1" "$CLOG" && ok || bad "C1: one line, REQUEUED <pr> <sha> (got: $(grep -o 'mgfy-os#31 .*' "$CLOG" | tail -2))"
[ ! -s "$T/merges.txt" ] && ok || bad "C1: this sweep NEVER merges (got: $(cat "$T/merges.txt"))"
grep -q 'statusCheckRollup' "$T/gh-calls.txt" \
  && bad "C1: the check state must be read at the head sha through actions/runs, never off the PR's rollup" || ok
grep -q "actions/runs?head_sha=$H1" "$T/gh-calls.txt" \
  && ok || bad "C1: and it must be asked for the FULL head sha (calls: $(grep actions "$T/gh-calls.txt" | head -2))"

# C2 — ejected AGAIN after that requeue: the resolver's, never a second requeue.
: > "$T/label-adds.txt"
echo failed > "$T/checkmode"      # Mergify's own check on the head says the batch failed
run_tick
grep -qxF "reejected $K31 $H1" "$A" && ok || bad "C2: a second ejection after a requeue must be counted as one (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "C2: and the PR goes to the resolver (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "C2: with the reason the resolver owns (got '$(reason_of "$K31")')"
[ ! -s "$T/label-adds.txt" ] && ok || bad "C2: nothing re-labels a PR that has been ejected twice (got: $(cat "$T/label-adds.txt"))"

# C3 — a genuinely RED head is left exactly where it is, and named once.
reset_case
mkrec 31 "$H1"
echo red > "$T/cistate"
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
echo "ejected $K31 $H1" >> "$A"
run_tick
[ ! -s "$T/label-adds.txt" ] && ok || bad "C3: never re-queue over a red check (got: $(cat "$T/label-adds.txt"))"
[ "$(grep -c "DEQUEUED_RED $K31" "$CLOG")" = 1 ] && ok || bad "C3: a red ejected head is named exactly once (got $(grep -c "DEQUEUED_RED $K31" "$CLOG"))"
run_tick
[ "$(grep -c "DEQUEUED_RED $K31" "$CLOG")" = 1 ] && ok || bad "C3: and not again on the next tick (got $(grep -c "DEQUEUED_RED $K31" "$CLOG"))"

# C4 — Mergify's label with NO local mark is the same fact, and reads the same.
reset_case
mkrec 31 "$H1"
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
run_tick
grep -q 'labels\[\]=merge-queue' "$T/label-adds.txt" \
  && ok || bad "C4: a PR carrying Mergify's dequeued label must be re-queued even with no local ejection mark (got: $(cat "$T/label-adds.txt"))"
grep -q 'labels/dequeued' "$T/label-removes.txt" \
  && ok || bad "C4: and the dequeued label has to COME OFF — Mergify keeps a dequeued PR out on the same head until it is re-embarked (got: $(cat "$T/label-removes.txt"))"
grep -q '@mergifyio requeue' "$T/comments.txt" \
  && ok || bad "C4: it is a re-entry, not a first enqueue (got: $(cat "$T/comments.txt"))"
grep -qE "^requeued $K31 $H1 [0-9]+$" "$A" \
  && ok || bad "C4: and it is recorded, so the label alone cannot buy a second one (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "C4: and it reaches QUEUED (got $(state_of "$K31"))"

# C5 — observe mode says what it would do and writes nothing at all.
reset_case
rm -f "$T/h/flags/merge-conductor-merge"
mkrec 31 "$H1"
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
echo "ejected $K31 $H1" >> "$A"
run_tick
[ ! -s "$T/label-adds.txt" ] && ok || bad "C5: observe mode must write no label (got: $(cat "$T/label-adds.txt"))"
[ ! -s "$T/label-removes.txt" ] && ok || bad "C5: nor remove one (got: $(cat "$T/label-removes.txt"))"
grep -q "would REQUEUE $K31" "$CLOG" && ok || bad "C5: but it must say what it would have done"
grep -qE "^requeued $K31 " "$A" && bad "C5: and write no mark it did not spend" || ok
touch "$T/h/flags/merge-conductor-merge"

# C6 — the cap: six ejected READY PRs, five requeues, one deferral.
reset_case
ROWS=""
for N in 41 42 43 44 45 46; do
  mkrec "$N" "$H1"
  echo "ejected example-org/mgfy-os#$N $H1" >> "$A"
  [ -n "$ROWS" ] && ROWS="$ROWS,"
  ROWS="$ROWS$(list_row "$N" "$H1" CLEAN MERGEABLE dequeued)"
done
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$ROWS" > "$T/list.json"
run_tick MC_REQUEUE_CAP=5
[ "$(grep -c '^requeued example-org/mgfy-os#4' "$A")" = 5 ] \
  && ok || bad "C6: the per-tick cap must hold at 5 (got $(grep -c '^requeued example-org/mgfy-os#4' "$A"))"
[ "$(grep -c 'REQUEUE_DEFERRED' "$CLOG")" = 1 ] \
  && ok || bad "C6: the sixth is DEFERRED and re-offered, never dropped silently (got $(grep -c 'REQUEUE_DEFERRED' "$CLOG"))"

# C7 — Mergify never acknowledges: the row PARKS. It does not merge.
reset_case
mkrec 31 "$H1"
echo none > "$T/checkmode"        # no witness, ever
printf 'dequeued\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
echo "ejected $K31 $H1" >> "$A"
run_tick
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "C7: an unwitnessed requeue waits, it does not become READY (got $(state_of "$K31"))"
case "$(reason_of "$K31")" in *"witness"*) ok ;; *) bad "C7: and the reason must say what it is waiting for (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/merges.txt" ] && ok || bad "C7: the degraded direct merge must NEVER fire on a requeued head (got: $(cat "$T/merges.txt"))"
: > "$T/label-adds.txt"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE "")" > "$T/list.json"
run_tick
[ ! -s "$T/merges.txt" ] && ok || bad "C7: not on the next tick either (got: $(cat "$T/merges.txt"))"
[ ! -s "$T/label-adds.txt" ] && ok || bad "C7: and never a second requeue for the same sha (got: $(cat "$T/label-adds.txt"))"
[ "$(grep -c "^requeued $K31 $H1" "$A")" = 1 ] && ok || bad "C7: one mark, one requeue (attempts: $(grep requeued "$A"))"

# C8 — the queue read fails on the settle pass: an outage is not an ejection.
reset_case
mkrec 31 "$H1"
mc_row_put "$K31" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$U31"
printf 'merge-queue\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE merge-queue)" > "$T/list.json"
echo fail > "$T/qview"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "C8: a queue state we could not read must leave the row alone (got $(state_of "$K31"))"
grep -qE "^(ejected|requeued) $K31 " "$A" \
  && bad "C8: and must invent neither an ejection nor a requeue (attempts: $(cat "$A"))" || ok

# C9 — THE EJECTION GETS ONE TICK TO STAND. The settle pass runs before the open
#      pass, so a PR could be ejected and re-queued inside one tick: the row
#      would never say `queue-ejected` to anyone reading it, and the witness poll
#      would be asking about a head whose Mergify check still carries the
#      failure the ejection was read from — which reads as a live witness.
reset_case
mkrec 31 "$H1"
mc_row_put "$K31" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$U31"
printf 'merge-queue\n' > "$T/labels"
printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE merge-queue)" > "$T/list.json"
echo failed > "$T/checkmode"   # Mergify's check on the head says the batch failed
run_tick
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "C9: the tick that ejects a PR must leave it ejected (got $(state_of "$K31"))"
grep -q 'queue-ejected' <<<"$(reason_of "$K31")" \
  && ok || bad "C9: and the row must SAY so — nobody can read an ejection that was undone in the same tick (got '$(reason_of "$K31")')"
[ ! -s "$T/label-adds.txt" ] && ok || bad "C9: no re-label in the same tick as the ejection (got: $(cat "$T/label-adds.txt"))"
grep -qE "^requeued $K31 " "$A" && bad "C9: and no requeue mark spent" || ok
# ...and the NEXT tick, with Mergify's check moved off the failure, does re-queue it.
echo running > "$T/checkmode"
run_tick
grep -q 'labels\[\]=merge-queue' "$T/label-adds.txt" \
  && ok || bad "C9: the tick AFTER the ejection is the one that puts it back (got: $(cat "$T/label-adds.txt"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "C9: and it reaches QUEUED (got $(state_of "$K31"))"

echo "merge-queue-reentry.bh-636: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
