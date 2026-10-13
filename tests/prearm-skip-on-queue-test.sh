#!/bin/bash
# tests/prearm-skip-on-queue-test.sh — bin/pre-arm-guards.sh is SKIPPED on a repo
# whose main is behind GitHub's native merge queue, and still runs everywhere else.
#
# WHY. pre-arm exists because CI at a PR head was green against the main of THAT
# moment: it dispatches static-guards.yml on refs/pull/<n>/merge and waits up to
# 1800s. A merge queue builds `main + the entries ahead of it + this PR` and runs
# the required check on exactly that tree, which is the same question asked
# better — and its rc-3 "main moved since" path is structurally unsatisfiable in
# a busy repo, the tail this whole redesign exists to kill. So the queue makes it
# redundant PER REPO. The repo capability is the switch: no flag, nothing to
# forget to unset, and a repo with no merge_queue rule keeps the guard.
#
# Driven: the stub pre-arm writes a sentinel, so "was it invoked" is a fact
# rather than a reading of the code.
# Run from anywhere: tests/prearm-skip-on-queue-test.sh   (exit 0 = all pass)
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

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-1586: the merge-queue provider probe (rulesets, .mergify.yml) is a gh_rest
# read now, so the fixture carries the REST library and the response emitter.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
H1=aaaaaaaa1111
printf 'queued example-org/queued-os - - 2 box-q\nplain example-org/plain-os - - 3 box-p\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"; done
# The sentinel: every pre-arm invocation is written down, with its arguments.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/prearm-calls.txt"\nexit 0\n' "$T" > "$T/h/bin/pre-arm-guards.sh"
chmod +x "$T/h/bin/pre-arm-guards.sh"

for P in "queued QS 11" "plain PL 21"; do
  set -- $P
  mkdir -p "$T/h/builds/pool-$1-$2-$3-20260912000$3"
  echo "PR_CREATED https://github.com/example-org/$1-os/pull/$3" > "$T/h/builds/pool-$1-$2-$3-20260912000$3/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-$1-$2-$3-20260912000$3/review.md"
  echo "$H1" > "$T/h/builds/pool-$1-$2-$3-20260912000$3/reviewed-sha"
done

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/example-org/queued-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/example-org/queued-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/plain-os/rulesets/4"*)
    restpr --raw 200 '{"id":4,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request"}]}' ;;
  *"api -i -X GET repos/example-org/plain-os/rulesets"*) restpr --raw 200 '[{"id":4,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"pr merge"*) exit 0 ;;
  *"pr view https://github.com/example-org/queued-os/pull/11 --json state,isInMergeQueue"*) echo "OPEN true" ;;
  *"pr view https://github.com/example-org/plain-os/pull/21 --json state,isInMergeQueue"*) echo "MERGED false" ;;
  *"--json state,headRefOid"*) echo "OPEN $H1" ;;
  *"--json state"*) echo MERGED ;;
  *"--json mergeCommit"*) echo cccccccc3333 ;;
  *"pr list -R example-org/queued-os --state open"*)
    echo '[{"number":11,"url":"https://github.com/example-org/queued-os/pull/11","headRefOid":"$H1","headRefName":"ticket/qs-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false}]' ;;
  *"pr list -R example-org/plain-os --state open"*)
    echo '[{"number":21,"url":"https://github.com/example-org/plain-os/pull/21","headRefOid":"$H1","headRefName":"ticket/pl-21","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false}]' ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
: > "$T/prearm-calls.txt"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }

grep -q 'example-org/queued-os 11' "$T/prearm-calls.txt" \
  && bad "pre-arm-guards.sh must NOT be dispatched on a merge-queue repo — the merge_group run subsumes it (got: $(cat "$T/prearm-calls.txt"))" || ok
grep -q 'example-org/plain-os 21' "$T/prearm-calls.txt" && ok \
  || bad "pre-arm-guards.sh must still run on a repo with no merge queue (got: $(cat "$T/prearm-calls.txt"))"

echo "prearm-skip-on-queue-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
