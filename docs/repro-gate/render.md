# Pre-build repro gate: the two renderers (BH-2042)

`bin/lib/prebuild-repro/render.sh` turns the gate's build record into text. It
replaces the render stubs from the contract, so the render row in
[../repro-gate.md](../repro-gate.md) ("nothing") is superseded by this page.
Both functions read two files in the build dir and print to stdout only:

- `prebuild-repro.txt`, the record `pr_record` writes (`REPRO_GATE:`, `REPRO_REASON:`, `REPRO_EVIDENCE:`).
- `prebuild-repro.md`, the drive detail (`REPRO_ROLE:`, `REPRO_URL:`, `REPRO_STEPS:`, `REPRO_OBSERVED:`).
  A `REPRO_<X>:` line starts a field and the lines after it continue it, so
  steps can span lines. CRs are dropped. Unknown keys are ignored.

A missing record, an unreadable one, or one whose `REPRO_GATE:` is not one of
the six known words prints nothing from either function.

## `pr_brief_line <build>`

Called by `bin/run-build.sh` `# >>> prebuild repro (BH-2004)`; the result is
`$REPRO_BRIEF_LINE` in the plan prompt. Only a `reproduced` record with a
non-empty detail file prints:

```
 THIS BUG WAS REPRODUCED ON PROD BEFORE THE BUILD. Use these steps and this observed result as the fix's acceptance check and put them in the plan's ## Reproduction: <prebuild-repro.md folded>
```

The whole detail file is folded to one line (newlines, CRs and tabs become
spaces) and capped at 2000 characters, ` [truncated]` included when it is cut.
Every other gate, and a `reproduced` record with no detail file, prints nothing:
"use these steps" with no steps would be false.

## `pr_pr_section <build>`

Called by `bin/run-build.sh` `# >>> repro section`; the result is
`$REPRO_SECTION`, which `PR_BODY_FOR` appends after the pre-PR section. The
same function runs at PR create and at the tier-settle body edit, on the same
files, so both renders match. Output starts with a blank line.

| record | PR body gets |
|---|---|
| `reproduced` | `## Reproduced on prod before build`, then `URL:` with the URL in an inline code span (capped at 500 characters, ` [truncated]` after the span when cut), `Steps:` and `Observed:` each in a code fence |
| `reproduced`, detail file missing or empty | the heading and `The drive recorded a reproduction but its detail file (prebuild-repro.md) is missing, so no steps are shown.` |
| `cannot-drive`, `not-reproduced`, `already-fixed`, `stop` | `Not reproduced before build: <reason>.` |
| `skip` with a marker or cause-proven reason | `Reproduction skipped: <reason>.` |
| `skip not-bug`, `skip knob-off` | nothing |
| no record, unknown gate | nothing (the body is byte-identical to a build without the gate) |

`skip not-bug` and `skip knob-off` stay silent because the gate never looked at
those tickets. Every feature build records `skip not-bug`, and a line about it
on every feature PR would say nothing.

A `stop` record only reaches a PR body on a resumed build (the record exists,
so the runner does not run again). It is still true: the drive said not
reproduced or already fixed.

The reason is `REPRO_REASON` with one trailing `.` dropped; `-` or empty reads
`no reason recorded`. A missing URL reads `URL: not recorded`, and a missing
steps or observed field reads `not recorded` inside its fence. Nothing is
invented.

### The fence rule

Steps and observed text come from prod, so they sit in a code fence made of one
more backtick than the longest backtick run in the text, at least three. Text
holding a fence, a `## ` heading or `Closes #12` stays inside the block: it can
not end the fence early, open a heading in the PR body, or read as a closing
keyword. Each field is capped at 2000 characters, with ` [truncated]` appended
when cut.

The URL is free text from the drive too, so it gets the same treatment on one
line (BH-2123): an inline code span one backtick longer than its longest
backtick run, with a space inside each delimiter, like
``URL: ` https://app.example.test/x ` ``. A URL holding `fixes #12` or an
`@mention` renders as code, so it can not close an issue or ping anyone in the
client repo, and a backtick at either end can not close the span. It is capped
at 500 characters, with ` [truncated]` after the span when cut. A missing URL
stays the plain `URL: not recorded`.

Tests: `tests/prebuild-repro-render.bh-2042-test.sh` (the run-build blocks are
lifted verbatim from the flattened pipeline and run against the real library)
and `tests/prebuild-repro-url.bh-2123-test.sh` (the URL span and cap).
