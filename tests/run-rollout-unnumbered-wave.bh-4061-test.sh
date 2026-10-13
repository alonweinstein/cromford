#!/bin/bash
# tests/run-rollout-unnumbered-wave.bh-4061-test.sh — BH-4061 parser half.
#
# skills/harness/SKILL.md teaches `### Wave: <title>`, and bin/run-rollout.sh
# only stripped `Wave <digits>:`. An unnumbered heading kept the literal
# `Wave: ` in its title, so every `after:` line refused `unknown dependency`
# (#3966, #3979 on 2026-10-03). This drives a copy of the real script out of a
# scratch checkout (the tests/run-rollout.bh-984-test.sh layout: a scratch
# $HARNESS with fleet.conf and a gh stub, a filer stub beside the copied
# library) and asserts on children.json, parse.err and rollout-run.txt.
#
#   U1  the #3979 shape: `### Wave: a` / `after: a` / `after: a, b`
#   U2  `### Wave 1: a` still parses
#   U3  `### wave 3 : a`, `### WAVE: b` + `after: A`; `### Wavefront rework` keeps its title
#   U4  a comma title with any `after:` refuses `comma in wave title`; U4-neg files without one
#   U5  an unknown name is quoted with the known titles
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

ROLLOUT="$T/co/bin/run-rollout.sh"
mkdir -p "$T/h/bin" "$T/co/bin/lib" "$T/bodies"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/run-rollout.sh" "$DIR/bin/fleet-conf.sh" "$T/co/bin/"
cp "$DIR/bin/lib/file-children.sh" "$T/co/bin/lib/"
chmod +x "$ROLLOUT"
cat > "$T/h/fleet.conf" <<'CONF'
scoutish example-org/scoutish https://scoutish.example - 9 box-1 10.0.0.9
CONF
# The filer, stubbed beside the library: one board key per wave in the spec,
# the way the real filer records a child only after GitHub numbered it.
cat > "$T/co/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_issues() {
  local n i=1
  n=$(jq 'length' "$FC_SPEC")
  while [ "$i" -le "$n" ]; do printf 'FAKE-%s\n' "$i" >> "$FC_BUILD/children.txt"; i=$((i + 1)); done
  return 0
}
SH
cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
if [ "$1" = issue ] && [ "$2" = view ]; then cat "$GH_BODY"; exit 0; fi
echo "gh stub: $*" >&2; exit 1
SH
chmod +x "$T/h/bin/gh"

# drive <body-file> — a fresh build dir $T/b, dry run, scoutish (issues lane).
drive() {
  scratch_rm "$T/b" 2>/dev/null; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY="$1" DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >"$T/b/stdout.txt" 2>&1 )
}
titles() { jq -r '[.[].title]|join(",")' "$T/b/children.json" 2>/dev/null; }
afters() { jq -c '[.[].after]' "$T/b/children.json" 2>/dev/null; }
last_result() { grep '^RESULT ' "$T/b/rollout-run.txt" 2>/dev/null | tail -1; }

# ── U1: the #3979 body shape ──────────────────────────────────────────────
cat > "$T/bodies/u1.md" <<'MD'
Master.

## Rollout

### Wave: a
Tracer.

### Wave: b
after: a
Second.

### Wave: c
after: a, b
Third.
MD
drive "$T/bodies/u1.md"
[ "$(titles)" = "a,b,c" ] && ok || bad "U1: titles want a,b,c got '$(titles)' ($(cat "$T/b/parse.err" 2>/dev/null))"
[ "$(afters)" = "[[],[1],[1,2]]" ] && ok || bad "U1: after want [[],[1],[1,2]] got '$(afters)'"
[ "$(last_result)" = 'RESULT "ROLLOUT_FILED 3"' ] && ok || bad "U1: result '$(last_result)'"
grep -q 'after:' <<<"$(jq -r '.[1].body' "$T/b/children.json" 2>/dev/null)" \
  && bad "U1: the after: line stayed in wave 2's body" || ok

# ── U2: numbered headings still parse ─────────────────────────────────────
printf '## Rollout\n### Wave 1: a\nOne.\n### Wave 2: b\nafter: a\nTwo.\n' > "$T/bodies/u2.md"
drive "$T/bodies/u2.md"
[ "$(titles)" = "a,b" ] && ok || bad "U2: titles '$(titles)'"
[ "$(afters)" = "[[],[1]]" ] && ok || bad "U2: after '$(afters)'"

# ── U3: case, a space before the colon, and a title that only starts with Wave ─
printf '## Rollout\n### wave 3 : a\nOne.\n### WAVE: b\nafter: A\nTwo.\n### Wavefront rework\nThree.\n### Waves: x\nFour.\n' > "$T/bodies/u3.md"
drive "$T/bodies/u3.md"
[ "$(titles)" = "a,b,Wavefront rework,Waves: x" ] && ok || bad "U3: titles '$(titles)' ($(cat "$T/b/parse.err" 2>/dev/null))"
[ "$(afters)" = "[[],[1],[],[]]" ] && ok || bad "U3: after '$(afters)'"
printf '## Rollout\n<h3>Wave: a</h3>\nOne.\n### Wave 2:b\nafter: a\nTwo.\n' > "$T/bodies/u3b.md"
drive "$T/bodies/u3b.md"
[ "$(titles)" = "a,b" ] && ok || bad "U3b: <h3>Wave: a</h3> and Wave 2:b want a,b got '$(titles)'"
printf '## Rollout\n### Wave:\nOne.\n### Wave: b\nTwo.\n' > "$T/bodies/u3c.md"
drive "$T/bodies/u3c.md"
[ "$(head -1 "$T/b/parse.err" 2>/dev/null)" = "empty title" ] && ok || bad "U3c: bare '### Wave:' want empty title, got '$(cat "$T/b/parse.err" 2>/dev/null)'"

# ── U4: a comma in a title, with and without any after: line ─────────────
printf '## Rollout\n### Wave: a, b\nOne.\n### Wave: c\nafter: a\nTwo.\n' > "$T/bodies/u4.md"
drive "$T/bodies/u4.md"; RC=$?
[ "$RC" -ne 0 ] && ok || bad "U4: must exit non-zero"
[ "$(head -1 "$T/b/parse.err" 2>/dev/null)" = "comma in wave title" ] && ok \
  || bad "U4: parse.err '$(cat "$T/b/parse.err" 2>/dev/null)'"
[ ! -e "$T/b/children.json" ] && ok || bad "U4: children.json written"
[ "$(last_result)" = 'RESULT "ROLLOUT_FAILED comma in wave title"' ] && ok || bad "U4: result '$(last_result)'"
printf '## Rollout\n### Wave: a, b\nOne.\n### Wave: c\nTwo.\n' > "$T/bodies/u4n.md"
drive "$T/bodies/u4n.md"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "U4-neg: rc=$RC ($(cat "$T/b/parse.err" 2>/dev/null))"
[ "$(titles)" = "a, b,c" ] && ok || bad "U4-neg: titles '$(titles)'"
[ "$(last_result)" = 'RESULT "ROLLOUT_FILED 2"' ] && ok || bad "U4-neg: result '$(last_result)'"

# ── U5: an unknown name is quoted, with the titles the parser knows ───────
printf '## Rollout\n### Wave: a\nOne.\n### Wave: b\nafter: x\nTwo.\n' > "$T/bodies/u5.md"
drive "$T/bodies/u5.md"; RC=$?
[ "$RC" -ne 0 ] && ok || bad "U5: must exit non-zero"
[ "$(head -1 "$T/b/parse.err" 2>/dev/null)" = 'unknown dependency "x" (known: "a", "b")' ] && ok \
  || bad "U5: parse.err '$(cat "$T/b/parse.err" 2>/dev/null)'"
[ "$(last_result)" = 'RESULT "ROLLOUT_FAILED unknown dependency "x" (known: "a", "b")"' ] && ok \
  || bad "U5: result '$(last_result)'"
# The name is quoted as the author wrote it, and the list keeps their case.
printf '## Rollout\n### Wave: Alpha\nOne.\n### Wave: Beta\nafter: Gamma Ray\nTwo.\n' > "$T/bodies/u5b.md"
drive "$T/bodies/u5b.md"
[ "$(head -1 "$T/b/parse.err" 2>/dev/null)" = 'unknown dependency "Gamma Ray" (known: "Alpha", "Beta")' ] && ok \
  || bad "U5b: parse.err '$(cat "$T/b/parse.err" 2>/dev/null)'"

echo "run-rollout-unnumbered-wave: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
