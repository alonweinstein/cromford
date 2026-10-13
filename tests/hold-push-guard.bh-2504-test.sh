#!/bin/bash
# tests/hold-push-guard.bh-2504-test.sh — BH-2504: a lane that pushes to a PR
# branch re-reads the ticket's HOLD right before `git push`, and pushes with a
# lease on the sha it started from.
#
# THE INCIDENT (2026-09-25). The lead held #2406 at 20:11:01Z and
# bin/blocked-resolver.sh pushed a fix round to ticket/bh-2406 at 20:11:30Z: it
# read the hold when its run STARTED and never again. The same evening a main
# merge, a rebuild and a harness push each landed on a held branch while a lead
# fix agent worked it. Two writers on one branch (#2182).
#
# THE ACCEPTANCE ROWS (red first — every one fails on main):
#   G  bin/lib/hold-push.sh against a REAL bare origin and a fake GitHub:
#   G1 no HOLD and an unchanged branch -> pushed, as today
#   G2 a HOLD posted AFTER the round started (the start read said clear) and
#      before the push -> nothing pushed, rc 3, one line
#   G3 RESUME after the HOLD -> pushed
#   G4 a lead commit lands mid-round -> the lease rejects the push, rc 1, and
#      the lead's commit is what origin still holds
#   G5 the `hold` label -> nothing pushed
#   G6 the hold cannot be read -> nothing pushed, rc 4
#   G7 a board project (no GitHub issue) -> no issue read, pushed under the lease
#   G8 an empty lease is a usage error, never "no lease"
#   R  bin/blocked-resolver.sh's real br_fix_round, lifted by name:
#   R1 no HOLD -> the round is pushed, under the lease on the head it read
#   R2 a HOLD posted WHILE the round runs -> nothing pushed, no fixrounds
#      counter, no PR comment, the HELD bookkeeping called
#   R3 HOLD then RESUME while it runs -> pushed
#   R4 the hold unreadable at the push -> nothing pushed
# Run from anywhere: tests/hold-push-guard.bh-2504-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE fixed clock for every comment timestamp: the thread's order is the fixture's.
ISO() { printf '2026-09-25T20:%02d:00Z' "$1"; }

mkdir -p "$T/fakebin" "$T/gh" "$T/h/bin/lib"
# A scratch harness: gh-rest's ETag cache and any log default under $HARNESS.
export HARNESS="$T/h"
# FIXTURE fleet: tproj is a GitHub-Issues lane (board prefix "-"), iproj an
# in-app board whose tickets are not issues.
{ printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj 192.0.2.8\n'; } > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"

# --- the fake GitHub: the issue and its thread, per number -------------------
#   $T/gh/issue-<n>.json  $T/gh/comments-<n>.json   $T/gh/fail = every read fails
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
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

ISSUE() { # ISSUE <n> [labels,csv]
  local labels='["ai-build"]'
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")')
  jq -nc --argjson n "$1" --argjson l "$labels" \
    '{number:$n,state:"open",title:"TK-9: a FIXTURE ticket",body:"## Scope",labels:[$l[]|{name:.}]}' > "$T/gh/issue-$1.json"
}
THREAD() { # THREAD <n> [<body> <minute>]... — the REST comments array, oldest first
  local n="$1"; shift; local rows=()
  while [ $# -ge 2 ]; do
    rows+=("$(jq -nc --arg b "$1" --arg c "$(ISO "$2")" '{body:$b,created_at:$c,user:{type:"User"}}')")
    shift 2
  done
  local IFS=,; printf '[%s]\n' "${rows[*]}" > "$T/gh/comments-$n.json"
}

# The library under test, laid out as it ships: hold-push.sh beside hold.sh,
# fleet-conf.sh one directory up.
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/hold-push.sh" "$T/h/bin/lib/" 2>/dev/null || true
HP="$T/h/bin/lib/hold-push.sh"

# --- a real origin and a working clone -----------------------------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git clone -q "$G/origin.git" "$G/wt" 2>/dev/null
gitc() { git -C "$1" -c user.name=FIXTURE -c user.email=fixture@example.invalid -c commit.gpgsign=false "${@:2}"; }
( cd "$G/wt" && echo base > f.txt && git add f.txt ) && gitc "$G/wt" commit -qm base
git -C "$G/wt" push -q origin HEAD:refs/heads/main
git -C "$G/wt" checkout -qb ticket/TK-9
echo pr > "$G/wt/pr.txt"; git -C "$G/wt" add pr.txt; gitc "$G/wt" commit -qm "TK-9: the PR"
git -C "$G/wt" push -q origin HEAD:refs/heads/ticket/TK-9
BR=ticket/TK-9
remote_tip() { git -C "$G/origin.git" rev-parse "refs/heads/$1" 2>/dev/null; }

# ROUND — a round starts: the lease is the PR head, and a local commit is made.
ROUND() {
  git -C "$G/wt" fetch -q origin
  git -C "$G/wt" reset -q --hard "origin/$BR"
  LEASE=$(remote_tip "$BR")
  echo "round $1" >> "$G/wt/pr.txt"; git -C "$G/wt" add pr.txt; gitc "$G/wt" commit -qm "round $1"
  NEW=$(git -C "$G/wt" rev-parse HEAD)
}
PUSH() { # PUSH <project> <ticket> -> rc; stderr to $T/push.err
  ( . "$HP" 2>/dev/null || exit 99
    hold_push "$1" "$2" "$G/wt" origin HEAD "$BR" "$LEASE" ) 2>"$T/push.err"
}

# ============================================================================
# G — bin/lib/hold-push.sh
# ============================================================================
[ -r "$HP" ] && ok || bad "bin/lib/hold-push.sh does not exist — there is no guarded push"

# G1 — no HOLD, the branch unchanged: pushed exactly as today
ISSUE 9; THREAD 9
ROUND 1; PUSH tproj -; RC=$?
[ "$RC" = 0 ] && ok || bad "G1 an unheld ticket and an unchanged branch must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G1 origin must hold the round's commit"
grep -q 'issues/9' "$T/gh.log" 2>/dev/null && ok || bad "G1 the push must read ticket #9 (the branch's ticket) first"

# G2 — the round STARTS clear, a HOLD lands while it runs, then the push
ISSUE 9; THREAD 9
ROUND 2
( . "$HP" 2>/dev/null && hold_push_verdict tproj - "$BR" >/dev/null ); RC=$?
[ "$RC" = 0 ] && ok || bad "G2 the round's start read must be clear (rc $RC)"
THREAD 9 'HOLD — lead: a fix agent owns this branch now.' 11
PUSH tproj -; RC=$?
[ "$RC" = 3 ] && ok || bad "G2 a HOLD posted after the round started must refuse the push with rc 3 (got $RC)"
[ "$(remote_tip "$BR")" = "$LEASE" ] && ok || bad "G2 nothing may reach origin under a HOLD"
[ "$(grep -c 'HOLD' "$T/push.err")" = 1 ] && ok || bad "G2 exactly one line naming the HOLD: $(cat "$T/push.err")"

# G3 — RESUME after the HOLD lifts it
THREAD 9 'HOLD — lead: a fix agent owns this branch now.' 11 'RESUME' 12
PUSH tproj -; RC=$?
[ "$RC" = 0 ] && ok || bad "G3 RESUME after HOLD must let the push through (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "G3 origin must hold the round's commit"

# G4 — a lead commit lands on the branch mid-round: the lease refuses the push
ISSUE 9; THREAD 9
ROUND 4
git clone -q "$G/origin.git" "$G/lead" 2>/dev/null
git -C "$G/lead" checkout -q "$BR"
echo lead > "$G/lead/lead.txt"; git -C "$G/lead" add lead.txt; gitc "$G/lead" commit -qm "lead fix"
git -C "$G/lead" push -q origin "HEAD:refs/heads/$BR"
LEADSHA=$(git -C "$G/lead" rev-parse HEAD)
PUSH tproj -; RC=$?
[ "$RC" = 1 ] && ok || bad "G4 a branch that moved since the round started must be refused by the lease, rc 1 (got $RC)"
[ "$(remote_tip "$BR")" = "$LEADSHA" ] && ok || bad "G4 the lead's commit must still be origin's tip — never force-overwritten"
grep -q 'nothing overwritten' "$T/push.err" && ok || bad "G4 one line must say the lease refused it: $(cat "$T/push.err")"

# G5 — the `hold` label holds, whatever the thread says
ISSUE 9 'ai-build,hold'; THREAD 9 'RESUME' 1
ROUND 5; PUSH tproj -; RC=$?
[ "$RC" = 3 ] && ok || bad "G5 the hold label must refuse the push (rc $RC)"
[ "$(remote_tip "$BR")" = "$LEASE" ] && ok || bad "G5 nothing may reach origin under the hold label"

# G6 — the hold cannot be read: nothing pushed, and it says so
ISSUE 9; THREAD 9; : > "$T/gh/fail"
ROUND 6; PUSH tproj -; RC=$?
rm -f "$T/gh/fail"
[ "$RC" = 4 ] && ok || bad "G6 an unreadable hold must refuse the push with rc 4 (got $RC)"
[ "$(remote_tip "$BR")" = "$LEASE" ] && ok || bad "G6 nothing may reach origin when the hold could not be read"

# G7 — a board project has no GitHub issue: no read, the lease is the guard
: > "$T/gh.log"
ROUND 7; PUSH iproj -; RC=$?
[ "$RC" = 0 ] && ok || bad "G7 a board ticket must push under the lease (rc $RC: $(cat "$T/push.err"))"
[ -s "$T/gh.log" ] && bad "G7 a board ticket must make no issue read: $(cat "$T/gh.log")" || ok
# ...and a caller that names the issue outright is read on that repo
ISSUE 9; THREAD 9 'HOLD' 3
ROUND 71; PUSH iproj 'o/tproj#9'; RC=$?
[ "$RC" = 3 ] && ok || bad "G7 an explicitly named issue that is held must refuse the push (rc $RC)"

# G8 — no lease is not a lease
ISSUE 9; THREAD 9
ROUND 8; LEASE=""; PUSH tproj -; RC=$?
[ "$RC" = 64 ] && ok || bad "G8 an empty lease must be a usage error (got $RC)"
[ "$(git -C "$G/origin.git" rev-parse "refs/heads/$BR")" != "$NEW" ] && ok || bad "G8 nothing may be pushed without a lease"

# ============================================================================
# R — br_fix_round, the resolver's real function, with git and the agent stubbed.
# ============================================================================
BRS="$DIR/bin/blocked-resolver.sh"
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BRS"; }
lift br_fix_round > "$T/fixround.sh"
[ -s "$T/fixround.sh" ] && ok || bad "R0 br_fix_round could not be lifted"
HEAD1=1111111111111111111111111111111111111111
NEWHEAD=3333333333333333333333333333333333333333
URL="https://github.com/o/tproj/pull/7"
RH="$T/rh"; ST="$T/st"; REPOS="$T/repos"
mkdir -p "$RH/bin" "$ST/tproj" "$REPOS/tproj/.git"
printf '#!/bin/bash\n[ "$2" = repo ] && echo o/tproj\nexit 0\n' > "$RH/bin/fleet-conf.sh"
# The agent is where the round's time goes; AGENT_THREAD is what the lead posts
# on the ticket WHILE it runs.
cat > "$RH/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'agent\n' >> "$T/agent.log"
[ -n "\${AGENT_THREAD:-}" ] && printf '%s\n' "\$AGENT_THREAD" > "$T/gh/comments-7.json"
[ -n "\${AGENT_FAIL:-}" ] && : > "$T/gh/fail"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$RH/bin/lane-alert.sh"
chmod +x "$RH/bin/"*.sh
cat > "$T/fr-stubs.sh" <<EOF
OBSERVE=0; H="$RH"; ST="$ST"; LOG="$T/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
STAMP() { printf '2026-09-25 20:00:00Z'; }
say() { printf '%s\n' "\$*" >> "$T/say.log"; }
br_event() { printf '%s\n' "\$*" >> "$T/events.log"; }
br_file() { printf '%s' "$T/rec.json"; }
br_load() { echo '{}'; }
br_push_field() { :; }
br_has_field_value() { return 1; }
br_json_edit() { :; }
br_cap_key() { printf ck; }
br_num() { printf 0; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal %s\n' "\$3" >> "$T/terminal.log"; }
br_pr_ref() { printf 'o/tproj ticket/TK-7 %s\n' "$HEAD1"; }
br_slug_of_url() { printf 'o/tproj'; }
mc_num_of_url() { printf 7; }
br_findings() { printf '1. HIGH src/app.ts:12 the route is unauthenticated.\n'; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$T/terminal.log"; }
br_ladder_class() { echo ""; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$T/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
br_pr_comment() { printf 'comment %s\n' "\$2" >> "$T/comments.log"; }
br_fix_push_note() { :; }
gi_check() { return 0; }
br_rebuild_fresh() { printf 'rebuild %s\n' "\$3" >> "$T/terminal.log"; }
# The ticket behind this park, as the resolver's own hold gate names it.
br_hold_issue() { printf 'o/tproj 7'; }
br_hold_gate() { printf 'hold-gate %s\n' "\$*" >> "$T/holdgate.log"; return 1; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  printf 'git %s\n' "\${a[*]}" >> "$T/git.log"
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/main") echo mainsha ;;
    "rev-parse --verify -q origin/"*) echo "$HEAD1" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD"|"rev-parse --short HEAD") echo "$NEWHEAD" ;;
    "log --no-merges --name-only --format= HEAD --not"*) echo src/app.ts ;;
    "ls-files") echo src/app.ts ;;
    *" push "*|"push "*) printf '%s\n' "\${a[*]}" >> "$T/push.log" ;;
    *) return 0 ;;
  esac
}
EOF
# The real hold library, as the resolver sources it on a box.
printf '. "%s"\n. "%s"\n' "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/hold-push.sh" > "$T/libs.sh"
FR() { # FR — the real br_fix_round in a fresh shell, reason head-not-reapproved
  rm -f "$T/agent.log" "$T/git.log" "$T/terminal.log" "$T/record.log" "$T/push.log" \
        "$T/comments.log" "$T/events.log" "$T/holdgate.log" "$T/gh/fail"
  bash -c '. "$1" 2>/dev/null; . "$2"; . "$3"; br_fix_round tproj rk head-not-reapproved "$4" /rec TK-7' _ \
    "$T/libs.sh" "$T/fr-stubs.sh" "$T/fixround.sh" "$URL" >/dev/null 2>&1
}

# R1 — no HOLD: the round is pushed, leased on the head it read
ISSUE 7; THREAD 7
FR
[ -s "$T/agent.log" ] && ok || bad "R1 the fix round must run (terminal: $(cat "$T/terminal.log" 2>/dev/null))"
grep -q "ticket/TK-7:$HEAD1" "$T/push.log" 2>/dev/null && ok \
  || bad "R1 the push must lease on the head the round read ($HEAD1): $(cat "$T/push.log" 2>/dev/null)"
grep -q -- '--force-with-lease' "$T/push.log" 2>/dev/null && ok || bad "R1 the push must be a lease push"
[ -s "$T/comments.log" ] && ok || bad "R1 a pushed round comments on the PR"

# R2 — the lead posts HOLD on the ticket while the round runs
ISSUE 7; THREAD 7
AGENT_THREAD="$(jq -nc --arg c "$(ISO 30)" '[{body:"HOLD — lead: I am fixing this PR myself.",created_at:$c,user:{type:"User"}}]')" FR
[ -s "$T/agent.log" ] && ok || bad "R2 the round must have started (the HOLD came after the dispatch)"
[ ! -s "$T/push.log" ] && ok || bad "R2 a HOLD posted mid-round must stop the push: $(cat "$T/push.log")"
grep -q 'fixrounds' "$T/record.log" 2>/dev/null && bad "R2 a held round must spend no fixrounds counter: $(cat "$T/record.log")" || ok
[ -s "$T/comments.log" ] && bad "R2 a held round must not comment on the PR: $(cat "$T/comments.log")" || ok
[ -s "$T/holdgate.log" ] && ok || bad "R2 the HELD bookkeeping (br_hold_gate) must run"
[ -s "$T/terminal.log" ] && bad "R2 a hold is not a terminal — nothing rebuilt or escalated: $(cat "$T/terminal.log")" || ok

# R3 — HOLD then RESUME while it runs: pushed
ISSUE 7; THREAD 7
AGENT_THREAD="$(jq -nc --arg a "$(ISO 30)" --arg b "$(ISO 31)" \
  '[{body:"HOLD",created_at:$a,user:{type:"User"}},{body:"RESUME",created_at:$b,user:{type:"User"}}]')" FR
[ -s "$T/push.log" ] && ok || bad "R3 RESUME after HOLD must let the round push"

# R4 — the hold cannot be read at the push: nothing pushed
ISSUE 7; THREAD 7
AGENT_FAIL=1 FR
[ ! -s "$T/push.log" ] && ok || bad "R4 an unreadable hold at the push must not push: $(cat "$T/push.log")"
grep -q 'fixrounds' "$T/record.log" 2>/dev/null && bad "R4 an unreadable hold spends no fixrounds counter" || ok

echo "hold-push-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
