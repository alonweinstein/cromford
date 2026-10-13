#!/bin/bash
# tests/rb-prepr-late.bh-2021-test.sh — BH-2021: the pre-PR gate judges the head
# that actually opens the PR. BH-1706's gate runs once, right after execute;
# the review fix rounds and the pre-PR rebase onto origin/$BASE still move the
# head after it. #1983 got its raw `rm -rf "$PD/…"` from a review fix round and
# its sigpipe-negative hit from main's newer lint on the rebase, both after the
# one-shot gate. The late pass (`prepr_gate_late`, the `# >>> prepr late` block
# after `# <<< pre-pr rebase`) re-runs the same gate on the final head, skips
# when that head is the one already judged, and shares the build's single fix
# turn with the first pass.
#
# Fixtures are scratch git repos holding copies of the REAL gates, driven with
# the real CC() lifted from the driver and a stub agent-call.sh (same shape as
# tests/rb-prepr-gate.bh-1706-test.sh). The violating lines are assembled at
# runtime so this file stays clean under both gates.
# Run from anywhere: tests/rb-prepr-late.bh-2021-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/prepr-gate.sh"
H="$T/h"
mkdir -p "$H/bin/lib"
cp "$LIB" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"

awk '/^CC\(\) \{ # CC <stage>/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
grep -q 'agent-call.sh' "$T/cc.sh" && ok || bad "could not lift CC() from bin/run-build.sh"

cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s\n' "$1" "$3" "$4" >> "$CALLLOG"
printf '%s\n' "$6" >> "$CALLLOG.prompt"
echo "stub ran" > "$5"
[ -n "${STUB_FIX:-}" ] && [ -f "$STUB_FIX" ] && bash "$STUB_FIX"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# Violating lines, assembled so this file never contains them.
RAW_RM=$(printf '%s -rf "$X"' rm)
SIGNEG=$(printf 'echo a %s grep -q a && bad "a must not appear"' '|')
SCRATCH_SRC='. "$(dirname "$0")/lib/scratch.sh" || exit 1'

mkwt() { # mkwt <name> <main-setup> <build-setup> — worktree on ticket/x over main
  local w="$T/wt-$1"; shift
  mkdir -p "$w/bin" "$w/catalog" "$w/tests"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  ( cd "$w" || exit 1
    git init -q -b main && git config user.email t@example.com && git config user.name t
    git config commit.gpgsign false
    "$1"
    git add -A && git commit -qm base
    git checkout -qb ticket/x
    "$2"
    git add -A && git commit -qm build ) >/dev/null 2>&1
  printf '%s' "$w"
}
none()      { :; }
add_rawrm() { printf '#!/bin/bash\n%s\nX=/nonexistent\n%s\n' "$SCRATCH_SRC" "$RAW_RM" > tests/x-test.sh; }
add_clean() { printf '#!/bin/bash\n%s\necho hi\n' "$SCRATCH_SRC" > tests/ok-test.sh; }

# Commits made AFTER the first pass (a review fix round, a rebase), and the
# scripted fixes the stub agent applies. Each runs in the worktree.
cat > "$T/late-rawrm.sh" <<SH
printf '#!/bin/bash\n%s\nX=/nonexistent\n%s\n' '$SCRATCH_SRC' '$RAW_RM' > tests/x-test.sh
git add -A && git commit -qm "review fix round"
SH
cat > "$T/late-rawrm-w.sh" <<SH
printf '#!/bin/bash\n%s\nX=/nonexistent\n%s\n' '$SCRATCH_SRC' '$RAW_RM' > tests/w-test.sh
git add -A && git commit -qm "review fix round"
SH
cat > "$T/late-signeg.sh" <<SH
cat > tests/y-test.sh <<'EOF'
#!/bin/bash
$SCRATCH_SRC
bad() { echo bad; }
$SIGNEG
EOF
git add -A && git commit -qm "review fix round"
SH
cat > "$T/fix-x.sh" <<SH
printf '#!/bin/bash\n%s\nscratch_rm "\$T/x"\n' '$SCRATCH_SRC' > tests/x-test.sh
git add -A && git commit -qm fix
SH
cp "$T/fix-x.sh" "$T/late-fix-x.sh"
# Adversarial negatives: none of these is a finding.
cat > "$T/late-negatives.sh" <<SH
cat > tests/n-test.sh <<'EOF'
#!/bin/bash
$SCRATCH_SRC
X=\$T/y
mkdir -p "\$T/x"
rm -rf "\$T/x"
rm -rf "\${T:?}/x"
scratch_rm "\$X"
rm -f "\$X"
bad() { echo bad; }
grep -q a <<<"\$(echo b)" && bad "a must not appear"
cat > "\$T/h.sh" <<'IN'
$RAW_RM
IN
EOF
git add -A && git commit -qm "review fix round"
SH

# drive <wt> <case> <late-script|-> [env...] — first pass through prepr_gate,
# then the late commit (if any), then prepr_gate_late; the calls the first
# pass made land in calls.first; the globals in vars.sh.
drive() {
  local w="$1" c="$2" late="$3"; shift 3
  mkdir -p "$T/$c"
  ( cd "$w" || exit 1
    env HARNESS="$H" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x \
        LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/$c/calls" STUB_FIX= LATE="$late" BASEREF="${BASEREF:-main}" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CG_ORIENT=""
      . "$0"
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . "$BASEREF" "$BUILD"
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION > "$BUILD/vars.first.sh"
      if [ -f "$BUILD/calls" ]; then cp "$BUILD/calls" "$BUILD/calls.first"; fi
      if [ "$LATE" != - ]; then STUB_FIX= bash "$LATE" >/dev/null 2>&1; fi
      prepr_gate_late . "$BASEREF" "$BUILD"
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION > "$BUILD/vars.sh"
    ' "$T/cc.sh" >"$T/$c/out.txt" 2>&1 )
}
calls()      { [ -f "$T/$1/calls" ] && wc -l < "$T/$1/calls" | tr -d ' ' || echo 0; }
calls_first(){ [ -f "$T/$1/calls.first" ] && wc -l < "$T/$1/calls.first" | tr -d ' ' || echo 0; }
late_calls() { echo $(( $(calls "$1") - $(calls_first "$1") )); }
vars()  { PREPR_STATE="<unset>"; PREPR_NOTE="<unset>"; PREPR_SECTION="<unset>"
          [ -f "$T/$1/vars.sh" ] && . <(sed 's/^declare -- /declare -g /' "$T/$1/vars.sh"); }
late_state() { sed -n 's/^state=//p' "$T/$1/prepr-late/prepr.txt" 2>/dev/null; }

# ── L0: a clean first pass records the head it judged ──────────────────────
W=$(mkwt l0 none add_clean)
drive "$W" l0 -
[ "$(cat "$T/l0/prepr-head" 2>/dev/null)" = "$(git -C "$W" rev-parse HEAD)" ] && ok \
  || bad "L0: \$BUILD/prepr-head is not the judged HEAD: $(cat "$T/l0/out.txt")"

# ── L1: clean first pass, then a review fix round adds a raw rm ────────────
W=$(mkwt l1 none add_clean)
drive "$W" l1 "$T/late-rawrm.sh" STUB_FIX="$T/fix-x.sh"
vars l1
[ "$(calls_first l1)" = 0 ] && ok || bad "L1: the first pass was not clean"
[ "$(late_calls l1)" = 1 ] && ok || bad "L1: the late pass made $(late_calls l1) agent calls, want 1: $(cat "$T/l1/out.txt")"
grep -q 'tests-scratch-only' "$T/l1/calls.prompt" 2>/dev/null && grep -q 'tests/x-test.sh' "$T/l1/calls.prompt" && ok \
  || bad "L1: the late brief does not carry the R2 finding in tests/x-test.sh"
[ "$(late_state l1)" = fixed ] && ok || bad "L1: prepr-late/prepr.txt state '$(late_state l1)', want fixed"
[ -z "$PREPR_NOTE" ] && [ "$PREPR_STATE" = fixed ] && ok || bad "L1: globals state='$PREPR_STATE' note='$PREPR_NOTE'"
grep -q 'PREPR late state=fixed .*fix_calls=1' "$T/l1/pipeline.log" 2>/dev/null && ok || bad "L1: no 'PREPR late state=fixed' log line"
[ "$(cat "$T/l1/prepr-head" 2>/dev/null)" = "$(git -C "$W" rev-parse HEAD)" ] && ok || bad "L1: prepr-head not moved to the late head"
# Same, no fix: red with the finding in the section.
W=$(mkwt l1r none add_clean)
drive "$W" l1r "$T/late-rawrm.sh"
vars l1r
[ "$(late_calls l1r)" = 1 ] && ok || bad "L1r: late calls $(late_calls l1r), want 1"
[ "$(late_state l1r)" = red ] && [ "$PREPR_STATE" = red ] && ok || bad "L1r: state '$(late_state l1r)'/'$PREPR_STATE', want red"
[ "$PREPR_NOTE" = " | prepr=red" ] && ok || bad "L1r: note '$PREPR_NOTE'"
grep -q '^## Pre-PR gate: unresolved' <<<"$PREPR_SECTION" && grep -q 'tests/x-test.sh' <<<"$PREPR_SECTION" && ok \
  || bad "L1r: the section does not name tests/x-test.sh: $PREPR_SECTION"

# ── L2: nothing moved after the first pass -> unchanged, no scan ───────────
W=$(mkwt l2 none add_rawrm)
drive "$W" l2 -
vars l2
[ "$(calls_first l2)" = 1 ] && [ "$(late_calls l2)" = 0 ] && ok || bad "L2: calls first=$(calls_first l2) late=$(late_calls l2), want 1/0"
[ "$(late_state l2)" = unchanged ] && ok || bad "L2: late state '$(late_state l2)', want unchanged: $(cat "$T/l2/out.txt")"
[ ! -e "$T/l2/prepr-late/checks.txt" ] && ok || bad "L2: an unchanged head was re-scanned"
[ "$PREPR_STATE" = red ] && [ "$PREPR_NOTE" = " | prepr=red" ] && grep -q 'tests/x-test.sh' <<<"$PREPR_SECTION" && ok \
  || bad "L2: the first pass's red verdict did not survive: '$PREPR_STATE' '$PREPR_NOTE'"
grep -q 'PREPR late state=unchanged' "$T/l2/pipeline.log" 2>/dev/null && ok || bad "L2: no unchanged log line"

# ── L3: first pass red, a later commit fixes it -> late clean clears it ────
W=$(mkwt l3 none add_rawrm)
drive "$W" l3 "$T/late-fix-x.sh"
vars l3
[ "$(late_calls l3)" = 0 ] && ok || bad "L3: late calls $(late_calls l3), want 0"
[ "$(late_state l3)" = clean ] && [ -z "$PREPR_NOTE" ] && [ -z "$PREPR_SECTION" ] && ok \
  || bad "L3: late '$(late_state l3)' note '$PREPR_NOTE' — a clean final head must clear the first pass's red"

# ── L3b: first pass spent the turn (fixed), a later commit adds a raw rm ──
W=$(mkwt l3b none add_rawrm)
drive "$W" l3b "$T/late-rawrm-w.sh" STUB_FIX="$T/fix-x.sh"
vars l3b
[ "$(calls_first l3b)" = 1 ] && [ "$(late_calls l3b)" = 0 ] && ok \
  || bad "L3b: calls first=$(calls_first l3b) late=$(late_calls l3b), want 1/0 (one turn per build)"
[ "$(late_state l3b)" = red ] && [ "$PREPR_NOTE" = " | prepr=red" ] && ok || bad "L3b: late '$(late_state l3b)' note '$PREPR_NOTE', want red"
grep -q 'already spent' <<<"$PREPR_SECTION" && grep -q 'tests/w-test.sh' <<<"$PREPR_SECTION" && ok \
  || bad "L3b: the section does not say the turn was spent: $PREPR_SECTION"
W=$(mkwt l3c none add_clean)
drive "$W" l3c "$T/late-rawrm.sh" RB_PREPR_FIX_TURNS=0 STUB_FIX="$T/fix-x.sh"
vars l3c
[ "$(calls l3c)" = 0 ] && [ "$(late_state l3c)" = off ] && [ -z "$PREPR_NOTE" ] && ok \
  || bad "L3c: turns=0 late was '$(late_state l3c)' with $(calls l3c) calls, want off/0"
grep -q 'tests/x-test.sh' "$T/l3c/prepr-late/prepr-findings.txt" 2>/dev/null && ok || bad "L3c: findings not recorded"

# ── L4: a late sigpipe-negative line is an in-diff finding ─────────────────
W=$(mkwt l4 none add_clean)
drive "$W" l4 "$T/late-signeg.sh"
vars l4
grep -q '^tests/y-test.sh:[0-9]*: sigpipe-negative' "$T/l4/prepr-late/prepr-findings.txt" 2>/dev/null && ok \
  || bad "L4: no sigpipe-negative finding in prepr-late/prepr-findings.txt: $(cat "$T/l4/prepr-late/determinism.txt" 2>/dev/null | head -20)"
[ "$(late_calls l4)" = 1 ] && [ "$(late_state l4)" = red ] && ok || bad "L4: late '$(late_state l4)' calls $(late_calls l4), want red/1"

# ── L5: adversarial negatives after the first pass; a main-only raw rm ─────
W=$(mkwt l5 add_rawrm add_clean)
drive "$W" l5 "$T/late-negatives.sh"
vars l5
[ "$(calls l5)" = 0 ] && ok || bad "L5: negatives bought $(calls l5) agent calls"
[ "$(late_state l5)" = clean ] && [ -z "$PREPR_NOTE" ] && ok \
  || bad "L5: late '$(late_state l5)', want clean: $(cat "$T/l5/prepr-late/prepr-findings.txt" 2>/dev/null)"
[ ! -s "$T/l5/prepr-late/prepr-findings.txt" ] && [ -f "$T/l5/prepr-late/prepr-findings.txt" ] && ok || bad "L5: in-diff findings recorded for negatives"
grep -q 'tests/x-test.sh' "$T/l5/prepr-late/prepr-preexisting.txt" 2>/dev/null && ok || bad "L5: the main-only raw rm is not preexisting"
grep -q 'PREPR late state=clean .*preexisting=[1-9]' "$T/l5/pipeline.log" 2>/dev/null && ok || bad "L5: the log line does not count preexisting"

# ── L8: rebase onto an origin/main ahead of a stale local main ─────────────
W=$(mkwt l8 none add_clean)
cat > "$T/rebase-l8.sh" <<SH
git checkout -q main
mkdir -p tests
printf '#!/bin/bash\n%s\nX=/nonexistent\n%s\n' '$SCRATCH_SRC' '$RAW_RM' > tests/m-test.sh
git add -A && git commit -qm "main moved"
git update-ref refs/remotes/origin/main HEAD
git reset -q --hard HEAD~1
git checkout -q ticket/x
git rebase -q origin/main
SH
drive "$W" l8 "$T/rebase-l8.sh"
vars l8
[ "$(git -C "$W" rev-parse main)" != "$(git -C "$W" rev-parse origin/main)" ] && ok || bad "L8: fixture did not leave local main stale"
[ "$(calls l8)" = 0 ] && [ "$(late_state l8)" = clean ] && ok \
  || bad "L8: main's own file was blamed on the build: late '$(late_state l8)' calls $(calls l8)"
grep -q 'tests/m-test.sh' "$T/l8/prepr-late/prepr-preexisting.txt" 2>/dev/null && ok || bad "L8: tests/m-test.sh is not preexisting"

# ── L9: a late scan that cannot run keeps the first pass's verdict ───────
cat > "$T/late-crash.sh" <<'SH'
printf '#!/bin/bash\necho boom\nexit 2\n' > bin/checks-run.sh
git add -A && git commit -qm "rebase brought a broken gate"
SH
W=$(mkwt l9 none add_rawrm)
drive "$W" l9 "$T/late-crash.sh"
vars l9
[ "$(late_state l9)" = could-not-run ] && ok || bad "L9: late state '$(late_state l9)', want could-not-run"
[ "$PREPR_STATE" = red ] && [ "$PREPR_NOTE" = " | prepr=red" ] && grep -q 'tests/x-test.sh' <<<"$PREPR_SECTION" && ok \
  || bad "L9: a late could-not-run dropped the first pass's red: '$PREPR_STATE' '$PREPR_NOTE'"
[ "$(cat "$T/l9/prepr-head" 2>/dev/null)" != "$(git -C "$W" rev-parse HEAD)" ] && ok \
  || bad "L9: a scan that could not run recorded its head as judged"

# ── L6: the production blocks, lifted from the driver, with the real CC() ──
awk '/^# >>> prepr gate/{f=1;next} /^# <<< prepr gate/{exit} f' "$RB_ALL" > "$T/prepr-block.sh"
awk '/^# >>> prepr late/{f=1;next} /^# <<< prepr late/{exit} f' "$RB_ALL" > "$T/prepr-late-block.sh"
grep -q 'prepr_gate_late' "$T/prepr-late-block.sh" && ok || bad "L6: no '# >>> prepr late' block calling prepr_gate_late in bin/run-build.sh"
W=$(mkwt l6 none add_clean)
mkdir -p "$T/l6"
( cd "$W" || exit 1
  env HARNESS="$H" BUILD="$T/l6" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x BASE=main \
      LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/l6/calls" STUB_FIX="$T/fix-x.sh" LATE="$T/late-rawrm.sh" \
  bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    CG_ORIENT=""
    . "$0"; . "$1"
    STUB_FIX= bash "$LATE" >/dev/null 2>&1
    . "$2"
    declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION > "$BUILD/vars.sh"
  ' "$T/cc.sh" "$T/prepr-block.sh" "$T/prepr-late-block.sh" >"$T/l6/out.txt" 2>&1 )
vars l6
[ "$(calls l6)" = 1 ] && ok || bad "L6: the driver blocks made $(calls l6) agent calls, want 1: $(cat "$T/l6/out.txt")"
grep -q 'PREPR late state=fixed' "$T/l6/pipeline.log" 2>/dev/null && ok || bad "L6: no 'PREPR late state=fixed' in pipeline.log"
[ "$PREPR_STATE" = fixed ] && [ -z "$PREPR_NOTE" ] && ok || bad "L6: driver ended '$PREPR_STATE' '$PREPR_NOTE'"

# ── L7: the late block sits after the rebase and before the push/PR ────────
awk '/^# <<< pre-pr rebase/{a=NR} /^# >>> prepr late/{b=NR} /^# >>> pre-pr squash/{c=NR}
     /^# >>> pr open/{d=NR} /^# >>> head-bound approval/{e=NR}
     END{exit !(a && b && c && d && e && a<b && b<c && c<d && d<e)}' "$RB_ALL" && ok \
  || bad "L7: marker order is not <<< pre-pr rebase < >>> prepr late < >>> pre-pr squash < >>> pr open < >>> head-bound approval"

echo "rb-prepr-late: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
