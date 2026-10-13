# Served-sha auto-deploy (one Vercel production deploy of main HEAD)

**What it is:** a hook of the served-sha watch lane
([served-sha-watch.md](served-sha-watch.md)),
`bin/lib/served-sha-watch.d/20-autodeploy.sh` (`ssw_hook_autodeploy`, BH-4938).
When a project's prod is stuck behind main HEAD past `SERVED_SHA_LAG_MIN` and
Vercel has **no** production deployment for HEAD at all, it asks Vercel once for
a production deployment of main's full HEAD sha (`POST /v13/deployments`,
`gitSource {type: github, org, repo, ref: main, sha}`, the name of the
deployment prod serves now). Then it follows that request. It pages if prod
still doesn't serve the sha `SERVED_SHA_LAG_MIN` after the request, and it logs
(and resolves the page) when it does.

**Off by default.** Nothing is requested unless `SERVED_SHA_AUTODEPLOY` is
exactly `1`. Turning it on is the operator's call.

## How to reach it

- On: a `SERVED_SHA_AUTODEPLOY=1` settings row on the `served-sha-watch` lane,
  or `SERVED_SHA_AUTODEPLOY=1` in `env/global.env`. Any other value (`true`,
  `yes`, empty) is off.
- Off again: remove it or set it to `0`. That stops new requests only. A
  request already made is still followed up and confirmed, so a page it opened
  can still close.
- It runs inside the lane's tick: `/root/harness/bin/served-sha-watch.sh; tail -5 /root/harness/logs/served-sha-watch.log`.

## When it requests (all of them, checked in this order)

knob `1`; verdict `alert`; deployment state exactly `none` (never `building`,
`ready`, `failed` or `unread`); the state file is readable; no `.deploy` entry
for this full sha; `owner/repo`, the served deployment's name, the project id
and the team are all known. A missing one logs
`<project>: auto-deploy skipped (<field> unknown)`.

## What it writes on a live hub

- `state/served-sha-watch/<project>.json` key `.deploy {sha, at, rc, id?, alerted?}`.
  It is written as `rc: "pending"` **before** the POST (if that write fails:
  `auto-deploy ledger write failed, no request sent`, and no POST). Then the
  outcome: `requested` (2xx with an id), `requested-empty` (2xx, no id) or
  `failed:<http>` (`000` = no answer). The in-sync tick deletes the file, as
  the lane always did.
- `logs/served-sha-watch.log`: `<project>: auto-deploy of <sha8> requested`
  (or the rc), `<project>: auto-deploy of <sha8> confirmed: prod serves it`,
  `<project>: state file unreadable, auto-deploy skipped (fail closed)`.
- Alerts through `bin/lane-alert.sh`, id `served-autodeploy:<project>:<sha12>`,
  severity critical: `auto-deploy request failed (HTTP <code>) for <sha8>`, or
  `auto-deploy of <sha8> requested <N>m ago, prod still serves <sha8>`, at most
  one per sha. On confirm, `--resolve` on the same id when one was sent.
  Its alert state is `state/alerts/served-autodeploy_<project>_<sha12>.json`
  (lane-alert folds the colons in a filename).

## How to drive it in a test

`tests/served-sha-autodeploy.bh-4938-test.sh` copies the hook into the scratch
harness `tests/lib/served-sha-fixture.sh` builds and runs the real lane per tick
(`SERVED_SHA_NOW=$((NOW+k))`). `$T/fx/post.json` / `post.code` answer the POST,
`grep -c '^POST ' $T/req/argv.lines` counts requests, `$T/alerts.txt` records
every `lane-alert.sh` call.

## What usually lies

- `pending` means the request may or may not have reached Vercel. It is never
  retried; the follow-up page covers it after the lag. Same for `failed:000`.
- `ready` and `building` are never redeployed. `ready` with prod behind is a
  pinned domain (Instant Rollback / paused promotion), and a redeploy would not
  change what it serves.
- No alert after a request does not mean it worked before the lag passed: the
  follow-up only fires `SERVED_SHA_LAG_MIN` after the request.
