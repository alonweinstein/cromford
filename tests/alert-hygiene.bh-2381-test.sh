#!/bin/bash
# tests/alert-hygiene.bh-2381-test.sh — the five follow-ups to BH-2337 (#2380).
#
#   S  main-red's STILL RED rides the shared main-red-<slug> id, so the GREEN's
#      --resolve closes it (it used to key on auto-<row_key> and stay open).
#   D  the fleet-propagate drain line is log-only only when it says N/N rebaked.
#   G  "[auth] ghdefault-<slug> RECOVERED" is log-only only as its full sentence.
#   H  hotfix_announce pr_open/merged are ALERTS.log lines, not rows; hotfix
#      FAILURE lines still page, and an unlisted event still beats.
#   L  claude-auth-check.sh's ghvis_latch edits state/claude-auth-down.txt under
#      locks/lane-down-state.lock, the lock bin/lib/lane-down.sh documents.
#   R  bin/lane-reprobe.sh never seeds the canary's ghdefault-/ghblind- latches
#      as runner lanes, even when a repo slug ends in -grok/-codex.
#
# Same fixture as tests/alert-hygiene.bh-2337-test.sh: real bin/beat.sh,
# bin/lane-alert.sh, bin/lib/alert-state.sh and the real poll-commands re-beat
# block against a scratch $HARNESS, with a fake curl as the console (one send =
# one row).
# Run from anywhere: tests/alert-hygiene.bh-2381-test.sh   (exit 0 = all pass)
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
akey()    { ( . "$DIR/bin/lib/alert-state.sh"; alert_state_key "$1" ); }
announce() { ( . "$DIR/bin/lib/hotfix-lib.sh"; hotfix_announce "$H" "$@" ); }

# ── S. STILL RED is the same condition as RED/GREEN ─────────────────────────
RED="o/r main is RED: \"Harness CI\" failed 2 runs in a row (job: lint; sha 0123abcd; red since 2026-09-25T01:00:00Z). https://example.invalid/run/1"
STILL="o/r main is STILL RED on a new sha: \"Harness CI\" failed (job: lint; sha 89abcdef; red since 2026-09-25T01:00:00Z). Something landed on main and it did not fix this. Merges for o/r stay frozen while main-red-o-r exists. https://example.invalid/run/3"
GREEN="o/r main is GREEN again: \"Harness CI\" passed on 4567cdef (it was red since 2026-09-25T01:00:00Z). main-red-o-r cleared — merges for o/r are unfrozen."
KS=$(akey "[orchestrator/main-red] $STILL"); KR=$(akey "[orchestrator/main-red] $RED")
[ "$KS" = "$KR" ] && [ "$KS" = main-red-o_r ] && ok || bad "S1 STILL RED must key on main-red-o_r like RED (still=$KS red=$KR)"

reset
la main-red "$STILL"
[ "$(rows)" = 1 ] && ok || bad "S2 STILL RED with nothing open must open one row (rows=$(rows))"
la --resolve --log-only main-red "$GREEN"
[ "$(resolves)" = 1 ] && ok || bad "S2 GREEN must resolve the STILL RED row (resolves=$(resolves)): $(cat "$T/sent.jsonl" 2>/dev/null)"
[ "$(twins)" = 1 ] && ok || bad "S2 GREEN must close the console twin once (twins=$(twins))"
SF="$H/state/alerts/main-red-o_r.json"
[ ! -s "$SF" ] || [ "$(jq -r '.resolved_at // empty' "$SF" 2>/dev/null)" != "" ] \
  && ok || bad "S2 the main-red-o_r state must be resolved: $(cat "$SF" 2>/dev/null)"
[ "$(find "$H/state/alerts" -maxdepth 1 -name 'auto-*.json' 2>/dev/null | awk 'END{print NR+0}')" = 0 ] \
  && ok || bad "S2 STILL RED opened an auto-* id: $(ls "$H/state/alerts")"

reset
la --critical main-red "$RED"
la main-red "$STILL"
[ "$(rows)" = 1 ] && ok || bad "S3 STILL RED while RED is open is a repeat, not a second row (rows=$(rows)): $(cat "$T/sent.jsonl")"
la --resolve --log-only main-red "$GREEN"
[ "$(resolves)" = 1 ] && [ "$(twins)" = 1 ] && [ "$(rows)" = 1 ] && ok || bad "S3 GREEN must close the one row (rows=$(rows) resolves=$(resolves) twins=$(twins))"

# ── D. the drain rule needs N/N rebaked ─────────────────────────────────────
DR="[orchestrator/fleet-propagate] drained the pool images debounced earlier at 907edcd"
logonly "$DR: 3/3 rebaked (drain), hub ok. No box needed syncing." && ok || bad "D1 a 3/3 drain must be log-only"
logonly "$DR: 2/3 rebaked (drain), failed: p2, hub ok." && bad "D2 a 2/3 drain must NOT be log-only" || ok
logonly "$DR: something went sideways" && bad "D3 a drain line with no count must NOT be log-only" || ok

# ── G. the RECOVERED rule is the full sentence ──────────────────────────────
GR="[auth] ghdefault-o_r RECOVERED — the default gh token sees o/r again"
logonly "$GR" && ok || bad "G1 the producer's RECOVERED line must be log-only"
( export LC_ALL=C; logonly "$GR" ) && ok || bad "G1 the RECOVERED line must be log-only under LC_ALL=C"
reset
echo "2026-09-25 01:00:00Z $GR" >> "$H/logs/ALERTS.log"
rebeat
[ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "G1 the RECOVERED ALERTS line's re-beat wrote an alert (rows=$(rows)): $(cat "$T/sent.jsonl" 2>/dev/null)"
logonly "[auth] ghdefault-o_r RECOVERED? no — still blind" && bad "G2 a RECOVERED? no line must NOT be log-only" || ok
logonly "$GR, but the admin token lost it" && bad "G3 trailing text after the sentence must NOT be log-only" || ok

# ── H. hotfix pr_open/merged are notices; failures still page ───────────────
for ev in pr_open merged; do
  reset
  announce proj AB-5 "$ev" "AB-5 — $ev https://github.com/o/r/pull/7"
  alerts_has "[proj/AB-5] HOTFIX $ev: AB-5 — $ev" && ok || bad "H $ev: the ALERTS line must stay: $(cat "$H/logs/ALERTS.log")"
  [ "$(rows)" = 0 ] && ok || bad "H $ev: hotfix_announce wrote an alert row (rows=$(rows)): $(cat "$T/sent.jsonl" 2>/dev/null)"
  [ -f "$H/state/hotfix-announced/proj/AB-5.$ev" ] && ok || bad "H $ev: the dedupe marker was not written"
  rebeat
  [ "$(rows)" = 0 ] && [ "$(ids)" = 0 ] && ok || bad "H $ev: the re-beat wrote an alert (rows=$(rows) ids=$(ids)): $(cat "$T/sent.jsonl" 2>/dev/null)"
done
H3="[proj] HOTFIX POST-DEPLOY APPLY FAILED (abc12345): PR https://github.com/o/r/pull/7 files: 1 failed (build b1)"
logonly "$H3" && bad "H3 a POST-DEPLOY APPLY FAILED line must NOT be log-only" || ok
reset
echo "2026-09-25 01:00:00Z $H3" >> "$H/logs/ALERTS.log"
rebeat
[ "$(rows)" = 1 ] && ok || bad "H3 the APPLY FAILED line's re-beat must page (rows=$(rows))"
logonly "[proj/AB-5] HOTFIX https://github.com/o/r/pull/7 could NOT be labelled 'hotfix' — run: gh label create hotfix -R o/r" \
  && bad "H4 a could-NOT-be-labelled line must NOT be log-only" || ok
logonly "[proj] HOTFIX CLOSE-OUT OWED (abc12345): x" && bad "H4 a CLOSE-OUT OWED line must NOT be log-only" || ok
reset
announce proj AB-5 failed "x"
[ "$(rows)" = 1 ] && ok || bad "H5 an unlisted event must still beat (rows=$(rows))"

# ── L. ghvis_latch holds the lane-down state lock ───────────────────────────
C="$T/c"
mkdir -p "$C/bin/lib" "$C/state" "$C/locks" "$C/logs"
cp "$DIR/bin/lib/lane-down.sh" "$C/bin/lib/"
latch() { ( export HARNESS="$C"; AUTH_CHECK_LIB=1 . "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1; ghvis_latch "$@" ) 2>>"$C/err.txt"; }
CS="$C/state/claude-auth-down.txt"
printf 'hub\n' > "$CS"
( flock -x 9; touch "$C/held"; sleep 3 ) 9>"$C/locks/lane-down-state.lock" &
HOLDER=$!
for _ in $(seq 50); do [ -f "$C/held" ] && break; sleep 0.1; done
t0=$(date +%s)
latch ghblind-o_r on
t1=$(date +%s)
wait "$HOLDER"
[ $((t1 - t0)) -ge 2 ] && ok || bad "L1 ghvis_latch must wait for locks/lane-down-state.lock (took $((t1 - t0))s)"
grep -qxF ghblind-o_r "$CS" && grep -qxF hub "$CS" && ok || bad "L1 the latch line must land and keep hub: $(cat "$CS") err=$(cat "$C/err.txt")"
latch ghblind-o_r on
[ "$(grep -cxF ghblind-o_r "$CS")" = 1 ] && ok || bad "L2 a second on must not duplicate: $(cat "$CS")"
latch ghblind-o_r off
! grep -qxF ghblind-o_r "$CS" && grep -qxF hub "$CS" && ok || bad "L2 off must drop only the latch line: $(cat "$CS")"
grep -q '\.tmp' <<<"$(ls "$C/state")" && bad "L2 a tmp file was left behind: $(ls "$C/state")" || ok
# Without bin/lib/lane-down.sh the latch still works, unlocked (fail-open).
rm -f "$C/bin/lib/lane-down.sh"
latch ghdefault-o_r on
grep -qxF ghdefault-o_r "$CS" && ok || bad "L3 with no lane-down lib the latch must still write: $(cat "$CS")"
latch ghdefault-o_r off
! grep -qxF ghdefault-o_r "$CS" && ok || bad "L3 with no lane-down lib the latch must still clear: $(cat "$CS")"

# ── R. lane-reprobe does not seed the canary's per-repo latches ─────────────
R="$T/r"
mkdir -p "$R/bin/lib" "$R/env" "$R/state/lane-down" "$R/flags" "$R/logs" "$R/locks" "$T/fakebin"
cp "$DIR/bin/lane-reprobe.sh" "$R/bin/"
cp "$DIR/bin/lib/lane-down.sh" "$R/bin/lib/"
: > "$R/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "${PROBE_OUT:-}"\nexit 1\n' > "$R/bin/lane-probe.sh"
printf '#!/bin/bash\nexit 0\n' > "$R/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 1\n' > "$R/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/ssh"
chmod +x "$R/bin/"*.sh "$T/fakebin/ssh"
printf 'hub\nhub-grok\nghdefault-acme_tool-grok\nghblind-acme_tool-codex\nghdefault-Acme_x-fireworks\n' \
  > "$R/state/claude-auth-down.txt"
HARNESS="$R" PATH="$T/fakebin:$PATH" bash "$R/bin/lane-reprobe.sh" >/dev/null 2>&1
[ -z "$(ls "$R/state/lane-down" | grep '^gh')" ] && ok || bad "R1 a ghdefault-/ghblind- latch was seeded as a runner lane: $(ls "$R/state/lane-down")"
[ -f "$R/state/lane-down/hub-grok" ] && ok || bad "R2 hub-grok must still be seeded: $(ls "$R/state/lane-down") log=$(cat "$R/logs/lane-reprobe.log" 2>/dev/null)"
[ ! -e "$R/state/lane-down/hub" ] && ok || bad "R3 a bare box line must never be seeded"

echo "alert-hygiene.bh-2381: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
