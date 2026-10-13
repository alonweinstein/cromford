#!/bin/bash
# tests/gh-shim-actions.bh-789-test.sh — bin/lib/gh-shim/actions.sh (#769 chunk 3,
# BH-789): `gh run view|rerun|list` as single REST calls.
#
# HOW IT DRIVES. The real bin/gh-rest-shim through the PATH symlink $T/shim/gh,
# shipped handlers sourced from bin/lib/gh-shim, a stub behind it
# (tests/lib/gh-shim-stub.sh). Assertions read recorded argv, stdout and exit
# codes; no block greps handler source.
#
# Behaviours broken once during the build, each turning a block red:
#   - drop the databaseId<-id field mapping        -> run-view-json red
#   - fetch logs for every job, not just failures  -> run-view-log-failed red
#   - post rerun instead of rerun-failed-jobs      -> run-rerun-failed red
#   - translate `run view 1` with no --json/--log  -> run-view-untranslated red
#
# Run from anywhere:  bash tests/gh-shim-actions.bh-789-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }
countlines() { gshim_calls | grep -c -- "$1"; return 0; }

gshim_stub_setup
printf 'https://github.com/o/r\n' >"$T/fixtures/git-origin.txt"

printf '%s\n' '{"id":991,"status":"completed","conclusion":"success","head_sha":"abc","head_branch":"feat","name":"CI","display_title":"Fix it","html_url":"https://github.com/o/r/actions/runs/991","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:05:00Z","event":"push","run_number":12,"run_attempt":1,"workflow_id":77}' | gshim_fixture repos_o_r_actions_runs_991
printf '%s\n' '{"total_count":3,"jobs":[{"id":1,"name":"lint","conclusion":"success"},{"id":2,"name":"unit","conclusion":"failure"},{"id":3,"name":"build","conclusion":"success"}]}' | gshim_fixture repos_o_r_actions_runs_991_jobs
printf 'lint log\n'  | gshim_fixture repos_o_r_actions_jobs_1_logs
printf 'unit log\n'  | gshim_fixture repos_o_r_actions_jobs_2_logs
printf 'build log\n' | gshim_fixture repos_o_r_actions_jobs_3_logs
printf '{}\n' | gshim_fixture repos_o_r_actions_runs_991_rerun
printf '{}\n' | gshim_fixture repos_o_r_actions_runs_991_rerun-failed-jobs
printf '%s\n' '{"total_count":2,"workflow_runs":[{"id":5,"created_at":"2026-01-02T00:00:00Z","status":"completed","conclusion":"success"},{"id":6,"created_at":"2026-01-03T00:00:00Z","status":"completed","conclusion":"failure"}]}' | gshim_fixture repos_o_r_actions_workflows_ci.yml_runs
printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":9,"created_at":"2026-01-04T00:00:00Z","status":"queued","conclusion":null}]}' | gshim_fixture repos_o_r_actions_runs

# ── run-view-json ────────────────────────────────────────────────────────────
gshim_reset
gshim_run run view 991 -R o/r --json status,conclusion
eq  "run-view-json rc"     "$RC" "0"
eq  "run-view-json stdout" "$OUT" '{"status":"completed","conclusion":"success"}'
has "run-view-json call"   "$(gshim_calls)" "api repos/o/r/actions/runs/991"
hasnt "run-view-json no passthru" "$(gshim_calls)" "PASSTHRU"
gshim_reset
gshim_run run view 991 -R o/r --json databaseId,headSha,headBranch,displayTitle,url,number,attempt,workflowDatabaseId
eq  "run-view-json map" "$OUT" '{"databaseId":991,"headSha":"abc","headBranch":"feat","displayTitle":"Fix it","url":"https://github.com/o/r/actions/runs/991","number":12,"attempt":1,"workflowDatabaseId":77}'
gshim_reset
gshim_run run view 991 -R o/r --json status --jq '.status'
eq  "run-view-json jq" "$OUT" "completed"

# ── run-view-unmappable-field passes through ─────────────────────────────────
gshim_reset
gshim_run run view 991 -R o/r --json jobs
has   "run-view-unmappable passthru" "$(gshim_calls)" "PASSTHRU run view 991 -R o/r --json jobs"
has   "run-view-unmappable depth"    "$(gshim_env)"   "depth=1 run view 991 -R o/r --json jobs"
hasnt "run-view-unmappable no rest"  "$(gshim_calls)" "api repos/o/r/actions/runs/991"

# ── run-view-untranslated (no --json, no --log) passes through ───────────────
gshim_reset
gshim_run run view 991 -R o/r
has   "run-view-untranslated passthru" "$(gshim_calls)" "PASSTHRU run view 991 -R o/r"
has   "run-view-untranslated depth"    "$(gshim_env)"   "depth=1 run view 991 -R o/r"
hasnt "run-view-untranslated no rest"  "$(gshim_calls)" "api repos/o/r/actions/runs/991"

# ── run-view-log-failed-only-failed-jobs ─────────────────────────────────────
gshim_reset
gshim_run run view 991 -R o/r --log-failed
eq  "run-view-log-failed rc"     "$RC" "0"
eq  "run-view-log-failed stdout" "$OUT" "$(printf '=== unit ===\nunit log')"
has "run-view-log-failed jobs call" "$(gshim_calls)" "repos/o/r/actions/runs/991/jobs"
eq  "run-view-log-failed one log call" "$(countlines 'actions/jobs/')" "1"
has "run-view-log-failed the failed job" "$(gshim_calls)" "repos/o/r/actions/jobs/2/logs"
hasnt "run-view-log-failed not lint"  "$(gshim_calls)" "actions/jobs/1/logs"
hasnt "run-view-log-failed not build" "$(gshim_calls)" "actions/jobs/3/logs"

# ── run-view-log (all jobs) ──────────────────────────────────────────────────
gshim_reset
gshim_run run view 991 -R o/r --log
eq "run-view-log rc"        "$RC" "0"
eq "run-view-log three logs" "$(countlines 'actions/jobs/')" "3"
eq "run-view-log stdout"    "$OUT" "$(printf '=== lint ===\nlint log\n=== unit ===\nunit log\n=== build ===\nbuild log')"

# ── run-view-log-failed with no failures prints nothing ──────────────────────
gshim_reset
printf '%s\n' '{"total_count":1,"jobs":[{"id":1,"name":"lint","conclusion":"success"}]}' >"$T/fixtures/repos_o_r_actions_runs_991_jobs.json"
gshim_run run view 991 -R o/r --log-failed
eq "run-view-log-failed-none rc"     "$RC" "0"
eq "run-view-log-failed-none stdout" "$OUT" ""
eq "run-view-log-failed-none no logs" "$(countlines 'actions/jobs/')" "0"
printf '%s\n' '{"total_count":3,"jobs":[{"id":1,"name":"lint","conclusion":"success"},{"id":2,"name":"unit","conclusion":"failure"},{"id":3,"name":"build","conclusion":"success"}]}' >"$T/fixtures/repos_o_r_actions_runs_991_jobs.json"

# ── run-rerun ────────────────────────────────────────────────────────────────
gshim_reset
gshim_run run rerun 991 -R o/r
eq  "run-rerun rc"   "$RC" "0"
has "run-rerun call" "$(gshim_calls)" "-X POST repos/o/r/actions/runs/991/rerun"
hasnt "run-rerun not failed-jobs" "$(gshim_calls)" "rerun-failed-jobs"

# ── run-rerun-failed ─────────────────────────────────────────────────────────
gshim_reset
gshim_run run rerun 991 -R o/r --failed
eq  "run-rerun-failed rc"   "$RC" "0"
has "run-rerun-failed call" "$(gshim_calls)" "-X POST repos/o/r/actions/runs/991/rerun-failed-jobs"

# ── run-list-workflow-jq ─────────────────────────────────────────────────────
gshim_reset
gshim_run run list -R o/r --workflow ci.yml --event workflow_dispatch --limit 10 \
  --json databaseId,createdAt --jq '.[0].databaseId'
eq  "run-list rc"     "$RC" "0"
eq  "run-list stdout" "$OUT" "5"
has "run-list call"   "$(gshim_calls)" "api repos/o/r/actions/workflows/ci.yml/runs"
has "run-list query"  "$(gshim_calls)" "query=event=workflow_dispatch&per_page=10&page=1"
gshim_reset
gshim_run run list -R o/r --limit 5 --json databaseId,status
eq  "run-list-no-workflow stdout" "$OUT" '[{"databaseId":9,"status":"queued"}]'
has "run-list-no-workflow call"   "$(gshim_calls)" "api repos/o/r/actions/runs?per_page=5&page=1"

# ── run-list unmappable field passes through ─────────────────────────────────
gshim_reset
gshim_run run list -R o/r --json jobs
has   "run-list unmappable passthru" "$(gshim_calls)" "PASSTHRU run list -R o/r --json jobs"
hasnt "run-list unmappable no rest"  "$(gshim_calls)" "api repos/o/r/actions/runs"

# ── bad --limit is the real binary's to reject (contract gshim_limit_ok) ───────
gshim_reset
gshim_run run list -R o/r --limit abc --json databaseId
has "run-list bad limit passthru" "$(gshim_calls)" "PASSTHRU run list -R o/r --limit abc"

echo "gh-shim-actions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
