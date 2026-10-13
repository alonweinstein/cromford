#!/bin/bash
# tests/triage-escalate-needs-human.bh-3444-test.sh — the triage escalate hook
# (BH-3444): the REAL bin/triage-shard.sh, in a scratch harness whose agent-call
# stub writes the session's DECISION lines, with the real decision-log.sh and
# the real needs-human lib, and a placer stub that records its argv.
#   E1  escalate with a human-only reason -> one placer call, source `triage`,
#       one `needs-human:` line in logs/<p>.log, no ALERTS line from the hook
#   E2  escalate :: flaky suite -> no call
#   E3  a launch (not an escalate) with a human-only reason -> no call
#   E4  a product board (board_prefix FR) -> no call
#   E5  no needs-human lib on the box -> no call, decisions.log still written
#   E6  the placer fails -> the shard completes, the log says placer rc=1
#   E7  45 escalate lines -> 40 calls (decision-log's bound)
#   E8  a key with no issue number -> no call
#
# MUTATION (D1), run by hand in the build: delete the `# >>> needs-human
# escalate` block from bin/triage-shard.sh -> E1 red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHARD="$DIR/bin/triage-shard.sh"
[ -r "$SHARD" ] && [ -r "$DIR/bin/lib/needs-human/classify.sh" ] && ok || bad "D41: the shard or the classify lib is missing"

mkdir -p "$T/fakebin"
for s in gh gh_rest alert-line jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 0\n' "$T" "$s" > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"
done

H="$T/h"
setup() { # a fresh scratch harness
  scratch_rm "$H"; mkdir -p "$H/bin/lib/needs-human" "$H/logs" "$H/locks" "$H/noenv"
  printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
  # agent-call.sh <stage> <project> <model> <timeout> <out> <prompt>
  printf '#!/bin/bash\nprintf "%%s\\n" "$DECISIONS" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
  cp "$DIR/bin/decision-log.sh" "$H/bin/decision-log.sh"
  printf '#!/bin/bash\n[ "${2:-}" = board_prefix ] && echo "${BP:--}"\nexit 0\n' > "$H/bin/fleet-conf.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/placer.calls"\nexit ${PLACER_RC:-0}\n' "$H" > "$H/bin/needs-human-hold.sh"
  chmod +x "$H"/bin/*.sh
  cp "$DIR/bin/lib/needs-human.sh" "$H/bin/lib/"
  cp "$DIR/bin/lib/needs-human/"*.sh "$H/bin/lib/needs-human/"
  printf 'Triage ticket BH-9 on testproj.\n' > "$T/prompt.txt"
}
RUN() { # RUN <decisions>  -> the shard's rc
  ( unset JOBS_URL JOB_ID AGENT_CALL_FP
    export DECISIONS="$1" HARNESS="$H" HOME="$T" HARNESS_ENV_DIR="$H/noenv" PATH="$T/fakebin:$PATH" \
           TSH_RUNNER=claude TSH_MODEL=m BEAT_LOG=/dev/null
    cd "$T" && bash "$SHARD" testproj BH-9 "$T/prompt.txt" >/dev/null 2>&1 )
}
calls() { [ -f "$H/placer.calls" ] && wc -l < "$H/placer.calls" | tr -d ' ' || echo 0; }
nhalerts() { grep -c 'needs-human' "$H/logs/ALERTS.log" 2>/dev/null || true; }

ACT="F1 needs a human to run the probe from the hub"
FP=$( HARNESS="$H"; . "$DIR/bin/lib/needs-human.sh"; nh_fingerprint "$ACT" )
[[ "$FP" =~ ^[0-9a-f]{12}$ ]] && ok || bad "fingerprint of the E1 action is '$FP'"

# E1
setup; RUN "DECISION: BH-9 :: escalate :: $ACT"; RC=$?
[ "$RC" = 0 ] && ok || bad "E1: shard rc $RC"
[ "$(calls)" = 1 ] && [ "$(cat "$H/placer.calls")" = "testproj 9 $FP $ACT triage" ] && ok \
  || bad "E1: placer calls '$(cat "$H/placer.calls" 2>/dev/null)'"
[ "$(grep -c 'needs-human:' "$H/logs/testproj.log" 2>/dev/null)" = 1 ] \
  && grep -q "needs-human: .*($FP).*placer rc=0" "$H/logs/testproj.log" && ok || bad "E1: testproj.log: $(grep needs-human "$H/logs/testproj.log" 2>/dev/null)"
[ "$(nhalerts)" = 0 ] && ok || bad "E1: the hook wrote ALERTS.log"

# E2
setup; RUN "DECISION: BH-9 :: escalate :: flaky suite"
[ "$(calls)" = 0 ] && ok || bad "E2: flaky suite called the placer: $(cat "$H/placer.calls")"

# E3
setup; RUN "DECISION: BH-9 :: launch :: $ACT"
[ "$(calls)" = 0 ] && ok || bad "E3: a launch called the placer"

# E4
setup; BP=FR RUN "DECISION: BH-9 :: escalate :: $ACT"
[ "$(calls)" = 0 ] && ok || bad "E4: a product board called the placer"

# E5
setup; scratch_rm "$H/bin/lib/needs-human.sh"; scratch_rm "$H/bin/lib/needs-human"; RUN "DECISION: BH-9 :: escalate :: $ACT"; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && grep -q 'BH-9 :: escalate' "$H/logs/decisions.log" 2>/dev/null \
  && ok || bad "E5: without the lib: rc $RC, calls $(calls), decisions '$(cat "$H/logs/decisions.log" 2>/dev/null)'"

# E6
setup; PLACER_RC=1 RUN "DECISION: BH-9 :: escalate :: $ACT"; RC=$?
[ "$RC" = 0 ] && grep -q 'placer rc=1' "$H/logs/testproj.log" && grep -q "shard BH-9 rc=0" "$H/logs/testproj.log" \
  && [ "$(nhalerts)" = 0 ] && ok || bad "E6: failing placer: rc $RC, log $(grep -c . "$H/logs/testproj.log" 2>/dev/null) lines"

# E7
setup; D=""; for i in $(seq 1 45); do D="${D}DECISION: BH-$i :: escalate :: run the lead-verdict probe from the hub"$'\n'; done
RUN "$D"
[ "$(calls)" = 40 ] && ok || bad "E7: 45 escalates gave $(calls) calls"

# E8
setup; RUN "DECISION: misc :: escalate :: needs a human from the hub"
[ "$(calls)" = 0 ] && ok || bad "E8: a non-numeric key called the placer"

[ -z "$(find "$T" -maxdepth 1 -name 'called.*')" ] && ok || bad "a gh/alert stub was called: $(ls "$T"/called.* 2>/dev/null)"

echo "triage-escalate-needs-human.bh-3444: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
