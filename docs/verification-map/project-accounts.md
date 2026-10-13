# Mission Control PROJECT ACCOUNTS (BH-1657)

**What it is:** a section on the hub tab of `/settings` listing every fleet
project and the Claude account it bills. A project with a label (e.g.
`own:project-3`) runs every claude call on that account's token and never on the
shared project-6/max accounts. "shared pool" means no pin.

**How a user reaches it:** sign in to Mission Control → nav → SETTINGS → the
HUB tab (the default) → scroll below HUB LANES to PROJECT ACCOUNTS.

**Key routes/screens:**
- `/settings` — hub tab; the section is not shown on a project tab
- `/settings?project=<project>` — where each project cell links

**Selectors:**
- `role=table` inside the section titled `PROJECT ACCOUNTS`
- `role=textbox[name="account label for <project>"]` — the label input
- `role=button[name="SET"]` — appears when the input differs from the stored label
- column headers are buttons titled `sort by …` with `aria-sort`

**Preconditions / seed needs:** the hub lane status must answer (it supplies
the fleet project list); `GET /api/settings` supplies the `account.*` rows. No
row = "shared pool".

**Verify it works:** type a label and press SET → the in-app confirm modal
reads "<project> will bill account <label>" (Escape cancels) → confirm → the
row shows the label and SET BY `console`. `shared` unpins ("goes back to the
shared pool"). A value starting `sk-`, containing `/` or `..`, shows an inline
refusal and SET is disabled; the worker also answers 400 for it.

**Manual-only / not automatable:** setting a label changes which account real
builds bill on every box within the 60 s settings cache. Do not drive SET on
production except to set the intended pin; read-only checks (sort, links,
refusal text) are safe.
