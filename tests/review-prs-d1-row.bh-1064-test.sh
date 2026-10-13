#!/bin/bash
# BH-1064 — bin/review-prs.sh records its OWN verdict in the jobs ledger, on a
# row per paid review, so `/api/verdict?pr=…` can answer for an external PR this
# lane reviewed instead of only for harness BUILD PRs.
#
# Drives the REAL bin/review-prs.sh against a scratch $HARNESS with `gh`,
# `agent-call.sh` and a stubbed jobs-client. The stubbed functions are injected
# via BASH_ENV so review-prs sees them as shell functions (the same shape
# production uses, and the only shape that lets `job_lane_open` export JOB_ID
# back into the lane's shell).
#
# THE STUB MODELS THE DEPLOYED WORKER, NOT A CONVENIENT LEDGER. Artifacts are
# appended to one file and every read materialises them LAST-WRITE-WINS per
# (job_id, artifact_kind) — which is what
# worker/jobs/src/index.js does (`ON CONFLICT(job_id, artifact_kind) DO UPDATE`).
# A stub that kept every write would pass with one shared lane row per tick and
# prove nothing: N2 is exactly the case that shared row loses.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

PROJECT=project-1
SLUG=example-org/project-1
NUM=42
HEAD=head42sha42
STATE="$T/h/state/$PROJECT.pr-reviews.json"
STORE="$T/job-artifacts.tsv"
OPENLOG="$T/job-opens.tsv"

mkdir -p "$T/fakebin"

# The PR list each case wants, as the tsv `gh pr list … --jq` prints.
printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"pr list"*) cat "$TEST_ROOT/prs.tsv" ;;
  *"pr diff"*"name-only"*) printf 'lib/pricing.ts\n' ;;
  *"pr diff"*) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n' ;;
  *"pr view"*"mergeCommit"*) printf '{"mergeCommit":{"oid":"mergecommitsha"}}\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"%s"}\n' "${PR_MERGE_STATE:-CLEAN}" ;;
  *"pr view"*"comments,reviews"*) printf '{"comments":[],"reviews":[]}\n' ;;
  *"pr view"*"body"*) printf '{"body":"test body"}\n' ;;
  *"pr view"*"state"*) printf '{"state":"MERGED"}\n' ;;
  *"pr review"*|*"pr comment"*) : ;;
  *"pr merge"*) printf 'merged\n' ;;
  *"api"*) : ;;
esac
exit 0
STUB

# The reviewer. The verdict is per PR — the prompt's first line carries
# "(#<num> by …)" — so a tick reviewing two PRs produces two DIFFERENT verdicts
# and a row that picked up the wrong PR's judgement is visible, not plausible.
cat > "$T/fakebin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
PF="${6#@}"
N=$(sed -n '1s/.*(#\([0-9]*\) by .*/\1/p' "$PF" 2>/dev/null)
V=$(cat "$TEST_ROOT/verdict-$N" 2>/dev/null || echo APPROVE)
printf 'Static review of #%s.\nTIER: 2\nVERDICT: %s\n' "$N" "$V" > "$5"
printf 'claude\n' > "$5.runner"
STUB

cat > "$T/fakebin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$T/stub.sh" <<'STUB'
# job_lane_open <lane> <key> <kind> <meta> — the row id is derived from the KEY,
# which is the whole point: an empty key (the pre-BH-1064 shape) is ONE row for
# every PR of the tick, a per-review key is one row each.
job_lane_open() {
  printf '%s\t%s\n' "$1" "${2:-}" >> "$JOB_OPEN_LOG"
  local id="job-${2:-shared}"; id="${id//\//-}"; id="${id//@/-}"
  JOB_ID="$id"; export JOB_ID
  return 0
}
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() {
  local kind="$1" ref="$2" detail="${3:-}" job="${4:-${JOB_ID:-}}"
  [ -n "$kind" ] && [ -n "$ref" ] && [ -n "$job" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$job" "$kind" "$ref" "$detail" >> "$JOB_STORE"
  return 0
}
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
STUB

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  scratch_rm "$T/h" || return 1
  rm -f "$T/agent-calls.log" "$STORE" "$OPENLOG"
  mkdir -p "$T/h/bin" "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call.sh" "$T/fakebin/sleep"
  cp "$T/fakebin/agent-call.sh" "$T/h/bin/agent-call.sh"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" "$PROJECT"
  chmod +x "$T/h/bin/agent-call.sh"
  cp "$T/stub.sh" "$T/h/bin/stub.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/merge-queue.sh"; chmod +x "$T/h/bin/merge-queue.sh"
  printf '{}\n' > "$STATE"
}

calls() { if [ -f "$T/agent-calls.log" ]; then wc -l < "$T/agent-calls.log"; else echo 0; fi; }

# THE UPSERT. One surviving row per (job_id, artifact_kind), in first-written
# order — the worker's ON CONFLICT rule, spelled once.
store_final() {
  [ -f "$STORE" ] || return 0
  awk -F'\t' '{k=$1 FS $2; if (!(k in ord)) {ord[k]=NR}; row[k]=$0}
              END {for (k in row) printf "%s\t%s\n", ord[k], row[k]}' "$STORE" \
    | sort -n | cut -f2-
}
art_field() { # art_field <job> <kind> <col:3=ref|4=detail>
  store_final | awk -F'\t' -v j="$1" -v k="$2" -v c="$3" '$1==j && $2==k {print $c}'
}
artifact_count() { store_final | awk -F'\t' -v k="$1" '$2 == k {n++} END{print n+0}'; }
# detail_field <job> <kind> <jq-path> — one field out of a SURVIVING artifact's
# detail JSON, or "-" when the writer left it out. `/api/verdict` hands the
# verdict detail's `.record` to its callers verbatim
# (worker/jobs/src/index.js, `record: d.record !== undefined ? d.record : null`),
# and `job_verdict_headbound` reads `.headbound` out of the same blob — a field
# the writer omits reads as NOT MEASURED downstream, which is why the shape is
# asserted rather than assumed.
detail_field() {
  printf '%s' "$(art_field "$1" "$2" 4)" | jq -r "$3 // \"-\"" 2>/dev/null
}
# verdict_for_pr <pr-url> — GET /api/verdict?pr=, modelled: resolve the PR
# through a SURVIVING pr_url artifact, then read that job's verdict.
# Prints "<verdict>\t<reviewed_sha>\t<provenance>", rc 2 when the ledger has
# nothing to say about this PR (the worker's 404).
verdict_for_pr() {
  local pr="$1" job v d
  job=$(store_final | awk -F'\t' -v p="$pr" '$2=="pr_url" && $3==p {j=$1} END{print j}')
  [ -n "$job" ] || return 2
  v=$(art_field "$job" verdict 3)
  d=$(art_field "$job" verdict 4)
  [ -n "$v" ] || return 2
  printf '%s\t%s\t%s\n' "$v" \
    "$(printf '%s' "$d" | jq -r '.reviewed_sha // "-"' 2>/dev/null)" \
    "$(printf '%s' "$d" | jq -r '.provenance // "-"' 2>/dev/null)"
}

run_lane() {
  local rp="${1:-$RP}" extra_env="${2:-}"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" \
      TEST_ROOT="$T" JOB_STORE="$STORE" JOB_OPEN_LOG="$OPENLOG" \
      BASH_ENV="$T/h/bin/stub.sh" $extra_env
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$rp" "$PROJECT" >/dev/null 2>&1 )
  echo $?
}

# ── N1 — a paid review writes verdict + pr_url on a row keyed to THIS head ───
fresh_harness
printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"
RC=$(run_lane)
[ "$RC" -eq 0 ] && ok || bad "N1 exited $RC, expected 0"
[ "$(calls)" -eq 1 ] && ok || bad "N1 made $(calls) agent-call invocations, expected 1"
[ "$(jq -r --arg n "$NUM" '.[$n].verdict // ""' "$STATE")" = "APPROVE" ] \
  && ok || bad "N1 state verdict mismatch: $(cat "$STATE")"
[ "$(awk -F'\t' 'NR==1{print $2}' "$OPENLOG")" = "review/$PROJECT/$NUM@$HEAD" ] \
  && ok || bad "N1 claimed key '$(awk -F'\t' 'NR==1{print $2}' "$OPENLOG")', expected review/$PROJECT/$NUM@$HEAD"
[ "$(awk -F'\t' 'NR==1{print $1}' "$OPENLOG")" = "review/$PROJECT/claude" ] \
  && ok || bad "N1 changed the lane string: $(cat "$OPENLOG")"
[ "$(artifact_count pr_url)" -eq 1 ] \
  && ok || bad "N1 left $(artifact_count pr_url) pr_url artifacts, expected 1"
[ "$(artifact_count verdict)" -eq 1 ] \
  && ok || bad "N1 left $(artifact_count verdict) verdict artifacts, expected 1"
ROW=$(verdict_for_pr "https://github.com/$SLUG/pull/$NUM") \
  && ok || bad "N1 /api/verdict could not resolve #$NUM: $(store_final)"
[ "$ROW" = "$(printf 'APPROVE\t%s\tclaude' "$HEAD")" ] \
  && ok || bad "N1 verdict row '$ROW', expected APPROVE/$HEAD/claude"
# The verdict is written BEFORE the pr_url that makes the row findable, so a
# half-written pair is unfindable rather than mis-attributed.
[ "$(awk -F'\t' '$2=="verdict"||$2=="pr_url" {print $2; exit}' "$STORE")" = verdict ] \
  && ok || bad "N1 wrote pr_url before verdict — a reader can resolve a row with no verdict on it"
# The detail fields the fleet reads off these rows. `record` is what
# /api/verdict hands back as the pointer to the work that produced the verdict;
# with it omitted an operator resolving an external PR gets `null`, which every
# consumer reads as NOT MEASURED. `lane` says which lane bought it, and
# `headbound` is the head-bound gate's word — `n/a` here, because this lane runs
# no such gate, and that is a real answer where silence is not.
N1JOB="job-review-$PROJECT-$NUM-$HEAD"
[ "$(detail_field "$N1JOB" verdict .record)" = "review-prs:$PROJECT:$NUM" ] \
  && ok || bad "N1 verdict detail record='$(detail_field "$N1JOB" verdict .record)', expected review-prs:$PROJECT:$NUM"
[ "$(detail_field "$N1JOB" verdict .headbound)" = "n/a" ] \
  && ok || bad "N1 verdict detail headbound='$(detail_field "$N1JOB" verdict .headbound)', expected n/a"
[ "$(detail_field "$N1JOB" verdict .settled)" = "true" ] \
  && ok || bad "N1 verdict detail settled='$(detail_field "$N1JOB" verdict .settled)', expected true"
[ "$(detail_field "$N1JOB" pr_url .record)" = "review-prs:$PROJECT:$NUM" ] \
  && ok || bad "N1 pr_url detail record='$(detail_field "$N1JOB" pr_url .record)', expected review-prs:$PROJECT:$NUM"
[ "$(detail_field "$N1JOB" pr_url .lane)" = "review-prs" ] \
  && ok || bad "N1 pr_url detail lane='$(detail_field "$N1JOB" pr_url .lane)', expected review-prs"

# ── N2 — two PRs in ONE tick each keep their own row ─────────────────────────
# The shared per-tick row upserts both pairs onto one (job_id, artifact_kind),
# so #7's pr_url and verdict are overwritten by #9's: #7 becomes unfindable and
# whatever IS found is bound to the wrong head. RED before the per-review row.
fresh_harness
printf '7\thead7sha7\texternaldev\tPR seven\n9\thead9sha9\texternaldev\tPR nine\n' > "$T/prs.tsv"
printf 'APPROVE\n' > "$T/verdict-7"
printf 'REQUEST_CHANGES\n' > "$T/verdict-9"
RC=$(run_lane "$RP" "PR_MERGE_STATE=BLOCKED")
[ "$RC" -eq 0 ] && ok || bad "N2 exited $RC, expected 0"
[ "$(calls)" -eq 2 ] && ok || bad "N2 made $(calls) agent-call invocations, expected 2"
[ "$(awk -F'\t' '{print $2}' "$OPENLOG" | sort -u | wc -l)" -eq 2 ] \
  && ok || bad "N2 opened $(awk -F'\t' '{print $2}' "$OPENLOG" | sort -u | wc -l) distinct job keys, expected 2: $(cat "$OPENLOG")"
R7=$(verdict_for_pr "https://github.com/$SLUG/pull/7") \
  && ok || bad "N2 /api/verdict lost #7 — the tick's later PR overwrote its row: $(store_final)"
[ "${R7:-}" = "$(printf 'APPROVE\thead7sha7\tclaude')" ] \
  && ok || bad "N2 #7 row '${R7:-}', expected APPROVE/head7sha7/claude"
R9=$(verdict_for_pr "https://github.com/$SLUG/pull/9") \
  && ok || bad "N2 /api/verdict lost #9: $(store_final)"
[ "${R9:-}" = "$(printf 'REQUEST_CHANGES\thead9sha9\tclaude')" ] \
  && ok || bad "N2 #9 row '${R9:-}', expected REQUEST_CHANGES/head9sha9/claude"
[ "$(artifact_count verdict)" -eq 2 ] \
  && ok || bad "N2 left $(artifact_count verdict) surviving verdict artifacts, expected 2 (one per PR)"
# The pointer on each row names ITS OWN PR: a record that said `#9` on #7's row
# would send an operator reading /api/verdict for #7 to the wrong review.
[ "$(detail_field job-review-"$PROJECT"-7-head7sha7 verdict .record)" = "review-prs:$PROJECT:7" ] \
  && ok || bad "N2 #7 verdict record='$(detail_field job-review-"$PROJECT"-7-head7sha7 verdict .record)', expected review-prs:$PROJECT:7"
[ "$(detail_field job-review-"$PROJECT"-9-head9sha9 verdict .record)" = "review-prs:$PROJECT:9" ] \
  && ok || bad "N2 #9 verdict record='$(detail_field job-review-"$PROJECT"-9-head9sha9 verdict .record)', expected review-prs:$PROJECT:9"
rm -f "$T/verdict-7" "$T/verdict-9"

# ── N3 — a re-review of a NEW head claims a new key, the old one is untouched ─
fresh_harness
printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"
run_lane >/dev/null
printf '%s\thead42sha99\texternaldev\tTest PR\n' "$NUM" > "$T/prs.tsv"
printf '{}\n' > "$STATE"      # the head moved as far as this lane is concerned
run_lane >/dev/null
[ "$(awk -F'\t' '{print $2}' "$OPENLOG" | sort -u | wc -l)" -eq 2 ] \
  && ok || bad "N3 reviewed two heads under $(awk -F'\t' '{print $2}' "$OPENLOG" | sort -u | wc -l) key(s): $(cat "$OPENLOG")"
grep -q "review/$PROJECT/$NUM@head42sha99" "$OPENLOG" \
  && ok || bad "N3 second head did not claim its own key: $(cat "$OPENLOG")"
R=$(verdict_for_pr "https://github.com/$SLUG/pull/$NUM")
[ "$R" = "$(printf 'APPROVE\thead42sha99\tclaude')" ] \
  && ok || bad "N3 /api/verdict answers '$R', expected the NEWEST head (head42sha99)"

# ── N4 — mutation: with the artifact block removed, nothing is written ───────
fresh_harness
printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"
mkdir -p "$T/mutant/bin/lib"
cp "$DIR/bin/fleet-conf.sh" "$T/mutant/bin/fleet-conf.sh"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/mutant/bin/lib/gh-pr-list.sh"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/mutant/bin/lib/"
cp "$DIR/bin/lib/gh-pr-create.sh" "$T/mutant/bin/lib/gh-pr-create.sh" 2>/dev/null || true
awk '/^# >>> review-prs d1 artifacts/{skip=1;next} /^# <<< review-prs d1 artifacts/{skip=0;next} skip==0{print}' \
  "$RP" > "$T/mutant/bin/review-prs.sh"
chmod +x "$T/mutant/bin/review-prs.sh"
RC=$(run_lane "$T/mutant/bin/review-prs.sh")
[ "$RC" -eq 0 ] && ok || bad "N4 mutant exited $RC, expected 0"
[ "$(calls)" -eq 1 ] && ok || bad "N4 mutant made $(calls) agent-call invocations, expected 1 (review still ran)"
[ "$(artifact_count pr_url)" -eq 0 ] && ok || bad "N4 mutant wrote pr_url artifacts with the block removed"
[ "$(artifact_count verdict)" -eq 0 ] && ok || bad "N4 mutant wrote verdict artifacts with the block removed"

echo "review-prs-d1-row (BH-1064): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
