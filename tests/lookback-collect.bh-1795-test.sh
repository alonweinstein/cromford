#!/bin/bash
# tests/lookback-collect.bh-1795-test.sh — BH-1795.1: the repeat-failure
# collector, bin/lookback-collect.sh, that bin/lookback.sh runs once a week.
#
# DRIVEN, NOT GREPPED: every case runs the real collector through `env -i … bash
# $H/bin/lookback-collect.sh` in a scratch $HARNESS ($T/h) rebuilt per case, with
# the real bin/jobs-client.sh + bin/lib/jobs/* behind a `curl` shim that answers
# /api/ledger and /api/alerts from tests/fixtures/lookback/collect/, a `gh` shim
# for the commits and pulls/files REST reads, and a stub bin/fleet-conf.sh.
# Fixture dates are templates filled from the ONE `NOW` read below.
#
#   K1  one in-window fixture per source -> exactly the seven sources, sorted
#   K2  item fields; files[] from changed-files.txt, from PR files, else []; id
#   K3  8-day-old rows/files excluded; ledger 503 -> sources.abandoned.ok=false,
#       incomplete, other items kept, rc 0.  K3b: a 200 HTML body, same.
#   K4  LOOKBACK_ALERT_MIN both sides.  K4b LOOKBACK_REREVIEW_MIN both sides.
#   K5  --since bounds the window; missing --out / bad --since / future -> rc 2
#   K6  LOOKBACK_BUNDLE_MAX_ITEMS=2 keeps the 2 newest, truncated, incomplete
#   K7  NOT RUN/BLOCKED lines, RESOLVED_MERGED/CI_SUPERSEDED records, a released
#       ledger row and a mid-line "revert" subject produce no item
#   K8  every source unreadable -> rc 1; JOBS_URL empty -> not configured, ok=false
#   K9  the real bin/lookback.sh with LOOKBACK_DRY=1 runs the real collector
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/lookback/collect"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-collect.bh-1795-test: SKIPPED — jq missing"; exit 0; }

NOW=$(date -u +%s)
iso()   { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
day()   { date -u -d "@$1" +%Y%m%d; }
IN=$((NOW - 86400)); OLD=$((NOW - 8 * 86400)); D5=$((NOW - 5 * 86400))
REG=$(HARNESS_TEST_SANDBOX=1 bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR") \
  || { echo "FAIL: could not render the lane registry"; exit 1; }
H="$T/h"
OUT="$T/bundle.json"

fill() { # fill <fixture> <dest>
  sed -e "s/@AT_IN@/$(iso "$IN")/g" -e "s/@AT_OLD@/$(iso "$OLD")/g" -e "s/@AT_NOW@/$(iso "$NOW")/g" \
      -e "s/@STAMP_IN@/$(stamp "$IN")/g" -e "s/@STAMP_OLD@/$(stamp "$OLD")/g" \
      -e "s/@DAY_IN@/$(day "$IN")/g" -e "s/@DAY_OLD@/$(day "$OLD")/g" "$FX/$1" > "$2"
}

# fresh — a new scratch harness holding the real collector and one fixture per source.
fresh() {
  scratch_rm "$H"; rm -f "$OUT" "$T/out"
  mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state/blocked-resolver/project-3" "$H/flags" "$H/env" "$H/catalog" "$T/shim" "$T/stub"
  : > "$H/env/global.env"
  cp "$DIR/bin/lookback-collect.sh" "$H/bin/" 2>/dev/null
  cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR/bin/lib/lookback-common.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$REG" "$H/catalog/lanes.json"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.lane-alert"\n' "$T" > "$H/bin/lane-alert.sh"
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in --projects) echo project-3 ;; project-3) [ "$2" = repo ] && echo example-org/project-3 ;; *) exit 1 ;; esac
SH
  chmod +x "$H/bin/"*.sh
  fill reopens.csv "$H/logs/reopens.csv"
  fill ALERTS.log "$H/logs/ALERTS.log"
  local f
  for f in parked fixrounds rereview superseded old abandoned; do
    fill "br-$f.json" "$H/state/blocked-resolver/project-3/$(jq -r .rkey "$FX/br-$f.json").json"
  done
  touch -d "@$OLD" "$H/state/blocked-resolver/project-3/project-3-project-3-7.json"
  mkdir -p "$H/builds/project-3-project-3-3-202609010000" "$H/builds/project-3-project-3-3-202609200000"
  printf 'src/old.ts\n' > "$H/builds/project-3-project-3-3-202609010000/changed-files.txt"
  printf 'src/a.ts\nsrc/b.ts\n\n' > "$H/builds/project-3-project-3-3-202609200000/changed-files.txt"
  fill ledger.json "$T/stub/ledger.json"
  fill alerts.json "$T/stub/alerts.json"
  fill commits.json "$T/stub/commits.json"
  cp "$FX/pr-42-files.json" "$FX/pr-43-files.json" "$FX/worker-503.json" "$T/stub/"
  printf '<html><body>Cloudflare: origin error</body></html>' > "$T/stub/html"
  # curl: the jobs worker. Prints body + "\n<code>" the way _jobs_req's -w asks.
  cat > "$T/shim/curl" <<SH
#!/bin/bash
url="\${!#}"
answer() { cat "\$2"; printf '\n%s' "\$1"; }
case "\$url" in
  *"/api/ledger?kind=abandoned"*)
    case "\${STUB_LEDGER:-ok}" in ok) answer 200 "$T/stub/ledger.json" ;; 503) answer 503 "$T/stub/worker-503.json" ;; html) answer 200 "$T/stub/html" ;; esac ;;
  *"/api/alerts?"*)
    case "\${STUB_ALERTS:-ok}" in ok) answer 200 "$T/stub/alerts.json" ;; 503) answer 503 "$T/stub/worker-503.json" ;; esac ;;
  *) printf '{"error":"not found"}\n404' ;;
esac
SH
  cat > "$T/shim/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.gh"
[ "\${STUB_GH:-ok}" = ok ] || { echo "gh: HTTP 502" >&2; exit 1; }
[ "\$1" = api ] || exit 1
path="\$2"; shift 2; q=""
[ "\${1:-}" = --jq ] && q="\$2"
case "\$path" in
  repos/example-org/project-3/commits\?*) f="$T/stub/commits.json" ;;
  repos/example-org/project-3/pulls/42/files*) f="$T/stub/pr-42-files.json" ;;
  repos/example-org/project-3/pulls/43/files*) f="$T/stub/pr-43-files.json" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
if [ -n "\$q" ]; then jq -r "\$q" "\$f"; else cat "\$f"; fi
SH
  chmod +x "$T/shim/curl" "$T/shim/gh"
  rm -f "$T/calls.gh" "$T/calls.lane-alert"
}

collect() { # collect [VAR=value ...] -- [collector args]; rc in $RC, bundle in $OUT
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL=http://jobs.stub HARNESS_SECRET=x \
    JOBS_RETRIES=0 LANE_GATE_NOW="$NOW" "${envs[@]}" bash "$H/bin/lookback-collect.sh" "$@" > "$T/out" 2>&1
  RC=$?
}
q() { jq -r "$1" "$OUT" 2>/dev/null; }
item() { jq -c --arg s "$1" --arg t "$2" '[.items[]|select(.source==$s and .ticket==$t)]' "$OUT" 2>/dev/null; }

# --- K1 one in-window fixture per source ---------------------------------------
fresh
collect -- --days 7 --out "$OUT"
eq "K1 rc" "$RC" 0
eq "K1 sources of the items" "$(q '.items|map(.source)|sort|join(",")')" \
  "abandoned,alert_family,fix_rounds,parked,postmerge_fail,reopen,revert"
eq "K1 incomplete" "$(q '.incomplete')" false
eq "K1 bundle keys" "$(q 'keys_unsorted|map(select(.=="window" or .=="items" or .=="sources" or .=="incomplete"))|sort|join(",")')" "incomplete,items,sources,window"
# The collector reads its own clock once; it is at or after this test's NOW.
TO_E=$(date -u -d "$(q '.window.to')" +%s 2>/dev/null || echo 0)
eq "K1 window.to is the collector's NOW" "$([ "$TO_E" -ge "$NOW" ] && [ "$TO_E" -le $((NOW + 120)) ] && echo yes || echo "no ($(q '.window.to'))")" yes
eq "K1 window.from is to - 7 days" "$(q '.window.from')" "$(iso $((TO_E - 7 * 86400)))"
eq "K1 source records" "$(q '.sources|keys|join(",")')" "abandoned,alert_family,br_records,fix_rounds,postmerge_fail,reopen,revert"
eq "K1 every source ok" "$(q '[.sources[]|.ok]|all')" true
eq "K1 reopen item" "$(item reopen project-3-1 | jq -r '.[0]|[.project,.lane,.reason,.at]|join("|")')" \
  "project-3|reopen|reopened: done -> todo|$(date -u -d "@$IN" +%Y-%m-%d)T00:00:00Z"
eq "K1 abandoned (ledger) item" "$(item abandoned project-3-8 | jq -r '.[0]|[.project,.lane,.at]|join("|")')" "project-3|blocked-resolver|$(iso "$IN")"
eq "K1 abandoned counted once (ledger + br file)" "$(item abandoned project-3-8 | jq length)" 1
eq "K1 parked item" "$(item parked project-3-2 | jq -r '.[0]|[.pr,.reason]|join("|")')" "https://github.com/example-org/project-3/pull/42|ci repair rounds exhausted"
eq "K1 fix_rounds item" "$(item fix_rounds project-3-3 | jq -r '.[0].reason')" "2 fix rounds, 0 re-reviews"
eq "K1 a record with no PR url keeps pr empty" "$(item fix_rounds project-3-3 | jq -r '.[0].pr')" ""
eq "K1 alert_family item" "$(jq -r '.items[]|select(.source=="alert_family")|[.project,.lane,(.reason|startswith("rebase:conflict x3"))]|map(tostring)|join("|")' "$OUT")" "project-3|rebase|true"
eq "K1 postmerge_fail item" "$(item postmerge_fail project-3-12 | jq -r '.[0]|[.pr,.lane,.reason]|join("|")')" \
  "https://github.com/example-org/project-3/pull/43|postmerge-qa|FAIL: the invoices table renders empty for a client with invoices"
eq "K1 revert item" "$(jq -r '.items[]|select(.source=="revert")|[.project,.lane,.reason]|join("|")' "$OUT")" \
  'project-3|revert|Revert "feat(project-3-3): invoice table"'
eq "K1 sorted by (source, project, ticket)" "$(q '.items == (.items|sort_by([.source,.project,.ticket]))')" true

# --- K2 item fields, files[], id -----------------------------------------------
eq "K2 field types" "$(q '[.items[]|(.project|type)=="string" and (.files|type)=="array" and (.lane|length)>0 and (.reason|length)>0 and (.at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))]|all')" true
eq "K2 ticket or pr on every ticket-bearing item" "$(q '[.items[]|select(.source!="alert_family" and .source!="revert")|((.ticket|length)>0 or (.pr|length)>0)]|all')" true
eq "K2 build dir files (newest build)" "$(item fix_rounds project-3-3 | jq -c '.[0].files')" '["src/a.ts","src/b.ts"]'
eq "K2 PR files from GitHub" "$(item parked project-3-2 | jq -c '.[0].files')" '["src/p.ts"]'
eq "K2 PR files for the postmerge item" "$(item postmerge_fail project-3-12 | jq -c '.[0].files')" '["src/q.ts","src/r.ts"]'
eq "K2 revert has no files" "$(jq -c '.items[]|select(.source=="revert")|.files' "$OUT")" '[]'
eq "K2 ledger item without pr or build has no files" "$(item abandoned project-3-8 | jq -c '.[0].files')" '[]'
ids_ok=true
while IFS= read -r id && IFS= read -r joined; do
  [ "$id" = "$(printf '%s' "$joined" | sha1sum | cut -c1-12)" ] || { ids_ok=false; echo "  id mismatch for $joined"; }
done < <(jq -r '.items[]|.id, ([.source,.project,.ticket,.pr,.reason]|join("|"))' "$OUT")
eq "K2 id = sha1(source|project|ticket|pr|reason)[:12]" "$ids_ok" true
eq "K2 ids unique" "$(q '[.items[].id]|(unique|length)==length')" true

# --- K3 window and a ledger outage ---------------------------------------------
eq "K3 8-day-old reopen excluded" "$(item reopen project-3-9)" '[]'
eq "K3 8-day-old br file excluded (fixrounds 5)" "$(q '[.items[]|select(.ticket=="project-3-7")]|length')" 0
eq "K3 8-day-old ledger row excluded" "$(q '[.items[]|select(.ticket=="project-3-11")]|length')" 0
eq "K3 8-day-old FAILED line excluded" "$(q '[.items[]|select(.ticket=="project-3-15")]|length')" 0
fresh
collect STUB_LEDGER=503 -- --days 7 --out "$OUT"
eq "K3 ledger 503 rc" "$RC" 0
eq "K3 ledger 503 -> abandoned not ok" "$(q '.sources.abandoned.ok')" false
has "K3 ledger 503 error names the status" "$(q '.sources.abandoned.error')" "503"
eq "K3 ledger 503 -> incomplete" "$(q '.incomplete')" true
eq "K3 other sources still carry items" "$(q '[.items[].source]|(index("reopen")!=null) and (index("alert_family")!=null)')" true
fresh
collect STUB_LEDGER=html -- --days 7 --out "$OUT"
eq "K3b ledger 200 HTML rc" "$RC" 0
eq "K3b ledger 200 HTML -> abandoned not ok" "$(q '.sources.abandoned.ok')" false
eq "K3b ledger 200 HTML -> incomplete" "$(q '.incomplete')" true

# --- K4 alert and re-review thresholds -----------------------------------------
fresh
collect LOOKBACK_ALERT_MIN=3 -- --days 7 --out "$OUT"
eq "K4 ALERT_MIN=3: family at 3 present" "$(q '[.items[]|select(.source=="alert_family")|.reason|split(" ")[0]]|join(",")')" "rebase:conflict"
collect LOOKBACK_ALERT_MIN=2 -- --days 7 --out "$OUT"
eq "K4 ALERT_MIN=2: family at 2 present too" "$(q '[.items[]|select(.source=="alert_family")|.reason|split(" ")[0]]|sort|join(",")')" "deploy:slow,rebase:conflict"
collect LOOKBACK_ALERT_MIN=4 -- --days 7 --out "$OUT"
eq "K4 ALERT_MIN=4: nothing" "$(q '[.items[]|select(.source=="alert_family")]|length')" 0
eq "K4b REREVIEW_MIN default: rereviews 1 is not a repeat" "$(item fix_rounds project-3-4)" '[]'
collect LOOKBACK_REREVIEW_MIN=1 -- --days 7 --out "$OUT"
eq "K4b REREVIEW_MIN=1: rereviews 1 counts" "$(item fix_rounds project-3-4 | jq -r '.[0].reason')" "0 fix rounds, 1 re-reviews"
collect LOOKBACK_REREVIEW_MIN=2 -- --days 7 --out "$OUT"
eq "K4b REREVIEW_MIN=2: rereviews 1 does not" "$(item fix_rounds project-3-4)" '[]'
eq "K4b fixrounds 1 alone is not a repeat" "$(item fix_rounds project-3-2)" '[]'

# --- K5 --since and usage -------------------------------------------------------
fresh
printf '%s,project-3,project-3-5,done,review\n' "$(day "$D5")" >> "$H/logs/reopens.csv"
collect -- --days 7 --out "$OUT"
eq "K5 --days 7 includes a 5-day-old reopen" "$(item reopen project-3-5 | jq length)" 1
collect -- --since "$(iso $((NOW - 3 * 86400)))" --out "$OUT"
eq "K5 --since rc" "$RC" 0
eq "K5 --since 3 days ago excludes it" "$(item reopen project-3-5)" '[]'
eq "K5 --since is the window's from" "$(q '.window.from')" "$(iso $((NOW - 3 * 86400)))"
rm -f "$OUT"
collect -- --days 7
eq "K5 no --out -> rc 2" "$RC" 2
collect -- --since "not a date" --out "$OUT"
eq "K5 bad --since -> rc 2" "$RC" 2
collect -- --since "$(iso $((NOW + 86400)))" --out "$OUT"
eq "K5 future --since -> rc 2" "$RC" 2
collect -- --days x --out "$OUT"
eq "K5 non-integer --days -> rc 2" "$RC" 2
eq "K5 no bundle written on a usage error" "$([ -e "$OUT" ] && echo yes || echo no)" no

# --- K6 the item cap ------------------------------------------------------------
fresh
collect -- --days 7 --out "$OUT"
NEWEST=$(jq -r '.items|sort_by(.at)|reverse|.[:2]|map(.id)|sort|join(",")' "$OUT")
collect LOOKBACK_BUNDLE_MAX_ITEMS=2 -- --days 7 --out "$OUT"
eq "K6 rc" "$RC" 0
eq "K6 two items kept" "$(q '.items|length')" 2
eq "K6 the newest two" "$(q '.items|map(.id)|sort|join(",")')" "$NEWEST"
eq "K6 truncated" "$(q '.truncated')" true
eq "K6 incomplete" "$(q '.incomplete')" true
eq "K6 still sorted" "$(q '.items == (.items|sort_by([.source,.project,.ticket]))')" true
collect LOOKBACK_BUNDLE_MAX_ITEMS=400 -- --days 7 --out "$OUT"
eq "K6 under the cap: not truncated" "$(q '.truncated')" false

# --- K7 things that are not repeat failures -------------------------------------
collect -- --days 7 --out "$OUT"
for t in project-3-13 project-3-14 project-3-6 project-3-10; do
  eq "K7 no item for $t" "$(q "[.items[]|select(.ticket==\"$t\")]|length")" 0
done
eq "K7 fix_rounds only for project-3-3" "$(q '[.items[]|select(.source=="fix_rounds")|.ticket]|join(",")')" "project-3-3"
eq "K7 one revert (mid-line revert ignored)" "$(q '[.items[]|select(.source=="revert")]|length')" 1

# --- K8 nothing readable --------------------------------------------------------
fresh
rm -f "$H/logs/reopens.csv" "$H/logs/ALERTS.log"; mkdir "$H/logs/reopens.csv" "$H/logs/ALERTS.log"
scratch_rm "$H/state/blocked-resolver"; : > "$H/state/blocked-resolver"
collect STUB_LEDGER=503 STUB_ALERTS=503 STUB_GH=fail -- --days 7 --out "$OUT"
eq "K8 every source unreadable -> rc 1" "$RC" 1
eq "K8 no source ok" "$(q '[.sources[]|.ok]|any')" false
fresh
collect JOBS_URL= -- --days 7 --out "$OUT"
eq "K8 JOBS_URL empty -> rc 0 (local sources read)" "$RC" 0
eq "K8 JOBS_URL empty -> abandoned not ok" "$(q '.sources.abandoned.ok')" false
eq "K8 JOBS_URL empty -> alert_family not ok" "$(q '.sources.alert_family.ok')" false
has "K8 JOBS_URL empty -> says not configured" "$(q '.sources.alert_family.error')" "not configured"
fresh
collect STUB_GH=fail -- --days 7 --out "$OUT"
eq "K8 gh failing -> revert not ok" "$(q '.sources.revert.ok')" false
has "K8 gh failing names the repo" "$(q '.sources.revert.error')" "example-org/project-3"
eq "K8 gh failing -> PR files are [], not a guess" "$(item parked project-3-2 | jq -c '.[0].files')" '[]'
fresh
scratch_rm "$H/state/blocked-resolver"; rm -f "$H/logs/reopens.csv" "$H/logs/ALERTS.log"
collect -- --days 7 --out "$OUT"
eq "K8 absent local files are an empty read, not a failure" "$(q '[.sources.reopen.ok,.sources.br_records.ok,.sources.postmerge_fail.ok]|all')" true

# --- K9 the production entry point ----------------------------------------------
fresh
env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL=http://jobs.stub HARNESS_SECRET=x JOBS_RETRIES=0 \
  LANE_GATE_NOW="$NOW" LOOKBACK_DRY=1 bash "$H/bin/lookback.sh" > "$T/out" 2>&1
RC=$?
eq "K9 lookback.sh rc" "$RC" 0
has "K9 inventory printed" "$(cat "$T/out")" "LOOKBACK_DRY=1 — 7 item(s)"
has "K9 per-source line" "$(cat "$T/out")" "reopen ok=true n=1 truncated=false"
eq "K9 no collector alert" "$(grep -c 'lookback: collector' "$H/logs/ALERTS.log" 2>/dev/null || true)" 0

echo "lookback-collect.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
