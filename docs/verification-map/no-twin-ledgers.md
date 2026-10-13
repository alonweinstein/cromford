# The no-twin idempotency ledgers (a hub wipe stops re-buying work)

**What it is:** `bin/lib/ledger-twin.sh` and the six lanes that now keep their
"have we already paid for this?" marker in BOTH places — the file they have
always written, and a row in the existing `ledgers` table
(`worker/jobs/schema.sql`, PK `(kind, key)`). One flag arms all six.

**Why it exists:** BH-1036 (epic #1028). Six hub/box file stores were the ONLY
record that paid or client-visible work had already happened: a dispatched
adversarial review and its daily cap, a lander resolution session, a train
member's close-out comment, a production QA drive, a plan session, an overlap
deferral. All of them live in `state/` on one machine. Wipe the hub — or
re-offer the same build to a different pool box — and every one of them answers
"never seen it". The money is spent twice and, for the batch train, the client
is written to twice.

The seventh store the ticket named, `state/migration-prs-alerted.txt`, is NOT
here: BH-1040 already moved that lane onto `ledgers(kind=migration)` with its
own three-way read and a deliberate write-AFTER-send. A second kind for the
same fact would be a row neither dedup could see, under two different write
orders, so that lane keeps BH-1040's store.

**How an operator reaches it.** It ships DARK. Nothing changes until the
`no-twin-ledgers` pause-flag row is set; with the row absent every lane is
byte-for-byte what it was, and no ledger row is read or written:

```bash
bin/jobs-client.sh flag-set   no-twin-ledgers on "BH-1036 cycle 1"
bin/jobs-client.sh flag-active no-twin-ledgers     # rc 0 once it is up
ls /root/harness/flags/no-twin-ledgers             # what each box tests
```

The file is materialised on every box by the existing `flag_active` reconcile, so
one `flag-set` on the hub arms the fleet within a tick. Turning it off returns
every lane to file-only with no cleanup: rows written while it was on are simply
not read.

**The six twins:**

| store (the file, still written) | lane | kind | key | status |
|---|---|---|---|---|
| `state/review-autopilot/<slug>-<num>-<head12>` | `bin/review-autopilot.sh` (`cron/hub.cron`, hourly :17) | `review_autopilot` | `<owner/repo>#<num>@<head12>` | `reviewed` / `skipped` (verdict in detail) |
| `state/review-autopilot/count-<P>-<YYYYMMDD>` | same lane | `review_autopilot_cap` | `<project> <YYYYMMDD>` | the count, as text |
| `state/lander/<P>-<num>` | `bin/lander.sh` (called by the merge queue) | `lander` | `<project>#<num>@<head>` | `attempted` |
| `state/batch-resolve/<P>/{landed,red,abandoned}.txt` | `bin/batch-resolve.sh` (`cron/hub.cron`) | `batch_member` | `<owner/repo>#<num>@<head>` | `landed` / `red` / `abandoned` |
| `state/overlap-defer/<P>/<KEY>` | `bin/run-build.sh` `# >>> overlap not-before` | — (reads the `overlap_defer` **artifact** back; no new row) | `ticket_id == <KEY>`, ref `deferred` | `detail.not_before_s` |
| `state/postmerge-qa-done.txt` | `bin/postmerge-qa.sh` (`23,53 * * * *`) | `postmerge_qa` | `<build-dir basename>` | `PASS` / `FAIL` / `NOT_COVERED_NO_QA_ENV` |
| `state/plan-malformed.txt` | `bin/run-build.sh` `# >>> plan malformed hold` | `plan_malformed` (already existed) | `<project> <KEY>` | read order flips to ROW FIRST |

**How to drive it:**

| what | how |
|---|---|
| the four library verbs, against the real `bin/jobs-client.sh` with a stubbed curl | section A of `HARNESS_TEST_SANDBOX=1 bash tests/no-twin-ledgers.bh-1036-test.sh` |
| each lane, real script, empty `state/`, populated rows | sections B (review-autopilot), C (lander), D (batch-resolve), E (overlap-defer), F (postmerge-qa), G (plan-malformed) of the same suite |
| the outage breaker: a dead worker is paid for once per process, not once per candidate | section A (A9/A10/A11) and section B (B5') of the same suite |
| the dark `bin/lib/rb/` stage copies still carry the driver's two edited regions | section H of the same suite |
| the existing behaviour is unchanged with the flag off | the "flag off" case in every one of those sections, plus `tests/batch-resolve-test.sh`, `tests/postmerge-qa-test.sh`, `tests/plan-malformed-cap-test.sh`, `tests/merge-funnel-test.sh`, `tests/remediator-agent-test.sh`, which run with no flag and stay green |

**Files it owns on a live box:** none that are new. Every file listed in the
table above is written exactly as before; `logs/jobs-client.log` carries the one
line an outage leaves. After a tick of each lane with the flag on:

```bash
bin/jobs-client.sh ledger-list review_autopilot 5
bin/jobs-client.sh ledger-list review_autopilot_cap 5
bin/jobs-client.sh ledger-list lander 5
bin/jobs-client.sh ledger-list batch_member 5
bin/jobs-client.sh ledger-list postmerge_qa 5
bin/jobs-client.sh artifact-feed overlap_defer <project> "" 5   # <kind> <project> [since] [limit]
```

**Knobs:** one — the `no-twin-ledgers` `pause_flags` row. Nothing else is
configurable and nothing new is hardcoded: the daily review cap
(`REVIEW_AUTOPILOT_DAILY_CAP`) and the deferral window
(`OVERLAP_DEFER_NOTBEFORE_SECS`) keep the env resolution they already had.

**What must never regress:**

- **An unanswerable read is never "already done".** A ledger outage, a flag that
  is off, a box with no `bin/jobs-client.sh` — all of them are rc 1 from
  `lt_get`/`lt_seen`, and every lane falls back to its file. Reading an outage as
  done drops paid work silently; doing the work twice is the strictly safer
  failure and is what the file half already guarantees.
- **A write that cannot be made is not a failure.** `lt_put` is always rc 0. The
  file line is already on disk by the time it runs, so no lane may exit non-zero
  because the side channel blinked.
- **The file is written FIRST, every time.** File then row, and the row is never
  written before the GitHub/Clerk/beat side effect it records. A crash between
  the two leaves the box correct.
- **The key carries the head.** `review_autopilot`, `lander` and `batch_member`
  all key on `(PR, head sha)`, which is the identity their filenames encoded. A
  row at a different head is a different piece of work and must not dedup — a
  push to a branch makes it a candidate again, exactly as before.
- **A `red` row does not satisfy a `landed` guard.** `member_excluded` takes an
  optional status precisely so the settle's narrower question ("has this member
  already been closed out?") cannot be answered by the candidate filter's wider
  one.
- **The daily cap takes the HIGHER of file and row.** A row that reads low — a
  blip, a write that never landed — must never be what buys a 41st review.
- **The artifact read is bounded and the bound cannot hide a live deferral.** The
  `overlap_defer` feed is asked for one hour, 500 rows; the fact's own lifetime is
  `OVERLAP_DEFER_NOTBEFORE_SECS` (default 600s), so a row old enough to fall off
  the end has already expired and falling through is the correct answer.
- **`lt_on` resolves once per process.** `flag_active` reconciles the flag from
  the DB on every call, and the candidate loops (one per open PR, one per train
  candidate) would otherwise turn that into a request per row for an answer that
  cannot change inside one lane run.
- **One outage is paid for once per process.** A worker that REFUSES is cheap; a
  worker that HANGS costs `JOBS_TIMEOUT` x retries per call, and these verbs run
  inside per-candidate loops. The first rc-1 read or failed write latches the
  library off for the rest of the process (`lt_down`), in the documented
  fail-open direction: latched off a read is still never "already done" and a
  write is still rc 0. A real miss (rc 2) never latches — the worker answered.
  The cap row is read once per project per tick for the same reason.
- **The dark `bin/lib/rb/` copies move with the driver.** `bin/lib/rb/gates.sh`
  and `bin/lib/rb/plan.sh` hold BH-478's verbatim slices of the two
  `bin/run-build.sh` regions this touches. They are dark today, so a stale copy
  goes red nowhere until BH-478 flips those stages — section H compares both
  regions byte for byte.
- **The file half stays for one full cycle.** Deleting the file reads is a later
  slice of the epic, and pre-existing file-only markers are NOT backfilled into
  rows by this change — the file still answers them.
