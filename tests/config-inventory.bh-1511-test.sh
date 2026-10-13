#!/bin/bash
# tests/config-inventory.bh-1511-test.sh — bin/config-inventory.sh (BH-1511.0).
#
# Two things worth proving, red before green:
#   1. the classification RULES: on a small fixture tree, every one of the six
#      classes (plus the deferred-to-#1510 and computed-default flags) lands
#      where the rule that names it says it should. A generator whose rules
#      look right in the source but classify the wrong bucket in practice is
#      worse than no generator: it hands #1511's later slices a lie dressed as
#      data. Every fixture below traces to a specific finding of the #1514
#      adversarial review (B3/B4/B5/I1/I2/I3), and was RED against the code
#      that PR shipped before the matching fix landed.
#   2. FRESHNESS (BH-5518): docs/config-inventory/inventory.json is generated
#      and git-ignored, never committed, so freshness is "two renders of the
#      CURRENT tree agree", compared on a LINE-FREE projection (read_sites
#      keyed on file+default, endpoints on file+literal+kind, never on a line
#      number — the #1514 review showed a line-keyed compare is noise). It is
#      a hard FAIL, and so is a tracked inventory.json. While the file was
#      committed this compare was a WARN, because every PR touching bin/ moved
#      it; a committed render was the conflict BH-5518 removed.
#
# Run from anywhere: tests/config-inventory.bh-1511-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
warn() { WARN=$((WARN+1)); echo "WARN: $1"; }

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

run_gen() { bash "$DIR/bin/config-inventory.sh" "$@"; }
[ -s "$DIR/bin/config-inventory.py" ] && ok || bad "bin/config-inventory.py is missing"

# ══ 1. classification rules on a small fixture tree ══════════════════════════
FX="$T/fixture"
mkdir -p "$FX/bin/lib" "$FX/fly" "$FX/cron" "$FX/catalog/lanes.d" "$FX/tests"

# ALREADY_REGISTERED: FIXTURE_KNOB is registered for the fixture-lane lane and
# read by that lane's own script.
cat > "$FX/catalog/lanes.d/fixture-lane.json" <<'JSON'
{
  "id": "fixture-lane",
  "script": "bin/fixture-lane.sh",
  "knobs": [
    { "env": "FIXTURE_KNOB", "type": "int", "default": 5 }
  ]
}
JSON
cat > "$FX/bin/fixture-lane.sh" <<'SH'
#!/bin/bash
VAL="${FIXTURE_KNOB:-5}"
echo "$VAL"
SH

# SECRET: a TOKEN-suffixed name, never registered. Plus review M2: a bare
# `KEY` compound that is a lookup identifier, not a credential, must NOT be
# SECRET.
cat > "$FX/bin/fixture-secret.sh" <<'SH'
#!/bin/bash
T="${FIXTURE_API_TOKEN:-}"
K="${LAST_KEY:-}"
SH

# BOX_LAYOUT: a path default rooted at /root, PLUS review M3: $H/ / $HENV/ /
# $HOME/ are box-relative too, not just $HARNESS/.
cat > "$FX/bin/fixture-boxlayout.sh" <<'SH'
#!/bin/bash
D="${FIXTURE_STATE_DIR:-/root/fixture/state}"
P="${FIXTURE_H_PROMPT:-$H/prompts/fixture.md}"
SH

# TEST_HOOK: assigned only by a tests/ file via env-prefix, read (with an
# EMPTY fallback, no self-init) by production code that never assigns it
# itself — a genuine seam, not a knob a test happens to override.
cat > "$FX/bin/fixture-testhook.sh" <<'SH'
#!/bin/bash
V="${FIXTURE_TEST_SEAM:-}"
echo "$V"
SH
cat > "$FX/tests/fixture-testhook-test.sh" <<'SH'
#!/bin/bash
FIXTURE_TEST_SEAM=1 bash bin/fixture-testhook.sh
SH

# B3 (review): a test overriding a REAL knob (a production self-init with a
# non-empty default) must NOT be swallowed into TEST_HOOK — knob evidence
# beats a test assignment. Repro is #1514's own (TESTED_KNOB_TTL).
cat > "$FX/bin/fixture-tested-knob.sh" <<'SH'
#!/bin/bash
FIXTURE_TESTED_KNOB_TTL="${FIXTURE_TESTED_KNOB_TTL:-300}"
echo "$FIXTURE_TESTED_KNOB_TTL"
SH
cat > "$FX/tests/fixture-tested-knob-test.sh" <<'SH'
#!/bin/bash
FIXTURE_TESTED_KNOB_TTL=0 bash bin/fixture-tested-knob.sh
SH

# PLUMBING (self-assigned, loop shape): a `for` LOOP variable, read with a
# fallback INSIDE the loop body — section 7's real "assigned then read in the
# same function" shape. Not the review's B4 bug (that was an ORDINARY
# `NAME=value` assignment, fixed below): this one must stay PLUMBING even
# though its own default ('none') is a non-empty literal, because it is
# loop-parsed output (review B4/B5's own worked distinction — RN24/RN7/LKIND
# stay PLUMBING despite carrying real-looking scratch defaults).
cat > "$FX/bin/fixture-loopvar.sh" <<'SH'
#!/bin/bash
for FIXTURE_LOOP_ITEM in a b c; do
  echo "${FIXTURE_LOOP_ITEM:-none}"
done
SH

# B4a (review): a `NAME=` shape INSIDE a quoted log/echo string is not a real
# assignment — must not push a real self-init knob into PLUMBING.
cat > "$FX/bin/fixture-logstring-knob.sh" <<'SH'
#!/bin/bash
FIXTURE_LOGSTR_KNOB_SECS="${FIXTURE_LOGSTR_KNOB_SECS:-60}"
echo "tick: FIXTURE_LOGSTR_KNOB_SECS=$FIXTURE_LOGSTR_KNOB_SECS (info only)"
SH

# B4b (review): a validation-CLAMP that restates the var's own known default
# (`case … X=<same literal> ;; esac`) is not a distinct local value.
cat > "$FX/bin/fixture-clamp-knob.sh" <<'SH'
#!/bin/bash
FIXTURE_CLAMP_KNOB_MAX="${FIXTURE_CLAMP_KNOB_MAX:-5}"
case "$FIXTURE_CLAMP_KNOB_MAX" in
  ''|*[!0-9]*) FIXTURE_CLAMP_KNOB_MAX=5 ;;
esac
echo "$FIXTURE_CLAMP_KNOB_MAX"
SH

# B4 (review, KNOWN REMAINING GAP, documented not silently accepted): a plain
# `NAME=$(...)` reading a fallback source for the SAME var — review's own
# TICKET_IDENTITY_GUARD/POOL_SPAWN_CAP shape — still resolves PLUMBING. A
# version of self-assigned that let this override (via self-init or "any
# non-empty default exists somewhere") ALSO promoted real accumulators/status
# strings (RED_NAMES, RUNNING, PHASE_USD, BEFORE, DRIVE_LAST — all read with
# a sane non-empty fallback for the exact same defensive-shell reason a real
# knob is) into CONFIG, which is worse: it pollutes #1511's conversion
# slices with state variables. See classify()'s own comment for the measured
# tradeoff. This fixture pins the CURRENT (safe, imperfect) behaviour so a
# future attempt at the override is caught if it regresses silently.
cat > "$FX/bin/fixture-fallback-read-knob.sh" <<'SH'
#!/bin/bash
if [ -z "${FIXTURE_FALLBACK_GUARD:-}" ] && [ -r "$FX_ENV" ]; then
  FIXTURE_FALLBACK_GUARD=$(sed -n 's/^FIXTURE_FALLBACK_GUARD=\(.*\)/\1/p' "$FX_ENV")
fi
if [ "${FIXTURE_FALLBACK_GUARD:-1}" = 0 ]; then
  echo "off"
fi
SH

# B5 (review): a MULTI-NAME `read` line assigns every name it lists, not just
# the last one on the line — each of A/B must be PLUMBING, never CONFIG, even
# though each is separately read with its own fallback.
cat > "$FX/bin/fixture-readloop.sh" <<'SH'
#!/bin/bash
while IFS=$'\t' read -r FIXTURE_RD_A FIXTURE_RD_B; do
  echo "${FIXTURE_RD_A:-?} ${FIXTURE_RD_B:-?}"
done < "$FX_ROWS"
SH

# CONFIG: a plain value, no registry hit, no secret/box/test/plumbing shape —
# the residual this whole ticket exists to find. Declared via the
# `NAME="${NAME:-default}"` self-init idiom, which must NOT be read as
# self-assigned plumbing (BH-1511.0's first real bug, caught scanning the
# real tree: it marked ~500 genuine knobs as PLUMBING before the fix).
cat > "$FX/bin/fixture-config.sh" <<'SH'
#!/bin/bash
FIXTURE_TIMEOUT_SECS="${FIXTURE_TIMEOUT_SECS:-30}"
echo "$FIXTURE_TIMEOUT_SECS"
SH

# deferred_to_1510 (I2): a *_MODEL var and a model-id-shaped default — #1511's
# own ticket body says model ids are #1510's, not a generic settings row
# here. FIXTURE_REVIEW_MODEL_T0 covers the "_MODEL_" segment in the MIDDLE of
# a name, not just as a suffix (review's REVIEW_MODEL_T0 miss).
cat > "$FX/bin/fixture-model.sh" <<'SH'
#!/bin/bash
M="${FIXTURE_STAGE_MODEL:-claude-opus-5}"
N="${FIXTURE_REVIEW_MODEL_T0:-}"
echo "$M $N"
SH

# I2: a RUNNER_*-prefixed name with an EMPTY default (no _MODEL suffix, no
# model-shaped default, no #1510 note) must still defer — the review's
# RUNNER_TRIAGE_FALLBACK/RUNNER_CHAT_FALLBACK/RUNNER_EVAL leak, all empty or
# plain-vendor defaults.
cat > "$FX/bin/fixture-runner-fallback.sh" <<'SH'
#!/bin/bash
FB="${FIXTURE_RUNNER_CHAT_FALLBACK:-}"
echo "$FB"
SH

# I2: a routing word (LADDER/TIER/FALLBACK/...) COMBINED with a vendor name
# defers even with no RUNNER/MODEL/EFFORT segment (review's LADDER_TIER2_GROK)
# — but a vendor-scoped ORDINARY setting with no routing word (GROK_MAX_TURNS)
# must NOT defer, since #1511 still owns it.
cat > "$FX/bin/fixture-ladder-tier.sh" <<'SH'
#!/bin/bash
FIXTURE_LADDER_TIER2_GROK="${FIXTURE_LADDER_TIER2_GROK:-1}"
FIXTURE_GROK_MAX_TURNS="${FIXTURE_GROK_MAX_TURNS:-25}"
echo "$FIXTURE_LADDER_TIER2_GROK $FIXTURE_GROK_MAX_TURNS"
SH

# computed_default: a default that is shell text, not a value — section 18's
# own rule ("a default is a VALUE, never shell text") applied here as a flag
# rather than a refusal, since this is an inventory, not the registry itself.
cat > "$FX/bin/fixture-computed.sh" <<'SH'
#!/bin/bash
TAG="${FIXTURE_BOX_TAG:-$(hostname)}"
echo "$TAG"
SH

OUTDIR="$T/out"
run_gen --root "$FX" --out "$OUTDIR" > "$T/gen.log" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "generator exited $RC on the fixture tree: $(cat "$T/gen.log")"
[ -s "$OUTDIR/inventory.json" ] && ok || bad "no inventory.json written for the fixture tree"
[ -s "$OUTDIR/index.html" ] && ok || bad "no index.html written for the fixture tree"

cls() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.class' "$OUTDIR/inventory.json"; }
rule() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.rule' "$OUTDIR/inventory.json"; }
flag() { jq -r --arg n "$1" --arg f "$2" '.variables[]|select(.name==$n)|.[$f]' "$OUTDIR/inventory.json"; }

[ "$(cls FIXTURE_KNOB)" = ALREADY_REGISTERED ] \
  && ok || bad "FIXTURE_KNOB should be ALREADY_REGISTERED, got $(cls FIXTURE_KNOB)"
[ "$(cls FIXTURE_API_TOKEN)" = SECRET ] \
  && ok || bad "FIXTURE_API_TOKEN should be SECRET, got $(cls FIXTURE_API_TOKEN)"
[ "$(cls LAST_KEY)" != SECRET ] \
  && ok || bad "LAST_KEY (a lookup identifier, review M2) must NOT be SECRET, got $(cls LAST_KEY)"
[ "$(cls FIXTURE_STATE_DIR)" = BOX_LAYOUT ] \
  && ok || bad "FIXTURE_STATE_DIR should be BOX_LAYOUT, got $(cls FIXTURE_STATE_DIR)"
[ "$(cls FIXTURE_H_PROMPT)" = BOX_LAYOUT ] \
  && ok || bad "FIXTURE_H_PROMPT (\$H/ path, review M3) should be BOX_LAYOUT, got $(cls FIXTURE_H_PROMPT)"
[ "$(cls FIXTURE_TEST_SEAM)" = TEST_HOOK ] \
  && ok || bad "FIXTURE_TEST_SEAM should be TEST_HOOK, got $(cls FIXTURE_TEST_SEAM)"
[ "$(cls FIXTURE_TESTED_KNOB_TTL)" = CONFIG ] \
  && ok || bad "FIXTURE_TESTED_KNOB_TTL (review B3: real knob a test overrides) should be CONFIG, got $(cls FIXTURE_TESTED_KNOB_TTL)"
[ "$(cls FIXTURE_LOOP_ITEM)" = PLUMBING ] \
  && ok || bad "FIXTURE_LOOP_ITEM (for-loop var) should be PLUMBING, got $(cls FIXTURE_LOOP_ITEM)"
[ "$(rule FIXTURE_LOOP_ITEM)" = self-assigned ] \
  && ok || bad "FIXTURE_LOOP_ITEM should classify via the self-assigned rule, got $(rule FIXTURE_LOOP_ITEM)"
[ "$(cls FIXTURE_LOGSTR_KNOB_SECS)" = CONFIG ] \
  && ok || bad "FIXTURE_LOGSTR_KNOB_SECS (review B4a: NAME= inside a log string) should be CONFIG, got $(cls FIXTURE_LOGSTR_KNOB_SECS)"
[ "$(cls FIXTURE_CLAMP_KNOB_MAX)" = CONFIG ] \
  && ok || bad "FIXTURE_CLAMP_KNOB_MAX (review B4b: clamp restating its own default) should be CONFIG, got $(cls FIXTURE_CLAMP_KNOB_MAX)"
[ "$(cls FIXTURE_FALLBACK_GUARD)" = PLUMBING ] \
  && ok || bad "FIXTURE_FALLBACK_GUARD (review B4: KNOWN remaining gap, pinned not silently regressed) should be PLUMBING, got $(cls FIXTURE_FALLBACK_GUARD)"
[ "$(cls FIXTURE_RD_A)" = PLUMBING ] \
  && ok || bad "FIXTURE_RD_A (review B5: multi-name read) should be PLUMBING, got $(cls FIXTURE_RD_A)"
[ "$(cls FIXTURE_RD_B)" = PLUMBING ] \
  && ok || bad "FIXTURE_RD_B (review B5: multi-name read, second name) should be PLUMBING, got $(cls FIXTURE_RD_B)"
[ "$(cls FIXTURE_TIMEOUT_SECS)" = CONFIG ] \
  && ok || bad "FIXTURE_TIMEOUT_SECS (self-init idiom) should be CONFIG, got $(cls FIXTURE_TIMEOUT_SECS)"
[ "$(cls FIXTURE_STAGE_MODEL)" = CONFIG ] \
  && ok || bad "FIXTURE_STAGE_MODEL should still classify CONFIG, got $(cls FIXTURE_STAGE_MODEL)"
[ "$(flag FIXTURE_STAGE_MODEL deferred_to_1510)" = true ] \
  && ok || bad "FIXTURE_STAGE_MODEL must be flagged deferred_to_1510"
[ "$(flag FIXTURE_REVIEW_MODEL_T0 deferred_to_1510)" = true ] \
  && ok || bad "FIXTURE_REVIEW_MODEL_T0 (review I2: _MODEL_ segment in the middle) must be flagged deferred_to_1510"
[ "$(flag FIXTURE_RUNNER_CHAT_FALLBACK deferred_to_1510)" = true ] \
  && ok || bad "FIXTURE_RUNNER_CHAT_FALLBACK (review I2: RUNNER_ prefix, empty default) must be flagged deferred_to_1510"
[ "$(flag FIXTURE_LADDER_TIER2_GROK deferred_to_1510)" = true ] \
  && ok || bad "FIXTURE_LADDER_TIER2_GROK (review I2: routing word + vendor) must be flagged deferred_to_1510"
[ "$(flag FIXTURE_GROK_MAX_TURNS deferred_to_1510)" = false ] \
  && ok || bad "FIXTURE_GROK_MAX_TURNS (vendor-scoped but no routing word) must NOT be flagged deferred_to_1510"
[ "$(flag FIXTURE_TIMEOUT_SECS deferred_to_1510)" = false ] \
  && ok || bad "FIXTURE_TIMEOUT_SECS must NOT be flagged deferred_to_1510"
[ "$(flag FIXTURE_BOX_TAG computed_default)" = true ] \
  && ok || bad "FIXTURE_BOX_TAG (\$(hostname) default) must be flagged computed_default"
[ "$(flag FIXTURE_TIMEOUT_SECS computed_default)" = false ] \
  && ok || bad "FIXTURE_TIMEOUT_SECS must NOT be flagged computed_default"

# The fixture's CONFIG vars must show up in a proposed slice, and the
# fixture's deferred vars must NOT — that's the whole point of separating them.
jq -e '[.proposed_slices[].vars[]] | index("FIXTURE_TIMEOUT_SECS")' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "FIXTURE_TIMEOUT_SECS should appear in a proposed slice"
jq -e '[.proposed_slices[].vars[]] | index("FIXTURE_STAGE_MODEL") | not' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "FIXTURE_STAGE_MODEL (deferred to #1510) should NOT appear in a proposed slice"
jq -e '[.proposed_slices[].vars[]] | index("FIXTURE_RUNNER_CHAT_FALLBACK") | not' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "FIXTURE_RUNNER_CHAT_FALLBACK (deferred to #1510) should NOT appear in a proposed slice"

# ══ 2. endpoint literals: CONFIG (call target) vs DOC ═════════════════════════
cat > "$FX/bin/fixture-endpoint.sh" <<'SH'
#!/bin/bash
# See https://example.com/docs for background — not a call target.
API_BASE="https://api.fixture-vendor.example/v1"
curl -s "$API_BASE/ping"
# review I1: ANY assignment (not just *_URL/_BASE/_HOST) is a call target.
APIB="https://apib.fixture-vendor.example/mint"
# review I1: a literal with a regex metacharacter is a pattern, not a target.
# (No trailing `)` on purpose: URL_RE itself excludes `)` from a match, same
# as it excludes a closing markdown-link paren — a literal ending in one
# would be truncated before classification ever saw it, which is a
# pre-existing, unrelated URL_RE property this fixture isn't testing.)
PATTERN_SOURCES="https://api.fixture-vendor.example/v[0-9]+/data"
SH
run_gen --root "$FX" --out "$OUTDIR" > "$T/gen2.log" 2>&1
epkind() { jq -r --arg l "$1" '[.endpoints[]|select(.literal==$l)][0].kind' "$OUTDIR/inventory.json"; }
[ "$(epkind 'https://api.fixture-vendor.example/v1')" = CONFIG ] \
  && ok || bad "an assigned *_BASE URL used by curl should be endpoint kind CONFIG"
[ "$(epkind 'https://example.com/docs')" = DOC ] \
  && ok || bad "a URL inside a comment should be endpoint kind DOC"
[ "$(epkind 'https://apib.fixture-vendor.example/mint')" = CONFIG ] \
  && ok || bad "review I1: ANY name= assignment (not just *_URL/_BASE/_HOST) should be endpoint kind CONFIG"
[ "$(epkind 'https://api.fixture-vendor.example/v[0-9]+/data')" = DOC ] \
  && ok || bad "review I1: a literal with regex metacharacters should be endpoint kind DOC, not a call target"

jq -e '[.proposed_slices[] | select(.name=="endpoints")] | length > 0' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "review I1: an explicit \"endpoints\" slice must be emitted when CONFIG-kind endpoints exist"

# ══ 3. conflicting defaults: detected, actionable filter, empty-default noise
#      dropped (review I5 partial fix) ════════════════════════════════════════
cat > "$FX/bin/fixture-conflict-a.sh" <<'SH'
#!/bin/bash
FIXTURE_CONFLICT_KNOB="${FIXTURE_CONFLICT_KNOB:-10}"
SH
cat > "$FX/bin/fixture-conflict-b.sh" <<'SH'
#!/bin/bash
FIXTURE_CONFLICT_KNOB="${FIXTURE_CONFLICT_KNOB:-20}"
SH
cat > "$FX/bin/fixture-presence-test.sh" <<'SH'
#!/bin/bash
[ -n "${FIXTURE_PRESENCE_ALERT:-}" ] && echo "set"
FIXTURE_PRESENCE_ALERT="${FIXTURE_PRESENCE_ALERT:-1300}"
SH
run_gen --root "$FX" --out "$OUTDIR" > "$T/gen3.log" 2>&1
jq -e '.conflicts[] | select(.name=="FIXTURE_CONFLICT_KNOB")' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "FIXTURE_CONFLICT_KNOB (10 vs 20) should be in .conflicts"
jq -e '.conflicts_actionable[] | select(.name=="FIXTURE_CONFLICT_KNOB")' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "FIXTURE_CONFLICT_KNOB is CONFIG-class and should be in .conflicts_actionable too"
jq -e '[.conflicts[] | select(.name=="FIXTURE_PRESENCE_ALERT")] | length == 0' "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "review I5: an empty-string presence-test default vs a real one ('' vs 1300) should NOT be a conflict"

# ══ 4. duplicate-meaning auto-chain detection (review I4) ════════════════════
cat > "$FX/bin/fixture-alias.sh" <<'SH'
#!/bin/bash
FIXTURE_REREVIEW_CAP="${FIXTURE_REREVIEW_CAP:-${FIXTURE_MC_REREVIEW_DAILY_CAP:-3}}"
FIXTURE_MC_REREVIEW_DAILY_CAP="${FIXTURE_MC_REREVIEW_DAILY_CAP:-3}"
SH
run_gen --root "$FX" --out "$OUTDIR" > "$T/gen3b.log" 2>&1
jq -e '[.duplicates[] | select(.vars | index("FIXTURE_REREVIEW_CAP") and index("FIXTURE_MC_REREVIEW_DAILY_CAP"))] | length > 0' \
  "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "review I4: a bare \${OTHER:-...} default should auto-derive a duplicate-meaning pair"

# ══ 5. slices respect BOTH max_knobs and max_files (review I3) ═══════════════
mkdir -p "$FX/bin/manyfiles"
for i in $(seq 1 15); do
  printf '#!/bin/bash\nFIXTURE_MANYFILE_%02d="${FIXTURE_MANYFILE_%02d:-%d}"\n' "$i" "$i" "$i" \
    > "$FX/bin/fixture-manyfile-$i.sh"
done
run_gen --root "$FX" --out "$OUTDIR" > "$T/gen4.log" 2>&1   # build_slices()'s defaults are 40 knobs / 12 files
jq -e '[.proposed_slices[] | select((.vars|length) > 40 or (.files|length) > 12)] | length == 0' \
  "$OUTDIR/inventory.json" >/dev/null \
  && ok || bad "review I3: no proposed slice may exceed 40 vars or 12 files"

# ══ 6. no network, no writes outside --out ════════════════════════════════════
BEFORE=$(find "$FX" -type f | sort)
run_gen --root "$FX" --out "$T/out2" > /dev/null 2>&1
AFTER=$(find "$FX" -type f | sort)
[ "$BEFORE" = "$AFTER" ] && ok || bad "the generator must not write anything under --root"

# ══ 7. the generator is documented in the verification map ═══════════════════
if [ -s "$DIR/docs/verification-map/entries/BH-1511.0.md" ] \
  && grep -q "config-inventory" "$DIR/docs/verification-map/entries/BH-1511.0.md"; then
  ok
else
  bad "docs/verification-map/entries/BH-1511.0.md is missing or does not mention bin/config-inventory"
fi

# ══ 8. freshness (review B1/B2, BH-5518): two renders of the CURRENT tree
#      agree on a LINE-FREE projection, and inventory.json is not tracked.
#      A hard FAIL: nothing is committed, so nothing can be legitimately stale.
PROJECT_JQ='
  del(.generated_at_commit) |
  .variables |= map(. + {read_sites: ([.read_sites[] | {file, default}] | unique | sort_by(.file, .default))}) |
  .endpoints  |= ([.[] | {file, literal, kind, service, reason}] | unique | sort_by(.file, .literal))
'
# At once: one render of the real tree takes ~25 s.
run_gen --root "$DIR" --out "$T/fresh1" > "$T/fresh1.log" 2>&1 & p1=$!
run_gen --root "$DIR" --out "$T/fresh2" > "$T/fresh2.log" 2>&1 & p2=$!
wait "$p1"; wait "$p2"
if [ -s "$T/fresh1/inventory.json" ] && [ -s "$T/fresh2/inventory.json" ]; then
  jq "$PROJECT_JQ" "$T/fresh1/inventory.json" > "$T/fresh1.norm.json" 2>"$T/jq1.err"
  jq "$PROJECT_JQ" "$T/fresh2/inventory.json" > "$T/fresh2.norm.json" 2>"$T/jq2.err"
  if [ -s "$T/fresh1.norm.json" ] && cmp -s "$T/fresh1.norm.json" "$T/fresh2.norm.json"; then
    ok
  else
    bad "two renders of the current tree differ (line-free projection): the generator is not deterministic ($(diff "$T/fresh1.norm.json" "$T/fresh2.norm.json" 2>/dev/null | head -5 | tr '\n' ' ') $(cat "$T/jq1.err" "$T/jq2.err"))"
  fi
else
  bad "could not render inventory.json from the current tree: $(cat "$T/fresh1.log" "$T/fresh2.log")"
fi
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$DIR" ls-files --error-unmatch docs/config-inventory/inventory.json >/dev/null 2>&1; then
    bad "docs/config-inventory/inventory.json is tracked; it is generated and git-ignored (BH-5518)"
  else ok; fi
else
  echo "SKIP: section 8 tracked-path check ($DIR is not a git checkout)"
fi

echo "config-inventory.bh-1511-test: $PASS passed, $FAIL failed, $WARN warned"
[ "$FAIL" = 0 ]
