#!/bin/bash
# tests/ci-absent-kick.bh-636-test.sh — BH-636 W3: A HEAD WITH NO RUN IS NOT A
# HEAD THAT IS WAITING.
#
# THE SILENCE THIS KILLS. A moved head whose CI never started answered
# `re-review deferred — CI none` every five minutes, forever: the re-review is
# debounced on CI going green, and a head GitHub never built never goes green.
# #1827 and #1645 sat exactly there. The close/reopen kick that the WAIT_CI
# catch-all already fires was never wired into this path, and a head that has
# ALREADY been kicked and is still silent had no next step at all.
#
# So: the deferral tells `ci=absent` apart from `ci=pending` and `ci=flake`, an
# absent head is KICKED once per head, and the second silence on the same head
# raises ONE actionable ALERTS line instead of another deferral.
#
# Driven against the real bin/merge-conductor.sh and a fake gh that records
# every PATCH; asserted on state/, logs/ALERTS.log and the recorded writes.
# Every age comes from ONE clock read (NOW).
# Run from anywhere: tests/ci-absent-kick.bh-636-test.sh   (exit 0 = all pass)
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
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/"
# BH-1586: mc_ci_state reads actions/runs through gh_rest, so the fixture carries
# the REST library (and the stub answers whole HTTP responses via restpr).
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

H1=aaaaaaaa1111   # the reviewed sha
H2=bbbbbbbb2222   # the moved head, with NO run on it
H3=cccccccc3333   # a head with a PENDING run
H4=dddddddd4444   # a head whose only run was cancelled

{ printf '#!/bin/bash\nT=%s\nH2=%s\nH3=%s\nH4=%s\n' "$T" "$H2" "$H3" "$H4"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$*" in
  *"api -X PATCH repos/"*) printf '%s\n' "$*" >> "$T/patches.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*)
    printf '%s\n' "$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  # The three heads under test, as the REST run list (BH-1586: one read serves
  # both mc_ci_state and mc_ci_flake_runs, each reducing it with its own jq).
  *"actions/runs?head_sha=$H2"*) restpr --runs ;;
  *"actions/runs?head_sha=$H3"*) restpr --runs 'in_progress|' ;;
  *"actions/runs?head_sha=$H4"*) restpr --runs 'completed|cancelled|905|compile' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
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
ALOG="$T/h/logs/ALERTS.log"
CLOG="$T/h/logs/merge-conductor.log"
: > "$T/gh-calls.txt"; : > "$T/patches.txt"; : > "$T/gh-writes.txt"

mkrec() { # mkrec <num> <reviewed-sha>
  local d="$T/h/builds/pool-demo-os-TK-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
}
list_row() { # list_row <num> <head> <mergeState> <mergeable>
  printf '{"number":%s,"url":"https://github.com/example-org/demo-os/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","labels":[],"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$4"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
U() { printf 'https://github.com/example-org/demo-os/pull/%s' "$1"; }
K12='example-org/demo-os#12'

touch "$T/h/flags/merge-conductor-actions"

# ============================================================================
# A. The re-review path: a moved head with NO run on it
# ============================================================================
# A1 — 700s in HEAD_MOVED, MERGEABLE, on the project base, zero runs: KICKED.
mkrec 12 "$H1"
printf '[%s]' "$(list_row 12 "$H2" CLEAN MERGEABLE)" > "$T/list.json"
mc_row_put "$K12" HEAD_MOVED $((NOW-700)) "$H2" "$H1" - "reviewed ${H1:0:8} head ${H2:0:8}" "$(U 12)"
: > "$T/patches.txt"
run_tick
grep -q 'pulls/12 -f state=closed' "$T/patches.txt" && grep -q 'pulls/12 -f state=open' "$T/patches.txt" \
  && ok || bad "A1: a moved head with no workflow run at all must be kicked (close/reopen), got: $(cat "$T/patches.txt")"
grep -qxF "cikick $K12 $H2" "$A" \
  && ok || bad "A1: the kick must be recorded once per (PR, head) (attempts: $(cat "$A"))"
grep -q "CI_KICKED $K12 $H2" "$CLOG" \
  && ok || bad "A1: the kick must be logged as CI_KICKED <pr> <sha> (got: $(grep -o 'demo-os#12 .*' "$CLOG" | tail -2))"
grep -q 're-review deferred — CI none' "$CLOG" \
  && bad "A1: the old blind 'CI none' deferral must be gone — it is the silence this fixes" || ok

# A2 — the same head again: no second kick. One close/reopen per head, ever.
: > "$T/patches.txt"
run_tick
[ ! -s "$T/patches.txt" ] && ok || bad "A2: a head that has been kicked once must never be kicked again (got: $(cat "$T/patches.txt"))"
grep -q 'CI_ABSENT_TWICE' "$ALOG" 2>/dev/null \
  && bad "A2: inside the escalation window the row just waits — it does not page" || ok

# A3 — kicked once, still silent past 2x the window: ONE actionable ALERTS line.
mc_row_put "$K12" HEAD_MOVED $((NOW-1300)) "$H2" "$H1" - "reviewed ${H1:0:8} head ${H2:0:8}" "$(U 12)"
: > "$T/patches.txt"
run_tick
[ "$(grep -c 'CI_ABSENT_TWICE' "$ALOG")" = 1 ] \
  && ok || bad "A3: a second silence on the same head must raise exactly ONE ALERTS line (got $(grep -c 'CI_ABSENT_TWICE' "$ALOG"))"
grep -q 'branches filter' "$ALOG" \
  && ok || bad "A3: the alert must say what to look at, not just that it is stuck (got: $(grep CI_ABSENT_TWICE "$ALOG"))"
[ ! -s "$T/patches.txt" ] && ok || bad "A3: the escalation is an alert, not a second kick (got: $(cat "$T/patches.txt"))"
mc_row_put "$K12" HEAD_MOVED $((NOW-1300)) "$H2" "$H1" - "reviewed ${H1:0:8} head ${H2:0:8}" "$(U 12)"
run_tick
[ "$(grep -c 'CI_ABSENT_TWICE' "$ALOG")" = 1 ] \
  && ok || bad "A3: and it never pages twice for the same head (got $(grep -c 'CI_ABSENT_TWICE' "$ALOG"))"

# A4 — a young row is a run that has not appeared YET, not one that never will.
mkrec 15 "$H1"
printf '[%s]' "$(list_row 15 "$H2" CLEAN MERGEABLE)" > "$T/list.json"
mc_row_put 'example-org/demo-os#15' HEAD_MOVED $((NOW-200)) "$H2" "$H1" - "reviewed ${H1:0:8} head ${H2:0:8}" "$(U 15)"
: > "$T/patches.txt"
run_tick
grep -q 'pulls/15' "$T/patches.txt" \
  && bad "A4: a row 3m old must not be kicked — the run has not appeared yet (got: $(cat "$T/patches.txt"))" || ok
grep -q 'demo-os#15 re-review deferred — ci=absent' "$CLOG" \
  && ok || bad "A4: the deferral must name the state as ci=absent (got: $(grep -o 'demo-os#15 .*' "$CLOG" | tail -1))"

# A5 — a CONFLICTING head runs no workflow BY DESIGN. Never kicked.
mkrec 16 "$H1"
printf '[%s]' "$(list_row 16 "$H2" DIRTY CONFLICTING)" > "$T/list.json"
mc_row_put 'example-org/demo-os#16' HEAD_MOVED $((NOW-1300)) "$H2" "$H1" - "reviewed ${H1:0:8} head ${H2:0:8}" "$(U 16)"
: > "$T/patches.txt"
run_tick MC_MERGE_TREE=1
grep -q 'pulls/16' "$T/patches.txt" \
  && bad "A5: ci=none is the NORMAL state of a conflicted head — kicking one closes and reopens every conflicted PR for nothing" || ok

# ============================================================================
# B. The other CI words keep their own line
# ============================================================================
# B1 — a PENDING run is a run. The literal line other suites pin stays.
mkrec 17 "$H1"
printf '[%s]' "$(list_row 17 "$H3" CLEAN MERGEABLE)" > "$T/list.json"
mc_row_put 'example-org/demo-os#17' HEAD_MOVED $((NOW-1300)) "$H3" "$H1" - "reviewed ${H1:0:8} head ${H3:0:8}" "$(U 17)"
: > "$T/patches.txt"
run_tick
grep -q "demo-os#17 re-review deferred — CI pending on ${H3:0:8}" "$CLOG" \
  && ok || bad "B1: a pending head must keep the byte-for-byte 'CI pending' line (got: $(grep -o 'demo-os#17 .*' "$CLOG" | tail -1))"
grep -q 'pulls/17' "$T/patches.txt" \
  && bad "B1: kicking a head with a run in flight CANCELS that run — never do it" || ok

# B2 — a cancelled head is a FLAKE, not an absence: the flake ladder owns it.
mkrec 18 "$H1"
printf '[%s]' "$(list_row 18 "$H4" CLEAN MERGEABLE)" > "$T/list.json"
mc_row_put 'example-org/demo-os#18' HEAD_MOVED $((NOW-1300)) "$H4" "$H1" - "reviewed ${H1:0:8} head ${H4:0:8}" "$(U 18)"
: > "$T/patches.txt"
run_tick
grep -q 'demo-os#18 re-review deferred — ci=flake' "$CLOG" \
  && ok || bad "B2: a cancelled/timed_out head defers as ci=flake, not ci=absent (got: $(grep -o 'demo-os#18 .*' "$CLOG" | tail -1))"
grep -q 'pulls/18' "$T/patches.txt" \
  && bad "B2: a flaky head is re-run, never close/reopened as well (got: $(cat "$T/patches.txt"))" || ok

# ============================================================================
# C. The WAIT_CI catch-all escalates on the same rule
# ============================================================================
# C1 — WAIT_CI `checks none`, kicked once, still silent 21m later: ONE line.
mkrec 19 "$H2"
printf '[%s]' "$(list_row 19 "$H2" CLEAN MERGEABLE)" > "$T/list.json"
echo "cikick example-org/demo-os#19 $H2" >> "$A"
mc_row_put 'example-org/demo-os#19' WAIT_CI $((NOW-1300)) "$H2" "$H2" - "checks none" "$(U 19)"
: > "$T/patches.txt"
run_tick
[ "$(grep -c 'demo-os#19' "$ALOG")" = 1 ] \
  && ok || bad "C1: a WAIT_CI head that was kicked and is still silent must page exactly once (got: $(grep 'demo-os#19' "$ALOG"))"
grep -q 'CI_ABSENT_TWICE' "$ALOG" && ok || bad "C1: and it must be the CI_ABSENT_TWICE line"
[ ! -s "$T/patches.txt" ] && ok || bad "C1: it is an alert, not a second kick (got: $(cat "$T/patches.txt"))"

# C2 — a CONFLICTING WAIT_CI head is never kicked and never paged.
mkrec 20 "$H2"
printf '[%s]' "$(list_row 20 "$H2" DIRTY CONFLICTING)" > "$T/list.json"
echo "cikick example-org/demo-os#20 $H2" >> "$A"
mc_row_put 'example-org/demo-os#20' WAIT_CI $((NOW-1300)) "$H2" "$H2" - "checks none" "$(U 20)"
: > "$T/patches.txt"
run_tick MC_MERGE_TREE=1
grep -q 'demo-os#20' "$ALOG" \
  && bad "C2: a conflicted head's absent CI is the rebase's business — it must never page as CI_ABSENT_TWICE" || ok
grep -q 'pulls/20' "$T/patches.txt" \
  && bad "C2: and it must never be kicked" || ok

# C3 — and the word reaches the line a PERSON reads. The budget alert's detail
#      said `ci=none`, which reads as "nothing to report" for the two states
#      that are the reader's whole problem.
mkrec 21 "$H2"
printf '[%s]' "$(list_row 21 "$H2" CLEAN MERGEABLE)" > "$T/list.json"
mc_row_put 'example-org/demo-os#21' WAIT_CI $((NOW-7200)) "$H2" "$H2" - "checks none" "$(U 21)"
run_tick
grep -q 'demo-os#21' "$ALOG" && ok || bad "C3: a row two hours past its WAIT_CI budget must page (got: $(cat "$ALOG"))"
grep -q 'ci=absent' "$ALOG" \
  && ok || bad "C3: and the page must say ci=absent, not ci=none (got: $(grep 'demo-os#21' "$ALOG" | tail -1))"

echo "ci-absent-kick.bh-636: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
