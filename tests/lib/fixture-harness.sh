# tests/lib/fixture-harness.sh — the ONE scratch-harness fixture for the merge
# conductor family and the blocked-resolver family. Sourced by suites, never
# executed. Not a suite: tests/*.sh does not glob tests/lib/.
#
# WHY IT EXISTS (BH-1196). Six mc-family suites carried the same eight-line
# fixture block — the scratch tree, five `cp` of sibling libs, `cp bin/lib/mc/*.sh`
# and the REST emitter — and tests/mc/classify-test.sh carried it twice. The
# blocked-resolver monolith carried its own hundred-line cousin, and when it was
# split into seven suites that block would have been copied seven more times. A
# fixture change is then N edits, N of which are "the one nobody remembered",
# and a suite that half-installs its harness is green on a lane that refused
# every tick. One file, one edit.
#
# THE SHAPE, AND WHY EVERY FUNCTION TAKES ITS ROOTS AS ARGUMENTS. Nothing here
# reads $DIR, $T or $H as an inherited global: a suite that forgot to set one
# would otherwise install its fixture into somebody else's tree. fx_br_harness
# and fx_br_ladder_git DO set DIR/T/H as globals from their own arguments before
# they run, because the helper functions they define (RUN, ROW, SPENT, mkbranch,
# osha) are the monolith's own, verbatim, and read those names at CALL time.
#
# WHAT STAYS IN THE SUITE, ON PURPOSE:
#   * `. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init` — sourcing the thing
#     under test is the suite's own act, and it is read there.
#   * `export HARNESS=...` for the mc family. The br family must NOT export it
#     (tests/no-harness-export-test.sh's rule: the lane has to start without it),
#     so no function here exports it either.
#   * the `cp` of the scripts a suite DRIVES, and one rooted `$DIR/...` token per
#     suite, so bin/test-impact.sh keeps selecting the family when the lane or
#     its modules change.
#
# Every install function returns non-zero on the first failed mkdir/cp of a file
# it needs, and every caller appends `|| exit 1`: a fixture that half-installs
# must never produce a green suite (the lesson tests/lib/br-modules.sh already
# carries). fx_br_ladder_git is the exception and says so here rather than
# pretending otherwise — it is the monolith's git fixture verbatim, and its
# `git init`/`git push` lines carry no handlers there either; a failure inside it
# surfaces as the section-8 assertions going red, which is what it did before.
# shellcheck shell=bash

# shellcheck source=tests/lib/rb-all.sh
. "$(dirname "${BASH_SOURCE[0]}")/rb-all.sh" || return 1
# shellcheck source=tests/lib/br-modules.sh
. "$(dirname "${BASH_SOURCE[0]}")/br-modules.sh" || return 1

fx_tree() { # fx_tree <T> — the scratch harness tree both families run in
  mkdir -p "$1/h/bin/lib" "$1/h/logs" "$1/h/state" "$1/h/flags" "$1/h/locks" \
           "$1/h/builds" "$1/h/env" "$1/fakebin" || return 1
}

fx_restpr() { # fx_restpr <repo-dir> <T>
  # The shared REST answer emitter. gh-rest.sh judges the HTTP STATUS LINE that
  # `gh api -i` prints, so a stub arm that just echoes JSON says nothing at all;
  # `restpr` prints a whole response. tests/lib/rest-emit.sh documents the shapes.
  cp "$1/tests/lib/rest-emit.sh" "$2/fakebin/restpr" || return 1
  chmod +x "$2/fakebin/restpr" || return 1
}

fx_mc_harness() { # fx_mc_harness <repo-dir> <T> — the merge-conductor family's fixture
  fx_tree "$2" || return 1
  # gh-rest.sh rides along with the conductor lib. BOTH lanes need it: every
  # decision read goes through it (BH-784), and bin/lib/gh-pr-list.sh reads its
  # lists through the same contract (BH-782). Without the file beside them, each
  # answers 75 "no contract lib on this box" to every read and the suite would be
  # green on a conductor that never reads anything.
  cp "$1/bin/lib/gh-pr-list.sh" "$1/bin/lib/merge-conductor-lib.sh" "$1/bin/lib/gh-rest.sh" "$1/bin/lib/gh-rest-var.sh" "$2/h/bin/lib/" || return 1
  # BH-945: the main-red freeze moved out of bin/merge-conductor.sh into this lib,
  # which merge-conductor-lib.sh sources.
  cp "$1/bin/lib/main-red-gate.sh" "$1/bin/lib/gh-budget.sh" "$2/h/bin/lib/" || return 1
  mkdir -p "$2/h/bin/lib/mc" || return 1
  cp "$1"/bin/lib/mc/*.sh "$2/h/bin/lib/mc/" || return 1
  # BH-2504: every conductor push (mc_rebase, mc_restack, mrt_rebase_pure) goes
  # through bin/lib/hold-push.sh, which reads the ticket through hold.sh.
  # BH-5234: mc_restack and hold_push's rewrite guard read bin/lib/stale-parent.sh.
  cp "$1/bin/lib/hold-push.sh" "$1/bin/lib/hold.sh" "$1/bin/lib/stale-parent.sh" "$2/h/bin/lib/" || return 1
  fx_restpr "$1" "$2" || return 1
}

fx_conductor_tick() { # fx_conductor_tick <repo-dir> <T> — what the suites that drive the WHOLE tick add
  cp "$1/bin/merge-conductor.sh" "$1/bin/fleet-conf.sh" "$1/bin/jobs-client.sh" "$2/h/bin/" || return 1
  # BH-1526: the tick sources the ownership lib (and it hold.sh), so a whole-tick
  # suite runs the one-PR-per-ticket check and the merge hold as a box does.
  cp "$1/bin/lib/ticket-ownership.sh" "$1/bin/lib/hold.sh" "$2/h/bin/lib/" || return 1
  mkdir -p "$2/h/bin/lib/jobs" || return 1
  cp "$1"/bin/lib/jobs/*.sh "$2/h/bin/lib/jobs/" || return 1
}

# fx_br_harness <repo-dir> <T> — the blocked-resolver family's fixture: the
# monolith tests/blocked-resolver-test.sh carried this as its lines 24-123, and
# every line below is that text, minus the `cp` of the seven scripts the lane
# drives (which stays in each suite, so bin/test-impact.sh still selects them).
# The suite copies those scripts into $T/h/bin FIRST; the chmod below covers them.
fx_br_harness() {
DIR="$1"; T="$2"; H="$2/h"
fx_tree "$T" || return 1
mkdir -p "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/repos" || return 1
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
br_modules_install "$DIR" "$H" || return 1
# gh-rest.sh rides along with the conductor lib (BH-784): bin/merge-sweep.sh's
# decision reads go through it, and without the file the sweep's own fail-closed
# shims answer "unverifiable" to every one of them.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/git-identity.sh" "$H/bin/lib/" || return 1
# BH-1134: the fix round commits under, and refuses to push anything but, the
# GLOBAL git identity. The scratch global is the t@t every pre-made checkpoint
# commit in these suites already carries, so they assert what they always did —
# and the lane never reads the real box's ~/.gitconfig.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL" || return 1
# The shared REST answer emitter (tests/lib/rest-emit.sh documents the shapes):
# gh-rest.sh judges the HTTP STATUS LINE, so a stub arm prints a whole response.
fx_restpr "$DIR" "$T" || return 1
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || return 1
chmod +x "$H/bin/"*.sh || return 1
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# lane-alert is RECORDED, never stubbed silent: "the lane went quiet instead of
# paging" is exactly the failure section 6b is about.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# Every gh call is recorded so "did anything close a PR / comment / merge" is a
# fact about the run rather than a reading of the source.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  # br_pr_ref reads the PR over REST (see tests/resolver-pr-read-failed-test.sh),
  # so the same head+branch answer is keyed on the REST path too.
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-9" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-9" ;;
  *"--json headRefName"*)  echo "ticket/TK-9" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"--json comments"*)     echo "Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated." ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *"pr diff"*)             cat "$T/prdiff" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"
echo OPEN > "$T/prstate"
# The PR the REST reads answer with (#783): one object now carries the branch,
# the title and the head this fixture used to answer field by field. Sections
# that want a different PR overwrite these files, exactly as they overwrite
# $T/prstate.
printf 'ticket/TK-9' > "$T/prbranch"
printf 'TK-9: a thing' > "$T/prtitle"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
: > "$T/comment-bodies.txt"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# ssh is RECORDED and never real: a test that reaches a box is a test that has
# already failed.
cat > "$T/fakebin/br-ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ssh.txt"
exit 0
EOF
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN. mc_git_auth answers from GH_TOKEN first
# and `gh auth token` second; with both empty every git path refuses before it
# can touch a network, which is the only acceptable shape for a fixture that
# drives a lane whose job is pushing to real repos.
export GH_TOKEN=""

# BRENV carries per-section environment (the ladder caps, BR_LADDER) into the
# run the way the operator would set it in env/global.env.
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$(date -u +%s)" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
# ROWST <key> <STATE> <reason> <url> — the same row in a state that is not
# BLOCKED_HUMAN. RED_TWICE (2026-09-15) is the first of those: the conductor
# parks a head whose CI is still red after its one rerun there, and this lane
# owns it on exactly the same terms.
ROWST() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$(date -u +%s)" abc123 abc123 "$3" "$4" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
# SPENT is the monolith's line 685: two rungs already spent, so a park under
# test arrives at rung 3 with the history that put it there stated outright. It
# lives here because two of the new suites call it (6b's key derivation and the
# rebuild-outcome sections), and it was defined in only one of them.
SPENT() { # SPENT <cap-key> — mechanical and fix round both already ran and failed
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg k "$1" '{project:"tproj",rkey:$k,mechanicals:1,fixrounds:1,rebuilds:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/$1.json"
}
}

# fx_br_ladder_git <repo-dir> <T> — the section-8 fixture: a REAL local git (a
# bare "remote", branches that genuinely conflict with main), the mc_rebase rc
# contract stubbed onto the conductor lib copy, and the section's own gh and
# agent-call stubs. The monolith carried it as its lines 846-988, inside section
# 8; tests/br-rungs-test.sh and tests/br-contested-test.sh both drive the ladder
# on it, so it is here rather than in either of them. Call it AFTER
# fx_br_harness, where section 8's header used to sit.
#
# CARRIED SETUP (BH-1196): the jobs client below is the monolith's lines 748-752,
# the last install before section 8 and byte-identical to the one at 692. The
# ladder's rebuild rung enqueues through it, so section 8 inherited it from the
# sections above rather than writing its own — and a suite that starts at
# section 8 has to be handed it, or the rebuild rung enqueues into nothing.
fx_br_ladder_git() {
DIR="$1"; T="$2"; H="$2/h"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
scratch_rm "$H/state/blocked-resolver"
rm -f "$H/state/build-queue/tproj"/*.failed.json "$H/state/build-queue/tproj"/*.json
: > "$H/state/merge-conductor/pr-state.tsv"
touch "$H/flags/fly-pool-tproj"
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
# --- fixture override: mc_rebase to its documented rc contract ---------------
# 0 pushed (stdout: the new head) | 1 conflict (stdout: the paths) | 2 gate red
# | 3 lease rejected | 4 setup failed.
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  local out; out=\$(cat "$T/rebase-out" 2>/dev/null)
  [ -n "\$out" ] && printf '%s' "\$out"
  return "\$(cat "$T/rebase-rc" 2>/dev/null || echo 4)"
}
EOF

ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"; printf 'shared\n' > "$SEED/b.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
mkbranch() { # mkbranch <branch> conflict|clean — always off the base commit
  git -C "$SEED" checkout -q main
  git -C "$SEED" reset -q --hard "$(git -C "$SEED" rev-list --max-parents=0 HEAD)"
  git -C "$SEED" checkout -q -b "$1"
  if [ "$2" = conflict ]; then printf 'the branch changed this line\n' >> "$SEED/a.txt"
  else printf '%s\n' "$1" > "$SEED/f.txt"; fi
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q origin "$1"
}
mkbranch ticket/TK-88 conflict
mkbranch ticket/TK-89 conflict
mkbranch ticket/TK-90 clean
mkbranch ticket/TK-91 clean
# 8f drives the setup-failure edges and must not share a ticket with 8e: 8e
# leaves a brfix/tproj-TK-91 checkpoint behind and pushes its fix to
# ticket/TK-91, so a later round on that ticket reuses a tree whose conflict is
# already resolved and legitimately commits nothing.
mkbranch ticket/TK-94 conflict
# Sections 9 and 10 (the contested hold and the two ladder shapes) need their
# own tickets, and they need REAL conflicts too — so their branches are cut here
# with every other one, before main moves.
mkbranch ticket/TK-95 conflict
# 9i's winner: one ticket whose conflict recurs on TWO paths at once.
mkbranch ticket/TK-70 conflict
mkbranch ticket/TK-98 conflict
mkbranch ticket/TK-101 conflict
mkbranch ticket/TK-102 conflict
# main moves AFTER the branches, on the same line: every conflict below is a
# real one git computes, not a fixture that says the word.
git -C "$SEED" checkout -q main
printf 'main changed this line\n' >> "$SEED/a.txt"
git -C "$SEED" commit -qam "main work"; git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
osha() { git -C "$ORIGIN" rev-parse "$1"; }

# The gh stub for this section: the PR under test is named by two files, so a
# scenario is one write rather than one stub.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # mc_pr_files PAGES THE FILE LIST THROUGH gh_rest SINCE BH-784, so its read is
  # a "gh api -i -X GET .../pulls/<n>/files?per_page=..." call. It sits ABOVE the
  # shared -i -X arm ON PURPOSE: that arm delegates to tests/lib/gh-rest-stub.sh,
  # which knows nothing about /files and would answer nothing — every hold below
  # would then name no competitor and §9i would be green on an empty read.
  # The body is the files ARRAY; the jq that names the filenames is
  # mc_pr_files's own, not a gh -q template.
  # ONE FILE LIST PER PR, not one for the whole fixture (§9i): the competitor
  # set is per PATH, so the suite has to be able to say "#96 touches a.txt and
  # #97 touches b.txt". $T/prfiles is still the answer for a PR with no file of
  # its own.
  *"-i -X GET"*"/pulls/"*"/files"*)
    _p="\$*"; _n="\${_p##*/pulls/}"; _n="\${_n%%/*}"
    _f="$T/prfiles-\$_n"; [ -f "\$_f" ] || _f="$T/prfiles"
    restpr --raw 200 "\$(jq -R -s -c 'split("\n")|map(select(length>0))|map({filename:.})' < "\$_f" 2>/dev/null)" ;;
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*)
    # The posted findings are an ISSUE-COMMENTS read now (#783), so this
    # section's one-body fixture is handed to the shared stub as that thread.
    GHT="$T"; cp "$T/findings" "$T/prcomments" 2>/dev/null || : > "$T/prcomments"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  # The per-PR file list mc_pr_files buys for each candidate it keeps does NOT
  # go through gh_rest, so it is not caught by the arm above. The open-PR list
  # harness_pr_list pages (section 9's competitor scan) DOES, since BH-782 —
  # the arm above answers it from this same \$T/openprs fixture, and this arm
  # is what a non-gh_rest reader of the list would still get.
  *"/pulls?state=open"*) cat "$T/openprs" 2>/dev/null ;;
  # mc_pr_files reads the file list over REST; the GraphQL arm below it is the
  # fallback that only fires when REST answers nothing.
  # ONE FILE LIST PER PR, not one for the whole fixture (§9i): the competitor
  # set is per PATH, so the suite has to be able to say "#96 touches a.txt and
  # #97 touches b.txt". $T/prfiles is still the answer for a PR with no file of
  # its own.
  *"/files"*)
    _p="\$*"; _n="\${_p##*/pulls/}"; _n="\${_n%%/*}"
    if [ -f "$T/prfiles-\$_n" ]; then cat "$T/prfiles-\$_n"; else cat "$T/prfiles" 2>/dev/null; fi ;;
  *"--json files"*) cat "$T/prfiles" 2>/dev/null ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  # br_pr_ref's REST read. gh api --jq renders an ABSENT field as the string
  # "null"; it never emits the blank positional field the old paired GraphQL
  # read could, so a missing head reads as "null" here rather than as a gap the
  # branch then slides into. (No backticks in this heredoc — it is unquoted, so
  # a backtick would run the command at stub-WRITE time.)
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json state"*)       echo OPEN ;;
  *"--json comments"*)    cat "$T/findings" 2>/dev/null ;;
  *"actions/runs?head_sha="*) cat "$T/failedruns" 2>/dev/null ;;
  *"run view"*"--log-failed"*) cat "$T/joblog" 2>/dev/null ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/failedruns"; : > "$T/joblog"
printf '[]\n' > "$T/openprs"; printf 'a.txt\n' > "$T/prfiles"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
# The "agent": it runs with the worktree as its cwd, exactly as bin/agent-call.sh
# is invoked, and records the prompt it was given.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
if [ -f "$T/agent-resolves" ]; then
  printf 'both sides, resolved\n' > a.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: resolved the merge and answered the findings" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
}
