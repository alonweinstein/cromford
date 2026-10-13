#!/bin/bash
# tests/review-tier-prisma-folder.bh-1974-test.sh — every schema-risk pattern
# matches Prisma's multi-file layout, prisma/schema/*.prisma (BH-1974).
#
# WHAT WAS WRONG. Every copy of the schema-risk alternation said
# `schema\.prisma`, which only matches a file NAMED schema.prisma. A repo on the
# folder layout (prisma/schema/<domain>.prisma) changed its schema and the diff
# tiered T1, bought neither the security lens nor the refuter, and stayed
# TIER=1 — eligible for tier-1 auto-merge.
#
# WHAT IS PINNED. A diff touching only prisma/schema/scan.prisma gets the same
# review tier, the same lenses and the same merge tier as one touching
# prisma/schema.prisma, through every copy of the pattern:
#   L  bin/lib/review-tier.sh, sourced and called (RT_RISKY_RE / RT_HIGHRISK_RE)
#   D  the driver's RISKY= / HIGHRISK= / PAT= lines, picked out of the rb_all
#      flatten and eval'd verbatim in each fixture
#   R  the dormant stage-module copies in bin/lib/rb/{review,pr}.sh: equal to
#      their driver twins, and eval'd the same way
#   N  ordinary prisma files (seed.ts, a README in the folder, src/lib/prisma.ts,
#      a .prisma.bak outside and inside the folder) are NOT pulled into the
#      schema/money class (the new arm is anchored at .prisma$)
# Every pick must be non-empty: an empty pick is a FAIL, never a skip.
#
# No network, no model call. Fixtures are mktemp git repos under $T.
# Run from anywhere: tests/review-tier-prisma-folder.bh-1974-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten the driver"; exit 1; }
LIB="$DIR/bin/lib/review-tier.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mk_fixture() { # mk_fixture <name> <path> — base commit (README.md) + one change commit touching <path>
  local d="$T/$1"
  git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" checkout -q -b main; }
  echo x > "$d/README.md"
  git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@t commit -qm base
  mkdir -p "$d/$(dirname "$2")"
  echo m > "$d/$2"
  git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@t commit -qm change
}
mk_fixture schema-single prisma/schema.prisma
mk_fixture schema-folder prisma/schema/scan.prisma
mk_fixture schema-nested prisma/schema/scan/runs.prisma
mk_fixture neg-seed      prisma/seed.ts
mk_fixture neg-readme    prisma/schema/README.md
mk_fixture neg-client    src/lib/prisma.ts
mk_fixture neg-bak       prisma/schemas/x.prisma.bak
mk_fixture neg-bak-folder prisma/schema/scan.prisma.bak
POS="schema-single schema-folder schema-nested"
NEG="neg-seed neg-readme neg-client neg-bak neg-bak-folder"

pick() { # pick <file> <substr-a> <substr-b> — the one line of <file> holding both
  # Needles travel through ENVIRON, never `awk -v`: gawk processes -v for escape
  # sequences, so 'schema\.prisma' would arrive as 'schema.prisma' and miss.
  A="$2" B="$3" awk 'index($0,ENVIRON["A"])>0 && index($0,ENVIRON["B"])>0 {print; exit}' "$1"
}
need() { [ -n "$1" ] && ok || bad "$2: pick came back empty"; }

# ============================================================================
# L — the lib classifier, sourced and called
# ============================================================================
lib_tier() { ( cd "$T/$1" && bash -c '. "$1" && review_tier HEAD~1 HEAD' _ "$LIB" 2>/dev/null ); }
SINGLE=$(lib_tier schema-single)
case "$SINGLE" in
  "T2 "*"1 schema/money path(s)"*) ok ;;
  *) bad "L: prisma/schema.prisma baseline should be T2 with 1 schema/money path, got: ${SINGLE:-<empty>}" ;;
esac
FOLDER=$(lib_tier schema-folder)
[ -n "$SINGLE" ] && [ "$FOLDER" = "$SINGLE" ] \
  && ok || bad "L: prisma/schema/scan.prisma must tier exactly like prisma/schema.prisma
    schema.prisma:      ${SINGLE:-<empty>}
    schema/scan.prisma: ${FOLDER:-<empty>}"
NESTED=$(lib_tier schema-nested)
case "$NESTED" in
  "T2 "*"schema/money path(s)"*) ok ;;
  *) bad "L: prisma/schema/scan/runs.prisma must be T2 schema/money, got: ${NESTED:-<empty>}" ;;
esac

# ============================================================================
# D — the driver's production lines, from the flatten, eval'd verbatim
# ============================================================================
RISKY_LINE=$(pick "$RB_ALL" 'RISKY=$(git diff' 'webhook')
HIGH_LINE=$(pick "$RB_ALL" 'HIGHRISK=$(git diff' 'payout')
PAT_LINE=$(pick "$RB_ALL" "PAT='" 'schema\.prisma')
TIER_LINE=$(pick "$RB_ALL" 'TIER=2' '"$PAT" <<<"$CHANGED"')
# The file list PAT is matched against, as the driver captures it.
CHANGED_LINE=$(pick "$RB_ALL" 'CHANGED=$(git diff --name-only' '...HEAD)')
need "$RISKY_LINE" "D/RISKY";  need "$HIGH_LINE" "D/HIGHRISK"
need "$PAT_LINE"   "D/PAT";    need "$TIER_LINE" "D/TIER"
need "$CHANGED_LINE" "D/CHANGED"

run_lines() { # run_lines <fixture> <risky-line> <high-line> <pat-line> <tier-line> -> "RISKY=n HIGHRISK=n TIER=n"
  ( cd "$T/$1" || exit 1
    BASE=HEAD~1; RISKY=; HIGHRISK=; PAT=; CHANGED=; TIER=1
    eval "$CHANGED_LINE"; eval "$2"; eval "$3"; eval "$4"; eval "$5"
    echo "RISKY=$RISKY HIGHRISK=$HIGHRISK TIER=$TIER" )
}
for F in $POS; do
  GOT=$(run_lines "$F" "$RISKY_LINE" "$HIGH_LINE" "$PAT_LINE" "$TIER_LINE")
  [ "$GOT" = "RISKY=1 HIGHRISK=1 TIER=2" ] \
    && ok || bad "D/$F: driver lines must give RISKY=1 HIGHRISK=1 TIER=2 (security lens, refuter, no tier-1 merge), got: ${GOT:-<empty>}"
done

# ============================================================================
# R — the dormant stage-module copies: equal to their twins, and behaving
# ============================================================================
RB_REVIEW="$DIR/bin/lib/rb/review.sh"; RB_PR="$DIR/bin/lib/rb/pr.sh"
R_RISKY=$(pick "$RB_REVIEW" 'RISKY=$(git diff' 'webhook')
R_HIGH=$(pick "$RB_REVIEW" 'HIGHRISK=$(git diff' 'payout')
R_PAT=$(pick "$RB_PR" "PAT='" 'schema\.prisma')
need "$R_RISKY" "R/RISKY"; need "$R_HIGH" "R/HIGHRISK"; need "$R_PAT" "R/PAT"
[ "$R_RISKY" = "$RISKY_LINE" ] && ok || bad "R: rb/review.sh RISKY= has drifted from the driver's
    rb:     $R_RISKY
    driver: $RISKY_LINE"
[ "$R_HIGH" = "$HIGH_LINE" ] && ok || bad "R: rb/review.sh HIGHRISK= has drifted from the driver's
    rb:     $R_HIGH
    driver: $HIGH_LINE"
[ "$R_PAT" = "$PAT_LINE" ] && ok || bad "R: rb/pr.sh PAT= has drifted from the driver's
    rb:     $R_PAT
    driver: $PAT_LINE"
for F in $POS; do
  GOT=$(run_lines "$F" "$R_RISKY" "$R_HIGH" "$R_PAT" "$TIER_LINE")
  [ "$GOT" = "RISKY=1 HIGHRISK=1 TIER=2" ] \
    && ok || bad "R/$F: rb module lines must give RISKY=1 HIGHRISK=1 TIER=2, got: ${GOT:-<empty>}"
done

# ============================================================================
# N — ordinary prisma files stay out of the schema/money class
# ============================================================================
for F in $NEG; do
  OUT=$(lib_tier "$F")
  [ -n "$OUT" ] && ok || bad "N/$F: lib printed nothing"
  case "$OUT" in
    "T2 "*) bad "N/$F: must not be T2, got: $OUT" ;;
    *) ok ;;
  esac
  GOT=$(run_lines "$F" "$RISKY_LINE" "$HIGH_LINE" "$PAT_LINE" "$TIER_LINE")
  [ "$GOT" = "RISKY=0 HIGHRISK=0 TIER=1" ] \
    && ok || bad "N/$F: driver lines must give RISKY=0 HIGHRISK=0 TIER=1, got: ${GOT:-<empty>}"
  GOT=$(run_lines "$F" "$R_RISKY" "$R_HIGH" "$R_PAT" "$TIER_LINE")
  [ "$GOT" = "RISKY=0 HIGHRISK=0 TIER=1" ] \
    && ok || bad "N/$F: rb module lines must give RISKY=0 HIGHRISK=0 TIER=1, got: ${GOT:-<empty>}"
done

echo "review-tier-prisma-folder.bh-1974-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
