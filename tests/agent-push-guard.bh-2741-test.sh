#!/bin/bash
# tests/agent-push-guard.bh-2741-test.sh — BH-2741: an agent session in a guarded
# lane does not push; the harness pushes after the session, through its hold
# check (bin/lib/hold-push.sh).
#
# WHY. BH-2504 put the harness's own pushes behind hold_push, which re-reads the
# ticket's HOLD at the push. An agent that ran `git push` itself inside its
# session never went through that check, so a lead's HOLD could still lose the
# race to the agent. bin/iron-law-guard.sh now denies every `git push` from a
# guarded lane (rule `agent-push`), and the one line it files names the hold it
# read, so a refused push on a held ticket is legible without a second log.
#
# Driven as shipped: a scratch $HARNESS carries the guard, bin/lib/hold-push.sh,
# bin/lib/hold.sh, bin/fleet-conf.sh, the lane shims and bin/lane-fence.sh in
# the repo's own layout, the guard is fed a real PreToolUse payload, and the
# origin is a real bare repo.
#   A1  held ticket, `git push origin <br>` -> rc 2, stderr names the HOLD, ONE
#       findings line with family=actguard-agent-push and hold=held, origin unmoved
#   A2  held ticket, bare `git push` from the worktree -> rc 2, hold=held
#   A3  the other spellings of a push -> rc 2, rule agent-push
#   A4  a clear ticket -> still rc 2, hold=clear; a board project -> hold=clear,
#       no GitHub read at all
#   A5  gh fails -> hold=unreadable; gh hangs -> rc 2 inside 15 s, hold=unchecked
#   A6  no lane / an unguarded lane -> rc 0, no finding
#   A7  commands that only MENTION a push -> rc 0, no finding
#   A8  the codex path: the PATH shim and the pre-push hook refuse the agent's
#       push; hold_push under the same fenced env still lands
#   A10 `git push origin main` stays rule push-main
#   bash tests/agent-push-guard.bh-2741-test.sh     exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
# This suite is itself run by harness lanes that export HARNESS_LANE.
unset HARNESS_LANE HARNESS_LANE_PROJECT HARNESS_TICKET

H="$T/h"
mkdir -p "$T/fakebin" "$T/gh" "$H/bin/lib" "$H/logs"
cp "$DIR/bin/iron-law-guard.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/lane-fence.sh" "$H/bin/"
cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/hold-push.sh" "$H/bin/lib/"
cp -r "$DIR/bin/lane-shims" "$H/bin/"
GUARD="$H/bin/iron-law-guard.sh"
FIND="$H/logs/findings.log"

{ printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj 192.0.2.8\n'; } > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"

# --- the fake GitHub (the shape tests/hold-push-guard.bh-2504-test.sh uses) ---
#   $T/gh/issue-<n>.json  $T/gh/comments-<n>.json
#   $T/gh/fail = every read fails; $T/gh/hang = every read sleeps 30 s
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
[ -f "$T/gh/hang" ] && sleep 30   # determinism: ok a stub that never answers; A5 asserts the guard gives up on it
[ -f "$T/gh/fail" ] && { echo "API rate limit already exceeded (FIXTURE)" >&2; exit 1; }
N=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p' | head -1)
case "\$*" in
  *"/issues/"*"/comments"*) cat "$T/gh/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"/issues/"*) cat "$T/gh/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

jq -nc '{number:9,state:"open",title:"TK-9: a FIXTURE ticket",body:"## Scope",labels:[{name:"ai-build"}]}' > "$T/gh/issue-9.json"
HELD() { jq -nc '[{body:"HOLD — lead: a fix agent owns this branch now.",created_at:"2026-09-26T20:11:00Z",user:{type:"User"}}]' > "$T/gh/comments-9.json"; }
CLEAR() { echo '[]' > "$T/gh/comments-9.json"; }

# --- a real origin and a worktree on the ticket branch -----------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git clone -q "$G/origin.git" "$G/wt" 2>/dev/null
WT="$G/wt"
gitc() { git -C "$1" -c user.name=FIXTURE -c user.email=fixture@example.invalid -c commit.gpgsign=false "${@:2}"; }
echo base > "$WT/f.txt"; git -C "$WT" add f.txt; gitc "$WT" commit -qm base
git -C "$WT" push -q origin HEAD:refs/heads/main
git -C "$WT" checkout -qb ticket/TK-9
echo pr > "$WT/pr.txt"; git -C "$WT" add pr.txt; gitc "$WT" commit -qm "TK-9: the PR"
git -C "$WT" push -q origin HEAD:refs/heads/ticket/TK-9
LEASE=$(git -C "$G/origin.git" rev-parse refs/heads/ticket/TK-9)
echo local >> "$WT/pr.txt"; git -C "$WT" add pr.txt; gitc "$WT" commit -qm "a local round"
NEW=$(git -C "$WT" rev-parse HEAD)
tip() { git -C "$G/origin.git" rev-parse refs/heads/ticket/TK-9; }

# guard <lane|-> <project> <command> [cwd] -> prints rc; stderr in $T/err
guard() {
  local lane="$1" proj="$2" cmd="$3" cwd="${4:-$WT}" pl
  pl=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}')
  local -a e=(env HARNESS="$H" HARNESS_LANE_PROJECT="$proj" HARNESS_TICKET=TK-9)
  [ "$lane" = - ] || e+=(HARNESS_LANE="$lane")
  printf '%s' "$pl" | timeout 30 "${e[@]}" bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
nfind() { awk 'END { print NR }' "$FIND" 2>/dev/null || echo 0; }

# ── A1. a held ticket: the push is refused, one line names the hold ─────────
HELD; : > "$FIND"
RC=$(guard fix tproj "git push origin ticket/TK-9")
[ "$RC" = 2 ] && ok || bad "A1 an agent push on a held ticket must be refused (rc $RC)"
grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" && ok || bad "A1 no deny reason on stderr"
grep -q "HOLD" "$T/err" && ok || bad "A1 the deny reason must name the HOLD: $(cat "$T/err")"
[ "$(nfind)" = 1 ] && ok || bad "A1 exactly one findings line (got $(nfind))"
grep -q 'family=actguard-agent-push' "$FIND" 2>/dev/null && ok || bad "A1 the finding is not family=actguard-agent-push: $(cat "$FIND" 2>/dev/null)"
grep -q 'hold=held' "$FIND" 2>/dev/null && ok || bad "A1 the finding must name hold=held: $(cat "$FIND" 2>/dev/null)"
[ "$(tip)" = "$LEASE" ] && ok || bad "A1 origin moved"

# ── A2. bare `git push` from the worktree on the held branch ────────────────
: > "$FIND"
RC=$(guard fix tproj "git push")
[ "$RC" = 2 ] && ok || bad "A2 a bare push on a held ticket's branch must be refused (rc $RC)"
grep -q 'hold=held' "$FIND" 2>/dev/null && ok || bad "A2 the bare push's finding must name hold=held: $(cat "$FIND" 2>/dev/null)"

# ── A3. the other spellings ─────────────────────────────────────────────────
CLEAR
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  : > "$FIND"
  RC=$(guard fix tproj "$CMD" "$T")
  [ "$RC" = 2 ] && grep -q 'family=actguard-agent-push' "$FIND" 2>/dev/null \
    && ok || bad "A3 not denied as agent-push (rc $RC): $CMD :: $(cat "$FIND" 2>/dev/null)"
done <<CASES
git -C $WT push -u origin HEAD
git -C $WT push --force-with-lease origin ticket/TK-9
rtk git push origin ticket/TK-9
bash -c 'git push origin ticket/TK-9'
cd $WT && git push
CASES
: > "$FIND"
RC=$(guard execute tproj "git push -u origin HEAD")
[ "$RC" = 2 ] && grep -q 'hold=clear.*o/tproj#9' "$FIND" 2>/dev/null \
  && ok || bad "A3 \`git push -u origin HEAD\` must resolve HEAD to ticket/TK-9 (rc $RC): $(cat "$FIND" 2>/dev/null)"

# ── A4. clear ticket, and a board project ───────────────────────────────────
CLEAR; : > "$FIND"
RC=$(guard fix tproj "git push origin ticket/TK-9")
[ "$RC" = 2 ] && ok || bad "A4 an agent push on a CLEAR ticket is still the harness's push (rc $RC)"
grep -q 'family=actguard-agent-push.*hold=clear' "$FIND" 2>/dev/null && ok || bad "A4 the finding must say hold=clear: $(cat "$FIND" 2>/dev/null)"
grep -q 'on HOLD' "$T/err" && bad "A4 a clear ticket's refusal must not claim a HOLD" || ok
: > "$FIND"; : > "$T/gh.log"
RC=$(guard fix iproj "git push origin ticket/TK-9")
[ "$RC" = 2 ] && grep -q 'hold=clear.*no GitHub issue' "$FIND" 2>/dev/null \
  && ok || bad "A4 a board project: rc 2 and hold=clear … no GitHub issue (rc $RC): $(cat "$FIND" 2>/dev/null)"
[ -s "$T/gh.log" ] && bad "A4 a board project must not read GitHub: $(cat "$T/gh.log")" || ok

# ── A5. an unreadable and a hanging hold read ───────────────────────────────
touch "$T/gh/fail"; : > "$FIND"
RC=$(guard fix tproj "git push origin ticket/TK-9")
[ "$RC" = 2 ] && grep -q 'hold=unreadable' "$FIND" 2>/dev/null \
  && ok || bad "A5 gh failing: rc 2 and hold=unreadable (rc $RC): $(cat "$FIND" 2>/dev/null)"
rm -f "$T/gh/fail"; touch "$T/gh/hang"; : > "$FIND"
S0=$SECONDS
RC=$(guard fix tproj "git push origin ticket/TK-9")
EL=$((SECONDS - S0))
[ "$RC" = 2 ] && ok || bad "A5 a hanging hold read must still refuse (rc $RC)"
[ "$EL" -le 15 ] && ok || bad "A5 the guard took ${EL}s — a hanging hold read must be bounded"
grep -q 'hold=unchecked' "$FIND" 2>/dev/null && ok || bad "A5 a hanging read must say hold=unchecked: $(cat "$FIND" 2>/dev/null)"
[ "$(nfind)" = 1 ] && ok || bad "A5 exactly one findings line (got $(nfind))"
rm -f "$T/gh/hang"

# ── A6. sessions that keep push authority ───────────────────────────────────
HELD; : > "$FIND"
for L in - chat lead-review remediate; do
  RC=$(guard "$L" tproj "git push origin ticket/TK-9")
  [ "$RC" = 0 ] && ok || bad "A6 lane '$L' must keep its push (rc $RC)"
done
[ -s "$FIND" ] && bad "A6 an allowed push filed a finding: $(cat "$FIND")" || ok

# ── A7. commands that only mention a push ───────────────────────────────────
: > "$FIND"
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  RC=$(guard fix tproj "$CMD")
  [ "$RC" = 0 ] && ok || bad "A7 OVER-BLOCKED (rc $RC): $CMD :: $(head -1 "$T/err")"
done <<'ALLOWED'
git log --grep push -5
git commit -m "push later"
echo "git push origin x"
gh pr create --title "push fix"
git status && npm test
git stash push -m wip
npx prisma generate
ALLOWED
RC=$(guard fix tproj "$(printf 'cat > /tmp/runbook.md <<%s\ngit push origin ticket/TK-9\nEOF\necho wrote it\n' "'EOF'")")
[ "$RC" = 0 ] && ok || bad "A7 a quoted heredoc BODY naming git push was refused (rc $RC)"
[ -s "$FIND" ] && bad "A7 an allowed command filed a finding: $(head -1 "$FIND")" || ok

# ── A8. the codex lanes: PATH shim + pre-push hook, and the harness push ────
CLEAR
SHIMS="$H/bin/lane-shims"
mapfile -t HE < <(env HARNESS="$H" bash "$H/bin/lane-fence.sh" hooks-env "$WT" 2>/dev/null)
[ "${#HE[@]}" = 3 ] && ok || bad "A8 lane-fence hooks-env printed no GIT_CONFIG pointer: ${HE[*]:-none}"
FENV=(HARNESS="$H" HARNESS_LANE=execute HARNESS_LANE_PROJECT=tproj HARNESS_TICKET=TK-9 "${HE[@]}")
( cd "$WT" && env "${FENV[@]}" PATH="$SHIMS:$PATH" "$SHIMS/_fence.sh" --shim git push -q origin HEAD:refs/heads/ticket/TK-9 ) >/dev/null 2>"$T/err"
RC=$?
[ "$RC" != 0 ] && ok || bad "A8 the PATH shim let the agent's push through"
[ "$(tip)" = "$LEASE" ] && ok || bad "A8 origin moved under the PATH shim"
( cd "$WT" && env "${FENV[@]}" git push -q origin HEAD:refs/heads/ticket/TK-9 ) >/dev/null 2>"$T/err"
RC=$?
[ "$RC" != 0 ] && grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
  && ok || bad "A8 the pre-push hook let the agent's raw push through (rc $RC)"
[ "$(tip)" = "$LEASE" ] && ok || bad "A8 origin moved past the pre-push hook"
( cd "$WT" && env "${FENV[@]}" PATH="$SHIMS:$PATH" bash -c \
    '. "$1" && hold_push tproj - "$2" origin HEAD ticket/TK-9 "$3"' _ "$H/bin/lib/hold-push.sh" "$WT" "$LEASE" ) >/dev/null 2>"$T/err"
RC=$?
[ "$RC" = 0 ] && ok || bad "A8 hold_push inside a fenced lane must still push (rc $RC): $(head -3 "$T/err")"
[ "$(tip)" = "$NEW" ] && ok || bad "A8 the harness's hold-checked push did not reach origin"

# ── A10. main keeps its own rule ────────────────────────────────────────────
: > "$FIND"
RC=$(guard fix tproj "git push origin main")
[ "$RC" = 2 ] && grep -q 'family=actguard-push-main ' "$FIND" 2>/dev/null \
  && ok || bad "A10 a push to main must stay rule push-main (rc $RC): $(cat "$FIND" 2>/dev/null)"
grep -q 'hold=' "$FIND" 2>/dev/null && bad "A10 push-main must not spend a hold read" || ok
# HEAD while standing on main is main, whether the cwd, a `cd` or `-C` says so.
git clone -q "$G/origin.git" "$G/onmain" 2>/dev/null
for CMD in "git -C $G/onmain push origin HEAD" "cd $G/onmain && git push -u origin HEAD"; do
  : > "$FIND"
  RC=$(guard fix tproj "$CMD" "$T")
  [ "$RC" = 2 ] && grep -q 'family=actguard-push-main ' "$FIND" 2>/dev/null \
    && ok || bad "A10 HEAD on main must be rule push-main (rc $RC): $CMD :: $(cat "$FIND" 2>/dev/null)"
done

echo "agent-push-guard (BH-2741): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
