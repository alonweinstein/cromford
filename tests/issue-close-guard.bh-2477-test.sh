#!/bin/bash
# tests/issue-close-guard.bh-2477-test.sh — BH-2477: the post-merge close-out
# must not close an issue the merge only SLICED.
#
# THE INCIDENT. #2320 was a master ticket split into C0..C6. PR #2390 built C0,
# said `Refs #2320` (not `Closes`), its plan said "The build for THIS ticket is
# C0", and C1..C6 (#2407..#2412) were filed and open. The merge conductor still
# posted "Closing this issue." and closed #2320, because the close-out took the
# issue number from the build KEY and never asked whether the merge delivered it.
#
# WHAT THIS PINS. bin/lib/issue-state-lib.sh:issue_close_guard answers ONE word
# from three checks (the plan's slice marker, the PR body's closing keyword, the
# issue's open children), and both close-out helpers obey it:
#   issue_close_shipped (batch train, tier-1 in-build merge)
#   mc_close_shipped    (merge conductor, tier-2 sweep and its owed retry)
# Everything is asserted on the REST argv that reached the stub `gh` and on the
# word printed, never on the source text.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/issue-close-guard.bh-2477-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/issue-state-lib.sh" ] || { echo "FAIL: bin/lib/issue-state-lib.sh missing"; exit 1; }

# ── scratch harness: the real libs, a routed REST stub ──────────────────────
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
cp "$DIR/bin/lib/issue-state-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
# Every comment body the stub receives, captured before gh-rest.sh deletes it.
ghfx_extra <<'SH'
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init
command -v issue_close_guard >/dev/null 2>&1 && ok || bad "issue_close_guard is not defined after sourcing the lib"

S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/2390
REC="$T/h/builds/pool-proj-BH-2320-202609251756"
mkdir -p "$REC"
# The real #2390 body line and the real #2320 plan marker line (D4).
REFS_BODY=$'## Summary\nRefs #2320\n\nThis builds C0. The PR body says `Refs #2320` and not `Closes`: C1 to C6 follow.'
CLOSES_BODY=$'## Summary\nCloses #2320\n\nharness build'
MARKER_LINE='**The build for THIS ticket is C0.** C1 to C6 are filed as children by the decomposer.'

# xref <num> <state> <body> [pr] — one `cross-referenced` timeline event in the
# shape GitHub answers: source.issue carries a `pull_request` key only for a PR.
xref() {
  jq -nc --argjson n "$1" --arg st "$2" --arg b "$3" --arg pr "${4:-}" \
    '{event:"cross-referenced",source:{type:"issue",issue:(
       {number:$n,state:$st,body:$b} + (if $pr=="" then {} else {pull_request:{url:"x"}} end))}}'
}
reset() {
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"
  rm -f "$REC/plan.md" "$REC/issue-commented"
  unset ISSUE_CLOSE_GUARD_PAGES
}
pr_body() { ghfx_route GET "repos/$S/pulls/2390" 200 "$(jq -nc --arg b "$1" '{number:2390,state:"closed",merged_at:"2026-09-25T17:56:00Z",body:$b}')"; }
timeline() { ghfx_route GET "repos/$S/issues/2320/timeline*" 200 "$1"; }
writes() { # the close path: comment POST, PATCH, re-read, label strip
  ghfx_route POST   "repos/$S/issues/2320/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/2320" 200 '{"state":"closed"}'
  ghfx_route GET    "repos/$S/issues/2320" 200 '{"state":"closed","body":"master","labels":[{"name":"ai-build"}]}'
  ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
}
n_patch()  { grep -c -- "-X PATCH repos/$S/issues/2320" "$T/gh-argv.log"; }
n_post()   { grep -c -- "-X POST repos/$S/issues/2320/comments" "$T/gh-argv.log"; }
n_delete() { grep -c -- "-X DELETE repos/$S/issues/2320/labels" "$T/gh-argv.log"; }
guard() { issue_close_guard "$S" 2320 "$PRURL" "$@" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# G. issue_close_guard — the one word
# ════════════════════════════════════════════════════════════════════════════
# G1 the #2390 body: Refs, not Closes
reset; pr_body "$REFS_BODY"; timeline '[]'
W=$(guard "$REC"); [ "$W" = slice:no-keyword ] && ok || bad "G1: 'Refs #2320' must be slice:no-keyword (got '$W')"

# G2 every closing form GitHub honours closes
for b in 'Closes #2320' 'fixes: #2320' 'Resolved https://github.com/example-org/proj/issues/2320' \
         'This PR closes example-org/proj#2320.' 'FIX #2320'; do
  reset; pr_body "$b"; timeline '[]'
  W=$(guard "$REC"); [ "$W" = close ] && ok || bad "G2: body '$b' must be close (got '$W')"
done

# G3 adversarial negatives for the keyword
for b in 'Closes #23200' 'Closes #232' 'Closes other/repo#2320' 'closes' '' \
         'Refs #2320' 'Closes the gap on #2320' 'Resolved https://github.com/example-org/projX/issues/2320' \
         'This says `Refs #2320` and not `Closes`: #2320 stays open'; do
  reset; pr_body "$b"; timeline '[]'
  W=$(guard "$REC"); [ "$W" = slice:no-keyword ] && ok || bad "G3: body '$b' must be slice:no-keyword (got '$W')"
done
# a null body (GitHub answers null for an empty description) is no keyword, not unreadable
reset; ghfx_route GET "repos/$S/pulls/2390" 200 '{"number":2390,"body":null}'; timeline '[]'
W=$(guard "$REC"); [ "$W" = slice:no-keyword ] && ok || bad "G3: a null body must be slice:no-keyword (got '$W')"

# G4 an unreadable PR is unknown, never close
reset; ghfx_route GET "repos/$S/pulls/2390" 403 '{"message":"API rate limit exceeded"}'; timeline '[]'
W=$(guard "$REC"); case "$W" in unknown:*) ok ;; *) bad "G4: a 403 PR read must be unknown:* (got '$W')" ;; esac
reset; ghfx_route GET "repos/$S/pulls/2390" 200 'not json'; timeline '[]'
W=$(guard "$REC"); case "$W" in unknown:*) ok ;; *) bad "G4: an unparseable PR read must be unknown:* (got '$W')" ;; esac
reset
W=$(issue_close_guard "$S" 2320 "not-a-pr-url" "$REC" 2>/dev/null); case "$W" in unknown:*) ok ;; *) bad "G4: an unparseable PR url must be unknown:* (got '$W')" ;; esac

# G5 the plan marker makes it a slice even when the PR says Closes
reset; pr_body "$CLOSES_BODY"; timeline '[]'
printf '# BH-2320\n\nSome design.\n\n%s\n\n## Tasks (C0)\n' "$MARKER_LINE" > "$REC/plan.md"
W=$(guard "$REC"); [ "$W" = slice:plan ] && ok || bad "G5: the plan marker must be slice:plan (got '$W')"
[ ! -s "$T/gh-argv.log" ] && ok || bad "G5: the plan check is local and must stop before any read ($(cat "$T/gh-argv.log"))"
reset; pr_body "$CLOSES_BODY"; timeline '[]'
printf 'The build for THIS ticket is C3.\n' > "$REC/plan.md"
W=$(guard "$REC"); [ "$W" = slice:plan ] && ok || bad "G5: an unbolded marker must be slice:plan (got '$W')"

# G6 plans that only TALK about slices are not a slice
reset; pr_body "$CLOSES_BODY"; timeline '[]'
printf '| C0 | the first slice |\n| C1 | next |\nA plan quoting `The build for THIS ticket is C0` mid-line.\nWe note: The build for THIS ticket is C0 in prose.\n' > "$REC/plan.md"
W=$(guard "$REC"); [ "$W" = close ] && ok || bad "G6: a plan that only mentions the marker mid-line must not be a slice (got '$W')"

# G7 no record: the plan check is skipped, the rest still runs
reset; pr_body "$CLOSES_BODY"; timeline '[]'
W=$(guard ""); [ "$W" = close ] && ok || bad "G7: no record dir must skip the plan check (got '$W')"
reset; pr_body "$REFS_BODY"; timeline '[]'
W=$(guard ""); [ "$W" = slice:no-keyword ] && ok || bad "G7: no record dir must still read the PR (got '$W')"

# G8 an open hand-filed child (the #2407 shape)
reset; pr_body "$CLOSES_BODY"
timeline "[$(xref 2407 open $'Child **C1** of #2320. Order: 1 of 6.'),$(xref 2477 open 'Refs #2320.')]"
W=$(guard "$REC"); [ "$W" = 'slice:open-children:#2407' ] && ok || bad "G8: an open Child **C1** of #2320 must be slice:open-children:#2407 (got '$W')"

# G9 an open decomposer child (the Part of shape), two of them, deduplicated
reset; pr_body "$CLOSES_BODY"
timeline "[$(xref 2408 open $'Scope.\nPart of #2320\nOrder: 2 of 6'),$(xref 2409 open 'Part of #2320'),$(xref 2408 open $'Scope.\nPart of #2320')]"
W=$(guard "$REC"); [ "$W" = 'slice:open-children:#2408,#2409' ] && ok || bad "G9: open Part of #2320 children must be listed once each (got '$W')"

# G10 negatives for children: a mention, a closed child, a PR, another number, the issue itself
reset; pr_body "$CLOSES_BODY"
timeline "[$(xref 2450 open 'Refs #2320'),$(xref 2410 closed 'Part of #2320'),$(xref 2390 open 'Part of #2320' pr),$(xref 2411 open 'Part of #23200'),$(xref 2320 open 'Part of #2320'),{\"event\":\"labeled\"}]"
W=$(guard "$REC"); [ "$W" = close ] && ok || bad "G10: mentions, closed children, PRs and #23200 are not open children (got '$W')"

# G11 the timeline cap is an unknown, never "no children"
reset; pr_body "$CLOSES_BODY"
FULL=$(jq -nc '[range(100)] | map({event:"commented"})')
ghfx_route GET "repos/$S/issues/2320/timeline?per_page=100&page=1" 200 "$FULL"
ghfx_route GET "repos/$S/issues/2320/timeline?per_page=100&page=2" 200 "$FULL"
ghfx_route GET "repos/$S/issues/2320/timeline?per_page=100&page=3" 200 '[]'
W=$(ISSUE_CLOSE_GUARD_PAGES=2 guard "$REC"); [ "$W" = unknown:timeline-capped ] && ok || bad "G11: a timeline still full at the cap must be unknown:timeline-capped (got '$W')"
grep -q 'page=3' "$T/gh-argv.log" && bad "G11: the cap must bound the loop (page 3 was read)" || ok
# …and the knob is read from env/global.env like the lib's other knobs
reset; pr_body "$CLOSES_BODY"
ghfx_route GET "repos/$S/issues/2320/timeline?per_page=100&page=1" 200 "$FULL"
ghfx_route GET "repos/$S/issues/2320/timeline?per_page=100&page=2" 200 "[$(xref 2412 open 'Child **C6** of #2320')]"
echo 'ISSUE_CLOSE_GUARD_PAGES=1' > "$T/h/env/global.env"
W=$(guard "$REC" "$T/h"); [ "$W" = unknown:timeline-capped ] && ok || bad "G11: ISSUE_CLOSE_GUARD_PAGES in env/global.env must bound the read (got '$W')"
: > "$T/h/env/global.env"
W=$(guard "$REC" "$T/h"); [ "$W" = 'slice:open-children:#2412' ] && ok || bad "G11: a child on page 2 must be found under the default cap (got '$W')"

# G12 an unreadable timeline is unknown
reset; pr_body "$CLOSES_BODY"; ghfx_route GET "repos/$S/issues/2320/timeline*" 403 '{"message":"nope"}'
W=$(guard "$REC"); case "$W" in unknown:*) ok ;; *) bad "G12: a 403 timeline must be unknown:* (got '$W')" ;; esac
reset; pr_body "$CLOSES_BODY"; timeline '{"message":"not a list"}'
W=$(guard "$REC"); case "$W" in unknown:*) ok ;; *) bad "G12: a non-array timeline page must be unknown:* (got '$W')" ;; esac

# ════════════════════════════════════════════════════════════════════════════
# S. issue_close_shipped with a PR url — batch train and tier-1 path
# ════════════════════════════════════════════════════════════════════════════
KID="[$(xref 2407 open $'Scope.\nPart of #2320')]"  # TEST-CHANGE BH-4662: the open child the S/M slice cases now need
ics() { issue_close_shipped "$S" 2320 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }

# S1 Refs: no close, one slice comment, then the label comes off
# TEST-CHANGE BH-2508: a slice now strips ai-build from the master; the word gains +<strip word>.
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped ] && ok || bad "S1: a Refs PR must answer kept-slice:no-keyword+stripped rc 0 (rc=$RC w=$W)"  # TEST-CHANGE BH-2508
[ "$(n_patch)" = 0 ] && ok || bad "S1: a Refs PR must never PATCH the issue ($(n_patch) PATCHes)"
[ "$(n_post)" = 1 ] && ok || bad "S1: exactly one slice comment (got $(n_post))"
[ "$(n_delete)" = 1 ] && ok || bad "S1: a slice must take the ai-build label off the master once (got $(n_delete))"  # TEST-CHANGE BH-2508
head -1 "$T/posted.txt" | grep -q '^Slice delivered: #2390' && ok || bad "S1: the comment must start 'Slice delivered: #2390' (got $(head -1 "$T/posted.txt"))"
grep -q 'Closing this issue' "$T/posted.txt" && bad "S1: a slice must never say 'Closing this issue'" || ok
grep -q '—' "$T/posted.txt" && bad "S1: no em dashes in a client-visible comment" || ok

# S2 plan slice with a Closes body
reset; pr_body "$CLOSES_BODY"; timeline "$KID"; writes  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
printf '%s\n' "$MARKER_LINE" > "$REC/plan.md"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:plan+stripped ] && ok || bad "S2: a plan slice must answer kept-slice:plan+stripped rc 0 (rc=$RC w=$W)"  # TEST-CHANGE BH-2508
[ "$(n_patch)" = 0 ] && ok || bad "S2: a plan slice must never PATCH the issue"
[ "$(n_post)" = 1 ] && head -1 "$T/posted.txt" | grep -q '^Slice delivered: #2390' && ok || bad "S2: one 'Slice delivered' comment (posts=$(n_post))"

# S3 an open child, named in the comment
reset; pr_body "$CLOSES_BODY"; timeline "[$(xref 2407 open 'Child **C1** of #2320')]"; writes
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = 'kept-slice:open-children:#2407+stripped' ] && ok || bad "S3: an open child must answer kept-slice:open-children:#2407+stripped (rc=$RC w=$W)"  # TEST-CHANGE BH-2508
[ "$(n_patch)" = 0 ] && ok || bad "S3: an open child must never PATCH the issue"
grep -q '#2407' "$T/posted.txt" && ok || bad "S3: the comment must name #2407 ($(cat "$T/posted.txt"))"

# S4 Closes, no children, no marker: today's close, byte for byte
reset; pr_body "$CLOSES_BODY"; timeline '[]'; writes
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = stripped ] && ok || bad "S4: a Closes PR must close and strip (rc=$RC w=$W)"
[ "$(n_patch)" = 1 ] && ok || bad "S4: a Closes PR must PATCH the issue once (got $(n_patch))"
head -1 "$T/posted.txt" | grep -q '^Merged in' && ok || bad "S4: the close comment is the caller's own body"

# S5 unknown: zero writes, rc 1
reset; ghfx_route GET "repos/$S/pulls/2390" 403 '{"message":"nope"}'; timeline '[]'; writes
W=$(ics); RC=$?
[ "$RC" = 1 ] && ok || bad "S5: an unknown must be rc 1 (rc=$RC w=$W)"
case "$W" in close-deferred:*) ok ;; *) bad "S5: an unknown must print close-deferred:* (got '$W')" ;; esac
[ "$(n_patch)" = 0 ] && [ "$(n_post)" = 0 ] && ok || bad "S5: an unknown writes nothing (patch=$(n_patch) post=$(n_post))"

# S6 no PR url: today's behaviour, no guard reads at all
reset; writes
W=$(issue_close_shipped "$S" 2320 "Merged. Closing this issue." "$T/h" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$W" = stripped ] && [ "$(n_patch)" = 1 ] && ok || bad "S6: no PR url must keep today's close (rc=$RC w=$W)"
grep -q 'pulls/2390\|timeline' "$T/gh-argv.log" && bad "S6: no PR url must make no guard read" || ok

# ════════════════════════════════════════════════════════════════════════════
# M. mc_close_shipped with a PR url — merge conductor and tier-2 sweep
# ════════════════════════════════════════════════════════════════════════════
mcs() { mc_close_shipped "$S" 2320 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }

# M1 Refs: no close, the comment marker written
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(mcs); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped ] && ok || bad "M1: a Refs PR must answer kept-slice:no-keyword+stripped rc 0 (rc=$RC w=$W)"  # TEST-CHANGE BH-2508
[ "$(n_patch)" = 0 ] && ok || bad "M1: a Refs PR must never PATCH the issue ($(n_patch))"
[ -f "$REC/issue-commented" ] && ok || bad "M1: the slice comment must write <record>/issue-commented"
head -1 "$T/posted.txt" | grep -q '^Slice delivered: #2390' && ok || bad "M1: the comment must start 'Slice delivered: #2390'"

# M2 the other lane on the same record: no second comment
ghfx_log_reset
W=$(mcs); RC=$?
# TEST-CHANGE BH-2508: the stub still reads the label as on, so the retry strips again (idempotent DELETE).
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped ] && ok || bad "M2: the second call must still answer kept-slice (rc=$RC w=$W)"
[ "$(n_post)" = 0 ] && [ "$(n_patch)" = 0 ] && ok || bad "M2: the second call must post nothing and close nothing (post=$(n_post) patch=$(n_patch))"

# M3 Closes: today's path
reset; pr_body "$CLOSES_BODY"; timeline '[]'; writes
W=$(mcs); RC=$?
[ "$RC" = 0 ] && [ "$(n_patch)" -ge 1 ] && ok || bad "M3: a Closes PR must close (rc=$RC w=$W patch=$(n_patch))"
case "$W" in kept-*|close-deferred*) bad "M3: a Closes PR must print the strip word (got '$W')" ;; *) ok ;; esac
head -1 "$T/posted.txt" | grep -q '^Merged in' && ok || bad "M3: the close comment is the caller's own body"

# M4 unknown: rc 1, nothing written, no marker
reset; ghfx_route GET "repos/$S/pulls/2390" 403 '{"message":"nope"}'; timeline '[]'; writes
W=$(mcs); RC=$?
[ "$RC" = 1 ] && [ "$(n_patch)" = 0 ] && [ "$(n_post)" = 0 ] && [ ! -f "$REC/issue-commented" ] && ok \
  || bad "M4: an unknown must be rc 1 with no writes (rc=$RC w=$W patch=$(n_patch) post=$(n_post))"
case "$W" in close-deferred:*) ok ;; *) bad "M4: an unknown must print close-deferred:* (got '$W')" ;; esac

echo "issue-close-guard (BH-2477): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
