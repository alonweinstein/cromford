#!/bin/bash
# tests/hotfix-after-deploy-test.sh — the post-deploy half of the hotfix lane
# (BH-378 / BH-370.4).
#
# WHY THIS TEST EXISTS. bin/hotfix-after-deploy.sh is the only place in the
# harness that says "this hotfix is LIVE" and closes the client's issue on the
# strength of it. Two mistakes are expensive here and both are silent: closing
# an issue whose SQL never applied, and running before the deploy was verified.
# So the assertions are about artifacts, never source text — which filenames
# reached POST /apply, what the PR comment's marker line says, what the ledger
# records, whether `issue close` appears in the gh argv log at all, and in case
# 6 whether the REAL bin/deploy-verify.sh reached the hook only after its own
# `deploy-verify OK` line and kept its verdict when the hook failed.
#
# Run from anywhere: tests/hotfix-after-deploy-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/locks" "$H/state" "$H/flags" "$H/builds" "$T/fakebin"
for f in hotfix-after-deploy.sh apply-migrations.sh fleet-conf.sh prod-url.sh; do
  [ -f "$DIR/bin/$f" ] && cp "$DIR/bin/$f" "$H/bin/$f"
done
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"   # TEST-CHANGE BH-1651: issue close-out is REST
cp "$DIR/bin/lib/issue-state-lib.sh" "$H/bin/lib/"   # TEST-CHANGE BH-2508: the issue close-out asks issue_close_guard first
chmod +x "$H/bin/"*.sh 2>/dev/null
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> '"$T"'/beat.txt\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"

# project-1 is an ENDPOINT project (bin/apply-migrations.sh's own case arm), so
# the fixture gives it the GitHub-Issues board_prefix `-` to drive the close-out
# lane, and project-3 an in-app board prefix to prove that lane posts no issue argv.
printf 'project-1 o/p https://tproj.example - 2 box-t 100.0.0.9\n' >  "$H/fleet.conf"
printf 'project-3 o/b https://bproj.example TP 3 box-b 100.0.0.8\n'    >> "$H/fleet.conf"
: > "$H/env/global.env"
printf 'PROJECT_1_API_BASE=http://stub\nMIGRATION_TOKEN=t\n' > "$H/env/project-1.env"
printf 'PROJECT_3_APP_BASE=http://stub\nMIGRATION_TOKEN=t\n'     > "$H/env/project-3.env"

# ---------------------------------------------------------------------------
# apply-migrations dispatcher: counts invocations and can answer rc 75 once, so
# the retry path is exercised without racing a real flock. The real driver runs
# underneath it in every other case.
# ---------------------------------------------------------------------------
mv "$H/bin/apply-migrations.sh" "$H/bin/apply-migrations-real.sh" 2>/dev/null
cat > "$H/bin/apply-migrations.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/apply.calls"
if [ -f "$T/force75" ]; then
  n=\$(cat "$T/force75")
  if [ "\$n" -gt 0 ]; then echo \$((n-1)) > "$T/force75"; exit 75; fi
fi
exec bash "$H/bin/apply-migrations-real.sh" "\$@"
EOF
chmod +x "$H/bin/apply-migrations.sh"

# ---------------------------------------------------------------------------
# gh / curl stubs. gh records EVERY argv line; curl records every POSTed filename.
# ---------------------------------------------------------------------------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  # TEST-CHANGE BH-1651: the close-out is gh_rest_comment then gh_rest_close. The
  # REST calls are logged as the same "issue comment|close <n>" lines the asserts
  # below already read, with the comment body taken from its file, plus the raw argv.
  *"-i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/rest.log"
    n=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    for a in "\$@"; do case "\$a" in body=@*) printf 'issue comment %s --body %s\n' "\$n" "\$(cat "\${a#body=@}")" >> "$T/gh.log" ;; esac; done
    if [ -f "$T/comment.fail" ] || [ -f "$T/issue-comment.fail" ]; then printf 'HTTP/2 403\r\n\r\n{}'; exit 0; fi
    printf 'HTTP/2 201\r\n\r\n{"id":1}'; exit 0 ;;
  *"-i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/rest.log"
    n=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    printf 'issue close %s (rest)\n' "\$n" >> "$T/gh.log"
    [ -f "$T/close.noflip" ] || echo closed > "$T/issue.reread"
    printf 'HTTP/2 200\r\n\r\n{"state":"closed"}'; exit 0 ;;
  # TEST-CHANGE BH-2508: the close guard reads the PR body and the issue
  # timeline before it lets the close run. A Closes body and no timeline events
  # keep every close case below a delivered close, as it was before the guard.
  *"-i -X GET repos/"*"/pulls/"*)
    printf '%s\n' "\$*" >> "$T/rest.log"
    printf 'HTTP/2 200\r\n\r\n{"number":9,"body":"Closes #378"}'; exit 0 ;;
  *"-i -X GET repos/"*"/issues/"*"/timeline"*)
    printf '%s\n' "\$*" >> "$T/rest.log"
    printf 'HTTP/2 200\r\n\r\n[]'; exit 0 ;;
  *"-i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/rest.log"
    printf 'HTTP/2 200\r\n\r\n{"state":"%s"}' "\$(cat "$T/issue.reread" 2>/dev/null || echo open)"; exit 0 ;;
esac
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  "api repos/"*"/issues/"*"/comments"*)
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment.md" ;; esac; done
    if [ -f "$T/comment.fail" ]; then echo "gh: could not post" >&2; exit 1; fi
    echo 4242; exit 0 ;;
  "api repos/"*"/issues/"*) cat "$T/issue.state" 2>/dev/null || echo open; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""; body=""; prev=""
for a in "\$@"; do
  case "\$a" in http*) url="\$a" ;; esac
  [ "\$prev" = "-d" ] && body="\$a"
  prev="\$a"
done
case "\$url" in
  */status) cat "$T/status.json" 2>/dev/null; exit 0 ;;
  */apply)
    f=\$(printf '%s' "\$body" | sed -E 's/.*"filename":"([^"]*)".*/\1/')
    printf '%s\n' "\$f" >> "$T/posts.log"
    cat "$T/apply-\$f.json" 2>/dev/null || printf '{"ok":true,"status":"applied"}\n'
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

B="$H/builds/project-1-BH-378-202609181301"; mkdir -p "$B"
BB="$H/builds/project-3-BH-378-202609181301";    mkdir -p "$BB"
SHA=abc1234def5678

ledger() { # ledger <build-dir> <mode> <decision> [status-for-files]
  jq -n --arg mode "$2" --arg d "$3" --arg st "${4:-not-pending}" \
    '{fp:"deadfp", mode:$mode, decision:$d,
      files:[{path:"scripts/migrations/a.sql",status:$st},
             {path:"scripts/migrations/b.sql",status:$st}],
      posted_comment_id:4242, after_deploy:null}' > "$1/hotfix-migrate.json"
}

reset() {
  : > "$T/posts.log"; : > "$T/gh.log"; : > "$T/rest.log"; rm -f "$T/issue.reread" "$T/close.noflip" "$T/issue-comment.fail"; : > "$T/beat.txt"; : > "$T/apply.calls"
  : > "$H/logs/ALERTS.log"
  rm -f "$T/comment.md" "$T/comment.fail" "$T/apply-"*.json "$T/force75" "$T/issue.state"
  rm -f "$B/hotfix-migrate.json" "$BB/hotfix-migrate.json"
  scratch_rm "$H/locks"; scratch_rm "$H/flags"; mkdir -p "$H/locks" "$H/flags"
  : > "$H/state/migrations-refused-project-1.txt"
  : > "$H/state/migrations-refused-project-3.txt"
  cat > "$T/status.json" <<'JSON'
{"applied":[{"filename":"old.sql"}],
 "pending":[{"filename":"a.sql","checksum":"c1"},{"filename":"b.sql","checksum":"c2"}]}
JSON
}

run_had() { # run_had <project> <build> [VAR=VAL ...] -> prints rc
  local p="$1" b="$2"; shift 2
  ( cd "$T" && PATH="$T/fakebin:$PATH" env HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      SLUG=o/p PR_URL=https://github.com/o/p/pull/9 HOTFIX_AFTERDEPLOY_RETRY_WAIT=0 \
      "$@" bash "$H/bin/hotfix-after-deploy.sh" "$p" "$b" "$SHA" > "$T/had.out" 2> "$T/had.err" )
  echo $?
}
marker() { head -n1 "$T/comment.md" 2>/dev/null; }
nposts() { local n; n=$(grep -c . "$T/posts.log" 2>/dev/null); echo "${n:-0}"; }

# ===========================================================================
# 1. deferred -> apply both files in ledger order, prove it, close the issue
# ===========================================================================
reset
ledger "$B" endpoint deferred-to-deploy
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] || bad "1: a clean post-deploy apply must exit 0 (got $RC; $(head -c 300 "$T/had.err"))"
[ "$RC" = 0 ] && ok
printf 'a.sql\nb.sql\n' > "$T/want-posts"
diff -q "$T/want-posts" "$T/posts.log" >/dev/null 2>&1 && ok \
  || bad "1: POST order must be exactly a then b (got: $(tr '\n' ' ' < "$T/posts.log"))"
[ "$(marker)" = "<!-- hotfix-migrate-afterdeploy fp=deadfp status=applied -->" ] && ok \
  || bad "1: comment line 1 must be the after-deploy marker with status=applied (got '$(marker)')"
grep -q '"filename":"a.sql"' "$T/comment.md" && grep -q '"filename":"b.sql"' "$T/comment.md" && ok \
  || bad "1: the second proof must carry the driver's own per-file JSON"
grep -q "$SHA" "$T/comment.md" && ok || bad "1: the second proof must name the deployed sha"
[ "$(jq -r '.after_deploy.status' "$B/hotfix-migrate.json")" = applied ] && ok \
  || bad "1: ledger after_deploy.status must be applied (got $(jq -c '.after_deploy' "$B/hotfix-migrate.json"))"
[ "$(jq -r '.after_deploy.sha' "$B/hotfix-migrate.json")" = "$SHA" ] && ok \
  || bad "1: ledger after_deploy.sha must be the deployed sha"
[ "$(jq -r '.fp' "$B/hotfix-migrate.json")" = deadfp ] && \
[ "$(jq -r '.posted_comment_id' "$B/hotfix-migrate.json")" = 4242 ] && ok \
  || bad "1: the ledger rewrite must preserve every other key"
grep -q '^issue comment 378 ' "$T/gh.log" && ok || bad "1: a GitHub-Issues project must get an issue comment (gh log: $(tr '\n' '|' < "$T/gh.log"))"
grep '^issue comment 378 ' "$T/gh.log" | grep -q "$SHA" && ok || bad "1: the issue comment must name the sha"
grep '^issue comment 378 ' "$T/gh.log" | grep -q 'https://tproj.example' && ok \
  || bad "1: the issue comment must carry the production URL"
grep -q '^issue close 378 ' "$T/gh.log" && ok || bad "1: a successful post-deploy apply must close the issue"
grep -q 'HOTFIX POST-DEPLOY' "$H/logs/ALERTS.log" && bad "1: a clean apply must not alert" || ok

# mutation guard for the success WORD set: already-applied is success too
reset
ledger "$B" endpoint deferred-to-deploy
printf '{"ok":true,"status":"already-applied"}\n' > "$T/apply-a.sql.json"
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && [ "$(jq -r '.after_deploy.status' "$B/hotfix-migrate.json")" = applied ] && ok \
  || bad "1b: already-applied is a success word (rc=$RC status=$(jq -r '.after_deploy.status' "$B/hotfix-migrate.json"))"

# ===========================================================================
# 2. one file refused -> failed, alert once, ledger says so, issue stays OPEN
# ===========================================================================
reset
ledger "$B" endpoint deferred-to-deploy
printf '{"ok":true,"status":"refused","reason":"destructive"}\n' > "$T/apply-b.sql.json"
RC=$(run_had project-1 "$B")
[ "$RC" = 1 ] && ok || bad "2: a file that did not apply must exit 1 (got $RC)"
grep -q 'status=failed' <<<"$(marker)" && ok || bad "2: the marker must say status=failed (got '$(marker)')"
grep -q 'issue close' "$T/gh.log" && bad "2: a failed apply must never close the issue" || ok
grep -q 'issue comment' "$T/gh.log" && bad "2: a failed apply must not claim the hotfix is live" || ok
N=$(grep -c 'HOTFIX POST-DEPLOY APPLY FAILED' "$H/logs/ALERTS.log"); [ "$N" = 1 ] && ok \
  || bad "2: exactly one ALERTS line, got $N"
grep 'HOTFIX POST-DEPLOY APPLY FAILED' "$H/logs/ALERTS.log" | grep -q 'b.sql' && ok \
  || bad "2: the alert must name the file that failed ($(cat "$H/logs/ALERTS.log"))"
[ "$(grep -c fleet_alert "$T/beat.txt")" = 1 ] && ok || bad "2: exactly one fleet_alert beat"
[ "$(jq -r '.after_deploy.status' "$B/hotfix-migrate.json")" = failed ] && ok \
  || bad "2: the ledger must record after_deploy.status=failed"

# a /status endpoint nobody could read is a failure, never "nothing pending"
reset
ledger "$B" endpoint deferred-to-deploy
echo 'not json at all' > "$T/status.json"
RC=$(run_had project-1 "$B")
[ "$RC" = 1 ] && ok || bad "2b: an unreadable /status must fail, not pass (got $RC)"
grep -q 'issue close' "$T/gh.log" && bad "2b: an unreadable /status must not close the issue" || ok

# ===========================================================================
# 3. the driver's lock is busy once -> exactly one retry, then success
# ===========================================================================
reset
ledger "$B" endpoint deferred-to-deploy
echo 1 > "$T/force75"
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "3: a busy lock must be retried once and then succeed (got $RC; $(head -c 300 "$T/had.err"))"
[ "$(grep -c . "$T/apply.calls")" = 2 ] && ok \
  || bad "3: the driver must be invoked twice, got $(grep -c . "$T/apply.calls")"
grep -q '^issue close 378 ' "$T/gh.log" && ok || bad "3: the retried success must still close the issue"

# busy twice is a failure, not a pass
reset
ledger "$B" endpoint deferred-to-deploy
echo 2 > "$T/force75"
RC=$(run_had project-1 "$B")
[ "$RC" = 1 ] && ok || bad "3b: a lock busy on both tries must fail (got $RC)"
grep -q 'issue close' "$T/gh.log" && bad "3b: busy twice must never close the issue" || ok
grep -q 'busy' "$T/comment.md" 2>/dev/null && ok || bad "3b: the proof must say the driver was busy"

# ===========================================================================
# 4. no ledger: this build had no hotfix migration. Silence, and no API calls.
# ===========================================================================
reset
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "4: no ledger must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && [ ! -s "$T/gh.log" ] && ok \
  || bad "4: no ledger must touch no API at all (posts=$(nposts) gh=$(tr '\n' '|' < "$T/gh.log"))"

# an unparseable ledger is NOT an absent one
reset
echo '{ this is not json' > "$B/hotfix-migrate.json"
RC=$(run_had project-1 "$B")
[ "$RC" = 1 ] && ok || bad "4b: an unparseable ledger must fail loudly (got $RC)"
grep -q 'issue close' "$T/gh.log" && bad "4b: an unparseable ledger must close nothing" || ok

# ===========================================================================
# 5. decision=applied (the SQL went live with the PR): close-out only
# ===========================================================================
reset
ledger "$B" endpoint applied applied
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5: an already-applied hotfix must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "5: an already-applied hotfix must POST no SQL again (got $(nposts))"
grep -q 'status=applied' <<<"$(marker)" && ok || bad "5: the second proof must still be posted (got '$(marker)')"
grep -q '^issue close 378 ' "$T/gh.log" && ok || bad "5: the issue must be closed"

# an in-app board project gets the PR comment and NO issue argv
reset
ledger "$BB" endpoint applied applied
RC=$(run_had project-3 "$BB" SLUG=o/b PR_URL=https://github.com/o/b/pull/4)
[ "$RC" = 0 ] && ok || bad "5b: in-app board project must exit 0 (got $RC)"
grep -q '^issue ' "$T/gh.log" && bad "5b: a project with an in-app board has no GitHub issue to close" || ok
[ "$(grep -c 'api repos/o/b/issues/4/comments' "$T/gh.log")" = 1 ] && ok \
  || bad "5b: exactly one PR comment for the in-app board project ($(tr '\n' '|' < "$T/gh.log"))"

# an issue someone already closed is left alone
reset
ledger "$B" endpoint applied applied
echo closed > "$T/issue.state"
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5c: an already-closed issue must exit 0 (got $RC)"
grep -q 'issue close' "$T/gh.log" && bad "5c: an already-closed issue must not be closed again" || ok
grep -q 'issue comment' "$T/gh.log" && bad "5c: an already-closed issue must not be commented on" || ok

# a hold/flagged ledger is nobody's close-out
reset
ledger "$B" endpoint hold hold
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5d: a held hotfix must exit 0 (got $RC)"
grep -q 'issue close' "$T/gh.log" && bad "5d: a held hotfix must never close the issue" || ok
[ "$(nposts)" = 0 ] && ok || bad "5d: a held hotfix must POST nothing"

# AT 5 says "(workflow or endpoint)": a workflow-mode hotfix whose SQL already
# went in with the PR gets the same close-out and POSTs nothing
reset
ledger "$B" workflow applied applied
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5e: a workflow-mode applied hotfix must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "5e: a workflow-mode applied hotfix must POST no SQL (got $(nposts))"
grep -q '^issue close 378 ' "$T/gh.log" && ok || bad "5e: the workflow-mode issue must be closed"

# once per merge sha, for real: a by-hand re-run on a ledger that already records
# this sha as applied spends no API call and posts no duplicate proof
: > "$T/gh.log"; : > "$T/posts.log"
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5f: a re-run on an applied ledger must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && [ ! -s "$T/gh.log" ] && ok \
  || bad "5f: a re-run on an applied ledger must touch no API (posts=$(nposts) gh=$(tr '\n' '|' < "$T/gh.log"))"
grep -q 'already applied' "$T/had.err" && ok || bad "5f: the re-run must say it was already applied"

# a proof that did not post after a SUCCESSFUL apply is an alert, not a whisper:
# the ledger says applied, the PR carries nothing, and someone has to be told
reset
ledger "$B" endpoint deferred-to-deploy
touch "$T/comment.fail"
RC=$(run_had project-1 "$B")
[ "$RC" = 1 ] && ok || bad "5g: a proof that did not post must exit 1 (got $RC)"
[ "$(nposts)" = 2 ] && ok || bad "5g: the apply itself must still have run (posts=$(nposts))"
grep -q 'HOTFIX CLOSE-OUT OWED' "$H/logs/ALERTS.log" && ok || bad "5g: a proof that did not post must write an ALERTS line"
grep -q 'closeout' "$T/beat.txt" && ok || bad "5g: a proof that did not post must beat a fleet_alert"
grep -q 'issue close' "$T/gh.log" && bad "5g: a proof that did not post must close nothing" || ok

# the other close-out branch that spends no gh write: an issue whose state could
# not be read is left alone, and the same owed line + beat tell a human. The
# stub answers an empty state when issue.state is an empty file.
reset
ledger "$B" endpoint applied applied
: > "$T/issue.state"
RC=$(run_had project-1 "$B")
[ "$RC" = 0 ] && ok || bad "5h: an unreadable issue state is a close-out owed, not an apply failure (got $RC)"
grep -q 'HOTFIX CLOSE-OUT OWED.*unreadable' "$H/logs/ALERTS.log" && ok \
  || bad "5h: an unreadable issue state must write the owed ALERTS line ($(cat "$H/logs/ALERTS.log"))"
grep -q 'closeout' "$T/beat.txt" && ok || bad "5h: an unreadable issue state must beat a fleet_alert"
grep -q 'issue close' "$T/gh.log" && bad "5h: an unreadable issue state must close nothing" || ok
grep -q 'issue comment' "$T/gh.log" && bad "5h: an unreadable issue state must comment nothing" || ok

# BH-1651: the close-out is REST — comment POST, then the PATCH, then the fresh
# re-read gh_rest_close answers on — and each failure keeps its own alert.
reset
ledger "$B" endpoint applied applied
RC=$(run_had project-1 "$B")
ORDER=$(grep -oE -- '-X (POST|PATCH|GET) repos/o/p/issues/378(/comments)?' "$T/rest.log" | tail -3 | tr '\n' '|')
[ "$ORDER" = "-X POST repos/o/p/issues/378/comments|-X PATCH repos/o/p/issues/378|-X GET repos/o/p/issues/378|" ] && ok \
  || bad "5i: the REST close-out must be comment, close, re-read in that order (got $ORDER)"
grep -q -- '-X PATCH .*state=closed' "$T/rest.log" && ok || bad "5i: the PATCH must set state=closed"
grep -q 'HOTFIX' "$H/logs/ALERTS.log" && bad "5i: a clean REST close-out must not alert" || ok
reset
ledger "$B" endpoint applied applied
touch "$T/issue-comment.fail"
RC=$(run_had project-1 "$B")
grep -q -- '-X PATCH' "$T/rest.log" && bad "5j: a 403 on the comment must never close the issue" || ok
grep -q 'HOTFIX CLOSE-OUT OWED.*took no deployed comment' "$H/logs/ALERTS.log" && ok \
  || bad "5j: a 403 on the comment must write the no-comment alert ($(cat "$H/logs/ALERTS.log"))"
reset
ledger "$B" endpoint applied applied
touch "$T/close.noflip"
RC=$(run_had project-1 "$B")
grep -q 'HOTFIX CLOSE-OUT OWED.*the close failed' "$H/logs/ALERTS.log" && ok \
  || bad "5k: a close whose re-read still says open must write the close-failed alert ($(cat "$H/logs/ALERTS.log"))"
# 5l. no temp file for the comment body is a comment that never went out: no
#     close, and the no-comment alert (BH-1651). Only the comment's mktemp fails.
reset
ledger "$B" endpoint applied applied
REALMK=$(command -v mktemp)
mkdir -p "$T/mkfail"
printf '#!/bin/bash\ncase "$*" in *hotfix-comment*) exit 1 ;; esac\nexec %s "$@"\n' "$REALMK" > "$T/mkfail/mktemp"
chmod +x "$T/mkfail/mktemp"
RC=$(PATH="$T/mkfail:$PATH" run_had project-1 "$B")
grep -q -- '-X POST' "$T/rest.log" && bad "5l: no temp file must post no comment" || ok
grep -q -- '-X PATCH' "$T/rest.log" && bad "5l: no temp file must never close the issue" || ok
grep -q 'HOTFIX CLOSE-OUT OWED.*took no deployed comment' "$H/logs/ALERTS.log" && ok \
  || bad "5l: no temp file must write the no-comment alert ($(cat "$H/logs/ALERTS.log"))"

# ===========================================================================
# 6. the production caller: the REAL bin/deploy-verify.sh reaches the hook only
#    after its own OK line, and a failing hook never changes its verdict.
# ===========================================================================
H6="$T/h6"
mkdir -p "$H6/bin/lib" "$H6/logs" "$H6/env" "$T/build6"
cp "$DIR/bin/deploy-verify.sh" "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$H6/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$H6/bin/lib/"
chmod +x "$H6/bin/"*.sh
printf 'tproj o/tproj https://tproj.example - 2 box-t 100.0.0.9\n' > "$H6/fleet.conf"
: > "$H6/env/global.env"; : > "$H6/env/tproj.env"
printf '#!/bin/bash\nexit 0\n' > "$H6/bin/beat.sh"; chmod +x "$H6/bin/beat.sh"
# the hook itself, stubbed: it marks the log and FAILS
cat > "$H6/bin/hotfix-after-deploy.sh" <<'EOF'
#!/bin/bash
echo "HOOK RAN for $1 $3"
exit 1
EOF
chmod +x "$H6/bin/hotfix-after-deploy.sh"
mkdir -p "$T/fakebin6"
cat > "$T/fakebin6/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *deployments/*statuses*) echo success ;;
  *deployments*) echo '[{"id":77,"environment":"production","created_at":"2026-09-18T03:00:00Z"}]' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin6/gh"
printf '#!/bin/bash\necho 200\nexit 0\n' > "$T/fakebin6/curl"; chmod +x "$T/fakebin6/curl"

RUN6() {
  : > "$T/build6/pipeline.log"; : > "$H6/logs/ALERTS.log"
  ( PATH="$T/fakebin6:$PATH" HARNESS="$H6" FLEET_CONF="$H6/fleet.conf" \
      bash "$H6/bin/deploy-verify.sh" tproj o/tproj deadbeefdeadbeef "$T/build6" >/dev/null 2>&1 )
}

# (a) with a ledger present the hook runs, AFTER the OK line, and its rc 1 is not the gate's
printf '{"fp":"x","mode":"endpoint","decision":"deferred-to-deploy","files":[],"after_deploy":null}\n' \
  > "$T/build6/hotfix-migrate.json"
RUN6; RC=$?
[ "$RC" = 0 ] && ok || bad "6: a failing post-deploy hook must not change the deploy verdict (rc=$RC)"
grep -q 'HOOK RAN for tproj deadbeefdeadbeef' "$T/build6/pipeline.log" && ok \
  || bad "6: deploy-verify must invoke the hook (log: $(cat "$T/build6/pipeline.log"))"
OKLINE=$(grep -n 'deploy-verify OK' "$T/build6/pipeline.log" | head -1 | cut -d: -f1)
HOOKLINE=$(grep -n 'HOOK RAN' "$T/build6/pipeline.log" | head -1 | cut -d: -f1)
[ -n "$OKLINE" ] && [ -n "$HOOKLINE" ] && [ "$HOOKLINE" -gt "$OKLINE" ] && ok \
  || bad "6: the hook must run AFTER the deploy-verify OK line (ok=$OKLINE hook=$HOOKLINE)"
grep -q 'DEPLOY-VERIFY FAILED' "$H6/logs/ALERTS.log" && bad "6: the hook's failure is not a deploy failure" || ok

# (b) no ledger -> no hook at all (a build with no hotfix SQL calls nothing)
rm -f "$T/build6/hotfix-migrate.json"
RUN6; RC=$?
[ "$RC" = 0 ] && ok || bad "6b: an ordinary merge must still verify (rc=$RC)"
grep -q 'HOOK RAN' "$T/build6/pipeline.log" && bad "6b: no hotfix ledger means no hook" || ok

echo "hotfix-after-deploy-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
