#!/bin/bash
# tests/mc-branch-refs.bh-4656-test.sh — BH-4659 (BH-4656.1): branch tips from
# ONE refs read per prefix. "$DIR/bin/lib/pr-snapshot-refs.sh" answers
# prs_branch_tip from `GET repos/<slug>/git/matching-refs/heads/<prefix>/`,
# cached as state/pr-snapshot/<owner_repo>/refs-<prefix>.json for
# PR_SNAPSHOT_TTL_S, and "$DIR/bin/lib/mc/rebase.sh" asks it before its live
# `branches/<br>` reads in head_lag_tip and mc_branch_exists.
#
# WHAT IS DRIVEN. The real merge-conductor-lib (mc_init, then head_lag_tip,
# head_lag_check, mc_branch_exists and prs_branch_tip), each case in a fresh
# process, against a stub gh that logs every argv to $T/log/gh:
#   B1  4 open PRs on ticket/*, refs tips == heads: 4 head_lag_tip calls cost
#       1 matching-refs read and 0 branches/ reads.
#   B2  a refs tip that differs from the PR head is confirmed by ONE live
#       branches/ read, and the lag clock starts (`lags its branch tip`).
#   B3  a branch absent from the refs, and a refs read that answers 500, fall
#       back to branches/<br>: on a 404 that is rc 75 and HEAD_LAG_WHY=HTTP 404.
#   B4  mc_branch_exists on a refs hit: rc 0, no branches/ read.
#   B5  mc_branch_exists on a refs miss: exactly one probe; 404 -> 1, 500 -> 2,
#       200 -> 0.
#   B6  negatives: no `/`, a prefix no open PR uses, ticket/bh-1 when the refs
#       hold only ticket/bh-10, a refs file past its TTL, PR_SNAPSHOT=0.
#   B7  a 403 refs read stores nothing; a held refs lock: the loser reads and
#       writes nothing.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-branch-refs.bh-4656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
# The driven lib and every bin/lib file it sources (BH-4552 scratch_install_closure).
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "FAIL: closure install failed for bin/lib/merge-conductor-lib.sh"; exit 1; }
[ -f "$T/h/bin/lib/pr-snapshot-refs.sh" ] || { echo "FAIL: closure did not install $DIR/bin/lib/pr-snapshot-refs.sh"; exit 1; }   # impact: this suite drives it
[ -f "$T/h/bin/lib/mc/snapshot-refs.sh" ] || { echo "FAIL: closure did not install $DIR/bin/lib/mc/snapshot-refs.sh, the module that loads prs_branch_tip"; exit 1; }
mkdir -p "$T/log" "$T/tmp"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"

SLUG=example-org/demo-os
D="$T/h/state/pr-snapshot/example-org_demo-os"
sha() { printf "$1%.0s" {1..40}; }

# $T/refs.json is the matching-refs answer (raw GitHub rows); $T/refs-status
# overrides its status. $T/br/<last segment> is a branch's tip; $T/br-status
# overrides every branches/ answer's status.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHT/log/gh"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
case "$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
case "$p" in
  repos/example-org/demo-os/git/matching-refs/heads/*)
    st=$(cat "$GHT/refs-status" 2>/dev/null || echo 200)
    if [ "$st" = 200 ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/refs.json"
    else printf 'HTTP/2 %s\r\n\r\n{"message":"nope"}\n' "$st"; fi ;;
  repos/example-org/demo-os/branches/*)
    br="${p#repos/example-org/demo-os/branches/}"
    st=$(cat "$GHT/br-status" 2>/dev/null || echo 200)
    if [ "$st" = 200 ] && [ -f "$GHT/br/${br##*/}" ]; then
      printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg n "$br" --arg s "$(cat "$GHT/br/${br##*/}")" '{name:$n, commit:{sha:$s}}'
    elif [ "$st" = 200 ]; then printf 'HTTP/2 404\r\n\r\n{"message":"Branch not found"}\n'
    else printf 'HTTP/2 %s\r\n\r\n{"message":"nope"}\n' "$st"; fi ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

unset PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S PRS_COUNT_FILE PR_SNAPSHOT_LIB PR_SNAPSHOT_REFS_LIB
export PATH="$T/fakebin:$PATH" GHT="$T" TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 HARNESS_SECRET=x \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 FLEET_CONF="$T/h/fleet.conf"
NOW=$(date +%s)

# open <n>... — the snapshot's open list: PR <n> on ticket/bh-<n>, head sha <n>.
open() {
  mkdir -p "$D"
  printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0) | tonumber
    | {number: ., head: {ref: ("ticket/bh-" + tostring), sha: (tostring * 40)}, base: {ref: "main"}}]' > "$D/open.json"
}
# refs <branch>=<sha>... — the matching-refs answer, in GitHub's shape.
refs() {
  printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(length > 0) | split("=")
    | {ref: ("refs/heads/" + .[0]), object: {sha: .[1], type: "commit"}}]' > "$T/refs.json"
}
reset() {
  scratch_rm "$T/h/state"; scratch_rm "$T/br"; mkdir -p "$T/h/state" "$T/br"
  rm -f "$T/refs-status" "$T/br-status" "$T/drv.out"; : > "$T/log/gh"; : > "$T/h/logs/merge-conductor.log"
}
TICKN=0
# drv <bash code> — the conductor lib in a fresh process (its own tick id).
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
mc_init
eval "$1"
EOF
drv() { TICKN=$((TICKN + 1)); MC_TICK_ID="t$TICKN" bash "$T/drv.sh" "$1" > "$T/drv.out" 2>&1; DRC=$?; }
n_refs() { grep -cE "GET repos/$SLUG/git/matching-refs/heads/${1:-}" "$T/log/gh"; }
n_br() { grep -cE "GET repos/$SLUG/branches/${1:-}" "$T/log/gh"; }

# ── B1: 4 PRs, tips == heads: 1 refs read, 0 branches/ reads ──
reset; open 1 2 3 4
refs "ticket/bh-1=$(sha 1)" "ticket/bh-2=$(sha 2)" "ticket/bh-3=$(sha 3)" "ticket/bh-4=$(sha 4)" "ticket/bh-10=$(sha a)"
drv 'for n in 1 2 3 4; do head_lag_tip example-org/demo-os "ticket/bh-$n" "$TMPDIR/tip$n" "$(printf "$n%.0s" {1..40})" || echo "RC$n=$?"; echo "TIP$n=$(cat "$TMPDIR/tip$n")"; done'
[ "$DRC" = 0 ] && ok || bad "B1 rc=$DRC $(cat "$T/drv.out")"
[ "$(n_refs ticket/)" = 1 ] && ok || bad "B1 want 1 matching-refs read, got $(n_refs ticket/)"
[ "$(n_br)" = 0 ] && ok || bad "B1 want 0 branches/ reads, got $(n_br)"
for n in 1 2 3 4; do grep -qx "TIP$n=$(sha "$n")" "$T/drv.out" && ok || bad "B1 tip $n: $(cat "$T/drv.out")"; done
[ -r "$D/refs-ticket.json" ] && ok || bad "B1 refs-ticket.json was not written"
grep -q 'RC' "$T/drv.out" && bad "B1 a tip was unreadable: $(cat "$T/drv.out")" || ok

# ── B2: a refs tip that differs from the head: one live read, the clock starts ──
reset; open 1; refs "ticket/bh-1=$(sha b)"; sha b > "$T/br/bh-1"
drv 'head_lag_check demo-os demo-os#1 example-org/demo-os 1 https://x/1 "$(printf "1%.0s" {1..40})" ticket/bh-1 false; echo "HLC=$?"'
[ "$(n_br ticket/bh-1)" = 1 ] && ok || bad "B2 want exactly 1 live branches/ read, got $(n_br ticket/bh-1) ($(cat "$T/drv.out"))"
grep -q "lags its branch tip $(sha b | cut -c1-8)" "$T/h/logs/merge-conductor.log" && ok || bad "B2 the lag clock did not start: $(tail -3 "$T/h/logs/merge-conductor.log") $(cat "$T/drv.out")"
# The same, with a live answer that has caught up with the head: no clock.
reset; open 1; refs "ticket/bh-1=$(sha b)"; sha 1 > "$T/br/bh-1"
drv 'head_lag_check demo-os demo-os#1 example-org/demo-os 1 https://x/1 "$(printf "1%.0s" {1..40})" ticket/bh-1 false; echo "HLC=$?"'
grep -q "lags its branch tip" "$T/h/logs/merge-conductor.log" && bad "B2b a stale refs tip started a clock the live read disproves" || ok

# ── B3: absent from refs / a failed refs read -> branches/<br>, today's contract ──
reset; open 1 2; refs "ticket/bh-1=$(sha 1)"
drv 'head_lag_tip example-org/demo-os ticket/bh-2 "$TMPDIR/t" "$(printf "2%.0s" {1..40})"; echo "RC=$? WHY=$HEAD_LAG_WHY"'
[ "$(n_br ticket/bh-2)" = 1 ] && ok || bad "B3a absent from refs: want 1 branches/ read, got $(n_br ticket/bh-2)"
grep -q "RC=75 WHY=HTTP 404" "$T/drv.out" && ok || bad "B3a want rc 75 / HTTP 404: $(cat "$T/drv.out")"
reset; open 1; refs "ticket/bh-1=$(sha 1)"; echo 500 > "$T/refs-status"
drv 'head_lag_tip example-org/demo-os ticket/bh-1 "$TMPDIR/t" "$(printf "1%.0s" {1..40})"; echo "RC=$? WHY=$HEAD_LAG_WHY"'
[ "$(n_refs ticket/)" = 1 ] && [ "$(n_br ticket/bh-1)" = 1 ] && ok || bad "B3b a 500 refs read: refs=$(n_refs ticket/) br=$(n_br ticket/bh-1)"
grep -q "RC=75 WHY=HTTP 404" "$T/drv.out" && ok || bad "B3b want rc 75 / HTTP 404: $(cat "$T/drv.out")"
[ ! -e "$D/refs-ticket.json" ] && ok || bad "B3b a 500 refs read was stored"

# ── B4: mc_branch_exists on a refs hit: 0, no probe ──
reset; open 1; refs "ticket/bh-1=$(sha 1)"
drv 'mc_branch_exists example-org/demo-os ticket/bh-1; echo "RC=$?"'
grep -qx "RC=0" "$T/drv.out" && ok || bad "B4 rc: $(cat "$T/drv.out")"
[ "$(n_br)" = 0 ] && ok || bad "B4 a refs hit still probed branches/"

# ── B5: mc_branch_exists on a refs miss: one probe, gone only on its 404 ──
for case in 404:1 500:2 200:0; do
  st=${case%%:*}; want=${case#*:}
  reset; open 1 2; refs "ticket/bh-1=$(sha 1)"
  if [ "$st" = 200 ]; then sha 2 > "$T/br/bh-2"; elif [ "$st" = 500 ]; then echo 500 > "$T/br-status"; fi
  drv 'mc_branch_exists example-org/demo-os ticket/bh-2; echo "RC=$?"'
  grep -qx "RC=$want" "$T/drv.out" && ok || bad "B5 probe $st: want rc $want, got $(cat "$T/drv.out")"
  [ "$(n_br ticket/bh-2)" = 1 ] && ok || bad "B5 probe $st: want exactly 1 probe, got $(n_br ticket/bh-2)"
done

# ── B6: the negatives — every one a miss (rc 2) ──
reset; open 1 10; refs "ticket/bh-10=$(sha a)" "main=$(sha c)"
drv 'prs_branch_tip example-org/demo-os main; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && [ "$(n_refs)" = 0 ] && ok || bad "B6 main: $(cat "$T/drv.out"), $(n_refs) refs reads"
drv 'prs_branch_tip example-org/demo-os feature/x; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && [ "$(n_refs)" = 0 ] && ok || bad "B6 feature/ (no open PR uses it): $(cat "$T/drv.out"), $(n_refs) refs reads"
drv 'prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && ok || bad "B6 ticket/bh-1 matched ticket/bh-10: $(cat "$T/drv.out")"
drv 'prs_branch_tip example-org/demo-os ticket/bh-10; echo "RC=$?"'
[ "$(head -1 "$T/drv.out")" = "$(sha a)" ] && grep -qx "RC=0" "$T/drv.out" && ok || bad "B6 ticket/bh-10 hit: $(cat "$T/drv.out")"
[ "$(n_refs ticket/)" = 1 ] && ok || bad "B6 the fresh refs file was not reused ($(n_refs ticket/) reads)"
touch -d "@$((NOW - 120))" "$D/refs-ticket.json"
drv 'prs_branch_tip example-org/demo-os ticket/bh-10; echo "RC=$?"'
[ "$(n_refs ticket/)" = 2 ] && ok || bad "B6 a refs file past its TTL was not re-read ($(n_refs ticket/) reads)"
reset; open 1; refs "ticket/bh-1=$(sha 1)"
# PR_SNAPSHOT resolves when the lib is sourced, so the kill switch is the env.
PR_SNAPSHOT=0 drv 'prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && [ "$(n_refs)" = 0 ] && [ ! -e "$D/refs-ticket.json" ] && ok || bad "B6 PR_SNAPSHOT=0: $(cat "$T/drv.out"), $(n_refs) refs reads"
# A refs sha that is not 40-hex is a miss, never a tip.
reset; open 1; refs "ticket/bh-1=nothex"
drv 'prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && ok || bad "B6 a non-hex sha: $(cat "$T/drv.out")"

# ── B7: a 403 stores nothing; a held lock: the loser reads, writes nothing ──
reset; open 1; refs "ticket/bh-1=$(sha 1)"; echo 403 > "$T/refs-status"
drv 'prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
grep -qx "RC=2" "$T/drv.out" && [ ! -e "$D/refs-ticket.json" ] && ok || bad "B7 a 403 refs read: $(cat "$T/drv.out"), file: $(ls "$D")"
rm -f "$T/refs-status"; : > "$T/log/gh"
: > "$D/refs-ticket.lock"
( flock -x 9; sleep 30 ) 9>"$D/refs-ticket.lock" &   # determinism: ok — holds the lock for the one drv below, killed right after; nothing waits on it
LP=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$D/refs-ticket.lock" true 2>/dev/null || break; sleep 0.1; done   # determinism: ok — waits for the holder above to take the lock, bounded at 1 s
drv 'prs_branch_tip example-org/demo-os ticket/bh-1; echo "RC=$?"'
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
[ "$(head -1 "$T/drv.out")" = "$(sha 1)" ] && ok || bad "B7 the lock loser did not answer from its own read: $(cat "$T/drv.out")"
[ "$(n_refs ticket/)" = 1 ] && [ ! -e "$D/refs-ticket.json" ] && ok || bad "B7 the lock loser wrote refs-ticket.json ($(n_refs ticket/) reads)"

echo "mc-branch-refs.bh-4656: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
