#!/bin/bash
# tests/conductor-pause.bh-1672-test.sh — the merge conductor honours a merges
# pause (BH-1684, the BH-1672.3 slice), driven through the WHOLE script.
#
# A merges pause is a row in the pauses cache (state/pauses.json, read by
# bin/lib/pause.sh). Under a live row the conductor sets MERGES=0: fleet-wide
# for a fleet row, inside that project's own subshell for a project row. It
# never sets KILL, so the mode reads `actions` and not `kill-switch`, and every
# TICK line of a paused project carries the `PAUSED(merges) ` prefix.
#
# Cases, each in its own scratch tree so no state leaks between them:
#   F  fleet merges row: no merge anywhere, TICK prefixed, no kill-switch mode
#   P  demo-os row only: demo-os does not merge, issuer DOES
#   E  the same tree after PAUSE_NOW passes expiry: no PAUSED(, the merge runs
#   H  demo-os held (BH-1465) plus a live row: the held line is prefixed
#   N  an ended row, a reviews row, another project's row, a garbage expires_at,
#      an empty list and no cache at all: each still merges, with no label
#   R  pause_refresh runs exactly once per tick
#   M  the published mode: actions under a fleet row (KILL and ACTIONS untouched),
#      merge under a project row and after expiry
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conductor-pause.bh-1672-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/lib/pause.sh" ] || exit 1   # impact: this suite drives the whole tick through bin/lib/pause.sh
H1=aaaaaaaa1111; H2=cccccccc7777
NOW=1790208000                        # 2026-09-24T00:00:00Z
FUT="2026-09-24T21:00:00Z"            # NOW + 21h
PAST="2026-09-23T00:00:00Z"
EXP_EPOCH=1790283600                  # FUT as an epoch

# setup <case> — a fresh scratch harness with two READY PRs: demo-os#11 and
# issuer#7, both approved at their head, clean and green, merge flags on.
setup() {
  C="$T/$1"; mkdir -p "$C"
  fx_mc_harness "$DIR" "$C" >/dev/null || exit 1
  fx_conductor_tick "$DIR" "$C" || exit 1
  cp "$DIR/bin/lib/pause.sh" "$C/h/bin/lib/pause.sh" || exit 1
  # The suite drives the hand-written cache, never the network: when BH-1683
  # fills pause_refresh in, this override keeps it a counter.
  printf '\npause_refresh(){ echo x >> "%s/refresh.calls"; return 0; }\n' "$C" >> "$C/h/bin/lib/pause.sh"
  # A stand-in lane gate: only the per-project hold, driven by a file.
  cat > "$C/h/bin/lib/lane-gate.sh" <<EOF
LANE_HELD_FLAG=""
lane_project_held() { [ -f "$C/held-\$2" ] || return 1; LANE_HELD_FLAG="lane-off-\$1.\$2"; return 0; }
EOF
  printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer https://issuer.example /api/board 3 box-issuer\n' > "$C/h/fleet.conf"
  : > "$C/h/env/global.env"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$C/h/bin/agent-call.sh"; chmod +x "$C/h/bin/agent-call.sh"
  touch "$C/h/flags/merge-conductor-actions" "$C/h/flags/merge-conductor-merge"
  local b
  b="$C/h/builds/demo-os-TK-11-202609120001"; mkdir -p "$b"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$b/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$b/review.md"; echo "$H1" > "$b/reviewed-sha"
  b="$C/h/builds/issuer-IS-7-202609120002"; mkdir -p "$b"
  echo "PR_CREATED https://github.com/example-org/issuer/pull/7" > "$b/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$b/review.md"; echo "$H2" > "$b/reviewed-sha"
  cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$C/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge https://github.com/example-org/demo-os/pull/11 --squash --match-head-commit $H1"*)
    echo demo-os#11 >> "$C/merge-calls.txt"; touch "$C/merged11"; exit 0 ;;
  *"pr merge https://github.com/example-org/issuer/pull/7 --squash --match-head-commit $H2"*)
    echo issuer#7 >> "$C/merge-calls.txt"; touch "$C/merged7"; exit 0 ;;
  *"pr merge"*) echo "wrong merge form: \$*" >> "$C/gh-writes.txt"; exit 1 ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11")
    if [ -f "$C/merged11" ]; then restpr MERGED "$H1" ticket/TK-11 main "" MERGEABLE CLEAN app/cromford dddddddd1111
    else restpr OPEN "$H1" ticket/TK-11 main "" MERGEABLE CLEAN app/cromford ""; fi ;;
  *"api -i -X GET repos/example-org/issuer/pulls/7")
    if [ -f "$C/merged7" ]; then restpr MERGED "$H2" ticket/is-7 main "" MERGEABLE CLEAN app/cromford eeeeeeee7777
    else restpr OPEN "$H2" ticket/is-7 main "" MERGEABLE CLEAN app/cromford ""; fi ;;
  *"pr list -R example-org/demo-os --state open"*)
    if [ -f "$C/merged11" ]; then echo "[]"; else cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    fi ;;
  *"pr list -R example-org/issuer --state open"*)
    if [ -f "$C/merged7" ]; then echo "[]"; else cat <<'J'
[{"number":7,"url":"https://github.com/example-org/issuer/pull/7","headRefOid":"$H2","headRefName":"ticket/is-7","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    fi ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$C/fakebin/gh"
  cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "PUT "*/api/settings) printf '%s\n' "\$D" >> "$C/settings-puts.txt"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
  chmod +x "$C/fakebin/curl"
  : > "$C/merge-calls.txt"; : > "$C/gh-writes.txt"
}
# row <scope> <what> <expires_at> [ended_at] — one cache row as JSON
row() {
  jq -nc --arg s "$1" --arg w "$2" --arg e "$3" --arg d "${4:-}" \
    '{id:1,scope:$s,what:$w,reason:"runaway fix",actor:"operator",created_at:"2026-09-21T21:00:00Z",
      expires_at:$e,ended_at:(if $d == "" then null else $d end),end_reason:null}'
}
cache() { jq -sc '{pauses:.,truncated:false}' > "$C/h/state/pauses.json"; }
run_tick() { # run_tick [PAUSE_NOW]
  local m; m=$(nlines "$C/h/logs/merge-conductor.log")
  ( cd "$C" && PATH="$C/fakebin:$PATH" HARNESS="$C/h" HARNESS_SECRET=x PAUSE_NOW="${1:-$NOW}" MC_MERGE_SETTLE=0 \
      bash "$C/h/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$C/tick.err"; }
  TICKLOG=$(tail -n +"$((m+1))" "$C/h/logs/merge-conductor.log" 2>/dev/null)
}
# published_mode — the merge-conductor.mode value the LAST tick published
# through conductor_mode_publish (the fake curl records every settings PUT).
published_mode() {
  jq -r 'select(.key == "merge-conductor.mode") | .value' "$C/settings-puts.txt" 2>/dev/null | tail -1
}
nlines() { local n; n=$( { wc -l < "$1"; } 2>/dev/null ) || n=0; echo "${n:-0}"; }
merged() { grep -qx "$1" "$C/merge-calls.txt"; }

# ---- F. a fleet merges row ---------------------------------------------------
setup F; row fleet merges "$FUT" | cache; run_tick
merged demo-os#11 && bad "F: a fleet merges pause must stop demo-os#11 merging" || ok
merged issuer#7 && bad "F: a fleet merges pause must stop issuer#7 merging" || ok
grep -q 'PAUSED(merges) TICK demo-os tick=' <<<"$TICKLOG" && ok || bad "F: the demo-os TICK line must carry 'PAUSED(merges) ' (log: $(grep 'TICK' <<<"$TICKLOG"))"
grep -q 'PAUSED(merges) TICK issuer tick=' <<<"$TICKLOG" && ok || bad "F: the issuer TICK line must carry 'PAUSED(merges) '"
grep -q 'PAUSED(merges) fleet' <<<"$TICKLOG" && ok || bad "F: a fleet pause must say so once in the log"
grep -q 'mode=kill-switch' "$C/h/logs/merge-conductor.log" && bad "F: a pause must never read as the kill switch" || ok
[ -f "$C/h/flags/automerge-disabled" ] && bad "F: a pause must not raise automerge-disabled" || ok
# The pause lowers MERGES and nothing else: ACTIONS stays on, so the tick's
# mode is `actions` (not observe, not kill-switch) and rebases, re-reviews and
# the other actions still run.
[ "$(published_mode)" = actions ] && ok || bad "F: under a fleet merges pause the tick must publish mode=actions (got '$(published_mode)')"
[ -s "$C/gh-writes.txt" ] && bad "F: $(cat "$C/gh-writes.txt")" || ok
[ "$(nlines "$C/refresh.calls")" -eq 1 ] && ok || bad "R: pause_refresh must run exactly once per tick (got $(nlines "$C/refresh.calls"))"
# ---- E. the same tree, the clock past expiry ---------------------------------
run_tick $((EXP_EPOCH + 1))
grep -q 'PAUSED(' <<<"$TICKLOG" && bad "E: an expired pause must print no PAUSED( label (got: $(grep 'PAUSED(' <<<"$TICKLOG"))" || ok
merged demo-os#11 && ok || bad "E: after expiry demo-os#11 must merge with no restart"
merged issuer#7 && ok || bad "E: after expiry issuer#7 must merge"
[ "$(published_mode)" = merge ] && ok || bad "E: after expiry the tick must publish mode=merge again (got '$(published_mode)')"
[ "$(nlines "$C/refresh.calls")" -eq 2 ] && ok || bad "R: two ticks, two refreshes (got $(nlines "$C/refresh.calls"))"

# ---- P. a demo-os row only ---------------------------------------------------
setup P; row demo-os merges "$FUT" | cache; run_tick
merged demo-os#11 && bad "P: a demo-os merges pause must stop demo-os#11 merging" || ok
merged issuer#7 && ok || bad "P: a demo-os pause must NOT stop issuer#7 merging (log: $(grep -i 'issuer' <<<"$TICKLOG" | tail -5))"
grep -q 'PAUSED(merges) TICK demo-os tick=' <<<"$TICKLOG" && ok || bad "P: demo-os's TICK line must carry the prefix"
grep -q 'PAUSED([a-z,]*) TICK issuer' <<<"$TICKLOG" && bad "P: issuer's TICK line must carry no prefix" || ok
grep -q 'PAUSED(merges) fleet' <<<"$TICKLOG" && bad "P: a project row is not a fleet pause" || ok
grep -q 'mode=kill-switch' "$C/h/logs/merge-conductor.log" && bad "P: a pause must never read as the kill switch" || ok
[ "$(published_mode)" = merge ] && ok || bad "P: a project row must not lower the fleet mode (got '$(published_mode)')"

# ---- H. held plus a live row -------------------------------------------------
setup H; row demo-os merges "$FUT" | cache; touch "$C/held-demo-os"; run_tick
grep -q 'PAUSED(merges) TICK demo-os held' <<<"$TICKLOG" && ok || bad "H: the held line must carry the prefix (log: $(grep 'held' <<<"$TICKLOG"))"
merged demo-os#11 && bad "H: a held project merges nothing" || ok
merged issuer#7 && ok || bad "H: issuer is neither held nor paused and must merge"

# ---- N. rows and caches that must NOT pause merges ---------------------------
neg() { # neg <name> — the cache is already written; demo-os must merge, no label
  run_tick
  merged demo-os#11 && ok || bad "N/$1: demo-os#11 must still merge"
  grep -q 'PAUSED(merges)' <<<"$TICKLOG" && bad "N/$1: no merges label (got: $(grep 'PAUSED(' <<<"$TICKLOG"))" || ok
}
setup Nended;   row fleet merges "$FUT" "$PAST" | cache; neg ended
setup Nreviews; row fleet reviews "$FUT" | cache; neg reviews-row
grep -q 'PAUSED(reviews) TICK demo-os tick=' <<<"$TICKLOG" && ok || bad "N/reviews-row: the TICK label names the live reviews pause"
setup Nother;   row other-os merges "$FUT" | cache; neg other-project
setup Ngarbage; row fleet merges "not-a-date" | cache; neg garbage-expiry
setup Nempty;   printf '{"pauses":[],"truncated":false}\n' > "$C/h/state/pauses.json"; neg empty-list
setup Nnone;    rm -f "$C/h/state/pauses.json"; neg no-cache
setup Njunk;    echo 'not json' > "$C/h/state/pauses.json"; neg garbage-json

echo "conductor-pause.bh-1672-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
