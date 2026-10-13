# Slice remainder filing (BH-5961)

## What it is

A plan can build one slice of an issue. It says `SLICE: C<k> of #N` and lists the other
slices as list items (`- C1: ...`, `- **C2**: ...`). When that slice merges and no open
child issue carries the rest, the close-out reads the remainder from the build record's
`plan.md` and files one child issue per slice. The filer is `fc_file_issues` with kind
`slice`. It titles each child `<KEY>.<j>: <title>`, writes `Part of #N`, `Order: n of M`
and any `Blocked-by:` the plan gave (`after C<i>`, `depends on C<i>`, `needs C<i>`). It posts
one parent comment that lists the children, and it takes `ai-build` off the parent.
`bin/decompose-parent-close.sh` closes the parent when every child has merged.

GitHub-Issues projects only. In-app board projects do not reach this path.

## Where it runs

- `issue_slice_settle` in `bin/lib/issue-state-lib.sh` (rb/pr.sh, batch-resolve.sh,
  hotfix-after-deploy.sh).
- `mc_close_shipped` in `bin/lib/mc/classify.sh` (the merge conductor).

Both call `slice_remainder_settle` only for the guard word `slice:plan` with zero open
children. `slice:no-keyword` keeps the old comment and warn alert.

## The four answers

| rc | word | close-out word | what happened |
|----|------|----------------|---------------|
| 0 | `remainder-filed:#a,#b` | `kept-slice:remainder-filed:#a,#b` | children filed (now or before), parent commented and unlabelled |
| 1 | `remainder-deferred:<why>` | `close-deferred:remainder` | lock held, parent read failed, or a create failed; the next tick retries |
| 2 | `remainder-unknown:<why>` | `kept-slice:no-children+label-kept` | the plan names no remainder; one critical `SLICE_REMAINDER_UNKNOWN` page, the no-children comment, no warn alert |
| 3 | `remainder-skip:<why>` | `kept-slice:no-children+label-kept` | switched off, no record or plan, parent closed, no filer, no key, or dry run; the old path with its warn alert |

## Record files

All under `<record>/slice-remainder/`:

- `children.json`: the spec, parsed once per record. A plan edited later never files a second set.
- `children.txt`: the filer's append-only ledger. A crashed run resumes from it.
- `filed`: `#a,#b`, written only when every child is filed. Read first on every call.
- `unknown-paged`: the reason of the one page. The record stays unknown after it.
- `fc-error.txt`, `fc-out.txt`, `parse.log`, `pipeline.log`, `decompose-gh.log`: evidence.
- `.lock`: `flock -n` dedupe for two lanes on one record. Never a wait.

## How to drive it from a shell

```bash
HARNESS=/root/harness bash -c '
  . /root/harness/bin/lib/issue-state-lib.sh
  slice_remainder_parse <record>/plan.md <N> /tmp/children.json https://github.com/<o>/<r>/pull/<pr>
  jq . /tmp/children.json'
```

`slice_remainder_parse` writes nothing on GitHub. It answers `ok:<m>`, `none` or `bad:<why>`
(`no-slice-line`, `duplicate:C<j>`, `gap:C<j>`, `too-many:<m>`, `empty:C<j>`).

Set `FILE_CHILDREN_DRY_RUN=1` on a close-out to log the filer's commands with no write.

## How to switch it off

- the settings row `switch.slice-remainder-off` (or `switch.slice-remainder-off.<box>`),
  read through `lane_switch` (`catalog/switches.d/slice-remainder-off.json`), or with no
  row, `touch $HARNESS/flags/slice-remainder-off`, or
- `SLICE_REMAINDER_FILE=0` in the environment or `env/global.env`.

Either one restores the old no-children comment and warn alert. `SLICE_REMAINDER_MAX`
(default 6) caps the number of children; a plan with more pages `bad:too-many:<m>`.

## Verified by

`tests/slice-remainder.bh-5961-test.sh`.
