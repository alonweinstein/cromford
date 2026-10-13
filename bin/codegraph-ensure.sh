#!/bin/bash
# bin/codegraph-ensure.sh <project> [worktree] — make the code graph genuinely
# usable from a build, and say so in one deterministic line.
#
# THE DEFECT THIS EXISTS FOR (found by an execute Phase 0, 2026-08-25). The
# index is real and good in /root/repos/<project>: one `codegraph explore` hands
# back the symbols, their callers and a blast radius that would replace seven
# file round-trips. Builds never saw it. Every repo commits a `.codegraph/
# .gitignore` (ignore-everything-but-me), so a `git worktree add` MATERIALISES
# an empty `.codegraph/` directory in the worktree — and codegraph resolves an
# index by walking up to the NEAREST `.codegraph/`, which is now that empty one.
# The session probed `ls .codegraph/`, got a listing, concluded "indexed", and
# then did a hundred shell reads because every query came back empty.
#
# Reproduced exactly: commit the .gitignore, `git worktree add`, and a bare
# `codegraph explore` in the worktree answers "CodeGraph isn't available here".
# `ls .codegraph/` prints nothing at all (the only file is dotted). Path present,
# capability absent — the fly-probe shape, one layer down.
#
# So this script does two things and refuses to guess about either:
#   1. Makes the MAIN clone's index exist and be current (init / sync).
#   2. Emits ONE line that is CAPABILITY-tested — a real query must return a
#      real symbol — never path-tested. An empty `.codegraph/` renders NOT
#      AVAILABLE, which is the first thing the tests pin.
#
# Measured before choosing the design (real 787-file / 6,461-symbol TypeScript
# product repo, this machine): init from scratch 1.2s, sync with no changes
# 0.17s, sync after an edit 0.29s. All three are cheap enough to sit on the
# per-build path, so there is no out-of-band rollout step and no box left
# un-indexed waiting for one — which is what the operator's "always current" needs.
#
# QUERY FORM: `codegraph explore -p <main-clone>`. The CLI takes an explicit
# project path (`-p/--path`, also on `query` and `node`), so nothing needs
# symlinking into the worktree — a 164MB db copied per slot to work around a
# flag the tool already has would be the wrong trade. It also means the parent
# walk never runs, so the empty `.codegraph/` cannot shadow anything.
#
# DRIFT: the index describes MAIN's tree, and the build's branch has its own
# edits. The line says so — and the CLI itself prefixes every cross-worktree
# result with the same warning, which is better than a caveat we maintain.
set -uo pipefail
PROJECT="${1:?usage: codegraph-ensure.sh <project> [worktree]}"
WORKTREE="${2:-$PWD}"
REPO="${CODEGRAPH_REPO:-/root/repos/$PROJECT}"
CG="${CODEGRAPH_BIN:-codegraph}"

nope() { echo "CODEGRAPH NOT AVAILABLE ($1)"; exit 0; }

command -v "$CG" >/dev/null 2>&1 || nope "codegraph CLI not installed on this box"
[ -d "$REPO" ] || nope "no main clone at $REPO"

# status -j is the CLI's own machine-readable state: initialized, lastIndexed,
# nodeCount, and pendingChanges {added,modified,removed} — which is the
# staleness signal, natively, with no SHA bookkeeping of our own to drift.
st() { "$CG" status -j "$REPO" 2>/dev/null; }
field() { python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
k = sys.argv[1]
if k == "pending":
    p = d.get("pendingChanges") or {}
    print(sum(int(p.get(x,0)) for x in ("added","modified","removed")))
else:
    v = d.get(k)
    print("" if v is None else v)
' "$1" 2>/dev/null; }

S=$(st)
[ -n "$S" ] || nope "codegraph status returned nothing for $REPO"

# CREATE if missing. `index` refuses on an uninitialised project ("Run codegraph
# init first"), so init is the create path and index/sync are the refresh paths.
if [ "$(field initialized <<<"$S")" != "True" ] && [ "$(field initialized <<<"$S")" != "true" ]; then
  "$CG" init "$REPO" >/dev/null 2>&1
  S=$(st)
fi

# REFRESH if stale. Cheap enough to run every build; this is the backstop that
# makes a missed post-merge hook cost 0.3s instead of a silently stale answer.
PENDING=$(field pending <<<"$S")
if [ -n "$PENDING" ] && [ "$PENDING" != 0 ]; then
  "$CG" sync "$REPO" >/dev/null 2>&1
  S=$(st)
fi

NODES=$(field nodeCount <<<"$S")
LAST=$(field lastIndexed <<<"$S")
[ -n "$NODES" ] && [ "$NODES" != 0 ] || nope "index at $REPO is empty (0 symbols) — nothing to query"

# CAPABILITY, not path. Everything above could be true of a corrupt or
# unreadable db; the only proof that a query works is a query that worked. One
# symbol is enough, and it must come back with a real file:line.
#
# A single search term is not enough to lean on: the first version used "e" and
# rendered NOT AVAILABLE for a healthy one-symbol repo whose only function was
# named `alphaThing`. So walk a few common letters and take the first hit — any
# one of them proves the query path reads the db, and an index where NONE of
# them match a symbol has nothing worth querying anyway, which is the same
# answer by a different route.
SMOKE_OK=0
for TERM in e a i o t; do
  if "$CG" query -p "$REPO" -l 1 "$TERM" 2>&1 | grep -q ':[0-9]'; then SMOKE_OK=1; break; fi
done
[ "$SMOKE_OK" = 1 ] || nope "smoke query returned no symbol from $REPO — index unreadable or has no queryable symbols"

SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
BRANCHNAME=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
echo "CODEGRAPH AVAILABLE (index @ $BRANCHNAME $SHA, ${NODES} symbols, indexed $LAST; query via: $CG explore -p $REPO \"<symbols or question>\")"
echo "  Also: $CG query -p $REPO <search> to find a symbol, $CG node -p $REPO <symbol> for one symbol's source and callers. Do NOT run a bare codegraph from $WORKTREE — the worktree carries an empty .codegraph/ that shadows the real index; the -p form is the only one that works here."
echo "  The index is MAIN's tree, not this branch's: symbols you add or change in this build are not in it, and the CLI repeats that caveat on every result. Treat it as the map, and the working tree as the territory."
exit 0
