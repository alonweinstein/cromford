#!/bin/bash
# tests/br-suite-partition.bh-1196-test.sh — the partition contract for BH-1196:
# tests/blocked-resolver-test.sh was a 2,342-line monolith with 18 numbered
# sections, and its sections moved WHOLE and VERBATIM into seven
# tests/br-<concern>-test.sh suites.
#
# WHY THIS TEST EXISTS. A split is the one refactor whose failure mode is
# silence: a section that gets dropped on the way out of the old file takes its
# assertions with it, every remaining suite stays green, and nothing anywhere
# says a claim stopped being checked. So the move is judged by NUMBERS taken
# from the old file BEFORE anything moved — tests/br/expected-sections.tsv,
# generated from the monolith on the merge base — and re-counted on the new
# files here. Every section exists in exactly ONE new suite, with the same
# count of `ok` and `bad` command words, and the totals match (180 / 391).
#
# HOW IT MEASURES. One counter, count_sections below, used for both sides: the
# manifest was produced by it and every assertion here re-runs it. A section is
# a `# <id>. ` line IMMEDIATELY after a `# =====` rule line, so a numbered list
# inside a comment block is never a section and `# ---- 10a.` sub-headers are
# not sections. `ok` and `bad` count as COMMAND WORDS only (start of line, or
# after `;`, `&`, `|`, `{`), so `"ok":true` in a stub's JSON and the words
# inside a message string never count. Case 8 proves the counter can go red by
# deleting one real `&& ok || bad` opener from a scratch copy, and case 9 feeds
# it a fixture of nothing but the four negatives and demands 0 / 0 — a counter
# that counted everything, or nothing, would pass neither.
#
# WHAT IT DOES NOT CLAIM. It says nothing about whether the moved assertions
# still hold; that is each new suite's own run, and the thin runner's summary.
# Run from anywhere: tests/br-suite-partition.bh-1196-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MANIFEST="$DIR/tests/br/expected-sections.tsv"
MONOLITH="$DIR/tests/blocked-resolver-test.sh"

# The counter. Identical to the one the manifest was generated with (BH-1196);
# it is the single definition of "a section" and of "an assertion opener" that
# both sides of this test agree on.
count_sections() { # count_sections <suite>  -> "<id>\t<ok>\t<bad>" per numbered section
  awk '
    prev_rule && /^# [0-9]+[a-z]*\. / { if (sec != "") printf "%s\t%d\t%d\n", sec, o, b; sec = $2; o = 0; b = 0 }
    { prev_rule = ($0 ~ /^# =====/) }
    /^[[:space:]]*#/ { next }
    { o += gsub(/(^|[;&|{] *)ok( *([;&|}]|$))/, "&"); b += gsub(/(^|[;&|{] *)bad( *([;&|}]|$)| ")/, "&") }
    END { if (sec != "") printf "%s\t%d\t%d\n", sec, o, b }' "$1"
}

rows()   { grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$'; }
suites() { rows | cut -f1 | sort -u; }

# ---- case group 1: the manifest itself parses --------------------------------
NROWS=$(rows | wc -l)
[ "$NROWS" -ge 1 ] && ok || bad "the manifest must carry at least one row (got $NROWS from $MANIFEST)"
SHAPE=$(rows | awk -F'\t' 'NF != 4 || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $1 !~ /^tests\// { print NR": "$0 }')
[ -z "$SHAPE" ] && ok || bad "every manifest row is <suite under tests/><TAB><section><TAB><ok><TAB><bad>: $SHAPE"

# ---- case group 2: every suite the manifest names is a real, sane suite -------
for s in $(suites); do
  if [ -f "$DIR/$s" ]; then ok; else bad "the manifest names $s but no such file exists"; continue; fi
  bash -n "$DIR/$s" 2>/dev/null && ok || bad "$s does not parse (bash -n)"
  grep -q 'lib/scratch.sh" || exit 1' "$DIR/$s" && ok \
    || bad "$s must source tests/lib/scratch.sh with a same-line handler (bin/test-sources-lint.sh's shape)"
done

# ---- case group 3: each suite's sections are EXACTLY its manifest rows --------
for s in $(suites); do
  [ -f "$DIR/$s" ] || { bad "cannot count sections of missing suite $s"; continue; }
  WANT=$(rows | awk -F'\t' -v s="$s" '$1 == s { printf "%s\t%s\t%s\n", $2, $3, $4 }' | sort)
  GOT=$(count_sections "$DIR/$s" | sort)
  if [ "$WANT" = "$GOT" ]; then ok; else
    bad "$s: sections/counts differ from the manifest (want -> got):
$(diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") || true)"
  fi
done

# ---- case group 4: every section lives in exactly ONE suite -------------------
for id in $(rows | cut -f2); do
  IDRE=${id//./\\.}
  WHERE=""; N=0
  for s in $(suites); do
    [ -f "$DIR/$s" ] || continue
    C=$(grep -c "^# ${IDRE} " "$DIR/$s" || true)
    if [ "$C" -gt 0 ]; then WHERE="$WHERE $s($C)"; N=$((N + C)); fi
  done
  [ "$N" -eq 1 ] && ok || bad "section $id must have exactly one header across the manifest's suites (found $N:${WHERE:- nowhere})"
done

# ---- case group 5: the totals, as numbers ------------------------------------
WANT_TOT=$(rows | awk -F'\t' '{o+=$3;b+=$4} END{printf "%d %d\n", o, b}')
GOT_TOT=$(for s in $(suites); do [ -f "$DIR/$s" ] && count_sections "$DIR/$s"; done \
          | awk -F'\t' '{o+=$2;b+=$3} END{printf "%d %d\n", o+0, b+0}')
[ "$WANT_TOT" = "$GOT_TOT" ] && ok \
  || bad "the ok/bad totals over the new suites must equal the manifest's (manifest: $WANT_TOT, suites: $GOT_TOT)"

# ---- case group 6: the name-pinned entry point still runs every suite ---------
LIST=$(bash "$MONOLITH" --list 2>/dev/null | sort -u)
[ "$LIST" = "$(suites)" ] && ok \
  || bad "tests/blocked-resolver-test.sh --list must print exactly the manifest's suites (got: $(printf '%s' "$LIST" | tr '\n' ' '))"

# ---- case group 7: nothing is left behind in the old file --------------------
LEFT=$(count_sections "$MONOLITH")
[ -z "$LEFT" ] && ok || bad "tests/blocked-resolver-test.sh must carry no numbered section any more (found: $(printf '%s' "$LEFT" | tr '\n' ' '))"
LEFTC=$(awk '/^[[:space:]]*#/ { next }
             { o += gsub(/(^|[;&|{] *)ok( *([;&|}]|$))/, "&"); b += gsub(/(^|[;&|{] *)bad( *([;&|}]|$)| ")/, "&") }
             END { printf "%d %d\n", o+0, b+0 }' "$MONOLITH")
[ "$LEFTC" = "0 0" ] && ok || bad "tests/blocked-resolver-test.sh must carry no ok/bad command word any more (got $LEFTC)"

# ---- case group 8: the counter can go RED (D3) -------------------------------
# One real opener is deleted from a scratch copy of the first manifest suite and
# the same comparison is re-run: it must differ, and differ by exactly one ok
# and one bad, so a counter that matched everything or nothing fails here.
MSUITE=$(rows | head -1 | cut -f1)
if [ -f "$DIR/$MSUITE" ]; then
  cp "$DIR/$MSUITE" "$T/mutated.sh"
  sed -i '0,/&& ok || bad/{/&& ok || bad/d}' "$T/mutated.sh"
  BEFORE=$(count_sections "$DIR/$MSUITE" | awk -F'\t' '{o+=$2;b+=$3} END{printf "%d %d\n", o+0, b+0}')
  AFTER=$(count_sections "$T/mutated.sh"   | awk -F'\t' '{o+=$2;b+=$3} END{printf "%d %d\n", o+0, b+0}')
  [ "$BEFORE" != "$AFTER" ] && ok || bad "deleting an opener from $MSUITE must change the counts (both $BEFORE)"
  EXPECT=$(printf '%s' "$BEFORE" | awk '{printf "%d %d\n", $1-1, $2-1}')
  [ "$AFTER" = "$EXPECT" ] && ok || bad "deleting one '&& ok || bad' opener must cost exactly one ok and one bad (before $BEFORE, after $AFTER, expected $EXPECT)"
else
  bad "cannot run the counter mutation: the manifest's first suite $MSUITE does not exist"
  bad "cannot run the counter delta check: the manifest's first suite $MSUITE does not exist"
fi

# ---- case group 9: the counter's negatives -----------------------------------
# Everything in section 1. of this fixture is a shape that must NOT count; the
# opener in section 2. is the positive control on the same file, so "0 0" cannot
# be the answer of a counter that simply matches nothing.
cat > "$T/negatives.sh" <<'NEG'
#!/bin/bash
# ============================================================================
# 1. nothing below this header is an assertion opener
# ============================================================================
# a comment that says ok and says bad "with a quote right after it"
printf '%s' '{"ok":true,"bad":"no"}' > /dev/null
MSG="the run went bad in a way this string describes"
NOTE='ok'
# ---- 10a. a sub-header is not a section
echo "# 3. a numbered line that follows no rule line is not a section"
# ============================================================================
# 2. the positive control
# ============================================================================
true && ok || bad "one opener, counted once"
NEG
NEGOUT=$(count_sections "$T/negatives.sh")
[ "$(printf '%s\n' "$NEGOUT" | awk -F'\t' '$1=="1." {print $2, $3}')" = "0 0" ] && ok \
  || bad "the counter must score the negatives fixture's section 1. as 0 0 (got: $(printf '%s' "$NEGOUT" | tr '\n' ' '))"
[ "$(printf '%s\n' "$NEGOUT" | awk -F'\t' '$1=="2." {print $2, $3}')" = "1 1" ] && ok \
  || bad "the counter must score the negatives fixture's one real opener as 1 1 (got: $(printf '%s' "$NEGOUT" | tr '\n' ' '))"

echo "br-suite-partition.bh-1196-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
