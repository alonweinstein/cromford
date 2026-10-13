# Pre-build repro gate: the thread fetch and the skip marker

`pr_fetch_thread` (`bin/lib/prebuild-repro/thread.sh`) and `pr_skip_classify` (`bin/lib/prebuild-repro/classify.sh`),
BH-2040, order 2 of #2004. `bin/prebuild-repro.sh` calls them at steps 3 and 4. The contract is in
[../repro-gate.md](../repro-gate.md).

A principal can skip the gate for one ticket by writing a line that starts with `[no-repro]`, `[no-repro: <text>]`
or `[no-repro: cause-proven — <evidence>]`. The same line from a client is ignored.

## `pr_fetch_thread <project> <ticket-id> <key>`

The board comes from `bin/fleet-conf.sh <project> board_prefix`, the same resolution `stop.sh` uses.

| rc | meaning | the runner records |
|---|---|---|
| 0 | the normalized JSON below on stdout | goes on to classify |
| 1 | the board exists and could not be read: a gh read that is not rc 0 (a 404, a 5xx, a rate limit), a failed read of the newest page, curl failing, no internal token, a body that is not an object, an in-app answer with no comments array (`{"error":…}`), bad JSON. Nothing is printed. | `cannot-drive thread-unreadable` |
| 3 | not wired: no `bin/fleet-conf.sh`, no row for the project, no repo or issue number (GitHub), no prod URL (in-app) | `cannot-drive fetch-not-wired` |

A failed read is never an empty thread and never a skip.

```json
{"source":"app|gh","truncated":false,"body":"…","body_principal":false,
 "comments":[{"id":"…","createdAt":"…","body":"…","author":"…","principal":false,"harness":false}]}
```

`body` and a comment `body` are `""` when the board gives null. `id` is always a string.

### GitHub (`board_prefix` is `-`)

- The number is `<ticket-id>` when it is numeric, otherwise the digits of `<KEY>`.
- `gh_rest GET repos/<repo>/issues/<n>`, then `…/comments -F per_page=100`.
- The issue's `comments` count over 100 sets `truncated: true`, and the page holding the newest comment is read
  as well and merged by id. `pr_ledger_key` keys on the newest comment, so page 1 alone would freeze the key on a
  long thread. An issue with no count and a full first page is also `truncated`.
- `principal`: `author_association` is OWNER, MEMBER or COLLABORATOR, or `user.type` is `Bot`. CONTRIBUTOR and
  NONE are not. `body_principal` is the same rule on the issue.
  On a repo where the operator is a CONTRIBUTOR (cromford, project-5), his `[no-repro]` is therefore not read: the
  gate drives once, capped, rather than skip. Making him principal there is a follow-up, not this rule.
- `harness`: the author is one of the harness Apps (`HARNESS_SELF_APPS`, `hs_ours` in `bin/lib/harness-self.sh`),
  or the body carries `<!-- harness:repro-stop` AND the login is one of `harness_pr_spellings`
  (`bin/lib/gh-pr-list.sh`: the Apps and the PAT login). A client quoting the stop comment stays `false`.
- `source: "gh"`, `author` is `user.login`, `createdAt` is `created_at`.

### In-app (any other prefix)

- `curl -s --max-time 25 -H "Authorization: Bearer <internal token>" "$PROD$PREFIX/tickets/<ticket-id>"`, with
  the token from `bin/internal-token-for.sh`.
- Comments are `.comments`, `.ticket.comments` or `.data.comments`. An empty array is fine.
- `principal`: `isInternal == true`, or the author name or userId is this board's system actor (`_prt_self_actor`,
  a copy of the SELF_ACTORS names in `bin/triage-gate.sh`).
- `harness`: `principal` AND the body carries `<!-- harness:repro-stop`. The harness posts with the internal token,
  but so does a person on the team, and their comment (new repro steps, say) must move `pr_ledger_key`. A client
  cannot post an internal comment, so a client quoting the stop comment stays `false`.
- `body_principal`: the reporter's userId (`reporter.userId` or `reporterId`) is `system`, or
  `reporter.isInternal == true`. `body` is the ticket's `description` (or `body`).
- `truncated`: more than 100 comments. `source: "app"`, `author` is `author.name`.

## `pr_skip_classify <thread-json>`

Pure jq. The texts it reads, in order: each `principal: true` comment, newest first by `createdAt` then `id`,
then the body when `body_principal` is true. A client comment, whenever it came, is never read, so a later client
comment does not supersede a principal's marker. The first hit wins.

In each text, line by line:

- A line starting (after whitespace) with three backticks opens or closes a fence. Lines inside a fence are
  skipped, and so is everything after a fence that never closes.
- A line starting with `>` is skipped.
- A line starting with `[no-repro]` is a hit with no text.
- A line starting with `[no-repro:` and holding a later `]` is a hit. The text runs from after the colon (leading
  space dropped) to the last `]` on the line.
- `no-repro` is case-insensitive (`[No-Repro]` counts). Nothing else is.

These never match: `` writes `[no-repro]` `` (inline backticks, the line does not start with the marker),
`see [no-repro] above`, `> [no-repro]`, a fenced `[no-repro]`, `[no-reproduce]`, `[norepro]`, `[no-repro: never
closed` and `cause-proven — …` in prose.

| hit | output |
|---|---|
| text starting `cause-proven` (case-sensitive) | `skip\tcause-proven\t<evidence>`: the rest, leading spaces, dashes and colons dropped, at most 300 chars, `-` when empty |
| any other text | `skip\tmarker\t<text>`, `-` for a bare `[no-repro]` |
| no hit, `truncated: true` | `run\tthread-truncated\t-` |
| no hit | `run\t-\t-` (also for bad JSON, empty input or a non-object) |

Tabs and newlines in the evidence become spaces, so the runner's `IFS=$'\t' read` sees three fields.

## Doctrine

`rules/topics/02-board-triage.md`: write `[no-repro: cause-proven — <quote the evidence>]` when the ticket already
carries hard evidence of the cause. A client's `[no-repro]` is ignored.

Tests: `tests/prebuild-repro-skip.bh-2040-test.sh`.
