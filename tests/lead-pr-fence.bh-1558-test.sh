#!/bin/bash
# tests/lead-pr-fence.bh-1558-test.sh — BH-1558: the two merge paths #1537 left
# unfenced, bin/review-prs.sh's merge_step and bin/run-build.sh's tier-1
# self-merge, now ask the SAME questions every other merge lane asks:
#   * a held ticket's PR does not merge (bin/lib/ticket-ownership.sh
#     to_lane_hold, the BH-1526 fence);
#   * a LEAD-authored PR (the lead_pr_authors row) merges only on a lead/human
#     MERGE or MERGE-WITH-NOTES verdict ROW standing on its exact live head
#     (bin/lib/verdicts.sh, the BH-1525 reader) — never on a box/Fable APPROVE;
#   * an unreadable lead row, PR or verdicts table is "not this pass", never a
#     merge (the verdict reader's rc 2 rule), and it does not spend review-prs'
#     merge-retry budget.
#
# THE REPLAY (2026-09-22 23:46Z): review-prs approved and auto-merged lead PR
# #1547 at its pre-guard head while the lead's Mac review had asked for one
# more commit. R1 is that tick: a lead PR, a box APPROVE, no lead row -> no merge.
#
# Driven, not grepped: each production block is extracted VERBATIM by its
# `# >>> …` markers (the tests/block-gate-lanes-test.sh shape) and run against a
# stub gh (GitHub) and a stub curl (the jobs worker: /api/verdicts and
# /api/settings/lead_pr_authors).
# Run from anywhere: tests/lead-pr-fence.bh-1558-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
TICKET=1558
H1=aaaaaaaa11111111111111111111111111111111   # the live head
H0=0000000011111111111111111111111111111111   # an earlier head of the same PR
H2=bbbbbbbb22222222222222222222222222222222   # a head pushed after the verdict was read
PRURL="https://github.com/$SLUG/pull/41"
LEAD=operator
BOT='cromford[bot]'

# ---------------------------------------------------------------------------
# The scratch harness: one GitHub-Issues project (board prefix "-") so the
# ticket HOLD is readable, with the real libraries the two lanes load.
# ---------------------------------------------------------------------------
H="$T/h"; FX="$T/fx"; VD="$T/vd"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$T/fakebin" "$FX" "$VD"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/ticket-ownership.sh" \
   "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
cat > "$H/bin/fleet-conf.sh" <<SHIM
#!/bin/bash
case "\$1 \${2:-}" in
  "--projects ")          echo demo-os ;;
  "demo-os repo")         echo "$SLUG" ;;
  "demo-os board_prefix") echo "-" ;;
esac
exit 0
SHIM
chmod +x "$H/bin/fleet-conf.sh"
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/demo-os.env"
for s in beat.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"; done
# lane-alert.sh records every alert the block gate's streak counter raises.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T/fx" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# gh: PR #41 (author from $FX/author, head $H1, "Closes #1558"), issue #1558
# (body from $FX/issue-body; $FX/issue-404 makes it unreadable), merges recorded.
# A `-q`/--jq read (the block gate's thread scan) answers nothing: no block.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/gh-calls"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  # A merge pinned (--match-head-commit) to a head that is no longer the live
  # one (\$FX/live-head) is refused, as GitHub refuses it. Unpinned, it lands
  # whatever the live head is — the race #1603's review names.
  *"pr merge"*|*"-X PUT"*"/merge"*)
    pin=\$(printf '%s' "\$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')
    if [ -f "$FX/live-head" ] && [ -n "\$pin" ] && [ "\$pin" != "\$(cat "$FX/live-head")" ]; then
      printf '%s\n' "\$*" >> "$FX/refused"; echo "Head branch was modified. Review and try the merge again." >&2; exit 1
    fi
    printf '%s\n' "\$*" >> "$FX/merges"; exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/41"|*"api -i -X GET repos/$SLUG/pulls/41 "*)
    if [ -s "$FX/merges" ]; then restpr MERGED "$H1" ticket/bh-$TICKET main "" MERGEABLE CLEAN "\$(cat "$FX/author")" cccccccc3333 "Closes #$TICKET"
    else restpr OPEN "$H1" ticket/bh-$TICKET main "" MERGEABLE CLEAN "\$(cat "$FX/author")" "" "Closes #$TICKET"; fi ;;
  *"--json headRefOid"*) echo "$H1" ;;
  *"--json state"*) [ -s "$FX/merges" ] && echo MERGED || echo OPEN ;;
  *"--json mergeCommit"*) echo cccccccc3333 ;;
  *" -q "*|*"--jq"*) exit 0 ;;
  *"api repos/$SLUG/issues/$TICKET/comments"*) echo '[]'; exit 0 ;;
  *"api repos/$SLUG/issues/$TICKET"*)
    [ -f "$FX/issue-404" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -nc --arg b "\$(cat "$FX/issue-body")" '{number:$TICKET,state:"open",labels:[{name:"ai-build"}],title:"BH-$TICKET: x",body:\$b}'; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# curl: the jobs worker. GET /api/verdicts answers $VD/<head> or "nothing
# stands"; $VD/down fails it at the transport. GET /api/settings/lead_pr_authors
# answers $VD/lead; $VD/lead-down fails it at the transport.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "GET "*/api/verdicts\?*)
    printf '%s\n' "\$URL" >> "$VD/calls"
    [ -f "$VD/down" ] && exit 7
    h="\${URL##*head=}"; h="\${h%%&*}"
    if [ -f "$VD/\$h" ]; then printf '%s\n200\n' "\$(cat "$VD/\$h")"
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "GET "*/api/settings/lead_pr_authors)
    [ -f "$VD/lead-down" ] && exit 7
    [ -f "$VD/lead-404" ] && { printf 'error code: 1042\n404\n'; exit 0; }
    [ -f "$VD/lead-html" ] && { printf '<html><body>gateway</body></html>\n200\n'; exit 0; }
    [ -f "$VD/lead-null" ] && { printf '{"setting":null}\n200\n'; exit 0; }
    printf '{"setting":{"key":"lead_pr_authors","value":"%s"}}\n200\n' "\$(cat "$VD/lead")" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# vd_put <head> <verdict> <source> — one standing row on that head
vd_put() {
  jq -nc --arg v "$2" --arg s "$3" --arg h "$1" \
    '{standing:{id:7,repo:"example-org/demo-os",pr:41,head_sha:$h,verdict:$v,source:$s,
      created_at:"2026-09-23T10:00:00Z",report_url:null,reviewer:"mac-lead"},head:$h,rows:[]}' > "$VD/$1"
}
# reset <author> [held] — a fresh tick: no merges, no verdict rows, the lead row
# reads `operator`, the ticket carries a HOLD line only when asked.
reset() {
  rm -f "$FX"/* "$VD"/*; : > "$FX/gh-calls"; : > "$VD/calls"
  printf '%s' "$1" > "$FX/author"; printf '%s' "$LEAD" > "$VD/lead"
  if [ "${2:-}" = held ]; then printf 'HOLD: the lead is building this on the Mac; the pool must not build or split it.\n\n## Build\nx' > "$FX/issue-body"
  else printf '## Build\nx' > "$FX/issue-body"; fi
  scratch_rm "$H/state/block-gate" 2>/dev/null; scratch_rm "$H/state/merge-queue" 2>/dev/null
  scratch_rm "$H/state/ticket-ownership" 2>/dev/null
  return 0
}
merged() { [ -s "$FX/merges" ]; }
export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=s \
       JOBS_URL=https://jobs.test JOBS_RETRIES=0

# ============================================================================
# R. bin/review-prs.sh's merge step, extracted by its markers and driven.
# ============================================================================
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rmerge.sh"
[ -s "$T/rmerge.sh" ] && ok || bad "could not extract the review-prs merge step — markers missing?"
RLOG="$T/pr-reviews.log"
# run_review [author-arg] — one APPROVE merge_step on #41 at $H1 (served by the
# Claude lane, i.e. the box/Fable APPROVE); prints MERGED=… FENCED=…
run_review() {
  [ "${KEEP_LOG:-0}" = 1 ] || : > "$RLOG"
  ( cd "$T" && PROJECT=demo-os SLUG="$SLUG" LOG="$RLOG" bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      rp_prov_is_claude() { [ "${1:-}" = claude ]; }
      mc_queue_conductor_only() { return 1; }
      mc_pr_queued() { return 1; }
      # TEST-CHANGE (BH-1585): the merge step reads the state-after over REST
      # (mc_pr_view / gh_rest, which review-prs.sh always has in scope); the
      # driver provides both, over the stub arm for pulls/41 above.
      # TEST-CHANGE (BH-1285): merge_step now reads .base.ref before the
      # direct merge (a stacked PR is held), so the shim carries base.ref too.
      . "$HARNESS/bin/lib/gh-rest.sh"
      mc_pr_view() { local f; f=$(mktemp); gh_rest GET "repos/$SLUG/pulls/${1##*/}" > "$f" || { rm -f "$f"; return 75; }
        jq -r "{STATE: (if .merged_at != null then \"MERGED\" elif .state == \"open\" then \"OPEN\" else \"CLOSED\" end), base: {ref: .base.ref}} | ${2:-.}" "$f"; rm -f "$f"; }
      . "$HARNESS/bin/lib/block-gate.sh"
      . "$0"
      merge_step 41 '"$H1"' claude "$1"
      printf "MERGED=%s FENCED=%s MQ=%s" "$MERGED" "${RP_FENCED:-0}" "${RP_MQ_WANT:-0}"' "$T/rmerge.sh" "${1-$(cat "$FX/author")}" 2>>"$T/review.err" )
}

# R1. THE #1547 REPLAY: a lead PR, a box APPROVE, no lead verdict row.
reset "$LEAD"
OUT=$(run_review)
merged && bad "R1 THE DEFECT: review-prs merged a LEAD PR on a box APPROVE with no lead verdict row ($(cat "$FX/merges"))" || ok
grep -q 'MERGED=no' <<<"$OUT" && ok || bad "R1: a fenced lead PR reports merged=no (got '$OUT')"
grep -q 'FENCED=1' <<<"$OUT" && ok || bad "R1: a fenced merge must say so (RP_FENCED=1) so merge_retry does not count it (got '$OUT')"
grep -q "$SLUG#41 MERGE_HELD.*lead" "$RLOG" && ok || bad "R1: the refusal is logged as a lead-PR hold: $(cat "$RLOG")"
grep -q "head=$H1" "$VD/calls" && ok || bad "R1: the lane must have asked the verdicts table about the live head: $(cat "$VD/calls")"
[ -f "$H/state/merge-queue/demo-os/41" ] && bad "R1: a fenced lead PR must not be pushed onto the box merge queue" || ok

# R2. A lead MERGE row on the exact head: it merges.
reset "$LEAD"; vd_put "$H1" MERGE lead
OUT=$(run_review)
merged && ok || bad "R2: a lead MERGE row on the live head must let review-prs merge the lead PR (got '$OUT'; log $(cat "$RLOG"))"
grep -q 'MERGED=yes' <<<"$OUT" && ok || bad "R2: merged=yes (got '$OUT')"
grep -q -- "--match-head-commit $H1" "$FX/merges" && ok \
  || bad "R2 (F1): the merge must be pinned to the head the verdict was read on: $(cat "$FX/merges")"

# R2b. MERGE-WITH-NOTES is a clearing verdict too.
reset "$LEAD"; vd_put "$H1" MERGE-WITH-NOTES human
OUT=$(run_review)
merged && ok || bad "R2b: a human MERGE-WITH-NOTES on the live head clears the lead PR (got '$OUT')"

# R3. A lead MERGE row on an OLDER head only: no merge.
reset "$LEAD"; vd_put "$H0" MERGE lead
OUT=$(run_review)
merged && bad "R3: a lead MERGE on an earlier head must not merge the live one ($(cat "$FX/merges"))" || ok

# R3b. A lead BLOCK on the live head: no merge.
reset "$LEAD"; vd_put "$H1" BLOCK lead
OUT=$(run_review)
merged && bad "R3b: a lead BLOCK on the live head must not merge ($(cat "$FX/merges"))" || ok

# R4. The verdicts table is unreadable: fail closed, not counted.
reset "$LEAD"; vd_put "$H1" MERGE lead; touch "$VD/down"
OUT=$(run_review)
merged && bad "R4: an unreadable verdicts table must not merge a lead PR ($(cat "$FX/merges"))" || ok
grep -q 'FENCED=1' <<<"$OUT" && ok || bad "R4: an unreadable read is not a merge attempt (got '$OUT')"
grep -q "could not be read.*next pass asks again" "$RLOG" && ok || bad "R4: the log names the unreadable read: $(cat "$RLOG")"

# R4b (F3). An unreadable fence feeds the block gate's outage streak, so the
# fence standing ahead of the gate does not swallow review-prs' outage alert.
reset "$LEAD"; vd_put "$H1" MERGE lead; touch "$VD/down"
OUT=$(BLOCK_GATE_STREAK_K=1 run_review)
[ -s "$FX/alerts" ] && ok || bad "R4b (F3): an unreadable verdicts read at the fence must raise the block gate's streak alert (alerts: none; log $(cat "$RLOG"))"
grep -q 'verdicts' "$FX/alerts" 2>/dev/null && ok || bad "R4b (F3): the alert names the verdicts outage: $(cat "$FX/alerts" 2>/dev/null)"
reset "$LEAD"; touch "$VD/lead-down"
OUT=$(BLOCK_GATE_STREAK_K=1 run_review)
[ -s "$FX/alerts" ] && ok || bad "R4c (F3): an unreadable lead row at the fence must raise a streak alert too (log $(cat "$RLOG"))"
reset "$LEAD"
OUT=$(BLOCK_GATE_STREAK_K=1 run_review)
[ -s "$FX/alerts" ] && bad "R4d (F3): a lead PR legitimately WAITING on its lead is not an outage — no alert ($(cat "$FX/alerts"))" || ok

# R5. The lead_pr_authors row is unreadable: nobody can tell whose PR it is —
# fail closed for the lead's PR AND for any other author.
reset "$LEAD"; vd_put "$H1" MERGE lead; touch "$VD/lead-down"
OUT=$(run_review)
merged && bad "R5: an unreadable lead row must not let a PR merge ($(cat "$FX/merges"))" || ok
reset external-dev; touch "$VD/lead-down"
OUT=$(run_review)
merged && bad "R5b: an unreadable lead row holds a non-lead PR too — whether it is the lead's cannot be told ($(cat "$FX/merges"))" || ok

# R5c-e (F2). Only a genuine worker answer carrying the row is a READ. A 404
# from something that is not the worker, a 200 that is not JSON, and an
# emptied/null row are all "whose PR this is cannot be told": fenced.
reset "$LEAD"; touch "$VD/lead-404"
OUT=$(run_review)
merged && bad "R5c (F2): a non-worker 404 ('error code: 1042') on the lead row must not let a lead PR merge ($(cat "$FX/merges"))" || ok
grep -q 'FENCED=1' <<<"$OUT" && ok || bad "R5c: fenced (got '$OUT')"
reset "$LEAD"; touch "$VD/lead-html"
OUT=$(run_review)
merged && bad "R5d (F2): a 200 HTML answer on the lead row must not let a lead PR merge ($(cat "$FX/merges"))" || ok
grep -q 'FENCED=1' <<<"$OUT" && ok || bad "R5d: fenced (got '$OUT')"
reset "$LEAD"; touch "$VD/lead-null"
OUT=$(run_review)
merged && bad "R5e (F2): a null lead row is 'unknown', not 'nobody is the lead' ($(cat "$FX/merges"))" || ok
reset "$LEAD"; : > "$VD/lead"
OUT=$(run_review)
merged && bad "R5f (F2): an EMPTIED lead row is 'unknown', not 'nobody is the lead' ($(cat "$FX/merges"))" || ok

# R9 (F1). The lead verdict stands on H1, the list read H1, but the branch moved
# to H2 before the merge: the pinned merge is refused, nothing lands, and the
# cleared lead PR is NOT handed to the box queue (which has no lead fence).
reset "$LEAD"; vd_put "$H1" MERGE lead; printf '%s' "$H2" > "$FX/live-head"
OUT=$(run_review)
merged && bad "R9 (F1): a lead verdict on H1 merged live head H2 ($(cat "$FX/merges"))" || ok
[ -f "$H/state/merge-queue/demo-os/41" ] && bad "R9 (F1b): a cleared lead PR whose merge failed must not fall through to the box merge queue" || ok
grep -q 'MQ=0' <<<"$OUT" && ok || bad "R9 (F1b): no merge_queue row for it either (got '$OUT')"
grep -q "left for the lead" "$RLOG" && ok || bad "R9 (F1b): the log says it is left for the lead: $(cat "$RLOG")"

# R10 (N). The MERGE_HELD line is written once per (PR, head, reason), not per tick.
reset "$LEAD"; : > "$RLOG"
KEEP_LOG=1 run_review >/dev/null; KEEP_LOG=1 run_review >/dev/null; KEEP_LOG=1 run_review >/dev/null
[ "$(grep -c 'MERGE_HELD' "$RLOG")" = 1 ] && ok || bad "R10 (N): three ticks on one head/reason must log ONE MERGE_HELD line, got $(grep -c 'MERGE_HELD' "$RLOG")"
vd_put "$H1" BLOCK lead
KEEP_LOG=1 run_review >/dev/null
[ "$(grep -c 'MERGE_HELD' "$RLOG")" = 2 ] && ok || bad "R10 (N): a NEW reason on the same head is a new line, got $(grep -c 'MERGE_HELD' "$RLOG")"

# R6. A HELD ticket's (non-lead) PR is not merged by review-prs.
reset external-dev held
OUT=$(run_review)
merged && bad "R6: review-prs merged a PR for a HELD ticket ($(cat "$FX/merges"))" || ok
grep -q "$SLUG#41 MERGE_HELD.*held" "$RLOG" && ok || bad "R6: the hold is logged: $(cat "$RLOG")"
grep -q 'FENCED=1' <<<"$OUT" && ok || bad "R6: a held tick is not a merge attempt (got '$OUT')"

# R6b. The hold cannot be read: not this pass.
reset external-dev; touch "$FX/issue-404"
OUT=$(run_review)
merged && bad "R6b: an unreadable ticket hold must not merge ($(cat "$FX/merges"))" || ok

# R7. Control: a non-lead PR on a clear ticket merges exactly as today.
reset external-dev
OUT=$(run_review)
merged && ok || bad "R7: a non-lead PR on a clear ticket must still merge on APPROVE (got '$OUT'; log $(cat "$RLOG"); err $(tail -3 "$T/review.err" 2>/dev/null))"

# R8. The author is not handed in (an old caller): the fence reads the PR itself.
reset "$LEAD"
OUT=$(run_review "")
merged && bad "R8: with no author argument the fence must read the PR and still hold the lead PR ($(cat "$FX/merges"))" || ok
reset "$LEAD"; vd_put "$H1" MERGE lead
OUT=$(run_review "")
merged && ok || bad "R8b: with no author argument and a lead MERGE row the lead PR merges (got '$OUT'; log $(cat "$RLOG"))"

# ============================================================================
# M. merge_retry: a fenced lead PR does not spend the retry budget.
# ============================================================================
awk '/^# >>> review-prs state write/{f=1;next} /^# <<< review-prs state write/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rstate.sh"
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rretry.sh"
[ -s "$T/rstate.sh" ] && [ -s "$T/rretry.sh" ] && ok || bad "could not extract the review-prs state-write / merge-retry blocks"
reset "$LEAD"; : > "$RLOG"
printf '{"41":{"sha":"%s","verdict":"APPROVE","served":"claude"}}\n' "$H1" > "$T/state.json"
( cd "$T" && PROJECT=demo-os SLUG="$SLUG" LOG="$RLOG" STATE="$T/state.json" AUTHOR="$LEAD" bash -c 'set -uo pipefail
    STAMP() { echo TS; }
    rp_prov_is_claude() { [ "${1:-}" = claude ]; }
    mc_queue_conductor_only() { return 1; }
    mc_pr_queued() { return 1; }
    mc_pr_view() { echo "OPEN CLEAN"; }
    . "$HARNESS/bin/lib/block-gate.sh"
    . "$0"; . "$1"; . "$2"
    merge_retry 41 '"$H1"'' "$T/rstate.sh" "$T/rmerge.sh" "$T/rretry.sh" 2>>"$T/review.err" )
merged && bad "M: merge_retry landed a lead PR with no lead verdict ($(cat "$FX/merges"))" || ok
[ "$(jq -r '."41".merge_retries // 0' "$T/state.json")" = 0 ] && ok \
  || bad "M: a fenced retry must hand its attempt back (merge_retries=$(jq -r '."41".merge_retries' "$T/state.json"))"

# ============================================================================
# B. bin/run-build.sh's tier-1 merge gate, extracted and driven.
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the tier-1 merge gate — markers missing?"
run_gate() { # prints the RESULT line
  rm -f "$T/RESULT"; mkdir -p "$H/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$H/builds/gate/review.md"; : > "$H/builds/gate/pipeline.log"
  ( cd "$T" && BUILD="$H/builds/gate" ALERTS="$H/logs/ALERTS.log" \
      PROJECT=demo-os KEY=BH-$TICKET TICKET=$TICKET SLUG="$SLUG" TIER=1 PR_URL="$PRURL" \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" CLOSES_LINE="Closes #$TICKET" HEADBOUND_SHA="$H1" BUILDER_NO_MERGE= \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/block-gate.sh"
        . "$HARNESS/bin/lib/ticket-ownership.sh"
        . "$0"' "$T/gate.sh" >/dev/null 2>>"$T/gate.err" ) || true
  cat "$T/RESULT" 2>/dev/null
}
BLOG="$H/builds/gate/pipeline.log"

# B1. A HELD ticket: the tier-1 build does not merge its own PR.
reset "$BOT" held
OUT=$(run_gate)
merged && bad "B1: the tier-1 self-merge landed a PR for a HELD ticket ($(cat "$FX/merges"))" || ok
grep -q "^PR_CREATED $PRURL" <<<"$OUT" && ok || bad "B1: a held tier-1 build exits through PR_CREATED (got '$OUT')"
grep -q "MERGE_HELD.*held" "$BLOG" && ok || bad "B1: the build log names the hold: $(cat "$BLOG")"

# B2. Control: a clear ticket, a pool author: merges as today.
reset "$BOT"
OUT=$(run_gate)
merged && ok || bad "B2: a clear tier-1 pool PR must still self-merge (got '$OUT'; log $(cat "$BLOG"); err $(tail -3 "$T/gate.err" 2>/dev/null))"
grep -q "^PR_MERGED $PRURL" <<<"$OUT" && ok || bad "B2: PR_MERGED (got '$OUT')"

# B3. A lead-authored PR with the build's own APPROVE and no lead row: no merge.
reset "$LEAD"
OUT=$(run_gate)
merged && bad "B3: the tier-1 self-merge landed a LEAD PR on its own APPROVE ($(cat "$FX/merges"))" || ok
grep -q "^PR_CREATED $PRURL" <<<"$OUT" && ok || bad "B3: exits through PR_CREATED (got '$OUT')"
grep -q "MERGE_HELD.*lead" "$BLOG" && ok || bad "B3: the build log names the lead-PR rule: $(cat "$BLOG")"

# B4. A lead MERGE row on the exact live head: merges.
reset "$LEAD"; vd_put "$H1" MERGE lead
OUT=$(run_gate)
merged && ok || bad "B4: a lead MERGE on the live head lets the tier-1 gate merge the lead PR (got '$OUT'; log $(cat "$BLOG"))"

# B5. A lead MERGE row on an older head only: no merge.
reset "$LEAD"; vd_put "$H0" MERGE lead
OUT=$(run_gate)
merged && bad "B5: a lead MERGE on an earlier head must not merge the live one ($(cat "$FX/merges"))" || ok

# B6. Unreadable verdicts: no merge.
reset "$LEAD"; vd_put "$H1" MERGE lead; touch "$VD/down"
OUT=$(run_gate)
merged && bad "B6: an unreadable verdicts table must not let the tier-1 gate merge a lead PR ($(cat "$FX/merges"))" || ok

# B7 (F1). The fence reads H1 (verdict there), the branch moves to H2 before
# `gh pr merge`: the pinned merge is refused and the cleared lead PR does NOT
# fall through to the box merge queue.
reset "$LEAD"; vd_put "$H1" MERGE lead; printf '%s' "$H2" > "$FX/live-head"
OUT=$(run_gate)
merged && bad "B7 (F1): a lead verdict on H1 let the tier-1 gate merge live head H2 ($(cat "$FX/merges"))" || ok
grep -q -- "--match-head-commit $H1" "$FX/refused" 2>/dev/null && ok \
  || bad "B7 (F1): the tier-1 merge must be pinned to the head the fence read (refused: $(cat "$FX/refused" 2>/dev/null))"
[ -f "$H/state/merge-queue/demo-os/41" ] && bad "B7 (F1b): a cleared lead PR whose merge failed must not be enqueued on the box queue" || ok
grep -q "^PR_CREATED $PRURL" <<<"$OUT" && ok || bad "B7: exits through PR_CREATED (got '$OUT')"

# B8 (F2). A non-worker 404 on the lead row: the tier-1 gate does not merge.
reset "$LEAD"; vd_put "$H1" MERGE lead; touch "$VD/lead-404"
OUT=$(run_gate)
merged && bad "B8 (F2): a non-worker 404 on the lead row must not let the tier-1 gate merge ($(cat "$FX/merges"))" || ok

echo "lead-pr-fence.bh-1558: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
