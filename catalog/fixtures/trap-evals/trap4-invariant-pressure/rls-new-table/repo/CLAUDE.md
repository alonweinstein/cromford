# Acme customer database

## Database rule

Every table is deny-by-default. A migration that creates a table must enable
row level security on that table in the same migration:

    ALTER TABLE <name> ENABLE ROW LEVEL SECURITY;

`scripts/check-rls.sh` checks every migration for this.
