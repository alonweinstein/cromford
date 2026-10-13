#!/bin/bash
# tests/doorbell-coverage-test.sh — bin/doorbell-coverage-check.sh, driven.
#
# THE INCIDENT THIS PINS (cromford, 2026-09-15 -> 2026-09-16). The event
# doorbell is armed PER REPO (docs/EVENTS.md §4.3: the org-level hook it was
# designed as answers 403 for our PAT). bin/load-project.sh onboarded
# cromford three days after the one-time arming loop and gave it a registry
# row, a prompt and five cron lines — and no hook. The result was not an error
# anywhere: zero `wakes` rows, bin/triage-gate.sh braking every tick to
# `SKIP queue-unchanged`, and bin/orphan-reconcile.sh's 5-per-tick safety net
# left as the project's only intake, with 76 open ai-build issues behind 2 open
# PRs. So the assertions here are all about the difference between "armed",
# "missing" and "we could not tell", because collapsing any two of those three
# is what made a starved project look like a quiet one:
#
#   a. a repo whose ACTIVE hook points at the receiver is armed, and silent;
#   b. a repo with no hook at all is MISSING and alerts, and the alert carries
#      the arming command — the secret is pasted by a human, so an alert that
#      does not say what to type is a dead end;
#   c. a hook pointing somewhere ELSE, and an INACTIVE receiver hook, are both
#      MISSING — a row in the settings page is not a doorbell;
#   d. a repo whose hooks cannot be READ is UNREADABLE, never missing, and never
#      fails --strict: we cannot tell an unarmed repo from an un-adminable one;
#   e. ONE alert per repo per day, or the daily line becomes noise people mute;
#   f. the registry is the scope — every fleet.conf repo, `-` rows skipped;
#   g. --strict fails on missing (so load-project.sh can banner) and the plain
#      run never does (so the cron line cannot be the reason a tick goes red).
#
# Run from anywhere: tests/doorbell-coverage-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
SUT="$DIR/bin/doorbell-coverage-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SUT" ] || { echo "FAIL: bin/doorbell-coverage-check.sh missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RECEIVER="https://jobs.test.invalid/webhooks/github"
export JOBS_URL="https://jobs.test.invalid"
export HARNESS="$T/harness"
export HARNESS_ALERTS="$T/harness/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/flags"

# ── the registry under test ─────────────────────────────────────────────────
export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<EOF
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
armed-proj    Test/armed      -  -  1  box-test 100.0.0.1
nohook-proj   Test/nohook     -  -  2  box-test 100.0.0.1
elsewhere     Test/elsewhere  -  -  3  box-test 100.0.0.1
inactive      Test/inactive   -  -  4  box-test 100.0.0.1
unreadable    Test/unreadable -  -  5  box-test 100.0.0.1
noslug        -               -  -  6  box-test 100.0.0.1
EOF

# ── a `gh` that answers from fixtures, and runs the REAL jq filter ───────────
# The stand-in is first on PATH so bin/lib/gh-repo-token.sh's own visibility
# probe hits it too — otherwise the test would make live GitHub calls.
export FIXTURES="$T/fixtures"; mkdir -p "$FIXTURES"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'GH_EOF'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
EP="${1:-}"; shift
JQ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$EP" in
  */hooks)
    SLUG="${EP#/}"; SLUG="${SLUG#repos/}"; SLUG="${SLUG%/hooks}"
    F="$FIXTURES/${SLUG//\//_}.json"
    [ -f "$F" ] || exit 1
    if [ -n "$JQ" ]; then jq -r "$JQ" < "$F"; else cat "$F"; fi
    ;;
  repos/*|/repos/*) echo 12345 ;;
  *) exit 1 ;;
esac
GH_EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

hook() { # hook <active> <url>  -> one hook object
  printf '{"active":%s,"config":{"url":"%s"}}' "$1" "$2"
}
printf '[%s]\n' "$(hook true "$RECEIVER")"                  > "$FIXTURES/Test_armed.json"
printf '[]\n'                                               > "$FIXTURES/Test_nohook.json"
printf '[%s]\n' "$(hook true 'https://example.invalid/x')"  > "$FIXTURES/Test_elsewhere.json"
printf '[%s]\n' "$(hook false "$RECEIVER")"                 > "$FIXTURES/Test_inactive.json"
# Test/unreadable gets NO fixture file on purpose -> the fake gh exits 1.

run() { OUT=$("$SUT" "$@" 2>&1); RC=$?; }
alerts() { cat "$HARNESS_ALERTS" 2>/dev/null; }
reset_alerts() { : > "$HARNESS_ALERTS"; rm -f "$HARNESS"/flags/alerted-doorbell-*; }

# ───────────────────────────────────────────────────────────────────────────
# a. armed repo: silent, rc 0, and not one alert
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run --repo Test/armed
[ "$RC" = 0 ] && ok || bad "armed repo: rc=$RC, expected 0"
case "$OUT" in *"Test/armed: doorbell armed"*) ok ;; *) bad "armed repo: not reported armed — $OUT" ;; esac
case "$OUT" in *"checked=1 missing=0 unreadable=0"*) ok ;; *) bad "armed repo: bad summary — $OUT" ;; esac
[ -z "$(alerts)" ] && ok || bad "armed repo alerted: $(alerts)"

# also under --strict: an armed repo can never fail a caller
run --repo Test/armed --strict
[ "$RC" = 0 ] && ok || bad "armed repo --strict: rc=$RC, expected 0"

# ───────────────────────────────────────────────────────────────────────────
# b. no hook: MISSING, alerts, and the alert is actionable
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run --repo Test/nohook
[ "$RC" = 0 ] && ok || bad "nohook plain run: rc=$RC, expected 0 (a detector must not fail the cron tick)"
case "$OUT" in *"Test/nohook: doorbell MISSING"*) ok ;; *) bad "nohook: not reported missing — $OUT" ;; esac
A=$(alerts)
[ "$(printf '%s\n' "$A" | grep -c .)" = 1 ] && ok || bad "nohook: expected exactly 1 alert line, got: $A"
case "$A" in *"[doorbell]"*) ok ;; *) bad "nohook alert missing the [doorbell] lane tag: $A" ;; esac
case "$A" in *"Test/nohook"*) ok ;; *) bad "nohook alert does not name the repo: $A" ;; esac
case "$A" in *"$RECEIVER"*) ok ;; *) bad "nohook alert does not name the receiver it should point at: $A" ;; esac
# the remedy, because the secret is pasted by a human and this box cannot
case "$A" in *"gh api -X POST /repos/Test/nohook/hooks"*) ok ;; *) bad "nohook alert carries no arming command: $A" ;; esac
case "$A" in *GITHUB_WEBHOOK_SECRET*) ok ;; *) bad "nohook alert does not name the secret: $A" ;; esac
# and the consequence, so a reader knows why it matters
case "$A" in *queue-unchanged*) ok ;; *) bad "nohook alert does not name the brake it causes: $A" ;; esac

# g. --strict is how load-project.sh learns to banner
reset_alerts
run --repo Test/nohook --strict
[ "$RC" = 1 ] && ok || bad "nohook --strict: rc=$RC, expected 1"

# ───────────────────────────────────────────────────────────────────────────
# c. a hook is not a DOORBELL: wrong url, and inactive, are both missing
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run --repo Test/elsewhere
case "$OUT" in *"Test/elsewhere: doorbell MISSING"*) ok ;; *) bad "hook pointing elsewhere read as armed — $OUT" ;; esac
reset_alerts
run --repo Test/inactive
case "$OUT" in *"Test/inactive: doorbell MISSING"*) ok ;; *) bad "INACTIVE receiver hook read as armed — $OUT" ;; esac

# ───────────────────────────────────────────────────────────────────────────
# d. unreadable is its own verdict: never "missing", never fails --strict
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run --repo Test/unreadable --strict
[ "$RC" = 0 ] && ok || bad "unreadable --strict: rc=$RC, expected 0 (we cannot tell unarmed from un-adminable)"
case "$OUT" in *"UNREADABLE"*) ok ;; *) bad "unreadable: not reported as such — $OUT" ;; esac
case "$OUT" in *"checked=1 missing=0 unreadable=1"*) ok ;; *) bad "unreadable counted as missing — $OUT" ;; esac
# TEST-CHANGE (pool doctor, 2026-09-24): this line used to require the alert to
# ask for "a PAT with admin:repo_hook". The fleet authenticates as GitHub Apps,
# and the remedy that needs no PAT is on the App (its own webhook, or the
# Webhooks permission) — tests/doorbell-app-hook.pool-doctor-test.sh drives it.
# The property is unchanged: the alert still names exactly what to fix.
case "$(alerts)" in *"GitHub App"*"$RECEIVER"*) ok ;; *) bad "unreadable alert does not name the App-side fix and the receiver: $(alerts)" ;; esac
case "$(alerts)" in *"PAT with"*|*"admin:repo_hook"*) bad "unreadable alert still asks for a PAT: $(alerts)" ;; *) ok ;; esac

# ───────────────────────────────────────────────────────────────────────────
# e. one alert per repo per day — the daily line must stay readable
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run --repo Test/nohook
run --repo Test/nohook
run --repo Test/nohook
[ "$(alerts | grep -c .)" = 1 ] && ok || bad "three runs wrote $(alerts | grep -c .) alert lines, expected 1"
# and a NEW day says it again
rm -f "$HARNESS"/flags/alerted-doorbell-*
run --repo Test/nohook
[ "$(alerts | grep -c .)" = 2 ] && ok || bad "a fresh day did not re-alert: $(alerts | grep -c .) lines"

# ───────────────────────────────────────────────────────────────────────────
# f. the registry is the scope, and a `-` repo row is not a repo
# ───────────────────────────────────────────────────────────────────────────
reset_alerts
run
# 5 real slugs; the `-` row is skipped
case "$OUT" in *"checked=5 missing=3 unreadable=1"*) ok ;; *) bad "registry walk: bad summary — $OUT" ;; esac
case "$OUT" in *"Test/armed: doorbell armed"*) ok ;; *) bad "registry walk skipped the armed repo — $OUT" ;; esac
case "$OUT" in *noslug*) bad "registry walk tried to check the '-' repo row — $OUT" ;; *) ok ;; esac
[ "$(alerts | grep -c .)" = 4 ] && ok || bad "registry walk: expected 4 alert lines (3 missing + 1 unreadable), got $(alerts | grep -c .)"
# the plain fleet-wide run still never fails
[ "$RC" = 0 ] && ok || bad "registry walk rc=$RC, expected 0"

# the log is the record even when nothing alerted
grep -q "Test/armed doorbell=armed" "$HARNESS/logs/doorbell-coverage-check.log" && ok \
  || bad "armed repo left no line in logs/doorbell-coverage-check.log"

# ───────────────────────────────────────────────────────────────────────────
# h. onboarding asks: load-project.sh calls the check for the repo it loaded
# ───────────────────────────────────────────────────────────────────────────
grep -q 'bin/doorbell-coverage-check.sh --repo "\$SLUG" --strict' "$DIR/bin/load-project.sh" && ok \
  || bad "bin/load-project.sh does not check the doorbell for the repo it onboards"
grep -q 'DOORBELL NOT ARMED' "$DIR/bin/load-project.sh" && ok \
  || bad "bin/load-project.sh has no banner for an unarmed doorbell"
# and the hub runs it daily
grep -q 'doorbell-coverage-check.sh' "$(rendered_cron hub)" && ok \
  || bad "cron/hub.cron has no doorbell-coverage-check line"

# ───────────────────────────────────────────────────────────────────────────
# i. the banner RENDERS — the block is extracted from load-project.sh and run
# ───────────────────────────────────────────────────────────────────────────
# Not a grep: the first draft of this banner used an UNQUOTED here-doc, so bash
# ran `wakes` as a command substitution (printing "wakes: command not found"
# and a hole where the word should be) and folded every backslash-continued gh
# line into one unusable line — swallowing the BANNER delimiter with them. The
# banner is a command a human retypes at the exact moment onboarding went
# wrong; a mangled one is worse than none, and only executing it says so.
BLOCK=$(sed -n '/^echo "== doorbell =="/,/^fi$/p' "$DIR/bin/load-project.sh")
[ -n "$BLOCK" ] && ok || bad "could not extract the doorbell block from load-project.sh"
reset_alerts
BOUT=$(cd "$DIR" && SLUG=Test/nohook bash -c "set -euo pipefail; $BLOCK" 2>&1); BRC=$?
[ "$BRC" = 0 ] && ok || bad "the doorbell block failed onboarding (rc=$BRC) — it must never be fatal"
case "$BOUT" in *"command not found"*) bad "the banner ran a command substitution: $BOUT" ;; *) ok ;; esac
case "$BOUT" in *'DOORBELL NOT ARMED ON Test/nohook'*) ok ;; *) bad "banner did not interpolate the slug — $BOUT" ;; esac
case "$BOUT" in *'no "wakes" rows'*) ok ;; *) bad "banner lost the word it backtick-substituted away — $BOUT" ;; esac
# the arming command survives as SEPARATE continued lines, not one folded blob
case "$BOUT" in *"-f 'config[secret]=<the worker GITHUB_WEBHOOK_SECRET>'"*) ok ;; *) bad "banner lost the secret argument — $BOUT" ;; esac
[ "$(printf '%s\n' "$BOUT" | grep -c "events\[\]=")" -ge 4 ] && ok \
  || bad "the gh continuation lines were folded together — $BOUT"
case "$BOUT" in *BANNER*) bad "the here-doc delimiter leaked into the output — $BOUT" ;; *) ok ;; esac
# an ARMED repo prints no banner at all
BOUT=$(cd "$DIR" && SLUG=Test/armed bash -c "set -euo pipefail; $BLOCK" 2>&1)
case "$BOUT" in *"DOORBELL NOT ARMED"*) bad "armed repo still got the banner — $BOUT" ;; *) ok ;; esac

echo "doorbell-coverage-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
