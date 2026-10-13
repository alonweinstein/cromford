#!/bin/bash
# tests/alerts-groom-pr-scope.v1-test.sh — bin/alerts-groom.sh's PR rule settles
# ONLY rows whose subject is the PR being open (V1 alert hygiene, 2026-09-25).
#
# The rule used to resolve ANY open row whose line named a PR once that PR was
# MERGED or CLOSED. A merge is exactly when these start, not end:
#   S1  POST-MERGE PROD QA FAILED   (bin/postmerge-qa.sh)   — real defects live in prod
#   S2  POST-MERGE PROD QA NOT RUN  (bin/postmerge-qa.sh)   — prod never observed
#   S3  HOTFIX POST-DEPLOY APPLY FAILED (bin/hotfix-after-deploy.sh)
#   S4  HOTFIX CLOSE-OUT OWED       (bin/hotfix-after-deploy.sh)
# Each must SURVIVE its PR merging. What still settles:
#   S5  a merge-queue / rebase-train / blocked-resolver ESCALATED row (the PR-open
#       subject, ALERTS_PR_SUBJECT_RE) on a merged or closed PR, any repo casing
#   S6  an mq-<kind>:<project>:<N> row with no URL, through the registry's repo
#   S7  mq-headbound / mq-tc SURVIVE a MERGE (unreviewed or failing code reached
#       main) and settle on a CLOSE without merge
#   S8  one GitHub question per PR per pass
# Run from anywhere: tests/alerts-groom-pr-scope.v1-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/stub" "$T/bin/lib"
export HARNESS="$T" PATH="$T/stub:$PATH" FLEET_CONF="$T/fleet.conf"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=s\n' > "$T/env/global.env"
cat > "$FLEET_CONF" <<'CONF'
project-4    example-org/project-4    - - 8 box-project-4-1 10.0.0.2
project-9 example-org/project-9 - - 5 box-project-9-1 10.0.0.3
CONF
ln -sf "$DIR/bin/fleet-conf.sh" "$T/bin/fleet-conf.sh"
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/alert_family.py" "$T/bin/alert_family.py"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fleet-projects-or-alert.sh"
printf '#!/bin/bash\necho ""\n' > "$T/bin/project-of.sh"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-for.sh"
printf 'import sys\n' > "$T/bin/alerts-supersede.py"
chmod +x "$T/bin/fleet-projects-or-alert.sh" "$T/bin/project-of.sh" "$T/bin/box-for.sh"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""; url=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && printf '%s\n' "\$a" >> "$T/posts.jsonl"
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */api/alerts/open) cat "$T/open.json" ;;
  */api/alerts/resolve) echo '{"resolved":1}' ;;
  *) echo '{}' ;;
esac
STUB
# PR states: 10/11/12/13/20 MERGED, 21 CLOSED (unmerged), 789 on project-9 MERGED.
cat > "$T/stub/gh" <<STUB
#!/bin/bash
echo "\$*" >> "$T/gh.log"
case "\$*" in
  *pull/21\ *|*pull/21) echo CLOSED ;;
  *pull/10*|*pull/11*|*pull/12*|*pull/13*|*pull/20*|*pull/22*|*project-9/pull/789*|*project-4/pull/1756*) echo MERGED ;;
  *) echo OPEN ;;
esac
STUB
chmod +x "$T/stub/curl" "$T/stub/gh"

U=https://github.com/example-org/project-4/pull
cat > "$T/open.json" <<JSON
{"alerts":[
 {"id":1,"akey":"alert:a1","project":"project-4","line":"2026-09-25 10:00:00Z [project-4] POST-MERGE PROD QA FAILED for TK-1 (abcd1234, $U/10): FAIL: the table did not render"},
 {"id":2,"akey":"prodqa-deploy:project-4:abcd","project":"project-4","line":"Post-merge QA gave up on TK-2 (abcd1234): no version endpoint 3h after merge (limit 2h) — prod is not confirmed serving this merge and nothing was driven ($U/11)"},
 {"id":3,"akey":"alert:a3","project":"project-4","line":"2026-09-25 10:00:00Z [project-4] HOTFIX POST-DEPLOY APPLY FAILED (abcd1234): PR $U/12 files: pending (build b1)"},
 {"id":4,"akey":"alert:a4","project":"project-4","line":"2026-09-25 10:00:00Z [project-4] HOTFIX CLOSE-OUT OWED (abcd1234): board comment not posted (PR $U/13, build b1)"},
 {"id":5,"akey":"alert:a5","project":"project-9","line":"[blocked-resolver] ESCALATED: The PR is OPEN and untouched: https://github.com/example-org/project-9/pull/789"},
 {"id":6,"akey":"alert:a6","project":"project-9","line":"[rebase-train] https://github.com/example-org/project-9/pull/789 parked after 2 failed rounds"},
 {"id":7,"akey":"mq-conflict:project-4:1756","project":"project-4","line":"Merge queue: semantic conflict with main, needs a hand"},
 {"id":8,"akey":"mq-headbound:project-4:20","project":"project-4","line":"Merge queue: #20 head is not the sha the review approved: $U/20"},
 {"id":9,"akey":"mq-headbound:project-4:21","project":"project-4","line":"Merge queue: #21 head is not the sha the review approved: $U/21"},
 {"id":10,"akey":"mq-tc:project-4:22","project":"project-4","line":"Merge queue: #22 rebase typecheck FAILED — needs a hand: $U/22"},
 {"id":11,"akey":"mq-stale:project-4:30","project":"project-4","line":"Merge queue: #30 fails against current main: $U/30"}
]}
JSON
HARNESS="$T" bash "$DIR/bin/alerts-groom.sh" >/dev/null 2>&1
RESOLVED=" $(jq -r '.ids[]? | tostring' "$T/posts.jsonl" 2>/dev/null | sort -n | tr '\n' ' ')"
has() { case "$RESOLVED" in *" $1 "*) return 0 ;; esac; return 1; }
has 1 && bad "S1: POST-MERGE PROD QA FAILED was resolved by its PR merging (resolved:$RESOLVED)" || ok
has 2 && bad "S2: POST-MERGE PROD QA NOT RUN / gave up was resolved by its PR merging (resolved:$RESOLVED)" || ok
has 3 && bad "S3: HOTFIX POST-DEPLOY APPLY FAILED was resolved by its PR merging (resolved:$RESOLVED)" || ok
has 4 && bad "S4: HOTFIX CLOSE-OUT OWED was resolved by its PR merging (resolved:$RESOLVED)" || ok
has 5 && has 6 && ok || bad "S5: PR-open subject rows on a merged project-9 PR must settle (resolved:$RESOLVED)"
has 7 && ok || bad "S6: an mq-* row with no URL must settle through the registry's repo (resolved:$RESOLVED)"
has 8 && bad "S7: mq-headbound on a MERGED PR must stay — unreviewed code reached main (resolved:$RESOLVED)" || ok
has 9 && ok || bad "S7: mq-headbound on a PR CLOSED without merge must settle (resolved:$RESOLVED)"
has 10 && bad "S7: mq-tc on a MERGED PR must stay — failing code reached main (resolved:$RESOLVED)" || ok
has 11 && bad "an OPEN PR's row must stay (resolved:$RESOLVED)" || ok
[ "$(grep -c 'project-9/pull/789' "$T/gh.log" 2>/dev/null)" = 1 ] && ok || bad "S8: one GitHub question per PR per pass: $(cat "$T/gh.log" 2>/dev/null)"
# the scoped rule never even asks GitHub about a row it could not settle
grep -q 'pull/10' "$T/gh.log" && bad "S1-S4 rows are not PR-subject rows; they should cost no GitHub call: $(cat "$T/gh.log")" || ok

echo "alerts-groom-pr-scope.v1: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
