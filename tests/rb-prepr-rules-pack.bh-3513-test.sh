#!/bin/bash
# tests/rb-prepr-rules-pack.bh-3513-test.sh — BH-3513 (BH-3477.4): the rules
# pack (bin/rules-pack.sh, contract BH-3509) runs in three places:
#   1. the pre-push gate, bin/lib/prepr-gate.sh: its lines are in-diff
#      `RULES-PACK <id>: <line>` findings with the one fix turn, and a pack still
#      red after it blocks the PR (rules_pack_block, REVIEW_BLOCKED, exit 6)
#      under the RULES_PACK_BLOCK fly-pool knob;
#   2. HARNESS_SUITE_RUN's impact-gate arm, bin/lib/rb/gates.sh: the pack runs
#      first, the suites it ran are dropped from the gate (--skip-suites), and
#      a red pack folds into HARNESS_EXIT;
#   3. the PR body's evidence table, bin/evidence-summary.sh: one row.
#
# Every fixture worktree is a scratch git repo holding copies of the REAL gates
# (bin/checks-run.sh + checks/, bin/test-determinism-lint.sh + its conf,
# bin/test-impact.sh) plus a STUB bin/rules-pack.sh scripted per call through
# $PACK_CTL (rc.N, out.N, pre.N, suites.N for call N; call 1's files answer any
# call that has none). It is driven through the real prepr_gate with the real
# CC() and a stub $HARNESS/bin/agent-call.sh.
#
#   P1  a red pack is an in-diff finding: the fix turn's brief carries it, and
#       the pack runs with --tree . --skip checks-tree,determinism
#   P2  still red after the turn, knob 1: the pr.sh `rules pack block` span
#       exits 6 with REVIEW_BLOCKED rules-pack before PR create
#   P3  the turn fixes it: pack=clean, fixed, the span passes
#   P4  knob 0: warn only, the PR section names bin/rules-pack.sh (never the
#       determinism lint)
#   P4b the knob answers nothing: the block fires (fail closed)
#   P5  rc 125 / 2 / 1-with-no-line: could-not-run, other gates decide, no block
#   P5b no pack in the repo: skipped
#   P6  the execute.sh span sits after escalate_block() and PUSH_BRANCH execute,
#       and blocks like P2
#   P7  a fix turn that edits a ratchet baseline is red and pack=red (D2);
#       tests/jobs-client-modules.d/ is not a rules path
#   P8  the late pass keeps the first pass's pack verdict when its own pack
#       could not run, and on an unchanged head
#   H1  HARNESS_IMPACT_GATE_RUN: RULES_PACK line, --skip-suites only when the
#       pack ran, red folds into a gate rc 0 only, no pack = byte-identical
#   H2  bin/test-impact-gate.sh --skip-suites drops the suites after ranking
#   E1  bin/evidence-summary.sh renders the rules pack row
# Run from anywhere: tests/rb-prepr-rules-pack.bh-3513-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export TEST_IMPACT_DURATIONS_FILE="$T/state/test-impact-durations.tsv"

LIB="$DIR/bin/lib/prepr-gate.sh"
# $H: the real lane-gate.sh over the real registry. $HZ: a lane_knob that
# answers 0 for RULES_PACK_BLOCK. $HN: one that answers nothing for it.
H="$T/h"; HZ="$T/hz"; HN="$T/hn"
mkdir -p "$H/bin/lib" "$HZ/bin/lib" "$HN/bin/lib"
cp "$LIB" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$LIB" "$HZ/bin/lib/"; cp "$LIB" "$HN/bin/lib/"
cat > "$HZ/bin/lib/lane-gate.sh" <<'SH'
lane_knob() { case "$2" in RB_PREPR_FIX_TURNS) echo 1 ;; RULES_PACK_BLOCK) echo 0 ;; esac; }
SH
cat > "$HN/bin/lib/lane-gate.sh" <<'SH'
lane_knob() { case "$2" in RB_PREPR_FIX_TURNS) echo 1 ;; esac; }
SH
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"

awk '/^CC\(\) \{ # CC <stage>/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
grep -q 'agent-call.sh' "$T/cc.sh" && ok || bad "could not lift CC() from bin/run-build.sh"

for h in "$H" "$HZ" "$HN"; do
  cat > "$h/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s\n' "$1" "$3" "$4" >> "$CALLLOG"
printf '%s\n' "$6" >> "$CALLLOG.prompt"
echo "stub ran" > "$5"
[ -n "${STUB_FIX:-}" ] && [ -f "$STUB_FIX" ] && bash "$STUB_FIX"
exit 0
SH
  cat > "$h/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
  chmod +x "$h/bin/agent-call.sh" "$h/bin/alert-line.sh"
done

# The stub pack: the BH-3509 contract, answered from $PACK_CTL per call.
cat > "$T/rules-pack.stub" <<'SH'
#!/bin/bash
c="$PACK_CTL"
n=$(( $(cat "$c/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c/n"
printf '%s\n' "$*" >> "$c/argv"
k=$n; [ -f "$c/rc.$k" ] || k=1
out=""
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
if [ -n "$out" ]; then
  mkdir -p "$out"
  [ -f "$c/pre.$k" ] && cp "$c/pre.$k" "$out/preexisting.txt"
  [ -f "$c/suites.$k" ] && cp "$c/suites.$k" "$out/suites.txt"
fi
[ -f "$c/out.$k" ] && cat "$c/out.$k"
echo "stub pack stderr" >&2
exit "$(cat "$c/rc.$k")"
SH
chmod +x "$T/rules-pack.stub"

# mkwt <name> <build-setup-fn> [nopack] — a fixture worktree on ticket/x over main.
mkwt() {
  local w="$T/wt-$1"
  mkdir -p "$w/bin" "$w/catalog" "$w/tests"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$DIR/bin/test-impact.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  [ "${3:-}" = nopack ] || cp "$T/rules-pack.stub" "$w/bin/rules-pack.sh"
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
add_plain() { printf '#!/bin/bash\necho plain\n' > bin/mapped.sh; }

# pack <case> <call> <rc> [stdout-line] — script one call of the stub.
pack() {
  local c="$T/$1/ctl"; mkdir -p "$c"
  echo "$3" > "$c/rc.$2"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$c/out.$2"; else rm -f "$c/out.$2"; fi
}
FINDING='lib-root: bin/lib/x.sh:3 literal /root/harness'

cat > "$T/fix-commit.sh" <<'SH'
printf '#!/bin/bash\necho fixed\n' > bin/mapped.sh
git add -A && git commit -qm "fix the pack finding"
SH
cat > "$T/fix-baseline.sh" <<'SH'
mkdir -p tests/switch-ratchet.d && echo x > tests/switch-ratchet.d/x.drop
git add -A && git commit -qm "edit a ratchet baseline"
SH
cat > "$T/fix-jcm.sh" <<'SH'
mkdir -p tests/jobs-client-modules.d && echo y > tests/jobs-client-modules.d/y
git add -A && git commit -qm "touch jobs-client-modules.d"
SH

# drive <wt> <case> <harness> [env...] — prepr_gate on the fixture; with LATE=1
# a commit moves the head and prepr_gate_late runs; LATE=same runs it unmoved.
drive() {
  local w="$1" c="$2" h="$3"; shift 3
  mkdir -p "$T/$c/ctl"
  ( cd "$w" || exit 1
    env HARNESS="$h" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x \
        LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/$c/calls" STUB_FIX= PACK_CTL="$T/$c/ctl" LATE= "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CG_ORIENT=""
      . "$0"
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . main "$BUILD"
      declare -p PREPR_STATE PREPR_SECTION PREPR_PACK_STATE PREPR_PACK_OUT > "$BUILD/vars1.sh" 2>/dev/null
      if [ "$LATE" = 1 ]; then
        git commit -q --allow-empty -m move
        prepr_gate_late . main "$BUILD"
      elif [ "$LATE" = same ]; then
        prepr_gate_late . main "$BUILD"
      fi
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION PREPR_PACK_STATE PREPR_PACK_OUT > "$BUILD/vars.sh"
    ' "$T/cc.sh" >"$T/$c/out.txt" 2>&1 )
}
calls() { [ -f "$T/$1/calls" ] && wc -l < "$T/$1/calls" | tr -d ' ' || echo 0; }
vars()  { PREPR_STATE="<unset>"; PREPR_NOTE="<unset>"; PREPR_SECTION="<unset>"; PREPR_PACK_STATE="<unset>"; PREPR_PACK_OUT=""
          [ -f "$T/$1/vars.sh" ] && . <(sed 's/^declare -- /declare -g /' "$T/$1/vars.sh"); }

# Extract the `rules pack block` span from one module.
span() { awk '/^# >>> rules pack block/{f=1} f{print} /^# <<< rules pack block/{exit}' "$1"; }
span "$DIR/bin/lib/rb/pr.sh" > "$T/span-pr.sh"
span "$DIR/bin/lib/rb/execute.sh" > "$T/span-exec.sh"
[ -s "$T/span-pr.sh" ] && ok || bad "no '# >>> rules pack block' span in bin/lib/rb/pr.sh"
[ -s "$T/span-exec.sh" ] && ok || bad "no '# >>> rules pack block' span in bin/lib/rb/execute.sh"

# block <case> <harness> <span-file> — the span after the case's prepr_gate,
# with the driver's RESULT and escalate_block stubbed; prints its exit code.
block() {
  local c="$1" h="$2" s="$3"
  rm -f "$T/$c/RESULT" "$T/$c/escalate" "$T/$c/rules-pack-block.txt"
  env HARNESS="$h" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 LANE_REGISTRY="$T/lanes.json" \
      ALERTLOG="$T/$c/alerts" \
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

# ── P1: a red pack is an in-diff finding with the fix turn ──────────────────
W=$(mkwt p1 add_plain)
pack p1 1 1 "$FINDING"
drive "$W" p1 "$H"
vars p1
grep -qF "RULES-PACK $FINDING" "$T/p1/calls.prompt" 2>/dev/null && ok \
  || bad "P1: the fix brief does not carry the RULES-PACK line: $(cat "$T/p1/prepr-scan.txt" 2>/dev/null) $(cat "$T/p1/out.txt")"
grep -qF 'run it with `--only <id>` to reproduce' "$T/p1/calls.prompt" 2>/dev/null && ok || bad "P1: the brief does not say how to reproduce a pack finding"
grep -qx 'fix_calls=1' "$T/p1/prepr.txt" 2>/dev/null && ok || bad "P1: prepr.txt: $(tr '\n' ' ' < "$T/p1/prepr.txt" 2>/dev/null)"
grep -qx 'rules-pack rc=1' "$T/p1/prepr-scan.txt" 2>/dev/null && ok || bad "P1: prepr-scan.txt has no 'rules-pack rc=1'"
A=$(head -1 "$T/p1/ctl/argv" 2>/dev/null)
case " $A " in *" --skip checks-tree,determinism "*) ok ;; *) bad "P1: pack argv '$A' lacks --skip checks-tree,determinism" ;; esac
case " $A " in *" --tree . "*) ok ;; *) bad "P1: pack argv '$A' lacks --tree ." ;; esac
case " $A " in *" --base main "*) ok ;; *) bad "P1: pack argv '$A' lacks --base main" ;; esac
[ "$PREPR_STATE" = red ] && [ "$PREPR_PACK_STATE" = red ] && ok || bad "P1: state '$PREPR_STATE' pack '$PREPR_PACK_STATE', want red/red"
grep -qx 'pack=red' "$T/p1/prepr.txt" 2>/dev/null && ok || bad "P1: prepr.txt has no pack=red"
grep -q 'PREPR state=red .*fix_calls=1 pack=red$' "$T/p1/pipeline.log" && ok || bad "P1: the PREPR log line lacks ' pack=red' at its end: $(grep PREPR "$T/p1/pipeline.log")"

# ── P2: still red, knob 1 -> the pr.sh span blocks before PR create ──────────
RC=$(block p1 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "P2: the pr.sh span exited $RC, want 6: $(cat "$T/p1/block.out")"
case "$(cat "$T/p1/RESULT" 2>/dev/null)" in "REVIEW_BLOCKED rules-pack: 1 finding(s)"*) ok ;;
  *) bad "P2: RESULT '$(cat "$T/p1/RESULT" 2>/dev/null)'" ;; esac
grep -qF "$FINDING" "$T/p1/rules-pack-block.txt" 2>/dev/null && ok || bad "P2: rules-pack-block.txt does not hold the finding"
[ "$(head -1 "$T/p1/escalate" 2>/dev/null)" = rules-pack ] && ok || bad "P2: escalate_block gate arg '$(head -1 "$T/p1/escalate" 2>/dev/null)'"
grep -q PR_CREATE_REACHED "$T/p1/block.out" && bad "P2: the span let the build reach PR create" || ok
grep -qF 'BLOCKED: the rules pack is red' "$T/p1/alerts" 2>/dev/null && ok || bad "P2: no alert through alert-line.sh"

# ── P3: the fix turn fixes it ───────────────────────────────────────────────
W=$(mkwt p3 add_plain)
pack p3 1 1 "$FINDING"; pack p3 2 0
drive "$W" p3 "$H" STUB_FIX="$T/fix-commit.sh"
vars p3
[ "$PREPR_PACK_STATE" = clean ] && [ "$PREPR_STATE" = fixed ] && ok \
  || bad "P3: state '$PREPR_STATE' pack '$PREPR_PACK_STATE', want fixed/clean: $(cat "$T/p3/prepr-scan.txt" 2>/dev/null)"
grep -qx 'pack=clean' "$T/p3/prepr.txt" 2>/dev/null && ok || bad "P3: prepr.txt has no pack=clean"
RC=$(block p3 "$H" "$T/span-pr.sh")
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/p3/block.out" && [ ! -f "$T/p3/RESULT" ] && ok \
  || bad "P3: a clean pack was blocked (rc $RC): $(cat "$T/p3/block.out")"

# ── P4: knob 0 -> warn only, the section names the pack ─────────────────────
W=$(mkwt p4 add_plain)
pack p4 1 1 "$FINDING"
drive "$W" p4 "$HZ"
vars p4
RC=$(block p4 "$HZ" "$T/span-pr.sh")
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/p4/block.out" && ok || bad "P4: knob 0 still blocked (rc $RC)"
grep -qF 'PREPR rules pack red — RULES_PACK_BLOCK=0, the PR opens with the unresolved section' "$T/p4/pipeline.log" && ok \
  || bad "P4: no warn-only log line"
grep -qF '`bin/rules-pack.sh`' <<<"$PREPR_SECTION" && grep -qF "$FINDING" <<<"$PREPR_SECTION" && ok \
  || bad "P4: the section does not name bin/rules-pack.sh and the finding: $PREPR_SECTION"
grep -qF 'test-determinism-lint' <<<"$PREPR_SECTION" && bad "P4: a RULES-PACK line was credited to the determinism lint" || ok

# ── P4b: the knob answers nothing -> the block fires ────────────────────────
W=$(mkwt p4b add_plain)
pack p4b 1 1 "$FINDING"
drive "$W" p4b "$HN"
RC=$(block p4b "$HN" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "P4b: an unresolved RULES_PACK_BLOCK must fail closed (rc $RC)"

# ── P5: could-not-run never blocks and never decides the gate ───────────────
for v in 125 2 1; do
  c="p5-$v"
  W=$(mkwt "$c" add_plain)
  pack "$c" 1 "$v"
  drive "$W" "$c" "$H"
  vars "$c"
  grep -q '^rules-pack: could not run' "$T/$c/prepr-scan.txt" 2>/dev/null && ok || bad "P5 rc $v: prepr-scan.txt: $(cat "$T/$c/prepr-scan.txt" 2>/dev/null)"
  [ "$PREPR_PACK_STATE" = could-not-run ] && ok || bad "P5 rc $v: pack '$PREPR_PACK_STATE'"
  [ "$PREPR_STATE" = clean ] && ok || bad "P5 rc $v: state '$PREPR_STATE', want clean"
  [ "$(calls "$c")" = 0 ] && ok || bad "P5 rc $v: a pack that could not run bought a fix call"
  RC=$(block "$c" "$H" "$T/span-pr.sh")
  [ "$RC" = 0 ] && ok || bad "P5 rc $v: blocked (rc $RC)"
done

# ── P5b: no pack in the repo -> skipped ─────────────────────────────────────
W=$(mkwt p5b add_plain nopack)
drive "$W" p5b "$H"
vars p5b
grep -qx 'rules-pack: skipped' "$T/p5b/prepr-scan.txt" 2>/dev/null && ok || bad "P5b: prepr-scan.txt: $(cat "$T/p5b/prepr-scan.txt" 2>/dev/null)"
grep -qx 'pack=skipped' "$T/p5b/prepr.txt" 2>/dev/null && ok || bad "P5b: prepr.txt has no pack=skipped"
[ ! -f "$T/p5b/ctl/argv" ] && ok || bad "P5b: something ran a pack"
[ "$PREPR_STATE" = clean ] && ok || bad "P5b: state '$PREPR_STATE'"

# ── P6: the execute.sh call site ────────────────────────────────────────────
L_ESC=$(grep -n '^escalate_block() {' "$RB_ALL" | head -1 | cut -d: -f1)
L_PUSH=$(grep -n '^PUSH_BRANCH execute$' "$RB_ALL" | head -1 | cut -d: -f1)
L_RPB=$(grep -n 'rules_pack_block execute' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$L_ESC" ] && [ -n "$L_PUSH" ] && [ -n "$L_RPB" ] && [ "$L_RPB" -gt "$L_ESC" ] && [ "$L_RPB" -gt "$L_PUSH" ] && ok \
  || bad "P6: the execute call site (line ${L_RPB:-none}) must follow escalate_block() {(${L_ESC:-none}) and PUSH_BRANCH execute (${L_PUSH:-none})"
L_ESC_END=$(awk -v s="$L_ESC" 'NR > s && /^}$/ {print NR; exit}' "$RB_ALL")
[ -n "$L_RPB" ] && [ -n "$L_ESC_END" ] && [ "$L_RPB" -gt "$L_ESC_END" ] && ok || bad "P6: the call site is inside escalate_block()"
RC=$(block p1 "$H" "$T/span-exec.sh")
[ "$RC" = 6 ] && ok || bad "P6: the execute.sh span exited $RC, want 6"
case "$(cat "$T/p1/RESULT" 2>/dev/null)" in "REVIEW_BLOCKED rules-pack: 1 finding(s)"*) ok ;; *) bad "P6: RESULT '$(cat "$T/p1/RESULT" 2>/dev/null)'" ;; esac
grep -qF "$FINDING" "$T/p1/rules-pack-block.txt" 2>/dev/null && ok || bad "P6: no block file"

# ── P7: a fix turn that edits a ratchet baseline is red (D2) ────────────────
W=$(mkwt p7 add_plain)
pack p7 1 1 "$FINDING"; pack p7 2 0
drive "$W" p7 "$H" STUB_FIX="$T/fix-baseline.sh"
vars p7
[ "$PREPR_STATE" = red ] && ok || bad "P7: state '$PREPR_STATE', want red: $(cat "$T/p7/prepr-scan.txt" 2>/dev/null)"
grep -qF "edited the gate's own rules: tests/switch-ratchet.d/x.drop" <<<"$PREPR_SECTION" && ok || bad "P7: section: $PREPR_SECTION"
[ "$PREPR_PACK_STATE" = red ] && ok || bad "P7: a baseline edit that turned the pack green left pack '$PREPR_PACK_STATE'"
RC=$(block p7 "$H" "$T/span-pr.sh")
[ "$RC" = 6 ] && ok || bad "P7: the baseline edit was not blocked (rc $RC)"
W=$(mkwt p7j add_plain)
pack p7j 1 1 "$FINDING"; pack p7j 2 0
drive "$W" p7j "$H" STUB_FIX="$T/fix-jcm.sh"
vars p7j
[ "$PREPR_STATE" = fixed ] && [ "$PREPR_PACK_STATE" = clean ] && ok \
  || bad "P7: tests/jobs-client-modules.d/ is not a rules path (state '$PREPR_STATE' pack '$PREPR_PACK_STATE')"

# ── P8: the late pass keeps the first pass's pack verdict ───────────────────
W=$(mkwt p8 add_plain)
pack p8 1 1 "$FINDING"; pack p8 2 1 "$FINDING"; pack p8 3 125
drive "$W" p8 "$HZ" LATE=1
vars p8
grep -q 'PREPR late state=' "$T/p8/pipeline.log" && ok || bad "P8: the late pass did not run: $(cat "$T/p8/out.txt")"
grep -q '^rules-pack: could not run' "$T/p8/prepr-late/prepr-scan.txt" 2>/dev/null && ok || bad "P8: the late pack did not answer could-not-run"
[ "$PREPR_PACK_STATE" = red ] && ok || bad "P8: a late pack that could not run replaced red with '$PREPR_PACK_STATE'"
W=$(mkwt p8s add_plain)
pack p8s 1 1 "$FINDING"
drive "$W" p8s "$HZ" LATE=same
vars p8s
grep -q 'PREPR late state=unchanged' "$T/p8s/pipeline.log" && [ "$PREPR_PACK_STATE" = red ] && ok \
  || bad "P8: an unchanged head lost the pack verdict ('$PREPR_PACK_STATE')"

# ── H1: HARNESS_IMPACT_GATE_RUN ─────────────────────────────────────────────
awk '/^HARNESS_IMPACT_GATE_RUN\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/lib/rb/gates.sh" > "$T/hig.sh"
[ -s "$T/hig.sh" ] && ok || bad "H1: could not extract HARNESS_IMPACT_GATE_RUN"
# hrun <case> <gate-rc> [nopack] — the function in a scratch checkout.
hrun() {
  local c="$1" r="$T/$1/repo"
  mkdir -p "$r/bin" "$T/$c/build" "$T/$c/ctl"
  cat > "$r/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$GATE_ARGV"
echo "stub gate output"
exit "$GATE_RC"
SH
  chmod +x "$r/bin/test-impact-gate.sh"
  [ "${3:-}" = nopack ] || cp "$T/rules-pack.stub" "$r/bin/rules-pack.sh"
  ( cd "$r" || exit 1
    env BUILD="$T/$c/build" PROJECT=cromford KEY=BH-1 BASE=bbb GATE_RC="$2" \
        GATE_ARGV="$T/$c/gate-argv" PACK_CTL="$T/$c/ctl" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             . "$0"
             HARNESS_IMPACT_GATE_RUN harness-suite.txt lenses' "$T/hig.sh" ) > "$T/$c/out.txt" 2>&1
}
B1="$T/h1a/build"
pack h1a 1 1 "$FINDING"; printf 'tests/a-test.sh\n' > "$T/h1a/ctl/suites.1"
hrun h1a 0
grep -q '^RULES_PACK: red (rc 1, ' "$B1/harness-suite.txt" 2>/dev/null && ok || bad "H1a: $(cat "$B1/harness-suite.txt" 2>/dev/null)"
grep -qF "$FINDING" "$B1/harness-suite.txt" && ok || bad "H1a: the finding is not in the suite record"
[ "$(tail -1 "$B1/harness-suite.txt")" = 'HARNESS_EXIT: 1' ] && ok || bad "H1a: a red pack on a gate rc 0 must be HARNESS_EXIT 1: $(tail -1 "$B1/harness-suite.txt")"
case " $(cat "$T/h1a/gate-argv" 2>/dev/null) " in *" --skip-suites $B1/rules-pack-lenses/suites.txt "*) ok ;;
  *) bad "H1a: gate argv '$(cat "$T/h1a/gate-argv" 2>/dev/null)' lacks --skip-suites" ;; esac
grep -q 'HARNESS-VERIFY lenses rules pack rc=1' "$B1/pipeline.log" 2>/dev/null && ok || bad "H1a: no rules pack line in pipeline.log"
case " $(head -1 "$T/h1a/ctl/argv" 2>/dev/null) " in *" --out $B1/rules-pack-lenses "*) ok ;; *) bad "H1a: pack argv $(cat "$T/h1a/ctl/argv")" ;; esac

B1="$T/h1b/build"
pack h1b 1 125; printf 'tests/a-test.sh\n' > "$T/h1b/ctl/suites.1"
hrun h1b 0
grep -q '^RULES_PACK: could-not-run (rc 125, ' "$B1/harness-suite.txt" 2>/dev/null && ok || bad "H1b: $(cat "$B1/harness-suite.txt" 2>/dev/null)"
[ "$(tail -1 "$B1/harness-suite.txt")" = 'HARNESS_EXIT: 0' ] && ok || bad "H1b: could-not-run changed the gate rc"
grep -q -- '--skip-suites' "$T/h1b/gate-argv" && bad "H1b: a pack that could not run removed suites from the gate" || ok

B1="$T/h1c/build"
hrun h1c 0 nopack
printf 'HARNESS_SUITE: impact gate — bin/test-impact-gate.sh --base bbb\nstub gate output\nHARNESS_EXIT: 0\n' > "$T/h1c/golden"
cmp -s "$T/h1c/golden" "$B1/harness-suite.txt" && ok || bad "H1c: no pack must be byte-identical: $(cat "$B1/harness-suite.txt")"
[ "$(cat "$T/h1c/gate-argv")" = "--base bbb --project cromford --table $B1/impact-gate-lenses.md" ] && ok \
  || bad "H1c: gate argv changed: $(cat "$T/h1c/gate-argv")"
grep -q 'rules pack' "$B1/pipeline.log" && bad "H1c: no pack, but pipeline.log names one" || ok

B1="$T/h1d/build"
pack h1d 1 0
hrun h1d 1
grep -q '^RULES_PACK: clean (rc 0, ' "$B1/harness-suite.txt" && [ "$(tail -1 "$B1/harness-suite.txt")" = 'HARNESS_EXIT: 1' ] && ok \
  || bad "H1d: a red gate with a clean pack: $(tail -2 "$B1/harness-suite.txt")"

# ── H2: bin/test-impact-gate.sh --skip-suites ───────────────────────────────
R="$T/h2repo"
mkdir -p "$R/bin/lib" "$R/tests"
for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f"
done
chmod +x "$R/bin/"*.sh
printf '#!/bin/bash\nwidget_close_all() { echo closed; }\n' > "$R/bin/lib/widget.sh"
cat > "$R/tests/reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh"
SH
cat > "$R/tests/wide-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
git -C "$DIR" ls-files >/dev/null
SH
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
HB=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam touch
( cd "$R" && bin/test-impact-gate.sh --base "$HB" --runner plan --list "$T/h2.nolist" ) > "$T/h2.no" 2>&1
grep -qx 'tests/reads-test.sh' "$T/h2.nolist" && ok || bad "H2: fixture: reads-test is not selected: $(cat "$T/h2.no")"
printf 'tests/reads-test.sh\n' > "$T/h2.skip"
( cd "$R" && bin/test-impact-gate.sh --base "$HB" --runner plan --skip-suites "$T/h2.skip" --list "$T/h2.list" ) > "$T/h2.yes" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "H2: --skip-suites exited $RC: $(tail -3 "$T/h2.yes")"
grep -qE '^plan: tests/reads-test\.sh +run by the rules pack \(outside the cap\)$' "$T/h2.yes" && ok \
  || bad "H2: no 'run by the rules pack' plan line: $(grep '^plan' "$T/h2.yes")"
grep -qx 'tests/reads-test.sh' "$T/h2.list" && bad "H2: a skipped suite is still in --list" || ok
grep -qx 'tests/wide-test.sh' "$T/h2.list" && ok || bad "H2: an unskipped suite was dropped"
grep -q 'run by the rules pack' "$T/h2.no" && bad "H2: without the flag nothing is skipped" || ok
: > "$T/h2.empty"
( cd "$R" && bin/test-impact-gate.sh --base "$HB" --runner plan --skip-suites "$T/h2.empty" --list "$T/h2.elist" ) > "$T/h2.e" 2>&1
cmp -s "$T/h2.no" "$T/h2.e" && cmp -s "$T/h2.nolist" "$T/h2.elist" && ok || bad "H2: an empty skip file changed the output: $(diff "$T/h2.no" "$T/h2.e")"
( cd "$R" && bin/test-impact-gate.sh --help ) 2>&1 | grep -q -- '--skip-suites' && ok || bad "H2: --help does not document --skip-suites"

# ── E1: the evidence row ────────────────────────────────────────────────────
EB="$T/e1"; mkdir -p "$EB"
"$DIR/bin/evidence-summary.sh" "$EB" > "$T/e1.none" 2>&1
"$DIR/bin/evidence-summary.sh" --json "$EB" > "$T/e1.none.json" 2>&1
grep -q 'rules pack' "$T/e1.none" && bad "E1: no summary.json must mean no row" || ok
mkdir -p "$EB/rules-pack"
cat > "$EB/rules-pack/summary.json" <<'JSON'
{"state":"red","budget_s":60,"elapsed_s":17,"over_budget":false,"components":[{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"},{"id":"e"},{"id":"f"},{"id":"g"},{"id":"h"},{"id":"i"},{"id":"j"},{"id":"k"}],"could_not_run":[]}
JSON
"$DIR/bin/evidence-summary.sh" "$EB" > "$T/e1.red" 2>&1
grep -qxF '| rules pack (bin/rules-pack.sh) | red — 11 components, 17s of 60s budget |' "$T/e1.red" && ok \
  || bad "E1: row: $(grep 'rules pack' "$T/e1.red")"
diff <(grep -v '^| rules pack ' "$T/e1.red") "$T/e1.none" >/dev/null && ok || bad "E1: the row is not the only difference"
"$DIR/bin/evidence-summary.sh" --json "$EB" > "$T/e1.red.json" 2>&1
cmp -s "$T/e1.none.json" "$T/e1.red.json" && ok || bad "E1: --json changed"
jq '.over_budget = true | .could_not_run = ["date-bomb"]' "$EB/rules-pack/summary.json" > "$EB/s.tmp" && mv "$EB/s.tmp" "$EB/rules-pack/summary.json"
printf 'x: one\ny: two\n' > "$EB/rules-pack/preexisting.txt"
"$DIR/bin/evidence-summary.sh" "$EB" > "$T/e1.over" 2>&1
grep -qxF '| rules pack (bin/rules-pack.sh) | red — 11 components, 17s of 60s budget, over budget; could not run: date-bomb; pre-existing: 2 |' "$T/e1.over" && ok \
  || bad "E1: variant row: $(grep 'rules pack' "$T/e1.over")"
mkdir -p "$EB/prepr-late"; printf 'state=fixed\npack=clean\n' > "$EB/prepr-late/prepr.txt"
"$DIR/bin/evidence-summary.sh" "$EB" > "$T/e1.late" 2>&1
grep -q '^| rules pack (bin/rules-pack.sh) | clean — 11 components' "$T/e1.late" && ok || bad "E1: prepr-late pack= does not override: $(grep 'rules pack' "$T/e1.late")"

echo "rb-prepr-rules-pack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
