#!/bin/bash
# tests/checks-suite-test.sh — the mined checks in checks/ must actually FIRE.
#
# Same discipline as tests/guardrails-test.sh, for the harness-side lane: every
# check is exercised against a seeded violation (must fire) AND a clean fixture
# (must stay silent), plus the cross-check that no check fires on ANOTHER
# check's clean fixture. A rule that matches nothing looks exactly like a diff
# with nothing to find, so "it ran and was quiet" proves nothing on its own.
#
# It also proves the two wiring points execute the runner (bin/merge-sweep.sh's
# added-line scan and bin/run-build.sh's review gates) and that the whole lane
# is DETECTION ONLY — no check and no runner may contain a write path.
#
# Self-contained: no network, no secrets, no $HARNESS.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
C="$DIR/checks"
RUN="$DIR/bin/checks-run.sh"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUGS="client-id-trust sql-command-injection secret-literals tests-scratch-only worker-schema-ensure-columns"

# ── 1. catalog shape ────────────────────────────────────────────────────────
[ -x "$RUN" ] && ok || bad "bin/checks-run.sh missing or not executable"
[ -f "$C/README.md" ] && ok || bad "checks/README.md missing"
for S in $SLUGS; do
  [ -x "$C/$S/check.sh" ] && ok || bad "$S: check.sh missing or not executable"
  [ -f "$C/$S/WHY.md" ]   && ok || bad "$S: WHY.md missing"
  for F in violation clean; do
    [ -s "$C/$S/fixtures/$F.diff" ] && ok || bad "$S: fixtures/$F.diff missing or empty"
  done
  # WHY.md must trace the check to the recurrence that earned it, and must own
  # its false positives — a check nobody can argue with gets deleted when wrong.
  grep -qE '^\- \*\*Family key:\*\* `[0-9a-f]+`' "$C/$S/WHY.md" \
    && ok || bad "$S: WHY.md does not name its family key"
  grep -qi 'false positive' "$C/$S/WHY.md" \
    && ok || bad "$S: WHY.md does not document its known false positives"
  # The family key in WHY.md must be the one the check itself cites, so a hit in
  # a log can be traced back to the evidence without opening the catalog.
  FAM=$(grep -oE '^\- \*\*Family key:\*\* `[0-9a-f]+`' "$C/$S/WHY.md" | grep -oE '[0-9a-f]{6,}')
  grep -q "$FAM" "$C/$S/check.sh" \
    && ok || bad "$S: check.sh does not cite family $FAM in its output"
done
# Every catalog directory is covered by this test — a check added without being
# added to SLUGS would otherwise be proven by nothing.
for D in "$C"/*/; do
  S=$(basename "$D")
  grep -qw "$S" <<<"$SLUGS" && ok || bad "checks/$S exists but is not in this test's SLUGS list"
done

# ── 2. every check fires on its violation, stays silent on its clean file ───
for S in $SLUGS; do
  OUT=$("$RUN" "$C/$S/fixtures/violation.diff" 2>&1); RC=$?
  [ "$RC" = 1 ] && ok || bad "$S: runner rc on the seeded violation was $RC, expected 1"
  grep -q "^CHECK-HIT $S " <<<"$OUT" \
    && ok || bad "$S: did NOT fire on its own seeded violation"

  OUT=$("$RUN" "$C/$S/fixtures/clean.diff" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "$S: runner rc on the clean fixture was $RC, expected 0"
  grep -q '^CHECK-HIT ' <<<"$OUT" \
    && bad "$S: something fired on the clean fixture (false positive): $OUT" || ok
  grep -q '^CHECK-ERROR ' <<<"$OUT" \
    && bad "$S: a check crashed on the clean fixture: $OUT" || ok
done

# ── 3. no check fires on another check's clean fixture ──────────────────────
for S in $SLUGS; do
  for O in $SLUGS; do
    [ "$S" = "$O" ] && continue
    OUT=$("$RUN" "$C/$O/fixtures/clean.diff" 2>&1)
    grep -q "^CHECK-HIT $S " <<<"$OUT" \
      && bad "$S fired on $O's clean fixture" || ok
  done
done

# ── 4. the runner's exclusions ──────────────────────────────────────────────
# A test file asserting AGAINST one of these patterns must not be a hit, and
# neither must a spec that quotes the ticket back at itself.
cat > "$T/excluded.diff" <<'EOF'
diff --git a/src/app/api/x/route.test.ts b/src/app/api/x/route.test.ts
--- a/src/app/api/x/route.test.ts
+++ b/src/app/api/x/route.test.ts
@@ -1,2 +1,3 @@
 it("scopes by org", () => {
+  expect(src).not.toContain("where: { id }")
 })
diff --git a/.harness/specs/TK-9/plan.md b/.harness/specs/TK-9/plan.md
--- /dev/null
+++ b/.harness/specs/TK-9/plan.md
@@ -0,0 +1,3 @@
+# Plan for TK-9
+Stop calling prisma.$queryRawUnsafe( with the table name from the request body.
+Never log process.env.CRON_SECRET.
diff --git a/src/app/api/y/route.ts b/src/app/api/y/route.ts
--- a/src/app/api/y/route.ts
+++ b/src/app/api/y/route.ts
@@ -1,2 +1,3 @@
 export async function GET() {
+  // never do: prisma.$queryRawUnsafe(`SELECT * FROM ${t}`)
 }
EOF
OUT=$("$RUN" "$T/excluded.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "test files, spec prose and comment-only lines must all be excluded (rc=$RC): $OUT"

# The exclusions must not have blinded the checks: the same prose alongside a
# REAL violation in real code still fires.
cat > "$T/excluded-plus-real.diff" <<'EOF'
diff --git a/.harness/specs/TK-9/plan.md b/.harness/specs/TK-9/plan.md
--- /dev/null
+++ b/.harness/specs/TK-9/plan.md
@@ -0,0 +1,2 @@
+# Plan for TK-9
+Stop calling prisma.$queryRawUnsafe( with the table name from the request body.
diff --git a/src/app/api/y/route.ts b/src/app/api/y/route.ts
--- a/src/app/api/y/route.ts
+++ b/src/app/api/y/route.ts
@@ -1,2 +1,3 @@
 export async function GET(req) {
+  return prisma.$queryRawUnsafe(req.query.sql)
 }
EOF
OUT=$("$RUN" "$T/excluded-plus-real.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q '^CHECK-HIT sql-command-injection ' <<<"$OUT" \
  && ok || bad "a real violation beside excluded prose must still fire (rc=$RC): $OUT"

# ── 5. runner contract: rc 2 when it cannot run, never a quiet 0 ────────────
OUT=$("$RUN" "$T/does-not-exist.diff" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a missing diff must be rc 2 (could not run), got $RC"
grep -q 'could not run' <<<"$OUT" && ok || bad "rc 2 must SAY it could not run, got: $OUT"
OUT=$(CHECKS_DIR="$T/nope" "$RUN" "$C/client-id-trust/fixtures/clean.diff" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a missing catalog must be rc 2, got $RC"

# An empty diff is clean, not an error.
: > "$T/empty.diff"
OUT=$("$RUN" "$T/empty.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^CHECKS: clean' <<<"$OUT" \
  && ok || bad "an empty diff must be clean (rc=$RC): $OUT"

# A crashing check is REPORTED, never swallowed into a passing run.
mkdir -p "$T/cat/boom"
printf '#!/bin/bash\nexit 3\n' > "$T/cat/boom/check.sh"; chmod +x "$T/cat/boom/check.sh"
OUT=$(CHECKS_DIR="$T/cat" "$RUN" "$C/client-id-trust/fixtures/clean.diff" 2>&1)
grep -q '^CHECK-ERROR boom rc=3' <<<"$OUT" \
  && ok || bad "a check exiting >1 must be reported as CHECK-ERROR, got: $OUT"

# ── 6. DETECTION ONLY — the whole lane has no write path ────────────────────
# The lane's one promise is that a hit parks and alerts and never changes code.
# Grep is a blunt instrument, so it is aimed at the verbs that would break the
# promise: git writes, gh mutations, and in-place edits.
for F in "$RUN" "$C"/*/check.sh; do
  if grep -nE '(git[[:space:]]+(commit|push|checkout|reset|revert|merge|apply|add)|gh[[:space:]]+(pr[[:space:]]+(merge|close|edit)|api[[:space:]]+-X)|sed[[:space:]]+-i|>[[:space:]]*"?\$(SRC|FILE))' "$F" \
     | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
    bad "$(basename "$(dirname "$F")")/$(basename "$F"): contains a write path — this lane is detection only"
  else ok; fi
done

# ── 7. the gates actually EXECUTE the runner ───────────────────────────────
# A catalog nothing runs is a catalog that proves nothing. Both wiring points
# are asserted, and merge-sweep's is asserted by RUNNING its extracted scan
# block over a fixture, not by grepping for a call it might never reach.
grep -q 'checks-run.sh' "$RB_ALL" \
  && ok || bad "bin/run-build.sh does not run the checks"
grep -q 'CHECKS_NOTE' "$RB_ALL" \
  && ok || bad "bin/run-build.sh does not feed the check results to the reviewer"
grep -q 'GATES_NOTE.*CHECKS_NOTE' "$RB_ALL" \
  && ok || bad "the check note must join GATES_NOTE, which is what reaches the review prompt"
grep -q 'checks-run.sh' "$DIR/bin/merge-sweep.sh" \
  && ok || bad "bin/merge-sweep.sh does not run the checks"
grep -q 'CHECKOUT/checks' "$DIR/bin/harness-sync.sh" \
  && ok || bad "bin/harness-sync.sh does not deploy checks/ to the boxes — the wiring would be dead there"

mkdir -p "$T/bin"
awk '/^ *# >>> iron-law scan/{f=1;next} /^ *# <<< iron-law scan/{exit} f' \
  "$DIR/bin/merge-sweep.sh" > "$T/scan.sh"
[ -s "$T/scan.sh" ] && ok || bad "could not extract the merge-sweep scan block — markers missing?"
# The sweep reads the diff through mc_pr_diff now (BH-784), i.e. one
# `gh api -i -X GET repos/o/r/pulls/1 -H "Accept: application/vnd.github.v3.diff"`
# whose answer is judged on its HTTP status line. So the stub prints a real 200
# response whose body is the fixture, and the scan block is sourced with the
# conductor lib that owns the read (gh-rest.sh rides with it, or every read
# answers "unverifiable" and the sweep skips the PR before it ever scans).
cp "$DIR/tests/lib/rest-emit.sh" "$T/bin/restpr"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --raw 200; cat "$FIXTURE_DIFF" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/restpr"
# $H points at a fake box layout whose bin/ holds the REAL runner and whose
# checks/ is the REAL catalog, which is exactly how a box resolves them.
mkdir -p "$T/box/bin/lib"; cp "$RUN" "$T/box/bin/"; cp -r "$C" "$T/box/checks"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/box/bin/lib/"
mkdir -p "$T/box/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/box/bin/lib/mc/"
scan() { # scan <fixture> -> the FLAGS count the sweep would park on
  ( PATH="$T/bin:$PATH" FIXTURE_DIFF="$1" PR="https://github.com/o/r/pull/1" H="$T/box" \
    HARNESS="$T/box" LOG="$T/sweep.log" \
    bash -c 'set -uo pipefail; STAMP() { date -u "+%F %TZ"; }
             . "$HARNESS/bin/lib/merge-conductor-lib.sh"; . "$0"; echo "${FLAGS:-x}"' "$T/scan.sh" 2>/dev/null )
}
# 4, not 3, since BH-1124 added the 40-char ghs_ literal to that fixture so the
# bounded GitHub-token branch is still proven to FIRE.
[ "$(scan "$C/secret-literals/fixtures/violation.diff")" = 4 ] \
  && ok || bad "the sweep must count mined-check hits as red flags (got: $(scan "$C/secret-literals/fixtures/violation.diff"), expected 4)"
[ "$(scan "$C/secret-literals/fixtures/clean.diff")" = 0 ] \
  && ok || bad "the sweep must stay at 0 on a clean diff (got: $(scan "$C/secret-literals/fixtures/clean.diff"))"
# FAIL-OPEN: no runner on the box means the sweep behaves exactly as it did
# before this catalog existed. A broken detector must never invent a reason to
# hold a PR that passed review.
noruntime() {
  ( PATH="$T/bin:$PATH" FIXTURE_DIFF="$1" PR="https://github.com/o/r/pull/1" H="$T/nobox" \
    HARNESS="$T/box" LOG="$T/sweep.log" \
    bash -c 'set -uo pipefail; STAMP() { date -u "+%F %TZ"; }
             . "$HARNESS/bin/lib/merge-conductor-lib.sh"; . "$0"; echo "${FLAGS:-x}"' "$T/scan.sh" 2>/dev/null )
}
[ "$(noruntime "$C/secret-literals/fixtures/violation.diff")" = 0 ] \
  && ok || bad "with no runner deployed the sweep must fail open to 0 (got: $(noruntime "$C/secret-literals/fixtures/violation.diff"))"

# ── 8. tree-capable checks ──────────────────────────────────────────────────
# fixtures/tree-bad/ is how a check declares it can read a WHOLE CHECKOUT rather
# than a diff, and the claim is proven exactly the way sections 2 and 3 prove
# the diff claim: FIRE on the bad tree, stay SILENT on the good one, through the
# real runner. Each check is run against a catalog holding only itself, so the
# rc and the hits belong to it and not to a neighbour that happens to dislike
# the same fixture tree.
NTREE=0
for D in "$C"/*/; do
  S=$(basename "$D")
  [ -d "$D/fixtures/tree-bad" ] || continue
  NTREE=$((NTREE + 1))
  [ -d "$D/fixtures/tree-good" ] \
    && ok || bad "$S: ships fixtures/tree-bad/ but no fixtures/tree-good/ to prove it stays quiet"
  mkdir -p "$T/treecat-$S"
  cp -r "$D" "$T/treecat-$S/$S"
  OUT=$(CHECKS_DIR="$T/treecat-$S" "$RUN" --tree "$D/fixtures/tree-bad" 2>&1); RC=$?
  [ "$RC" = 1 ] && ok || bad "$S: runner --tree on its own tree-bad fixture was rc $RC, expected 1"
  grep -q "^CHECK-HIT $S " <<<"$OUT" \
    && ok || bad "$S: did NOT fire on its own tree-bad fixture: $OUT"

  OUT=$(CHECKS_DIR="$T/treecat-$S" "$RUN" --tree "$D/fixtures/tree-good" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "$S: runner --tree on its own tree-good fixture was rc $RC, expected 0"
  grep -q '^CHECKS: clean (' <<<"$OUT" \
    && ok || bad "$S: tree-good must report a clean tree run, got: $OUT"
done
[ "$NTREE" -gt 0 ] \
  && ok || bad "no tree-capable check in the catalog — section 8 proved nothing"

# The runner's tree contract, same shape as section 5's diff contract: a root
# that is not there is rc 2 and says so, never a quiet clean.
OUT=$("$RUN" --tree "$T/no-such-tree" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "runner --tree on a missing root must be rc 2, got $RC"
grep -q 'could not run' <<<"$OUT" && ok || bad "runner --tree rc 2 must SAY it could not run, got: $OUT"

echo "checks-suite-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
