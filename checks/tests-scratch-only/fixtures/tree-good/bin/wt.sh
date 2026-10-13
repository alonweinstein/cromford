#!/bin/bash
# A worktree under the repos root, removed by git first and rm second.
set -uo pipefail
WT="${REPOS_ROOT:-/root/repos}/.x"
git -C "${REPOS_ROOT:-/root/repos}/p" worktree remove --force "$WT" || rm -rf "$WT"
