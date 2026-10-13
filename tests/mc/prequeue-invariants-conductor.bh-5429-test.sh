#!/bin/bash
# tests/mc/prequeue-invariants-conductor.bh-5429-test.sh — BH-5439 (#5429): an
# invariant red parks with its evidence. The prequeue-gate workflow prints
# `red ... why=invariant:<ids>` plus prequeue-invariant-timing|fail|slow
# annotations; the hub reads them into sidecars next to the cache entry
# (bin/lib/mc-prequeue.d/dispatch.sh pq_read_run), names the invariant in the
# park reason and posts ONE evidence comment per (PR, head, main)
# (bin/merge-conductor.sh + bin/lib/mc-prequeue.d/red-comment.sh), and the
# resolver brief adds one sentence (bin/blocked-resolver.sh br_prequeue_brief).
#
#   K1   invariant red: parked with the invariant reason, sidecars written;
#        K1-prune ages them out, K1-sib dispatches nothing extra for them
#   K2   one comment POST with suite, fenced FAIL lines, marker, repro, no em
#        dash; a later tick posts none. K2-empty: no fail lines, no POST, park.
#        K2-rc75: a refused POST is one log line, the park still happens.
#        K2-nocat: an id with no catalog row is named as missing, no repro
#   K3   a red without why: today's reason byte for byte, no POST, no sidecar;
#        K3b a cached red with no sidecars reads the same
#   K4   br_prequeue_brief adds the catalog sentence only for an invariant park
#   K5   a green run with a timing annotation: one PREQUEUE_INVARIANTS line
#
# Driven, not grepped: every K1-K3/K5 case runs bin/merge-conductor.sh WHOLE in
# a scratch tree with the real tracer and the real hooks, against a stub gh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/prequeue-invariants-conductor.bh-5429-test.sh
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
[ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/red-comment.sh" ] && [ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/blocked-resolver.sh" ] \
  || bad "setup: bin/lib/mc-prequeue.d/red-comment.sh (or a sibling) is missing"   # impact: bin/lib/mc-prequeue.d/dispatch.sh bin/lib/mc-prequeue.d/red-comment.sh bin/merge-conductor.sh bin/blocked-resolver.sh

NOW=$(date +%s)
SLUG=example-org/demo-os
U="https://github.com/$SLUG/pull"
NUM=41
SUITE=tests/share-mirror-clean-test.sh

# ── a real origin that never leaves this box ─────────────────────────────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
S="$T/seed"; git init -q --bare "$T/origin.git"; git init -q "$S"
echo one > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm A; MA=$(git -C "$S" rev-parse HEAD)
echo y > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm h1; H1=$(git -C "$S" rev-parse HEAD)
git -C "$S" reset -q --hard "$MA"; echo two > "$S/x.txt"; git -C "$S" commit -qam M; M=$(git -C "$S" rev-parse HEAD)
git -C "$S" push -q "$T/origin.git" "$M:refs/heads/main" "$H1:refs/pull/41/head" || exit 1

# ── the scratch harness: the conductor's whole closure, two libs stubbed ─────
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/h/catalog" "$T/fakebin" "$T/repos"
cat > "$T/h/bin/lib/ticket-ownership.sh" <<'EOF'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
cat > "$T/h/bin/lib/block-gate.sh" <<'EOF'
bg_enforce() { return 1; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { :; }
bg_reason() { :; }
bg_refuse() { return 0; }
EOF
: > "$T/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
# The closure carries bin/lib/mc-prequeue.d/red-comment.sh: the tracer sources that directory by glob.
[ -r "$T/h/bin/lib/mc-prequeue.d/red-comment.sh" ] || bad "setup: the conductor closure does not carry bin/lib/mc-prequeue.d/red-comment.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/catalog/prequeue-invariants.tsv" "$T/h/catalog/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
MCD="$T/h/state/merge-conductor"

# The stub gh. The runs list is $T/runs.json, run 77's jobs $T/jobs.json, check
# run 88's annotations $T/ann.json. A `-F body=@<file>` comment POST (the
# evidence comment) logs its argv to $T/comments.txt, copies the body to
# $T/comment-<k>.md, and answers 201, or the status in $T/comment.status.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=$NUM
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*) printf '%s\n' "\$*" >> "$T/dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*) restpr --raw 200 "\$(cat "$T/runs.json")" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/actions/runs/77/jobs"*) restpr --raw 200 "\$(cat "$T/jobs.json")" ;;
  *"api -i -X GET repos/$SLUG/check-runs/88/annotations"*) restpr --raw 200 "\$(cat "$T/ann.json")" ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$(cat "$T/main")\"}" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/\$N/comments -F body=@"*)
    k=\$(( \$(wc -l < "$T/comments.txt") + 1 )); printf '%s\n' "\$*" >> "$T/comments.txt"
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment-\$k.md" ;; esac; done
    st=\$(cat "$T/comment.status" 2>/dev/null || echo 201)
    if [ "\$st" = 201 ]; then restpr --raw 201 '{"id":555}'; else restpr --raw "\$st" '{"message":"API rate limit exceeded"}'; fi ;;
  *"api -i -X POST repos/$SLUG/issues/\$N/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*) restpr OPEN "$H1" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":%s,"url":"$U/%s","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' "\$N" "\$N" "$H1" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

MCLOG="$T/h/logs/merge-conductor.log"
ROWS="$MCD/pr-state.tsv"
PQD="$MCD/prequeue"
P41="$PQD/example-org_demo-os_${NUM}_${H1}_$M"
# reset — #41 approved and green at H1, a fresh state, no runs, no comments.
# KEEP=1 keeps the verdict store (a later tick of the same key, re-asked from
# READY); MAIN=<sha> moves main from M.
reset() {
  if [ "${KEEP:-0}" = 1 ]; then rm -rf "$T/keep"; mkdir -p "$T/keep"; cp -a "$PQD" "$T/keep/pq" 2>/dev/null; fi
  rm -f "$T/tick.err" "$T/comment.status" "$T"/comment-*.md
  : > "$T/c-enq.txt"; : > "$T/comments.txt"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"; scratch_rm "$T/h/tmp/conductor"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  if [ "${KEEP:-0}" = 1 ]; then [ -d "$T/keep/pq" ] && cp -a "$T/keep/pq" "$PQD"
  else
    : > "$T/dispatch.txt"; echo '{"workflow_runs":[]}' > "$T/runs.json"; echo '[]' > "$T/ann.json"
    echo '{"jobs":[{"id":88,"name":"gate"}]}' > "$T/jobs.json"
  fi
  echo "${MAIN:-$M}" > "$T/main"
  echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$T/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# put <state> <dispatched_at> [suites] — the (#41, H1, M) cache entry, through the tracer's writer.
put() {
  ( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    pq_cache_put "$(pq_key "$SLUG" "$NUM" "$H1" "$M")" "$1" "$2" - "${3:-}" ) || bad "fixture: pq_cache_put failed for $*"
}
# run — run 77 completed success, titled exactly as the dispatcher titles (#41, H1, M).
run() {
  jq -nc --arg t "prequeue pr=$NUM head=$H1 main=$M" '{workflow_runs:[{id:77,display_title:$t,status:"completed",conclusion:"success",created_at:"2026-10-05T01:00:00Z"}]}' > "$T/runs.json"
}
# ann <title=message>... — the annotations on job 88, plus one unrelated.
ann() {
  local a
  { printf '%s\n' '{"title":"other","message":"x"}'
    for a in "$@"; do jq -nc --arg t "${a%%=*}" --arg m "${a#*=}" '{title:$t,message:$m,annotation_level:"notice"}'; done; } | jq -sc . > "$T/ann.json"
}
VRED="prequeue-verdict=red main=$M head=$H1 suites=$SUITE why=invariant:share-mirror-clean"
VFAIL="prequeue-invariant-fail=share-mirror-clean: FAIL: leak in docs/x.md
FAIL: second line"
VTIME="prequeue-invariant-timing=prequeue-invariants: total 512s wall 140s (11 ran)"
VSLOW="prequeue-invariant-slow=prequeue-invariant-slow: lanes-registry 300s over its 206s estimate"
K() { printf '%s#%s' "$SLUG" "$NUM"; }
state()  { awk -F'\t' -v k="$(K)" '$1==k {print $2}' "$ROWS"; }
reason() { awk -F'\t' -v k="$(K)" '$1==k {print $7}' "$ROWS"; }
enq()    { grep -c "issues/$NUM/comments\|issues/$NUM/labels\|pulls/$NUM/merge\|pr merge $U/$NUM" "$T/c-enq.txt" 2>/dev/null || true; }
ndisp()  { grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null || true; }
nposts() { grep -c "issues/$NUM/comments" "$T/comments.txt" 2>/dev/null || true; }
clog()   { grep -F "$(K)" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }
REASON_INV="prequeue-red: $SUITE on main ${M:0:12} — invariant:share-mirror-clean: the head merged onto current main fails them"
REASON_A="prequeue-red: tests/a.sh on main ${M:0:12} — the head merged onto current main fails them"
parked() { # parked <case> <exact reason>
  [ "$(state)" = BLOCKED_HUMAN ] && ok || bad "$1: parked BLOCKED_HUMAN (state '$(state)'; err: $(tail -3 "$T/tick.err"); log: $(clog))"
  [ "$(reason)" = "$2" ] && ok || bad "$1: the park reason (got '$(reason)', want '$2')"
  [ "$(enq)" = 0 ] && ok || bad "$1: nothing enqueued (argv: $(cat "$T/c-enq.txt"))"
}

# ============================================================================
# K1. Tick 1 dispatches; tick 2 reads the invariant red and its annotations.
# ============================================================================
reset; tick
[ "$(ndisp)" = 1 ] && ok || bad "K1: tick 1 dispatches once (got $(ndisp); err: $(tail -3 "$T/tick.err"))"
KEEP=1 reset; run; ann "$VRED" "$VFAIL" "$VTIME" "$VSLOW"; tick
parked K1 "$REASON_INV"
[ "$(cat "$P41.why" 2>/dev/null)" = "invariant:share-mirror-clean" ] && ok || bad "K1: .why sidecar (got '$(cat "$P41.why" 2>/dev/null)')"
[ "$(cat "$P41.fail" 2>/dev/null)" = "$(printf '### share-mirror-clean\nFAIL: leak in docs/x.md\nFAIL: second line')" ] && ok \
  || bad "K1: .fail sidecar is one block per id (got '$(cat "$P41.fail" 2>/dev/null)')"
[ "$(sed -n 1p "$P41.timing" 2>/dev/null)" = "prequeue-invariants: total 512s wall 140s (11 ran)" ] && ok || bad "K1: .timing line 1 is the total (got '$(cat "$P41.timing" 2>/dev/null)')"
[ "$(sed -n 2p "$P41.timing" 2>/dev/null)" = "prequeue-invariant-slow: lanes-registry 300s over its 206s estimate" ] && ok || bad "K1: .timing line 2 is the slow line (got '$(cat "$P41.timing" 2>/dev/null)')"
case "$(head -n1 "$P41" 2>/dev/null)" in "red "*" 77 $SUITE") ok ;; *) bad "K1: the cache entry is unchanged in shape (got '$(head -n1 "$P41" 2>/dev/null)')" ;; esac
grep -q '\.tmp\.' <<<"$(ls "$PQD")" && bad "K1: no tmp file is left behind ($(ls "$PQD"))" || ok
# K1-sib: with the sidecars on disk, a later tick of the same key is the exact
# red hit: no extra dispatch, still parked, no hold.
KEEP=1 reset; tick
[ "$(ndisp)" = 1 ] && ok || bad "K1-sib: the sidecars cause no second dispatch (got $(ndisp): $(cat "$T/dispatch.txt"))"
parked K1-sib "$REASON_INV"
# ...and a miss for the same head on another main walks the siblings: a sidecar
# is not a 40-hex main, so only the real entry counts (a red, no dispatch).
MNEW=$(printf 'e%.0s' $(seq 40))
( MC_STATE_DIR="$MCD" MC_H="$T/h" P=demo MC_PREQUEUE_REUSE=0 PQ_MAIN="" PQ_SUITES="" PQ_PATH=""
  mc_log() { echo "$*" >> "$T/sib.log"; }
  mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
  pq_dispatch() { echo "DISPATCH $*" >> "$T/sib.log"; return 0; }
  . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1
  pq_wf_present() { _pq_wf=yes; }
  pq_resolve "$SLUG" "$NUM" "$U/$NUM" "$H1" "$MNEW" "$(pq_key "$SLUG" "$NUM" "$H1" "$MNEW")" > "$T/sib.out" 2>&1
  printf '%s|%s\n' "$(tail -n1 "$T/sib.out")" "$PQ_PATH" > "$T/sib.res" )
[ "$(cat "$T/sib.res")" = "red|$P41" ] && ok || bad "K1-sib: the sibling loop reads the entry, not its sidecars (got '$(cat "$T/sib.res")'; $(cat "$T/sib.log" 2>/dev/null))"
grep -q DISPATCH "$T/sib.log" 2>/dev/null && bad "K1-sib: no dispatch from a sidecar" || ok
# K1-prune: an 8-day-old sidecar ages out with its entry. Main moved, so the
# tick is a miss and the hook runs pq_prune.
for f in "$P41" "$P41.why" "$P41.fail" "$P41.timing"; do touch -d "@$((NOW - 8 * 86400))" "$f"; done
KEEP=1 MAIN="$MNEW" reset; tick
for f in "$P41" "$P41.why" "$P41.fail" "$P41.timing"; do [ -e "$f" ] && bad "K1-prune: $f pruned at 8 days ($(ls "$PQD"))" || ok; done
[ "$(ndisp)" = 2 ] && ok || bad "K1-prune: the miss on the new main dispatches (got $(ndisp))"

# ============================================================================
# K2. One evidence comment; none on a later tick.
# ============================================================================
reset; put pending $((NOW - 60)); run; ann "$VRED" "$VFAIL" "$VTIME"; tick
parked K2 "$REASON_INV"
[ "$(nposts)" = 1 ] && ok || bad "K2: exactly one comment POST (got $(nposts): $(cat "$T/comments.txt"); log: $(clog))"
B="$T/comment-1.md"
grep -qF "\`$SUITE\`" "$B" 2>/dev/null && ok || bad "K2: the body names the suite ($(cat "$B" 2>/dev/null))"
grep -qF '**share-mirror-clean**' "$B" 2>/dev/null && ok || bad "K2: the body names the id"
awk '/^```text$/{f=1;next} f&&/^```$/{exit} f' "$B" 2>/dev/null > "$T/fence"
[ "$(cat "$T/fence")" = "$(printf 'FAIL: leak in docs/x.md\nFAIL: second line')" ] && ok || bad "K2: both FAIL lines in a text fence (got '$(cat "$T/fence")')"
grep -qxF "<!-- prequeue-invariant:$H1:$M -->" "$B" 2>/dev/null && ok || bad "K2: the marker line"
grep -qF "To reproduce: \`git merge origin/main && HARNESS_TEST_SANDBOX=1 bash $SUITE\`" "$B" 2>/dev/null && ok || bad "K2: the repro line"
grep -qF "Head ${H1:0:8} merged onto main ${M:0:12} fails 1 whole-repo invariant suite" "$B" 2>/dev/null && ok || bad "K2: the opener names head, main and count"
[ "$(grep -c '—' "$B" 2>/dev/null)" = 0 ] && ok || bad "K2: no em dash in the body"
grep -q "prequeue invariant comment posted.*share-mirror-clean" "$MCLOG" 2>/dev/null && ok || bad "K2: one log line names the posted ids (log: $(clog))"
# A later tick of the same (PR, head, main), the attempt ledger kept: no second POST.
cp "$MCD/attempts.txt" "$T/att.keep" 2>/dev/null
KEEP=1 reset; cp "$T/att.keep" "$MCD/attempts.txt" 2>/dev/null; tick
parked "K2 tick 3" "$REASON_INV"
[ "$(nposts)" = 0 ] && ok || bad "K2: a later tick posts nothing (got $(nposts))"

# K2-empty: an invariant red with no fail annotation: no POST, one log line, park.
reset; put pending $((NOW - 60)); run; ann "$VRED" "$VTIME"; tick
parked K2-empty "$REASON_INV"
[ "$(nposts)" = 0 ] && ok || bad "K2-empty: no POST without fail lines (got $(nposts))"
[ "$(grep -c 'invariant red with no fail lines, no comment' "$MCLOG" 2>/dev/null)" = 1 ] && ok || bad "K2-empty: one log line (log: $(clog))"

# K2-rc75: the POST is refused: one log line with the rc, park, no retry.
reset; put pending $((NOW - 60)); run; ann "$VRED" "$VFAIL"; echo 403 > "$T/comment.status"; tick
parked K2-rc75 "$REASON_INV"
[ "$(nposts)" = 1 ] && ok || bad "K2-rc75: one POST attempt (got $(nposts))"
[ "$(grep -c 'prequeue invariant comment NOT posted.*rc 75' "$MCLOG" 2>/dev/null)" = 1 ] && ok || bad "K2-rc75: one log line names rc 75 (log: $(clog))"
grep -q 'prequeue invariant comment posted' "$MCLOG" 2>/dev/null && bad "K2-rc75: a refused POST is never logged as posted" || ok
cp "$MCD/attempts.txt" "$T/att.keep" 2>/dev/null
KEEP=1 reset; cp "$T/att.keep" "$MCD/attempts.txt" 2>/dev/null; tick
[ "$(nposts)" = 0 ] && ok || bad "K2-rc75: the next tick does not retry (got $(nposts))"
parked "K2-rc75 tick 2" "$REASON_INV"

# K2-nocat: an id with no catalog row is named as missing, with no repro line.
reset; put pending $((NOW - 60)); run
ann "prequeue-verdict=red main=$M head=$H1 suites=$SUITE,tests/zz.sh why=invariant:share-mirror-clean,no-such-inv" "$VFAIL" "prequeue-invariant-fail=no-such-inv: FAIL: boom"
tick
[ "$(nposts)" = 1 ] && ok || bad "K2-nocat: one POST (got $(nposts); log: $(clog))"
B="$T/comment-1.md"
grep -qF '**no-such-inv** (no catalog row on the hub for no-such-inv)' "$B" 2>/dev/null && ok || bad "K2-nocat: the missing row is named ($(cat "$B" 2>/dev/null))"
[ "$(grep -c '^To reproduce:' "$B" 2>/dev/null)" = 1 ] && ok || bad "K2-nocat: only the catalogued id gets a repro line"
grep -qF 'fails 2 whole-repo invariant suites' "$B" 2>/dev/null && ok || bad "K2-nocat: the opener counts 2"

# ============================================================================
# K3. A red without why: today's reason, byte for byte; no POST, no sidecar.
# ============================================================================
reset; put pending $((NOW - 60)); run; ann "prequeue-verdict=red main=$M head=$H1 suites=tests/a.sh" "$VFAIL"; tick
parked K3 "$REASON_A"
[ "$(nposts)" = 0 ] && ok || bad "K3: no POST for a red without why (got $(nposts))"
[ -e "$P41.why" ] && bad "K3: no .why sidecar for a red without why" || ok
# K3b: a cached red with no sidecars, read on a later tick.
reset; put red $((NOW - 60)) tests/a.sh; tick
parked K3b "$REASON_A"
[ "$(nposts)" = 0 ] && ok || bad "K3b: no POST (got $(nposts))"

# ============================================================================
# K4. br_prequeue_brief, extracted by name.
# ============================================================================
awk '/^br_prequeue_brief\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brief.sh"
b=$( . "$T/brief.sh" && br_prequeue_brief "$REASON_INV" )
case "$b" in *"$SUITE"*) ok ;; *) bad "K4: the brief names the suite (got '$b')" ;; esac
case "$b" in *"current main ${M:0:12}: "*) ok ;; *) bad "K4: the brief names the 12-char main (got '$b')" ;; esac
case "$b" in *"catalog/prequeue-invariants.tsv"*) ok ;; *) bad "K4: the brief names the catalog for an invariant park (got '$b')" ;; esac
case "$b" in *"current main ${M:0:12}: $SUITE. Merge"*) ok ;; *) bad "K4: the suite parse is unchanged (got '$b')" ;; esac
b=$( . "$T/brief.sh" && br_prequeue_brief "$REASON_A" )
case "$b" in *"catalog/prequeue-invariants.tsv"*) bad "K4: no catalog sentence for a plain red (got '$b')" ;; *) ok ;; esac

# ============================================================================
# K5. A green run with a timing annotation: one PREQUEUE_INVARIANTS line.
# ============================================================================
reset; put pending $((NOW - 60)); run; ann "prequeue-verdict=green main=$M head=$H1 suites=" "$VTIME"; tick
[ "$(grep -c "$SLUG#$NUM PREQUEUE_INVARIANTS head ${H1:0:8} main ${M:0:12}: prequeue-invariants: total" "$MCLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "K5: exactly one PREQUEUE_INVARIANTS line (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"
[ "$(nposts)" = 0 ] && ok || bad "K5: no POST on a green (got $(nposts))"
[ "$(enq)" -ge 1 ] && ok || bad "K5: the green head is enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state)'; log: $(clog))"
[ -e "$P41.why" ] && bad "K5: no .why sidecar on a green" || ok

echo "prequeue-invariants-conductor.bh-5429: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
