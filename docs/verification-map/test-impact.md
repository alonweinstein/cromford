# CI test-impact selection (a diff runs the suites it can reach)

**What it is:** `bin/test-impact.sh`, the `--only-file` flag on
`bin/test-suite-run.sh` and `bin/test-trace-safety.sh`, and the
`which suites can this diff reach` step in the two matrix jobs and two fan-in
jobs of `.github/workflows/harness-ci.yml` (BH-1203).

**Why.** After BH-1192 the corpus runs as eight shards (four until 2026-09-22), and
every pull request pays that to prove that a paragraph in `docs/` did not break
the merge conductor. The shards made the corpus faster; they did not make it
smaller. This lane asks the narrower question: given this diff, which suites
could possibly see it? A docs-only change selects the always-run floor of 19, a one-library change
about 85, and anything the map cannot account for still selects the
whole corpus.

**The universe is what git tracks.** `git ls-files` in a checkout, `find` with
the machine-local directories pruned in a tree that is not one. A snapshot that
re-adds files under `.gitignore` rules — which is what the Fly test host's
runner does — lacks tracked files that live under an ignored directory, so its
map is one row shorter. The checkout's map is the correct one: a diff is made of
tracked paths, so the universe is tracked paths.

**The map.** `bin/test-impact.sh map` reads the TEXT of every `tests/*.sh` and
`tests/mc/*.sh` and emits `<suite>\t<path>` rows, where a path is a file, a
directory (trailing `/`, meaning anything under it), or `*` (the whole tree).
The rows are closed transitively over what those scripts `source`, so a change
to `bin/lib/alpha.sh` reaches the suite that only ever names `bin/beta.sh`.

**The source closure blanks the variable before it reads the path.** A source
line is tokenised on non-path characters, and `$` is one of them, so
`. "$HARNESS/bin/lib/x.sh"` used to tokenise to `HARNESS/bin/lib/x.sh` — not a
path in this tree — and produced no edge at all; the braced `${HARNESS}/…` only
worked by the accident of `}` being a separator too (BH-1253). Every `$NAME`
and `${NAME}` is now blanked first, so the token starts at the `/` and resolves.
The blanking is narrow on purpose: `$` must be followed by a letter or an
underscore, which leaves `$0`, `$1` and `$(cd …)` alone. That is what makes
`. "$HARNESS/bin/lib/rb/$_m.sh"` a dependency on the whole `bin/lib/rb/`
directory, which is the shape 173 rows of the map now have and had none of
before.

**The extraction is ROOTED, and that is the whole trick.** A plain
`grep -o 'bin/[^ ]*'` over `tests/` is useless here: 284 of the 441 suites
mention `bin/`, and almost every one of those is the suite writing into its own
scratch harness (`chmod +x "$H/bin/"*.sh`, `cp "$DIR/bin/$f" "$T/bin/$f"`).
Counting `$T/bin/` as a dependency on the repo's `bin/` would put two thirds of
the corpus in every diff. A token behind a variable that is not the checkout is
a scratch path and is dropped; an unrooted token must resolve to a real file, so
`the bin/ lane` in a sentence is prose and `"$DIR/bin/lib/mc/$m.sh"` is a
dependency on every module in that directory.

**Six spellings of "the checkout", and every line is normalised before anything
is extracted.** BH-1203's review found the first version of this recognising
only the first of them and dropping eight suites, and a second round found the
sixth and one more:

| spelling | example |
|---|---|
| a root variable | `"$DIR/bin/x"` (500 suites) |
| the idiom, inline | `"$(cd "$(dirname "$0")/.." && pwd)/bin/x"` |
| its short form | `"$(dirname "$0")/../bin/x"` |
| a root variable that is not `DIR` | `H="$(cd …)"` then `"$H/bin/x"` |
| python's f-string | `open(f"{DIR}/console-ui/…")` |
| python's argv, then a piecewise join | `python3 - "$DIR"`, `root = sys.argv[1]`, `os.path.join(root, "bin", "share")` |

Each becomes the literal marker `@ROOT@/`, so the extractor knows one form
instead of six and a seventh is one `gsub`. The last one needs two steps: the
per-suite flag that says this suite handed python the checkout, and folding
`os.path.join(@ROOT@, "a", "b")` into `@ROOT@/a/b`, because in python the path
does not exist as text until the join is folded. **The fourth has to be per
suite:** `$H` is the checkout in three suites and a scratch harness in 958 other
places, so a variable earns root status only in the suite whose own text assigns
it from the idiom.

**The always-run set** is derived, not listed: a suite whose text says
`ls-files`, `find "$DIR"`, `--tree` or `"$DIR"/tests/*` reads the whole tree, so
no map of it is worth anything and it runs on every diff. Nineteen suites
qualify, and the three that main added while BH-1203 was in flight were picked
up with no edit.
`catalog/test-impact-always.txt` is the escape hatch for a whole-tree reach no
signal can see; it is empty, and a line added to it is an admission that the
detector missed something.

**Everything it cannot see runs everything.** `select <base>..<head>` prints the
whole corpus, with the reason, when the diff touches `tests/lib/`,
`bin/lib/suite-runner.sh`, `bin/test-impact.sh`, `.github/workflows/` or
`catalog/` (infra: a change there can move which suites exist or how they run);
when it touches a path no suite maps and that is not inert (`docs/`, root
`*.md`, `.claude/`, `.harness/specs/`); when the base cannot be resolved; when
the map cannot be built; and when the selection somehow comes back empty. Every
unknown falls to FULL, because the expensive failure is one slow CI run and the
silent one is a regression that shipped because its suite was not selected.

**The CI decision lives in the script, not in YAML.** `ci-select` reads
`TI_EVENT`, `TI_BASE`, `TI_PR_TITLE` and `TI_PR_LABELS` and returns the whole
corpus for a push to main, for a merge train (both the `merge train` spelling
BH-1203 named and the `batch(<project>): …` title `bin/batch-resolve.sh`
actually opens — a train carries several tickets and is the last PR where a
partial corpus is defensible), for the `full` label, and for any event that is
not a pull request. The title travels as an environment variable and is never
interpolated into a shell command.

**The map is generated and never committed**, on BH-1175's rule: it is derived
from committed sources and moves on most PRs, so a stored copy would conflict on
every rebase of a drain exactly the way `docs/verification-map/README.md` did.
It is in `.gitignore`; every consumer builds it, which takes about three
seconds. That removes the "stale map" trigger BH-1203 asked for and replaces it
with something structural: a hole in the map makes its path unmapped, and an
unmapped path is `unknown reach`, which is the whole corpus.

**The corpus-wide audit.** `bin/test-impact.sh audit` re-reads the corpus with a
cruder, deliberately independent rule — on any line that names the checkout,
every token that resolves to a real file must be a row of that suite — and
prints what the map is missing. It must print nothing, and
`tests/test-impact-test.sh` fails when it does not. Against the map BH-1203 sent
for review it prints 493 missing rows over 465 suites; against this one it
prints nothing. It is the case that catches the whole class, where checking one
library by hand caught none of it.

Its residual blind spot is stated rather than hidden: a line that reaches the
checkout through a spelling NEITHER the normaliser nor the audit recognises is
invisible to both. That is precisely why the normaliser holds one list of forms
instead of five scattered branches — a new form is one `gsub`, and the audit
starts checking its lines the moment it is added.

**Known blind spot: exec edges.** The closure follows `source` and `.`, not
exec. `bin/agent-call.sh` RUNS `bin/iron-law-guard.sh`, `bin/run-build.sh` runs
`bin/size-scope.sh`, `bin/run-triage.sh` runs `bin/overlap-guard.sh`; a change to
a callee does not pull in the suites that only name the caller. Most of those
suites stub the callee, so following exec would widen the selection for little
gain, and it is outside the ticket's design. The safe reading of a small
selection is "the map knows about `source`", not "nothing else can be affected".

**The orphan ratchet.** `bin/test-impact.sh orphans` lists the `bin/`, `worker/`
and `console-ui/` entries that NO suite names — for which the lane will
correctly select nothing, which is only acceptable where it was already true.
Since BH-1268 nothing about the set is committed.
`bin/test-impact.sh orphans --check` computes the live set AND the set at this
branch's merge-base (`TI_BASE`, else `git merge-base HEAD origin/main`) and
refuses any orphan that is NEW — the old ratchet's question, asked of two trees
instead of a tree and a file. A FIXED orphan needs no commit, and a neighbour's
merge cannot re-red anybody, because every branch is judged against its own
base. It costs one extra map build over the base tree, about five seconds. The
list itself (`catalog/test-impact-orphans.txt`) is derived and git-ignored, and
`--check` refuses a tracked one; a base that cannot be resolved is rc 2, never a
pass.

A committed COUNT was the first design and was refused in review: a floor only
refuses while live equals it, so one fixed orphan that nobody compensates for
leaves the ratchet blind by the width of the slack — and main already stood at
102 against a proposed floor of 103. The two shapes that slip past a count, a
swap (fix one, add one) and a new hole added after a fix, are cases G6 and G7.

Only exact, by-name rows count: a whole-tree suite and a directory sweep reach
every file under them, and counting those would make the orphan set permanently
empty — a guard that can never fire reads like a guard and is not one.

**And "named" means named on a line that is not a comment** (BH-1253). The map
is an over-approximation by design, so `# see $DIR/bin/x.sh for the real thing`
counts as a citation for SELECTION and costs one extra suite on a diff — the
documented safe direction. For the RATCHET the same row points the wrong way: a
script whose only mention in the whole corpus is a sentence inside a comment has
no test, and counting it hid 18 holes, `bin/board-invariants.sh` among them. So
the map built for `orphans` skips lines whose first non-blank character is `#`
and the map every other command builds does not — 95 orphans became 113 with no
change to a single selection. A TRAILING comment after real code still counts.
`orphans --check` scores both trees with the current script, so the 18 appear on
both sides of the diff and none of them reads as new.

**It runs under mawk, and that is not a detail.** The awk on every fleet box and
in the `debian:trixie-slim` image `bin/run-tests-in-docker.sh` builds is mawk
1.3.4, not gawk, and until BH-1253 the script could not build a map there at
all: mawk creates an array element for the LVALUE before it evaluates the right
side of an assignment, so the ternary that accumulated a suite's root variables
saw its own key on first sight and produced an alternation with an empty branch
(`(|DIR|…)`), which mawk refuses to compile. Every `map`, `select`, `orphans`
and `audit` died with `regular expression compile failed` and fell through to
the full corpus — never unsafe, just blind — and `tests/test-impact-test.sh` was
39 passed / 42 failed on every box in the fleet. With that fixed, a second mawk
difference surfaced: its `match()` takes the shorter, later alternative rather
than the longest, so a redundant `fleet[.]conf` beside the generic
`[A-Za-z0-9_-]+[.](md|conf)` in the prefix list returned the UNROOTED token and
36 suites lost their `fleet.conf` row. Keep the prefix list free of redundant
alternatives, keep the awk POSIX (no `gensub`, no `IGNORECASE`, no `{n}`), and
`tests/test-impact.bh-1253-test.sh` compares a map built under mawk with one
built under whatever `awk` is on `PATH` byte for byte.

**A tree with no suites is rc 2, never a wait.** `$(ls tests/*.sh)` unquoted as
awk's argv is an EMPTY argv when the glob matches nothing, and awk with no file
operand reads stdin — so `map`, `orphans` and `audit` over a tree with no suites
used to block for as long as the caller held stdin open rather than refusing.
The suite list is built, and refused when empty, before any awk runs.

**How to drive it.**

```bash
bin/test-impact.sh map                      # the map, on stdout
bin/test-impact.sh select origin/main..HEAD # the suites this branch can reach
bin/test-impact.sh orphans                  # what no suite names
bin/test-impact.sh orphans --check          # the orphans this branch ADDS (none)
bin/test-impact.sh audit                    # rows the map is missing (empty)
bash bin/test-suite-run.sh --only-file /tmp/impact.txt tests tests/mc
bash tests/test-impact-test.sh              # the suite
bash tests/test-impact.bh-1253-test.sh      # mawk parity, source edges, the comment rule
```

**What it looks like in CI.** Each of the four shard jobs and both fan-ins print
one line: `impact: 21 of 520 suites (selected: 3 changed path(s))`, or
`impact: 520 of 520 suites (full: infra change (.github/workflows/harness-ci.yml))`.
A small run has to be visibly a decision — the failure to fear is a selection
nobody noticed, because a green check that ran eleven suites looks exactly like
a green check that ran all of them.

**How this relates to BH-550's `bin/lib/test-select.sh`** (#842, in flight).
That one is the BUILD lane's selector: it runs inside `bin/run-build.sh` against
a CLIENT repo, maps a changed file to `*.test.ts` / `*.spec.ts` by a
hand-written `tests/impact-map.json`, the filename convention, and codegraph's
importers. This one is the CI lane's selector for cromford's own shell
corpus, and its map is DERIVED from suite text rather than written by hand.

The doctrine is the same and deliberately so: every doubt answers FULL, a map
that will not parse or will not build is FULL and never "zero mappings", and the
list and the reason travel on different channels so a narrowed list beside a
FULL reason is impossible. `select` prints its reason on fd 3 and the suites on
stdout; #842 prints `FULL: <reason>` on stderr and exits 2 with stdout empty.
The difference is the caller: `--only-file` wants a list in every case, so the
full corpus here IS the list of all 516, which keeps one code path in the runner
and keeps an empty list the rc 2 refusal it is everywhere else.

The map FORMATS stay separate, and that is the point rather than an oversight.
#842's is a hand-maintained hint file a target repo ships; a derived table is
impossible there, because the harness does not own those repos' conventions.
This one is derived precisely because a hand-maintained table in THIS repo would
be the committed generated file BH-1175 removed. What can converge later is the
caller: when the build lane runs against cromford itself, #842 can call
`bin/test-impact.sh select <base>..<head>` instead of re-deriving a map — one
selector for one repo, two selectors for two different kinds of repo.

**The full-corpus escapes.** The `full` label on a pull request, the
`workflow_dispatch` button, and any push to main. There is deliberately no
nightly `schedule:`: main takes several merges a day and each one is a full run,
so a nightly would buy a duplicate — and it would arm the metered `prompt-evals`
job on an event with no base sha, whose gate fails OPEN to RUN. That job is
fenced to `pull_request` and `push` for the same reason.
