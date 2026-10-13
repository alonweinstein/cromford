#!/bin/bash
# tests/fly-pool-prurl-shape-test.sh — a url-less PR_CREATED is a BUILDER defect,
# not a token finding.
#
# THE DEFECT (BH-765, 2026-09-18). Four project-5 builds reaped a RESULT whose
# first line was `PR_CREATED  | SIZE: 614 product lines … | STACKED on …` — the
# claim was there, the URL was not. The gate in bin/fly-pool.sh takes field 2 of
# that line with `awk '{print $2}'`, so PRURL became the literal `|`;
# pr_state_rest answered `UNKNOWN unparseable-url`; the gate slept
# POOL_PR_VERIFY_SLEEP for a retry that could not differ, landed in the
# UNVERIFIABLE branch, and wrote an alert saying the PR "could NOT be read over
# REST with the admin gh token" — sending a human to fix a token that was fine.
# The first line was left as `PR_CREATED  | …`, which bin/blocked-resolver.sh
# reads as rebuild-landed while bin/board-closeout.sh (`PR_CREATED http*`) never
# matches it: a build nobody closes out.
#
# WHAT THIS SUITE PINS: field 2 that is not `https://github.com/<o>/<r>/pull/<n>`
# is decided from the LINE — RESULT_MALFORMED, one alert naming the builder and
# saying no gh call was made, zero gh calls, zero sleeps — and a well-formed URL
# still takes the old path byte for byte.
#
# HOW IT DRIVES: the gate and its REST reader are EXTRACTED VERBATIM from
# bin/fly-pool.sh by their `# >>>` / `# <<<` markers and run against a mktemp'd
# $HARNESS with a stub `gh` on PATH, exactly as
# tests/fly-pool-pr-verify-rest-test.sh does. The real bin/lib/gh-repo-token.sh
# is copied in and sourced before the gate, which is where bin/fly-pool.sh
# sources it. Assertions are on artifacts: the first line of $LOCAL/RESULT, the
# contents of ALERTS.log, and the stub's own call and sleep logs.
#
# Run from anywhere: tests/fly-pool-prurl-shape-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive this gate"; exit 1; }

GOODURL="https://github.com/example-org/project-5/pull/1"
LINE2='TIER: 2 | QA: manual — no browser on this box | migration: none'
# The line the four project-5 builds actually wrote, byte for byte.
BADLINE='PR_CREATED  | SIZE: 614 product lines across 1 file(s) — over 2x the 300-line threshold (600) — already tier-2 | STACKED on ticket/TK-2212 (parent PR not resolved)'

# ── the production block, lifted verbatim ────────────────────────────────────
marked() { # marked <start> <end> <file>
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
GATE="$T/gate.sh"; HELPERS="$T/helpers.sh"
marked '# >>> pr verify rest (BH-709)' '# <<< pr verify rest' "$DIR/bin/fly-pool.sh" > "$HELPERS"
marked '# >>> pr verify gate (BH-709)' '# <<< pr verify gate' "$DIR/bin/fly-pool.sh" > "$GATE"
sed -n '/^STAMP() {/p;/^say() {/p' "$DIR/bin/fly-pool.sh" > "$T/saystamp.sh"

# ── the stub gh ──────────────────────────────────────────────────────────────
# Records every invocation. Answers repo reads 200 and PR reads from
# $CASE/pr-<n>.resp, so a case that reaches GitHub at all leaves a trace.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$CASE/gh-calls.log"
[ "${1:-}" = api ] || exit 1
KIND=repo
for a in "$@"; do case "$a" in repos/*/pulls/*) KIND=pr ;; esac; done
if [ "$KIND" = pr ]; then
  N=$(( $(cat "$CASE/pr.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$N" > "$CASE/pr.n"
  F="$CASE/pr-$N.resp"; [ -f "$F" ] || F=$(ls "$CASE"/pr-*.resp 2>/dev/null | tail -1)
else
  F="$CASE/repo-1.resp"
fi
[ -n "$F" ] && [ -f "$F" ] || exit 1
CODE=$(head -n 1 "$F"); BODY=$(tail -n +2 "$F")
case "$CODE" in
  200) TXT="OK" ;; 404) TXT="Not Found" ;; 403) TXT="Forbidden" ;; *) TXT="Status" ;;
esac
case " $* " in
  *" -i "*) printf 'HTTP/2.0 %s %s\nx-stub: 1\n\n%s\n' "$CODE" "$TXT" "$BODY" ;;
  *)        printf '%s\n' "$BODY" ;;
esac
case "$CODE" in 2*) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin/gh"

# ── the driver: the real block, nothing restated ─────────────────────────────
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
LOG="$HARNESS/logs/fly-pool.log"
. "$SAYSTAMP"
# Recorded, never taken: the pause between read attempts is not the behaviour
# under test, and the whole point of S5 is that the malformed path never gets
# near it.
sleep() { printf 'sleep %s\n' "$*" >> "$CASE/sleeps.log"; }
RLINE=$(head -n 1 "$LOCAL/RESULT")
. "$HELPERS"
# Where bin/fly-pool.sh sources it: top level, before the reap loop.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
. "$GATE"
printf 'done\n' > "$CASE/drive.done"
DRIVE

resp() { printf '%s\n%s\n' "$2" "$3" > "$1"; }
newcase() { # newcase <name> <first RESULT line>
  CASE="$T/case-$1"; export CASE
  H="$CASE/harness"; LOCAL="$H/builds/pool-project-5-TK-2213-$NOW"
  mkdir -p "$LOCAL" "$H/logs" "$H/env" "$H/flags" "$H/bin/lib"
  cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" \
     "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/" 2>/dev/null
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  printf '%s\n%s\n' "$2" "$LINE2" > "$LOCAL/RESULT"
  resp "$CASE/pr-1.resp" 200 '{"state":"open","merged":false}'
  resp "$CASE/repo-1.resp" 200 '{"id":42}'
}
drive() {
  PATH="$T/bin:$PATH" HARNESS="$H" LOCAL="$LOCAL" P=project-5 KEY=TK-2213 \
    GATE="$GATE" HELPERS="$HELPERS" SAYSTAMP="$T/saystamp.sh" \
    POOL_PR_VERIFY_SLEEP=3 bash "$T/drive.sh" >/dev/null 2>&1
}
line1()   { head -n 1 "$LOCAL/RESULT"; }
alerts()  { cat "$H/logs/ALERTS.log" 2>/dev/null; }
nalerts() { alerts | grep -c . ; }
calls()   { cat "$CASE/gh-calls.log" 2>/dev/null; }
ncalls()  { calls | grep -c . ; }
nsleeps() { local n; n=$(grep -c . "$CASE/sleeps.log" 2>/dev/null) || n=0; printf '%s' "$n"; }

malformed() { # malformed <case> <original first line> <what field 2 was>
  [ "$(line1)" = "RESULT_MALFORMED $2" ] && ok \
    || bad "$1: expected 'RESULT_MALFORMED $2', line 1 is '$(line1)'"
  [ "$(sed -n 2p "$LOCAL/RESULT")" = "$LINE2" ] && ok \
    || bad "$1: line 2 of the RESULT did not survive byte-identical"
  [ "$(nalerts)" = 1 ] && ok || bad "$1: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
  alerts | grep -q "not a PR URL" && ok || bad "$1: the alert must say field 2 is not a PR URL: $(alerts)"
  alerts | grep -q "field 2 is '$3'" && ok || bad "$1: the alert must quote field 2 as '$3': $(alerts)"
  alerts | grep -q 'BUILDER' && ok || bad "$1: the alert must name the builder as the writer: $(alerts)"
  alerts | grep -q 'rewritten RESULT_MALFORMED' && ok || bad "$1: the alert must say what it did: $(alerts)"
  alerts | grep -qF "$LOCAL" && ok || bad "$1: the alert must name the build record: $(alerts)"
  # The whole point: this is not a token finding.
  grep -q 'gh token' <<<"$(alerts)" && bad "$1: the alert blamed a gh token: $(alerts)" || ok
  grep -q 'INVISIBLE' <<<"$(alerts)" && bad "$1: the alert used the invisible-repo register: $(alerts)" || ok
  grep -q 'could NOT be read' <<<"$(alerts)" && bad "$1: the alert claimed a read that never happened: $(alerts)" || ok
  # S4/S5, asserted per case: no call, no pause.
  [ "$(ncalls)" = 0 ] && ok || bad "$1: a malformed URL must ask GitHub nothing, called: $(calls)"
  [ "$(nsleeps)" = 0 ] && ok || bad "$1: a malformed URL must not enter the retry loop, slept: $(cat "$CASE/sleeps.log" 2>/dev/null)"
}
untouched() { # untouched <case> <expected first line>
  [ "$(line1)" = "$2" ] && ok || bad "$1: the RESULT was touched — line 1 is '$(line1)'"
  [ "$(sed -n 2p "$LOCAL/RESULT")" = "$LINE2" ] && ok || bad "$1: line 2 did not survive"
}

# ── Section C — the extraction itself (a suite that extracted nothing FAILS) ──
[ -s "$GATE" ] && ok || bad "C: could not extract the PR_CREATED gate from bin/fly-pool.sh"
grep -q 'RLINE#PR_CREATED ' "$GATE" && ok || bad "C: the extracted block is not the gate — its PR_CREATED entry condition is missing"
[ -s "$HELPERS" ] && ok || bad "C: could not extract the REST reader from bin/fly-pool.sh"

# ── Section S — the defect ───────────────────────────────────────────────────
# S1 — the line the four project-5 builds wrote.
newcase s1 "$BADLINE"
drive
malformed S1 "$BADLINE" '|'

# S2 — `PR_CREATED` and nothing else: field 2 is empty.
newcase s2 "PR_CREATED"
drive
malformed S2 "PR_CREATED" ''

# S3 — near-misses that pr_state_rest cannot parse either.
newcase s3a "PR_CREATED https://github.com/o/r/pull/12/files"
drive
malformed S3a "PR_CREATED https://github.com/o/r/pull/12/files" 'https://github.com/o/r/pull/12/files'
newcase s3b "PR_CREATED #12"
drive
malformed S3b "PR_CREATED #12" '#12'
newcase s3c "PR_CREATED https://github.com/o/r/pulls/12"
drive
malformed S3c "PR_CREATED https://github.com/o/r/pulls/12" 'https://github.com/o/r/pulls/12'
newcase s3d "PR_CREATED https://github.com/a/b/c/pull/12"
drive
malformed S3d "PR_CREATED https://github.com/a/b/c/pull/12" 'https://github.com/a/b/c/pull/12'

# ── Section S6 — the negatives: what must NOT be called malformed ────────────
# A well-formed URL with a trailing note in the RESULT line: field 2 IS the URL.
newcase s6a "PR_CREATED $GOODURL | QUEUED: in the repo's merge queue"
drive
untouched S6a "PR_CREATED $GOODURL | QUEUED: in the repo's merge queue"
[ "$(nalerts)" = 0 ] && ok || bad "S6a: a verified OPEN PR must not alert: $(alerts)"
calls | grep -q '/pulls/' && ok || bad "S6a: a well-formed URL must still be read over REST, called: $(calls)"

# The #749 builder-side output: not this gate's business.
newcase s6b "PR_CREATE_FAILED: gh pr create produced no url — the branch is pushed, open the PR by hand"
drive
untouched S6b "PR_CREATE_FAILED: gh pr create produced no url — the branch is pushed, open the PR by hand"
[ "$(nalerts)" = 0 ] && ok || bad "S6b: a PR_CREATE_FAILED RESULT must not alert from this gate: $(alerts)"
[ "$(ncalls)" = 0 ] && ok || bad "S6b: a PR_CREATE_FAILED RESULT must ask GitHub nothing, called: $(calls)"

# Idempotence: a re-reap of an already-rewritten RESULT.
newcase s6c "RESULT_MALFORMED $BADLINE"
drive
untouched S6c "RESULT_MALFORMED $BADLINE"
[ "$(nalerts)" = 0 ] && ok || bad "S6c: a re-reap must not alert twice: $(alerts)"
[ "$(ncalls)" = 0 ] && ok || bad "S6c: a re-reap must ask GitHub nothing, called: $(calls)"

# A RESULT that never claimed a PR at all.
newcase s6d "PLAN_BLOCKED the ticket allows two readings"
drive
untouched S6d "PLAN_BLOCKED the ticket allows two readings"
[ "$(nalerts)" = 0 ] && ok || bad "S6d: a PLAN_BLOCKED RESULT must not alert: $(alerts)"

# ── Section S7 — fail-open: the tick survives an unwritable alert log ────────
newcase s7 "$BADLINE"
mkdir -p "$H/logs/ALERTS.log"
drive
[ -f "$CASE/drive.done" ] && ok || bad "S7: the gate aborted the tick when it could not append to ALERTS.log"
[ "$(line1)" = "RESULT_MALFORMED $BADLINE" ] && ok \
  || bad "S7: the rewrite must still happen when the alert cannot be written — line 1 is '$(line1)'"

echo "fly-pool-prurl-shape: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
