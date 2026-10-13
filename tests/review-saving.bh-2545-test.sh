#!/bin/bash
# tests/review-saving.bh-2545-test.sh — trivial diff classes get a cheap-model
# route, and every review the harness skips (patch-id reuse) or cheapens (the
# trivial route) is a stage_events row (BH-2545).
#
# The lib under test is "$DIR/bin/lib/review-saving.sh"; its three knobs are
# registered in "$DIR/catalog/lanes.d/_lib.review-saving.json".
#
#   C   review_diff_class: docs / lock / tests positives with exact line counts,
#       and every adversarial negative (agent instructions, CI, guard inputs,
#       mixes, renames out of code, unparseable input, over the cap) is `code`
#   K   the knobs: registry default (shadow, 200, docs), a bad mode, a bad max
#       or a bad route class is off and logged, max 0 makes nothing trivial
#   P   review_trivial_pick: shadow keeps the model, route takes model_for's
#       answer, route with no answer keeps the default, and a class outside
#       REVIEW_TRIVIAL_ROUTE_CLASSES (tests, lock by default) is shadow only
#   L   the REAL bin/review-prs.sh: the model the fake agent-call receives per
#       class and mode, the tick-default reset, and a routed TIER 1 capped at 2.
#   M   a routed APPROVE merges nothing: against a control that DOES reach
#       gh pr merge, it posts a comment review, reaches no merge, is refused by
#       merge_retry, and is re-reviewed on the full model next tick (which merges)
#       The REAL bin/review-autopilot.sh: measured (TRIVIAL_SHADOW), never routed
#   R   REUSED events from the three patch-id reuse sites (the real review-prs
#       and autopilot replays, the real settle.sh rebind_patch_id), fail-open on
#       a refused or failed job_open, and JOB_ID never touched
#   Z   no model literal in the lib; both new files named here by rooted path
# Run from anywhere: bash tests/review-saving.bh-2545-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/review-saving.sh"
REGF="$DIR/catalog/lanes.d/_lib.review-saving.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
# Hermetic: with a secret in the environment the model resolver asks the real
# worker, which answers for review.trivial on its own terms and clears the cache.
unset HARNESS_SECRET JOBS_URL

# ---------------------------------------------------------------------------
# Diff fixtures. mkdiff <file> <path>... — one file section per path, each with
# a real header pair and a hunk of 3 changed lines (2 added, 1 removed), so a
# diff of N paths is 3N lines exactly.
mkdiff() {
  local f="$1" p; shift; : > "$f"
  for p in "$@"; do
    printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n@@ -1,2 +1,3 @@\n ctx\n-old\n+new\n+more\n' \
      "$p" "$p" "$p" "$p" >> "$f"
  done
}
# The lib is sourced into a subshell per call so every case starts clean.
cls() { ( . "$LIB" 2>/dev/null || exit 9; review_diff_class "$1" ) 2>/dev/null; }
D="$T/d"; mkdir -p "$D"

# ---- C1..C3 positives, with the exact changed-line count
mkdiff "$D/c1" README.md docs/notes/x.md guide.rst c.adoc
[ "$(cls "$D/c1")" = "docs 12" ] && ok || bad "C1 docs positives: '$(cls "$D/c1")'"
mkdiff "$D/c2" package-lock.json yarn.lock sub/pnpm-lock.yaml Cargo.lock go.sum poetry.lock uv.lock composer.lock Gemfile.lock requirements.lock
[ "$(cls "$D/c2")" = "lock 30" ] && ok || bad "C2 lock positives: '$(cls "$D/c2")'"
mkdiff "$D/c3" tests/a-test.sh test/b.js e2e/c.spec.ts src/__tests__/d.js src/__mocks__/e.js pkg/fixtures/f.json pkg/testdata/g.bin src/__snapshots__/h.snap src/x.test.ts src/y.spec.js pkg/z_test.go ui/w.snap
[ "$(cls "$D/c3")" = "tests 36" ] && ok || bad "C3 tests positives: '$(cls "$D/c3")'"
# A `--- ` / `+++ ` line inside a hunk is content, but the header pair is not.
printf 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-a\n+b\n' > "$D/c4"
[ "$(cls "$D/c4")" = "docs 2" ] && ok || bad "C4 the header pair is not counted: '$(cls "$D/c4")'"

# ---- C-neg: every one of these is `code`
neg() { # neg <label> <diff-file>
  local got; got=$(cls "$2")
  [ "${got%% *}" = code ] && ok || bad "C-neg $1 must be code, got '$got'"
}
for p in CLAUDE.md sub/CLAUDE.md CLAUDE.local.md AGENTS.md RTK.md rules/topics/01-iron-guardrails.md \
         prompts/build-discipline.md skills/x/SKILL.md .claude/agents/a.md .github/workflows/ci.yml \
         .github/PULL_REQUEST_TEMPLATE.md docs/verification-map/entries/BH-1.md .harness/specs/BH-1/plan.md \
         catalog/lanes.d/x.json guardrails/x/README.md checks/x.md tests/lib/scratch.sh \
         tests/llm-call-ratchet-allowlist.txt requirements.txt src/fixtures.ts docs/run.sh bin/x.sh \
         tests/env-path-allowlist.d/rb-stage-modules.txt tests/gh-app-ratchet-baseline/batch-resolve.sh.txt \
         tests/rb-raw-readers-baseline tests/known-container-failures.txt tests/config-literal-lint.sh \
         tests/x-guard-test.sh test/ratchet.js tests/secret-denylist.txt tests/by-design/x.txt pages/a.mdx; do
  mkdiff "$D/n" "$p"; neg "$p" "$D/n"
done
mkdiff "$D/n" docs/a.md bin/b.sh;          neg "docs+code" "$D/n"
mkdiff "$D/n" docs/a.md tests/t.sh;        neg "docs+tests" "$D/n"
mkdiff "$D/n" package-lock.json README.md; neg "lock+docs" "$D/n"
printf 'diff --git a/bin/x.sh b/docs/x.md\nsimilarity index 90%%\nrename from bin/x.sh\nrename to docs/x.md\n' > "$D/n"
neg "rename bin/x.sh -> docs/x.md" "$D/n"
printf 'diff --git "a/docs/my doc\\t.md" "b/docs/my doc\\t.md"\n--- "a/docs/my doc\\t.md"\n+++ "b/docs/my doc\\t.md"\n@@ -1 +1 @@\n-a\n+b\n' > "$D/n"
neg "quoted path" "$D/n"
: > "$D/n";                                 neg "empty diff" "$D/n"
printf -- '--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-a\n+b\n' > "$D/n"
neg "no diff --git header" "$D/n"
neg "missing file" "$D/does-not-exist"
# 201 changed lines of docs: the class is docs, and the cap is P's business —
# pinned below (K4). Here: the count is exact.
{ printf 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,201 @@\n'
  for _i in $(seq 1 201); do printf '+l%s\n' "$_i"; done; } > "$D/big"
[ "$(cls "$D/big")" = "docs 201" ] && ok || bad "C5 a 201-line docs diff counts 201: '$(cls "$D/big")'"

# ---------------------------------------------------------------------------
# K / P: the knobs and the pick, in a scratch harness with no settings rows.
KH="$T/kh"; mkdir -p "$KH/logs" "$KH/state"
pick() { # pick <diff> [env...] -> "ACTION|MODEL|CLASS|LINES"
  local f="$1"; shift
  ( export HARNESS="$KH" LANE_REGISTRY="$T/no-registry.json"
    unset REVIEW_TRIVIAL_MODE REVIEW_TRIVIAL_MAX_LINES REVIEW_TRIVIAL_ROUTE_CLASSES
    for kv in "$@"; do export "${kv?}"; done
    . "$LIB" 2>/dev/null || exit 9
    [ -f "$T/model_for.sh" ] && . "$T/model_for.sh"
    review_trivial_pick "$f" p1 DEFAULT_WORD
    printf '%s|%s|%s|%s' "${RT_ACTION-unset}" "${RT_MODEL-unset}" "${RT_CLASS-unset}" "${RT_LINES-unset}" ) 2>/dev/null
}
knobs() { ( export HARNESS="$KH" LANE_REGISTRY="$T/no-registry.json"
            unset REVIEW_TRIVIAL_MODE REVIEW_TRIVIAL_MAX_LINES REVIEW_TRIVIAL_ROUTE_CLASSES
            for kv in "$@"; do export "${kv?}"; done
            . "$LIB" 2>/dev/null || exit 9; _rs_knobs; printf '%s|%s|%s' "$_RS_MODE" "$_RS_MAX" "$_RS_CLASSES" ) 2>/dev/null; }
mkdiff "$D/docs" README.md
mkdiff "$D/code" bin/x.sh
mkdiff "$D/tests" tests/foo-test.sh
mkdiff "$D/lock" package-lock.json
rm -f "$T/model_for.sh"
[ "$(knobs)" = "shadow|200|docs" ] && ok || bad "K1 with no row the registry default is shadow/200/docs: '$(knobs)'"
: > "$KH/logs/review-saving.log"
[ "$(knobs REVIEW_TRIVIAL_MODE=bogus)" = "off|200|docs" ] && ok || bad "K2 a bad mode is off (never clamped to a mode): '$(knobs REVIEW_TRIVIAL_MODE=bogus)'"
[ "$(grep -c 'bogus' "$KH/logs/review-saving.log" 2>/dev/null)" = 1 ] && ok || bad "K2 the bad value is named once in the log: $(cat "$KH/logs/review-saving.log" 2>/dev/null)"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MAX_LINES=0 | cut -d'|' -f1-2)" = "|DEFAULT_WORD" ] && ok || bad "K3 max 0 makes nothing trivial: '$(pick "$D/docs" REVIEW_TRIVIAL_MAX_LINES=0)'"
[ "$(pick "$D/big" REVIEW_TRIVIAL_MODE=shadow | cut -d'|' -f1-2)" = "|DEFAULT_WORD" ] && ok || bad "K4 201 lines over a cap of 200 is not trivial: '$(pick "$D/big" REVIEW_TRIVIAL_MODE=shadow)'"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MAX_LINES=abc | cut -d'|' -f1-2)" = "|DEFAULT_WORD" ] && ok || bad "K5 a non-digit max is off: '$(pick "$D/docs" REVIEW_TRIVIAL_MAX_LINES=abc)'"
: > "$KH/logs/review-saving.log"
[ "$(knobs REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs evil' | cut -d'|' -f1)" = "off" ] && ok \
  || bad "K6 a route class outside docs|lock|tests is off (never dropped to the good ones): '$(knobs REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs evil')'"
[ "$(grep -c 'evil' "$KH/logs/review-saving.log" 2>/dev/null)" = 1 ] && ok || bad "K6 the bad class is named once in the log: $(cat "$KH/logs/review-saving.log" 2>/dev/null)"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs evil' | cut -d'|' -f1-2)" = "|DEFAULT_WORD" ] && ok \
  || bad "K6 a bad class routes and records nothing: '$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs evil')'"

[ "$(pick "$D/docs")" = "shadow|DEFAULT_WORD|docs|3" ] && ok || bad "P1 shadow keeps the model: '$(pick "$D/docs")'"
printf 'model_for() { [ "$1" = review.trivial ] && [ "$2" = p1 ] && { echo TRIVIAL_WORD; return 0; }; return 75; }\n' > "$T/model_for.sh"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route)" = "routed|TRIVIAL_WORD|docs|3" ] && ok || bad "P2 route takes the review.trivial model: '$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route)'"
[ "$(pick "$D/code" REVIEW_TRIVIAL_MODE=route | cut -d'|' -f1-3)" = "|DEFAULT_WORD|code" ] && ok || bad "P2b a code diff is never routed: '$(pick "$D/code" REVIEW_TRIVIAL_MODE=route)'"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MODE=off | cut -d'|' -f1-2)" = "|DEFAULT_WORD" ] && ok || bad "P2c off routes nothing: '$(pick "$D/docs" REVIEW_TRIVIAL_MODE=off)'"
# P4 the route classes default to docs: a tests or lock diff in route mode is
# measured (shadow) and keeps the default model; widening the row routes it.
[ "$(pick "$D/tests" REVIEW_TRIVIAL_MODE=route)" = "shadow|DEFAULT_WORD|tests|3" ] && ok || bad "P4 a tests diff is not routed by default: '$(pick "$D/tests" REVIEW_TRIVIAL_MODE=route)'"
[ "$(pick "$D/lock" REVIEW_TRIVIAL_MODE=route)" = "shadow|DEFAULT_WORD|lock|3" ] && ok || bad "P4 a lock diff is not routed by default: '$(pick "$D/lock" REVIEW_TRIVIAL_MODE=route)'"
[ "$(pick "$D/tests" REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs tests')" = "routed|TRIVIAL_WORD|tests|3" ] && ok \
  || bad "P4b an operator row naming tests routes it: '$(pick "$D/tests" REVIEW_TRIVIAL_MODE=route 'REVIEW_TRIVIAL_ROUTE_CLASSES=docs tests')'"
printf 'model_for() { return 75; }\n' > "$T/model_for.sh"
[ "$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route | cut -d'|' -f1-2)" = "no-route|DEFAULT_WORD" ] && ok || bad "P3 no route keeps the default: '$(pick "$D/docs" REVIEW_TRIVIAL_MODE=route)'"
rm -f "$T/model_for.sh"

# ---------------------------------------------------------------------------
# The event helper, alone: argv recorded, fail-open, JOB_ID untouched.
EVT="$T/events.log"
cat > "$T/jobstub.sh" <<'STUB'
job_open() {
  printf 'open %s\n' "$*" >> "$TEST_ROOT/events.log"
  local rc; rc=$(cat "$TEST_ROOT/jo-rc" 2>/dev/null || echo 0)
  case "$rc" in 0) printf 'rs-1'; return 0 ;; 9) printf 'IN_FLIGHT box x'; return 9 ;; *) return "$rc" ;; esac
}
job_event()  { printf 'event %s\n' "$*" >> "$TEST_ROOT/events.log"; return 0; }
job_update() { printf 'update %s\n' "$*" >> "$TEST_ROOT/events.log"; return 0; }
STUB
evt() { ( export TEST_ROOT="$T" HARNESS="$KH"; . "$T/jobstub.sh"; . "$LIB" || exit 9
          JOB_ID="${JOB_ID_IN-}"
          review_saving_event p1 review-prs o/p1 7 abcdef1234567890 REUSED "from=1234567abcde to=abcdef123456 how=main-merge"
          printf 'rc=%s JOB_ID=%s' "$?" "$JOB_ID" ) 2>/dev/null; }
# Counts over the event log; an absent log is 0 events, never an empty string.
CNT() { { cat "$EVT" 2>/dev/null || true; } | grep -c -- "$1" || true; }
SAV() { CNT "^event rs-[0-9]* review-saving $1 "; }
rm -f "$EVT" "$T/jo-rc"
out=$(JOB_ID_IN=job-billing evt)
[ "$out" = "rc=0 JOB_ID=job-billing" ] && ok || bad "R6 the helper leaves JOB_ID byte-identical and answers 0: '$out'"
grep -q "^open p1 review-saving/review-prs/o/p1#7@abcdef1234567890 review-saving review-saving " "$EVT" && ok || bad "R6 job_open argv: $(cat "$EVT")"
[ "$(SAV REUSED)" = 1 ] && ok || bad "R6 one REUSED event: $(cat "$EVT")"
grep -q "^update rs-[0-9]* status=done stage=done$" "$EVT" && ok || bad "R6 the event's row is closed: $(cat "$EVT")"
rm -f "$EVT"; echo 9 > "$T/jo-rc"
out=$(evt)
[ "$out" = "rc=0 JOB_ID=" ] && [ "$(CNT '^event\|^update')" = 0 ] && ok || bad "R5 a refused job_open (rc 9) writes no event and answers 0: '$out' $(cat "$EVT")"
rm -f "$EVT"; echo 1 > "$T/jo-rc"
out=$(evt)
[ "$out" = "rc=0 JOB_ID=" ] && [ "$(CNT '^event')" = 0 ] && ok || bad "R5b a failed job_open (rc 1) writes no event and answers 0: '$out'"
rm -f "$T/jo-rc"

# ---------------------------------------------------------------------------
# The git side, shared by the replay cases.
W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }
fixture() { # fixture <checkout-dir>
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos" 2>/dev/null
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
  mkdir -p "$T/repos"; git clone -q "$T/remote.git" "$T/repos/$1"
}
main_merge() {
  w checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit m >/dev/null; push main
  w checkout -q pr; w merge -q --no-edit main >/dev/null 2>&1; push pr; w rev-parse HEAD
}

# ---------------------------------------------------------------------------
# L1..L4, R1, R4: the REAL bin/review-prs.sh (the review-prs-replay.bh-2310 rig).
RP="$DIR/bin/review-prs.sh"
PROJECT=project-1
PH="$T/h"
PSTATE="$PH/state/$PROJECT.pr-reviews.json"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"pr list"*) cat "$TEST_ROOT/prs.tsv" ;;
  *"pr diff"*"name-only"*) sed -n 's|^diff --git a/\([^ ]*\) .*|\1|p' "$TEST_ROOT/diff.$3" 2>/dev/null ;;
  *"pr diff"*) cat "$TEST_ROOT/diff.$3" 2>/dev/null ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*"comments,reviews"*) printf '{"comments":[],"reviews":[]}\n' ;;
  *"pr view"*"body"*) printf '{"body":"test body"}\n' ;;
  *"pr review"*) printf '%s\n' "$*" >> "$TEST_ROOT/gh-reviews.log" ;;
  *"pr comment"*) : ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$TEST_ROOT/merges.log" ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *"api"*)
    # RP_BASE_OK=1: the PR's own REST read answers an OPEN PR on main, so an
    # APPROVE gets past rp_base_hold to `gh pr merge` (the M1 control proves it).
    PRJ='{"number":42,"state":"open","merged":false,"mergeable_state":"clean","base":{"ref":"main"},"head":{"sha":"x"}}'
    if [ "${RP_BASE_OK:-0}" = 1 ] && [[ "$*" =~ GET\ repos/[^\ ]+/pulls/[0-9]+($|\ ) ]]; then
      printf 'HTTP/2.0 200 OK\r\n\r\n%s\n' "$PRJ"
    elif [ "${RP_BASE_OK:-0}" = 1 ] && [ "$2" != -i ] && [[ "$2" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+$ ]] && [ "$3" = -q ]; then
      printf '%s' "$PRJ" | jq -r "$4"
    fi ;;
esac
exit 0
STUB
cat > "$T/fakebin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s %s\n' "${AGENT_CALL_FP:-?}" "$3" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 1\nVERDICT: APPROVE\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call.sh" "$T/fakebin/sleep"
{ cat <<'STUB'
job_lane_open() { JOB_ID="job-x"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_heartbeat() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
STUB
  cat "$T/jobstub.sh"; } > "$T/rpstub.sh"
fresh_rp() {
  scratch_rm "$PH" 2>/dev/null
  rm -f "$T/agent-calls.log" "$EVT" "$T/jo-rc" "$T"/diff.* "$T/merges.log" "$T/gh-reviews.log"
  mkdir -p "$PH/bin/lib" "$PH/state" "$PH/logs" "$PH/locks" "$PH/env" "$PH/builds"
  cp "$T/fakebin/agent-call.sh" "$PH/bin/agent-call.sh"; chmod +x "$PH/bin/agent-call.sh"
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/patch-same.sh" "$PH/bin/lib/"
  mrs_fixture "$PH" "$PROJECT"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$PH/bin/$b"; chmod +x "$PH/bin/$b"; done
  printf '{}\n' > "$PSTATE"
}
# trivial_route <harness> <project> — the review.trivial ladder a box caches.
trivial_route() { mkdir -p "$1/state/model-routes"; printf '0\tTRIVIAL_WORD\tclaude\n' > "$1/state/model-routes/review.trivial@$2.tsv"; }
run_rp() { # run_rp [env...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$PH" FLEET_CONF="$DIR/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="${RP_REPOS:-$T/repos}" BASH_ENV="$T/rpstub.sh" LANE_REGISTRY="$T/no-registry.json"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_TRIVIAL_MODE REVIEW_TRIVIAL_MAX_LINES REVIEW_TRIVIAL_ROUTE_CLASSES REVIEW_MODEL HARNESS_SECRET JOBS_URL
    for kv in "$@"; do export "${kv?}"; done
    # The open-PR list is REST now; the bridge answers it from prs.tsv. Sourced
    # in this subshell only: it exports a `gh` function the autopilot rig must not see.
    . "$(dirname "$0")/lib/gh-list-bridge.sh" || exit 1
    bash "$RP" "$PROJECT" >/dev/null 2>&1 )
}
heads() { : > "$T/prs.tsv"; while [ $# -gt 0 ]; do printf '%s\t%s\texternaldev\tTest PR\n' "$1" "$2" >> "$T/prs.tsv"; shift 2; done; }
models() { cut -d' ' -f2 "$T/agent-calls.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
fresh_rp; BR=$(awk -F'\t' 'NR==1{print $2}' "$PH/state/model-routes/build.review@$PROJECT.tsv")
[ -n "$BR" ] && ok || bad "rig: no build.review word in the fixture cache"

# L1 route + a docs-only PR -> the trivial model reaches agent-call
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" README.md; heads 42 aaaaaaa1
run_rp REVIEW_TRIVIAL_MODE=route
[ "$(models)" = "TRIVIAL_WORD" ] && ok || bad "L1 review-prs route: the fake agent-call must get TRIVIAL_WORD, got '$(models)'"
[ "$(SAV TRIVIAL_ROUTED)" = 1 ] && ok || bad "L1 one TRIVIAL_ROUTED event: $(cat "$EVT" 2>/dev/null)"
grep -q "trivial docs 3 lines: routed model=TRIVIAL_WORD" "$PH/logs/pr-reviews.log" 2>/dev/null && ok || bad "L1 the log line: $(tail -2 "$PH/logs/pr-reviews.log" 2>/dev/null)"
# The reviewer said TIER 1; the record says at most 2. A label only: M1-M4 pin the merge.
[ "$(jq -r '.["42"].tier' "$PSTATE" 2>/dev/null)" = 2 ] && ok || bad "L1 a routed TIER 1 is recorded as tier 2: $(cat "$PSTATE" 2>/dev/null)"

# M1 control: an UNROUTED docs APPROVE on a readable main base reaches gh pr merge.
# Without it M2's "no merge" could be the rig, not the fence.
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" README.md; heads 42 aaaaaaa1
run_rp RP_BASE_OK=1
[ "$(models)" = "$BR" ] && grep -q "^pr merge 42 " "$T/merges.log" 2>/dev/null && ok \
  || bad "M1 control: an unrouted APPROVE must reach gh pr merge: models='$(models)' merges='$(cat "$T/merges.log" 2>/dev/null)' $(grep '#42' "$PH/logs/pr-reviews.log" 2>/dev/null | tail -3)"
grep -q -- "--approve" "$T/gh-reviews.log" 2>/dev/null && ok || bad "M1 control: an unrouted APPROVE posts --approve: $(cat "$T/gh-reviews.log" 2>/dev/null)"
# M2 the routed APPROVE, same rig: no merge, a comment review (no GitHub approval),
# no head marker, trivial=1 on the row, no ledger verdict.
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" README.md; heads 42 aaaaaaa1
run_rp RP_BASE_OK=1 REVIEW_TRIVIAL_MODE=route
[ "$(models)" = TRIVIAL_WORD ] && ok || bad "M2 rig: the routed model must serve: '$(models)'"
[ ! -s "$T/merges.log" ] && ok || bad "M2 A ROUTED CHEAP-MODEL APPROVE WAS MERGED: $(cat "$T/merges.log")"
grep -q -- "--comment" "$T/gh-reviews.log" 2>/dev/null && ! grep -q -- "--approve" "$T/gh-reviews.log" && ok \
  || bad "M2 a routed APPROVE posts as a comment review, never --approve: $(cat "$T/gh-reviews.log" 2>/dev/null)"
! grep -q "Automated harness review" "$T/gh-reviews.log" 2>/dev/null && ok \
  || bad "M2 the advisory body carries no head marker the dedup rung would rehydrate: $(cat "$T/gh-reviews.log")"
[ "$(jq -r '.["42"] | "\(.sha) \(.verdict) \(.trivial)"' "$PSTATE" 2>/dev/null)" = "aaaaaaa1 APPROVE 1" ] && ok \
  || bad "M2 the row records the advisory APPROVE with trivial=1: $(cat "$PSTATE" 2>/dev/null)"
grep -q "APPROVE left unmerged: an advisory read by the trivial route" "$PH/logs/pr-reviews.log" 2>/dev/null && ok \
  || bad "M2 the log says why it did not merge: $(grep '#42' "$PH/logs/pr-reviews.log" 2>/dev/null | tail -3)"
# M3 the next tick, same head: merge_retry refuses, and the head is re-reviewed on
# the FULL model (never routed again); that APPROVE merges and clears the flag.
: > "$T/agent-calls.log"; rm -f "$EVT"
run_rp RP_BASE_OK=1 REVIEW_TRIVIAL_MODE=route
[ "$(models)" = "$BR" ] && ok || bad "M3 the advisory head is re-reviewed once on the full model: '$(models)'"
[ "$(SAV TRIVIAL_ESCALATED)" = 1 ] && [ "$(SAV TRIVIAL_ROUTED)" = 0 ] && ok || bad "M3 one TRIVIAL_ESCALATED event, no second route: $(cat "$EVT" 2>/dev/null)"
[ "$(grep -c "^pr merge 42 " "$T/merges.log" 2>/dev/null)" = 1 ] && ok || bad "M3 the full-model APPROVE merges, once: $(cat "$T/merges.log" 2>/dev/null)"
[ "$(jq -r '.["42"].trivial // "none"' "$PSTATE" 2>/dev/null)" = none ] && ok || bad "M3 the full verdict clears trivial: $(cat "$PSTATE")"
# M4 merge_retry alone: a trivial APPROVE on the current head (as a replay leaves
# it) is never retried into a merge, even OPEN CLEAN on main.
# Every hold answers "no hold" and the PR reads OPEN CLEAN, so only the trivial
# guard stands between the record and merge_step; M4c proves the rig reaches it.
retry_only() { # retry_only <trivial-json-fragment>
  rm -f "$T/merges.log"
  printf '{"42":{"sha":"aaaaaaa1","verdict":"APPROVE","tier":"2","served":"claude"%s}}\n' "$1" > "$PSTATE"
  ( export HARNESS="$PH" STATE="$PSTATE" SLUG=o/p PROJECT="$PROJECT" LOG="$PH/logs/x.log" TEST_ROOT="$T"
    eval "$(sed -n '/^merge_retry() {/,/^}/p' "$RP")"
    rp_prov_is_claude() { [ "$1" = claude ]; }
    hold_conductor_owns_merges() { return 1; }; mc_queue_conductor_only() { return 1; }
    hold_automerge_disabled() { return 1; }; hold_paused_project() { return 1; }
    mc_pr_view() { echo "OPEN CLEAN"; }
    rp_state_write() { local t; t=$(mktemp); jq "$@" "$STATE" > "$t" && mv "$t" "$STATE"; }
    STAMP() { date -u +%FT%TZ; }
    merge_step() { printf 'merge_step %s\n' "$*" >> "$TEST_ROOT/merges.log"; }
    merge_retry 42 aaaaaaa1 externaldev ) >/dev/null 2>&1
}
fresh_rp
retry_only ''
grep -q "^merge_step 42 aaaaaaa1 claude" "$T/merges.log" 2>/dev/null && ok || bad "M4c control: an ordinary APPROVE on the head is retried into merge_step: $(cat "$T/merges.log" 2>/dev/null)"
retry_only ',"trivial":"1"'
[ ! -s "$T/merges.log" ] && ok || bad "M4 merge_retry must refuse a trivial APPROVE: $(cat "$T/merges.log")"
# L1b route but no review.trivial route anywhere -> the default model, NO_ROUTE
fresh_rp; mkdiff "$T/diff.42" README.md; heads 42 aaaaaaa1
run_rp REVIEW_TRIVIAL_MODE=route
[ "$(models)" = "$BR" ] && [ "$(SAV TRIVIAL_NO_ROUTE)" = 1 ] && [ "$(SAV TRIVIAL_ROUTED)" = 0 ] && ok \
  || bad "L1b no route: the build.review word and a NO_ROUTE event, got '$(models)' $(cat "$EVT" 2>/dev/null)"
# L2 shadow (the default) -> build.review model, TRIVIAL_SHADOW
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" README.md; heads 42 aaaaaaa1
run_rp
[ "$(models)" = "$BR" ] && ok || bad "L2 review-prs shadow: the build.review word, got '$(models)'"
[ "$(SAV TRIVIAL_SHADOW)" = 1 ] && ok || bad "L2 one TRIVIAL_SHADOW event: $(cat "$EVT" 2>/dev/null)"
[ "$(jq -r '.["42"].tier' "$PSTATE" 2>/dev/null)" = 1 ] && ok || bad "L2 an unrouted TIER 1 stays tier 1: $(cat "$PSTATE" 2>/dev/null)"
# L3 a code diff -> build.review, no trivial event
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" bin/x.sh; heads 42 aaaaaaa1
run_rp REVIEW_TRIVIAL_MODE=route
[ "$(models)" = "$BR" ] && ok || bad "L3 review-prs code diff: the build.review word, got '$(models)'"
[ "$(CNT ' review-saving TRIVIAL_')" = 0 ] && ok || bad "L3 no trivial event on code: $(cat "$EVT" 2>/dev/null)"
# L4 a docs PR then a code PR in ONE tick -> the code PR gets the tick default
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" README.md; mkdiff "$T/diff.43" bin/x.sh
heads 42 aaaaaaa1 43 bbbbbbb2
run_rp REVIEW_TRIVIAL_MODE=route
[ "$(grep -c '#42@' "$T/agent-calls.log" 2>/dev/null)" = 1 ] && [ "$(grep -c '#43@' "$T/agent-calls.log" 2>/dev/null)" = 1 ] && ok \
  || bad "L4 each head bought exactly one review: $(cat "$T/agent-calls.log" 2>/dev/null)"
[ "$(grep '#42@' "$T/agent-calls.log" | cut -d' ' -f2)" = TRIVIAL_WORD ] && [ "$(grep '#43@' "$T/agent-calls.log" | cut -d' ' -f2)" = "$BR" ] && ok \
  || bad "L4 the code PR after a routed docs PR must get the tick default: $(cat "$T/agent-calls.log" 2>/dev/null)"

# L7 route with the default classes: a tests-only PR and a lockfile PR keep the
# build.review model and are measured as TRIVIAL_SHADOW, never routed
fresh_rp; trivial_route "$PH" "$PROJECT"; mkdiff "$T/diff.42" tests/foo-test.sh; mkdiff "$T/diff.43" package-lock.json
heads 42 aaaaaaa1 43 bbbbbbb2
run_rp REVIEW_TRIVIAL_MODE=route
[ "$(models)" = "$BR $BR" ] && ok || bad "L7 tests/lock PRs are not routed by default: '$(models)'"
[ "$(SAV TRIVIAL_SHADOW)" = 2 ] && [ "$(SAV TRIVIAL_ROUTED)" = 0 ] && ok || bad "L7 two TRIVIAL_SHADOW events, no ROUTED: $(cat "$EVT" 2>/dev/null)"
[ "$(jq -r '.["42"].tier' "$PSTATE" 2>/dev/null)" = 1 ] && ok || bad "L7 an unrouted tests PR keeps its tier: $(cat "$PSTATE" 2>/dev/null)"

# R1 the real review-prs replay -> one REUSED event, 0 agent calls
fresh_rp; fixture "$PROJECT"; mkdiff "$T/diff.42" f.txt
heads 42 "$R"; run_rp
H=$(main_merge); heads 42 "$H"; rm -f "$EVT"; : > "$T/agent-calls.log"
run_rp
[ ! -s "$T/agent-calls.log" ] && ok || bad "R1 a replay buys no review: $(cat "$T/agent-calls.log")"
[ "$(CNT ' review-saving review-saving ')" = 1 ] && ok || bad "R1 one review-saving job_open: $(cat "$EVT" 2>/dev/null)"
[ "$(SAV REUSED)" = 1 ] && grep -q "review-saving REUSED from=${R:0:12} to=${H:0:12} how=main-merge" "$EVT" && ok \
  || bad "R1 one REUSED event naming both heads and how: $(cat "$EVT" 2>/dev/null)"
# R4 job_open fails -> the lane still replays (state moves), no event
fresh_rp; fixture "$PROJECT"; mkdiff "$T/diff.42" f.txt
heads 42 "$R"; run_rp
H=$(main_merge); heads 42 "$H"; rm -f "$EVT"; echo 1 > "$T/jo-rc"
run_rp; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.["42"].sha' "$PSTATE")" = "$H" ] && [ "$(jq -r '.["42"].replayed_from' "$PSTATE")" = "$R" ] && ok \
  || bad "R4 a failed job_open must not break the replay: rc=$rc $(cat "$PSTATE")"
[ "$(CNT '^event.* review-saving ')" = 0 ] && ok || bad "R4 no event when job_open failed: $(cat "$EVT")"

# ---------------------------------------------------------------------------
# L5, L6, R2: the REAL bin/review-autopilot.sh (the review-autopilot-replay rig).
AH="$T/ah"
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
fresh_ap() {
  scratch_rm "$AH" 2>/dev/null
  rm -f "$T/ap-calls.txt" "$EVT" "$T/jo-rc" "$T/ap-diff"
  mkdir -p "$AH/bin/lib/mc" "$AH/logs" "$AH/locks" "$AH/env" "$AH/state" "$T/apbin"
  cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$AH/bin/"
  cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
     "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$AH/bin/lib/"
  cp "$DIR"/bin/lib/mc/*.sh "$AH/bin/lib/mc/"
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/patch-same.sh" "$AH/bin/lib/"
  # The lane is a COPY in the scratch harness, so its lib is too (it sources
  # from its own directory). Missing, the copy runs as it did before BH-2545.
  [ -r "$LIB" ] && cp "$LIB" "$AH/bin/lib/"
  [ -r "$REGF" ] && { mkdir -p "$AH/catalog/lanes.d"; cp "$REGF" "$AH/catalog/lanes.d/"; }
  printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$AH/fleet.conf"
  : > "$AH/env/global.env"
  mrs_fixture "$AH" p1
  { printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s %s\n' "${AGENT_CALL_FP:-?}" "$3" >> "$T/ap-calls.txt"
printf 'Fine.\n\nVERDICT: MERGE — reads fine\n' > "$5"
exit 0
EOF
  } > "$AH/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$AH/bin/beat.sh"
  chmod +x "$AH/bin/"*.sh
}
mkdir -p "$T/apbin"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then exit 0; fi
case "$*" in
  api\ repos/o/p1/issues/7/comments*) printf '[]\n' ;;
  *repos/o/p1/pulls/7) printf 'HTTP/2.0 200 OK\r\n\r\n{"number":7,"state":"open","merged_at":null}\n' ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*) sed -n 's|^diff --git a/\([^ ]*\) .*|\1|p' "$T/ap-diff" ;;
  *"pr diff"*)             cat "$T/ap-diff" ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *) : ;;
esac
exit 0
EOF
} > "$T/apbin/gh"
chmod +x "$T/apbin/gh"
pulls_for() { jq -n --arg sha "$1" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"; }
run_ap() { # run_ap [env...]
  ( export PATH="$T/apbin:$PATH" HARNESS="$AH" FLEET_CONF="$AH/fleet.conf" GH_TOKEN="" TEST_ROOT="$T" \
      REPOS_ROOT="${AP_REPOS:-$T/repos}" BASH_ENV="$T/jobstub.sh" LANE_REGISTRY="$T/no-registry.json"
    unset JOB_ID REVIEW_TRIVIAL_MODE REVIEW_TRIVIAL_MAX_LINES REVIEW_TRIVIAL_ROUTE_CLASSES REVIEW_MODEL HARNESS_SECRET JOBS_URL
    for kv in "$@"; do export "${kv?}"; done
    bash "$AH/bin/review-autopilot.sh" >>"$T/ap-run.log" 2>&1 ) || true; }
apmodels() { cut -d' ' -f2 "$T/ap-calls.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# L5 autopilot, route + docs -> MEASURED, never routed: its MERGE word lands via
# the conductor with no tier to cap, so the build.review model still reads it
fresh_ap; trivial_route "$AH" p1; mkdiff "$T/ap-diff" README.md; pulls_for aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1
run_ap REVIEW_TRIVIAL_MODE=route
[ "$(apmodels)" = "$BR" ] && ok || bad "L5 autopilot is never routed: the fake agent-call must get the build.review word, got '$(apmodels)' $(tail -3 "$AH/logs/review-autopilot.log" 2>/dev/null)"
[ "$(SAV TRIVIAL_SHADOW)" = 1 ] && [ "$(SAV TRIVIAL_ROUTED)" = 0 ] && ok || bad "L5 one TRIVIAL_SHADOW event and no ROUTED: $(cat "$EVT" 2>/dev/null)"
# L6 autopilot, route + code -> build.review
fresh_ap; trivial_route "$AH" p1; mkdiff "$T/ap-diff" bin/x.sh; pulls_for aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1
run_ap REVIEW_TRIVIAL_MODE=route
[ "$(apmodels)" = "$BR" ] && ok || bad "L6 autopilot code diff: the build.review word, got '$(apmodels)'"
[ "$(CNT ' review-saving TRIVIAL_')" = 0 ] && ok || bad "L6 no trivial event on code: $(cat "$EVT" 2>/dev/null)"

# R2 the real autopilot replay -> one REUSED event, no new agent call
fresh_ap; fixture p1; mkdiff "$T/ap-diff" f.txt
pulls_for "$R"; run_ap
H=$(main_merge); pulls_for "$H"; rm -f "$EVT"; : > "$T/ap-calls.txt"
run_ap
[ ! -s "$T/ap-calls.txt" ] && ok || bad "R2 an autopilot replay buys no review: $(cat "$T/ap-calls.txt")"
[ "$(SAV REUSED)" = 1 ] && grep -q "review-saving REUSED from=${R:0:12} to=${H:0:12} how=main-merge" "$EVT" && ok \
  || bad "R2 one REUSED event naming both heads and how: $(cat "$EVT" 2>/dev/null) $(tail -2 "$AH/logs/review-autopilot.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
# R3: rebind_patch_id from the REAL bin/lib/mc/settle.sh, the patch test stubbed.
rm -f "$EVT"
out=$( export TEST_ROOT="$T" HARNESS="$T/mch"
  mkdir -p "$T/mch/logs" "$T/mch/state" "$T/mch/flags" "$T/mch/locks" "$T/mch/builds" "$T/rec3"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
  . "$T/jobstub.sh"
  unset -f review_saving_event
  mc_patch_id_rebind() { printf 'same:main-merge'; }
  job_verdict_rebind() { return 0; }
  rebind_patch_id "demo-os#7" demo-os example-org/demo-os 7 https://github.com/example-org/demo-os/pull/7 \
    "$T/rec3" 1111111111112222222222223333333333334444 aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd
  echo "rc=$?" ) 2>/dev/null
[ "$out" = "rc=0" ] && ok || bad "R3 rebind_patch_id must still answer rc 0: '$out'"
[ "$(SAV REUSED)" = 1 ] && grep -q "^open demo-os review-saving/merge-conductor/example-org/demo-os#7@aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd " "$EVT" \
  && grep -q "review-saving REUSED from=111111111111 to=aaaaaaaaaaaa how=main-merge" "$EVT" && ok \
  || bad "R3 the conductor rebind records one REUSED event: $(cat "$EVT" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Z1: no model literal in the lib (the route is a model_routes row). Guarded so
# an absent lib fails instead of counting zero.
[ -r "$LIB" ] && [ "$(grep -c 'claude-' "$LIB")" = 0 ] && ok || bad "Z1 the lib must exist and carry no claude- literal"
# Z2: the registry file is real JSON naming the lib, and both files are named by path above.
[ -r "$REGF" ] && [ "$(jq -r '.libs[0].id + " " + .libs[0].file' "$REGF" 2>/dev/null)" = "review-saving bin/lib/review-saving.sh" ] && ok \
  || bad "Z2 $REGF must register lib review-saving at bin/lib/review-saving.sh"
[ "$(grep -v '^[[:space:]]*#' "$0" | grep -v 'grep -cF' | grep -cF -e '"$DIR/bin/lib/review-saving.sh"' -e '"$DIR/catalog/lanes.d/_lib.review-saving.json"')" = 2 ] && ok \
  || bad "Z2 both new files must be named by rooted path on non-comment lines"

echo "review-saving.bh-2545: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
