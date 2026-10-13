#!/bin/bash
# tests/mc/merged-not-ejected.bh-4562-test.sh — BH-4562: A PR MERGIFY MERGED IS
# NEVER LOGGED EJECTED AND PARKED BLOCKED.
#
# THE INCIDENT (#4142, 02:02:34Z). Mergify landed a green batch. While it did, it
# dropped its queued/checking labels and moved its queue check, and GitHub had
# not set merged_at yet (it did at 02:02:35Z). The conductor's queue settle read
# the PR OPEN with no queue witness, counted a second ejection and parked the row
# BLOCKED_HUMAN queue-ejected-twice, handing a MERGED PR to the resolver. Nothing
# settled it after that: no issue close, no deploy request.
#
# THE RULE. Before the settle arm counts an ejection on Mergify it asks why the
# PR left (mc_queue_left_why, one uncached PR read + one check-runs read):
# merged settles, a check titled merged waits a tick, an unreadable answer waits,
# a stated reason (failure conclusion, `dequeued`) ejects as before, and no
# witness at all is held one tick per head. A row the race already parked is
# settled once GitHub says MERGED.
#
# Driven against the real bin/merge-conductor.sh and a stub gh whose pulls/<n>
# read answers from a per-read script ($T/pr-seq, line k = the k-th read, the
# last line repeats). One clock read (NOW).
# Run from anywhere: tests/mc/merged-not-ejected.bh-4562-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# gh-rest-etag.sh rides along on purpose: M10 pins that the confirm read skips
# the If-None-Match the cache would otherwise send.
for f in merge-conductor-lib gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list gh-rest-etag; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/"
done
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\nnatv example-org/natv-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/deploys.txt\nexit 0\n' "$T" > "$T/h/bin/deploy-request.sh"
chmod +x "$T/h/bin/"*.sh

H1=aaaaaaaa11112222333344445555666677778888
MSHA=eeeeeeee11112222333344445555666677778888
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# ---- fixture switches -------------------------------------------------------
# pr-seq   the state the k-th pulls/<n> read answers: OPEN | MERGED | CLOSED | 403
# checks   the check_runs array the check-runs read answers (JSON, no brackets)
# labels   the PR's labels, comma-separated
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nH1=%s\nMSHA=%s\n' "$T" "$MGFY_YML" "$H1" "$MSHA"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
LBL=$(cat "$T/labels" 2>/dev/null)
case "$*" in
  *"api -i -X GET repos/example-org/natv-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"name":"main","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/example-org/natv-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/natv-os/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    printf 'checks\n' >> "$T/reads.txt"
    restpr --raw 200 "{\"check_runs\":[$(cat "$T/checks" 2>/dev/null)]}" ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"api -X PATCH repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff ;;
  # Sub-resources by name: a bare "/pulls/*/" would also catch the ETag's W/"…".
  *"/pulls/"*"/files"*|*"/pulls/"*"/commits"*|*"/pulls/"*"/reviews"*|*"/pulls/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    # The k-th read answers line k of pr-seq; the list's own lazy reads do not
    # advance it. Every read records whether it carried the cache's If-None-Match.
    INM=0; case "$*" in *"If-None-Match"*) INM=1 ;; esac
    if [ "${HPL_READ_ROLE:-}" = list-lazy ]; then K=$(cat "$T/pr-n" 2>/dev/null || echo 0); [ "$K" -gt 0 ] || K=1
    else K=$(( $(cat "$T/pr-n" 2>/dev/null || echo 0) + 1 )); echo "$K" > "$T/pr-n"; fi
    ST=$(sed -n "${K}p" "$T/pr-seq"); [ -n "$ST" ] || ST=$(sed -n '$p' "$T/pr-seq")
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    printf 'pulls %s %s inm=%s role=%s pr=%s\n' "$K" "$ST" "$INM" "${HPL_READ_ROLE:-}" "$PN" >> "$T/reads.txt"
    case "$ST" in
      403) restpr --raw 403 '{"message":"Forbidden"}' ;;
      MERGED) restpr MERGED "$H1" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator "$MSHA" | sed "1a ETag: W/\"e$K\"" ;;
      *) restpr "$ST" "$H1" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator | sed "1a ETag: W/\"e$K\"" ;;
    esac ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
HO="$T/h/state/merge-conductor/handoff"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

mkrec() { # mkrec <repo> <num> <head>
  local d="$T/h/builds/pool-$1-X-$2-202610050000"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/$1-os/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_DETACHED_DEPLOY_VERIFY=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
nlines()    { grep -c "$@" 2>/dev/null || true; }
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
KN='example-org/natv-os#41'
UN=https://github.com/example-org/natv-os/pull/41
CK_MERGED='{"name":"Mergify Merge Queue","status":"completed","conclusion":"cancelled","output":{"title":"Merged via merge queue"}}'
CK_FAILED='{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":"Dequeued — checks failed"}}'

# reset_case <pr-seq lines...> — a QUEUED row on H1 that already has one counted
# ejection and one requeue, so the next counted ejection is the second (EJN=2):
# the incident's shape.
reset_case() {
  : > "$A"; : > "$CLOG"
  for f in gh-calls label-removes writes merges deploys reads; do : > "$T/$f.txt"; done
  : > "$T/labels"; : > "$T/checks"; rm -f "$T/pr-n"
  printf '%s\n' "$@" > "$T/pr-seq"
  rm -rf "$T/h/state/gh-etag" "$HO" "$T/h/state/merge-conductor/handoff-released" "$T/h/state/merge-conductor/closed-watch"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  mkrec mgfy 31 "$H1"
  mc_row_put "$K31" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$U31"
  echo "ejected $K31 $H1" >> "$A"
  echo "requeued $K31 $H1 $((NOW-600))" >> "$A"
}
strikes() { grep -cE "^(ejected|reejected) $K31 " "$A"; }
fresh_reads() { nlines -E "^pulls [0-9]+ [A-Z0-9]+ inm=0 role= pr=${1:-31}\$" "$T/reads.txt"; }

# ============================================================================
# M1 — merged during the dequeue (AT1): OPEN, OPEN, then MERGED on the confirm.
# ============================================================================
reset_case OPEN OPEN MERGED
run_tick
[ "$(state_of "$K31")" = MERGED ] && ok || bad "M1: a PR GitHub reports merged must settle MERGED (got $(state_of "$K31") '$(reason_of "$K31")')"
[ "$(strikes)" = 1 ] && ok || bad "M1: no new ejected/reejected line (attempts: $(cat "$A"))"
grep -q 'BLOCKED_' "$CLOG" && bad "M1: nothing may say BLOCKED for a merged PR ($(grep BLOCKED_ "$CLOG" | head -2))" || ok
grep -q 'EJECTED from the merge queue' "$CLOG" && bad "M1: and nothing may say EJECTED" || ok
[ -z "$(ls -A "$HO" 2>/dev/null)" ] && ok || bad "M1: no hand-off to the resolver ($(ls "$HO"))"
[ ! -s "$T/label-removes.txt" ] && ok || bad "M1: no label DELETE ($(cat "$T/label-removes.txt"))"
grep -q "$K31 left the merge queue MERGED" "$CLOG" && ok || bad "M1: the log says it left MERGED ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
grep -q "^deployreq $K31 $MSHA" "$A" && ok || bad "M1: the settle runs (deploy request recorded)"
# M10 — the confirm read is the third pulls read and it carries no If-None-Match.
grep -qE '^pulls 2 OPEN inm=1 role= pr=31$' "$T/reads.txt" && ok || bad "M10: the fixture must make the second read a cached one ($(cat "$T/reads.txt"))"
grep -qE '^pulls 3 MERGED inm=0 role= pr=31$' "$T/reads.txt" && ok || bad "M10: the confirm read must skip the ETag ($(cat "$T/reads.txt"))"

# ============================================================================
# M2 — merged between read #1 and read #2 (H1): no confirm read at all.
# ============================================================================
reset_case OPEN MERGED
run_tick
[ "$(state_of "$K31")" = MERGED ] && ok || bad "M2: QS=merged must settle MERGED (got $(state_of "$K31") '$(reason_of "$K31")')"
[ "$(strikes)" = 1 ] && ok || bad "M2: no new strike (attempts: $(cat "$A"))"
grep -q 'BLOCKED_\|EJECTED from the merge queue' "$CLOG" && bad "M2: no BLOCKED/EJECTED line" || ok
[ -z "$(ls -A "$HO" 2>/dev/null)" ] && ok || bad "M2: no hand-off"
[ ! -s "$T/label-removes.txt" ] && ok || bad "M2: no label DELETE"
[ "$(fresh_reads)" = 1 ] && ok || bad "M2: only the very first read is uncached — no extra confirm read ($(cat "$T/reads.txt"))"
grep -q 'checks' "$T/reads.txt" && bad "M2: and no check-runs read" || ok

# ============================================================================
# M3 — Mergify's check says merged, merged_at not set yet: wait, then settle.
# ============================================================================
reset_case OPEN
printf '%s' "$CK_MERGED" > "$T/checks"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "M3: a merged title with no merged_at keeps the row QUEUED (got $(state_of "$K31") '$(reason_of "$K31")')"
[ "$(strikes)" = 1 ] && ok || bad "M3: no strike for a merging PR (attempts: $(cat "$A"))"
grep -q "still QUEUED: Mergify's check says merged" "$CLOG" && ok || bad "M3: the log says why it waits ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
printf 'MERGED\n' > "$T/pr-seq"; rm -f "$T/pr-n"
run_tick
[ "$(state_of "$K31")" = MERGED ] && ok || bad "M3: the next tick settles it (got $(state_of "$K31"))"
[ "$(strikes)" = 1 ] && ok || bad "M3: still no strike (attempts: $(cat "$A"))"

# ============================================================================
# M4 — a real red batch ejects exactly as today (AT2).
# ============================================================================
reset_case OPEN
printf 'dequeued' > "$T/labels"
printf '%s' "$CK_FAILED" > "$T/checks"
run_tick
grep -qxF "reejected $K31 $H1" "$A" && ok || bad "M4: a real ejection after a requeue counts (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "M4: and parks BLOCKED_HUMAN (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "M4: on queue-ejected-twice (got '$(reason_of "$K31")')"
grep -q "$K31 EJECTED from the merge queue again" "$CLOG" && ok || bad "M4: with today's EJECTED … again line"
[ -s "$(mc_handoff_file "$K31")" ] && ok || bad "M4: and the hand-off is recorded"

# ============================================================================
# M5 — a merged PR the race already parked settles (AT3).
# ============================================================================
park_case() {
  reset_case "$@"
  : > "$T/h/state/merge-conductor/pr-state.tsv"
  echo "reejected $K31 $H1" >> "$A"
  mc_row_put "$K31" BLOCKED_HUMAN $((NOW-300)) "$H1" "$H1" - "queue-ejected-twice" "$U31"
  mc_handoff_record "$K31" "$H1" queue-ejected-twice "$U31"
}
park_case MERGED
run_tick
[ "$(state_of "$K31")" = MERGED ] && ok || bad "M5: a parked PR GitHub reports merged must settle (got $(state_of "$K31") '$(reason_of "$K31")')"
[ -s "$(mc_handoff_rel_file "$K31")" ] && ok || bad "M5: the hand-off is released"
grep -q "^deployreq $K31 $MSHA" "$A" && ok || bad "M5: mc_settle_merged ran (attempts: $(cat "$A"))"
[ "$(nlines -F "$MSHA" "$T/deploys.txt")" = 1 ] && ok || bad "M5: one deploy request ($(cat "$T/deploys.txt"))"
run_tick
[ "$(nlines -F "MERGED $K31 by conductor" "$CLOG")" = 1 ] && ok || bad "M5: a second tick settles nothing more ($(nlines -F "MERGED $K31 by conductor" "$CLOG"))"
[ "$(nlines -F "$MSHA" "$T/deploys.txt")" = 1 ] && ok || bad "M5: and requests no second deploy"

# ============================================================================
# M6 — parked and still open stays parked.
# ============================================================================
park_case OPEN
run_tick
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "M6: a parked open PR stays parked (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "M6: on its reason (got '$(reason_of "$K31")')"
[ ! -e "$(mc_handoff_rel_file "$K31")" ] && ok || bad "M6: and its hand-off is not released"

# ============================================================================
# M7 — no witness holds exactly one tick, then ejects as today.
# ============================================================================
reset_case OPEN
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "M7: tick 1 holds the row QUEUED (got $(state_of "$K31") '$(reason_of "$K31")')"
grep -qxF "qgone $K31 $H1" "$A" && ok || bad "M7: with one qgone mark (attempts: $(cat "$A"))"
[ "$(strikes)" = 1 ] && ok || bad "M7: and no new strike on tick 1"
run_tick
grep -qxF "reejected $K31 $H1" "$A" && ok || bad "M7: tick 2 counts the ejection (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "M7: and parks as today (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "M7: on queue-ejected-twice (got '$(reason_of "$K31")')"

# ============================================================================
# M8 — an unreadable confirm is not an ejection.
# ============================================================================
reset_case OPEN OPEN 403
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "M8: an unreadable confirm leaves the row QUEUED (got $(state_of "$K31") '$(reason_of "$K31")')"
[ "$(strikes)" = 1 ] && ok || bad "M8: no strike (attempts: $(cat "$A"))"
grep -q "^qgone " "$A" && bad "M8: and no hold mark" || ok
grep -q "$K31 still QUEUED: the dequeue could not be confirmed" "$CLOG" && ok || bad "M8: the log says so ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"

# ============================================================================
# M11 — a NEGATED merged title is not a landing. Mergify's `dequeued` label with
#       a neutral "cannot be merged" check is a real ejection, counted this
#       tick; read as `merging` it would hold the row QUEUED every tick.
# ============================================================================
reset_case OPEN
printf 'dequeued' > "$T/labels"
printf '%s' '{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","output":{"title":"The pull request cannot be merged"}}' > "$T/checks"
run_tick
grep -q "Mergify's check says merged" "$CLOG" && bad "M11: 'cannot be merged' must not read as merging" || ok
grep -qxF "reejected $K31 $H1" "$A" && ok || bad "M11: the dequeued label ejects this tick (attempts: $(cat "$A"))"

# ============================================================================
# M9 — the native provider never calls the confirm.
# ============================================================================
reset_case OPEN
: > "$T/h/state/merge-conductor/pr-state.tsv"; : > "$A"
mkrec natv 41 "$H1"
mc_row_put "$KN" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$UN"
run_tick
grep -q "natv-os.*check-runs" "$T/gh-calls.txt" && bad "M9: no check-runs read on the native queue" || ok
[ "$(fresh_reads 41)" -le 1 ] && ok || bad "M9: no uncached confirm read on the native queue ($(cat "$T/reads.txt"))"
[ "$(state_of "$KN")" = QUEUED ] && ok || bad "M9: unknown on the native queue leaves the row as-is (got $(state_of "$KN"))"
grep -q "^qgone " "$A" && bad "M9: and writes no hold mark" || ok

echo "merged-not-ejected.bh-4562: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
