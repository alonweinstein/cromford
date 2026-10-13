#!/bin/bash
# tests/gh-shim-repo.bh-788-test.sh — the review round on bin/lib/gh-shim/repo.sh
# (PR #882, the operator's CHANGES_REQUESTED of 2026-09-18): finding 6, `repo clone`
# hard-set GIT_CONFIG_COUNT=1 and index 0, clobbering whatever the caller had
# already put there.
#
# THE CALLER THAT PAYS: bin/lane-fence.sh:93-94 ships `core.hooksPath` to a
# fenced lane through GIT_CONFIG_COUNT/_KEY_n/_VALUE_n. A clone that overwrote
# index 0 dropped the fence's hooks pointer and said nothing about it.
#
# HOW IT DRIVES. The real bin/gh-rest-shim with the real shipped handlers over
# tests/lib/gh-shim-stub.sh's fixture stub, whose git stub records every
# GIT_CONFIG_* pair it was handed in $T/git-calls.txt. Assertions are that
# recording, stdout and the exit code — never handler source.
#
# Run from anywhere:  bash tests/gh-shim-repo.bh-788-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }

gshim_stub_setup
gitcalls() { [ -f "$T/git-calls.txt" ] && cat "$T/git-calls.txt"; return 0; }

# ── repo-clone-appends-git-config (finding 6) ────────────────────────────────
gshim_reset
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/fence \
  gshim_run repo clone o/r dir
eq "repo-clone-appends rc" "$RC" "0"
has "repo-clone-appends argv" "$(gitcalls)" "git clone https://github.com/o/r.git dir"
has "repo-clone-appends keeps hooksPath key" "$(gitcalls)" "GIT_CONFIG_KEY_0=core.hooksPath"
has "repo-clone-appends keeps hooksPath value" "$(gitcalls)" "GIT_CONFIG_VALUE_0=/fence"
has "repo-clone-appends helper at index 1" "$(gitcalls)" \
  "GIT_CONFIG_KEY_1=credential.https://github.com.helper"
has "repo-clone-appends helper value" "$(gitcalls)" "GIT_CONFIG_VALUE_1=!"
has "repo-clone-appends helper is git-credential" "$(gitcalls)" "auth git-credential"
has "repo-clone-appends count bumped" "$(gitcalls)" "GIT_CONFIG_COUNT=2"
hasnt "repo-clone-appends no token in argv or env" "$(gitcalls)" "x-access-token"
hasnt "repo-clone-appends no PAT" "$(gitcalls)" "ghp_"

# Two pairs already present -> the helper lands at index 2, count 3.
gshim_reset
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/fence \
  GIT_CONFIG_KEY_1=protocol.version GIT_CONFIG_VALUE_1=2 \
  gshim_run repo clone o/r
has "repo-clone-appends-two keeps pair 0" "$(gitcalls)" "GIT_CONFIG_KEY_0=core.hooksPath"
has "repo-clone-appends-two keeps pair 1" "$(gitcalls)" "GIT_CONFIG_KEY_1=protocol.version"
has "repo-clone-appends-two helper at 2" "$(gitcalls)" \
  "GIT_CONFIG_KEY_2=credential.https://github.com.helper"
has "repo-clone-appends-two count" "$(gitcalls)" "GIT_CONFIG_COUNT=3"

# ── repo-clone-junk-count ────────────────────────────────────────────────────
# A non-numeric count is 0, the sanitation bin/lane-fence.sh uses — never a bash
# arithmetic error on the exec path.
gshim_reset
GIT_CONFIG_COUNT=junk gshim_run repo clone o/r
eq "repo-clone-junk-count rc" "$RC" "0"
has "repo-clone-junk-count helper at 0" "$(gitcalls)" \
  "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
has "repo-clone-junk-count count" "$(gitcalls)" "GIT_CONFIG_COUNT=1"
hasnt "repo-clone-junk-count no junk left" "$(gitcalls)" "GIT_CONFIG_COUNT=junk"
gshim_reset
GIT_CONFIG_COUNT= gshim_run repo clone o/r
eq "repo-clone-empty-count rc" "$RC" "0"
has "repo-clone-empty-count count" "$(gitcalls)" "GIT_CONFIG_COUNT=1"

# Nothing preset is byte-for-byte the old behaviour: index 0, count 1.
gshim_reset
gshim_run repo clone o/r dir
has "repo-clone-unset-count index 0" "$(gitcalls)" \
  "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
has "repo-clone-unset-count count" "$(gitcalls)" "GIT_CONFIG_COUNT=1"

# ── mutation (D1): clobber index 0 again, watch the append block go red ───────
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's/^  n="${GIT_CONFIG_COUNT:-0}"/  n=0/' "$T/lib/repo.sh"
if [ "$(grep -cF 'n="${GIT_CONFIG_COUNT:-0}"' "$DIR/bin/lib/gh-shim/repo.sh")" -ge 1 ] &&
   [ "$(grep -cF 'n="${GIT_CONFIG_COUNT:-0}"' "$T/lib/repo.sh")" -eq 0 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/fence \
  GH_SHIM_LIB="$T/lib" gshim_run repo clone o/r dir
if [ "$(gitcalls | grep -c 'GIT_CONFIG_KEY_0=core.hooksPath')" -ge 1 ]; then
  bad "mutation: the mutant kept hooksPath — repo-clone-appends-git-config pins nothing"
else
  ok
fi


# ── repo-clone-dot-component (fix round) ─────────────────────────────────────
# The clone slug class admits `.` and `..` components the contract's gshim_slug
# rejects: `../x` would have become `git clone https://github.com/../x.git`.
# Same dot-component case as gshim_slug: the call is the real binary's.
for bad in ../x ./x x/.. x/. ../.; do
  gshim_reset
  gshim_run repo clone "$bad"
  has "repo-clone-dot-component $bad passthru" "$(gshim_calls)" "PASSTHRU repo clone $bad"
  eq "repo-clone-dot-component $bad no git" "$(gitcalls | grep -c 'git clone')" "0"
done

echo "gh-shim-repo.bh-788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
