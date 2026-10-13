#!/bin/bash
# bin/lib/pr-snapshot-refs.sh — BH-4659 (BH-4656.1): branch tips from ONE refs
# read per branch prefix, so the conductor stops paying one `branches/<br>`
# read per PR per tick. Sourced, never executed.
#
#   prs_branch_tip <slug> <branch>   rc 0 and the 40-hex tip on stdout (a hit),
#                                    rc 2 (a miss). Never a "gone" answer: a
#                                    miss is the caller's cue to probe live.
#
# The read is `GET repos/<slug>/git/matching-refs/heads/<prefix>/`, where
# <prefix> is the branch's first path segment. It is ONE gh_rest GET, not
# _gh_rest_list: the endpoint answers every match at once and has no pages, so
# paging it would fetch the same set again per page. A truncated answer could
# only turn a hit into a miss, and a miss probes live.
#
# A MISS when: the snapshot is off (_prs_on), there is no root, the branch has
# no `/`, the open list (open.json) is unreadable or no open PR's head.ref
# shares the prefix (so only the prefixes open PRs use are ever read), the read
# failed or did not answer an array, or the branch is not in it with a 40-hex
# sha.
#
# THE CACHE is state/pr-snapshot/<owner_repo>/refs-<prefix>.json, an array of
# {ref, sha} (refs/heads/ stripped, sha lowercased), trusted while it is younger
# than PR_SNAPSHOT_TTL_S. It is written under `flock -n refs-<prefix>.lock`,
# temp file then mv, and never after a failed read. The loser of the lock reads
# for itself and writes nothing: the lock is dedupe, never a queue.
#
# No `set -e`, no `exit`; the root is pr-snapshot.sh's ${HARNESS:-${H:-}}.
if [ -n "${PR_SNAPSHOT_REFS_LIB:-}" ]; then return 0 2>/dev/null; fi
PR_SNAPSHOT_REFS_LIB=1
# shellcheck source=bin/lib/pr-snapshot.sh
command -v prs_open_list >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/pr-snapshot.sh" 2>/dev/null

prs_branch_tip() {
  local slug="${1:-}" br="${2:-}" d pre safe f src="" now m ttl tmp fd rc=0 sha
  command -v _prs_on >/dev/null 2>&1 && _prs_on || return 2
  d=$(_prs_dir "$slug") || return 2
  case "$br" in ?*/?*) ;; *) return 2 ;; esac
  pre="${br%%/*}"
  safe=$(printf '%s' "$pre" | tr -cd 'A-Za-z0-9._-')
  [ "$safe" = "$pre" ] || return 2
  jq -e --arg p "$pre/" 'type == "array" and any(.[]; (.head.ref // "") | startswith($p))' \
    "$d/open.json" >/dev/null 2>&1 || return 2
  f="$d/refs-$safe.json"
  now=$(date +%s); ttl=$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")
  m=$(stat -c %Y "$f" 2>/dev/null) || m=""
  if [ -n "$m" ] && [ $((now - m)) -ge 0 ] && [ $((now - m)) -lt "$ttl" ]; then
    src="$f"
  else
    tmp=$(mktemp "${TMPDIR:-/tmp}/pr-snapshot-refs.XXXXXX") || return 2
    # A plain command with `> file`, never `$( )`: GH_REST_* reach the caller.
    gh_rest GET "repos/$slug/git/matching-refs/heads/$pre/" > "$tmp" || rc=$?
    if [ "$rc" = 0 ] && jq -c 'if type != "array" then error("not an array") else . end
         | [.[] | {ref: ((.ref // "") | sub("^refs/heads/"; "")),
         sha: ((.object.sha // "") | ascii_downcase)}] | unique_by(.ref)' "$tmp" > "$tmp.m" 2>/dev/null; then
      src="$tmp.m"
      # The braces scope the 2>/dev/null to the open (BH-4658).
      if { exec {fd}>"$d/refs-$safe.lock"; } 2>/dev/null; then
        if flock -n "$fd"; then
          cp "$tmp.m" "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
          rm -f "$f.tmp.$$"
        fi
        exec {fd}>&-
      fi
    fi
  fi
  sha=""
  [ -n "$src" ] && sha=$(jq -r --arg r "$br" 'first(.[]? | select(.ref == $r) | .sha) // empty' "$src" 2>/dev/null)
  [ -n "${tmp:-}" ] && rm -f "$tmp" "$tmp.m"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  printf '%s\n' "$sha"
}
