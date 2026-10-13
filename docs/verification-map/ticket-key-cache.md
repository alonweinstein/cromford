# Ticket-key cache (the key a park already paid for)

**What it is:** `bin/blocked-resolver.sh` asks gh for a parked PR's head branch
at DISCOVERY (`br_conductor_emit`), which runs before `br_one` installs the
repo's own installation token — so on a repo the default token cannot see, the
branch comes back empty and the candidate arrives with no ticket key.
`br_one` then derives the key inside the token (`br_derive_ticket_key`: the
branch, then the PR title, then the build-record name) and logs
`discovery carried no ticket key — derived <KEY> from the PR/record`. That cost
two `gh pr view` reads and a log line every ten minutes, for as long as the park
lived.

Since BH-487.2 the derived key is written beside the row —
`state/blocked-resolver/<project>/<rkey>.tkey`, one line — by `br_tkey_put`, and
the NEXT discovery reads it through `br_tkey_sync`, which is the key the
candidate carries from then on. Three rules make it safe:

- **gh wins.** When discovery derived a key of its own and the cache disagrees,
  the cache is overwritten on that tick and the tick acts on the gh key. An
  identical cache is not rewritten (no write per park per tick).
- **The shape is the guard.** A cached line only counts if it still passes
  `br_key_shape` — the same guard every other key source passes through. A
  hand-edited `not a key` is ignored (the tick behaves exactly as it did before
  BH-487: PR-number rkey, one `.nokey-alerted` page) and the file is left as
  written; `TK-9` comes back as `TK-9`.
- **Sync never creates.** Only `br_tkey_put` writes the file, so a park that
  never reached `br_one` keeps no cache at all.

The file is deliberately NOT a `*.json`: `br_from_rebuilds` globs
`state/blocked-resolver/*/*.json` and would read a cache as a state row.

**How an operator reaches it:** no UI. On the hub,
`ls /root/harness/state/blocked-resolver/<project>/` shows `<rkey>.tkey` beside
that park's `<rkey>.json` and `<rkey>.nokey-alerted`;
`grep 'discovery carried no ticket key' /root/harness/logs/blocked-resolver.log`
shows the derivation ONCE per park rather than once per ten-minute tick, and the
following ticks name `<project>-<KEY>` in their `EVENT resolver_rung` lines. The
directory is created by the resolver itself, so on a box with no parks it does
not exist and that is the healthy state.

**Primary lanes / scripts:**
- `bin/lib/rebuild-ledger.sh` — `br_cached_tkey`, `br_tkey_put`, `br_tkey_sync`.
  Sourced by the resolver, hard; `$ST` and `br_key_shape` are the resolver's and
  bind at call time.
- `bin/blocked-resolver.sh` — `br_one` puts the key it derived; `br_conductor_emit`
  passes every discovered key through the sync.

**State and flags:** `$H/state/blocked-resolver/<project>/<rkey>.tkey`, one line,
the shaped ticket key. No knob, no env var, no cron of its own — it rides the
resolver's `*/10` lane.

**How to drive it:** `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-948-test.sh`
— the in-process table (put/sync/shape guard, sync-never-creates, identical
cache untouched) plus three end-to-end runs of the real resolver: tick 1 derives
and caches while tick 2 carries the key with no title read, a stale `TK-8` cache
is rewritten to the `TK-9` the branch named, and a `not a key` cache is ignored
with the row landing under the PR-number rkey.

**Verify it works:** that suite reports `54 pass, 0 fail`; on the hub, a park
whose branch the default token cannot see logs the derivation line once and then
grows a `.tkey` file next to its row.

**Manual-only / not automatable:** watching a real token-blind repo across two
live ticks (the fixture simulates the blind discovery by answering an empty
`--json headRefName`).
