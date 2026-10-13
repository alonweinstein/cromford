#!/bin/bash
# tests/gh-credential-extra-read.bh-5910-test.sh — BH-5910: fly/gh-credential.sh
# answers the read-only token for an extra repo, and the project token for
# everything else.
#
# A pool machine gets /run/harness-env/gh-token (the project token, write) and,
# when lane.fly-pool.<project>.extra_read_repos is set, gh-token-read (read-only,
# the project plus the extra repos). git asks the helper with the request path
# (useHttpPath). Only a path whose owner/repo is in GH_EXTRA_READ_REPOS gets the
# read token, so a push to the project repo never uses it.
#
# PINNED (the real helper, a real credential request on stdin):
#   1 extra repo path -> read token
#   2 project repo path -> project token
#   3 no path line -> project token
#   4 read file absent -> project token
#   5 case-insensitive match, and a path with no .git suffix
#   6 a repo NOT in GH_EXTRA_READ_REPOS -> project token, and an empty list
#   7 the read file empty and no live file -> GH_TOKEN, as today
#   8 store/erase answer nothing
#   9 fly/builder-runner.sh live_git_credentials sets useHttpPath only when
#     the read file exists
# Run from anywhere: bash tests/gh-credential-extra-read.bh-5910-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
HELPER="$DIR/fly/gh-credential.sh"

printf 'tok-fixture-project\n' > "$T/gh-token"
printf 'tok-fixture-read\n' > "$T/gh-token-read"
# ask <path or empty> [verb] -> the password line the helper printed
ask() {
  local p="$1" v="${2:-get}"
  { printf 'protocol=https\nhost=github.com\n'; [ -n "$p" ] && printf 'path=%s\n' "$p"; printf '\n'; } \
    | env -i PATH="/usr/bin:/bin" GH_TOKEN_LIVE_FILE="${LIVE:-$T/gh-token}" GH_TOKEN_READ_FILE="${READ:-$T/gh-token-read}" \
        GH_EXTRA_READ_REPOS="${XR-example-org/OtherRepo, example-org/ThirdRepo}" GH_TOKEN="${GHT:-}" \
        sh "$HELPER" "$v" | sed -n 's/^password=//p'
}

[ "$(ask example-org/OtherRepo.git)" = tok-fixture-read ] && ok || bad "1: the extra repo must get the read token, got '$(ask example-org/OtherRepo.git)'"
[ "$(ask example-org/ThirdRepo.git)" = tok-fixture-read ] && ok || bad "1: the second extra repo (after ', ') must get the read token"
[ "$(ask example-org/proj-repo.git)" = tok-fixture-project ] && ok || bad "2: the project repo must get the project token, got '$(ask example-org/proj-repo.git)'"
[ "$(ask '')" = tok-fixture-project ] && ok || bad "3: no path must get the project token, got '$(ask '')'"
[ "$(READ="$T/absent" ask example-org/OtherRepo.git)" = tok-fixture-project ] && ok || bad "4: no read file must get the project token"
[ "$(ask example-org/otherrepo.git)" = tok-fixture-read ] && ok || bad "5: the match must be case-insensitive"
[ "$(ask example-org/OtherRepo)" = tok-fixture-read ] && ok || bad "5: a path with no .git must match"
[ "$(ask example-org/OtherRepo.git/info/refs)" = tok-fixture-read ] && ok || bad "5: a path past owner/repo must match on owner/repo"
[ "$(ask example-org/OtherRepoX.git)" = tok-fixture-project ] && ok || bad "6: a longer name is not the extra repo"
[ "$(ask example-org/NotListed.git)" = tok-fixture-project ] && ok || bad "6: an unlisted repo must get the project token"
[ "$(XR='' ask example-org/OtherRepo.git)" = tok-fixture-project ] && ok || bad "6: an empty GH_EXTRA_READ_REPOS must send no read token"
: > "$T/empty"
[ "$(LIVE="$T/absent" READ="$T/empty" GHT=tok-fixture-env ask example-org/OtherRepo.git)" = tok-fixture-env ] && ok || bad "7: empty read file + no live file must answer GH_TOKEN"
[ -z "$(ask example-org/OtherRepo.git store)" ] && [ -z "$(ask example-org/OtherRepo.git erase)" ] && ok || bad "8: store/erase must print nothing"

# ── 9. live_git_credentials, lifted from fly/builder-runner.sh ──────────────
FN=$(sed -n '/^live_git_credentials() {/,/^}/p' "$DIR/fly/builder-runner.sh")
[ -n "$FN" ] && ok || bad "9: live_git_credentials() not found in fly/builder-runner.sh"
mkdir -p "$T/home" "$T/env" "$T/h/fly"
cp "$HELPER" "$T/h/fly/gh-credential.sh"
gitcfg() { env -i PATH="/usr/bin:/bin" HOME="$T/home" git config --global --get "$1"; }
runlgc() { env -i PATH="/usr/bin:/bin" HOME="$T/home" ENVDIR="$T/env" HARNESS="$T/h" bash -c "$FN"$'\nlive_git_credentials'; }
printf 'tok-fixture-project\n' > "$T/env/gh-token"
runlgc
[ -n "$(gitcfg credential.https://github.com.helper)" ] && ok || bad "9: the helper must be installed"
[ -z "$(gitcfg credential.https://github.com.useHttpPath)" ] && ok || bad "9: no read file -> useHttpPath must stay unset"
printf 'tok-fixture-read\n' > "$T/env/gh-token-read"
runlgc
[ "$(gitcfg credential.https://github.com.useHttpPath)" = true ] && ok || bad "9: a read file must set useHttpPath=true"

echo "gh-credential-extra-read (BH-5910): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
