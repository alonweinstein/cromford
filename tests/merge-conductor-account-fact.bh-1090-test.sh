#!/bin/bash
# tests/merge-conductor-account-fact.bh-1090-test.sh — BH-1090.
#
# Pins four review findings from BH-1019 (#1074):
#   1. `AGENT_CALL_REFUSED*` must match only account-specific refusals
#      (runners-restricted), not hub-no-build or no-tools.
#   2. A bare `429` with no exhaustion words must not mark the lane down;
#      a 429 paired with an exhaustion word still does.
#   3. `ACCOUNT_EXHAUST_REGEX` is additive to the built-in vocabulary.
#   4. Lane-down markers are per-account: the default canary must not clear
#      routed-account markers, and the spawn gate must consult the account
#      that would actually pay.
set -uo pipefail
# scratch.sh owns $T and its cleanup, and carries the run-as-root-next-to-a-
# live-harness guard. Sourced before the first mktemp/trap/cd (checks-run rule
# tests-scratch-only R1).
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
unset HARNESS_SECRET

DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUG="example-org/cromford"
URL="https://github.com/$SLUG/pull/12"
KEY="$SLUG#12"
H1="h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1h1"
H2="h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2h2"

mkdir -p "$T/h/bin/lib/mc" "$T/h/bin" "$T/h/env" "$T/h/state/merge-conductor" \
         "$T/h/logs" "$T/h/flags" "$T/h/state/quota" "$T/repos" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# bin/lib/review-model.sh is in this list because mc_lane_next_review_account
# resolves the review model through it (BH-998) instead of naming one, so a
# fixture without it would ask account-pick about an empty model and still pass
# — the stub ignores argv[3]. Section 5 asserts the resolved word arrives.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/review-provenance.sh" \
   "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# bin/lib/gh-rest.sh rides with the lib (BH-784): mc_rereview's diff and body
# reads go through it now, and a fixture tree without it leaves the fail-closed
# shim answering UNVERIFIABLE to both — mc_rereview would then return 2 at its
# FIRST line, before the account sweep and the lane-down marker sections 8 and 9
# exist to prove. The suite would still be green, for the wrong reason.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
# BH-1194: bin/jobs-client.sh is a SHIM over bin/lib/jobs/*.sh and refuses to
# run without its modules, so a fixture that copies the client alone dies with
# `missing module .../bin/lib/jobs/req.sh` before the first assertion.
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
export HARNESS="$T/h"
# BH-1510.1: review_model's answer with no REVIEW_MODEL is the build.review
# model_routes row; this worker-less box carries the resolver's cache of it.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T/h"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$HARNESS/logs/beats.txt"\nexit 0\n' > "$T/h/bin/beat.sh"
chmod +x "$T/h/bin/beat.sh"

# Stub curl: only the ledger PUT matters; everything else is a 404 miss.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}
200
' ;;
  *) printf '{"error":"not found"}
404
' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# Stub gh: PR 12 approved at H1, head H2, green CI, plain body.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/logs/gh-calls.txt"
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) echo "WRITE VERB: $*" >> "$HARNESS/logs/gh-writes.txt"; exit 1 ;;
  *"pr comment"*) printf '%s\n' "$*" >> "$HARNESS/logs/comments.txt" ;;
  *"pr view"*"--json state,headRefOid"*) echo "OPEN __H2__" ;;
  *"pr view"*"--json state"*) echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo ccccmergecommit ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  # THE REST ROUTES (BH-784). The diff and the PR object share the pulls/12
  # path and differ only by the v3.diff media type, so the diff arm matches
  # FIRST. The words are the same ones the `pr view` arms above answer with, so
  # a reader that moved to REST sees exactly what it saw before.
  *"v3.diff"*) printf 'HTTP/1.1 200 OK\r\n\r\n'; printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api -i -X GET repos/__SLUG__/pulls/12"*)
    restpr OPEN __H2__ ticket/bh-1090 main "" MERGEABLE CLEAN operator ccccmergecommit "plain body" ;;
  *"pr list -R __SLUG__ --state open"*)
    cat <<'J'
[{"number":12,"url":"__URL__","headRefOid":"__H2__","headRefName":"ticket/bh-1090","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[]}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  # BH-1586: the CI read is gh_rest — a whole HTTP response, REST-shaped runs.
  *"api -i -X GET repos/"*"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"api repos/*/pulls"*) echo '{"message":"Bad credentials"}'; exit 1 ;;
  *"pr diff __URL__"*) printf '+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
esac
exit 0
EOF
sed -i "s|__SLUG__|$SLUG|g; s|__URL__|$URL|g; s|__H1__|$H1|g; s|__H2__|$H2|g" "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# Stub git: patch-id is md5 of the per-sha diff.
cat > "$T/fakebin/git" <<'EOF'
#!/bin/bash
A="$*"
case "$A" in
  *ls-remote*|*"remote set-url"*|*clone*|*fetch*) exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   SHA="${A##* }"; printf 'diff for %s\n' "$SHA"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

# Stub agent-call.sh: writes $OUT.account when a claude attempt actually ran.
cat > "$T/h/bin/agent-call.sh" <<'EOF'
#!/bin/bash
# $1 stage  $2 project  $3 model  $4 timeout  $5 out  $6 prompt
OUT="$5"
RUNNER="${AGENT_CALL_RUNNERS:-claude}"
if [ "$RUNNER" != "claude" ]; then
  printf 'AGENT_CALL_REFUSED runners-restricted claude is not available and the caller allows only: %s\n' "$RUNNER" > "$OUT"
  exit 2
fi
# Simulate no headroom when requested.
if [ -f "$HARNESS/state/quota/no-headroom" ]; then
  printf 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom\n' > "$OUT"
  exit 76
fi
# A claude-side failure HAS chosen an account, so the real agent-call.sh writes
# $OUT.account on it too (bin/agent-call.sh, the claude arm, after the candidate
# loop). Simulate a bare 429 (non-fact) or an exhaustion 429 (fact).
if [ -f "$HARNESS/state/quota/bare-429" ]; then
  printf '%s\n' "${MC_STUB_ACCOUNT:-default}" > "$OUT.account"
  printf 'the claude review lane errored (HTTP 429):\n' > "$OUT"
  exit 2
fi
if [ -f "$HARNESS/state/quota/exhaust-429" ]; then
  printf '%s\n' "${MC_STUB_ACCOUNT:-default}" > "$OUT.account"
  printf 'the claude review lane errored (HTTP 429): session limit\n' > "$OUT"
  exit 2
fi
# The two refusals that never reach an account write NO .account — and, like the
# real script on this path, do not remove a stale one either. Sweeping it is
# mc_rereview's job (section 8).
if [ -f "$HARNESS/state/quota/claude-429" ]; then
  printf 'AGENT_CALL_REFUSED runners-restricted claude is not available and the caller allows only: claude\n' > "$OUT"
  exit 2
fi
# Routed account pick is reflected in the env by the fixture below.
printf '%s\n' "${MC_STUB_ACCOUNT:-default}" > "$OUT.account"
printf 'claude %s\n' "$2" >> "$HARNESS/logs/vendor-rows.txt"
printf 'claude\n' > "$OUT.runner"
printf 'claude-fable-5-1\n' > "$OUT.model"
printf 'findings\nVERDICT: APPROVE\n' > "$OUT"
exit 0
EOF
chmod +x "$T/h/bin/agent-call.sh"

# A prior review record so the row is HEAD_MOVED rather than FRESH.
REC="$T/h/builds/pool-demo-os-BH-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings
TIER: 2
VERDICT: APPROVE
' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"

# Stub account-pick.sh: driven by fixture files.
cat > "$T/h/bin/account-pick.sh" <<'EOF'
#!/bin/bash
# $1 stage  $2 vendor  $3 model — argv[3] is RECORDED, because which model the
# pick is made for decides which account's marker the gate then consults.
printf '%s\n' "${3-}" > "$HARNESS/state/quota/pick-model"
if [ -f "$HARNESS/state/quota/pick-fail" ]; then exit 2; fi
ACCT="${MC_STUB_ACCOUNT:-default}"
printf 'name=%s\n' "$ACCT"
printf 'reason=pinned\n'
exit 0
EOF
chmod +x "$T/h/bin/account-pick.sh"

export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
ATT="$T/h/state/merge-conductor/attempts.txt"
LOG="$T/h/logs/merge-conductor.log"
DOWNFILE="$T/h/state/claude-auth-down.txt"
: > "$DOWNFILE"

tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
      MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
      "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}
state_of() { awk -F'\t' -v k="$KEY" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
spawns() { local n; n=$(grep -c 'REREVIEW_SPAWNED' "$LOG" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }

# ============================================================================
# 1. ACCOUNT-FACT CLASSIFICATION: only account-specific refusals count.
# ============================================================================
for R in "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" \
         "AGENT_CALL_REFUSED runners-restricted claude is not available"; do
  mc_lane_account_fact "$R" && ok || bad "account fact not recognised: $R"
done
for R in "AGENT_CALL_REFUSED hub-no-build the review lane does not run on the hub" \
         "AGENT_CALL_REFUSED no-tools contract cannot be enforced on runner claude"; do
  mc_lane_account_fact "$R" && bad "non-account refusal treated as account fact: $R" || ok
done

# ============================================================================
# 2. BARE 429 IS NOT A FACT; 429 PLUS EXHAUSTION WORD IS.
# ============================================================================
mc_lane_account_fact "the claude review lane errored (HTTP 429):" \
  && bad "bare 429 marked lane down" || ok
mc_lane_account_fact "the claude review lane errored (HTTP 429): session limit" \
  || bad "429 + exhaustion word must still be a fact"

# ============================================================================
# 3. ACCOUNT_EXHAUST_REGEX IS ADDITIVE TO BUILT-INS.
# ============================================================================
unset MC_LANE_EXHAUST_RE; ACCOUNT_EXHAUST_REGEX='custom phrase' . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
mc_lane_account_fact "custom phrase" || bad "custom ACCOUNT_EXHAUST_REGEX not matched"
mc_lane_account_fact "you have hit your monthly limit" || bad "built-in exhausted after custom override"

# ============================================================================
# 4. PER-ACCOUNT MARKER PATHS: create and remove per account.
# ============================================================================
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" default \
  && ok || bad "default marker not written"
[ -f "$T/h/state/merge-conductor/lane-down" ] && ok || bad "default marker file missing"
mc_lane_down_for_account default && ok || bad "default marker not detected"

rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" routed-acct \
  && ok || bad "routed marker not written"
[ -f "$T/h/state/merge-conductor/lane-down.d/routed-acct" ] && ok || bad "routed marker file missing"
[ ! -f "$T/h/state/merge-conductor/lane-down" ] && ok || bad "routed marker leaked to default path"
mc_lane_down_for_account routed-acct && ok || bad "routed marker not detected"
mc_lane_down_for_account default && bad "default detected a routed-only marker" || ok

mc_lane_up routed-acct
[ ! -f "$T/h/state/merge-conductor/lane-down.d/routed-acct" ] && ok || bad "routed marker not removed by mc_lane_up"
mc_lane_up default
[ ! -f "$T/h/state/merge-conductor/lane-down" ] && ok || bad "default marker not removed by mc_lane_up"

# 4b. THE DEFAULT ACCOUNT KEEPS BOTH HEALTH SOURCES (BH-1019's first
# safeguard). The spawn gate in headbound_review now asks
# mc_lane_down_for_account instead of mc_claude_lane_down, so a box the FLEET
# MONITOR listed in state/claude-auth-down.txt — the positive-auth-evidence
# outage class — must still read as down, with no conductor marker on disk.
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
printf '%s\n' "$MC_LANE_BOX" > "$DOWNFILE"
mc_claude_lane_down && ok || bad "fleet monitor line not seen by mc_claude_lane_down"
mc_lane_down_for_account default \
  && ok || bad "fleet monitor line not seen by mc_lane_down_for_account default"
mc_lane_down_for_next_review \
  && ok || bad "fleet monitor line not seen by mc_lane_down_for_next_review"
# A routed account is NOT this box's default login, so the fleet line must not
# speak for it.
mc_lane_down_for_account routed-acct \
  && bad "fleet monitor line leaked onto a routed account" || ok
: > "$DOWNFILE"
mc_lane_down_for_account default && bad "default still down after the fleet line cleared" || ok

# ============================================================================
# 5. ACCOUNT-PICK AWARENESS: next-review account and its marker.
# ============================================================================
rm -f "$T/h/state/quota/pick-fail"
[ "$(mc_lane_next_review_account)" = "default" ] && ok || bad "default account not returned"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; [ "$(mc_lane_next_review_account)" = "routed-acct" ] ) \
  && ok || bad "routed account not returned"

# 5b — THE PICK IS MADE FOR THE MODEL THE READ ACTUALLY BUYS (BH-998).
# mc_rereview passes agent-call.sh `review_model`'s answer; asking account-pick
# about a different word would hand back the account for a lane nobody is about
# to use, and the gate would then consult that account's marker. A literal here
# is the defect tests/mc-rereview-model.bh-998-test.sh bans from this file.
rm -f "$T/h/state/quota/pick-model"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct REVIEW_MODEL=probe-model-9
  mc_lane_next_review_account >/dev/null )
[ "$(cat "$T/h/state/quota/pick-model" 2>/dev/null)" = probe-model-9 ] && ok \
  || bad "the account pick must be made for the resolved review model (got '$(cat "$T/h/state/quota/pick-model" 2>/dev/null)')"
# …and with nothing configured it is review_model's own fallback, never empty.
rm -f "$T/h/state/quota/pick-model"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; unset REVIEW_MODEL
  mc_lane_next_review_account >/dev/null )
PICKED=$(cat "$T/h/state/quota/pick-model" 2>/dev/null)
[ -n "$PICKED" ] && [ "$PICKED" = "$(unset REVIEW_MODEL; review_model "$T/h")" ] && ok \
  || bad "an unconfigured box must pick for review_model's fallback, never an empty model (got '$PICKED')"

rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" routed-acct
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; mc_lane_down_for_next_review ) \
  && ok || bad "per-account marker not seen for next review"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=default; mc_lane_down_for_next_review ) \
  && bad "default saw a routed-only marker" || ok

# ============================================================================
# 6. SPAWN GATE: a routed account in cooldown blocks the spawn.
# ============================================================================
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
touch "$T/h/flags/merge-conductor-actions"
rm -f "$T/h/state/quota/no-headroom" "$T/h/state/quota/bare-429" \
      "$T/h/state/quota/exhaust-429" "$T/h/state/quota/claude-429"
: > "$T/h/logs/vendor-rows.txt"; : > "$T/h/logs/gh-calls.txt"; : > "$T/h/logs/comments.txt"
# Mark only the routed account as down.
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" routed-acct
# Drive a tick with routing on and a routed account selected.
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
    MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
    ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct \
    bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "spawn tick rc=$? stderr:"; cat "$T/tick.err"; }
[ "$(wc -l < "$T/h/logs/vendor-rows.txt" | tr -d ' ')" -eq 0 ] \
  && ok || bad "spawn gate bought a read while routed account is down: $(cat "$T/h/logs/vendor-rows.txt")"
grep -qE 'not spawned.*account routed-acct.*lane-down marker' "$LOG" \
  && ok || bad "spawn gate did not log the blocked account"

# ============================================================================
# 7. CANARY CLEAR: the REAL bin/claude-auth-check.sh ok arm clears the default
#    marker for this box and does not touch a routed one.
#    Driven end to end (its own HARNESS tree, a `claude` that answers ok) —
#    a test that rm'd the marker itself would pass against any version of the
#    script, including one with the clear deleted.
# ============================================================================
CAN="$T/can"
mkdir -p "$CAN/bin" "$CAN/canbin" "$CAN/state/merge-conductor/lane-down.d" \
         "$CAN/logs" "$CAN/locks" "$CAN/flags"
model_routes_fixture "$CAN" || exit 1  # BH-1510.2: this root runs a converted lane too
# A healthy account answers what the probe asks. Since V1 alert hygiene the probe
# asks the model to join AUTHPROBE and a per-run code with a hyphen
# (docs/AUTH-PROBE.md); the stub does that transformation, never a literal.
cat > "$CAN/canbin/claude" <<'SH'
#!/bin/bash
printf 'AUTHPROBE-%s\n' "$(printf '%s' "$2" | grep -oE 'code [0-9a-f]+' | awk '{print $2}' | head -1)"
SH
# No fleet projects -> the only box is the local hub, which is the arm under test.
printf '#!/bin/bash\nexit 0\n' > "$CAN/bin/fleet-conf.sh"
printf '#!/bin/bash\necho local\n' > "$CAN/bin/box-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$CAN/bin/beat.sh"
printf '#!/bin/bash\n# BH-2560: the probe now calls agent-call.sh; forward it to the stub claude on PATH\nclaude -p "$6" --model "$3" >"$5" 2>"$5.err"; exit $?\n' > "$CAN/bin/agent-call.sh"; chmod +x "$CAN/bin/agent-call.sh"
chmod +x "$CAN/canbin/claude" "$CAN/bin/fleet-conf.sh" "$CAN/bin/box-for.sh" "$CAN/bin/beat.sh"
printf 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom\n' \
  > "$CAN/state/merge-conductor/lane-down"
printf 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom\n' \
  > "$CAN/state/merge-conductor/lane-down.d/routed-acct"
( PATH="$CAN/canbin:$PATH" HARNESS="$CAN" bash "$DIR/bin/claude-auth-check.sh" ) >/dev/null 2>&1
[ ! -f "$CAN/state/merge-conductor/lane-down" ] \
  && ok || bad "the canary ok arm did not clear the default marker"
[ -f "$CAN/state/merge-conductor/lane-down.d/routed-acct" ] \
  && ok || bad "the canary cleared a routed marker it does not probe"

# ============================================================================
# 8. THE ACCOUNT SIDECAR IS SWEPT BEFORE THE CALL (BH-1090 review, BLOCK-2).
#    $out is keyed on (PR, head), so a re-spawn lands on the same path. A
#    refusal that never reaches an account (NO_HEADROOM) writes no .account —
#    so an UNSWEPT one from the previous attempt would put the marker on an
#    account this run never touched, leave `default` clean, and re-open the
#    every-5-minutes spawn loop BH-1019 closed.
# ============================================================================
RR="$T/h/state/merge-conductor/rereview"; mkdir -p "$RR"
OUTF="$RR/probe.out"
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
rm -f "$T/h/state/quota/bare-429" "$T/h/state/quota/exhaust-429" "$T/h/state/quota/claude-429"
touch "$T/h/state/quota/no-headroom"
printf 'acctB\n' > "$OUTF.account"          # the attempt that ran an hour ago
mc_rereview "$SLUG" 12 demo-os "$URL" "$H1" "$H2" "$REC" "$OUTF" >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "a NO_HEADROOM refusal must be a lane failure (rc 2)"
[ -f "$T/h/state/merge-conductor/lane-down" ] \
  && ok || bad "NO_HEADROOM did not mark the DEFAULT account down"
[ ! -f "$T/h/state/merge-conductor/lane-down.d/acctB" ] \
  && ok || bad "a stale \$out.account steered the marker onto acctB"
[ ! -f "$OUTF.account" ] \
  && ok || bad "\$out.account survived the pre-call sweep"
rm -f "$T/h/state/quota/no-headroom"

# ============================================================================
# 9. THE MARKER IS WRITTEN FOR THE ACCOUNT THAT ACTUALLY PAID, and a Claude
#    answer on that account clears that account's marker only.
#    Drives the real mc_rereview (Task 3's contract, end to end).
# ============================================================================
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
touch "$T/h/state/quota/exhaust-429"
( export MC_STUB_ACCOUNT=routed-acct
  mc_rereview "$SLUG" 12 demo-os "$URL" "$H1" "$H2" "$REC" "$OUTF" >/dev/null 2>&1 )
[ -f "$T/h/state/merge-conductor/lane-down.d/routed-acct" ] \
  && ok || bad "an exhaustion on routed-acct did not mark THAT account down"
[ ! -f "$T/h/state/merge-conductor/lane-down" ] \
  && ok || bad "a routed-account exhaustion marked the default account down"
rm -f "$T/h/state/quota/exhaust-429"
# A default-account marker must survive a routed-account answer, and vice versa.
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" default
( export MC_STUB_ACCOUNT=routed-acct
  mc_rereview "$SLUG" 12 demo-os "$URL" "$H1" "$H2" "$REC" "$OUTF" >/dev/null 2>&1 )
[ ! -f "$T/h/state/merge-conductor/lane-down.d/routed-acct" ] \
  && ok || bad "a Claude answer on routed-acct did not clear its marker"
[ -f "$T/h/state/merge-conductor/lane-down" ] \
  && ok || bad "an answer on routed-acct cleared the DEFAULT account's marker"

# ============================================================================
# 10. EVERY MARKER HAS A RELEASE EVENT (BH-1090 review, BLOCK-1).
#     The hourly canary probes this box's own login, so it never answers for a
#     routed account. Without an expiry the only clearer of a routed marker is
#     a Claude answer through that account — the read the gate refuses to buy
#     while the marker stands — and one routed exhaustion holds every
#     head-bound re-review on the box until an operator removes a file.
# ============================================================================
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
MARK="$T/h/state/merge-conductor/lane-down.d/routed-acct"
mc_lane_down_note "the claude review lane errored (HTTP 429): session limit" routed-acct
mc_lane_down_for_account routed-acct && ok || bad "a fresh routed marker must hold"
# Age it past the retry window: the next gate check releases it, once.
touch -d "@$(( $(date -u +%s) - 7200 ))" "$MARK"
mc_lane_down_for_account routed-acct \
  && bad "a routed marker older than MC_LANE_ROUTED_RETRY_SECS still held the gate shut" || ok
[ ! -f "$MARK" ] && ok || bad "the expired routed marker was not removed"
# The window is a knob, and the DEFAULT marker is never timed — the canary owns it.
mc_lane_down_note "the claude review lane errored (HTTP 429): session limit" routed-acct
touch -d "@$(( $(date -u +%s) - 7200 ))" "$MARK"
( export MC_LANE_ROUTED_RETRY_SECS=86400; mc_lane_down_for_account routed-acct ) \
  && ok || bad "MC_LANE_ROUTED_RETRY_SECS did not widen the window"
rm -f "$MARK"
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" default
touch -d "@$(( $(date -u +%s) - 604800 ))" "$T/h/state/merge-conductor/lane-down"
mc_lane_down_for_account default \
  && ok || bad "the default marker expired on a timer — only the canary may clear it"
rm -f "$T/h/state/merge-conductor/lane-down"

# 10b. THE GATE BUYS THE ONE READ. Same tick as section 6, with the marker aged
# past the window: the spawn happens instead of being held forever.
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* 2>/dev/null
rm -f "$T/h/state/quota/no-headroom" "$T/h/state/quota/bare-429" \
      "$T/h/state/quota/exhaust-429" "$T/h/state/quota/claude-429"
: > "$LOG"; : > "$ATT"; : > "$T/h/logs/vendor-rows.txt"
rm -rf "$T/h/state/merge-conductor/rereview"
mc_lane_down_note "the claude review lane errored (HTTP 429): session limit" routed-acct
touch -d "@$(( $(date -u +%s) - 7200 ))" "$MARK"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
    MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
    ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct \
    bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "expiry tick rc=$? stderr:"; cat "$T/tick.err"; }
grep -q 'REREVIEW_SPAWNED' "$LOG" \
  && ok || bad "the gate never released an expired routed marker: $(grep -c 'not spawned' "$LOG" 2>/dev/null) hold lines"

# ============================================================================
# 11. THE EPOCH FOLLOWS THE ACCOUNT THAT WOULD PAY (BH-1090 review).
#     MC_RR_LANEFAIL_MAX and bin/blocked-resolver.sh's BR_LANEFAIL_MAX forget an
#     outage only when the epoch moves. An epoch blind to routed transitions
#     strands both caps on a row nothing else transitions.
# ============================================================================
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* "$T/h/state/merge-conductor/lane-epoch" 2>/dev/null
EP0=$( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; mc_lane_epoch )
mc_lane_down_note "the claude review lane errored (HTTP 429): session limit" routed-acct
EP1=$( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; mc_lane_epoch )
[ "$EP1" != "$EP0" ] && ok || bad "a routed account going DOWN did not move the lane epoch ($EP0 -> $EP1)"
mc_lane_up routed-acct
EP2=$( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; mc_lane_epoch )
[ "$EP2" != "$EP1" ] && ok || bad "a routed account coming UP did not move the lane epoch ($EP1 -> $EP2)"
EP3=$( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=routed-acct; mc_lane_epoch )
[ "$EP3" = "$EP2" ] && ok || bad "the epoch moved with no transition ($EP2 -> $EP3)"
# Routing off is the deployed configuration (docs/ACCOUNT-ROUTING.md): the epoch
# must read exactly as it did before per-account markers existed.
rm -f "$T/h/state/merge-conductor/lane-down" \
      "$T/h/state/merge-conductor/lane-down.d/"* "$T/h/state/merge-conductor/lane-epoch" 2>/dev/null
EP0=$(mc_lane_epoch)
mc_lane_down_note "AGENT_CALL_NO_HEADROOM no claude account with quota headroom" default
EP1=$(mc_lane_epoch)
[ "$EP1" != "$EP0" ] && ok || bad "with routing off the default marker stopped moving the epoch"
rm -f "$T/h/state/merge-conductor/lane-down"

# ============================================================================
# 12. THE REAL bin/agent-call.sh WRITES THE SIDECAR mc_rereview READS (Task 3).
#     The stub above stands in for it everywhere else in this file; this section
#     drives the real script so the two contracts cannot drift.
# ============================================================================
AC="$T/ac"
mkdir -p "$AC/bin" "$AC/acbin" "$AC/logs" "$AC/flags" "$AC/locks" "$AC/state"
printf '#!/bin/bash\ncase "${CLAUDE_STUB_MODE:-ok}" in\n  fail) echo "usage limit" >&2; exit 1 ;;\n  bare429) echo "HTTP 429" >&2; exit 1 ;;\nesac\necho ok\n' > "$AC/acbin/claude"
printf '#!/bin/bash\n[ "${1:-}" = "--kill-after" ] && shift 2\ncase "${1:-}" in --kill-after=*) shift ;; esac\nshift\nexec "$@"\n' > "$AC/acbin/timeout"
printf '#!/bin/bash\necho subscription\n' > "$AC/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$AC/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$AC/bin/sync-agent-rules.sh"
chmod +x "$AC/acbin/"* "$AC/bin/"*
ac_call() { # ac_call <claude-stub-mode> <out> [extra env assignments...]
  local mode="$1" out="$2"; shift 2
  ( export PATH="$AC/acbin:$PATH" HARNESS="$AC" HOME="$AC" CLAUDE_STUB_MODE="$mode" \
           LADDER_BACKOFF_SECS=0 RUNNER_REVIEW=claude AGENT_CALL_RUNNERS=claude \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$out" "hello" ) >/dev/null 2>&1
}
: > "$AC/logs/failovers.log"
ac_call ok "$AC/o1.txt"
[ "$(cat "$AC/o1.txt.account" 2>/dev/null)" = default ] \
  && ok || bad "agent-call did not name the paying account on a successful claude attempt: $(cat "$AC/o1.txt.account" 2>/dev/null)"
ac_call fail "$AC/o2.txt"
[ "$(cat "$AC/o2.txt.account" 2>/dev/null)" = default ] \
  && ok || bad "agent-call did not name the paying account on a claude-side FAILURE"
# A stale sidecar at a path this call never reaches an account on is removed by
# the attempt itself, so the caller can never read the last run's account.
printf 'acctB\n' > "$AC/o3.txt.account"
ac_call ok "$AC/o3.txt"
[ "$(cat "$AC/o3.txt.account" 2>/dev/null)" = default ] \
  && ok || bad "a stale \$OUT.account survived a new attempt"

# 12b. ACCOUNT_EXHAUST_REGEX IS ADDITIVE IN THE LADDER TOO (BH-1090 review).
# One knob cannot mean two things on one box: an operator who widens the
# conductor's vocabulary with it must not silently narrow agent-call's, which
# would reclassify a real "usage limit" as a transient and retry it.
: > "$AC/logs/failovers.log"
ac_call fail "$AC/o4.txt" ACCOUNT_EXHAUST_REGEX='custom phrase'
grep -q 'class=account-exhausted' "$AC/logs/failovers.log" \
  && ok || bad "a built-in exhaustion phrase was not classified as account-exhausted after ACCOUNT_EXHAUST_REGEX was set: $(tr '\n' '|' < "$AC/logs/failovers.log")"
grep -qE 'class=(real-failure|transient)' "$AC/logs/failovers.log" \
  && bad "'usage limit' lost its class to a custom ACCOUNT_EXHAUST_REGEX: $(tr '\n' '|' < "$AC/logs/failovers.log")" || ok
# ...and the custom phrase is matched too, so the override still overrides.
: > "$AC/logs/failovers.log"
printf '#!/bin/bash\necho "custom phrase" >&2\nexit 1\n' > "$AC/acbin/claude"
ac_call ok "$AC/o5.txt" ACCOUNT_EXHAUST_REGEX='custom phrase'
grep -q 'class=account-exhausted' "$AC/logs/failovers.log" \
  && ok || bad "a custom ACCOUNT_EXHAUST_REGEX phrase was not classified as account-exhausted: $(tr '\n' '|' < "$AC/logs/failovers.log")"

echo "merge-conductor-account-fact.bh-1090-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
