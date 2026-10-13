#!/bin/bash
# tests/hotfix-rereview-order-test.sh — the conductor orders a `hotfix` PR first
# on EVERY repo, and writes the degraded-merge marker only where there is a
# queue to be degraded (BH-645, #643 slice 2 of 5).
#
# THE CASE THIS PINS. BH-369 gave the conductor its hotfix ordering behind one
# condition: `[ "$QUEUE" = 1 ]`. That was right for the marker — the marker
# exists so a plain PR about to bypass a SILENT QUEUE can stand aside for a
# tick — and wrong for the ORDER. A repo with no merge queue at all (PROVIDER
# none, which is most of the fleet) got no ordering whatsoever: its PRs were
# worked in whatever order GitHub listed them, which is exactly the state the
# lane was built to remove. So the condition splits: ordering for every repo
# with rows, marker for queue repos only.
#
# WHAT IS ASSERTED are the artifacts a live box would show — the real
# logs/merge-conductor.log lines, the real `gh` call order recorded by the fake
# gh, and the presence or absence of state/merge-conductor/tick/*.hotfix-*. The
# whole script runs against a scratch $HARNESS, exactly like its sibling
# tests/hotfix-conductor-degraded-test.sh (which owns the QUEUE=1 degraded
# contract and is not edited here).
#
# THE MARKER IS TRANSIENT — every worker drops its own line on exit, so the file
# is empty or gone by the time a tick ends. It is therefore observed the way a
# concurrent worker observes it: the fake gh lists the tick directory on every
# call, so `$T/tick-seen` is what the repo's other PRs could actually see while
# the tick ran. Asserting on the leftovers would prove nothing in either
# direction.
#
# MC_PR_PARALLEL=1 throughout: it makes the tick fork one worker at a time, so
# "#2 before #1" is a fact about the ordering and not about a race between
# three background subshells.
#
# MUTATION (the red-first proof): hoisting `hotfix_pending_write` back out of
# its `QUEUE=1` guard turns section 2 red, and dropping the `ROWS=(HOTROWS
# PLAINROWS)` assignment turns section 1 red. Both re-run against main with:
#   git show main:bin/merge-conductor.sh > /tmp/mc-main.sh
#   CONDUCTOR=/tmp/mc-main.sh bash tests/hotfix-rereview-order-test.sh
#
# Run from anywhere: tests/hotfix-rereview-order-test.sh  (exit 0 = all pass)
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
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
# BH-1194 made bin/jobs-client.sh a SHIM over bin/lib/jobs/*.sh — a fixture that
# copies the client must copy the modules too, or every call through it fails
# closed with "missing module".
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# BH-477: bin/lib/merge-conductor-lib.sh is a SHIM over bin/lib/mc/*.sh — same
# missing-module failure mode as the jobs-client shim above.
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-784/BH-782/BH-945: the classifier's per-PR and closed-list reads moved to
# REST (bin/lib/gh-rest.sh, judged on the HTTP status line `gh api -i` prints,
# never on gh's exit code), and the main-red freeze moved out of
# merge-conductor-lib.sh into its own lib. Without these three a bare `gh api`
# call reads as rc 75 (no contract lib on this box) and every PR fails closed
# to WAIT_CI/NEEDS_REBASE before the hotfix ordering this suite pins ever gets
# exercised — see tests/merge-conductor-test.sh section 0 for the same fixture.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"   # BH-1586: the paged PR-files read
# The shared REST answer emitter (tests/lib/rest-emit.sh docs its shapes): a
# `gh api -i` stub arm must print a real HTTP status line, not a bare gh-CLI
# answer, or gh-rest.sh reads every one of them as a transport failure.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "${CONDUCTOR:-$DIR/bin/merge-conductor.sh}" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
MSHA=cccccccc3333
head_of() { printf 'aaaaaaaa000%s' "$1"; }
TICKDIR="$T/h/state/merge-conductor/tick"

# Three build records: PRs 1, 2, 3 — each APPROVE bound to its own head.
for N in 1 2 3; do
  REC="$T/h/builds/pool-mgfy-MG-$N-20260917000$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: hotfix\n  - name: default\n' | base64 | tr -d '\n')

for N in 1 2 3; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
echo none > "$T/provider"
echo false > "$T/draft-2"

labels_csv() { tr '\n' ',' < "$T/labels-$1" 2>/dev/null | sed 's/,$//'; }
open_list() {
  local n out="" lbl csv drafty
  for n in 1 2 3; do
    [ "$(cat "$T/prstate-$n" 2>/dev/null)" = open ] || continue
    csv=$(labels_csv "$n"); lbl="[]"
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    drafty=false; [ "$n" = 2 ] && drafty=$(cat "$T/draft-2")
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"isDraft\":$drafty,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":$lbl},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

# The fake gh. Two jobs beyond answering: it records every invocation in order
# (that IS the per-PR work order), and it lists the tick directory on every call
# so the transient hotfix marker is observed the way a sibling worker sees it.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
ls -1 "$TICKDIR" 2>/dev/null >> "$T/tick-seen"
PROV=\$(cat "$T/provider" 2>/dev/null || echo none)
# /pulls/N (the BH-784 REST reads and the migration-proof /pulls/N/files read)
# and the legacy /pull/N, /issues/N, issue close/comment spellings all carry
# the PR number the same way — one regex, so a call this fixture has not seen
# before still resolves to a number rather than falling through to PR 1.
N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls?/([0-9]+).*#\1#p; t; s#.*/issues/([0-9]+).*#\1#p; t; s#.*issue (close|comment) ([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=1
PRSTATE=\$(cat "$T/prstate-\$N" 2>/dev/null || echo open)
HEAD=aaaaaaaa000\$N
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
case "\$*" in
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes; a
  # repo with no .mergify.yml answers 404.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*)
    if [ "\$PROV" = mergify ]; then restpr --raw 200 '{"content":"$MGFY_YML"}'
    else restpr --raw 404 '{"message":"Not Found"}'; fi ;;
  *"check-runs"*) : ;;
  # BH-425: gh_budget_refresh's rate_limit read — unanswered, gh_budget_low
  # reads "unknown" and a caller that treats that as low skips the tick.
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N" ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate-\$N"; exit 0 ;;
  *"issue comment"*|*"issue close"*) printf '%s\n' "\$*" >> "$T/issue-calls.txt" ;;
  # BH-370.2's migration-proof gate (mc_hotfix_proof): the added-file listing,
  # no -i — none of these PRs carries migration SQL, so an empty array is n/a.
  # BH-1586: the paged gh_rest reader (\`api -i -X GET …/pulls/N/files -F …\`).
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  # BH-784: the per-PR state read, ONE gh api -i call replacing the old
  # pr-view --json forms below. restpr judges the STATE word the way GitHub
  # really answers MERGED — state closed WITH merged_at set — so \$PRSTATE
  # (flipped by the pr-merge arm above) drives it directly. -H v3.diff is
  # matched FIRST: it is also a /pulls/N call and would otherwise fall into
  # the state arm and answer a diff read with a pull object.
  *"api -i -X GET repos/example-org/mgfy-os/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/mgfy-os/pulls/\$N")
    case "\$PRSTATE" in
      merged) restpr MERGED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN app/cromford "$MSHA" ;;
      closed) restpr CLOSED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN app/cromford ;;
      *)      restpr OPEN   "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN app/cromford ;;
    esac ;;
  # BH-782: the closed-PR reconciliation list, REST now — none of these three
  # PRs is closed-outside-the-tick, so an empty 200 page is the whole answer.
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=closed"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]' ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
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

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_PR_PARALLEL=1 env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
merge_seq() { grep -n -- "/pull/$1 " "$T/merge-calls.txt" 2>/dev/null | head -1 | cut -d: -f1; }
# The first per-PR gh read of the tick: which PR did the conductor start on?
first_pr_touched() {
  grep -oE '(/pull/|/issues/)[0-9]+' "$T/gh-calls.txt" 2>/dev/null | grep -oE '[0-9]+$' | head -1
}
markers_now() { ls -1 "$TICKDIR" 2>/dev/null | grep -c 'hotfix-' | tr -d ' '; }
markers_seen() { grep -c 'hotfix-' "$T/tick-seen" 2>/dev/null | tr -d ' '; }

reset_fixture() { # reset_fixture <labels-for-2> [provider] [draft-2]
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/hotfix-announced" "$T/h/state/merge-sweep-done.txt"
  rm -f "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  for N in 1 2 3; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$T/labels-2"
  echo "${2:-none}" > "$T/provider"
  echo "${3:-false}" > "$T/draft-2"
  for f in gh-calls.txt merge-calls.txt issue-calls.txt label-adds.txt queue-cmds.txt tick-seen; do : > "$T/$f"; done
  : > "$T/h/logs/ALERTS.log"; : > "$CLOG"
  open_list
}
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ---------------------------------------------------------------------------
# 1. §order — PROVIDER=none: the hotfix still heads the tick
# ---------------------------------------------------------------------------
reset_fixture hotfix none
run_tick
grep -q "example-org/mgfy-os#2 heads this tick's order" "$CLOG" && ok \
  || bad "1a: a repo with no merge queue must still log the hotfix ordering (log: $(grep -c . "$CLOG") lines: $(grep 'heads this' "$CLOG"))"
[ "$(first_pr_touched)" = 2 ] && ok \
  || bad "1b: the conductor must start on PR 2 (got PR $(first_pr_touched); first calls: $(head -5 "$T/gh-calls.txt" | tr '\n' '|'))"
[ "$(merge_seq 2)" = 1 ] && ok \
  || bad "1c: PR 2 must be the FIRST merge of the tick (merge calls: $(cat "$T/merge-calls.txt"))"
for N in 1 2 3; do
  [ "$(state_of "example-org/mgfy-os#$N")" = MERGED ] && ok || bad "1d: PR $N must still land (got '$(state_of "example-org/mgfy-os#$N")')"
done
[ "$(grep -c "heads this tick's order" "$CLOG")" = 1 ] && ok \
  || bad "1e: the ordering must be named exactly once (got $(grep -c "heads this tick's order" "$CLOG"))"

# ---------------------------------------------------------------------------
# 2. §no-marker — no queue means no degraded merge to hold back
# ---------------------------------------------------------------------------
[ "$(markers_seen)" = 0 ] && ok \
  || bad "2a: no *.hotfix-* marker may be written on a QUEUE=0 repo (a worker saw: $(grep 'hotfix-' "$T/tick-seen" | sort -u | tr '\n' ' '))"
[ "$(markers_now)" = 0 ] && ok || bad "2b: no *.hotfix-* marker may be left behind on a QUEUE=0 repo ($(ls -1 "$TICKDIR" 2>/dev/null | tr '\n' ' '))"
# D5: the log line must not promise an interaction that cannot happen here.
# One grep, not a file-read piped into `grep -q`: the latter SIGPIPEs the
# upstream grep on its first match under `set -o pipefail` and flakes this
# suite (tests/rollup-crash-loud-test.sh section 5 forbids the shape). Both
# substrings are on the SAME log line when HWAIT is non-empty (see the
# mc_log call this pins), so `.*` between them is the same assertion.
grep -q "heads this tick's order.*degraded merge waits" "$CLOG" \
  && bad "2c: a repo with no queue has no degraded merge to wait — the log must not say so ($(grep 'heads this' "$CLOG"))" || ok

# ---------------------------------------------------------------------------
# 3. §queue-repo-still-marks — semantics unchanged where there IS a queue
# ---------------------------------------------------------------------------
reset_fixture hotfix mergify
run_tick
grep -q "example-org/mgfy-os#2 heads this tick's order" "$CLOG" && ok \
  || bad "3a: a queue repo must still log the ordering ($(grep 'heads this' "$CLOG"))"
[ "$(markers_seen)" -ge 1 ] && ok \
  || bad "3b: a QUEUE=1 repo must write the tick's hotfix marker — the degraded merge reads it (tick-seen: $(sort -u "$T/tick-seen" | tr '\n' ' '))"
grep 'hotfix-' "$T/tick-seen" | grep -q 'hotfix-mgfy' && ok \
  || bad "3c: the marker must be keyed by project (saw: $(grep 'hotfix-' "$T/tick-seen" | sort -u | tr '\n' ' '))"
# Same one-grep shape as 2c above — no file-read piped into `grep -q`.
grep -q "heads this tick's order.*degraded merge waits" "$CLOG" && ok \
  || bad "3d: on a queue repo the line must still say a plain degraded merge waits a tick ($(grep 'heads this' "$CLOG"))"

# ---------------------------------------------------------------------------
# 4. §draft — a draft PR is never the emergency
# ---------------------------------------------------------------------------
reset_fixture hotfix none true
run_tick
grep -q "heads this tick's order" "$CLOG" && bad "4a: a DRAFT PR carrying the label must not reorder the tick ($(grep 'heads this' "$CLOG"))" || ok
[ "$(markers_seen)" = 0 ] && ok || bad "4b: a draft hotfix must write no marker"

# ---------------------------------------------------------------------------
# 5. §no-hotfix / §lane-off — the order is exactly what it is today
# ---------------------------------------------------------------------------
reset_fixture "" none
run_tick
grep -q "heads this tick's order" "$CLOG" && bad "5a: no labelled PR, no reordering ($(grep 'heads this' "$CLOG"))" || ok
[ "$(first_pr_touched)" = 1 ] && ok || bad "5b: with no hotfix the list order stands — PR 1 first (got $(first_pr_touched))"

reset_fixture hotfix-candidate none
run_tick
grep -q "heads this tick's order" "$CLOG" && bad "5c: 'hotfix-candidate' is not the label ($(grep 'heads this' "$CLOG"))" || ok
[ "$(first_pr_touched)" = 1 ] && ok || bad "5d: a near-miss label must leave list order alone (got $(first_pr_touched))"

reset_fixture hotfix none
touch "$T/h/flags/hotfix-lane-off"
run_tick
grep -q "heads this tick's order" "$CLOG" && bad "5e: the kill switch must stop the reordering on a non-queue repo too" || ok
[ "$(first_pr_touched)" = 1 ] && ok || bad "5f: with the lane off the order is today's (got $(first_pr_touched))"
rm -f "$T/h/flags/hotfix-lane-off"

# ---------------------------------------------------------------------------
# 6. §no-cap-exemption — ORDER ONLY. A hotfix goes first; it is never a slot.
# ---------------------------------------------------------------------------
# The ticket's wording is about MC_REREVIEW_PARALLEL ("the ticket says sort key,
# not queue"); the property is the same one every conductor budget expresses, so
# it is pinned on the budget that a fixture can observe end to end. With one
# merge unit for the whole tick the hotfix TAKES that unit — it does not conjure
# a second one, and the plain PRs are refused and counted exactly as they are
# today.
reset_fixture hotfix none
run_tick MC_MERGE_BUDGET=1
[ "$(grep -c . "$T/merge-calls.txt")" = 1 ] && ok \
  || bad "6a: one merge unit must mean exactly one merge, hotfix or not (got: $(cat "$T/merge-calls.txt"))"
[ "$(merge_seq 2)" = 1 ] && ok || bad "6b: the one merge must be the hotfix (merge calls: $(cat "$T/merge-calls.txt"))"
grep -q "merge deferred" "$CLOG" && ok \
  || bad "6c: the PRs behind the spent budget must be refused and counted, not silently skipped ($(grep -c . "$CLOG") log lines)"

echo "hotfix-rereview-order-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
