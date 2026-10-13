# Operator settings (the knob store)

**What it is:** one D1 row per number an operator may need to change without a
deploy — the first of them is `gh_budget_min_remaining`, the GitHub rate-limit
floor. The table stores every value as TEXT and each consumer parses what it
needs; the API's whole job is to refuse a key or a value that would read as
something else later.

**How a user reaches it:** there is **no UI route** — no console screen renders
or edits a knob. Every path to the datum, enumerated: the console's Pages proxy
(`console-ui/functions/api/coord/[[path]].js`) is a GENERIC pass-through, so a
signed-in console session can READ `GET /api/coord/settings`; it names no path
allowlist, and `settings` appears nowhere in it. Writes are bearer-only: that
file allows `PUT` for `flags` and nothing else, and every other verb is a 405.
So the only way to change a knob is from a box, two ways:

- `bin/jobs-client.sh setting-get gh_budget_min_remaining` → prints the value
- `bin/jobs-client.sh setting-set gh_budget_min_remaining 900 "why"` → writes it
- or directly:
  `curl -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings"`

**Key routes/screens:**
- `GET /api/settings` — every knob, `ORDER BY key`
- `GET /api/settings/<key>` — one knob. Answers `200 {setting:null}` when the
  row is absent, never a `404`: "no row, use your documented fallback" is a real
  answer, and the client's `404` branch means something else (a ledger miss).
  A key outside `^[a-z0-9_.-]{1,64}$`, or a torn percent-escape, is a `400`.
- `PUT /api/settings` — `{key,value,note?,actor?}`, upserts on `key`. A JSON
  number is stringified; `null`, a boolean, an object, `""`, whitespace-only,
  and anything over 256 chars are refused, never coerced. An omitted `note`
  keeps the previous one (`COALESCE`); `actor` is always overwritten.

**Selectors:** not applicable — no rendered screen. The observable surfaces are
the three rcs of `setting_get`: `0` = here is the value (on stdout), `2` = no
row, `1` = the worker did not answer. `1` and `2` both send a consumer to its
documented fallback; only `0` carries a number.

**Preconditions / seed needs:** `worker/jobs/schema.sql` applied to the
`harness-jobs` D1 database (`npx wrangler d1 execute harness-jobs --remote
--file=./schema.sql` from `worker/jobs`) and the worker deployed. The seed row
`gh_budget_min_remaining=800` arrives with the schema, via `INSERT OR IGNORE`,
so re-applying the file never resets a threshold an operator raised. No new env
var; `HARNESS_SECRET` and `JOBS_URL` are the ones every box already holds.

**Verify it works:** on any box, `bin/jobs-client.sh setting-get
gh_budget_min_remaining` prints `800` and exits 0. Then `setting-set
gh_budget_min_remaining 900 "test"`, `setting-get` prints `900`, and
`setting-set gh_budget_min_remaining 800` puts it back.

**Manual-only / not automatable:** the schema apply and the worker deploy are
human steps (a box does not write the production D1 schema). The knob is shared
fleet state, so a value left changed changes fleet behaviour for everybody —
set it back after driving it.

## Keyed rows

Some knobs are one row per subject, the subject in the key. No seed row: an
absent row is the documented default.

| key | values | absent means | entry |
|---|---|---|---|
| `tracker_adapter.<project>` | `github-issues` \| `board` \| `jira` \| `linear` | fleet.conf column 4 (`-` = `github-issues`, a prefix = `board`; never `jira` or `linear`); any other value is refused and the child filer files nothing | [tracker-adapter.md](tracker-adapter.md) |
| `tracker_jira.<project>.write_projects` | space-separated Jira project keys every verb may touch | no Jira writes at all | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.comment_projects` | keys where only `comment`/`link_pr` may write | none | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.read_projects` | keys `list`/`read` may touch (on top of the write and comment keys) | only the write and comment keys | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.label` | the build label the Jira list filters on | `ai-build` | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.waiting_on_field` | `customfield_<n>` | waitingOn null | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.triage_verdict_field` | `customfield_<n>` | triageVerdict null | [tracker-jira.md](tracker-jira.md) |
| `tracker_jira.<project>.status_map` | `alias=Jira Status;alias=Jira Status` | status arguments are Jira status names | [tracker-jira.md](tracker-jira.md) |

## Box-local knobs that are NOT in this store

Some switches have to be readable before a box can reach the network, or before
`bin/run-build.sh` has sourced anything. Those live in `env/global.env` with a
`flags/` kill file beside them, are READ rather than sourced, and are listed here
so an operator has one place to look.

| knob | default | what the off-state does | entry |
|---|---|---|---|
| `SKIP_CLOSED` / `flags/skip-closed-off` | on | `bin/run-build.sh` stops reading the issue's state and enqueues exactly as it did before BH-637 | [closed-issue-hygiene.md](closed-issue-hygiene.md) |
| `CLOSE_STRIP_AI_BUILD` / `flags/close-strip-ai-build-off` | on | the four merge paths still comment and close, and leave `ai-build` on the issue | [closed-issue-hygiene.md](closed-issue-hygiene.md) |
| `DECOMPOSE_INHERIT_LABELS` | empty | a comma list ADDED to the inherited vocabulary (`ai-build` + `HOTFIX_LABEL`); empty means only those two are copied to a split child | [closed-issue-hygiene.md](closed-issue-hygiene.md) |

`SKIP_CLOSED` in particular cannot be a D1 row: it is read at the top of
`bin/run-build.sh`, hundreds of lines before that script sources `env/global.env`
and long before any worker call would be appropriate.
