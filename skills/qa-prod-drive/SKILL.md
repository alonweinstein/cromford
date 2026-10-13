---
name: qa-prod-drive
description: Drive a deployed app as a real signed-in user — mint a Clerk session or one-time sign-in ticket for the project's QA account, lift and restore the ban on QA accounts that are banned at rest, get past Vercel Deployment Protection, drive screens headless with Playwright at 1280px and 375px, and report only what was actually observed. Use when asked to QA prod or a preview, verify a shipped feature as a user, reproduce a user-reported bug, or check a role's access.
---

# qa-prod-drive

Two ways into an app as a user, both backed by Clerk's backend API. No password is
ever typed, and no browser is ever driven by a human on this box.

- **Session JWT** (`bin/qa-session.sh`) — a bearer token for API calls. Fastest way
  to probe authz, read a route's real payload, or do incident ops.
- **Sign-in ticket** (`bin/qa-drive.mjs`, smoke-tested by `bin/qa-signin-check.mjs`)
  — a one-time `__clerk_ticket` that lands a *browser* in a real session. This is
  what "tested as a user" means. It satisfies instances that enforce MFA, because
  the trusted backend IS the factor.

Both are gated by one thing that used to be invisible: **the account's Clerk ban
state**. Read "Banned at rest" below before you drive anything privileged.

## The honesty rule — read this before you write any claim

**Never say "tested as a user" unless a browser really loaded the screens and you
really observed the outcome.** Build-proof is stated as exactly that: "typecheck and
`npm run build` green". If Playwright would not install, the sign-in never landed, or
you drove two of the five screens, the report says so **as the headline** — a pass
with nothing behind it is the one outcome that must never happen. Count what you
actually did (screens loaded, flows driven, shots written), never what the plan
listed or what you intended.

**A page that landed on `/sign-in` is a FAIL.** Not a skip, not a pass with a
caveat, not "the screen was behind auth". `bin/qa-drive.mjs` exits non-zero on it
and `bin/qa-signin-check.mjs` does too (it used to print `FAIL:` and exit 0, so
every caller that checked `$?` read a bounced sign-in as a working one — that is
the bug this skill was rewritten around on 2026-08-29).

## Guardrails

- **Previews share the PROD database.** Use obviously fake inputs, on
  non-destructive actions only. Never trigger deletes, payments, emails, or writes
  to real client records.
- **Mint short, mint often.** Default session TTL is 600s.
- **Privileged QA accounts are BANNED at rest** (`qa-owner`, `qa-admin`,
  `qa-administrator`). That is the rest state working, not a bug — see "Banned at
  rest" below for the ONE sanctioned way through it, and never reach for the Clerk
  dashboard instead.
- **A permission wall is an observation, not a defect.** Screens the QA role
  legitimately cannot reach get recorded as such.
- Secrets live in `/root/harness/env/<project>.env` (chmod 600). Read them with
  `set -a; . <file>; set +a` — never echo a value, never paste one into a report,
  a commit, a board comment or a log line.

## Accounts and env

`/root/harness/state/qa-accounts.json` maps `project -> role -> {email, user_id}`
(project-1 carries owner/admin/read_only/
user; other projects carry their own tiers). Per-project env
(`env-templates/project.env.example` documents all of these):

| var | what it unlocks |
|---|---|
| `QA_CLERK_SECRET_KEY` | minting sessions and sign-in tokens for that app's Clerk instance |
| `QA_TEST_USER_ID` | the default low-privilege QA user for browser drives |
| `QA_TEST_EMAIL` / `QA_TEST_PASSWORD` | the same user's credentials (rarely needed — the ticket flow beats them) |
| `VERCEL_AUTOMATION_BYPASS_SECRET` | getting past Deployment Protection on previews |

Any of them absent = that capability is off. QA the public surface and say the
authed screens were not covered. Do not invent a workaround.

## Banned at rest — the trap that made drives lie

Privileged QA accounts are **BANNED in Clerk** by our own design: project-3's
`qa-administrator` has been banned since 2026-08-16, project-1' `qa-owner` and
`qa-admin` the same. Keep it that way; a privileged account that is live in
production is a standing risk nobody is watching.

The trap is what Clerk does with a banned user:

> `POST /v1/sign_in_tokens` for a banned user **returns 200 and mints a real
> ticket.** The refusal happens later, in the browser, when the session is
> refused and the app redirects to `/sign-in`.

So a drive minted a ticket, "signed in", bounced, screenshotted the sign-in page
and reported coverage. Every authed observation in such a report was of a screen
nobody ever loaded. Two things fix it and both are already wired:

**1. Ask, don't assume.** `bin/qa-drive.mjs` reads the ban state *before* minting
and fails by name. By hand:

```bash
/root/harness/bin/qa-clerk-ban.sh <project> <user_...> status   # -> banned | active
```

An unreadable state is never "active" — it exits non-zero and prints nothing.

**2. Lift it for the drive, and always put it back.**

```bash
/root/harness/bin/qa-unbanned.sh <project> <role|user_...> -- <command…>
```

It reads the state, unbans only if the account was **observed** banned, runs your
command, and re-bans from an **EXIT trap** — on success, on failure, on a
non-zero exit, on SIGINT/SIGTERM. Three retries; if the re-ban still will not
land it writes an `ALERTS.log` line naming the account, fires a `fleet_alert`
beat and **exits 90 whatever your command returned**. A drive that passed while
leaving a privileged account unbanned is not a pass.

It restores the state it found rather than banning unconditionally, so wrapping
an account that is legitimately active at rest (project-4 `qa-harness`, project-1
`user`) is a no-op. **So wrap every drive** — an "unban only when I think I need
it" habit is a habit that will be wrong once, silently. `flock` per account makes
the window exclusive; a second drive waits, then declines with rc 75 rather than
driving inside someone else's window.

Minting a JWT and *then* re-banning is pointless: a ban revokes live sessions, so
the token dies with the window. The unban has to wrap the whole drive.

## 1. Session JWT — for API-level probes

```bash
/root/harness/bin/qa-session.sh <project> <role> [ttl-seconds]   # default TTL 600
```

It reads `QA_CLERK_SECRET_KEY` from `env/<project>.env`, resolves the role's
`user_id` through `bin/qa-account.sh` (the one lookup both this and
`qa-unbanned.sh` use), creates a session (`POST /v1/sessions`) and prints a JWT
(`POST /v1/sessions/<id>/tokens`). A banned account exits **3** with a message
naming `qa-unbanned.sh` — run it inside that wrapper's window and it mints
normally. Use the JWT as a bearer token:

```bash
JWT=$(/root/harness/bin/qa-session.sh project-1 user 900)
curl -s -H "Authorization: Bearer $JWT" https://<app-domain>/api/<route> | jq .
```

The role matrix probe: same route, every role, assert the status codes match the
app's intent. A `403` where you expected `200` is a finding; a `200` where you
expected `403` is a **security** finding — report it as one.

## 2. Browser drive — the real thing

**Smoke test first.** `bin/qa-signin-check.mjs` proves sign-in works at all
before you write a longer script:

```bash
set -a; . /root/harness/env/<project>.env; set +a
/root/harness/bin/qa-unbanned.sh <project> "$QA_TEST_USER_ID" -- \
  node /root/harness/bin/qa-signin-check.mjs https://<base-url> /root/repos/<project>/
```

Prints `LANDED:<url>` + `TITLE:` and **exits 0** on success; any `FAIL:` line
comes with a **non-zero exit**, so `$?` is a usable gate. Args: base URL, then the
root Playwright is resolved from (ESM imports ignore `NODE_PATH`, so it uses
`createRequire` against the project repo — pass the repo path, with or without a
trailing slash).

**Then drive.** `bin/qa-drive.mjs` is the reference implementation AND a usable
tool: it signs in, loads each path at 1280px and 375px, screenshots, and collects
the mechanical findings (console errors, failed requests, horizontal body scroll
at 375px, native dialogs).

```bash
/root/harness/bin/qa-unbanned.sh <project> <role> -- \
  node /root/harness/bin/qa-drive.mjs https://<base-url> /root/repos/<project>/ \
       /tmp/qa-out /clients /clients/abc123
```

It writes `/tmp/qa-out/observed.json` plus one PNG per screen per viewport, ends
on `QA COVERAGE: …` and `QA: PASS|FAIL`, and exits non-zero on FAIL. Import
`signIn()` from it rather than re-typing the sign-in flow in a one-off script —
two implementations of "are we really signed in" is how one of them comes to be
wrong quietly.

The flow any script of your own must copy:

1. **Bypass Deployment Protection in COOKIE mode** (previews only):
   navigate first to
   `<base>/?x-vercel-protection-bypass=$VERCEL_AUTOMATION_BYPASS_SECRET&x-vercel-set-bypass-cookie=true`,
   after which the cookie authenticates every request.
   **Never set the bypass as a global Playwright `extraHTTPHeaders`** — a global
   header rides along on third-party requests (Clerk's CDN) and breaks their CORS
   preflight. That lesson cost a full QA stage on 2026-07-28.
2. **Mint a one-time ticket:**
   `POST https://api.clerk.com/v1/sign_in_tokens` with
   `{"user_id": "$QA_TEST_USER_ID", "expires_in_seconds": 300}` and
   `Authorization: Bearer $QA_CLERK_SECRET_KEY`. Take `.token`.
3. **Land the session:** `goto(<base>/sign-in?__clerk_ticket=<token>)`, then
   `waitForURL(u => !u.pathname.startsWith('/sign-in'))`, then **re-read the
   landed URL** — `waitForURL` can be satisfied by a transient URL that redirects
   straight back. Ending on `/sign-in` or `/sign-up` is a **FAIL**: do not
   proceed, and never record it as covered. Check the ban state first (above) so
   the failure names its own cause.
4. **Drive:** headless chromium, each screen at **1280px and 375px**, exercise the
   primary flow, capture console errors and failed requests, screenshot every screen.
5. Prefer ARIA / `data-*` selectors, poll for an observable end state rather than
   sleeping, and `evaluate()` only to READ state.

If the repo has `docs/verification-map/`, it is the established record of how each
feature is reached and driven — take nav paths, routes, selectors and preconditions
from there instead of rediscovering them. An entry that no longer matches the app is
a finding to write down, not something to quietly work around.
Before you claim a pass on a screen, read that entry's **What usually lies:** field
and check each way it names that the screen can look right and not be. A repo with
no map can get a draft from `bin/feature-map-draft.sh <project>` in cromford:
an operator runs it, it opens a PR, and it never merges.

## 3. What to check on every screen you load

The UI iron laws, because a drive is the only thing that can see them:

- no horizontal body scroll at 375px (wide content scrolls inside its own container)
- data tables sort on header click, with a visible direction indicator
- every identity cell links to its detail view — no dead rows
- no native `confirm` / `alert` / `prompt` dialogs
- console errors and failed requests are findings, not noise

## 4. The automated lane — post-merge production QA

`bin/postmerge-qa.sh <project>` is this skill wired as a pipeline stage. Cron,
one build per tick, entirely after the merge so it can never block one:

1. **Deploy gate first** — production must be serving the merge sha (the
   project's `VERSION_URL` when it has one, else a successful GitHub production
   deployment). "Not deployed yet" requeues; nothing is ever driven against the
   previous build.
2. **`bin/qa-drive.mjs`**, through `qa-unbanned.sh`, on the screens named in the
   build's `plan.md` "## QA screens" (falling back to `/`, and saying so).
3. **The `prodqa` agent lane** for the flows and the judgement calls — skipped
   entirely when step 2 never landed a session, because an LLM cannot observe a
   screen the browser never reached.
4. **Attach**: `qa-prod.md` in the build dir, findings into `logs/findings.log`
   as `lens=prodqa`, and a comment on the merged PR. A FAIL also writes
   `ALERTS.log` and fires a `fleet_alert` beat.

Kill switches: `flags/postmerge-qa-disabled` or `POSTMERGE_QA_DISABLED=1`. To
drive one build by hand: `postmerge-qa.sh <project> /root/harness/builds/<dir>`.

## 5. Report

State the base URL, the account and role you drove as, and honest counts:

```
QA COVERAGE: screens=<n> flows=<n> shots=<n>
```

counting only screens really loaded, flows really driven, and screenshots really
written. Zero coverage is `screens=0` and a FAIL verdict — never a pass. Pre-existing
issues outside the ticket are noted separately, not failed. Then, plainly: what you
saw, what you could not reach and why, and which claims rest on build-proof rather
than a drive.
