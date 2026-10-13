#!/bin/bash
# tests/migration-autopilot-ledger.bh-2623-test.sh — BH-2623 (BH-2532.1).
#
# THE BUG THIS PINS. bin/migration-autopilot.sh kept state/migration-autopilot-
# done.txt as a write-through beside the ledgers(kind=migration) DB row, and
# read the FILE first: a row in the file made ledger_has answer "present"
# without asking job_ledger_get, so a migration the DB had no record of was
# skipped on the file's word. It also appended to the file on every decision,
# and a failed job_ledger_put was swallowed by `|| true` with no trace.
#
# After BH-2623 the DB row is the only store:
#   A1  DB says applied, no file          -> skipped, no file created
#   A2  file says applied, DB has no row  -> NOT skipped: DB asked, applied once
#   A3  DB unreachable                    -> HOLD, nothing applied or written
#   A4  a full applying run               -> no done-file exists afterwards
#   A5  a failed PUT                      -> exactly one log line
#   A6  an existing done-file             -> left byte-identical (never deleted)
#   N1  PUT fails, run twice              -> is_applied stops a second POST
#
# The real script is run as a script (D2); gh/curl are fixtures in $T/fakebin
# and jobs-client.sh is a stub driven by $T/ledger-mode and $T/put-mode.
# NOTHING HERE TOUCHES THE LIVE HARNESS.
# Run from anywhere: tests/migration-autopilot-ledger.bh-2623-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq required by this test";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required by this test"; exit 1; }

# Real-file tripwire: the live done-file must not move.
REALDONE=/root/harness/state/migration-autopilot-done.txt
snap() { [ -f "$1" ] && stat -c '%Y %s' "$1" || echo absent; }
D0=$(snap "$REALDONE")

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" "$T/calls" "$T/repo"
cp "$DIR/bin/migration-autopilot.sh" "$T/bin/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/"

# ---- the repo the deploy gate and the classifier read ----------------------
git -C "$T/repo" init -q -b main
git -C "$T/repo" config user.email t@t.invalid
git -C "$T/repo" config user.name  tester
echo readme > "$T/repo/README.md"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m init
mkdir -p "$T/repo/scripts/migrations"
printf 'ALTER TABLE t ADD COLUMN c text;\n' > "$T/repo/scripts/migrations/0001_x.sql"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m "add 0001_x.sql"
MC=$(git -C "$T/repo" rev-parse HEAD)

# ---- env: a worker IS configured -------------------------------------------
cat > "$T/env/global.env" <<'EOF'
HARNESS_SECRET=fixture-secret
JOBS_URL=http://jobs.invalid
EOF
cat > "$T/env/project-1.env" <<'EOF'
PROJECT_1_API_BASE=http://app.test
PROJECT_1_INTERNAL_API_TOKEN=fixture-internal
MIGRATION_TOKEN=fixture-migration
EOF

# ---- fixtures ---------------------------------------------------------------
cat > "$T/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "${2:-}" = repo ] && echo "o/repo"
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
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"--limit 100"*)
    jq -nc --arg oid "$MC" '[{number:5,author:{login:"operator"},mergeCommit:{oid:\$oid},files:[{path:"scripts/migrations/0001_x.sql"}]}]'
    ;;
esac
exit 0
EOF
# curl: prod serves the merge. The status ledger lists the file only after an
# apply POST (or when $T/app-applied exists), so a missing POST cannot hide.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL=""
for a in "\$@"; do case "\$a" in http*) URL="\$a" ;; esac; done
case "\$URL" in
  */api/internal/version) printf '{"sha":"%s"}' "$MC"; exit 0 ;;
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

# jobs-client stub, job_ledger_get's real rc contract: 0 + status on a row,
# 2 on a reachable miss, 1 when the API is unusable. job_ledger_put records
# every call and answers per $T/put-mode (ok -> 0, fail -> 1).
cat > "$T/bin/jobs-client.sh" <<EOF
#!/bin/bash
if [ -z "\${HARNESS_SECRET:-}" ] && [ -r "$T/env/global.env" ]; then
  HARNESS_SECRET=\$(sed -n 's/^HARNESS_SECRET=//p' "$T/env/global.env" | head -1)
  [ -n "\$HARNESS_SECRET" ] && export HARNESS_SECRET
fi
job_ledger_get() { # <kind> <key>
  printf '%s\t%s\n' "\$1" "\$2" >> "$T/calls/ledger-get"
  local mode
  mode=\$(cat "$T/ledger-mode" 2>/dev/null)
  case "\$mode" in
    outage) return 1 ;;
    absent) return 2 ;;
    present:*) printf '%s' "\${mode#present:}"; return 0 ;;
  esac
  return 1
}
job_ledger_put() { # <kind> <key> <status>
  printf '%s\t%s\t%s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls/ledger-put"
  [ "\$(cat "$T/put-mode" 2>/dev/null)" = fail ] && return 1
  return 0
}
EOF

# ---- helpers ----------------------------------------------------------------
reset() {
  rm -rf "$T/calls" "$T/logs" "$T/state" "$T/locks" "$T/app-applied"
  mkdir -p "$T/calls" "$T/logs" "$T/state" "$T/locks"
  : > "$T/calls/beat"; : > "$T/calls/lane-alert"
  : > "$T/calls/ledger-get"; : > "$T/calls/ledger-put"
  printf ok > "$T/put-mode"
}
mode()    { printf '%s' "$1" > "$T/ledger-mode"; }
putmode() { printf '%s' "$1" > "$T/put-mode"; }
run_autopilot() {
  HARNESS="$T" MIGRATION_AUTOPILOT_REPO_DIR="$T/repo" PATH="$T/fakebin:$PATH" \
    bash "$T/bin/migration-autopilot.sh" project-1
}
DONE="$T/state/migration-autopilot-done.txt"
PLOG="$T/logs/project-1.log"
posts() { if [ -f "$T/calls/apply-post" ]; then wc -l < "$T/calls/apply-post"; else echo 0; fi; }
gets()  { wc -l < "$T/calls/ledger-get"; }
puts()  { wc -l < "$T/calls/ledger-put"; }
holds() { awk '/--id migration-autopilot-hold/ && !/--resolve/ {n++} END{print n+0}' "$T/calls/lane-alert"; }
failed_lines() { if [ -f "$PLOG" ]; then grep -c 'migration ledger write failed' "$PLOG"; else echo 0; fi; }

# ===========================================================================
# A1. DB answers "applied", no done-file -> skipped, asked once, no file.
# ===========================================================================
reset; mode 'present:applied PR#5'
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC"
[ "$(posts)" = 0 ] && ok || bad "A1: applied a migration the DB ledger already holds ($(posts) posts)"
[ "$(gets)" = 1 ] && ok || bad "A1: want one ledger read, got $(gets)"
grep -qxF "$(printf 'migration\tproject-1 0001_x.sql')" "$T/calls/ledger-get" && ok \
  || bad "A1: the read did not use kind=migration key='project-1 0001_x.sql': $(cat "$T/calls/ledger-get")"
[ ! -e "$DONE" ] && ok || bad "A1: a DB hit still back-fills the done-file: $(cat "$DONE")"
[ "$(holds)" = 0 ] && ok || bad "A1: a successful read raised a HOLD"

# ===========================================================================
# A2. The done-file says applied, the DB has no row, the app has not applied
#     it -> the file is NOT consulted: the DB is asked and the apply runs once.
# ===========================================================================
reset; mode absent
echo "project-1 0001_x.sql applied PR#5" > "$DONE"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "A2: rc=$RC"
[ "$(gets)" -ge 1 ] && ok || bad "A2: THE BUG — skipped on the done-file without asking the DB ledger"
[ "$(posts)" = 1 ] && ok || bad "A2: want exactly one apply POST (file row must not shadow the DB), got $(posts)"
grep -qF "$(printf 'migration\tproject-1 0001_x.sql\tapplied PR#5')" "$T/calls/ledger-put" && ok \
  || bad "A2: the apply was not recorded in the DB ledger: $(cat "$T/calls/ledger-put")"

# ===========================================================================
# A3. DB unreachable -> HOLD: rc 0, no POST, no put, one alert, no file.
# ===========================================================================
reset; mode outage
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "A3: a HOLD must exit 0 (got rc=$RC)"
[ "$(posts)" = 0 ] && ok || bad "A3: applied while the ledger could not be read"
[ "$(puts)" = 0 ] && ok || bad "A3: wrote a ledger row during an outage: $(cat "$T/calls/ledger-put")"
[ "$(holds)" = 1 ] && ok || bad "A3: want exactly one HOLD alert, got $(holds)"
grep -q 'holding this run' "$PLOG" 2>/dev/null && ok || bad "A3: no hold line in the project log"
[ ! -e "$DONE" ] && ok || bad "A3: the done-file was created during an outage"

# ===========================================================================
# A4. A full applying run leaves no done-file behind.
# ===========================================================================
reset; mode absent
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "A4: rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "A4: want one apply POST, got $(posts)"
[ ! -e "$DONE" ] && ok || bad "A4: state/migration-autopilot-done.txt exists after a full run: $(cat "$DONE" 2>/dev/null)"
[ "$(failed_lines)" = 0 ] && ok || bad "A4: a successful put logged a write failure"

# ===========================================================================
# A5. A failed PUT logs exactly one line (it is no longer swallowed).
# ===========================================================================
reset; mode absent; putmode fail; : > "$T/app-applied"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "A5: rc=$RC"
[ "$(posts)" = 0 ] && ok || bad "A5: re-applied a file the app already lists"
[ "$(puts)" = 1 ] && ok || bad "A5: want one put attempt, got $(puts)"
[ "$(failed_lines)" = 1 ] && ok \
  || bad "A5: want exactly one 'migration ledger write failed' line, got $(failed_lines): $(cat "$PLOG" 2>/dev/null)"
grep 'migration ledger write failed' "$PLOG" 2>/dev/null | grep -q '0001_x.sql' && ok \
  || bad "A5: the failure line does not name the file"
[ ! -e "$DONE" ] && ok || bad "A5: fell back to the done-file on a failed put"

# ===========================================================================
# A6. An existing done-file is left alone: byte-identical, not deleted.
# ===========================================================================
reset; mode absent
echo "project-1 0000_other.sql applied PR#1" > "$DONE"
cp "$DONE" "$T/done.before"
run_autopilot
[ "$(posts)" = 1 ] && ok || bad "A6: want one apply POST, got $(posts)"
cmp -s "$T/done.before" "$DONE" && ok || bad "A6: the existing done-file was changed or deleted"

# ===========================================================================
# N1. PUT fails on the apply, next tick: is_applied answers, no second POST.
# ===========================================================================
reset; mode absent; putmode fail
run_autopilot
[ "$(posts)" = 1 ] && ok || bad "N1: first run want one POST, got $(posts)"
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "N1: second run rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "N1: a lost ledger row caused a re-apply ($(posts) posts)"
grep -q 'already applied per app ledger' "$PLOG" 2>/dev/null && ok \
  || bad "N1: the second run did not re-check the app ledger: $(cat "$PLOG" 2>/dev/null)"
[ "$(failed_lines)" = 2 ] && ok || bad "N1: want one failure line per failed put (2), got $(failed_lines)"

# ===========================================================================
# Tripwire: nothing above touched the live harness.
# ===========================================================================
[ "$(snap "$REALDONE")" = "$D0" ] && ok || bad "tripwire: the LIVE $REALDONE was modified"

echo "migration-autopilot-ledger.bh-2623: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
