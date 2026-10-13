#!/bin/bash
# tests/test-payload-pin-lint.bh-5792-test.sh — bin/test-payload-pin-lint.sh
# driven over hermetic `git init` repos, plus the BH-5792 prompt rule pins.
#
#   THE PROPERTY UNDER TEST: an added test-file line that compares a whole JSON
#   payload (`jq -S .`, a deep-equal of a bare response against an object
#   literal, an assertion against a 3+ key JSON literal) is reported with its
#   real path and line. Warn mode exits 0; error mode (conf or --strict) exits
#   1. It is silent for a contract test, a field-level assert, a non-test file
#   and, in diff mode, a line that was already there.
#
# Every whole-payload pattern below is built from parts, so the lint (in diff
# mode over the PR that adds this suite, and in S1 over this file) sees none.
# Run from anywhere: tests/test-payload-pin-lint.bh-5792-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-payload-pin-lint.sh"
CONF="$DIR/catalog/payload-pin-lint.conf"
DCONF="$DIR/catalog/determinism-lint.conf"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The patterns, from parts.
J=jq
DE="assert.deep""Equal("
TE=".to""Equal("
Q='"'
lit() { # lit k1 k2 ... -> '{"k1":null,"k2":null,...}'
  local s="" k
  for k in "$@"; do s="$s${s:+,}$Q$k$Q:null"; done
  printf "'{%s}'" "$s"
}

# run [args...] -> stdout in $OUT, stderr in $ERR, rc in $RC. HARNESS points at
# scratch so no box-local flags/ conf can leak in. GITHUB_ACTIONS is set ONLY
# by a case that asks for it (RUN_GHA=true, A9): a CI runner exports
# GITHUB_ACTIONS=true, and the lint's `::warning` lines would otherwise join
# every case's stdout (merge batches #5847-#5849 failed 10 cases that way).
run() {
  OUT=$(HARNESS="$T/h" PAYLOAD_PIN_LINT_CONF="${RUN_CONF-$CONF}" DETERMINISM_LINT_CONF="$DCONF" \
        GITHUB_ACTIONS="${RUN_GHA:-}" \
        bash "${RUN_LINT:-$LINT}" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
G() { git -C "$T/r" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
# repo [base-line] — fresh repo, tests/a-test.sh with one line, branch `base`.
repo() {
  rm -rf "$T/r"; git init -q "$T/r" || exit 1
  mkdir -p "$T/r/tests" "$T/r/worker/jobs/test" "$T/r/console-ui/src/test" "$T/r/bin"
  printf '%s\n' "${1:-echo base}" > "$T/r/tests/a-test.sh"
  G add -A && G commit -qm base && G branch base
}
commit() { G add -A && G commit -qm added; }
fline() { printf '%s\n' "$2" >> "$T/r/$1"; }
findings() { grep -c 'payload-pin' <<<"$1"; }

# ── A1: the ticket's acceptance — a whole-payload deepEqual warns, rc 0 ─────
repo; fline worker/jobs/test/x.test.js "const body = await res.json();"
fline worker/jobs/test/x.test.js "$DE""body, { ready: 2, held: 1 });"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "A1 rc $RC (want 0 in warn mode): $OUT $ERR"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^worker/jobs/test/x\.test\.js:2: payload-pin: deep-equal-whole: ' <<<"$OUT" \
  && ok || bad "A1 want one deep-equal-whole finding at x.test.js:2: $OUT"
grep -q '1 findings (mode warn' <<<"$ERR" && ok || bad "A1 summary lacks '1 findings (mode warn': $ERR"

# ── A2: a contract test is silent ───────────────────────────────────────────
repo; fline worker/jobs/test/x.contract.test.js "$DE""body, { ready: 2, held: 1 });"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A2a *.contract.test.* not silent (rc $RC): $OUT"
repo; fline worker/jobs/test/x.test.js "// contract-test: the public payload shape"
fline worker/jobs/test/x.test.js "$DE""body, { ready: 2, held: 1 });"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A2b // contract-test header not silent (rc $RC): $OUT"
repo; fline tests/y-test.sh '#!/bin/bash'; fline tests/y-test.sh '# contract-test'
fline tests/y-test.sh "diff <($J -S . a.json) <($J -S . b.json)"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A2c # contract-test header (shell) not silent (rc $RC): $OUT"
# A2d: a header past header_lines does not exempt
repo; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do fline tests/y-test.sh "echo $i"; done
fline tests/y-test.sh '# contract-test'; fline tests/y-test.sh "diff <($J -S . a.json) <($J -S . b.json)"; commit
run --base base "$T/r"
[ "$(findings "$OUT")" = 1 ] && ok || bad "A2d a contract-test line at line 16 exempted the file: $OUT"

# ── A3: field-level asserts are silent ──────────────────────────────────────
repo
fline worker/jobs/test/x.test.js "$DE""body.accounts, { a: 1 });"
fline worker/jobs/test/x.test.js "assert.equal(body.ready, 2);"
fline tests/a-test.sh "v=\$($J -S '.payload.ready' out.json)"
fline tests/a-test.sh "eq \"x\" \"\$(tix | $J -c '[.ready]')\" '[5]'"
commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A3 field-level asserts not silent (rc $RC): $OUT"

# ── A4: jq -S over the identity filter ──────────────────────────────────────
repo; fline tests/z-test.sh "diff <($J -S . a.json) <($J -S . b.json)"
fline tests/z-test.sh "[ \"\$($J -Sc . out.json)\" = \"\$(cat want.json)\" ]"; commit
run --base base "$T/r"
[ "$(findings "$OUT")" = 2 ] && grep -qE '^tests/z-test\.sh:1: payload-pin: jq-sort-whole: ' <<<"$OUT" \
  && grep -qE '^tests/z-test\.sh:2: payload-pin: jq-sort-whole: ' <<<"$OUT" \
  && ok || bad "A4 want jq-sort-whole at z-test.sh:1 and :2 (-Sc): $OUT"

# ── A5: the #4126 shape — a 3+ key JSON literal on an assertion ─────────────
repo; fline tests/t-test.sh "eq \"T6\" \"\$(tix ghp)\" $(lit ready blocked held)"
fline tests/t-test.sh "eq \"T7\" \"\$(tix ghp)\" $(lit ready blocked)"
fline tests/t-test.sh "echo $(lit a b c) > fixture.json"; commit
run --base base "$T/r"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^tests/t-test\.sh:1: payload-pin: json-literal-whole: ' <<<"$OUT" \
  && ok || bad "A5 want exactly one json-literal-whole at t-test.sh:1: $OUT"
# A5c: the [ = ] form flags the compared literal, not a literal set after a test
repo; fline tests/t-test.sh "[ \"\$(j .x)\" = $(lit a b c) ]"
fline tests/t-test.sh "if [ \"\$st\" = running ]; then out=$(lit job box id); fi"; commit
run --base base "$T/r"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^tests/t-test\.sh:1: payload-pin: json-literal-whole: ' <<<"$OUT" \
  && ok || bad "A5c want exactly one json-literal-whole at t-test.sh:1 (the stub line is not an assert): $OUT"
# A5b: the real BH-3988 line from history, if reachable
SRC=$(git -C "$DIR" show '2531062b:tests/utilization-tickets.bh-3988-test.sh' 2>/dev/null)
REAL=$(grep -m1 -E "^[[:space:]]*eq .*'\\{\"ready\":null," <<<"$SRC")
if [ -n "$REAL" ]; then
  repo; fline tests/u-test.sh "$REAL"; commit
  run --base base "$T/r"
  [ "$(findings "$OUT")" = 1 ] && grep -q 'json-literal-whole' <<<"$OUT" && ok || bad "A5b real #4126 line not flagged: $OUT"
else
  echo "SKIP A5b: 2531062b not reachable or line moved"
fi

# ── A6: diff mode judges added lines only; --all judges every line ──────────
repo "$DE""body, { a: 1 });"
mv "$T/r/tests/a-test.sh" "$T/r/tests/w.test.js"; G add -A; G commit -qm mv; G branch -f base
fline tests/w.test.js "assert.equal(body.a, 1);"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A6 diff mode reported a pre-existing line (rc $RC): $OUT"
run --all "$T/r"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^tests/w\.test\.js:1: payload-pin: deep-equal-whole: ' <<<"$OUT" \
  && ok || bad "A6 --all lacks the pre-existing line: $OUT"

# ── A7: a non-test file is silent ───────────────────────────────────────────
repo; fline bin/tool.sh "diff <($J -S . a.json) <($J -S . b.json)"; fline bin/tool.js "$DE""body, { a: 1 });"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "A7 non-test file not silent (rc $RC): $OUT"

# ── A8: error mode ──────────────────────────────────────────────────────────
repo; fline worker/jobs/test/x.test.js "$DE""body, { ready: 2, held: 1 });"; commit
run --strict --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "A8a --strict rc $RC (want 1): $OUT $ERR"
grep -q '(mode error' <<<"$ERR" && ok || bad "A8a summary does not say mode error: $ERR"
sed 's/^mode .*/mode error/' "$CONF" > "$T/err.conf"
[ "$(grep -c '^mode error$' "$T/err.conf")" = 1 ] && ok || bad "A8b sed changed no mode line"
RUN_CONF="$T/err.conf" run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "A8b conf mode error rc $RC (want 1): $OUT"
sed 's/^mode .*/mode bogus/' "$CONF" > "$T/bogus.conf"
RUN_CONF="$T/bogus.conf" run --base base "$T/r"
[ "$RC" -eq 0 ] && [ "$(findings "$OUT")" = 1 ] && ok || bad "A8c mode bogus rc $RC (want 0, one finding): $OUT"
grep -q "mode 'bogus'" <<<"$ERR" && ok || bad "A8c stderr does not name the bad mode: $ERR"

# ── A9: GitHub annotations ──────────────────────────────────────────────────
RUN_GHA=true run --base base "$T/r"
grep -q '^::warning file=worker/jobs/test/x\.test\.js,line=1::payload-pin deep-equal-whole' <<<"$OUT" \
  && ok || bad "A9a no ::warning annotation: $OUT"
RUN_GHA=true run --strict --base base "$T/r"
grep -q '^::error file=worker/jobs/test/x\.test\.js,line=1::payload-pin deep-equal-whole' <<<"$OUT" \
  && ok || bad "A9b no ::error annotation under --strict: $OUT"
run --base base "$T/r"
grep -q '^::' <<<"$OUT" && bad "A9c annotation printed without GITHUB_ACTIONS: $OUT" || ok

# ── A10: fail closed on setup ───────────────────────────────────────────────
mkdir -p "$T/copy/bin"; cp "$LINT" "$T/copy/bin/" 2>/dev/null
RUN_LINT="$T/copy/bin/test-payload-pin-lint.sh" RUN_CONF="" run --base base "$T/r"
[ "$RC" -eq 2 ] && grep -q 'no conf found' <<<"$ERR" && ok || bad "A10a no conf rc $RC (want 2): $ERR"
grep -v '^rule ' "$CONF" > "$T/norule.conf"
RUN_CONF="$T/norule.conf" run --base base "$T/r"
[ "$RC" -eq 2 ] && ok || bad "A10b conf with no rule rc $RC (want 2): $ERR"
run --base nosuchref "$T/r"
[ "$RC" -eq 2 ] && grep -q 'cannot resolve base nosuchref' <<<"$ERR" && ok || bad "A10c bad base rc $RC (want 2): $ERR"
mkdir -p "$T/notgit/tests"
run --base base "$T/notgit"
[ "$RC" -eq 2 ] && ok || bad "A10d non-git root rc $RC (want 2): $ERR"
run --bogus "$T/r"
[ "$RC" -eq 2 ] && ok || bad "A10e unknown flag rc $RC (want 2): $ERR"

# ── A11: expect(<name>) toEqual an object literal ─────────────────────────────
repo; fline console-ui/src/test/v.test.js "expect(res)$TE{ a: 1 });"
fline console-ui/src/test/v.test.js "expect(res.a)$TE{ b: 1 });"; commit
run --base base "$T/r"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^console-ui/src/test/v\.test\.js:1: payload-pin: deep-equal-whole: ' <<<"$OUT" \
  && ok || bad "A11 want one finding at v.test.js:1: $OUT"

# ── P1: the builder prompt carries the rule ─────────────────────────────────
BD="$DIR/prompts/build-discipline.md"
[ "$(grep -c '^## Added 2026-10-09 (BH-5792)' "$BD")" = 1 ] && ok || bad "P1 build-discipline.md lacks exactly one BH-5792 heading"
SEC=$(awk '/^## Added 2026-10-09 \(BH-5792\)/{f=1; next} f && /^## /{exit} f' "$BD")
RULE=$(grep -E '^- \*\*D[0-9]+ Assert the fields the feature owns' <<<"$SEC")
[ -n "$RULE" ] && ok || bad "P1 no '- **D<n> Assert the fields the feature owns' rule under the BH-5792 heading"
for w in 'contract-test' '*.contract.test.*' 'bin/test-payload-pin-lint.sh'; do
  grep -qF -- "$w" <<<"$RULE" && ok || bad "P1 the rule does not name $w"
done

# ── P2: the planning prompt sentence carries the rule ───────────────────────
PR=$(bash -c '. "$1" && th_plan_rule AB-1' _ "$DIR/bin/lib/test-home-lib.sh")
grep -qF 'never the whole payload' <<<"$PR" && grep -qF 'contract-test' <<<"$PR" \
  && ok || bad "P2 th_plan_rule lacks the payload rule: $PR"
[[ $PR == "TEST FILES ARE PER-TICKET"* ]] && ok || bad "P2 th_plan_rule no longer starts with TEST FILES ARE PER-TICKET"
[[ $PR == *[!\ ]" " ]] && ok || bad "P2 th_plan_rule does not end in exactly one space"

# ── P3: the plan contract and the doc ───────────────────────────────────────
[ "$(grep -c '^## 12\. Test style: assert the fields you own (BH-5792)$' "$DIR/prompts/plan-contract.md")" = 1 ] \
  && ok || bad "P3 plan-contract.md lacks exactly one §12 heading"
TD="$DIR/docs/TESTING.md"
if [ -f "$TD" ] && grep -qE '^#+ .*Assert the fields you own' "$TD" \
   && grep -qF 'bin/test-payload-pin-lint.sh' "$TD" && grep -qF 'catalog/payload-pin-lint.conf' "$TD"; then ok
else bad "P3 docs/TESTING.md missing, or lacks the heading or the lint/conf names"; fi

# ── S1: this suite is clean under its own lint ──────────────────────────────
repo; cp "$0" "$T/r/tests/s-test.sh"; commit
run --strict --all "$T/r"
[ "$RC" -eq 0 ] && ok || bad "S1 the lint flags this suite (rc $RC): $OUT $ERR"

echo "test-payload-pin-lint.bh-5792: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
