#!/bin/bash
# tests/alert-hygiene.bh-2337-test.sh — a success or recovery notice is a log
# line, not an alert row; the GH-token visibility check is a status row that
# pages only when NO token can see the repo, once.
#
# THE BACKLOG THIS PINS (2026-09-25). 180 of 377 open fleet alerts (48%) were
# notices: fleet-propagate "propagated <sha> to the fleet: 8/8 boxes synced",
# "HOTFIX seen", "main is GREEN again", and a daily "DEFAULT GH TOKEN CANNOT SEE
# <repo>" for repos the admin token covers. Each reached the table twice over:
# the producer's own beat, and bin/poll-commands.sh re-beating its ALERTS.log
# line into bin/beat.sh. So every case below checks BOTH paths, and checks the
# ALERTS.log line is still written (the audit record stays).
#
# Real bin/beat.sh, bin/lane-alert.sh, bin/lib/alert-state.sh,
# bin/lib/hotfix-lib.sh, the real poll-commands re-beat block and the real
# gh_visibility_canary from bin/claude-auth-check.sh, against a scratch
# $HARNESS. A fake curl is "the console" (one send = one row); a file-backed
# bin/jobs-client.sh stub is "the ledgers table".
# Run from anywhere: tests/alert-hygiene.bh-2337-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
export HARNESS="$H"
export PATH="$T/stub:$PATH"
for s in beat.sh lane-alert.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
printf '#!/bin/bash\necho ""\n' > "$H/bin/project-of.sh"; chmod +x "$H/bin/project-of.sh"
# beat.sh's direct path, so one send == one curl (see alert-state-machine-test).
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=FIXTURE-secret\n' > "$H/env/global.env"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && { printf '%s\n' "\$a" >> "$T/sent.jsonl"; break; }
  prev="\$a"
done
echo '{"ok":true}'
STUB
chmod +x "$T/stub/curl"

awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" > "$T/rebeat.body"
[ -s "$T/rebeat.body" ] || bad "could not extract the alerts re-beat block from bin/poll-commands.sh"
rebeat() { ( export HARNESS="$H" BEAT="$H/bin/beat.sh"; . "$T/rebeat.body" ) >/dev/null 2>&1; }

# rows: sends that open or re-state a condition; resolves: retractions.
rows()     { cat "$T/sent.jsonl" 2>/dev/null | awk '!/"resolved":true/ && NF {n++} END{print n+0}'; }
# TEST-CHANGE (BH-4054): lane-alert.sh --resolve now sends the orclane:<id>
# resolve AND its console twin alert:<id> (kind "alert"). resolves() still
# counts the lane's own retraction, exactly once; twins() counts the twin, and
# the GREEN cases assert it is exactly one too.
resolves() { cat "$T/sent.jsonl" 2>/dev/null | awk '/"resolved":true/ && /"kind":"fleet_alert"/ {n++} END{print n+0}'; }
twins()    { cat "$T/sent.jsonl" 2>/dev/null | awk '/"resolved":true/ && /"kind":"alert"/ && /"akey":"alert:main-red-o_r"/ {n++} END{print n+0}'; }
ids()      { find "$H/state/alerts" -maxdepth 1 -name '*.json' 2>/dev/null | awk 'END{print NR+0}'; }
alerts_has() { grep -qF -- "$1" "$H/logs/ALERTS.log"; }
reset() {
  scratch_rm "$H/state/alerts"; scratch_rm "$T/sent.jsonl"; scratch_rm "$H/state/hotfix-announced"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/alerts-state.log"; echo 0 > "$H/flags/.alerts-cursor"
}
la() { "$DIR/bin/lane-alert.sh" "$@" >/dev/null 2>&1; }
logonly() { ( . "$DIR/bin/lib/alert-state.sh"; alert_state_logonly "$1" ); }

# ── P. fleet-propagate ──────────────────────────────────────────────────────
reset
OKL="propagated 907edcd to the fleet: 8/8 boxes synced, 10/10 pool images rebaked, hub ok, crontab unchanged."
la --log-only fleet-propagate "$OKL"
alerts_has "[orchestrator/fleet-propagate] $OKL" && ok || bad "P1 the 8/8 ALERTS.log line must stay: $(cat "$H/logs/ALERTS.log")"
[ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "P1 an 8/8 propagate wrote an alert (rows=$(rows) ids=$(ids))"
rebeat
[ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "P1 the 8/8 line's re-beat wrote an alert (rows=$(rows) ids=$(ids)): $(cat "$T/sent.jsonl" 2>/dev/null)"
logonly "[orchestrator/fleet-propagate] propagated 907edcd to the fleet: 7/8 boxes synced, 10/10 pool images rebaked, hub ok, crontab unchanged." \
  && bad "P2 a 7/8 line must never be log-only" || ok
reset
la --critical fleet-propagate "propagating 907edcd to the fleet FAILED in part — hub=ok, 7/8 boxes synced, failed: beta(rc=7), 10/10 pool images rebaked, crontab unchanged."
[ "$(rows)" = 1 ] && ok || bad "P2 a 7/8 / FAILED propagate must write exactly one alert (rows=$(rows))"
rebeat
[ "$(rows)" = 1 ] && ok || bad "P2 the FAILED line's re-beat must not add a second row (rows=$(rows))"
logonly "[orchestrator/fleet-propagate] drained the pool images debounced earlier at 907edcd: 2/2 rebaked (drain), hub ok. No box needed syncing." \
  && ok || bad "P3 the drain success line must be log-only"

# ── H. HOTFIX seen ──────────────────────────────────────────────────────────
reset
( . "$DIR/bin/lib/hotfix-lib.sh"; hotfix_announce "$H" proj AB-5 seen "AB-5 — the roof is on fire" )
alerts_has "[proj/AB-5] HOTFIX seen: AB-5 — the roof is on fire" && ok || bad "H1 the HOTFIX seen ALERTS line must stay"
[ "$(rows)" = 0 ] && ok || bad "H1 HOTFIX seen wrote an alert row (rows=$(rows)): $(cat "$T/sent.jsonl" 2>/dev/null)"
rebeat
[ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "H1 the HOTFIX seen re-beat wrote an alert (rows=$(rows) ids=$(ids))"
# BH-2381: pr_open is a notice too — its ALERTS line is the announcement.
( . "$DIR/bin/lib/hotfix-lib.sh"; hotfix_announce "$H" proj AB-5 pr_open "AB-5 — PR open" )
alerts_has "[proj/AB-5] HOTFIX pr_open: AB-5 — PR open" && ok || bad "H2 pr_open is still announced in ALERTS.log"
[ "$(rows)" = 0 ] && ok || bad "H2 pr_open wrote an alert row (rows=$(rows)): $(cat "$T/sent.jsonl" 2>/dev/null)"

# ── M. main-red GREEN resolves the RED, and opens nothing ───────────────────
reset
la --critical main-red "o/r main is RED: \"Harness CI\" failed 2 runs in a row (job: lint; sha 0123abcd; red since 2026-09-25T01:00:00Z). https://example.invalid/run/1"
[ "$(rows)" = 1 ] && ok || bad "M1 the RED must page once (rows=$(rows))"
RAKEY=$(jq -r '.akey' < <(head -1 "$T/sent.jsonl") 2>/dev/null)
# poll-commands runs every minute: the RED's own line is re-beaten long before
# any GREEN, and lands on the id the RED opened (a counted repeat, no row).
rebeat
[ "$(rows)" = 1 ] && ok || bad "M1 the RED line's re-beat wrote a second row (rows=$(rows)): $(cat "$T/sent.jsonl")"
IDS_RED=$(ids)
la --resolve --log-only main-red "o/r main is GREEN again: \"Harness CI\" passed on 4567cdef (it was red since 2026-09-25T01:00:00Z). main-red-o-r cleared — merges for o/r are unfrozen. https://example.invalid/run/2"
[ "$(resolves)" = 1 ] && ok || bad "M1 GREEN must issue exactly one resolve (resolves=$(resolves)): $(cat "$T/sent.jsonl")"
[ "$(jq -r 'select(.resolved==true and .kind=="fleet_alert")|.akey' "$T/sent.jsonl" 2>/dev/null)" = "$RAKEY" ] \
  && ok || bad "M1 the resolve must carry the RED's akey ($RAKEY): $(cat "$T/sent.jsonl")"
[ "$(twins)" = 1 ] && ok || bad "M1 GREEN must close the console twin alert:main-red-o_r once (twins=$(twins)): $(cat "$T/sent.jsonl")"
[ "$(rows)" = 1 ] && [ "$(ids)" = "$IDS_RED" ] && ok || bad "M1 GREEN wrote a new alert (rows=$(rows) ids=$(ids) was $IDS_RED)"
alerts_has "main is GREEN again" && ok || bad "M1 the GREEN ALERTS.log line must stay"
rebeat
[ "$(rows)" = 1 ] && ok || bad "M1 the re-beat of the GREEN/RESOLVED lines wrote a row (rows=$(rows)): $(cat "$T/sent.jsonl")"
reset
la --resolve --log-only main-red "o/r main is GREEN again: \"Harness CI\" passed on 4567cdef (it was red since unknown). main-red-o-r cleared — merges for o/r are unfrozen."
alerts_has "[orchestrator/main-red] o/r main is GREEN again" && ok || bad "M2 GREEN with nothing open must still write its ALERTS line: $(cat "$H/logs/ALERTS.log")"
[ -f "$T/sent.jsonl" ] && bad "M2 GREEN with nothing open sent something: $(cat "$T/sent.jsonl")" || ok
rebeat
[ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "M2 its re-beat wrote an alert (rows=$(rows) ids=$(ids))"

# ── A. the GH-token visibility canary ───────────────────────────────────────
C="$T/c"
mkdir -p "$C/bin/lib" "$C/env" "$C/flags" "$C/logs" "$C/state" "$C/locks" "$C/fakebin"
cp "$DIR/bin/lib/gh-repo-token.sh" "$C/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$C/bin/"
echo 'GH_ADMIN_TOKEN=admintok' > "$C/env/github-admin.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$C/bin/beat.sh"; chmod +x "$C/bin/beat.sh"
# The ledgers table: one "<kind>\t<key>\t<status>\t<detail>" row per (kind,key).
cat > "$C/bin/jobs-client.sh" <<'SH'
job_ledger_get() {
  [ -n "${LEDGER_DOWN:-}" ] && return 1
  local s; s=$(awk -F'\t' -v k="$1" -v v="$2" '$1==k && $2==v {print $3}' "$LEDGER" 2>/dev/null | tail -1)
  [ -n "$s" ] || return 2
  printf '%s' "$s"
}
job_ledger_put() {
  [ -n "${LEDGER_DOWN:-}" ] && return 1
  awk -F'\t' -v k="$1" -v v="$2" '!($1==k && $2==v)' "$LEDGER" > "$LEDGER.tmp" 2>/dev/null; mv "$LEDGER.tmp" "$LEDGER"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$LEDGER"
}
SH
cat > "$C/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") printf 'ts\nbd\nmk\n' ;;
  "ts repo") echo "o/adminonly" ;;
  "bd repo") echo "o/seen" ;;
  "mk repo") echo "o/blind" ;;
esac
SH
chmod +x "$C/bin/fleet-conf.sh"
cat > "$C/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/adminonly -q .id") [ "${GH_TOKEN:-}" = admintok ] && exit 0; exit 1 ;;
  "api repos/o/blind -q .id")     [ -f "$T/healed" ] && exit 0; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$C/fakebin/gh"
: > "$C/ledger.tsv"
canary() {
  ( export PATH="$C/fakebin:$PATH" HARNESS="$C" T="$C" BEAT_SINK="$C/beats.txt" LEDGER="$C/ledger.tsv"; unset GH_TOKEN
    # shellcheck source=/dev/null
    AUTH_CHECK_LIB=1 . "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1
    gh_visibility_canary ) 2>"$C/err.txt"
}
row()    { awk -F'\t' -v v="$1" '$1=="gh_visibility" && $2==v {print $3}' "$C/ledger.tsv"; }
cbeats() { cat "$C/beats.txt" 2>/dev/null | awk '/"akey":"ghinvisible:/ && !/"resolved":true/ {n++} END{print n+0}'; }
: > "$C/logs/ALERTS.log"; : > "$C/beats.txt"
canary
[ "$(row o/adminonly)" = "default_token_visible=0 admin_token_visible=1" ] \
  && ok || bad "A1 admin-covered repo: status row missing/wrong: '$(row o/adminonly)' err=$(cat "$C/err.txt")"
grep -q '"akey":"ghinvisible:o/adminonly"' "$C/beats.txt" && bad "A1 admin-covered repo must not alert: $(cat "$C/beats.txt")" || ok
grep -q "DEFAULT GH TOKEN CANNOT SEE o/adminonly (ts)" "$C/logs/ALERTS.log" && ok || bad "A1 the admin-covered ALERTS audit line must stay"
logonly "$(grep 'CANNOT SEE o/adminonly' "$C/logs/ALERTS.log" | head -1)" && ok \
  || bad "A1 the admin-covered ALERTS line must be log-only (its re-beat is a row otherwise): $(grep 'o/adminonly' "$C/logs/ALERTS.log")"
[ "$(row o/blind)" = "default_token_visible=0 admin_token_visible=0" ] && ok || bad "A2 blind repo status row: '$(row o/blind)'"
BB=$(grep '"akey":"ghinvisible:o/blind"' "$C/beats.txt")
[ "$(cbeats)" = 1 ] && [[ "$BB" == *'"severity":"critical"'* ]] \
  && ok || bad "A2 both tokens blind must page once, critical: $(cat "$C/beats.txt")"
[ "$(row o/seen)" = "default_token_visible=1" ] && ok || bad "A2 visible repo status row: '$(row o/seen)'"
canary
[ "$(cbeats)" = 1 ] && ok || bad "A3 a second run the same day paged again: $(cat "$C/beats.txt")"
rm -f "$C"/flags/ghinvisible-*
canary
[ "$(cbeats)" = 1 ] && ok || bad "A3 the next day paged again (once on the transition, not daily): $(cat "$C/beats.txt")"
( export LEDGER_DOWN=1; canary )
[ "$(cbeats)" = 1 ] && ok || bad "A4 a DB outage re-paged a repo already paged: $(cat "$C/beats.txt")"
touch "$C/healed"
canary
[ "$(awk '/"akey":"ghinvisible:o\/blind"/ && /"resolved":true/ {n++} END{print n+0}' "$C/beats.txt")" = 1 ] \
  && ok || bad "A5 recovery must resolve the blind alert once: $(cat "$C/beats.txt")"
[ "$(row o/blind)" = "default_token_visible=1" ] && ok || bad "A5 recovered status row: '$(row o/blind)'"
grep -q admintok "$C/logs/ALERTS.log" "$C/beats.txt" "$C/ledger.tsv" && bad "the admin token VALUE leaked" || ok

echo "alert-hygiene.bh-2337: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
