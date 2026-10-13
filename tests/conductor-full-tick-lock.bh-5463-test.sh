#!/bin/bash
# tests/conductor-full-tick-lock.bh-5463-test.sh — BH-5463: one FULL (unkeyed)
# conductor tick per project at a time.
#
# On 2026-10-08 wake-loop started an unkeyed tick every 12-15 minutes and each
# one ran 536-1167 s, so two full ticks of cromford ran at once and the
# second one counted locked=82 of 100. The full tick now takes
# locks/merge-conductor-<project>-fulltick.lock with `flock -n`, in a holder
# subshell that tick_project and its detached lanes never see. A keyed tick
# (MC_ONLY_PR) takes no such lock.
#
# Every case drives the WHOLE "$DIR/bin/merge-conductor.sh" over two projects,
# a (#7) and b (#3), with the real flock. The gh stub sleeps $GH_SLOW seconds on
# project a's open-PR list read, so a tick stays inside tick_project.
#   F1 two full ticks at once: one run, one skip line, one list read of a
#   F2 an externally held lock: the skip writes no metrics, no tick-a.json and
#      no GitHub read for a; b ticks in full
#   F3 a keyed tick runs while a full tick holds the lock
#   F4 no child of the tick holds the lock fd; the lock is free after the tick
#   F5 the lock is per project: b's lock is free after the tick
#   F6 MC_FULL_TICK_SINGLE=0: no lock, a ticks; the skip text never reuses the
#      retired "still holds this project's lock" wording
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-full-tick-lock.bh-5463-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -d /proc/self/fd ] || { echo "no /proc — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
( export HARNESS="$H"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || { echo "FAIL: conductor fixture"; exit 1; }
scratch_install_closure bin/merge-conductor.sh "$H" >/dev/null || { echo "FAIL: closure install failed for bin/merge-conductor.sh"; exit 1; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
mkdir -p "$H/tmp" "$T/repos/a/.git" "$T/repos/b/.git"
printf 'a example-org/a https://a.example /api/board 2 local\nb example-org/b https://b.example /api/board 2 local\n' > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
cat > "$T/fakebin/git" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/git"

sha() { printf "$1%.0s" {1..40}; }
# pr_json <repo> <n> — one open PR, in the list shape and the pulls/<n> shape.
pr_list() {
  jq -nc --arg r "$1" --argjson n "$2" --arg h "$(sha "$2")" '[{number:$n,
    html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:"2026-10-08T00:00:00Z", created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]'
}
pr_one() {
  jq -nc --arg r "$1" --argjson n "$2" --arg h "$(sha "$2")" '{number:$n, state:"open", merged_at:null, draft:false,
    html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)), user:{login:"operator"}, labels:[],
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}},
    mergeable:true, mergeable_state:"behind", updated_at:"2026-10-08T00:00:00Z"}'
}
mkdir -p "$T/fx"
pr_list example-org/a 7 > "$T/fx/list-a.json"; pr_one example-org/a 7 > "$T/fx/a-7.json"
pr_list example-org/b 3 > "$T/fx/list-b.json"; pr_one example-org/b 3 > "$T/fx/b-3.json"

# The gh stub. Every call is logged as `<pid> <argv>`. Project a's open-PR list
# read writes the stub's own pid to $GHT/gh-pid-a and then sleeps $GH_SLOW.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$$" "$*" >> "$GHT/gh-calls.txt"
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"auth token"*) echo fixture-token; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -X PATCH"*) exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
esac
case "$p" in
  repos/example-org/[ab]/pulls|repos/example-org/[ab]/pulls\?state=open*)
    r="${p#repos/example-org/}"; r="${r%%/*}"
    if [ "$r" = a ]; then printf '%s\n' "$$" > "$GHT/gh-pid-a"; sleep "${GH_SLOW:-0}"; fi
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/fx/list-$r.json" || echo '[]' ;;
  repos/example-org/[ab]/pulls\?state=closed*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/example-org/[ab]/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/example-org/[ab]/pulls/[0-9]*)
    r="${p#repos/example-org/}"; r="${r%%/*}"; n="${p##*/pulls/}"; n="${n%%[!0-9]*}"
    if [ -f "$GHT/fx/$r-$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/fx/$r-$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; fi ;;
  repos/example-org/[ab]/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *"actions/runs"*) restpr --runs 'in_progress|' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

LOG="$H/logs/merge-conductor.log"
LK_A="$H/locks/merge-conductor-a-fulltick.lock"
LK_B="$H/locks/merge-conductor-b-fulltick.lock"
SKIP_A="TICK a skipped: another full tick of a is still running"

reset() {
  scratch_rm "$H/state/merge-conductor"
  mkdir -p "$H/state/merge-conductor"
  : > "$LOG"; : > "$T/gh-calls.txt"; rm -f "$T/gh-pid-a" "$T"/tick*.err
}
# tick <tag> [VAR=value...] — one whole conductor run; rc to $T/rc.<tag>.
tick() {
  local tag="$1"; shift
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$H" GHT="$T" HARNESS_SECRET=x TMPDIR="$H/tmp" \
      MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=1 \
      MC_TICK_SECS=0 MC_HEAD_LAG_MINS=0 MC_MAIN_RED_DETECT=0 MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 \
      FLEET_CONF="$H/fleet.conf" "$@" bash "$H/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.$tag.err"
    echo "$?" > "$T/rc.$tag" )
}
held() { ! flock -n "$1" true 2>/dev/null; }
waitfile() { local i; for i in $(seq 1 120); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }
# hold_a — hold a's full-tick lock from outside, as a running tick would.
# `flock -o` closes the fd before it runs sleep, so killing $HOLD frees it.
hold_a() {
  mkdir -p "$H/locks"; flock -o "$LK_A" sleep 60 & HOLD=$!
  local i; for i in $(seq 1 50); do held "$LK_A" && return 0; sleep 0.1; done
  return 1
}
unhold() { kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""; }
nskip() { grep -c "$SKIP_A" "$LOG" 2>/dev/null; }
nmetrics() { grep -cE "TICK $1 tick=" "$LOG" 2>/dev/null; }
nlist_a() { grep -cE 'repos/example-org/a/pulls(\?state=open| |$)' "$T/gh-calls.txt"; }
mclog() { tail -20 "$LOG" 2>/dev/null; }

# ── F1: two full ticks at once -> one run ────────────────────────────────────
reset
tick one GH_SLOW=3 &
P1=$!
waitfile "$T/gh-pid-a" || bad "F1 the first tick never read a's list: $(mclog) $(cat "$T/tick.one.err")"
tick two
wait "$P1"
[ "$(cat "$T/rc.one" 2>/dev/null)" = 0 ] && ok || bad "F1 tick one rc=$(cat "$T/rc.one" 2>/dev/null) $(tail -3 "$T/tick.one.err")"
[ "$(cat "$T/rc.two" 2>/dev/null)" = 0 ] && ok || bad "F1 tick two rc=$(cat "$T/rc.two" 2>/dev/null) $(tail -3 "$T/tick.two.err")"
[ "$(nskip)" = 1 ] && ok || bad "F1 expected exactly one '$SKIP_A' line, got $(nskip): $(mclog)"
[ "$(nmetrics a)" = 1 ] && ok || bad "F1 expected exactly one 'TICK a tick=' metrics line, got $(nmetrics a): $(mclog)"
[ "$(nlist_a)" = 1 ] && ok || bad "F1 a's open-PR list was read $(nlist_a) times, expected 1: $(cat "$T/gh-calls.txt")"
# b has its own lock: each run either ticks b or skips it with b's own line
# (tick one's b can still be running when tick two starts).
nb=$(( $(nmetrics b) + $(grep -c 'TICK b skipped: another full tick of b is still running' "$LOG") ))
[ "$nb" = 2 ] && [ "$(nmetrics b)" -ge 1 ] && ok || bad "F1 b must tick or skip once per run, got $(nmetrics b) metrics lines ($nb total)"
held "$LK_A" && bad "F1 a's full-tick lock is still held after both ticks ended" || ok

# ── F2 + F5: an externally held lock -> the skip writes nothing; b ticks ─────
reset
printf '{"tick":"fixture","project":"a","started_at":1700000000}\n' > "$H/state/merge-conductor/tick-a.json"
hold_a || bad "F2 the test could not take a's lock"
tick f2
unhold
[ "$(cat "$T/rc.f2" 2>/dev/null)" = 0 ] && ok || bad "F2 rc=$(cat "$T/rc.f2" 2>/dev/null) $(tail -3 "$T/tick.f2.err")"
[ "$(nskip)" = 1 ] && ok || bad "F2 expected one skip line, got $(nskip): $(mclog)"
[ "$(nmetrics a)" = 0 ] && ok || bad "F2 a skipped tick wrote a metrics line: $(mclog)"
[ "$(jq -r .started_at "$H/state/merge-conductor/tick-a.json" 2>/dev/null)" = 1700000000 ] && ok \
  || bad "F2 a skipped tick rewrote tick-a.json: $(cat "$H/state/merge-conductor/tick-a.json" 2>/dev/null)"
grep -q 'example-org/a' "$T/gh-calls.txt" && bad "F2 a skipped tick read GitHub for a: $(grep 'example-org/a' "$T/gh-calls.txt")" || ok
[ "$(nmetrics b)" = 1 ] && ok || bad "F2/F5 project b did not tick while a was held: $(mclog)"
grep -q 'example-org/b/pulls' "$T/gh-calls.txt" && ok || bad "F2/F5 project b read no list"
held "$LK_B" && bad "F5 b's full-tick lock is held after the tick" || ok

# ── F3: a keyed tick runs while a full tick holds the lock ───────────────────
reset
hold_a || bad "F3 the test could not take a's lock"
tick f3 MC_ONLY_PR=example-org/a#7
unhold
[ "$(cat "$T/rc.f3" 2>/dev/null)" = 0 ] && ok || bad "F3 rc=$(cat "$T/rc.f3" 2>/dev/null) $(tail -3 "$T/tick.f3.err")"
[ "$(nskip)" = 0 ] && ok || bad "F3 a keyed tick logged the full-tick skip: $(mclog)"
grep -q 'repos/example-org/a/pulls' "$T/gh-calls.txt" && ok || bad "F3 the keyed tick read nothing for a: $(cat "$T/gh-calls.txt")"
awk -F'\t' '$1=="example-org/a#7"' "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null | grep -q . && ok \
  || bad "F3 the keyed tick wrote no row for example-org/a#7: $(mclog)"

# ── F4: no child of the tick holds the lock ──────────────────────────────────
reset
tick f4 GH_SLOW=3 &
P4=$!
if waitfile "$T/gh-pid-a"; then
  sleep 0.3
  GHPID=$(cat "$T/gh-pid-a")
  holders=$(for f in /proc/[0-9]*/fd/*; do
      [ "$(readlink "$f" 2>/dev/null)" = "$LK_A" ] && { f="${f#/proc/}"; echo "${f%%/*}"; }
    done | sort -u)
  n=$(grep -c . <<<"$holders")
  [ "$n" = 1 ] && ok || bad "F4 expected exactly one pid with a's lock open, got $n (${holders//$'\n'/ })"
  grep -qx "$GHPID" <<<"$holders" && bad "F4 the gh child (pid $GHPID) inherited the lock fd" || ok
  held "$LK_A" && ok || bad "F4 a's full-tick lock is not held while the tick runs"
else
  bad "F4 the tick never read a's list: $(mclog)"
fi
wait "$P4"
held "$LK_A" && bad "F4 a's lock is still held after the tick ended" || ok

# ── F6: the kill switch ──────────────────────────────────────────────────────
reset
hold_a || bad "F6 the test could not take a's lock"
tick f6 MC_FULL_TICK_SINGLE=0
unhold
[ "$(nskip)" = 0 ] && ok || bad "F6 MC_FULL_TICK_SINGLE=0 still skipped: $(mclog)"
[ "$(nmetrics a)" = 1 ] && ok || bad "F6 MC_FULL_TICK_SINGLE=0: a did not tick: $(mclog)"
# The control: the same hold with the knob unset skips, and the skip text is new.
reset
hold_a || bad "F6 control: the test could not take a's lock"
tick f6c
unhold
[ "$(nskip)" = 1 ] && ok || bad "F6 control: the default did not skip a held project: $(mclog)"
grep -q "still holds this project's lock" "$LOG" && bad "F6 the skip reuses the retired text" || ok

echo "conductor-full-tick-lock.bh-5463-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
