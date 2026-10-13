#!/bin/bash
# tests/tier-wording-code.bh-4572-test.sh — BH-4581 (BH-4572 scope 1, the
# wording half): the build and sweep code states tier 2 as a RECORDED RISK
# CLASS, never as a wait for a person.
#
# Tier 2 no longer waits on anyone: an approved tier-2 PR lands through the
# merge queue on the same gates as tier 1 (BH-4579's tier_gate_mode row is the
# only thing that can hold it). The PR body, the demotion notes and the sweep's
# close-out comment still said "merges via the harness merge sweep after
# review", "demoted to tier-2" and "tier-2 sweep" — copy that tells a client and
# a reviewer a person is about to look, which is no longer true.
#
# The wording changed and NOTHING ELSE did. So this suite drives the real
# blocks (extracted verbatim by their markers from the assembled run-build):
#   T5  the kind demoter still demotes to TIER=2, and the verdict artifact
#       still records "tier":"2" and the reason, in the new words;
#   T7  MERGE_NOTE_FOR renders the new tier-2 sentence, and tier 1 / STACKED
#       are unchanged;
# and pins the ticket's grep definitions (T6, T8, T9) plus the sibling
# boundary (T10). No network, no model call, no ledger: the artifact sink is a
# stub that writes to disk.
# Run from anywhere: tests/tier-wording-code.bh-4572-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

NEW_T2='Tier 2 — risk class recorded; lands through the merge queue on the same gates as tier 1'

# --- T0: every touched script still parses.
for f in bin/lib/rb/pr.sh bin/lib/rb/result.sh bin/merge-sweep.sh; do
  bash -n "$DIR/$f" 2>/dev/null && ok || bad "T0: bash -n fails on $f"
done

# --- T5: a demoted build is still TIER 2 and the artifact still says so.
awk '/^# >>> kind demoter/{f=1;next} /^# <<< kind demoter/{exit} f' "$RB_ALL" > "$T/demote.sh"
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/demote.sh" ]  && ok || bad "T5: could not extract the kind demoter — markers missing?"
[ -s "$T/verdict.sh" ] && ok || bad "T5: could not extract the verdict-artifact block — markers missing?"
B="$T/b"; mkdir -p "$B" "$T/h/logs"
{ echo "KIND: bug"; echo "KIND_REPRO: missing"; echo "KIND_REPRO_MISSING: the whole '## Reproduction' section"; } > "$B/kind.txt"
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$B/review.md"
OUT=$( env HARNESS="$T/h" BUILD="$B" PROJECT=p KEY=K TIER=1 QA_NOTE="" KIND_GATE_ENFORCE=1 \
           ALERTS="$T/h/logs/ALERTS.log" PR_URL=https://github.com/x/y/pull/1 JOB_ID=job-1 \
           HEADBOUND_SHA=abc REPAIRS=0 REPAIR_ROUNDS=- SINK="$T/artifact.json" \
       bash -c 'set -uo pipefail; STAMP() { echo TS; }
                job_artifact_put() { printf "%s" "$3" > "$SINK"; }
                . "$0"; . "$1"; printf "TIER=%s\n" "$TIER"' "$T/demote.sh" "$T/verdict.sh" 2>/dev/null )
grep -qx 'TIER=2' <<<"$OUT" && ok || bad "T5: the demoter must still end at TIER=2 (got: $OUT)"
A=$(cat "$T/artifact.json" 2>/dev/null)
[ "$(jq -r .tier <<<"$A" 2>/dev/null)" = 2 ] && ok || bad "T5: the verdict artifact must record tier 2 (artifact: $A)"
NOTE=$(jq -r .note <<<"$A" 2>/dev/null)
grep -qF 'KIND: bug' <<<"$NOTE" && ok || bad "T5: the demotion reason must still be recorded (note: $NOTE)"
grep -qF 'recorded tier-2 (risk signal)' <<<"$NOTE" \
  && ok || bad "T5: the note must state the tier as a recorded risk signal (note: $NOTE)"
grep -qF 'demoted to tier-2' <<<"$NOTE" && bad "T5: the note still says 'demoted to tier-2' (note: $NOTE)" || ok
grep -qF 'recorded tier-2 (risk signal)' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "T5: pipeline.log must carry the same wording ($(cat "$B/pipeline.log" 2>/dev/null))"

# --- T6: no copy in the build lib, the sweep or the console implies a person.
G=$(cd "$DIR" && git grep -nE 'awaiting the operator|needs the operator|tier-2 waits|demoted to tier-2' -- bin/lib/rb bin/merge-sweep.sh console-ui/src); GRC=$?
[ "$GRC" = 1 ] && [ -z "$G" ] && ok || bad "T6: human-implying tier copy is still present (rc $GRC):
$G"

# --- T7: the PR-body tier sentence, rendered by the real function.
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$RB_ALL" > "$T/note.sh"
[ -s "$T/note.sh" ] && ok || bad "T7: could not extract the merge note fn — markers missing?"
render() { ( env TIER="$1" "${@:2}" bash -c 'set -uo pipefail; . "$0"; MERGE_NOTE_FOR "$TIER"' "$T/note.sh" 2>/dev/null ); }
N=$(render 2)
grep -qF "$NEW_T2" <<<"$N" && ok || bad "T7: the tier-2 sentence must read '$NEW_T2' (got: $N)"
grep -qF 'merge sweep after review' <<<"$N" && bad "T7: the tier-2 sentence still promises a sweep after review (got: $N)" || ok
N=$(render 1)
grep -qF 'Tier 1 (low-risk class) — auto-merging' <<<"$N" && ok || bad "T7b: the tier-1 sentence changed (got: $N)"
N=$(render 2 STACK_ON=x)
grep -qF 'STACKED' <<<"$N" && ok || bad "T7c: the STACKED sentence changed (got: $N)"

# --- T8: no `tier-2` GitHub label applier anywhere in bin/.
G=$(cd "$DIR" && git grep -nE "labels?.*tier-2" -- bin/); GRC=$?
[ "$GRC" = 1 ] && [ -z "$G" ] && ok || bad "T8: a tier-2 label applier exists in bin/ (rc $GRC):
$G"

# --- T9: the sweep's close-out says reviewed-merge sweep; the ledger key stays.
MS="$DIR/bin/merge-sweep.sh"
[ "$(grep -c 'tier-2 sweep' "$MS")" = 0 ] && ok || bad "T9: merge-sweep.sh still says 'tier-2 sweep': $(grep -n 'tier-2 sweep' "$MS")"
[ "$(grep -c 'reviewed-merge sweep' "$MS")" -ge 4 ] && ok || bad "T9: merge-sweep.sh close-out must say 'reviewed-merge sweep' (count $(grep -c 'reviewed-merge sweep' "$MS"))"
grep -q 'stage:"tier2_sweep_merged"' "$MS" && ok || bad "T9b: the tier2_sweep_merged stage key must be kept for ledger continuity"

# --- T10: the external-enqueue sibling's files are not in this slice. The
#     branch is stacked on the BH-4579 contract, which DOES own those files, so
#     the diff is this ticket's own commits (subject names BH-4581) plus the
#     uncommitted tree — not everything since origin/main.
if (cd "$DIR" && git rev-parse -q --verify origin/main >/dev/null 2>&1); then
  # pr-scoped: ok negative check: an empty range passes, it never requires a commit
  CH=$(cd "$DIR" && { git log --format= --name-only --grep='BH-4581' origin/main..HEAD
                      git diff --name-only HEAD; } 2>/dev/null)
  for f in bin/review-prs.sh bin/lib/autoenqueue.sh bin/merge-conductor.sh; do
    grep -qxF "$f" <<<"$CH" && bad "T10: $f belongs to the external-enqueue sibling and must not change here" || ok
  done
else
  ok
fi

echo "tier-wording-code: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
