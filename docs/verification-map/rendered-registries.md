# Rendered registries (cron, env example, rules)

**What it is:** three committed files in this repo are meant to be *rendered*
from fragments rather than hand-edited, and `bin/lib/render-fragments.sh`'s
`rf_registry()` is the one place that says which, from what, and with which
command. `guardrails/rendered-file-freshness/check.sh` is the CI half: a PR that
edits a rendered file and none of its inputs goes red with the fragment dir in
the message.

| rendered | inputs | render command |
|---|---|---|
| `cron/*.cron` | `cron/lanes/` `cron/boxes/` `fleet.conf` `bin/lib/cron-lines.sh` | `bin/render-crontab.sh --from-fragments --all --write` |
| `env-templates/global.env.example` | `env-templates/lanes/` | `bin/render-env-example.sh --write` |
| `rules/CLAUDE.md` | `rules/topics/` | `bin/render-rules.sh --write` |

**What exists at this commit, exactly:** `bin/lib/render-fragments.sh` (the
contract: `rf_fail`, `rf_registry`, `rf_fragments`, `rf_write_atomic`,
`rf_check`) and this guardrail. `bin/render-crontab.sh` exists but takes none of
the flags above — it prints a box's crontab from `fleet.conf` and writes
nothing. `bin/render-env-example.sh` and `bin/render-rules.sh` do not exist yet,
and neither do `cron/lanes/`, `cron/boxes/`, `env-templates/lanes/` or
`rules/topics/`. The commands in the table are the registry's spelling of what
each renderer will answer to when its slice lands (#559, #560, #561); nothing
here claims they run today.

**Exit codes every renderer answers with** (the contract's convention, from
`bin/lib/render-fragments.sh`): `0` rendered, or `--check` found no drift; `1`
`--check` found drift; `2` cannot render — missing or empty fragment dir, bad
arguments, and any render failure under `--check`, so a renderer that did not
run never reports "no drift"; `3` a fragment was refused, with file and line on
stderr.

**How an operator reaches it:** it is CI, not a screen. In the `lint` job of
`.github/workflows/harness-ci.yml`, step
*"rendered files are edited through their fragments"*, `pull_request` events
only, on a checkout with `fetch-depth: 0`. The PR's Checks tab is where an
operator sees it. On a box it is a shell command:

```sh
guardrails/rendered-file-freshness/check.sh origin/main     # what CI runs
RFF_FILES=list.txt guardrails/rendered-file-freshness/check.sh
RFF_MAP_FILE=rows.txt RFF_ROOT=/path/to/repo guardrails/rendered-file-freshness/check.sh
```

**What it prints on this checkout today:** `none of the rendered registries is
adopted in . yet — not adopted, nothing to keep fresh.`, rc 0. Adoption is per
row and is read off the checkout, so each row turns itself on the day its
fragment dir lands.

**How to drive it:**

| what | how |
|---|---|
| the guardrail — every fire, every must-not-fire, adoption, the escape hatch, the map knobs | `HARNESS_TEST_SANDBOX=1 bash tests/guardrails-test.sh` (the `rendered-file-freshness` section) |
| the contract the default map is compared against | `HARNESS_TEST_SANDBOX=1 bash tests/render-fragments-test.sh` (section A5 pins `rf_registry`) |
| a seeded violation, by hand | `R=$(mktemp -d); mkdir -p $R/cron/lanes; RFF_ROOT=$R RFF_FILES=guardrails/rendered-file-freshness/fixtures/changed-stale.txt guardrails/rendered-file-freshness/check.sh; echo rc=$?` → rc 1, naming `cron/lanes/` |

**What must never regress:**

- **One spelling of the registry.** The default map baked into `check.sh` lives
  between `# >>> rff default map` / `# <<< rff default map` and is diffed
  against `rf_registry()` by the suite. Change the registry and the guardrail
  follows in the same PR, or the test goes red.
- **Adoption is a fact about the checkout or the base, never about the diff.**
  A row is adopted when its first input exists in the checkout OR at the base
  ref (`git ls-tree`), so a PR that deletes a fragment dir and hand-edits the
  rendered file cannot report "not adopted" and pass (G20 in the suite).
- **Every no-op is printed.** Unreadable list, unreadable map file, failed diff,
  unadopted row: rc 0 with a line saying which. A check that could not run must
  never read as a check that passed.
- **The escape hatch stays a label *and* a written reason**, taken from the
  `Guardrail-Justification:` marker line — never from the raw PR body.
