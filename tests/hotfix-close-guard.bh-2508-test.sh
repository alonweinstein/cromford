#!/bin/bash
# tests/hotfix-close-guard.bh-2508-test.sh — BH-2508: the hotfix lane's issue
# close-out asks issue_close_guard first, like the four merge close-outs do
# since BH-2477.
#
# WHY. bin/hotfix-after-deploy.sh closed the ticket's issue after a verified
# deploy on the strength of the build KEY alone. A hotfix PR that says `Refs #n`
# or leaves open children behind would close a master nobody delivered, the
# exact #2320 defect BH-2477 fixed everywhere else.
#
# This drives the REAL script against a scratch harness with the real
# gh-rest.sh and issue-state-lib.sh, and asserts on the REST argv the stub `gh`
# received, the comment bodies it was sent, and ALERTS.log.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/hotfix-close-guard.bh-2508-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/state" "$H/flags" "$H/builds" "$T/tmp"
cp "$DIR/bin/hotfix-after-deploy.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/prod-url.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/issue-state-lib.sh" "$H/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/"*.sh
printf 'project-1 o/p https://tproj.example - 2 box-t 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/project-1.env"

ghfx_init
# The script's non-REST gh calls: the repo-visibility probe, the PR proof
# comment (-q .id) and the issue state read (-q .state). Every REST comment body
# is captured before gh-rest.sh deletes its file.
ghfx_extra <<'SH'
case "$A" in
  *"-X POST"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
  "api repos/"*"/comments"*) echo 4242; exit 0 ;;
  "api repos/"*"/issues/"*) echo open; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
esac
SH

B="$H/builds/project-1-BH-378-202609251300"; mkdir -p "$B"
SHA=abc1234def5678
ledger() {
  jq -n '{fp:"deadfp",mode:"endpoint",decision:"applied",files:[{path:"scripts/migrations/a.sql",status:"applied"}],after_deploy:null}' \
    > "$B/hotfix-migrate.json"
}
reset() {
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"; : > "$H/logs/ALERTS.log"
  ledger
  cp "$DIR/bin/lib/issue-state-lib.sh" "$H/bin/lib/"
  rm -f "$B/issue-commented"
}
KID="[$(jq -nc '{event:"cross-referenced",source:{type:"issue",issue:{number:401,state:"open",body:"Scope.\nPart of #378"}}}')]"  # TEST-CHANGE BH-4662: the open child the strip cases now need
pr_body()  { ghfx_route GET "repos/o/p/pulls/9" 200 "$(jq -nc --arg b "$1" '{number:9,state:"closed",body:$b}')"; }
timeline() { ghfx_route GET "repos/o/p/issues/378/timeline*" 200 "$1"; }
writes() {
  ghfx_route POST   "repos/o/p/issues/378/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/o/p/issues/378" 200 '{"state":"closed"}'
  ghfx_route DELETE "repos/o/p/issues/378/labels/ai-build" 200 '[]'
  ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"closed","body":"hotfix master","labels":[{"name":"ai-build"}]}'
}
run() {
  ( cd "$T" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" \
      SLUG=o/p PR_URL=https://github.com/o/p/pull/9 \
      bash "$H/bin/hotfix-after-deploy.sh" project-1 "$B" "$SHA" > "$T/out" 2> "$T/err" )
  echo $?
}
n_patch()  { grep -c -- '-X PATCH repos/o/p/issues/378' "$T/gh-argv.log"; }
n_post()   { grep -c -- '-X POST repos/o/p/issues/378/comments' "$T/gh-argv.log"; }
n_delete() { grep -c -- '-X DELETE repos/o/p/issues/378/labels' "$T/gh-argv.log"; }

# H1 Refs: the issue stays open, gets the slice comment, loses ai-build
reset; pr_body $'Hotfix for the rate table.\nRefs #378'; timeline "$KID"; writes  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
RC=$(run)
[ "$RC" = 0 ] && ok || bad "H1: a slice close-out must exit 0 (rc=$RC; $(head -c 300 "$T/err"))"
[ "$(n_patch)" = 0 ] && ok || bad "H1: a Refs hotfix must never close issue 378 ($(n_patch) PATCHes)"
[ "$(n_post)" = 1 ] && ok || bad "H1: exactly one comment on issue 378 (got $(n_post))"
[ "$(head -1 "$T/posted.txt")" = 'Slice delivered: #9; children own the rest.' ] && ok \
  || bad "H1: the issue comment must be the slice comment (got '$(head -1 "$T/posted.txt")')"
grep -q 'Deployed ' "$T/posted.txt" && bad "H1: a slice must not get the 'Deployed ... live' close comment" || ok
[ "$(n_delete)" = 1 ] && ok || bad "H1: a slice must take ai-build off issue 378 once (got $(n_delete))"
grep -q 'left issue 378 open, slice delivered (kept-slice:no-keyword+stripped)' "$T/err" && ok \
  || bad "H1: stderr must say the issue was left open with the word ($(cat "$T/err"))"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "H1: a clean slice settle must not alert ($(cat "$H/logs/ALERTS.log"))"

# H2 Closes, no children: today's close, exactly
reset; pr_body $'Hotfix.\nCloses #378'; timeline '[]'; writes
RC=$(run)
[ "$RC" = 0 ] && [ "$(n_patch)" = 1 ] && ok || bad "H2: a Closes hotfix must close issue 378 (rc=$RC patch=$(n_patch); $(head -c 300 "$T/err"))"
head -1 "$T/posted.txt" | grep -q "^Deployed $SHA for this hotfix" && ok || bad "H2: the close comment is today's deployed comment ($(head -1 "$T/posted.txt"))"
[ "$(n_delete)" = 0 ] && ok || bad "H2: today's hotfix close does not strip ($(n_delete))"
grep -q 'Slice delivered' "$T/posted.txt" && bad "H2: a Closes hotfix posts no slice comment" || ok

# H3 Closes, but an open decomposer child remains
reset; pr_body $'Closes #378'
timeline "[$(jq -nc '{event:"cross-referenced",source:{type:"issue",issue:{number:401,state:"open",body:"Scope.\nPart of #378"}}}')]"
writes
RC=$(run)
[ "$RC" = 0 ] && [ "$(n_patch)" = 0 ] && ok || bad "H3: an open child must keep issue 378 open (rc=$RC patch=$(n_patch))"
[ "$(n_delete)" = 1 ] && grep -q '#401 is still open' "$T/posted.txt" && ok \
  || bad "H3: slice comment naming #401 and one DELETE (delete=$(n_delete) posted=$(cat "$T/posted.txt"))"

# H4 the PR is unreadable: nothing written, one ALERTS line
reset; ghfx_route GET "repos/o/p/pulls/9" 403 '{"message":"nope"}'; timeline '[]'; writes
RC=$(run)
[ "$(n_patch)" = 0 ] && [ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && ok \
  || bad "H4: an undecided guard writes nothing (patch=$(n_patch) post=$(n_post) delete=$(n_delete))"
[ "$(grep -c 'close guard could not decide' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "H4: one ALERTS line naming the undecided guard ($(cat "$H/logs/ALERTS.log"))"

# H5 no issue-state-lib.sh in the tree: fail closed, never close blind
reset; rm -f "$H/bin/lib/issue-state-lib.sh"; pr_body $'Closes #378'; timeline '[]'; writes
RC=$(run)
[ "$(n_patch)" = 0 ] && [ "$(n_post)" = 0 ] && ok || bad "H5: no guard must mean no close (patch=$(n_patch) post=$(n_post))"
grep -q 'no-guard' "$H/logs/ALERTS.log" && ok || bad "H5: no guard must write an ALERTS line naming no-guard ($(cat "$H/logs/ALERTS.log"))"

# H6 the strip fails on a slice: a named word and an ALERTS line, never silence
reset; pr_body $'Refs #378'; timeline "$KID"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
ghfx_route POST   "repos/o/p/issues/378/comments" 201 '{"id":1}'
ghfx_route DELETE "repos/o/p/issues/378/labels/ai-build" 500 '{"message":"boom"}'
ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"open","body":"m","labels":[{"name":"ai-build"}]}'
RC=$(run)
[ "$(n_patch)" = 0 ] && ok || bad "H6: a slice must not close"
grep -q 'kept-slice:no-keyword+strip-failed.*take ai-build off issue 378 by hand' "$H/logs/ALERTS.log" && ok \
  || bad "H6: a failed strip must alert with its word ($(cat "$H/logs/ALERTS.log"))"

# H7 the merge close-out already paid the slice comment into this build record
# (mc_close_shipped / issue_close_shipped write <record>/issue-commented): the
# hotfix lane must not post it a second time; the strip still runs (review D11)
reset; pr_body $'Refs #378'; timeline "$KID"; writes; touch "$B/issue-commented"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
RC=$(run)
[ "$RC" = 0 ] && [ "$(n_post)" = 0 ] && ok || bad "H7: a slice comment already on this record must not be posted again (rc=$RC post=$(n_post))"
[ "$(n_patch)" = 0 ] && [ "$(n_delete)" = 1 ] && ok || bad "H7: no close, and the strip still runs (patch=$(n_patch) delete=$(n_delete))"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "H7: a skipped comment is not a failure ($(cat "$H/logs/ALERTS.log"))"

# H8 the hotfix lane run twice on one record: one comment in total. The first
# run records after_deploy in the ledger, which alone would stop the second, so
# the ledger is reset in between (a ledger write that failed looks like this).
reset; pr_body $'Refs #378'; timeline '[]'; writes
run >/dev/null; ledger; run >/dev/null
[ "$(grep -c 'left issue 378 open' "$T/err")" = 1 ] && ok || bad "H8: the second run must reach the slice close-out ($(cat "$T/err"))"
[ "$(n_post)" = 1 ] && ok || bad "H8: two hotfix runs on one record must post the slice comment once (got $(n_post))"
[ -f "$B/issue-commented" ] && ok || bad "H8: the hotfix slice comment must write <record>/issue-commented"

echo "hotfix-close-guard (BH-2508): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
