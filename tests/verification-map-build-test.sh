#!/bin/bash
# tests/verification-map-build-test.sh — the verification-map index is generated,
# and these are the properties that keep it honest after this commit.
#
# BH-798. docs/verification-map/README.md was hand-edited by every build that
# added a feature entry, and it showed: the committed table had a stray blank
# line in the middle of it, which splits a markdown table in two. Worse, two
# builds that both add a row edit the same line range of the same file, so every
# concurrent pair conflicts on a file neither of them cares about.
#
# The fix is the usual one: the README stops being a source and becomes an
# artifact. `bin/verification-map-build.sh` concatenates
# `docs/verification-map/index/head.md`, a table built from
# `docs/verification-map/entries/<TICKET-KEY>.md`, and
# `docs/verification-map/index/tail.md`. A build writes its own entry file; the
# script writes the README.
#
# WHAT THESE ASSERTIONS ARE WORTH. Every case drives the REAL script with
# `--repo <fixture>` — there is no copy of the logic in here — and asserts on the
# BYTES of the generated README, its exit codes, and the primer another script
# renders from it. The four that carry the weight:
#
#   1. sort order is natural, not lexical: BH-999 must come before BH-1000, or
#      the table reshuffles itself the day a key crosses a power of ten.
#   2. `--check` NEVER writes. It is the CI step; a check that repairs what it
#      was asked to report makes the problem invisible. Since BH-1175 it
#      validates the committed SOURCES (every entry parses, no two produce the
#      same row, every document link resolves, no README is tracked) instead of
#      comparing bytes against a committed index — there is no committed index.
#   3. a malformed entry aborts with the README untouched. A generator that can
#      leave a half-written index is worse than no generator.
#   4. the neighbours stay unaffected: `bin/verification-map.sh` counts feature
#      entries with `find -maxdepth 1 -type f`, so the sources live in
#      SUBDIRECTORIES or every build's primer quotes an entry count that is wrong
#      by the number of sources; and `docs/verification-map/index/tail.md` must
#      CARRY the `generated files` heading and its one row, because that heading
#      is what arms `bin/batch-resolve.sh`'s regen table for this repo (BH-865
#      reversed the BH-798 pin here on purpose — the lane is meant to be on now;
#      BH-1175 moved the table's home from the generated README to the source it
#      was always generated from, since the README left git).
#
# Run from anywhere: bash tests/verification-map-build-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
VMB="$DIR/bin/verification-map-build.sh"
VM="$DIR/bin/verification-map.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$VMB" ] && ok || bad "bin/verification-map-build.sh is missing or not executable"

# ── the fixture repo ─────────────────────────────────────────────────────────
# Keys chosen so lexical and natural sort DISAGREE: lexically BH-1000 sorts
# before BH-7 and BH-999; naturally it sorts last.
R="$T/repo"; MAP="$R/docs/verification-map"
mkdir -p "$MAP/index" "$MAP/entries"
printf '%s\n' \
  '# Verification map — demo' \
  '' \
  'Head prose that must survive generation, above the table.' > "$MAP/index/head.md"
printf '%s\n' \
  '## Driving conventions' \
  '' \
  '- **Drive the real script, never a paraphrase of it.**' > "$MAP/index/tail.md"
printf '%s\n' '| Seven | [seven.md](seven.md) | `bin/seven.sh` |' > "$MAP/entries/BH-7.md"
printf '%s\n' \
  '| Nine A | [nine-a.md](nine-a.md) | `bin/nine.sh` |' \
  '| Nine B | [nine-b.md](nine-b.md) | `bin/nine.sh` |' > "$MAP/entries/BH-999.md"
printf '%s\n' '| Thousand | [thousand.md](thousand.md) | `bin/thousand.sh` |' > "$MAP/entries/BH-1000.md"
# A real feature entry at the top level: this is what bin/verification-map.sh
# counts, and what must still be the ONLY thing it counts (case 6).
printf '%s\n' '# Billing' '' '**What it is:** a fixture feature entry.' > "$MAP/billing.md"
# The documents the rows above LINK to. --check resolves every link since
# BH-1175, so a fixture whose rows point at nothing would fail for its own
# shape rather than for the behaviour under test.
for d in seven nine-a nine-b thousand; do
  printf '%s\n' "# $d" > "$MAP/$d.md"
done

README="$MAP/README.md"
rows() { awk '/^\|-/{f=1;next} f && /^\| /{print}' "$1" 2>/dev/null; }
lineno() { grep -n -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

# ── 1. generate ──────────────────────────────────────────────────────────────
OUT=$("$VMB" --repo "$R" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "generate must exit 0 on a well-formed map (got $RC: $OUT)"
[ -s "$README" ] && ok || bad "generate must write $MAP/README.md"

head -1 "$README" 2>/dev/null | grep -q '^> \*\*GENERATED — do not edit by hand' \
  && ok || bad "line 1 of the generated README must be the GENERATED banner (got: $(head -1 "$README" 2>/dev/null))"
# The banner is worth nothing if it does not say what to run instead.
grep -q 'bin/verification-map-build.sh' "$README" \
  && ok || bad "the banner must name the script that regenerates the README"
grep -q 'entries/' "$README" \
  && ok || bad "the banner must tell the next build where its own entry file goes"

WANT=$(printf '%s\n' \
  '| Seven | [seven.md](seven.md) | `bin/seven.sh` |' \
  '| Nine A | [nine-a.md](nine-a.md) | `bin/nine.sh` |' \
  '| Nine B | [nine-b.md](nine-b.md) | `bin/nine.sh` |' \
  '| Thousand | [thousand.md](thousand.md) | `bin/thousand.sh` |')
GOT=$(rows "$README")
[ "$GOT" = "$WANT" ] && ok || bad "rows must be BH-7, BH-999 (both, in file order), BH-1000 — natural sort, not lexical. Got:
$GOT"

# The stable header and the conventions must bracket the table, or the renderer
# that extracts '## Driving conventions' by heading loses it.
H=$(lineno "$README" 'Head prose that must survive generation'); S=$(lineno "$README" '^|-'); C=$(lineno "$README" '^## Driving conventions')
if [ -n "$H" ] && [ -n "$S" ] && [ -n "$C" ] && [ "$H" -lt "$S" ] && [ "$C" -gt "$S" ]; then ok
else bad "head.md must precede the table and index/tail.md must follow it (head=$H sep=$S conventions=$C)"; fi

cp "$README" "$T/first"
"$VMB" --repo "$R" >/dev/null 2>&1
cmp -s "$T/first" "$README" && ok || bad "generation must be stable: a second run changed the README"

# ── 2. --check never writes, and validates SOURCES rather than bytes ─────────
# WHAT CHANGED AND WHY (BH-1175). This case used to assert that a HAND-EDITED
# README makes --check exit 1 — the drift check. The README is no longer
# committed, so there is no committed copy to drift from and a hand edit cannot
# survive the next regenerate: the property that assertion bought is now bought
# by the file's absence from git, which tests/verification-map-no-commit-test.sh
# pins directly (NC-2, NC-3). The assertion is REPLACED, not dropped: --check
# still must never write, and it must still exit 1 — on a bad SOURCE, which is
# the failure that is still reachable.
cp "$README" "$T/before-check"
OUT=$("$VMB" --check --repo "$R" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "--check on well-formed sources must exit 0 (got $RC: $OUT)"
cmp -s "$T/before-check" "$README" && ok || bad "--check rewrote the README on a clean tree"

HAND='| Hand edited | [hand.md](hand.md) | `bin/hand.sh` |'
printf '%s\n' "$HAND" >> "$README"
OUT=$("$VMB" --check --repo "$R" 2>&1); RC=$?
[ "$RC" = 0 ] && ok \
  || bad "a hand-edited README is not a --check failure any more: the file is generated and ignored, and the next regenerate erases the edit (got $RC: $OUT)"
grep -qF "$HAND" "$README" \
  && ok || bad "--check must never write: the hand-edited row is gone, so --check repaired the file it was asked to report on"
"$VMB" --repo "$R" >/dev/null 2>&1   # back to generated
grep -qF "$HAND" "$README" \
  && bad "the regenerate must erase a hand edit — that is what replaces the old drift assertion" || ok

# 2b. a DUPLICATE ROW across two entry files. The union merge driver produced
# exactly this on a squash merge and it turned main red three times on
# 2026-09-20; a byte comparison never saw it, because a duplicated row
# regenerates to itself.
cp "$MAP/entries/BH-7.md" "$MAP/entries/BH-70.md"
OUT=$("$VMB" --check --repo "$R" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "--check must exit 1 when two entry files produce the same row (got $RC: $OUT)"
grep -q 'BH-70.md' <<<"$OUT" && grep -q 'BH-7.md' <<<"$OUT" \
  && ok || bad "the duplicate-row message must name BOTH entry files. Got: $OUT"
rm -f "$MAP/entries/BH-70.md"

# 2c. a document link that resolves to nothing. The index is a table of links.
printf '%s\n' '| Nowhere | [nowhere.md](nowhere.md) | `bin/nowhere.sh` |' > "$MAP/entries/BH-71.md"
OUT=$("$VMB" --check --repo "$R" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "--check must exit 1 on an entry whose document link resolves to nothing (got $RC: $OUT)"
grep -q 'nowhere.md' <<<"$OUT" \
  && ok || bad "the dead-link message must name the missing document. Got: $OUT"
rm -f "$MAP/entries/BH-71.md"
OUT=$("$VMB" --check --repo "$R" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "--check must pass again once the bad entry is gone (got $RC: $OUT)"

# ── 3. a malformed entry aborts, README untouched ────────────────────────────
cp "$README" "$T/before-bad"
printf '%s\n' 'not a row' > "$MAP/entries/BH-8.md"
OUT=$("$VMB" --repo "$R" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a non-table line in an entry file must exit 2 (got $RC: $OUT)"
grep -q 'BH-8.md:1' <<<"$OUT" && ok || bad "the malformed-entry message must name file:line (got: $OUT)"
cmp -s "$T/before-bad" "$README" && ok || bad "a refused generation must leave the README byte-identical"
rm -f "$MAP/entries/BH-8.md"

# ── 4. missing sources ───────────────────────────────────────────────────────
cp "$README" "$T/before-missing"
mv "$MAP/entries" "$T/entries-away"
OUT=$("$VMB" --repo "$R" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a missing entries/ directory must exit 2 (got $RC: $OUT)"
grep -q 'entries' <<<"$OUT" && ok || bad "the missing-entries message must name entries/ (got: $OUT)"
cmp -s "$T/before-missing" "$README" && ok || bad "a missing entries/ must leave the README untouched"
mv "$T/entries-away" "$MAP/entries"

mv "$MAP/index/head.md" "$T/head-away"
OUT=$("$VMB" --repo "$R" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a missing index/head.md must exit 2 (got $RC: $OUT)"
grep -q 'head.md' <<<"$OUT" && ok || bad "the missing-head message must name index/head.md (got: $OUT)"
cmp -s "$T/before-missing" "$README" && ok || bad "a missing index/head.md must leave the README untouched"
mv "$T/head-away" "$MAP/index/head.md"

# ── 5. the production data: exactly what CI's lint step runs ─────────────────
# Since BH-1175 this validates the SOURCES (parse, no duplicate row, every link
# resolves, no tracked README) rather than comparing bytes against a committed
# index. It is still the same command CI runs, on the same data.
OUT=$("$VMB" --check --repo "$DIR" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "this repo's own verification-map sources must validate — the CI step (got $RC: $OUT)"

# ── 6. the neighbours ────────────────────────────────────────────────────────
# bin/verification-map.sh counts feature entries with find -maxdepth 1 -type f.
# If the sources ever move up to the map root, every primer's entry count and
# listing gains four files that are not features.
mkdir -p "$T/h/state"
HARNESS="$T/h" "$VM" render demo-os --repo "$R" >/dev/null 2>&1
PRIMER="$T/h/state/demo-os-context.md"
LIST=$(awk '/^FEATURE ENTRIES \(/{f=1;next} /^Read the entry for the feature/{f=0} f' "$PRIMER" 2>/dev/null)
grep -q 'billing.md' <<<"$LIST" && ok || bad "the primer's FEATURE ENTRIES listing must still carry real entries (got: $LIST)"
if grep -qE 'head\.md|tail\.md|entries|index' <<<"$LIST"; then
  bad "the primer listed a generator SOURCE as a feature entry — the sources must stay in subdirectories. Got:
$LIST"
else ok; fi

# bin/batch-resolve.sh arms its batch train for a repo that declares a
# "generated files" table under a HEADING. BH-798 pinned that heading OUT,
# because arming the merge lane was a non-goal there. BH-865 arms it on purpose,
# so the pin is REVERSED, not deleted.
#
# WHAT CHANGED AND WHY (BH-1175). These two assertions used to read the
# COMMITTED README. That file is gone from git, and `git show <ref>:<path>`
# answers nothing for a path that is not in the tree — so the table's home is
# now the file it was always generated FROM, docs/verification-map/index/tail.md,
# which both parsers read since this ticket. The assertion is MOVED to that
# file, not dropped: if the heading or the row leaves it, the batch merge train
# turns itself off for this repo, silently, and that is what these two lines
# exist to prevent. tests/verification-map-no-commit-test.sh NC-4 drives the
# real mc_regen_table over a tree with no committed README to prove the parser
# half.
PROD_TABLE="$DIR/docs/verification-map/index/tail.md"
grep -qiE '^#+[[:space:]]*.*generated files' "$PROD_TABLE" \
  && ok || bad "docs/verification-map/index/tail.md carries no 'generated files' HEADING — bin/batch-resolve.sh's regen table for cromford is empty and the train is off (BH-865/BH-1175)"
grep -qF '| `docs/verification-map/README.md` | `bin/verification-map-build.sh` |' "$PROD_TABLE" \
  && ok || bad "docs/verification-map/index/tail.md must declare the README → bin/verification-map-build.sh regenerate row (BH-865/BH-1175)"
# That the GENERATED index still carries that table (for a reader of the public
# mirror) is pinned by GT-1 in tests/generated-files-train-test.sh, which
# generates into a scratch repository. It is not re-asserted here, because
# generating into $DIR would be a test writing into the real checkout.

echo "verification-map-build: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
