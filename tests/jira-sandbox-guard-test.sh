#!/bin/bash
# tests/jira-sandbox-guard-test.sh — BH-4076: the Jira adapter
# (bin/lib/tracker/jira.sh) refuses any request about a project key that is
# not on the project's allowlist, and any write to an issue Jira says now lives
# somewhere else. Every case loads the allowlist the production way, through
# trk_jira_context and the settings rows
#   tracker_jira.jproj.write_projects   = CROM
#   tracker_jira.jproj.comment_projects = CMNT
#   tracker_jira.jproj.read_projects    = CROM CMNT
# against the gateway stub in tests/lib/tracker-jira-stub.sh. No network.
#
#   G1  positive control: a CROM-1 comment IS sent, after its guard GET
#   G2  every write verb on CLNT-5: rc 1, no request at all, a stderr line
#   G3  CROM-9 now answers as CLNT-88: every write rc 1, one GET, no write
#   G4  no write_projects row: no writes, reads still work
#   G5  settings worker 503: the context fails and nothing reaches Jira
#   G6  an inherited TRK_JIRA_* allowlist is overwritten by the context
#   G7  comment tier: comment/link_pr yes, transition/labels/close_out no
#   G8  malformed keys: rc 1, no request
#   G9  a dry run of a refused write: rc 1 and no DRYRUN line
#   G10 a read of an unlisted project: rc 1, no output, no request
#   G11 an allowlist row carrying JQL, or a glob: the context fails, no search,
#       no write
#   G12 across the whole suite, no request ever named a CLNT- issue
#
#   HARNESS_TEST_SANDBOX=1 bash tests/jira-sandbox-guard-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

jira_stub_setup "$T" || { echo "stub setup failed"; exit 1; }
. "$DIR/bin/lib/tracker.sh" || exit 1
tracker_load jira || { echo "FAIL: tracker_load jira"; exit 1; }
mkdir -p "$T/run"
TRK_LOG="$T/run/jira.log"; TRK_ERR="$T/run/curl.err"; TRK_DRY=0; TRK_REQ_FILE=""
S="$JIRA_STUB_STATE"
BODY="$T/run/body.txt"; printf 'Shipped.\n' > "$BODY"
PR=https://github.com/o/r/pull/9
fresh() { rm -f "$S/requests" "$S/writes" "$S/arm" "$S"/body-*; }
nw() { cat "$S/writes" 2>/dev/null | grep -c .; }
nr() { jira_requests | grep -c .; }
ctx() { trk_jira_context jproj 2>"$T/run/ctx.err"; }

# run_verb <verb> <key> — the verb with the arguments it needs; stderr to $T/run/v.err
run_verb() {
  case "$1" in
    comment|close_out) "tracker_$1" "$2" "$BODY" ;;
    transition) tracker_transition "$2" Done ;;
    label_add|label_remove) "tracker_$1" "$2" ai-build ;;
    link_pr) tracker_link_pr "$2" "$PR" ;;
    read) tracker_read "$2" ;;
  esac 2>"$T/run/v.err"
}
WRITES="comment transition label_add label_remove link_pr close_out"

# --- G1 -------------------------------------------------------------------
fresh; ctx && ok || bad "G1 context rc=$?: $(cat "$T/run/ctx.err")"
run_verb comment CROM-1 >/dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "G1 a CROM-1 comment must be sent (rc=$rc): $(cat "$T/run/v.err")"
[ "$(cat "$S/writes" 2>/dev/null)" = "comment CROM-1" ] && ok || bad "G1 one comment write: $(cat "$S/writes" 2>/dev/null)"
[ "$(jira_requests | tr '\n' '|')" = "GET /rest/api/3/issue/CROM-1?fields=project,labels,status|POST /rest/api/3/issue/CROM-1/comment|" ] \
  && ok || bad "G1 the guard GET, then the comment: $(jira_requests)"

# --- G2 -------------------------------------------------------------------
for v in $WRITES; do
  fresh
  run_verb "$v" CLNT-5 >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "G2 $v CLNT-5 rc=$rc, want 1"
  [ "$(nr)" = 0 ] && [ "$(nw)" = 0 ] && ok || bad "G2 $v CLNT-5 reached the stub: $(jira_requests)"
  grep -q "CLNT-5 is in project CLNT, not on jproj's" "$T/run/v.err" && ok || bad "G2 $v: the stderr line: $(cat "$T/run/v.err")"
done

# --- G3 -------------------------------------------------------------------
for v in $WRITES; do
  fresh
  run_verb "$v" CROM-9 >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "G3 $v CROM-9 (moved to CLNT-88) rc=$rc, want 1"
  [ "$(jira_requests)" = "GET /rest/api/3/issue/CROM-9?fields=project,labels,status" ] && ok || bad "G3 $v: exactly the one guard GET: $(jira_requests)"
  [ "$(nw)" = 0 ] && ok || bad "G3 $v wrote: $(cat "$S/writes")"
  grep -q 'CLNT-88' "$T/run/v.err" && ok || bad "G3 $v: stderr names where it went: $(cat "$T/run/v.err")"
done
fresh; out=$(run_verb read CROM-9); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "G3 a read of the moved issue prints nothing, rc 1 (rc=$rc): $out"

# --- G4 -------------------------------------------------------------------
jira_unset tracker_jira.jproj.write_projects
fresh; ctx && ok || bad "G4 context without a write row rc=$?: $(cat "$T/run/ctx.err")"
for v in $WRITES; do
  run_verb "$v" CROM-1 >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "G4 $v CROM-1 with no write row rc=$rc, want 1"
done
[ "$(nw)" = 0 ] && [ "$(jira_req_count '^(POST|PUT|DELETE) ')" = 0 ] && ok || bad "G4 a write went out: $(jira_requests)"
out=$(run_verb read CROM-1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .key)" = CROM-1 ] && ok || bad "G4 a read still works (rc=$rc): $out"
jira_set tracker_jira.jproj.write_projects CROM

# --- G5 -------------------------------------------------------------------
fresh; touch "$S/settings-down"
ctx; rc=$?
[ "$rc" = 1 ] && ok || bad "G5 a worker outage must fail the context (rc=$rc)"
[ -z "${TRK_JIRA_BASE:-}" ] && ok || bad "G5 TRK_JIRA_BASE survived a failed context: $TRK_JIRA_BASE"
[ "$(grep -c . "$S/settings.log")" -ge 1 ] && ok || bad "G5 the worker was never asked"
for v in $WRITES read; do
  run_verb "$v" CROM-1 >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "G5 $v after a failed context rc=$rc, want 1"
done
tracker_list >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "G5 list after a failed context rc=$rc"
[ "$(nr)" = 0 ] && ok || bad "G5 Jira was called: $(jira_requests)"
rm -f "$S/settings-down"

# --- G6 -------------------------------------------------------------------
fresh
export TRK_JIRA_WRITE_PROJECTS=CLNT TRK_JIRA_COMMENT_PROJECTS=CLNT TRK_JIRA_READ_PROJECTS=CLNT
ctx && ok || bad "G6 context rc=$?"
run_verb comment CLNT-5 >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(nr)" = 0 ] && ok || bad "G6 an inherited allowlist let CLNT-5 through (rc=$rc): $(jira_requests)"
[ "$TRK_JIRA_WRITE_PROJECTS" = CROM ] && ok || bad "G6 the context did not overwrite TRK_JIRA_WRITE_PROJECTS: $TRK_JIRA_WRITE_PROJECTS"
export -n TRK_JIRA_WRITE_PROJECTS TRK_JIRA_COMMENT_PROJECTS TRK_JIRA_READ_PROJECTS

# --- G7 -------------------------------------------------------------------
fresh; ctx
run_verb comment CMNT-3 >/dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "G7 comment on the comment-tier CMNT-3 rc=$rc: $(cat "$T/run/v.err")"
run_verb link_pr CMNT-3 >/dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "G7 link_pr on CMNT-3 rc=$rc: $(cat "$T/run/v.err")"
[ "$(cat "$S/writes" | tr '\n' '|')" = "comment CMNT-3|comment CMNT-3|" ] && ok || bad "G7 two comments: $(cat "$S/writes")"
fresh
for v in transition label_add label_remove close_out; do
  run_verb "$v" CMNT-3 >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "G7 $v on the comment-tier CMNT-3 rc=$rc, want 1"
  grep -q "not on jproj's write allowlist" "$T/run/v.err" && ok || bad "G7 $v: stderr: $(cat "$T/run/v.err")"
done
[ "$(nw)" = 0 ] && [ "$(nr)" = 0 ] && ok || bad "G7 a write-tier verb reached the stub: $(jira_requests)"

# --- G8 -------------------------------------------------------------------
fresh
for k in crom-1 CROM-01 10001 " CROM-1" "CROM-1 " "CROM-1/../CLNT-2" CROMX-1 CRO-1 ""; do
  for v in comment read; do
    out=$(run_verb "$v" "$k"); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "G8 $v '$k' rc=$rc, want 1 and no output"
  done
done
[ "$(nr)" = 0 ] && ok || bad "G8 a malformed key reached the stub: $(jira_requests)"

# --- G9 -------------------------------------------------------------------
fresh
out=$(TRK_DRY=1 run_verb comment CLNT-5); rc=$?
[ "$rc" = 1 ] && ok || bad "G9 a dry refused write must still be rc 1 (rc=$rc)"
grep -q DRYRUN <<<"$out" && bad "G9 a dry run reported a refused write: $out" || ok
out=$(TRK_DRY=1 run_verb comment CROM-1); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^DRYRUN ')" = 1 ] && ok || bad "G9 an allowed dry write prints one DRYRUN (rc=$rc): $out"
[ "$(nw)" = 0 ] && ok || bad "G9 a dry run wrote: $(cat "$S/writes")"

# --- G10 ------------------------------------------------------------------
fresh
out=$(run_verb read CLNT-5); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && [ "$(nr)" = 0 ] && ok || bad "G10 read CLNT-5 (rc=$rc out=$out): $(jira_requests)"

# --- G11 ------------------------------------------------------------------
fresh
jira_set tracker_jira.jproj.read_projects 'CROM") OR project = CLNT OR ("'
ctx; rc=$?
[ "$rc" = 1 ] && ok || bad "G11 an injected allowlist row must fail the context (rc=$rc)"
grep -q 'tracker_jira.jproj.read_projects' "$T/run/ctx.err" && ok || bad "G11 stderr names the row: $(cat "$T/run/ctx.err")"
tracker_list >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(jira_req_count search)" = 0 ] && ok || bad "G11 a search went out (rc=$rc): $(jira_requests)"
run_verb comment CROM-1 >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(nr)" = 0 ] && ok || bad "G11 a write after a failed context (rc=$rc): $(jira_requests)"
jira_set tracker_jira.jproj.read_projects "CROM CMNT"
# A glob in a row must not expand against the working directory: a file named
# CLNT beside the caller would otherwise become an allowlisted key.
mkdir -p "$T/globdir"; touch "$T/globdir/CLNT"
jira_set tracker_jira.jproj.write_projects 'CROM C*'
(cd "$T/globdir" && trk_jira_context jproj 2>/dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "G11 a write row holding a glob must fail the context (rc=$rc)"
(cd "$T/globdir" && trk_jira_context jproj 2>/dev/null; run_verb comment CLNT-5 >/dev/null; echo "rc=$?") | grep -qx 'rc=1' && ok || bad "G11 a globbed CLNT reached the allowlist"
[ "$(nr)" = 0 ] && ok || bad "G11 the glob case sent: $(jira_requests)"
jira_set tracker_jira.jproj.write_projects CROM

# --- G12 ------------------------------------------------------------------
# `requests` is cleared per case; requests.all is the stub's whole-suite log,
# which fresh never touches.
[ "$(grep -c . "$S/requests.all")" -gt 10 ] && ok || bad "G12 the whole-suite request log is (nearly) empty"
grep 'CLNT-' "$S/requests.all" && bad "G12 a request named a CLNT- issue" || ok
[ ! -e "$S/authbad" ] && ok || bad "G12 a call went out with the wrong credential: $(cat "$S/authbad")"

echo "jira-sandbox-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
