# QA personas generator (`bin/qa-personas.sh`)

**What it is:** the operator lane that turns an answered questionnaire into a
project repo's QA personas. It splits one answers file into `qa/personas.json`
and `qa/apps.json`, renders `docs/verification-map/personas.md` from the same
two documents, commits all three on a branch in that repo, and opens a PR. The
questions live in the `qa-personas` skill; the schema lives in
`docs/E2E-POLICY.md` § Personas and is validated by `bin/lib/qa-personas.sh`,
which this script sources rather than re-implements.

**The script calls no model; the answers may come from one.** Since BH-5204
an agent may draft the answers file from the code (role guards, route tree,
nav per role), or a person may answer the questions. The PR still opens, and
the orchestrator reads the rendered map before it merges. Every flow in these
files is something an automated lane will later click through against a real
environment, so the floor is mechanical: the validator refuses a persona with
an empty `out_of_bounds` list and a write flow with no `cleanup`, and the
production lane never runs a `production_safe: false` flow.

**How an operator reaches it.** There is no cron lane and no board trigger — it
is invoked by hand, from a box with a checkout of the project repo:

```sh
# the questions and the answers-file shape (prints and exits 2; no stdin loop)
bin/qa-personas.sh project-5 --interactive

# what would be written, without touching the repo or running one git command
bin/qa-personas.sh project-5 --from /tmp/answers.json --repo /root/repos/project-5 --dry-run

# the real run: branch, commit, push, PR. Prints the PR URL and nothing else.
bin/qa-personas.sh project-5 --from /tmp/answers.json
```

`--repo` defaults to `${REPOS_ROOT:-/root/repos}/<project>`. The branch is
`qa/personas-<YYYYMMDD>`, which is also the dedupe key: a second run the same
day finds the branch and refuses rather than making a second PR.

**Which commits the PR carries.** The branch is cut from the checkout's local
`main` explicitly, and the checkout is put back on the branch it was on before
the run ends — success or failure. Both halves matter: a branch cut from
whatever HEAD was parked on would carry that branch's commits into a PR against
`main`, and a run that left HEAD on its own `qa/personas-<date>` would feed
exactly that to the next day's run. Two checkouts are refused instead of
branched from: one with no local `main` at all, and one whose `main` carries
commits `origin/main` does not have (checked only when the checkout already
knows `origin/main` — this lane runs no `fetch`). So the PR diff is the three
files and nothing else.

**What it refuses, and what that costs.** Every refusal is one line on stderr
and rc 1. Everything above the branch line writes nothing into the repo at all —
no branch, no files, no commit, no PR:

| refusal | line comes from |
|---|---|
| answers file missing or unreadable | the script |
| `--repo` is not a git work tree | the script |
| the work tree has uncommitted changes | the script |
| any schema defect in the answers | `qa_personas_validate` (`personas.json: …` / `apps.json: …`) |
| `main` is not a local branch in the checkout | the script |
| local `main` is ahead of `origin/main` | the script |
| the branch for today already exists | the script |

Past that line the three files are committed, so the two remaining refusals do
leave something local behind. Each one says so in its own stderr line, and each
still hands the checkout back to the branch it started on:

| refusal | what survives, and what to do |
|---|---|
| `git push` failed (`gh pr create` is never attempted) | the local `qa/personas-<date>` branch and its commit stay in the checkout — delete the branch before re-running, or push it by hand |
| `gh pr create` failed | the same branch, pushed to origin — open the PR by hand from it, or delete it here and on origin before re-running |

The ordering is what makes "stamped done without delivery" impossible: validate,
render into a temp dir, branch, write, commit, push, create the PR, and only
then print the URL gh handed back. The URL is the single success token.

**How to drive it:**

| what | how |
|---|---|
| the whole script — arguments, refusals, the render, the dry run, the real run against a scratch repo with a real bare `origin` and stubbed `git`/`gh` | `bash tests/qa-personas-generator-test.sh` |
| the schema it validates against (the lib, every rule of v1) | `bash tests/qa-personas-schema-test.sh` |
| the skill installs under the name Claude Code selects on | `bash tests/skills-sync-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/qa-personas-generator-test.sh` |

The generator suite asserts the negatives as hard as the happy path: eleven
malformed answers files, each of which must produce rc 1, an empty repo and an
uninvoked `gh`. It also pins iron guardrail 1 directly — the bare origin's `main`
sha is compared before and after the real run, and no `gh pr merge` may appear
in the recorded argv. The day-two path has its own case (D11): a checkout parked
on an unrelated branch with an unrelated commit on it, asserting the PR's diff
against `main` is exactly the three files, that the unrelated commit is not in
it, and that the checkout comes back with its own file on it. The two
post-commit refusals assert the same hand-back plus the surviving branch, so
the rows above cannot drift from what the script does.

**What is NOT wired yet.** Nothing in `bin/` or `cron/` calls
`bin/qa-personas.sh`; it is operator-invoked only, and `grep -rl qa-personas
bin/ cron/` returns the lib, this script and nothing else. The consumers of the
files it writes — the flow engine, the preview lane and the production lane —
are the other children of #528 (#534, #535, #536) and **do not exist in this
repo today**, so a project that merges a personas PR gets the files and the map
entry, and no lane behaviour changes until those slices land.

**Manual-only / not automatable:** the PR it opens. The generator never merges,
no harness session merges it, and the reading it asks for is a person's job:
every route real, every write flow marked `production safe: no` with a cleanup
that would actually undo it, and everything expensive or irreversible listed as
out of bounds. The rule, in one sentence: never merge a persona map an operator
has not read.
