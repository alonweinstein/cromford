# Mission Control ACCOUNT & TOKEN HEALTH (BH-2516)

**What it is:** a read-only section on the hub tab of `/settings`, directly
below PROJECT ACCOUNTS. One row per credential the fleet runs on (Claude
OAuth, GitHub App): KIND, ACCOUNT, LEASES, EXPIRES, LAST REFRESH, FAILS,
LAST ERROR, BOX. A row is red when the worker says `expiring` (under
`warn_h` hours to expiry, expired included). The threshold and where it came
from are printed under the table.

**How a user reaches it:** sign in to Mission Control → nav → SETTINGS → the
HUB tab (the default) → scroll below PROJECT ACCOUNTS to ACCOUNT & TOKEN
HEALTH.

**Key routes/screens:**
- `/settings` — hub tab; the section is not shown on a project tab
- `GET /api/coord/account-leases/health` → jobs worker `GET /api/account-leases/health`
- `/p/<project>` — where a lease's PROJECT cell links; `/machines` — where BOX links

**Selectors:**
- the section titled `ACCOUNT & TOKEN HEALTH`, `role=table` inside it
- `tr.cell--red` — a row the worker marked `expiring`; its EXPIRES cell also reads `EXPIRING`
- `role=button[name="<subject>"]` with `aria-expanded` in the ACCOUNT column — opens that account's live-lease table below the main one
- in the lease table, `role=link[name="<project>"]` → `/p/<project>`
- column headers are buttons titled `sort by …` with `aria-sort`; EXPIRES ascending is the default (soonest first, unknown last)

**States:**
- loading: a skeleton
- read failed with nothing on screen: `could not load — <reason>` with RETRY. Never the empty copy.
- read succeeded with zero rows: `no accounts reported`
- a refresh failed with rows on screen: a banner above the table, and the rows stay
- `list truncated — the worker capped this read; not every lease/token is shown` when any `truncated` flag is set

**Preconditions / seed needs:** rows come from the token-health reports and
account leases the BH-2516 siblings write. Until they land the worker route
is the contract stub, which answers zero accounts, so production shows
`no accounts reported` plus `Red = under 24 h to expiry (default)`.

**Verify it works:** with rows present, click an ACCOUNT → `aria-expanded`
flips to `true` and a lease table appears; click EXPIRES → `aria-sort` flips.
At 375 px the table scrolls inside its own box and the body does not scroll
sideways.

**Manual-only / not automatable:** nothing here writes, so every check is
safe on production.
