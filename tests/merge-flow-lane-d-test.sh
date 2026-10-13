#!/bin/bash
# tests/merge-flow-lane-d-test.sh — Lane D (2026-09-24): an approval the hub
# itself produces rings the conductor for THAT PR at once, instead of waiting
# for the next */5 tick (bin/lib/keyed-wake.sh, called from the detached
# re-review's finish in bin/lib/mc/rebase.sh mc_rereview_run).
#
#   KW-1 kw_conductor launches `MC_ONLY_PR=<slug>#<n> bin/merge-conductor.sh`
#   KW-2 a second wake for the same PR inside MC_KEYED_WAKE_MIN_S launches nothing
#   KW-3 MC_KEYED_WAKE=0 launches nothing; a bad slug or number launches nothing
#   KW-4 a detached re-review that finishes APPROVE rings the conductor for its PR
#   KW-5 one that finishes BLOCK (or with no verdict) rings nothing
#   KW-6 the two knobs are registered on the merge-conductor lane
# No network, no gh: the conductor is a stub that records what it was handed.
# Run from anywhere: tests/merge-flow-lane-d-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/keyed-wake.sh" ] || { echo "FAIL: bin/lib/keyed-wake.sh does not exist"; exit 1; }

export HARNESS="$T/h"; mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/locks"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/keyed-wake.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# The conductor stub: one line per launch, naming the key it was handed.
cat > "$T/h/bin/merge-conductor.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${MC_ONLY_PR:-<none>}" >> "$T/launches.txt"
EOF
chmod +x "$T/h/bin/merge-conductor.sh"
launches() { grep -c . "$T/launches.txt" 2>/dev/null || true; }
# wait_for <condition> — poll up to 5s; the launch is detached by design.
wait_for() { local i=0; while [ "$i" -lt 100 ]; do eval "$1" && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

# shellcheck source=bin/lib/keyed-wake.sh
. "$T/h/bin/lib/keyed-wake.sh" || exit 1

# KW-1
: > "$T/launches.txt"
kw_conductor example-org/demo-os 31 "test" && ok || bad "KW-1 kw_conductor must answer rc 0 when it launches"
wait_for '[ "$(launches)" = 1 ]' && ok || bad "KW-1 one keyed conductor launch (got $(launches))"
grep -qx 'example-org/demo-os#31' "$T/launches.txt" && ok || bad "KW-1 the launch carries MC_ONLY_PR=example-org/demo-os#31 (got $(cat "$T/launches.txt"))"
# KW-2
kw_conductor example-org/demo-os 31 "again" && bad "KW-2 a second wake inside the window must answer rc 1" || ok
sleep 0.3; [ "$(launches)" = 1 ] && ok || bad "KW-2 no second launch inside MC_KEYED_WAKE_MIN_S (got $(launches))"
# ...another PR is its own key
kw_conductor example-org/demo-os 32 "other" && wait_for '[ "$(launches)" = 2 ]' && ok || bad "KW-2 a different PR is not deduped against #31 (got $(launches))"
# ...and past the window it launches again
MC_KEYED_WAKE_MIN_S=0 kw_conductor example-org/demo-os 31 "later" && wait_for '[ "$(launches)" = 3 ]' && ok \
  || bad "KW-2 past the window the same PR launches again (got $(launches))"
# KW-3
: > "$T/launches.txt"; rm -rf "$T/h/state/merge-conductor/keyed-wake"
MC_KEYED_WAKE=0 kw_conductor example-org/demo-os 41 "off" && bad "KW-3 MC_KEYED_WAKE=0 must answer rc 1" || ok
kw_conductor 'example-org/demo-os;rm' 41 "bad" && bad "KW-3 a malformed slug must answer rc 1" || ok
kw_conductor example-org/demo-os 4x1 "bad" && bad "KW-3 a malformed number must answer rc 1" || ok
sleep 0.3; [ "$(launches)" = 0 ] && ok || bad "KW-3 nothing launched (got $(cat "$T/launches.txt"))"

# KW-4 / KW-5 — the re-review finish, through the real mc_rereview_run.
(
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
  mc_rereview() { cat "$T/verdict"; }
  jf="$MC_RR_DIR/job.json"; mkdir -p "$MC_RR_DIR"
  : > "$T/launches.txt"; rm -rf "$T/h/state/merge-conductor/keyed-wake"
  echo APPROVE > "$T/verdict"
  mc_rr_write "$jf" running 0 "$(mc_now)" 0 - headsha revsha "$T/out"
  mc_rereview_run example-org/demo-os 51 demo "https://github.com/example-org/demo-os/pull/51" revsha headsha "" "$jf" "$T/out"
  [ "$(mc_rr_field "$jf" status)" = done ] || echo "FAIL: KW-4 the job file must still record done (got $(mc_rr_field "$jf" status))"
  wait_for 'grep -qx "example-org/demo-os#51" "$T/launches.txt"' || echo "FAIL: KW-4 an APPROVE re-review must ring the conductor for its PR (got $(cat "$T/launches.txt"))"
  grep -q "example-org/demo-os#51 KEYED_WAKE" "$MC_LOG" || echo "FAIL: KW-4 the wake is one conductor log line (log: $(tail -3 "$MC_LOG"))"
  : > "$T/launches.txt"; rm -rf "$T/h/state/merge-conductor/keyed-wake"
  echo BLOCK > "$T/verdict"
  mc_rr_write "$jf" running 0 "$(mc_now)" 0 - headsha2 revsha "$T/out"
  mc_rereview_run example-org/demo-os 52 demo "https://github.com/example-org/demo-os/pull/52" revsha headsha2 "" "$jf" "$T/out"
  sleep 0.3; [ ! -s "$T/launches.txt" ] || echo "FAIL: KW-5 a BLOCK re-review must ring nothing (got $(cat "$T/launches.txt"))"
) > "$T/kw45.txt" 2>&1
if grep -q '^FAIL:' "$T/kw45.txt"; then
  while IFS= read -r l; do bad "${l#FAIL: }"; done < <(grep '^FAIL:' "$T/kw45.txt")
else
  ok
fi

# KW-7 the stamps are pruned (review nit 4): a stamp older than a day goes on
# the next wake, a fresh one stays.
KWD="$T/h/state/merge-conductor/keyed-wake"; mkdir -p "$KWD"
touch -d '2 days ago' "$KWD/example-org_demo-os#77" "$KWD/example-org_demo-os#77.lock"
: > "$T/launches.txt"; kw_conductor example-org/demo-os 78 "prune" >/dev/null
[ ! -e "$KWD/example-org_demo-os#77" ] && [ ! -e "$KWD/example-org_demo-os#77.lock" ] && ok || bad "KW-7 a day-old stamp and its lock are pruned (left: $(ls "$KWD"))"
[ -e "$KWD/example-org_demo-os#78" ] && ok || bad "KW-7 the fresh stamp stays"

# KW-6 the knobs are registered, with the defaults this lib falls back to.
REG="$DIR/catalog/lanes.d/merge-conductor.json"
[ "$(jq -r '.knobs[] | select(.env=="MC_KEYED_WAKE") | .default' "$REG")" = 1 ] && ok || bad "KW-6 MC_KEYED_WAKE registered with default 1"
[ "$(jq -r '.knobs[] | select(.env=="MC_KEYED_WAKE_MIN_S") | .default' "$REG")" = 120 ] && ok || bad "KW-6 MC_KEYED_WAKE_MIN_S registered with default 120"

# KW-7 THE DAY-OLD PRUNE NEVER DELETES A LOCK FILE SOMEONE HOLDS (lead MINOR 4
# on #2215). Opening a lock with `9>>` does not touch its mtime, so a PR woken a
# day ago has a day-old .lock; `find -mmin +1440 -delete` removed it while a
# caller sat in flock on it, and the next caller locked a NEW inode. An in-flight
# caller (holding the per-PR lock under the directory lock, shared) is simulated
# here while another PR's wake runs the prune.
KWD="$T/h/state/merge-conductor/keyed-wake"; mkdir -p "$KWD"
OLDLK="$KWD/example-org_demo-os#77.lock"; : > "$OLDLK"; touch -d '2 days ago' "$OLDLK"
( exec 6>>"$KWD/.prune.lock"; flock -s 6; exec 9>>"$OLDLK"; flock 9; exec sleep 5 ) >/dev/null 2>&1 &
KWHOLD=$!
wait_for '! flock -n "$OLDLK" true 2>/dev/null' || true
MC_KEYED_WAKE_MIN_S=0 kw_conductor example-org/demo-os 78 "prune" >/dev/null
[ -e "$OLDLK" ] && ok || bad "KW-7 a held day-old lock file must survive another PR's prune"
kill "$KWHOLD" 2>/dev/null; wait "$KWHOLD" 2>/dev/null
# ...and with nobody holding anything, a day-old stamp and its lock do go
OLDST="$KWD/example-org_demo-os#79"; echo 1 > "$OLDST"; : > "$OLDST.lock"; touch -d '2 days ago' "$OLDST" "$OLDST.lock"
MC_KEYED_WAKE_MIN_S=0 kw_conductor example-org/demo-os 80 "prune" >/dev/null
[ ! -e "$OLDST" ] && [ ! -e "$OLDST.lock" ] && ok || bad "KW-7 an idle day-old stamp and lock are still pruned"

echo "merge-flow-lane-d-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
