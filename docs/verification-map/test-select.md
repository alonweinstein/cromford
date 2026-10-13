# Per-diff test selection (`bin/lib/test-select.sh`)

**What it is:** the function that turns a diff into the list of test files that
diff actually needs. `bin/lib/test-select.sh <repo-dir> <base> <head>` prints one
repo-relative test path per line (sorted, de-duplicated, each existing at
`<head>`) and exits 0, or prints nothing and exits 2 with `FULL: <reason>` on
stderr, or exits 3 with `UNAVAILABLE: <reason>` when it cannot look at all.

The whole design is the exit-2 path. A selector that narrows a run by mistake
produces a build that is green because the red test never ran, and nothing
downstream can tell that from a real pass — so every doubt (a broken map, a
compound test script, a source file nothing covers, a missing `jq`) comes back
as FULL, and stdout stays empty until every FULL branch has been passed.

**How a build reaches it:** `HARNESS_SUITE_RUN` in `bin/run-build.sh` (the block
between `# >>> harness suite run` and `# <<< harness suite run`) calls it at
three sites — `harness-suite.txt lenses` (before the review lenses read the
diff), `harness-suite-fix.txt fix` (after a merged fix round) and
`harness-suite-head.txt head` (on a moved head). The caller narrows **only** on
rc 0 with non-empty stdout; every other answer runs the whole suite and carries
the reason into the mode string.

**The knob:** `TEST_SELECT` (`1|true|yes|on` / `0|false|no|off`; anything else is
an ALERTS line and OFF). Unset, the default is ON only for a `board_prefix = -`
project whose checkout carries `tests/impact-map.json`, `tests/static-guards.txt`
or `tests/static-guards/`. **The only checkout on this box (cromford) has
none of the three, and no `package.json` either**, so `HARNESS_SUITE_RUN` returns
at `no-test-script` before the selector is reached and landing this changes no
build here until a repo adds a map. The plan checked the same for the rest of
the fleet on 2026-09-18; this box cannot see those checkouts to confirm it.

**What it reads, all at `<head>`, all optional:**

| input | what it does | absent |
|---|---|---|
| `tests/impact-map.json` | `{"<glob>": ["tests/…"]}`, keys fnmatch'd against changed paths | contributes nothing (present-but-unparseable is FULL) |
| `docs/verification-map/*.md` | an ENTRY naming a changed path contributes the `tests/…` paths it names (`README.md` is the index and `TEMPLATE.md` is the shape — neither is an entry, and reading them as one drags in every feature's tests) | contributes nothing |
| `tests/static-guards.txt`, `tests/static-guards/` | always selected, on every answer | no guards |
| `tests/always-full.txt` | one regex or glob per line; a changed path matching → FULL | the built-in default list (lockfiles, schema, configs, workflows, env, test scaffolding) |
| `package.json` | the script the harness will run (`test:unit`, else `test`) | no compound-script check |
| `.codegraph/` + `codegraph` on PATH | `codegraph affected`, else `codegraph explore` per file | the bounded importer `grep` answers instead |

**What contributes nothing, by rule:** the root `docs/` tree, markdown, text,
images and lockfiles (`is_nonsource`). They are not covered by tests, so they map
to no tests — a docs-only diff comes back as the static guards alone, or as
`FULL: no test files found` when the repo declares none. Without that gate a
markdown file whose stem collides with a test name decides a narrowed run by
coincidence: `plan.md` pulled in three unrelated `plan-*` suites on this repo's
own HEAD. The gate is per path, so a doc riding along with real code changes
nothing about what the code selects.

**"docs" means the root tree, not any directory called docs.** `app/docs/page.tsx`
is a route and `src/components/docs/Viewer.tsx` is a component; treating them as
prose would mean a source file nothing covers never reports `unmappable`, and the
build would run the guards alone and read as green. Nested prose is still prose by
its extension, so the only thing this widens is a nested `docs/` directory holding
an odd extension — which goes FULL, the safe direction (cases 18, 18b, 18c).

**How to drive it:**

| what | how |
|---|---|
| all 20 cases against real git repos | `bash tests/test-select-test.sh`, or `HARNESS_TEST_SANDBOX=1 bash tests/test-select-test.sh` as root on a harness box — the shared scratch guard refuses to build a scratch tree next to a live `/root/harness` without it. CI is not root and needs no flag |
| the real caller, narrowing a real `npm run` argv | case 13 of that suite — `HARNESS_SUITE_RUN` extracted from `bin/run-build.sh` by its markers, with a stub `npm` |
| this repo, right now | `bin/lib/test-select.sh . HEAD~1 HEAD; echo $?` — on the commit that last touched this entry it prints exactly `tests/test-select-test.sh`, rc 0. On a commit that changed only prose it prints nothing and answers `FULL: no test files found`, rc 2, because cromford declares no static guards |
| any other checkout | `bin/lib/test-select.sh /root/repos/<project> origin/main HEAD` — a repo with no map still answers from the filename convention and this map; it goes FULL the moment one changed source file maps to nothing |
| the suite reads one clock and no network | `bin/test-determinism-lint.sh tests/test-select-test.sh` |

**Files it owns:** `bin/lib/test-select.sh` and `tests/test-select-test.sh`. It
writes nothing anywhere: one `mktemp` file outside the repo for the NUL-delimited
git reads, removed on exit. `git status --porcelain` in the inspected repo is
byte-identical before and after a call.

**What must never regress:**

- **Empty means FULL.** No candidates, no guards, nothing at head → exit 2
  `FULL: no test files found`. An empty stdout with rc 0 would read to the caller
  as "run the full suite" anyway, but the record would claim a selection.
- **A deleted test is MAPPED, never SELECTED.** A test deleted in the diff still
  proves its module was covered (so the change is not unmappable), and it never
  reaches the argv list, because it does not exist at head.
- **The static guards are on every exit-0 answer**, including a docs-only diff,
  in BOTH declared forms — the `tests/static-guards.txt` list and the
  `tests/static-guards/` directory (cases 7, 19).
- **A source file under a nested `docs/` directory is source.** Only the root
  `docs/` tree is prose by path; everything else earns it by extension
  (cases 18, 18b).
- **A repo's `tests/always-full.txt` REPLACES the built-in list**, it does not
  extend it. The built-in regex is a documented fallback, not policy, so a repo
  that ships its own owns the whole rule (case 20, and 20b for the replacement).
- **A docs-only diff selects the guards and nothing else.** Prose covers no
  code; a stem collision between a markdown file and a test name is not a
  mapping (cases 7 and 7c).
- **The tree, never the checkout.** The importer `grep` is the one arm that
  reads the filesystem, so what it finds is dropped unless it exists at head —
  an untracked test never marks a change MAPPED and never reaches the argv list
  (case 17).
- **A broken map is FULL, not an empty map** — absent ≠ empty ≠ broken.
- **A compound `test` script is FULL.** `npm run x -- files` appends to the LAST
  command of `a && b`, so the file list would land on the wrong command
  (`bin/repro-gate.sh:75-83`, the project-4 false-fail). Never split it.
- **Precision, not "the tests/ directory".** An unrelated sibling test must not
  be selected; a selector that returns everything passes every positive case and
  is worth nothing.
- **Nothing reaches a shell.** Paths come out of a diff. No `eval`, no
  `bash -c`, no command built from a string; a path named
  `src/lib/a$(touch pwned).ts` is answered, not executed.
- **Bounds only ever widen.** The importer grep is skipped above 200 changed
  source files and never enters `node_modules`/`dist`/`build`/`.next`. Both can
  only remove candidates, which pushes toward FULL.
- **codegraph claims nothing when it fails.** No reason string, no selection; the
  grep arm answers instead. The codegraph arm is exercised in the suite with a
  stub binary; the real binary is not installed on this box, so the codegraph arm
  has never been driven against it.
- **codegraph adds tests, never a mapping.** It answers for the whole range, so
  it names tests without saying which changed file each one covers. Its tokens
  join the selection with no owner, which means a change codegraph alone maps
  still answers `FULL: unmappable change <f>`. That is wider than the ticket's
  "(a)+(b)+(c) mapped to zero tests" and deliberately so — inventing an owner
  would let a real hole in coverage read as mapped (case 14b).

**Known limits (ticket-conformant, both raised on the parent #483):**

- **The filename convention is a stem PREFIX** (`x*.test.*`, the shape the ticket
  specifies), so a short stem can be mapped by a stranger's test: change
  `src/lib/a.ts` in a tree whose only test is `tests/auth.test.ts` and the answer
  is `tests/auth.test.ts`, rc 0 — the change reads as covered. `a`, `db`, `ui` and
  friends are where this bites. Narrowing the rule to an exact-stem match, with
  the prefix kept only for the `x.unit.test.ts` shape, is the fix; it changes the
  contract, so it belongs to the parent, not here.
- **`*.snap` is nonsource.** A snapshot-only diff contributes nothing and does not
  go FULL, so it can ship having run only the guards. Rare (a snapshot moves with
  its test or its source), but the honest rule is to map a snapshot to its owning
  test, or to make `__snapshots__/**` always-full. Until then a repo that cares
  puts the path in its own `tests/always-full.txt`.
