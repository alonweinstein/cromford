#!/bin/bash
# tests/dep-verify-test.sh — bin/dep-verify.sh against a gh shim and scratch
# pre-plans. Run from anywhere: tests/dep-verify-test.sh  (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. `Blocked-by: #N` used to be an order; from W2-G it is
# a claim this script checks, and a wrong SOFT is the one expensive outcome in
# the whole design — a child built on a base that does not carry the code it
# needs. So the suite is written from the fail-closed side: every way the
# evidence can be incomplete has its own case and every one of them must come
# back UNKNOWN (which DEP_UNKNOWN_MODE decides the fate of — see unblocked-children-test.sh), and SOFT is only
# ever reached with BOTH halves present. The author's escape hatch is pinned
# beating a plan that disagrees with it, the cache is pinned invalidating on a
# plan edit rather than on a clock, and the dry run is pinned writing nothing.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/state" "$T/prompts"
cp "$DIR/bin/dep-verify.sh" "$T/bin/"
cp "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
# TEST-CHANGE (BH-782): the two GitHub reads go through the REST contract now,
# and without the lib beside the script every case would answer "gh lib missing"
# instead of exercising the verdict it is about.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
CONF
# The only place a GitHub-Issues project's KEY prefix is written down is its
# rendered triage prompt (prompts/TEMPLATE-GH.md's launch line).
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"

# gh shim. GH_FAIL=1 dies like a dead token; otherwise each call answers from a
# file, so "what GitHub said" is a fixture and never a network round trip.
mkdir -p "$T/bin"
# TEST-CHANGE (BH-782): the PR list and the child's issue body are REST reads
# through bin/lib/gh-rest.sh (`gh api -i`), so the shim answers those two with a
# status line, a blank line and a REST-shaped body. GH_FAIL=1 turns both into a
# 403, which is the "we could not look" case the script now names out loud
# instead of reading as "the blocker has no PR" / "the body is empty".
# `pulls/N/files` was already a plain REST `gh api` call and is unchanged.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
INC=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
reply() { # reply <status> <body>
  if [ "$INC" = 1 ]; then printf 'HTTP/2.0 %s\r\n\r\n' "$1"; fi
  [ -n "$2" ] && printf '%s\n' "$2"
  case "$1" in 2*) exit 0 ;; *) exit 1 ;; esac
}
if [ "${GH_FAIL:-}" = 1 ]; then reply 403 '{"message":"forbidden"}'; fi
case "$P" in
  */pulls/*/files*)
    n=$(printf '%s' "$P" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    reply 200 "$(cat "$HARNESS/pr-files-$n.json" 2>/dev/null)" ;;
  */pulls*)  reply 200 "$(cat "$HARNESS/prs.json" 2>/dev/null || echo '[]')" ;;
  */issues/[0-9]*) reply 200 "$(cat "$HARNESS/issue-body.json" 2>/dev/null || echo '{"body":""}')" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
export GH_ISSUES_REPO="example-org/proj"

# #11 is the blocker: an OPEN harness PR on the branch run-build.sh cuts.
# REST shapes: head.ref / head.sha, lowercase state, merged_at for MERGED.
echo '[{"number":99,"title":"AB-11: parent","head":{"ref":"ticket/ab-11","sha":"aaaa111"},"state":"open","merged_at":null}]' > "$T/prs.json"
cat > "$T/pr-files-99.json" <<'JSON'
[{"filename":"src/lib/rollup.ts"},{"filename":"src/ui/rollup-card.tsx"},{"filename":"package.json"}]
JSON
echo '{"body":"## Scope\nBlocked-by: #11\n"}' > "$T/issue-body.json"

# The child's pre-plan: disjoint files, and a plan that says the link is soft.
PD="$T/plans/proj-AB-20"; mkdir -p "$PD"
cat > "$PD/plan.md" <<'MD'
## Scope
Touch src/lib/brain-map.ts only.

## Dependencies
DEPENDS: #11 soft — reads no symbol #11 adds, ordering preference only

SIZE: S
MD
printf 'src/lib/brain-map.ts\n' > "$PD/planned-files.txt"

run() { "$T/bin/dep-verify.sh" proj "$@" 2>/dev/null; }

# ---------- 1. SOFT needs BOTH halves, and here it has them -----------------
OUT=$(run 20 11)
[[ "$OUT" == SOFT\ * ]] && ok || bad "disjoint files + DEPENDS soft must be SOFT (got: $OUT)"
grep -q 'disjoint' <<<"$OUT" && ok || bad "the SOFT reason must name the file evidence (got: $OUT)"
grep -q 'ordering preference only' <<<"$OUT" && ok || bad "the SOFT reason must carry the plan's own words (got: $OUT)"

# ---------- 2. the cache: a verdict, and what re-opens it -------------------
C="$T/state/dep-verify/proj/20-11"
[ -s "$C" ] && ok || bad "a computed verdict must be cached at $C"
head -1 "$C" | grep -q '^fp=' && ok || bad "the cache row must carry the evidence fingerprint (got: $(head -1 "$C"))"
# A cache HIT answers with no pulls/N/files call at all: remove the fixture and
# the verdict must still come back SOFT.
mv "$T/pr-files-99.json" "$T/pr-files-99.json.off"
OUT=$(run 20 11)
[[ "$OUT" == SOFT\ * ]] && ok || bad "an unchanged fingerprint must answer from cache (got: $OUT)"
mv "$T/pr-files-99.json.off" "$T/pr-files-99.json"

# ---------- 3. overlapping files are HARD, whatever the plan says -----------
# This is also the cache-invalidation case: the pair above is cached SOFT, and
# editing the child's own file list has to re-open the question rather than
# reuse it. Fingerprinting the EVIDENCE is what buys that; a timestamp would not.
printf 'src/lib/brain-map.ts\nsrc/lib/rollup.ts\n' > "$PD/planned-files.txt"
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a changed planned-files list must re-verify to HARD, not reuse SOFT (got: $OUT)"
grep -q 'src/lib/rollup.ts' <<<"$OUT" && ok || bad "the HARD reason must name the colliding path (got: $OUT)"
# a DIRECTORY scope that contains the blocker's file collides too (the
# bin/conflict-check.sh rule: file == file, dir contains file)
printf 'src/lib/brain-map.ts\nsrc/ui\n' > "$PD/planned-files.txt"
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a directory scope containing the blocker's file must be HARD (got: $OUT)"
printf 'src/lib/brain-map.ts\n' > "$PD/planned-files.txt"

# ---------- 4. missing semantic half = UNKNOWN, with the file half reported -
cat > "$PD/plan.md" <<'MD'
## Scope
Touch src/lib/brain-map.ts only.
SIZE: S
MD
OUT=$(run 20 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "no DEPENDS line must be UNKNOWN, never SOFT (got: $OUT)"
grep -q 'disjoint' <<<"$OUT" && ok || bad "UNKNOWN must still report the file half it did compute (got: $OUT)"

# ---------- 5. DEPENDS hard is HARD -----------------------------------------
cat > "$PD/plan.md" <<'MD'
## Dependencies
DEPENDS: #11 hard — imports the rollup helper #11 adds
SIZE: S
MD
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "DEPENDS hard must be HARD (got: $OUT)"
grep -q 'imports the rollup helper' <<<"$OUT" && ok || bad "the HARD reason must quote the plan (got: $OUT)"

# ---------- 6. the author's escape hatch outranks the evidence --------------
cat > "$PD/plan.md" <<'MD'
## Dependencies
DEPENDS: #11 soft — I think this is fine
SIZE: S
MD
echo '{"body":"## Scope\nBlocked-by: #11 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "Blocked-by: #11 (hard) must beat a plan that says soft (got: $OUT)"
echo '{"body":"## Scope\nNeeds: #11\n"}' > "$T/issue-body.json"
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a Needs: #11 line must be HARD with no verification (got: $OUT)"
# the body the CALLER already has is used instead of a second fetch
printf '## Scope\nBlocked-by: #11 (hard)\n' > "$T/body.md"
OUT=$(GH_FAIL=1 DEP_CHILD_BODY_FILE="$T/body.md" run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a handed-in body must be read without asking gh (got: $OUT)"
echo '{"body":"## Scope\nBlocked-by: #11\n"}' > "$T/issue-body.json"

# ---------- 7. no pre-plan = UNKNOWN, and it costs nothing ------------------
# GH_FAIL=1 proves the early exit really is before any request: a child with no
# file list is answered without a token, which is what makes this free to ask on
# every blocked child of every tick.
OUT=$(GH_FAIL=1 run 21 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "a child with no pre-plan must be UNKNOWN (got: $OUT)"
[ -e "$T/state/dep-verify/proj/21-11" ] && bad "an unanswerable pair must not be cached" || ok

# ---------- 8. a blocker with no file evidence at all -----------------------
cat > "$PD/plan.md" <<'MD'
## Dependencies
DEPENDS: #12 soft — unrelated area
SIZE: S
MD
OUT=$(run 20 12)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "a blocker with no PR and no pre-plan must be UNKNOWN (got: $OUT)"
# ...but its OWN pre-plan is evidence when it has one
BD="$T/plans/proj-AB-12"; mkdir -p "$BD"
printf 'src/lib/other.ts\n' > "$BD/planned-files.txt"
OUT=$(run 20 12)
[[ "$OUT" == SOFT\ * ]] && ok || bad "a blocker's own pre-plan is the third-choice file set (got: $OUT)"
grep -q "pre-plan" <<<"$OUT" && ok || bad "the reason must say where the blocker's files came from (got: $OUT)"

# ---------- 9. the dry run writes nothing -----------------------------------
rm -rf "$T/state/dep-verify"
OUT=$(DEP_VERIFY_DRY_RUN=1 run 20 12)
[[ "$OUT" == SOFT\ * ]] && ok || bad "the dry run must still print the verdict (got: $OUT)"
[ -e "$T/state/dep-verify/proj/20-12" ] && bad "DEP_VERIFY_DRY_RUN=1 must not cache" || ok

# ---------- 10. the kill flag ------------------------------------------------
OUT=$(DEP_VERIFY=0 run 20 12)
[[ "$OUT" == UNKNOWN\ * ]] && grep -q 'off' <<<"$OUT" && ok || bad "DEP_VERIFY=0 must answer UNKNOWN off (got: $OUT)"
echo 'DEP_VERIFY=0' > "$T/env/global.env"
OUT=$(run 20 12); : > "$T/env/global.env"
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "DEP_VERIFY=0 in global.env must turn it off (got: $OUT)"
touch "$T/flags/dep-verify-off"
OUT=$(run 20 12)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "flags/dep-verify-off must turn it off (got: $OUT)"
rm -f "$T/flags/dep-verify-off"
OUT=$(run 20 12)
[[ "$OUT" == SOFT\ * ]] && ok || bad "removing the flag must turn it back on (got: $OUT)"

# ---------- 11. a hand-written file list drives the file half alone ---------
# DEP_CHILD_FILES is how the file evidence is inspected before any pre-plan
# exists — the PR's own dry-run table is produced exactly this way.
printf 'src/lib/rollup.ts\n' > "$T/hand.txt"
OUT=$(DEP_VERIFY_DRY_RUN=1 DEP_CHILD_FILES="$T/hand.txt" DEP_CHILD_PLAN=/nonexistent run 30 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a hand-written overlapping list must be HARD (got: $OUT)"
printf 'src/lib/elsewhere.ts\n' > "$T/hand.txt"
OUT=$(DEP_VERIFY_DRY_RUN=1 DEP_CHILD_FILES="$T/hand.txt" DEP_CHILD_PLAN=/nonexistent run 30 11)
[[ "$OUT" == UNKNOWN\ * ]] && grep -q 'disjoint' <<<"$OUT" && ok \
  || bad "a disjoint hand list with no plan is UNKNOWN and says the file half passed (got: $OUT)"

# ---------- 12. garbage in, one line out -------------------------------------
OUT=$(run abc 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "a non-numeric child must be UNKNOWN (got: $OUT)"
[ "$(printf '%s' "$OUT" | grep -c .)" = 1 ] && ok || bad "exactly one line, always (got: $OUT)"
OUT=$(GH_ISSUES_REPO= run 20 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok || bad "a project with no issues repo must be UNKNOWN (got: $OUT)"

# ---------- 13. a pre-plan names the directory AND the file in it -----------
# THE REAL LISTS (project-5 TK-667 / TK-669, 2026-09-14). A pre-plan writes "I
# add a migration" as two entries — the directory and the file under it — so the
# bare `prisma/migrations/manual` collided with every sibling's migration and
# `bin/dep-verify.sh project-5 669 667` reported
# `2026-09-14-TK-669-hat-merge-knobs.sql ~ prisma/migrations/manual`: two
# DIFFERENT new files judged as one shared path. The directory entry is dropped
# when the same list also names a file under it — and the verdict here stays
# HARD anyway, for the reason that is actually true (both slices append to
# prisma/schema.prisma).
CP="$T/plans/proj-AB-669"; BP="$T/plans/proj-AB-667"; mkdir -p "$CP" "$BP"
cat > "$CP/plan.md" <<'MD'
## Dependencies
DEPENDS: #667 soft — ordering preference only
SIZE: M
MD
cat > "$CP/planned-files.txt" <<'TXT'
prisma/migrations/manual
prisma/migrations/manual/2026-09-14-TK-669-hat-merge-knobs.sql
prisma/schema.prisma
scripts/worker-import-set.json
scripts/worker-import-set.mjs
TXT
cat > "$BP/planned-files.txt" <<'TXT'
prisma/migrations/manual
prisma/migrations/manual/2026-09-14-TK-667-team-chart-max-members.sql
prisma/schema.prisma
scripts/worker-import-set.json
scripts/worker-import-set.mjs
TXT
OUT=$(run 669 667)
[[ "$OUT" == HARD\ * ]] && ok || bad "669 vs 667 must still be HARD (got: $OUT)"
grep -q 'prisma/schema.prisma~prisma/schema.prisma' <<<"$OUT" && ok \
  || bad "the HARD reason must be the file both slices really append to (got: $OUT)"
grep -q 'prisma/migrations/manual~\|~prisma/migrations/manual,\|~prisma/migrations/manual$' <<<"$OUT" \
  && bad "the bare migrations directory must no longer be reported as a shared path (got: $OUT)" || ok
grep -q 'TK-669-hat-merge-knobs.sql' <<<"$OUT" \
  && bad "two DIFFERENT new migration files must not be judged as one (got: $OUT)" || ok

# with the genuinely shared append-only files out of the way, the two migrations
# are what is left — and they are different files in the same directory.
printf 'prisma/migrations/manual\nprisma/migrations/manual/2026-09-14-TK-669-hat-merge-knobs.sql\n' > "$CP/planned-files.txt"
printf 'prisma/migrations/manual\nprisma/migrations/manual/2026-09-14-TK-667-team-chart-max-members.sql\n' > "$BP/planned-files.txt"
OUT=$(run 669 667)
[[ "$OUT" == SOFT\ * ]] && ok \
  || bad "two distinct files under one named directory must be disjoint (got: $OUT)"

# ...and the rule the prune must NOT break: a directory that appears ALONE is an
# honest "I touch things under here" and still contains everything under it.
printf 'prisma/migrations/manual\n' > "$BP/planned-files.txt"
OUT=$(run 669 667)
[[ "$OUT" == HARD\ * ]] && ok || bad "a directory named ALONE must still contain the sibling's file (got: $OUT)"

# ---------- 14. the cheap file list is evidence on its own (BH-499) ---------
# WHY THIS EXISTS. Sections 4 and 11 above pin the old rule: disjoint files with
# no DEPENDS line is UNKNOWN, and UNKNOWN is obeyed exactly like HARD. That rule
# assumed the only file list in existence came from a FULL pre-plan, which also
# carries the DEPENDS line — so a list without one meant the planner had looked
# and declined to say, which is not evidence of anything.
#
# bin/planned-files-cheap.sh breaks that assumption: its list is extracted from
# the ticket body deterministically and CANNOT carry a DEPENDS line, because no
# model ever read the code. Requiring one there is requiring a sentence nobody
# was asked to write, and the result is the state this ticket exists to end —
# every child UNKNOWN, every Blocked-by line obeyed, the wave as narrow as its
# hand-typed graph. So a list that SAYS where it came from is accepted as the
# file half, and the semantic half is supplied by the body's own silence: no
# `Needs:` and no `(hard)` anywhere in it.
#
# The escape hatch still outranks everything (section 6), and a `model-floor`
# list deliberately does NOT qualify — a model guessing paths from a body that
# named none is the weakest evidence in the system, and it may say HARD on an
# overlap but never SOFT on a disjoint.
CPD="$T/plans/proj-AB-80"; mkdir -p "$CPD"
rm -f "$CPD/plan.md"
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
echo '{"body":"## Scope\nBlocked-by: #11\nTouch src/lib/brain-map.ts.\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == SOFT\ * ]] && ok \
  || bad "a SOURCE: ticket-body list disjoint from the parent, with no DEPENDS and no hard marker, must be SOFT (got: $OUT)"
grep -q 'ticket-body' <<<"$OUT" && ok || bad "the SOFT reason must name the evidence it leaned on (got: $OUT)"
# the SOURCE line is a HEADER, not a path. Counted as one it inflates every
# cheap list by one entry, and a line with a colon and a space in it would sit
# in the overlap comparison forever looking like a file nobody can find.
grep -q '(1 vs 3 paths)' <<<"$OUT" && ok \
  || bad "the SOURCE header was counted as a path — the child has exactly 1 (got: $OUT)"

# codegraph-widened lists carry the same weight
printf 'SOURCE: ticket-body+codegraph\nsrc/lib/brain-map.ts\nsrc/lib/other-thing.ts\n' > "$CPD/planned-files.txt"
OUT=$(run 80 11)
[[ "$OUT" == SOFT\ * ]] && ok || bad "a ticket-body+codegraph list must be accepted too (got: $OUT)"

# overlapping is HARD, exactly as it is for a full pre-plan's list
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\nsrc/lib/rollup.ts\n' > "$CPD/planned-files.txt"
OUT=$(run 80 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "an overlapping cheap list must be HARD (got: $OUT)"
grep -q 'src/lib/rollup.ts' <<<"$OUT" && ok || bad "the HARD reason must name the colliding path (got: $OUT)"

# a `Needs:` marker anywhere in the body disqualifies the cheap SOFT. The
# author said this slice needs something; we do not then infer independence
# from a file list they never wrote.
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
echo '{"body":"## Scope\nBlocked-by: #11\nNeeds: #12\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok \
  || bad "a body carrying a Needs: marker must fall back to UNKNOWN (got: $OUT)"
echo '{"body":"## Scope\nBlocked-by: #11\nBlocked-by: #12 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok \
  || bad "a body carrying a (hard) marker for ANY blocker must fall back to UNKNOWN (got: $OUT)"

# the weakest tier stays out: a model-guessed list may say HARD, never SOFT
echo '{"body":"## Scope\nBlocked-by: #11\n"}' > "$T/issue-body.json"
printf 'SOURCE: model-floor\nsrc/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
OUT=$(run 80 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok \
  || bad "a SOURCE: model-floor list must NOT reach SOFT on its own (got: $OUT)"

# a list with NO header is the pre-BH-499 shape and keeps the old answer
printf 'src/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
OUT=$(run 80 11)
[[ "$OUT" == UNKNOWN\ * ]] && ok \
  || bad "a headerless list with no DEPENDS must stay UNKNOWN — section 4's rule is unchanged (got: $OUT)"

# ...and the source is part of the cached evidence: re-headering the same paths
# must re-open the question rather than replay the UNKNOWN above.
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
OUT=$(run 80 11)
[[ "$OUT" == SOFT\ * ]] && ok || bad "the SOURCE line must be part of the evidence fingerprint (got: $OUT)"

# ---------- 15. one Blocked-by line, several blockers (BH-515) --------------
# WHY THIS EXISTS. bin/run-decompose.sh writes a decomposed child's blockers as
# ONE line — `Blocked-by: #553 (hard), #555 (hard)` — and both readers of the
# author's escape hatch used to stop at the first `#` on that line, so every
# blocker after the first lost its suffix: #555 went through verification like
# an unmarked claim while its author had typed (hard) right next to it. Each
# `#N` is judged by the suffix that follows IT, wherever on the line it sits.
rm -rf "$T/state/dep-verify"
cat > "$PD/plan.md" <<'MD'
## Dependencies
DEPENDS: #11 soft — reads no symbol #11 adds, ordering preference only
DEPENDS: #12 soft — unrelated area
SIZE: S
MD
printf 'src/lib/brain-map.ts\n' > "$PD/planned-files.txt"
# The body is not part of the evidence fingerprint when the caller hands in no
# body file (the gh shim answers it), so a pair re-asked under a different body
# would replay its own cached row — each sub-case below starts from no cache.

# 15a. both blockers marked. The SECOND one's suffix is the hatch, and it is the
# hatch that answers — not the file comparison, which would have said SOFT.
echo '{"body":"## Scope\nBlocked-by: #11 (hard), #12 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 20 12)
[[ "$OUT" == HARD\ * ]] && ok || bad "a second-position (hard) must be the escape hatch (got: $OUT)"
grep -q 'by design' <<<"$OUT" && ok || bad "the hatch, not the files, must be the reason for #12 (got: $OUT)"
grep -q '~' <<<"$OUT" && bad "#12 must not have been file-compared at all (got: $OUT)" || ok
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "the first blocker of the line keeps its hatch (got: $OUT)"

# 15b. only the second is marked: 12 is hard by design, and 11 is NOT — a
# neighbour's suffix must not leak onto the blocker beside it.
rm -rf "$T/state/dep-verify"
echo '{"body":"## Scope\nBlocked-by: #11, #12 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 20 12)
[[ "$OUT" == HARD\ * ]] && grep -q 'by design' <<<"$OUT" && ok \
  || bad "#12 (hard) after an unmarked blocker must be the hatch (got: $OUT)"
OUT=$(run 20 11)
[[ "$OUT" == SOFT\ * ]] && ok \
  || bad "#11 carries no suffix of its own and must still go through verification (got: $OUT)"

# 15c. the number boundary: #1 must not read #11's suffix as its own.
rm -rf "$T/state/dep-verify"
echo '{"body":"## Scope\nBlocked-by: #1, #11 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 20 1)
[[ "$OUT" == HARD\ * ]] && bad "#1 must not inherit #11's suffix (got: $OUT)" || ok
OUT=$(run 20 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "a (hard) after a shorter number is still #11's hatch (got: $OUT)"

# 15d. the same line read as a MARKER, through section 14's cheap-list child:
# a (hard) anywhere on the line disqualifies the deterministic-list SOFT.
rm -rf "$T/state/dep-verify"
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\n' > "$CPD/planned-files.txt"
echo '{"body":"## Scope\nBlocked-by: #11, #12 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == UNKNOWN\ * ]] && grep -q 'marker' <<<"$OUT" && ok \
  || bad "a (hard) on the second blocker of the line is still a marker (got: $OUT)"
rm -rf "$T/state/dep-verify"
echo '{"body":"## Scope\nBlocked-by: #11 (hard), #12 (hard)\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == HARD\ * ]] && ok || bad "#11's own suffix outranks the cheap list (got: $OUT)"
rm -rf "$T/state/dep-verify"
echo '{"body":"## Scope\nBlocked-by: #11, #12\n"}' > "$T/issue-body.json"
OUT=$(run 80 11)
[[ "$OUT" == SOFT\ * ]] && ok \
  || bad "a multi-blocker line with no suffix anywhere must invent no marker (got: $OUT)"

echo "dep-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
