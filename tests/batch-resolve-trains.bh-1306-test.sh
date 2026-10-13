#!/bin/bash
# tests/batch-resolve-trains.bh-1306-test.sh — BH-1306: a train that is BEHIND
# the base tip is re-verified there before it lands, the DIFF beats the plan
# when the two disagree, and the repo's most-coupled directories are modules.
#
# THE BUG, IN ONE SENTENCE (reviewer probe P7 of #1297). The partition's premise
# is textual disjointness. After train A lands, train B's union still MERGES
# cleanly — its merge base is the OLD tip — so `settle_train` never re-formed it:
# the trigger was `*CONFLICTING*|*DIRTY*` and nothing else. Nothing downstream
# re-verifies A+B together (`bin/merge-queue.sh` reads no CI, this repo's
# branch protection declares no required checks), so B lands on a tip its
# `verify_union` never saw. With a contract that is red only when BOTH feature
# files exist, each train is green alone and main is RED after both land.
#
# Ten behaviours, every one of them driven against a REAL bare origin and the
# SHIPPED lane — no paraphrase of its logic anywhere in this file:
#
#   P7a a CLEAN train whose base no longer contains the tip is re-verified
#       THERE, and when that verification is red the train PR is closed, its
#       members released and excluded, and one alert is raised
#   P7b the same train when the re-verify is GREEN: re-formed onto the tip,
#       same PR, same branch, a new union sha that CONTAINS the tip
#   N1  a train whose base IS the tip is left exactly where it is
#   N2  a gated pass (flags/batch-resolve-off) spends nothing on a behind train
#   N3  BATCH_REFORM_MAX=0 spends nothing on a behind train either
#   B1  a behind train whose re-form budget is spent is closed, not left
#       landable
#   D1  when the pre-plan and the diff disagree, the DIFF is what the candidate
#       claims — the plan is a prediction, the diff is the patch
#   D2  a diff that is nothing but declared generated output still falls back
#       to the plan (the narrow change: diff-FIRST, not diff-ONLY)
#   M1  bin/lib/, bin/ and worker/jobs/src/lib/ are modules, and bin/lib/mc/
#       still wins over both of its parents
#   M2  two lane scripts in bin/ therefore ride ONE train
#
# WHY REAL GIT. Every claim here is about what a union cut from a moving base
# actually does — whether the second train's branch contains what landed under
# it, and whether rebuilding it on the new tip produces a tree that verifies. A
# stubbed git would only prove the shell around it is spelled right, which was
# never the part in doubt. `gh` IS stubbed, always: nothing here may touch
# GitHub.
#
# Run from anywhere: tests/batch-resolve-trains.bh-1306-test.sh  (exit 0 = pass)
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
mkdir -p "$S/src" "$S/scripts" "$S/bin/lib/mc"

printf 'export const base = 1\n' > "$S/src/base.ts"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/lib/mc/keep.sh"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"

# The stub regenerate command, as in the BH-1270 fixture: it rewrites the
# declared registry deterministically from the tree, so every member of every
# train conflicts with the base in it. That conflict is the whole reason a train
# exists, and it is why the partition must not count declared generated files.
cat > "$S/scripts/regen.sh" <<'REGEN'
#!/bin/sh
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"

# THE CONTRACT THAT IS RED ONLY WHEN BOTH FEATURES ARE PRESENT. This is probe
# P7 exactly: it is GREEN on main+A and GREEN on main+B, and RED on main+A+B. A
# lane that never re-verifies the second union on the tip cannot see it.
cat > "$S/ci-stub.sh" <<CI
#!/bin/sh
f="$T/red-when-all.txt"
[ -s "\$f" ] || exit 0
while IFS= read -r p; do
  [ -n "\$p" ] || continue
  [ -e "\$p" ] || exit 0
done < "\$f"
exit 1
CI
chmod +x "$S/ci-stub.sh"

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

# mksib <branch> <file...> — a sibling that adds files of its own AND rewrites
# the declared registry, so it conflicts with an advanced base in a file the
# repo marks generated (allowed) and nowhere else.
mksib() {
  local br="$1" f; shift
  git -C "$S" checkout -q -b "$br" "$BASE"
  for f in "$@"; do
    mkdir -p "$(dirname "$S/$f")"
    printf 'export const x = 1\n' > "$S/$f"
  done
  printf '%s\n' src/base.ts "$@" | jq -R . | jq -sc '{imports:.}' > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$br" >/dev/null && git -C "$S" push -q origin "$br"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mksib ticket/tk-11 src/feature-a.ts)
HEAD_B=$(mksib ticket/tk-12 src/feature-b.ts)
# THE PLAN AND THE PATCH DISAGREE (D1). Its pre-plan names src/unrelated.ts
# alone; the patch it actually carries also touches src/feature-a.ts, which is
# the file #101 carries. Judged from the plan these two are disjoint and ride
# two trains that meet on main; judged from the patch they are not.
HEAD_G=$(mksib ticket/tk-17 src/unrelated.ts src/feature-a.ts)
HEAD_I=$(mksib ticket/tk-18 bin/one.sh)
HEAD_J=$(mksib ticket/tk-19 bin/two.sh)
# A sibling whose diff is NOTHING BUT the declared generated file. It has a
# pre-plan, so the fallback still has an answer — that is D2's whole point.
git -C "$S" checkout -q -b ticket/tk-16 "$BASE"
printf '{"imports":["src/base.ts","src/nothing.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm tk-16 >/dev/null && git -C "$S" push -q origin ticket/tk-16
HEAD_F=$(git -C "$S" rev-parse HEAD)

# The base moves on, so every sibling conflicts with it in the registry.
advance_main() {
  git -C "$S" checkout -q main && git -C "$S" reset -q --hard "$BASE"
  printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
  printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null
  git -C "$S" push -qf origin main
  rm -rf "$T/repos/$PROJ"; git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
}

# ── the harness tree ─────────────────────────────────────────────────────────
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" \
         "$H/tmp" "$H/plans" "$T/fakebin" "$T/repos"
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
# THE REGISTRY IS RENDERED, NEVER COPIED (BH-1247/#1275) — and a compose that
# fails is RED, never a skip: M2 and every case below would otherwise run
# against a lane with no knobs and pass for a reason that is not the one under
# test (the same rule tests/jobs-worker-test.sh applies to the same builder).
mkdir -p "$H/catalog"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$H/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: batch-resolve-trains.bh-1306-test: catalog/lanes.json could not be composed from catalog/lanes.d — every case below would run against a lane with no knobs"; exit 1; }
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# THE ALERT IS AN ARTIFACT, not a no-op: "one alert per abandoned train" is a
# claim this suite makes, so the stub has to record what it was told.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh"

cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
flag_active() { [ -f "$T/h/flags/\$1" ]; }
flag_set() {
  case "\$2" in off|0|false) rm -f "$T/h/flags/\$1" ;; *) touch "$T/h/flags/\$1" ;; esac
}
EOF

advance_main
export MC_REPOS="$T/repos"

# ── the fake gh ──────────────────────────────────────────────────────────────
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"--json headRefOid"*)
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  *"-i -X GET repos/$SLUG/commits/"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}\n'
    exit 0 ;;
  *"-i -X POST repos/$SLUG/actions/runs/"*"/cancel"*)
    printf '%s\n' "\$*" | grep -oE 'runs/[0-9]+' | sed 's#runs/##' >> "$T/cancelled.txt"
    printf 'HTTP/2.0 202 Accepted\nx-stub: 1\n\n{}\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"workflow_runs":[{"id":4242,"name":"Harness CI","status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}\n'
    exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0 ;;
  *"api -i -X PATCH repos/$SLUG/pulls/"*)
    printf 'closed\n' > "$T/pr-state-\$num.txt"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    case "\$(cat "$T/pr-state-\$num.txt" 2>/dev/null)" in
      closed) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n' ;;
      *)      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
    esac
    exit 0 ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'; exit 0 ;;
  *"-X PATCH repos/$SLUG/pulls/"*)
    printf '%s\n' "\$num" >> "$T/train-closed.txt"; echo '{"state":"closed"}'; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*)
    n=\$(( \$(cat "$T/prnum.txt" 2>/dev/null || echo 899) + 1 ))
    printf '%s\n' "\$n" > "$T/prnum.txt"
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$T/train-body-\$n.txt"
      prev="\$a"
    done
    printf '%s\n' "\$n" >> "$T/train-created.txt"
    echo "https://github.com/$SLUG/pull/\$n"
    exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/"*)
    cat "$T/train-state-\$num.json" 2>/dev/null && exit 0
    echo '{"state":"OPEN","mergeCommit":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

mkpr() { # mkpr <num> <branch> <head> <created>
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg c "$4" --arg slug "$SLUG" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:$c, labels:[]}'
}
mkrec() { # mkrec <ticket-number> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026092100$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkplan() { # mkplan <ticket-number> <path...>
  local k="$1"; shift
  mkdir -p "$H/plans/$PROJ-TK-$k"
  printf '%s\n' "$@" > "$H/plans/$PROJ-TK-$k/planned-files.txt"
}
mkrec 11 101 "$HEAD_A"; mkplan 11 src/feature-a.ts
mkrec 12 102 "$HEAD_B"; mkplan 12 src/feature-b.ts
mkrec 17 107 "$HEAD_G"; mkplan 17 src/unrelated.ts   # the plan the DIFF contradicts
mkrec 16 108 "$HEAD_F"; mkplan 16 src/feature-b.ts   # regen-only diff, real plan
mkrec 18 109 "$HEAD_I"; mkplan 18 bin/one.sh
mkrec 19 110 "$HEAD_J"; mkplan 19 bin/two.sh

run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"; : > "$T/trains.tsv"
  : > "$T/train-closed.txt"; : > "$T/ledger.tsv"; : > "$T/cancelled.txt"
  : > "$T/train-created.txt"; : > "$T/alerts.txt"
  rm -f "$T"/train-body-*.txt "$T"/train-state-*.json "$T"/pr-state-*.txt \
        "$T/red-when-all.txt" "$H/state/settings-cache.json" "$H/flags/"* 2>/dev/null
  printf '899\n' > "$T/prnum.txt"
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor/batch-hold"
  rm -f "$H/state/merge-conductor/attempts.txt"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
}
batch_branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/' | sort; }
nbatch() { batch_branches | grep -c . ; }
remote_head() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }
recof() { echo "$STATE/train-${1##*/}.json"; }
bodymem() { grep -oE '#1[0-9]+' "$T/train-body-$1.txt" 2>/dev/null | sort -u | tr -d '#' | tr '\n' ' '; }
has_ref() { git -C "$T/origin.git" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

# arm_behind [<red-path>...] — two disjoint siblings form two trains; the FIRST
# one really lands, so main moves under the second and the second is BEHIND it
# while still merging cleanly. Every artifact is truncated afterwards, so what a
# case asserts is what the SETTLE pass did and nothing else.
#   Sets BR0 BR1 REC1 MERGESHA U1_REMOTE_BEFORE.
arm_behind() {
  reset
  [ "$#" -gt 0 ] && printf '%s\n' "$@" > "$T/red-when-all.txt"
  { mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
    mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
  run
  [ "$(nbatch)" = 2 ] || { echo "arm_behind: two trains must go out, got $(nbatch)"; return 1; }
  BR0=$(batch_branches | head -1); BR1=$(batch_branches | tail -1)
  REC1=$(recof "$BR1")
  [ "$(jq -r '.train_url' "$REC1")" = "https://github.com/$SLUG/pull/901" ] \
    || { echo "arm_behind: the second branch must be PR 901, got $(jq -r '.train_url' "$REC1")"; return 1; }
  # the first train really lands: its branch is merged into main on the origin
  git -C "$S" fetch -q origin "+refs/heads/*:refs/remotes/origin/*"
  git -C "$S" checkout -q main && git -C "$S" reset -q --hard origin/main
  git -C "$S" merge -q --no-edit "origin/$BR0" >/dev/null 2>&1
  git -C "$S" push -q origin main
  MERGESHA=$(git -C "$S" rev-parse HEAD)
  printf '{"state":"MERGED","mergeCommit":{"oid":"%s"},"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' \
    "$MERGESHA" > "$T/train-state-900.json"
  # ...and GitHub calls the second train's PR CLEAN, because it IS: its merge
  # base is the old tip and the union still merges. That is the whole bug.
  printf '{"state":"OPEN","mergeCommit":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' \
    > "$T/train-state-901.json"
  U1_REMOTE_BEFORE=$(remote_head "$BR1")
  : > "$LOG"; : > "$T/train-created.txt"; : > "$T/train-closed.txt"
  : > "$T/cancelled.txt"; : > "$T/alerts.txt"; : > "$T/trains.tsv"; : > "$T/gh-calls.txt"
  return 0
}

# ============================================================================
# P7a. A BEHIND TRAIN THAT IS RED ON THE TIP NEVER LANDS
#      The contract is red only when BOTH feature files exist, so each train is
#      green alone and the union of both is not. Re-verified on the tip the
#      second train is RED — and because bin/merge-queue.sh reads no CI, the
#      only way it does not land is for the lane to close it.
# ============================================================================
if arm_behind src/feature-a.ts src/feature-b.ts; then
  run
  grep -qi 'LANDED' "$LOG" && ok || bad "P7a setup: the first train must settle as landed in the same pass"
  grep -qxF 901 "$T/train-closed.txt" 2>/dev/null && ok \
    || bad "P7a a CLEAN train whose base no longer contains the tip must be re-verified there before it lands — main was ahead, the contract is red on the union of both, and the train was left landable (closed: '$(tr '\n' ' ' < "$T/train-closed.txt")')"
  [ "$(jq -r '.status' "$REC1" 2>/dev/null)" = abandoned ] && ok \
    || bad "P7a the record must read abandoned (got $(jq -r '.status' "$REC1" 2>/dev/null))"
  grep -qxF "102 $HEAD_B" "$STATE/abandoned.txt" 2>/dev/null && ok \
    || bad "P7a its member must go back to the one-at-a-time path, excluded at the head it rode with"
  has_ref "$BR1" && bad "P7a the dead train's branch must be deleted from the remote" || ok
  [ "$(grep -c . "$T/alerts.txt")" = 1 ] && ok \
    || bad "P7a exactly one alert per abandoned train (got $(grep -c . "$T/alerts.txt"))"
  [ -s "$T/train-created.txt" ] \
    && bad "P7a no new train may be built out of the released member in the same pass: $(cat "$T/train-created.txt")" || ok
  grep -qi 'BEHIND' "$LOG" && ok || bad "P7a the log must name the trigger: $(tail -3 "$LOG")"
  grep -qi 'RED against the repo' "$LOG" && ok \
    || bad "P7a and it must say the re-verification on the tip is what went red: $(tail -3 "$LOG")"
  [ "$(cat "$H/builds/$PROJ-TK-12-2026092100"*/reviewed-sha)" = "$HEAD_B" ] && ok \
    || bad "P7a NOTHING may be re-reviewed or re-bound: the member's head never moved"
else
  bad "P7a fixture could not be armed"
fi
advance_main

# ============================================================================
# P7b. THE GREEN ARM: RE-FORMED ONTO THE TIP, SAME PR
#      Same setup, nothing red. The train is rebuilt on the new tip and
#      force-pushed to the same branch — and the new union CONTAINS what landed
#      under it, which is the property the whole ticket is about.
# ============================================================================
if arm_behind; then
  run
  [ "$(remote_head "$BR1")" != "$U1_REMOTE_BEFORE" ] && ok \
    || bad "P7b a behind train's branch must be rebuilt on the new tip"
  git -C "$T/origin.git" merge-base --is-ancestor "$MERGESHA" "refs/heads/$BR1" >/dev/null 2>&1 && ok \
    || bad "P7b and the union it pushed must CONTAIN the tip that landed under it — that is what 'verified on the new base' means"
  [ "$(jq -r '.reform_n' "$REC1")" = 1 ] && ok \
    || bad "P7b the re-form must be counted (reform_n=$(jq -r '.reform_n' "$REC1"))"
  [ "$(jq -r '.train_url' "$REC1")" = "https://github.com/$SLUG/pull/901" ] && ok \
    || bad "P7b the SAME PR must carry the new union — a re-form is not a new train"
  [ -s "$T/train-created.txt" ] && bad "P7b no second train PR may be opened: $(cat "$T/train-created.txt")" || ok
  [ -s "$T/train-closed.txt" ] && bad "P7b a GREEN re-verify must not close anything: $(cat "$T/train-closed.txt")" || ok
  grep -qi 'RE-FORMED' "$LOG" && ok || bad "P7b the re-form must be said out loud"
  grep -qi 'no longer contains' "$LOG" && ok \
    || bad "P7b and it must say the trigger was BEHIND, not a conflict that never happened: $(grep -i 'RE-FORMED' "$LOG" | head -1)"
  grep -qxF 4242 "$T/cancelled.txt" 2>/dev/null && ok \
    || bad "P7b the superseded CI run must be cancelled (got '$(tr '\n' ' ' < "$T/cancelled.txt")')"
  awk -F'\t' '$3=="open"' "$T/trains.tsv" | grep -qi 'tip' && ok \
    || bad "P7b the merge_trains row must say what it was re-formed onto: $(cat "$T/trains.tsv")"
else
  bad "P7b fixture could not be armed"
fi
advance_main

# ============================================================================
# N1. A TRAIN WHOSE BASE *IS* THE TIP IS LEFT ALONE
#     Absent is not behind: the check must cost a train nothing when nothing
#     moved under it.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
if [ "$(nbatch)" = 2 ]; then
  N1_BR0=$(batch_branches | head -1); N1_BR1=$(batch_branches | tail -1)
  N1_H0=$(remote_head "$N1_BR0"); N1_H1=$(remote_head "$N1_BR1")
  : > "$LOG"; : > "$T/train-closed.txt"
  run
  { [ "$(remote_head "$N1_BR0")" = "$N1_H0" ] && [ "$(remote_head "$N1_BR1")" = "$N1_H1" ]; } && ok \
    || bad "N1 nothing landed under either train, so neither branch may be rewritten"
  { [ "$(jq -r '.reform_n' "$(recof "$N1_BR0")")" = 0 ] \
    && [ "$(jq -r '.reform_n' "$(recof "$N1_BR1")")" = 0 ]; } && ok \
    || bad "N1 and neither may spend a re-form"
  [ -s "$T/train-closed.txt" ] && bad "N1 nothing may be closed: $(cat "$T/train-closed.txt")" || ok
  grep -qi 'RE-FORMED' "$LOG" && bad "N1 a train that is not behind must not be re-formed" || ok
else
  bad "N1 setup: two trains must go out (got $(nbatch))"
fi

# ============================================================================
# N2 / N3. A GATED PASS AND A ZEROED BUDGET SPEND NOTHING
#     BH-945's freeze and BATCH_REFORM_MAX=0 both mean "do not buy a union
#     build, a verification run and a push this tick". The behind check sits
#     inside that same guard, so a gated pass never even asks.
# ============================================================================
if arm_behind; then
  touch "$H/flags/batch-resolve-off"
  run
  [ "$(remote_head "$BR1")" = "$U1_REMOTE_BEFORE" ] && ok \
    || bad "N2 a gated pass must not re-form a behind train"
  [ -s "$T/train-closed.txt" ] && bad "N2 and must not close one: $(cat "$T/train-closed.txt")" || ok
  grep -qi 'no new batch' "$LOG" && ok || bad "N2 the gate must be said out loud: $(tail -2 "$LOG")"
else
  bad "N2 fixture could not be armed"
fi
advance_main

if arm_behind; then
  BATCH_REFORM_MAX=0 run
  [ "$(remote_head "$BR1")" = "$U1_REMOTE_BEFORE" ] && ok \
    || bad "N3 BATCH_REFORM_MAX=0 turns the whole re-form off, behind included"
  [ -s "$T/train-closed.txt" ] && bad "N3 and closes nothing: $(cat "$T/train-closed.txt")" || ok
else
  bad "N3 fixture could not be armed"
fi
advance_main

# ============================================================================
# N4. AN UNREADABLE PR STATE IS NOT "BEHIND"
#     A train that has in fact MERGED reads as behind by construction — the tip
#     contains the union, not the reverse. So when `gh pr view` answers nothing
#     at all, acting on the behind check would re-form, or close, a train that
#     may already be landed. The trigger requires GitHub to have said OPEN.
# ============================================================================
if arm_behind; then
  : > "$T/train-state-901.json"          # the read succeeds and says nothing
  run
  [ "$(remote_head "$BR1")" = "$U1_REMOTE_BEFORE" ] && ok \
    || bad "N4 a train whose state could not be read must not be re-formed on a behind answer"
  [ -s "$T/train-closed.txt" ] && bad "N4 and must certainly not be closed: $(cat "$T/train-closed.txt")" || ok
else
  bad "N4 fixture could not be armed"
fi
advance_main

# ============================================================================
# B1. A BEHIND TRAIN WITH NO BUDGET LEFT IS CLOSED, NOT LEFT LANDABLE
#     The DIRTY arm may leave a spent train to its age budget — nobody can
#     merge a union that does not merge. A BEHIND one IS landable and its
#     verification does not cover the tip, so leaving it in the queue is
#     leaving the bug in the queue.
# ============================================================================
if arm_behind; then
  jq -c '.reform_n = 3' "$REC1" > "$REC1.tmp" && mv -f "$REC1.tmp" "$REC1"
  run
  grep -qxF 901 "$T/train-closed.txt" 2>/dev/null && ok \
    || bad "B1 a behind train past BATCH_REFORM_MAX must be taken out of the queue (closed: '$(tr '\n' ' ' < "$T/train-closed.txt")')"
  [ "$(jq -r '.status' "$REC1" 2>/dev/null)" = abandoned ] && ok \
    || bad "B1 and its record must read abandoned (got $(jq -r '.status' "$REC1" 2>/dev/null))"
  grep -qxF "102 $HEAD_B" "$STATE/abandoned.txt" 2>/dev/null && ok \
    || bad "B1 and its member must be released and excluded at its head"
  grep -qi 'BATCH_REFORM_MAX' "$LOG" && ok || bad "B1 the refusal must name the budget: $(tail -3 "$LOG")"
else
  bad "B1 fixture could not be armed"
fi
advance_main

# ============================================================================
# D1. THE DIFF BEATS THE PLAN
#     #107's pre-plan names src/unrelated.ts; the patch it carries also touches
#     src/feature-a.ts, which #101 carries. The plan is a PREDICTION of the
#     patch and the patch is what the review was of — so judged honestly these
#     two could meet and must ride one train.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 107 ticket/tk-17 "$HEAD_G" 2026-09-21T07:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok \
  || bad "D1 a candidate whose PATCH meets another's must ride ONE train, whatever its plan predicted (branches: $(nbatch); $(grep -i 'claims' "$LOG" | tr '\n' '|'))"
[ "$(bodymem 900)" = "101 107 " ] && ok \
  || bad "D1 and that train must carry both of them (got '$(bodymem 900)')"
grep -q '#107 claims 2 file(s) from diff' "$LOG" && ok \
  || bad "D1 the lane must say it judged #107 from the diff: $(grep -i '#107 claims' "$LOG" | head -1)"

# ============================================================================
# D2. DIFF-FIRST IS NOT DIFF-ONLY
#     #108's whole patch is the declared generated registry, which is
#     subtracted from every set. An empty answer is not an answer, so the plan
#     still speaks — and a planned regen-only PR is judged, not UNJUDGED.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 108 ticket/tk-16 "$HEAD_F" 2026-09-21T08:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 2 ] && ok \
  || bad "D2 a regen-only diff must fall back to the plan, not collapse the partition (branches: $(nbatch))"
grep -q '#108 claims 1 file(s) from plan:' "$LOG" && ok \
  || bad "D2 and the lane must say the plan is what answered: $(grep -i '#108 claims' "$LOG" | head -1)"

# ============================================================================
# M1. THE REPO'S MOST-COUPLED DIRECTORIES ARE MODULES
#     bin/lib/*.sh, bin/*.sh and worker/jobs/src/lib/* were in NO module, so
#     two PRs editing the shared libraries every lane sources could ride two
#     trains at once. Order matters: the child pattern must win over its
#     parents, or bin/lib/mc/ would collapse into bin/.
# ============================================================================
( set -u
  # shellcheck source=/dev/null
  . "$H/bin/lib/mc/train.sh"
  check() { # check <path> <expected>
    local got; got=$(mrt_module_of "$1")
    [ "$got" = "$2" ] || { echo "mrt_module_of $1 -> '$got', expected '$2'"; return 1; }
  }
  check bin/lib/gh-rest.sh          "bin/lib/"             || exit 1
  check bin/batch-resolve.sh        "bin/"                 || exit 1
  check worker/jobs/src/lib/core.js "worker/jobs/src/lib/" || exit 1
  check bin/lib/mc/train.sh         "bin/lib/mc/"          || exit 1
  if mrt_module_of docs/x.md >/dev/null 2>&1; then
    echo "docs/x.md must belong to no module, got '$(mrt_module_of docs/x.md)'"; exit 1
  fi
  exit 0
) && ok || bad "M1 the module map is wrong — see the line above"

# ============================================================================
# M2. AND THEREFORE TWO LANE SCRIPTS RIDE ONE TRAIN
#     bin/one.sh and bin/two.sh are different files and a textual non-conflict.
#     They are also the same module, which is the whole reason a module list
#     exists — and the reason this repo's own lane scripts must be in one.
# ============================================================================
reset
{ mkpr 109 ticket/tk-18 "$HEAD_I" 2026-09-21T09:00:00Z
  mkpr 110 ticket/tk-19 "$HEAD_J" 2026-09-21T10:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok \
  || bad "M2 two PRs in bin/ must ride ONE train (branches: $(nbatch); $(grep -i 'claims' "$LOG" | tr '\n' '|'))"
[ "$(bodymem 900)" = "109 110 " ] && ok || bad "M2 and both must be in it (got '$(bodymem 900)')"

echo "$PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
