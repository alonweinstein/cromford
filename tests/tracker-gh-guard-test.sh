#!/bin/bash
# tests/tracker-gh-guard-test.sh — bin/gh-ledger/gh (the `gh` first on every
# lane's PATH) refuses a GitHub ISSUE write on the app repo of a project whose
# tracker_adapter row is jira or linear (bin/lib/tracker-gh-guard.sh).
#
#   G1  gh issue create|comment|close -R <repo> is refused, nothing reaches gh
#   G2  gh api POST/PATCH/DELETE on repos/<repo>/issues…, fields with no -X too
#   G3  a numbered path that is a pull request goes through (PRs stay on GitHub)
#   G4  reads, and `gh pr …`, go through and pay no settings call
#   G5  a GitHub-Issues project's repo is untouched
#   G6  fail-open: a settings outage, or the switch, lets the write through
#
# No network: the real `gh` and `curl` are stubs.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-gh-guard-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

S="$T/ls"
mkdir -p "$T/h/bin" "$T/h/flags" "$T/h/state" "$T/real" "$S"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  o/l  https://lin.example  -  9
ghp      o/r  https://gh.example   -  9
CONF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$S" > "$T/h/bin/alert-line.sh"
cat > "$T/real/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TG_STATE/real.log"
case "$*" in
  "api repos/o/l/pulls/7 "*) exit 0 ;;
  "api repos/"*"/pulls/"*) exit 1 ;;
esac
exit 0
SH
cat > "$T/real/curl" <<'SH'
#!/bin/bash
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -w) fmt="$2"; shift ;; -X|-m|--max-time|--connect-timeout|-H|-d|--data-binary) shift ;; http*) url="$1" ;; esac
  shift
done
reply() { if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; exit 0; }
case "$url" in
  https://jobs.example/api/settings/*)
    echo "${url##*/}" >> "$TG_STATE/settings.log"
    [ -e "$TG_STATE/down" ] && reply 503 '{"error":"down"}'
    f="$TG_STATE/setting-${url##*/}"; [ -r "$f" ] && reply 200 "$(cat "$f")"
    reply 404 '{"error":"no such setting"}' ;;
esac
reply 404 '{}'
SH
chmod +x "$T/h/bin/alert-line.sh" "$T/real/gh" "$T/real/curl"
jq -n '{setting:{key:"tracker_adapter.linproj",value:"linear"}}' > "$S/setting-tracker_adapter.linproj"

export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" TG_STATE="$S" GH_TOKEN=fixture-token GH_LEDGER_OFF=1
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export PATH="$DIR/bin/gh-ledger:$T/real:$PATH"
fresh() { rm -f "$S/real.log" "$S/settings.log" "$S/alerts"; }
sent()  { grep -qF -- "$1" "$S/real.log" 2>/dev/null; }
run()   { gh "$@" >/dev/null 2>"$T/err"; }

# --- G1 -------------------------------------------------------------------
for args in "issue comment 12 -R o/l --body hi" "issue close 12 --repo o/l" "issue create --repo=o/l --title t --body b"; do
  fresh
  # shellcheck disable=SC2086
  run $args; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$S/real.log" ] && grep -q 'refused' "$T/err" && ok || bad "G1 'gh $args' must be refused (rc=$rc): $(cat "$S/real.log" "$T/err" 2>/dev/null)"
done
grep -q 'tracker-gh-guard.*o/l.*linear' "$S/alerts" 2>/dev/null && ok || bad "G1 one ALERTS line names the repo and tracker: $(cat "$S/alerts" 2>/dev/null)"

# --- G2 -------------------------------------------------------------------
for args in "api -X POST repos/o/l/issues/12/comments -f body=hi" "api repos/o/l/issues/12/comments -f body=hi" \
            "api --method=PATCH /repos/o/l/issues/12 -f state=closed" "api -X DELETE repos/o/l/issues/12/labels/ai-build" \
            "api -X POST repos/o/l/issues -f title=t" "api -X PATCH repos/o/l/issues/comments/99 -f body=x"; do
  fresh
  # shellcheck disable=SC2086
  run $args; rc=$?
  [ "$rc" = 1 ] && ! sent "issues" && ok || bad "G2 'gh $args' must be refused (rc=$rc): $(cat "$S/real.log" 2>/dev/null)"
done

# --- G3 -------------------------------------------------------------------
fresh; run api -X POST repos/o/l/issues/7/comments -f body=hi; rc=$?
[ "$rc" = 0 ] && sent "api -X POST repos/o/l/issues/7/comments" && ok || bad "G3 a comment on PR #7 goes through (rc=$rc): $(cat "$S/real.log" 2>/dev/null)"

# --- G4 -------------------------------------------------------------------
for args in "api repos/o/l/issues/12" "api -X GET repos/o/l/issues/12/comments" "issue view 12 -R o/l" "pr comment 5 -R o/l --body hi" "issue list -R o/l"; do
  fresh
  # shellcheck disable=SC2086
  run $args; rc=$?
  [ "$rc" = 0 ] && [ -s "$S/real.log" ] && [ ! -s "$S/settings.log" ] && ok || bad "G4 'gh $args' goes through with no lookup (rc=$rc)"
done

# --- G5 -------------------------------------------------------------------
fresh; run issue comment 12 -R o/r --body hi; rc=$?
[ "$rc" = 0 ] && sent "issue comment 12 -R o/r" && ok || bad "G5 a GitHub-Issues project's write goes through (rc=$rc)"

# --- G6 -------------------------------------------------------------------
fresh; : > "$S/down"; run issue comment 12 -R o/l --body hi; rc=$?; rm -f "$S/down"
[ "$rc" = 0 ] && sent "issue comment 12 -R o/l" && ok || bad "G6 a settings outage lets the write through (rc=$rc)"
fresh; GH_TRACKER_GUARD_OFF=1 run issue comment 12 -R o/l --body hi; rc=$?
[ "$rc" = 0 ] && [ ! -s "$S/settings.log" ] && ok || bad "G6 GH_TRACKER_GUARD_OFF=1 lets it through"
fresh; : > "$T/h/flags/tracker-gh-guard-off"; run issue comment 12 -R o/l --body hi; rc=$?; rm -f "$T/h/flags/tracker-gh-guard-off"
[ "$rc" = 0 ] && ok || bad "G6 flags/tracker-gh-guard-off lets it through"

echo "tracker-gh-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
