#!/bin/bash
# tests/publish-cromford-takeover.bh-4834-test.sh — the retired "-share" mirror
# workflow is gone, and publish-cromford.yml carries what it used to (BH-4834,
# slice BH-4848).
#
# The old workflow held the daily schedule, the watchdog-stamp environment and
# the share-mirror stamp step, and eight suites pinned them there. Deleting it
# without moving those would leave the stamp with no sender and the suites
# pointed at a missing file. So this suite checks that the move happened, and
# that it did not quietly weaken the suites it moved.
#
#   S1      the acceptance grep: no tracked file outside the history dirs names
#           the old mirror repo, the old workflow file or its PAT secret
#   S6      the old workflow file is gone and publish-cromford.yml is present
#   S7      publish-cromford.yml (parsed as YAML): a daily schedule, the job runs
#           in the watchdog-stamp environment, and a "Stamp the outside dead-man"
#           step gated on success() AND the armed output, reading
#           WATCHDOG_STAMP_SECRET and posting to api/stamp/share-mirror
#   S7-neg  the same check on a copy with the stamp step's armed clause removed
#           must fail: an unarmed run must never stamp
#   S8      no retargeted suite has fewer ok/bad call sites than at the merge base
#   S9      bin/share/mapping.py's GUARD_SALT is still byte-identical: its literal
#           was split to clear S1, and the shipped digests depend on its value
#
# The three S1 patterns (and the S9 salt) are assembled from pieces so this file is not a hit on
# its own grep. No network, no clock.
#
# Run from anywhere: tests/publish-cromford-takeover.bh-4834-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP $1"; }
WF="$DIR/.github/workflows/publish-cromford.yml"
S="share"

# ── S1. the acceptance grep prints nothing ──────────────────────────────────
if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  skip "S1: not a git checkout"
else
  P1="cromford"'-share'
  P2="publish-"'share\.yml'
  P3="SHARE_"'PUBLISHER'
  HITS=$(git -C "$DIR" grep -n -e "$P1" -e "$P2" -e "$P3" -- . ':!.harness/specs' ':!docs/notes' ':!tests/fixtures' 2>&1)
  RC=$?
  if [ "$RC" -eq 1 ] && [ -z "$HITS" ]; then ok
  elif [ "$RC" -eq 0 ]; then bad "S1: the old mirror is still named outside the history dirs:
$HITS"
  else bad "S1: git grep rc $RC: $HITS"; fi
fi

# ── S6. the old workflow is gone, the new one is there ──────────────────────
[ ! -e "$DIR/.github/workflows/publish-$S.yml" ] && ok || bad "S6: .github/workflows/publish-$S.yml must be deleted"
[ -f "$WF" ] && ok || bad "S6: $WF not found"

# ── S7. the stamp, schedule and environment moved onto publish-cromford.yml ──
# check_wf <file>: rc 0 when every S7 property holds, else rc 1 and one line
# per missing property on stdout.
check_wf() {
  python3 - "$1" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
errs = []
on = w.get(True, w.get("on")) or {}
crons = [c.get("cron", "") for c in (on.get("schedule") or []) if isinstance(c, dict)]
if not any(re.fullmatch(r"\d+ \d+ \* \* \*", c) for c in crons):
    errs.append("no daily schedule cron (got %r)" % crons)
job = (w.get("jobs") or {}).get("publish") or {}
if job.get("environment") != "watchdog-stamp":
    errs.append("jobs.publish.environment is %r, want 'watchdog-stamp'" % job.get("environment"))
steps = [s for s in job.get("steps") or [] if s.get("name") == "Stamp the outside dead-man"]
if len(steps) != 1:
    errs.append("want exactly one 'Stamp the outside dead-man' step, found %d" % len(steps))
else:
    s = steps[0]
    cond = str(s.get("if", ""))
    if "steps.armed.outputs.armed == 'true'" not in cond:
        errs.append("stamp step if %r lacks the armed clause" % cond)
    if "success()" not in cond:
        errs.append("stamp step if %r lacks success()" % cond)
    if "secrets.WATCHDOG_STAMP_SECRET" not in str((s.get("env") or {}).get("STAMP_SECRET", "")):
        errs.append("stamp step env STAMP_SECRET does not read secrets.WATCHDOG_STAMP_SECRET")
    if "api/stamp/share-mirror" not in str(s.get("run", "")):
        errs.append("stamp step run body does not post to api/stamp/share-mirror")
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PY
}
if ! python3 -c 'import yaml' 2>/dev/null; then
  skip "S7: python3 yaml not available"
  skip "S7-neg: python3 yaml not available"
elif [ ! -f "$WF" ]; then
  bad "S7: $WF not found"
  bad "S7-neg: $WF not found"
else
  OUT=$(check_wf "$WF") && ok || bad "S7: publish-cromford.yml:
$OUT"
  # S7-neg: the armed clause removed from the stamp step only.
  NEG="$T/ungated.yml"
  sed "s/^\([[:space:]]*if: success()\) && steps\.armed\.outputs\.armed == 'true'[[:space:]]*\$/\1/" "$WF" > "$NEG"
  if cmp -s "$WF" "$NEG"; then
    bad "S7-neg: could not build the ungated fixture (no 'if: success() && steps.armed…' line in the workflow)"
  elif OUT=$(check_wf "$NEG"); then
    bad "S7-neg: a stamp step without the armed clause passed the S7 check"
  else
    case "$OUT" in *"lacks the armed clause"*) ok ;; *) bad "S7-neg: failed for the wrong reason: $OUT" ;; esac
  fi
fi

# ── S8. no retargeted suite lost an ok/bad call site ────────────────────────
if ! git -C "$DIR" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  skip "S8: no origin/main to compare against"
else
  MB=$(git -C "$DIR" merge-base HEAD origin/main)
  RX='(^|[^A-Za-z_])(ok|bad)([^A-Za-z_]|$)'
  for f in gitleaks-pin.bh-2115 share-gitleaks-required.bh-2059 harness-ci-runners.bh-1323 \
           harness-ci-runners.bh-1206 watchdog-url-offbox.bh-2091 progress-push.k2 \
           main-red-detector gh-app-default.c2; do
    P="tests/$f-test.sh"
    if ! BASE=$(git -C "$DIR" show "$MB:$P" 2>/dev/null); then
      bad "S8: $P is not in the merge base $MB"; continue
    fi
    if [ ! -f "$DIR/$P" ]; then bad "S8: $P was deleted"; continue; fi
    NB=$(printf '%s\n' "$BASE" | grep -cE "$RX")
    NW=$(grep -cE "$RX" "$DIR/$P")
    [ "$NW" -ge "$NB" ] && ok || bad "S8: $P has $NW ok/bad call sites, the merge base had $NB"
  done
fi

# ── S9. the guard salt kept its exact bytes ─────────────────────────────────
WANT="cromford"'-share/v1'
GOT=$(cd "$DIR/bin/share" && python3 -I -c 'import sys; sys.path.insert(0, "."); import mapping; print(mapping.GUARD_SALT)' 2>&1)
[ "$GOT" = "$WANT" ] && ok || bad "S9: GUARD_SALT is '$GOT', want '$WANT'"

echo "publish-cromford-takeover.bh-4834-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
