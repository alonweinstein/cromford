#!/bin/bash
# tests/test-impact-gate-fast.bh-3860-test.sh — the builder's gate runs the
# FAST-LINT set first, outside the cap (BH-3860, slice BH-3863).
#
# Always-suites ranked third in bin/test-impact-gate.sh, so the cap or the
# budget could drop a 2 s lint and it reached a merge-queue batch untested. The
# gate now reads the checkout's own `bin/fast-lints.sh --list` (or the
# TEST_IMPACT_GATE_FAST seam) and runs that set ahead of everything else.
#   F1  with --cap 1, the two fast suites are the first two plan rows, each with
#       the reason `fast-lint (the PR check runs it too)`
#   F2  both run, first, and the cap applies only to the rest
#   F2b a fast suite the selection also picked keeps its old reasons after `; `
#   F3  the plan line says `cap 1 + 2 fast-lint suite(s) outside it`
#   F4  --skip-suites wins: a fast suite the rules pack ran is not run twice
#   F5  --table tags the fast rows `(fast)` and nothing else
#   F6  no bin/fast-lints.sh and no seam: the plan is the pre-change gate's,
#       byte for byte; a fast-lints.sh that fails is one note and no tier
#   F7  --help carries the FAST-LINT TIER (BH-3860) paragraph
#   F8  with no seam, an executable bin/fast-lints.sh --list is the source
# Real git repos under $T, the real gate and selector, no mocks.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-gate-fast: git is required"; exit 2; }

R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/catalog"
for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f"
done
chmod +x "$R/bin/"*.sh
printf '#!/bin/bash\nwidget_close_all() { echo closed; }\n' > "$R/bin/lib/widget.sh"
for s in aa zz; do printf '#!/bin/bash\necho "%s: 1 passed, 0 failed"\n' "$s" > "$R/tests/$s-self-test.sh"; done
cat > "$R/tests/slow-reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh" || exit 1
echo "slow-reads: 1 passed, 0 failed"
SH
# Two always-lints the diff does not touch. fa is in the always list, so the
# selection picks it too (the overlap path); fb is picked by nothing (rank-0 append).
for s in fa fb; do printf '#!/bin/bash\necho "%s-lint: 1 passed, 0 failed"\n' "$s" > "$R/tests/$s-lint-test.sh"; done
printf 'tests/fa-lint-test.sh  whole-tree lint\n' > "$R/catalog/test-impact-always.txt"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"
for s in aa zz; do echo '# touched' >> "$R/tests/$s-self-test.sh"; done
gitc commit -qam touch
export HARNESS="$T/empty"
unset TEST_IMPACT_GATE_FAST TEST_IMPACT_GATE_TIERS TEST_IMPACT_GATE_CAP TEST_IMPACT_GATE_BUDGET_S
printf 'tests/fa-lint-test.sh\ntests/fb-lint-test.sh\n' > "$T/fast.txt"
gate() { ( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --runner local "$@" 2>&1 ); }
FL='fast-lint (the PR check runs it too)'

# F1 / F2 / F2b / F3 / F5
OUT=$(TEST_IMPACT_GATE_FAST="$T/fast.txt" gate --cap 1 --table "$T/table.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "F1: the gate must pass (rc=$RC): $(tail -5 <<<"$OUT")"
P1=$(grep '^plan: tests/' <<<"$OUT" | sed -n 1p); P2=$(grep '^plan: tests/' <<<"$OUT" | sed -n 2p)
case "$P1" in "plan: tests/fa-lint-test.sh"*"$FL"*) ok ;; *) bad "F1: first plan row must be fa with the fast reason, got: $P1" ;; esac
case "$P2" in "plan: tests/fb-lint-test.sh"*"$FL") ok ;; *) bad "F1: second plan row must be fb with only the fast reason, got: $P2" ;; esac
case "$P1" in *"$FL; always "*) ok ;; *) bad "F2b: a selected fast suite keeps its old reasons after '; ', got: $P1" ;; esac
for s in fa fb; do
  grep -q "^impact-gate: done tests/$s-lint-test.sh rc=0$" <<<"$OUT" && ok || bad "F2: $s must run: $OUT"
done
D=$(grep '^impact-gate: done ' <<<"$OUT")
[ "$(sed -n 1p <<<"$D")" = 'impact-gate: done tests/fa-lint-test.sh rc=0' ] \
  && [ "$(sed -n 2p <<<"$D")" = 'impact-gate: done tests/fb-lint-test.sh rc=0' ] && ok \
  || bad "F2: the fast suites must run FIRST: $D"
[ "$(grep -c . <<<"$D")" = 3 ] && ok || bad "F2: cap 1 applies to the rest — exactly 3 ran, got: $D"
grep -q 'ran 3 of 5 selected suites via local: passed (left to CI: 2 by the cap, 0 by the budget)' <<<"$OUT" && ok \
  || bad "F2: ran 3 of 5, 2 left to CI by the cap: $(grep 'ran ' <<<"$OUT")"
grep -q 'lint-test' <<<"$(awk '/^impact-gate: left to CI by the cap \(/ { on = 1; next } on && /^plan:   / { print; next } { on = 0 }' <<<"$OUT")" \
  && bad "F2: a fast suite is never left to CI by the cap" || ok
grep -qF 'running up to 3 of 5 selected suites (cap 1 + 2 fast-lint suite(s) outside it, budget 450s); left to CI by the cap: 2' <<<"$OUT" && ok \
  || bad "F3: plan line: $(grep 'running up to' <<<"$OUT")"
grep -qF "| \`tests/fa-lint-test.sh\` | (fast) $FL; always" "$T/table.md" && ok || bad "F5: fa row tagged (fast): $(cat "$T/table.md")"
grep -qF "| \`tests/fb-lint-test.sh\` | (fast) $FL |" "$T/table.md" && ok || bad "F5: fb row tagged (fast): $(cat "$T/table.md")"
[ "$(grep -c '(fast)' "$T/table.md")" = 2 ] && ok || bad "F5: only the two fast rows are tagged: $(cat "$T/table.md")"

# F4: the rules pack ran fb; it is never run (or planned) again, and fa still runs.
printf 'tests/fb-lint-test.sh\n' > "$T/skip.txt"
OUT=$(TEST_IMPACT_GATE_FAST="$T/fast.txt" gate --cap 1 --skip-suites "$T/skip.txt"); RC=$?
[ "$RC" = 0 ] && ok || bad "F4: the gate must pass (rc=$RC): $(tail -5 <<<"$OUT")"
grep -qx 'plan: tests/fb-lint-test.sh  run by the rules pack (outside the cap)' <<<"$OUT" && ok || bad "F4: fb is reported as run by the rules pack: $OUT"
grep -q 'done tests/fb-lint-test.sh' <<<"$OUT" && bad "F4: fb must not run twice: $OUT" || ok
grep -q "^plan: tests/fb-lint-test.sh .*$FL" <<<"$OUT" && bad "F4: fb must not be a fast plan row: $OUT" || ok
grep -q '^impact-gate: done tests/fa-lint-test.sh rc=0$' <<<"$OUT" && ok || bad "F4: fa still runs: $OUT"
grep -qF '(cap 1 + 1 fast-lint suite(s) outside it' <<<"$OUT" && ok || bad "F4: one fast suite left: $(grep 'running up to' <<<"$OUT")"

# F6: no seam, no bin/fast-lints.sh — the plan output equals the pre-change
# gate's. The reference is the gate before BH-3860, taken from git when this
# checkout can see it (a CI or box checkout); an isolated snapshot has no
# history, so there the exact F=0 text is checked on its own.
OUT=$(gate --cap 1 --runner plan); RC=$?
[ "$RC" = 0 ] && ok || bad "F6: plan run rc=$RC: $OUT"
grep -q 'fast' <<<"$OUT" && bad "F6: no fast-lints.sh and no seam must mean no fast tier and no note: $OUT" || ok
grep -qF 'running up to 1 of 4 selected suites (cap 1, budget 450s); left to CI by the cap: 3' <<<"$OUT" && ok \
  || bad "F6: the F=0 plan line is today's text: $(grep 'running up to' <<<"$OUT")"
REF=""
for ref in 0cd2c96 origin/main; do
  REF=$(git -C "$DIR" show "$ref:bin/test-impact-gate.sh" 2>/dev/null) && ! grep -q 'FAST-LINT TIER' <<<"$REF" && break
  REF=""
done
if [ -n "$REF" ]; then
  R0="$T/repo0"; git clone -q "$R" "$R0"
  printf '%s\n' "$REF" > "$R0/bin/test-impact-gate.sh"
  OUT0=$( cd "$R0" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --cap 1 --runner plan 2>&1 )
  [ "$(grep -E '^(plan:|impact-gate: running up to)' <<<"$OUT")" = "$(grep -E '^(plan:|impact-gate: running up to)' <<<"$OUT0")" ] && ok \
    || bad "F6: plan lines differ from the pre-change gate: $(diff <(grep -E '^(plan:|impact-gate: running up to)' <<<"$OUT0") <(grep -E '^(plan:|impact-gate: running up to)' <<<"$OUT"))"
else
  echo "note: F6 pre-change reference not reachable from this checkout — the exact-text check above stands alone"
fi
# A fast-lints.sh that cannot answer (rc 2: the always-set unavailable) is one
# note on stderr, rc 0, and no tier.
printf '#!/bin/bash\necho "fast-lints: always-suite set unavailable" >&2\nexit 2\n' > "$R/bin/fast-lints.sh"; chmod +x "$R/bin/fast-lints.sh"
ERR=$( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --cap 1 --runner plan 2>&1 >"$T/f6.out" ); RC=$?
[ "$RC" = 0 ] && ok || bad "F6: a failing fast list is never fatal (rc=$RC): $ERR"
[ "$(grep -c 'impact-gate: fast-lint list unavailable — no fast tier' <<<"$ERR")" = 1 ] && ok || bad "F6: exactly one note on stderr, got: $ERR"
grep -q "$FL" "$T/f6.out" && bad "F6: a failing list gives no fast tier: $(cat "$T/f6.out")" || ok

# F8: no seam, an executable bin/fast-lints.sh --list naming fa is the source.
printf '#!/bin/bash\n[ "$1" = --list ] || exit 2\necho tests/fa-lint-test.sh\n' > "$R/bin/fast-lints.sh"; chmod +x "$R/bin/fast-lints.sh"
OUT=$(gate --cap 1 --runner plan); RC=$?
[ "$RC" = 0 ] && ok || bad "F8: rc=$RC: $OUT"
case "$(grep '^plan: tests/' <<<"$OUT" | sed -n 1p)" in "plan: tests/fa-lint-test.sh"*"$FL"*) ok ;; *) bad "F8: fast-lints.sh --list must feed the tier: $OUT" ;; esac
grep -qF '(cap 1 + 1 fast-lint suite(s) outside it' <<<"$OUT" && ok || bad "F8: plan line: $(grep 'running up to' <<<"$OUT")"
rm -f "$R/bin/fast-lints.sh"

# F7
( cd "$R" && bin/test-impact-gate.sh --help ) | grep -q 'FAST-LINT TIER (BH-3860)' && ok || bad "F7: --help must carry the FAST-LINT TIER paragraph"

echo "test-impact-gate-fast: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
