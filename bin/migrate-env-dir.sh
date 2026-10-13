#!/bin/bash
# bin/migrate-env-dir.sh — move the harness secrets dir from $HARNESS/env to
# /etc/harness/env, once, by hand (BH-452 / BH-392.2).
#
# OPERATOR STEP, not automation: run `sudo bash /root/harness/bin/migrate-env-dir.sh`
# on each existing box. bin/bootstrap-machine.sh runs it as its first step on a
# fresh box; nothing else in this harness (cron, run-build.sh, fleet-propagate.sh)
# ever calls it.
#
# D-4 copy-then-swap: the files are copied to $DEST.tmp.$$ and permission-fixed
# there, the tmp tree is moved into place, and only then is the old real dir
# swapped for a symlink. A failure before the swap leaves the box exactly as it
# was (the ERR/EXIT trap removes the tmp tree); a failure after it names the
# retained copy on stderr instead of guessing.
#
# Idempotent: the symlink IS the migration marker. A second run prints
# "already migrated" and exits 0. A symlink pointing somewhere else (a Fly/pool
# machine's tmpfs at /run/harness-env) is refused, never rewritten.
#
# Prints counts, paths and modes only — never the content of an env file, and it
# never sources one. bin/harden-state.sh already resolves its ENV_DIR through
# harness_env_dir (bin/lib/env-path.sh), so the new location is armed by the
# existing lane with no change here.
#
# Usage: migrate-env-dir.sh [--harness DIR] [--dest DIR]
# Exit: 0 migrated or already migrated | 1 refused (box untouched) | 2 usage
set -euo pipefail

HARNESS_ARG=""
DEST_ARG=""
usage() {
  echo "usage: migrate-env-dir.sh [--harness DIR] [--dest DIR]" >&2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS_ARG="${2:?--harness needs a directory}"; shift 2 ;;
    --dest)    DEST_ARG="${2:?--dest needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 2 ;;
    *)         echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# A real box migration writes under /etc and chmods secrets: root only. A test
# or a dry operator run that points --harness at its own tree does not.
if [ -z "$HARNESS_ARG" ] && [ "$(id -u)" -ne 0 ]; then
  echo "refusing: must run as root (or pass --harness DIR for a scratch tree)" >&2
  exit 2
fi

HARNESS_DIR="${HARNESS_ARG:-${HARNESS:-/root/harness}}"
DEST="${DEST_ARG:-${ETC_HARNESS_ENV:-/etc/harness/env}}"
SRC="$HARNESS_DIR/env"

if [ -L "$SRC" ]; then
  if [ "$(readlink -f "$SRC")" = "$(realpath -m "$DEST")" ]; then
    echo "already migrated: $SRC -> $DEST"
    exit 0
  fi
  echo "refusing: $SRC is a symlink to $(readlink "$SRC"), not $DEST (pool/tmpfs shape)" >&2
  exit 1
fi

# Fresh box: nothing to copy, just create the new location and the compat link.
if [ ! -e "$SRC" ]; then
  mkdir -p "$DEST"
  chmod 700 "$(dirname "$DEST")" "$DEST"
  ln -s "$DEST" "$SRC"
  echo "created empty $DEST (700), linked $SRC -> $DEST"
  exit 0
fi

if [ ! -d "$SRC" ]; then
  echo "refusing: $SRC exists and is neither a directory nor a symlink" >&2
  exit 1
fi

if [ -e "$DEST" ]; then
  if [ -n "$(find "$DEST" -mindepth 1 2>/dev/null | head -1)" ]; then
    echo "refusing: $DEST already exists and is not empty — inspect it by hand" >&2
    exit 1
  fi
  rmdir "$DEST"
fi

mkdir -p "$(dirname "$DEST")"
chmod 700 "$(dirname "$DEST")"

TMP="$DEST.tmp.$$"
rm -rf "$TMP"
trap 'rm -rf "$TMP"' ERR EXIT
cp -a "$SRC" "$TMP"
find "$TMP" -type d -exec chmod 700 {} +
find "$TMP" -type f -exec chmod 600 {} +

SRC_FILES=$(find "$SRC" -type f | wc -l)
TMP_FILES=$(find "$TMP" -type f | wc -l)
SRC_DIRS=$(find "$SRC" -type d | wc -l)
if [ "$SRC_FILES" -ne "$TMP_FILES" ]; then
  echo "refusing: copied $TMP_FILES of $SRC_FILES files — $SRC left untouched" >&2
  exit 1
fi

mv "$TMP" "$DEST"
trap - ERR EXIT

OLD="$SRC.pre-migrate.$$"
if ! { mv "$SRC" "$OLD" && ln -s "$DEST" "$SRC"; }; then
  echo "FAILED after the copy: $DEST holds the files, original left at $OLD — finish the swap by hand" >&2
  exit 1
fi
# harden-state arms env files +i; rm -rf cannot delete immutable files, and a
# half-removed backup would leave plaintext secrets on disk. Release the flag
# from the whole backup tree before removing it.
if command -v chattr >/dev/null 2>&1 && command -v lsattr >/dev/null 2>&1; then
  chattr -R -i "$OLD" 2>/dev/null || true
fi
rm -rf "$OLD"

echo "migrated $SRC_FILES files, $SRC_DIRS dirs -> $DEST (700 dirs / 600 files), $SRC is now a symlink"
