#!/bin/bash
# tests/feature-map-draft.bh-2005-test.sh — the draft lane of BH-2005 (built as
# BH-2037): bin/feature-map-draft.sh, the operator CLI that drafts a
# verification map for an unmapped app repo and opens a PR, never merging it.
#
# Drives the REAL script. Everything it calls lives in a scratch $HARNESS/bin
# (fleet-conf.sh, agent-call.sh, jobs-client.sh, and the real lib/lane-model.sh)
# or on PATH (gh), and each project is a scratch clone of a scratch bare repo,
# so a push is a real push and `git ls-remote` on the bare repo is the proof of
# what reached origin.
#
#   off FEATURE_MAP_DRAFT_ENABLED unset/0/yes -> rc 3 REFUSED, no gh, no agent
#   a   open feature-map/draft PR           -> rc 3 REFUSED, no agent, no push
#   b   gh pr list fails / is not JSON       -> rc 1, no agent
#   b2  branch on origin, no PR              -> rc 3, no agent, sha unchanged
#   c   map already on main                  -> rc 5 ALREADY_MAPPED
#   d   knob unset/7.5/abc/0/unreadable      -> 15 / 7.5 / rc 2 / rc 2 / 15+log
#   e   agent writes nothing                 -> rc 4 DRAFT_EMPTY, no push
#   f   happy path (+ no-workflow variant)   -> pushed, PR, body, log line;
#       prompt names the drive scripts by absolute harness path
#   fs  agent stages strays itself           -> only the map + workflow committed
#   g   --all --dry-run                      -> four projects in ticket order
#   dry one project; slug unresolved; push fails; agent rc 77; no prod URL;
#   no model route; cost over cap (on PR_OPENED and on DRAFT_EMPTY).
#
# MUTATION NOTE (D1): deleting the `return 3` after the open-PR refusal turns
# (a) red (the agent gets called and a branch is pushed); deleting the
# DRAFT_EMPTY check turns (e) red (an empty commit attempt, rc != 4); dropping
# the index reset + commit pathspec turns (fs) red; moving the over-cap alert
# back behind the PR turns capempty red; a relative drive path turns (f) red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/feature-map-draft.bh-2005-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/feature-map-draft.sh"

ok=0; bad=0
pass() { ok=$((ok+1)); }
fail() { bad=$((bad+1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" "$2" 2>/dev/null; then pass; else fail "$1: [$3] not in $2: $(head -c 600 "$2" 2>/dev/null)"; fi; }
hasnt() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1: [$3] unexpectedly in $2"; else pass; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

H="$T/h"; R="$T/repos"; B="$T/bare"; P="$T/path"
mkdir -p "$H/bin/lib" "$H/logs" "$R" "$B" "$P"
cp "$DIR/bin/lib/lane-model.sh" "$H/bin/lib/lane-model.sh"

# --- stubs -------------------------------------------------------------------
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
# The --all list is the fleet's (bin/fleet-conf.sh --projects-with-board), in
# fleet.conf order; FLEET_LIST=fail makes that read fail. It is not logged in
# fleet.log, which records the per-project slug reads in the order they ran.
if [ "$1" = --projects-with-board ]; then
  [ "${FLEET_LIST:-ok}" = fail ] && exit 1
  printf '%s\n' project-3 project-1 project-4 project-5; exit 0
fi
echo "$1" >> "$STUBLOG/fleet.log"
case "$1" in ghost) exit 1 ;; esac
[ "$2" = repo ] && echo "example-org/$1"
EOF
cat > "$H/bin/prod-url.sh" <<'EOF'
#!/bin/bash
case "$1" in noprod-os) exit 1 ;; esac
echo "https://$1.example"
EOF
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
{ echo "argv $1 $2 $3 $4"
  echo "AGENT_CALL_ROLE=${AGENT_CALL_ROLE:-}"
  echo "AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT=${AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT:-}"
} >> "$STUBLOG/agent.log"
printf '%s' "$6" > "$STUBLOG/prompt.txt"
echo "2026-09-24T00:00:00Z,box,$2,$1,claude,$3,0,10,1,1,1,1,${AGENT_COST:-1.25},metered" >> "$HARNESS/logs/cost.csv"
if [ "${AGENT_MODE:-full}" != none ]; then
  mkdir -p docs/verification-map/entries
  echo "# map" > docs/verification-map/README.md
  printf '| a |\n\n**Manual-only / not automatable:** the Stripe checkout redirect\n\n## next\n' > docs/verification-map/entries/pay.md
  printf '| b |\n\n**Manual-only / not automatable:** none\n' > docs/verification-map/entries/list.md
  echo stray > stray.txt
  # an agent that stages habitually: none of these may reach the commit
  if [ "${AGENT_STAGE:-}" = 1 ]; then
    mkdir -p shots && echo png > shots/prod.png && echo SECRET=x > .env.qa
    git add -f stray.txt shots/prod.png .env.qa
  fi
  if [ "${AGENT_MODE:-full}" != nowf ]; then
    mkdir -p .github/workflows && echo "name: vmap" > .github/workflows/verification-map-freshness.yml
  fi
fi
exit "${AGENT_RC:-0}"
EOF
cat > "$H/bin/jobs-client.sh" <<'EOF'
setting_get() {
  echo "$1" >> "$STUBLOG/knob.log"
  [ -n "${KNOB_VAL:-}" ] && printf '%s' "$KNOB_VAL"
  return "${KNOB_RC:-2}"
}
EOF
cat > "$P/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUBLOG/gh.log"
case "$1 $2" in
  # The open-draft-PR read, over REST (bin/lib/gh-rest.sh: `gh api -i -X GET`).
  "api -i")
    case "$*" in *"/pulls?state=open&head="*) ;; *) exit 0 ;; esac
    case "${GH_LIST:-empty}" in
      empty) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
      open)  printf 'HTTP/1.1 200 OK\r\n\r\n[{"number":9,"html_url":"https://github.com/o/r/pull/9"}]\n' ;;
      junk)  printf 'HTTP/1.1 200 OK\r\n\r\nHTTP 502 bad gateway\n' ;;
      fail)  printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"fixture"}\n'; exit 1 ;;
    esac ;;
  "pr create")
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$STUBLOG/body.md"; shift; done
    [ "${GH_CREATE:-ok}" = fail ] && exit 1
    echo "https://github.com/example-org/stub/pull/77" ;;
esac
EOF
chmod +x "$H/bin/"*.sh "$P/gh"

mkrepo() { # mkrepo <project> — fresh bare origin + clone with one commit on main
  local p="$1"
  scratch_rm "$B/$p.git"; scratch_rm "$R/$p"
  git init -q --bare -b main "$B/$p.git"
  git init -q -b main "$R/$p"
  mkdir -p "$R/$p/docs"; echo hi > "$R/$p/docs/intro.md"
  git -C "$R/$p" add -A && git -C "$R/$p" commit -qm init
  git -C "$R/$p" remote add origin "$B/$p.git"
  git -C "$R/$p" push -q origin main
}

reset() { # fresh logs + default knobs for a case
  STUBLOG="$T/log.$1"; scratch_rm "$STUBLOG"; mkdir -p "$STUBLOG"; : > "$STUBLOG/agent.log"; : > "$STUBLOG/gh.log"
  rm -f "$H/logs/ALERTS.log" "$H/logs/feature-map-draft.log" "$H/logs/cost.csv"
  export STUBLOG
  unset GH_LIST FLEET_LIST GH_CREATE KNOB_VAL KNOB_RC AGENT_MODE AGENT_RC AGENT_COST AGENT_STAGE
  export FEATURE_MAP_MODEL=stub-model
  export FEATURE_MAP_DRAFT_ENABLED=1   # the lane's enable knob; the "off" cases unset it
}

run() { # run <args...> — the real script; OUT/ERR/RC
  HARNESS="$H" REPOS_ROOT="$R" PATH="$P:$PATH" "$SCRIPT" "$@" > "$STUBLOG/out" 2> "$STUBLOG/err"
  RC=$?
}

remote_head() { git ls-remote "$B/$1.git" refs/heads/feature-map/draft; }
wt_count() { git -C "$R/$1" worktree list | wc -l | tr -d ' '; }
agent_calls() { wc -l < "$STUBLOG/agent.log" | tr -d ' '; }

for p in project-3 project-1 project-4 project-5; do mkrepo "$p"; done

# --- usage -------------------------------------------------------------------
reset usage; run
check "usage rc" "$RC" "2"
has "usage names the builder box" "$STUBLOG/err" "builder box"
reset usage2; run project-3 --bogus
check "unknown flag rc" "$RC" "2"

# --- off: FEATURE_MAP_DRAFT_ENABLED defaults 0 and refuses before any spend ----
for v in unset 0 yes; do
  reset "off-$v"; if [ "$v" = unset ]; then unset FEATURE_MAP_DRAFT_ENABLED; else export FEATURE_MAP_DRAFT_ENABLED="$v"; fi
  run project-3
  check "off($v) rc" "$RC" "3"
  has "off($v) refusal names the knob" "$STUBLOG/out" "REFUSED FEATURE_MAP_DRAFT_ENABLED is off"
  check "off($v) agent not called" "$(agent_calls)" "0"
  check "off($v) no gh read" "$(wc -l < "$STUBLOG/gh.log" | tr -d ' ')" "0"
  check "off($v) nothing pushed" "$(remote_head project-3)" ""
  check "off($v) no worktree" "$(wt_count project-3)" "1"
done
reset off-all; unset FEATURE_MAP_DRAFT_ENABLED; run --all
check "off --all rc" "$RC" "3"
check "off --all agent not called" "$(agent_calls)" "0"
reset off-dry; unset FEATURE_MAP_DRAFT_ENABLED; run project-3 --dry-run
check "off --dry-run still runs (spends nothing)" "$RC" "0"
check "off --dry-run agent not called" "$(agent_calls)" "0"

# --- (a) open draft PR -------------------------------------------------------
reset a; export GH_LIST=open; run project-3
check "a rc" "$RC" "3"
has "a refusal line" "$STUBLOG/out" "REFUSED open draft PR https://github.com/o/r/pull/9"
check "a agent not called" "$(agent_calls)" "0"
check "a nothing pushed" "$(remote_head project-3)" ""
has "a gh list asked for the draft head" "$STUBLOG/gh.log" "api -i -X GET repos/example-org/project-3/pulls?state=open&head=example-org:feature-map/draft"
if grep -q 'pr list' "$STUBLOG/gh.log"; then fail "a: the draft-head read went over GraphQL (gh pr list)"; else pass; fi

# --- (b) gh list fails / unparseable ------------------------------------------
reset b; export GH_LIST=fail; run project-3
check "b rc" "$RC" "1"
has "b message" "$STUBLOG/err" "cannot prove no open draft PR"
has "b names the HTTP status (the read is not in a subshell)" "$STUBLOG/err" "HTTP 502"
check "b agent not called" "$(agent_calls)" "0"
reset bj; export GH_LIST=junk; run project-3
check "b junk rc" "$RC" "1"
check "b junk agent not called" "$(agent_calls)" "0"

# --- (b2) branch on origin without PR -------------------------------------------
reset b2
git -C "$R/project-1" push -q origin main:refs/heads/feature-map/draft
BEFORE=$(remote_head project-1)
run project-1
check "b2 rc" "$RC" "3"
has "b2 message" "$STUBLOG/out" "branch exists without PR, open or delete it"
check "b2 agent not called" "$(agent_calls)" "0"
check "b2 sha unchanged" "$(remote_head project-1)" "$BEFORE"
mkrepo project-1

# --- (c) map already on main ----------------------------------------------------
reset c
mkdir -p "$R/project-4/docs/verification-map"; echo x > "$R/project-4/docs/verification-map/x.md"
git -C "$R/project-4" add -A && git -C "$R/project-4" commit -qm map && git -C "$R/project-4" push -q origin main
git -C "$R/project-4" reset -q --hard HEAD~1   # the local ref is stale; the script must fetch
git -C "$R/project-4" update-ref refs/remotes/origin/main HEAD
run project-4
check "c rc" "$RC" "5"
has "c message" "$STUBLOG/out" "ALREADY_MAPPED project-4"
check "c agent not called" "$(agent_calls)" "0"
mkrepo project-4

# --- (d) the knob ----------------------------------------------------------------
reset d1; export KNOB_RC=2; run project-3
check "d unset rc" "$RC" "0"
has "d unset -> 15" "$STUBLOG/agent.log" "AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT=15"
has "d asked the right key" "$STUBLOG/knob.log" "feature_map.draft_max_usd"
mkrepo project-3
reset d2; export KNOB_RC=0 KNOB_VAL=7.5; run project-3
check "d 7.5 rc" "$RC" "0"
has "d 7.5" "$STUBLOG/agent.log" "AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT=7.5"
mkrepo project-3
for v in abc 0 -1 1e3 " 7" 0.0; do
  reset d3; export KNOB_RC=0 KNOB_VAL="$v"; run project-3
  check "d '$v' rc" "$RC" "2"
  check "d '$v' agent not called" "$(agent_calls)" "0"
  has "d '$v' message" "$STUBLOG/err" "bad knob feature_map.draft_max_usd"
done
reset d4; export KNOB_RC=1; run project-3
check "d unreadable rc" "$RC" "0"
has "d unreadable -> 15" "$STUBLOG/agent.log" "AGENT_CALL_BUDGET_USD_FEATURE_MAP_DRAFT=15"
has "d unreadable logged" "$STUBLOG/err" 'knob unreadable, default $15'
has "d unreadable in lane log" "$H/logs/feature-map-draft.log" 'knob unreadable, default $15'
mkrepo project-3

# --- (e) agent writes nothing -------------------------------------------------------
reset e; export AGENT_MODE=none; run project-5
check "e rc" "$RC" "4"
has "e message" "$STUBLOG/out" "DRAFT_EMPTY project-5"
check "e nothing pushed" "$(remote_head project-5)" ""
check "e worktree cleaned" "$(wt_count project-5)" "1"
check "e local branch gone" "$(git -C "$R/project-5" branch --list feature-map/draft)" ""
hasnt "e no pr create" "$STUBLOG/gh.log" "pr create"

# --- (f) happy path --------------------------------------------------------------------
reset f; run project-3
check "f rc" "$RC" "0"
has "f url printed" "$STUBLOG/out" "https://github.com/example-org/stub/pull/77"
[ -n "$(remote_head project-3)" ] && pass || fail "f branch not pushed"
has "f pr create base/head" "$STUBLOG/gh.log" "pr create -R example-org/project-3 --base main --head feature-map/draft"
has "f body freshness" "$STUBLOG/body.md" "FRESHNESS: wired"
has "f body entries" "$STUBLOG/body.md" "entries: 2"
has "f body manual-only" "$STUBLOG/body.md" "Manual-only: 1"
has "f body manual-only names" "$STUBLOG/body.md" "entries/pay.md"
has "f body cost" "$STUBLOG/body.md" 'cost: $1.25 (cap $15)'
has "f body footer" "$STUBLOG/body.md" "Generated with [Claude Code](https://claude.com/claude-code)"
check "f commit subject" "$(git --git-dir="$B/project-3.git" log -1 --format=%s feature-map/draft)" "docs(verification-map): draft map for project-3 (BH-2005)"
FILES=$(git --git-dir="$B/project-3.git" show --name-only --format= feature-map/draft | sort | tr '\n' ' ')
check "f committed files (stray.txt left out)" "$FILES" ".github/workflows/verification-map-freshness.yml docs/verification-map/README.md docs/verification-map/entries/list.md docs/verification-map/entries/pay.md "
check "f log lines" "$(grep -c PR_OPENED "$H/logs/feature-map-draft.log")" "1"
has "f log url + cost" "$H/logs/feature-map-draft.log" "$(printf 'project-3\tPR_OPENED\thttps://github.com/example-org/stub/pull/77\t1.25')"
check "f no pr merge" "$(grep -c 'pr merge' "$STUBLOG/gh.log")" "0"
has "f agent argv" "$STUBLOG/agent.log" "argv feature-map-draft project-3 stub-model 3600"
has "f agent role" "$STUBLOG/agent.log" "AGENT_CALL_ROLE=feature-map.draft"
has "f prompt has backfill body" "$STUBLOG/prompt.txt" "This repo has no \`docs/verification-map/\`"
hasnt "f prompt skips backfill preamble" "$STUBLOG/prompt.txt" "Everything below the line is the issue body"
has "f prompt has TEMPLATE lies field" "$STUBLOG/prompt.txt" "What usually lies"
# the agent runs in the APP worktree, so the drive scripts must be named by the
# harness's absolute path, with qa-drive's three positionals filled in
has "f prompt drive wrapper absolute" "$STUBLOG/prompt.txt" "$H/bin/qa-unbanned.sh project-3 <role> -- node $H/bin/qa-drive.mjs https://project-3.example "
has "f prompt drive account" "$STUBLOG/prompt.txt" "QA_TEST_USER_ID=\$($H/bin/qa-account.sh project-3 <role>)"
has "f prompt drive out-dir outside worktree" "$STUBLOG/prompt.txt" " $H/logs/feature-map-draft-project-3-"
hasnt "f prompt no relative drive path" "$STUBLOG/prompt.txt" "\`bin/qa-unbanned.sh"
check "f worktree cleaned" "$(wt_count project-3)" "1"
[ -s "$H/logs/ALERTS.log" ] && fail "f wrote an ALERTS line: $(cat "$H/logs/ALERTS.log")" || pass
# the second run must refuse on the branch it just pushed, never re-spend
reset f2; run project-3
check "f re-run refuses" "$RC" "3"
check "f re-run agent not called" "$(agent_calls)" "0"
mkrepo project-3
reset fv; export AGENT_MODE=nowf; run project-1
check "f nowf rc" "$RC" "0"
has "f nowf freshness" "$STUBLOG/body.md" "FRESHNESS: NOT wired, adopt before relying on the map"
mkrepo project-1

# --- (f) the agent stages strays itself --------------------------------------------------
reset fs; export AGENT_STAGE=1; run project-3
check "fs rc" "$RC" "0"
FILES=$(git --git-dir="$B/project-3.git" show --name-only --format= feature-map/draft | sort | tr '\n' ' ')
check "fs committed files (staged strays left out)" "$FILES" ".github/workflows/verification-map-freshness.yml docs/verification-map/README.md docs/verification-map/entries/list.md docs/verification-map/entries/pay.md "
mkrepo project-3

# --- (g) --all --dry-run ---------------------------------------------------------------
reset g; run --all --dry-run
check "g rc" "$RC" "0"
check "g order" "$(tr '\n' ' ' < "$STUBLOG/fleet.log")" "project-3 project-1 project-4 project-5 "
check "g agent not called" "$(agent_calls)" "0"
check "g per-project lines" "$(grep -c ' DRY_RUN$' "$STUBLOG/out")" "4"

has "g dry-run detail" "$STUBLOG/out" "slug=example-org/project-5 refuse-check=clear cap=15"

# --- (g2) --all with an unreadable project list ----------------------------------------
# The list is fleet-conf.sh --projects-with-board's; a failed read is not "no
# projects": rc 1, an alert, and not one project touched.
reset g2; export FLEET_LIST=fail; run --all --dry-run
check "g2 rc" "$RC" "1"
check "g2 no project read" "$(cat "$STUBLOG/fleet.log" 2>/dev/null)" ""
has "g2 alert" "$H/logs/ALERTS.log" "fleet-conf.sh --projects-with-board gave no project list"
check "g2 agent not called" "$(agent_calls)" "0"

# --- dry-run, one project ------------------------------------------------------------
reset dry; run project-3 --dry-run
check "dry rc" "$RC" "0"
has "dry prints" "$STUBLOG/out" "slug=example-org/project-3 refuse-check=clear cap=15"
check "dry agent not called" "$(agent_calls)" "0"
check "dry no worktree" "$(wt_count project-3)" "1"
check "dry no local branch" "$(git -C "$R/project-3" branch --list feature-map/draft)" ""

# --- slug unresolved -------------------------------------------------------------------
reset ghost; run ghost
check "ghost rc" "$RC" "1"
has "ghost alert" "$H/logs/ALERTS.log" "cannot resolve repo slug for ghost"
check "ghost alert count" "$(wc -l < "$H/logs/ALERTS.log" | tr -d ' ')" "1"

# --- push fails --------------------------------------------------------------------------
reset push
printf '#!/bin/sh\nexit 1\n' > "$B/project-4.git/hooks/pre-receive"; chmod +x "$B/project-4.git/hooks/pre-receive"
run project-4
check "push rc" "$RC" "1"
has "push alert names branch" "$H/logs/ALERTS.log" "feature-map/draft"
[ -e "$H/logs/feature-map-draft.log" ] && grep -q PR_OPENED "$H/logs/feature-map-draft.log" && fail "push: PR_OPENED logged" || pass
hasnt "push no pr create" "$STUBLOG/gh.log" "pr create"
check "push worktree cleaned" "$(wt_count project-4)" "1"
mkrepo project-4

# --- pr create fails ------------------------------------------------------------------
reset create; export GH_CREATE=fail; run project-4
check "create rc" "$RC" "1"
has "create alert" "$H/logs/ALERTS.log" "feature-map/draft pushed on example-org/project-4 but gh pr create failed"
[ -e "$H/logs/feature-map-draft.log" ] && grep -q PR_OPENED "$H/logs/feature-map-draft.log" && fail "create: PR_OPENED logged" || pass
mkrepo project-4

# --- agent rc 77 (hub refusal) ---------------------------------------------------------
reset a77; export AGENT_RC=77; run project-5
check "77 rc" "$RC" "1"
check "77 nothing pushed" "$(remote_head project-5)" ""
has "77 alert names rc" "$H/logs/ALERTS.log" "rc 77"
check "77 worktree cleaned" "$(wt_count project-5)" "1"

# --- no production URL: stop before the worktree and the spend -----------------------------
reset noprod; mkrepo noprod-os; run noprod-os
check "noprod rc" "$RC" "1"
check "noprod agent not called" "$(agent_calls)" "0"
has "noprod alert" "$H/logs/ALERTS.log" "no production URL for noprod-os"
check "noprod worktree" "$(wt_count noprod-os)" "1"

# --- no model route -----------------------------------------------------------------------
reset route; unset FEATURE_MAP_MODEL; run project-5
check "route rc" "$RC" "1"
check "route agent not called" "$(agent_calls)" "0"
has "route alert" "$H/logs/ALERTS.log" "no model route for role feature-map.draft"
check "route worktree" "$(wt_count project-5)" "1"

# --- cost over cap ------------------------------------------------------------------------
reset cap; export AGENT_COST=20; run project-5
check "cap rc" "$RC" "0"
has "cap alert" "$H/logs/ALERTS.log" 'feature-map draft project-5 cost $20 over cap $15'
mkrepo project-5
# an inert budget flag on a draft that came back empty still alerts
reset capempty; export AGENT_COST=20 AGENT_MODE=none; run project-5
check "capempty rc" "$RC" "4"
has "capempty alert" "$H/logs/ALERTS.log" 'feature-map draft project-5 cost $20 over cap $15'

# --- static ---------------------------------------------------------------------------------
check "no claude model literal" "$(grep -E 'claude-[a-z]' "$SCRIPT" | grep -vc 'claude.com/claude-code')" "0"
check "no force push" "$(grep -c -- '--force' "$SCRIPT" | tr -d ' ')" "$(grep -c 'worktree remove --force' "$SCRIPT")"
check "no pr merge" "$(grep -c 'pr merge' "$SCRIPT")" "0"
check "no cron line" "$(grep -rl feature-map-draft "$DIR/cron" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "feature-map-draft: $ok ok, $bad bad"
[ "$bad" = 0 ]
