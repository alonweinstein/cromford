#!/bin/bash
# tests/lane-fence-test.sh — the act-time fence for the NON-claude lanes, driven
# for real (SDLC item 8). Sibling of tests/iron-law-guard-test.sh, which drives
# the claude half; this one drives the PATH shims, the pre-push hook and the
# wiring in bin/agent-call.sh.
#
# WHY THIS SHAPE. Same reason as the hook's test: a fence whose only proof is a
# grep is the shape of guard this repo keeps finding inert. So every case here
# EXECUTES the shim — with fake binaries on PATH whose only job is to record
# that they ran — and reads the verdict, the reason, the finding line, the
# fallback ledger file and the ALERTS line back off disk. The hook half runs
# against a real git repo pushing to a real (local, offline) bare remote.
#
# The five things that must stay true:
#   1. the five irreversible families are DENIED before the real binary runs,
#      including through the wrappers (npx/npm) that reach prisma and vercel
#   2. everything else reaches the real binary unchanged, argv intact
#   3. an unfenced session, LANE_FENCE=0, and a BROKEN fence all run the command
#      — the last one loudly, once per day, never silently
#   4. the pre-push hook refuses main even when the shim never saw the command,
#      and does not eat the repo's own hooks
#   5. bin/agent-call.sh actually puts all of that in front of codex/gemini/grok,
#      and never in front of claude (which has the PreToolUse hook instead)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin" "$T/realbin" "$T/fakebin" "$T/repo"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/iron-law-guard.sh" "$DIR/bin/lane-fence.sh" "$T/bin/"
cp -r "$DIR/bin/lane-shims" "$T/bin/"
chmod +x "$T/bin"/*.sh "$T/bin/lane-shims"/* 2>/dev/null

# The "real" binaries the shims are standing in front of. Each one records the
# argv it was handed, so a passthrough is proven by the tool having RUN, not by
# an exit code that could mean anything.
for b in gh vercel prisma psql npx npm pnpm; do
  cat > "$T/realbin/$b" <<EOF
#!/bin/bash
printf '%s %s\n' "$b" "\$*" >> "$T/ran.log"
EOF
  chmod +x "$T/realbin/$b"
done
: > "$T/ran.log"

SHIMS="$T/bin/lane-shims"
# One fenced execute lane, the way agent-call.sh composes it: the shim dir on
# the front of PATH, the lane marker in the environment.
fence() { # fence [env=val ...] -- <command...>  -> prints the exit code
  local -a e=()
  while [ "${1:-}" != -- ]; do e+=("$1"); shift; done
  shift
  ( env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=TK-7 \
        PATH="$SHIMS:$T/realbin:$PATH" "${e[@]}" "$@" ) >/dev/null 2>"$T/err"
  echo $?
}

# --- 1. the five families are denied, before the real binary runs ------------
while IFS='|' read -r RULE CMD; do
  [ -n "$CMD" ] || continue
  : > "$T/ran.log"
  RC=$(fence -- bash -c "$CMD")
  [ "$RC" != 0 ] || { bad "NOT DENIED (rc=0): $CMD"; continue; }
  ok
  grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
    || bad "denied but gave the model no reason: $CMD"
  grep -q "family=actguard-$RULE" "$T/logs/findings.log" 2>/dev/null \
    || bad "denied but filed no $RULE finding: $CMD"
  [ -s "$T/ran.log" ] && bad "DENIED BUT RAN ANYWAY: $CMD -> $(cat "$T/ran.log")"
done <<'CASES'
pr-merge|gh pr merge 123 --squash
pr-merge|gh pr merge 12
push-main|git push origin main
push-main|git push --force origin HEAD:main
prisma-live-db|npx prisma db push
prisma-live-db|pnpm exec prisma migrate deploy
prod-db-write|psql "$DATABASE_URL" -c "UPDATE users SET tier='pro'"
vercel-deploy|vercel --prod
vercel-deploy|vercel promote dpl_x --scope project-12
CASES

# The finding says WHICH fence caught it. Same family as the hook's (one iron
# law reached for on two runners is one recurrence), different mechanism.
grep -q "PATH-shim(" "$T/logs/findings.log" \
  && ok || bad "the finding does not name the PATH shim as the mechanism"
grep -q "ticket=TK-7" "$T/logs/findings.log" \
  && ok || bad "the finding does not carry the ticket"

# The attempt is also a FACT in the per-build fallback ledger the DB row is
# rendered from (state/lane-fence/<job or ticket>.log).
LEDGER="$T/state/lane-fence/TK-7.log"
[ -s "$LEDGER" ] && ok || bad "no fallback ledger line was written for the blocked attempts"
awk -F'\t' 'NF>=5 && $3=="deny" {n++} END {exit !(n>=9)}' "$LEDGER" \
  && ok || bad "the ledger lines are not the tab-separated shape the rollup counts: $(head -1 "$LEDGER")"

# ...and the DB row that file is the fallback FOR. A stand-in jobs-client
# records what the fence asked the worker to write, so the artifact kind, the
# count and the verbs are read back rather than assumed. Fail-open by
# construction: every case above ran with no jobs-client on the box at all.
cat > "$T/bin/jobs-client.sh" <<EOF
#!/bin/bash
job_artifact_put() { printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T/artifact.log"; }
EOF
: > "$T/artifact.log"
RC=$(fence JOB_ID=build-testproj-TK-7-1 -- gh pr merge 77)
[ "$RC" != 0 ] && ok || bad "the deny path changed when a jobs client was present (rc=$RC)"
grep -q '^lane_fence|1 blocked by the lane fence (gh)|' "$T/artifact.log" \
  && ok || bad "no lane_fence artifact row was written: $(cat "$T/artifact.log")"
cut -d'|' -f3- "$T/artifact.log" | jq -e '.blocked==1 and .mode=="deny" and .lane=="execute" and (.verbs|index("gh")) and (.fallback_file|test("lane-fence"))' >/dev/null 2>&1 \
  && ok || bad "the artifact detail is not the JSON the console reads: $(cut -d'|' -f3- "$T/artifact.log")"
rm -f "$T/bin/jobs-client.sh"

# A refused command must not LEAK what it was carrying. The hook only ever sees
# the unexpanded "$DATABASE_URL"; a shim gets argv AFTER the shell expanded it,
# and both sinks are durable — logs/findings.log is what bin/rule-miner.sh
# bundles into a GitHub PR body. So the password goes and the HOST stays, and
# the deny itself proves the classifier still had what it decides on.
: > "$T/ran.log"
RC=$(fence -- psql 'postgres://app:S3CRETpw@db.supabase.co:5432/prod' -c 'UPDATE users SET tier=1')
[ "$RC" != 0 ] && [ ! -s "$T/ran.log" ] \
  && ok || bad "an EXPANDED prod connection string was not denied (rc=$RC)"
LEAKED=$(grep -rl 'S3CRETpw' "$T/logs" "$T/state/lane-fence" 2>/dev/null | tr '\n' ' ')
[ -z "$LEAKED" ] && ok || bad "the refusal wrote the password into: $LEAKED"
grep -q 'db.supabase.co' "$T/logs/findings.log" \
  && ok || bad "redaction ate the host too — the finding no longer says which database"
# ...and redaction must not blunt the classifier: --prod is not a password flag.
: > "$T/ran.log"; RC=$(fence -- vercel --prod)
[ "$RC" != 0 ] && [ ! -s "$T/ran.log" ] \
  && ok || bad "\`vercel --prod\` survived the fence — redaction mangled the flag (rc=$RC)"

# --- 2. ordinary work reaches the real binary, argv intact ------------------
: > "$T/logs/findings.log"
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  : > "$T/ran.log"
  RC=$(fence -- bash -c "$CMD")
  [ "$RC" = 0 ] || { bad "OVER-BLOCKED (rc=$RC): $CMD :: $(head -1 "$T/err")"; continue; }
  [ -s "$T/ran.log" ] || { bad "allowed but the real binary never ran: $CMD"; continue; }
  ok
done <<'ALLOWED'
gh pr create --title "act-time fence" --body-file /tmp/b
gh pr view 12 --json state
npm run build
npx prisma generate
vercel env pull .env.local --scope project-12
psql "$DATABASE_URL" -c "SELECT count(*) FROM users"
gh issue comment 4 --body "pr merge is the merge lane's job, not ours"
ALLOWED
[ -s "$T/logs/findings.log" ] \
  && bad "an allowed command filed a finding: $(head -1 "$T/logs/findings.log")" || ok

# Argv survives the shim exactly — a fence that mangles arguments is a fence
# that breaks builds in ways nobody will attribute to it.
: > "$T/ran.log"; RC=$(fence -- gh pr view 12 --json 'state,headRefOid' --jq '.state')
[ "$RC" = 0 ] && [ "$(cat "$T/ran.log")" = "gh pr view 12 --json state,headRefOid --jq .state" ] \
  && ok || bad "the shim changed the argv it passed through: $(cat "$T/ran.log")"

# The REAL git — no fake behind this one — still works through its shim. Every
# build session runs dozens of these, and a fence that broke `git` would look
# like a broken repo rather than like a fence.
RC=$(fence -- git --version)
[ "$RC" = 0 ] && [ ! -s "$T/err" ] \
  && ok || bad "the git shim broke an ordinary git call (rc=$RC): $(head -1 "$T/err")"

# A binary that exists nowhere behind the shim is a plain 127, not a crash and
# never a loop back into the shim.
RC=$(fence -- mongosh --eval 'db.x.find()')
[ "$RC" = 127 ] && ok || bad "a shim with no real binary behind it exited $RC, not 127"

# --- 3. the switches, and a broken fence ------------------------------------
# No lane marker: the orchestrator, box-chat and the merge lanes keep authority.
# -u HARNESS_LANE, not merely "unset here": this suite is itself run BY a build
# lane often enough that inheriting the marker would make this case pass for the
# wrong reason.
: > "$T/ran.log"
( env -u HARNESS_LANE HARNESS="$T" PATH="$SHIMS:$T/realbin:$PATH" gh pr merge 1 ) >/dev/null 2>&1
grep -q '^gh pr merge 1$' "$T/ran.log" \
  && ok || bad "a session with no HARNESS_LANE (the orchestrator) was fenced"

: > "$T/ran.log"; RC=$(fence LANE_FENCE=0 -- gh pr merge 1)
[ "$RC" = 0 ] && [ -s "$T/ran.log" ] && ok || bad "LANE_FENCE=0 did not disarm the fence (rc=$RC)"

# 0 is the ONLY off switch. bin/agent-call.sh and the pre-push hook both read
# anything-but-0 as armed, so a shim that also honoured `off` would hand out a
# half-disarmed box: inert shims on PATH, a pre-push that still refuses main.
: > "$T/ran.log"; : > "$T/logs/ALERTS.log"; rm -f "$T/flags"/*
RC=$(fence LANE_FENCE=off -- gh pr merge 1)
[ "$RC" != 0 ] && [ ! -s "$T/ran.log" ] \
  && ok || bad "LANE_FENCE=off disarmed the shim while the pre-push hook stayed armed (rc=$RC)"

# PATH already carrying the shim dir (a fenced session composing PATH again)
# must stay a working fence, not a box where every shimmed command exits 127.
: > "$T/ran.log"
( env HARNESS="$T" HARNESS_LANE=execute PATH="$SHIMS:$SHIMS:$T/realbin:$PATH" \
      gh pr view 3 --json state ) >/dev/null 2>"$T/err"
RC=$?
[ "$RC" = 0 ] && [ -s "$T/ran.log" ] \
  && ok || bad "a doubled shim dir on PATH broke an ordinary command (rc=$RC): $(head -1 "$T/err")"
: > "$T/ran.log"
( env HARNESS="$T" HARNESS_LANE=execute PATH="$SHIMS:$SHIMS:$T/realbin:$PATH" \
      gh pr merge 1 ) >/dev/null 2>&1
[ ! -s "$T/ran.log" ] && ok || bad "a doubled shim dir on PATH also stopped denying"

: > "$T/ran.log"; : > "$T/logs/findings.log"
RC=$(fence LANE_FENCE=warn -- gh pr merge 1)
[ "$RC" = 0 ] && [ -s "$T/ran.log" ] && ok || bad "LANE_FENCE=warn did not run the command (rc=$RC)"
grep -q "was RUN ANYWAY" "$T/err" && ok || bad "warn mode ran the command without saying so"
grep -q "family=actguard-pr-merge" "$T/logs/findings.log" \
  && ok || bad "warn mode ran the command AND filed nothing — the whole point of warn-first"

# A typo'd flag is still a fence (same rule as OVERLAP_DEFER_ENFORCE).
: > "$T/ran.log"; : > "$T/logs/ALERTS.log"; rm -f "$T/flags"/*
RC=$(fence LANE_FENCE=yes -- gh pr merge 1)
[ "$RC" != 0 ] && [ ! -s "$T/ran.log" ] && ok || bad "LANE_FENCE=yes was read as 'off' (rc=$RC)"
grep -q "LANE_FENCE=yes is not a value this fence knows" "$T/logs/ALERTS.log" \
  && ok || bad "an unrecognized LANE_FENCE value was treated as ON silently"

# A fence that cannot run its classifier denies NOTHING and says so — the same
# trade the hook makes, for the same reason. Once per day, not once per command:
# this shim also stands in front of npm and git.
: > "$T/logs/ALERTS.log"; : > "$T/ran.log"; rm -f "$T/flags"/*
mv "$T/bin/iron-law-guard.sh" "$T/bin/iron-law-guard.off"
RC=$(fence -- gh pr merge 1)
[ "$RC" = 0 ] && [ -s "$T/ran.log" ] \
  && ok || bad "a fence with no classifier bricked the command instead of failing open (rc=$RC)"
grep -q "act-time lane fence INERT" "$T/logs/ALERTS.log" \
  && ok || bad "a degraded fence failed open SILENTLY — the one failure mode this must not have"
RC=$(fence -- gh pr merge 2)
[ "$(grep -c "lane fence INERT" "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the inert-fence alert repeats per command; ALERTS.log would drown"
mv "$T/bin/iron-law-guard.off" "$T/bin/iron-law-guard.sh"

# --- 4. the pre-push hook: what the PATH shim can never see -----------------
git init -q -b main "$T/repo" 2>/dev/null
git -C "$T/repo" config user.email t@example.com
git -C "$T/repo" config user.name tester
git -C "$T/repo" commit -q --allow-empty -m one
git init -q --bare "$T/remote.git" 2>/dev/null
git -C "$T/repo" remote add origin "$T/remote.git"
# The repo's OWN pre-push, which the fence must not silently switch off.
cat > "$T/repo/.git/hooks/pre-push" <<EOF
#!/bin/bash
cat > "$T/orig-hook-stdin"
echo ran > "$T/orig-hook-ran"
EOF
printf '#!/bin/bash\necho ran > "%s"\n' "$T/orig-precommit-ran" > "$T/repo/.git/hooks/pre-commit"
chmod +x "$T/repo/.git/hooks/pre-push" "$T/repo/.git/hooks/pre-commit"

mapfile -t HE < <(env HARNESS="$T" bash "$T/bin/lane-fence.sh" hooks-env "$T/repo" 2>/dev/null)
[ "${#HE[@]}" = 3 ] && [ "${HE[1]}" = "GIT_CONFIG_KEY_0=core.hooksPath" ] \
  && ok || bad "hooks-env did not print the three GIT_CONFIG_* assignments: ${HE[*]:-none}"
HOOKS="${HE[2]#GIT_CONFIG_VALUE_0=}"
[ -x "$HOOKS/pre-push" ] && ok || bad "hooks-env installed no pre-push hook in $HOOKS"
[ -x "$HOOKS/pre-commit" ] \
  && ok || bad "the fence's hooks dir drops the repo's own pre-commit — husky would go dark"

push() { # push <ref> [env=val ...]
  local ref="$1"; shift
  ( env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj HARNESS_TICKET=TK-7 \
        "${HE[@]}" "$@" git -C "$T/repo" push origin "$ref" ) >/dev/null 2>"$T/err"
  echo $?
}
rm -f "$T/orig-hook-ran"
RC=$(push main)
[ "$RC" != 0 ] && ok || bad "the pre-push hook let main through"
grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
  && ok || bad "the refused push gave no reason"
git -C "$T/remote.git" rev-parse --verify -q main >/dev/null \
  && bad "main landed on the remote anyway" || ok

# BH-2741: a feature branch is not the agent's to push either — the harness
# pushes it after the session, through bin/lib/hold-push.sh.
git -C "$T/repo" checkout -q -b feat && git -C "$T/repo" commit -q --allow-empty -m two
RC=$(push feat)
[ "$RC" != 0 ] && grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
  && ok || bad "an execute-lane feature-branch push was let through (rc=$RC)"
git -C "$T/remote.git" rev-parse --verify -q feat >/dev/null \
  && bad "the refused feature branch landed on the remote anyway" || ok
# A lane the guard does not fence (lead-review keeps its push) pushes, and the
# repo's own hook still runs, with the refs it expects on stdin.
rm -f "$T/orig-hook-ran" "$T/orig-hook-stdin"
RC=$(push feat HARNESS_LANE=lead-review)
[ "$RC" = 0 ] && ok || bad "an unfenced lane's feature-branch push was blocked (rc=$RC): $(head -3 "$T/err")"
[ -f "$T/orig-hook-ran" ] \
  && ok || bad "the repo's own pre-push hook never ran — the fence ate it"
grep -q "refs/heads/feat" "$T/orig-hook-stdin" 2>/dev/null \
  && ok || bad "the chained hook got no refs on stdin: $(cat "$T/orig-hook-stdin" 2>/dev/null)"

# warn mode lets it through here too, and says so.
RC=$(push main LANE_FENCE=warn)
[ "$RC" = 0 ] && grep -q "was NOT stopped" "$T/err" \
  && ok || bad "LANE_FENCE=warn did not let the push through with a warning (rc=$RC)"

# The hooks dir OUTLIVES the hooks it was built from (husky regenerates
# .husky/_ on install; a branch may carry no husky at all). A forwarder left
# pointing at a deleted hook exits 127, and git reads 127 as "hook failed" — so
# the fence would brick commits it has no opinion about. Two belts:
#   a) a re-install rebuilds the directory rather than adding to it
rm -f "$T/repo/.git/hooks/pre-commit"
mapfile -t HE2 < <(env HARNESS="$T" bash "$T/bin/lane-fence.sh" hooks-env "$T/repo" 2>/dev/null)
[ "${HE2[2]}" = "${HE[2]}" ] \
  && ok || bad "a re-install moved the hooks dir: ${HE2[2]:-none}"
[ ! -e "$HOOKS/pre-commit" ] \
  && ok || bad "the forwarder for a hook the repo no longer has survived the re-install"
#   b) and a forwarder that goes stale between installs exits 0, not 127
printf '#!/bin/bash\nexit 0\n' > "$T/repo/.git/hooks/pre-commit"
chmod +x "$T/repo/.git/hooks/pre-commit"
env HARNESS="$T" bash "$T/bin/lane-fence.sh" hooks-env "$T/repo" >/dev/null 2>&1
rm -f "$T/repo/.git/hooks/pre-commit"
"$HOOKS/pre-commit" >/dev/null 2>&1
[ "$?" = 0 ] \
  && ok || bad "a stale forwarder exits nonzero — git would refuse the commit and blame nothing"
# The repo is left as section 5 expects it: a real pre-push, no stale entries.
env HARNESS="$T" bash "$T/bin/lane-fence.sh" hooks-env "$T/repo" >/dev/null 2>&1

# --- 5. the wiring: what actually reaches the codex/gemini/grok processes ----
# bin/agent-call.sh is run for real with a fake codex that dumps its environment.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
env > "$T_SENTINEL_DIR/env.txt"
printf 'ok\n' > "$(while [ "$#" -gt 0 ]; do [ "$1" = --output-last-message ] && { echo "$2"; break; }; shift; done)"
EOF
# gemini takes no --output-last-message, and it has to EXIT 0: a nonzero fake
# would send agent-call.sh down the failover ladder to claude, whose env would
# then be the one this test reads back.
printf '#!/bin/bash\nenv > "$T_SENTINEL_DIR/env.txt"\necho ok\n' > "$T/fakebin/gemini"
printf '#!/bin/bash\nenv > "$T_SENTINEL_DIR/env.txt"\necho ok\n' > "$T/fakebin/claude"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/beat.sh" "$T/bin/codex-usage.sh"
# runner_ready() reads these off disk before it will use a lane at all; without
# them agent-call.sh fails over to claude and every assertion below would be
# testing the wrong branch.
mkdir -p "$T/.codex" "$T/.gemini"
echo '{}' > "$T/.codex/auth.json"; echo '{}' > "$T/.gemini/oauth_creds.json"

call() { # call <stage> <runner> [env assignments...]
  local stage="$1" runner="$2"; shift 2
  rm -f "$T/env.txt"
  ( cd "$T/repo" || exit 1
    export T_SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env "RUNNER_$(echo "$stage" | tr '[:lower:]' '[:upper:]')=$runner" "$@" \
      bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-opus-5 600 "$T/out.txt" "hi" ) >/dev/null 2>&1
}
lane_path() { grep -m1 '^PATH=' "$T/env.txt" 2>/dev/null; }

call execute codex
case "$(lane_path)" in
  PATH=$T/bin/lane-shims:*) ok ;;
  *) bad "the codex execute lane did not get the shim dir at the FRONT of PATH: $(lane_path)" ;;
esac
grep -qx "HARNESS_LANE=execute" "$T/env.txt" \
  && ok || bad "the lane marker never reached codex, so every shim is inert there"
grep -qx "GIT_CONFIG_KEY_0=core.hooksPath" "$T/env.txt" \
  && ok || bad "the codex lane got no pre-push hook pointer"
grep -q "^GIT_CONFIG_VALUE_0=$T/state/lane-fence-hooks-" "$T/env.txt" \
  && ok || bad "the hooks dir handed to codex is not the one this box installed"

# Prepended ONCE even when the caller's PATH already carries it (a fenced
# session that itself runs agent-call.sh, a resumed lane inheriting the env).
call execute codex "PATH=$T/bin/lane-shims:$T/fakebin:$PATH"
N=$(lane_path | awk -v d="$T/bin/lane-shims" '{n=gsub(d ":","");print n}')
[ "$N" = 1 ] \
  && ok || bad "the shim dir landed on PATH $N times — every shimmed command would 127: $(lane_path)"

call execute gemini
case "$(lane_path)" in
  PATH=$T/bin/lane-shims:*) ok ;;
  *) bad "the gemini lane is unfenced: $(lane_path)" ;;
esac

# The claude lane is fenced by the PreToolUse hook instead — no shim dir, or the
# same rule would be enforced twice with two different failure modes.
call execute claude
case "$(lane_path)" in
  PATH=$T/bin/lane-shims:*) bad "the claude lane got the PATH shims as well as its hook" ;;
  *) ok ;;
esac

# chat keeps its authority, and the kill switch reaches the process.
call chat codex
case "$(lane_path)" in
  PATH=$T/bin/lane-shims:*) bad "the chat lane was fenced" ;;
  *) ok ;;
esac
call execute codex LANE_FENCE=0
case "$(lane_path)" in
  PATH=$T/bin/lane-shims:*) bad "LANE_FENCE=0 still put the shims on PATH" ;;
  *) ok ;;
esac

# A box with no fence deployed runs the lane and SAYS so.
: > "$T/logs/ALERTS.log"; mv "$T/bin/lane-shims" "$T/bin/lane-shims.off"
call execute codex
grep -q "act-time lane fence MISSING" "$T/logs/ALERTS.log" \
  && ok || bad "a box with no fence ran a codex build lane silently unguarded"
[ -s "$T/env.txt" ] \
  && ok || bad "a missing fence stopped the stage from running at all — it must degrade, not brick"
mv "$T/bin/lane-shims.off" "$T/bin/lane-shims"

echo "lane-fence: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
