#!/bin/bash
# tests/daily-digest.bh-3706-test.sh — BH-3706 (BH-3688.3): the daily-digest
# hub lane, driven through the SHIPPED bin/daily-digest.sh.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H: a symlink tree of
# the repo's bin/, a copy of catalog/lanes.d and switches.d) with two shims:
# bin/beat.sh appends its payload and BEAT_STRICT to $T/beats and exits
# $T/beat.rc; bin/lane-alert.sh records every call. Everything else is real:
# the gate, the switch, jobs-client, the ledger verbs, console_pages_url and
# the #3703 contract libs. A fake `curl` first in PATH is the jobs worker at
# $JOBS_URL:
#   - /api/settings answers $T/settings.json (gate traffic -> $GATELOG);
#   - /api/ledger GET/PUT keeps rows in $T/ledger.json; $T/ledger.code forces
#     that status (503 = rc 1 in job_ledger_get);
#   - /api/metrics/daily-digest answers $T/route.json, or the raw $T/route.body
#     when it exists, with the status in $T/route.code.
# Every other request goes to $REQLOG; every URL at all to $T/urls.
# DAILY_DIGEST_FIXTURE=$T/fx.sh overrides dd_render with a deterministic text
# (dd_summary too, when $T/summary.on exists). D8r runs without it, so the real
# renderer and summary libs (BH-3707) are what the lane sees.
#
# Cases: D1 D3 D4 D5 D6 D7 D8 D8r R3 S1 S2 T1 L1 P1 N1, and the mutations M1-M3
# (sed copies of the lane with the dedupe, the switch, the hour gate removed).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest.bh-3706-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this slice ships (D41).
for f in "$DIR/bin/daily-digest.sh" "$DIR/catalog/lanes.d/daily-digest.json" \
         "$DIR/cron/lanes/722-daily-digest.cron" "$DIR/catalog/switches.d/daily-digest-off.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ -f "$DIR/bin/daily-digest.sh" ] || { echo "daily-digest: $PASS passed, $FAIL failed"; exit 1; }

H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf 'BEAT_STRICT=%s %s\n' "${BEAT_STRICT:-}" "$1" >> "$FXT/beats"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh"
LANE="$H/bin/daily-digest.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary|-d) body="$a" ;;
    -w) wfmt=1 ;;
  esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
printf '%s\n' "$url" >> "$FXT/urls"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
case "$path" in
  /api/settings*|/api/flags*|/api/lanes*) printf '%s %s %s\n' "$m" "$path" "$body" >> "$GATELOG" ;;
  *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG" ;;
esac
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  *" /api/ledger"*)
    if [ -f "$FXT/ledger.code" ]; then code=$(cat "$FXT/ledger.code"); out='{"error":"down"}'
    elif [ "$m" = GET ]; then
      k=$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')
      v=$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    else
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET /api/metrics/daily-digest"*)
    code=$(cat "$FXT/route.code" 2>/dev/null || echo 200)
    if [ -f "$FXT/route.body" ]; then out=$(cat "$FXT/route.body"); else out=$(cat "$FXT/route.json"); fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

# The render seam: a fixed text built from the json's own .day, and the argv
# dd_render was handed, so D1 can check what the lane passed it.
cat > "$T/fx.sh" <<'SH'
dd_render() {
  printf '%s\n' "$@" > "$FXT/render.args"
  if [ "$6" != - ]; then cat "$6" > "$FXT/render.summary"; fi
  local d; d=$(jq -r .day "$1")
  case "$(cat "$FXT/render.mode" 2>/dev/null)" in
    blank) printf '   \n'; return 0 ;;
    fail) return 3 ;;
    long)
      printf 'Daily digest %s\n' "$d"
      local i; for i in $(seq 1 30); do printf 'item %02d → a line of forty-odd characters\n' "$i"; done
      return 0 ;;
  esac
  printf 'Daily digest %s\nline two → ok\nline three\n' "$d"
}
if [ -f "$FXT/summary.on" ]; then
  dd_summary() { printf 'A quiet day.\n' > "$2"; return 0; }
fi
SH

REQLOG="$T/reqlog"; GATELOG="$T/gatelog"
export HARNESS="$H" FXT="$T" REQLOG GATELOG \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  CONSOLE_PAGES_URL=https://console.invalid/ PATH="$T/fakebin:$PATH"
unset DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_MAX_ITEMS DAILY_DIGEST_TEXT_MAX_CHARS \
  DAILY_DIGEST_REBUILD_LOOP_MIN DAILY_DIGEST_HUMAN_ACTORS DAILY_DIGEST_LLM_SUMMARY DAILY_DIGEST_LLM_MAX_USD \
  DAILY_DIGEST_NOW DAILY_DIGEST_FIXTURE NEEDS_HUMAN_TRIP_COUNT LEAD_REVIEW_SPOTCHECK_PCT \
  LANE_GATE_DISABLE BEAT_STRICT DD_TIMED 2>/dev/null || true

D=2026-09-29
NOW=1790751900          # 2026-09-30T07:05:00Z, so D is 2026-09-29
SD="$H/state/daily-digest"
render_want() { printf 'Daily digest %s\nline two → ok\nline three' "$1"; }

# reset: a fresh world — no ledger rows, no switches, no settings rows, the
# fixture route body for day D, the console taking every beat.
reset() {
  local p
  for p in "$T/beats" "$T/alerts.log" "$T/urls" "$T/ledger.json" "$T/ledger.code" "$T/route.json" \
    "$T/route.body" "$T/route.code" "$T/beat.rc" "$T/settings.json" "$T/render.args" "$T/render.mode" \
    "$T/render.summary" "$T/summary.on" "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  : > "$REQLOG"; : > "$GATELOG"
  echo '{}' > "$T/ledger.json"; echo '[]' > "$T/settings.json"
  jq --arg d "$D" '.day = $d' "$DIR/tests/fixtures/daily-digest/fixture-day.json" > "$T/route.json"
}
# run [VAR=value ...]: one tick of the lane under the sandbox, NOW pinned.
run() {
  env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" DAILY_DIGEST_FIXTURE="$T/fx.sh" "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
n_beat() { local n; n=$(wc -l 2>/dev/null < "$T/beats"); printf '%s' "${n:-0}" | tr -d ' '; }
n_log() { local n; n=$(wc -l 2>/dev/null < "$H/logs/daily-digest.log"); printf '%s' "${n:-0}" | tr -d ' '; }
n_alert() { cnt "$1" "$T/alerts.log"; }
summary() { tail -1 "$H/logs/daily-digest.log" 2>/dev/null; }
payload() { sed -n "${1:-1}p" "$T/beats" | sed 's/^BEAT_STRICT=[^ ]* //'; }
ledger() { jq -r --arg i "daily_digest/$D" '.[$i].status // "none"' "$T/ledger.json"; }

# ── D1: one send ─────────────────────────────────────────────────────────────
reset; run
check "D1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "D1 exactly one beat ($(n_beat))" '[ "$(n_beat)" = 1 ]'
check "D1 the send went through archie-tg-send.sh, not beat.sh" '! grep -q "^BEAT_STRICT=" "$T/beats"'
check "D1 payload shape: $(payload)" \
  'payload | jq -e --arg a "daily-digest:$D" ".akey == \$a and (has(\"kind\") | not)" >/dev/null'
check "D1 .line is the render, byte for byte, signed Archie" '[ "$(payload | jq -r .line)" = "$(render_want "$D")"$'"'"'\n\nArchie'"'"' ]'
check "D1 state json equals the route body" 'cmp -s <(jq -S . "$SD/$D.json") <(jq -S . "$T/route.json")'
check "D1 state txt is the full render" '[ "$(cat "$SD/$D.txt")" = "$(render_want "$D")" ]'
check "D1 ledger daily_digest/$D is sent ($(ledger))" '[ "$(ledger)" = sent ]'
check "D1 ledger detail" \
  'jq -r --arg i "daily_digest/$D" ".[\$i].detail" "$T/ledger.json" | jq -e ".chars > 0 and .empty == false and .summary == \"none\"" >/dev/null'
check "D1 stamp exists" '[ -f "$SD/sent-$D" ]'
check "D1 summary line: $(summary)" 'summary | grep -qE "^[^ ]+ day=$D sent=1 empty=0 chars=[0-9]+ summary=none$"'
check "D1 chars counts characters, not bytes" \
  'summary | grep -q " chars=$(LC_ALL=C.UTF-8 bash -c "x=\$(cat); printf %s \${#x}" < <(render_want "$D")) "'
check "D1 route query ($(grep daily-digest "$REQLOG"))" \
  'grep -qF "GET /api/metrics/daily-digest?day=$D&loop_min=2&trip=2&human=operator&limit=20 " "$REQLOG"'
check "D1 dd_render argv: $(tr '\n' '|' < "$T/render.args")" \
  '[ "$(sed -n 2,6p "$T/render.args" | tr "\n" "|")" = "https://console.invalid|-|$(sed -n 4p "$T/render.args")|5|-|" ] && [ "$(sed -n 1p "$T/render.args")" = "$SD/$D.json" ]'
check "D1 spotcheck pct is a number" 'sed -n 4p "$T/render.args" | grep -qE "^[0-9]+$"'
check "D1 no alert" '[ ! -s "$T/alerts.log" ]'
check "N1 no telegram on a code line of the lane" '[ -s "$DIR/bin/daily-digest.sh" ] && ! grep -vE "^[[:space:]]*#" "$DIR/bin/daily-digest.sh" | grep -qi "telegram"'
check "N1 every URL is the jobs worker ($(grep -v '^https://jobs.invalid' "$T/urls" | head -3))" \
  '[ -s "$T/urls" ] && ! grep -qv "^https://jobs.invalid/" "$T/urls"'

# ── D3: dedupe ───────────────────────────────────────────────────────────────
: > "$REQLOG"; L0=$(n_log); run
check "D3a ledger sent: no second beat" '[ "$(n_beat)" = 1 ]'
check "D3a ledger sent: no new log line" '[ "$(n_log)" = "$L0" ]'
check "D3a ledger sent: no route request" '! grep -q daily-digest "$REQLOG"'
echo 503 > "$T/ledger.code"; run
check "D3b ledger 503 + stamp: no beat" '[ "$(n_beat)" = 1 ]'
check "D3b ledger 503 + stamp: summary ends dup ($(summary))" 'summary | grep -qE "sent=0 .* dup$"'
reset; echo 503 > "$T/ledger.code"; run
check "D3c ledger 503, no stamp: exactly one beat" '[ "$(n_beat)" = 1 ] && summary | grep -q " sent=1 "'
check "D3c the stamp guards the next tick" '[ -f "$SD/sent-$D" ]'
run
check "D3c second tick, ledger still down: still one beat" '[ "$(n_beat)" = 1 ]'
reset; mkdir -p "$SD"; echo '{"chars":9,"empty":false,"summary":"none"}' > "$SD/sent-$D"; run
check "D3d ledger miss + stamp: no beat" '[ "$(n_beat)" = 0 ]'
check "D3d ledger miss + stamp: the ledger catches up to sent" '[ "$(ledger)" = sent ] && grep -q "^PUT /api/ledger " "$REQLOG"'
check "D3d ledger miss + stamp: no route request" '! grep -q daily-digest "$REQLOG"'

# ── D4: switches ─────────────────────────────────────────────────────────────
reset; mkdir -p "$H/flags"; touch "$H/flags/daily-digest-off"; run
check "D4a daily-digest-off: no beat, summary off ($(summary))" '[ "$(n_beat)" = 0 ] && summary | grep -qE "^[^ ]+ day=$D sent=0 .* off$"'
check "D4a daily-digest-off: no request" '[ ! -s "$REQLOG" ]'
rm -f "$H/flags/daily-digest-off"; run
check "D4a switch removed: sends" '[ "$(n_beat)" = 1 ]'
reset; run DAILY_DIGEST_ENABLED=0
check "D4b ENABLED=0: no beat, summary disabled ($(summary))" '[ "$(n_beat)" = 0 ] && summary | grep -q " disabled$"'
run
check "D4b ENABLED unset: sends" '[ "$(n_beat)" = 1 ]'
reset; run DAILY_DIGEST_ENABLED=7
check "D4b ENABLED=7 is a note and the default" '[ "$(n_beat)" = 1 ] && grep -q "DAILY_DIGEST_ENABLED=7" "$H/logs/daily-digest.notes.log"'
reset; mkdir -p "$H/flags"; touch "$H/flags/lane-off-daily-digest"; run
check "D4c lane-off flag: no beat, no request" '[ "$(n_beat)" = 0 ] && [ ! -s "$REQLOG" ]'
rm -f "$H/flags/lane-off-daily-digest"; run
check "D4c lane-off removed: sends" '[ "$(n_beat)" = 1 ]'
reset; echo '[{"key":"switch.daily-digest-off","value":"1","actor":"operator"}]' > "$T/settings.json"; run
check "D4d settings switch row: no beat, off ($(summary))" '[ "$(n_beat)" = 0 ] && summary | grep -q " off$"'

# ── D5: the send hour ────────────────────────────────────────────────────────
reset; NOW=1790751599 run      # 06:59:59Z
check "D5a 06:59:59Z: no beat, no log line, no ledger read" \
  '[ "$(n_beat)" = 0 ] && [ "$(n_log)" = 0 ] && ! grep -q "/api/ledger" "$REQLOG"'
NOW=1790751600 run             # 07:00:00Z
check "D5b 07:00:00Z: sends" '[ "$(n_beat)" = 1 ]'
reset; echo '[{"key":"lane.daily-digest.daily_digest_send_hour_utc","value":"9","actor":"operator"}]' > "$T/settings.json"
NOW=1790758740 run             # 08:59Z
check "D5c hour row 9, 08:59Z: nothing" '[ "$(n_beat)" = 0 ] && [ "$(n_log)" = 0 ] && ! grep -q "/api/ledger" "$REQLOG"'
NOW=1790758800 run             # 09:00Z
check "D5c hour row 9, 09:00Z: sends" '[ "$(n_beat)" = 1 ]'
reset; NOW=1790751900 run DAILY_DIGEST_SEND_HOUR_UTC=24
check "D5d hour 24 is out of range: a note and the default 7" \
  '[ "$(n_beat)" = 1 ] && grep -q "DAILY_DIGEST_SEND_HOUR_UTC=24" "$H/logs/daily-digest.notes.log"'

# ── D6: read failure ─────────────────────────────────────────────────────────
for how in 503 html otherday; do
  reset
  case "$how" in
    503) echo 503 > "$T/route.code" ;;
    html) printf '<html><body>oops</body></html>' > "$T/route.body" ;;
    otherday) jq '.day = "2026-09-28"' "$T/route.json" > "$T/route.tmp" && mv "$T/route.tmp" "$T/route.json" ;;
  esac
  run
  check "D6 $how: no beat" '[ "$(n_beat)" = 0 ]'
  check "D6 $how: no ledger write" '! grep -q "^PUT /api/ledger" "$REQLOG"'
  check "D6 $how: one read alert ($(cat "$T/alerts.log" 2>/dev/null))" \
    '[ "$(n_alert "--id daily-digest-read:$D ")" = 1 ] && grep -q "^--severity warn " "$T/alerts.log"'
  check "D6 $how: summary read-failed ($(summary))" 'summary | grep -q " read-failed$"'
  check "D6 $how: no state json" '[ ! -f "$SD/$D.json" ]'
  run
  check "D6 $how: second tick, no second alert, no beat" '[ "$(n_alert "daily-digest-read")" = 1 ] && [ "$(n_beat)" = 0 ]'
  rm -f "$T/route.code" "$T/route.body"; jq --arg d "$D" '.day = $d' "$T/route.json" > "$T/route.tmp" && mv "$T/route.tmp" "$T/route.json"
  run
  check "D6 $how: the route back sends" '[ "$(n_beat)" = 1 ] && [ "$(ledger)" = sent ]'
done

# ── D7: send failure ─────────────────────────────────────────────────────────
reset; echo 1 > "$T/beat.rc"; run
check "D7 tick 1: ledger send-failed ($(ledger))" '[ "$(ledger)" = send-failed ]'
check "D7 tick 1: attempts 1, no stamp" '[ "$(cat "$SD/attempts-$D" 2>/dev/null)" = 1 ] && [ ! -f "$SD/sent-$D" ]'
check "D7 tick 1: summary send-failed ($(summary))" 'summary | grep -qE "sent=0 .* send-failed$"'
check "D7 tick 1: no alert yet" '[ ! -s "$T/alerts.log" ]'
run
check "D7 tick 2 retries" '[ "$(n_beat)" = 2 ] && [ ! -s "$T/alerts.log" ]'
run
check "D7 tick 3: one send alert" '[ "$(n_beat)" = 3 ] && [ "$(n_alert "--id daily-digest-send:$D ")" = 1 ]'
: > "$REQLOG"; run
check "D7 tick 4: no fourth attempt, no new alert, no route request" \
  '[ "$(n_beat)" = 3 ] && [ "$(n_alert daily-digest-send)" = 1 ] && ! grep -q daily-digest "$REQLOG"'
reset; echo 2 > "$T/beat.rc"; run
check "D7 beat rc 2 (no console) is a failure" '[ "$(ledger)" = send-failed ] && [ ! -f "$SD/sent-$D" ] && summary | grep -q " send-failed$"'

# ── D8: render failure ───────────────────────────────────────────────────────
reset; echo fail > "$T/render.mode"; run
check "D8 a renderer rc 3: no beat, one render alert" \
  '[ "$(n_beat)" = 0 ] && [ "$(n_alert "--id daily-digest-render:$D ")" = 1 ]'
check "D8 summary render-failed ($(summary))" 'summary | grep -q " render-failed$"'
check "D8 no ledger write, no stamp" '! grep -q "^PUT /api/ledger" "$REQLOG" && [ ! -f "$SD/sent-$D" ]'
run
check "D8 next tick: no second alert" '[ "$(n_alert daily-digest-render)" = 1 ] && [ "$(n_beat)" = 0 ]'
# D8r: no render seam. The real bin/lib/daily-digest-{render,summary}.sh (BH-3707).
reset; env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" bash "$LANE" > "$T/out" 2>&1
check "D8r the real renderer: one beat, ledger sent" '[ "$(n_beat)" = 1 ] && [ "$(ledger)" = sent ] && [ -f "$SD/sent-$D" ]'
check "D8r the beat is the rendered digest" \
  'payload | jq -r .line | head -1 | grep -qx "Daily digest $D (UTC)" && payload | jq -r .line | grep -qF "Throughput: merged 2 https://console.invalid/dora?days=1"'  # determinism: ok the renderer's fixed link text is asserted; this test issues no windowed query
check "D8r the summary is off by default ($(summary))" 'summary | grep -q "summary=none$"'
reset; echo blank > "$T/render.mode"; run
check "D8b whitespace-only render: no beat, render-failed" \
  '[ "$(n_beat)" = 0 ] && [ "$(n_alert "--id daily-digest-render:$D ")" = 1 ] && summary | grep -q " render-failed$"'

# ── R3: the cut ──────────────────────────────────────────────────────────────
reset; echo long > "$T/render.mode"; run DAILY_DIGEST_TEXT_MAX_CHARS=600
FULL=$(cat "$SD/$D.txt" 2>/dev/null)
WANT=$(LC_ALL=C.UTF-8 bash -c 'x=$(cat); printf "%s" "${x:0:600}"' <<<"$FULL")
check "R3 the full render is longer than 600 characters" '[ "$(LC_ALL=C.UTF-8 bash -c "x=\$(cat); printf %s \${#x}" <<<"$FULL")" -gt 1000 ]'
check "R3 .line is 600 characters plus the cut note" \
  '[ "$(payload | jq -r .line)" = "$WANT"$'"'"'\n'"'"'"(cut; full digest in state/daily-digest/$D.txt on the hub)"$'"'"'\n\nArchie'"'"' ]'
check "R3 the txt holds the whole render" 'grep -q "^item 30 → " "$SD/$D.txt"'
reset; echo long > "$T/render.mode"; run DAILY_DIGEST_TEXT_MAX_CHARS=499
check "R3 499 is out of range: a note and the default 3500, no cut" \
  'grep -q "DAILY_DIGEST_TEXT_MAX_CHARS=499" "$H/logs/daily-digest.notes.log" && ! payload | jq -r .line | grep -q "(cut;"'

# ── S1: the NOW seam is honoured only under the sandbox ──────────────────────
reset; env -u HARNESS_TEST_SANDBOX DAILY_DIGEST_NOW=1577880000 DAILY_DIGEST_SEND_HOUR_UTC=0 bash "$LANE" > "$T/out" 2>&1
check "S1 without the sandbox the pinned day 2019-12-31 is ignored ($(summary))" \
  'summary | grep -qE " day=[0-9]{4}-[0-9]{2}-[0-9]{2} " && ! summary | grep -q "day=2019-12-31" && grep -q "daily-digest?day=" "$REQLOG" && ! grep -q "day=2019-12-31" "$REQLOG"'
check "S1 without the sandbox the fixture is not sourced (the stub renders)" '[ ! -f "$T/render.args" ]'

# ── S2: a summary paragraph is passed on ─────────────────────────────────────
reset; touch "$T/summary.on"; run
check "S2 dd_render got the summary file" '[ "$(sed -n 6p "$T/render.args")" != - ] && [ "$(cat "$T/render.summary")" = "A quiet day." ]'
check "S2 summary=new ($(summary))" 'summary | grep -q " sent=1 .* summary=new$"'

# ── T1: the trip count comes from the needs-human lib row ────────────────────
reset; echo '[{"key":"lib.needs-human.needs_human_trip_count","value":"3","actor":"operator"}]' > "$T/settings.json"; run
check "T1 trip=3 ($(grep daily-digest "$REQLOG"))" 'grep -q "daily-digest?day=$D&loop_min=2&trip=3&" "$REQLOG"'
reset; run DAILY_DIGEST_HUMAN_ACTORS="operator,ops team" DAILY_DIGEST_REBUILD_LOOP_MIN=4
check "T1 human is URI-encoded, loop_min passed" 'grep -qF "loop_min=4&trip=2&human=operator%2Cops%20team&limit=20 " "$REQLOG"'

# ── L1: a held lock skips the tick ───────────────────────────────────────────
reset; mkdir -p "$H/locks"
exec 8>"$H/locks/daily-digest.lock"; flock -n 8
run
exec 8>&-
check "L1 held lock: no beat, no request" '[ "$(n_beat)" = 0 ] && [ ! -s "$REQLOG" ]'
run
check "L1 lock released: sends" '[ "$(n_beat)" = 1 ]'

# ── P1: prune by the date in the name ────────────────────────────────────────
reset; mkdir -p "$SD"
touch "$SD/2026-08-01.json" "$SD/sent-2026-08-01" "$SD/attempts-2026-08-01" "$SD/alerted-read-2026-08-01" "$SD/2026-09-15.txt"
run
check "P1 older than 30 days: gone" '[ ! -e "$SD/2026-08-01.json" ] && [ ! -e "$SD/sent-2026-08-01" ] && [ ! -e "$SD/attempts-2026-08-01" ] && [ ! -e "$SD/alerted-read-2026-08-01" ]'
check "P1 inside 30 days: kept" '[ -e "$SD/2026-09-15.txt" ] && [ -e "$SD/$D.txt" ]'

# ── Empty day ────────────────────────────────────────────────────────────────
reset; jq --arg d "$D" '.day = $d' "$DIR/tests/fixtures/daily-digest/empty-day.json" > "$T/route.json"; run
check "empty day: sent, empty=1 ($(summary))" 'summary | grep -q " sent=1 empty=1 " && jq -r --arg i "daily_digest/$D" ".[\$i].detail" "$T/ledger.json" | jq -e ".empty == true" >/dev/null'

# ── Mutations (D1): each removed behavior turns its case red ────────────────
mutate() { rm -f "$LANE"; sed "$1" "$DIR/bin/daily-digest.sh" > "$LANE"; chmod +x "$LANE"; }
mutate '/# >>> dedupe/,/# <<< dedupe/c :'
check "M1 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; run; run
check "M1 no ledger/stamp dedupe: D3a sends a second beat" '[ "$(n_beat)" = 2 ]'
mutate '/lane_switch daily-digest-off/d'
check "M2 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; mkdir -p "$H/flags"; touch "$H/flags/daily-digest-off"; run
check "M2 no switch read: D4a sends" '[ "$(n_beat)" = 1 ]'
mutate '/# hour-gate/d'
check "M3 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; NOW=1790751599 run
check "M3 no hour gate: D5a sends" '[ "$(n_beat)" = 1 ]'
rm -f "$LANE"; ln -s "$DIR/bin/daily-digest.sh" "$LANE"

echo "daily-digest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
