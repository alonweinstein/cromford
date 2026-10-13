#!/bin/bash
# tests/review-provenance-test.sh — WHO READ THE CODE, and what happens when
# nobody did.
#
# THE TWO INCIDENTS THIS PINS (2026-09-16, project-5 #1621 and #1624).
#
# 1. PROVENANCE WAS A RUNNER WORD, AND THE RUNNER WORD IS NOT THE MODEL.
#    bin/agent-call.sh's tier-3 lane runs the STAGE'S OWN Claude model through
#    OpenRouter (`runner=openrouter, model=anthropic/claude-fable-5.1`). Every
#    merge gate compared against the literal string `claude`, so a Claude read
#    of the diff was filed as a cheap-lane fallback: the PR parked on
#    `provenance`, and in the conductor's own re-review an APPROVE was rewritten
#    into a BLOCK by `[ "$runner" = claude ] || v="BLOCK"`.
#    The mirror-image trap is just as real: `$OUT.model` used to be written by
#    the claude branch ALONE, so #1624's grok review carried `claude-opus-5` in
#    its model file. A rule that read the model alone would have called that
#    grok review a Claude read. The runner decides whether the model is
#    evidence; the model decides which Claude.
#
# 2. "NO VERDICT" WAS OUR OUTAGE, AND IT CLOSED A FINISHED PR.
#    #1621's re-review came back four seconds after it was bought. The run files
#    say why and nothing read them: the claude account was 429 `You've hit your
#    session limit`, and the survival ladder underneath it passes the prompt as
#    an argv element, which a 136KB review prompt cannot be. The conductor
#    counted that as "the reviewer had no verdict", parked `no-verdict`, and
#    bin/blocked-resolver.sh CLOSED the PR to rebuild it from scratch. the operator's
#    standing order (2026-09-16) is that only a concrete failed EVENT closes a
#    PR — silence from our own reviewer is not one.
#
# Run from anywhere: tests/review-provenance-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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

H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# bin/lib/gh-rest.sh rides with the conductor lib: since BH-784 mc_pr_diff and
# mc_pr_view go through gh_rest, and without the file the lib's fail-closed
# shims answer "unverifiable" to every read (mc_rereview then reports a lane
# failure for a diff it never asked for).
cp "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
export PATH="$T/fakebin:$PATH"

# ============================================================================
# 1. The pair rule, pure
# ============================================================================
# shellcheck source=/dev/null
. "$H/bin/lib/review-provenance.sh"

rp_is_claude claude ""                                  && ok || bad "the primary lane is claude whatever the model says"
rp_is_claude openrouter "anthropic/claude-fable-5.1"    && ok || bad "openrouter + an anthropic/ slug IS a Claude read — that is the whole point of the tier-3 lane keeping the stage model"
rp_is_claude openrouter "~anthropic/claude-opus-latest" && ok || bad "the ~anthropic/ variant slug agent-call.sh builds for bare model words must count too"
rp_is_claude openrouter "deepseek/deepseek-v4-flash"    && bad "the openrouter FLOOR model is not Claude" || ok
rp_is_claude grok "claude-opus-5"                       && bad "#1624: a grok run that inherited a stale claude-* .model file must NEVER read as a Claude review" || ok
rp_is_claude fireworks "accounts/fireworks/models/kimi-k2p7-code" && bad "fireworks serves open models only" || ok
rp_is_claude codex "gpt-6-astra"                        && bad "codex is not a Claude lane" || ok

[ "$(rp_prov_word claude claude-fable-5-1)" = claude ]                            && ok || bad "the primary lane records as claude"
[ "$(rp_prov_word openrouter anthropic/claude-fable-5.1)" = claude-via-openrouter ] && ok || bad "a Claude model on the tier-3 lane records HONESTLY: claude-via-openrouter, never plain claude (got $(rp_prov_word openrouter anthropic/claude-fable-5.1))"
[ "$(rp_prov_word openrouter deepseek/deepseek-v4-flash)" = openrouter ]          && ok || bad "the openrouter floor records as the lane"
[ "$(rp_prov_word grok claude-opus-5)" = grok ]                                   && ok || bad "a stale model file must not rename the grok lane"
[ "$(rp_prov_word - -)" = - ]                                                     && ok || bad "absence stays absence — it is not a claim about any lane"
[ "$(rp_prov_word '' '')" = - ]                                                   && ok || bad "an empty runner word is absence too"

rp_prov_is_claude claude                && ok || bad "reader: claude"
rp_prov_is_claude claude-via-openrouter && ok || bad "reader: claude-via-openrouter is a Claude read — this is the word the merge gates must not park on"
rp_prov_is_claude openrouter            && bad "the bare lane word is not a Claude read" || ok
rp_prov_is_claude grok                  && bad "grok is not a Claude read" || ok
rp_prov_is_claude -                     && bad "absence is not a Claude read; the caller decides what silence means" || ok
rp_prov_is_claude ''                    && bad "empty is not a Claude read" || ok

# The markers as agent-call.sh writes them, beside the output file.
mk() { printf '%s\n' "$2" > "$1.runner"; printf '%s\n' "$3" > "$1.model"; printf 'x\n' > "$1"; }
mk "$T/o1" openrouter "anthropic/claude-fable-5.1"
mk "$T/o2" grok "claude-opus-5"
printf 'x\n' > "$T/o3"                       # no markers at all: a pre-2026-08 record
rp_out_is_claude "$T/o1" && ok || bad "rp_out_is_claude must read the PAIR from the markers"
rp_out_is_claude "$T/o2" && bad "#1624 again, through the marker files" || ok
rp_out_is_claude "$T/o3" && ok || bad "a record with no .runner marker predates the fallback lanes — it reads as claude, exactly as every call site did before this lib"
[ "$(rp_out_label "$T/o2")" = "grok (claude-opus-5)" ] && ok || bad "a log line has to be able to name what actually served the call (got $(rp_out_label "$T/o2"))"

# ============================================================================
# 2. The merge gates that read the word
# ============================================================================
export MC_H="$H"
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init

mc_prov_held claude                && bad "claude is not a provenance hold" || ok
mc_prov_held claude-via-openrouter && bad "a Claude model on the tier-3 lane must NOT park a PR — project-5 #1621's build was finished and green" || ok
mc_prov_held -                     && bad "'-' means the ledger said nothing" || ok
mc_prov_held grok                  && ok || bad "grok still holds"
mc_prov_held codex                 && ok || bad "codex still holds"

H1=aaaaaaaa1111
c() { mc_classify "$@" | cut -f1; }
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude-via-openrouter green 0 0 0 0 - -)" = READY ] && ok \
  || bad "an APPROVE authored by Claude through OpenRouter, clean and green, must be READY (got $(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude-via-openrouter green 0 0 0 0 - -))"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE grok green 0 0 0 0 - -)" = BLOCKED_HUMAN ] && ok \
  || bad "a grok-authored APPROVE must still park on provenance — regression"

# --- 2b. THE MERGE WITH #506: both intents, on every square of the grid. ------
# #506 (BH-491, 2026-09-16) landed a DIRTY fall-through on mc_classify's
# provenance arm while this branch was open. The two rules have to hold at once,
# and they meet on the DIRTY rows:
#
#   #502 (this branch): `claude-via-openrouter` IS a Claude read, so it is never
#                       held anywhere a literal `claude` would not be.
#   #506:               a head nobody has read is HEAD_MOVED whether or not it
#                       conflicts. The guard is a fall-through on the provenance
#                       arm, NOT a copy of the DIRTY test hoisted above it —
#                       hoisting shadowed the drift branch, so a conflicted PR
#                       whose head had moved answered NEEDS_REBASE and stopped
#                       buying the head-bound re-review that binds an approval to
#                       the sha it read.
#
# The DIRTY arm's own reason word is the square git could NOT flag: it merged
# clean from main still carrying the literal list `claude|-|""`, which would have
# filed a claude-via-openrouter PR as `dirty-under-provenance` — the exact
# mislabel this branch exists to delete, reintroduced by a clean automerge.
cr() { mc_classify "$@"; }
H2=bbbbbbbb2222

# #506's intent: drift outranks the rebase, under EVERY provenance word.
for P in grok codex claude claude-via-openrouter; do
  [ "$(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE $P none 0 0 0 0 - -)" = HEAD_MOVED ] && ok \
    || bad "a DIRTY head nobody has read is HEAD_MOVED, not NEEDS_REBASE (prov=$P) — the hoisted DIRTY test #506 removed shadowed the drift branch"
done

# The DIRTY arm, head already reviewed: the reason names the hold, and it names
# it by mc_prov_held — not by the literal word list.
[ "$(cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE grok none 0 0 0 0 - -)" \
  = "$(printf 'NEEDS_REBASE\tdirty-under-provenance')" ] && ok \
  || bad "a DIRTY grok PR rebases and says WHY (got: $(cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE grok none 0 0 0 0 - -))"
[ "$(cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude-via-openrouter none 0 0 0 0 - -)" \
  = "$(printf 'NEEDS_REBASE\tmergeState DIRTY')" ] && ok \
  || bad "a Claude model on the tier-3 lane is a Claude read: its DIRTY PR is a plain rebase, never dirty-under-provenance (got: $(cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude-via-openrouter none 0 0 0 0 - -))"
[ "$(cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude none 0 0 0 0 - -)" \
  = "$(printf 'NEEDS_REBASE\tmergeState DIRTY')" ] && ok \
  || bad "a claude-authored DIRTY PR is a plain rebase — regression"
[ "$(MC_PROV_CLEARED=1 cr OPEN DIRTY CONFLICTING $H1 $H1 APPROVE grok none 0 0 0 0 - -)" \
  = "$(printf 'NEEDS_REBASE\tmergeState DIRTY')" ] && ok \
  || bad "a cleared provenance hold drops the dirty-under-provenance reason too"

# And the park itself still fires for a real non-primary runner on a head that
# CAN merge — the fall-through must not have deleted the hold.
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - -)" = BLOCKED_HUMAN ] && ok \
  || bad "the provenance park must still fire on a clean head — the #506 fall-through is DIRTY-only"

# ============================================================================
# 3. mc_review_lane_failure: our outage, named
# ============================================================================
lf() { mc_review_lane_failure "$1" "${2:-0}"; }

# (a) the 429 that started this: the claude lane's own envelope.
printf 'nothing useful\n' > "$T/f1"
jq -nc '{is_error:true,api_error_status:429,result:"You'"'"'ve hit your session limit · resets 8am (America/Chicago)",terminal_reason:"api_error"}' > "$T/f1.json"
printf 'claude\n' > "$T/f1.runner"; printf 'claude-fable-5-1\n' > "$T/f1.model"
W=$(lf "$T/f1"); RC=$?
[ "$RC" = 0 ] && ok || bad "a 429 session limit is a LANE failure, not a verdict about the PR"
grep -q "session limit" <<<"$W" && grep -q 429 <<<"$W" && ok \
  || bad "the reason must quote the vendor's own words — that string is the whole diagnosis (got: $W)"

# (b) the E2BIG the ladder died on, verbatim from #1621's run file.
printf '/root/harness/bin/agent-call.sh: line 872: /usr/bin/timeout: Argument list too long\n' > "$T/f2"
printf 'fireworks\n' > "$T/f2.runner"
W=$(lf "$T/f2" 1); RC=$?
[ "$RC" = 0 ] && ok || bad "agent-call rc!=0 is a lane failure"
grep -q "Argument list too long" <<<"$W" && ok || bad "the reason must carry the shell's own error line (got: $W)"

# (c) the refusal markers agent-call.sh writes when it declines to run a lane.
printf 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom\n' > "$T/f3"
printf 'claude\n' > "$T/f3.runner"
W=$(lf "$T/f3" 76); RC=$?
[ "$RC" = 0 ] && grep -q AGENT_CALL_NO_HEADROOM <<<"$W" && ok || bad "a lane that never ran is a lane failure (got rc=$RC: $W)"

# (d) nothing written at all.
: > "$T/f4"; printf 'claude\n' > "$T/f4.runner"
lf "$T/f4" 0 >/dev/null && ok || bad "an empty output file is a lane failure"

# (e) a non-Claude runner. This is where `|| v=BLOCK` used to live.
printf 'Looks fine to me.\nVERDICT: APPROVE\n' > "$T/f5"
printf 'grok\n' > "$T/f5.runner"; printf 'claude-opus-5\n' > "$T/f5.model"
W=$(lf "$T/f5" 0); RC=$?
[ "$RC" = 0 ] && ok || bad "a grok review is not the claude read the gate asked for"
grep -q "grok" <<<"$W" && ok || bad "the reason must name the lane that served it (got: $W)"

# (f) the negative case: a real Claude answer is NOT a lane failure.
printf 'VERDICT: APPROVE\n' > "$T/f6"; printf 'claude\n' > "$T/f6.runner"; printf 'claude-fable-5-1\n' > "$T/f6.model"
lf "$T/f6" 0 >/dev/null && bad "a Claude lane that answered must not read as a failure" || ok
printf 'VERDICT: BLOCK\n' > "$T/f7"; printf 'openrouter\n' > "$T/f7.runner"; printf 'anthropic/claude-fable-5.1\n' > "$T/f7.model"
lf "$T/f7" 0 >/dev/null && bad "Claude through OpenRouter answered — that is a read, not a failure" || ok

# ============================================================================
# 4. mc_rereview end to end, with the lanes stubbed
# ============================================================================
mkdir -p "$H/bin"
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
# stage project model timeout OUT @prompt
OUT="$5"
case "$FAKE_LANE" in
  claude-approve)  printf 'VERDICT: APPROVE\n' > "$OUT"; printf 'claude\n' > "$OUT.runner"; printf 'claude-fable-5-1\n' > "$OUT.model" ;;
  claude-block)    printf 'VERDICT: BLOCK\n'   > "$OUT"; printf 'claude\n' > "$OUT.runner"; printf 'claude-fable-5-1\n' > "$OUT.model" ;;
  claude-waffle)   printf 'I am not sure.\n'   > "$OUT"; printf 'claude\n' > "$OUT.runner"; printf 'claude-fable-5-1\n' > "$OUT.model" ;;
  or-approve)      printf 'VERDICT: APPROVE\n' > "$OUT"; printf 'openrouter\n' > "$OUT.runner"; printf 'anthropic/claude-fable-5.1\n' > "$OUT.model" ;;
  grok-approve)    printf 'VERDICT: APPROVE\n' > "$OUT"; printf 'grok\n' > "$OUT.runner"; printf 'claude-opus-5\n' > "$OUT.model" ;;
  limit)           printf 'nope\n' > "$OUT"; printf 'claude\n' > "$OUT.runner"
                   jq -nc '{is_error:true,api_error_status:429,result:"You'"'"'ve hit your session limit · resets 8am"}' > "$OUT.json"; exit 1 ;;
esac
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# mc_rereview reads the diff and the PR body through REST now (BH-784): one
# gh api -i -X GET on the pull, judged on its HTTP status line, so restpr prints
# a whole response. The diff shares that path and is told apart by its Accept
# header, which is why it is matched FIRST. Every WRITE verb still lands in the
# comment sink, which the test asserts stays EMPTY.
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.ts
+++ b/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/1621"*) restpr OPEN newsha ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
  *"pr comment"*|*"api -i -X POST repos/"*"/comments"*) echo "$*" >> "$FAKE_GH_COMMENTS" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export FAKE_GH_COMMENTS="$T/comments.txt"; : > "$FAKE_GH_COMMENTS"
URL=https://github.com/example-org/demo-os/pull/1621
rr() { FAKE_LANE="$1" mc_rereview example-org/demo-os 1621 demo-os "$URL" oldsha newsha "" "$T/rr.out"; }

V=$(rr claude-approve); [ "$?" = 0 ] && [ "$V" = APPROVE ] && ok || bad "a claude APPROVE is an APPROVE (rc=$? v=$V)"
V=$(rr claude-block);   [ "$?" = 0 ] && [ "$V" = BLOCK ]   && ok || bad "a claude BLOCK is a BLOCK"
V=$(rr or-approve);     RC=$?
[ "$RC" = 0 ] && [ "$V" = APPROVE ] && ok \
  || bad "THE #1621 FIX: Claude through OpenRouter APPROVED — it must come back APPROVE, not rewritten into a BLOCK (rc=$RC v='$V')"
V=$(rr grok-approve);   RC=$?
[ "$RC" = 2 ] && ok || bad "a grok review is a LANE failure (rc 2), not a fabricated BLOCK (rc=$RC v='$V')"
[ -z "$V" ] && ok || bad "a lane failure prints no verdict — it must not be mistakable for one (got '$V')"
grep -q grok "$T/rr.out.lanefail" && ok || bad "the reason file must name the lane"
V=$(rr limit);          RC=$?
[ "$RC" = 2 ] && ok || bad "a 429 is rc 2 (lane), never rc 1 (no verdict) — the difference is whether the PR is charged for it"
grep -q "session limit" "$T/rr.out.lanefail" && ok || bad "the 429's words must survive into the reason file"
V=$(rr claude-waffle);  RC=$?
[ "$RC" = 1 ] && ok || bad "a Claude lane that answered without a parsable verdict is rc 1 — a real no-verdict, and the only thing that still is"
[ -s "$FAKE_GH_COMMENTS" ] && bad "mc_rereview must never write to the PR — the tick owns every GitHub write" || ok

# The job wrapper records the lane failure under its own status.
JF="$H/state/merge-conductor/rereview/x.json"
mkdir -p "$(dirname "$JF")"
mc_rr_write "$JF" running $$ "$(mc_now)" 0 - newsha oldsha "$T/rr.out"
FAKE_LANE=limit mc_rereview_run example-org/demo-os 1621 demo-os "$URL" oldsha newsha "" "$JF" "$T/rr.out"
[ "$(mc_rr_field "$JF" status)" = lane-failed ] && ok || bad "the job must record lane-failed, not failed (got $(mc_rr_field "$JF" status))"
[ "$(mc_rr_state "$JF")" = lanefail ] && ok || bad "mc_rr_state must answer lanefail (got $(mc_rr_state "$JF"))"
grep -q "session limit" <<<"$(mc_rr_field "$JF" reason)" && ok || bad "the job file must carry the reason the tick will log"
grep -q "LANE FAILED" "$H/logs/merge-conductor.log" && ok || bad "the lane failure must be in the conductor log, in words, not silent"

# ============================================================================
# 5. The tick: a lane failure is retried, and NEVER parks on the first one
# ============================================================================
# headbound_review lifted out of bin/lib/mc/classify.sh — the lanefail arm needs
# only the lib, so the rest of the tick is not in the way.
awk '/^headbound_review\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/lib/mc/classify.sh" > "$T/hbr.sh"
grep -q 'lanefail)' "$T/hbr.sh" || { echo "FAIL: could not lift headbound_review"; exit 1; }
# shellcheck source=/dev/null
. "$T/hbr.sh"
ALERTS=""; mc_alert() { ALERTS="$ALERTS|$3"; echo "$3" >> "$T/alerts.txt"; }
: > "$T/alerts.txt"
KEY="example-org/demo-os#1621"; HEAD=newsha
JF2=$(mc_rr_file example-org/demo-os 1621 "$HEAD")
lanefail_job() { mc_rr_write "$JF2" lane-failed $$ "$(mc_now)" "$(mc_now)" - "$HEAD" oldsha "$T/rr.out" "the claude review lane errored (HTTP 429): You've hit your session limit"; }

export MC_RR_LANEFAIL_MAX=3
for i in 1 2 3; do
  lanefail_job
  headbound_review provenance "$KEY" example-org/demo-os 1621 demo-os "$URL" "" "$HEAD" oldsha APPROVE CLEAN green; RCH=$?
  [ "$RCH" = 0 ] && ok || bad "read $i of 3: a lane failure must return 0 (carry on classifying), not park (rc=$RCH)"
  [ -f "$JF2" ] && bad "read $i: the job file must be REMOVED so the next tick buys another read" || ok
  grep -q "no verdict, no strike and no park" "$H/logs/merge-conductor.log" && ok || bad "read $i: the log must say the PR was not charged for our outage"
  grep -qE 'BLOCKED_HUMAN|BLOCKED_AGENT' "$H/logs/merge-conductor.log" && bad "read $i: three reads is not a park — MC_RR_LANEFAIL_MAX is the bound, not the first failure" || ok
done
# The read after the cap: still no verdict, and now it parks — without closing.
lanefail_job
headbound_review provenance "$KEY" example-org/demo-os 1621 demo-os "$URL" "" "$HEAD" oldsha APPROVE CLEAN green; RCH=$?
[ "$RCH" = 1 ] && ok || bad "past the cap the row is parked, so the tick is finished with this PR (rc=$RCH)"
grep -q "session limit" "$T/alerts.txt" && ok || bad "past the cap ONE actionable ALERT must name what is down (stopping is an alert, not a whisper)"
grep -q "parked (not closed)" "$T/alerts.txt" && ok || bad "the alert must say the PR was left open"
ROW=$(grep -F "$KEY" "$MC_ROWS" | tail -1)
grep -q BLOCKED_HUMAN <<<"$ROW" && ok || bad "past the cap the row parks: $ROW"
grep -q 'no-verdict' <<<"$ROW" && ok || bad "it parks on no-verdict, the reason bin/blocked-resolver.sh owns: $ROW"
grep -q 'review lane down' <<<"$ROW" && ok || bad "the park reason must name the lane, so the row itself says whose problem this is: $ROW"
grep -qE 'CLOSED|ABANDONED' <<<"$ROW" && bad "NOTHING here may close or abandon a PR for a review we never got" || ok
grep -q 'handed to bin/blocked-resolver.sh' "$H/logs/merge-conductor.log" && ok || bad "the park must be handed off in the line shape br_handoff_lines reads"

# ============================================================================
# 6. The resolver: silence never closes a PR (the operator, 2026-09-16)
# ============================================================================
# br_rereview lifted the way tests/blocked-resolver-test.sh lifts its rungs.
awk '/^br_rereview\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brr.sh"
grep -q 'rc" = 2' "$T/brr.sh" || { echo "FAIL: could not lift br_rereview"; exit 1; }
grep -q 'br_rebuild_fresh' "$T/brr.sh" && bad "br_rereview must not reach br_rebuild_fresh at all — that is the call that CLOSED project-5 #1621" || ok
awk '/^br_lane_down_alert\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" >> "$T/brr.sh"
# shellcheck source=/dev/null
BR_NOVERDICT_MAX=2; BR_LANEFAIL_MAX=3; . "$T/brr.sh"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$T/br.log"; : > "$LOG"; OBSERVE=0; export H
say() { echo "$*" >> "$LOG"; }
STATEJ="$T/br.json"; echo '{"rereviews":0}' > "$STATEJ"
br_load() { cat "$STATEJ"; }
br_num()  { printf '%s' "$(jq -r --arg f "$2" '.[$f] // 0' <<<"$1")"; }
br_record() { echo "record $3 $5" >> "$LOG"; [ -n "${6:-}" ] && jq -c --arg b "$6" '.[$b] = ((.[$b] // 0) + 1)' "$STATEJ" > "$STATEJ.t" && mv "$STATEJ.t" "$STATEJ"; return 0; }
# BH-1019: the rung now stamps WHICH outage its lane failures belong to.
br_set_field() { jq -c --arg k "$3" --arg v "${4:-}" '.[$k]=$v' "$STATEJ" > "$STATEJ.t" && mv "$STATEJ.t" "$STATEJ"; return 0; }
# A COUNTER is reset as a number, or br_record's `+ 1` dies on a string and
# silently drops the whole attempt record — which is why the two setters differ.
br_set_num()   { jq -c --arg k "$3" --argjson v "${4:-0}" '.[$k]=$v' "$STATEJ" > "$STATEJ.t" && mv "$STATEJ.t" "$STATEJ"; return 0; }
br_close_pr() { echo "CLOSED-THE-PR" >> "$LOG"; }
br_rebuild_fresh() { echo "REBUILT-FRESH" >> "$LOG"; }
mc_row_field() { printf 'oldsha'; }
job_verdict_rebind() { return 0; }

FAKE_LANE=limit br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "no counter spent" "$LOG" && ok || bad "a lane failure must not spend one of the PR's reads: $(cat "$LOG")"
[ "$(jq -r '.rereviews' "$STATEJ")" = 0 ] && ok || bad "the counter moved on a read we never got"
[ "$(jq -r '.lanefails' "$STATEJ")" = 1 ] && ok || bad "lane failures are counted on their OWN axis — they bound the spend without eating the PR's reads"
FAKE_LANE=claude-waffle br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
FAKE_LANE=claude-waffle br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
[ "$(jq -r '.rereviews' "$STATEJ")" = 2 ] && ok || bad "a real no-verdict spends a read"
grep -qE 'CLOSED-THE-PR|REBUILT-FRESH' "$LOG" && bad "THE #1621 REGRESSION: two silent reads must not close or rebuild the PR" || ok
: > "$T/alerts.txt"
FAKE_LANE=claude-waffle br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "stops spending" "$LOG" && ok || bad "past BR_NOVERDICT_MAX the rung stops buying reads"
grep -qE 'CLOSED-THE-PR|REBUILT-FRESH' "$LOG" && bad "and it still must not close the PR" || ok
grep -q "REVIEW LANE DOWN" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "past the cap ONE ALERTS line must name the lane as the broken thing"
grep -q "left OPEN, never closed" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "the alert must say what did NOT happen to the PR"
FAKE_LANE=claude-approve br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "stops spending" "$LOG" && ok || bad "and it stays stopped until the lane is fixed"

# The lane-failure axis has its own bound: a rung that answered "no counter
# spent" every tick forever would still be BUYING an attempt every tick (the
# grok rung runs, answers, and is discarded as not-a-Claude-read).
echo '{"rereviews":0,"lanefails":0}' > "$STATEJ"; : > "$LOG"
for i in 1 2 3; do FAKE_LANE=limit br_rereview demo-os 1621 no-verdict "$URL" "" TK-1; done
[ "$(jq -r '.lanefails' "$STATEJ")" = 3 ] && ok || bad "three lane failures must be counted (got $(jq -r '.lanefails' "$STATEJ"))"
: > "$LOG"
FAKE_LANE=limit br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "stops buying attempts" "$LOG" && ok || bad "past BR_LANEFAIL_MAX the rung stops buying attempts: $(cat "$LOG")"
[ "$(jq -r '.rereviews' "$STATEJ")" = 0 ] && ok || bad "and the PR's own read budget was never touched by any of it"
# ...AND IT STAYS STOPPED ONLY WHILE THE LANE STAYS DOWN (BH-1019). `lanefails`
# used to be a counter nothing ever reset, so five failures during one quota
# outage stranded the row for good: the conductor's park releases when the lane
# comes back and this cap did not, which strands the same PR one lane further
# down. It is bound to the same lane-health epoch both lanes read.
[ "$(jq -r '.lanefail_epoch' "$STATEJ")" = "$(mc_lane_epoch)" ] && ok \
  || bad "the lane failures must be stamped with the outage they belong to (got $(jq -r '.lanefail_epoch' "$STATEJ"))"
# The lane comes back: a Claude answer anywhere on the box, or the hourly
# canary. Section 3's 429 fixtures already marked it down through mc_rereview,
# which is why this is the release and not another failure.
mc_lane_up
: > "$LOG"; FAKE_LANE=limit br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "health changed" "$LOG" && ok \
  || bad "a lane-health change must give this rung its failures back, or nothing re-reads the PR when the quota resets: $(cat "$LOG")"
[ "$(jq -r '.lanefails' "$STATEJ")" = 1 ] && ok \
  || bad "the count must restart under the new epoch, not continue (got $(jq -r '.lanefails' "$STATEJ"))"
: > "$LOG"; FAKE_LANE=limit br_rereview demo-os 1621 no-verdict "$URL" "" TK-1
grep -q "health changed" "$LOG" && bad "the forgetting is once per lane-health change, not every tick" || ok
grep -qE 'CLOSED-THE-PR|REBUILT-FRESH' "$LOG" && bad "a broken lane must never close the PR, however many times it breaks" || ok

# ============================================================================
# 7. The argv ceiling that made the survival ladder unreachable for reviews
# ============================================================================
grep -q 'agent_argv_too_big' "$DIR/bin/agent-call.sh" && ok || bad "bin/agent-call.sh must bound what it puts in an argv element"
# Driven, not grepped: a prompt over the ceiling must reach codex on STDIN.
mkdir -p "$T/or"; cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "-" ] && { wc -c > "$FAKE_CODEX_STDIN_BYTES"; echo "stdin"; exit 0; }; done
echo "argv" ; exit 0
EOF
chmod +x "$T/fakebin/codex"
export FAKE_CODEX_STDIN_BYTES="$T/stdin.bytes"
P=$(head -c 200000 /dev/zero | tr '\0' 'x')
( set -- ; AGENT_ARGV_MAX=96000; agent_argv_too_big() { [ "${#1}" -ge "$AGENT_ARGV_MAX" ]; }
  agent_argv_too_big "$P" ) && ok || bad "a 200KB prompt is over the argv ceiling by any reading"
( AGENT_ARGV_MAX=96000; agent_argv_too_big() { [ "${#1}" -ge "$AGENT_ARGV_MAX" ]; }
  agent_argv_too_big "short" ) && bad "a short prompt must keep going through argv, byte for byte as today" || ok
printf '%s' "$P" | codex exec -m m - >/dev/null 2>&1
[ "$(tr -d ' ' < "$FAKE_CODEX_STDIN_BYTES")" = 200000 ] && ok || bad "codex must receive the whole prompt on stdin when it is passed '-' (got $(cat "$FAKE_CODEX_STDIN_BYTES"))"

echo "review-provenance-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
