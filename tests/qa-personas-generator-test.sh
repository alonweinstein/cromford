#!/bin/bash
# tests/qa-personas-generator-test.sh — bin/qa-personas.sh is the operator half
# of #528: it takes an ANSWERED questionnaire, splits it into the two files
# bin/lib/qa-personas.sh reads (qa/personas.json, qa/apps.json), renders
# docs/verification-map/personas.md from them, and opens a PR on the project
# repo. No model, no LLM call, nothing driven — a person answers the questions
# and a person reads the map before it merges.
#
# WHAT THIS SUITE DRIVES. The real script, always: every case below runs
# bin/qa-personas.sh as a command with a scratch project repo, a real bare
# `origin`, and stubbed `git`/`gh` on PATH that record their argv and then hand
# off to the real binary. Nothing here greps the script for a string except the
# two structural negatives at the end, and those are guarded so a MISSING file
# fails rather than passes (a grep over a file that is not there also counts 0).
#
# THE ANSWERS FILE IS BUILT FROM THE COMMITTED FIXTURES —
# `jq -s '.[0] + {apps: .[1].apps}'` over tests/fixtures/qa-personas/valid.json
# and apps.json — so a fixture change can never leave this suite testing a
# document tests/qa-personas-schema-test.sh no longer matches.
#
# WHERE THE REAL RUN'S OUTPUT IS READ FROM. A successful run hands the checkout
# back to the branch it found it on, so the three files are NOT lying in the
# work tree afterwards — section D reads them out of the commit on
# qa/personas-<date> with `git show`, which is the same thing the PR carries.
# D11 is the case that pins that hand-back, from a checkout parked on somebody
# else's branch (the day-two path), including that the PR's diff against main is
# exactly the three files.
#
# THE NEGATIVES CARRY THE WEIGHT. The validator gates an irreversible,
# client-visible action: a branch and a PR on somebody's repo. So every
# malformed answers file asserts three things, not one — rc 1, nothing written
# into the repo, and `gh` never invoked.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/qa-personas.sh"
W="$T/w"; mkdir -p "$W"

# ── stubs: record the argv, then run the real thing ─────────────────────────
GH_LOG="$W/gh.log"; GH_BODY="$W/pr-body.txt"; GIT_LOG="$W/git.log"; GH_ENV="$W/gh-env.txt"
export GH_LOG GH_BODY GIT_LOG GH_ENV
: > "$GH_LOG"; : > "$GIT_LOG"
# The credential the script hands gh is a property under test, so the ambient
# one is cleared: whatever this box exports must not decide the answer.
unset GH_TOKEN
STUB="$W/bin"; mkdir -p "$STUB"
GITBIN=$(command -v git)
cat > "$STUB/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$GIT_LOG"
exec "$GITBIN" "\$@"
EOF
cat > "$STUB/gh" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
printf '%s\n' "${GH_TOKEN:-none}" > "$GH_ENV"
prev=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && [ -f "$a" ] && cat "$a" > "$GH_BODY"
  prev="$a"
done
if [ "${GH_FAIL:-0}" = "1" ]; then
  echo "gh: pr create failed" >&2
  exit 1
fi
echo "https://github.com/acme/demo/pull/42"
EOS
chmod +x "$STUB/git" "$STUB/gh"

# ── a real bare origin and a real project checkout ──────────────────────────
ORIGIN="$W/origin.git"
git init -q --bare "$ORIGIN"
R="$W/repo"
git init -q "$R"
git -C "$R" symbolic-ref HEAD refs/heads/main
printf 'demo\n' > "$R/README.md"
git -C "$R" add README.md
git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
git -C "$R" remote add origin "$ORIGIN"
git -C "$R" push -q -u origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
MAIN_SHA_BEFORE=$(git -C "$ORIGIN" rev-parse main)

# a second, untouched clone for the adversarial negatives (they must write
# nothing, so one clean checkout serves all of them)
RN="$W/repo-neg"
git clone -q "$ORIGIN" "$RN"

mkdir -p "$W/plain"          # a directory that is not a git work tree

ANS="$W/answers.json"
jq -s '.[0] + {apps: .[1].apps}' \
  "$DIR/tests/fixtures/qa-personas/valid.json" \
  "$DIR/tests/fixtures/qa-personas/apps.json" > "$ANS"

OUTF="$W/out.txt"; ERRF="$W/err.txt"
# HARNESS points at an EMPTY scratch tree by default, so bin/lib/gh-app-auth.sh
# answers "this box does not mint App tokens" without running a process. No run
# in this suite may reach the live harness or the network; the armed case sets
# HARNESS_OVR to a scratch harness with a stubbed minter.
mkdir -p "$W/harness"
run() { # run <args...> — stdout to $OUTF, stderr to $ERRF, rc returned
  : > "$OUTF"; : > "$ERRF"
  PATH="$STUB:$PATH" REPOS_ROOT="$W/repos" HARNESS="${HARNESS_OVR:-$W/harness}" \
    "$SCRIPT" "$@" >"$OUTF" 2>"$ERRF"
}
errlines() { wc -l < "$ERRF" | tr -d ' '; }
has() { grep -qF -- "$2" "$1"; }

# ── A — arguments and refusals ──────────────────────────────────────────────
bash -n "$SCRIPT" 2>"$W/syn.txt" && ok || bad "A1: bash -n on the script: $(cat "$W/syn.txt")"
[ -x "$SCRIPT" ] && ok || bad "A1: bin/qa-personas.sh must be executable"

run; RC=$?
[ "$RC" = 2 ] && ok || bad "A1: no arguments must be rc 2 (got $RC)"
has "$ERRF" "usage:" && ok || bad "A1: no arguments must print usage on stderr (got: $(cat "$ERRF"))"
[ ! -s "$OUTF" ] && ok || bad "A1: usage belongs on stderr, not stdout (got: $(cat "$OUTF"))"

run demo; RC=$?
[ "$RC" = 2 ] && ok || bad "A1: a project with no mode must be rc 2 (got $RC)"

run demo --from "$ANS" --wat; RC=$?
[ "$RC" = 2 ] && ok || bad "A1: an unknown flag must be rc 2 (got $RC)"
has "$ERRF" "usage:" && ok || bad "A1: an unknown flag must print usage (got: $(cat "$ERRF"))"

# A2 the merged fixtures are a document the contract accepts
run demo --from "$ANS" --repo "$R" --dry-run; RC=$?
[ "$RC" = 0 ] && ok || bad "A2: the merged fixtures must validate (rc $RC, stderr: $(cat "$ERRF"))"

# A3 a dirty work tree is refused, and the operator's own dirt survives
printf 'local edit\n' >> "$R/README.md"
run demo --from "$ANS" --repo "$R"; RC=$?
[ "$RC" = 1 ] && ok || bad "A3: a dirty work tree must be rc 1 (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "A3: want exactly one stderr line, got: $(cat "$ERRF")"
[ ! -e "$R/qa" ] && ok || bad "A3: nothing may be written into a dirty repo"
[ ! -s "$GH_LOG" ] && ok || bad "A3: gh must not be called on a refusal"
[ -n "$(git -C "$R" status --porcelain)" ] && ok || bad "A3: the operator's own uncommitted work was destroyed"
git -C "$R" checkout -q -- README.md

# A4 a --repo that is not a git work tree
run demo --from "$ANS" --repo "$W/plain"; RC=$?
[ "$RC" = 1 ] && ok || bad "A4: a non-repo --repo must be rc 1 (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "A4: want exactly one stderr line, got: $(cat "$ERRF")"
[ ! -e "$W/plain/qa" ] && ok || bad "A4: nothing may be written into a plain directory"
[ ! -s "$GH_LOG" ] && ok || bad "A4: gh must not be called on a refusal"

# A5 a missing answers file
run demo --from "$W/nope.json" --repo "$R"; RC=$?
[ "$RC" = 1 ] && ok || bad "A5: a missing answers file must be rc 1 (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "A5: want exactly one stderr line, got: $(cat "$ERRF")"
[ ! -e "$R/qa" ] && ok || bad "A5: nothing may be written when the answers file is missing"

# ── C — dry run and interactive ─────────────────────────────────────────────
: > "$GIT_LOG"
run demo --from "$ANS" --repo "$R" --dry-run; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: --dry-run must exit 0 (got $RC, stderr: $(cat "$ERRF"))"
for P in qa/personas.json qa/apps.json docs/verification-map/personas.md; do
  has "$OUTF" "$P" && ok || bad "C1: --dry-run stdout must name $P"
done
has "$OUTF" '# QA personas' && ok || bad "C1: --dry-run must print the rendered map entry, not just its path"
[ ! -e "$R/qa" ] && ok || bad "C1: --dry-run must write nothing into the repo"
[ -z "$(git -C "$R" status --porcelain)" ] && ok || bad "C1: --dry-run left the repo dirty"
[ "$(git -C "$R" rev-parse --abbrev-ref HEAD)" = main ] && ok || bad "C1: --dry-run must not leave a branch behind"
[ ! -s "$GH_LOG" ] && ok || bad "C1: --dry-run must never call gh"
[ ! -s "$GIT_LOG" ] && ok || bad "C1: --dry-run must run no git command at all (got: $(cat "$GIT_LOG"))"

run demo --interactive; RC=$?
[ "$RC" = 2 ] && ok || bad "C2: --interactive must exit 2 on a headless box (got $RC)"
has "$OUTF" '1. Who are the personas?' && ok || bad "C2: --interactive must print the questionnaire (got: $(head -3 "$OUTF"))"
has "$OUTF" '"sign_in": "clerk-ticket"' && ok || bad "C2: --interactive must print the answers-file shape"
[ ! -e "$R/qa" ] && ok || bad "C2: --interactive must write nothing"

# ── D — the real run ────────────────────────────────────────────────────────
: > "$GIT_LOG"
run demo --from "$ANS" --repo "$R"; RC=$?
[ "$RC" = 0 ] && ok || bad "D: the real run must exit 0 (got $RC, stderr: $(cat "$ERRF"))"

# D2 the branch. Read from refs, not from HEAD: a successful run hands the
# checkout back to the branch it found it on, so HEAD is main again here (D11
# is what pins that). The branch the PR is for is the one ref it created.
BR=$(git -C "$R" for-each-ref --format='%(refname:short)' 'refs/heads/qa/personas-*')
[ "$(printf '%s\n' "$BR" | grep -c .)" = 1 ] \
  && ok || bad "D2: the run must leave exactly one qa/personas-* branch, got: $(printf '%s ' $BR)"
[[ "$BR" =~ ^qa/personas-[0-9]{8}$ ]] && ok || bad "D2: branch is '$BR', want qa/personas-<YYYYMMDD>"

# D1 the three files are COMMITTED on that branch, and the split is exactly the
# documented one (read with `git show`, so this proves the commit, not a file
# left lying in a work tree).
for F in qa/personas.json qa/apps.json docs/verification-map/personas.md; do
  git -C "$R" cat-file -e "$BR:$F" 2>/dev/null && ok || bad "D1: $F was not committed on $BR"
done
[ "$(jq -S 'del(.apps)' "$ANS")" = "$(git -C "$R" show "$BR:qa/personas.json" 2>/dev/null | jq -S . 2>/dev/null)" ] \
  && ok || bad "D1: qa/personas.json must be the answers minus .apps"
[ "$(jq -S '{version: 1, apps: .apps}' "$ANS")" = "$(git -C "$R" show "$BR:qa/apps.json" 2>/dev/null | jq -S . 2>/dev/null)" ] \
  && ok || bad "D1: qa/apps.json must be {version:1, apps:<answers.apps>}"
[ "$(git -C "$R" diff --name-only main.."$BR" | sort | tr '\n' ' ')" \
  = "docs/verification-map/personas.md qa/apps.json qa/personas.json " ] \
  && ok || bad "D1: the branch must carry exactly the three files against main, got: $(git -C "$R" diff --name-only main.."$BR" | tr '\n' ' ')"

# D3 the commit footer
LASTLINE=$(git -C "$R" log -1 --format=%B "$BR" | grep -v '^[[:space:]]*$' | tail -1)
[[ "$LASTLINE" =~ ^Co-Authored-By:\ Claude.*\<noreply@anthropic\.com\>$ ]] \
  && ok || bad "D3: last commit line is '$LASTLINE', want the Claude Code co-author trailer"

# D4 gh was asked for a PR against main, and its URL is the only thing on stdout
has "$GH_LOG" 'pr create' && ok || bad "D4: gh pr create was never invoked (log: $(cat "$GH_LOG"))"
has "$GH_LOG" '--base main' && ok || bad "D4: the PR must target --base main (log: $(cat "$GH_LOG"))"
has "$GH_LOG" "--head $BR" && ok || bad "D4: the PR must be opened for $BR (log: $(cat "$GH_LOG"))"
[ "$(cat "$OUTF")" = "https://github.com/acme/demo/pull/42" ] \
  && ok || bad "D4: stdout must carry the PR URL gh returned, and nothing else (got: $(cat "$OUTF"))"

# D5 the body states the rule and carries the footer. BH-5204: the rule is no
# longer "an operator reads it" — the orchestrator reads it, and the floor is
# the validator's out-of-bounds refusal.
has "$GH_BODY" 'The orchestrator reads `docs/verification-map/personas.md` before the merge' \
  && has "$GH_BODY" 'the validator refuses one with an empty out-of-bounds list' \
  && ok || bad "D5: the PR body must state the confirmation rule"
has "$GH_BODY" '🤖 Generated with [Claude Code]' \
  && ok || bad "D5: the PR body must end with the standard attribution footer"

# D6 iron guardrail 1: main is untouched, nothing was merged
[ "$(git -C "$ORIGIN" rev-parse main)" = "$MAIN_SHA_BEFORE" ] \
  && ok || bad "D6: origin/main moved — this lane must never push to main"
git -C "$ORIGIN" rev-parse --verify -q "refs/heads/$BR" >/dev/null \
  && ok || bad "D6: the feature branch was never pushed to origin"
grep -q 'pr merge' "$GH_LOG" && bad "D6: the lane invoked gh pr merge" || ok
grep -E '^push .*(^| )main($| )' "$GIT_LOG" >/dev/null \
  && bad "D6: a git push targeted main: $(grep '^push' "$GIT_LOG")" || ok

# ── B — the rendered map entry (read from the real run's output) ────────────
# The run's output is the committed blob on $BR — the work tree is back on main.
MAP="$W/personas.md"
git -C "$R" show "$BR:docs/verification-map/personas.md" > "$MAP" 2>/dev/null \
  && ok || bad "B: the rendered map entry is not readable on $BR"
for NEED in '# QA personas' 'What it is' 'How a user reaches it' 'Manual-only'; do
  has "$MAP" "$NEED" && ok || bad "B: the map entry must carry '$NEED'"
done
TABLES=$(grep -c '^| flow | route |' "$MAP")
[ "$TABLES" = 2 ] && ok || bad "B: want one flows table per persona (2), found $TABLES"
for F in users dashboard new-scan; do
  grep -q "^| $F | " "$MAP" && ok || bad "B: no table row for flow '$F'"
done
NEWSCAN=$(grep -m1 '^| new-scan | ' "$MAP")
case "$NEWSCAN" in
  *'| no |'*) ok ;;
  *) bad "B: the write flow must render production safe = no (got: $NEWSCAN)" ;;
esac
case "$NEWSCAN" in
  *'delete the queued scan named qa-smoke'*) ok ;;
  *) bad "B: the write flow's row must carry its cleanup text (got: $NEWSCAN)" ;;
esac
has "$MAP" '/billing' && ok || bad "B: the owner persona's out_of_bounds must be listed"
has "$MAP" 'apps/admin/**' && ok || bad "B: each persona's apps must render with their globs"

# B2 `seed` is a RENDERED column, not a schema field: schema v1 defines no seed
# key, so a flow that carries one must render it and must not be refused for it.
jq '.personas[0].flows[0].seed = "one user with a pending invite"' "$ANS" > "$W/seed.json"
run demo --from "$W/seed.json" --repo "$R" --dry-run; RC=$?
[ "$RC" = 0 ] && ok || bad "B2: a seed string must pass through, not be validated away (rc $RC: $(cat "$ERRF"))"
grep -q '^| users | .* | one user with a pending invite | ' "$OUTF" \
  && ok || bad "B2: a flow's seed must render in the seed column"

# D7 a second run the same day refuses, and origin gains no second ref.
# No checkout -q main here on purpose: the successful run above is required to
# have handed the checkout back itself (D11), so the day-two run starts from
# main because the script put it there, not because this suite did.
REFS_BEFORE=$(git -C "$ORIGIN" for-each-ref --format='%(refname)' | sort)
[ "$(git -C "$R" rev-parse --abbrev-ref HEAD)" = main ] \
  && ok || bad "D7: a successful run must leave the checkout on main, found $(git -C "$R" rev-parse --abbrev-ref HEAD)"
[ -z "$(git -C "$R" status --porcelain)" ] \
  && ok || bad "D7: a successful run left the checkout dirty: $(git -C "$R" status --porcelain)"
: > "$GH_LOG"
run demo --from "$ANS" --repo "$R"; RC=$?
[ "$RC" = 1 ] && ok || bad "D7: a same-day re-run must refuse (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "D7: want exactly one stderr line, got: $(cat "$ERRF")"
has "$ERRF" "$BR" && ok || bad "D7: the refusal must name the branch that already exists (got: $(cat "$ERRF"))"
[ ! -s "$GH_LOG" ] && ok || bad "D7: a refused re-run must not call gh"
[ "$(git -C "$ORIGIN" for-each-ref --format='%(refname)' | sort)" = "$REFS_BEFORE" ] \
  && ok || bad "D7: a refused re-run pushed something to origin"

# a push that fails must stop before gh: nothing half-made
RP="$W/repo-nopush"
git clone -q "$ORIGIN" "$RP"
git -C "$RP" remote set-url origin "$W/not-a-remote"
: > "$GH_LOG"
run demo --from "$ANS" --repo "$RP"; RC=$?
[ "$RC" = 1 ] && ok || bad "D8: a failed push must be rc 1 (got $RC)"
[ ! -s "$GH_LOG" ] && ok || bad "D8: a PR must never be opened for a branch that is not pushed"
[ "$(errlines)" = 1 ] && ok || bad "D8: want exactly one stderr line, got: $(cat "$ERRF")"
# The branch and the commit DO survive a failed push. That is what
# docs/verification-map/qa-personas.md is required to say, so the line the
# operator sees has to say it too — and the checkout still comes back.
git -C "$RP" rev-parse --verify -q "refs/heads/$BR" >/dev/null \
  && ok || bad "D8: the local branch is what the refusal tells the operator to delete, so it must exist"
[ "$(git -C "$RP" rev-parse --abbrev-ref HEAD)" = main ] \
  && ok || bad "D8: a failed push must still hand the checkout back, found $(git -C "$RP" rev-parse --abbrev-ref HEAD)"
[ -z "$(git -C "$RP" status --porcelain)" ] \
  && ok || bad "D8: a failed push left loose files in the work tree: $(git -C "$RP" status --porcelain)"
has "$ERRF" 'stay in the checkout' \
  && ok || bad "D8: the refusal must say the branch and commit stay behind (got: $(cat "$ERRF"))"

# gh failing after a good push: honest line, named branch, never rc 0.
# Its own bare origin, so the push is judged on its own merits.
RG="$W/repo-ghfail"
git clone -q "$ORIGIN" "$RG"
git init -q --bare "$W/ghfail.git"
git -C "$RG" remote set-url origin "$W/ghfail.git"
git -C "$RG" push -q -u origin main
: > "$GH_LOG"
export GH_FAIL=1
run demo --from "$ANS" --repo "$RG"; RC=$?
unset GH_FAIL
[ "$RC" = 1 ] && ok || bad "D9: a failed gh pr create must be rc 1, never 0 (got $RC)"
has "$ERRF" 'qa/personas-' && ok || bad "D9: the failure must name the pushed branch so it can be opened by hand"
[ ! -s "$OUTF" ] && ok || bad "D9: no URL may be printed when gh returned none (got: $(cat "$OUTF"))"
[ "$(errlines)" = 1 ] && ok || bad "D9: want exactly one stderr line, got: $(cat "$ERRF")"
git -C "$RG" rev-parse --verify -q "refs/heads/$BR" >/dev/null \
  && ok || bad "D9: the pushed branch must still be in the checkout to open by hand"
[ "$(git -C "$RG" rev-parse --abbrev-ref HEAD)" = main ] \
  && ok || bad "D9: a failed gh must still hand the checkout back, found $(git -C "$RG" rev-parse --abbrev-ref HEAD)"
has "$ERRF" 'before re-running' \
  && ok || bad "D9: the refusal must tell the operator what to do with the branch it left (got: $(cat "$ERRF"))"

# D10 the credential. On a box that mints App tokens the push and the PR spend a
# repo-scoped installation token, not the fleet's shared PAT (the ratchet in
# tests/gh-app-ratchet-test.sh is what makes this mandatory rather than nice).
# An unarmed box must behave exactly as it did before — no token, no new fork.
[ "$(cat "$GH_ENV" 2>/dev/null)" = none ] \
  && ok || bad "D10: an unarmed box must leave GH_TOKEN alone (got: $(cat "$GH_ENV" 2>/dev/null))"
HA="$W/harness-armed"; mkdir -p "$HA/bin" "$HA/env" "$HA/flags"
: > "$HA/env/github-app.env"
printf '#!/bin/bash\necho ghs-scratch-installation-token\n' > "$HA/bin/gh-token.sh"
chmod +x "$HA/bin/gh-token.sh"
RA="$W/repo-armed"
git clone -q "$ORIGIN" "$RA"
git init -q --bare "$W/armed.git"
git -C "$RA" remote set-url origin "$W/armed.git"
git -C "$RA" push -q -u origin main
: > "$GH_LOG"; : > "$GH_ENV"
HARNESS_OVR="$HA" run demo --from "$ANS" --repo "$RA"; RC=$?
[ "$RC" = 0 ] && ok || bad "D10: the armed run must still open the PR (rc $RC: $(cat "$ERRF"))"
[ "$(cat "$GH_ENV" 2>/dev/null)" = ghs-scratch-installation-token ] \
  && ok || bad "D10: gh must run on the App installation token, not the fleet PAT (got: $(cat "$GH_ENV" 2>/dev/null))"

# D11 the day-two path. The checkout is parked on somebody else's branch, which
# is exactly where a previous lane — or yesterday's run of THIS lane — leaves
# it. The branch has to be cut from main anyway, so the PR carries the three
# files and nothing that was already sitting on the checkout, and the operator
# gets their branch back.
RD="$W/repo-parked"
git clone -q "$ORIGIN" "$RD"
git init -q --bare "$W/parked.git"
git -C "$RD" remote set-url origin "$W/parked.git"
git -C "$RD" push -q -u origin main
git -C "$RD" checkout -qb someones-ticket
printf 'unrelated\n' > "$RD/OLDSTUFF.md"
git -C "$RD" add OLDSTUFF.md
git -C "$RD" -c user.email=t@t -c user.name=t commit -qm 'an unrelated commit sitting on the checkout'
: > "$GH_LOG"
run demo --from "$ANS" --repo "$RD"; RC=$?
[ "$RC" = 0 ] && ok || bad "D11: a run from a parked checkout must still open the PR (rc $RC: $(cat "$ERRF"))"
BRD=$(git -C "$RD" for-each-ref --format='%(refname:short)' 'refs/heads/qa/personas-*')
[ "$(printf '%s\n' "$BRD" | grep -c .)" = 1 ] \
  && ok || bad "D11: want exactly one qa/personas-* branch, got: $(printf '%s ' $BRD)"
[ "$(git -C "$RD" diff --name-only main.."$BRD" | sort | tr '\n' ' ')" \
  = "docs/verification-map/personas.md qa/apps.json qa/personas.json " ] \
  && ok || bad "D11: the PR must carry exactly the three files against main, got: $(git -C "$RD" diff --name-only main.."$BRD" | tr '\n' ' ')"
grep -q 'unrelated commit' <<<"$(git -C "$RD" log --format=%s main.."$BRD")" \
  && bad "D11: the PR carries a commit from the branch the checkout was parked on" || ok
[ "$(git -C "$RD" log --oneline main.."$BRD" | grep -c .)" = 1 ] \
  && ok || bad "D11: the branch must be one commit ahead of main, got: $(git -C "$RD" log --oneline main.."$BRD" | tr '\n' ' ')"
[ "$(git -C "$RD" rev-parse --abbrev-ref HEAD)" = someones-ticket ] \
  && ok || bad "D11: the checkout must be handed back to the branch it was on, found $(git -C "$RD" rev-parse --abbrev-ref HEAD)"
[ -z "$(git -C "$RD" status --porcelain)" ] \
  && ok || bad "D11: the run left the operator's checkout dirty: $(git -C "$RD" status --porcelain)"
[ ! -e "$RD/qa" ] \
  && ok || bad "D11: the generated files belong to the branch, not to the branch the operator was on"
[ -f "$RD/OLDSTUFF.md" ] && ok || bad "D11: the operator's own file did not come back with their branch"

# D12 a checkout with no local main is refused rather than branched from
# whatever is there: the PR targets main, so cutting from master (or from a
# ticket branch) would open a PR whose diff is that other branch.
RM="$W/repo-nomain"
git init -q "$RM"
git -C "$RM" symbolic-ref HEAD refs/heads/master
printf 'nomain\n' > "$RM/README.md"
git -C "$RM" add README.md
git -C "$RM" -c user.email=t@t -c user.name=t commit -qm init
git -C "$RM" remote add origin "$W/nomain.git"
: > "$GH_LOG"
run demo --from "$ANS" --repo "$RM"; RC=$?
[ "$RC" = 1 ] && ok || bad "D12: a checkout with no local main must be rc 1 (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "D12: want exactly one stderr line, got: $(cat "$ERRF")"
# The wording has to be the real reason: without its own check the script dies
# on `checkout -b <branch> main` and blames an existing branch instead.
has "$ERRF" 'no local main branch' \
  && ok || bad "D12: the refusal must name the missing main, not blame something else (got: $(cat "$ERRF"))"
[ ! -e "$RM/qa" ] && ok || bad "D12: nothing may be written when there is no main to cut from"
[ ! -s "$GH_LOG" ] && ok || bad "D12: gh must not be called on a refusal"
[ "$(git -C "$RM" rev-parse --abbrev-ref HEAD)" = master ] \
  && ok || bad "D12: the refusal must leave the checkout where it was"
[ -z "$(git -C "$RM" for-each-ref --format='%(refname)' 'refs/heads/qa/personas-*')" ] \
  && ok || bad "D12: no branch may be created when there is no main to cut from"

# D13 the other way the same defect arrives: main itself carrying a commit
# origin does not have. Cutting from it would put that commit in the PR, so it
# is refused too — no fetch, just the origin/main the checkout already knows.
# Its own bare origin, so the push would SUCCEED here: without the guard this
# case opens a PR carrying the local-only commit, which is the thing being
# refused, rather than failing on a rejected push for an unrelated reason.
RU="$W/repo-unpushed"
git clone -q "$ORIGIN" "$RU"
git init -q --bare "$W/unpushed.git"
git -C "$RU" remote set-url origin "$W/unpushed.git"
git -C "$RU" push -q -u origin main
printf 'local only\n' >> "$RU/README.md"
git -C "$RU" add README.md
git -C "$RU" -c user.email=t@t -c user.name=t commit -qm 'a commit only this checkout has'
: > "$GH_LOG"
run demo --from "$ANS" --repo "$RU"; RC=$?
[ "$RC" = 1 ] && ok || bad "D13: a local main ahead of origin/main must be rc 1 (got $RC)"
[ "$(errlines)" = 1 ] && ok || bad "D13: want exactly one stderr line, got: $(cat "$ERRF")"
has "$ERRF" 'origin/main does not have' \
  && ok || bad "D13: the refusal must say why (got: $(cat "$ERRF"))"
[ ! -e "$RU/qa" ] && ok || bad "D13: nothing may be written on that refusal"
[ ! -s "$GH_LOG" ] && ok || bad "D13: gh must not be called on a refusal"
[ -z "$(git -C "$RU" for-each-ref --format='%(refname)' 'refs/heads/qa/personas-*')" ] \
  && ok || bad "D13: no branch may be cut from a main origin has not seen"
[ "$(git -C "$RU" rev-parse --abbrev-ref HEAD)" = main ] \
  && ok || bad "D13: the refusal must leave the checkout where it was"
[ -n "$(git -C "$RU" log --oneline origin/main..main)" ] \
  && ok || bad "D13: the operator's own unpushed commit must survive the refusal"

# ── E — adversarial negatives: none of these may produce a PR ───────────────
neg_common() { # neg_common <label> <rc>
  local label="$1" rc="$2" n
  [ "$rc" = 1 ] || { bad "$label: rc $rc, want 1 (stderr: $(cat "$ERRF"))"; return 1; }
  n=$(errlines)
  [ "$n" = 1 ] || { bad "$label: $n stderr lines, want exactly 1: $(cat "$ERRF")"; return 1; }
  [ ! -e "$RN/qa" ] || { bad "$label: wrote into the repo on a refusal"; return 1; }
  [ ! -s "$GH_LOG" ] || { bad "$label: called gh on a refusal: $(cat "$GH_LOG")"; return 1; }
  [ -z "$(git -C "$RN" status --porcelain)" ] || { bad "$label: left the repo dirty"; return 1; }
  return 0
}
from_lib() { # from_lib <label> — the refusal must be the contract's own line
  case "$(cat "$ERRF")" in
    "personas.json: "*|"apps.json: "*) ok ;;
    *) bad "$1: the schema refusal must come from bin/lib/qa-personas.sh (got: $(cat "$ERRF"))" ;;
  esac
}
neg_jq() { # neg_jq <label> <jq filter>
  : > "$GH_LOG"
  jq "$2" "$ANS" > "$W/bad.json"
  run demo --from "$W/bad.json" --repo "$RN"; local rc=$?
  neg_common "$1" "$rc" || return
  from_lib "$1"
}
neg_raw() { # neg_raw <label> <raw file contents>
  : > "$GH_LOG"
  printf '%s' "$2" > "$W/bad.json"
  run demo --from "$W/bad.json" --repo "$RN"; local rc=$?
  neg_common "$1" "$rc" || return
  from_lib "$1"
}

neg_jq 'E: production_safe as a string' '.personas[0].flows[0].production_safe = "true"'
neg_jq 'E: a write flow with no cleanup'  'del(.personas[1].flows[1].cleanup)'
neg_jq 'E: an absolute route'             '.personas[0].flows[0].route = "https://app.example.com/x"'
neg_jq 'E: an unsupported sign_in'        '.personas[0].sign_in = "password"'
neg_jq 'E: a duplicate persona id'        '.personas[1].id = "admin"'
neg_jq 'E: no personas at all'            '.personas = []'
neg_jq 'E: a persona naming an unknown app' '.personas[0].apps = ["nope"]'
neg_jq 'E: .apps as an array'             '.apps = []'
neg_jq 'E: no .apps at all'               'del(.apps)'
neg_raw 'E: an answers file that is not JSON' 'personas: all of them'
neg_raw 'E: an empty answers file'        ''

# structural negatives — guarded, so a missing file FAILS instead of counting 0
if [ -f "$SCRIPT" ]; then
  [ "$(grep -c 'agent-call' "$SCRIPT")" = 0 ] \
    && ok || bad "E: this slice calls no model — agent-call.sh must not appear in the generator"
  [ "$(grep -c 'pr merge' "$SCRIPT")" = 0 ] \
    && ok || bad "E: iron guardrail 1 — the generator must never run gh pr merge"
  # The schema has ONE owner. Every refusal above already came back with the
  # lib's own wording; this pins the wiring that makes that true.
  grep -q 'qa_personas_validate' "$SCRIPT" \
    && ok || bad "E: the generator must validate through bin/lib/qa-personas.sh, never with rules of its own"
else
  bad "E: bin/qa-personas.sh does not exist, so the structural negatives proved nothing"
fi

# ── F — the skill carries the questionnaire the script prints ──────────────
# The operator reads the skill; the script prints the same questions. Two
# copies of a questionnaire drift, so the parity is asserted rather than hoped
# for: every line of the script's questionnaire block must appear in SKILL.md.
SKILL="$DIR/skills/qa-personas/SKILL.md"
if [ -f "$SKILL" ]; then
  run demo --interactive
  QBLOCK="$W/questions.txt"
  awk '/^1\. Who are the personas/{f=1} f&&/^$/{exit} f{print}' "$OUTF" > "$QBLOCK"
  QN=$(grep -cE '^[0-9]+\. ' "$QBLOCK")
  [ "$QN" -ge 6 ] && ok || bad "F: the questionnaire must ask its six questions, found $QN"
  MISSING=""
  while IFS= read -r L; do
    grep -qF -- "$L" "$SKILL" || MISSING="$MISSING[$L]"
  done < "$QBLOCK"
  [ -z "$MISSING" ] && ok || bad "F: the skill and the script disagree on the questionnaire: $MISSING"
  for NEED in '"sign_in": "clerk-ticket"' 'production_safe' \
              'The orchestrator reads' 'out_of_bounds' \
              '--from <answers.json>'; do
    has "$SKILL" "$NEED" && ok || bad "F: skills/qa-personas/SKILL.md must carry '$NEED'"
  done
else
  bad "F: skills/qa-personas/SKILL.md does not exist"
fi

echo "qa-personas-generator: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
