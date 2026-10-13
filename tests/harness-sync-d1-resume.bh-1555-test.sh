#!/bin/bash
# tests/harness-sync-d1-resume.bh-1555-test.sh — bin/harness-sync.sh records how
# far a D1 schema apply got, resumes there on the next pass, and pages when a
# changed statement redefines an object D1 already has.
#
# WHY (BH-1555, the review follow-ups to #1548).
#   S1. A cold 116-statement apply cannot finish inside the `timeout 300`
#       fleet-propagate gives harness-sync. Before this change a kill threw the
#       whole apply away: the stamp is written last, so the next pass started at
#       statement 1 and was killed at the same place, forever.
#   I1. `CREATE ... IF NOT EXISTS` is a SILENT NO-OP on D1 when the object is
#       already there, so an EDITED definition of an existing table/index is
#       sent, reports success and changes nothing. That cannot be fixed by
#       sending it differently (the schema is additive by contract) but it must
#       not pass unnoticed, so it pages.
#
# Everything here drives bin/harness-sync.sh itself against a fake npx that
# records instead of calling Cloudflare (the fixture is the one from
# tests/harness-sync-d1-batch.bh-1538-test.sh, plus NPX_KILL_AFTER).
# Run from anywhere: bash tests/harness-sync-d1-resume.bh-1555-test.sh (0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "git/flock missing — skipping"; exit 0; }
# shellcheck source=bin/lib/d1-schema.sh
. "$DIR/bin/lib/d1-schema.sh" || exit 1

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"
PROG="$T/state/worker-schema-progress-jobs"
STAMP_F="$T/state/worker-schema-applied-jobs"
printf 'CLOUDFLARE_ACCOUNT_ID=test-account\nCLOUDFLARE_API_TOKEN=not-a-real-token\n' > "$T/env/cloudflare.env"

# ── the fake npx: one line per call, argv flattened.
#   NPX_FAIL_MULTI=1      fail any d1 execute carrying more than one statement
#   NPX_KILL_AFTER=<n>    fail every d1 execute from the n-th one on (the
#                         `timeout 300` kill, seen from inside the apply)
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
APPLIED="$T/applied.sql"
CALLS="$T/d1-calls"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
args=$(printf '%s ' "$@" | sed ':a;N;$!ba;s/\n/ \/ /g' | tr '\t' ' ')
printf '%s | %s\n' "$PWD" "$args" >> "$NPX_LOG"
if [ "${3:-}" = "d1" ] && [ "${4:-}" = "execute" ]; then
  sql="${!#}"
  n=$(( $(cat "$CALLS" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$CALLS"
  if [ -n "${NPX_KILL_AFTER:-}" ] && [ "$n" -ge "${NPX_KILL_AFTER}" ]; then
    echo "fake npx: killed (round trip $n)" >&2; exit 137
  fi
  if [ "${NPX_FAIL_MULTI:-}" = 1 ] && [ "$(printf '%s\n' "$sql" | grep -c ';[[:space:]]*$')" -gt 1 ]; then
    echo "fake npx: multi-statement --command refused" >&2; exit 1
  fi
  printf '%s\n' "$sql" >> "$APPLIED"
fi
exit 0
EOF
chmod +x "$T/fakebin/npx"
if ! command -v rsync >/dev/null; then
  cat > "$T/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$T/fakebin/rsync"
fi

# ── origin + clone, one worker with a D1 binding and a 116-statement schema ──
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" "$T/ck/worker/jobs"
printf '#!/bin/bash\necho v1\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{
  "name": "jobs-test",
  "main": "src/index.js",
  "d1_databases": [ { "binding": "DB", "database_name": "jobs-test-db", "database_id": "0000" } ]
}
EOF
NSTMT=116
{ echo "-- a schema the size of worker/jobs's on 2026-09-22"
  for i in $(seq 1 "$NSTMT"); do
    printf 'CREATE TABLE IF NOT EXISTS t_%03d (\n  id INTEGER PRIMARY KEY\n);\n' "$i"
  done; } > "$T/ck/worker/jobs/schema.sql"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
# PUBLISH, not push. A build session on a harness box may not run `git push`
# with main as its target — the act-time iron-law guard blocks it even for a
# scratch bare repo in $TMPDIR — so the fixture's origin PULLS from the clone
# instead. Same resulting refs, no push.
publish() { git -C "$T/origin" fetch -q "$T/ck" main:main; git -C "$T/ck" fetch -q origin; }
publish
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

FAIL_MULTI=""; KILL_AFTER=""; ALERT_S=100000
sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH" \
           NPX_FAIL_MULTI="$FAIL_MULTI" NPX_KILL_AFTER="$KILL_AFTER" \
           HARNESS_SYNC_SCHEMA_ALERT_S="$ALERT_S"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; : > "$T/applied.sql"; rm -f "$T/d1-calls"; }
# cold() — forget BOTH stamps, so the worker phase sees a changed worker and
# the apply has no baseline. Without the deploy stamp the loop skips the worker
# entirely and a case would read "nothing sent" as its answer.
cold() { rm -f "$STAMP_F" "$T/state/worker-deployed-jobs" "$PROG"; }
d1_lines() { grep -F 'd1 execute' "$NPXLOG" 2>/dev/null; }
d1_count() { d1_lines | grep -c . ; }
deployed() { grep -F 'wrangler deploy' "$NPXLOG" 2>/dev/null | grep -c . ; }
commit() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; publish; }
blob() { git -C "$T/ck" hash-object worker/jobs/schema.sql; }
# statements D1 ACCEPTED, as t_NNN numbers (applied.sql is written by the fake
# npx only after it decides not to fail, so a killed round trip is not in it).
sent() { grep -o 'CREATE TABLE IF NOT EXISTS t_[0-9]*' "$T/applied.sql" 2>/dev/null | sed 's/.*t_//'; }

# S0. SAFETY PROBE (as in harness-sync-d1.bh-1000): a dirty checkout must
# refuse, or this suite would rsync its fixture over a live harness.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS — refusing to run the deploy path"
  echo "harness-sync-d1-resume.bh-1555-test: 0 pass, 1 fail"; exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ============================================================================
# R1. a cold apply killed part way: exit 0 for the sync but NO deploy, NO
#     stamp, and a progress file holding the key and the statements that DID
#     land (the last successful round trip's end).
# ============================================================================
KILL_AFTER=3
sync
KILL_AFTER=""
[ "$(deployed)" = 0 ] && ok || bad "R1: a killed apply must not deploy"
[ ! -f "$STAMP_F" ] && ok || bad "R1: a killed apply must not stamp the schema"
[ -f "$PROG" ] && ok || bad "R1: a killed apply must leave a progress file in state/"
R1PROG=$(cat "$PROG" 2>/dev/null)
R1DONE=${R1PROG##* }
[ "$R1PROG" = "$(blob) jobs-test-db none $R1DONE" ] \
  && ok || bad "R1: progress = '<blob> <db> <baseline|none> <done>', got '$R1PROG'"
case "$R1DONE" in ''|*[!0-9]*) bad "R1: the done count must be an integer, got '$R1DONE'" ;; *) ok ;; esac
[ "${R1DONE:-0}" -gt 0 ] && [ "${R1DONE:-0}" -lt "$NSTMT" ] \
  && ok || bad "R1: done must be a partial count in 1..$((NSTMT-1)), got '$R1DONE'"
# it never counts a statement the fake npx refused: exactly $R1DONE landed
[ "$(sent | grep -c .)" = "$R1DONE" ] \
  && ok || bad "R1: progress says $R1DONE done but $(sent | grep -c .) statements were accepted"
grep -q 'schema.sql statement .* failed against D1 jobs-test-db' "$ALERTS" \
  && ok || bad "R1: the killed apply still pages: $(cat "$ALERTS")"

# ============================================================================
# R3. the NEXT pass resumes: it sends only the statements after the recorded
#     progress, exits 0, deploys, stamps, and removes the progress file.
# ============================================================================
reset_run
# R3 is only meaningful if R1 actually recorded a partial count; without one
# "resumed from 0" and "never resumed" are the same observation.
case "$R1DONE" in ''|*[!0-9]*) R1DONE=0 ;; esac
[ "$R1DONE" -gt 0 ] && ok || bad "R3: precondition — R1 recorded no progress to resume from"
sync
[ "$RC" = 0 ] && ok || bad "R3: the resuming pass must exit 0, got $RC: $(cat "$T/out.txt")"
FIRST=$(sent | head -1 | sed 's/^0*//')
[ "$FIRST" = "$((R1DONE + 1))" ] \
  && ok || bad "R3: the resume must start at statement $((R1DONE+1)), started at '$FIRST'"
[ "$(sent | grep -c .)" = "$((NSTMT - R1DONE))" ] \
  && ok || bad "R3: the resume must send the remaining $((NSTMT - R1DONE)), sent $(sent | grep -c .)"
grep -q "resuming at statement $((R1DONE + 1))/$NSTMT" "$ULOG" \
  && ok || bad "R3: the resume must say so in the log: $(grep -F 'schema apply' "$ULOG" | head -3)"
[ "$(deployed)" = 1 ] && ok || bad "R3: the finished apply must deploy"
[ "$(cat "$STAMP_F" 2>/dev/null)" = "$(blob) jobs-test-db" ] \
  && ok || bad "R3: the finished apply must stamp the blob and its database, got '$(cat "$STAMP_F" 2>/dev/null)'"
[ ! -f "$PROG" ] && ok || bad "R3: a finished apply must remove its progress file: $(cat "$PROG")"

# ============================================================================
# R4. a progress file whose key does not match the pending list (here: another
#     blob sha) is NEVER trusted — the full pending set is sent and the stale
#     file is removed. Same for unparseable content.
# ============================================================================
reset_run
cold
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef jobs-test-db none 100" > "$PROG"
sync
[ "$(sent | grep -c .)" = "$NSTMT" ] \
  && ok || bad "R4: a mismatched progress file must not skip anything; sent $(sent | grep -c .) of $NSTMT"
[ ! -f "$PROG" ] && ok || bad "R4: a mismatched progress file must be removed"
[ "$(deployed)" = 1 ] && ok || bad "R4: and the apply still completes"
reset_run
cold
printf 'garbage\n' > "$PROG"
sync
[ "$(sent | grep -c .)" = "$NSTMT" ] && [ ! -f "$PROG" ] \
  && ok || bad "R4: unparseable progress must be discarded, not clamped: sent $(sent | grep -c .), file $( [ -f "$PROG" ] && echo kept || echo gone)"

# ============================================================================
# R2. on the per-statement fallback path progress advances by ONE per single.
# ============================================================================
reset_run
cold
FAIL_MULTI=1; KILL_AFTER=6
sync
FAIL_MULTI=""; KILL_AFTER=""
R2DONE=$(awk '{print $NF}' "$PROG" 2>/dev/null)
[ "$R2DONE" = "$(sent | grep -c .)" ] && [ "${R2DONE:-0}" -gt 0 ] \
  && ok || bad "R2: on the single path progress must equal the singles that landed ($R2DONE vs $(sent | grep -c .))"
rm -f "$PROG" "$STAMP_F"

# ============================================================================
# R5. REGRESSION (BH-1538 B2): a complete apply, then a one-statement change,
#     still costs exactly ONE round trip and leaves no progress file behind.
# ============================================================================
reset_run
cold
sync
[ "$(deployed)" = 1 ] && [ ! -f "$PROG" ] && ok || bad "R5: precondition — a clean full apply"
reset_run
printf 'CREATE INDEX IF NOT EXISTS ix_r5 ON t_001(id);\n' >> "$T/ck/worker/jobs/schema.sql"
commit "one new statement"
sync
[ "$(d1_count)" = 1 ] && [ "$(d1_lines | grep -c 'ix_r5')" = 1 ] \
  && ok || bad "R5: a one-statement delta must still be one round trip, took $(d1_count)"
[ ! -f "$PROG" ] && ok || bad "R5: a completed delta leaves no progress file"
[ ! -s "$ALERTS" ] && ok || bad "R5: a new object must not page: $(cat "$ALERTS")"

# ============================================================================
# E1/E4. an EDITED definition of an object D1 already has: the apply still
#        sends it and still deploys (the schema is additive by contract), and
#        writes exactly ONE ALERTS line naming the object AND the statement's
#        ordinal in the WHOLE file, not its position in the pending list.
# ============================================================================
reset_run
sed -i.bak 's/^CREATE TABLE IF NOT EXISTS t_005 ($/CREATE TABLE IF NOT EXISTS t_005 ( -- edited/' "$T/ck/worker/jobs/schema.sql"
rm -f "$T/ck/worker/jobs/schema.sql.bak"
grep -q 't_005 ( -- edited' "$T/ck/worker/jobs/schema.sql" \
  && ok || bad "E1: precondition — the fixture edit did not apply"
commit "t_005 redefined"
sync
[ "$RC" = 0 ] && ok || bad "E1: an edited definition alerts but must not fail the sync, got $RC"
[ "$(deployed)" = 1 ] && ok || bad "E1: and must still deploy"
[ "$(grep -c 'EXISTING object' "$ALERTS")" = 1 ] \
  && ok || bad "E1: exactly one EXISTING object ALERTS line, got: $(cat "$ALERTS")"
grep -q 'table t_005' "$ALERTS" \
  && ok || bad "E1: the ALERTS line must name the object: $(cat "$ALERTS")"
# E4: t_005's CREATE is statement 5 of the file; in `pend` it is statement 1.
grep -q 'statement 5:' "$ALERTS" \
  && ok || bad "E4: the ALERTS line must carry the ordinal in the FULL file (5), got: $(cat "$ALERTS")"

# ============================================================================
# E2. a brand-new object in the same delta never alerts.
# ============================================================================
reset_run
printf 'CREATE TABLE IF NOT EXISTS t_new_e2 (id INTEGER PRIMARY KEY);\n' >> "$T/ck/worker/jobs/schema.sql"
commit "a new table"
sync
[ "$(d1_lines | grep -c 't_new_e2')" = 1 ] && ok || bad "E2: the new statement must be sent"
[ "$(grep -c 'EXISTING object' "$ALERTS")" = 0 ] \
  && ok || bad "E2: a NEW object must not page: $(cat "$ALERTS")"

# ============================================================================
# E3. a cold apply (no stamp, so no baseline) never alerts: every object is
#     "new" as far as this box can tell, and guessing would page on every box
#     that lost its stamp.
# ============================================================================
reset_run
cold
sync
[ "$(deployed)" = 1 ] && ok || bad "E3: precondition — the cold apply completed"
[ "$(grep -c 'EXISTING object' "$ALERTS")" = 0 ] \
  && ok || bad "E3: a full apply has no baseline and must not page: $(cat "$ALERTS")"

echo "harness-sync-d1-resume.bh-1555-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
