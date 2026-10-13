# Lane render: cron, the env template and the lane registry are composed, not appended

**What it is (BH-1178):** the three files every new lane or knob used to be
appended to are now RENDERS of one file per lane, per box and per topic. Adding
a lane is a new `catalog/lanes.d/<id>.json` plus a new
`cron/lanes/<NNN>-<id>.cron`; adding a knob is a new
`env-templates/lanes/<NNN>-<slug>.env.example`. Nothing shared is edited, so
two builds doing it at the same time write different files.

The tail it exists for: across the last 200 merges `cron/hub.cron` was touched
by 6 and `env-templates/global.env.example` by 25, always in the same trailing
lines, and `catalog/lanes.json` is one sorted 3,100-line array. Two branches
each registering one unrelated lane conflicted in BOTH `cron/<box>.cron` and
`catalog/lanes.json` — measured on `origin/main` before this change, and clean
after it.

**And the renders left git (BH-1247).** BH-1178 split the sources but kept the
twelve outputs committed, which left each of them a shared mutable cell every
build writes: a PR that edited a lane and did not re-render turned red on
`tests/registry-render-test.sh`, and once such a PR merged, every OTHER open PR
inherited the red on a file its ticket never mentioned. Three merge trains died
that way on 2026-09-21 (#1241, #1257, #1263); #1241 went red immediately after
#1234 hand-edited four lanes. Same answer as BH-1175 gave
`docs/verification-map/README.md`: take the contested cell OUT of git rather
than resolve it. The ten `cron/<box>.cron`, `catalog/lanes.json` and
`env-templates/global.env.example` are git-ignored, and everything that reads
one renders it first.

**The renders are byte-identical at this cut.** All ten crontabs, the registry
and the env template compose to exactly the bytes `origin/main` committed, and
`bin/render-crontab.sh <box>` produces the same installed crontab from a
rendered base as it did from the committed one — so no box's behaviour changes.

## The three renderers

| generated file | composed from | command |
|---|---|---|
| `cron/<box>.cron` (10) | `cron/lanes/`, `cron/boxes/<box>.d/`, `cron/boxes/<box>.order`, `catalog/lanes.json`, `fleet.conf` | `bin/render-crontab.sh --from-fragments --all --write`, which hands off to `bin/render-cron.sh --all` (`--out-dir <dir>` renders elsewhere, `<box>` prints one) |
| `env-templates/global.env.example` | `env-templates/lanes/` | `bin/render-env-example.sh --write` (`--to <path>`) |
| `catalog/lanes.json` | `catalog/lanes.d/` | `bin/lanes-build.sh --write` (`--to <path>`) |

None of the twelve is committed. **The box list comes from `cron/boxes/<box>.d`,
not from the rendered `cron/*.cron`** — a list derived from the artifact is
empty in a fresh checkout, and `--all` would then report success having rendered
nothing.

### What `--check` means now

`--check` on all three stopped comparing bytes: there is no committed copy to
compare against, and "the file on disk differs from its sources" is a tree that
has not been regenerated yet, not a defect. It validates what IS committed:

- the sources parse and are well-named (unchanged),
- the render is **deterministic** — two runs over the same sources produce the
  same bytes, which is the property the byte comparison stood in for,
- **no render is TRACKED in git**, whether or not `.gitignore` still covers it.
  Requiring both would leave the obvious way back in open: a PR that deletes the
  ignore line and `git add -f`s the render would pass, and a gate whose subject
  can delete the gate is not a gate.

`--check-committed` keeps the old byte comparison, for a repo or a lane that
still has a committed render to compare against — the same pair
`bin/verification-map-build.sh` carries, for the same reason.

### Who renders, and when

| consumer | renders through | when |
|---|---|---|
| a box installing its crontab (`bin/update-runners.sh`, `bin/fleet-propagate.sh`, an operator) | `bin/render-crontab.sh`, whose BASE is now `bin/render-cron.sh <box>` | every install, fail-closed on a render error |
| `bin/box-name.sh` (the watchdog-ping name the fleet is keyed on) | `bin/render-cron.sh <box>` | when no render is on disk, best-effort |
| `bin/lib/lane-gate.sh`, `bin/lib/llm-gate.sh`, `bin/harness-ctl.sh`, `bin/render-cron.sh` | `bin/lib/lanes-registry.sh`'s `lanes_json_path` | on demand, memoised per process |
| `worker/jobs` (a STATIC ESM import of `catalog/lanes.json`) | `bin/lanes-build.sh --write` before `wrangler deploy` and before `npm test` | every deploy, every CI run |
| CI | all three, before the suites, plus `bin/render-diff.sh` on a PR | every run |
| the public share mirror | all three, at publish time | every publish |

`lanes_json_path` renders to `catalog/lanes.json` itself and not to somewhere
under `state/`, because the worker's import is resolved by the bundler at build
time and cannot be pointed elsewhere; a second location would give the fleet two
spellings of one artifact and the one the worker serves would be the one nothing
refreshed. Staleness is keyed on a **hash** of `catalog/lanes.d/` (its file list
as well as its contents, so a deleted lane moves the key) held in
`catalog/.lanes.json.stamp` — not on mtimes, which `git checkout`, `cp -a` and
rsync all move for reasons that have nothing to do with content.

### The cost, and what pays it back

Uncommitting the renders takes "what will this box actually run" out of the PR
diff, and that is the question a lane review is asking. `bin/render-diff.sh
<base-ref>` computes it: the base's fragments rendered by the base's own
renderers, this tree's rendered by this tree's, and the difference printed. CI
runs it on every pull request. It is a REPORT — it fails only when it cannot
compute a diff (rc 2), because a render diff that silently prints nothing is
indistinguishable from a change with no effect.

The fragment directories and the three commands are the spellings
`bin/lib/render-fragments.sh`'s `rf_registry()` and
`guardrails/rendered-file-freshness` already declared, so the guardrail's
message names a command that exists. All three are also declared in the
`## Generated files` table of `docs/verification-map/index/tail.md` (which is
where `bin/batch-resolve.sh` reads it since BH-1175 made the README generated
and uncommitted) . They no longer carry
`merge=union` in `.gitattributes`: a merge driver for a path git never sees is a
rule with no subject that would come back into force the day somebody re-added
the file, so BH-1247 removed all twelve declarations and
`tests/generated-files-train-test.sh` now asserts each of those paths has NO
merge attribute. The one declaration left is
`env-templates/project.env.example`, which is hand-maintained. The regenerate
table still writes the ten crontabs out **by literal path, never a glob**, because
`bin/batch-resolve.sh` matches that table with shell `case`, where `*` crosses
`/`: a `cron/*.cron` row would also claim `cron/lanes/<lane>.cron`, and a
conflicted path with a regenerate command is resolved by taking one side. Two
approved PRs editing the same lane fragment in one train would silently lose
one, with the render and every check green. The ten crontabs are therefore
written out one by one, and `tests/generated-files-train-test.sh` GT-7 pins both
the count and the no-glob rule,
so `bin/batch-resolve.sh` and the rebase twin repair them by re-running the
command over the merged tree instead of hand-merging a machine-written file.

## What render-cron.sh owns, and what it does not

It composes the box's OPERATOR lines — everything that used to live outside the
`# BEGIN fleet-managed` markers — and then hands the result to
`bin/render-crontab.sh`, which still owns the two things it always owned: the
per-project block from `fleet.conf` (via `bin/lib/cron-lines.sh`) and the
`hub-lease.sh check &&` prefix inside `# BEGIN hub-lanes`. One renderer per
concern, and the crontab a box installs is still produced by exactly the script
that produced it before this change.

Membership comes from the REGISTRY, not from the fragment: a lane's line is
rendered onto a box when `catalog/lanes.json` lists that box in `.boxes`. Two
classes of registry lane are deliberately not rendered from a fragment, and the
renderer names each reason rather than skipping quietly:

- the seven per-project lanes of the fleet-managed block (`run-triage`,
  `run-product`, `healthcheck`, `apply-migrations`, `merge-queue`,
  `deploy-train`, `review-prs`) — `bin/lib/cron-lines.sh` owns them, keyed on
  each project's `fleet.conf` minute offset;
- a lane another lane schedules, written in the registry as a cadence naming
  its caller (`fly-pool`: `*/10 * * * * (via bin/fly-pool-tick.sh)`).

Everything else must have a cadence AND a fragment. A registry lane with an
empty cadence, or one a box claims with no fragment, fails the render by name
with an EMPTY stdout — the second is the 2026-08-30 project-7 failure in the
other direction: registered, visible on the settings page, scheduled nowhere.

## The fragment format

A fragment is crontab text with `# @` directives at column 0. `# @hub-lanes`
marks the section as belonging inside a hub-lanes block; `# @ungated <why>`
marks a hub-scoped lane that runs on every box holding the file on purpose;
`# @fleet-managed` marks where the project blocks go; `# @box <id>` starts a
box's variant of the lane, and lines above the first `# @box` are the default
every other box gets.

There are TWO substitutions:

- `@BOX@` becomes the box id. It exists so the two lanes that take the box as an
  argument (`extra-usage-track`, `cost-rows-push`) are one file rather than ten.
- `@WATCHDOG@` becomes the name this box pings the watchdog with (BH-1185),
  from `cron_watchdog_name_for` in `bin/lib/cron-lines.sh`: `hub` →
  `box-hub`, otherwise the `fleet.conf` box column of the first project
  on this box, machine generation and all (`project-3` → `box-project-3-2`).
  That function is the inverse of `cron_box_id_for` and cannot be string
  surgery, because `cron_box_id_for` DROPS the generation suffix. It exists so
  `cron/lanes/260-watchdog-ping.cron` is ONE line rather than ten: the ten were
  a default naming `box-project-4-1` with no `# @box project-4` header plus nine
  variants, so a box newly added to the lane's `.boxes` silently pinged under
  project-4's name — at the watchdog, indistinguishable from the new box being down.
  Adding a box to the ping is now a `fleet.conf` row plus its id in
  `catalog/lanes.d/watchdog-ping.json` `.boxes`, never a fragment edit. A box
  the registry cannot name REFUSES the render, naming the box; resolution is
  lazy, so a box with no `fleet.conf` row that runs no lane using the
  placeholder (`project-10`) renders exactly as before.

A hub-scoped lane must carry ONE of `# @hub-lanes` or `# @ungated <why>`, and
the render refuses it by name otherwise. A hub lane that simply forgot the gate
renders with no lease check and fires on every box at once; before this, only
`tests/hub-cron-gated-test.sh` said so, after the crontab was committed.
**The reason on `# @ungated` is REQUIRED** (BH-1185): the directive regex used
to be `/^# @ungated( |$)/` and accepted a bare directive, so a typo rendered as
a decision. A bare or whitespace-only `# @ungated` in any fragment that renders
for the box now refuses by `file:line`, in a pre-scan that runs BEFORE the gate
check, so a bare directive can never be counted as the declaration a hub-scoped
lane owes. Four lanes are legitimately ungated and say why in their own file:
`poll-commands` (the console's command channel must answer on the box an
operator is talking to), `claude-auth-check` (it checks THIS box's credential),
`heartbeat-reaper` (it reads this box's own `state/heartbeat/`) and
`backup-records-sync` (registered to the hub alone, rewriting that hub's own
`state/fleet-heartbeat/` records from one GET, fail-open). The fourth is
BH-1031's line reproduced as committed: the render says what the crontab
already does, and whether that line should take the lease is a question for
that lane, not something a renderer may decide on its behalf.

Both fragment directories are listed through `rf_fragments()` in
`bin/lib/render-fragments.sh`, which sorts under `LC_ALL=C` and REFUSES a CR
byte. A CRLF fragment would otherwise render rc 0 with the `\r` inside the
crontab line: cron hands bash a redirect target `1\r`, the lane fails every
tick, and every `--check` stays green because the committed crontab was
rendered from the same bytes.

### Two refusals about a crontab that is green everywhere and still wrong

Both BH-1185, both with an EMPTY stdout and rc 1 like every other refusal here.

**The same schedule line from two fragments.** stderr reads
`render-cron.sh: <box>: the same cron line is emitted by more than one fragment
— '<line>' from <frag> <frag>`. Each fragment is exactly what its author wrote,
the registry is consistent and every `--check` is green — and the box runs that
lane twice, every tick, forever. The comparison is over the EXPANDED text (after
`@BOX@` / `@WATCHDOG@`), across `cron/lanes/` and `cron/boxes/<box>.d` together,
and before `render-crontab.sh` adds the hub-lease prefix. A `# @box` variant
REPLACES its default, so a variant identical to its own default is not a
duplicate and does not refuse.

**A managed script for a project the box does not own.** stderr reads
`render-cron.sh: <box>: <file>:<n> invokes a managed script for project '<p>',
which fleet.conf does not assign to this box`. `render-crontab.sh` ABSORBS such
a line into the managed block when the box owns the project — the migration path
off the hand-maintained crontabs, unchanged — but a foreign project has no block
to be absorbed into, so the line was preserved verbatim as the operator's and the
box ran a lane for a project (or a parked one) with no registry row and no kill
switch. Scripts deliberately outside `cron_managed_scripts` (`security-scan.sh`
and kin) still take a project argument and are not refused.

Both were measured against the fleet before they shipped: no box renders a
duplicate schedule line and no `cron/boxes/*.d` file invokes a managed script,
so each refusal is green on the fleet as it stands and
`bin/render-diff.sh origin/main` reports no change.

The hub-lanes markers are not stored: the renderer opens a block immediately
before a run's first schedule line and closes it after its last, so a comment
paragraph ABOVE a run stays outside and one BETWEEN two gated lines stays
inside. That reproduces `cron/hub.cron`'s fourteen blocks exactly.

Order is the fragment's `<NNN>` prefix, one fleet-wide sequence that every box
is a subsequence of, with `cron/boxes/<box>.order` for the places a box
genuinely deviates (`project-6` runs the ping group before the tick group;
`hub` runs `rebase-train` inside its hub block, and takes `jobs-watchdog` at
350 because its variant of that lane is the gated `*/5` detector while the
other nine run the `24,54 --resume` pass at 520). A new lane needs no entry
there.

## Proof

`tests/registry-render-test.sh`:

- every one of the ten boxes renders, and renders to the same bytes twice — the
  whole fleet, not a sample. (Until BH-1247 this compared against the committed
  `cron/<box>.cron`; there is no committed copy now, and determinism is the
  property that comparison stood in for.);
- an empty cadence and a missing fragment each fail the render, by name, with
  nothing on stdout;
- two branches each adding a lane MERGE CLEAN, the two builders recompose the
  generated files over the merged tree, and the result carries both lanes;
- the env template and `catalog/lanes.json` compose from their parts
  deterministically, a new topic file reaches the render, and
  `--check-committed` goes red when a committed copy is stale;
- every cron fragment names a lane the registry carries;
- a CRLF fragment is refused rather than rendered, in both renderers;
- a hub-scoped lane declaring neither `# @hub-lanes` nor `# @ungated` is refused
  by name, and declaring either renders;
- an unknown box id refuses with a reason rather than a blank line.

`tests/render-cron.bh-1185-test.sh` pins the substitution and the three
refusals, every case driving `bin/render-cron.sh` itself over a scratch copy of
the repo:

- every box in the ping lane's `.boxes` pings under the name `fleet.conf` gives
  it (the expectation is read out of `fleet.conf` by the test, not typed), the
  `-2` generation suffix survives, and the fragment is one line naming no box;
- a box the registry cannot name refuses, by box id, with nothing on stdout —
  and a NEW box (a `fleet.conf` row plus a `.boxes` entry) renders its own ping
  with the fragment byte-identical to the committed one;
- two fragments emitting the same line refuse and name both fragments and the
  line, whether the collision is lane-vs-lane or `cron/boxes/<box>.d`-vs-lane;
- a boxes-file line for a foreign project refuses by `file:line` and project,
  while an OWNED project renders and is absorbed exactly once, a comment naming
  a managed script is not a line, and a non-managed script is not refused;
- a bare or whitespace-only `# @ungated` refuses by `file:line`, cannot count as
  the declaration even beside a real `# @hub-lanes`, and renders with a reason;
- and the adversarial negative for all three refusals: every one of the ten
  boxes still renders, to the same bytes twice.

`tests/registry-no-commit-test.sh` (BH-1247) carries the rest:

- none of the twelve is tracked, all twelve are ignored, and none carries a
  merge attribute;
- a TRACKED render fails `--check` by name, for all three renderers, and it
  fails even when `.gitignore` no longer covers it;
- `--check` refuses a source that does not render to the same bytes twice, and
  `--check-committed` still answers the old question both ways;
- two branches each adding a lane merge clean with no attribute and no
  resolver, and the render over the merged tree carries both;
- a tree with NO `cron/<box>.cron` still renders a full crontab through
  `bin/render-crontab.sh`, and `bin/box-name.sh` still resolves the box name
  rather than falling back to the hostname;
- the loader renders when nothing is on disk, does not rewrite an unchanged
  registry, re-renders after a lane file changes, and still yields to
  `LANE_REGISTRY`;
- `bin/render-diff.sh` says "no change" on an unchanged tree and shows the
  gained crontab line and the registry change on a real lane addition.

## Not in this change

The per-lane paragraphs of `docs/MERGE-CONDUCTOR.md` and
`docs/BUILD-CONCURRENCY.md` stay where they are. `guardrails/doc-monolith-edit`
fails any edit to a guarded doc outside its Changes region unless the PR title
starts with `docs:`, and moving a file whole is the largest such edit there is
— so a mechanical move belongs in its own `docs:` PR, not in this one.
