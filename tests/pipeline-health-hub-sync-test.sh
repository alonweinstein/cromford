#!/bin/bash
# tests/pipeline-health-hub-sync-test.sh — "the hub has not synced in N hours",
# the block extracted VERBATIM from bin/pipeline-health.sh by its markers and
# driven against a scratch tree with a pinned clock.
#
# WHY IT EXISTS (BH-628). bin/update-model-prices.sh left the hub's checkout
# dirty on a cron; bin/harness-sync.sh refuses to deploy a dirty checkout;
# the hub's LIVE bin/ then froze for 16 hours while every health check stayed
# green — check 8 compares the CHECKOUT's HEAD to origin, and fleet-propagate's
# ff-only pull keeps that current whether or not the deploy ever lands. The only
# signal was harness-sync's own REFUSED line, one identical copy per attempt,
# which alert-triage's deferral spool swallowed.
#
# So this is the distinct, ESCALATING alert: one line per hour carrying the hour
# count (never one per tick), a --critical lane-alert past the critical
# threshold, and exactly one RESOLVED when a deploy lands.
#
# FAIL-OPEN IS THE PROPERTY UNDER TEST. A refusal whose stamp will not parse
# must still page; a box that has never synced must still page. The negatives
# matter as much: no stamps at all, a refusal older than the last success, and
# a --check run (which writes no stamps at all — see
# tests/harness-sync-stamps-test.sh) must all stay silent.
#
# Run from anywhere: tests/pipeline-health-hub-sync-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/locks"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read; every fixture age is derived from it.
NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

awk '/^# >>> hub sync stall/{f=1;next} /^# <<< hub sync stall/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "could not extract the hub-sync-stall block — markers missing?"

printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"
cat > "$T/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
exit 0
SH
chmod +x "$T/bin/lane-alert.sh"
export LANE_SINK="$T/lane.txt"

R="$T/state/harness-sync-last-refused"
S="$T/state/harness-sync-last-success"
MARK="$T/state/hub-sync-stalled"
echo '{}' > "$T/state/health-alerted.json"

reset() { rm -f "$R" "$S" "$MARK"; : > "$T/lane.txt"; : > "$T/logs/ALERTS.log"
          : > "$T/logs/pipeline-health.log"; echo '{}' > "$T/state/health-alerted.json"; }
drive() { # drive [VAR=val ...] — runs the block with a recording alert()
  : > "$T/alerts.txt"
  ( export HARNESS="$T" T="$T" NOW="$NOW" "$@"
    bash -c '
      set -uo pipefail
      H="$T"; DEDUP="$T/state/health-alerted.json"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$T/cap.sh"; . "$0"' "$T/block.sh" >/dev/null 2>"$T/err.txt" )
}

# ============================================================================
# (a) refused two hours ago, last deploy three hours ago: one hourly page that
#     says how long the hub has been frozen. No Telegram yet.
# ============================================================================
reset
iso 10800 > "$S"
{ iso 7200; echo "dirty uncommitted: catalog/model-prices.json"; } > "$R"
drive
[ "$(wc -l < "$T/alerts.txt")" = 1 ] && ok || bad "(a) expected exactly one alert, got: $(cat "$T/alerts.txt")"
L=$(head -1 "$T/alerts.txt")
grep -q '^3600|hubsyncstall:hub|' <<<"$L" \
  && ok || bad "(a) the stall alert must be hourly under its own key: $L"
grep -q 'has not synced in 3h' <<<"$L" \
  && ok || bad "(a) the line must carry the hour count: $L"
grep -q 'dirty uncommitted: catalog/model-prices.json' <<<"$L" \
  && ok || bad "(a) the line must carry the recorded reason: $L"
grep -q 'bin/harness-sync.sh' <<<"$L" \
  && ok || bad "(a) the line must name the fix: $L"
[ -f "$MARK" ] && ok || bad "(a) the marker must be written so the resolve can fire once"
[ ! -s "$T/lane.txt" ] && ok || bad "(a) below the critical threshold nothing escalates: $(cat "$T/lane.txt")"

# (a-bis) ESCALATING, not repeating: the same condition an hour later says 4h.
: > "$T/alerts.txt"
iso 14400 > "$S"
drive
grep -q 'has not synced in 4h' "$T/alerts.txt" \
  && ok || bad "(a-bis) the hour count must grow with the stall: $(cat "$T/alerts.txt")"

# ============================================================================
# (b) past the critical threshold: the hourly line AND a Telegram-grade page
# ============================================================================
reset
iso 18000 > "$S"
{ iso 3600; echo "dirty uncommitted: bin/run-build.sh"; } > "$R"
drive
grep -q '|hubsyncstall:hub|' "$T/alerts.txt" && ok || bad "(b) the hourly line must still fire: $(cat "$T/alerts.txt")"
grep -q -- '--critical' "$T/lane.txt" && grep -q -- '--id hubsyncstall:hub' "$T/lane.txt" \
  && ok || bad "(b) past the critical threshold this must escalate: $(cat "$T/lane.txt")"
grep -q 'has not synced in 5h' "$T/lane.txt" \
  && ok || bad "(b) the escalation must carry the same hour count: $(cat "$T/lane.txt")"

# ============================================================================
# (c) a refusal on a box that has NEVER recorded a success
# ============================================================================
reset
{ iso 7200; echo "diverged 1111111 vs 2222222"; } > "$R"
drive
grep -q '|hubsyncstall:hub|' "$T/alerts.txt" || bad "(c) a refusal with no success stamp must page: $(cat "$T/alerts.txt")"
grep -q '|hubsyncstall:hub|' "$T/alerts.txt" && ok
grep -qi 'never' "$T/alerts.txt" \
  && ok || bad "(c) the line must say there has never been a successful sync: $(cat "$T/alerts.txt")"

# ============================================================================
# (d) FAIL-OPEN: a refusal stamp that will not parse is still a refusal
# ============================================================================
reset
iso 10800 > "$S"
printf 'garbage not a date\nsome reason\n' > "$R"
drive
grep -q '|hubsyncstall:hub|' "$T/alerts.txt" \
  && ok || bad "(d) an unreadable refusal stamp must still page: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -qi 'unreadable' "$T/alerts.txt" \
  && ok || bad "(d) the line must say the stamp could not be read: $(cat "$T/alerts.txt")"
[ ! -s "$T/lane.txt" ] && ok || bad "(d) an unknown age must not be escalated as critical: $(cat "$T/lane.txt")"

# ============================================================================
# (e) it comes back: exactly one RESOLVED, the marker goes, the dedupe key goes
# ============================================================================
reset
touch "$MARK"
jq -n '{"hubsyncstall:hub": 1}' > "$T/state/health-alerted.json"
{ iso 7200; echo "dirty uncommitted: bin/x.sh"; } > "$R"
iso 60 > "$S"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "(e) a recovered hub must not page: $(cat "$T/alerts.txt")"
[ "$(grep -c 'RESOLVED hubsyncstall:hub' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(e) exactly one RESOLVED line: $(cat "$T/logs/ALERTS.log")"
grep -q 'RESOLVED hubsyncstall:hub' "$T/logs/pipeline-health.log" \
  && ok || bad "(e) the resolve must reach the pipeline log too: $(cat "$T/logs/pipeline-health.log")"
[ ! -f "$MARK" ] && ok || bad "(e) the marker must be cleared"
[ "$(jq -r 'has("hubsyncstall:hub")' "$T/state/health-alerted.json")" = false ] \
  && ok || bad "(e) the resolve must clear the dedupe stamp"
grep -q -- '--resolve' "$T/lane.txt" \
  && ok || bad "(e) the escalation must be closed too: $(cat "$T/lane.txt")"
# and not again on the next tick
: > "$T/logs/ALERTS.log"; : > "$T/lane.txt"
drive
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(e) the resolve must fire once, not every tick: $(cat "$T/logs/ALERTS.log")"
[ ! -s "$T/lane.txt" ] && ok || bad "(e) and must not re-resolve at lane-alert either: $(cat "$T/lane.txt")"

# ============================================================================
# (f) a box with no stamps at all: there is no sync here to watch
# ============================================================================
reset
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "(f) no stamps must page nothing: $(cat "$T/alerts.txt")"
[ ! -f "$MARK" ] && ok || bad "(f) no stamps must not leave a marker"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(f) no stamps must write nothing: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# (g) a refusal older than the last success is history, not a stall — and a
#     quiet main with no refusal since is not "the hub has not synced"
# ============================================================================
reset
{ iso 86400; echo "dirty uncommitted: bin/x.sh"; } > "$R"
iso 36000 > "$S"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "(g) a stale refusal must not page: $(cat "$T/alerts.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "(g) and must not resolve something nobody was told about: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# (h) the threshold is operator data, not a constant in the script
# ============================================================================
reset
iso 120 > "$S"
{ iso 60; echo "dirty uncommitted: bin/x.sh"; } > "$R"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "(h) two minutes is not a stall at the default threshold: $(cat "$T/alerts.txt")"
reset
iso 120 > "$S"
{ iso 60; echo "dirty uncommitted: bin/x.sh"; } > "$R"
drive HUB_SYNC_STALL_S=60
grep -q '|hubsyncstall:hub|' "$T/alerts.txt" \
  && ok || bad "(h) HUB_SYNC_STALL_S must be read, not the constant: $(cat "$T/alerts.txt")"
# and the critical knob likewise
reset
iso 300 > "$S"
{ iso 60; echo "dirty uncommitted: bin/x.sh"; } > "$R"
drive HUB_SYNC_STALL_S=60 HUB_SYNC_CRITICAL_S=120
grep -q -- '--critical' "$T/lane.txt" \
  && ok || bad "(h) HUB_SYNC_CRITICAL_S must be read, not the constant: $(cat "$T/lane.txt")"

echo "pipeline-health-hub-sync-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
