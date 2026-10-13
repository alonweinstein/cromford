#!/bin/bash
# tests/reopen-window.bh-115-test.sh — bin/reopen-metrics.sh windows the
# builds_total denominator to the same 14 days as the reopens_14d numerator.
#
# The bug this pins (BH-115): reopens_14d counted the last 14 days, but
# builds_total counted every PR-shaped build ever — every metrics.csv row, and
# on the GitHub lane every build dir with a PR_MERGED/PR_CREATED RESULT. The
# rate only ever diluted: at 500 lifetime builds a project needs 75 reopens in
# 14 days to cross the 0.15 demote threshold, so the demoter could never fire
# on a mature project. W1 is the ticket's own fixture: 500 lifetime builds, 10
# of them in the window, 2 reopens in the window must read 2/10 = 0.20 and
# demote, not 2/500 = 0.004.
#
# Every producer case drives the real script (SCRIPT= overrides it, so the
# same suite can be pointed at main's copy to show it red). Removing the date
# window from either denominator line fails W1 or W2.
# Run from anywhere: tests/reopen-window.bh-115-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
SCRIPT="${SCRIPT:-$DIR/bin/reopen-metrics.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ago()  { date -u -d "$1 days ago" "+$2" 2>/dev/null || date -u -v-"$1"d "+$2"; }
OLD=$(ago 40 '%Y-%m-%d %H:%M:%SZ');  OLDC=$(ago 40 '%Y%m%d')0000
NEW=$(ago 3 '%Y-%m-%d %H:%M:%SZ');   NEWC=$(ago 3 '%Y%m%d')0000
SINCE=$(ago 14 '%Y%m%d')
EDGE=$(ago 14 '%Y-%m-%d %H:%M:%SZ')     # dated exactly $SINCE
PAST=$(ago 15 '%Y-%m-%d %H:%M:%SZ')     # $SINCE - 1 day

# One registry for every case. All GitHub-lane rows (board-api-prefix "-"), so
# the snapshot lane never needs credentials; the gh stub answers an empty page.
mkdir -p "$T/stub"
printf '#!/bin/bash\necho "[]"\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

HDR='build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min'
# fresh <name> -> a clean harness tree at $T/<name> with one project "solo"
fresh() {
  H="$T/$1"; scratch_rm "$H"; mkdir -p "$H/logs" "$H/state" "$H/builds" "$H/env"
  echo 'solo  Acme/solo  -  -  3 box-small' > "$H/fleet.conf"
  echo "$HDR" > "$H/logs/metrics.csv"
  echo 'date,project,key,from,to' > "$H/logs/reopens.csv"
}
# row <key> <date-or-empty> [build_dir] — metrics-collect.sh's real row shape
row() { printf '%s,solo,%s,%s,%s,%s,PR_MERGED,S,0,0,5\n' "${3:-solo-$1}" "$1" "$2" "$2" "$2" >> "$H/logs/metrics.csv"; }
# bdir <dir-suffix> [RESULT kind]
bdir() { mkdir -p "$H/builds/solo-$1"; echo "${2:-PR_MERGED} https://x/pull/1" > "$H/builds/solo-$1/RESULT"; }
reopen() { echo "$1,solo,#$2,done,open" >> "$H/logs/reopens.csv"; }
run() { HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET= JOBS_URL=http://127.0.0.1:9 bash "$SCRIPT" >/dev/null 2>&1; }
got() { jq -c .solo "$H/state/reopen-rate.json" 2>/dev/null; }
bt()  { jq -r .solo.builds_total "$H/state/reopen-rate.json" 2>/dev/null; }

# ---------- W1: the ticket's fixture, metrics.csv source ----------------------
fresh w1
for i in $(seq 1 490);   do row "S-$i" "$OLD" "solo-S-$i-$OLDC"; done
for i in $(seq 491 500); do row "S-$i" "$NEW" "solo-S-$i-$NEWC"; done
reopen "${NEWC:0:8}" 1; reopen "${NEWC:0:8}" 2
run
[ "$(got)" = '{"reopens_14d":2,"builds_total":10}' ] && ok \
  || bad "W1 500 lifetime / 10 in-window / 2 reopens must be {reopens_14d:2,builds_total:10} (got $(got))"
# Mutation guard: this is the value with no window on the denominator.
[ "$(bt)" != 500 ] && ok || bad "W1 builds_total is the all-time count (500) — the window is gone"
W1_RATE="$H/state/reopen-rate.json"

# ---------- W1-demote: that file reaches the tier demoter ---------------------
awk '/^# >>> reopen trust signal/{f=1;next}  /^# <<< reopen trust signal/{exit}  f' "$RB_ALL" > "$T/signal.sh"
awk '/^# >>> reopen trust demoter/{f=1;next} /^# <<< reopen trust demoter/{exit} f' "$RB_ALL" > "$T/demoter.sh"
[ -s "$T/signal.sh" ] && [ -s "$T/demoter.sh" ] && ok || bad "could not extract the reopen signal/demoter blocks"
HH="$T/gate"; scratch_rm "$HH"; mkdir -p "$HH/state" "$HH/build"
cp "$W1_RATE" "$HH/state/reopen-rate.json" 2>/dev/null
G=$(HARNESS="$HH" BUILD="$HH/build" PROJECT=solo KEY=K TIER=1 JOBS_URL=http://127.0.0.1:9 HARNESS_SECRET= \
  bash -c 'set -uo pipefail; STAMP(){ echo TS; }; QA_NOTE=""; . "$0"; . "$1"; printf "%s|%s" "$TIER" "$QA_NOTE"' \
  "$T/signal.sh" "$T/demoter.sh" 2>/dev/null)
[ "${G%%|*}" = 2 ] && ok || bad "W1-demote 2/10 over 0.15 must force tier-2 (got '$G')"
grep -q 'reopen rate 0.20 (2/10, 14d) over 0.15' <<<"$G" && ok \
  || bad "W1-demote QA note must carry 0.20 (2/10, 14d) (got '$G')"

# ---------- W2: build-dir fallback, dated by the run-build dir suffix ---------
fresh w2
for i in $(seq 1 490);   do bdir "G-$i-$OLDC"; done
for i in $(seq 491 500); do bdir "G-$i-$NEWC"; done
run
[ "$(bt)" = 10 ] && ok || bad "W2 fallback must count only the 10 in-window dirs (got $(bt))"

# ---------- W3: build-dir fallback, suffix-less dirs dated by RESULT mtime ----
fresh w3
bdir G-old; touch -d '40 days ago' "$H/builds/solo-G-old/RESULT" 2>/dev/null \
  || touch -t "$(ago 40 '%Y%m%d')1200" "$H/builds/solo-G-old/RESULT"
bdir G-new
bdir G-blocked REVIEW_BLOCKED
run
[ "$(bt)" = 1 ] && ok || bad "W3 an old-mtime RESULT is excluded, a fresh one counts, a non-PR kind never does (got $(bt))"

# ---------- W4: undated metrics rows are not counted --------------------------
fresh w4
row U-1 ""; row U-2 ""
for i in $(seq 1 10); do row "S-$i" "$NEW"; done
run
[ "$(bt)" = 10 ] && ok || bad "W4 rows with no date and no dir suffix must not count (got $(bt))"
# ...but an undated row whose build_dir carries run-build's suffix is dated by it.
fresh w4b
row U-1 "" "solo-U-1-$NEWC"; row U-2 "" "solo-U-2-$OLDC"
run
[ "$(bt)" = 1 ] && ok || bad "W4 a dateless row falls back to its build_dir suffix (got $(bt))"

# ---------- W5: the boundary is >= SINCE, same as the numerator ---------------
fresh w5
row E-1 "$EDGE"; row E-2 "$PAST"
reopen "$SINCE" 1; reopen "$(ago 15 '%Y%m%d')" 2
run
[ "$(got)" = '{"reopens_14d":1,"builds_total":1}' ] && ok \
  || bad "W5 a row dated exactly SINCE counts, SINCE-1 does not, on both sides (got $(got))"

# ---------- W5b: merged_at wins over started ----------------------------------
fresh w5b
printf 'solo-M-1,solo,M-1,%s,%s,%s,PR_MERGED,S,0,0,5\n' "$OLD" "$OLD" "$NEW" >> "$H/logs/metrics.csv"
printf 'solo-M-2,solo,M-2,%s,,,PR_CREATED,S,0,0,5\n' "$NEW" >> "$H/logs/metrics.csv"
printf 'solo-M-3,solo,M-3,%s,,,REVIEW_BLOCKED,S,0,0,5\n' "$NEW" >> "$H/logs/metrics.csv"
run
[ "$(bt)" = 2 ] && ok || bad "W5b launched-old/merged-new counts, started alone dates a row, non-PR kinds never count (got $(bt))"

# ---------- W6: the fallback only fires when metrics.csv has nothing ----------
fresh w6
for i in $(seq 1 10); do row "S-$i" "$NEW"; done
for i in $(seq 1 30); do bdir "G-$i-$NEWC"; done
run
[ "$(bt)" = 10 ] && ok || bad "W6 in-window metrics.csv rows win; build dirs are not added (got $(bt))"

# ---------- W7: the numerator window is unchanged -----------------------------
fresh w7
reopen "${OLDC:0:8}" 1; reopen "${NEWC:0:8}" 2
run
[ "$(jq -r .solo.reopens_14d "$H/state/reopen-rate.json" 2>/dev/null)" = 1 ] && ok \
  || bad "W7 a reopen 40 days ago must not count (got $(got))"

echo "reopen-window.bh-115-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
