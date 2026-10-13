#!/bin/bash
# tests/iron-law-fs-test.sh — family 6 of the act-time iron-law guard, driven for real.
#
# Family 6 is "a destructive filesystem verb pointed at the harness's own state".
# Every case below feeds bin/iron-law-guard.sh a real PreToolUse payload on stdin
# — the production entry point, exactly the way bin/agent-call.sh wires it — and
# reads the verdict back off disk: the exit code, the stderr the model is shown,
# the findings.log line and the ALERTS.log line. The only two source greps are
# the ticket's own documentation pins in §4, and they are marked as such.
#
# What must stay true:
#   1. rm, find -delete, git clean, git worktree remove, rsync --delete,
#      truncate, shred and a pure `>` truncation pointed under a protected root
#      are DENIED with rc 2, a finding, and exactly one ALERTS line
#   2. an unset/empty variable inside a target is its own refusal — an empty
#      expansion is how `rm -rf "$X/env"` becomes `rm -rf /env`
#   3. the work a lane is supposed to do (its own worktree, its own build dir,
#      /tmp, appends, ordinary writes, the verb quoted inside an argument) is
#      untouched, and an unresolvable target is allowed, never guessed
#   4. family 6 fires on EVERY session carrying a HARNESS_LANE marker, including
#      orchestrator/chat/greenfield; no marker at all is completely inert
#   5. families 1-5 keep their old fence (guarded lanes only) and stay
#      findings-only — no ALERTS line
#   6. no case anywhere trips the set -u crash audit
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/env" "$T/builds/testproj-TK-7-x" "$T/wt" "$T/tmp"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# GUARD_OVERRIDE is how this suite is shown red against origin/main's guard.
GUARD="${GUARD_OVERRIDE:-$DIR/bin/iron-law-guard.sh}"

payload() { # payload <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$T}" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'
}
# The guarded execute lane, with this box's layout pointed at $T and the lane's
# own worktree/build dir in the environment the way run-build.sh puts them there.
# X and Y are explicitly UNSET: §2's cases are about a variable the guard cannot
# see, and one inherited from whatever shell runs this suite would test nothing.
guard() { # guard <command> [cwd]
  payload "$1" "${2:-$T}" | timeout 30 env -u X -u Y HARNESS="$T" HARNESS_LANE=execute \
    HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=TK-7 \
    BUILD_DIR="$T/builds/testproj-TK-7-x" WT="$T/wt" \
    bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
# Same, with an arbitrary lane marker. An EMPTY first argument means no marker at
# all: `env -u`, not merely an unset assignment, because this suite may itself be
# running inside a marked lane and an inherited HARNESS_LANE would quietly make
# the no-marker case assert nothing.
lane() { # lane <lane-or-empty> <command> [cwd]
  local l="$1" c="$2" d="${3:-$T}"
  payload "$c" "$d" | timeout 30 env -u X -u Y -u HARNESS_LANE HARNESS="$T" ${l:+HARNESS_LANE=$l} \
    HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=TK-7 \
    BUILD_DIR="$T/builds/testproj-TK-7-x" WT="$T/wt" \
    bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
alerts() { [ -f "$T/logs/ALERTS.log" ] && wc -l < "$T/logs/ALERTS.log" || echo 0; }

# --- 1. a destructive verb under a protected root is refused ----------------
# Every shape here is one a session can reach today: the plain verb, one per
# protected root, the verb behind the fleet's rtk rewrite, behind `bash -c`,
# behind sudo, behind `\rm`, behind a `cd X &&`, and with a `..` that walks back
# into state. Also the ANCESTORS of the protected roots — `rm -rf /root/harness`
# and `rm -rf /root/harness/*` are the literal footprint of the #388 wipe, and a
# guard that refuses `/root/harness/env` while allowing the directory above it
# refuses nothing that matters.
# @T@ is this run's scratch HARNESS; @@CWD= sets the payload cwd.
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  CWD="$T"
  case "$CMD" in
    *"@@CWD="*) CWD="${CMD##*@@CWD=}"; CMD="${CMD%%@@CWD=*}" ;;
  esac
  CMD="${CMD//@T@/$T}"; CWD="${CWD//@T@/$T}"
  : > "$T/logs/findings.log"; A0=$(alerts)
  RC=$(guard "$CMD" "$CWD")
  if [ "$RC" != 2 ]; then bad "NOT DENIED (rc=$RC): $CMD"; continue; fi
  ok
  grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
    || bad "denied but gave the model no reason: $CMD"
  grep -q "family=actguard-fs-destroy" "$T/logs/findings.log" 2>/dev/null \
    || bad "denied but filed no fs-destroy finding: $CMD"
  A1=$(alerts)
  [ "$A1" = "$((A0+1))" ] \
    || bad "refusal did not add exactly one ALERTS line (${A0}->${A1}): $CMD"
  tail -1 "$T/logs/ALERTS.log" 2>/dev/null | grep -q "REFUSED a destructive filesystem verb" \
    || bad "the ALERTS line does not name the refusal: $CMD"
  tail -1 "$T/logs/ALERTS.log" 2>/dev/null \
    | grep -q "Tripwire only — the wall is the chattr ticket (#388)." \
    || bad "the ALERTS line does not say this is a tripwire, not the wall: $CMD"
done <<'CASES'
rm -rf /root/harness/env
rm -rf "$HARNESS/state"
rm -rf /root/harness/logs
rm -rf /root/harness/builds
rm -rf /root/harness/flags
rm -rf /root/harness/locks
rm -rf /root/orchestrator
rm -rf /root/repos
rm -rf /root/harness-checkout
rm -rf /etc/harness
rm -rf /root/.ssh
rm /root/harness/env/global.env
rm -- /root/harness/env/global.env
find /root/harness/logs -delete
find /root/harness/state -type f -delete
git -C /root/harness-checkout clean -fdx
git clean -fdx@@CWD=/root/harness/state
git -C /root/harness clean -fdx
cd /root/harness && git clean -fdx
git -C /root/harness-checkout clean -fd bin@@CWD=@T@/wt
git worktree remove /root/repos/x/wt
git worktree remove -f /root/harness-checkout
rsync -a --delete s/ /root/harness/state/
rsync -a --delete-after s/ /root/harness/state/
truncate -s0 /root/harness/logs/cost.csv
truncate -s 0 /root/harness/logs/cost.csv
shred -u /root/.ssh/id_ed25519
: > /root/harness/logs/ALERTS.log
true > @T@/logs/x
> /root/harness/env/x
>/root/harness/env/x
:>/root/harness/env/x
1>/root/harness/env/x
cat /dev/null > /root/harness/state/y
rm -rf /root/harness/logs/../env
rm -rf /root/harness
rm -rf /root/harness/
rm -rf /root/harness/*
rm -rf /root
rm -rf /
rm -rf /etc
rm -rf @T@
rm -rf .@@CWD=/root/harness
rm -rf @T@/state
cd /root/harness && rm -rf logs
find . -delete@@CWD=/root/harness/builds/other
rtk rm -rf /root/harness/env
\rm -rf /root/harness/env
bash -c 'rm -rf /root/harness/env'
cd /root/harness && bash -c 'rm -rf logs'
sudo rm -rf /etc/harness
CASES

# --- 2. an empty expansion is its own refusal -------------------------------
# `rm -rf "$X/env"` with X unset is `rm -rf /env`. The guard is a separate
# process and cannot see a variable the agent set inside its own shell, so unset
# reads as empty and the refusal says so — while a variable assigned in the same
# command, or defaulted, is unresolvable and therefore allowed.
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  : > "$T/logs/findings.log"
  RC=$(guard "$CMD")
  [ "$RC" = 2 ] || { bad "an empty expansion was allowed (rc=$RC): $CMD"; continue; }
  ok
  grep -q "family=actguard-fs-empty-expansion" "$T/logs/findings.log" 2>/dev/null \
    || bad "empty expansion filed the wrong family: $CMD :: $(head -1 "$T/logs/findings.log")"
done <<'EMPTY'
rm -rf "$X/env"
rm -rf $X/
find "$Y" -delete
truncate -s 0 "$X/logs/cost.csv"
EMPTY

# --- 3. the lane's own work, and anything unresolvable, is untouched --------
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  CWD="$T"
  case "$CMD" in
    *"@@CWD="*) CWD="${CMD##*@@CWD=}"; CMD="${CMD%%@@CWD=*}" ;;
  esac
  CMD="${CMD//@T@/$T}"; CWD="${CWD//@T@/$T}"
  : > "$T/logs/findings.log"; A0=$(alerts)
  RC=$(guard "$CMD" "$CWD")
  [ "$RC" = 0 ] || { bad "OVER-BLOCKED (rc=$RC): $CMD :: $(head -1 "$T/err")"; continue; }
  ok
  [ -s "$T/logs/findings.log" ] && bad "an allowed command filed a finding: $CMD" || ok
  [ "$(alerts)" = "$A0" ] || bad "an allowed command wrote an ALERTS line: $CMD"
done <<'ALLOWED'
rm -rf node_modules@@CWD=@T@/wt
rm -rf "$WT/node_modules"
rm -rf "$BUILD_DIR/node_modules"
rm -rf "$HARNESS/builds/testproj-TK-7-x/out"
rm -rf @T@/builds/testproj-TK-7-x/out
rm -rf /tmp/wt-abc
rm -rf "$(mktemp -d)/x"
rm -rf @T@/tmp/scratch
X=/tmp/a; rm -rf "$X/b"
rm -rf "${X:-/tmp/y}"
find /root/harness/logs -name '*.log'
find @T@/wt -name '*.ts' -delete
git commit -m "rm -rf the old logs"
git -C "$WT" clean -fd -e node_modules
git -C "$WT" clean -fd dist@@CWD=/root/harness/state
git -C @T@/wt clean -fd dist bin@@CWD=/root/repos/cromford
rm -rf @T@/wt/*
rm -rf "$BUILD_DIR"/*
git -C /root/repos/x worktree remove /root/worktrees/x-bh-9
echo "find -delete"
grep -r 'rm -rf' bin/
echo hi >> /root/harness/logs/ALERTS.log
echo json > state/x.json@@CWD=@T@/wt
echo json > /root/harness/state/x.json
setsid /root/harness/bin/run-build.sh p 1 K > /root/harness/logs/p.k-build.out 2>&1 &
rsync -a src/ /root/harness/state/
rsync --delete src/ host:/root/harness/env
rsync --delete src/ rsync://host/root/harness/env
truncate -s 0 /tmp/x
npm run build && npm test
npm run format
cat >/root/harness/state/x.json <<'JSON'
{"a":1}
JSON
bash -c 'echo ok'
ls -la /root/harness/env
ALLOWED

# A quoted heredoc body is DATA: the text being written into a file may contain
# any verb it likes and is not a command.
: > "$T/logs/findings.log"
RC=$(guard "cat > $T/wt/notes.md <<'EOF'
rm -rf /root/harness/env
EOF")
[ "$RC" = 0 ] && ok || bad "a quoted heredoc BODY was judged as a command (rc=$RC)"

# rm with nothing but flags has no target at all.
[ "$(guard "rm -rf")" = 0 ] && ok || bad "a targetless rm was refused"

# --- 4. lane semantics, and the refusal the session is shown ----------------
# No marker = not a harness session = no opinion at all, on any family.
[ "$(lane "" "rm -rf /root/harness/env")" = 0 ] \
  && ok || bad "a session with no HARNESS_LANE was guarded"
# Every MARKED lane carries family 6, including the three families 1-5 do not fence.
for L in orchestrator chat greenfield plan execute review fix qa triage; do
  A0=$(alerts)
  RC=$(lane "$L" "rm -rf $T/env")
  [ "$RC" = 2 ] || { bad "family 6 did not fire on the $L lane (rc=$RC)"; continue; }
  ok
  [ "$(alerts)" = "$((A0+1))" ] || bad "the $L lane refusal wrote no ALERTS line"
  grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
    || bad "the $L lane refusal gave the model no reason"
  grep -q "say so in your reply" "$T/err" \
    || bad "the $L lane refusal does not tell the session what to do instead"
  grep -q "use the literal path" "$T/err" \
    || bad "the $L lane refusal drops the empty-expansion hint"
done

# The header has to say what this is and is not (ticket §9 documentation pins).
[ "$(grep -c 'chattr' "$GUARD")" -ge 1 ] \
  && ok || bad "the header does not name the chattr wall (#388)"
grep -q "tripwire" "$GUARD" \
  && ok || bad "the header does not say this is a tripwire, not a sandbox"

# --- 5. families 1-5 keep their own fence, and stay findings-only -----------
for C in "gh pr merge 1" "git push origin main" "vercel --prod"; do
  for L in orchestrator chat; do
    [ "$(lane "$L" "$C")" = 0 ] \
      && ok || bad "a family 1-5 law fired on the unfenced $L lane: $C"
  done
  : > "$T/logs/findings.log"; A0=$(alerts)
  [ "$(guard "$C")" = 2 ] && ok || bad "family 1-5 stopped firing on the execute lane: $C"
  [ -s "$T/logs/findings.log" ] || bad "family 1-5 filed no finding: $C"
  [ "$(alerts)" = "$A0" ] \
    && ok || bad "a family 1-5 refusal wrote an ALERTS line (families 1-5 are findings-only): $C"
done

# --- 6. nothing above ever crashed the guard before it decided --------------
if grep -q "CRASHED" "$T/logs/ALERTS.log" 2>/dev/null; then
  bad "the guard crashed before reaching a verdict: $(grep CRASHED "$T/logs/ALERTS.log" | head -1)"
else
  ok
fi

echo "iron-law-fs: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
