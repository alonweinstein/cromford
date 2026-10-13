#!/bin/bash
# tests/merge-conductor-stale-dequeue.bh-3480-test.sh — BH-3480: A PR MERGIFY
# DEQUEUED GOES BACK IN ONCE A FRESH VERDICT BINDS ITS NEW HEAD.
#
# #3396 (2026-09-29): dequeued 02:03 for a failing check, fixed 03:36, and it
# sat with merge-queue on and its row reading QUEUED until a person posted
# `@Mergifyio requeue` at 03:45. The conductor now reads Mergify's payload
# (bin/lib/mc-stale-dequeue.sh) and requeues once per (PR, head) when a verdict
# newer than the dequeue binds the head; a head dequeued again after its
# requeue goes to the resolver.
#
#   P  sdq_payload_last against #3396's real mergify[bot] comments
#      (tests/fixtures/bh-3480-pr3396-mergify-comments.json)
#   D  the pure sdq_decide table: every adversarial negative, every positive
#   C  real bin/merge-conductor.sh ticks against a fake gh and a fake worker
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
FIX="$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json"
SDQ="$DIR/bin/lib/mc-stale-dequeue.sh"
[ -r "$SDQ" ] || { echo "FAIL: $SDQ is missing"; echo "merge-conductor-stale-dequeue.bh-3480: 0 passed, 1 failed"; exit 1; }
# The real dequeued comment of #3396, verbatim, as the template every
# time-relative fixture below is cut from (D4: the shape Mergify writes).
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$FIX")
# mcom <state> <created-epoch> <updated-epoch> <id> [login] — one comment object
mcom() {
  jq -nc --arg b "${DQBODY/\"state\": \"dequeued\"/\"state\": \"$1\"}" --arg c "$(iso "$2")" --arg u "$(iso "$3")" \
     --argjson id "$4" --arg l "${5:-mergify[bot]}" '{id:$id, created_at:$c, updated_at:$u, user:{login:$l}, body:$b}'
}

# ============================================================================
# P. sdq_payload_last — which payload is Mergify's latest word, and when
# ============================================================================
(
  # shellcheck source=bin/lib/mc-stale-dequeue.sh
  . "$SDQ"
  gh() { [ -s "$T/pfail" ] && return 1; cat "$T/pl.json"; }
  : > "$T/pfail"
  # P1 — #3396 as the conductor saw it before the hand requeue: the "Queued —"
  #      pointer plus the dequeued status comment. updated_at is the time.
  jq -c '[.[] | select(.id == 5882216652 or .id == 5882237379)]' "$FIX" > "$T/pl.json"
  OUT=$(sdq_payload_last example-org/cromford 3396); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "dequeued	$(date -u -d 2026-09-29T03:45:49Z +%s)	5882237379" ] \
    && echo ok || echo "bad P1: #3396's dequeued comment must read dequeued at its updated_at (rc $RC, got '$OUT')"
  # P1b — all of #3396, merged at the end: the newest comment wins.
  cp "$FIX" "$T/pl.json"
  OUT=$(sdq_payload_last example-org/cromford 3396)
  [ "$(cut -f1 <<<"$OUT")" = merged ] && echo ok || echo "bad P1b: the full #3396 thread ends merged (got '$OUT')"
  # P2 — a human pasting a payload block is not Mergify.
  printf '[%s,%s]' "$(mcom waiting $((NOW-900)) $((NOW-900)) 10)" "$(mcom dequeued $((NOW-60)) $((NOW-60)) 11 operator)" > "$T/pl.json"
  OUT=$(sdq_payload_last o/r 1)
  [ "$(cut -f1 <<<"$OUT")" = waiting ] && echo ok || echo "bad P2: a operator comment carrying a payload must be ignored (got '$OUT')"
  # P3 — the newer status comment wins even when Mergify edited the OLDER one
  #      later (it adds "Requeued — continues in" to the old one on a requeue).
  printf '[%s,%s]' "$(mcom dequeued $((NOW-3600)) $((NOW-60)) 20)" "$(mcom waiting $((NOW-300)) $((NOW-290)) 21)" > "$T/pl.json"
  OUT=$(sdq_payload_last o/r 1)
  [ "$(cut -f1 <<<"$OUT")" = waiting ] && [ "$(cut -f3 <<<"$OUT")" = 21 ] \
    && echo ok || echo "bad P3: the newer waiting payload must win over an older, later-edited dequeued one (got '$OUT')"
  # P4 — no payload comment at all.
  jq -c '[.[] | select(.id == 5882216652 or .id == 5883254101)]' "$FIX" > "$T/pl.json"
  sdq_payload_last o/r 1 >/dev/null; RC=$?
  [ "$RC" = 1 ] && echo ok || echo "bad P4: no payload comment is rc 1 (got $RC)"
  # P5 — a payload that does not parse is 'cannot tell', not 'none'.
  printf '[%s]' "$(jq -nc --arg b "$(printf -- '-*- Mergify Payload -*-\n{"version": 1, "state": \n-*- Mergify Payload End -*-')" \
     '{id:1, created_at:"2026-09-29T01:00:00Z", updated_at:"2026-09-29T01:00:00Z", user:{login:"mergify[bot]"}, body:$b}')" > "$T/pl.json"
  sdq_payload_last o/r 1 >/dev/null; RC=$?
  [ "$RC" = 2 ] && echo ok || echo "bad P5: broken payload JSON is rc 2 (got $RC)"
  # P6 — a failed read is rc 2.
  echo x > "$T/pfail"
  sdq_payload_last o/r 1 >/dev/null; RC=$?
  [ "$RC" = 2 ] && echo ok || echo "bad P6: a failed comments read is rc 2 (got $RC)"
  : > "$T/pfail"
  # P7 — --paginate prints one array per page; the newest across pages wins.
  { printf '[%s]' "$(mcom dequeued $((NOW-3600)) $((NOW-3600)) 30)"; printf '[%s]' "$(mcom waiting $((NOW-100)) $((NOW-100)) 31)"; } > "$T/pl.json"
  OUT=$(sdq_payload_last o/r 1)
  [ "$(cut -f1 <<<"$OUT")" = waiting ] && echo ok || echo "bad P7: two pages must be read as one list (got '$OUT')"
  # P8 — sdq_head_pushed_epoch: a committer date is an epoch; an empty or
  #      failed answer is rc 2, never "today 00:00Z" (GNU date -d "").
  gh() { echo "2026-09-29T03:36:10Z"; }
  OUT=$(sdq_head_pushed_epoch o/r abc); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "$(date -u -d 2026-09-29T03:36:10Z +%s)" ] && echo ok || echo "bad P8: a committer date must read as its epoch (rc $RC, got '$OUT')"
  gh() { echo ""; }
  sdq_head_pushed_epoch o/r abc >/dev/null; RC=$?
  [ "$RC" = 2 ] && echo ok || echo "bad P8: an empty committer date is rc 2 (got $RC)"
  gh() { return 1; }
  sdq_head_pushed_epoch o/r abc >/dev/null; RC=$?
  [ "$RC" = 2 ] && echo ok || echo "bad P8: a failed commit read is rc 2 (got $RC)"
) > "$T/p.out" 2>&1
PASS=$((PASS + $(grep -c '^ok$' "$T/p.out")))
while IFS= read -r l; do bad "${l#bad }"; done < <(grep -v '^ok$' "$T/p.out")

# ============================================================================
# D. sdq_decide — the pure table. T=1000.
# ============================================================================
(
  # shellcheck source=bin/lib/mc-stale-dequeue.sh
  . "$SDQ"
  # row <name> <want> <args…>
  row() { local n="$1" w="$2" g; shift 2; g=$(sdq_decide "$@"); [ "$g" = "$w" ] && echo ok || echo "bad $n: want $w, got '$g' for ($*)"; }
  L=merge-queue
  # positives
  row D1  requeue  dequeued 1000 2000 - - 1 - "$L"               # box approval, head committed after T
  row D2  requeue  dequeued 1000 500 MERGE 1500 0 - "$L"         # lead MERGE newer than T, old head
  row D2b requeue  dequeued 1000 - MERGE-WITH-NOTES 1001 0 - "$L,other"
  # adversarial negatives (plan System invariants (c))
  for s in waiting queued checking merged embarked; do row "D3-$s" none "$s" 1000 2000 - - 1 - "$L"; done
  row D4  none     dequeued 1000 1000 - - 1 - "$L"               # head committed AT the dequeue, not after (> not >=)
  row D4b none     dequeued 1000 900 - - 1 - "$L"                # approval on a head older than the dequeue
  row D5  none     dequeued 1000 - MERGE 1000 0 - "$L"           # lead MERGE not newer than T
  row D6  none     dequeued 1000 2000 BLOCK 1500 1 - "$L"        # a lead BLOCK stands on HEAD
  row D7  none     dequeued 1000 2000 - - 0 - "$L"               # approval bound to another head only
  row D8  none     dequeued 1000 2000 - - 1 - ""                 # no merge-queue label
  row D8b none     dequeued 1000 2000 - - 1 - "$L,queued"        # Mergify visibly holds it
  row D8c none     dequeued 1000 2000 - - 1 - "$L,checking"
  row D9  none     "" "" 2000 - - 1 - "$L"                       # unparseable / unread
  # already requeued on this head
  row D10 wait     dequeued 1000 2000 - - 1 1200 "$L"            # the dequeue predates our requeue
  row D11 wait     dequeued 1250 2000 - - 1 1000 "$L"            # Mergify's edit seconds after our requeue
  row D12 resolver dequeued 1400 2000 - - 1 1000 "$L"            # dequeued again, well after the requeue
  row D13 resolver dequeued 1400 2000 BLOCK 1500 0 1000 "$L"     # the requeue mark decides before any verdict
  row D14 wait     dequeued 1300 2000 - - 1 1000 "$L"            # exactly the grace: not yet a second dequeue
  row D15 resolver dequeued 1100 2000 - - 1 1000 "$L" 60         # grace is an argument
) > "$T/d.out" 2>&1
PASS=$((PASS + $(grep -c '^ok$' "$T/d.out")))
while IFS= read -r l; do bad "${l#bad }"; done < <(grep -v '^ok$' "$T/d.out")

# ============================================================================
# C. The arm, through the real conductor
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/mc-stale-dequeue.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done

H2=8747024e0b1c2d3e4f5061728394a5b6c7d8e9f0
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # ---- the two reads BH-3480 adds -----------------------------------------
  *"api --paginate repos/example-org/mgfy-os/issues/"*"/comments"*)
    [ -s "$T/cfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    cat "$T/mcomments.json" ;;
  *"api repos/example-org/mgfy-os/commits/"*) cat "$T/headdate" ;;
  # ---- writes -------------------------------------------------------------
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  "api repos/example-org/mgfy-os/pulls/"[0-9]*)
    RN=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    RLJ=$(printf '%s' "$LBL" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/{"name":"&"}/' | paste -sd, -)
    printf '{"number":%s,"html_url":"https://github.com/example-org/mgfy-os/pull/%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"%s","ref":"ticket/mg-31"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[%s],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
      "$RN" "$RN" "$(cat "$T/head-$RN" 2>/dev/null || echo unknown)" "$RLJ" ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
# The jobs worker: the standing verdict on PR 31 is whatever $T/verdict says.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  */api/verdicts\?*)
    if [ -s "$T/verdict" ]; then printf '{"standing":%s}\n200\n' "\$(cat "$T/verdict")"; else printf '{"standing":null}\n200\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31

mkrec() { # mkrec <num> <head> <reviewed-sha>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026092900$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <labels-csv>
  local lbl="[]"
  [ -n "${3:-}" ] && lbl=$(printf '%s' "$3" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}]' \
    "$1" "$1" "$2" "$1" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
requeues()  { grep -c '@mergifyio requeue' "$T/comments.txt"; }
payload_reads() { grep -c 'api --paginate repos/example-org/mgfy-os/issues/31/comments' "$T/gh-calls.txt"; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# The #3396 shape: merge-queue still on (no Mergify label), the row QUEUED from
# last tick, Mergify's newest payload `dequeued` an hour ago.
# setup <labels> <head-committed-epoch> <reviewed-sha>
setup() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/verdict"; : > "$T/cfail"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/mergify-asks" 2>/dev/null
  echo running > "$T/checkmode"
  printf '%s\n' "$1" | tr ',' '\n' > "$T/labels"
  iso "$2" > "$T/headdate"
  mkrec 31 "$H2" "$3"
  list_row 31 "$H2" "$1" > "$T/list.json"
  printf '[%s]' "$(mcom dequeued $((NOW-3700)) $((NOW-3600)) 100)" > "$T/mcomments.json"
  mc_row_put "$K31" QUEUED $((NOW-300)) "$H2" "$H2" - "in the merge queue" "$U31"
}

# C1 — stale dequeue, the conductor's approval on a head committed after it:
#      exactly one requeue, logged and counted.
setup merge-queue $((NOW-600)) "$H2"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "C1: exactly one @mergifyio requeue must be posted (got $(requeues); comments: $(cat "$T/comments.txt"); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -q 'labels/dequeued' "$T/label-removes.txt" && ok || bad "C1: the requeue goes through mc_requeue_mergify, which clears Mergify's dequeued label first (got: $(cat "$T/label-removes.txt"))"
grep -q "STALE_DEQUEUE_REQUEUED $K31 $H2" "$CLOG" && ok || bad "C1: one STALE_DEQUEUE_REQUEUED line (log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -rqs '^staledequeue_requeue 1$' "$T/h/state/merge-conductor/tick" && ok || bad "C1: the staledequeue_requeue counter must read 1 ($(grep -rs staledequeue "$T/h/state/merge-conductor/tick" | head -2))"
grep -qE "^requeued $K31 $H2 [0-9]+$" "$A" && ok || bad "C1: the (PR, head) requeue mark must be written (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "C1: a witnessed requeue leaves the row QUEUED (got $(state_of "$K31") '$(reason_of "$K31")')"
[ ! -s "$T/merges.txt" ] && ok || bad "C1: this arm never merges (got: $(cat "$T/merges.txt"))"

# C2 — the same head on the next tick: no second requeue, and the row stops
#      claiming QUEUED.
run_tick
[ "$(requeues)" = 1 ] && ok || bad "C2: the same head must never be requeued twice (got $(requeues))"
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "C2: a requeued head Mergify has not taken waits (got $(state_of "$K31") '$(reason_of "$K31")')"
case "$(reason_of "$K31")" in *"never re-queued twice"*) ok ;; *) bad "C2: the reason must say so (got '$(reason_of "$K31")')" ;; esac

# C3 — no verdict newer than the dequeue: the approval binds a head committed
#      BEFORE it (BH-636's case, not this one) and no lead row stands.
setup merge-queue $((NOW-7200)) "$H2"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C3: no verdict on the current head must mean no requeue (got $(requeues))"
grep -qE "^requeued $K31 " "$A" && bad "C3: and no mark spent (attempts: $(cat "$A"))" || ok

# C3b — a lead MERGE row on HEAD, newer than the dequeue. The head was
#       committed BEFORE the dequeue, so the box approval alone is not fresh
#       (C3c) and only the lead row can make it so.
setup merge-queue $((NOW-7200)) "$H2"
printf '{"verdict":"MERGE","source":"lead","id":7,"created_at":"%s","report_url":null,"reviewer":"lead"}' "$(iso $((NOW-60)))" > "$T/verdict"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "C3b: a lead MERGE newer than the dequeue must requeue (got $(requeues); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"

# C3c — the same lead MERGE, but OLDER than the dequeue: not fresh.
setup merge-queue $((NOW-7200)) "$H2"
printf '{"verdict":"MERGE","source":"lead","id":7,"created_at":"%s","report_url":null,"reviewer":"lead"}' "$(iso $((NOW-5000)))" > "$T/verdict"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C3c: a lead MERGE older than the dequeue must not requeue (got $(requeues))"

# C4 — requeued, then Mergify dequeues the head AGAIN: the resolver's, with
#      no new comment.
setup merge-queue $((NOW-600)) "$H2"
run_tick
[ "$(requeues)" = 1 ] || bad "C4 setup: the first requeue did not happen (got $(requeues))"
printf '[%s,%s]' "$(mcom dequeued $((NOW-3700)) $((NOW-3600)) 100)" "$(mcom dequeued $((NOW+600)) $((NOW+900)) 101)" > "$T/mcomments.json"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "C4: a re-dequeue after a requeue must not post again (got $(requeues))"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "C4: it goes to the resolver (got $(state_of "$K31") '$(reason_of "$K31")')"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "C4: on the reason the resolver owns (got '$(reason_of "$K31")')"
[ "$(grep -cxF "reejected $K31 $H2" "$A")" = 1 ] && ok || bad "C4: one reejected mark, so the strike count agrees (attempts: $(cat "$A"))"
grep -q "STALE_DEQUEUE_RESOLVER $K31 $H2" "$CLOG" && ok || bad "C4: one STALE_DEQUEUE_RESOLVER line"

# C5 — observe mode: says what it would do, writes nothing.
setup merge-queue $((NOW-600)) "$H2"
rm -f "$T/h/flags/merge-conductor-merge"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C5: observe mode must post nothing (got $(requeues))"
[ ! -s "$T/label-adds.txt" ] && [ ! -s "$T/label-removes.txt" ] && ok || bad "C5: nor touch a label (adds: $(cat "$T/label-adds.txt"); removes: $(cat "$T/label-removes.txt"))"
grep -q "STALE_DEQUEUE_WOULD_REQUEUE $K31 $H2" "$CLOG" && ok || bad "C5: one WOULD line (log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -qE "^requeued $K31 " "$A" && bad "C5: and no mark it did not spend" || ok
touch "$T/h/flags/merge-conductor-merge"

# C6 — Mergify's own queued label: it is holding the PR, the payload is not
#      even read.
setup merge-queue,queued $((NOW-600)) "$H2"
run_tick
[ "$(payload_reads)" = 0 ] && ok || bad "C6: a PR carrying Mergify's queued label costs no comments read (got $(payload_reads))"
[ "$(requeues)" = 0 ] && ok || bad "C6: and gets no requeue (got $(requeues))"

# C6b — no merge-queue label: not ours to requeue, and not read.
setup "" $((NOW-600)) "$H2"
run_tick
[ "$(payload_reads)" = 0 ] && ok || bad "C6b: a PR without merge-queue costs no comments read (got $(payload_reads))"

# C8 — the comments read fails: nothing is done, and it is said.
setup merge-queue $((NOW-600)) "$H2"
echo x > "$T/cfail"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C8: an unreadable payload is never a requeue (got $(requeues))"
grep -q "$K31 stale-dequeue check: the Mergify payload could not be read" "$CLOG" && ok || bad "C8: and the log says why"

# C9 — the payload is not dequeued (Mergify is waiting on conditions): nothing.
setup merge-queue $((NOW-600)) "$H2"
printf '[%s]' "$(mcom waiting $((NOW-3700)) $((NOW-3600)) 100)" > "$T/mcomments.json"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C9: a waiting payload is not a dequeue (got $(requeues))"

# C7 — D2: the production call site is what does it. A scratch conductor with
#      the call removed leaves C1 unrequeued.
cp "$T/h/bin/merge-conductor.sh" "$T/mc.orig"
grep -qxF '    sdq_arm' "$T/h/bin/merge-conductor.sh" || bad "C7: the conductor has no '    sdq_arm' call line to remove"
grep -vxF '    sdq_arm' "$T/mc.orig" > "$T/h/bin/merge-conductor.sh"
# an `if … then fi` with an empty body is a syntax error; give it a no-op.
python3 - "$T/h/bin/merge-conductor.sh" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("command -v sdq_arm >/dev/null 2>&1; then\n  fi", "command -v sdq_arm >/dev/null 2>&1; then\n    :\n  fi")
open(p,"w").write(s)
PY
bash -n "$T/h/bin/merge-conductor.sh" || bad "C7: the mutated conductor does not parse"
setup merge-queue $((NOW-600)) "$H2"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "C7: with the call site deleted C1 still requeued — the suite is not pinning the conductor (got $(requeues))"
cp "$T/mc.orig" "$T/h/bin/merge-conductor.sh"

echo "merge-conductor-stale-dequeue.bh-3480: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
