#!/bin/bash
# tests/mc/needs-human-verdict.bh-3777-test.sh — a PR whose lead-verdict status
# BH-3683 withholds (la_decide rc 1: a protected path, or revoked lane
# authority) is NEEDS_HUMAN_VERDICT, never QUEUED, and gets no merge-queue label
# and no `@mergifyio queue` while it waits (BH-3777, acceptance).
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo (queue_rules in .mergify.yml) with a fake gh — the BH-2199 fixture
# (tests/conductor-gates.bh-2199-test.sh). bin/lib/verdict-status.sh is a stub
# in the scratch tree: its la_decide answers the rc and LA_REASON written to
# $T/la-rc and $T/la-reason and records every call, and la_human_needed /
# vs_publish record theirs. Every assertion reads the real label POSTs, the real
# `@mergifyio` comments, the real rows and the real conductor log / ALERTS.log.
#   N1  rc 1 -> READY -> NEEDS_HUMAN_VERDICT; zero label POSTs, zero asks; no
#       hand-off record; la_human_needed called once, lane merge-conductor
#   N2  the reason names the protected path and the exact human command with
#       the full head
#   N3  a human verdict lands (rc 0) -> NEEDS_HUMAN_VERDICT -> READY -> QUEUED,
#       exactly one label POST; a further tick posts none
#   N4  rc 2 keeps the BH-2199 hold: READY, no label, MERGE_HELD
#   N5  rc 0 "not governed" -> READY -> QUEUED as today; and on a repo with no
#       queue the gate never runs
#   N6  a QUEUED row is never gated (no la_decide call from the gate)
#   N7  past its TTL the STUCK page names the command, and the log never says
#       "the alert is the action" for it
# Run from anywhere: tests/mc/needs-human-verdict.bh-3777-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from list.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done
# Anything that shells out to the human verdict command is a test failure: the
# harness never posts a human verdict by itself (ticket, out of scope).
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lead-verdict-calls.txt"\nexit 0\n' "$T" > "$T/h/bin/lead-verdict.sh"; chmod +x "$T/h/bin/lead-verdict.sh"

# THE AUTHORITY STUB. The real bin/lib/verdict-status.sh is replaced by one that
# answers la_decide from two files, so a case flips the answer between ticks.
cat > "$T/h/bin/lib/verdict-status.sh" <<EOF
la_decide() {
  printf '%s\n' "\$*" >> "$T/la-calls.txt"
  LA_REASON=\$(cat "$T/la-reason" 2>/dev/null)
  return "\$(cat "$T/la-rc" 2>/dev/null || echo 0)"
}
la_human_needed() { printf '%s\n' "\$*" >> "$T/lhn-calls.txt"; return 0; }
vs_publish() { printf '%s\n' "\$*" >> "$T/vs-calls.txt"; return 0; }
vs_context() { echo lead-verdict; }
EOF

N=41
URL41="https://github.com/example-org/mgfy-os/pull/41"
HEAD41=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa41   # a full 40-hex head: the command must carry it whole
REC="$T/h/builds/pool-mgfy-MG-41-2026100100"
mkdir -p "$REC"
echo "PR_CREATED $URL41" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
printf '%s' "$HEAD41" > "$REC/reviewed-sha"
: > "$REC/pipeline.log"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')

open_list() {
  local csv lbl="[]"
  csv=$(tr '\n' ',' < "$T/labels-41" 2>/dev/null | sed 's/,$//')
  [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":41,"url":"%s","headRefOid":"%s","headRefName":"ticket/mg-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s}]\n' \
    "$URL41" "$HEAD41" "$lbl" > "$T/list.json"
}

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
N=41
HEAD=$HEAD41
LBL=\$(tr '\n' ',' < "$T/labels-41" 2>/dev/null | sed 's/,\$//')
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -n "\$Q" ]; then printf '%s' "\$1" | jq -r "\$Q"; else printf '%s\n' "\$1"; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*"/reviews"*) fx '[]' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*) fx '{"number":41,"base":{"ref":"main"}}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*)
    if [ -e "$T/nomergify" ]; then restpr --raw 404 '{"message":"Not Found"}'; else restpr --raw 200 '{"content":"$MGFY_YML"}'; fi ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-41"; sort -u -o "$T/labels-41" "$T/labels-41"
    [ "\$CHECK" = running ] && { printf 'queued\n' >> "$T/labels-41"; sort -u -o "$T/labels-41" "$T/labels-41"; } ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    grep -vxF 'merge-queue' "$T/labels-41" > "$T/labels-41.tmp" 2>/dev/null; mv -f "$T/labels-41.tmp" "$T/labels-41" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *v3.diff*) restpr --diff '+++ b/catalog/switches.d/x-off.json
+{}
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*) restpr OPEN "\$HEAD" "ticket/mg-41" main "\$LBL" MERGEABLE CLEAN operator ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed","number":41}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":41}' ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
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

KEY='example-org/mgfy-os#41'
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
A="$T/h/logs/ALERTS.log"
field() { awk -F'\t' -v k="$KEY" -v n="$1" '$1==k {print $n}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 MC_MERGIFY_REASK_TICKS=1 \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
clear_calls() {
  for f in gh-calls.txt merge-calls.txt label-adds.txt queue-cmds.txt la-calls.txt lhn-calls.txt vs-calls.txt lead-verdict-calls.txt; do : > "$T/$f"; done
  : > "$CLOG"; : > "$A"
}
la() { echo "$1" > "$T/la-rc"; printf '%s' "$2" > "$T/la-reason"; }
# reset <checkmode>: a fresh conductor state, no labels, and the row seeded
# READY with NO label — a seed tick whose la_decide is undecidable (rc 2) is the
# BH-2199 hold, which returns before the label POST.
reset() {
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"
  rm -f "$T/h/state/merge-sweep-done.txt" "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe "$T/nomergify" 2>/dev/null
  : > "$T/labels-41"; echo none > "$T/checkmode"; open_list
  la 2 "the files of example-org/mgfy-os#41 could not be read whole"
  clear_calls; run_tick
  echo "${1:-running}" > "$T/checkmode"; open_list; clear_calls
}
labels_posted() { grep -c -- "issues/41/labels" "$T/label-adds.txt" 2>/dev/null; }
asks_posted()   { grep -ci -- "@mergifyio" "$T/queue-cmds.txt" 2>/dev/null; }
gate_calls()    { grep -c -- "^example-org/mgfy-os 41 $HEAD41 conductor" "$T/la-calls.txt" 2>/dev/null; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
PROT="touches protected paths: catalog/switches.d/x-off.json"
CMD="bin/lead-verdict.sh post example-org/mgfy-os 41 $HEAD41 MERGE --source human"

# ── seed sanity: the row starts READY with no label ─────────────────────────
reset running
[ "$(field 2)" = READY ] && ok || bad "seed: the rc-2 tick must leave the row READY (got '$(field 2)'; log: $(tail -3 "$CLOG"))"
[ ! -s "$T/labels-41" ] && ok || bad "seed: the rc-2 tick must add no label (labels: $(cat "$T/labels-41"))"

# ── N1/N2: la_decide rc 1 ───────────────────────────────────────────────────
la 1 "$PROT"
run_tick
grep -qF "$KEY READY -> NEEDS_HUMAN_VERDICT" "$CLOG" && ok || bad "N1: the log must show READY -> NEEDS_HUMAN_VERDICT (log: $(grep -F '#41' "$CLOG" | tail -4))"
[ "$(field 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "N1: the row must be NEEDS_HUMAN_VERDICT, never QUEUED (got '$(field 2)')"
[ "$(labels_posted)" = 0 ] && ok || bad "N1: no merge-queue label while the verdict is withheld (POSTs: $(cat "$T/label-adds.txt"))"
[ "$(asks_posted)" = 0 ] && ok || bad "N1: no @mergifyio ask while the verdict is withheld (comments: $(cat "$T/queue-cmds.txt"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "N1: no merge of any kind (merge calls: $(cat "$T/merge-calls.txt"))"
[ ! -s "$T/vs-calls.txt" ] && ok || bad "N1: no lead-verdict status published (vs_publish: $(cat "$T/vs-calls.txt"))"
HO=$(find "$T/h/state" -path '*handoff*' -type f 2>/dev/null | head -3)
[ -z "$HO" ] && ok || bad "N1: blocked-resolver must not be handed this row (hand-off files: $HO)"
grep -q 'BLOCKED_HUMAN' "$ROWS" && bad "N1: the row is not BLOCKED_HUMAN: $(cat "$ROWS")" || ok
[ "$(grep -c 'merge-conductor$' "$T/lhn-calls.txt" 2>/dev/null)" = 1 ] && ok || bad "N1: la_human_needed is called once with lane merge-conductor (calls: $(cat "$T/lhn-calls.txt"))"
grep -qF "example-org/mgfy-os 41 $HEAD41 $PROT merge-conductor" "$T/lhn-calls.txt" && ok || bad "N1: la_human_needed gets the slug, PR, full head and LA_REASON (calls: $(cat "$T/lhn-calls.txt"))"
[ ! -s "$T/lead-verdict-calls.txt" ] && ok || bad "N1: the harness never posts a human verdict itself: $(cat "$T/lead-verdict-calls.txt")"
WHY=$(field 7)
grep -qF "catalog/switches.d/x-off.json" <<<"$WHY" && ok || bad "N2: the reason names the protected path (reason: '$WHY')"
grep -qF "$CMD" <<<"$WHY" && ok || bad "N2: the reason carries the exact command with the full head '$CMD' (reason: '$WHY')"
# A second withheld tick: still no label, still one state.
open_list; clear_calls; run_tick
[ "$(field 2)" = NEEDS_HUMAN_VERDICT ] && [ "$(labels_posted)" = 0 ] && [ "$(asks_posted)" = 0 ] && ok \
  || bad "N1: a second withheld tick stays NEEDS_HUMAN_VERDICT with no label/ask (state '$(field 2)', labels: $(cat "$T/label-adds.txt"))"

# ── N3: a human verdict lands on the head ───────────────────────────────────
la 0 "a human verdict stands on ${HEAD41:0:12}"
open_list; clear_calls; run_tick
grep -qF "$KEY NEEDS_HUMAN_VERDICT -> READY" "$CLOG" && ok || bad "N3: the next tick goes NEEDS_HUMAN_VERDICT -> READY (log: $(grep -F '#41' "$CLOG" | tail -4))"
grep -qF "$KEY READY -> QUEUED" "$CLOG" && ok || bad "N3: ...and READY -> QUEUED in the same tick (log: $(grep -F '#41' "$CLOG" | tail -4))"
[ "$(field 2)" = QUEUED ] && ok || bad "N3: the row is QUEUED (got '$(field 2)')"
[ "$(labels_posted)" = 1 ] && ok || bad "N3: exactly one label POST (POSTs: $(cat "$T/label-adds.txt"))"
[ ! -s "$T/lead-verdict-calls.txt" ] && ok || bad "N3: the harness never posts a human verdict itself"
# ── N6: a QUEUED row is not gated ───────────────────────────────────────────
open_list; clear_calls; run_tick
[ "$(field 2)" = QUEUED ] && ok || bad "N6: the row stays QUEUED (got '$(field 2)')"
[ "$(labels_posted)" = 0 ] && ok || bad "N3: a further tick posts no further label (POSTs: $(cat "$T/label-adds.txt"))"
[ "$(gate_calls)" = 0 ] && ok || bad "N6: a QUEUED row costs no la_decide call (calls: $(cat "$T/la-calls.txt"))"

# ── N4: rc 2 keeps the BH-2199 hold ─────────────────────────────────────────
reset running
la 2 "the files of example-org/mgfy-os#41 could not be read whole"
run_tick
[ "$(field 2)" = READY ] && ok || bad "N4: an undecidable authority keeps the row READY (got '$(field 2)')"
[ "$(labels_posted)" = 0 ] && ok || bad "N4: no label on an undecidable authority (POSTs: $(cat "$T/label-adds.txt"))"
grep -qF "$KEY MERGE_HELD" "$CLOG" && ok || bad "N4: the hold is logged MERGE_HELD (log: $(grep -F '#41' "$CLOG" | tail -3))"
grep -qF "lead authority could not be decided" "$CLOG" && ok || bad "N4: the hold names the undecidable authority (log: $(grep -F '#41' "$CLOG" | tail -3))"
grep -q NEEDS_HUMAN_VERDICT "$CLOG" "$ROWS" && bad "N4: rc 2 is never reported as a withheld verdict: $(grep NEEDS_HUMAN_VERDICT "$CLOG" "$ROWS")" || ok
[ ! -s "$T/lhn-calls.txt" ] && ok || bad "N4: rc 2 asks no human (la_human_needed: $(cat "$T/lhn-calls.txt"))"

# ── N5: not governed -> today's path; no queue -> no gate ───────────────────
reset running
la 0 "not governed"
run_tick
grep -qF "$KEY READY -> QUEUED" "$CLOG" && ok || bad "N5: an ungoverned repo enqueues as today (log: $(grep -F '#41' "$CLOG" | tail -3))"
[ "$(labels_posted)" = 1 ] && ok || bad "N5: one label POST as today (POSTs: $(cat "$T/label-adds.txt"))"
grep -q NEEDS_HUMAN_VERDICT "$CLOG" "$ROWS" && bad "N5: no NEEDS_HUMAN_VERDICT on rc 0" || ok
# No merge queue on the repo: the gate is not run at all.
reset running
touch "$T/nomergify"; rm -f "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
la 1 "$PROT"
open_list; clear_calls; run_tick
[ "$(gate_calls)" = 0 ] && ok || bad "N5: a repo without a Mergify queue runs no gate (la_decide calls: $(cat "$T/la-calls.txt"); log: $(grep -F '#41' "$CLOG" | tail -3))"
grep -q NEEDS_HUMAN_VERDICT "$CLOG" "$ROWS" && bad "N5: no NEEDS_HUMAN_VERDICT without a Mergify queue: $(grep NEEDS_HUMAN_VERDICT "$CLOG")" || ok
rm -f "$T/nomergify"

# ── N7: the STUCK page names the command ────────────────────────────────────
reset running
la 1 "$PROT"
run_tick
[ "$(field 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "N7 setup: the row is NEEDS_HUMAN_VERDICT (got '$(field 2)')"
OLD=$(( $(date +%s) - 3601 ))
awk -F'\t' -v OFS='\t' -v k="$KEY" -v s="$OLD" '$1==k {$3=s} {print}' "$ROWS" > "$ROWS.tmp" && mv -f "$ROWS.tmp" "$ROWS"
open_list; clear_calls; run_tick
[ "$(grep -c 'STUCK' "$A")" = 1 ] && ok || bad "N7: one STUCK page past the default TTL (ALERTS: $(cat "$A"))"
grep 'STUCK' "$A" | grep -qF -- "--source human" && ok || bad "N7: the STUCK page names the human command (ALERTS: $(cat "$A"))"
grep -q 'the alert is the action' <<<"$(grep -F "$KEY" "$CLOG")" && bad "N7: the log must not say 'the alert is the action' for this state: $(grep -F 'the alert is the action' "$CLOG")" || ok
grep -F "$KEY" "$CLOG" | grep -q 'stuck in NEEDS_HUMAN_VERDICT past its TTL' && ok || bad "N7: the re-kick line says only a human verdict moves it (log: $(grep -F '#41' "$CLOG" | tail -3))"
[ "$(labels_posted)" = 0 ] && ok || bad "N7: still no label (POSTs: $(cat "$T/label-adds.txt"))"

echo "needs-human-verdict.bh-3777-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
