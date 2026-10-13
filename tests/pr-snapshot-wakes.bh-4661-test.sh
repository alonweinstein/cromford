#!/bin/bash
# tests/pr-snapshot-wakes.bh-4661-test.sh — BH-4661 (BH-4656 part 3): the
# webhook mirror feed "$DIR/bin/lib/pr-snapshot-wakes.sh", loaded the way
# production loads it: through the source hook at the end of
# "$DIR/bin/lib/pr-snapshot.sh", after the real bin/jobs-client.sh. The cases
# drive the contract's real prs_open_list / prs_base_tip / prs_pr_get.
#
# Stubbed:
#   * _jobs_req — redefined after jobs-client.sh is sourced. /api/wakes?since=N
#                 answers $T/wakes/N.json ({"wakes":[]} when absent) or rc 1
#                 when $T/wakes/N.fail exists; /api/wakes/summary answers
#                 $T/summary.json (rc 2, the 404, when absent). Every path is
#                 logged to $T/log/worker.
#   * gh        — the open PR list ($T/prs.json), pulls/<n> ($T/pr/<n>.json)
#                 and git/ref/heads/main ($T/tip). Every argv is logged.
# Ages are set by writing open.meta / base-* / wakes.state epochs and
# `touch -d`, never by sleeping.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-snapshot-wakes.bh-4661-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/pr" "$T/wakes"
for s in bin/jobs-client.sh bin/lib/pr-snapshot.sh; do
  scratch_install_closure "$s" "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
WLIB="$DIR/bin/lib/pr-snapshot-wakes.sh"
[ -r "$WLIB" ] || echo "note: bin/lib/pr-snapshot-wakes.sh not found"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }

SLUG=example-org/demo-os
TIPA=$(printf '1%.0s' {1..40}); TIPB=$(printf '2%.0s' {1..40})
UPD=2026-10-05T10:00:00Z
sha() { printf "$1%.0s" {1..40}; }

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
p=""; prev=""
for a in "\$@"; do [ "\$prev" = GET ] && p="\$a"; prev="\$a"; done
pg=1; [[ " \$* " =~ [\&\ ]page=([0-9]+) ]] && pg="\${BASH_REMATCH[1]}"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
case "\$p" in
  repos/$SLUG/pulls|repos/$SLUG/pulls\?*)
    if [ "\$pg" = 1 ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json"
    else printf 'HTTP/2 200\r\n\r\n[]\n'; fi ;;
  repos/$SLUG/pulls/*)
    n="\${p##*/pulls/}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/pr/\$n.json" ;;
  repos/$SLUG/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/tip")" '{ref:"refs/heads/main", object:{sha:\$s, type:"commit"}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

unset PR_SNAPSHOT_LIB PR_SNAPSHOT_WAKES_LIB PRS_COUNT_FILE
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LANE_REGISTRY="$T/lanes.json" T \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 PR_SNAPSHOT_QUIET_TTL_S=300 PR_SNAPSHOT_FEED_STALE_S=900

SNAPDIR="$H/state/pr-snapshot/example-org_demo-os"
NOW=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# pr <n> <head> — one open PR in the list and its finished pulls/<n> body.
pr() {
  jq -c --argjson n "$1" --arg h "$2" --arg u "$UPD" '. + [{number:$n, state:"open", updated_at:$u,
    head:{sha:$h}, base:{ref:"main"}}]' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  jq -nc --arg h "$2" --arg u "$UPD" '{head:{sha:$h}, base:{ref:"main"}, mergeable:true, mergeable_state:"clean", updated_at:$u}' > "$T/pr/$1.json"
}
# cached <n> <head> <key-mtime> — pr-<n>.json/.key on disk, keyed on TIPA.
cached() {
  cp "$T/pr/$1.json" "$SNAPDIR/pr-$1.json"
  printf '%s\t%s\t%s' "$2" "$UPD" "$TIPA" > "$SNAPDIR/pr-$1.key"
  touch -d "@$3" "$SNAPDIR/pr-$1.key"
}
# summary <repo> <last_at epoch>
summary() { jq -nc --arg r "$1" --arg a "$(iso "$2")" '{repos:[{repo:$r, n:3, last_at:$a, kinds:"pr"}]}' > "$T/summary.json"; }
# rows <since-file> <kind> <key> <from-id> <to-id> <at epoch> — a page of wakes
rows() {
  jq -nc --arg r "$SLUG" --arg k "$2" --arg y "$3" --argjson a "$4" --argjson b "$5" --arg at "$(iso "$6")" \
    '{wakes:[range($a; $b + 1) | {id:., repo:$r, kind:$k, key:$y, event:"x", at:$at, acked_at:null}]}' > "$T/wakes/$1.json"
}
# addrow <since-file> <kind> <key> <id> <at epoch> — append one row to a page
addrow() {
  [ -f "$T/wakes/$1.json" ] || echo '{"wakes":[]}' > "$T/wakes/$1.json"
  jq -c --arg r "$SLUG" --arg k "$2" --arg y "$3" --argjson i "$4" --arg at "$(iso "$5")" \
    '.wakes += [{id:$i, repo:$r, kind:$k, key:$y, event:"x", at:$at, acked_at:null}]' "$T/wakes/$1.json" > "$T/w.tmp" \
    && mv "$T/w.tmp" "$T/wakes/$1.json"
}
reset() {
  scratch_rm "$H/state/pr-snapshot"; scratch_rm "$T/wakes"; scratch_rm "$T/pr"
  mkdir -p "$T/wakes" "$T/pr" "$SNAPDIR"
  rm -f "$T/log"/* "$T/count" "$T/summary.json" "$H/bin/lib/pr-snapshot-wakes.sh"
  [ -r "$WLIB" ] && cp "$WLIB" "$H/bin/lib/"
  echo '[]' > "$T/prs.json"; echo "$TIPA" > "$T/tip"; : > "$T/log/gh"; : > "$T/log/worker"
}
# seed — a box past its bootstrap: wm 10, a complete read 100s ago with
# coverage from two hours back, a fresh feed and a 120s-old open list.
seed() {
  reset
  echo 10 > "$SNAPDIR/wakes.wm"
  printf '%s\t1\t1\t%s\n' "$((NOW - 100))" "$((NOW - 7200))" > "$SNAPDIR/wakes.state"
  summary "$SLUG" "$((NOW - 30))"
  pr 1 "$(sha 1)"; pr 2 "$(sha 2)"
  cp "$T/prs.json" "$SNAPDIR/open.json"; echo "$((NOW - 120))" > "$SNAPDIR/open.meta"
  printf '%s\t%s\n' "$((NOW - 10))" "$TIPA" > "$SNAPDIR/base-main"
}
# drv <bash code> — jobs-client.sh, then pr-snapshot.sh (whose hook loads the
# wakes lib), then the _jobs_req stub, in a fresh process.
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
if [ -z "${NOJOBS:-}" ]; then
  . "$HARNESS/bin/jobs-client.sh" || exit 97
fi
. "$HARNESS/bin/lib/pr-snapshot.sh" || exit 99
if [ -z "${NOJOBS:-}" ]; then
  _jobs_req() {
    local s
    printf '%s %s\n' "$1" "$2" >> "$T/log/worker"
    case "$2" in
      /api/wakes/summary*) [ -f "$T/summary.json" ] || return 2; cat "$T/summary.json" ;;
      "/api/wakes?"*)
        s="${2#*since=}"; s="${s%%&*}"
        [ -e "$T/wakes/$s.fail" ] && return 1
        if [ -f "$T/wakes/$s.json" ]; then cat "$T/wakes/$s.json"; else echo '{"wakes":[]}'; fi ;;
      *) return 2 ;;
    esac
  }
else
  unset -f _jobs_req wakes_summary 2>/dev/null
fi
eval "$1"
EOF
drv() { bash "$T/drv.sh" "$1" > "$T/drv.out" 2>&1; DRC=$?; }
lreads() { grep -cE -- "GET repos/$SLUG/pulls( |\?)" "$T/log/gh"; }
reads() { grep -cE -- "GET repos/$SLUG/$1( |\$)" "$T/log/gh"; }
wreads() { grep -c '^GET /api/wakes?' "$T/log/worker"; }
sreads() { grep -c '^GET /api/wakes/summary' "$T/log/worker"; }
seen() { printf 'prs_wake_seen %s %s %s %s; echo "%s=$?"' "$SLUG" "$2" "$3" "$4" "$1"; }
out() { grep -qx "$1" "$T/drv.out"; }
get() { printf 'prs_pr_get %s %s %s %s main %s' "$SLUG" "$1" "$(sha "$1")" "$UPD" "$T/o$1"; }

# ── K1: a fresh feed and no wake past wm -> the 120s-old list is reused ──
seed
drv "prs_open_list $SLUG $T/o1; echo list=\$?"
out list=0 && ok || bad "K1 rc: $(cat "$T/drv.out")"
[ "$(lreads)" = 0 ] && ok || bad "K1 want 0 list reads, got $(lreads)"
cmp -s "$T/o1" "$SNAPDIR/open.json" && ok || bad "K1 the cached list was not served"
[ "$(wreads)" = 1 ] && grep -q 'since=10&' "$T/log/worker" && ok || bad "K1 the feed was not read from wm 10: $(cat "$T/log/worker")"

# ── B: without the wakes lib in the box the contract's default (rc 2) holds ──
seed; rm -f "$H/bin/lib/pr-snapshot-wakes.sh"
drv "prs_open_list $SLUG $T/o1"
[ "$(lreads)" = 1 ] && ok || bad "B without the lib the 120s-old list was not re-read ($(lreads))"
[ "$(wreads)" = 0 ] && ok || bad "B without the lib the feed was still read"

# ── K2: any wake after open.meta -> the list re-pages at the 60s TTL ──
seed; addrow 10 issue 77 11 "$((NOW - 50))"
drv "prs_open_list $SLUG $T/o1; $(seen any any - $((NOW - 120)))"
[ "$(lreads)" = 1 ] && ok || bad "K2 want 1 list read, got $(lreads)"
out any=0 && ok || bad "K2 prs_wake_seen any: $(cat "$T/drv.out")"
[ "$(cat "$SNAPDIR/wakes.wm")" = 11 ] && ok || bad "K2 wm want 11, got $(cat "$SNAPDIR/wakes.wm")"

# ── K3: a pr wake for #2 misses #2, #1 still hits ──
seed; cached 1 "$(sha 1)" "$((NOW - 100))"; cached 2 "$(sha 2)" "$((NOW - 100))"
addrow 10 pr 2 11 "$((NOW - 50))"
drv "PRS_COUNT_FILE=$T/count; $(get 1); $(get 2)"
[ "$DRC" = 0 ] && ok || bad "K3 rc=$DRC $(cat "$T/drv.out")"
[ "$(reads pulls/2)" = 1 ] && ok || bad "K3 want 1 pulls/2 read, got $(reads pulls/2)"
[ "$(reads pulls/1)" = 0 ] && ok || bad "K3 want 0 pulls/1 reads, got $(reads pulls/1)"
grep -qx 'MISS 2' "$T/count" && grep -qx 'HIT 1' "$T/count" && ok || bad "K3 count: $(cat "$T/count" 2>/dev/null)"
[ "$(reads git/ref/heads/main)" = 0 ] && ok || bad "K3 a pr wake re-read the base tip"

# ── K4: a failed second page keeps nothing and answers 2 ──
seed; rows 10 pr 1 11 510 "$((NOW - 50))"; touch "$T/wakes/510.fail"
printf 'checks\tz\t5\t%s\n' "$((NOW - 5000))" > "$SNAPDIR/changed.tsv"; cp "$SNAPDIR/changed.tsv" "$T/changed.before"
drv "$(seen any any - $((NOW - 120))); $(seen pr pr 1 $((NOW - 120))); $(seen push push main $((NOW - 120))); prs_open_list $SLUG $T/o1"
out any=2 && out pr=2 && out push=2 && ok || bad "K4 want rc 2 throughout: $(cat "$T/drv.out")"
[ "$(cat "$SNAPDIR/wakes.wm")" = 10 ] && ok || bad "K4 wm moved to $(cat "$SNAPDIR/wakes.wm")"
cmp -s "$SNAPDIR/changed.tsv" "$T/changed.before" && ok || bad "K4 changed.tsv changed"
[ "$(cut -f2 "$SNAPDIR/wakes.state")" = 0 ] && ok || bad "K4 state not incomplete: $(cat "$SNAPDIR/wakes.state")"
[ "$(lreads)" = 1 ] && ok || bad "K4 the list got the quiet extension ($(lreads) reads)"
[ "$(wreads)" = 2 ] && ok || bad "K4 want 2 page reads in one throttled read, got $(wreads)"

# ── K5: a summary older than PR_SNAPSHOT_FEED_STALE_S is not fresh ──
seed; summary "$SLUG" "$((NOW - 1000))"
drv "prs_open_list $SLUG $T/o1; $(seen any any - $((NOW - 120))); prs_feed_fresh $SLUG; echo fresh=\$?"
[ "$(lreads)" = 1 ] && ok || bad "K5 the list was not re-read on a stale feed"
out any=2 && out fresh=1 && ok || bad "K5 $(cat "$T/drv.out")"
seed; rm -f "$T/summary.json"
drv "$(seen any any - $((NOW - 120))); prs_feed_fresh $SLUG; echo fresh=\$?"
out any=2 && out fresh=1 && ok || bad "K5b a summary outage read as fresh: $(cat "$T/drv.out")"

# ── K6: a 500-row page reads on; its own watermark, never an ack ──
reset; summary "$SLUG" "$((NOW - 30))"
rows 0 checks c 1 500 "$((NOW - 50))"; rows 500 pr 9 501 503 "$((NOW - 40))"
drv "prs_changed $SLUG; echo changed=\$?"
out changed=0 && ok || bad "K6 prs_changed: $(cat "$T/drv.out")"
[ "$(wreads)" = 2 ] && ok || bad "K6 want 2 page reads, got $(wreads): $(cat "$T/log/worker")"
[ "$(grep '^GET /api/wakes?' "$T/log/worker" | sed -n 2p | grep -c 'since=500&')" = 1 ] && ok || bad "K6 page 2 not from since=500"
[ "$(grep '^GET /api/wakes?' "$T/log/worker" | grep -c 'limit=500')" = 2 ] && ok || bad "K6 a page without limit=500"
[ "$(cat "$SNAPDIR/wakes.wm")" = 503 ] && ok || bad "K6 wm want 503, got $(cat "$SNAPDIR/wakes.wm" 2>/dev/null)"
[ "$(grep -c . "$SNAPDIR/changed.tsv")" = 503 ] && ok || bad "K6 changed.tsv rows $(grep -c . "$SNAPDIR/changed.tsv" 2>/dev/null)"
grep -qE '/api/wakes/(ack|cursor)' "$T/log/worker" && bad "K6 acked or used the cursor" || ok
[ "$(cut -f2 "$SNAPDIR/wakes.state")" = 1 ] && [ "$(cut -f4 "$SNAPDIR/wakes.state")" -ge "$NOW" ] && ok || bad "K6 state: $(cat "$SNAPDIR/wakes.state")"

# ── K7: a 2xx with no .wakes array is a failed read ──
seed; echo '{}' > "$T/wakes/10.json"
drv "$(seen any any - $((NOW - 120)))"
out any=2 && ok || bad "K7 $(cat "$T/drv.out")"
[ "$(cat "$SNAPDIR/wakes.wm")" = 10 ] && [ "$(cut -f2 "$SNAPDIR/wakes.state")" = 0 ] && ok || bad "K7 wm/state: $(cat "$SNAPDIR/wakes.wm") $(cat "$SNAPDIR/wakes.state")"
seed; addrow 10 pr 1 11 "$((NOW - 50))"; jq -c '.wakes[0].at = "yesterday"' "$T/wakes/10.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/wakes/10.json"
drv "$(seen any any - $((NOW - 120)))"
out any=2 && [ "$(cat "$SNAPDIR/wakes.wm")" = 10 ] && ok || bad "K7a an unparseable at was not a failed page: $(cat "$T/drv.out")"
# K7b: the first complete read covers only from its own start
reset; summary "$SLUG" "$((NOW - 30))"
drv "$(seen old pr 1 $((NOW - 3600))); $(seen new pr 1 "\$(date +%s)")"
out old=2 && ok || bad "K7b a since older than coverage: $(cat "$T/drv.out")"
out new=1 && ok || bad "K7b a since inside coverage: $(cat "$T/drv.out")"
# K7c: no _jobs_req -> 2 and nothing written
reset; summary "$SLUG" "$((NOW - 30))"
NOJOBS=1 drv "$(seen any any - $((NOW - 120)))"
out any=2 && ok || bad "K7c $(cat "$T/drv.out")"
[ -z "$(find "$SNAPDIR" -name 'wakes.*' -o -name changed.tsv)" ] && ok || bad "K7c wrote $(find "$SNAPDIR" -type f)"

# ── K8: the summary names the repo in another case -> not fresh ──
seed; summary example-org/demo-os "$((NOW - 30))"
drv "prs_open_list $SLUG $T/o1; $(seen any any - $((NOW - 120)))"
[ "$(lreads)" = 1 ] && ok || bad "K8 a case-mismatched summary gave the quiet extension"
out any=2 && ok || bad "K8 $(cat "$T/drv.out")"

# ── K9: a same-minute wake before the key's mtime still counts ──
B=$(( (NOW - 90) / 60 * 60 ))
seed; addrow 10 pr 2 11 "$((B + 10))"; addrow 10 pr 3 12 "$((B - 10))"
drv "$(seen same pr 2 $((B + 40))); $(seen prev pr 3 $((B + 40))); $(seen key pr 4 $((B - 100)))"
out same=0 && ok || bad "K9 a same-minute wake was missed: $(cat "$T/drv.out")"
out prev=1 && ok || bad "K9 a previous-minute wake matched: $(cat "$T/drv.out")"
out key=1 && ok || bad "K9 a wake for another key matched: $(cat "$T/drv.out")"

# ── K10: a push wake (keyed on a sha) re-reads the base tip once ──
seed; echo "$TIPB" > "$T/tip"; addrow 10 push "$(sha c)" 11 "$((NOW - 5))"
drv "prs_base_tip $SLUG main"
[ "$(reads git/ref/heads/main)" = 1 ] && grep -qx "$TIPB" "$T/drv.out" && ok || bad "K10 tip: $(cat "$T/drv.out") reads=$(reads git/ref/heads/main)"
seed; echo "$TIPB" > "$T/tip"; addrow 10 pr 1 11 "$((NOW - 5))"
drv "prs_base_tip $SLUG main"
[ "$(reads git/ref/heads/main)" = 0 ] && grep -qx "$TIPA" "$T/drv.out" && ok || bad "K10b a pr wake re-read the tip: $(cat "$T/drv.out")"

# ── K12: one read pair per PR_SNAPSHOT_TTL_S ──
seed
drv "$(seen a any - $((NOW - 120))); $(seen b pr 1 $((NOW - 120))); prs_changed $SLUG; prs_feed_fresh $SLUG"
[ "$(wreads)" = 1 ] && [ "$(sreads)" = 1 ] && ok || bad "K12 want 1+1 reads inside the TTL, got $(wreads)+$(sreads)"
out a=1 && out b=1 && ok || bad "K12 $(cat "$T/drv.out")"
awk -F'\t' -v OFS='\t' -v r="$((NOW - 61))" '{ $1 = r; print }' "$SNAPDIR/wakes.state" > "$T/st" && mv "$T/st" "$SNAPDIR/wakes.state"
drv "$(seen a any - $((NOW - 120)))"
[ "$(wreads)" = 2 ] && [ "$(sreads)" = 2 ] && ok || bad "K12 want 2+2 reads past the TTL, got $(wreads)+$(sreads)"

echo "pr-snapshot-wakes.bh-4661: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
