# Review tier (how much review a diff buys)

**What it is:** `bin/lib/review-tier.sh`, read by the `# >>> review lenses`
block of `bin/run-build.sh`. Before a single lens is launched, the diff is
classified from its own file list — **T0** docs/tests/CI-config, **T1** product
code with no risky paths, **T2** schema/auth/billing/migrations/money — and the
tier decides four things: which lenses run, which model the general lens runs
on, whether it gets the "static review, no build run" prompt variant, and how
many lens fix rounds the build may buy (BH-485).

| tier | lenses | review model | fix-round cap |
|---|---|---|---|
| T0 | `review` only | `REVIEW_MODEL_T0` (defaults to `REVIEW_MODEL`) | 1 |
| T1 | `review` (+ `security` if RISKY>0, which at T1 it is not) | `REVIEW_MODEL` | 2 |
| T2 | `review` + `security` if RISKY>0 + `refute` if HIGHRISK>0 — today's set | `REVIEW_MODEL` | 0 = uncapped, as today |

**T2 is decided first, and absence is T2.** A `.sql` or `migrations/` path
forces T2 wherever it sits, including under `tests/`; a README beside a
migration is T2. An empty or unreadable file list, a path carrying `..`, a
missing or unsourceable lib, and a line the caller cannot parse all answer T2
with today's `RISKY`/`HIGHRISK` lens set and uncapped rounds — a box whose
`bin/lib/` has not synced behaves exactly as it did before this existed.

**Where the ticket's two lists overlap** (`tests/gh-token-test.sh` is in T0's
path list and matches T2's `token` pattern), the split is: the schema/money
class (`schema.prisma`, `prisma/schema/*.prisma` at any depth, migrations,
`.sql`, billing/money names) forces T2 anywhere, the name-based risky extras (middleware, auth,
permission, role, token, webhook) force T2 only on a path that is not itself
docs/tests/CI-config.

**How an operator reaches it:** it runs inside every build, and it is also a CLI.

```sh
bin/lib/review-tier.sh <base> <head>      # from a repo checkout, prints one line
bin/lib/review-tier.sh main HEAD          # -> T1 reason=product code, no risky paths
```

**Files it names on a live box:**

| file | what it holds |
|---|---|
| `builds/<record>/review-tier.txt` | one line — `REVIEW-TIER T0 reason=… lenses=… cap=…` — written before the first lens call |
| `builds/<record>/pipeline.log` | the same line with `model=…`, plus `FIX-ROUND CAP <n> reached at tier <T>` on a build that hit its cap |
| the PR body's Evidence block | the `\| review depth \|` row, rendered by `bin/evidence-summary.sh` only when `review-tier.txt` exists |

`review-tier.txt` is a **record, never an input**: it is recomputed from the
diff on every run, and a record missing one simply renders no row.

**Knobs:** `REVIEW_MODEL_T0` in `env/global.env` (unset = `REVIEW_MODEL`, so the
knob is inert until an operator sets it). No new required env var — an unset
`REVIEW_MODEL_T0` changes nothing anywhere.

**How to drive it:**

| what | how |
|---|---|
| the classifier table, including every negative that must never be T0 | section A of `bash tests/review-tier-test.sh` |
| the wired block — which lenses are actually CALLED per tier | section B (drives the extracted `# >>> review lenses` block with a stubbed reviewer) |
| the T0 prompt variant, and that a T1 diff never gets it | section C |
| the model tier, and that it is inert when unset | section D |
| the fix-round caps, on both the parallel and the sequential path | section E |
| `pipeline.log` + `review-tier.txt`, written before any lens ran | section F |
| the PR-body row, and that it stays out of the `Digest:` string | section G |
| that nothing else moved: HARNESS-VERIFY still runs at T0, all three terminals still fire, a missing lib falls back to today's behaviour | section H |
| the lens flow this sits in front of | `bash tests/parallel-lenses-test.sh` |

**What must never regress:**

- **A cheaper tier never buys away ground truth.** The repo suite the harness
  runs itself (`HARNESS-VERIFY` → `harness-suite.txt`), the tamper scan,
  semgrep, the static guards, the iron-law scan and the mechanical gates run at
  every tier. The tier touches the LLM lenses and nothing else.
- **The three terminals are unchanged.** A lens that still refuses exits
  `REVIEW_BLOCKED` / `SECURITY_BLOCKED` / `REFUTE_BLOCKED`, capped or not — the
  cap skips the fix ROUND, never the adjudication.
- **`RISKY=` and `HIGHRISK=` in `bin/run-build.sh` are the one definition of
  risky.** The lib copies those two regexes verbatim; section A fails if either
  drifts.
- **No `claude-*` model string anywhere in the tier path.** The T0 model is one
  env line, resolved like every other model in `bin/run-build.sh`.
- **The fix-round count comes from the build dir's own `fix-run.txt`,
  `security-fix-run.txt`, `refute-fix-run.txt`** — the same three
  `bin/evidence-summary.sh` counts, and deliberately not `qa-fix-run.txt`, which
  is a different stage's round.
