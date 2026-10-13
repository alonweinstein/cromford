#!/bin/bash
# bin/lib/rules-pack-snapshot.sh — the rules pack's isolated runner (BH-3477).
# Sourced, never executed. Functions only. No root default (BH-2613 rule 4):
# every path is an argument.
#
# rp_snapshot_probe
#   rc 0 when `setpriv --reuid nobody --regid nogroup --clear-groups` can
#   switch user here, else rc 125 with `setpriv cannot switch` on stderr.
#
# rp_snapshot_build <src_tree> <fork_sha> <head_sha> <workdir>
#   Builds <workdir>/repo (two commits, `base` then `head`, with
#   refs/remotes/origin/main at `base`) and <workdir>/base (a one-commit tree of
#   the fork), chowned to nobody. Prints the snapshot's base commit sha.
#   rc 0, or 125 when it cannot build.
#
# rp_snapshot_reachable <dir>
#   rc 0 when nobody can enter <dir> by its absolute path (search permission on
#   every ancestor), else rc 1. The run's `cd` happens as root, but the suites
#   resolve their own absolute paths (and git, mktemp under TMPDIR) as nobody:
#   a workdir under a root-only parent (/root, mode 700) is a snapshot whose
#   base no component can resolve (BH-5284 pool, PR #5296).
#
# rp_snapshot_run <dir> <cmd...>
#   Runs the command in <dir> as nobody under
#   `env -i PATH HOME TMPDIR LANG LC_ALL RATCHET_BASE TI_BASE`; returns the
#   command's rc.
#
# <dir> is <workdir>/repo or <workdir>/base; a run's HOME and TMPDIR are
# <workdir>/home and <workdir>/tmp, which rp_snapshot_build makes. RATCHET_BASE
# and TI_BASE pass through from the caller, default origin/main — which inside
# the snapshot is the base commit. Every failure before the command runs is rc
# 125 with `rules-pack: snapshot: <step>` on stderr: could not run, never a
# pass and never a red. The caller probes first, and makes the parent of
# <workdir> traversable by nobody; the lib touches nothing outside <workdir>.

rp_snapshot_probe() {
  command -v setpriv >/dev/null 2>&1 \
    || { echo "rules-pack: setpriv cannot switch to nobody (setpriv is not installed)" >&2; return 125; }
  # The exact flags the run uses (#1541 review C1).
  setpriv --reuid nobody --regid nogroup --clear-groups true >/dev/null 2>&1 \
    || { echo "rules-pack: setpriv cannot switch to nobody here (not root, or no CAP_SETUID/SETGID)" >&2; return 125; }
  return 0
}

# _rp_snapshot_extract <src> <sha> <dest> — the committed tree of <sha>, never
# the source's working tree.
_rp_snapshot_extract() {
  local ps
  git -C "$1" archive --format=tar "$2" | tar -x -C "$3"
  ps="${PIPESTATUS[*]}"
  [ "$ps" = "0 0" ] || { echo "rules-pack: snapshot: could not extract $2 into $3 (archive|tar: $ps)" >&2; return 125; }
}

# _rp_snapshot_commit <repo> <subject> — stage everything, one commit.
_rp_snapshot_commit() {
  git -C "$1" add -A >&2 \
    && git -C "$1" -c user.email=rules-pack@harness -c user.name=rules-pack -c commit.gpgsign=false \
         commit -q --no-verify --allow-empty -m "$2" >&2 \
    || { echo "rules-pack: snapshot: could not commit $2 in $1" >&2; return 125; }
}

rp_snapshot_build() {
  [ "$#" -eq 4 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] \
    || { echo "rules-pack: snapshot: usage: rp_snapshot_build <src_tree> <fork_sha> <head_sha> <workdir>" >&2; return 125; }
  local src="$1" fork="$2" head="$3" w="$4" sha base
  if [ -e "$w/repo" ] || [ -e "$w/base" ]; then
    echo "rules-pack: snapshot: $w already holds a snapshot, refusing to reuse it" >&2; return 125
  fi
  for sha in "$fork" "$head"; do
    git -C "$src" rev-parse -q --verify "$sha^{commit}" >/dev/null 2>&1 \
      || { echo "rules-pack: snapshot: $sha is not a commit in $src" >&2; return 125; }
  done
  mkdir -p "$w/repo" "$w/base" "$w/home" "$w/tmp" \
    || { echo "rules-pack: snapshot: could not make $w" >&2; return 125; }

  _rp_snapshot_extract "$src" "$fork" "$w/repo" || return 125
  git -C "$w/repo" init -q >&2 || { echo "rules-pack: snapshot: could not git-init $w/repo" >&2; return 125; }
  _rp_snapshot_commit "$w/repo" base || return 125
  base=$(git -C "$w/repo" rev-parse HEAD) || { echo "rules-pack: snapshot: no base commit in $w/repo" >&2; return 125; }

  # The head tree replaces the fork tree whole, so files the head deleted go.
  git -C "$w/repo" rm -rq --cached --ignore-unmatch . >&2 \
    && find "$w/repo" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + \
    || { echo "rules-pack: snapshot: could not clear $w/repo for the head tree" >&2; return 125; }
  _rp_snapshot_extract "$src" "$head" "$w/repo" || return 125
  _rp_snapshot_commit "$w/repo" head || return 125
  git -C "$w/repo" update-ref refs/remotes/origin/main "$base" >&2 \
    || { echo "rules-pack: snapshot: could not point origin/main at $base" >&2; return 125; }

  _rp_snapshot_extract "$src" "$fork" "$w/base" || return 125
  git -C "$w/base" init -q >&2 || { echo "rules-pack: snapshot: could not git-init $w/base" >&2; return 125; }
  _rp_snapshot_commit "$w/base" base || return 125

  chown -R nobody:nogroup "$w" \
    || { echo "rules-pack: snapshot: could not hand the snapshot to nobody" >&2; return 125; }
  printf '%s\n' "$base"
}

rp_snapshot_reachable() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || return 1
  setpriv --reuid nobody --regid nogroup --clear-groups test -x "$1/." >/dev/null 2>&1
}

rp_snapshot_run() {
  [ "$#" -ge 2 ] || { echo "rules-pack: snapshot: usage: rp_snapshot_run <dir> <cmd...>" >&2; return 125; }
  local dir="$1" w
  shift
  w=$(dirname "$dir")
  (
    cd "$dir" 2>/dev/null || { echo "rules-pack: snapshot: cannot enter $dir" >&2; exit 125; }
    # A clean environment: nothing of the caller's (tokens, HARNESS, the env
    # dir) reaches the command.
    setpriv --reuid nobody --regid nogroup --clear-groups \
      env -i PATH="$PATH" HOME="$w/home" TMPDIR="$w/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        RATCHET_BASE="${RATCHET_BASE:-origin/main}" TI_BASE="${TI_BASE:-origin/main}" "$@"
  )
}
