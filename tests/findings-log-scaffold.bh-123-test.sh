#!/bin/bash
# tests/findings-log-scaffold.bh-123-test.sh — BH-123: bin/findings-log.sh
# must not log review-format SCAFFOLDING (section openers, tool-clean status
# lines) as findings, and must still log every finding-shaped line, including
# the adversarial near-misses. Drives the real script against a fixture.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FIX="$DIR/catalog/fixtures/findings"
RUN="$DIR/bin/findings-log.sh"
export HARNESS="$T"
mkdir -p "$T/logs"
FLOG="$T/logs/findings.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkbuild() { # mkbuild <name> [<fixture>:<target> ...]
  local d="$T/builds/$1"; shift
  mkdir -p "$d"
  local p; for p in "$@"; do cp "$FIX/${p%%:*}" "$d/${p##*:}"; done
  echo "$d"
}
# logged <ticket> <exact finding text>: a row for the ticket ends in ":: <text>"
logged() { local _l; _l=$(grep -F "ticket=$1 " "$FLOG"); grep -qF ":: $2" <<<"$_l"; }

# A6 (age-out pin): a pre-existing bootstrap scaffold row survives byte-for-byte.
OLD='2026-08-26 03:00:00Z [x] ticket=OLD-1 lens=general verdict=APPROVE rule=- family=7a0b01908ac2 :: Validation trace (plan tasks vs validate.txt)'
printf '%s\n' "$OLD" > "$FLOG"

B=$(mkbuild s1 review-scaffold.md:review.md)
"$RUN" "$B" cromford BH-900; RC=$?
[ "$RC" = 0 ] && ok || bad "rc $RC on the scaffold fixture"

# A1: real findings are logged.
for f in \
  '**BLOCKING (D14):** Unsafe trust of client-supplied ids:' \
  'The retry loop in `src/sync.ts` re-sends the webhook on every 500 without an idempotency key' \
  'The refuter deleted the lock file between the check and the write in `bin/sync-lock.sh` and the second writer won' \
  'Security: route X trusts a client-supplied org id'; do
  logged BH-900 "$f" && ok || bad "A1 real finding not logged: $f"
done
grep -q 'ticket=BH-900 lens=general verdict=APPROVE ' "$FLOG" && ok || bad "A1 verdict should be APPROVE"

# A2: scaffold lines are absent (matched as the WHOLE finding text).
for s in \
  'Validation trace (plan tasks vs validate.txt)' \
  '**Validation trace (plan tasks vs validate.txt):**' \
  'Validation trace — plan tasks vs validate.txt' \
  '`npx tsc --noEmit` — clean' \
  '`npx tsc --noEmit` — clean, zero errors on HEAD' \
  '`semgrep.txt` does not exist — nothing to triage' \
  '`semgrep.txt` is empty, so there is nothing to triage.' \
  'Findings (all minor, none blocking)' \
  'Requirements coverage vs ticket' \
  'Verdict (general lens, re-review)'; do
  grep -F 'ticket=BH-900 ' "$FLOG" | awk -F' :: ' -v t="$s" '$2==t{f=1} END{exit !f}' \
    && bad "A2 scaffold logged as a finding: $s" || ok
done
N=$(grep -c 'ticket=BH-900 ' "$FLOG")
[ "$N" = 21 ] && ok || bad "A2 row count: want 21 real findings, got $N
$(grep 'ticket=BH-900 ' "$FLOG" | sed 's/.* :: /    /')"

# A3: adversarial near-misses are kept.
for f in \
  '`validate.txt` is empty, so task 2 has no VALIDATE evidence at all' \
  '`npm test` passes but 2 suites were skipped with it.skip in tests/x.test.ts' \
  '`npx tsc --noEmit` reports 3 errors in src/lib/format.ts on HEAD' \
  '`bin/sync.sh` passes on ubuntu yet the macOS path is untested' \
  'Findings from the refuter are still unaddressed after fix round 2' \
  'Validation trace — task 3 VALIDATE never ran (D6)' \
  '**Validation trace:** FRAUD: false-completion — validate.txt claims green with HARNESS_EXIT: 1' \
  'Summary — FRAUD: debris in scripts/tmp-backfill.ts and a stray console.log' \
  'Findings: BLOCK on the missing RLS enable for the new payouts table' \
  '`npm test` passes, 2 suites failed on the CI runner' \
  '`validate.txt` exit 0 while harness-suite.txt says HARNESS_EXIT: 1' \
  '`red.txt` passes at base — the repro test is vacuous' \
  "\`tsc\` ok, the new route leaks every org's clients to any caller" \
  '`npm run build` green; lint reports 4 warnings in src/a.ts' \
  'Summary — the PATCH route never re-checks org ownership' \
  'Findings — the retry loop duplicates payouts on a 500' \
  'System invariants — the lock is held across the build'; do
  logged BH-900 "$f" && ok || bad "A3 near-miss dropped: $f"
done
grep -q 'ticket=BH-900 .*rule=D6 .*:: Validation trace — task 3' "$FLOG" && ok || bad "A3 D6 rule not extracted"
grep -q 'ticket=BH-900 .*fraud=false-completion .*:: \*\*Validation trace:\*\*' "$FLOG" \
  && ok || bad "A3 fraud=false-completion not extracted"

# A5: row shape unchanged.
BADSHAPE=$(grep 'ticket=BH-900 ' "$FLOG" | grep -vcE 'lens=general verdict=[^ ]+ rule=[^ ]+ .*family=[0-9a-f]{12} :: ')
[ "$BADSHAPE" = 0 ] && ok || bad "A5 $BADSHAPE rows off the row shape"

# A6: the pre-seeded row is still line 1, byte-for-byte.
[ "$(head -1 "$FLOG")" = "$OLD" ] && ok || bad "A6 pre-existing row rewritten: $(head -1 "$FLOG")"

# A4: the existing fixtures' asserted rows are all still produced.
B=$(mkbuild s2 review-block.md:review.md)
"$RUN" "$B" project-2 TK-900
N=$(grep -c 'ticket=TK-900 ' "$FLOG")
[ "$N" = 4 ] && ok || bad "A4 review-block.md rows: want 4, got $N"
for r in 'rule=D14 family=' 'rule=D1 family=' 'rule=D25 family=' 'rule=- family=[0-9a-f]\{12\} :: \*\*BLOCKING:\*\* validate.txt'; do
  _l=$(grep 'ticket=TK-900 ' "$FLOG"); grep -q "$r" <<<"$_l" && ok || bad "A4 review-block.md row missing: $r"
done
B=$(mkbuild s3 review-fraud-tagged.md:review.md)
"$RUN" "$B" project-2 TK-901
N=$(grep -c 'ticket=TK-901 ' "$FLOG")
[ "$N" = 8 ] && ok || bad "A4 review-fraud-tagged.md rows: want 8, got $N"
for c in weakened-tests false-completion unauthorized-action scope-creep spec-betrayal debris; do
  _l=$(grep 'ticket=TK-901 ' "$FLOG"); grep -q "fraud=$c " <<<"$_l" && ok || bad "A4 fraud=$c row missing"
done

# A7: fail-open on a malformed review: rc 0, nothing appended.
BEFORE=$(wc -l < "$FLOG")
B=$(mkbuild s4 review-malformed.md:review.md)
"$RUN" "$B" project-2 TK-902; RC=$?
[ "$RC" = 0 ] && ok || bad "A7 rc $RC on malformed review"
[ "$(wc -l < "$FLOG")" = "$BEFORE" ] && ok || bad "A7 malformed review appended rows"

echo "findings-log-scaffold.bh-123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
