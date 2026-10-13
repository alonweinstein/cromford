#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/pr-url-reconcile-restack.bh-1904-test.sh — BH-1904: a stacked child
# whose create failed, and whose parent then MERGED and had its branch deleted,
# is restacked onto the project base and its PR opened by bin/pr-url-reconcile.sh.
#
# THE DEFECT THIS PINS (TK-3128 -> project-5 #3298). The record read
# `PR_CREATE_FAILED … | STACKED on ticket/bh-1 (… PR 1)`. No PR existed on the
# child branch, so the lane paged `gh pr create --head ticket/bh-2 --base
# ticket/bh-1`, a base that no longer existed once the parent merged. A human
# rebased the child and opened the PR by hand.
#
# Every case drives the REAL lane (bin/pr-url-reconcile.sh, as cron runs it)
# against a scratch $HARNESS carrying the real conductor lib, and a REAL bare
# origin wired in with url.<origin>.insteadOf for both remote spellings, so every
# git assertion is about the origin's own refs. gh is a stub that records every
# argv and answers the branch and compare reads off that same origin.
#
# D1 MUTATIONS, run once before the PR and confirmed red: delete the
# restack_orphan call (A red), drop the gaveup check (B2 red), write the
# restacked marker after the create instead of before it (F red), skip the
# parent-branch 404 check (D red).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-url-reconcile-restack.bh-1904-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
LANE="$DIR/bin/pr-url-reconcile.sh"
[ -f "$LANE" ] || exit 1   # impact: bin/pr-url-reconcile.sh
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: bin/lib/mc/rebase.sh
REALGIT=$(command -v git)
SLUG=example-org/cromford
PURL="https://github.com/$SLUG/pull/1"
NEWURL="https://github.com/$SLUG/pull/42"

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# ── the scratch harness: the conductor family's fixture, plus the lane's libs ─
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
# verdict-parse.sh is NOT copied: it resolves its window knob off its own
# checkout's catalog/lanes.d/_lib.json, and a scratch hub has none, so a copy
# here reads every verdict as unknown. The lane falls back to the checkout's.
cp "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/result-pr-url.sh" "$DIR/bin/lib/gh-app-auth.sh" \
   "$H/bin/lib/" || exit 1
cp "$DIR/bin/fleet-conf.sh" "$H/bin/" || exit 1
printf 'cromford example-org/cromford - - 3 box-small 10.0.0.7\n' > "$H/fleet.conf"
# No hub clone of the project: mc_restack takes its scratch-clone path, which is
# the one that reads the origin through the insteadOf above.
mkdir -p "$T/repos"

# git: the real one, with every push written to a log a case can count.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/pushes.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"

# gh: every argv to gh-argv.txt. Reads answer `gh api -i` shaped (status line,
# headers, blank line, body); the branch and compare reads are computed off the
# origin itself, so they are true about whatever the lane pushed.
# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
hold_fixture_libs "$DIR" "$H" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
G="$REALGIT"; O="$T/origin.git"
say() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "\$1" "\$2"; }
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"-X POST repos/$SLUG/pulls "*)
    printf '%s\n' "\$*" >> "$T/posts.txt"
    all="\$*"; cp "\${all##*body=@}" "$T/post-body.txt" 2>/dev/null
    case "\$(cat "$T/post-mode" 2>/dev/null)" in
      403) say '403 Forbidden' '{"message":"Resource not accessible by integration"}' ;;
      500) say '500 Internal Server Error' '{"message":"boom"}' ;;
      *)   say '201 Created' '{"number":42,"html_url":"$NEWURL"}' ;;
    esac; exit 0 ;;
  *"pulls?head=example-org:ticket/bh-2&state="*) say '200 OK' '[]'; exit 0 ;;
  # TEST-CHANGE (BH-5234): mc_restack reads the restacked branch's own open
  # children before it pushes; ticket/bh-2 has none.
  *"pulls?state=open&base=ticket%2Fbh-2&per_page=100"*) say '200 OK' '[]'; exit 0 ;;
  *" repos/$SLUG/pulls/1")
    case "\$(cat "$T/parent-mode")" in
      502)    say '502 Bad Gateway' '{"message":"bad gateway"}' ;;
      open)   say '200 OK' "\$(jq -nc --arg s "\$(cat "$T/phead")" '{number:1,state:"open",merged_at:null,head:{ref:"ticket/bh-1",sha:\$s},html_url:"$PURL"}')" ;;
      closed) say '200 OK' "\$(jq -nc --arg s "\$(cat "$T/phead")" '{number:1,state:"closed",merged_at:null,head:{ref:"ticket/bh-1",sha:\$s},html_url:"$PURL"}')" ;;
      *)      say '200 OK' "\$(jq -nc --arg s "\$(cat "$T/phead")" '{number:1,state:"closed",merged_at:"2026-09-24T12:00:00Z",head:{ref:"ticket/bh-1",sha:\$s},html_url:"$PURL"}')" ;;
    esac; exit 0 ;;
  *" repos/$SLUG/branches/"*)
    all="\$*"; b="\${all##*/branches/}"; b="\${b//%2F//}"
    [ -f "$T/branch-403" ] && { say '403 Forbidden' '{"message":"forbidden"}'; exit 0; }
    if s=\$("\$G" -C "\$O" rev-parse -q --verify "refs/heads/\$b" 2>/dev/null); then
      say '200 OK' "{\"name\":\"\$b\",\"commit\":{\"sha\":\"\$s\"}}"
    else
      say '404 Not Found' '{"message":"Branch not found"}'
    fi; exit 0 ;;
  *" repos/$SLUG/compare/"*)
    all="\$*"; r="\${all##*/compare/}"; a="\${r%%...*}"; h="\${r##*...}"
    a=\$("\$G" -C "\$O" rev-parse -q --verify "\$a^{commit}" 2>/dev/null) || { say '404 Not Found' '{"message":"Not Found"}'; exit 0; }
    h=\$("\$G" -C "\$O" rev-parse -q --verify "\$h^{commit}" 2>/dev/null) || { say '404 Not Found' '{"message":"Not Found"}'; exit 0; }
    ah=\$("\$G" -C "\$O" rev-list --count "\$a..\$h"); bh=\$("\$G" -C "\$O" rev-list --count "\$h..\$a")
    if [ "\$ah" = 0 ] && [ "\$bh" = 0 ]; then st=identical
    elif [ "\$bh" = 0 ]; then st=ahead
    elif [ "\$ah" = 0 ]; then st=behind
    else st=diverged; fi
    say '200 OK' "{\"status\":\"\$st\",\"ahead_by\":\$ah,\"behind_by\":\$bh}"; exit 0 ;;
esac
say '404 Not Found' '{"message":"no stub arm"}'
exit 0
EOF
chmod +x "$T/fakebin/gh"

# fixture <case> — a fresh origin: main, the parent ticket/bh-1 (two commits),
# the child ticket/bh-2 (one commit on the parent), the parent SQUASH-merged
# into main and its branch deleted from origin. The parent's pre-merge head
# stays reachable as refs/pull/1/head, as it does on GitHub.
#   conflict  main also edits the child's line, so the replay conflicts
#   forced    the parent is force-pushed AFTER the child was cut, and the
#             rewritten head is the one that merged (not in the child's history)
#   alive     the parent's branch is NOT deleted
#   restacked the child was already rebased onto main and pushed (a crash
#             between the push and the marker on an earlier tick)
BD=cromford-BH-2-202609241200
REC="$H/builds/$BD"
fixture() {
  local mode="${1:-}" S="$T/seed"
  rm -rf "$T/origin.git" "$S" "$H/tmp/conductor" "$H/builds" "$H/logs"
  mkdir -p "$H/builds" "$H/logs" "$REC"
  : > "$T/pushes.txt"; : > "$T/gh-argv.txt"; : > "$T/posts.txt"
  rm -f "$T/post-mode" "$T/branch-403" "$T/post-body.txt"
  echo merged > "$T/parent-mode"
  touch "$H/flags/merge-conductor-actions"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  printf 'base\n' > "$S/a.txt"; printf 'c0\n' > "$S/child.txt"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb ticket/bh-1
  printf 'p1\n' > "$S/p1.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p1
  printf 'p2\n' > "$S/p2.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p2
  "$REALGIT" -C "$S" checkout -qb ticket/bh-2
  printf 'child\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam child
  CHILD0=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q ticket/bh-1
  if [ "$mode" = forced ]; then
    printf 'p2-rewritten\n' > "$S/p2.txt"; "$REALGIT" -C "$S" commit -q --amend -am p2b
  fi
  PHEAD=$("$REALGIT" -C "$S" rev-parse HEAD); printf '%s' "$PHEAD" > "$T/phead"
  "$REALGIT" -C "$S" checkout -q main
  "$REALGIT" -C "$S" merge -q --squash ticket/bh-1 >/dev/null && "$REALGIT" -C "$S" commit -qm 'parent (#1)'
  if [ "$mode" = conflict ]; then
    printf 'main-edit\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam 'main edits the child line'
  fi
  "$REALGIT" -C "$S" push -q origin main ticket/bh-2 "$PHEAD:refs/pull/1/head" 2>/dev/null
  [ "$mode" = alive ] && "$REALGIT" -C "$S" push -q origin ticket/bh-1 2>/dev/null
  if [ "$mode" = restacked ]; then
    "$REALGIT" -C "$S" checkout -q ticket/bh-2
    "$REALGIT" -C "$S" rebase -q --onto main "$PHEAD" >/dev/null 2>&1
    "$REALGIT" -C "$S" push -qf origin ticket/bh-2 2>/dev/null
  fi
  CHEAD=$("$REALGIT" -C "$T/origin.git" rev-parse ticket/bh-2)
  # The record: a failed create carrying the ratchet's redacted stack note.
  printf '%s\n' "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. | STACKED on ticket/bh-1 (example-org/cromford PR 1)" \
    "TIER: 2" > "$REC/RESULT"
  printf 'VERDICT: APPROVE\nTIER: 2\n' > "$REC/review.md"
  printf '2026-09-24 12:00:00Z pr create failed and no open PR exists on ticket/bh-2: rate limited\n' > "$REC/pipeline.log"
  printf '{"title":"the child ticket"}\n' > "$REC/ticket-meta.json"
  printf 'What: the child.\n' > "$REC/pr-body.md"
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
run_lane() { # the lane exactly as cron runs it, against the scratch hub
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" MC_REPOS="$T/repos" PATH="$T/fakebin:$PATH"
    bash "$LANE" ) >"$T/stdout.txt" 2>&1
}
count()   { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s\n' "${n:-0}"; }
alerts()  { count . "$H/logs/ALERTS.log"; }
pushes()  { count '^PUSH' "$T/pushes.txt"; }
posts()   { count . "$T/posts.txt"; }
LOGF="$H/logs/pr-url-reconcile.log"

# ============================================================================
# A. The parent merged and its branch is gone: rebase --onto main <parent
#    pre-merge head>, push, open the PR against main, re-link the record.
# ============================================================================
fixture; run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "A: the lane must exit 0, got $RC: $(cat "$T/stdout.txt")"
[ "$(origin_rev ticket/bh-2)" != "$CHEAD" ] \
  && ok || bad "A: origin's ticket/bh-2 must have moved (still $CHEAD). log: $(cat "$LOGF" 2>/dev/null)"
[ "$(origin_rev ticket/bh-2^)" = "$(origin_rev main)" ] \
  && ok || bad "A: the child's new first parent must be main's tip (child^=$(origin_rev ticket/bh-2^) main=$(origin_rev main))"
[ "$("$REALGIT" -C "$T/origin.git" diff --name-only main ticket/bh-2)" = child.txt ] \
  && ok || bad "A: main..child must carry only the child's file (got: $("$REALGIT" -C "$T/origin.git" diff --name-only main ticket/bh-2 | tr '\n' ' '))"
[ "$(posts)" = 1 ] && ok || bad "A: exactly one POST pulls (got $(posts): $(cat "$T/posts.txt"))"
grep -q -- '-f head=ticket/bh-2 -f base=main ' "$T/posts.txt" \
  && ok || bad "A: the PR must be opened head=ticket/bh-2 base=main (got: $(cat "$T/posts.txt"))"
grep -q -- '-f title=BH-2: the child ticket ' "$T/posts.txt" \
  && ok || bad "A: the title must be the ticket's, prefixed with the key (got: $(cat "$T/posts.txt"))"
head -n 1 "$REC/RESULT" | grep -qE "^PR_CREATED $NEWURL \| RECONCILED " \
  && ok || bad "A: RESULT line 1 must be 'PR_CREATED <url> | RECONCILED …' (got: $(head -n 1 "$REC/RESULT"))"
grep -q "^RESTACKED: $PURL $PHEAD -> $(origin_rev ticket/bh-2) onto main$" "$REC/RESULT" \
  && ok || bad "A: RESULT must carry the RESTACKED: line (got: $(cat "$REC/RESULT"))"
grep -q '^RECONCILED_FROM: PR_CREATE_FAILED' "$REC/RESULT" \
  && ok || bad "A: RESULT must keep RECONCILED_FROM: (got: $(cat "$REC/RESULT"))"
[ "$(grep -c "^PR: $NEWURL$" "$REC/RESULT")" = 1 ] && ok || bad "A: exactly one PR: line"
[ -f "$REC/.pr-url-reconciled" ] && ok || bad "A: .pr-url-reconciled must be touched"
[ "$(alerts)" = 0 ] && ok || bad "A: nothing is paged when the lane did the work (got: $(cat "$H/logs/ALERTS.log"))"
[ "$(cat "$REC/.pr-url-reconcile-restacked" 2>/dev/null)" = "$(origin_rev ticket/bh-2)" ] \
  && ok || bad "A: the restacked marker must hold the pushed sha"
BODYF=$(grep -oE 'body=@[^ ]+' "$T/posts.txt" | head -n 1)
[ -z "$(ls "$REC"/pr-body.restack.* 2>/dev/null)" ] && ok || bad "A: the tmp body file must be removed"
cmp -s "$REC/pr-body.md" <(printf 'What: the child.\n') && ok || bad "A: pr-body.md itself must never be edited"
[ -n "$BODYF" ] && ok || bad "A: the POST must carry a body file"
grep -q '^What: the child\.$' "$T/post-body.txt" 2>/dev/null && ok || bad "A: the PR body must be the build's own pr-body.md"
grep -q "^Restacked by pr-url-reconcile: the parent $PURL merged and deleted \`ticket/bh-1\`, so this branch was rebased --onto main ${PHEAD:0:8} and the PR opened against main\.$" "$T/post-body.txt" 2>/dev/null \
  && ok || bad "A: the PR body must carry the restack note (got: $(cat "$T/post-body.txt" 2>/dev/null))"
# A second tick: the record is linked and never walked again.
: > "$T/gh-argv.txt"; run_lane
[ "$(pushes)" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "A: a second tick must push and POST nothing more"
[ -s "$T/gh-argv.txt" ] && bad "A: a linked record is never read again (got: $(cat "$T/gh-argv.txt"))" || ok

# ============================================================================
# B. The replay conflicts: ONE alert naming the file, nothing pushed, no POST,
#    terminal. B2: a second tick adds nothing.
# ============================================================================
fixture conflict; run_lane
[ "$(alerts)" = 1 ] && ok || bad "B: exactly one ALERTS line (got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q 'conflicts in: child.txt' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "B: the alert must name the conflicting file (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q 'Nothing pushed' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "B: the alert must say nothing was pushed"
grep -q 'open it by hand' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "B: the ordinary 'open it by hand' page must not be sent as well" || ok
grep -q -- '--base ticket/bh-1' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "B: no fix command may name the dead parent branch as the base" || ok
[ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "B: origin's child must be untouched"
[ "$(pushes)" = 0 ] && ok || bad "B: a conflicted replay is never pushed"
[ "$(posts)" = 0 ] && ok || bad "B: no POST on a conflict"
[ -f "$REC/.pr-url-reconcile-restack-gaveup" ] && ok || bad "B: the gaveup marker must exist"
head -n 1 "$REC/RESULT" | grep -q '^PR_CREATE_FAILED' && ok || bad "B: line 1 must be unchanged"
: > "$T/gh-argv.txt"; run_lane
[ "$(alerts)" = 1 ] && ok || bad "B2: a second tick must not page again (got $(alerts))"
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "B2: a second tick must push and POST nothing"
grep -q "pulls/1$" "$T/gh-argv.txt" && bad "B2: a given-up record must not read the parent PR again" || ok

# ============================================================================
# C. The parent PR is still OPEN: not this arm's case, today's page.
# ============================================================================
fixture; echo open > "$T/parent-mode"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "C: an open parent: no push, no POST"
grep -q -- 'open it by hand: gh pr create --head ticket/bh-2 --base ticket/bh-1' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "C: today's page with --base ticket/bh-1 (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
# C2. Closed unmerged (a rebuild, BH-458's territory): today's page too.
fixture; echo closed > "$T/parent-mode"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "C2: a parent closed unmerged: no push, no POST"
grep -q 'open it by hand' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "C2: today's page"

# ============================================================================
# D. The parent merged but its branch still exists: today's page.
# ============================================================================
fixture alive; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "D: a live parent branch: no push, no POST"
grep -q 'open it by hand' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "D: today's page (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
# D2. The branch read 403s: UNKNOWN, no page, no push.
fixture; touch "$T/branch-403"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "D2: a 403 branch read: no push, no POST, no page"
grep -q 'UNKNOWN' "$LOGF" && ok || bad "D2: one UNKNOWN log line (got: $(cat "$LOGF"))"

# ============================================================================
# E. The conductor is not armed: no push, a `would restack` line, today's page.
# ============================================================================
fixture; rm -f "$H/flags/merge-conductor-actions"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E: an unarmed conductor: no push, no POST"
grep -q 'would restack' "$LOGF" && ok || bad "E: the log must say 'would restack' (got: $(cat "$LOGF"))"
grep -q 'open it by hand' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "E: today's page is still sent"

# ============================================================================
# F. The push lands, the create is refused (403); the next tick creates it
#    without a second rebase.
# ============================================================================
fixture; echo 403 > "$T/post-mode"; run_lane
MOVED=$(origin_rev ticket/bh-2)
[ "$MOVED" != "$CHEAD" ] && ok || bad "F: tick 1 must push the restack"
[ "$(cat "$REC/.pr-url-reconcile-restacked" 2>/dev/null)" = "$MOVED" ] \
  && ok || bad "F: the restacked marker must hold the pushed sha after a failed create"
head -n 1 "$REC/RESULT" | grep -q '^PR_CREATE_FAILED' && ok || bad "F: line 1 is unchanged after a failed create"
[ "$(alerts)" = 0 ] && ok || bad "F: one failed create is not a page (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
rm -f "$T/post-mode"; run_lane
[ "$(origin_rev ticket/bh-2)" = "$MOVED" ] && ok || bad "F: tick 2 must not rebase again"
[ "$(pushes)" = 1 ] && ok || bad "F: exactly one push over both ticks (got $(pushes))"
head -n 1 "$REC/RESULT" | grep -qE "^PR_CREATED $NEWURL \| RECONCILED " \
  && ok || bad "F: tick 2 links the record (got: $(head -n 1 "$REC/RESULT"))"
[ "$(alerts)" = 0 ] && ok || bad "F: no page over both ticks"

# ============================================================================
# G. The parent PR read 502s: UNKNOWN. No push, no POST, no page.
# ============================================================================
fixture; echo 502 > "$T/parent-mode"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "G: a 502: no push, no POST, no page"
[ "$(grep -c 'UNKNOWN' "$LOGF")" = 1 ] && ok || bad "G: exactly one UNKNOWN log line (got: $(cat "$LOGF"))"

# ============================================================================
# H. The parent was rewritten after the child was cut: ONE page, nothing pushed.
# ============================================================================
fixture forced; run_lane
[ "$(alerts)" = 1 ] && ok || bad "H: exactly one ALERTS line (got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q "is not in ticket/bh-2's history" "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "H: the alert must say the parent head is not in the child's history"
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "H: nothing pushed, nothing POSTed"
[ -f "$REC/.pr-url-reconcile-restack-gaveup" ] && ok || bad "H: terminal"

# ============================================================================
# I. The create answers 500 three ticks running: ONE page on the third.
# ============================================================================
fixture; echo 500 > "$T/post-mode"
run_lane; run_lane
[ "$(alerts)" = 0 ] && ok || bad "I: two failed tries are not a page yet (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
run_lane
[ "$(alerts)" = 1 ] && ok || bad "I: the third failed try pages once (got $(alerts))"
grep -q 'failed 3 times' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "I: the page must say it failed 3 times"
[ -f "$REC/.pr-url-reconcile-restack-gaveup" ] && ok || bad "I: the gaveup marker must exist"
[ "$(pushes)" = 1 ] && ok || bad "I: one push over three ticks (got $(pushes))"
run_lane
[ "$(alerts)" = 1 ] && [ "$(posts)" = 3 ] && ok || bad "I: a fourth tick does nothing (alerts $(alerts), posts $(posts))"

# ============================================================================
# J. A BLOCK verdict owes no PR: no push, no alert.
# ============================================================================
fixture; printf 'VERDICT: BLOCK\n' > "$REC/review.md"; run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "J: BLOCK: no push, no POST, no page"

# ============================================================================
# K. The crash window: origin's child is already on main and no marker says so.
#    No second rebase (it would be a false rc 6 page); the PR is opened.
# ============================================================================
fixture restacked; run_lane
[ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "K: the already-restacked child must not be rebased again"
[ "$(pushes)" = 0 ] && ok || bad "K: no push"
grep -q -- '-f head=ticket/bh-2 -f base=main ' "$T/posts.txt" && ok || bad "K: the PR is opened against main"
[ "$(alerts)" = 0 ] && ok || bad "K: no page (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
head -n 1 "$REC/RESULT" | grep -qE "^PR_CREATED $NEWURL " && ok || bad "K: the record is linked"

# ============================================================================
# L. A record with no STACKED note is today's page, byte for byte.
# ============================================================================
fixture
printf '%s\n' "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded." "TIER: 2" > "$REC/RESULT"
run_lane
[ "$(pushes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L: not stacked: no push, no POST"
grep -q -- 'open it by hand: gh pr create --head ticket/bh-2 --base main' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "L: today's page (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

echo "pr-url-reconcile-restack.bh-1904-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
