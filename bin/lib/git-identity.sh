# bin/lib/git-identity.sh — THE configured commit identity, and the check that a
# push carries nothing else (BH-1134). Sourced, never executed; defines only
# gi_* functions and the GI_NAME/GI_EMAIL it resolves, so sourcing has no effect.
#
# WHY. project-5 #2708's fix-round commit was authored and committed as
# `Claude Fable 5.1 <noreply@anthropic.com>` and the repo's author == pusher
# ruleset dequeued it. The build lane never had the problem because its squash
# re-authors everything with the box's global config; the fix round and the
# lander push an agent's commits as they are.
#
#   gi_resolve        GI_NAME/GI_EMAIL from `git config --global`, NEVER the
#                     effective config: an agent that ran `git config user.email`
#                     inside a repo poisons that repo's local config, and that must
#                     not become "the configured author". Each missing half falls
#                     back to the fleet default fly/builder-runner.sh writes.
#   gi_env            the four GIT_AUTHOR_*/GIT_COMMITTER_* assignments, one per
#                     line. The environment beats user.* config and `git -c`;
#                     only an explicit --author beats the author half, which is
#                     what gi_check is for.
#   gi_export         the same four, exported into the current shell.
#   gi_check <wt> <exclude-ref>...
#                     every commit in `HEAD --not <excludes>` (merges included:
#                     an agent-committed conflict merge is a commit the push
#                     carries) whose author OR committer email is not GI_EMAIL.
#                     rc 0 all match | 1 mismatch (prints `<sha8> author=<ae>
#                     committer=<ce>` per commit) | 3 could not run. rc 3 is
#                     never clean.
#   gi_ensure_global  sets the global identity to the default ONLY where it is
#                     unset. Bootstrap only; a lane never writes global config.
# shellcheck shell=bash

# BH-4080: the defaults are HARNESS_GIT_NAME / HARNESS_GIT_EMAIL, from the
# deployment defaults home. Missing, this lib defines nothing: gi_check is then
# undefined and every caller refuses the push, which is the safe answer.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1
GI_DEFAULT_NAME=$HARNESS_GIT_NAME
GI_DEFAULT_EMAIL=$HARNESS_GIT_EMAIL

gi_norm() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

gi_resolve() {
  GI_NAME=$(git config --global user.name 2>/dev/null)
  GI_EMAIL=$(git config --global user.email 2>/dev/null)
  [ -n "$GI_NAME" ]  || GI_NAME="$GI_DEFAULT_NAME"
  [ -n "$GI_EMAIL" ] || GI_EMAIL="$GI_DEFAULT_EMAIL"
  return 0
}

gi_env() {
  [ -n "${GI_EMAIL:-}" ] || gi_resolve
  printf 'GIT_AUTHOR_NAME=%s\nGIT_AUTHOR_EMAIL=%s\nGIT_COMMITTER_NAME=%s\nGIT_COMMITTER_EMAIL=%s\n' \
    "$GI_NAME" "$GI_EMAIL" "$GI_NAME" "$GI_EMAIL"
}

gi_export() {
  [ -n "${GI_EMAIL:-}" ] || gi_resolve
  export GIT_AUTHOR_NAME="$GI_NAME" GIT_AUTHOR_EMAIL="$GI_EMAIL" \
         GIT_COMMITTER_NAME="$GI_NAME" GIT_COMMITTER_EMAIL="$GI_EMAIL"
}

gi_check() {
  local wt="$1"; shift
  local want log sha ae ce bad=""
  [ -n "${GI_EMAIL:-}" ] || gi_resolve
  want=$(gi_norm "$GI_EMAIL")
  [ -n "$want" ] && [ -n "$wt" ] || return 3
  # An exclude that does not resolve would make `log` fail; a caller that asked
  # for it must hear "could not run", never a shorter (and so cleaner) range.
  log=$(git -C "$wt" log --format='%H %ae %ce' HEAD --not "$@" -- 2>/dev/null) || return 3
  while read -r sha ae ce; do
    [ -n "$sha" ] || continue
    if [ "$(gi_norm "$ae")" != "$want" ] || [ "$(gi_norm "$ce")" != "$want" ]; then
      bad="$bad${sha:0:8} author=$ae committer=$ce"$'\n'
    fi
  done <<<"$log"
  [ -z "$bad" ] && return 0
  printf '%s' "$bad"
  return 1
}

gi_ensure_global() {
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "$GI_DEFAULT_NAME"
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "$GI_DEFAULT_EMAIL"
}
