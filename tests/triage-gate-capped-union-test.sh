#!/bin/bash
# tests/triage-gate-capped-union-test.sh — a capped listing is not a deletion.
#
# TK-314 put `capped` on every board list so the fleet can tell when
# LIST_FETCH_CAP clipped the page. project-9 crossed 500 cards on 2026-09-02
# and triage-gate.sh jq-stripped the flag, so 10 old done cards showed up as
# REMOVED. They still answered GET /tickets/{id} 200.
#
# Run from anywhere: tests/triage-gate-capped-union-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GATE="$DIR/bin/triage-gate.sh"

# 1. the live fetch must read .capped (not drop it on the floor).
#    Optional `?` is required: a raw ticket array (project-3 feature-board) makes
#    `.capped // false` stderr "Cannot index array with string \"capped\""
#    and run-triage.sh 2>> ALERTS.log turns that into a fleet alert every tick.
if grep -n -- ".capped? // false" "$GATE" >/dev/null; then
  ok
else
  bad 'triage-gate.sh does not read .capped? from the listing'
fi

# 2. it must union prior fingerprint rows whose id is missing from this page
#    via --slurpfile (prior fingerprint stays off jq argv).
if grep -F -- '--slurpfile prev' "$GATE" >/dev/null \
   && grep -F 'select($have[.id] | not)' "$GATE" >/dev/null; then
  ok
else
  bad 'triage-gate.sh missing capped-page union (--slurpfile prev / select($have[.id] | not))'
fi

# 3. union is gated on capped=true (do not keep ghosts on a complete listing).
if grep -n 'capped" = "true"' "$GATE" >/dev/null; then
  ok
else
  bad 'triage-gate.sh union is not gated on capped=true'
fi

# 4. behaviour lock: a 3-row capped page plus a 4-row prior fingerprint keeps
#    the overflow id and does not duplicate ids that are already on the page.
page='[{"id":"A","status":"todo","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"b","title":"new"},{"id":"B","status":"todo","waitingOn":null,"triageVerdict":null,"commentCount":1,"lastActivityAt":"b","title":"b"},{"id":"C","status":"done","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"a","title":"c"}]'
prior='{"product-board":[{"id":"B","status":"todo","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"a","title":"b-old"},{"id":"C","status":"done","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"a","title":"c"},{"id":"D","status":"done","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"z","title":"overflow"},{"id":"E","status":"done","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"y","title":"overflow-2"}]}'
got=$(jq -cS --arg bid product-board --slurpfile prev <(printf '%s' "$prior") '
  . as $page
  | ($prev[0][$bid] // []) as $old
  | ($page | map({key:.id, value:true}) | from_entries) as $have
  | $page + [$old[] | select($have[.id] | not)]
  | sort_by(.id)
' <<<"$page")
ids=$(jq -c '[.[].id]' <<<"$got")
n=$(jq 'length' <<<"$got")
# A is NEW, B keeps the PAGE title (not the stale prior), D+E overflow kept.
title_b=$(jq -r '.[] | select(.id=="B") | .title' <<<"$got")
[ "$n" = "5" ] && [ "$ids" = '["A","B","C","D","E"]' ] && [ "$title_b" = "b" ] && ok \
  || bad "union got n=$n ids=$ids title_b=$title_b (want 5 [A,B,C,D,E] title b)"

# 5. empty prior / missing board key is a no-op, not a crash.
got=$(jq -cS --arg bid product-board --slurpfile prev <(printf '%s' '{}') '
  . as $page
  | ($prev[0][$bid] // []) as $old
  | ($page | map({key:.id, value:true}) | from_entries) as $have
  | $page + [$old[] | select($have[.id] | not)]
  | sort_by(.id)
' <<<"$page")
n=$(jq 'length' <<<"$got")
[ "$n" = "3" ] && ok || bad "empty-prior union n=$n want=3"

# 6. a raw array listing must not stderr on .capped (the project-3-2 ALERTS flood).
arr_err=$(mktemp)
arr_out=$(jq -r '.capped? // false' <<<"[]" 2>"$arr_err")
if [ "$arr_out" = "false" ] && [ ! -s "$arr_err" ]; then
  ok
else
  bad "array listing: out=$arr_out err=$(tr '\n' ' ' <"$arr_err") (want false, no stderr)"
fi
rm -f "$arr_err"

# 7. wrapped {capped:true} still reads true (TK-314 path).
obj_out=$(jq -r '.capped? // false' <<<"{\"capped\":true,\"tickets\":[]}")
[ "$obj_out" = "true" ] && ok || bad "wrapped listing capped=true: out=$obj_out"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
