#!/bin/bash
# tests/test-impact-gate-nightly-test.sh — the builder's gate runs the NIGHTLY
# suites a diff reaches, whatever the cap (2026-09-28, the nightly tier).
#
# catalog/test-tiers.tsv takes nightly-tier suites out of every merge-queue
# batch. For a suite the builder's gate left behind, "left to CI" would be a
# false promise: no batch runs it, so it would reach main untested until the
# nightly run. So the gate runs every impacted nightly suite FIRST, outside the
# cap, and names any the budget could not start as left to the NIGHTLY run.
#   G1  with --cap 1 and a reached nightly suite, the nightly suite still runs,
#       ahead of the cap's one, and is not in "left to CI"
#   G2  without a tier file the gate is exactly what it was (cap 1 = 1 suite)
#   G4  a nightly suite the budget could not start is left to the NIGHTLY run,
#       never counted as left to CI
#   G3  the --table tags the nightly row, and never lists it as left to CI
# Real git repos under $T, the real gate and selector, no mocks.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-gate-nightly: git is required"; exit 2; }

R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/catalog"
for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f"
done
chmod +x "$R/bin/"*.sh
printf '#!/bin/bash\nwidget_close_all() { echo closed; }\n' > "$R/bin/lib/widget.sh"
for s in aa zz; do printf '#!/bin/bash\nsleep "${SLOW_%s_SLEEP:-0}"\necho "%s: 1 passed, 0 failed"\n' "$(tr a-z A-Z <<<"$s")" "$s" > "$R/tests/$s-self-test.sh"; done
cat > "$R/tests/slow-reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh" || exit 1
echo "slow-reads: 1 passed, 0 failed"
SH
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"
for s in aa zz; do echo '# touched' >> "$R/tests/$s-self-test.sh"; done
gitc commit -qam touch
export HARNESS="$T/empty"
gate() { ( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" bin/test-impact-gate.sh --base "$BASE" --runner local "$@" 2>&1 ); }

# G2 first: no tier file, cap 1 -> exactly one suite runs.
OUT=$(gate --cap 1); RC=$?
{ [ "$RC" = 0 ] && grep -q 'ran 1 of 3 selected' <<<"$OUT"; } && ok || bad "G2: without a tier file the cap is the cap (rc=$RC): $(tail -3 <<<"$OUT")"

# G1: the reads suite is nightly-tier.
printf 'tests/slow-reads-test.sh\tnightly\t60\t-\tslow\n' > "$R/catalog/test-tiers.tsv"
OUT=$(gate --cap 1 --table "$T/table.md"); RC=$?
[ "$RC" = 0 ] && ok || bad "G1: the gate must pass (rc=$RC): $(tail -5 <<<"$OUT")"
grep -q 'impact-gate: done tests/slow-reads-test.sh rc=0' <<<"$OUT" && ok || bad "G1: the reached nightly suite must RUN in the gate: $OUT"
grep -q 'ran 2 of 3 selected' <<<"$OUT" && ok || bad "G1: nightly suite + the cap's one = 2 ran: $(grep 'ran ' <<<"$OUT")"
first=$(grep '^impact-gate: done ' <<<"$OUT" | head -1)
case "$first" in *slow-reads*) ok ;; *) bad "G1: the nightly suite must run FIRST, got: $first" ;; esac
grep -q slow-reads <<<"$(awk '/^impact-gate: left to CI by the cap \(/ { on = 1; next } on && /^plan:   / { print; next } { on = 0 }' <<<"$OUT")" && bad "G1: a nightly suite is never 'left to CI' — no batch runs it" || ok
# G3
grep -q 'slow-reads-test.sh` | nightly tier' "$T/table.md" && ok || bad "G3: the table must tag the nightly row: $(cat "$T/table.md")"
grep -q slow-reads <<<"$(sed -n '/<summary>Left to CI/,/<\/details>/p' "$T/table.md")" && bad "G3: the table lists a nightly suite as left to CI" || ok

# G4: two nightly suites, the first outlives a 1 s budget: the second is left
# to the NIGHTLY run by name, and only the non-nightly leftover counts as left
# to CI.
printf 'tests/aa-self-test.sh\tnightly\t60\t-\tslow\ntests/zz-self-test.sh\tnightly\t1\t-\tslow\n' > "$R/catalog/test-tiers.tsv"
OUT=$(SLOW_AA_SLEEP=2 gate --cap 5 --budget 1 --table "$T/table4.md"); RC=$?
grep -q 'left to CI: 0 by the cap, 1 by the budget; left to the nightly run only: 1)' <<<"$OUT" && ok \
  || bad "G4: 1 non-nightly suite left to CI, 1 nightly suite left to the nightly run: $(grep 'ran ' <<<"$OUT")"
grep -q 'zz-self-test.sh' <<<"$(sed -n '/NIGHTLY-tier suite/,$p' <<<"$OUT")" && ok || bad "G4: the nightly leftover must be named: $OUT"
grep -q 'Left to the NIGHTLY run only (1)' "$T/table4.md" && ok || bad "G4: the table must list it under the nightly run: $(cat "$T/table4.md")"
grep -q zz-self <<<"$(sed -n '/<summary>Left to CI/,/<\/details>/p' "$T/table4.md")" && bad "G4: the table lists a nightly suite as left to CI" || ok

echo "test-impact-gate-nightly: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
