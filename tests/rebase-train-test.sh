#!/bin/bash
# tests/rebase-train-test.sh — bin/rebase-train-ahead.sh, the TARGETED rebase
# train: after a merge to main, refresh exactly the open harness PRs that touch
# what just landed, and nothing else.
#
# WHAT THIS PINS AND WHY. The train pushes to branches that have money spent on
# them, so its two expensive mistakes are opposite ones: refreshing a PR it had
# no business touching (a moved head buys a re-review, and a PR the conductor is
# mid-merge on can lose its merge), and refreshing nothing at all (which is
# exactly what today's ~144 DIRTY events a day already cost). Both are SILENT in
# production — the lane logs a line either way — so every claim below is driven
# against a fake gh and a stubbed mc_rebase, and asserted on WHICH PRs the train
# asked to refresh, in what order, and what it wrote to the mark.
#
# The refresh itself is bin/lib/merge-conductor-lib.sh:mc_rebase, which has its
# own suite (tests/merge-conductor-test.sh, tests/mc-rebase-credentials-test.sh).
# Here it is a recorder: this file is about SELECTION and custody, not about how
# a branch gets merged.
#
# Run from anywhere: tests/rebase-train-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/proj
H="$T/h"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" \
         "$H/state/merge-conductor/rebase" "$T/fakebin"
cp "$DIR/bin/rebase-train-ahead.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST, which needs the contract lib beside it.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$H/fleet.conf"
: > "$H/bin/jobs-client.sh"

# --- the stub refresh helper -------------------------------------------------
# mc_rebase records (slug, project, branch, head, url) and answers with the rc
# the fixture put in $T/rc-<pr-number>, defaulting to 0 (pushed). That is the
# whole contract bin/rebase-train-ahead.sh consumes.
cat > "$H/bin/lib/merge-conductor-lib.sh" <<EOF
MC_ROWS="$H/state/merge-conductor/pr-state.tsv"
MC_RB_DIR="$H/state/merge-conductor/rebase"
MC_LOG="$H/logs/mc.log"
mc_log() { echo "\$*" >> "\$MC_LOG"; }
mc_git_auth_clear() { echo cleared >> "$T/auth-clear.txt"; }
# The conductor exports mc_rb_state (it ages a stalled job out on a timeout);
# a lib that does not is the jq-fallback path. The fixture drives BOTH, because
# "is this rebase still running" is the question that decides whether the train
# stays out of the conductor's way.
[ -f "$T/with-rb-state" ] && mc_rb_state() { jq -r '.status // ""' "\$1" 2>/dev/null; }
mc_rebase() {
  printf '%s\t%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\$4" "\$5" >> "$T/rebase-calls.tsv"
  local n; n=\${5##*/}
  local rc; rc=\$(cat "$T/rc-\$n" 2>/dev/null || echo 0)
  case "\$rc" in
    1) printf 'src/lib/pay.ts\n'; return 1 ;;
    0|5) printf 'newsha%s000000\n' "\$n"; return "\$rc" ;;
    *) return "\$rc" ;;
  esac
}
EOF

# --- the fake gh -------------------------------------------------------------
# Two shapes, both real: `gh api repos/<slug>/commits?...` (the main history, one
# sha per line because the caller passes --jq), `gh api repos/<slug>/commits/<sha>`
# (that commit's filenames, same reason), and `gh pr list --json` (a JSON array,
# jq applied by the caller).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api repos/$SLUG/commits/"*)
    s=\$(printf '%s\n' "\$*" | sed -nE 's#.*/commits/([a-z0-9]+).*#\1#p')
    cat "$T/commit-\$s.txt" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/commits?"*)
    [ -f "$T/gh-commits-broken" ] && exit 1
    cat "$T/main-history.txt" 2>/dev/null; exit 0 ;;
  # TEST-CHANGE (BH-1585): the open list is REST now — the page, then per PR
  # the single GET (mergeable_state) and pulls/N/files. Same fixture
  # (\$T/prs.json), reshaped to REST; gh-prs-broken breaks the page read.
  *"repos/$SLUG/pulls?"*)
    [ -f "$T/gh-prs-broken" ] && { printf 'HTTP/2.0 500\r\n\r\n{}\n'; exit 1; }
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --arg s "$SLUG" '[.[] | {number, html_url: .url, title: "t", body: "", draft: .isDraft,
      state: "open", merged_at: null, closed_at: null, labels: [], user: {login: "operator", type: "User"},
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
      head: {ref: .headRefName, sha: .headRefOid, repo: {full_name: \$s}},
      base: {ref: .baseRefName, repo: {full_name: \$s}}}]' "$T/prs.json" 2>/dev/null || echo '[]'
    exit 0 ;;
  *"repos/$SLUG/pulls/"*"/files"*)
    [ -f "$T/files-broken" ] && { printf 'HTTP/2.0 502\r\n\r\n{}\n'; exit 1; }
    n=\$(printf '%s\n' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --argjson n "\$n" '[.[] | select(.number == \$n) | .files[]? | {filename: .path, additions: 0, deletions: 0}]' "$T/prs.json"
    exit 0 ;;
  *"repos/$SLUG/pulls/"[0-9]*)
    n=\$(printf '%s\n' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    [ -f "$T/pr-broken-\$n" ] && { printf 'HTTP/2.0 502\r\n\r\n{}\n'; exit 1; }
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --argjson n "\$n" '.[] | select(.number == \$n) | {number, mergeable: true, mergeable_state: (.mergeStateStatus | ascii_downcase)}' "$T/prs.json"
    exit 0 ;;
  *"pr list -R $SLUG --state open --author operator"*)
    [ -f "$T/gh-prs-broken" ] && exit 1
    cat "$T/prs.json" 2>/dev/null; exit 0 ;;
  *"pr list"*)
    # EVERY author's list fails when the fixture says gh is broken: that is what
    # "unreadable" means to bin/lib/gh-pr-list.sh, which keeps the authors that
    # DID answer and only fails when none did.
    [ -f "$T/gh-prs-broken" ] && exit 1
    echo '[]'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# lane-alert records instead of paging.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh"

# --- the fixture world -------------------------------------------------------
# main has merged sha2 (touching src/lib/pay.ts) on top of sha1 (the mark).
printf 'sha2\nsha1\nsha0\n' > "$T/main-history.txt"
printf 'src/lib/pay.ts\nsrc/lib/project-2.ts\n' > "$T/commit-sha2.txt"
printf 'README.md\n' > "$T/commit-sha1.txt"

# mkpr <num> <branch> <draft> <base> <mergeState> <file>...
mkpr() {
  local n="$1" br="$2" d="$3" base="$4" ms="$5"; shift 5
  jq -nc --arg n "$n" --arg br "$br" --argjson d "$d" --arg base "$base" --arg ms "$ms" \
     --arg slug "$SLUG" --args '
    {number: ($n|tonumber), url: ("https://github.com/"+$slug+"/pull/"+$n),
     headRefName: $br, headRefOid: ("head"+$n), isDraft: $d, baseRefName: $base,
     mergeStateStatus: $ms, files: [$ARGS.positional[] | {path: .}]}' "$@"
}
setprs() { jq -sc '.' > "$T/prs.json"; }

MARK="$H/state/rebase-train/${SLUG//\//_}.last"
reset() {
  : > "$T/gh-calls.txt"; : > "$T/rebase-calls.tsv"; : > "$T/alerts.txt"
  : > "$H/logs/rebase-train-ahead.log"
  rm -f "$T"/rc-*
}
run() { bash "$H/bin/rebase-train-ahead.sh" "$@" >/dev/null 2>&1; }
called() { grep -qF "$1" "$T/rebase-calls.tsv" 2>/dev/null; }
ncalls() { wc -l < "$T/rebase-calls.tsv" 2>/dev/null | tr -d " "; }

# One PR that shares src/lib/pay.ts with the merge, one that shares nothing.
{ mkpr 41 ticket/ab-1 false main CLEAN src/lib/pay.ts src/ui/a.tsx
  mkpr 42 ticket/ab-2 false main CLEAN src/other/thing.ts; } | setprs

# ============================================================================
# 1. The kill flags stop it before it reads anything
# ============================================================================
reset
touch "$H/flags/rebase-train-off"
run
[ ! -s "$T/gh-calls.txt" ] && ok || bad "flags/rebase-train-off must stop the train before any gh call"
rm -f "$H/flags/rebase-train-off"
reset
touch "$H/flags/automerge-disabled"
run
[ ! -s "$T/gh-calls.txt" ] && ok \
  || bad "flags/automerge-disabled must stop the train too — a fleet that is not merging must not be pushing branches"
rm -f "$H/flags/automerge-disabled"

# ============================================================================
# 2. FIRST SIGHT OF A REPO PLANTS THE MARK AND REFRESHES NOTHING
#    Without this a fresh box (or a restored state dir) pushes every open PR in
#    one tick, which is the opposite of a targeted train.
# ============================================================================
reset
run
[ "$(ncalls)" = 0 ] && ok || bad "the first tick must refresh nothing (got $(ncalls) call(s))"
[ "$(cat "$MARK" 2>/dev/null)" = sha2 ] && ok || bad "the first tick must plant the mark at main's head (got '$(cat "$MARK" 2>/dev/null)')"
grep -q 'mark planted' "$H/logs/rebase-train-ahead.log" && ok || bad "the first tick must say it planted the mark"

# ============================================================================
# 3. THE SELECTION. Only the PR that touches what merged is refreshed.
# ============================================================================
reset
echo sha1 > "$MARK"
run
called "$SLUG"$'\t'"proj"$'\t'"ticket/ab-1" && ok || bad "the PR sharing src/lib/pay.ts with the merge must be refreshed"
called "ticket/ab-2" && bad "a PR sharing no file with the merge must be left alone" || ok
[ "$(ncalls)" = 1 ] && ok || bad "exactly one refresh was due (got $(ncalls))"
grep -q 'refreshed onto main' "$H/logs/rebase-train-ahead.log" && ok || bad "one log line per refresh"
grep -q 'src/lib/pay.ts' "$H/logs/rebase-train-ahead.log" && ok || bad "the refresh line must name the merged file it shares"
[ "$(cat "$MARK")" = sha2 ] && ok || bad "a completed tick must advance the mark"
[ ! -s "$T/alerts.txt" ] && ok || bad "a successful refresh must not page anybody"

# nothing new on main = no work and no gh pr list at all
reset
run
[ "$(ncalls)" = 0 ] && ok || bad "an unchanged main must refresh nothing"
grep -q 'pr list' "$T/gh-calls.txt" && bad "an unchanged main must not even list PRs" || ok

# ============================================================================
# 4. WHAT THE TRAIN REFUSES TO TOUCH
# ============================================================================
try_one() { # try_one <prs-json-producer...> -> runs one tick from sha1
  reset; echo sha1 > "$MARK"; run
}
{ mkpr 43 ticket/ab-3 true main CLEAN src/lib/pay.ts; } | setprs
try_one
[ "$(ncalls)" = 0 ] && ok || bad "a DRAFT PR must never be refreshed"

{ mkpr 44 ticket/ab-4 false release/2 CLEAN src/lib/pay.ts; } | setprs
try_one
[ "$(ncalls)" = 0 ] && ok || bad "a PR based on another branch must not be merged with main"

{ mkpr 45 ticket/ab-5 false main DIRTY src/lib/pay.ts; } | setprs
try_one
[ "$(ncalls)" = 0 ] && ok || bad "an already-DIRTY PR is the merge conductor's lane — the train must not race its lease"

# the conductor's own custody, read out of its state file and never written
{ mkpr 46 ticket/ab-6 false main CLEAN src/lib/pay.ts; } | setprs
printf '%s#46\tQUEUED\t1\t-\t-\t-\t-\thttps://x\n' "$SLUG" > "$H/state/merge-conductor/pr-state.tsv"
try_one
[ "$(ncalls)" = 0 ] && ok || bad "a PR the conductor has QUEUED must be left alone"
[ "$(wc -l < "$H/state/merge-conductor/pr-state.tsv")" = 1 ] && ok \
  || bad "the train must never write the conductor's state file"
printf '%s#46\tWAIT_CI\t1\t-\t-\t-\t-\thttps://x\n' "$SLUG" > "$H/state/merge-conductor/pr-state.tsv"
try_one
[ "$(ncalls)" = 1 ] && ok || bad "a WAIT_CI PR is not in the conductor's hands and IS refreshable (got $(ncalls))"
# a detached conductor rebase already in flight for that PR
RBJ="$H/state/merge-conductor/rebase/${SLUG//\//_}_46_abc.json"
echo '{"status":"running","pid":1,"head_sha":"abc"}' > "$RBJ"
try_one
[ "$(ncalls)" = 0 ] && ok || bad "a detached conductor rebase in flight must stand the train down"
# ...and a FINISHED one must not. mc_rebase_run leaves its job file behind with
# status `done` forever, so a check on the file's existence would exclude every
# PR the conductor ever rebased — the train would silently do less work over
# time on exactly the busiest repos.
echo '{"status":"done","pid":1,"rc":"0","head_sha":"abc"}' > "$RBJ"
try_one
[ "$(ncalls)" = 1 ] && ok \
  || bad "a FINISHED conductor rebase job file must not exclude the PR forever (got $(ncalls))"
# the same pair again through mc_rb_state, the path production takes
touch "$T/with-rb-state"
echo '{"status":"running","pid":1,"head_sha":"abc"}' > "$RBJ"
try_one
[ "$(ncalls)" = 0 ] && ok || bad "mc_rb_state=running must stand the train down too"
echo '{"status":"done","pid":1,"rc":"0","head_sha":"abc"}' > "$RBJ"
try_one
[ "$(ncalls)" = 1 ] && ok || bad "mc_rb_state=done must not exclude the PR (got $(ncalls))"
rm -f "$T/with-rb-state"
rm -f "$H/state/merge-conductor/rebase/"*.json
: > "$H/state/merge-conductor/pr-state.tsv"

# ============================================================================
# 5. THE CAP, and that a capped tick does not lie about it
# ============================================================================
{ mkpr 51 ticket/ab-a false main CLEAN src/lib/pay.ts
  mkpr 52 ticket/ab-b false main CLEAN src/lib/pay.ts
  mkpr 53 ticket/ab-c false main CLEAN src/lib/project-2.ts; } | setprs
reset; echo sha1 > "$MARK"
REBASE_TRAIN_MAX=2 run
[ "$(ncalls)" = 2 ] && ok || bad "REBASE_TRAIN_MAX=2 must stop at two pushes (got $(ncalls))"
grep -q 'REBASE_TRAIN_MAX=2' "$H/logs/rebase-train-ahead.log" && ok \
  || bad "a capped tick must say so, naming the cap"
# ...and the same number read from flags/scheduler.conf rather than the env
reset; echo sha1 > "$MARK"
printf 'REBASE_TRAIN_MAX=1\n' > "$H/flags/scheduler.conf"
run
[ "$(ncalls)" = 1 ] && ok || bad "flags/scheduler.conf must set the cap too (got $(ncalls))"
printf 'REBASE_TRAIN_MAX=banana\n' > "$H/flags/scheduler.conf"
reset; echo sha1 > "$MARK"; run
[ "$(ncalls)" = 3 ] && ok \
  || bad "an unparseable cap must fall back to the documented default of 3, not to 0 (got $(ncalls))"
rm -f "$H/flags/scheduler.conf"

# ============================================================================
# 6. OUTCOMES: only a real conflict pages, and every other rc is a log line
# ============================================================================
{ mkpr 61 ticket/ab-x false main CLEAN src/lib/pay.ts; } | setprs
reset; echo sha1 > "$MARK"; echo 1 > "$T/rc-61"; run
grep -q -- '--critical' "$T/alerts.txt" && ok || bad "a real conflict must lane-alert --critical"
grep -q "$SLUG/pull/61" "$T/alerts.txt" && ok || bad "the conflict alert must carry the PR url"
grep -q 'CONFLICTS with main' "$H/logs/rebase-train-ahead.log" && ok || bad "the conflict must be logged too"

reset; echo sha1 > "$MARK"; echo 2 > "$T/rc-61"; run
[ ! -s "$T/alerts.txt" ] && ok || bad "a RED verification gate retries next tick — it must not page"
grep -q 'gate RED' "$H/logs/rebase-train-ahead.log" && ok || bad "a red gate must still be logged"

reset; echo sha1 > "$MARK"; echo 3 > "$T/rc-61"; run
[ ! -s "$T/alerts.txt" ] && ok || bad "a lost lease must not page"
grep -q 'head moved' "$H/logs/rebase-train-ahead.log" && ok || bad "a lost lease must be logged"

# rc 5 = pushed but the approval could NOT be rebound. It counts as a push and
# it says out loud that the PR now needs a re-review — silence there is a PR
# that parks at the head-bound gate with nothing explaining why.
reset; echo sha1 > "$MARK"; echo 5 > "$T/rc-61"; run
grep -q 'rebind FAILED' "$H/logs/rebase-train-ahead.log" && ok || bad "an un-rebound push must say so"
[ ! -s "$T/alerts.txt" ] && ok || bad "the conductor re-reviews it — the train must not page for that"

# ============================================================================
# 7. FAIL-SAFE MARKS. A tick that could not see the PRs must NOT advance the
#    mark, or those merges are never compared against anything again.
# ============================================================================
reset; echo sha1 > "$MARK"
touch "$T/gh-prs-broken"; run; rm -f "$T/gh-prs-broken"
[ "$(cat "$MARK")" = sha1 ] && ok || bad "an unreadable PR list must leave the mark where it was"
grep -q 'mark NOT advanced' "$H/logs/rebase-train-ahead.log" && ok || bad "and must say so"

reset; echo sha1 > "$MARK"
touch "$T/gh-commits-broken"; run; rm -f "$T/gh-commits-broken"
[ "$(cat "$MARK")" = sha1 ] && ok || bad "an unreadable main history must leave the mark where it was"
[ "$(ncalls)" = 0 ] && ok || bad "and must refresh nothing"

# A mark that has fallen out of the window takes the whole window rather than
# doing nothing forever.
reset; echo sha-ancient > "$MARK"
{ mkpr 71 ticket/ab-y false main CLEAN src/lib/pay.ts; } | setprs
run
[ "$(ncalls)" = 1 ] && ok || bad "a mark older than the window must still refresh what the window shows (got $(ncalls))"
[ "$(cat "$MARK")" = sha2 ] && ok || bad "and must advance to main's head"

# 7b. BH-1585 review round 2 (B2). A PR whose FILES read fails must not be
#     passed over for good: the list is unavailable, nothing is refreshed on a
#     guess, and the mark stays where it was so the next tick looks again.
reset; echo sha1 > "$MARK"
{ mkpr 71 ticket/ab-y false main CLEAN src/lib/pay.ts; } | setprs
touch "$T/files-broken"; run; rm -f "$T/files-broken"
grep -q 'pulls/71/files' "$T/gh-calls.txt" && ok || bad "7b: the files read must actually have been asked"
[ "$(cat "$MARK")" = sha1 ] && ok || bad "7b: a failed files read must leave the mark where it was (got $(cat "$MARK"))"
[ "$(ncalls)" = 0 ] && ok || bad "7b: and must refresh nothing on a guess (got $(ncalls))"
# 7c. A PR whose MERGE STATE could not be read (UNVERIFIABLE) is neither
#     refreshed nor passed over: the other PR is still handled, the mark holds.
reset; echo sha1 > "$MARK"
{ mkpr 71 ticket/ab-y false main CLEAN src/lib/pay.ts
  mkpr 72 ticket/ab-z false main CLEAN src/lib/pay.ts; } | setprs
touch "$T/pr-broken-71"; run; rm -f "$T/pr-broken-71"
called "/pull/71" && bad "7c: an UNVERIFIABLE PR must not be refreshed" || ok
called "/pull/72" && ok || bad "7c: the readable PR sharing the merged file must still be refreshed"
[ "$(cat "$MARK")" = sha1 ] && ok || bad "7c: an UNVERIFIABLE row must hold the mark (got $(cat "$MARK"))"
grep -q 'unverifiable this tick' "$H/logs/rebase-train-ahead.log" && ok || bad "7c: the held mark must be said: $(tail -2 "$H/logs/rebase-train-ahead.log")"

# ============================================================================
# 8. Explicit project arguments override the registry sweep
# ============================================================================
reset; echo sha1 > "$MARK"
run nosuchproject
[ "$(ncalls)" = 0 ] && ok || bad "a project with no fleet.conf row must be skipped, not guessed at"
[ "$(cat "$MARK")" = sha1 ] && ok || bad "and must not touch another repo's mark"

# ============================================================================
# 9. DEDUPE, NEVER A QUEUE — a second tick with the lock held exits at once.
# ============================================================================
reset; echo sha1 > "$MARK"
( flock -n 8 || exit 1; run; ) 8>"$H/locks/rebase-train-ahead.lock"
[ "$(ncalls)" = 0 ] && ok || bad "a tick that finds the lock held must do nothing (and must not wait)"

echo "rebase-train-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
