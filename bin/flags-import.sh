#!/bin/bash
# bin/flags-import.sh [--dry-run] — BH-4153: move this box's legacy flag files
# for the ported families (paused-*, automerge-disabled[-*], lanedown-*) into
# their harness_flags rows, then delete each file.
#
# Per file (_flag_import_one in bin/lib/jobs/flags.sh): a row whose
# cleared_at // set_at is at or after the file's mtime wins (BH-1370) and the
# file goes; otherwise the row is PUT active with set_by flags-import:<box> and
# a reason naming the file, read back, and only then is the file removed. A
# failure keeps the file, and a kept file is still honoured (flag_has reads it
# as a local hold). Idempotent: a second run finds no file and writes nothing.
#
# Only a flag this box OWNS is published (_flag_owned): paused-<p> and
# automerge-disabled-<p> for a <p> fleet.conf puts on this box, the fleet
# automerge-disabled on the hub, and lanedown-*. A file only ever paused the box
# it sat on, so any other one (a stray from a failed PUT, an old quiesce) is
# reported kept-local and left as this box's local hold, never made fleet-wide.
#
# Output, one line per file: imported <name> <scope> | kept-row <name> |
# kept-local <name> not-owned | failed <name> <why> | would-import <name> <scope>;
# or `nothing to import`.
# Exit 0 all done, 1 any failure, 75 no jobs client or worker unreachable
# (nothing touched). Runs daily from bin/update-runners.sh, by hand, and lazily
# from flag_has.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
DRY=""
case "${1:-}" in
  --dry-run) DRY=--dry-run ;;
  "") ;;
  *) echo "usage: flags-import.sh [--dry-run]" >&2; exit 2 ;;
esac
# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" 2>/dev/null || { echo "flags-import: bin/jobs-client.sh did not load"; exit 75; }
if [ -z "$DRY" ] && ! _flag_db_configured; then
  echo "flags-import: no worker configured (JOBS_URL or HARNESS_SECRET empty), nothing touched"
  exit 75
fi
N=0; RC=0
for F in "$(_flag_dir)"/*; do
  [ -f "$F" ] || continue
  NAME=${F##*/}
  _flag_ported "$NAME" || continue
  N=$((N + 1))
  _flag_import_one "$NAME" $DRY; R=$?
  case "$R" in
    0) ;;
    75) RC=75; break ;;   # the worker is gone: every other file would fail the same way
    *) RC=1 ;;
  esac
done
[ "$N" -gt 0 ] || echo "nothing to import"
exit "$RC"
