#!/bin/bash
# tests/conductor-gates.bh-2275-test.sh — the #2199 follow-ups (BH-2275,
# acceptance): a lead CHANGES_REQUESTED on a PR already in the Mergify queue
# takes it OUT of the queue, once; and an unreadable .mergify.yml probe holds.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo (queue_rules in .mergify.yml) with a fake gh. Every assertion reads the
# real `gh pr merge` calls, the real label adds (the queue ask), the real rows
# and the real conductor log / ALERTS.log.
#   D1  a lead CR lands on a QUEUED PR: our label comes off and ONE
#       `@mergifyio dequeue` is posted; the row leaves QUEUED; a second tick
#       posts nothing more
#   D2  a HELD READY PR (label on, queue silent) gets a lead CR: the same one
#       dequeue, and the block gate still refuses it
#   D3  no CR: a QUEUED PR is left alone (no dequeue)
#   D4  the CR clears: the PR is re-queued once, reaches QUEUED, and settles
#       MERGED when Mergify merges it
#   (the fixture's Mergify stamps `dequeued` on a dequeue, as the real one does,
#   and D1/D2 assert the BH-636 re-entry never requeues over the lead CR)
#   U1  last-known-good (option B): a 200 records the provider in the settings
#       table once; a 502 on a KNOWN-mergify repo holds (no PUT /merge, no
#       direct merge, no rewrite) with ONE alert; with no record a 502 reads as
#       `none` and the conductor log names that window; a 404 records `none`;
#       U1e a 502 with the worker DOWN and no cache is `unknown` and holds
# Run from anywhere: tests/conductor-gates.bh-2275-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from list.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
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
# The block gate rides with the conductor lib in production. verdicts.sh stays
# out, as in tests/conductor-block-gate-test.sh: its worker read would answer
# "unreadable" in this fixture and hold every merge.
cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
MSHA=cccccccc3333
head_of() { printf 'aaaaaaaa00%s' "$1"; }
BLOCKED=dddddddd0041   # the head the lead's review was left on (G1)

for N in 41 42; do
  REC="$T/h/builds/pool-mgfy-MG-$N-2026091700$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')

labels_csv() { tr '\n' ',' < "$T/labels-$1" 2>/dev/null | sed 's/,$//'; }
open_list() {
  local n out="" lbl csv
  for n in ${OPEN_PRS:-41 42}; do
    [ "$(cat "$T/prstate-$n" 2>/dev/null)" = open ] || continue
    csv=$(labels_csv "$n"); lbl="[]"
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":$lbl},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

# The gh stub. The reads BH-2199 adds (reviews with their STATE, the PR's base,
# the three-dot compare) answer through the -q program the lib passes, from
# JSON fixtures, the way `gh api … -q` would.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
N=\$(printf '%s' "\$*" | sed -nE 's#.*(/pull/|/pulls/|/issues/)([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=41
PRSTATE=\$(cat "$T/prstate-\$N" 2>/dev/null || echo open)
HEAD=aaaaaaaa00\$N
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -f "\$1" ]; then if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi; else echo "HTTP 404: Not Found" >&2; exit 1; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*"/reviews"*)
    f="$T/reviews-\$N.json"; [ -f "\$f" ] || f="$T/no-reviews.json"; fx "\$f" ;;
  "api -X GET repos/example-org/mgfy-os/compare/"*)
    sha=\$(printf '%s' "\$*" | sed -nE 's#.*compare/[^ ]*\.\.\.([0-9a-f]+).*#\1#p'); fx "$T/compare-\$sha.json" ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*) fx "$T/pull-base.json" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*)
    case "\$(cat "$T/mgfy-mode" 2>/dev/null || echo ok)" in
      502) restpr --raw 502 '{"message":"Server Error"}' ;;
      404) restpr --raw 404 '{"message":"Not Found"}' ;;
      *)   restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
    esac ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt"
    # Mergify answers a dequeue as the real one does: its own queued label goes
    # and its default \`dequeued\` label goes ON (review of #2277) — the label
    # that arms the conductor's BH-636 re-entry.
    case "\$*" in *"@mergifyio dequeue"*) { grep -vxF queued "$T/labels-\$N"; echo dequeued; } > "$T/labels-\$N.tmp" 2>/dev/null; sort -u -o "$T/labels-\$N" "$T/labels-\$N.tmp" ;; esac ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/dequeued"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF dequeued "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"
    [ "\$CHECK" = running ] && { printf 'queued\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"; } ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate-\$N"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/pr-comments.txt" ;;
  *v3.diff*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    case "\$PRSTATE" in
      merged) restpr MERGED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator "$MSHA" ;;
      *)      restpr OPEN   "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
    esac ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed","number":'"\$N"'}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":'"\$N"'}' ;;
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
# The jobs worker, as far as BH-2275's last-known-good provider needs it: the
# settings table, one file per key under $T/settings/, and every PUT logged.
mkdir -p "$T/settings"
cat > "$T/fakebin/curl" <<CURL
#!/bin/bash
URL="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$BODY" in @*) BODY=\$(cat "\${BODY#@}") ;; esac
# \$T/worker-down: the settings routes answer 503 (the worker is configured but
# not answering) — review r2 of #2277.
if [ -f "$T/worker-down" ]; then case "\$URL" in */api/settings*) printf '{"error":"unavailable"}\n503\n'; exit 0 ;; esac; fi
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "PUT "*/api/settings)
    k=\$(jq -r .key <<<"\$BODY"); v=\$(jq -r .value <<<"\$BODY")
    printf '%s' "\$v" > "$T/settings/\$k"; printf '%s %s\n' "\$k" "\$v" >> "$T/setting-puts.txt"
    jq -nc --arg k "\$k" --arg v "\$v" '{setting:{key:\$k,value:\$v}}'; printf '200\n' ;;
  "GET "*/api/settings/*)
    k="\${URL##*/}"
    if [ -f "$T/settings/\$k" ]; then jq -nc --arg k "\$k" --arg v "\$(cat "$T/settings/\$k")" '{setting:{key:\$k,value:\$v}}'; printf '200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"
echo '[]' > "$T/no-reviews.json"
echo '{"number":41,"base":{"ref":"main"}}' > "$T/pull-base.json"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
A="$T/h/logs/ALERTS.log"
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.example.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
reset_fixture() { # reset_fixture <checkmode>
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"
  rm -f "$T/h/state/merge-sweep-done.txt" "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  rm -f "$T"/reviews-*.json "$T"/compare-*.json 2>/dev/null
  for N in 41 42; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
  for f in gh-calls.txt merge-calls.txt label-adds.txt label-removes.txt queue-cmds.txt pr-comments.txt; do : > "$T/$f"; done
  : > "$A"; : > "$CLOG"
  echo "${1:-running}" > "$T/checkmode"; echo ok > "$T/mgfy-mode"
  open_list
}
lead_cr() { # lead_cr <pr> <commit> — the lead's CHANGES_REQUESTED, `## BLOCKING` and no BLOCK marker (#2158's shape)
  jq -nc --arg c "$2" --arg n "$1" '[{id:5308896759, user:{login:"operator", type:"User"}, author_association:"OWNER",
     state:"CHANGES_REQUESTED", commit_id:$c, submitted_at:"2026-09-24T19:03:16Z",
     html_url:("https://github.com/example-org/mgfy-os/pull/"+$n+"#pullrequestreview-5308896759"),
     body:"# Review\n\n## BLOCKING\n\nthe split-brain guard is missing"}]' > "$T/reviews-$1.json"
}
own_diff() { # own_diff <sha> <patch> — the PR's own diff at that head (compare main...<sha>)
  jq -nc --arg p "$2" '{files:[{filename:"src/x.ts", status:"modified", changes:2, sha:"1111", patch:$p}]}' > "$T/compare-$1.json"
}
merges_of() { grep -c -- "/pull/$1\b" "$T/merge-calls.txt" 2>/dev/null; }
asks_of()   { grep -c -- "issues/$1/labels" "$T/label-adds.txt" 2>/dev/null; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

queued_row() { # queued_row <pr> — the conductor's own QUEUED row, label on, as a witnessed enqueue leaves it
  printf 'merge-queue\nqueued\n' > "$T/labels-$1"
  mkdir -p "$T/h/state/merge-conductor"
  printf 'example-org/mgfy-os#%s\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/mgfy-os/pull/%s\n' \
    "$1" 1790000000 "$(head_of "$1")" "$(head_of "$1")" "$(head_of "$1" | cut -c1-8)" "$1" >> "$ROWS"
}
dequeues_of() { grep -c -- "issues/$1/comments.*@mergifyio dequeue" "$T/queue-cmds.txt" 2>/dev/null; }
requeues_of() { grep -c -- "issues/$1/comments.*@mergifyio requeue" "$T/queue-cmds.txt" 2>/dev/null; }
removes_of()  { grep -c -- "issues/$1/labels/merge-queue" "$T/label-removes.txt" 2>/dev/null; }

# ── D1: a lead CR on a QUEUED PR ─────────────────────────────────────────────
reset_fixture running
queued_row 41
lead_cr 41 "$(head_of 41)"
open_list; MC_PR_PARALLEL=1 run_tick
[ "$(dequeues_of 41)" = 1 ] && ok || bad "D1: a lead CR on a queued PR must post ONE @mergifyio dequeue (got $(dequeues_of 41): $(cat "$T/queue-cmds.txt"))"
[ "$(removes_of 41)" -ge 1 ] && ok || bad "D1: our merge-queue label must come off (removes: $(cat "$T/label-removes.txt"))"
grep -q 'example-org/mgfy-os#41 CR_DEQUEUED' "$CLOG" && ok || bad "D1: the log must say CR_DEQUEUED (log: $(grep -F '#41' "$CLOG" | tail -3))"
grep -q 'CHANGES_REQUESTED' <<<"$(grep -F '#41 CR_DEQUEUED' "$CLOG")" && ok || bad "D1: the dequeue line must name the standing CHANGES_REQUESTED"
[ "$(state_of 'example-org/mgfy-os#41')" != QUEUED ] && ok || bad "D1: the row must leave QUEUED (got '$(state_of 'example-org/mgfy-os#41')')"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "D1: nothing merges (merge calls: $(cat "$T/merge-calls.txt"))"
grep -qx dequeued "$T/labels-41" && ok || bad "D1 setup: the fixture's Mergify must stamp its dequeued label (labels: $(cat "$T/labels-41"))"
[ "$(requeues_of 41)" = 0 ] && ok || bad "D1: the BH-636 re-entry must not requeue a PR it just took out for a lead CR (cmds: $(cat "$T/queue-cmds.txt"))"
# A second tick with the CR still standing and Mergify's dequeued label on:
# no second dequeue, no requeue, no label add (review of #2277).
: > "$T/label-adds.txt"; open_list; MC_PR_PARALLEL=1 run_tick
[ "$(dequeues_of 41)" = 1 ] && ok || bad "D1: the dequeue is posted ONCE per (PR, head) (got $(dequeues_of 41))"
[ "$(requeues_of 41)" = 0 ] && ok || bad "D1: no @mergifyio requeue while the lead CR stands (cmds: $(cat "$T/queue-cmds.txt"))"
[ "$(asks_of 41)" = 0 ] && ok || bad "D1: a lead-blocked PR is not put back in the queue (asks: $(cat "$T/label-adds.txt"))"
grep -q 'example-org/mgfy-os#41 REQUEUED' "$CLOG" && bad "D1: the log must not say REQUEUED: $(grep 'REQUEUED' "$CLOG")" || ok
[ "$(state_of 'example-org/mgfy-os#41')" != QUEUED ] && ok || bad "D1: the row must not be back in QUEUED (got QUEUED)"

# ── D4: the CR clears — the PR goes back in, and settles when Mergify merges it ──
# The lead approves on the same head. The dequeued label is still on, so the
# BH-636 re-entry is what puts it back: dequeued off, merge-queue on,
# @mergifyio requeue, QUEUED. Then Mergify merges it and the row settles.
jq -c '. + [{id:5308896760, user:{login:"operator", type:"User"}, author_association:"OWNER",
   state:"APPROVED", commit_id:"'"$(head_of 41)"'", submitted_at:"2026-09-24T20:03:16Z",
   html_url:"https://github.com/example-org/mgfy-os/pull/41#pullrequestreview-5308896760", body:"fixed"}]' \
   "$T/reviews-41.json" > "$T/reviews-41.tmp" && mv -f "$T/reviews-41.tmp" "$T/reviews-41.json"
open_list; MC_PR_PARALLEL=1 run_tick
[ "$(requeues_of 41)" = 1 ] && ok || bad "D4: once the CR clears the PR is re-queued, once (cmds: $(cat "$T/queue-cmds.txt"); log: $(grep -F '#41' "$CLOG" | tail -3))"
[ "$(state_of 'example-org/mgfy-os#41')" = QUEUED ] && ok || bad "D4: the re-queued row must reach QUEUED (got '$(state_of 'example-org/mgfy-os#41')')"
grep -qx dequeued "$T/labels-41" && bad "D4: the requeue must take Mergify's dequeued label off (labels: $(cat "$T/labels-41"))" || ok
echo merged > "$T/prstate-41"; open_list; MC_PR_PARALLEL=1 run_tick
[ "$(state_of 'example-org/mgfy-os#41')" = MERGED ] && ok || bad "D4: when Mergify merges it the row settles MERGED (got '$(state_of 'example-org/mgfy-os#41')')"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "D4: the queue merged it, never the conductor (merge calls: $(cat "$T/merge-calls.txt"))"

# ── D2: a HELD READY PR (label on) gets a lead CR ───────────────────────────
reset_fixture none
OPEN_PRS=41 open_list; MC_PR_PARALLEL=1 run_tick     # the silent queue holds it READY, label on
[ "$(state_of 'example-org/mgfy-os#41')" = READY ] && grep -qx 'merge-queue' "$T/labels-41" && ok \
  || bad "D2 setup: PR 41 must be held READY with our label on (state '$(state_of 'example-org/mgfy-os#41')', labels $(cat "$T/labels-41"))"
lead_cr 41 "$(head_of 41)"
OPEN_PRS=41 open_list; MC_PR_PARALLEL=1 run_tick
[ "$(dequeues_of 41)" = 1 ] && ok || bad "D2: a held PR that gets a lead CR is dequeued once (got $(dequeues_of 41): $(cat "$T/queue-cmds.txt"))"
[ "$(removes_of 41)" -ge 1 ] && ok || bad "D2: its label comes off (removes: $(cat "$T/label-removes.txt"))"
grep -q 'example-org/mgfy-os#41 MERGE_REFUSED block-gate: standing CHANGES_REQUESTED' "$CLOG" && ok || bad "D2: the block gate still refuses it"
OPEN_PRS=41 open_list; MC_PR_PARALLEL=1 run_tick
[ "$(dequeues_of 41)" = 1 ] && ok || bad "D2: still ONE dequeue after another tick (got $(dequeues_of 41))"
[ "$(requeues_of 41)" = 0 ] && ok || bad "D2: no @mergifyio requeue while the lead CR stands (cmds: $(cat "$T/queue-cmds.txt"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "D2: nothing merges (merge calls: $(cat "$T/merge-calls.txt"))"

# ── D3: no CR, a QUEUED PR is left alone ────────────────────────────────────
reset_fixture running
queued_row 42
open_list; MC_PR_PARALLEL=1 run_tick
[ "$(dequeues_of 42)" = 0 ] && ok || bad "D3: a queued PR with no CR must not be dequeued (got: $(cat "$T/queue-cmds.txt"))"
[ "$(state_of 'example-org/mgfy-os#42')" = QUEUED ] && ok || bad "D3: it stays QUEUED (got '$(state_of 'example-org/mgfy-os#42')')"

# ── U1: an unreadable .mergify.yml probe answers the LAST-KNOWN-GOOD provider ──
# (the lead's option B, a deliberate deviation from #2275 item 2's "unknown").
KEYN=mc.queue_provider.example-org.mgfy-os
puts_of() { local n; n=$(grep -c -- "^$KEYN $1\$" "$T/setting-puts.txt" 2>/dev/null); echo "${n:-0}"; }
# Only the provider key: the conductor publishes its own rows (merge-conductor.*) too.
key_puts() { local n; n=$(grep -c -- "^$KEYN " "$T/setting-puts.txt" 2>/dev/null); echo "${n:-0}"; }
# U1a: a real read (200) records `mergify` in the settings table, once.
reset_fixture none; rm -f "$T/settings/$KEYN" "$T/setting-puts.txt" "$T/h/tmp"/*.provider*
run_tick
[ "$(cat "$T/settings/$KEYN" 2>/dev/null)" = mergify ] && ok || bad "U1a: a 200 must record mergify as $KEYN (settings: $(ls "$T/settings"))"
[ "$(puts_of mergify)" = 1 ] && ok || bad "U1a: one PUT for the read (puts: $(cat "$T/setting-puts.txt" 2>/dev/null))"
open_list; run_tick
[ "$(puts_of mergify)" = 1 ] && ok || bad "U1a: an unchanged answer is not written again (puts: $(cat "$T/setting-puts.txt" 2>/dev/null))"
# U1b: a KNOWN-mergify repo whose probe answers 502 holds: no PUT /merge, no
# direct merge, no rewrite of the record, ONE alert a day naming the fallback.
reset_fixture none; echo 502 > "$T/mgfy-mode"; : > "$T/setting-puts.txt"
rm -f "$T/h/tmp"/*.provider "$T/h/tmp"/*.provider.recorded   # the DB row, not this box's cache, answers
run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "U1b: a known-mergify repo with a 5xx probe must never be merged directly (merge calls: $(cat "$T/merge-calls.txt"))"
grep -qE '(-X PUT|pr merge)' "$T/gh-calls.txt" && bad "U1b: no PUT /merge of any kind: $(grep -E '(-X PUT|pr merge)' "$T/gh-calls.txt")" || ok
for N in 41 42; do
  grep -q "example-org/mgfy-os#$N MERGE_HELD" "$CLOG" && ok || bad "U1b: PR $N is held through the Mergify path (log: $(grep -F "#$N" "$CLOG" | tail -2))"
done
[ "$(key_puts)" = 0 ] && ok || bad "U1b: an unreadable probe is never recorded (puts: $(cat "$T/setting-puts.txt"))"
[ "$(grep -c "probe failed for example-org/mgfy-os.*last-known provider 'mergify'" "$A")" = 1 ] && ok || bad "U1b: ONE alert naming the probe failure and the last-known provider (ALERTS: $(cat "$A"))"
open_list; run_tick
[ "$(grep -c 'probe failed for example-org/mgfy-os' "$A")" = 1 ] && ok || bad "U1b: a second failed tick the same day does not page again (ALERTS: $(cat "$A"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "U1b: still no direct merge on the second tick"
# U1c: THE REMAINING WINDOW, stated: a repo with NO record anywhere reads as
# `none` on a failed probe, and the alert says exactly that.
reset_fixture none; echo 502 > "$T/mgfy-mode"; : > "$T/setting-puts.txt"
rm -f "$T/settings/$KEYN" "$T/h/tmp"/*.provider*
OPEN_PRS=41 open_list; MC_PR_PARALLEL=1 run_tick
grep -q "example-org/mgfy-os merge-queue provider probe failed and this repo has no last-known provider record.*'none'" "$CLOG" && ok || bad "U1c: the conductor log must name the never-read window (log: $(grep -i 'probe' "$CLOG" | tail -2))"
grep -q 'probe failed' "$A" && bad "U1c: the never-read window is a log line, not a page (it is the pre-BH-2275 answer): $(grep 'probe failed' "$A")" || ok
[ "$(key_puts)" = 0 ] && ok || bad "U1c: an unreadable probe is never recorded, not even as none (puts: $(cat "$T/setting-puts.txt"))"
# U1d: a GENUINE 404 is a real read: `none` is recorded.
reset_fixture none; echo 404 > "$T/mgfy-mode"; : > "$T/setting-puts.txt"
rm -f "$T/settings/$KEYN" "$T/h/tmp"/*.provider*
run_tick
[ "$(cat "$T/settings/$KEYN" 2>/dev/null)" = none ] && ok || bad "U1d: a genuine 404 records none (settings: $(cat "$T/settings/$KEYN" 2>/dev/null))"
grep -q 'probe failed' "$A" && bad "U1d: a 404 is an answer, not a failure: $(grep 'probe failed' "$A")" || ok

# U1e (review r2 of #2277): the probe answers 502 AND the worker is down, on a
# box with NO cache file (fresh, rebuilt, or the MERGIFY.md §4 fast path just
# deleted it) — a repo the worker HAS recorded as mergify. That is `unknown`,
# never `none`: nothing merges around the queue.
reset_fixture none; echo 502 > "$T/mgfy-mode"; : > "$T/setting-puts.txt"
printf 'mergify' > "$T/settings/$KEYN"; touch "$T/worker-down"
rm -f "$T/h/tmp"/*.provider*
run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "U1e: a failed probe with the worker down and no cache must never merge directly (merge calls: $(cat "$T/merge-calls.txt"))"
grep -qE '(-X PUT|pr merge)' "$T/gh-calls.txt" && bad "U1e: no PUT /merge of any kind: $(grep -E '(-X PUT|pr merge)' "$T/gh-calls.txt")" || ok
grep -q 'merge-queue provider UNKNOWN' "$CLOG" && ok || bad "U1e: the conductor must hold the tick as provider UNKNOWN (log: $(grep -iE 'provider|probe' "$CLOG" | tail -3))"
grep -q "no last-known provider record" "$CLOG" && bad "U1e: a worker outage is not a genuine no-row: $(grep 'no last-known' "$CLOG")" || ok
[ "$(grep -c 'provider probe failed for example-org/mgfy-os' "$A")" = 1 ] && ok || bad "U1e: one alert for the unknown hold (ALERTS: $(cat "$A"))"
rm -f "$T/worker-down"

echo "conductor-gates.bh-2275-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
