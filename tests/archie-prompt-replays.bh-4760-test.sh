#!/bin/bash
# tests/archie-prompt-replays.bh-4760-test.sh — BH-4764 (slice 1 of #4760): the
# `prompt:` key of bin/archie-skill-replay.sh, the replay root
# catalog/prompts/replays/ for lane prompts, and the unreadable-metric section of
# catalog/prompts/archie-check.md.
#
# Every runner case DRIVES bin/archie-skill-replay.sh, with its default recorded
# replayer or with a stub model (ARCHIE_REPLAY_MODEL_CMD) that keeps a copy of
# the prompt it was given. Nothing here calls a vendor.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/archie-skill-replay.sh"
REPLAYS="$DIR/catalog/prompts/replays"
CHECK="$DIR/catalog/prompts/archie-check.md"
CASE1="$DIR/catalog/prompts/replays/archie-check/replays/01-unreadable-metric"
CASE2="$DIR/catalog/prompts/replays/archie-check/replays/02-events-need-nothing"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A stub model: keeps the prompt, then replays the case's own recording.
mkdir -p "$T/stubs" "$T/calls"
cat > "$T/stubs/record" <<EOF
#!/bin/bash
cp "\$1" "$T/calls/\$(basename "\$2").txt"
cat "\$2/recorded.txt"
EOF
chmod +x "$T/stubs/record"

run() { "$RUNNER" "$@" > "$T/out" 2>"$T/err"; echo $?; }

# skill_root <root> <prompt-line> [<cases>] [<body>]: a scratch replay root with
# one valid skill `probe` (verdicts go|stop) and <cases> valid cases (default 2).
skill_root() {
  local r="$1" n="${3:-2}" i
  mkdir -p "$r/probe/replays"
  printf -- '---\nname: probe\ndescription: probe skill for the prompt key\nverdicts: go | stop\n%s\n---\n%s\n' \
    "$2" "${4:-}" > "$r/probe/SKILL.md"
  for i in $(seq 1 "$n"); do
    mkdir -p "$r/probe/replays/0$i-case"
    echo "case $i input" > "$r/probe/replays/0$i-case/input.md"
    echo "VERDICT: go" > "$r/probe/replays/0$i-case/expected"
    printf 'fine\nVERDICT: go\n' > "$r/probe/replays/0$i-case/recorded.txt"
  done
}

# --- R1 the shipped replay root passes with the default recorded replayer ------
RC=$(run --root "$REPLAYS")
if [ "$RC" = 0 ] && grep -qx 'PASS archie-check/01-unreadable-metric speak' "$T/out" \
   && grep -qx 'PASS archie-check/02-events-need-nothing blank' "$T/out" \
   && tail -1 "$T/out" | grep -q ' 0 failed$' && ! grep -q '^FAIL' "$T/out"; then ok
else bad "R1 replay root: rc=$RC $(cat "$T/out" "$T/err")"; fi

# --- R2 the prompt head is the live soul, then archie-check.md -----------------
# bin/archie.sh composes: cat prompts/archie-soul.d/*.md; printf '\n'; cat
# catalog/prompts/archie-check.md. The replay head must be the same bytes.
{ cat "$DIR"/prompts/archie-soul.d/*.md; echo; cat "$CHECK"; echo; } > "$T/live-head"
cat "$DIR"/prompts/archie-soul.d/*.md > "$T/soul"
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" run --root "$REPLAYS" --skill archie-check)
[ "$RC" = 0 ] && ok || bad "R2 stubbed run rc=$RC: $(cat "$T/out" "$T/err")"
for C in "$CASE1" "$CASE2"; do
  F="$T/calls/$(basename "$C").txt"
  [ -f "$F" ] || { bad "R2 $(basename "$C"): the model got no prompt"; continue; }
  cmp -s -n "$(wc -c < "$T/soul")" "$F" "$T/soul" && ok || bad "R2 $(basename "$C"): prompt does not start with the soul"
  cmp -s -n "$(wc -c < "$T/live-head")" "$F" "$T/live-head" && ok \
    || bad "R2 $(basename "$C"): prompt head is not soul + newline + archie-check.md + newline"
  # the whole prompt, byte for byte: head, blank line, separator, input, close
  { cat "$T/live-head"; echo; echo '=== CASE ==='; cat "$C/input.md"; echo
    echo 'End with exactly one line: VERDICT: <one of speak | blank>'; } > "$T/want"
  cmp -s "$F" "$T/want" && ok || bad "R2 $(basename "$C"): prompt is not head + case + close"
done

# --- R3 refused prompt paths: structural FAIL, rc 1, no case runs --------------
# Each row: <prompt: value> | <the FAIL line it must print>. The second `..`
# row resolves to a real repo file, so only the `..` refusal stops it.
i=0
while IFS='|' read -r PL WANT; do
  i=$((i+1)); R="$T/r3-$i"
  skill_root "$R" "prompt: $PL"
  RC=$(run --root "$R")
  if [ "$RC" = 1 ] && grep -qxF "FAIL probe prompt $WANT" "$T/out" && ! grep -q '^PASS' "$T/out"; then ok
  else bad "R3 [$PL]: rc=$RC $(cat "$T/out" "$T/err")"; fi
done <<'ROWS'
../etc/x|../etc/x contains ..
catalog/../catalog/prompts/archie-check.md|catalog/../catalog/prompts/archie-check.md contains ..
/etc/passwd|/etc/passwd absolute path
catalog/prompts/nope.md|catalog/prompts/nope.md not a readable file under the repo
catalog/prompts/archie-check.md ../etc/x|../etc/x contains ..
ROWS

# --- R3d a repo directory with no *.md is refused --------------------------------
if compgen -G "$DIR/tests/lib/*.md" >/dev/null; then
  echo "note: R3d skipped, tests/lib now holds a *.md"
else
  skill_root "$T/r3d" 'prompt: tests/lib'
  RC=$(run --root "$T/r3d")
  if [ "$RC" = 1 ] && grep -q '^FAIL probe prompt tests/lib ' "$T/out" && ! grep -q '^PASS' "$T/out"; then ok
  else bad "R3d dir with no *.md: rc=$RC $(cat "$T/out" "$T/err")"; fi
fi

# --- R3e a symlink in the repo that points out of it is refused -------------------
# The runner resolves prompt: against its own repo, so a scratch copy of it gets
# a scratch repo with one symlink out.
mkdir -p "$T/sym" "$T/outside"
scratch_install_closure bin/archie-skill-replay.sh "$T/sym" >/dev/null || bad "R3e cannot install the runner"
echo "outside text" > "$T/outside/x.md"
ln -s "$T/outside" "$T/sym/out"
skill_root "$T/r3e" 'prompt: out/x.md'
"$T/sym/bin/archie-skill-replay.sh" --root "$T/r3e" > "$T/out" 2>"$T/err"; RC=$?
if [ "$RC" = 1 ] && grep -qx 'FAIL probe prompt out/x.md not a readable file under the repo' "$T/out" && ! grep -q '^PASS' "$T/out"; then ok
else bad "R3e symlink out of the repo: rc=$RC $(cat "$T/out" "$T/err")"; fi

# --- R4 default root and archie-learn are unchanged ------------------------------
RC=$(run)
L=$(tail -1 "$T/out")
[ "$RC" = 0 ] && [ "$L" = 'archie-skill-replay: 5 skills, 14 passed, 0 failed' ] && ok \
  || bad "R4 default root: rc=$RC last=[$L]"
for S in archie-skill-replays.bh-4064-test.sh archie-learning.bh-4066-test.sh; do
  bash "$DIR/tests/$S" > "$T/sub.out" 2>&1 && ok || bad "R4 $S is red: $(tail -5 "$T/sub.out")"
done

# --- R5 with prompt: set, the SKILL.md body is not used ------------------------------
rm -f "$T/calls/"*
skill_root "$T/r5" 'prompt: catalog/prompts/archie-check.md' 2 'BODY-MARKER'
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" run --root "$T/r5")
{ cat "$CHECK"; echo; echo; echo '=== CASE ==='; echo 'case 1 input'; echo
  echo 'End with exactly one line: VERDICT: <one of go | stop>'; } > "$T/want"
F="$T/calls/01-case.txt"
if [ "$RC" = 0 ] && [ -f "$F" ] && ! grep -q 'BODY-MARKER' "$F" && cmp -s "$F" "$T/want"; then ok
else bad "R5 prompt file replaces the body: rc=$RC $(cat "$T/out" "$T/err")"; fi
# the control: without prompt:, the same skill sends its body
rm -f "$T/calls/"*
skill_root "$T/r5b" '' 2 'BODY-MARKER'
RC=$(ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" run --root "$T/r5b")
[ "$RC" = 0 ] && grep -q 'BODY-MARKER' "$T/calls/01-case.txt" 2>/dev/null && ok || bad "R5 control: body not sent without prompt:"

# --- R6 a valid prompt: does not lift the 2-case minimum ------------------------------
skill_root "$T/r6" 'prompt: catalog/prompts/archie-check.md' 1
RC=$(run --root "$T/r6")
[ "$RC" = 1 ] && grep -q '^FAIL probe needs at least 2 replay cases, has 1$' "$T/out" && ok \
  || bad "R6 one case: rc=$RC $(cat "$T/out")"

# --- C1 archie-check.md: the unreadable-metric section --------------------------------
SEC=$(sed -n '/^## When the metric is unreadable$/,/^## /p' "$CHECK" | sed '$d')
[ "$(grep -c '^## When the metric is unreadable$' "$CHECK")" = 1 ] && ok || bad "C1 no single unreadable-metric heading"
for s in metric_unreadable ticket-file watch-cadence metric_query; do
  grep -qF "$s" <<<"$SEC" && ok || bad "C1 the section does not name [$s]"
done
grep -qF 'except when check.metric_unreadable is true' "$CHECK" && ok || bad "C1 no except clause"

# --- C2 nothing else in archie-check.md changed ----------------------------------------
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  RM=$(git -C "$DIR" diff origin/main -- catalog/prompts/archie-check.md | grep -E '^-[^-]|^-$' || true)
  N=$(grep -c . <<<"$RM")
  if [ -z "$RM" ] || { [ "$N" = 1 ] && grep -qF 'sends no message.' <<<"$RM"; }; then ok
  else bad "C2 archie-check.md lost lines: $RM"; fi
else
  echo "note: C2 skipped, origin/main does not resolve"
fi

# --- C3 the replay root and its README ---------------------------------------------------
if [ -f "$DIR/catalog/prompts/replays/README.md" ] && grep -qF 'prompt:' "$DIR/catalog/prompts/replays/README.md" \
   && grep -qF -- '--root catalog/prompts/replays' "$DIR/catalog/prompts/replays/README.md"; then ok
else bad "C3 README missing or does not document prompt: and the run command"; fi
[ ! -e "$DIR/orchestrator/skills/archie-check" ] && ok || bad "C3 archie-check replay is under orchestrator/skills"
grep -qx 'prompt: prompts/archie-soul.d catalog/prompts/archie-check.md' "$DIR/catalog/prompts/replays/archie-check/SKILL.md" \
  && ok || bad "C3 SKILL.md prompt: line"

# --- C4 the two cases --------------------------------------------------------------------
[ "$(head -1 "$CASE1/recorded.txt")" = 'CLASS: ticket-file' ] && ok || bad "C4 case 01 does not open with CLASS: ticket-file"
grep -q '"metric_unreadable": *true' "$CASE1/input.md" && ok || bad "C4 case 01 input has no metric_unreadable true"
grep -qx '## Events this check is answering' "$CASE2/input.md" && ok || bad "C4 case 02 has no events section"

# --- V1 no em or en dash ----------------------------------------------------------------
if [ ! -f "$CASE1/recorded.txt" ] || [ ! -f "$CASE2/recorded.txt" ]; then bad "V1 a recorded.txt is missing"
elif grep -P '[\x{2013}\x{2014}]' "$CHECK" "$CASE1/recorded.txt" "$CASE2/recorded.txt"; then
  bad "V1 an em or en dash in archie-check.md or a recorded.txt"
else ok; fi

# --- V2 no hardcoded model string ----------------------------------------------------------
if [ ! -d "$REPLAYS" ]; then bad "V2 no replay root"
elif grep -rE 'claude-[a-z0-9]' "$REPLAYS" "$RUNNER"; then bad "V2 a claude-* model string"; else ok; fi

echo "archie-prompt-replays: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
