# Standby hub (warm standby for the hub lease)

**What it is:** `bin/standby-install.sh <box>` turns a registered fleet box into
a warm standby hub (#401). It writes `/etc/cron.d/harness-standby`: every hub
lane, each behind `/root/harness/bin/hub-lease.sh check && `, so the lanes stay
inert while the hub holds the lease and fire on the standby once it lapses. The
file ends with one stream line,
`10,25,40,55 * * * * root /root/harness/bin/hub-lease.sh check || /root/harness/bin/state-restore.sh <hub-id> latest --apply --standby >> /root/harness/logs/standby-stream.log 2>&1`,
which keeps pulling the hub's latest state snapshot for as long as `check` is
false. The registry side is a comment directive in `fleet.conf`,
`# @standby <box> <hub-name> <hub-id>`, read by `bin/fleet-conf.sh --standby`
and `--standby-of <box>`. It starts with `#`, so every positional reader of
`fleet.conf` skips it.

What the render drops, and why: comments, blanks and `@reboot` lines; any line
with `watchdog-ping.sh` or `/api/ping/` (the standby would ping AS the hub); and
any hub lane whose command, gate stripped, byte-equals a command the box's own
crontab already runs (it would run twice). The hub's ungated
`hub-lease.sh renew` line comes out as `check && renew`, so the standby never
takes the lease on its own. Env lines are kept verbatim, in hub order. Like
`bin/render-crontab.sh`, the render does not parse shell: on a line with a
top-level `;` or `||` the gate covers only the first command.

**How an operator reaches it:** the console's /hub page has a read-only
STANDBY section (BH-2641) between ROLE and BACKUPS: one row per standby
heartbeat from the `standbys` array of `GET /api/hub/recovery`, and "No standby
has reported a heartbeat yet." while that array is absent. Installing still
happens on the standby box itself:

- dry run, prints the file and writes nothing:
  `/root/harness/bin/standby-install.sh box-small`
- install (tmp + `mv`, mode 644), then `state/standby-of` = `<hub-name> <hub-id>`:
  `/root/harness/bin/standby-install.sh box-small --apply`
- also record the directive in a fleet.conf (replaces any line for that box):
  `... --conf /root/harness-checkout/fleet.conf`
- read the registry: `bin/fleet-conf.sh --standby`,
  `bin/fleet-conf.sh --standby-of box-small`

Defaults: `--hub-name` = `hub_box_name` (`HUB_BOX_NAME`, else `box-hub`),
`--hub-id` = `hub`, `--root` = `/root/harness-checkout` (where
`bin/render-crontab.sh` renders the hub's and the box's own crontab, the latter
keyed by `state/box-id`), `--cron-file` = `/etc/cron.d/harness-standby`. It is
not the user crontab because `bin/update-runners.sh` reinstalls that daily.

**Preconditions:** the box has a `fleet.conf` row with a tailnet IP; it is not
the hub; with `--apply`, `bin/box-name.sh` on the box answers that box's name;
`BACKUP_S3_ENDPOINT`, `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY`
are set and `BACKUP_AGE_IDENTITY_FILE` is readable (from `global.env`); the
cron.d directory exists and `cron` is running. Any miss is a refusal: rc 1, one
`standby-install: refused: <what>` line on stderr, and with `--apply` one
`[standby-install] REFUSED <box>: <what> — needs <who>` line in `logs/ALERTS.log`.
Nothing is written on a refusal. Missing env is reported by name, never value.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/standby-install.bh-401-test.sh`
drives the CLI end to end in a scratch tree: fixture render (drops, prefix once,
renew gated, env order), every refusal, `--apply` (mode 644, stream line last,
`state/standby-of`), `--conf` idempotence, the `fleet-conf.sh` flags, and one
smoke run through the real `render-crontab.sh`. The failover side is pinned by
`tests/watchdog-failover.bh-401-test.sh` (the watchdog's standby/failover KV
contract). The `state-restore.sh --standby` mode the stream line calls belongs
to a sibling slice of #401 and has no suite on this branch yet.

**Manual-only / not automatable:** installing on a real standby box (`--apply`
as root writes `/etc/cron.d`) and a real failover (the hub going dark long
enough for its 180 s lease to lapse). Neither is driven by any test here.
