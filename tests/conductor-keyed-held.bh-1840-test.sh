#!/bin/bash
# tests/conductor-keyed-held.bh-1840-test.sh — a keyed tick loads the held-page
# cache so a woken PR's held row is paged by the cron tick's capped flush, not
# directly by mc_budget_check (BH-1840, from BH-1831.2).
#
# The real bin/merge-conductor.sh over repos a (#7, #8) and b (#3) in actions
# mode, with a fake jobs worker serving GET /api/conductor/held from $HELD_JSON
# (or a 500 under HELD_FAIL=1) and recording every request to $REQ_SINK.
#   A. keyed a#7 tick with a#7 held: no page, `alerted` unspent, no release, no flush.
#   B. the unkeyed tick after it pages a#7 once, with "held since", releases it
#      and spends `alerted`.
#   C. MC_FLUSH_MAX=1 with a#7 and b#3 held: the keyed tick sends nothing, the
#      unkeyed tick sends exactly one and logs "1 held pages remain".
#   D. held list unreadable (500): the keyed tick fails open to paging a#7
#      directly, with the "unreadable" log line.
#   E. held row on a stale head: no cache match, so the keyed tick pages a#7 for
#      its current state, and still sends no release.
# D1 mutations (both turn case A red): drop `[ -n "$load_only" ] && return 0`
# in mc_hold_tick_begin (the keyed tick flushes and releases); drop the keyed
# else-arm at the mc_hold_tick_begin call in bin/merge-conductor.sh (a direct page).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-keyed-held.bh-1840-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin" "$T/h/bin/lib" "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc" \
         "$T/h/env" "$T/h/logs" "$T/h/locks" "$T/h/state" "$T/h/calls" \
         "$T/h/flags" "$T/fakebin"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/h/env/global.env"
# BH-1625: the conductor reads the APPROVE records below through the shared
# verdict reader, which a scratch harness does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_install "$T/h" || exit 1

cp "$DIR/bin/merge-conductor.sh"   "$T/h/bin/merge-conductor.sh"
cp "$DIR/bin/jobs-client.sh"       "$T/h/bin/jobs-client.sh"
cp "$DIR/bin/lib/env-path.sh"      "$T/h/bin/lib/env-path.sh"
cp "$DIR"/bin/lib/jobs/*.sh        "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/revdep-lib.sh"    "$T/h/bin/lib/revdep-lib.sh"
cp "$DIR/bin/lib/gh-budget.sh"     "$T/h/bin/lib/gh-budget.sh"
cp "$DIR/bin/lib/heartbeat.sh"     "$T/h/bin/lib/heartbeat.sh"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/merge-conductor-lib.sh"
cp "$DIR/bin/lib/gh-rest.sh"       "$T/h/bin/lib/gh-rest.sh"
cp "$DIR/bin/lib/gh-pr-list.sh"    "$T/h/bin/lib/gh-pr-list.sh"
cp "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/main-red-gate.sh"
cp "$DIR"/bin/lib/mc/*.sh          "$T/h/bin/lib/mc/"
cp "$DIR/bin/fleet-conf.sh"        "$T/h/bin/fleet-conf.sh"
cp "$DIR/bin/box-for.sh"           "$T/h/bin/box-for.sh"
chmod +x "$T/h/bin/merge-conductor.sh" "$T/h/bin/jobs-client.sh" \
         "$T/h/bin/fleet-conf.sh" "$T/h/bin/box-for.sh"

printf 'a example-org/a https://a.example /api/board 2 local\nb example-org/b https://b.example /api/board 2 local\n' > "$T/h/fleet.conf"
# The flush runs in merge|actions alike; actions arms no land/merge side lanes.
touch "$T/h/flags/merge-conductor-actions"

cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"
chmod +x "$T/fakebin/restpr"

H1=aaaaaaaa1111; H2=bbbbbbbb2222; H3=cccccccc3333

cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "" > "$4"; exit 0
SH
cat > "$T/h/bin/batch-resolve.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh" "$T/h/bin/batch-resolve.sh"

# A build record per PR, each APPROVE bound to that PR's own head, so nothing is
# HEAD_MOVED: with CI green every PR classifies READY, the state whose age page
# goes through mc_budget_check's hold (a HEAD_MOVED page is a state note). Since
# BH-4717 READY's budget age is a state note too by default, so run_mc pins the
# pre-BH-4717 note set: this suite is about the hold, which did not change.
mkrec() { # mkrec <dir> <repo> <pr number> <reviewed sha>
  mkdir -p "$T/h/builds/$1"
  echo "PR_CREATED https://github.com/example-org/$2/pull/$3" > "$T/h/builds/$1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/$1/review.md"
  echo "$4" > "$T/h/builds/$1/reviewed-sha"
}
mkrec a-TK-7-202609230001 a 7 "$H1"
mkrec a-TK-8-202609230002 a 8 "$H2"
mkrec b-TK-3-202609230003 b 3 "$H3"

cat > "$T/fakebin/git" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/fakebin/git"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\${GH_CALLS:-/dev/null}"
case "\$*" in
  *"pr list -R example-org/a --state open"*)
    cat <<'JR'
[
 {"number":7,"url":"https://github.com/example-org/a/pull/7","headRefOid":"$H1","headRefName":"ticket/TK-7","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false},
 {"number":8,"url":"https://github.com/example-org/a/pull/8","headRefOid":"$H2","headRefName":"ticket/TK-8","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false}
]
JR
    ;;
  *"pr list -R example-org/a --state closed"*|*"repos/example-org/a/pulls?state=closed"*) printf 'HTTP/2.0 200\\r\\n\\r\\n[]' ;;
  *"pr list -R example-org/b --state open"*)
    cat <<'JR'
[{"number":3,"url":"https://github.com/example-org/b/pull/3","headRefOid":"$H3","headRefName":"ticket/TK-3","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false}]
JR
    ;;
  *"pr list -R example-org/b --state closed"*|*"repos/example-org/b/pulls?state=closed"*) printf 'HTTP/2.0 200\\r\\n\\r\\n[]' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/a/pulls/7"*) restpr OPEN "$H1" ticket/TK-7 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"api -i -X GET repos/example-org/a/pulls/8"*) restpr OPEN "$H2" ticket/TK-8 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"api -i -X GET repos/example-org/b/pulls/3"*) restpr OPEN "$H3" ticket/TK-3 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"actions/runs?head_sha=$H1"*|*"actions/runs?head_sha=$H2"*|*"actions/runs?head_sha=$H3"*) echo 'completed|success' | restpr --runs - ;;
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\\n' ;;
  *"pr view"*) echo '{"body":"harness build"}' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\\n+const a = 1;\\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The open-PR list is REST since BH-1585; the bridge answers the REST reads from
# the `pr list --state open` description above, as in every sibling conductor suite.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/conductor/held*)
    if [ "${HELD_FAIL:-0}" = 1 ]; then printf '{"error":"boom"}\n500\n'
    elif [ -s "${HELD_JSON:-}" ]; then cat "$HELD_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "POST "*/api/conductor/held/release) printf '{"released":1}\n200\n' ;;
  "PUT "*/api/conductor/held) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"

PST="$T/h/state/merge-conductor/pr-state.tsv"
state_of()   { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$PST" 2>/dev/null; }
alerted_of() { awk -F'\t' -v k="$1" '$1==k {print $6; exit}' "$PST" 2>/dev/null; }
mclog() { cat "$T/h/logs/merge-conductor.log" 2>/dev/null; }
alerts() { cat "$T/h/logs/ALERTS.log" 2>/dev/null; }
# Lines of ALERTS.log about one PR (the key is followed by a space in mc_alert's text).
# A count read through cat, so a missing file is 0 rather than an empty string.
npages() { cat "$T/h/logs/ALERTS.log" 2>/dev/null | grep -cF "conductor: $1 "; }
nrelease() { cat "$T/req.txt" 2>/dev/null | grep -c "^POST .*api/conductor/held/release .*\"repo\":\"$1\",\"number\":$2,"; }

reset_mc() {
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs/merge-conductor.log" "$T/h/logs/ALERTS.log" \
         "$T/gh-calls.txt" "$T/req.txt" "$T/mc.err"
  mkdir -p "$T/h/state/merge-conductor" "$T/h/logs"
  : > "$T/h/logs/merge-conductor.log"
  : > "$T/gh-calls.txt"
  : > "$T/req.txt"
}

run_mc() {
  (
    cd "$T" &&
    export PATH="$T/fakebin:$T/h/bin:$PATH" &&
    HARNESS="$T/h" HARNESS_SECRET=x REQ_SINK="$T/req.txt" \
      GH_CALLS="$T/gh-calls.txt" \
      FLEET_CONF="$T/h/fleet.conf" MC_REHYDRATE=0 LAND_FIRE=0 GH_TOKEN=fixture-token \
      MC_STATE_NOTE_STATES="HEAD_MOVED STACKED_WAIT NEEDS_REBASE REBASING" \
      "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/mc.err"
  ) || { echo "mc rc=$? stderr:"; cat "$T/mc.err"; }
}

# THE HELD ROW MUST MATCH WHAT THE FIXTURE CLASSIFIES a#7 INTO, or case A would
# pass on a cache miss that has nothing to do with the fix. Read it off one plain
# keyed tick rather than hardcoding it.
reset_mc
run_mc env MC_ONLY_PR=example-org/a#7
ST7=$(state_of 'example-org/a#7'); ST3=READY
[ -n "$ST7" ] && ok || { bad "setup: the fixture did not classify a#7: $(mclog)"; echo "conductor-keyed-held.bh-1840-test: $PASS pass, $FAIL fail"; exit 1; }

# AGED PAST READY's 15m BUDGET AND SHORT OF ITS 20m STUCK TTL (mc_budget,
# mc_stuck_ttl): the only pager this row can reach is mc_budget_check's, the one
# this ticket is about. An older row would also page through mc_stuck_check.
SINCE=$(( $(date +%s) - 1000 ))
seed_row() { # <key> <state> <head> <num>
  printf '%s\t%s\t%s\t%s\t-\t-\tclean\thttps://github.com/%s/pull/%s\n' "$1" "$2" "$SINCE" "$3" "${1%#*}" "$4" >> "$PST"
}
held_row() { # <repo> <num> <state> <head> <text>
  jq -nc --arg r "$1" --argjson n "$2" --arg s "$3" --arg h "$4" --arg t "$5" --arg since "$SINCE" \
    '{repo:$r,number:$n,state:$s,head:$h,kind:"BUDGET",text:$t,mark:($s+"@"+$since),mode:"kill-switch",
      first_held_at:"2026-09-23T00:00:00Z",last_seen_at:"2026-09-23T00:00:00Z"}'
}
held_json() { jq -sc '{rows:., n_total:length}' > "$T/held.json"; }

# A. A keyed a#7 tick with a#7's page held sends nothing and spends nothing.
reset_mc
seed_row example-org/a#7 "$ST7" "$H1" 7
held_row example-org/a 7 "$ST7" "$H1" "16m in $ST7: held-a7-page" | held_json
run_mc env MC_ONLY_PR=example-org/a#7 HELD_JSON="$T/held.json"
[ "$(state_of 'example-org/a#7')" = "$ST7" ] && ok || bad "case A: a#7 left $ST7 (fixture drift): $(state_of 'example-org/a#7')"
[ "$(npages 'example-org/a#7')" = 0 ] && ok || bad "case A: the keyed tick paged a#7 directly: $(alerts)"
case "$(alerted_of 'example-org/a#7')" in ''|-) ok ;; *) bad "case A: the keyed tick spent a#7's alerted mark: $(alerted_of 'example-org/a#7')" ;; esac
grep -q 'POST .*api/conductor/held/release' "$T/req.txt" && bad "case A: the keyed tick released a held row: $(grep release "$T/req.txt")" || ok
grep -q 'flushed' "$T/h/logs/merge-conductor.log" && bad "case A: the keyed tick ran the flush: $(mclog)" || ok
grep -q 'GET .*api/conductor/held' "$T/req.txt" && ok || bad "case A: the keyed tick never read the held list (the cache it defers to)"

# B. The unkeyed tick after it pages a#7 once, with the held-since text, and releases it.
run_mc env HELD_JSON="$T/held.json"
grep -q 'example-org/a#7 BUDGET flushed' "$T/h/logs/merge-conductor.log" && ok || bad "case B: the cron tick did not flush a#7: $(mclog)"
[ "$(npages 'example-org/a#7')" = 1 ] && ok || bad "case B: expected exactly one a#7 page, got: $(alerts)"
grep -F 'conductor: example-org/a#7 ' "$T/h/logs/ALERTS.log" 2>/dev/null | grep -q 'held since 2026-09-23T00:00:00Z under mode=kill-switch' && ok \
  || bad "case B: a#7's page lacks the held-since text: $(alerts)"
[ "$(nrelease example-org/a 7)" = 1 ] && ok || bad "case B: expected one release POST for a#7: $(grep release "$T/req.txt")"
[ "$(alerted_of 'example-org/a#7')" = "$ST7@$SINCE" ] && ok || bad "case B: a#7's alerted mark is not spent: '$(alerted_of 'example-org/a#7')'"
grep -q 'not paged again, retrying the release only' "$T/h/logs/merge-conductor.log" && bad "case B: the flush found a#7 already paged: $(mclog)" || ok

# C. MC_FLUSH_MAX=1, two held rows: the keyed tick sends none, the cron tick one.
reset_mc
seed_row example-org/a#7 "$ST7" "$H1" 7
seed_row example-org/b#3 "$ST3" "$H3" 3
{ held_row example-org/a 7 "$ST7" "$H1" "16m in $ST7: held-a7-page"
  held_row example-org/b 3 "$ST3" "$H3" "16m in $ST3: held-b3-page"; } | held_json
run_mc env MC_ONLY_PR=example-org/a#7 HELD_JSON="$T/held.json" MC_FLUSH_MAX=1
[ -z "$(alerts)" ] && ok || bad "case C: the keyed tick sent a page: $(alerts)"
run_mc env HELD_JSON="$T/held.json" MC_FLUSH_MAX=1
[ "$(grep -c 'held since' "$T/h/logs/ALERTS.log" 2>/dev/null || true)" = 1 ] && ok || bad "case C: expected exactly one held page from the cron tick: $(alerts)"
[ "$(npages 'example-org/b#3')" = 0 ] && ok || bad "case C: the capped row b#3 was paged anyway: $(alerts)"
grep -q 'flush: 1 held pages remain, next tick' "$T/h/logs/merge-conductor.log" && ok || bad "case C: no 'flush: 1 held pages remain' line: $(mclog)"

# D. Held list unreadable: the keyed tick fails open to paging a#7 directly.
reset_mc
seed_row example-org/a#7 "$ST7" "$H1" 7
run_mc env MC_ONLY_PR=example-org/a#7 HELD_FAIL=1
[ "$(npages 'example-org/a#7')" = 1 ] && ok || bad "case D: an unreadable held list must page a#7 directly: $(alerts)"
grep -q 'held since' <<<"$(grep -F 'conductor: example-org/a#7 ' "$T/h/logs/ALERTS.log" 2>/dev/null)" && bad "case D: a direct page carried held-since text" || ok
grep -q 'held pages unreadable this tick (rc=' "$T/h/logs/merge-conductor.log" && ok || bad "case D: no 'held pages unreadable' line: $(mclog)"
grep -q 'POST .*api/conductor/held/release' "$T/req.txt" && bad "case D: the keyed tick released a held row" || ok

# E. A stale held row (another head): no cache match, a#7 pages for its current
# state, and the keyed tick still releases nothing (the cron flush owns that).
reset_mc
seed_row example-org/a#7 "$ST7" "$H1" 7
held_row example-org/a 7 "$ST7" deadbeef0000 "16m in $ST7: stale-a7-page" | held_json
run_mc env MC_ONLY_PR=example-org/a#7 HELD_JSON="$T/held.json"
[ "$(npages 'example-org/a#7')" = 1 ] && ok || bad "case E: a stale held row must not suppress a#7's page: $(alerts)"
grep -q 'stale-a7-page' "$T/h/logs/ALERTS.log" 2>/dev/null && bad "case E: the keyed tick sent the stale held text" || ok
[ "$(alerted_of 'example-org/a#7')" = "$ST7@$SINCE" ] && ok || bad "case E: a#7's direct page did not spend its mark: '$(alerted_of 'example-org/a#7')'"
grep -q 'POST .*api/conductor/held/release' "$T/req.txt" && bad "case E: the keyed tick released the stale row" || ok

rm -f "$T/h/flags/merge-conductor-actions" "$T/held.json"
echo "conductor-keyed-held.bh-1840-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
