#!/bin/bash
# tests/resolver-pr-url-derivation-test.sh — bin/blocked-resolver.sh gets the repo
# slug and the branch out of the PR URL, so the ladder walks mechanical -> fix
# round -> rebuild in that order instead of falling straight to the bottom.
#
# THE DEFECT THIS PINS (2026-09-16). Both branch rungs asked fleet-conf for the
# slug and gave up on an empty answer — printing, in the same line, the URL that
# contains it. From logs/blocked-resolver.log, one second apart:
#
#   project-5/example-org-project-5-1645 [conflict-unresolvable]: no repo/branch/head
#     for https://github.com/example-org/project-5/pull/1645 — nothing mechanical to try, FIX ROUND
#   project-5/example-org-project-5-1645: no repo/branch for
#     https://github.com/example-org/project-5/pull/1645 — REBUILD FRESH instead
#
# Rung 1 could not run and rung 2 could not run, so REBUILD FRESH was the only
# rung that ever fired — $20-30 and an hour a time, and TK-1529 was ABANDONED
# after three of them. #1542 #1556 #1526 #1592 #1630 #1634 #1645 all did this.
#
# The second half is the token. gh-repo-token.sh exists because the hub's default
# PAT 404s on example-org/project-5, and `gh pr view` with it answers an EMPTY
# STRING and rc 0 — which the old code read as "this PR has no branch". The fake
# gh here reproduces exactly that: it answers only when GH_TOKEN is the admin
# one, so a test that passes is a test where the read was actually re-tried under
# the repo's own credential.
# Run from anywhere: tests/resolver-pr-url-derivation-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Scratch harness only. Nothing here may touch /root/harness.
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin"
ADMTOK=tok_ADMIN_0002
DEFTOK=tok_DEFAULT_0001

# The fake gh: the PR read answers ONLY under the admin token, which is the
# 2026-09-12 project-5 shape. Under anything else it 404s, exactly as the hub's
# default PAT does on example-org/project-5.
#
# THE READ IS REST NOW (2026-09-16). br_pr_ref asks `gh api repos/<slug>/pulls/N`
# rather than the GraphQL `gh pr view --json`, because the GraphQL bucket is the
# one the whole hub shares and the one that ran out — see the sibling fixture
# tests/resolver-pr-read-failed-test.sh for the incident that forced it.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  "api repos/example-org/project-5 -q .id")
      [ "\${GH_TOKEN:-}" = "$ADMTOK" ] && { echo 42; exit 0; }; exit 1 ;;
  *"api repos/example-org/project-5/pulls/1645"*)
      [ "\${GH_TOKEN:-}" = "$ADMTOK" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      echo "64b4d2d3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-1608"; exit 0 ;;
  *"api repos/example-org/project-5/pulls/9999"*)
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"api repos/o/tproj/pulls/8888"*)
      echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef null"; exit 0 ;;
  # /pull/7 and /pull/8 are the NON-SHA HEAD shapes (#511). The read is paired
  # and positional, so a head field that is not 40 hex — a branch name slid into
  # it, jq rendering an absent .head.sha as "null" — must be dropped rather than
  # handed to rung 2 as a --force-with-lease value.
  *"api repos/o/tproj/pulls/7 "*) echo "ticket/TK-7 ticket/TK-7"; exit 0 ;;
  *"api repos/o/tproj/pulls/8 "*) echo "null ticket/TK-8"; exit 0 ;;
  *"api repos/"*"/pulls/"*) echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef ticket/TK-9"; exit 0 ;;
  "api repos/"*) echo 7; exit 0 ;;
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) echo ""; exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
printf 'GH_ADMIN_TOKEN=%s\n' "$ADMTOK" > "$H/env/github-admin.env"; chmod 600 "$H/env/github-admin.env"
export GH_TOKEN="$DEFTOK"

cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$H/bin/lib/gh-repo-token.sh"

# The functions under test, lifted out of the script the way the other resolver
# fixtures do it — the script's top level is a whole lane run.
fn() { awk -v F="^$1\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh"; }
for f in br_use_token br_reset_token br_slug_of_url br_pr_ref; do
  src=$(fn "$f"); [ -n "$src" ] || { echo "FAIL: $f not found in bin/blocked-resolver.sh"; exit 1; }
  eval "$src"
done

URL=https://github.com/example-org/project-5/pull/1645

# --- 1. the slug is in the URL ----------------------------------------------
[ "$(br_slug_of_url "$URL")" = example-org/project-5 ] && ok || bad "slug from a PR URL"
[ "$(br_slug_of_url https://github.com/example-org/cromford/pull/489)" = example-org/cromford ] && ok \
  || bad "slug from a second PR URL"
# Anything that is not a PR URL yields nothing — mc_slug_of_url's sed echoes its
# input unchanged on no match, so this guard is the whole reason br_slug_of_url
# exists rather than a bare call to it.
for u in - "" https://github.com/example-org/project-5 https://example.com/x/y/pull/1 "not a url"; do
  br_slug_of_url "$u" >/dev/null 2>&1 && bad "br_slug_of_url must refuse '$u'" || ok
done

# --- 2. the branch and head come back, under the token that can SEE the repo --
read -r SLUG BR HEAD <<<"$(br_pr_ref "$URL")"
[ "$SLUG" = example-org/project-5 ] && ok || bad "br_pr_ref slug: got '${SLUG:-}'"
[ "$BR" = ticket/TK-1608 ] && ok || bad "br_pr_ref branch: got '${BR:-}'"
[ "$HEAD" = 64b4d2d3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] && ok || bad "br_pr_ref head: got '${HEAD:-}'"
# It really did have to retry: the first read ran under the default token.
[ "$(grep -c 'pulls/1645' "$T/gh.txt")" -ge 2 ] && ok \
  || bad "the failed first read must be re-tried under the repo's token"
# And it asked REST, not GraphQL — the bucket that ran out on 2026-09-16.
grep -q 'pr view' "$T/gh.txt" && bad "br_pr_ref must not use the GraphQL 'gh pr view'" || ok
# A HEAD IS A SHA OR IT IS NOTHING (#511, kept across the REST move). `head` is
# what rung 2 falls back to for its --force-with-lease value when `origin/<br>`
# will not resolve, so a head field carrying anything but 40 hex is the bug this
# guard closes — the lease guard could never fire, and a park with no local ref
# walked on into a worktree add instead of stopping as a setup block. /pull/7 is
# the residue shape the old GraphQL read produced, a branch NAME sitting in the
# head field; the branch it CAN have must still come back.
read -r SLUG BR HEAD <<<"$(br_pr_ref https://github.com/o/tproj/pull/7)"
[ "$SLUG" = o/tproj ] && [ "$BR" = ticket/TK-7 ] && ok \
  || bad "a non-sha oid must still yield the branch: got slug='${SLUG:-}' br='${BR:-}'"
[ -z "${HEAD:-}" ] && ok || bad "a non-sha head must be dropped, never used as a lease: got '${HEAD:-}'"
# And the shape the REST read produces for an absent .head.sha — jq renders it
# the string "null".
read -r SLUG BR HEAD <<<"$(br_pr_ref https://github.com/o/tproj/pull/8)"
[ "$BR" = ticket/TK-8 ] && [ -z "${HEAD:-}" ] && ok \
  || bad "a null oid must be dropped too: got br='${BR:-}' head='${HEAD:-}'"

# No URL, no answer — a park with no PR is still a park with no branch.
br_pr_ref - >/dev/null 2>&1 && bad "br_pr_ref must refuse a missing URL" || ok
br_pr_ref "" >/dev/null 2>&1 && bad "br_pr_ref must refuse an empty URL" || ok

# --- 3. the rungs themselves -------------------------------------------------
# br_mechanical and br_fix_round are driven with fleet-conf answering NOTHING —
# the exact condition that used to collapse the ladder — and with every rung
# below them recorded rather than run.
mkdir -p "$H/bin"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
ST="$T/st"; mkdir -p "$ST"; LOG="$T/resolver.log"; : > "$LOG"
OBSERVE=0; MAX_MECHANICAL=1; MAX_FIXROUNDS=1; REPOS="$T/repos"
say() { echo "$*" >> "$LOG"; }
br_cap_key() { echo "tkey"; }
br_load()    { echo '{}'; }
br_num()     { echo 0; }
br_event()   { :; }
br_record()  { echo "record $*" >> "$T/rungs.txt"; }
br_fix_round()    { echo "FIX_ROUND" >> "$T/rungs.txt"; }
br_rebuild_fresh(){ echo "REBUILD_FRESH" >> "$T/rungs.txt"; }
br_rerun_ci()     { return 1; }
mc_rebase()  { echo "MC_REBASE slug=$1 project=$2 branch=$3 head=$4" >> "$T/rungs.txt"; printf '%s' "ffffffffffffffffffffffffffffffffffffffff"; return 0; }
eval "$(fn br_mechanical)"

: > "$T/rungs.txt"
br_mechanical project-5 example-org-project-5-1645 conflict-unresolvable "$URL" - TK-1608
grep -q "MC_REBASE slug=example-org/project-5 project=project-5 branch=ticket/TK-1608 head=64b4d2d3" "$T/rungs.txt" && ok \
  || bad "rung 1 must reach mc_rebase with the URL-derived slug and branch: $(cat "$T/rungs.txt")"
grep -q FIX_ROUND "$T/rungs.txt" && bad "rung 1 succeeded, so rung 2 must NOT run" || ok
grep -q REBUILD_FRESH "$T/rungs.txt" && bad "rung 1 succeeded, so rung 3 must NOT run" || ok
grep -q 'no repo/branch' "$LOG" && bad "the old give-up line must be gone: $(cat "$LOG")" || ok

# 3b. A PR THAT COULD NOT BE READ IS RETRIED, NOT CASCADED (2026-09-16).
# With no token that can see the repo the read fails under both credentials, and
# a failed read says NOTHING about the branch. The rung spends nothing and the
# park comes back next tick — see tests/resolver-pr-read-failed-test.sh for the
# rate-limit incident this pins.
: > "$T/rungs.txt"; : > "$LOG"
GH_TOKEN=$DEFTOK _GHRT_ADMIN_TOK="" br_mechanical project-5 example-org-project-5-9999 \
  conflict-unresolvable https://github.com/example-org/project-5/pull/9999 - TK-9999
grep -q 'PR read FAILED' "$LOG" && ok || bad "an unreadable PR must say so: $(cat "$LOG")"
grep -qE 'FIX_ROUND|REBUILD_FRESH' "$T/rungs.txt" \
  && bad "an unreadable PR must spend no rung: $(cat "$T/rungs.txt")" || ok

# 3b2. A PR THAT WAS READ AND REALLY HAS NO BRANCH still cascades, exactly as
# before: head.ref comes back null when the head repo is gone.
: > "$T/rungs.txt"; : > "$LOG"
br_mechanical tproj o-tproj-8888 conflict-unresolvable https://github.com/o/tproj/pull/8888 - TK-8888
grep -q FIX_ROUND "$T/rungs.txt" && ok || bad "a null head.ref still cascades: $(cat "$T/rungs.txt")"
grep -q "no branch/head" "$LOG" && ok || bad "the give-up line must survive for a real no-branch PR: $(cat "$LOG")"

# 3c. THE HEAD IS OPTIONAL TO THE FIX ROUND. `gh` answering the branch but not
# the sha must not cost rung 2 the branch it CAN have — the fix round reads its
# own lease off origin/<branch> and never needed the sha.
read -r SLUG BR HEAD <<<"$(BR_NO_OID=1 br_pr_ref https://github.com/o/tproj/pull/3)"
[ "$SLUG" = o/tproj ] && [ "$BR" = ticket/TK-9 ] && ok || bad "slug+branch on a repo the default token sees"

# 3c. A PARK WITH NO PR AT ALL still walks down, exactly as before.
: > "$T/rungs.txt"; : > "$LOG"
br_mechanical project-5 example-org-project-5-0 build-dead - - TK-1
grep -q FIX_ROUND "$T/rungs.txt" && ok || bad "a park with no PR still falls to the fix round: $(cat "$T/rungs.txt")"

echo "resolver-pr-url-derivation: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
