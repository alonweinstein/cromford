#!/bin/bash
# tests/env-path-port-b-test.sh — batch-B (orc-job .. with-job) reads its env
# through bin/lib/env-path.sh, and keeps today's path when that lib is absent.
#
# WHY THIS EXISTS. The port is mechanical, so the temptation is to "prove" it by
# grepping the scripts for $HENV. That proves somebody typed a variable name. The
# thing that can actually break is the RESOLUTION: a script that now resolves to
# a different directory than it read yesterday loses its token silently, and the
# lane just stops doing its job with a 0 exit code. So every case here runs a
# REAL batch-B script end to end and asserts on what the script printed:
#
#   1. with the lib present and no $HARNESS/env, the script reads /etc/harness/env
#      (ETC_HARNESS_ENV here) — the whole point of the migration;
#   2. HARNESS_ENV_DIR still outranks it (fly pool machines set it);
#   3. copied ALONE into a scratch bin/ with no bin/lib — the shape 46 suites in
#      this repo use — the inline fallback prints exactly $HARNESS/env, today's
#      path, and transcript-scrub.sh still honours HARNESS_ENV_DIR there;
#   4. a NON-scrubber entry point (bin/pool-cap.sh) resolves the same way, so
#      case 1 is a property of the snippet and not of one script.
#
# Two scripts carry the load because they are the two shapes in the batch: a
# reader that globs the whole env dir (transcript-scrub.sh) and a reader that
# greps one file for one key (pool-cap.sh). Every asserted value is an invented
# fixture string; no real secret is read, asserted, or printed.
# Run from anywhere: tests/env-path-port-b-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The 52 files this slice ports. Embedded as data on purpose: the allowlist file
# that used to carry this list is DELETED by this slice (that deletion is what
# makes tests/env-path-test.sh scan these files for real), so reading it back
# would make this suite pass by reading nothing.
PORT_B="orc-job.sh orchestrate.sh orchestrator-burn.sh orphan-reconcile.sh
outcome-metrics.sh pipeline-health.sh poll-commands.sh lib/pool-account.sh
pool-cap.sh post-proposal.sh postmerge-qa.sh pr-owner-sweep.sh product-cmd.sh
push-proposal-assets.sh qa-clerk-ban.sh qa-session.sh quota-poll.sh
quota-status.sh rebase-train-ahead.sh rebase-train.sh reconcile-prs.sh
reopen-metrics.sh review-autopilot.sh review-prs.sh review-rescue.sh
review-tighten.sh rule-miner.sh run-build.sh run-decompose.sh run-preplan.sh
run-product.sh run-triage.sh runner-bench.sh security-scan.sh
stale-owed-tickets.sh sweep-stale-builds.sh tg-media.sh tickets-snapshot-push.sh
transcript-scrub.sh triage-gate.sh triage-map.sh triage-shard.sh tts-say.sh
unblocked-children.sh untriaged-sweep.sh vendor-spend-pull.sh verify-claims.sh
wake-loop.sh watchdog-ping.sh watchdog-poll.sh watchdog-responder.sh
with-job.sh"

ETC_VALUE=from-etc-secret-value
OVERRIDE_VALUE=from-override-value
ALONE_VALUE=alone-secret-value

mkdir -p "$T/a" "$T/etc" "$T/x"
printf 'X_TOKEN="%s"\n' "$ETC_VALUE" > "$T/etc/global.env"
printf 'Y_TOKEN="%s"\n' "$OVERRIDE_VALUE" > "$T/x/global.env"

# ══ 1. the real scrubber, lib present, no $HARNESS/env -> the etc dir ════════
# This is the migration itself: the box's env moved to /etc/harness/env and the
# script was never told. Before the port the scrubber read a hardcoded
# /root/harness/env and this value walked into the transcript.
OUT=$(printf 'x %s y\n' "$ETC_VALUE" \
  | env -u HARNESS_ENV_DIR HARNESS="$T/a" ETC_HARNESS_ENV="$T/etc" \
        bash "$DIR/bin/transcript-scrub.sh")
case "$OUT" in
  *"$ETC_VALUE"*) bad "etc-dir secret survived the scrubber: $OUT" ;;
  *'[REDACTED]'*) ok ;;
  *) bad "scrubber printed neither the value nor a redaction: $OUT" ;;
esac

# ══ 2. HARNESS_ENV_DIR outranks the etc dir ═════════════════════════════════
# fly/entrypoint.sh exports it on every pool machine, so this is the case that
# decides whether a pool builder reads its tmpfs or the hub's disk.
OUT=$(printf 'p %s q %s r\n' "$OVERRIDE_VALUE" "$ETC_VALUE" \
  | HARNESS_ENV_DIR="$T/x" HARNESS="$T/a" ETC_HARNESS_ENV="$T/etc" \
    bash "$DIR/bin/transcript-scrub.sh")
case "$OUT" in
  *"$OVERRIDE_VALUE"*) bad "HARNESS_ENV_DIR value was not redacted: $OUT" ;;
  *) ok ;;
esac
case "$OUT" in
  *"$ETC_VALUE"*) ok ;;
  *) bad "the etc dir was read even though HARNESS_ENV_DIR was set: $OUT" ;;
esac

# ══ 3. copied ALONE, no bin/lib -> the inline fallback, today's path ════════
# 46 suites in this repo copy one bin script into a scratch tree without
# bin/lib. If the snippet needed the library, every one of them would go red.
mkdir -p "$T/h/bin" "$T/h/env"
cp "$DIR/bin/transcript-scrub.sh" "$T/h/bin/"
printf 'Z_TOKEN="%s"\n' "$ALONE_VALUE" > "$T/h/env/global.env"
[ -e "$T/h/bin/lib/env-path.sh" ] && bad "scratch tree was supposed to have NO bin/lib"
OUT=$(printf 'm %s n\n' "$ALONE_VALUE" \
  | env -u HARNESS_ENV_DIR HARNESS="$T/h" ETC_HARNESS_ENV="$T/no-etc" \
        bash "$T/h/bin/transcript-scrub.sh")
case "$OUT" in
  *"$ALONE_VALUE"*) bad "fallback did not resolve \$HARNESS/env: $OUT" ;;
  *'[REDACTED]'*) ok ;;
  *) bad "copied-alone scrubber printed neither value nor redaction: $OUT" ;;
esac

# Same copied-alone shape, but the caller sets HARNESS_ENV_DIR and $HARNESS
# points nowhere — tests/transcript-push-test.sh's shape. transcript-scrub.sh
# documents HARNESS_ENV_DIR in its own header, and the port must not quietly
# drop that: with no library present, only the script's explicit
# ${HARNESS_ENV_DIR:-...} guard can honour it.
OUT=$(printf 'm %s n\n' "$ALONE_VALUE" \
  | HARNESS="$T/no-harness" HARNESS_ENV_DIR="$T/h/env" ETC_HARNESS_ENV="$T/no-etc" \
    bash "$T/h/bin/transcript-scrub.sh")
case "$OUT" in
  *"$ALONE_VALUE"*) bad "HARNESS_ENV_DIR was ignored without the lib: $OUT" ;;
  *'[REDACTED]'*) ok ;;
  *) bad "copied-alone override run printed neither value nor redaction: $OUT" ;;
esac

# ══ 4. a second entry point: bin/pool-cap.sh reads the same dir ═════════════
# Not a scrubber, not a secret — a number the Fly pool sizes itself from. If the
# cap silently reads 0 (unlimited) because global.env moved, the pool stops
# obeying its ceiling, which is a cost bug nobody sees until the invoice.
mkdir -p "$T/p1/bin" "$T/p1/env"
cp "$DIR/bin/pool-cap.sh" "$T/p1/bin/"
printf 'POOL_CAP_MAX=7\n' > "$T/p1/env/global.env"
GOT=$(env -u HARNESS_ENV_DIR -u POOL_CAP_MAX -u POOL_AUTOSCALE \
      HARNESS="$T/p1" ETC_HARNESS_ENV="$T/no-etc" \
      bash "$T/p1/bin/pool-cap.sh" bh455proj)
[ "$GOT" = 7 ] && ok || bad "pool-cap fallback read '$GOT' want 7"

mkdir -p "$T/p2/bin/lib" "$T/etc2"
cp "$DIR/bin/pool-cap.sh" "$T/p2/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/p2/bin/lib/"
printf 'POOL_CAP_MAX=7\n' > "$T/etc2/global.env"
[ -d "$T/p2/env" ] && bad "scratch root was supposed to have NO env dir"
GOT=$(env -u HARNESS_ENV_DIR -u POOL_CAP_MAX -u POOL_AUTOSCALE \
      HARNESS="$T/p2" ETC_HARNESS_ENV="$T/etc2" \
      bash "$T/p2/bin/pool-cap.sh" bh455proj)
[ "$GOT" = 7 ] && ok || bad "pool-cap read '$GOT' from the etc dir, want 7"

# ══ 5. the allowlist file is gone, so the guard scans these files for real ══
[ -e "$DIR/tests/env-path-allowlist.d/port-b.txt" ] \
  && bad "tests/env-path-allowlist.d/port-b.txt still exists — the guard is still skipping batch B" \
  || ok

# ══ 6. every ported file still parses ══════════════════════════════════════
SYNTAX_BAD=0
for b in $PORT_B; do
  f="$DIR/bin/$b"
  [ -f "$f" ] || { bad "ported file missing: bin/$b"; SYNTAX_BAD=1; continue; }
  bash -n "$f" || { bad "bash -n failed: bin/$b"; SYNTAX_BAD=1; }
done
[ "$SYNTAX_BAD" -eq 0 ] && ok

# ══ 7. the suites that drive these scripts, named and run ══════════════════
# The port touches 52 lanes. These nine are the ones whose fixtures actually
# execute a ported script (copied alone, or in place against a scratch root), so
# a broken line shape shows up here as a red suite rather than at 03:00 on a box.
for s in transcript-scrub-test.sh transcript-push-test.sh transcript-cost-test.sh \
         remediator-agent-test.sh pipeline-health-detectors-test.sh \
         pool-cap-refusal-test.sh sweep-stale-builds-test.sh \
         run-decompose-issues-test.sh queued-fly-custody-test.sh; do
  # -u SCRATCH: tests/lib/scratch.sh removes the tree named by an inherited
  # SCRATCH before making its own, so a child suite would delete THIS suite's $T.
  # -u JOB_ID: a harness build lane exports it, and transcript-push-test.sh has a
  # case about an UNCLAIMED lane — inheriting the runner's own job id makes that
  # fixture describe the wrong thing. CI runs these suites with neither set.
  if env -u SCRATCH -u T -u JOB_ID -u JOB_PHASE_ID bash "$DIR/tests/$s" >/dev/null 2>&1 </dev/null; then ok; else bad "regression suite red after the port: tests/$s"; fi
done

echo "env-path-port-b-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
