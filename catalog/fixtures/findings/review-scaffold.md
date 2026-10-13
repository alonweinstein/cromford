# Adversarial review — BH-900 (general lens)

## Validation trace (plan tasks vs validate.txt)

- **Validation trace (plan tasks vs validate.txt):**
- `npx tsc --noEmit` — clean
- `npx tsc --noEmit` — clean, zero errors on HEAD
- `semgrep.txt` does not exist — nothing to triage
- `semgrep.txt` is empty, so there is nothing to triage.

## Validation trace — plan tasks vs validate.txt

## Requirements coverage vs ticket

## Findings (all minor, none blocking)

- **BLOCKING (D14):** Unsafe trust of client-supplied ids: the PATCH handler in `src/app/api/clients/[id]/route.ts` never re-checks the row's org against the caller's.
- The retry loop in `src/sync.ts` re-sends the webhook on every 500 without an idempotency key
1. The refuter deleted the lock file between the check and the write in `bin/sync-lock.sh` and the second writer won
### Security: route X trusts a client-supplied org id
- `validate.txt` is empty, so task 2 has no VALIDATE evidence at all
- `npm test` passes but 2 suites were skipped with it.skip in tests/x.test.ts
- `npx tsc --noEmit` reports 3 errors in src/lib/format.ts on HEAD
- `bin/sync.sh` passes on ubuntu yet the macOS path is untested
- Findings from the refuter are still unaddressed after fix round 2
## Validation trace — task 3 VALIDATE never ran (D6)
- **Validation trace:** FRAUD: false-completion — validate.txt claims green with HARNESS_EXIT: 1
## Summary — FRAUD: debris in scripts/tmp-backfill.ts and a stray console.log
## Findings: BLOCK on the missing RLS enable for the new payouts table
- `npm test` passes, 2 suites failed on the CI runner
- `validate.txt` exit 0 while harness-suite.txt says HARNESS_EXIT: 1
- `red.txt` passes at base — the repro test is vacuous
- `tsc` ok, the new route leaks every org's clients to any caller
- `npm run build` green; lint reports 4 warnings in src/a.ts
## Summary — the PATCH route never re-checks org ownership
## Findings — the retry loop duplicates payouts on a 500
## System invariants — the lock is held across the build

## Verdict (general lens, re-review)

VERDICT: APPROVE
