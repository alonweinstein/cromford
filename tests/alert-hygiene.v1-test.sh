#!/bin/bash
# tests/alert-hygiene.v1-test.sh — V1 alert hygiene (2026-09-25): the operator
# must be able to trust alerts by exception. That day the console held ~459 open
# rows and the triage backlog 1,036 lines over 533 families, mostly noise. This
# pins the measured causes this change removes:
#   R1  status events (account ran out + requeued, pool build DEFERRED +
#       requeued) route to info — logged, never sent — HOTFIX seen/pr_open/merged
#       are main's log-only notices (BH-2337, BH-2381), while the lines that owe a
#       human something still page, a hotfix FAILURE line among them
#   R2  DEFAULT GH TOKEN CANNOT SEE: log-only when the admin token covers
#       (BH-2337), critical when nothing sees the repo
#   R3  the auth canary's ALERTS.log lines collapse onto the id its beat declares,
#       whatever the probe's own words were
#   R4  hotfix_announce: seen/pr_open/merged beat nothing (main's BH-2337/BH-2381
#       contract, unchanged by V1); any other event still beats pre-triaged
#   R5  the ALERTS.log re-beat (poll-commands.sh) keys the console row on the
#       CONDITION: no date, and two wordings of one condition share one akey
#   R6  fleet.conf `# @retired` is read by the registry and downgrades DOWN lines
#       naming a retired project/box; a live box is untouched
#   R7  alert knobs are DB-driven through main's conf-row mechanism (BH-2411):
#       a row conf.alerts.<name> answers after the environment, before the box
#       conf and the code default
#   R9  a conf.alerts row may never switch the shipped rules off, set the
#       default severity to info, or set the PR-subject / auth-prose regexes
#       that decide what the groomer and the sweep close (the #2291 allow-list,
#       ported onto conf-row)
#   R8  bin/alerts-hygiene-sweep.sh: dry run resolves nothing and prints before /
#       after counts; --apply resolves exactly the classified rows, by class
# Run from anywhere: tests/alert-hygiene.v1-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
export HARNESS="$H" PATH="$T/stub:$PATH"
for s in beat.sh lane-alert.sh alert-digest.sh alert_family.py fleet-conf.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""; url=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && printf '%s\n' "\$a" >> "$T/sent.jsonl"
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */api/alerts/open) cat "$T/open.json" ;;
  */api/alerts/resolve) echo '{"resolved":1}' ;;
  *) echo '{"ok":true}' ;;
esac
STUB
chmod +x "$T/stub/curl"
export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<'CONF'
live-os  example-org/live-os  - - 1 box-live 10.0.0.1
# PARKED: gone-proj  example-org/gone - - 0 box-gonebox
# @retired gone-proj box-gonebox
CONF

sent()  { [ -f "$T/sent.jsonl" ] && grep -c . "$T/sent.jsonl" || echo 0; }
reset() { local p; for p in "$H/state/alerts" "$H/state/alert-warn-batch.jsonl"* "$T/sent.jsonl"; do scratch_rm "$p"; done; : > "$H/logs/ALERTS.log"; : > "$H/logs/alerts-state.log"; }
beat()  { "$DIR/bin/beat.sh" "$1" >/dev/null 2>&1; }
mk()    { jq -nc --arg akey "$1" --arg l "$2" '{kind:"alert",project:"fleet",akey:$akey,line:$l}'; }
spooled() { [ -f "$H/state/alert-warn-batch.jsonl" ] && grep -c . "$H/state/alert-warn-batch.jsonl" || echo 0; }

# ── R1 status events are info ───────────────────────────────────────────────
reset
beat "$(mk k1 '2026-09-24 13:48:53Z [pool/project-5] TK-3306: account max5 ran out (BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED). It is cooled on the hub and another account can serve, so there is no project hold: the ticket is requeued with its deferral count unchanged (0), 6835 is destroyed rather than reused')"
beat "$(mk k2 '2026-09-23 13:29:06Z [pool/project-3] TK-202: pool build DEFERRED (BUILD_DEFERRED plan session produced no output) — requeued attempt 1')"
[ "$(sent)" = 0 ] && ok || bad "R1: a status event was sent ($(sent)): $(cat "$T/sent.jsonl")"
[ "$(grep -c 'info-only' "$H/logs/alerts-state.log")" = 2 ] && ok || bad "R1: the two status events were not journaled info-only: $(cat "$H/logs/alerts-state.log")"
# HOTFIX notices follow main (BH-2337, BH-2381): log-only, never noted or sent.
beat "$(mk k3 '2026-09-24 10:00:00Z [proj/AB-9] HOTFIX seen: AB-9 — payments are down')"
beat "$(mk k4 '2026-09-24 10:05:00Z [proj/AB-9] HOTFIX pr_open: PR opened https://github.com/o/r/pull/7')"
beat "$(mk k7 '2026-09-25 05:38:17Z [proj/AB-9] HOTFIX merged: https://github.com/o/r/pull/7')"
[ "$(sent)" = 0 ] && ok || bad "R1: a HOTFIX notice was sent ($(sent)): $(cat "$T/sent.jsonl")"
[ "$(grep -c 'log-only :: .*HOTFIX' "$H/logs/alerts-state.log")" = 3 ] && ok || bad "R1: the three HOTFIX notices were not journaled log-only: $(cat "$H/logs/alerts-state.log")"
# ...and the lines that DO owe a human something still page, the hotfix lane's
# FAILURE lines (bin/hotfix-after-deploy.sh) included: V1's routing rules and
# condition keys must not swallow them (main pins the log-only side of this in
# tests/alert-hygiene.bh-2381-test.sh H3/H4).
beat "$(mk k5 '2026-09-24 13:29:06Z [pool/project-3] TK-203: pool build DEFERRED (x) — deferred 3 times now, so the queue row is FAILED. This pool will not re-offer it')"
beat "$(mk k6 '2026-09-25 05:38:17Z [pool/project-1] TK-328: POOL_DEFER_TO_HUMAN — spawn cap of 12 in 86400s reached, queue row removed')"
beat "$(mk k8 '2026-09-25 06:00:00Z [proj] HOTFIX POST-DEPLOY APPLY FAILED (abc12345): PR https://github.com/o/r/pull/7 files: 1 failed (build b1)')"
beat "$(mk k9 '2026-09-25 06:01:00Z [proj] HOTFIX CLOSE-OUT OWED (abc12345): the ticket could not be closed (PR https://github.com/o/r/pull/7, build b1)')"
[ "$(sent)" = 4 ] && ok || bad "R1: an actionable line was swallowed (sent=$(sent), want 4 incl. both hotfix failures)"
grep -q 'APPLY FAILED' "$T/sent.jsonl" && grep -q 'CLOSE-OUT OWED' "$T/sent.jsonl" \
  && ok || bad "R1: a hotfix FAILURE line must page: $(cat "$T/sent.jsonl")"

# ── R2 GH token visibility ─────────────────────────────────────────────────
reset
beat "$(mk g1 '2026-09-25 06:52:10Z [auth] DEFAULT GH TOKEN CANNOT SEE example-org/project-4 (project-4) (new): the admin token CAN see it, so lanes routed through bin/lib/gh-repo-token.sh keep working')"
[ "$(sent)" = 0 ] && [ "$(spooled)" = 0 ] && ok || bad "R2: admin-covered repo is a log-only notice on main (sent=$(sent) spooled=$(spooled))"
beat "$(mk g2 '2026-09-25 06:52:10Z [auth] DEFAULT GH TOKEN CANNOT SEE example-org/project-3 (project-3): the admin token cannot see it either (or is absent) — every gh consumer is blind to this repo')"
[ "$(sent)" = 1 ] && ok || bad "R2: a repo no token sees must page (sent=$(sent))"

# ── R3 the canary's lines collapse onto its beat's id ───────────────────────
. "$DIR/bin/lib/alert-state.sh"
A=$(alert_state_key '2026-09-24 00:51:41Z [auth] project-6 AUTH PROBE INCONCLUSIVE: (The Vercel MCP server isnt authorized')
B=$(alert_state_key '2026-09-25 01:51:41Z [auth] project-6 AUTH PROBE INCONCLUSIVE: Also, the Vercel MCP server needs authorization')
[ "$A" = authprobe-project-6 ] && [ "$A" = "$B" ] && ok || bad "R3: two wordings of one probe condition got ids '$A' / '$B', want authprobe-project-6"
[ "$(alert_state_key '2026-09-24 19:52:04Z [auth] project-1 CLAUDE AUTH DOWN: The plugin needs authorization')" = authdown-project-1 ] \
  && ok || bad "R3: CLAUDE AUTH DOWN must key on authdown-<box>"
[ "$(alert_state_key '[auth] hub MODEL POOL EXHAUSTED — auth is fine')" = pooldry-hub ] && ok || bad "R3: MODEL POOL EXHAUSTED must key on pooldry-<box>"
[ "$(alert_state_key '[auth] DEFAULT GH TOKEN CANNOT SEE example-org/project-4 (project-4) (new): x')" = ghdefault-example-org_project-4 ] \
  && ok || bad "R3: the GH visibility line must key on the beat's id ghdefault-<owner_repo>"

# ── R4 hotfix_announce ─────────────────────────────────────────────────────
SINK="$T/hotfix-beats.txt"; : > "$SINK"
mkdir -p "$T/hf/bin/lib" "$T/hf/logs" "$T/hf/state" "$T/hf/flags"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$SINK" > "$T/hf/bin/beat.sh"; chmod +x "$T/hf/bin/beat.sh"
( . "$DIR/bin/lib/hotfix-lib.sh"
  hotfix_announce "$T/hf" proj AB-1 seen "seen it"
  hotfix_announce "$T/hf" proj AB-1 pr_open "PR opened"
  hotfix_announce "$T/hf" proj AB-1 merged "merged" )
[ ! -s "$SINK" ] && ok || bad "R4: seen/pr_open/merged are notices and must not beat (main, BH-2337/BH-2381): $(cat "$SINK")"
[ "$(grep -cE 'HOTFIX (seen|pr_open|merged):' "$T/hf/logs/ALERTS.log" 2>/dev/null)" = 3 ] \
  && ok || bad "R4: each notice keeps its ALERTS.log line: $(cat "$T/hf/logs/ALERTS.log" 2>/dev/null)"
( . "$DIR/bin/lib/hotfix-lib.sh"; hotfix_announce "$T/hf" proj AB-1 failed "something broke" )
grep -q '"akey":"hotfix:proj:AB-1:failed"' "$SINK" && grep -q '"triaged":true' "$SINK" \
  && ok || bad "R4: any other hotfix event still beats as a pre-triaged page: $(cat "$SINK")"

# ── R5 the ALERTS.log re-beat keys on the condition ─────────────────────────
awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' "$DIR/bin/poll-commands.sh" > "$T/rebeat.sh"
[ -s "$T/rebeat.sh" ] && ok || bad "R5: could not extract the alerts re-beat block"
mkdir -p "$T/pc/logs" "$T/pc/flags" "$T/pc/bin/lib"
for s in alert_family.py fleet-conf.sh; do ln -sf "$DIR/bin/$s" "$T/pc/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$T/pc/bin/lib/alert-state.sh"
printf '#!/bin/bash\necho ""\n' > "$T/pc/bin/project-of.sh"; chmod +x "$T/pc/bin/project-of.sh"
cat > "$T/pc/logs/ALERTS.log" <<'LOG'
2026-09-24 00:51:41Z [auth] project-6 AUTH PROBE INCONCLUSIVE: (The Vercel MCP server isnt authorized
2026-09-25 01:51:41Z [auth] project-6 AUTH PROBE INCONCLUSIVE: Also, the Vercel MCP server needs authorization
2026-09-25 01:52:00Z [project-3] DEPLOY FAILED: build could not start.
LOG
( HARNESS="$T/pc"; BEAT="$T/pc/beat-rec.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pc/rebeats.jsonl"\n' "$T" > "$BEAT"; chmod +x "$BEAT"
  # shellcheck disable=SC1090
  . "$T/rebeat.sh" ) >/dev/null 2>&1
K1=$(sed -n 1p "$T/pc/rebeats.jsonl" | jq -r .akey); K2=$(sed -n 2p "$T/pc/rebeats.jsonl" | jq -r .akey); K3=$(sed -n 3p "$T/pc/rebeats.jsonl" | jq -r .akey)
[ "$K1" = "alert:authprobe-project-6" ] && ok || bad "R5: re-beat akey must be alert:<condition id>, got '$K1'"
[ "$K1" = "$K2" ] && ok || bad "R5: one condition, two days, two wordings must be ONE akey ($K1 vs $K2)"
[ -n "$K3" ] && [ "$K3" != "$K1" ] && ok || bad "R5: a different condition must keep its own akey ($K3)"
grep -qE ':20[0-9]{6}"' "$T/pc/rebeats.jsonl" && bad "R5: a re-beat akey still carries a date: $(cat "$T/pc/rebeats.jsonl")" || ok

# ── R6 retired in the registry ─────────────────────────────────────────────
[ "$("$DIR/bin/fleet-conf.sh" --retired)" = "gone-proj box-gonebox" ] && ok || bad "R6: fleet-conf.sh --retired: '$("$DIR/bin/fleet-conf.sh" --retired)'"
grep -qx gone-proj <<<"$("$DIR/bin/fleet-conf.sh" --projects)" && bad "R6: a retired directive became a watched project" || ok
reset
beat "$(mk r1 'RUNNER LANE DOWN: codex on gonebox box failed its canary')"
beat "$(mk r2 '[jobs-watchdog] LANE SILENT: gone-proj@hub has not ticked')"
[ "$(sent)" = 0 ] && ok || bad "R6: a DOWN line about a retired box/project paged (sent=$(sent))"
beat "$(mk r3 'RUNNER LANE DOWN: codex on live box failed its canary')"
[ "$(sent)" = 1 ] && ok || bad "R6: a live box's DOWN line was muted (sent=$(sent))"

# ── R7 DB-driven knobs (main's conf-row, BH-2411) ──────────────────────────
# No bin/jobs-client.sh in this harness, so conf-row reads the cache as it
# stands and never refreshes it.
cfg() { ( unset ALERT_REMINDER_S; alert_cfg "$@" ); }
printf '{"fetched_at":1,"values":{"conf.alerts.alert_reminder_s":"77"},"seeded":{}}' > "$H/state/settings-cache.json"
[ "$(cfg ALERT_REMINDER_S 21600)" = 77 ] && ok || bad "R7: a row conf.alerts.alert_reminder_s must set ALERT_REMINDER_S (got $(cfg ALERT_REMINDER_S 21600))"
printf 'set ALERT_REMINDER_S 55\n' > "$H/flags/alerts.conf"
[ "$(cfg ALERT_REMINDER_S 21600)" = 77 ] && ok || bad "R7: main's precedence: the row outranks the box conf"
[ "$(ALERT_REMINDER_S=33 alert_cfg ALERT_REMINDER_S 21600)" = 33 ] && ok || bad "R7: the environment must outrank everything"
rm -f "$H/state/settings-cache.json"
[ "$(cfg ALERT_REMINDER_S 21600)" = 55 ] && ok || bad "R7: no row = the box conf"
rm -f "$H/flags/alerts.conf"
[ "$(cfg ALERT_REMINDER_S 21600)" = 21600 ] && ok || bad "R7: no row, no conf = the code default"

# ── R9 a row may tune alerting, never gut it (the #2291 allow-list, on conf-row) ─
# A settings row is written from the console, fleet-wide. Two knobs a row must
# never reach, whatever main's conf-row accepts as well formed:
#   ALERT_BUILTIN_RULES      0 drops every shipped collapse / severity / logonly
#                            rule at once, on every box (refused at any value)
#   ALERT_DEFAULT_SEVERITY   info mutes every emitter nobody retrofitted
# A refused row is logged and read as no row (BH-2478), so the box conf, then
# the code default, answers. Env and flags/alerts.conf can still set both.
# (The kill switch and *_RE rows are main's BH-2411/BH-2478 contract and pinned
# as row-settable there; they are not changed here.)
# A fresh process per read: conf-row memoises the rows per shell.
acfg() { env -u ALERTS_CONF -u ALERT_BUILTIN_RULES -u ALERT_DEFAULT_SEVERITY HARNESS="$H" \
           bash -c '. "$1/bin/lib/alert-state.sh"; alert_cfg "$2" "$3"' _ "$DIR" "$1" "$2" 2>/dev/null; }
alogonly() { env -u ALERTS_CONF -u ALERT_BUILTIN_RULES HARNESS="$H" \
           bash -c '. "$1/bin/lib/alert-state.sh"; alert_state_logonly "$2"' _ "$DIR" "$1" >/dev/null 2>&1; }
rm -f "$H/flags/alerts.conf" "$H/logs/lane-gate.log"
printf '{"fetched_at":1,"seeded":{},"values":{"conf.alerts.alert_builtin_rules":"0","conf.alerts.alert_default_severity":"info"}}' > "$H/state/settings-cache.json"
[ "$(acfg ALERT_BUILTIN_RULES 1)" = 1 ] && ok || bad "R9: a row must not switch the shipped rules off (got $(acfg ALERT_BUILTIN_RULES 1))"
alogonly '[proj/AB-9] HOTFIX seen: AB-9 — x' && ok || bad "R9: with a builtin_rules=0 row the shipped logonly rule must still apply"
[ "$(acfg ALERT_DEFAULT_SEVERITY critical)" = critical ] && ok || bad "R9: a row must not set the default severity to info (got $(acfg ALERT_DEFAULT_SEVERITY critical))"
grep -q "conf.alerts.alert_builtin_rules='0' refused" "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "R9: the refused builtin_rules row must be logged: $(cat "$H/logs/lane-gate.log" 2>/dev/null)"
grep -q "conf.alerts.alert_default_severity='info' refused" "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "R9: the refused severity row must be logged: $(cat "$H/logs/lane-gate.log" 2>/dev/null)"
# refused = no row, so the box conf answers
printf 'set ALERT_DEFAULT_SEVERITY warn\nset ALERT_BUILTIN_RULES 1\n' > "$H/flags/alerts.conf"
[ "$(acfg ALERT_DEFAULT_SEVERITY critical)" = warn ] && ok || bad "R9: a refused severity row falls through to flags/alerts.conf"
# the box conf and the environment keep both knobs
printf 'set ALERT_BUILTIN_RULES 0\nset ALERT_DEFAULT_SEVERITY info\n' > "$H/flags/alerts.conf"
[ "$(acfg ALERT_BUILTIN_RULES 1)" = 0 ] && ok || bad "R9: flags/alerts.conf may still drop the shipped rules"
[ "$(acfg ALERT_DEFAULT_SEVERITY critical)" = info ] && ok || bad "R9: flags/alerts.conf may still set severity info"
rm -f "$H/flags/alerts.conf"
[ "$(ALERT_DEFAULT_SEVERITY=info HARNESS="$H" bash -c '. "$1/bin/lib/alert-state.sh"; alert_cfg ALERT_DEFAULT_SEVERITY critical' _ "$DIR" 2>/dev/null)" = info ] \
  && ok || bad "R9: the environment may still set severity info"
# The PR-subject and auth-prose regexes decide which rows the groomer and the
# sweep may CLOSE. A row of "." would settle every PR-naming row on merge (the
# #2293 bug) or sweep every auth page, so neither is ever read from a row;
# env and flags/alerts.conf still set them.
acfgre() { env -u ALERTS_CONF -u ALERTS_PR_SUBJECT_RE -u ALERTS_SWEEP_AUTH_PROSE_RE HARNESS="$H" \
           bash -c '. "$1/bin/lib/alert-state.sh"; alert_cfg "$2" "$3"' _ "$DIR" "$1" "$2" 2>/dev/null; }
rm -f "$H/flags/alerts.conf" "$H/logs/lane-gate.log"
printf '{"fetched_at":1,"seeded":{},"values":{"conf.alerts.alerts_pr_subject_re":".","conf.alerts.alerts_sweep_auth_prose_re":"."}}' > "$H/state/settings-cache.json"
[ "$(acfgre ALERTS_PR_SUBJECT_RE X)" = X ] && ok || bad "R9: a row must not widen what a PR close settles (got $(acfgre ALERTS_PR_SUBJECT_RE X))"
[ "$(acfgre ALERTS_SWEEP_AUTH_PROSE_RE X)" = X ] && ok || bad "R9: a row must not widen what the sweep calls a false auth page (got $(acfgre ALERTS_SWEEP_AUTH_PROSE_RE X))"
grep -q "conf.alerts.alerts_pr_subject_re='.' refused" "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "R9: the refused PR-subject row must be logged: $(cat "$H/logs/lane-gate.log" 2>/dev/null)"
printf 'set ALERTS_PR_SUBJECT_RE Merge queue: #\nset ALERTS_SWEEP_AUTH_PROSE_RE AUTH DOWN.*MCP\n' > "$H/flags/alerts.conf"
[ "$(acfgre ALERTS_PR_SUBJECT_RE X)" = "Merge queue: #" ] && ok || bad "R9: flags/alerts.conf may still set ALERTS_PR_SUBJECT_RE (got $(acfgre ALERTS_PR_SUBJECT_RE X))"
[ "$(acfgre ALERTS_SWEEP_AUTH_PROSE_RE X)" = "AUTH DOWN.*MCP" ] && ok || bad "R9: flags/alerts.conf may still set ALERTS_SWEEP_AUTH_PROSE_RE"
rm -f "$H/flags/alerts.conf"
[ "$(ALERTS_PR_SUBJECT_RE='^mq-' HARNESS="$H" bash -c '. "$1/bin/lib/alert-state.sh"; alert_cfg ALERTS_PR_SUBJECT_RE X' _ "$DIR" 2>/dev/null)" = '^mq-' ] \
  && ok || bad "R9: the environment may still set ALERTS_PR_SUBJECT_RE"
[ "$(ALERTS_SWEEP_AUTH_PROSE_RE='MCP' HARNESS="$H" bash -c '. "$1/bin/lib/alert-state.sh"; alert_cfg ALERTS_SWEEP_AUTH_PROSE_RE X' _ "$DIR" 2>/dev/null)" = MCP ] \
  && ok || bad "R9: the environment may still set ALERTS_SWEEP_AUTH_PROSE_RE"
# what a row MAY do is unchanged: tune cadence, pick warn/critical. The
# builtin-rules switch is box-only in both directions.
printf '{"fetched_at":1,"seeded":{},"values":{"conf.alerts.alert_default_severity":"warn","conf.alerts.alert_builtin_rules":"1","conf.alerts.alert_reminder_s":"900"}}' > "$H/state/settings-cache.json"
[ "$(acfg ALERT_DEFAULT_SEVERITY critical)" = warn ] && ok || bad "R9: a severity row warn is still accepted"
[ "$(acfg ALERT_BUILTIN_RULES 0)" = 0 ] && ok || bad "R9: ALERT_BUILTIN_RULES is never read from a row, whatever its value"
[ "$(acfg ALERT_REMINDER_S 21600)" = 900 ] && ok || bad "R9: a cadence row is still accepted"
rm -f "$H/state/settings-cache.json" "$H/logs/lane-gate.log"

# ── R10 the state machine's decision rides the beat (fire / remind) ────────
# The console pings a still-open row only when alertstate is fire or remind
# (cromford-console, src/alert-ping.js). Without it on the beat, a
# condition-keyed alert pages once and never again.
reset
beat "$(mk p1 '2026-09-25 01:52:00Z [project-3] DEPLOY FAILED: build could not start.')"
ALERT_REMINDER_S=0 "$DIR/bin/beat.sh" "$(mk p1 '2026-09-25 02:52:00Z [project-3] DEPLOY FAILED: build could not start.')" >/dev/null 2>&1
S1=$(sed -n 1p "$T/sent.jsonl" 2>/dev/null | jq -r '.alertstate // ""'); S2=$(sed -n 2p "$T/sent.jsonl" 2>/dev/null | jq -r '.alertstate // ""')
[ "$S1" = fire ] && ok || bad "R10: the first sighting must carry alertstate fire (got '$S1')"
[ "$S2" = remind ] && ok || bad "R10: the reminder must carry alertstate remind (got '$S2')"

# ── R11 retired names never mute a live project or box, whole words only ───
cat >> "$FLEET_CONF" <<'CONF'
# @retired live-os box-live
# @retired gone box-gone
CONF
: > "$H/logs/alerts-state.log"
TOK=" $(alert_state_retired_tokens) "
case "$TOK" in *" live-os "*|*" live "*|*" box-live "*) bad "R11: a retired directive naming a LIVE project/box was honoured: $TOK" ;; *) ok ;; esac
grep -q 'retired-conflict.*live-os' "$H/logs/alerts-state.log" && ok || bad "R11: the conflict must be logged: $(cat "$H/logs/alerts-state.log")"
reset
beat "$(mk w1 'RUNNER LANE DOWN: codex on gonebox-staging box failed its canary')"
beat "$(mk w2 '[jobs-watchdog] LANE SILENT: gone-proj-v2@hub has not ticked')"
[ "$(sent)" = 2 ] && ok || bad "R11: a retired name must match whole words only, not inside another name (sent=$(sent), want 2)"
beat "$(mk w3 'RUNNER LANE DOWN: codex on live box failed its canary')"
[ "$(sent)" = 3 ] && ok || bad "R11: a live box named in a retired directive must still page (sent=$(sent))"

# ── R8 the one-shot sweep ──────────────────────────────────────────────────
cat > "$T/open.json" <<'JSON'
{"alerts":[
 {"id":1,"akey":"alert:aaa:20260923","project":"project-1","line":"2026-09-23 10:51:51Z [auth] project-6 CLAUDE AUTH DOWN: the plugin needs authorization"},
 {"id":2,"akey":"alert:bbb:20260924","project":"project-6","line":"2026-09-24 01:51:38Z [auth] project-6 CLAUDE AUTH DOWN: the OAuth flow"},
 {"id":3,"akey":"alert:ccc:20260924","project":"project-5","line":"2026-09-24 13:48:53Z [pool/project-5] TK-3306: account max5 ran out (x). It is cooled on the hub and another account can serve, so there is no project hold: the ticket is requeued"},
 {"id":4,"akey":"alert:ddd:20260923","project":"project-3","line":"2026-09-23 13:29:06Z [pool/project-3] TK-202: pool build DEFERRED (x) — requeued attempt 1"},
 {"id":5,"akey":"critical:costzeromerge:project-9","project":"project-9","line":"CRITICAL [pipeline-health] project-9 spent $649.54 in 7d with 0 merged PR(s)"},
 {"id":6,"akey":"mq-hb-lander:project-4:1756","project":"project-4","line":"[UNTRIAGED 45m] Merge queue: #1756 rebase CONFLICTS with main. Needs a hand: https://github.com/example-org/project-4/pull/1756"},
 {"id":7,"akey":"lanedown:gone-proj:20260901","project":"gone-proj","line":"RUNNER LANE DOWN: codex on gonebox box"},
 {"id":8,"akey":"alert:eee:20260925","project":"project-4","line":"2026-09-25 06:52:10Z [auth] DEFAULT GH TOKEN CANNOT SEE example-org/project-4 (project-4) (new): the admin token CAN see it, so lanes keep working"},
 {"id":9,"akey":"","project":"","line":"CRITICAL something real with no akey and no project"},
 {"id":10,"akey":"alert:fff:20260925","project":"project-6","line":"2026-09-25 01:51:41Z [auth] project-6 AUTH PROBE INCONCLUSIVE: Also, the Vercel MCP server (`plugin:vercel:vercel`) needs authorization"},
 {"id":11,"akey":"authdown:hub","project":"fleet","line":"2026-09-25 02:51:41Z [auth] hub CLAUDE AUTH DOWN: The Vercel MCP server needs authorization"},
 {"id":12,"akey":"hotfix:proj:AB-9:pr_open","project":"proj","line":"2026-09-24 10:05:00Z [proj/AB-9] HOTFIX pr_open: PR opened https://github.com/o/r/pull/7"},
 {"id":13,"akey":"alert:ggg","project":"proj","line":"2026-09-25 06:00:00Z [proj] HOTFIX POST-DEPLOY APPLY FAILED (abc12345): PR https://github.com/o/r/pull/7 files: 1 failed (build b1)"}
]}
JSON
# R12: the hub's auth canary still holds `hub` as DOWN, so its prose-looking row
# is NOT swept: the sweep never closes an auth alert for a box the canary has
# not yet seen answer cleanly.
printf 'hub\n' > "$H/state/claude-auth-down.txt"
rm -f "$T/sent.jsonl"
OUT=$("$DIR/bin/alerts-hygiene-sweep.sh" --from-file "$T/open.json" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R8: dry run rc=$RC: $OUT"
grep -q '^open before: 13$' <<<"$OUT" && ok || bad "R8: before count: $OUT"
grep -q '#11 ' <<<"$OUT" && bad "R12: an auth row for a box still in state/claude-auth-down.txt was swept: $OUT" || ok
grep -q '^to resolve: 7$' <<<"$OUT" && ok || bad "R8: want 7 to resolve (1 auth-probe-prose, 1 dup-dated, 2 logonly, 2 reclassified-info, 1 retired): $OUT"
grep -q '2 logonly' <<<"$OUT" && ok || bad "R8: the HOTFIX pr_open and admin-covered GH rows are main's log-only notices: $OUT"
grep -q '#13 ' <<<"$OUT" && bad "R8: a hotfix APPLY FAILED row must never be swept: $OUT" || ok
grep -q '1 auth-probe-prose' <<<"$OUT" && ok || bad "R8: the Vercel-MCP false auth page is its own class: $OUT"
grep -q '^open after (projected): 6$' <<<"$OUT" && ok || bad "R8: projected after: $OUT"
grep -q '1 dup-dated' <<<"$OUT" && ok || bad "R8: the older of the two project-6 AUTH DOWN rows is the dup: $OUT"
grep -q '1 retired' <<<"$OUT" && ok || bad "R8: the retired project's row: $OUT"
grep -q '#5 ' <<<"$OUT" && bad "R8: a real critical row was classified: $OUT" || ok
grep -q '#9 ' <<<"$OUT" && bad "R8: a row with empty akey/project must not shift columns into a class: $OUT" || ok
grep -q '#6 ' <<<"$OUT" && bad "R8: a PR row was classified without --check-prs: $OUT" || ok
grep -q '#2 ' <<<"$OUT" && bad "R8: the NEWEST row of a dated condition must stay open: $OUT" || ok
[ ! -s "$T/sent.jsonl" ] && ok || bad "R8: the dry run POSTed: $(cat "$T/sent.jsonl")"
# --apply against the (stubbed) console: one resolve request per class, exact ids.
rm -f "$T/sent.jsonl"
OUT=$("$DIR/bin/alerts-hygiene-sweep.sh" --apply 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R8: --apply rc=$RC: $OUT"
IDS=$(jq -c '.ids[]' "$T/sent.jsonl" 2>/dev/null | sort -n | tr '\n' ' ')
[ "$IDS" = "1 3 4 7 8 10 12 " ] && ok || bad "R8: --apply resolved ids '$IDS', want '1 3 4 7 8 10 12 '"
grep -qx 'v1-dup-dated' <<<"$(jq -r .reason "$T/sent.jsonl")" && ok || bad "R8: each class records its reason: $(cat "$T/sent.jsonl")"
"$DIR/bin/alerts-hygiene-sweep.sh" --apply --from-file "$T/open.json" >/dev/null 2>&1 \
  && bad "R8: --apply on a saved file must refuse" || ok

# ── R13 --check-prs: a MERGE never settles mq-headbound / mq-tc ─────────────
# (review of #2291) Head-bound = unreviewed code; tc = failing typecheck. A merge
# means that code reached main — worse, not settled. Only a close without merge
# ends them, exactly as bin/alerts-groom.sh rule 1 (#2293).
# The PR state is read over REST through bin/lib/gh-rest.sh (BH-1585), so the
# stub answers `gh api -i -X GET repos/<slug>/pulls/<n>` and logs anything else:
# a GraphQL read (`gh pr view`) reaching this stub is itself a failure.
cat > "$T/stub/gh" <<STUB
#!/bin/bash
case "\$*" in
  "api -i -X GET repos/"*/pulls/*) ;;
  *) printf '%s\n' "\$*" >> "$T/gh-other.log"; exit 1 ;;
esac
case "\$*" in
  *live-os/pulls/41*|*live-os/pulls/42*|*live-os/pulls/44*) B='{"state":"closed","merged_at":"2026-09-25T00:00:00Z"}' ;;
  *live-os/pulls/43*) B='{"state":"closed","merged_at":null}' ;;
  *) B='{"state":"open","merged_at":null}' ;;
esac
printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "\$B"
STUB
chmod +x "$T/stub/gh"
rm -f "$T/gh-other.log"
cat > "$T/open.json" <<'JSON'
{"alerts":[
 {"id":41,"akey":"mq-headbound:live-os:41","project":"live-os","line":"Merge queue: #41 head is not the sha the review approved: https://github.com/example-org/live-os/pull/41"},
 {"id":42,"akey":"mq-tc:live-os:42","project":"live-os","line":"Merge queue: #42 rebase typecheck FAILED — needs a hand: https://github.com/example-org/live-os/pull/42"},
 {"id":43,"akey":"mq-tc:live-os:43","project":"live-os","line":"Merge queue: #43 rebase typecheck FAILED — needs a hand: https://github.com/example-org/live-os/pull/43"},
 {"id":44,"akey":"mq-conflict:live-os:44","project":"live-os","line":"Merge queue: #44 has a semantic conflict with main: https://github.com/example-org/live-os/pull/44"}
]}
JSON
OUT=$("$DIR/bin/alerts-hygiene-sweep.sh" --check-prs --from-file "$T/open.json" 2>&1)
grep -q '#41 ' <<<"$OUT" && bad "R13: a MERGED mq-headbound row must stay open: $OUT" || ok
grep -q '#42 ' <<<"$OUT" && bad "R13: a MERGED mq-tc row must stay open: $OUT" || ok
grep -q '#43 ' <<<"$OUT" && ok || bad "R13: a CLOSED (unmerged) mq-tc row is settled: $OUT"
grep -q '#44 ' <<<"$OUT" && ok || bad "R13: a merged mq-conflict row is settled: $OUT"
grep -q '^to resolve: 2$' <<<"$OUT" && ok || bad "R13: want exactly 2 pr-closed: $OUT"
[ ! -s "$T/gh-other.log" ] && ok || bad "R13: --check-prs must read PR state over REST (bin/lib/gh-rest.sh), not GraphQL: $(cat "$T/gh-other.log")"

# ── R14 the quarantine path: what carries alertstate, and what does not ─────
# An untriaged fleet_alert is quarantined AFTER the state machine decided, so
# the queued payload carries alertstate and the 45-min force-escalation
# (bin/alert-flush.sh, file path) forwards it intact. What does NOT carry it is
# stated in docs/ALERTS-STATE-MACHINE.md: alert-triage's own escalation
# (triage:<key>) and the alerts-db claim path re-key the page without it.
reset
rm -f "$H/flags/alert-quarantine-disabled"
"$DIR/bin/beat.sh" "$(jq -nc '{kind:"fleet_alert",project:"fleet",akey:"q1",line:"[x] QUARANTINE PATH CHECK"}')" >/dev/null 2>&1
QS=$(cut -f2- "$H/state/alert-quarantine.jsonl" 2>/dev/null | jq -r '.alertstate // ""' | head -1)
[ "$QS" = fire ] && ok || bad "R14: the quarantined payload must carry the state machine's alertstate (got '$QS')"
touch "$H/flags/alert-quarantine-disabled"

echo "alert-hygiene.v1: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
