#!/bin/bash
# tests/batch-resolve-trains.bh-1269-test.sh — BH-1269: what bin/batch-resolve.sh
# learned from a day of merge trains run by hand (2026-09-21, ~52 merges).
#
# Six behaviours, each driven against a REAL bare origin and the SHIPPED lane —
# no paraphrase of its logic anywhere in this file:
#
#   T1  a train forms with ONE member (BATCH_TRAIN_MIN, default 1)
#   T2  a candidate whose OWN CI is red and whose head is behind the base is
#       REBASED (purely) and its verdict CARRIED by +/- line identity; a second
#       red on the rebased head PARKS it instead of rebasing again
#   T3  a merged fix-main-red PR whose merge-ref run is green removes
#       flags/main-red-<repo> AND its D1 pause row in the same tick
#   T4  the train-skip file is honoured LIVE, per candidate
#   T5  a member whose own CI concludes failure AFTER the train formed pre-empts
#       it: the train closes itself and re-forms without that member, and no
#       binary split is paid
#   T6  every train writes merge_trains rows, and the client verbs that carry
#       them build the body the worker route accepts and read the rows back
#   T7  the fleet lane gate stops the lane before it looks at anything
#   T8  the mc_batch_should_spawn the CONDUCTOR resolves — not the module's text
#       — honours BATCH_TRAIN_MIN, so a lone PR is actually spawned for
#
# WHY REAL GIT. Every claim in T2 is about what `git rebase` and `git diff`
# actually do to a patch — whether the rebased head carries the same added and
# removed lines. A stubbed git would only prove the shell around them is spelled
# right, which was never the part in doubt. `gh` IS stubbed, always: nothing
# here may touch GitHub.
#
# Run from anywhere: tests/batch-resolve-trains.bh-1269-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
if [ -n "${BATCH_TEST_KEEP:-}" ]; then echo "fixture kept at $T"; else trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts" "$S/tests"

printf 'tests/static-guards.txt merge=union\n' > "$S/.gitattributes"
printf 'guard-base\n' > "$S/tests/static-guards.txt"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
printf 'export const base = 1\n' > "$S/src/base.ts"

# The stub regenerate command. It rewrites the registry deterministically from
# the tree — EXCEPT when $T/regen-oscillate exists, where it writes a different
# answer on every run: a generator with no fixed point, which is the one shape a
# rebase must refuse to push.
cat > "$S/scripts/regen.sh" <<REGEN
#!/bin/sh
if [ -f "$T/regen-oscillate" ]; then
  echo tick >> "$T/osc-count.txt"
  printf '{"n":%s}\\n' "\$(grep -c . "$T/osc-count.txt")" > scripts/worker-import-set.json
  exit 0
fi
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/ci-stub.sh"; chmod +x "$S/ci-stub.sh"

cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `bash scripts/regen.sh` |
ARCH
cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

```bash
bash ci-stub.sh
```
CLAUDEMD

git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$S" push -q origin main
BASE=$(git -C "$S" rev-parse HEAD)

# mkregistry <branch> <marker> — a sibling that rewrites the REGENERABLE file,
# so it conflicts with a base branch that also rewrote it. That conflict is what
# makes a train worth building at all (CONFLICTS_SEEN).
mkregistry() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const %s = 1\n' "$2" > "$S/src/feature-$2.ts"
  printf '{"imports":["src/base.ts","src/feature-%s.ts"]}\n' "$2" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$2" >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
# mkplain <branch> <marker> — a sibling that touches ONE new source file and
# nothing else, so a rebase onto an advanced base is a pure replay and the
# patch's own added lines cannot change. T2 turns on that.
mkplain() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const %s = 1\nexport const %s2 = 2\n' "$2" "$2" > "$S/src/plain-$2.ts"
  git -C "$S" add -A && git -C "$S" commit -qm "$2" >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mkregistry ticket/tk-11 a)
HEAD_B=$(mkplain    ticket/tk-12 b)
HEAD_C=$(mkplain    ticket/tk-13 c)

# The base moves on: a new source file of its own AND a rewrite of the
# regenerable registry. #101 therefore conflicts with main in a file the repo
# declares generated (allowed); #102 and #103 are clean against it and behind it.
git -C "$S" checkout -q main
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null && git -C "$S" push -q origin main

# ── the harness tree ─────────────────────────────────────────────────────────
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" \
         "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" \
   "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
# BH-1606: a train opens only as the App (never the lead PAT), so this box can mint one.
cp "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/"; : > "$H/env/github-app.env"
# TEST-CHANGE (BH-1630): the lane now reads the token's expiry (`gh-token.sh
# --expires-at`) before it pushes a union, so the stub answers one, far ahead.
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "'"$T"'/alerts.txt"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# The jobs client: a ledger file, a merge-train file, and a flag store shaped
# like the real flag helper — write-through, the file AND the row in ONE call,
# which is the whole of T3's second half. It is a STUB and this suite proves
# nothing about the helper itself; the jobs-client suites own that.
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
flag_active() { [ -f "$T/h/flags/\$1" ]; }
flag_set() {
  case "\$2" in off|0|false) rm -f "$T/h/flags/\$1"; printf '%s off %s\n' "\$1" "\${3:-}" >> "$T/flagrows.txt" ;;
                *)            touch "$T/h/flags/\$1"; printf '%s on %s\n'  "\$1" "\${3:-}" >> "$T/flagrows.txt" ;; esac
}
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
EOF

git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# ── the fake gh ──────────────────────────────────────────────────────────────
# Every call is logged. The REST arms answer in bin/lib/gh-rest.sh's wire shape:
# a status line, a blank line, then the body.
# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
hold_fixture_libs "$DIR" "$H" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
sha=\$(printf '%s\n' "\$*" | grep -oE 'commits/[0-9a-f]+' | head -1 | sed 's#commits/##')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"--json headRefOid"*)
    cat "$T/head-\$num.txt" 2>/dev/null && exit 0
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  # THIS PR'S OWN CHECK RUNS. Green unless a scenario writes a fixture for the
  # exact sha, which is how "a job concluded failure" is armed and disarmed.
  *"-i -X GET repos/$SLUG/commits/"*)
    if [ -f "$T/checks-\$sha.json" ]; then B=\$(cat "$T/checks-\$sha.json")
    else B='{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}'; fi
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$B"; exit 0 ;;
  *"-i -X POST repos/$SLUG/actions/runs/"*"/cancel"*)
    printf '%s\n' "\$*" | grep -oE 'runs/[0-9]+' | sed 's#runs/##' >> "$T/cancelled.txt"
    printf 'HTTP/2.0 202 Accepted\nx-stub: 1\n\n{}\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/runs.json" 2>/dev/null || echo '{"workflow_runs":[{"id":4242,"name":"Harness CI","run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}')"
    exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/closedprs.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  *"api -i -X PATCH repos/$SLUG/pulls/"*)
    printf 'closed\n' > "$T/pr-state-\$num.txt"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    case "\$(cat "$T/pr-state-\$num.txt" 2>/dev/null)" in
      closed) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n' ;;
      merged) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":"2026-09-21T00:00:00Z"}\n' ;;
      *)      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
    esac
    exit 0 ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'; exit 0 ;;
  # The train's own PR is closed with a plain (non -i) PATCH by the pre-emption.
  *"-X PATCH repos/$SLUG/pulls/"*)
    printf '%s\n' "\$num" >> "$T/train-closed.txt"; echo '{"state":"closed"}'; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*)
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$T/train-body.txt"
      prev="\$a"
    done
    cat "$T/train-url.txt" 2>/dev/null || echo "https://github.com/$SLUG/pull/900"
    exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/9"*)
    cat "$T/train-state.json" 2>/dev/null || echo '{}'; exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

mkpr() { # mkpr <num> <branch> <head> <mergeState> <created>
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg m "$4" --arg c "$5" --arg slug "$SLUG" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:$m, mergeable:"MERGEABLE", state:"OPEN", createdAt:$c, labels:[]}'
}
mkrec() { # mkrec <issue> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026092100$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 11 101 "$HEAD_A"
mkrec 12 102 "$HEAD_B"
mkrec 13 103 "$HEAD_C"
REC13="$H/builds/$PROJ-TK-13-202609210013"

# A check-runs fixture with one concluded failure, for a given sha.
arm_red() { printf '{"check_runs":[{"name":"replay-evals","status":"completed","conclusion":"failure"}]}' > "$T/checks-$1.json"; }
# ...and the five VACUOUS shapes: a head with nothing concluded badly on it that
# has nevertheless proved nothing at all. Each one lifted the fleet-wide freeze
# before this round.
arm_checks() { printf '%s' "$2" > "$T/checks-$1.json"; }
VAC_INPROGRESS='{"check_runs":[{"name":"Harness CI / shard 0","status":"in_progress","conclusion":null}]}'
VAC_QUEUED='{"check_runs":[{"name":"Harness CI / shard 0","status":"queued","conclusion":null}]}'
VAC_NONE='{"check_runs":[]}'
VAC_IGNORED='{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral"},{"name":"Publish share mirror","status":"completed","conclusion":"success"}]}'
VAC_SKIPPED='{"check_runs":[{"name":"Harness CI / shard 0","status":"completed","conclusion":"skipped"},{"name":"Summary","status":"completed","conclusion":"neutral"}]}' 

# TRAIN_PARALLEL=1 — NOT a weakening, a statement of which contract this suite
# is about. BH-1270 made the lane open one train per group of candidates whose
# planned-file sets do not intersect, with TRAIN_PARALLEL=2 as the default, and
# it defines TRAIN_PARALLEL=1 as "BH-1269, byte for byte". Several fixtures here
# (#101 and #102 touch different files) are disjoint under that partition, so at
# the new default they form TWO trains and the single-train assertions below —
# which are about trains of one, the late-red pre-emption and the D1 rows, none
# of which is a claim about how many trains a tick opens — would be reading the
# wrong scenario. Every assertion in this file is unchanged; the knob says which
# behaviour they describe. tests/batch-resolve-trains.bh-1270-test.sh T6 is what
# proves the two are the same thing, at the lane and at the planner.
run() { TRAIN_PARALLEL=1 bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"; : > "$T/trains.tsv"
  : > "$T/flagrows.txt"; : > "$T/train-closed.txt"; : > "$T/ledger.tsv"; : > "$T/cancelled.txt"
  rm -f "$T/train-body.txt" "$T/train-state.json" "$T"/checks-*.json "$T"/pr-state-*.txt \
        "$T/closedprs.json" "$H/flags/"* 2>/dev/null
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor/batch-hold"
  rm -f "$H/state/merge-conductor/attempts.txt"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
}
batch_branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/'; }
nbatch() { batch_branches | grep -c . ; }
remote_head() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }

# ============================================================================
# T1. A TRAIN FORMS WITH ONE MEMBER
#     #101 is the only candidate and it conflicts with main in the file the repo
#     declares generated — which before BH-1269 was "fewer than 2 candidates"
#     and a wait for a partner that never came.
# ============================================================================
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok || bad "T1 a lone approved, conflicting PR must ride a train of one (branches: $(nbatch))"
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" && ok || bad "T1 the train body must name #101"
grep -qi 'train of 1 ' "$LOG" && ok || bad "T1 the lane must say it built a train of one: $(grep -i 'train of' "$LOG" | head -1)"

# and the knob still buys the old behaviour
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
BATCH_TRAIN_MIN=2 run
[ "$(nbatch)" = 0 ] && ok || bad "T1 BATCH_TRAIN_MIN=2 must restore the wait-for-a-partner behaviour"

# ============================================================================
# T2. AN INHERITED RED IS REBASED, NEVER RERUN — AND THE VERDICT IS CARRIED
# ============================================================================
reset
mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-21T03:00:00Z | jq -sc '.' > "$T/prs.json"
arm_red "$HEAD_C"
BEFORE=$(remote_head ticket/tk-13)
run
AFTER=$(remote_head ticket/tk-13)
[ "$AFTER" != "$BEFORE" ] && ok || bad "T2 an own-CI-red candidate behind the base must be REBASED, not left alone"
MAINSHA=$(remote_head main)
[ "$(git -C "$T/repos/$PROJ" rev-list --count "$AFTER..$MAINSHA" 2>/dev/null)" = 0 ] && ok \
  || bad "T2 the rebased head must sit on top of the base branch"
[ "$(head -1 "$REC13/reviewed-sha")" = "$AFTER" ] && ok \
  || bad "T2 the head-bound verdict must be CARRIED to the rebased head (reviewed-sha=$(head -1 "$REC13/reviewed-sha"), head=$AFTER)"
grep -qi 'carried' "$LOG" && ok || bad "T2 the carry must be said out loud"
grep -q "rerun-failed-jobs" "$T/gh-calls.txt" && bad "T2 an inherited red must never be rerun — the run is pinned to the stale merge ref" || ok
[ "$(nbatch)" = 0 ] && ok || bad "T2 the rebased PR must not also ride this pass's train"

# the SECOND red, on the rebased head, parks it: the head is no longer behind
# the base, so there is no rebase left to buy.
: > "$T/gh-calls.txt"; : > "$LOG"
arm_red "$AFTER"
mkpr 103 ticket/tk-13 "$AFTER" CLEAN 2026-09-21T03:00:00Z | jq -sc '.' > "$T/prs.json"
run
[ "$(remote_head ticket/tk-13)" = "$AFTER" ] && ok || bad "T2 a second red must not buy a second rebase"
grep -qxF "103 $AFTER" "$STATE/own-red.txt" 2>/dev/null && ok \
  || bad "T2 the twice-red PR must be PARKED at its head: $(cat "$STATE/own-red.txt" 2>/dev/null)"
grep -qi 'PARKED' "$LOG" && ok || bad "T2 the park must be said out loud"
# and a park is sticky at that head: the next pass costs no GitHub read at all
: > "$T/gh-calls.txt"
run
grep -q "commits/$AFTER/check-runs" "$T/gh-calls.txt" && bad "T2 a parked head must not be re-read every pass" || ok

# A REBASE THAT CHANGES THE PATCH IS THROWN AWAY, NOT PUSHED. #104's commit is
# already on the base under a different commit id, so rebasing it drops the
# commit and the patch's own added lines disappear — a re-review is genuinely
# owed and nothing may move the head.
reset
git -C "$S" checkout -q -b ticket/tk-14 "$BASE"
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
git -C "$S" add -A && git -C "$S" commit -qm "the same content main already has" >/dev/null
git -C "$S" push -q origin ticket/tk-14
HEAD_D=$(git -C "$S" rev-parse HEAD)
mkrec 14 104 "$HEAD_D"
mkpr 104 ticket/tk-14 "$HEAD_D" CLEAN 2026-09-21T04:00:00Z | jq -sc '.' > "$T/prs.json"
arm_red "$HEAD_D"
run
[ "$(remote_head ticket/tk-14)" = "$HEAD_D" ] && ok \
  || bad "T2 a rebase that does not carry must push NOTHING"
[ "$(head -1 "$H/builds/$PROJ-TK-14-202609210014/reviewed-sha")" = "$HEAD_D" ] && ok \
  || bad "T2 and must not rebind the verdict to anything"
grep -qi 'NOT the same patch' "$LOG" && ok || bad "T2 and must say a re-review is owed: $(grep -i 'own CI is red' "$LOG" | head -1)"

# A REBASE LEAVES THE REPO'S DECLARED GENERATED FILES STALE BY CONSTRUCTION —
# the member could not have predicted what the base would add to a generated
# index — so they are REGENERATED and committed before the push, exactly as
# carry.sh did. They are outside the carry identity, so the verdict still binds.
reset
git -C "$S" checkout -q -b ticket/tk-15 "$BASE"
printf 'export const drift = 1\n' > "$S/src/plain-drift.ts"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm drift >/dev/null && git -C "$S" push -q origin ticket/tk-15
HEAD_F=$(git -C "$S" rev-parse HEAD)
mkrec 15 105 "$HEAD_F"
mkpr 105 ticket/tk-15 "$HEAD_F" CLEAN 2026-09-21T05:00:00Z | jq -sc '.' > "$T/prs.json"
arm_red "$HEAD_F"
run
NEW_F=$(remote_head ticket/tk-15)
[ "$NEW_F" != "$HEAD_F" ] && ok || bad "T2 a stale generated file must not stop the rebase"
REG=$(git -C "$T/origin.git" show "$NEW_F:scripts/worker-import-set.json" 2>/dev/null)
{ grep -q 'src/plain-drift.ts' <<<"$REG" && grep -q 'src/main-advance.ts' <<<"$REG"; } && ok \
  || bad "T2 the pushed head must carry the REGENERATED registry, not the union driver's leftovers: $REG"
[ "$(head -1 "$H/builds/$PROJ-TK-15-202609210015/reviewed-sha")" = "$NEW_F" ] && ok \
  || bad "T2 and the verdict must still carry — generated paths are outside the identity"

# BUT A GENERATOR WITH NO FIXED POINT IS A REAL CONFLICT WEARING A CLEAN
# REBASE'S CLOTHES: the pushed head would be red for a BRAND NEW reason, on a
# head that is no longer behind the base, so this lane would park it and never
# retry. Nothing is pushed.
reset
git -C "$S" checkout -q -b ticket/tk-16 "$BASE"
printf 'export const osc = 1\n' > "$S/src/plain-osc.ts"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm osc >/dev/null && git -C "$S" push -q origin ticket/tk-16
HEAD_G=$(git -C "$S" rev-parse HEAD)
mkrec 16 106 "$HEAD_G"
mkpr 106 ticket/tk-16 "$HEAD_G" CLEAN 2026-09-21T06:00:00Z | jq -sc '.' > "$T/prs.json"
arm_red "$HEAD_G"
: > "$T/osc-count.txt"; touch "$T/regen-oscillate"
run
rm -f "$T/regen-oscillate"
[ "$(remote_head ticket/tk-16)" = "$HEAD_G" ] && ok \
  || bad "T2 a generated file that never settles must push NOTHING"
grep -qi 'do not SETTLE' "$LOG" && ok \
  || bad "T2 and must name it a real conflict: $(grep -i 'own CI is red' "$LOG" | head -1)"

# ============================================================================
# T3. A MERGED fix-main-red PR CLEARS THE HOLD NOW
# ============================================================================
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
# merged AFTER the flag went up, labelled, and its merge-ref run is green
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok || bad "T3 a merged, green fix-main-red PR must clear the flag file"
grep -q '^main-red-example-org-demo-os off ' "$T/flagrows.txt" && ok \
  || bad "T3 and the D1 pause row in the SAME tick (flag_set … off): $(cat "$T/flagrows.txt")"
grep -qi 'CLEARED' "$LOG" && ok || bad "T3 the lift must be said out loud"
[ "$(nbatch)" = 1 ] && ok || bad "T3 and the freeze must not gate this very tick"

# a fix-main-red PR whose own CI is RED lifts nothing
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
arm_red "$FIXSHA"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ -f "$H/flags/main-red-example-org-demo-os" ] && ok || bad "T3 a fix-main-red PR with a RED merge-ref run must lift nothing"
[ "$(nbatch)" = 0 ] && ok || bad "T3 and the freeze must still gate the lane"

# THE FIVE VACUOUS SHAPES. Each is a merge-ref head with no concluded failure
# on it and no proof either: a fix admin-merged while its CI is still running,
# one whose jobs have not raised a check run yet, and the skipped/ignored-only
# tails. "No failure" is not "green", and each of these lifted the fleet-wide
# freeze onto an unproven base before this round.
for SHAPE in in_progress queued no_runs ignored_only skipped_only; do
  reset
  mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
  FIXSHA=$(remote_head main)
  touch "$H/flags/main-red-example-org-demo-os"
  case "$SHAPE" in
    in_progress)  arm_checks "$FIXSHA" "$VAC_INPROGRESS" ;;
    queued)       arm_checks "$FIXSHA" "$VAC_QUEUED" ;;
    no_runs)      arm_checks "$FIXSHA" "$VAC_NONE" ;;
    ignored_only) arm_checks "$FIXSHA" "$VAC_IGNORED" ;;
    skipped_only) arm_checks "$FIXSHA" "$VAC_SKIPPED" ;;
  esac
  jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
  run
  [ -f "$H/flags/main-red-example-org-demo-os" ] && ok \
    || bad "T3 a merge-ref head that is '$SHAPE' has proved NOTHING and must not lift the freeze"
  [ "$(nbatch)" = 0 ] && ok || bad "T3 and the freeze must still gate the lane ($SHAPE)"
done

# TWO RUNS OF THE SAME WORKFLOW FOR ONE SHA is an ordinary fleet shape —
# mc_kick_ci's close/reopen raises a second `pull_request` run for the same
# head, and so does a workflow_dispatch — and GitHub lists them NEWEST FIRST
# with one entry per run at its latest attempt, so `run_attempt` ties and
# picking `last` picked the OLDEST. Both orderings must refuse while anything of
# that name is still in flight.
for ORDER in newest_in_progress newest_failed; do
  reset
  mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
  FIXSHA=$(remote_head main)
  touch "$H/flags/main-red-example-org-demo-os"
  case "$ORDER" in
    newest_in_progress)
      printf '{"workflow_runs":[{"id":99,"name":"Harness CI","run_attempt":1,"status":"in_progress","conclusion":null,"created_at":"2026-09-21T11:00:00Z","run_started_at":"2026-09-21T11:00:00Z"},{"id":42,"name":"Harness CI","run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}' > "$T/runs.json" ;;
    newest_failed)
      printf '{"workflow_runs":[{"id":99,"name":"Harness CI","run_attempt":1,"status":"completed","conclusion":"failure","created_at":"2026-09-21T11:00:00Z","run_started_at":"2026-09-21T11:00:00Z"},{"id":42,"name":"Harness CI","run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}' > "$T/runs.json" ;;
  esac
  jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
  run
  rm -f "$T/runs.json"
  [ -f "$H/flags/main-red-example-org-demo-os" ] && ok \
    || bad "T3 with two Harness CI runs for one sha ($ORDER, GitHub's newest-first order) the NEWEST decides — the freeze must not lift"
done

# ...and the newest-green / older-cancelled order DOES lift: a superseded run
# that was cancelled must not hold a freeze for ever.
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
printf '{"workflow_runs":[{"id":99,"name":"Harness CI","run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-09-21T11:00:00Z","run_started_at":"2026-09-21T11:00:00Z"},{"id":42,"name":"Harness CI","run_attempt":2,"status":"completed","conclusion":"cancelled","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}' > "$T/runs.json"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
rm -f "$T/runs.json"
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 a superseded, cancelled older run must not hold the freeze when the newest run is green"

# A HEAD WITH NO RUN OF THE NAMED WORKFLOW HAS NOT BEEN TESTED, however green
# its check runs look. That is this fleet's own shape and not a hypothetical: a
# push made with the App token raises no `pull_request` run, so a fix PR landed
# that way carries a Summary success, a neutral Mergify run and ZERO Harness CI
# runs — a head whose shards never ran. The default refuses it; the knob is
# there for a repo that genuinely raises no workflow of that name.
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
printf '{"workflow_runs":[]}' > "$T/runs.json"
arm_checks "$FIXSHA" '{"check_runs":[{"name":"Summary","status":"completed","conclusion":"success"},{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral"}]}'
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 a merge-ref head with ZERO runs of the named workflow has not been tested and must not lift the freeze"
grep -qi 'no Harness CI run for' "$LOG" && ok \
  || bad "T3 and the lane must SAY why the freeze stands: $(grep -i 'STANDS' "$LOG" | head -1)"

# ...and BATCH_CI_RUN_REQUIRED=0 is the fallback for a repo that raises no
# workflow of that name at all, where requiring one makes freezes unliftable.
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
printf '{"workflow_runs":[]}' > "$T/runs.json"
arm_checks "$FIXSHA" '{"check_runs":[{"name":"Summary","status":"completed","conclusion":"success"},{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral"}]}'
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
BATCH_CI_RUN_REQUIRED=0 run
rm -f "$T/runs.json"
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 with BATCH_CI_RUN_REQUIRED=0 the check-runs half alone must still be able to lift"

# A MERGIFY CHECK RUN IS NEVER THIS REPO'S CI, WHATEVER IT IS CALLED THIS WEEK.
# The reporter has shipped as both "Mergify Merge Protections" and "Mergify
# Merge Queue"; a queued one would otherwise read as "this head is still
# pending" and the lift would never fire.
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
arm_checks "$FIXSHA" '{"check_runs":[{"name":"Mergify Merge Queue","status":"queued","conclusion":null},{"name":"Harness CI","status":"completed","conclusion":"success"}]}'
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 a QUEUED 'Mergify Merge Queue' check run must be ignored, not read as this head still being pending"

# the WORKFLOW RUN is asked for too: check-run counts lie while shard jobs wait
# for a pool runner and have raised no check runs at all (train #1229, 08:45Z).
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
printf '{"workflow_runs":[{"id":4242,"name":"Harness CI","run_attempt":1,"status":"in_progress","conclusion":null,"run_started_at":"2026-09-21T10:00:00Z"}]}' > "$T/runs.json"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 a Harness CI run that has not concluded must not lift the freeze, whatever the check runs say"
rm -f "$T/runs.json"

# the LABEL is the fleet's knob, not a literal
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:202, merged_at:$m, labels:[{name:"unbreak-main"}], head:{sha:$h}}]' > "$T/closedprs.json"
MC_MAIN_RED_LABEL=unbreak-main run
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 a renamed MC_MAIN_RED_LABEL must still lift the freeze — a hardcoded string silently disables it"

# ...and the OTHER spelling of the same label, the one main_red_label reads out
# of the harness env file. The two are not unified upstream, so both must work.
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
printf 'MAIN_RED_LABEL=unbreak-main\n' > "$H/env/global.env"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:203, merged_at:$m, labels:[{name:"unbreak-main"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
: > "$H/env/global.env"
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T3 MAIN_RED_LABEL in the harness env file must rename the label too"

# an UNLABELLED merged PR lifts nothing either
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
FIXSHA=$(remote_head main)
touch "$H/flags/main-red-example-org-demo-os"
jq -nc --arg h "$FIXSHA" --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{number:201, merged_at:$m, labels:[{name:"chore"}], head:{sha:$h}}]' > "$T/closedprs.json"
run
[ -f "$H/flags/main-red-example-org-demo-os" ] && ok || bad "T3 only the fix-main-red LABEL lifts a freeze"

# ============================================================================
# T4. THE TRAIN-SKIP FILE IS HONOURED LIVE
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
{ grep -q '#101' <<<"$B" && grep -q '#102' <<<"$B"; } && ok || bad "T4 both siblings must ride when nothing is parked"

reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
mkdir -p "$STATE"
printf '# parked by hand\n102\n' > "$STATE/train-skip.txt"
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#102' <<<"$B" && bad "T4 a PR listed in train-skip.txt must not be a member" || ok
grep -q '#101' <<<"$B" && ok || bad "T4 and the rest of the train must still form (a train of one)"
grep -qi 'train-skip' "$LOG" && ok || bad "T4 the park must name the file an operator edits"
rm -f "$STATE/train-skip.txt"

# ============================================================================
# T5. A MEMBER THAT GOES RED AFTER THE TRAIN FORMED PRE-EMPTS IT
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok || bad "T5 the first pass must push one train"
TRAINBR=$(batch_branches)
# the train is still in flight, and NOW #102's own CI concludes failure
echo '{"state":"OPEN","mergeCommit":null}' > "$T/train-state.json"
arm_red "$HEAD_B"
: > "$T/LOGMARK"; : > "$LOG"
run
grep -qx '900' "$T/train-closed.txt" && ok || bad "T5 the train PR must be closed, not left to fail its one run"
TRAINREC="$STATE/train-${TRAINBR##*/}.json"
[ "$(jq -r '.status' "$TRAINREC" 2>/dev/null)" = abandoned ] && ok \
  || bad "T5 the train record must read abandoned (got $(jq -r '.status' "$TRAINREC" 2>/dev/null))"
grep -qxF "102 $HEAD_B" "$STATE/abandoned.txt" 2>/dev/null && ok \
  || bad "T5 the late-red member must be excluded at its head"
grep -qi 'PRE-EMPTED' "$LOG" && ok || bad "T5 the pre-emption must be said out loud"
grep -qi 'binary split of the red union' "$LOG" \
  && bad "T5 no split may be paid for a member that was already known red" || ok
[ "$(nbatch)" = 1 ] && ok || bad "T5 the dead train's branch must be gone and exactly one new one pushed (got $(nbatch))"
grep -qx '4242' "$T/cancelled.txt" 2>/dev/null && ok \
  || bad "T5 the union's own workflow run must be CANCELLED — nothing will read it and it holds a pool runner: $(cat "$T/cancelled.txt" 2>/dev/null)"
# and the train re-forms WITHOUT it, in the very same pass: the members were
# released and only the red one is excluded.
B=$(cat "$T/train-body.txt" 2>/dev/null)
{ grep -q '#101' <<<"$B" && ! grep -q '#102' <<<"$B"; } && ok \
  || bad "T5 the next train must re-form without the red member (body: $(tr '\n' ' ' <<<"$B" | cut -c1-200))"

# ============================================================================
# T6. EVERY TRAIN WRITES merge_trains ROWS
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
TRAINBR=$(batch_branches)
UNION=$(git -C "$T/origin.git" rev-parse "refs/heads/$TRAINBR")
awk -F'\t' -v b="$TRAINBR" '$2==b && $3=="creating"' "$T/trains.tsv" | grep -q . && ok \
  || bad "T6 the row must exist BEFORE the train PR is opened (creating): $(cat "$T/trains.tsv")"
ROW=$(awk -F'\t' -v b="$TRAINBR" '$2==b && $3=="open"' "$T/trains.tsv" | tail -1)
[ -n "$ROW" ] && ok || bad "T6 and again once the train PR exists (open)"
grep -q 'members=101,102' <<<"$ROW" && ok || bad "T6 the row must carry its members: $ROW"
grep -q "union_sha=$UNION" <<<"$ROW" && ok || bad "T6 and the union sha CI runs once over: $ROW"
grep -q 'train_pr=900' <<<"$ROW" && ok || bad "T6 and the train's own PR number: $ROW"
# the landing writes the outcome, the merge sha and the one CI run id
echo '{"state":"MERGED","mergeCommit":{"oid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}' > "$T/train-state.json"
run
LANDED=$(awk -F'\t' -v b="$TRAINBR" '$2==b && $3=="landed"' "$T/trains.tsv" | tail -1)
[ -n "$LANDED" ] && ok || bad "T6 a landed train must write a landed row: $(cat "$T/trains.tsv")"
grep -q 'merge_sha=deadbeef' <<<"$LANDED" && ok || bad "T6 with its merge sha: $LANDED"
grep -q 'run_id=4242' <<<"$LANDED" && ok || bad "T6 and the id of the one run it bought: $LANDED"

# the client verbs that carry the row: the body the worker route accepts, and
# the rows read back out of it.
(
  JOBS_HARNESS="$H"; JOBS_BOX=testbox
  _jobs_req() {
    printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/req.txt"
    case "$1 $2" in
      "GET /api/merge-trains"*) cat "$T/mt-api.json" ;;
      *) printf '{"train":{"outcome":"open"}}' ;;
    esac
  }
  . "$DIR/bin/lib/jobs/queue.sh" 2>/dev/null
  merge_train_put demo-os batch/demo-os/x open repo=example-org/demo-os train_pr=900 \
    members=101,102 member_count=2 union_sha=abc run_id=7 bogus=nope >/dev/null
  printf '{"merge_trains":[{"project":"demo-os","branch":"batch/demo-os/x","outcome":"landed","train_pr":900,"member_count":2,"members":"101,102","union_sha":"abc","run_id":"7","merge_sha":"def","created_at":"2026-09-21T00:00:00Z"}]}' > "$T/mt-api.json"
  merge_train_list demo-os > "$T/mt-list.tsv"
)
BODY=$(grep '^PUT /api/merge-trains' "$T/req.txt" | tail -1 | cut -d' ' -f3-)
[ "$(jq -r '.members' <<<"$BODY")" = "101,102" ] && ok || bad "T6 merge_train_put must send the members: $BODY"
[ "$(jq -r '.train_pr' <<<"$BODY")" = "900" ] && ok || bad "T6 and a numeric train_pr: $BODY"
[ "$(jq -r '.bogus // "absent"' <<<"$BODY")" = absent ] && ok \
  || bad "T6 an unknown key must be DROPPED, never sent — the route would 400 the whole write: $BODY"
[ "$(cut -f3 "$T/mt-list.tsv")" = landed ] && ok || bad "T6 merge_train_list must read the rows back: $(cat "$T/mt-list.tsv")"

# ============================================================================
# T7. THE FLEET LANE GATE
# ============================================================================
reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
touch "$H/flags/lane-off-batch-resolve"
run
[ ! -s "$T/gh-calls.txt" ] && ok || bad "T7 flags/lane-off-batch-resolve must stop the lane before any gh call"
[ "$(nbatch)" = 0 ] && ok || bad "T7 and push no train"
rm -f "$H/flags/lane-off-batch-resolve"

reset
mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-21T01:00:00Z | jq -sc '.' > "$T/prs.json"
touch "$H/flags/lane-off-batch-resolve-$PROJ"
run
[ "$(nbatch)" = 0 ] && ok || bad "T7 and the per-project spelling must stop it too"
rm -f "$H/flags/lane-off-batch-resolve-$PROJ"

# ============================================================================
# T8. THE mc_batch_should_spawn THE CONDUCTOR RESOLVES
#
#     bin/lib/merge-conductor-lib.sh SOURCES bin/lib/mc/queue.sh and then
#     re-defines this function further down, and the later definition wins. So a
#     knob added only to the module is invisible to bin/merge-conductor.sh,
#     which sources the lib — and trains of one would never be spawned for while
#     every suite stayed green. This sources the lib exactly as the conductor
#     does and drives the RESOLVED function; a grep of either file would pass on
#     the bug this pins.
# ============================================================================
spawn_rc() { # spawn_rc <BATCH_TRAIN_MIN> <candidate count> -> rc
  ( export HARNESS="$H" MC_REPOS="$T/repos"
    BATCH_TRAIN_MIN="$1" bash -c '
      set -uo pipefail
      . "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 99
      mc_init >/dev/null 2>&1
      mc_batch_should_spawn probe-project "$1"' _ "$2" >/dev/null 2>&1 )
}
spawn_rc 1 1; [ "$?" = 0 ] && ok \
  || bad "T8 with BATCH_TRAIN_MIN=1 the conductor must spawn the lane for ONE candidate — trains of one are dead without this"
spawn_rc 2 1; [ "$?" = 1 ] && ok \
  || bad "T8 with BATCH_TRAIN_MIN=2 one candidate must NOT spawn it (no train is in flight)"
spawn_rc 2 2; [ "$?" = 0 ] && ok || bad "T8 two candidates must spawn it at min 2"
spawn_rc 1 0; [ "$?" = 1 ] && ok || bad "T8 zero candidates and no open train must not spawn it"
( . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  type mc_batch_should_spawn 2>/dev/null | grep -q 'BATCH_TRAIN_MIN' ) && ok \
  || bad "T8 the function the lib RESOLVES must be the one that reads the knob, not the module's shadowed copy"

echo "batch-resolve-trains(BH-1269): $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
