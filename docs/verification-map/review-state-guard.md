# Review-state guard (the paid-review ledger cannot read or write as nothing)

**What it is:** `bin/review-prs.sh` spends real money — one Fable session per
unreviewed PR head — and dedupes that spend on
`state/<project>.pr-reviews.json`. The ledger is the only thing standing between
a tick and a second paid review of a head that has not moved.

Until BH-977 the file was seeded (`echo '{}'`) only when it was MISSING, and
every write was `jq … "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"`. On
jq 1.7 a 0-byte input makes the read print nothing with rc 0 AND makes the write
print nothing with rc 0 — so a truncated ledger read as "nothing reviewed" and
was rewritten as 0 bytes on every write, for ever. It could not heal. On the
project-5 box on 2026-09-19 that was 304 reviews and USD 328 in one day, all on
unchanged shas.

Two guards now sit on the file, both inside `bin/review-prs.sh`:

- **`# >>> review-prs state load`** — after the flock, a state file that is not
  a JSON object (0 bytes, garbage, an array, a bare scalar) is reseeded to `{}`
  and ONE line goes to `logs/ALERTS.log` naming the project, the file and the
  byte count. A non-empty bad file is copied to `<state>.json.bad` first, so the
  evidence survives; a 0-byte one is not copied, because a 0-byte `.bad` tells
  nobody anything. A MISSING file is still seeded silently — that is a first
  run, not corruption. A healthy file is not rewritten, not copied and not
  alerted.
- **`# >>> review-prs state write`** — `rp_state_write` is the only writer of
  the ledger. It runs jq into a variable and replaces the file only when the
  result is non-empty AND an object. A refusal keeps the file exactly as it was,
  writes one `logs/pr-reviews.log` line per refusal and at most one
  `logs/ALERTS.log` line per tick, and the tick carries on. A refused write
  costs one extra review of that head next tick — bounded, and announced.

The guards are after the flock on purpose: only the tick that owns the lane
repairs and alerts. A second tick exits at the lock exactly as it always did.

**How an operator reaches it:** there is no UI. The lane is the per-project
`review-prs.sh` line in `cron/<box>.cron` (twice an hour per project).

**Primary lanes / scripts:**
- `bin/review-prs.sh` — the `# >>> review-prs state load` and
  `# >>> review-prs state write` blocks, plus the seven call sites of
  `rp_state_write` (merge-retry alert, merge-retry counter, CI deferral, CI
  stale alert, no-verdict counter, no-verdict give-up, verdict record).
- `bin/review-autopilot.sh` reads the same file (`2>/dev/null || echo ""`) and
  falls back to its own per-head markers, so it never looped on spend. It
  benefits from the healed file without a change of its own.

**Knobs:** none. A switch here would only exist to turn the loop back on.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-state.bh-977-test.sh` — drives
  the REAL script against a scratch `$HARNESS` with `gh` and `agent-call`
  stubbed and two open external PRs on distinct heads. Covers: a 0-byte ledger
  (one tick reviews each head once, the second reviews nothing), a garbage
  ledger (`.bad` keeps the bytes), an array ledger, a healthy ledger left
  byte-identical with no alert, a missing ledger treated as a first run,
  a write whose jq prints nothing at rc 0, a write whose jq exits 1, the static
  pin that exactly one `STATE.tmp` site is left in the script, and two mutation
  cases — with the load block deleted the second tick re-reviews, and with the
  write guard replaced by the naive `tmp && mv` chain the ledger goes to 0
  bytes.
- `HARNESS_TEST_SANDBOX=1 bash tests/review-ci-gate-test.sh` and
  `HARNESS_TEST_SANDBOX=1 bash tests/external-review-ci-read-test.sh` — cover the
  converted write sites from the CI-debounce and verdict-record sides.

**Preconditions / seed needs:** none beyond the fixture suite. On a box, an open
external PR is needed to see a review at all.

**Verify it works (on a box):**

```sh
stat -c%s /root/harness/state/<project>.pr-reviews.json   # non-zero
jq -e 'type == "object"' /root/harness/state/<project>.pr-reviews.json  # rc 0
grep 'was not a JSON object' /root/harness/logs/ALERTS.log   # one repair line, if the box had the defect
grep 'refused to write' /root/harness/logs/pr-reviews.log    # empty unless jq itself is unhappy
```

After the healing tick, an unchanged head produces no new `verdict=` line in
`logs/pr-reviews.log` on the following ticks. That is the user-visible effect:
the 3-4 reviews per PR per hour stop.

**Manual-only / not automatable:** the fleet-wide sweep. Every box heals itself
on its next `review-prs` tick once this is propagated, and the ALERTS line names
the project — reading `logs/ALERTS.log` across the fleet after the propagation
is an operator action, not a check this repo can run.
