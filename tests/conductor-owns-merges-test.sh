#!/bin/bash
# tests/conductor-owns-merges-test.sh — flags/conductor-owns-merges makes
# bin/merge-conductor.sh the fleet's ONE merger (docs/MERGE-CONDUCTOR.md §9).
#
# WHY THIS IS THE TEST THAT MATTERS. The conductor was built because a PR has no
# owner between "open" and "merged": six actors can merge it, each has a reason
# to walk away, and none comes back. Giving the conductor the job is only half
# the change — the other half is the other mergers STANDING DOWN, and a stand-down
# that half-works is worse than none, because two owners racing one PR is exactly
# the shape that produced the incident. So each site is DRIVEN here with the flag
# on and with it off: on, nothing may reach `gh pr merge` and nothing may be
# pushed onto the box queue; off, the behaviour must be byte-for-byte what it was.
#
# The entries a stood-down queue is holding are KEPT, never deleted — removing
# the flag has to hand the work straight back.
# Run from anywhere: tests/conductor-owns-merges-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" "$T/h/builds" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# bin/lib/gh-rest.sh rides with the lib because the queue's state read goes
# through it (BH-784); without it every read answers "unverifiable" and the
# queue skips the row, which would let this suite pass the stand-down half on
# a broken read instead of on the flag.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
printf 'p o/p - - 2 box-p\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"; : > "$T/h/env/p.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lander.sh"; chmod +x "$T/h/bin/lander.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
# gh: every call is recorded; a merge is recorded separately so "did anything try
# to land a PR" is a fact and not a reading of the code.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; exit 0 ;;
  *"api repos/"*"/rulesets"*) : ;;
  *"--json state,isInMergeQueue"*) echo "MERGED false" ;;
  # The tier-1 gate and the tier-2 sweep both read the bare state; what it must
  # say differs per section, so the section sets it. (The gate used to read
  # state,isInMergeQueue in one call; it now reads state and asks the queue
  # PROVIDER separately, because isInMergeQueue is GitHub's queue only.)
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"--json mergeCommit"*) echo deadbeefcafe ;;
  # The tier-2 sweep asks the same question over REST since BH-784
  # (gh api -i -X GET repos/<slug>/pulls/<n>, judged on the HTTP status line),
  # so the same fixture state is printed as a whole response through restpr.
  *"api -i -X GET repos/o/p/pulls/"*)
    restpr "\$(cat "$T/prstate" 2>/dev/null || echo OPEN)" headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
echo OPEN > "$T/prstate"

# ============================================================================
# 1. bin/merge-queue.sh — the per-box landing path
# ============================================================================
mq() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-queue.sh" p >/dev/null 2>&1 ) || true; }
mkdir -p "$T/h/state/merge-queue/p"; : > "$T/merge-calls.txt"; : > "$T/gh-calls.txt"
touch "$T/h/state/merge-queue/p/7"
touch "$T/h/flags/conductor-owns-merges"
mq
[ -s "$T/merge-calls.txt" ] && bad "the box merge queue must not run gh pr merge while conductor-owns-merges is on" || ok
[ -f "$T/h/state/merge-queue/p/7" ] && ok || bad "a stood-down queue must KEEP its entries — removing the flag hands them straight back"
grep -q 'conductor-owns-merges' "$T/h/logs/merge-queue.log" && ok || bad "the stand-down must say why in the log"
rm -f "$T/h/flags/conductor-owns-merges"
MQ_BEFORE=$(grep -c 'conductor-owns-merges' "$T/h/logs/merge-queue.log" || true)
mq
MQ_AFTER=$(grep -c 'conductor-owns-merges' "$T/h/logs/merge-queue.log" || true)
[ "$MQ_BEFORE" = "$MQ_AFTER" ] && ok || bad "with the flag off the queue must not stand down (stand-downs: $MQ_BEFORE -> $MQ_AFTER)"

# BH-1366: section 2 drove bin/tier2-merge-sweep.sh, the tier-2 FEEDER, and
# pinned that flags/conductor-owns-merges stood it down. That lane is retired —
# the enqueue now happens at the APPROVE verdict — and the same stand-down is
# pinned at its new home by tests/merge-queue-enqueue-on-verdict.bh-1366-test.sh
# (§A8 for bin/run-build.sh, §B4 for bin/review-prs.sh).

# ============================================================================
# 3. bin/run-build.sh's tier-1 merge gate, extracted and driven
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the tier-1 merge gate — markers missing?"
run_gate() { # run_gate <flag on|off> ; prints the RESULT line
  if [ "$1" = on ]; then touch "$T/h/flags/conductor-owns-merges"; else rm -f "$T/h/flags/conductor-owns-merges"; fi
  rm -f "$T/RESULT" "$T/merge-calls.txt"; mkdir -p "$T/h/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/gate/review.md"; printf 'plan\n' > "$T/h/builds/gate/plan.md"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD="$T/h/builds/gate" ALERTS="$T/h/logs/ALERTS.log" \
      PROJECT=p KEY=TK-9 SLUG=o/p TIER=1 PR_URL=https://github.com/o/p/pull/9 \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        . "$0"' "$T/gate.sh" >/dev/null 2>&1 ) || true
  cat "$T/RESULT" 2>/dev/null
}
OUT=$(run_gate on)
[ -s "$T/merge-calls.txt" ] && bad "a tier-1 build must NOT merge its own PR while conductor-owns-merges is on" || ok
grep -q '^PR_CREATED https://github.com/o/p/pull/9' <<<"$OUT" && ok || bad "a stood-down tier-1 gate must still report PR_CREATED (got '$OUT')"
grep -q 'left to the merge conductor' "$T/h/builds/gate/pipeline.log" && ok || bad "the stand-down must say why in the build log"
# With the flag off the gate really merges, so GitHub answers MERGED afterwards.
echo MERGED > "$T/prstate"
OUT=$(run_gate off)
[ -s "$T/merge-calls.txt" ] && ok || bad "with the flag off a tier-1 build must merge its own PR exactly as it always has"
grep -q '^PR_MERGED https://github.com/o/p/pull/9' <<<"$OUT" && ok || bad "a real tier-1 merge must still report PR_MERGED (got '$OUT')"

echo "conductor-owns-merges-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
