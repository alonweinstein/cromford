#!/bin/bash
# bin/replan-check.sh <project> <ticket> <key> <build-dir> — BH-3955: the replan
# check between waves. Called from bin/lib/rb/plan.sh `# >>> replan check
# (BH-3955)`, before the plan, on every build.
#
# WHY. A split child (`<KEY>.<n>: …`, n >= 1, `Part of #<parent>`) was written
# before its `Blocked-by` siblings were built. By the time those siblings have
# merged, what they actually shipped may have renamed the thing the child
# calls, settled a question it assumed, or made it moot. So once every blocker
# has merged, ONE cheap model call reads the blockers' merged diffs, their
# review / preview-QA findings and the parent thread since the split, and
# answers exactly one of:
#   REPLAN: keep                       build the child as written
#   REPLAN: amend                      AMEND-BEGIN … AMEND-END carries the new
#                                      scope; plan.sh plans against it and
#                                      posts it on the child as a comment
#   REPLAN: escalate :: <decision>     a human must decide first: the child is
#                                      parked with the `hold` label and ONE
#                                      beat names the decision
#
# OUTPUT. $BUILD/replan-verdict, always, one line: `skip <why>`, `keep <why>`,
# `amend <why>`, `escalate <decision>` or `escalate hold-failed <decision>`.
# Amend also writes replan-amendment.md and (for a fresh answer) replan-comment.md;
# escalate writes replan-decision.txt and replan-beat. Every non-skip verdict
# is one DECISION line through bin/decision-log.sh (gate=replan scope=child).
#
# FAIL-OPEN. Nothing here blocks a build: no route, no evidence, a model that
# failed or answered off-contract — all `keep`, logged. A blocker we could not
# read counts as NOT merged, so an outage is a skip and never a spend.
#
# DEDUP BEFORE SPEND. The D1 ledger row kind=replan key="<project> <KEY>" holds
# `<verdict> <fp>`, fp = sha256(child body + sorted blocker merge SHAs + parent
# comment ids); an amend keeps its amendment in the row's detail. Same fp, no
# call. Only a cleanly parsed answer is written, and an escalate only once its
# hold is on. A stored escalate whose hold label is now gone was answered by a
# human: it becomes keep and is never re-escalated on the same evidence.
#
# Kill switch: REPLAN_CHECK=0 or flags/replan-check-off. Caps (bytes, env
# overridable): REPLAN_DIFF_MAX 12000 per blocker, REPLAN_DIFF_TOTAL 30000,
# REPLAN_FINDING_MAX 3000 per file, REPLAN_COMMENTS_MAX 4000. Exit 0 always.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"; export HARNESS
P="${1:-}"; TICKET="${2:-}"; KEY="${3:-}"; BUILD="${4:-}"
[ -n "$P" ] && [ -n "$KEY" ] && [ -n "$BUILD" ] && [ -d "$BUILD" ] || exit 0
: "$TICKET"
VERDICT="$BUILD/replan-verdict"
DIFF_MAX="${REPLAN_DIFF_MAX:-12000}"; DIFF_TOTAL="${REPLAN_DIFF_TOTAL:-30000}"
FINDING_MAX="${REPLAN_FINDING_MAX:-3000}"; COMMENTS_MAX="${REPLAN_COMMENTS_MAX:-4000}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) [$P/$KEY] REPLAN $*" >> "$BUILD/pipeline.log"; }
skip() { printf 'skip %s\n' "$1" > "$VERDICT"; log "skip: $1 — no check, the plan runs as written"; exit 0; }
oneline() { tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ //; s/ $//'; }

# A resume reads the answer this build dir already paid for.
if [ -s "$VERDICT" ]; then log "verdict already recorded ($(head -1 "$VERDICT")) — reused, no model call"; exit 0; fi
# shellcheck source=lib/lane-switch.sh
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -e "$HARNESS/flags/$1" ]; }   # no lib: the file, as before
if [ "${REPLAN_CHECK:-1}" = 0 ] || lane_switch replan-check-off; then skip off; fi

# ── eligibility ──────────────────────────────────────────────────────────────
META="$BUILD/ticket-meta.json"
[ -s "$META" ] || skip "not a child"
TITLE=$(jq -r '.title // ""' "$META" 2>/dev/null)
WAVE=$(printf '%s\n' "$TITLE" | sed -nE '1s/^[[:space:]]*[A-Za-z]+-[0-9]+\.([0-9]+).*/\1/p')
[ -n "$WAVE" ] && [ "$((10#$WAVE))" -ge 1 ] || skip "not a child"
BODY=$(jq -r '.body // ""' "$META" 2>/dev/null)
# The footer lines are read outside code fences: a plain fence toggle. This
# lane never sources the filer (tests/file-children.bh-981-test.sh pins who
# may), and decompose writes the Part of / Blocked-by footer as plain lines.
VIS=$(printf '%s\n' "$BODY" | tr -d '\r' | awk '/^[[:space:]]*(```|~~~)/{f=!f; next} !f')
PARENT=$(printf '%s\n' "$VIS" | sed -nE 's/^Part of #([0-9]+)([^0-9].*)?$/\1/p' | head -1)
[ -n "$PARENT" ] || skip "not a child"
[ -z "${STACK_ON:-}" ] || skip "stacked build"
BLOCKERS=$(printf '%s\n' "$VIS" | grep -E '^Blocked-by:' | grep -oE '#[0-9]+' | tr -d '#' | sort -un)
[ -n "$BLOCKERS" ] || skip "no blockers"

SLUG=$("$HARNESS/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || skip "no GitHub repo for $P"
CHILD_N=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
[ -n "$CHILD_N" ] || skip "key $KEY carries no issue number"
PFX=$(printf '%s' "${KEY%%-*}" | tr '[:upper:]' '[:lower:]')
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HARNESS/bin/lib/gh-rest.sh" ] && . "$HARNESS/bin/lib/gh-rest.sh"
command -v gh_rest >/dev/null 2>&1 || skip "blockers not merged (no gh_rest on this box)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/replan.XXXXXX") || skip "no temp dir"
trap 'rm -rf "$TMP"' EXIT

# Merged = the blocker issue is CLOSED and a PR on its harness branch
# ticket/<prefix>-<n> has merged_at set. Any read that is not rc 0 is NOT merged.
: > "$TMP/merged.tsv"
for b in $BLOCKERS; do
  gh_rest GET "repos/$SLUG/issues/$b" > "$TMP/i$b.json" || skip "blockers not merged (#$b unreadable)"
  [ "$(jq -r '.state // ""' "$TMP/i$b.json" 2>/dev/null)" = closed ] || skip "blockers not merged (#$b is open)"
  gh_rest GET "repos/$SLUG/pulls?state=closed&head=${SLUG%%/*}:ticket/$PFX-$b&per_page=100" > "$TMP/p$b.json" \
    || skip "blockers not merged (#$b's PRs unreadable)"
  pr=$(jq -r '[.[]? | select(.merged_at != null)] | sort_by(.merged_at) | last | (.number // empty)' "$TMP/p$b.json" 2>/dev/null)
  sha=$(jq -r '[.[]? | select(.merged_at != null)] | sort_by(.merged_at) | last | (.merge_commit_sha // "")' "$TMP/p$b.json" 2>/dev/null)
  [[ "$pr" =~ ^[0-9]+$ ]] || skip "blockers not merged (#$b closed with no merged PR on ticket/$PFX-$b)"
  printf '%s\t%s\t%s\n' "$b" "$pr" "$sha" >> "$TMP/merged.tsv"
done
MERGED_TXT=$(awk -F'\t' '{printf "%s#%s (PR #%s)", (NR>1?", ":""), $1, $2}' "$TMP/merged.tsv")
log "every blocker merged: $MERGED_TXT — gathering evidence"

# ── evidence, capped ─────────────────────────────────────────────────────────
EV="$BUILD/replan-evidence.md"; TRUNC=no; HAVE=0; total=0
: > "$TMP/ev.md"
while IFS=$'\t' read -r b pr _sha; do
  if gh_rest GET "repos/$SLUG/pulls/$pr/files?per_page=100" > "$TMP/f$pr.json"; then
    jq -r '.[]? | "--- " + (.filename // "?") + "\n" + (.patch // "(no patch: binary or too large)")' "$TMP/f$pr.json" > "$TMP/d$pr.txt" 2>/dev/null
    [ "$(jq 'length' "$TMP/f$pr.json" 2>/dev/null || echo 0)" -ge 100 ] && TRUNC=yes
  else
    : > "$TMP/d$pr.txt"; echo "(diff of PR #$pr unreadable)" >> "$TMP/ev.md"; TRUNC=yes
  fi
  if [ -s "$TMP/d$pr.txt" ]; then
    room=$((DIFF_TOTAL - total)); cap=$DIFF_MAX; [ "$room" -lt "$cap" ] && cap=$room
    [ "$cap" -lt 0 ] && cap=0
    [ "$(wc -c < "$TMP/d$pr.txt")" -gt "$cap" ] && TRUNC=yes
    { echo "## Blocker #$b, merged as PR #$pr: diff"; head -c "$cap" "$TMP/d$pr.txt"; echo; } >> "$TMP/ev.md"
    total=$((total + $(head -c "$cap" "$TMP/d$pr.txt" | wc -c))); [ "$cap" -gt 0 ] && HAVE=1
  fi
  # (b) review / preview-QA findings from this box's own record of the blocker build.
  dir=$(ls -1dt "$HARNESS/builds/$P-${KEY%%-*}-$b-"* "$HARNESS/builds/pool-$P-${KEY%%-*}-$b-"* 2>/dev/null | head -1)
  if [ -n "$dir" ]; then
    for f in "$dir/review.md" "$dir"/preview-qa*.md; do
      [ -s "$f" ] || continue
      [ "$(wc -c < "$f")" -gt "$FINDING_MAX" ] && TRUNC=yes
      { echo "## Blocker #$b: $(basename "$f")"; head -c "$FINDING_MAX" "$f"; echo; } >> "$TMP/ev.md"; HAVE=1
    done
  fi
done < "$TMP/merged.tsv"
# (c) parent comments created after this child was filed.
CMT_IDS=""
CREATED=""
gh_rest GET "repos/$SLUG/issues/$CHILD_N" > "$TMP/child.json" && CREATED=$(jq -r '.created_at // ""' "$TMP/child.json" 2>/dev/null)
if [ -n "$CREATED" ] && gh_rest GET "repos/$SLUG/issues/$PARENT/comments?since=$CREATED&per_page=100" > "$TMP/pc.json"; then
  jq -r --arg c "$CREATED" '[.[]? | select((.created_at // "") > $c)] | .[] | "### comment " + (.id|tostring) + " (" + .created_at + ")\n" + (.body // "")' "$TMP/pc.json" > "$TMP/pc.txt" 2>/dev/null
  CMT_IDS=$(jq -r --arg c "$CREATED" '[.[]? | select((.created_at // "") > $c) | .id] | sort | map(tostring) | join(",")' "$TMP/pc.json" 2>/dev/null)
  if [ -s "$TMP/pc.txt" ]; then
    [ "$(wc -c < "$TMP/pc.txt")" -gt "$COMMENTS_MAX" ] && TRUNC=yes
    { echo "## Parent #$PARENT: comments since the split"; head -c "$COMMENTS_MAX" "$TMP/pc.txt"; echo; } >> "$TMP/ev.md"; HAVE=1
  fi
else
  echo "(parent #$PARENT comments unreadable)" >> "$TMP/ev.md"; TRUNC=yes
fi
{ echo "truncated: $TRUNC"; echo; cat "$TMP/ev.md"; } > "$EV"

# ── verdict helpers ──────────────────────────────────────────────────────────
decide() { # decide <verdict> <reason> — the verdict file and the DECISION line
  printf '%s %s\n' "$1" "$2" > "$VERDICT"
  printf 'DECISION: %s :: replan-%s :: %s\n' "$KEY" "$1" "$(printf '%s' "$2" | oneline | cut -c1-200)" > "$BUILD/replan-decision.out"
  [ -x "$HARNESS/bin/decision-log.sh" ] && "$HARNESS/bin/decision-log.sh" "$P" replan child "$BUILD/replan-decision.out" >/dev/null 2>&1
  log "verdict: $1 — $2"
}
if [ "$HAVE" != 1 ]; then decide keep "no evidence (no blocker diff, no findings, no parent comments since the split)"; exit 0; fi

# The jobs client for the ledger; absent or down means no dedup, never a block.
if [ -r "$HARNESS/bin/jobs-client.sh" ] && [ -r "$HARNESS/bin/lib/jobs/req.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
fi
LKEY="$P $KEY"
FP=$( { printf '%s\n' "$BODY"; cut -f3 "$TMP/merged.tsv" | sort; printf '%s\n' "$CMT_IDS"; } | sha256sum | cut -c1-64)
LSTATUS=""; LDETAIL=""
if command -v _jobs_req >/dev/null 2>&1; then
  q=$(jq -nr --arg k replan --arg v "$LKEY" '"kind="+($k|@uri)+"&key="+($v|@uri)')
  if resp=$(_jobs_req GET "/api/ledger?$q" 2>/dev/null); then
    LSTATUS=$(jq -r '.ledger.status // ""' <<<"$resp" 2>/dev/null)
    LDETAIL=$(jq -r '.ledger.detail // ""' <<<"$resp" 2>/dev/null)
  fi
fi
ledger_put() { # ledger_put <verdict> [detail]
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put replan "$LKEY" "$1 $FP" "${2:-}" >/dev/null 2>&1 \
    || log "ledger write failed — the next build of $KEY may pay for this check again"
}
HOLD_ON=$(jq -r '[(.labels // [])[] | if type=="object" then (.name // "") else tostring end] | index("hold") != null' "$META" 2>/dev/null)
if [ "${LSTATUS##* }" = "$FP" ]; then
  case "${LSTATUS%% *}" in
    keep) decide keep "same evidence as an earlier check (ledger), no model call"; exit 0 ;;
    escalate)
      if [ "$HOLD_ON" != true ]; then
        ledger_put keep
        decide keep "escalation answered (hold lifted), same evidence, not re-escalated"; exit 0
      fi
      printf '%s\n' "$LDETAIL" > "$BUILD/replan-decision.txt"
      decide escalate "${LDETAIL:-still waiting on the decision from an earlier check}"; exit 0 ;;
    amend)
      if [ -n "$LDETAIL" ]; then
        printf '%s\n' "$LDETAIL" > "$BUILD/replan-amendment.md"
        decide amend "same evidence as an earlier check (ledger), amendment reused, no model call"; exit 0
      fi
      log "ledger says amend but carries no amendment — asking again" ;;
  esac
fi

# ── the model call ───────────────────────────────────────────────────────────
# shellcheck source=bin/lib/model-route.sh
[ -r "$HARNESS/bin/lib/model-route.sh" ] && . "$HARNESS/bin/lib/model-route.sh"
MODEL=""
command -v model_for >/dev/null 2>&1 && MODEL=$(model_for replan "$P" 2>/dev/null)
if [ -z "$MODEL" ]; then decide keep "no route (model_routes role replan answered nothing)"; exit 0; fi
PROMPT="$BUILD/replan-prompt.md"
{
  cat <<EOF
You are checking ONE split child ticket, $KEY ("$TITLE"), before it is planned. Every ticket it was blocked by has now merged. Decide whether the child can be built exactly as written.

Answer with exactly one final line, and nothing after it:
REPLAN: keep
REPLAN: amend
REPLAN: escalate :: <the one decision a human must make, one sentence>

keep: what the blockers shipped matches what this child assumes.
amend: the blockers changed something this child depends on (a name, a signature, a file, a settled question), and the scope can be corrected without a human. Put the corrected scope and acceptance tests between a line AMEND-BEGIN and a line AMEND-END, before the REPLAN line. Plain sentences, short.
escalate: the evidence raises a question only the ticket's owner can answer. Do not escalate for anything you can resolve by reading the evidence.
Never re-split the child, never change its blockers or its order.

THE CHILD, as filed:
$BODY

THE EVIDENCE$([ "$TRUNC" = yes ] && echo " (PARTIAL: some of it was truncated or unreadable)"):
EOF
  cat "$EV"
} > "$PROMPT"
RUN="$BUILD/replan-run.txt"
CALL_RC=0
AGENT_CALL_LANE=fly-pool AGENT_CALL_ROLE=replan \
  "$HARNESS/bin/agent-call.sh" replan "$P" "$MODEL" 180 "$RUN" "@$PROMPT" >/dev/null 2>&1 || CALL_RC=$?
if [ "$CALL_RC" != 0 ]; then decide keep "model error: agent-call rc=$CALL_RC"; exit 0; fi
LINE=$(tr -d '\r' < "$RUN" 2>/dev/null | grep -E '^REPLAN:' | tail -1 | sed -E 's/[[:space:]]+$//')
if [ -z "$LINE" ]; then decide keep "model error: no REPLAN line"; exit 0; fi
if ! [[ "$LINE" =~ ^REPLAN:\ (keep|amend|escalate)(\ ::\ (.*))?$ ]]; then
  decide keep "model error: unparseable verdict '$(printf '%s' "$LINE" | cut -c1-60)'"; exit 0
fi
WORD="${BASH_REMATCH[1]}"; REST=$(printf '%s' "${BASH_REMATCH[3]:-}" | oneline)

case "$WORD" in
  keep)
    ledger_put keep
    decide keep "model said keep" ;;
  amend)
    AMEND=$(tr -d '\r' < "$RUN" | awk '/^[[:space:]]*AMEND-BEGIN[[:space:]]*$/{f=1;next} /^[[:space:]]*AMEND-END[[:space:]]*$/{if(f)exit} f' | head -c 3500)
    if [ -z "$(printf '%s' "$AMEND" | tr -d '[:space:]')" ]; then decide keep "model error: amend with an empty AMEND block"; exit 0; fi
    printf '%s\n' "$AMEND" > "$BUILD/replan-amendment.md"
    {
      echo "Before planning this part, we checked what its blockers actually shipped, and the scope needed an update."
      echo
      echo "What landed:"
      while IFS=$'\t' read -r b pr _sha; do echo "- #$b, merged in PR #$pr"; done < "$TMP/merged.tsv"
      echo
      echo "What changes in this part's scope:"
      echo
      printf '%s\n' "$AMEND"
      echo
      echo "The plan for this part follows the updated scope. Nothing about the split or the order changed."
    } > "$BUILD/replan-comment.md"
    ledger_put amend "$AMEND"
    decide amend "scope amended after $MERGED_TXT merged" ;;
  escalate)
    if [ -z "$REST" ]; then decide keep "model error: escalate with no decision"; exit 0; fi
    printf '%s\n' "$REST" > "$BUILD/replan-decision.txt"
    # shellcheck source=bin/lib/ticket-hold-cmd.sh
    [ -r "$HARNESS/bin/lib/ticket-hold-cmd.sh" ] && . "$HARNESS/bin/lib/ticket-hold-cmd.sh"
    HRC=1; HOUT="ticket-hold-cmd.sh is not on this box"
    if command -v thc_run >/dev/null 2>&1; then
      HOUT=$(thc_run hold "$P" "$(jq -nc --arg t "$KEY" --arg r "replan escalate: $REST" '{ticket:$t,reason:$r,actor:"replan-check"}')" 2>/dev/null); HRC=$?
    fi
    if [ "$HRC" = 0 ]; then
      # The hold is on, so the beat's "parked" is true. Cache only now: an
      # escalation that parked nothing must not later read as answered.
      ledger_put escalate "$REST"
      BRC=0
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg a "replan-escalate-$P-$KEY" --arg t "$KEY needs a decision before it builds: $REST" '{kind:"fleet_alert",project:$p,akey:$a,line:$t}')" >/dev/null 2>&1 || BRC=$?
      printf '%s\n' "$BRC" > "$BUILD/replan-beat"
      [ "$BRC" = 0 ] || log "beat failed rc=$BRC — the hold label is on regardless"
      decide escalate "$REST"
    else
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --project "$P" "[$P/$KEY] REPLAN escalate could not park $KEY (hold rc=$HRC: $(printf '%s' "$HOUT" | oneline | cut -c1-160)). Decision needed before it builds: $REST"
      decide escalate "hold-failed $REST"
    fi ;;
esac
exit 0
