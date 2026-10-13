# Resolver modules (`bin/lib/br/`)

**What it is:** the split of `bin/blocked-resolver.sh` — 3,778 lines that 19 of
the last 200 merges touched — into one file per concern under `bin/lib/br/`.
It is the resolver's half of the conflict-reduction plan that already produced
`bin/lib/mc/` (BH-477) and `bin/lib/rb/` (BH-478): on the day the plan was
written, those five files and their two suites accounted for 40 of 53 conflicted
files. Two builds that touch two unrelated concerns should not conflict in a
file neither ticket is about.

**The first slice ships two modules and changes nothing.**

| module | what it owns |
|---|---|
| `bin/lib/br/ladder.sh` | the classifier: `br_ladder_class`, `br_skips_mechanical`, `br_ladder_rung`, `br_regen_offered`, `br_regen_ladder`, `br_action`, `br_reason_of` |
| `bin/lib/br/record.sh` | the per-`(project, key)` json under `$ST`: `br_rkey`, `br_cap_key`, `br_file`, `br_load`, `br_num`, `br_record`, `br_event`, `br_set_outcome`, `br_set_num`, `br_set_field`, `br_seen_rebuild`, `br_json_edit` |

**It landed DARK.** The `# >>> resolver modules` loop sources the modules ABOVE
the inline copies, which are still there — so the inline definition wins, byte
for byte, and the modules are inert. A tick today behaves exactly as it did
before the slice. The CUT that deletes the inline copies is a separate change,
and `tests/br-split-layout-test.sh` case 4 holds the two texts identical until
it happens: the module's copy of every mapped function must be byte-identical to
the inline one, and the inline one must still exist.

**A missing module is a REFUSAL, not a shrug.** Boxes take `bin/` through
`rsync -a` per FILE (`bin/harness-sync.sh`), so a tick that fires mid-sync can
see the lane new and a module missing or half written. Either case ends the tick
with rc 1 and one line:

```
<stamp> RESOLVER MODULE MISSING: bin/lib/br/<module>.sh is missing or unusable on <box> — the box's bin/ is half-synced; no park was drained this tick
```

in `logs/ALERTS.log`. Failing open would drain parks with half a classifier —
every park answered `none`, nothing fixed, and a log line that reads exactly
like a quiet tick.

**How an operator reaches it:** there is no new lane and no new cron line. It is
`bin/blocked-resolver.sh`, the hub's `*/10` drain (`cron/hub.cron`), loading two
more files on startup.

```sh
grep -n '^BR_MODULES=' /root/harness/bin/blocked-resolver.sh
ls /root/harness/bin/lib/br/
```

**How to drive it:**

| what | how |
|---|---|
| the layout contract: ownership, no overlap, nothing missing, the dark byte-identity, nothing runs on source, the refusals | `bash tests/br-split-layout-test.sh` |
| the lane itself is unchanged by the slice | `bash tests/br-ladder-test.sh`, `bash tests/br-rebuild-test.sh`, `bash tests/br-reads-test.sh`, `bash tests/br-neighbors-test.sh`, `bash tests/br-rungs-test.sh`, `bash tests/br-contested-test.sh`, `bash tests/br-rebuild-outcome-test.sh` — the 455 assertions that were `tests/blocked-resolver-test.sh`, one suite per concern since BH-1196. `bash tests/blocked-resolver-test.sh` still runs all seven and prints the same summary line, for one release |
| nothing was dropped when those seven files were cut out of the monolith | `bash tests/br-suite-partition.bh-1196-test.sh` — every section lives in exactly one suite, with the `ok`/`bad` counts `tests/br/expected-sections.tsv` took from the old file before a line moved |
| the ladder, the caps and the rungs the modules copy | `bash tests/blocked-resolver.bh-488-test.sh`, `bash tests/blocked-resolver.bh-614-test.sh`, `bash tests/rebuild-ledger.bh-946-test.sh` |
| the lane still starts with no `HARNESS` in the environment | `bash tests/no-harness-export-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/br-split-layout-test.sh` |

**Fixtures:** a suite that copies `bin/blocked-resolver.sh` into a scratch
harness must install the modules beside it, or the copy refuses its own tick.
That is one call, from one lib, in every such suite:

```sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
```

Since BH-1196 the seven `tests/br-*-test.sh` suites take the WHOLE fixture —
the scratch tree, the sibling libs, the stubbed `PATH`, and the `RUN` / `ROW` /
`ROWST` / `STATEJSON` / `SPENT` helpers — from one lib, which sources
`br-modules.sh` itself, so a fixture change is one edit rather than seven:

```sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_br_harness "$DIR" "$T" || exit 1        # the base harness
fx_br_ladder_git "$DIR" "$T" || exit 1     # + the real local git the ladder runs on
```

The `cp` of the scripts a suite DRIVES stays in that suite's own text, on
purpose: `bin/test-impact.sh` reads rooted `$DIR/...` tokens to decide which
suites a change selects, and a `cp` that moved into the lib would stop selecting
the family when the lane changes.

**The next slices** move the discovery reads (`br_from_*`, the key derivation),
the gates (`br_hold_*`, `br_already_merged`) and the rungs (`br_mechanical`,
`br_fix_round`, `br_adjudicate`, `br_rebuild_*`), each one dark first and cut
after, each one adding its rows to `tests/br/expected-map.tsv`.
