#!/bin/bash
# tests/pipeline-health-lead-unqueued.bh-3778-test.sh — bin/pipeline-health.sh
# pages a lead-cleared PR that never reached the merge queue (BH-3778).
#
# 2026-10-01: ten PRs sat up to 17h with `lead-verdict: success` on their head
# and no live queue entry, and nothing paged. The block is extracted VERBATIM
# between its markers and run with alert() stubbed to the real dedupe shape
# against a fake gh. Then the real RETRACT_NS is asked whether a cleared
# condition retracts its page.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> lead merge unqueued (BH-3778)' "$PH")
B=$(grep -c '^# <<< lead merge unqueued' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> lead merge unqueued (BH-3778)' … '# <<< lead merge unqueued' block (open=$A close=$B)"
awk '/^# >>> lead merge unqueued \(BH-3778\)/{f=1;next} /^# <<< lead merge unqueued/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no lead merge unqueued block to run"; echo "pipeline-health-lead-unqueued.bh-3778: $PASS passed, $((FAIL+1)) failed"; exit 1; }

RL=$(grep -m1 '^RETRACT_NS=' "$PH")
RNS=$( eval "$RL"; printf '%s' "$RETRACT_NS" )
grep -qE "^($RNS):" <<<"leadunqueued:example-org/proj-os#31:8747024e0b1c" \
  && ok || bad "leadunqueued is not in RETRACT_NS, so a queued or merged PR never retracts its page"

mkdir -p "$T/fakebin" "$T/s"
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SLUG=example-org/proj-os
# pr <num> <labels-csv> [draft] [base] — one open PR in the list
LIST=""
pr() {
  local l; l=$(jq -nc --arg s "$2" '$s | split(",") | map(select(length > 0)) | map({name:.})')
  LIST="$LIST${LIST:+,}$(jq -nc --argjson n "$1" --argjson l "$l" --argjson d "${3:-false}" --arg b "${4:-main}" \
    '{number:$n, draft:$d, head:{sha:("sha" + ($n|tostring) + "0000000000")}, base:{ref:$b, repo:{default_branch:"main"}}, labels:$l}')"
}
# st <num> <state|none|fail> [updated-epoch] — the head's combined status
st() {
  case "$2" in
    fail) echo fail > "$T/s/$1" ;;
    none) jq -nc '{state:"success", statuses:[{context:"ci/x", state:"success", updated_at:"2026-10-01T00:00:00Z"}]}' > "$T/s/$1" ;;
    *)    jq -nc --arg s "$2" --arg u "$(iso "$3")" \
            '{state:$s, statuses:[{context:"ci/x", state:"success", updated_at:$u}, {context:"lead-verdict", state:$s, updated_at:$u}]}' > "$T/s/$1" ;;
  esac
}
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CT/gh-calls.txt"
case "$*" in
  "api repos/example-org/proj-os/pulls?state=open&per_page=100") [ "${LIST_MODE:-ok}" = down ] && exit 1; cat "$CT/list.json" ;;
  "api repos/example-org/proj-os/commits/sha"*"/status")
    N=$(sed -n 's|.*/commits/sha\([0-9]*\)0000000000/status|\1|p' <<<"$*")
    [ "$(cat "$CT/s/$N" 2>/dev/null)" = fail ] && exit 1
    cat "$CT/s/$N" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
echo '{}' > "$T/dedup.json"

touch "$T/active.txt"
drive() { # drive [env...] — one run; alert() is the real dedupe shape over $T/dedup.json
  : > "$T/alerts.txt"; : > "$T/gh-calls.txt"; : > "$T/fired.txt"
  printf '[%s]' "$LIST" > "$T/list.json"
  ( export PATH="$T/fakebin:$PATH" CT="$T" LEAD_REVIEW_AUTO_REPOS="$SLUG" "$@"
    H="$T/h"; NOW="$NOW"; DEDUP="$T/dedup.json"; ACTIVE="$T/active.txt"; FIRED="$T/fired.txt"
    gh_budget_low() { [ "${BUDGET_LOW:-0}" = 1 ]; }
    [ "${KNOB_FAIL:-0}" = 1 ] && lane_env_apply() { exit 75; }
    alert() { local last
      echo "$2" >> "$FIRED"
      last=$(jq -r --arg k "$2" '.[$k] // 0' "$DEDUP")
      [ $(( NOW - last )) -lt "$1" ] && return 0
      jq --arg k "$2" --argjson t "$NOW" '.[$k]=$t' "$DEDUP" > "$DEDUP.tmp" && mv "$DEDUP.tmp" "$DEDUP"
      printf '%s|%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    # shellcheck disable=SC1090
    . "$T/block.sh"; echo reached ) > "$T/drive.out" 2>&1
}

# P1 — merge-queue label, lead-verdict success 45m ago, no queued label: one page.
pr 31 merge-queue; st 31 success $((NOW-2700))
# P3 negatives
pr 32 merge-queue,queued;    st 32 success $((NOW-2700))
pr 33 merge-queue,checking;  st 33 success $((NOW-2700))
pr 34 "";                    st 34 pending $((NOW-2700))
pr 35 "";                    st 35 failure $((NOW-2700))
pr 36 "";                    st 36 none
pr 37 "" true;               st 37 success $((NOW-2700))
pr 38 "" false ticket/x;     st 38 success $((NOW-2700))
pr 39 "";                    st 39 success $((NOW-600))
pr 40 "";                    st 40 fail
drive
grep -qx reached "$T/drive.out" && ok || bad "the block did not run to its end: $(cat "$T/drive.out")"
grep -q "^leadunqueued:$SLUG#31:sha310000000|$SLUG #31 has lead-verdict success on sha310000000 for 45m and is not in the merge queue (labels: merge-queue); .* https://github.com/$SLUG/pull/31$" "$T/alerts.txt" \
  && ok || bad "P1: a 45m lead-verdict success with no queued label must page once naming the URL, the age and the labels: $(cat "$T/alerts.txt")"
[ "$(wc -l < "$T/alerts.txt")" = 1 ] && ok || bad "P1/P3: exactly one page expected, got: $(cat "$T/alerts.txt")"
for n in 32 33 34 35 36 37 38 39 40; do
  grep -q "#$n:" "$T/alerts.txt" && bad "P3: PR #$n must not page: $(grep "#$n:" "$T/alerts.txt")" || ok
done
grep -qE 'commits/sha3[23]0000000000/status' "$T/gh-calls.txt" && bad "P3: a PR Mergify holds (queued/checking) costs no status read" || ok
grep -qE 'commits/sha3[78]0000000000/status' "$T/gh-calls.txt" && bad "P3: a draft or non-main PR costs no status read" || ok

# P2 — an immediate re-run: no second page.
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "P2: a second run must not page again: $(cat "$T/alerts.txt")"

# P4 — the threshold is the settings row: at 60 the 45m status is young; a junk
#      value falls back to 30.
echo '{}' > "$T/dedup.json"
drive LEAD_MERGE_UNQUEUED_MIN=60
[ ! -s "$T/alerts.txt" ] && ok || bad "P4: LEAD_MERGE_UNQUEUED_MIN=60 still paged a 45m status: $(cat "$T/alerts.txt")"
drive LEAD_MERGE_UNQUEUED_MIN=abc
grep -q "^leadunqueued:$SLUG#31:" "$T/alerts.txt" && ok || bad "P4: a junk LEAD_MERGE_UNQUEUED_MIN must fall back to 30: $(cat "$T/alerts.txt")"

# P3b — the list read fails: no page, and the block still ends.
echo '{}' > "$T/dedup.json"
drive LIST_MODE=down
[ ! -s "$T/alerts.txt" ] && ok || bad "P3b: a failed list read paged: $(cat "$T/alerts.txt")"
grep -qx reached "$T/drive.out" && ok || bad "P3b: the block did not run to its end on a failed list read"

# P6 — no watched repos: nothing read at all.
drive LEAD_REVIEW_AUTO_REPOS=""
[ ! -s "$T/gh-calls.txt" ] && ok || bad "P6: an empty LEAD_REVIEW_AUTO_REPOS must cost no gh call: $(cat "$T/gh-calls.txt")"

# P7 — the condition clears (Mergify took it): the real epilogue retracts.
LIST=""; pr 31 merge-queue,queued; st 31 success $((NOW-2700))
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "P7: a queued PR must stop paging: $(cat "$T/alerts.txt")"
sed -n '/^# ── Retraction epilogue/,/^rm -f "\$FIRED"$/p' "$PH" > "$T/epi.sh"
if [ -s "$T/epi.sh" ]; then
  mkdir -p "$T/eh/state" "$T/eh/logs" "$T/eh/bin"
  printf '#!/bin/bash\nexit 0\n' > "$T/eh/bin/beat.sh"; chmod +x "$T/eh/bin/beat.sh"
  K="leadunqueued:$SLUG#31:sha310000000"
  echo "$K" > "$T/eh/state/health-active.txt"
  : > "$T/eh/fired"; jq -nc --arg k "$K" '{($k):1}' > "$T/eh/dedup.json"
  ( H="$T/eh"; FIRED="$T/eh/fired"; ACTIVE="$T/eh/state/health-active.txt"; DEDUP="$T/eh/dedup.json"; eval "$RL"
    STAMP() { date -u +%FT%TZ; }; alert_emit() { printf '%s\n' "$*" >> "$T/eh/emitted"; }
    # shellcheck disable=SC1090
    . "$T/epi.sh" ) >/dev/null 2>&1
  grep -qF "RESOLVED $K" "$T/eh/emitted" 2>/dev/null \
    && ok || bad "P7: the retraction epilogue did not RESOLVE $K ($(cat "$T/eh/emitted" 2>/dev/null))"
else
  bad "P7: no '# ── Retraction epilogue' section found in bin/pipeline-health.sh to drive"
fi

# P8 — a skip is not a clear. #31 pages, then a run that cannot read it (the
#      status read, the list read, the budget gate, a knob that fails closed,
#      or #31 sitting past the 30-PR cap) must carry its key: the real epilogue
#      RESOLVEs nothing, and the next readable run does not page it again.
epi() { # the real retraction epilogue over $T/active.txt, $T/fired.txt, $T/dedup.json
  : > "$T/emitted"; mkdir -p "$T/eh/state" "$T/eh/logs" "$T/eh/bin"
  printf '#!/bin/bash\nexit 0\n' > "$T/eh/bin/beat.sh"; chmod +x "$T/eh/bin/beat.sh"
  ( H="$T/eh"; FIRED="$T/fired.txt"; ACTIVE="$T/active.txt"; DEDUP="$T/dedup.json"; eval "$RL"
    STAMP() { date -u +%FT%TZ; }; alert_emit() { printf '%s\n' "$*" >> "$T/emitted"; }
    # shellcheck disable=SC1090
    . "$T/epi.sh" ) >/dev/null 2>&1
}
K="leadunqueued:$SLUG#31:sha310000000"
LIST=""; pr 31 merge-queue; st 31 success $((NOW-2700))
echo '{}' > "$T/dedup.json"; : > "$T/active.txt"
drive; epi
grep -qxF "$K" "$T/active.txt" && ok || bad "P8: #31 must page and stand active: alerts=$(cat "$T/alerts.txt") active=$(cat "$T/active.txt")"
p8() { # p8 <label> [env...] — one unreadable run, then one readable run
  local lbl=$1; shift
  drive "$@"; epi
  grep -qF "RESOLVED $K" "$T/emitted" && bad "P8 ($lbl): an unread PR was RESOLVED: $(cat "$T/emitted")" || ok
  grep -qxF "$K" "$T/active.txt" && ok || bad "P8 ($lbl): the key must stay active across an unread run: $(cat "$T/active.txt")"
  [ "$(jq -r --arg k "$K" '.[$k] // 0' "$T/dedup.json")" != 0 ] && ok || bad "P8 ($lbl): the dedupe stamp was cleared"
  st 31 success $((NOW-2700)); LIST=""; pr 31 merge-queue
  drive; epi
  [ ! -s "$T/alerts.txt" ] && ok || bad "P8 ($lbl): the same head paged twice: $(cat "$T/alerts.txt")"
  grep -qF "RESOLVED $K" "$T/emitted" && bad "P8 ($lbl): a still-stuck PR was RESOLVED: $(cat "$T/emitted")" || ok
}
st 31 fail;  p8 "status read fails"
p8 "list read fails" LIST_MODE=down
p8 "budget gate" BUDGET_LOW=1
p8 "knob fails closed" KNOB_FAIL=1
LIST=""; for n in $(seq 101 130); do pr "$n" ""; st "$n" pending $((NOW-60)); done; pr 31 merge-queue
p8 "past the 30-PR cap"
# …and a real clear still retracts.
LIST=""; pr 31 merge-queue,queued
drive; epi
grep -qF "RESOLVED $K" "$T/emitted" && ok || bad "P8: a queued PR must still RESOLVE: $(cat "$T/emitted")"

# P5 — more than 30 candidates: the cut is named, and exactly 30 status reads.
LIST=""
for n in $(seq 101 131); do pr "$n" ""; st "$n" pending $((NOW-60)); done
echo '{}' > "$T/dedup.json"
drive
grep -q "^leadunqueued:$SLUG:page-cut|$SLUG: the lead-merge-unqueued check has more than 30 open PRs" "$T/alerts.txt" \
  && ok || bad "P5: a 31-PR list must name its cut: $(head -3 "$T/alerts.txt")"
[ "$(grep -c '/status$' "$T/gh-calls.txt")" = 30 ] && ok || bad "P5: the cap is 30 status reads per repo (got $(grep -c '/status$' "$T/gh-calls.txt"))"

echo "pipeline-health-lead-unqueued.bh-3778: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
