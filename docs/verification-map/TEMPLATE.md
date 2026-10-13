# Verification map — the shape of a map, and of one entry

This directory in **cromford** holds the template. The map itself lives in
each **target repo** at `docs/verification-map/`, so the PR that changes a
feature changes its entry in the same diff. `guardrails/verification-map-freshness`
is what makes that mechanical rather than aspirational, and
`bin/verification-map.sh render <project>` is what puts the map in front of the
PLAN stage as `state/<project>-context.md`.

Why in-repo and not here: a map maintained centrally is a map nobody updates
while shipping. Colocation is the only version that survives contact with a
sprint — "without enforcement, the principle decays in months", and enforcement
needs the map inside the diff it belongs to.

## The directory

```
docs/verification-map/
  README.md          index: one row per feature + the driving conventions
  <feature>.md       one file per user-facing feature
```

`README.md` carries a table (feature → entry file → primary route) and a
`## Driving conventions` section. The renderer reads both by name: the index is
copied into the primer verbatim, the conventions section is extracted by its
heading. An entry file is any `*.md` that is not `README.md` or `TEMPLATE.md`.

## Driving conventions (the section every README must carry)

These are the conventions a QA session or an agent is expected to follow, and
they are stated in the repo so the repo can disagree with them on purpose:

- **Selectors:** prefer ARIA roles and names, then `data-testid` / stable
  `data-*` attributes. Never a CSS/Tailwind class chain — it changes on restyle
  and the failure looks like a broken feature.
- **Waiting:** poll an observable end-state (the row exists, the toast text
  appears, the request settled). Never a fixed `sleep`: it is slower when it
  works and lies when it does not.
- **`evaluate` reads, it never acts:** use it to read state the page already
  rendered. Calling a handler directly proves the handler runs, not that a user
  can reach it — which is the only thing QA was asked.
- **Entitlements are declared, not silently passed:** a screen the QA role
  cannot reach is recorded as not-covered with the role that would reach it.
  A permission wall is observed behavior, never a defect and never a pass.
- **Non-destructive only:** previews commonly share the production database.
  No deletes, payments, or sends — say so in the entry when a flow cannot be
  driven safely.

## One entry file

Copy the block below into `docs/verification-map/<feature>.md`. Keep it short:
this is a map, not a manual. Every line either helps someone reach the feature
or drive it, or it does not belong here.

```markdown
# <Feature name>

**What it is:** one or two sentences, in the language the client uses for it.

**How a user reaches it:** the real navigation path from sign-in
(e.g. sign in as <role> → sidebar → Clients → a client row → Documents).

**Key routes/screens:**
- `/route` — what this screen is for
- `/route/[id]` — dynamic; a real sample id lives in the preconditions below

**Selectors:**
- `role=table[name="Invoices"]` — the list
- `data-testid=invoice-row` — one row
(ARIA first, `data-*` second, class chains never.)

**Preconditions / seed needs:** what must exist before the flow works
(a seeded record, a role, a feature flag, an env var), and how to get it.

**Verify it works:** the observable end-state that proves the feature did its
job — the row that appears, the field that changes, the record that is written.

**What usually lies:** 1-3 bullets: the ways this feature looks right but isn't.
- a toast that fires before the write fails
- a list cached from before the change
- a badge reading a stale column
- a send that logs `not_configured` while the UI says sent

**Manual-only / not automatable:** the steps a script must not or cannot drive
(third-party redirects, payments, emails, anything destructive), stated plainly
so nobody reports them as gaps and nobody fakes them as passes.
```

## Personas (optional)

A repo whose QA lanes are wired also carries `qa/personas.json` and
`qa/apps.json`: who signs in, the flows each of them drives, and what nothing
may drive. The schema is written down once, in cromford at
`docs/E2E-POLICY.md` § Personas, and `bin/lib/qa-personas.sh` is the one reader
of both files.

When those files exist, their rendered half is `docs/verification-map/personas.md`
and it belongs in this directory next to the hand-written entries. Do not
hand-edit it. `bin/qa-personas.sh <project> --from <answers.json>` generates all
three from an answered questionnaire, and the `qa-personas` skill carries the
questions to ask. A page generated from the file the lanes actually read cannot
drift from them; a hand-kept second copy drifts inside a sprint.

## Keeping it honest

- An entry that no longer matches the app is worse than no entry: agents and QA
  sessions drive it as if it were true. Fix it in the PR that broke it.
- Do not write an entry for a feature you have not opened. A map assembled from
  reading route files describes the router, not the product.
- `bin/verification-map.sh render` copies what it finds and reports what it does
  not — it never fills a gap. An entry that is missing shows up as missing.
- `What usually lies` is the field a QA agent checks before it reports a pass.
