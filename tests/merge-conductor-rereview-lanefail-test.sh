#!/bin/bash
# tests/merge-conductor-rereview-lanefail-test.sh — BH-1019.
#
# THE INCIDENT. The merge conductor's head-bound re-review is a metered call,
# and until this change it bought reads it had already decided to throw away.
# cromford#818: eight detached re-review spawns on ONE pull request, five
# of them paid, every one of them served by a fallback lane and then rejected on
# provenance ("a claude read of this head is what the gate asked for, so this is
# no answer to it"). The rejection is correct; buying the read first is not.
# Three separate things made the loop:
#   1. mc_rereview handed agent-call.sh the whole survival ladder, so a claude
#      outage descended to grok/openrouter/fireworks and BILLED a verdict the
#      provenance check would refuse on arrival.
#   2. A provenance/lane rejection counted as a plain lane failure, so the cap
#      bought MC_RR_LANEFAIL_MAX reads of the same head against the same
#      outage — the lane being down was never an input to the decision.
#   3. Out of reads, the row parked BLOCKED_HUMAN `no-verdict` — and the very
#      next tick re-derived that park to HEAD_MOVED (head != reviewed is still
#      true) and armed the spawn again, on a head nobody had touched.
#
# WHAT THIS PINS (the fleet rule is ~/.claude/rules/metered-api-dedup.md: the
# "have we already paid for this" check runs BEFORE the billable call, the
# non-success path writes terminal state, and the attempt count is bounded):
#   a. mc_rereview passes a claude-only intent to agent-call.sh, so a stub that
#      WOULD serve "fireworks" writes no vendor row at all, one lanefail row is
#      recorded, and no second spawn is armed while the lane-down marker stands.
#   b. the marker cleared is a new lane-health epoch: exactly one spawn, not a
#      burst of the reads the previous epoch did not buy.
#   c. a park re-derived to HEAD_MOVED on an UNCHANGED head spawns nothing; the
#      same PR on a head that actually moved spawns again.
#
# Run from anywhere: tests/merge-conductor-rereview-lanefail-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111        # the sha the build's own review approved
H2=bbbbbbbb2222        # the head it moved to — nobody has read this one
H3=cccccccc3333        # a later head, pushed after the park
SLUG=example-org/demo-os
URL="https://github.com/$SLUG/pull/12"
KEY="$SLUG#12"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/review-provenance.sh" "$T/h/bin/lib/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# BH-680/#929: merge-conductor-lib.sh is a SHIM that sources bin/lib/mc/*.sh and
# exits on a missing module. A fixture that copies only the lib file dies with
# `missing module bin/lib/mc/log.sh`, which is a red train rather than a red test.
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# The re-review's own reads — the PR diff it reviews and the PR body it quotes —
# go through bin/lib/gh-rest.sh since BH-784. Without it in the tree the lib
# keeps its fail-closed shims, every read answers "unverifiable", and the lane
# fails for a reason this suite is not about. restpr (tests/lib/rest-emit.sh)
# is how the stub answers: the contract judges the HTTP STATUS LINE.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$HARNESS/logs/beats.txt"\nexit 0\n' > "$T/h/bin/beat.sh"
chmod +x "$T/h/bin/beat.sh"

# --- the stub agent-call: a review lane that WOULD serve fireworks -----------
# It is the whole point of case (a). When the claude CLI is 429ing ($T/claude-429)
# the real ladder descends to a paid open-model lane and returns a verdict — one
# the provenance check then throws away. The stub bills that read into
# $T/vendor-rows.txt, writes the provenance markers the real lanes write, and
# answers APPROVE, exactly as fireworks did on #818.
#
# It honours ONE thing: a caller that says it will only accept claude. Then a
# claude outage is a refusal with rc 2 and NOTHING is billed. A conductor that
# does not pass that intent bills a row here, which is the failure.
cat > "$T/h/bin/agent-call.sh" <<EOF
#!/bin/bash
# \$1 stage  \$2 project  \$3 model  \$4 timeout  \$5 out  \$6 prompt
OUT="\$5"
# K3: the call-guard key the conductor hands agent-call, one line per call.
printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/rr-fps.txt"
printf '%s\n' "\${AGENT_CALL_GUARD_STAGE:-}" >> "$T/rr-stages.txt"
if [ -f "$T/guard-refuse" ]; then
  # bin/agent-call.sh's call-guard refusal: rc 74, nothing called.
  printf 'AGENT_CALL_REFUSED call-guard repeat mc-rereview paid=5/5 fp=%s\n' "\${AGENT_CALL_FP:-}" > "\$OUT"
  exit 74
fi
if [ -f "$T/claude-nohead" ]; then
  # What bin/account-pick.sh produces when no claude account has quota headroom
  # left: rc 76, the marker, and NOTHING called. The fleet auth monitor calls
  # this class inconclusive and never lists the box, which is the whole point
  # of section d below.
  printf 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom\n' > "\$OUT"
  exit 76
fi
if [ -f "$T/claude-429" ]; then
  if [ "\${AGENT_CALL_RUNNERS:-}" = claude ]; then
    printf 'AGENT_CALL_REFUSED runners-restricted claude is not available and the caller allows only: claude\n' > "\$OUT"
    exit 2
  fi
  # the survival ladder, doing its job — and billing for it
  printf 'fireworks %s\n' "\$2" >> "$T/vendor-rows.txt"
  printf 'fireworks\n' > "\$OUT.runner"
  printf 'accounts/fireworks/models/kimi-k2p7-code\n' > "\$OUT.model"
  printf 'findings from an open model\nVERDICT: APPROVE\n' > "\$OUT"
  exit 0
fi
printf 'claude %s\n' "\$2" >> "$T/vendor-rows.txt"
printf 'claude\n' > "\$OUT.runner"
printf 'claude-fable-5-1\n' > "\$OUT.model"
printf 'findings\nVERDICT: APPROVE\n' > "\$OUT"
exit 0
EOF
chmod +x "$T/h/bin/agent-call.sh"

# --- git: patch-id is md5 of the per-sha diff, so two heads differ ----------
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *ls-remote*|*"remote set-url"*|*clone*|*fetch*) exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   SHA="\${A##* }"; printf 'diff for %s\n' "\$SHA"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

# --- gh: PR 12, approved at H1, head wherever mk_gh puts it, green CI -------
mk_gh() { # mk_gh <head>
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/comments.txt" ;;
  # THE DECISION READS ARE REST (BH-784): the diff and the PR object share the
  # pulls/12 path and differ only by the v3.diff media type, so the diff arm is
  # matched FIRST. One object carries the state, the head sha, the head ref and
  # the body the --json arms below used to answer one at a time.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/12"*)
    restpr OPEN "$1" ticket/TK-12 main "" MERGEABLE CLEAN operator ccccmergecommit "plain body" ;;
  *"pr view"*"--json state,headRefOid"*) echo "OPEN $1" ;;
  *"pr view"*"--json state"*) echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo ccccmergecommit ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":12,"url":"$URL","headRefOid":"$1","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  # BH-1586: the CI read is gh_rest — a whole HTTP response, REST-shaped runs.
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

REC="$T/h/builds/pool-demo-os-TK-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
touch "$T/h/flags/merge-conductor-actions"
: > "$T/vendor-rows.txt"; : > "$T/gh-calls.txt"; : > "$T/comments.txt"

export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
ATT="$T/h/state/merge-conductor/attempts.txt"
LOG="$T/h/logs/merge-conductor.log"
DOWNFILE="$T/h/state/claude-auth-down.txt"
: > "$DOWNFILE"

tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
             MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
             "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
           || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of() { awk -F'\t' -v k="$KEY" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
spawns()   { local n; n=$(grep -c 'REREVIEW_SPAWNED' "$LOG" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
LOGN=0
logmark()  { LOGN=$(wc -l < "$LOG" 2>/dev/null || echo 0); }
logsince() { tail -n +$((LOGN+1)) "$LOG" 2>/dev/null; }
# wait_status <job-file> <status> — the lane is asynchronous by design, so the
# test waits for the FILE rather than for a wall-clock guess.
wait_status() {
  local f="$1" want="$2" i
  for i in $(seq 1 150); do
    [ "$(jq -r .status "$f" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

# ============================================================================
# a. THE CLAUDE ACCOUNT IS 429ING AND THE MONITOR HAS NOT NOTICED YET.
#    The conductor spawns (it has no reason not to), and the job's agent-call
#    is where the money would go. With the claude-only intent it comes back
#    rc 2 having called nothing; without it, the fireworks row below is billed
#    for a verdict the provenance check throws away.
# ============================================================================
touch "$T/claude-429"
mk_gh "$H2"
tick
JF2=$(mc_rr_file "$SLUG" 12 "$H2")
[ -f "$JF2" ] && ok || bad "a moved head with green CI must spawn the detached head-bound re-review ($JF2)"
wait_status "$JF2" lane-failed && ok \
  || bad "a claude-only call refused on an outage must record lane-failed, never a verdict (got $(jq -r .status "$JF2" 2>/dev/null))"
[ ! -s "$T/vendor-rows.txt" ] && ok \
  || bad "the re-review bought a fallback-lane read it will reject on provenance: $(cat "$T/vendor-rows.txt")"
[ "$(jq -r .verdict "$JF2")" = "-" ] && ok \
  || bad "a lane that never ran has no verdict to record (got $(jq -r .verdict "$JF2"))"

# The monitor catches up: the claude lane is marked down fleet-wide.
echo hub > "$DOWNFILE"
logmark; tick
[ "$(grep -cE "^lanefail $KEY $H2( |\$)" "$ATT")" = 1 ] && ok \
  || bad "a lane failure must be recorded once (got $(grep -cE "^lanefail $KEY $H2( |\$)" "$ATT") rows)"
grep -qE "^lanefail $KEY $H2 [0-9]+\$" "$ATT" && ok \
  || bad "the lanefail row must carry the lane-health epoch it belongs to: $(grep "^lanefail $KEY $H2" "$ATT")"
[ "$(state_of)" = HEAD_MOVED ] && ok \
  || bad "our own outage must leave the PR waiting, not parked (got $(state_of))"
N=$(spawns)
logmark; tick; tick
[ "$(spawns)" = "$N" ] && ok \
  || bad "no read may be bought while the claude lane-down marker stands (spawns went $N -> $(spawns))"
# The conductor names the ACCOUNT whose marker it is waiting on (BH-1090); the
# pre-BH-1090 wording is gone, so only the current one is accepted here.
logsince | grep -qE 'account [^ ]+ lane-down marker is set' && ok \
  || bad "the refusal to spawn must say which account's marker it is waiting for"
[ ! -s "$T/vendor-rows.txt" ] && ok \
  || bad "a tick under a lane-down marker billed a vendor: $(cat "$T/vendor-rows.txt")"
[ "$(grep -cE "^lanefail $KEY $H2( |\$)" "$ATT")" = 1 ] && ok \
  || bad "the lane-down ticks must not each record another lanefail (got $(grep -cE "^lanefail $KEY $H2( |\$)" "$ATT"))"

# ============================================================================
# b. THE LANE COMES BACK. That is a new lane-health epoch, so the head is worth
#    one read again — ONE, not the four the previous epoch did not spend.
# ============================================================================
[ -f "$T/h/state/merge-conductor/lane-down" ] && ok \
  || bad "the refused read of section a must have marked the lane down from its own reason"
rm -f "$T/claude-429" "$DOWNFILE"; : > "$DOWNFILE"
# The conductor's marker is released by an EVENT, never by a clock: a Claude
# answer through mc_rereview, or the hourly end-to-end canary in
# bin/claude-auth-check.sh. Section e drives the first; this is the second.
mc_lane_up
N=$(spawns)
logmark; tick
[ "$(spawns)" = $((N+1)) ] && ok \
  || bad "a recovered lane must buy exactly one read (spawns went $N -> $(spawns))"
wait_status "$JF2" done && ok || bad "the re-review on a healthy lane must finish (got $(jq -r .status "$JF2" 2>/dev/null))"
[ "$(grep -c '^claude ' "$T/vendor-rows.txt")" = 1 ] && ok \
  || bad "exactly one claude read must have been bought (got $(cat "$T/vendor-rows.txt"))"
N=$(spawns); tick
[ "$(spawns)" = "$N" ] && ok || bad "a finished job must not be re-spawned (spawns went $N -> $(spawns))"

# ============================================================================
# c. THE PARK MUST NOT RE-ARM ITSELF. Out of reads on this head the row parks
#    `no-verdict`; head != reviewed is still true, so the classifier used to
#    hand it straight back to HEAD_MOVED and the spawn armed again — #818's
#    eight spawns.
#
#    THE RESOLVER'S RELEASE IS WHAT MAKES THIS VISIBLE. A fresh hand-off is
#    STICKY (mc_handoff_sticky): while it stands the conductor does not classify
#    the row at all. bin/blocked-resolver.sh writes its release marker the
#    moment it takes the PR, and from then on every tick classifies it again —
#    which is the window #818 spun in. So every case below releases the hand-off
#    first, or it would be testing the sticky park and not this change.
# ============================================================================
reset_pr() { # reset_pr <head> — an unreviewed moved head, no history, no jobs
  echo "$H1" > "$REC/reviewed-sha"
  awk -F'\t' -v k="$KEY" '$1!=k' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
  mv -f "$T/rows.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
  grep -v -- "$KEY" "$ATT" > "$T/att.tmp" 2>/dev/null; mv -f "$T/att.tmp" "$ATT"
  rm -f "$T/h/state/merge-conductor/rereview"/*.json "$T/h/state/merge-conductor/rereview"/*.out* 2>/dev/null
  rm -f "$T/h/state/merge-conductor/handoff"/* "$T/h/state/merge-conductor/handoff-released"/* 2>/dev/null
  rm -f "$T/h/state/merge-conductor/lane-down"; : > "$DOWNFILE"
  rm -f "$T/claude-429" "$T/claude-nohead"
  : > "$T/vendor-rows.txt"
  mk_gh "$1"
}
MARKER="$T/h/state/merge-conductor/lane-down"
ladder_job() { mc_rr_write "$JF2" lane-failed "$$" "$(mc_now)" "$(mc_now)" - "$H2" "$H1" "${JF2%.json}.out" \
                 "the survival ladder could not carry a review-sized prompt"; }
# park_it — drive the real lanefail cap to the real `no-verdict` park on H2, then
# let the resolver take the PR exactly as bin/blocked-resolver.sh does.
park_it_sticky() {   # the park alone: the hand-off is still open, so the row is sticky
  tick; JF2=$(mc_rr_file "$SLUG" 12 "$H2"); wait_status "$JF2" done >/dev/null
  ladder_job; tick env MC_RR_LANEFAIL_MAX=1
  ladder_job; tick env MC_RR_LANEFAIL_MAX=1
}
park_it() { park_it_sticky; mc_handoff_release "$KEY" test-resolver; }
reset_pr "$H2"; park_it
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "out of reads the PR parks (got $(state_of))"
grep -q 'BLOCKED_AGENT no-verdict' "$LOG" && ok || bad "the park must be the no-verdict hand-off the resolver owns"
grep -qE "^hbpark $KEY $H2 [0-9]+$" "$ATT" && ok \
  || bad "the park must record the sha AND the lane-health epoch it parked under: $(grep "^hbpark $KEY $H2" "$ATT")"
[ ! -f "$MARKER" ] && ok || bad "a survival-ladder failure is not an account fact and must not mark the lane down"
N=$(spawns); V=$(wc -l < "$T/vendor-rows.txt")
tick; tick
[ "$(state_of)" = BLOCKED_HUMAN ] && ok \
  || bad "a released park on an unchanged head must STAY parked, not be re-derived to HEAD_MOVED (got $(state_of))"
[ "$(spawns)" = "$N" ] && ok \
  || bad "a released park on an unchanged head must arm no spawn (spawns went $N -> $(spawns)) — this is cromford#818"
[ "$(wc -l < "$T/vendor-rows.txt")" = "$V" ] && ok \
  || bad "a released park on an unchanged head bought a read: $(tail -1 "$T/vendor-rows.txt")"
# ...and a head that ACTUALLY moved is a different question, asked again.
mk_gh "$H3"
N=$(spawns); tick
[ "$(spawns)" = $((N+1)) ] && ok \
  || bad "a NEW head after a park must buy its read (spawns went $N -> $(spawns))"
[ -f "$(mc_rr_file "$SLUG" 12 "$H3")" ] && ok || bad "the new head must get its own job file"
wait_status "$(mc_rr_file "$SLUG" 12 "$H3")" done >/dev/null

# The classifier's half of the same claim, as words: the park is held by the
# recorded sha and by nothing else.
MC_HB_PARKED=1 mc_classify OPEN CLEAN MERGEABLE "$H2" "$H1" APPROVE claude green 0 0 0 0 BLOCKED_HUMAN - \
  | grep -q '^BLOCKED_HUMAN' && ok || bad "with the park recorded for this head the classifier must hold BLOCKED_HUMAN"
MC_HB_PARKED=0 mc_classify OPEN CLEAN MERGEABLE "$H2" "$H1" APPROVE claude green 0 0 0 0 BLOCKED_HUMAN - \
  | grep -q '^HEAD_MOVED' && ok || bad "with no park recorded for this head the drift branch is unchanged: HEAD_MOVED"
MC_HB_PARKED=1 mc_classify OPEN CLEAN MERGEABLE "$H2" "$H1" APPROVE claude green 0 0 0 0 WAIT_CI - \
  | grep -q '^HEAD_MOVED' && ok || bad "the hold belongs to the BLOCKED_HUMAN reconciliation only, not to every row"

# ============================================================================
# d. THE OUTAGE CLASS THE FLEET AUTH MONITOR CANNOT SEE (BH-1019 review).
#    bin/claude-auth-check.sh writes a box's line only on positive AUTH
#    evidence. A 429 session limit, a weekly or monthly spend limit and
#    exhausted credits are classified inconclusive and the file is never
#    touched — and that is the #818 outage class AND the hub's state as this
#    ships ("You've hit your monthly spend limit · … resets Sep 23", no `hub`
#    line). A lane-health signal that cannot see a quota outage would leave this
#    whole change asleep during one. So the conductor keeps its own marker,
#    written from the reason it already has.
# ============================================================================
reset_pr "$H2"
touch "$T/claude-nohead"          # no claude account has headroom — nothing is called
logmark; tick
JF2=$(mc_rr_file "$SLUG" 12 "$H2")
wait_status "$JF2" lane-failed && ok \
  || bad "a refused claude-only read must record lane-failed (got $(jq -r .status "$JF2" 2>/dev/null))"
tick                               # the tick that reads the job and its reason
[ ! -s "$DOWNFILE" ] && ok \
  || bad "the fixture must keep the auth monitor SILENT — a quota outage is the class it never records"
[ -f "$MARKER" ] && ok \
  || bad "an account-fact lane failure must mark the lane down from the conductor's own evidence — without it a 429 outage is invisible to every gate in this change"
grep -q 'AGENT_CALL_NO_HEADROOM' "$MARKER" && ok \
  || bad "the marker must carry the reason, so an operator can read what is down (got $(cat "$MARKER" 2>/dev/null))"
mc_claude_lane_down && ok || bad "mc_claude_lane_down must OR the conductor's marker with the monitor's line"
N=$(spawns); L=$(grep -c "^lanefail $KEY $H2" "$ATT")
tick; tick
[ "$(spawns)" = "$N" ] && ok \
  || bad "no read may be spawned during a quota outage either (spawns went $N -> $(spawns)) — this is Important 2"
[ "$(grep -c "^lanefail $KEY $H2" "$ATT")" = "$L" ] && ok \
  || bad "the cap must not be spent five times against one quota outage (rows went $L -> $(grep -c "^lanefail $KEY $H2" "$ATT"))"
[ ! -s "$T/vendor-rows.txt" ] && ok || bad "a quota outage billed a vendor: $(cat "$T/vendor-rows.txt")"

# ============================================================================
# e. AND THE PARK RELEASES WHEN THE LANE COMES BACK — the probe from the review,
#    which on the first cut of this PR ended `state=BLOCKED_HUMAN
#    spawns_delta=0` for ever. Park, resolver release, lane down on an account
#    fact, no spawns; then ONE Claude answer on the box: the marker clears, the
#    epoch moves, and the parked PR is read exactly once.
# ============================================================================
reset_pr "$H2"; park_it
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "e: the PR must be parked before the release is tested (got $(state_of))"
PARKEP=$(awk -v k="$KEY" -v h="$H2" '$1=="hbpark" && $2==k && $3==h {print $4}' "$ATT" | tail -1)
[ -n "$PARKEP" ] && ok || bad "the park must carry the epoch it was taken under"
# The lane goes down on an account fact. The park's epoch is stale from here on.
mc_lane_down_note "the claude review lane errored (HTTP 429): You've hit your session limit"
[ -f "$MARKER" ] && ok || bad "a 429 reason must mark the lane down"
N=$(spawns); tick; tick
[ "$(spawns)" = "$N" ] && ok \
  || bad "the released park must not buy a read while the lane is still down (spawns went $N -> $(spawns))"
[ "$(state_of)" != BLOCKED_HUMAN ] && ok \
  || bad "a lane-health change must release the park — a park with no release event but a push is what strands the whole backlog (got $(state_of))"
# ONE Claude answer anywhere on this box — here through the same mc_rereview
# bin/blocked-resolver.sh calls — is the event everything was waiting for.
: > "$T/vendor-rows.txt"
mc_rereview "$SLUG" 12 demo-os "$URL" "$H1" "$H2" "$REC" "$T/probe.out" >/dev/null 2>&1
[ ! -f "$MARKER" ] && ok \
  || bad "a Claude verdict must clear the lane-down marker — that is one of the two events this lane has"
N=$(spawns); tick
[ "$(spawns)" = $((N+1)) ] && ok \
  || bad "the recovered lane must re-read the parked head exactly once (spawns went $N -> $(spawns))"
JF2=$(mc_rr_file "$SLUG" 12 "$H2"); wait_status "$JF2" done && ok \
  || bad "the re-armed read must come back with a verdict (got $(jq -r .status "$JF2" 2>/dev/null))"
N=$(spawns); tick
[ "$(spawns)" = "$N" ] && ok || bad "and exactly once: the recovery must not re-arm every tick (spawns went $N -> $(spawns))"

# ============================================================================
# f. A PARK WRITTEN BEFORE THIS CHANGE (a two-field `hbpark` row) re-arms once,
#    then parks bound to sha AND epoch. Bounded, and stated in the diff.
# ============================================================================
reset_pr "$H2"; park_it
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "f: the PR must be parked first (got $(state_of))"
awk -v k="$KEY" -v h="$H2" '$1=="hbpark" && $2==k && $3==h {print "hbpark " k " " h; next} {print}' "$ATT" > "$T/att.legacy"
mv -f "$T/att.legacy" "$ATT"
grep -qxF "hbpark $KEY $H2" "$ATT" && ok || bad "f: the legacy row was not written"
N=$(spawns); tick
[ "$(spawns)" = $((N+1)) ] && ok \
  || bad "a pre-deploy park row must re-arm exactly once rather than stranding the PR (spawns went $N -> $(spawns))"
JF2=$(mc_rr_file "$SLUG" 12 "$H2"); wait_status "$JF2" done >/dev/null
ladder_job; tick env MC_RR_LANEFAIL_MAX=1
ladder_job; tick env MC_RR_LANEFAIL_MAX=1
grep -qE "^hbpark $KEY $H2 [0-9]+$" "$ATT" && ok \
  || bad "the re-park must be bound to sha and epoch: $(grep "^hbpark $KEY $H2" "$ATT" | tr '\n' '|')"


# ============================================================================
# g. WHAT COUNTS AS AN ACCOUNT FACT, as words. The whole liveness chain hangs on
#    this classification, and it is the one thing a fixture cannot infer.
# ============================================================================
for R in "the review lane never ran: AGENT_CALL_NO_HEADROOM no claude account with quota headroom" \
         "the review lane never ran: AGENT_CALL_REFUSED runners-restricted claude is not available" \
         "the claude review lane errored (HTTP 429): You've hit your session limit" \
         "the claude review lane errored: you have hit your monthly spend limit" \
         "every review lane failed (agent-call rc=1): out of credits"; do
  mc_lane_account_fact "$R" && ok || bad "an account fact was not recognised: $R"
done
for R in "gh pr diff failed for $URL — there was nothing to review from" \
         "the review was served by grok, not a Claude lane" \
         "the survival ladder could not carry a review-sized prompt" \
         "the review lane wrote nothing (agent-call rc=0)"; do
  mc_lane_account_fact "$R" && bad "a one-call failure was read as an account outage: $R" || ok
done
rm -f "$MARKER"; : > "$DOWNFILE"
mc_claude_lane_down && bad "with neither source saying so the lane must read as up" || ok
mc_lane_down_note "the survival ladder could not carry a review-sized prompt"
[ -f "$MARKER" ] && bad "a non-account reason must not mark the lane down" || ok
E1=$(mc_lane_epoch); mc_lane_down_note "the claude review lane errored (HTTP 429): session limit"
E2=$(mc_lane_epoch); mc_lane_up; E3=$(mc_lane_epoch)
[ "$E2" = $((E1+1)) ] && [ "$E3" = $((E2+1)) ] && ok \
  || bad "the epoch must count transitions of the conductor's own marker too (got $E1 -> $E2 -> $E3)"
[ "$(mc_lane_epoch)" = "$E3" ] && ok || bad "the epoch must be stable when nothing changed (got $(mc_lane_epoch) after $E3)"

[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# h. A STICKY PARK MUST OBSERVE THE LANE'S RECOVERY ITSELF (review round 2).
#    mc_lane_epoch is a LATCH: it compares the lane's condition now against the
#    one last written, and bumps on a change. A row that returns before reading
#    it never observes the transition — and the sticky hand-off return in
#    pr_worker is exactly such a return, ~500 lines above where MC_HB_PARKED is
#    computed. With the read left down there, a no-verdict park sat through the
#    whole down->up recovery with the epoch never moving, and its release
#    depended on some OTHER lane (br_rereview, once per resolver tick) reading
#    the latch first. There is NO resolver in this fixture, on purpose.
#
#    The epoch file is read DIRECTLY here and never through mc_lane_epoch:
#    calling the latch from the test would advance it and mask the very bug.
# ============================================================================
EPF="$T/h/state/merge-conductor/lane-epoch"
epoch_file() { cut -d' ' -f1 "$EPF" 2>/dev/null; }
reset_pr "$H2"; park_it_sticky
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "h: the PR must be parked first (got $(state_of))"
EP0=$(epoch_file)
[ -n "$EP0" ] && ok || bad "h: the epoch file must exist before the transition"
# The lane goes down. Only the MARKER is written; nothing advances the latch.
mc_lane_down_note "the claude review lane errored (HTTP 429): You've hit your session limit"
N=$(spawns); tick
[ "$(epoch_file)" != "$EP0" ] && ok \
  || bad "a sticky park must observe the lane going down itself — with the epoch read below the sticky return it never does, and the release this change exists to give it depends on another lane happening to look first (epoch stayed $EP0)"
[ "$(spawns)" = "$N" ] && ok || bad "h: a sticky park must buy nothing (spawns went $N -> $(spawns))"
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "h: a sticky park stays parked while the hand-off is open (got $(state_of))"
EP1=$(epoch_file)
# ...and the lane comes back, still with nobody but the conductor looking.
mc_lane_up
tick; tick
[ "$(epoch_file)" != "$EP1" ] && ok \
  || bad "a sticky park must observe the recovery too, or nothing re-reads it when the quota window resets (epoch stayed $EP1)"
[ "$(state_of)" = BLOCKED_HUMAN ] && ok \
  || bad "h: the park is still the resolver's until it releases — the epoch is observed, not acted on (got $(state_of))"
# The resolver takes the PR. NOW the observed transition is what releases it.
mc_handoff_release "$KEY" test-resolver
N=$(spawns); tick
[ "$(state_of)" != BLOCKED_HUMAN ] && ok \
  || bad "the released park must re-arm on the transition the row observed while it was sticky (got $(state_of))"
[ "$(spawns)" = $((N+1)) ] && ok \
  || bad "h: and it buys exactly one read (spawns went $N -> $(spawns))"
wait_status "$(mc_rr_file "$SLUG" 12 "$H2")" done >/dev/null

# ============================================================================
# k3. A CALL-GUARD REFUSAL IS A DEFER, NOT A LANE FAILURE. agent-call.sh
#     refusing a repeat read of this head (rc 74, AGENT_CALL_REFUSED call-guard)
#     called nothing: it must not spend MC_RR_LANEFAIL_MAX, must not mark the
#     lane down, and must never park the PR BLOCKED_HUMAN "review lane down"
#     (the project-5 #1621 pattern the re-review found).
# ============================================================================
reset_pr "$H2"
touch "$T/guard-refuse"
for i in 1 2 3; do
  logmark; tick env MC_RR_LANEFAIL_MAX=1
  for w in $(seq 1 150); do logsince | grep -q 'call-guard' && break; sleep 0.2; done
done
rm -f "$T/guard-refuse"
[ "$(grep -cE "^lanefail $KEY $H2( |\$)" "$ATT")" = 0 ] && ok \
  || bad "k3a a call-guard refusal spent the lane-failure budget: $(grep "^lanefail $KEY" "$ATT")"
[ ! -f "$MARKER" ] && ok || bad "k3b a call-guard refusal marked the review lane down: $(cat "$MARKER")"
[ "$(state_of)" != BLOCKED_HUMAN ] && ok || bad "k3c a call-guard refusal parked the PR BLOCKED_HUMAN"
grep -q 'review lane down' "$T/h/logs/ALERTS.log" 2>/dev/null && bad "k3d a call-guard refusal raised a lane-down alert" || ok
grep -q 'deferred by the call-guard' "$LOG" && ok || bad "k3e the defer left no conductor log line"
# TEST-CHANGE (BH-3940): the conductor buys on the shared stage review-head now.
grep -qx 'review-head' "$T/rr-stages.txt" && ok || bad "k3f the conductor did not name the shared guard stage: $(sort -u "$T/rr-stages.txt" | tr '\n' ' ')"

# K3: every head-bound re-review names its work to the pre-call guard as THIS
# PR at THIS head, on the key every review lane shares
# (review:<slug>#<num>@<sha>[~reason], BH-3940).
[ -s "$T/rr-fps.txt" ] && ok || bad "k3: no re-review recorded a call-guard key"
grep -qvE '^review:[^#@ ]+#[0-9]+@[0-9a-f]{7,40}(~[a-z0-9]{1,24})?$' "$T/rr-fps.txt" 2>/dev/null \
  && bad "k3: a re-review was bought without its PR+head key: $(sort -u "$T/rr-fps.txt" | tr '\n' ' ')" || ok

echo "merge-conductor-rereview-lanefail-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
