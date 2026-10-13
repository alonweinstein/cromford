#!/bin/bash
# tests/mergify-queue-time.bh-1700-test.sh — bin/mergify-queue-time.sh, the
# operator CLI that measures how long merged PRs sat between entering the merge
# queue and merging (BH-1673.3).
#
# WHAT THIS PINS. The median is only worth reading if the counts under it are
# honest. A failed events read looks exactly like "this PR was never queued"
# (no labeled event came back), and counting it that way quietly shifts the
# median and the unqueued count at once — the #768 shape, silence read as fact.
# So Q4a asserts a 502 on one events read lands as incomplete=1 and NEVER as
# unqueued, and Q4b asserts a rate-limited read exits 75 with no summary at all.
#
# Every case runs the REAL CLI against a stub `gh` on PATH. The stub answers the
# pulls list from $T/pulls.json and each PR's events from $T/events-<n>.json; a
# $T/<name>.status file (first line the status, the rest the body) overrides the
# 200. It records its argv so Q1 can assert only GitHub REST paths were read.
#
# Run from anywhere: bash tests/mergify-queue-time.bh-1700-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/mergify-queue-time.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# HARNESS points at an empty scratch tree: the CLI falls back to its own
# bin/lib, the App identity is never armed, and no ledger or cache is written
# anywhere a live harness reads.
export HARNESS="$T/h" GH_ETAG=0 GH_STUB_DIR="$T/fx"
mkdir -p "$T/h/logs" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
cp "$DIR/tests/lib/rest-emit.sh" "$T/bin/restpr"; chmod +x "$T/bin/restpr"

cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
p=""
for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
case "$p" in
  repos/o/r/pulls\?*)                 n=pulls ;;
  repos/o/r/issues/*/events\?*)       n=${p#repos/o/r/issues/}; n="events-${n%%/*}" ;;
  *) exit 1 ;;
esac
if [ -f "$D/$n.status" ]; then
  restpr --raw "$(head -1 "$D/$n.status")" "$(tail -n +2 "$D/$n.status")"
elif [ -f "$D/$n.json" ]; then
  restpr --raw 200 "$(cat "$D/$n.json")"
else
  restpr --raw 404 '{"message":"Not Found"}'
fi
exit 0
STUB
chmod +x "$T/bin/gh"

NOW=1790000000        # 2026-09-21-ish; only differences matter
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
reset() { rm -f "$T"/fx/*; : > "$T/fx/gh-calls.txt"; PULLS='[]'; }
# pr <num> <merged epoch|-> [updated epoch]   (appends to PULLS; - = closed unmerged)
pr() {
  local m=null
  [ "$2" != - ] && m="\"$(iso "$2")\""
  PULLS=$(jq -c --argjson n "$1" --argjson m "$m" --arg u "$(iso "${3:-$NOW}")" \
    '. + [{number:$n, state:"closed", merged_at:$m, updated_at:$u}]' <<<"$PULLS")
  printf '%s' "$PULLS" > "$T/fx/pulls.json"
}
# ev <num> <event> <label> <epoch>   (appends one issue event)
ev() {
  local f="$T/fx/events-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg e "$2" --arg l "$3" --arg c "$(iso "$4")" \
    '. + [{event:$e, label:{name:$l}, created_at:$c}]' "$f" > "$f.new" && mv "$f.new" "$f"
}
# merged PR <num> at <epoch>, queued <min> minutes earlier with <label>
qpr() { pr "$1" "$2"; ev "$1" labeled "${4:-queued}" $(( $2 - $3 * 60 )); }
run() { RC=0; "$CLI" "$@" > "$T/out" 2> "$T/err" || RC=$?; LAST=$(tail -n 1 "$T/out"); }
row() { awk -F'\t' -v n="$1" '$1==n' "$T/out"; }
calls() { grep -c . "$T/fx/gh-calls.txt"; }

# ══ Q1: five queued merges, one closed-unmerged, --last 5 ═══════════════════
reset
qpr 1 $((NOW-0))     10
qpr 2 $((NOW-3600))  12
qpr 3 $((NOW-7200))  14
qpr 4 $((NOW-10800)) 30
qpr 5 $((NOW-14400)) 50
pr 6 -
ev 6 labeled queued $((NOW-100))
run o/r --last 5
[ "$RC" = 0 ] && ok || bad "Q1: rc must be 0, got $RC ($(cat "$T/err"))"
[ "$LAST" = "median_minutes=14 measured=5 unqueued=0 wanted=5 incomplete=0" ] && ok \
  || bad "Q1: summary wrong: '$LAST'"
[ "$(grep -c "$(printf '\tqueued$')" "$T/out")" = 5 ] && ok || bad "Q1: want 5 queued rows: $(cat "$T/out")"
[ "$(row 3)" = "$(printf '3\t%s\t%s\t14\tqueued' "$(iso $((NOW-7200-840)))" "$(iso $((NOW-7200)))")" ] && ok \
  || bad "Q1: row 3 wrong: '$(row 3)'"
[ -z "$(row 6)" ] && ok || bad "Q1: a closed-unmerged PR must not be a row"
grep -q 'issues/6/' "$T/fx/gh-calls.txt" && bad "Q1: a closed-unmerged PR's events must not be read" || ok
[ "$(head -1 "$T/fx/gh-calls.txt")" = "api -i -X GET repos/o/r/pulls?state=closed&sort=updated&direction=desc&per_page=100" ] && ok \
  || bad "Q1: pulls read wrong: $(head -1 "$T/fx/gh-calls.txt")"
[ "$(grep -cvE '^api -i -X GET repos/o/r/(pulls\?state=closed&sort=updated&direction=desc&per_page=100|issues/[0-9]+/events\?per_page=100)$' "$T/fx/gh-calls.txt")" = 0 ] && ok \
  || bad "Q1: only REST pulls/events reads allowed: $(cat "$T/fx/gh-calls.txt")"
[ "$(calls)" = 6 ] && ok || bad "Q1: want 1 pulls + 5 events reads, got $(calls)"

# ══ Q2a: even count → mean of the middle two ════════════════════════════════
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 12; qpr 3 $((NOW-7200)) 14; qpr 4 $((NOW-10800)) 30
run o/r --last 4
[ "$LAST" = "median_minutes=13 measured=4 unqueued=0 wanted=4 incomplete=0" ] && ok || bad "Q2a: '$LAST'"
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 11
run o/r --last 2
[ "$LAST" = "median_minutes=10.5 measured=2 unqueued=0 wanted=2 incomplete=0" ] && ok || bad "Q2a: non-whole median '$LAST'"

# ══ Q2b: only our merge-queue label → fallback source ═══════════════════════
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 20 merge-queue
run o/r --last 2
[ "$(row 2)" = "$(printf '2\t%s\t%s\t20\tmerge-queue' "$(iso $((NOW-3600-1200)))" "$(iso $((NOW-3600)))")" ] && ok \
  || bad "Q2b: merge-queue row wrong: '$(row 2)'"
[ "$LAST" = "median_minutes=15 measured=2 unqueued=0 wanted=2 incomplete=0" ] && ok || bad "Q2b: '$LAST'"
# Both labels: queued wins even when merge-queue is the later one.
reset
qpr 1 $((NOW-0)) 40
ev 1 labeled merge-queue $((NOW-300))
run o/r --last 1
[ "$(row 1 | cut -f4-5)" = "$(printf '40\tqueued')" ] && ok || bad "Q2b: queued must win over a later merge-queue: '$(row 1)'"

# ══ Q3a: no entry label, and a near-miss label name → none / unqueued ══════
reset
qpr 1 $((NOW-0)) 20
pr 2 $((NOW-3600)); ev 2 labeled bug $((NOW-4000)); ev 2 unlabeled queued $((NOW-3700))
pr 3 $((NOW-7200)); ev 3 labeled dequeued $((NOW-8000)); ev 3 labeled queued-old $((NOW-7900))
run o/r --last 3
[ "$LAST" = "median_minutes=20 measured=1 unqueued=2 wanted=3 incomplete=0" ] && ok || bad "Q3a: '$LAST'"
[ "$(row 3)" = "$(printf '3\t-\t%s\t-\tnone' "$(iso $((NOW-7200)))")" ] && ok || bad "Q3a: none row wrong: '$(row 3)'"
[ "$(row 2 | cut -f5)" = none ] && ok || bad "Q3a: unlabeled-only must be none: '$(row 2)'"
# A queued label only AFTER merged_at is not an entry.
reset
pr 1 $((NOW-0)); ev 1 labeled queued $((NOW+60))
run o/r --last 1
[ "$LAST" = "median_minutes=none measured=0 unqueued=1 wanted=1 incomplete=0" ] && ok || bad "Q3a: post-merge label: '$LAST'"

# ══ Q3b: fewer merged than wanted → incomplete ══════════════════════════════
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 12; qpr 3 $((NOW-7200)) 14
run o/r --last 5
[ "$RC" = 0 ] && ok || bad "Q3b: rc must be 0, got $RC"
[ "$LAST" = "median_minutes=12 measured=3 unqueued=0 wanted=5 incomplete=1" ] && ok || bad "Q3b: '$LAST'"
reset
pr 1 -
printf '%s' "$PULLS" > "$T/fx/pulls.json"
run o/r --last 5
[ "$RC" = 0 ] && ok || bad "Q3b: zero merged rc must be 0, got $RC"
[ "$(cat "$T/out")" = "median_minutes=none measured=0 unqueued=0 wanted=5 incomplete=1" ] && ok || bad "Q3b: zero merged: '$(cat "$T/out")'"

# ══ Q4a: one events read fails → incomplete, NEVER unqueued ═════════════════
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 12; qpr 3 $((NOW-7200)) 14
printf '502\n{"message":"Server Error"}' > "$T/fx/events-2.status"
run o/r --last 3
[ "$RC" = 0 ] && ok || bad "Q4a: rc must be 0, got $RC"
[ "$LAST" = "median_minutes=12 measured=2 unqueued=0 wanted=3 incomplete=1" ] && ok || bad "Q4a: '$LAST'"
[ "$(row 2)" = "$(printf '2\t-\t%s\t-\terror' "$(iso $((NOW-3600)))")" ] && ok || bad "Q4a: failed read row wrong: '$(row 2)'"
# Unparseable JSON under a 200 is a failed read too.
rm -f "$T/fx/events-2.status"; printf 'not json' > "$T/fx/events-2.json"
run o/r --last 3
[ "$LAST" = "median_minutes=12 measured=2 unqueued=0 wanted=3 incomplete=1" ] && ok || bad "Q4a: garbage events: '$LAST'"

# ══ Q4b: rate limit → rc 75, no summary ═════════════════════════════════════
reset
qpr 1 $((NOW-0)) 10
printf '403\n{"message":"API rate limit exceeded for installation"}' > "$T/fx/pulls.status"
run o/r --last 1
[ "$RC" = 75 ] && ok || bad "Q4b: rate-limited pulls must be rc 75, got $RC"
[ ! -s "$T/out" ] && ok || bad "Q4b: rc 75 must print nothing: '$(cat "$T/out")'"
[ "$(calls)" = 1 ] && ok || bad "Q4b: no events read after a failed pulls read"
printf '500\n{"message":"boom"}' > "$T/fx/pulls.status"
run o/r --last 1
[ "$RC" = 75 ] && [ ! -s "$T/out" ] && ok || bad "Q4b: 500 on pulls must be rc 75 and silent, got $RC"
rm -f "$T/fx/pulls.status"; printf 'garbage' > "$T/fx/pulls.json"
run o/r --last 1
[ "$RC" = 75 ] && [ ! -s "$T/out" ] && ok || bad "Q4b: unparseable pulls must be rc 75 and silent, got $RC"
reset
qpr 1 $((NOW-0)) 10; qpr 2 $((NOW-3600)) 12
printf '429\n{"message":"You have exceeded a secondary rate limit"}' > "$T/fx/events-2.status"
run o/r --last 2
[ "$RC" = 75 ] && ok || bad "Q4b: rate-limited events read must be rc 75, got $RC"
[ ! -s "$T/out" ] && ok || bad "Q4b: rc 75 must print no rows and no summary: '$(cat "$T/out")'"

# ══ Q5: --last defaults to 20 ═══════════════════════════════════════════════
reset
qpr 1 $((NOW-0)) 10
run o/r
[ "$LAST" = "median_minutes=10 measured=1 unqueued=0 wanted=20 incomplete=1" ] && ok || bad "Q5: '$LAST'"

# ══ Q6: bad arguments → rc 2, gh never called ═══════════════════════════════
for args in "o/r --last 0" "o/r --last x" "" "a/b/c" "o/r --last" "o/r --bogus" "--last 3"; do
  reset
  # shellcheck disable=SC2086
  run $args
  [ "$RC" = 2 ] && ok || bad "Q6: '$args' must be rc 2, got $RC"
  [ "$(calls)" = 0 ] && ok || bad "Q6: '$args' must not call gh"
  grep -q 'usage' "$T/err" && ok || bad "Q6: '$args' must print usage to stderr"
done

# ══ Q7: --last N picks the newest by merged_at, not by list order ═══════════
reset
# updated_at order (the list order) is the reverse of merged_at order.
pr 1 $((NOW-14400)) $((NOW-0));    ev 1 labeled queued $((NOW-14400-60))
pr 2 $((NOW-10800)) $((NOW-100));  ev 2 labeled queued $((NOW-10800-120))
pr 3 $((NOW-7200))  $((NOW-200));  ev 3 labeled queued $((NOW-7200-180))
pr 4 $((NOW-3600))  $((NOW-300));  ev 4 labeled queued $((NOW-3600-240))
pr 5 $((NOW-0))     $((NOW-400));  ev 5 labeled queued $((NOW-300))
run o/r --last 2
[ "$(cut -f1 "$T/out" | head -n 2 | tr '\n' ,)" = "5,4," ] && ok || bad "Q7: want PRs 5,4 newest first: $(cat "$T/out")"
[ "$LAST" = "median_minutes=4.5 measured=2 unqueued=0 wanted=2 incomplete=0" ] && ok || bad "Q7: '$LAST'"
[ "$(calls)" = 3 ] && ok || bad "Q7: only the 2 picked PRs' events are read, got $(calls) calls"

# ══ Q8: re-labeled, and a label after merge → the re-add counts ════════════
reset
pr 1 $((NOW-0))
ev 1 labeled queued $((NOW-2400))
ev 1 unlabeled queued $((NOW-2100))
ev 1 labeled queued $((NOW-1500))
ev 1 labeled queued $((NOW+300))
run o/r --last 1
[ "$(row 1)" = "$(printf '1\t%s\t%s\t25\tqueued' "$(iso $((NOW-1500)))" "$(iso "$NOW")")" ] && ok || bad "Q8: '$(row 1)'"

# ══ Q9: a full events page may be truncated → measured, but incomplete ═════
reset
qpr 1 $((NOW-0)) 10
jq -c --arg c "$(iso $((NOW-5000)))" '. + [range(99) | {event:"commented", created_at:$c}]' \
  "$T/fx/events-1.json" > "$T/fx/e" && mv "$T/fx/e" "$T/fx/events-1.json"
run o/r --last 1
[ "$LAST" = "median_minutes=10 measured=1 unqueued=0 wanted=1 incomplete=1" ] && ok || bad "Q9: '$LAST'"

echo "mergify-queue-time: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
