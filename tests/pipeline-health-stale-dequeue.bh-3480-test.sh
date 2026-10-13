#!/bin/bash
# tests/pipeline-health-stale-dequeue.bh-3480-test.sh — bin/pipeline-health.sh
# pages a labelled PR Mergify dequeued and nobody fixed (BH-3480).
#
# #3396 sat 1.5h with merge-queue on, its conductor row reading QUEUED, after
# Mergify dequeued it. The block is extracted VERBATIM between its markers and
# run with alert() stubbed against a fake gh; the payload reader is the real
# bin/lib/mc-stale-dequeue.sh. Then the real RETRACT_NS is asked whether a
# cleared condition retracts its page.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> stale dequeue (BH-3480)' "$PH")
B=$(grep -c '^# <<< stale dequeue' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> stale dequeue (BH-3480)' … '# <<< stale dequeue' block (open=$A close=$B)"
awk '/^# >>> stale dequeue \(BH-3480\)/{f=1;next} /^# <<< stale dequeue/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no stale dequeue block to run"; echo "pipeline-health-stale-dequeue.bh-3480: $PASS passed, $((FAIL+1)) failed"; exit 1; }

RL=$(grep -m1 '^RETRACT_NS=' "$PH")
RNS=$( eval "$RL"; printf '%s' "$RETRACT_NS" )
grep -qE "^($RNS):" <<<"staledequeue:proj:31" \
  && ok || bad "staledequeue is not in RETRACT_NS, so a requeued or merged PR never retracts its page"

H="$T/h"
mkdir -p "$H/bin/lib" "$T/fakebin" "$T/c"
cp "$DIR/bin/lib/mc-stale-dequeue.sh" "$H/bin/lib/"
printf 'proj example-org/proj-os - - 2 box\n' > "$H/fleet.conf"
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json")
# payload <num> <state> <updated-epoch>
payload() {
  jq -nc --arg b "${DQBODY/\"state\": \"dequeued\"/\"state\": \"$2\"}" --arg u "$(iso "$3")" \
    '[{id:1, created_at:$u, updated_at:$u, user:{login:"mergify[bot]"}, body:$b}]' > "$T/c/$1.json"
}
# issue <num> <labels-csv> — one open PR in the labelled-issues list
LIST=""
issue() {
  local l; l=$(printf '%s' "$2" | jq -R 'split(",")|map({name:.})' -c)
  LIST="$LIST${LIST:+,}{\"number\":$1,\"pull_request\":{\"url\":\"x\"},\"labels\":$l}"
}
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CT/gh-calls.txt"
case "$*" in
  *"api repos/example-org/proj-os/issues?labels=merge-queue"*) [ "${LIST_MODE:-ok}" = down ] && exit 1; cat "$CT/list.json" ;;
  *"api --paginate repos/example-org/proj-os/issues/"*"/comments"*)
    N=$(sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p' <<<"$*"); cat "$CT/c/$N.json" 2>/dev/null || echo '[]' ;;
  *"api repos/example-org/proj-os/pulls/"*) N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*"); echo "sha$N" ;;
  *"api repos/example-org/proj-os/commits/"*) N=$(sed -n 's|.*/commits/sha\([0-9]*\).*|\1|p' <<<"$*"); cat "$CT/c/$N.head" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"

drive() { # drive [env...]
  : > "$T/alerts.txt"; : > "$T/gh-calls.txt"
  printf '[%s]' "$LIST" > "$T/list.json"
  ( export PATH="$T/fakebin:$PATH" CT="$T" "$@"
    H="$T/h"; PROJECTS=proj
    gh_budget_low() { return 1; }
    alert() { printf '%s|%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    # shellcheck disable=SC1090
    . "$T/block.sh"; echo reached ) > "$T/drive.out" 2>&1
}

# H1 — dequeued 45m ago, head committed before it: one page.
# H2 — dequeued 10m ago: too young.
# H3 — a new head committed after the dequeue: the conductor's to requeue.
# H4 — Mergify's queued label: not read at all.
# H5 — the newest payload is waiting: not dequeued.
issue 31 merge-queue;         payload 31 dequeued $((NOW-2700)); iso $((NOW-9000)) > "$T/c/31.head"
issue 32 merge-queue;         payload 32 dequeued $((NOW-600));  iso $((NOW-9000)) > "$T/c/32.head"
issue 33 merge-queue;         payload 33 dequeued $((NOW-2700)); iso $((NOW-60))   > "$T/c/33.head"
issue 34 merge-queue,queued;  payload 34 dequeued $((NOW-2700)); iso $((NOW-9000)) > "$T/c/34.head"
issue 35 merge-queue;         payload 35 waiting  $((NOW-2700)); iso $((NOW-9000)) > "$T/c/35.head"
drive
grep -qx reached "$T/drive.out" && ok || bad "the block did not run to its end: $(cat "$T/drive.out")"
grep -q '^staledequeue:proj:31|proj #31 dequeued by Mergify 45m ago (payload updated .*) with no new head since; .* push a fix or requeue by hand: https://github.com/example-org/proj-os/pull/31$' "$T/alerts.txt" \
  && ok || bad "H1: a 45m dequeue with no new head must page once: $(cat "$T/alerts.txt")"
[ "$(wc -l < "$T/alerts.txt")" = 1 ] && ok || bad "H1-H5: exactly one page expected, got: $(cat "$T/alerts.txt")"
grep -q ':32|' "$T/alerts.txt" && bad "H2: a 10m dequeue (under STALE_DEQUEUE_MIN) paged" || ok
grep -q ':33|' "$T/alerts.txt" && bad "H3: a head committed after the dequeue paged" || ok
grep -q ':34|' "$T/alerts.txt" && bad "H4: a PR carrying Mergify's queued label paged" || ok
grep -q 'issues/34/comments' "$T/gh-calls.txt" && bad "H4: and its comments were read" || ok
grep -q ':35|' "$T/alerts.txt" && bad "H5: a waiting payload paged" || ok

# H6 — the threshold is the settings row: at 60 the 45m dequeue is young; a
#      junk value falls back to 30.
drive STALE_DEQUEUE_MIN=60
[ -s "$T/alerts.txt" ] && bad "H6: STALE_DEQUEUE_MIN=60 still paged a 45m dequeue: $(cat "$T/alerts.txt")" || ok
drive STALE_DEQUEUE_MIN=abc
grep -q '^staledequeue:proj:31|' "$T/alerts.txt" && ok || bad "H6: a junk STALE_DEQUEUE_MIN must fall back to 30: $(cat "$T/alerts.txt")"

# H7 — the list read fails: no page, and the block still ends.
drive LIST_MODE=down
[ -s "$T/alerts.txt" ] && bad "H7: a failed list read paged: $(cat "$T/alerts.txt")" || ok
grep -qx reached "$T/drive.out" && ok || bad "H7: the block did not run to its end on a failed list read"

# H8 — the condition clears (the PR got a new head): the real epilogue's
#      retraction sees no staledequeue key fired this run.
iso $((NOW-60)) > "$T/c/31.head"
drive
[ -s "$T/alerts.txt" ] && bad "H8: a PR with a new head must stop paging: $(cat "$T/alerts.txt")" || ok
sed -n '/^# ── Retraction epilogue/,/^rm -f "\$FIRED"$/p' "$PH" > "$T/epi.sh"
if [ -s "$T/epi.sh" ]; then
  mkdir -p "$T/eh/state" "$T/eh/logs"
  echo "staledequeue:proj:31" > "$T/eh/state/health-active.txt"
  : > "$T/eh/fired"; echo '{"staledequeue:proj:31":1}' > "$T/eh/dedup.json"
  ( H="$T/eh"; FIRED="$T/eh/fired"; ACTIVE="$T/eh/state/health-active.txt"; DEDUP="$T/eh/dedup.json"; eval "$RL"
    STAMP() { date -u +%FT%TZ; }; alert_emit() { printf '%s\n' "$*" >> "$T/eh/emitted"; }
    # shellcheck disable=SC1090
    . "$T/epi.sh" ) >/dev/null 2>&1
  grep -q 'RESOLVED staledequeue:proj:31' "$T/eh/emitted" "$T/eh/logs/"* 2>/dev/null \
    && ok || bad "H8: the retraction epilogue did not RESOLVE staledequeue:proj:31 ($(cat "$T/eh/emitted" 2>/dev/null))"
else
  bad "H8: no '# ── Retraction epilogue' section found in bin/pipeline-health.sh to drive"
fi

# Page cut — more than 30 labelled PRs: named, never silently judged as all.
LIST=""
for n in $(seq 101 131); do issue "$n" merge-queue; payload "$n" waiting $((NOW-60)); done
drive
grep -q '^staledequeue:proj:page-cut|proj: the stale-dequeue check has more than 30 labelled PRs' "$T/alerts.txt" \
  && ok || bad "a 31-PR list must name its cut: $(head -3 "$T/alerts.txt")"
[ "$(grep -c 'issues/[0-9]*/comments' "$T/gh-calls.txt")" = 30 ] && ok || bad "the cap is 30 comments reads per repo (got $(grep -c 'issues/[0-9]*/comments' "$T/gh-calls.txt"))"

echo "pipeline-health-stale-dequeue.bh-3480: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
