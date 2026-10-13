---
name: migration-judged-apply
description: Apply a merged migration SQL file to a product app's production database through its own /api/internal/migrations/apply endpoint — deploy gate first, classifier verdict respected, verified against the app's own ledger, one ALERT and stop on failure. Use when a migration is pending, an apply was refused or flagged, or someone asks to "apply the migration" / "why is this migration stuck".
---

# migration-judged-apply

The fleet never holds a database credential. Every schema change is applied by the
app itself, from the SQL already baked into its **deployed bundle**, triggered by a
filename over an internal-token-gated endpoint. This skill is the procedure for
driving that by hand, and for judging the cases the automation deliberately parks.

Spec: `docs/MIGRATION_ENDPOINT_SPEC.html`. Automation that already does this:
`bin/migration-autopilot.sh` (allowlisted files, post-deploy) and
`bin/apply-migrations.sh` (cron `*/15`, pending-file sweep). **Check whether the
autopilot already owns the file before doing anything by hand** — see step 0.

## Iron laws (these bind you, not just the scripts)

1. **Never apply before the deploy that carries the code serves.** A file only
   becomes addressable once it is in the running bundle, so the schema can never
   land ahead of the code that reads it. Verify the serving sha *contains* the
   merge commit — do not infer it from "the PR merged a while ago" (TK-64: finance
   tables sat unapplied for days while deployed code threw on every load).
2. **Additive only.** `ADD COLUMN IF NOT EXISTS`, new tables, new named
   constraints, new indexes, new enum values. Re-running must be a no-op.
3. **Every new table gets `ALTER TABLE … ENABLE ROW LEVEL SECURITY` plus
   `REVOKE ALL … FROM anon, authenticated` in the same migration.** A wave that
   creates no table has no RLS step — say so rather than skipping silently.
4. **A classifier-FLAGGED file is never auto-applied.** Flagged means a human reads
   the SQL first. You may apply it by hand *after* reading it and judging it safe,
   and you say in the record that you did so and why.
5. **Verify after apply, against the app's own status ledger — never the apply
   response.** `{ok:true}` is a claim; the ledger listing the filename is proof.
6. **On failure: ONE actionable `ALERTS.log` line, then stop.** Never retry-loop.
   Migrations inside a project are order-dependent, so a failure stops the whole
   sequence, not just the failing file. A refusal is deterministic per checksum —
   re-POSTing an unchanged file can only re-fire the alert (the 2026-08-06 pb67
   alert storm is exactly this).
7. **You never touch a production database directly.** No `prisma db push`, no
   `psql`, no Supabase SQL editor from this box. The endpoint or nothing.

## Wiring (never guessed — read it, per project)

Env lives in `/root/harness/env/global.env` + `/root/harness/env/<project>.env`
(chmod 600, never in git; keys documented in `env-templates/project.env.example`).
Two separate least-privilege secrets:

- `MIGRATION_TOKEN` — the `status` / `apply` endpoints.
- `<PREFIX>_INTERNAL_API_TOKEN` — the `/api/internal/version` endpoint only.

App base URLs, as `bin/migration-autopilot.sh` maps them:

| project | base var | version token var |
|---|---|---|
| project-1 | `PROJECT_1_API_BASE` | `PROJECT_1_INTERNAL_API_TOKEN` |
| project-2 | `PROJECT_2_APP_BASE` | `PROJECT_2_INTERNAL_API_TOKEN` |
| project-3 | `PROJECT_3_APP_BASE` | `PROJECT_3_INTERNAL_API_TOKEN` |
| project-4 | `PROJECT_4_API_BASE` | `PROJECT_4_INTERNAL_API_TOKEN` |

A project not in that table has no wiring. Stop and say so; do not guess a base URL.

```bash
P=project-2                                   # the project
set -a; . /root/harness/env/global.env; . /root/harness/env/$P.env; set +a
BASE="$PROJECT_2_APP_BASE"                               # from the table above
MIG() { curl -sf -m 60 -H "Authorization: Bearer $MIGRATION_TOKEN" -H 'User-Agent: curl/8' "$@"; }
```

## Procedure

### 0. Is this already owned by the automation?

```bash
( . /root/harness/bin/jobs-client.sh; job_ledger_get migration "$P <file>" ); echo "rc=$?"  # rc 0 = row (status printed), 2 = none, 1 = could not ask
cat /root/harness/state/migrations-refused-$P.txt                # terminal refusals
tail -30 /root/harness/logs/migrations.log
grep -i migration /root/harness/logs/ALERTS.log | tail -10
```

A file whose `ledgers(kind=migration)` row reads `applied` is done. A file whose
row reads `flagged`, or that is listed in `migrations-refused-*`, is parked *on
purpose* and is waiting for the judgement you are about to make. Never clear that
row or that file to "make it retry" without first establishing why it failed.

### 1. What does the app say is pending?

```bash
MIG "$BASE/api/internal/migrations/status" | jq '{applied: [.applied[]?.filename] | length, pending: [.pending[]? | {filename, statements}]}'
```

`status` compares the deployed bundle's `scripts/migrations/` against the app's
`MigrationApplied` ledger. An **empty pending list on an app you know has a new
file** usually means the file is not in the bundle: Vercel serverless functions do
not include arbitrary repo files, so the app's `next.config` needs
`outputFileTracingIncludes` for `scripts/migrations/**`. That failure mode is
fail-safe (nothing to apply, nothing breaks) and it is a repo fix, not an apply.

project-4 answers a multi-target shape (`{targets:{prod:{applied:[…]},…}}`); every
target must list the file before you call it applied.

### 2. Deploy gate — is the code serving?

```bash
MC=$(gh pr view <PR#> -R <owner/repo> --json mergeCommit -q .mergeCommit.oid)
SERVING=$(curl -sf -m 20 -H "Authorization: Bearer $PROJECT_2_INTERNAL_API_TOKEN" -H 'User-Agent: curl/8' \
          "$BASE/api/internal/version" | jq -r '.sha // empty')
git -C /root/repos/$P fetch -q origin
git -C /root/repos/$P merge-base --is-ancestor "$MC" "$SERVING" && echo "SERVING" || echo "NOT SERVING YET — wait"
```

`NOT SERVING YET` is not a failure. Wait for the deploy and re-check; the autopilot
re-checks every 15 minutes on its own.

### 3. Classifier verdict — read it, do not skip it

```bash
git -C /root/repos/$P show "$MC:scripts/migrations/<file>.sql" > /tmp/mig/<file>.sql
bin/check-migration-appliable.sh "$P" /tmp/mig /tmp/mig/<file>.sql; echo "exit=$?"
```

Exit 0 = inside the conservative allowlist (CREATE TABLE, CREATE [UNIQUE] INDEX,
single-action `ADD COLUMN`, bare named `ADD CONSTRAINT`, `ENABLE ROW LEVEL
SECURITY`, the `ALTER COLUMN x TYPE TEXT USING x::text` self-cast, `REVOKE`).
Exit 1 = FLAGGED, with a reason per statement.

The two flags you will actually meet:

- **`DO $$ … $$` block** — the endpoint classifier refuses procedural guards
  (TK-90 stalled ~8h on exactly this). The fix is to rewrite the SQL: put the
  constraint INLINE in the `CREATE TABLE`, use `ADD COLUMN IF NOT EXISTS`, use a
  named `ADD CONSTRAINT` (the executor treats duplicate-constraint 42710 as
  applied). That is a PR against the app repo, not a hand-apply.
- **`GRANT … TO anon/authenticated`** — breaks the deny-by-default RLS posture.
  Do not apply it. Report it.

`DROP` / `TRUNCATE` / `DELETE` are never applied from this box, by anyone, ever.

### 4. Apply

```bash
RES=$(curl -sf -m 300 -X POST \
  -H "Authorization: Bearer $MIGRATION_TOKEN" -H 'Content-Type: application/json' -H 'User-Agent: curl/8' \
  -d "$(jq -nc --arg f '<file>.sql' '{filename:$f, actor:"human:<who>"}')" \
  "$BASE/api/internal/migrations/apply")
jq '{ok, status, alreadyApplied, flagged: (.flagged//[]|length), rls: (.rlsWarnings//[]|length), last: (.perStatement//[]|last)}' <<<"$RES"
```

The endpoint takes a **filename only** — SQL never travels. `actor` is free text;
name yourself (`human:<name>`), not `watcher`/`autopilot`, so the ledger records who
decided. Response statuses: `applied`, `already-applied` (idempotent no-op),
`in-progress` (another caller owns it — do nothing, re-check), `refused` (terminal
for this checksum), `checksum-mismatch` (a merged file was edited after it was
applied — a human must look, do not re-apply), `failed`.

### 5. Verify — the ledger, and the feature

```bash
MIG "$BASE/api/internal/migrations/status" | jq --arg f '<file>.sql' '[.applied[]?.filename] | index($f) != null'
```

`true` or it did not happen. Then prove the schema is *usable*, not merely recorded:
load the screen or hit the route that reads the new tables/columns and confirm it
renders real rows instead of throwing. A migration is not "done" because a POST
returned 200 — it is done when the feature it unblocks works.

### 6. Record it

```bash
tail -5 /root/harness/logs/migrations.log
```

Say plainly in your run summary / board comment: which file, which PR, the serving
sha, the classifier verdict, and what you verified — SELECT, screen, or both. If you
hand-applied a FLAGGED file, say that and say why it was safe.

## On failure

Write exactly ONE line and stop:

```bash
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$P] MIGRATION NEEDS HUMAN: <file>.sql (PR #<n>) — <what failed, verbatim status/reason> — needs <the specific action, from whom>" \
  >> /root/harness/logs/ALERTS.log
```

Name the action and the authority it needs ("owner must run this in the Supabase
dashboard", "app repo needs `outputFileTracingIncludes`"). A question asked into
your own run log is indistinguishable from silence. Then stop — no second attempt,
no next file in the sequence.
