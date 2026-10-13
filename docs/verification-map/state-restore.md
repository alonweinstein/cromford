# Recover a box's state from R2 (`state-restore`)

**What it is:** `bin/state-restore.sh <box> [ts|latest]` — the operator's one
command between the uploader (`bin/state-backup.sh`, #447) and the merge policy
(`bin/restore-merge.sh`, #446). It lists the box's objects in the bucket, pulls
one, checks its sha256 against the stored object metadata, extracts it in two
steps so `env.tar.age` never reaches the tree that gets merged, decrypts `env/`
when an identity is supplied, prints `meta/checkout-head.txt` and
`meta/crontab.txt`, and hands the tree to `restore-merge.sh`. Dry run is the
default; `--apply` is the only thing that lets anything be written.

**How an operator reaches it:** by hand, on a box or an operator machine. There
is no cron caller and no lock — it is a recovery action, taken with the lanes
fenced. The whole procedure, including the Orgo snapshot layer underneath it, is
[docs/RESTORE.md](../RESTORE.md).

**How to drive it:**

| what | how |
|---|---|
| the whole lane, against a fake bucket and the real merge | `HARNESS_TEST_SANDBOX=1 bash tests/state-restore.bh-449-test.sh` |
| the uploader that produces the object it reads | `HARNESS_TEST_SANDBOX=1 bash tests/state-backup.bh-447-test.sh` |
| the merge policy on its own | `bash tests/restore-merge-test.sh` |
| `--standby` stream mode (a standby's 15-minute pull of its hub: env/ state/ orchestrator/ only, watermark, report) | `HARNESS_TEST_SANDBOX=1 bash tests/state-restore-standby.bh-401-test.sh` |
| what an operator sees first | `bin/state-restore.sh <box>` — one `<ts>  <bytes>` row per backup, exit 1 and `no backups for <box>` when the prefix is empty |
| the plan, without writing | `bin/state-restore.sh <box> latest --live /root/harness` |

The suite runs the real `bin/state-backup.sh` to CREATE the object it then
restores, so the two halves are pinned against each other rather than against a
hand-written tarball. `age`, `zstd` and `aws` are stand-ins when the box has no
real binary; CI sets `AGE_REQUIRED=1` so the real encryption path is the one
that is proven there.

**Files it writes:**

- `<dest>/<box>/<ts>/` — default `$H/tmp/state-restore/<box>/<ts>`. Holds
  `snapshot.tar.zst`, `env.tar.age`, `tree/` (what gets merged) and, on a failed
  decrypt, `env-stage/`. **It contains a decrypted `env/` after a successful
  run.** Outside `--standby` nothing here is ever removed by the tool — an
  existing destination is refused with `already pulled at <path>`, and the
  operator owns the `rm -rf`.
- `--standby` pulls under `$H/tmp/standby-restore` (mode 700; a `--dest`
  outside `$H/tmp/` is refused with exit 2) instead, removes
  its run dir on success, keeps one `<ts>.failed` per hub on failure, and
  writes the watermark `<live>/state/standby-stream.json`.
- whatever `restore-merge.sh` writes under `--apply`: the live tree, its
  `--backup-dir` copies of every replaced ledger/union file, and
  `flags/.alerts-cursor` last.

**Knobs:** the `BACKUP_S3_*` keys in `env/global.env` (shared with the uploader,
see [env-templates/global.env.example](../../env-templates/global.env.example))
plus `BACKUP_AGE_IDENTITY_FILE`, which should be set on an operator machine and
never on a box.

**What must never regress:** the sha256 check happens BEFORE extraction and the
extraction BEFORE the hand-off, so "merged an unverified snapshot" is impossible
by construction. A wrong identity refuses `env/` and still exits 1 after the
merge, so a clean-looking summary can never mean the secrets came back. The
truncated-listing case is real: a bucket answers 1000 keys per page, and reading
page one only would make `latest` the OLDEST object on a busy box.
