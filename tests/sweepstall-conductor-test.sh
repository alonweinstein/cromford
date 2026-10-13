#!/bin/bash
# tests/sweepstall-conductor-test.sh — pipeline-health's "sweep should have
# landed" detector watches the MERGE CONDUCTOR, not the retired merge sweep.
#
# THE INCIDENT (2026-09-26/27). bin/merge-sweep.sh has not run since ~09-23 (its
# hub cron line is gone; the conductor lands every PR). The detector still
# grepped logs/merge-sweep.log and exempted only the conductor state QUEUED, so
# every APPROVE + OPEN + CLEAN PR the conductor was deliberately holding
# (STACKED_WAIT, BLOCKED_HUMAN, a READY row held by a ticket HOLD, the merge
# flag, the lead fence, a MERGE_HELD queue, a dependency gate) paged "sweep
# never logged this PR — the silent-skip shape": 816 false alerts over 69 PRs.
#
# WHAT IT PINS
#   A. the detector block (extracted VERBATIM by its markers):
#      - reads state/merge-conductor/pr-state.tsv, never logs/merge-sweep.log;
#      - skips STACKED_WAIT and BLOCKED_HUMAN (and QUEUED, as before);
#      - skips READY when the conductor logged a hold for THIS head: a fresh
#        ready-why note (within SWEEPSTALL_HOLD_TICKS ticks), a MERGE_HELD line
#        or a PR-dependency-gate hold line;
#      - pages ONLY for "no conductor row" or "READY with no hold reason in the
#        last N ticks", and quotes the conductor's last reason line;
#      - N is a settings row (catalog/lanes.d/pipeline-health.json).
#   B. the conductor's READY arm: the three returns that used to be silent
#      (the ticket HOLD, the merge switch, the lead fence) each record one
#      reason (mc_ready_why): a note refreshed every tick and ONE log line per
#      (PR, head, reason).
#   C. the STUCK … READY page names that logged reason instead of the generic
#      "merge flag off, kill switch, budget spent, or gh refused".
#
# Run from anywhere: bash tests/sweepstall-conductor-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ════════════════════════════════════════════════════════════════════════════
# A. the detector
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/bin/lib" "$T/logs" "$T/state/merge-conductor" "$T/flags" "$T/fakebin" "$T/builds"
awk '/^# >>> sweep should have landed/{f=1;next} /^# <<< sweep should have landed/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/c1.sh"
[ -s "$T/c1.sh" ] && ok || bad "A0: the '>>> sweep should have landed' block did not extract"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/pr-terminal.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/o/r -q .id") exit 0 ;;
  *"repos/o/r/pulls/"[0-9]*)
    read -r s m h < "$T/prstate"
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -nc --arg s "$s" --arg m "$m" --arg h "$h" '{state: (if $s == "OPEN" then "open" else "closed" end),
      merged: false, merged_at: null, mergeable_state: ($m | ascii_downcase), user: {login: "operator"}, head: {ref: "b", sha: $h}}' ;;
  *"api rate_limit"*) now=$(date +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((now+3600))" "$((now+3600))" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"

drive() { # drive [env...] — one pass of the extracted block
  : > "$T/alerts.txt"; : > "$T/gh.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" GH_BUDGET_TTL_S=0; unset GH_TOKEN
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s)
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      job_verdict() { return 2; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$T/bin/lib/gh-budget.sh"
      . "$T/bin/lib/pr-terminal.sh"
      . "$0"' "$T/c1.sh" 2>"$T/err.txt" )
}

PR=https://github.com/o/r/pull/7; KEY='o/r#7'; HEAD=headsha7aaaa
REC="$T/builds/pool-ts-TK-7-202609260001"; mkdir -p "$REC"
echo "PR_CREATED $PR" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "OPEN CLEAN $HEAD" > "$T/prstate"
ROWS="$T/state/merge-conductor/pr-state.tsv"
NOTE="$T/state/merge-conductor/ready-why/o_r_7"
CLOG="$T/logs/merge-conductor.log"
row() { # row <state> [reason] — the conductor's row for PR 7 (key state since head reviewed alerted reason url)
  printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$KEY" "$1" "$(( $(date +%s) - 7200 ))" "$HEAD" "$HEAD" "${2:--}" "$PR" > "$ROWS"
}
note() { # note <age-s> <head> <kind> <text>
  mkdir -p "${NOTE%/*}"; printf '%s\t%s\t%s\t%s\n' "$(( $(date +%s) - $1 ))" "$2" "$3" "$4" > "$NOTE"
}
stale_clean() { # the PR has sat CLEAN on this head for 40 minutes
  echo "$PR $HEAD $(( $(date +%s) - 2400 ))" > "$T/state/sweep-clean-seen.txt"
}
reset() { : > "$ROWS"; rm -f "$NOTE"; : > "$CLOG"; : > "$T/logs/merge-sweep.log"; stale_clean; }

# A1. no conductor row at all: THE page, and it says so — never "the sweep"
reset
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -q "no conductor row for this PR" "$T/alerts.txt" \
  && ok || bad "A1: a PR with no conductor row must page and say so: $(cat "$T/alerts.txt") err=$(head -c 300 "$T/err.txt")"
grep -q "merge-sweep\|sweep never logged" "$T/alerts.txt" \
  && bad "A1: the page must not blame the retired merge sweep: $(cat "$T/alerts.txt")" || ok

# A2. the retired sweep's log is NOT read: a line there is neither quoted nor an exemption
reset; echo "2026-09-26 10:00:00Z $PR skipped: mergeState=UNSTABLE" > "$T/logs/merge-sweep.log"
drive
grep -q "skipped: mergeState=UNSTABLE" "$T/alerts.txt" \
  && bad "A2: logs/merge-sweep.log must not be quoted any more: $(cat "$T/alerts.txt")" || ok

# A3/A4. STACKED_WAIT and BLOCKED_HUMAN are the conductor's to hold (and to page on by its own TTL)
for st in STACKED_WAIT BLOCKED_HUMAN QUEUED; do
  reset; row "$st" "waiting on the parent"
  drive
  [ ! -s "$T/alerts.txt" ] && ok || bad "A3: a $st row must not page: $(cat "$T/alerts.txt")"
done
# … and so is every other state the conductor owns (WAIT_CI, NEEDS_REBASE, …)
for st in WAIT_CI HEAD_MOVED; do
  reset; row "$st" "checks pending"
  drive
  [ ! -s "$T/alerts.txt" ] && ok || bad "A4: a $st row is the conductor's (its TTL pages): $(cat "$T/alerts.txt")"
done

# A5. READY + a fresh hold note for THIS head: held on purpose, no page
reset; row READY; note 60 "$HEAD" ticket-hold "held by a HOLD on its ticket or thread"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "A5: a READY row with a fresh hold note must not page: $(cat "$T/alerts.txt")"

# A6. READY + a note for an OLD head: this head has no reason, it pages and quotes the conductor
reset; row READY; note 60 oldhead00000 merges-off "the conductor is not merging"
echo "2026-09-26 11:00:00Z $KEY enqueued in the none merge queue at ${HEAD:0:8}" >> "$CLOG"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -q "READY" "$T/alerts.txt" \
  && grep -q "enqueued in the none merge queue" "$T/alerts.txt" \
  && ok || bad "A6: a READY row whose note is for another head must page with the conductor's last line: $(cat "$T/alerts.txt")"

# A7. READY + a note older than N ticks: the conductor stopped saying why — page, quoting that last reason
reset; row READY; note 3600 "$HEAD" merges-off "the conductor is not merging (mode=observe)"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -q "the conductor is not merging (mode=observe)" "$T/alerts.txt" \
  && ok || bad "A7: a stale note (>N ticks) must page and quote the last reason: $(cat "$T/alerts.txt")"

# A8. N IS A SETTINGS ROW: a note 20m old is fresh at N=6 and stale at the default N=3
reset; row READY; note 1200 "$HEAD" merges-off "the conductor is not merging"
drive SWEEPSTALL_HOLD_TICKS=6
[ ! -s "$T/alerts.txt" ] && ok || bad "A8: at SWEEPSTALL_HOLD_TICKS=6 a 20m-old note is fresh: $(cat "$T/alerts.txt")"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "A8: at the default N a 20m-old note is stale and pages: $(cat "$T/alerts.txt")"
jq -e '.knobs[] | select(.env == "SWEEPSTALL_HOLD_TICKS") | .default == 3 and .type == "int"' \
  "$DIR/catalog/lanes.d/pipeline-health.json" >/dev/null && ok \
  || bad "A8: SWEEPSTALL_HOLD_TICKS must be a registered knob on the pipeline-health lane (default 3)"

# A9. READY + a MERGE_HELD line for THIS head in the conductor log: no page
reset; row READY
echo "2026-09-26 11:00:00Z $KEY MERGE_HELD: the mergify queue has acknowledged nothing at ${HEAD:0:8} for 3 held tick(s)" >> "$CLOG"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "A9: a MERGE_HELD line for this head must exempt the row: $(cat "$T/alerts.txt")"
# … but one about ANOTHER head is not a hold on this one
reset; row READY
echo "2026-09-26 11:00:00Z $KEY MERGE_HELD: the mergify queue has acknowledged nothing at oldhead0 for 3 held tick(s)" >> "$CLOG"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "A9: a MERGE_HELD line for another head is no exemption: $(cat "$T/alerts.txt")"

# A10. READY + a dependency-gate hold for THIS head: no page
reset; row READY
echo "2026-09-26 11:00:00Z $KEY READY and HELD by the PR-dependency gate on ${HEAD:0:8}: it declares #5 that is still open" >> "$CLOG"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "A10: a dependency-gate hold for this head must exempt the row: $(cat "$T/alerts.txt")"

# A11. READY and the conductor never said anything: the page says exactly that
reset; row READY
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -q "logged no reason" "$T/alerts.txt" \
  && ok || bad "A11: a READY row with nothing logged must page and say no reason was logged: $(cat "$T/alerts.txt")"

# A12. another PR's lines never count: o/r#70 is not o/r#7
reset; row READY
echo "2026-09-26 11:00:00Z o/r#70 MERGE_HELD: held at ${HEAD:0:8}" >> "$CLOG"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "A12: o/r#70's hold must not exempt o/r#7: $(cat "$T/alerts.txt")"

# ════════════════════════════════════════════════════════════════════════════
# B/C. the conductor lib: mc_ready_why and the STUCK READY page
# ════════════════════════════════════════════════════════════════════════════
export HARNESS="$T/h" MC_REHYDRATE=0
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" "$T/h/builds"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111; H2=bbbbbbbb2222; K='example-org/x#9'; U=https://github.com/example-org/x/pull/9
LOGF="$T/h/logs/merge-conductor.log"; : > "$LOGF"
lines() { grep -cF "$K READY not merged" "$LOGF" 2>/dev/null; }

if ! command -v mc_ready_why >/dev/null 2>&1; then
  bad "B0: mc_ready_why is not defined by the conductor lib"
else
  mc_ready_why "$K" "$H1" merges-off "the conductor is not merging this tick (mode=observe)"
  WF="$MC_STATE_DIR/ready-why/$(mc_handoff_id "$K")"
  [ "$(lines)" = 1 ] && ok || bad "B1: one reason line on the first hold (got $(lines)): $(cat "$LOGF")"
  grep -qF "$K READY not merged on ${H1:0:8}: the conductor is not merging this tick (mode=observe)" "$LOGF" \
    && ok || bad "B1: the line names the PR, the head and the reason: $(cat "$LOGF")"
  IFS=$'\t' read -r wts wh wk wt < "$WF" 2>/dev/null
  [ "${wh:-}" = "$H1" ] && [ "${wk:-}" = merges-off ] && [ "${wt:-}" = "the conductor is not merging this tick (mode=observe)" ] \
    && [ $(( $(date +%s) - ${wts:-0} )) -lt 60 ] && ok || bad "B1: the note carries (epoch, head, kind, text): $(cat "$WF" 2>/dev/null)"
  # same (PR, head, reason) on the next tick: no second line, but the note's stamp is refreshed
  printf '%s\t%s\t%s\t%s\n' 1000 "$H1" merges-off old > "$WF"
  mc_ready_why "$K" "$H1" merges-off "the conductor is not merging this tick (mode=observe)"
  [ "$(lines)" = 1 ] && ok || bad "B2: deduped per (PR, head, reason) — still one line (got $(lines))"
  IFS=$'\t' read -r wts _ _ _ < "$WF"
  [ "${wts:-0}" -gt 1000 ] && ok || bad "B2: the note is refreshed every tick (stamp $wts)"
  # a new head is a new line
  mc_ready_why "$K" "$H2" merges-off "the conductor is not merging this tick (mode=observe)"
  [ "$(lines)" = 2 ] && ok || bad "B3: a new head logs its own line (got $(lines))"
  # B3b. no attempts row: a `<kind> <key> <head>` row moves read_memo_fp for the
  #      head and would buy a PR re-read on the next tick (conductor-read-memo)
  grep -q "$K" "$MC_ATTEMPTS" 2>/dev/null && bad "B3b: mc_ready_why must not write the attempts ledger: $(grep "$K" "$MC_ATTEMPTS")" || ok
  # the reader answers for the head it is asked about
  [ "$(mc_ready_why_last "$K" "$H2")" = "the conductor is not merging this tick (mode=observe)" ] \
    && ok || bad "B4: mc_ready_why_last reads the note for its head (got '$(mc_ready_why_last "$K" "$H2")')"
  [ -z "$(mc_ready_why_last "$K" "$H1")" ] && ok || bad "B4: a note for another head is not this head's reason"
  # B6. `logged`: the caller logs this hold's own reason line (Lane D's
  #     merges-off line), so mc_ready_why refreshes the note and adds no line
  K3='example-org/x#13'; n0=$(grep -cF "$K3" "$LOGF")
  mc_ready_why "$K3" "$H1" merges-off "merges are off this tick (mode observe)" logged
  WF3="$MC_STATE_DIR/ready-why/$(mc_handoff_id "$K3")"
  [ "$(grep -cF "$K3" "$LOGF")" = "$n0" ] && ok || bad "B6: 'logged' must add no log line: $(grep -F "$K3" "$LOGF")"
  [ "$(mc_ready_why_last "$K3" "$H1")" = "merges are off this tick (mode observe)" ] \
    && ok || bad "B6: 'logged' still writes the note (got '$(mc_ready_why_last "$K3" "$H1")' / $(cat "$WF3" 2>/dev/null))"
fi

# B5. the READY arm: each of the three once-silent returns records its reason
ARM=$(awk '/^    READY\)$/{f=1} f{print} f&&/^      fi ;;$/{exit}' "$DIR/bin/merge-conductor.sh")
[ -n "$ARM" ] && ok || bad "B5: the READY arm did not extract"
SEG=$(grep -A1 -E 'to_lane_hold "\$P" "\$SLUG" "\$NUM"' <<<"$ARM"); grep -q 'mc_ready_why "\$KEY" "\$HEAD" ticket-hold' <<<"$SEG" \
  && ok || bad "B5: the ticket-HOLD return must record a reason: $(grep -E 'to_lane_hold' <<<"$ARM")"
SEG=$(grep -A1 -E '^\s*if \[ "\$MERGES" != 1 \]; then' <<<"$ARM"); grep -q 'mc_ready_why "\$KEY" "\$HEAD" merges-off' <<<"$SEG" \
  && ok || bad "B5: the merge-switch return must record a reason: $(grep -A2 -E 'MERGES" [!=]*= 1' <<<"$ARM")"
SEG=$(grep -A6 -E 'MC_LEAD_RC=\$\?' <<<"$ARM"); grep -q 'mc_ready_why "\$KEY" "\$HEAD" lead-' <<<"$SEG" \
  && ok || bad "B5: the lead-fence return must record a reason: $(grep -A6 -E 'MC_LEAD_RC=' <<<"$ARM")"
# no bare silent return is left behind on those three lines
grep -qE 'to_lane_hold "\$P" "\$SLUG" "\$NUM" && return 0$' <<<"$ARM" \
  && bad "B5: the ticket-HOLD return is still silent" || ok
grep -qE '^\s*\[ "\$MERGES" = 1 \] \|\| return 0$' <<<"$ARM" \
  && bad "B5: the merge-switch return is still silent" || ok
grep -qE '^\s*\[ "\$MC_LEAD_RC" = 1 \] \|\| return 0$' <<<"$ARM" \
  && bad "B5: the lead-fence return is still silent" || ok

# C. the STUCK READY page names the logged reason, never the generic list
K2='example-org/x#11'; U2=https://github.com/example-org/x/pull/11
if command -v mc_ready_why >/dev/null 2>&1; then
  mc_ready_why "$K2" "$H1" ticket-hold "held by a HOLD on its ticket or thread"
fi
W=$(mc_stuck_waiting_on READY - 'example-org/x#11' "$H1")
grep -qF "held by a HOLD on its ticket or thread" <<<"$W" && ok \
  || bad "C1: the READY waiting-on text must name the logged reason (got '$W')"
grep -qF "merge flag off, kill switch, budget spent, or gh refused" <<<"$W" \
  && bad "C1: the generic list must be gone (got '$W')" || ok
W=$(mc_stuck_waiting_on READY - 'example-org/x#12' "$H1")
grep -qF "merge flag off, kill switch, budget spent, or gh refused" <<<"$W" \
  && bad "C2: no reason logged is said as such, not guessed (got '$W')" || ok
grep -qF "logged no reason" <<<"$W" && ok || bad "C2: a READY row with no logged reason says so (got '$W')"
# the page itself (merge mode, so it is sent, not held)
: > "$T/h/logs/ALERTS.log"
OLD=$(( $(date -u +%s) - 7200 ))
MC_MODE=merge mc_stuck_check 'example-org/x#11' READY "$OLD" "$H1" "$U2" - "verdict=APPROVE" >/dev/null 2>&1
grep -F 'example-org/x#11' "$T/h/logs/ALERTS.log" | grep -F "held by a HOLD on its ticket or thread" >/dev/null && ok \
  || bad "C3: the STUCK READY alert must carry the logged reason: $(cat "$T/h/logs/ALERTS.log")"
# the other states' sentences are unchanged
[ "$(mc_stuck_waiting_on WAIT_CI checks)" = 'a required check to report on this head (checks)' ] && ok \
  || bad "C4: WAIT_CI text unchanged (got '$(mc_stuck_waiting_on WAIT_CI checks)')"

echo "sweepstall-conductor: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
