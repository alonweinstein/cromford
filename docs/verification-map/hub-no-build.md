# The hub runs no agent build work

**What it is:** `bin/lib/hub-box.sh`, and the entry points that ask it
whether this box may run agent build work. Four refuse, and
`bin/blocked-resolver.sh` hops its fix round to the owning box instead. It
turns the hub-thinning policy (docs/HUB-THINNING-PLAN.md, the operator 2026-08-24) into a control, after ten `up10`
self-improvement lanes were found executing on the hub when `/root/harness` was
wiped on 2026-09-15 (incident #388).

**How an operator reaches it:** it is not a cron lane — it is a guard inside
four scripts, each marked `# >>> hub-no-build` / `# <<< hub-no-build` where it
is a block:

| Script | Where | Refuses as | Result |
|---|---|---|---|
| `bin/agent-call.sh` | right after `STAMP()`, before the runner is resolved | the stage argument | rc **77**, `AGENT_CALL_REFUSED hub-no-build …` written to the outfile. No cost row, no phase row, no beat |
| `bin/run-build.sh` | right after `env/global.env` is sourced — i.e. AFTER the Fly enqueue, which is the hub's legitimate job | `build` | rc **3**, `BUILD_REFUSED hub-no-build …` in `$BUILD/RESULT`, naming `bin/box-for.sh`'s answer |
| `bin/run-preplan.sh` | right after `env/global.env`, before `PLANDIR` is created | `preplan` | rc **3**, a line in `logs/preplan.log`, no `plans/<project>-<KEY>` dir |
| `bin/up10-lane.sh` | the `--here` branch | `up10` | rc **77**, and **no override** |
| `bin/up10-lane.sh` | the owning-box resolution, before the hop | `up10` | rc **2** when `bin/box-for.sh` answers `local` OR any of the hub's names — the hub is never the owner, from any box |
| `bin/blocked-resolver.sh` | `br_fix_round`, after admission (cap, observe, slot gate) and before any git work | — (`hub_box_builds_here`, no ALERTS line) | **never refuses: hops.** `br_fix_remote` ssh's the owning box and runs `--fix-here` there; an owner that is `local`/the hub, no tailnet address, or no `FIX_RESULT` back is a `br_setup_blocked` (no rung spent). agent-call rc 77/78 inside a fix round is a setup block too (BH-594) |

**How to drive it:**

| what | how |
|---|---|
| all four, plus the lib | `bash tests/hub-no-build-lanes-test.sh` |
| the real `agent-call.sh`, against a scratch `$HARNESS` with a fake `claude` | section 2 of that suite |
| the `run-build.sh` / `run-preplan.sh` blocks, extracted verbatim by their markers | sections 3 and 4 |
| `up10-lane.sh`, with ssh, gh, `box-for.sh`, `fleet-conf.sh` and `run-build.sh` all stubbed | section 5 |
| the ssh hop mints its token and PATH on the far side, never on the hub | `bash tests/up10-remote-token-test.sh` |
| the resolver's fix-round hop, `--fix-here`, and rc 77/78 as a setup block, on a real local git with a fake ssh | `bash tests/blocked-resolver.bh-594-test.sh` |
| the neighbours that drive the same scripts | `bash tests/agent-call-notools-test.sh`, `tests/claim-rules-test.sh`, `tests/no-serialize-test.sh` |

**Files it owns on a live box:**

- `logs/ALERTS.log` — one `[hub-no-build] refused <lane> <ticket> on <box> — …`
  line per refusal.
- `flags/alerted-hub-no-build-<lane>-<ticket>-<YYYYMMDD>` — the per-UTC-day
  dedupe marker. `bin/preplan-tick.sh` fires every 2 minutes on the hub, so
  without it a single refused project writes 720 lines a day.
- `logs/up10.log` — one line per `up10-lane.sh` run: the hop, or the launch, or
  the refusal.

**Knobs:** `HUB_BUILD_OK`, `HUB_NO_BUILD_LANES`, `HUB_BOX_NAME`, all in
`env/global.env`. See `env-templates/global.env.example` and
docs/OPERATOR-SETUP.md ("The hub runs no agent build work").

**What must never regress:**

- **A missing lib fails OPEN.** A box mid-sync that has not received
  `bin/lib/hub-box.sh` behaves exactly as it did before this shipped
  (`command -v hub_no_build_refuse || hub_no_build_refuse() { return 1; }` in
  all three guards). A guard that failed closed on its own absence would take
  every build lane in the fleet down with one bad rsync. `up10-lane.sh` is the
  deliberate exception: its fallbacks still refuse on the hub, because the hub
  local path is the thing the incident was.
- **An empty box name is not the hub.** `is_hub_box ""` is false, and
  `box-hub0` must not prefix-match `box-hub`.
- **The hub is refused by identity, not by spelling.** `bin/up10-lane.sh` asks
  `is_hub_box` about `bin/box-for.sh`'s answer, so fleet.conf column 6 naming
  the hub as `box-hub` (or whatever `HUB_BOX_NAME` says) fails closed
  the same way `local` does — otherwise owner == local box on the hub and the
  local-path shortcut runs there, which is the incident. The refusal happens on
  the box that resolved the owner, not after an ssh to the hub.
- **The refusal is loud and rc-bearing**, never a silent rc 0 — the caller must
  be able to tell a refusal from an answer, which is why `$OUT` carries the
  `AGENT_CALL_REFUSED` marker rather than whatever a previous attempt left there.
- **The hop's remote command mints its own credential, on the target.** The ssh
  string sets `PATH` and then `GH_TOKEN=$(/root/harness/bin/gh-token.sh <repo>)`
  on the far side; the hub never resolves a token for the hop, and the token
  value never appears in the ssh argv, in `ps` on either side, or in
  `logs/up10.log`. `bash tests/up10-remote-token-test.sh` runs the real script
  with a fakessh that EXECUTES the remote string under `env -i` and reads back
  what the far side's `gh` ran on. (BH-639, 2026-09-17: a BatchMode ssh carries
  no GH_TOKEN and no PATH, so the far side's dedupe read fail-closed and every
  orchestrator-turn up10 launch died there.)
- **`state/box-name` missing on the hub** makes `bin/box-name.sh` fall through
  to the hostname (`box-hub`), which is NOT the hub's
  fleet name, so the guard fails open. `bin/box-name.sh --write` at sync time is
  what makes the file exist; it already does in production.
