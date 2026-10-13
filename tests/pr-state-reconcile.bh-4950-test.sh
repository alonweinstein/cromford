#!/bin/bash
# tests/pr-state-reconcile.bh-4950-test.sh — BH-4954 (BH-4950.1): the hub sweep
# "$DIR/bin/pr-state-reconcile.sh", run WHOLE (`tick`) against a scratch
# harness carrying the real jobs client and every lib it sources (installed by
# scratch_install_closure). Its lane is registered by
# "$DIR/catalog/lanes.d/pr-state-reconcile.json" and scheduled by
# "$DIR/cron/lanes/716-pr-state-reconcile.cron". Stubbed:
#   * curl — a STATEFUL jobs worker. POST /api/pr-state-events appends to
#            $T/events.jsonl (a repeat of repo+number+since is a duplicate);
#            GET /api/pr-state/gate folds that log per field, latest non-null,
#            exactly as pr-gate.js gateFacts does. GET /api/verdict?pr= answers
#            $T/jv/<n>.json (missing = 404 = job_verdict rc 2). GET
#            /api/verdicts ... standing_only answers $T/standing/<n>, and a 500
#            when $T/standing500/<n> exists. $T/post500 fails every write.
#   * gh   — the open list ($T/prs.json), the single PR ($T/head/<n>; a closed
#            one when $T/closed/<n> exists, a 500 on $T/head500/<n>), the thread
#            ($T/comments/<n>.json; a 500 on $T/comments500/<n>), the CI reads
#            (Actions runs from $T/ci/<sha>; both reads fail on $T/ci500) and
#            rate_limit (remaining 0 when $T/budgetlow exists).
# Every worker request is logged "<METHOD> <path> <body>" and every gh call too.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-state-reconcile.bh-4950-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# CI's tests/ shards leave GH_TOKEN unset on purpose (harness-ci.yml, BH-1984),
# so this suite runs that way everywhere: a dev shell's token must not decide
# which path gh_budget_low takes (bin/lib/gh-budget.sh, `gh auth token`).
unset GH_TOKEN
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp"
[ -f "$DIR/bin/pr-state-reconcile.sh" ] && ok || { bad "bin/pr-state-reconcile.sh does not exist"; echo "pr-state-reconcile: $PASS passed, $FAIL failed"; exit 1; }
scratch_install_closure bin/pr-state-reconcile.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/pr-state-reconcile.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }

R=example-org/cromford
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
touch "$T/events.jsonl"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1 | sed 's/%2F/\//g'; }
code=200; out='{}'
case "\$m \$p" in
  "POST /api/pr-state-events")
    if [ -e "$T/post500" ]; then code=500; out='{"error":"boom"}'
    elif jq -e --argjson b "\$body" 'select(.repo == \$b.repo and .number == \$b.number and .since == \$b.since)' "$T/events.jsonl" 2>/dev/null | grep -q .; then
      out='{"recorded":false,"duplicate":true}'
    else
      printf '%s\n' "\$body" >> "$T/events.jsonl"; code=201; out='{"recorded":true,"duplicate":false}'
    fi ;;
  "GET /api/pr-state/gate?"*)
    r=\$(qp repo)
    out=\$(jq -sc --arg r "\$r" '[.[] | select(.repo == \$r)] | group_by(.number)
      | map(. as \$e | reduce ("head","draft","closed","held","hotfix","ci_green_sha","builder_approved_sha","lead_verdict_sha","lead_verdict_word") as \$f
          ({repo: \$r, number: \$e[0].number}; .[\$f] = ([\$e[] | .[\$f] | select(. != null)] | last)))
      | {rows: ., as_of: "now"}' "$T/events.jsonl") ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -e "$T/standing500/\$n" ]; then code=500; out='{"error":"boom"}'
    else
      if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
      out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}')
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    rem=5000; [ -e "$T/budgetlow" ] && rem=0
    echo "{\"resources\":{\"core\":{\"remaining\":\$rem,\"limit\":5000,\"reset\":2000000000},\"graphql\":{\"remaining\":\$rem,\"limit\":5000,\"reset\":2000000000}}}" ;;
  *"-X GET repos/$R/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/$R/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/head500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    elif [ -e "$T/closed/\$n" ]; then printf 'HTTP/2 200\r\n\r\n{"state":"closed","head":{"sha":"%s"}}\n' "$C"
    else printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{state:"open",head:{sha:\$s},base:{ref:"main"}}'; fi ;;
  *"-X GET repos/$R/issues/"*"/comments"*)
    a="\$*"; n="\${a##*/issues/}"; n="\${n%%/*}"
    if [ -e "$T/comments500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; cat "$T/comments/\$n.json" 2>/dev/null || echo '[]'; fi ;;
  *"actions/runs"*)
    [ -e "$T/ci500" ] && exit 1
    a="\$*"; s="\${a##*head_sha=}"; s="\${s%%&*}"
    if [ -f "$T/ci/\$s" ]; then jq -nc --arg c "\$(cat "$T/ci/\$s")" '{workflow_runs:[{name:"Harness CI",status:"completed",conclusion:\$c,run_started_at:"2026-10-07T00:00:00Z"}]}'
    else echo '{"workflow_runs":[]}'; fi ;;
  *"check-runs"*)
    [ -e "$T/ci500" ] && exit 1
    echo '{"check_runs":[]}' ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=$R \
  PR_STATE_RECONCILE_MAX_PER_SWEEP=30
unset BOX_NAME JOBS_BOX HUB_BOX_NAME PR_SNAPSHOT

# pr <n> <head> [draft] — an open PR on $R at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/'"$R"'/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"},
    updated_at:"2026-10-07T00:00:00Z"}]' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# approve <n> <reviewed_sha> [headbound] — the builder's ledger verdict row
approve() {
  jq -nc --arg s "$2" --arg hb "${3:-n/a}" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:$hb, reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
green() { echo success > "$T/ci/$1"; }
# seed <n> <json fields> — a gate fact the db already holds
SEEDN=0
seed() { SEEDN=$((SEEDN + 1)); jq -nc --arg r "$R" --argjson n "$1" --argjson f "$2" --arg s "seed-$SEEDN" \
  '{repo:$r, number:$n, state:"gate", since:$s, reason:"seed"} + $f' >> "$T/events.jsonl"; }
reset() {
  rm -f "$T/log"/* "$T"/{ci500,post500,budgetlow,events.jsonl} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing standing500 head head500 closed comments comments500 ci; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"; : > "$T/events.jsonl"
}
tick() { ( cd "$T" && bash "$H/bin/pr-state-reconcile.sh" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/pr-state-reconcile.log"
summ() { grep ' checked=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
num() { summ | sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }
recon() { jq -s '[.[] | select(.reason == "reconcile")] | length' "$T/events.jsonl"; }
recon_rows() { jq -sc '[.[] | select(.reason == "reconcile") | del(.repo, .state, .actor)]' "$T/events.jsonl"; }
facts() { jq -sc --argjson n "$1" '[.[] | select(.number == $n)] as $e
  | reduce ("head","draft","closed","held","ci_green_sha","builder_approved_sha","lead_verdict_sha","lead_verdict_word") as $f
      ({}; .[$f] = ([$e[] | .[$f] | select(. != null)] | last))' "$T/events.jsonl"; }
# `gh auth token` is the budget check's local credential lookup when GH_TOKEN
# is unset, not a GitHub read; `api rate_limit` is the budget check itself.
GH_NOT_READS='api rate_limit|^auth token$'
ghreads() { grep -vcE "$GH_NOT_READS" "$T/log/gh" 2>/dev/null || true; }

# ── R1: db head A, GitHub head B -> exactly one row, reason=reconcile, head=B ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$A\",\"draft\":0}"; tick
[ "$RC" = 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
[ "$(recon)" = 1 ] && ok || bad "R1 want exactly one reconcile row, got $(recon): $(recon_rows)"
ROW=$(jq -sc '[.[] | select(.reason == "reconcile")] | first' "$T/events.jsonl")
[ "$(jq -r .head <<<"$ROW")" = "$B" ] && [ "$(jq -r .number <<<"$ROW")" = 7 ] && ok || bad "R1 row: $ROW"
[ "$(jq -r '[keys[] | select(IN("draft","closed","held","ci_green_sha","builder_approved_sha","lead_verdict_sha"))] | length' <<<"$ROW")" = 0 ] \
  && ok || bad "R1 the row carries more than head: $ROW"
case "$(jq -r .since <<<"$ROW")" in "reconcile@${B:0:12}@head@"[0-9]*) ok ;; *) bad "R1 source: $ROW" ;; esac
[ "$(jq -r '.since | length' <<<"$ROW")" -le 64 ] && ok || bad "R1 source over the 64-char cap: $ROW"
grep -q "$R 7 head db=${A:0:12} live=${B:0:12}" "$LOGF" && ok || bad "R1 no per-correction line: $(cat "$LOGF")"
has checked=1 && has corrected=1 && has failed=0 && has repos=1 && ok || bad "R1 summary: $(summ)"
grep -q "$A" "$LOGF" && bad "R1 a full sha reached the log" || ok
grep -q 'test-secret' "$LOGF" && bad "R1 a secret reached the log" || ok

# ── R2: a second sweep writes zero rows ──
tick
[ "$(recon)" = 1 ] && ok || bad "R2 want still one reconcile row, got $(recon): $(recon_rows)"
has checked=1 && has corrected=0 && ok || bad "R2 summary: $(summ)"

# ── R3: CI unreadable (runs and check-runs both fail) -> no ci row, skipped ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\"}"; green "$B"; touch "$T/ci500"; tick
[ "$(recon)" = 0 ] && ok || bad "R3 an unreadable CI wrote: $(recon_rows)"
[ "$(num skipped)" -ge 1 ] 2>/dev/null && ok || bad "R3 want skipped>=1: $(summ)"
grep -q 'CI on .* is unreadable' "$LOGF" && ok || bad "R3 no unreadable-CI line: $(cat "$LOGF")"
# ... and the same PR with CI readable and green writes ci_green_sha=<head>.
rm -f "$T/ci500"; tick
[ "$(jq -r .ci_green_sha <<<"$(facts 7)")" = "$B" ] && [ "$(recon)" = 1 ] && ok || bad "R3 green CI not corrected: $(recon_rows)"

# ── R4: cold backfill, 10 green+approved PRs, MAX=5 -> defers, converges, ends at 0 ──
reset
for n in 1 2 3 4 5 6 7 8 9 10; do pr "$n" "$A"; approve "$n" "$A"; done; green "$A"
PR_STATE_RECONCILE_MAX_PER_SWEEP=5 tick
[ "$(recon)" = 5 ] && ok || bad "R4 sweep 1 want 5 rows, got $(recon)"
has corrected=5 && [ "$(num deferred)" -gt 0 ] 2>/dev/null && ok || bad "R4 sweep 1 summary: $(summ)"
LAST=""
for _ in 2 3 4 5 6 7 8 9; do
  PR_STATE_RECONCILE_MAX_PER_SWEEP=5 tick; LAST=$(num corrected)
  [ "$LAST" = 0 ] && break
done
[ "$LAST" = 0 ] && ok || bad "R4 never converged: $(summ)"
[ "$(recon)" = 30 ] && ok || bad "R4 want 30 rows (head+approve+ci on 10 PRs), got $(recon)"
ALL=1; for n in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(facts "$n" | jq -r '[.head, .ci_green_sha, .builder_approved_sha] | unique | length')" = 1 ] && [ "$(facts "$n" | jq -r .head)" = "$A" ] || ALL=0
done
[ "$ALL" = 1 ] && ok || bad "R4 not every PR holds head=ci=approve=A"

# ── R5: open in the db, closed on GitHub -> closed=1; a 500 writes nothing ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\"}"; seed 9 "{\"head\":\"$C\",\"closed\":0}"; touch "$T/closed/9"; tick
[ "$(recon_rows | jq -c '[.[] | select(.number == 9) | .closed]')" = "[1]" ] && ok || bad "R5 want closed=1 on 9: $(recon_rows)"
case "$(recon_rows | jq -r '.[] | select(.number == 9) | .since')" in "reconcile@${C:0:12}@closed@"*) ok ;; *) bad "R5 source: $(recon_rows)" ;; esac
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\"}"; seed 9 "{\"head\":\"$C\"}"; touch "$T/head500/9"; tick
[ "$(recon)" = 0 ] && ok || bad "R5 a 500 wrote: $(recon_rows)"
[ "$(num skipped)" -ge 1 ] 2>/dev/null && ok || bad "R5 500 want skipped>=1: $(summ)"

# ── R6: budget low -> no read past the budget check and no write ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$A\"}"; touch "$T/budgetlow"; tick
[ "$RC" = 0 ] && ok || bad "R6 rc=$RC"
[ "$(recon)" = 0 ] && ok || bad "R6 wrote under a low budget: $(recon_rows)"
[ "$(ghreads)" = 0 ] && ok || bad "R6 GitHub reads past the budget: $(grep -vE "$GH_NOT_READS" "$T/log/gh")"
grep -q 'pr-state' "$T/log/worker" 2>/dev/null && bad "R6 a gate read/write under a low budget: $(cat "$T/log/worker")" || ok
grep -q "budget low; $R skipped this pass" "$LOGF" && ok || bad "R6 no budget line: $(cat "$LOGF")"

# ── R7: MAX unset or 0 -> exit 0, nothing written ──
for v in UNSET 0 abc; do
  reset; pr 7 "$B"; seed 7 "{\"head\":\"$A\"}"
  if [ "$v" = UNSET ]; then ( unset PR_STATE_RECONCILE_MAX_PER_SWEEP; tick; exit "$RC" ); RC=$?
  else PR_STATE_RECONCILE_MAX_PER_SWEEP=$v tick; fi
  [ "$RC" = 0 ] && ok || bad "R7 $v rc=$RC"
  [ "$(recon)" = 0 ] && ok || bad "R7 $v wrote: $(recon_rows)"
  grep -q 'PR_STATE_RECONCILE_MAX_PER_SWEEP=.* is not a positive integer' "$LOGF" && ok || bad "R7 $v no refusal line: $(cat "$LOGF")"
  [ -s "$T/log/gh" ] && bad "R7 $v read GitHub with no cap" || ok
done
reset; pr 7 "$B"; seed 7 "{\"head\":\"$A\"}"; LEAD_REVIEW_AUTO_REPOS='' tick
[ "$(recon)" = 0 ] && grep -q 'LEAD_REVIEW_AUTO_REPOS is empty' "$LOGF" && ok || bad "R7 empty repos: $(cat "$LOGF")"

# ── R8: vd_standing rc 2 and hold_check_thread rc 2 write nothing ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\",\"held\":1}"
echo '{"verdict":"MERGE","source":"lead","id":3,"created_at":"x"}' > "$T/standing/7"
touch "$T/standing500/7" "$T/comments500/7"; tick
[ "$(recon)" = 0 ] && ok || bad "R8 an unreadable verdict/thread wrote: $(recon_rows)"
[ "$(num skipped)" -ge 2 ] 2>/dev/null && ok || bad "R8 want skipped>=2: $(summ)"
# ... and readable, the same PR gets lead_verdict and held=0.
rm -f "$T/standing500/7" "$T/comments500/7"; tick
F=$(facts 7)
[ "$(jq -r .lead_verdict_sha <<<"$F")" = "$B" ] && [ "$(jq -r .lead_verdict_word <<<"$F")" = MERGE ] && ok || bad "R8 lead_verdict not corrected: $(recon_rows)"
[ "$(jq -r .held <<<"$F")" = 0 ] && ok || bad "R8 held not corrected to 0: $(recon_rows)"

# ── R9: a thread HOLD and a reapproved@<head> rebind are corrected ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\"}"; approve 7 "$A" "reapproved@$B"
echo '[{"body":"HOLD: wait","created_at":"2026-10-07T00:00:00Z","user":{"type":"User","login":"operator"}}]' > "$T/comments/7.json"; tick
F=$(facts 7)
[ "$(jq -r .held <<<"$F")" = 1 ] && ok || bad "R9 held not corrected to 1: $(recon_rows)"
[ "$(jq -r .builder_approved_sha <<<"$F")" = "$B" ] && ok || bad "R9 reapproved@head not corrected: $(recon_rows)"
# an APPROVE on an OLDER sha with no rebind is not an approval of the head
reset; pr 7 "$B"; seed 7 "{\"head\":\"$B\"}"; approve 7 "$A"; tick
[ "$(recon)" = 0 ] && ok || bad "R9 an old-sha APPROVE was written: $(recon_rows)"

# ── R10: a failed write is failed, never corrected ──
reset; pr 7 "$B"; seed 7 "{\"head\":\"$A\"}"; touch "$T/post500"; tick
has corrected=0 && has failed=1 && ok || bad "R10 summary: $(summ)"
grep -q 'was not written; next sweep retries' "$LOGF" && ok || bad "R10 no failure line: $(cat "$LOGF")"

# ── R11: off the hub -> one log line, no reads ──
reset; pr 7 "$B"; echo box-demo > "$H/state/box-name"; tick
grep -q 'runs on the hub only' "$LOGF" && ok || bad "R11 no hub line"
[ -s "$T/log/gh" ] || [ -s "$T/log/worker" ] && bad "R11 read off the hub" || ok

# ── Lane registration: hub, */15, the knob, behind hub-lease, no other cron touched ──
J="$DIR/catalog/lanes.d/pr-state-reconcile.json"
[ "$(jq -r '[.id, .scope, .script, .cadence, (.boxes|join(",")), .switch.name, (.wired|tostring)] | join(" ")' "$J")" \
  = "pr-state-reconcile hub bin/pr-state-reconcile.sh */15 * * * * hub lane-off-pr-state-reconcile true" ] && ok || bad "catalog entry: $(cat "$J")"
[ "$(jq -c '.knobs[0] | [.env, .type, .default, .min, .max, .required]' "$J")" = '["PR_STATE_RECONCILE_MAX_PER_SWEEP","int",30,1,500,true]' ] \
  && ok || bad "knob: $(jq -c .knobs "$J")"
grep -qx '\*/15 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/pr-state-reconcile.sh tick >/dev/null 2>&1' \
  "$DIR/cron/lanes/716-pr-state-reconcile.cron" && ok || bad "cron line"

echo "pr-state-reconcile: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
