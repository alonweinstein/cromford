#!/bin/bash
# tests/config-inventory.bh-1530-test.sh — BH-1530: the five round-2 review
# residuals (R2-N1..N5) of #1514 plus the one-file-one-slice regrouping.
#
# The 1511 suite pins the classification rules that shipped; this one pins the
# five places that review said they still get the wrong answer, plus the
# slicing invariant the ticket asks for. Every section drives the PRODUCTION
# entry point (bash bin/config-inventory.sh) over a fixture tree and reads the
# ANSWER out of inventory.json with jq — never a regex over the generator's
# own source (section 8 is the one exception, and it pins a doc sentence
# exists, not behaviour).
#
# Each section was RED against a34a2b2 before its fix landed:
#   1  R2-N2  a same-line self-init swallowed the real assignment
#   2  R2-N3  #1510 deferral caught CI runners and a claude-auth file path
#   3  R2-N4  a production local a test also sets was TEST_HOOK, not PLUMBING
#   4  R2-N4  an empty-default knob with an in-code fallback read as a seam
#   5  R2-N1  URL-defaults / bare api_get missed; display links counted as calls
#   6         one file in up to 9 slices (parallel conversion PRs would conflict)
#   7         the inventory of THIS tree still carries every one of those answers
#   8  R2-N5  the context/output names slice authors must drop on sight
#
# Section 7 is a HARD fail: it pins this ticket's outcome on a fresh render of
# this tree (the inventory is generated and git-ignored since BH-5518, so there
# is no committed artifact), and a later bin/ edit that re-breaks one of these
# is exactly what the ticket wants caught.
#
# Run from anywhere: tests/config-inventory.bh-1530-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

run_gen() { bash "$DIR/bin/config-inventory.sh" "$@"; }

# ── shared fixture tree for sections 1-5 ─────────────────────────────────────
FX="$T/fixture"
OUT="$T/out"
mkdir -p "$FX/bin/lib" "$FX/tests"

cls()  { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.class' "$OUT/inventory.json"; }
rule() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.rule' "$OUT/inventory.json"; }
defr() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.deferred_to_1510' "$OUT/inventory.json"; }

# ══ 1. R2-N2: the self-init skip applies only to the self-init assignment ════
# `X=$(cmd); X="${X:-0}"` has TWO assignments of X on one line: a real one and
# the self-init. Dropping both (the a34a2b2 behaviour) loses the evidence that
# X is a computed local, and 15 real locals (BEFORE, VCUR, DEFER, LN0 …) filed
# as settings-row candidates because of it.
cat > "$FX/bin/fixture-sameline.sh" <<'SH'
#!/bin/bash
FIXTURE_SAMELINE_LOCAL=$(wc -l < /etc/hostname); FIXTURE_SAMELINE_LOCAL="${FIXTURE_SAMELINE_LOCAL:-0}"
echo "$FIXTURE_SAMELINE_LOCAL"
SH
# Negative: a PURE self-init on its own line is the knob-declaration idiom and
# must stay CONFIG — the whole reason the skip exists.
cat > "$FX/bin/fixture-pure-selfinit.sh" <<'SH'
#!/bin/bash
FIXTURE_PURE_SELFINIT="${FIXTURE_PURE_SELFINIT:-5}"
echo "$FIXTURE_PURE_SELFINIT"
SH
# Negative: `local X=${X:-3}` is ONE assignment and ONE self-init — still pure.
cat > "$FX/bin/fixture-local-selfinit.sh" <<'SH'
#!/bin/bash
fixture_fn() {
  local FIXTURE_LOCAL_SELFINIT=${FIXTURE_LOCAL_SELFINIT:-3}
  echo "$FIXTURE_LOCAL_SELFINIT"
}
fixture_fn
SH

# ══ 2. R2-N3: CI runners and a claude-auth path are not #1510's ══════════════
cat > "$FX/bin/fixture-runners.sh" <<'SH'
#!/bin/bash
A="${FIXTURE_CI_RUNNERS_LABEL:-ubuntu-latest}"
B="${FIXTURE_BATCH_CI_RUNNERS:-2}"
C="${FIXTURE_SUITE_RUNNER_LABEL:-self-hosted}"
D="${FIXTURE_DOWN_FILE:-$H/state/claude-auth-down.txt}"
E="${RUNNER_TEMP:-/tmp}"
echo "$A $B $C $D $E"
SH
# Positives: a real model id, a _MODEL name and a RUNNER segment still defer.
cat > "$FX/bin/fixture-still-deferred.sh" <<'SH'
#!/bin/bash
E="${FIXTURE_X_MODEL:-}"
F="${FIXTURE_RUNNER_EVAL:-}"
G="${FIXTURE_STAGE:-claude-opus-5}"
I="${FIXTURE_GPT:-gpt-6}"
echo "$E $F $G $I"
SH

# ══ 3. R2-N4 (locals): a name the reading file assigns is never TEST_HOOK ════
cat > "$FX/bin/fixture-local-testset.sh" <<'SH'
#!/bin/bash
FIXTURE_LOCAL_TESTSET=$(date +%s)
echo "${FIXTURE_LOCAL_TESTSET:-}"
SH
cat > "$FX/tests/fixture-local-testset-test.sh" <<'SH'
#!/bin/bash
FIXTURE_LOCAL_TESTSET=1 bash bin/fixture-local-testset.sh
SH
# Negative: a genuine seam — read with an empty default, never assigned by
# production code, set only by a test — stays TEST_HOOK.
cat > "$FX/bin/fixture-seam.sh" <<'SH'
#!/bin/bash
V="${FIXTURE_TEST_SEAM:-}"
echo "$V"
SH
cat > "$FX/tests/fixture-seam-test.sh" <<'SH'
#!/bin/bash
FIXTURE_TEST_SEAM=1 bash bin/fixture-seam.sh
SH

# ══ 4. R2-N4 (knobs): an empty default whose real default lives in code ══════
cat > "$FX/bin/fixture-fallback-shapes.sh" <<'SH'
#!/bin/bash
TICKS=$(br_knob_num FIXTURE_HELPER_TICKS "${FIXTURE_HELPER_TICKS:-}" 12)
case "${FIXTURE_CASE_SECS:-}" in
  ''|*[!0-9]*) SECS=45 ;;
  *) SECS=$FIXTURE_CASE_SECS ;;
esac
[ -n "${FIXTURE_ISNOT_MAX:-}" ] \
  || echo "FIXTURE_ISNOT_MAX='${FIXTURE_ISNOT_MAX:-}' is not a whole number — treating as 600 (the default)"
echo "$TICKS $SECS"
SH
# Negatives: a plain equality compare is how a genuine seam is read too, and a
# helper handed a `$X` EXPANSION (not the `${X:-` form) is not knob evidence.
cat > "$FX/bin/fixture-fallback-negatives.sh" <<'SH'
#!/bin/bash
[ "${FIXTURE_EQ_SEAM:-}" = 1 ] && echo "on"
V="${FIXTURE_DOLLAR_HELPER:-}"
N=$(num_or "$FIXTURE_DOLLAR_HELPER" 5)
echo "$V $N"
SH
cat > "$FX/tests/fixture-fallback-test.sh" <<'SH'
#!/bin/bash
FIXTURE_HELPER_TICKS=1 FIXTURE_CASE_SECS=1 FIXTURE_ISNOT_MAX=1 \
  FIXTURE_EQ_SEAM=1 FIXTURE_DOLLAR_HELPER=1 bash bin/fixture-fallback-shapes.sh
SH

# ══ 5. R2-N1: URL defaults and bare api_get are call targets ═════════════════
cat > "$FX/bin/fixture-endpoints-1530.sh" <<'SH'
#!/bin/bash
JOBS="${FIXTURE_JOBS_URL:-https://harness-jobs.fixture.workers.dev}"
code=$(api_get "https://openrouter.fixture.example/credits" "$k")
LINK="https://github.com/$SLUG/pull/$num"
REMOTE="https://github.com/$SLUG.git"
echo "$JOBS $code $LINK $REMOTE"
SH

run_gen --root "$FX" --out "$OUT" > "$T/gen1.log" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "generator exited $RC on the fixture tree: $(cat "$T/gen1.log")"
[ -s "$OUT/inventory.json" ] && ok || bad "no inventory.json written for the fixture tree"

# ── section 1 assertions ─────────────────────────────────────────────────────
[ "$(cls FIXTURE_SAMELINE_LOCAL)" = PLUMBING ] \
  && ok || bad "R2-N2: FIXTURE_SAMELINE_LOCAL (X=\$(cmd); X=\"\${X:-0}\" on one line) should be PLUMBING, got $(cls FIXTURE_SAMELINE_LOCAL)"
[ "$(rule FIXTURE_SAMELINE_LOCAL)" = self-assigned ] \
  && ok || bad "R2-N2: FIXTURE_SAMELINE_LOCAL should classify via the self-assigned rule, got $(rule FIXTURE_SAMELINE_LOCAL)"
[ "$(cls FIXTURE_PURE_SELFINIT)" = CONFIG ] \
  && ok || bad "R2-N2 negative: a pure self-init on its own line must stay CONFIG, got $(cls FIXTURE_PURE_SELFINIT)"
[ "$(cls FIXTURE_LOCAL_SELFINIT)" = CONFIG ] \
  && ok || bad "R2-N2 negative: \`local X=\${X:-3}\` is one assignment + one self-init and must stay CONFIG, got $(cls FIXTURE_LOCAL_SELFINIT)"

# ── section 2 assertions ─────────────────────────────────────────────────────
[ "$(defr FIXTURE_CI_RUNNERS_LABEL)" = false ] \
  && ok || bad "R2-N3: FIXTURE_CI_RUNNERS_LABEL (a CI runner label) must NOT be deferred to #1510"
[ "$(defr FIXTURE_BATCH_CI_RUNNERS)" = false ] \
  && ok || bad "R2-N3: FIXTURE_BATCH_CI_RUNNERS must NOT be deferred to #1510"
[ "$(defr FIXTURE_SUITE_RUNNER_LABEL)" = false ] \
  && ok || bad "R2-N3: FIXTURE_SUITE_RUNNER_LABEL must NOT be deferred to #1510"
[ "$(defr FIXTURE_DOWN_FILE)" = false ] \
  && ok || bad "R2-N3: FIXTURE_DOWN_FILE (default names claude-auth-down.txt, not a model) must NOT be deferred to #1510"
[ "$(defr RUNNER_TEMP)" = false ] \
  && ok || bad "R2-N3: RUNNER_TEMP (the GitHub Actions scratch dir, a shell/CI builtin) must NOT be deferred to #1510"
[ "$(defr FIXTURE_X_MODEL)" = true ] \
  && ok || bad "R2-N3 negative: a _MODEL name must still be deferred to #1510"
[ "$(defr FIXTURE_RUNNER_EVAL)" = true ] \
  && ok || bad "R2-N3 negative: a RUNNER_ name must still be deferred to #1510"
[ "$(defr FIXTURE_STAGE)" = true ] \
  && ok || bad "R2-N3 negative: a claude-opus-5 default must still be deferred to #1510"
[ "$(defr FIXTURE_GPT)" = true ] \
  && ok || bad "R2-N3 negative: a gpt-6 default must still be deferred to #1510"

# ── section 3 assertions ─────────────────────────────────────────────────────
[ "$(cls FIXTURE_LOCAL_TESTSET)" = PLUMBING ] \
  && ok || bad "R2-N4: FIXTURE_LOCAL_TESTSET (a local its own file assigns) should be PLUMBING, got $(cls FIXTURE_LOCAL_TESTSET)"
[ "$(rule FIXTURE_LOCAL_TESTSET)" = self-assigned ] \
  && ok || bad "R2-N4: FIXTURE_LOCAL_TESTSET should classify via the self-assigned rule, got $(rule FIXTURE_LOCAL_TESTSET)"
[ "$(cls FIXTURE_TEST_SEAM)" = TEST_HOOK ] \
  && ok || bad "R2-N4 negative: a genuine seam must stay TEST_HOOK, got $(cls FIXTURE_TEST_SEAM)"

# ── section 4 assertions ─────────────────────────────────────────────────────
[ "$(cls FIXTURE_HELPER_TICKS)" = CONFIG ] \
  && ok || bad "R2-N4: FIXTURE_HELPER_TICKS (br_knob_num NAME \"\${NAME:-}\" 12) should be CONFIG, got $(cls FIXTURE_HELPER_TICKS)"
[ "$(cls FIXTURE_CASE_SECS)" = CONFIG ] \
  && ok || bad "R2-N4: FIXTURE_CASE_SECS (case \"\${NAME:-}\" in clamp) should be CONFIG, got $(cls FIXTURE_CASE_SECS)"
[ "$(cls FIXTURE_ISNOT_MAX)" = CONFIG ] \
  && ok || bad "R2-N4: FIXTURE_ISNOT_MAX (\"NAME='\${NAME:-}' is not …\" validation message) should be CONFIG, got $(cls FIXTURE_ISNOT_MAX)"
[ "$(cls FIXTURE_EQ_SEAM)" = TEST_HOOK ] \
  && ok || bad "R2-N4 negative: a plain equality compare is not knob evidence — FIXTURE_EQ_SEAM should stay TEST_HOOK, got $(cls FIXTURE_EQ_SEAM)"
[ "$(cls FIXTURE_DOLLAR_HELPER)" = TEST_HOOK ] \
  && ok || bad "R2-N4 negative: a helper handed \$NAME (an expansion, not \${NAME:-}) is not knob evidence — got $(cls FIXTURE_DOLLAR_HELPER)"

# ── section 5 assertions ─────────────────────────────────────────────────────
epkind() { jq -r --arg p "$1" '[.endpoints[]|select(.literal|startswith($p))][0].kind' "$OUT/inventory.json"; }
epreason() { jq -r --arg p "$1" '[.endpoints[]|select(.literal|startswith($p))][0].reason' "$OUT/inventory.json"; }
[ "$(epkind 'https://harness-jobs.fixture.workers.dev')" = CONFIG ] \
  && ok || bad "R2-N1: a URL that is the default of \${VAR:-…} is a call target (CONFIG), got $(epkind 'https://harness-jobs.fixture.workers.dev')"
case "$(epreason 'https://harness-jobs.fixture.workers.dev')" in
  *FIXTURE_JOBS_URL*) ok ;;
  *) bad "R2-N1: the URL-default reason must name the variable it is the default of, got $(epreason 'https://harness-jobs.fixture.workers.dev')" ;;
esac
[ "$(epkind 'https://openrouter.fixture.example/credits')" = CONFIG ] \
  && ok || bad "R2-N1: a bare \`api_get \"https://…\"\` call is a call target (CONFIG), got $(epkind 'https://openrouter.fixture.example/credits')"
[ "$(epkind 'https://github.com/$SLUG/pull/')" = DOC ] \
  && ok || bad "R2-N1: an interpolated github.com/\$slug/pull/\$num display link is not a call target, got $(epkind 'https://github.com/$SLUG/pull/')"
[ "$(epkind 'https://github.com/$SLUG.git')" = CONFIG ] \
  && ok || bad "R2-N1 negative: a git remote (no /pull/, /issues/, /commit/, /actions/runs/ path) stays CONFIG, got $(epkind 'https://github.com/$SLUG.git')"
jq -e '[.proposed_slices[]|select(.name=="endpoints")|.vars[]]|map(select(test("harness-jobs.fixture")))|length > 0' \
  "$OUT/inventory.json" >/dev/null \
  && ok || bad "R2-N1: the endpoints slice's checklist must carry the URL-default call target"

# ══ 6. one file, one slice ═══════════════════════════════════════════════════
# (a) two vars of DIFFERENT subsystems sharing one lib file land in ONE slice.
FX6A="$T/fx6a"; OUT6A="$T/out6a"
mkdir -p "$FX6A/bin/lib"
cat > "$FX6A/bin/mc-fixture.sh" <<'SH'
#!/bin/bash
A="${FIXTURE_MC_SHARED:-1}"
B="${FIXTURE_MC_SHARED:-1}"
echo "$A $B"
SH
cat > "$FX6A/bin/cost-fixture.sh" <<'SH'
#!/bin/bash
C="${FIXTURE_COST_SHARED:-2}"
D="${FIXTURE_COST_SHARED:-2}"
echo "$C $D"
SH
cat > "$FX6A/bin/lib/fixture-shared.sh" <<'SH'
#!/bin/bash
echo "${FIXTURE_MC_SHARED:-1} ${FIXTURE_COST_SHARED:-2}"
SH
run_gen --root "$FX6A" --out "$OUT6A" > "$T/gen6a.log" 2>&1
jq -e '[.proposed_slices[]|select(.name!="endpoints")|select((.vars|index("FIXTURE_MC_SHARED")) or (.vars|index("FIXTURE_COST_SHARED")))]|length == 1' \
  "$OUT6A/inventory.json" >/dev/null \
  && ok || bad "regrouping: two vars sharing bin/lib/fixture-shared.sh must land in ONE slice, got $(jq -c '[.proposed_slices[]|select(.name!="endpoints")|select((.vars|index("FIXTURE_MC_SHARED")) or (.vars|index("FIXTURE_COST_SHARED")))|.name]' "$OUT6A/inventory.json")"
jq -e '[.proposed_slices[]|select(.name!="endpoints")|.files[]]|group_by(.)|map(select(length>1))|length == 0' \
  "$OUT6A/inventory.json" >/dev/null \
  && ok || bad "regrouping: no file may appear in two var slices"

# (b) 14 vars each in its own file AND in one shared hub file = 15 files, over
#     the 12-file cap: the component is cut into a SERIAL chain, never into
#     independent slices that would conflict on the hub file.
FX6B="$T/fx6b"; OUT6B="$T/out6b"
mkdir -p "$FX6B/bin"
HUB="$FX6B/bin/fixture-hub.sh"
printf '#!/bin/bash\n' > "$HUB"
for i in $(seq -w 1 14); do
  printf '#!/bin/bash\nV="${FIXTURE_HUB_%s:-1}"\nW="${FIXTURE_HUB_%s:-1}"\necho "$V $W"\n' \
    "$i" "$i" > "$FX6B/bin/fixture-h$i.sh"
  printf 'echo "${FIXTURE_HUB_%s:-1}"\n' "$i" >> "$HUB"
done
run_gen --root "$FX6B" --out "$OUT6B" > "$T/gen6b.log" 2>&1
CH=$(jq -c '[.proposed_slices[]|select(.name!="endpoints")|select(.files|index("bin/fixture-hub.sh"))]' "$OUT6B/inventory.json")
[ "$(echo "$CH" | jq 'length >= 2')" = true ] \
  && ok || bad "regrouping: a 15-file component must be cut into >=2 chunks, got $(echo "$CH" | jq 'length')"
[ "$(echo "$CH" | jq '[.[].serial_group]|unique|length == 1 and (.[0] != null)')" = true ] \
  && ok || bad "regrouping: every chunk of one over-cap component must carry the SAME non-null serial_group, got $(echo "$CH" | jq -c '[.[].serial_group]')"
[ "$(echo "$CH" | jq --argjson n "$(echo "$CH" | jq 'length')" '[.[].order] == ([range(1;$n+1)]|map("\(.) of \($n)"))')" = true ] \
  && ok || bad "regrouping: chunk order must read \"1 of N\" … \"N of N\", got $(echo "$CH" | jq -c '[.[].order]')"
[ "$(echo "$CH" | jq '[.[].blocked_by] == ([null] + (.[0:-1]|map(.name)))')" = true ] \
  && ok || bad "regrouping: each chunk must be blocked_by the previous one (null for the first), got $(echo "$CH" | jq -c '[.[].blocked_by]')"
[ "$(echo "$CH" | jq '[.[]|select((.vars|length) > 40 or (.files|length) > 12)]|length == 0')" = true ] \
  && ok || bad "regrouping: every chain chunk must still respect the 40-knob / 12-file caps"
[ "$(echo "$CH" | jq '[.[].note]|all(test("parallel"))')" = true ] \
  && ok || bad "regrouping: a chain chunk's note must say the chunks are built one after another, never in parallel"

# (c) single-file vars share nothing, so they pack as ordinary independent
#     slices with NO serial_group — the 1511 suite's FIXTURE_MANYFILE_* shape.
FX6C="$T/fx6c"; OUT6C="$T/out6c"
mkdir -p "$FX6C/bin"
for i in $(seq 1 15); do
  printf '#!/bin/bash\nFIXTURE_SOLO_%02d="${FIXTURE_SOLO_%02d:-%d}"\n' "$i" "$i" "$i" \
    > "$FX6C/bin/fixture-solo-$i.sh"
done
run_gen --root "$FX6C" --out "$OUT6C" > "$T/gen6c.log" 2>&1
jq -e '[.proposed_slices[]|select(.name!="endpoints")|select(.serial_group != null)]|length == 0' \
  "$OUT6C/inventory.json" >/dev/null \
  && ok || bad "regrouping: independent single-file vars must NOT be chained"
jq -e '[.proposed_slices[]|select((.vars|length) > 40 or (.files|length) > 12)]|length == 0' \
  "$OUT6C/inventory.json" >/dev/null \
  && ok || bad "regrouping: independent slices must still respect the 40-knob / 12-file caps"
jq -e '[.proposed_slices[]|select(.name!="endpoints")|.vars[]]|length == 15' \
  "$OUT6C/inventory.json" >/dev/null \
  && ok || bad "regrouping: all 15 independent vars must be packed, none dropped"

# ══ 7. the inventory of this tree carries these answers ══════════════════════
run_gen --root "$DIR" --out "$T/s7" > "$T/s7.log" 2>&1
INV="$T/s7/inventory.json"
if [ -s "$INV" ]; then
  ccls() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.class' "$INV"; }
  cdef() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.deferred_to_1510' "$INV"; }
  for n in DEFER VCUR LN0; do
    [ "$(ccls "$n")" = PLUMBING ] \
      && ok || bad "inventory: $n (R2-N2 same-line self-init) should be PLUMBING, got $(ccls "$n")"
  done
  for n in REPRO_RC QA_NOTE; do
    [ "$(ccls "$n")" = PLUMBING ] \
      && ok || bad "inventory: $n (R2-N4 local a test also sets) should be PLUMBING, got $(ccls "$n")"
  done
  for n in E2E_JOIN_MAX_S OVERLAP_WAIT_SECS GROK_BILLING; do
    [ "$(ccls "$n")" = CONFIG ] \
      && ok || bad "inventory: $n (R2-N4 empty default, in-code fallback) should be CONFIG, got $(ccls "$n")"
  done
  for n in CI_RUNNERS_LABEL MC_LANE_DOWN_FILE RUNNER_TEMP BATCH_CI_RUNNERS; do
    [ "$(cdef "$n")" = false ] \
      && ok || bad "inventory: $n (R2-N3) must NOT be deferred to #1510, got $(cdef "$n")"
  done
  jq -e '[.proposed_slices[]|select(.name!="endpoints")|{n:.name,g:(.serial_group//null),f:.files[]}]
         |group_by(.f)|map(select(length>1))
         |map(select((map(.g)|unique|length)!=1 or .[0].g==null))|length == 0' "$INV" >/dev/null \
    && ok || bad "inventory: a file appears in two slices that are not one serial chain ($(jq -c '[.proposed_slices[]|select(.name!="endpoints")|{n:.name,g:(.serial_group//null),f:.files[]}]|group_by(.f)|map(select(length>1))|map(select((map(.g)|unique|length)!=1 or .[0].g==null))|length' "$INV") files)"
  # An interpolated github.com WEB page is a display link; an interpolated
  # `.git` REMOTE on the same host is a real call target and must survive the
  # rule — both halves are asserted, so "stopped counting github links" cannot
  # pass for "stopped counting display links".
  jq -e '[.endpoints[]|select(.kind=="CONFIG")|.literal]
         |map(select(test("^https://github.com/\\$.*(/pull/|/issues/|/commit/|/actions/runs/)")))|length == 0' "$INV" >/dev/null \
    && ok || bad "inventory: interpolated github.com display links must not be CONFIG call targets"
  jq -e '[.endpoints[]|select(.kind=="CONFIG")|.literal]|map(select(test("^https://github.com/\\$.*\\.git$")))|length > 0' "$INV" >/dev/null \
    && ok || bad "inventory: a github.com git remote is a real call target and must stay CONFIG"
  jq -e '[.proposed_slices[]|select(.name=="endpoints")|.vars[]]|map(select(test("harness-jobs|api.github.com")))|length >= 2' "$INV" >/dev/null \
    && ok || bad "inventory: the endpoints slice must carry the URL-default and api_get call targets"
else
  bad "the generator wrote no inventory.json for this tree: $(cat "$T/s7.log")"
fi

# ══ 8. R2-N5 is written down where a slice author will read it ═══════════════
NOTE="$DIR/docs/notes/2026-09-22-BH-1530-inventory-residuals.md"
DOC="$DIR/docs/verification-map/config-inventory.md"
[ -s "$NOTE" ] && ok || bad "the dated note docs/notes/2026-09-22-BH-1530-inventory-residuals.md is missing (D37)"
grep -q '^Doc: ' "$NOTE" 2>/dev/null && ok || bad "the dated note needs a \`Doc: <NAME>\` line (D37)"
for f in "$NOTE" "$DOC" "$DIR/bin/config-inventory.py"; do
  if grep -q 'R2-N5' "$f" 2>/dev/null && grep -q 'COST_KEY' "$f" 2>/dev/null && grep -q 'JOBS_BODY' "$f" 2>/dev/null; then
    ok
  else
    bad "$(basename "$f") must name R2-N5's context/output variables (COST_KEY, JOBS_BODY) so slice authors drop them on sight"
  fi
done

echo "config-inventory.bh-1530-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
