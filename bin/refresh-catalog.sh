#!/bin/bash
# refresh-catalog.sh — regenerate catalog/feature-catalog.md from the OS repos.
# NOT run on the boxes (they don't have the sibling repos). Run on the operator's Mac,
# manually or monthly, then commit + push; boxes pick it up via update-runners.sh.
#
# v1 is a documented stub: run a Claude session over the repo docs with the prompt
# below, review the diff, commit.
# The survey list is the registry, not a hand-kept line: a project enrolled
# after this file was written was simply never surveyed, and the catalog then
# reads as complete.
PROJECTS=$("$(cd "$(dirname "$0")" && pwd)/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')
[ -n "$PROJECTS" ] || { echo "FATAL: fleet.conf unreadable — cannot list the projects to survey" >&2; exit 1; }
cat <<EOF
Refresh procedure (manual, on the Mac):
1. cd ~/cromford
2. Run a Claude session with this prompt:
   "Update catalog/feature-catalog.md. Survey the feature sets of every
    project in fleet.conf — $PROJECTS — plus ~/project-6. Find each one's local
    checkout on this Mac (fleet.conf carries its GitHub slug) and read its
    CLAUDE.md + docs maps (NOT the code). Keep the file's existing structure: shared-DNA note,
    cross-pollination shortlist table, per-OS distinctive features, project-6
    primitive vocabulary. Add new features shipped since the last refresh, drop
    anything that no longer exists, keep entries one-line dense."
3. Review the diff, commit, push. Boxes self-sync daily (update-runners.sh).
EOF
exit 0
