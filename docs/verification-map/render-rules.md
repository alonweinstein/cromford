# Rules render (rules/topics → rules/CLAUDE.md)

**What it is:** `bin/render-rules.sh`, the renderer that turns
`rules/topics/NN-<topic>.md` into the committed `rules/CLAUDE.md` with a
generated `## Contents` list. `rules/topics/00-intro.md` is the preamble,
verbatim; every other topic is one `## ` section, verbatim; the TOC is the only
text the renderer invents. It sources `bin/lib/render-fragments.sh` for fragment
listing, CR refusal, the atomic write and the drift compare, so its exit codes
are the contract's: 0 rendered / no drift, 1 drift, 2 cannot render (and any
render failure under `--check` maps to 2, never 0), 3 a topic refused.

**The shipping path did not change.** `bin/update-runners.sh`,
`bin/sync-agent-rules.sh`, `fly/builder-runner.sh`, `bin/rules-drift-check.sh`
and `bin/context-signature.sh` all still read the rendered `rules/CLAUDE.md` at
its old path, and `bin/fleet-propagate.sh` still matches `rules/`. Boxes never
see `rules/topics/` — only the rendered file lands in `/root/.claude/CLAUDE.md`.

**How an operator reaches it:** it is a script, not a lane. From a checkout:

```sh
bin/render-rules.sh                  # print the rules file the topics describe
bin/render-rules.sh --check          # rc 0 clean, rc 1 DRIFT + first 25 diff lines
bin/render-rules.sh --write          # render and move it onto rules/CLAUDE.md
bin/render-rules.sh --root /some/checkout --check
bin/render-rules.sh -h               # the header, including the exit codes
```

**Editing a rule:** change the topic file, run `--write`, commit both. A topic
edit committed without the render is drift; section B6 of the suite catches it
(`bin/render-rules.sh --check` rc 1), and B6 also asserts `rules/topics/` is
present in the checkout so `bin/test-impact.sh`'s text-based CI-select maps a
topic-only diff to this suite, not only a diff that also touches
`rules/CLAUDE.md` or the renderer. Since BH-1336 the belt is beside it: CI's
`lane renders generate and their sources validate` step runs
`bin/render-rules.sh --check` directly, so the drift is red whatever the test
selection picked. That line is a CHECK and never a `--write` — this is the one
render in that step which IS committed, and writing it first would erase the
drift the step exists to catch.

**How to drive it:**

| what | how |
|---|---|
| the whole renderer against scratch topic trees, plus this checkout | `HARNESS_TEST_SANDBOX=1 bash tests/render-rules-test.sh` |
| the golden render, the TOC anchors, `--write` idempotence | sections B1–B3 of that suite |
| the refusals: no `## ` first line, duplicate heading, CRLF, empty topics dir, bad flags | section B4 |
| drift and a missing committed file | section B5 |
| this checkout's own `rules/CLAUDE.md` is the render of its topics | section B6 |
| the `rf_registry` row is a command that works, run verbatim | section B7 |
| the CI belt and the regenerate row, on real git | `HARNESS_TEST_SANDBOX=1 bash tests/render-rules-guards.bh-1336-test.sh` |
| the CI step really carries the check, and never a write | `awk '/name: lane renders generate and their sources validate/,/render-diff.sh/' .github/workflows/harness-ci.yml` |
| the regenerate row, as the train reads it | `bash -c 'eval "$(sed -n "/^regen_table()/,/^}/p" bin/batch-resolve.sh)"; show_base(){ git show "origin/main:$1" 2>/dev/null; }; regen_table' \| grep rules/` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/render-rules-test.sh` |
| the contract it sources | `bash tests/render-fragments-test.sh` |

**Files it names:**

- `rules/topics/*.md` — the inputs. First file in `LC_ALL=C` order is the
  preamble; every other one must begin with a `## ` heading, and no two may
  carry the same heading text.
- `rules/CLAUDE.md` — the only file it writes, and only under `--write`.
