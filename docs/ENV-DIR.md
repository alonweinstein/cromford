# Env directory contract

Harness secrets live outside the repo tree. The canonical location is
`/etc/harness/env/`. `/root/harness/env/` is a compat symlink for this release
and will be removed in the next release.

## What is in there

- `global.env` — box-wide variables (API keys, alert endpoints, model prices).
- `<project>.env` — per-project overrides.
- `accounts.d/` — service account pick lists.
- `tokens.d/` — short-lived token cache.
- `fly.env` — Fly.io pool secrets copied to pool machines.

All regular files are mode `0600`. All subdirectories are mode `0700`. The
directory itself is owned by `root:root` mode `0700`.

## How scripts resolve the directory

Scripts source `bin/lib/env-path.sh` and call `harness_env_dir` with the
script's harness root. Set `$H` to the caller's root before pasting; for
example, `H="${HARNESS:-/root/harness}"`.

```bash
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
```

That is the canonical sourcing snippet. Port slices must paste it verbatim.
The `$(dirname ...)` fallback lets a script in `bin/` find the library when
`$HARNESS` is not set, and the inline fallback keeps unported scripts and
scratch-tree tests working when the lib is not present.

Precedence, highest first:

1. `HARNESS_ENV_DIR` if it is set and non-empty.
2. `$HARNESS/env` if it exists and is a real directory (not a symlink).
3. `${ETC_HARNESS_ENV:-/etc/harness/env}` if it exists as a directory.
4. Otherwise fall back to `$HARNESS/env`.

The `HARNESS` default is `/root/harness`. `ETC_HARNESS_ENV` is for tests and
non-standard installs.

## Fly pool machines

`fly/entrypoint.sh` exports `HARNESS_ENV_DIR=/run/harness-env` so every process
on a pool machine uses the tmpfs directly. The symlink at `/root/harness/env`
exists only for unported readers during the transition.

## Remediator policy

`bin/remediator-settings.json` denies `Read/Edit/Write` on both
`/root/harness/env/**` and `/etc/harness/env/**` during the symlink release.
