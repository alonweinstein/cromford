#!/bin/bash
# tests/factory-stop-digest.bh-3711-test.sh — BH-3711 (slice 4 of BH-3687): a
# factory stop is stated in the daily digest and in pipeline-health.
#
# D runs the REAL bin/alert-digest.sh, copied into a scratch $HARNESS with the
# real factory-stop / lane-switch / lane-gate libs, a stub jobs worker that
# answers GET /api/settings/switch.factory-stop from a fixture, and bin/beat.sh
# stubbed to record its argument. The clock is pinned through PAUSE_NOW.
#   D1 row on since T-3h -> the beat carries `FACTORY STOP ON since <iso>
#      (3h00m) by operator: "freeze for audit"`;
#   D2 row off -> the beat is sent (a triage line exists), no factory text;
#   D3 empty triage log, switch on -> exactly one beat anyway;
#   D4 the GET fails -> an empty day sends nothing; with a triage line the beat
#      says `factory-stop state unknown (worker did not answer).`;
#   D5 an unparseable since -> `age unknown`, never an epoch-0 age.
# H extracts pipeline-health's `# >>> factory stop state` block and its
# alert_digest function verbatim and runs them:
#   H1 on -> one `factory-stop: ON since …` line, one warn beat keyed
#      health:factorystop:on; a second run inside 21600 s adds no beat;
#   H2 off -> neither;  H3 GET fails -> one `state unknown` line, no beat.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
NOW=1790000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE=$(iso $((NOW - 3*3600)))

setup() {
  scratch_rm "$H"; scratch_rm "$T/beats"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags"
  cp "$DIR/bin/alert-digest.sh" "$H/bin/"
  cp "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/factory-stop.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
  cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  case "$2" in
    /api/settings/switch.factory-stop) [ -r "$ONE_FILE" ] || return 1; cat "$ONE_FILE" ;;
    *) return 1 ;;
  esac
}
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats"\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  : > "$H/logs/alert-triage.log"; rm -f "$T/one.json"
}
one() { # one <value> [since] — the single-key answer
  jq -nc --arg v "$1" --arg u "${2-$SINCE}" '{key:"switch.factory-stop",setting:{key:"switch.factory-stop",value:$v,updated_at:$u,actor:"operator",note:"freeze for audit"}}' > "$T/one.json"
}
triage_line() { printf '%s HANDLED something\n' "$(date -u '+%Y-%m-%d %H:%M')" >> "$H/logs/alert-triage.log"; }
fsenv() { env HARNESS="$H" ONE_FILE="$T/one.json" JOBS_BOX=hub-1 JOBS_URL=http://stub.invalid LANE_GATE_NOW="$NOW" "$@"; }
digest() { fsenv PAUSE_NOW="$NOW" bash "$H/bin/alert-digest.sh" >/dev/null 2>&1; }
beats()  { [ -f "$T/beats" ] && wc -l < "$T/beats" | tr -d ' ' || echo 0; }
line()   { jq -r '.line' "$T/beats" 2>/dev/null; }

# ── D ──────────────────────────────────────────────────────────────────────
setup; one 1; triage_line; digest
L=$(line)
grep -qF " FACTORY STOP ON since $SINCE (3h00m) by operator: \"freeze for audit\" — no builds, triage launches, merges or deploys until bin/factory-stop.sh off." <<<"$L" \
  && ok || bad "D1: the digest must state the stop (beats=$(beats), line: $L)"

setup; one 0; triage_line; digest
[ "$(beats)" = 1 ] && ok || bad "D2: a triage line still sends (beats=$(beats))"
grep -qi 'factory' <<<"$(line)" && bad "D2: switch off must add no factory text: $(line)" || ok

setup; one 1; digest
[ "$(beats)" = 1 ] && ok || bad "D3: a quiet day with the switch on must still send once (beats=$(beats))"
grep -qF 'FACTORY STOP ON' <<<"$(line)" && ok || bad "D3: the quiet-day beat names the stop: $(line)"

setup; digest
[ "$(beats)" = 0 ] && ok || bad "D4: an unknown state on an empty day must not force a send (beats=$(beats): $(line))"
setup; triage_line; digest
grep -qF ' factory-stop state unknown (worker did not answer).' <<<"$(line)" \
  && ok || bad "D4: an unreadable switch is said as unknown, never as off: $(line)"
grep -qF 'FACTORY STOP ON' <<<"$(line)" && bad "D4: unknown must not read as ON" || ok

setup; one 1 'not-a-date'; digest
grep -qF 'FACTORY STOP ON since not-a-date (age unknown) by operator' <<<"$(line)" \
  && ok || bad "D5: an unparseable since reads 'age unknown': $(line)"
grep -qE '[0-9]{3,}d|[0-9]{4,}h' <<<"$(line)" && bad "D5: an epoch-0 age leaked: $(line)" || ok

setup; one on ''; digest
grep -qF 'FACTORY STOP ON since unknown (age unknown) by operator' <<<"$(line)" \
  && ok || bad "D5: an empty since is never today's midnight: $(line)"

# ── H ──────────────────────────────────────────────────────────────────────
awk '/^# >>> factory stop state/{f=1;next} /^# <<< factory stop state/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/fs-block.sh"
awk '/^alert_digest\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$T/ad.sh"
[ -s "$T/fs-block.sh" ] && ok || bad "H0: pipeline-health needs a '# >>> factory stop state' block"
[ -s "$T/ad.sh" ] && ok || bad "H0: could not extract alert_digest from pipeline-health"
health() {
  fsenv H="$H" NOW="$NOW" DEDUP="$H/state/health-alerted.json" FIRED="$H/state/health-fired.1" \
    bash -c 'set -uo pipefail
      STAMP() { printf TS; }
      . "$0"; . "$1"' "$T/ad.sh" "$T/fs-block.sh" >/dev/null 2>"$T/health.err"
}
hsetup() { setup; echo '{}' > "$H/state/health-alerted.json"; : > "$H/logs/pipeline-health.log"; }
hlines() { grep -c -- "$1" "$H/logs/pipeline-health.log" || true; }

hsetup; one 1; health
[ "$(hlines "^TS factory-stop: ON since $SINCE (3h00m) by operator — freeze for audit\$")" = 1 ] \
  && ok || bad "H1: one state line (log: $(cat "$H/logs/pipeline-health.log"), stderr: $(cat "$T/health.err"))"
[ "$(beats)" = 1 ] && ok || bad "H1: exactly one warn digest (beats=$(beats))"
B=$(head -1 "$T/beats" 2>/dev/null)
[ "$(jq -r '.severity + " " + .akey' <<<"$B" 2>/dev/null)" = "warn health:factorystop:on" ] \
  && ok || bad "H1: the beat is a warn keyed health:factorystop:on: $B"
grep -qF "factory-stop is ON since $SINCE (3h00m) by operator: freeze for audit" <<<"$(jq -r .line <<<"$B" 2>/dev/null)" \
  && ok || bad "H1: the digest text: $B"
health
[ "$(beats)" = 1 ] && ok || bad "H1: a second run inside 21600 s adds no beat (beats=$(beats))"

hsetup; one 0; health
[ "$(hlines 'factory-stop')" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "H2: switch off writes neither (log: $(cat "$H/logs/pipeline-health.log"), beats=$(beats))"

hsetup; health
[ "$(hlines '^TS factory-stop: state unknown$')" = 1 ] && [ "$(beats)" = 0 ] && ok \
  || bad "H3: an unreadable switch is one line and no alert (log: $(cat "$H/logs/pipeline-health.log"), beats=$(beats))"

echo "factory-stop-digest.bh-3711-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
