#!/bin/bash
# tests/harness-ci-runners.bh-1323-test.sh — BH-1323: CI_RUNNER MUST NAME A
# KNOWN FLEET.
#
# WHAT THE SWITCH COSTS. Where CI runs is a repo variable (BH-1209/BH-1206):
# every `runs-on` in .github/workflows/harness-ci.yml is
# `${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}`, so the fleet moves with
# one API call. The fallback is what makes that safe to flip — and it is also the
# hole. A typo in the value, or a deleted variable, renders empty, `fromJSON`
# takes the fallback, and the whole run goes green on a hosted image nobody
# chose. Nothing is red, nothing is queued, nothing says which fleet ran the
# gate. That is the silence this suite kills.
#
# WHY A SCRIPT AND NOT A TEST. The value only exists in GitHub's API. A suite
# here runs with no network, never sees `vars.CI_RUNNER`, and under BH-1203 test
# selection may not run at all on a given PR. So the assertion is the same shape
# BH-1206 used for the tool guards: bin/ci-runner-known.sh holds the list, and
# the `lint` job runs it against the live value through `env:`. A typo'd variable
# puts `lint` itself on the fallback, where the step then goes RED instead of
# green — the check survives the failure it is about.
#
# Block A RUNS the guard (it is the production entry point). Block B asserts the
# one thing a run cannot: that the workflow calls it, in a job every event
# executes, and that the value rides in through env rather than being
# interpolated into a `run:` line. Block C makes the doc and the script agree —
# a known-fleets table that has drifted from the list is how the next person
# flips the variable to a value the guard refuses. Block D pins ask 4: the
# public-copy publisher stays on its hosted image.
#
# No network, no secrets, no clock, no writes — so no scratch tree to source.
# Run from anywhere: exit 0 = pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
KNOWN="${BH1323_KNOWN:-$DIR/bin/ci-runner-known.sh}"
WF="${BH1323_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
DOC="${BH1323_DOC:-$DIR/docs/CI-RUNNERS.md}"
PUBLISHER="${BH1323_PUBLISHER:-$DIR/.github/workflows/publish-cromford.yml}"

# The two fleets, byte for byte, held here as well as in the script on purpose:
# a suite that read its expectations out of the thing it is testing would pass
# on any list at all.
MONKCI='"monkci-ubuntu-24.04-4"'
FLYPOOL='["self-hosted","linux","bh-ci"]'
# The one runs-on line every job carries (BH-1206). Counted, not edited: this
# ticket makes the fallback LOUD, it does not remove it.
RUNS_ON_FALLBACK="fromJSON(vars.CI_RUNNER || '\"ubuntu-latest\"')"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF"; exit 1; }

# ── A. the guard, RUN ───────────────────────────────────────────────────────
# An absent or non-executable script is a FAIL, never a skip: block A would
# otherwise report "all good" on a ticket whose whole mechanism is missing.
if [ -x "$KNOWN" ]; then ok; else bad "A: $KNOWN is missing or not executable (BH-1323)"; fi

GOUT=""; GRC=""
gk() { GOUT=$("$KNOWN" "$1" 2>&1); GRC=$?; }    # gk <value>  → $GRC, $GOUT
gk_noargs() { GOUT=$("$KNOWN" 2>&1); GRC=$?; }

if [ -x "$KNOWN" ]; then
  gk "$MONKCI"
  if [ "$GRC" = 0 ]; then ok; else bad "A: the current fleet $MONKCI must be rc 0 (rc=$GRC): $GOUT"; fi

  gk "$FLYPOOL"
  if [ "$GRC" = 0 ]; then ok; else bad "A: the fallback fleet $FLYPOOL must be rc 0 (rc=$GRC): $GOUT"; fi

  # A TYPO IS THE WHOLE TICKET. `monkci-ubuntu-24.04` is a label GitHub has no
  # runner for; today it renders through the fallback and the run is green.
  gk '"monkci-ubuntu-24.04"'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a typo'd label must be rc 1 (rc=$GRC): $GOUT"; fi
  # …and the refusal has to carry the fix, or the next person reads "rejected"
  # and guesses. Both known values, verbatim, in the message.
  case "$GOUT" in *"$MONKCI"*) ok ;; *) bad "A: the refusal must name $MONKCI: $GOUT" ;; esac
  case "$GOUT" in *"$FLYPOOL"*) ok ;; *) bad "A: the refusal must name $FLYPOOL: $GOUT" ;; esac

  # The fallback image is not a known fleet: a variable explicitly SET to it is
  # indistinguishable in effect from a broken one, and the ticket asked for two.
  gk '"ubuntu-latest"'
  if [ "$GRC" = 1 ]; then ok; else bad "A: '\"ubuntu-latest\"' must be rc 1 (rc=$GRC): $GOUT"; fi

  # The hosted rollback target the doc used to name. Two fleets means two.
  gk '"ubuntu-16-core"'
  if [ "$GRC" = 1 ]; then ok; else bad "A: '\"ubuntu-16-core\"' must be rc 1 (rc=$GRC): $GOUT"; fi

  # A SUBSET of the pool's labels is a different runner set, not a near miss:
  # it matches every self-hosted linux runner on the account.
  gk '["self-hosted","linux"]'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a label subset must be rc 1 (rc=$GRC): $GOUT"; fi

  # THE MATCH IS EXACT BYTES, NEVER NORMALISED JSON. A trailing space inside the
  # quotes is a label GitHub will queue on forever; `jq -c` would erase it and
  # the guard would bless the outage.
  gk '"monkci-ubuntu-24.04-4 "'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a trailing space inside the label must be rc 1 (rc=$GRC): $GOUT"; fi

  # The rest of the exact-bytes negatives, asserted rather than left to "the
  # case statement obviously handles it". Runner labels are case-sensitive on
  # GitHub's side, so a capitalised label is a queue-forever value too.
  gk '"MonkCI-Ubuntu-24.04-4"'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a case variant of the label must be rc 1 (rc=$GRC): $GOUT"; fi

  # A REORDERED array selects the same runners and is still refused: the guard
  # answers "is this the string we reviewed", not "does this resolve the same".
  gk '["linux","self-hosted","bh-ci"]'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a reordered label array must be rc 1 (rc=$GRC): $GOUT"; fi

  # Same meaning, different bytes: spaced JSON is refused on purpose, because
  # the alternative is a jq normalisation that would also bless the trailing
  # space above. One shape per fleet, and the doc table holds that shape.
  gk '["self-hosted", "linux", "bh-ci"]'
  if [ "$GRC" = 1 ]; then ok; else bad "A: spaced JSON must be rc 1 (rc=$GRC): $GOUT"; fi

  # A single space is not "empty" to the shell but it is just as broken.
  gk ' '
  if [ "$GRC" = 1 ]; then ok; else bad "A: a single space must be rc 1 (rc=$GRC): $GOUT"; fi

  # A value pasted with its trailing newline is the classic env/API paste bug
  # (the same shape CRON_SECRET comparisons .trim() away). Refused, not trimmed.
  gk '"monkci-ubuntu-24.04-4"
'
  if [ "$GRC" = 1 ]; then ok; else bad "A: a trailing newline must be rc 1 (rc=$GRC): $GOUT"; fi

  # An UNSET variable renders as the empty string. That is the same silent
  # hosted fallback as a typo, so it is refused, and the message says which of
  # the two it was.
  gk ''
  if [ "$GRC" = 1 ]; then ok; else bad "A: an empty value must be rc 1 (rc=$GRC): $GOUT"; fi
  case "$GOUT" in *unset*) ok ;; *) bad "A: an empty value must be reported as unset: $GOUT" ;; esac

  # Misuse is rc 2, never 0: a guard that answered "known" to a call it did not
  # understand is a green step that checked nothing.
  gk_noargs
  if [ "$GRC" = 2 ]; then ok; else bad "A: no argument must be rc 2 (usage), got rc=$GRC: $GOUT"; fi
  case "$GOUT" in *usage*) ok ;; *) bad "A: the usage refusal must say usage: $GOUT" ;; esac

  # It is stateless and writes nothing; it runs on every job of every run.
  gk "$MONKCI"
  if [ "$GRC" = 0 ]; then ok; else bad "A: a repeat call changed its answer (rc=$GRC): $GOUT"; fi
fi

# ── B. the workflow wires it, in a job every run executes ───────────────────
# Comments are stripped first: the step explains itself at length, and an
# assertion that reads prose is an assertion about nothing.
job_block() {
  awk -v want="$1" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$") }
    inblk { print }
  ' "$WF" | grep -v '^[[:space:]]*#'
}

LINT=$(job_block lint)
if [ -n "$LINT" ]; then ok; else bad "B: no 'lint' job block parsed out of $WF — the reader is broken, not the file"; fi

case "$LINT" in
  *'CI_RUNNER_VALUE: ${{ vars.CI_RUNNER }}'*) ok ;;
  *) bad "B: the lint job does not pass vars.CI_RUNNER in through env as CI_RUNNER_VALUE" ;;
esac

RUNLINE=$(printf '%s\n' "$LINT" | grep 'run:.*ci-runner-known\.sh' || true)
if [ -n "$RUNLINE" ]; then ok
else bad "B: no run: line in the lint job invokes bin/ci-runner-known.sh — the guard is dead code"; fi
case "$RUNLINE" in
  *'bin/ci-runner-known.sh "$CI_RUNNER_VALUE"'*) ok ;;
  *) bad "B: the lint job must run bin/ci-runner-known.sh \"\$CI_RUNNER_VALUE\", found: ${RUNLINE:-<nothing>}" ;;
esac

# THE VALUE NEVER GOES INTO A run: LINE. `${{ vars.X }}` interpolated into a
# shell command is a template injection: whoever can set the variable can run
# code as the job. env: is the only sanctioned path, and it is also why the
# guard takes an argument rather than reading the environment itself.
INJECT=$(grep -nE '^[[:space:]]*run:.*vars\.CI_RUNNER' "$WF" || true)
if [ -z "$INJECT" ]; then ok
else bad "B: vars.CI_RUNNER is interpolated into a run: line — pass it through env:
$INJECT"; fi
# …and the reader is not vacuous: the variable does appear in this file.
if grep -q 'vars\.CI_RUNNER' "$WF"; then ok
else bad "B: vars.CI_RUNNER does not appear in $WF at all — the injection check graded nothing"; fi

# THE FALLBACK EXPRESSION IS NOT TOUCHED. This ticket makes it loud; removing it
# would break every fork and every fresh clone. One per job, still.
JOBS=$(awk '/^jobs:/{inj=1;next} inj && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{gsub(/[ :]/,"");print}' "$WF")
NJOBS=$(printf '%s\n' "$JOBS" | grep -c .)
NFB=$(grep -E '^[[:space:]]*runs-on:' "$WF" | grep -cF "$RUNS_ON_FALLBACK")
if [ "$NJOBS" -ge 8 ] && [ "$NFB" = "$NJOBS" ]; then ok
else bad "B: $NFB of $NJOBS runs-on lines carry the sanctioned fallback — BH-1323 must not change them"; fi

# ── C. the doc's known-fleets table and the script agree ────────────────────
if [ -f "$DOC" ]; then ok; else bad "C: $DOC not found"; fi

if [ -f "$DOC" ]; then
  FLEET_ROWS=$(awk '
    /^## Known fleets/ { inblk=1; next }
    inblk && /^## / { inblk=0 }
    inblk && /^\|/ { print }
  ' "$DOC")
  # The first backticked cell of each row is the value. The header row and the
  # separator carry no backticks, so they drop out on their own.
  VALUES=$(printf '%s\n' "$FLEET_ROWS" | sed -n 's/^|[[:space:]]*`\([^`]*\)`.*/\1/p')
  NVAL=$(printf '%s\n' "$VALUES" | grep -c . || true)
  if [ "$NVAL" = 2 ]; then ok
  else bad "C: the doc's '## Known fleets' table yields $NVAL backticked values, expected 2:
$VALUES"; fi
  if [ -x "$KNOWN" ]; then
    DOCBAD=""
    while read -r V; do
      [ -n "$V" ] || continue
      gk "$V"
      [ "$GRC" = 0 ] || DOCBAD="$DOCBAD
    $V (rc=$GRC)"
    done <<< "$VALUES"
    if [ -z "$DOCBAD" ]; then ok
    else bad "C: the doc lists fleet value(s) bin/ci-runner-known.sh refuses — add a fleet to BOTH or neither:$DOCBAD"; fi
  else
    bad "C: cannot check the doc against the guard — $KNOWN is not executable"
  fi

  CUR=$(grep -F 'Current value' "$DOC" | head -1)
  case "$CUR" in
    *"$MONKCI"*) ok ;;
    *) bad "C: the doc's 'Current value' row must name $MONKCI, found: ${CUR:-<no row>}" ;;
  esac

  # CAPTURE FIRST, MATCH WITH `case` — never a file-reading grep piped into a
  # quiet grep. That shape closed PR #1391: the quiet grep exits at the first
  # match, SIGPIPEs the grep upstream of it, and `pipefail` turns the kill into
  # a failure, so the assertion goes red at random on correct code.
  # tests/rollup-crash-loud-test.sh scans every tests/*.sh for it and fails the
  # corpus on a hit, which is what a 40%-flaky safety test bought the repo — and
  # the scan reads the raw file, so not even a comment may spell the shape out.
  # One LINE has to carry both words, so the note reads as a note and not as two
  # unrelated sentences several sections apart — hence the per-line `case`
  # rather than one match over the whole capture.
  PUB_NOTE=$(grep -F 'publish-cromford' "$DOC" || true)
  PUB_NOTE_OK=""
  while IFS= read -r L; do
    case "$L" in *ubuntu-latest*) PUB_NOTE_OK=$L ;; esac
  done <<< "$PUB_NOTE"
  if [ -n "$PUB_NOTE_OK" ]; then ok
  else bad "C: the doc must note that publish-cromford.yml stays on ubuntu-latest (BH-1323 ask 4)"; fi
fi

# ── D. ask 4's negative: the public-copy publisher is left alone ──────────
if [ -f "$PUBLISHER" ]; then ok; else bad "D: $PUBLISHER not found"; fi
if [ -f "$PUBLISHER" ]; then
  N=$(grep -cE '^[[:space:]]*runs-on:[[:space:]]*ubuntu-latest[[:space:]]*$' "$PUBLISHER")
  if [ "$N" = 1 ]; then ok
  else bad "D: publish-cromford.yml must keep exactly one 'runs-on: ubuntu-latest' line, found $N — it does not run the corpus and BH-1323 leaves it"; fi
fi

echo "harness-ci-runners.bh-1323-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
