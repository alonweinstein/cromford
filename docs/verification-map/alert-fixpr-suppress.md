# Fix-PR brake on alert triage

**What it is:** the second brake on `bin/alert-triage.sh`. The 6h TTL brake stops
a family being re-investigated every tick; this one stops it being
re-investigated forever once the fix is already written. A family whose recorded
fix PR `bin/gh-pr-state.sh` confirms is still OPEN is ANSWERED: no session is
bought, the lane logs `ANSWERED-PENDING-MERGE`, and one beat per family per
calendar day says "merge it". Past `FIXPR_STALE_HOURS` the escalation gets
louder and goes out on its own akey, once. When the PR merges or closes the
entry is dropped and the family triages normally again, because the fix may not
have worked.

**The first "merge it" can lag up to 6h.** The session that records the fix PR
is also stamped into the 6h TTL brake, and that check runs first, so the
family's next lines are TTL-dropped with no `ANSWERED-PENDING-MERGE` line until
the 6h expires. The 6h brake is untouched by design; the fix-PR brake takes over
after it.

Entries are written by the lane itself: a triage session that ends by naming an
open PR (`FIX-PR: https://github.com/<owner>/<repo>/pull/<n>`, the line
immediately before its summary line, step 4 of the prompt) has that url verified
with one `bin/gh-pr-state.sh` read and recorded under the family key.

**Both state reads go through `bin/gh-pr-state.sh`** — the once-per-recording
read and the once-per-answered-family-per-tick read. It is a child process on
purpose: it arms the repo-scoped App installation token (`bin/lib/gh-app-auth.sh`)
so both reads run on the same identity, it reads over REST
(`gh_rest_pr_state`, so a rate limit answers "unverifiable" rather than the
empty string #768 was about), and being a child it cannot hand the lane's own
`GH_TOKEN` back to a pre-env snapshot the way an in-shell `gh_auth_reset` does
(BH-470).

**How an operator reaches it:** `cron/hub.cron` line 39,
`*/10 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/alert-triage.sh`,
on the hub. Nothing else calls it. Output lands in `logs/alert-triage.log`,
including the stale escalation, and the beats reach the console/Telegram on the
akeys `triage-fixpr:<family>` and `triage-fixpr-stale:<family>`. The stale
escalation deliberately does NOT go to `logs/ALERTS.log`: `bin/poll-commands.sh`
re-beats every new ALERTS.log line on its own akey, which paged twice a day for
one stale PR.

**How to drive it:**

| what | how |
|---|---|
| the brake, the answered loop, the record path, the armed REST read, `BEAT_STRICT`, every fail-open case | `HARNESS_TEST_SANDBOX=1 bash tests/alert-fixpr-suppress-test.sh` |
| the neighbours it must not disturb (6h TTL brake, family cap, deferral spool, per-family tiering) | `HARNESS_TEST_SANDBOX=1 bash tests/triage-split-test.sh` |
| the family key it stores under | `python3 bin/alert_family.py family "<raw quarantine line with its source prefix>"` |
| one clock read per fixture | `bash bin/test-determinism-lint.sh tests/alert-fixpr-suppress-test.sh` |

Both suites run the real `bin/alert-triage.sh` against a scratch `$HARNESS` with
`agent-call.sh`, `beat.sh`, `gh`, `ssh`, `flock` and `timeout` stubbed; what
those stubs receive is the assertion. `bin/gh-pr-state.sh`, `bin/lib/gh-rest.sh`
and `bin/lib/gh-app-auth.sh` are the REAL files, so the identity the read arms
and the protocol it speaks are under test — the `gh` stub records both.

**Files it owns on a live box (the hub):**

- `state/alert-triage/<project>/alert-fix-prs.json` — the ledger, one per
  project run since BH-5942 (seeded once by a copy of the old shared
  `state/alert-fix-prs.json`). `{"<family-12hex>": {"pr_url",
  "first_seen", "last_checked", "suppressed_total", "beat_day",
  "stale_beat_at"}}`. Written whole-file (temp + `os.replace`) under the
  project run's `locks/alert-triage-<project>.lock`. Pruned when the PR leaves OPEN, or after
  30 days with no successful check.
- `logs/alert-triage.log` — `ANSWERED-PENDING-MERGE family=<f> lines=<n>
  total=<N> fix=<url> (no session, $0)` per answered family per tick, plus one
  line per drop, unreadable entry, unreadable ledger, failed state check and
  prune, plus `named fix PR <url> (OPEN) — recorded` after a recording session,
  plus `FIX PR STALE: <url> has been open for <h>h ...` once per family per open
  PR.
- `flags/fixpr-suppress-off` — the kill switch (see below); nothing creates it.

**Knobs:** `FIXPR_STALE_HOURS` (default 24) from `env/global.env`.
`TRIAGE_NOW` is test-only scaffolding for pinning the tick's clock; production
leaves it unset. `flags/fixpr-suppress-off` disables the diversion entirely —
every family buys its session exactly as it did before this brake existed, no
`gh` read happens, and sessions still RECORD new entries, so the ledger is warm
when the flag comes off.

**What must never regress:**

- A suppression may only follow a positive `OPEN` read. A missing ledger, a torn
  ledger, an entry with no `pr_url`, a `gh` that exits nonzero or times out, and
  the kill switch must all leave the family buying its session, with the reason
  in the lane log.
- An answered family is never stamped into `state/alert-families.json` (the 6h
  brake must not learn about a family it never triaged) and never enters the
  family cap or the deferral spool.
- Send then stamp: `beat_day` and `stale_beat_at` are written only after
  `beat.sh` returns 0 **under `BEAT_STRICT=1`**, so a beat that failed to send
  is retried next tick instead of being silently marked as delivered. Without
  that flag `beat.sh` returns 0 for a beat the console never took, and the
  invariant holds only against a stub. rc 2 (no console configured on this box)
  counts as delivered — there is nothing to retry.
- Neither state read goes through `gh pr view`. A rate-limited GraphQL read
  answers an empty string that a decision path reads as "no such PR" (#768);
  `bin/gh-pr-state.sh` keeps 44 (no such PR) and 75 (unverifiable) apart, and
  only a literal `OPEN` ever suppresses.
- The stale escalation pages ONCE: the beat is the escalation, `logs/ALERTS.log`
  is not written, because `bin/poll-commands.sh` would re-beat it.
- The counts in the log and beat lines are the real ones (`lines` this tick,
  `total` cumulative, `<h>h` open).
- Only an anchored `^FIX-PR: <pull-url>` in the session's last message records,
  and only after the harness itself confirms the url is OPEN — a mid-sentence
  mention, an `/issues/` path, a bare `PR #573` and a merged or closed url must
  all record nothing.
