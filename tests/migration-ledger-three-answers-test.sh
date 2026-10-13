#!/bin/bash
# tests/migration-ledger-three-answers-test.sh — BH-1040.
#
# THE BUG THIS PINS. bin/migration-autopilot.sh's ledger_has collapsed the two
# non-zero answers of job_ledger_get into one: rc 2 ("worker reachable, no such
# row") and rc 1 ("the API is unusable") both came back as "absent". So with an
# empty state/migration-autopilot-done.txt and harness-jobs down, a file the
# autopilot had already ledgered as failed-alerted / flagged / applied was
# carried straight through the classifier, the deploy gate and the apply POST as
# if it had never been seen. The ledger exists to stop exactly that (the pb67
# alert storm); it failed OPEN on the one condition it was built for.
#
# So the three answers get a test each, through the PRODUCTION ENTRY POINT —
# both scripts are run as scripts, not sourced for their functions:
#   present  -> skip; the DB row is the only store (BH-2623: no done-file)
#   absent   -> proceed exactly as before, apply once
#   unknown  -> HOLD: no classifier, no POST, one alert, rc 0, next tick re-asks
# plus the same three answers in bin/check-migration-prs.sh, which now dedupes
# on the same ledgers(kind=migration) rather than its own private text file.
#
# NOTHING HERE TOUCHES THE LIVE HARNESS. Every path is under $T, gh/curl are
# fixtures in $T/fakebin, and jobs-client.sh is a stub whose answers are driven
# by $T/ledger-mode. No network call is made and no real migration is applied.
# Run from anywhere: tests/migration-ledger-three-answers-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq required by this test";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required by this test"; exit 1; }

# Real-file tripwire: the live artifacts these scripts write must not move.
REALDONE=/root/harness/state/migration-autopilot-done.txt
REALALERTED=/root/harness/state/migration-prs-alerted.txt
snap() { [ -f "$1" ] && stat -c '%Y %s' "$1" || echo absent; }
D0=$(snap "$REALDONE"); A0=$(snap "$REALALERTED")

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" "$T/calls" "$T/repo"

cp "$DIR/bin/migration-autopilot.sh" "$DIR/bin/check-migration-prs.sh" "$T/bin/"
# alert-state.sh comes with the copy on purpose: BOTH lanes ask it whether
# lane-alert.sh is actually deduping on --id, so a fixture without it would test
# the fallback everywhere and never the production path.
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/"

# ---- the repo the deploy gate and the classifier read ----------------------
# Two commits: the migration must have a parent, because the autopilot asks for
# the PR's OWN change (git diff --diff-filter=A "$MC^" "$MC").
git -C "$T/repo" init -q -b main
git -C "$T/repo" config user.email t@t.invalid
git -C "$T/repo" config user.name  tester
echo readme > "$T/repo/README.md"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m init
mkdir -p "$T/repo/scripts/migrations"
printf 'ALTER TABLE t ADD COLUMN c text;\n' > "$T/repo/scripts/migrations/0001_x.sql"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m "add 0001_x.sql"
MC=$(git -C "$T/repo" rev-parse HEAD)
MC0=$(git -C "$T/repo" rev-parse HEAD~1)   # what prod serves when the deploy has not landed

# ---- env: a worker IS configured (HARNESS_SECRET set) ----------------------
cat > "$T/env/global.env" <<'EOF'
HARNESS_SECRET=fixture-secret
JOBS_URL=http://jobs.invalid
EOF
cat > "$T/env/project-1.env" <<'EOF'
PROJECT_1_API_BASE=http://app.test
PROJECT_1_INTERNAL_API_TOKEN=fixture-internal
MIGRATION_TOKEN=fixture-migration
EOF

# ---- fixtures for everything the two scripts shell out to ------------------
# The slug names its project: since BH-4080 check-migration-prs.sh reads each
# repo from here rather than a literal table, and the gh stub below keys on it.
cat > "$T/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "${2:-}" = repo ] && echo "example-org/$1"
exit 0
EOF
cat > "$T/bin/check-migration-appliable.sh" <<'EOF'
#!/bin/bash
echo "appliable"
exit 0
EOF
cat > "$T/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/beat"
exit 0
EOF
cat > "$T/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/lane-alert"
exit 0
EOF
chmod +x "$T/bin/fleet-conf.sh" "$T/bin/check-migration-appliable.sh" \
         "$T/bin/beat.sh" "$T/bin/lane-alert.sh"

# gh: one merged migration PR (#5, by operator, merge commit = the repo HEAD).
# Two shapes, because the two lanes ask for different things: the autopilot asks
# for --json number,author,mergeCommit,files, check-migration-prs.sh asks with
# -q and so receives the jq filter's TSV. Only project-1 has a row, so the
# check lane's pass over four repos produces exactly one candidate.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"--limit 100"*)
    jq -nc --arg oid "$MC" '[{number:5,author:{login:"operator"},mergeCommit:{oid:\$oid},files:[{path:"scripts/migrations/0001_x.sql"}]}]'
    ;;
  *"--limit 15"*)
    case "\$*" in *project-1*) printf '5\tadd 0001_x.sql\t0001_x.sql\n' ;; esac
    ;;
esac
exit 0
EOF

# curl: the app's three endpoints. The apply POST is recorded, one line per
# call, and the status ledger starts empty and lists the file only AFTER an
# apply — the autopilot verifies through status, so a stub that always answered
# "applied" would hide a missing POST rather than prove one.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL=""
for a in "\$@"; do case "\$a" in http*) URL="\$a" ;; esac; done
case "\$URL" in
  */api/internal/version)
    # $T/serving-old = the deploy carrying the merge has NOT landed yet, which
    # is the case where a hold blocks nothing that could have run this tick.
    if [ -f "$T/serving-old" ]; then printf '{"sha":"%s"}' "$MC0"
    else printf '{"sha":"%s"}' "$MC"; fi
    exit 0 ;;
  */api/internal/migrations/status)
    if [ -f "$T/calls/apply-post" ] || [ -f "$T/app-applied" ]; then
      printf '{"applied":[{"filename":"0001_x.sql"}]}'
    else printf '{"applied":[]}'; fi
    exit 0 ;;
  */api/internal/migrations/apply)
    printf '%s\n' "\$URL" >> "$T/calls/apply-post"
    printf '{"ok":true,"status":"applied"}'; exit 0 ;;
esac
exit 22
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# jobs-client stub. Its rc contract is job_ledger_get's real one
# (bin/jobs-client.sh:292-311): 0 + status on a row, 2 on a reachable miss,
# 1 when the API is unusable. It also loads HARNESS_SECRET from env/global.env
# the way the real client does, because that load is what tells a lane a worker
# is configured at all. $T/ledger-mode drives which answer comes back.
cat > "$T/bin/jobs-client.sh" <<EOF
#!/bin/bash
if [ -z "\${HARNESS_SECRET:-}" ] && [ -r "$T/env/global.env" ]; then
  HARNESS_SECRET=\$(sed -n 's/^HARNESS_SECRET=//p' "$T/env/global.env" | head -1)
  [ -n "\$HARNESS_SECRET" ] && export HARNESS_SECRET
fi
job_ledger_get() { # <kind> <key>
  printf '%s\t%s\n' "\$1" "\$2" >> "$T/calls/ledger-get"
  local mode st
  mode=\$(cat "$T/ledger-mode" 2>/dev/null)
  case "\$mode" in
    outage) return 1 ;;
    absent) return 2 ;;
    present:*) printf '%s' "\${mode#present:}"; return 0 ;;
    rows)
      st=\$(awk -F'\t' -v k="\$2" '\$1==k{print \$2; f=1} END{exit !f}' "$T/ledger-rows.tsv" 2>/dev/null) || return 2
      [ -n "\$st" ] || return 1
      printf '%s' "\$st"; return 0 ;;
  esac
  return 1
}
job_ledger_put() { # <kind> <key> <status>
  printf '%s\t%s\t%s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls/ledger-put"
  return 0
}
EOF

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
reset() {
  rm -rf "$T/calls" "$T/logs" "$T/state" "$T/locks" "$T/app-applied"
  rm -f "$T/flags/alert-state-off" "$T/serving-old"
  mkdir -p "$T/calls" "$T/logs" "$T/state" "$T/locks"
  # The call logs exist from the start so `grep -c` always prints a number and
  # an assertion can never read "file absent" as "count 0".
  : > "$T/calls/beat"; : > "$T/calls/lane-alert"
  : > "$T/calls/ledger-get"; : > "$T/calls/ledger-put"
  : > "$T/ledger-rows.tsv"
}
mode() { printf '%s' "$1" > "$T/ledger-mode"; }
row()  { printf '%s\t%s\n' "$1" "$2" >> "$T/ledger-rows.tsv"; }

run_autopilot() {
  HARNESS="$T" MIGRATION_AUTOPILOT_REPO_DIR="$T/repo" PATH="$T/fakebin:$PATH" \
    bash "$T/bin/migration-autopilot.sh" project-1
}
run_checkprs() {
  HARNESS="$T" PATH="$T/fakebin:$PATH" bash "$T/bin/check-migration-prs.sh"
}

DONE="$T/state/migration-autopilot-done.txt"
ALERTED="$T/state/migration-prs-alerted.txt"
posts()      { if [ -f "$T/calls/apply-post" ]; then wc -l < "$T/calls/apply-post"; else echo 0; fi; }
gets()       { wc -l < "$T/calls/ledger-get"; }
beats()      { wc -l < "$T/calls/beat"; }
# A HOLD alert is a lane-alert call on the hold id that is NOT the --resolve
# that closes it — counting both as "an alert" would read the healthy path as a
# page.
holds()      { awk '/--id migration-autopilot-hold/ && !/--resolve/ {n++} END{print n+0}' "$T/calls/lane-alert"; }
resolves()   { awk '/--resolve/ {n++} END{print n+0}' "$T/calls/lane-alert"; }
noput()      { [ ! -s "$T/calls/ledger-put" ]; }
# A ledger_put line, tab separated exactly as the stub records it. Status is
# matched as a PREFIX so "applied PR#5 serving=abc1234" still matches.
putline()    { printf 'migration\t%s\t%s' "$1" "$2"; }

# ===========================================================================
# 1. autopilot, ledger UNKNOWN (worker unreachable) + empty done-file
#    -> HOLD. Nothing applied, nothing ledgered, exactly one alert, rc 0.
# ===========================================================================
reset; mode outage
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "1: a HOLD must exit 0 (got rc=$RC)"
[ "$(posts)" = 0 ] && ok || bad "1: THE BUG — the apply POST ran while the ledger could not be read ($(posts) posts)"
[ "$(holds)" = 1 ] && ok || bad "1: want exactly one HOLD alert, got $(holds): $(cat "$T/calls/lane-alert" 2>/dev/null)"
grep -q -- '--id migration-autopilot-hold:project-1' "$T/calls/lane-alert" 2>/dev/null && ok \
  || bad "1: the HOLD alert carries no stable --id, so every tick would page again"
[ "$(resolves)" = 0 ] && ok || bad "1: an unreadable ledger must not resolve the hold condition"
grep -q -- '--severity critical' "$T/calls/lane-alert" 2>/dev/null && ok \
  || bad "1: a hold that blocks a migration prod is already serving must page critical: $(cat "$T/calls/lane-alert" 2>/dev/null)"
[ ! -s "$DONE" ] && ok || bad "1: the done-file was written during an outage: $(cat "$DONE")"
noput && ok || bad "1: a ledger row was written during an outage: $(cat "$T/calls/ledger-put")"
grep -q 'holding this run' "$T/logs/project-1.log" 2>/dev/null && ok \
  || bad "1: no hold line in the project log: $(cat "$T/logs/project-1.log" 2>/dev/null)"

# 1b. the same hold on a box whose harness-sync predates bin/lane-alert.sh: the
#     FAIL shape instead (one ALERTS.log line + one fleet_alert beat), and still
#     no apply. D13 — the line says "nothing applied", and it is rendered on the
#     only path that renders it, which is before any POST.
reset; mode outage
mv "$T/bin/lane-alert.sh" "$T/lane-alert.sh.off"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "1b: rc=$RC"
[ "$(posts)" = 0 ] && ok || bad "1b: applied without a readable ledger on the fallback path"
grep -q 'MIGRATION AUTOPILOT HOLD' "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "1b: no ALERTS.log line without lane-alert.sh: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
grep -q 'nothing applied' "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "1b: the alert does not say what did NOT happen"
[ "$(beats)" = 1 ] && ok || bad "1b: want one fallback beat, got $(beats)"
grep -q '"akey":"migration-autopilot-hold:project-1"' "$T/calls/beat" && ok \
  || bad "1b: the fallback beat has no stable akey: $(cat "$T/calls/beat")"
[ ! -s "$DONE" ] && ok || bad "1b: wrote the done-file on the fallback path: $(cat "$DONE")"
mv "$T/lane-alert.sh.off" "$T/bin/lane-alert.sh"

# 1c. lane-alert.sh IS present but the alert state machine is OFF
#     (flags/alert-state-off). Its legacy path ignores --id entirely and beats
#     akey="orclane:<lane>:$(date +%Y%m%d%H%M)" — a fresh key every tick, so
#     "ONE alert per condition" would become a page every tick per project.
#     The hold must route to its own deduped shape instead.
reset; mode outage
: > "$T/flags/alert-state-off"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "1c: rc=$RC"
[ "$(posts)" = 0 ] && ok || bad "1c: applied without a readable ledger"
[ "$(holds)" = 0 ] && ok \
  || bad "1c: routed to lane-alert.sh with its state machine off — that path mints a per-minute akey and storms"
[ "$(beats)" = 1 ] && ok || bad "1c: want one deduped beat with the state machine off, got $(beats)"
grep -q '"akey":"migration-autopilot-hold:project-1"' "$T/calls/beat" && ok \
  || bad "1c: the state-machine-off beat has no stable akey: $(cat "$T/calls/beat")"

# 1d. the same hold while prod is NOT yet serving the merge. Nothing would have
#     been applied this tick either (the deploy gate is a local merge-base and
#     needs no ledger), so the page must be proportional: warn, not critical.
reset; mode outage
: > "$T/serving-old"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "1d: rc=$RC"
[ "$(holds)" = 1 ] && ok || bad "1d: want exactly one HOLD alert, got $(holds)"
grep -q -- '--severity warn' "$T/calls/lane-alert" 2>/dev/null && ok \
  || bad "1d: paged critical for a file the deploy gate would have held anyway: $(cat "$T/calls/lane-alert" 2>/dev/null)"
[ "$(posts)" = 0 ] && ok || bad "1d: applied without a readable ledger"

# ===========================================================================
# 2. autopilot, ledger PRESENT (DB row) -> skip. Since BH-2623 the DB row is
#    the only store: no done-file is back-filled, and every tick asks the DB.
# ===========================================================================
reset; mode 'present:applied PR#7'
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "2: rc=$RC"
[ "$(posts)" = 0 ] && ok || bad "2: re-applied a migration the ledger already holds"
[ ! -e "$DONE" ] && ok || bad "2: a DB hit still back-fills the done-file: $(cat "$DONE")"
[ "$(holds)" = 0 ] && ok || bad "2: a successful read raised a HOLD alert"
[ "$(resolves)" = 1 ] && ok || bad "2: a reachable ledger must close the hold condition once ($(resolves))"
# and the next tick asks the DB again (there is no file to answer first), and
# still does not apply.
BEFORE=$(gets); run_autopilot
[ "$(gets)" -gt "$BEFORE" ] && ok || bad "2: the second run did not re-ask the DB ledger"
[ "$(posts)" = 0 ] && ok || bad "2: the second run re-applied ($(posts) posts)"

# ===========================================================================
# 3. autopilot, ledger ABSENT (a real miss) -> today's behaviour, apply once.
# ===========================================================================
reset; mode absent
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "3: rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "3: want exactly one apply POST, got $(posts)"
[ ! -e "$DONE" ] && ok || bad "3: the apply still writes the done-file: $(cat "$DONE")"
grep -qF "$(putline 'project-1 0001_x.sql' 'applied PR#5')" "$T/calls/ledger-put" && ok \
  || bad "3: the apply was not written through to the ledger: $(cat "$T/calls/ledger-put" 2>/dev/null)"
[ "$(holds)" = 0 ] && ok || bad "3: a real miss raised a HOLD alert"
# second run: the DB is asked again (the stub still answers absent) and the
# app's own ledger (is_applied) stops a second POST.
BEFORE=$(gets); run_autopilot
[ "$(posts)" = 1 ] && ok || bad "3: the second run re-applied ($(posts) posts total)"
[ "$(gets)" -gt "$BEFORE" ] && ok || bad "3: the second run did not re-ask the DB ledger"

# ===========================================================================
# 4. check-migration-prs, ledger UNKNOWN -> no ping this tick, one log line.
# ===========================================================================
reset; mode outage
run_checkprs; RC=$?
[ "$RC" = 0 ] && ok || bad "4: rc=$RC"
[ "$(beats)" = 0 ] && ok || bad "4: pinged a human while the dedupe ledger was unreadable"
grep -q 'ledger unreachable' "$T/logs/migrations.log" 2>/dev/null && ok \
  || bad "4: the skipped tick left no record: $(cat "$T/logs/migrations.log" 2>/dev/null)"
noput && ok || bad "4: wrote a ledger row during an outage: $(cat "$T/calls/ledger-put")"
[ ! -s "$ALERTED" ] && ok || bad "4: fell back to writing the legacy file: $(cat "$ALERTED")"
# ...and the SILENCE is itself visible. logs/migrations.log is tailed by nothing
# (the header at :16-19 says this lane deliberately moved off ALERTS.log), so a
# skipped tick with only a log line means a merged migration-SQL PR that needs a
# human is announced nowhere for the whole outage.
prs_unknown() { awk '/--id migration-prs-ledger-unknown/ && !/--resolve/ {n++} END{print n+0}' "$T/calls/lane-alert"; }
[ "$(prs_unknown)" = 1 ] && ok \
  || bad "4: the lane went dark on an unreadable ledger with no alert at all ($(prs_unknown)): $(cat "$T/calls/lane-alert" 2>/dev/null)"
grep -q -- '--severity warn' "$T/calls/lane-alert" 2>/dev/null && ok \
  || bad "4: a delayed ping is a warn, not a page: $(cat "$T/calls/lane-alert" 2>/dev/null)"
[ "$(resolves)" = 0 ] && ok || bad "4: an unreadable ledger must not close the unknown condition"

# 4b. ONE per run, not one per PR/repo — the loop spans four repos.
[ "$(awk '/--id migration-prs-ledger-unknown/ && !/--resolve/ {n++} END{print n+0}' "$T/calls/lane-alert")" = 1 ] && ok \
  || bad "4b: the unknown alert is raised more than once in a single run"

# 4c. a run that completes with every read answered closes the condition, once.
reset; mode absent
run_checkprs
[ "$(resolves)" = 1 ] && ok \
  || bad "4c: a healthy run did not close the ledger-unknown condition ($(resolves)): $(cat "$T/calls/lane-alert" 2>/dev/null)"
grep -q -- '--id migration-prs-ledger-unknown' "$T/calls/lane-alert" 2>/dev/null && ok \
  || bad "4c: the resolve does not carry the id it opened with: $(cat "$T/calls/lane-alert" 2>/dev/null)"

# ===========================================================================
# 5. check-migration-prs, the PR's own row is PRESENT -> already pinged, quiet.
# ===========================================================================
reset; mode rows; row 'example-org/project-1#5' alerted
run_checkprs
[ "$(beats)" = 0 ] && ok || bad "5: re-pinged a PR the ledger already records as alerted"
noput && ok || bad "5: rewrote a row that was already there: $(cat "$T/calls/ledger-put")"

# ===========================================================================
# 6. check-migration-prs, the AUTOPILOT already applied every file -> no ping.
#    The two lanes share kind=migration with two key shapes, which is the whole
#    point of moving this lane onto it.
# ===========================================================================
reset; mode rows; row 'project-1 0001_x.sql' 'applied PR#5'
run_checkprs
[ "$(beats)" = 0 ] && ok || bad "6: pinged a human for SQL the autopilot had already applied"
grep -qF "$(putline 'example-org/project-1#5' 'applied-per-autopilot')" "$T/calls/ledger-put" && ok \
  || bad "6: the suppression was not recorded: $(cat "$T/calls/ledger-put" 2>/dev/null)"

# 6b. NEGATIVE: only applied* counts. A flagged/failed/skipped row is exactly
#     the case a human still has to look at.
reset; mode rows; row 'project-1 0001_x.sql' 'flagged PR#5'
run_checkprs
[ "$(beats)" = 1 ] && ok || bad "6b: a classifier-FLAGGED file stopped paging a human ($(beats) beats)"

# ===========================================================================
# 7. check-migration-prs, ABSENT -> ping once, record in the ledger, and do
#    NOT write the legacy file.
# ===========================================================================
reset; mode absent
run_checkprs
[ "$(beats)" = 1 ] && ok || bad "7: want exactly one beat, got $(beats)"
grep -q '"akey":"migration:example-org/project-1#5"' "$T/calls/beat" && ok \
  || bad "7: the beat's akey changed: $(cat "$T/calls/beat")"
grep -qF "$(putline 'example-org/project-1#5' 'alerted')" "$T/calls/ledger-put" && ok \
  || bad "7: the ping was not recorded in the ledger: $(cat "$T/calls/ledger-put" 2>/dev/null)"
[ ! -s "$ALERTED" ] && ok \
  || bad "7: still writing state/migration-prs-alerted.txt with a worker configured: $(cat "$ALERTED")"

# ===========================================================================
# 8. check-migration-prs with NO worker configured -> byte-for-byte the old
#    lane: one beat, key appended to the legacy file. (tests/remediator-agent-
#    test.sh runs it in exactly this shape.)
# ===========================================================================
reset; mode absent
mv "$T/bin/jobs-client.sh" "$T/jobs-client.sh.off"
run_checkprs
[ "$(beats)" = 1 ] && ok || bad "8: no-worker path beat $(beats) times"
grep -qxF 'example-org/project-1#5' "$ALERTED" && ok \
  || bad "8: the legacy dedupe file stopped being written without a worker: $(cat "$ALERTED" 2>/dev/null)"
# ...and it dedupes on that file, as it always did
run_checkprs
[ "$(beats)" = 1 ] && ok || bad "8: the no-worker path stopped deduping ($(beats) beats)"
mv "$T/jobs-client.sh.off" "$T/bin/jobs-client.sh"

# ===========================================================================
# 9. check-migration-prs, ABSENT but the legacy file already holds the key ->
#    no re-page on the first tick after this ships; the key is back-filled.
# ===========================================================================
reset; mode absent
echo 'example-org/project-1#5' > "$ALERTED"
run_checkprs
[ "$(beats)" = 0 ] && ok || bad "9: re-paged a PR the legacy file had already alerted on"
grep -qF "$(putline 'example-org/project-1#5' 'legacy-file')" "$T/calls/ledger-put" && ok \
  || bad "9: the legacy key was not back-filled: $(cat "$T/calls/ledger-put" 2>/dev/null)"

# ===========================================================================
# 10. check-migration-prs, the APP's own ledger already lists every file ->
#     the pre-existing quiet branch, now recording to the ledger instead of the
#     legacy file. This is the one line of that branch this change touches.
# ===========================================================================
reset; mode absent; : > "$T/app-applied"
run_checkprs
[ "$(beats)" = 0 ] && ok || bad "10: pinged a human for SQL the app ledger already lists applied"
grep -qF "$(putline 'example-org/project-1#5' 'applied-per-app-ledger')" "$T/calls/ledger-put" && ok \
  || bad "10: the app-ledger suppression was not recorded: $(cat "$T/calls/ledger-put")"
[ ! -s "$ALERTED" ] && ok || bad "10: wrote the legacy file with a worker configured: $(cat "$ALERTED")"
grep -q 'already applied per app ledger' "$T/logs/migrations.log" 2>/dev/null && ok \
  || bad "10: the app-ledger log line changed: $(cat "$T/logs/migrations.log" 2>/dev/null)"

# ===========================================================================
# 11. the tripwire: nothing above touched the live harness.
# ===========================================================================
[ "$(snap "$REALDONE")" = "$D0" ] && ok || bad "11: the LIVE $REALDONE was modified"
[ "$(snap "$REALALERTED")" = "$A0" ] && ok || bad "11: the LIVE $REALALERTED was modified"

echo "migration-ledger-three-answers: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
