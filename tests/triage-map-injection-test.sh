#!/bin/bash
# tests/triage-map-injection-test.sh — the orientation map actually reaches both
# lanes' prompts, and a failed render is DECLARED rather than silently dropped.
#
# This test runs the lane scripts' OWN prompt-construction code. It extracts the
# real `# --- ORIENTATION MAP ---` block and the real PROMPT="..." assignment out
# of bin/alert-triage.sh and bin/alerts-medic.sh and executes them, because a
# test that retypes the prompt proves only that the copy is correct — which is
# this repo's most-repeated lesson (see tests/prompt-ceiling-test.sh, which
# extracts prompt_guard from agent-call.sh for the same reason). Delete the
# injection from a lane and this file goes red; that is the whole point.
#
# The second half is the degrade path. "Proceed without the map" and "pretend
# there was one" look identical from the outside, so the failure must leave a
# line in ALERTS.log. A silent mapless lane is exactly the failure mode this
# wave exists to kill.
# Run from anywhere: tests/triage-map-injection-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- extract the real code out of a lane script ----------------------
# Emits a runnable script: the lane's own STAMP(), its own ORIENTATION MAP block,
# its own PROMPT assignment, and nothing we wrote by hand except placeholders
# for the alert text the prompt interpolates.
extract() {  # extract <lane-script> <out.sh>
  python3 - "$1" "$2" <<'PY'
import sys
src = open(sys.argv[1]).read()

stamp = next(l for l in src.splitlines() if l.startswith("STAMP() {"))

b = src.index("# --- ORIENTATION MAP (begin) ---")
e = src.index("# --- ORIENTATION MAP (end) ---") + len("# --- ORIENTATION MAP (end) ---")
block = src[b:e]

# PROMPT="..." — walk to the matching unescaped closing quote.
i = src.index('PROMPT="')
j = i + len('PROMPT="')
while True:
    c = src[j]
    if c == "\\":
        j += 2
        continue
    if c == '"':
        break
    j += 1
prompt = src[i:j + 1]

open(sys.argv[2], "w").write(
    "set -uo pipefail\n"
    + stamp + "\n"
    # placeholders for the values the prompt interpolates. FKEY/FCOUNT arrive
    # with the per-family split: alert-triage builds its PROMPT inside a loop
    # over families, so the assignment references the current family's key and
    # line count. Everything else here is the lane's own code, verbatim.
    + 'ALERTS="ALERT-TEXT-PLACEHOLDER"\n'
    + 'NEW="ALERT-TEXT-PLACEHOLDER"\n'
    + 'FALERTS="ALERT-TEXT-PLACEHOLDER"\n'
    + 'FKEY="fam000000test"\n'
    + 'FCOUNT=1\n'
    + 'CONSOLE_URL="https://console.invalid"\n'
    # alerts-medic's escalation clause quotes the park TTL back to the model, so
    # it must be bound here too. Under `set -u` a newly interpolated variable
    # kills the synthetic script outright, and every assertion below then fails
    # for a reason that has nothing to do with the orientation map.
    + 'PARK_TTL=604800\n'
    # Same reason: alert-triage's Sentry-first clause interpolates the owned-app
    # list, which the lane builds from fleet.conf just above the PROMPT. Bound
    # here as a placeholder rather than resolved, because what this file tests is
    # the orientation map's injection — the list itself is driven for real in
    # tests/fleet-lanes-registry-test.sh.
    + 'SENTRY_APPS="APP-LIST-PLACEHOLDER"\n'
    + block + "\n"
    + prompt + "\n"
    + 'printf %s "$PROMPT"\n'
)
PY
}

# a HARNESS root whose bin/ holds the REAL renderer (via the real fleet.conf),
# so the prompt gets a real map, while logs land in the temp dir.
mkdir -p "$T/h/bin" "$T/h/logs"
for s in triage-map.sh fleet-conf.sh box-for.sh; do ln -sf "$DIR/bin/$s" "$T/h/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"

for LANE in alert-triage alerts-medic; do
  extract "$DIR/bin/$LANE.sh" "$T/$LANE.built.sh" 2>/dev/null \
    && [ -s "$T/$LANE.built.sh" ] && ok || { bad "could not extract prompt construction from $LANE.sh"; continue; }

  # --- the map is in the prompt, whole ---------------------------------------
  : > "$T/h/logs/ALERTS.log"
  OUT=$(HARNESS="$T/h" bash "$T/$LANE.built.sh" 2>/dev/null)
  grep -q '=== HARNESS ORIENTATION (deterministically rendered' <<<"$OUT" \
    && ok || bad "$LANE: prompt is missing the orientation block header"
  grep -q '=== END HARNESS ORIENTATION ===' <<<"$OUT" \
    && ok || bad "$LANE: prompt is missing the orientation block footer"
  # not just the delimiters — the content the lane would otherwise re-derive
  grep -q '^FLEET (' <<<"$OUT" && grep -q '^CAPABILITIES (' <<<"$OUT" \
    && ok || bad "$LANE: orientation block reached the prompt without its sections"
  # the alert payload is still there: the map is an addition, not a replacement
  grep -q 'ALERT-TEXT-PLACEHOLDER' <<<"$OUT" \
    && ok || bad "$LANE: injecting the map displaced the alert text"
  # a healthy render must not raise the degraded-mode alert
  [ ! -s "$T/h/logs/ALERTS.log" ] \
    && ok || bad "$LANE: a successful render wrote a failure line ($(cat "$T/h/logs/ALERTS.log"))"

  # --- render fails: proceed, but SAY SO ------------------------------------
  # A lane that quietly runs mapless is indistinguishable from one that has the
  # map, which is how a regression here would survive unnoticed for weeks.
  mkdir -p "$T/broken/bin" "$T/broken/logs"
  printf '#!/bin/sh\necho "boom" >&2\nexit 1\n' > "$T/broken/bin/triage-map.sh"
  chmod +x "$T/broken/bin/triage-map.sh"
  : > "$T/broken/logs/ALERTS.log"
  OUT=$(HARNESS="$T/broken" bash "$T/$LANE.built.sh" 2>/dev/null); RC=$?
  [ "$RC" -eq 0 ] && grep -q 'ALERT-TEXT-PLACEHOLDER' <<<"$OUT" \
    && ok || bad "$LANE: a failed render must not block the prompt (rc=$RC)"
  ! grep -q 'HARNESS ORIENTATION' <<<"$OUT" \
    && ok || bad "$LANE: a failed render still produced an orientation block"
  grep -q 'without orientation map — render failed' "$T/broken/logs/ALERTS.log" \
    && ok || bad "$LANE: a failed render was not declared in ALERTS.log (got: $(cat "$T/broken/logs/ALERTS.log"))"
  rm -rf "$T/broken"
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
