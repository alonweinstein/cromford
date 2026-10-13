#!/bin/bash
# tests/outcome-rework-test.sh — BH-3956: the `reworked` outcome, driven.
#
# bin/outcome-metrics.sh grows a fourth outcome: a merged PR A is REWORKED when
# a later merged PR B, inside REWORK_WINDOW_DAYS, touches at least
# REWORK_MIN_SHARE percent of A's product files (bin/size-scope.sh decides what
# is product), and B is not A's own ticket's repair round. The pass itself is
# bin/lib/outcome-rework.sh; every case below drives it through the REAL lane
# entry point, bin/outcome-metrics.sh, so deleting the call site fails here.
#
# Each positive case has its near-miss beside it (10 days later, overlap only
# in tests/docs/lockfiles, the same ticket, 25% share, a train, a revert, a
# non-default base): a detector that fires on everything is as useless as one
# that never fires.
#
# NO LIVE CALLS: curl and gh are stubs. gh records argv and exits 90 on any
# verb that is not a read, and the suite asserts it never got one.
# Fixtures use invented repos and tickets (Acme/widget-os, WD-nn).
#
# Run from anywhere: tests/outcome-rework-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
BASE="$T"
LIB="$DIR/bin/lib/outcome-rework.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/outcome-rework.sh does not exist"

STUB="$BASE/stub"; mkdir -p "$STUB"
export PATH="$STUB:$PATH"
printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"; chmod +x "$STUB/flock"

# ── curl stub: the worker. One merged ledger PR on a repo outside fleet.conf,
# so the existing per-PR loop runs (and the run is not "nothing measured")
# without touching any fixture this suite is about.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
body='{}'; code=404
case "$URL" in
  */api/ledger\?kind=merge*)
    M=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    body='{"ledgers":[{"key":"https://github.com/Acme/ledger-only/pull/1","status":"merged","job_id":"b-1","updated_at":"'"$M"'"}]}'; code=200 ;;
esac
printf '%s\n%s\n' "$body" "$code"
EOF
chmod +x "$STUB/curl"

# ── gh stub: serves the pulls listing, per-PR files and rate_limit ──────────
cat > "$STUB/gh" <<'EOF'
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
      rate_limit) OUT=$(cat "$FIX/rate_limit.json" 2>/dev/null || echo '{"resources":{"core":{"remaining":5000}}}') ;;
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
EOF
chmod +x "$STUB/gh"

# ── time anchors ─────────────────────────────────────────────────────────────
# A0 = Tuesday 12:00Z of the ISO week 4 weeks back, so that week is closed
# (Sunday + 7d window < now) and lies wholly inside a 60-day backfill.
NOW=$(date -u +%s)
D=$((NOW - 28*86400)); DOW=$(date -u -d "@$D" +%u)
MON=$(( (D/86400 - (DOW-1)) * 86400 ))
A0=$((MON + 86400 + 43200))
WEEK=$(date -u -d "@$MON" +%G-W%V)
CURWEEK=$(date -u -d "@$NOW" +%G-W%V)
DAY=86400

# ── one fresh harness root per case ─────────────────────────────────────────
newroot() { # newroot <name> -> sets R
  R="$BASE/$1"
  mkdir -p "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fix"
  echo "HARNESS_SECRET=test-secret" > "$R/env/global.env"
  cat > "$R/fleet.conf" <<'EOF'
widget-os  Acme/widget-os   https://os.widget.example  /api/board  2 box-widget
gadget-os  Acme/gadget-os   https://os.gadget.example  /api/board  4 box-gadget
EOF
  : > "$R/list.tsv"; : > "$R/gh.log"
}
# lpr <repo> <number> <epoch> <title> [base-ref] — a merged PR in the listing
lpr() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -u -d "@$3" +%Y-%m-%dT%H:%M:%SZ)" "$4" "${5:-main}" >> "$R/list.tsv"; }
# lfiles <repo> <number> <file>... — that PR's file list
lfiles() {
  local repo="$1" n="$2"; shift 2
  printf '%s\n' "$@" | jq -R . | jq -s '[.[] | {filename: .}]' > "$R/fix/prfiles-$(printf '%s' "$repo" | tr '/' '_')-$n.json"
}
# mkpages — writes page 1 of each repo's listing, newest-updated first
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
run() { # run [VAR=val ...] — the real lane, against root $R
  env HARNESS="$R" FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" "$@" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
}
rows() { grep -c ',reworked,' "$R/logs/outcome-metrics.csv" 2>/dev/null || true; }
U=https://github.com/Acme/widget-os/pull

# ── R1: A reworked by B 3 days later, 2 of 4 product files ───────────────────
newroot r1
lpr Acme/widget-os 31 "$A0" "WD-31: pricing panel"
lpr Acme/widget-os 32 "$((A0 + 3*DAY))" "WD-32: pricing follow-up"
lfiles Acme/widget-os 31 src/a.ts src/b.ts src/c.ts src/d.ts tests/a.test.ts
lfiles Acme/widget-os 32 src/a.ts src/b.ts
mkpages
cp -r "$R" "$BASE/r1-pristine"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "R1 lane exited $RC"
CSV="$R/logs/outcome-metrics.csv"
[ "$(rows)" = 1 ] && ok || bad "R1 expected exactly 1 reworked row, got $(rows): $(cat "$CSV" 2>/dev/null)"
grep -q ",$U/31,reworked," "$CSV" 2>/dev/null && ok || bad "R1 no reworked row for PR 31"
grep ",$U/31,reworked," "$CSV" 2>/dev/null | grep -q "$U/32" && ok || bad "R1 evidence does not name PR 32"
grep ",$U/31,reworked," "$CSV" 2>/dev/null | grep -q '2 of 4 product files (50%)' && ok \
  || bad "R1 evidence lacks '2 of 4 product files (50%)': $(grep reworked "$CSV" 2>/dev/null)"
grep ",$U/31,reworked," "$CSV" 2>/dev/null | grep -q 'sibling=-' && ok || bad "R5b a non-sibling row does not carry sibling=-"
grep -q "$U/32,reworked" "$CSV" 2>/dev/null && bad "R1 B itself was reported reworked" || ok
grep -q 'rework=1 ' "$R/logs/outcome-metrics.log" && ok || bad "R1 the run log does not count the rework row: $(tail -1 "$R/logs/outcome-metrics.log")"
grep -qx "reworked:$U/31" "$R/state/outcome-metrics-seen.txt" && ok || bad "R1 SEEN key reworked:<A-url> missing"

# ── R9: CSV yes, findings.log no ─────────────────────────────────────────────
grep -q 'outcome=reworked' "$R/logs/findings.log" 2>/dev/null && bad "R9 a reworked row reached findings.log" || ok

# ── R8: a second run appends nothing ─────────────────────────────────────────
C1=$(wc -l < "$CSV"); RL1=$({ wc -l < "$R/logs/outcome-rework-rollup.csv"; } 2>/dev/null || echo x)
S1=$(wc -l < "$R/state/outcome-metrics-seen.txt")
run
[ "$(wc -l < "$CSV")" = "$C1" ] && ok || bad "R8 second run grew the CSV ($C1 -> $(wc -l < "$CSV"))"
[ "$({ wc -l < "$R/logs/outcome-rework-rollup.csv"; } 2>/dev/null || echo x)" = "$RL1" ] && ok || bad "R8 second run grew the rollup"
[ "$(wc -l < "$R/state/outcome-metrics-seen.txt")" = "$S1" ] && ok || bad "R8 second run grew SEEN"
# The file cache made the second run fetch nothing again.
[ "$(grep -c 'pulls/31/files' "$R/gh.log")" = 1 ] && ok || bad "R8 PR 31's files were fetched again ($(grep -c 'pulls/31/files' "$R/gh.log"))"

# ── R10: the knobs are read ──────────────────────────────────────────────────
R="$BASE/r10a"; cp -r "$BASE/r1-pristine" "$R"
run REWORK_MIN_SHARE=60
[ "$(rows)" = 0 ] && ok || bad "R10 REWORK_MIN_SHARE=60 still emitted a 50% row"
R="$BASE/r10b"; cp -r "$BASE/r1-pristine" "$R"
run REWORK_WINDOW_DAYS=0
grep -q 'pulls?state=closed' "$R/gh.log" && bad "R10 REWORK_WINDOW_DAYS=0 still listed pulls" || ok
[ "$(rows)" = 0 ] && ok || bad "R10 REWORK_WINDOW_DAYS=0 still emitted a row"
R="$BASE/r10c"; cp -r "$BASE/r1-pristine" "$R"
run REWORK_MIN_SHARE=abc
[ "$(rows)" = 1 ] && ok || bad "R10 a malformed REWORK_MIN_SHARE did not fall back to the default"

# ── R2: same overlap, 10 days later ──────────────────────────────────────────
newroot r2
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 10*DAY))" "WD-32: y"
lfiles Acme/widget-os 31 src/a.ts src/b.ts src/c.ts src/d.ts; lfiles Acme/widget-os 32 src/a.ts src/b.ts
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R2 a B 10 days later counted as rework"

# ── R3: overlap only in tests/docs/lockfiles ─────────────────────────────────
newroot r3
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 2*DAY))" "WD-32: y"
lfiles Acme/widget-os 31 src/a.ts tests/a.test.ts docs/x.md README.md package-lock.json
lfiles Acme/widget-os 32 src/zzz.ts tests/a.test.ts docs/x.md README.md package-lock.json
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R3 overlap only in tests/docs/lockfile counted as rework"

# ── R4: B is A's own ticket (a repair round) ─────────────────────────────────
newroot r4
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 3*DAY))" "WD-31: fix round"
lfiles Acme/widget-os 31 src/a.ts src/b.ts src/c.ts src/d.ts; lfiles Acme/widget-os 32 src/a.ts src/b.ts
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R4 the same ticket's repair round counted as rework"

# ── R5: siblings of one parent ───────────────────────────────────────────────
newroot r5
lpr Acme/widget-os 41 "$A0" "WD-41: WD-40.1: contract"; lpr Acme/widget-os 42 "$((A0 + 2*DAY))" "WD-42: WD-40.2: wire it"
lfiles Acme/widget-os 41 src/a.ts src/b.ts src/c.ts src/d.ts; lfiles Acme/widget-os 42 src/a.ts src/b.ts
mkpages; run
grep ",$U/41,reworked," "$R/logs/outcome-metrics.csv" 2>/dev/null | grep -q 'sibling=WD-40' && ok \
  || bad "R5 sibling pair not tagged sibling=WD-40: $(grep reworked "$R/logs/outcome-metrics.csv" 2>/dev/null)"

# ── R6: 25% share under a 30% threshold ──────────────────────────────────────
newroot r6
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 3*DAY))" "WD-32: y"
lfiles Acme/widget-os 31 src/a.ts src/b.ts src/c.ts src/d.ts; lfiles Acme/widget-os 32 src/a.ts src/q.ts
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R6 a 25% share counted as rework"

# ── R7: the window boundary ──────────────────────────────────────────────────
newroot r7a
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 7*DAY))" "WD-32: y"
lfiles Acme/widget-os 31 src/a.ts src/b.ts; lfiles Acme/widget-os 32 src/a.ts
mkpages; run
[ "$(rows)" = 1 ] && ok || bad "R7 a B exactly 7d later did not count"
newroot r7b
lpr Acme/widget-os 31 "$A0" "WD-31: x"; lpr Acme/widget-os 32 "$((A0 + 7*DAY + 3600))" "WD-32: y"
lfiles Acme/widget-os 31 src/a.ts src/b.ts; lfiles Acme/widget-os 32 src/a.ts
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R7 a B 7d+1h later counted"
# B merged BEFORE A is not rework of A (A here is the older PR 31's successor).
grep -q "$U/32,reworked" "$R/logs/outcome-metrics.csv" 2>/dev/null && bad "R7 an earlier PR was read as reworking a later one" || ok

# ── R11: trains, reverts, non-default bases are never B ──────────────────────
newroot r11
lpr Acme/widget-os 31 "$A0" "WD-31: x"
lpr Acme/widget-os 32 "$((A0 + 1*DAY))" "batch(widget-os): land 3 approved siblings as one train"
lpr Acme/widget-os 33 "$((A0 + 2*DAY))" 'Revert "WD-31: x"'
lpr Acme/widget-os 34 "$((A0 + 3*DAY))" "WD-34: on a feature branch" feature
lfiles Acme/widget-os 31 src/a.ts src/b.ts
for n in 32 33 34; do lfiles Acme/widget-os "$n" src/a.ts src/b.ts; done
mkpages; run
[ "$(rows)" = 0 ] && ok || bad "R11 a train, a revert or a non-default-base PR counted as B: $(grep reworked "$R/logs/outcome-metrics.csv" 2>/dev/null)"

# ── R12: the weekly rollup ───────────────────────────────────────────────────
newroot r12
lpr Acme/widget-os 41 "$A0" "WD-41: WD-40.1: contract"
lpr Acme/widget-os 42 "$((A0 + 1*DAY))" "WD-42: WD-40.2: wire"
lpr Acme/widget-os 43 "$((A0 + 2*DAY))" "WD-43: plain"
lpr Acme/widget-os 44 "$((A0 + 3*DAY))" "WD-44: plain"
lpr Acme/widget-os 45 "$((A0 + 3*DAY))" "WD-45: docs only"
lpr Acme/widget-os 46 "$((NOW - 3600))" "WD-46: this week"
lpr Acme/gadget-os 51 "$A0" "GD-51: plain"
lfiles Acme/widget-os 41 src/a.ts src/b.ts
lfiles Acme/widget-os 42 src/a.ts src/x.ts
lfiles Acme/widget-os 43 src/c.ts
lfiles Acme/widget-os 44 src/d.ts
lfiles Acme/widget-os 45 docs/readme.md
lfiles Acme/widget-os 46 src/e.ts
lfiles Acme/gadget-os 51 src/g.ts
mkpages; run
RU="$R/logs/outcome-rework-rollup.csv"
head -1 "$RU" 2>/dev/null | grep -qx 'week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source' \
  && ok || bad "R12 rollup header wrong: $(head -1 "$RU" 2>/dev/null)"
grep -qx "$WEEK,widget-os,4,1,25.0,2,1,50.0,1,backfill" "$RU" 2>/dev/null && ok \
  || bad "R12 widget-os $WEEK row wrong: $(grep "$WEEK,widget-os" "$RU" 2>/dev/null)"
grep -qx "$WEEK,gadget-os,1,0,0.0,0,0,-,0,backfill" "$RU" 2>/dev/null && ok \
  || bad "R12 gadget-os $WEEK row wrong (zero denominator must be '-'): $(grep "$WEEK,gadget-os" "$RU" 2>/dev/null)"
grep -q "^$CURWEEK," "$RU" 2>/dev/null && bad "R12 the current, unclosed week got a rollup row" || ok
grep -q "rework week=$WEEK project=widget-os rate=25.0% (1/4) decomposed=50.0% (1/2)" "$R/logs/outcome-metrics.log" && ok \
  || bad "R12 no rollup log line for widget-os: $(grep 'rework week' "$R/logs/outcome-metrics.log" | head -3)"

# ── R13: the 60-day backfill, once; cap -> incomplete; DRY writes nothing ───
newroot r13
lpr Acme/widget-os 61 "$((NOW - 50*DAY))" "WD-61: old but in"
lpr Acme/widget-os 62 "$((NOW - 70*DAY))" "WD-62: too old"
lpr Acme/widget-os 63 "$((NOW - 5*DAY))" "WD-63: recent"
lfiles Acme/widget-os 61 src/a.ts; lfiles Acme/widget-os 62 src/b.ts; lfiles Acme/widget-os 63 src/c.ts
mkpages
cp -r "$R" "$BASE/r13-pristine"
run; RC_FULL=$?
grep -q 'pulls/61/files' "$R/gh.log" && ok || bad "R13 the backfill did not reach a PR merged 50 days ago"
grep -q 'pulls/62/files' "$R/gh.log" && bad "R13 the backfill fetched a PR merged 70 days ago" || ok
[ -f "$R/state/outcome-rework-backfill.done" ] && ok || bad "R13 a complete first run did not write the backfill marker"
grep -q 'rework_scan_days=60' "$R/logs/outcome-metrics.log" && ok || bad "R13 first run did not scan 60 days: $(tail -1 "$R/logs/outcome-metrics.log")"
grep -q 'rework_complete=1' "$R/logs/outcome-metrics.log" && ok || bad "R13 first run not marked complete"
run
tail -1 "$R/logs/outcome-metrics.log" | grep -q 'rework_scan_days=21' && ok || bad "R13 after the backfill the scan is not window+14: $(tail -1 "$R/logs/outcome-metrics.log")"

R="$BASE/r13cap"; cp -r "$BASE/r13-pristine" "$R"
run REWORK_FETCH_CAP=1; RC_CAP=$?
[ -f "$R/state/outcome-rework-backfill.done" ] && bad "R13 a cap-limited run wrote the backfill marker" || ok
# Completeness is per repo and week (BH-6165): the week that holds the unread
# PR 61 gets no widget-os row; a closed week clear of it and its window does.
W61=$(date -u -d "@$((NOW - 50*DAY))" +%G-W%V)
grep -q "^$W61,widget-os," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && bad "R13 the week of the unread PR 61 ($W61) got a widget-os row" || ok
grep -q "^$WEEK,widget-os,0,0,-," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && ok || bad "R13 a closed, fully read week ($WEEK) got no widget-os row: $(cat "$R/logs/outcome-rework-rollup.csv" 2>/dev/null)"
grep -q 'rework_complete=0' "$R/logs/outcome-metrics.log" && ok || bad "R13 a cap-limited run did not log rework_complete=0"
[ -s "$R/logs/ALERTS.log" ] && bad "R13 a cap-limited run wrote an ALERT" || ok
R="$BASE/r13off"; cp -r "$BASE/r13-pristine" "$R"
run REWORK_WINDOW_DAYS=0; RC_OFF=$?
[ "$RC_CAP" = "$RC_OFF" ] && [ "$RC_FULL" = "$RC_OFF" ] && ok || bad "R13 the rework pass changed the exit code (full=$RC_FULL cap=$RC_CAP off=$RC_OFF)"
# Resume: the next cap-limited run fetches what the first did not, never the same PR twice.
R="$BASE/r13cap"
F1=$(grep -oE 'pulls/6[13]/files' "$R/gh.log" | sort -u)
: > "$R/gh.log"
run REWORK_FETCH_CAP=1
F2=$(grep -oE 'pulls/6[13]/files' "$R/gh.log" | sort -u)
[ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && ok || bad "R13 a capped re-run did not resume off the cache (first: $F1, second: $F2)"
[ -f "$R/state/outcome-rework-backfill.done" ] && ok || bad "R13 the resumed run completed the scan but wrote no marker"

R="$BASE/r13dry"; cp -r "$BASE/r1-pristine" "$R"
DOUT=$(env HARNESS="$R" FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" OUTCOME_DRY=1 bash "$DIR/bin/outcome-metrics.sh" 2>&1 >/dev/null)
grep -q "outcome reworked: $U/31 reworked by $U/32" <<<"$DOUT" && ok || bad "R13 DRY did not print the reworked row it would write: $DOUT"
[ -s "$R/logs/outcome-metrics.csv" ] && bad "R13 DRY wrote the CSV" || ok
[ -e "$R/logs/outcome-rework-rollup.csv" ] && bad "R13 DRY wrote the rollup" || ok
[ -e "$R/state/outcome-rework-backfill.done" ] && bad "R13 DRY wrote the backfill marker" || ok
[ -e "$R/state/outcome-rework" ] && bad "R13 DRY left a persistent file cache" || ok
grep -q 'rework=1 ' "$R/logs/outcome-metrics.log" && ok || bad "R13 DRY did not still count what it would write"

# ── Detection only: no run issued a write verb ───────────────────────────────
W=$(cat "$BASE"/*/gh.log.writes 2>/dev/null)
[ -z "$W" ] && ok || bad "a run issued a mutating gh call: $(head -1 <<<"$W")"

echo "outcome-rework-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
