# Hub sync liveness ("the hub has not synced in N hours")

**What it is:** the detector that notices when `bin/harness-sync.sh` has stopped
deploying. It is built out of two stamps the sync itself now writes and one
block in `bin/pipeline-health.sh`.

**Why it exists:** `harness-sync.sh` refuses to deploy a checkout with
uncommitted `bin/`, `prompts/`, `rules/` or `fleet.conf` — deliberately, because
force-resetting a box checkout destroys work. The hole was that the refusal was
one identical ALERTS line per attempt, which the alert-triage deferral spool
swallows, and nothing else noticed: `pipeline-health.sh` check 8 (`driftfail`)
compares the CHECKOUT's HEAD to origin, and `fleet-propagate.sh`'s ff-only pull
keeps that current whether or not the deploy lands. So the hub's LIVE `bin/` sat
frozen for 16 hours with every check green, while `blocked-resolver`,
`merge-conductor` and the rest of the hub crons ran stale code (BH-628).

**The stamps** (`bin/harness-sync.sh`, deploy path only):

| file | written when | contents |
|---|---|---|
| `state/harness-sync-last-success` | the deploy finished, after every rsync | one ISO-UTC line |
| `state/harness-sync-last-refused` | rc 30 (dirty / diverged) or `pull-failed` | ISO-UTC line, then the freshness string that explains it |

`--check` writes NOTHING. It runs before every build on every box in the fleet
(`bin/context-gate.sh`), so a stamping `--check` would make the whole fleet look
like a refusing hub. A transient rc 20 (lock busy, fetch failed) is not stamped
as a refusal either: a network blink followed by a quiet main must not page.

**The detector** (`bin/pipeline-health.sh`, marker block `# >>> hub sync stall`):
fires when a refusal stamp exists and is newer than the last success (or there
is no success at all). Age is `now - last success`. Past `HUB_SYNC_STALL_S` it
calls `alert 3600 hubsyncstall:hub`, so it is ONE line per hour with a growing
hour count rather than one line per 10-minute tick; past `HUB_SYNC_CRITICAL_S`
it additionally raises `lane-alert.sh --critical --id hubsyncstall:hub`
(Telegram, DM when the monitor is off). When a deploy lands it writes exactly
one RESOLVED line to `logs/ALERTS.log` and `logs/pipeline-health.log`, clears
the dedupe key and the `state/hub-sync-stalled` marker, and calls
`lane-alert.sh --resolve`.

**How an operator reaches it:** `cron/hub.cron` runs `bin/pipeline-health.sh`
every 10 minutes on the hub. Output lands in `logs/ALERTS.log` and
`logs/pipeline-health.log`; Mission Control's pipeline pane reads the latter
through `bin/fetch-log.sh which=pipeline`.

**How to drive it:**

| what | how |
|---|---|
| the stamps, whole script against a scratch bare origin + clone | `bash tests/harness-sync-stamps-test.sh` |
| the detector block, extracted verbatim with a pinned clock | `bash tests/pipeline-health-hub-sync-test.sh` |
| the neighbouring blocks in the same file | `bash tests/cost-rollup-liveness-test.sh`, `tests/pipeline-health-detectors-test.sh`, `-closeout-ageout-test.sh`, `-flake-rate-test.sh`, `-permared-test.sh` |
| on a live hub | `cat /root/harness/state/harness-sync-last-success` after the next `fleet-propagate` tick |

**Knobs:** `HUB_SYNC_STALL_S` (default 3600) and `HUB_SYNC_CRITICAL_S` (default
14400) in `env/global.env`; both documented in `env-templates/global.env.example`.
`HARNESS` and `HARNESS_CHECKOUT` override the roots, for tests only — without
the `HARNESS` override a fixture driving the deploy path rsyncs its scratch
checkout straight over the real `/root/harness`.

**What must never regress:**

- **Fail-open.** A refusal stamp whose timestamp will not parse is still a
  stall, with the age reported as unknown. It is not escalated to `--critical`,
  because "unknown" is not "four hours".
- **The negatives stay quiet:** no stamps at all (a fresh box), a refusal older
  than the last success, and a success-only box on a quiet main must all page
  nothing. "Has not synced" only means something after a refusal.
- **One page per hour, not one per tick.** The TTL is what keeps this out of the
  deferral spool that swallowed the original line.
