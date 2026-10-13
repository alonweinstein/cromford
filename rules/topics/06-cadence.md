## Cadence & hygiene

- Cron fires you per project. **Locks in `/root/harness/locks/` are DEDUPE, never a queue** (the operator, 2026-09-13 — "we never lock and serialize"): before launching a build check `locks/build-key-<project>-<KEY>.lock` with `flock -n` and skip that ticket if it is held, because something is already building it. Launch everything else immediately — never wait for another build to finish, and never hold a lock across a build. A box that genuinely needs a ceiling sets `BUILD_SLOTS` in `env/global.env` (0 = unlimited, the default); over the cap a build answers `BUILD_DEFERRED` and is re-offered next tick rather than queued.
- Log a one-line summary per run to `/root/harness/logs/<project>.log` (timestamp, tickets seen, actions taken).
- If a run finds nothing new, exit quietly. Don't manufacture work.
- If something is broken (API down, auth failing, repo diverged), write it to `/root/harness/logs/ALERTS.log` and stop — don't retry-loop.

<!-- CODEGRAPH_START -->
