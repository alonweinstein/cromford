---
name: qa-personas
description: Write or refresh a project's QA personas — draft the answers from the code (role guards, route tree, nav per role) or ask the people who know the product, turn them into qa/personas.json, qa/apps.json and the verification-map entry with bin/qa-personas.sh, and open the PR the orchestrator reads before it merges. Use when a repo has no personas yet, when a new role or flow appears, or when a persona's flows have gone stale.
---

# QA personas

A QA persona is "sign in as this kind of user, then click through these flows".
The QA lanes read them from two files in the project repo — `qa/personas.json`
and `qa/apps.json` — and `bin/lib/qa-personas.sh` is the one reader of both.
This skill is how those files get written.

**An agent may draft the answers from the code** (the operator, 2026-10-07). Read the
role guards, the route tree and the nav each role sees, and write the answers
file from that. A person may still answer it instead. Either way the PR opens,
and the orchestrator (merge grant) reads the rendered map instead of a human
filling in a questionnaire.

Every flow in these files is something an automated lane will later click
through against a real environment, so a wrong route or a write flow marked
safe is a real action with real consequences. That is why the safety floor is
mechanical, not a reader:

- Anything that creates, pays, sends or deletes is `production_safe: false`
  with a `cleanup`. The validator refuses a write flow with no cleanup, and
  production never runs one.
- Every persona's `out_of_bounds` is a non-empty list. The validator refuses a
  persona without one. List at least these, wherever the app has them:
  refunds; charges, payouts and anything Stripe; mark-paid; every SMS,
  iMessage, email or Telegram send or resend button; signing; deletes;
  invites; role changes; imports; integration connect and disconnect.
- Never click refunds for real customer payments. Send messages only to test
  customers.

Order the personas least privileged first. The QA lanes drive one persona per
changed app area and take the first owner in file order, so the order is the
privilege ranking.

## The questionnaire

Ask these, in this order, of whoever knows the product. Write the answers down
as one JSON file.

1. Who are the personas? One per kind of user who can sign in. Give each a
   short id (lowercase letters, digits and dashes) and the role name its QA
   account uses.
2. How does each one sign in? v1 has one answer: clerk-ticket.
3. Which apps does each one own? The names from the apps map below, so a diff
   that only touches one app drives only the personas that own it.
4. What are the top 3-5 flows for each persona? Per flow: an id, a title, the
   route it starts at, the observable that proves it worked, and the clicks in
   between.
5. Which of those flows WRITE something? A write flow is production_safe:
   false, runs against preview only, and must say how to clean up after itself.
6. What must never be driven? The routes and actions that are out of bounds for
   that persona. At least one is required.

Three to five flows per persona is the right size. The question to ask about
each one is "would I notice if this broke?" — if the answer is no, it does not
belong in a lane that runs on every build.

## The answers file

One file, one shape: the personas document plus a top-level `apps` map. There
is no translation layer — the generator splits this file, it does not rewrite
it.

```json
{
  "version": 1,
  "apps": { "admin": ["apps/admin/**"], "web": ["apps/web/**", "src/**"] },
  "personas": [
    { "id": "owner", "role": "qa-owner", "sign_in": "clerk-ticket",
      "apps": ["web"], "out_of_bounds": ["/billing"],
      "flows": [
        { "id": "dashboard", "title": "See the dashboard", "route": "/dashboard",
          "observable": "the scans table renders", "production_safe": true,
          "steps": [ {"goto": "/dashboard"},
                     {"expect": {"selector": "role=table"}} ] },
        { "id": "new-scan", "title": "Start a scan", "route": "/scans/new",
          "observable": "a queued scan row appears", "production_safe": false,
          "cleanup": "delete the queued scan named qa-smoke",
          "steps": [ {"goto": "/scans/new"},
                     {"fill": {"selector": "input[name=name]", "value": "qa-smoke"}},
                     {"click": "button:has-text(\"Start scan\")"},
                     {"expect": {"selector": "role=row", "text": "qa-smoke"}} ] } ] } ]
}
```

Every rule of that shape is written down once, in `docs/E2E-POLICY.md`
§ Personas, and validated once, by `qa_personas_validate`. Read the policy for
the details; the ones that trip people up:

- `id` is `^[a-z0-9-]+$` and unique. A flow id is unique within its persona.
- `sign_in` is exactly `"clerk-ticket"`. v1 has one sign-in kind.
- `route` starts with `/`. An absolute `https://…` is refused.
- `production_safe` is a JSON boolean. `"true"`, `1` and a missing key are all
  refused, and none of them defaults.
- Every name in a persona's `apps` must be a key of the top-level `apps` map.
- `out_of_bounds` is required and non-empty, and every entry is a non-empty
  string.
- A flow may carry its own `apps`: a non-empty list of names from its
  persona's `apps`. When a persona is driven for one changed area, its flows
  tagged only with other areas are left out of that run. A flow with no
  `apps` is always driven.
- `seed` is optional, and it is documentation: the generator renders it in the
  flows table and nothing validates or executes it.

## The production_safe rule

`production_safe: false` means the flow writes. Two things follow, and the
validator enforces the first:

- **It must carry a `cleanup`** — a non-empty sentence saying how to undo what
  it did. A write flow without one is refused.
- **It is preview-only.** The production lane keeps a write flow's metadata,
  drops its steps and marks it `skipped`. Nothing marked `production_safe:
  false` is ever driven against production.

So the honest default for anything that creates, pays, sends or deletes is
`false`. Marking a write flow `true` to get it running is how a QA lane starts
writing rows into a client's live database.

## Generate the files

```sh
bin/qa-personas.sh <project> --from <answers.json> [--repo <dir>] [--dry-run]
bin/qa-personas.sh <project> --interactive
```

`--interactive` prints this questionnaire and the answers-file shape and exits;
it does not prompt, because the boxes are headless. `--dry-run` prints the three
rendered files and touches nothing. A real run refuses a dirty work tree,
validates the answers, then branches `qa/personas-<YYYYMMDD>` from the
checkout's local `main`, commits the three files, pushes, opens a PR against
`main`, and prints the PR URL. It puts the checkout back on the branch it found
it on, so the PR carries the three files and nothing the checkout was already
sitting on.

It writes exactly three files into the project repo:

| file | what |
|---|---|
| `qa/personas.json` | the answers minus the app map — what the lanes read |
| `qa/apps.json` | `{version: 1, apps: …}` — which paths belong to which app |
| `docs/verification-map/personas.md` | the same content, in the shape a person reads |

A defect in the answers is one line on stderr from `qa_personas_validate` and
nothing written at all — no branch, no files, no PR. Fix the answers and run it
again. The two failures that can land after the commit — the push failing, or
`gh pr create` failing — are also one line and rc 1, but they do leave the local
`qa/personas-<YYYYMMDD>` branch and its commit in the checkout; the line says so,
and the branch has to go before you re-run that day.

## The confirmation rule

The generator opens the PR; it never merges it. The orchestrator reads
`docs/verification-map/personas.md` in the PR before the merge and checks
three things:

1. Every route is a route that exists, and it is the route the flow starts at.
2. Every flow that writes says `no` in the production safe column and carries a
   cleanup that would actually undo it.
3. The out-of-bounds list names everything that would be expensive, loud or
   irreversible if a lane clicked it — billing, sends, deletes, anything that
   touches a third party.

To change something, edit the answers file and re-run the generator. Hand-edit
the JSON and the page and they drift apart inside a sprint.
