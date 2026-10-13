# Tier-2 payload dedup (pay for a remediation payload once)

**What it is:** the file that says "we already asked the model this exact
question" — `state/remediation-payload-dedup.tsv`, one row per fingerprint of
(akey + alert line + key-sorted payload JSON). One writer and one reader, both
in `bin/remediate-agent.sh`: a read-only lookup before the daily-cap claim, a
`pending` claim under `flock` immediately before `bin/agent-call.sh`, and the
outcome settled immediately after it.

Inside `REMEDIATE_DEDUP_WINDOW` (default 86400s, measured from the last
attempt): `ok` and `empty` are terminal on the first answer — an empty answer
was billed too — and `failed`/`pending` retry until `attempts` reaches
`REMEDIATE_DEDUP_CAP` (default 3). A hit never suppresses: it fails open with
its reason on the page, logged `FAILOPEN-dedup`.

**How an operator reaches it.** No cron lane of its own. It runs inside tier 2
of the alert remediation lane, which is opt-in per box:

| lane | where it runs | what it does to the ledger |
|---|---|---|
| any `fleet_alert` beat | `bin/beat.sh` → `rem_try` → `bin/remediate-agent.sh` (only with `flags/remediation-agent-enabled` present, and only after the 6h akey throttle lets the alert through) | claims `pending` before the call, settles `ok`/`empty`/`failed` after it |
| a hand run of the wrapper | `bin/remediate-agent.sh <akey> <line> <payload-json>` | the same — the guard is in the script, not in its caller |

**Preconditions:** `flags/remediation-agent-enabled` exists (hub pilot, created
by hand), `flags/remediation-disabled` does not, and `sha256sum`, `jq`,
`python3` and `flock` are on PATH. Without `sha256sum` the wrapper refuses the
run rather than fingerprinting every payload to the same key.

**Knobs:** `REMEDIATE_DEDUP_WINDOW` (seconds, default 86400),
`REMEDIATE_DEDUP_CAP` (attempts, default 3). Garbage or zero falls back to the
default. Not this feature: `REMEDIATE_DAILY_CAP` (20 runs/day, a different
ledger) and `REM_WINDOW` in `beat.sh` (the 6h akey throttle, a different key).

**How to drive it:**

| what | how |
|---|---|
| the whole contract — one call per payload, the cap of 3, an empty result terminal, the window boundary both ways, the marker present at call time, an unwritable ledger, and the beat.sh path | `HARNESS_TEST_SANDBOX=1 bash tests/remediate-agent-dedup-test.sh` |
| the rest of tier 2 (pilot flag, evidence rule, daily cap, kill switch) still intact | `HARNESS_TEST_SANDBOX=1 bash tests/remediator-agent-test.sh` |
| tier 1 handlers | `HARNESS_TEST_SANDBOX=1 bash tests/remediation-hook-test.sh` |

**Verify it works** (on a pilot box, after merge and `fleet-propagate` — not
observed by the build that shipped this):

- `cat /root/harness/state/remediation-payload-dedup.tsv` — one tab-separated
  row per fingerprint: `last_ts  fp  attempts  outcome  akey`. No payload text
  and no alert line anywhere in the file.
- `grep FAILOPEN-dedup /root/harness/logs/remediation.log` — the repeats that
  cost nothing, each carrying why (`already got an agent run Ns ago (outcome:
  ok)` or `already failed 3 agent attempts (cap 3)`).
- `state/alert-quarantine.jsonl` — the deduped alert is still there, with
  ` [remediator tried: this exact alert payload already …]` appended to its
  line. A dedup hit that stopped paging would be the bug.
- `logs/cost.csv` — no new `,remediate,` row for a hit, because no vendor call
  was made.

**Manual-only / not automatable:** nothing here needs a browser. The live
evidence above needs a box with the pilot flag set and is read after a deploy,
not in CI.
