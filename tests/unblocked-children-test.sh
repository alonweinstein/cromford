#!/bin/bash
# tests/unblocked-children-test.sh — bin/unblocked-children.sh against a gh shim.
# Run from anywhere: tests/unblocked-children-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
export HARNESS="$T" GH_ISSUES_REPO="org/repo"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# gh shim: `gh issue list ... --state all --json ...` answers from $T/issues.json;
# GH_FAIL=1 makes it die like a dead token would. The later calls the dep pass
# makes (the PR list, a PR's changed files, the one issue comment) answer from
# their own fixtures, and anything unanticipated falls through to the issue list
# exactly as this shim has always behaved.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
[ "${GH_FAIL:-}" = "1" ] && { echo "gh: HTTP 401" >&2; exit 1; }
case "$*" in
  *"pr list"*)       cat "$HARNESS/prs.json" 2>/dev/null || echo '[]' ;;
  # (BH-781) The dep pass posts through bin/lib/gh-rest.sh:
  # `gh api -i -X POST repos/o/r/issues/N/comments -F body=@<file>`. The shim
  # answers in that library's wire shape and records the same sentence it always
  # did — "issue comment <n> --body <text>" — so the assertions below still read
  # what a human put on the thread rather than an argv shape.
  *"-X POST"*comments*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    bf=$(printf '%s' "$*" | sed -nE 's/.*-F body=@([^ ]+).*/\1/p')
    printf 'issue comment %s --body %s\n' "$n" "$(cat "$bf" 2>/dev/null)" >> "$HARNESS/comments.log"
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"issue view"*)
    n=$(printf '%s' "$*" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    cat "$HARNESS/issue-$n.json" 2>/dev/null \
      || cat "$HARNESS/issue-body.json" 2>/dev/null || echo '{"body":""}' ;;
  *pulls/*/files*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    cat "$HARNESS/pr-files-$n.json" 2>/dev/null || exit 1 ;;
  *) cat "$HARNESS/issues.json" ;;
esac
SH
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
run() { "$DIR/bin/unblocked-children.sh" p 2>/dev/null; }
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"

cat > "$T/issues.json" <<'JSON'
[
 {"number":331,"state":"CLOSED","title":"TK-323.1 keys","body":"parent #323"},
 {"number":332,"state":"OPEN","title":"TK-323.2 carry-forward","body":"**Blocked-by: #331** (build after it).\nTS-323.3 builds after THIS."},
 {"number":333,"state":"OPEN","title":"TK-323.3 delta analysis","body":"Blocked-by: #332"},
 {"number":336,"state":"OPEN","title":"two blockers","body":"> Blocked-by #331, #340 — both must land"},
 {"number":337,"state":"OPEN","title":"two blockers both closed","body":"blocked-by: TK-331 / #331 and #341"},
 {"number":338,"state":"OPEN","title":"no blocker, mentions 331 in prose","body":"See #331 for context."},
 {"number":339,"state":"CLOSED","title":"already closed child","body":"Blocked-by: #331"},
 {"number":340,"state":"OPEN","title":"other blocker","body":""},
 {"number":341,"state":"CLOSED","title":"other blocker closed","body":""}
]
JSON

# 1. #331 went OPEN -> CLOSED: 332 (single blocker) and 337 (both blockers closed)
#    are listed; 333 (blocked by open 332), 336 (340 still open), 338 (prose
#    mention, no Blocked-by line) and 339 (already closed) are not.
OUT=$(run <<'D'
board issues: CHANGED 331 "TK-323.1 keys" (state: OPEN -> CLOSED; comments: 3 -> 4; activity)
board issues: CHANGED 350 "other" (comments: 1 -> 2; activity)
D
)
grep -q '^board issues: UNBLOCKED 332 "TK-323.2 carry-forward" (Blocked-by #331 is now CLOSED' <<<"$OUT" && ok || bad "332 should be listed (got: $OUT)"
grep -q '^board issues: UNBLOCKED 337 ' <<<"$OUT" && ok || bad "337 (all blockers closed) should be listed (got: $OUT)"
for n in 333 336 338 339 331 350; do
  grep -q "UNBLOCKED $n " <<<"$OUT" && bad "$n must NOT be listed (got: $OUT)" || ok
done
[ "$(grep -c . <<<"$OUT")" -eq 2 ] && ok || bad "exactly two lines expected (got: $OUT)"

# 2. no OPEN -> CLOSED line in the diff: silent, exit 0, and gh is never needed
OUT=$(GH_FAIL=1 run <<'D'
board issues: CHANGED 332 "TK-323.2 carry-forward" (comments: 1 -> 2; activity)
board issues: NEW 360 "fresh"
D
); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "no closure should be silent (rc=$RC out=$OUT)"

# 3. a closure but gh is dead: fail-open — silent, exit 0
OUT=$(GH_FAIL=1 run <<<'board issues: CHANGED 331 "x" (state: OPEN -> CLOSED)'); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "gh failure should be silent exit 0 (rc=$RC out=$OUT)"

# 4. a project with no GitHub-Issues board resolves no repo: silent, exit 0
OUT=$(GH_ISSUES_REPO= run <<<'board issues: CHANGED 331 "x" (state: OPEN -> CLOSED)'); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "no repo should be silent exit 0 (rc=$RC out=$OUT)"

# 5. the in-app spelling ("status: open -> closed") is honoured too
OUT=$(run <<<'board b1: CHANGED 331 "x" (status: open -> closed; activity)')
grep -q 'UNBLOCKED 332 ' <<<"$OUT" && ok || bad "lowercase status closure should count (got: $OUT)"

# ---------- 6. dep-verified soft: a Blocked-by line the harness CHECKED ------
# W2-G. Above this point every class still OBEYS the Blocked-by line and only
# differs on how early. Here the line itself is judged: #51's pre-plan names
# files #50's PR does not touch, and its plan declares the link ordering-only,
# so it is emitted as UNBLOCKED — build on MAIN now — instead of stacking on a
# branch it does not need. Everything is wired through $HARNESS/bin, so the
# sections above (which have no bin/dep-verify.sh under $T) exercised the
# flag-off path already.
mkdir -p "$T/bin/lib" "$T/plans" "$T/prompts" "$T/logs" "$T/state"
cp "$DIR/bin/dep-verify.sh" "$T/bin/"
cp "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"
echo 'setsid /root/harness/bin/run-build.sh p <issue-number> AB-<issue-number> > x' > "$T/prompts/p.md"
cat > "$T/issues.json" <<'JSON'
[
 {"number":50,"state":"OPEN","title":"parent, PR open","body":""},
 {"number":51,"state":"OPEN","title":"AB-50.2 brain map","body":"## Scope\nBlocked-by: #50"},
 {"number":52,"state":"OPEN","title":"AB-50.3 rollup","body":"## Scope\nBlocked-by: #50"}
]
JSON
echo '[{"number":900,"title":"AB-50: parent","headRefName":"ticket/ab-50","headRefOid":"bbbb222","state":"OPEN","url":"https://gh/900","isDraft":false}]' > "$T/prs.json"
echo '[{"filename":"src/lib/rollup.ts"}]' > "$T/pr-files-900.json"
for n in 51 52; do
  mkdir -p "$T/plans/p-AB-$n"
  printf '## Dependencies
DEPENDS: #50 soft — shares no code with the parent
SIZE: S
' > "$T/plans/p-AB-$n/plan.md"
done
printf 'src/lib/brain-map.ts
' > "$T/plans/p-AB-51/planned-files.txt"
printf 'src/lib/rollup.ts
'    > "$T/plans/p-AB-52/planned-files.txt"   # overlaps the parent PR

: > "$T/logs/p.log"; : > "$T/comments.log"; : > "$T/gh-calls.log"
OUT=$(run <<<'board issues: CHANGED 50 "parent" (comments: 1 -> 2; activity)')
grep -q '^board issues: UNBLOCKED 51 .*dep-verified soft: #50' <<<"$OUT" && ok   || bad "a file-disjoint child whose plan says soft must be emitted as UNBLOCKED (got: $OUT)"
grep -q 'STACKABLE 51 ' <<<"$OUT" && bad "a soft-verified child must not ALSO be offered as a stack (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 52 ' <<<"$OUT" && ok   || bad "a child whose files overlap the parent PR keeps today's STACKABLE behaviour (got: $OUT)"
grep -q 'UNBLOCKED 52 ' <<<"$OUT" && bad "an overlapping child must never be soft-released (got: $OUT)" || ok
grep -q 'DEP_SOFT 51 vs 50 ' "$T/logs/p.log" && ok || bad "DEP_SOFT must be logged (got: $(cat "$T/logs/p.log"))"
grep -q 'DEP_HARD 52 vs 50 ' "$T/logs/p.log" && ok || bad "DEP_HARD must be logged (got: $(cat "$T/logs/p.log"))"
# ONE --state all PR list for the whole pass, not one per (child, blocker) pair:
# two pairs are judged here, and a PAT has 5000 requests an hour.
[ "$(grep -c 'pr list.*--state all' "$T/gh-calls.log")" = 1 ] && ok \
  || bad "the dep pass must share one --state all PR list (got: $(grep -c 'pr list.*--state all' "$T/gh-calls.log"))"

# the decision is recorded on the thread, once and only once
[ "$(grep -c 'issue comment 51' "$T/comments.log")" = 1 ] && ok   || bad "exactly one comment on the soft-launched child (got: $(cat "$T/comments.log"))"
grep -q 'issue comment 52' "$T/comments.log" && bad "a child that was not released must not be commented on" || ok
run <<<'board issues: CHANGED 50 "parent" (comments: 2 -> 3; activity)' >/dev/null
[ "$(grep -c 'issue comment 51' "$T/comments.log")" = 1 ] && ok   || bad "the marker must stop a second comment on a later tick (got: $(cat "$T/comments.log"))"

# the dry run emits the line and writes nothing
rm -rf "$T/state/dep-verify"; : > "$T/comments.log"
OUT=$(DEP_VERIFY_DRY_RUN=1 run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'UNBLOCKED 51 .*dep-verified soft' <<<"$OUT" && ok || bad "the dry run must still emit the line (got: $OUT)"
[ -s "$T/comments.log" ] && bad "DEP_VERIFY_DRY_RUN=1 must post no comment" || ok
[ -e "$T/state/dep-verify/p/51-50" ] && bad "DEP_VERIFY_DRY_RUN=1 must cache nothing" || ok

# ---------- 7. the kill flag: byte for byte what this script did before ------
: > "$T/logs/p.log"; : > "$T/comments.log"
OUT=$(DEP_VERIFY=0 run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'dep-verified soft' <<<"$OUT" && bad "DEP_VERIFY=0 must emit no soft line (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 51 .*base=ticket/ab-50' <<<"$OUT" && ok   || bad "with the flag off #51 is a plain STACKABLE again (got: $OUT)"
[ -s "$T/logs/p.log" ] && bad "DEP_VERIFY=0 must log no DEP_ line" || ok
[ -s "$T/comments.log" ] && bad "DEP_VERIFY=0 must post nothing" || ok
touch "$T/flags/dep-verify-off" 2>/dev/null || { mkdir -p "$T/flags"; touch "$T/flags/dep-verify-off"; }
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'dep-verified soft' <<<"$OUT" && bad "flags/dep-verify-off must turn it off (got: $OUT)" || ok
rm -f "$T/flags/dep-verify-off"
# ...and with both classes off the script exits silently on a diff with no closure
OUT=$(DEP_VERIFY=0 STACKED_BUILDS=0 GH_FAIL=1 run <<<'board issues: CHANGED 50 "x" (activity)'); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "both flags off = the original early exit (rc=$RC out=$OUT)"

# ---------- 8. the parent the labelled list cannot see -----------------------
# THE SIZE GATE REMOVES ai-build FROM A DECOMPOSED PARENT (project-5 #667, #668
# are OPEN and unlabelled), and this pass lists `--label ai-build`. A blocker
# that is simply not in the list used to read as CLOSED, which is the worst of
# both answers: the child's blockers all looked closed, nothing in the diff had
# closed them, so it was dropped without ever being judged — while the triage
# session, reading the same body, correctly saw an open parent. Blockers the
# list does not carry are now fetched by number.
# #69 has no pre-plan, so its dep verdict is UNKNOWN; this section pins the
# STATE reading and runs under DEP_UNKNOWN_MODE=hard so an UNKNOWN pair is a
# wait here — the mode itself is section 9's subject.
export DEP_UNKNOWN_MODE=hard
rm -rf "$T/state/dep-verify"; : > "$T/logs/p.log"; : > "$T/comments.log"
cat > "$T/issues.json" <<'JSON'
[
 {"number":69,"state":"OPEN","title":"AB-69 child of two de-labelled parents","body":"## Scope\nBlocked-by: #67, #68"}
]
JSON
echo '{"number":67,"state":"OPEN","title":"parent one"}'   > "$T/issue-67.json"
echo '{"number":68,"state":"CLOSED","title":"parent two"}' > "$T/issue-68.json"
echo '[{"number":901,"title":"AB-67: parent one","headRefName":"ticket/ab-67","headRefOid":"ccc333","state":"OPEN","url":"https://gh/901","isDraft":false}]' > "$T/prs.json"
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q '^board issues: STACKABLE 69 .*base=ticket/ab-67' <<<"$OUT" && ok \
  || bad "an OPEN parent missing from the ai-build list must read OPEN, leaving the child stackable on its PR (got: $OUT)"
grep -q 'UNBLOCKED 69 ' <<<"$OUT" && bad "a child with an OPEN blocker must never be released (got: $OUT)" || ok

# ...and when those parents really are closed, the release comes from THIS pass:
# no board diff can carry a closure the ai-build fingerprint never saw.
echo '{"number":67,"state":"CLOSED","title":"parent one"}' > "$T/issue-67.json"
echo '[]' > "$T/prs.json"
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q '^board issues: UNBLOCKED 69 .*every blocker it names — #67, #68 — is CLOSED' <<<"$OUT" && ok \
  || bad "all blockers closed with nothing in the diff must still release the child (got: $OUT)"
[ -e "$T/state/dep-verify/p/69.unblocked" ] && ok || bad "the release must leave its rate-limit marker"
# the marker is what stops the same line every ten minutes...
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'UNBLOCKED 69 ' <<<"$OUT" && bad "the marker must stop a second release line inside the window (got: $OUT)" || ok
# ...and the window is what stops it becoming a dropped ticket.
OUT=$(UNBLOCKED_REMIND_S=0 run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'UNBLOCKED 69 ' <<<"$OUT" && ok || bad "a child nobody launched must be offered again once the window passes (got: $OUT)"

# a child that already has its own PR is not a launch, so it is not a line
echo '[{"number":902,"title":"AB-69: child","headRefName":"ticket/ab-69","headRefOid":"ddd444","state":"OPEN","url":"https://gh/902","isDraft":false}]' > "$T/prs.json"
rm -f "$T/state/dep-verify/p/69.unblocked"
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q 'UNBLOCKED 69 ' <<<"$OUT" && bad "a child with its own open PR must not be released again (got: $OUT)" || ok
echo '[]' > "$T/prs.json"

# a blocker nobody can read is NOT a blocker that closed: fail closed, say nothing
rm -f "$T/issue-67.json" "$T/issue-68.json" "$T/state/dep-verify/p/69.unblocked"
echo '{"body":"not an issue"}' > "$T/issue-body.json"
OUT=$(run <<<'board issues: CHANGED 50 "x" (activity)')
grep -q ' 69 ' <<<"$OUT" && bad "a blocker whose state could not be read must leave the child alone (got: $OUT)" || ok
unset DEP_UNKNOWN_MODE

# ---------- 9. DEP_UNKNOWN_MODE: an UNKNOWN pair is not a cap ----------------
# A decomposed child has no pre-plan until the pre-plan lane reaches it, and
# "no planned-files list" is UNKNOWN — which every caller obeyed like HARD.
# project-5 05:04Z 2026-09-16: 22 of 49 open tickets held that way with the Fly
# pool already unlimited. the operator: "There should be no cap, let's remove the cap."
# Default `soft`: the pair counts like SOFT and the child is released on main,
# with a line and a thread comment that say the check could NOT run. `hard` is
# the old wait. A pair the evidence actually calls HARD is HARD under both.
rm -rf "$T/state/dep-verify" "$T/plans/p-AB-71" "$T/plans/p-AB-72"; : > "$T/logs/p.log"; : > "$T/comments.log"
rm -f "$T/issue-body.json"
cat > "$T/issues.json" <<'JSON'
[
 {"number":70,"state":"OPEN","title":"parent, PR open","body":""},
 {"number":71,"state":"OPEN","title":"AB-70.1 no pre-plan yet","body":"## Scope\nBlocked-by: #70"},
 {"number":72,"state":"OPEN","title":"AB-70.2 pre-planned, really hard","body":"## Scope\nBlocked-by: #70"},
 {"number":73,"state":"OPEN","title":"AB-70.3 no pre-plan, author says hard","body":"## Scope\nBlocked-by: #70 (hard)"}
]
JSON
echo '[{"number":910,"title":"AB-70: parent","headRefName":"ticket/ab-70","headRefOid":"eee555","state":"OPEN","url":"https://gh/910","isDraft":false}]' > "$T/prs.json"
echo '[{"filename":"src/lib/shared.ts"}]' > "$T/pr-files-910.json"
mkdir -p "$T/plans/p-AB-72"
printf '## Dependencies\nDEPENDS: #70 hard — extends the parent\x27s module\nSIZE: S\n' > "$T/plans/p-AB-72/plan.md"
printf 'src/lib/shared.ts\n' > "$T/plans/p-AB-72/planned-files.txt"

# default (nothing set): soft
OUT=$(run <<<'board issues: CHANGED 70 "parent" (activity)')
grep -q '^board issues: UNBLOCKED 71 .*dep-unverified, released: #70' <<<"$OUT" && ok \
  || bad "default DEP_UNKNOWN_MODE=soft must release an un-pre-planned child on main (got: $OUT)"
grep -q 'STACKABLE 71 ' <<<"$OUT" && bad "a released child must not ALSO be offered as a stack (got: $OUT)" || ok
grep -q 'dep-verified soft: #70.*71\|UNBLOCKED 71 .*dep-verified soft' <<<"$OUT" && bad "an UNKNOWN release must not claim it was verified (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 72 ' <<<"$OUT" && ok || bad "a pair the evidence calls HARD stays a stack under soft (got: $OUT)"
grep -q 'UNBLOCKED 72 ' <<<"$OUT" && bad "a HARD pair must never be released by the UNKNOWN mode (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 73 ' <<<"$OUT" && ok || bad "the author's (hard) hatch must hold an un-pre-planned child under soft (got: $OUT)"
grep -q 'UNBLOCKED 73 ' <<<"$OUT" && bad "Blocked-by … (hard) outranks the UNKNOWN mode (got: $OUT)" || ok
grep -q 'DEP_SOFT 71 vs 70 — UNKNOWN, released (DEP_UNKNOWN_MODE=soft): ' "$T/logs/p.log" && ok \
  || bad "the soft path must log DEP_SOFT … UNKNOWN, released (got: $(cat "$T/logs/p.log"))"
grep -q 'DEP_HARD 71 vs 70' "$T/logs/p.log" && bad "no DEP_HARD line for an UNKNOWN pair under soft (got: $(cat "$T/logs/p.log"))" || ok
grep -q 'DEP_HARD 72 vs 70 — the pre-plan' "$T/logs/p.log" && ok || bad "a real HARD verdict keeps its DEP_HARD line (got: $(cat "$T/logs/p.log"))"
grep -q 'DEP_HARD 73 vs 70 — #73 declares #70 hard' "$T/logs/p.log" && ok || bad "the hatch must answer HARD before the no-pre-plan exit (got: $(cat "$T/logs/p.log"))"
# the thread comment says the check could not run, not "we checked"
[ "$(grep -c 'issue comment 71' "$T/comments.log")" = 1 ] && ok || bad "exactly one comment on the released child (got: $(cat "$T/comments.log"))"
grep -q 'could not verify the dependency yet' "$T/comments.log" && ok \
  || bad "an UNKNOWN release must say so on the thread (got: $(cat "$T/comments.log"))"
grep -q 'We checked the dependency' "$T/comments.log" && bad "an UNKNOWN release must not claim a check ran" || ok
grep -q 'issue comment 72\|issue comment 73' "$T/comments.log" && bad "held children get no comment" || ok

# hard: the pre-2026-09-16 behaviour, to the letter
rm -rf "$T/state/dep-verify"; : > "$T/logs/p.log"; : > "$T/comments.log"
OUT=$(DEP_UNKNOWN_MODE=hard run <<<'board issues: CHANGED 70 "parent" (activity)')
grep -q '^board issues: STACKABLE 71 .*base=ticket/ab-70' <<<"$OUT" && ok || bad "DEP_UNKNOWN_MODE=hard must hold an un-pre-planned child as a stack (got: $OUT)"
grep -q 'UNBLOCKED 71 ' <<<"$OUT" && bad "DEP_UNKNOWN_MODE=hard must not release on UNKNOWN (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 72 ' <<<"$OUT" && ok || bad "HARD stays a stack under hard too (got: $OUT)"
grep -q 'DEP_HARD 71 vs 70 — UNKNOWN, treated as hard: ' "$T/logs/p.log" && ok \
  || bad "the hard path keeps the old log line (got: $(cat "$T/logs/p.log"))"
[ -s "$T/comments.log" ] && bad "nothing is released under hard, so nothing is commented on" || ok
# ...spelled in env/global.env rather than the environment
mkdir -p "$T/env"; printf 'DEP_UNKNOWN_MODE=hard\n' > "$T/env/global.env"
OUT=$(run <<<'board issues: CHANGED 70 "parent" (activity)')
grep -q '^board issues: STACKABLE 71 ' <<<"$OUT" && ok || bad "env/global.env DEP_UNKNOWN_MODE=hard must be honoured (got: $OUT)"
rm -f "$T/env/global.env"
# ...and the dry run releases on paper only
rm -rf "$T/state/dep-verify"; : > "$T/comments.log"
OUT=$(DEP_VERIFY_DRY_RUN=1 run <<<'board issues: CHANGED 70 "parent" (activity)')
grep -q 'UNBLOCKED 71 .*dep-unverified, released' <<<"$OUT" && ok || bad "the dry run must still emit the released line (got: $OUT)"
[ -s "$T/comments.log" ] && bad "DEP_VERIFY_DRY_RUN=1 must post no comment for an UNKNOWN release" || ok

echo "unblocked-children: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
