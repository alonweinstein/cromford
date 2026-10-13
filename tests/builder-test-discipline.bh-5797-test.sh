#!/bin/bash
# tests/builder-test-discipline.bh-5797-test.sh — BH-5797 scopes 1 and 2: the
# builder prompt rules, and the builder verify step (the pre-PR gate,
# bin/lib/prepr-gate.sh) runs the CI fast lints before the push. A fast-lint
# finding that survives the one fix turn is a fix, not a PR.
#
#   V1  a fixture suite that hand-copies bin/lib/x.sh into a scratch harness:
#       the real `bin/rules-pack.sh --only scratch-closure` is red on it, and
#       that line through the real prepr_gate and the pr.sh `rules pack block`
#       span exits 6 REVIEW_BLOCKED (ticket acceptance test 1)
#   V2  a new suite reading the RANDOM variable (the real determinism lint) that the fix
#       turn leaves red: the span exits 6, the block file names the line
#   V3  a new source file no suite names (the real orphans --check): exit 6
#   V4  bin/rules-pack.sh --list carries fast-lints-data
#   V5  the fix turn fixes the determinism finding: no block
#   V6  RULES_PACK_BLOCK=0: a red fast lint is warn only, the PR opens
#   V7  the execute.sh span blocks the same way as the pr.sh one
#   V9  RB_PREPR_FIX_TURNS=0 (no fix turn, PREPR_STATE=off): a red determinism
#       finding does not block, as the knob documents (lead review lr-5811)
#   V8  a lead marker with no reason on its line: the real marker-reason pack
#       component is red, and that line blocks the PR (exit 6); with a reason,
#       green
#   B1  prompts/build-discipline.md has the BH-5797 section, D58-D63, one rule
#       for each ticket pattern
#   B2  D46 says the allow marker needs its reason on the line, for the lead
# Fixture worktrees hold copies of the REAL gates (checks-run + checks/,
# the determinism lint + its conf, bin/test-impact.sh) and a stub pack scripted
# per call, driven through the real prepr_gate with the real CC() and a stub
# agent-call.sh, the way tests/rb-prepr-rules-pack.bh-3513-test.sh does.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/builder-test-discipline.bh-5797-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v jq >/dev/null || { echo "builder-test-discipline: git and jq are required"; exit 2; }

NOW=1790000000
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export TEST_IMPACT_DURATIONS_FILE="$T/state/test-impact-durations.tsv"
unset RATCHET_BASE TI_BASE

# $H: the real lane-gate.sh over the real registry. $HZ: RULES_PACK_BLOCK=0.
H="$T/h"; HZ="$T/hz"
scratch_install_closure bin/lib/prepr-gate.sh "$H" >/dev/null || bad "could not install the prepr-gate closure"
scratch_install_closure bin/lib/prepr-gate.sh "$HZ" >/dev/null || bad "could not install the prepr-gate closure (HZ)"
printf 'lane_knob() { case "$2" in RB_PREPR_FIX_TURNS) echo 1 ;; RULES_PACK_BLOCK) echo 0 ;; esac; }\n' > "$HZ/bin/lib/lane-gate.sh"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"

awk '/^CC\(\) \{ # CC <stage>/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
grep -q 'agent-call.sh' "$T/cc.sh" && ok || bad "could not lift CC() from bin/run-build.sh"
for h in "$H" "$HZ"; do
  cat > "$h/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s\n' "$1" "$3" "$4" >> "$CALLLOG"
echo "stub ran" > "$5"
[ -n "${STUB_FIX:-}" ] && [ -f "$STUB_FIX" ] && bash "$STUB_FIX"
exit 0
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTLOG"\nexit 0\n' > "$h/bin/alert-line.sh"
  chmod +x "$h/bin/agent-call.sh" "$h/bin/alert-line.sh"
done

# The stub pack: rc and stdout from $PACK_CTL/rc and $PACK_CTL/out (every call).
cat > "$T/rules-pack.stub" <<'SH'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
[ -n "$out" ] && mkdir -p "$out"
[ -f "$PACK_CTL/out" ] && cat "$PACK_CTL/out"
exit "$(cat "$PACK_CTL/rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/rules-pack.stub"

# mkwt <name> <build-fn> — a fixture worktree on ticket/x over main.
mkwt() {
  local w="$T/wt-$1"
  mkdir -p "$w/bin" "$w/catalog" "$w/tests"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$DIR/bin/test-impact.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  cp "$T/rules-pack.stub" "$w/bin/rules-pack.sh"
  ( cd "$w" || exit 1
    git init -q -b main && git config user.email t@example.com && git config user.name t
    git config commit.gpgsign false
    printf '#!/bin/bash\necho mapped\n' > bin/mapped.sh
    printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/mapped.sh" >/dev/null\nbash "$DIR/bin/rules-pack.sh" --list >/dev/null\n' > tests/mapped-test.sh
    chmod +x bin/*.sh tests/*.sh
    git add -A && git commit -qm base
    git checkout -qb ticket/x
    "$2"
    git add -A && git commit -qm build ) >/dev/null 2>&1
  printf '%s' "$w"
}
add_plain()  { printf '#!/bin/bash\necho plain\n' > bin/mapped.sh; }
add_random() { printf '#!/bin/bash\nn=$%s\necho "$n"\n' RANDOM > tests/rand-test.sh; }
add_orphan() { printf '#!/bin/bash\necho new\n' > bin/new-tool.sh; chmod +x bin/new-tool.sh; }
cat > "$T/fix-random.sh" <<'SH'
printf '#!/bin/bash\nn=7\necho "$n"\n' > tests/rand-test.sh
git add -A && git commit -qm "fix the determinism finding"
SH

# drive <wt> <case> <harness> [env...] — prepr_gate on the fixture.
drive() {
  local w="$1" c="$2" h="$3"; shift 3
  mkdir -p "$T/$c/ctl"
  ( cd "$w" || exit 1
    env HARNESS="$h" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x \
        LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/$c/calls" STUB_FIX= PACK_CTL="$T/$c/ctl" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CG_ORIENT=""
      . "$0"
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . main "$BUILD"
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION PREPR_PACK_STATE PREPR_PACK_OUT > "$BUILD/vars.sh"
      declare -p PREPR_LINT_STATE >> "$BUILD/vars.sh" 2>/dev/null || true
    ' "$T/cc.sh" >"$T/$c/out.txt" 2>&1 )
}
span() { awk '/^# >>> rules pack block/{f=1} f{print} /^# <<< rules pack block/{exit}' "$1"; }
span "$DIR/bin/lib/rb/pr.sh" > "$T/span-pr.sh"
span "$DIR/bin/lib/rb/execute.sh" > "$T/span-exec.sh"
# block <case> <harness> <span-file> — the span after the case's prepr_gate; prints its exit code.
block() {
  local c="$1" h="$2" s="$3"
  rm -f "$T/$c/RESULT" "$T/$c/escalate" "$T/$c/rules-pack-block.txt"
  env HARNESS="$h" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 LANE_REGISTRY="$T/lanes.json" ALERTLOG="$T/$c/alerts" \
  bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
    escalate_block() { printf "%s\n%s\n" "$1" "$2" > "$BUILD/escalate"; }
    . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
    . <(sed "s/^declare -- /declare -g /" "$BUILD/vars.sh")
    . "$0"
    echo PR_CREATE_REACHED
  ' "$s" > "$T/$c/block.out" 2>&1
  echo $?
}

# ── V1 (acceptance test 1): a hand copy of bin/lib/x.sh ─────────────────────
# The real lint on a clone of this checkout with one hand-copying suite added.
CL="$T/clone"; git clone -q "$DIR" "$CL" 2>/dev/null || bad "V1 cannot clone $DIR"
L='bin/''lib'
( cd "$CL" && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false
  git checkout -q -b ticket/v1
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nmkdir -p "$T/h/%s"\ncp "$DIR/%s/x.sh" "$T/h/%s/"\n' "$L" "$L" "$L" > tests/handcopy-v1-test.sh
  git add tests/handcopy-v1-test.sh && git commit -qm "a hand copy" ) >/dev/null 2>&1
V1BASE=$(git -C "$CL" rev-parse HEAD~1 2>/dev/null)
( HARNESS_TEST_SANDBOX=1 "$CL/bin/rules-pack.sh" --base "$V1BASE" --only scratch-closure --runner local --out "$T/v1-pack" ) > "$T/v1-pack.out" 2>"$T/v1-pack.err"; rc=$?
LINE=$(grep '^scratch-closure: ' "$T/v1-pack.out" | head -1)
[ "$rc" = 1 ] && grep -q 'handcopy-v1-test.sh' <<<"$LINE" && ok || bad "V1 the real scratch-closure lint is not red on a hand copy (rc $rc): $(cat "$T/v1-pack.out") $(tail -3 "$T/v1-pack.err")"
W=$(mkwt v1 add_plain)
mkdir -p "$T/v1/ctl"; echo 1 > "$T/v1/ctl/rc"; printf '%s\n' "${LINE:-scratch-closure: tests/handcopy-v1-test.sh:5}" > "$T/v1/ctl/out"
drive "$W" v1 "$H"
RC=$(block v1 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "V1 the verify step let a hand copy reach PR create (rc $RC): $(cat "$T/v1/block.out")"
grep -q 'handcopy-v1-test.sh' "$T/v1/rules-pack-block.txt" 2>/dev/null && ok || bad "V1 the block file does not name the suite"

# ── V2: RANDOM left red by the fix turn ────────────────────────────────────
W=$(mkwt v2 add_random)
drive "$W" v2 "$H"
grep -q 'rand-test.sh' "$T/v2/prepr-findings.txt" 2>/dev/null && ok || bad "V2 the determinism lint found nothing: $(cat "$T/v2/out.txt" | tail -5)"
RC=$(block v2 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "V2 a red determinism finding reached PR create (rc $RC): $(tail -3 "$T/v2/block.out")"
grep -q 'rand-test.sh' "$T/v2/rules-pack-block.txt" 2>/dev/null && ok || bad "V2 the block file does not name the line: $(cat "$T/v2/rules-pack-block.txt" 2>/dev/null)"
case "$(cat "$T/v2/RESULT" 2>/dev/null)" in "REVIEW_BLOCKED rules-pack: "*) ok ;; *) bad "V2 RESULT '$(cat "$T/v2/RESULT" 2>/dev/null)'" ;; esac

# ── V3: an orphan ───────────────────────────────────────────────────────────
W=$(mkwt v3 add_orphan)
drive "$W" v3 "$H"
grep -q '^ORPHAN bin/new-tool.sh' "$T/v3/prepr-findings.txt" 2>/dev/null && ok || bad "V3 no ORPHAN finding: $(cat "$T/v3/prepr-findings.txt" 2>/dev/null)"
RC=$(block v3 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "V3 an orphan reached PR create (rc $RC)"

# ── V4: fast-lints data is in the pack ──────────────────────────────────────
"$DIR/bin/rules-pack.sh" --list 2>/dev/null | grep -q '^fast-lints-data[[:space:]]' && ok || bad "V4 the rules pack has no fast-lints-data component"
awk -F'\t' '$1 == "fast-lints-data" && $2 == "tree" && $4 == "tests/fast-lints-data.bh-3860-test.sh" {f = 1} END {exit !f}' "$DIR/catalog/rules-pack.tsv" \
  && ok || bad "V4 the catalog row is not 'fast-lints-data tree suite tests/fast-lints-data.bh-3860-test.sh'"

# ── V5: the fix turn fixes it ───────────────────────────────────────────────
W=$(mkwt v5 add_random)
drive "$W" v5 "$H" STUB_FIX="$T/fix-random.sh"
RC=$(block v5 "$H" "$T/span-pr.sh")
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/v5/block.out" && ok || bad "V5 a fixed finding was blocked (rc $RC): $(cat "$T/v5/block.out")"

# ── V6: knob 0 is warn only ─────────────────────────────────────────────────
W=$(mkwt v6 add_random)
drive "$W" v6 "$HZ"
RC=$(block v6 "$HZ" "$T/span-pr.sh")
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/v6/block.out" && ok || bad "V6 knob 0 still blocked (rc $RC)"

# ── V7: the execute.sh span ─────────────────────────────────────────────────
RC=$(block v2 "$H" "$T/span-exec.sh")
[ "$RC" = 6 ] && ok || bad "V7 the execute.sh span let a red determinism finding through (rc $RC)"

# ── V9: RB_PREPR_FIX_TURNS=0 is detection only for the fast lints ──────────
# (lead review lr-5811): no fix turn ran, so a red determinism finding opens
# the PR with the section, as the knob documents.
H0="$T/h0"
scratch_install_closure bin/lib/prepr-gate.sh "$H0" >/dev/null || bad "could not install the prepr-gate closure (H0)"
printf 'lane_knob() { case "$2" in RB_PREPR_FIX_TURNS) echo 0 ;; RULES_PACK_BLOCK) echo 1 ;; esac; }\n' > "$H0/bin/lib/lane-gate.sh"
cp "$H/bin/agent-call.sh" "$H/bin/alert-line.sh" "$H0/bin/"
W=$(mkwt v9 add_random)
drive "$W" v9 "$H0"
grep -q 'state=off' "$T/v9/prepr.txt" 2>/dev/null && ok || bad "V9 precondition: the gate did not run detection only: $(cat "$T/v9/prepr.txt" 2>/dev/null)"
RC=$(block v9 "$H0" "$T/span-pr.sh")
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/v9/block.out" && ok || bad "V9 knob 0 turns blocked a fast-lint finding with no fix turn (rc $RC)"

# ── V8: a lead marker with no reason fails the verify step ─────────────────
CL8="$T/clone8"; git clone -q "$DIR" "$CL8" 2>/dev/null || bad "V8 cannot clone $DIR"
DOK="determinism: ""ok"
( cd "$CL8" && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false
  git checkout -q -b ticket/v8
  printf '#!/bin/bash\nsleep 0.2 # %s\n' "$DOK" > tests/bare-marker-v8-test.sh
  git add tests/bare-marker-v8-test.sh && git commit -qm "a bare marker" ) >/dev/null 2>&1
V8BASE=$(git -C "$CL8" rev-parse HEAD~1 2>/dev/null)
( HARNESS_TEST_SANDBOX=1 "$CL8/bin/rules-pack.sh" --base "$V8BASE" --only marker-reason --runner local --out "$T/v8-pack" ) > "$T/v8-pack.out" 2>"$T/v8-pack.err"; rc=$?
LINE8=$(grep '^marker-reason: ' "$T/v8-pack.out" | head -1)
[ "$rc" = 1 ] && grep -q 'bare-marker-v8-test.sh' <<<"$LINE8" && ok || bad "V8 the real marker-reason component is not red on a bare marker (rc $rc): $(cat "$T/v8-pack.out") $(tail -3 "$T/v8-pack.err")"
W=$(mkwt v8 add_plain)
mkdir -p "$T/v8/ctl"; echo 1 > "$T/v8/ctl/rc"; printf '%s\n' "${LINE8:-marker-reason: tests/bare-marker-v8-test.sh}" > "$T/v8/ctl/out"
drive "$W" v8 "$H"
RC=$(block v8 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && grep -q 'bare-marker-v8-test.sh' "$T/v8/rules-pack-block.txt" 2>/dev/null && ok || bad "V8 a bare marker reached PR create (rc $RC)"
( cd "$CL8" && printf '#!/bin/bash\nsleep 0.2 # %s — a bounded wait\n' "$DOK" > tests/bare-marker-v8-test.sh && git commit -qam "the reason" ) >/dev/null 2>&1
( HARNESS_TEST_SANDBOX=1 "$CL8/bin/rules-pack.sh" --base "$V8BASE" --only marker-reason --runner local --out "$T/v8b-pack" ) > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "V8 a marker with its reason is still red (rc $rc)"

# ── B1/B2: the prompt ───────────────────────────────────────────────────────
BD="$DIR/prompts/build-discipline.md"
SEC=$(awk 'f && /^## /{exit} /^## Added 2026-10-09 \(BH-5797\)/{f=1} f' "$BD")
[ -n "$SEC" ] && ok || bad "B1 no '## Added 2026-10-09 (BH-5797)' section"
for d in D58 D59 D60 D61 D62 D63; do grep -q "^- \*\*$d " <<<"$SEC" && ok || bad "B1 no $d rule in the BH-5797 section"; done
for topic in scratch_install_closure needs-human RANDOM GH_TOKEN origin/main 'register' 'branch' 'mutation' 'format the real code'; do
  grep -qi -- "$topic" <<<"$SEC" && ok || bad "B1 the section has no line about '$topic'"
done
awk '/^- \*\*D46 / && /reason on the same line/ && /lead review/ {f = 1} END {exit !f}' "$BD" && ok || bad "B2 D46 does not say the allow marker needs its reason on the line for the lead review"

echo "builder-test-discipline.bh-5797: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
