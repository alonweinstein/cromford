#!/bin/bash
# tests/operating-doc.bh-5289-test.sh — BH-5289: docs/OPERATING.md, the
# operator's lessons-and-defaults page, exists, carries every lesson group the
# ticket names, is linked from the README, the install guide, AGENTS.md and
# both CONTRIBUTING files, says nothing about a fleet (bin/share/leakcheck.py,
# the same scan the public copy runs as tests/no-client-identifiers-test.sh),
# and the two builder prompts point at it.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/operating-doc.bh-5289-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OP="$DIR/docs/OPERATING.md"

# O1 the doc exists
if [ -f "$OP" ]; then ok; else
  bad "O1 docs/OPERATING.md does not exist"
  echo "operating-doc.bh-5289: PASS=$PASS FAIL=$FAIL"; exit 1
fi

# O2 every lesson group is its own section, in the ticket's order, and the
# Defaults table closes the page
HEADS=$(grep -E '^## ' "$OP")
WANT='## Merge throughput
## Review throughput
## Builds
## Conflicts
## Gates vs reports
## Tests
## Operations
## Defaults'
[ "$HEADS" = "$WANT" ] && ok || bad "O2 the ## headings are not exactly the eight lesson groups in order: $(printf '%s' "$HEADS" | tr '\n' '|')"

# Every lesson in the ticket body leaves a trace on the page (case-insensitive,
# fixed strings).
while IFS= read -r kw; do
  [ -n "$kw" ] || continue
  grep -qiF -- "$kw" "$OP" && ok || bad "O2 no lesson mentions '$kw'"
done <<'KW'
merge queue
can affect
separate lanes
culprit
bisect
fix-main-red
timing row
in parallel
backoff
risk
CHANGES_REQUESTED
paginat
pre-push
slot lock
ETag
700
hotspot
fragment
module map
sequence
stacked
changelog
closure helper
reported, not gated
marker
RANDOM`
find
eval
declare
/tmp
box-id
console
WIP limit
HOLD
by pattern
detector
KW

# Each lesson says three things. Count the labels: one per ### lesson.
NLESS=$(grep -cE '^### ' "$OP")
for lab in '**What goes wrong.**' '**What the factory does.**' '**Knob.**'; do
  n=$(grep -cF -- "$lab" "$OP")
  [ "$NLESS" -gt 0 ] && [ "$n" = "$NLESS" ] && ok || bad "O2 $NLESS lessons but $n '$lab' labels"
done

# O3 linked from the README and the install guide
grep -qF '(docs/OPERATING.md)' "$DIR/README.md" && ok || bad "O3 README.md does not link docs/OPERATING.md"
grep -qF 'OPERATING.md' "$DIR/docs/SELF-HOST.md" && ok || bad "O3 docs/SELF-HOST.md does not link OPERATING.md"
# The sanitizer patches this README row byte for byte; the new row must not move it.
grep -qxF '| See the dated notes this README used to be | [docs/CHANGELOG-NOTES.md](docs/CHANGELOG-NOTES.md) |' "$DIR/README.md" \
  && ok || bad "O3 the README row bin/share/sanitize.py patches changed"

# O4 AGENTS.md (public) and both CONTRIBUTING files point at it
for f in bin/share/overlay/AGENTS.md bin/share/overlay/CONTRIBUTING.md CONTRIBUTING.md; do
  if [ ! -f "$DIR/$f" ]; then
    case "$f" in bin/share/*) [ -d "$DIR/bin/share" ] || { ok; continue; } ;; esac
    bad "O4 $f does not exist"; continue
  fi
  grep -qF 'docs/OPERATING.md' "$DIR/$f" && ok || bad "O4 $f does not point at docs/OPERATING.md"
done

# O5 fleet-neutral: no names, no spend figures, no upstream issue numbers
mkdir -p "$T/pub"
cp "$OP" "$T/pub/OPERATING.md"
[ -f "$DIR/bin/share/overlay/AGENTS.md" ] && cp "$DIR/bin/share/overlay/AGENTS.md" "$T/pub/AGENTS.md"
if [ -f "$DIR/bin/share/leakcheck.py" ]; then
  python3 -I "$DIR/bin/share/leakcheck.py" "$T/pub" > "$T/leak.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok || bad "O5 leakcheck rc=$rc on OPERATING.md/AGENTS.md: $(head -5 "$T/leak.out")"
  # Negative control: the same scan over the same copy plus one mapped name
  # must go red, or a green O5 proves nothing.
  name=$(cd "$DIR/bin/share" && python3 -I -c 'import sys; sys.path.insert(0, "."); from mapping import NAME_TOKENS; print(sorted(NAME_TOKENS)[0])' 2>/dev/null)
  if [ -n "$name" ]; then
    mkdir -p "$T/neg"; cp "$T/pub/OPERATING.md" "$T/neg/OPERATING.md"
    printf '\nRun it on %s.\n' "$name" >> "$T/neg/OPERATING.md"
    python3 -I "$DIR/bin/share/leakcheck.py" "$T/neg" --quiet >/dev/null 2>&1; nrc=$?
    [ "$nrc" = 1 ] && ok || bad "O5 negative control: leakcheck rc=$nrc on a copy that names a mapped identifier"
  else
    bad "O5 could not read a NAME_TOKENS entry from bin/share/mapping.py"
  fi
else
  echo "ok O5 leak scan is tests/no-client-identifiers-test.sh in this copy"
fi
if grep -nE '\$[0-9]' "$T"/pub/*.md > "$T/money.out"; then bad "O5 a spend figure: $(head -3 "$T/money.out")"; else ok; fi
if grep -nE '#[0-9]{3,}' "$T"/pub/*.md > "$T/issues.out"; then bad "O5 an issue number: $(head -3 "$T/issues.out")"; else ok; fi

# O6 the builder and planner prompts carry the lessons and link the page
BD="$DIR/prompts/build-discipline.md"; PC="$DIR/prompts/plan-contract.md"
grep -qx '## Added 2026-10-07 (BH-5289)' "$BD" && ok || bad "O6 build-discipline.md has no BH-5289 section"
for r in D47 D48 D49 D50; do
  grep -qE "^- \*\*$r " "$BD" && ok || bad "O6 build-discipline.md has no rule $r"
done
grep -qF 'docs/OPERATING.md' "$BD" && ok || bad "O6 build-discipline.md does not link docs/OPERATING.md"
grep -qF '#5269' "$BD" && ok || bad "O6 build-discipline.md does not link the conflict-discipline section (#5269)"
grep -qx '## 10. Operating lessons (BH-5289)' "$PC" && ok || bad "O6 plan-contract.md has no '## 10. Operating lessons' section"
grep -qF 'docs/OPERATING.md' "$PC" && ok || bad "O6 plan-contract.md does not link docs/OPERATING.md"

echo "operating-doc.bh-5289: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
