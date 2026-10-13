#!/bin/bash
# project-of.sh [--prefix|--repo] <text> — which fleet project does this string name?
#
# Prints the project and exits 0; prints nothing and exits 1 when no fleet
# project is named. The registry (bin/fleet-conf.sh) is the only source of
# names, so a project enrolled tomorrow is recognised by every caller without
# anybody editing a regex — the 2026-09-10 tier-2 merge stall was four such
# regexes, each written when the fleet had four projects.
#
#   --prefix  the string STARTS with "<project>-" (a build-dir name:
#             project-1-TK-88-202607010000), optionally behind the hub's own
#             "pool-" copy marker (pool-project-5-TK-551-202609131444). Longest
#             project name wins, so "sib-nav-…" never reads as "sib".
#   default   the project is mentioned ANYWHERE in the string (an alert line, a
#             queue row), case-insensitively — which is what the hand-written
#             `*project-2*` and `grep -qi "${p%-os}"` matches did. Full names
#             are tried before short stems ("project-3" for project-3), and within each
#             pass the EARLIEST mention wins, ties going to the longer name.
#             See the comment on earliest() for why position beats length.
#   --repo    exact owner/repository lookup using fleet.conf column 2, ignoring
#             case. A repository slug need not contain its fleet project name.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE=mention
[ "${1:-}" = "--prefix" ] && { MODE=prefix; shift; }
[ "${1:-}" = "--repo" ] && { MODE=repo; shift; }
TEXT="${1:?text}"
PROJECTS=$("$HERE/fleet-conf.sh" --projects 2>/dev/null) || exit 1
# Longest name first: every match below is a substring test, and a shorter
# project name that prefixes a longer one would otherwise claim it.
SORTED=$(awk '{ print length, $0 }' <<<"$PROJECTS" | sort -rn | cut -d' ' -f2-)
LOWER=$(tr '[:upper:]' '[:lower:]' <<<"$TEXT")
if [ "$MODE" = repo ]; then
  for P in $SORTED; do
    REPO=$("$HERE/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
    [ -n "$REPO" ] && [ "$REPO" != - ] || continue
    if [ "${REPO,,}" = "$LOWER" ]; then echo "$P"; exit 0; fi
  done
  exit 1
fi
if [ "$MODE" = prefix ]; then
  # "pool-" is the ONLY prefix stripped, and it is stripped because it is OURS:
  # a build relayed from a Fly pool machine is copied back to the hub as
  # pool-<project>-<KEY>-<stamp>, so the dir genuinely belongs to <project>.
  # Left unstripped, every relayed build answered "no project" — which is how 39
  # pool builds were retired unrescued on 2026-09-13 (bin/review-rescue.sh), and
  # why bin/reconcile-prs.sh already had to cut it by hand before calling here.
  # No other mid-string name is a prefix: mq-* and ext-* records belong to other
  # sweeps and claiming them would move work.
  HEAD="${TEXT#pool-}"
  for P in $SORTED; do
    case "$HEAD" in "$P"-*) echo "$P"; exit 0 ;; esac
  done
  exit 1
fi
# EARLIEST match wins, ties broken by the longer name. Not "longest anywhere":
# two projects can share a box, so the box NAME carries a project name inside it
# ("[project-7] watcher on box-project-6-1 exited rc=1"). Preferring the
# longer name resolved that line to project-6, and alerts-groom then tails
# project-6's watcher log to decide whether a project-7 alert has recovered — one
# healthy project-6 cycle closes a live project-7 alert. An alert line names its
# subject first and its context after, so position is the better signal. The
# tie-break keeps the collision case: at the same offset, sib-nav beats sib.
earliest() { # earliest <needle>... -> prints the best-matching needle, or nothing
  local n pre off best_off=-1 best="" best_len=0
  for n in "$@"; do
    case "$LOWER" in *"$n"*) ;; *) continue ;; esac
    pre="${LOWER%%"$n"*}"; off=${#pre}
    if [ "$best_off" -lt 0 ] || [ "$off" -lt "$best_off" ] \
       || { [ "$off" -eq "$best_off" ] && [ "${#n}" -gt "$best_len" ]; }; then
      best_off=$off; best="$n"; best_len=${#n}
    fi
  done
  [ -n "$best" ] && printf '%s' "$best"
}
HIT=$(earliest $SORTED)
[ -n "$HIT" ] && { echo "$HIT"; exit 0; }
# Only then the stems. A stem is a weaker signal than a full name, so no stem
# may win over any full-name match anywhere in the string — offset only ever
# breaks ties WITHIN a pass, never across the two.
STEMS=""
for P in $SORTED; do
  S="${P%-os}"
  [ "$S" != "$P" ] || continue
  STEMS="$STEMS $S"
done
HIT=$(earliest $STEMS)
[ -n "$HIT" ] || exit 1
# Map the winning stem back to its project.
for P in $SORTED; do
  [ "${P%-os}" = "$HIT" ] && { echo "$P"; exit 0; }
done
exit 1
