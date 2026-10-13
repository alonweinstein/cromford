#!/bin/bash
# tests/daily-digest-outcome-gap.bh-3987-test.sh — BH-4017 (BH-3987.3): the
# outcome-gap section of the daily digest.
#
# The lane cases (D1-D6) run the SHIPPED bin/daily-digest.sh from a scratch
# harness the way tests/daily-digest.bh-3706-test.sh does: bin/beat.sh and
# bin/lane-alert.sh are shims, a fake `curl` first in PATH is the jobs worker,
# and the REAL dd_render (bin/lib/daily-digest-render.sh) renders. The fake
# worker answers
#   /api/metrics/daily-digest   the fixture day in $T/route.json;
#   /api/metrics/outcome-gap    $T/gap.json (or the raw $T/gap.body) with the
#                               status in $T/gap.code;
#   /api/settings               $T/settings.json; /api/ledger keeps $T/ledger.json.
# The render cases (R1-R4, D3) source the renderer and call dd_render directly.
#
#   D1  a project-9 gap: the sent line, the state json's .outcome_gap.ok
#   D2  gap route 500 / non-object / ok:false: n/a, still sent, no alert
#   D3  no outcome_gap key: no gap line, the rest byte-identical; a 404 leaves
#       the key out of the state json with one note
#   D4  the request carries the knob values (defaults, then settings rows)
#   D5  out-of-range knobs: one warn line and the default each
#   D6  an otherwise empty day with a gap is not empty
#   R1-R4 the render's line shapes, cut and order
#   M1-M2 mutations: the lane's merge and the renderer's guard removed
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-outcome-gap.bh-3987-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest-outcome-gap: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this slice ships (D41).
for f in "$DIR/bin/daily-digest.sh" "$DIR/bin/lib/daily-digest-render.sh" "$DIR/catalog/lanes.d/daily-digest.json" \
         "$DIR/worker/jobs/src/routes/outcome-gap.js" "$DIR/worker/jobs/src/lib/outcome-gap.js" \
         "$DIR/worker/jobs/test/route-table.d/670-outcome-gap.txt" "$DIR/docs/notes/2026-10-03-BH-3987-outcome-gap.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
EMPTYFIX="$DIR/tests/fixtures/daily-digest/empty-day.json"
RENDER="$DIR/bin/lib/daily-digest-render.sh"

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
printf '%s\n' "$1" >> "$FXT/beats"
exit 0
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
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
case "$path" in /api/metrics/outcome-gap*) [ -f "$FXT/gap.down" ] && exit 7 ;; esac
case "$path" in
  /api/settings*|/api/flags*|/api/lanes*) ;;
  *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG" ;;
esac
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  *" /api/ledger"*)
    if [ "$m" = GET ]; then
      k=$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')
      v=$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    else
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET /api/metrics/daily-digest"*) out=$(cat "$FXT/route.json") ;;
  "GET /api/metrics/outcome-gap"*)
    code=$(cat "$FXT/gap.code" 2>/dev/null || echo 200)
    if [ -f "$FXT/gap.body" ]; then out=$(cat "$FXT/gap.body"); else out=$(cat "$FXT/gap.json"); fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

REQLOG="$T/reqlog"
export HARNESS="$H" FXT="$T" REQLOG \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  CONSOLE_PAGES_URL=https://console.invalid/ PATH="$T/fakebin:$PATH"
unset DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_MAX_ITEMS DAILY_DIGEST_TEXT_MAX_CHARS \
  DAILY_DIGEST_REBUILD_LOOP_MIN DAILY_DIGEST_HUMAN_ACTORS DAILY_DIGEST_LLM_SUMMARY DAILY_DIGEST_LLM_MAX_USD \
  DAILY_DIGEST_GAP_MIN_USD DAILY_DIGEST_GAP_DAYS DAILY_DIGEST_GAP_LOOKBACK_DAYS DAILY_DIGEST_GAP_STAGES \
  DAILY_DIGEST_NOW DAILY_DIGEST_FIXTURE NEEDS_HUMAN_TRIP_COUNT LEAD_REVIEW_SPOTCHECK_PCT \
  LANE_GATE_DISABLE BEAT_STRICT DD_TIMED 2>/dev/null || true

D=2026-09-29
NOW=1790751900          # 2026-09-30T07:05:00Z, so D is 2026-09-29
SD="$H/state/daily-digest"
C=https://console.invalid

# gap_fixture <n tickets> <usd each>: an answer the route emits for one project,
# tickets cut at the route's limit of 20.
gap_fixture() {
  jq -nc --arg d "$D" --argjson n "$1" --argjson u "$2" '
    [range(0; $n) | {ticket: "TK-\(. + 1)", usd: $u, unpriced_calls: 0, first_ts: "2026-09-10T00:00:00Z", last_job_id: "j-so-\(. + 1)"}] as $all
    | {ok: true, day: $d, from: "2026-08-31T00:00:00Z", to: "2026-09-30T00:00:00Z", min_usd: 5, days: 7, lookback: 30,
       stages: ["plan","preplan","preplan-files","execute","review","fix"],
       total_usd: ($n * $u), tickets_n: $n, unpriced_calls: 4,
       projects: (if $n == 0 then [] else [{project: "project-9", usd: ($n * $u), tickets_n: $n,
                  tickets: {rows: $all[:20], truncated: ($n > 20)}}] end),
       truncated: false}'
}

reset() {
  local p
  for p in "$T/beats" "$T/alerts.log" "$T/ledger.json" "$T/route.json" "$T/gap.json" "$T/gap.body" "$T/gap.code" \
    "$T/gap.down" "$T/settings.json" "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  : > "$REQLOG"
  echo '{}' > "$T/ledger.json"; echo '[]' > "$T/settings.json"
  jq --arg d "$D" '.day = $d' "$FIX" > "$T/route.json"
  # project-9: 51 tickets, $710 in all (the last one carries the odd $10).
  gap_fixture 51 13.725490196078431 | jq -c '.total_usd = 710 | .projects[0].usd = 710' > "$T/gap.json"
}
run() {
  env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n_beat() { local n; n=$(wc -l 2>/dev/null < "$T/beats"); printf '%s' "${n:-0}" | tr -d ' '; }
line() { sed -n "${1:-1}p" "$T/beats" | jq -r .line; }
summary() { tail -1 "$H/logs/daily-digest.log" 2>/dev/null; }
gapq() { grep '^GET /api/metrics/outcome-gap' "$REQLOG"; }
notes() { cat "$H/logs/daily-digest.notes.log" 2>/dev/null; }
has() { grep -qF -- "$2" <<<"$1"; }

# ── D1: the project-9 gap end to end ───────────────────────────────────────
reset; run
L=$(line)
check "D1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "D1 one beat ($(n_beat))" '[ "$(n_beat)" = 1 ]'
check "D1 the headline: $(grep -F "Outcome gap" <<<"$L" | head -1)" \
  'has "$L" "Outcome gap: \$710.00 over 51 tickets with build spend over \$5.00 and no merged harness PR 7+ days $C/costs"'
check "D1 the project line" 'has "$L" "  project-9: \$710.00 over 51 tickets $C/p/project-9"'
check "D1 a ticket line links its job" 'grep -qxF "    TK-1 \$13.73 $C/jobs/j-TK-1" <<<"$L"'
check "D1 the ticket list is cut at max-items" 'has "$L" "  +46 more (list cut at the source) $C/p/project-9"'
check "D1 state json .outcome_gap.ok is true" '[ "$(jq -r .outcome_gap.ok "$SD/$D.json")" = true ]'
check "D1 state json carries the gap verbatim" 'cmp -s <(jq -S .outcome_gap "$SD/$D.json") <(jq -S . "$T/gap.json")'
check "D1 the rest of the state json is the route body" 'cmp -s <(jq -S "del(.outcome_gap)" "$SD/$D.json") <(jq -S . "$T/route.json")'
check "D1 summary sent=1 ($(summary))" 'summary | grep -q " sent=1 empty=0 "'
check "D1 no alert" '[ ! -s "$T/alerts.log" ]'

# ── D2: a failed gap read is n/a, never a gap of 0, and never an alert ──────
for how in 500 html notok array transport; do
  reset
  case "$how" in
    500) echo 500 > "$T/gap.code"; echo '{"error":"boom"}' > "$T/gap.body" ;;
    html) printf '<html>oops</html>' > "$T/gap.body" ;;
    notok) echo '{"ok":false,"error":"x"}' > "$T/gap.body" ;;
    array) echo '[]' > "$T/gap.body" ;;
    transport) touch "$T/gap.down" ;;
  esac
  run
  L=$(line)
  check "D2 $how: one beat ($(n_beat))" '[ "$(n_beat)" = 1 ]'
  check "D2 $how: n/a line ($(grep -F "Outcome gap" <<<"$L"))" 'has "$L" "Outcome gap: n/a (read failed"'
  check "D2 $how: no gap total" '! has "$L" "Outcome gap: \$"'
  check "D2 $how: no alert ($(cat "$T/alerts.log" 2>/dev/null))" '[ ! -s "$T/alerts.log" ]'
  check "D2 $how: summary sent=1 ($(summary))" 'summary | grep -q " sent=1 "'
  check "D2 $how: state json ok:false" '[ "$(jq -r .outcome_gap.ok "$SD/$D.json")" = false ]'
done
reset; echo 500 > "$T/gap.code"; echo '{"error":"boom"}' > "$T/gap.body"; run
check "D2 500: the error names the status" '[ "$(jq -r .outcome_gap.error "$SD/$D.json")" = "read failed (http=500)" ]'
reset; touch "$T/gap.down"; run
check "D2 transport: the error says no status" '[ "$(jq -r .outcome_gap.error "$SD/$D.json")" = "read failed (http=none)" ]'

# ── D3: no key, no section ──────────────────────────────────────────────────
render() { bash -c '. "$1" || exit 9; shift; dd_render "$@"' _ "$RENDER" "$1" "https://console.test/" - 0 "${2:-5}" -; }
jq --slurpfile g "$T/gap.json" '.outcome_gap = $g[0]' "$FIX" > "$T/with.json"
jq 'del(.outcome_gap)' "$T/with.json" > "$T/without.json"
NOKEY=$(render "$FIX"); rc1=$?
WITH=$(render "$T/with.json"); rc2=$?
check "D3 both renders rc 0 ($rc1 $rc2)" '[ "$rc1" = 0 ] && [ "$rc2" = 0 ]'
check "D3 no outcome_gap key: no Outcome gap line" '! grep -q "Outcome gap" <<<"$NOKEY"'
check "D3 the key removed renders byte-identical to the fixture" '[ "$(render "$T/without.json")" = "$NOKEY" ]'
check "D3 the gap render minus its block is the fixture render" \
  '[ "$(grep -vE "^(Outcome gap: |  project-9: |    TK-|  \+[0-9]+ more .*/p/project-9$)" <<<"$WITH")" = "$NOKEY" ]'
reset; echo 404 > "$T/gap.code"; echo '{"error":"unknown endpoint","worker":"harness-jobs"}' > "$T/gap.body"; run
check "D3 gap 404: sent ($(summary))" '[ "$(n_beat)" = 1 ] && summary | grep -q " sent=1 "'
check "D3 gap 404: no outcome_gap key in the state json" '[ "$(jq "has(\"outcome_gap\")" "$SD/$D.json")" = false ]'
check "D3 gap 404: no section in the text" '! line | grep -q "Outcome gap"'
check "D3 gap 404: one note ($(notes))" '[ "$(notes | grep -c "outcome-gap")" = 1 ]'
check "D3 gap 404: no alert" '[ ! -s "$T/alerts.log" ]'

# ── D4: the knob values ride the request ────────────────────────────────────
reset; run
check "D4 defaults ($(gapq))" \
  'gapq | grep -qF "GET /api/metrics/outcome-gap?day=$D&min_usd=5&days=7&lookback=30&stages=plan,preplan,preplan-files,execute,review,fix&limit=20 "'
reset
cat > "$T/settings.json" <<'JSON'
[{"key":"lane.daily-digest.daily_digest_gap_min_usd","value":"10","actor":"operator"},
 {"key":"lane.daily-digest.daily_digest_gap_days","value":"3","actor":"operator"},
 {"key":"lane.daily-digest.daily_digest_gap_lookback_days","value":"14","actor":"operator"},
 {"key":"lane.daily-digest.daily_digest_gap_stages","value":"execute","actor":"operator"}]
JSON
run
check "D4 settings rows ($(gapq))" 'gapq | grep -qF "?day=$D&min_usd=10&days=3&lookback=14&stages=execute&limit=20 "'

# ── D5: out-of-range knobs are one warn and the default ─────────────────────
reset; run DAILY_DIGEST_GAP_DAYS=99
check "D5 days 99: one warn ($(notes))" '[ "$(notes | grep -c "warn: DAILY_DIGEST_GAP_DAYS=99")" = 1 ]'
check "D5 days 99: days=7 asked ($(gapq))" 'gapq | grep -qF "?day=$D&min_usd=5&days=7&lookback=30&"'
reset; run DAILY_DIGEST_GAP_STAGES='Bad!'
check "D5 stages Bad!: one warn ($(notes))" '[ "$(notes | grep -c "warn: DAILY_DIGEST_GAP_STAGES=Bad!")" = 1 ]'
check "D5 stages Bad!: the default list ($(gapq))" 'gapq | grep -qF "&stages=plan,preplan,preplan-files,execute,review,fix&"'
reset; run DAILY_DIGEST_GAP_LOOKBACK_DAYS=5 DAILY_DIGEST_GAP_DAYS=7
check "D5 lookback 5 <= days 7: one warn ($(notes))" '[ "$(notes | grep -c "warn: DAILY_DIGEST_GAP_LOOKBACK_DAYS=5")" = 1 ]'
check "D5 lookback 5 <= days 7: the defaults ($(gapq))" 'gapq | grep -qF "?day=$D&min_usd=5&days=7&lookback=30&"'
reset; run DAILY_DIGEST_GAP_MIN_USD=10001
check "D5 min 10001: one warn and 5 ($(gapq))" \
  '[ "$(notes | grep -c "warn: DAILY_DIGEST_GAP_MIN_USD=10001")" = 1 ] && gapq | grep -qF "&min_usd=5&"'

# ── D6: an otherwise empty day with a gap is not empty ──────────────────────
reset; jq --arg d "$D" '.day = $d' "$EMPTYFIX" > "$T/route.json"; gap_fixture 2 10 > "$T/gap.json"; run
check "D6 summary empty=0 ($(summary))" 'summary | grep -q " sent=1 empty=0 "'
check "D6 state json .empty is false" '[ "$(jq -r .empty "$SD/$D.json")" = false ]'
check "D6 no 'Nothing happened' above a gap" '! line | grep -q "Nothing happened"'
reset; jq --arg d "$D" '.day = $d' "$EMPTYFIX" > "$T/route.json"; gap_fixture 0 0 > "$T/gap.json"; run
check "D6 an empty gap keeps an empty day empty ($(summary))" 'summary | grep -q " sent=1 empty=1 " && [ "$(jq -r .empty "$SD/$D.json")" = true ]'

# ── R1-R4: the render ───────────────────────────────────────────────────────
CT=https://console.test
variant() { jq --slurpfile g <(printf '%s' "$2") '.outcome_gap = $g[0]' "$FIX" > "$T/$1.json"; printf '%s' "$T/$1.json"; }
R1=$(render "$(variant r1 "$(gap_fixture 2 20 | jq -c '.projects[0].tickets.rows[1].last_job_id = null')")")
check "R1 a ticket line links its job" 'grep -qxF "    TK-1 \$20.00 $CT/jobs/j-TK-1" <<<"$R1"'
check "R1 a null job id links the project, never /jobs/null" \
  'grep -qxF "    TK-2 \$20.00 $CT/p/project-9" <<<"$R1" && ! grep -q "/jobs/null" <<<"$R1"'
R2=$(render "$(variant r2 "$(gap_fixture 0 0)")")
check "R2 none line" 'grep -qxF "Outcome gap: none (every ticket over \$5.00 has a merged harness PR) $CT/costs" <<<"$R2"'
R3=$(render "$(variant r3 "$(gap_fixture 7 10)")" 5)
check "R3 seven tickets at max 5: five lines and +2 more" \
  '[ "$(grep -c "^    TK-" <<<"$R3")" = 5 ] && grep -qxF "  +2 more $CT/p/project-9" <<<"$R3"'
R3t=$(render "$(variant r3t "$(gap_fixture 2 10 | jq -c '.truncated = true')")")
check "R3 a route-side cut says so" 'grep -q "^Outcome gap: .* 7+ days (cut at the source) $CT/costs$" <<<"$R3t"'
R4=$(render "$(variant r4 "$(gap_fixture 2 10)")")
at() { grep -nE -- "$1" <<<"$R4" | head -1 | cut -d: -f1; }
check "R4 order: Spend, its lines, Outcome gap, Autonomy ($(at '^Spend: ') $(at '^  \$/merged PR') $(at '^Outcome gap: ') $(at '^Autonomy:'))" \
  '[ "$(at "^Spend: ")" -lt "$(at "^  \\\$/merged PR")" ] && [ "$(at "^  \\\$/merged PR")" -lt "$(at "^Outcome gap: ")" ] && [ "$(at "^Outcome gap: ")" -lt "$(at "^Autonomy:")" ]'
R4x=$(render "$(variant r4x "$(gap_fixture 2 10 | jq -c '.projects[0].project = "a<b>&c"')")")
check "R4 <>& are stripped from the project" 'grep -qF "  abc: \$20.00 over 2 tickets $CT/p/abc" <<<"$R4x"'
R5=$(render "$(variant r5 '{"ok":false,"error":"read failed (http=500)"}')")
check "R5 ok:false is n/a" 'grep -qxF "Outcome gap: n/a (read failed: read failed (http=500)) $CT/costs" <<<"$R5"'

# ── Mutations (D1) ──────────────────────────────────────────────────────────
mutate() { rm -f "$1"; sed "$2" "$3" > "$1"; }
mutate "$LANE" '/\.outcome_gap = \$g\[0\]/s/\.outcome_gap = \$g\[0\]/./' "$DIR/bin/daily-digest.sh"; chmod +x "$LANE"
check "M1 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; run
check "M1 no merge: D1's .outcome_gap.ok goes missing" '[ "$(jq -r .outcome_gap.ok "$SD/$D.json")" != true ]'
rm -f "$LANE"; ln -s "$DIR/bin/daily-digest.sh" "$LANE"
MR="$T/render-mut.sh"
sed 's/if has("outcome_gap") then/if true then/' "$RENDER" > "$MR"
check "M2 the mutation changed the renderer" '! cmp -s "$MR" "$RENDER"'
MUT=$(bash -c '. "$1" || exit 9; shift; dd_render "$@"' _ "$MR" "$FIX" "https://console.test/" - 0 5 - 2>/dev/null)
check "M2 no guard: D3's no-key render grows a gap line" 'grep -q "Outcome gap" <<<"$MUT"'

echo "daily-digest-outcome-gap: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
