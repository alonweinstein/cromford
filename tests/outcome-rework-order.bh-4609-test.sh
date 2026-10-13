#!/bin/bash
# tests/outcome-rework-order.bh-4609-test.sh — BH-4609: the rework scan reads
# the repos an active initiative measures FIRST, so a fetch cap reached partway
# never starves them behind other repos.
#
# bin/outcome-metrics.sh reads GET /api/initiatives?status=active, takes each
# metric_query `csv:logs/outcome-rework-rollup.csv#<col>@project=<p>`, and hands
# the projects to rework_scan (bin/lib/outcome-rework.sh) as its 14th argument;
# rework_scan moves those repos to the front of repos.tsv.
#
#   O1  REWORK_FETCH_CAP = harness's own PR count: every harness files read
#       precedes any alpha/beta read; harness complete, alpha not; the rollup
#       has harness rows
#   O2  the initiatives read fails (503): fleet order, one log line
#   O3  the summary line carries rework_first=harness, or - with none
#   O4  rework_scan with 13 arguments keeps fleet order; a junk token in the
#       14th is dropped
#   O5  read-only: the gh sink holds no write
#
# NO LIVE CALLS: curl and gh are the stubs of tests/outcome-rework-test.sh,
# plus the initiatives route. Fixtures are invented (Acme/*, HX-nn).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/outcome-rework-order.bh-4609-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid JOBS_RETRIES=0
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
BASE="$T"
STUB="$BASE/stub"; mkdir -p "$STUB"
export PATH="$STUB:$PATH"
printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"; chmod +x "$STUB/flock"

# ── curl stub: the worker. The ledger route as in outcome-rework-test.sh, and
# the initiatives route answering $FIX/initiatives.json ($FIX/initiatives.code).
cat > "$STUB/curl" <<'SH'
#!/bin/bash
URL="${!#}"
body='{}'; code=404
case "$URL" in
  */api/ledger\?kind=merge*)
    M=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    body='{"ledgers":[{"key":"https://github.com/Acme/ledger-only/pull/1","status":"merged","job_id":"b-1","updated_at":"'"$M"'"}]}'; code=200 ;;
  */api/initiatives\?status=active*)
    printf '%s\n' "$URL" >> "$FIX/initiatives.reads"
    body=$(cat "$FIX/initiatives.json" 2>/dev/null || echo '{"initiatives":[]}')
    code=$(cat "$FIX/initiatives.code" 2>/dev/null || echo 200) ;;
esac
printf '%s\n%s\n' "$body" "$code"
SH
chmod +x "$STUB/curl"

# ── gh stub: tests/outcome-rework-test.sh's, verbatim in behaviour ──────────
cat > "$STUB/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
JQ=""; A=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="$2"; shift 2 ;;
    --json)  shift 2 ;;
    --paginate) shift ;;
    -X|--method) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
    *) A+=("$1"); shift ;;
  esac
done
SUB="${A[0]:-}"; P="${A[1]:-}"
flat() { printf '%s' "$1" | tr '/' '_'; }
OUT=""
case "$SUB" in
  api)
    case "$P" in
      rate_limit) OUT='{"resources":{"core":{"remaining":5000}}}' ;;
      repos/*/pulls\?state=closed*)
        R=${P#repos/}; R=${R%%/pulls*}; PG=$(printf '%s' "$P" | grep -oE 'page=[0-9]+$' | cut -d= -f2)
        OUT=$(cat "$FIX/pulls-$(flat "$R")-$PG.json" 2>/dev/null || echo '[]') ;;
      repos/*/pulls/*/files*)
        R=${P#repos/}; R=${R%%/pulls/*}; N=${P#*/pulls/}; N=${N%%/*}
        OUT=$(cat "$FIX/prfiles-$(flat "$R")-$N.json" 2>/dev/null || echo '[]') ;;
      repos/*/commits\?since=*) OUT='[]' ;;
      *) OUT='{}' ;;
    esac ;;
  pr)
    case "${A[1]:-}" in
      view) OUT='{"mergeCommit":{"oid":""}}' ;;
      *) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
    esac ;;
  *) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
esac
[ -z "$OUT" ] && exit 1
if [ -n "$JQ" ]; then printf '%s' "$OUT" | jq -r "$JQ"; else printf '%s' "$OUT"; fi
SH
chmod +x "$STUB/gh"

# A0 = Tuesday 12:00Z four ISO weeks back: a closed week inside the backfill.
NOW=$(date -u +%s)
D=$((NOW - 28*86400)); DOW=$(date -u -d "@$D" +%u)
MON=$(( (D/86400 - (DOW-1)) * 86400 ))
A0=$((MON + 86400 + 43200))
DAY=86400

newroot() { # newroot <name> -> sets R; three fleet repos, harness LAST
  R="$BASE/$1"
  mkdir -p "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fix"
  echo "HARNESS_SECRET=test-secret" > "$R/env/global.env"
  cat > "$R/fleet.conf" <<'CONF'
alpha-os  Acme/alpha-os   https://os.alpha.example  /api/board  2 box-alpha
beta-os   Acme/beta-os    https://os.beta.example   /api/board  4 box-beta
harness   Acme/harness    https://os.harness.example /api/board 6 box-harness
CONF
  : > "$R/list.tsv"; : > "$R/gh.log"
}
lpr() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -u -d "@$3" +%Y-%m-%dT%H:%M:%SZ)" "$4" "${5:-main}" >> "$R/list.tsv"; }
lfiles() {
  local repo="$1" n="$2"; shift 2
  printf '%s\n' "$@" | jq -R . | jq -s '[.[] | {filename: .}]' > "$R/fix/prfiles-$(printf '%s' "$repo" | tr '/' '_')-$n.json"
}
mkpages() {
  python3 - "$R/list.tsv" "$R/fix" <<'PY'
import json, sys, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    repo, n, merged, title, base = line.rstrip("\n").split("\t")
    rows[repo].append({"number": int(n), "merged_at": merged, "updated_at": merged,
                       "title": title, "base": {"ref": base, "repo": {"default_branch": "main"}}})
for repo, prs in rows.items():
    prs.sort(key=lambda p: p["updated_at"], reverse=True)
    json.dump(prs, open("%s/pulls-%s-1.json" % (sys.argv[2], repo.replace("/", "_")), "w"))
PY
}
fixture() { # the three repos' merged PRs: alpha 2, beta 2, harness 3
  lpr Acme/alpha-os 11 "$A0" "AX-11: a"; lpr Acme/alpha-os 12 "$((A0 + DAY))" "AX-12: b"
  lfiles Acme/alpha-os 11 src/a.ts; lfiles Acme/alpha-os 12 src/a.ts
  lpr Acme/beta-os 21 "$A0" "BX-21: a"; lpr Acme/beta-os 22 "$((A0 + DAY))" "BX-22: b"
  lfiles Acme/beta-os 21 src/b.ts; lfiles Acme/beta-os 22 src/b.ts
  lpr Acme/harness 31 "$A0" "HX-31: a"; lpr Acme/harness 32 "$((A0 + DAY))" "HX-32: b"
  lpr Acme/harness 33 "$((A0 + 2*DAY))" "HX-33: c"
  lfiles Acme/harness 31 bin/x.sh bin/y.sh; lfiles Acme/harness 32 bin/x.sh; lfiles Acme/harness 33 bin/z.sh
  mkpages
}
initiatives() { # initiatives <metric_query>...
  jq -nc '{initiatives: [$ARGS.positional | to_entries[] | {id: (.key + 1), status: "active", metric_query: .value}], truncated: false}' \
    --args "$@" > "$R/fix/initiatives.json"
}
run() {
  env HARNESS="$R" FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" "$@" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
}
# first_line <pattern>: the gh.log line number of the first match (0 = none)
first_line() { local l; l=$(grep -n -m1 -E "$1" "$R/gh.log" | cut -d: -f1); printf '%s' "${l:-0}"; }
last_line()  { local l; l=$(grep -n -E "$1" "$R/gh.log" | tail -1 | cut -d: -f1); printf '%s' "${l:-0}"; }
summary() { grep ' scanned=' "$R/logs/outcome-metrics.log" | tail -1; }
MQ='csv:logs/outcome-rework-rollup.csv#decomposed_rate@project=harness'

# ── O1: the cap reached partway, harness first ──────────────────────────────
newroot o1; fixture
initiatives "$MQ" 'csv:logs/other.csv#x' "$MQ"
run REWORK_FETCH_CAP=3; RC=$?
[ "$RC" = 0 ] && ok || bad "O1 lane exited $RC"
HL=$(last_line 'repos/Acme/harness/pulls/[0-9]+/files')
OF=$(first_line 'repos/Acme/(alpha|beta)-os/pulls/[0-9]+/files')
[ "$(grep -cE 'repos/Acme/harness/pulls/[0-9]+/files' "$R/gh.log")" = 3 ] && ok \
  || bad "O1 want all 3 harness files reads, got $(grep -cE 'repos/Acme/harness/pulls/[0-9]+/files' "$R/gh.log")"
[ "$HL" -gt 0 ] && { [ "$OF" = 0 ] || [ "$HL" -lt "$OF" ]; } && ok \
  || bad "O1 a harness files read came after an alpha/beta read (last harness line $HL, first other $OF): $(grep files "$R/gh.log")"
grep -q 'rework: Acme/harness product-file reads incomplete' "$R/logs/outcome-metrics.log" \
  && bad "O1 harness was left incomplete" || ok
grep -q 'rework: Acme/alpha-os product-file reads incomplete' "$R/logs/outcome-metrics.log" \
  && ok || bad "O1 alpha should be the incomplete repo: $(grep rework "$R/logs/outcome-metrics.log")"
grep -q ',harness,' "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && ok \
  || bad "O1 the rollup has no harness rows: $(cat "$R/logs/outcome-rework-rollup.csv" 2>/dev/null)"
grep -q 'status=active' "$R/fix/initiatives.reads" 2>/dev/null && ok || bad "O1 the lane never read the active initiatives"
# ── O3: the summary names the order (deduped) ───────────────────────────────
summary | grep -qE ' rework_first=harness( |$)' && ok || bad "O3 summary lacks rework_first=harness: $(summary)"
# ── O5: read-only ───────────────────────────────────────────────────────────
[ ! -s "$R/gh.log.writes" ] && ok || bad "O5 a gh write: $(cat "$R/gh.log.writes")"

# ── O2: the initiatives read fails -> fleet order, one log line ─────────────
newroot o2; fixture
initiatives "$MQ"; echo 503 > "$R/fix/initiatives.code"
run REWORK_FETCH_CAP=3
[ "$(grep -c 'rework: initiatives unreadable; fleet order' "$R/logs/outcome-metrics.log")" = 1 ] && ok \
  || bad "O2 want one 'initiatives unreadable' line: $(grep rework "$R/logs/outcome-metrics.log")"
[ "$(first_line 'repos/Acme/alpha-os/pulls/[0-9]+/files')" -gt 0 ] && [ "$(first_line 'repos/Acme/harness/pulls/[0-9]+/files')" = 0 ] && ok \
  || bad "O2 fleet order: alpha first, harness starved by the cap: $(grep files "$R/gh.log")"
summary | grep -qE ' rework_first=-( |$)' && ok || bad "O2 summary lacks rework_first=-: $(summary)"
[ ! -s "$R/gh.log.writes" ] && ok || bad "O5 a gh write (O2)"
# ── O3: no initiative -> rework_first=- ─────────────────────────────────────
newroot o3; fixture; initiatives
run REWORK_FETCH_CAP=3
summary | grep -qE ' rework_first=-( |$)' && ok || bad "O3 no initiative: summary lacks rework_first=-: $(summary)"

# ── O4: rework_scan, the lib directly ───────────────────────────────────────
newroot o4; fixture
# shellcheck source=../bin/lib/outcome-rework.sh
. "$DIR/bin/lib/outcome-rework.sh" || { echo "FAIL: cannot source bin/lib/outcome-rework.sh"; exit 1; }
scan() { # scan <work> [first]: rework_scan with 13 args, or 14
  mkdir -p "$1"
  if [ $# -ge 2 ]; then
    FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" HARNESS="$R" rework_scan "$R/cand" "$1" "$1/cache" "$1/roll.csv" 60 7 30 0 0 "$DIR/bin" 1 "$R/o4.log" test "$2"
  else
    FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" HARNESS="$R" rework_scan "$R/cand" "$1" "$1/cache" "$1/roll.csv" 60 7 30 0 0 "$DIR/bin" 1 "$R/o4.log" test
  fi
  cut -f2 "$1/rework/repos.tsv" | tr '\n' ' '
}
eq() { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
eq "O4 13 arguments: fleet order" "$(scan "$R/w13")" "alpha-os beta-os harness "
eq "O4 empty 14th: fleet order" "$(scan "$R/w14e" "")" "alpha-os beta-os harness "
eq "O4 harness first" "$(scan "$R/w14" "harness")" "harness alpha-os beta-os "
eq "O4 list order, then fleet order" "$(scan "$R/w14b" "harness beta-os")" "harness beta-os alpha-os "
eq "O4 an unknown project is ignored" "$(scan "$R/w14u" "nope harness")" "harness alpha-os beta-os "
eq "O4 a junk token is dropped" "$(scan "$R/w14j" "a b;rm beta-os")" "beta-os alpha-os harness "
[ ! -s "$R/gh.log.writes" ] && ok || bad "O5 a gh write (O4)"

echo "outcome-rework-order: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
