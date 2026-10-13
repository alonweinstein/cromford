Master BH-3966 (Archie rollout), split into 6 waves.
Wave 2 ticket BH-4063 is next.
- Wave 1 BH-4062: PR merged to main.
- BH-4063 says "Blocked-by: BH-4062" and reads the `initiatives` table, which
  is in worker/jobs/schema.sql on main.
- BH-4063's plan touches only the files the master lists for wave 2. Nothing
  from the master's "Out of scope" list appears in it.
