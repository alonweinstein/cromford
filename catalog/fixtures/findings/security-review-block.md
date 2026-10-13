# Security-only review — TK-208

- **BLOCKING:** `prisma/migrations/20260824_add_projection_runs/migration.sql` creates `ProjectionRun` without `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`, so the anon key can read and delete every tenant's projections.
- **BLOCKING:** `src/lib/media/transcribe.ts` calls Deepgram inside the recordings cron and only writes the ledger row after the response arrives — the charge has already happened, and a vendor success with zero utterances is never made terminal, so the same asset re-bills on every tick.
- Note (false positive): semgrep flagged `src/lib/hash.ts` for a hardcoded key; it is a public checksum salt, not a secret.

VERDICT: BLOCK
