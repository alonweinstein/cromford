# Account overage headroom (an account billing extra usage is usable)

**What it is:** the reading that stops the pickers parking an account whose
subscription week is spent but which is billing **extra usage** (Anthropic's
overage) and can still serve. The endpoint's `extra_usage` object is carried into
`state/quota/<account>.json` by `bin/quota-poll.sh`, and
`account_reading_class` in `bin/account-pick.sh` — the ONE classifier both the
hub's `account_headroom` and the Fly pool's `_pa_metered` read — answers
`metered|<extra pct>|overage` for it instead of applying `ACCOUNT_WEEK_MAX`.

Also here: **whose meter the implicit `default` account shows.** `default`'s json
is derived from a `bin/extra-usage-track.sh` snapshot, and
`ACCOUNT_DEFAULT_LABEL` says WHICH snapshot — the one for the account
`env/global.env`'s `CLAUDE_CODE_OAUTH_TOKEN` actually bills, which on the hub is
not the box's stored login.

**How an operator reaches it:** no UI route. The operator screen is

```bash
/root/harness/bin/quota-status.sh          # table
/root/harness/bin/quota-status.sh --json   # the same rows as json
```

Read the `default` row: with `ACCOUNT_DEFAULT_LABEL=project-6-account` set in the
hub's `env/global.env` and one `quota-poll.sh` tick run, it shows `WEEK 100%` with
`STATE ok` and an ` extra: on NN% of cap` line underneath. That `extra:` line is
what makes a 100% week readable as a working account rather than a bug. Then
`tail logs/account-routing.log`: no `no_headroom` rows for claude while
`logs/extra-usage*.csv` says `extra_enabled=1,spend_limit_reached=0`.

**Key files/entry points:**
- `bin/quota-poll.sh` `normalize()` — carries `extra_usage` (`utilization` → `pct`); `status_json` carries `extra_usage: null`
- `bin/quota-poll.sh` `DEFAULT_LABEL`/`SNAP`/`SNAP_SOURCE` — the labelled snapshot, and the one `default fallback label_snapshot_missing:<label>` row
- `bin/account-pick.sh` `account_reading_class` — `class|rank_pct|detail`, overage branch before the thresholds
- `bin/account-pick.sh` `account_overage_ok`, `account_cooldown_stamp_short`, and the CLI form `account-pick.sh --overage-ok <account>`
- `bin/lib/pool-account.sh` `_pa_metered` (drop class `capped:<detail>`), `_pa_saturated_reason` (strips the detail, still `all_capped`)
- `bin/agent-call.sh` — the `# >>> overage cooldown (BH-1456)` block in `ladder_recover`'s `account-exhausted|auth` arm
- `bin/quota-status.sh` `row_json` + the ` extra:` table line

**State it reads/writes:** `state/quota/<account>.json`,
`state/extra-usage-last[-<label>].json` (read only; `bin/extra-usage-track.sh`
owns it), `state/quota/cooldown/<vendor>/<account>` (the short window is a
BACKDATED epoch, so every existing reader keeps its single window).

**Preconditions:** a fresh (`status: ok`, younger than
`ACCOUNT_POLL_STALE_SECS`) poll whose `extra_usage.is_enabled` is `true`. A
stale or `unreadable` poll is never overage-ok — the flag means "we have a
current reading that this account can bill".

**Knobs:** `ACCOUNT_EXTRA_MAX` (97), `ACCOUNT_OVERAGE_COOLDOWN_SECS` (900),
`ACCOUNT_DEFAULT_LABEL` (unset; hub `project-6-account`, registered
`settable: false` in `catalog/lanes.d/quota-poll.json` because it is an identity).

**Verify it works:**

| what | how |
|---|---|
| the whole classifier contract — overage metered, `spend_limit`/`disabled`/`extra_cap` still refusing, `is_enabled:false` and a null reading unchanged, the stale negative, the pool lease, the ladder's short cooldown, the status screen | `HARNESS_TEST_SANDBOX=1 bash tests/account-pick.bh-1456-test.sh` |
| `extra_usage` reaching the json, and which snapshot `default` is derived from | `HARNESS_TEST_SANDBOX=1 bash tests/quota-poll.bh-1456-test.sh` |
| the classifier's existing cases, both pickers | `HARNESS_TEST_SANDBOX=1 bash tests/account-routing-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/pool-account-test.sh` |
| the cooldown key contract the short stamp rides on | `HARNESS_TEST_SANDBOX=1 bash tests/account-cooldown-vendor.bh-940-test.sh` |

**Manual-only / not automatable:** setting `ACCOUNT_DEFAULT_LABEL` in the hub's
`env/global.env` (a box env file, outside any test's reach) and reading the real
`quota-status.sh` table on the hub afterwards. Until that knob is set, the hub's
`default` row still describes the box login.
