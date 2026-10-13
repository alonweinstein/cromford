#!/bin/bash
# tests/pr-snapshot-lanes.bh-4656-test.sh — BH-4659 (BH-4656.1): the merge
# conductor and batch-resolve read the shared PR snapshot
# ("$DIR/bin/lib/pr-snapshot.sh", BH-4658) through
# "$DIR/bin/lib/gh-pr-list.sh" when the lane exports HPL_SNAPSHOT=1.
#
# WHAT IS DRIVEN. The real harness_pr_list, sourced in a fresh process per
# lane, against a stub gh that logs every argv (and the HPL_READ_ROLE it ran
# under) to $T/log/gh:
#   S1     one tick, two lanes (the conductor's field list, then batch-resolve's)
#          over 3 open PRs: 3 pulls/<n> reads in total and ONE open-list read.
#   S2     the next tick, the list TTL expired, #2's updated_at changed: exactly
#          one new pulls/2, nothing for #1 or #3.
#   S3     CI goes green with the key unchanged: a stored blocked body is never
#          served, the live clean is, and the row reads CLEAN (review F1);
#          unstable/has_hooks are never served either; clean is.
#   S7b    PR_SNAPSHOT=0: 3+3 pulls/<n> reads, no state dir, stdout cmp-equal
#          to S1's per lane.
#   S8     HPL_SNAPSHOT unset: today's `pulls?state=open&…&sort=created` shape
#          and the same stdout.
#   Sd     a draft is never read, in any mode, and reads DRAFT.
#   S9     a rate-limited snapshot list fails the list (rc != 0, never `[]`).
#   L1     a WHOLE "$DIR/bin/merge-conductor.sh" tick, twice: the log carries
#          `<slug> PR-SNAPSHOT hit=<n> miss=<n>`, hit > 0 on the second tick,
#          and prs_gc ran. #1 (behind) is a hit on the second tick; #2
#          (blocked, CI's state) is read live again (review F1).
#   L2     with #1's body in the snapshot after that tick, the conductor's
#          decision read (mc_rest_pr_json, no HPL_READ_ROLE) still asks GitHub.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-snapshot-lanes.bh-4656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/pr" "$T/out"
# The driven libs and every bin/lib file they source (BH-4552 scratch_install_closure).
for s in bin/lib/gh-pr-list.sh bin/lib/pr-snapshot.sh bin/lib/env-path.sh bin/lib/gh-budget.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install failed for $s"; exit 1; }
done
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }

SLUG=example-org/demo-os
sha() { printf "$1%.0s" {1..40}; }
TIP=$(sha f)
UPD=2026-10-05T10:00:00Z
CONDUCTOR_FIELDS=number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,labels,updatedAt,isCrossRepository
BATCH_FIELDS=number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,createdAt,labels,author

# The stub answers both list shapes: today's `pulls?state=open&…` page and the
# snapshot's `pulls -f state=open -F per_page=100 -F page=N`.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s role=%s\n' "$*" "${HPL_READ_ROLE:--}" >> "$GHT/log/gh"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
case "$p" in
  repos/example-org/demo-os/pulls|repos/example-org/demo-os/pulls\?*)
    if [ -e "$GHT/list403" ]; then printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'
    elif [ "$pg" = 1 ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/prs.json"
    else printf 'HTTP/2 200\r\n\r\n[]\n'; fi ;;
  repos/example-org/demo-os/pulls/*)
    n="${p##*/pulls/}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/pr/$n.json" ;;
  repos/example-org/demo-os/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(cat "$GHT/tip")" '{ref:"refs/heads/main", object:{sha:$s, type:"commit"}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

unset PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S PRS_COUNT_FILE PR_SNAPSHOT_LIB HPL_SNAPSHOT
export PATH="$T/fakebin:$PATH" HARNESS="$H" GHT="$T" TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 \
  LANE_REGISTRY="$T/lanes.json" HARNESS_PR_AUTHORS=operator

D="$H/state/pr-snapshot/example-org_demo-os"
NOW=$(date +%s)
# pr <n> <head> [draft] — one open PR in the list and its pulls/<n> body.
# updated_at comes from $T/upd/<n>, else UPD.
pr() {
  local u; u=$(cat "$T/upd/$1" 2>/dev/null || echo "$UPD")
  jq -c --argjson n "$1" --arg h "$2" --arg u "$u" --argjson dr "${3:-false}" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:$dr, state:"open",
    updated_at:$u, created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os"}}}]' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  jq -nc --arg h "$2" --arg u "$u" '{head:{sha:$h}, base:{ref:"main"}, mergeable:true, mergeable_state:"clean", updated_at:$u}' > "$T/pr/$1.json"
}
reset() {
  scratch_rm "$H/state/pr-snapshot"; scratch_rm "$T/upd"; scratch_rm "$T/pr"; mkdir -p "$T/upd" "$T/pr"
  rm -f "$T/list403" "$T/count"; echo '[]' > "$T/prs.json"; echo "$TIP" > "$T/tip"; : > "$T/log/gh"
}
# lane <mode> <fields> <out> — one lane's list in a fresh process.
#   mode snap: HPL_SNAPSHOT=1 and the lib sourced; off: PR_SNAPSHOT=0 as well;
#   none: HPL_SNAPSHOT unset and the lib not sourced (today's lane).
cat > "$T/lane.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/gh-pr-list.sh" || exit 99
case "$1" in
  snap) . "$HARNESS/bin/lib/pr-snapshot.sh" || exit 98; export HPL_SNAPSHOT=1 ;;
  off)  export PR_SNAPSHOT=0; . "$HARNESS/bin/lib/pr-snapshot.sh" || exit 98; export HPL_SNAPSHOT=1 ;;
esac
harness_pr_list example-org/demo-os open "$2" 100 > "$3"
EOF
lane() { bash "$T/lane.sh" "$@" 2>>"$T/lane.err"; LRC=$?; }
pulls_n() { grep -cE "GET repos/$SLUG/pulls/${1:-[0-9]+}( |\$)" "$T/log/gh"; }
lists() { grep -cE "GET repos/$SLUG/pulls( |\?)" "$T/log/gh"; }

# ── S1: one tick, two lanes, 3 PRs: 3 per-PR reads, one list read ──
reset; for n in 1 2 3; do pr "$n" "$(sha "$n")"; done
lane snap "$CONDUCTOR_FIELDS" "$T/out/s1-c"
[ "$LRC" = 0 ] && ok || bad "S1 lane 1 rc=$LRC $(tail -3 "$T/lane.err")"
[ "$(pulls_n)" = 3 ] && ok || bad "S1 lane 1 want 3 pulls/<n> reads, got $(pulls_n)"
lane snap "$BATCH_FIELDS" "$T/out/s1-b"
[ "$LRC" = 0 ] && ok || bad "S1 lane 2 rc=$LRC"
[ "$(pulls_n)" = 3 ] && ok || bad "S1 lane 2 made new pulls/<n> reads: $(pulls_n) in total"
[ "$(lists)" = 1 ] && ok || bad "S1 the open list was read $(lists) times, want 1"
grep -qE "GET repos/$SLUG/pulls -f state=open" "$T/log/gh" && ok || bad "S1 the list did not go through prs_open_list"
[ "$(jq -c '[.[].number]' "$T/out/s1-c")" = "[1,2,3]" ] && ok || bad "S1 lane 1 rows: $(cat "$T/out/s1-c")"
[ "$(jq -r '[.[].mergeStateStatus] | unique | join(",")' "$T/out/s1-b")" = CLEAN ] && ok || bad "S1 lane 2 mergeStateStatus: $(cat "$T/out/s1-b")"
[ "$(jq -c '.[0] | keys_unsorted' "$T/out/s1-b")" = "$(printf '%s' "$BATCH_FIELDS" | jq -Rc 'split(",")')" ] \
  && ok || bad "S1 lane 2 keys are not exactly its fields: $(jq -c '.[0] | keys_unsorted' "$T/out/s1-b")"

# ── S2: the next tick, the list expired, #2 changed: one new pulls/2 only ──
B1=$(pulls_n 1); B2=$(pulls_n 2); B3=$(pulls_n 3)
echo 2026-10-05T11:00:00Z > "$T/upd/2"
echo '[]' > "$T/prs.json"; for n in 1 2 3; do pr "$n" "$(sha "$n")"; done
echo "$((NOW - 3600))" > "$D/open.meta"
lane snap "$CONDUCTOR_FIELDS" "$T/out/s2"
[ "$LRC" = 0 ] && ok || bad "S2 rc=$LRC"
[ "$(lists)" = 2 ] && ok || bad "S2 an expired list was not re-read ($(lists) list reads)"
[ "$(pulls_n 2)" = $((B2 + 1)) ] && ok || bad "S2 want exactly one new pulls/2, got $(( $(pulls_n 2) - B2 ))"
[ "$(pulls_n 1)" = "$B1" ] && [ "$(pulls_n 3)" = "$B3" ] && ok || bad "S2 #1 or #3 was re-read"

# ── S3: CI goes green with the key unchanged (review F1) ──
# GitHub does not bump updated_at on a check run, and here main does not move
# either, so the key is (H, U, T) on both ticks. A stored `blocked` body must
# never answer: the live `clean` does, and the row reads CLEAN.
reset; pr 1 "$(sha 1)"
jq '.mergeable_state = "blocked"' "$T/pr/1.json" > "$T/pr/1.tmp" && mv "$T/pr/1.tmp" "$T/pr/1.json"
lane snap "$CONDUCTOR_FIELDS" "$T/out/s3a"
[ "$LRC" = 0 ] && ok || bad "S3 tick 1 rc=$LRC"
[ "$(jq -r '.[0].mergeStateStatus' "$T/out/s3a")" = BLOCKED ] && ok || bad "S3 tick 1 row: $(cat "$T/out/s3a")"
[ "$(jq -r '.mergeable_state' "$D/pr-1.json" 2>/dev/null)" = blocked ] && ok || bad "S3 tick 1 did not store the blocked body (the case would test nothing)"
B1=$(pulls_n 1)
jq '.mergeable_state = "clean"' "$T/pr/1.json" > "$T/pr/1.tmp" && mv "$T/pr/1.tmp" "$T/pr/1.json"
echo "$((NOW - 3600))" > "$D/open.meta"
lane snap "$CONDUCTOR_FIELDS" "$T/out/s3b"
[ "$LRC" = 0 ] && ok || bad "S3 tick 2 rc=$LRC"
[ "$(pulls_n 1)" = $((B1 + 1)) ] && ok || bad "S3 a cached blocked body was served: $(( $(pulls_n 1) - B1 )) new pulls/1 reads"
[ "$(jq -r '.[0].mergeStateStatus' "$T/out/s3b")" = CLEAN ] && ok || bad "S3 CI went green, the list still says: $(cat "$T/out/s3b")"
# Settled now: the clean body is served from disk on the next lane.
B1=$(pulls_n 1)
lane snap "$BATCH_FIELDS" "$T/out/s3c"
[ "$(pulls_n 1)" = "$B1" ] && ok || bad "S3 a cached clean body was re-read"
[ "$(jq -r '.[0].mergeStateStatus' "$T/out/s3c")" = CLEAN ] && ok || bad "S3 tick 3 row: $(cat "$T/out/s3c")"
# unstable and has_hooks are CI's too: never served, whatever the key says.
for st in unstable has_hooks; do
  jq --arg s "$st" '.mergeable_state = $s' "$T/pr/1.json" > "$T/pr/1.tmp" && mv "$T/pr/1.tmp" "$T/pr/1.json"
  cp "$T/pr/1.json" "$D/pr-1.json"
  B1=$(pulls_n 1)
  lane snap "$CONDUCTOR_FIELDS" "$T/out/s3d"; lane snap "$BATCH_FIELDS" "$T/out/s3e"
  [ "$(pulls_n 1)" = $((B1 + 2)) ] && ok || bad "S3 a cached $st body was served: $(( $(pulls_n 1) - B1 )) reads over two lanes"
done

# ── S7b: PR_SNAPSHOT=0 — 3+3 reads, nothing stored, the same bytes ──
reset; for n in 1 2 3; do pr "$n" "$(sha "$n")"; done
lane off "$CONDUCTOR_FIELDS" "$T/out/s7-c"; R1=$LRC
lane off "$BATCH_FIELDS" "$T/out/s7-b"; R2=$LRC
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok || bad "S7b rc=$R1/$R2"
[ "$(pulls_n)" = 6 ] && ok || bad "S7b want 3+3 pulls/<n> reads, got $(pulls_n)"
[ ! -e "$H/state/pr-snapshot" ] && ok || bad "S7b PR_SNAPSHOT=0 wrote state/pr-snapshot"
grep -qE "GET repos/$SLUG/pulls -f state=open" "$T/log/gh" && bad "S7b PR_SNAPSHOT=0 still listed through prs_open_list" || ok
cmp -s "$T/out/s1-c" "$T/out/s7-c" && ok || bad "S7b conductor list differs from the snapshot run's"
cmp -s "$T/out/s1-b" "$T/out/s7-b" && ok || bad "S7b batch-resolve list differs from the snapshot run's"

# ── S8: HPL_SNAPSHOT unset — today's request shape, the same bytes ──
reset; for n in 1 2 3; do pr "$n" "$(sha "$n")"; done
lane none "$CONDUCTOR_FIELDS" "$T/out/s8-c"; R1=$LRC
lane none "$BATCH_FIELDS" "$T/out/s8-b"; R2=$LRC
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok || bad "S8 rc=$R1/$R2"
grep -qE "GET repos/$SLUG/pulls\?state=open&per_page=100&sort=created" "$T/log/gh" && ok || bad "S8 not today's list shape: $(head -2 "$T/log/gh")"
[ "$(pulls_n)" = 6 ] && ok || bad "S8 want 3+3 pulls/<n> reads, got $(pulls_n)"
cmp -s "$T/out/s7-c" "$T/out/s8-c" && cmp -s "$T/out/s7-b" "$T/out/s8-b" && ok || bad "S8 output differs from S7b's"

# ── Sd: a draft is never read, in any mode ──
for mode in snap off none; do
  reset; pr 1 "$(sha 1)"; pr 4 "$(sha 4)" true
  lane "$mode" "$CONDUCTOR_FIELDS" "$T/out/sd"
  [ "$LRC" = 0 ] && ok || bad "Sd ($mode) rc=$LRC"
  [ "$(pulls_n 4)" = 0 ] && ok || bad "Sd ($mode) the draft was read"
  [ "$(jq -r '.[] | select(.number == 4) | .mergeStateStatus' "$T/out/sd")" = DRAFT ] && ok || bad "Sd ($mode) row: $(cat "$T/out/sd")"
done

# ── S9: a rate-limited snapshot list fails the list, never `[]` on rc 0 ──
reset; pr 1 "$(sha 1)"; : > "$T/list403"
lane snap "$CONDUCTOR_FIELDS" "$T/out/s9"
[ "$LRC" != 0 ] && ok || bad "S9 a 403 list answered rc 0: $(cat "$T/out/s9")"
[ ! -s "$T/out/s9" ] && ok || bad "S9 a failed list printed: $(cat "$T/out/s9")"
[ ! -e "$D/open.json" ] && ok || bad "S9 a failed list was stored"
grep -q "REST list unavailable (HTTP 403" "$T/lane.err" "$H/logs/"* 2>/dev/null && ok || bad "S9 no 'REST list unavailable' line"

# ============================================================================
# L1 / L2: a WHOLE conductor tick (the production entry point)
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
LT="$T/lt"; mkdir -p "$LT"
( export HARNESS="$LT/h"; fx_mc_harness "$DIR" "$LT" && fx_conductor_tick "$DIR" "$LT" ) || { echo "FAIL: conductor fixture"; exit 1; }
scratch_install_closure bin/merge-conductor.sh "$LT/h" >/dev/null || { echo "FAIL: closure install failed for bin/merge-conductor.sh"; exit 1; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
mkdir -p "$LT/repos/demo-os/.git" "$LT/pr"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$LT/h/fleet.conf"
: > "$LT/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$LT/h/bin/agent-call.sh"; chmod +x "$LT/h/bin/agent-call.sh"
cat > "$LT/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$LT/fakebin/curl"
cat > "$LT/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s role=%s\n' "$*" "${HPL_READ_ROLE:--}" >> "$GHT/gh-calls.txt"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -X PATCH"*)
    printf '%s\n' "$*" >> "$GHT/gh-writes.txt"; exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
esac
case "$p" in
  repos/example-org/demo-os/pulls|repos/example-org/demo-os/pulls\?state=open*)
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/prs.json" || echo '[]' ;;
  repos/example-org/demo-os/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/example-org/demo-os/pulls/[0-9]*)
    n="${p##*/pulls/}"; n="${n%%[!0-9]*}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/pr/$n.json" ;;
  repos/example-org/demo-os/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *"actions/runs"*) restpr --runs 'in_progress|' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$LT/fakebin/gh"
echo '[]' > "$LT/prs.json"
# #1 is `behind`, a state CI cannot change, so a quiet tick may answer it from
# disk. #2 is `blocked`, CI's state, which is never served (review F1).
for n in 1 2; do
  st=behind; [ "$n" = 2 ] && st=blocked
  jq -c --argjson n "$n" --arg h "$(sha "$n")" --arg u "$UPD" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:$u, created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os"}}}]' "$LT/prs.json" > "$LT/prs.tmp" && mv "$LT/prs.tmp" "$LT/prs.json"
  jq -nc --argjson n "$n" --arg h "$(sha "$n")" --arg u "$UPD" --arg st "$st" '{number:$n, state:"open", merged_at:null, draft:false,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), user:{login:"operator"}, labels:[],
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os"}}, mergeable:true, mergeable_state:$st, updated_at:$u}' > "$LT/pr/$n.json"
done
# A pr-* file older than prs_gc's three days: the conductor's gc must drop it.
mkdir -p "$LT/h/state/pr-snapshot/example-org_demo-os"
echo '{}' > "$LT/h/state/pr-snapshot/example-org_demo-os/pr-77.json"; touch -d '5 days ago' "$LT/h/state/pr-snapshot/example-org_demo-os/pr-77.json"
ltick() { ( cd "$LT" && PATH="$LT/fakebin:$PATH" HARNESS="$LT/h" GHT="$LT" HARNESS_SECRET=x TMPDIR="$LT/h/tmp" \
  MC_REPOS="$LT/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=1 MC_TICK_SECS=0 \
  MC_HEAD_LAG_MINS=0 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
  bash "$LT/h/bin/merge-conductor.sh" >/dev/null 2>"$LT/tick.err" ); }
mkdir -p "$LT/h/tmp"
ltick; LRC1=$?
[ "$LRC1" = 0 ] && ok || bad "L1 tick 1 rc=$LRC1 $(tail -3 "$LT/tick.err")"
MCLOG="$LT/h/logs/merge-conductor.log"
grep -qE "example-org/demo-os PR-SNAPSHOT hit=[0-9]+ miss=[0-9]+" "$MCLOG" 2>/dev/null && ok || bad "L1 tick 1 wrote no PR-SNAPSHOT line: $(tail -5 "$MCLOG" 2>/dev/null)"
[ ! -e "$LT/h/state/pr-snapshot/example-org_demo-os/pr-77.json" ] && ok || bad "L1 prs_gc did not run"
B=$(grep -c . "$LT/gh-calls.txt")
ltick; LRC2=$?
[ "$LRC2" = 0 ] && ok || bad "L1 tick 2 rc=$LRC2 $(tail -3 "$LT/tick.err")"
LAST=$(grep -E "example-org/demo-os PR-SNAPSHOT hit=" "$MCLOG" | tail -1)
HITS=$(sed -nE 's/.*PR-SNAPSHOT hit=([0-9]+) .*/\1/p' <<<"$LAST")
[ "$(grep -c "PR-SNAPSHOT hit=" "$MCLOG")" = 2 ] && ok || bad "L1 want one PR-SNAPSHOT line per tick: $(grep PR-SNAPSHOT "$MCLOG")"
[ "${HITS:-0}" -gt 0 ] && ok || bad "L1 the quiet second tick had no hit: $LAST"
NEWLAZY=$(tail -n +"$((B + 1))" "$LT/gh-calls.txt" | grep -cE "GET repos/example-org/demo-os/pulls/1( .*)? role=list-lazy")
[ "$NEWLAZY" = 0 ] && ok || bad "L1 tick 2 re-read #1 for the list ($NEWLAZY)"
NEWLAZY2=$(tail -n +"$((B + 1))" "$LT/gh-calls.txt" | grep -cE "GET repos/example-org/demo-os/pulls/2( .*)? role=list-lazy")
[ "$NEWLAZY2" = 1 ] && ok || bad "L1 tick 2 served #2's blocked body from disk ($NEWLAZY2 live list reads, want 1)"
[ ! -s "$LT/gh-writes.txt" ] && ok || bad "L1 the observe tick wrote: $(cat "$LT/gh-writes.txt")"
# ── L2: the decision read stays live ──
# #1's body is in the snapshot now (the hit above). The conductor's decision
# read, mc_rest_pr_json, run in the same lane setup, must still ask GitHub.
[ -s "$LT/h/state/pr-snapshot/example-org_demo-os/pr-1.json" ] && ok || bad "L2 setup: #1 is not in the snapshot"
B=$(grep -c . "$LT/gh-calls.txt")
L2OUT=$( cd "$LT" && PATH="$LT/fakebin:$PATH" HARNESS="$LT/h" H="$LT/h" GHT="$LT" HARNESS_SECRET=x TMPDIR="$LT/h/tmp" \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 bash -c '. "$HARNESS/bin/lib/pr-snapshot.sh"; export HPL_SNAPSHOT=1
    . "$HARNESS/bin/lib/merge-conductor-lib.sh" && mc_init && mc_rest_pr_json example-org/demo-os 1' 2>/dev/null )
NEWDEC=$(tail -n +"$((B + 1))" "$LT/gh-calls.txt" | grep -cE "GET repos/example-org/demo-os/pulls/1 role=-$")
[ "$NEWDEC" = 1 ] && ok || bad "L2 mc_rest_pr_json after a snapshot hit made $NEWDEC live pulls/1 reads, want 1"
[ -n "$L2OUT" ] && ok || bad "L2 mc_rest_pr_json answered nothing"

echo "pr-snapshot-lanes.bh-4656: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
