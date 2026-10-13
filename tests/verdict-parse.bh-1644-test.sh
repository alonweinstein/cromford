#!/bin/bash
# tests/verdict-parse.bh-1644-test.sh — verdict-parse follow-ups from the #1639
# review (BH-1644):
#   1. no window resolve on SOURCE; verdict_prime resolves once and exports it
#      (subshells and `bash -c` children reuse it); unprimed callers still
#      resolve per call.
#   2. a lane tick that sources the lib and parses nothing resolves 0 times.
#   3. an unresolvable window raises ONE ALERTS line per box per UTC day.
#   4. harness-sync copies catalog/ before bin/.
#   5. the prompt-replay eval gate diffs against the PR's merge base.
#   6. ratchet: every loop-parsing lane primes; no source-time resolve.
# Run from anywhere: tests/verdict-parse.bh-1644-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/verdict-parse.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'Some review.\n\nVERDICT: APPROVE\n' > "$T/approve.md"
printf 'Some review.\n\nVERDICT: BLOCK\n' > "$T/block.md"

# ---- 1. prime semantics -----------------------------------------------------
CNT="$T/r1.txt"; : > "$CNT"
(
  unset VERDICT_WINDOW_LINES _VP_WINDOW
  lib_env_apply() { printf 'resolve\n' >> "$CNT"; export VERDICT_WINDOW_LINES=3; }
  export -f lib_env_apply; export CNT
  . "$LIB"
  echo "after-source $(grep -c resolve "$CNT")" >> "$T/r1.mark"
  unset VERDICT_WINDOW_LINES
  verdict_prime || echo WRONG-PRIME-RC >> "$T/r1.mark"
  unset VERDICT_WINDOW_LINES
  A=$(verdict_parse "$T/approve.md"); B=$(verdict_parse "$T/block.md")
  C=$(bash -c '. "$1"; verdict_parse "$2"' _ "$LIB" "$T/approve.md")
  [ "$A/$B/$C" = APPROVE/BLOCK/APPROVE ] || echo "WRONG $A/$B/$C" >> "$T/r1.mark"
  echo "after-prime $(grep -c resolve "$CNT")" >> "$T/r1.mark"
  verdict_prime
  echo "after-reprime $(grep -c resolve "$CNT")" >> "$T/r1.mark"
)
grep -q '^after-source 0$' "$T/r1.mark" && ok || bad "1a sourcing the lib must resolve 0 times ($(grep after-source "$T/r1.mark"))"
grep -q '^after-prime 1$' "$T/r1.mark" && ok || bad "1b prime + 3 parses (\$(...), bash -c) must resolve exactly once ($(grep after-prime "$T/r1.mark"))"
grep -q '^after-reprime 1$' "$T/r1.mark" && ok || bad "1c a second verdict_prime must not resolve again ($(grep after-reprime "$T/r1.mark"))"
grep -q WRONG "$T/r1.mark" && bad "1b primed parses answered wrong: $(grep WRONG "$T/r1.mark")" || ok

CNT="$T/r1d.txt"; : > "$CNT"
(
  unset VERDICT_WINDOW_LINES _VP_WINDOW
  lib_env_apply() { printf 'resolve\n' >> "$CNT"; export VERDICT_WINDOW_LINES=3; }
  . "$LIB"
  A=$(verdict_parse "$T/approve.md"); B=$(verdict_parse "$T/block.md")
  [ "$A/$B" = APPROVE/BLOCK ] || echo "WRONG $A/$B" >> "$CNT"
)
[ "$(grep -c '^resolve' "$CNT")" = 2 ] && ok || bad "1d unprimed shell, 2 parses must resolve 2 times (got $(grep -c '^resolve' "$CNT"))"
grep -q WRONG "$CNT" && bad "1d unprimed verdicts wrong" || ok

# ---- 2. a non-parsing lane tick (fly-pool shape: source, no parse) ----------
CNT="$T/r2.txt"; : > "$CNT"
( unset VERDICT_WINDOW_LINES _VP_WINDOW
  lib_env_apply() { printf 'resolve\n' >> "$CNT"; export VERDICT_WINDOW_LINES=3; }
  . "$LIB"; . "$LIB"; true )
[ "$(grep -c '^resolve' "$CNT")" = 0 ] && ok || bad "2a a non-parsing lane tick must resolve 0 times (got $(grep -c '^resolve' "$CNT"))"

# ---- 3. unresolvable window alerts once per box per UTC day -----------------
# A scratch lib copy with no catalog/ next to it: no env, no lib_env_apply,
# no registry default.
mk_box() { mkdir -p "$1/bin/lib" "$1/logs" "$1/flags"; cp "$LIB" "$1/bin/lib/"; : > "$1/logs/ALERTS.log"; }
BOX="$T/box"; mk_box "$BOX"
run_unres() {  # <box> [fake-date]
  ( unset VERDICT_WINDOW_LINES _VP_WINDOW H
    export HARNESS="$1"
    if [ -n "${2:-}" ]; then mkdir -p "$T/fd"; printf '#!/bin/sh\n[ "$1" = "-u" ] && [ "$2" = "+%%Y%%m%%d" ] && { echo %s; exit 0; }\nexec /bin/date "$@"\n' "$2" > "$T/fd/date"; chmod +x "$T/fd/date"; PATH="$T/fd:$PATH"; fi
    . "$1/bin/lib/verdict-parse.sh"
    for _ in 1 2 3 4 5; do [ "$(verdict_parse "$T/approve.md")" = unknown ] || echo NOT-UNKNOWN >> "$1/logs/marks"; done
    verdict_prime && echo PRIME-OK >> "$1/logs/marks"; verdict_prime
    true )
}
nalert() { grep -c 'VERDICT_WINDOW_LINES is unresolvable' "$1/logs/ALERTS.log"; }
run_unres "$BOX"
[ "$(nalert "$BOX")" = 1 ] && ok || bad "3a 5 parses + 2 primes unresolvable must alert exactly once (got $(nalert "$BOX"))"
grep -q 'NOT-UNKNOWN\|PRIME-OK' "$BOX/logs/marks" 2>/dev/null && bad "3a unresolvable window must stay fail-closed (unknown, prime rc 1)" || ok
run_unres "$BOX"
[ "$(nalert "$BOX")" = 1 ] && ok || bad "3b a second process the same day must not alert again (got $(nalert "$BOX"))"
run_unres "$BOX" 29991231
[ "$(nalert "$BOX")" = 2 ] && ok || bad "3c a new UTC day must alert once more (got $(nalert "$BOX"))"
BOX2="$T/box2"; mk_box "$BOX2"
( unset _VP_WINDOW H; export HARNESS="$BOX2" VERDICT_WINDOW_LINES=3; . "$LIB"; verdict_prime; verdict_parse "$T/approve.md" >/dev/null
  for bogus in 0 abc; do VERDICT_WINDOW_LINES=$bogus verdict_parse "$T/approve.md" >/dev/null; done; true )
( unset _VP_WINDOW H VERDICT_WINDOW_LINES; export HARNESS="$BOX2"; . "$LIB"; verdict_prime; verdict_parse "$T/approve.md" >/dev/null; true )
[ "$(nalert "$BOX2")" = 0 ] && ok || bad "3d a resolvable window (env, or registry default) must never alert (got $(nalert "$BOX2"))"

BOX3="$T/box3"; mk_box "$BOX3"
( unset VERDICT_WINDOW_LINES _VP_WINDOW H; export HARNESS="$BOX3"; . "$BOX3/bin/lib/verdict-parse.sh"
  verdict_parse "$T/approve.md" >/dev/null; verdict_is APPROVE "$T/approve.md"; true )
[ "$(nalert "$BOX3")" = 1 ] && ok || bad "3e an unprimed lane whose parses cannot resolve must alert once (got $(nalert "$BOX3"))"

# ---- 4. harness-sync: catalog/ before bin/ ----------------------------------
HS="$DIR/bin/harness-sync.sh"
CL=$(grep -n 'rsync -a "$CHECKOUT/catalog/"' "$HS" | head -1 | cut -d: -f1)
BL=$(grep -n 'rsync -a "$CHECKOUT/bin/"' "$HS" | head -1 | cut -d: -f1)
[ -n "$CL" ] && [ -n "$BL" ] && [ "$CL" -lt "$BL" ] && ok || bad "4a harness-sync must rsync catalog/ (line ${CL:-none}) before bin/ (line ${BL:-none})"

# ---- 5. prompt-replay gate diffs against the merge base ---------------------
WF="$DIR/.github/workflows/harness-ci.yml"
awk '/id: gate$/{g=1} g&&/run: \|$/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,""); print}' "$WF" \
  | sed -e 's/\${{ github.event.pull_request.base.sha }}/$T_BASE/' -e 's/\${{ github.event.pull_request.head.sha }}/$T_HEAD/' \
        -e 's/\${{ github.event.before }}/$T_BEFORE/' -e 's/\${{ github.sha }}/$T_HEAD/' > "$T/gate.sh"
if grep -q 'prompts/' "$T/gate.sh"; then
  ok
  R="$T/repo"; mkdir -p "$R"; (cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t \
    && mkdir prompts bin && echo a > prompts/p.md && echo x > bin/x && git add -A && git commit -qm base \
    && git checkout -qb feat && echo y > bin/x && git commit -qam feat && git checkout -qb feat2 && echo b > prompts/q.md && git add -A && git commit -qm f2 \
    && git checkout -q main && echo c > prompts/p.md && git commit -qam mainmoved)
  gate() {  # <head-branch>
    ( cd "$R"; export GITHUB_OUTPUT="$T/out" EVALS_FORCE=0 T_BASE="$(git rev-parse main)" T_HEAD="$(git rev-parse "$1")" T_BEFORE=""; : > "$GITHUB_OUTPUT"
      bash "$T/gate.sh" >/dev/null 2>&1; grep '^run=' "$GITHUB_OUTPUT" | tail -1 )
  }
  [ "$(gate feat)" = run=0 ] && ok || bad "5a stale-base PR with no prompts/ diff vs its merge base must skip (got $(gate feat))"
  [ "$(gate feat2)" = run=1 ] && ok || bad "5b a PR that edits prompts/ must replay (got $(gate feat2))"
else
  bad "5 could not extract the prompt-replay gate step"
fi
grep -q 'git merge-base' "$WF" && ok || bad "5c the replay gate must use git merge-base"

# ---- 6. ratchet --------------------------------------------------------------
for lane in merge-sweep review-rescue review-prs run-build; do
  grep -q 'verdict_prime' "$DIR/bin/$lane.sh" && ok || bad "6a bin/$lane.sh parses verdicts in a loop and must call verdict_prime"
done
for f in "$DIR"/bin/*.sh; do
  n=$(grep -cE 'verdict_(parse|is) ' "$f")
  [ "$n" -ge 3 ] && ! grep -q verdict_prime "$f" && bad "6b $(basename "$f") has $n verdict parse sites and never primes"
done; ok
awk '/^[a-z_]+\(\) *\{/{inf=1} inf&&/^}/{inf=0;next} !inf&&/_VP_WINDOW=\$\(/{print; bad=1} END{exit bad}' "$LIB" >/dev/null \
  && ok || bad "6c verdict-parse.sh must not resolve _VP_WINDOW at source time"

echo "verdict-parse.bh-1644: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
