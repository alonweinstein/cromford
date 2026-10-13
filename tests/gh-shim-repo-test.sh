#!/bin/bash
# tests/gh-shim-repo-test.sh — bin/lib/gh-shim/repo.sh (#769 chunk 2):
# `gh repo view` over REST and `gh repo clone` as a git exec.
#
# HOW IT DRIVES. The real bin/gh-rest-shim with the real shipped handlers over
# tests/lib/gh-shim-stub.sh, whose git stub records every argv AND every
# GIT_CONFIG_* pair in $T/git-calls.txt. That recording is what lets this suite
# assert NO TOKEN reaches argv or git config — the one claim in this file that a
# reviewer cannot take on trust.
#
# Broken once each, each turned a block red:
#   - clone with an https://x-access-token:$T@ URL -> repo-clone-no-token-in-argv
#   - map default_branch as a bare string          -> repo-view-shape
#
# Run from anywhere:  bash tests/gh-shim-repo-test.sh (exit 0 = pass)
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
logfile="$T/h/logs/gh-passthrough.log"
logline() { [ -f "$logfile" ] && cat "$logfile"; return 0; }
gitcalls() { [ -f "$T/git-calls.txt" ] && cat "$T/git-calls.txt"; return 0; }

gshim_fixture repos_o_r <<'J'
{"id":1,"name":"r","full_name":"o/r","default_branch":"main","archived":false,
 "html_url":"https://github.com/o/r","private":true,"description":"the repo"}
J

# ── repo-view-shape (the shape bin/load-project.sh reads) ────────────────────
gshim_reset
gshim_run repo view o/r --json name,defaultBranchRef,isArchived
eq "repo-view-shape" "$OUT" '{"name":"r","defaultBranchRef":{"name":"main"},"isArchived":false}'
eq "repo-view-shape rc" "$RC" "0"
has "repo-view-shape endpoint" "$(gshim_calls)" "api repos/o/r"
gshim_run repo view o/r --json defaultBranchRef --jq .defaultBranchRef.name
eq "repo-view-defaultbranch-jq" "$OUT" "main"
gshim_run repo view o/r --json nameWithOwner,isPrivate,description,url
eq "repo-view-rest-of-map" "$OUT" '{"nameWithOwner":"o/r","isPrivate":true,"description":"the repo","url":"https://github.com/o/r"}'
gshim_run repo view -R o/r --json name -q .name
eq "repo-view-dash-R" "$OUT" "r"

gshim_reset
gshim_run repo view o/r --json name,diskUsage
has "repo-view-unmappable-passthru" "$(gshim_calls)" "PASSTHRU repo view o/r --json name,diskUsage"
has "repo-view-unmappable-reason" "$(logline)" "reason=field:diskUsage"
eq "repo-view-unmappable no REST" "$(gshim_calls | grep -c 'api repos')" "0"

gshim_reset
gshim_run repo view o/r
has "repo-view-no-json-passthru" "$(gshim_calls)" "PASSTHRU repo view o/r"

gshim_reset
rm -f "$T/fixtures/repos_o_r.json"
gshim_run repo view o/r --json name
eq "repo-view-404 rc" "$RC" "1"
eq "repo-view-404 no body" "$OUT" ""
gshim_fixture repos_o_r <<'J'
{"id":1,"name":"r","full_name":"o/r","default_branch":"main","archived":false,
 "html_url":"https://github.com/o/r","private":true,"description":"the repo"}
J

# ── repo-clone-no-token-in-argv ──────────────────────────────────────────────
# The origin stays the bare https URL (bin/lib/merge-conductor-lib.sh expects
# exactly that) and auth arrives as a credential HELPER, never a credential.
gshim_reset
GH_TOKEN=ghp_notatoken gshim_run repo clone o/r dir -- -q
eq "repo-clone rc" "$RC" "0"
has "repo-clone argv" "$(gitcalls)" "git clone https://github.com/o/r.git dir -q"
has "repo-clone helper key" "$(gitcalls)" "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
has "repo-clone helper value" "$(gitcalls)" "auth git-credential"
has "repo-clone helper count" "$(gitcalls)" "GIT_CONFIG_COUNT=1"
hasnt "repo-clone no x-access-token" "$(gitcalls)" "x-access-token"
hasnt "repo-clone no PAT" "$(gitcalls)" "ghp_"
hasnt "repo-clone no passthru" "$(gshim_calls)" "PASSTHRU"
eq "repo-clone no REST call" "$(gshim_calls | grep -c 'api ')" "0"

gshim_reset
gshim_run repo clone o/r
has "repo-clone-no-dir" "$(gitcalls)" "git clone https://github.com/o/r.git"
eq "repo-clone-no-dir single arg" "$(gitcalls | grep -c 'git clone https://github.com/o/r.git$')" "1"

gshim_reset
gshim_run repo clone https://github.com/o/r.git mydir
has "repo-clone-url-normalised" "$(gitcalls)" "git clone https://github.com/o/r.git mydir"

# A form gh knows and we do not (a bare repo name for the authenticated user)
# is gh's to resolve: guessing an owner clones the wrong repository.
gshim_reset
gshim_run repo clone justarepo
has "repo-clone-bare-name-passthru" "$(gshim_calls)" "PASSTHRU repo clone justarepo"
has "repo-clone-bare-name-reason" "$(logline)" "reason=no-slug"
eq "repo-clone-bare-name no git" "$(gitcalls | grep -c 'git clone')" "0"

# ── mutation (D1): put a token in the URL, watch the no-token block go red ───
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's|https://github.com/\$slug.git|https://x-access-token:tok@github.com/$slug.git|' "$T/lib/repo.sh"
if [ "$(grep -c 'x-access-token' "$DIR/bin/lib/gh-shim/repo.sh")" -eq 0 ] &&
   [ "$(grep -c 'x-access-token' "$T/lib/repo.sh")" -ge 1 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset
GH_SHIM_LIB="$T/lib" gshim_run repo clone o/r dir -- -q
if [ "$(gitcalls | grep -c 'x-access-token')" -eq 0 ]; then
  bad "mutation: the mutant clone carries no token — repo-clone-no-token-in-argv pins nothing"
else
  ok
fi

echo "gh-shim-repo: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
