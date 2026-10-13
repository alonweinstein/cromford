#!/bin/bash
# tests/alert-state-machine-test.sh — an alert fires ONCE, resolves ONCE, and
# routes by severity.
#
# THE 24 HOURS THIS PINS (2026-09-15). the operator reads the alerts topic on his phone,
# and that day it carried: 68 EXTRA-USAGE lines about ONE account in ONE overage
# (its "already told you" marker keyed on a resets_at timestamp whose
# microseconds move every poll, so the grep never matched what it had just
# written); ~35 pipeline-health RESOLVED lines retracting conditions nobody had
# been told were open; 10 SILENT triage rows paged one at a time for one dead
# lane; and 5 LANE DOWN lines every canary from a box that has been parked
# on purpose since 2026-08-25.
#
# Four emitters, four private dedupe schemes, four different bugs. So the rule
# these assertions defend is that dedupe is NOT the emitter's job: a condition
# has an id and a lifecycle, and bin/lib/alert-state.sh is the only place that
# knows it.
#
# Run from anywhere: tests/alert-state-machine-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
export HARNESS="$H"
export PATH="$T/stub:$PATH"

# The scripts under test run from the CHECKOUT (that is how harness-sync installs
# them) against a scratch $HARNESS, so nothing here can touch the live tree.
for s in beat.sh lane-alert.sh alert-digest.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"

# WHAT "SENT" MEANS HERE. An untriaged fleet_alert is normally parked in
# state/alert-quarantine.jsonl for the triage lane, which would make every
# assertion below a statement about the quarantine rather than about the wire.
# Disabling the quarantine puts beat.sh on its direct path, so one send == one
# curl, and the fake curl is the only thing standing between this test and the
# network.
touch "$H/flags/alert-quarantine-disabled"
touch "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
# Record the JSON body (-d <payload>) and nothing else; answer like the API.
prev=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && { printf '%s\n' "\$a" >> "$T/sent.jsonl"; break; }
  prev="\$a"
done
echo '{"ok":true}'
STUB
chmod +x "$T/stub/curl"

CONF="$H/flags/alerts.conf"
sent()      { [ -f "$T/sent.jsonl" ] && wc -l < "$T/sent.jsonl" | tr -d ' ' || echo 0; }
alerts_n()  { [ -f "$H/logs/ALERTS.log" ] && wc -l < "$H/logs/ALERTS.log" | tr -d ' ' || echo 0; }
reset() {
  scratch_rm "$H/state/alerts"; for p in "$H/state/alert-warn-batch.jsonl"*; do scratch_rm "$p"; done; rm -rf "$T/sent.jsonl"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/alerts-state.log"
  rm -f "$CONF" "$H"/flags/paused-*
}
la() { "$DIR/bin/lane-alert.sh" "$@" >/dev/null 2>&1; }

# ── 1. FIRE ONCE, then count instead of paging ──────────────────────────────
# The EXTRA-USAGE shape: the same condition, re-observed every quarter hour.
reset
la --id extra-usage-overage-acct --severity critical extra-usage "account is in overage, meter \$25969.68"
[ "$(sent)" = 1 ]     && ok || bad "first sighting did not send (sent=$(sent))"
[ "$(alerts_n)" = 1 ] && ok || bad "first sighting wrote $(alerts_n) ALERTS.log lines, want 1"
for i in 2 3 4 5; do
  la --id extra-usage-overage-acct --severity critical extra-usage "account is in overage, meter \$2600$i.47"
done
[ "$(sent)" = 1 ] && ok || bad "repeats of an open id paged again (sent=$(sent), want 1)"
# ALERTS.log is append-only and MUST NOT grow a wall of repeats either: the
# counter lives in the state lane's own log.
[ "$(alerts_n)" = 1 ] && ok || bad "repeats appended to ALERTS.log ($(alerts_n) lines, want 1)"
grep -q "still firing id=extra-usage-overage-acct n=5" "$H/logs/alerts-state.log" \
  && ok || bad "logs/alerts-state.log has no 'still firing ... n=5' record"
[ -s "$H/state/alerts/extra-usage-overage-acct.json" ] \
  && ok || bad "no state/alerts/<id>.json written"
C=$(jq -r '.count' "$H/state/alerts/extra-usage-overage-acct.json" 2>/dev/null)
[ "$C" = 5 ] && ok || bad "state count=$C, want 5"

# ── 2. REMINDER INTERVAL ────────────────────────────────────────────────────
# A condition that stays open is not silent forever — it nags on a configured
# interval, and the nag says how many times it has been seen.
ALERT_REMINDER_S=0 la --id extra-usage-overage-acct --severity critical extra-usage "account is in overage, meter \$26144.47"
[ "$(sent)" = 2 ] && ok || bad "reminder interval elapsed but nothing was sent (sent=$(sent))"
grep -q "still firing, n=6" "$T/sent.jsonl" && ok || bad "the reminder does not carry 'still firing, n=6'"
grep -q "still firing, n=6" "$H/logs/ALERTS.log" && ok || bad "the reminder is missing from ALERTS.log"

# ── 3. RESOLVE ONCE, and never for something nobody announced ───────────────
la --resolve --id extra-usage-overage-acct extra-usage "out of overage, back on credits"
# TEST-CHANGE (BH-4054): a resolve now sends TWO beats, orclane:<id> and its
# console twin alert:<id> (tests/lane-alert-resolve-console.bh-4054-test.sh), so
# every count from here on in this section is one higher. Each is still exact.
[ "$(sent)" = 4 ] && ok || bad "resolve of an open id did not send (sent=$(sent), want 4: orclane + alert twin)"
[ "$(jq -r 'select(.resolved == true)|.akey' "$T/sent.jsonl" | sort | tr '\n' ' ')" = "alert:extra-usage-overage-acct orclane:extra-usage-overage-acct " ] \
  && ok || bad "the two resolve beats are not orclane:<id> and alert:<id>: $(cat "$T/sent.jsonl")"
jq -e 'select(.resolved == true)' <<<"$(tail -1 "$T/sent.jsonl")" >/dev/null 2>&1 \
  && ok || bad "the resolve beat is not marked resolved:true"
grep -q "^.*RESOLVED: out of overage" "$H/logs/ALERTS.log" && ok || bad "no RESOLVED line in ALERTS.log"
la --resolve --id extra-usage-overage-acct extra-usage "out of overage, back on credits"
la --resolve --id never-fired-at-all extra-usage "this condition was never announced"
[ "$(sent)" = 4 ] && ok || bad "a resolve for a closed/unknown id paged (sent=$(sent), want 4)"
grep -q "resolve-silent id=never-fired-at-all" "$H/logs/alerts-state.log" \
  && ok || bad "the silent resolve was not journaled"
# ...and the closed id is a NEW incident next time, not a repeat of the old one.
la --id extra-usage-overage-acct --severity critical extra-usage "account is in overage again"
[ "$(sent)" = 5 ] && ok || bad "a resolved id did not fire fresh on recurrence (sent=$(sent))"

# ── 4. SEVERITY ROUTING ─────────────────────────────────────────────────────
# critical pages, warn waits for the digest, info never leaves the box.
reset
la --id sev-crit --severity critical lane "a critical thing"
[ "$(sent)" = 1 ] && ok || bad "critical did not page (sent=$(sent))"
la --id sev-warn --severity warn lane "a warn thing"
[ "$(sent)" = 1 ] && ok || bad "warn paged instead of batching (sent=$(sent), want 1)"
grep -q "a warn thing" "$H/state/alert-warn-batch.jsonl" 2>/dev/null \
  && ok || bad "warn was not spooled to the batch"
la --id sev-info --severity info lane "an info thing"
[ "$(sent)" = 1 ] && ok || bad "info was sent (sent=$(sent), want 1)"
grep -q "an info thing" "$H/logs/ALERTS.log" && ok || bad "info must still reach ALERTS.log"
grep -q "info-only id=sev-info" "$H/logs/alerts-state.log" && ok || bad "info decision not journaled"

# A retraction rides the channel its ALERT used. Closing the warn above must not
# page: handing the noise back with one sign flipped is the exact shape of the
# ~35 RESOLVED lines a day this replaces.
la --resolve --id sev-warn lane "the warn thing recovered"
[ "$(sent)" = 1 ] && ok || bad "resolving a warn paged instead of batching (sent=$(sent), want 1)"
grep -q "the warn thing recovered" "$H/state/alert-warn-batch.jsonl" 2>/dev/null \
  && ok || bad "the warn's resolve was not spooled to the batch"

# The digest is the delivery half: a warn that only ever spools is a warn nobody
# gets, which is worse than the noise it replaced.
"$DIR/bin/alert-digest.sh" --warn-batch >/dev/null 2>&1
[ "$(sent)" = 2 ] && ok || bad "--warn-batch did not send the batch (sent=$(sent))"
grep -q "a warn thing" "$T/sent.jsonl" && ok || bad "the batch does not carry the warn's text"
[ ! -s "$H/state/alert-warn-batch.jsonl" ] && ok || bad "the spool was not drained"
"$DIR/bin/alert-digest.sh" --warn-batch >/dev/null 2>&1
[ "$(sent)" = 2 ] && ok || bad "an empty spool manufactured a digest ping (sent=$(sent))"

# ── 5. HASH DEDUPE FOR AN EMITTER THAT NAMES NO ID ──────────────────────────
# pipeline-health and the jobs watchdog are owned by other lanes and cannot be
# edited here, so the primitive has to collapse their repeats on its own: same
# normalised text = same condition, even when the emitter decorates its akey
# with a fresh timestamp every pass (which is exactly what defeats every
# akey-based dedupe downstream).
reset
beat() { "$DIR/bin/beat.sh" "$1" >/dev/null 2>&1; }
mk() { jq -nc --arg akey "$1" --arg l "$2" '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}'; }
beat "$(mk "health:stalepr:2026091514" "[pipeline-health] project-7: harness PR(s) #359,#327 open >12h awaiting merge")"
[ "$(sent)" = 1 ] && ok || bad "an unkeyed alert did not page on first sighting (sent=$(sent))"
beat "$(mk "health:stalepr:2026091515" "[pipeline-health] project-7: harness PR(s) #359,#327 open >12h awaiting merge")"
beat "$(mk "health:stalepr:2026091516" "[pipeline-health] project-7: harness PR(s) #359,#327 open >12h awaiting merge")"
[ "$(sent)" = 1 ] && ok || bad "repeat text under a moving akey paged again (sent=$(sent), want 1)"
grep -q "still firing id=auto-" "$H/logs/alerts-state.log" \
  && ok || bad "the derived-id suppression was not journaled"
# A genuinely different condition still gets through — the dedupe must not be a
# mute button. row_key keeps PR/ticket identities apart on purpose.
beat "$(mk "health:stuckqueue:2026091516" "[pipeline-health] project-3 TK-1199 queued 51m with no spawn")"
[ "$(sent)" = 2 ] && ok || bad "a different condition was swallowed (sent=$(sent), want 2)"

# ── 6. PARKED BOX -> INFO ───────────────────────────────────────────────────
# The project-10 box is switched off on purpose. Its canary failing is the
# expected outcome, not news, and it accounted for 5 lines every 6h.
reset
printf 'parked project-10\n' > "$CONF"
beat "$(mk "lanedown:project-10-codex:20260915" "RUNNER LANE DOWN: codex on project-10 box failed its canary")"
[ "$(sent)" = 0 ] && ok || bad "a parked box's LANE DOWN paged (sent=$(sent), want 0)"
# flags/paused-<box> says the same thing without editing the conf.
rm -f "$CONF"; touch "$H/flags/paused-project-10"
beat "$(mk "lanedown:project-10-grok:20260915" "RUNNER LANE DOWN: grok on project-10 box failed its canary")"
[ "$(sent)" = 0 ] && ok || bad "flags/paused-<box> did not downgrade LANE DOWN (sent=$(sent))"
# A box that is IN SERVICE is untouched: this is a downgrade for parked boxes,
# never a blanket mute on the word "DOWN".
beat "$(mk "lanedown:hub-codex:20260915" "RUNNER LANE DOWN: codex on hub box failed its canary")"
[ "$(sent)" = 1 ] && ok || bad "a live box's LANE DOWN was swallowed (sent=$(sent), want 1)"
# ...and a parked box NAMED INSIDE AN UNRELATED ALERT must not mute it either.
beat "$(mk "costcap:fleet:20260915" "fleet spent \$2227.74 in 24h (cap \$800) — project-10 is in the rollup")"
[ "$(sent)" = 2 ] && ok || bad "a parked box's name inside an unrelated alert muted it (sent=$(sent))"

# ── 6b. ONE CANARY FAILURE IS ONE ALERT ─────────────────────────────────────
# ONE FAILURE, ONE ALERT — even though the canary says it twice, in two
# different sentences. bin/claude-auth-check.sh writes "[auth] <box>-<lane> LANE
# DOWN" straight into ALERTS.log and separately beats "RUNNER LANE DOWN: ...";
# poll-commands.sh re-beats that log line a minute later, so without a rule
# mapping the two onto one id every canary failure pages twice.
reset
beat "$(jq -nc --arg akey "lanedown:hub-codex:20260915" --arg id "lanedown-hub-codex" \
  --arg l "RUNNER LANE DOWN (new): codex on hub box failed its canary — that fallback tier is NOT available if primaries fail there." \
  '{kind:"fleet_alert",project:"fleet",akey:$akey,alertid:$id,severity:"warn",line:$l}')" >/dev/null 2>&1
beat "$(jq -nc --arg akey "alert:abc:20260915" \
  --arg l "2026-09-15 15:00:01Z [auth] hub-codex LANE DOWN (new)" \
  '{kind:"alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1
[ "$(sent)" = 0 ] && ok || bad "a warn LANE DOWN paged instead of batching (sent=$(sent))"
[ "$(grep -c . "$H/state/alert-warn-batch.jsonl" 2>/dev/null || echo 0)" = 1 ] \
  && ok || bad "the canary's two sentences were batched as two conditions, want 1"
# The RECOVERY lines the emitters write straight into ALERTS.log arrive here via
# the same re-beat, carrying no severity — the default would make each one a
# fresh critical page announcing that something is FINE.
beat "$(mk "alert:def:20260915" "2026-09-15 15:40:01Z [auth] hub-codex RECOVERED")"
beat "$(mk "alert:ghi:20260915" "2026-09-15 15:41:01Z [jobs-watchdog] LANE RESUMED: project-7@hub is ticking again.")"
[ "$(sent)" = 0 ] && ok || bad "a recovery line paged as a fresh alert (sent=$(sent), want 0)"


# ── 7. CONF-DRIVEN COLLAPSE AND SEVERITY RULES ──────────────────────────────
# Ten SILENT rows naming ten different tickets are ONE dead lane. row_key keeps
# them apart (correctly, for its own purpose), so the conf collapses them.
reset
cat > "$CONF" <<'CONF'
collapse \[jobs-watchdog\] SILENT job: ([a-z0-9-]+) jobs-watchdog-silent-\1
severity \[pipeline-health\] RESOLVED  info
CONF
for k in TK-1168 TK-1172 TK-1181 TK-1199; do
  beat "$(mk "jobs:$k" "[jobs-watchdog] SILENT job: project-5 build/project-5/decompose key=$k has shown no activity for 91m")"
done
[ "$(sent)" = 1 ] && ok || bad "4 SILENT rows for one project sent $(sent) pages, want 1"
[ -s "$H/state/alerts/jobs-watchdog-silent-project-5.json" ] \
  && ok || bad "the collapse rule did not produce the templated id"
# A retraction is good news, and good news does not need to reach a phone.
beat "$(mk "health:stalepr:project-7" "[pipeline-health] RESOLVED stalepr:project-7 — condition no longer holds")"
[ "$(sent)" = 1 ] && ok || bad "a demoted-to-info RESOLVED line paged (sent=$(sent), want 1)"

# ── 7b. THE SAME RULES, WITH NO CONF FILE AT ALL ────────────────────────────
# flags/ is machine-local and is NOT one of the directories harness-sync rsyncs,
# so a collapse rule that lives only in env-templates/alerts.conf.example takes
# effect on exactly the boxes where somebody remembered to copy a file. The
# three emitters these rules cover are owned by other lanes and cannot be fixed
# at the source, so the rules ship in bin/lib/alert-state.sh and this asserts
# they are in force out of the box.
reset
[ ! -e "$CONF" ] || bad "reset left a conf file behind"
for k in TK-1168 TK-1172 TK-1181; do
  beat "$(mk "jobs:$k" "[jobs-watchdog] SILENT job: project-5 build/project-5/decompose key=$k has shown no activity for 91m")"
done
[ "$(sent)" = 1 ] && ok || bad "the built-in SILENT collapse is not in force with no conf (sent=$(sent), want 1)"
beat "$(mk "health:stalepr:project-7" "[pipeline-health] RESOLVED stalepr:project-7 — condition no longer holds")"
# TEST-CHANGE (BH-4054): the built-in that keeps this line off the wire is now
# the log-only rule (the info rule is gone); the assertion is unchanged.
[ "$(sent)" = 1 ] && ok || bad "the built-in RESOLVED log-only rule is not in force with no conf (sent=$(sent))"
# ...and a box can drop them.
reset
printf 'set ALERT_BUILTIN_RULES 0\n' > "$CONF"
for k in TK-1168 TK-1172 TK-1181; do
  beat "$(mk "jobs:$k" "[jobs-watchdog] SILENT job: project-5 build/project-5/decompose key=$k has shown no activity for 91m")"
done
[ "$(sent)" = 3 ] && ok || bad "ALERT_BUILTIN_RULES 0 did not drop the shipped rules (sent=$(sent), want 3)"
# A --resolve is the CLOSING EDGE of a real page and must never be caught by a
# blanket rule on the word RESOLVED — that turns fire-once/resolve-once into
# fire-once, silently.
reset
la --id closing-edge --severity critical lane "something broke"
la --resolve --id closing-edge lane "something recovered"
# TEST-CHANGE (BH-4054): the resolve is two beats now (orclane + its alert twin).
[ "$(sent)" = 3 ] && ok || bad "a lane resolve was demoted to info by a rule (sent=$(sent), want 3)"

# ── 8. FAIL OPEN ────────────────────────────────────────────────────────────
# The noise filter is allowed to cost a duplicate page. It is never allowed to
# cost a page. Both kill switches restore the old behaviour exactly.
reset
touch "$H/flags/alert-state-off"
for i in 1 2 3; do la --id off-test --severity critical lane "the switch is off"; done
[ "$(sent)" = 3 ] && ok || bad "flags/alert-state-off did not restore per-event sending (sent=$(sent))"
[ "$(alerts_n)" = 3 ] && ok || bad "with the machine off, ALERTS.log should carry all 3 lines"
rm -f "$H/flags/alert-state-off"
reset
printf 'set ALERT_STATE_ENABLED 0\n' > "$CONF"
for i in 1 2 3; do la --id off-test --severity critical lane "the switch is off"; done
[ "$(sent)" = 3 ] && ok || bad "ALERT_STATE_ENABLED=0 did not restore per-event sending (sent=$(sent))"

# ── 9. BACKWARD COMPATIBILITY ───────────────────────────────────────────────
# Every existing caller passes no flags at all, and every existing reader greps
# ALERTS.log for "[orchestrator/<lane>] ". Neither may change shape.
reset
la some-lane "a plain old two-argument call"
grep -q "^[0-9-]* [0-9:]*Z \[orchestrator/some-lane\] a plain old two-argument call$" "$H/logs/ALERTS.log" \
  && ok || bad "the legacy ALERTS.log line shape changed: $(cat "$H/logs/ALERTS.log")"
[ "$(sent)" = 1 ] && ok || bad "a flagless call did not page (sent=$(sent))"
# A non-alert beat is not the state machine's business at all.
S0=$(sent)
"$DIR/bin/beat.sh" '{"kind":"status","project":"project-5","line":"tick"}' >/dev/null 2>&1
[ "$(sent)" -gt "$S0" ] && ok || bad "a non-alert beat was swallowed by the alert gate"

echo "alert-state-machine: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
