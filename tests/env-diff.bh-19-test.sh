#!/bin/bash
# tests/env-diff.bh-19-test.sh — bin/env-diff.sh (BH-19) against a scratch
# harness, the REAL script and the REAL bin/lib/lane-gate.sh, with a stub
# bin/beat.sh that records each payload and BEAT_STRICT and answers
# $STUB_BEAT_RC (0 delivered, 1 POST failed, 2 no console).
#
# What is proved here:
#   A1  a change to GROK_BILLING + RUNNER_TRIAGE is ONE triaged fleet_alert
#       naming the box and old→new, sent with BEAT_STRICT=1;
#   A2  the same state again sends nothing (deduped per change, not per tick);
#   A3  three changes across global.env and project-3.env are still ONE beat;
#   A4  an added key reads ∅→new and a removed one old→∅;
#   A5  a failed POST (rc 1) does not advance the snapshot: the next tick
#       re-sends the SAME akey, and the tick after that sends nothing;
#   A6  A→B then B→A are two changes with two different akeys;
#   A7  no console (rc 2) writes ONE ALERTS.log line and advances;
#   A8  a secret-looking key never leaks its value to beat, log or snapshot;
#   N1-N8 things that must NOT beat (first run, no change, reformatting,
#       unrelated keys, near-miss key names, an unreadable file, a comment);
#   G1  flags/lane-off-env-diff and ENV_DIFF=0 stop it before any write;
#   C1  25 changes: 20 items in the line and an exact "(+5 more".
# Run from anywhere: tests/env-diff.bh-19-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
BEATS="$T/beats.log"
SNAP="$H/state/env-diff/snapshot.tsv"
ALERTS="$H/logs/ALERTS.log"
LOG="$H/logs/env-diff.log"

reset() {
  [ -d "$H" ] && { chmod -R u+w "$H" 2>/dev/null; scratch_rm "$H"; }
  rm -f "$BEATS"
  mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/locks"
  cp "$DIR/bin/env-diff.sh" "$H/bin/" 2>/dev/null
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  cat > "$H/bin/beat.sh" <<SH
#!/bin/bash
printf 'strict=%s\t%s\n' "\${BEAT_STRICT:-}" "\$1" >> "$BEATS"
exit "\${STUB_BEAT_RC:-0}"
SH
  chmod +x "$H/bin/beat.sh"
}

# run [rc] — one tick of the real script, beat stub answering <rc>.
run() {
  env -u CONSOLE_URL -u HARNESS_SECRET HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    ENV_DIFF_BOX=testbox STUB_BEAT_RC="${1:-0}" bash "$H/bin/env-diff.sh" >/dev/null 2>&1
}
nbeats() { [ -f "$BEATS" ] && wc -l < "$BEATS" | tr -d ' ' || echo 0; }
payload() { sed -n "${1}p" "$BEATS" | cut -f2-; }
field()   { payload "$1" | jq -r "$2" 2>/dev/null; }
# run_base <case> — the baseline tick. Every negative asserts it happened, so a
# "no beat" can never pass merely because the script did nothing at all.
run_base() { run; [ -f "$SNAP" ] && ok || bad "$1: the baseline tick must write the snapshot"; }

# ---------------------------------------------------------------- A1 / A2 / N1
reset
printf 'GROK_BILLING=subscription\nRUNNER_TRIAGE=claude\nCONSOLE_URL=https://c.example\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N1: first run (no snapshot) must not beat, got $(nbeats)"
[ -f "$SNAP" ] && ok || bad "N1: first run must write the baseline snapshot"
printf 'GROK_BILLING=api\nRUNNER_TRIAGE=grok\nCONSOLE_URL=https://c.example\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "A1: exactly one beat expected, got $(nbeats)"
L=$(field 1 .line)
[ "$(field 1 .kind)" = fleet_alert ] && ok || bad "A1: kind must be fleet_alert, got '$(field 1 .kind)'"
[ "$(field 1 .triaged)" = true ] && ok || bad "A1: triaged must be true, got '$(field 1 .triaged)'"
[ "$(field 1 .project)" = fleet ] && ok || bad "A1: project must be fleet, got '$(field 1 .project)'"
case "$L" in *testbox*) ok ;; *) bad "A1: line must name the box: $L" ;; esac
case "$L" in *"GROK_BILLING subscription→api"*) ok ;; *) bad "A1: line must carry GROK_BILLING subscription→api: $L" ;; esac
case "$L" in *"RUNNER_TRIAGE claude→grok"*) ok ;; *) bad "A1: line must carry RUNNER_TRIAGE claude→grok: $L" ;; esac
case "$(field 1 .akey)" in envdiff:testbox:????????????????) ok ;; *) bad "A1: akey must be envdiff:testbox:<16 hex>, got '$(field 1 .akey)'" ;; esac
[ "$(sed -n 1p "$BEATS" | cut -f1)" = strict=1 ] && ok || bad "A1: beat must be sent with BEAT_STRICT=1"
run
[ "$(nbeats)" = 1 ] && ok || bad "A2: an unchanged tick must not beat again, got $(nbeats)"

# ---------------------------------------------------------------------- A3
reset
printf 'GROK_BILLING=subscription\nRUNNER_PLAN=claude\n' > "$H/env/global.env"
printf 'EXECUTE_MODEL=opus\n' > "$H/env/project-3.env"
run
printf 'GROK_BILLING=api\nRUNNER_PLAN=grok\n' > "$H/env/global.env"
printf 'EXECUTE_MODEL=sonnet\n' > "$H/env/project-3.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "A3: three changes over two files must be ONE beat, got $(nbeats)"
L=$(field 1 .line)
for w in "global.env GROK_BILLING subscription→api" "global.env RUNNER_PLAN claude→grok" "project-3.env EXECUTE_MODEL opus→sonnet"; do
  case "$L" in *"$w"*) ok ;; *) bad "A3: line must carry '$w': $L" ;; esac
done

# ---------------------------------------------------------------------- A4
reset
printf 'PLAN_MODEL=opus\nRUNNER_TRIAGE=claude\n' > "$H/env/global.env"
run
printf 'RUNNER_TRIAGE=claude\nREVIEW_EFFORT=high\n' > "$H/env/global.env"
run
L=$(field 1 .line)
case "$L" in *"REVIEW_EFFORT ∅→high"*) ok ;; *) bad "A4: an added key must read ∅→high: $L" ;; esac
case "$L" in *"PLAN_MODEL opus→∅"*) ok ;; *) bad "A4: a removed key must read opus→∅: $L" ;; esac
# A box whose baseline held NO matching key: the snapshot is an empty file, and
# the first key that appears is still an addition, not a removal.
reset
printf 'CONSOLE_URL=https://c\n' > "$H/env/global.env"
run_base A4
printf 'CONSOLE_URL=https://c\nGROK_BILLING=api\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "A4: a key added over an empty baseline must beat once, got $(nbeats)"
case "$(field 1 .line)" in *"GROK_BILLING ∅→api"*) ok ;; *) bad "A4: over an empty baseline it must read ∅→api: $(field 1 .line)" ;; esac

# ---------------------------------------------------------------------- A5
reset
printf 'GROK_BILLING=subscription\n' > "$H/env/global.env"
run
cp "$SNAP" "$T/snap.before"
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
run 1
[ "$(nbeats)" = 1 ] && ok || bad "A5: the failed tick must still have tried one beat, got $(nbeats)"
cmp -s "$SNAP" "$T/snap.before" && ok || bad "A5: a failed POST (rc 1) must NOT advance the snapshot"
run 0
[ "$(nbeats)" = 2 ] && ok || bad "A5: the next tick must re-send, got $(nbeats) beats"
[ -n "$(field 1 .akey)" ] && [ "$(field 1 .akey)" = "$(field 2 .akey)" ] && ok \
  || bad "A5: the re-send must carry the IDENTICAL akey ('$(field 1 .akey)' vs '$(field 2 .akey)')"
run 0
[ "$(nbeats)" = 2 ] && ok || bad "A5: after a delivered beat the next tick must send nothing, got $(nbeats)"

# ---------------------------------------------------------------------- A6
reset
printf 'GROK_BILLING=subscription\n' > "$H/env/global.env"
run
printf 'GROK_BILLING=api\n' > "$H/env/global.env"; run
printf 'GROK_BILLING=subscription\n' > "$H/env/global.env"; run
[ "$(nbeats)" = 2 ] && ok || bad "A6: A→B then B→A must be two beats, got $(nbeats)"
[ -n "$(field 2 .akey)" ] && [ "$(field 1 .akey)" != "$(field 2 .akey)" ] && ok \
  || bad "A6: the two changes must carry different akeys ('$(field 1 .akey)' vs '$(field 2 .akey)')"
case "$(field 2 .line)" in *"GROK_BILLING api→subscription"*) ok ;; *) bad "A6: second line must read api→subscription: $(field 2 .line)" ;; esac

# ---------------------------------------------------------------------- A7
reset
printf 'RUNNER_TRIAGE=claude\n' > "$H/env/global.env"
run
printf 'RUNNER_TRIAGE=grok\n' > "$H/env/global.env"
run 2
N=$(grep -c 'RUNNER_TRIAGE claude→grok' "$ALERTS" 2>/dev/null); N=${N:-0}
[ "$N" = 1 ] && ok || bad "A7: no console (rc 2) must write exactly ONE ALERTS.log line, got $N"
grep -q 'testbox' "$ALERTS" 2>/dev/null && ok || bad "A7: the ALERTS line must name the box"
run 2
N=$(grep -c 'RUNNER_TRIAGE' "$ALERTS" 2>/dev/null); N=${N:-0}
[ "$N" = 1 ] && ok || bad "A7: the next tick must add nothing to ALERTS.log, got $N lines"
[ "$(nbeats)" = 1 ] && ok || bad "A7: the next tick must not beat again, got $(nbeats)"

# ---------------------------------------------------------------------- A8
reset
printf 'RUNNER_API_KEY=sk-aaa\n' > "$H/env/global.env"
run
printf 'RUNNER_API_KEY=sk-bbb\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "A8: a secret key change must still beat once, got $(nbeats)"
case "$(field 1 .line)" in *"RUNNER_API_KEY changed (value redacted)"*) ok ;; *) bad "A8: line must say value redacted: $(field 1 .line)" ;; esac
if grep -rq 'sk-aaa\|sk-bbb' "$BEATS" "$H/logs" "$H/state" 2>/dev/null; then
  bad "A8: a raw secret value leaked into $(grep -rl 'sk-aaa\|sk-bbb' "$BEATS" "$H/logs" "$H/state" 2>/dev/null | tr '\n' ' ')"
else ok; fi
grep -q $'global.env\tRUNNER_API_KEY\tsha256:' "$SNAP" 2>/dev/null && ok || bad "A8: the snapshot must store sha256:<hash> for a secret key"

# ------------------------------------------------------------ N3 reformatting
reset
printf 'GROK_BILLING=api\nRUNNER_TRIAGE=grok\nREVIEW_MODEL=opus\n' > "$H/env/global.env"
run_base N3
printf 'export GROK_BILLING="api"\n  RUNNER_TRIAGE='"'"'grok'"'"'\r\nREVIEW_MODEL=opus   \n' > "$H/env/global.env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N3: export/quote/whitespace reformatting must not beat: $(payload 1)"

# ----------------------------------------------------- N4 / N5 unrelated keys
reset
printf 'GROK_BILLING=api\nCONSOLE_URL=https://a\nBUILD_SLOTS=0\nMODELS_URL=https://m1\n' > "$H/env/global.env"
run_base N4
cp "$SNAP" "$T/snap.before"
printf 'GROK_BILLING=api\nCONSOLE_URL=https://b\nBUILD_SLOTS=4\nMODELS_URL=https://m2\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N4: CONSOLE_URL/BUILD_SLOTS/MODELS_URL changes must not beat: $(payload 1)"
cmp -s "$SNAP" "$T/snap.before" && ok || bad "N5: an unrelated key change must leave the snapshot unchanged"

# -------------------------------------------------------- N6 near-miss names
reset
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
run_base N6
printf 'GROK_BILLING=api\nMODEL_PRICES_URL=https://p\nRUNNER=x\nXBILLING_MODE=y\nRUNNERS_ON=1\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N6: MODEL_PRICES_URL/RUNNER/XBILLING_MODE/RUNNERS_ON must not match: $(payload 1)"

# ------------------------------------------------------- N7 unreadable file
reset
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
printf 'EXECUTE_MODEL=opus\n' > "$H/env/project-3.env"
run_base N7
cp "$SNAP" "$T/snap.before"
# Root reads through mode 000, so as root the unreadable file is a dangling
# symlink (the file listed, the read failing) — the same failed read either way.
if [ "$(id -u)" -eq 0 ]; then
  rm -f "$H/env/project-3.env"; ln -s "$T/nowhere/project-3.env" "$H/env/project-3.env"
else
  chmod 000 "$H/env/project-3.env"
fi
run
[ "$(nbeats)" = 0 ] && ok || bad "N7: an unreadable env file must not read as its keys removed: $(payload 1)"
cmp -s "$SNAP" "$T/snap.before" && ok || bad "N7: the unreadable file's rows must carry forward unchanged"
chmod 644 "$H/env/project-3.env" 2>/dev/null
# and a missing env dir changes nothing at all
scratch_rm "$H/env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N7: a missing env dir must not beat"
cmp -s "$SNAP" "$T/snap.before" && ok || bad "N7: a missing env dir must not touch the snapshot"

# ------------------------------------------------------- N8 commented line
reset
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
run_base N8
printf 'GROK_BILLING=api\n#RUNNER_TRIAGE=grok\n  # REVIEW_MODEL=opus\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 0 ] && ok || bad "N8: an added commented-out line must not beat: $(payload 1)"

# ---------------------------------------------------------------------- G1
reset
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
: > "$H/flags/lane-off-env-diff"
run
[ -f "$SNAP" ] && bad "G1: lane-off-env-diff must stop the lane before the snapshot write" || ok
rm -f "$H/flags/lane-off-env-diff"
printf 'GROK_BILLING=api\nENV_DIFF=0\n' > "$H/env/global.env"
run
[ -f "$SNAP" ] && bad "G1: ENV_DIFF=0 must stop the lane before the snapshot write" || ok
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
run
[ -f "$SNAP" ] && ok || bad "G1: with the switch cleared the lane must run (baseline written)"
[ "$(nbeats)" = 0 ] && ok || bad "G1: no beat expected"

# ---------------------------------------------------------------------- C1
reset
: > "$H/env/global.env"
for i in $(seq 1 25); do printf 'RUNNER_K%02d=a\n' "$i" >> "$H/env/global.env"; done
run
sed -i 's/=a$/=b/' "$H/env/global.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "C1: 25 changes must be ONE beat, got $(nbeats)"
L=$(field 1 .line)
N=$(printf '%s' "$L" | grep -o 'RUNNER_K[0-9]* a→b' | wc -l | tr -d ' ')
[ "$N" = 20 ] && ok || bad "C1: line must carry exactly 20 items, got $N: $L"
case "$L" in *"(+5 more"*) ok ;; *) bad "C1: line must end '(+5 more …': $L" ;; esac
N=$(grep -o 'RUNNER_K[0-9]* a→b' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 25 ] && ok || bad "C1: the full list (25 items) must be in logs/env-diff.log, got $N"

echo "env-diff.bh-19: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
