#!/bin/bash
# tests/lead-review-queue.bh-5151-test.sh — BH-5151: the lead-review lane reads
# the WHOLE request queue, orders it hotfix > priority > oldest, supersedes dead
# rows before any budget is spent, and stops the tick on a worker 503 instead of
# skipping every remaining row. Runs bin/lead-review.sh tick WHOLE against a
# scratch harness (its real bin/lib closure), with only these stubbed:
#   * curl — the jobs worker. GET /api/lead-reviews pages $T/rows.json exactly
#            as the real route does (ORDER BY created_at, rowid; 100 a page;
#            `after=<created_at>,<rowid>` -> rows past it; `next_after` on a
#            truncated page). $T/oldworker ignores `after` and sends no
#            next_after; $T/page2fail answers 500 to any page past the first;
#            $T/jobs503 / $T/claim503 answer 503 to job_open / the claim.
#   * gh   — the open-PR list (repos/<slug>/pulls?state=open) from $T/open.json,
#            $T/openfail = exit 1; a PR read (pulls/<n>) from $T/pr/<n>.json,
#            else an open PR at $SHA.
#   * bin/agent-call.sh — counts calls and records the PR each names.
# The PR repo is real git: one origin with refs/pull/<n>/head for every PR.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-queue.bh-5151-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/pr"
cp "$DIR/bin/lead-review.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
# jobs-client.sh exits on a missing module: the closure must have brought them.
[ -r "$H/bin/lib/jobs/req.sh" ] || { echo "the closure did not install bin/lib/jobs/*.sh"; exit 1; }
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
demo-os   example-org/demo-os   https://demo.test  /api/board 1 box-demo
other-os  example-org/other-os  https://other.test /api/board 3 box-other
EOF

# ── git: origin with main + one PR commit published at refs/pull/<n>/head ──
O="$T/origin/demo-os.git"; W="$T/work/demo-os"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\n## Verification Contract\n\n```bash\nexit 0\n```\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
SHA=$(git -C "$W" rev-parse HEAD)
for n in 11 12 13 21 22 23 31 32 33 34 35 36 37 41 42 43 44 45; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"
OLD=$(printf 'c%.0s' {1..40})

# ── the stub worker ──
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*)
    q=""; case "\$p" in *\?*) q="\${p#*\?}" ;; esac
    after=""
    case "&\$q" in *"&after="*) after="\${q#*after=}"; after="\${after%%&*}"; after=\$(printf '%b' "\${after//%/\\\\x}") ;; esac
    old=0; [ -e "$T/oldworker" ] && { old=1; after=""; }
    if [ -e "$T/page2fail" ] && [ -n "\$after" ]; then code=500; out='{"error":"boom"}'
    else
      out=\$(jq -c --arg a "\$after" --argjson old "\$old" '
        (sort_by(.created_at, .seq)) as \$all
        | (if \$a == "" then \$all
           else (\$a | capture("^(?<c>.*),(?<s>[0-9]+)\$")) as \$k
             | [\$all[] | select(.created_at > \$k.c or (.created_at == \$k.c and .seq > (\$k.s | tonumber)))] end) as \$rest
        | \$rest[:100] as \$pg
        | {requests: [\$pg[] | del(.seq)], truncated: ((\$rest | length) > 100)}
          + (if (\$rest | length) > 100 and \$old == 0 then {next_after: "\(\$pg[-1].created_at),\(\$pg[-1].seq)"} else {} end)' "$T/rows.json")
    fi ;;
  "POST /api/jobs")
    if [ -e "$T/jobs503" ]; then code=503; out='{"error":"jobs unavailable","detail":"D1_ERROR: overloaded"}'
    else k=\$(printf '%s' "\$body" | jq -r '.ticket_id'); out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}'); fi ;;
  "POST /api/lead-reviews/"*/claim)
    [ -e "$T/claim503" ] && { code=503; out='{"error":"lead_review_requests unavailable","detail":"D1_ERROR: overloaded"}'; } ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  [ -e "$T/openfail" ] && exit 1
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then cat "$T/open.json"; else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  n="\${BASH_REMATCH[1]}"
  printf 'HTTP/2 200\r\n\r\n'
  if [ -f "$T/pr/\$n.json" ]; then cat "$T/pr/\$n.json"
  else jq -nc --arg s "$SHA" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}'; fi
  exit 0
fi
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${AGENT_CALL_PR##*/}" >> "$T/log/agent-prs"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE

# row <id> <repo> <pr> <sha> <created_at> <seq> [priority] -> one stored row
row() {
  jq -nc --arg i "$1" --arg r "$2" --argjson p "$3" --arg s "$4" --arg c "$5" --argjson q "$6" --arg pri "${7:-}" \
    '{id:$i,repo:$r,pr:$p,head_sha:$s,status:"requested",created_at:$c,seq:$q,scope_notes:null}
     + (if $pri == "" then {} else {priority:($pri|tonumber)} end)'
}
setrows() { printf '%s\n' "$@" | jq -sc . > "$T/rows.json"; }
# foreign <n> <first-seq> -> n rows for other-os over 50 PRs, three timestamps
foreign() {
  jq -nc --argjson n "$1" --argjson f "$2" --arg s "$OLD" \
    '[range(0; $n) | {id:"f-\(.)",repo:"example-org/other-os",pr:(1000 + (. % 50)),head_sha:$s,status:"requested",
       created_at:(["2026-10-07 05:00:00","2026-10-07 06:00:00","2026-10-07 07:00:00"][. % 3]),seq:($f + .),scope_notes:null}]'
}
# open <pr>:<sha>[:<label>] ... -> $T/open.json, the REST open-PR list of demo-os
open_prs() {
  local a out='[]' n s l
  for a in "$@"; do
    IFS=: read -r n s l <<<"$a"
    out=$(jq -c --argjson n "$n" --arg s "$s" --arg l "$l" \
      '. + [{number:$n,head:{sha:$s},labels:(if $l == "" then [] else [{name:$l}] end)}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$T/open.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{oldworker,page2fail,jobs503,claim503,openfail} "$T/pr"/*.json "$H/logs/lead-review.log"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
  [ -f "$H/bin/lib/pr-snapshot.sh.off" ] && mv "$H/bin/lib/pr-snapshot.sh.off" "$H/bin/lib/pr-snapshot.sh"
  echo '[]' > "$T/open.json"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
L="$H/logs/lead-review.log"
summary() { grep ' tick seen=' "$L" 2>/dev/null | tail -1; }
cnt() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
lgets() { cnt '^GET /api/lead-reviews' "$T/log/worker"; }
agents() { cnt . "$T/log/agent-prs"; }
claims() { cnt '^POST /api/lead-reviews/.*/claim' "$T/log/worker"; }
sups() { cnt '^POST /api/lead-reviews/.*/result .*"outcome":"superseded"' "$T/log/worker"; }
# corder — the request ids in claim order. Claims are made one at a time in
# queue order (the pool's gate), so this IS the order the tick works the queue.
# BH-4956 removed the per-tick start cap: every owned row is reviewed in one
# tick, and the order cases below read this instead of "only the first ran".
corder() { grep -o '^POST /api/lead-reviews/[^/ ]*/claim' "$T/log/worker" 2>/dev/null | cut -d/ -f4 | paste -sd' ' -; }

# (a) 250 rows (3 owned, 247 another box's): the lane reads all 250 over 3 pages
reset
setrows "$(row a-1 example-org/demo-os 11 "$SHA" '2026-10-07 04:00:00' 0)" \
        "$(row a-2 example-org/demo-os 12 "$SHA" '2026-10-07 04:00:01' 1)" \
        "$(row a-3 example-org/demo-os 13 "$SHA" '2026-10-07 04:00:02' 2)"
jq -sc '.[0] + .[1]' "$T/rows.json" <(foreign 247 3) > "$T/rows.tmp" && mv "$T/rows.tmp" "$T/rows.json"
open_prs "11:$SHA" "12:$SHA" "13:$SHA"
tick
[ "$RC" -eq 0 ] && ok || bad "a rc=$RC $(cat "$T/out")"
[ "$(lgets)" = 3 ] && ok || bad "a list GETs=$(lgets) (want 3)"
[ "$(grep '^GET /api/lead-reviews' "$T/log/worker" | sed -n '2,3p' | grep -c 'after=')" = 2 ] && ok || bad "a pages 2-3 carry no after=: $(grep '^GET /api/lead-reviews' "$T/log/worker")"
S=$(summary)
[[ "$S" == *" tick seen=250 owned=3 "* ]] && ok || bad "a summary seen/owned: $S"
[[ "$S" == *" total=250 prs=53" ]] && ok || bad "a summary total/prs: $S"
grep -qE 'truncated|drain' "$L" && bad "a a truncated/drain line: $(grep -E 'truncated|drain' "$L")" || ok
[ "$(agents)" = 3 ] && [ "$(corder)" = "a-1 a-2 a-3" ] && ok || bad "a claims '$(corder)', agents $(agents) (want a-1 a-2 a-3: oldest first)"

# (b1) hotfix first: the newest row's PR carries `hotfix`
B_ROWS=("$(row b-21 example-org/demo-os 21 "$SHA" '2026-10-07 05:00:00' 0)"
        "$(row b-22 example-org/demo-os 22 "$SHA" '2026-10-07 06:00:00' 1 5)"
        "$(row b-23 example-org/demo-os 23 "$SHA" '2026-10-07 07:00:00' 2)")
reset; setrows "${B_ROWS[@]}"; open_prs "21:$SHA" "22:$SHA" "23:$SHA:Hotfix"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(claims)" = 3 ] && [ "$(corder)" = "b-23 b-22 b-21" ] && ok || bad "b1 claims: $(grep claim "$T/log/worker")"
[ "$(agents)" = 3 ] && ok || bad "b1 reviewed '$(cat "$T/log/agent-prs" 2>/dev/null)' (want all 3)"
# (b2) no hotfix: the priority row beats the older unprioritised one
reset; setrows "${B_ROWS[@]}"; open_prs "21:$SHA" "22:$SHA" "23:$SHA"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(corder)" = "b-22 b-21 b-23" ] && ok || bad "b2 claims '$(corder)' (want b-22 b-21 b-23)"
# (b3) a look-alike label is not hotfix
reset; setrows "${B_ROWS[@]}"; open_prs "21:$SHA" "22:$SHA" "23:$SHA:hotfix-candidate"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(corder)" = "b-22 b-21 b-23" ] && ok || bad "b3 claims '$(corder)' (want b-22 b-21 b-23)"
# (b4) higher priority first, and both before no priority
reset
setrows "$(row b-21 example-org/demo-os 21 "$SHA" '2026-10-07 05:00:00' 0)" \
        "$(row b-22 example-org/demo-os 22 "$SHA" '2026-10-07 06:00:00' 1 5)" \
        "$(row b-23 example-org/demo-os 23 "$SHA" '2026-10-07 07:00:00' 2 9)"
open_prs "21:$SHA" "22:$SHA" "23:$SHA"
LEAD_REVIEW_MAX_PER_TICK=3 tick
[ "$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)" = "23 22 21" ] && ok || bad "b4 order '$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)' (want 23 22 21)"

# (c) 4 dead rows + 1 live, MAX=1: the 4 are superseded and the live one is
# reviewed. The live row is the OLDEST, so the dead ones are only reached when
# the sweep runs before the budget is spent.
reset
setrows "$(row c-35 example-org/demo-os 35 "$SHA" '2026-10-07 04:59:59' 0)" \
        "$(row c-31 example-org/demo-os 31 "$SHA" '2026-10-07 05:00:00' 1)" \
        "$(row c-32 example-org/demo-os 32 "$SHA" '2026-10-07 05:00:01' 2)" \
        "$(row c-33 example-org/demo-os 33 "$OLD" '2026-10-07 05:00:02' 3)" \
        "$(row c-34 example-org/demo-os 34 "$OLD" '2026-10-07 05:00:03' 4)"
open_prs "33:$SHA" "34:$SHA" "35:$SHA"
for n in 31 32; do jq -nc --arg s "$SHA" '{state:"closed",head:{sha:$s},base:{ref:"main"}}' > "$T/pr/$n.json"; done
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$RC" -eq 0 ] && ok || bad "c rc=$RC"
[ "$(sups)" = 4 ] && ok || bad "c superseded posts=$(sups) (want 4): $(grep result "$T/log/worker")"
[ "$(grep -c '/result .*"outcome":"superseded".*"detail":"pr closed"' "$T/log/worker")" = 2 ] && ok || bad "c 'pr closed' details: $(grep result "$T/log/worker")"
[ "$(grep -c "/result .*\"outcome\":\"superseded\".*\"detail\":\"head moved to ${SHA:0:12}\"" "$T/log/worker")" = 2 ] && ok || bad "c 'head moved' details"
grep -q '^POST /api/lead-reviews/c-35/result .*"outcome":"done"' "$T/log/worker" && ok || bad "c the live row was not reviewed"
[ "$(agents)" = 1 ] && ok || bad "c agent calls=$(agents) (want 1)"
S=$(summary)
[[ "$S" == *" done=1 superseded=4 "*" deferred=0 "* ]] && ok || bad "c summary: $S"
# (c2) the snapshot says moved, the live read says the same head: no supersede
reset
setrows "$(row c-36 example-org/demo-os 36 "$SHA" '2026-10-07 05:00:00' 0)"
open_prs "36:$OLD"
tick
[ "$(sups)" = 0 ] && ok || bad "c2 superseded a live row"
[ "$(agents)" = 1 ] && ok || bad "c2 agent calls=$(agents) (want 1)"
# (c3) no snapshot lib: review_one's own live read supersedes a closed PR, no model call
reset; [ -f "$H/bin/lib/pr-snapshot.sh" ] && mv "$H/bin/lib/pr-snapshot.sh" "$H/bin/lib/pr-snapshot.sh.off"
setrows "$(row c-37 example-org/demo-os 37 "$SHA" '2026-10-07 05:00:00' 0)"
jq -nc --arg s "$SHA" '{state:"closed",head:{sha:$s},base:{ref:"main"}}' > "$T/pr/37.json"
tick
grep -q '^POST /api/lead-reviews/c-37/result .*"outcome":"superseded".*"detail":"pr closed"' "$T/log/worker" && ok || bad "c3 no 'pr closed' supersede: $(grep result "$T/log/worker")"
[ "$(agents)" = 0 ] && ok || bad "c3 agent calls=$(agents) (want 0)"
# (c4) same, plus a live row behind it, MAX=1: the backstop's supersede does not
# use up the budget, so the live row is reviewed in the same tick
reset; [ -f "$H/bin/lib/pr-snapshot.sh" ] && mv "$H/bin/lib/pr-snapshot.sh" "$H/bin/lib/pr-snapshot.sh.off"
setrows "$(row c-37 example-org/demo-os 37 "$SHA" '2026-10-07 05:00:00' 0)" \
        "$(row c-35 example-org/demo-os 35 "$SHA" '2026-10-07 05:00:01' 1)"
jq -nc --arg s "$SHA" '{state:"closed",head:{sha:$s},base:{ref:"main"}}' > "$T/pr/37.json"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(sups)" = 1 ] && [ "$(cat "$T/log/agent-prs" 2>/dev/null)" = 35 ] && ok || bad "c4 superseded=$(sups) reviewed='$(cat "$T/log/agent-prs" 2>/dev/null)' (want 1 and 35)"
[[ "$(summary)" == *" done=1 superseded=1 "*" deferred=0 "* ]] && ok || bad "c4 summary: $(summary)"
[ -f "$H/bin/lib/pr-snapshot.sh.off" ] && mv "$H/bin/lib/pr-snapshot.sh.off" "$H/bin/lib/pr-snapshot.sh"

# (d) the claim answers 503 overloaded: ONE line, the tick ends, nothing skipped
D_ROWS=(); for i in 1 2 3 4 5; do D_ROWS+=("$(row d-4$i example-org/demo-os "4$i" "$SHA" "2026-10-07 05:00:0$i" "$i")"); done
reset; setrows "${D_ROWS[@]}"; open_prs "41:$SHA" "42:$SHA" "43:$SHA" "44:$SHA" "45:$SHA"; : > "$T/claim503"
LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$RC" -eq 0 ] && ok || bad "d rc=$RC"
[ "$(grep -c 'answered 503' "$L")" = 1 ] && ok || bad "d '503' lines: $(grep -c 'answered 503' "$L"): $(cat "$L")"
grep -q 'D1_ERROR: overloaded' "$L" && ok || bad "d the 503 body is not in the line"
# BH-5781: _jobs_req sends a 503 "overloaded" answer's request once more, so
# the ONE row's claim reaches the worker twice; still one row, one line.
[ "$(claims)" = 2 ] && ok || bad "d claims=$(claims) (want 2: one row, sent again once by the overload retry)"
grep -q 'worker unusable' "$L" && bad "d per-row worker-unusable lines" || ok
S=$(summary)
[[ "$S" == *" skipped=0 "* ]] && ok || bad "d summary skipped: $S"
[[ "$S" == *" stopped=worker left=4" ]] && ok || bad "d summary stop: $S"
[ "$(agents)" = 0 ] && ok || bad "d agent called"
rm -f "$T/claim503"; tick
grep -q 'tick skipped' "$L" && bad "d the lock was not released" || ok
[ "$(grep -c ' tick seen=' "$L")" = 2 ] && ok || bad "d the second tick did not run"
# (d2) job_open answers 503: one line, no claim, nothing skipped
reset; setrows "${D_ROWS[@]}"; open_prs "41:$SHA" "42:$SHA" "43:$SHA" "44:$SHA" "45:$SHA"; : > "$T/jobs503"
LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$(grep -c 'failed (worker unusable); tick ended' "$L")" = 1 ] && ok || bad "d2 lines: $(grep -c 'worker unusable' "$L"): $(cat "$L")"
[ "$(claims)" = 0 ] && ok || bad "d2 claims=$(claims)"
S=$(summary)
[[ "$S" == *" skipped=0 "* ]] && [[ "$S" == *" stopped=worker left=4" ]] && ok || bad "d2 summary: $S"

# (e) the page cap: 350 rows, LEAD_REVIEW_MAX_PAGES=2 -> 200 read, said so, next tick the same
reset; foreign 350 0 > "$T/rows.json"
LEAD_REVIEW_MAX_PAGES=2 tick
[ "$RC" -eq 0 ] && ok || bad "e rc=$RC"
[ "$(lgets)" = 2 ] && ok || bad "e list GETs=$(lgets) (want 2)"
[ "$(grep -c 'hit LEAD_REVIEW_MAX_PAGES=2 after 200 rows' "$L")" = 1 ] && ok || bad "e cap line: $(cat "$L")"
[[ "$(summary)" == *" total=200+ prs=50+" ]] && ok || bad "e summary: $(summary)"
LEAD_REVIEW_MAX_PAGES=2 tick
[ "$(grep -c 'hit LEAD_REVIEW_MAX_PAGES=2 after 200 rows' "$L")" = 2 ] && [ "$(grep -c ' tick seen=' "$L")" = 2 ] && ok || bad "e second tick: $(cat "$L")"

# (f) an old worker ignores after: one GET, said so, a floor not a count
reset; foreign 250 0 > "$T/rows.json"; : > "$T/oldworker"
tick
[ "$(lgets)" = 1 ] && ok || bad "f list GETs=$(lgets) (want 1)"
grep -q 'cursor paging not deployed' "$L" && ok || bad "f no 'not deployed' line: $(cat "$L")"
[[ "$(summary)" == *" total=100+ "* ]] && ok || bad "f summary: $(summary)"

# (g) page 2 fails: page 1's rows are worked, the count is a floor
reset; foreign 250 0 > "$T/rows.json"; : > "$T/page2fail"
tick
[ "$RC" -eq 0 ] && ok || bad "g rc=$RC"
grep -q 'request list page 2 failed' "$L" && ok || bad "g no 'page 2 failed' line: $(cat "$L")"
S=$(summary)
[[ "$S" == *" tick seen=100 "* ]] && [[ "$S" == *" total=100+ "* ]] && ok || bad "g summary: $S"

# (h) the open-PR list is unreadable: said once, no hotfix order, no supersede, oldest first
reset; setrows "$(row b-21 example-org/demo-os 21 "$SHA" '2026-10-07 05:00:00' 0)" \
                "$(row b-23 example-org/demo-os 23 "$SHA" '2026-10-07 07:00:00' 1)"
open_prs "21:$SHA" "23:$SHA:hotfix"; : > "$T/openfail"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(grep -c 'unreadable.*no hotfix order' "$L")" = 1 ] && ok || bad "h unreadable lines: $(cat "$L")"
[ "$(corder)" = "b-21 b-23" ] && ok || bad "h claims '$(corder)' (want b-21 b-23: oldest first)"
[ "$(sups)" = 0 ] && ok || bad "h superseded on an unreadable list"

echo "lead-review-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
