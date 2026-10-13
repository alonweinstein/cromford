#!/bin/sh
# fly/gh-credential.sh — a git credential helper that reads the builder's GitHub
# token AT CALL TIME, so a `git push` 60 minutes into a build uses the token the
# hub rotated at minute 45 rather than the one the machine booted with.
#
# WHY (2026-09-14, project-5 TK-680/681/682). fly/builder-runner.sh wired git up
# with `gh auth setup-git`, whose helper answers with whatever $GH_TOKEN held when
# the process started. A GitHub App installation token dies in an hour and a pool
# build takes 40-75 minutes, so those three builds' pre-PR push answered
# `remote: Invalid username or token` and the whole build was thrown away.
# bin/fly-pool.sh now pushes a fresh token to /run/harness-env/gh-token while the
# build runs; this is the five lines that make plain `git push` see it.
#
# Falls back to $GH_TOKEN when the file is absent, which is exactly what the
# helper it replaces did — so an unarmed machine, or one whose file never landed,
# authenticates the way it does today.
#
# `store`/`erase` are answered with silence on purpose: nothing here caches, so
# there is nothing to write or forget. No token value is printed anywhere but on
# the credential protocol's own stdout, which git consumes.
#
# A READ-ONLY TOKEN FOR EXTRA REPOS (BH-5910). When bin/fly-pool.sh also pushed
# /run/harness-env/gh-token-read (lane.fly-pool.<project>.extra_read_repos), a
# request whose path is one of GH_EXTRA_READ_REPOS gets that token instead. git
# sends the path only with credential.useHttpPath, which fly/builder-runner.sh
# sets when the file exists. Every other request, the project repo's push
# included, is answered exactly as before.
[ "${1:-}" = get ] || exit 0
TOK=""
REQ_PATH=""
while IFS= read -r line; do
  line=$(printf '%s' "$line" | tr -d '\r')
  [ -n "$line" ] || break
  case "$line" in path=*) REQ_PATH="${line#path=}" ;; esac
done
RF="${GH_TOKEN_READ_FILE:-/run/harness-env/gh-token-read}"
if [ -n "$REQ_PATH" ] && [ -n "${GH_EXTRA_READ_REPOS:-}" ] && [ -s "$RF" ]; then
  # owner/repo of the path: the first two segments, .git stripped, lower case.
  set -f
  WANT=$(printf '%s' "$REQ_PATH" | cut -d/ -f1-2 | sed 's/\.git$//' | tr 'A-Z' 'a-z')
  for R in $(printf '%s' "$GH_EXTRA_READ_REPOS" | tr ',' ' ' | tr 'A-Z' 'a-z'); do
    if [ "$R" = "$WANT" ]; then
      TOK=$(tr -d ' \t\r\n' < "$RF" 2>/dev/null)
      break
    fi
  done
fi
[ -n "$TOK" ] && { printf 'username=x-access-token\npassword=%s\n' "$TOK"; exit 0; }
F="${GH_TOKEN_LIVE_FILE:-/run/harness-env/gh-token}"
[ -s "$F" ] && TOK=$(tr -d ' \t\r\n' < "$F" 2>/dev/null)
[ -n "$TOK" ] || TOK="${GH_TOKEN:-}"
[ -n "$TOK" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$TOK"
