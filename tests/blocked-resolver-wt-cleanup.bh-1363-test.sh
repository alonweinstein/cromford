#!/bin/bash
# tests/blocked-resolver-wt-cleanup.bh-1363-test.sh — the fix round's scratch
# worktree goes on EVERY exit path, and a removal that failed says so (BH-1363).
#
# WHY IT EXISTS. On 2026-09-22 the hub sat at 92% disk with 14 GB in
# /root/harness/tmp/brfix/: eleven fix-round worktrees dated 09-17..09-20, still
# registered in cromford, project-5 and project-2, with no process
# holding them and the resolver idle. bin/blocked-resolver.sh removes its
# worktree on every PLANNED exit, but:
#   * removal happened only at the eleven inline call sites — the per-key
#     subshell's EXIT trap freed the ledger row and nothing else — so a round
#     that ended anywhere else (a box reboot, update-runners, an operator kill)
#     dropped a 1.8-2.7 GB checkout;
#   * every removal discards the rc of `git worktree remove --force`, which
#     genuinely fails on a locked worktree (rc 128, directory still there), so a
#     removal that failed reads exactly like one that worked;
#   * nothing else sweeps them — a brfix checkpoint is local-only by
#     construction, so bin/disk-clean.sh stage 3 keeps it for ever.
#
# What is proved here, all of it against the REAL lane (bin/blocked-resolver.sh
# driven the way cron drives it) over a REAL git repo with a REAL bare remote:
#   §1  a round killed mid-agent with SIGTERM to its whole session (what a
#       reboot does) leaves no directory under $H/tmp/brfix and no brfix entry
#       in `git worktree list`, and brfix/<ck> — the checkpoint the next round
#       reuses — SURVIVES;
#   §1b a SIGTERM to the lane's process group alone, which leaves the agent
#       running in the group `timeout` gave it, does NOT delete the worktree
#       under that agent: the round waits for it and cleans up after;
#   §2  a removal that the ordinary --force refuses (the worktree is locked) is
#       escalated until the directory is gone, and logged once;
#   §3  the refusal path (agent rc≠0, no commit) leaves nothing behind and its
#       terminal wording is unchanged;
#   §4  a removal that fails everything says "could NOT remove" and names the
#       path, and the round's own verdict is still recorded — a cleanup failure
#       never rewrites the outcome;
#   §5  the SUCCESS path (the round pushes) also leaves nothing behind.
# Run from anywhere: tests/blocked-resolver-wt-cleanup.bh-1363-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"; export HARNESS="$H"
ST="$H/state/blocked-resolver"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$ST" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/git-identity.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# ---------------------------------------------------------------------------
# A REAL repo and a REAL bare remote: "is the worktree gone" is then a fact on
# disk in a repo git itself administers, never a stub's opinion.
# ---------------------------------------------------------------------------
export GIT_AUTHOR_NAME=harness GIT_AUTHOR_EMAIL=harness@test
export GIT_COMMITTER_NAME=harness GIT_COMMITTER_EMAIL=harness@test
# BH-1134: the fix round pins, and pushes only, the GLOBAL git identity
# (bin/lib/git-identity.sh). The scratch global is the same harness@test.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = harness\n\temail = harness@test\n' > "$GIT_CONFIG_GLOBAL"
ORIGIN="$T/origin.git"
git init -q --bare -b main "$ORIGIN"
CLONE="$T/repos/tproj"
git init -q -b main "$CLONE"
echo base > "$CLONE/base.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm base
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" push -q origin main
git -C "$CLONE" checkout -q -b ticket/TK-9
echo branch > "$CLONE/branch.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm "the ticket's own change"
git -C "$CLONE" push -q origin ticket/TK-9
git -C "$CLONE" checkout -q main
git -C "$CLONE" fetch -q origin
PRHEAD=$(git -C "$CLONE" rev-parse origin/ticket/TK-9)

# The fake gh: the same recorded envelope stub the other resolver suites use.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/TK-9' > "$T/prbranch"
    printf 'TK-9: a thing' > "$T/prtitle"
    printf '%s' "$PRHEAD" > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/issue-comments.json" ;;
  *"repos/"*"/issues/"*)   cat "$T/issue.json" ;;
  *"pr comment"*)  printf '%s\n' "\$*" >> "$T/pr-comment.txt"; exit 0 ;;
  *"pr close"*)    printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)     echo "$PRHEAD ticket/TK-9" ;;
  *"--json headRefName"*) echo "ticket/TK-9" ;;
  *"--json comments"*) echo "Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated." ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '%s\n' '{"number":9,"state":"open","labels":[{"name":"ai-build"}],"title":"TK-9: a thing","body":"## Scope"}' > "$T/issue.json"
printf '[]\n' > "$T/issue-comments.json"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/prcomments"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"

# THE TWO BREAKERS (§4 only, and only while BRFIX_BREAK=1 is in the env). A
# removal that fails EVERYTHING is not reachable as root with permission bits —
# root ignores them — so the failure is injected where the code meets the
# system: `git worktree remove` refuses, and `rm` refuses, for paths under
# tmp/brfix. Every other section runs the real git and the real rm.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
if [ "\${BRFIX_BREAK:-0}" = 1 ]; then
  case " \$* " in
    *" worktree remove "*) case " \$* " in *"$H/tmp/brfix/"*) exit 128 ;; esac ;;
  esac
fi
exec /usr/bin/git "\$@"
EOF
cat > "$T/fakebin/rm" <<EOF
#!/bin/bash
if [ "\${BRFIX_BREAK:-0}" = 1 ]; then
  case " \$* " in *"$H/tmp/brfix/"*) exit 1 ;; esac
fi
exec /usr/bin/rm "\$@"
EOF
chmod +x "$T/fakebin/git" "$T/fakebin/rm"
[ -x /usr/bin/git ] && [ -x /usr/bin/rm ] || { echo "git/rm not where the shims expect them — skipping"; exit 0; }
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# The stub agent. BRFIX_AGENT says which shape of round this is; every shape is
# one the real lane has (a commit, a refusal, a locked tree, a kill mid-flight).
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2" >> "$T/agent-calls.txt"
case "\${BRFIX_AGENT:-commit}" in
  sleep)
    printf '%s\n' "\$PWD" > "$T/agent-started"
    sleep 120                      # determinism: ok the kill under test arrives while this runs
    exit 0 ;;
  sleep-short)
    printf '%s\n' "\$PWD" > "$T/agent-started"
    sleep 8                        # determinism: ok §1b kills the group and watches the round wait this out
    echo "the fix the agent made" >> agent-fix.txt
    git add -A >/dev/null 2>&1
    git commit -qm "fix round: the agent's commit" >/dev/null 2>&1
    exit 0 ;;
  lock)
    printf '%s\n' "\$PWD" > "$T/agent-started"
    /usr/bin/git -C "$CLONE" worktree lock "\$PWD" >/dev/null 2>&1
    exit 1 ;;
  fail)
    printf '%s\n' "\$PWD" > "$T/agent-started"
    exit 1 ;;
esac
printf '%s\n' "\$PWD" > "$T/agent-started"
echo "the fix the agent made" >> agent-fix.txt
git add -A >/dev/null 2>&1
git commit -qm "fix round: the agent's commit" >/dev/null 2>&1
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

LOG="$H/logs/blocked-resolver.log"
CK=tproj-TK-9
URL=https://github.com/o/tproj/pull/9
REC="$H/builds/tproj-TK-9-20260917000001"
mkdir -p "$REC"
printf 'PR_CREATED %s\n' "$URL" > "$REC/RESULT"
printf '{"labels":[]}\n' > "$REC/ticket-meta.json"
printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' \
  "o/tproj#9" "$NOW" "head-not-reapproved" "$URL" > "$H/state/merge-conductor/pr-state.tsv"

reset() {
  : > "$LOG"; : > "$T/agent-calls.txt"; : > "$T/pr-comment.txt"
  rm -f "$T/agent-started" "$T/tick.log"
  scratch_rm "$ST/tproj"; scratch_rm "$ST/rounds"
  chmod -R u+w "$H/tmp" 2>/dev/null
  for w in $(/usr/bin/git -C "$CLONE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'); do
    [ "$w" = "$CLONE" ] && continue
    /usr/bin/git -C "$CLONE" worktree remove --force --force "$w" >/dev/null 2>&1
    scratch_rm "$w"
  done
  /usr/bin/git -C "$CLONE" worktree prune >/dev/null 2>&1
  /usr/bin/git -C "$CLONE" branch -D "brfix/$CK" >/dev/null 2>&1
  scratch_rm "$H/tmp"
  /usr/bin/git -C "$CLONE" push -q -f origin "$PRHEAD:refs/heads/ticket/TK-9" 2>/dev/null
  /usr/bin/git -C "$CLONE" fetch -q origin
}

# The production entry point, driven the way cron drives it.
TICK() { # TICK <env-assignments...>
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
      BR_SSH="$T/fakebin/br-ssh" env "$@" bash "$H/bin/blocked-resolver.sh" \
      >>"$T/tick.log" 2>&1 ) || true
}
brfix_dirs() { find "$H/tmp/brfix" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; }
brfix_wts()  { /usr/bin/git -C "$CLONE" worktree list --porcelain 2>/dev/null | awk '/^worktree .*brfix-/{print $2}'; }
removal_lines() { awk '/removed the fix-round worktree/ { n++ } END { print n + 0 }' "$LOG" 2>/dev/null; }

# ============================================================================
# §1. A KILLED ROUND LEAVES NOTHING. SIGTERM to the lane's process group while
#     the agent is working — exactly what a reboot, an update-runners restart
#     or an operator kill does — and the worktree must still go.
# ============================================================================
reset
cat > "$T/lane.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$\$" > "$T/pgid"
exec bash "$H/bin/blocked-resolver.sh"
EOF
chmod +x "$T/lane.sh"
rm -f "$T/pgid"
( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
    BRFIX_AGENT=sleep BR_MAX_FIXROUNDS=2 setsid bash "$T/lane.sh" >"$T/tick.log" 2>&1 ) &
i=0
while [ ! -s "$T/agent-started" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded poll for the agent stub's own stamp
[ -s "$T/agent-started" ] && ok || bad "§1 the fix round never reached the agent in 60s: $(cat "$T/tick.log" "$LOG" 2>/dev/null)"
KILLED_WT=$(cat "$T/agent-started" 2>/dev/null)
[ -d "$KILLED_WT" ] && ok || bad "§1 the round's worktree is not on disk while the agent runs: $KILLED_WT"
# SIGTERM TO THE WHOLE SESSION, which is what a reboot does. Not the process
# GROUP alone: `timeout` puts the agent it runs into a process group of its own
# (that is how it kills a whole tree on expiry), so a group-only kill leaves the
# agent running and the round's shell blocked in `wait` until the agent ends of
# its own accord — cleanup then still happens, just whenever that is. setsid
# above gives the lane its own session, so the session id is the pgid on file.
SID=$(cat "$T/pgid" 2>/dev/null)
if [ -n "$SID" ] && pkill -TERM -s "$SID" 2>/dev/null; then ok; else bad "§1 could not signal the lane's session ($SID)"; fi
i=0
while pgrep -s "$SID" >/dev/null 2>&1 && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded wait for the signalled session to go
wait 2>/dev/null
pgrep -s "$SID" >/dev/null 2>&1 \
  && bad "§1 the lane's session is still alive 60s after SIGTERM: $(ps -eo pid,sid,stat,args | awk -v s="$SID" '$2==s')" || ok
[ -z "$(brfix_dirs)" ] \
  && ok || bad "§1 a killed round left its worktree on disk: $(brfix_dirs)"
[ -z "$(brfix_wts)" ] \
  && ok || bad "§1 a killed round left a registered worktree: $(brfix_wts)"
/usr/bin/git -C "$CLONE" rev-parse --verify -q "brfix/$CK" >/dev/null \
  && ok || bad "§1 the checkpoint branch brfix/$CK was collateral — the next round has to buy those tokens again"
[ "$(removal_lines)" -ge 1 ] \
  && ok || bad "§1 nothing in logs/blocked-resolver.log says the worktree was removed: $(cat "$LOG")"

# ============================================================================
# §1b. THE SIGNAL TRAP'S OWN JOB: WAIT FOR THE AGENT, THEN CLEAN. `timeout` runs
#      the agent in a process group of its own, so a kill aimed at the LANE's
#      group (an operator `kill -- -PGID`, a supervisor stopping the lane) hits
#      the round's shell while its agent is still writing. With the TERM trap
#      the round finishes waiting on that agent and cleans up after it; without
#      one, bash dies at once and its EXIT trap deletes the worktree out from
#      under a live agent — the one thing worse than leaking it.
# ============================================================================
reset
rm -f "$T/pgid"
( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
    BRFIX_AGENT=sleep-short BR_MAX_FIXROUNDS=2 setsid bash "$T/lane.sh" >"$T/tick.log" 2>&1 ) &
i=0
while [ ! -s "$T/agent-started" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded poll for the agent stub's own stamp
[ -s "$T/agent-started" ] && ok || bad "§1b the fix round never reached the agent in 60s: $(cat "$T/tick.log" "$LOG" 2>/dev/null)"
LIVE_WT=$(cat "$T/agent-started" 2>/dev/null)
PGID=$(cat "$T/pgid" 2>/dev/null)
kill -TERM "-$PGID" 2>/dev/null && ok || bad "§1b could not signal the lane's process group ($PGID)"
sleep 2                            # determinism: ok the agent stub sleeps 8s; this samples while it is still working
[ -d "$LIVE_WT" ] \
  && ok || bad "§1b the worktree was deleted under a still-running agent: $LIVE_WT"
i=0
while pgrep -s "$PGID" >/dev/null 2>&1 && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded wait for the round to finish waiting on its agent
wait 2>/dev/null
[ -z "$(brfix_dirs)" ] \
  && ok || bad "§1b the signalled round never cleaned up after its agent: $(brfix_dirs)"
[ -z "$(brfix_wts)" ] \
  && ok || bad "§1b the signalled round left a registered worktree: $(brfix_wts)"
[ "$(removal_lines)" -ge 1 ] \
  && ok || bad "§1b nothing says the worktree was removed: $(cat "$LOG")"
/usr/bin/git -C "$CLONE" rev-parse --verify -q "brfix/$CK" >/dev/null \
  && ok || bad "§1b the checkpoint branch was collateral — the agent's commit is gone"

# ============================================================================
# §2. A REMOVAL THE ORDINARY --force REFUSES. The agent locks its own worktree
#     and fails; `git worktree remove --force` answers rc 128 and leaves the
#     directory. The round must escalate until it is really gone.
# ============================================================================
reset
TICK BRFIX_AGENT=lock BR_MAX_FIXROUNDS=2
[ "$(wc -l < "$T/agent-calls.txt")" = 1 ] \
  && ok || bad "§2 the round did not run its agent: $(cat "$LOG")"
[ -z "$(brfix_dirs)" ] \
  && ok || bad "§2 a locked worktree survived the round: $(brfix_dirs)"
[ -z "$(brfix_wts)" ] \
  && ok || bad "§2 a locked worktree is still registered: $(brfix_wts)"
/usr/bin/git -C "$CLONE" rev-parse --verify -q "brfix/$CK" >/dev/null \
  && ok || bad "§2 brfix/$CK must survive a round that has another round owed"
[ "$(removal_lines)" = 1 ] \
  && ok || bad "§2 want exactly one removal line, got $(removal_lines): $(cat "$LOG")"
grep -q "removed the fix-round worktree $H/tmp/brfix/" "$LOG" \
  && ok || bad "§2 the removal line does not name the path: $(grep 'fix-round worktree' "$LOG")"

# ============================================================================
# §3. THE ORDINARY REFUSAL. Agent rc≠0, no commit, no rounds left: the terminal
#     wording is unchanged and nothing is left behind.
# ============================================================================
reset
TICK BRFIX_AGENT=fail BR_MAX_FIXROUNDS=1
[ -z "$(brfix_dirs)" ] \
  && ok || bad "§3 a refused round left its worktree on disk: $(brfix_dirs)"
[ -z "$(brfix_wts)" ] \
  && ok || bad "§3 a refused round left a registered worktree: $(brfix_wts)"
grep -q 'did not produce a verified commit' "$LOG" \
  && ok || bad "§3 the terminal wording changed: $(cat "$LOG")"
[ "$(jq -r '.fixrounds' "$ST/tproj/$CK.json" 2>/dev/null)" = 1 ] \
  && ok || bad "§3 fixrounds must still be counted: $(cat "$ST/tproj/$CK.json" 2>/dev/null)"
[ "$(removal_lines)" = 1 ] \
  && ok || bad "§3 want exactly one removal line, got $(removal_lines): $(cat "$LOG")"

# ============================================================================
# §4. A REMOVAL THAT FAILS EVERYTHING IS TOLD, and changes no verdict.
# ============================================================================
reset
TICK BRFIX_AGENT=fail BR_MAX_FIXROUNDS=1 BRFIX_BREAK=1
grep -q 'could NOT remove the fix-round worktree' "$LOG" \
  && ok || bad "§4 a removal that failed was reported as nothing at all: $(cat "$LOG")"
grep -q "could NOT remove the fix-round worktree $H/tmp/brfix/" "$LOG" \
  && ok || bad "§4 the could-not-remove line does not name the path: $(grep 'fix-round worktree' "$LOG")"
[ "$(removal_lines)" = 0 ] \
  && ok || bad "§4 a failed removal claimed success too: $(grep 'fix-round worktree' "$LOG")"
grep -q 'did not produce a verified commit' "$LOG" \
  && ok || bad "§4 a cleanup failure rewrote the round's own verdict: $(cat "$LOG")"
[ "$(jq -r '.fixrounds' "$ST/tproj/$CK.json" 2>/dev/null)" = 1 ] \
  && ok || bad "§4 the round's counter was lost to a cleanup failure: $(cat "$ST/tproj/$CK.json" 2>/dev/null)"
[ -n "$(brfix_dirs)" ] \
  && ok || bad "§4 the fixture did not actually break the removal — the case proves nothing"
chmod -R u+w "$H/tmp" 2>/dev/null

# ============================================================================
# §5. THE SUCCESS PATH. The round pushes and still leaves nothing behind.
# ============================================================================
reset
TICK BRFIX_AGENT=commit BR_MAX_FIXROUNDS=1
/usr/bin/git -C "$CLONE" fetch -q origin
[ "$(/usr/bin/git -C "$CLONE" rev-parse origin/ticket/TK-9)" != "$PRHEAD" ] \
  && ok || bad "§5 the round did not push, so this is not the success path: $(cat "$LOG")"
[ -z "$(brfix_dirs)" ] \
  && ok || bad "§5 a round that pushed left its worktree on disk: $(brfix_dirs)"
[ -z "$(brfix_wts)" ] \
  && ok || bad "§5 a round that pushed left a registered worktree: $(brfix_wts)"
[ "$(removal_lines)" = 1 ] \
  && ok || bad "§5 want exactly one removal line, got $(removal_lines): $(cat "$LOG")"
reset

echo "blocked-resolver-wt-cleanup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
