# GitHub API budget

**What it is:** a shared GitHub API rate-limit budget per token. Lanes that
source `bin/lib/gh-budget.sh` share one cached `gh api rate_limit` read and ask
whether non-essential GitHub reads should skip this tick (`gh_budget_low`),
whether a bucket is exhausted (`gh_budget_exhausted`), and raise an ALERTS.log
beat when a bucket hits zero (`gh_budget_ratelimit_alert`).

**How an operator reaches it:** `bin/lib/gh-budget.sh` is sourced by cron
lanes such as `bin/merge-conductor.sh`. Output lands in `logs/<lane>.log` for
the low signal, `logs/ALERTS.log` for exhausted-bucket alerts, and state is
cached under `state/gh-budget/`. Token values never reach filenames, logs, or
the cache.

**How to drive it:**

| what | how |
|---|---|
| the shared library | `bash tests/gh-budget-test.sh` |
| token handling helpers it depends on | `bash tests/gh-repo-token-test.sh` |
| a consumer that skips non-essential reads when low | `bash tests/merge-conductor-test.sh` |

**Files it owns on a live box:**

- `state/gh-budget/<token-fingerprint>.json` — cached `rate_limit` payload, TTL
  `GH_BUDGET_TTL_S` (default 60s). Fingerprint is the sha256 prefix of the
  active token, never the token itself.
- `logs/<lane>.log` — `gh_budget_low` writes one line per (lane, fetched_at)
  when the budget is below threshold.
- `logs/ALERTS.log` — `gh_budget_ratelimit_alert` writes one line per exhausted
  bucket, deduped by reset epoch.
- `state/gh-budget/logged-*` — per-lane dedupe markers for low/unknown signals.
- `flags/alerted-gh-ratelimit-*` — per-bucket alert dedupe markers.

**Knobs:** `gh_budget_min_remaining` via `setting_get`, then
`GH_BUDGET_MIN_REMAINING`, default 800. `GH_BUDGET_TTL_S` controls the cache
TTL (default 60s). See `bin/lib/gh-budget.sh` for resolution order.

**What must never regress:** an unknown budget must still let the lane proceed
(as healthy) while logging the fact; a bucket at zero must page every reset
epoch; non-essential reads must be skipped when low, but essential passes
(merge-queue settle, open-PR classification) must continue.
