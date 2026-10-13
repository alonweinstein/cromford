# Account cooldowns (vendor-scoped) and the operator's clear lever

**What it is:** the file that says "this vendor's account refused us, skip it for
a while" — `state/quota/cooldown/<vendor>/<account>`, epoch seconds. One writer
in `bin/agent-call.sh` (the `account-exhausted|auth` branch of `ladder_recover`),
one more in `bin/lib/pool-account.sh` (`pool_account_cooldown`, always `claude`),
one reader in `bin/account-pick.sh` (`account_cooling <vendor> <account>`, used by
both pickers), and one display in `bin/quota-status.sh`.

The vendor is in the key because `default` is a name all five vendors answer to.
On 2026-09-18 a codex `default` exhaustion stamped the unscoped
`state/quota/cooldown/default` and the claude picker read it: every claude pick
exited 2 and every lane logged `no_headroom` for six hours while
`state/quota/default.json` still said `ok`.

**How an operator reaches it.** No cron lane of its own — it is state three lanes
share:

| lane | where it runs | what it does to a cooldown |
|---|---|---|
| any routed stage | `bin/agent-call.sh` `ladder_recover` (every build/triage/review call with `ACCOUNT_ROUTING=1`) | writes `cooldown/<runner>/<account>` on `account-exhausted` / `auth`, nothing on any other class |
| the Fly pool reap | `bin/fly-pool.sh` → `pool_account_cooldown` (`cron/hub.cron`, \*/10 via `fly-pool-tick.sh`) | writes `cooldown/claude/<account>` on the hub for a machine that is about to not exist |
| every pick | `bin/account-pick.sh` (and `pool_account_lease`) | reads it, and sweeps any pre-BH-940 unscoped file to `cooldown/.legacy/` — one `legacy_cooldown_ignored` routing row per file, once per process |

**The lever:**

```bash
/root/harness/bin/quota-status.sh --clear-cooldown <vendor> <account>
```

prints `cleared cooldown <vendor>/<account> (stamped <ISO>, would have run to
HH:MMZ)` and exits 0, or `no cooldown for <vendor>/<account>` and exits 1 having
logged nothing. rc 2 on an unknown vendor or an invalid account name, and then
nothing is removed. It writes nothing else. It exists because releasing an
account otherwise means an `rm` under `state/`, which `bin/iron-law-guard.sh`
family 6 refuses at session level.

**Windows and knobs:** `ACCOUNT_COOLDOWN_SECS` (default `MODEL_COOLDOWN_SECS`,
21600). `bin/quota-poll.sh` deletes stamps older than twice the window on its own
tick. Not this feature: `state/model-cooldown-<model>-<account>`, the fable→opus
credit cooldown, which is a different file with a different meaning.

**How to drive it:**

| what | how |
|---|---|
| the whole contract — isolation both ways, the legacy sweep, the writer, the branch it stays inside, the pool, the display, the lever, expiry | `HARNESS_TEST_SANDBOX=1 bash tests/account-cooldown-vendor.bh-940-test.sh` |
| the picker's own cooldown cases end to end | `HARNESS_TEST_SANDBOX=1 bash tests/account-routing-test.sh` (cases 6, 7, 9, 11, 14, 17) |
| the ladder's rotation on an exhausted/de-authed account | `HARNESS_TEST_SANDBOX=1 bash tests/ladder-recovery-test.sh` (cases 3, 4) |
| the pool's half | `HARNESS_TEST_SANDBOX=1 bash tests/pool-account-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/pool-account-routing-test.sh` |

**What it looks like on a live box** (rung-4/5 evidence, after merge +
`fleet-propagate`, not observed by the build that shipped this):

- `ls /root/harness/state/quota/cooldown/` — vendor directories (`claude/`,
  `codex/`), plus `.legacy/` holding any swept unscoped file.
- `bin/quota-status.sh` — ` cooldown: default cx to 01:24Z` on the `default` row
  while claude on the same box shows no cooldown line at all.
- `logs/account-routing.log` — one `,default,legacy_cooldown_ignored` row on the
  first pick after the rollout, then claude picks with `reason=default`/`only`
  and no new `,claude-*,-,no_headroom` rows.
- `logs/failovers.log` — `account claude/b cooled down 6h — retrying on the next
  claude account with headroom`, and `[quota-status] cooldown codex/default
  cleared by operator` after a lever run.

**Fleet row (BH-2319).** The cooldown file above stays on the box that wrote it.
The worker now also holds a fleet copy in the `fleet_cooldowns` D1 table, keyed
`(kind, vendor, subject)`: `account` (vendor = runner, subject = account),
`model` (vendor = claude, subject = `<model>` or `<model>/<account>`) and `lane`
(vendor = lane, subject = box). The routes are `POST /api/cooldowns`,
`POST /api/cooldowns/clear` and `GET /api/cooldowns[?kind=]`, and the shell
reaches them through `bin/lib/fleet-cooldown.sh` (`fcd_put`, `fcd_clear`,
`fcd_live`, `fcd_list`). **No picker or writer uses the row yet** (later slices
of BH-2319), so `quota-status.sh --clear-cooldown` clears only the file.

| what | how |
|---|---|
| clear the fleet row for one account | `curl -s -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H "content-type: application/json" -d '{"kind":"account","vendor":"claude","subject":"<acct>"}' $JOBS_URL/api/cooldowns/clear` answers `{"cleared":1,...}`, or `0` when there was no row |
| the live probe | `curl -s -H "Authorization: Bearer …" $JOBS_URL/api/cooldowns` answers `{"rows":[...],"truncated":false,"as_of":...}` with only live rows. `{"rows":[],"truncated":false,...}` on a fresh deploy |
| the routes, against real SQL | `cd worker/jobs && node --test test/cooldowns.bh-2353.test.js` |
| the seam and the client verbs | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-cooldown.bh-2353-test.sh` |

**Manual-only / not automatable:** nothing here needs a browser. The live
evidence above needs the hub's own `state/` and is read after a deploy, not in
CI.
