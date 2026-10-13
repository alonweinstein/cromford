#!/bin/bash
# tests/outcome-rework-partial.bh-6165-test.sh — BH-6165: a repo that one run
# cannot read completely still gets rollup rows for its fully read weeks.
#
# rework_scan (bin/lib/outcome-rework.sh) used to roll up a repo only when every
# product-file list in its 60-day listing was read. example-org/cromford
# merges more PRs in 60 days than one run's fetch budget, so it never got a
# row. Completeness is now per repo and week: a closed week rolls up when the
# repo's listing succeeded and no PR merged inside [Monday, Monday + 7d +
# window] is unread. Such a row is final; a week that holds an unread PR waits.
#
#   P1  the real lane, REWORK_FETCH_CAP=2: PRs 71 and 72 (WEEK) are read, 74
#       (50 days back) is not; the run is incomplete, yet WEEK has its
#       cromford row and log line, and 74's week has no row
#   P2  the boundary: one unread PR at Monday or at Monday + 14d holds WEEK
#       back (no row, no finding for PR 71); at Monday - 1s or Monday + 14d
#       + 1s it does not
#   P3  the row's numbers: 2 merged, 1 reworked, 50.0
#   P4  the scratch round-trip: missing.tsv names the unread PR, listed.tsv
#       both repos, complete.tsv not cromford
#   P5  a failed listing: no cromford row at all; alpha-os still rolls up
#   P6  read-only: the gh sink holds no write
#
# NO LIVE CALLS: curl and gh are the stubs of tests/outcome-rework-test.sh.
# Fixtures are invented (Acme/*, BH-nn, AX-nn).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/outcome-rework-partial.bh-6165-test.sh
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

# ── curl stub: the worker, as in outcome-rework-test.sh ─────────────────────
cat > "$STUB/curl" <<'SH'
#!/bin/bash
URL="${!#}"
body='{}'; code=404
case "$URL" in
  */api/ledger\?kind=merge*)
    M=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    body='{"ledgers":[{"key":"https://github.com/Acme/ledger-only/pull/1","status":"merged","job_id":"b-1","updated_at":"'"$M"'"}]}'; code=200 ;;
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
WEEK=$(date -u -d "@$MON" +%G-W%V)
DAY=86400
OLD=$((NOW - 50*DAY))
OLDWEEK=$(date -u -d "@$OLD" +%G-W%V)

newroot() { # newroot <name> -> sets R; alpha-os first, cromford second
  R="$BASE/$1"
  mkdir -p "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fix"
  echo "HARNESS_SECRET=test-secret" > "$R/env/global.env"
  cat > "$R/fleet.conf" <<'CONF'
alpha-os       Acme/alpha-os       https://os.alpha.example   /api/board  2 box-alpha
cromford  Acme/cromford  https://os.harness.example /api/board  6 box-harness
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
run() {
  env HARNESS="$R" FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" "$@" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
}
summary() { grep ' scanned=' "$R/logs/outcome-metrics.log" | tail -1; }
# shellcheck source=../bin/lib/outcome-rework.sh
. "$DIR/bin/lib/outcome-rework.sh" || { echo "FAIL: cannot source bin/lib/outcome-rework.sh"; exit 1; }
scan() { # scan <work>: rework_scan direct, dry=0, fetch cap 0 (only the cache is read)
  mkdir -p "$1"
  FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" HARNESS="$R" \
    rework_scan "$R/cand" "$1" "$1/cache" "$1/roll.csv" 60 7 30 0 0 "$DIR/bin" 0 "$R/scan.log" test
}
seed() { # seed <work> <n>...: cache those cromford PRs as read
  local w="$1" n; shift
  mkdir -p "$w/cache/Acme_cromford"
  for n in "$@"; do echo 'bin/x.sh' > "$w/cache/Acme_cromford/$n"; done
}

# ── P1 + P3: the real lane, capped partway through cromford ────────────
newroot p1
lpr Acme/cromford 71 "$A0" "BH-71: a"
lpr Acme/cromford 72 "$((A0 + DAY))" "BH-72: b"
lpr Acme/cromford 74 "$OLD" "BH-74: old"
lfiles Acme/cromford 71 bin/x.sh; lfiles Acme/cromford 72 bin/x.sh; lfiles Acme/cromford 74 bin/y.sh
mkpages
run REWORK_FETCH_CAP=2; RC=$?
[ "$RC" = 0 ] && ok || bad "P1 lane exited $RC"
RU="$R/logs/outcome-rework-rollup.csv"
grep -qE 'repos/Acme/cromford/pulls/71/files' "$R/gh.log" && grep -qE 'repos/Acme/cromford/pulls/72/files' "$R/gh.log" && ok \
  || bad "P1 PRs 71 and 72 were not both read: $(grep files "$R/gh.log")"
grep -qE 'repos/Acme/cromford/pulls/74/files' "$R/gh.log" && bad "P1 PR 74 was read; the cap did not bite" || ok
summary | grep -q 'rework_complete=0' && ok || bad "P1 a capped run is not rework_complete=0: $(summary)"
grep -q "^$WEEK,cromford," "$RU" 2>/dev/null && ok \
  || bad "P1 no ^$WEEK,cromford, row: $(cat "$RU" 2>/dev/null)"
[ "$(grep "^$WEEK,cromford," "$RU" 2>/dev/null | head -1 | awk -F, '{print NF}')" = 10 ] && ok \
  || bad "P1 the $WEEK cromford row has not 10 columns"
grep -q "rework week=$WEEK project=cromford " "$R/logs/outcome-metrics.log" && ok \
  || bad "P1 no rollup log line for $WEEK cromford: $(grep 'rework' "$R/logs/outcome-metrics.log")"
grep -q "^$OLDWEEK,cromford," "$RU" 2>/dev/null && bad "P1 the week of the unread PR 74 ($OLDWEEK) got a row" || ok
# P3: 72 touches all of 71's product files, one day later, another ticket.
grep -qx "$WEEK,cromford,2,1,50.0,0,0,-,0,backfill" "$RU" 2>/dev/null && ok \
  || bad "P3 $WEEK cromford row wrong: $(grep "^$WEEK,cromford," "$RU" 2>/dev/null)"
grep -q 'Acme/cromford/pull/71' "$R/logs/outcome-metrics.csv" 2>/dev/null && ok \
  || bad "P3 PR 71 in a complete week has no reworked finding: $(cat "$R/logs/outcome-metrics.csv" 2>/dev/null)"
[ ! -s "$R/gh.log.writes" ] && ok || bad "P6 a gh write (P1): $(cat "$R/gh.log.writes")"

# ── P2: the week boundary, one unread PR 79 ─────────────────────────────────
p2() { # p2 <label> <epoch of the unread PR> <want: row|none>
  newroot "p2-$1"
  lpr Acme/cromford 71 "$A0" "BH-71: a"
  lpr Acme/cromford 72 "$((A0 + DAY))" "BH-72: b"
  lpr Acme/cromford 79 "$2" "BH-79: unread"
  mkpages
  local w="$R/w"; seed "$w" 71 72
  scan "$w" || bad "P2 $1: rework_scan returned non-zero"
  if [ "$3" = row ]; then
    grep -q "^$WEEK,cromford," "$w/roll.csv" 2>/dev/null && ok \
      || bad "P2 $1: want a $WEEK row, got: $(cat "$w/roll.csv" 2>/dev/null)"
    grep -q 'Acme/cromford/pull/71' "$R/cand" 2>/dev/null && ok \
      || bad "P2 $1: PR 71 in a complete week is not a reworked finding"
  else
    grep -q "^$WEEK,cromford," "$w/roll.csv" 2>/dev/null \
      && bad "P2 $1: an unread PR in the week or its window, yet a $WEEK row was written" || ok
    grep -q 'Acme/cromford/pull/71' "$R/cand" 2>/dev/null \
      && bad "P2 $1: PR 71 in an incomplete week became a reworked finding" || ok
  fi
}
p2 at-monday "$MON" none
p2 at-window-end "$((MON + 14*DAY))" none
p2 mid-week "$((MON + 3*DAY))" none
p2 after-window-end "$((MON + 14*DAY + 1))" row
p2 before-monday "$((MON - 1))" row

# ── P4: the scratch round-trip ──────────────────────────────────────────────
R="$BASE/p2-at-monday"; W="$R/w/rework"
[ "$(cat "$W/missing.tsv" 2>/dev/null)" = "$(printf 'Acme/cromford\t%s' "$(date -u -d "@$MON" +%Y-%m-%dT%H:%M:%SZ)")" ] && ok \
  || bad "P4 missing.tsv: $(cat "$W/missing.tsv" 2>/dev/null)"
[ "$(cat "$W/listed.tsv" 2>/dev/null)" = "$(printf 'Acme/alpha-os\talpha-os\nAcme/cromford\tcromford')" ] && ok \
  || bad "P4 listed.tsv: $(cat "$W/listed.tsv" 2>/dev/null)"
grep -q 'Acme/cromford' "$W/complete.tsv" && bad "P4 a repo with an unread PR is in complete.tsv" || ok
[ "$REWORK_COMPLETE" = 1 ] && bad "P4 a run with an unread PR set REWORK_COMPLETE=1" || ok

# ── P5: cromford listing is not a list ─────────────────────────────────
newroot p5
lpr Acme/alpha-os 11 "$A0" "AX-11: a"
lpr Acme/cromford 71 "$A0" "BH-71: a"
lfiles Acme/alpha-os 11 src/a.ts; lfiles Acme/cromford 71 bin/x.sh
mkpages
echo '{"message":"Server Error"}' > "$R/fix/pulls-Acme_cromford-1.json"
run
RU="$R/logs/outcome-rework-rollup.csv"
grep -q ',cromford,' "$RU" 2>/dev/null && bad "P5 a repo whose listing failed got a rollup row" || ok
grep -qx "$WEEK,alpha-os,1,0,0.0,0,0,-,0,backfill" "$RU" 2>/dev/null && ok \
  || bad "P5 alpha-os $WEEK row missing: $(cat "$RU" 2>/dev/null)"
[ ! -s "$R/gh.log.writes" ] && ok || bad "P6 a gh write (P5)"

# ── P6: no run issued a write verb ──────────────────────────────────────────
W=$(cat "$BASE"/*/gh.log.writes 2>/dev/null)
[ -z "$W" ] && ok || bad "P6 a run issued a mutating gh call: $(head -1 <<<"$W")"

echo "outcome-rework-partial: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
