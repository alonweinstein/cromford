#!/bin/bash
# tests/generated-path-conflicts-test.sh — the mechanical rung resolves an add/add
# conflict on a GENERATED per-ticket file instead of buying a fresh rebuild, and
# the blocked resolver derives the repo slug and branch from the PR URL so the
# ladder walks mechanical -> fix round -> rebuild in that order.
#
# WHAT THIS PINS (2026-09-16, project-5). Seven of fourteen open PRs were DIRTY.
# The conductor's MERGE_TREE log said the conflicts were add/add on
# docs/build-log/waves/TK-<n>.md and .harness/specs/TK-<n>/plan.md — harness
# output, one file per ticket, carried on a stale base and fighting the sibling
# that merged first. Every one of them walked the resolver ladder to REBUILD
# FRESH ($20-30 and an hour each); TK-1529 was ABANDONED after three.
#
# Two defects, one bill:
#   (a) mc_rebase had no rule for these paths. `*.md` fell to the UNION resolver,
#       which glues two unrelated tickets' documents into one file — so the only
#       honest answer it could give was "conflict".
#   (b) both branch rungs asked fleet-conf for the repo slug and gave up on an
#       empty answer, printing the URL that contains the slug while doing it:
#         "no repo/branch/head for .../pull/1645 — nothing mechanical to try, FIX ROUND"
#         "no repo/branch for   .../pull/1645 — REBUILD FRESH instead"
#       one second apart. Rung 1 and rung 2 could never run; rebuild was the only
#       rung that ever fired.
#
# WHY REAL GIT AND NOT A FAKE. The whole question here is what git's index holds
# during an add/add merge and which stage `checkout --ours/--theirs` takes. A
# fake git that echoes what the test wants would pin nothing at all, so section 1
# builds a real repository, makes a real conflicting merge, and asserts on the
# real bytes left in the tree.
# Run from anywhere: tests/generated-path-conflicts-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The library is sourced against a SCRATCH harness. Nothing in this file may
# read or write /root/harness (tests/*.sh run as root; the 09-15 trap wiped it).
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
cp "$DIR/config/generated-paths.conf" "$T/h/config/"
printf '# only specs here\n.harness/specs/*/\n' > "$T/h/config/specs-only.conf"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init

# ---------------------------------------------------------------------------
# 1. THE ALLOWLIST AND THE TWO KEY DERIVATIONS
# ---------------------------------------------------------------------------
[ "$(mc_generated_globs | wc -l)" = 2 ] || bad "the conf should carry exactly two globs, got: $(mc_generated_globs | tr '\n' ' ')"
[ "$(mc_generated_globs | wc -l)" = 2 ] && ok

for p in docs/build-log/waves/TK-1605.md .harness/specs/TK-1561/plan.md .harness/specs/TK-1561/review.md; do
  mc_path_is_generated "$p" && ok || bad "$p should be on the generated allowlist"
done
# A path off the list is never touched — this is the guard that keeps the rule
# from eating a real conflict in real code.
for p in src/lib/engine/org-blueprint.ts prisma/schema.prisma README.md docs/ARCHITECTURE.md \
         tests/level2-unit/org-blueprint.test.ts .harness/config.json; do
  mc_path_is_generated "$p" && bad "$p must NOT be on the generated allowlist" || ok
done

[ "$(mc_ticket_of_path docs/build-log/waves/TK-1605.md)" = TK-1605 ] && ok || bad "wave doc -> ticket key"
[ "$(mc_ticket_of_path .harness/specs/TK-1561/plan.md)" = TK-1561 ] && ok || bad "spec dir -> ticket key"
[ "$(mc_ticket_of_path docs/build-log/waves/OMY-42.md)" = OMY-42 ] && ok || bad "another project's prefix -> ticket key"
# No key in the path = not ours to resolve. A hand-written index under one of
# these prefixes must survive.
mc_ticket_of_path docs/build-log/waves/README.md >/dev/null 2>&1 \
  && bad "a keyless path must yield no ticket key" || ok

[ "$(mc_ticket_of_branch ticket/TK-1608)" = TK-1608 ] && ok || bad "branch -> ticket key"
[ "$(mc_ticket_of_branch ticket/TK-1481-r3)" = TK-1481 ] && ok || bad "an -rN rebuild branch -> the base ticket key"
[ "$(mc_ticket_of_branch ticket/TK-1608)" = TK-1608 ] && ok || bad "an already-uppercase branch -> ticket key"
for b in design/project-6-prototype mergify/configuration-deprecated-update main; do
  mc_ticket_of_branch "$b" >/dev/null 2>&1 && bad "$b must yield no ticket key" || ok
done

# ---------------------------------------------------------------------------
# 2. A REAL ADD/ADD ON A WAVE DOC, RESOLVED MECHANICALLY
#
# The fixture is PR #1645's shape exactly: branch `ticket/TK-1608`, cut from a
# base that predates TK-1605, carrying its own stale copy of TK-1605's wave doc
# and of TK-1561's plan. main has since taken the real ones.
# ---------------------------------------------------------------------------
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
mkdir -p "$R/src/lib/engine"
echo "base" > "$R/src/lib/engine/org-blueprint.ts"
git -C "$R" add -A; git -C "$R" commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# main: the siblings land first.
mkdir -p "$R/docs/build-log/waves" "$R/.harness/specs/TK-1561"
printf 'MAIN COPY of the TK-1605 wave doc\n' > "$R/docs/build-log/waves/TK-1605.md"
printf 'MAIN COPY of the TK-1561 plan\n'    > "$R/.harness/specs/TK-1561/plan.md"
git -C "$R" add -A; git -C "$R" commit -qm "TK-1605 + TK-1561 land"

# the branch, off the stale base: its OWN artefacts plus fossil copies of theirs.
git -C "$R" checkout -q -b ticket/TK-1608 "$BASE"
mkdir -p "$R/docs/build-log/waves" "$R/.harness/specs/TK-1561" "$R/.harness/specs/TK-1608"
printf 'BRANCH FOSSIL of the TK-1605 wave doc\n' > "$R/docs/build-log/waves/TK-1605.md"
printf 'BRANCH FOSSIL of the TK-1561 plan\n'     > "$R/.harness/specs/TK-1561/plan.md"
printf 'TK-1608 wave doc, this build wrote it\n' > "$R/docs/build-log/waves/TK-1608.md"
printf 'TK-1608 plan, this build wrote it\n'     > "$R/.harness/specs/TK-1608/plan.md"
git -C "$R" add -A; git -C "$R" commit -qm "TK-1608"

git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "the fixture should conflict"
CONF=$(git -C "$R" diff --name-only --diff-filter=U | sort | tr '\n' ' ')
[ "$CONF" = ".harness/specs/TK-1561/plan.md docs/build-log/waves/TK-1605.md " ] && ok \
  || bad "expected an add/add on both siblings' artefacts, got: $CONF"

OUT=$(mc_resolve_conflicts "$R" ticket/TK-1608); RC=$?
[ "$RC" = 0 ] && ok || bad "mc_resolve_conflicts should resolve an all-generated conflict (rc=$RC, left: $OUT)"
[ -z "$OUT" ] && ok || bad "a resolved conflict prints nothing, got: $OUT"
# THEIRS on another ticket's files: main's copy is the real one.
grep -q '^MAIN COPY of the TK-1605' "$R/docs/build-log/waves/TK-1605.md" && ok \
  || bad "another ticket's wave doc must be taken from main: $(head -1 "$R/docs/build-log/waves/TK-1605.md")"
grep -q '^MAIN COPY of the TK-1561' "$R/.harness/specs/TK-1561/plan.md" && ok \
  || bad "another ticket's plan must be taken from main"
# No markers survive, and the merge can actually be committed.
grep -rq '<<<<<<<' "$R/docs" "$R/.harness" && bad "conflict markers were left in the tree" || ok
[ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "paths left unmerged in the index"
git -C "$R" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1 && ok || bad "the resolved merge must commit"
# The branch's OWN artefacts are untouched by any of this.
grep -q 'this build wrote it' "$R/docs/build-log/waves/TK-1608.md" && ok || bad "the branch's own wave doc was lost"

# ---------------------------------------------------------------------------
# 3. OURS ON THIS PR'S OWN TICKET
#
# The build re-ran and rewrote its own wave doc while a copy of it also reached
# main. The BRANCH's copy is the output of the commits under review, so it wins.
# ---------------------------------------------------------------------------
git -C "$R" checkout -q main
printf 'MAIN COPY of the TK-1608 wave doc\n' > "$R/docs/build-log/waves/TK-1608.md"
mkdir -p "$R/.harness/specs/TK-1608"
printf 'MAIN COPY of the TK-1608 plan\n' > "$R/.harness/specs/TK-1608/plan.md"
git -C "$R" add -A; git -C "$R" commit -qm "a stray TK-1608 artefact on main"
git -C "$R" checkout -q ticket/TK-1608
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "section 3 fixture should conflict"
OUT=$(mc_resolve_conflicts "$R" ticket/TK-1608); RC=$?
[ "$RC" = 0 ] && ok || bad "this PR's own artefacts should resolve (rc=$RC, left: $OUT)"
grep -q 'this build wrote it' "$R/docs/build-log/waves/TK-1608.md" && ok \
  || bad "this PR's own wave doc must be taken from the branch: $(head -1 "$R/docs/build-log/waves/TK-1608.md")"
grep -q 'this build wrote it' "$R/.harness/specs/TK-1608/plan.md" && ok \
  || bad "this PR's own plan must be taken from the branch"
git -C "$R" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 3b. THE PARENT-WAVE CASE: "another ticket's file" that carries OUR work
#
# Not every one of these files is strictly one ticket's. project-5's
# docs/build-log/waves/TK-1251.md is a PARENT wave's narrative and each of its
# five children appends a section to it. If the branch has written ITS OWN
# ticket into a file whose name says another ticket, taking main's copy deletes
# this build's output — worse than the conflict it was avoiding. So that case
# stays a real conflict.
# ---------------------------------------------------------------------------
git -C "$R" checkout -q main
printf '# TK-2000 parent wave\n\n## TK-2100 built\n' > "$R/docs/build-log/waves/TK-2000.md"
git -C "$R" add -A; git -C "$R" commit -qm "the parent wave doc, with a sibling's section"
git -C "$R" checkout -q ticket/TK-1608
printf '# TK-2000 parent wave\n\n## TK-1608 built, and this branch is the only copy of that\n' \
  > "$R/docs/build-log/waves/TK-2000.md"
git -C "$R" add -A; git -C "$R" -c commit.gpgsign=false commit -qm "TK-1608 appends to the parent wave"
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "3b fixture should conflict"
mc_resolve_generated "$R" docs/build-log/waves/TK-2000.md TK-1608 \
  && bad "a file carrying this PR's own work must NOT be taken from main" || ok
OUT=$(mc_resolve_conflicts "$R" ticket/TK-1608); RC=$?
# It falls through to the md union rather than being taken from one side, so the
# branch's own paragraph survives either way — what must never happen is a silent
# `--theirs` that drops it.
grep -q 'TK-1608 built, and this branch is the only copy' "$R/docs/build-log/waves/TK-2000.md" && ok \
  || bad "this build's own paragraph was deleted: $(cat "$R/docs/build-log/waves/TK-2000.md")"
git -C "$R" merge --abort >/dev/null 2>&1
# ...and the fossil case is unaffected: main mentions the ticket too (or the
# branch does not), so THEIRS is still taken.
git -C "$R" checkout -q main
printf '# TK-2001 wave\n\nMAIN COPY, mentions TK-1608 as a sibling\n' > "$R/docs/build-log/waves/TK-2001.md"
git -C "$R" add -A; git -C "$R" commit -qm "TK-2001 on main"
git -C "$R" checkout -q ticket/TK-1608
printf '# TK-2001 wave\n\nBRANCH FOSSIL, also mentions TK-1608\n' > "$R/docs/build-log/waves/TK-2001.md"
git -C "$R" add -A; git -C "$R" -c commit.gpgsign=false commit -qm "TK-2001 fossil"
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "3b fossil fixture should conflict"
mc_resolve_generated "$R" docs/build-log/waves/TK-2001.md TK-1608 && ok \
  || bad "main's copy mentions the ticket too, so THEIRS must still be taken"
grep -q 'MAIN COPY' "$R/docs/build-log/waves/TK-2001.md" && ok || bad "THEIRS should have won"
git -C "$R" merge --abort >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 4. ANY OTHER PATH IS STILL A REAL CONFLICT
#
# The rule must not become "the resolver merges whatever it is handed". A
# conflict in real code still goes to the fix round with the FULL list — which is
# that rung's brief.
# ---------------------------------------------------------------------------
git -C "$R" checkout -q main
echo "main's engine change" > "$R/src/lib/engine/org-blueprint.ts"
printf 'MAIN COPY of the TK-1701 wave doc\n' > "$R/docs/build-log/waves/TK-1701.md"
git -C "$R" add -A; git -C "$R" commit -qm "engine + TK-1701"
git -C "$R" checkout -q ticket/TK-1608
echo "the branch's engine change" > "$R/src/lib/engine/org-blueprint.ts"
printf 'BRANCH FOSSIL of the TK-1701 wave doc\n' > "$R/docs/build-log/waves/TK-1701.md"
git -C "$R" add -A; git -C "$R" -c commit.gpgsign=false commit -qm "branch engine change"
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "section 4 fixture should conflict"
OUT=$(mc_resolve_conflicts "$R" ticket/TK-1608); RC=$?
[ "$RC" = 1 ] && ok || bad "a conflict in real code must stay a conflict (rc=$RC)"
grep -q 'src/lib/engine/org-blueprint.ts' <<<"$OUT" && ok || bad "the unresolved list must name the real conflict: $OUT"
grep -q 'docs/build-log/waves/TK-1701.md' <<<"$OUT" && ok \
  || bad "the unresolved list is the FULL conflict list (the fix round's brief): $OUT"
git -C "$R" merge --abort >/dev/null 2>&1

# 4b. A KEYLESS BRANCH TURNS THE WHOLE MECHANISM OFF. Without a ticket key for
# the PR there is no "mine" to compare against, so mc_resolve_generated declines
# and the path falls through to the pre-existing `*.md` union — the same answer
# this branch got before any of this shipped.
git -C "$R" checkout -q -b design/prototype "$BASE" 2>/dev/null
mkdir -p "$R/docs/build-log/waves"
printf 'A PROTOTYPE copy of the TK-1605 wave doc\n' > "$R/docs/build-log/waves/TK-1605.md"
git -C "$R" add -A; git -C "$R" -c commit.gpgsign=false commit -qm proto
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "4b fixture should conflict"
mc_resolve_generated "$R" docs/build-log/waves/TK-1605.md "$(mc_ticket_of_branch design/prototype 2>/dev/null)" \
  && bad "a branch with no ticket key must resolve nothing" || ok
OUT=$(mc_resolve_conflicts "$R" design/prototype); RC=$?
[ "$RC" = 0 ] && ok || bad "4b should still fall through to the md union (rc=$RC)"
grep -q 'A PROTOTYPE copy' "$R/docs/build-log/waves/TK-1605.md" \
  && grep -q 'MAIN COPY' "$R/docs/build-log/waves/TK-1605.md" && ok \
  || bad "4b should be the union of both sides, not one side taken whole"
git -C "$R" merge --abort >/dev/null 2>&1

# 4c. THE ALLOWLIST IS THE CONFIG FILE, not a hardcoded list. Point the library
# at a conf that does NOT list the wave docs and the very same path stops being
# auto-resolved — it falls back to the union, which is what "off" looks like.
git -C "$R" checkout -q ticket/TK-1608
git -C "$R" merge -q --no-edit design/prototype >/dev/null 2>&1 && bad "4c fixture should conflict"
MINE=$(mc_ticket_of_branch ticket/TK-1608)
MC_GENERATED_PATHS_CONF="$T/h/config/specs-only.conf" \
  mc_resolve_generated "$R" docs/build-log/waves/TK-1605.md "$MINE" \
  && bad "a glob removed from the conf must stop being auto-resolved" || ok
# ...and with the shipped conf back, the same path in the same merge IS resolved,
# so the difference is the config file and nothing else.
mc_resolve_generated "$R" docs/build-log/waves/TK-1605.md "$MINE" && ok \
  || bad "the shipped conf must auto-resolve the same path"
grep -q 'A PROTOTYPE copy' "$R/docs/build-log/waves/TK-1605.md" && ok \
  || bad "TK-1605 is not ticket/TK-1608's, so theirs (the merged side) wins"
git -C "$R" merge --abort >/dev/null 2>&1
# ...and with the conf missing entirely the compiled-in default keeps a pool
# machine (which bakes bin/ and not config/) behaving the same.
MC_GENERATED_PATHS_CONF="$T/h/config/does-not-exist.conf" \
  mc_path_is_generated docs/build-log/waves/TK-1605.md && ok \
  || bad "with no conf file the compiled-in default must still match"
MC_GENERATED_PATHS_CONF="$T/h/config/specs-only.conf" \
  mc_path_is_generated docs/build-log/waves/TK-1605.md \
  && bad "a conf file that is present must REPLACE the compiled-in default" || ok

# ---------------------------------------------------------------------------
# 5. THE CONF HAS TO REACH THE BOXES
#
# A config file the lanes read at run time is dead on every box unless both
# propagation planes carry it. This is the project-3 finance-tables lesson in another
# shape: a thing that ships as a file somebody has to copy by hand has not
# shipped. The compiled-in default is the safety net, not the mechanism.
# ---------------------------------------------------------------------------
grep -q 'CHECKOUT/config' "$DIR/bin/harness-sync.sh" && ok \
  || bad "bin/harness-sync.sh must rsync config/ onto the box"
grep -q 'config/' <<<"$(grep '^FLEET_PATHS=' "$DIR/bin/lib/fleet-paths.sh")" && ok \
  || bad "bin/lib/fleet-paths.sh's FLEET_PATHS must list config/ or a conf change never propagates"
# The compiled-in default and the shipped conf must not drift: the library says
# they are the same two entries, so assert it rather than trusting the comment.
DEFAULT=$(MC_GENERATED_PATHS_CONF="$T/no-such.conf" mc_generated_globs | sort)
SHIPPED=$(MC_GENERATED_PATHS_CONF="$DIR/config/generated-paths.conf" mc_generated_globs | sort)
[ "$DEFAULT" = "$SHIPPED" ] && ok \
  || bad "MC_GENERATED_PATHS_DEFAULT has drifted from config/generated-paths.conf: [$DEFAULT] vs [$SHIPPED]"

echo "generated-path-conflicts: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
