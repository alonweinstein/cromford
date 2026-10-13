# Hub-probe probe bodies (BH-3434.2, BH-3449)

**What it is:** the four probes `hp_run` (`bin/lib/hub-probes/common.sh`)
dispatches to. Each is one file under `bin/lib/hub-probes/`, sourced only when
`hp_run` gets a validated call for it. Every probe prints its output lines on
stdout, sets `HP_HTTP_STATUS`, and returns 0 for PASS and 1 for FAIL.

**How an operator reaches it:** no UI and no lane yet. Nothing on main calls
`hp_run` today; drive it by hand from a harness checkout.

## Preconditions

- `app-status-write` and `app-installation-repos` need a box that mints App
  installation tokens (`gh_auth_armed`: `env/github-app.env` readable,
  `bin/gh-token.sh` present, `GH_APP_TOKENS` not 0, the `gh-app-tokens-off`
  switch off). Without one they answer `FAIL app-token-unavailable` and make no
  GitHub call.
- `app-permissions` needs only `gh` auth (`GET /apps/<slug>` is public).
- `d1-count` needs the jobs client configured (`JOBS_URL`, `HARNESS_SECRET`).

## Driving it

```bash
bash -c '. bin/jobs-client.sh; . bin/lib/hub-probes/common.sh; hp_run app-permissions <app-slug>; echo rc=$? status=$HP_HTTP_STATUS'
bash -c '. bin/jobs-client.sh; . bin/lib/hub-probes/common.sh; hp_run app-installation-repos; echo rc=$?'
bash -c '. bin/jobs-client.sh; . bin/lib/hub-probes/common.sh; hp_run d1-count jobs all; echo rc=$?'
bash -c '. bin/jobs-client.sh; . bin/lib/hub-probes/common.sh; hp_run app-status-write <owner/repo> <40-hex sha>; echo rc=$?'
```

`app-status-write` WRITES: it leaves a `success` commit status with context
`hub-probe` on that sha. It never uses `lead-verdict`.

## The probes

| probe | args | calls | PASS prints | FAIL lines |
|---|---|---|---|---|
| `app-status-write` | `<owner/repo> <sha>` | `gh_app_only_for`, `POST repos/<repo>/statuses/<sha>` (App token), release, `GET repos/<repo>/commits/<sha>/statuses` (caller's identity) | `state=success`, `creator.type=Bot` from the newest `hub-probe` entry | `FAIL app-token-unavailable`; `HTTP <code>` + `FAIL unverifiable` (rc 75 on either call); `HTTP 404` + `FAIL post-rejected`; `HTTP 404` + `FAIL not-found` (read); `FAIL unparseable`; or the `state=`/`creator.type=` lines with anything but success/Bot (`none` when absent) |
| `app-permissions` | `<app-slug>` | `GET apps/<slug>` | one `key=value` line per permission (none for `{}`) | `HTTP 404` + `FAIL not-found`; `HTTP <code>` + `FAIL unverifiable`; `FAIL no-permissions` |
| `app-installation-repos` | none | `gh_app_only_for ${HARNESS_REPO}` when that is a slug, else `example-org/cromford`; `GET installation/repositories?per_page=100`; release | one `full_name` line per repo, `total_count=<n>`, and `incomplete: <listed> of <total>` when there are more than one page (still PASS) | `FAIL app-token-unavailable`; `HTTP 404` + `FAIL not-found`; `HTTP <code>` + `FAIL unverifiable`; `FAIL unparseable` |
| `d1-count` | `<table> <template>` | `hp_d1_count` → `GET /api/hub-probe/count` | `count=<n>` (`HP_HTTP_STATUS=200`) | `FAIL worker-unavailable` (`HP_HTTP_STATUS=000`) |

`bin/gh-token.sh` scopes the installation token to the one repo it mints for,
so `app-installation-repos` shows what GitHub returns for that token, not
necessarily every repo the installation covers.

## Tests

`tests/hub-probe-probes.bh-3449-test.sh` drives every row above through the real
`hp_run` and `bin/jobs-client.sh`, with `gh_rest`, the App-token helpers and
`_jobs_req` stubbed. `tests/hub-probe-contract.bh-3447-test.sh` keeps the
dispatcher's `not-implemented` path covered with a copy of `common.sh` that has
no probe file beside it.
