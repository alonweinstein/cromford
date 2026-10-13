#!/bin/bash
# tests/stuck-work-memo.bh-5943-test.sh — BH-5943 (BH-5938.3): stuck-work stops
# re-reading what cannot change. Two local memos, both fail open to the ledger:
#   state/stuck-work/seen/<sha1(key)>  the sw_first_seen anchor (one epoch line)
#   state/stuck-work/led/<sha1(key)>   this lane's own stuck_work row
#                                      ({"status":…,"detail":"<JSON string>"})
# and one profile line per run in logs/stuck-work-profile.log.
#
#   AT-3a two swf_pr_facts passes over 3 PRs: pass 2 makes 0 stuck_work_seen
#         GETs and field 22 is the same in both passes
#   AT-3b a failed ledger GET is `?` and writes no memo; the next pass reads and
#         writes it; a junk memo is ignored and replaced
#   AT-3c the shipped lane: tick 1 pages (1 PUT), tick 2 makes 0 stuck_work GETs
#         and 0 pages
#   AT-3d 4 x SLA: one repage from the mirror alone, paged_at kept; later 0 GETs
#   AT-3e memo off with no explicit HARNESS under the sandbox (S7's inputs); a
#         corrupt or empty-status mirror falls back to the GET; GET rc 1 and a
#         failed PUT write no mirror
#   AT-3f one profile line per run; led_hit >= 1 on tick 2; the summary line
#         keeps L1's shape
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-memo.bh-5943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "stuck-work-memo: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SEEN_SRC="$DIR/bin/lib/stuck-work/seen.sh"
LANE_SRC="$DIR/bin/stuck-work.sh"
FX="$DIR/tests/fixtures/stuck-work"
for f in "$SEEN_SRC" "$LANE_SRC" "$DIR/bin/lib/stuck-work/facts-pr.sh" "$FX/scenario-ready-8m.txt"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work-memo: 0 passed, 1 failed"; exit 1; }
done

NOW=1700009999
T0=1700000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
nfiles() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ═════ AT-3a / AT-3b: sw_first_seen through the real swf_pr_facts ═══════════
mkdir -p "$T/shim"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "stuck-work-memo: 0 passed, 1 failed"; exit 1; }
printf '#!/bin/bash\nexit 1\n' > "$T/shim/gh"; chmod +x "$T/shim/gh"
cat > "$T/prelude.sh" <<EOF
. "$DIR/bin/lib/gh-rest.sh"
. "$DIR/bin/lib/gh-rest-list.sh"
. "$DIR/bin/lib/verdicts.sh"
. "$DIR/bin/lib/jobs/jobs.sh"
. "$DIR/bin/lib/jobs/dequeue-watch.sh"
. "$DIR/bin/lib/stuck-work/seen.sh"
eval "\$(sed -n '/^vs_context()/p' "$DIR/bin/lib/verdict-status.sh")"
eval "\$(sed -n '/^mc_mergify_check() {/,/^}/p;/^mc_mergify_check_live() {/,/^}/p' "$DIR/bin/lib/mc/queue.sh")"
eval "\$(sed -n '/^mc_handoff_id()/p;/^mc_resolver_claim_file()/p;/^mc_resolver_claim_get() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
. "$DIR/bin/lib/stuck-work/facts-pr.sh"
EOF
cat >> "$T/prelude.sh" <<'EOF'
gh_rest() {
  local p="$2" f
  GH_REST_STATUS=200; GH_REST_REASON=
  f="$T/gh/${p//\//_}"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  case "$p" in
    */status) echo '{"state":"pending","statuses":[]}' ;;
    */check-runs) echo '{"total_count":0,"check_runs":[]}' ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
# _jobs_req: every request is logged to $T/jobs.calls; $T/ledger.down makes a
# ledger GET answer 500 (rc 1).
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" k
  printf '%s %s\n' "$m" "$p" >> "$T/jobs.calls"
  JOBS_HTTP=200; JOBS_BODY=
  case "$p" in
    /api/settings) echo '{"settings":[]}' ;;
    /api/verdicts\?*) echo '{"standing":null}' ;;
    /api/pr-state\?*) JOBS_HTTP=404; return 2 ;;
    /api/dequeue-watch/actions*) echo '{"rows":[],"truncated":false}' ;;
    /api/ledger\?*)
      [ -f "$T/ledger.down" ] && { JOBS_HTTP=500; return 1; }
      k=$(sed -n 's/.*[?&]key=\([^&]*\).*/\1/p' <<<"$p")
      if [ -f "$T/ledger/$k" ]; then cat "$T/ledger/$k"; else JOBS_HTTP=404; return 2; fi ;;
    /api/ledger)
      [ "$m" = PUT ] || return 1
      k=$(jq -r '.key|@uri' <<<"$b"); mkdir -p "$T/ledger"
      jq -c '{ledger:{status, detail}}' <<<"$b" > "$T/ledger/$k" ;;
    *) return 1 ;;
  esac
}
EOF
pass() { # pass [VAR=val...] — one swf_pr_facts o/r in a clean env, HARNESS=$T/h
  : > "$T/jobs.calls"; : > "$T/count"
  env -i PATH="$T/shim:$PATH" HOME="$T" T="$T" HARNESS="$T/h" JOBS_BOX=test HARNESS_TEST_SANDBOX=1 \
    STUCK_WORK_NOW="$NOW" MC_RESOLVER_CLAIM_DIR="$T/claims" SWF_COUNT_FILE="$T/count" PR_SNAPSHOT_TTL_S=0 \
    LANE_REGISTRY="$T/lanes.json" "$@" bash -c '. "$T/prelude.sh"; swf_pr_facts o/r > "$T/out.pr"' 2> "$T/err"
}
f22() { awk -F'\t' '{print $2 "=" $22}' "$T/out.pr" | sort | tr '\n' ' '; }
seenget() { cnt 'GET /api/ledger?kind=stuck_work_seen' "$T/jobs.calls"; }
SEEND="$T/h/state/stuck-work/seen"
mkdir -p "$T/gh" "$T/claims" "$T/h"
jq -nc --arg c "$(iso "$T0")" '[5,6,7] | map({number:., html_url:("https://github.com/o/r/pull/"+(.|tostring)),
  draft:false, created_at:$c, head:{sha:("a" + ("000000000000000000000000000000000000000" + (.|tostring))[-39:])},
  labels:[{name:"ai-build"}]})' > "$T/gh/repos_o_r_pulls"

# ── AT-3a ─────────────────────────────────────────────────────────────────
pass
P1=$(f22)
check "AT-3a pass 1 reads 3 anchors ($(seenget) GETs)" '[ "$(seenget)" = 3 ]'
check "AT-3a pass 1 field 22 is a number for each PR ($P1)" '[ "$(awk -F"\t" "\$22 ~ /^[0-9]+\$/" "$T/out.pr" | wc -l)" = 3 ]'
check "AT-3a pass 1 wrote 3 memo files ($(nfiles "$SEEND"))" '[ "$(nfiles "$SEEND")" = 3 ]'
check "AT-3a pass 1 counts 3 SEEN-MISS" '[ "$(cnt "^SEEN-MISS " "$T/count")" = 3 ]'
pass STUCK_WORK_NOW=$((NOW + 600))
P2=$(f22)
check "AT-3a pass 2 makes 0 stuck_work_seen GETs ($(seenget))" '[ "$(seenget)" = 0 ]'
check "AT-3a pass 2 field 22 is identical ($P1 / $P2)" '[ "$P1" = "$P2" ] && [ -n "$P1" ]'
check "AT-3a pass 2 counts 3 SEEN-HIT" '[ "$(cnt "^SEEN-HIT " "$T/count")" = 3 ] && [ "$(cnt "^SEEN-MISS " "$T/count")" = 0 ]'

# ── AT-3b ─────────────────────────────────────────────────────────────────
rm -rf "$T/h" "$T/ledger"; mkdir -p "$T/h"; : > "$T/ledger.down"
pass
check "AT-3b ledger down: field 22 is ? for all 3 ($(f22))" '[ "$(awk -F"\t" "\$22 == \"?\"" "$T/out.pr" | wc -l)" = 3 ]'
check "AT-3b ledger down: no memo written ($(nfiles "$SEEND"))" '[ "$(nfiles "$SEEND")" = 0 ]'
rm -f "$T/ledger.down"
pass
B1=$(f22)
check "AT-3b ledger back: 3 GETs and 3 memos" '[ "$(seenget)" = 3 ] && [ "$(nfiles "$SEEND")" = 3 ]'
for m in "$SEEND"/*; do printf 'junk\n' > "$m"; done
pass STUCK_WORK_NOW=$((NOW + 900))
check "AT-3b junk memo: the ledger is read again ($(seenget) GETs)" '[ "$(seenget)" = 3 ]'
check "AT-3b junk memo: the ledger answer is printed ($B1 / $(f22))" '[ "$(f22)" = "$B1" ]'
check "AT-3b junk memo: replaced with digits" '[ "$(cat "$SEEND"/* | grep -cxE "[0-9]+")" = 3 ]'

# ── AT-3e (seen): memo off with no explicit HARNESS under the sandbox ───────
# S7's three inputs, twice each: a memo would answer the second call.
seen_s7() { # prints "<stdout>|rc=<rc>"
  env -i PATH="$PATH" HOME="$T" HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW="$NOW" T="$T" S="$SEEN_SRC" H="$T/hh" "$@" bash -c '
    job_ledger_row() { [ -n "${ROW_OUT:-}" ] && printf "%s\n" "$ROW_OUT"; return "${ROW_RC:-2}"; }
    job_ledger_put() { printf "%s\n" "$*" >> "$T/s7puts"; return 0; }
    . "$S" || { echo source-failed; exit 0; }
    out=$(sw_first_seen "$KEY"); echo "$out|rc=$?"'
}
rm -f "$T/s7puts"
a1=$(seen_s7 KEY='o/r#12|ready' ROW_RC=2); a2=$(seen_s7 KEY='o/r#12|ready' ROW_RC=2)
check "AT-3e no HARNESS: absent row twice -> now both times, 2 PUTs ($a1 $a2)" \
  '[ "$a1" = "$NOW|rc=0" ] && [ "$a2" = "$NOW|rc=0" ] && [ "$(wc -l < "$T/s7puts")" = 2 ]'
b1=$(seen_s7 KEY='o/r#13|ready' ROW_RC=0 ROW_OUT='{"status":"seen","detail":"{\"first_seen\":1700000001}"}')
check "AT-3e no HARNESS: a present row prints its anchor ($b1)" '[ "$b1" = "1700000001|rc=0" ]'
c1=$(seen_s7 KEY='o/r#13|ready' ROW_RC=1)
check "AT-3e no HARNESS: an unreadable row is ? (no memo answered) ($c1)" '[ "$c1" = "?|rc=0" ]'
check "AT-3e no HARNESS: nothing written under \$H" '[ ! -e "$T/hh/state" ]'

# ═════ AT-3c..3f: the shipped bin/stuck-work.sh ══════════════════════════════
H="$T/lh"
mkdir -p "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/lane-alerts"\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary|-d) body="$a" ;; -w) wfmt=1 ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
printf '%s %s\n' "$m" "$path" >> "$FXT/reqs"
dec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  "GET /api/ledger"*)
    if [ -f "$FXT/get.code" ]; then code=$(cat "$FXT/get.code"); out='{"error":"down"}'
    else
      k=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
      v=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    fi ;;
  "PUT /api/ledger"*)
    if [ -f "$FXT/put.code" ]; then code=$(cat "$FXT/put.code"); out='{"error":"down"}'
    else
      printf 'PUT %s\n' "$(jq -r '"\(.kind) \(.key) \(.status)"' <<<"$body")" >> "$FXT/seq"
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"
export HARNESS="$H" FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  PATH="$T/fakebin:$PATH" FLEET_CONF="$T/fleet.conf"
printf 'cromford example-org/cromford - -\n' > "$T/fleet.conf"
unset GH_TOKEN GITHUB_TOKEN STUCK_WORK_ENABLED STUCK_WORK_MAX_ITEMS STUCK_WORK_REPAGE_FACTOR STUCK_WORK_REPO \
  STUCK_WORK_SLA_READY_MIN STUCK_WORK_NOW STUCK_WORK_FIXTURE STUCK_WORK_PROJECTS LANE_GATE_DISABLE HARNESS_ENV_DIR \
  SWF_COUNT_FILE PL_LANE PL_PROJECT PL_LOCK_FD PL_SLUG PL_STATE_DIR 2>/dev/null || true

LOG="$H/logs/stuck-work.log"
PROF="$H/logs/stuck-work-profile.log"
LED="$H/state/stuck-work/led"
E=1789999520; K="example-org/cromford#120|ready|$E"
lreset() {
  local p
  for p in "$T/seq" "$T/reqs" "$T/lane-alerts" "$T/ledger.json" "$T/get.code" "$T/put.code" \
    "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  echo '{}' > "$T/ledger.json"; : > "$T/seq"; : > "$T/reqs"
}
run() { # run <now> [VAR=value ...]: one tick of the shipped lane over scenario-ready-8m
  local now=$1; shift
  : > "$T/reqs"
  env HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW="$now" STUCK_WORK_FIXTURE="$FX/scenario-ready-8m.txt" "$@" \
    bash "$H/bin/stuck-work.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
pages() { cnt 'STUCK-WORK example-org/' "$H/logs/ALERTS.log"; }
puts() { cnt '^PUT stuck_work ' "$T/seq"; }
ledgets() { cnt '^GET /api/ledger?kind=stuck_work&' "$T/reqs"; }
row() { jq -r --arg i "stuck_work/$1" '.[$i].status // "none"' "$T/ledger.json"; }
last() { tail -n 1 "$LOG" 2>/dev/null; }
plast() { tail -n 1 "$PROF" 2>/dev/null; }
pfield() { plast | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# ── AT-3c ─────────────────────────────────────────────────────────────────
lreset; run $((E + 900))
check "AT-3c tick 1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "AT-3c tick 1: one page, one PUT, row paged ($(pages)/$(puts)/$(row "$K"))" \
  '[ "$(pages)" = 1 ] && [ "$(puts)" = 1 ] && [ "$(row "$K")" = paged ]'
check "AT-3c tick 1 wrote the mirror ($(cat "$LED"/* 2>/dev/null))" \
  '[ "$(nfiles "$LED")" = 1 ] && jq -e ".status == \"paged\" and (.detail | fromjson | .paged_at) == $((E + 900))" "$LED"/* >/dev/null'
check "AT-3f tick 1: one profile line, project=cromford, integer secs ($(plast))" \
  '[ "$(wc -l < "$PROF")" = 1 ] && [ "$(pfield project)" = cromford ] && [[ "$(pfield secs)" =~ ^[0-9]+$ ]] && [ "$(pfield led_miss)" = 1 ] && [ "$(pfield led_hit)" = 0 ]'
: > "$T/seq"
run $((E + 1200))
check "AT-3c tick 2: 0 stuck_work ledger GETs ($(ledgets): $(grep ledger "$T/reqs" | head -3))" '[ "$(ledgets)" = 0 ]'
check "AT-3c tick 2: 0 pages, 0 PUTs" '[ "$(pages)" = 1 ] && [ "$(puts)" = 0 ]'
check "AT-3f tick 2: led_hit >= 1 ($(plast))" '[ "$(pfield led_hit)" -ge 1 ] 2>/dev/null && [ "$(wc -l < "$PROF")" = 2 ]'
check "AT-3f the summary line keeps its shape ($(last))" \
  'last | grep -qxE "[0-9T:Z-]+ items=1 states=ready:1 past_sla=1 paged=0 repaged=0 incomplete=0"'

# ── AT-3d ─────────────────────────────────────────────────────────────────
run $((E + 3600))
check "AT-3d 4 x SLA: exactly one repage ($(pages))" '[ "$(pages)" = 2 ] && [ "$(row "$K")" = repaged ]'
check "AT-3d the mirror was the only source: 0 GETs ($(ledgets))" '[ "$(ledgets)" = 0 ]'
check "AT-3d paged_at kept from tick 1, repaged_at stamped" \
  'jq -r --arg i "stuck_work/$K" ".[\$i].detail" "$T/ledger.json" | jq -e ".paged_at == $((E + 900)) and .repaged_at == $((E + 3600))" >/dev/null'
check "AT-3d the mirror now says repaged" 'jq -e ".status == \"repaged\"" "$LED"/* >/dev/null'
run $((E + 4500))
check "AT-3d a later tick: 0 GETs, 0 pages ($(ledgets)/$(pages))" '[ "$(ledgets)" = 0 ] && [ "$(pages)" = 2 ]'

# ── AT-3e (led): a mirror that does not parse falls back to the GET ─────────
lreset; run $((E + 900))
for m in "$LED"/*; do printf 'not json\n' > "$m"; done
run $((E + 1200))
check "AT-3e corrupt mirror: the row is read ($(ledgets) GET)" '[ "$(ledgets)" = 1 ]'
check "AT-3e corrupt mirror: same decision, no page ($(pages))" '[ "$(pages)" = 1 ]'
check "AT-3e corrupt mirror: replaced by the GET answer" 'jq -e ".status == \"paged\"" "$LED"/* >/dev/null'
for m in "$LED"/*; do printf '{"status":"","detail":""}\n' > "$m"; done
run $((E + 1300))
check "AT-3e empty-status mirror: the row is read ($(ledgets) GET), no page" '[ "$(ledgets)" = 1 ] && [ "$(pages)" = 1 ]'
lreset; echo 500 > "$T/get.code"; run $((E + 900))
check "AT-3e GET 500: no mirror written ($(nfiles "$LED"))" '[ "$(nfiles "$LED")" = 0 ]'
lreset; echo 500 > "$T/put.code"; run $((E + 900))
check "AT-3e PUT 500: no page, no mirror ($(pages)/$(nfiles "$LED"))" '[ "$(pages)" = 0 ] && [ "$(nfiles "$LED")" = 0 ]'
rm -f "$T/put.code"; run $((E + 1200))
check "AT-3e PUT back: the next tick pages ($(pages))" '[ "$(pages)" = 1 ]'

# ── prune: memo and mirror files older than 30 days go ──────────────────────
mkdir -p "$H/state/stuck-work/seen"
printf '1700000000\n' > "$H/state/stuck-work/seen/old"
touch -d @1000000000 "$H/state/stuck-work/seen/old" "$LED"/*
run $((E + 1500))
check "prune: a memo file older than 30 days is deleted" '[ ! -e "$H/state/stuck-work/seen/old" ]'

echo "stuck-work-memo: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
