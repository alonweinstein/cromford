#!/bin/bash
# tests/mc/locks-test.sh — BH-1302: the sixth mc/ suite, for the one module the
# BH-477 split left with none.
#
# bin/lib/mc/locks.sh owns three families nothing named BY PATH before this file:
#   - the LANE-DOWN family (mc_lane_account_fact, mc_lane_down_marker_path,
#     mc_lane_down_note, mc_lane_up, mc_claude_lane_down, mc_lane_down_for_account,
#     mc_lane_next_review_account, mc_lane_down_for_next_review, mc_lane_epoch);
#   - MC_LANE_EXHAUST_RE (BH-1090's ADDITIVE composition: an ACCOUNT_EXHAUST_REGEX
#     override ORs with the built-in list, it never replaces it) and
#     MC_LANE_ROUTED_RETRY_SECS with its non-integer `case` validation;
#   - the conductor's lock and claim primitives (mc_safe_name, mc_pr_lock,
#     mc_merge_lock, mc_git_lock, mc_merge_locked, mc_git_locked, mc_attempted,
#     mc_attempt_clear, mc_rr_lanefail_note/count).
# tests/merge-conductor-account-fact.bh-1090-test.sh exercises some of the same
# functions through a whole conductor tick; it names the LIB, never the module,
# and bin/test-impact.sh's map is static — so locks.sh stayed in the orphan set.
# The `LOCKS_SRC="$DIR/bin/lib/mc/locks.sh"` line below is what takes it out.
#
# WHY IT LOADS THROUGH THE SHIM. The module is never sourced directly in
# production: bin/lib/merge-conductor-lib.sh loads it in its module loop, and
# that loop is what 14 scripts and 30 suites get. So the fixture sources the
# SHIM (the real one, copied into $T/h) and section 0 asserts the functions under
# test really came out of mc/locks.sh — a seam that bypassed the shim would prove
# nothing about how the conductor gets these names.
#
# MC_LOCKS_UNDER_TEST=<path> swaps the copied module for a deliberately broken
# one, which is how the ticket's "red first" is a repeatable command rather than
# a story. It is read by nothing in bin/.
#
# No real harness, no gh, no network, no clock dependence: account-pick.sh is a
# stub, marker ageing is an explicit `touch -d @<epoch - N>`, and every write is
# under $T.
# Run from anywhere: tests/mc/locks-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ── fixture ─────────────────────────────────────────────────────────────────
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin" "$T/h/env" "$T/h/state/merge-conductor" \
         "$T/h/state/quota" "$T/h/logs" "$T/h/locks"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
LOCKS_SRC="$DIR/bin/lib/mc/locks.sh"
[ -n "${MC_LOCKS_UNDER_TEST:-}" ] && LOCKS_SRC="$MC_LOCKS_UNDER_TEST"
cp "$LOCKS_SRC" "$T/h/bin/lib/mc/locks.sh"
# The sibling libs the shim pulls in when they are present. review-model.sh is
# load-bearing here and not decoration: mc_lane_next_review_account resolves the
# review model through review_model (BH-998), so a fixture without it would ask
# the stub about an empty model word (section 5 pins the resolved word arrives).
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/review-provenance.sh" \
   "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
: > "$T/h/env/global.env"

# Stub account-pick.sh, the shape bin/account-pick.sh answers in: `name=<acct>`
# on stdout, rc 2 when it cannot pick. argv[3] (the model) is recorded, because
# which model the pick is made for decides which account's marker the gate then
# consults.
cat > "$T/h/bin/account-pick.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${3-}" > "$HARNESS/state/quota/pick-model"
[ -f "$HARNESS/state/quota/pick-fail" ] && exit 2
printf 'name=%s\n' "${MC_STUB_ACCOUNT:-default}"
printf 'reason=pinned\n'
exit 0
EOF
chmod +x "$T/h/bin/account-pick.sh"

export HARNESS="$T/h"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
declare -F mc_lane_down_marker_path >/dev/null \
  || { echo "FAIL: bin/lib/mc/locks.sh did not load through the shim"; exit 1; }

MARK_DEF="$T/h/state/merge-conductor/lane-down"
MARK_D="$T/h/state/merge-conductor/lane-down.d"
DOWNFILE="$T/h/state/claude-auth-down.txt"
EPOCHF="$T/h/state/merge-conductor/lane-epoch"
FACT="AGENT_CALL_NO_HEADROOM no claude account with quota headroom"
clear_markers() { rm -f "$MARK_DEF" "$MARK_D"/* 2>/dev/null; : > "$DOWNFILE"; return 0; }
clear_markers

# ============================================================================
# 0. THE NAMES CAME FROM THE MODULE, THROUGH THE PRODUCTION SHIM
# ============================================================================
for fn in mc_lane_down_marker_path mc_lane_epoch mc_merge_locked mc_safe_name; do
  src=$( shopt -s extdebug; declare -F "$fn" | awk '{print $3}' )
  [ "$src" = "$T/h/bin/lib/mc/locks.sh" ] && ok \
    || bad "0: $fn must be defined by mc/locks.sh via the shim, got '${src:-<undefined>}'"
done

# ============================================================================
# 1. MARKER PATH SHAPE PER ACCOUNT
# ============================================================================
[ "$(mc_lane_down_marker_path default)" = "$MARK_DEF" ] && ok \
  || bad "1: default marker path (got $(mc_lane_down_marker_path default))"
[ "$(mc_lane_down_marker_path acct-a)" = "$MARK_D/acct-a" ] && ok \
  || bad "1: routed marker path (got $(mc_lane_down_marker_path acct-a))"
[ "$(mc_lane_down_marker_path)" = "$MARK_DEF" ] && ok \
  || bad "1: no argument must be the default account"
# A name that would escape lane-down.d/ is not a name we can hold a marker for,
# so it is the DEFAULT marker — never a write beside or above the directory.
for nm in '' '../escape' '.hidden' 'a/b' '/etc/passwd'; do
  [ "$(mc_lane_down_marker_path "$nm")" = "$MARK_DEF" ] && ok \
    || bad "1: unsafe account name '$nm' must resolve to the default marker (got $(mc_lane_down_marker_path "$nm"))"
done
clear_markers
mc_lane_down_note "$FACT" '../escape' && ok || bad "1: noting an unsafe name must still record the outage"
[ -f "$MARK_DEF" ] && ok || bad "1: the unsafe name did not land on the default marker"
[ ! -e "$T/h/state/merge-conductor/escape" ] && ok || bad "1: a marker was written OUTSIDE lane-down.d/"
[ "$(find "$T/h/state/merge-conductor" -maxdepth 1 -name 'lane-down*' | wc -l | tr -d ' ')" = 1 ] && ok \
  || bad "1: unexpected lane-down* entries: $(find "$T/h/state/merge-conductor" -maxdepth 1 -name 'lane-down*')"

# ============================================================================
# 2. ACCOUNT X DOES NOT HIDE ACCOUNT Y
# ============================================================================
clear_markers
mc_lane_down_note "$FACT" acct-a && ok || bad "2: acct-a marker not written"
[ -f "$MARK_D/acct-a" ] && ok || bad "2: acct-a marker file missing"
grep -qxF "$FACT" "$MARK_D/acct-a" && ok || bad "2: the marker must carry the reason"
[ ! -f "$MARK_DEF" ] && ok || bad "2: a routed marker leaked onto the default path"
[ ! -f "$MARK_D/acct-b" ] && ok || bad "2: a routed marker leaked onto another account"
mc_lane_down_for_account acct-a && ok || bad "2: acct-a not detected as down"
mc_lane_down_for_account acct-b && bad "2: acct-b read acct-a's marker" || ok
mc_lane_down_for_account default && bad "2: default read a routed marker" || ok
mc_claude_lane_down && bad "2: mc_claude_lane_down read a routed marker" || ok

# A second note on an account already down keeps the FIRST reason: the marker
# records the outage that opened, not the last call that hit it.
mc_lane_down_note "the claude review lane errored (HTTP 429): session limit" acct-a
grep -qxF "$FACT" "$MARK_D/acct-a" && ok || bad "2: a second note overwrote the original reason"

mc_lane_down_note "$FACT" acct-b
mc_lane_up acct-a
[ ! -f "$MARK_D/acct-a" ] && ok || bad "2: mc_lane_up did not remove acct-a"
mc_lane_down_for_account acct-b && ok || bad "2: mc_lane_up acct-a cleared acct-b too"
mc_lane_up default
mc_lane_down_for_account acct-b && ok || bad "2: mc_lane_up default cleared a routed marker"

# A reason that is NOT an account fact records nothing at all.
clear_markers
mc_lane_down_note "the claude review lane errored (HTTP 429):" acct-a \
  && bad "2: a bare 429 marked the lane down" || ok
[ ! -f "$MARK_D/acct-a" ] && ok || bad "2: a non-fact reason still wrote a marker"

# ============================================================================
# 3. THE FLEET MONITOR'S LINE SPEAKS FOR THE DEFAULT ACCOUNT ONLY
# ============================================================================
clear_markers
printf '%s\n' "$MC_LANE_BOX" > "$DOWNFILE"
mc_claude_lane_down && ok || bad "3: fleet monitor line not seen by mc_claude_lane_down"
mc_lane_down_for_account default && ok || bad "3: fleet monitor line not seen for the default account"
mc_lane_down_for_account acct-a && bad "3: fleet monitor line leaked onto a routed account" || ok
: > "$DOWNFILE"
mc_lane_down_for_account default && bad "3: default still down after the fleet line cleared" || ok

# ============================================================================
# 4. THE EPOCH MOVES ON TRANSITIONS AND NEVER OTHERWISE
# ============================================================================
clear_markers; rm -f "$EPOCHF"
E0=$(mc_lane_epoch)
[ "$(mc_lane_epoch)" = "$E0" ] && ok || bad "4: the epoch moved with no transition (from $E0)"
mc_lane_down_note "$FACT" default
E1=$(mc_lane_epoch)
[ "$E1" = "$((E0 + 1))" ] && ok || bad "4: going down must advance the epoch once ($E0 -> $E1)"
[ "$(mc_lane_epoch)" = "$E1" ] && ok || bad "4: a second read while still down moved the epoch"
mc_lane_up default
E2=$(mc_lane_epoch)
[ "$E2" = "$((E1 + 1))" ] && ok || bad "4: coming back up must advance the epoch once ($E1 -> $E2)"

# ============================================================================
# 5. NEXT-REVIEW ACCOUNT ROTATION
# ============================================================================
clear_markers; rm -f "$T/h/state/quota/pick-fail"
[ "$(mc_lane_next_review_account)" = default ] && ok \
  || bad "5: routing off must answer default (got $(mc_lane_next_review_account))"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-a; [ "$(mc_lane_next_review_account)" = acct-a ] ) \
  && ok || bad "5: the answer must follow the pick (acct-a)"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-b; [ "$(mc_lane_next_review_account)" = acct-b ] ) \
  && ok || bad "5: the answer must follow the pick (acct-b)"
# The pick is made for the model the read actually buys (BH-998), never a literal.
rm -f "$T/h/state/quota/pick-model"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-a REVIEW_MODEL=probe-model-9
  mc_lane_next_review_account >/dev/null )
[ "$(cat "$T/h/state/quota/pick-model" 2>/dev/null)" = probe-model-9 ] && ok \
  || bad "5: the pick must be made for the resolved review model (got '$(cat "$T/h/state/quota/pick-model" 2>/dev/null)')"
# account-pick cannot answer -> default, never an empty account.
touch "$T/h/state/quota/pick-fail"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-a; [ "$(mc_lane_next_review_account)" = default ] ) \
  && ok || bad "5: a failing account-pick must fall back to default"
rm -f "$T/h/state/quota/pick-fail"
chmod -x "$T/h/bin/account-pick.sh"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-a; [ "$(mc_lane_next_review_account)" = default ] ) \
  && ok || bad "5: a non-executable account-pick.sh must fall back to default"
chmod +x "$T/h/bin/account-pick.sh"

# ...and the gate follows the rotation, not the default marker.
clear_markers
mc_lane_down_note "$FACT" acct-a
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-a; mc_lane_down_for_next_review ) \
  && ok || bad "5: the next-review gate did not see the picked account's marker"
( export ACCOUNT_ROUTING=1 MC_STUB_ACCOUNT=acct-b; mc_lane_down_for_next_review ) \
  && bad "5: the next-review gate read acct-a's marker for acct-b" || ok
mc_lane_down_for_next_review && bad "5: with routing off the gate read a routed marker" || ok
printf '%s\n' "$MC_LANE_BOX" > "$DOWNFILE"
mc_lane_down_for_next_review && ok || bad "5: with routing off the gate must ask the default lane's health"
: > "$DOWNFILE"

# ============================================================================
# 6. THE EXHAUST VOCABULARY: every built-in arm, and the adversarial negatives
# ============================================================================
# One realistic reason line per alternative of _MC_LANE_EXHAUST_BUILTIN. The
# `hit your [a-z0-9 -]*limit` arm gets a phrase that matches NOTHING else in the
# list, so that arm is not proved by a neighbour.
EXHAUSTED=(
  "the claude review lane errored (HTTP 429): you are out of usage credits"
  "the claude review lane errored (HTTP 429): you have reached your usage limit"
  "the claude review lane errored (HTTP 429): session limit reached for this account"
  "the claude review lane errored (HTTP 429): your weekly limit resets Sep 23"
  "the claude review lane errored (HTTP 429): monthly limit exceeded"
  "the claude review lane errored (HTTP 429): out of credits"
  "the claude review lane errored (HTTP 429): your credit balance is too low"
  "the claude review lane errored (HTTP 429): spend limit reached"
  "the claude review lane errored (HTTP 429): You've hit your 5 hour limit"
  "the claude review lane errored (HTTP 429): quota exceeded"
  "the claude review lane errored (HTTP 429): limit reached"
)
NOT_FACTS=(
  "the claude review lane errored (HTTP 429):"
  "AGENT_CALL_REFUSED hub-no-build the review lane does not run on the hub"
  "AGENT_CALL_REFUSED no-tools contract cannot be enforced on runner claude"
  "review timed out after 600s"
  "rebase conflict in bin/x.sh"
  "context window too large for this model"
)
for r in "${EXHAUSTED[@]}"; do
  mc_lane_account_fact "$r" && ok || bad "6: exhaustion phrase not recognised: $r"
done
mc_lane_account_fact "the claude review lane errored (HTTP 429): Session Limit" && ok \
  || bad "6: the exhaust match must be case-insensitive"
mc_lane_account_fact "$FACT" && ok || bad "6: AGENT_CALL_NO_HEADROOM is an account fact"
mc_lane_account_fact "AGENT_CALL_REFUSED runners-restricted claude is not available" && ok \
  || bad "6: AGENT_CALL_REFUSED runners-restricted is an account fact"
for r in "${NOT_FACTS[@]}"; do
  mc_lane_account_fact "$r" && bad "6: non-fact treated as an account fact: $r" || ok
done

# ============================================================================
# 7. ACCOUNT_EXHAUST_REGEX IS ADDITIVE, NOT A REPLACEMENT
# ============================================================================
# MC_LANE_EXHAUST_RE is composed at SOURCE time, so every case below re-sources
# the shim in a subshell with the variable unset; the parent's regex is never
# touched.
( unset MC_LANE_EXHAUST_RE
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_lane_account_fact "a custom phrase from this operator" && exit 1
  exit 0
) && ok || bad "7: 'custom phrase' matches with NO override set — the override test below would be vacuous"

( unset MC_LANE_EXHAUST_RE
  export ACCOUNT_EXHAUST_REGEX='custom phrase'
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_lane_account_fact "a custom phrase from this operator" \
    || { echo "  (the override phrase itself did not match)"; exit 1; }
  for r in "${EXHAUSTED[@]}"; do
    mc_lane_account_fact "$r" || { echo "  (built-in lost under the override: $r)"; exit 1; }
  done
  for r in "${NOT_FACTS[@]}"; do
    mc_lane_account_fact "$r" && { echo "  (the override widened the match to: $r)"; exit 1; }
  done
  exit 0
) && ok || bad "7: ACCOUNT_EXHAUST_REGEX must OR with the built-in list, and widen it no further"

# ============================================================================
# 8. MC_LANE_ROUTED_RETRY_SECS REJECTS A NON-INTEGER
# ============================================================================
# "Rejects" = falls back to the 3600 default so the bad value never reaches the
# age comparison. A bad knob must never take the conductor down.
for v in abc '' 12x -5 3.5 ' ' 99999999999999999999x; do
  ( export MC_LANE_ROUTED_RETRY_SECS="$v"
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
    [ "$MC_LANE_ROUTED_RETRY_SECS" = 3600 ] ) \
    && ok || bad "8: MC_LANE_ROUTED_RETRY_SECS='$v' must fall back to 3600"
done
( export MC_LANE_ROUTED_RETRY_SECS=900
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  [ "$MC_LANE_ROUTED_RETRY_SECS" = 900 ] ) \
  && ok || bad "8: a valid MC_LANE_ROUTED_RETRY_SECS must be kept"
( unset MC_LANE_ROUTED_RETRY_SECS
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  [ "$MC_LANE_ROUTED_RETRY_SECS" = 3600 ] ) \
  && ok || bad "8: an unset MC_LANE_ROUTED_RETRY_SECS must be 3600"

# The behavioural half: the fallback is what the expiry actually compares on.
clear_markers
mc_lane_down_note "$FACT" acct-a
touch -d "@$(( $(date -u +%s) - 1200 ))" "$MARK_D/acct-a"   # 20 minutes old
( export MC_LANE_ROUTED_RETRY_SECS=abc
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_lane_down_for_account acct-a ) \
  && ok || bad "8: a junk knob must leave the 3600 window in force (a 20m-old marker still holds)"
[ -f "$MARK_D/acct-a" ] && ok || bad "8: a marker inside the window was released"
( export MC_LANE_ROUTED_RETRY_SECS=600
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_lane_down_for_account acct-a ) \
  && bad "8: a marker older than the window still held the gate shut" || ok
[ ! -f "$MARK_D/acct-a" ] && ok || bad "8: the expired marker was not removed (no release event)"

# The DEFAULT marker is never timed — the hourly canary owns it.
clear_markers
mc_lane_down_note "$FACT" default
touch -d "@$(( $(date -u +%s) - 604800 ))" "$MARK_DEF"      # a week old
mc_lane_down_for_account default && ok \
  || bad "8: the default marker expired on a timer — only the canary may clear it"
clear_markers

# ============================================================================
# 9. LOCK PRIMITIVES: paths, the lock is really held, the fd is really released
# ============================================================================
[ "$(mc_safe_name 'a/b c:d')" = 'a_b_c_d' ] && ok \
  || bad "9: mc_safe_name (got $(mc_safe_name 'a/b c:d'))"
[ "$(mc_safe_name 'keep.me-1_2')" = 'keep.me-1_2' ] && ok \
  || bad "9: mc_safe_name must keep . - _ and alphanumerics"
[ "$(mc_pr_lock demo-os 'x/y')" = "$T/h/locks/merge-conductor-demo-os-x_y.lock" ] && ok \
  || bad "9: mc_pr_lock path (got $(mc_pr_lock demo-os 'x/y'))"
[ "$(mc_merge_lock demo-os)" = "$T/h/locks/merge-conductor-demo-os-merge.lock" ] && ok \
  || bad "9: mc_merge_lock path (got $(mc_merge_lock demo-os))"
[ "$(mc_git_lock demo-os)" = "$T/h/locks/merge-conductor-demo-os-git.lock" ] && ok \
  || bad "9: mc_git_lock path (got $(mc_git_lock demo-os))"
# The three are distinct files, so a PR worker's lock can never be a project's.
[ "$(mc_pr_lock demo-os 11)" != "$(mc_merge_lock demo-os)" ] \
  && [ "$(mc_merge_lock demo-os)" != "$(mc_git_lock demo-os)" ] && ok \
  || bad "9: the PR, merge and git locks must be three different files"

MLK=$(mc_merge_lock demo-os); GLK=$(mc_git_lock demo-os)
# rc is the wrapped command's own, never the wrapper's.
mc_merge_locked demo-os true; [ "$?" = 0 ] && ok || bad "9: mc_merge_locked must return the command's rc 0"
mc_merge_locked demo-os false; [ "$?" = 1 ] && ok || bad "9: mc_merge_locked must return the command's rc 1"
mc_git_locked demo-os true; [ "$?" = 0 ] && ok || bad "9: mc_git_locked must return the command's rc 0"
mc_git_locked demo-os bash -c 'exit 7'; [ "$?" = 7 ] && ok \
  || bad "9: mc_git_locked must pass an arbitrary rc through (99 is reserved for 'no lock')"
# The command really runs, and it really runs while the lock is HELD: a second
# flock on the same file from inside the section must be refused.
mc_merge_locked demo-os bash -c 'flock -n "$1" true; printf "%s" "$?" > "$2"; :' _ "$MLK" "$T/held-merge.txt"
[ "$(cat "$T/held-merge.txt" 2>/dev/null)" = 1 ] && ok \
  || bad "9: the merge lock was NOT held while the command ran (inner flock rc '$(cat "$T/held-merge.txt" 2>/dev/null)')"
mc_git_locked demo-os bash -c 'flock -n "$1" true; printf "%s" "$?" > "$2"; :' _ "$GLK" "$T/held-git.txt"
[ "$(cat "$T/held-git.txt" 2>/dev/null)" = 1 ] && ok \
  || bad "9: the git lock was NOT held while the command ran (inner flock rc '$(cat "$T/held-git.txt" 2>/dev/null)')"
# ...and the fd is released the moment it returns. A lock that outlived its call
# is the 03:54-04:02Z project-5 stall the function shape exists to prevent.
[ -f "$MLK" ] && ok || bad "9: the merge lock file was not created under MC_LOCK_DIR"
flock -n "$MLK" true && ok || bad "9: the merge lock was still held after mc_merge_locked returned"
flock -n "$GLK" true && ok || bad "9: the git lock was still held after mc_git_locked returned"

# ============================================================================
# 10. CLAIM PRIMITIVES: one attempt per (kind, PR, head), and the lane-fail
#     ledger keyed on the epoch
# ============================================================================
KEY='example-org/demo-os#12'
SHA_A=aaaa1111; SHA_B=bbbb2222
: > "$MC_ATTEMPTS"
mc_attempted rebase "$KEY" "$SHA_A" && bad "10: a first attempt must not read as already tried" || ok
mc_attempted rebase "$KEY" "$SHA_A" && ok || bad "10: the attempt was not recorded"
mc_attempted rebase "$KEY" "$SHA_B" && bad "10: a different head read as already tried" || ok
mc_attempted rereview "$KEY" "$SHA_A" && bad "10: a different kind read as already tried" || ok
mc_attempt_clear rebase "$KEY" "$SHA_A"
mc_attempted rebase "$KEY" "$SHA_A" && bad "10: mc_attempt_clear did not forget the attempt" || ok
mc_attempted rebase "$KEY" "$SHA_B" && ok || bad "10: mc_attempt_clear removed an attempt it was not asked about"

: > "$MC_ATTEMPTS"
mc_rr_lanefail_note "$KEY" "$SHA_A" 3
mc_rr_lanefail_note "$KEY" "$SHA_A" 3
[ "$(mc_rr_lanefail_count "$KEY" "$SHA_A" 3)" = 2 ] && ok \
  || bad "10: lane-fail count under one epoch (got $(mc_rr_lanefail_count "$KEY" "$SHA_A" 3))"
[ "$(mc_rr_lanefail_count "$KEY" "$SHA_A" 4)" = 0 ] && ok \
  || bad "10: the cap must reset when the lane epoch moves (got $(mc_rr_lanefail_count "$KEY" "$SHA_A" 4))"
[ "$(mc_rr_lanefail_count "$KEY" "$SHA_B" 3)" = 0 ] && ok \
  || bad "10: lane-fail counts must be per head (got $(mc_rr_lanefail_count "$KEY" "$SHA_B" 3))"

echo "mc/locks-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
