# Child-filer contract (`bin/lib/file-children.sh`)

**What it is:** one sourced library holding the entry point every child-filing
lane goes through, the two text templates a child issue body is made of, and the
fence-safe `## Rollout` detector. It is slice `.0` of #816 — the contract the
four sibling slices import.

**Who calls it.** `bin/run-decompose.sh` does, through `file_children`, since
BH-982 moved the issues-lane filing loop into `bin/lib/fc-issues.sh`
([fc-issues.md](fc-issues.md)) — that slice owns the byte-compare that keeps the
child bodies identical to the ones this script wrote inline. The remaining
slices (`fc_file_board` in `bin/lib/fc-board.sh`, `bin/run-rollout.sh`, the
`bin/run-build.sh` hook) are still to come; `file_children` answering **3** with
a `FILE_CHILDREN_UNIMPLEMENTED <lane>` log line is the seam that lets each of
them land on its own, in any order, and it is still what the board lane gets.

**How an operator reaches it** — no cron line, no executable, no lane. It is
sourced from a shell:

```sh
. bin/lib/file-children.sh
fc_child_title rollout AB-7 0 "schema"            # AB-7.1: schema
fc_child_footer rollout 900 2 4 "#901 (hard)" "" ""
printf '## Rollout\n' | fc_has_rollout && echo "armed"
printf '```\n## Rollout\n```\n' | fc_has_rollout || echo "fenced: correctly no"
fc_board_base widget-os                           # <API base><fleet.conf col 4>, or rc 1
file_children scoutish 552 TK-552 /tmp/b /tmp/b/children.json --kind rollout   # rc 3 today
```

**How to drive it:**

| what | how |
|---|---|
| the whole contract, on a scratch tree | `HARNESS_TEST_SANDBOX=1 bash tests/file-children.bh-981-test.sh` |
| the decompose footer against the REAL decomposer | the same suite, section A4 — it runs `bin/run-decompose.sh` under `DECOMPOSE_DRY_RUN=1` and `diff -u`s the child bodies it produces against `fc_child_footer` |
| the launcher still reads the `Blocked-by` line this writes | the same suite, section A4 — the produced line goes through the real `bin/unblocked-children.sh` |
| the decomposer is unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-issues-test.sh` and `tests/decompose-contract-first-test.sh`, both unedited |
| lint | `bash -n bin/lib/file-children.sh`, `shellcheck -S error bin/lib/file-children.sh` |

**What must never regress:**

- **The decompose footer is byte-identical to `bin/run-decompose.sh:400-412`.**
  Four scripts parse those exact lines: `bin/unblocked-children.sh` (`Blocked-by:
  #<n>`), `bin/lib/dep-verify-lib.sh` (the `(hard)` suffix),
  `bin/decompose-parent-close.sh` (`Part of #N` / `Order: n of N`) and
  `bin/size-gate.sh` (the size budget line). A one-byte drift is a child that
  launches into a conflict, so A4 fails on it.
- **Fences and code spans are stripped before anything else is read.** Issue
  #816's own body documents the `## Rollout` convention inside a ``` fence and
  writes `<h2>Rollout</h2>` in inline code; a detector that reads through either
  files issues nobody asked for, on somebody else's repo, under our App
  identity. That body is committed in the suite as the real-world negative.
- **The fourth code form has no marker, so the detector guards the indent.**
  `fc_strip_fences` is a state machine over ```` ``` ````, `~~~`, backticks,
  `<pre>` and `<code>`; an INDENTED code block carries none of those and reaches
  `fc_has_rollout` intact. Markdown allows a heading up to three leading spaces,
  so four spaces — or a tab anywhere in the leading run — is code and answers no.
- **An unterminated fence or span swallows the rest, except for a block
  marker.** A span runs to end of line and a fence to EOF, which is the right
  fail-closed rule for text and the wrong one for a `<pre`/`<code` OPEN tag:
  that tag is exactly what the END pass needs in order to hide everything after
  it. So an unclosed BACKTICK span re-emits the canonical marker (`<pre>` or
  `<code>`) for the first open tag in the remainder it drops — `` ` `` then
  `<pre>` then `## Rollout` answered YES and filed phantom waves before BH-1335.
  **Open tags only**: a dropped `</pre>` is never re-emitted, because a close
  marker is the one direction that could make the detector say yes more often.
  The rule is monotone — it can only hide more — and `bin/run-rollout.sh`'s
  `strip_backticks` carries the identical one.
- **A fence is a character AND a run length.** A run closes only on the same
  character at a length at least as long as the one that opened it, so the
  natural way to document the convention — a 3-backtick example wrapped in a
  4-backtick fence — does not reopen visibility inside the outer block and does
  not arm the lane.
- **A blockquote is a quoted spec, not a declaration, in both spellings.** The
  markdown `> ## Rollout` and the HTML `<blockquote><h2>Rollout</h2></blockquote>`
  (and `> <h2>Rollout</h2>`, the shape an in-app board stores) all answer no.
  The `>` line is dropped while its marker is still attached, because the tag
  pass moves `<h2>` onto a line of its own and would otherwise strand a quoted
  heading as a real one.
- **A trailing `\r` is removed first**, so a CRLF body reaches the fence,
  blockquote and indent guards — and the heading — as its author wrote it. No
  real body on the fleet carries one; this is insurance, not a seen shape.
- **`## Rollout ##` is a deliberate false negative.** CommonMark renders the
  closing sequence as a heading, but the detector's contract is that every
  uncertain shape answers no: a missed rollout master is planned as an ordinary
  ticket (today's behaviour, recoverable), where a false positive files N issues
  on a client repo with no plan stage. Pinned as a corpus negative so the
  decision is committed rather than an accident of the regex.
- **rc 3 is a feature, and it is never silent.** The log line is written before
  the return.
- **Sourcing is inert**: no `set -e`, no `exit`, no output, no file written at
  source time. A sourced `exit` kills the lane that sourced it.
- **`fc_board_base` reads no token and logs nothing**, and fails closed (rc 1,
  empty stdout) on the GitHub-Issues lane, an unknown project or a missing base.

**Preconditions / seed needs:** none. No network, no `gh`, no model call, no
GitHub API budget — the suite builds its own scratch `fleet.conf` and env files.

**Manual-only / not automatable:** nothing. cromford has no user-facing app
and this slice adds no lane to drive.
