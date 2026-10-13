#!/bin/bash
# bin/archie-followup.sh — BH-4063 (BH-3966.2): Archie's self-scheduled
# follow-ups, a thin CLI over bin/lib/archie-wake.sh.
#
#   archie-followup.sh add <3d|YYYY-MM-DD> <note> [--initiative I<n>]
#   archie-followup.sh list
#
# add writes ONE ledger row (kind archie_followup, key fu-<sha8>, status
# pending, detail {due_at, initiative_id, note}); the same follow-up asked twice
# on one day is the same row. The archie tick wakes the initiative (or
# factory-watch when none is named) on the first tick at or after due_at, then
# puts the row `fired`. Rows are never deleted.
#
# Exit: 0 written (or already there), 2 bad input (nothing written), 1 the jobs
# ledger did not answer. Note: docs/notes/2026-10-04-BH-4063-archie-wakeups.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/archie-wake.sh" 2>/dev/null || true
}
# The suite's seam, the same one bin/archie.sh honours. Sandbox only.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FIXTURE"
fi
command -v archie_followup_add >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 \
  && command -v jq >/dev/null 2>&1 || { echo "archie-followup: bin/lib/archie-wake.sh, jobs-client or jq missing" >&2; exit 1; }
export HARNESS="$H"

usage() { echo "usage: archie-followup.sh add <3d|YYYY-MM-DD> <note> [--initiative I<n>] | archie-followup.sh list" >&2; exit 2; }

case "${1:-}" in
  add)
    shift
    [ "$#" -ge 2 ] || usage
    WHEN=$1 NOTE=$2 INI=""
    shift 2
    case "${1:-}" in
      --initiative) [ -n "${2:-}" ] || usage; INI=$2; shift 2 ;;
      '') ;;
      *) usage ;;
    esac
    [ "$#" = 0 ] || usage
    OUT=$(archie_followup_add "$WHEN" "$NOTE" "$INI"); RC=$?
    case "$RC" in
      0) printf 'Follow-up %s set for %s%s: %s\n' "$(cut -f1 <<<"$OUT")" "$(cut -f2 <<<"$OUT")" \
           "${INI:+ on I${INI#[Ii]}}" "$NOTE" ;;
      2) ;;
      *) echo "archie-followup: the jobs ledger did not answer; nothing was written" >&2 ;;
    esac
    exit "$RC" ;;
  list)
    RESP=$(ledger_page archie_followup 100); RC=$?
    case "$RC" in
      0) jq -r '.ledgers[] | select(.status == "pending") | (.detail // "" | try fromjson catch {}) as $d
           | [.key, ($d.due_at // "?"), (if $d.initiative_id == null then "factory-watch" else "I\($d.initiative_id)" end), ($d.note // "")]
           | @tsv' <<<"$RESP" ;;
      2) ;;
      *) echo "archie-followup: the jobs ledger did not answer" >&2; exit 1 ;;
    esac
    exit 0 ;;
  *) usage ;;
esac
